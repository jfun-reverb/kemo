-- ============================================================
-- 242_backfill_settlements_notify_gate.sql
-- backfill_settlements() 의 settlement_paypal_required 알림 발송을
-- 인플루언서 공개 스위치로 조건화
--
-- 배경: 마이그레이션 240의 settlement_settings.influencer_visible 이 false(기본,
--   잠금)인 동안에는 관리자가 정산 화면을 열어 backfill_settlements() 를 호출해도
--   PayPal 미등록 인플루언서에게 settlement_paypal_required 알림이 나가면 안 된다.
--   사용자 확정 사항: 이 알림이 막히는 대신, PayPal 미등록 건은 관리자가 사람 경로로
--   직접 요청한다는 전제를 수용함.
--
-- 변경 범위(최소 변경 원칙 — 마이그레이션 231 원문 전체를 그대로 복사한 뒤 두 곳만
--   바꿨다):
--   ① DECLARE 에 v_notify boolean 변수 추가 + 함수 시작부에서
--      v_notify := public.is_settlement_public(); 로 1회 조회
--   ② notif_ins CTE의 WHERE 절에 AND v_notify 조건 한 줄만 추가
--
--   아래는 전부 231 원문 그대로 손대지 않았다:
--   - 권한 게이트(has_permission('settlement.view','read')) — 무변경
--   - 정산 도입일(컷오프) 조회 v_cutoff — 무변경
--   - candidates/receipt_latest/post_latest/review_channel_latest/channel_cert/cert
--     CTE(인증 성공 판정 전체 로직) — 무변경
--   - inserted CTE(멱등 UPSERT, cert_at 완전성 강제, cutoff_at 조건) — 무변경
--   - events_ins CTE(settlement_events 감사 이력 INSERT) — ⚠️무변경, 항상 실행됨
--     (스위치와 무관하게 금전 감사 기록은 계속 남아야 한다)
--   - 반환 시그니처 RETURNS TABLE(created_count integer, paypal_missing_count integer)
--     — 무변경. paypal_missing_count 는 알림을 안 보내도 inserted 중
--     paypal_email IS NULL 인 행을 그대로 count 하므로 스위치 상태와 무관하게
--     계속 정확히 집계된다(관리자 화면이 이 값을 그대로 사용하므로 매우 중요).
--
-- 되돌리는 방법: 마이그레이션 240의 스위치를 true 로 켜면(코드 재배포 없이) 이
--   함수는 자동으로 PayPal 미등록 알림을 다시 발행한다.
--
-- 작성일: 2026-07-20
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
  v_notify          boolean;  -- [242] 인플루언서 공개 스위치(240) — true 일 때만 알림 발송
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read (218 과 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  -- ── [242] 인플루언서 공개 스위치 조회. false(기본)면 아래 notif_ins 가 0건. ──
  v_notify := public.is_settlement_public();

  -- 신규 생성분(inserted)을 뒤 이력·알림 INSERT CTE(events_ins/notif_ins)가 재참조한다.
  -- 데이터 변경 CTE는 최종 쿼리가 그 결과를 읽지 않아도 "부수효과용"으로 항상 완전히
  -- 실행된다(218 과 동일 근거 — PostgreSQL 공식 문서 WITH Queries 절).
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
    -- 응모별 영수증(receipt) 최신 1건 상태+승인시각 (computeCertStatus: g.receipt = 최신 제출)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 응모별 게시물(post) 최신 1건 상태+승인시각 (gifting/visit — g.result = 최신 제출, 채널 무관)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각 (monitor 채널별 g.reviewByChannel)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 리뷰어(monitor 일반) 응모에 한해, 캠페인 채널(콤마 분리) 전체의 인증샷 승인시각
    -- 최댓값 + "그 중 하나라도 reviewed_at 이 비어있는지(any_null)"를 응모 단위로 집계.
    -- any_null 은 cert CTE 에서 GREATEST 의 null-무시 동작을 우회해 완전성을 강제하는 데 쓴다
    -- (전부 승인이어야 성공이므로, 가장 늦은 승인시각이 "그 응모가 실제로 인증 성공 확정된 시점" —
    -- 단, 값이 하나라도 비어있으면 그 시점을 정확히 알 수 없으므로 신뢰하지 않는다).
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
      END AS is_success,

      -- ── 인증 성공일(cert_at) — 판정 종류별 마지막 승인 시각 ──
      -- (완전성 강제: 리뷰어 케이스는 영수증·채널 중 하나라도 reviewed_at 이 비어있으면
      --  GREATEST 의 null-무시 동작으로 대체되지 않도록 명시적으로 NULL 처리한다.)
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
    LEFT JOIN channel_cert   cc  ON cc.application_id = cd.application_id
  ),
  inserted AS (
    INSERT INTO public.settlements (influencer_id, application_id, campaign_id, amount_jpy, paypal_email)
    SELECT influencer_id, application_id, campaign_id, reward, NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외(PR2로 이관)
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외(PR2 수동 처리)
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행 (218 과 동일).
    -- [240] 스위치와 무관하게 항상 남는다 — 금전 감사는 잠금 상태에서도 필수.
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_ins AS (
    -- PayPal 미등록 안내 알림: 인플루언서당 미읽음 1건만(멱등 — 218 과 동일 dedup 방식).
    -- 컷오프 이전 응모는 애초에 inserted 에 안 들어오므로 이 알림도 과거분에는 발송되지
    -- 않는다(사양서 §확정 설계 결정 ⑤ "과거 처리·과거분은 어떤 알림도 발송 안 함").
    -- [242] AND v_notify 조건 추가 — settlement_settings.influencer_visible=false(기본)면
    --   inserted 행이 있어도 이 CTE는 0건 INSERT(안전측 — 코드 변경 없이 240 스위치로 복구).
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
  '[242] 인증 성공 응모(computeCertStatus==success 서버 재현) 중 '
  '"인증 성공일(cert_at, 마지막 필요 결과물의 reviewed_at) >= settlement_settings.cutoff_at" '
  '인 것만 settlements UPSERT 생성. cutoff_at NULL 이면 자동 생성 0건(안전측). '
  'cert_at 이 NULL(레거시 reviewed_at 누락)이거나 컷오프 이전이면 자동 대상에서 제외 '
  '— 과거 미등록 조회·수동 처리는 마이그레이션 232+. '
  '관리자가 정산 화면 진입 시 호출(트리거 아님, B안). has_permission(''settlement.view'',''read'') 게이트. '
  'settlement_events 감사 이력은 항상 INSERT(스위치 무관). PayPal 미등록 인플에게 발행하는 '
  'settlement_paypal_required 알림은 settlement_settings.influencer_visible=true 일 때만 발행 '
  '(마이그레이션 240 스위치, 기본 false=미발송 — paypal_missing_count 반환값은 알림 여부와 무관하게 항상 정확히 집계). '
  '역방향(인증 깨짐→on_hold)은 PR1 범위 밖.';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 240 까지 적용된 뒤에 실행할 것.
--   ⚠️ cutoff_at 을 의도적으로 세팅/해제하며 대조하는 절차이므로, 운영 DB 에서
--      실행할 땐 검증 후 반드시 최종 원하는 값으로 되돌려 놓을 것.
-- ============================================================
/*

-- [V0] 함수 재정의 확인 (반환 타입 동일한지)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'backfill_settlements';

-- [V1] 스위치 잠금(influencer_visible=false, 기본) + cutoff_at 과거 시점 세팅 후 호출
--   — created_count > 0 이어도(정산행은 생성) settlement_paypal_required 알림은 0건이어야 함
BEGIN;
UPDATE public.settlement_settings
  SET cutoff_at = '2020-01-01T00:00:00+09:00'  -- 회귀 확인용 임시값(운영 값 아님)
WHERE id = 1;
SELECT influencer_visible FROM public.settlement_settings;  -- false 확인
SELECT * FROM public.backfill_settlements();
SELECT count(*) FROM public.notifications WHERE kind = 'settlement_paypal_required'
  AND created_at > now() - interval '1 minute';
-- 기대: 위 count = 0 (잠금 상태이므로 알림 미발송, 정산행은 정상 생성)
ROLLBACK;  -- 검증용 UPDATE·INSERT 전부 되돌림

-- [V2] 검증 종료 후 실제 cutoff_at 값 확인(V1 은 ROLLBACK 했으므로 원래 값 그대로 유지됨)
SELECT cutoff_at, influencer_visible FROM public.settlement_settings;

*/

-- ============================================================
-- 롤백용 원본 전문 (마이그레이션 231 — 스위치 조건 없이 항상 알림 발송)
-- ============================================================
/*

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
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  WITH candidates AS (
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
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
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
  cert AS (
    SELECT
      cd.application_id,
      cd.influencer_id,
      cd.campaign_id,
      cd.reward,
      cd.paypal_email,
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
    LEFT JOIN channel_cert   cc  ON cc.application_id = cd.application_id
  ),
  inserted AS (
    INSERT INTO public.settlements (influencer_id, application_id, campaign_id, amount_jpy, paypal_email)
    SELECT influencer_id, application_id, campaign_id, reward, NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL
      AND v_cutoff IS NOT NULL
      AND cert_at >= v_cutoff
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
  '[231-rollback] 알림 게이트(242) 제거, 항상 알림 발송하는 원본 동작으로 복귀.';

GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

NOTIFY pgrst, 'reload schema';

*/
