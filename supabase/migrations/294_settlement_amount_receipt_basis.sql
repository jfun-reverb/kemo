-- ============================================================
-- 294_settlement_amount_receipt_basis.sql
-- 리뷰어형 정산 금액을 영수증 실결제액 기준으로 전환 — 2/2
--   (헬퍼 재정의 + 호출 함수 3개 동시 재정의, 한 파일·한 트랜잭션)
-- 사양서: docs/specs/2026-08-05-settlement-receipt-amount-switch.md §3-1, §3-2 마이그레이션②
--
-- ⚠️ **293 을 먼저 적용해야 한다.** 이 파일의 저장 함수들이 293 이 만드는 칸 2개
--    (receipt_amount_jpy·amount_cap_jpy)에 INSERT 하므로, 293 없이 실행하면 그 자리에서
--    실패한다. 적용 순서: 293 → 294 → 295. 롤백 순서는 그 역순.
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
--   2) 헬퍼 반환 테이블에 receipt_amount_jpy·amount_cap_jpy 2컬럼 추가(293 이 만든 감사용
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
    -- (294 는 여기를 손대지 않는다 — 금액 계산은 아래 최종 SELECT 에서만 바뀐다).
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
    -- [294] 264(=262=232 원본)와 동일한 DISTINCT ON/ORDER BY(어느 행이 "최신"인지 판정은
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
    -- ── [294 신규] 금액 계산: 리뷰어형(monitor, 가구매 포함) = min(영수증, 상시가) 절사 ──
    -- ⚠️ LEAST() 는 NULL 을 무시하는 함수라(파일 상단 경고 참고) 두 값이 모두 유효할
    -- 때만 호출한다 — 그렇지 않으면 "영수증 없음"이 조용히 "상시가로 대체"돼 버린다.
    CASE
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount IS NOT NULL AND rl.purchase_amount > 0
           AND cd.product_price   IS NOT NULL AND cd.product_price   > 0
        THEN floor(LEAST(rl.purchase_amount, cd.product_price::numeric))::bigint
      WHEN cd.recruit_type = 'monitor' THEN NULL::bigint  -- 아래 amount_issue 로 사유가 채워짐
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'receipt_amount'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(261 부터 그대로)
    -- ── [294 신규] 감사용 칸 2개(293) — 리뷰어형만 채움, 그 외 NULL ──
    CASE WHEN cd.recruit_type = 'monitor' THEN floor(rl.purchase_amount)::bigint ELSE NULL::bigint END AS receipt_amount_jpy,
    CASE WHEN cd.recruit_type = 'monitor' THEN cd.product_price ELSE NULL::bigint END AS amount_cap_jpy,
    -- ── [294 신규] amount_issue: 조건 3종(사양서 §3-1·§3-2) ──
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
  '[294 재정의, 264 원본 대체(반환 컬럼 2개 추가: receipt_amount_jpy·amount_cap_jpy)] private '
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
  v_notify          boolean;  -- [242 계승, 262 유지, 294 도 유지] 인플루언서 공개 스위치(240)
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

  -- ── [242→262 계승, 294 도 유지] 인플루언서 노출 잠금 조회 ──
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
  '[294 재정의, 262 원본 대체(알림 잠금 게이트 계승 유지)] 금액을 _settlement_cert_candidates() '
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
  '[294 재정의, 262 원본 대체(반환 타입 변경으로 DROP 후 재생성 — receipt_amount_jpy/'
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
  '[294 재정의, 262 원본 대체] 금액을 _settlement_cert_candidates() 헬퍼가 계산한 amount_jpy/'
  'amount_source/reward_part_jpy/receipt_amount_jpy/amount_cap_jpy 로 저장. amount_issue 가 '
  '있는 건(금액 NULL/0 이하)은 서버가 조용히 skip(예외 아님) — 반환값(등록 건수)이 실제 처리 건수. '
  '⚠️ settlement_paid/settlement_paypal_required 알림 둘 다 발행하지 않는 233 원칙 그대로 유지. '
  '나머지(재검증·멱등·컷오프 필터·paid 분기 시 paid_at/paid_by·이력 기록·권한 게이트)는 233 그대로.';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 293 까지 적용된 뒤에 실행할 것.
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

-- [V2] 인증 성공 집계가 293/294 적용 전후로 그대로인지 확인(§5-1 "인증 성공 집계 영향
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
-- 방법 B) 293 도 함께 롤백하려면 293 파일 하단 롤백 절차를 이 순서 다음에 실행할 것
--   (293 은 컬럼만 추가하므로 이 파일 롤백과 독립적이지만, 완전 원복 시 함께 되돌림).
