-- ============================================
-- 개발서버(staging) 전용: deliverables 플로우 검증용 테스트 유저 6명
-- 비밀번호: 모두 test1234, 이메일 확인 완료
-- 주의: 운영서버 실행 금지. Stage 0 (035_create_deliverables) 적용 후 실행
--
-- 사용법:
--   1. 개발서버 SQL Editor에서 실행
--   2. 실행 전 : 아래 TEST_CAMPAIGN_ID를 개발서버의 모집중(monitor 타입) 캠페인 ID로 교체
--   3. 응모이력/활동관리/관리자 신청·결과물 페이지에서 각 상태 확인
--
-- 롤백 (테스트 유저 전량 삭제):
--   DELETE FROM auth.users WHERE email LIKE 'deliv.%@reverb.jp';
--   (cascade로 influencers / applications / receipts / deliverables 함께 삭제)
-- ============================================

DO $$
DECLARE
  v_campaign_id uuid;
  v_user_id uuid;
  v_app_id uuid;
  v_users jsonb := '[
    {"email":"deliv.pending@reverb.jp",   "name":"提出・審査中",   "status":"pending"},
    {"email":"deliv.approved@reverb.jp",  "name":"承認・未提出",   "status":"approved_no_receipt"},
    {"email":"deliv.receipt@reverb.jp",   "name":"領収書提出済み", "status":"receipt_pending"},
    {"email":"deliv.receipt-ok@reverb.jp","name":"領収書承認済み", "status":"receipt_approved"},
    {"email":"deliv.post@reverb.jp",      "name":"投稿URL提出",    "status":"post_pending"},
    {"email":"deliv.rejected@reverb.jp",  "name":"不承認",         "status":"rejected"}
  ]'::jsonb;
  v_user jsonb;
