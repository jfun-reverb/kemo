-- 485_settlement_transfers.sql
-- 정산 송금 묶음 (조각 2 — 송금 묶음·연결·묶음 이력 표 + settlements.current_transfer_id)
-- 사양서: docs/specs/2026-09-30-settlement-transfer-fee-record.md (D-1~D-5)
-- 작업표: docs/specs/2026-09-30-settlement-transfer-fee-record-breakdown.md 「조각 2」
--
-- 목적:
--   페이팔 송금 1건(= 여러 정산 건을 묶어 한 번에 보낸 거래)을 「송금 묶음」으로 기록한다.
--   묶음 = 송금일(정본)·합계·수수료·거래번호. 연결 표 = 묶음에 속한 정산 건과 건별 금액.
--   이 마이그레이션은 표·칸·조회 정책만 만든다. 함수(기록·정정·보류 해제 연동)는 다음 마이그레이션.
--
-- 🔴 페이팔 주소 칸을 두지 않는다:
--   363(5년 뒤 파기)은 influencers.paypal_email 과 settlements.paypal_email **두 곳만** 비운다.
--   묶음 표에 주소를 복사해 두면 파기 대상 밖에 개인정보 사본이 남는다. 주소는 정산 행 스냅샷을 따라간다.
--
-- 🔴 불변식 (표 제약으로 못 건다 — 다음 마이그레이션의 함수가 지킨다):
--   settlements.current_transfer_id 가 있으면
--     ① settlements.paid_at          = 그 묶음의 sent_at
--     ② settlements.paid_amount_jpy  = 그 건의 「현재 연결」(revert_event_id IS NULL) 금액
--   위반 조회는 아래 [검증 6] 참고.
--
-- 외래 키 ON DELETE 결정:
--   - settlement_transfers.influencer_id : RESTRICT.
--       settlements.influencer_id 는 217 에서 CASCADE 이나, 251 의 삭제 차단 장치
--       (trg_block_delete_with_settlements, influencers)가 정산 행이 있는 회원 삭제를 먼저 막는다.
--       금전 기록이므로 표 수준에서도 조용히 지워지지 않게 RESTRICT (CASCADE 를 그대로 따르면
--       차단 장치가 우회될 때 송금 기록까지 사라진다).
--   - items.transfer_id / items.settlement_id / items.revert_event_id / events.transfer_id,
--     settlements.current_transfer_id : RESTRICT (금전 감사 — 217 settlement_events 와 같은 원칙).
--   - recorded_by / actor : auth.users ON DELETE SET NULL (관리자 삭제 후에도 기록 유지 — 217·484 와 같음).
--
-- 권한: 세 표 모두 조회 has_permission('settlement.view','read'). 쓰기 정책 없음(함수만 쓴다).
--
-- 롤백 (다음 마이그레이션 함수가 적용된 뒤에는 그쪽을 먼저 되돌릴 것):
--   ALTER TABLE public.settlements DROP COLUMN IF EXISTS current_transfer_id;
--   DROP TABLE IF EXISTS public.settlement_transfer_events;
--   DROP TABLE IF EXISTS public.settlement_transfer_items;
--   DROP TABLE IF EXISTS public.settlement_transfers;
--   (새 표·새 칸뿐. 기존 settlements 값은 건드리지 않았으므로 데이터 손실 없음 — 단 새 표에 쌓인 기록은 사라진다)

BEGIN;

