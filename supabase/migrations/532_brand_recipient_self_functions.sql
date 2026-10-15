-- ============================================================
-- 532_brand_recipient_self_functions.sql
-- 브랜드 멤버 관리·여러 브랜드 — 작업 3: 받는 사람·본인 함수 + 527 넓히기
--   작업표 docs/specs/2026-10-15-brand-member-breakdown.md 「작업 3」·「착수 전 선결 조건」S0-4·「사양서와 코드가 어긋나는 곳」2·3·4번
--   사양서 docs/specs/2026-07-15-brand-portal.md §16 머리 「낱말 정의」·16-3·16-4(화면 정책 넷 ③)·16-7
--
-- 목적
--   ① 새 함수 11개
--        공개(비로그인 포함) 1 : get_brand_invite_link_state
--        로그인 사용자 7      : respond_brand_invite · get_my_brand_invites · mark_my_brand_mypage_seen · touch_my_brand_activity ·
--                              set_my_brand_last_viewed · update_my_brand_profile · mark_my_brand_password_changed
--        서비스 키 전용 2     : service_brand_invite_create_account · service_brand_invite_finalize   (조각 6 의 서버 함수가 부른다)
--        안쪽 전용 1          : _brand_acceptable_invites_for                                          (호출 불가)
--   ② 527 함수 여섯 재정의 (CREATE OR REPLACE — 단 service_mark_brand_setup_mail_sent 는 인자가 늘어 옛 3인자를 DROP 후 4인자 생성)
--        get_my_brand_login_state · get_brand_link_state · service_issue_brand_account_link ·
--        complete_brand_account_setup · complete_brand_password_reset · service_mark_brand_setup_mail_sent
--   표·칸은 530 이 만들었다. 이 파일은 함수만 더한다. 비밀번호 원문을 받는 함수는 만들지 않는다(작업표 설계 메모).
--
-- 베이스
--   530 : 표 brand_invites · 칸 brand_accounts.{mypage_seen_at,last_brand_id,password_changed_at,setup_mail_sent_by,created_via_invite_id} ·
--         brand_account_links.last_active_at · 도우미 _brand_invite_acceptable(id, 계정, 링크경로?) · _brand_seat_usage · my_brand_role
--   527 : 재정의하는 여섯의 현재 원본 · _brand_email_owner · 잠금 열쇠 'brand_account_upsert:'||브랜드 → 'brand_account_email:'||이메일 (이 순서)
--         · 새 이메일 인증 계정 직접 삽입 방식(auth.users + auth.identities, 비밀번호 빈칸, raw_app_meta_data.account_kind='brand')
--   531 : create_brand_invite · resend_brand_invite · cancel_brand_invite · release_brand_member (이 파일의 시험이 부른다) · 양식·실행 권한 방식
--
-- ┌ 작업표와 다른 점 (아래가 전부) ──────────────────────────────────────────────┐
--   1) 안쪽 도우미 _brand_acceptable_invites_for(p_auth_id) 를 더했다(작업표 산출 계약에 없음). 「이 계정이 지금 수락할 수 있는 대기 초대」를
--      로그인 판정·받은 초대 목록·527 링크 판정 둘이 같은 식으로 쓰게 하는 한 곳이다. 판정 자체는 530 _brand_invite_acceptable 그대로.
--   2) mark_my_brand_mypage_seen · mark_my_brand_password_changed 의 반환(작업표는 칸이 비어 있음): text.
--        mark_my_brand_mypage_seen   → ok / not_brand
--        mark_my_brand_password_changed → ok / setup_incomplete(비밀번호를 아직 안 정한 계정 — 「변경」이 아니라 기록 안 함) / not_brand
--   3) service_brand_invite_create_account 의 reason 값: invalid_link · name_required(이름 비었음) · terms_required(약관 판 비었음).
--      service_brand_invite_finalize 의 reason 값: invalid_link · password_not_set(인증 계정에 비밀번호가 없음) · already_member(이미 활성 연결).
--      작업표는 reason 값을 나열하지 않았다. 무효 사유는 나누지 않는 원칙대로 링크 무효·갈래 어긋남·취소·만료는 모두 invalid_link 하나다.
--   4) complete_brand_account_setup 도 password_changed_at 을 기록한다. 작업표 산출 계약은 재설정(complete_brand_password_reset)만 적었으나
--      사양서 16-4 「설정·재설정·변경 어느 것이든 마지막으로 비밀번호를 정한 날」을 따랐다(530 [F] 가 기존 행을 password_set_at 으로 채운 것과도 맞는다).
--   5) service_mark_brand_setup_mail_sent 의 p_sent_by 가 admin·self 가 아니면 오류 22023(NULL 은 admin). 작업표는 허용값 밖 처리를 안 적었다 —
--      표 CHECK 제약(530)으로 어차피 막히는데, 호출하는 서버 함수의 오타를 거부로 드러내려는 것.
--   6) get_my_brand_login_state.last_brand_id 의 폴백은 **NULL** 이다(아래 「last_brand_id 기준」).
--   7) update_my_brand_profile · service_brand_invite_create_account 는 이름 100자 · 연락처 50자로 잘라 저장하는 길이 안전 장치를 둔다(작업표에 없음 —
--      표에는 길이 제한이 없고 호출은 공개 키로 누구나 할 수 있다. 화면이 먼저 제한할 것).
--   8) V2 시험은 관리자 계정 번호(<ADMIN_AUTH_ID>) 없이 돈다 — admin_upsert_brand_owner_account 대신 계정·연결을 직접 삽입한다
--      (이 파일의 함수는 관리자 가드가 없다). 대신 527 V5 의 흐름(설정 링크 → 설정 완료 → 비밀번호 찾기)을 같은 순서로 다시 걷는다.
-- └──────────────────────────────────────────────────────────────────────────────────────────────┘
--
-- 🔴 530 확인 사항에 대한 결론 — 「예외 2」(보낼 때 new → 지금 비밀번호를 정한 브랜드 계정)가 sent_owner_auth_id 대조 없이 통과하는 것
--   · 의도대로다. 예외 2 의 조건은 「지금 그 이메일이 비밀번호를 정한 브랜드 계정」이고 계정이 생긴 경로를 묻지 않는다(S0-4 — 다른 초대 수락이든 관리자
--     계정 만들기든). 보낼 때 new 였으므로 대조할 sent_owner_auth_id 자체가 없다(NULL). ⓑ(보낼 때 brand)만 sent_owner_auth_id 로 「그 계정」을 못 박는다
--     (같은 이메일로 계정이 지워졌다 다시 생긴 경우를 막는다).
--   · 「수락하는 사람 = 초대 이메일의 계정인가」는 respond_brand_invite 가 **항상 로그인 계정을 p_auth_id 로 넘기고**, 530 도우미가 가장 먼저
--     brand_accounts.email = 초대 이메일을 요구하는 것으로 지켜진다 — 링크 번호만 안다고 남의 계정이 수락할 수 없다(V2 「다른계정=invalid」·「지목불일치=invalid」).
--     비로그인 판정(get_brand_invite_link_state)은 계정 없이(p_auth_id NULL) 링크만으로 valid 와 브랜드·보낸 사람 이름을 줄 뿐 수락은 못 한다.
--     서비스 키 마무리(service_brand_invite_finalize)도 p_auth_id 를 넘겨 같은 검사를 받는다.
--   · 전제: 계정 일치는 brand_accounts.email, 「지금 이메일 소유 상태」는 auth.users 이메일로 본다. 두 값은 527 email_replaced 가 함께 고쳐 같게 유지된다.
--     (1차에는 로그인 이메일을 바꾸는 기능이 없다 — 나중에 생기면 두 곳을 함께 갱신해야 한다.)
--
-- last_brand_id 기준 (get_my_brand_login_state)
--   · 계정의 last_brand_id 가 **지금 활성 연결 + 활성 브랜드**(= 같은 응답의 brands 배열에 든 것)일 때만 그 값, 아니면 NULL.
--     531 release_brand_member 는 last_brand_id 를 바꾸지 않아 해제된 브랜드를 가리킬 수 있어서 여기서 걸러낸다(그 칸의 값은 지우지 않는다 — 다시 연결되면 살아난다).
--   · NULL 일 때 어느 브랜드로 열지는 화면 몫이다: 사양서 16-4 「이름순 첫 브랜드(한글 가나다 → 영문 ABC)」를 데이터베이스 정렬이 재현하지 못하고
--     (상태 응답의 brands 배열은 대표 먼저·이름순이라 화면 규칙과 다르다), 서버가 짐작한 값이 화면 규칙과 어긋나면 화면이 그 값을 따르게 되기 때문이다.
--   · state 가 ok 가 아닐 때(no_active_brand·setup_incomplete·not_brand)는 늘 NULL.
--
-- 빨간 점(new_invite_dot) 기준
--   · 「수락 가능한 대기 초대」 중 issued_at 이 계정의 mypage_seen_at **보다 늦은 것**이 하나라도 있으면 true. mypage_seen_at 이 NULL(한 번도 안 열었음)이면 초대가 하나라도 있으면 true.
--   · mark_my_brand_mypage_seen 이 mypage_seen_at 을 지금으로 → 같은 순간 이전에 발급된 초대는 점이 꺼지고, 대표가 다시 보내면(531 reissue 가 issued_at 을 지금으로) 다시 켜진다.
--
-- 527 재정의 여섯의 변경 요지 (그 밖은 527 글자 그대로)
--   get_my_brand_login_state            : 키 4개 추가(last_brand_id · has_pending_invite · new_invite_dot · password_changed_at). state 값·기존 키 불변. 활동 기록 안 함.
--   get_brand_link_state                : 「활성 브랜드 연결이 있다」 → 「활성 브랜드 연결이 있거나 수락 가능한 대기 초대가 있다」.
--   service_issue_brand_account_link    : no_active_brand 거부 조건을 같은 식으로 넓힘(reason 이름 불변).
--   complete_brand_account_setup        : password_changed_at 도 기록.
--   complete_brand_password_reset       : password_changed_at 도 기록.
--   service_mark_brand_setup_mail_sent  : 4번째 인자 p_sent_by text DEFAULT 'admin' 추가 + setup_mail_sent_by 기록. 옛 3인자 DROP.
--   · 권한 상태는 527 그대로: get_brand_link_state = anon·authenticated·service_role / complete_* 둘·get_my_brand_login_state = authenticated·service_role (anon 막힘) /
--     service_issue·service_mark = service_role 만.
--
-- A. 함수 표 — 누가 부를 수 있나 (anon / authenticated / service_role·postgres)
--   get_brand_invite_link_state              열림 / 열림 / 열림     (비로그인 화면이 부름)
--   respond_brand_invite                     막힘 / 열림 / 열림
--   get_my_brand_invites                     막힘 / 열림 / 열림
--   mark_my_brand_mypage_seen                막힘 / 열림 / 열림
--   touch_my_brand_activity                  막힘 / 열림 / 열림
--   set_my_brand_last_viewed                 막힘 / 열림 / 열림
--   update_my_brand_profile                  막힘 / 열림 / 열림
--   mark_my_brand_password_changed           막힘 / 열림 / 열림
--   service_brand_invite_create_account      막힘 / 막힘 / 열림     (서비스 키 전용)
--   service_brand_invite_finalize            막힘 / 막힘 / 열림     (서비스 키 전용)
--   _brand_acceptable_invites_for            막힘 / 막힘 / 열림     (안쪽 전용)
--   · 재정의 여섯의 권한은 위 「527 재정의」 끝 줄 그대로. 안쪽 호출은 감싸는 함수가 SECURITY DEFINER 라 산다.
--
-- 설계 판단
--   [A] 수락 경로 셋(respond_brand_invite · service_brand_invite_create_account · service_brand_invite_finalize)은 **527 과 같은 브랜드 잠금 열쇠**
--       'brand_account_upsert:'||brand_id 를 먼저, 이메일 잠금 'brand_account_email:'||이메일 을 그다음에 잡는다(527·531 과 같은 순서 — 데드락 방지).
--       줄은 잠금 **밖에서 한 번**(어느 브랜드·이메일인지 알려고), 잠금 **안에서 다시**(FOR UPDATE) 읽고 링크 번호도 다시 맞춘 뒤 _brand_invite_acceptable 로 판정한다 —
--       기다리는 사이 대표가 다시 보내 옛 링크가 됐거나 취소됐을 수 있다. 조각 4 의 대표 해제가 같은 브랜드 열쇠를 쓰므로 순서가 정해진다(수락이 먼저면 해제 거부 · 해제가 먼저면 수락 거절).
--   [B] 수락 거절 사유는 나누지 않는다(invalid 하나) — 취소·만료·다른 계정·번호 불일치를 구분해 알려 주면 초대 존재를 캐는 길이 된다.
--       already_member · setup_incomplete 는 **수락 가능 판정을 통과한 뒤**(= 초대받은 본인에게만) 나오므로 다른 사람에게 새지 않는다.
--   [C] 수락은 비밀번호 설정을 마친 계정만(setup_incomplete), 거절은 계정 상태와 무관. 자리 수는 다시 검사하지 않는다(보낼 때 막는다 — 대기 초대가 이미 자리를 차지하고 있다).
--       수락해도 「마지막으로 본 브랜드」는 안 바뀐다(마이페이지 수락 정책). 초대 수락 화면은 set_my_brand_last_viewed 를 따로 부른다.
--   [D] touch_my_brand_activity 의 5분 묶기는 이 파일에서 유일한 사본(interval '5 minutes'). 로그인 판정은 활동을 기록하지 않는다(로그인만 한 것은 활동이 아니다).
--   [E] service_brand_invite_create_account 는 인증 계정을 직접 삽입한다(527 방식) — 497 가입 관문·526 가입 트리거·498 미인증 정리와의 상호작용은 작업표 작업 6 「걸리는 장치 대조」 그대로
--       (삽입은 정의자 권한 owner postgres 라 관문 통과, account_kind=brand 라 인플루언서 행 없음, email_confirmed_at 이 채워져 정리 대상 밖).
--       마무리가 거부돼 남은 계정을 지우는 일은 호출하는 서버 함수 몫(연결 없음 · created_via_invite_id = 이 초대 · password_set_at 비어 있음일 때만).
--   [F] respond_brand_invite 의 p_via_link 는 false — 로그인한 쪽 기준(예외 1 재시도는 비로그인 새 이메일 경로 전용이라 여기서는 통과 못 한다).
--
-- 배포 순서
--   1) 526 → 527 → 528 → 530 → 531 이 먼저 들어가 있어야 한다(개발서버에는 있음). 🔴 개발서버만. 운영은 526~532 묶음으로(묶음 ① 전체 보류) — 약관 관문(작업표 S2·/약관확인) 뒤.
--      532 단독 운영 반영 금지: 530·531 이 없으면 없는 표·함수를 불러 로그인 판정(get_my_brand_login_state)이 깨진다.
--      /약관확인 에 넘길 것 — 이 파일이 새로 쌓는 개인정보: 이름·연락처(update_my_brand_profile · 초대 수락 계정 생성) · 약관 동의 시각과 판 ·
--      브랜드별 마지막 활동 시각(last_active_at — 이용 기록) · 마이페이지 확인 시각 · 비밀번호 변경 시각.
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 적용만으로 바뀌는 기존 동작: 로그인 판정에 키 4개가 늘고, 연결이 해제된 계정도 대기 초대가 있으면 비밀번호 찾기·설정 링크를 받는다.
--      service_mark_brand_setup_mail_sent 는 3인자가 4인자(기본값 admin)로 바뀌어도 지금 서버 함수 둘(notify-brand-account-setup · brand-password-reset-request)의 호출이 그대로 돈다.
--      (비밀번호 찾기 재발송이 self 가 아니라 admin 으로 기록되는 것은 조각 7 전까지 받아들인다 — 개발서버 한정.)
--   3) 이 파일 다음은 작업 4(관리자 함수 + 527 권한 교체) · 5(초대 메일 서버 함수) · 6(새 이메일 수락 서버 함수 — 이 파일의 서비스 키 함수 둘을 부른다).
--
-- 되돌리는 방법  (이 순서로)
--   0) 조각 7·화면(②)·서버 함수(조각 5·6)가 이 파일의 함수를 부르고 있으면 그쪽을 먼저 내린다 — 조각 7 이 4번째 인자를 넘기고 있으면 7 을 먼저 되돌린다.
--   1) 🔴 먼저 4인자를 DROP:  DROP FUNCTION IF EXISTS public.service_mark_brand_setup_mail_sent(uuid, uuid, text, text);
--      (4인자를 남긴 채 3인자를 되살리면 기본값 때문에 3인자 호출이 모호 오류가 난다)
--   2) 527 파일에서 해당 구문 여섯을 다시 실행한다(CREATE OR REPLACE 와 그 GRANT/REVOKE 줄까지 — 527 의 §3 get_brand_link_state · §4 complete_brand_account_setup ·
--      §5 complete_brand_password_reset · §6 get_my_brand_login_state · §9-1 service_issue_brand_account_link · §9-2 service_mark_brand_setup_mail_sent(3인자)).
--      3인자는 새로 만드는 것이라 실행 권한 회수(PUBLIC → anon, authenticated)를 반드시 다시 건다.
--   3) 이 파일의 새 함수를 지운다 (도우미를 마지막에 — 2번을 한 뒤여야 넓힌 판정이 도우미를 더 부르지 않는다):
--        DROP FUNCTION IF EXISTS public.service_brand_invite_finalize(uuid, uuid);
--        DROP FUNCTION IF EXISTS public.service_brand_invite_create_account(uuid, text, text, text);
--        DROP FUNCTION IF EXISTS public.mark_my_brand_password_changed();
--        DROP FUNCTION IF EXISTS public.update_my_brand_profile(text, text);
--        DROP FUNCTION IF EXISTS public.set_my_brand_last_viewed(uuid);
--        DROP FUNCTION IF EXISTS public.touch_my_brand_activity(uuid);
--        DROP FUNCTION IF EXISTS public.mark_my_brand_mypage_seen();
--        DROP FUNCTION IF EXISTS public.get_my_brand_invites();
--        DROP FUNCTION IF EXISTS public.respond_brand_invite(uuid, uuid, text);
--        DROP FUNCTION IF EXISTS public.get_brand_invite_link_state(uuid);
--        DROP FUNCTION IF EXISTS public._brand_acceptable_invites_for(uuid);
--   4) 아래 [V1] 을 다시 돌려 527 의 기대 상태(여섯 함수의 권한)로 돌아왔는지 본다.
--   ⚠️ 이 함수들이 만든 데이터(수락된 연결·초대 상태·활동 시각·password_changed_at·setup_mail_sent_by)는 함수를 지워도 남는다.
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   ⚠️ 신규 함수는 「적용 Success」가 동작 확인이 아니다 — [V2] 가 모든 새 함수와 재정의 여섯을 1회 이상 부른다.
--   [V1] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.pronargs, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--      WHERE n.nspname = 'public'
--        AND p.proname IN ('get_brand_invite_link_state','respond_brand_invite','get_my_brand_invites','mark_my_brand_mypage_seen',
--                          'touch_my_brand_activity','set_my_brand_last_viewed','update_my_brand_profile','mark_my_brand_password_changed',
--                          'service_brand_invite_create_account','service_brand_invite_finalize','_brand_acceptable_invites_for',
--                          'get_my_brand_login_state','get_brand_link_state','service_issue_brand_account_link',
--                          'complete_brand_account_setup','complete_brand_password_reset','service_mark_brand_setup_mail_sent')
--      ORDER BY 1;
--     기대: 17행 · acl 맨 앞에 `=X/` 가 어느 행에도 없다 · svc_can 전부 true ·
--           anon_can 은 get_brand_invite_link_state · get_brand_link_state 두 행만 true ·
--           auth_can 은 열두 행 true(get_brand_invite_link_state · respond_brand_invite · get_my_brand_invites · mark_my_brand_mypage_seen · touch_my_brand_activity ·
--                      set_my_brand_last_viewed · update_my_brand_profile · mark_my_brand_password_changed · get_my_brand_login_state · get_brand_link_state ·
--                      complete_brand_account_setup · complete_brand_password_reset), 나머지 다섯(service_brand_invite_create_account · service_brand_invite_finalize ·
--                      _brand_acceptable_invites_for · service_issue_brand_account_link · service_mark_brand_setup_mail_sent)은 false ·
--           service_mark_brand_setup_mail_sent 는 **한 행만**, pronargs = 4 (3인자가 남아 있으면 DROP 이 안 된 것 — 멈추고 알릴 것).
--   [V2] 되돌림 묶음 시험 — 완료 정의 전 항목 + 527 V5 회귀(설정 링크 → 설정 완료 → 비밀번호 찾기). 끝의 RAISE EXCEPTION 이 전부 되돌린다
--     (편집기 자동 커밋 때문에 BEGIN…ROLLBACK 대신 DO 하나로. 시험 이메일은 zz-532-*@example.invalid, 메일은 나가지 않는다. 530 V5·531 V2 와 같은 방식).
--     로그인 흉내(set_config)는 auth.uid() 를 바꿀 뿐이다. 호출 문장과 확인 조회 문장은 일부러 나눴다(한 문장 안의 조회는 호출 전 데이터를 본다 — 531 에서 겪음).
--     시간 의존: 한 트랜잭션 안에서는 now() 가 고정이라 「5분」「빨간 점」은 시간을 되돌려 놓는 UPDATE 로 시험한다(시험 편의).
--     DO $$
--     DECLARE
--       v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b5 uuid;
--       a_o  uuid := gen_random_uuid(); a_m  uuid := gen_random_uuid(); a_x  uuid := gen_random_uuid();
--       a_y  uuid := gen_random_uuid(); a_w  uuid := gen_random_uuid(); a_rr uuid := gen_random_uuid();
--       a_s  uuid := gen_random_uuid(); a_nw uuid; a_nc uuid;
--       i_m uuid; i_y uuid; i_w uuid; i_rr uuid; i_s uuid; i_nw2 uuid; i_nw3 uuid; i_nc uuid;
--       l_m uuid; l_old uuid; l_nw2 uuid; l_nw3 uuid; l_nc uuid; l_a uuid; l_b uuid;
--       v_r jsonb; v_rows jsonb; v_t text; v_t2 text; v_ts timestamptz; v_s1 integer; v_s2 integer;
--       v_out text := '';
--     BEGIN
--       -- ── 준비: 브랜드 4개(b1·b2·b3·b5) · 계정 7개 · 연결 ─────────────────────────
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-532-b1', '[]') RETURNING id INTO v_b1;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-532-b2', '[]') RETURNING id INTO v_b2;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-532-b3', '[]') RETURNING id INTO v_b3;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-532-b5', '[]') RETURNING id INTO v_b5;
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       SELECT '00000000-0000-0000-0000-000000000000'::uuid, t.id,'authenticated','authenticated',t.em,t.pw,now(),now(),now(),
--              '','','','','','','','','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb,
--              jsonb_build_object('sub',t.id::text,'email',t.em,'email_verified',true,'phone_verified',false)
--         FROM (VALUES (a_o,'zz-532-o@example.invalid','x'),(a_m,'zz-532-m@example.invalid','x'),(a_x,'zz-532-x@example.invalid','x'),
--                      (a_y,'zz-532-y@example.invalid','x'),(a_w,'zz-532-w@example.invalid','x'),(a_rr,'zz-532-rr@example.invalid','x'),
--                      (a_s,'zz-532-s@example.invalid','')) AS t(id,em,pw);
--       -- o = 대표(b1·b2·b3) · m = 기존 브랜드 계정(b2 멤버) · x = 연결 없는 외부 계정 · y·w = 초대 받을 기존 계정
--       -- rr = b1 에서 해제된 계정 · s = 비밀번호 미설정 계정(b5 대표)
--       INSERT INTO public.brand_accounts (auth_id,email,name,password_set_at)
--         VALUES (a_o,'zz-532-o@example.invalid','대표O',now()),(a_m,'zz-532-m@example.invalid',NULL,now()),
--                (a_x,'zz-532-x@example.invalid',NULL,now()),(a_y,'zz-532-y@example.invalid',NULL,now()),
--                (a_w,'zz-532-w@example.invalid',NULL,now()),(a_rr,'zz-532-rr@example.invalid',NULL,now()),
--                (a_s,'zz-532-s@example.invalid',NULL,NULL);
--       INSERT INTO public.brand_account_links (auth_id,brand_id,role)
--         VALUES (a_o,v_b1,'owner'),(a_o,v_b2,'owner'),(a_o,v_b3,'owner'),(a_m,v_b2,'member'),(a_s,v_b5,'owner');
--       INSERT INTO public.brand_account_links (auth_id,brand_id,role,status,released_at)
--         VALUES (a_rr,v_b1,'member','released',now());
--     
--       -- ── A. 대표 o 가 b1 에 기존 계정 4명을 초대(전부 ⓑ) ─────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_r := public.create_brand_invite(v_b1, 'zz-532-m@example.invalid');   i_m  := (v_r->>'invite_id')::uuid;  v_t := v_r->>'result';
--       v_r := public.create_brand_invite(v_b1, 'zz-532-y@example.invalid');   i_y  := (v_r->>'invite_id')::uuid;  v_t := v_t || '/' || (v_r->>'result');
--       v_r := public.create_brand_invite(v_b1, 'zz-532-w@example.invalid');   i_w  := (v_r->>'invite_id')::uuid;  v_t := v_t || '/' || (v_r->>'result');
--       v_r := public.create_brand_invite(v_b1, 'zz-532-rr@example.invalid');  i_rr := (v_r->>'invite_id')::uuid;  v_t := v_t || '/' || (v_r->>'result');
--       v_out := v_out || '초대=' || v_t || ' ';
--       SELECT i.link_id INTO l_m FROM public.brand_invites i WHERE i.id = i_m;
--     
--       -- ── B. 링크 판정 · 로그아웃/다른 계정/지목 불일치 ───────────────────────────
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.get_brand_invite_link_state(gen_random_uuid());
--       v_out := v_out || '무작위=' || (v_r->>'state') || '/' || (SELECT count(*) FROM jsonb_object_keys(v_r)) || ' ';
--       v_r := public.get_brand_invite_link_state(l_m);
--       v_out := v_out || '기존계정링크=' || (v_r->>'state') || '/' || (v_r->>'recipient') || '/' || (v_r->>'brand_name') || '/' || (v_r->>'inviter_name') || ' ';
--       v_r := public.respond_brand_invite(NULL, l_m, 'accept');
--       v_out := v_out || '비로그인=' || (v_r->>'result') || ' ';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_x, 'role', 'authenticated')::text, true);
--       v_r := public.respond_brand_invite(NULL, l_m, 'accept');
--       v_out := v_out || '다른계정=' || (v_r->>'result') || '/' || COALESCE(v_r->>'brand_id', 'NULL') || ' ';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_y, 'role', 'authenticated')::text, true);
--       v_r := public.respond_brand_invite(i_y, l_m, 'accept');
--       v_out := v_out || '지목불일치=' || (v_r->>'result') || ' ';
--     
--       -- ── C. m 의 빨간 점: 받은 초대 · 끄기 · 대표가 다시 보내면 다시 켜짐 ───────────
--       UPDATE public.brand_invites SET issued_at = now() - interval '2 hours', expires_at = now() + interval '22 hours' WHERE id = i_m;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_m, 'role', 'authenticated')::text, true);
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || 'm판정=' || (v_r->>'state') || '/' || (v_r->>'has_pending_invite') || '/' || (v_r->>'new_invite_dot') || ' ';
--       v_rows := public.get_my_brand_invites();
--       v_out := v_out || '받은초대=' || jsonb_array_length(v_rows) || '/' || (v_rows->0->>'brand_name') || '/' || (v_rows->0->>'inviter_name')
--                      || '/' || ((v_rows->0->>'invite_id')::uuid = i_m) || ' ';
--       v_t := public.mark_my_brand_mypage_seen();
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '점끄기=' || v_t || '/' || (v_r->>'new_invite_dot') || ' ';
--       UPDATE public.brand_accounts SET mypage_seen_at = now() - interval '1 hour' WHERE auth_id = a_m;   -- 한 시간 전에 마이페이지를 열었던 것으로
--       l_old := l_m;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_r := public.resend_brand_invite(i_m);
--       v_t := v_r->>'result';
--       SELECT i.link_id INTO l_m FROM public.brand_invites i WHERE i.id = i_m;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_m, 'role', 'authenticated')::text, true);
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '다시보내기=' || v_t || '/' || (v_r->>'new_invite_dot') || ' ';
--       v_t := public.get_brand_invite_link_state(l_old)->>'state';
--       v_r := public.respond_brand_invite(NULL, l_old, 'accept');
--       v_out := v_out || '옛링크=' || v_t || '/' || (v_r->>'result') || ' ';
--       v_r := public.respond_brand_invite(NULL, gen_random_uuid(), 'bogus');
--       v_out := v_out || '잘못된동작=' || (v_r->>'result') || ' ';
--     
--       -- ── D. m 이 메일 링크로 수락 ────────────────────────────────────────────────
--       v_r := public.respond_brand_invite(NULL, l_m, 'accept');
--       v_out := v_out || '수락=' || (v_r->>'result') || '/' || ((v_r->>'brand_id')::uuid = v_b1);
--       v_out := v_out || '/' || (SELECT count(*) FROM public.brand_account_links WHERE auth_id = a_m AND brand_id = v_b1 AND role = 'member' AND status = 'active')
--                      || '/' || (SELECT i.status FROM public.brand_invites i WHERE i.id = i_m)
--                      || '/' || (SELECT i.accepted_auth_id = a_m FROM public.brand_invites i WHERE i.id = i_m) || ' ';
--       v_r := public.respond_brand_invite(NULL, l_m, 'accept');
--       v_out := v_out || '수락재호출=' || (v_r->>'result') || ' ';
--     
--       -- ── E. y 가 초대번호로 거절 → 자리 1 감소 ──────────────────────────────────
--       v_s1 := public._brand_seat_usage(v_b1);                     -- 대표 1 + 멤버 m 1 + 대기 3(y·w·rr) = 5
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_y, 'role', 'authenticated')::text, true);
--       v_r := public.respond_brand_invite(i_y, NULL, 'decline');
--       v_s2 := public._brand_seat_usage(v_b1);                     -- 4
--       v_out := v_out || '거절=' || (v_r->>'result') || '/' || v_s1 || '→' || v_s2 || '/' || (SELECT i.status FROM public.brand_invites i WHERE i.id = i_y) || ' ';
--       v_r := public.respond_brand_invite(i_y, NULL, 'decline');
--       v_out := v_out || '거절재호출=' || (v_r->>'result') || ' ';
--     
--       -- ── F. w 가 초대번호로 수락(자리는 다시 검사하지 않는다) ─────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_w, 'role', 'authenticated')::text, true);
--       v_r := public.respond_brand_invite(i_w, NULL, 'accept');
--       v_s2 := public._brand_seat_usage(v_b1);                     -- 대표 1 + 멤버 m·w 2 + 대기 1(rr) = 4
--       v_out := v_out || '수락id=' || (v_r->>'result') || '/' || (SELECT count(*) FROM public.brand_account_links WHERE auth_id = a_w AND brand_id = v_b1 AND status = 'active')
--                      || '/' || v_s2 || ' ';
--     
--       -- ── G. 연결이 모두 해제된 계정 rr: 대기 초대 → 로그인 판정 · 설정 링크 · 재설정 끝까지 ───
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_rr, 'role', 'authenticated')::text, true);
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || 'rr판정=' || (v_r->>'state') || '/' || (v_r->>'has_pending_invite') || '/' || (v_r->>'new_invite_dot')
--                      || '/' || COALESCE(v_r->>'last_brand_id', 'NULL') || ' ';
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.service_issue_brand_account_link(a_rr, 'auto');
--       l_a := (v_r->>'link_id')::uuid;
--       v_t := (v_r->>'ok') || '/' || (v_r->>'kind');
--       v_t2 := public.get_brand_link_state(l_a, 'reset');
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_rr, 'role', 'authenticated')::text, true);
--       v_t := v_t || '/' || v_t2 || '/' || public.complete_brand_password_reset(l_a);
--       v_out := v_out || 'rr재설정=' || v_t || '/' || public.get_brand_link_state(l_a, 'reset')
--                      || '/' || (SELECT a.password_changed_at IS NOT NULL FROM public.brand_accounts a WHERE a.auth_id = a_rr) || ' ';
--       -- 연결도 대기 초대도 없는 x 는 여전히 링크를 못 받는다
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.service_issue_brand_account_link(a_x, 'auto');
--       v_out := v_out || '연결없음x=' || (v_r->>'ok') || '/' || (v_r->>'reason') || ' ';
--     
--       -- ── H. m 의 활동 기록(5분 묶기) · 마지막 브랜드 · 프로필 · 비밀번호 변경 · 해제 뒤 판정 ───
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_m, 'role', 'authenticated')::text, true);
--       v_ts := now() - interval '2 minutes';
--       UPDATE public.brand_account_links SET last_active_at = v_ts WHERE auth_id = a_m AND brand_id = v_b1 AND status = 'active';
--       v_t := public.touch_my_brand_activity(v_b1);
--       v_out := v_out || '5분내=' || v_t || '/' || (SELECT l.last_active_at = v_ts FROM public.brand_account_links l WHERE l.auth_id = a_m AND l.brand_id = v_b1 AND l.status = 'active') || ' ';
--       UPDATE public.brand_account_links SET last_active_at = now() - interval '10 minutes' WHERE auth_id = a_m AND brand_id = v_b1 AND status = 'active';
--       v_t := public.touch_my_brand_activity(v_b1);
--       v_out := v_out || '5분후=' || v_t || '/' || (SELECT l.last_active_at = now() FROM public.brand_account_links l WHERE l.auth_id = a_m AND l.brand_id = v_b1 AND l.status = 'active') || ' ';
--       UPDATE public.brand_account_links SET last_active_at = NULL WHERE auth_id = a_m AND brand_id = v_b1 AND status = 'active';
--       v_t := public.touch_my_brand_activity(v_b1);
--       v_out := v_out || '처음기록=' || v_t || '/' || (SELECT l.last_active_at IS NOT NULL FROM public.brand_account_links l WHERE l.auth_id = a_m AND l.brand_id = v_b1 AND l.status = 'active') || ' ';
--       v_out := v_out || '미연결=' || public.touch_my_brand_activity(v_b3) || '/' || public.touch_my_brand_activity(gen_random_uuid()) || ' ';
--       v_t := public.set_my_brand_last_viewed(v_b1);
--       v_out := v_out || '마지막=' || v_t || '/' || (SELECT a.last_brand_id = v_b1 FROM public.brand_accounts a WHERE a.auth_id = a_m)
--                      || '/' || public.set_my_brand_last_viewed(v_b3) || ' ';
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '마지막판정=' || (v_r->>'state') || '/' || ((v_r->>'last_brand_id')::uuid = v_b1) || ' ';
--       v_t := public.update_my_brand_profile('  새이름  ', ' 010-1 ');
--       v_out := v_out || '프로필=' || v_t || '/' || (SELECT a.name || '|' || a.phone FROM public.brand_accounts a WHERE a.auth_id = a_m) || ' ';
--       v_out := v_out || '프로필오류=' || public.update_my_brand_profile('   ', '1') || '/' || public.update_my_brand_profile(NULL, '1') || ' ';
--       UPDATE public.brand_accounts SET password_changed_at = NULL WHERE auth_id = a_m;
--       v_t := public.mark_my_brand_password_changed();
--       v_out := v_out || '비번변경=' || v_t || '/' || (SELECT a.password_changed_at IS NOT NULL FROM public.brand_accounts a WHERE a.auth_id = a_m) || ' ';
--       -- 브랜드 계정이 아닌 로그인(무작위 번호)
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
--       v_out := v_out || '비브랜드=' || public.update_my_brand_profile('a', 'b') || '/' || public.mark_my_brand_password_changed()
--                      || '/' || public.mark_my_brand_mypage_seen() || '/' || (public.respond_brand_invite(NULL, l_m, 'accept')->>'result')
--                      || '/' || jsonb_array_length(public.get_my_brand_invites()) || ' ';
--       -- 대표 o 가 m 을 b1 에서 해제 → m 의 마지막 브랜드(b1)는 가리키지 않는다
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_t := public.release_brand_member(v_b1, a_m);
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_m, 'role', 'authenticated')::text, true);
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '해제후=' || v_t || '/' || (v_r->>'state') || '/' || COALESCE(v_r->>'last_brand_id', 'NULL') || '/' || jsonb_array_length(v_r->'brands') || ' ';
--     
--       -- ── I. S0-4: 새 이메일을 두 브랜드(b2·b3)가 초대 → 하나를 서버 경로로 수락 → 남은 초대는 로그인해서 수락 ───
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_r := public.create_brand_invite(v_b2, 'zz-532-nw@example.invalid');  i_nw2 := (v_r->>'invite_id')::uuid;  v_t := v_r->>'result';
--       v_r := public.create_brand_invite(v_b3, 'zz-532-nw@example.invalid');  i_nw3 := (v_r->>'invite_id')::uuid;  v_t := v_t || '/' || (v_r->>'result');
--       v_r := public.create_brand_invite(v_b2, 'zz-532-nc@example.invalid');  i_nc  := (v_r->>'invite_id')::uuid;  v_t := v_t || '/' || (v_r->>'result');
--       v_out := v_out || '새이메일초대=' || v_t || ' ';
--       SELECT i.link_id INTO l_nw2 FROM public.brand_invites i WHERE i.id = i_nw2;
--       SELECT i.link_id INTO l_nw3 FROM public.brand_invites i WHERE i.id = i_nw3;
--       SELECT i.link_id INTO l_nc  FROM public.brand_invites i WHERE i.id = i_nc;
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.get_brand_invite_link_state(l_nw2);
--       v_t := (v_r->>'state') || '/' || (v_r->>'recipient');
--       v_r := public.get_brand_invite_link_state(l_nw3);
--       v_out := v_out || '신규링크=' || v_t || '/' || (v_r->>'state') || '/' || (v_r->>'recipient') || ' ';
--       v_r := public.service_brand_invite_create_account(l_nw2, ' 신규 ', '010-9', 'v-532');
--       a_nw := (v_r->>'auth_id')::uuid;
--       v_out := v_out || '계정생성=' || (v_r->>'ok') || '/' || (v_r->>'email') || ' ';
--       v_out := v_out || '신규계정=' || (SELECT a.name FROM public.brand_accounts a WHERE a.auth_id = a_nw)
--                      || '/' || (SELECT a.terms_version FROM public.brand_accounts a WHERE a.auth_id = a_nw)
--                      || '/' || (SELECT a.created_via_invite_id = i_nw2 FROM public.brand_accounts a WHERE a.auth_id = a_nw)
--                      || '/' || (SELECT a.password_set_at IS NULL FROM public.brand_accounts a WHERE a.auth_id = a_nw)
--                      || '/' || (SELECT count(*) FROM auth.users u WHERE u.id = a_nw AND u.email = 'zz-532-nw@example.invalid')
--                      || '/' || (SELECT count(*) FROM auth.identities d WHERE d.user_id = a_nw)
--                      || '/' || (SELECT count(*) FROM public.influencers f WHERE f.id = a_nw)
--                      || '/' || (SELECT u.raw_app_meta_data->>'account_kind' FROM auth.users u WHERE u.id = a_nw) || ' ';
--       -- 같은 초대로 다시(중간 실패 재시도): 링크는 아직 유효하고 같은 계정을 다시 쓴다
--       v_r := public.get_brand_invite_link_state(l_nw2);
--       v_t := (v_r->>'state') || '/' || (v_r->>'recipient');
--       v_r := public.service_brand_invite_create_account(l_nw2, '신규2', '', 'v-532');
--       v_out := v_out || '재시도=' || v_t || '/' || (v_r->>'ok') || '/' || ((v_r->>'auth_id')::uuid = a_nw) || ' ';
--       -- 다른 초대(b3)는 지금 무효(이 계정은 b3 초대로 만든 것이 아니고 아직 비밀번호도 없다)
--       v_r := public.get_brand_invite_link_state(l_nw3);
--       v_out := v_out || '다른초대=' || (v_r->>'state') || ' ';
--       -- 비밀번호가 없으면 마무리 거부
--       v_r := public.service_brand_invite_finalize(l_nw2, a_nw);
--       v_out := v_out || '마무리전=' || (v_r->>'ok') || '/' || (v_r->>'reason') || ' ';
--       UPDATE auth.users SET encrypted_password = 'x' WHERE id = a_nw;      -- 조각 6 의 비밀번호 저장 단계를 SQL 로 대신
--       v_r := public.service_brand_invite_finalize(l_nw2, a_nw);
--       v_out := v_out || '마무리=' || (v_r->>'ok') || '/' || ((v_r->>'brand_id')::uuid = v_b2);
--       v_out := v_out || '/' || (SELECT a.password_set_at IS NOT NULL AND a.password_changed_at IS NOT NULL FROM public.brand_accounts a WHERE a.auth_id = a_nw)
--                      || '/' || (SELECT count(*) FROM public.brand_account_links l WHERE l.auth_id = a_nw AND l.brand_id = v_b2 AND l.role = 'member' AND l.status = 'active')
--                      || '/' || (SELECT i.status FROM public.brand_invites i WHERE i.id = i_nw2)
--                      || '/' || (SELECT i.accepted_auth_id = a_nw FROM public.brand_invites i WHERE i.id = i_nw2) || ' ';
--       v_r := public.service_brand_invite_finalize(l_nw2, a_nw);
--       v_out := v_out || '재마무리=' || (v_r->>'ok') || '/' || (v_r->>'reason') || ' ';
--       -- S0-4: 남은 b3 초대가 「로그인해서 수락」(ⓑ)으로 살아난다
--       v_r := public.get_brand_invite_link_state(l_nw3);
--       v_t := (v_r->>'state') || '/' || (v_r->>'recipient');
--       v_r := public.service_brand_invite_create_account(l_nw3, '다른이름', '', 'v-532');
--       v_out := v_out || 'S0-4=' || v_t || ' S0-4가입=' || (v_r->>'ok') || '/' || (v_r->>'reason') || ' ';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_nw, 'role', 'authenticated')::text, true);
--       v_r := public.respond_brand_invite(NULL, l_nw3, 'accept');
--       v_out := v_out || 'S0-4수락=' || (v_r->>'result') || '/' || (SELECT count(*) FROM public.brand_account_links l WHERE l.auth_id = a_nw AND l.brand_id = v_b3 AND l.status = 'active') || ' ';
--       -- 두 호출 사이에 초대가 취소되면(대표 해제 등) 마무리가 거부된다
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.service_brand_invite_create_account(l_nc, '취소될사람', '', 'v-532');
--       a_nc := (v_r->>'auth_id')::uuid;
--       v_t := v_r->>'ok';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_t := v_t || '/' || public.cancel_brand_invite(i_nc);
--       PERFORM set_config('request.jwt.claims', '', true);
--       UPDATE auth.users SET encrypted_password = 'x' WHERE id = a_nc;
--       v_r := public.service_brand_invite_finalize(l_nc, a_nc);
--       v_out := v_out || 'nc취소=' || v_t || '/' || (v_r->>'ok') || '/' || (v_r->>'reason')
--                      || '/' || (SELECT count(*) FROM public.brand_accounts a WHERE a.auth_id = a_nc)
--                      || '/' || (SELECT count(*) FROM public.brand_account_links l WHERE l.auth_id = a_nc) || ' ';
--     
--       -- ── J. 회귀(527 V5 와 같은 흐름, 비밀번호 찾기 경로까지) + 비밀번호 미설정 계정 s ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_o, 'role', 'authenticated')::text, true);
--       v_r := public.create_brand_invite(v_b1, 'zz-532-s@example.invalid');
--       i_s := (v_r->>'invite_id')::uuid;
--       v_out := v_out || 's초대=' || (v_r->>'result') || ' ';
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.service_issue_brand_account_link(a_s, 'auto');
--       l_a := (v_r->>'link_id')::uuid;
--       v_out := v_out || '발급=' || (v_r->>'ok') || '/' || (v_r->>'kind') || ' ';
--       v_out := v_out || 'setup유효=' || public.get_brand_link_state(l_a, 'setup') || ' reset종류=' || public.get_brand_link_state(l_a, 'reset') || ' ';
--       v_r := public.service_issue_brand_account_link(a_s, 'setup');
--       l_b := (v_r->>'link_id')::uuid;
--       v_out := v_out || '옛링크2=' || public.get_brand_link_state(l_a, 'setup') || ' ';
--       v_t := public.service_mark_brand_setup_mail_sent(a_s, l_b, 'zz-532-s@example.invalid')::text;
--       v_out := v_out || '기록=' || v_t || '/' || (SELECT a.setup_mail_sent_by FROM public.brand_accounts a WHERE a.auth_id = a_s);
--       v_t := public.service_mark_brand_setup_mail_sent(a_s, l_b, 'zz-532-s@example.invalid', 'self')::text;
--       v_out := v_out || '/' || v_t || '/' || (SELECT a.setup_mail_sent_by FROM public.brand_accounts a WHERE a.auth_id = a_s);
--       BEGIN
--         PERFORM public.service_mark_brand_setup_mail_sent(a_s, l_b, 'zz-532-s@example.invalid', 'bogus');
--         v_out := v_out || '/bogus=오류없음 ';
--       EXCEPTION WHEN SQLSTATE '22023' THEN
--         v_out := v_out || '/bogus=22023 ';
--       END;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_s, 'role', 'authenticated')::text, true);
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '완료전=' || (v_r->>'state') || '/' || (v_r->>'has_pending_invite') || '/' || COALESCE(v_r->>'password_changed_at', 'NULL') || ' ';
--       v_r := public.respond_brand_invite(i_s, NULL, 'accept');
--       v_out := v_out || '미완료수락=' || (v_r->>'result') || '/' || (SELECT count(*) FROM public.brand_account_links l WHERE l.auth_id = a_s AND l.brand_id = v_b1) || ' ';
--       v_out := v_out || '비번없음=' || public.complete_brand_account_setup(l_b, 'v-test') || ' ';
--       UPDATE auth.users SET encrypted_password = 'x' WHERE id = a_s;
--       v_out := v_out || '다른링크=' || public.complete_brand_account_setup(gen_random_uuid(), 'v-test') || ' ';
--       v_out := v_out || '완료=' || public.complete_brand_account_setup(l_b, 'v-test') || ' ';
--       v_out := v_out || '재호출=' || public.complete_brand_account_setup(l_b, 'v-test') || ' ';
--       v_r := public.get_my_brand_login_state();
--       v_out := v_out || '완료후=' || (v_r->>'state') || '/' || ((v_r->>'password_changed_at') IS NOT NULL) || ' ';
--       v_r := public.respond_brand_invite(i_s, NULL, 'accept');
--       v_out := v_out || '설정후수락=' || (v_r->>'result') || ' ';
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_r := public.service_issue_brand_account_link(a_s, 'auto');
--       l_a := (v_r->>'link_id')::uuid;
--       v_t := (v_r->>'kind') || '/' || public.get_brand_link_state(l_a, 'reset');
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', a_s, 'role', 'authenticated')::text, true);
--       v_t2 := public.complete_brand_password_reset(l_a);
--       v_out := v_out || '재설정=' || v_t || '/' || v_t2 || '/' || public.get_brand_link_state(l_a, 'reset') || ' ';
--       RAISE EXCEPTION '532 시험 결과(전부 되돌림): %', v_out;
--     END $$;
--     기대(의도된 예외 한 줄 — 줄바꿈 없이 이어진 한 줄이다. 아래는 읽기 쉽게 항목마다 끊었다. 항목 끝의 공백 한 칸이 구분이다):
--       「초대=ok/ok/ok/ok
--         무작위=invalid/1
--         기존계정링크=valid/existing/zz-532-b1/대표O
--         비로그인=not_brand
--         다른계정=invalid/NULL
--         지목불일치=invalid
--         m판정=ok/true/true
--         받은초대=1/zz-532-b1/대표O/true
--         점끄기=ok/false
--         다시보내기=ok/true
--         옛링크=invalid/invalid
--         잘못된동작=invalid
--         수락=ok/true/1/accepted/true
--         수락재호출=invalid
--         거절=ok/5→4/declined
--         거절재호출=invalid
--         수락id=ok/1/4
--         rr판정=no_active_brand/true/true/NULL
--         rr재설정=true/reset/valid/ok/invalid/true
--         연결없음x=false/no_active_brand
--         5분내=ok/true
--         5분후=ok/true
--         처음기록=ok/true
--         미연결=not_linked/not_linked
--         마지막=ok/true/not_linked
--         마지막판정=ok/true
--         프로필=ok/새이름|010-1
--         프로필오류=name_required/name_required
--         비번변경=ok/true
--         비브랜드=not_brand/not_brand/not_brand/not_brand/0
--         해제후=ok/ok/NULL/1
--         새이메일초대=ok/ok/ok
--         신규링크=valid/new/valid/new
--         계정생성=true/zz-532-nw@example.invalid
--         신규계정=신규/v-532/true/true/1/1/0/brand
--         재시도=valid/new/true/true
--         다른초대=invalid
--         마무리전=false/password_not_set
--         마무리=true/true/true/1/accepted/true
--         재마무리=false/invalid_link
--         S0-4=valid/existing S0-4가입=false/invalid_link
--         S0-4수락=ok/1
--         nc취소=true/ok/false/invalid_link/1/0
--         s초대=ok
--         발급=true/setup
--         setup유효=valid reset종류=invalid
--         옛링크2=invalid
--         기록=true/admin/true/self/bogus=22023
--         완료전=setup_incomplete/true/NULL
--         미완료수락=setup_incomplete/0
--         비번없음=password_not_set
--         다른링크=link_mismatch
--         완료=ok
--         재호출=already_set
--         완료후=ok/true
--         설정후수락=ok
--         재설정=reset/valid/ok/invalid」
--       읽는 법(전부 작업표 완료 정의): 무작위=invalid(키 1개) · 기존계정링크/수락/수락재호출/다른계정 = ⓑ 수락·재호출 invalid·다른 계정 invalid · 거절=자리 5→4 ·
--         rr판정~rr재설정 = 연결이 모두 해제된 계정 + 대기 초대 → no_active_brand + has_pending_invite, 설정 링크 발급·valid·재설정 끝까지 ok ·
--         5분내/5분후/처음기록/미연결 = 5분 묶기·not_linked · 점끄기/다시보내기 = new_invite_dot 껐다 켜짐 · 새이메일초대~S0-4수락 = S0-4(하나 수락 → 남은 초대가 existing 으로 valid) ·
--         nc취소 = 두 호출 사이 취소 → 마무리 invalid_link · 발급~재설정 = 527 V5 회귀(설정 링크 → 설정 완료 → 비밀번호 찾기).
--       ⚠️ 한 군데라도 다르면 멈추고 알릴 것(남은 단계를 계속 쏟지 말 것). 오류가 「RAISE」가 아닌 다른 것이면(함수 없음·칸 없음 등) 530·531 이 안 들어간 것이다.
--     그다음 따로(시험 뒤 잔여 확인 — 전부 0 이어야 한다. 0 이 아니면 멈추고 알릴 것):
--       SELECT (SELECT count(*) FROM auth.users WHERE email LIKE 'zz-532-%') AS users,
--              (SELECT count(*) FROM auth.identities WHERE identity_data->>'email' LIKE 'zz-532-%') AS identities,
--              (SELECT count(*) FROM public.brands WHERE name LIKE 'zz-532-%') AS brands,
--              (SELECT count(*) FROM public.brand_invites WHERE email LIKE 'zz-532-%') AS invites,
--              (SELECT count(*) FROM public.brand_accounts WHERE email LIKE 'zz-532-%') AS accounts;
--   [V3] 로그인한 실제 브라우저에서 한 번(묶음 ② 화면 때 확인해도 된다) — 개발서버 /brand/ 로그인 뒤 콘솔:
--       (await db.rpc('get_my_brand_login_state')).data     → state·name·email·brands 에 더해 last_brand_id · has_pending_invite · new_invite_dot · password_changed_at 네 키
--       (await db.rpc('get_my_brand_invites')).data          → [] (오류 아님)
--       (await db.rpc('get_brand_invite_link_state', {p_link_id: crypto.randomUUID()})).data → {state:'invalid'}  (로그아웃 상태에서도 같다)
--     ⚠️ 서비스 키 전용 둘(service_brand_invite_*)은 브라우저에서 부르면 권한 오류(42501)가 정상이다.
-- ============================================================

