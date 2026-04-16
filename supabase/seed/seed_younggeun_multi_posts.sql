-- ============================================
-- younggeun.kim@jfun.co.kr — 시딩(gifting/visit) 결과물 복수 URL 더미
-- 개발서버 전용
--
-- 생성:
--   1. 기프팅 승인 application 1건 (없으면 생성, 있으면 재사용)
--   2. 방문형 승인 application 1건 (동일)
--   3. 각 신청에 post 결과물 3종씩 (Instagram/TikTok/YouTube) — 모두 pending
--
-- 롤백:
--   DELETE FROM deliverables WHERE user_id =
--     (SELECT id FROM auth.users WHERE email='younggeun.kim@jfun.co.kr')
--     AND kind='post';
-- ============================================

DO $$
DECLARE
  v_user_id uuid;
  v_gift_camp_id uuid;
  v_visit_camp_id uuid;
  v_app_id uuid;
  v_make_deliverable record;
  v_def_urls jsonb := '[
    {"channel":"instagram", "url":"https://www.instagram.com/p/YOUNG_TEST_IG/"},
    {"channel":"tiktok",    "url":"https://www.tiktok.com/@youngtest/video/1234567890"},
    {"channel":"youtube",   "url":"https://www.youtube.com/watch?v=younggeunTEST"}
  ]'::jsonb;
  v_row jsonb;
BEGIN
  SELECT id INTO v_user_id FROM auth.users WHERE email = 'younggeun.kim@jfun.co.kr';
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'younggeun.kim@jfun.co.kr 없음'; END IF;

  -- 기프팅 + 방문형 테스트 캠페인 선택
  SELECT id INTO v_gift_camp_id FROM campaigns
    WHERE type = 'gifting' AND brand LIKE '[TEST]%'
    ORDER BY created_at DESC LIMIT 1;
  SELECT id INTO v_visit_camp_id FROM campaigns
    WHERE type = 'visit' AND brand LIKE '[TEST]%'
    ORDER BY created_at DESC LIMIT 1;

  -- ───────── 기프팅 신청(없으면 생성) + post 3건 ─────────
  IF v_gift_camp_id IS NOT NULL THEN
    SELECT id INTO v_app_id FROM applications
     WHERE user_id = v_user_id AND campaign_id = v_gift_camp_id LIMIT 1;
    IF v_app_id IS NULL THEN
      INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
      VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근(복수URL 테스트-기프팅)',
              v_gift_camp_id, '더미: 복수 URL 테스트', 'approved', now(), now() - interval '2 day')
      RETURNING id INTO v_app_id;
    ELSE
      UPDATE applications SET status='approved', reviewed_at=now()
       WHERE id = v_app_id AND status <> 'approved';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(v_def_urls) LOOP
      INSERT INTO deliverables (
        application_id, user_id, campaign_id, kind, status,
        post_url, post_channel, post_submissions, submitted_at
      ) VALUES (
        v_app_id, v_user_id, v_gift_camp_id,
        'post', 'pending',
        v_row->>'url',
        v_row->>'channel',
        jsonb_build_array(jsonb_build_object(
          'url', v_row->>'url',
          'channel', v_row->>'channel',
          'submitted_at', (now() - interval '1 hour')::text
        )),
        now() - interval '1 hour'
      )
      ON CONFLICT (application_id, kind, post_url)
        WHERE kind='post' AND post_url IS NOT NULL
        DO NOTHING;
    END LOOP;
  END IF;

  -- ───────── 방문형 신청 + post 3건 ─────────
  IF v_visit_camp_id IS NOT NULL THEN
    SELECT id INTO v_app_id FROM applications
     WHERE user_id = v_user_id AND campaign_id = v_visit_camp_id LIMIT 1;
    IF v_app_id IS NULL THEN
      INSERT INTO applications (user_id, user_email, user_name, campaign_id, message, status, reviewed_at, created_at)
      VALUES (v_user_id, 'younggeun.kim@jfun.co.kr', '영근(복수URL 테스트-방문형)',
              v_visit_camp_id, '더미: 복수 URL 테스트', 'approved', now(), now() - interval '2 day')
      RETURNING id INTO v_app_id;
    ELSE
      UPDATE applications SET status='approved', reviewed_at=now()
       WHERE id = v_app_id AND status <> 'approved';
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(v_def_urls) LOOP
      INSERT INTO deliverables (
        application_id, user_id, campaign_id, kind, status,
        post_url, post_channel, post_submissions, submitted_at
      ) VALUES (
        v_app_id, v_user_id, v_visit_camp_id,
        'post', 'pending',
        REPLACE(v_row->>'url', 'TEST', 'VISIT'),
        v_row->>'channel',
        jsonb_build_array(jsonb_build_object(
          'url', REPLACE(v_row->>'url', 'TEST', 'VISIT'),
          'channel', v_row->>'channel',
          'submitted_at', (now() - interval '30 minute')::text
        )),
        now() - interval '30 minute'
      )
      ON CONFLICT (application_id, kind, post_url)
        WHERE kind='post' AND post_url IS NOT NULL
        DO NOTHING;
    END LOOP;
  END IF;

  RAISE NOTICE '영근 복수 URL 더미 생성 완료 (기프팅 3건 + 방문형 3건)';
END $$;
