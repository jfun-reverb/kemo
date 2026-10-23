-- ============================================================
-- 588_campaign_record_only.sql
-- 2026-10-23 — 기록용 캠페인(인플루언서 모집 없이 외부 결과물만 붙이는 캠페인) 칸 · 불변 장치 · 응모 거부 · 행사 조합 금지
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ⑥ · 작업표 docs/specs/2026-10-23-record-only-campaign-breakdown.md 조각 1
--   사용자 결정 S4(오프라인 행사 조합 금지) · 개발 기본값 S6(칸 이름)·S7(불변의 예외)·S8(거부 코드)
--
-- 🔴 운영에 먼저 나가는 작업(사양서 배포 순서 ①) — 브랜드 묶음(526~)에 기대지 않는다
--
-- 고치는 것
--   1) campaigns.is_record_only boolean NOT NULL DEFAULT false — 기존 행은 전부 false
--   2) 트리거 trg_campaigns_record_only_lock(BEFORE UPDATE OF is_record_only) + 함수 _campaigns_record_only_lock()
--      값이 바뀌고 로그인 세션이 있으면(auth.uid() IS NOT NULL) 'record_only_locked' 로 거부 — 관리자 화면 요청도 전부 거부.
--      로그인 없는 실행(SQL 편집기·서비스 키)만 바꿀 수 있다(S7). 🔴 SECURITY INVOKER — 판정에 표를 읽지 않는다
--      ⚠️ 삽입은 막지 않는다 — 기록용 여부는 「만들 때」 정한다
--   3) 검사 제약 campaigns_record_only_not_event — 기록용과 오프라인 행사(event_mode)를 함께 켤 수 없다(S4)
--   4) check_application_deadline() — 베이스 326(272 → 326). 보관 삭제 검사 바로 뒤, 관리자 통과 조항보다 **앞**에
--      기록용 거부 한 줄. 거부 코드 recruit_not_open 을 다시 쓴다(S8 — 회원 화면 「このキャンペーンは現在応募を受け付けていません」,
--      ui.js:174 · shared.js:2489 「예상된 거부」 목록에 이미 있다). 메시지 끝 (record_only) 은 기록·로그용
--      그 밖은 326 과 글자 그대로(주석 번호만 [588] 표시 추가)
--   · 바꾸지 않는 것: campaigns_bump_version(275 — 새 칸은 제외 6개에 없어 자동으로 version 대상) ·
--     캠페인 변경 이력 화이트리스트(265·266 — 바뀔 수 없는 값이라 넣지 않는다, S13) · 트리거 이름 trg_application_deadline_guard
--
-- 응모가 이 트리거를 지나는 자리: 회원 응모(applications INSERT) · 행사 예약 reserve_event_ticket(378 — 응모 행을 넣는다).
--   로그인 없는 삽입(배치·서비스 키)은 326 그대로 맨 앞에서 통과한다.
--   ⚠️ 삽입 전용 — 행사 대기자 승격(UPDATE)엔 안 걸린다. 기록용은 행사가 될 수 없어(3) 해당 없다
--
-- 편집기 경고: Supabase SQL 편집기의 「Success」는 이전 실행 잔상일 수 있다 — 끝의 기록 줄을 기록 표에서 확인한다.
--   🔴 SQL 편집기는 서비스 키라 2)·4)의 로그인 분기를 재현하지 못한다 — 로그인한 브라우저 콘솔로 확인한다(아래 「검증」)
--
-- 롤백(화면 조각 6~11 을 되돌린 **뒤**에 칸을 지운다 — 칸이 없으면 관리자 목록 조회가 실패한다)
--   DROP TRIGGER IF EXISTS trg_campaigns_record_only_lock ON public.campaigns;
--   DROP FUNCTION IF EXISTS public._campaigns_record_only_lock();
--   ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_record_only_not_event;
--   326_audit_remediation_bundle_i_deadline_and_msg_sender.sql 의 check_application_deadline 블록(CREATE OR REPLACE ~ COMMENT)을 다시 실행
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS is_record_only;
--
-- 검증(개발서버 · 로그인한 브라우저 콘솔)
--   관리자: db.from('campaigns').update({is_record_only:true}).eq('id', <일반 캠페인>) → record_only_locked 오류
--           같은 캠페인 제목 수정 → 성공
--   관리자: 기록용 캠페인에 applications 삽입 → recruit_not_open (record_only)
--   회원:   기록용 active 캠페인 응모 → 「このキャンペーンは現在応募を受け付けていません」
--   기록용 + event_mode=true 삽입 → campaigns_record_only_not_event 위반
-- ============================================================
BEGIN;

