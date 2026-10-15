-- ============================================================
-- 533_brand_admin_member_functions.sql
-- 브랜드 멤버 관리·여러 브랜드 — 작업 4: 관리자 함수 + 527 권한 교체
--   작업표 docs/specs/2026-10-15-brand-member-breakdown.md 「작업 4」 · 사양서 docs/specs/2026-07-15-brand-portal.md §16 머리 낱말 정의·§16-3(1·5번)·§16-4(관리자 브랜드 상세)·§16-5(11번)·§16-7
--
-- 목적
--   ① 쓰기 다섯 — 가드 has_permission('brand.account_manage','write'), 거부 forbidden:
--        admin_change_brand_owner · admin_set_brand_member_limit · admin_release_brand_account · admin_link_brand_owner_account (이 넷은 신설)
--        admin_upsert_brand_owner_account (527 재정의 — 가드 교체 + 이메일 교체 때 setup_mail_sent_by 도 비움)
--   ② 조회 둘 — 관리자 전원(is_admin(), 아니면 42501):
--        admin_get_brand_account_status (527 확장 — 기존 칸 유지 + 새 칸) · admin_check_brand_account_email (신설, 겹침 확인 창용)
--   표·칸은 만들지 않는다(530 이 만들었다). 안쪽 도우미(531 _brand_transfer_owner · _brand_contacts_mark_primary, 527 _brand_email_owner)를 쓴다.
--
-- 베이스(재정의하는 두 함수 — 파일 목록에서 CREATE 정의를 가려 확인함)
--   admin_upsert_brand_owner_account(uuid,text,text)  : 527 (528·530~532 에 재정의 없음 — `grep -l "FUNCTION public.admin_upsert_brand_owner_account"` = 527 하나)
--   admin_get_brand_account_status(uuid)              : 527 (같은 방법으로 확인 — 527 하나)
--   527 의 conflict_brand 반환은 **바꾸지 않았다** — 「계정 만들기」는 겹치면 그대로 conflict_brand 를 돌려주고, 화면(묶음 ③)이 겹침 확인 창을 띄운다.
--   conflict_brand 를 푸는 것은 admin_link_brand_owner_account 하나뿐이다(다른 브랜드에 연결된 계정도 대표로 잇는다).
--
-- 배포 순서
--   1) 530·531·532 가 먼저 들어가 있어야 한다(brand_invites·brand_member_limits·권한 시드·_brand_transfer_owner·_brand_seat_usage).
--      🔴 개발서버만. 운영은 526~533 묶음으로(묶음 ① 전체 보류).
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 다음은 작업 5(초대 메일 서버 함수)·7(기존 메일 함수 권한 판정 교체).
--   3) ⚠️ 적용 즉시 바뀌는 기존 동작: admin_upsert_brand_owner_account 의 가드가 「캠페인 관리자 이상」→ brand.account_manage 쓰기 권한으로 바뀐다.
--      기본 시드(530)는 최고 관리자·캠페인 관리자 쓰기 / 캠페인 매니저 숨김 — 지금과 같은 결과다. 권한 관리 화면에서 등급을 바꾸면 그대로 따른다.
--      🔴 notify-brand-account-setup(메일 함수)의 판정은 아직 is_campaign_admin() 고정이다 — 작업 7 이 같은 권한 항목으로 바꾼다. 그 사이 권한을 바꾸면 계정은 만들어지고 메일만 거부될 수 있다.
--
-- 설계 판단
--   [A] has_permission 은 등급 행이 없으면 등급별로 판정이 반대다(269) — 530 이 세 등급 시드를 넣었다. 이 파일은 시드를 더하지 않는다.
--   [B] 쓰기 함수는 모두 브랜드 잠금(527·531 과 같은 열쇠 'brand_account_upsert:'||brand_id) 안에서 판정한다. 이메일을 다루는 link 는 그 뒤 이메일 잠금(brand_account_email)을 잡는다(브랜드 → 이메일).
--       수락 쪽(respond_brand_invite·service_brand_invite_finalize)도 같은 열쇠라 「수락이 먼저면 해제 거부 · 해제가 먼저면 수락 거부」(16-3 5번)가 지켜진다.
--   [C] admin_release_brand_account: 대표 해제는 활성 멤버가 있으면 owner_has_members, 없으면 해제 + 그 브랜드의 status='pending' 초대 전부 cancelled(만료·ⓒ·상태가 바뀐 줄·누가 보냈든).
--       정확히 admin_get_brand_account_status.release_cancel_count 가 세는 조건과 같다. 멤버 해제는 초대를 건드리지 않는다. 받은 사람에게 메일 없음.
--       이어서 그 초대의 service_brand_invite_finalize 는 _brand_invite_acceptable(status<>'pending')로 invalid_link 가 된다(532 확인 — 시험 [V16]).
--   [D] admin_change_brand_owner: 대표가 없거나 기대한 대표와 다르면 owner_changed(a03-02b). 새 사람이 활성 멤버가 아니면 not_member.
--   [E] admin_link_brand_owner_account: 판정 순서 forbidden → brand_not_found → brand_archived → invalid_email → owner_exists → not_brand_account(email_kind 동봉) → 연결.
--       작업표 결과 값 목록에 brand_not_found 가 없지만 527 upsert 와 같이 둔다(없는 브랜드 아이디). 근거 줄(source_contact_id)에는 담당자 표시가 옮겨진 줄의 id 를 적는다.
--       비밀번호 미설정 계정도 잇는다(password_set=false → 화면이 설정 메일 갈래로, 작업표 S0-2). email_kind 는 거부 땐 none|influencer|admin, 성공 땐 'brand'.
--   [F] admin_get_brand_account_status: 대기 초대 숫자 둘은 정의가 다르다(pending_invite_count = 만료 전 대기, release_cancel_count = 상태가 대기인 전부). 초대 줄·이메일은 싣지 않는다.
--       비밀번호 미설정 계정의 members[].last_active_at 은 null 로 가린다(대표 줄은 설정 완료일 때만 값이 있다). 작업표 칸 외에 members[].role 을 더했다(대표 줄 구분용 — owner_auth_id 로도 가를 수 있다).
--   [G] 실행 권한: 부여 먼저(postgres, authenticated, service_role) → PUBLIC 회수 → anon 회수 (369·370·375). 반환형이 안 바뀌어 DROP 이 없다 → 기존 권한은 그대로 남고 명시로 다시 걸었다.
--
-- 되돌리는 방법
--   1) 신설 다섯을 지운다(이 파일을 쓰는 화면·메일 함수가 있으면 먼저 되돌릴 것):
--        DROP FUNCTION IF EXISTS public.admin_link_brand_owner_account(uuid, text);
--        DROP FUNCTION IF EXISTS public.admin_release_brand_account(uuid, uuid);
--        DROP FUNCTION IF EXISTS public.admin_set_brand_member_limit(uuid, int);
--        DROP FUNCTION IF EXISTS public.admin_change_brand_owner(uuid, uuid, uuid);
--        DROP FUNCTION IF EXISTS public.admin_check_brand_account_email(uuid, text);
--   2) 527 두 함수 본문을 되돌린다(CREATE OR REPLACE 라 실행 권한은 그대로). 저장소 루트에서:
--        f() { sed -n "/^CREATE OR REPLACE FUNCTION public.$2/,/^\$\$;/p" "$1"; }
--        f supabase/migrations/527_brand_account_functions.sql admin_upsert_brand_owner_account
--        f supabase/migrations/527_brand_account_functions.sql admin_get_brand_account_status
--      나온 두 구문을 개발서버 SQL 편집기에서 실행(이 파일의 [확인1] 실행 권한 조회로 권한이 그대로인지 확인).
--   ⚠️ 이 함수들이 바꾼 데이터(연결 해제 이력·취소된 초대·상한 행·담당자 표시 이동)는 함수를 지워도 남는다.
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   [확인1] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--      WHERE n.nspname='public'
--        AND p.proname IN ('admin_change_brand_owner','admin_set_brand_member_limit','admin_release_brand_account','admin_link_brand_owner_account',
--                          'admin_upsert_brand_owner_account','admin_get_brand_account_status','admin_check_brand_account_email')
--      ORDER BY 1;
--     기대: 7행 · acl 맨 앞에 `=X/` 없음 · anon_can 전부 false · auth_can·svc_can 전부 true.
--   [확인2] 되돌림 묶음 시험 — 캠페인 매니저·캠페인 관리자·관리자 아닌 계정 흉내(set_config + SET LOCAL ROLE authenticated). 끝의 RAISE EXCEPTION 이 전부 되돌린다
--     (편집기 자동 커밋 때문에 BEGIN…ROLLBACK 대신 DO 하나로 — 530·531 과 같은 방식. 시험 이메일은 `.invalid`, 메일은 나가지 않는다).
--     관리자 계정은 admins 표에서 등급별로 하나씩 조회해 쓰고, 해당 등급이 없으면 이 시험 안에서만 임시로 만든다(되돌려진다).
--     🔴 함수 호출과 확인 조회는 **별개 문장**이다(같은 문장 안의 조회는 호출 전 스냅숏을 본다). 확인 조회는 RESET ROLE 뒤에 한다.
--     매니저 권한을 쓰기로 바꾸는 UPDATE 는 이 DO 안(되돌림)에서만 한다. 이 파일의 함수 일곱을 모두 1회 이상 호출한다(적용 Success 는 동작 확인이 아니다).
--     결과는 한 개의 예외 메시지로 나오며 줄마다 시험 라벨 [V1]~[V26] + PASS/FAIL(FAIL 이면 got= 실제값)이다. 기대: 전부 PASS.
--     ⚠️ 한 줄이라도 FAIL 이면 멈추고 알릴 것(남은 단계를 계속 쏟지 말 것).
--
--     DO $$
--     DECLARE
--       v_out text := ''; v_g text; v_role text; v_id uuid;
--       adm_s uuid; adm_c uuid; adm_m uuid; adm_c_email text; v_temp text := '';
--       o1 uuid := gen_random_uuid(); m1 uuid := gen_random_uuid(); o2 uuid := gen_random_uuid();
--       x uuid := gen_random_uuid(); inf uuid := gen_random_uuid(); acct_n uuid;
--       b1 uuid; b2 uuid; b3 uuid; b4 uuid; b5 uuid; link_n uuid;
--       r jsonb; rc jsonb; r1 text; r2 text; r3 text; r4 text; r5 text; r6 text; r7 text;
--       ts_a timestamptz := now() - interval '2 days'; ts_b timestamptz := now() - interval '1 day';
--     BEGIN
--       -- ── 준비 (관리자 계정 기준: 등급별로 admins 표에서 하나씩 조회, 없으면 이 시험 안에서만 임시로 만든다) ──
--       FOREACH v_role IN ARRAY ARRAY['super_admin','campaign_admin','campaign_manager'] LOOP
--         SELECT a.auth_id INTO v_id FROM public.admins a WHERE a.role = v_role AND a.auth_id IS NOT NULL ORDER BY a.created_at LIMIT 1;
--         IF v_id IS NULL THEN
--           v_id := gen_random_uuid();
--           INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                                   confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                                   phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--           VALUES ('00000000-0000-0000-0000-000000000000'::uuid, v_id,'authenticated','authenticated','zz-533-adm-'||v_role||'@example.invalid','x',now(),now(),now(),
--                   '','','','','','','','','{"provider":"email","providers":["email"]}'::jsonb,
--                   jsonb_build_object('sub',v_id::text,'email','zz-533-adm-'||v_role||'@example.invalid','email_verified',true,'phone_verified',false));
--           INSERT INTO public.admins (auth_id, email, name, role) VALUES (v_id, 'zz-533-adm-'||v_role||'@example.invalid', 'zz-533 임시 '||v_role, v_role);
--           v_temp := v_temp || v_role || ' ';
--         END IF;
--         IF v_role = 'super_admin' THEN adm_s := v_id; ELSIF v_role = 'campaign_admin' THEN adm_c := v_id; ELSE adm_m := v_id; END IF;
--       END LOOP;
--       SELECT u.email INTO adm_c_email FROM auth.users u WHERE u.id = adm_c;
--     
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-533-b1', jsonb_build_array(jsonb_build_object('id','k1','name','대표1','phone','010','email','zz-533-o1@example.invalid','is_primary',true))) RETURNING id INTO b1;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-533-b2', '[]') RETURNING id INTO b2;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-533-b3', jsonb_build_array(jsonb_build_object('id','k3','name','신규','phone','','email','zz-533-x@example.invalid','is_primary',true))) RETURNING id INTO b3;
--       INSERT INTO public.brands (name, contacts, status) VALUES ('zz-533-b4', '[]', 'archived') RETURNING id INTO b4;
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-533-b5', jsonb_build_array(jsonb_build_object('id','k5','name','겹침','phone','','email','zz-533-o2@example.invalid','is_primary',true))) RETURNING id INTO b5;
--     
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       SELECT '00000000-0000-0000-0000-000000000000'::uuid, t.id,'authenticated','authenticated',t.em,'x',now(),now(),now(),
--              '','','','','','','','', t.app, jsonb_build_object('sub',t.id::text,'email',t.em,'email_verified',true,'phone_verified',false)
--         FROM (VALUES
--           (o1,'zz-533-o1@example.invalid','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb),
--           (m1,'zz-533-m1@example.invalid','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb),
--           (o2,'zz-533-o2@example.invalid','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb),
--           (x ,'zz-533-x@example.invalid' ,'{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb),
--           (inf,'zz-533-inf@example.invalid','{"provider":"email","providers":["email"]}'::jsonb)
--         ) AS t(id,em,app);
--       INSERT INTO public.brand_accounts (auth_id,email,name,password_set_at) VALUES
--         (o1,'zz-533-o1@example.invalid','대표1',now()),(m1,'zz-533-m1@example.invalid','멤버1',now()),(o2,'zz-533-o2@example.invalid','대표2',now());
--       INSERT INTO public.brand_accounts (auth_id,email,name) VALUES (x,'zz-533-x@example.invalid','미설정X');   -- 비밀번호 미설정, 연결 없음
--       INSERT INTO public.brand_account_links (auth_id,brand_id,role,last_active_at) VALUES (o1,b1,'owner',ts_a),(m1,b1,'member',ts_b),(o2,b2,'owner',NULL);
--       -- b1 초대: i1 유효 대기 · i2 만료 대기 · i3 거절
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at) VALUES
--         (b1,'zz-533-i1@example.invalid',o1,'대표1','pending','new',now(),now()+interval '24 hours'),
--         (b1,'zz-533-i2@example.invalid',o1,'대표1','pending','new',now()-interval '48 hours',now()-interval '24 hours');
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at,declined_at) VALUES
--         (b1,'zz-533-i3@example.invalid',o1,'대표1','declined','new',now()-interval '2 hours',now()+interval '22 hours',now());
--     
--       -- ── [V1][V2] 캠페인 매니저 흉내 — 쓰기 다섯은 forbidden, 조회 둘은 성공 ──
--       RESET ROLE;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_m, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_change_brand_owner(b1, m1, o1);
--       r2 := public.admin_set_brand_member_limit(b1, 3)->>'result';
--       r3 := public.admin_release_brand_account(b1, m1)->>'result';
--       r4 := public.admin_link_brand_owner_account(b3, 'zz-533-x@example.invalid')->>'result';
--       r5 := public.admin_upsert_brand_owner_account(b3, NULL, NULL)->>'result';
--       r  := public.admin_get_brand_account_status(b1);
--       rc := public.admin_check_brand_account_email(b1, 'zz-533-o1@example.invalid');
--       RESET ROLE;
--       v_g := r1||'/'||r2||'/'||r3||'/'||r4||'/'||r5;
--       v_out := v_out || E'\n[V1] 매니저 쓰기 다섯 ' || CASE WHEN v_g = 'forbidden/forbidden/forbidden/forbidden/forbidden' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (r->>'can_manage')||'/'||jsonb_array_length(r->'members')||'/'||(rc->>'result')||'/'||(rc->>'email_kind');
--       v_out := v_out || E'\n[V2] 매니저 조회 둘(can_manage=false, 목록 2, 확인 ok/brand) ' || CASE WHEN v_g = 'false/2/ok/brand' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (SELECT count(*) FROM public.brand_account_links WHERE auth_id = m1 AND brand_id = b1 AND status = 'active' AND role = 'member')
--              ||'/'||(SELECT count(*) FROM public.brand_member_limits WHERE brand_id = b1);
--       v_out := v_out || E'\n[V3] 매니저 거부 뒤 변화 없음(멤버 연결 1, 상한 행 0) ' || CASE WHEN v_g = '1/0' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V4] 캠페인 관리자 흉내 — 상태 조회 확장 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r := public.admin_get_brand_account_status(b1);
--       RESET ROLE;
--       v_g := (r->>'can_manage')||'/'||((r->>'owner_auth_id')::uuid = o1)||'/'||jsonb_array_length(r->'members')||'/'||(r->>'pending_invite_count')||'/'||(r->>'release_cancel_count')
--              ||'/'||(r->>'seat_used')||'/'||(r->>'member_limit')||'/'||(r ? 'setup_mail_sent_by')||'/'||jsonb_typeof(r->'members'->0->'last_active_at')||'/'||(r->>'status');
--       v_out := v_out || E'\n[V4] 상태 조회 확장(can_manage·대표·목록2·대기1·해제취소2·자리3/5·대표 마지막 접속 있음·status active) ' ||
--                CASE WHEN v_g = 'true/true/2/1/2/3/5/true/string/active' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V5][V6][V7] 대표 바꾸기 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_change_brand_owner(b1, m1, o2);       -- 기대 대표가 틀림
--       r2 := public.admin_change_brand_owner(b1, m1, NULL);     -- 기대 대표 없음
--       r3 := public.admin_change_brand_owner(b1, x, o1);        -- 멤버가 아님
--       r4 := public.admin_change_brand_owner(b1, m1, o1);       -- 정상
--       RESET ROLE;
--       v_g := r1||'/'||r2||'/'||r3||'/'||r4;
--       v_out := v_out || E'\n[V5] 대표 바꾸기 응답 ' || CASE WHEN v_g = 'owner_changed/owner_changed/not_member/ok' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (SELECT role FROM public.brand_account_links WHERE auth_id = m1 AND brand_id = b1 AND status = 'active')
--              ||'/'||(SELECT role FROM public.brand_account_links WHERE auth_id = o1 AND brand_id = b1 AND status = 'active')
--              ||'/'||(SELECT count(*) FROM public.brand_account_links WHERE brand_id = b1 AND role = 'owner' AND status = 'active')
--              ||'/'||((SELECT last_active_at FROM public.brand_account_links WHERE auth_id = m1 AND brand_id = b1 AND status = 'active') = ts_b
--                      AND (SELECT last_active_at FROM public.brand_account_links WHERE auth_id = o1 AND brand_id = b1 AND status = 'active') = ts_a)
--              ||'/'||(SELECT lower(btrim(e->>'email')) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true')
--              ||'/'||(SELECT count(*) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true');
--       v_out := v_out || E'\n[V6] 바꾼 뒤(m1 대표·o1 멤버·활성 대표 1·마지막 접속 보존·담당자 표시 m1·표시 1개) ' ||
--                CASE WHEN v_g = 'owner/member/1/true/zz-533-m1@example.invalid/1' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_change_brand_owner(b1, o1, m1);       -- 되돌리기
--       RESET ROLE;
--       v_g := r1||'/'||(SELECT role FROM public.brand_account_links WHERE auth_id = o1 AND brand_id = b1 AND status = 'active')
--              ||'/'||(SELECT lower(btrim(e->>'email')) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true')
--              ||'/'||(SELECT count(*) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true')
--              ||'/'||(SELECT jsonb_array_length(contacts) FROM public.brands WHERE id = b1);
--       v_out := v_out || E'\n[V7] 되돌리기(ok·o1 대표·표시 o1·표시 1개·담당자 줄 2) ' ||
--                CASE WHEN v_g = 'ok/owner/zz-533-o1@example.invalid/1/2' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V8][V9] 멤버 상한 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_set_brand_member_limit(b1, 0)->>'result';
--       r2 := public.admin_set_brand_member_limit(b1, 51)->>'result';
--       r3 := public.admin_set_brand_member_limit(b1, NULL)->>'result';
--       r4 := public.admin_set_brand_member_limit(gen_random_uuid(), 3)->>'result';
--       r  := public.admin_set_brand_member_limit(b1, 3);
--       r5 := (r->>'result')||':'||(r->>'member_limit')||':'||(r->>'seat_used');
--       r  := public.admin_set_brand_member_limit(b1, 1);        -- 지금 인원(3)보다 작아도 받는다
--       r6 := (r->>'result')||':'||(r->>'member_limit')||':'||(r->>'seat_used');
--       r  := public.admin_set_brand_member_limit(b1, 5);
--       r7 := (r->>'result')||':'||(r->>'member_limit')||':'||(r->>'seat_used');
--       RESET ROLE;
--       v_g := r1||'/'||r2||'/'||r3||'/'||r4||'/'||r5||'/'||r6||'/'||r7;
--       v_out := v_out || E'\n[V8] 상한 ' || CASE WHEN v_g = 'invalid_limit/invalid_limit/invalid_limit/brand_not_found/ok:3:3/ok:1:3/ok:5:3' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (SELECT count(*) FROM public.brand_member_limits WHERE brand_id = b1)||'/'||(SELECT member_limit FROM public.brand_member_limits WHERE brand_id = b1)
--              ||'/'||((SELECT updated_by FROM public.brand_member_limits WHERE brand_id = b1) = adm_c);
--       v_out := v_out || E'\n[V9] 상한 행 저장(1행·5·기록자=관리자) ' || CASE WHEN v_g = '1/5/true' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V10] 매니저 권한을 쓰기로 바꾸면 같은 호출이 ok (서버가 설정을 실제로 따른다) — 이 DO 안이라 끝에 되돌려진다 ──
--       UPDATE public.role_permissions SET access_level = 'write' WHERE role = 'campaign_manager' AND feature_key = 'brand.account_manage';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_m, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_set_brand_member_limit(b1, 5)->>'result';
--       RESET ROLE;
--       UPDATE public.role_permissions SET access_level = 'hidden' WHERE role = 'campaign_manager' AND feature_key = 'brand.account_manage';
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_m, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r2 := public.admin_set_brand_member_limit(b1, 5)->>'result';
--       RESET ROLE;
--       v_g := r1||'/'||r2;
--       v_out := v_out || E'\n[V10] 매니저 쓰기 허용→ok / 다시 잠금→forbidden ' || CASE WHEN v_g = 'ok/forbidden' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V11][V12] 해제: 없는 연결 · 멤버 있는 대표 거부 · 멤버 해제 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_release_brand_account(b1, x)->>'result';
--       r2 := public.admin_release_brand_account(b1, o1)->>'result';
--       r  := public.admin_release_brand_account(b1, m1);
--       r3 := (r->>'result')||':'||(r->>'cancelled_invites');
--       RESET ROLE;
--       v_g := r1||'/'||r2||'/'||r3;
--       v_out := v_out || E'\n[V11] 해제 응답(없는 연결·멤버 있는 대표·멤버 해제) ' || CASE WHEN v_g = 'not_linked/owner_has_members/ok:0' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (SELECT count(*) FROM public.brand_account_links WHERE auth_id = m1 AND brand_id = b1 AND status = 'active')
--              ||'/'||((SELECT count(*) FROM public.brand_account_links WHERE auth_id = m1 AND brand_id = b1 AND status = 'released') >= 1);
--       v_out := v_out || E'\n[V12] 멤버 연결 해제됨(활성 0·이력 있음) ' || CASE WHEN v_g = '0/true' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V13] 새 이메일 초대: 계정 만들기 단계까지 진행 (조각 6 서버 함수가 하는 일을 SQL 로 흉내) ──
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at)
--         VALUES (b1,'zz-533-n@example.invalid',o1,'대표1','pending','new',now(),now()+interval '24 hours') RETURNING link_id INTO link_n;
--       r := public.service_brand_invite_create_account(link_n, '신규N', '010', 'zz-533-terms');
--       acct_n := NULLIF(r->>'auth_id','')::uuid;
--       v_g := (r->>'ok')||'/'||(SELECT count(*) FROM public.brand_accounts WHERE auth_id = acct_n);
--       v_out := v_out || E'\n[V13] 새 이메일 초대 계정 만들기 단계(ok·계정 1) ' || CASE WHEN v_g = 'true/1' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       UPDATE auth.users SET encrypted_password = 'x' WHERE id = acct_n;       -- 비밀번호 저장 단계 흉내
--     
--       -- ── [V14][V15][V16] 대표 해제 → 상태가 대기인 초대 전부 취소(i1·i2·n = 3) → 마무리 호출은 invalid_link ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r := public.admin_release_brand_account(b1, o1);
--       r1 := (r->>'result')||':'||(r->>'cancelled_invites');
--       RESET ROLE;
--       v_out := v_out || E'\n[V14] 대표 해제 응답(ok:3) ' || CASE WHEN r1 = 'ok:3' THEN 'PASS' ELSE 'FAIL got='||r1 END;
--       v_g := (SELECT count(*) FROM public.brand_invites WHERE brand_id = b1 AND status = 'cancelled' AND cancelled_at IS NOT NULL)
--              ||'/'||(SELECT count(*) FROM public.brand_invites WHERE brand_id = b1 AND status = 'pending')
--              ||'/'||(SELECT count(*) FROM public.brand_invites WHERE brand_id = b1 AND status = 'declined')
--              ||'/'||(SELECT count(*) FROM public.brand_account_links WHERE brand_id = b1 AND status = 'active');
--       v_out := v_out || E'\n[V15] 해제 뒤(취소 3·대기 0·거절 1 그대로·활성 연결 0) ' || CASE WHEN v_g = '3/0/1/0' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       r := public.service_brand_invite_finalize(link_n, acct_n);
--       v_out := v_out || E'\n[V16] 취소된 초대의 마무리(invalid_link) ' || CASE WHEN r->>'reason' = 'invalid_link' THEN 'PASS' ELSE 'FAIL got='||COALESCE(r->>'reason','null') END;
--     
--       -- ── [V17] 해제 뒤 상태 조회와 재해제 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r := public.admin_get_brand_account_status(b1);
--       r1 := public.admin_release_brand_account(b1, o1)->>'result';
--       RESET ROLE;
--       v_g := (r->>'status')||'/'||jsonb_array_length(r->'members')||'/'||jsonb_typeof(r->'owner_auth_id')||'/'||(r->>'pending_invite_count')||'/'||(r->>'release_cancel_count')||'/'||r1;
--       v_out := v_out || E'\n[V17] 해제 뒤 상태(none·목록 0·대표 null·대기 0·취소대상 0)+재해제 not_linked ' || CASE WHEN v_g = 'none/0/null/0/0/not_linked' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V18][V19] 브랜드 연결 추가: 다른 브랜드(b2) 대표 계정 o2 를 b1 대표로 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r := public.admin_link_brand_owner_account(b1, ' ZZ-533-O2@example.invalid ');
--       RESET ROLE;
--       v_g := (r->>'result')||'/'||(r->>'password_set')||'/'||(r->>'email_kind')||'/'||((r->>'auth_id')::uuid = o2);
--       v_out := v_out || E'\n[V18] 연결 추가 응답(ok·비밀번호 설정됨·brand·o2) ' || CASE WHEN v_g = 'ok/true/brand/true' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (SELECT count(*) FROM public.brand_account_links WHERE brand_id = b1 AND auth_id = o2 AND role = 'owner' AND status = 'active')
--              ||'/'||(SELECT lower(btrim(e->>'email')) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true')
--              ||'/'||(SELECT count(*) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b1 AND e->>'is_primary' = 'true')
--              ||'/'||((SELECT source_contact_id FROM public.brand_account_links WHERE brand_id = b1 AND auth_id = o2 AND status = 'active') IS NOT NULL)
--              ||'/'||(SELECT count(*) FROM public.brand_account_links WHERE auth_id = o2 AND status = 'active');
--       v_out := v_out || E'\n[V19] 연결 뒤(대표 1·담당자 표시 o2·표시 1개·근거 줄 있음·o2 활성 연결 2) ' ||
--                CASE WHEN v_g = '1/zz-533-o2@example.invalid/1/true/2' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V20][V21][V22] 연결 추가 거부들 · 527 겹침(conflict_brand)은 그대로 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r1 := public.admin_link_brand_owner_account(b1, 'zz-533-x@example.invalid')->>'result';
--       r  := public.admin_link_brand_owner_account(b3, 'zz-533-inf@example.invalid');   r2 := (r->>'result')||':'||(r->>'email_kind');
--       r  := public.admin_link_brand_owner_account(b3, adm_c_email);                     r3 := (r->>'result')||':'||(r->>'email_kind');
--       r  := public.admin_link_brand_owner_account(b3, 'zz-533-none@example.invalid');  r4 := (r->>'result')||':'||(r->>'email_kind');
--       r5 := public.admin_link_brand_owner_account(b3, 'abc')->>'result';
--       r6 := public.admin_link_brand_owner_account(b4, 'zz-533-x@example.invalid')->>'result';
--       r7 := public.admin_link_brand_owner_account(gen_random_uuid(), 'zz-533-x@example.invalid')->>'result';
--       rc := public.admin_upsert_brand_owner_account(b5, NULL, NULL);
--       RESET ROLE;
--       v_g := r1||'/'||r2||'/'||r3||'/'||r4||'/'||r5||'/'||r6||'/'||r7;
--       v_out := v_out || E'\n[V20] 연결 추가 거부들 ' ||
--                CASE WHEN v_g = 'owner_exists/not_brand_account:influencer/not_brand_account:admin/not_brand_account:none/invalid_email/brand_archived/brand_not_found' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_out := v_out || E'\n[V21] 계정 만들기는 겹치면 conflict_brand 그대로(527 판정 불변) ' || CASE WHEN rc->>'result' = 'conflict_brand' THEN 'PASS' ELSE 'FAIL got='||COALESCE(rc->>'result','null') END;
--     
--       -- ── [V22][V23][V24] 비밀번호 미설정 계정 연결(password_set=false) → 이메일 교체 갈래에서 보낸 쪽 기록도 비운다 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r := public.admin_link_brand_owner_account(b3, 'zz-533-x@example.invalid');
--       RESET ROLE;
--       v_g := (r->>'result')||'/'||(r->>'password_set');
--       v_out := v_out || E'\n[V22] 비밀번호 미설정 계정 연결(ok·password_set=false) ' || CASE WHEN v_g = 'ok/false' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       UPDATE public.brand_accounts SET setup_mail_sent_at = now(), setup_mail_sent_to = email, setup_mail_sent_by = 'admin', setup_link_id = gen_random_uuid() WHERE auth_id = x;
--       UPDATE public.brand_account_links SET last_active_at = now() WHERE auth_id = x AND brand_id = b3 AND status = 'active';
--       UPDATE public.brands SET contacts = jsonb_build_array(jsonb_build_object('id','k3','name','신규','phone','','email','zz-533-x2@example.invalid','is_primary',true)) WHERE id = b3;
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       rc := public.admin_get_brand_account_status(b3);          -- 교체 전 상태(설정 전 대표 줄의 마지막 접속은 가린다)
--       r  := public.admin_upsert_brand_owner_account(b3, NULL, NULL);
--       RESET ROLE;
--       v_g := (rc->>'status')||'/'||jsonb_typeof(rc->'members'->0->'last_active_at')||'/'||(rc->>'setup_mail_sent_by');
--       v_out := v_out || E'\n[V23] 설정 전 대표 줄(상태 mail_sent·마지막 접속 가림·보낸 쪽 admin) ' || CASE WHEN v_g = 'mail_sent/null/admin' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--       v_g := (r->>'result')||'/'||(r->>'needs_mail')||'/'||(SELECT email FROM public.brand_accounts WHERE auth_id = x)
--              ||'/'||((SELECT setup_mail_sent_by FROM public.brand_accounts WHERE auth_id = x) IS NULL)
--              ||'/'||((SELECT setup_mail_sent_at FROM public.brand_accounts WHERE auth_id = x) IS NULL)
--              ||'/'||(SELECT email FROM auth.users WHERE id = x);
--       v_out := v_out || E'\n[V24] 이메일 교체 갈래(email_replaced·메일 필요·새 이메일·보낸 쪽/시각 비움·인증 계정 이메일) ' ||
--                CASE WHEN v_g = 'email_replaced/true/zz-533-x2@example.invalid/true/true/zz-533-x2@example.invalid' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V25] 겹침 확인 조회 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', adm_c, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       r  := public.admin_check_brand_account_email(b1, 'zz-533-o1@example.invalid');
--       r1 := (r->>'email_kind')||'/'||(r->>'linked_brand_count')||'/'||(r->>'released_from_this_brand')||'/'||(r->>'name');
--       r  := public.admin_check_brand_account_email(b1, 'zz-533-o2@example.invalid');
--       r2 := (r->>'email_kind')||'/'||(r->>'linked_brand_count')||'/'||(r->>'released_from_this_brand')||'/'||(r->>'name');
--       r3 := (public.admin_check_brand_account_email(b1, 'zz-533-inf@example.invalid')->>'email_kind')
--             ||'/'||(public.admin_check_brand_account_email(b1, adm_c_email)->>'email_kind')
--             ||'/'||(public.admin_check_brand_account_email(b1, 'zz-533-none@example.invalid')->>'email_kind')
--             ||'/'||(public.admin_check_brand_account_email(b1, 'abc')->>'result');
--       RESET ROLE;
--       v_g := r1||';'||r2||';'||r3;
--       v_out := v_out || E'\n[V25] 겹침 확인(해제된 옛 대표 / 두 브랜드 연결 / 인플루언서·관리자·없음·형식오류) ' ||
--                CASE WHEN v_g = 'brand/0/true/대표1;brand/2/false/대표2;influencer/admin/none/invalid_email' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       -- ── [V26] 로그아웃 상태(관리자 아님)에서 조회 둘은 오류 42501 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', inf, 'role', 'authenticated')::text, true);
--       SET LOCAL ROLE authenticated;
--       BEGIN
--         r := public.admin_get_brand_account_status(b1);
--         r1 := 'no_error';
--       EXCEPTION WHEN insufficient_privilege THEN r1 := '42501';
--       END;
--       BEGIN
--         rc := public.admin_check_brand_account_email(b1, 'zz-533-o1@example.invalid');
--         r2 := 'no_error';
--       EXCEPTION WHEN insufficient_privilege THEN r2 := '42501';
--       END;
--       RESET ROLE;
--       v_g := r1||'/'||r2;
--       v_out := v_out || E'\n[V26] 관리자가 아닌 계정의 조회 둘(42501) ' || CASE WHEN v_g = '42501/42501' THEN 'PASS' ELSE 'FAIL got='||v_g END;
--     
--       RAISE EXCEPTION '533 시험 결과(전부 되돌림, 임시 관리자: %): %', COALESCE(NULLIF(v_temp,''),'없음'), v_out;
--     END $$;
--
--     기대(줄바꿈 후 라벨별): [V1] 매니저 쓰기 다섯 PASS … [V26] PASS (26줄 전부 PASS, "임시 관리자: 없음" 이면 기존 관리자 계정으로 돈 것)
--     그다음 따로(시험 뒤 잔여 확인 — 앞 넷 0, 마지막 1 이어야 한다. 아니면 멈추고 알릴 것):
--       SELECT (SELECT count(*) FROM auth.users WHERE email LIKE 'zz-533-%') AS users,
--              (SELECT count(*) FROM public.brands WHERE name LIKE 'zz-533-%') AS brands,
--              (SELECT count(*) FROM public.brand_invites WHERE email LIKE 'zz-533-%') AS invites,
--              (SELECT count(*) FROM public.brand_accounts WHERE email LIKE 'zz-533-%') AS accounts,
--              (SELECT count(*) FROM public.admins WHERE email LIKE 'zz-533-%') AS temp_admins,
--              (SELECT count(*) FROM public.role_permissions WHERE role='campaign_manager' AND feature_key='brand.account_manage' AND access_level='hidden') AS manager_hidden;
--       (users·brands·invites·accounts·temp_admins = 0, manager_hidden = 1)
--   [확인3] 로그인한 관리자 브라우저에서 상태 조회 1회(관리자 가드는 SQL 편집기로 재현되지 않는다 — 서비스 키에는 로그인 사용자가 없다):
--        (await db.rpc('admin_get_brand_account_status', {p_brand_id: '<브랜드 아이디>'})).data → 새 칸들이 모두 있고 can_manage 가 등급대로(캠페인 매니저면 false).
--   ⚠️ 로그인 흉내(set_config)는 auth.uid() 를 바꿀 뿐이다. 실제 로그인 세션에서의 호출은 묶음 ③(화면) 때 따로 확인한다.
-- ============================================================

