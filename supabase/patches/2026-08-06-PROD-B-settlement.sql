-- ═══════════════════════════════════════════════════════════════
-- 운영 배포 묶음 B — 정산 영수증 기준 전환 (마이그레이션 299~303)
-- 만든 날짜: 2026-08-06
--
-- ⚠️ 묶음 A 를 먼저 적용한 뒤 실행합니다.
-- ⚠️ 이 묶음은 리뷰어형 정산 금액을 「영수증 실결제액(상시가 상한)」으로 바꿉니다.
--    사양서(2026-08-05-settlement-receipt-amount-switch.md §3-6)가 걸어 둔
--    사전 통지·재동의 법률 확인은 2026-08-06 사용자 결정으로 생략하고 배포합니다.
-- ═══════════════════════════════════════════════════════════════


-- ───────────────────────────────────────────────────────────────
-- [파일 299] 299_settlements_receipt_amount_columns.sql
-- ───────────────────────────────────────────────────────────────
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


-- ───────────────────────────────────────────────────────────────
-- [파일 300] 300_settlement_amount_receipt_basis.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 300_settlement_amount_receipt_basis.sql
-- 리뷰어형 정산 금액을 영수증 실결제액 기준으로 전환 — 2/2
--   (헬퍼 재정의 + 호출 함수 3개 동시 재정의, 한 파일·한 트랜잭션)
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-1, §3-2 마이그레이션②
--
-- ⚠️ **299 를 먼저 적용해야 한다.** 이 파일의 저장 함수들이 299 가 만드는 칸 2개
--    (receipt_amount_jpy·amount_cap_jpy)에 INSERT 하므로, 299 없이 실행하면 그 자리에서
--    실패한다. 적용 순서: 299 → 300 → 301. 롤백 순서는 그 역순.
--
-- ── 이 마이그레이션이 하는 일 ──
--   리뷰어형(monitor, 가구매 proxy_purchase 포함) 정산 금액 산정을
--     "campaigns.product_price 그대로"(261~264)
--   에서
--     "min(그 응모의 최신 영수증 purchase_amount, campaigns.product_price), 소수는 버림"
--   으로 바꾼다. 시딩(gifting)·방문형(visit)은 이번에도 변경 없음(campaigns.reward 그대로).
--
--   "어느 영수증인가" = 인증 성공 판정에 이미 쓰이고 있는 바로 그 최신 영수증 행
--   (receipt_latest, 아래 CTE). 별도 조건으로 다른 행을 고르지 않는다 — 판정과 금액이
--   다른 행을 가리키면 §3-1 "판정·금액 단일 소스" 원칙이 깨진다. 인증 성공 건은 정의상
--   이 행이 approved 상태다.
--
-- ── 이 함수의 "현재 유효한 원본"은 264 다(전수 확인, 사양서 §1-1) ──
--   grep -rl "_settlement_cert_candidates" supabase/migrations/ 결과 이 함수를
--   정의/재정의한 파일은 232 → 262 → 264 세 곳. 264 가 gifting·visit 무보수 캠페인을
--   후보에서 제외하는 WHERE 조건을 추가했으므로, **이 조건을 반드시 그대로 유지**한다
--   (아래 candidates CTE 참고 — 262 원본에는 없던 조건).
--   backfill_settlements() 의 "현재 유효한 원본"은 262 다(242 의 알림 잠금 게이트를
--   계승한 버전). 이 마이그레이션도 그 게이트(v_notify := is_settlement_public())를
--   그대로 유지한다 — 절대 제거하지 말 것(262 파일 자체의 경고 문구와 동일 함정 구간).
--
-- ── 이 마이그레이션이 바꾸는 것(요약) ──
--   1) receipt_latest CTE 가 purchase_amount 도 함께 가져온다(SELECT 목록에 1컬럼 추가.
--      DISTINCT ON/ORDER BY 는 완전히 그대로 — 어느 행이 "최신"인지 판정은 무변경).
--   2) 헬퍼 반환 테이블에 receipt_amount_jpy·amount_cap_jpy 2컬럼 추가(299 가 만든 감사용
--      칸을 채우기 위한 계산값. 관리자 화면 "영수증 N엔 → 상한 적용 M엔" 표시는 2단계 —
--      이번엔 값만 계산해 반환·저장한다).
--   3) 금액 계산 CASE 문 — 리뷰어형만 product_price 단독 참조에서
--      min(영수증, 상시가) 절사로 교체. 시딩·방문형은 CASE 문 자체가 그대로(cd.reward).
--   4) amount_issue 판정 조건 3종 추가(사양서 §3-1·§3-2):
--        ㉮ 영수증 결제 금액(purchase_amount) 없음/0 이하
--        ㉯ 상한(product_price) 없음/0 이하
--        ㉰ 위 둘 다 있어도 버림 결과가 0 이하(예: 0.5엔처럼 극단적으로 작은 값)
--      ⚠️ ㉰ 을 빠뜨리면 0 이하 금액이 저장 대상에 남아 CHECK(amount_jpy>0) 위반으로
--      배치 INSERT 전체가 실패한다(262 가 이미 겪은 함정과 같은 종류).
--   5) receipt_amount_jpy·amount_cap_jpy 를 backfill_settlements()·
--      register_past_settlements() 의 INSERT 문에도 함께 저장한다.
--
-- ── 절대 바꾸지 않는 것(인증 성공 판정, 사양서 §3-2 강조) ──
--   receipt_latest 의 DISTINCT ON/ORDER BY(어느 행이 "최신"인지), post_latest·
--   review_channel_latest·channel_cert CTE, is_success·cert_at 의 CASE 문 — 전부 264
--   원본을 한 글자도 안 바꾸고 그대로 복사했다. 화면 dev/js/admin-deliverables.js 의
--   computeCertStatus() 와의 단일 소스 정합을 유지하기 위함. receipt_latest 에 컬럼을
--   1개 추가하는 것은 "어느 행을 최신으로 볼지"에 영향을 주지 않는다(SELECT 목록만
--   늘어날 뿐 WHERE/ORDER BY 는 무변경).
--   변경하지 않는 것(그 외): candidates CTE 의 264 제외 조건(gifting·visit 무보수),
--   정산 도입일 컷오프 조건, PayPal 미등록 알림의 인플루언서 노출 잠금 게이트,
--   이력(settlement_events) 기록, 과거 수동 등록의 "알림 없음" 원칙, 권한 게이트
--   (has_permission), 낙관적 락·동시성 처리.
--
-- ── ⚠️ LEAST()/GREATEST() 의 NULL 무시 동작 주의 ──
--   PostgreSQL 의 LEAST(a, b) 는 "값이 하나라도 NULL 이면 NULL"이 아니라 "NULL 은
--   무시하고 남은 값 중 최소"를 반환한다(둘 다 NULL 일 때만 NULL). 즉
--   LEAST(NULL, 1000) 은 NULL 이 아니라 1000 이 된다. 이 성질을 모르고 그냥
--   LEAST(rl.purchase_amount, cd.product_price) 를 쓰면, 영수증 금액이 없는 건이
--   "상시가로 조용히 대체"되어 예전(261~264) 버그가 반대 방향으로 재현된다. 그래서
--   아래 CASE 문은 LEAST 를 부르기 **전에** 두 값이 모두 NULL 아님·0 초과인지 먼저
--   확인하고, 하나라도 문제가 있으면 NULL(→ amount_issue 로 걸러짐)로 처리한다.
--
-- ── DROP 순서(262 가 정리한 원칙 그대로) ──
--   1) DROP get_past_unregistered_settlements()   (헬퍼를 호출하는 쪽 — 먼저 제거)
--   2) DROP _settlement_cert_candidates()          (헬퍼 — 그다음 제거)
--   3) CREATE _settlement_cert_candidates()        (헬퍼부터 새로 만들어야 아래
--                                                      CREATE OR REPLACE 들이 최신
--                                                      반환 컬럼을 참조할 수 있음)
--   4) CREATE OR REPLACE backfill_settlements()     (반환 타입 불변 — DROP 불필요)
--   5) CREATE get_past_unregistered_settlements()   (헬퍼 재생성 후 다시 만듦)
--   6) CREATE OR REPLACE register_past_settlements() (반환 타입 불변 — DROP 불필요)
--   전부 이 파일 하나의 트랜잭션(마이그레이션 파일 = 암묵적 단일 트랜잭션)에서 실행되므로
--   중간에 실패하면 전체가 롤백되어 "헬퍼는 새 버전, 함수는 옛 버전" 같은 반쪽 상태가
--   남지 않는다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 0. 반환 타입이 바뀌는 함수 먼저 DROP (의존 호출부 → 헬퍼 순서)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
DROP FUNCTION IF EXISTS public._settlement_cert_candidates();

