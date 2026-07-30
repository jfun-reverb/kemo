-- ============================================================
-- 272_recruit_deadline_guard.sql
-- 모집 마감 후 응모(applications INSERT)를 데이터베이스에서 차단
-- 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md (1단계 — §설계 1-(가))
--
-- ▶ 무엇을 왜 막는가
--   화면의 응모 버튼 차단은 캠페인 status(closed/ended) 기준이고, status 전이는
--   autoCloseCampaigns()가 "누군가 캠페인 목록을 불러올 때" 수행한다(storage.js:198).
--   아무도 목록을 열지 않으면 마감일이 지나도 campaigns.status 는 active 그대로 남는다
--   — 즉 서버 관점에서 status 는 신뢰할 수 없는 값이고, applications BEFORE INSERT
--   트리거 4종(048 정원가드/049 자동승인/179 감사용 재정의/180 연령정책) 중
--   어느 것도 마감일 자체는 보지 않는다. 운영 데이터 실측(2026-07-29)으로는
--   마감 후 응모 0건이었으나 "막혀 있어서 0건"이 아니라 "우연히 0건" — 이 트리거가
--   그 우연을 서버 차원의 필연으로 만든다.
--
-- ▶ 판정 4단계 (사양서 §설계 1-(가) 그대로, 별도 판정 함수 없이 트리거 함수 자체가 판정)
--   1. auth.uid() IS NULL              → 통과 (배치·마이그레이션·서비스 키)
--   2. public.is_admin()                → 통과 (현재는 도달하지 않는 대비 조항)
--   3. 캠페인 deadline 조회 → NULL      → 통과 (무기한 캠페인)
--   4. (now() AT TIME ZONE 'Asia/Tokyo')::date <= deadline → 통과, 아니면 거부
--      거부 메시지는 머신 판독용 코드 접두어 포함:
--        'recruit_deadline_passed: 모집 기간이 종료되었습니다'
--      → dev/js/ui.js friendlyErrorJa() 가 이 접두어를 정규식으로 매칭해 일본어/한국어
--        안내 문구로 변환한다(_ERR_DICT.recruitDeadlinePassed, post_already_approved 와
--        동일한 "메시지 문자열 매칭" 계약). 이 마이그레이션 작성 시점에 이미 프론트
--        코드가 그 매칭 규칙을 갖추고 있음을 확인함(dev/js/ui.js 미커밋 변경 확인,
--        2026-07-29) — 코드 접두어 문자열은 그 계약을 그대로 따른 것이며 임의 변경 금지.
--
-- ▶ 통과 조항(1·2번)이 구멍이 되지 않는 근거
--   1) auth.uid() IS NULL 통과 — applications 에는 익명 대상 쓰기 정책이 없다.
--      "applications_insert_own"(001_enable_rls.sql)은 WITH CHECK (auth.uid() = user_id) 뿐이고
--      TO anon 을 허용하는 별도 정책이 없어, 익명 키로 온 INSERT는 행 단위 보안 정책 단계에서
--      이미 거부되어 이 트리거까지 도달하지 못한다. 실제로 이 조항을 타는 것은 서비스 키를
--      쓰는 배치·마이그레이션뿐이다. 향후 익명 쓰기 정책을 추가한다면 이 조항을 반드시
--      재검토할 것(사양서 §설계 1-(가) 각주와 동일 경고).
--   2) public.is_admin() 통과 — 관리자가 인플루언서 대신 응모를 대리 등록하는 경로는
--      현재 코드베이스에 없다(insertApplication() 1곳뿐, storage.js:759). 즉 이 조항은
--      "현재는 도달하지 않는" 대비 조항이며, 결과물(deliverables) 검사 장치와 형태를
--      맞추고 향후 관리자 대리 응모 기능이 생겨도 막히지 않도록 미리 둔 것뿐이다.
--      이 조항의 존재가 대리 응모 기능이 있다는 뜻은 아니다.
--
-- ▶ 기존 applications BEFORE INSERT 트리거 3종(048/179 재정의 · 049 · 180)과의 관계
--   각 트리거는 서로 다른 축을 독립적으로 판정하고(정원/자동승인/연령/마감일), NEW 의
--   같은 컬럼을 두고 다투지 않으므로(이 트리거는 NEW 를 전혀 변형하지 않고 통과/거부만
--   한다) 실행 순서가 최종 결과(성공/거부 여부)에 영향을 주지 않는다. 다만 "동시에 여러
--   조건이 거부 사유가 될 때 어느 메시지가 먼저 뜨는가"는 순서에 좌우된다(PostgreSQL은
--   같은 이벤트의 BEFORE 트리거를 트리거 이름 알파벳순으로 실행하며, 하나가 예외를
--   던지면 트랜잭션이 즉시 중단되어 뒤 트리거는 실행되지 않는다):
--     trg_age_policy → trg_application_deadline_guard(본 트리거) →
--     trg_monitor_auto_approve → trg_monitor_slots_guard
--   트리거 이름을 "trg_application_deadline_guard"(a…)로 지어 두 monitor_* 트리거(m…)
--   보다 앞서 실행되도록 의도적으로 배치했다 — "마감이 지난 데다 정원도 찬" 극히
--   드문 경합(정상 흐름에서는 마감 시 화면이 이미 응모 버튼을 닫으므로, 이 경합은
--   화면이 stale 한 상태에서 직접 호출할 때만 발생)에서, 사용자에게 "정원이 찼다"
--   보다 "모집 기간이 끝났다"는 더 근본적인 이유를 먼저 보여주는 것이 자연스럽다고
--   판단했기 때문이다(정원 부족은 "조금만 빨랐으면 됐다"는 오해를 주지만, 마감은
--   그 자체로 더 이상 여지가 없다는 뜻이라 오해의 여지가 없다). 연령 정책(180,
--   trg_age_policy)은 "자격 자체"를 보는 축이라 타이밍과 무관하게 항상 먼저 나오는
--   편이 자연스러워 그대로 두었다(관여하지 않음).
--
-- ▶ 취소 후 재응모 / 부분 유니크 인덱스와의 관계
--   재응모는 insertApplication() 이 새 행을 그대로 INSERT 하는 경로라 이 트리거를
--   동일하게 탄다(마감 전이면 허용, 마감 후면 차단 — 사양서 §7 「경계 상황」 표와 일치).
--   (user_id, campaign_id) 부분 유니크 인덱스(104_application_cancellation.sql, cancelled
--   행 제외)는 "같은 응모가 중복 저장되는가"만 보는 제약이라 이 트리거의 날짜 판정과
--   축이 겹치지 않는다 — 마감 전 재응모는 유니크 인덱스도 통과, 마감 후 재응모는
--   유니크 인덱스 통과 여부와 무관하게 이 트리거가 먼저 막는다(BEFORE INSERT 이므로
--   유니크 제약 검사보다 먼저 실행).
--
-- ▶ 감사용 계정(influencers.is_audit)과의 상호작용
--   결정 7(사양서)대로 감사용 계정은 관리자 예외를 받지 않는다 — is_admin() 은 admins
--   테이블 존재 여부만 보고 influencers.is_audit 은 보지 않으므로, 감사용 계정이 관리자
--   계정으로 등록돼 있지 않은 한 이 트리거는 일반 인플루언서와 동일하게 마감 후 응모를
--   차단한다. 179가 재정의한 check_monitor_slots() 는 "감사용 응모를 정원 집계에서
--   제외"할 뿐 "감사용 응모 자체를 허용/차단"하는 것이 아니라서 이 트리거와 판정 축이
--   겹치지 않는다 — 두 트리거는 각자 다른 이유로 각자 독립적으로 거부할 수 있다(정원은
--   감사용을 열어주고, 마감은 감사용도 막는다). 동일인이 관리자 계정으로 로그인한
--   동안은 결정 3(관리자 예외)에 따라 통과하므로, 감사용 동선 확인은 관리자 권한이
--   없는 계정으로 해야 한다(사양서 §7과 동일 주의).
--
-- ▶ 롤백
--   DROP TRIGGER IF EXISTS trg_application_deadline_guard ON public.applications;
--   DROP FUNCTION IF EXISTS public.check_application_deadline();
--
-- ▶ 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.check_application_deadline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_deadline   date;
  v_today_kst  date;
