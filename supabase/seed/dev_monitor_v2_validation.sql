-- ============================================================
-- dev_monitor_v2_validation.sql
-- monitor 결과물 2단계화 검증용 더미 데이터 (개발서버 전용)
--
-- 적용 대상: 개발서버 (qysmxtipobomefudyixw)
-- 운영서버 적용 금지
--
-- 멱등성: 반복 실행해도 동일 데이터 유지 (이미 있으면 SKIP)
-- 정리: 하단 「ROLLBACK 스니펫」 참고
--
-- 시나리오 구성 (한 캠페인 + 3가지 영수증 상태):
--   A. sakura  — 신청 승인, 영수증 0건            → STEP 1 폼 노출 + STEP 2 안내문
--   B. yui     — 신청 승인, 영수증 검수중(pending) → STEP 1 검수중 배지 + STEP 2 안내문
--   C. haruka  — 신청 승인, 영수증 승인(approved)  → STEP 2 본문 펼쳐짐 + 캡쳐 폼
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_brand_id      uuid;
  v_admin_id      uuid;
  v_campaign_id   uuid;
  v_sakura_id     uuid;
  v_yui_id        uuid;
  v_haruka_id     uuid;
  v_app_sakura    uuid;
  v_app_yui       uuid;
  v_app_haruka    uuid;
  v_test_image    text := 'https://placehold.co/600x800/EEE/333?text=Test+Receipt';
  v_brand_name    text := '【検証】モニター2段階';
  v_camp_title    text := '【検証】モニター2段階 検証用キャンペーン';
BEGIN
  -- 0. 관리자 ID (reviewed_by 용)
  SELECT auth_id INTO v_admin_id FROM public.admins WHERE email = 'admin@kemo.jp' LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION '관리자 admin@kemo.jp가 존재하지 않습니다. 관리자 시드 먼저 실행 필요.';
  END IF;

  -- 0. 테스트 인플루언서 ID
  SELECT id INTO v_sakura_id FROM auth.users WHERE email = 'sakura.test@reverb.jp' LIMIT 1;
  SELECT id INTO v_yui_id    FROM auth.users WHERE email = 'yui.test@reverb.jp'    LIMIT 1;
  SELECT id INTO v_haruka_id FROM auth.users WHERE email = 'haruka.test@reverb.jp' LIMIT 1;
  IF v_sakura_id IS NULL OR v_yui_id IS NULL OR v_haruka_id IS NULL THEN
    RAISE EXCEPTION '테스트 인플루언서 누락 (sakura/yui/haruka). test_influencers_staging.sql 시드 먼저 실행 필요.';
  END IF;

  -- 1. 테스트용 brand (멱등 — name 기준)
  SELECT id INTO v_brand_id FROM public.brands WHERE name = v_brand_name LIMIT 1;
  IF v_brand_id IS NULL THEN
    INSERT INTO public.brands (name, status, created_by)
    VALUES (v_brand_name, 'active', v_admin_id)
    RETURNING id INTO v_brand_id;
    RAISE NOTICE '[brand] 신규 생성: %', v_brand_id;
  ELSE
    RAISE NOTICE '[brand] 기존 사용: %', v_brand_id;
  END IF;

  -- 2. 테스트용 monitor 캠페인 (멱등 — title + brand_id 기준)
  SELECT id INTO v_campaign_id FROM public.campaigns
   WHERE title = v_camp_title AND brand_id = v_brand_id LIMIT 1;
  IF v_campaign_id IS NULL THEN
    INSERT INTO public.campaigns (
      brand_id, brand, product, title,
      status, recruit_type, channel, channel_match,
      slots, min_followers,
      recruit_start, deadline, post_deadline,
      purchase_start, purchase_end, submission_end,
      img1, view_count,
      caution_items, participation_steps
    ) VALUES (
      v_brand_id,
      v_brand_name,
      'モニター2段階 検証用ダミー商品',
      v_camp_title,
      'active', 'monitor', 'instagram', 'or',
      10, 0,
      CURRENT_DATE,
      CURRENT_DATE + INTERVAL '14 days',
      CURRENT_DATE + INTERVAL '21 days',
      CURRENT_DATE,
      CURRENT_DATE + INTERVAL '7 days',
      CURRENT_DATE + INTERVAL '28 days',
      v_test_image, 0,
      '[]'::jsonb, '[]'::jsonb
    ) RETURNING id INTO v_campaign_id;
    RAISE NOTICE '[campaign] 신규 생성: %', v_campaign_id;
  ELSE
    RAISE NOTICE '[campaign] 기존 사용: %', v_campaign_id;
  END IF;

  -- 3. 시나리오 A: sakura — approved, 영수증 0건
  SELECT id INTO v_app_sakura FROM public.applications
   WHERE user_id = v_sakura_id AND campaign_id = v_campaign_id LIMIT 1;
  IF v_app_sakura IS NULL THEN
    INSERT INTO public.applications (
      user_id, campaign_id, message, status, reviewed_by, reviewed_at
    ) VALUES (
      v_sakura_id, v_campaign_id,
      '[검증 A] 영수증 0건 — STEP 1 폼 노출 + STEP 2 gated 안내 확인',
      'approved', v_admin_id, now()
    ) RETURNING id INTO v_app_sakura;
    RAISE NOTICE '[A] sakura application: %', v_app_sakura;
  END IF;

  -- 4. 시나리오 B: yui — approved, 영수증 pending
  SELECT id INTO v_app_yui FROM public.applications
   WHERE user_id = v_yui_id AND campaign_id = v_campaign_id LIMIT 1;
  IF v_app_yui IS NULL THEN
    INSERT INTO public.applications (
      user_id, campaign_id, message, status, reviewed_by, reviewed_at
    ) VALUES (
      v_yui_id, v_campaign_id,
      '[검증 B] 영수증 검수중 — STEP 1 검수중 배지 + STEP 2 gated 안내 확인',
      'approved', v_admin_id, now()
    ) RETURNING id INTO v_app_yui;

    INSERT INTO public.deliverables (
      application_id, user_id, campaign_id, kind, status, receipt_url, submitted_at
    ) VALUES (
      v_app_yui, v_yui_id, v_campaign_id, 'receipt', 'pending', v_test_image, now()
    );
    RAISE NOTICE '[B] yui application + pending receipt: %', v_app_yui;
  END IF;

  -- 5. 시나리오 C: haruka — approved, 영수증 approved (STEP 2 본문 활성화)
  SELECT id INTO v_app_haruka FROM public.applications
   WHERE user_id = v_haruka_id AND campaign_id = v_campaign_id LIMIT 1;
  IF v_app_haruka IS NULL THEN
    INSERT INTO public.applications (
      user_id, campaign_id, message, status, reviewed_by, reviewed_at
    ) VALUES (
      v_haruka_id, v_campaign_id,
      '[검증 C] 영수증 승인 — STEP 2 본문 펼쳐짐 + 리뷰 캡쳐 폼 활성화',
      'approved', v_admin_id, now()
    ) RETURNING id INTO v_app_haruka;

    INSERT INTO public.deliverables (
      application_id, user_id, campaign_id, kind, status, receipt_url,
      submitted_at, reviewed_at, reviewed_by
    ) VALUES (
      v_app_haruka, v_haruka_id, v_campaign_id, 'receipt', 'approved', v_test_image,
      now() - INTERVAL '1 day', now(), v_admin_id
    );
    RAISE NOTICE '[C] haruka application + approved receipt: %', v_app_haruka;
  END IF;

  RAISE NOTICE '=== monitor 2단계 검증 데이터 준비 완료 ===';
  RAISE NOTICE 'campaign_id : %', v_campaign_id;
  RAISE NOTICE '인플루언서 로그인 : sakura.test@reverb.jp / yui.test@reverb.jp / haruka.test@reverb.jp (비밀번호 test1234)';
  RAISE NOTICE '관리자 화면     : 캠페인 관리 → "모니터2段階 検証用キャンペーン" → 신청자';
