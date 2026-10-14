-- ============================================================
-- 526_brand_account_functions.sql
-- 브랜드 로그인 — 조각 2: 데이터베이스 함수
--   docs/specs/2026-10-14-brand-login-breakdown.md 「조각 2」·「선결 조건」·「🎨 피그마 설명 반영」 F-1~F-8
--   사양서 docs/specs/2026-07-15-brand-portal.md §16-6
--
-- 목적
--   525 의 표(brand_accounts · brand_account_links · brand_password_reset_requests) 위에 올라가는 함수 묶음.
--   ① 관리자가 브랜드 대표 담당자 계정을 만들고/바꾸는 함수      admin_upsert_brand_owner_account
--   ② 관리자 화면의 계정 줄 상태                               admin_get_brand_account_status
--   ③ 링크(계정 만들기·비밀번호 재설정 공용) 유효 판정(비로그인)  get_brand_link_state
--   ④ 설정 완료 기록(약관 동의 시각·비밀번호 설정 시각)         complete_brand_account_setup
--   ⑤ 재설정 완료 기록(링크 번호 비우기)                       complete_brand_password_reset
--   ⑥ 로그인 직후 판정                                        get_my_brand_login_state
--   ⑦ 비밀번호 찾기 요청 제한(서비스 키 전용, 243 복제)         check_brand_password_reset_rate_limit
--   ⑧ 요청 기록 30일 정리 + pg_cron                           purge_old_brand_password_reset_requests
--   ⑨ 메일 서버 함수(조각 4·5)용 서비스 키 전용 보조 둘          service_issue_brand_account_link · service_mark_brand_setup_mail_sent
--   + 내부 도우미 _brand_email_owner (이메일을 쓰는 계정이 누구인지 — 호출 불가, 안쪽 전용)
--
-- 베이스 (재정의할 때 이 파일이 원본)
--   계정 직접 삽입 방식 : 417 invite_admin (auth.users + auth.identities, 이메일 lower(btrim()) 정규화)
--   요청 제한 3층·30일 정리 : 243 (표 이름과 락 키, 정리 시각만 다르다)
--   실행 권한 : 375 — 부여 먼저 → PUBLIC 회수 → anon/authenticated 회수. 회수 방향이 둘이다(369·370)
--   대표 줄 : brands.contacts[] 의 is_primary 줄(086) — 이메일 정본. 옛 칸 primary_email 은 보지 않는다(stale 9)
--
-- 배포 순서  (사용자 결정 P-1: 개발서버에서만 동작)
--   1) 525 가 먼저 적용돼 있어야 한다(없으면 표가 없어 이 파일은 함수 본문만 만들어지고 첫 호출에서 터진다).
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 🔴 운영 데이터베이스에는 적용하지 않는다(보류, 약관 관문 P-7).
--   3) 적용만으로 바뀌는 기존 동작: 없음(새 함수와 새 예약 작업뿐).
--   4) 이 파일 다음 조각: 3(delete_brand·merge_brands·invite_admin 가드) → 4(설정 메일) → 5(비밀번호 찾기 메일).
--
-- ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
-- │ A. 함수 표 — 누가 부르고, 누가 부를 수 있나                                                    │
-- ├───────────────────────────────────────┬────────┬───────────────┬───────────────────────────┤
-- │ 함수                                  │ anon   │ authenticated │ service_role / postgres   │
-- ├───────────────────────────────────────┼────────┼───────────────┼───────────────────────────┤
-- │ admin_upsert_brand_owner_account      │ 막힘   │ 열림(안쪽에서 │ 열림                      │
-- │                                       │        │ 캠페인 관리자 │                           │
-- │                                       │        │ 이상 재확인)  │                           │
-- │ admin_get_brand_account_status        │ 막힘   │ 열림(is_admin │ 열림                      │
-- │                                       │        │ 안쪽 확인)    │                           │
-- │ get_brand_link_state                  │ 열림   │ 열림          │ 열림 (비로그인 화면이 부름) │
-- │ complete_brand_account_setup          │ 막힘   │ 열림          │ 열림 (임시 세션이 부름)   │
-- │ complete_brand_password_reset         │ 막힘   │ 열림          │ 열림 (임시 세션이 부름)   │
-- │ get_my_brand_login_state              │ 막힘   │ 열림          │ 열림                      │
-- │ check_brand_password_reset_rate_limit │ 막힘   │ 막힘          │ 열림 (조각 5 서버 함수)   │
-- │ purge_old_brand_password_reset_requests│ 막힘  │ 막힘          │ postgres 만 (pg_cron)     │
-- │ service_issue_brand_account_link      │ 막힘   │ 막힘          │ service_role (조각 4·5)   │
-- │ service_mark_brand_setup_mail_sent    │ 막힘   │ 막힘          │ service_role (조각 4)     │
-- │ _brand_email_owner (도우미)           │ 막힘   │ 막힘          │ postgres·service_role     │
-- └───────────────────────────────────────┴────────┴───────────────┴───────────────────────────┘
--   · 안쪽 호출은 감싸는 함수가 SECURITY DEFINER 라 산다(도우미를 authenticated 에서 회수해도 관리자 함수는 부를 수 있다).
--   · 비로그인에 여는 것은 get_brand_link_state 하나뿐이고 true/false 두 값 외에는 아무것도 돌려주지 않는다(이메일 반환 금지).
--
-- ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
-- │ B. admin_upsert_brand_owner_account 판정 규칙 (화면이 넘기는 이전 값 = 상세를 연 시점의 대표 줄)   │
-- └──────────────────────────────────────────────────────────────────────────────────────────────┘
--   입력: 브랜드 번호 · 이전 대표 줄 id(p_prev_contact_id) · 이전 대표 이메일(p_prev_email). 현재 값은 서버가 brands.contacts 에서 직접 읽는다.
--   모든 이메일 비교는 lower(btrim()). 브랜드 단위로 직렬화(advisory lock), 같은 이메일을 두고 다투는 호출도 직렬화한다.
--
--   (0) 가드·입력 검사  — 순서대로, 첫 번째에서 멈춘다
--       is_campaign_admin() 아님 ........................ forbidden
--       브랜드 없음 ........................................ brand_not_found        (계약에 없던 값 — 추가)
--       브랜드가 보관(archived) ........................... brand_archived         (계약에 없던 값 — 추가. P-9 와 같은 결: 보관 브랜드에는 계정을 못 만든다)
--       대표 줄 없음 또는 이메일 비었음 .................... no_primary_email
--       이메일이 형식에 안 맞음(@ 없음 등) ................. invalid_email         (계약에 없던 값 — 추가. 없으면 인증 서비스에 이상한 주소가 들어간다)
--
--   (1) 이 브랜드에 「활성 대표(owner) 연결」이 없다  → 이전 값은 보지 않는다(P-2: 「계정 없음」 줄 단추도 같은 함수)
--       이 이메일을 쓰는 계정이 admins 에 있음 ........... conflict_admin
--       이 이메일을 쓰는 계정이 회원(인플루언서 등) ........ conflict_influencer   (회원 행이 없는 일반 계정도 여기로 — 브랜드도 관리자도 아닌 모든 기존 계정)
--       이 이메일을 쓰는 브랜드 계정이 다른 브랜드에 활성 연결 ... conflict_brand
--       이 이메일의 브랜드 계정이 연결 없음(해제된 계정) .. 그 계정을 재사용해 연결만 새로 만든다 → created (설정이 끝난 계정이면 needs_mail=false)
--       아무도 안 씀 ....................................... 계정 새로 만들고 연결 → created, needs_mail=true
--
--   (2) 활성 대표 연결이 있다(계정 A)  → 아래 위에서부터 첫 번째에 걸리는 것
--       ① 현재 대표 이메일 = A 의 로그인 이메일 ............ noop   (연결의 근거 줄 id·이름·전화는 현재 대표 줄로 맞춘다)
--       ② 현재 대표 이메일 = 화면이 넘긴 이전 이메일 ........ noop   (이번 저장에서 이메일이 안 바뀜. A 의 로그인 이메일과 어긋나 있어도 되풀이 안내를 안 한다 —
--                                                                 반환 칸 account_email 로 화면이 비교할 수 있다)
--       ③ 이전 줄 id 가 현재 대표 줄 id 와 다름 ............. primary_moved   (대표 표시가 다른 줄로 옮겨짐. 옛 계정 유지, 메일 없음, 경고만)
--       ④ A 의 비밀번호가 아직 안 정해짐 ..................... email_replaced  (새 이메일의 충돌 검사 → 통과하면 auth.users.email · identities · brand_accounts.email 갱신,
--                                                                 setup_link_id 를 NULL 로 비워 옛 링크 무효화, 메일 발송 기록 비움 → needs_mail=true)
--                                                                 충돌이면 conflict_admin / conflict_influencer / conflict_brand 로 멈춤(아무것도 안 바꿈)
--       ⑤ 그 밖(비밀번호 이미 정해짐) ........................ password_already_set  (로그인 이메일 유지, 메일 없음. 화면은 「로그인 이메일은 안 바뀝니다」 안내)
--   반환 칸: result · needs_mail · email(현재 대표 이메일) · auth_id · account_email(계정의 현재 로그인 이메일) · brand_id.
--   ⚠️ 이전 값이 둘 다 NULL 인 채로 활성 연결이 있고 이메일이 다르면 ④·⑤ 로 간다(이메일 변경으로 본다) — 화면은 상세를 열 때 스냅샷을 꼭 넘길 것.
--
-- ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
-- │ C. 링크 번호(brand_accounts.setup_link_id) 사용 규칙 — 피그마 F-2                                │
-- └──────────────────────────────────────────────────────────────────────────────────────────────┘
--   · 칸 하나가 「현재 유효한 링크 번호」. 설정 메일·재설정 메일 모두 보낼 때마다 새 번호로 교체(service_issue_brand_account_link) → 앞서 보낸 링크는 전부 무효.
--   · 종류는 계정 상태로 정해진다: 비밀번호 미설정(password_set_at IS NULL) = setup / 설정됨 = reset.
--     링크 종류가 지금 계정 상태와 안 맞으면(예: 설정 메일을 받고 그사이 비밀번호를 정함) invalid — 「상태 바뀜」(피그마 w01-05).
--   · 설정/재설정이 끝나면 번호를 NULL 로 비운다 → 같은 링크는 「이미 사용됨」(invalid).
--   · 이메일 교체(email_replaced)도 번호를 NULL 로 비워 옛 링크를 죽인다. 새 번호는 메일 서버 함수가 발급한다.
--
-- ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
-- │ D. 설계 판단                                                                                  │
-- └──────────────────────────────────────────────────────────────────────────────────────────────┘
--   [A] get_brand_link_state 는 「브랜드 계정이 아니거나 활성 브랜드(보관 아님) 연결이 없으면」 invalid 로 한다.
--       이유: 그 상태에서 비밀번호를 정해도 로그인 판정이 no_active_brand 로 막혀 헛수고가 된다. 사용자는 w01-05(쓸 수 없는 링크) 안내대로 운영팀에 문의.
--       (get_my_brand_login_state 의 P-9 보관 제외와 같은 기준.)
--   [B] complete_brand_account_setup 은 화면 순서(updateUser({password}) 먼저 → 이 함수)를 서버가 강제한다.
--       비밀번호가 아직 비어 있으면(encrypted_password='') 새 값 password_not_set 으로 거절 — 임시 세션을 가진 사람이 비밀번호 없이
--       약관 동의만 찍고 「설정 완료」 상태를 만드는 것을 막는다(계약에 없던 반환값 — 추가).
--       실패 시 상태: 비밀번호는 바뀌었는데 이 함수가 실패하면 password_set_at 은 NULL 그대로 → 로그인 판정은 setup_incomplete(실패 문구).
--         · 화면은 같은 임시 세션으로 이 함수를 몇 번 다시 부른다(멱등 — 아직 아무것도 안 바뀌었으므로 안전).
--         · 그래도 실패하면 사용자가 「비밀번호 찾기」를 누르면 password_set_at 이 NULL 이라 조각 5 가 설정 메일을 다시 보낸다(스스로 복구).
--         · 반대 순서(이 함수 먼저)는 채택하지 않았다: 동의·설정 완료만 기록되고 비밀번호는 비어 있는 상태가 생긴다.
--   [C] raw_user_meta_data 에는 sub·email·email_verified·phone_verified 만 담는다. 담당자 이름·전화는 brand_accounts 칸에 둔다.
--       383 의 정리 트리거(BEFORE UPDATE OF raw_user_meta_data)는 name 등 가입 폼 열쇠를 지우므로 그 칸을 담는 곳으로 쓰지 않는다.
--       email_replaced 가 raw_user_meta_data 의 email 키를 고치는 UPDATE 는 383 이 지우는 열쇠(name·birthdate 등)와 무관해 안전하다.
--   [D] 497 가입 관문 : 이 함수들의 auth.users INSERT/UPDATE 는 SECURITY DEFINER(소유자 postgres)라 current_user 가 supabase_auth_admin 이 아니어서 통과한다.
--       498 미인증 정리: email_confirmed_at 을 now() 로 채워 대상 밖. 420 가입 트리거: account_kind=brand 라 인플루언서 행을 만들지 않는다.
--   [E] 서비스 키 보조(⑨)를 함수로 둔 이유: 메일 서버 함수가 표를 직접 고쳐도 되지만(service_role 은 RLS 를 우회) 「종류 판정 + 활성 연결 확인 + 새 번호 교체」가
--       세 단계라 두 서버 함수(4·5)에 사본이 생긴다. 한 곳에 두어 같은 조건을 쓰게 한다. 계정을 찾는 조회(이메일·브랜드로)는 표를 직접 읽는다(이메일은 정규화돼 저장).
--   [F] 계정 열거 방지: 비밀번호 찾기에서 계정 존재 여부는 조각 5 서버 함수가 항상 같은 응답으로 가린다. 이 파일의 비로그인 함수(get_brand_link_state)는
--       무작위 uuid 를 맞춰야만 valid 가 나오고 이메일 등 다른 정보를 주지 않는다.
--   [G] 이메일 충돌 판정은 auth.users 전체를 lower(btrim(email)) 로 본다. auth.users 의 유일 색인은 대소문자를 구분하므로 이 정규화가 필요하다.
--
-- 되돌리는 방법  (이 순서로. 계정이 하나라도 만들어진 뒤라면 6) 의 표 삭제는 하지 않는다)
--   1) SELECT cron.unschedule('brand-password-reset-requests-retention-daily');
--   2) DROP FUNCTION IF EXISTS public.purge_old_brand_password_reset_requests();
--      DROP FUNCTION IF EXISTS public.check_brand_password_reset_rate_limit(text, boolean);
--   3) DROP FUNCTION IF EXISTS public.service_mark_brand_setup_mail_sent(uuid, uuid, text);
--      DROP FUNCTION IF EXISTS public.service_issue_brand_account_link(uuid, text);
--   4) DROP FUNCTION IF EXISTS public.get_my_brand_login_state();
--      DROP FUNCTION IF EXISTS public.complete_brand_password_reset(uuid);
--      DROP FUNCTION IF EXISTS public.complete_brand_account_setup(uuid, text);
--      DROP FUNCTION IF EXISTS public.get_brand_link_state(uuid, text);
--      DROP FUNCTION IF EXISTS public.admin_get_brand_account_status(uuid);
--      DROP FUNCTION IF EXISTS public.admin_upsert_brand_owner_account(uuid, text, text);
--      DROP FUNCTION IF EXISTS public._brand_email_owner(text, uuid);
--   5) 이 파일이 만든 시험·실제 계정은 별도 정리: 계정을 지우려면 auth.users 에서 해당 행 삭제(brand_accounts·links 는 CASCADE).
--   ⚠️ 화면(조각 6~10)이 이미 이 함수를 부르는 상태에서 2)~4)를 하면 화면 호출이 실패한다 — 화면을 먼저 내린다.
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   ⚠️ 이 함수들은 「적용 Success」가 동작 확인이 아니다. 함수마다 아래에서 실제로 1회씩 부른다.
--   ⚠️ 관리자 가드 함수는 SQL 편집기에서는 로그인 사용자가 없어 forbidden 이 나오는 게 정상이다 → 로그인한 관리자 브라우저 콘솔로 부른다
--      (개발서버 관리자 화면 /admin/ 에서 F12 → Console. 전역 `db` 가 로그인된 연결이다).
--
--   [V1] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public'
--        AND p.proname IN ('admin_upsert_brand_owner_account','admin_get_brand_account_status','get_brand_link_state',
--                          'complete_brand_account_setup','complete_brand_password_reset','get_my_brand_login_state',
--                          'check_brand_password_reset_rate_limit','purge_old_brand_password_reset_requests',
--                          'service_issue_brand_account_link','service_mark_brand_setup_mail_sent','_brand_email_owner')
--      ORDER BY 1;
--     기대: acl 맨 앞에 `=X/` 가 어느 행에도 없다. anon_can 은 get_brand_link_state 만 true.
--           auth_can 은 admin_upsert · admin_get_status · get_brand_link_state · complete_setup · complete_reset · get_my_brand_login_state 만 true.
--           svc_can 은 get_my_brand_login_state 까지 포함한 위 여섯 + check_rate_limit · service_issue · service_mark · _brand_email_owner 가 true,
--           purge 는 false(postgres 만).
--   [V2] 시험 데이터 없이 할 수 있는 호출 — SQL 편집기(postgres)
--     SELECT public.get_brand_link_state(gen_random_uuid(), 'setup');      → invalid
--     SELECT public.get_brand_link_state(gen_random_uuid(), 'reset');      → invalid
--     SELECT public.get_brand_link_state(NULL, 'setup');                   → invalid
--     SELECT public.get_my_brand_login_state();                            → {"state":"not_brand",...}  (편집기엔 로그인 사용자가 없다)
--     SELECT public.complete_brand_account_setup(gen_random_uuid(), 'v0'); → not_brand
--     SELECT public.complete_brand_password_reset(gen_random_uuid());      → not_brand
--     SELECT public.admin_upsert_brand_owner_account(gen_random_uuid(), NULL, NULL); → {"result":"forbidden",...}  (로그인 없음 = 정상)
--     SELECT public.check_brand_password_reset_rate_limit(encode(extensions.digest('zz-526@example.invalid','sha256'),'hex'), false);  → true (첫 호출)
--       같은 문장을 5분 안에 다시 → false.  끝나고 정리: DELETE FROM public.brand_password_reset_requests
--                                                          WHERE email_hash = encode(extensions.digest('zz-526@example.invalid','sha256'),'hex');
--     SELECT public.purge_old_brand_password_reset_requests();             → 정수(0 이면 정상)
--     SELECT jobname, schedule, active FROM cron.job WHERE jobname = 'brand-password-reset-requests-retention-daily';  → '0 21 * * *', true
--     SELECT public.service_issue_brand_account_link(gen_random_uuid(), 'auto');  → {"ok":false,"reason":"no_account"}
--     SELECT public.service_mark_brand_setup_mail_sent(gen_random_uuid(), gen_random_uuid(), 'a@example.invalid');  → false
--     SELECT public._brand_email_owner('zz-526-none@example.invalid', NULL);  → {"kind":"none","auth_id":null}
--   [V3] 로그인한 브라우저 콘솔에서 — 개발서버 관리자 화면(캠페인 관리자 이상 계정)
--     (await db.rpc('admin_get_brand_account_status', {p_brand_id: '<아무 브랜드 uuid>'}))   → data {status:'none',...}
--     (await db.rpc('admin_upsert_brand_owner_account', {p_brand_id: crypto.randomUUID(), p_prev_contact_id: null, p_prev_email: null})).data  → {result:'brand_not_found',...}
--     (await db.rpc('get_my_brand_login_state')).data                                            → {state:'not_brand',...}
--     campaign_manager 로 로그인해 같은 upsert 를 부르면 → {result:'forbidden'}. 인플루언서 앱 콘솔에서 admin_get_brand_account_status → error 42501.
--   [V4] 시험 브랜드가 필요한 것 — 한 번에 되돌아가는 DO 블록. created · noop · email_replaced · password_already_set · primary_moved · 세 충돌을 한 번에 본다.
--     ⚠️ 판단: SQL 편집기(postgres)는 auth.uid() 가 비어 관리자 가드가 forbidden 을 내므로, set_config 로 JWT 클레임을 흉내 낸다(417 의 검증 3)와 같은 방식).
--        auth.users 직접 삽입이 필요해 편집기에서만 가능하고, 끝의 RAISE EXCEPTION 이 전부 롤백한다(편집기 자동 커밋 때문에 BEGIN…ROLLBACK 대신 DO 하나로).
--        시험 이메일은 `.invalid` 도메인, 메일은 나가지 않는다. 실행 전 아래 <ADMIN_AUTH_ID> 를 캠페인 관리자 이상의 admins.auth_id 로 바꾼다:
--          SELECT auth_id, role FROM public.admins WHERE role IN ('super_admin','campaign_admin') LIMIT 3;
--     DO $$
--     DECLARE
--       v_admin uuid := '<ADMIN_AUTH_ID>';
--       b1 uuid; b2 uuid; b3 uuid; b4 uuid;
--       r jsonb; v_out text := '';
--       v_inf_email text; v_adm_email text;
--     BEGIN
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
--       SELECT email INTO v_inf_email FROM public.influencers WHERE email IS NOT NULL LIMIT 1;
--       SELECT email INTO v_adm_email FROM public.admins LIMIT 1;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-526-b1',
--         '[{"id":"c1","name":"시험","phone":"000","email":"zz-526-a@example.invalid","is_primary":true}]') RETURNING id INTO b1;
--       -- 1) 만들기
--       r := public.admin_upsert_brand_owner_account(b1, NULL, NULL);                    v_out := v_out || '1=' || (r->>'result') || ' ';          -- created
--       -- 2) 같은 값 재저장
--       r := public.admin_upsert_brand_owner_account(b1, 'c1', 'zz-526-a@example.invalid'); v_out := v_out || '2=' || (r->>'result') || ' ';       -- noop
--       -- 3) 설정 전 이메일 수정
--       UPDATE public.brands SET contacts = '[{"id":"c1","name":"시험","email":"zz-526-b@example.invalid","is_primary":true}]' WHERE id = b1;
--       r := public.admin_upsert_brand_owner_account(b1, 'c1', 'zz-526-a@example.invalid'); v_out := v_out || '3=' || (r->>'result') || '/' || (r->>'needs_mail') || ' ';  -- email_replaced/true
--       v_out := v_out || 'auth이메일=' || (SELECT email FROM auth.users WHERE id = (r->>'auth_id')::uuid) || ' ';                                    -- zz-526-b@…
--       -- 4) 설정 뒤 이메일 수정
--       UPDATE public.brand_accounts SET password_set_at = now() WHERE auth_id = (r->>'auth_id')::uuid;
--       UPDATE public.brands SET contacts = '[{"id":"c1","email":"zz-526-c@example.invalid","is_primary":true}]' WHERE id = b1;
--       r := public.admin_upsert_brand_owner_account(b1, 'c1', 'zz-526-b@example.invalid'); v_out := v_out || '4=' || (r->>'result') || ' ';        -- password_already_set
--       -- 5) 대표 표시가 다른 줄로 옮겨짐
--       UPDATE public.brands SET contacts = '[{"id":"c2","email":"zz-526-d@example.invalid","is_primary":true}]' WHERE id = b1;
--       r := public.admin_upsert_brand_owner_account(b1, 'c1', 'zz-526-c@example.invalid'); v_out := v_out || '5=' || (r->>'result') || ' ';        -- primary_moved
--       -- 6) 충돌 셋 (연결 없는 새 브랜드)
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-526-b2', jsonb_build_array(jsonb_build_object('id','x','email',v_inf_email,'is_primary',true))) RETURNING id INTO b2;
--       r := public.admin_upsert_brand_owner_account(b2, NULL, NULL); v_out := v_out || '6a=' || (r->>'result') || ' ';                              -- conflict_influencer (회원 이메일이 하나라도 있을 때)
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-526-b3', jsonb_build_array(jsonb_build_object('id','x','email',v_adm_email,'is_primary',true))) RETURNING id INTO b3;
--       r := public.admin_upsert_brand_owner_account(b3, NULL, NULL); v_out := v_out || '6b=' || (r->>'result') || ' ';                              -- conflict_admin
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-526-b4', '[{"id":"x","email":"zz-526-b@example.invalid","is_primary":true}]') RETURNING id INTO b4;
--       r := public.admin_upsert_brand_owner_account(b4, NULL, NULL); v_out := v_out || '6c=' || (r->>'result') || ' ';                              -- conflict_brand
--       -- 7) 상태·판정 함수
--       v_out := v_out || '상태=' || (public.admin_get_brand_account_status(b1)->>'status') || ' ';                                                   -- active
--       -- 8) 대표 이메일 없음
--       UPDATE public.brands SET contacts = '[]' WHERE id = b4;
--       r := public.admin_upsert_brand_owner_account(b4, NULL, NULL); v_out := v_out || '8=' || (r->>'result') || ' ';                              -- no_primary_email
--       RAISE EXCEPTION '526 시험 결과(전부 되돌림): %', v_out;
--     END $$;
--     기대: 오류 창에 「1=created 2=noop 3=email_replaced/true auth이메일=zz-526-b@example.invalid 4=password_already_set 5=primary_moved
--           6a=conflict_influencer 6b=conflict_admin 6c=conflict_brand 상태=active 8=no_primary_email」 한 줄(의도된 예외).
--     그다음 따로: SELECT count(*) FROM auth.users WHERE email LIKE 'zz-526-%';  SELECT count(*) FROM public.brands WHERE name LIKE 'zz-526-%'; → 둘 다 0 (0 이 아니면 멈추고 알릴 것)
--     ⚠️ 이 시험은 요청 제한·링크 번호 발급(service_*)·설정 완료 함수를 다루지 않는다 — 아래 V5.
--   [V5] 링크·설정 완료 함수 — 같은 방식의 되돌림 DO 블록 (브랜드 계정 하나를 만들고 임시 세션 대신 클레임으로 그 계정을 흉내낸다)
--     DO $$
--     DECLARE
--       v_admin uuid := '<ADMIN_AUTH_ID>';
--       b1 uuid; r jsonb; v_acct uuid; v_link uuid; v_link2 uuid; v_out text := '';
--     BEGIN
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-526-b5',
--         '[{"id":"c1","name":"시험","email":"zz-526-e@example.invalid","is_primary":true}]') RETURNING id INTO b1;
--       r := public.admin_upsert_brand_owner_account(b1, NULL, NULL);  v_acct := (r->>'auth_id')::uuid;
--       r := public.service_issue_brand_account_link(v_acct, 'auto');   v_link := (r->>'link_id')::uuid;
--       v_out := v_out || '발급=' || (r->>'kind') || ' ';                                                       -- setup
--       v_out := v_out || 'setup유효=' || public.get_brand_link_state(v_link, 'setup') || ' ';                  -- valid
--       v_out := v_out || 'reset종류=' || public.get_brand_link_state(v_link, 'reset') || ' ';                  -- invalid (종류 불일치)
--       r := public.service_issue_brand_account_link(v_acct, 'setup');  v_link2 := (r->>'link_id')::uuid;   -- 번호 교체
--       v_out := v_out || '옛링크=' || public.get_brand_link_state(v_link, 'setup') || ' ';                     -- invalid
--       v_out := v_out || '기록=' || public.service_mark_brand_setup_mail_sent(v_acct, v_link2, 'zz-526-e@example.invalid')::text || ' ';  -- true
--       v_out := v_out || '상태1=' || (public.admin_get_brand_account_status(b1)->>'status') || ' ';            -- mail_sent
--       -- 이제 이 계정으로 로그인한 척
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', v_acct, 'role', 'authenticated')::text, true);
--       v_out := v_out || '완료전=' || (public.get_my_brand_login_state()->>'state') || ' ';                    -- setup_incomplete
--       v_out := v_out || '비번없음=' || public.complete_brand_account_setup(v_link2, 'v-test') || ' ';         -- password_not_set
--       UPDATE auth.users SET encrypted_password = 'x' WHERE id = v_acct;                                   -- 비밀번호가 바뀐 척
--       v_out := v_out || '다른링크=' || public.complete_brand_account_setup(gen_random_uuid(), 'v-test') || ' ';  -- link_mismatch
--       v_out := v_out || '완료=' || public.complete_brand_account_setup(v_link2, 'v-test') || ' ';             -- ok
--       v_out := v_out || '재호출=' || public.complete_brand_account_setup(v_link2, 'v-test') || ' ';           -- already_set
--       v_out := v_out || '완료후=' || (public.get_my_brand_login_state()->>'state') || ' ';                    -- ok
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
--       r := public.service_issue_brand_account_link(v_acct, 'auto');   v_link := (r->>'link_id')::uuid;
--       v_out := v_out || '재설정종류=' || (r->>'kind') || '/' || public.get_brand_link_state(v_link, 'reset') || ' ';  -- reset/valid
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', v_acct, 'role', 'authenticated')::text, true);
--       v_out := v_out || '재설정완료=' || public.complete_brand_password_reset(v_link) || '/' || public.get_brand_link_state(v_link, 'reset') || ' ';  -- ok/invalid
--       RAISE EXCEPTION '526 V5 시험 결과(전부 되돌림): %', v_out;
--     END $$;
--     기대: 「발급=setup setup유효=valid reset종류=invalid 옛링크=invalid 기록=true 상태1=mail_sent 완료전=setup_incomplete 비번없음=password_not_set
--           다른링크=link_mismatch 완료=ok 재호출=already_set 완료후=ok 재설정종류=reset/valid 재설정완료=ok/invalid」
--     그다음 따로: SELECT count(*) FROM auth.users WHERE email LIKE 'zz-526-%'; → 0
--   [V6] 🔁 회귀: 인플루언서 신규 가입 1회 · 관리자 초대 1회 (이 파일은 그 함수들을 안 바꾸지만 같은 auth.users 에 삽입하는 코드가 늘었으므로 한 번)
--
-- 가입 관문·정리 트리거와의 상호작용은 525 머리말 끝부분과 위 D-[D] 참조. 이 파일은 그 트리거들을 바꾸지 않는다.
-- ============================================================