BEGIN;

-- ── 1. 안쪽 도우미 — 이 계정이 지금 수락할 수 있는 대기 초대 ─────────────────────
--   「수락 가능」 판정은 530 _brand_invite_acceptable 한 곳(p_via_link=false — 로그인한 쪽 기준). 여기서는 그 계정 이메일로 온 만료 전 대기 초대만 추려
--   그 판정에 건다. 로그인 판정(has_pending_invite·빨간 점)·받은 초대 목록·527 넓히기 둘이 모두 이 함수를 쓴다 — 식 사본을 늘리지 않으려는 것.
CREATE OR REPLACE FUNCTION public._brand_acceptable_invites_for(p_auth_id uuid)
RETURNS SETOF public.brand_invites
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT i.*
    FROM public.brand_accounts a
    JOIN public.brand_invites i ON i.email = lower(btrim(a.email))
   WHERE a.auth_id = p_auth_id
     AND i.status = 'pending'
     AND i.expires_at > now()
     AND public._brand_invite_acceptable(i.id, p_auth_id, false);
$$;

COMMENT ON FUNCTION public._brand_acceptable_invites_for(uuid) IS
  '[532] 내부 도우미. 이 계정이 지금 수락할 수 있는 대기 초대(만료 전 + _brand_invite_acceptable(id, 계정, false) 통과). 로그인 판정·받은 초대 목록·527 링크 판정이 함께 쓴다. 호출 불가(안쪽 전용).';