BEGIN;

-- ── 1. admin_upsert_brand_owner_account (재정의 — 베이스 527, 본문 그대로 + 아래 둘만 다르다) ──
--   ① 가드: is_campaign_admin() → has_permission('brand.account_manage','write') (거부는 같은 forbidden)
--   ② 갈래 ④(설정 전 이메일 교체): setup_mail_sent_by 도 NULL 로 비운다(옛 메일의 「보낸 쪽」이 새 이메일에 남지 않게)
--   그 밖(판정 규칙·conflict_brand 반환 포함)은 527 과 글자 그대로 같다. 시그니처·반환형이 같아 CREATE OR REPLACE.
--   판정 규칙은 527 머리말 B 표. 반환 jsonb 칸: result · needs_mail · email · auth_id · account_email · brand_id
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
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
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
               -- 옛 메일의 인증 서비스 일회용 토큰도 비운다(옛 링크로 세션이 생기지 않게 — 527 리뷰 권고)
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
               setup_mail_sent_to = NULL,
               setup_mail_sent_by = NULL      -- 533: 보낸 쪽 기록도 함께 비운다
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
  '[533] (527 재정의: 가드를 brand.account_manage 쓰기 권한으로 교체 + 이메일 교체 때 setup_mail_sent_by 비움) 브랜드 대표 담당자 계정 만들기/바꾸기(안쪽 재확인). 판정 규칙은 527 머리말 B 표. 반환 jsonb: result·needs_mail·email·auth_id·account_email·brand_id.
   result = created·noop·email_replaced·password_already_set·primary_moved·conflict_influencer·conflict_admin·conflict_brand·no_primary_email·invalid_email·brand_not_found·brand_archived·forbidden.';

