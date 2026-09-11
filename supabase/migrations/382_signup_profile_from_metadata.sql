-- ============================================================
-- 382_signup_profile_from_metadata.sql
-- 가입 폼에 적은 값이 회원 행에 실제로 저장되게 한다 (설계 1)
-- 사양서: docs/specs/2026-08-25-signup-consent-not-recorded.md (설계 1)
-- 선행: 014(가입 트리거 원본) · 381(과거분 소급 — **운영 적용 완료 2026-08-25**)
--
-- 🔴 **381 이 운영에 적용된 뒤에만 이 파일을 넣는다.** 순서가 뒤집히면 이 트리거가
--    만드는 **진짜 기록**과 381 의 소급분이 섞여 되돌릴 수 없다. (381 적용 완료 확인함)
--
-- ── 무엇이 문제였나 ────────────────────────────────────────────
--   가입 화면은 이름·생년월일·성별·동의 시각을 **폼에서 다 받아 놓고**,
--   그 값을 회원 행에 넣는 호출(`upsertInfluencer`)에 **한 번도 도달하지 못했다.**
--   `dev/js/auth.js` 가 이메일 확인 대기 상태(`!data.session`)면 안내 화면을 띄우고
--   **그 자리에서 return** 하는데, **운영은 이메일 확인이 필수**라 항상 그 길로 빠진다.
--   (개발서버는 확인이 꺼져 있어 저장이 됐다 — 그래서 두 서버의 상태가 달랐다)
--
-- ── 왜 트리거인가 (다른 후보를 뺀 이유) ────────────────────────
--   ⚠️ **「가입 직후 화면에서 저장」은 성립하지 않는다.** 그 시점에는 로그인 세션이
--      없고, `influencers` 쓰기 정책은 본인 확인을 요구한다. 화면을 아무리 고쳐도
--      막힌다.
--   ⚠️ **「확인 후 첫 로그인에 채운다」도 단독으로는 성립하지 않는다.** 그때는 폼 값이
--      이미 사라진 뒤라 **채울 재료가 없다.**
--   → 남는 경로는 **계정이 만들어지는 순간 서버에서 넣는 것** 하나다. 폼 값은
--      `signUp` 의 `options.data` 로 넘겨 `auth.users.raw_user_meta_data` 에 실린다.
--
-- ── 🔴 개인정보를 두 곳에 남기지 않는다 ────────────────────────
--   `raw_user_meta_data` 는 **개인정보를 담는 자리가 하나 느는 것**이다. 그런데
--   탈퇴 파기(352)는 그 안에서 **`email` 키 하나만** 바꾼다 — 이름·생년월일을 거기
--   두면 **탈퇴해도 그 사본이 남는다.**
--   → 그래서 이 트리거는 값을 옮긴 **직후 그 자리를 지운다.** 352 를 고쳐 따라가게
--      하는 것보다(그 함수는 120줄이고 이미 복잡하다) **애초에 안 남기는 쪽**이 안전하다.
--   ⚠️ `email` 키는 **남긴다** — 352 가 그것을 바꾸는 것을 전제로 짜여 있고, 인증
--      서비스도 그 값을 쓴다. 우리가 넣은 키만 지운다.
--
-- ── 미확인 계정 ────────────────────────────────────────────────
--   이 트리거는 **계정이 만들어질 때**(확인 메일을 열기 전) 돈다. 그래서 확인하지
--   않은 사람에게도 동의 시각이 남는다. **그래도 넣는다** — 그 사람이 가입 폼에서
--   동의를 누른 것은 **실제로 일어난 일**이고, 안 적으면 지금과 같은 「받았는데
--   기록이 없는」 상태가 반복된다.
--   🔴 **다만 그 사람을 회원으로 세면 안 된다**(2026-08-26 사용자 결정).
--      그건 이 파일이 아니라 **설계 2(인증 여부를 아는 값)** 가 담당한다.
--      ⚠️ 설계 2 없이 이 파일만 넣으면 그 결정이 지켜지지 않는다.
--
-- ── 소급분과 새 기록은 갈린다 ──────────────────────────────────
--   381 의 소급분은 `terms_agreed_at = created_at` 이 **정확히 같다**(같은 칸을 복사).
--   이 트리거가 넣는 값은 **동의 시각(폼)** 과 **가입 시각(계정 생성)** 이 서로 다른
--   출처라 일치하지 않는다. 그래서 381 의 되돌리기 조건(`= created_at`)은 이 트리거가
--   만든 기록을 **건드리지 않는다.**
--   ⚠️ 다만 **우연에 기대는 구분**이다 — 되돌릴 일이 생기면 건수를 먼저 세어 볼 것.
--
-- 이 파일이 만드는 것:
--   [A] handle_new_user() 재정의 — 메타데이터에서 값을 꺼내 넣고, 그 자리를 지운다
-- ============================================================