-- ============================================================
-- 1. 공통 판정·금액 계산 헬퍼 재생성 (private — PUBLIC/authenticated 직접 실행 불가)
-- ============================================================
CREATE FUNCTION public._settlement_cert_candidates()
RETURNS TABLE (
  application_id      uuid,
  influencer_id       uuid,
  campaign_id         uuid,
  campaign_no         text,
  campaign_title      text,
  reward              bigint,
  recruit_type        text,
  paypal_email        text,
  influencer_name     text,
  influencer_name_kana text,
  amount_jpy          bigint,
  amount_source       text,
  reward_part_jpy     bigint,
  receipt_amount_jpy  bigint,
  amount_cap_jpy      bigint,
  amount_issue        text,
  is_success          boolean,
  cert_at             timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 감사용 제외 + 아직 정산행 없음(멱등)
    -- + [264, 유지] 무보수 시딩·방문형 제외. 이 CTE 는 264 원본과 완전히 동일하다
    -- (300 은 여기를 손대지 않는다 — 금액 계산은 아래 최종 SELECT 에서만 바뀐다).
    SELECT
      a.id                                AS application_id,
      a.user_id                           AS influencer_id,
      a.campaign_id                       AS campaign_id,
      c.campaign_no                       AS campaign_no,
      c.title                             AS campaign_title,
      c.reward                            AS reward,
      c.product_price                     AS product_price,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase,
      inf.paypal_email                    AS paypal_email,
      inf.name_kanji                      AS influencer_name,
      inf.name_kana                       AS influencer_name_kana
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.status = 'approved'
      AND inf.is_audit = false
      AND NOT EXISTS (
        SELECT 1 FROM public.settlements s WHERE s.application_id = a.id
      )
      -- [264, 유지] 시딩(gifting)·방문형(visit) 이면서 현금 리워드가 없는 캠페인은
      -- "금액 오류"가 아니라 "제품만 제공하는 정상 무보수 캠페인"이라 애초에 후보에서
      -- 제외한다. monitor 는 이 조건의 영향을 받지 않는다.
      AND NOT (
        c.recruit_type <> 'monitor'
        AND (c.reward IS NULL OR c.reward <= 0)
      )
  ),
  receipt_latest AS (
    -- [300] 264(=262=232 원본)와 동일한 DISTINCT ON/ORDER BY(어느 행이 "최신"인지 판정은
    -- 완전히 무변경) + purchase_amount 1컬럼만 추가로 가져온다. 인증 성공 판정에 쓰는
    -- 바로 이 행에서 금액도 함께 가져와야 "판정·금액 단일 소스"가 유지된다(사양서 §3-1).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at, d.purchase_amount
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 264(=262=232 원본)와 동일: 응모별 게시물(post) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 264(=262=232 원본)와 동일: 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 264(=262=232 원본)와 동일: 리뷰어(monitor 일반) 응모의 캠페인 채널 전체 인증샷
    -- 승인시각 최댓값 + 완전성 강제(any_null). (변경 없음 — 인증 성공 판정은 그대로)
    SELECT
      cd.application_id,
      MAX(rcl.reviewed_at)                      AS max_channel_reviewed_at,
      bool_or(rcl.reviewed_at IS NULL)           AS any_null
    FROM candidates cd
    CROSS JOIN LATERAL unnest(string_to_array(cd.channel, ',')) AS ch(name)
    LEFT JOIN review_channel_latest rcl
      ON rcl.application_id = cd.application_id
     AND rcl.post_channel   = btrim(ch.name)
    WHERE cd.recruit_type = 'monitor' AND NOT cd.proxy_purchase
      AND btrim(ch.name) <> ''
    GROUP BY cd.application_id
  )
  SELECT
    cd.application_id,
    cd.influencer_id,
    cd.campaign_id,
    cd.campaign_no,
    cd.campaign_title,
    cd.reward,
    cd.recruit_type,
    cd.paypal_email,
    cd.influencer_name,
    cd.influencer_name_kana,
    -- ── [300 신규] 금액 계산: 리뷰어형(monitor, 가구매 포함) = min(영수증, 상시가) 절사 ──
    -- ⚠️ LEAST() 는 NULL 을 무시하는 함수라(파일 상단 경고 참고) 두 값이 모두 유효할
    -- 때만 호출한다 — 그렇지 않으면 "영수증 없음"이 조용히 "상시가로 대체"돼 버린다.
    CASE
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount IS NOT NULL AND rl.purchase_amount > 0
           AND cd.product_price   IS NOT NULL AND cd.product_price   > 0
        -- ⚠️ 버림 결과가 0 이하면 NULL 로 떨어뜨린다(2026-08-05 개발서버 실측에서 발견).
        -- 안 그러면 "금액 미확정"인데 금액 칸만 0 으로 채워져, 같은 미확정 3종 중
        -- 이 케이스만 관리자 화면에 「0엔」으로 표시돼 "0엔 지급 건인가?"로 읽힌다
        -- (저장은 amount_issue 로 걸러져 안 되므로 금전 사고는 아니지만 표시가 어긋난다).
        THEN NULLIF(GREATEST(floor(LEAST(rl.purchase_amount, cd.product_price::numeric)), 0), 0)::bigint
      WHEN cd.recruit_type = 'monitor' THEN NULL::bigint  -- 아래 amount_issue 로 사유가 채워짐
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'receipt_amount'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(261 부터 그대로)
    -- ── [300 신규] 감사용 칸 2개(299) — 리뷰어형만 채움, 그 외 NULL ──
    CASE WHEN cd.recruit_type = 'monitor' THEN floor(rl.purchase_amount)::bigint ELSE NULL::bigint END AS receipt_amount_jpy,
    CASE WHEN cd.recruit_type = 'monitor' THEN cd.product_price ELSE NULL::bigint END AS amount_cap_jpy,
    -- ── [300 신규] amount_issue: 조건 3종(사양서 §3-1·§3-2) ──
    -- 화면에 보여줄 사유 라벨은 2종(금액 없음/상한 없음)으로 묶어도 되지만 판정 조건은
    -- 반드시 3개다 — ㉰(버림 결과 0 이하)을 빠뜨리면 배치 INSERT 가 CHECK(amount_jpy>0)
    -- 위반으로 전체 실패한다.
    CASE
      WHEN cd.recruit_type = 'monitor' AND (rl.purchase_amount IS NULL OR rl.purchase_amount <= 0)
        THEN '리뷰어형 영수증 결제 금액(purchase_amount) 값 없음 또는 0 이하'
      WHEN cd.recruit_type = 'monitor' AND (cd.product_price IS NULL OR cd.product_price <= 0)
        THEN '리뷰어형 제품 가격(product_price, 지급 상한) 값 없음 또는 0 이하'
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount > 0 AND cd.product_price > 0
           AND floor(LEAST(rl.purchase_amount, cd.product_price::numeric)) <= 0
        THEN '리뷰어형 정산 금액이 소수점 절사 후 0 이하'
      ELSE NULL
    END AS amount_issue,
    -- ── is_success: 264(=262=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        COALESCE(rl.status = 'approved', false)
      WHEN cd.recruit_type = 'monitor' THEN
        COALESCE(rl.status = 'approved', false)
        AND EXISTS (
          SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          WHERE btrim(ch.name) <> ''
        )
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          LEFT JOIN review_channel_latest rcl
            ON rcl.application_id = cd.application_id
           AND rcl.post_channel   = btrim(ch.name)
          WHERE btrim(ch.name) <> ''
            AND COALESCE(rcl.status, 'none') <> 'approved'
        )
      ELSE
        COALESCE(pl.status = 'approved', false)
    END AS is_success,
    -- ── cert_at: 264(=262=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        rl.reviewed_at
      WHEN cd.recruit_type = 'monitor' THEN
        CASE
          WHEN rl.reviewed_at IS NULL OR COALESCE(cc.any_null, true) THEN NULL
          ELSE GREATEST(rl.reviewed_at, cc.max_channel_reviewed_at)
        END
      ELSE
        pl.reviewed_at
    END AS cert_at
  FROM candidates cd
  LEFT JOIN receipt_latest rl  ON rl.application_id = cd.application_id
  LEFT JOIN post_latest    pl  ON pl.application_id = cd.application_id
  LEFT JOIN channel_cert   cc  ON cc.application_id = cd.application_id;
$$;

COMMENT ON FUNCTION public._settlement_cert_candidates() IS
  '[300 재정의, 264 원본 대체(반환 컬럼 2개 추가: receipt_amount_jpy·amount_cap_jpy)] private '
  '헬퍼 — 정산 미등록(settlements 행 없음) 응모 전체에 대해 인증 성공 여부(is_success)·인증 '
  '성공일(cert_at, 판정 로직은 264 그대로 무변경)에 더해 모집 형식별 정산 금액(amount_jpy)· '
  '금액 출처(amount_source)·감사용 원금액/상한(receipt_amount_jpy/amount_cap_jpy)·금액 미확정 '
  '사유(amount_issue, 정상이면 NULL)를 계산한다. '
  '리뷰어형(monitor, 가구매 포함)=min(최신 영수증 purchase_amount, campaigns.product_price) 절사, '
  '시딩·방문형=campaigns.reward(무변경). '
  'backfill_settlements()·get_past_unregistered_settlements()·register_past_settlements() '
  '3곳이 이 함수 하나를 호출해 판정·금액 로직 드리프트를 원천 차단. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 RPC 호출 불가) — 264 와 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

-- ============================================================
-- 2. backfill_settlements() 재정의 — 반환 타입 불변(CREATE OR REPLACE 충분)
--    ⚠️ 이 함수의 "현재 유효한 원본"은 262 다(242 의 알림 잠금 게이트를 계승한 버전).
--    v_notify 선언·조회·notif_ins WHERE 조건 3종은 262 에서 그대로 가져온 것이며
--    절대 제거하지 않는다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.backfill_settlements()
RETURNS TABLE(created_count integer, paypal_missing_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_created         integer := 0;
  v_paypal_missing  integer := 0;
  v_cutoff          timestamptz;
  v_notify          boolean;  -- [242 계승, 262 유지, 300 도 유지] 인플루언서 공개 스위치(240)
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read (262 와 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  -- ── [242→262 계승, 300 도 유지] 인플루언서 노출 잠금 조회 ──
  -- ⚠️ 이 함수의 "현재 유효한 원본"은 232 도 264 도 아니라 262(=242 잠금 계승)다.
  --    아래 v_notify 선언·조회·notif_ins WHERE 조건 3종은 절대 제거 금지.
  v_notify := public.is_settlement_public();

  WITH cert AS (
    SELECT * FROM public._settlement_cert_candidates()
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, paypal_email
    )
    SELECT influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
           receipt_amount_jpy, amount_cap_jpy,
           NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외(PR2로 이관)
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외(PR2 수동 처리)
      AND amount_issue IS NULL         -- 금액 미확정 건은 CHECK(amount_jpy>0) 위반으로 배치 전체가
                                        -- 실패하는 것을 막기 위해 저장 대상에서 제외
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_ins AS (
    -- PayPal 미등록 안내 알림: 인플루언서당 미읽음 1건만(멱등 — 218 과 동일 dedup 방식).
    -- 컷오프 이전 응모는 애초에 inserted 에 안 들어오므로 과거분에는 발송되지 않는다.
    -- [242→262 계승] WHERE v_notify — settlement_settings.influencer_visible=false(운영
    --   기본값)이면 inserted 행이 있어도 이 CTE 는 0건 INSERT(안전측). 제거 금지.
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    SELECT i.influencer_id, 'settlement_paypal_required', 'settlements', i.id,
           'PayPalメールアドレス未登録のお知らせ',
           '報酬のお振込みにはPayPalメールアドレスの登録が必要です。マイページから登録をお願いします。'
    FROM inserted i
    WHERE v_notify
      AND i.paypal_email IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications x
        WHERE x.user_id = i.influencer_id
          AND x.kind    = 'settlement_paypal_required'
          AND x.read_at IS NULL
      )
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM inserted WHERE paypal_email IS NULL)
  INTO v_created, v_paypal_missing;

  RETURN QUERY SELECT v_created, v_paypal_missing;
END;
$$;

COMMENT ON FUNCTION public.backfill_settlements() IS
  '[300 재정의, 262 원본 대체(알림 잠금 게이트 계승 유지)] 금액을 _settlement_cert_candidates() '
  '헬퍼가 계산한 amount_jpy/amount_source/reward_part_jpy/receipt_amount_jpy/amount_cap_jpy 로 '
  '저장(리뷰어형은 min(영수증,상시가) 절사, 시딩·방문형은 reward). amount_issue 가 있는 건은 '
  '저장 대상에서 제외해 배치 INSERT 가 CHECK(amount_jpy>0) 위반으로 전체 실패하는 것을 방지. '
  '컷오프·게이트(v_notify=is_settlement_public())·이력/알림 INSERT 는 262 그대로(변경 없음).';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

-- ============================================================
-- 3. 과거 미등록 인증성공 조회 RPC 재생성 — 반환 컬럼 추가(DROP 후 재생성 필요)
-- ============================================================
CREATE FUNCTION public.get_past_unregistered_settlements()
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
  cert_at               timestamptz
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
    c.cert_at
  FROM public._settlement_cert_candidates() c
  WHERE c.is_success
    -- ── 명시적 컷오프 필터(262=232 원본과 동일, 호출 순서 비의존) ──
    -- "과거분" = 컷오프 이전 인증성공(cert_at < v_cutoff) 또는 판정시각 불명 레거시
    -- (cert_at NULL) 또는 컷오프 미설정(v_cutoff NULL — 세팅 전엔 전부 수동 대상).
    AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff);
    -- ⚠️ amount_issue 가 있는 행도 일부러 걸러내지 않고 그대로 반환한다 —
    -- 관리자 화면(2단계, 이번 범위 밖)이 이 값으로 체크박스를 비활성화하고 사유 배지를
    -- 보여줘야 하므로, 여기서 숨기면 "왜 이 건이 안 보이지"라는 혼란만 남긴다.
END;
$$;

COMMENT ON FUNCTION public.get_past_unregistered_settlements() IS
  '[300 재정의, 262 원본 대체(반환 타입 변경으로 DROP 후 재생성 — receipt_amount_jpy/'
  'amount_cap_jpy 2컬럼 추가)] 과거 미등록 인증성공 응모 목록(정산 페인 「과거 미등록」 UI). '
  '리뷰어형은 min(영수증,상시가) 절사 기준 금액, amount_issue 있는 행은 화면에서 체크박스 '
  '비활성 대상. 필터·권한 게이트는 262 그대로.';

REVOKE ALL ON FUNCTION public.get_past_unregistered_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;

-- ============================================================
-- 4. register_past_settlements() 재정의 — 반환 타입 불변(CREATE OR REPLACE 충분)
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
  -- ── 권한 게이트: settlement.pay 최소 write (262=233 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 목표 상태 검증: paid | pending 만 허용 (233 과 동일) ──
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
    -- ── 서버 재검증(233 원칙 유지) ──
    -- 클라가 넘긴 id 목록을 그대로 신뢰하지 않고, 헬퍼가 다시 계산한 is_success ·
    -- amount_issue 로 재검증한다. amount_issue 가 있는 건(금액 NULL/0 이하)은 여기서
    -- 조용히 제외한다(예외 아님 — 부분 성공 허용, 반환값이 곧 실제 처리 건수).
    SELECT c.application_id, c.influencer_id, c.campaign_id,
           c.amount_jpy, c.amount_source, c.reward_part_jpy,
           c.receipt_amount_jpy, c.amount_cap_jpy, c.paypal_email
    FROM public._settlement_cert_candidates() c
    WHERE c.application_id = ANY(p_application_ids)
      AND c.is_success
      AND c.amount_issue IS NULL
      -- 명시적 컷오프 필터(262=232 조회와 동일) — 컷오프 이후 신규건은 자동 백필 대상이라
      -- 수동 무알림 처리에서 제외.
      AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id,
      t.amount_jpy, t.amount_source, t.reward_part_jpy,
      t.receipt_amount_jpy, t.amount_cap_jpy,
      p_target_status,
      NULLIF(t.paypal_email, ''),
      CASE WHEN p_target_status = 'paid' THEN now()      ELSE NULL END,
      CASE WHEN p_target_status = 'paid' THEN auth.uid() ELSE NULL END,
      v_memo
    FROM targets t
    -- 동시 처리 경쟁 방지(이중 방어 — 233 과 동일).
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행.
    -- ⚠️ notifications INSERT 는 여기 없음(233 「알림 없음」 원칙 그대로 — 의도적).
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
  '[300 재정의, 262 원본 대체] 금액을 _settlement_cert_candidates() 헬퍼가 계산한 amount_jpy/'
  'amount_source/reward_part_jpy/receipt_amount_jpy/amount_cap_jpy 로 저장. amount_issue 가 '
  '있는 건(금액 NULL/0 이하)은 서버가 조용히 skip(예외 아님) — 반환값(등록 건수)이 실제 처리 건수. '
  '⚠️ settlement_paid/settlement_paypal_required 알림 둘 다 발행하지 않는 233 원칙 그대로 유지. '
  '나머지(재검증·멱등·컷오프 필터·paid 분기 시 paid_at/paid_by·이력 기록·권한 게이트)는 233 그대로.';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 299 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 4개(헬퍼+3) 반환 타입 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    '_settlement_cert_candidates',
    'backfill_settlements',
    'get_past_unregistered_settlements',
    'register_past_settlements'
  );

-- [V1] 헬퍼가 여전히 PUBLIC/authenticated 에 노출 안 됐는지 확인
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만)

