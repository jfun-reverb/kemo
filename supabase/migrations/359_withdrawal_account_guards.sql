-- ============================================================
-- 359_withdrawal_account_guards.sql
--
-- 회원 탈퇴 — 작업 8 「로그인 차단」 2/2 (실제 차단 장치)
--   358 = 판정 함수 (**반드시 먼저 적용**)
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 8」·Q4
--
-- ============================================================
-- ① 「로그인 차단」이라는 말이 실제로 뜻하는 것 셋
-- ============================================================
--   ㄱ **새 로그인** — 352 가 이미 막았다(로그인 계정 이메일을 자리표시 주소로 바꾼다)
--   ㄴ **이미 열려 있는 세션** — 화면이 부팅할 때 로그아웃시킨다(이 묶음의 화면 몫)
--   ㄷ **쓰기** — 이 파일. 화면을 안 거치고 개발자 도구로 직접 불러도 막힌다
--
--   🔴 ㄴ만으로는 부족하다 — 화면 로그아웃은 **평범한 사용자만** 막는다.
--     서버 차단이 최종 방어선이다.
--
-- ============================================================
-- ② 무엇을 막고 무엇을 안 막나 — 실제 피해 순서로 골랐다
-- ============================================================
--   | 순위 | 경로 | 안 막으면 |
--   |---|---|---|
--   | 1 🔴 | **프로필 수정**(`influencers`) | **파기가 무효가 된다** — 352 가 비운 18개 칸을 회원이 마이페이지에서 그대로 다시 채운다. 「파기했다」는 방침 약속과 실제가 어긋난다 |
--   | 2 🔴 | **응모**(`applications`) | 탈퇴 확정자가 새 캠페인에 응모 → 승인되면 결과물·정산까지 이어진다 |
--   | 3 🟡 | **행사 예약**(`event_tickets`) | 정원이 한정된 팝업 좌석이 죽는다. ⚠️ **되살리기는 수정이라 삽입 전 검사를 우회**하고, 확정 이후 만든 예약은 배치(350 section 0)가 활성 신청만 봐서 **아무도 안 지운다** |
--
--   **안 막는 것 — 응모건 메시지 발송.** 앱 안 문의 창구가 **아직 없어서**(작업 2 미착수),
--   여기를 막으면 탈퇴 절차 중인 회원이 운영팀에 닿을 수단이 **0개**가 된다. 「눌러도 아무
--   데도 못 가는 막다른 길」은 2026-05-22 에 이미 한 번 만든 실수다.
--   ⚠️ **이건 구멍이다** — 창구가 생기는 작업 2 시점에 다시 판단할 것.
--
--   **안 막는 것 — 응모 취소.** `cancel_application` 은 수정이라 애초에 삽입 전 검사에
--   안 걸린다. 탈퇴 확정자가 남은 응모를 취소하는 것은 막을 이유가 없다.
--
-- ============================================================
-- ③ ★ 통과해야 하는 것 — 하나라도 막으면 파기가 통째로 실패한다
-- ============================================================
--   세 장치 모두 맨 앞에 **두 개의 통과 조항**을 둔다(326 의 형태 그대로):
--
--   `auth.uid() IS NULL`  — 예약 실행·서비스 키. 🔴 **이게 없으면 352 의 파기가
--       `influencers` 를 비우다 자기 자신에게 막히고, 확정 전이가 무한 롤백된다.**
--   `is_admin()`          — 관리자. 🔴 **이게 없으면 관리자를 겸한 회원이 영구 반신불수가
--       된다** — 352 가 그런 계정의 파기를 거부하므로(`admin_account_excluded`) 그 사람은
--       `scheduled` + 예정일 경과 상태로 **영원히 남는데**, 차단만 걸리면 탈퇴가 확정되지도
--       않은 채 응모·프로필 수정이 영구히 막힌다.
--
--   ⚠️ 행사 장치는 조건을 두 개 더 둔다:
--     ㄱ **새 상태가 `confirmed`·`waitlist` 일 때만** 본다 → 배치의 취소
--        (`_withdrawal_cancel_event_ticket`)·본인 취소·관리자 취소가 자연 통과
--     ㄴ **대기자 승격(`waitlist` → `confirmed`)은 무조건 통과** → 남의 취소가 제3자
--        때문에 막히는 것을 방지(아래 [C] 본문의 긴 주석 참조)
--   ⚠️ **현장 입장 확인(`check_in_ticket`)은 ㄱ 으로 빠지지 않는다** — 그 함수는 입장
--     시각과 확인 횟수만 바꾸고 상태는 `confirmed` 그대로 두기 때문이다. 그쪽은
--     **관리자 통과 조항**으로 지나간다. 나중에 조건을 손댈 때 「입장 확인은 상태
--     필터로 빠진다」고 잘못 믿지 말 것.
--
-- ============================================================
-- ④ 트리거 이름을 `trg_account_withdrawn_guard` 로 지은 이유
-- ============================================================
--   `applications` 의 트리거는 **이름 알파벳 순**으로 실행된다:
--     trg_account_withdrawn_guard(본 파일) → trg_age_policy → trg_application_deadline_guard
--     → trg_application_insert_status_guard → trg_monitor_*
--
--   **가장 먼저**여야 하는 이유 — 352 가 생년월일도 비우므로, 탈퇴 확정자가 응모하면
--   연령 정책(180)이 먼저 걸려 **「연령 미달」이라는 엉뚱한 이유**가 뜬다. 마감보다 앞이어야
--   하는 것도 같은 이유다(272 가 마감을 정원보다 먼저 오게 이름을 지은 것과 같은 판단).
--
-- ============================================================
-- ⑤ 거부 코드 `account_withdrawn`
-- ============================================================
--   `RAISE EXCEPTION 'account_withdrawn: …' USING ERRCODE = 'P0001'` — 272·326 과 같은 형태.
--   ⚠️ 화면 등록 **두 곳이 한 세트**다(둘 중 하나만 하면 반쪽):
--     ㄱ `dev/js/ui.js` 의 오류 사전 — 안 넣으면 「권한이 없습니다」로 뭉개진다
--     ㄴ `dev/lib/shared.js` 의 정상 거부 목록 — 안 넣으면 차단될 때마다 관리자 오류 로그의
--        「미해결」 배지가 오른다(2026-08-11 에 비밀번호 재사용으로 실제로 다섯 번 쌓였다)
--
-- ============================================================
-- ⑥ 되돌리기
-- ============================================================
--   DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.event_tickets;
--   DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.influencers;
--   DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.applications;
--   DROP FUNCTION IF EXISTS public.check_account_withdrawn_event_ticket();
--   DROP FUNCTION IF EXISTS public.check_account_withdrawn_influencer();
--   DROP FUNCTION IF EXISTS public.check_account_withdrawn_application();
--   기존 함수를 하나도 재정의하지 않으므로 이것으로 완전히 되돌아간다.
--
-- ⚠️ **적용 순서: 358 → 359.** 반대면 없는 판정 함수를 불러 첫 쓰기에서 터진다.
-- ============================================================