-- ── 2. 받는 사람 — 메일 링크 판정 (비로그인 가능) ────────────────────────────────
--   {state:'valid'|'invalid', recipient:'new'|'existing', brand_name, inviter_name, expires_at}. 무효면 {state:'invalid'} 한 칸뿐.
--   수락 가능 판정은 _brand_invite_acceptable(id, NULL, true) — 새 이메일 경로(예외 1 재시도 포함)와 같은 기준.
--   recipient: 보낼 때 ⓑ(brand) → existing / new 이고 지금도 계정 없음 → new / new 인데 지금 브랜드 계정이면:
--     이 초대로 만든 비밀번호 미설정 계정(예외 1 재시도) → new, 그 밖(비밀번호를 정한 계정 — 예외 2 S0-4) → existing.
--   링크를 가진 사람 = 메일을 받은 사람이라 브랜드 이름·보낸 사람 이름을 돌려준다(작업표 어긋남 3번 — 「비로그인은 두 값만」 원칙의 의도된 예외).
CREATE OR REPLACE FUNCTION public.get_brand_invite_link_state(p_link_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv       public.brand_invites%ROWTYPE;
  v_acct      public.brand_accounts%ROWTYPE;
  v_owner     jsonb;
  v_recipient text;
  v_brand     text;
BEGIN
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND OR NOT public._brand_invite_acceptable(v_inv.id, NULL, true) THEN
    RETURN jsonb_build_object('state', 'invalid');
  END IF;

  IF v_inv.recipient_kind = 'brand' THEN
    v_recipient := 'existing';
  ELSE
    v_owner := public._brand_email_owner(v_inv.email, NULL);
    IF v_owner->>'kind' = 'none' THEN
      v_recipient := 'new';
    ELSE
      SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = NULLIF(v_owner->>'auth_id', '')::uuid;
      IF FOUND AND v_acct.created_via_invite_id = v_inv.id AND v_acct.password_set_at IS NULL THEN
        v_recipient := 'new';        -- 예외 1: 같은 초대의 재시도 — 새 이메일 경로를 이어간다
      ELSE
        v_recipient := 'existing';   -- 예외 2(S0-4): 비밀번호를 정한 브랜드 계정 — 로그인해서 수락
      END IF;
    END IF;
  END IF;

  SELECT b.name INTO v_brand FROM public.brands b WHERE b.id = v_inv.brand_id;

  RETURN jsonb_build_object(
    'state',        'valid',
    'recipient',    v_recipient,
    'brand_name',   v_brand,
    'inviter_name', v_inv.inviter_name,
    'expires_at',   v_inv.expires_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_invite_link_state(uuid) IS
  '[532] 초대 메일 링크 판정(비로그인 가능). 수락 가능이면 {state:valid, recipient:new|existing, brand_name, inviter_name, expires_at}, 아니면 {state:invalid} 한 칸. 판정은 _brand_invite_acceptable(id, NULL, true). 링크 소지자에게 브랜드·보낸 사람 이름을 주는 것은 의도된 예외(작업표 어긋남 3번).';

-- ── 3. 받는 사람 — 수락·거절 (메일 링크와 마이페이지가 같은 함수) ──────────────────
--   {result, brand_id}: ok · already_member · invalid · not_brand · setup_incomplete. 무효 사유는 나누지 않는다.
--   · 메일 링크는 p_link_id, 마이페이지는 p_invite_id 로 지목(둘 다 주면 같은 줄이어야 한다 — 아니면 invalid).
--   · 🔴 잠금 순서: 브랜드('brand_account_upsert:'||brand_id, 527 과 같은 열쇠) → 이메일('brand_account_email:'||이메일). 잠금 **안에서** 줄을 다시 읽고
--     링크 번호도 다시 맞춘다(기다리는 사이 대표가 다시 보내 옛 링크가 됐을 수 있다) → _brand_invite_acceptable 판정.
--     대표 해제(조각 4)가 같은 열쇠를 쓰므로 「수락이 먼저면 해제 거부 · 해제가 먼저면 수락 거절」 순서가 정해진다(16-3 5번).
--   · 수락하는 사람 = 초대 이메일의 계정 인지는 _brand_invite_acceptable 의 p_auth_id 검사(계정 이메일 = 초대 이메일)가 보장한다 — 링크 번호만으로 남이 수락하지 못한다.
--   · 수락은 비밀번호 설정을 마친 계정만(setup_incomplete). 거절은 계정 상태와 무관(메일을 받은 본인이면 된다). 자리는 다시 검사하지 않는다(보낼 때 막았다).
--   · 「마지막으로 본 브랜드」는 건드리지 않는다(마이페이지 수락 정책 — 초대 수락 화면은 set_my_brand_last_viewed 를 따로 부른다).
CREATE OR REPLACE FUNCTION public.respond_brand_invite(p_invite_id uuid, p_link_id uuid, p_action text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_acct public.brand_accounts%ROWTYPE;
  v_pre  public.brand_invites%ROWTYPE;
  v_inv  public.brand_invites%ROWTYPE;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('result', 'not_brand', 'brand_id', NULL);
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('accept', 'decline') THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_brand', 'brand_id', NULL);
  END IF;

  -- 줄 지목 — 잠금을 잡을 브랜드·이메일을 알기 위해 잠금 전에 한 번 읽는다
  IF p_link_id IS NOT NULL THEN
    SELECT i.* INTO v_pre FROM public.brand_invites i
     WHERE i.link_id = p_link_id AND (p_invite_id IS NULL OR i.id = p_invite_id);
  ELSIF p_invite_id IS NOT NULL THEN
    SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.id = p_invite_id;
  ELSE
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  -- 브랜드 → 이메일 (527 과 같은 순서)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  -- 잠금 안에서 줄을 다시 읽는다 — 그사이 다시 보내기(링크 교체)·취소·해제가 있었을 수 있다
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR (p_link_id IS NOT NULL AND v_inv.link_id <> p_link_id) THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  -- 수락 가능 판정 + 「이 계정의 이메일 = 초대 이메일」 (둘 다 도우미 한 곳)
  IF NOT public._brand_invite_acceptable(v_inv.id, v_uid, false) THEN
    RETURN jsonb_build_object('result', 'invalid', 'brand_id', NULL);
  END IF;

  IF p_action = 'decline' THEN
    UPDATE public.brand_invites SET status = 'declined', declined_at = now() WHERE id = v_inv.id;
    RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id);
  END IF;

  -- 수락
  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.auth_id = v_uid AND l.brand_id = v_inv.brand_id AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'already_member', 'brand_id', v_inv.brand_id);
  END IF;
  IF v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('result', 'setup_incomplete', 'brand_id', v_inv.brand_id);
  END IF;

  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
  VALUES (v_uid, v_inv.brand_id, 'member', 'active');
  UPDATE public.brand_invites
     SET status = 'accepted', accepted_at = now(), accepted_auth_id = v_uid
   WHERE id = v_inv.id;

  RETURN jsonb_build_object('result', 'ok', 'brand_id', v_inv.brand_id);
END;
$$;

COMMENT ON FUNCTION public.respond_brand_invite(uuid, uuid, text) IS
  '[532] 초대 수락·거절(메일 링크=p_link_id, 마이페이지=p_invite_id, 같은 함수). p_action = accept | decline. 결과 {result, brand_id} — ok·already_member·invalid·not_brand·setup_incomplete.
   브랜드 잠금(527 열쇠) → 이메일 잠금 → 줄 재독(링크 번호 재확인) → _brand_invite_acceptable(id, 로그인 계정, false). 수락은 비밀번호 설정을 마친 계정만, 자리는 다시 검사하지 않음. authenticated 전용.';

-- ── 4. 받는 사람 — 받은 초대 목록 · 빨간 점 끄기 ────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_invites()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := auth.uid();
  v_rows jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'invite_id',    i.id,
           'brand_id',     i.brand_id,
           'brand_name',   b.name,
           'inviter_name', i.inviter_name,
           'issued_at',    i.issued_at,
           'expires_at',   i.expires_at
         ) ORDER BY i.issued_at DESC, i.id), '[]'::jsonb)
    INTO v_rows
    FROM public._brand_acceptable_invites_for(v_uid) i
    JOIN public.brands b ON b.id = i.brand_id;

  RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_invites() IS
  '[532] 로그인한 브랜드 계정이 지금 수락할 수 있는 초대 목록 [{invite_id, brand_id, brand_name, inviter_name, issued_at, expires_at}] (최근 발급순). 비로그인·브랜드 계정이 아니면 빈 배열. authenticated 전용.';