-- ── 1. 칸 ──
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS is_record_only boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.campaigns.is_record_only IS
  '[588] 기록용 캠페인 — 인플루언서 모집 없이 외부 결과물만 붙이는 캠페인. 만든 뒤 바꿀 수 없다(trg_campaigns_record_only_lock — 로그인 없는 실행만 예외). '
  '인플루언서 화면·응모·홍보 메일에 나오지 않는다. 브랜드 응답에는 싣지 않는다(브랜드 화면에는 일반 캠페인처럼 보인다). '
  '오프라인 행사(event_mode)와 함께 켤 수 없다(campaigns_record_only_not_event). 사양서 brand-portal.md 16-5 15번 ⑥.';

-- ── 2. 불변 장치 ──
CREATE OR REPLACE FUNCTION public._campaigns_record_only_lock()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- 로그인 없는 실행(SQL 편집기·서비스 키·배치)만 바꿀 수 있다 — 관리자 화면 요청도 거부(S7)
  IF NEW.is_record_only IS DISTINCT FROM OLD.is_record_only
     AND auth.uid() IS NOT NULL THEN
    RAISE EXCEPTION 'record_only_locked: 기록용 여부는 등록한 뒤 바꿀 수 없습니다 (campaign_id=%)', OLD.id
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public._campaigns_record_only_lock() IS
  '[588] campaigns.is_record_only 불변 트리거 함수. BEFORE UPDATE OF is_record_only. '
  '값이 바뀌고 auth.uid() 가 있으면 record_only_locked(P0001). 로그인 없는 실행은 통과. SECURITY INVOKER.';

REVOKE ALL ON FUNCTION public._campaigns_record_only_lock() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._campaigns_record_only_lock() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_campaigns_record_only_lock ON public.campaigns;
CREATE TRIGGER trg_campaigns_record_only_lock
  BEFORE UPDATE OF is_record_only ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public._campaigns_record_only_lock();

-- ── 3. 오프라인 행사 조합 금지(S4) ──
ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_record_only_not_event;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_record_only_not_event
  CHECK (NOT (is_record_only AND event_mode IS TRUE));

-- ── 4. 응모 거부 — check_application_deadline 재정의(베이스 326) ──
CREATE OR REPLACE FUNCTION public.check_application_deadline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camp_status      text;
  v_camp_deadline    date;
  v_camp_deleted_at  timestamptz;
  v_camp_record_only boolean;
  v_today_kst        date;
  v_is_admin         boolean;
