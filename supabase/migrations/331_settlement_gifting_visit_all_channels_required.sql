-- ============================================================
-- 331_settlement_gifting_visit_all_channels_required.sql
-- 시딩(gifting)·방문형(visit) 인증 성공 판정 — 캠페인이 요구하는 채널 "전부"가
-- 승인돼야 인증 성공으로 바꾼다 (지금까지는 여러 채널 중 아무 1건만 승인돼도
-- 인증 성공 + 리워드 전액이 지급되고 있었다)
--
-- ── 재정의 기준 확인(전수 grep, feedback_function_redefine_latest_base 메모리 규칙) ──
--   함수를 정의(CREATE/CREATE OR REPLACE FUNCTION)한 파일은 232 → 262 → 264 → 300 →
--   318 다섯 곳(그 뒤 324 는 이 함수를 "손대지 않는다"고 스스로 명시하며 그대로
--   호출만 한다 — 324 파일 26행 참고). 번호가 가장 큰 318 이 현재 유효한 원본이다.
--   이 마이그레이션은 318 의 함수 본문을 그대로 베이스로 삼는다.
--
-- ── 무엇이 문제였나 ──
--   318(=300=264=262=232 원본) 의 is_success·cert_at CASE 문은 recruit_type='monitor'
--   일 때만 "캠페인이 요구하는 채널 전부가 승인돼야 한다"(channel_cert CTE +
--   review_channel_latest, 채널마다 카드를 하나씩 요구하는 화면과 동일 규칙)를
--   강제한다. recruit_type 이 gifting·visit 인 ELSE 분기는 channel 을 전혀 보지
--   않고 `post_latest`(응모 단위로 "가장 최근에 제출된 게시물 1건", 채널 무관)의
--   상태만 본다 — 즉 캠페인이 인스타그램·틱톡 둘 다 요구해도, 둘 중 아무 채널이나
--   1건만 승인되면(심지어 그게 가장 나중에 제출된 게시물이기만 하면) 나머지 채널을
--   전혀 안 냈어도 인증 성공 + 정산 후보(전액)로 잡힌다.
--
-- ── 결정된 방향(사용자 확인 완료) ──
--   시딩·방문형도 리뷰어형(monitor)이 이미 하는 방식을 채널 종류만 바꿔 그대로
--   재사용한다. 새로운 판정 방식을 만들지 않는다 — channel_cert/review_channel_latest
--   와 완전히 같은 구조(EXISTS+NOT EXISTS 쌍, 채널 비교 규칙까지)로
--   post_channel_cert/post_channel_latest 를 추가한다.
--
--   채널 비교 규칙도 monitor 와 완전히 동일하게 맞춘다(마이그레이션 319 로 이미
--   통일된 축) — 캠페인 쪽 채널 토큰만 btrim, 결과물(deliverables.post_channel) 쪽
--   값은 원본 그대로(트림·대소문자 변환 없음) 비교. 두 규칙이 갈리면 정산과
--   화면 사이에 또 다른 사각지대가 생긴다(319 파일이 경고한 바로 그 함정).
--
-- ── 운영 실측(2026-08-10, 소급 피해 여부 확인) ──
--   채널을 2개 이상 요구하는 시딩(gifting) 캠페인 = 0건.
--   방문형(visit) 인증 성공(is_success=true) 응모 = 0건.
--   → 지금 이 순간 이 변경으로 성공→실패 로 뒤집히는 "기존" 데이터는 없다.
--   그러나 데이터는 계속 쌓이므로, 이 마이그레이션을 적용하는 시점에 실측이
--   달라졌을 수 있다 — 아래 [V0] 을 반드시 적용 *직전에* 다시 돌려 재확인한다.
--
-- ── 이 마이그레이션이 바꾸는 것(전부) ──
--   1) CTE 추가 — post_channel_latest(게시물의 응모×채널별 최신 1건, draft 제외[318
--      규칙 계승]) · post_channel_cert(그 응모의 캠페인 채널 전체에 대한 승인시각
--      최댓값 + 완전성 강제 any_null. channel_cert 를 recruit_type<>'monitor' 로만
--      바꾼 것과 완전히 같은 구조)
--   2) CTE 제거 — post_latest(응모 단위 채널 무관 최신 게시물 1건). is_success·cert_at
--      의 ELSE 분기가 더 이상 이 값을 쓰지 않으므로 제거한다(쓰이지 않는 CTE를
--      남겨두면 "왜 안 쓰이지"라는 혼란만 남긴다).
--   3) is_success CASE 문의 ELSE(gifting·visit) 분기 — monitor 의 EXISTS+NOT EXISTS
--      쌍을 채널 종류만 review_channel_latest→post_channel_latest 로 바꿔 그대로
--      재사용.
--   4) cert_at CASE 문의 ELSE(gifting·visit) 분기 — "채널 전부 승인된 시점"(=마지막
--      채널이 승인된 시각) = post_channel_cert.max_channel_reviewed_at. monitor 는
--      영수증 승인 시각과 GREATEST 로 합치지만, gifting·visit 은 합칠 영수증
--      개념이 없어(정산 판정에서 영수증을 보지 않음 — 300/318 부터 그대로) 채널
--      완전성 시각 하나만 쓴다.
--
-- ── 절대 바꾸지 않는 것 ──
--   candidates CTE(승인 응모·감사용 제외·정산행 미존재·264 의 무보수 시딩/방문형
--   제외 조건, ⚠️여전히 유지 — 재확인은 아래 [V6]) / receipt_latest / 금액 계산
--   CASE 문(리뷰어형=min(영수증,상시가) 절사 / 시딩·방문형=reward 그대로, 261·300
--   그대로) / amount_issue 판정 3종(모두 monitor 전용이라 이 변경과 무관) /
--   receipt_amount_jpy·amount_cap_jpy / monitor(리뷰어형) 의 is_success·cert_at
--   분기(가구매·일반 둘 다) — 300/318 과 한 글자도 다르지 않다. RETURNS TABLE
--   시그니처(컬럼 이름·타입)도 318 과 완전히 동일 — 반환 타입이 안 바뀌므로 DROP
--   없이 CREATE OR REPLACE 로 충분하다.
--
--   이 헬퍼를 호출하는 backfill_settlements()·get_past_unregistered_settlements()·
--   register_past_settlements() 3곳(324 가 최신 원본)은 헬퍼가 돌려주는 컬럼·타입이
--   그대로라 재정의할 필요가 없다.
--
-- ── ⚠️ 채널이 비어 있는 시딩·방문형 캠페인 처리 방침 ──
--   monitor 는 이미 "채널이 0개면 인증 성공이 안 된다"(EXISTS 조건이 거짓)는
--   규칙을 쓰고 있고, 이 마이그레이션은 그 규칙을 gifting·visit 에도 그대로
--   적용한다 — channel 이 NULL/빈 문자열/공백뿐이면 unnest(string_to_array(...))
--   가 0행을 내어 EXISTS 가 거짓이 되고, is_success 는 항상 false 가 된다.
--
--   이 규칙을 그대로 적용하면 "채널이 비어 있는 채로 이미 게시물이 승인돼
--   인증 성공으로 잡혀 있던" gifting·visit 응모가 있을 경우 그 응모가 이 마이그
--   레이션 적용 즉시 인증 성공에서 빠진다(=정산 후보에서 사라진다) — 이미 정산
--   행이 생성된 응모는 candidates CTE 의 "정산행 미존재" 조건에 걸려 애초에 이
--   함수의 대상이 아니므로 영향받지 않지만, 아직 정산행이 없는 응모는 영향받는다.
--
--   ⚠️ 이것이 정말 존재하는지는 코드 작성 시점에는 검증할 수 없다(데이터베이스에
--   직접 접근하지 않았다) — 반드시 아래 [V0] 을 이 파일의 CREATE OR REPLACE 를
--   실행하기 *전에* 먼저 돌려서 확인한다. [V0] 이 1행이라도 반환하면 즉시 멈추고
--   이 마이그레이션을 적용하지 말 것 — 그 응모들을 어떻게 처리할지(캠페인의
--   channel 칸을 먼저 채워 넣을지 / 그 응모만 예외로 둘지 / 이미 확인된 건이라
--   수동으로 먼저 정산 처리해 candidates 에서 빼놓을지)는 사람이 결정해야 하는
--   사안이라 이 마이그레이션이 자동으로 판단하지 않는다.
--
-- ── 정산 행 생성에 미치는 실질 영향(318 파일과 동일한 구조로 안내) ──
--   1) backfill_settlements() 는 v_cutoff IS NOT NULL 을 요구한다 — 이 문서 작성
--      시점 운영은 settlement_settings.cutoff_at 이 미설정(NULL)이라 자동 백필은
--      여전히 0건이다(created_count 는 이 변경과 무관하게 계속 0).
--   2) get_past_unregistered_settlements()("과거 미등록" 수동 처리 화면)는
--      컷오프와 무관하게 후보를 그대로 보여준다 — **이 화면은 이 마이그레이션
--      적용 즉시 영향받는다.** 지금까지 "인증성공"으로 떠 있던 gifting·visit
--      응모 중, 캠페인이 요구하는 채널 전부가 승인되지 않은 건은 이 화면에서
--      바로 사라진다(의도된 동작 — 그 건들은 애초에 "완료"가 아니었다). 반대로
--      이미 사람이 그 화면에서 "송금완료 기록" 버튼을 눌러 만든 기존 settlements
--      행은 candidates 조건(정산행 미존재)에 걸려 이 헬퍼의 대상이 아니므로
--      **소급 변경·환수는 일어나지 않는다.**
--   운영 실측(위 "운영 실측" 절)상 오늘 시점에는 이 화면에서 사라지는 건도 0건일
--   것으로 예상되지만, 반드시 [V0]으로 재확인한 뒤 적용할 것.
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
    -- + [264, 유지] 무보수 시딩·방문형 제외. 318 원본과 완전히 동일(이 마이그레이션은
    -- 여기를 손대지 않는다).
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
    -- 318 원본과 완전히 동일(변경 없음) — 응모별 영수증(receipt) 최신 1건(draft 제외).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at, d.purchase_amount
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_channel_latest AS (
    -- [331 신규] gifting·visit 게시물(post) 의 "응모×채널"별 최신 1건(draft 제외 —
    -- 318 이 receipt_latest·review_channel_latest 에 도입한 규칙을 그대로 계승).
    -- review_channel_latest 와 완전히 같은 패턴(DISTINCT ON + submitted_at/updated_at
    -- 내림차순). post_channel 이 NULL(채널 판별 불가 레거시)인 행은 후보에서 제외 —
    -- 아래 비교(pcl.post_channel = btrim(ch.name))에서 NULL 은 결과가 같지만, 명시적
    -- 조건으로 미리 빼 두면 review_channel_latest 와 완전히 같은 모양이 된다.
    -- 응모 단위(채널 무관) 최신 1건이던 옛 post_latest CTE 는 이 마이그레이션에서
    -- 완전히 대체돼 제거됐다 — 아래 is_success·cert_at 어디에서도 더 이상 참조하지
    -- 않는다.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 318 원본과 완전히 동일(변경 없음) — 응모×채널별 인증샷(review_image) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 318 원본과 완전히 동일(변경 없음) — 리뷰어(monitor 일반) 응모의 캠페인 채널
    -- 전체 인증샷 승인시각 최댓값 + 완전성 강제(any_null).
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
  ),
  post_channel_cert AS (
    -- [331 신규] channel_cert 를 recruit_type<>'monitor'(시딩·방문형) 로만 바꿔 그대로
    -- 재사용 — 그 응모의 캠페인 채널 전체에 대한 게시물 승인시각 최댓값(마지막 채널이
    -- 승인된 시각) + 완전성 강제(any_null, 하나라도 미승인이면 true). 채널 비교 규칙도
    -- channel_cert 와 완전히 동일 — 캠페인 토큰만 btrim, post_channel 은 원본 그대로
    -- (마이그레이션 319 로 통일된 축, 대소문자·공백까지 정확히 일치해야 함).
    SELECT
      cd.application_id,
      MAX(pcl.reviewed_at)                      AS max_channel_reviewed_at,
      bool_or(pcl.reviewed_at IS NULL)           AS any_null
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
    -- 318 원본과 완전히 동일(변경 없음).
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
    -- ── 감사용 칸 2개(299) — 리뷰어형만 채움, 그 외 NULL. 318 원본과 동일 ──
    CASE WHEN cd.recruit_type = 'monitor' THEN floor(rl.purchase_amount)::bigint ELSE NULL::bigint END AS receipt_amount_jpy,
    CASE WHEN cd.recruit_type = 'monitor' THEN cd.product_price ELSE NULL::bigint END AS amount_cap_jpy,
    -- ── amount_issue: 조건 3종(318 그대로 — 모두 monitor 전용, 이 변경과 무관) ──
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
    -- monitor 분기 2종은 318(=300=264=262=232=231 원본) 그대로 무변경.
    -- ELSE(gifting·visit) 분기만 [331] 채널 완전성 요구로 교체.
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
        -- [331] 시딩(gifting)·방문형(visit) — 캠페인이 요구하는 채널 "전부"에 승인된
        -- 게시물이 있어야 인증 성공. 채널이 0개(NULL/빈 문자열/공백뿐)면 EXISTS 가
        -- 거짓이 되어 is_success 는 항상 false(monitor 와 동일 규칙 — 위 "채널이 비어
        -- 있는 캠페인 처리 방침" 참고).
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
    END AS is_success,
    -- ── cert_at ──
    -- monitor 분기 2종은 318 그대로 무변경. ELSE(gifting·visit) 분기만 [331] 채널
    -- 완전성 시각(마지막 채널이 승인된 시각)으로 교체 — 합칠 영수증 승인 시각이
    -- 없으므로(정산 판정이 gifting·visit 의 영수증을 보지 않음, 300/318 부터 그대로)
    -- monitor 처럼 GREATEST 로 합치지 않는다.
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        rl.reviewed_at
      WHEN cd.recruit_type = 'monitor' THEN
        CASE
          WHEN rl.reviewed_at IS NULL OR COALESCE(cc.any_null, true) THEN NULL
          ELSE GREATEST(rl.reviewed_at, cc.max_channel_reviewed_at)
        END
      ELSE
        CASE
          WHEN COALESCE(pcc.any_null, true) THEN NULL
          ELSE pcc.max_channel_reviewed_at
        END
    END AS cert_at
  FROM candidates cd
  LEFT JOIN receipt_latest    rl  ON rl.application_id = cd.application_id
  LEFT JOIN channel_cert      cc  ON cc.application_id = cd.application_id
  LEFT JOIN post_channel_cert pcc ON pcc.application_id = cd.application_id;
$$;

COMMENT ON FUNCTION public._settlement_cert_candidates() IS
  '[331 재정의, 318 원본 대체(반환 컬럼 무변경 — is_success·cert_at 의 gifting·visit '
  '분기만 변경)] private 헬퍼 — 정산 미등록(settlements 행 없음) 응모 전체에 대해 인증 '
  '성공 여부(is_success)·인증 성공일(cert_at)·모집 형식별 정산 금액(amount_jpy)·금액 '
  '출처(amount_source)·감사용 원금액/상한(receipt_amount_jpy/amount_cap_jpy)·금액 미확정 '
  '사유(amount_issue)를 계산한다. '
  '[331] 시딩(gifting)·방문형(visit) 도 리뷰어형(monitor) 과 동일하게 캠페인이 요구하는 '
  '채널(campaigns.channel) 전부에 승인된 게시물(post)이 있어야 인증 성공으로 판정한다 '
  '(post_channel_latest·post_channel_cert 신규 — monitor 의 review_channel_latest·'
  'channel_cert 를 채널 종류만 바꿔 그대로 재사용, 채널 비교 규칙도 동일[319: 캠페인 '
  '토큰만 btrim, 결과물 쪽은 원본 그대로]). 채널이 0개인 캠페인은 monitor 와 동일하게 '
  '항상 is_success=false. 응모 단위(채널 무관) 최신 게시물 1건만 보던 옛 post_latest '
  'CTE 는 제거. 그 외(candidates·receipt_latest·금액 계산·amount_issue·monitor 분기)는 '
  '318 그대로 무변경. '
  'backfill_settlements()·get_past_unregistered_settlements()·register_past_settlements() '
  '3곳이 이 함수 하나를 호출해 판정·금액 로직 드리프트를 원천 차단. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 호출 불가) — 318 과 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ SQL Editor 세션은 auth.uid() 가 NULL 이라 has_permission 게이트가 있는 함수
--   (backfill_settlements 등)는 postgres(소유자) role 로 실행해야 permission_denied
--   없이 호출된다. 헬퍼(_settlement_cert_candidates) 자체는 오너 권한이면 직접 SELECT 가능.
-- ============================================================
/*

-- ══════════════ [V0] 필수 — 반드시 위 CREATE OR REPLACE 를 실행하기 *전에* 먼저 ══════════════
-- 돌린다. 지금(318 상태) 시딩·방문형 중 is_success=true 인 후보 중에서, 이 마이그
-- 레이션이 도입하는 "채널 전부 승인" 규칙으로 다시 판정하면 false 로 뒤집히는
-- 응모를 찾는다. 아직 이 파일의 CREATE OR REPLACE 를 실행하지 않았으므로 "새 규칙"
-- 부분은 이 조회 안에서 직접 계산한다(함수를 바꾸기 전이라 함수 호출로는 확인할
-- 수 없다).
WITH old_success AS (
  -- 지금 이 순간(마이그레이션 331 적용 전, 즉 318 상태) 실제로 is_success=true 인
  -- 시딩·방문형 후보. 정산행이 이미 있는 응모는 애초에 이 함수의 대상이 아니므로
  -- (candidates CTE 의 "정산행 미존재" 조건) 여기 안 걸린다 — 즉 이 조회가 찾는
  -- 응모는 전부 "아직 정산행이 없는" 응모다.
  SELECT application_id, campaign_id
  FROM public._settlement_cert_candidates()
  WHERE recruit_type IN ('gifting', 'visit') AND is_success
),
new_post_channel_latest AS (
  -- 이 마이그레이션이 새로 도입하는 CTE 를 함수 재정의 전에 미리 계산(위 CREATE OR
  -- REPLACE 블록의 post_channel_latest 와 완전히 동일한 정의).
  SELECT DISTINCT ON (d.application_id, d.post_channel)
    d.application_id, d.post_channel, d.status
  FROM public.deliverables d
  WHERE d.kind = 'post' AND d.post_channel IS NOT NULL AND d.status <> 'draft'
  ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
)
SELECT
  os.application_id, os.campaign_id, c.campaign_no, c.title,
  c.channel AS campaign_channel_raw,
  (c.channel IS NULL OR btrim(c.channel) = '') AS channel_is_empty
FROM old_success os
JOIN public.campaigns c ON c.id = os.campaign_id
WHERE NOT (
  -- 위 CREATE OR REPLACE 블록의 is_success ELSE 분기(gifting·visit)와 완전히 동일한
  -- 식 — 새 규칙으로 다시 판정했을 때도 여전히 true 인지 확인.
  EXISTS (
    SELECT 1 FROM unnest(string_to_array(c.channel, ',')) AS ch(name)
    WHERE btrim(ch.name) <> ''
  )
  AND NOT EXISTS (
    SELECT 1
    FROM unnest(string_to_array(c.channel, ',')) AS ch(name)
    LEFT JOIN new_post_channel_latest pcl
      ON pcl.application_id = os.application_id
     AND pcl.post_channel   = btrim(ch.name)
    WHERE btrim(ch.name) <> ''
      AND COALESCE(pcl.status, 'none') <> 'approved'
  )
)
ORDER BY c.campaign_no;
-- 기대(2026-08-10 실측 기준): 0행.
-- ⚠️ 1행이라도 나오면 즉시 멈추고 이 마이그레이션(위 CREATE OR REPLACE)을 적용하지
-- 말 것. channel_is_empty=true 인 행은 "캠페인 channel 칸이 비어 있어서" 뒤집히는
-- 경우, false 인 행은 "채널은 있는데 일부만 승인돼서" 뒤집히는 경우다 — 어느
-- 쪽이든 사람이 먼저 확인·결정해야 한다(파일 상단 "채널이 비어 있는 캠페인 처리
-- 방침" 참고). 결정 후 이 쿼리를 다시 돌려 0행이 될 때 비로소 적용한다.


-- ══════════════ [V0-b] 참고용(적용 여부와 무관, 과거 손실 확인) ══════════════
-- 이미 settlements 행이 만들어진(=이미 송금대기/완료로 등록된) gifting·visit 정산
-- 중, 캠페인이 채널을 2개 이상 요구하는데 그중 일부 채널에만 승인된 게시물이 있는
-- 것(=지금 규칙이면 애초에 인증 성공이 아니었을 것)이 있는지 참고로 확인한다.
-- 이 마이그레이션은 이미 만들어진 settlements 행을 전혀 건드리지 않으므로(정산행이
-- 있으면 candidates 에서 원천 제외) 여기서 뭐가 나오든 이 마이그레이션 적용 여부와
-- 무관하다 — 과거에 이미 일어난 일을 파악하는 용도일 뿐이다.
WITH multi_channel_settled AS (
  SELECT s.id AS settlement_id, s.application_id, s.status, s.amount_jpy,
         c.campaign_no, c.title, c.channel,
         array_length(
           array_remove(string_to_array(c.channel, ','), ''), 1
         ) AS channel_count
  FROM public.settlements s
  JOIN public.campaigns   c ON c.id = s.campaign_id
  WHERE c.recruit_type IN ('gifting', 'visit')
),
approved_post_channels AS (
  SELECT DISTINCT application_id, post_channel
  FROM public.deliverables
  WHERE kind = 'post' AND status = 'approved' AND post_channel IS NOT NULL
)
SELECT mcs.*, count(apc.post_channel) AS approved_channel_count
FROM multi_channel_settled mcs
LEFT JOIN approved_post_channels apc ON apc.application_id = mcs.application_id
WHERE mcs.channel_count >= 2
GROUP BY mcs.settlement_id, mcs.application_id, mcs.status, mcs.amount_jpy,
         mcs.campaign_no, mcs.title, mcs.channel, mcs.channel_count
HAVING count(apc.post_channel) < mcs.channel_count
ORDER BY mcs.campaign_no;
-- 0행이 아니면: 과거에 일부 채널만 승인된 채로 이미 정산(대기/완료)이 만들어진
-- 건이 있다는 뜻 — 이 마이그레이션이 자동으로 되돌리지 않으므로, 필요하면 별도로
-- (관리자 확인 후) settlement_events 에 사유를 남기고 수동으로 보류(on_hold)
-- 처리할지 사람이 결정할 사안이다.


-- ⚠️⚠️ [V0] 이 0행이고 필요하면 [V0-b] 도 확인했다면, 이 지점에서 파일 상단의
-- CREATE OR REPLACE 블록을 SQL Editor 에 적용한다 ⚠️⚠️


-- ══════════════ [V1] 함수 반환 타입이 318 과 동일한지 확인 ══════════════
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = '_settlement_cert_candidates';

-- ══════════════ [V2] 헬퍼가 여전히 PUBLIC/authenticated 에 노출 안 됐는지 확인 ══════════════
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만)

-- ══════════════ [V3] [V0] 이 지목한 응모들이 적용 후에도 여전히 false 인지(회귀 없음) ══════════════
-- [V0] 이 0행이었다면 이 단계는 건너뛰어도 된다(대상 자체가 없음).
SELECT application_id, recruit_type, is_success, amount_issue, cert_at
FROM public._settlement_cert_candidates()
WHERE application_id = ANY(ARRAY[]::uuid[])  -- ← [V0] 결과의 application_id 를 채워 실행
ORDER BY application_id;

-- ══════════════ [V4] 전체 집계 전후 비교 ══════════════
-- monitor 의 candidate_cnt·success_cnt 는 이 변경과 무관하므로 그대로여야 한다.
-- gifting·visit 의 success_cnt 는 [V0] 에서 찾은 건수만큼(운영 실측상 0) 줄어들 수 있다.
SELECT
  recruit_type,
  count(*) AS candidate_cnt,
  count(*) FILTER (WHERE is_success) AS success_cnt,
  count(*) FILTER (WHERE is_success AND amount_issue IS NOT NULL) AS success_but_amount_issue_cnt,
  sum(amount_jpy) FILTER (WHERE is_success AND amount_issue IS NULL) AS success_amount_sum
FROM public._settlement_cert_candidates()
GROUP BY recruit_type
ORDER BY recruit_type;

-- ══════════════ [V5] backfill_settlements() 회귀 확인 — cutoff_at 미설정이면 여전히 0건 ══════════════
-- (postgres role 로 실행하거나 has_permission 통과하는 관리자 세션 필요)
SELECT cutoff_at, influencer_visible FROM public.settlement_settings WHERE id = 1;
SELECT * FROM public.backfill_settlements();
-- 기대: created_count=0 (cutoff_at 이 NULL 인 동안은 이 변경과 무관하게 항상 0)

-- ══════════════ [V6] candidates CTE(264 무보수 시딩·방문형 제외)가 여전히 살아있는지 ══════════════
-- reward 가 NULL·0 이하인 시딩·방문형 캠페인의 승인 응모는 이 함수 결과에 아예
-- 나타나면 안 된다(후보에서 원천 제외 — 이 마이그레이션이 손대지 않은 부분의 회귀 확인).
SELECT count(*) AS should_be_zero
FROM public._settlement_cert_candidates() c
JOIN public.campaigns camp ON camp.id = c.campaign_id
WHERE camp.recruit_type <> 'monitor' AND (camp.reward IS NULL OR camp.reward <= 0);
-- 기대: 0

-- ══════════════ [V7] get_past_unregistered_settlements() 스모크 ══════════════
-- (앱에서 campaign_admin 이상 세션으로 확인 권장 — SQL Editor 직접 호출은
-- permission_denied 가능. [V0] 이 0행이면 이 화면의 건수는 적용 전후로 그대로여야 한다)
-- SELECT recruit_type, count(*) FROM public.get_past_unregistered_settlements()
-- GROUP BY recruit_type ORDER BY recruit_type;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 반환 타입(컬럼 구성)이 318 과 동일하므로 DROP 없이 CREATE OR REPLACE 로 되돌릴 수 있다.
-- 1) 318_settlement_candidates_exclude_draft.sql 파일을 열어
--    "CREATE OR REPLACE FUNCTION public._settlement_cert_candidates()" 블록부터
--    그 COMMENT ON FUNCTION 문장까지를 그대로 복사해 SQL Editor 에서 실행한다.
-- 2) REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC; 실행.
-- 3) NOTIFY pgrst, 'reload schema'; 실행.
-- 이 작업은 post_channel_latest·post_channel_cert 두 CTE 를 제거하고 옛 post_latest
-- CTE 를 되살려, is_success·cert_at 의 gifting·visit 분기를 "아무 채널이나 1건만
-- 승인되면 성공"으로 되돌리는 것과 동일한 효과다. backfill_settlements()·
-- get_past_unregistered_settlements()·register_past_settlements() 는 331 에서 손대지
-- 않았으므로 함께 되돌릴 필요가 없다.
-- ============================================================
