-- ============================================================
-- 364_withdrawal_media_purge.sql
-- 2026-08-20
--
-- 목적:
--   탈퇴가 확정된 회원의 **영수증·인증샷 파일**을 확정 6개월 뒤 저장소에서
--   실제로 지운다. 지운 뒤 주소 칸(receipt_url)을 비우고 파기 시각을 찍는다.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 12
--
-- ============================================================
-- 🔴 이 저장소에서 「서버가 저장소 파일을 지우는」 첫 사례다
-- ============================================================
--   지금까지 파일 삭제는 **전부 브라우저가** 했다(감사용 계정 청소·캠페인
--   보관 삭제 — 서버 함수가 경로를 돌려주고 화면이 지운다). 이번은 예약
--   실행이라 브라우저가 없다.
--
--   ⚠️ 그래서 325 는 **큐**를 만들었다 — 지울 경로를 표에 쌓아 두고 나중에
--   화면이 소비하게. 그런데 **그 큐를 소비하는 화면을 아무도 안 만들어서,
--   위반 증빙 파일은 지금도 안 지워지고 있다**(CLAUDE.md 에 「파기 완료가
--   아니라 추적 근거만 보존」이라고 적혀 있는 그 상태다).
--
--   이번엔 큐를 만들지 않는다. 만들 필요가 없다:
--     - 325 가 큐를 쓴 진짜 이유는 「예약 실행이라서」가 아니라, 경로를 담고
--       있던 **행 자체가 그 순간 영원히 사라져서** 나중에 물어볼 곳이 없었기
--       때문이다(위반 기록을 지우면서 그 행의 경로도 함께 사라진다).
--     - 여기서는 `applications`·`deliverables` 행이 **안 지워진다**(정산 감사
--       기록이 붙들고 있다). 주소는 언제든 다시 조회할 수 있다.
--
--   ★ 그 결과 **「아직 안 지워진 것」의 표시가 별도 표가 아니라
--     `receipt_url` 이 아직 남아 있다는 사실 그 자체**가 된다.
--     쌓기만 하고 안 지우는 실패가 구조적으로 불가능해진다 — 안 지우면
--     다음 날에도 그대로 목록에 뜨고, 밀린 건수 경고에도 그대로 잡힌다.
--
-- ============================================================
-- 무엇을 지우나 / 무엇은 안 지우나
-- ============================================================
--   지운다 : deliverables.receipt_url 이 가리키는 파일
--            - kind='receipt'      (영수증 + **방문형 현장 사진**)
--            - kind='review_image' (리뷰 인증샷)
--   안 지운다:
--            - kind='post'          — 파일이 아니라 바깥 SNS 주소다(우리가
--              지울 수 있는 것이 아니다)
--            - 캠페인 이미지(img1~8) — 개인정보가 아니고, 지우면 캠페인
--              화면이 깨진다
--            - **응모건 메시지 첨부** — 성격은 같지만 이번 범위 밖(사용자
--              결정 2026-08-20 「조각으로 분리」). 아래 [C] 의 kind 목록이
--              그 확장 자리다 — 나중에 종류 하나만 더하면 된다.
--            - 위반 증빙(influencer-flag-evidence) — 보관기간이 3년으로
--              다르다(마이그레이션 166·325 소관)
--
-- ============================================================
-- ⚠️ 영수증은 **공개 통**에 있다 (이번 작업이 만든 문제는 아니다)
-- ============================================================
--   receipt_url 은 `campaign-images/receipts/...` 를 가리키고 그 통은
--   공개 읽기다. 즉 확정 후 6개월 동안은 **주소를 아는 사람이면 누구나**
--   그 영수증을 볼 수 있다. 이 파일이 그걸 6개월로 끊어 주기는 하지만
--   해결하지는 못한다(비공개 통 이전은 별도 과제 — 전수조사 묶음 B 가
--   「브랜드사가 그 링크로 확인 중」이라 보류한 그 건이다).
--   → 약관·방침에 파기 문구를 쓸 때 「6개월간은 공개 주소」임을 알고 쓸 것.
--
-- ============================================================
-- 되돌리기
-- ============================================================
--   DROP FUNCTION IF EXISTS public.count_overdue_withdrawal_media_purge();
--   DROP FUNCTION IF EXISTS public.count_overdue_withdrawal_email_blocks();
--   DROP FUNCTION IF EXISTS public.mark_withdrawal_media_purged(uuid[]);
--   DROP FUNCTION IF EXISTS public.list_pending_withdrawal_media_purge(integer);
--   DROP FUNCTION IF EXISTS public._withdrawal_media_purge_due_ids();
--   ALTER TABLE public.deliverables DROP COLUMN IF EXISTS media_purged_at;
--   ⚠️ 365(예약 등록)를 **먼저** 되돌릴 것 — 순서가 바뀌면 함수가 사라진
--   채로 예약이 계속 돌아 매일 실패한다.
--   ⚠️ 이미 지워진 **파일은 되살아나지 않는다.** 칸을 되돌려도 마찬가지다.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] deliverables.media_purged_at — 파기 시각
-- ============================================================
--   ⚠️ 이 칸이 없으면 「지웠다」와 「원래 파일이 없었다」를 구분할 수 없다.
--   둘 다 receipt_url 이 비어 있는 모습이라, 나중에 감사에서
--   「이 회원 영수증은 파기된 건가, 애초에 안 낸 건가」를 답할 수 없다.
ALTER TABLE public.deliverables
  ADD COLUMN IF NOT EXISTS media_purged_at timestamptz;

