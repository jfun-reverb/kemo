-- ============================================================
-- 530_brand_member_base.sql
-- 브랜드 멤버 관리·여러 브랜드 — 작업 1: 기초 (표·칸·권한 시드·판정 도우미)
--   작업표 docs/specs/2026-10-15-brand-member-breakdown.md 「작업 1」 · 사양서 docs/specs/2026-07-15-brand-portal.md §16-2·§16-7
--
-- 목적
--   ① 표 둘: brand_invites(멤버 초대 기록) · brand_member_limits(브랜드별 인원 상한)
--   ② brand_accounts 칸 5개 · brand_account_links 칸 1개
--   ③ 권한 항목 brand.account_manage 시드 3행
--   ④ 판정 함수 다섯: my_brand_role · is_my_brand(로그인 사용자) / _brand_member_limit · _brand_seat_usage ·
--      _brand_invite_acceptable(안쪽 전용)
--   이 파일은 함수 다섯 외의 동작을 바꾸지 않는다 — 새 표·칸·시드뿐이고 기존 함수는 건드리지 않는다.
--   초대를 만들고 수락하는 함수는 작업 2 이후.
--
-- 베이스
--   표 모양·정책 방식 : 526(읽기 정책만, 쓰기 정책 없음, (SELECT public.is_admin()) 감싸기 — 415 방식)
--   이메일 소유 판정  : 527 의 _brand_email_owner(text, uuid) 를 그대로 재사용(none / admin / brand / influencer)
--   잠금 열쇠        : 527 과 같은 열쇠('brand_account_upsert:'||브랜드 / 'brand_account_email:'||이메일)는 **작업 2 이후 쓰기 함수가** 잡는다.
--                      이 파일의 함수는 읽기 전용(STABLE)이라 잠금을 잡지 않는다 — 호출하는 쪽이 잠금 안에서 부른다.
--   권한 시드        : 441(세 등급 행 + default_level 같은 값, ON CONFLICT DO NOTHING)
--   실행 권한        : 369·370·375 — 부여 먼저 → PUBLIC 회수 → anon/authenticated 회수. 회수 방향이 둘이다.
--
-- 배포 순서
--   1) 526 → 527 → 528 이 먼저 들어가 있어야 한다(개발서버에는 있음). 🔴 개발서버만. 운영은 526~528 뒤 묶음으로(묶음 ① 전체 보류).
--      운영 반영 전 /약관확인 — brand_invites 에 계정 없는 사람의 이메일이 쌓인다(보관 기간 포함, 작업표 S2).
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 적용만으로 바뀌는 기존 동작: 없음.
--   3) 이 파일 다음은 작업 2(대표 함수). 화면(카탈로그 shared.js 의 brand.account_manage 등록)은 묶음 ③ 몫 —
--      🔴 시드는 이 파일이 먼저 넣는다(has_permission 은 행이 없으면 등급 2종이 거부, 슈퍼 관리자만 통과 — 269).
--
-- 설계 판단
--   [A] brand_invites 는 읽기 정책도 쓰기 정책도 두지 않는다. 관리자·대표·멤버·받는 사람 모두 함수로만 본다.
--       수락하지 않은 사람의 이메일(계정 없는 사람 포함)을 표 읽기로 노출하지 않으려는 것이다. 장애 대응은 서비스 키(SQL 편집기).
--   [B] expires_at 에 기본값을 두지 않는다(NOT NULL). 「issued_at + 24시간」 식을 표 기본값에도 두면 식 사본이 하나 더 생긴다.
--       값은 넣는 쪽 함수(작업 2)가 한 번에 채운다. 대신 CHECK(expires_at > issued_at)로 거꾸로 된 값만 막는다.
--       issued_at 은 기본값 now() — 함수가 같은 시각으로 expires_at 을 계산해 넣는다.
--   [C] brand_invites.brand_id 는 ON DELETE CASCADE(작업표 어긋남 7번 — 초대 줄이 있는 브랜드는 연결 이력이 있고 528 이 삭제를 막는다).
--       invited_by·sent_owner_auth_id·accepted_auth_id·mail_sent_link_id 는 참조를 걸지 않는다(계정이 지워져도 기록은 남고, 관리자 삭제와 얽히지 않게).
--   [D] brand_accounts.created_via_invite_id → brand_invites ON DELETE SET NULL. 초대 줄이 지워져도(브랜드 삭제 연쇄) 계정은 남는다.
--       FK 가 brand_invites 를 가리키므로 표 생성 순서는 brand_invites 가 먼저.
--   [E] brand_account_links.last_active_at 에 기본값 없음 — 「아직 활동 기록 없음」(화면 「—」)과 구분되어야 한다.
--   [F] password_changed_at 은 기존 행을 password_set_at 으로 채운다(설정 완료 = 첫 변경일). 설정 안 한 계정은 NULL 그대로.
--       setup_mail_sent_by 는 기존 행을 채우지 않는다 — 기존 설정 메일이 관리자 발송인지 본인 비밀번호 찾기 재발송인지 기록이 없다. NULL 허용.
--   [G] _brand_invite_acceptable 의 「지금 이메일 소유 상태」 대응표(_brand_email_owner 의 kind → 보낼 때 갈래 recipient_kind):
--         none → new / brand → brand / admin·influencer → blocked.
--       · 대기 · 만료 전(expires_at > now()) · 브랜드 활성(brands.status='active') · recipient_kind<>'blocked' 가 먼저다.
--       · 지금 상태 = 보낼 때 갈래여야 통과. ⓑ(brand)는 그 계정이 보낼 때 계정(sent_owner_auth_id)과 같아야 한다 — 보낼 때 계정이 NULL 이면 통과 못 한다.
--       · 예외 1(재시도): 보낼 때 new + 지금 그 이메일 계정이 brand + created_via_invite_id = 이 초대 + password_set_at NULL
--         → **p_via_link=true 일 때만** 통과(비로그인 새 이메일 경로). false 면 통과 못 한다.
--       · 예외 2(S0-4): 보낼 때 new + 지금 그 이메일이 password_set_at 이 있는 브랜드 계정 → p_via_link 와 무관하게 통과.
--       · p_auth_id 가 주어지면 brand_accounts.email = 초대 이메일(둘 다 lower(btrim))이어야 한다. NULL 이면 검사하지 않는다.
--       · 비밀번호 설정 여부는 brand_accounts.password_set_at 하나로 본다(인증 계정의 비밀번호 유무가 아니다).
--       · 이 도우미는 「초대가 유효한가」만 본다. 받는 계정의 비밀번호 설정 요구(setup_incomplete)는 수락 함수(작업 3)가 따로 본다.
--   [H] _brand_seat_usage 는 「자리를 차지하는가」, _brand_invite_acceptable 은 「수락할 수 있는가」 — 서로 다른 판정이다. 합치지 않는다.
--       좌석 = (활성 대표 연결이 있으면 1) + 활성 멤버 연결 수 + (status='pending' 이고 expires_at > now() 인 초대 수). 보관 브랜드도 센다(상한 판정은 활성 브랜드에서만 쓰인다).
--       만료·거절·취소·수락된 초대는 세지 않는다(수락된 초대는 멤버 연결로 세어진다).
--   [I] my_brand_role 은 활성 연결 + 활성 브랜드(527 get_my_brand_login_state 의 P-9 와 같은 기준). 한 사람이 같은 브랜드에 활성 연결이 둘일 수 없다
--       (526 부분 유일 색인) — 그래서 단일 값.
--
-- 되돌리는 방법  (이 순서로: 함수 → 칸 → 표 → 시드. 작업 2 이후 함수가 이미 있으면 그것을 먼저 지운다)
--   1) DROP FUNCTION IF EXISTS public._brand_invite_acceptable(uuid, uuid, boolean);
--      DROP FUNCTION IF EXISTS public._brand_seat_usage(uuid);
--      DROP FUNCTION IF EXISTS public._brand_member_limit(uuid);
--      DROP FUNCTION IF EXISTS public.is_my_brand(uuid);
--      DROP FUNCTION IF EXISTS public.my_brand_role(uuid);
--   2) ALTER TABLE public.brand_accounts
--        DROP COLUMN IF EXISTS created_via_invite_id, DROP COLUMN IF EXISTS setup_mail_sent_by,
--        DROP COLUMN IF EXISTS password_changed_at,   DROP COLUMN IF EXISTS last_brand_id, DROP COLUMN IF EXISTS mypage_seen_at;
--      ALTER TABLE public.brand_account_links DROP COLUMN IF EXISTS last_active_at;
--   3) DROP TABLE IF EXISTS public.brand_member_limits;   -- 데이터가 있으면 상한 설정이 사라진다
--      DROP TABLE IF EXISTS public.brand_invites;         -- 데이터가 있으면 초대 기록이 사라진다(2번이 먼저여야 참조 오류가 없다)
--   4) DELETE FROM public.role_permissions WHERE feature_key = 'brand.account_manage';
--   ⚠️ password_changed_at 을 지우면 마이페이지의 「비밀번호 변경일」이 사라진다(되돌릴 수 없는 값 — 필요하면 백업 후).
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   [V1] 표·정책
--     SELECT c.relname, c.relrowsecurity AS rls_on,
--            (SELECT count(*) FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname) AS policies
--       FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--      WHERE n.nspname='public' AND c.relname IN ('brand_invites','brand_member_limits') ORDER BY 1;
--     기대: brand_invites = rls_on true · policies 0 / brand_member_limits = rls_on true · policies 1.
--   [V2] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE')         AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--            has_function_privilege('service_role', p.oid, 'EXECUTE')  AS svc_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--      WHERE n.nspname='public'
--        AND p.proname IN ('my_brand_role','is_my_brand','_brand_member_limit','_brand_seat_usage','_brand_invite_acceptable')
--      ORDER BY 1;
--     기대: acl 맨 앞에 `=X/` 없음 · anon_can 전부 false · auth_can 은 my_brand_role·is_my_brand 만 true · svc_can 은 다섯 모두 true.
--   [V3] 권한 시드
--     SELECT role, feature_key, access_level, default_level FROM public.role_permissions
--      WHERE feature_key = 'brand.account_manage' ORDER BY role;
--     기대: 3행 — campaign_admin write/write · campaign_manager hidden/hidden · super_admin write/write.
--   [V4] 새 칸
--     SELECT table_name, column_name FROM information_schema.columns
--      WHERE table_schema='public' AND
--        ((table_name='brand_accounts' AND column_name IN ('mypage_seen_at','last_brand_id','password_changed_at','setup_mail_sent_by','created_via_invite_id'))
--         OR (table_name='brand_account_links' AND column_name='last_active_at')) ORDER BY 1,2;
--     기대: 6행. 기존 계정이 있으면 `SELECT count(*) FROM public.brand_accounts WHERE password_set_at IS NOT NULL AND password_changed_at IS NULL;` = 0.
--   [V5] 되돌림 묶음 시험 — 대표/멤버/무관 계정 흉내 + 좌석 수 + 수락 가능 판정. 끝의 RAISE EXCEPTION 이 전부 되돌린다
--     (편집기 자동 커밋 때문에 BEGIN…ROLLBACK 대신 DO 하나로. 시험 이메일은 `.invalid`, 메일은 나가지 않는다. 527 V4 와 같은 방식).
--     DO $$
--     DECLARE
--       b uuid; o uuid := gen_random_uuid(); m uuid := gen_random_uuid(); x uuid := gen_random_uuid(); n uuid := gen_random_uuid();
--       i_ok uuid; i_blk uuid; i_new uuid; v_out text := '';
--     BEGIN
--       INSERT INTO public.brands (name, contacts) VALUES ('zz-530-b', '[]') RETURNING id INTO b;
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       SELECT '00000000-0000-0000-0000-000000000000'::uuid, t.id,'authenticated','authenticated',t.em,'x',now(),now(),now(),
--              '','','','','','','','','{"provider":"email","providers":["email"],"account_kind":"brand"}'::jsonb,
--              jsonb_build_object('sub',t.id::text,'email',t.em,'email_verified',true,'phone_verified',false)
--         FROM (VALUES (o,'zz-530-o@example.invalid'),(m,'zz-530-m@example.invalid'),(x,'zz-530-x@example.invalid'),(n,'zz-530-n@example.invalid')) AS t(id,em);
--       INSERT INTO public.brand_accounts (auth_id,email,password_set_at)
--         VALUES (o,'zz-530-o@example.invalid',now()),(m,'zz-530-m@example.invalid',now()),(x,'zz-530-x@example.invalid',now());
--       INSERT INTO public.brand_account_links (auth_id,brand_id,role) VALUES (o,b,'owner'),(m,b,'member');
--       -- 초대: 대기(유효) 1 · 대기(만료) 1 · 거절 1  → 좌석 = 대표 1 + 멤버 1 + 대기 1 = 3
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at)
--         VALUES (b,'zz-530-i1@example.invalid',o,'대표','pending','new',now(),now()+interval '24 hours') RETURNING id INTO i_ok;
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at)
--         VALUES (b,'zz-530-i2@example.invalid',o,'대표','pending','new',now()-interval '48 hours',now()-interval '24 hours');
--       INSERT INTO public.brand_invites (brand_id,email,invited_by,inviter_name,status,recipient_kind,issued_at,expires_at,declined_at)
--         VALUES (b,'zz-530-i3@example.invalid',o,'대표','declined','new',now(),now()+interval '24 hours',now());
--       v_out := v_out || '좌석=' || public._brand_seat_usage(b) || ' 상한=' || public._brand_member_limit(b) || ' ';          -- 3 / 5
--       -- 로그인 흉내: 대표 / 멤버 / 무관 / 로그아웃
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', o, 'role', 'authenticated')::text, true);
--       v_out := v_out || '대표=' || COALESCE(public.my_brand_role(b),'NULL') || ' ';                                           -- owner
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', m, 'role', 'authenticated')::text, true);
--       v_out := v_out || '멤버=' || COALESCE(public.my_brand_role(b),'NULL') || '/' || public.is_my_brand(b) || ' ';          -- member/true
--       PERFORM set_config('request.jwt.claims', json_build_object('sub', x, 'role', 'authenticated')::text, true);
--       v_out := v_out || '무관=' || COALESCE(public.my_brand_role(b),'NULL') || '/' || public.is_my_brand(b) || ' ';          -- NULL/false
--       PERFORM set_config('request.jwt.claims', '', true);
--       v_out := v_out || '로그아웃=' || COALESCE(public.my_brand_role(b),'NULL') || ' ';                                       -- NULL
--       -- 수락 가능 판정
--       v_out := v_out || '새이메일=' || public._brand_invite_acceptable(i_ok, NULL, false) || ' ';                             -- true
--       UPDATE public.brand_invites SET recipient_kind='blocked' WHERE id = i_ok;
--       v_out := v_out || 'blocked=' || public._brand_invite_acceptable(i_ok, NULL, false) || ' ';                              -- false
--       UPDATE public.brand_invites SET recipient_kind='new' WHERE id = i_ok;
--       -- 예외 1: 이 초대로 만든 계정(비밀번호 미설정)
--       INSERT INTO public.brand_accounts (auth_id,email,created_via_invite_id) VALUES (n,'zz-530-i1@example.invalid',i_ok);
--       -- (auth.users 의 이메일은 zz-530-n@… 이므로 이 시험은 계정 표 이메일이 아니라 auth.users 이메일을 맞춰야 한다 — 아래 UPDATE)
--       UPDATE auth.users SET email='zz-530-i1@example.invalid' WHERE id = n;
--       v_out := v_out || '재시도(링크)=' || public._brand_invite_acceptable(i_ok, NULL, true)
--                      || ' 재시도(그 밖)=' || public._brand_invite_acceptable(i_ok, NULL, false) || ' ';                        -- true / false
--       -- 예외 2: 같은 계정이 비밀번호를 정함
--       UPDATE public.brand_accounts SET password_set_at = now() WHERE auth_id = n;
--       v_out := v_out || '예외2=' || public._brand_invite_acceptable(i_ok, NULL, false)
--                      || ' 계정일치=' || public._brand_invite_acceptable(i_ok, n, false)
--                      || ' 계정불일치=' || public._brand_invite_acceptable(i_ok, x, false) || ' ';                              -- true / true / false
--       RAISE EXCEPTION '530 시험 결과(전부 되돌림): %', v_out;
--     END $$;
--     기대: 「좌석=3 상한=5 대표=owner 멤버=member/true 무관=NULL/false 로그아웃=NULL 새이메일=true blocked=false
--           재시도(링크)=true 재시도(그 밖)=false 예외2=true 계정일치=true 계정불일치=false」 한 줄(의도된 예외).
--     그다음 따로: SELECT count(*) FROM auth.users WHERE email LIKE 'zz-530-%'; SELECT count(*) FROM public.brands WHERE name='zz-530-b'; → 둘 다 0
--     (0 이 아니면 멈추고 알릴 것). 만료 줄은 좌석에 안 들어간다(위 3 = 대표+멤버+유효 대기 1).
--     ⚠️ 로그인 흉내(set_config)는 auth.uid() 를 바꿀 뿐이다. 관리자 정책 분기는 이 시험이 안 도는 영역 — 읽기 정책 1개는 [V1] 로 확인.
--   [V6] 새 함수 1회 호출은 [V5] 가 겸한다(적용 Success 는 동작 확인이 아니다). 정책이 읽기만 있는지: 로그인한 관리자 브라우저 콘솔에서
--        (await db.from('brand_member_limits').select('*')).data → [] (오류 아님)  /  (await db.from('brand_invites').select('*')).data → [] (정책 없음 = 항상 빈 배열)
-- ============================================================

