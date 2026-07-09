-- ============================================================
-- 233_settlement_register_past_fn.sql
-- 정산 과거분 컷오프 PR2 — 2/2 (과거 건 수동 처리 RPC, 알림 없음)
-- 사양서: docs/specs/2026-07-09-settlement-cutoff-past-handling.md §「설계」②「확정 설계 결정」④⑤⑦
--
-- register_past_settlements(p_application_ids, p_target_status, p_memo) — 관리자가
-- 「과거 미등록」 목록(마이그레이션 232 get_past_unregistered_settlements)에서 건별/
-- 다중선택 후 「지급완료 기록」(paid) 또는 「정산대기 추가」(pending) 중 하나로 확정할
-- 때 호출한다.
--
-- ── 판정 재사용(사양서 지시 — 232와 정확히 동일해야 함) ──
--   마이그레이션 232 에서 만든 private 헬퍼 `public._settlement_cert_candidates()`
--   를 그대로 호출한다. 클라이언트가 넘긴 application_id 목록을 **서버가 그대로
--   신뢰하지 않고**, 헬퍼가 다시 계산한 is_success·candidates(=아직 settlements 행
--   없음) 로 재검증한 뒤 그 교집합만 실제로 INSERT 한다:
--     - is_success=false 이거나
--     - 클라 조회 이후 다른 관리자가 먼저 처리해 이미 settlements 행이 생겼거나
--       (헬퍼의 candidates CTE 가 NOT EXISTS settlements 라 이미 자동 제외됨)
--     - 존재하지 않는/이미 취소된 application_id 이거나
--   위 경우는 조용히 skip 되고(예외 아님), 실제 등록된 건수만 반환한다.
--   ON CONFLICT (application_id) DO NOTHING 을 추가로 걸어 동시 처리 경쟁(두 관리자가
--   같은 건을 동시에 선택해 제출)에도 중복 INSERT 가 발생하지 않도록 이중 방어한다.
--
-- ── 알림 없음(사양서 §확정 설계 결정 ⑤, 사용자 강조 2026-07-09) ──
--   mark_settlement_paid()(마이그레이션 222)는 처리 시 settlement_paid 알림을 발행하고,
--   backfill_settlements()(231/232)는 PayPal 미등록 시 settlement_paypal_required 알림을
--   발행한다. 이 함수는 **의도적으로 둘 다 발행하지 않는다** — 과거 이관 처리는 "이미
--   지나간 일을 시스템에 기록만 하는" 성격이라, 활동을 이미 종료했거나 잊고 있던
--   과거 인플루언서에게 뒤늦게 알림이 쏟아지는 걸 막기 위함(마이그레이션 231이 막은
--   "컷오프 자동 백필 알림 폭주"와 같은 취지를 수동 처리 경로에도 동일하게 적용).
--   notifications INSERT 문 자체가 이 함수 본문에 없다(주석으로만 알리는 게 아니라
--   실제로 코드가 없음 — 검증 SQL [V3] 참고).
--
-- ── paid 분기 시 paid_at/paid_by(사양서 §확정 설계 결정 ④) ──
--   p_target_status='paid' 로 등록하는 건 "이미 외부 PayPal 로 지급 완료한 과거 건을
--   시스템에 뒤늦게 기록"하는 것이므로, 실제 지급 시각을 알 수 없는 이상 처리 시각
--   (now())을 paid_at 으로, 처리한 관리자(auth.uid())를 paid_by 로 기록한다 —
--   mark_settlement_paid()(222)가 pending→paid 전이 시 하는 것과 동일한 컬럼 세팅을
--   "생성과 동시에" 적용하는 셈이다. p_target_status='pending' 이면 paid_at/paid_by
--   는 NULL(정상 pending 신규 생성, 231/232의 backfill_settlements INSERT 와 동일한 값).
--
-- ── settlement_events 이력(사양서 §확정 설계 결정 ⑦) ──
--   action='create', prev_status=NULL, next_status=p_target_status(스키마 CHECK가
--   'create' action 의 next_status 값 자체를 제한하지 않으므로 'paid'/'pending' 모두
--   허용됨 — 마이그레이션 217 settlement_events.next_status CHECK 는 4개 상태 전부
--   허용). memo 에 "과거 이관" 표시를 기본 포함해, 이후 이력 조회(get_settlement_events,
--   마이그레이션 225)에서 자동 백필분과 구분 가능하게 한다.
--
-- ── 권한(사양서 §확정 설계 결정 ⑦) ──
--   has_permission('settlement.pay','write') — mark_settlement_paid 와 동일 기준
--   (campaign_manager 는 hidden 이라 42501). "지급완료 기록"은 되돌릴 수 없는 동작이므로
--   화면(admin-settlements.js, 후속 UI 조각)에서 확인 모달을 강제한다(서버는 게이트만).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.register_past_settlements(
  p_application_ids uuid[],
  p_target_status   text,
  p_memo            text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registered integer := 0;
  v_memo       text;
  v_cutoff     timestamptz;
BEGIN
  -- ── 권한 게이트: settlement.pay 최소 write ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 목표 상태 검증: paid | pending 만 허용 ──
  IF p_target_status NOT IN ('paid', 'pending') THEN
    RAISE EXCEPTION 'invalid_target_status: paid 또는 pending 만 허용됩니다 (입력값: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  IF p_application_ids IS NULL OR array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'empty_application_ids: 처리할 응모를 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  v_memo := COALESCE(NULLIF(btrim(p_memo), ''), '과거 이관 (수동 처리)');

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  WITH targets AS (
    -- ── 서버 재검증 ──
    -- 클라가 넘긴 id 목록을 그대로 신뢰하지 않고, 헬퍼가 다시 계산한 is_success 로
    -- 재검증한다. 헬퍼의 candidates CTE 자체가 "아직 settlements 행 없음"만 대상이므로
    -- 조회(232) 이후 이미 처리된 건은 여기서 자동으로 걸러진다.
    SELECT c.application_id, c.influencer_id, c.campaign_id, c.reward, c.paypal_email
    FROM public._settlement_cert_candidates() c
    WHERE c.application_id = ANY(p_application_ids)
      AND c.is_success
      -- 명시적 컷오프 필터(232 조회와 동일) — 컷오프 이후 신규건은 자동 백필 대상이라
      -- 수동 무알림 처리에서 제외(232 목록에 안 뜨지만 서버 이중 방어로 알림 스킵 사고 차단).
      AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id, t.reward,
      p_target_status,
      NULLIF(t.paypal_email, ''),
      CASE WHEN p_target_status = 'paid' THEN now()      ELSE NULL END,
      CASE WHEN p_target_status = 'paid' THEN auth.uid() ELSE NULL END,
      v_memo
    FROM targets t
    -- 동시 처리 경쟁 방지(이중 방어 — candidates 필터가 이미 대부분 걸러내지만
    -- 두 관리자가 같은 순간 같은 건을 제출하는 극단적 경쟁 상황 대비).
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행.
    -- ⚠️ notifications INSERT 는 여기 없음(파일 상단 「알림 없음」 설명 참고 — 의도적).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, p_target_status, auth.uid(), v_memo
    FROM inserted
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_registered FROM inserted;

  RETURN v_registered;
END;
$$;

COMMENT ON FUNCTION public.register_past_settlements(uuid[], text, text) IS
  '[233] 과거 미등록 인증성공 응모를 관리자가 건별/일괄로 settlements 행 생성 처리. '
  'p_target_status=''paid''(이미 외부 지급 완료 — paid_at/paid_by 즉시 세팅) 또는 '
  '''pending''(아직 미지급 — 정산대기로 신규 등록) 만 허용. 서버가 '
  '_settlement_cert_candidates() 로 is_success·미등록 여부를 재검증(클라 입력 비신뢰) '
  '후 통과분만 INSERT, ON CONFLICT(application_id) DO NOTHING 으로 멱등. '
  '⚠️ settlement_paid/settlement_paypal_required 알림 둘 다 발행하지 않음(의도적 — '
  '과거 이관은 뒤늦은 알림 폭주 방지). has_permission(''settlement.pay'',''write'') 게이트, '
  'settlement_events(action=''create'') 이력 기록. 반환값 = 실제 등록된 건수(정수).';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 232 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'register_past_settlements';

-- [V1] 잘못된 target_status 거부 확인 (앱에서 campaign_admin 세션으로 — SQL Editor
--   직접 실행은 auth.uid() 가 NULL 이라 permission_denied 로 먼저 막힐 수 있음)
-- SELECT public.register_past_settlements(ARRAY['00000000-0000-0000-0000-000000000000']::uuid[], 'cancelled', null);
-- 기대: invalid_target_status 예외

-- [V2] 스모크 대상 확보 — 과거 미등록 인증성공 1~2건
SELECT application_id, influencer_id, campaign_title, amount_jpy, cert_at
FROM public.get_past_unregistered_settlements()
LIMIT 5;

-- [V3] 스모크 호출 — pending 등록 (위에서 얻은 application_id 로 교체)
-- SELECT public.register_past_settlements(ARRAY['<위 application_id>']::uuid[], 'pending', '개발 스모크');

-- [V4] 결과 확인 — status='pending', paid_at/paid_by NULL, settlement_events 1행(action='create'),
--   notifications 에 이 건 관련 신규 알림이 "없어야" 함(알림 미발행 검증 핵심)
-- SELECT status, paid_at, paid_by, memo FROM public.settlements WHERE application_id = '<위 id>';
-- SELECT * FROM public.settlement_events s
--   JOIN public.settlements st ON st.id = s.settlement_id
--   WHERE st.application_id = '<위 id>' ORDER BY s.at DESC;
-- SELECT count(*) FROM public.notifications
--   WHERE kind IN ('settlement_paid','settlement_paypal_required')
--     AND created_at > now() - interval '5 minutes';
-- 기대: 0 (이번 호출로 새로 생긴 알림이 없어야 함 — 다른 원인의 최근 알림과 착오 없도록
--   실행 직전 시각을 메모해두고 그 이후 생성분만 비교할 것)

-- [V5] 멱등성 확인 — 같은 application_id 로 재호출 시 registered_count=0
--   (candidates 가 이미 settlements 행 있는 건 자동 제외)
-- SELECT public.register_past_settlements(ARRAY['<위 id>']::uuid[], 'pending', null);
-- 기대: 0

-- [V6] paid 분기 확인 — target_status='paid' 로 다른 미등록 건 처리 후 paid_at/paid_by 세팅 확인
-- SELECT public.register_past_settlements(ARRAY['<다른 application_id>']::uuid[], 'paid', '이미 지급 완료(과거)');
-- SELECT status, paid_at, paid_by, memo FROM public.settlements WHERE application_id = '<다른 id>';
-- 기대: status='paid', paid_at IS NOT NULL, paid_by = 처리한 관리자 uuid

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.register_past_settlements(uuid[], text, text);
-- (이 함수만 지우면 되며, 마이그레이션 232의 헬퍼·backfill_settlements·
--  get_past_unregistered_settlements 에는 영향 없음 — 233 은 232 의 헬퍼를
--  "호출"만 할 뿐 아무것도 재정의하지 않았기 때문)
