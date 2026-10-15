-- ============================================================
-- 531_brand_owner_functions.sql
-- 브랜드 멤버 관리·여러 브랜드 — 작업 2: 대표 함수 (초대 관리 · 대표 넘기기 · 멤버 해제 · 멤버 목록)
--   작업표 docs/specs/2026-10-15-brand-member-breakdown.md 「작업 2 — 대표 함수」 · 사양서 docs/specs/2026-07-15-brand-portal.md §16-2·§16-3·§16-4(06 멤버 관리·화면 정책 넷 ②)·§16-7
--
-- 목적
--   ① 로그인 사용자 함수 7개(SECURITY DEFINER, search_path=''):
--        create_brand_invite · resend_brand_invite · cancel_brand_invite · hide_brand_invite
--        transfer_brand_ownership · release_brand_member · get_brand_members
--   ② 안쪽 전용 2개(호출 불가): _brand_transfer_owner(조각 4 admin_change_brand_owner 도 부른다) · _brand_contacts_mark_primary
--   ③ 안쪽 전용 도우미 6개(식·판정 사본을 한 곳에 두려는 것): _brand_invite_expires_at · _brand_invite_recipient_info ·
--        _brand_invite_inviter_name · _brand_invite_reissue · _brand_invite_result · _brand_caller_link_role
--   함수만 추가한다 — 표·칸은 530 이 만들었고, 기존 함수는 건드리지 않는다. 적용만으로 바뀌는 기존 동작: 없음.
--
-- 베이스
--   530 : 표 brand_invites·brand_member_limits · 도우미 my_brand_role·_brand_member_limit·_brand_seat_usage
--   527 : _brand_email_owner(text, uuid) (none/admin/brand/influencer) · 잠금 열쇠 'brand_account_upsert:'||brand_id → 'brand_account_email:'||이메일 (이 순서)
--   526 : brand_account_links — 활성 대표 부분 유일 색인(브랜드당 1명) · (계정,브랜드) 활성 부분 유일 색인 · status active/released + released_at
--   brands.contacts : jsonb 배열 [{id, name, phone, email, is_primary}] (084, dev/js/admin-brand.js 의 _brandFormContacts 와 같은 구조)
--
-- 배포 순서
--   1) 530 이 먼저 들어가 있어야 한다. 🔴 개발서버만. 운영은 526~531 묶음으로(묶음 ① 전체 보류). 운영 반영 전 /약관확인
--      (brand_invites 에 계정 없는 사람의 이메일이 쌓인다 · 「마지막 접속」은 이용 기록 — 작업표 S2·사양서 16-3 9번).
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 이 파일 다음은 작업 3(받는 사람·본인 함수 + 527 넓히기).
--
-- 🔴 brands.contacts 덮어쓰기 경고 (공유 지점)
--   이 파일의 _brand_contacts_mark_primary 가 **서버가 brands.contacts 를 고치는 첫 경로**다(대표가 바뀔 때 대표 표시 이동).
--   그런데 관리자 브랜드 상세의 편집 폼(admin-brand.js saveBrandDetail)은 열 때 읽은 contacts 배열을 **통째로** 저장한다 —
--   폼을 연 채로 대표가 바뀌면 저장 순간 대표 표시가 옛 값으로 되돌아간다. 사양서 16-4 「화면 정책 넷」 ② 의 방어선
--   (「브랜드 정보 저장은 담당자 칸을 보내지 않는다」)은 묶음 ③ 몫이다 — **③ 이 들어가기 전에는 이 위험이 열려 있다.**
--   (merge_brands 528·광고주 신청서 함수 397 도 contacts 를 쓴다 — 서버끼리는 브랜드 잠금이 없어 직렬화되지 않는다.)
--
-- 설계 판단
--   [A] 쓰기 여섯(create·resend·cancel·hide·transfer·release)은 모두 브랜드 잠금(527 과 같은 열쇠) 안에서 「지금 이 브랜드의 활성 대표인가 + 브랜드 활성」을
--       **다시** 판정한다. 이메일을 다루는 create·resend 는 그 뒤에 이메일 잠금도 잡는다(브랜드 → 이메일 순서 — 527 과 같다. 데드락 방지).
--       초대 id 로 부르는 함수(resend·cancel·hide)는 브랜드를 알기 위해 잠금 **전에** 한 번 읽고, 잠금 뒤에 줄을 FOR UPDATE 로 다시 읽는다.
--   [B] 만료 식 `issued_at + interval '24 hours'` 는 _brand_invite_expires_at **한 곳**. create 의 새 줄 삽입과 _brand_invite_reissue(create·resend 공용)가 부른다.
--       표 기본값에는 두지 않았다(530 [B]).
--   [C] 「만료」는 저장하지 않는다 — status='pending' 이면서 expires_at <= now() 가 만료(사양서 §16 머리 정의 ①). 취소는 만료 전 대기만(cancel).
--   [D] create 응답은 어느 결과든 키 집합이 {result, invite_id, seat_used, member_limit} 로 같다(ⓐⓑⓒ 갈래를 짐작할 값 없음). ⓒ(관리자·인플루언서 이메일)도
--       `ok` 로 자리를 차지한다. 갈래는 서버가 _brand_email_owner 로 고르고 ⓑ 면 sent_owner_auth_id 를 저장한다. 호출자가 대표가 아니거나 브랜드가
--       비활성이면 seat_used·member_limit 는 NULL(자리 수를 대표에게만 준다).
--   [E] 남의 초대 존재 여부 비노출: resend 는 호출자가 그 브랜드의 활성 연결이 없으면(또는 줄이 없으면) 똑같이 `not_found`, 연결은 있는데 멤버거나 브랜드가
--       비활성이면 `not_owner`. cancel·hide 는 반환 값에 not_found 가 없어서 줄이 없든 남의 것이든 `not_owner` 로 같게 돌려준다.
--   [F] create 의 판정 순서: 대표 → 브랜드 활성 → 이메일 형식 → 본인 이메일 → 이미 활성 연결 → 같은 이메일 대기 초대(만료 → 자리 검사 후 그 줄 다시 보내기 +
--       owner_hidden_at 비움 / 만료 전 + 지금 링크 발송 기록 없음(mail_sent_link_id ≠ link_id) → 멱등: 같은 invite_id 로 링크·시각·갈래·보낼 때 상태·보낸 사람 새로,
--       자리 검사 없음 / 만료 전 + 발송 기록 있음 → already_pending) → 새 줄(자리 검사 → seat_full). 거절 줄은 재사용하지 않고 새 줄.
--   [G] resend: 대기(pending)만. 만료 줄만 자리 검사(seat_full) — 만료 전 줄은 이미 자리를 차지하므로 가득 차도 ok. 취소·수락·거절은 not_resendable.
--       reissue 는 새 link_id·issued_at·expires_at·갈래 재판정·mail_sent_* 비움·invited_by/inviter_name 을 지금 대표로·owner_hidden_at 비움.
--   [H] inviter_name 스냅샷 = brand_accounts.name (비었으면 brand_accounts.email).
--   [I] transfer: 옛 대표 연결·새 대표(멤버) 연결을 **둘 다 해제**한 뒤 새 연결 둘을 만든다(역할을 덮어쓰지 않는다 → 연결 표에 이력).
--       해제를 먼저 해야 「브랜드당 활성 대표 1명」 부분 유일 색인에 안 걸린다. 같은 문장 흐름·한 트랜잭션이라 대표 0명·2명 순간이 밖에서 안 보인다.
--       각 사람의 옛 연결 last_active_at 을 그 사람의 새 연결로 옮긴다(넘긴 순간 「—」로 바뀌지 않게). source_contact_id 도 옮긴다.
--       _brand_transfer_owner 는 대표 판정을 하지 않는다(호출하는 쪽 몫) — 새 사람이 활성 멤버 연결이 아니면 `not_member`, 이미 대표면 변경 없이 `ok`,
--       옛 대표가 없으면(대표 0명) 새 사람만 대표로 올린다. 함수 안에서 브랜드 잠금을 다시 잡는다(같은 트랜잭션이면 재진입 — 호출자가 이미 잡았어도 안전).
--   [J] _brand_contacts_mark_primary: 같은 사람 판정 = 이메일 lower(btrim()) 일치(첫 일치 줄). 있으면 그 줄에 is_primary=true, 나머지는 is_primary=false(줄은 지우지
--       않는다). 없으면 계정의 이름·이메일·연락처로 줄을 한 번 더한다(id = 새 uuid 문자열). 메일은 보내지 않는다. 대표를 해제만 하는 경로(release 는 멤버 전용)는 건드리지 않는다.
--   [K] release_brand_member 는 활성 **멤버**만 해제한다 — 대표·본인·이미 해제된 사람·연결 없는 사람은 not_member. (대표 해제는 관리자 몫 — 조각 4.)
--       해제 때 그 사람 brand_accounts.last_brand_id 는 건드리지 않는다(작업 3 의 로그인 판정이 활성 연결로 걸러낸다).
--   [L] get_brand_members: 활성 연결 + 활성 브랜드가 없으면 {result:'not_linked'}(my_brand_role 기준 — 527 의 P-9 와 같다). 대표: {my_role, seat_used, member_limit, rows[]}
--       — 계정 행(대표·멤버, auth_id 포함, last_active_at) + 초대 행(pending → 'pending' / pending+만료 → 'expired' / declined → 'declined'; 취소·수락·숨김 제외;
--       name 은 늘 NULL; auth_id·last_active_at NULL). 🔴 멤버 호출: 계정 행만, **auth_id 키 자체를 뺀다**, last_active_at 포함, 초대 행 0건,
--       seat_used·member_limit 는 대표와 같은 값(사양서 16-7 — 「n / m명」은 멤버에게도 보인다. n 은 대기 초대 포함이라 멤버 화면 줄 수보다 클 수 있다 — 의도).
--       정렬: 대표 → 멤버(연결 생성순) → 초대(발급순).
--   [M] 실행 권한: 부여 먼저(postgres, service_role, 공개 함수는 authenticated) → PUBLIC 회수 → anon(안쪽 전용은 anon·authenticated) 회수 — 530 과 같은 모양(369·370·375).
--
-- 되돌리는 방법  (함수만 추가했으므로 지우면 끝 — 이 파일을 쓰는 작업 3 이후 함수가 있으면 그것을 먼저)
--   DROP FUNCTION IF EXISTS public.get_brand_members(uuid);
--   DROP FUNCTION IF EXISTS public.release_brand_member(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.transfer_brand_ownership(uuid, uuid);
--   DROP FUNCTION IF EXISTS public.hide_brand_invite(uuid);
--   DROP FUNCTION IF EXISTS public.cancel_brand_invite(uuid);
--   DROP FUNCTION IF EXISTS public.resend_brand_invite(uuid);
--   DROP FUNCTION IF EXISTS public.create_brand_invite(uuid, text);
--   DROP FUNCTION IF EXISTS public._brand_transfer_owner(uuid, uuid);
--   DROP FUNCTION IF EXISTS public._brand_contacts_mark_primary(uuid, uuid);
--   DROP FUNCTION IF EXISTS public._brand_invite_reissue(uuid, uuid);
--   DROP FUNCTION IF EXISTS public._brand_invite_result(text, uuid, uuid, boolean);
--   DROP FUNCTION IF EXISTS public._brand_invite_inviter_name(uuid);
--   DROP FUNCTION IF EXISTS public._brand_invite_recipient_info(text);
--   DROP FUNCTION IF EXISTS public._brand_invite_expires_at(timestamptz);
--   DROP FUNCTION IF EXISTS public._brand_caller_link_role(uuid);
--   ⚠️ 이 함수들이 만든 데이터(초대 줄·연결 이력·brands.contacts 의 대표 표시 이동)는 함수를 지워도 남는다.
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   [V1] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--      WHERE n.nspname='public'
--        AND p.proname IN ('create_brand_invite','resend_brand_invite','cancel_brand_invite','hide_brand_invite','transfer_brand_ownership',
--                          'release_brand_member','get_brand_members','_brand_transfer_owner','_brand_contacts_mark_primary','_brand_invite_expires_at',
--                          '_brand_invite_recipient_info','_brand_invite_inviter_name','_brand_invite_reissue','_brand_invite_result','_brand_caller_link_role')
--      ORDER BY 1;
--     기대: 15행 · acl 맨 앞에 `=X/` 없음 · anon_can 전부 false · svc_can 전부 true ·
--           auth_can 은 앞 일곱(create/resend/cancel/hide/transfer/release/get)만 true, 나머지 여덟은 false.
--   [V2] 되돌림 묶음 시험 — 대표/멤버/무관 계정 흉내로 작업표 완료 정의 전 항목. 끝의 RAISE EXCEPTION 이 전부 되돌린다
--     (편집기 자동 커밋 때문에 BEGIN…ROLLBACK 대신 DO 하나로. 시험 이메일은 `.invalid`, 메일은 나가지 않는다. 530 V5·527 V4 와 같은 방식).
--     만료 초대는 issued_at/expires_at 을 과거로 직접 UPDATE 해서 만든다. 이 파일의 함수 일곱 + 안쪽 둘을 모두 1회 이상 호출한다(적용 Success 는 동작 확인이 아니다).
--     DO $$
--     DECLARE
--       b uuid; o uuid := gen_random_uuid(); m uuid := gen_random_uuid(); x uuid := gen_random_uuid(); c uuid := gen_random_uuid();
--       ts1 timestamptz := now() - interval '1 hour'; ts2 timestamptz := now() - interval '2 hours';
--       r jsonb; r1 jsonb; r2 jsonb; r3 jsonb; ia uuid; ib uuid; ic uuid; ir uuid; ir_dec uuid; old_link uuid;
--       v_out text := '';
--     BEGIN
--       INSERT INTO public.brands (name, contacts)
--         VALUES ('zz-531-b', jsonb_build_array(jsonb_build_object('id','k1','name','대표','phone','010','email',' ZZ-531-O@Example.INVALID ','is_primary',true)))
--         RETURNING id INTO b;
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       SELECT '00000000-0000-0000-0000-000000000000'::uuid, t.id,'authenticated','authenticated',t.em,'x',now(),now(),now(),
--              '','','','','','','','','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb,
--              jsonb_build_object('sub',t.id::text,'email',t.em,'email_verified',true,'phone_verified',false)
--         FROM (VALUES (o,'zz-531-o@example.invalid'),(m,'zz-531-m@example.invalid'),(x,'zz-531-x@example.invalid'),(c,'zz-531-c@example.invalid')) AS t(id,em);
--       -- 계정 표: 대표 o · 멤버 m · 이미 브랜드 계정인 외부인 x(ⓑ 갈래). c 는 인증 계정만 있고 브랜드 계정 행이 없다 → _brand_email_owner 가 influencer 로 봄(ⓒ 갈래)
--       INSERT INTO public.brand_accounts (auth_id,email,name,password_set_at)
--         VALUES (o,'zz-531-o@example.invalid','대표O',now()),(m,'zz-531-m@example.invalid','멤버M',now()),(x,'zz-531-x@example.invalid','외부X',now());
--       INSERT INTO public.brand_account_links (auth_id,brand_id,role,last_active_at) VALUES (o,b,'owner',ts2),(m,b,'member',ts1);
--       -- 자리: 대표 1 + 멤버 1 = 2 (상한 5)
--       -- ── 대표 호출 ─────────────────────────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
--       -- T1 ⓐⓑⓒ 세 이메일(ⓑ 는 대소문자·뒤 공백 섞어서) 응답 키 집합 동일 · 모두 ok · 자리 1씩 증가
--       r1 := public.create_brand_invite(b, 'zz-531-a@example.invalid');
--       r2 := public.create_brand_invite(b, ' ZZ-531-X@example.invalid ');
--       r3 := public.create_brand_invite(b, 'zz-531-c@example.invalid');
--       ia := (r1->>'invite_id')::uuid; ib := (r2->>'invite_id')::uuid; ic := (r3->>'invite_id')::uuid;
--       v_out := v_out || '생성=' || (r1->>'result') || '/' || (r2->>'result') || '/' || (r3->>'result')
--                      || ' 자리=' || (r1->>'seat_used') || '/' || (r2->>'seat_used') || '/' || (r3->>'seat_used')
--                      || ' 상한=' || (r3->>'member_limit')
--                      || ' 키수=' || (SELECT count(*) FROM jsonb_object_keys(r1))
--                      || ' 키동일=' || ((SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r1) k) = (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r2) k)
--                                    AND (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r2) k) = (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(r3) k)) || ' ';
--       -- T2 상한 5 에서 다섯째 초대(대표 + 멤버 + 초대 3 = 5) → seat_full
--       r := public.create_brand_invite(b, 'zz-531-d@example.invalid');
--       v_out := v_out || '다섯째=' || (r->>'result') || ' ';
--       -- T3 대기(만료 전) 줄 다시 보내기는 가득 차도 ok
--       v_out := v_out || '대기재발송(가득)=' || (public.resend_brand_invite(ib)->>'result') || ' ';
--       -- T4 만료 줄: 자리 있으면 ok / 없으면 seat_full
--       UPDATE public.brand_invites SET issued_at = now() - interval '48 hours', expires_at = now() - interval '24 hours' WHERE id = ia;
--       r := public.create_brand_invite(b, 'zz-531-d@example.invalid');                       -- 만료 줄은 자리를 안 차지 → 자리 4 → d 가 5번째 자리 ok
--       v_out := v_out || 'd생성=' || (r->>'result') || ' ';
--       v_out := v_out || '만료재발송(가득)=' || (public.resend_brand_invite(ia)->>'result') || ' ';
--       v_out := v_out || 'd취소=' || public.cancel_brand_invite((r->>'invite_id')::uuid) || ' ';
--       v_out := v_out || '만료재발송(자리있음)=' || (public.resend_brand_invite(ia)->>'result') || ' ';
--       -- T5 만료 줄 cancel → not_pending · hide(만료) → ok · hide(대기) → not_hideable · 숨긴 줄은 목록에 없음
--       UPDATE public.brand_invites SET issued_at = now() - interval '48 hours', expires_at = now() - interval '24 hours' WHERE id = ic;
--       v_out := v_out || '만료취소=' || public.cancel_brand_invite(ic) || ' 만료삭제=' || public.hide_brand_invite(ic) || ' 대기삭제=' || public.hide_brand_invite(ib) || ' ';
--       r := public.get_brand_members(b);
--       v_out := v_out || '목록=' || jsonb_array_length(r->'rows') || ' ';
--       -- T6 만료 + 삭제해 둔 같은 이메일을 다시 초대 → 같은 줄을 되살림(owner_hidden_at 비움)
--       r := public.create_brand_invite(b, 'zz-531-c@example.invalid');
--       v_out := v_out || '되살림=' || (r->>'result') || '/같은줄=' || ((r->>'invite_id')::uuid = ic)
--                      || '/숨김해제=' || (SELECT owner_hidden_at IS NULL FROM public.brand_invites WHERE id = ic) || '/자리=' || (r->>'seat_used') || ' ';
--       -- T7 발송 기록 있는 대기 줄 → already_pending · 발송 기록 없는 대기 줄 → 멱등(같은 줄·링크 새로)
--       UPDATE public.brand_invites SET mail_sent_link_id = link_id, mail_sent_at = now() WHERE id = ib;
--       r := public.create_brand_invite(b, 'zz-531-x@example.invalid');
--       v_out := v_out || '이미대기=' || (r->>'result') || ' ';
--       SELECT link_id INTO old_link FROM public.brand_invites WHERE id = ib;
--       UPDATE public.brand_invites SET mail_sent_link_id = NULL, mail_sent_at = NULL WHERE id = ib;
--       r := public.create_brand_invite(b, 'zz-531-x@example.invalid');
--       v_out := v_out || '멱등=' || (r->>'result') || '/같은줄=' || ((r->>'invite_id')::uuid = ib)
--                      || '/링크바뀜=' || ((SELECT link_id FROM public.brand_invites WHERE id = ib) <> old_link) || ' ';
--       -- T8 거절 줄은 재사용하지 않고 새 줄: c 를 취소해 자리를 비운 뒤 거절 줄이 있는 r 이메일 초대
--       v_out := v_out || 'c취소=' || public.cancel_brand_invite(ic) || ' ';
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at,declined_at)
--         VALUES (b,'zz-531-r@example.invalid',o,'대표O','declined','new',now() - interval '2 hours',now() + interval '22 hours',now()) RETURNING id INTO ir_dec;
--       r := public.create_brand_invite(b, 'zz-531-r@example.invalid');
--       ir := (r->>'invite_id')::uuid;
--       v_out := v_out || '거절후새줄=' || (r->>'result') || '/새줄=' || (ir <> ir_dec)
--                      || '/r줄수=' || (SELECT count(*) FROM public.brand_invites WHERE brand_id = b AND email = 'zz-531-r@example.invalid') || ' ';
--       -- T9 대표 목록: 계정 2 + 초대(a·b·r 대기 + r 거절) 4 = 6 / 초대 행 name 전부 NULL / 상태 expired 계산
--       r := public.get_brand_members(b);
--       v_out := v_out || '대표목록=' || jsonb_array_length(r->'rows') || '/역할=' || (r->>'my_role') || '/자리=' || (r->>'seat_used') || '/' || (r->>'member_limit')
--                      || '/초대name모두NULL=' || (SELECT bool_and(jsonb_typeof(e->'name') = 'null') FROM jsonb_array_elements(r->'rows') e WHERE e->>'kind' = 'invite')
--                      || '/거절행=' || (SELECT count(*) FROM jsonb_array_elements(r->'rows') e WHERE e->>'status' = 'declined') || ' ';
--       UPDATE public.brand_invites SET issued_at = now() - interval '48 hours', expires_at = now() - interval '24 hours' WHERE id = ia;
--       v_out := v_out || 'expired행=' || (SELECT count(*) FROM jsonb_array_elements(public.get_brand_members(b)->'rows') e WHERE e->>'status' = 'expired') || ' ';
--       UPDATE public.brand_invites SET expires_at = now() + interval '24 hours', issued_at = now() WHERE id = ia;   -- 시험 편의: 다시 대기로
--       -- T10 입력 오류
--       v_out := v_out || '본인=' || (public.create_brand_invite(b, 'ZZ-531-O@example.invalid')->>'result')
--                      || ' 이미멤버=' || (public.create_brand_invite(b, 'zz-531-m@example.invalid')->>'result')
--                      || ' 형식=' || (public.create_brand_invite(b, 'abc')->>'result') || ' ';
--       -- ── 멤버 호출 ─────────────────────────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
--       r := public.get_brand_members(b);
--       v_out := v_out || '멤버:초대=' || (public.create_brand_invite(b, 'zz-531-q@example.invalid')->>'result')
--                      || '/재발송=' || (public.resend_brand_invite(ia)->>'result') || '/취소=' || public.cancel_brand_invite(ia) || '/삭제=' || public.hide_brand_invite(ia)
--                      || '/넘기기=' || public.transfer_brand_ownership(b, o) || '/해제=' || public.release_brand_member(b, o)
--                      || ' 목록=' || jsonb_array_length(r->'rows') || '/초대행=' || (SELECT count(*) FROM jsonb_array_elements(r->'rows') e WHERE e->>'kind' = 'invite')
--                      || '/auth_id키=' || (SELECT bool_or(e ? 'auth_id') FROM jsonb_array_elements(r->'rows') e)
--                      || '/last_active키=' || (SELECT bool_and(e ? 'last_active_at') FROM jsonb_array_elements(r->'rows') e)
--                      || '/역할=' || (r->>'my_role') || '/자리=' || (r->>'seat_used') || '/' || (r->>'member_limit') || ' ';
--       -- ── 무관 계정 호출 ────────────────────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
--       v_out := v_out || '무관:재발송=' || (public.resend_brand_invite(ia)->>'result') || '/없는줄=' || (public.resend_brand_invite(gen_random_uuid())->>'result')
--                      || '/취소=' || public.cancel_brand_invite(ia) || '/목록=' || (public.get_brand_members(b)->>'result') || ' ';
--       -- ── 대표 넘기기 (m 으로) ──────────────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
--       v_out := v_out || '넘기기:무관에게=' || public.transfer_brand_ownership(b, x) || '/본인에게=' || public.transfer_brand_ownership(b, o);
--       v_out := v_out || '/m에게=' || public.transfer_brand_ownership(b, m) || ' ';
--       v_out := v_out || '넘긴뒤:m=' || (SELECT role FROM public.brand_account_links WHERE auth_id = m AND brand_id = b AND status = 'active')
--                      || ' o=' || (SELECT role FROM public.brand_account_links WHERE auth_id = o AND brand_id = b AND status = 'active')
--                      || ' 활성대표수=' || (SELECT count(*) FROM public.brand_account_links WHERE brand_id = b AND role = 'owner' AND status = 'active')
--                      || ' 활동일보존=' || ((SELECT last_active_at FROM public.brand_account_links WHERE auth_id = m AND brand_id = b AND status = 'active') = ts1
--                                         AND (SELECT last_active_at FROM public.brand_account_links WHERE auth_id = o AND brand_id = b AND status = 'active') = ts2)
--                      || ' 담당자=' || (SELECT jsonb_array_length(contacts) FROM public.brands WHERE id = b)
--                      || '줄/표시=' || (SELECT e->>'email' FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b AND e->>'is_primary' = 'true')
--                      || '/표시수=' || (SELECT count(*) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b AND e->>'is_primary' = 'true')
--                      || '/옛줄표시=' || (SELECT e->>'is_primary' FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b AND e->>'id' = 'k1') || ' ';
--       v_out := v_out || '옛대표:초대=' || (public.create_brand_invite(b, 'zz-531-q@example.invalid')->>'result') || ' ';
--       -- ── 새 대표(m)가 다시 o 에게 넘김 → 목록에 있는 이메일(대소문자·공백 달라도)에 표시가 돌아감, 줄은 늘지 않음 ──
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
--       -- ⚠️ 함수 호출과 확인 조회를 한 문장에 두지 않는다 — 같은 문장 안의 조회는 문장 시작 시점의 데이터를 봐서 호출 결과가 안 보인다
--       v_out := v_out || '되넘기기=' || public.transfer_brand_ownership(b, o);
--       v_out := v_out || ' 담당자=' || (SELECT jsonb_array_length(contacts) FROM public.brands WHERE id = b)
--                      || '줄/표시=' || (SELECT lower(btrim(e->>'email')) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b AND e->>'is_primary' = 'true')
--                      || '/표시수=' || (SELECT count(*) FROM public.brands, jsonb_array_elements(contacts) e WHERE id = b AND e->>'is_primary' = 'true') || ' ';
--       -- ── 멤버 해제 (대표 o 가) ─────────────────────────────────
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
--       v_out := v_out || '해제:m=' || public.release_brand_member(b, m) || ' 다시=' || public.release_brand_member(b, m)
--                      || ' 본인=' || public.release_brand_member(b, o) || ' 무관=' || public.release_brand_member(b, x);
--       v_out := v_out || ' m연결이력=' || (SELECT count(*) FROM public.brand_account_links WHERE auth_id = m AND brand_id = b)
--                      || '/활성=' || (SELECT count(*) FROM public.brand_account_links WHERE auth_id = m AND brand_id = b AND status = 'active') || ' ';
--       -- ── 브랜드 보관 → 대표도 막힘 ─────────────────────────────
--       UPDATE public.brands SET status = 'archived' WHERE id = b;
--       v_out := v_out || '보관:초대=' || (public.create_brand_invite(b, 'zz-531-q@example.invalid')->>'result')
--                      || '/재발송=' || (public.resend_brand_invite(ia)->>'result') || '/목록=' || (public.get_brand_members(b)->>'result') || ' ';
--       RAISE EXCEPTION '531 시험 결과(전부 되돌림): %', v_out;
--     END $$;
--     기대(의도된 예외 한 줄 — 줄바꿈 없이 이어진 한 줄이다. 아래는 읽기 쉽게 끊었다):
--       「생성=ok/ok/ok 자리=3/4/5 상한=5 키수=4 키동일=true 다섯째=seat_full 대기재발송(가득)=ok
--         d생성=ok 만료재발송(가득)=seat_full d취소=ok 만료재발송(자리있음)=ok
--         만료취소=not_pending 만료삭제=ok 대기삭제=not_hideable 목록=4
--         되살림=ok/같은줄=true/숨김해제=true/자리=5 이미대기=already_pending 멱등=ok/같은줄=true/링크바뀜=true
--         c취소=ok 거절후새줄=ok/새줄=true/r줄수=2
--         대표목록=6/역할=owner/자리=5/5/초대name모두NULL=true/거절행=1 expired행=1
--         본인=self_email 이미멤버=already_member 형식=invalid_email
--         멤버:초대=not_owner/재발송=not_owner/취소=not_owner/삭제=not_owner/넘기기=not_owner/해제=not_owner 목록=2/초대행=0/auth_id키=false/last_active키=true/역할=member/자리=5/5
--         무관:재발송=not_found/없는줄=not_found/취소=not_owner/목록=not_linked
--         넘기기:무관에게=not_member/본인에게=not_member/m에게=ok
--         넘긴뒤:m=owner o=member 활성대표수=1 활동일보존=true 담당자=2줄/표시=zz-531-m@example.invalid/표시수=1/옛줄표시=false
--         옛대표:초대=not_owner
--         되넘기기=ok 담당자=2줄/표시=zz-531-o@example.invalid/표시수=1
--         해제:m=ok 다시=not_member 본인=not_member 무관=not_member m연결이력=3/활성=0
--         보관:초대=brand_inactive/재발송=not_owner/목록=not_linked」
--       ⚠️ T9 의 자리=5/5 는 그 시점 계정 2 + 대기 초대 3(a·b·r)이라 5 / 상한 5. 만료 줄 a 를 일부러 되살리는 UPDATE 는 시험 편의다.
--       ⚠️ 한 군데라도 다르면 멈추고 알릴 것(남은 단계를 계속 쏟지 말 것).
--     그다음 따로(시험 뒤 잔여 확인 — 전부 0 이어야 한다. 0 이 아니면 멈추고 알릴 것):
--       SELECT (SELECT count(*) FROM auth.users WHERE email LIKE 'zz-531-%') AS users,
--              (SELECT count(*) FROM public.brands WHERE name = 'zz-531-b') AS brands,
--              (SELECT count(*) FROM public.brand_invites WHERE email LIKE 'zz-531-%') AS invites,
--              (SELECT count(*) FROM public.brand_accounts WHERE email LIKE 'zz-531-%') AS accounts;
--     ⚠️ 로그인 흉내(set_config)는 auth.uid() 를 바꿀 뿐이다. 실제 로그인한 브라우저 세션에서의 호출은 묶음 ②(화면) 때 따로 확인한다.
-- ============================================================