BEGIN
  -- 테스트용 캠페인 1건 선택 (monitor 우선, 없으면 아무 타입)
  SELECT id INTO v_campaign_id
    FROM campaigns
   ORDER BY
     CASE WHEN type = 'monitor' THEN 0 ELSE 1 END,
     CASE WHEN status = 'active' THEN 0 ELSE 1 END,
     created_at DESC
   LIMIT 1;

  IF v_campaign_id IS NULL THEN
    RAISE EXCEPTION '캠페인이 1건도 없습니다. 먼저 관리자 페이지에서 캠페인을 등록하세요.';
  END IF;

  RAISE NOTICE '테스트 캠페인 ID: %', v_campaign_id;

  FOR v_user IN SELECT * FROM jsonb_array_elements(v_users) LOOP
    -- 1) auth.users 생성 (존재 여부 먼저 체크 — auth.users.email엔 unique constraint 없음)
    SELECT id INTO v_user_id FROM auth.users WHERE email = v_user->>'email';

    IF v_user_id IS NULL THEN
      INSERT INTO auth.users (
        instance_id, id, aud, role,
        email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, email_change_token_current,
        phone_change, phone_change_token, recovery_token, reauthentication_token
      )
      VALUES (
        '00000000-0000-0000-0000-000000000000', gen_random_uuid(),
        'authenticated', 'authenticated',
        v_user->>'email',
        crypt('test1234', gen_salt('bf', 10)),
        now(),
        '{"provider":"email","providers":["email"]}'::jsonb,
        jsonb_build_object('email', v_user->>'email', 'email_verified', true),
        now(), now(),
        '', '', '', '', '', '', '', ''
      )
      RETURNING id INTO v_user_id;

      -- auth.identities 대응 행 생성 (로그인 필수)
      INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
      VALUES (
        gen_random_uuid(), v_user_id,
        jsonb_build_object('sub', v_user_id::text, 'email', v_user->>'email', 'email_verified', true),
        'email', v_user_id::text,
        now(), now(), now()
      );
    END IF;

    -- 2) influencers 업데이트 (트리거로 행은 생성되어 있음)
    UPDATE influencers SET
      name = v_user->>'name',
      name_kanji = v_user->>'name',
      name_kana = 'てすと',
      ig = replace(split_part(v_user->>'email', '@', 1), '.', '_'),
      ig_followers = 10000,
      category = 'beauty',
      primary_sns = 'instagram',
      zip = '150-0001', prefecture = '東京都', city = '渋谷区1-1-1',
      phone = '090-0000-0000',
      paypal_email = v_user->>'email',
      terms_agreed_at = now(),
      privacy_agreed_at = now()
    WHERE email = v_user->>'email';

    -- 3) application 생성 (상태에 따라 분기)
    INSERT INTO applications (user_id, campaign_id, message, status, address, created_at)
    VALUES (
      v_user_id, v_campaign_id,
      'テスト応募メッセージ (' || (v_user->>'status') || ')',
      CASE
        WHEN v_user->>'status' = 'pending'       THEN 'pending'
        WHEN v_user->>'status' = 'rejected'      THEN 'rejected'
        ELSE 'approved'
      END,
      '東京都渋谷区1-1-1',
      now() - (random() * interval '7 days')
    )
    RETURNING id INTO v_app_id;

    -- approved 건에 reviewed_by/at 기록
    IF v_user->>'status' <> 'pending' THEN
      UPDATE applications SET reviewed_at = now() - interval '2 days' WHERE id = v_app_id;
    END IF;

    -- 4) 상태별 receipt / deliverable 생성
    IF v_user->>'status' IN ('receipt_pending', 'receipt_approved') THEN
      -- receipts 테이블 INSERT → 트리거가 deliverables에 dual-write
      INSERT INTO receipts (application_id, user_id, campaign_id, receipt_url, purchase_date, purchase_amount, created_at)
      VALUES (
        v_app_id, v_user_id, v_campaign_id,
        'https://placehold.co/600x800?text=receipt',
        current_date - 3, 3200,
        now() - interval '1 day'
      );

      -- receipt_approved: deliverable 상태를 approved로 갱신
      IF v_user->>'status' = 'receipt_approved' THEN
        UPDATE deliverables
           SET status = 'approved', reviewed_at = now(), version = version + 1
         WHERE application_id = v_app_id AND kind = 'receipt';
      END IF;
    END IF;

    IF v_user->>'status' = 'post_pending' THEN
      -- 선행 receipt 승인 + post URL 제출
      INSERT INTO receipts (application_id, user_id, campaign_id, receipt_url, purchase_date, purchase_amount, created_at)
      VALUES (v_app_id, v_user_id, v_campaign_id, 'https://placehold.co/600x800?text=receipt', current_date - 5, 3200, now() - interval '3 days');

      UPDATE deliverables SET status = 'approved', reviewed_at = now() - interval '2 days', version = version + 1
       WHERE application_id = v_app_id AND kind = 'receipt';

      INSERT INTO deliverables (
        application_id, user_id, campaign_id, kind, status,
        post_url, post_channel, post_submissions, submitted_at
      )
      VALUES (
        v_app_id, v_user_id, v_campaign_id, 'post', 'pending',
        'https://www.instagram.com/p/TEST_' || substr(md5(random()::text), 1, 8) || '/',
        'instagram',
        jsonb_build_array(jsonb_build_object(
          'url', 'https://www.instagram.com/p/TEST/',
          'channel', 'instagram',
          'submitted_at', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        )),
        now() - interval '1 hour'
      );
    END IF;
  END LOOP;
END $$;

-- 결과 확인
SELECT
  i.email,
  i.name,
  a.status AS app_status,
  a.reviewed_at IS NOT NULL AS reviewed,
  d_receipt.status AS receipt_status,
  d_post.status AS post_status
FROM influencers i
LEFT JOIN applications a ON a.user_id = i.id
LEFT JOIN deliverables d_receipt ON d_receipt.application_id = a.id AND d_receipt.kind = 'receipt'
LEFT JOIN deliverables d_post    ON d_post.application_id    = a.id AND d_post.kind    = 'post'
WHERE i.email LIKE 'deliv.%@reverb.jp'
ORDER BY i.email;
