-- ============================================================
-- 356_withdrawal_proxy_foundation.sql
--
-- 회원 탈퇴 — 작업 19 「관리자 대행 탈퇴 신청」 2/3 (토대)
--   355 = 권한 시드 (순서 무관)
--   357 = 본체(대행 신청·관리자 되돌리기) — **반드시 이 파일 뒤에**
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 19」
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md §5 ⑤
--
-- ============================================================
-- ① 이 파일만 적용하면 동작이 바뀌나 — **사실상 안 바뀐다**
-- ============================================================
--   [A] 값 확장  — 새 값을 쓰는 곳이 아직 0곳
--   [B] 겸직 판정 헬퍼 — 신설(부르는 곳은 [F] 하나)
--   [C] 응모 철회 헬퍼 — 신설(부르는 곳은 357)
--   [D] cancel_application — 통과 표시를 **세우는 곳이 아직 0곳**이라 종전과 동일
--   [E] cancel_withdrawal  — 거부 대상 값('admin')을 가진 행이 0건이라 종전과 동일
--   [F] get_withdrawal_precheck — 겸직 회원에게만 답이 달라진다
--
--   → 되돌릴 일이 생겨도 **357 만 되돌리면** 된다. 그래서 여기서 끊었다.
--
-- ============================================================
-- ② ★ 가장 위험한 것 — [D] cancel_application 재정의
-- ============================================================
--   이 플랫폼에서 가장 예민한 공유 함수다. **2026-05-12 ~ 08-06 약 3개월간 죽어
--   있었고 오류 수집망을 두 겹 다 빠져나가 로그에 흔적이 하나도 없었다**
--   (마이그레이션 306 이 고침). 화면이 실패를 일반 문구로 덮기 때문에, 여기서
--   실수하면 **아무도 모르는 채로 회원의 응모 취소가 다시 죽는다.**
--
--   그래서 이 파일은 309 원본을 **스크립트로 통째 추출해 한 곳만 치환**했다.
--   손으로 220줄을 옮기는 방식은 쓰지 않았다.
--
--   🔴 **적용 직후 반드시 — 시험 인플루언서 계정 브라우저에서 「본인 응모 취소」를
--     실제로 눌러 볼 것.** 이게 통과하기 전에는 357 을 적용하지 않는다.
--
-- ============================================================
-- ③ 통과 표시가 왜 필요한가
-- ============================================================
--   cancel_application(309)은 **부르는 사람이 그 응모의 주인이 아니면 거부**한다
--   (`not_owner`). 그래서 관리자가 대행으로 부르면 **모든 응모에서 실패**하는데,
--   탈퇴 신청 함수의 철회 반복문은 이유를 가리지 않고 삼켜 「철회 못 한 건」으로만
--   센다 → **응모를 하나도 못 지운 채 조용히 성공**하고 원인을 알 수 없다.
--
--   해법은 행사 예약이 이미 쓰는 방식(`reverb.event_ticket_bypass`, 289)과 같다.
--   다만 **표시 값에 대상 회원 고유번호를 담는다** — 289 처럼 'on' 만 두면
--   「그 트랜잭션 안에서는 아무 응모나 취소 가능」이 되지만, 고유번호를 담으면
--   **그 회원 응모만** 통과한다.
--
--   ⚠️ 표시를 세우는 곳은 [C] 헬퍼 **하나뿐**이고, 그 함수는 아무에게도 실행
--     권한을 주지 않는다. 밖에서 이 표시를 세울 방법이 없다.
--
-- ============================================================
-- ④ 값 이름을 셋으로 나눈 이유 ('admin' 을 재활용하지 않았다)
-- ============================================================
--   사양서 §5 ⑤ 가 정의한 'admin' 은 **자격 상실에 의한 강제 탈퇴**(약관 제6조
--   3항)이고, 349 가 그 값을 「본인이 취소 못 함」으로 해석해 막고 있다.
--   이번에 필요한 것은 **회원이 요청해서 관리자가 대신 눌러 주는 것**이라 성격이
--   정반대다(본인이 취소할 수 있어야 한다).
--   → 같은 낱말에 반대 뜻을 얹으면 349 가 **있는 그대로 정반대로 동작**한다.
--     운영 데이터가 0건이라 이름을 나누는 비용이 없다.
--
--   self         — 본인이 신청
--   admin_proxy  — 관리자 대행(회원이 요청). **본인이 취소할 수 있다**
--   admin_forced — 관리자 강제(자격 상실). 본인이 취소할 수 없다
--
--   ⚠️ **강제(admin_forced)는 값만 만들고 이번에 열지 않는다**(2026-08-19 결정).
--     되돌릴 수단이 없는 처리를 약관 개정 전에 여는 것이 되기 때문이다. 357 의
--     대행 함수는 두 값을 다 받지만 화면은 대행만 보낸다.
--
-- ============================================================
-- ⑤ 352(파기 함수)는 손대지 않았다 — 의도적 판단
-- ============================================================
--   352 도 같은 겸직 판정을 인라인으로 갖고 있어 [B] 헬퍼로 바꾸는 것이 「같은
--   판단은 한 곳에」 원칙에 맞다. 그런데 그 함수는 120줄이고 **결과가 완전히
--   동일**하다 — 이번 기능에 필요하지 않은데 되돌릴 수 없는 파기 함수를 통째로
--   복사하는 위험이 더 크다고 판단했다.
--   → **352 를 다음에 손댈 때 [B] 헬퍼 호출로 교체할 것.** 그때까지 같은 판정이
--     두 곳에 있다(둘 다 `admins.auth_id` 존재 확인 한 줄이라 갈릴 여지는 작다).
--
-- ============================================================
-- ⑥ 되돌리기
-- ============================================================
--   [D]·[E]·[F] 는 각각 309·349·353 파일의 함수 블록을 그대로 다시 실행하면
--   되돌아간다. [A] 는 CHECK 를 ('self','admin') 으로 되돌린다(새 값 행이 있으면
--   먼저 지워야 한다). [B]·[C] 는 DROP FUNCTION.
--   ⚠️ **357 을 먼저 되돌린 뒤에 할 것.**
-- ============================================================

