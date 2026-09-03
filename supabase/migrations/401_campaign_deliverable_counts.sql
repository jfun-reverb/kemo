-- ============================================================
-- 401. 캠페인 목록의 「결과물 현황」 열 — 서버 집계 함수
-- ============================================================
-- 사양서: docs/specs/2026-09-03-campaign-list-deliverable-column.md
--
-- ── 무엇을 하나 ───────────────────────────────────────────
-- 캠페인마다 결과물 제출·승인 건수를 한 번에 돌려준다.
-- 관리자 캠페인 목록이 「영수증 12/12」·「결과물 8/12」(승인/제출)를 그리는 재료다.
--
-- 🔴 **캠페인마다 조회하면 안 된다.** 운영 캠페인이 212건이다(2026-09-03 실측).
--    이 저장소에는 집계를 가져오는 방식이 둘인데, 신청 열은 **서버 집계 1회**
--    (`get_campaign_application_counts`)이고 브랜드 상세 인증 성공 막대는
--    **캠페인마다 조회**(`hydrateCampCertBars`)다. 후자는 브랜드당 캠페인이
--    몇 개뿐이라 견디는 것이고 목록에는 못 쓴다. `storage.js` 주석이
--    「신청 전건 약 3,000건을 클라이언트로 전송하던 방식에서 서버 집계 1회로 전환」
--    이라 적어 둔 그 교훈이다.
--
-- ── 본뜬 것 ───────────────────────────────────────────────
-- `get_campaign_application_counts()` — 🔴 **현재 원본은 151 이 아니라 179** 다
-- (181 은 이 함수를 정의하지 않고 다른 것만 고친다). 179 가 감사용 계정을 빼면서
-- 재정의했다. 같은 모양을 따른다: 인자 없음 · `SECURITY DEFINER` ·
-- `SET search_path=''` · `is_admin()` 가드 · `authenticated` 에만 실행 권한.
--
-- ── 세는 규칙 (셋 다 빠뜨리면 숫자가 어긋난다) ────────────
-- 🔴 ① **감사용 계정 제외** — 179 와 같은 방식(`influencers` 이어 붙여 `is_audit=false`).
--       안 빼면 같은 줄에 「신청 12/20」(감사용 제외)과 「결과물 13건」(감사용 포함)이
--       나란히 떠 **분자가 분모를 넘는다.** ⚠️ 2026-09-03 실측으로는 감사용 행이
--       1개(응모 0건)라 지금은 숫자가 안 갈리지만, **그 계정으로 응모하는 순간 갈린다.**
-- 🔴 ② **임시저장(`draft`) 제외** — 화면(`fetchDeliverables`)이 원래 빼고 있다.
--       정산이 이 누락으로 한 번 데었다(마이그레이션 318).
-- 🔴 ③ **반려·취소된 신청의 결과물 제외** — 그 결과물은 「검수 불필요」다
--       (2026-07-21 결정). 안 빼면 처리할 수 없는 건이 「검수가 남은 몫」으로 보인다.
--
-- ── 이름은 여기서 정하지 않는다 ───────────────────────────
-- ⚠️ **방문형의 현장 사진도 `kind='receipt'` 다**(2026-09-03 실측 133건).
--    그래서 이 함수는 **종류만 세고**, 그것을 「영수증」이라 부를지 「현장 사진」이라
--    부를지는 **화면이 모집 형식을 보고 정한다.** 그래야 형식이 늘어도 함수를 안 고친다.
--
-- ── 건수다, 사람 수가 아니다 ──────────────────────────────
-- ⚠️ 한 사람이 채널 2개에 내면 **2건**이다. 같은 줄의 「신청」 열은 **사람 수**라
--    단위가 다르다. 그래서 화면은 분모를 「승인된 신청 수」가 아니라 **제출 건수**로
--    두어 한 열 안에서 단위가 닫히게 한다(사양서 결정).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_campaign_deliverable_counts()
RETURNS TABLE(
  campaign_id       uuid,
  receipt_submitted bigint,
  receipt_approved  bigint,
  result_submitted  bigint,
  result_approved   bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 관리자 전용 함수 — 비관리자 접근 차단 (179 와 같은 문구)
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한 없음' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    d.campaign_id,
    COUNT(*) FILTER (WHERE d.kind = 'receipt')                                   AS receipt_submitted,
    COUNT(*) FILTER (WHERE d.kind = 'receipt' AND d.status = 'approved')         AS receipt_approved,
    COUNT(*) FILTER (WHERE d.kind IN ('post', 'review_image'))                   AS result_submitted,
    COUNT(*) FILTER (WHERE d.kind IN ('post', 'review_image')
                       AND d.status = 'approved')                                AS result_approved
  FROM public.deliverables d
  JOIN public.applications a ON a.id = d.application_id
  JOIN public.influencers  i ON i.id = a.user_id
  WHERE d.status <> 'draft'                          -- ② 임시저장 제외
    AND i.is_audit = false                           -- ① 감사용 제외
    AND a.status NOT IN ('rejected', 'cancelled')    -- ③ 검수 불필요 제외
  GROUP BY d.campaign_id;
END;
$$;

COMMENT ON FUNCTION public.get_campaign_deliverable_counts() IS
  '[401] 캠페인별 결과물 제출·승인 건수. 관리자 캠페인 목록 「결과물 현황」 열 전용. '
  '감사용 계정·임시저장·반려취소 신청 제외. 종류만 세고 이름은 화면이 모집 형식으로 정한다.';

-- ------------------------------------------------------------
-- 실행 권한
--   🔴 새 함수는 기본으로 PUBLIC 실행 권한이 붙고, Supabase 가 거기 더해
--      anon·authenticated 에 개별로도 준다. **두 방향은 서로를 대신하지 못한다**
--      (마이그레이션 369·370·375). 함수 안에 `is_admin()` 가드가 있지만
--      기본값에 기대지 않고 명시적으로 닫는다.
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.get_campaign_deliverable_counts() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_campaign_deliverable_counts() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_campaign_deliverable_counts() TO authenticated;


-- ============================================================
-- 검증
-- ============================================================
/*

-- [V1] 권한 — 비로그인은 막히고 로그인은 열려야 한다
SELECT (p.proacl::text LIKE '{=X/%')                            AS public_남음,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = 'get_campaign_deliverable_counts';
-- 기대: false · false · true

-- [V2] 숫자가 맞나 — 함수 결과와 직접 센 것을 대조
--      ⚠️ 편집기는 서비스 키라 is_admin() 이 false 다. 함수를 직접 부르면 「권한 없음」이
--         나는 것이 정상이고, 그게 가드가 살아 있다는 증거다.
--         숫자 대조는 아래처럼 같은 조건을 손으로 세어 본다.
SELECT d.campaign_id,
       count(*) FILTER (WHERE d.kind='receipt')                        AS 영수증_제출,
       count(*) FILTER (WHERE d.kind='receipt' AND d.status='approved') AS 영수증_승인,
       count(*) FILTER (WHERE d.kind IN ('post','review_image'))        AS 결과물_제출,
       count(*) FILTER (WHERE d.kind IN ('post','review_image') AND d.status='approved') AS 결과물_승인
  FROM public.deliverables d
  JOIN public.applications a ON a.id = d.application_id
  JOIN public.influencers  i ON i.id = a.user_id
 WHERE d.status <> 'draft' AND i.is_audit = false
   AND a.status NOT IN ('rejected','cancelled')
 GROUP BY d.campaign_id
 ORDER BY 4 DESC LIMIT 10;

-- [V3] 제외 규칙이 실제로 무언가를 걸러내는가 (안 걸러내면 규칙이 죽은 것)
SELECT count(*) FILTER (WHERE d.status = 'draft')                        AS 임시저장,
       count(*) FILTER (WHERE i.is_audit)                                AS 감사용,
       count(*) FILTER (WHERE a.status IN ('rejected','cancelled'))      AS 반려취소
  FROM public.deliverables d
  JOIN public.applications a ON a.id = d.application_id
  JOIN public.influencers  i ON i.id = a.user_id;
-- ⚠️ 0 이 나오는 축이 있어도 정상이다 — 다만 **그 규칙이 지금 아무것도 안 막고 있다**는
--    뜻이므로, 나중에 데이터가 생겼을 때를 위해 남겨 둔 것임을 알고 볼 것.

*/


-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.get_campaign_deliverable_counts();