BEGIN;

-- ── 1. 표 brand_invites ─────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.brand_invites (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  brand_id           uuid        NOT NULL REFERENCES public.brands(id) ON DELETE CASCADE,
  email              text        NOT NULL CHECK (email = lower(btrim(email))),
  invited_by         uuid        NOT NULL,
  inviter_name       text        NOT NULL,
  -- 만료는 저장하지 않는다 — pending 이면서 expires_at 이 지난 것이 만료
  status             text        NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','accepted','declined','cancelled')),
  -- 보낼 때의 갈래: new(계정 없음) / brand(이미 브랜드 계정) / blocked(관리자·인플루언서 이메일)
  recipient_kind     text        NOT NULL CHECK (recipient_kind IN ('new','brand','blocked')),
  sent_owner_auth_id uuid,
  link_id            uuid        NOT NULL DEFAULT gen_random_uuid(),
  issued_at          timestamptz NOT NULL DEFAULT now(),
  -- 기본값 없음: issued_at + 24시간은 넣는 쪽 함수가 채운다(식 사본을 만들지 않는다 — 머리말 [B])
  expires_at         timestamptz NOT NULL,
  mail_sent_at       timestamptz,
  mail_sent_link_id  uuid,
  declined_at        timestamptz,
  accepted_at        timestamptz,
  accepted_auth_id   uuid,
  cancelled_at       timestamptz,
  owner_hidden_at    timestamptz,
  created_at         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT brand_invites_expires_after_issued CHECK (expires_at > issued_at)
);