GRANT  EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_upsert_brand_owner_account(uuid, text, text) FROM anon;

-- ── 2. admin_get_brand_account_status (확장) ────────────────────────────
--   기존 칸 4개(status·email·setup_mail_sent_at·password_set_at)는 그대로 + 새 칸. 관리자 아니면 42501 (527 과 같다 — 화면은 실패를 null 로 받는다).
--   🔴 대기 초대 숫자 둘은 **정의가 다르다**(사양서 §16 머리 낱말 정의):
--     pending_invite_count = status='pending' 이고 expires_at > now() (만료 전 — 「초대 대기 N 포함」)
--     release_cancel_count = status='pending' 전부(만료 줄 포함 — 대표 해제 때 함께 취소될 건수, admin_release_brand_account 가 실제로 취소하는 줄과 같은 조건)
--   초대 줄·이메일은 돌려주지 않는다(수락 안 한 사람의 이메일 보호 — 16-5 11번).
CREATE OR REPLACE FUNCTION public.admin_get_brand_account_status(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_acct    public.brand_accounts%ROWTYPE;
  v_owner   uuid;
  v_status  text;
  v_members jsonb;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT a.* INTO v_acct
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active'
   LIMIT 1;

  IF FOUND THEN
    v_owner  := v_acct.auth_id;
    v_status := CASE
                  WHEN v_acct.password_set_at IS NOT NULL THEN 'active'
                  WHEN v_acct.setup_mail_sent_at IS NOT NULL THEN 'mail_sent'
                  ELSE 'mail_pending'
                END;
  ELSE
    v_owner  := NULL;
    v_status := 'none';
  END IF;

  -- 활성 연결 전원(대표 먼저). 비밀번호를 아직 안 정한 계정의 마지막 접속은 가린다(대표 줄은 「설정 완료」일 때만 값이 있다 — 16-4)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'auth_id',         a.auth_id,
           'role',            l.role,
           'name',            a.name,
           'email',           a.email,
           'phone',           a.phone,
           'last_active_at',  CASE WHEN a.password_set_at IS NOT NULL THEN l.last_active_at ELSE NULL END,
           'password_set_at', a.password_set_at
         ) ORDER BY (l.role = 'owner') DESC, l.created_at, l.id), '[]'::jsonb)
    INTO v_members
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
   WHERE l.brand_id = p_brand_id AND l.status = 'active';

  RETURN jsonb_build_object(
    'status',               v_status,
    'email',                CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.email END,
    'setup_mail_sent_at',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_at END,
    'password_set_at',      CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.password_set_at END,
    'setup_mail_sent_by',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_by END,
    'owner_auth_id',        v_owner,
    'members',              v_members,
    'pending_invite_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending' AND i.expires_at > now()),
    'release_cancel_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending'),
    'seat_used',            public._brand_seat_usage(p_brand_id),
    'member_limit',         public._brand_member_limit(p_brand_id),
    'can_manage',           public.has_permission('brand.account_manage', 'write')
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_account_status(uuid) IS
  '[533] 관리자 화면 계정 줄 상태(관리자 전원, 아니면 42501). 527 칸 유지(status none/mail_pending/mail_sent/active · email · setup_mail_sent_at · password_set_at) + setup_mail_sent_by · owner_auth_id · members[](활성 연결 전원, 대표 먼저: auth_id·role·name·email·phone·last_active_at[비밀번호 미설정 계정은 null]·password_set_at) · pending_invite_count(만료 전 대기) · release_cancel_count(상태가 대기인 초대 전부) · seat_used · member_limit · can_manage(brand.account_manage 쓰기). 초대 줄·이메일은 싣지 않는다.';

