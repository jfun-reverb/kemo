-- ============================================================
-- 261_settlements_amount_source.sql
-- 정산 금액 산정 규칙 변경 PR1 — 1/2 (금액 구분 칸 추가)
-- 사양서: docs/specs/2026-07-23-settlement-reviewer-receipt-amount.md §3-1, §3-2 마이그레이션①
--
-- ── 배경 ──
--   217_settlements_schema.sql 은 정산 금액(amount_jpy)을 "생성 시점
--   campaigns.reward 스냅샷" 한 가지로만 정의했다. 그런데 리뷰어형(monitor)
--   캠페인은 실무상 현금 리워드(reward)가 아니라 제품 가격(product_price)을
--   페이백하는 구조라, reward=0 인 리뷰어형 캠페인 57개(승인 응모 1,065건)가
--   정산 후보에서 통째로 빠져 있었다(2026-07-23 운영 실측).
--
--   이 마이그레이션은 "금액이 어느 값에서 나왔는지"를 나중에 구분할 수 있도록
--   settlements 에 칸 2개만 먼저 추가한다. 실제 계산 로직 교체는 다음
--   마이그레이션(262)에서 판정 헬퍼·함수 3개를 동시에 재정의하며 처리한다 —
--   이 파일 단독으로는 기존 동작(전부 reward 기준)에 아무 변화도 없다.
--
-- ── amount_source 값 3종(사양서 §3-1) ──
--   'reward'              — 시딩(gifting)·방문형(visit). 현행 그대로(변경 없음).
--   'product_price'        — 리뷰어형(monitor, 가구매 여부 무관). 이번에 신설.
--   'product_plus_reward'  — 제품 가격 + 현금 보수 합산(§6 Q1, 사용자 확인 보류).
--     이번 마이그레이션·다음 마이그레이션(262) 모두 이 값을 실제로 만들어내지
--     않는다(계산 로직 미구현) — 값 칸과 CHECK 제약만 미리 열어 둔다. 나중에
--     합산을 채택할 때 스키마 변경 없이 262 함수 본문만 고치면 되도록 하기 위함.
--
-- ── reward_part_jpy(사양서 §3-1) ──
--   합산(product_plus_reward)을 채택했을 때 그중 현금 보수 부분만 별도로
--   기록하기 위한 칸. 지금은 항상 NULL(합산 미구현이므로 값이 생길 일이 없음).
--
-- ── 기존 행 백필 ──
--   지금 시점 settlements 에 이미 있는 행은 전부 217 원본 규칙(campaigns.reward
--   스냅샷)으로 만들어졌으므로 amount_source='reward' 로 채운다(사양서 §3-2).
--   운영 실측상 정산행이 사실상 없어(리뷰어형 전량 누락 상태) 백필 대상은
--   0건에 가깝지만, 시딩형 소수 건(예: B0032-C002)이 있을 수 있어 안전하게
--   UPDATE 를 실행한다.
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
  ADD COLUMN IF NOT EXISTS amount_source text,
  ADD COLUMN IF NOT EXISTS reward_part_jpy bigint;

-- CHECK 제약은 별도 문으로(컬럼이 이미 있는 재실행 시에도 안전하게 걸리도록
-- 기존 동명 제약을 먼저 제거 후 추가 — ALTER TABLE ADD COLUMN 에 인라인 CHECK 를
-- 쓰면 IF NOT EXISTS 재실행 시 제약 중복 추가 에러가 날 수 있어 분리했다).
ALTER TABLE public.settlements
  DROP CONSTRAINT IF EXISTS settlements_amount_source_check;
ALTER TABLE public.settlements
  ADD CONSTRAINT settlements_amount_source_check
  CHECK (amount_source IS NULL OR amount_source IN ('reward', 'product_price', 'product_plus_reward'));

COMMENT ON COLUMN public.settlements.amount_source IS
  '[261] 정산 금액(amount_jpy)의 출처 구분. '
  '''reward''(시딩·방문형 — campaigns.reward, 현행 규칙) | '
  '''product_price''(리뷰어형 monitor, 가구매 포함 — campaigns.product_price, 마이그262부터 신설) | '
  '''product_plus_reward''(제품가격+현금보수 합산 — 스키마만 예비, 계산 미구현·§6 Q1 보류). '
  'NULL 허용은 261 적용 전 기존 행 호환용(같은 마이그레이션에서 즉시 reward 로 백필됨).';
COMMENT ON COLUMN public.settlements.reward_part_jpy IS
  '[261] amount_source=''product_plus_reward'' 로 합산했을 때 그중 현금 보수(campaigns.reward) '
  '부분만 별도 기록하는 칸. 합산 계산이 아직 구현되지 않아 현재는 항상 NULL.';

-- ============================================================
-- 2. 기존 행 백필 — 217 원본 규칙(전부 reward 스냅샷)으로 생성된 행이므로 'reward' 고정
-- ============================================================
UPDATE public.settlements
SET amount_source = 'reward'
WHERE amount_source IS NULL;

-- ============================================================
-- 3. 테이블 주석 갱신 — "생성 시점 campaigns.reward 스냅샷" 단정 문구를
--    "모집 형식별 산정 규칙" 으로 교체(217 COMMENT ON TABLE 재작성)
-- ============================================================
COMMENT ON TABLE public.settlements IS
  '[217, 261 금액 규칙 갱신] 인플루언서 리워드 정산. 1 응모(application) = 1행 '
  '(application_id UNIQUE, 멱등). backfill_settlements() RPC(마이그레이션 218→232→262)가 '
  '인증 성공 응모를 UPSERT 생성. '
  '금액(amount_jpy)은 생성 시점 스냅샷(엔화) — 모집 형식별로 출처가 다르다(amount_source 참고): '
  '리뷰어형(monitor, 가구매 포함)=campaigns.product_price / 시딩·방문형=campaigns.reward. '
  '캠페인 값을 사후 변경해도 기존 정산행은 불변(스냅샷 원칙 유지).';
COMMENT ON COLUMN public.settlements.amount_jpy IS
  '엔화(¥). 원천징수 없음·전액 지급(약관 제13조). 생성 시점 스냅샷 — 출처는 amount_source '
  '참고(리뷰어형=campaigns.product_price / 시딩·방문형=campaigns.reward, 마이그레이션 261·262).';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 칸 추가 확인
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'settlements'
  AND column_name IN ('amount_source', 'reward_part_jpy');

-- [V1] CHECK 제약 확인
SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.settlements'::regclass
  AND conname = 'settlements_amount_source_check';

-- [V2] 기존 행 백필 확인 (전부 'reward' 여야 함 — 262 적용 전까지는 이 상태 유지)
SELECT amount_source, count(*) FROM public.settlements GROUP BY amount_source;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ALTER TABLE public.settlements DROP CONSTRAINT IF EXISTS settlements_amount_source_check;
-- ALTER TABLE public.settlements DROP COLUMN IF EXISTS reward_part_jpy;
-- ALTER TABLE public.settlements DROP COLUMN IF EXISTS amount_source;
-- -- 주석은 217 원본 COMMENT ON TABLE/COLUMN 문을 재실행해 되돌릴 것(파일 상단 참고)