-- 🔴 적용 전 필수 확인 — 옛 값('admin') 행이 남아 있으면 [A] 가 실패한다.
--   349 의 검증 절차 [V6] 가 개발 데이터베이스에 그런 행을 일부러 넣어 봤다.
--   실패하면 아래 메시지가 뜨니, 그 행을 지우고 다시 실행할 것.
DO $$
DECLARE v_cnt integer;
BEGIN
  SELECT count(*) INTO v_cnt
    FROM public.withdrawal_requests
   WHERE requested_by_kind = 'admin';
  IF v_cnt > 0 THEN
    RAISE EXCEPTION
      '[356] requested_by_kind = ''admin'' 인 행이 %건 남아 있습니다. 349 검증에서 넣어 본 시험 행이라면 지운 뒤 다시 실행하세요: DELETE FROM public.withdrawal_requests WHERE requested_by_kind = ''admin'';',
      v_cnt;
  END IF;
END $$;

BEGIN;

-- ============================================================
-- [A] requested_by_kind 를 셋으로 확장
--
--   ⚠️ 제약 이름을 글자로 적지 않고 **찾아서** 지운다 — 345 가 인라인 CHECK 로
--     선언해 이름이 자동 생성됐고, 그 이름을 추측해 적으면 `IF EXISTS` 가 조용히
--     통과해 옛 제약이 그대로 남는다. 마이그레이션 104 가 정확히 그 방식으로
--     실패해 「취소 후 재응모」가 플랫폼 전체에서 한 번도 동작하지 않았다(305 가
--     고침). 같은 실수를 반복하지 않는다.
-- ============================================================
DO $$
DECLARE v_name text;
BEGIN
  SELECT con.conname INTO v_name
    FROM pg_constraint con
    JOIN pg_class     rel ON rel.oid = con.conrelid
    JOIN pg_namespace ns  ON ns.oid  = rel.relnamespace
   WHERE ns.nspname  = 'public'
     AND rel.relname = 'withdrawal_requests'
     AND con.contype = 'c'
     AND pg_get_constraintdef(con.oid) LIKE '%requested_by_kind%';

  -- ⚠️ 이 조회는 여러 행이 나와도 **오류 없이 첫 행만** 쓴다. 345 를 읽어 이 열을
  --   언급하는 CHECK 가 하나뿐임을 확인했지만, 나중에 같은 열에 제약이 더 생기면
  --   하나만 지우고 나머지를 조용히 남긴다.
  IF v_name IS NULL THEN
    RAISE EXCEPTION '[356] requested_by_kind CHECK 제약을 찾지 못했습니다 — 345 가 적용되지 않았거나 구조가 다릅니다.';
  END IF;

  EXECUTE format('ALTER TABLE public.withdrawal_requests DROP CONSTRAINT %I', v_name);