BEGIN
  -- 1. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (익명 anon 쓰기는 applications_insert_own 행 단위 보안 정책에서 이미 차단되어
  --     여기까지 도달하지 못한다 — 위 파일 상단 주석 참조)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 2. 관리자 — 현재는 관리자 대리 응모 경로가 없어 도달하지 않는 대비 조항.
  --    향후 관리자 대리 응모 기능이 생겨도 막히지 않도록 미리 둔다.
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 3. 캠페인 마감일 조회. NULL(무기한 캠페인)이면 통과.
  SELECT c.deadline
    INTO v_deadline
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  IF v_deadline IS NULL THEN
    RETURN NEW;
  END IF;

  -- 4. 일본 시각(Asia/Tokyo) 기준 오늘 날짜가 마감일을 넘었는지 판정.
  --    마감일 당일 23:59:59(일본 시각)까지 허용 — 시각 없는 date 컬럼이라
  --    "당일 끝까지"가 유일하게 자연스러운 해석(연령 정책 calc_age_kst 와 동일 표현).
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  IF v_today_kst <= v_deadline THEN
    RETURN NEW;
  END IF;

  -- 머신 판독용 코드 접두어 — dev/js/ui.js friendlyErrorJa() 가 이 문자열을 정규식으로
  -- 매칭해 일본어/한국어 안내 문구로 치환한다(post_already_approved 와 동일 계약).
  RAISE EXCEPTION 'recruit_deadline_passed: 모집 기간이 종료되었습니다'
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION public.check_application_deadline() IS
  '[272] 모집 마감 응모 차단 트리거 함수. BEFORE INSERT ON applications.
   판정: auth.uid() NULL 통과 → is_admin() 통과 → campaigns.deadline NULL 통과 →
   (now() AT TIME ZONE ''Asia/Tokyo'')::date <= deadline 이면 통과, 아니면
   ''recruit_deadline_passed: ...'' 예외(ERRCODE P0001).
   사양서 docs/specs/2026-07-29-deadline-server-enforcement.md 1단계.';

