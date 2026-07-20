-- ============================================================
-- 244_admin_invite_mail_tracking.sql
-- 2026-07-20
--
-- 목적:
--   관리자 초대 메일(사양서 PR 3, docs/specs/2026-07-20-admin-invite-mail-and-setpw.md
--   §D-6 ①) 발송 여부를 admins 테이블에 기록한다. 지금은 초대 메일을 보내도
--   admins 행 어디에도 흔적이 안 남아, super_admin이 「초대했는데 메일이 갔는지」를
--   확인할 방법이 없다(관리자 계정 관리 화면 「발송됨/미발송」 표시 + 「초대 재발송」
--   버튼의 기반 데이터).
--
--   선례를 그대로 따름: 201_orient_mail_sent_tracking.sql
--   (orient_sheets.mail_sent_at / mail_sent_to — 같은 명명 규칙 · 같은 타입 · 같은
--    "신규 컬럼은 NULL 허용, 기존 행은 NULL로 시작" 원칙)
--
-- 변경:
--   admins 에 컬럼 3개 추가 (전부 NULL 허용, 백필 없음 — 기존 행은 "발송 이력 없음"이
--   사실이므로 NULL이 곧 정확한 값이다)
--     - invite_mail_sent_at  timestamptz NULL : 최근 초대 메일 발송 성공 시각
--     - invite_mail_sent_to  text        NULL : 최근 초대 메일 수신 주소(재발송 시 이메일이
--                                                바뀌는 경우는 없지만, 표시·audit 목적으로 원본
--                                                발송 대상을 남긴다 — orient_sheets.mail_sent_to
--                                                패턴과 동일한 이유)
--     - invite_completed_at timestamptz NULL : 초대받은 사람이 자립형 설정 페이지
--                                                (dev/admin-setpw.html)에서 최초로 비밀번호
--                                                설정을 완료한 시각. 아래 "채울 수 있는가" 참고.
--
--   신규 Edge Function `notify-admin-invite`(PR 2, super_admin 로그인 토큰 전용)가
--   초대 메일 발송 성공 시 service_role 로 invite_mail_sent_at·invite_mail_sent_to 를
--   UPDATE 한다(orient_sheets 패턴과 동일 — 기록 실패가 발송 자체를 무효화하지 않는다).
--
-- ────────────────────────────────────────────────────────────
-- 「최초 비밀번호 설정 완료 시각」을 실제로 채울 수 있는가 — 판단
-- ────────────────────────────────────────────────────────────
--   설정 자체는 자립형 페이지가 Supabase 표준 경로 auth.updateUser({password}) 로 수행하고,
--   이 호출은 클라이언트(브라우저) → Supabase Auth 직접 통신이라 우리 서버 코드가 그 순간에
--   개입하지 않는다. 그렇다고 "채울 수 없다"는 결론은 아니다 — 아래 대안이 이미 이 프로젝트의
--   기존 행 단위 보안 정책(RLS)만으로 성립한다:
--
--   008_create_admins.sql 의 "admins_update" 정책은 이미
--     USING ( super_admin 전체 OR auth_id = auth.uid() )
--   즉 "본인 행은 본인이 직접 UPDATE 가능"이 이미 허용돼 있다(본인 비밀번호 변경
--   changeMyAdminPassword 가 이미 이 성질에 기대는 것과 동일선상). 재설정 링크를 클릭해
--   생긴 임시 세션도 그 사람 본인의 인증된(authenticated) 세션이므로 auth.uid() 가 본인
--   auth_id 와 일치한다.
--
--   따라서 자립형 페이지는 새로운 원격 호출 함수(RPC)나 SECURITY DEFINER 함수 없이,
--   auth.updateUser({password}) 성공 직후 같은 세션으로 아래 형태의 일반 UPDATE 를
--   한 번 더 호출하는 것만으로 이 컬럼을 채울 수 있다:
--
--     await db.from('admins')
--       .update({ invite_completed_at: new Date().toISOString() })
--       .eq('auth_id', session.user.id)
--       .is('invite_completed_at', null);   -- 최초 1회만 기록(이미 값이 있으면 덮어쓰지 않음)
--
--   `.is('invite_completed_at', null)` 조건이 SQL 의 COALESCE 역할을 대신한다 — 별도 함수
--   없이 PostgREST WHERE 절만으로 "최초 1회" 성질을 보장한다. 이 UPDATE 가 실패해도(네트워크
--   오류 등) 비밀번호 자체는 이미 auth.updateUser() 로 바뀐 뒤이므로 로그인 자체는 영향받지
--   않는다 — 이 컬럼은 어디까지나 관리자 계정 관리 화면의 "설정 완료 여부" 표시용 부가 정보다.
--
--   결론: 컬럼을 포함한다. 채우는 주체는 화면 코드(자립형 페이지, PR 1·5-B 구현 시)이고,
--   이 마이그레이션은 그 채우기가 기존 RLS 만으로 가능하도록 스키마만 준비한다.
--
-- 행 단위 보안 정책(RLS) 검토:
--   admins 테이블 기존 정책 3종(008_create_admins.sql)을 그대로 상속하며, 신규 정책은
--   추가하지 않는다.
--     - admins_select: is_admin() — 전체 관리자가 조회 가능. invite_mail_sent_to 는
--       admins.email 자체가 이미 같은 정책으로 전체 관리자에게 노출돼 있으므로(항상 자기
--       자신의 이메일과 동일한 값) 추가 노출이 아니다.
--     - admins_update: super_admin 전체 OR 본인 행 — Edge Function 은 service_role 로
--       RLS 를 우회해 쓰고(초대 메일 발송 기록), 본인 행 UPDATE 허용은 위 "완료 시각" 채우기
--       메커니즘이 정확히 필요로 하는 성질이다. 별도 정책 불필요.
--     - admins_delete: 영향 없음(컬럼 추가와 무관).
--   결론: 신규 RLS 정책 없음 — ALTER TABLE ADD COLUMN 은 기존 정책 범위에 자동 포함된다.
--
-- 운영 데이터 영향:
--   신규 컬럼 3개 전부 NULL 허용 — 기존 행은 NULL(이력 없음)로 시작, 영향 없음.
--   행 단위 보안 정책 변경 없음.
--
-- 롤백:
--   ALTER TABLE public.admins DROP COLUMN IF EXISTS invite_mail_sent_at;
--   ALTER TABLE public.admins DROP COLUMN IF EXISTS invite_mail_sent_to;
--   ALTER TABLE public.admins DROP COLUMN IF EXISTS invite_completed_at;
-- ============================================================