BEGIN;

-- ============================================================
-- [A] 응모 — 삽입 전
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_account_withdrawn_application()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  -- 통과 ① 예약 실행·서비스 키
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 통과 ② 관리자 (위 헤더 ③ — 관리자 겸직 회원을 구하는 조항)
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF public._withdrawal_account_blocked(NEW.user_id) THEN
    RAISE EXCEPTION 'account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.check_account_withdrawn_application() IS
  '[359] 탈퇴가 확정됐거나 예정일이 지난 회원의 새 응모를 막는다. 판정은 358 의 '
  '_withdrawal_account_blocked() 하나(단일 소스). 예약 실행·관리자는 통과.';

DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.applications;
CREATE TRIGGER trg_account_withdrawn_guard
  BEFORE INSERT ON public.applications
  FOR EACH ROW EXECUTE FUNCTION public.check_account_withdrawn_application();

-- ============================================================
-- [B] 프로필 — 수정 전
--
--   🔴 **이 장치가 이 파일에서 가장 중요하다.** 없으면 파기가 무효가 된다.
--
--   ⚠️ 352 의 파기도 이 표를 수정한다 — 예약 실행(auth.uid() 없음) 또는 관리자 수동
--     호출(is_admin())로 들어오므로 위 통과 조항 둘이 그것을 살린다. **통과 조항을
--     지우면 파기가 자기 자신에게 막혀 확정이 무한 롤백된다.**
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_account_withdrawn_influencer()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF public._withdrawal_account_blocked(NEW.id) THEN
    RAISE EXCEPTION 'account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.check_account_withdrawn_influencer() IS
  '[359] 탈퇴가 확정됐거나 예정일이 지난 회원이 자기 프로필을 다시 채우는 것을 막는다. '
  '🔴 이것이 없으면 352 가 비운 18개 칸을 회원이 마이페이지에서 되살려 **파기가 무효**가 '
  '된다. ⚠️ 통과 조항(예약 실행·관리자)을 지우면 352 의 파기 자체가 이 장치에 막혀 '
  '확정이 무한 롤백된다.';

DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.influencers;
CREATE TRIGGER trg_account_withdrawn_guard
  BEFORE UPDATE ON public.influencers
  FOR EACH ROW EXECUTE FUNCTION public.check_account_withdrawn_influencer();

-- ============================================================
-- [C] 행사 예약 — 삽입·수정 전
--
--   ⚠️ **수정도 걸어야 한다** — 취소한 예약을 되살리는 경로(330)는 새 행을 만들지 않고
--     기존 행을 되살린다. 삽입만 걸면 그대로 우회된다.
--   ⚠️ 조건을 「새 상태가 confirmed·waitlist 일 때만」으로 좁혀, 취소로 가는 수정
--     (배치·본인·관리자)을 자연 통과시킨다.
--   ⚠️ **현장 입장 확인은 이 필터로 안 빠진다** — 그 함수는 입장 시각과 확인 횟수만
--     바꾸고 상태는 confirmed 그대로다. 관리자 통과 조항으로 지나간다.
--
--   ⚠️ 예약 함수(330)는 실패를 예외가 아니라 `{ok:false, reason}` 으로 돌려주는 계약인데
--     이 장치는 예외를 던진다 — **계약이 어긋난다.** 도달이 극히 드문 최종 방어선이고,
--     8/28~30 행사에서 실제로 쓰일 222줄짜리 함수를 지금 재정의하는 위험이 더 크다고
--     판단해 감수한다. **이 어긋남을 여기 적어 둔다.**
-- ============================================================
CREATE OR REPLACE FUNCTION public.check_account_withdrawn_event_ticket()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
BEGIN
  -- 취소로 가는 것은 언제나 통과 — 좌석을 비우는 방향이라 막을 이유가 없다
  IF NEW.status NOT IN ('confirmed', 'waitlist') THEN
    RETURN NEW;
  END IF;

  -- 🔴 대기자 승격(waitlist → confirmed)은 **무조건 통과시킨다.**
  --
  --   이 수정은 **승격되는 사람이 부르는 것이 아니다.** 다른 회원이 자기 예약을 취소할
  --   때, 그 트랜잭션 안에서 대기 1번을 끌어올리며 일어난다. 그래서 이 자리에 서 있는
  --   로그인 정보는 **취소한 사람**의 것이고, 검사 대상은 **승격되는 제3자**다.
  --
  --   막으면 이렇게 된다:
  --     ① 회원 A 가 자기 예약을 취소한다
  --     ② 대기 1번이 마침 탈퇴 절차 중인 B 였다
  --     ③ 이 장치가 B 를 이유로 예외를 던진다
  --     ④ 예외가 **A 의 취소까지 통째로 되돌린다**
  --     ⑤ 다시 눌러도 순번은 늘 같은 B 라 **영구히 막힌다**
  --   A 는 아무 잘못이 없는데 남의 탈퇴 때문에 자기 예약을 못 버리게 된다.
  --   (승격 UPDATE 는 예외 처리로 감싸여 있지 않아 함수 전체가 롤백된다 — 288 실측)
  --
  --   통과시켜서 생기는 일은 훨씬 가볍다 — 탈퇴 중인 대기자가 좌석을 잠시 차지하지만,
  --   **다음 새벽 배치(350 section 0)가 그 티켓을 취소하고 자리를 다음 사람에게 넘긴다.**
  --   하루 안에 정리되는 문제와 영구히 막히는 문제를 저울질한 결과다.
  --
  --   ⚠️ **이 조항이 구멍이 되지 않는 이유** — `event_tickets` 에는 직접 쓰기 정책이
  --     없어(282) 회원이 자기 티켓을 스스로 승격시킬 방법이 없다. 승격은 288 의 공용
  --     함수 안에서만 일어난다.
  --   ⚠️ **되살리기(취소 후 재예약)는 여기 안 걸린다** — 그건 `cancelled → confirmed`
  --     라 아래 검사를 그대로 받는다. 막아야 하는 것이 그쪽이다.
  IF TG_OP = 'UPDATE'
     AND OLD.status = 'waitlist'
     AND NEW.status = 'confirmed' THEN
    RETURN NEW;
  END IF;

  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF public._withdrawal_account_blocked(NEW.influencer_id) THEN
    RAISE EXCEPTION 'account_withdrawn: 탈퇴 절차가 진행 중인 계정입니다'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.check_account_withdrawn_event_ticket() IS
  '[359] 탈퇴가 확정됐거나 예정일이 지난 회원의 행사 예약(신규·되살리기)을 막는다. '
  '⚠️ 수정에도 거는 이유 — 되살리기는 새 행을 만들지 않아 삽입 전 검사를 우회한다. '
  '⚠️ 새 상태가 confirmed·waitlist 일 때만 본다 — 취소로 가는 수정(배치·본인)과 현장 '
  '입장 확인은 통과해야 한다. ⚠️ 예약 함수(330)의 반환 계약(예외 대신 {ok:false})과 '
  '어긋나지만, 그 함수를 재정의하는 위험이 더 크다고 판단해 감수한 것이다.';