BEGIN;

-- ── 0. 내부 도우미 — 이 이메일을 쓰는 계정이 누구인가 ───────────────────
--   반환: {"kind":"none|admin|brand|influencer","auth_id":<uuid|null>}
--   우선순위 admin > brand > influencer. 호출자(DEFINER 함수)만 부른다.
CREATE OR REPLACE FUNCTION public._brand_email_owner(p_email text, p_exclude_auth uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id   uuid;
  v_kind text;
BEGIN
  -- 같은 이메일(대소문자·공백 무시)을 쓰는 행이 여럿일 수 있다 — 전부 보고 우선순위 admin > brand > influencer 로 고른다
  SELECT u.id,
         CASE WHEN EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = u.id) THEN 'admin'
              WHEN EXISTS (SELECT 1 FROM public.brand_accounts ba WHERE ba.auth_id = u.id) THEN 'brand'
              ELSE 'influencer' END
    INTO v_id, v_kind
    FROM auth.users u
   WHERE lower(btrim(u.email)) = lower(btrim(COALESCE(p_email, '')))
     AND (p_exclude_auth IS NULL OR u.id <> p_exclude_auth)
   ORDER BY CASE WHEN EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = u.id) THEN 0
                 WHEN EXISTS (SELECT 1 FROM public.brand_accounts ba WHERE ba.auth_id = u.id) THEN 1
                 ELSE 2 END,
            u.created_at
   LIMIT 1;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('kind', 'none', 'auth_id', NULL);
  END IF;

  RETURN jsonb_build_object('kind', v_kind, 'auth_id', v_id);
