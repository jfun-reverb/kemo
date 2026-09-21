-- ============================================================
-- 455_settlement_cert_or_channel_match.sql
-- 인증 성공 판정(정산 후보) — 「또는」(channel_match='or') 캠페인은 요구 채널
-- 중 하나만 승인돼도 성공으로 본다 (지금까지는 채널을 여럿 모집하면
-- channel_match 를 안 보고 무조건 전부 승인을 요구했다 — 「그리고」와 똑같이)
--
-- 사양서: docs/specs/2026-09-21-or-channel-deliverable-judgement.md §3-2
-- 작업표: docs/specs/2026-09-21-or-channel-deliverable-judgement-breakdown.md
--         「A. 서버 판정」
--
-- ── 재정의 기준 확인(전수 grep, feedback_function_redefine_latest_base 메모리 규칙) ──
--   `_settlement_cert_candidates` 를 CREATE(OR REPLACE) 로 실제 정의한 파일은
--   232 → 262 → 264 → 300 → 318 → 331 여섯 곳(그 뒤 233·277·278·288·302·324·327·
--   337·339·343·344·347·350·370·399·418·433 은 전부 이 함수를 "부르기만" 하거나
--   주석에서 이름을 언급할 뿐 재정의하지 않는다 — grep 결과를 파일별로 눈으로
--   확인했다). 번호가 가장 큰 **331** 이 현재 유효한 원본이고, 이 마이그레이션은
--   331 의 함수 본문을 그대로 베이스로 삼는다.
--
-- ── 무엇이 문제였나 ──
--   회원 문의(2026-09-21) — 채널을 여럿(예: 인스타그램·틱톡·X) 「또는」으로 모집한
--   방문형 캠페인에서, 회원이 화면 안내대로 채널 하나에만 게시물을 올려 승인까지
--   받았는데도 인증 성공이 안 되고 마감 안내 메일이 계속 왔다. 원인은 331 의
--   channel_cert(리뷰어형 인증샷)·post_channel_cert(시딩·방문형 게시물) 두 CTE 가
--   campaigns.channel_match 를 **전혀 읽지 않고** 캠페인이 요구하는 채널 전부의
--   승인을 강제하기 때문 — 「그리고」(and)든 「또는」(or)이든 구분 없이 같은
--   규칙을 썼다. 운영 실측 승인 응모 80건(리워드 합계 ¥80,000)이 이 결함으로
--   인증 성공·정산이 막혀 있었다(사양서 §1-1).
--
-- ── 결정된 방향(사양서 §1-3, dev/lib/shared.js:1029 campaignFollowerKind 와
--    글자 그대로 같은 기준 — 최소 팔로워수 판정이 이미 쓰는 축을 그대로 가져옴.
--    새 기준을 만들지 않는다) ──
--     채널 1개 이하                              → single (그 채널만. 0개면 요구할
--                                                    채널이 없어 이 판정 자체가 안 돈다)
--     btrim(lower(channel_match)) = 'and'         → and    (지금과 동일 — 전부 승인)
--     그 밖(NULL·빈값 포함)                       → or     (하나라도 승인이면 충족)
--
--   🔴 기본값은 or 다("and 가 아니면 or") — 반대로 적으면 지금 정상인 or 캠페인이
--      깨진다. 운영에 channel_match 가 NULL·빈값인 캠페인은 0건(2026-09-21 실측,
--      1단계 마감 메일 수정 시 확인)이지만, NULL 갈래가 비어 있다는 것이 "틀려도
--      된다"는 뜻은 아니다(사양서 §1-3).
--
--   ⚠️ 채널이 1개면 channel_match 를 보지 않는다 — 331 의 "채널이 비어 있는
--      캠페인 처리 방침"과 같은 이유로, 채널 1개짜리를 or/and 로 가르는 것
--      자체가 의미가 없고(하나만 있으면 "전부"와 "하나라도"가 같은 결과) 잘못
--      가르면 오히려 위험만 는다(화면 판정과도 같은 원칙).
--
-- ── 이 마이그레이션이 바꾸는 것(전부) ──
--   1) candidates CTE — c.channel_match 컬럼 추가(지금까지 이 함수는 channel_match
--      를 아예 select 하지 않았다).
--   2) 신규 CTE channel_kind — 응모(application_id)별 채널 갈래(single/and/or)를
--      위 세 줄 그대로 계산. candidates 바로 뒤, channel_cert·post_channel_cert
--      보다 앞에 둔다(WITH 절은 앞서 정의된 CTE 만 참조 가능).
--   3) channel_cert(리뷰어형) · post_channel_cert(시딩·방문형) 두 CTE — "and/single
--      전부 승인" 집계(max_channel_reviewed_at·any_null, 331 과 완전히 동일한 식·
--      값)에 더해 "or 하나라도 승인" 집계(min_approved_reviewed_at·any_approved)를
--      **같은 CTE 안에 나란히** 추가한다. and/single 쪽 계산식은 한 글자도 안
--      바뀐다 — 최종 CASE 에서 ck.kind 로 어느 쪽을 쓸지만 고른다.
--   4) is_success CASE — 리뷰어형(monitor, non-proxy) 분기와 시딩·방문형(ELSE)
--      분기 각각에 `CASE ck.kind WHEN 'or' THEN ... ELSE(=and/single) 331 원본 그대로
--      END` 를 씌운다. or 갈래는 "채널 중 하나라도 승인된 결과물이 있는가"만
--      본다(EXISTS 단독, NOT EXISTS 쌍 없음). and/single 갈래는 331 의 EXISTS+NOT
--      EXISTS 쌍을 글자 그대로 유지.
--   5) cert_at CASE — 마찬가지로 or 갈래는 "승인된 채널 중 가장 이른 승인
--      시각"(min_approved_reviewed_at, 최초로 성공 조건을 만족한 시점)을,
--      and/single 갈래는 331 그대로 "전부 승인된 마지막 채널의 시각"
--      (max_channel_reviewed_at, any_null 가드 포함)을 쓴다.
--   6) FROM 절에 `LEFT JOIN channel_kind ck ON ck.application_id = cd.application_id`
--      추가.
--
-- ── 절대 바꾸지 않는 것(331 과 완전히 동일) ──
--   candidates CTE 의 나머지 조건(승인 응모·감사용 제외·정산행 미존재·264 의
--   무보수 시딩/방문형 제외) / receipt_latest / post_channel_latest·
--   review_channel_latest(정의 무변경) / 금액 계산 CASE 문(receipt_amount 기준,
--   261/300 그대로) / amount_issue 판정 3종(모두 monitor 전용) /
--   receipt_amount_jpy·amount_cap_jpy / proxy_purchase(가구매) 분기(채널을 아예
--   안 봄, 331 그대로) / and·single 갈래의 is_success·cert_at 계산식(값 자체는
--   331 과 100% 동일 — ELSE 로 감싸는 위치만 바뀜) / RETURNS TABLE 시그니처(컬럼
--   이름·타입 무변경 — 반환 타입이 안 바뀌므로 DROP 없이 CREATE OR REPLACE 로
--   충분).
--
--   이 헬퍼를 호출하는 backfill_settlements()·get_past_unregistered_settlements()·
--   register_past_settlements() 3곳은 헬퍼가 돌려주는 컬럼·타입이 그대로라
--   재정의할 필요가 없다(331 과 같은 이유).
--
-- ── ⚠️ 채널 비교 규칙(마이그레이션 319 로 통일된 축)은 절대 바꾸지 않는다 ──
--   캠페인 쪽 채널 토큰만 btrim, 결과물(deliverables.post_channel) 쪽 값은 원본
--   그대로(트림·대소문자 변환 없음) 비교. 이 규칙을 여기서만 바꾸면 화면·엑셀·
--   메일과 또 다른 사각지대가 생긴다(319 가 경고한 바로 그 함정).
--
-- ── ⚠️ 같은 판정이 여섯 곳(사양서 §2-②) ──
--   이 마이그레이션은 그중 서버(A, 여기)만 고친다. 나머지 다섯(검수 화면·엑셀+
--   브랜드 공유 화면·결과물 검수 결과 메일·일일 메일 리뷰 인증샷·
--   _campaign_cert_success_counts 집계[베이스 433, 마이그레이션 456])은 같은
--   배포 묶음의 다른 작업이 본다. 여기서 A 만 먼저 적용해도 "인증 성공은 됐는데
--   화면에는 안 뜨는" 어긋남만 생기고(해가 없는 방향 — 정산은 이미 막혀 있던
--   상태에서 더 나빠지지 않는다), 반대(화면은 성공인데 서버는 실패)보다 안전하다.
--
-- ── 운영 실측 — 이 함수를 **재정의하기 직전** 아래 [V0] 로 다시 셀 것 ──
--   사양서(§1-1)의 "80명"은 게시물(gifting·visit) 기준으로 "승인된 채널이 1개
--   이상이고 요구 채널 수보다 적은" 승인 응모를 센 수다. 리뷰어형(monitor)의
--   리뷰 인증샷 쪽은 이 마이그레이션 작성 시점까지 세어진 적이 없다(사양서 §3-2
--   "아직 안 셈"). [V0] 이 둘 다 센다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

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
  amount_source        text,
  reward_part_jpy      bigint,
  receipt_amount_jpy   bigint,
  amount_cap_jpy       bigint,
  amount_issue         text,
  is_success           boolean,
  cert_at              timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 감사용 제외 + 아직 정산행 없음(멱등)
    -- + [264, 유지] 무보수 시딩·방문형 제외. 331 원본과 완전히 동일하되
    -- [455 신규] c.channel_match 컬럼만 추가했다(지금까지 이 함수는 이 값을
    -- 아예 읽지 않았다 — 사양서 §1-2 「원인」).
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
      c.channel_match                     AS channel_match,
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
  channel_kind AS (
    -- [455 신규] 응모별 채널 갈래 — dev/lib/shared.js 의 campaignFollowerKind
    -- (1029행)와 글자 그대로 같은 기준(사양서 §1-3). 새 기준을 만들지 않는다.
    --   채널 1개 이하                       → single
    --   btrim(lower(channel_match))='and'   → and
    --   그 밖(NULL 포함)                    → or   (🔴 기본값 — "and 가 아니면 or")
    SELECT
      cd.application_id,
      CASE
        WHEN (
          SELECT count(*) FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          WHERE btrim(ch.name) <> ''
        ) <= 1 THEN 'single'
        WHEN btrim(lower(cd.channel_match)) = 'and' THEN 'and'
        ELSE 'or'
      END AS kind
    FROM candidates cd
  ),
  receipt_latest AS (
    -- 331 원본과 완전히 동일(변경 없음) — 응모별 영수증(receipt) 최신 1건(draft 제외).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at, d.purchase_amount
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_channel_latest AS (
    -- 331 원본과 완전히 동일(변경 없음) — gifting·visit 게시물(post) 의 "응모×채널"별
    -- 최신 1건(draft 제외).
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 331 원본과 완전히 동일(변경 없음) — 응모×채널별 인증샷(review_image) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- [455 확장] 리뷰어(monitor 일반) 응모의 채널 완전성 집계. and/single 쪽
    -- (max_channel_reviewed_at·any_null)은 331 원본과 완전히 동일한 식·값 —
    -- 최종 CASE 에서 ck.kind='or' 가 아닐 때만 쓴다. or 쪽(min_approved_reviewed_at·
    -- any_approved) 은 [455 신규] — 승인된 채널 중 가장 이른 승인 시각과, 승인된
    -- 채널이 하나라도 있는지. 둘 다 같은 GROUP BY 안에서 함께 계산해도 서로
    -- 간섭하지 않는다(FILTER 로 집계 대상만 가른다).
    SELECT
      cd.application_id,
      MAX(rcl.reviewed_at)                                        AS max_channel_reviewed_at,
      bool_or(rcl.reviewed_at IS NULL)                             AS any_null,
      MIN(rcl.reviewed_at) FILTER (WHERE rcl.status = 'approved')  AS min_approved_reviewed_at,
      bool_or(rcl.status = 'approved')                             AS any_approved
    FROM candidates cd
    CROSS JOIN LATERAL unnest(string_to_array(cd.channel, ',')) AS ch(name)
    LEFT JOIN review_channel_latest rcl
      ON rcl.application_id = cd.application_id
     AND rcl.post_channel   = btrim(ch.name)
    WHERE cd.recruit_type = 'monitor' AND NOT cd.proxy_purchase
      AND btrim(ch.name) <> ''
    GROUP BY cd.application_id
  ),
  post_channel_cert AS (
    -- [455 확장] channel_cert 와 완전히 같은 구조를 recruit_type<>'monitor'
    -- (시딩·방문형)로만 바꿔 재사용. and/single·or 두 집계 모두 [455 신규] 추가된
    -- or 쪽을 제외하면 331 원본과 동일.
    SELECT
      cd.application_id,
      MAX(pcl.reviewed_at)                                        AS max_channel_reviewed_at,
      bool_or(pcl.reviewed_at IS NULL)                             AS any_null,
      MIN(pcl.reviewed_at) FILTER (WHERE pcl.status = 'approved')  AS min_approved_reviewed_at,
      bool_or(pcl.status = 'approved')                             AS any_approved
    FROM candidates cd
    CROSS JOIN LATERAL unnest(string_to_array(cd.channel, ',')) AS ch(name)
    LEFT JOIN post_channel_latest pcl
      ON pcl.application_id = cd.application_id
     AND pcl.post_channel   = btrim(ch.name)
    WHERE cd.recruit_type <> 'monitor'
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
    -- ── 금액 계산: 리뷰어형(monitor, 가구매 포함) = min(영수증, 상시가) 절사 ──
    -- 331 원본과 완전히 동일(변경 없음) — 채널 갈래와 무관.
    CASE
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount IS NOT NULL AND rl.purchase_amount > 0
           AND cd.product_price   IS NOT NULL AND cd.product_price   > 0
        THEN NULLIF(GREATEST(floor(LEAST(rl.purchase_amount, cd.product_price::numeric)), 0), 0)::bigint
      WHEN cd.recruit_type = 'monitor' THEN NULL::bigint  -- 아래 amount_issue 로 사유가 채워짐
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'receipt_amount'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(261 부터 그대로)
    -- ── 감사용 칸 2개(299) — 리뷰어형만 채움, 그 외 NULL. 331 원본과 동일 ──
    CASE WHEN cd.recruit_type = 'monitor' THEN floor(rl.purchase_amount)::bigint ELSE NULL::bigint END AS receipt_amount_jpy,
    CASE WHEN cd.recruit_type = 'monitor' THEN cd.product_price ELSE NULL::bigint END AS amount_cap_jpy,
    -- ── amount_issue: 조건 3종(331 그대로 — 모두 monitor 전용, 채널 갈래와 무관) ──
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
    -- ── is_success ──
    -- 가구매(proxy_purchase) 분기는 331 그대로 무변경(채널을 아예 안 봄).
    -- 리뷰어형 일반·시딩·방문형 두 분기는 [455] ck.kind 로 갈래를 나눈다.
    -- and/single 쪽(ELSE)은 331 의 EXISTS+NOT EXISTS 쌍을 글자 그대로 유지 —
    -- or 쪽만 [455 신규](EXISTS 단독 — 승인된 채널이 하나라도 있으면 충족).
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        COALESCE(rl.status = 'approved', false)
      WHEN cd.recruit_type = 'monitor' THEN
        CASE ck.kind
          WHEN 'or' THEN
            -- [455 신규] 영수증 승인 + 요구 채널 중 하나라도 인증샷 승인.
            COALESCE(rl.status = 'approved', false)
            AND EXISTS (
              SELECT 1
              FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN review_channel_latest rcl
                ON rcl.application_id = cd.application_id
               AND rcl.post_channel   = btrim(ch.name)
              WHERE btrim(ch.name) <> ''
                AND rcl.status = 'approved'
            )
          ELSE
            -- 331 원본과 완전히 동일(변경 없음) — and·single 은 요구 채널 전부 승인.
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
        END
      ELSE
        -- 시딩(gifting)·방문형(visit).
        CASE ck.kind
          WHEN 'or' THEN
            -- [455 신규] 요구 채널 중 하나라도 승인된 게시물이 있으면 충족.
            EXISTS (
              SELECT 1
              FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_channel_latest pcl
                ON pcl.application_id = cd.application_id
               AND pcl.post_channel   = btrim(ch.name)
              WHERE btrim(ch.name) <> ''
                AND pcl.status = 'approved'
            )
          ELSE
            -- 331 원본과 완전히 동일(변경 없음) — and·single 은 요구 채널 전부 승인.
            -- 채널이 0개(NULL/빈 문자열/공백뿐)면 EXISTS 가 거짓이라 항상 실패
            -- (monitor 와 동일 규칙 — 331 「채널이 비어 있는 캠페인 처리 방침」).
            EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              WHERE btrim(ch.name) <> ''
            )
            AND NOT EXISTS (
              SELECT 1
              FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_channel_latest pcl
                ON pcl.application_id = cd.application_id
               AND pcl.post_channel   = btrim(ch.name)
              WHERE btrim(ch.name) <> ''
                AND COALESCE(pcl.status, 'none') <> 'approved'
            )
        END
    END AS is_success,
    -- ── cert_at ──
    -- 가구매 분기는 331 그대로 무변경. 리뷰어형 일반·시딩·방문형 두 분기는
    -- ck.kind 로 갈래를 나눈다. and/single 쪽은 331 그대로(any_null 가드 포함,
    -- max_channel_reviewed_at = 마지막 채널이 승인된 시각). or 쪽은 [455 신규]
    -- min_approved_reviewed_at = 최초로 성공 조건을 만족한(=하나라도 승인된)
    -- 시각.
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        rl.reviewed_at
      WHEN cd.recruit_type = 'monitor' THEN
        CASE ck.kind
          WHEN 'or' THEN
            CASE
              WHEN rl.reviewed_at IS NULL OR NOT COALESCE(cc.any_approved, false) THEN NULL
              ELSE GREATEST(rl.reviewed_at, cc.min_approved_reviewed_at)
            END
          ELSE
            CASE
              WHEN rl.reviewed_at IS NULL OR COALESCE(cc.any_null, true) THEN NULL
              ELSE GREATEST(rl.reviewed_at, cc.max_channel_reviewed_at)
            END
        END
      ELSE
        CASE ck.kind
          WHEN 'or' THEN
            CASE
              WHEN NOT COALESCE(pcc.any_approved, false) THEN NULL
              ELSE pcc.min_approved_reviewed_at
            END
          ELSE
            CASE
              WHEN COALESCE(pcc.any_null, true) THEN NULL
              ELSE pcc.max_channel_reviewed_at
            END
        END
    END AS cert_at
  FROM candidates cd
  LEFT JOIN channel_kind      ck  ON ck.application_id = cd.application_id
  LEFT JOIN receipt_latest    rl  ON rl.application_id = cd.application_id
  LEFT JOIN channel_cert      cc  ON cc.application_id = cd.application_id
  LEFT JOIN post_channel_cert pcc ON pcc.application_id = cd.application_id;
$$;

COMMENT ON FUNCTION public._settlement_cert_candidates() IS
  '[455 재정의, 331 원본 대체(반환 컬럼 무변경 — is_success·cert_at 의 채널 완전성 '
  '판정만 channel_match 갈래별로 분기)] private 헬퍼 — 정산 미등록(settlements 행 '
  '없음) 응모 전체에 대해 인증 성공 여부(is_success)·인증 성공일(cert_at)·모집 '
  '형식별 정산 금액(amount_jpy)·금액 출처(amount_source)·감사용 원금액/상한'
  '(receipt_amount_jpy/amount_cap_jpy)·금액 미확정 사유(amount_issue)를 계산한다. '
  '[455] campaigns.channel_match 갈래(dev/lib/shared.js campaignFollowerKind 와 '
  '동일 기준 — 채널 1개 이하=single, and=and, 그 밖(NULL 포함)=or)에 따라 채널 '
  '완전성 요구가 갈린다: and·single 은 종전대로 캠페인이 요구하는 채널 전부에 '
  '승인이 있어야 하고, or 은 하나라도 승인이면 충족한다(리뷰어형 인증샷·시딩·'
  '방문형 게시물 둘 다). 채널이 0개인 캠페인은 갈래와 무관하게 항상 '
  'is_success=false(331 그대로). '
  'backfill_settlements()·get_past_unregistered_settlements()·register_past_settlements() '
  '3곳이 이 함수 하나를 호출해 판정·금액 로직 드리프트를 원천 차단. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 호출 불가) — 331 과 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor 에서 1단계씩 실행 — 결과 확인 후 다음
-- 단계로. ⚠️ [V0] 은 위 CREATE OR REPLACE 를 실행하기 *전에* 먼저 돌린다.
-- SQL Editor 세션은 auth.uid() 가 NULL 이라 has_permission 게이트가 있는 함수
-- (backfill_settlements 등)는 postgres(소유자) role 로 실행해야 permission_denied
-- 없이 호출된다. 헬퍼(_settlement_cert_candidates) 자체는 오너 권한이면 직접
-- SELECT 가능.
-- ============================================================
/*

-- ══════════════ [V0] 필수 — 반드시 위 CREATE OR REPLACE 를 실행하기 *전에* ══════════════
-- 먼저 돌린다. 지금(331 상태) 실제로 배포된 함수의 is_success 를 "old"로,
-- 이 파일이 도입하는 새 규칙을 처음부터 다시 계산한 것을 "new"로 삼아 응모
-- 단위로 대조한다(함수를 바꾸기 전이므로 "new" 는 이 조회 안에서 직접 계산).
--
-- 🔴 이 변경은 or 요구를 "전부"에서 "하나라도"로 완화하는 것뿐이라, 이론상
--    true→false 로 바뀌는 응모는 0건이어야 한다(전부 승인이면 하나라도 승인은
--    자동으로 참이므로). 그 칸이 1건이라도 나오면 즉시 멈추고 원인을 먼저 본다.
WITH old_result AS (
  SELECT application_id, campaign_id, recruit_type, is_success
  FROM public._settlement_cert_candidates()
),
candidates AS (
  SELECT
    a.id AS application_id, a.campaign_id, c.recruit_type, c.channel, c.channel_match,
    COALESCE(c.proxy_purchase, false) AS proxy_purchase
  FROM public.applications a
  JOIN public.campaigns c ON c.id = a.campaign_id
  JOIN public.influencers inf ON inf.id = a.user_id
  WHERE a.status = 'approved'
    AND inf.is_audit = false
    AND NOT EXISTS (SELECT 1 FROM public.settlements s WHERE s.application_id = a.id)
    AND NOT (c.recruit_type <> 'monitor' AND (c.reward IS NULL OR c.reward <= 0))
),
channel_kind AS (
  SELECT
    cd.application_id,
    CASE
      WHEN (SELECT count(*) FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '') <= 1 THEN 'single'
      WHEN btrim(lower(cd.channel_match)) = 'and' THEN 'and'
      ELSE 'or'
    END AS kind
  FROM candidates cd
),
receipt_latest AS (
  SELECT DISTINCT ON (d.application_id) d.application_id, d.status
  FROM public.deliverables d
  WHERE d.kind = 'receipt' AND d.status <> 'draft'
  ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
),
review_latest AS (
  SELECT DISTINCT ON (d.application_id, d.post_channel) d.application_id, d.post_channel, d.status
  FROM public.deliverables d
  WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL AND d.status <> 'draft'
  ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
),
post_latest AS (
  SELECT DISTINCT ON (d.application_id, d.post_channel) d.application_id, d.post_channel, d.status
  FROM public.deliverables d
  WHERE d.kind = 'post' AND d.post_channel IS NOT NULL AND d.status <> 'draft'
  ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
),
new_result AS (
  SELECT
    cd.application_id, cd.campaign_id, cd.recruit_type, ck.kind,
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        COALESCE(rl.status = 'approved', false)
      WHEN cd.recruit_type = 'monitor' THEN
        CASE ck.kind
          WHEN 'or' THEN
            COALESCE(rl.status = 'approved', false)
            AND EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN review_latest rv ON rv.application_id = cd.application_id AND rv.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND rv.status = 'approved'
            )
          ELSE
            COALESCE(rl.status = 'approved', false)
            AND EXISTS (SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '')
            AND NOT EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN review_latest rv ON rv.application_id = cd.application_id AND rv.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND COALESCE(rv.status,'none') <> 'approved'
            )
        END
      ELSE
        CASE ck.kind
          WHEN 'or' THEN
            EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_latest pl ON pl.application_id = cd.application_id AND pl.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND pl.status = 'approved'
            )
          ELSE
            EXISTS (SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '')
            AND NOT EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_latest pl ON pl.application_id = cd.application_id AND pl.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND COALESCE(pl.status,'none') <> 'approved'
            )
        END
    END AS is_success
  FROM candidates cd
  JOIN channel_kind ck ON ck.application_id = cd.application_id
  LEFT JOIN receipt_latest rl ON rl.application_id = cd.application_id
)
SELECT
  o.recruit_type,
  n.kind,
  count(*) AS 응모수,
  count(*) FILTER (WHERE o.is_success = false AND n.is_success = true)  AS 새로_성공_뒤집히는_건,
  count(*) FILTER (WHERE o.is_success = true  AND n.is_success = false) AS "🔴성공_상실(0이어야_함)",
  count(*) FILTER (WHERE o.is_success = true  AND n.is_success = true)  AS 그대로_성공,
  count(*) FILTER (WHERE o.is_success = false AND n.is_success = false) AS 그대로_실패
FROM old_result o
JOIN new_result n ON n.application_id = o.application_id
GROUP BY o.recruit_type, n.kind
ORDER BY o.recruit_type, n.kind;
-- 기대: 「🔴성공_상실」 은 모든 행에서 0. 「새로_성공_뒤집히는_건」 은 kind='or'
-- 행에서만 0보다 클 수 있고(사양서 §1-1 의 게시물 80명이 recruit_type IN
-- ('gifting','visit') AND kind='or' 행에 반영돼야 한다 — 정확한 수는 이 조회가
-- 최종 답이다, 사양서 표의 "4건/80명"은 승인 응모가 있는 캠페인만 센 것이라
-- 참고치일 뿐이다), kind='and'·'single' 행에서는 항상 0(코드가 그 갈래를 한
-- 글자도 안 바꿨으므로).
-- ⚠️ old_result 와 new_result 의 총 건수(응모수 합계)가 서로 달라 JOIN 이 행을
-- 누락하지 않았는지도 함께 본다 — 두 CTE 의 candidates 조건이 완전히 같으므로
-- 같은 응모 집합이어야 한다.

-- ══════════════ [V0-and] 참고 — 「그리고」 5건(전부 리뷰어형, qoo10·cosme)이 ══════════════
-- 이번 변경에 안 걸리는지 개별로 눈으로 확인.
SELECT
  c.campaign_no, c.title, c.channel, c.channel_match, c.recruit_type,
  count(a.id) AS 승인응모수
FROM public.campaigns c
JOIN public.applications a ON a.campaign_id = c.id AND a.status = 'approved'
WHERE btrim(lower(c.channel_match)) = 'and'
  AND (SELECT count(*) FROM unnest(string_to_array(c.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '') >= 2
GROUP BY c.campaign_no, c.title, c.channel, c.channel_match, c.recruit_type
ORDER BY c.campaign_no;
-- 참고(2026-09-21 실측, 1단계 마감 메일 작업 때 확인): 5건, 전부 recruit_type=
-- 'monitor' · channel='qoo10,cosme' · 제출 마감 경과. [V0] 의 kind='and' 행이
-- 이 5건의 승인 응모를 포함하고 「🔴성공_상실」 0·「새로_성공」 0 인지로
-- 재확인한다.

-- ⚠️⚠️ 위 [V0] 의 「🔴성공_상실(0이어야_함)」 이 모든 행에서 0 임을 확인한 뒤
-- 이 지점에서 파일 상단의 CREATE OR REPLACE 블록을 SQL Editor 에 적용한다 ⚠️⚠️

-- ══════════════ [V1] 함수 반환 타입이 331 과 동일한지 확인 ══════════════
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = '_settlement_cert_candidates';

-- ══════════════ [V2] 헬퍼가 여전히 PUBLIC/authenticated 에 노출 안 됐는지 확인 ══════════════
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만)

-- ══════════════ [V3] 적용 후 재집계 — [V0] 과 같은 모양으로 다시 세어 일치하는지 ══════════════
-- (지금은 old_result 도 새 함수를 호출하므로 old=new 가 되어 두 칸 다 "그대로"만
-- 나와야 한다 — 그 자체가 함수가 실제로 적용됐다는 증거다)
WITH r AS (
  SELECT application_id, campaign_id, recruit_type, is_success
  FROM public._settlement_cert_candidates()
)
SELECT r.recruit_type, count(*) AS 응모수, count(*) FILTER (WHERE r.is_success) AS 성공수
FROM r
GROUP BY r.recruit_type
ORDER BY r.recruit_type;

-- ══════════════ [V4] backfill_settlements() 회귀 확인 — cutoff_at 미설정이면 여전히 0건 ══════════════
-- (postgres role 로 실행하거나 has_permission 통과하는 관리자 세션 필요)
SELECT cutoff_at, influencer_visible FROM public.settlement_settings WHERE id = 1;
SELECT * FROM public.backfill_settlements();
-- 기대: created_count=0 (cutoff_at 이 NULL 인 동안은 이 변경과 무관하게 항상 0)

-- ══════════════ [V5] candidates CTE(264 무보수 시딩·방문형 제외)가 여전히 살아있는지 ══════════════
SELECT count(*) AS should_be_zero
FROM public._settlement_cert_candidates() c
JOIN public.campaigns camp ON camp.id = c.campaign_id
WHERE camp.recruit_type <> 'monitor' AND (camp.reward IS NULL OR camp.reward <= 0);
-- 기대: 0

-- ══════════════ [V6] get_past_unregistered_settlements() 스모크 — 80건이 뜨는지 ══════════════
-- (앱에서 campaign_admin 이상 세션으로 확인 권장 — SQL Editor 직접 호출은
-- permission_denied 가능. [V0] 의 「새로_성공_뒤집히는_건」 합계만큼 여기 새로
-- 나타나야 한다)
-- SELECT recruit_type, count(*) FROM public.get_past_unregistered_settlements()
-- GROUP BY recruit_type ORDER BY recruit_type;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 반환 타입(컬럼 구성)이 331 과 동일하므로 DROP 없이 CREATE OR REPLACE 로 되돌릴 수 있다.
-- 1) 331_settlement_gifting_visit_all_channels_required.sql 파일을 열어
--    "CREATE OR REPLACE FUNCTION public._settlement_cert_candidates()" 블록부터
--    그 COMMENT ON FUNCTION 문장까지를 그대로 복사해 SQL Editor 에서 실행한다.
-- 2) REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC; 실행.
-- 3) NOTIFY pgrst, 'reload schema'; 실행.
-- 이 작업은 channel_kind CTE 와 channel_cert·post_channel_cert 의 or 쪽 집계를
-- 무시하고, is_success·cert_at 을 다시 "채널 전부 승인" 하나로 되돌리는 것과
-- 동일한 효과다(단, or 로 새로 성공 처리된 응모가 있었다면 되돌리는 순간 다시
-- 실패로 바뀐다 — 이미 이 함수로 만들어진 settlements 행은 candidates 조건에
-- 걸려 대상이 아니므로 롤백해도 건드리지 않는다).
-- ============================================================
