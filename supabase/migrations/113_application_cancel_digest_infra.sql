-- ════════════════════════════════════════════════════════════════════
-- migration 113: 응모 취소 — 사이드바 즉시 공지 + 일일 요약 발송 로그
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-11-application-cancel.md §6 (2026-05-12 재작성)
--       docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md §7
--
-- 변경:
--   1. cancel_application RPC 본체에 admin_notices INSERT 로직 추가
--      (cancel_phase != 'recruit' 만) — 운영자는 사이드바 「공지사항」 에서
--      즉시 인지 가능.
--   2. application_cancel_digest_runs 테이블 신규 — 일일 요약 메일
--      발송 로그. digest_date UNIQUE 로 cron 중복 호출 차단.
--   3. applications(cancelled_at) 부분 인덱스 — 일일 윈도우 스캔 성능.
--
-- 이메일은 별도 Edge Function notify-application-cancelled-daily 가
-- pg_cron 호출로 매일 한국시간 오전 9시 실행. 본 마이그레이션 자체는
-- pg_cron schedule 등록을 포함하지 않음(환경별 secrets 의존 — HANDOFF
-- 별도 안내).
--
-- ROLLBACK:
--   DROP INDEX IF EXISTS public.idx_applications_cancelled_at;
--   DROP TABLE IF EXISTS public.application_cancel_digest_runs;
--   -- cancel_application 은 104 본문으로 CREATE OR REPLACE 복원
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 1. cancel_application RPC 재정의 (admin_notices INSERT 추가) ──
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
  SELECT * INTO v_campaign   FROM public.campaigns   WHERE id      = v_app.campaign_id;
  SELECT * INTO v_influencer FROM public.influencers WHERE auth_id = v_app.user_id;

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
  'migration 113 에서 recruit 외 단계 admin_notices 자동 등록 추가.';


-- ── 2. application_cancel_digest_runs (발송 로그 테이블) ──
CREATE TABLE IF NOT EXISTS public.application_cancel_digest_runs (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  digest_date       date NOT NULL,                                     -- 다이제스트 대상일 (KST 전일)
  ran_at            timestamptz NOT NULL DEFAULT now(),                -- 실제 발송 시각
  status            text NOT NULL CHECK (status IN ('sent','skipped_no_data','failed')),
  recipients_count  integer NOT NULL DEFAULT 0,                        -- 수신자 수 (관리자 + env)
  cancelled_count   integer NOT NULL DEFAULT 0,                        -- 윈도우 내 취소 건수
  error_message     text,                                              -- failed 시 외부 오류 메시지
  CONSTRAINT application_cancel_digest_runs_date_uniq UNIQUE (digest_date)
);

COMMENT ON TABLE public.application_cancel_digest_runs IS
  '응모 취소 일일 요약 메일 발송 로그. digest_date UNIQUE 로 cron 중복 호출 차단.';
COMMENT ON COLUMN public.application_cancel_digest_runs.status IS
  'sent: 정상 발송 / skipped_no_data: 윈도우 내 대상 0건 / failed: Brevo 등 외부 오류';

ALTER TABLE public.application_cancel_digest_runs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "application_cancel_digest_runs_select_super"
  ON public.application_cancel_digest_runs;
CREATE POLICY "application_cancel_digest_runs_select_super"
  ON public.application_cancel_digest_runs
  FOR SELECT TO authenticated
  USING (public.is_super_admin());

-- INSERT/UPDATE/DELETE policy 미정의 → authenticated 는 deny.
-- Edge Function 은 service_role 키로 BYPASSRLS — policy 무관하게 쓰기 가능.


-- ── 3. 일일 윈도우 스캔용 부분 인덱스 ──
CREATE INDEX IF NOT EXISTS idx_applications_cancelled_at
  ON public.applications (cancelled_at)
  WHERE status = 'cancelled'
    AND cancel_phase IS NOT NULL
    AND cancel_phase <> 'recruit';

COMMENT ON INDEX public.idx_applications_cancelled_at IS
  '일일 요약 메일의 윈도우 스캔용. recruit 단계 취소는 인덱스 제외(스캔 대상 아님).';

COMMIT;