-- [V2] 인증 성공 집계가 299/300 적용 전후로 그대로인지 확인(§5-1 "인증 성공 집계 영향
--   없음" 검증) — recruit_type 별 candidate_cnt·success_cnt 는 264 시점과 동일해야 하고,
--   monitor 행만 금액(amount_source='receipt_amount')·amount_issue 분포가 달라져야 한다.
--   ⚠️ SQL Editor 세션은 auth.uid() 가 NULL 이라 has_permission 체크로 막힐 수 있음 —
--   postgres(소유자) role 세션이면 헬퍼를 직접 조회 가능(owner 권한).
SELECT
  recruit_type,
  amount_source,
  count(*) AS candidate_cnt,
  count(*) FILTER (WHERE is_success) AS success_cnt,
  count(*) FILTER (WHERE is_success AND amount_issue IS NOT NULL) AS success_but_amount_issue_cnt,
  sum(amount_jpy) FILTER (WHERE is_success AND amount_issue IS NULL) AS success_amount_sum
FROM public._settlement_cert_candidates()
GROUP BY recruit_type, amount_source
ORDER BY recruit_type;

-- [V3] 리뷰어형 개별 건 상한 적용 여부 표본 확인(영수증 > 상시가인 건이 실제로 잘리는지)
SELECT application_id, campaign_no, receipt_amount_jpy, amount_cap_jpy, amount_jpy, amount_issue
FROM public._settlement_cert_candidates()
WHERE recruit_type = 'monitor' AND is_success
ORDER BY (receipt_amount_jpy - amount_cap_jpy) DESC NULLS LAST
LIMIT 20;

-- [V4] backfill_settlements() 회귀 확인 — 컷오프 미설정이면 여전히 created_count=0 이어야 함
SELECT cutoff_at FROM public.settlement_settings;
SELECT * FROM public.backfill_settlements();

-- [V5] get_past_unregistered_settlements() 스모크 — 리뷰어형 건이 amount_source='receipt_amount' 로
--   보이고 receipt_amount_jpy/amount_cap_jpy 가 채워지는지
--   (앱에서 campaign_admin 세션으로 확인 — SQL Editor 직접 호출은 permission_denied 가능)
-- SELECT recruit_type, amount_source, amount_issue, amount_jpy, receipt_amount_jpy, amount_cap_jpy, campaign_no, cert_at
-- FROM public.get_past_unregistered_settlements()
-- ORDER BY cert_at NULLS FIRST
-- LIMIT 20;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 방법 A) 이 마이그레이션이 바꾼 것만 264/262 원본으로 되돌리려면(역순):
--   1) register_past_settlements() 를 262_settlement_amount_by_recruit_type.sql 의
--      "4. register_past_settlements() 재정의" CREATE OR REPLACE 블록을 그대로 재실행.
--   2) DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
--      이어서 262_settlement_amount_by_recruit_type.sql 의 "3." 블록(CREATE FUNCTION)을 재실행.
--   3) backfill_settlements() 를 262_settlement_amount_by_recruit_type.sql 의
--      "2." 블록(CREATE OR REPLACE)을 그대로 재실행.
--   4) DROP FUNCTION IF EXISTS public._settlement_cert_candidates();
--      이어서 264_settlement_gifting_visit_zero_reward_exclusion.sql 의 CREATE OR REPLACE
--      블록(264 가 "1. 공통 판정·금액 계산 헬퍼 재생성"이라 부르는 그 블록)을 재실행해
--      264 시점(리뷰어형=product_price 그대로)으로 되돌린다.
-- 방법 B) 299 도 함께 롤백하려면 299 파일 하단 롤백 절차를 이 순서 다음에 실행할 것
--   (299 는 컬럼만 추가하므로 이 파일 롤백과 독립적이지만, 완전 원복 시 함께 되돌림).