DROP TRIGGER IF EXISTS trg_application_deadline_guard ON public.applications;
CREATE TRIGGER trg_application_deadline_guard
  BEFORE INSERT ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.check_application_deadline();

COMMIT;

-- ============================================================
-- 검증 쿼리 (SQL Editor — 아래를 1단계씩 순서대로 실행)
-- ============================================================
--
-- 1단계 — 함수·트리거 존재 확인:
--   SELECT p.proname, p.prosecdef,
--          t.tgname, t.tgenabled
--     FROM pg_proc p
--     JOIN pg_trigger t ON t.tgfoid = p.oid
--    WHERE p.proname = 'check_application_deadline'
--      AND p.pronamespace = 'public'::regnamespace;
--   → 1행, prosecdef=true, tgname='trg_application_deadline_guard', tgenabled='O'
--
-- 2단계 — 트리거 실행 순서 확인 (알파벳순 재확인):
--   SELECT tgname
--     FROM pg_trigger
--    WHERE tgrelid = 'public.applications'::regclass
--      AND tgname LIKE 'trg_%'
--      AND NOT tgisinternal
--    ORDER BY tgname;
--   → trg_age_policy, trg_application_deadline_guard,
--     trg_monitor_auto_approve, trg_monitor_slots_guard 순서로 4행 기대
--
-- 3단계 — 실제 차단 확인 (안전한 방법: 트랜잭션을 커밋하지 않고 롤백)
--   ⚠️ 아래는 반드시 BEGIN ~ ROLLBACK 사이에서만 실행할 것(운영 데이터에 남기지 않기 위함).
--   -- 3-1) 마감일이 지난 캠페인 하나를 확인해 둔다 (없으면 3-2 전에 개발 캠페인의
--   --      deadline 을 어제 날짜로 UPDATE 해서 임시로 만들어도 됨 — 이 경우도 ROLLBACK 안에서):
--   --   SELECT id, title, deadline FROM public.campaigns
--   --    WHERE deadline < (now() AT TIME ZONE 'Asia/Tokyo')::date
--   --    LIMIT 1;
--   --
--   -- 3-2) 그 캠페인 id 와, 그 캠페인에 아직 응모하지 않은 테스트 인플루언서 id 로:
--   BEGIN;
--     -- SET LOCAL ROLE 등으로 실제 인플루언서 세션을 흉내내기 어려우면,
--     -- auth.uid() 를 흉내내는 대신 서비스 키 SQL Editor 특성상 아래처럼
--     -- SECURITY DEFINER 우회 없이 직접 검증하려면 반드시 그 인플루언서로
--     -- 로그인한 브라우저(또는 anon+JWT)에서 실제 응모를 시도해야 한다.
--     -- SQL Editor 는 관리자(서비스 키) 세션이라 auth.uid() 가 NULL 로 통과되어
--     -- 이 트리거를 재현하지 못한다 — 이 트리거는 반드시 실제 인플루언서 로그인
--     -- 세션(개발서버 브라우저)에서 마감 지난 캠페인에 응모를 시도해 확인할 것.
--   ROLLBACK;
--
--   대안(권장) — SQL Editor 로 안전하게 재현하려면 auth.uid() 를 흉내내는 로컬 설정을 쓴다:
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message)
--     VALUES ('<테스트 인플루언서 auth_id>'::uuid, '<마감 지난 캠페인 id>'::uuid, '검증용');
--     -- 기대: ERROR: recruit_deadline_passed: 모집 기간이 종료되었습니다
--   ROLLBACK;
--   ⚠️ set_config('request.jwt.claims', ...) 는 PostgREST 가 세팅하는 값을 SQL Editor 에서
--      흉내내는 것 — auth.uid() 는 이 클레임의 'sub' 값을 읽으므로 위 방식으로 재현 가능.
--      실행 후 반드시 ROLLBACK 해서 검증용 응모 행이 남지 않게 할 것.
-- ============================================================