BEGIN;

ALTER TABLE public.admins
  ADD COLUMN IF NOT EXISTS invite_mail_sent_at  timestamptz,
  ADD COLUMN IF NOT EXISTS invite_mail_sent_to   text,
  ADD COLUMN IF NOT EXISTS invite_completed_at   timestamptz;

COMMENT ON COLUMN public.admins.invite_mail_sent_at IS
  '[244] 관리자 초대 메일 최근 발송 성공 시각(NULL=미발송). Edge Function notify-admin-invite 가 service_role 로 기록.';
COMMENT ON COLUMN public.admins.invite_mail_sent_to IS
  '[244] 관리자 초대 메일 최근 발송 수신 주소. Edge Function notify-admin-invite 가 service_role 로 기록.';
COMMENT ON COLUMN public.admins.invite_completed_at IS
  '[244] 초대받은 사람이 자립형 비밀번호 설정 페이지에서 최초로 설정을 완료한 시각(NULL=미완료). '
  '자립형 페이지가 auth.updateUser() 성공 직후 본인 행에 한해 기존 admins_update RLS(본인 행 UPDATE 허용)로 직접 기록 — 신규 함수 불필요.';

COMMIT;

-- ============================================================
-- 검증 쿼리 (마이그레이션 후 SQL Editor 에서 실행, 1단계씩 진행)
-- ============================================================

-- [1단계] 컬럼 추가 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema = 'public' AND table_name = 'admins'
--    AND column_name IN ('invite_mail_sent_at','invite_mail_sent_to','invite_completed_at');
-- 기대: 3행, 전부 is_nullable = 'YES'

-- [2단계] 기존 행 전부 NULL(백필 없음) 확인
-- SELECT count(*) FILTER (WHERE invite_mail_sent_at IS NOT NULL) AS sent_not_null,
--        count(*) FILTER (WHERE invite_completed_at IS NOT NULL) AS completed_not_null
--   FROM public.admins;
-- 기대: 두 값 모두 0 (직후 실행 시점 기준)

-- [3단계] 기존 admins RLS 정책이 신규 컬럼에도 그대로 적용되는지(정책 목록 자체는 불변 확인)
-- SELECT policyname, cmd FROM pg_policies WHERE tablename = 'admins' ORDER BY policyname;
-- 기대: admins_select / admins_insert / admins_update / admins_delete 4건 그대로(신규 정책 없음)