COMMENT ON TABLE public.brand_invites IS
  '[530] 브랜드 멤버 초대 기록. 읽기·쓰기 정책 없음 — 함수(SECURITY DEFINER)와 서비스 키로만 접근(수락 안 한 사람의 이메일 보호).
   만료는 저장하지 않고 status=pending 이면서 expires_at 이 지난 것. expires_at 은 넣는 함수가 issued_at+24시간으로 채운다.
   invited_by·sent_owner_auth_id·accepted_auth_id·mail_sent_link_id 는 참조 없음(계정이 지워져도 기록 유지).';

CREATE UNIQUE INDEX IF NOT EXISTS brand_invites_link_id_key
  ON public.brand_invites (link_id);

-- 한 브랜드에 같은 이메일의 대기 초대는 하나뿐
CREATE UNIQUE INDEX IF NOT EXISTS brand_invites_one_pending_per_email
  ON public.brand_invites (brand_id, email)
  WHERE status = 'pending';

-- 이메일로 받은 초대 찾기(받은 초대 목록·로그인 판정)
CREATE INDEX IF NOT EXISTS brand_invites_email_pending_idx
  ON public.brand_invites (email)
  WHERE status = 'pending';

-- ── 2. 표 brand_member_limits ───────────────────────────────

CREATE TABLE IF NOT EXISTS public.brand_member_limits (
  brand_id     uuid        PRIMARY KEY REFERENCES public.brands(id) ON DELETE CASCADE,
  -- 대표를 포함한 인원. 상한 1 이면 대표만 있고 초대할 수 없다. 행이 없으면 5(_brand_member_limit)
  member_limit integer     NOT NULL CHECK (member_limit BETWEEN 1 AND 50),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid
);

