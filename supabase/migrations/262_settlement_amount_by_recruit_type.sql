-- ============================================================
-- 262_settlement_amount_by_recruit_type.sql
-- 정산 금액 산정 규칙 변경 PR1 — 2/2 (형식별 금액 계산 헬퍼 + 함수 3개 동시 재정의)
-- 사양서: docs/specs/2026-07-23-settlement-reviewer-receipt-amount.md §3-1, §3-2 마이그레이션②
--
-- ── 이 마이그레이션이 하는 일 ──
--   리뷰어형(monitor) 캠페인 57개(승인 응모 1,065건)가 정산 후보에서 통째로
--   빠져 있던 원인(candidates CTE 의 "c.reward > 0" 조건 — 리뷰어형은 실무상
--   reward 가 전부 0)을 없애고, 모집 형식별로 금액 출처를 분기한다:
--     리뷰어형(monitor, 가구매 여부 무관) → campaigns.product_price
--     시딩(gifting)·방문형(visit)         → campaigns.reward(현행 그대로)
--   가구매(proxy_purchase)는 금액 계산에서 분기하지 않는다 — 인증 성공 판정에서만
--   갈린다(영수증만 vs 영수증＋채널별 인증샷, 아래 인증 성공 CASE 문 참고).
--
--   공용 헬퍼 `public._settlement_cert_candidates()`(마이그레이션 232) 의 반환
--   항목이 늘어나므로(amount_jpy/amount_source/reward_part_jpy/amount_issue 추가)
--   CREATE OR REPLACE 로는 안 되고(반환 타입 변경은 DROP 필수) DROP 후 재생성한다.
--   같은 이유로 `get_past_unregistered_settlements()` 도 반환 컬럼이 늘어(amount_source·
--   amount_issue·campaign_no 추가) DROP 후 재생성한다. `backfill_settlements()`·
--   `register_past_settlements()` 는 반환 타입이 그대로라 CREATE OR REPLACE 로 충분하다.
--
-- ── DROP 순서(의존성 처리) ──
--   PostgreSQL 은 PL/pgSQL(backfill_settlements/get_past_unregistered_settlements/
--   register_past_settlements) 함수 본문 안에서의 함수 호출을 pg_depend 에 하드
--   의존성으로 기록하지 않는다(뷰가 하부 테이블에 의존성을 갖는 것과 다름 — 함수
--   본문은 opaque text 라 호출 대상 존재 여부는 실행 시점에만 확인된다). 즉
--   `_settlement_cert_candidates()` 를 먼저 DROP 해도 문법적으로는 에러가 나지 않는다.
--   그래도 "의존 함수를 먼저 처리한다" 원칙을 명시적으로 지키기 위해, 반환 타입이
--   바뀌는 두 함수를 아래 순서로 DROP → 재생성한다:
--     1) DROP get_past_unregistered_settlements()   (헬퍼를 호출하는 쪽 — 먼저 제거)
--     2) DROP _settlement_cert_candidates()          (헬퍼 — 그다음 제거)
--     3) CREATE _settlement_cert_candidates()        (헬퍼부터 새로 만들어야 아래
--                                                        CREATE OR REPLACE 들이 최신
--                                                        반환 컬럼을 참조할 수 있음)
--     4) CREATE OR REPLACE backfill_settlements()     (반환 타입 불변 — DROP 불필요)
--     5) CREATE get_past_unregistered_settlements()   (헬퍼 재생성 후 다시 만듦)
--     6) CREATE OR REPLACE register_past_settlements() (반환 타입 불변 — DROP 불필요)
--   전부 이 파일 하나의 트랜잭션(마이그레이션 파일 = 암묵적 단일 트랜잭션)에서 실행되므로
--   중간에 실패하면 전체가 롤백되어 "헬퍼는 새 버전, 함수는 옛 버전" 같은 반쪽 상태가
--   남지 않는다.
--
-- ── 인증 성공 판정은 한 글자도 바꾸지 않음(사양서 §3-2 강조) ──
--   receipt_latest/post_latest/review_channel_latest/channel_cert CTE 와 is_success·
--   cert_at 의 CASE 문은 마이그레이션 232 원본을 그대로 복사했다. 화면
--   dev/js/admin-deliverables.js 의 computeCertStatus() 와의 단일 소스 정합을 지키기
--   위함 — 이번 변경은 오직 "금액을 어디서 가져오는가" 만 바꾼다.
--
-- ── candidates CTE 조건 변경(사양서 §3-1·§3-2) ──
--   기존: WHERE a.status='approved' AND c.reward > 0 AND inf.is_audit=false AND (미등록)
--   변경: "c.reward > 0" 제거. 대신 형식별 계산 금액이 NULL 이거나 0 이하면
--   amount_issue 에 사유를 채운다(저장은 안 하고 후보로는 남겨 관리자 화면에서
--   "금액 확인 필요"로 보이게 하기 위함 — 사양서 §3-3 (나)). 시딩·방문형의 리워드
--   0원 캠페인은 amount_issue 가 서서 결과적으로 지금처럼 실제 정산 대상이 되지
--   않는다(§3-1 "세부 규칙" 마지막 항목과 결과적으로 동일).
--
-- ── amount_issue 미확정 건은 저장하지 않음(사양서 §2-1 ①) ──
--   settlements.amount_jpy 는 CHECK (amount_jpy > 0) 이 걸려 있다(마이그레이션 217).
--   자동 등록(backfill_settlements)은 여러 건을 한 INSERT 문으로 넣으므로, 그중
--   금액이 NULL/0 이하인 행이 하나라도 섞이면 배치 전체가 실패한다. 따라서
--   `amount_issue IS NULL` 인 행만 INSERT 대상에 포함한다(현재 실측상 리뷰어형은
--   가격 누락 0건이라 즉시 위험은 없지만, 앞으로 가격 없는 캠페인이 생길 대비).
--   과거 수동 등록(register_past_settlements)도 동일하게 조용히 skip 한다(예외 아님 —
--   233 원본의 "재검증 후 통과분만 INSERT" 원칙 연장).
--
-- ── 합산(product_plus_reward)은 이번에 구현하지 않음(사양서 §6 Q1 보류) ──
--   금액 계산은 recruit_type 하나로만 분기하며, reward_part_jpy 는 항상 NULL 로 둔다.
--   나중에 합산을 채택하면 이 파일의 "금액 계산" CASE 문 한 곳(candidates 최종 SELECT)
--   만 고치면 되도록 계산 로직을 헬퍼 한 곳에 모아 뒀다(backfill_settlements·
--   get_past_unregistered_settlements·register_past_settlements 는 전부 헬퍼가 계산한
--   값을 그대로 가져다 쓸 뿐 자체 계산을 하지 않는다).
--
-- ── 변경하지 않는 것(사양서 §3-2) ──
--   인증 성공 판정, 정산 도입일 컷오프 조건, PayPal 미등록 알림의 인플루언서 노출
--   잠금 게이트(v_notify — 아래 ⚠️ 참고), 이력(settlement_events) 기록, 과거 수동
--   등록의 "알림 없음" 원칙, 권한 게이트(has_permission), 낙관적 락·동시성 처리.
--
-- ── ⚠️ backfill_settlements() 의 "현재 유효한 원본"은 232 가 아니라 242 다 ──
--   232 가 만든 backfill_settlements() 를 마이그레이션 242 가 CREATE OR REPLACE 로
--   다시 정의하면서 알림 잠금 게이트(v_notify := is_settlement_public(), notif_ins
--   WHERE v_notify)를 얹었다. 이 마이그레이션이 232 본문만 보고 재정의하면 242 의
--   잠금이 조용히 풀려, 운영 기본값(influencer_visible=false)인데도 인플루언서에게
--   settlement_paypal_required 알림이 나간다(리뷰 지적 2026-07-23 — 실제로 초안에서
--   이 사고가 났고 커밋 전에 복구함). 함수를 CREATE OR REPLACE 로 재정의할 때는
--   **파일 번호가 가장 큰 정의**를 베이스로 삼을 것.
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
    -- 정산 대상 후보: 승인된 응모 + 감사용 제외 + 아직 정산행 없음(멱등).
    -- ⚠️ [262] "c.reward > 0" 조건 제거 — 리뷰어형(monitor)은 실무상 reward 가
    -- 전부 0 이고 금액은 product_price 에서 나오므로, 여기서 걸러내면 리뷰어형
    -- 전량이 후보에서 사라진다(이번 변경의 발단). 형식별 금액 유효성은 아래
    -- amount_issue 계산으로 개별 판정한다.
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
  ),
  receipt_latest AS (
    -- 232 와 동일: 응모별 영수증(receipt) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 232 와 동일: 응모별 게시물(post) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 232 와 동일: 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 232 와 동일: 리뷰어(monitor 일반) 응모의 캠페인 채널 전체 인증샷 승인시각
    -- 최댓값 + 완전성 강제(any_null). (변경 없음 — 인증 성공 판정은 그대로)
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
    -- ── [262 신규] 금액 계산: recruit_type 하나로만 분기(가구매 여부 무관) ──
    -- 리뷰어형(monitor, 가구매 포함) = campaigns.product_price
    -- 시딩(gifting)·방문형(visit)     = campaigns.reward (현행 그대로)
    -- 나중에 현금 보수 합산(product_plus_reward)을 채택하면 이 CASE 문 한 곳만 고치면
    -- 된다(backfill_settlements 등 호출부는 계산된 값을 그대로 가져다 쓸 뿐이다).
    CASE
      WHEN cd.recruit_type = 'monitor' THEN cd.product_price
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'product_price'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(§6 Q1 보류)
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.product_price IS NULL
        THEN '리뷰어형 제품 가격(product_price) 값 없음'
      WHEN cd.recruit_type = 'monitor' AND cd.product_price <= 0
        THEN '리뷰어형 제품 가격(product_price) 0 이하'
      WHEN cd.recruit_type <> 'monitor' AND cd.reward IS NULL
        THEN '시딩·방문형 현금 리워드(reward) 값 없음'
      WHEN cd.recruit_type <> 'monitor' AND cd.reward <= 0
        THEN '시딩·방문형 현금 리워드(reward) 0 이하'
      ELSE NULL
    END AS amount_issue,
    -- ── is_success: 232(=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
    -- ── cert_at: 232(=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
  '[262 재정의, 232 원본 대체] private 헬퍼 — 정산 미등록(settlements 행 없음) 응모 전체에 '
  '대해 인증 성공 여부(is_success)·인증 성공일(cert_at, 판정 로직은 232 그대로 무변경)에 더해 '
  '모집 형식별 정산 금액(amount_jpy)·금액 출처(amount_source: reward|product_price|'
  'product_plus_reward)·금액 미확정 사유(amount_issue, 정상이면 NULL)를 계산한다. '
  '리뷰어형(monitor, 가구매 포함)=campaigns.product_price, 시딩·방문형=campaigns.reward. '
  '후보 조건에서 "c.reward > 0" 제거(리뷰어형 전량 배제 원인 해소) — 대신 형식별 금액이 '
  'NULL/0 이하면 amount_issue 로 표시. backfill_settlements()·'
  'get_past_unregistered_settlements()·register_past_settlements() 3곳이 이 함수 하나를 '
  '호출해 판정·금액 로직 드리프트를 원천 차단한다. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 RPC 호출 불가) — 232 와 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

-- ============================================================
-- 2. backfill_settlements() 재정의 — 반환 타입 불변(CREATE OR REPLACE 충분)
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
  v_notify          boolean;  -- [242 계승] 인플루언서 공개 스위치(240) — true 일 때만 알림 발송
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read (232 와 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  -- ── [242 계승] 인플루언서 노출 잠금 조회 ──
  -- ⚠️ 이 함수의 "현재 유효한 원본"은 232가 아니라 **242**다. 242가 232 버전 위에
  --    알림 게이트(v_notify)를 얹었으므로, 이 마이그레이션이 232만 보고 재정의하면
  --    242의 잠금이 조용히 풀린다(운영 기본값 influencer_visible=false 인데도
  --    settlement_paypal_required 알림이 나가는 사고). 아래 v_notify 선언·조회·
  --    notif_ins WHERE 조건 3종은 242에서 그대로 가져온 것이며, 절대 제거 금지.
  v_notify := public.is_settlement_public();

  WITH cert AS (
    SELECT * FROM public._settlement_cert_candidates()
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy, paypal_email
    )
    SELECT influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
           NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외(PR2로 이관)
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외(PR2 수동 처리)
      AND amount_issue IS NULL         -- [262 신규] 금액 미확정 건은 CHECK(amount_jpy>0) 위반으로
                                        -- 배치 전체가 실패하는 것을 막기 위해 저장 대상에서 제외
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
    -- [242 계승] WHERE v_notify — settlement_settings.influencer_visible=false(운영 기본값)
    --   이면 inserted 행이 있어도 이 CTE 는 0건 INSERT(안전측 — 코드 재배포 없이
    --   240 스위치 한 줄로 공개 전환). 제거 금지.
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
  '[262 재정의, 232 원본 대체] 금액을 _settlement_cert_candidates() 헬퍼가 계산한 amount_jpy/'
  'amount_source/reward_part_jpy 로 저장(기존 "무조건 campaigns.reward" 대체 — 리뷰어형은 '
  'product_price, 시딩·방문형은 reward). amount_issue 가 있는 건(금액 NULL/0 이하)은 저장 '
  '대상에서 제외해 배치 INSERT 가 CHECK(amount_jpy>0) 위반으로 전체 실패하는 것을 방지. '
  '컷오프·게이트·이력/알림 INSERT 는 232 그대로(변경 없음).';

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
    c.amount_issue,
    c.cert_at
  FROM public._settlement_cert_candidates() c
  WHERE c.is_success
    -- ── 명시적 컷오프 필터(232 원본과 동일, 호출 순서 비의존) ──
    -- "과거분" = 컷오프 이전 인증성공(cert_at < v_cutoff) 또는 판정시각 불명 레거시
    -- (cert_at NULL) 또는 컷오프 미설정(v_cutoff NULL — 세팅 전엔 전부 수동 대상).
    AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff);
    -- ⚠️ [262] amount_issue 가 있는 행도 일부러 걸러내지 않고 그대로 반환한다 —
    -- 관리자 화면(§3-3 (다))이 이 값으로 체크박스를 비활성화하고 사유 배지를
    -- 보여줘야 하므로, 여기서 숨기면 "왜 이 건이 안 보이지"라는 혼란만 남긴다.
END;
$$;

COMMENT ON FUNCTION public.get_past_unregistered_settlements() IS
  '[262 재정의, 232 원본 대체(반환 타입 변경으로 DROP 후 재생성)] 과거 미등록 인증성공 응모 '
  '목록(정산 페인 「과거 미등록」 UI). amount_jpy/amount_source/amount_issue/campaign_no 를 '
  '추가 반환(사양서 2026-07-23 §3-2) — 리뷰어형은 product_price, 시딩·방문형은 reward 기준 '
  '금액, amount_issue 있는 행은 화면에서 체크박스 비활성 대상. 필터·권한 게이트는 232 그대로.';

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
  -- ── 권한 게이트: settlement.pay 최소 write (233 과 동일) ──
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
    -- amount_issue 로 재검증한다. [262 신규] amount_issue 가 있는 건(금액 NULL/0 이하)은
    -- 여기서 조용히 제외한다(예외 아님 — 부분 성공 허용, 반환값이 곧 실제 처리 건수).
    SELECT c.application_id, c.influencer_id, c.campaign_id,
           c.amount_jpy, c.amount_source, c.reward_part_jpy, c.paypal_email
    FROM public._settlement_cert_candidates() c
    WHERE c.application_id = ANY(p_application_ids)
      AND c.is_success
      AND c.amount_issue IS NULL
      -- 명시적 컷오프 필터(232 조회와 동일) — 컷오프 이후 신규건은 자동 백필 대상이라
      -- 수동 무알림 처리에서 제외.
      AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id,
      t.amount_jpy, t.amount_source, t.reward_part_jpy,
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
  '[262 재정의, 233 원본 대체] 금액을 _settlement_cert_candidates() 헬퍼가 계산한 amount_jpy/'
  'amount_source/reward_part_jpy 로 저장(기존 "무조건 t.reward" 대체). amount_issue 가 있는 '
  '건(금액 NULL/0 이하)은 서버가 조용히 skip(예외 아님) — 반환값(등록 건수)이 실제 처리 건수. '
  '⚠️ settlement_paid/settlement_paypal_required 알림 둘 다 발행하지 않는 233 원칙 그대로 유지. '
  '나머지(재검증·멱등·컷오프 필터·paid 분기 시 paid_at/paid_by·이력 기록·권한 게이트)는 233 그대로.';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 261 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 3개 + 헬퍼 반환 타입 확인
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

-- [V2] 리뷰어형(monitor) 후보가 이제 잡히는지 — 운영 실측 사례(§0)와 같은 규모인지 확인.
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

-- [V3] backfill_settlements() 회귀 확인 — 컷오프 미설정이면 여전히 created_count=0 이어야 함
SELECT cutoff_at FROM public.settlement_settings;
SELECT * FROM public.backfill_settlements();

-- [V4] get_past_unregistered_settlements() 스모크 — 리뷰어형 건이 amount_source='product_price' 로 보이는지
--   (앱에서 campaign_admin 세션으로 확인 — SQL Editor 직접 호출은 permission_denied 가능)
-- SELECT recruit_type, amount_source, amount_issue, amount_jpy, campaign_no, cert_at
-- FROM public.get_past_unregistered_settlements()
-- ORDER BY cert_at NULLS FIRST
-- LIMIT 20;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 방법 A) 이 마이그레이션이 바꾼 것만 232/233 원본으로 되돌리려면(역순):
--   1) register_past_settlements() 를 233_settlement_register_past_fn.sql 의
--      CREATE OR REPLACE 블록을 그대로 재실행해 원본으로 되돌림.
--   2) DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
--      이어서 232_settlement_past_unregistered_query.sql 의 해당 CREATE OR REPLACE
--      블록을 재실행(232 는 CREATE OR REPLACE 였으므로 반환 타입이 262 버전과
--      다르면 먼저 DROP 해야 함 — 위 DROP 문 필수).
--   3) backfill_settlements() 를 232_settlement_past_unregistered_query.sql 의
--      CREATE OR REPLACE 블록을 그대로 재실행해 원본으로 되돌림.
--   4) DROP FUNCTION IF EXISTS public._settlement_cert_candidates();
--      이어서 232_settlement_past_unregistered_query.sql 의 헬퍼 CREATE OR REPLACE
--      블록을 재실행해 원본(261 이전 반환 컬럼)으로 되돌림.
-- 방법 B) 261 도 함께 롤백하려면 261 파일 하단 롤백 절차를 이 순서 다음에 실행할 것
--   (261 은 컬럼만 추가하므로 이 파일 롤백과 독립적이지만, 완전 원복 시 함께 되돌림).