END;
$$;

COMMENT ON FUNCTION public._brand_email_owner(text, uuid) IS
  '[526] 내부 도우미. 이메일(lower(btrim()))을 쓰는 auth.users 계정이 admin / brand / influencer(그 밖 모두) / none 중 무엇인지. 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_email_owner(text, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_email_owner(text, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_email_owner(text, uuid) FROM anon, authenticated;

-- ── 1. admin_upsert_brand_owner_account ────────────────────────────────
--   판정 규칙은 머리말 B 표. 반환 jsonb 칸: result · needs_mail · email · auth_id · account_email · brand_id
CREATE OR REPLACE FUNCTION public.admin_upsert_brand_owner_account(
  p_brand_id        uuid,
  p_prev_contact_id text,
  p_prev_email      text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status     text;
  v_contacts   jsonb;
  v_prim       jsonb;
  v_cur_id     text;
  v_email      text;
  v_prev_email text;
  v_name       text;
  v_phone      text;
  v_link       public.brand_account_links%ROWTYPE;
  v_acct       public.brand_accounts%ROWTYPE;
  v_owner      jsonb;
  v_kind       text;
  v_owner_id   uuid;
  v_new_id     uuid;
  v_result     text;
  v_needs      boolean := false;
  v_auth       uuid;
  v_acct_email text;
  v_moved      boolean;
  v_cname      text;
BEGIN
  -- (0) 가드·입력 검사 -------------------------------------------------
  IF NOT public.is_campaign_admin() THEN
    RETURN jsonb_build_object('result', 'forbidden', 'needs_mail', false);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'needs_mail', false);
  END IF;

  -- 브랜드 단위 직렬화(같은 브랜드를 두 관리자가 동시에 저장해도 연결이 둘 생기지 않게)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT b.status, COALESCE(b.contacts, '[]'::jsonb)
    INTO v_status, v_contacts
    FROM public.brands b
   WHERE b.id = p_brand_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'needs_mail', false);
  END IF;
  IF v_status <> 'active' THEN
    RETURN jsonb_build_object('result', 'brand_archived', 'needs_mail', false, 'brand_id', p_brand_id);
  END IF;

  -- 대표 줄 = contacts 의 is_primary 줄(여럿이면 앞선 것)
  IF jsonb_typeof(v_contacts) = 'array' THEN
    SELECT e.elem INTO v_prim
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
     WHERE e.elem->>'is_primary' = 'true'
     ORDER BY e.ord
     LIMIT 1;
  END IF;

  v_email := lower(btrim(COALESCE(v_prim->>'email', '')));
  IF v_prim IS NULL OR v_email = '' THEN
    RETURN jsonb_build_object('result', 'no_primary_email', 'needs_mail', false, 'brand_id', p_brand_id);
  END IF;
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
  END IF;

  v_cur_id     := NULLIF(btrim(COALESCE(v_prim->>'id', '')), '');
  v_name       := NULLIF(btrim(COALESCE(v_prim->>'name', '')), '');
  v_phone      := NULLIF(btrim(COALESCE(v_prim->>'phone', '')), '');
  v_prev_email := lower(btrim(COALESCE(p_prev_email, '')));
  v_moved      := p_prev_contact_id IS NOT NULL AND v_cur_id IS NOT NULL AND p_prev_contact_id <> v_cur_id;

  -- 같은 이메일을 두고 다투는 호출(서로 다른 브랜드)도 직렬화한다
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  SELECT l.* INTO v_link
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active';

  IF NOT FOUND THEN
    -- (1) 활성 대표 연결 없음 — 이전 값은 보지 않는다(P-2) ----------------
    v_owner    := public._brand_email_owner(v_email, NULL);
    v_kind     := v_owner->>'kind';
    v_owner_id := NULLIF(v_owner->>'auth_id', '')::uuid;

    IF v_kind = 'admin' THEN
      RETURN jsonb_build_object('result', 'conflict_admin', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    ELSIF v_kind = 'influencer' THEN
      RETURN jsonb_build_object('result', 'conflict_influencer', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
    ELSIF v_kind = 'brand' THEN
      SELECT ba.* INTO v_acct FROM public.brand_accounts ba WHERE ba.auth_id = v_owner_id FOR UPDATE;
      IF EXISTS (SELECT 1 FROM public.brand_account_links l2
                  WHERE l2.auth_id = v_owner_id AND l2.status = 'active' AND l2.brand_id <> p_brand_id) THEN
        RETURN jsonb_build_object('result', 'conflict_brand', 'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
      END IF;
      -- 연결이 없는(해제된) 계정을 재사용: 이 브랜드의 대표로 연결만 새로 만든다
      UPDATE public.brand_account_links
         SET role = 'owner', source_contact_id = v_cur_id
       WHERE auth_id = v_owner_id AND brand_id = p_brand_id AND status = 'active';
      IF NOT FOUND THEN
        INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id)
        VALUES (v_owner_id, p_brand_id, 'owner', 'active', v_cur_id);
      END IF;
      v_result     := 'created';
      v_needs      := v_acct.password_set_at IS NULL;
      v_auth       := v_owner_id;
      v_acct_email := v_acct.email;
    ELSE
      -- 아무도 안 쓰는 이메일 — 계정 새로 만들기(417 방식 직접 삽입)
      v_new_id := gen_random_uuid();
      BEGIN
        INSERT INTO auth.users (
          instance_id, id, aud, role, email,
          encrypted_password, email_confirmed_at,
          created_at, updated_at,
          confirmation_token, recovery_token,
          email_change, email_change_token_new, email_change_token_current,
          phone_change, phone_change_token, reauthentication_token,
          raw_app_meta_data, raw_user_meta_data
        ) VALUES (
          '00000000-0000-0000-0000-000000000000',
          v_new_id, 'authenticated', 'authenticated', v_email,
          '',                      -- 비밀번호 미설정 — 로그인 불가 상태(설정 링크로만 정해진다)
          now(), now(), now(),
          '', '', '', '', '', '', '', '',
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'account_kind', 'brand'),
          jsonb_build_object('sub', v_new_id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false)
        );
        INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
        VALUES (
          gen_random_uuid(), v_new_id,
          jsonb_build_object('sub', v_new_id::text, 'email', v_email, 'email_verified', true),
          'email', v_new_id::text, now(), now()
        );
        INSERT INTO public.brand_accounts (auth_id, email, name, phone, created_by)
        VALUES (v_new_id, v_email, v_name, v_phone, auth.uid());
        INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id)
        VALUES (v_new_id, p_brand_id, 'owner', 'active', v_cur_id);
      EXCEPTION WHEN unique_violation THEN
        -- 부분 삽입은 이 블록 안에서 되돌려진다. 동시에 같은 이메일로 다른 경로가 계정을 만든 드문 경우.
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        RETURN jsonb_build_object(
          'result', CASE WHEN v_cname LIKE 'brand_account%' THEN 'conflict_brand' ELSE 'conflict_influencer' END,
          'needs_mail', false, 'email', v_email, 'brand_id', p_brand_id);
      END;
      v_result     := 'created';
      v_needs      := true;
      v_auth       := v_new_id;
      v_acct_email := v_email;
    END IF;

  ELSE
    -- (2) 활성 대표 연결 있음(계정 A) ------------------------------------
    SELECT ba.* INTO v_acct FROM public.brand_accounts ba WHERE ba.auth_id = v_link.auth_id FOR UPDATE;
    v_auth       := v_acct.auth_id;
    v_acct_email := v_acct.email;

    IF v_email = v_acct.email OR v_email = v_prev_email THEN
      -- ① 로그인 이메일과 같음 / ② 이번 저장에서 이메일이 안 바뀜
      v_result := 'noop';
      IF v_email = v_acct.email THEN
        -- 이 줄이 A 의 대표 줄이다 — 근거 줄 id·이름·전화를 현재 값으로 맞춘다(메일은 없음)
        IF v_link.source_contact_id IS DISTINCT FROM v_cur_id THEN
          UPDATE public.brand_account_links SET source_contact_id = v_cur_id WHERE id = v_link.id;
        END IF;
        IF v_acct.name IS DISTINCT FROM v_name OR v_acct.phone IS DISTINCT FROM v_phone THEN
          UPDATE public.brand_accounts SET name = v_name, phone = v_phone WHERE auth_id = v_acct.auth_id;
        END IF;
      END IF;

    ELSIF v_moved THEN
      -- ③ 대표 표시가 다른 줄로 옮겨짐 — 옛 계정 유지, 메일 없음
      v_result := 'primary_moved';

    ELSIF v_acct.password_set_at IS NULL THEN
      -- ④ 설정 전 이메일 수정 — 계정 이메일 교체 + 옛 링크 무효화
      v_owner    := public._brand_email_owner(v_email, v_acct.auth_id);
      v_kind     := v_owner->>'kind';
      IF v_kind = 'admin' THEN
        RETURN jsonb_build_object('result', 'conflict_admin', 'needs_mail', false, 'email', v_email,
                                  'auth_id', v_auth, 'account_email', v_acct.email, 'brand_id', p_brand_id);
      ELSIF v_kind = 'brand' THEN
        RETURN jsonb_build_object('result', 'conflict_brand', 'needs_mail', false, 'email', v_email,
                                  'auth_id', v_auth, 'account_email', v_acct.email, 'brand_id', p_brand_id);
      ELSIF v_kind = 'influencer' THEN
        RETURN jsonb_build_object('result', 'conflict_influencer', 'needs_mail', false, 'email', v_email,
                                  'auth_id', v_auth, 'account_email', v_acct.email, 'brand_id', p_brand_id);
      END IF;

      BEGIN
        UPDATE auth.users
           SET email             = v_email,
               updated_at        = now(),
               -- 옛 메일의 인증 서비스 일회용 토큰도 비운다(옛 링크로 세션이 생기지 않게 — 526 리뷰 권고)
               recovery_token     = '',
               confirmation_token = '',
               recovery_sent_at   = NULL,
               raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('email', v_email)
         WHERE id = v_acct.auth_id;
        UPDATE auth.identities
           SET identity_data = COALESCE(identity_data, '{}'::jsonb) || jsonb_build_object('email', v_email),
               updated_at    = now()
         WHERE user_id = v_acct.auth_id AND provider = 'email';
        UPDATE public.brand_accounts
           SET email              = v_email,
               name               = v_name,
               phone              = v_phone,
               setup_link_id      = NULL,     -- 옛 링크 무효화. 새 번호는 메일 서버 함수가 발급한다
               setup_mail_sent_at = NULL,
               setup_mail_sent_to = NULL
         WHERE auth_id = v_acct.auth_id;
        UPDATE public.brand_account_links SET source_contact_id = v_cur_id WHERE id = v_link.id;
      EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_cname = CONSTRAINT_NAME;
        RETURN jsonb_build_object(
          'result', CASE WHEN v_cname LIKE 'brand_account%' THEN 'conflict_brand' ELSE 'conflict_influencer' END,
          'needs_mail', false, 'email', v_email, 'auth_id', v_auth, 'account_email', v_acct.email, 'brand_id', p_brand_id);
      END;
      v_result     := 'email_replaced';
      v_needs      := true;
      v_acct_email := v_email;

    ELSE
      -- ⑤ 설정 뒤 이메일 수정 — 로그인 이메일 유지
      v_result := 'password_already_set';
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'result',        v_result,
    'needs_mail',    v_needs,
    'email',         v_email,
    'auth_id',       v_auth,
    'account_email', v_acct_email,
    'brand_id',      p_brand_id
  );
