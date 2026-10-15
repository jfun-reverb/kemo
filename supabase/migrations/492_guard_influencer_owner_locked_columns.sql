-- ============================================================
-- 492. 회원이 자기 행의 이메일·동의 시각·가입 시각을 직접 고칠 수 없게 한다
-- ============================================================
-- 전수조사(3차) ⑤-2·⑤-3 — docs/research/2026-09-28-codebase-audit-findings.md
--
-- ── 무엇이 문제였나 ────────────────────────────────────────
-- 회원 본인 수정 정책(313)은 `auth.uid() = id` 만 보고 **칸은 안 본다.** 화면에는 이 칸들을
-- 고치는 자리가 없지만, 회원이 자기 로그인 정보로 데이터베이스에 직접 요청을 보내면
-- (브라우저 개발자 도구) 아래 칸이 그대로 바뀐다.
--   · email — 재가입 차단 해시(361)·탈퇴 예정일 메일·홍보 메일이 이 칸을 쓴다.
--     로그인 이메일과 다른 값으로 바꾸면 재가입 차단을 피하거나 메일이 엉뚱한 곳으로 간다.
--     (탈퇴 시행일이 들어가는 순간부터 실제 문제)
--   · terms_agreed_at · privacy_agreed_at · marketing_agreed_at · age_consent_at — 동의의 법적 근거 기록
--   · created_at — 가입 시각(420 이 가입 순간만 지켰다)
--   · marketing_opt_in 을 직접 false → true — 동의 시각(marketing_agreed_at)을 남기는
--     resubscribe_marketing()(140)을 건너뛴다(특정전자메일법 동의 근거 누락)
--
-- ── 무엇을 막나 / 무엇을 남기나 ────────────────────────────
-- 막는 것(회원 본인이 **직접** 보낸 UPDATE 만):
--   위 다섯 칸의 변경(거부) · marketing_opt_in 켜기(거부) · age_consent_at 이 이미 있을 때의 변경(**조용히 옛 값 유지**)
-- 남기는 것:
--   · 나이 확인 창(application.js)의 age_consent_at **최초 기록** — 예전 가입자가 처음 응모할 때
--     비어 있던 칸을 채운다. 값은 **서버 시각으로 덮는다**(브라우저 시계를 믿지 않는다 — 420 과 같은 원칙)
--   · 마케팅 끄기(storage.js updateMarketingOptIn) — marketing_opt_in=false · marketing_unsubscribed_at 만 바꾼다
--   · 마이페이지 저장(mypage.js saveProfile) — 이 칸들을 보내지 않는다
--   · 로그인 때 프로필 구제(auth.js upsertInfluencer) — 행이 없을 때의 **삽입**이라 이 장치(UPDATE)와 무관.
--     ⚠️ 행이 이미 있는데 조회만 0건이면 충돌 경로(UPDATE)로 가 created_at 변경으로 거부된다 — 정상 흐름이 아니고
--     로그인은 진행된다(logAppError 로 남음). 오히려 가입 시각 덮어쓰기를 막는다.
--
-- ── 통과 판정이 398 과 다른 이유 (중요) ────────────────────
-- 398 은 `auth.uid() IS NULL` 과 `is_campaign_admin()` 으로 통과시켰다. 여기서는 그것으로 부족하다 —
-- 정당한 쓰기가 **회원 로그인 상태의 서버 함수 안**에서도 일어나기 때문이다
-- (resubscribe_marketing: auth.uid() = 회원 본인인데 marketing_agreed_at 을 바꾼다).
-- → 판정을 「누가 로그인했나」가 아니라 **「지금 어느 권한으로 실행 중인가」(current_user)** 로 한다.
--   · 회원이 직접 보낸 요청     → current_user = 'authenticated'  → 검사
--   · SECURITY DEFINER 함수 안  → current_user = 함수 소유자(postgres) → 통과
--   · 예약 실행·SQL 편집기·서비스 키 → 'postgres' / 'service_role' → 통과
-- 🔴 그래서 이 트리거 함수는 **SECURITY INVOKER** 여야 한다. DEFINER 로 바꾸면 current_user 가
--    늘 소유자가 되어 **아무것도 막지 못한다**(오류 없이 조용히 무력화).
-- 관리자가 화면에서 직접 고치는 경로는 지금 없지만 대비로 `is_admin()` 도 통과시킨다.
--   ⚠️ 그래서 **관리자를 겸한 회원은 자기 행에서도 이 보호를 받지 않는다**(의도 — 관리자 겸직은 탈퇴도 막혀 있다, 357).
--
-- ⚠️ 익명(anon)은 313 정책에 막혀 여기 도달하지 않는다.
-- ⚠️ 거부 문구는 한국어 고정 — 정상 화면에서는 나올 수 없는 오류다(직접 요청에만 뜬다).
-- ⚠️ 트리거 이름: influencers BEFORE UPDATE 에 이미 넷(059·180·359·398)이 있다. 이 트리거는
--    age_consent_at 하나만 값을 바꾸고(서버 시각) 나머지는 거부만 한다. 다른 트리거가 같은 칸을
--    건드리지 않아 실행 순서가 결과를 바꾸지 않는다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_influencer_owner_locked_columns()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- 회원이 직접 보낸 요청만 본다(위 「통과 판정」). 서버 함수·예약 실행·서비스 키는 통과.
  IF current_user <> 'authenticated' THEN
    RETURN NEW;
  END IF;
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  IF NEW.email               IS DISTINCT FROM OLD.email
  OR NEW.terms_agreed_at     IS DISTINCT FROM OLD.terms_agreed_at
  OR NEW.privacy_agreed_at   IS DISTINCT FROM OLD.privacy_agreed_at
  OR NEW.marketing_agreed_at IS DISTINCT FROM OLD.marketing_agreed_at
  OR NEW.created_at          IS DISTINCT FROM OLD.created_at
  OR (NEW.marketing_opt_in IS TRUE AND OLD.marketing_opt_in IS NOT TRUE)
  THEN
    RAISE EXCEPTION '이 항목은 회원 본인이 직접 변경할 수 없습니다.'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 연령 동의 시각 — 거부하지 않고 **조용히 바로잡는다**.
  --   · 비어 있었으면 최초 기록을 허용하되 값은 서버 시각
  --   · 이미 있으면 옛 값을 그대로 둔다
  --   ⚠️ 거부로 만들면 안 된다 — 가입 트리거(420)는 이 칸을 늘 채우지만 생년월일·성별은 범위 밖이면
  --      비워서, 「동의 시각은 있는데 나이 확인 창이 뜨는」 회원이 생긴다. 그 창(application.js)은
  --      age_consent_at 을 늘 보내므로 거부하면 그 회원은 **응모를 영영 못 한다**(492 검토 지적).
  IF OLD.age_consent_at IS NULL AND NEW.age_consent_at IS NOT NULL THEN
    NEW.age_consent_at := now();
  ELSIF OLD.age_consent_at IS NOT NULL THEN
    NEW.age_consent_at := OLD.age_consent_at;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_influencer_owner_locked_columns() IS
  '[492] 회원 본인의 직접 UPDATE 에서 email·동의 시각 4종·created_at 변경과 marketing_opt_in 켜기를 거부. '
  'age_consent_at 은 비어 있을 때 한 번만(서버 시각), 이미 있으면 조용히 옛 값 유지. 판정은 current_user=authenticated — '
  '🔴 SECURITY INVOKER 필수(DEFINER 면 조용히 무력화).';