-- ============================================================
-- 1. 송금 묶음 (페이팔 거래 1건)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_transfers (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sent_at          timestamptz NOT NULL,                       -- 🔴 송금일의 정본
  influencer_id    uuid NOT NULL REFERENCES public.influencers(id) ON DELETE RESTRICT,
  sent_total_jpy   bigint NOT NULL
                     CONSTRAINT settlement_transfers_total_positive CHECK (sent_total_jpy > 0),
  fee_jpy          bigint NOT NULL
                     CONSTRAINT settlement_transfers_fee_nonneg CHECK (fee_jpy >= 0),
  fee_rate_percent numeric NULL,                               -- 계산 당시 규칙 스냅샷(484)
  fee_fixed_jpy    integer NULL,
  fee_rounding     text NULL
                     CONSTRAINT settlement_transfers_fee_rounding_check
                     CHECK (fee_rounding IS NULL OR fee_rounding IN ('round','floor','ceil')),
  fee_manual       boolean NOT NULL DEFAULT false,             -- 수동 입력이면 true(계산값과 같아도)
  paypal_txn_id    text NULL
                     CONSTRAINT settlement_transfers_txn_len CHECK (paypal_txn_id IS NULL OR char_length(paypal_txn_id) <= 100),
  memo             text NULL,
  source           text NOT NULL
                     CONSTRAINT settlement_transfers_source_check CHECK (source IN ('app','sheet_backfill')),
  recorded_by      uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  recorded_at      timestamptz NOT NULL DEFAULT now(),
  version          integer NOT NULL DEFAULT 1
);

COMMENT ON TABLE public.settlement_transfers IS
  '[485] 정산 송금 묶음(페이팔 거래 1건). sent_at 이 송금일 정본. 페이팔 주소 칸 없음(363 파기 대상 밖 사본 방지). 쓰기는 함수만.';
COMMENT ON COLUMN public.settlement_transfers.source IS
  'app = 화면에서 기록 / sheet_backfill = 지급대장(시트) 소급 입력. recorded_at 기준 「도입 시각」 계산에 app 만 쓴다.';

CREATE INDEX IF NOT EXISTS idx_settlement_transfers_sent_at_id
  ON public.settlement_transfers (sent_at, id);
CREATE INDEX IF NOT EXISTS idx_settlement_transfers_influencer_id
  ON public.settlement_transfers (influencer_id);
-- _settlement_transfer_intro_at() (후속 마이그레이션)이 「앱으로 처음 기록한 시각」을 찾는 데 쓴다
CREATE INDEX IF NOT EXISTS idx_settlement_transfers_recorded_at_app
  ON public.settlement_transfers (recorded_at) WHERE source = 'app';

-- ============================================================
-- 2. 연결 (묶음 ↔ 정산 건, 건별 금액)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_transfer_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id     uuid NOT NULL REFERENCES public.settlement_transfers(id) ON DELETE RESTRICT,
  settlement_id   uuid NOT NULL REFERENCES public.settlements(id) ON DELETE RESTRICT,
  amount_jpy      bigint NOT NULL
                    CONSTRAINT settlement_transfer_items_amount_positive CHECK (amount_jpy > 0),
  created_at      timestamptz NOT NULL DEFAULT now(),
  revert_event_id uuid NULL REFERENCES public.settlement_events(id) ON DELETE RESTRICT,
  CONSTRAINT settlement_transfer_items_transfer_settlement_uniq UNIQUE (transfer_id, settlement_id)
);

COMMENT ON TABLE public.settlement_transfer_items IS
  '[485] 송금 묶음에 속한 정산 건 연결. revert_event_id NULL = 현재 송금 기록, 값 = 그 보류 해제 이력에 속한 옛 송금(연결 행은 지우지 않는다).';

-- 한 정산 건에 「현재 송금 기록」은 하나뿐
CREATE UNIQUE INDEX IF NOT EXISTS uq_settlement_transfer_items_current
  ON public.settlement_transfer_items (settlement_id) WHERE revert_event_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_settlement_transfer_items_settlement_id
  ON public.settlement_transfer_items (settlement_id);

