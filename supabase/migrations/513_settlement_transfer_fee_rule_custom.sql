-- =============================================================================
-- 마이그레이션 513: 송금 묶음에 「이 송금만 요율을 따로 정했다」 칸
-- 사양서  : docs/specs/2026-10-02-settlement-per-transfer-fee-rule.md (설계 ① (가))
-- 작업표  : docs/specs/2026-10-08-settlement-per-transfer-fee-rule-breakdown.md (D1)
-- 대상    : 개발서버 → 운영서버. 514~517 보다 먼저
-- 위험도  : 낮음 — 칸 1개 추가(기본값 false). 기존 행 전부 false, 행 단위 보안 정책 그대로(485)
-- 편집기 경고: 안 뜸
--
-- 뜻: 그 송금의 수수료 근거(사본 3칸 fee_rate_percent·fee_fixed_jpy)가 「그 순간의 수수료 설정」과
--     요율·고정액이 달랐으면 true. 끝수(fee_rounding)는 비교하지 않는다(사양서 경우의 수 3).
--     세우는 곳은 기록(514)·정정(517)의 「이 송금 요율 직접 정하기」 저장뿐이다.
--
-- 되돌리기(514~517 을 먼저 되돌린 뒤에만 — 그 함수들이 이 칸을 쓴다. 편집기 경고 뜸, 「이 송금만」 표시가 사라진다):
--   ALTER TABLE public.settlement_transfers DROP COLUMN IF EXISTS fee_rule_custom;
-- =============================================================================

BEGIN;

ALTER TABLE public.settlement_transfers
  ADD COLUMN IF NOT EXISTS fee_rule_custom boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.settlement_transfers.fee_rule_custom IS
  '[513] 이 송금만 요율·고정액을 따로 정했다(저장 순간 수수료 설정과 요율·고정액이 다름 — 끝수는 비교 안 함). 기록 514·정정 517 의 「이 송금 요율 직접 정하기」 저장만 세운다';

COMMIT;

-- 검증: SELECT count(*) FILTER (WHERE fee_rule_custom) AS custom, count(*) AS total FROM public.settlement_transfers;  → custom 0
