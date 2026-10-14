-- ============================================================
-- 525_brand_accounts_base.sql
-- 브랜드 로그인 — 조각 1: 데이터베이스 기초
--   docs/specs/2026-10-14-brand-login-breakdown.md 「조각 1」 · 사양서 docs/specs/2026-07-15-brand-portal.md §16-6
--
-- 목적
--   브랜드 대표 담당자가 로그인할 수 있는 「브랜드 계정」의 바닥을 깐다.
--   ① 표 셋: brand_accounts(계정) · brand_account_links(계정↔브랜드 연결) · brand_password_reset_requests(비밀번호 찾기 요청 기록)
--   ② handle_new_user() — 앱 메타데이터 account_kind='brand' 인 계정은 인플루언서 행을 만들지 않는다
--   ③ influencers BEFORE INSERT 거부 트리거 — 브랜드 계정의 id 로는 인플루언서 행을 못 만든다(어느 경로로든)
--   ④ get_my_account_kind() — 로그인한 본인이 'brand' 인지 'other' 인지(인플루언서 앱 차단 판정용)
--
-- 베이스
--   handle_new_user : 420 (014 → 382 → 420). 084 는 권한만 손댔다. 본문은 420 에서 글자 그대로 옮기고
--                     맨 앞에 브랜드 분기만 더했다. 382 를 베이스로 잡으면 420 의 날짜 범위 검사가 사라진다.
--   표 모양(243 복제): 요청 기록 표 · 이메일 해시만 저장(원문 이메일 없음)
--   정책 방식: 415 — (SELECT auth.uid()) / (SELECT public.is_admin()) 로 감싸 행마다 평가를 피한다
--
-- 배포 순서  (사용자 결정 P-1: 개발서버에서만 동작)
--   1) 개발서버 SQL 편집기에 이 파일 전체를 실행한다. 🔴 운영 데이터베이스에는 적용하지 않는다(보류).
--   2) 이 파일은 다른 코드보다 먼저 들어가야 한다 — 이후 조각의 함수·화면이 이 표와 함수를 부른다.
--   3) 운영 반영은 관문(약관 P-7)이 닫힌 뒤 별도 결정 — 지금은 보류. 운영에 넣어도 기존 동작은
--      안 바뀌지만(표·함수만 생긴다) 아직 승인되지 않았다.
--   4) 적용만으로 바뀌는 기존 동작: 없음. handle_new_user 는 account_kind 가 없으면 420 과 완전히 같다.
--
-- 설계 판단
--   [A] 왜 「앱 메타데이터」(raw_app_meta_data)인가
--       raw_user_meta_data 는 `signUp({options:{data:…}})` 로 공개 키 호출자가 마음대로 채운다. 거기에 brand 표시를
--       읽으면 누구나 가입 때 인플루언서 행을 건너뛸 수 있다. raw_app_meta_data 는 서버(서비스 키·SQL)만 쓴다.
--       또 383 의 정리 트리거(BEFORE UPDATE OF raw_user_meta_data)와 497 의 열쇠 목록은 사용자 메타데이터만 만진다 —
--       그래서 브랜드 표시는 사용자 메타데이터에 두면 안 된다(이름 `name` 같은 폼 키도 383 이 지운다).
--   [B] 거부 트리거 함수는 SECURITY DEFINER + SET search_path = ''
--       이 트리거는 `influencers` INSERT 마다 돈다. 호출자가 로그인한 회원(authenticated)이면 INVOKER 로는
--       brand_accounts 읽기 정책(본인 행만)에 걸려 「남의 id 로 넣는 행」을 못 본다. 그런데 137 의 인플루언서 삽입 정책은
--       `auth.uid() IS NOT NULL` 이면 통과라서(본인 행 제한 없음) 판정은 반드시 NEW.id 이고, 정책과 무관하게 표를 읽어야
--       한다 → DEFINER. 492·497 의 「INVOKER 필수」는 `current_user` 로 호출자를 가르는 함수에 대한 것이고, 이 함수는
--       current_user 를 쓰지 않으므로 해당 없다. 실행 권한은 둘 다 회수(트리거 발화는 EXECUTE 권한을 보지 않는다).
--   [C] 거부 판정은 brand_accounts 만이 아니라 auth.users 의 앱 메타데이터도 본다
--       가입 트리거(handle_new_user)가 도는 시점에는 brand_accounts 행이 아직 없다(auth.users 가 먼저, 계정 표는 그 뒤).
--       그 틈과, 계정 표 행이 없는 반쪽 상태에서도 인플루언서 행이 생기지 않게 두 곳을 모두 본다.
--   [D] 이메일은 어디서나 lower(btrim()) — 표에는 정규화한 값만 저장(CHECK)하고 유일 색인도 같은 식이다.
--   [E] get_my_account_kind 는 「계정이 있는가」만 본다. 활성 브랜드 연결·설정 완료 여부는 조각 2 의 get_my_brand_login_state 몫.
--
-- 권한 정책
--   세 표 모두 RLS 켜기, 쓰기 정책 없음(쓰기는 SECURITY DEFINER 함수·서비스 키만).
--   읽기: brand_accounts·brand_account_links = 본인 또는 관리자 전원 / brand_password_reset_requests = 최고 관리자만.
--   ⚠️ 관리자 전원(캠페인 매니저 포함)이 담당자 이름·전화를 읽는 것은 의도다 — 같은 값이 이미 brands.contacts 에 있고
--      brands 읽기 정책(082 brands_select_admin)이 is_admin() 전원이다. 좁히려면 brands 와 함께 좁힌다.
--   🔴 표 권한(GRANT)은 건드리지 않았다 — 이 저장소의 다른 표와 같다. RLS 정책이 유일한 방어선이다.
--
-- 되돌리는 방법  (아래를 이 순서로)
--   1) handle_new_user 되돌리기: 420_signup_consent_and_birthdate_range.sql 의 handle_new_user 구문(CREATE OR REPLACE FUNCTION
--      public.handle_new_user() … $$;)만 다시 실행. 이 파일의 맨 앞 브랜치 분기만 사라진다. 트리거 연결은 그대로.
--   2) DROP TRIGGER IF EXISTS trg_block_influencer_row_for_brand ON public.influencers;
--      DROP FUNCTION IF EXISTS public.block_influencer_row_for_brand();
--   3) DROP FUNCTION IF EXISTS public.get_my_account_kind();
--   4) 표 삭제는 **데이터가 0건일 때만**(계정이 하나라도 있으면 auth.users 쪽 계정이 남아 반쪽이 된다):
--      DROP TABLE IF EXISTS public.brand_password_reset_requests;
--      DROP TABLE IF EXISTS public.brand_account_links;
--      DROP TABLE IF EXISTS public.brand_accounts;
--      ⚠️ 1)을 안 하고 4)만 하면 handle_new_user 는 그대로 새 분기를 갖지만 표가 없어도 오류는 없다(분기는 앱 메타데이터만 본다).
--         반대로 2)를 안 하고 4)를 하면 influencers INSERT 가 전부 「relation does not exist」로 실패한다 — 반드시 2) 먼저.
--
-- 적용 후 확인  (한 단계씩 실행하고 결과를 본 뒤 다음으로 — supabase.md 「SQL 검증 순차 안내」)
--   [V1] 표·정책·권한 상태
--     SELECT c.relname, c.relrowsecurity AS rls_on,
--            (SELECT count(*) FROM pg_policies p WHERE p.schemaname='public' AND p.tablename=c.relname) AS policies
--       FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
--      WHERE n.nspname='public' AND c.relname IN ('brand_accounts','brand_account_links','brand_password_reset_requests')
--      ORDER BY 1;
--     기대: 3행, rls_on 전부 true, policies = 1 · 1 · 1 (읽기 정책만, 쓰기 정책 없음).
--   [V2] 실행 권한 — 🔴 has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께 본다
--     SELECT p.proname, p.proacl::text AS acl,
--            has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can,
--            has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can
--       FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--      WHERE n.nspname='public' AND p.proname IN ('get_my_account_kind','block_influencer_row_for_brand')
--      ORDER BY 1;
--     기대: get_my_account_kind = anon_can false · auth_can true · acl 맨 앞에 `=X/` 없음
--           block_influencer_row_for_brand = 둘 다 false · acl 맨 앞에 `=X/` 없음.
--   [V3] 되돌림 포함 시험 — auth.users 삽입을 DO 블록 + RAISE EXCEPTION 으로 통째로 되돌린다.
--     ⚠️ 판단: SQL 편집기는 postgres 권한으로 돌므로 auth.users 직접 삽입이 **가능**하다(417 invite_admin 이 같은 방식,
--        420 의 [V2] 선례). 위험은 ① 편집기가 문장마다 자동 커밋하므로 BEGIN…ROLLBACK 을 여러 문장으로 쓰면 중간에 확정될 수
--        있다 → 반드시 **DO 블록 하나 + 끝의 RAISE EXCEPTION** 으로(예외로 전부 롤백) ② 497 가입 관문은 current_user 가
--        supabase_auth_admin 이 아니라서 이 시험을 통과시킨다(관문을 시험하는 것이 아니다) ③ 시험 이메일은 `.invalid` 도메인.
--        메일은 나가지 않는다(인증 서비스를 안 거친 직접 삽입). 362 가입 차단은 미적용이라 영향 없음.
--     DO $$
--     DECLARE
--       v_brand uuid := gen_random_uuid();  v_plain uuid := gen_random_uuid();  v_half uuid := gen_random_uuid();
--       r_brand_inf int; r_plain_inf int; msg_c text; msg_d text;
--     BEGIN
--       -- (A) 브랜드 표시 계정: 앱 메타데이터 account_kind=brand → 인플루언서 행 0건이어야 한다
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       VALUES ('00000000-0000-0000-0000-000000000000', v_brand,'authenticated','authenticated','zz-525-brand@example.invalid','',now(),now(),now(),
--               '','','','','','','','',
--               '{"provider":"email","providers":["email"],"account_kind":"brand"}', jsonb_build_object('sub',v_brand::text,'email','zz-525-brand@example.invalid','email_verified',true,'phone_verified',false));
--       -- (B) 대조군: account_kind 없는 일반 계정 → 인플루언서 행 1건이어야 한다
--       INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--                               confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--                               phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--       VALUES ('00000000-0000-0000-0000-000000000000', v_plain,'authenticated','authenticated','zz-525-plain@example.invalid','',now(),now(),now(),
--               '','','','','','','','',
--               '{"provider":"email","providers":["email"]}', jsonb_build_object('sub',v_plain::text,'email','zz-525-plain@example.invalid','email_verified',true,'phone_verified',false));
--       SELECT count(*) INTO r_brand_inf FROM public.influencers WHERE id = v_brand;
--       SELECT count(*) INTO r_plain_inf FROM public.influencers WHERE id = v_plain;
--       -- (C) 계정 표 행이 아직 없어도(앱 메타데이터만) 직접 삽입 거부
--       BEGIN
--         INSERT INTO public.influencers (id, email) VALUES (v_brand, 'zz-525-brand@example.invalid');
--         msg_c := 'NOT BLOCKED';
--       EXCEPTION WHEN others THEN msg_c := SQLERRM; END;
--       -- (D) 계정 표 행이 있고 앱 메타데이터는 일반인 계정도 거부(표 쪽 판정)
--       INSERT INTO public.brand_accounts (auth_id, email) VALUES (v_plain, 'zz-525-plain@example.invalid');
--       DELETE FROM public.influencers WHERE id = v_plain;
--       BEGIN
--         INSERT INTO public.influencers (id, email) VALUES (v_plain, 'zz-525-plain@example.invalid');
--         msg_d := 'NOT BLOCKED';
--       EXCEPTION WHEN others THEN msg_d := SQLERRM; END;
--       RAISE EXCEPTION '525 시험 결과(전부 되돌림): A브랜드 인플루언서행=% (기대 0) · B일반 인플루언서행=% (기대 1) · C=% · D=% (둘 다 기대 brand_account_not_influencer)',
--         r_brand_inf, r_plain_inf, msg_c, msg_d;
--     END $$;
--     기대: 오류 창에 위 한 줄이 나오고(의도된 예외), 이후 `SELECT count(*) FROM auth.users WHERE email LIKE 'zz-525-%'` = 0.
--     순서: ① 위 DO 블록만 실행 → 오류 문구 확인 ② 그다음 따로 count 조회 실행 → 0 확인(0 이 아니면 즉시 멈추고 알릴 것).
--     ⚠️ 이 시험은 관리자·권한 분기를 재현하지 못한다(서비스 권한이라 정책이 안 돈다).
--   [V4] get_my_account_kind 는 실제 로그인한 브라우저 콘솔에서 1회: (await db.rpc('get_my_account_kind')).data → 'other' (인플루언서·관리자 계정).
--   [V5] 🔁 회귀 2종: 인플루언서 신규 가입 1회(influencers 행 생성·폼 값 저장) · 관리자 초대 1회(invite_admin).
--
-- 가입 관문·정리 트리거와의 상호작용 (조각 2 가 417 방식으로 계정을 직접 삽입할 때) — 이 파일은 바꾸지 않는다
--   · 420 on_auth_user_created(AFTER INSERT) : account_kind=brand 면 이 파일의 분기로 즉시 종료 → 인플루언서 행 없음, 메타데이터 정리 UPDATE 도 안 돈다
--   · 383 on_auth_user_updated_strip_signup_meta(BEFORE UPDATE OF raw_user_meta_data) : 삽입엔 안 돈다. 이후 그 칸을 고치는 UPDATE 마다
--       name·name_kanji·name_kana·birthdate·gender·동의 시각·marketing 열쇠(+497 의 signup_ticket)를 떨군다 → 브랜드 담당자 이름 등을 그 칸에 담지 말 것(표 칸 사용)
--   · 497 trg_signup_ticket_gate / trg_signup_resend_gate : current_user <> 'supabase_auth_admin' 이면 첫 분기에서 통과. 직접 삽입은 DEFINER 함수(소유자 postgres)라 통과.
--       다만 인증 서비스(GoTrue)가 같은 계정을 만들거나 재설정 메일을 보내는 경로는 email_confirmed_at 이 채워진 행이라 통과(resend 관문 첫 줄)
--   · 498 purge_unverified_accounts : email_confirmed_at IS NULL 만 대상 → 브랜드 계정은 확인 시각이 있어 대상 아님(이 값을 NULL 로 두면 7일 뒤 삭제된다)
--   · 499 signup_email_registered : 브랜드 계정 이메일도 「이미 가입」으로 보인다(알려진 틈 — 조각 문서 stale 6-ⓒ)
-- ============================================================