END $$;

ALTER TABLE public.withdrawal_requests
  ADD CONSTRAINT withdrawal_requests_requested_by_kind_check
  CHECK (requested_by_kind IN ('self', 'admin_proxy', 'admin_forced'));

COMMENT ON COLUMN public.withdrawal_requests.requested_by_kind IS
  '[356] 누가 신청했나 — self(본인) · admin_proxy(관리자 대행, 회원이 요청) · '
  'admin_forced(관리자 강제, 자격 상실 · 약관 제6조 3항). 본인 탈퇴와 자격 상실은 '
  '다른 사건이라 감사에서 갈려야 하고(사양서 §5 ⑤), 거기에 「대행」이라는 세 번째 '
  '성격이 더해졌다. ★ 셋의 결정적 차이는 **본인이 취소할 수 있는가** — 대행은 '
  '가능, 강제는 불가(cancel_withdrawal 이 admin_forced 만 거부). 옛 값 admin 은 '
  '버렸다(운영 0건) — 그 뜻이 「강제」였는데 「대행」으로 재활용하면 취소 판정이 '
  '있는 그대로 정반대로 동작한다.';

-- ============================================================
-- [B] _influencer_is_admin_account(uuid) — 대상 회원이 관리자 계정을 겸하나
--
--   ⚠️ is_admin() 과 **헷갈리지 말 것** — is_admin() 은 「지금 호출한 사람」이
--     관리자인가이고, 이 함수는 「대상 회원」이 관리자 계정인가다. 이름에
--     _influencer_ 를 넣은 이유가 그것이다.
--
--   왜 필요한가: 로그인 계정은 관리자와 인플루언서가 **같은 행을 공유**한다.
--   그래서 파기 함수(352)가 겸직 회원을 거부하는데, 신청 단계에서 아무도 안 막아
--   그런 회원이 신청하면 **매일 재시도되며 영영 확정되지 않는다.**
-- ============================================================
CREATE OR REPLACE FUNCTION public._influencer_is_admin_account(
  p_influencer_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.admins WHERE auth_id = p_influencer_id
  );
$fn$;

COMMENT ON FUNCTION public._influencer_is_admin_account(uuid) IS
  '[356] 그 회원이 관리자 계정을 겸하고 있나. 로그인 계정을 관리자와 같이 쓰기 '
  '때문에 그대로 파기하면 그 사람의 관리자 로그인이 조용히 끊긴다 — 352 가 확정 '
  '단계에서 거부하는 근거이고, 신청 단계(357)·사전 조회([F])도 같은 판정을 쓴다. '
  '⚠️ is_admin() 과 다르다 — 저쪽은 「호출한 사람」, 이쪽은 「대상 회원」. '
  '내부 전용 — authenticated 에 GRANT 하지 않는다. '
  '⚠️ 352 는 아직 같은 판정을 인라인으로 갖고 있다(위 헤더 ⑤) — 그 함수를 다음에 '
  '손댈 때 이 헬퍼 호출로 교체할 것.';

REVOKE ALL ON FUNCTION public._influencer_is_admin_account(uuid) FROM PUBLIC;