GRANT  EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_account_status(uuid) FROM anon;

-- ── 3. admin_check_brand_account_email (신설, 조회 — 관리자 전원) ──────────
--   「계정 만들기」 전 겹침 확인 창(사양서 16-3 1번)용. 관리자에게는 숨길 이유가 없어 종류·이름을 그대로 돌려준다.
--   result: ok | invalid_email.  email_kind: none | brand | influencer | admin (우선순위 admin > brand > influencer — _brand_email_owner).
CREATE OR REPLACE FUNCTION public.admin_check_brand_account_email(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email  text := lower(btrim(COALESCE(p_email, '')));
  v_owner  jsonb;
  v_kind   text;
  v_id     uuid;
  v_name   text;
  v_linked integer := 0;
  v_rel    boolean := false;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'email_kind', NULL, 'name', NULL,
                              'linked_brand_count', 0, 'released_from_this_brand', false);
  END IF;

  v_owner := public._brand_email_owner(v_email, NULL);
  v_kind  := v_owner->>'kind';
  v_id    := NULLIF(v_owner->>'auth_id', '')::uuid;

  IF v_kind = 'brand' THEN
    SELECT a.name INTO v_name FROM public.brand_accounts a WHERE a.auth_id = v_id;
    SELECT count(*)::int INTO v_linked
      FROM public.brand_account_links l
      JOIN public.brands b ON b.id = l.brand_id
     WHERE l.auth_id = v_id AND l.status = 'active';
    v_rel := p_brand_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.brand_account_links l
       WHERE l.auth_id = v_id AND l.brand_id = p_brand_id AND l.status = 'released');
  ELSIF v_kind = 'admin' THEN
    SELECT NULLIF(btrim(a.name), '') INTO v_name FROM public.admins a WHERE a.auth_id = v_id;
  ELSIF v_kind = 'influencer' THEN
    SELECT COALESCE(NULLIF(btrim(i.name_kanji), ''), NULLIF(btrim(i.name), ''))
      INTO v_name FROM public.influencers i WHERE i.id = v_id;
  END IF;

  RETURN jsonb_build_object(
    'result',                  'ok',
    'email_kind',              v_kind,
    'name',                    v_name,
    'linked_brand_count',      v_linked,
    'released_from_this_brand', v_rel
  );