-- ───────────────────────────────────────────────────────────────
-- [파일 301] 301_receipt_settlement_lock_guard.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 301_receipt_settlement_lock_guard.sql
-- 정산이 이미 처리된 응모에 영수증을 새로 제출하는 것을 데이터베이스에서 차단
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-4 ★(영수증 신규
--   제출 가드) — 「단계 배정」 표에 따라 이 마이그레이션의 서버 차단만 1단계 범위이고,
--   인플루언서 화면 사유 안내(2.5단계)·관리자 화면 경고(2단계)·영수증 사후 수정 재계산
--   가드(2단계)는 이번 범위 밖이다.
--
-- ── 왜 막아야 하는가 ──
--   영수증(kind='receipt')은 재제출할 때마다 기존 행을 재사용하지 않고 **새 행이
--   쌓인다**(§1-3 — review_image/post 와 달리 "기존 행 교체" 분기가 storage.js
--   insertDraftDeliverable() 에 없다). 정산(settlements) 은 그 응모의 "최신 영수증"
--   (receipt_latest — 마이그레이션 300 헬퍼, submitted_at DESC 최신 1건)을 근거로
--   금액을 계산해 이미 저장했다. 정산이 만들어진 뒤에 그보다 나중 시각의 새 영수증
--   행이 하나라도 생기면, 그 순간부터 "최신 영수증"의 정의가 바뀌어 판정·금액이
--   가리키는 행이 서로 어긋난다 — §3-1 "판정·금액 단일 소스" 원칙이 깨지는 지점.
--
-- ── 무엇을 막는가 ──
--   그 응모(application_id)에 status IN ('paid','on_hold') 인 정산행이
--   하나라도 있으면, 그 응모에 새로 kind='receipt' 행을 draft 또는 pending 상태로
--   저장(INSERT 또는 UPDATE)하는 것을 막는다. **정산대기(pending) 상태는 막지 않는다**
--   (사양서 §3-4 — 정산대기는 제출은 허용하되 관리자 화면에 경고만 띄운다. 그 경고
--   UI·제출 시 정산액 재계산은 2단계 범위).
--
-- ── 왜 취소(cancelled)는 막지 않는가 (2026-08-05 사용자 결정) ──
--   초안은 관리자 영수증 수정 가드와 같은 3종 집합으로 맞췄다가 뺐다. 두 가드는 목적이
--   다르다 — 관리자 금액 수정 차단은 "확정된 금전 기록이 흔들리는 것"을 막는 것이라
--   취소분에도 타당하지만, 영수증 제출 차단은 "정산 금액과 영수증이 어긋나는 것"을
--   막는 것이고 **취소된 정산은 지급 자체를 하지 않으므로 어긋날 금액이 없다.**
--   ⚠️ 결정적 이유: 취소(cancelled)는 **되돌아올 길이 없는 종료 상태**다.
--   mark_settlement_revert(224)는 on_hold 에서만 pending 으로 되돌리고, 관리자 화면에도
--   cancelled 행에는 처리 버튼이 없으며, settlement_events 의 ON DELETE RESTRICT 때문에
--   정산행 삭제도 사실상 불가능하다. 여기에 영수증 제출까지 막으면 그 응모는 **영구히
--   새 영수증을 못 내는 상태로 굳는다**(인플루언서가 갇힘).
--
-- ── 왜 INSERT 뿐 아니라 UPDATE 도 막는가 ──
--   실제 저장 경로는 두 단계다: ①storage.js insertDraftDeliverable() 가 새 행을
--   status='draft' 로 INSERT ②같은 화면의 "提出" 버튼이 submitDrafts() 를 호출해
--   그 행을 status='pending' 으로 UPDATE. ①에서 막으면 ②까지 갈 필요가 없는 게
--   보통이지만, "정산이 아직 없을 때 draft 를 만들어 두고 한참 뒤에야 제출 버튼을
--   누르는" 순서가 뒤바뀐 경우 ①은 통과하고 그 사이에 정산이 paid/on_hold
--   가 될 수 있다 — 이때 ②(UPDATE)도 막아야 실제로 안전하다. 그래서 BEFORE INSERT
--   OR UPDATE 로 둘 다 검사한다.
--
-- ── 왜 kind='receipt' 로만 좁히는가 ──
--   이 문제(정산 생성 후 "최신 행"이 바뀌는 위험)는 §1-3 이 지적한 대로 영수증에만
--   있다 — review_image·post 는 채널당 1행을 그대로 UPDATE 로 재사용하므로 새 행이
--   추가되지 않는다(created_at 이 바뀌지 않아 receipt_latest 류 CTE 의 "최신" 판정에
--   영향이 없다). 다른 kind 까지 이 트리거로 막으면 근거 없는 과잉 차단이 된다.
--
-- ── 관리자 경로가 걸리지 않는 근거(직접 추적 확인) ──
--   - 관리자 대리 등록(admin_create_deliverable_proxy, 마이그레이션 160)은 영수증을
--     INSERT 할 때 항상 status='approved' 로 즉시 저장한다(160 섹션 6 "⑦ deliverables
--     INSERT — status='approved'"). 이 트리거는 NEW.status IN ('draft','pending') 일 때만
--     차단하므로, 'approved' 로 들어오는 대리 등록 INSERT 는 조건 자체에 걸리지 않는다
--     — is_admin() 예외를 별도로 둘 필요조차 없지만, 아래 판정 함수는 방어적으로
--     관리자를 먼저 통과시킨다(대리 등록 외에 향후 관리자 경로가 draft/pending 상태로
--     영수증을 만들 가능성에 대비한 안전판, 274 의 관리자 예외와 같은 사고방식).
--   - 관리자 영수증 사후 수정(update_receipt_admin, 마이그레이션 178)은 order_number·
--     purchase_date·purchase_amount 3개 컬럼만 UPDATE 하고 status 는 건드리지 않는다
--     (178 SQL: "UPDATE public.deliverables SET order_number=…, purchase_date=…,
--     purchase_amount=…" — status 없음). 즉 NEW.status = OLD.status 로 유지되고,
--     정산이 존재하는 응모의 영수증은 정의상 이미 승인(approved)된 행이므로
--     NEW.status IN ('draft','pending') 에 해당하지 않는다 — 애초에 이 트리거의
--     검사 대상이 아니다. (다만 178 이 편집하는 대상 행의 상태가 어떤 이유로든
--     draft/pending 이면 관리자 예외로 통과시킨다 — 아래 판정 함수 참고.)
--
-- ── 이 마이그레이션이 다루지 않는 것(2단계로 이월, 사양서 §4) ──
--   - 정산대기(pending) 상태에서 새 영수증이 승인됐을 때 정산액을 다시 계산하는 로직
--     (§3-1 스냅샷 예외, §3-4 "영수증 수정 가드(재계산 포함)") — 2단계.
--   - 관리자 화면의 "정산 후 영수증이 다시 제출됨" 경고 UI — 2단계.
--   - 인플루언서 화면에 "이미 정산 처리된 응모라 제출할 수 없습니다" 를 일본어로
--     안내하는 문구(dev/js/ui.js friendlyErrorJa) — 2.5단계. 이 마이그레이션 배포
--     직후에는 차단될 때 원문 예외 메시지(한국어)가 그대로 노출된다. 자동 백필
--     (cutoff_at 미설정, §1-5)이 꺼져 있고 실제로 이 트리거에 걸릴 인플루언서가
--     당장은 사실상 없으므로 노출 빈도는 낮지만, 2.5단계 배포 전까지 남는 알려진 간극.
--
-- ── 롤백 ──
--   DROP TRIGGER IF EXISTS trg_receipt_settlement_lock ON public.deliverables;
--   DROP FUNCTION IF EXISTS public.check_receipt_settlement_lock();
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_receipt_settlement_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_locked boolean;
BEGIN
  -- 0. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (익명 쓰기는 deliverables_insert_own/update_own_* 행 단위 보안 정책이 이미
  --     차단해 여기까지 도달하지 못한다 — 274 와 동일 논리)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 1. 관리자 — 대리 등록·사후 수정·되돌리기 전부 면제. 이 가드의 목적은 "인플루언서의
  --    신규 제출"만 막는 것이지, 관리자가 하는 정정·교정 작업을 막는 것이 아니다.
  --    (실제로는 대리 등록이 항상 status='approved' 로 INSERT 하고, 사후 수정은
  --    status 를 건드리지 않아 아래 2번 조건에서도 걸리지 않는 게 보통이지만,
  --    관리자 경로 전반의 방어판으로 명시적으로 먼저 통과시킨다.)
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 2. 영수증이 아니거나(kind<>'receipt') 저장하려는 상태가 draft/pending 이 아니면
  --    (=본인이 만드는 "신규 제출/재제출" 방향 연산이 아니면) 무관 — 통과.
  IF NEW.kind <> 'receipt' OR NEW.status NOT IN ('draft', 'pending') THEN
    RETURN NEW;
  END IF;

  -- 3. 그 응모에 이미 처리된(=더 이상 되돌릴 수 없거나 손댈 필요가 없는) 정산이
  --    있는지 확인. settlements.application_id 는 UNIQUE(마이그레이션 217) 이라
  --    최대 1행만 매칭된다.
  SELECT EXISTS (
    SELECT 1 FROM public.settlements s
     WHERE s.application_id = NEW.application_id
       AND s.status IN ('paid', 'on_hold')  -- cancelled 제외(파일 상단 「왜 취소는 막지 않는가」)
  ) INTO v_locked;

  IF v_locked THEN
    -- 머신 판독용 코드 접두어(콜론 뒤는 한국어 원문 — 인플루언서 대상 일본어 안내로
    -- 바꾸는 작업은 2.5단계, dev/js/ui.js friendlyErrorJa 에 패턴 추가 예정. 파일
    -- 상단 "이 마이그레이션이 다루지 않는 것" 참고).
    RAISE EXCEPTION 'settlement_locked_receipt_submission: 이미 정산 처리된 응모에는 영수증을 새로 제출할 수 없습니다. 문의사항은 관리자에게 연락해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.check_receipt_settlement_lock() IS
  '[301] 정산(settlements)이 paid/on_hold 인 응모에 새 영수증(kind=receipt,
   status IN (draft,pending))을 저장하려 하면 차단하는 트리거 함수. BEFORE INSERT OR
   UPDATE ON deliverables, WHEN(NEW.kind=''receipt''). 정산대기(pending)는 막지 않는다
   (제출은 허용, 재계산·경고 UI는 2단계). 관리자(is_admin())와 로그인 세션 없는 호출은
   면제. 사양서 docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-4 ★.';

DROP TRIGGER IF EXISTS trg_receipt_settlement_lock ON public.deliverables;
CREATE TRIGGER trg_receipt_settlement_lock
  BEFORE INSERT OR UPDATE ON public.deliverables
  FOR EACH ROW
  WHEN (NEW.kind = 'receipt')
  EXECUTE FUNCTION public.check_receipt_settlement_lock();

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 299·300 까지 적용된 뒤에 실행할 것(settlements 표·함수 의존 없음이지만
--   같은 기능 세트이므로 순서를 맞춘다).
-- ============================================================
/*

-- [V0] 함수·트리거 생성 확인
SELECT p.proname, p.prosecdef,
       t.tgname, t.tgenabled
  FROM pg_proc p
  LEFT JOIN pg_trigger t ON t.tgfoid = p.oid
 WHERE p.proname = 'check_receipt_settlement_lock'
   AND p.pronamespace = 'public'::regnamespace;
-- 기대: prosecdef=true, tgname='trg_receipt_settlement_lock', tgenabled='O'

-- [V1] deliverables 트리거 전체 목록 확인(간섭 재확인 — 5개여야 함: 301 적용 전 4개 + 이번 1개)
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'public.deliverables'::regclass AND NOT tgisinternal
 ORDER BY tgname;

-- [V2] 테스트 대상 확보 — status IN ('paid','on_hold') 정산이 걸린 응모 1건
SELECT s.application_id, s.status, a.user_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
 WHERE s.status IN ('paid', 'on_hold')
 LIMIT 1;

-- [V2-b] 취소(cancelled)는 막지 않는다는 것도 함께 확인할 대상 — 이 응모에서는
--   영수증 신규 제출이 **정상 동작해야** 한다(막히면 잘못된 것).
SELECT s.application_id, s.status, a.user_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
 WHERE s.status = 'cancelled'
 LIMIT 1;

-- [V3] 실제 차단 확인 (SQL Editor 는 서비스 키라 auth.uid() 가 NULL 로 통과되어 이
--   트리거를 있는 그대로 재현하지 못함 — 274 와 동일 제약). 아래 두 방법 중 하나:
--
--   방법 1 (권장) — 개발서버에 실제 로그인한 인플루언서 브라우저에서, 정산이 paid/
--   on_hold 인 응모의 활동관리 화면에 진입해 영수증을 새로 제출해 본다.
--   → 「settlement_locked_receipt_submission: …」 오류가 나야 한다.
--   반대로 정산이 pending·cancelled 인 응모에서는 **정상 제출돼야** 한다.
--
--   방법 2 — SQL Editor 에서 request.jwt.claims 를 흉내내 auth.uid() 를 설정(272·274
--   와 동일 패턴). 반드시 ROLLBACK 할 것:
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<위 V2 에서 확보한 user_id>')::text, true);
--     INSERT INTO public.deliverables (application_id, user_id, campaign_id, kind, status, receipt_url)
--     VALUES ('<위 V2 의 application_id>'::uuid, '<user_id>'::uuid,
--             (SELECT campaign_id FROM public.applications WHERE id = '<application_id>'),
--             'receipt', 'draft', 'https://example.com/test.jpg');
--     -- 기대: ERROR: settlement_locked_receipt_submission: 이미 정산 처리된 응모에는 ...
--   ROLLBACK;

-- [V4] 정산대기(pending)는 막히지 않는지 확인(회귀) — status='pending' 인 정산이 걸린
--   응모로 같은 절차(V3 방법 1 또는 2)를 반복. 정상적으로 draft 저장이 성공해야 한다.

-- [V5] 관리자 대리 등록·영수증 수정이 여전히 정상 동작하는지(회귀) — 개발서버 관리자
--   화면에서 정산이 paid 인 응모를 골라 ①대리 등록(영수증) ②영수증 인플레이스 수정을
--   각각 시도. 둘 다 차단 없이 정상 저장되어야 한다.

*/


-- ───────────────────────────────────────────────────────────────
-- [파일 302] 302_update_receipt_admin_settlement_guard.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 302_update_receipt_admin_settlement_guard.sql
-- 관리자 영수증 사후 수정에 정산 정합 가드 추가
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-1(재계산 기준),
--   §3-4 「영수증 금액 사후 수정 가드」(관리자 경로)
--
-- ── 배경 ──
--   299·300 로 리뷰어형(monitor) 정산 금액이 "그 응모의 최신 영수증(receipt_latest)
--   purchase_amount 를 캠페인 상시가로 상한을 씌운 값"이 됐다. 그런데 관리자가 영수증을
--   등록한 뒤(=정산이 이미 만들어진 뒤)에도 update_receipt_admin(마이그레이션 128→178)
--   RPC 로 purchase_amount 를 얼마든지 고칠 수 있고, 지금까지 그 수정은 정산과 아무
--   관계가 없었다(178 은 deliverables 만 UPDATE 하고 settlements 는 건드리지 않는다).
--   이 파일 적용 전에는 "저장된 정산액"과 "영수증에 실제로 적힌 금액"이 관리자의
--   사후 수정 한 번으로 조용히 어긋날 수 있었다 — §3-1 이 요구하는 "판정·금액 단일
--   소스" 원칙이 저장 시점 이후로는 지켜지지 않는 구멍.
--
-- ── update_receipt_admin 의 "현재 유효한 정의" 전수 확인(작업 착수 전) ──
--   grep -rl "update_receipt_admin" supabase/migrations/ 결과 4개 파일:
--     128(원본 CREATE) → 178(CREATE OR REPLACE, 3종 필수→최소 1개로 완화)
--     → 252(receipt_edit_history 테이블에 트리거 추가 — update_receipt_admin 본문 자체는
--       무변경, RPC 코드를 안 건드리고 트리거로 투명 처리한다고 252 파일에 명시)
--     → 301(deliverables 에 별도 트리거 trg_receipt_settlement_lock 추가 — 이 함수의
--       UPDATE 문도 그 트리거를 통과하지만, is_admin() 이 함수 안에서 이미 참인 호출만
--       이 지점에 도달하므로 301 트리거 1번 조건에서 항상 조기 통과한다. update_receipt_
--       admin 자체의 시그니처·본문은 301 도 건드리지 않았다).
--   → 이 함수의 "현재 유효한 정의"는 178. 이번 파일이 178 을 대체하는 재정의다.
--
-- ── 무엇을 바꾸는가(요약) ──
--   그 영수증(deliverables.kind='receipt')이 속한 응모(application_id)에 정산
--   (settlements) 행이 있으면:
--     · status IN ('paid','on_hold','cancelled') → 수정 자체를 차단(RAISE EXCEPTION,
--       178 의 UPDATE 문에 도달하기 전에 막는다 — 반려 차단 트리거 247 과 같은 사고방식)
--     · status = 'pending' → 수정은 허용하고, 저장 직후 "그 응모의 최신 영수증"을
--       다시 읽어 정산 금액을 재계산해 갱신한다(재계산이 "금액 미확정"으로 떨어지면
--       아래 「재계산 결과가 실패할 때」참고)
--     · 정산 행 자체가 없음 → 178 과 완전히 동일하게 동작(영향 없음)
--
-- ── ⚠️ 여기서는 취소(cancelled)도 차단 대상이다 — 301(영수증 신규 제출 차단)와
--    다른 이유(사용자 2026-08-05 확인) ──
--   301 은 "취소(cancelled)된 정산이 있는 응모"에 새 영수증을 내는 것은 막지 않는다
--   (인플루언서가 영구히 새 영수증을 못 내는 상태로 굳는 것을 피하기 위해서다 — 301
--   파일 상단 참고). 이 파일(302)은 그 반대로 취소도 막는다. 두 가드는 막는 대상과
--   목적이 다르다:
--     · 301(제출 차단) = 인플루언서가 "새 영수증 행"을 만드는 것을 막는다. 목적은
--       "정산 금액과 영수증이 어긋나는 것"을 막는 것이고, 취소된 정산은 지급 자체를
--       하지 않으므로 애초에 어긋날 금액이 없다 — 막을 이유가 약하고, 막으면 인플루언서가
--       영원히 갇히는 부작용이 크다.
--     · 302(이 파일, 수정 차단) = 관리자가 "이미 존재하는 영수증 행의 금액 칸"을 고치는
--       것을 막는다. 목적은 "확정된 금전 기록이 흔들리는 것"을 막는 것이다. 취소된
--       정산도 한때 계산됐던 금액(amount_jpy)이 감사 기록(settlement_events)에 남아
--       있고, 그 근거였던 영수증을 사후에 바꾸면 "그 취소가 어떤 금액을 근거로 이뤄졌는지"
--       를 사후에 다시 쓸 수 있게 된다 — 즉 "인플루언서가 갇히는" 부작용이 없고(관리자가
--       거는 가드일 뿐, 인플루언서의 다음 행동을 막지 않는다), 반대로 "막지 않으면
--       감사 기록의 근거가 사후에 바뀐다"는 위험만 남는다. 그래서 302 는 3종
--       (paid·on_hold·cancelled) 모두 차단한다.
--
-- ── 재계산 기준(사양서 §3-1) ──
--   · "최신 영수증" = 300 의 receipt_latest 와 완전히 같은 정렬 기준
--     (application_id 기준 submitted_at DESC, updated_at DESC 최신 1건). 지금 수정하는
--     행(p_deliverable_id)이 그 최신 행이 아닐 수도 있으므로, 별도로 "이 행이 최신인지"
--     따지지 않고 그냥 응모 기준으로 다시 조회한다 — 이 UPDATE 가 이미 커밋 전 같은
--     트랜잭션에 반영돼 있으므로 방금 고친 값이 그대로 보인다.
--   · 상한(캠페인 상시가) = **저장된 옛 상한(settlements.amount_cap_jpy)을 재사용하지
--     않고 campaigns.product_price 를 다시 읽는다** — 캠페인이 그 사이 수정됐을 수
--     있어서다(사양서 §3-1 "재계산 기준" 행 명시).
--   · 계산식은 300 과 완전히 같아야 한다: NULLIF(GREATEST(floor(LEAST(영수증, 상한)), 0), 0)
--     ⚠️ LEAST() 는 NULL 을 무시하는 함수라(300 파일 상단과 동일 경고) 두 값이 모두
--     유효(NOT NULL·0 초과)할 때만 호출한다. 300 의 헬퍼(_settlement_cert_candidates)를
--     그대로 호출하지 못하는 이유 — 그 헬퍼는 "아직 정산행이 없는" 응모만 대상으로
--     하는 CTE(candidates, NOT EXISTS settlements)라 이미 정산행이 있는 이 케이스에는
--     맞지 않는다. 그래서 같은 계산식을 이 함수 안에 별도로 복제했다 — **300 의 계산식이
--     바뀌면 이 함수도 함께 고쳐야 한다**(드리프트 위험, 파일 양쪽에 서로를 가리키는
--     경고 주석을 남긴다).
--   · 감사용 칸 2개(receipt_amount_jpy·amount_cap_jpy, 299)도 재계산 성공 시 함께
--     갱신한다 — 안 하면 관리자 화면의 "왜 이 금액인가" 설명이 거짓 근거를 표시한다
--     (사양서 §3-1 "재계산 기준" 행 명시).
--
-- ── 재계산 결과가 "금액 미확정"이 될 때 — 이 파일의 결정 사항(사양서에 답이 없던 지점) ──
--   settlements.amount_jpy 는 CHECK(amount_jpy > 0) 이라 0/NULL 로 UPDATE 할 수 없다.
--   후보 3가지 중 **"정산 행을 보류(on_hold)로 돌린다"를 택했다**:
--     A) 수정 자체를 거부한다 — 기각. 관리자가 정당하게 오기(잘못 적은 값)를 고치려는 시도까지
--        막아 버리면, 잘못된 영수증 값을 영구히 못 고치는 새로운 막다른 길이 생긴다.
--     B) 정산을 보류(on_hold)로 돌리고 amount_jpy 는 손대지 않는다 — **채택**.
--     C) 재계산을 실패로만 기록하고 상태·금액을 그대로 둔다 — 기각. "조용한 어긋남"을
--        막으려고 만드는 가드인데, 이 선택지는 그 어긋남을 그대로 허용하는 것과 같다.
--   B 를 택한 이유:
--     · amount_jpy 칸을 건드리지 않으므로 CHECK(amount_jpy>0) 위반이 원천적으로
--       발생하지 않는다(0/NULL 을 넣으려는 시도 자체가 없다).
--     · "확정된 금전 기록이 흔들리는 것을 막는다"는 이 가드 전체의 목적과 정확히
--       일치한다 — 마지막으로 유효했던 금액을 그대로 보존한 채, 사람이 다시 검토할
--       때까지 더 이상 손대지 못하게 잠근다(on_hold 가 되면 이 함수 자신의 위쪽 차단
--       규칙에 걸려 재편집이 막힌다 — 아래 참고).
--     · 이미 있는 인프라를 그대로 재사용한다 — 관리자 정산 페인에 "보류 해제" 버튼이
--       이미 있고(마이그레이션 224 mark_settlement_revert, 화면 dev/js/admin-settlements.js),
--       관리자는 ①보류 해제로 pending 복귀 → ②영수증을 다시 올바르게 고침 → ③이 함수가
--       재실행되며 재계산 성공 이라는 흐름으로 스스로 복구할 수 있다. 새 UI 를 만들
--       필요가 없다.
--     · 정확히 같은 판단 패턴이 이 저장소에 이미 있다 — 246(auto_hold_settlement_on_app_
--       reject) 이 "신청이 반려되면 pending 정산을 자동으로 on_hold 로 돌린다"를 트리거로
--       구현해 뒀다. 이 파일은 그 판단을 "영수증 금액이 더 이상 신뢰할 수 없게 됐을 때"
--       라는 새 트리거 조건에 적용하는 것뿐이다.
--   ⚠️ amount_jpy·amount_source·receipt_amount_jpy·amount_cap_jpy 는 전부 이전 값
--   그대로 둔다(보류 시점 스냅샷 보존) — 재계산에 실패했다고 새 계산값(무효)을 감사
--   칸에 채우면 "왜 예전 금액이 지금 이상한 숫자로 보이는가"라는 혼란만 남긴다.
--
-- ── settlement_events.action 확장: 'recalc' 신설 ──
--   기존 5종(create/pay/hold/cancel/revert, 217) 중 어느 것도 "상태는 그대로(pending→
--   pending)인데 금액만 바뀌었다"는 사건을 표현하지 못한다. 그래서 'recalc' 를 새로
--   추가한다(52 recalc_brand_application_totals 등 이 저장소가 이미 "재계산"에 쓰는
--   용어와 동일). prev_status·next_status 는 둘 다 'pending' 으로 남긴다(CHECK 도메인
--   안에서 유효 — 상태가 안 바뀌었다는 사실 자체가 기록에 남는 편이 낫다).
--   "금액 미확정으로 자동 보류"되는 쪽은 **새 action 을 만들지 않고 기존 'hold' 를
--   재사용한다** — 246 이 이미 "자동 보류"를 별도 action 없이 memo 로만 구분하는
--   전례를 세워 뒀다(246 파일 "감사 구분" 섹션 참고). 같은 관례를 따른다.
--
-- ── ⚠️ 자동 보류 memo 문구는 반드시 "자동 보류"라는 두 글자 연속 표현을 피한다 ──
--   dev/js/admin-settlements.js:338 이 `(s.memo || '').includes('자동 보류')` 로
--   "신청 반려로 자동 보류"(246) 앰버 배지를 그린다. 이 파일이 만드는 자동 보류는
--   원인이 "신청 반려"가 아니라 "영수증 금액 확정 불가"이므로, memo 에 그 문자열
--   그대로가 들어가면 화면이 **엉뚱한 사유("신청이 반려·취소되어 자동 보류된 정산입니다")
--   를 사용자에게 보여준다.** 그래서 이 파일의 memo 문구는 "보류 처리"라고만 쓰고
--   "자동"과 "보류"를 붙여 쓰지 않는다(예: "영수증 수정으로 금액을 확정할 수 없어
--   보류 처리됨" — "자동"이라는 단어 자체가 없다). 이 gap 을 구분해 보여줄 전용 배지는
--   2단계(관리자 화면) 범위 — 지금은 "잘못된 기존 배지가 뜨는 것"만 피한다.
--
-- ── 권한: is_campaign_admin() 그대로, has_permission('settlement.pay') 추가 안 함 ──
--   정산 금액을 실제로 움직이는 RPC(mark_settlement_paid/hold/cancel/revert,
--   register_past_settlements) 는 has_permission('settlement.pay','write') 로 따로
--   막혀 있다(220 시드: campaign_admin=write, campaign_manager=hidden — 슈퍼관리자가
--   나중에 이 값을 등급별로 더 좁힐 수도 있는 동적 권한). 이 함수는 그 RPC 들을 직접
--   호출하는 게 아니라 "영수증 수정"이라는, 이미 is_campaign_admin() 으로 허가된 행위의
--   **자동 부수 효과**로 정산을 건드린다 — 246(신청 반려 시 자동 보류) 도 has_permission
--   검사 없이 신청 상태 변경 권한에만 의존하는 것과 같은 성격이다. 그래서 이 함수에
--   settlement.pay 검사를 추가로 걸지 않는다(추가하면 오히려 "영수증은 고쳤는데 정산은
--   조용히 안 맞아도 되는" 이 파일이 막으려는 그 구멍이 다시 열린다 — 권한이 없다고
--   그냥 통과시킬 수는 없고, 권한이 없다고 영수증 수정 자체를 막는 것도 178 의 기존
--   범위를 벗어난다).
--
-- ── ⚠️ PL/pgSQL FOUND 변수 함정 ──
--   settlements 를 조회한 직후의 FOUND 는 그 다음에 실행되는 아무 SQL 문(INSERT 등)
--   에도 계속 덮어써진다. 이 함수 본문에서 정산 조회 이후 여러 문장(deliverables
--   UPDATE·receipt_edit_history INSERT)이 이어지므로, 나중에 "정산이 있었는지"를
--   판단할 때 암묵적 FOUND 를 다시 참조하면 엉뚱한 문장의 결과를 읽게 된다. 그래서
--   정산 조회 직후 명시적 불리언 변수(v_settlement_found)에 그 순간의 FOUND 값을
--   즉시 옮겨 담고, 이후로는 전부 그 변수만 사용한다.
--
-- ── 반환값 설계(화면이 쓸 수 있도록) ──
--   기존 178 은 RETURNS void. 이 파일은 RETURNS TABLE(4컬럼)로 바꾼다 — 인자 목록
--   (uuid, text, date, numeric)은 그대로지만 반환 타입이 바뀌므로 CREATE OR REPLACE 로는
--   안 되고 DROP 후 CREATE 가 필요하다(300 이 get_past_unregistered_settlements 에
--   적용한 것과 동일 이유). storage.js 의 updateReceiptAdmin() 은 현재 {error} 만
--   구조분해하고 반환된 data 를 쓰지 않으므로(dev/lib/storage.js:1209) 이 반환 타입
--   변경만으로는 기존 화면 동작이 깨지지 않는다 — 새 값은 2단계(관리자 화면)가
--   토스트 문구("정산 금액이 N엔으로 재계산되었습니다" 등)를 만들 때 쓸 재료다.
--   반환 컬럼 4개:
--     settlement_status         — 처리 후 정산 상태. 정산 행 자체가 없으면 NULL.
--     settlement_recalculated   — 이번 호출로 정산 금액(amount_jpy)이 실제로 바뀌어
--                                  저장됐으면 true. 변경 없음(no-op·정산 없음·자동 보류)
--                                  이면 false.
--     settlement_amount_jpy     — 처리 후 정산 금액(엔). 정산이 없으면 NULL. 자동
--                                  보류된 경우 예전 값 그대로.
--     settlement_amount_issue   — 재계산 결과가 "금액 미확정"이 되어 자동 보류된
--                                  경우의 사유 문구. 그 외에는 NULL.
--   (paid/on_hold/cancelled 로 차단된 경우는 RAISE EXCEPTION 으로 트랜잭션이 끝나므로
--   이 반환값 자체가 존재하지 않는다 — 클라는 그 상황을 error 로 받는다, 301 과 동일)
--
-- ── 128/178 대비 변경 사항 요약 ──
--   [유지] 권한 가드(is_campaign_admin) · 입력 정규화·검증(최소 1개, 주문번호 200자,
--     구매금액 음수 금지) · 대상 행 조회 FOR UPDATE · kind='receipt' 검증 · no-op 시
--     이력 미기록 · receipt_edit_history INSERT
--   [신규] 정산 조회(FOR UPDATE) · paid/on_hold/cancelled 차단 · pending 이면 저장
--     직후 재계산·감사 칸 갱신·settlement_events 기록 · 재계산 실패 시 on_hold 자동
--     전환 · 반환 타입 void → TABLE(4컬럼)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. settlement_events.action CHECK 확장 — 'recalc' 추가(217 원본 5종 → 6종)
--    DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴(160/162/299 와 동일, 재실행 안전)
-- ============================================================
ALTER TABLE public.settlement_events
  DROP CONSTRAINT IF EXISTS settlement_events_action_check;

ALTER TABLE public.settlement_events
  ADD CONSTRAINT settlement_events_action_check
  CHECK (action IN (
    'create',  -- 정산 최초 생성(backfill_settlements/register_past_settlements)
    'pay',     -- 송금완료 처리(mark_settlement_paid, 222)
    'hold',    -- 보류(관리자 수동 mark_settlement_hold, 223 / 신청 반려 자동, 246 /
               -- 영수증 재계산 실패 자동, 302 — memo 로 사유 구분)
    'cancel',  -- 취소(mark_settlement_cancel, 223)
    'revert',  -- 보류 해제·pending 복귀(mark_settlement_revert, 224)
    'recalc'   -- [302 신규] 상태는 그대로(pending→pending)인데 영수증 사후 수정으로
               -- 금액(amount_jpy)만 재계산되어 바뀐 사건
  ));

-- ============================================================
-- 2. update_receipt_admin 재정의 — 반환 타입 변경(void→TABLE)이라 DROP 후 CREATE
-- ============================================================
DROP FUNCTION IF EXISTS public.update_receipt_admin(uuid, text, date, numeric);

CREATE FUNCTION public.update_receipt_admin(
  p_deliverable_id  uuid,
  p_order_number    text,
  p_purchase_date   date,
  p_purchase_amount numeric
)
RETURNS TABLE (
  settlement_status       text,
  settlement_recalculated boolean,
  settlement_amount_jpy   bigint,
  settlement_amount_issue text
)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_prev                  record;   -- 대상 영수증 행(order_number/purchase_date/purchase_amount/kind/application_id)
  v_admin_name             text;
  v_trimmed_order          text;
  v_order_to_save          text;    -- NULLIF(v_trimmed_order, '') — 저장에 사용할 최종값

  v_settlement             record;  -- 그 응모의 정산 행(있으면)
  v_settlement_found       boolean; -- FOUND 함정 방지용 명시적 플래그(파일 상단 경고 참고)

  v_latest_receipt_amount  numeric; -- 저장 직후 다시 읽은 "그 응모의 최신 영수증" 결제 금액
  v_cap                    bigint;  -- 다시 읽은 캠페인 상시가(product_price, 옛 스냅샷 재사용 금지)
                                    -- campaigns.product_price 는 bigint(003) — 300 과 타입을 맞춘다
  v_new_amount             bigint;  -- 재계산된 정산 금액
  v_new_receipt_snapshot   bigint;  -- 재계산된 감사용 칸 — 영수증 원금액(floor)
  v_new_cap_snapshot       bigint;  -- 재계산된 감사용 칸 — 적용 상한
  v_amount_issue           text;    -- 재계산 실패 사유(정상이면 NULL)
  v_recalculated           boolean := false;
  v_out_status             text;    -- 반환용: 처리 후 정산 상태
  v_out_amount             bigint;  -- 반환용: 처리 후 정산 금액
BEGIN
  -- ── 권한 가드: campaign_admin 이상(178 과 동일, 변경 없음) ──────────────
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── 입력 정규화(178 과 동일) ─────────────────────────────────────────
  v_trimmed_order := btrim(COALESCE(p_order_number, ''));
  v_order_to_save := NULLIF(v_trimmed_order, '');

  -- ── 입력 검증: 최소 1개 필수(178 과 동일) ──────────────────────────
  IF v_order_to_save IS NULL
     AND p_purchase_date   IS NULL
     AND p_purchase_amount IS NULL
  THEN
    RAISE EXCEPTION '주문번호·구매일·구매금액 중 최소 1개는 입력해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  IF v_order_to_save IS NOT NULL AND length(v_order_to_save) > 200 THEN
    RAISE EXCEPTION '주문번호는 200자 이하여야 합니다' USING ERRCODE = '22023';
  END IF;

  IF p_purchase_amount IS NOT NULL AND p_purchase_amount < 0 THEN
    RAISE EXCEPTION '구매금액은 0 이상이어야 합니다' USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 조회(178 과 동일 + application_id 추가 조회) ───────────
  SELECT order_number, purchase_date, purchase_amount, kind, application_id
    INTO v_prev
    FROM public.deliverables
   WHERE id = p_deliverable_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '결과물을 찾을 수 없습니다 (id: %)', p_deliverable_id USING ERRCODE = '02000';
  END IF;

  IF v_prev.kind != 'receipt' THEN
    RAISE EXCEPTION '영수증 결과물만 수정 가능합니다 (kind=receipt 필요, 실제: %)', v_prev.kind
      USING ERRCODE = '22023';
  END IF;

  -- ── [302 신규] 그 응모의 정산 조회 + 상태별 차단 ────────────────────
  -- FOR UPDATE 로 행 잠금 — mark_settlement_*() RPC 들과의 동시 처리 경쟁 방지.
  -- settlements.application_id 는 UNIQUE(217) 이므로 최대 1행만 매칭된다.
  SELECT id, status, version, amount_jpy, campaign_id, receipt_amount_jpy, amount_cap_jpy
    INTO v_settlement
    FROM public.settlements
   WHERE application_id = v_prev.application_id
   FOR UPDATE;
  v_settlement_found := FOUND;  -- 이후 문장이 FOUND 를 계속 덮어쓰므로 즉시 변수로 옮김

  -- 송금완료(paid)·보류(on_hold)·취소(cancelled) — 수정 자체를 차단.
  -- (파일 상단 "여기서는 취소도 차단 대상" 설명 참고 — 301 의 제출 차단과 집합이 다르다)
  IF v_settlement_found AND v_settlement.status IN ('paid', 'on_hold', 'cancelled') THEN
    RAISE EXCEPTION 'settlement_locked_receipt_edit: 이미 처리된 정산(송금완료·보류·취소)이 연결된 영수증은 수정할 수 없습니다. 정산 상태를 먼저 확인해 주세요.'
      USING ERRCODE = '22023';
  END IF;

  -- ── no-op 체크(178 과 동일) ──────────────────────────────────────
  -- 정산 잠금 차단(바로 위)을 먼저 통과한 뒤에 검사한다 — 값이 실제로 바뀌는지와
  -- 무관하게 "정산이 paid/on_hold/cancelled 면 이 함수 호출 자체를 막는다"는 규칙을
  -- 예외 없이 적용하기 위해서다(잠긴 정산에는 no-op 호출도 허용하지 않는다).
  IF v_prev.order_number    IS NOT DISTINCT FROM v_order_to_save
     AND v_prev.purchase_date   IS NOT DISTINCT FROM p_purchase_date
     AND v_prev.purchase_amount IS NOT DISTINCT FROM p_purchase_amount
  THEN
    RETURN QUERY SELECT
      (CASE WHEN v_settlement_found THEN v_settlement.status ELSE NULL END),
      false,
      (CASE WHEN v_settlement_found THEN v_settlement.amount_jpy ELSE NULL END),
      NULL::text;
    RETURN;
  END IF;

  -- ── 관리자 이름 스냅샷(178 과 동일) ──────────────────────────────
  SELECT name INTO v_admin_name
    FROM public.admins
   WHERE auth_id = auth.uid()
   LIMIT 1;

  -- ── deliverables UPDATE(178 과 동일) ─────────────────────────────
  UPDATE public.deliverables
     SET order_number    = v_order_to_save,
         purchase_date   = p_purchase_date,
         purchase_amount = p_purchase_amount
   WHERE id = p_deliverable_id;

  -- ── receipt_edit_history INSERT(178 과 동일) ─────────────────────
  INSERT INTO public.receipt_edit_history (
    deliverable_id, changed_by, changed_by_name,
    order_number_prev, order_number_next,
    purchase_date_prev, purchase_date_next,
    purchase_amount_prev, purchase_amount_next,
    source
  ) VALUES (
    p_deliverable_id, auth.uid(), COALESCE(v_admin_name, '(이름미상)'),
    v_prev.order_number, v_order_to_save,
    v_prev.purchase_date, p_purchase_date,
    v_prev.purchase_amount, p_purchase_amount,
    'admin_edit'
  );

  -- ── [302 신규] 정산이 정산대기(pending)면 저장 직후 재계산 ─────────
  IF v_settlement_found AND v_settlement.status = 'pending' THEN
    -- "최신 영수증" 재조회 — 300 receipt_latest 와 완전히 동일한 정렬 기준.
    -- 방금 위에서 커밋 전 UPDATE 한 값이 같은 트랜잭션 안이라 바로 보인다.
    SELECT purchase_amount
      INTO v_latest_receipt_amount
      FROM public.deliverables
     WHERE application_id = v_prev.application_id AND kind = 'receipt'
     ORDER BY submitted_at DESC, updated_at DESC
     LIMIT 1;

    -- 상한 재조회 — 저장된 옛 amount_cap_jpy 재사용 금지, campaigns 를 다시 읽는다.
    SELECT product_price
      INTO v_cap
      FROM public.campaigns
     WHERE id = v_settlement.campaign_id;

    -- amount_issue 판정 3종 — 300 과 완전히 동일한 조건(⚠️ 300 계산식이 바뀌면
    -- 이 블록도 함께 고칠 것 — 파일 상단 "재계산 기준" 절 경고 참고)
    IF v_latest_receipt_amount IS NULL OR v_latest_receipt_amount <= 0 THEN
      v_amount_issue := '리뷰어형 영수증 결제 금액(purchase_amount) 값 없음 또는 0 이하';
    ELSIF v_cap IS NULL OR v_cap <= 0 THEN
      v_amount_issue := '리뷰어형 제품 가격(product_price, 지급 상한) 값 없음 또는 0 이하';
    ELSIF floor(LEAST(v_latest_receipt_amount, v_cap::numeric)) <= 0 THEN
      v_amount_issue := '리뷰어형 정산 금액이 소수점 절사 후 0 이하';
    ELSE
      v_amount_issue := NULL;
    END IF;

    IF v_amount_issue IS NOT NULL THEN
      -- ── 재계산 실패 → 자동 보류(파일 상단 "재계산 결과가 금액 미확정" 절 결정 B) ──
      -- amount_jpy/amount_source/receipt_amount_jpy/amount_cap_jpy 는 절대 건드리지
      -- 않는다 — CHECK(amount_jpy>0) 보호 + "확정된 금전 기록 보존" 원칙.
      -- ⚠️ memo 에 "자동 보류"라는 연속 문자열을 절대 쓰지 않는다(파일 상단 경고 참고 —
      -- dev/js/admin-settlements.js:338 의 신청반려 배지와 충돌한다).
      UPDATE public.settlements
         SET status  = 'on_hold',
             memo    = '영수증 수정으로 금액을 확정할 수 없어 보류 처리됨 (' || v_amount_issue || ')',
             version = version + 1
       WHERE id = v_settlement.id;

      INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
      VALUES (
        v_settlement.id, 'hold', 'pending', 'on_hold', auth.uid(),
        '영수증 수정 후 정산 금액 재계산 불가로 보류 처리 (' || v_amount_issue || ')'
      );

      v_out_status := 'on_hold';
      v_out_amount := v_settlement.amount_jpy;  -- 예전 값 그대로(변경 없음)
      v_recalculated := false;
    ELSE
      -- ── 재계산 성공 — 300 과 완전히 동일한 계산식 ──
      v_new_amount           := NULLIF(GREATEST(floor(LEAST(v_latest_receipt_amount, v_cap::numeric)), 0), 0)::bigint;
      v_new_receipt_snapshot := floor(v_latest_receipt_amount)::bigint;
      v_new_cap_snapshot     := v_cap::bigint;

      -- 실제로 달라질 때만 UPDATE+이력 기록(불필요한 settlement_events 잡음 방지 —
      -- 이 영수증 행이 "최신"이 아니었거나 값이 우연히 같으면 아무것도 안 바뀐다)
      IF v_new_amount           IS DISTINCT FROM v_settlement.amount_jpy
         OR v_new_receipt_snapshot IS DISTINCT FROM v_settlement.receipt_amount_jpy
         OR v_new_cap_snapshot     IS DISTINCT FROM v_settlement.amount_cap_jpy
      THEN
        UPDATE public.settlements
           SET amount_jpy         = v_new_amount,
               amount_source      = 'receipt_amount',
               receipt_amount_jpy = v_new_receipt_snapshot,
               amount_cap_jpy     = v_new_cap_snapshot,
               version            = version + 1
         WHERE id = v_settlement.id;

        INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
        VALUES (
          v_settlement.id, 'recalc', 'pending', 'pending', auth.uid(),
          '영수증 수정으로 정산 금액 재계산: ' || COALESCE(v_settlement.amount_jpy::text, '(없음)')
            || '엔 → ' || v_new_amount || '엔'
        );

        v_out_amount    := v_new_amount;
        v_recalculated  := true;
      ELSE
        v_out_amount := v_settlement.amount_jpy;  -- 재계산했지만 값이 같음 — no-op
      END IF;

      v_out_status := 'pending';  -- 재계산 성공 경로는 상태가 바뀌지 않는다
    END IF;
  ELSIF v_settlement_found THEN
    -- 이 지점에 도달했다는 것 자체가 이론상 불가능하다 — status IN ('paid','on_hold',
    -- 'cancelled') 는 위에서 이미 차단됐고, 남는 값은 'pending' 뿐이다(217 CHECK 로
    -- status 는 4종만 존재). 방어적으로 기존 값을 그대로 반환한다.
    v_out_status := v_settlement.status;
    v_out_amount := v_settlement.amount_jpy;
  END IF;

  RETURN QUERY SELECT v_out_status, v_recalculated, v_out_amount, v_amount_issue;
END;
$$;

COMMENT ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) IS
  '[302 재정의, 178 원본 대체(반환 타입 void→TABLE, 정산 정합 가드 추가)] 관리자가 '
  'deliverables(kind=receipt) 영수증 필드(주문번호·구매일·구매금액)를 수정하고 변경 이력을 '
  '기록하는 RPC. SECURITY DEFINER, campaign_admin 이상 필요. 그 응모에 정산(settlements)이 '
  '있으면: paid/on_hold/cancelled 는 수정 차단(RAISE EXCEPTION), pending 은 수정 허용 후 '
  '최신 영수증·현재 캠페인 상시가로 정산 금액을 재계산해 갱신(변경 시 settlement_events '
  'action=recalc 기록). 재계산이 "금액 미확정"이 되면 amount_jpy 는 그대로 두고 정산을 '
  'on_hold 로 자동 전환(action=hold, memo 로 사유 구분). 정산 행이 없으면 178 과 동일 동작.';

