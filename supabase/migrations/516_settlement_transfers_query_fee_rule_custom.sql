-- =============================================================================
-- 마이그레이션 516: get_settlement_transfers — fee_rule_custom 칸
-- 베이스  : 502 의 「2-1」 블록(현재 원본). 월별·회차별 조회(502 2-2·2-3)는 건드리지 않는다
-- 사양서  : docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md (① (라))
-- 작업표  : docs/specs/2026-10-08-settlement-per-transfer-fee-rule-breakdown.md (D4)
-- 선행    : 513
-- 대상    : 개발서버 → 운영서버
-- 위험도  : 낮음 — 읽기 함수. 반환 칸이 늘어 DROP 후 CREATE(한 트랜잭션에서 권한 3줄까지)
-- 편집기 경고: 뜸 — 무해 (같은 이름·같은 인자의 함수를 바로 다시 만들고 권한을 다시 건다)
--
-- 502 대비: 반환 칸 fee_rule_jpy 바로 뒤에 fee_rule_custom boolean 하나. 나머지 글자 그대로.
--   화면은 칸을 이름으로 읽으므로 이 파일 적용 직후 옛 화면도 그대로 돈다.
--
-- 되돌리기(한 트랜잭션): 502 의 DROP FUNCTION IF EXISTS public.get_settlement_transfers(date, date); + 2-1 블록 + 권한 3줄
-- =============================================================================

BEGIN;

DROP FUNCTION IF EXISTS public.get_settlement_transfers(date, date);

-- ── 2-1. get_settlement_transfers — 묶음 1줄 + 포함 건 jsonb (+ sent_at_estimated · fee_estimated) ──
CREATE FUNCTION public.get_settlement_transfers(p_from date, p_to date)
RETURNS TABLE (
  id                uuid,
  sent_at           timestamptz,
  influencer_id     uuid,
  influencer_name   text,
  sent_total_jpy    bigint,
  fee_jpy           bigint,
  fee_manual        boolean,
  sent_at_estimated boolean,
  fee_estimated     boolean,
  fee_rate_percent  numeric,
  fee_fixed_jpy     integer,
  fee_rounding      text,
  fee_rule_jpy      bigint,
  fee_rule_custom   boolean,
  paypal_txn_id     text,
  memo              text,
  source            text,
  recorded_by       uuid,
  recorded_by_name  text,
  recorded_at       timestamptz,
  version           integer,
  total_spend_jpy   bigint,
  fee_stale         boolean,
  items             jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT t.id,
         t.sent_at,
         t.influencer_id,
         i.name,
         t.sent_total_jpy,
         t.fee_jpy,
         t.fee_manual,
         t.sent_at_estimated,
         t.fee_estimated,
         t.fee_rate_percent,
         t.fee_fixed_jpy,
         t.fee_rounding,
         -- fee_rule_jpy — 저장된 규칙 스냅샷으로 다시 계산한 수수료(2026-10-02 사용자 결정 ①: 고친 값이면 「규칙 계산 · 실제 · 차이」).
         --   🔴 계산식은 _settlement_fee_calc 한 곳 — 화면에 식을 두지 않는다. 스냅샷이 하나라도 비면 NULL(시트 실제값 묶음 — 결정 6)
         CASE WHEN t.fee_rate_percent IS NOT NULL AND t.fee_fixed_jpy IS NOT NULL AND t.fee_rounding IS NOT NULL
              THEN public._settlement_fee_calc(t.sent_total_jpy, t.fee_rate_percent, t.fee_fixed_jpy, t.fee_rounding)
         END,
         -- [516] 이 송금만 요율·고정액을 따로 정했나(513). 화면은 이 저장값만 본다 — 설정과 다시 비교하지 않는다
         t.fee_rule_custom,
         t.paypal_txn_id,
         t.memo,
         t.source,
         t.recorded_by,
         (SELECT a.name FROM public.admins a WHERE a.auth_id = t.recorded_by LIMIT 1),
         t.recorded_at,
         t.version,
         (t.sent_total_jpy + t.fee_jpy),
         -- [2] fee_stale — 487 머리말 규칙 그대로
         (t.fee_manual AND EXISTS (
            SELECT 1
              FROM public.settlement_transfer_events pe
             WHERE pe.transfer_id = t.id
               AND pe.action = 'correct'
               AND pe.prev ? 'sent_total_jpy'
               AND pe.next ? 'sent_total_jpy'
               AND (pe.prev ->> 'sent_total_jpy') IS DISTINCT FROM (pe.next ->> 'sent_total_jpy')
               AND pe.at > COALESCE((
                     SELECT max(fe.at)
                       FROM public.settlement_transfer_events fe
                      WHERE fe.transfer_id = t.id
                        AND (fe.action = 'create'
                             OR (fe.action = 'correct'
                                 AND NOT (fe.prev ? 'sent_total_jpy')
                                 AND (fe.prev ->> 'fee_jpy') IS DISTINCT FROM (fe.next ->> 'fee_jpy')))
                   ), '-infinity'::timestamptz)
         )),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'settlement_id',   ti.settlement_id,
                    'application_id',  s.application_id,
                    'campaign_id',     s.campaign_id,
                    'campaign_no',     c.campaign_no,
                    'campaign_title',  c.title,
                    'amount_jpy',      ti.amount_jpy,
                    'due_date',        public._settlement_payout_due(s.cert_at),
                    'cert_at',         s.cert_at,
                    'is_current',      (ti.revert_event_id IS NULL),
                    'revert_event_id', ti.revert_event_id
                  ) ORDER BY ti.created_at, ti.id)
             FROM public.settlement_transfer_items ti
             JOIN public.settlements s ON s.id = ti.settlement_id
             LEFT JOIN public.campaigns c ON c.id = s.campaign_id
            WHERE ti.transfer_id = t.id
         ), '[]'::jsonb)
    FROM public.settlement_transfers t
    LEFT JOIN public.influencers i ON i.id = t.influencer_id
   WHERE (p_from IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date >= p_from)
     AND (p_to   IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date <= p_to)
   ORDER BY t.sent_at, t.id;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfers(date, date) IS
  '[516, 베이스 502] 송금 묶음 목록(+ fee_rule_custom)(송금일=일본 날짜 기준 기간, NULL=열림). 묶음 1줄 + items(포함 건: 캠페인·연결 금액·원래 지급 예정일·현재 연결 여부) + fee_stale + 추정 표시(sent_at_estimated·fee_estimated) + fee_rule_jpy(스냅샷 규칙 계산값, 스냅샷 없으면 NULL). '
  '정렬 sent_at,id 유일. 페이팔 주소 미노출. fee_stale 규칙은 487 머리말 [2].';

REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfers(date, date) TO authenticated;

COMMIT;

-- 검증(관리자 콘솔): (await db.rpc('get_settlement_transfers',{p_from:null,p_to:null})).data[0]  → fee_rule_custom 칸이 있다