-- ============================================================
-- [C] _withdrawal_cancel_applications(uuid) — 살아있는 응모 일괄 철회
--
--   ★ 본인 신청(357 의 request_withdrawal)과 대행 신청(request_withdrawal_for_member)
--     이 **둘 다 이 함수를 부른다.** 반복문을 두 벌로 만들면 이 저장소가 반복해 겪은
--     「같은 판단이 여러 곳」 사고가 된다.
--
--   반복문 자체는 354 의 것을 **글자 그대로** 옮겼다. 달라진 것은 통과 표시를
--   세우고 끄는 두 줄뿐이다.
--
--   ⚠️ **아무에게도 실행 권한을 주지 않는다.** 이 함수를 부를 수 있으면 남의 응모를
--     통째로 취소할 수 있다. 내부 전용이 아니라 **보안 경계**다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_cancel_applications(
  p_influencer_id uuid
) RETURNS TABLE (
  cancelled_count   integer,
  uncancelled_count integer
)
-- ⚠️ 반환 칸 이름 `uncancelled_count` 는 **withdrawal_requests 의 실제 열 이름과
--   같다**(345). 지금은 이 함수가 그 표를 전혀 건드리지 않아 충돌이 없지만, 나중에
--   이 안에서 그 표를 조회·수정하게 되면 출력 칸과 열 참조가 부딪혀 첫 호출에서
--   터진다(42702). 2026-05-20 에 정확히 그 유형으로 응모건 메시지가 죽었다.
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_app_id       uuid;
  v_cancelled    integer := 0;
  v_uncancelled  integer := 0;
  v_app_cancel_reason_code CONSTANT text := 'withdrawal';
BEGIN
  -- 통과 표시 — 세 번째 인자 true = **트랜잭션 지역**(끝나면 저절로 사라진다).
  --   값에 대상 회원 고유번호를 담아 **그 회원 응모만** 통과시킨다(헤더 ③).
  PERFORM set_config('reverb.withdrawal_actor_uid', p_influencer_id::text, true);

  -- ↓ 아래 반복문은 354 의 것과 **논리가 같다**(스크립트로 대조 — 실행줄 12개가
  --   1:1 대응하고 변수 이름 셋만 다르다: v_influencer_id→p_influencer_id ·
  --   v_cancelled_count→v_cancelled · v_uncancelled_count→v_uncancelled).
  FOR v_app_id IN
    SELECT id FROM public.applications
     WHERE user_id = p_influencer_id
       AND status IN ('pending', 'approved')
  LOOP
    BEGIN
      PERFORM public.cancel_application(v_app_id, v_app_cancel_reason_code, NULL, true);
      v_cancelled := v_cancelled + 1;
    EXCEPTION WHEN OTHERS THEN
      -- 결과물 승인됨(cancel_application 자체 차단) · 송금완료 정산 있음
      -- (마이그레이션 247 트리거) · 행사(event_mode) 응모(마이그레이션 289
      -- 트리거) 등, 이유를 가리지 않고 "철회 못 한 건"으로만 센다. 행사 응모는
      -- 마이그레이션 350 의 배치가 뒤이어 재시도한다.
      -- ⚠️ 실패 이유를 보려면 cancel_application 을 같은 인자로 직접 부를 것 —
      --   정상 가드를 결함으로 오판하기 쉽다(작업 5 검증에서 실제로 그럴 뻔했다).
      v_uncancelled := v_uncancelled + 1;
    END;
  END LOOP;

  -- 표시를 끈다 — 같은 트랜잭션에서 뒤에 다른 일이 이어질 수 있다.
  --   (저장점 롤백 시에도 표시는 함께 되돌아가지만, 명시적으로 끄는 편이 안전하다)
  PERFORM set_config('reverb.withdrawal_actor_uid', '', true);

  cancelled_count   := v_cancelled;
  uncancelled_count := v_uncancelled;
  RETURN NEXT;
END;
$fn$;

COMMENT ON FUNCTION public._withdrawal_cancel_applications(uuid) IS
  '[356] 그 회원의 살아있는 응모(심사중·승인)를 건별로 철회하고 성공·실패 건수를 '
  '돌려준다. 본인 신청과 관리자 대행 신청이 **둘 다 이 함수를 부른다**(반복문이 '
  '두 벌이 되지 않게). 반복문은 354 의 것과 논리가 같고(변수 이름 셋만 다르다), 통과 표시를 세우고 '
  '끄는 두 줄만 다르다. 🔴 **아무에게도 실행 권한을 주지 않는다** — 부를 수 있으면 '
  '남의 응모를 통째로 취소할 수 있다. 내부 전용이 아니라 보안 경계다.';

REVOKE ALL ON FUNCTION public._withdrawal_cancel_applications(uuid) FROM PUBLIC;

-- ============================================================
-- [D] cancel_application 재정의 — **베이스 309**
--   309 원본을 스크립트로 통째 추출해 **본인 검증 한 곳만** 치환했다
--   (손으로 옮기면 220줄 중 한 줄만 어긋나도 알 수 없다).
-- ============================================================
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

