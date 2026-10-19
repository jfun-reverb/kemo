-- ============================================================
-- 551_brand_receipt_sign_guard.sql — 브랜드에게 영수증 서명 주소를 주기 전 「올린 사람 대조」
--   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 5b」 점검에서 나온 구멍
--
-- 구멍: receipt_url 은 회원이 직접 쓰는 칸이다. 회원이 자기 영수증 줄에 **다른 회원의 파일 경로**(receipts/…)를 적으면,
--   그 캠페인의 브랜드가 서버 함수 brand-campaign-results(조각 5 엑셀 · 5b 영수증 하나)로 남의 영수증 서명 주소를 받는다.
--   서버 함수는 서비스 키로 서명해 저장소 정책(548)을 거치지 않는다. 회원 쪽은 548 조회 정책이 같은 대조로 막았다.
-- 막는 법: 서명 전에 이 함수로 거른다 — 548 조회 정책과 같은 판정(_deliverable_media_owner_ok)
--   · 영수증 줄(kind='receipt')이고 값이 통 경로(「://」 없음)
--   · 비공개 통 deliverable-media 에 그 이름의 파일이 있고
--   · 그 파일의 올린 사람 = 그 줄의 회원 또는 그 줄을 대리 등록한 관리자
--   돌려주는 것: 통과한 결과물 번호 + 대조한 경로(+ 대조한 썸네일 경로) — 서명은 이 값으로만
-- 실행 권한: **서비스 키만**(서버 함수 전용). 회원·브랜드·비로그인 모두 회수 — 남의 결과물 번호로 파일 존재를 떠보지 못하게
--
-- 되돌리기: DROP FUNCTION public.service_brand_receipt_signable(uuid[]); — 그 전에 서버 함수를 이 호출 없는 판으로 되돌릴 것
--   (반대 순서면 서명이 전부 실패해 브랜드가 영수증을 못 연다 — 서버 함수는 판정 실패를 「서명 안 함」으로 처리한다)
-- 편집기 경고: 함수 DROP 이 하나 있다(이 함수 자신 — 반환형 변경). 표 변경 없음
-- ============================================================

-- 🔄 반환을 「번호」 → 「번호 + 대조한 경로 + 대조한 썸네일 경로」로(점검 반영). 서버 함수는 **이 값만** 서명한다 —
--    화면·판정 응답의 값을 다듬어(앞뒤 공백 자르기 등) 서명하면, 대조한 파일과 서명하는 파일이 달라지는 길이 생긴다
--    (예: 「receipts/남의경로 」처럼 끝에 공백을 붙인 이름으로 자기 파일을 올려 대조를 통과시키고, 잘린 남의 경로를 서명받기).
--    썸네일도 올린 사람을 따로 대조한다(원본과 같은 판정) — 통과 못 하면 thumb_path NULL.
-- 개발서버에 옛 판(SETOF uuid)이 먼저 들어갔다 — 반환형이 달라 DROP 후 CREATE(서비스 키 전용이라 다른 호출처 없음 · 권한은 아래에서 다시 건다)
DROP FUNCTION IF EXISTS public.service_brand_receipt_signable(uuid[]);

CREATE FUNCTION public.service_brand_receipt_signable(p_ids uuid[])
RETURNS TABLE (deliverable_id uuid, path text, thumb_path text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT d.id, o.name, t.name
    FROM public.deliverables d
    JOIN storage.objects o
      ON o.bucket_id = 'deliverable-media'
     AND o.name = d.receipt_url
    LEFT JOIN storage.objects t
      ON t.bucket_id = 'deliverable-media'
     AND t.name = regexp_replace(o.name, '^([^/]+)/', '\1/thumb/')
     AND public._deliverable_media_owner_ok(t.owner_id, d.user_id, d.submitted_by_admin)
   WHERE d.id = ANY (coalesce(p_ids, ARRAY[]::uuid[]))
     AND d.kind = 'receipt'
     AND d.receipt_url IS NOT NULL
     AND position('://' in d.receipt_url) = 0
     AND public._deliverable_media_owner_ok(o.owner_id, d.user_id, d.submitted_by_admin);
$$;

COMMENT ON FUNCTION public.service_brand_receipt_signable(uuid[]) IS
  '[551] 브랜드 영수증 서명 전 올린 사람 대조(548 조회 정책과 같은 판정) — 통과한 결과물 번호 + 대조한 경로·썸네일 경로(서명은 이 값만). 서비스 키 전용(서버 함수 brand-campaign-results).';

GRANT  EXECUTE ON FUNCTION public.service_brand_receipt_signable(uuid[]) TO postgres, service_role;
REVOKE ALL ON FUNCTION public.service_brand_receipt_signable(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_brand_receipt_signable(uuid[]) FROM anon, authenticated;
