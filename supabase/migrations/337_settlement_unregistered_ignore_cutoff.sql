-- ============================================================
-- 337_settlement_unregistered_ignore_cutoff.sql
-- 「미등록」 조회를 도입일과 무관하게 (정산 2단계 · 사양서 §4-2)
--
-- ▶ 왜
--   상태 탭에 「미등록」이 생기면서 그 탭의 뜻이 **「정산 행이 아직 없는 건 전부」**가
--   된다. 그런데 이 함수는 324 까지 「도입일 이전 + 금액 미확정」만 돌려줬다.
--   화면만 합치고 이 함수를 그대로 두면 **5단계에서 도입일을 켜는 순간 탭이 반쪽**이 된다.
--
-- ▶ 무엇을 바꾸나 — **`WHERE` 절 한 곳뿐**
--   · 컷오프 조건 제거 → `WHERE c.is_success` 만 남는다
--   · **반환 항목은 그대로**(`is_pre_cutoff` 포함). 화면이 안 쓰게 되더라도 빼면 서명이
--     달라져 `DROP` 이 필요해진다. 유지하면 **덮어쓰기로 끝나** 호출부 영향이 0이다
--
-- ⚠️ **베이스는 324**(계보 232 → 262 → 300 → **324**). 이 저장소는 과거에 옛 정의를
--    베이스로 재작성해 **알림 잠금이 소실될 뻔한** 전례가 있다. 아래 본문은 324 에서
--    그대로 떼어 온 것이고 `WHERE` 절만 고쳤다.
-- ⚠️ `_settlement_cert_candidates()` 는 **건드리지 않는다**(계보 …→318→331,
--    인증 판정·금액 계산의 단일 소스).
-- ⚠️ 지금은 도입일이 비어 있어 **동작 차이가 0건**이다. 그래도 지금 고치는 이유는
--    5단계에 가서 고치면 이미 혼란을 겪은 뒤이기 때문이다.
--
-- ⚠️ 번호 안내 — 334·335·336·337 사용. 다음 사람은 338 부터 쓸 것.
--    332 는 이미 이 저장소 dev 브랜치에 site_daily_visits 로 확정돼 있다(iOS 와 무관).
--    333 은 dev 에는 없지만 `feature/ios-app` 브랜치(아직 dev 미병합)가 자기 번호로
--    332_device_push_tokens.sql·333_device_push_token_rpcs.sql 을 이미 갖고 있다 —
--    그쪽 332 는 이쪽 332 와 **다른 내용**이라, 그 브랜치가 dev 로 들어오는 날 332·333
--    둘 다(적어도 하나는) 재번호가 필요하다. 이 파일이 그 충돌을 해결하지 않는다 —
--    iOS 브랜치를 dev 로 합칠 때 처리할 것(리뷰 시 확인됨, 2026-08-18).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_past_unregistered_settlements()
RETURNS TABLE (
  application_id       uuid,
  influencer_id        uuid,
  influencer_name       text,
  influencer_name_kana  text,
  has_paypal            boolean,
  campaign_id           uuid,
  campaign_no           text,
  campaign_title        text,
  recruit_type          text,
  amount_jpy            bigint,
  amount_source          text,
  receipt_amount_jpy     bigint,
  amount_cap_jpy          bigint,
  amount_issue           text,
  cert_at               timestamptz,
  is_pre_cutoff          boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff timestamptz;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  RETURN QUERY
  SELECT
    c.application_id,
    c.influencer_id,
    c.influencer_name,
    c.influencer_name_kana,
    (c.paypal_email IS NOT NULL AND btrim(c.paypal_email) <> '') AS has_paypal,
    c.campaign_id,
    c.campaign_no,
    c.campaign_title,
    c.recruit_type,
    c.amount_jpy,
    c.amount_source,
    c.receipt_amount_jpy,
    c.amount_cap_jpy,
    c.amount_issue,
    c.cert_at,
    -- [324, H-3] true = 진짜 과거분(컷오프 이전·시각 불명·컷오프 미설정 — 300 원본과
    --   동일 판정). false = 컷오프 이후인데 amount_issue 때문에 새로 노출된 건(이번
    --   추가분) — 화면이 두 경우에 다른 안내 문구를 붙일 수 있도록 구분값만 내려준다.
    (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff) AS is_pre_cutoff
  FROM public._settlement_cert_candidates() c
  -- ★ [337] 컷오프 조건을 뺐다 — **인증에 성공한 후보 전부**를 돌려준다.
  --   324 까지는 「도입일 이전」 + 「금액 미확정」만 반환했다. 화면이 「과거 미등록」이라는
  --   별도 자리였을 때는 그게 맞았지만, 이제 상태 탭의 「미등록」으로 흡수되면서
  --   **그 탭은 「정산 행이 아직 없는 건 전부」를 뜻한다.**
  -- ⚠️ 안 고치면 **5단계에서 도입일을 켜는 순간 이 탭이 반쪽만 보여준다** — 도입일 이후
  --   건이 통째로 사라지고, 「미등록인데 목록에 없다」는 같은 혼란이 재발한다.
  --   지금은 도입일이 비어 있어(v_cutoff IS NULL) 동작 차이가 **0건**이지만,
  --   그때 가서 고치면 이미 혼란을 겪은 뒤다.
  WHERE c.is_success;
    -- ⚠️ amount_issue 가 있는 행은 화면에서 체크박스 비활성화 대상으로 그대로 반환한다
    -- (300 원본 원칙 유지 — 숨기면 "왜 이 건이 안 보이지"라는 혼란만 남긴다).
END;
$$;

-- ── 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다) ────────────────
-- [1] 서명이 그대로인가 — 반환 칸 16개, is_pre_cutoff 포함
--   SELECT string_agg(p.parameter_name, ', ' ORDER BY p.ordinal_position)
--     FROM information_schema.parameters p
--    WHERE p.specific_schema='public'
--      AND p.specific_name LIKE 'get_past_unregistered_settlements%'
--      AND p.parameter_mode='OUT';
--
-- [2] ★ **실제로 한 번 부른다.** 함수를 만드는 구문은 본문의 자료형을 검사하지 않아
--     적용은 성공하고 첫 호출에서 터진다(2026-08-18 마이그레이션 335, 42804).
--   ⚠️ SQL 편집기는 서비스 키라 `has_permission` 가드에 막힌다(42501).
--      **실제 로그인한 관리자 브라우저 콘솔**에서 부를 것:
--        await db.rpc('get_past_unregistered_settlements')
--
-- [3] 도입일이 비어 있는 지금은 **건수가 안 변해야 정상**이다(동작 차이 0건).
--     적용 전후 건수를 비교해 같으면 통과.
--
-- ── 참고 — 이 함수만 넓히고 짝을 안 넓힌 자리 ─────────────────────────────
-- register_past_settlements()(324) 는 **자기 안에도 같은 컷오프 조건**을 그대로 갖고
-- 있다 — 「미등록」 탭이 이 함수로 컷오프 이후 건까지 보여주게 된 뒤에도, 그 건을 골라
-- 「송금완료 기록」을 누르면 register_past_settlements() 의 targets 절이 조용히 걸러내
-- registered_count 만 줄어든다(오류도, skipped_no_paypal 같은 사유 표시도 없다).
-- ⚠️ 지금은 사이드 이펙트가 없다 — 작업표(2026-08-18-settlement-stage2-breakdown.md)
--    작업3이 「미등록」 탭의 일괄 버튼 자체를 3단계까지 잠그기 때문이다. 이 함수는
--    3단계(마이그레이션 C)에서 다시 재정의되니, **그때 이 컷오프 조건도 같이 다룰 것**
--    — 안 다루면 3단계 잠금 해제 직후 같은 문제가 되살아난다.
--
-- 롤백: 324 의 같은 함수 정의를 다시 적용한다(DROP 후 CREATE).