REVOKE ALL ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_receipt_admin(uuid, text, date, numeric) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 299·300·301 까지 적용된 뒤에 실행할 것.
--
--   ⚠️ is_campaign_admin() 은 auth.uid() 를 참조하므로 SQL Editor 의 기본 서비스 키
--   세션(auth.uid() IS NULL)으로는 이 함수를 직접 호출할 수 없다(178 원본부터 있던
--   제약, 302 가 새로 만든 제약이 아님). 아래 [V4] 부터는 274/301 과 동일한
--   "request.jwt.claims 로 관리자 계정을 흉내내는" 방식을 쓴다 — 이 함수는
--   SECURITY DEFINER 로 deliverables/settlements 를 직접 UPDATE 하므로(행 단위
--   보안 정책을 거치지 않음), 이 흉내내기 방식만으로 대부분의 분기를 SQL Editor
--   안에서 검증할 수 있다(301 의 "브라우저 필수" 제약과 다른 점 — 301 은 RLS INSERT
--   정책이 관여했지만 이 함수는 함수 내부 UPDATE 라 흉내내기로 충분하다). 다만
--   [V8](실제 저장 버튼 클릭 후 화면이 안 깨지는지)은 브라우저 확인을 권장한다.
-- ============================================================
/*

-- [V0] 함수·제약 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'update_receipt_admin';

SELECT conname, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.settlement_events'::regclass
  AND conname = 'settlement_events_action_check';
-- 기대: 'recalc' 가 허용 목록에 보임

-- [V1] 테스트 대상 확보 — status='pending' 정산 + 그 응모의 최신 영수증 1건
SELECT s.id AS settlement_id, s.version, s.status, s.amount_jpy, s.receipt_amount_jpy,
       s.amount_cap_jpy, s.campaign_id, a.user_id, d.id AS deliverable_id, d.purchase_amount
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status = 'pending'
 ORDER BY d.submitted_at DESC
 LIMIT 5;

-- [V2] 차단 대상 확보 — status IN ('paid','on_hold','cancelled') 정산 + 그 응모의 영수증 1건
SELECT s.id AS settlement_id, s.status, a.user_id, d.id AS deliverable_id
  FROM public.settlements s
  JOIN public.applications a ON a.id = s.application_id
  JOIN public.deliverables d ON d.application_id = s.application_id AND d.kind = 'receipt'
 WHERE s.status IN ('paid', 'on_hold', 'cancelled')
 LIMIT 5;

-- [V3] admins 계정 하나 확보(흉내낼 관리자) — campaign_admin 이상
SELECT auth_id, name, role FROM public.admins
 WHERE role IN ('super_admin', 'campaign_admin') LIMIT 3;

-- [V4] 차단 확인 — [V2] 의 deliverable_id 를 [V3] 관리자로 수정 시도(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V2 의 deliverable_id>'::uuid, '테스트주문', '2026-08-01'::date, 3000
  );
  -- 기대: ERROR — settlement_locked_receipt_edit: 이미 처리된 정산(...)이 연결된...
ROLLBACK;

-- [V5] 재계산 성공 확인 — [V1] 의 deliverable_id 에 상한(product_price)보다 낮은
--   금액으로 수정(반드시 ROLLBACK, 실제 반영은 [V7] 에서)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V1 의 deliverable_id>'::uuid, null, null, 1234
  );
  -- 기대: settlement_status='pending', settlement_recalculated=true,
  --       settlement_amount_jpy=1234(또는 상한 이하 시 그 값), settlement_amount_issue=NULL
ROLLBACK;

-- [V6] 재계산 실패(금액 미확정) 확인 — [V1] 의 deliverable_id 에 0 을 넣어 시도
--   ⚠️ purchase_amount=0 은 178 자체 검증("음수만 차단")은 통과하지만 302 재계산에서
--   "영수증 결제 금액 없음/0 이하"로 판정돼야 한다(반드시 ROLLBACK)
BEGIN;
  SELECT set_config('request.jwt.claims',
    json_build_object('sub', '<V3 의 auth_id>')::text, true);
  SELECT * FROM public.update_receipt_admin(
    '<V1 의 deliverable_id>'::uuid, null, null, 0
  );
  -- 기대: settlement_status='on_hold', settlement_recalculated=false,
  --       settlement_amount_jpy=(V1 의 기존 amount_jpy 그대로), settlement_amount_issue IS NOT NULL
  SELECT status, memo, amount_jpy FROM public.settlements WHERE id = '<V1 의 settlement_id>';
  -- 기대: status='on_hold', memo 에 "자동 보류"라는 연속 문자열이 없어야 함(위 검색 참고),
  --       amount_jpy 는 트랜잭션 내에서만 바뀌지 않은 값 확인(ROLLBACK 이라 실제 반영 안 됨)
ROLLBACK;

-- [V7] 실제 반영 확인(선택, COMMIT) — [V5] 를 실제로 커밋해 settlement_events 에
--   action='recalc' 행이 남는지 확인
-- BEGIN;
--   SELECT set_config('request.jwt.claims', json_build_object('sub','<V3 의 auth_id>')::text, true);
--   SELECT * FROM public.update_receipt_admin('<V1 의 deliverable_id>'::uuid, null, null, 1234);
-- COMMIT;
-- SELECT action, prev_status, next_status, memo FROM public.settlement_events
--  WHERE settlement_id = '<V1 의 settlement_id>' ORDER BY at DESC LIMIT 1;
-- -- 기대: action='recalc', prev_status='pending', next_status='pending'

-- [V8] 회귀 — 정산이 아예 없는 응모의 영수증을 관리자 화면(브라우저)에서 정상 수정.
--   기대: 기존과 동일하게 성공(에러 없음), receipt_edit_history 에 새 행 1건.

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ settlement_events 에 이미 action='recalc' 행이 쌓였다면, CHECK 제약을 5종으로
--    되돌리기 전에 그 행들을 먼저 삭제하거나 action 값을 다른 값으로 바꿔야 한다
--    (그렇지 않으면 아래 ADD CONSTRAINT 자체가 기존 데이터 위반으로 실패한다).
--
-- DROP FUNCTION IF EXISTS public.update_receipt_admin(uuid, text, date, numeric);
-- -- 178 버전(RETURNS void, 정산 가드 없음)으로 복원하려면
-- -- supabase/migrations/178_relax_update_receipt_admin.sql 의
-- -- "update_receipt_admin RPC" CREATE OR REPLACE 블록 전체를 SQL Editor 에서 재실행.
--
-- ALTER TABLE public.settlement_events
--   DROP CONSTRAINT IF EXISTS settlement_events_action_check;
-- ALTER TABLE public.settlement_events
--   ADD CONSTRAINT settlement_events_action_check
--   CHECK (action IN ('create', 'pay', 'hold', 'cancel', 'revert'));


-- ───────────────────────────────────────────────────────────────
-- [파일 303] 303_faq_receipt_payback_amount.sql
-- ───────────────────────────────────────────────────────────────
-- ============================================================
-- 303_faq_receipt_payback_amount.sql
-- 자주 묻는 질문(faq_nodes)에 「최대 금액인데 왜 적게 받았나요」 항목 추가
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-3 (자)
--
-- ── 왜 필요한가 ──
--   300 으로 리뷰어형 정산이 「영수증 실결제액(상시가를 상한으로 자름)」이 되면서,
--   화면 문구도 「¥N 円ペイバック」(금액 약속) → 「購入金額をペイバック（最大 ¥N）」
--   (상한 안내)로 바뀐다. 그 결과 **새 문의 유형**이 생긴다 —
--   「최대 2,000엔이라고 써 있었는데 1,500엔만 들어왔다」.
--   이 항목이 없으면 그 문의가 전부 사람 응대(응모건 메시지)로 몰린다.
--
-- ── 어디에 붙는가 ──
--   카테고리 5 「보수·정산」(00000001-0000-0000-0000-000000000005) 아래.
--   기존 항목 2개(Q5-1 리워드 수령 방법 sort_order=10 / Q5-2 PayPal 변경 =20)
--   다음에 오도록 sort_order=30.
--
-- ── 문안 원칙 (.claude/rules/ui.md 「인플루언서 안내 문구」) ──
--   초등학생 눈높이 · 한 문장 한 동작 · 번호 단계 · 마지막은 안전망으로 닫기.
--   ⚠️ 「상한을 넘으면 승인되지 않을 수 있다」는 활동관리 입력 안내(2.5단계)와 같은
--      사실을 말하지만, 여기서는 **이미 지급된 뒤 보는 문의**라 승인 얘기를 앞세우지
--      않는다. 받은 금액이 왜 그 금액인지부터 답한다.
--
-- ── 되돌리기 ──
--   DELETE FROM public.faq_nodes WHERE id = '00000002-0000-0000-0005-000000000003';
--   (faq_interactions 는 node_id 참조가 CASCADE 라 함께 정리된다)
-- ============================================================

INSERT INTO public.faq_nodes
  (id, parent_id, kind, label_ko, label_ja, body_ko, body_ja,
   action_type, action_target, action_label_ko, action_label_ja,
   is_human_handoff, relevant_stages, sort_order, active)
VALUES
  ('00000002-0000-0000-0005-000000000003'::uuid,
   '00000001-0000-0000-0000-000000000005'::uuid,
   'item',
   '「최대 금액」이라고 쓰여 있는데 적게 들어왔어요',
   '「最大金額」と書いてあるのに、少なく振り込まれました',
   '리뷰어형 캠페인은 다음과 같이 계산합니다.
1. 영수증에 적힌 「실제로 지불한 금액」을 그대로 돌려드립니다.
2. 쿠폰이나 포인트를 쓰셔서 싸게 사셨다면, 그 싸게 산 금액이 들어갑니다.
3. 「최대」는 제품 가격을 말합니다. 그 금액을 넘겨 드리지는 않습니다.
받으신 금액이 영수증 금액과 다르다고 생각되시면, 아래 「직접 문의」로 알려 주세요.',
   'レビュアー型のキャンペーンは、つぎのように計算しています。
1. レシートに書かれた「実際にお支払いした金額」を、そのままお返しします。
2. クーポンやポイントを使って安く買われた場合は、その安く買われた金額をお振込みします。
3. 「最大」は商品価格のことです。その金額を超えてお振込みすることはありません。
お振込みされた金額がレシートの金額とちがうと思われる場合は、下の「直接お問い合わせ」からお知らせください。',
   'navigate', '#mypage-settlements', '정산 내역 보기', '精算履歴を見る',
   false, ARRAY['done'], 30, true)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 항목이 「보수·정산」 카테고리 아래에 붙었는지 (3건이어야 함)
SELECT sort_order, label_ko, label_ja, active
  FROM public.faq_nodes
 WHERE parent_id = '00000001-0000-0000-0000-000000000005'::uuid
   AND kind = 'item'
 ORDER BY sort_order;

-- [V2] 이동 버튼이 실제 화면 경로를 가리키는지 — 인플루언서 앱의 정산 화면 해시
--   (dev/js/mypage.js openMypageSub('settlements') · 해시 #mypage-settlements)
SELECT label_ko, action_type, action_target, action_label_ja
  FROM public.faq_nodes
 WHERE id = '00000002-0000-0000-0005-000000000003'::uuid;
-- 기대: navigate / #mypage-settlements
--   ⚠️ 정산 화면은 settlement_settings.influencer_visible=false 인 동안 인플루언서에게
--      잠겨 있다. 잠금 상태에서 이 버튼을 누르면 응모이력으로 되돌아간다(mypage.js 폴백).
--      정산을 공개하기 전까지는 이 항목의 이동 버튼이 사실상 동작하지 않는 셈이므로,
--      3단계 배포 시점에 정산 공개 여부와 함께 확인할 것.
*/