CREATE OR REPLACE FUNCTION public.mark_my_brand_mypage_seen()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN 'not_brand'; END IF;
  UPDATE public.brand_accounts SET mypage_seen_at = now() WHERE auth_id = v_uid;
  IF NOT FOUND THEN RETURN 'not_brand'; END IF;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.mark_my_brand_mypage_seen() IS
  '[532] 마이페이지를 연 시각을 계정에 기록(빨간 점 끄기). 결과 ok / not_brand. 점은 수락 가능한 초대 중 issued_at 이 이 시각보다 늦은 것이 있을 때 다시 켜진다(get_my_brand_login_state.new_invite_dot). authenticated 전용.';

-- ── 5. 본인 — 활동 · 마지막 브랜드 · 프로필 · 비밀번호 변경 기록 ─────────────────────
--   touch_my_brand_activity: 그 브랜드 연결의 last_active_at 을 지금으로. 🔴 **5분 안에 이미 기록됐으면 건너뛴다**(묶기) — 이 5분이 유일한 사본이다.
--   화면(②)이 사람이 누른 화면 이동·저장 때만 부른다. 로그인 판정(get_my_brand_login_state)에서는 기록하지 않는다(16-4 화면 정책 넷 ③).
CREATE OR REPLACE FUNCTION public.touch_my_brand_activity(p_brand_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL OR public.my_brand_role(p_brand_id) IS NULL THEN
    RETURN 'not_linked';
  END IF;

  UPDATE public.brand_account_links
     SET last_active_at = now()
   WHERE auth_id = v_uid
     AND brand_id = p_brand_id
     AND status = 'active'
     AND (last_active_at IS NULL OR last_active_at < now() - interval '5 minutes');

  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.touch_my_brand_activity(uuid) IS
  '[532] 그 브랜드에서의 마지막 활동 시각 기록(활성 연결 + 활성 브랜드). 5분 안에 이미 기록됐으면 건너뛴다(그래도 ok). 결과 ok / not_linked. 사람이 누른 화면 이동·저장 때만 부를 것(열어 둔 탭·자동 저장·로그인 직후 첫 화면은 부르지 않는다). authenticated 전용.';

CREATE OR REPLACE FUNCTION public.set_my_brand_last_viewed(p_brand_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL OR public.my_brand_role(p_brand_id) IS NULL THEN
    RETURN 'not_linked';
  END IF;

  UPDATE public.brand_accounts SET last_brand_id = p_brand_id WHERE auth_id = v_uid;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.set_my_brand_last_viewed(uuid) IS
  '[532] 마지막으로 본 브랜드 기록(활성 연결 + 활성 브랜드일 때만). 결과 ok / not_linked. authenticated 전용.';

CREATE OR REPLACE FUNCTION public.update_my_brand_profile(p_name text, p_phone text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_name  text := btrim(COALESCE(p_name, ''));
  v_phone text := btrim(COALESCE(p_phone, ''));
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM public.brand_accounts a WHERE a.auth_id = v_uid) THEN
    RETURN 'not_brand';
  END IF;
  IF v_name = '' THEN
    RETURN 'name_required';
  END IF;

  -- 길이 안전 장치(화면이 먼저 제한한다): 이름 100자 · 연락처 50자. 담당자 목록(brands.contacts)과는 맞추지 않는다.
  UPDATE public.brand_accounts
     SET name  = left(v_name, 100),
         phone = NULLIF(left(v_phone, 50), '')
   WHERE auth_id = v_uid;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.update_my_brand_profile(text, text) IS
  '[532] 본인 이름·연락처 수정(앞뒤 공백 제거, 연락처가 비면 NULL). 결과 ok / name_required / not_brand. 담당자 목록과 맞추지 않는다. authenticated 전용.';

CREATE OR REPLACE FUNCTION public.mark_my_brand_password_changed()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL THEN RETURN 'not_brand'; END IF;

  UPDATE public.brand_accounts
     SET password_changed_at = now()
   WHERE auth_id = v_uid AND password_set_at IS NOT NULL;
  IF FOUND THEN RETURN 'ok'; END IF;

  IF EXISTS (SELECT 1 FROM public.brand_accounts a WHERE a.auth_id = v_uid) THEN
    RETURN 'setup_incomplete';   -- 비밀번호를 아직 안 정한 계정은 「변경」이 아니다
  END IF;
  RETURN 'not_brand';
END;
$$;

COMMENT ON FUNCTION public.mark_my_brand_password_changed() IS
  '[532] 마이페이지 비밀번호 변경 뒤 화면이 부른다 — password_changed_at 을 지금으로. 결과 ok / setup_incomplete(비밀번호 미설정 계정) / not_brand. 비밀번호 원문은 받지 않는다(현재 비밀번호 확인은 화면의 별도 연결 로그인으로 — 작업표 설계 메모). 호출만 하면 찍히는 표시용 값 — 보안 판정에 쓰지 말 것. authenticated 전용.';

-- ── 6. 로그인 판정 재정의 (베이스 527) ─────────────────────────────────────────
--   state 값 넷(ok · not_brand · setup_incomplete · no_active_brand)과 기존 키(state·name·email·brands)는 **그대로**. 칸만 넷 더한다:
--     last_brand_id       — 마지막으로 본 브랜드. 🔴 **지금 활성 연결 + 활성 브랜드(= brands 배열에 든 것)일 때만** 그 값, 아니면 NULL.
--                           531 release_brand_member 는 last_brand_id 를 안 바꾸므로 해제된 브랜드를 가리킬 수 있어 여기서 걸러낸다.
--                           폴백(NULL 일 때 어느 브랜드로 열지)은 화면 몫 — 사양서 16-4 「이름순 첫 브랜드」(가나다 → ABC)를 서버 정렬이 재현하지 못해 서버가 짐작하지 않는다.
--     has_pending_invite  — 수락 가능한 대기 초대가 있는가(_brand_acceptable_invites_for).
--     new_invite_dot      — 그 초대 중 issued_at 이 mypage_seen_at 보다 늦은 것이 있는가(mypage_seen_at 이 NULL 이면 초대가 하나라도 있으면 true).
--     password_changed_at — 마이페이지 「비밀번호 마지막 변경일」.
--   로그인 판정은 활동(last_active_at)을 기록하지 않는다.
CREATE OR REPLACE FUNCTION public.get_my_brand_login_state()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid        uuid := auth.uid();
  v_acct       public.brand_accounts%ROWTYPE;
  v_brands     jsonb;
  v_has_invite boolean;
  v_dot        boolean;
  v_last       uuid;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', false, 'new_invite_dot', false, 'password_changed_at', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_uid;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('state', 'not_brand', 'name', NULL, 'email', NULL, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', false, 'new_invite_dot', false, 'password_changed_at', NULL);
  END IF;

  -- 수락 가능한 대기 초대 · 새 초대 표시
  SELECT count(*) > 0,
         COALESCE(bool_or(v_acct.mypage_seen_at IS NULL OR i.issued_at > v_acct.mypage_seen_at), false)
    INTO v_has_invite, v_dot
    FROM public._brand_acceptable_invites_for(v_uid) i;

  IF v_acct.password_set_at IS NULL THEN
    RETURN jsonb_build_object('state', 'setup_incomplete', 'name', v_acct.name, 'email', v_acct.email, 'brands', '[]'::jsonb,
                              'last_brand_id', NULL, 'has_pending_invite', v_has_invite, 'new_invite_dot', v_dot,
                              'password_changed_at', v_acct.password_changed_at);
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'role', l.role)
                            ORDER BY (l.role = 'owner') DESC, b.name), '[]'::jsonb)
    INTO v_brands
    FROM public.brand_account_links l
    JOIN public.brands b ON b.id = l.brand_id
   WHERE l.auth_id = v_uid AND l.status = 'active' AND b.status = 'active';

  -- 마지막 브랜드는 지금 활성 연결 목록에 있을 때만
  v_last := CASE WHEN v_acct.last_brand_id IS NOT NULL
                  AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_brands) e WHERE e->>'id' = v_acct.last_brand_id::text)
                 THEN v_acct.last_brand_id END;

  RETURN jsonb_build_object(
    'state',               CASE WHEN jsonb_array_length(v_brands) = 0 THEN 'no_active_brand' ELSE 'ok' END,
    'name',                v_acct.name,
    'email',               v_acct.email,
    'brands',              v_brands,
    'last_brand_id',       v_last,
    'has_pending_invite',  v_has_invite,
    'new_invite_dot',      v_dot,
    'password_changed_at', v_acct.password_changed_at
  );
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_login_state() IS
  '[532] 브랜드 로그인 직후 판정(베이스 527). state 값 넷은 그대로(ok·not_brand·setup_incomplete·no_active_brand), 칸 추가: last_brand_id(지금 활성 연결일 때만, 아니면 NULL)·has_pending_invite·new_invite_dot·password_changed_at. 활동은 기록하지 않는다. authenticated 전용.';