BEGIN;

-- ── 1. 안쪽 도우미 ───────────────────────────────────────────

-- 1-1. 만료 식 — 「issued_at + 24시간」은 여기 한 곳(머리말 [B])
CREATE OR REPLACE FUNCTION public._brand_invite_expires_at(p_issued_at timestamptz)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT p_issued_at + interval '24 hours';
$$;

COMMENT ON FUNCTION public._brand_invite_expires_at(timestamptz) IS '[531] 내부 도우미. 초대 만료 시각 = 발급 시각 + 24시간. 이 식의 유일한 사본 — create·resend 가 함께 쓴다. 호출 불가(안쪽 전용).';

-- 1-2. 지금 로그인 사용자의 이 브랜드 활성 연결 역할(브랜드 활성 여부는 보지 않는다 — 호출하는 쪽이 따로 본다)
CREATE OR REPLACE FUNCTION public._brand_caller_link_role(p_brand_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT l.role
    FROM public.brand_account_links l
   WHERE l.auth_id = (SELECT auth.uid())
     AND l.brand_id = p_brand_id
     AND l.status = 'active'
   LIMIT 1;
$$;

COMMENT ON FUNCTION public._brand_caller_link_role(uuid) IS '[531] 내부 도우미. 로그인 사용자의 이 브랜드 활성 연결 역할(owner/member/NULL). 브랜드 활성 여부는 안 본다. 호출 불가(안쪽 전용).';

-- 1-3. 보낼 때 갈래 — 527 _brand_email_owner 결과를 new/brand/blocked 로 환산(530 [G] 와 같은 대응표)
CREATE OR REPLACE FUNCTION public._brand_invite_recipient_info(p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_owner jsonb := public._brand_email_owner(p_email, NULL);
  v_kind  text  := v_owner->>'kind';
BEGIN
  RETURN jsonb_build_object(
    'recipient_kind',     CASE v_kind WHEN 'none' THEN 'new' WHEN 'brand' THEN 'brand' ELSE 'blocked' END,
    'sent_owner_auth_id', CASE WHEN v_kind = 'brand' THEN v_owner->>'auth_id' ELSE NULL END
  );
END;
$$;

COMMENT ON FUNCTION public._brand_invite_recipient_info(text) IS '[531] 내부 도우미. 이메일의 보낼 때 갈래 {recipient_kind: new|brand|blocked, sent_owner_auth_id: ⓑ 일 때 그 계정}. 호출 불가(안쪽 전용).';

-- 1-4. 보낸 사람 이름 스냅샷 — brand_accounts.name, 비었으면 이메일
CREATE OR REPLACE FUNCTION public._brand_invite_inviter_name(p_auth_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email)
    FROM public.brand_accounts a
   WHERE a.auth_id = p_auth_id;
$$;

COMMENT ON FUNCTION public._brand_invite_inviter_name(uuid) IS '[531] 내부 도우미. 초대 줄의 inviter_name 스냅샷 = brand_accounts.name (비었으면 이메일). 호출 불가(안쪽 전용).';

-- 1-5. 줄 다시 보내기 — 새 링크·시각·갈래·보낸 사람, 발송 기록 비움, 삭제 표시 비움 (create·resend 공용)
CREATE OR REPLACE FUNCTION public._brand_invite_reissue(p_invite_id uuid, p_inviter uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_email text;
  v_info  jsonb;
BEGIN
  SELECT i.email INTO v_email FROM public.brand_invites i WHERE i.id = p_invite_id;
  v_info := public._brand_invite_recipient_info(v_email);

  UPDATE public.brand_invites
     SET link_id            = gen_random_uuid(),
         issued_at          = now(),
         expires_at         = public._brand_invite_expires_at(now()),
         recipient_kind     = v_info->>'recipient_kind',
         sent_owner_auth_id = NULLIF(v_info->>'sent_owner_auth_id', '')::uuid,
         mail_sent_at       = NULL,
         mail_sent_link_id  = NULL,
         invited_by         = p_inviter,
         inviter_name       = public._brand_invite_inviter_name(p_inviter),
         owner_hidden_at    = NULL
   WHERE id = p_invite_id;
END;
$$;

COMMENT ON FUNCTION public._brand_invite_reissue(uuid, uuid) IS '[531] 내부 도우미. 대기 초대 줄을 다시 보낼 상태로: 새 link_id·issued_at·expires_at·갈래 재판정·mail_sent_* 비움·보낸 사람 갱신·owner_hidden_at 비움. 호출하는 쪽이 브랜드·이메일 잠금 안에서 부른다. 호출 불가(안쪽 전용).';

-- 1-6. create 응답 모양 — 어느 결과든 키 집합이 같다(머리말 [D])
CREATE OR REPLACE FUNCTION public._brand_invite_result(p_result text, p_invite_id uuid, p_brand_id uuid, p_with_seat boolean)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'result',       p_result,
    'invite_id',    p_invite_id,
    'seat_used',    CASE WHEN p_with_seat THEN public._brand_seat_usage(p_brand_id) ELSE NULL END,
    'member_limit', CASE WHEN p_with_seat THEN public._brand_member_limit(p_brand_id) ELSE NULL END
  );
$$;

COMMENT ON FUNCTION public._brand_invite_result(text, uuid, uuid, boolean) IS '[531] 내부 도우미. create·resend 응답 {result, invite_id, seat_used, member_limit} — 키 집합은 늘 같다(p_with_seat=false 면 자리 수 NULL). 호출 불가(안쪽 전용).';

-- ── 2. 담당자 목록 대표 표시 이동 ─────────────────────────────

CREATE OR REPLACE FUNCTION public._brand_contacts_mark_primary(p_brand_id uuid, p_auth_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_acct     public.brand_accounts%ROWTYPE;
  v_contacts jsonb;
  v_email    text;
  v_idx      integer := NULL;   -- 0 부터 시작하는 일치 줄 위치
  v_new      jsonb;
BEGIN
  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = p_auth_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT COALESCE(b.contacts, '[]'::jsonb) INTO v_contacts FROM public.brands b WHERE b.id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN RETURN; END IF;
  IF jsonb_typeof(v_contacts) <> 'array' THEN v_contacts := '[]'::jsonb; END IF;

  v_email := lower(btrim(v_acct.email));

  -- 같은 사람 = 이메일(앞뒤 공백·대소문자 무시) 일치 — 첫 일치 줄
  SELECT (e.ord - 1)::int INTO v_idx
    FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
   WHERE lower(btrim(COALESCE(e.elem->>'email', ''))) = v_email
   ORDER BY e.ord
   LIMIT 1;

  -- 모든 줄의 대표 표시를 먼저 뗀다(줄은 지우지 않는다)
  SELECT COALESCE(jsonb_agg(
           CASE WHEN jsonb_typeof(e.elem) = 'object' THEN e.elem || jsonb_build_object('is_primary', false) ELSE e.elem END
           ORDER BY e.ord), '[]'::jsonb)
    INTO v_contacts
    FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord);

  IF v_idx IS NOT NULL THEN
    v_contacts := jsonb_set(v_contacts, ARRAY[v_idx::text, 'is_primary'], 'true'::jsonb);
  ELSE
    v_new := jsonb_build_object(
      'id',         gen_random_uuid()::text,
      'name',       COALESCE(v_acct.name, ''),
      'phone',      COALESCE(v_acct.phone, ''),
      'email',      v_acct.email,
      'is_primary', true
    );
    v_contacts := v_contacts || jsonb_build_array(v_new);
  END IF;

  UPDATE public.brands SET contacts = v_contacts WHERE id = p_brand_id;
END;
$$;

COMMENT ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid) IS
  '[531] 내부 도우미. brands.contacts 의 대표 표시(is_primary)를 이 계정으로 옮긴다 — 이메일(lower(btrim()))로 같은 사람 판정, 없으면 계정의 이름·이메일·연락처로 줄을 한 번 더한다. 옛 줄은 표시만 뗀다. 메일 없음. 대표 판정은 호출하는 쪽 몫. 호출 불가(안쪽 전용).
   ⚠️ 서버가 brands.contacts 를 고치는 첫 경로 — 관리자 편집 폼이 옛 배열을 통째로 저장하면 되돌아간다(묶음 ③ 전까지).';

-- ── 3. 대표 전환 본체 ─────────────────────────────────────────

CREATE OR REPLACE FUNCTION public._brand_transfer_owner(p_brand_id uuid, p_new_owner_auth_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_old public.brand_account_links%ROWTYPE;
  v_new public.brand_account_links%ROWTYPE;
BEGIN
  -- 같은 트랜잭션에서 이미 잡았으면 재진입(호출하는 쪽이 잡아도 안전)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT l.* INTO v_new
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.auth_id = p_new_owner_auth_id AND l.status = 'active'
   FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_member'; END IF;
  IF v_new.role = 'owner' THEN RETURN 'ok'; END IF;     -- 이미 대표 — 바꿀 것 없음

  SELECT l.* INTO v_old
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active'
   FOR UPDATE;

  -- 해제를 먼저(브랜드당 활성 대표 1명 · (계정,브랜드) 활성 1개 부분 유일 색인)
  UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_new.id;
  IF v_old.id IS NOT NULL THEN
    UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_old.id;
  END IF;

  -- 새 연결 — 각자 옛 연결의 last_active_at·source_contact_id 를 이어받는다
  INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id, last_active_at)
  VALUES (v_new.auth_id, p_brand_id, 'owner', 'active', v_new.source_contact_id, v_new.last_active_at);
  IF v_old.id IS NOT NULL THEN
    INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, source_contact_id, last_active_at)
    VALUES (v_old.auth_id, p_brand_id, 'member', 'active', v_old.source_contact_id, v_old.last_active_at);
  END IF;

  PERFORM public._brand_contacts_mark_primary(p_brand_id, p_new_owner_auth_id);
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public._brand_transfer_owner(uuid, uuid) IS
  '[531] 내부 도우미. 활성 멤버를 대표로 올리고 옛 대표는 멤버로 내린다(역할을 덮어쓰지 않고 해제+새 연결 — 이력). 두 사람의 last_active_at 은 새 연결로 옮긴다. 담당자 목록 대표 표시도 이동(메일 없음).
   반환 ok / not_member(새 사람이 활성 연결 아님). 대표 판정은 호출하는 쪽 몫 — transfer_brand_ownership(대표 판정 뒤)·조각 4 admin_change_brand_owner(권한 판정 뒤)가 부른다. 호출 불가(안쪽 전용).';