COMMENT ON FUNCTION public.cancel_application(uuid, text, text, boolean) IS
  '[356, 309 재정의] 회원 본인 응모 취소. 309 와 완전히 동일하고 본인 검증 한 곳만 '
  '넓혔다 — 탈퇴 처리 통과 표시(reverb.withdrawal_actor_uid)가 그 응모의 주인을 '
  '지목하고 있으면 통과한다. 관리자 대행 탈퇴가 회원 응모를 철회할 수 있게 하려는 '
  '것이며, 표시는 _withdrawal_cancel_applications() 안에서만 살아 있다(트랜잭션 지역). '
  '⚠️ 이 함수는 2026-05~08 약 3개월간 죽어 있었고 오류 로그에 흔적이 없었다 — '
  '고칠 때마다 실제 로그인 브라우저에서 본인 취소를 눌러 확인할 것.';

-- ============================================================
-- [E] cancel_withdrawal 재정의 — **베이스 349**
--   349 원본을 추출해 강제 판정 한 줄만 치환.
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_withdrawal()
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_influencer_id  uuid := auth.uid();
  v_inf            public.influencers%ROWTYPE;
  v_req            public.withdrawal_requests%ROWTYPE;
BEGIN
  -- 1. 본인 확인
  IF v_influencer_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 2. 본인 인플루언서 행 잠금(347 과 같은 순서 — 잠금 순서 메모 참고)
  --    + 감사용 계정 판별
  SELECT * INTO v_inf FROM public.influencers WHERE id = v_influencer_id FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- 3. 가장 최근 탈퇴 신청 행 잠금 — 활성 행이 있다면 이게 항상 그 행이다
  --    (부분 유일 색인이 "활성 행은 최신 행뿐"이라는 전제를 보장한다 —
  --    위 "그 외 설계 메모" 참고)
  SELECT * INTO v_req
    FROM public.withdrawal_requests
   WHERE influencer_id = v_influencer_id
   ORDER BY requested_at DESC
   LIMIT 1
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 4. 종료 상태는 거부(②) — done·cancelled 는 취소할 대상이 아니다
  IF v_req.status = 'done' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_done');
  END IF;

  IF v_req.status = 'cancelled' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'already_cancelled');
  END IF;

  -- 5. 관리자가 대신 신청한 행은 회원이 못 되돌린다(①) — 여기 도달했다면
  --    status 는 pending_payout 또는 scheduled(활성) 둘 중 하나뿐이다
  -- [356] **강제(자격 상실)만** 거부한다. 대행(admin_proxy)은 회원이 요청해서
  --   관리자가 대신 눌러 준 것이라, 5일 변심 유예를 뺏을 이유가 없다.
  --   ⚠️ 옛 값 'admin' 을 그대로 두고 뜻만 「대행」으로 바꾸지 않은 이유가 이것이다 —
  --     그랬으면 이 줄이 있는 그대로 정반대로 동작했다.
  IF v_req.requested_by_kind = 'admin_forced' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_requested');
  END IF;

  -- 6. 취소 처리 — status 만 바꾼다. completed_at·processed_by·
  --    scheduled_date·reason_code·reason_note·uncancelled_count 는
  --    건드리지 않는다(위 "그 외 설계 메모" 각 항목 참고). updated_at 은
  --    trg_withdrawal_requests_updated_at(345) 트리거가 자동 갱신한다.
  --    ⚠️ applications 표는 전혀 건드리지 않는다 — 철회된 응모를 되살리지
  --    않는 것은 의도된 동작이다(위 ③).
  UPDATE public.withdrawal_requests
     SET status = 'cancelled'
   WHERE id = v_req.id;

  RETURN jsonb_build_object(
    'ok',               true,
    'status',            'cancelled',
    'previous_status',   v_req.status
  );
END;
$$;

