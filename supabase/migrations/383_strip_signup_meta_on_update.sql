-- ════════════════════════════════════════════════════════════════════
-- 383 — 가입 폼 값이 계정 메타데이터에 되살아나는 것을 막는다
-- ════════════════════════════════════════════════════════════════════
--
-- ▌무엇이 문제였나 (2026-08-26 개발서버 실측)
--
-- 382 의 가입 트리거는 `auth.users.raw_user_meta_data` 에서 폼 값을 꺼내
-- `influencers` 에 넣은 뒤 **그 자리를 지운다.** 그런데 가입을 마치고 보면
-- 이름·가나·한자·생년월일·성별이 **그대로 남아 있었다.**
--
-- 트리거가 안 돈 것은 아니다 — 같은 함수가 만든 회원 행에 `age_consent_at`
-- 까지 정확히 채워져 있었고(화면이 안 보내는 값이라 트리거만이 넣을 수 있다),
-- 지우는 문장은 그 INSERT **뒤에** 있으므로 거기까지 반드시 실행됐다.
--
-- 실측: 시험 계정 3개 모두 `updated_at > created_at`(19~55밀리초).
--        즉 **삽입 직후 누군가 그 행을 다시 썼다.** 인증 서비스가 계정을 만든 뒤
--        자기가 들고 있던 사본으로 행을 한 번 더 저장하면서, 우리가 지운 자리를
--        **원래 값으로 되돌린 것**이다.
--
-- ▌그래서 「나중에 한 번 더 지우기」로는 못 막는다
--
-- 되돌리는 쓰기가 **언제** 오는지 우리가 정할 수 없다. 삽입 시점에만 지우면
-- 그 뒤에 오는 쓰기가 다시 되살린다. 그래서 **쓰기가 올 때마다** 지운다.
--
-- ▌하는 일
--
-- `auth.users` 를 수정하는 모든 쓰기 **직전에** 그 아홉 개 열쇠말을 떨궈낸다.
-- 값을 따로 저장하지 않고 들어오는 값에서 빼기만 하므로 추가 쓰기가 없다.
--
-- ⚠️ 그 아홉 개는 **가입 폼이 서버로 값을 나르는 통로일 뿐**이고, 저장소를
--    전수 조사한 결과 화면 코드에는 그 값을 읽는 곳이 **한 곳도 없다.**
--    관리자 초대(245)가 이 칸에 넣는 것은 `sub`·`email`·`email_verified`·
--    `phone_verified` 네 개뿐이라 겹치지 않는다.
--
-- 🔴 **앞으로 이 칸에 `name` 같은 값을 담아 쓰려 하면 조용히 사라진다.**
--    여기서 지우기 때문이다. 그런 기능이 필요해지면 이 목록을 먼저 볼 것.
--
-- 🔴 **이 함수가 오류를 내면 계정 수정이 전부 막힌다** — 로그인마다 도는
--    자리다(마지막 로그인 시각을 적는다). 그래서 값이 객체가 아닐 때는
--    아무것도 하지 않고 지나간다. `jsonb - text` 는 객체·배열이 아닌 값에
--    쓰면 오류를 내는데, 그 오류 하나가 **로그인을 통째로 막는다.**
--
-- ▌되돌리는 방법
--   DROP TRIGGER IF EXISTS on_auth_user_updated_strip_signup_meta ON auth.users;
--   DROP FUNCTION IF EXISTS public.strip_signup_meta_on_update();
--   DROP FUNCTION IF EXISTS public._strip_signup_meta(jsonb);
--   ⚠️ 트리거를 먼저 지운다 — 함수부터 지우려 하면 트리거가 붙들고 있어 거부된다.
--   ⚠️ 이미 지워진 값은 **안 돌아온다**(원본이 없다). 되돌리기는 「앞으로 안 지운다」는
--      뜻이지 「지운 것을 되살린다」가 아니다.
--   → 되돌리면 가입 폼 값이 계정 메타데이터에 다시 쌓인다(저장 자체는 정상).
--
-- 관련: 382(가입 트리거) · 352(탈퇴 파기 — 이메일 키만 바꾼다) · 014(원본 트리거)
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── 지울 열쇠말 목록은 여기 한 곳에만 둔다 ──────────────────────────
-- 🔴 아래 트리거와 일괄 정리가 **같은 함수**를 쓴다. 목록이 두 벌이 되면
--    한쪽만 늘어나 그 값이 되살아난다.
-- ⚠️ 382 의 지우기에도 같은 목록이 있다(그건 이미 적용돼 손대지 않는다).
--    **어긋나면 여기 목록이 이긴다** — 이쪽은 쓰기마다 돌기 때문이다.
CREATE OR REPLACE FUNCTION public._strip_signup_meta(m jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN jsonb_typeof(m) <> 'object' THEN m
           ELSE m - 'name' - 'name_kanji' - 'name_kana'
                  - 'birthdate' - 'gender'
                  - 'terms_agreed_at' - 'privacy_agreed_at'
                  - 'marketing_opt_in' - 'marketing_agreed_at'
         END;
$$;

CREATE OR REPLACE FUNCTION public.strip_signup_meta_on_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.raw_user_meta_data := public._strip_signup_meta(NEW.raw_user_meta_data);
  RETURN NEW;
EXCEPTION WHEN others THEN
  -- 🔴 **어떤 오류도 계정 수정을 막지 않는다.** 이 함수는 로그인마다 도는
  --    자리라(마지막 로그인 시각을 적는다), 여기서 예외가 새어 나가면
  --    로그인·비밀번호 변경·탈퇴 파기가 **전부 막힌다.**
  --    ⚠️ 대신 실패가 조용하다 — 그 계정은 값이 남은 채로 지나간다.
  --    「지우기가 안 되는 것」과 「로그인이 안 되는 것」 중 앞이 낫다는 판단.
  --    382 의 형제 함수(_safe_ts·_safe_date)가 같은 이유로 같은 방어를 한다.
  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public._strip_signup_meta(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._strip_signup_meta(jsonb) FROM anon, authenticated;
REVOKE ALL ON FUNCTION public.strip_signup_meta_on_update() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.strip_signup_meta_on_update() FROM anon, authenticated;

DROP TRIGGER IF EXISTS on_auth_user_updated_strip_signup_meta ON auth.users;
-- ⚠️ `OF raw_user_meta_data` 로 좁힌다 — 그 칸을 건드리지 않는 쓰기(로그인 시각만
--    적는 등)에는 아예 안 낀다. 그 칸을 SET 목록에 **적기만 해도** 도므로,
--    되살리는 쓰기는 반드시 걸린다(값이 같은지는 상관없다).
CREATE TRIGGER on_auth_user_updated_strip_signup_meta
  BEFORE UPDATE OF raw_user_meta_data ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.strip_signup_meta_on_update();

-- ── 이미 쌓인 값 정리 ────────────────────────────────────────────────
-- 위 장치가 붙기 전에 가입한 계정에는 값이 그대로 있다. 한 번 훑어 지운다.
-- ⚠️ 트리거가 알아서 지워 주기를 **기대하지 않고** 직접 지운다 — 같은 함수를
--    쓰므로 목록은 어차피 하나다. 이러면 트리거가 어떻게 도는지와 무관하게
--    이 문장만으로 결과가 정해진다.
-- ⚠️ 건드릴 것이 없는 행은 아예 안 건드린다 — 계정 수정 시각이 괜히 바뀌면
--    「최근에 뭔가 있었다」로 잘못 읽힌다.
UPDATE auth.users
   SET raw_user_meta_data = public._strip_signup_meta(raw_user_meta_data)
 WHERE jsonb_typeof(raw_user_meta_data) = 'object'
   AND (raw_user_meta_data ?| array['name','name_kanji','name_kana','birthdate',
                                    'gender','terms_agreed_at','privacy_agreed_at',
                                    'marketing_opt_in','marketing_agreed_at']);

COMMIT;

-- ════════════════════════════════════════════════════════════════════
-- 🔴 적용 **전에** 한 번 볼 것 — auth.users 에 이미 붙어 있는 장치 목록
-- ════════════════════════════════════════════════════════════════════
-- 저장소 파일에는 014(가입 시 회원 행 생성)뿐이지만, 인증 서비스가 자기가
-- 붙여 둔 것이 있을 수 있다. BEFORE UPDATE 자리에 다른 것이 이미 있으면
-- 이름 순서에 따라 서로 간섭할 수 있으므로 눈으로 확인한다.
-- select t.tgname, t.tgtype, p.proname from pg_trigger t
--   join pg_class c on c.oid = t.tgrelid
--   join pg_namespace n on n.oid = c.relnamespace
--   join pg_proc p on p.oid = t.tgfoid
--  where n.nspname = 'auth' and c.relname = 'users' and not t.tgisinternal;
--
-- ════════════════════════════════════════════════════════════════════
-- 적용 뒤 확인 (조회만 — 그대로 돌려도 안전)
-- ════════════════════════════════════════════════════════════════════
-- [1] 남은 계정이 0 이어야 한다
-- select count(*) as still_dirty from auth.users
--  where jsonb_typeof(raw_user_meta_data) = 'object'
--    and raw_user_meta_data ?| array['name','name_kanji','name_kana','birthdate',
--                                    'gender','terms_agreed_at','privacy_agreed_at',
--                                    'marketing_opt_in','marketing_agreed_at'];
--
-- [2] 🔴 **가입을 한 번 실제로 해 봐야 한다.** 이 확인만으로는 부족하다 —
--     막으려는 것이 「가입 직후 인증 서비스가 되돌려 쓰는 것」이라, 그 순간을
--     재현하지 않으면 고쳐졌는지 알 수 없다. 가입 화면에서 새 계정을 만든 뒤:
-- select email,
--        (select count(*) from jsonb_object_keys(raw_user_meta_data) k) as meta_keys,
--        (raw_user_meta_data ? 'birthdate') as has_birthdate
--   from auth.users where email = '<새 계정>';
--     → meta_keys 4 · has_birthdate false 여야 한다.
--     그리고 같은 계정의 회원 행에 이름·생년월일이 **들어가 있어야** 한다
--     (지우는 것이 너무 일러 못 읽는 상황과 구분).
-- select name, name_kana, birthdate, gender, age_consent_at
--   from public.influencers where email = '<새 계정>';
--
-- [3] 로그인이 안 막히는지 — 시험 계정으로 실제 로그인해 볼 것.
--     ⚠️ SQL 편집기로는 재현이 안 된다(서비스 키라 로그인 경로를 안 탄다).
-- ════════════════════════════════════════════════════════════════════