-- ── 4. 로그인 사용자 함수 ─────────────────────────────────────

-- 4-1. create_brand_invite
CREATE OR REPLACE FUNCTION public.create_brand_invite(p_brand_id uuid, p_email text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_status text;
  v_email  text;
  v_inv    public.brand_invites%ROWTYPE;
  v_info   jsonb;
  v_now    timestamptz := now();
  v_new_id uuid;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;

  -- 브랜드 잠금 → 대표·브랜드 활성 다시 판정
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));
  IF public._brand_caller_link_role(p_brand_id) IS DISTINCT FROM 'owner' THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN
    RETURN public._brand_invite_result('brand_inactive', NULL, NULL, false);
  END IF;

  -- 이메일 정규화·형식
  v_email := lower(btrim(COALESCE(p_email, '')));
  IF length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' THEN
    RETURN public._brand_invite_result('invalid_email', NULL, p_brand_id, true);
  END IF;

  -- 이메일 잠금(브랜드 → 이메일 순서 — 527 과 같다)
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_email));

  -- 본인 이메일
  IF EXISTS (SELECT 1 FROM public.brand_accounts a WHERE a.auth_id = v_uid AND lower(btrim(a.email)) = v_email) THEN
    RETURN public._brand_invite_result('self_email', NULL, p_brand_id, true);
  END IF;

  -- 이미 이 브랜드의 활성 연결(대표·멤버)
  IF EXISTS (SELECT 1
               FROM public.brand_account_links l
               JOIN public.brand_accounts a ON a.auth_id = l.auth_id
              WHERE l.brand_id = p_brand_id AND l.status = 'active' AND lower(btrim(a.email)) = v_email) THEN
    RETURN public._brand_invite_result('already_member', NULL, p_brand_id, true);
  END IF;

  -- 같은 이메일의 대기 초대
  SELECT i.* INTO v_inv
    FROM public.brand_invites i
   WHERE i.brand_id = p_brand_id AND i.email = v_email AND i.status = 'pending'
   FOR UPDATE;
  IF FOUND THEN
    IF v_inv.expires_at <= v_now THEN
      -- 만료 줄 → 그 줄 다시 보내기(자리 검사 포함 — 만료 줄은 자리를 안 차지한다)
      IF public._brand_seat_usage(p_brand_id) >= public._brand_member_limit(p_brand_id) THEN
        RETURN public._brand_invite_result('seat_full', NULL, p_brand_id, true);
      END IF;
      PERFORM public._brand_invite_reissue(v_inv.id, v_uid);
      RETURN public._brand_invite_result('ok', v_inv.id, p_brand_id, true);
    ELSIF v_inv.mail_sent_link_id IS DISTINCT FROM v_inv.link_id THEN
      -- 만료 전 + 지금 링크로 발송 기록 없음 → 멱등 재시도(자리 검사 없음 — 이미 자리를 차지한 줄)
      PERFORM public._brand_invite_reissue(v_inv.id, v_uid);
      RETURN public._brand_invite_result('ok', v_inv.id, p_brand_id, true);
    ELSE
      RETURN public._brand_invite_result('already_pending', v_inv.id, p_brand_id, true);
    END IF;
  END IF;

  -- 새 줄 (거절·취소·수락된 줄은 재사용하지 않는다)
  IF public._brand_seat_usage(p_brand_id) >= public._brand_member_limit(p_brand_id) THEN
    RETURN public._brand_invite_result('seat_full', NULL, p_brand_id, true);
  END IF;

  v_info := public._brand_invite_recipient_info(v_email);
  INSERT INTO public.brand_invites
    (brand_id, email, invited_by, inviter_name, status, recipient_kind, sent_owner_auth_id, issued_at, expires_at)
  VALUES
    (p_brand_id, v_email, v_uid, public._brand_invite_inviter_name(v_uid), 'pending',
     v_info->>'recipient_kind', NULLIF(v_info->>'sent_owner_auth_id', '')::uuid, v_now, public._brand_invite_expires_at(v_now))
  RETURNING id INTO v_new_id;

  RETURN public._brand_invite_result('ok', v_new_id, p_brand_id, true);
