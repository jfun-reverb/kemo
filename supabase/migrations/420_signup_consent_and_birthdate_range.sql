-- ============================================================
-- 420_signup_consent_and_birthdate_range.sql
-- 전수조사 2차(2026-09-02) 9-2(I-1, 중간) — 가입 동의 시각·생년월일에 범위 검사
--   docs/research/2026-09-02-codebase-audit-findings.md
--   docs/specs/2026-09-02-audit-remediation-plan.md
--
-- 베이스: 382 의 public.handle_new_user() (014 → 382 → 이 파일). 084 는 권한만 손댔다. 확인:
--   grep -ln "FUNCTION public.handle_new_user" supabase/migrations/*.sql
--
-- 무엇이 문제였나
--   382 는 가입 시각(created_at)은 「브라우저 시계를 믿지 않는다」며 서버 값을 쓰면서, 같은 폼에서
--   온 동의 시각 셋(약관·개인정보·마케팅)과 생년월일은 브라우저 값을 형변환만 하고 그대로 넣었다.
--   `signUp` 은 공개 키로 누구나 부를 수 있어 「2019년에 동의」·「2099-01-01 출생」 같은 값이
--   그대로 남을 수 있다. 동의 시각은 법적 근거이고, 생년월일은 연령 판정 근거다.
--
-- 무엇을 하나
--   도우미 둘(트리거보다 먼저 만든다 — 382 와 같은 이유):
--     _consent_ts_or_now(p text, ref timestamptz) — 값이 ref ±1일 안이면 그대로, 아니면 now()
--     _plausible_birthdate(p text)                — 1900-01-01 ~ 오늘(일본) 안이면 그대로, 아니면 NULL
--   handle_new_user() 가 그 둘을 쓴다. 마케팅 동의 시각은 **동의했을 때만** 넣는다(382 는 동의 안 했어도
--   값이 오면 저장했다 — 공개 키 임의 호출로 「동의 없는 동의 시각」이 생길 수 있었다). 그 밖의 본문은
--   382 와 같다(CREATE OR REPLACE — 014 의 트리거 연결·실행 권한 보존).
--   ⚠️ 「값이 아예 없음」도 now() 로 채우므로, 382 까지 남던 「동의 시각 NULL」이라는 진단 신호는 사라진다.
--      화면은 늘 값을 보내 정상 트래픽에서는 안 걸리는 경로다(검토 지적).
--   ⚠️ 동의 시각을 아예 created_at 으로 바꾸지 않은 이유 — 382 가 「소급분(381)은 동의 시각 = 가입
--      시각」이라는 표시로 신규 가입과 구분한다. 정상 브라우저 값은 그대로 두고 범위 밖만 고친다.
--   ⚠️ 화면(auth.js)은 그대로 둔다 — 화면이 값을 안 보내면 이 마이그레이션이 먼저 들어간 서버는
--      now() 로 채우고, 옛 서버는 NULL 을 남긴다. 배포 순서를 안 타게 서버만 바꾼다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._consent_ts_or_now(p text, ref timestamptz)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v timestamptz;
  r timestamptz := COALESCE(ref, now());
BEGIN
  v := public._safe_ts(p);
  IF v IS NULL THEN RETURN now(); END IF;
  IF v BETWEEN r - interval '1 day' AND r + interval '1 day' THEN RETURN v; END IF;
  RETURN now();
END;
$$;

COMMENT ON FUNCTION public._consent_ts_or_now(text, timestamptz) IS
  '[420] 가입 폼의 동의 시각 — 계정 생성 시각 ±1일 안이면 브라우저 값, 밖이거나 비었으면 now().
   내부 전용(가입 트리거).';

CREATE OR REPLACE FUNCTION public._plausible_birthdate(p text)
RETURNS date
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  d date;
BEGIN
  d := public._safe_date(p);
  IF d IS NULL THEN RETURN NULL; END IF;
  IF d < DATE '1900-01-01' OR d > (now() AT TIME ZONE 'Asia/Tokyo')::date THEN RETURN NULL; END IF;
  RETURN d;
END;
$$;

COMMENT ON FUNCTION public._plausible_birthdate(text) IS
  '[420] 가입 폼의 생년월일 — 1900-01-01 ~ 오늘(일본 시각) 안이면 그대로, 밖이면 NULL(연령 확인 절차가 다시 묻는다).
   내부 전용(가입 트리거).';

-- 382 의 _safe_* 와 같은 권한 — 트리거(소유자 권한)만 부른다.
REVOKE ALL ON FUNCTION public._consent_ts_or_now(text, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._consent_ts_or_now(text, timestamptz) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._consent_ts_or_now(text, timestamptz) TO postgres, service_role;
REVOKE ALL ON FUNCTION public._plausible_birthdate(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._plausible_birthdate(text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public._plausible_birthdate(text) TO postgres, service_role;

-- ── handle_new_user() 재정의 (베이스 382) ────────────────────
--   ⚠️ 트리거 연결(`on_auth_user_created`)은 다시 만들지 않는다 — 함수만 바꿔 끼운다.
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
    -- [420] 생년월일은 1900-01-01 ~ 오늘(일본 시각) 밖이면 버린다(NULL) — 비어 있으면 응모
    --   화면의 연령 확인 절차가 다시 묻는다. 미래 날짜·1800년대는 어떤 값으로도 못 쓴다.
    public._plausible_birthdate(m->>'birthdate'),
    -- 🔴 성별은 허용 목록으로 거른다 — 그 칸에 제약(180)이 걸려 있어, 목록 밖 값이
    --    오면 제약 위반으로 **가입이 통째로 롤백된다.** `signUp` 은 공개 키로 부를 수
    --    있어 화면 드롭다운을 거치지 않은 값이 올 수 있다.
    --    ⚠️ 위 `_safe_*` 도우미로는 이게 안 걸린다 — 형변환이 아니라 제약 위반이다.
    CASE WHEN m->>'gender' IN ('male','female','other','undisclosed')
         THEN m->>'gender' ELSE NULL END,
    -- [420] 동의 시각은 브라우저 값을 **계정 생성 시각 ±1일 안에서만** 믿는다 — 밖이면 서버
    --   시각(now()). 가입 시각은 이미 서버 값을 쓰면서 동의 시각만 브라우저 시계를 그대로
    --   저장하고 있었다(전수조사 2차 9-2). 시계가 틀린 기기·조작된 호출이 「2019년에 동의」
    --   같은 값을 남기면 동의 근거(특정전자메일법·개인정보)가 무너진다.
    public._consent_ts_or_now(m->>'terms_agreed_at',   NEW.created_at),
    public._consent_ts_or_now(m->>'privacy_agreed_at', NEW.created_at),
    -- 🔴 생년월일·성별 수집 동의 시각도 함께 넣는다 — **개인정보 동의와 같은 시각.**
    --    근거: 개인정보처리방침 §2.1 표가 생년월일·성별을 **「회원가입 · 필수」**
    --    수집 항목으로 적고 있다(2026-07-22 시행, 한국어·일본어 양판). 즉 가입 때
    --    받는 그 동의가 곧 이 수집 동의다.
    --    ⚠️ 안 넣으면 **새 가입자에게는 이 값이 영영 안 채워진다** — 응모 화면의
    --    연령 확인 절차는 「생년월일·성별이 비었을 때」만 뜨는데, 이제 가입 순간
    --    둘 다 채워져 그 절차가 한 번도 안 뜬다(2026-08-26 검토 지적).
    public._consent_ts_or_now(m->>'privacy_agreed_at', NEW.created_at),
    -- ⚠️ 참·거짓도 형변환이 터질 수 있다(예: 'yes'). 값이 정확히 'true' 일 때만
    --    참으로 보고, 그 밖에는 거짓으로 둔다 — 마케팅 동의는 **선택**이라
    --    애매하면 안 받은 것으로 두는 쪽이 맞다.
    (lower(COALESCE(m->>'marketing_opt_in', '')) = 'true'),
    -- [420] 마케팅 동의 시각도 같은 규칙 — 단 **동의했을 때만**(안 했으면 NULL 그대로).
    CASE WHEN lower(COALESCE(m->>'marketing_opt_in', '')) = 'true'
         THEN public._consent_ts_or_now(m->>'marketing_agreed_at', NEW.created_at)
         ELSE NULL END
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
  '[014+382+420] 계정이 만들어질 때 회원 행을 만든다. 420 부터 동의 시각은 계정 생성 시각 ±1일
   안에서만 브라우저 값을 믿고(밖이면 now()), 생년월일은 1900~오늘 밖이면 NULL. 382 부터 가입 폼 값
   (이름·생년월일·성별·동의 시각)을 raw_user_meta_data 에서 꺼내 함께 넣고,
   개인정보를 두 곳에 남기지 않도록 그 자리를 지운다(email 키는 남긴다).
   ⚠️ 미확인 계정에도 값이 들어간다 — 회원 수에서 빼는 것은 설계 2 소관.';

COMMIT;

-- ── 적용 후 확인 ─────────────────────────────────────────────────
-- [V1] 도우미 — 순수 계산이라 SQL 편집기에서 바로:
--   select public._consent_ts_or_now('2019-01-01T00:00:00Z', now()) = now() as out_of_range_becomes_now,
--          public._consent_ts_or_now((now() - interval '5 minutes')::text, now()) < now() as in_range_kept,
--          public._consent_ts_or_now(NULL, now()) = now() as null_becomes_now,
--          public._plausible_birthdate('2099-01-01') is null as future_dropped,
--          public._plausible_birthdate('1899-12-31') is null as too_old_dropped,
--          public._plausible_birthdate('1990-05-05') = date '1990-05-05' as ok_kept;
--   기대: 전부 true.
-- [V2] 트리거 — auth.users 에 시험 행을 넣어 트리거를 태우고 RAISE EXCEPTION 으로 되돌린다
--   (⚠️ 362 가입 차단 트리거가 적용된 서버에서는 auth.uid() 가 비어 거부된다 — 지금은 미적용):
--   DO $$ DECLARE v_id uuid := gen_random_uuid(); r record; BEGIN
--     INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at,
--       raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
--     VALUES (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
--       'zz-420-test@example.invalid', '', now(), '{"provider":"email","providers":["email"]}',
--       '{"name":"시험","name_kanji":"시험","name_kana":"しけん","birthdate":"2099-01-01","gender":"female",
--         "terms_agreed_at":"2019-01-01T00:00:00Z","privacy_agreed_at":"2019-01-01T00:00:00Z",
--         "marketing_opt_in":"true","marketing_agreed_at":"2019-01-01T00:00:00Z"}', now(), now());
--     SELECT birthdate, terms_agreed_at, privacy_agreed_at, marketing_agreed_at, created_at INTO r
--       FROM public.influencers WHERE id = v_id;
--     RAISE EXCEPTION '결과 birthdate=% terms=% privacy=% mkt=% created=%', r.birthdate, r.terms_agreed_at, r.privacy_agreed_at, r.marketing_agreed_at, r.created_at;
--   END $$;
--   기대: birthdate NULL · 동의 시각 셋이 2019 가 아니라 지금 시각.
