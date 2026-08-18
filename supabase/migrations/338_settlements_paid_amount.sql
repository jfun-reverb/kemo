-- ============================================================
-- 338_settlements_paid_amount.sql
-- 실제로 보낸 금액을 담을 칸 (정산 3단계 · 사양서 §4-3 마이그레이션 B)
--
-- ▶ 왜 필요한가
--   지금 `settlements` 는 **시스템이 계산한 금액**(`amount_jpy`)만 갖고 있고,
--   **실제로 얼마를 보냈는지**를 적을 자리가 없다. 그래서 계산값과 다른 금액을 보낸
--   경우 그 사실이 어디에도 안 남는다.
--   운영 실측(2026-08-18): 리뷰어형 저장분 189건 중 177건이 영수증 금액과 일치했고
--   **어긋난 12건**은 2026-05 사람 손 작업 오차였다 — 그런 건을 기록할 자리다.
--
-- ▶ NULL 의 뜻 — 「시스템 계산값과 같음」
--   대부분은 계산값 그대로 보낸다. 그때마다 같은 값을 두 칸에 적으면 낭비이고,
--   두 값이 어긋났을 때 **어느 쪽이 사실인지** 알기 어려워진다.
--   ⚠️ 그래서 `NULL` 을 「0원을 보냈다」로 읽으면 안 된다. 화면·조회가 이 뜻을 지켜야 한다.
--
-- ⚠️ **`amount_jpy` 를 덮어쓰지 않는다.** 그 값은 계산 근거(영수증 금액 `receipt_amount_jpy`·
--    상한 `amount_cap_jpy`·출처 `amount_source`)와 **짝을 이루는 스냅샷**이다. 덮으면
--    「왜 그 금액인가」를 설명할 수 없게 된다. 두 값이 다르면 화면이 **나란히** 보여준다.
--
-- ⚠️ **낙관적 잠금 제외 목록에 넣지 않는다.** 확인 결과 `settlements` 는 캠페인 표와 달리
--    **트리거로 version 을 올리지 않고** 각 함수가 `version = version + 1` 로 직접 올린다
--    (222·223·224). 즉 제외 목록이라는 것 자체가 없고, 이 칸은 자연히 보호 대상이다.
--    ⚠️ 나중에 트리거 방식으로 바꾸더라도 **이 칸을 제외 목록에 넣지 말 것** — 금액이
--    바뀌었는데 version 이 그대로면 두 관리자가 서로의 정정을 조용히 덮는다.
--
-- ▶ 이 마이그레이션만으로는 값이 안 들어간다
--   쓰는 경로는 C(`mark_settlement_paid` 인자 추가)와 E(`correct_settlement_payment`)다.
--   여기서는 **칸만** 만든다. 기존 행은 전부 `NULL`(= 계산값과 같음)로 시작한다.
--
-- ⚠️ 번호 안내 — 334~338 사용. 332·333 은 iOS 작업 폴더가 자기 번호로 점유 중이라 비움.
--    다음 사람은 339 부터 쓸 것.
-- ============================================================

ALTER TABLE public.settlements
  ADD COLUMN IF NOT EXISTS paid_amount_jpy bigint NULL;

COMMENT ON COLUMN public.settlements.paid_amount_jpy IS
  '실제로 보낸 금액(엔). NULL = 시스템 계산값(amount_jpy)과 같음 — 0원이 아니다. '
  'amount_jpy 는 계산 근거와 짝을 이루는 스냅샷이라 덮지 않고, 두 값이 다르면 화면이 나란히 보여준다. '
  '쓰는 경로는 mark_settlement_paid(마이그레이션 C)와 correct_settlement_payment(E).';

-- ⚠️ CHECK 를 걸지 않는 이유
--   `amount_jpy` 는 `CHECK(amount_jpy > 0)` 이지만 이 칸은 **NULL 이 정상값**이고,
--   「계산값보다 크다/작다」를 제약으로 못 박으면 **정당한 정정을 막는다**
--   (환율·수수료 차감으로 적게 보낸 건, 반대로 이전 회차를 합쳐 보낸 건 둘 다 있다).
--   금액의 타당성은 사람이 판단하고 `settlement_events` 에 사유가 남는다.

-- ── 적용 후 확인 ────────────────────────────────────────────
-- [1] 칸이 생겼고 기존 행이 전부 NULL 인가 (기대: total = nulls, non_null = 0)
--   SELECT count(*) AS total,
--          count(*) FILTER (WHERE paid_amount_jpy IS NULL) AS nulls,
--          count(paid_amount_jpy)                          AS non_null
--     FROM public.settlements;
--
-- [2] 자료형·NULL 허용 확인 (기대: bigint / YES)
--   SELECT data_type, is_nullable
--     FROM information_schema.columns
--    WHERE table_schema='public' AND table_name='settlements'
--      AND column_name='paid_amount_jpy';
--
-- ⚠️ 이 마이그레이션은 함수를 안 만들므로 「첫 호출에서 터지는」 유형(42804)은 없다.
--    다만 **화면이 이 칸을 읽기 시작하는 것은 작업 6부터**다 — 그 전에는 아무 변화가 없다.
--
-- 롤백: ALTER TABLE public.settlements DROP COLUMN IF EXISTS paid_amount_jpy;
--   ⚠️ 값이 들어간 뒤에 되돌리면 **실제 송금액 기록이 사라진다.** C·E 가 적용된 뒤에는
--      이 롤백을 쓰지 말 것(그때는 값을 옮겨 담을 곳을 먼저 만들어야 한다).