-- 트리거 함수 — API 로 부를 일이 없다. 회수 방향 둘 다(369·370 규칙). 트리거 발동에는 실행 권한이 필요 없다.
REVOKE ALL ON FUNCTION public.guard_influencer_owner_locked_columns() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_influencer_owner_locked_columns() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_guard_influencer_owner_locked_columns ON public.influencers;
CREATE TRIGGER trg_guard_influencer_owner_locked_columns
  BEFORE UPDATE ON public.influencers
  FOR EACH ROW EXECUTE FUNCTION public.guard_influencer_owner_locked_columns();

COMMIT;

-- ------------------------------------------------------------
-- 검증
-- ------------------------------------------------------------
-- 🔴 SQL 편집기는 서비스 권한이라 **회원 판정을 그냥은 재현 못 한다**(272·332 와 같은 함정).
--    아래처럼 트랜잭션 안에서 역할과 로그인 정보를 흉내 내고 끝에 되돌린다.
--
-- [V1] 회원 흉내 — 막혀야 하는 것(하나씩, 매번 오류가 나야 한다)
-- BEGIN;
--   SELECT set_config('request.jwt.claims', json_build_object('sub', '<회원 id>', 'role', 'authenticated')::text, true);
--   SET LOCAL ROLE authenticated;
--   UPDATE public.influencers SET email = 'x@example.com' WHERE id = '<회원 id>';   -- 오류
-- ROLLBACK;
--   (terms_agreed_at = now() · created_at = now() · marketing_opt_in = true(꺼져 있는 회원) 도 같은 방식으로)
--
-- [V2] 회원 흉내 — 통과해야 하는 것
-- BEGIN;  (위 두 줄 동일)
--   UPDATE public.influencers SET name_kana = name_kana, marketing_opt_in = false WHERE id = '<회원 id>';  -- 통과
--   SELECT public.resubscribe_marketing();                                                             -- 통과(서버 함수 안)
-- ROLLBACK;
--
-- [V3] 실제 브라우저 — 마이페이지 저장 · 메일 수신 켜기/끄기 · (예전 가입자) 나이 확인 창 저장이 그대로 되는지
--
-- 되돌리기:
--   DROP TRIGGER IF EXISTS trg_guard_influencer_owner_locked_columns ON public.influencers;
--   DROP FUNCTION IF EXISTS public.guard_influencer_owner_locked_columns();
