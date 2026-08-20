-- ============================================================
-- 360_promo_digest_exclude_withdrawing.sql
--
-- 회원 탈퇴 — 작업 16 「홍보성 알림·메일 차단」
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 16」
--
-- ============================================================
-- ① 무엇을 하나
-- ============================================================
--   캠페인 홍보 메일의 대상 조회 함수(`get_promo_digest_targets`)를 재정의해,
--   **탈퇴 절차가 진행 중이거나 끝난 회원을 대상에서 뺀다.**
--
--   ★ **베이스는 321** (`promo_digest_stable_order_and_invite_only_exclude`).
--     원본을 스크립트로 통째 추출해 **조건 한 덩어리만** 더했다 — 손으로 옮기면
--     240줄 중 한 줄이 어긋나도 알 수 없다.
--     (규칙: 함수 재정의는 **파일 번호가 가장 큰 정의**를 베이스로 —
--      메모리 feedback_function_redefine_latest_base)
--
-- ============================================================
-- ② 왜 필요한가
-- ============================================================
--   탈퇴를 신청한 사람에게 「새 캠페인이 나왔어요」를 계속 보내는 것은 그 자체로
--   실례이고, 확정된 회원은 메일 주소가 자리표시 주소로 바뀌어 **반송만 쌓인다**.
--   발송 시도는 메일 한도(월 2만 통)를 태운다.
--
-- ============================================================
-- ③ 취소하면 저절로 돌아온다 — 되살리는 처리를 만들지 않는다
-- ============================================================
--   조건이 `cancelled` 를 빼고 있고, 이 함수는 발송할 때마다 상태를 **다시 읽는다.**
--   그래서 회원이 탈퇴를 취소하면 다음 발송부터 자동으로 대상에 돌아온다.
--   ⚠️ 「대상에서 뺐다가 다시 넣는」 별도 표·처리를 만들면 그것이 어긋날 자리가 된다.
--
-- ============================================================
-- ④ 이번 범위 밖 — 업무 알림은 그대로 간다
-- ============================================================
--   막는 것은 **홍보(마케팅)** 뿐이다. 응모 접수·검수 결과·마감 안내 같은 업무 알림과
--   탈퇴 예정일 안내 메일은 **계속 가야 한다** — 특히 예정일 안내는 정산 알림을 없앤 뒤로
--   **회원에게 닿는 유일한 통지**다.
--
-- ============================================================
-- ⑤ 되돌리기
-- ============================================================
--   321 파일의 함수 블록을 그대로 다시 실행하면 되돌아간다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_promo_digest_targets(p_digest_date date)
RETURNS TABLE (
  influencer_id            uuid,
  email                    text,
  name                     text,
  unsubscribe_token        uuid,
  new_campaign_ids         uuid[],
  deadline_d1_campaign_ids uuid[],
  new_total_count          integer,
  deadline_d1_total_count  integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH

  -- ──────────────────────────────────────────────────────────
  -- [A] 신규 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
  -- ──────────────────────────────────────────────────────────
  new_campaigns AS (
    SELECT
      c.id,
      c.channel,
      c.recruit_type,
      c.min_followers,
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND (c.first_active_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
      AND c.deadline >= CURRENT_DATE
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [B] D-1 임박 캠페인 — [259] 보관 삭제 캠페인 제외, [321] 초대 전용 제외
  -- ──────────────────────────────────────────────────────────
  deadline_d1_campaigns AS (
    SELECT
      c.id,
      c.channel,
      c.recruit_type,
      c.min_followers,
      c.primary_channel,
      c.deadline,
      c.slots
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND c.deadline = CURRENT_DATE + 1
      AND c.deleted_at IS NULL          -- [259] 보관 삭제 캠페인 제외
      AND c.is_invite_only = false      -- [321] 초대 전용(비공개) 캠페인 제외
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [C] 발송 대상 인플루언서 기본 조건 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  eligible_influencers AS (
    SELECT
      i.id,
      i.unsubscribe_token,
      i.name_kanji,
      i.name_kana,
      i.name,
      i.ig_followers,
      i.tiktok_followers,
      i.x_followers,
      i.youtube_followers,
      i.ig,
      i.tiktok,
      i.x,
      i.youtube
    FROM public.influencers i
    WHERE i.marketing_opt_in = true
      AND i.marketing_unsubscribed_at IS NULL
      -- [360] 탈퇴 절차가 진행 중이거나 끝난 회원은 홍보 메일 대상에서 뺀다.
      --   ⚠️ `cancelled` 는 넣지 않는다 — 탈퇴를 취소한 회원은 **즉시 대상으로 돌아와야**
      --     한다. 이 조건이 매번 상태를 다시 읽는 구조라, 되살리는 처리를 따로 만들지
      --     않아도 자동으로 복귀한다(작업표 작업 16 의 「자동 복귀」가 이 뜻이다).
      --   ⚠️ 확정된 회원은 메일 주소가 자리표시 주소로 바뀌어 어차피 닿지 않지만,
      --     발송 시도 자체가 메일 한도를 태우고 반송을 만든다.
      AND NOT EXISTS (
        SELECT 1
          FROM public.withdrawal_requests w
         WHERE w.influencer_id = i.id
           AND w.status IN ('pending_payout', 'scheduled', 'done')
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_digest_sent s
         WHERE s.influencer_id = i.id
           AND s.digest_date   = p_digest_date
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [D] 신규 캠페인 × 인플루언서 매칭 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  new_matches AS (
    SELECT
      i.id                                            AS influencer_id,
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5]  AS campaign_ids,
      COUNT(*)::integer                               AS total_count
    FROM eligible_influencers i
    CROSS JOIN new_campaigns c
    WHERE
      (
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers
          )
      AND NOT EXISTS (
        SELECT 1
          FROM public.applications a
         WHERE a.user_id     = i.id
           AND a.campaign_id = c.id
           AND a.status     <> 'cancelled'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'new'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_email_clicks k
         WHERE k.campaign_id   = c.id
           AND k.influencer_id = i.id
      )
    GROUP BY i.id
  ),

  -- ──────────────────────────────────────────────────────────
  -- [E] D-1 임박 캠페인 × 인플루언서 매칭 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  d1_matches AS (
    SELECT
      i.id                                            AS influencer_id,
      (array_agg(c.id ORDER BY c.deadline ASC))[1:5]  AS campaign_ids,
      COUNT(*)::integer                               AS total_count
    FROM eligible_influencers i
    CROSS JOIN deadline_d1_campaigns c
    WHERE
      (
        (c.channel LIKE '%instagram%' AND i.ig      IS NOT NULL AND i.ig      <> '')
        OR (c.channel LIKE '%tiktok%'    AND i.tiktok  IS NOT NULL AND i.tiktok  <> '')
        OR (c.channel LIKE '%x%'         AND i.x       IS NOT NULL AND i.x       <> '')
        OR (c.channel LIKE '%youtube%'   AND i.youtube IS NOT NULL AND i.youtube <> '')
      )
      AND public._meets_min_followers(
            c.recruit_type, c.primary_channel, c.channel, c.min_followers,
            i.ig_followers, i.tiktok_followers, i.x_followers, i.youtube_followers
          )
      AND NOT EXISTS (
        SELECT 1
          FROM public.applications a
         WHERE a.user_id     = i.id
           AND a.campaign_id = c.id
           AND a.status     <> 'cancelled'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_exposure e
         WHERE e.campaign_id   = c.id
           AND e.influencer_id = i.id
           AND e.kind          = 'deadline_d1'
      )
      AND NOT EXISTS (
        SELECT 1
          FROM public.campaign_promo_email_clicks k
         WHERE k.campaign_id   = c.id
           AND k.influencer_id = i.id
      )
    GROUP BY i.id
  ),

  -- ──────────────────────────────────────────────────────────
  -- [F] 두 매칭 결합 (변경 없음)
  -- ──────────────────────────────────────────────────────────
  all_targets AS (
    SELECT
      COALESCE(nm.influencer_id, dm.influencer_id) AS influencer_id,
      COALESCE(nm.campaign_ids, '{}')              AS new_campaign_ids,
      COALESCE(dm.campaign_ids, '{}')              AS deadline_d1_campaign_ids,
      COALESCE(nm.total_count, 0)                  AS new_total_count,
      COALESCE(dm.total_count, 0)                  AS deadline_d1_total_count
    FROM new_matches nm
    FULL OUTER JOIN d1_matches dm
      ON nm.influencer_id = dm.influencer_id
    WHERE
      (COALESCE(array_length(nm.campaign_ids, 1), 0) > 0
       OR COALESCE(array_length(dm.campaign_ids, 1), 0) > 0)
  )

  -- ──────────────────────────────────────────────────────────
  -- [G] 최종 반환 — [321] ORDER BY 추가(정렬 기준 없어 순서가 매번 달랐던 문제)
  -- ──────────────────────────────────────────────────────────
  SELECT
    t.influencer_id,
    (SELECT u.email FROM auth.users u WHERE u.id = t.influencer_id) AS email,
    COALESCE(
      NULLIF(TRIM(i.name_kanji), ''),
      NULLIF(TRIM(i.name),       ''),
      NULLIF(TRIM(i.name_kana),  ''),
      ''
    ) AS name,
    i.unsubscribe_token,
    t.new_campaign_ids,
    t.deadline_d1_campaign_ids,
    t.new_total_count,
    t.deadline_d1_total_count
  FROM all_targets t
  JOIN public.influencers i ON i.id = t.influencer_id
  ORDER BY t.influencer_id;   -- [321] 안정적인 정렬 — Edge Function 이 매번 앞에서부터
                               --   200명씩 잘라 처리하므로 순서가 고정돼야 재현 가능하다.
$$;

COMMENT ON FUNCTION public.get_promo_digest_targets(date) IS
  '[360, 321 재정의] 캠페인 홍보 메일 대상 인플루언서. 321 과 같고 조건 하나만 더했다 — '
  '탈퇴 절차가 진행 중이거나(pending_payout·scheduled) 끝난(done) 회원을 뺀다. '
  '⚠️ cancelled 는 빼지 않는다 — 탈퇴를 취소하면 다음 발송부터 저절로 대상에 돌아온다. '
  '⚠️ 막는 것은 홍보뿐이다 — 업무 알림과 탈퇴 예정일 안내 메일은 계속 간다.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후 — 전부 읽기 전용)
-- ============================================================
/*

-- [V0] 함수가 실제로 도는가 (자료형·컬럼 오류는 첫 호출에서만 드러난다)
SELECT count(*) AS "오늘_대상자수"
  FROM public.get_promo_digest_targets(CURRENT_DATE);

-- [V1] ★ 탈퇴 신청이 있는 회원이 결과에 없는가
SELECT w.influencer_id, w.status,
       EXISTS (SELECT 1 FROM public.get_promo_digest_targets(CURRENT_DATE) g
                WHERE g.influencer_id = w.influencer_id) AS "대상에_있나"
  FROM public.withdrawal_requests w
 WHERE w.status IN ('pending_payout', 'scheduled', 'done')
 LIMIT 10;
-- 기대: 「대상에_있나」가 전부 false
-- ⚠️ 0행이면 시험할 대상이 없는 것 — 시험 계정으로 탈퇴를 신청한 뒤 다시 볼 것

-- [V2] ★ 취소한 회원은 다시 대상에 들어오는가 (자동 복귀)
SELECT w.influencer_id, w.status,
       EXISTS (SELECT 1 FROM public.get_promo_digest_targets(CURRENT_DATE) g
                WHERE g.influencer_id = w.influencer_id) AS "대상에_있나"
  FROM public.withdrawal_requests w
 WHERE w.status = 'cancelled'
 LIMIT 10;
-- 기대: 마케팅 수신에 동의했고 자격이 맞으면 true (탈퇴 취소가 대상 자격을 뺏지 않는다)

-- [V3] 무회귀 — 탈퇴와 무관한 회원 수가 종전과 같은가
--   321 적용 시점의 대상자 수와 비교. 탈퇴 신청자 수만큼만 줄어야 한다.

*/
