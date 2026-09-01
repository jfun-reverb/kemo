-- ════════════════════════════════════════════════════════════════════
-- 394 — 응모 취소가 관리자 공지사항에 글을 쓰지 않게 한다
--
-- 무엇을 바꾸나
--   `cancel_application` 안의 「8. admin_notices 즉시 등록」 블록만 걷어낸다.
--   **취소 처리 자체는 한 글자도 안 바뀐다.**
--
-- 왜
--   취소가 일어날 때마다 공지사항에 글이 하나씩 쌓여, 운영 공지 75건 중
--   **64건(85%)이 이 자동 등록물**이 됐다(2026-09-01 실측). 사람이 쓴 공지가
--   그 안에 묻히고, 미읽음 배지와 로그인 팝업이 상시 켜져 있게 된다.
--   🔴 게다가 공지 본문에 **회원 이름·이메일이 복사돼** 들어가는데, 탈퇴 파기
--      함수(352)는 `admin_notices` 를 한 번도 안 건드린다 — 그 회원이 탈퇴해도
--      공지 안 사본은 그대로 남는다. 이 변경은 **더 안 쌓이게** 하고,
--      이미 쌓인 64건은 **395** 가 지운다.
--   사양서 `docs/specs/2026-08-19-cancel-record-move-out-of-notices.md` §3-1
--   인계   `docs/specs/2026-09-01-cancel-notice-stop-handoff.md`
--
-- 🔴 베이스는 356 이다 (309 가 아니다)
--   이 함수를 정의한 파일은 다섯 — 104 → 113 → 306 → 309 → **356**.
--   (이름만 나오는 파일이 13개 더 있어 「가장 큰 번호」로 세면 틀린다.
--    `CREATE ... FUNCTION public.cancel_application` 이 있는 것만 정의다.)
--   309 를 베이스로 다시 쓰면 **356 이 넓힌 본인 검증이 통째로 사라져**
--   관리자 대행 탈퇴가 회원 응모를 하나도 못 철회하는데, 그 실패는 예외로
--   삼켜져 「접수됨 · 철회 못 한 건 N개」로만 뜬다 — 오류도 로그도 안 남는다.
--
-- 356 에서 걷어낸 것
--   ① 본문 「-- 8. admin_notices 즉시 등록」 IF 블록 하나 통째
--   ② 선언부 변수 12개 (v_phase_ko · v_recruit_type_ko · v_reason_label ·
--      v_notice_title · v_notice_body · v_supplement_html · v_campaign_no_esc ·
--      v_campaign_title_esc · v_influencer_name · v_influencer_email ·
--      v_reason_label_esc · v_influencer)
--      + 그 위 「내부 escape 매크로용」 주석 네 줄 (없는 것을 설명하게 된다)
--   ③ 회원 행 조회 한 줄 — v_influencer 는 공지 본문 밖에서 한 번도 안 쓰였다
--      (전수 확인). 그래서 조회도 함께 죽는다.
--
-- ⚠️ 그대로 둔 것 넷 — 하나라도 건드리면 조용히 깨진다
--   · 356 의 본인 검증(탈퇴 통과 표시) — 위 경고
--   · 309 의 notifications INSERT(`-- 7-b.`) — 인플루언서가 받는 유일한 취소
--     통지다. 공지 블록 바로 위에 붙어 있어 같이 지우기 쉽다.
--   · 취소 시점 도출 · 사유·동의 강제 · applications UPDATE
--   · v_campaign 조회 — 취소 시점(cancel_phase) 도출이 쓴다
--
-- ⚠️ 「모집 기간이면 건너뛴다」는 조건은 공지 블록에만 걸려 있었으므로 블록과
--    함께 사라진다. **다른 데로 옮기지 않는다** — 취소 처리에는 원래 그런
--    구분이 없었고, 만들면 없던 동작이 생긴다.
--
-- 🔴 검증은 실제 로그인 브라우저로 — SQL 편집기는 서비스 키라 본인 검증 분기가
--    아예 안 돌아 재현되지 않는다(356 주석의 그 함정).
--    ①취소가 된다 ②인플루언서에게 취소 알림이 온다 ③공지에 새 글이 안 생긴다
--    ④모집 기간 취소도 종전대로 ⑤관리자 대행 탈퇴로 응모가 실제로 철회된다
-- ════════════════════════════════════════════════════════════════════

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
  v_phase           text;
  v_deliv_approved  boolean;

  -- [309] 본인 취소 완료 알림(notifications) 제목
  v_notify_title    text;
