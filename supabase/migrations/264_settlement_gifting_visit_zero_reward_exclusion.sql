-- ============================================================
-- 264_settlement_gifting_visit_zero_reward_exclusion.sql
-- 정산 후보 조건 정정 — 무보수 시딩·방문형 캠페인을 "금액 오류"가 아니라
-- 애초에 "정산 후보 아님"으로 되돌림
-- 사양서: docs/specs/2026-07-23-settlement-reviewer-receipt-amount.md §3-1
--
-- ── 문제(운영 실측) ──
--   마이그레이션 262 가 candidates CTE 의 "c.reward > 0" 조건을 없애면서, 리뷰어형
--   (monitor)의 정당한 목적(product_price 기반 후보 포함)은 달성했지만 부작용으로
--   현금 리워드가 없는 시딩(gifting)·방문형(visit) 캠페인(= 제품만 제공하는 정상
--   무보수 캠페인)까지 후보에 들어와 amount_issue='시딩·방문형 현금 리워드(reward)
--   값 없음/0 이하' 로 표시됐다. 운영 조회 결과 gifting 인증성공 300건 중 261건이
--   이 사유였다(정상 캠페인 34개 중 33개가 reward=0). 262 이전에는 "c.reward > 0"
--   조건이 이들을 애초에 걸러냈으므로, "대상 아님"과 "진짜 금액 오류"가 뒤섞인
--   회귀다. 사양서 §3-1 "세부 규칙" 마지막 항목: "시딩·방문형의 리워드 0원
--   캠페인은 지금처럼 정산 대상이 아니다(제품 제공만 있는 캠페인 — 약관 제13조
--   3항과 일치)" — 262가 이 원칙을 지키지 못한 것을 이 마이그레이션이 되돌린다.
--
-- ── 이 마이그레이션이 하는 일 ──
--   `public._settlement_cert_candidates()` 를 CREATE OR REPLACE 로 재정의(반환
--   타입은 262 와 완전히 동일 — 컬럼 추가/삭제 없음, DROP 불필요):
--     1) candidates CTE 의 WHERE 절에 아래 조건 추가:
--        NOT (c.recruit_type <> 'monitor' AND (c.reward IS NULL OR c.reward <= 0))
--        → 시딩·방문형이면서 reward 가 NULL 이거나 0 이하인 건은 애초에 후보에서
--          제외(262 이전 "c.reward > 0" 동작과 동일한 효과를, monitor 는 건드리지
--          않는 방식으로 재현).
--     2) amount_issue CASE 문에서 "시딩·방문형 reward NULL/0이하" 2개 분기는 위
--        WHERE 절 제외로 이제 도달 불가능해졌으므로 제거(죽은 분기를 남겨두면
--        "amount_issue 가 시딩·방문형에서도 나올 수 있다"는 잘못된 인상을 준다).
--        monitor 의 product_price NULL/0이하 분기는 그대로 유지 — 이건 진짜
--        데이터 오류라 화면에 드러나야 한다(사양서 §3-3 (다)).
--
-- ── 변경하지 않는 것 ──
--   - 인증 성공 판정(is_success)·인증 성공일(cert_at) 계산: receipt_latest/
--     post_latest/review_channel_latest/channel_cert CTE 와 두 CASE 문은 262 원본을
--     한 글자도 안 바꾸고 그대로 복사했다. 화면 dev/js/admin-deliverables.js 의
--     computeCertStatus() 와의 단일 소스 정합 유지.
--   - 금액 계산(amount_jpy/amount_source) 자체 — monitor=product_price,
--     시딩·방문형=reward 분기는 262 그대로. 이번 변경은 "후보에 들어오느냐 마느냐"
--     만 바꾼다.
--   - 리뷰어형(monitor) 의 product_price 관련 amount_issue 분기 — 유지.
--   - backfill_settlements()·get_past_unregistered_settlements()·
--     register_past_settlements() 3개 호출부 — 반환 컬럼 구성이 그대로라 손대지
--     않는다. 헬퍼가 후보 자체를 덜 반환하게 되므로 자동으로 새 동작을 따른다.
--
-- ── ⚠️ 이 함수의 "현재 유효한 원본"은 262 다 (전수 확인 결과) ──
--   grep -rl "_settlement_cert_candidates" supabase/migrations/ 로 확인한 결과
--   이 함수를 정의/재정의한 파일은 232(원본 CREATE OR REPLACE) → 262(DROP 후
--   CREATE, 반환 컬럼 4개 추가) 두 곳뿐이다. 233 은 헬퍼를 호출만 하고 정의하지
--   않는다. 따라서 262 를 베이스로 삼는다(파일 번호가 가장 큰 정의 원칙,
--   .claude/rules/session-roles.md·262 파일 자체 경고 문구 준수).
--   ⚠️ backfill_settlements() 는 262 가 이미 242 의 알림 잠금 게이트(v_notify)를
--   계승해 뒀으므로 이 파일은 backfill_settlements() 를 아예 건드리지 않는다 —
--   헬퍼 안 조건만 바뀌므로 잠금 게이트를 다시 베낄 필요가 없다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public._settlement_cert_candidates()
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
    -- 정산 대상 후보: 승인된 응모 + 감사용 제외 + 아직 정산행 없음(멱등)
    -- + [264 신규] 무보수 시딩·방문형 제외.
    -- ⚠️ [262] "c.reward > 0" 조건은 여전히 없다(리뷰어형은 reward 가 전부 0 이라
    -- 그 조건을 되살리면 262 의 원래 목적이 도로 깨진다). 대신 [264] 아래 조건으로
    -- "시딩·방문형이면서 reward 가 NULL/0 이하"인 경우만 정확히 걸러낸다 — monitor 는
    -- 이 조건의 영향을 받지 않는다(recruit_type <> 'monitor' 로 한정).
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
      -- [264 신규] 시딩(gifting)·방문형(visit) 이면서 현금 리워드가 없는 캠페인은
      -- "금액 오류"가 아니라 "제품만 제공하는 정상 무보수 캠페인"이라 애초에 후보에서
      -- 제외한다(262 이전 "c.reward > 0" 과 동일한 결과를, monitor 를 건드리지 않는
      -- 방식으로 재현). 사양서 §3-1 "세부 규칙" 마지막 항목 근거.
      AND NOT (
        c.recruit_type <> 'monitor'
        AND (c.reward IS NULL OR c.reward <= 0)
      )
  ),
  receipt_latest AS (
    -- 262(=232 원본)와 동일: 응모별 영수증(receipt) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 262(=232 원본)와 동일: 응모별 게시물(post) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 262(=232 원본)와 동일: 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각. (변경 없음)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 262(=232 원본)와 동일: 리뷰어(monitor 일반) 응모의 캠페인 채널 전체 인증샷
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
    -- ── 금액 계산: 262 그대로(변경 없음) ──
    CASE
      WHEN cd.recruit_type = 'monitor' THEN cd.product_price
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'product_price'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(262 부터 그대로)
    -- [264] amount_issue: 시딩·방문형 reward NULL/0이하 2개 분기 제거 —
    -- candidates CTE 의 WHERE 절에서 이미 걸러내 이제 도달 불가능하기 때문(살아있는
    -- 죽은 코드를 남기면 "이 사유가 시딩·방문형에서도 나올 수 있다"는 오해를 준다).
    -- monitor 의 product_price NULL/0이하 2개 분기는 그대로 유지 — 진짜 데이터
    -- 오류라 화면에 드러나야 한다(사양서 §3-3 (다)).
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.product_price IS NULL
        THEN '리뷰어형 제품 가격(product_price) 값 없음'
      WHEN cd.recruit_type = 'monitor' AND cd.product_price <= 0
        THEN '리뷰어형 제품 가격(product_price) 0 이하'
      ELSE NULL
    END AS amount_issue,
    -- ── is_success: 262(=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
    -- ── cert_at: 262(=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
  '[264 재정의, 262 원본 대체(반환 타입 불변)] private 헬퍼 — candidates CTE 에서 '
  '"시딩(gifting)·방문형(visit) 이면서 reward NULL/0 이하"인 캠페인을 후보에서 제외 '
  '(262 가 "c.reward > 0" 을 없애며 생긴 부작용 — 무보수 정상 캠페인이 amount_issue 로 '
  '오표시되던 것을 정정). 리뷰어형(monitor)은 영향 없음(product_price 기준 후보 유지). '
  'amount_issue 는 이제 리뷰어형 product_price 누락만 표시. 인증 성공 판정(is_success/'
  'cert_at)·금액 계산 로직(amount_jpy/amount_source) 자체는 262 그대로 무변경. '
  'backfill_settlements()·get_past_unregistered_settlements()·register_past_settlements() '
  '3곳이 이 함수 하나를 호출해 판정·금액 로직 드리프트를 원천 차단(변경 없음). '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 RPC 호출 불가) — 262 와 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 263 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 헬퍼 반환 타입 불변 확인(컬럼 16개 그대로)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = '_settlement_cert_candidates';

-- [V1] 헬퍼가 여전히 PUBLIC/authenticated 에 노출 안 됐는지 확인
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만)

-- [V2] 운영 실측 표와 같은 형태로 비교(gifting 의 amount_issue 가 0이 되는지 확인).
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
-- 기대(이 마이그레이션 적용 전/후 비교):
--   gifting  | reward        | success_cnt 는 300→39 로 감소(무보수 261건이 후보에서
--            |               | 아예 빠지므로) | success_but_amount_issue_cnt: 261 → 0
--   monitor  | product_price | success_cnt=485, success_amount_sum=1,990,046 그대로 불변

-- [V3] backfill_settlements() 회귀 확인 — 컷오프 미설정이면 여전히 created_count=0 이어야 함
SELECT cutoff_at FROM public.settlement_settings;
SELECT * FROM public.backfill_settlements();

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 이 마이그레이션이 바꾼 것은 _settlement_cert_candidates() 헬퍼 하나뿐이다(반환
-- 타입 불변, CREATE OR REPLACE). 262 원본으로 되돌리려면:
--   262_settlement_amount_by_recruit_type.sql 의 "1. 공통 판정·금액 계산 헬퍼
--   재생성" 블록(CREATE FUNCTION public._settlement_cert_candidates() ~
--   REVOKE ALL 까지)을 CREATE OR REPLACE 로 바꿔 그대로 재실행하면 된다
--   (262 는 반환 컬럼을 늘리며 DROP 후 CREATE 를 썼지만, 264→262 롤백은 컬럼
--   구성이 동일하므로 DROP 없이 CREATE OR REPLACE 로 충분하다).
-- backfill_settlements()·get_past_unregistered_settlements()·
-- register_past_settlements() 는 이 마이그레이션이 손대지 않았으므로 롤백 대상 아님.