-- ============================================================
-- 3. 묶음 이력 (추가만)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_transfer_events (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transfer_id uuid NOT NULL REFERENCES public.settlement_transfers(id) ON DELETE RESTRICT,
  action      text NOT NULL
                CONSTRAINT settlement_transfer_events_action_check CHECK (action IN ('create','correct')),
  prev        jsonb NULL,
  next        jsonb NULL,
  memo        text NULL,
  actor       uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  actor_name  text NULL,
  at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.settlement_transfer_events IS
  '[485] 송금 묶음 변경 이력(추가만). 기록·정정 함수만 INSERT.';

CREATE INDEX IF NOT EXISTS idx_settlement_transfer_events_transfer_at
  ON public.settlement_transfer_events (transfer_id, at);

-- ============================================================
-- 4. settlements.current_transfer_id
-- ============================================================
ALTER TABLE public.settlements
  ADD COLUMN IF NOT EXISTS current_transfer_id uuid NULL
  REFERENCES public.settlement_transfers(id) ON DELETE RESTRICT;

COMMENT ON COLUMN public.settlements.current_transfer_id IS
  '[485] 이 정산 건의 「현재 송금 묶음」. NULL = 묶음 없음(옛 방식·미송금·보류 해제 후). '
  '불변식: 값이 있으면 paid_at = 묶음.sent_at, paid_amount_jpy = 현재 연결(revert_event_id IS NULL) 금액. '
  '표 제약이 아니라 다음 마이그레이션의 기록·정정·보류 해제 함수가 지킨다.';

CREATE INDEX IF NOT EXISTS idx_settlements_current_transfer_id
  ON public.settlements (current_transfer_id) WHERE current_transfer_id IS NOT NULL;

-- ============================================================
-- 5. 행 단위 보안 정책 — 조회만, 쓰기 정책 없음 (484·230 과 같은 형태)
-- ============================================================
ALTER TABLE public.settlement_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_transfer_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.settlement_transfer_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS settlement_transfers_select ON public.settlement_transfers;
CREATE POLICY settlement_transfers_select ON public.settlement_transfers
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

DROP POLICY IF EXISTS settlement_transfer_items_select ON public.settlement_transfer_items;
CREATE POLICY settlement_transfer_items_select ON public.settlement_transfer_items
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

DROP POLICY IF EXISTS settlement_transfer_events_select ON public.settlement_transfer_events;
CREATE POLICY settlement_transfer_events_select ON public.settlement_transfer_events
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩)
-- ⚠️ SQL 편집기는 서비스 키라 정책 분기가 안 돈다 → [5] 는 로그인한 관리자 브라우저 콘솔에서.
-- ============================================================
-- [1] SQL 편집기: 새 표 0행
--   SELECT (SELECT count(*) FROM public.settlement_transfers)       AS transfers,
--          (SELECT count(*) FROM public.settlement_transfer_items)  AS items,
--          (SELECT count(*) FROM public.settlement_transfer_events) AS events;   -- 0 / 0 / 0
-- [2] SQL 편집기: 기존 정산 행 전부 current_transfer_id NULL
--   SELECT count(*) AS total, count(current_transfer_id) AS with_transfer FROM public.settlements;  -- with_transfer = 0
-- [3] SQL 편집기: 정책·RLS 확인 (세 표 모두 rowsecurity=true, SELECT 정책 1개씩, 쓰기 정책 0)
--   SELECT tablename, policyname, cmd FROM pg_policies
--    WHERE tablename IN ('settlement_transfers','settlement_transfer_items','settlement_transfer_events');
-- [4] SQL 편집기: 색인 확인 (부분 유일 색인 uq_settlement_transfer_items_current 포함)
--   SELECT indexname FROM pg_indexes
--    WHERE tablename LIKE 'settlement_transfer%' OR indexname = 'idx_settlements_current_transfer_id';
-- [5] 브라우저(정산 조회 권한 관리자):
--   (await db.from('settlement_transfers').select('id')).data      -- [] , error null
-- [6] (조각 4·5 함수 적용 뒤 사용 — 지금은 0 이어야 정상) 불변식 위반 점검
--   SELECT
--     count(*) FILTER (WHERE it.id IS NULL)                                   AS missing_current_item,
--     count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_at IS DISTINCT FROM t.sent_at)    AS paid_at_mismatch,
--     count(*) FILTER (WHERE it.id IS NOT NULL AND s.paid_amount_jpy IS DISTINCT FROM it.amount_jpy) AS amount_mismatch
--     FROM public.settlements s
--     JOIN public.settlement_transfers t ON t.id = s.current_transfer_id
--     LEFT JOIN public.settlement_transfer_items it
--            ON it.settlement_id = s.id AND it.transfer_id = s.current_transfer_id AND it.revert_event_id IS NULL
--    WHERE s.current_transfer_id IS NOT NULL;                                  -- 세 값 모두 0