END;
$$;

COMMENT ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) IS
  '[526] 브랜드 대표 담당자 계정 만들기/바꾸기(캠페인 관리자 이상, 안쪽 재확인). 판정 규칙은 526 머리말 B 표. 반환 jsonb: result·needs_mail·email·auth_id·account_email·brand_id.
   result = created·noop·email_replaced·password_already_set·primary_moved·conflict_influencer·conflict_admin·conflict_brand·no_primary_email·invalid_email·brand_not_found·brand_archived·forbidden.';

GRANT  EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM anon;

-- ── 2. admin_get_brand_account_status ──────────────────────────────────
--   {status:'none'|'mail_pending'|'mail_sent'|'active', email, setup_mail_sent_at, password_set_at}
--   관리자가 아니면 오류(42501) — 화면은 실패를 null 로 받는다(「계정 없음」으로 그리지 않는다).
CREATE OR REPLACE FUNCTION public.admin_get_brand_account_status(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_acct   public.brand_accounts%ROWTYPE;
  v_status text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT a.* INTO v_acct
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active'
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('status', 'none', 'email', NULL, 'setup_mail_sent_at', NULL, 'password_set_at', NULL);
  END IF;

  v_status := CASE
                WHEN v_acct.password_set_at IS NOT NULL THEN 'active'
                WHEN v_acct.setup_mail_sent_at IS NOT NULL THEN 'mail_sent'
                ELSE 'mail_pending'
              END;

  RETURN jsonb_build_object(
    'status',             v_status,
    'email',              v_acct.email,
    'setup_mail_sent_at', v_acct.setup_mail_sent_at,
    'password_set_at',    v_acct.password_set_at
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_account_status(uuid) IS
  '[526] 관리자 화면 계정 줄 상태. none(연결 없음) / mail_pending(설정 메일 미발송) / mail_sent / active(비밀번호 설정됨). is_admin() 아니면 42501.';

GRANT  EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) FROM anon;

-- ── 3. get_brand_link_state ────────────────────────────────────────────
--   링크 유효 판정(비로그인 가능). 'valid' | 'invalid' 두 값만 — 이메일 등 다른 정보는 돌려주지 않는다(머리말 D-[A]·[F]).
--   kind: 'setup' = 비밀번호 미설정 계정의 링크 / 'reset' = 설정된 계정의 링크. 그 밖 값은 invalid.
CREATE OR REPLACE FUNCTION public.get_brand_link_state(p_link_id uuid, p_kind text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_link_id IS NULL OR p_kind IS NULL OR p_kind NOT IN ('setup', 'reset') THEN
    RETURN 'invalid';
  END IF;

  IF EXISTS (
    SELECT 1
      FROM public.brand_accounts a
     WHERE a.setup_link_id = p_link_id
       AND ((p_kind = 'setup' AND a.password_set_at IS NULL)
         OR (p_kind = 'reset' AND a.password_set_at IS NOT NULL))
       AND EXISTS (SELECT 1
                     FROM public.brand_account_links l
                     JOIN public.brands b ON b.id = l.brand_id
                    WHERE l.auth_id = a.auth_id AND l.status = 'active' AND b.status = 'active')
  ) THEN
    RETURN 'valid';
  END IF;
  RETURN 'invalid';
END;
$$;

COMMENT ON FUNCTION public.get_brand_link_state(uuid, text) IS
  '[526] 계정 만들기(setup)/비밀번호 재설정(reset) 링크 유효 판정. 링크 번호가 계정의 setup_link_id 와 같고 종류가 계정 상태(password_set_at)와 맞고 활성 브랜드 연결이 있으면 valid. 비로그인 가능, 이메일 반환 안 함.';

GRANT  EXECUTE ON FUNCTION public.get_brand_link_state(uuid, text) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_link_state(uuid, text) FROM PUBLIC;

-- ── 4. complete_brand_account_setup ────────────────────────────────────
--   설정 링크로 생긴 임시 세션이 부른다(auth.uid() = 그 계정). 화면은 updateUser({password}) 를 먼저 하고 이 함수를 부른다(머리말 D-[B]).
--   'ok' | 'link_mismatch' | 'already_set' | 'not_brand' | 'password_not_set'(526 추가)
CREATE OR REPLACE FUNCTION public.complete_brand_account_setup(p_link_id uuid, p_terms_version text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_acct public.brand_accounts%ROWTYPE;
  v_pw   text;
BEGIN
  IF v_uid IS NULL THEN
    RETURN 'not_brand';
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 'not_brand';
  END IF;

  -- 이미 끝난 계정이면 링크 번호가 비어 있어도 「이미 설정됨」으로 알린다(link_mismatch 보다 먼저)
  IF v_acct.password_set_at IS NOT NULL THEN
    RETURN 'already_set';
  END IF;

  IF p_link_id IS NULL OR v_acct.setup_link_id IS DISTINCT FROM p_link_id THEN
    RETURN 'link_mismatch';
  END IF;

  IF p_terms_version IS NULL OR btrim(p_terms_version) = '' THEN
    RAISE EXCEPTION 'terms_version_required' USING ERRCODE = '22023';
  END IF;

  -- 비밀번호가 실제로 정해졌는지(화면 순서: updateUser 먼저)
  SELECT u.encrypted_password INTO v_pw FROM auth.users u WHERE u.id = v_uid;
  IF v_pw IS NULL OR v_pw = '' THEN
    RETURN 'password_not_set';
  END IF;

  UPDATE public.brand_accounts
     SET password_set_at   = now(),
         terms_agreed_at   = now(),
         privacy_agreed_at = now(),
         terms_version     = btrim(p_terms_version),
         setup_link_id     = NULL
   WHERE auth_id = v_uid;

  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.complete_brand_account_setup(uuid, text) IS
  '[526] 브랜드 계정 설정 완료 기록(약관·개인정보 동의 시각은 서버 now()). 링크 번호가 맞고 비밀번호가 실제로 정해졌을 때만 ok. 결과: ok·link_mismatch·already_set·not_brand·password_not_set.';

GRANT  EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) FROM anon;

-- ── 5. complete_brand_password_reset ───────────────────────────────────
--   재설정 완료 뒤 링크 번호 비우기(F-2 「이미 사용됨」). 'ok' | 'link_mismatch' | 'not_brand'
CREATE OR REPLACE FUNCTION public.complete_brand_password_reset(p_link_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_acct public.brand_accounts%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN 'not_brand';
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RETURN 'not_brand';
  END IF;

  -- 재설정 링크는 설정이 끝난 계정의 것이어야 한다(미설정 계정의 번호는 설정 링크 몫)
  IF p_link_id IS NULL OR v_acct.password_set_at IS NULL OR v_acct.setup_link_id IS DISTINCT FROM p_link_id THEN
    RETURN 'link_mismatch';
  END IF;

  UPDATE public.brand_accounts SET setup_link_id = NULL WHERE auth_id = v_uid;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.complete_brand_password_reset(uuid) IS
  '[526] 비밀번호 재설정 완료 뒤 링크 번호(setup_link_id)를 비운다. 설정이 끝난 계정 + 번호 일치일 때만 ok. 결과: ok·link_mismatch·not_brand.';

GRANT  EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) FROM anon;

-- ── 6. get_my_brand_login_state ────────────────────────────────────────
--   로그인 직후 판정. {state:'ok'|'not_brand'|'setup_incomplete'|'no_active_brand', name, email, brands:[{id,name,role}]}
--   P-9: 보관(archived) 브랜드 연결은 빼고 센다.
--   🔴 호출 실패(null)를 「차단」으로 처리하는 쪽은 화면 몫 — 이 함수는 로그인 상태에서만 부른다.
CREATE OR REPLACE FUNCTION public.get_my_brand_login_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := auth.uid();
  v_acct   public.brand_accounts%ROWTYPE;
  v_brands jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb);
  END IF;

  IF v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('state', 'setup_incomplete', 'name', v_acct.name, 'email', v_acct.email, 'brands', '[]'::jsonb);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'role', l.role)
                            ORDER BY (l.role = 'owner') DESC, b.name), '[]'::jsonb)
    INTO v_brands
    FROM public.brand_account_links l
    JOIN public.brands b ON b.id = l.brand_id
   WHERE l.auth_id = v_uid AND l.status = 'active' AND b.status = 'active';

  RETURN jsonb_build_object(
    'state',  CASE WHEN jsonb_array_length(v_brands) = 0 THEN 'no_active_brand' ELSE 'ok' END,
    'name',   v_acct.name,
    'email',  v_acct.email,
    'brands', v_brands
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_login_state() IS
  '[526] 브랜드 로그인 직후 판정. not_brand(브랜드 계정 아님) / setup_incomplete(비밀번호 설정 미완료) / no_active_brand(활성 브랜드 연결 없음 — 보관 브랜드는 안 센다, P-9) / ok. authenticated 전용.';

GRANT  EXECUTE ON FUNCTION public.get_my_brand_login_state() TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_login_state() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_login_state() FROM anon;

-- ── 7. check_brand_password_reset_rate_limit (243 복제) ─────────────────
--   요청 제한 3층 중 ①이메일별(5분 1회·24시간 5회) ②전역(시간당 30건, 매칭 무관). ③ 형식·길이는 서버 함수가 DB 전에 거른다.
--   판정과 무관하게 항상 1행 기록(243 설계 결정 그대로). 락 키만 다르다 — 관리자 비밀번호 찾기와 서로 막지 않는다.
CREATE OR REPLACE FUNCTION public.check_brand_password_reset_rate_limit(
  p_email_hash text,
  p_matched    boolean
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_short_count  integer;
  v_day_count    integer;
  v_global_count integer;
  v_allowed      boolean := true;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('brand_password_reset_rate_limit'));

  SELECT count(*) INTO v_short_count
    FROM public.brand_password_reset_requests
   WHERE email_hash = p_email_hash
     AND requested_at > now() - interval '5 minutes';
  IF v_short_count > 0 THEN
    v_allowed := false;
  END IF;

  IF v_allowed THEN
    SELECT count(*) INTO v_day_count
      FROM public.brand_password_reset_requests
     WHERE email_hash = p_email_hash
       AND requested_at > now() - interval '24 hours';
    IF v_day_count >= 5 THEN
      v_allowed := false;
    END IF;
  END IF;

  IF v_allowed THEN
    SELECT count(*) INTO v_global_count
      FROM public.brand_password_reset_requests
     WHERE requested_at > now() - interval '1 hour';
    IF v_global_count >= 30 THEN
      v_allowed := false;
      RAISE WARNING '[check_brand_password_reset_rate_limit] global rate limit exceeded (count=%)', v_global_count;
    END IF;
  END IF;

  INSERT INTO public.brand_password_reset_requests (email_hash, matched, requested_at)
  VALUES (p_email_hash, p_matched, now());

  RETURN v_allowed;
END;
$$;

COMMENT ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) IS
  '[526] 브랜드 비밀번호 찾기 요청 제한 판정(243 복제). 이메일별 5분1회·24시간5회 + 전역 시간당30건을 원자적으로 판정하고 결과와 무관하게 항상 기록. service_role 전용.';

