-- ============================================================
-- 314_application_insert_status_guard.sql
-- 전수조사 후속 조치 묶음 E — E-5: 응모(applications) 삽입 시 상태 값을
-- 서버가 강제한다. 지금은 클라이언트가 무엇을 보내든 그대로 저장된다
-- (마이그레이션 137:247-250, applications_insert_own — WITH CHECK 이
-- "본인 행인가"만 보고 status 값은 전혀 보지 않는다. status 컬럼에
-- CHECK 제약도 없다).
--
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §1-5
--   "인플루언서가 스스로 당선될 수 있다 — 시딩·방문형에서 상태를 「당선」
--    으로 보내면 심사 없이 통과 → 결과물 제출 → 인증 성공 → 정산 후보까지
--    들어간다. 상태 변경 감사 기록은 수정 트리거라 삽입으로 들어온 값은
--    흔적도 안 남는다."
-- 조치 계획: docs/specs/2026-08-07-audit-remediation-plan.md 묶음 E, E-5
-- 전제: E-1~E-4(마이그레이션 312·313 포함)가 먼저 적용돼 있어야 순서상
--   맞다(파일 번호 순서 그대로 따르면 자동으로 지켜짐).
--
-- ────────────────────────────────────────────────────────────
-- 정당한 삽입 경로가 몇 개이고 각각 무엇을 보내는지 먼저 확인(전수 grep)
-- ────────────────────────────────────────────────────────────
-- `insert into applications` / `insertApplication(` 호출부를 전수 grep 했다
-- (dev/js/*.js, dev/lib/storage.js, supabase/migrations/*.sql):
--
--   1) dev/js/application.js:917-922 — 유일한 클라이언트 삽입 경로
--      (insertApplication, storage.js:806). status:'pending' 고정.
--      reviewed_by·reviewed_at 은 아예 안 보낸다(NULL로 저장됨).
--
--   2) public.reserve_event_ticket(...) — 오프라인 행사 예약(마이그레이션
--      283→284→288, 현재 유효한 정의는 288). 확정이면 status='approved',
--      대기면 status='pending' 으로 신청 행을 **직접** 만든다(288:177-208
--      경로와 동일 구조). 이건 자기 신고가 아니라 서버가 그 자리에서 정원을
--      세어(FOR UPDATE 잠금) 계산한 값이라 정당하다. 이 함수는 시작부에서
--      `PERFORM set_config('reverb.event_ticket_bypass', 'on', true)` 를
--      세운다(288:425) — 289(신청 상태 UPDATE 가드)가 이미 이 표시를
--      "이 트랜잭션은 288의 예약 함수가 낸 변경" 의 증거로 쓰고 있다.
--      이번 트리거도 **같은 표시를 재사용**한다(새 표시를 만들지 않는다).
--
--   3) 관리자가 인플루언서 대신 응모를 대리 등록하는 경로 — **없다**.
--      마이그레이션 272(모집 마감 가드) 파일 헤더가 이미 같은 결론을 적어
--      뒀다: "관리자가 인플루언서 대신 응모를 대리 등록하는 경로는 현재
--      코드베이스에 없다(insertApplication() 1곳뿐)". 이번 조사도 동일하게
--      확인됨 — CLAUDE.md 도 이 사실을 "관리자 대리 응모 경로가 없음" 으로
--      명시하고 있다.
--
-- 결론: 정당한 삽입은 ①클라이언트(항상 pending) ②행사 예약 함수(정원 계산
-- 값, bypass 표시 있음) 뿐이다. 그 외 경로로 들어오는 status 값은 전부
-- 신뢰할 수 없다 — 심사중으로 강제해도 깨지는 정당한 흐름이 없다.
--
-- ────────────────────────────────────────────────────────────
-- 이 마이그레이션이 하는 일
-- ────────────────────────────────────────────────────────────
-- BEFORE INSERT ON applications 트리거를 새로 추가한다. 판정 4단계:
--   1) reverb.event_ticket_bypass = 'on' (288의 예약 함수) → 통과
--   2) auth.uid() IS NULL (배치·서비스 키)                → 통과
--   3) is_admin() (현재는 도달하지 않는 대비 조항, 272 와 동일 근거) → 통과
--   4) 그 외 전부 → NEW.status := 'pending' 강제.
--      함께 NEW.reviewed_by / NEW.reviewed_at 도 NULL 로 강제한다 — status
--      만 pending 으로 되돌리고 reviewed_by·reviewed_at(누가 언제 승인했나
--      는 감사 칸)에 위조값이 남으면 "심사중인데 이미 승인자가 찍힌" 앞뒤가
--      안 맞는 행이 만들어진다. 정상 클라이언트는 애초에 이 두 칸을 보내지
--      않으므로(위 ①) NULL 로 강제해도 회귀 없음.
--
-- ⚠️ 실행 순서가 결정적이다 — monitor(리뷰어) 캠페인은 삽입 시 자동으로
--   당선 처리되는 기존 트리거(trg_monitor_auto_approve, 049)가 있다. 그
--   트리거는 recruit_type='monitor' 면 **무조건** NEW.status:='approved'
--   로 다시 덮어쓴다(049:31-35, 이전 값이 무엇이든 상관하지 않음). 이번
--   트리거가 monitor_auto_approve **보다 먼저** 돌면: 우리가 pending 으로
--   내린 값을 049가 곧바로 approved 로 되돌려 리뷰어형 자동 승인이 그대로
--   유지된다. 반대로 **나중에** 돌면: 049가 approved 로 만든 직후 우리가
--   다시 pending 으로 뭉개 버려 리뷰어형 응모가 전부 심사중에 갇힌다.
--
--   PostgreSQL 은 같은 타이밍(BEFORE)·같은 이벤트(INSERT)의 트리거를
--   트리거 이름 알파벳순으로 실행한다. 기존 4종 + 이번 트리거를 이름순
--   정렬하면:
--     trg_age_policy (180)
--     trg_application_deadline_guard (272)
--     trg_application_insert_status_guard (본 트리거)   ← 'a' < 'm' 이므로
--     trg_monitor_auto_approve (049)                       여기보다 먼저 실행
--     trg_monitor_slots_guard (048/179)
--   이름을 "trg_application_insert_status_guard"(a…)로 지어 두 monitor_*
--   트리거(m…)보다 앞서 실행되도록 의도적으로 배치했다 — 272 가 같은 이유로
--   "trg_application_deadline_guard"(a…)를 monitor_* 보다 앞에 둔 것과
--   동일한 관례. age_policy·deadline_guard 는 NEW 를 변형하지 않고
--   RAISE EXCEPTION 만 하므로 이 트리거와 순서를 다퉈도 최종 결과에
--   영향이 없다(먼저 예외가 나면 트랜잭션이 그 자리에서 끝난다).
--
-- ────────────────────────────────────────────────────────────
-- 영향받지 않는 것
-- ────────────────────────────────────────────────────────────
-- - 클라이언트의 정상 응모(gifting·visit) — 원래도 status:'pending' 만
--   보냈으므로 이 트리거가 값을 바꿔도 결과가 같다(no-op).
-- - monitor(리뷰어) 캠페인 자동 승인 — 049가 이 트리거 다음에 돌아
--   approved 로 다시 덮어쓴다(위 「실행 순서」 참고). 알림·정산 후보 등록
--   등 049 뒷단 로직은 049 가 세팅한 approved 값을 그대로 본다.
-- - 오프라인 행사 예약(reserve_event_ticket, 288) — bypass 표시로 통과.
--   확정=approved / 대기=pending 그대로 저장된다.
-- - 마감(272)·정원(048/179)·연령(180) 가드 — NEW 를 변형하지 않는
--   트리거라 이번 트리거와 값을 두고 다투지 않는다.
--
-- ────────────────────────────────────────────────────────────
-- 이 조각이 못 막는 것 (다른 조각·기존 방어선의 몫)
-- ────────────────────────────────────────────────────────────
-- - 남이 아닌 "본인" 행으로 위장한 삽입 — applications_insert_own(137)의
--   WITH CHECK (auth.uid() = user_id) 가 이미 막는다. 이번 트리거는 그
--   레이어 다음 단계(들어온 status 값 자체를 못 믿는 문제)를 막는다.
-- - 승인된 후 반려·취소된 신청의 정산 제외 — 마이그레이션 246·264 등
--   기존 로직이 별도로 처리(무관).
--
-- 롤백: 파일 하단.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_application_insert_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 1. 오프라인 행사 예약 함수(reserve_event_ticket 등, 288)가 세워 둔
  --    표시. 289(신청 상태 UPDATE 가드)가 쓰는 것과 동일한 표시를
  --    재사용한다 — 새 표시를 만들지 않는다. 이 표시가 있으면 그
  --    트랜잭션은 서버가 정원을 세어 계산한 값이므로 신뢰한다.
  IF COALESCE(current_setting('reverb.event_ticket_bypass', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  -- 2. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과
  --    (272 와 동일 조항). 익명 쓰기는 applications_insert_own RLS
  --    단계에서 이미 차단되어 여기 도달하지 못한다.
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 3. 관리자 — 현재는 관리자 대리 응모 경로가 없어 도달하지 않는
  --    대비 조항(272 와 동일 근거). 향후 대리 응모 기능이 생겨도
  --    막히지 않도록 미리 둔다.
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 4. 그 외 전부 — 클라이언트가 무엇을 보냈든 심사중으로 강제한다.
  --    monitor(리뷰어) 캠페인은 이 트리거 바로 다음에 도는
  --    trg_monitor_auto_approve(049)가 무조건 approved 로 다시
  --    덮어쓰므로 정상 동작에 영향이 없다 — 이 트리거는 "누가 approved
  --    를 보냈는가"를 지우는 것이지 "심사 없는 자동 승인 정책" 자체를
  --    바꾸는 것이 아니다.
  NEW.status      := 'pending';
  NEW.reviewed_by := NULL;
  NEW.reviewed_at := NULL;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_application_insert_status() IS
  '[314] 응모 삽입 시 상태값 위조 차단. BEFORE INSERT ON applications.
   판정: reverb.event_ticket_bypass=on 통과(288 예약 함수) → auth.uid() NULL
   통과(배치) → is_admin() 통과(대비 조항, 현재 미도달) → 그 외 status를
   pending 으로, reviewed_by/reviewed_at 을 NULL 로 강제.
   monitor 캠페인은 이 트리거 다음의 trg_monitor_auto_approve(049)가 approved
   로 다시 덮어써 자동 승인 정책은 그대로 유지된다(트리거 이름 알파벳순
   trg_application_insert_status_guard < trg_monitor_auto_approve).
   조사 docs/research/2026-08-07-codebase-audit-findings.md §1-5.';

DROP TRIGGER IF EXISTS trg_application_insert_status_guard ON public.applications;
CREATE TRIGGER trg_application_insert_status_guard
  BEFORE INSERT ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_application_insert_status();

COMMENT ON TRIGGER trg_application_insert_status_guard ON public.applications IS
  '[314] 응모 삽입 상태값 위조 차단. 이름을 trg_application_…(a…)로 지어
   trg_monitor_auto_approve(m…)보다 알파벳순으로 먼저 실행되도록 배치 —
   순서가 바뀌면 monitor 캠페인 자동 승인이 깨진다. 상세는 파일 헤더 참고.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- ============================================================
--
-- [1] 함수·트리거 존재 확인
-- SELECT p.proname, p.prosecdef, t.tgname, t.tgenabled
--   FROM pg_proc p JOIN pg_trigger t ON t.tgfoid = p.oid
--  WHERE p.proname = 'guard_application_insert_status'
--    AND p.pronamespace = 'public'::regnamespace;
--   → 1행, prosecdef=true, tgname='trg_application_insert_status_guard', tgenabled='O'
--
-- [2] 실행 순서 확인 (알파벳순 재확인 — 가장 중요)
-- SELECT tgname
--   FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND tgname LIKE 'trg_%'
--    AND NOT tgisinternal
--  ORDER BY tgname;
--   → 5행, 다음 순서여야 한다:
--     trg_age_policy
--     trg_application_deadline_guard
--     trg_application_insert_status_guard   ← 새로 추가된 것, 반드시 이 자리
--     trg_monitor_auto_approve
--     trg_monitor_slots_guard
--   trg_application_insert_status_guard 가 trg_monitor_auto_approve 보다
--   뒤에 나오면 즉시 중단하고 트리거 이름을 재검토할 것(리뷰어형 응모가
--   전부 심사중에 갇히는 회귀가 생긴다).
--
-- [3] 위조 시도 차단 확인 — SQL 편집기 (트리거는 역할과 무관하게 항상
--     발동하므로 재현 가능. 단 RLS INSERT 정책 자체는 서비스 키가 우회하니
--     이 단계는 "트리거 로직"만 검증한다 — 최종 확인은 [5] 실제 로그인).
--     ⚠️ 반드시 BEGIN ~ ROLLBACK 사이에서만 실행할 것(운영 데이터에 남기지
--     않기 위함). gifting 또는 visit 캠페인 id 와, 아직 응모하지 않은 테스트
--     인플루언서 id 로:
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message, status)
--     VALUES ('<테스트 인플루언서 auth_id>'::uuid, '<gifting/visit 캠페인 id>'::uuid,
--             '검증용', 'approved');  -- 일부러 approved 를 보낸다
--     SELECT status, reviewed_by, reviewed_at FROM public.applications
--      WHERE user_id = '<테스트 인플루언서 auth_id>'::uuid
--        AND campaign_id = '<gifting/visit 캠페인 id>'::uuid;
--     -- 기대: status='pending', reviewed_by IS NULL, reviewed_at IS NULL
--     --       (approved 를 보냈지만 pending 으로 강제됐어야 한다)
--   ROLLBACK;
--   ⚠️ set_config('request.jwt.claims', ...) 는 PostgREST 가 세팅하는 값을
--      SQL 편집기에서 흉내내는 것 — auth.uid() 는 이 클레임의 'sub' 값을
--      읽으므로 트리거 내부 판정(auth.uid() IS NULL / is_admin())까지
--      실제 로그인처럼 재현된다(272 파일의 검증 방식과 동일).
--
-- [4] monitor(리뷰어) 자동 승인 회귀 확인 — 같은 방식으로 monitor 캠페인에
--     대입(status 는 아무 값이나, 예: 'pending' 그대로):
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message, status)
--     VALUES ('<테스트 인플루언서 auth_id>'::uuid, '<monitor 캠페인 id>'::uuid,
--             '검증용', 'pending');
--     SELECT status, reviewed_by FROM public.applications
--      WHERE user_id = '<테스트 인플루언서 auth_id>'::uuid
--        AND campaign_id = '<monitor 캠페인 id>'::uuid;
--     -- 기대: status='approved', reviewed_by='自動承認' (049 가 정상적으로
--     --       이어서 처리했다는 뜻 — 자동 승인 정책이 안 깨졌는지 확인)
--   ROLLBACK;
--
-- [5] 실제 로그인 세션 확인 (권장·최종 확인) — 개발서버 브라우저에서:
--   5-1) 테스트 인플루언서 계정으로 로그인 → gifting/visit 캠페인에 정상
--        응모 → status='pending' 으로 저장되는지 확인(화면·데이터베이스
--        양쪽). 브라우저 개발자 도구 콘솔에서 insertApplication 호출 없이
--        직접 REST 로 status:'approved' 를 보내도 pending 으로 강제되는지
--        확인(선택).
--   5-2) monitor(리뷰어) 캠페인에 정상 응모 → status='approved' 로 자동
--        승인되는지 확인(기존 동작 회귀 없음).
--   5-3) 오프라인 행사 캠페인(event_mode=true)에 실제 예약 → 정원 안이면
--        approved, 정원 밖이면 pending 으로 정상 저장되는지 확인(288 예약
--        함수가 이 트리거에 막히지 않는지).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_application_insert_status_guard ON public.applications;
-- DROP FUNCTION IF EXISTS public.guard_application_insert_status();
-- COMMIT;
-- NOTIFY pgrst, 'reload schema';
-- ============================================================
