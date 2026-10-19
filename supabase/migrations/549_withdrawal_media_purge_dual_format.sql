-- ============================================================
-- 549_withdrawal_media_purge_dual_format.sql
-- 2026-10-19 — 탈퇴 회원 영수증·인증샷 파기 목록이 두 형식(옛 공개 주소 · 비공개 통 경로)을 받는다
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 6」(마이그레이션 F) · 의심 2②
--
-- 무엇을 하나
--   _deliverable_media_key(text)  내부 — 결과물 사진 값 → 통 안 경로. 옛 공개 주소(campaign-images)는 접두사를 떼고,
--                                 비공개 통 경로(548 — 「://」 없음)는 그대로. 그 밖의 주소는 NULL.
--   list_pending_withdrawal_media_purge(integer) — 364 본문 그대로 + ①storage_path 를 위 함수로 ②참조 세기(should_delete_file)를
--                                 「같은 경로」로 비교(두 형식을 같은 파일로 본다 — 조각 8 변환 전후에도 같은 판정, 보수적으로 남긴다)
--   🔴 반환 칸은 364 와 같다(CREATE OR REPLACE — 369 의 권한 회수·service_role 부여 보존). 어느 통인지는 서버 함수
--      purge-withdrawal-media 가 receipt_url 의 「://」 유무로 가른다(같은 배포 묶음).
--   적용만으로 바뀌는 기존 동작: 없음 — 지금 값은 전부 공개 주소라 storage_path·should_delete_file 결과가 364 와 같다
--      (개발·운영 모두 「://」 없는 값 0건, 2026-10-19 확인).
--
-- 🔴 운영 반영 — 작업표 「사전」 단계. 순서 고정: 548(통) → 549 → 서버 함수 purge-withdrawal-media 새 판.
--    🔴 함수가 통 둘의 존재를 먼저 확인하므로 548 전에 함수를 배포하면 공개 통 파기까지 전부 멈춘다.
--    ⚠️ 「://」 로 통을 가르는 기준이 두 곳(여기 _deliverable_media_key · 함수 bucketOf) — 한쪽만 바꾸지 말 것.
-- 편집기 경고: 실행 구문에 DROP·DELETE 없음.
-- 롤백: 364 파일의 [C] 부분(list_pending_withdrawal_media_purge) 다시 실행 → DROP FUNCTION public._deliverable_media_key(text);
--       (그다음 369 의 해당 회수 줄 재실행 — CREATE OR REPLACE 라 권한은 남지만 확인)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._deliverable_media_key(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN p_value IS NULL OR btrim(p_value) = '' THEN NULL
    WHEN position('://' IN p_value) = 0 THEN btrim(p_value)
    ELSE NULLIF(regexp_replace(p_value, '^.*/storage/v1/object/public/campaign-images/', ''), p_value)
  END;
$$;
COMMENT ON FUNCTION public._deliverable_media_key(text) IS
  '[549] 결과물 사진 값 → 통 안 경로(옛 공개 주소는 campaign-images 접두사 제거, 비공개 통 경로는 그대로, 그 밖 NULL).';
REVOKE ALL ON FUNCTION public._deliverable_media_key(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._deliverable_media_key(text) FROM anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._deliverable_media_key(text) TO postgres, service_role;

CREATE OR REPLACE FUNCTION public.list_pending_withdrawal_media_purge(
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  deliverable_id     uuid,
  receipt_url        text,
  storage_path       text,
  should_delete_file boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  WITH refs AS (
    -- 참조 세기용 키는 한 번만 계산한다(행마다 함수를 다시 부르지 않게 — 실행 계획 운에 기대지 않는다)
    SELECT o.id, public._deliverable_media_key(o.receipt_url) AS k
      FROM public.deliverables o
     WHERE o.receipt_url IS NOT NULL
       AND o.media_purged_at IS NULL
  ), target AS (
    SELECT d.id, d.receipt_url, public._deliverable_media_key(d.receipt_url) AS mkey
      FROM public.deliverables d
      JOIN public._withdrawal_media_purge_due_ids() due
        ON due.influencer_id = d.user_id
     WHERE d.kind IN ('receipt', 'review_image')
       AND d.receipt_url IS NOT NULL
       AND d.media_purged_at IS NULL
       -- 관리자를 겸한 회원은 건드리지 않는다(358·359·361 과 같은 판단).
       AND NOT public._influencer_is_admin_account(d.user_id)
     ORDER BY d.id
     LIMIT GREATEST(COALESCE(p_limit, 500), 1)
  )
  SELECT t.id,
         t.receipt_url,
         -- 통 안 경로. 형식이 다르면 NULL — 🔴 NULL 인 행은 파기 표시를 하지 않는다(부르는 쪽 책임, 364 와 같다)
         t.mkey AS storage_path,
         -- 같은 경로를 파기 대상 밖의 다른 행도 가리키면 파일은 남긴다. 🔴 두 형식을 같은 파일로 본다(549)
         --    ⚠️ 키에 통 이름이 없다(의도) — 옛 공개 통과 비공개 통에 같은 경로가 있으면 남긴다. 조각 8 변환 뒤 옛 주소 줄이 0건인지,
         --       조각 20 이 옛 공개 사본을 지우는지가 이 판정의 짝이다.
         NOT EXISTS (
           SELECT 1
             FROM refs o
            WHERE o.id <> t.id
              AND t.mkey IS NOT NULL
              AND o.k = t.mkey
              AND o.id NOT IN (SELECT tt.id FROM target tt)
         ) AS should_delete_file
    FROM target t;
$fn$;

COMMENT ON FUNCTION public.list_pending_withdrawal_media_purge(integer) IS
'탈퇴 확정 6개월이 지나 파기해야 할 영수증·인증샷 목록(364 → 549 두 형식). '
'🔴 service_role 전용 — 파일 경로를 돌려준다. 관리자에게는 건수만(count_overdue_withdrawal_media_purge). '
'어느 통인지는 receipt_url 의 「://」 유무 — 있으면 campaign-images, 없으면 deliverable-media(서버 함수가 가른다).';

COMMIT;

-- ============================================================
-- 검증
--   [V1] SELECT public._deliverable_media_key('https://x.supabase.co/storage/v1/object/public/campaign-images/receipts/a.jpg'),  -- receipts/a.jpg
--               public._deliverable_media_key('receipts/a.jpg'),                                                                -- receipts/a.jpg
--               public._deliverable_media_key('https://example.com/a.jpg');                                                     -- NULL
--   [V2] SELECT p.proacl::text FROM pg_proc p WHERE p.proname='list_pending_withdrawal_media_purge';  -- 364·369 와 같은 권한(service_role)
--   [V3] SELECT count(*) FROM public.list_pending_withdrawal_media_purge(500);  -- 적용 전과 같은 수
-- ============================================================