GRANT  EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.check_brand_password_reset_rate_limit(text, boolean) FROM anon, authenticated;

-- ── 8. 30일 정리 + pg_cron ─────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.purge_old_brand_password_reset_requests()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff  timestamptz := now() - interval '30 days';
  v_deleted integer;
BEGIN
  DELETE FROM public.brand_password_reset_requests WHERE requested_at < v_cutoff;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RAISE NOTICE '[purge_old_brand_password_reset_requests] cutoff=% deleted=% rows', v_cutoff, v_deleted;
  RETURN v_deleted;
END;
$$;

COMMENT ON FUNCTION public.purge_old_brand_password_reset_requests() IS
  '[526] 브랜드 비밀번호 찾기 요청 기록 30일 정리(243 과 같은 기간). postgres(pg_cron) 전용. pg_cron: brand-password-reset-requests-retention-daily (UTC 21:00 = KST 06:00).';

GRANT  EXECUTE ON FUNCTION public.purge_old_brand_password_reset_requests() TO postgres;
REVOKE EXECUTE ON FUNCTION public.purge_old_brand_password_reset_requests() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.purge_old_brand_password_reset_requests() FROM anon, authenticated, service_role;

-- 예약: 기존 정리 작업(UTC 19:00~20:45 사이 15분 간격으로 이미 채워짐, 243 은 19:15)과 겹치지 않는 UTC 21:00. 멱등(있으면 먼저 해제).
SELECT cron.unschedule(jobid)
  FROM cron.job
 WHERE jobname = 'brand-password-reset-requests-retention-daily';