COMMENT ON COLUMN public.deliverables.media_purged_at IS
'탈퇴 확정 6개월 뒤 영수증·인증샷 파일을 저장소에서 지운 시각(마이그레이션 364). '
'NULL 이고 receipt_url 도 NULL 이면 「원래 안 냈다」, NOT NULL 이면 「내고 파기됐다」. '
'이 칸이 채워지는 순간 receipt_url 은 함께 비워진다(같은 UPDATE).';

-- 파기 대상 조회 전용 부분 색인 — 아직 안 지운 파일 있는 행만.
CREATE INDEX IF NOT EXISTS idx_deliverables_media_purge_pending
  ON public.deliverables (user_id)
  WHERE media_purged_at IS NULL
    AND receipt_url IS NOT NULL
    AND kind IN ('receipt', 'review_image');

-- ============================================================
-- [B] _withdrawal_media_purge_due_ids() — 파기 기한이 지난 회원
-- ============================================================
--   ⚠️ 363(페이팔 파기)에서 겪은 함정을 그대로 피한다.
--   한 회원이 탈퇴 → 취소 → 재가입 → 재탈퇴를 하면 `done` 행이 여러 개다.
--   행마다 날짜를 비교하면 **옛 확정 1건 때문에 최근 확정분까지 기한이 지난
--   것으로 오판**해 아직 지키기로 한 파일을 일찍 지운다.
--   → 회원별로 묶어 **가장 최근 확정 시각**만 본다.
CREATE OR REPLACE FUNCTION public._withdrawal_media_purge_due_ids()
RETURNS TABLE (influencer_id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT w.influencer_id
    FROM public.withdrawal_requests w
   WHERE w.status = 'done'
     AND w.completed_at IS NOT NULL
   GROUP BY w.influencer_id
  HAVING MAX(w.completed_at) <= (now() - interval '6 months');
$fn$;

COMMENT ON FUNCTION public._withdrawal_media_purge_due_ids() IS
'탈퇴 확정 후 6개월이 지난 회원 id(마이그레이션 364). '
'회원별 MAX(completed_at) 기준 — 행 단위로 비교하면 재탈퇴 회원의 최근 확정분이 '
'옛 확정 때문에 일찍 파기된다(363 과 같은 함정).';

REVOKE ALL ON FUNCTION public._withdrawal_media_purge_due_ids() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public._withdrawal_media_purge_due_ids() TO postgres;

-- ============================================================
-- [C] list_pending_withdrawal_media_purge — 지울 목록
-- ============================================================
--   🔴 **service_role·postgres 에게만 준다.** 이 함수는 파일 주소를 그대로
--   돌려주는데 그 통이 **공개 읽기**라, 주소를 받은 사람은 곧 파일을 본
--   것이나 같다. 관리자에게도 주지 않는다 — 관리자가 볼 것은 [E] 의
--   **건수**뿐이다.
--
--   반환하는 `should_delete_file` 의 뜻:
--     같은 주소를 **파기 대상 밖의 다른 행**도 가리키고 있으면 false.
--     그 경우 이 행의 주소 칸만 비우고 **파일은 남긴다** — 그 파일은 아직
--     탈퇴하지 않은 다른 사람의 것이기도 하기 때문이다.
--     (이 저장소는 캠페인 설명 이미지에서 같은 함정을 이미 겪었다 — 복제
--      캠페인이 같은 파일을 가리켜, 참조를 안 세고 지우면 복제본이 깨졌다.)
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
  WITH target AS (
    SELECT d.id, d.receipt_url
      FROM public.deliverables d
      JOIN public._withdrawal_media_purge_due_ids() due
        ON due.influencer_id = d.user_id
     WHERE d.kind IN ('receipt', 'review_image')
       AND d.receipt_url IS NOT NULL
       AND d.media_purged_at IS NULL
       -- 관리자를 겸한 회원은 건드리지 않는다(358·359·361 과 같은 판단).
       -- 눈에 보이게 남겨 [E] 의 밀린 건수에 계속 잡히게 한다.
       AND NOT public._influencer_is_admin_account(d.user_id)
     ORDER BY d.id
     LIMIT GREATEST(COALESCE(p_limit, 500), 1)
  )
  SELECT t.id,
         t.receipt_url,
         -- 공개 전체 주소 → 통 안 상대 경로. 형식이 다르면 NULL.
         -- 🔴 NULL 인 행은 **파기 표시를 하지 않는다**(부르는 쪽 책임).
         --    표시해 버리면 주소 칸이 비어 그 파일을 **영영 다시 찾을 수
         --    없다.** 안 지운 채로 두면 [E] 의 밀린 건수에 계속 잡혀
         --    사람 눈에 띈다 — 361 의 「눈에 보이게 실패」와 같은 판단.
         NULLIF(
           regexp_replace(
             t.receipt_url,
             '^.*/storage/v1/object/public/campaign-images/', ''
           ),
           t.receipt_url            -- 치환이 하나도 안 됐으면 형식 불일치
         ) AS storage_path,
         NOT EXISTS (
           SELECT 1
             FROM public.deliverables o
            WHERE o.receipt_url = t.receipt_url
              AND o.id <> t.id
              AND o.media_purged_at IS NULL
              AND o.id NOT IN (SELECT tt.id FROM target tt)
         ) AS should_delete_file
    FROM target t;
$fn$;

COMMENT ON FUNCTION public.list_pending_withdrawal_media_purge(integer) IS
'탈퇴 확정 6개월이 지나 파기해야 할 영수증·인증샷 목록(마이그레이션 364). '
'🔴 service_role 전용 — 파일 주소를 돌려주는데 campaign-images 는 공개 통이라 '
'주소 노출이 곧 파일 노출이다. 관리자에게는 건수만(count_overdue_withdrawal_media_purge).';

REVOKE ALL ON FUNCTION public.list_pending_withdrawal_media_purge(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_pending_withdrawal_media_purge(integer) TO postgres, service_role;

-- ============================================================
-- [D] mark_withdrawal_media_purged — 파기 표시
-- ============================================================
--   🔴 **순서가 전부다: 파일을 지운 뒤에 이걸 부른다.**
--   반대로 하면(표시 먼저 → 삭제) 삭제가 실패한 파일이 「지운 것」으로
--   찍혀 목록에서 빠지고, **그 파일은 영원히 저장소에 남는다.** 아무도
--   모르고, 다시 찾을 방법도 없다(주소 칸을 이미 비웠으니).
--
--   ⚠️ 「파일이 이미 없음」은 실패가 아니다. 저장소에서 지운 것을 다시
--   지우려 하거나 애초에 업로드가 실패했던 경우인데, 이걸 실패로 치면
--   그 행이 매일 목록에 뜨고 밀린 건수가 **0 이 될 수 없다** — 경고가
--   상시 켜져 있으면 아무도 안 본다.
--
--   ⚠️ 반대로 **주소 형식이 안 맞아 경로를 못 뽑은 행([C] 의
--   storage_path IS NULL)은 여기에 넘기지 않는다.** 넘기면 주소 칸이
--   비어 그 파일을 다시 찾을 길이 사라진다. 안 넘기면 [E] 의 밀린
--   건수에 계속 남아 사람이 보고 처리하게 된다.
CREATE OR REPLACE FUNCTION public.mark_withdrawal_media_purged(
  p_ids uuid[]
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_updated integer;
BEGIN
  IF p_ids IS NULL OR array_length(p_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE public.deliverables
     SET receipt_url     = NULL,
         media_purged_at = now()
   WHERE id = ANY(p_ids)
     AND media_purged_at IS NULL;     -- 멱등 — 두 번 불러도 시각이 안 밀린다

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE NOTICE '[364] 영수증·인증샷 파기 표시 %건', v_updated;
  RETURN v_updated;
END;
$fn$;

COMMENT ON FUNCTION public.mark_withdrawal_media_purged(uuid[]) IS
'저장소에서 실제로 지운 뒤에만 부른다(마이그레이션 364). '
'🔴 표시를 먼저 하면 삭제 실패한 파일이 목록에서 빠져 영영 남는다. '
'주소 칸을 비우는 것과 시각을 찍는 것은 같은 UPDATE 라 어긋날 수 없다.';

REVOKE ALL ON FUNCTION public.mark_withdrawal_media_purged(uuid[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_withdrawal_media_purged(uuid[]) TO postgres, service_role;

-- ============================================================
-- [E] count_overdue_withdrawal_media_purge — 밀린 건수 (관리자용)
-- ============================================================
--   작업 14 의 「밀린 파기 경고」가 쓸 값. 주소는 안 주고 **숫자만** 준다.
--   0 이 정상이고, 며칠째 0 이 아니면 예약이 멈췄거나 삭제가 계속 실패
--   중이라는 뜻이다.
--
--   ⚠️ **권한이 없으면 0 이 아니라 오류를 낸다.** 처음엔 `AND is_admin()`
--   으로 조용히 0 을 돌려주게 썼다가 되돌렸다(2026-08-20 검토 지적):
--     - 이 저장소의 같은 목적 함수 **43개가 전부 예외를 던진다**
--       (248 `count_pending_review_applications` 등). 이것만 다르면
--       다음 사람이 어느 쪽이 맞는지 알 수 없다.
--     - 더 중요한 건, 0 을 돌려주면 화면이 **「밀린 것 없음」과 「볼 권한
--       없음」을 구분할 수 없다.** 이 저장소가 여러 번 세운 「조회 실패와
--       0건을 구분한다」 원칙(마이그레이션 276)과 정면으로 어긋난다.
--     - 작업 14 는 이 값으로 「0 이면 아무것도 안 그린다」를 판정하는데,
--       권한 없는 등급에게도 0 이 가면 **경고가 없는 것인지 못 보는
--       것인지 모른 채** 화면이 조용히 비어 버린다.
CREATE OR REPLACE FUNCTION public.count_overdue_withdrawal_media_purge()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM public.deliverables d
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = d.user_id
   WHERE d.kind IN ('receipt', 'review_image')
     AND d.receipt_url IS NOT NULL
     AND d.media_purged_at IS NULL;

  RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION public.count_overdue_withdrawal_media_purge() IS
'파기 기한이 지났는데 아직 안 지워진 영수증·인증샷 건수(마이그레이션 364, 작업 14 경고용). '
'주소는 주지 않는다 — 관리자에게도. 0 이 정상이고, 권한이 없으면 0 이 아니라 42501 오류다 '
'(화면이 「밀린 것 없음」과 「볼 권한 없음」을 구분해야 한다). '
'⚠️ 관리자를 겸한 회원의 행은 [C] 목록에서 빠지지만 여기에는 계속 잡힌다(의도 — 눈에 보이게). '
'즉 그런 회원이 있으면 이 값이 0 으로 안 내려간다. 작업 14 는 그것도 「사람이 봐야 할 상태」로 그릴 것.';

REVOKE ALL ON FUNCTION public.count_overdue_withdrawal_media_purge() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_overdue_withdrawal_media_purge() TO authenticated;

-- ============================================================
-- [F] count_overdue_withdrawal_email_blocks — 361 이 약속하고 안 만든 것
-- ============================================================
--   361 은 「보관기간 초과는 눈에 보여야 한다 — 작업 14 의 밀린 파기 경고와
--   함께」라고 파일에 적어 놓고 **세는 함수를 만들지 않았다.** 작업 14 가
--   그리려 해도 그릴 재료가 없는 상태였다. 세 줄이라 여기서 함께 만든다.
--
--   ⚠️ 361 의 정리 함수는 `blocked_until <= now()` 인 행을 지운다. 그러니
--   **아직 안 지워진 만료 행의 수**가 곧 밀린 양이다.
--   ⚠️ 권한 없으면 오류 — 위 [E] 와 같은 이유(관행 43개 · 「0건과 권한
--   없음을 구분」).
CREATE OR REPLACE FUNCTION public.count_overdue_withdrawal_email_blocks()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM public.withdrawal_email_blocks b
   WHERE b.blocked_until <= now();

  RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION public.count_overdue_withdrawal_email_blocks() IS
'보관기간이 끝났는데 아직 안 지워진 재가입 차단 해시 건수(마이그레이션 364 — 361 이 '
'약속만 하고 안 만든 자리). 0 이 정상이고, 권한이 없으면 0 이 아니라 42501 오류다. '
'이메일 원문은 어디에도 없으므로 숫자만 나온다.';

REVOKE ALL ON FUNCTION public.count_overdue_withdrawal_email_blocks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_overdue_withdrawal_email_blocks() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인
-- (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — .claude/rules/supabase.md
--  「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」. 신규 함수가
--  5개라 적용은 성공하고 **첫 호출에서** 자료형·컬럼 오류가 터진다.
--  1단계씩 순서대로, 결과를 보며 진행할 것)
-- ============================================================
--
-- [V0] 칸이 생겼는지
--   SELECT column_name, data_type FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='deliverables'
--      AND column_name='media_purged_at';
--   기대: 1행, timestamp with time zone.
--
-- [V1] ★ 기한이 지난 회원이 있는지 (없어도 정상 — 지금 탈퇴 확정 0건)
--   SELECT * FROM public._withdrawal_media_purge_due_ids();
--   기대: 0행(시행 전이라 확정된 탈퇴가 아직 없다).
--
-- [V2] ★★ 목록 함수 첫 호출 — 자료형 오류(42804)·컬럼 모호성(42702)이
--      여기서 드러난다. 0행이어도 **호출 자체가 성공하는지**가 확인 대상.
--   SELECT * FROM public.list_pending_withdrawal_media_purge(10);
--   기대: 0행, 오류 없음.
--
-- [V3] 건수 함수 2개 — ⚠️ **여기서는 권한 오류가 나는 것이 정상이다.**
--      SQL 편집기는 서비스 키라 is_admin() 이 false 이고, 이 두 함수는
--      권한이 없으면 0 이 아니라 오류를 낸다(「밀린 것 없음」과 「볼 권한
--      없음」을 화면이 구분할 수 있어야 하기 때문).
--   SELECT public.count_overdue_withdrawal_media_purge();
--   SELECT public.count_overdue_withdrawal_email_blocks();
--   기대: 둘 다 **오류 42501 'forbidden'**.
--   → 여기서 숫자 0 이 나오면 권한 검사가 안 걸린 것이므로 확인할 것.
--   → 진짜 값 확인은 [V6] 에서 관리자 브라우저로 한다.
--
-- [V4] ★★★ 주소 변환이 실제 데이터에서 맞는지 — 파기 대상이 0건이라
--      변환식만 따로 시험한다(읽기 전용, 아무것도 안 바꾼다):
--   SELECT receipt_url,
--          NULLIF(regexp_replace(receipt_url,
--                 '^.*/storage/v1/object/public/campaign-images/',''),
--                 receipt_url) AS storage_path
--     FROM public.deliverables
--    WHERE receipt_url IS NOT NULL LIMIT 5;
--   기대: storage_path 가 'receipts/....jpg' 처럼 나오고 **NULL 이 아니어야**
--   한다. NULL 이 나오면 그 행은 주소 형식이 달라 파일을 못 지운다 —
--   몇 건인지 세어 볼 것:
--     SELECT count(*) FROM public.deliverables
--      WHERE receipt_url IS NOT NULL
--        AND receipt_url NOT LIKE '%/storage/v1/object/public/campaign-images/%';
--   기대: 0. 0 이 아니면 그 형식을 확인하고 변환식을 넓혀야 한다.
--
-- [V5] 참조 세기가 필요한 상황이 실제로 있는지(같은 주소를 두 행이 가리킴):
--   SELECT receipt_url, count(*) FROM public.deliverables
--    WHERE receipt_url IS NOT NULL GROUP BY receipt_url HAVING count(*) > 1;
--   → 0행이면 참조 세기는 안전망일 뿐이다. 0행이 아니면 **핵심 장치**가
--     되므로 [C] 의 should_delete_file 이 false 로 나오는지 눈으로 볼 것.
--
-- [V6] 관리자 브라우저 콘솔에서(로그인한 상태 — SQL 편집기로는 is_admin()
--      분기가 아예 안 돈다):
--   await db.rpc('count_overdue_withdrawal_media_purge')
--   기대: {data: 0, error: null}.
--
-- [V7] 🔴 목록 함수가 관리자에게 **막히는지** (막혀야 정상):
--   await db.rpc('list_pending_withdrawal_media_purge', {p_limit: 1})
--   기대: 권한 오류(42501). 여기서 주소가 나오면 공개 통 파일이 관리자
--   전원에게 열린 것이므로 **즉시 되돌릴 것**.
-- ============================================================