END $$;

COMMIT;

-- ============================================================
-- 검증 쿼리 (적용 후 실행 — 시나리오별 행 3개 출력)
-- ============================================================
SELECT
  CASE i.email
    WHEN 'sakura.test@reverb.jp' THEN '검증 A (영수증 0건)'
    WHEN 'yui.test@reverb.jp'    THEN '검증 B (영수증 pending)'
    WHEN 'haruka.test@reverb.jp' THEN '검증 C (영수증 approved)'
    ELSE '기타'
  END                          AS scenario,
  i.email,
  a.status                     AS application_status,
  d.kind                       AS deliverable_kind,
  d.status                     AS deliverable_status,
  d.submitted_at
FROM public.applications a
JOIN public.campaigns c ON c.id = a.campaign_id
JOIN auth.users i       ON i.id = a.user_id
LEFT JOIN public.deliverables d ON d.application_id = a.id
WHERE c.title = '【検証】モニター2段階 検証用キャンペーン'
ORDER BY i.email, d.kind;

-- ============================================================
-- ROLLBACK 스니펫 (검증 종료 후 정리하고 싶을 때만 별도 실행)
-- ============================================================
-- DO $$
-- DECLARE
--   v_camp uuid;
-- BEGIN
--   SELECT id INTO v_camp FROM public.campaigns
--    WHERE title = '【検証】モニター2段階 検証用キャンペーン' LIMIT 1;
--   IF v_camp IS NOT NULL THEN
--     DELETE FROM public.deliverables   WHERE campaign_id = v_camp;
--     DELETE FROM public.applications   WHERE campaign_id = v_camp;
--     DELETE FROM public.campaigns      WHERE id = v_camp;
--     -- brand는 다른 캠페인이 참조 중이면 삭제 보류
--     DELETE FROM public.brands
--      WHERE name = '【検証】モニター2段階'
--        AND NOT EXISTS (SELECT 1 FROM public.campaigns WHERE brand_id = brands.id);
--   END IF;
-- END $$;