SELECT cron.schedule(
  'brand-password-reset-requests-retention-daily',
  '0 21 * * *',
  $$
  SELECT public.purge_old_brand_password_reset_requests();
  $$
);

-- ── 9. 서비스 키 전용 보조 — 메일 서버 함수(조각 4·5)용 ─────────────────────
--   계정을 찾는 조회(이메일·브랜드로)는 서버 함수가 표를 직접 읽는다(service_role 은 RLS 우회, 이메일은 정규화 저장).
--   링크 번호 교체 + 발송 기록만 함수로 둔다 — 종류 판정과 활성 연결 확인을 두 서버 함수가 따로 쓰면 사본이 생기므로(머리말 D-[E]).

-- 9-1. 새 링크 번호 발급. p_kind: 'setup' | 'reset' | 'auto'(계정 상태로 정함)
--   성공: {ok:true, kind, link_id, email, name}   실패: {ok:false, reason}
--   reason = no_account · no_active_brand · password_already_set(setup 요청인데 이미 설정됨) · password_not_set(reset 요청인데 미설정) · invalid_kind
CREATE OR REPLACE FUNCTION public.service_issue_brand_account_link(p_auth_id uuid, p_kind text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_acct public.brand_accounts%ROWTYPE;
  v_kind text;
  v_link uuid;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('setup', 'reset', 'auto') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_kind');
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = p_auth_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_account');
  END IF;

  IF NOT EXISTS (SELECT 1
                   FROM public.brand_account_links l
                   JOIN public.brands b ON b.id = l.brand_id
                  WHERE l.auth_id = p_auth_id AND l.status = 'active' AND b.status = 'active') THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no_active_brand');
  END IF;

  v_kind := CASE WHEN p_kind = 'auto'
                 THEN CASE WHEN v_acct.password_set_at IS NULL THEN 'setup' ELSE 'reset' END
                 ELSE p_kind END;
  IF v_kind = 'setup' AND v_acct.password_set_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'password_already_set');
  END IF;
  IF v_kind = 'reset' AND v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'password_not_set');
  END IF;

  v_link := gen_random_uuid();
  UPDATE public.brand_accounts SET setup_link_id = v_link WHERE auth_id = p_auth_id;

  RETURN jsonb_build_object('ok', true, 'kind', v_kind, 'link_id', v_link, 'email', v_acct.email, 'name', v_acct.name);