BEGIN;

-- ── 1. 표 ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.brand_accounts (
  auth_id            uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  -- 로그인 이메일 — 저장 전에 lower(btrim()) 로 정규화한다(CHECK 가 강제)
  email              text        NOT NULL CHECK (email = lower(btrim(email))),
  name               text,
  phone              text,
  password_set_at    timestamptz,
  terms_agreed_at    timestamptz,
  privacy_agreed_at  timestamptz,
  terms_version      text,
  setup_link_id      uuid,
  setup_mail_sent_at timestamptz,
  setup_mail_sent_to text,
  created_at         timestamptz NOT NULL DEFAULT now(),
  created_by         uuid
);

COMMENT ON TABLE public.brand_accounts IS
  '[525] 브랜드 로그인 계정(대표 담당자). auth.users 와 1:1(auth_id). 쓰기는 SECURITY DEFINER 함수·서비스 키만(RLS 쓰기 정책 없음).
   email 은 lower(btrim()) 정규화 값. created_by 는 만든 관리자의 auth_id(FK 없음 — 관리자 삭제와 얽히지 않게).';

CREATE UNIQUE INDEX IF NOT EXISTS brand_accounts_email_key
  ON public.brand_accounts (lower(btrim(email)));

CREATE TABLE IF NOT EXISTS public.brand_account_links (
  id                uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id           uuid        NOT NULL REFERENCES public.brand_accounts(auth_id) ON DELETE CASCADE,
  -- 🔴 RESTRICT — 연결이 있는 브랜드는 삭제할 수 없다(조각 3 의 delete_brand·merge_brands 가드가 먼저 친절한 메시지를 낸다)
  brand_id          uuid        NOT NULL REFERENCES public.brands(id) ON DELETE RESTRICT,
  role              text        NOT NULL CHECK (role IN ('owner','member')),
  status            text        NOT NULL DEFAULT 'active' CHECK (status IN ('active','released')),
  source_contact_id text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  released_at       timestamptz
);