-- ── 7. 527 링크 판정 둘 넓히기 — 「활성 연결 또는 수락 가능한 대기 초대」 ───────────────
--   연결이 모두 해제된 뒤 다시 초대받은 사람이 비밀번호 찾기·설정 링크를 못 쓰는 틈을 막는다(작업표 어긋남 2번).
--   (설정·재설정을 마치는 complete_* 둘은 연결을 안 보고 링크 번호 일치만 본다 — 그대로.)

-- 7-1. get_brand_link_state (베이스 527 §3)
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
       AND (EXISTS (SELECT 1
                      FROM public.brand_account_links l
                      JOIN public.brands b ON b.id = l.brand_id
                     WHERE l.auth_id = a.auth_id AND l.status = 'active' AND b.status = 'active')
            OR EXISTS (SELECT 1 FROM public._brand_acceptable_invites_for(a.auth_id)))
  ) THEN
    RETURN 'valid';
  END IF;
  RETURN 'invalid';
END;
$$;

COMMENT ON FUNCTION public.get_brand_link_state(uuid, text) IS
  '[532] 계정 만들기(setup)/비밀번호 재설정(reset) 링크 유효 판정(베이스 527). 링크 번호가 계정의 setup_link_id 와 같고 종류가 계정 상태(password_set_at)와 맞고, 활성 브랜드 연결이 있거나 수락 가능한 대기 초대가 있으면 valid. 비로그인 가능, 이메일 반환 안 함.';