END;
$$;

COMMENT ON FUNCTION public.admin_check_brand_account_email(uuid, text) IS
  '[533] 계정 만들기 전 겹침 확인 조회(관리자 전원, 아니면 42501). 반환 {result: ok|invalid_email, email_kind: none|brand|influencer|admin, name, linked_brand_count(활성 연결 수 — brand 만), released_from_this_brand(이 브랜드에서 해제된 연결 이력 — brand 만)}.';

GRANT  EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_check_brand_account_email(uuid, text) FROM anon;

-- ── 4. admin_change_brand_owner (신설) ─────────────────────────────────
--   a03-02b 「다른 관리자가 먼저 바꿈」 방어: 화면이 연 시점의 대표(p_expected_owner_auth_id)가 지금 대표와 다르면 owner_changed.
--   본체는 531 의 _brand_transfer_owner(옛 대표 해제 + 멤버 연결 + 새 대표 쪽 같은 방식 + 마지막 활동 이어받기 + 담당자 표시 이동). 메일 없음.
CREATE OR REPLACE FUNCTION public.admin_change_brand_owner(
  p_brand_id                uuid,
  p_new_owner_auth_id       uuid,
  p_expected_owner_auth_id  uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cur uuid;
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN 'forbidden';
  END IF;
  IF p_brand_id IS NULL OR p_new_owner_auth_id IS NULL THEN
    RETURN 'not_member';
  END IF;

  -- 브랜드 잠금(527·531 과 같은 열쇠) — 수락·해제와 순서가 정해진다
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT l.auth_id INTO v_cur
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active';
  IF NOT FOUND OR v_cur IS DISTINCT FROM p_expected_owner_auth_id THEN
    RETURN 'owner_changed';
  END IF;

  RETURN public._brand_transfer_owner(p_brand_id, p_new_owner_auth_id);   -- ok | not_member
END;
$$;

COMMENT ON FUNCTION public.admin_change_brand_owner(uuid, uuid, uuid) IS
  '[533] 관리자 대표 바꾸기. brand.account_manage 쓰기 권한(아니면 forbidden). 반환 ok | forbidden | owner_changed(지금 대표가 기대한 대표와 다름·대표 없음) | not_member(새 대표가 활성 멤버가 아님). 본체는 531 _brand_transfer_owner. 메일 없음.';

GRANT  EXECUTE ON FUNCTION public.admin_change_brand_owner(uuid, uuid, uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_change_brand_owner(uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_change_brand_owner(uuid, uuid, uuid) FROM anon;

-- ── 5. admin_set_brand_member_limit (신설) ─────────────────────────────
--   지금 인원보다 작게도 받는다(새 초대만 막힌다). 이력 없음. 표는 530 brand_member_limits(쓰기 정책 없음 — 이 함수가 유일한 쓰기 길).
CREATE OR REPLACE FUNCTION public.admin_set_brand_member_limit(p_brand_id uuid, p_limit int)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'member_limit', NULL, 'seat_used', NULL);
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 50 THEN
    RETURN jsonb_build_object('result', 'invalid_limit', 'member_limit', NULL, 'seat_used', NULL);
  END IF;
  IF p_brand_id IS NULL OR NOT EXISTS (SELECT 1 FROM public.brands b WHERE b.id = p_brand_id) THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'member_limit', NULL, 'seat_used', NULL);
  END IF;

  -- 상한과 초대 자리 검사가 엇갈리지 않게 같은 브랜드 잠금 안에서
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  INSERT INTO public.brand_member_limits (brand_id, member_limit, updated_at, updated_by)
  VALUES (p_brand_id, p_limit, now(), auth.uid())
  ON CONFLICT (brand_id) DO UPDATE
    SET member_limit = EXCLUDED.member_limit,
        updated_at   = EXCLUDED.updated_at,
        updated_by   = EXCLUDED.updated_by;

  RETURN jsonb_build_object('result', 'ok', 'member_limit', p_limit, 'seat_used', public._brand_seat_usage(p_brand_id));
END;
$$;

COMMENT ON FUNCTION public.admin_set_brand_member_limit(uuid, int) IS
  '[533] 브랜드별 인원 상한(대표 포함, 1~50) 저장. brand.account_manage 쓰기 권한. 반환 {result: ok|forbidden|invalid_limit|brand_not_found, member_limit, seat_used}. 지금 인원보다 작아도 받는다. 이력 없음(updated_at·updated_by 만).';

GRANT  EXECUTE ON FUNCTION public.admin_set_brand_member_limit(uuid, int) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_member_limit(uuid, int) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_brand_member_limit(uuid, int) FROM anon;

-- ── 6. admin_release_brand_account (신설) ──────────────────────────────
--   연결 해제(이력 보존 — 지우지 않고 status='released'). 멤버는 그냥 해제. 대표는 활성 멤버가 있으면 owner_has_members(먼저 대표 바꾸기).
--   S0-1: 대표를 해제하면 그 브랜드의 status='pending' 초대 **전부**(만료 줄·ⓒ·상태가 바뀐 줄·누가 보냈든) 를 같은 트랜잭션에서 cancelled 로 — 대표 없는 브랜드에 멤버가 생기는 길을 막는다.
--   수락 쪽(respond_brand_invite·service_brand_invite_finalize)은 같은 브랜드 잠금 안에서 초대를 다시 판정한다 → 해제가 먼저면 수락이 invalid, 수락이 먼저면 멤버가 생겨 해제가 거부된다.
CREATE OR REPLACE FUNCTION public.admin_release_brand_account(p_brand_id uuid, p_auth_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_link      public.brand_account_links%ROWTYPE;
  v_cancelled integer := 0;
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'cancelled_invites', 0);
  END IF;
  IF p_brand_id IS NULL OR p_auth_id IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked', 'cancelled_invites', 0);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT l.* INTO v_link
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.auth_id = p_auth_id AND l.status = 'active'
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_linked', 'cancelled_invites', 0);
  END IF;

  IF v_link.role = 'owner' THEN
    IF EXISTS (SELECT 1 FROM public.brand_account_links m
                WHERE m.brand_id = p_brand_id AND m.role = 'member' AND m.status = 'active') THEN
      RETURN jsonb_build_object('result', 'owner_has_members', 'cancelled_invites', 0);
    END IF;

    UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_link.id;

    UPDATE public.brand_invites
       SET status = 'cancelled', cancelled_at = now()
     WHERE brand_id = p_brand_id AND status = 'pending';
    GET DIAGNOSTICS v_cancelled = ROW_COUNT;
  ELSE
    UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_link.id;
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'cancelled_invites', v_cancelled);
END;
$$;

