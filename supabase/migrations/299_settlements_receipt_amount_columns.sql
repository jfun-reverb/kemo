-- ============================================================
-- 299_settlements_receipt_amount_columns.sql
-- 리뷰어형 정산 금액을 영수증 실결제액 기준으로 전환 — 1/2 (settlements 표 확장)
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-1, §3-2 마이그레이션①
--
-- ── 배경 ──
--   261·262·264 는 리뷰어형(monitor) 정산 금액을 "캠페인 상시가(campaigns.product_price)"
--   로 정의했다. 그런데 운영 실측(2026-08-05) 결과 실제 페이팔 송금은 대체로(리뷰어형
--   204건 중 177건, 약 94%) "영수증에 적힌 실제 결제 금액"이었고, 시스템 계산·화면
--   문구만 상시가였다. 이 작업은 정산 금액 산정 규칙을
--     리뷰어형(monitor, 가구매 proxy_purchase 포함) = min(영수증 실결제액, 캠페인 상시가)
--   로 바꾼다. 실제 계산 로직 교체는 다음 마이그레이션(300)에서 헬퍼·함수 3개를 동시에
--   재정의하며 처리한다 — 이 파일 단독으로는 기존 동작(전부 product_price 기준)에
--   아무 변화도 없다(컬럼 추가 + CHECK 확장만).
--
-- ── amount_source 값 4종째 추가(사양서 §3-1, §3-2) ──
--   기존 3종(261): 'reward' | 'product_price' | 'product_plus_reward'
--   신규 1종:       'receipt_amount' — 리뷰어형(monitor, 가구매 포함). 영수증 실결제액을
--     캠페인 상시가로 상한을 씌운 값. 다음 마이그레이션(300)부터 이 값을 실제로 만들어낸다.
--   ⚠️ 기존 'product_price' 값은 CHECK 에서 제거하지 않는다 — 운영에 이미 이 값으로
--   저장된 행(2026-08-05 실측 1건)이 있고, 217/261 스냅샷 원칙(생성 시점 값 고정)에 따라
--   과거 행은 재계산하지 않으므로 과거 값 그대로 유효해야 한다.
--
-- ── 감사용 칸 2개 추가(사양서 §3-2·§3-4) ──
--   receipt_amount_jpy — 정산 생성 시점 영수증 원금액(엔, 소수는 버림). 리뷰어형만 값이
--     들어가고 시딩·방문형은 NULL(현행 그대로 reward 기준이라 "영수증"이라는 개념이 없음).
--   amount_cap_jpy      — 정산 생성 시점 적용된 상한(캠페인 product_price 스냅샷). 마찬가지로
--     리뷰어형만 값이 들어가고 시딩·방문형은 NULL.
--   두 칸을 함께 남기는 이유 — 관리자 화면(2단계, 이번 범위 밖)이 "영수증 2,300엔 → 상한
--   적용 2,000엔 지급"처럼 원금액과 잘린 사실을 함께 보여줄 수 있어야 하기 때문(사양서
--   §3-4 "왜 1,500엔인가"를 화면이 바로 설명할 수 있어야 한다). amount_jpy 자체는
--   min(receipt_amount_jpy, amount_cap_jpy) 를 버림한 값과 같아야 하지만, 세 컬럼 사이에
--   DB 단의 CHECK 정합 제약은 걸지 않는다(217 이 amount_jpy 자체에도 그런 제약이 없고,
--   함수 쪽(300)에서 항상 세 값을 함께 계산·저장하므로 어긋날 경로가 없다).
--
-- ── 기존 행 백필 없음(사양서 §3-2 명시) ──
--   운영 실측(2026-08-05) 결과 정산행은 204건이 전부 이미 송금완료(paid) 상태이고
--   대기(pending) 행은 0건이다(§1-5) — 되돌리거나 재계산할 금액 스냅샷 자체가 없으므로
--   기존 행의 새 칸 2개는 NULL 로 남겨 둔다(217 스냅샷 원칙: 생성 시점 값 고정 유지).
--
-- ── 행 단위 보안 정책(RLS)·권한 변경 없음 ──
--   컬럼 추가만이라 217 이 만든 정책(settlements_select_own/settlements_select_admin)
--   그대로 유효. GRANT/REVOKE 변경 없음.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. 칸 2개 추가
-- ============================================================
ALTER TABLE public.settlements
  ADD COLUMN IF NOT EXISTS receipt_amount_jpy bigint,
  ADD COLUMN IF NOT EXISTS amount_cap_jpy      bigint;