COMMENT ON FUNCTION public.cancel_withdrawal() IS
  '[356, 349 재정의] 회원 본인 탈퇴 신청 취소. 349 와 동일하고 거부 조건만 좁혔다 — '
  '옛날에는 관리자가 만든 신청을 통째로 거부했지만, 이제 **강제(admin_forced)만** '
  '거부하고 **대행(admin_proxy)은 본인이 취소할 수 있다**(회원이 요청해서 관리자가 '
  '대신 눌러 준 것이므로). 실패 사유 코드 admin_requested 는 이름을 그대로 둔다 — '
  '뜻(관리자가 처리한 탈퇴라 본인이 못 되돌린다)이 같고 화면이 이미 그 코드로 문구를 그린다.';

-- ============================================================
-- [F] get_withdrawal_precheck 재정의 — **베이스 353**
--   353 원본을 추출해 겸직 가드 한 덩어리만 추가.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_withdrawal_precheck(
  p_influencer_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_caller      uuid := auth.uid();
  v_target      uuid;
  v_inf         public.influencers%ROWTYPE;
  v_is_open     boolean;
  v_b           record;
  v_active      public.withdrawal_requests%ROWTYPE;
  v_has_active  boolean := false;
  v_mode        text;
BEGIN
  -- 1. 본인 확인
  IF v_caller IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  v_target := COALESCE(p_influencer_id, v_caller);

  -- 2. 남의 것을 보려면 관리자여야 한다
  --    ⚠️ is_admin() 은 등급을 안 가린다 — 이 조회는 개인정보를 돌려주지 않고
  --      건수만 돌려주므로 관리자 전원에게 연다(관리자 화면 정합).
  IF v_target <> v_caller AND NOT public.is_admin() THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'forbidden');
  END IF;

  SELECT * INTO v_inf FROM public.influencers WHERE id = v_target;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_found');
  END IF;

  -- 3. 감사용 계정은 애초에 탈퇴할 수 없다(347/350 이 거부한다) — 화면이
  --    「탈퇴하기」를 그렸다가 눌러서 거부당하는 일이 없도록 여기서도 같은
  --    답을 준다.
  IF v_inf.is_audit THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'audit_account_blocked');
  END IF;

  -- [356] 관리자를 겸한 회원 — 확정 단계의 파기 함수(352)가 거부하므로, 그대로
  --   두면 신청은 되고 **영영 확정되지 않은 채 매일 재시도**된다. 감사용 계정과
  --   같은 이유로 여기서도 미리 답을 준다(화면이 「탈퇴하기」를 그렸다가 눌러서
  --   거부당하는 일이 없게).
  IF public._influencer_is_admin_account(v_target) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'admin_account_excluded');
  END IF;

  v_is_open := public.is_withdrawal_open();

  SELECT * INTO v_b FROM public._withdrawal_lock_blockers(v_target);

  -- 4. 지금 진행 중인 신청이 있으면 함께 알려준다 — 화면이 「신청함/취소하기」를
  --    그리려면 필요하고, 이걸 안 주면 화면이 표를 따로 조회하게 된다.
  SELECT * INTO v_active
    FROM public.withdrawal_requests
   WHERE influencer_id = v_target
     AND status IN ('pending_payout', 'scheduled')
   ORDER BY requested_at DESC
   LIMIT 1;
  v_has_active := FOUND;

  -- 5. mode 판정 — 조건 셋(위 헤더 ③) 전부 0일 때만 잠금 기간에도 자동 처리
  IF v_is_open THEN
    v_mode := 'open';
  ELSIF v_b.approved_deliverable_apps = 0
    AND v_b.event_apps = 0
    AND v_b.settlement_rows = 0
    AND v_b.unpaid_count = 0 THEN
    v_mode := 'locked_auto';
  ELSE
    v_mode := 'locked_support';
  END IF;

  RETURN jsonb_build_object(
    'ok',      true,
    'mode',    v_mode,
    'is_open', v_is_open,
    'blockers', jsonb_build_object(
      'approved_deliverable_apps', v_b.approved_deliverable_apps,
      'event_apps',                v_b.event_apps,
      'settlement_rows',           v_b.settlement_rows,
      'unpaid_count',              v_b.unpaid_count
    ),
    'active_request',
      CASE WHEN v_has_active
        THEN jsonb_build_object(
               'status',         v_active.status,
               'scheduled_date', v_active.scheduled_date)
        ELSE NULL
      END
  );
END;
$$;