END;
$$;

COMMENT ON FUNCTION public.service_issue_brand_account_link(uuid, text) IS
  '[526] 서비스 키 전용. 설정/재설정 메일을 보내기 직전 새 링크 번호(setup_link_id)를 발급해 앞선 링크를 모두 무효화한다. 종류가 계정 상태와 맞는지·활성 브랜드 연결이 있는지 한 곳에서 판정.';

GRANT  EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) FROM anon, authenticated;

-- 9-2. 설정 메일 발송 기록. 그 사이 새 링크가 발급됐으면(번호 불일치) 기록하지 않는다.
CREATE OR REPLACE FUNCTION public.service_mark_brand_setup_mail_sent(p_auth_id uuid, p_link_id uuid, p_sent_to text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE public.brand_accounts
     SET setup_mail_sent_at = now(),
         setup_mail_sent_to = lower(btrim(p_sent_to))
   WHERE auth_id = p_auth_id
     AND setup_link_id = p_link_id
     AND password_set_at IS NULL;
  RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text) IS
  '[526] 서비스 키 전용. 설정(setup) 메일 발송 시각·주소 기록. 링크 번호가 아직 현재 번호이고 비밀번호 미설정일 때만 기록(true). 재설정 메일은 기록하지 않는다.';

GRANT  EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text) FROM anon, authenticated;

COMMIT;