GRANT  EXECUTE ON FUNCTION public.get_brand_link_state(uuid, text) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_link_state(uuid, text) FROM PUBLIC;

-- 7-2. service_issue_brand_account_link (베이스 527 §9-1) — no_active_brand 조건만 넓힌다
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

  -- 활성 브랜드 연결도, 수락 가능한 대기 초대도 없으면 링크를 내지 않는다
  IF NOT EXISTS (SELECT 1
                   FROM public.brand_account_links l
                   JOIN public.brands b ON b.id = l.brand_id
                  WHERE l.auth_id = p_auth_id AND l.status = 'active' AND b.status = 'active')
     AND NOT EXISTS (SELECT 1 FROM public._brand_acceptable_invites_for(p_auth_id)) THEN
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
  '[532] 서비스 키 전용(베이스 527). 설정/재설정 메일을 보내기 직전 새 링크 번호를 발급해 앞선 링크를 모두 무효화한다. 활성 브랜드 연결이 없어도 수락 가능한 대기 초대가 있으면 발급(reason no_active_brand 조건을 넓힘).';

GRANT  EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_issue_brand_account_link(uuid, text) FROM anon, authenticated;

-- ── 8. 527 설정·재설정 완료 둘 — 비밀번호 변경 시각 기록 ─────────────────────────────
--   「설정·재설정·변경 어느 것이든 마지막으로 비밀번호를 정한 날」(16-4 화면 정책 넷 ③). 그 밖은 527 그대로.