COMMENT ON FUNCTION public.get_withdrawal_precheck(uuid) IS
  '[356, 353 재정의] 탈퇴 화면이 누르기 전에 부르는 조회. 353 과 동일하고 관리자를 '
  '겸한 회원에 대한 사전 거부(admin_account_excluded)만 더했다 — 그런 회원은 확정 '
  '단계의 파기 함수(352)가 거부해 영영 확정되지 않으므로, 화면이 「탈퇴하기」를 '
  '그렸다가 눌러서 거부당하는 일이 없게 미리 답을 준다.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후 — 1단계씩)
--
-- 🔴 **[V2] 가 이 파일에서 가장 중요하다.** 여기서 회원의 본인 응모 취소가
--    깨지면 아무도 모른 채 3개월이 갈 수 있다(2026-05~08 실제 사례).
--    **[V2] 가 통과하기 전에는 357 을 적용하지 않는다.**
-- ============================================================
/*

-- ── SQL 편집기 (구조 확인) ─────────────────────────────────

-- [V0] 값 제약이 셋으로 바뀌었나
SELECT pg_get_constraintdef(con.oid)
  FROM pg_constraint con
  JOIN pg_class rel ON rel.oid = con.conrelid
 WHERE rel.relname = 'withdrawal_requests'
   AND con.contype = 'c'
   AND pg_get_constraintdef(con.oid) LIKE '%requested_by_kind%';
-- 기대: ('self','admin_proxy','admin_forced')

-- [V0-b] 옛 값을 넣으려 하면 거부되나
--   INSERT ... requested_by_kind='admin' → CHECK 위반(23514)이어야 한다
--   (실제로 넣지 말고, 넣어 봤다면 반드시 지울 것)

-- [V1] 새 함수 둘이 실제로 도는가 (자료형·컬럼 오류는 첫 호출에서만 드러난다)
SELECT public._influencer_is_admin_account(
  (SELECT id FROM public.influencers WHERE is_audit = false LIMIT 1)
);
-- 기대: false 또는 true (오류 없이 값이 나오면 된다)

--   ⚠️ _withdrawal_cancel_applications 는 **여기서 부르지 말 것** — 실제로
--     응모를 취소한다. 357 검증에서 시험 계정으로 확인한다.


-- ── 🔴 [V2] 로그인한 인플루언서 브라우저 — 가장 중요 ──────────

-- 시험 계정으로 로그인해 **살아있는 응모 하나를 실제로 취소**한다.
--   await db.rpc('cancel_application', {p_application_id:'<본인 응모 uuid>',
--                                       p_reason_code:'<사유코드>',
--                                       p_reason_note:null,
--                                       p_acknowledged:true})
-- 기대: 종전과 똑같이 **성공**한다.
-- 🔴 여기서 not_owner 가 나오면 통과 표시 조건을 잘못 넣은 것이다 — 그 상태로
--    두면 **모든 회원의 응모 취소가 죽는다.** 즉시 309 의 함수 블록을 다시
--    실행해 되돌릴 것.
--
-- ⚠️ 화면(응모이력 → 취소)으로도 한 번 해 볼 것. 원격 호출 직접 호출만으로는
--    화면이 오류를 덮는 경로를 못 본다(2026-05 사고가 그 형태였다).

-- [V3] 본인 탈퇴 신청·취소가 여전히 되는가 (같은 계정에서)
--   await db.rpc('request_withdrawal', {})   → ok:true
--   await db.rpc('cancel_withdrawal', {})    → ok:true, status:'cancelled'
--   ⚠️ 시험 뒤 withdrawal_requests 의 그 행을 정리할 것

-- [V4] 사전 조회가 겸직 회원을 거부하는가 (관리자 계정으로)
--   관리자를 겸한 회원의 고유번호로:
--   await db.rpc('get_withdrawal_precheck', {p_influencer_id:'<겸직 회원 uuid>'})
--   기대: { ok:false, reason:'admin_account_excluded' }
--   ⚠️ 관리자 계정 자신의 인플루언서 행으로 해 보면 된다(관리자는 대개 인플루언서
--     행도 갖고 있다). 없으면 이 단계는 건너뛰고 357 검증에서 함께 본다

-- [V5] 겸직이 아닌 일반 회원은 종전과 같은가
--   await db.rpc('get_withdrawal_precheck', {})
--   기대: mode 가 open/locked_auto/locked_support 중 하나로 정상 반환

*/