END;
$$;

COMMENT ON FUNCTION public.create_brand_invite(uuid, text) IS
  '[531] 대표가 멤버 초대를 만든다. 결과 ok/not_owner/brand_inactive/invalid_email/self_email/already_member/already_pending/seat_full. 응답 키 {result, invite_id, seat_used, member_limit} 는 늘 같고 갈래(ⓐⓑⓒ)를 짐작할 값이 없다. 만료 줄·발송 기록 없는 대기 줄은 같은 줄을 다시 보낸다(머리말 [F]). authenticated 전용.';

-- 4-2. resend_brand_invite
CREATE OR REPLACE FUNCTION public.resend_brand_invite(p_invite_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_role     text;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  -- 브랜드를 알기 위해 잠금 전에 한 번 읽는다
  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  -- 잠금 안에서 줄·역할을 다시 읽는다
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND OR v_inv.brand_id <> v_brand_id THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);
  END IF;

  v_role := public._brand_caller_link_role(v_brand_id);
  IF v_role IS NULL THEN
    RETURN public._brand_invite_result('not_found', NULL, NULL, false);      -- 남의 브랜드 — 존재 비노출(머리말 [E])
  END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_role <> 'owner' OR v_status IS DISTINCT FROM 'active' THEN
    RETURN public._brand_invite_result('not_owner', NULL, NULL, false);
  END IF;

  IF v_inv.status <> 'pending' THEN
    RETURN public._brand_invite_result('not_resendable', p_invite_id, v_brand_id, true);
  END IF;

  -- 이메일 잠금(갈래를 다시 판정하므로) — 브랜드 → 이메일 순서
  PERFORM pg_advisory_xact_lock(hashtext('brand_account_email:' || v_inv.email));

  -- 만료 줄만 자리 검사(만료 전 대기 줄은 이미 자리를 차지 — 가득 차도 ok)
  IF v_inv.expires_at <= now()
     AND public._brand_seat_usage(v_brand_id) >= public._brand_member_limit(v_brand_id) THEN
    RETURN public._brand_invite_result('seat_full', p_invite_id, v_brand_id, true);
  END IF;

  PERFORM public._brand_invite_reissue(p_invite_id, v_uid);
  RETURN public._brand_invite_result('ok', p_invite_id, v_brand_id, true);