COMMENT ON TABLE public.brand_account_links IS
  '[525] 브랜드 계정 ↔ 브랜드 연결. role=owner 는 브랜드당 활성 1명(부분 유일). status=released 는 이력으로 남긴다.
   source_contact_id 는 연결의 근거가 된 brands.contacts[].id(문자열, FK 아님).';

CREATE UNIQUE INDEX IF NOT EXISTS brand_account_links_one_active_owner
  ON public.brand_account_links (brand_id)
  WHERE role = 'owner' AND status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS brand_account_links_one_active_per_account_brand
  ON public.brand_account_links (auth_id, brand_id)
  WHERE status = 'active';

-- brand_id 단독 조회(삭제·병합 가드, RESTRICT 검사)용
CREATE INDEX IF NOT EXISTS brand_account_links_brand_idx
  ON public.brand_account_links (brand_id);

CREATE TABLE IF NOT EXISTS public.brand_password_reset_requests (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  -- 원문 이메일 저장 금지 — sha256(소문자·공백 제거 정규화 후) 16진수 64자 (243 과 같은 규칙)
  email_hash   text        NOT NULL CHECK (email_hash ~ '^[0-9a-f]{64}$'),
  requested_at timestamptz NOT NULL DEFAULT now(),
  matched      boolean     NOT NULL DEFAULT false
);

