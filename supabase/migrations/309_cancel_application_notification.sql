-- ════════════════════════════════════════════════════════════════════
-- migration 309: 본인 응모 취소 완료 알림(notifications) — 서버 INSERT로 이관
-- ────────────────────────────────────────────────────────────────────
-- ── 무엇이 잘못되어 있었나 ─────────────────────────────────────────
--   notifications 표에는 처음부터(마이그레이션 037) INSERT 를 허용하는
--   행 단위 보안 정책(RLS)이 없다. 037 주석에 그 이유가 명시돼 있다:
--
--     -- INSERT는 SECURITY DEFINER 트리거에서만
--
--   그런데 dev/lib/storage.js 의 insertApplicationCancelledNotification()
--   은 사양 §4-10 을 따라 **브라우저에서 db.from('notifications').insert()
--   를 직접** 호출한다. SELECT/UPDATE/DELETE 는 본인 행 한정 정책이
--   있지만 INSERT 정책은 하나도 없으므로(037·044·137 전수 확인,
--   INSERT POLICY 0건), 이 호출은 행 단위 보안 정책의 기본 거부
--   원칙에 걸려 구조적으로 매번 42501 로 실패한다.
--
--   실측 근거(운영 데이터베이스):
--     · applications.status='cancelled' 행 30건 (전부 2026-05, 즉 마이그
--       레이션 306 이 고친 cancel_application 자체 장애 기간과 겹침 —
--       그 기간에도 취소 UPDATE 자체는 이 함수와 무관하게 별도 경로로
--       성공한 기록으로 보인다. 이 마이그레이션은 그 원인 규명이 아니라
--       "알림이 안 만들어진다"는 별개 결함만 다룬다)
--     · kind='application_cancelled' notifications 행 0건
--     · 다른 알림 6종(예: deliverable_approved 881건)은 전부
--       SECURITY DEFINER 트리거/함수가 INSERT — 정상 동작
--
-- ── 재정의 기준 전수 확인 ────────────────────────────────────────────
--   cancel_application 을 정의하는 마이그레이션은 104(원본)·113·306
--   세 곳뿐이다(전 파일 grep 재확인, 306 이후 다른 재정의 없음).
--   306 이 현재까지 가장 최근 정의이므로 306 본문을 한 글자도 바꾸지
--   않고 그대로 베이스로 삼아, "7. UPDATE" 직후·"8. admin_notices 즉시
--   등록" 앞에 알림 INSERT 블록 하나만 추가한다.
--
--   notifications.kind CHECK 제약의 현재 최신 정의는 283(11종,
--   application_cancelled 포함) — 105 이후 정의를 그대로 계승해 왔고
--   283 이 가장 최근이다(전 파일 grep 확인). 이 마이그레이션은 CHECK
--   제약을 건드리지 않는다(이미 포함돼 있으므로 불필요).
--
-- ── 수정 내용 ────────────────────────────────────────────────────────
--   cancel_application() 안에서 UPDATE 직후 notifications 1건을 직접
--   INSERT 한다(SECURITY DEFINER 함수 내부이므로 행 단위 보안 정책을
--   우회 — 037 설계 의도 그대로).
--
--   문구는 지금까지 클라이언트가 만들던 것과 동일하게 맞춘다
--   (dev/lib/storage.js insertApplicationCancelledNotification 원문):
--     title = 캠페인명이 있으면 '応募を取り消しました — {캠페인명}',
--             없으면 '応募を取り消しました'
--     body  = NULL
--   notifications.title 은 렌더 시 esc() 로 이스케이프 후 textContent
--   삽입이라(dev/js/notifications.js:304), admin_notices.body_html 처럼
--   서버 단에서 HTML escape 할 필요가 없다 — 마이그레이션 154 의
--   application_approved 알림과 동일한 패턴(원문 그대로 저장).
--
--   ⚠️ 예외 처리로 감싸지 않는다. 알림 INSERT 가 실패하면 취소 전체가
--   함께 롤백되는 것이 의도된 동작이다 — 다른 알림 6종도 전부 같은
--   트랜잭션 안에서 실패를 감수하고 있고, 지금까지 "알림 실패를
--   조용히 삼키는" 클라이언트 쪽 try/catch 구조가 바로 이번 결함이
--   3개월 넘게 발견되지 않은 원인이었다(dev/lib/storage.js 의
--   insertApplicationCancelledNotification 자체 catch). 서버 함수
--   안에서 실패하면 즉시 예외로 드러나고, 인플루언서 앱 오류 수집
--   경로(마이그레이션 165)에도 정상적으로 잡힌다.
--
-- ── 과거분 소급 생성 안 함 ───────────────────────────────────────────
--   2026-05 취소분 30건에는 알림을 만들지 않는다. 지금 시점에 3개월
--   전 취소 알림이 뜨면 사용자에게 혼란만 준다(개발 세션 판단 —
--   최종 확인은 요청자).
--
-- ── 영향 범위 ─────────────────────────────────────────────────────
--   cancel_application(uuid, text, text, boolean) 함수 재정의 1건뿐.
--   테이블·색인·트리거·행 단위 보안 정책·CHECK 제약 변경 없음.
--   dev/lib/storage.js·dev/js/mypage.js 쪽 정리(브라우저 직접 INSERT
--   호출 제거)는 이 마이그레이션 범위 밖 — 클라이언트 코드는 별도로
--   수정된다.
--
-- ROLLBACK:
--   -- 306 본문으로 CREATE OR REPLACE 복원(= 알림 INSERT 없는 상태로
--   -- 되돌리는 것. 되돌릴 이유가 없으므로 권장하지 않음 — notifications
--   -- 행 자체는 함수가 안 바뀌어도 그대로 남는다).
--   -- 굳이 되돌려야 한다면 306_fix_cancel_application_auth_id_bug.sql
--   -- 의 CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.cancel_application(
  p_application_id  uuid,
  p_reason_code     text DEFAULT NULL,
  p_reason_note     text DEFAULT NULL,
  p_acknowledged    boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_app             public.applications%ROWTYPE;
  v_campaign        public.campaigns%ROWTYPE;
  v_influencer      public.influencers%ROWTYPE;
  v_phase           text;
  v_phase_ko        text;
  v_recruit_type_ko text;
  v_reason_label    text;
  v_deliv_approved  boolean;
  v_notice_title    text;
  v_notice_body     text;
  v_supplement_html text;

  -- [309 신규] 본인 취소 완료 알림(notifications) 제목
  v_notify_title    text;

  -- 내부 escape 매크로용 임시 변수 (replace 체인 가독성 보강)
  -- admin_notices.body_html 는 클라이언트에서 다시 DOMPurify 통과시키지만,
  -- 방어 깊이 차원에서 서버 단에서도 1차 escape — DB값(캠페인/이름/사유)에
  -- 무언가 비정상 텍스트가 섞였을 때 onerror= 등 이벤트 속성 주입 차단.
  v_campaign_no_esc    text;
  v_campaign_title_esc text;
  v_influencer_name    text;
  v_influencer_email   text;
  v_reason_label_esc   text;
BEGIN
  -- 1. 신청 행 잠금 + 본인 검증
  SELECT * INTO v_app
  FROM public.applications
  WHERE id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  IF v_app.user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'not_owner' USING ERRCODE = '42501';
  END IF;

  -- 2. 상태 검증
  IF v_app.status NOT IN ('pending','approved') THEN
    RAISE EXCEPTION 'invalid_status' USING ERRCODE = '22023';
  END IF;

  -- 3. 결과물 1건이라도 승인됐으면 차단
  SELECT EXISTS (
    SELECT 1 FROM public.deliverables
    WHERE application_id = p_application_id AND status = 'approved'
  ) INTO v_deliv_approved;

  IF v_deliv_approved THEN
    RAISE EXCEPTION 'deliverable_already_approved' USING ERRCODE = '22023';
  END IF;

  -- 4. 캠페인 / 인플루언서 조회 (cancel_phase 도출 + admin_notices 본문 빌드)
  --    [마이그레이션 306] influencers 는 id 자체가 로그인 계정 식별자다.
  --    auth_id 라는 칸은 애초에 존재하지 않는다(113의 원인 결함 수정).
  SELECT * INTO v_campaign   FROM public.campaigns   WHERE id = v_app.campaign_id;
  SELECT * INTO v_influencer FROM public.influencers WHERE id = v_app.user_id;

  -- 5. cancel_phase 도출 (104 와 동일 로직 유지)
  v_phase := CASE
    WHEN v_campaign.purchase_start IS NOT NULL
         AND now() >= v_campaign.purchase_start::timestamptz
         AND (v_campaign.purchase_end IS NULL OR now() <= v_campaign.purchase_end::timestamptz) THEN 'purchase'
    WHEN v_campaign.visit_start IS NOT NULL
         AND now() >= v_campaign.visit_start::timestamptz
         AND (v_campaign.visit_end IS NULL OR now() <= v_campaign.visit_end::timestamptz) THEN 'visit'
    WHEN v_campaign.submission_end IS NOT NULL AND now() > v_campaign.submission_end::timestamptz THEN 'post'
    WHEN v_campaign.purchase_end   IS NOT NULL AND now() > v_campaign.purchase_end::timestamptz   THEN 'post'
    WHEN v_campaign.visit_end      IS NOT NULL AND now() > v_campaign.visit_end::timestamptz      THEN 'post'
    WHEN v_campaign.deadline       IS NOT NULL AND now() <= v_campaign.deadline::timestamptz      THEN 'recruit'
    ELSE 'other'
  END;

  -- 6. recruit 외 단계는 사유·동의 필수
  IF v_phase != 'recruit' THEN
    IF NOT COALESCE(p_acknowledged, false) THEN
      RAISE EXCEPTION 'acknowledgement_required' USING ERRCODE = '22023';
    END IF;
    IF p_reason_code IS NULL OR length(trim(p_reason_code)) = 0 THEN
      RAISE EXCEPTION 'reason_required' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 7. UPDATE
  UPDATE public.applications
  SET status             = 'cancelled',
      previous_status    = v_app.status,
      cancelled_at       = now(),
      cancel_reason_code = NULLIF(trim(p_reason_code), ''),
      cancel_reason      = NULLIF(trim(p_reason_note), ''),
      cancel_phase       = v_phase
  WHERE id = p_application_id;

  -- 7-b. [마이그레이션 309 신규] 본인 취소 완료 알림(notifications) INSERT
  --   dev/lib/storage.js 의 insertApplicationCancelledNotification() 이
  --   브라우저에서 직접 시도하던 것과 완전히 동일한 문구·값을 서버에서
  --   대신 만든다. notifications 표는 INSERT 행 단위 보안 정책이 없어
  --   (037 설계 — SECURITY DEFINER 함수/트리거 전용) 클라이언트 직접
  --   INSERT 는 구조적으로 항상 실패했다. 이 함수는 SECURITY DEFINER
  --   라 행 단위 보안 정책을 우회하므로 여기서 만드는 것이 정답이다.
  --   예외로 감싸지 않는다 — 실패 시 취소 전체가 롤백되는 것이 의도.
  v_notify_title := CASE
    WHEN v_campaign.title IS NOT NULL AND length(trim(v_campaign.title)) > 0
      THEN '応募を取り消しました — ' || v_campaign.title
    ELSE '応募を取り消しました'
  END;

  INSERT INTO public.notifications (
    user_id, kind, ref_table, ref_id, title, body
  ) VALUES (
    v_app.user_id, 'application_cancelled', 'applications', p_application_id,
    v_notify_title, NULL
  );

  -- 8. admin_notices 즉시 등록 (recruit 외 단계만 — 모집기간 취소 노이즈 차단)
  IF v_phase != 'recruit' THEN
    v_phase_ko := CASE v_phase
      WHEN 'purchase' THEN '구매기간'
      WHEN 'visit'    THEN '방문기간'
      WHEN 'post'     THEN '결과물 제출기간'
      ELSE '기타'
    END;

    v_recruit_type_ko := CASE COALESCE(v_campaign.recruit_type, '')
      WHEN 'monitor' THEN '리뷰어'
      WHEN 'gifting' THEN '기프팅'
      WHEN 'visit'   THEN '방문형'
      ELSE COALESCE(v_campaign.recruit_type, '-')
    END;

    SELECT name_ko INTO v_reason_label
    FROM public.lookup_values
    WHERE kind = 'cancel_reason'
      AND code = NULLIF(trim(p_reason_code), '')
    LIMIT 1;
    v_reason_label := COALESCE(v_reason_label, '-');

    -- HTML escape — DB 값(캠페인/이름/이메일/사유)도 일관되게 1차 처리.
    -- 줄바꿈 변환은 보충(reason_note) 만 적용 — title/name 등은 한 줄 텍스트.
    v_campaign_no_esc :=
      replace(replace(replace(COALESCE(v_campaign.campaign_no, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_campaign_title_esc :=
      replace(replace(replace(COALESCE(v_campaign.title, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_influencer_name :=
      replace(replace(replace(COALESCE(v_influencer.name, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_influencer_email :=
      replace(replace(replace(COALESCE(v_influencer.email, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
    v_reason_label_esc :=
      replace(replace(replace(v_reason_label, '&', '&amp;'), '<', '&lt;'), '>', '&gt;');

    v_notice_title := '응모 취소 — '
      || COALESCE(v_campaign.title, '캠페인')
      || ' / '
      || COALESCE(v_influencer.name, '인플루언서');

    -- 보충 텍스트: 자유 입력이라 줄바꿈도 보존.
    IF p_reason_note IS NOT NULL AND length(trim(p_reason_note)) > 0 THEN
      v_supplement_html :=
        '<p><b>보충:</b> '
        || replace(
             replace(
               replace(
                 replace(trim(p_reason_note), '&', '&amp;'),
                 '<', '&lt;'),
               '>', '&gt;'),
             E'\n', '<br>')
        || '</p>';
    ELSE
      v_supplement_html := '';
    END IF;

    v_notice_body :=
      '<div>'
      || '<p><b>캠페인:</b> ['
        || v_campaign_no_esc
        || '] '
        || v_campaign_title_esc
        || ' (' || v_recruit_type_ko || ')</p>'
      || '<p><b>인플루언서:</b> '
        || v_influencer_name
        || ' · '
        || v_influencer_email
        || '</p>'
      || '<p><b>취소 일시:</b> '
        || to_char((now() AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI')
        || ' KST</p>'
      || '<p><b>시점:</b> ' || v_phase_ko || '</p>'
      || '<p><b>사유:</b> ' || v_reason_label_esc || '</p>'
      || v_supplement_html
      || '</div>';

    INSERT INTO public.admin_notices (
      title, body_html, category,
      created_by, created_by_name,
      status, published_at, published_by, published_by_name
    ) VALUES (
      v_notice_title, v_notice_body, 'warning',
      NULL, 'system',
      'published', now(), NULL, 'system'
    );
  END IF;

  RETURN jsonb_build_object(
    'cancel_phase',    v_phase,
    'cancelled_at',    now(),
    'previous_status', v_app.status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_application(uuid, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.cancel_application(uuid, text, text, boolean) IS
  '캠페인 신청 본인 취소. 사양 §2-4 + §6. '
  '본인 검증 + 결과물 승인 차단 + cancel_phase 도출 + 사유·동의 강제 + UPDATE. '
  'migration 113 에서 recruit 외 단계 admin_notices 자동 등록 추가. '
  'migration 306 에서 influencers 조회 컬럼 오류(auth_id → id) 수정. '
  'migration 309 에서 본인 취소 완료 알림(notifications, kind=application_cancelled) '
  'INSERT 를 서버로 이관 — notifications 표에는 INSERT 행 단위 보안 정책이 없어 '
  '클라이언트 직접 INSERT 가 구조적으로 항상 실패하던 결함 수정.';

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 검증 (마이그레이션 실행 후 SQL 편집기에서 확인용 — 1단계씩 순서대로
-- 결과를 확인하며 진행할 것. 한 번에 다 실행하지 말 것)
-- ════════════════════════════════════════════════════════════════════
--
-- 1) 함수 정의에 notifications INSERT 블록이 들어갔는지 확인
-- SELECT pg_get_functiondef('public.cancel_application(uuid,text,text,boolean)'::regprocedure);
--   → 본문에 "INSERT INTO public.notifications" 와
--     "kind => application_cancelled" 문자열(정확히는
--     "'application_cancelled'")이 있어야 한다.
--
-- 2) 실제로 취소 + 알림 생성이 함께 되는지 (개발 데이터베이스, 테스트
--    계정 — 반드시 본인 소유 응모로 테스트. RLS 상 auth.uid() 로 본인
--    검증하므로 로그인한 그 계정의 응모 id 를 넣어야 함. service_role/
--    SQL 편집기는 로그인 세션이 없어 not_owner(42501)로 막히니, 이
--    검증은 브라우저 로그인 상태에서 앱 화면으로 직접 눌러보는 것을
--    권장)
--
--    화면 검증 순서:
--    ① 테스트 인플루언서로 로그인 → 임의 캠페인에 응모(pending 상태)
--    ② 마이페이지 → 응모이력에서 그 응모 「取消」(모집기간 중이면
--       사유 입력 없이 바로 처리되는 간단 모드)
--    ③ 「取消しました」류 성공 토스트가 뜨는지, 응모이력이 取消 탭으로
--       이동하고 상태가 取消済み 로 바뀌는지 확인
--    ④ 햄버거 메뉴 알림 벨에 미읽음 배지가 뜨는지, 알림 모달을 열어
--       「応募を取り消しました — {캠페인명}」 항목이 보이는지 확인
--
-- 3) SQL 로 결과 재확인 (위 ①②에서 사용한 응모 id 로)
-- SELECT n.id, n.kind, n.title, n.body, n.ref_table, n.ref_id, n.read_at, n.created_at
--   FROM public.notifications n
--  WHERE n.ref_table = 'applications'
--    AND n.ref_id    = '<취소한 응모 id>'
--    AND n.kind      = 'application_cancelled';
--   → 1행이 나와야 하고, title 이 캠페인명을 포함한
--     "応募を取り消しました — {캠페인명}" 형태여야 한다(캠페인명을
--     못 찾는 예외적 경우만 "応募を取り消しました" 단독).
--
-- 4) applications 쪽도 정상 갱신됐는지 (306 검증과 동일)
-- SELECT id, status, previous_status, cancelled_at, cancel_phase, cancel_reason_code
--   FROM public.applications
--  WHERE id = '<취소한 응모 id>';
--   → status='cancelled', cancelled_at 이 now() 근처여야 한다.
--
-- 5) (참고용, 선택) 과거 취소 30건에는 알림이 없다는 사실 확인 —
--    이 마이그레이션이 과거분을 소급 생성하지 않았음을 재확인
-- SELECT COUNT(*) AS cancelled_apps_total
--   FROM public.applications WHERE status = 'cancelled';
-- SELECT COUNT(*) AS cancel_notifications_total
--   FROM public.notifications WHERE kind = 'application_cancelled';
--   → 두 번째 값이 마이그레이션 적용 이전 취소 건수만큼 적어야 정상
--     (적용 이후 새로 취소한 건수만큼만 늘어남).
-- ════════════════════════════════════════════════════════════════════