END;
$$;

COMMENT ON FUNCTION public.resend_brand_invite(uuid) IS
  '[531] 대표가 초대를 다시 보낸다 — 새 링크·시각·갈래, 발송 기록 비움, 보낸 사람을 지금 대표로. 결과 ok/not_owner/not_found/not_resendable/seat_full(만료 줄만). 남의 브랜드·없는 줄은 똑같이 not_found. authenticated 전용.';

-- 4-3. cancel_brand_invite
CREATE OR REPLACE FUNCTION public.cancel_brand_invite(p_invite_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN RETURN 'not_owner'; END IF;

  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN RETURN 'not_owner'; END IF;          -- 줄이 없든 남의 것이든 같은 값(머리말 [E])

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_owner'; END IF;
  IF public._brand_caller_link_role(v_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 대기이고 만료 전인 줄만 — 만료 줄(저장 상태는 pending)도 거부(다시 보내기·삭제만)
  IF v_inv.status <> 'pending' OR v_inv.expires_at <= now() THEN RETURN 'not_pending'; END IF;

  UPDATE public.brand_invites SET status = 'cancelled', cancelled_at = now() WHERE id = p_invite_id;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.cancel_brand_invite(uuid) IS '[531] 대표가 대기 초대(만료 전)를 취소한다. 결과 ok/not_owner(없는 줄·남의 줄 포함)/not_pending(만료·거절·취소·수락). authenticated 전용.';

-- 4-4. hide_brand_invite
CREATE OR REPLACE FUNCTION public.hide_brand_invite(p_invite_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid      uuid := (SELECT auth.uid());
  v_brand_id uuid;
  v_inv      public.brand_invites%ROWTYPE;
  v_status   text;
BEGIN
  IF v_uid IS NULL OR p_invite_id IS NULL THEN RETURN 'not_owner'; END IF;

  SELECT i.brand_id INTO v_brand_id FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF v_brand_id IS NULL THEN RETURN 'not_owner'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || v_brand_id::text));

  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id FOR UPDATE;
  IF NOT FOUND THEN RETURN 'not_owner'; END IF;
  IF public._brand_caller_link_role(v_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = v_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 만료(대기 + 기한 지남)·거절만 「삭제」
  IF NOT (v_inv.status = 'declined' OR (v_inv.status = 'pending' AND v_inv.expires_at <= now())) THEN
    RETURN 'not_hideable';
  END IF;

  UPDATE public.brand_invites SET owner_hidden_at = COALESCE(owner_hidden_at, now()) WHERE id = p_invite_id;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.hide_brand_invite(uuid) IS '[531] 대표가 만료·거절 초대 줄을 목록에서 지운다(owner_hidden_at). 결과 ok/not_owner(없는 줄·남의 줄 포함)/not_hideable. 만료 줄에 같은 이메일을 다시 초대하면 되살아난다. authenticated 전용.';

-- 4-5. transfer_brand_ownership
CREATE OR REPLACE FUNCTION public.transfer_brand_ownership(p_brand_id uuid, p_new_owner_auth_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_status text;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL THEN RETURN 'not_owner'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));
  IF public._brand_caller_link_role(p_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 새 대표는 이 브랜드의 활성 **멤버**여야 한다(본인·무관한 계정·이미 해제된 사람은 not_member)
  IF p_new_owner_auth_id IS NULL OR p_new_owner_auth_id = v_uid
     OR NOT EXISTS (SELECT 1 FROM public.brand_account_links l
                     WHERE l.brand_id = p_brand_id AND l.auth_id = p_new_owner_auth_id
                       AND l.role = 'member' AND l.status = 'active') THEN
    RETURN 'not_member';
  END IF;

  RETURN public._brand_transfer_owner(p_brand_id, p_new_owner_auth_id);
END;
$$;

COMMENT ON FUNCTION public.transfer_brand_ownership(uuid, uuid) IS '[531] 대표가 활성 멤버 한 명에게 대표를 넘긴다(옛 대표는 멤버로). 결과 ok/not_owner/not_member. 담당자 목록 대표 표시도 따라 이동, 메일 없음. 본체는 _brand_transfer_owner. authenticated 전용.';

-- 4-6. release_brand_member
CREATE OR REPLACE FUNCTION public.release_brand_member(p_brand_id uuid, p_auth_id uuid)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_status text;
  v_link   uuid;
BEGIN
  IF v_uid IS NULL OR p_brand_id IS NULL THEN RETURN 'not_owner'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));
  IF public._brand_caller_link_role(p_brand_id) IS DISTINCT FROM 'owner' THEN RETURN 'not_owner'; END IF;
  SELECT b.status INTO v_status FROM public.brands b WHERE b.id = p_brand_id;
  IF v_status IS DISTINCT FROM 'active' THEN RETURN 'not_owner'; END IF;

  -- 활성 멤버만 — 대표·본인·이미 해제된 사람·연결 없는 사람은 not_member
  IF p_auth_id IS NULL OR p_auth_id = v_uid THEN RETURN 'not_member'; END IF;
  SELECT l.id INTO v_link
    FROM public.brand_account_links l
   WHERE l.brand_id = p_brand_id AND l.auth_id = p_auth_id AND l.role = 'member' AND l.status = 'active'
   FOR UPDATE;
  IF v_link IS NULL THEN RETURN 'not_member'; END IF;

  UPDATE public.brand_account_links SET status = 'released', released_at = now() WHERE id = v_link;
  RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION public.release_brand_member(uuid, uuid) IS '[531] 대표가 활성 멤버 한 명을 이 브랜드에서 해제한다(연결 이력은 남김). 결과 ok/not_owner/not_member(대표·본인·해제된 사람·무관한 계정). 대표 해제는 관리자 몫. authenticated 전용.';