COMMENT ON COLUMN public.settlements.receipt_amount_jpy IS
  '[299] 정산 생성 시점 영수증 원금액(엔, 소수는 버림) 스냅샷 — amount_source=''receipt_amount''(리뷰어형)인 '
  '행에서만 값이 있고, 그 외(reward/product_price/product_plus_reward)는 NULL. 관리자 화면이 '
  '"영수증 N엔 → 상한 적용 M엔 지급"을 설명하는 데 쓰는 감사용 칸(마이그레이션 300부터 실제 값 채움).';
COMMENT ON COLUMN public.settlements.amount_cap_jpy IS
  '[299] 정산 생성 시점 적용된 상한(캠페인 product_price) 스냅샷 — amount_source=''receipt_amount''(리뷰어형)인 '
  '행에서만 값이 있고, 그 외는 NULL. amount_jpy = LEAST(receipt_amount_jpy, amount_cap_jpy) 를 버림한 값과 '
  '같아야 하나 DB 단 CHECK 정합 제약은 두지 않음(계산은 항상 마이그레이션 300 헬퍼 한 곳에서만 발생).';

-- ============================================================
-- 2. amount_source CHECK 제약 확장 — 4종째('receipt_amount') 추가
--    기존 제약 재사용 대신 DROP → ADD 로 재실행 안전성 확보(261 과 동일 패턴)
-- ============================================================
ALTER TABLE public.settlements
  DROP CONSTRAINT IF EXISTS settlements_amount_source_check;
ALTER TABLE public.settlements
  ADD CONSTRAINT settlements_amount_source_check
  CHECK (amount_source IS NULL OR amount_source IN (
    'reward', 'product_price', 'product_plus_reward', 'receipt_amount'
  ));

COMMENT ON COLUMN public.settlements.amount_source IS
  '[299 갱신, 261 원본] 정산 금액(amount_jpy)의 출처 구분. '
  '''reward''(시딩·방문형 — campaigns.reward, 현행 그대로) | '
  '''product_price''(261~264 기간 리뷰어형에서 쓰던 옛 규칙 — campaigns.product_price. 과거 저장된 행 '
  '호환용, 마이그레이션 300 이후로는 새로 만들어지지 않음) | '
  '''product_plus_reward''(제품가격+현금보수 합산 — 스키마만 예비, 계산 미구현) | '
  '''receipt_amount''(299·300 신규 — 리뷰어형 monitor, 가구매 포함: 영수증 실결제액을 캠페인 상시가로 '
  '상한을 씌운 값. receipt_amount_jpy·amount_cap_jpy 두 칸에 원금액·상한을 함께 기록). '
  'NULL 허용은 261 적용 전 기존 행 호환용.';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 칸 추가 확인
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'settlements'
  AND column_name IN ('receipt_amount_jpy', 'amount_cap_jpy');

-- [V1] CHECK 제약 확인 (4종 허용 문자열이 보이는지)
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.settlements'::regclass
  AND conname = 'settlements_amount_source_check';

-- [V2] 기존 행 무변화 확인 (새 칸은 전부 NULL 이어야 함 — 이 마이그레이션은 계산을 하지 않는다)
SELECT count(*) AS total,
       count(*) FILTER (WHERE receipt_amount_jpy IS NOT NULL) AS receipt_amount_not_null,
       count(*) FILTER (WHERE amount_cap_jpy IS NOT NULL)     AS amount_cap_not_null
FROM public.settlements;
-- 기대: receipt_amount_not_null = 0, amount_cap_not_null = 0 (전부 이 마이그레이션 이전 행이므로)

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ **300 을 먼저 되돌린 뒤에 이 파일을 되돌린다.** 300 의 함수들이 여기서 만든
--    칸 2개(receipt_amount_jpy·amount_cap_jpy)에 INSERT 하므로, 이 파일만 먼저
--    되돌리면 그 함수들이 그 자리에서 실패한다. 순서: 300 롤백 → 299 롤백.
-- ALTER TABLE public.settlements DROP CONSTRAINT IF EXISTS settlements_amount_source_check;
-- ALTER TABLE public.settlements
--   ADD CONSTRAINT settlements_amount_source_check
--   CHECK (amount_source IS NULL OR amount_source IN ('reward', 'product_price', 'product_plus_reward'));
-- ALTER TABLE public.settlements DROP COLUMN IF EXISTS amount_cap_jpy;
-- ALTER TABLE public.settlements DROP COLUMN IF EXISTS receipt_amount_jpy;
-- -- COMMENT 는 261 원본 문구로 되돌리려면 261_settlements_amount_source.sql 의
-- -- COMMENT ON COLUMN public.settlements.amount_source 문을 다시 실행할 것.
