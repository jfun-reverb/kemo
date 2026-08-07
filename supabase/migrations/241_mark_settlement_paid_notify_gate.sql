-- ============================================================
-- 241_mark_settlement_paid_notify_gate.sql
-- mark_settlement_paid() 알림 발송을 인플루언서 공개 스위치로 조건화
--
-- 배경: 마이그레이션 240에서 도입한 settlement_settings.influencer_visible 이
--   false(기본, 잠금)인 동안에는 관리자가 송금 완료 처리를 해도 인플루언서에게
--   settlement_paid 알림이 나가면 안 된다("관리자만 기록" 단계 — 인플루언서에게는
--   정산 관련 흔적이 일절 노출되지 않아야 함).
--
-- 변경 범위(최소 변경 원칙 — 마이그레이션 222 원문 전체를 그대로 복사한 뒤
--   notifications INSERT 한 구간만 IF public.is_settlement_public() THEN ... END IF;
--   로 감쌌다):
--   - 권한 가드(has_permission('settlement.pay','write')) — 무변경
--   - 대상 행 잠금 조회(FOR UPDATE) — 무변경
--   - 낙관적 락(version 불일치 시 -1 반환) — 무변경
--   - 상태 전이 검증(pending 만 허용) — 무변경
--   - PayPal 최신값 재조회 + 미등록 시 차단 — 무변경
--   - settlements UPDATE(status='paid' 등) — 무변경
--   - settlement_events 감사 이력 INSERT — ⚠️무변경, 항상 실행됨
--     (스위치와 무관하게 금전 감사 기록은 계속 남아야 한다 — 요청 사항 그대로)
--   - notifications INSERT(settlement_paid) — ★이 마이그레이션이 바꾸는 유일한 부분,
--     is_settlement_public() 이 true 일 때만 실행
--
-- 되돌리는 방법: 마이그레이션 240의 스위치를 true 로 켜면(코드 재배포 없이) 이
--   함수는 자동으로 알림을 다시 보낸다. 함수 자체를 원래(222) 동작으로 되돌리려면
--   파일 하단 롤백 SQL 참고(스위치 조건 없이 항상 알림 발송).
--
-- 작성일: 2026-07-20
-- ============================================================

CREATE OR REPLACE FUNCTION public.mark_settlement_paid(
  p_settlement_id uuid,
  p_version       integer,
  p_memo          text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row          record;
  v_paypal_fresh text;
  v_new_version  integer;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──────────────────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, status, version, influencer_id
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) ─────────────────────────
  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  -- ── 상태 전이 검증: pending 만 송금 처리 가능 ───────────────────
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '정산 대기(pending) 상태만 송금 처리할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- ── PayPal 최신값 재조회(마스킹 뷰 우회 — DEFINER 원본 테이블 직접 조회) ──────
  SELECT NULLIF(btrim(paypal_email), '') INTO v_paypal_fresh
    FROM public.influencers
   WHERE id = v_row.influencer_id;

  IF v_paypal_fresh IS NULL THEN
    RAISE EXCEPTION 'PayPal 이메일이 등록되지 않아 송금 처리할 수 없습니다 (인플루언서: %)', v_row.influencer_id
      USING ERRCODE = '22023';
  END IF;

  -- ── settlements UPDATE ──────────────────────────────────────
  UPDATE public.settlements
     SET status       = 'paid',
         paid_at      = now(),
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  -- ── settlement_events 감사 이력 ─────────────────────────────
  -- [240] 스위치와 무관하게 항상 남는다 — 금전 감사는 잠금 상태에서도 필수.
  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  -- ── 인플루언서 알림(일본어 — 초등학생 눈높이, ui.md 컨벤션) ─────────
  -- [241] settlement_settings.influencer_visible = true 일 때만 발송.
  --   잠금(false, 기본) 상태에서는 관리자가 송금 완료 처리를 해도
  --   인플루언서에게 어떤 알림도 나가지 않는다.
  IF public.is_settlement_public() THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      v_row.influencer_id, 'settlement_paid', 'settlements', p_settlement_id,
      '報酬のお振込みが完了しました',
      'キャンペーンの報酬をPayPalにお振込みしました。マイページの「報酬・お支払い」からご確認ください。'
    );
  END IF;

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text) IS
  '[241] 관리자가 정산(settlements) 1건을 송금 완료 처리하는 RPC. SECURITY DEFINER, '
  'has_permission(''settlement.pay'',''write'') 게이트. pending→paid 만 허용, 낙관적 락 '
  '충돌 시 -1 반환(예외 아님). 송금 시점 influencers.paypal_email 최신값 재조회 후 갱신. '
  'settlement_events 감사 이력은 항상 INSERT(스위치 무관). settlement_paid 알림은 '
  'settlement_settings.influencer_visible=true 일 때만 발행(마이그레이션 240 스위치, 기본 false=미발송).';