BEGIN
  -- 1. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (272 원문 그대로, 무변경. 익명 anon 쓰기는 applications_insert_own 행 단위
  --     보안 정책에서 이미 차단되어 여기까지 도달하지 못한다 — 272 파일 상단 주석 참조)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- [326] 캠페인 상태·마감일·보관 삭제 여부를 한 번에 조회 (272 원문은 deadline 만 봤다).
  -- [588] 기록용 여부도 함께 조회한다.
  SELECT c.status, c.deadline, c.deleted_at, c.is_record_only
    INTO v_camp_status, v_camp_deadline, v_camp_deleted_at, v_camp_record_only
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  -- 캠페인을 찾을 수 없으면 통과 (272 원문이 deadline=NULL 을 "무기한 캠페인"으로
  -- 통과시킨 것과 동일한 결론 — 이 경로는 정상 흐름에서 도달하지 않는다. 위 파일
  -- 헤더 "판정 순서 2." 참고).
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- [326] 2. 보관 삭제(deleted_at)된 캠페인 — 관리자·서비스 키(이 지점 이후) 예외 없이
  --    무조건 거부. reserve_event_ticket(316)의 deleted_at 검사와 같은 설계(그 함수도
  --    이 검사에는 관리자 예외를 주지 않는다) — 위 파일 헤더 "판정 순서 3." 참고.
  IF v_camp_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'campaign_deleted: 삭제된 캠페인에는 응모할 수 없습니다 (campaign_id=%)', NEW.campaign_id
      USING ERRCODE = 'P0001';
  END IF;

  -- [588] 2-b. 기록용 캠페인 — 관리자도 예외 없이 거부(인플루언서 모집이 없는 캠페인).
  --    관리자 통과 조항(아래 3)보다 앞이어야 한다. 거부 코드는 recruit_not_open 을 다시 쓴다(S8 —
  --    회원에게 기록용이라는 이유를 드러내지 않는다). 끝의 (record_only) 는 기록·로그용.
  IF v_camp_record_only IS TRUE THEN
    RAISE EXCEPTION 'recruit_not_open: 기록용 캠페인에는 응모할 수 없습니다 (record_only)'
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. 관리자 — 아래(상태·마감일) 검사는 건너뛴다.
  --    (272 원문 그대로, 무변경 — 현재는 관리자 대리 응모 경로가 없어 도달하지 않는
  --     대비 조항. 단 위 2번(보관 삭제)을 이미 지난 뒤에만 도달하므로, 관리자도
  --     보관 삭제된 캠페인에는 이 조항으로 우회할 수 없다.)
  v_is_admin := public.is_admin();
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  -- [326] 4. 캠페인 상태 — 화면의 응모 버튼이 실제로 눌리는 상태는 'active' 하나뿐이다
  --    (dev/js/application.js:406~421, reserve_event_ticket 316 과 동일 판정 근거 —
  --    위 파일 헤더 "판정 순서 5." 참고). closed 는 마감일 전이어도 관리자가 상태
  --    드롭다운으로 수동 전환할 수 있어 아래 마감일 검사만으로는 못 잡는다.
  IF v_camp_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'recruit_not_open: 현재 모집 중이 아닌 캠페인입니다 (status=%)', COALESCE(v_camp_status, 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  -- 5. 일본 시각(Asia/Tokyo) 기준 오늘 날짜가 마감일을 넘었는지 판정.
  --    (272 원문 그대로, 무변경. status='active' 인데 deadline 만 지난 좁은 경합을
  --     이 검사가 잡는다 — 위 4번만으로는 못 막는 케이스.)
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  IF v_camp_deadline IS NULL OR v_today_kst <= v_camp_deadline THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'recruit_deadline_passed: 모집 기간이 종료되었습니다'
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION public.check_application_deadline() IS
  '[272+326+588] 모집 마감 응모 차단 트리거 함수. BEFORE INSERT ON applications.
   판정: auth.uid() NULL 통과 → 캠페인 조회(못 찾으면 통과) → deleted_at 있으면
   무조건 거부(campaign_deleted, 관리자 예외 없음) → [588] is_record_only 면
   무조건 거부(recruit_not_open … (record_only), 관리자 예외 없음) → is_admin() 통과 →
   status<>''active'' 면 거부(recruit_not_open) →
   (now() AT TIME ZONE ''Asia/Tokyo'')::date <= deadline 이면 통과, 아니면
   ''recruit_deadline_passed: ...'' 예외(ERRCODE P0001).
   [326] 캠페인 상태·보관 삭제 여부 검사 추가 — 사양서
   docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I」 I-12.
   [588] 기록용 캠페인 거부 — 사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ⑥.
   원본: docs/specs/2026-07-29-deadline-server-enforcement.md 1단계.';

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '588', '588_campaign_record_only.sql');
COMMIT;
