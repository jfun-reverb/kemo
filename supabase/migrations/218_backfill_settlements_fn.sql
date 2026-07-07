-- ============================================================
-- 218_backfill_settlements_fn.sql
-- 인플루언서 정산 관리 PR1 — 2/4 (자동 생성 RPC)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §5, §6(B안 채택)
--
-- backfill_settlements(): 관리자가 정산 화면을 열 때(PR2) 호출하는 "열 때마다 동기화"
--   백필 함수. 결과물 상태가 바뀔 때마다 실행되는 트리거가 아니다(B안, 사양서 §6 권고).
--   판정 로직은 dev/js/admin-deliverables.js 의 computeCertStatus/_finalizeMonitorReprs
--   (결과물 관리 화면과 동일 단일 소스)를 SQL 로 그대로 재현한다:
--
--   - 가구매(monitor + campaigns.proxy_purchase=true): 영수증(receipt) 최신 1건 approved 만 확인.
--   - 리뷰어(monitor 일반): 영수증 최신 1건 approved AND 캠페인 channel(콤마 분리) 의
--     "모든" 채널에 대해 review_image(post_channel=그 채널) 최신 1건이 approved.
--     채널이 0개(NULL/빈 문자열)면 절대 성공 아님(클라 로직과 동일 — 채널 미분류 상태).
--   - 시딩(gifting)·방문(visit): post 최신 1건(채널 무관, 가장 최근 제출) approved.
--
--   대상: applications.status='approved' AND campaigns.reward>0 AND
--         influencers.is_audit=false AND 아직 settlements 행이 없는 응모(멱등, UPSERT).
--
--   PayPal 미등록(paypal_email NULL/빈값)이면 생성과 동시에 notifications 에
--   'settlement_paypal_required' 알림을 인플루언서당 1건(미읽음 중복 방지)으로 남긴다.
--   해당 kind 는 마이그레이션 219 에서 notifications.kind CHECK 에 추가된다 — 이 함수
--   자체는 219 이후에 실제 실행돼야 정상 동작(같은 배치로 순서대로 적용되면 문제 없음).
--
-- 권한: has_permission('settlement.view','read') 게이트. 등록(access_level) 시드는
--   마이그레이션 220. super_admin 은 has_permission() 내부에서 무조건 통과.
--
-- 역방향(인증이 깨지면 pending 정산을 on_hold 로 되돌리는 것)은 PR1 범위 밖 —
--   이 함수는 "생성"만 한다(개발 요청 확정 사항).
--
-- 롤백: 파일 하단 참고.
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
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- 신규 생성분(inserted)을 뒤 이력·알림 INSERT CTE(events_ins/notif_ins)가 재참조한다.
  -- 데이터 변경 CTE는 최종 쿼리가 그 결과를 읽지 않아도 "부수효과용"으로 항상 완전히
  -- 실행된다(PostgreSQL 공식 문서 WITH Queries — Data-Modifying Statements 절: 데이터
  -- 변경 CTE는 그 출력을 상위 쿼리가 전혀 읽지 않아도 부수효과만을 위해 실행 가능).
  -- 별도 TEMP TABLE 없이 단일 문장으로 처리 — 트랜잭션 경계·재실행 안전성 단순화.
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 리워드>0 + 감사용 제외 + 아직 정산행 없음(멱등)
    SELECT
      a.id                                AS application_id,
      a.user_id                           AS influencer_id,
      a.campaign_id                       AS campaign_id,
      c.reward                            AS reward,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase,
      inf.paypal_email                    AS paypal_email
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.status = 'approved'
      AND c.reward > 0
      AND inf.is_audit = false
      AND NOT EXISTS (
        SELECT 1 FROM public.settlements s WHERE s.application_id = a.id
      )
  ),
  receipt_latest AS (
    -- 응모별 영수증(receipt) 최신 1건 상태 (computeCertStatus: g.receipt = 최신 제출)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 응모별 게시물(post) 최신 1건 상태 (gifting/visit — g.result = 최신 제출, 채널 무관)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 응모×채널별 인증샷(review_image) 최신 1건 상태 (monitor 채널별 g.reviewByChannel)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  cert AS (
    SELECT
      cd.application_id,
      cd.influencer_id,
      cd.campaign_id,
      cd.reward,
      cd.paypal_email,
      CASE
        -- 가구매: 영수증 승인만 확인 (리뷰 인증샷 미요구)
        WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
          COALESCE(rl.status = 'approved', false)

        -- 리뷰어 일반: 영수증 승인 AND 캠페인 채널 전부 인증샷 승인
        WHEN cd.recruit_type = 'monitor' THEN
          COALESCE(rl.status = 'approved', false)
          AND EXISTS (
            -- 채널이 최소 1개는 있어야 함(0개면 클라 로직상 절대 'approved' repr 가 안 됨)
            SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
            WHERE btrim(ch.name) <> ''
          )
          AND NOT EXISTS (
            -- 채널 중 하나라도 승인 아님(미제출/검수중/반려)이면 실패
            SELECT 1
            FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
            LEFT JOIN review_channel_latest rcl
              ON rcl.application_id = cd.application_id
             AND rcl.post_channel   = btrim(ch.name)
            WHERE btrim(ch.name) <> ''
              AND COALESCE(rcl.status, 'none') <> 'approved'
          )

        -- 시딩·방문: 게시물 단독 승인
        ELSE
          COALESCE(pl.status = 'approved', false)
      END AS is_success
    FROM candidates cd
    LEFT JOIN receipt_latest rl ON rl.application_id = cd.application_id
    LEFT JOIN post_latest    pl ON pl.application_id = cd.application_id
  ),
  inserted AS (
    INSERT INTO public.settlements (influencer_id, application_id, campaign_id, amount_jpy, paypal_email)
    SELECT influencer_id, application_id, campaign_id, reward, NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행. 최종 SELECT가 이 CTE를
    -- 참조하지 않아도 부수효과(INSERT)를 위해 항상 실행됨(위 함수 상단 설명 참고).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_ins AS (
    -- PayPal 미등록 안내 알림: 인플루언서당 미읽음 1건만(멱등 — 154 패턴과 동일 dedup 방식)
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    SELECT i.influencer_id, 'settlement_paypal_required', 'settlements', i.id,
           'PayPalメールアドレス未登録のお知らせ',
           '報酬のお振込みにはPayPalメールアドレスの登録が必要です。マイページから登録をお願いします。'
    FROM inserted i
    WHERE i.paypal_email IS NULL
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
  '[218] 인증 성공 응모(computeCertStatus==success 서버 재현) → settlements UPSERT 생성. '
  '관리자가 정산 화면 진입 시 호출(트리거 아님, B안). has_permission(''settlement.view'',''read'') 게이트. '
  'PayPal 미등록 인플에게 settlement_paypal_required 알림 동시 발행. 역방향(인증 깨짐→on_hold)은 PR1 범위 밖.';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 219(notifications.kind CHECK 확장)까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'backfill_settlements';

-- [V1] 스모크 호출 (super_admin 또는 campaign_admin 세션으로, SQL Editor 는 postgres role 이라
--   has_permission() 내부 is_super_admin() 경로를 타지 않을 수 있음 — 실제로는 앱에서
--   관리자 로그인 세션으로 호출 권장. SQL Editor 에서 바로 실행 시 auth.uid() 가 NULL 이라
--   permission_denied 로 막힐 수 있음 — 정상 동작.)
SELECT * FROM public.backfill_settlements();

-- [V2] 생성된 정산행 확인
SELECT count(*) FROM public.settlements;
SELECT s.*, a.status AS application_status, c.title, c.reward
FROM public.settlements s
JOIN public.applications a ON a.id = s.application_id
JOIN public.campaigns c ON c.id = s.campaign_id
ORDER BY s.created_at DESC LIMIT 20;

-- [V3] 멱등성 확인 — 같은 함수를 다시 호출해도 created_count=0 이어야 함
SELECT * FROM public.backfill_settlements();

-- [V4] PayPal 미등록 알림 확인
SELECT * FROM public.notifications WHERE kind = 'settlement_paypal_required' ORDER BY created_at DESC LIMIT 20;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.backfill_settlements();