-- 4-7. get_brand_members
CREATE OR REPLACE FUNCTION public.get_brand_members(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_rows jsonb;
BEGIN
  -- 활성 연결 + 활성 브랜드가 없으면 not_linked
  v_role := public.my_brand_role(p_brand_id);
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'not_linked');
  END IF;

  IF v_role = 'owner' THEN
    SELECT COALESCE(jsonb_agg(t.j ORDER BY t.grp, t.ord), '[]'::jsonb) INTO v_rows
      FROM (
        -- 계정 행: 대표(grp 0) → 멤버(grp 1, 연결 생성순)
        SELECT CASE l.role WHEN 'owner' THEN 0 ELSE 1 END AS grp, l.created_at AS ord,
               jsonb_build_object(
                 'kind', 'account', 'auth_id', l.auth_id, 'invite_id', NULL, 'name', a.name, 'email', a.email,
                 'role', l.role, 'status', 'active', 'issued_at', NULL, 'expires_at', NULL, 'declined_at', NULL,
                 'last_active_at', l.last_active_at) AS j
          FROM public.brand_account_links l
          JOIN public.brand_accounts a ON a.auth_id = l.auth_id
         WHERE l.brand_id = p_brand_id AND l.status = 'active'
        UNION ALL
        -- 초대 행(grp 2, 발급순): 대기·거절만, 취소·수락·숨김 제외. name 은 늘 NULL(겹침 비노출)
        SELECT 2 AS grp, i.issued_at AS ord,
               jsonb_build_object(
                 'kind', 'invite', 'auth_id', NULL, 'invite_id', i.id, 'name', NULL, 'email', i.email,
                 'role', 'member',
                 'status', CASE WHEN i.status = 'declined' THEN 'declined'
                                WHEN i.expires_at > now() THEN 'pending' ELSE 'expired' END,
                 'issued_at', i.issued_at, 'expires_at', i.expires_at, 'declined_at', i.declined_at,
                 'last_active_at', NULL) AS j
          FROM public.brand_invites i
         WHERE i.brand_id = p_brand_id AND i.status IN ('pending', 'declined') AND i.owner_hidden_at IS NULL
      ) t;

    RETURN jsonb_build_object(
      'my_role',      v_role,
      'seat_used',    public._brand_seat_usage(p_brand_id),
      'member_limit', public._brand_member_limit(p_brand_id),
      'rows',         v_rows
    );
  END IF;

  -- 멤버 호출: 계정 행만 · auth_id 키 자체를 뺀다 · last_active_at 은 준다 · 자리 수는 대표와 같은 값(머리말 [L], 사양서 16-7)
  SELECT COALESCE(jsonb_agg(t.j ORDER BY t.grp, t.ord), '[]'::jsonb) INTO v_rows
    FROM (
      SELECT CASE l.role WHEN 'owner' THEN 0 ELSE 1 END AS grp, l.created_at AS ord,
             jsonb_build_object(
               'kind', 'account', 'invite_id', NULL, 'name', a.name, 'email', a.email,
               'role', l.role, 'status', 'active', 'issued_at', NULL, 'expires_at', NULL, 'declined_at', NULL,
               'last_active_at', l.last_active_at) AS j
        FROM public.brand_account_links l
        JOIN public.brand_accounts a ON a.auth_id = l.auth_id
       WHERE l.brand_id = p_brand_id AND l.status = 'active'
    ) t;

  RETURN jsonb_build_object(
    'my_role',      v_role,
    'seat_used',    public._brand_seat_usage(p_brand_id),
    'member_limit', public._brand_member_limit(p_brand_id),
    'rows',         v_rows
  );