BEGIN;

-- ── [A-2] 형변환 도우미 — 형식이 깨진 값이 가입을 깨뜨리지 않게 ──────
--   🔴 이 둘이 없으면 메타데이터에 이상한 문자열이 들어왔을 때 **형변환 오류로
--      트리거가 실패하고, 그러면 계정 생성 자체가 롤백된다** — 가입이 통째로 막힌다.
--      값 하나가 깨졌다고 가입을 막는 쪽이 훨씬 나쁘다.
--   🔴 **트리거보다 먼저 만든다.** 뒤에 두면 트리거를 갈아 끼운 시점부터 도우미가
--      생기기 전까지 **가입이 전부 실패하는 구간**이 생긴다(함수 본문은 호출 시점에
--      해석되므로, 없는 함수를 부르면 그때 터진다).
--   ⚠️ 선언은 **STABLE** 이다 — 문자열을 시각·날짜로 바꾸는 일은 데이터베이스의
--      시간대·날짜 형식 설정에 의존하므로 IMMUTABLE 이 아니다.

CREATE OR REPLACE FUNCTION public._safe_ts(p text)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
  RETURN p::timestamptz;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public._safe_date(p text)
RETURNS date
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
BEGIN
  IF p IS NULL OR btrim(p) = '' THEN RETURN NULL; END IF;
  RETURN p::date;
EXCEPTION WHEN others THEN
  RETURN NULL;
END;
$$;