COMMENT ON TABLE public.brand_member_limits IS
  '[530] 브랜드별 인원 상한(대표 포함). 행이 없으면 5. 쓰기 정책 없음 — 함수(작업 4 admin_set_brand_member_limit)만. 읽기는 관리자 전원.
   brands 표의 칸으로 두지 않은 이유: brands 수정 정책이 is_admin() 전원이라 캠페인 매니저가 권한 항목을 우회해 직접 고칠 수 있다.';

-- ── 3. RLS — brand_invites 는 정책 0개, brand_member_limits 는 읽기 1개 ──

ALTER TABLE public.brand_invites       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_member_limits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "brand_member_limits_select" ON public.brand_member_limits;
CREATE POLICY "brand_member_limits_select"
  ON public.brand_member_limits FOR SELECT
  USING ((SELECT public.is_admin()));

-- ── 4. 칸 추가 ──────────────────────────────────────────────

ALTER TABLE public.brand_accounts
  ADD COLUMN IF NOT EXISTS mypage_seen_at        timestamptz,
  ADD COLUMN IF NOT EXISTS last_brand_id         uuid REFERENCES public.brands(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS password_changed_at   timestamptz,
  ADD COLUMN IF NOT EXISTS setup_mail_sent_by    text,
  ADD COLUMN IF NOT EXISTS created_via_invite_id uuid REFERENCES public.brand_invites(id) ON DELETE SET NULL;

-- CHECK 는 IF NOT EXISTS 가 없어 이름을 지정하고 지웠다 다시 만든다(재실행 안전)
ALTER TABLE public.brand_accounts DROP CONSTRAINT IF EXISTS brand_accounts_setup_mail_sent_by_check;
ALTER TABLE public.brand_accounts
  ADD CONSTRAINT brand_accounts_setup_mail_sent_by_check
  CHECK (setup_mail_sent_by IS NULL OR setup_mail_sent_by IN ('admin','self'));

COMMENT ON COLUMN public.brand_accounts.mypage_seen_at IS '[530] 마이페이지 빨간 점을 끈 시각(받은 초대가 이 시각 이후 발급됐으면 점이 켜진다).';
COMMENT ON COLUMN public.brand_accounts.last_brand_id IS '[530] 마지막으로 본 브랜드(삭제되면 비움).';
COMMENT ON COLUMN public.brand_accounts.password_changed_at IS '[530] 비밀번호를 마지막으로 설정·변경한 시각. 기존 행은 password_set_at 으로 채움.';
COMMENT ON COLUMN public.brand_accounts.setup_mail_sent_by IS '[530] 마지막 설정 메일을 누가 보냈나 — admin(관리자) / self(본인 비밀번호 찾기). 기존 행은 NULL(기록 없음).';
COMMENT ON COLUMN public.brand_accounts.created_via_invite_id IS '[530] 이 계정이 어느 초대를 수락하다 만들어졌나(새 이메일 수락의 중간 실패 재시도 판정용). 초대 줄이 지워지면 NULL.';

-- 기존 행 채우기(멱등)
UPDATE public.brand_accounts
   SET password_changed_at = password_set_at
 WHERE password_changed_at IS NULL AND password_set_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS brand_accounts_created_via_invite_idx
  ON public.brand_accounts (created_via_invite_id)
  WHERE created_via_invite_id IS NOT NULL;

ALTER TABLE public.brand_account_links
  ADD COLUMN IF NOT EXISTS last_active_at timestamptz;

COMMENT ON COLUMN public.brand_account_links.last_active_at IS '[530] 그 브랜드에서의 마지막 페이지 활동 시각(브랜드별). 기본값 없음 — NULL = 아직 기록 없음.';

-- ── 5. 권한 시드 brand.account_manage (441 방식 — 세 등급 행, default_level 같은 값) ──
--   🔴 행이 없으면 has_permission 이 등급 2종은 거부, 슈퍼 관리자만 통과(269) — 같은 마이그레이션에서 넣는다.
INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'brand.account_manage', 'write',  'write'),
  ('campaign_admin',   'brand.account_manage', 'write',  'write'),
  ('campaign_manager', 'brand.account_manage', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

-- ── 6. 판정 함수 ─────────────────────────────────────────────

-- 6-1. my_brand_role — 로그인 사용자가 이 브랜드에서 어떤 역할인가(활성 연결 + 활성 브랜드)
CREATE OR REPLACE FUNCTION public.my_brand_role(p_brand_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT l.role
    FROM public.brand_account_links l
    JOIN public.brands b ON b.id = l.brand_id
   WHERE l.auth_id = (SELECT auth.uid())
     AND l.brand_id = p_brand_id
     AND l.status = 'active'
     AND b.status = 'active'
   LIMIT 1;
$$;

COMMENT ON FUNCTION public.my_brand_role(uuid) IS
  '[530] 로그인 사용자의 이 브랜드 역할 — ''owner'' / ''member'' / NULL(연결 없음·해제·보관 브랜드·로그아웃). authenticated 전용.';

GRANT  EXECUTE ON FUNCTION public.my_brand_role(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.my_brand_role(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.my_brand_role(uuid) FROM anon;

-- 6-2. is_my_brand — 조회 정책용(415 방식: (SELECT public.is_my_brand(brand_id)))
CREATE OR REPLACE FUNCTION public.is_my_brand(p_brand_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT public.my_brand_role(p_brand_id) IS NOT NULL;
$$;

COMMENT ON FUNCTION public.is_my_brand(uuid) IS
  '[530] 로그인 사용자가 이 브랜드의 활성 대표 또는 멤버인가. 작업 2 이후 조회 정책이 (SELECT public.is_my_brand(brand_id)) 형태로 쓴다. authenticated 전용.';

GRANT  EXECUTE ON FUNCTION public.is_my_brand(uuid) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.is_my_brand(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.is_my_brand(uuid) FROM anon;

-- 6-3. _brand_member_limit — 상한(행이 없으면 5)
CREATE OR REPLACE FUNCTION public._brand_member_limit(p_brand_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((SELECT m.member_limit FROM public.brand_member_limits m WHERE m.brand_id = p_brand_id), 5);
$$;

COMMENT ON FUNCTION public._brand_member_limit(uuid) IS '[530] 내부 도우미. 브랜드 인원 상한(대표 포함) — brand_member_limits 행이 없으면 5. 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_member_limit(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_member_limit(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_member_limit(uuid) FROM anon, authenticated;

-- 6-4. _brand_seat_usage — 자리를 차지한 수
CREATE OR REPLACE FUNCTION public._brand_seat_usage(p_brand_id uuid)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    (CASE WHEN EXISTS (SELECT 1 FROM public.brand_account_links l
                        WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active')
          THEN 1 ELSE 0 END)
    + (SELECT count(*) FROM public.brand_account_links l
        WHERE l.brand_id = p_brand_id AND l.role = 'member' AND l.status = 'active')::int
    + (SELECT count(*) FROM public.brand_invites i
        WHERE i.brand_id = p_brand_id AND i.status = 'pending' AND i.expires_at > now())::int;
$$;

COMMENT ON FUNCTION public._brand_seat_usage(uuid) IS
  '[530] 내부 도우미. 자리를 차지한 수 = (활성 대표 연결 있으면 1) + 활성 멤버 연결 수 + (대기이고 만료 전인 초대 수 — ⓒ·상태가 바뀐 초대도 센다). 만료·거절·취소·수락된 초대는 안 센다. 「수락 가능」 판정(_brand_invite_acceptable)과 다른 판정.';

GRANT  EXECUTE ON FUNCTION public._brand_seat_usage(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_seat_usage(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_seat_usage(uuid) FROM anon, authenticated;

-- 6-5. _brand_invite_acceptable — 초대가 지금 수락 가능한가(머리말 [G])
CREATE OR REPLACE FUNCTION public._brand_invite_acceptable(
  p_invite_id uuid,
  p_auth_id   uuid,
  p_via_link  boolean
)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_inv       public.brand_invites%ROWTYPE;
  v_owner     jsonb;
  v_kind      text;     -- _brand_email_owner 의 kind
  v_owner_id  uuid;
  v_now_kind  text;     -- 지금 상태를 보낼 때 갈래 이름으로 환산
  v_acct      public.brand_accounts%ROWTYPE;
BEGIN
  SELECT i.* INTO v_inv FROM public.brand_invites i WHERE i.id = p_invite_id;
  IF NOT FOUND THEN RETURN false; END IF;

  -- 대기 · 만료 전 · ⓒ 아님
  IF v_inv.status <> 'pending' OR v_inv.expires_at <= now() OR v_inv.recipient_kind = 'blocked' THEN
    RETURN false;
  END IF;

  -- 브랜드 활성
  IF NOT EXISTS (SELECT 1 FROM public.brands b WHERE b.id = v_inv.brand_id AND b.status = 'active') THEN
    RETURN false;
  END IF;

  -- 계정이 주어지면 그 계정의 이메일이 초대 이메일과 같아야 한다
  IF p_auth_id IS NOT NULL THEN
    IF NOT EXISTS (SELECT 1 FROM public.brand_accounts a
                    WHERE a.auth_id = p_auth_id AND lower(btrim(a.email)) = lower(btrim(v_inv.email))) THEN
      RETURN false;
    END IF;
  END IF;

  -- 지금 이 이메일을 쓰는 계정 상태
  v_owner    := public._brand_email_owner(v_inv.email, NULL);
  v_kind     := v_owner->>'kind';
  v_owner_id := NULLIF(v_owner->>'auth_id', '')::uuid;
  v_now_kind := CASE v_kind WHEN 'none' THEN 'new' WHEN 'brand' THEN 'brand' ELSE 'blocked' END;

  -- 지금 상태 = 보낼 때 상태
  IF v_now_kind = v_inv.recipient_kind THEN
    IF v_inv.recipient_kind = 'brand' THEN
      -- ⓑ 는 보낼 때 그 계정이어야 한다(보낼 때 계정이 NULL 이면 통과 못 한다)
      RETURN v_inv.sent_owner_auth_id IS NOT NULL AND v_inv.sent_owner_auth_id = v_owner_id;
    END IF;
    RETURN true;   -- new → 지금도 계정 없음
  END IF;

  -- 예외 둘 — 보낼 때 new 인데 지금 그 이메일이 브랜드 계정인 경우만
  IF v_inv.recipient_kind = 'new' AND v_kind = 'brand' AND v_owner_id IS NOT NULL THEN
    SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_owner_id;
    IF FOUND THEN
      -- 예외 1(재시도): 이 초대로 만든 계정 + 비밀번호 미설정 — 링크 경로(p_via_link)에서만
      IF COALESCE(p_via_link, false)
         AND v_acct.created_via_invite_id = v_inv.id
         AND v_acct.password_set_at IS NULL THEN
        RETURN true;
      END IF;
      -- 예외 2(S0-4): 비밀번호를 정한 브랜드 계정 — 계정이 생긴 경로·p_via_link 무관
      IF v_acct.password_set_at IS NOT NULL THEN
        RETURN true;
      END IF;
    END IF;
  END IF;

  RETURN false;
END;
$$;

COMMENT ON FUNCTION public._brand_invite_acceptable(uuid, uuid, boolean) IS
  '[530] 내부 도우미. 초대가 지금 수락 가능한가 — 대기·만료 전·브랜드 활성·ⓒ 아님·지금 이메일 소유 상태=보낼 때 갈래(+ 예외 1 재시도[p_via_link=true 만]·예외 2 비밀번호를 정한 브랜드 계정). 계정이 주어지면 계정 이메일=초대 이메일.
   초대가 유효한가만 본다 — 받는 계정의 비밀번호 설정 요구는 수락 함수가 따로 본다. 호출하는 쪽이 브랜드 잠금 안에서 부를 것(이 함수는 잠금을 잡지 않는다). 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_invite_acceptable(uuid, uuid, boolean) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_invite_acceptable(uuid, uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_invite_acceptable(uuid, uuid, boolean) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