DROP TRIGGER IF EXISTS trg_account_withdrawn_guard ON public.event_tickets;
CREATE TRIGGER trg_account_withdrawn_guard
  BEFORE INSERT OR UPDATE ON public.event_tickets
  FOR EACH ROW EXECUTE FUNCTION public.check_account_withdrawn_event_ticket();

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
--
-- 🔴 **[V5]·[V6]·[V7] 이 이 파일에서 가장 중요하다** — 통과 조항이 제대로 걸렸는지
--    확인하는 단계다. 여기서 막히면 **파기가 통째로 실패하고 확정이 무한 롤백된다.**
-- ⚠️ SQL 편집기는 서비스 키라 `auth.uid()` 가 비어 **모든 차단이 통과 조항 ①에서 끝난다**
--    — 차단 자체는 로그인한 브라우저에서만 재현된다(마이그레이션 272·332 와 같은 함정).
-- ============================================================
/*

-- ── SQL 편집기 (구조·통과 조항 확인) ────────────────────────

-- [V0] 장치 3개가 걸렸는가
SELECT c.relname AS 표, t.tgname AS 장치, t.tgenabled AS 활성
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE t.tgname = 'trg_account_withdrawn_guard'
 ORDER BY c.relname;
-- 기대: 3행 (applications · event_tickets · influencers) · 전부 'O'

-- [V1] ★ 응모 장치가 연령·마감보다 **먼저** 실행되는가 (이름 알파벳 순)
SELECT t.tgname
  FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
 WHERE c.relname = 'applications' AND NOT t.tgisinternal
 ORDER BY t.tgname;
-- 기대: trg_account_withdrawn_guard 가 **맨 위**

-- [V2] ★ 예약 실행이 막히지 않는가 — 파기가 자기 자신에게 막히면 확정이 무한 롤백된다
SELECT public.advance_withdrawal_states();
-- 기대: 오류 없이 {"ok":true, ...} (SQL 편집기는 auth.uid() 가 없어 통과 조항 ①로 통과)

-- ── 로그인한 브라우저 (차단은 여기서만 재현된다) ─────────────

-- [V3] ★ 무회귀 — **탈퇴 신청이 없는 평범한 회원**
--   응모·프로필 저장·행사 예약이 **전부 종전대로** 되는지.
--   🔴 이게 깨지면 전 회원이 막힌 것이다 — 즉시 되돌릴 것

-- [V4] 확정(done) 계정에서
--   await db.from('influencers').update({city:'테스트'}).eq('id', '<본인 uuid>')
--   기대: account_withdrawn 오류
--   응모 삽입·행사 예약도 같은 오류

-- [V5] ★ 관리자 계정으로 인플루언서 상태 수정(인증·블랙리스트 등)
--   기대: **막히지 않는다**(통과 조항 ②). 막히면 관리자 화면이 통째로 죽는다

-- [V6] ★ 관리자를 겸한 회원이 예정일 경과 상태일 때
--   그 계정으로 응모·프로필 수정 → **막히지 않아야 한다**
--   (352 가 그런 계정의 파기를 거부하므로 영원히 이 상태다 — 막으면 영구 반신불수)

-- [V7] ★ 예정일 경과 + 확정 전 계정에서 **탈퇴 취소**
--   await db.rpc('cancel_withdrawal', {})
--   기대: **성공**한다. cancel_withdrawal 은 withdrawal_requests 만 건드리므로
--         이 장치들과 무관하다. 🔴 막히면 회원이 탈퇴를 되돌릴 수 없다

-- [V8] 확정 계정에서 남은 응모 취소
--   기대: **된다**(취소는 수정이라 응모 삽입 장치에 안 걸린다 — 의도)

-- [V9] 행사 — 확정 계정에서 예약 취소
--   기대: **된다**(새 상태가 cancelled 라 첫 조항으로 통과)

-- [V10] 관리자 오류 로그 화면
--   위 거부들이 「미해결」 배지를 **올리지 않는지**
--   (올리면 dev/lib/shared.js 의 정상 거부 목록에 account_withdrawn 이 안 들어간 것)

*/
