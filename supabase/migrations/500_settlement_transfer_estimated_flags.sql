-- 500_settlement_transfer_estimated_flags.sql
-- 정산 송금 묶음 — 「송금일 추정」·「수수료 추정」 표시 칸 2개 (시트 소급 반영 1/3)
-- 사양서: docs/specs/2026-10-01-settlement-sheet-backfill.md 설계 ① (가) · 결정 2·3·5
-- 작업표: docs/specs/2026-10-02-settlement-sheet-backfill-breakdown.md 「S1」
--
-- 선행: 485(settlement_transfers 표). 이 파일은 칸 2개만 더한다(함수 변경 없음).
-- 짝: 501(소급 함수 — 이 칸을 채운다) · 502(정정 함수가 이 칸을 지운다 + 조회 3개가 이 칸을 돌려준다)
--
-- ▶ 의미
--   sent_at_estimated = true : 송금일(sent_at)을 시트에서 못 찾아 그 탭의 회차 지급일로 채웠다(실제 송금일이 아님).
--   fee_estimated     = true : 수수료(fee_jpy)를 시트 합산 줄에서 못 찾아 규칙(484)으로 계산해 채웠다(실제 수수료가 아님).
--   🔴 「추정」은 값을 모른다는 뜻이 아니라 규칙·회차로 채웠다는 뜻이다. 총지출 합계에는 들어간다.
--   기존 행은 전부 false — 화면(앱)으로 기록한 묶음은 실제값이다.
--
-- ▶ 재실행 안전 — ADD COLUMN IF NOT EXISTS. 기존 행은 DEFAULT false 로 채워진다(표를 다시 쓰지 않는 즉시 처리).
--
-- 롤백 (🔴 502·501 을 먼저 되돌린 뒤에만 — 502 의 조회·정정 함수와 501 이 이 칸을 부른다):
--   ALTER TABLE public.settlement_transfers DROP COLUMN IF EXISTS fee_estimated;
--   ALTER TABLE public.settlement_transfers DROP COLUMN IF EXISTS sent_at_estimated;
--   ⚠️ 칸을 지우면 그 칸에 쌓인 추정 표시가 사라진다 — 소급을 이미 한 환경에서는 되돌리지 말 것.

BEGIN;

ALTER TABLE public.settlement_transfers
  ADD COLUMN IF NOT EXISTS sent_at_estimated boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS fee_estimated     boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.settlement_transfers.sent_at_estimated IS
  '[500] true = 송금일(sent_at)이 추정값(시트에 실제 송금일이 없어 그 탭의 회차 지급일로 채움). 시트 소급(501)만 true 로 만든다. 정정 함수(502)에 송금일을 넘기면 false 로 지워진다.';
COMMENT ON COLUMN public.settlement_transfers.fee_estimated IS
  '[500] true = 수수료(fee_jpy)가 추정값(시트 합산 줄이 없어 규칙 484 로 계산). 시트 소급(501)만 true 로 만든다. 정정 함수(502)에 수수료를 넘기면 false 로 지워진다.';

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩 — 각 단계 결과를 확인하고 다음으로)
-- [1] 칸 2개가 있고 NOT NULL · 기본값 false
--   SELECT column_name, data_type, is_nullable, column_default
--     FROM information_schema.columns
--    WHERE table_schema = 'public' AND table_name = 'settlement_transfers'
--      AND column_name IN ('sent_at_estimated', 'fee_estimated');
--   -- 2행, is_nullable = NO, column_default = false
-- [2] 기존 행에 추정 표시가 하나도 없다 (S1 완료 정의)
--   SELECT count(*) FROM public.settlement_transfers WHERE sent_at_estimated OR fee_estimated;   -- 0
