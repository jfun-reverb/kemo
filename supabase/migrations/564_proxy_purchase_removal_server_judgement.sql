-- ============================================================
-- 564: 가구매 철거 단계 B ① — 서버 판정 함수 넷에서 가구매(proxy_purchase) 갈래를 걷는다
-- ============================================================
-- 사양서 docs/specs/2026-10-20-proxy-purchase-removal.md 「설계 · 단계 B」
-- 🔴 단계 A(화면·메일, 운영 #2200) 가 운영에 나간 뒤에만 적용한다 — 먼저 넣으면 열린 길로 생긴
--    가구매 캠페인을 화면은 「영수증만」, 서버는 「인증샷 필요」로 갈라 본다.
-- 🔴 적용 직전 운영 가구매 캠페인 0건 재확인: SELECT count(*) FROM public.campaigns WHERE proxy_purchase;
--
-- 다시 정의하는 함수(전부 CREATE OR REPLACE — 인자·반환 칸 그대로, 실행 권한 보존. 🔴 DROP 금지):
--   1) _settlement_cert_candidates()            베이스 455 — 후보 칸·채널 인증 집계 제외·is_success·cert_at 의 가구매 갈래 제거
--   2) _campaign_cert_success_counts(uuid[])    베이스 456 — 후보 칸·성공 판정의 가구매 갈래 제거
--   3) get_deliverable_gate(uuid)               베이스 276 — 가구매면 인증샷 항목을 안 펼치던 예외 제거(채널 없는 옛 리뷰어형 예외는 유지)
--   4) link_orient_card_to_campaign(uuid,int,uuid) 베이스 464 — 가구매 카드 연결 거부 'form_type_retired' 신설,
--                                               리뷰어 카드는 recruit_type 만 본다, 응답의 campaign_proxy_purchase 키 제거
--   ※ 다섯째 _results_payload_core(545) 는 개발서버에만 있어 565 로 나눴다.
--
-- 본문은 각 베이스 파일의 정의를 글자 그대로 옮기고 가구매 갈래만 걷었다(주석도 그 자리만).
-- 칸 campaigns.proxy_purchase·부분 인덱스(197)·오리엔시트 형식 제약(194)·변경 이력 화이트리스트(265·266)는 남긴다(사양서 결정 1).
--
-- 실행 권한(착수 전 확인 2026-10-20, 운영·개발 같음) — 적용 뒤 같은지 다시 본다:
--   _settlement_cert_candidates      {postgres=X/postgres,service_role=X/postgres}
--   _campaign_cert_success_counts    {postgres=X/postgres,service_role=X/postgres}
--   get_deliverable_gate             {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
--   link_orient_card_to_campaign     {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
--   SELECT p.proname, p.proacl::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname IN ('_settlement_cert_candidates','_campaign_cert_success_counts',
--          'get_deliverable_gate','link_orient_card_to_campaign') ORDER BY 1;
--
-- 되돌리기: 455·456·276·464 각 파일의 함수 블록(CREATE OR REPLACE … $$;)을 그대로 다시 실행한다
--   (CREATE OR REPLACE 라 권한은 그대로). 단 단계 A 화면은 이미 가구매 갈래가 없으므로 되돌리면 화면과 서버가 갈린다.
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
    WHERE cd.recruit_type = 'monitor'
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
    -- ── 금액 계산: 리뷰어형(monitor) = min(영수증, 상시가) 절사 ──
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
    -- [가구매 철거 B] 가구매(영수증만) 분기를 걷었다 — 리뷰어형은 모두 영수증 + 채널별 인증샷.
    -- 리뷰어형·시딩·방문형 두 분기는 [455] ck.kind 로 갈래를 나눈다.
    -- and/single 쪽(ELSE)은 331 의 EXISTS+NOT EXISTS 쌍을 글자 그대로 유지 —
    -- or 쪽만 [455 신규](EXISTS 단독 — 승인된 채널이 하나라도 있으면 충족).
    CASE
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
    -- [가구매 철거 B] 가구매 분기 제거. 리뷰어형·시딩·방문형 두 분기는
    -- ck.kind 로 갈래를 나눈다. and/single 쪽은 331 그대로(any_null 가드 포함,
    -- max_channel_reviewed_at = 마지막 채널이 승인된 시각). or 쪽은 [455 신규]
    -- min_approved_reviewed_at = 최초로 성공 조건을 만족한(=하나라도 승인된)
    -- 시각.
    CASE
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
CREATE OR REPLACE FUNCTION public._campaign_cert_success_counts(p_campaign_ids uuid[])
RETURNS TABLE (
  campaign_id uuid,
  cert_count  integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 433 원본과 완전히 동일하되 [456 신규] c.channel_match 컬럼만 추가.
    -- 제외 셋 중 둘(감사용·반려/취소) — 화면 isCertExcluded 와 같은 기준.
    -- 화면과 달리 "승인된 신청만"으로 좁히지 않는다 — pending 신청은 어차피
    -- 결과물이 없어 success 계산에서 자연히 빠진다(정산 후보 조건인 "승인된
    -- 응모만"·"정산행 미존재"·"무보수 시딩/방문형 제외"는 여기 없음 — 이
    -- 함수는 정산이 아니라 결과물 인증 성공만 본다).
    SELECT
      a.id                                AS application_id,
      a.campaign_id                       AS campaign_id,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      c.channel_match                     AS channel_match
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.campaign_id = ANY(p_campaign_ids)
      AND a.status NOT IN ('rejected', 'cancelled')
      AND inf.is_audit = false
  ),
  channel_kind AS (
    -- [456 신규] 응모별 채널 갈래 — 마이그레이션 455 의 channel_kind 와 글자
    -- 그대로 같은 식(= dev/lib/shared.js campaignFollowerKind 와 같은 기준).
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
    -- 433 원본과 완전히 동일(변경 없음) — 응모별 영수증(receipt) 최신 1건 — draft 제외.
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 433 원본과 완전히 동일(변경 없음) — 리뷰어형 응모×채널별 인증샷(review_image) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  post_channel_latest AS (
    -- 433 원본과 완전히 동일(변경 없음) — 시딩·방문형 응모×채널별 게시물(post) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'post' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  success AS (
    SELECT
      cd.application_id,
      cd.campaign_id,
      CASE
        WHEN cd.recruit_type = 'monitor' THEN
          -- 리뷰어형([가구매 철거 B] 가구매 분기 제거) — 영수증 승인 + [456] ck.kind 에 따라 채널 요구 갈림.
          CASE ck.kind
            WHEN 'or' THEN
              -- [456 신규] 영수증 승인 + 요구 채널 중 하나라도 인증샷 승인.
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
              -- 433 원본과 완전히 동일(변경 없음) — and·single 은 캠페인 채널 전부 인증샷 승인.
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
          -- 시딩·방문형 — [456] ck.kind 에 따라 채널 요구 갈림.
          --
          -- 🔴 모집 형식을 **이름으로 지목**한다 — `ELSE` 로 두면 `recruit_type IS NULL`
          --    인 캠페인이 여기로 들어온다(제약 399 가 NULL 을 허용한다). 화면은
          --    `_finalizePostReprs`(admin-deliverables.js:713)가
          --    `if (rt !== 'gifting' && rt !== 'visit') continue;` 로 NULL 을 건너뛰어
          --    대표 상태가 안 생기므로 **NULL 캠페인은 화면에서 영원히 성공이 못 된다.**
          --    이름으로 안 지목하면 서버만 성공을 내서 「화면 동작 변화 0」이 깨진다.
          --    (433 원본과 완전히 동일 — 변경 없음)
          cd.recruit_type IN ('gifting', 'visit')
          AND CASE ck.kind
            WHEN 'or' THEN
              -- [456 신규] 요구 채널 중 하나라도 승인된 게시물이 있으면 충족.
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
              -- 433 원본과 완전히 동일(변경 없음) — and·single 은 캠페인 채널 전부 게시물 승인.
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
      END AS is_success
    FROM candidates cd
    LEFT JOIN channel_kind    ck ON ck.application_id = cd.application_id
    LEFT JOIN receipt_latest  rl ON rl.application_id = cd.application_id
  )
  -- 요청받은 캠페인 식별자 전부를 돌려준다(성공 0건인 캠페인도 cert_count=0 으로
  -- 포함) — 호출부(434)가 결측 행을 따로 신경 쓰지 않게. 433 원본과 완전히 동일.
  SELECT
    ids.campaign_id,
    COALESCE(cnt.cert_count, 0)::integer AS cert_count
  FROM unnest(p_campaign_ids) AS ids(campaign_id)
  LEFT JOIN (
    SELECT s.campaign_id, COUNT(*)::integer AS cert_count
    FROM success s
    WHERE s.is_success
    GROUP BY s.campaign_id
  ) cnt ON cnt.campaign_id = ids.campaign_id;
$$;
CREATE OR REPLACE FUNCTION public.get_deliverable_gate(
  p_application_id uuid
)
RETURNS TABLE (
  kind           text,
  post_channel   text,
  allowed        boolean,
  reason         text,
  submission_end date
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type   text;
  v_channel        text;
  v_channels       text[];
BEGIN
  -- 0. 호출자 검증 — 본인 신청 전체 조회이므로 can_submit_deliverable 처럼 항목별로
  --    조용히 permission_denied 를 섞어 내려보내지 않고, 함수 진입점에서 한 번에
  --    명확히 거부한다. auth.uid() IS NULL(서비스 키·SQL Editor)과 관리자는 예외.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = p_application_id AND a.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'permission_denied: 본인 신청만 조회할 수 있습니다'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- 1. 캠페인 정보 조회 (recruit_type/channel — 항목 전개 기준)
  SELECT c.recruit_type, c.channel
    INTO v_recruit_type, v_channel
    FROM public.applications a
    JOIN public.campaigns c ON c.id = a.campaign_id
   WHERE a.id = p_application_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found: 신청 정보를 찾을 수 없습니다'
      USING ERRCODE = 'P0001';
  END IF;

  -- 캠페인 channel 콤마 구분 문자열 → 배열 (trim + 빈 문자열 제외).
  -- string_to_array('', ',') 는 빈 배열을 반환하므로(PostgreSQL 문서) channel 이
  -- NULL/빈 문자열이면 v_channels 도 빈 배열이 된다.
  SELECT COALESCE(array_agg(t) FILTER (WHERE t <> ''), ARRAY[]::text[])
    INTO v_channels
    FROM (
      SELECT trim(x) AS t
        FROM unnest(string_to_array(COALESCE(v_channel, ''), ',')) AS x
    ) s;

  -- 2. 항목 전개 (사양서 §설계 3-(1), admin-deliverables.js 실제 조건과 정합)
  IF v_recruit_type = 'monitor' THEN
    -- 영수증 1건 — 리뷰어형은 항상 필요
    RETURN QUERY
      SELECT 'receipt'::text, NULL::text,
             (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
        FROM public.can_submit_deliverable(p_application_id, 'receipt', NULL) AS r;

    -- 채널별 리뷰 인증샷 — 채널 없는 레거시 monitor 는 요구하지 않음
    --   ([가구매 철거 B] 가구매 예외 제거 — 화면 활동관리 STEP2 숨김 조건과 같다)
    IF array_length(v_channels, 1) > 0 THEN
      RETURN QUERY
        SELECT 'review_image'::text, ch,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM unnest(v_channels) AS ch
          CROSS JOIN LATERAL public.can_submit_deliverable(p_application_id, 'review_image', ch) AS r;
    END IF;

  ELSIF v_recruit_type IN ('gifting', 'visit') THEN
    -- 채널별 게시물
    IF array_length(v_channels, 1) > 0 THEN
      RETURN QUERY
        SELECT 'post'::text, ch,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM unnest(v_channels) AS ch
          CROSS JOIN LATERAL public.can_submit_deliverable(p_application_id, 'post', ch) AS r;
    END IF;

    -- ★ 방문형(visit)은 **현장 사진(receipt)도 제출한다** (2026-07-30 리뷰에서 누락 발견).
    --   화면이 showImage = (rt === 'monitor' || rt === 'visit') 로 영수증 폼을 띄우고
    --   addDraftImage() 가 recruit_type 과 무관하게 kind='receipt' 로 저장하기 때문이다.
    --   이 행을 안 내보내면 화면이 「항목 없음 = 통과」로 처리해 마감 후에도 폼이 열리고,
    --   제출하면 트리거가 거부한다 — 3단계가 없애려던 바로 그 「화면은 열렸는데 서버가 거부」다.
    --   ⚠️ 인증 성공 판정(computeCertStatus)이 방문형에서 영수증을 안 보는 것과는 **다른 축**이다.
    --      그건 「인증 성공의 정의」이고 이건 「제출 가능 여부」다.
    IF v_recruit_type = 'visit' THEN
      RETURN QUERY
        SELECT 'receipt'::text, NULL::text,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM public.can_submit_deliverable(p_application_id, 'receipt', NULL) AS r;
    END IF;
  END IF;
  -- 그 외 recruit_type(방어적 — 현재 값 2종 외 없음): 0행 반환

  RETURN;
END;
$$;
CREATE OR REPLACE FUNCTION public.link_orient_card_to_campaign(
  p_orient_id   uuid,
  p_card_idx    int,
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sheet          record;
  v_campaign       record;
  v_now            timestamptz := now();

  v_cards          jsonb;
  v_total_count    int;
  v_card_entry     jsonb;
  v_existing_cid   text;

  v_already_linked boolean;

  v_updated_cards  jsonb;
  v_updated_data   jsonb;
  v_published_count int := 0;
  v_all_published  boolean;

  -- [464] 모집 형식 일치 검사
  v_card_ft        text;      -- 카드의 form_type
  v_exp_rt         text;      -- 기대하는 recruit_type
BEGIN
  -- ── 권한 가드 ─────────────────────────────────────────────────────────
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('success', false, 'reason', 'permission_denied');
  END IF;

  -- ── orient_sheets 행 잠금 ─────────────────────────────────────────────
  SELECT id, brand_id, application_id, status, data, version, campaign_id
    INTO v_sheet
    FROM public.orient_sheets
   WHERE id = p_orient_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'not_found');
  END IF;

  -- ── 상태 검증: submitted 인 경우만 연결 가능 (196과 동일) ────────────
  IF v_sheet.status <> 'submitted' THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'invalid_status',
      'current_status', v_sheet.status
    );
  END IF;

  -- ── cards 배열 추출 + 인덱스 범위 검증 ────────────────────────────────
  v_cards       := COALESCE(v_sheet.data -> 'cards', '[]'::jsonb);
  v_total_count := jsonb_array_length(v_cards);

  IF p_card_idx < 0 OR p_card_idx >= v_total_count THEN
    RETURN jsonb_build_object(
      'success',     false,
      'reason',      'invalid_card',
      'card_idx',    p_card_idx,
      'total_count', v_total_count
    );
  END IF;

  -- ── 멱등 검사: 해당 카드에 이미 campaign_id 기록 여부 ────────────────
  v_card_entry   := v_cards -> p_card_idx;
  v_existing_cid := v_card_entry ->> 'campaign_id';

  IF v_existing_cid IS NOT NULL THEN
    RETURN jsonb_build_object(
      'success',              false,
      'reason',               'already_published',
      'card_idx',             p_card_idx,
      'existing_campaign_id', v_existing_cid
    );
  END IF;

  -- ── 캠페인 행 잠금 + 존재 확인 ────────────────────────────────────────
  -- FOR UPDATE 로 이 캠페인을 대상으로 하는 동시 연결 시도를 직렬화한다
  -- (아래 전역 중복 검사가 정확히 동작하려면 이 잠금이 검사보다 먼저 있어야 함).
  SELECT id, brand_id, campaign_no, recruit_type
    INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id
     FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'campaign_not_found');
  END IF;

  -- ── 브랜드 일치 검증 ──────────────────────────────────────────────────
  IF v_campaign.brand_id IS DISTINCT FROM v_sheet.brand_id THEN
    RETURN jsonb_build_object(
      'success',           false,
      'reason',            'brand_mismatch',
      'sheet_brand_id',    v_sheet.brand_id,
      'campaign_brand_id', v_campaign.brand_id
    );
  END IF;

  -- ── [464 → 가구매 철거 B] 모집 형식 일치 검증 ─────────────────────────
  -- 카드 형식 → 캠페인 형식: reviewer→monitor / seeding→gifting.
  --   가구매(proxy_purchase) 카드는 더 이상 연결하지 않는다(form_type_retired — 화면도 막는다).
  --   방문형(visit)은 대응하는 카드 형식이 없어 어느 카드로도 안 붙는다.
  -- 캠페인 행 잠금(위 FOR UPDATE) 뒤라 최신 값을 본다.
  -- 카드 형식이 그 밖이면(옛 데이터·예외) 판단 근거가 없어 막지 않는다.
  v_card_ft := v_card_entry ->> 'form_type';
  IF v_card_ft = 'proxy_purchase' THEN
    RETURN jsonb_build_object(
      'success',        false,
      'reason',         'form_type_retired',
      'card_form_type', v_card_ft
    );
  END IF;
  IF v_card_ft IN ('reviewer', 'seeding') THEN
    v_exp_rt := CASE WHEN v_card_ft = 'seeding' THEN 'gifting' ELSE 'monitor' END;
    IF v_campaign.recruit_type IS DISTINCT FROM v_exp_rt THEN
      RETURN jsonb_build_object(
        'success',               false,
        'reason',                'recruit_type_mismatch',
        'card_form_type',        v_card_ft,
        'campaign_recruit_type', v_campaign.recruit_type
      );
    END IF;
  END IF;

  -- ── 전역 중복 검사: 이 캠페인이 이미 "어떤" 시트의 "어떤" 카드에 연결됐는지 ──
  -- (campaigns 행 잠금 뒤에 수행 — 동시 연결 시도 직렬화 보장)
  SELECT EXISTS (
    SELECT 1
      FROM public.orient_sheets os2,
           LATERAL jsonb_array_elements(COALESCE(os2.data -> 'cards', '[]'::jsonb)) AS card2
     WHERE (card2 ->> 'campaign_id') = p_campaign_id::text
  ) INTO v_already_linked;

  IF v_already_linked THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'campaign_already_linked'
    );
  END IF;

  -- ── cards[p_card_idx]에 campaign_id·published_at·linked_existing 기록 ──
  v_updated_cards := jsonb_set(
    jsonb_set(
      jsonb_set(
        v_cards,
        ARRAY[p_card_idx::text, 'campaign_id'],
        to_jsonb(p_campaign_id::text),
        true
      ),
      ARRAY[p_card_idx::text, 'published_at'],
      to_jsonb(v_now::text),
      true
    ),
    ARRAY[p_card_idx::text, 'linked_existing'],
    to_jsonb(true),
    true
  );

  v_updated_data := jsonb_set(v_sheet.data, '{cards}', v_updated_cards, false);

  -- ── all_published 판정 (196과 동일 로직) ─────────────────────────────
  SELECT COUNT(*)
    INTO v_published_count
    FROM jsonb_array_elements(v_updated_cards) AS card
   WHERE (card ->> 'campaign_id') IS NOT NULL;

  v_all_published := (v_published_count = v_total_count AND v_total_count > 0);

  -- ── UPDATE ────────────────────────────────────────────────────────────
  IF v_all_published THEN
    UPDATE public.orient_sheets
       SET data        = v_updated_data,
           version     = v_sheet.version + 1,
           status      = 'consumed',
           consumed_at = v_now,
           campaign_id = p_campaign_id
     WHERE id = v_sheet.id;
  ELSE
    UPDATE public.orient_sheets
       SET data    = v_updated_data,
           version = v_sheet.version + 1
     WHERE id = v_sheet.id;
  END IF;

  -- ── 반환 ─────────────────────────────────────────────────────────────
  RETURN jsonb_build_object(
    'success',         true,
    'status',          CASE WHEN v_all_published THEN 'consumed' ELSE 'submitted' END,
    'all_published',   v_all_published,
    'published_count', v_published_count,
    'total_count',     v_total_count,
    'campaign_no',     v_campaign.campaign_no,
    'linked_existing', true,
    'version',         v_sheet.version + 1
  );
END;
$$;
NOTIFY pgrst, 'reload schema';

COMMIT;