END;
$$;

COMMENT ON FUNCTION public.get_brand_members(uuid) IS
  '[531] 멤버 관리 목록. 활성 연결이 없으면 {result:''not_linked''}. 대표: {my_role, seat_used, member_limit, rows[]} — 계정 행(auth_id 포함)+초대 행(대기·만료·거절, name 늘 NULL, 취소·수락·숨김 제외).
   멤버: 계정 행만, auth_id 키 없음, last_active_at 포함, seat_used·member_limit 는 대표와 같은 값(사양서 16-7). authenticated 전용.';

-- ── 5. 실행 권한 (369·370·375) — 부여 먼저 → PUBLIC 회수 → anon(안쪽 전용은 authenticated 도) 회수 ──

-- 5-1. 로그인 사용자 함수 7개
GRANT  EXECUTE ON FUNCTION public.create_brand_invite(uuid, text)               TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.resend_brand_invite(uuid)                     TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.cancel_brand_invite(uuid)                     TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.hide_brand_invite(uuid)                       TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.transfer_brand_ownership(uuid, uuid)          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.release_brand_member(uuid, uuid)              TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_brand_members(uuid)                       TO postgres, authenticated, service_role;

REVOKE EXECUTE ON FUNCTION public.create_brand_invite(uuid, text)               FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.resend_brand_invite(uuid)                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.cancel_brand_invite(uuid)                     FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.hide_brand_invite(uuid)                       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.transfer_brand_ownership(uuid, uuid)          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.release_brand_member(uuid, uuid)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_brand_members(uuid)                       FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public.create_brand_invite(uuid, text)               FROM anon;
REVOKE EXECUTE ON FUNCTION public.resend_brand_invite(uuid)                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.cancel_brand_invite(uuid)                     FROM anon;
REVOKE EXECUTE ON FUNCTION public.hide_brand_invite(uuid)                       FROM anon;
REVOKE EXECUTE ON FUNCTION public.transfer_brand_ownership(uuid, uuid)          FROM anon;
REVOKE EXECUTE ON FUNCTION public.release_brand_member(uuid, uuid)              FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_brand_members(uuid)                       FROM anon;

-- 5-2. 안쪽 전용 8개 (postgres·service_role 만)
GRANT  EXECUTE ON FUNCTION public._brand_transfer_owner(uuid, uuid)             TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid)      TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_invite_expires_at(timestamptz)         TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_invite_recipient_info(text)            TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_invite_inviter_name(uuid)              TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_invite_reissue(uuid, uuid)             TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_invite_result(text, uuid, uuid, boolean) TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public._brand_caller_link_role(uuid)                 TO postgres, service_role;

REVOKE EXECUTE ON FUNCTION public._brand_transfer_owner(uuid, uuid)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid)      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_expires_at(timestamptz)         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_recipient_info(text)            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_inviter_name(uuid)              FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_reissue(uuid, uuid)             FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_result(text, uuid, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_caller_link_role(uuid)                 FROM PUBLIC;

REVOKE EXECUTE ON FUNCTION public._brand_transfer_owner(uuid, uuid)             FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid)      FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_invite_expires_at(timestamptz)         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_invite_recipient_info(text)            FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_invite_inviter_name(uuid)              FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_invite_reissue(uuid, uuid)             FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_invite_result(text, uuid, uuid, boolean) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._brand_caller_link_role(uuid)                 FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