COMMENT ON FUNCTION public.admin_release_brand_account(uuid, uuid) IS
  '[533] 관리자 연결 해제. brand.account_manage 쓰기 권한. 반환 {result: ok|forbidden|not_linked|owner_has_members, cancelled_invites}. 대표를 해제하면 그 브랜드의 status=pending 초대 전부(만료 줄 포함)를 함께 cancelled — 취소 건수 반환(admin_get_brand_account_status.release_cancel_count 와 같은 조건). 멤버 해제는 취소 0. 받은 사람에게 메일 없음.';

GRANT  EXECUTE ON FUNCTION public.admin_release_brand_account(uuid, uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_release_brand_account(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_release_brand_account(uuid, uuid) FROM anon;

-- ── 7. admin_link_brand_owner_account (신설) ───────────────────────────
--   대표 없는 브랜드에 **이미 있는 브랜드 계정**을 대표로 잇는다(다른 브랜드에 연결된 계정도 허용 — 527 의 conflict_brand 를 이 경로에서만 푼다).
--   메일은 보내지 않는다 — 화면이 이어서 notify-brand-account-setup 을 mail_kind:'link' 로 부르고, 양식은 서버가 password_set 로 고른다(조각 7).
--   담당자 표시 이동: 531 _brand_contacts_mark_primary. 근거 줄(source_contact_id)에는 표시가 옮겨진 줄의 id 를 적는다(527 다음 저장이 noop 으로 알아본다).
--   email_kind: 거부(not_brand_account)일 때 none|influencer|admin(a03-04a 문구용), ok 일 때 'brand'.
CREATE OR REPLACE FUNCTION public.admin_link_brand_owner_account(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email    text := lower(btrim(COALESCE(p_email, '')));
  v_status   text;
  v_owner    jsonb;
  v_kind     text;
  v_auth     uuid;
  v_acct     public.brand_accounts%ROWTYPE;
  v_prim_id  text;
BEGIN
  IF NOT public.has_permission('brand.account_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;

  -- 브랜드 → 이메일 순서(527·531 과 같다)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;
  IF v_status <> 'active' THEN
    RETURN jsonb_build_object('result', 'brand_archived', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN jsonb_build_object('result', 'invalid_email', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active') THEN
    RETURN jsonb_build_object('result', 'owner_exists', 'auth_id', NULL, 'password_set', NULL, 'email_kind', NULL);
  END IF;

  v_owner := public._brand_email_owner(v_email, NULL);
  v_kind  := v_owner->>'kind';
  v_auth  := NULLIF(v_owner->>'auth_id', '')::uuid;
  IF v_kind <> 'brand' OR v_auth IS NULL THEN
    RETURN jsonb_build_object('result', 'not_brand_account', 'auth_id', NULL, 'password_set', NULL, 'email_kind', v_kind);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_auth FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_brand_account', 'auth_id', NULL, 'password_set', NULL, 'email_kind', 'none');
  END IF;

  IF EXISTS (SELECT 1 FROM public.brand_account_links l
              WHERE l.brand_id = p_brand_id AND l.auth_id = v_auth AND l.status = 'active') THEN
    -- 이 브랜드의 활성 멤버(대표 없는 브랜드에 멤버가 있는 비정상 상태 포함) — 새 연결을 만들지 않고 대표로 올린다
    PERFORM public._brand_transfer_owner(p_brand_id, v_auth);
  ELSE
    INSERT INTO public.brand_account_links (auth_id, brand_id, role, status)
    VALUES (v_auth, p_brand_id, 'owner', 'active');
    PERFORM public._brand_contacts_mark_primary(p_brand_id, v_auth);
  END IF;

  -- 근거 줄: 담당자 목록에서 지금 대표 표시가 붙은 줄
  SELECT NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') INTO v_prim_id
    FROM public.brands b, jsonb_array_elements(CASE WHEN jsonb_typeof(b.contacts) = 'array' THEN b.contacts ELSE '[]'::jsonb END) WITH ORDINALITY AS e(elem, ord)
   WHERE b.id = p_brand_id AND e.elem->>'is_primary' = 'true'
   ORDER BY e.ord
   LIMIT 1;
  IF v_prim_id IS NOT NULL THEN
    UPDATE public.brand_account_links SET source_contact_id = v_prim_id
     WHERE brand_id = p_brand_id AND auth_id = v_auth AND status = 'active';
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'auth_id', v_auth, 'password_set', v_acct.password_set_at IS NOT NULL, 'email_kind', 'brand');
END;
$$;

COMMENT ON FUNCTION public.admin_link_brand_owner_account(uuid, text) IS
  '[533] 관리자 「브랜드 연결 추가」 — 대표 없는 브랜드에 이미 있는 브랜드 계정을 대표로 잇는다(다른 브랜드 연결 허용). brand.account_manage 쓰기 권한. 반환 {result: ok|forbidden|owner_exists|not_brand_account|brand_archived|brand_not_found|invalid_email, auth_id, password_set, email_kind}. 담당자 목록 대표 표시를 서버가 옮긴다. 메일은 안 보낸다(화면이 notify-brand-account-setup mail_kind:link 를 부른다).';

GRANT  EXECUTE ON FUNCTION public.admin_link_brand_owner_account(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_link_brand_owner_account(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_link_brand_owner_account(uuid, text) FROM anon;

NOTIFY pgrst, 'reload schema';

COMMIT;