-- 8-1. complete_brand_account_setup (베이스 527 §4) — password_changed_at 추가
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
     SET password_set_at     = now(),
         password_changed_at = now(),
         terms_agreed_at     = now(),
         privacy_agreed_at   = now(),
         terms_version       = btrim(p_terms_version),
         setup_link_id       = NULL
   WHERE auth_id = v_uid;

  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.complete_brand_account_setup(uuid, text) IS
  '[532] 브랜드 계정 설정 완료 기록(베이스 527) — 비밀번호 설정 시각·변경 시각(password_changed_at)·약관 동의 시각을 서버 now() 로. 링크 번호가 맞고 비밀번호가 실제로 정해졌을 때만 ok. 결과: ok·link_mismatch·already_set·not_brand·password_not_set.';

GRANT  EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_brand_account_setup(uuid, text) FROM anon;

-- 8-2. complete_brand_password_reset (베이스 527 §5) — password_changed_at 추가
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

  UPDATE public.brand_accounts
     SET setup_link_id = NULL, password_changed_at = now()
   WHERE auth_id = v_uid;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.complete_brand_password_reset(uuid) IS
  '[532] 비밀번호 재설정 완료 뒤 링크 번호(setup_link_id)를 비우고 비밀번호 변경 시각(password_changed_at)을 기록(베이스 527). 설정이 끝난 계정 + 번호 일치일 때만 ok. 결과: ok·link_mismatch·not_brand.';

GRANT  EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.complete_brand_password_reset(uuid) FROM anon;