BEGIN
  -- 1. 신청 행 잠금 + 본인 검증
  SELECT * INTO v_app
  FROM public.applications
  WHERE id = p_application_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found' USING ERRCODE = '22023';
  END IF;

  -- [356] 본인이거나, **탈퇴 처리 통과 표시가 그 회원을 지목**하고 있으면 통과.
  --   표시는 _withdrawal_cancel_applications() 만 세우고 그 안에서만 살아 있다
  --   (트랜잭션 지역). 값에 **대상 회원 고유번호를 담는 것이 핵심** — 289 처럼
  --   'on' 만 두면 그 트랜잭션 안에서 아무 응모나 취소할 수 있게 된다.
  -- ⚠️ current_setting 의 **두 번째 인자 true**(없으면 오류 대신 NULL)를 빼면
  --   (set_config 는 세 번째가 그 자리다 — 두 함수의 인자 수가 달라 헷갈리기 쉽다)
  --   표시가 없을 때 오류가 나 **본인 취소가 통째로 죽는다**. 이 함수는 2026-05~08
  --   약 3개월간 죽어 있었고 오류 로그에 흔적이 하나도 없었다.
  IF v_app.user_id IS DISTINCT FROM auth.uid()
     AND v_app.user_id::text IS DISTINCT FROM
         COALESCE(current_setting('reverb.withdrawal_actor_uid', true), '') THEN
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

  -- 4. 캠페인 조회 (cancel_phase 도출용)
  --    ⚠️ [394] 회원 행(v_influencer) 조회는 없앴다 — 공지 본문에만 쓰였다.
  --    [306] influencers 는 id 자체가 로그인 계정 식별자다. auth_id 라는 칸은
  --    애초에 존재하지 않는다(113의 원인 결함 수정) — 되살릴 일이 있으면 주의.
  SELECT * INTO v_campaign FROM public.campaigns WHERE id = v_app.campaign_id;

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

  -- 7-b. [마이그레이션 309] 본인 취소 완료 알림(notifications) INSERT
  --   🔴 **지우지 말 것** — 인플루언서가 받는 유일한 취소 통지다.
  --   notifications 표는 INSERT 행 단위 보안 정책이 없어(037 설계 —
  --   SECURITY DEFINER 함수/트리거 전용) 브라우저에서 직접 넣던 시절에는
  --   **한 번도 성공한 적이 없었다**(취소 30건 / 알림 0건). 이 함수는
  --   SECURITY DEFINER 라 그 정책을 우회하므로 여기서 만드는 것이 정답이다.
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

  -- [394] 여기에 있던 「8. admin_notices 즉시 등록」 블록을 없앴다.
  --   앞으로 취소는 관리자 공지사항에 아무것도 쓰지 않는다.
  --   ⚠️ 이 변경 뒤 admin_notices 에 **서버가 자동으로 쓰는 경로는 0** 이다
  --      (전수 확인 — 자동 등록은 이 함수 계열이 유일했다).
  --      공지사항은 이제 **사람이 쓴 것만** 남는다. 의도한 결과다.

  RETURN jsonb_build_object(
    'cancel_phase',    v_phase,
    'cancelled_at',    now(),
    'previous_status', v_app.status
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_application(uuid, text, text, boolean) IS
  '[394, 356 재정의] 회원 본인 응모 취소. 356 과 동일하되 관리자 공지사항(admin_notices) '
  '자동 등록을 없앴다 — 취소마다 공지가 쌓여 운영 공지의 85%를 차지했고, 본문에 복사된 '
  '회원 이름·이메일이 탈퇴 파기(352)에 안 걸려 그대로 남았다. 이미 쌓인 64건은 395 가 지운다. '
  '🔴 본인 검증은 356 그대로 — auth.uid() 이거나 reverb.withdrawal_actor_uid 가 그 회원을 '
  '지목할 때 통과(관리자 대행 탈퇴 경로). current_setting 의 두 번째 인자 true 를 빼면 '
  '본인 취소가 통째로 죽는다. 인플루언서 취소 알림(309)도 그대로 — 브라우저는 그 표에 '
  '넣을 수 없다.';