-- 🔴 실행 권한 — 내부 전용이다. 공개 키로 부를 수 있으면 안 된다.
--    ⚠️ 회수는 **두 방향 다** 해야 한다(마이그레이션 369·370 의 교훈) —
--       PUBLIC 부여와 역할별 부여는 서로를 대신하지 못한다.
REVOKE ALL ON FUNCTION public._safe_ts(text)   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._safe_date(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._safe_ts(text)   TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public._safe_date(text) TO postgres, service_role;


-- ── [A] handle_new_user() 재정의 (베이스 014) ────────────────────
--   ⚠️ 트리거 연결(`on_auth_user_created`)은 **다시 만들지 않는다.** 014 가 건 것을
--      그대로 쓴다 — 함수만 바꿔 끼운다(`CREATE OR REPLACE` 라 실행 권한도 보존).
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  m jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
BEGIN
  -- ⚠️ 값이 없으면 NULL 이 들어간다 — 014 와 같은 결과다. 화면이 아직 안 보내는
  --    동안에도(배포 순서상 그런 구간이 있다) 가입이 깨지지 않는다.
  -- ⚠️ 시각·날짜는 문자열로 오므로 형변환한다. 형식이 깨진 값이 오면 가입 전체가
  --    실패하므로, 아래 [A-2] 에서 안전하게 변환한다.
  INSERT INTO public.influencers (
    id, email, created_at,
    name, name_kanji, name_kana,
    birthdate, gender,
    terms_agreed_at, privacy_agreed_at, age_consent_at,
    marketing_opt_in, marketing_agreed_at
  )
  VALUES (
    NEW.id,
    NEW.email,
    -- 가입 시각은 **계정 생성 시각**을 쓴다(014 는 now() 였다). 트리거가 도는 시각과
    -- 계정 시각은 거의 같지만, 원본을 쓰는 편이 정확하다.
    COALESCE(NEW.created_at, now()),
    NULLIF(m->>'name', ''),
    NULLIF(m->>'name_kanji', ''),
    NULLIF(m->>'name_kana', ''),
    public._safe_date(m->>'birthdate'),
    -- 🔴 성별은 허용 목록으로 거른다 — 그 칸에 제약(180)이 걸려 있어, 목록 밖 값이
    --    오면 제약 위반으로 **가입이 통째로 롤백된다.** `signUp` 은 공개 키로 부를 수
    --    있어 화면 드롭다운을 거치지 않은 값이 올 수 있다.
    --    ⚠️ 위 `_safe_*` 도우미로는 이게 안 걸린다 — 형변환이 아니라 제약 위반이다.
    CASE WHEN m->>'gender' IN ('male','female','other','undisclosed')
         THEN m->>'gender' ELSE NULL END,
    public._safe_ts(m->>'terms_agreed_at'),
    public._safe_ts(m->>'privacy_agreed_at'),
    -- 🔴 생년월일·성별 수집 동의 시각도 함께 넣는다 — **개인정보 동의와 같은 시각.**
    --    근거: 개인정보처리방침 §2.1 표가 생년월일·성별을 **「회원가입 · 필수」**
    --    수집 항목으로 적고 있다(2026-07-22 시행, 한국어·일본어 양판). 즉 가입 때
    --    받는 그 동의가 곧 이 수집 동의다.
    --    ⚠️ 안 넣으면 **새 가입자에게는 이 값이 영영 안 채워진다** — 응모 화면의
    --    연령 확인 절차는 「생년월일·성별이 비었을 때」만 뜨는데, 이제 가입 순간
    --    둘 다 채워져 그 절차가 한 번도 안 뜬다(2026-08-26 검토 지적).
    public._safe_ts(m->>'privacy_agreed_at'),
    -- ⚠️ 참·거짓도 형변환이 터질 수 있다(예: 'yes'). 값이 정확히 'true' 일 때만
    --    참으로 보고, 그 밖에는 거짓으로 둔다 — 마케팅 동의는 **선택**이라
    --    애매하면 안 받은 것으로 두는 쪽이 맞다.
    (lower(COALESCE(m->>'marketing_opt_in', '')) = 'true'),
    public._safe_ts(m->>'marketing_agreed_at')
  )
  ON CONFLICT (id) DO NOTHING;

  -- 🔴 옮긴 값은 계정 메타데이터에서 지운다 — 개인정보를 두 곳에 남기지 않는다.
  --    `email` 키는 남긴다(352 파기와 인증 서비스가 그 값을 쓴다).
  UPDATE auth.users
     SET raw_user_meta_data = (COALESCE(raw_user_meta_data, '{}'::jsonb)
                                 - 'name' - 'name_kanji' - 'name_kana'
                                 - 'birthdate' - 'gender'
                                 - 'terms_agreed_at' - 'privacy_agreed_at'
                                 - 'marketing_opt_in' - 'marketing_agreed_at')
   WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.handle_new_user() IS
  '[014+382] 계정이 만들어질 때 회원 행을 만든다. 382 부터 가입 폼 값
   (이름·생년월일·성별·동의 시각)을 raw_user_meta_data 에서 꺼내 함께 넣고,
   개인정보를 두 곳에 남기지 않도록 그 자리를 지운다(email 키는 남긴다).
   ⚠️ 미확인 계정에도 값이 들어간다 — 회원 수에서 빼는 것은 설계 2 소관.';

COMMIT;

-- ── 적용 후 확인 ─────────────────────────────────────────────────
-- 🔴 SQL 편집기로는 이 트리거를 제대로 확인할 수 없다 — 실제 가입 화면에서
--    시험 계정을 만들어 봐야 한다(개발서버는 이메일 확인이 꺼져 있으므로,
--    **운영과 같은 조건**을 보려면 확인 대기 상태를 만들어야 한다).
--
-- 1) 함수가 바뀌었는지
-- SELECT prosrc LIKE '%raw_user_meta_data%' AS updated
--   FROM pg_proc WHERE proname = 'handle_new_user';
--
-- 2) 시험 가입 뒤 — 값이 들어갔는지 + 메타데이터가 비었는지
-- SELECT i.email, i.name_kana, i.birthdate, i.terms_agreed_at,
--        (u.raw_user_meta_data ? 'birthdate') AS meta_leftover
--   FROM public.influencers i JOIN auth.users u ON u.id = i.id
--  WHERE i.email = '<시험 계정>';
--   기대: 값이 채워지고 meta_leftover = false
--
-- 3) 소급분과 갈리는지
-- SELECT count(*) FILTER (WHERE terms_agreed_at = created_at) AS same_as_created
--   FROM public.influencers WHERE created_at > now() - interval '1 hour';
--   기대: 0 (새 가입은 동의 시각과 가입 시각이 서로 다른 출처라 일치하지 않는다)
