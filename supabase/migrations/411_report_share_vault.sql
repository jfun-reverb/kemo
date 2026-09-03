-- ============================================================
-- 411. 리포트 공유 비밀번호 — 금고 열쇠 + 암복호 헬퍼 (🔴 이 저장소 첫 양방향 암호화)
-- ============================================================
-- 작업표: 「작업 19」 · 사양서 「비밀번호를 어떻게 보관하나」
--
-- 무엇을 어디에 왜
--   공유 비밀번호는 **되돌릴 수 있게** 저장한다 — 관리자가 「보기」로 다시 확인해야 하므로
--   (2026-09-03 사용자 결정). 지금 쓰는 pgcrypto 의 crypt() 는 해시(되돌릴 수 없음)라 못 쓴다.
--   → pgcrypto 의 pgp_sym_encrypt / pgp_sym_decrypt (대칭키). 열쇠는 Supabase 금고(vault)에.
--
-- 🔴 첫 할 일이었던 확인 — 2026-09-04 개발서버에서 **로그인한 일반 세션(authenticated)이 부른
--    SECURITY DEFINER 함수 안에서 vault.decrypted_secrets 가 읽힌다**는 것을 실제로 확인했다.
--    (기존 선례 142·204·351·365·371 은 전부 예약 실행이라 이 경로는 처음이었다.)
--
-- ⚠️ 열쇠는 백업하지 않는다(2026-09-03 결정 — 회사에 비밀번호 보관 도구가 없다). 잃으면 저장된
--    공유 비밀번호만 못 풀고 리포트·결과물은 안 사라진다 → 비밀번호를 새로 정해 브랜드에 다시 알린다.
--    링크·비밀번호를 브랜드에 보낸 메일이 사실상 백업이다.
-- ⚠️ 금고가 데이터베이스 안에 있다는 한계를 알고 고른 것 — 최고 관리자 권한이 통째로 넘어가면
--    열쇠도 넘어간다. 데이터베이스 파일만 새는 경우를 막는다.
-- 🔴 두 헬퍼는 **아무에게도 실행 권한을 주지 않는다**(PUBLIC·anon·authenticated 전부 회수).
--    안쪽에서 부르는 SECURITY DEFINER 함수는 소유자 권한으로 돌아 계속 동작한다.
-- 🔴 롤백은 작업 20 이후를 먼저 되돌린 뒤 — 순서를 바꾸면 저장된 암호문을 영영 못 푼다.
-- ============================================================

BEGIN;

-- 2026-09-04 경로 확인용으로 만든 것 정리
DROP FUNCTION IF EXISTS public._probe_vault_read();
DELETE FROM vault.secrets WHERE name = '_probe_vault_from_authenticated';

-- ------------------------------------------------------------
-- ① 열쇠 — 이미 있으면 다시 만들지 않는다(다시 만들면 기존 암호문을 못 푼다)
-- ------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'report_share_pw_key') THEN
    PERFORM vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'report_share_pw_key',
      '[411] 리포트 공유 비밀번호 암복호 열쇠. 지우거나 바꾸면 저장된 공유 비밀번호를 전부 못 푼다. 백업 안 함(2026-09-03 결정).'
    );
  END IF;
END $$;

-- ------------------------------------------------------------
-- ② 암호화 / 복호화 — 내부 전용
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._report_share_key()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE k text;
BEGIN
  SELECT decrypted_secret INTO k FROM vault.decrypted_secrets WHERE name = 'report_share_pw_key';
  IF k IS NULL THEN RAISE EXCEPTION '공유 비밀번호 열쇠가 금고에 없습니다 (411)'; END IF;
  RETURN k;
END; $$;

CREATE OR REPLACE FUNCTION public._encrypt_report_password(p_plain text)
RETURNS bytea LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_plain IS NULL THEN RETURN NULL; END IF;
  RETURN extensions.pgp_sym_encrypt(p_plain, public._report_share_key());
END; $$;

CREATE OR REPLACE FUNCTION public._decrypt_report_password(p_cipher bytea)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_cipher IS NULL THEN RETURN NULL; END IF;
  RETURN extensions.pgp_sym_decrypt(p_cipher, public._report_share_key());
END; $$;

REVOKE ALL ON FUNCTION public._report_share_key()                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._encrypt_report_password(text)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._decrypt_report_password(bytea)     FROM PUBLIC, anon, authenticated;

COMMIT;

-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 왕복 — 편집기(관리자 권한)에서
SELECT public._decrypt_report_password(public._encrypt_report_password('abc-123 한글')) = 'abc-123 한글' AS 왕복;  -- true
-- [V2] 권한 — 셋 다 로그인·비로그인 모두 false
SELECT p.proname, has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인, has_function_privilege('anon', p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname IN ('_report_share_key','_encrypt_report_password','_decrypt_report_password');
-- [V3] 캠페인 관리자 브라우저에서 db.rpc('_encrypt_report_password',{p_plain:'x'}) → 권한 오류여야 한다
*/
-- 롤백: 작업 20 이후 되돌린 뒤 → DROP FUNCTION 3개 + DELETE FROM vault.secrets WHERE name='report_share_pw_key'
