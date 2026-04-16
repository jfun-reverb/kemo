-- ============================================
-- younggeun.kim@jfun.co.kr 테스트 더미 데이터
-- 개발서버 전용
--
-- 생성 내용:
--   1. 신청 5건 (상태별: pending / approved×3 / rejected)
--   2. 결과물 (승인 신청 3건에 각각 상태 다르게):
--      - 영수증 pending
--      - 영수증 approved + rejected 재제출 이력
--      - 게시물 URL pending
--
-- 전제:
--   - younggeun.kim@jfun.co.kr 계정이 auth.users + influencers에 이미 존재
--   - 테스트 캠페인 (monitor/gifting/visit) 3건 이상 존재
--
-- 롤백:
--   DELETE FROM deliverables WHERE user_id = (SELECT id FROM auth.users WHERE email='younggeun.kim@jfun.co.kr');
--   DELETE FROM applications WHERE user_id = (SELECT id FROM auth.users WHERE email='younggeun.kim@jfun.co.kr');
-- ============================================

DO $$
DECLARE
  v_user_id uuid;
  v_monitor_camp_id uuid;
  v_gifting_camp_id uuid;
  v_visit_camp_id uuid;

  v_app_pending uuid;
  v_app_approved_recp_pending uuid;
  v_app_approved_recp_approved uuid;
  v_app_approved_post_pending uuid;
  v_app_rejected uuid;

  v_deliv_id uuid;
BEGIN
  -- 유저 조회
  SELECT id INTO v_user_id FROM auth.users WHERE email = 'younggeun.kim@jfun.co.kr';
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'younggeun.kim@jfun.co.kr 계정이 auth.users에 없습니다.';
  END IF;

  -- 타입별 테스트 캠페인 선택 (최신 active 우선)
  SELECT id INTO v_monitor_camp_id FROM campaigns
    WHERE type = 'monitor' ORDER BY
      CASE WHEN status = 'active' THEN 0 ELSE 1 END, created_at DESC LIMIT 1;
  SELECT id INTO v_gifting_camp_id FROM campaigns
    WHERE type = 'gifting' ORDER BY
      CASE WHEN status = 'active' THEN 0 ELSE 1 END, created_at DESC LIMIT 1;
  SELECT id INTO v_visit_camp_id FROM campaigns
    WHERE type = 'visit' ORDER BY
      CASE WHEN status = 'active' THEN 0 ELSE 1 END, created_at DESC LIMIT 1;

  IF v_monitor_camp_id IS NULL THEN
    RAISE EXCEPTION 'monitor 타입 캠페인이 없습니다.';
  END IF;

  -- ── 1. 신청 pending (monitor) ──
  INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, created_at)
  VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근 테스트(심사중)',
          v_monitor_camp_id, '테스트: 심사중 상태', 'pending', now() - interval '1 day')
  RETURNING id INTO v_app_pending;

  -- ── 2. 신청 approved + 영수증 미제출 (monitor) ──
  INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
  VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근 테스트(승인·미제출)',
          COALESCE(v_gifting_camp_id, v_monitor_camp_id), '테스트: 결과물 미제출', 'approved',
          now() - interval '3 day', now() - interval '5 day')
  RETURNING id INTO v_app_approved_recp_pending;

  -- ── 3. 신청 approved + 영수증 pending (monitor) ──
  INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
  VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근 테스트(영수증 검수대기)',
          v_monitor_camp_id, '테스트: 영수증 검수 대기', 'approved',
          now() - interval '4 day', now() - interval '6 day')
  RETURNING id INTO v_app_approved_recp_approved;

  INSERT INTO deliverables (
    application_id, user_id, campaign_id, kind, status,
    receipt_url, purchase_date, purchase_amount, submitted_at
  ) VALUES (
    v_app_approved_recp_approved, v_user_id, v_monitor_camp_id,
    'receipt', 'pending',
    'https://placehold.co/400x600/FF99C8/fff?text=receipt+young',
    current_date - 2, 4800, now() - interval '1 hour'
  );

  -- ── 4. 신청 approved + 게시물 URL pending (gifting) ──
  IF v_gifting_camp_id IS NOT NULL THEN
    INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
    VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근 테스트(게시물 검수대기)',
            v_gifting_camp_id, '테스트: 게시물 URL 검수 대기', 'approved',
            now() - interval '2 day', now() - interval '4 day')
    RETURNING id INTO v_app_approved_post_pending;

    INSERT INTO deliverables (
      application_id, user_id, campaign_id, kind, status,
      post_url, post_channel, post_submissions, submitted_at
    ) VALUES (
      v_app_approved_post_pending, v_user_id, v_gifting_camp_id,
      'post', 'pending',
      'https://www.instagram.com/p/young_test_01/',
      'instagram',
      jsonb_build_array(jsonb_build_object(
        'url', 'https://www.instagram.com/p/young_test_01/',
        'channel', 'instagram',
        'submitted_at', (now() - interval '30 minute')::text
      )),
      now() - interval '30 minute'
    );
  END IF;

  -- ── 5. 신청 rejected (visit 또는 monitor) ──
  INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
  VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근 테스트(비승인)',
          COALESCE(v_visit_camp_id, v_monitor_camp_id),
          '테스트: 비승인 상태', 'rejected',
          now() - interval '1 day', now() - interval '3 day');

  RAISE NOTICE '영근 테스트 더미 데이터 생성 완료';
  RAISE NOTICE '  - 신청 5건 (pending 1, approved 3, rejected 1)';
  RAISE NOTICE '  - 결과물 2건 (영수증 pending, 게시물 pending)';
  RAISE NOTICE '  - 승인·미제출 1건, 비승인 1건';
END $$;