-- ── 9. 설정 메일 발송 기록 — 넷째 인자(누가 보냈나) ─────────────────────────────────
--   🔴 인자가 늘어 새 모양이다 — 옛 3인자는 먼저 DROP(두 벌이면 호출이 모호하다). 권한 회수를 다시 건다.
--   넷째 인자 기본값 'admin' — 지금 서버 함수 둘(notify-brand-account-setup · brand-password-reset-request)의 3인자 호출이 그대로 돈다.
--   허용값 밖(admin·self 외)은 오류 22023(호출하는 쪽 실수를 조용히 넘기지 않는다).
DROP FUNCTION IF EXISTS public.service_mark_brand_setup_mail_sent(uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.service_mark_brand_setup_mail_sent(
  p_auth_id uuid,
  p_link_id uuid,
  p_sent_to text,
  p_sent_by text DEFAULT 'admin'
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_by text := COALESCE(p_sent_by, 'admin');
BEGIN
  IF v_by NOT IN ('admin', 'self') THEN
    RAISE EXCEPTION 'invalid_sent_by' USING ERRCODE = '22023';
  END IF;

  UPDATE public.brand_accounts
     SET setup_mail_sent_at = now(),
         setup_mail_sent_to = lower(btrim(p_sent_to)),
         setup_mail_sent_by = v_by
   WHERE auth_id = p_auth_id
     AND setup_link_id = p_link_id
     AND password_set_at IS NULL;
  RETURN FOUND;
END;
$$;

COMMENT ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text, text) IS
  '[532] 서비스 키 전용(베이스 527). 설정(setup) 메일 발송 시각·주소·보낸 쪽(admin=관리자 / self=본인 비밀번호 찾기 재발송, 기본 admin) 기록. 링크 번호가 아직 현재 번호이고 비밀번호 미설정일 때만 기록(true). 재설정 메일은 기록하지 않는다. 옛 3인자는 지웠다.';

GRANT  EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text, text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_setup_mail_sent(uuid, uuid, text, text) FROM anon, authenticated;

-- ── 10. 서비스 키 전용 — 새 이메일(ⓐ) 수락 두 단계 (조각 6 의 서버 함수가 부른다) ──────
--   비밀번호 원문을 받는 함수는 만들지 않는다 — 비밀번호 저장(auth.admin.updateUserById)은 서버 함수가 두 호출 사이에서 한다.
--   실패 모양은 늘 같은 키 집합이고 사유는 나누지 않는다(invalid_link 하나로 모음) — 단 입력 검사(name_required·terms_required)와 마무리 전제(password_not_set·already_member)는 따로.

-- 10-1. service_brand_invite_create_account
--   {ok, auth_id, email, reason}. 🔴 잠금 순서 브랜드 → 이메일(527 과 같은 열쇠). 잠금 안에서 줄을 다시 읽고 링크 번호·수락 가능(p_via_link=true)을 확인한 뒤
--   「지금 갈래가 new(재시도 예외 포함)」일 때만 만든다 — S0-4 갈래(이미 비밀번호를 정한 계정)·ⓑ·ⓒ 는 invalid_link(로그인해서 수락할 길이다).
--   같은 초대로 만든 비밀번호 미설정 계정이 있으면 그 계정을 다시 쓴다(이름·연락처·동의 시각만 새 값으로).
--   인증 계정 직접 삽입은 527 방식 그대로(비밀번호 빈칸 — 로그인 불가, account_kind=brand, identities 행 포함).
CREATE OR REPLACE FUNCTION public.service_brand_invite_create_account(
  p_link_id       uuid,
  p_name          text,
  p_phone         text,
  p_terms_version text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pre      public.brand_invites%ROWTYPE;
  v_inv      public.brand_invites%ROWTYPE;
  v_acct     public.brand_accounts%ROWTYPE;
  v_owner    jsonb;
  v_kind     text;
  v_owner_id uuid;
  v_new_id   uuid;
  v_name     text := left(btrim(COALESCE(p_name, '')), 100);
  v_phone    text := NULLIF(left(btrim(COALESCE(p_phone, '')), 50), '');
  v_terms    text := btrim(COALESCE(p_terms_version, ''));
BEGIN
  IF p_link_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'invalid_link');
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'invalid_link');
  END IF;

  -- 브랜드 → 이메일
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR v_inv.link_id <> p_link_id
     OR v_inv.recipient_kind <> 'new'
     OR NOT public._brand_invite_acceptable(v_inv.id, NULL, true) THEN
    RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'invalid_link');
  END IF;

  IF v_name = '' THEN
    RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'name_required');
  END IF;
  IF v_terms = '' THEN
    RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'terms_required');
  END IF;

  v_owner    := public._brand_email_owner(v_inv.email, NULL);
  v_kind     := v_owner->>'kind';
  v_owner_id := NULLIF(v_owner->>'auth_id', '')::uuid;

  IF v_kind = 'none' THEN
    -- 새 계정 (527 admin_upsert_brand_owner_account 와 같은 직접 삽입)
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
        v_new_id, 'authenticated', 'authenticated', v_inv.email,
        '',                      -- 비밀번호 미설정 — 서버 함수가 다음 단계에서 정한다. 그 전엔 로그인 불가
        now(), now(), now(),
        '', '', '', '', '', '', '', '',
        jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'account_kind', 'brand'),
        jsonb_build_object('sub', v_new_id::text, 'email', v_inv.email, 'email_verified', true, 'phone_verified', false)
      );
      INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
      VALUES (
        gen_random_uuid(), v_new_id,
        jsonb_build_object('sub', v_new_id::text, 'email', v_inv.email, 'email_verified', true),
        'email', v_new_id::text, now(), now()
      );
      INSERT INTO public.brand_accounts
        (auth_id, email, name, phone, terms_agreed_at, privacy_agreed_at, terms_version, created_via_invite_id)
      VALUES
        (v_new_id, v_inv.email, v_name, v_phone, now(), now(), v_terms, v_inv.id);
    EXCEPTION WHEN unique_violation THEN
      -- 잠금 밖 경로(인플루언서 가입 등)가 같은 이메일을 그사이 만든 드문 경우 — 부분 삽입은 이 블록 안에서 되돌려진다
      RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'invalid_link');
    END;
    RETURN jsonb_build_object('ok', true, 'auth_id', v_new_id, 'email', v_inv.email, 'reason', NULL);

  ELSIF v_kind = 'brand' THEN
    -- 같은 초대로 만든 비밀번호 미설정 계정 = 중간 실패 재시도 → 다시 쓴다. 그 밖(S0-4 포함)은 로그인해서 수락할 길이다
    SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_owner_id FOR UPDATE;
    IF FOUND AND v_acct.created_via_invite_id = v_inv.id AND v_acct.password_set_at IS NULL THEN
      UPDATE public.brand_accounts
         SET name = v_name, phone = v_phone,
             terms_agreed_at = now(), privacy_agreed_at = now(), terms_version = v_terms
       WHERE auth_id = v_owner_id;
      RETURN jsonb_build_object('ok', true, 'auth_id', v_owner_id, 'email', v_inv.email, 'reason', NULL);
    END IF;
  END IF;

  RETURN jsonb_build_object('ok', false, 'auth_id', NULL, 'email', NULL, 'reason', 'invalid_link');
END;
$$;

COMMENT ON FUNCTION public.service_brand_invite_create_account(uuid, text, text, text) IS
  '[532] 서비스 키 전용(조각 6). 새 이메일(ⓐ) 초대 수락 1단계 — 인증 계정 직접 삽입(비밀번호 빈칸, account_kind=brand) + brand_accounts(이름·연락처·약관 동의·created_via_invite_id). 같은 초대의 비밀번호 미설정 계정이 있으면 다시 쓴다(재시도). 반환 {ok, auth_id, email, reason} — reason: invalid_link·name_required·terms_required. 브랜드→이메일 잠금 안에서 수락 가능(p_via_link=true)과 갈래 new 를 다시 판정한다. 비밀번호 원문은 받지 않는다.';

-- 10-2. service_brand_invite_finalize
--   {ok, brand_id, reason}. 비밀번호 저장(서버 함수의 updateUserById) **뒤**에 부른다. 잠금 안에서 수락 가능(p_via_link=true, 계정 일치)을 **다시** 판정 —
--   두 호출 사이에 초대가 취소됐을 수 있다. reason: invalid_link · password_not_set(인증 계정에 비밀번호가 없음) · already_member.
--   password_set_at·password_changed_at 은 아직 비어 있을 때만 채운다(이미 정한 계정의 변경 시각을 덮지 않는다). 멤버 연결 + 초대 accepted 를 한 트랜잭션에서.
--   마무리 거부 뒤 이 초대로 만든 계정을 지우는 일은 서버 함수 몫(조각 6) — 이 함수는 계정을 지우지 않는다.
CREATE OR REPLACE FUNCTION public.service_brand_invite_finalize(p_link_id uuid, p_auth_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_pre public.brand_invites%ROWTYPE;
  v_inv public.brand_invites%ROWTYPE;
  v_pw  text;
BEGIN
  IF p_link_id IS NULL OR p_auth_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  SELECT i.* INTO v_pre FROM public.brand_invites i WHERE i.link_id = p_link_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  -- 브랜드 → 이메일 (create_account 와 같은 열쇠·순서)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_pre.brand_id::text));
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_pre.email));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = v_pre.id FOR UPDATE;
  IF NOT FOUND OR v_inv.link_id <> p_link_id
     OR NOT public._brand_invite_acceptable(v_inv.id, p_auth_id, true) THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', NULL, 'reason', 'invalid_link');
  END IF;

  PERFORM 1 FROM public.brand_accounts a WHERE a.auth_id = p_auth_id FOR UPDATE;

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.auth_id = p_auth_id AND l.brand_id = v_inv.brand_id AND l.status = 'active') THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', v_inv.brand_id, 'reason', 'already_member');
  END IF;

  -- 비밀번호가 실제로 정해졌는지
  SELECT u.encrypted_password INTO v_pw FROM auth.users u WHERE u.id = p_auth_id;
  IF v_pw IS NULL OR v_pw = '' THEN
    RETURN jsonb_build_object('ok', false, 'brand_id', v_inv.brand_id, 'reason', 'password_not_set');
  END IF;

  UPDATE public.brand_accounts
     SET password_changed_at = CASE WHEN password_set_at IS NULL THEN now() ELSE password_changed_at END,
         password_set_at     = COALESCE(password_set_at, now())
   WHERE auth_id = p_auth_id;

  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
  VALUES (p_auth_id, v_inv.brand_id, 'member', 'active');
  UPDATE public.brand_invites
     SET status = 'accepted', accepted_at = now(), accepted_auth_id = p_auth_id
   WHERE id = v_inv.id;

  RETURN jsonb_build_object('ok', true, 'brand_id', v_inv.brand_id, 'reason', NULL);
END;
$$;

COMMENT ON FUNCTION public.service_brand_invite_finalize(uuid, uuid) IS
  '[532] 서비스 키 전용(조각 6). 새 이메일(ⓐ) 초대 수락 2단계(비밀번호 저장 뒤) — 브랜드→이메일 잠금 안에서 수락 가능(p_via_link=true, 계정 이메일 일치)을 다시 판정 → 비밀번호 실재 확인 → password_set_at·password_changed_at(비어 있을 때만) → 멤버 연결 → 초대 accepted. 반환 {ok, brand_id, reason} — reason: invalid_link·password_not_set·already_member. 계정 정리는 호출하는 서버 함수 몫.';

-- ── 11. 실행 권한 (369·370·375) — 부여 먼저 → PUBLIC 회수 → anon(·authenticated) 회수 ──
--   get_brand_link_state·service_issue_brand_account_link·complete_* 둘·service_mark 는 위 각 함수 뒤에서 이미 걸었다(527 과 같은 모양).
--   get_my_brand_login_state 는 CREATE OR REPLACE 라 권한이 남지만 527 상태를 명시로 다시 확인해 둔다.

-- 11-1. 비로그인도 부르는 것 — 초대 링크 판정
GRANT  EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) TO postgres, anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_brand_invite_link_state(uuid) FROM PUBLIC;

-- 11-2. 로그인 사용자 전용 (anon 회수)
GRANT  EXECUTE ON FUNCTION public.get_my_brand_login_state()                 TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text)     TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_my_brand_invites()                     TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.mark_my_brand_mypage_seen()                TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.touch_my_brand_activity(uuid)              TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.set_my_brand_last_viewed(uuid)             TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.update_my_brand_profile(text, text)        TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.mark_my_brand_password_changed()           TO postgres, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.get_my_brand_login_state()                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text)     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_invites()                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_mypage_seen()                FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.touch_my_brand_activity(uuid)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.set_my_brand_last_viewed(uuid)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_profile(text, text)        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_password_changed()           FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.get_my_brand_login_state()                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.respond_brand_invite(uuid, uuid, text)     FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_invites()                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_mypage_seen()                FROM anon;
REVOKE EXECUTE ON FUNCTION public.touch_my_brand_activity(uuid)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.set_my_brand_last_viewed(uuid)             FROM anon;
REVOKE EXECUTE ON FUNCTION public.update_my_brand_profile(text, text)        FROM anon;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_password_changed()           FROM anon;

-- 11-3. 서비스 키 전용·안쪽 전용 (postgres·service_role 만)
GRANT  EXECUTE ON FUNCTION public.service_brand_invite_create_account(uuid, text, text, text) TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public.service_brand_invite_finalize(uuid, uuid)                   TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_acceptable_invites_for(uuid)                         TO postgres, service_role;

REVOKE EXECUTE ON FUNCTION public.service_brand_invite_create_account(uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_brand_invite_finalize(uuid, uuid)                   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_acceptable_invites_for(uuid)                         FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.service_brand_invite_create_account(uuid, text, text, text) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.service_brand_invite_finalize(uuid, uuid)                   FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_acceptable_invites_for(uuid)                         FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