COMMENT ON TABLE public.brand_password_reset_requests IS
  '[525] 브랜드 비밀번호 찾기 요청 기록(243 복제). 원문 이메일 미저장(sha256 해시만). 요청 제한 판정용 + 30일 후 삭제(조각 2).
   쓰기는 서비스 키 전용(RLS 정책 없음).';

CREATE INDEX IF NOT EXISTS idx_brand_pw_reset_email_hash_at
  ON public.brand_password_reset_requests (email_hash, requested_at DESC);
CREATE INDEX IF NOT EXISTS idx_brand_pw_reset_requested_at
  ON public.brand_password_reset_requests (requested_at DESC);

-- ── 2. RLS — 켜기 + 읽기 정책만(쓰기 정책 없음 = 쓰기 전면 차단, 서비스 키·DEFINER 함수만) ──

ALTER TABLE public.brand_accounts                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_account_links           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brand_password_reset_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "brand_accounts_select" ON public.brand_accounts;
CREATE POLICY "brand_accounts_select"
  ON public.brand_accounts FOR SELECT
  USING (auth_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

DROP POLICY IF EXISTS "brand_account_links_select" ON public.brand_account_links;
CREATE POLICY "brand_account_links_select"
  ON public.brand_account_links FOR SELECT
  USING (auth_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

DROP POLICY IF EXISTS "brand_pw_reset_requests_select_super" ON public.brand_password_reset_requests;
CREATE POLICY "brand_pw_reset_requests_select_super"
  ON public.brand_password_reset_requests FOR SELECT
  USING ((SELECT public.is_super_admin()));

-- ── 3. handle_new_user() — 420 본문 그대로 + 맨 앞 브랜드 분기 ─────────
--   ⚠️ 트리거 연결(on_auth_user_created)은 다시 만들지 않는다 — 함수만 바꿔 끼운다.
--   ⚠️ 아래 본문은 420 에서 글자 그대로 옮겼다(맨 앞 분기 한 덩어리만 추가). 다시 손볼 때도 420 이 아니라 이 파일이 베이스다.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  m jsonb := COALESCE(NEW.raw_user_meta_data, '{}'::jsonb);
BEGIN
  -- [525] 브랜드 계정(앱 메타데이터 account_kind='brand')은 인플루언서 행을 만들지 않는다.
  --   🔴 사용자 메타데이터(raw_user_meta_data)가 아니라 **앱** 메타데이터를 본다 — 앞쪽은 공개 키 `signUp` 호출자가
  --   마음대로 채울 수 있다. 이 분기는 반드시 INSERT 보다 앞에 있어야 한다(아래 정리 UPDATE 도 건너뛴다).
  IF NEW.raw_app_meta_data->>'account_kind' = 'brand' THEN
    RETURN NEW;
  END IF;

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
  '[014+382+420+525] 계정이 만들어질 때 회원 행을 만든다. 525 부터 앱 메타데이터 account_kind=brand 인 계정은 회원 행 없이 즉시 종료(브랜드 계정).
   420 부터 동의 시각은 계정 생성 시각 ±1일 안에서만 브라우저 값을 믿고(밖이면 now()), 생년월일은 1900~오늘 밖이면 NULL. 382 부터 가입 폼 값
   (이름·생년월일·성별·동의 시각)을 raw_user_meta_data 에서 꺼내 함께 넣고,
   개인정보를 두 곳에 남기지 않도록 그 자리를 지운다(email 키는 남긴다).
   ⚠️ 미확인 계정에도 값이 들어간다 — 회원 수에서 빼는 것은 설계 2 소관.';

-- ── 4. influencers BEFORE INSERT — 브랜드 계정의 인플루언서 행 거부 ────
--   SECURITY DEFINER 이유는 머리말 [B], 두 곳을 보는 이유는 [C].
CREATE OR REPLACE FUNCTION public.block_influencer_row_for_brand()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.brand_accounts WHERE auth_id = NEW.id)
     OR EXISTS (SELECT 1 FROM auth.users u
                 WHERE u.id = NEW.id
                   AND u.raw_app_meta_data->>'account_kind' = 'brand') THEN
    RAISE EXCEPTION 'brand_account_not_influencer' USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.block_influencer_row_for_brand() IS
  '[525] influencers BEFORE INSERT. NEW.id 가 brand_accounts 에 있거나 auth.users 앱 메타데이터가 account_kind=brand 면 brand_account_not_influencer 로 거부.
   판정은 auth.uid() 가 아니라 NEW.id(137 의 삽입 정책은 로그인만 하면 통과). SECURITY DEFINER — 호출자의 표 읽기 정책에 좌우되지 않게.';

REVOKE ALL ON FUNCTION public.block_influencer_row_for_brand() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.block_influencer_row_for_brand() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_block_influencer_row_for_brand ON public.influencers;
CREATE TRIGGER trg_block_influencer_row_for_brand
  BEFORE INSERT ON public.influencers
  FOR EACH ROW EXECUTE FUNCTION public.block_influencer_row_for_brand();

-- ── 5. get_my_account_kind() — 'brand' | 'other' ───────────────────────
--   인플루언서 앱이 로그인 직후 부른다. ⚠️ anon 실행 권한을 회수했으므로 로그아웃 상태 호출은 'other' 가 아니라 권한 오류다
--   (화면은 실패 = null 로 받는다). 로그인 상태에서만 부를 것.
--   🔴 호출 실패(null)를 「차단」으로 처리하면 이 함수가 없는 서버에서 전원 로그인이 막힌다 — 화면(조각 9)이 실패 시 진행하되 자동 생성만 막는다.
CREATE OR REPLACE FUNCTION public.get_my_account_kind()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT CASE
           WHEN EXISTS (SELECT 1 FROM public.brand_accounts WHERE auth_id = (SELECT auth.uid()))
           THEN 'brand' ELSE 'other'
         END;
$$;

COMMENT ON FUNCTION public.get_my_account_kind() IS
  '[525] 로그인한 본인의 계정 종류 — brand_accounts 에 있으면 ''brand'', 아니면 ''other''. authenticated 전용(로그아웃 상태 호출은 권한 오류).';

-- 부여 먼저 → PUBLIC 회수 → anon 회수 (369·370·375 의 방향 둘)
GRANT  EXECUTE ON FUNCTION public.get_my_account_kind() TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_account_kind() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_account_kind() FROM anon;

COMMIT;
