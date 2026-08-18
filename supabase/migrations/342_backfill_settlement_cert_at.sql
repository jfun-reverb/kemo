-- ============================================================
-- 342_backfill_settlement_cert_at.sql
-- 인증 성공 시각이 비어 있는 정산 행 채우기 (정산 3단계 · 작업표 「작업 5 — F」)
--
-- ▶ 왜
--   화면이 「인증성공일」이라고 보여주던 값은 실은 **등록일**이었다. 과거분을 오늘 등록하면
--   오늘로 찍혀, **실제로 언제 인증에 성공했는지가 어디에도 안 남았다.** 마이그레이션 324 가
--   `cert_at` 칸을 새로 만들었지만 **그 이후 생기는 행만** 채운다.
--   운영 실측(2026-08-18): 그 이전에 만들어진 행 **204건**이 전부 비어 있고, 화면에는
--   「기록 없음」으로 뜬다.
--
-- ▶ 사전 측정 결과 (적용 전에 반드시 셌다 — 작업표 지시)
--   `supabase/patches/2026-08-18-measure-cert-at-backfill.sql` 을 운영에서 돌린 결과:
--     대상 204 / 판정 다시 돌릴 수 있음 204 / 지금 기준으로도 인증 성공 204 /
--     **인증일 복원 가능 204** / 판정은 되나 인증일 없음 0 / 응모 자체가 사라짐 0
--     복원되는 인증일 범위: 2026-05-18 ~ 2026-07-29
--   → 판정 기준이 그 사이 두 번 바뀌었는데도(318 = 임시저장 제외 / 331 = 시딩·방문형도
--     요구한 채널 전부) **뒤집힌 건이 하나도 없다.** 그래서 그대로 진행한다.
--
-- ▶ 무엇을 채우나 — **`cert_at` 하나뿐**
--   ⚠️ `paid_at` 은 **안 건드린다.** 2026-08-04 이전에 만들어진 행의 송금일은 「기록일」이지
--      실제 송금일이 아니지만, 그 정정은 하지 않기로 확정됐다(사양서 §5 ④).
--      실제 송금일을 고치는 길은 `correct_settlement_payment`(마이그레이션 341)다.
--   ⚠️ `version` 도 **안 올린다.** 사람이 바꾼 상태 변화가 아니라 처음부터 있었어야 할 값을
--      뒤늦게 적는 것이라, 올리면 목록을 열어 둔 관리자에게 **가짜 충돌**이 난다.
--   ⚠️ `updated_at` 은 트리거(217 `trg_settlements_updated_at`)가 자동으로 올린다 —
--      막을 방법이 없고 막을 이유도 없다(실제로 행이 바뀐 게 맞다).
--
-- ▶ 안전 장치 3종
--   ① **비어 있는 칸만** 채운다(`s.cert_at IS NULL`) — 이미 있는 값은 절대 안 덮는다
--   ② **계산 결과가 있을 때만**(`cand.cert_at IS NOT NULL`)
--   ③ ★ **지금 기준으로도 인증 성공인 건만**(`cand.is_success`)
--      ⚠️ ③이 없으면 안 된다. 가구매(`proxy_purchase`) 분기는 `cert_at` 을 영수증의
--         **검수 시각** 그대로 쓰는데, **반려된 영수증에도 검수 시각은 있다.**
--         즉 ②만 보면 「반려됐는데 인증일이 찍히는」 행이 생긴다.
--   → 다시 돌려도 아무것도 안 바뀐다(멱등).
--
-- ⚠️ 번호 안내 — 334~342 사용. 다음은 343.
--    332 는 이 저장소 dev 에 이미 `site_daily_visits` 로 확정돼 있다(iOS 와 무관).
--    333 만 `feature/ios-app` 브랜치와 겹쳐 비워 둔 것이다.
-- ============================================================

BEGIN;

UPDATE public.settlements s
   SET cert_at = cand.cert_at
  FROM (
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
          -- ★ [342] 「이미 정산 행이 있으면 제외」 조항을 **여기서만** 뺐다.
          --   원본 함수(331)는 「아직 등록 안 된 건」을 찾는 용도라 그 조항이 맞다. 우리는 반대로
          --   **이미 등록된 행**의 인증 시각을 되살리려는 것이라 그 조항이 걸림돌이다.
          --   ⚠️ 원본 함수는 **건드리지 않는다.** 이 복사본은 아래 UPDATE 한 문장 안에서만 살고
          --      끝나면 사라진다 — 저장소에 판정이 두 벌 영구히 남으면 나중에 서로 어긋난다.
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
      LEFT JOIN post_channel_cert pcc ON pcc.application_id = cd.application_id
  ) cand
 WHERE cand.application_id = s.application_id
   AND s.cert_at    IS NULL          -- ① 비어 있는 칸만
   AND cand.cert_at IS NOT NULL      -- ② 계산 결과가 있을 때만
   AND cand.is_success;              -- ③ 지금 기준으로도 인증 성공인 건만 (위 머리말 참조)

COMMIT;

-- ── 적용 후 확인 ────────────────────────────────────────────
-- [1] ★ 「기록 없음」이 0건이 됐나 (작업표의 완료 정의)
--   SELECT count(*) FILTER (WHERE cert_at IS NULL) AS "아직 비어 있음",
--          count(cert_at)                          AS "채워짐",
--          count(*)                                AS "전체"
--     FROM public.settlements;
--   기대(운영): 0 / 204 / 204
--
-- [2] 채워진 값이 그럴듯한가 — 인증일이 송금일보다 뒤인 행이 있으면 이상하다
--   SELECT count(*) AS "인증일이 송금일보다 뒤(0이어야 함)"
--     FROM public.settlements
--    WHERE cert_at IS NOT NULL AND paid_at IS NOT NULL AND cert_at > paid_at;
--   ⚠️ 0이 아니어도 데이터 오류가 아닐 수 있다 — 2026-08-04 이전 행의 `paid_at` 은
--      실제 송금일이 아니라 **기록일**이라, 인증 직후 바로 기록했다면 근소하게 뒤집힐 수 있다.
--      크게 벌어진 건이 있으면 그때 들여다볼 것.
--
-- [3] 월별 분포 — 화면에서 회차별로 묶일 때 어떻게 보일지 미리 본다
--   SELECT to_char(cert_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM') AS 월, count(*)
--     FROM public.settlements WHERE cert_at IS NOT NULL GROUP BY 1 ORDER BY 1;
--
-- 롤백: 이 마이그레이션이 채운 값만 되돌리려면 **어느 행을 채웠는지 알아야 한다.**
--   적용 직전에 아래를 떠 두면 되돌릴 수 있다(적용 후에는 구분이 불가능하다):
--     CREATE TABLE public._cert_at_backup_20260818 AS
--       SELECT id FROM public.settlements WHERE cert_at IS NULL;
--   되돌리기:
--     UPDATE public.settlements SET cert_at = NULL
--      WHERE id IN (SELECT id FROM public._cert_at_backup_20260818);
--   ⚠️ 다만 되돌릴 이유는 거의 없다 — **비어 있던 칸을 채우기만** 하고 다른 값은 안 건드린다.