REVOKE ALL ON FUNCTION public.mark_settlement_paid(uuid, integer, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_paid(uuid, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 240 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 재정의 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'mark_settlement_paid';

-- [V1] 스위치 잠금(false, 기본) 상태에서 스모크 대상 확보
SELECT s.id, s.status, s.version, s.influencer_id, i.paypal_email
FROM public.settlements s
JOIN public.influencers i ON i.id = s.influencer_id
WHERE s.status = 'pending' AND i.paypal_email IS NOT NULL AND btrim(i.paypal_email) <> ''
LIMIT 5;

-- [V2] 스모크 호출은 앱에서 campaign_admin 로그인 세션으로(SQL Editor 직접 실행은
--   auth.uid() NULL 이라 permission_denied — 정상 동작). 처리 후 아래로 확인:

-- [V3] 잠금 상태 처리 후 확인 — status='paid', settlement_events 1행(action='pay')은 있지만
--   notifications 는 0건이어야 함(잠금 상태이므로)
SELECT status, paid_at, paid_by, version FROM public.settlements WHERE id = '<위 id>';
SELECT * FROM public.settlement_events WHERE settlement_id = '<위 id>' ORDER BY at DESC;
SELECT * FROM public.notifications WHERE kind = 'settlement_paid' AND ref_id = '<위 id>';
-- 기대: settlement_events 1행 존재, notifications 0행

*/

-- ============================================================
-- 롤백용 원본 전문 (마이그레이션 222 — 스위치 조건 없이 항상 알림 발송)
-- ============================================================
/*

CREATE OR REPLACE FUNCTION public.mark_settlement_paid(
  p_settlement_id uuid,
  p_version       integer,
  p_memo          text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row          record;
  v_paypal_fresh text;
  v_new_version  integer;
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  SELECT id, status, version, influencer_id
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '정산 대기(pending) 상태만 송금 처리할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  SELECT NULLIF(btrim(paypal_email), '') INTO v_paypal_fresh
    FROM public.influencers
   WHERE id = v_row.influencer_id;

  IF v_paypal_fresh IS NULL THEN
    RAISE EXCEPTION 'PayPal 이메일이 등록되지 않아 송금 처리할 수 없습니다 (인플루언서: %)', v_row.influencer_id
      USING ERRCODE = '22023';
  END IF;

  UPDATE public.settlements
     SET status       = 'paid',
         paid_at      = now(),
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
  VALUES (
    v_row.influencer_id, 'settlement_paid', 'settlements', p_settlement_id,
    '報酬のお振込みが完了しました',
    'キャンペーンの報酬をPayPalにお振込みしました。マイページの「報酬・お支払い」からご確認ください。'
  );

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text) IS
  '[222-rollback] 알림 게이트(241) 제거, 항상 알림 발송하는 원본 동작으로 복귀.';

GRANT EXECUTE ON FUNCTION public.mark_settlement_paid(uuid, integer, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

*/
