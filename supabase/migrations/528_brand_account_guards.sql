-- ============================================================
-- 528_brand_account_guards.sql
-- 브랜드 로그인 — 조각 3: 기존 함수 세 개에 「브랜드 계정」 가드 추가
--   docs/specs/2026-10-14-brand-login-breakdown.md 「조각 3」 · P-10(초대 거부 확정) · stale 1
--
-- 목적
--   526 의 brand_account_links 가 생겼으므로, 기존 함수 세 개가 브랜드 계정을 모르는 채로 돌면 안 된다.
--   ① delete_brand(uuid)   — 계정 연결이 있으면 삭제 거부
--   ② merge_brands(uuid,uuid) — 원본 브랜드에 활성 계정 연결이 있으면 병합 거부
--   ③ invite_admin(text,text,text) — 브랜드 계정 이메일이면 관리자 초대·승격 거부
--
-- 🔴 베이스 번호 (글자 그대로 옮기고 가드만 더했다 — 175·191·245 를 베이스로 잡지 말 것)
--   delete_brand  : 325 (174 → 191 → 325). CREATE 정의가 있는 파일은 174·191·325 뿐, 번호 최대 = 325.
--   merge_brands  : 467 (175 → 328 → 467). 정의는 175·328·467. 175 를 베이스로 잡으면 328 의 오리엔시트 이동과
--                   467 의 메모 이동이 사라진다.
--   invite_admin  : 417 (031 → 245 → 417). 정의(CREATE)는 031·245·417. 084 는 권한만 손댄 파일이라 베이스 아님.
--   세 함수의 시그니처·반환형·LANGUAGE·SECURITY DEFINER·SET search_path = '' 는 베이스와 같다.
--   CREATE OR REPLACE 라 기존 실행 권한(proacl)이 그대로 남는다 — 🔴 DROP 하면 권한이 풀린다.
--
-- 바꾼 줄 (원본 본문과의 차이는 아래 「추가」뿐이다. 지운 줄·바뀐 줄 없음)
--   delete_brand  : 선언 2줄(v_links·v_rel) + 325 의 「연결 있음」 거부 바로 뒤에 계정 연결 검사 두 개
--       · 활성(status='active') 연결 N건 > 0 → 22023 '계정 연결 N건이 있어 삭제할 수 없습니다. …'
--       · 해제(released) 연결만 있어도 → 22023 '해제된 계정 연결 이력 N건이 있어 삭제할 수 없습니다(이력 보존). 병합 기능을 사용하세요.'
--   merge_brands  : 원본·대상 행 조회가 끝난 직후(멱등성 판정 앞)에 활성 연결 검사 1개
--       · 원본에 활성 연결 → RAISE EXCEPTION 'brand_has_account_links' USING ERRCODE='22023'
--   invite_admin  : 「이미 관리자」 거부 바로 뒤에 브랜드 계정 이메일 검사 1개
--       · brand_accounts.email 이 같거나, 같은 이메일의 인증 사용자가 브랜드 계정이면 → RAISE EXCEPTION 'brand_account_email'
--       · 비교는 lower(btrim()) (함수 첫머리에서 admin_email 을 이미 lower(btrim()) 한다 — 417)
--
-- 오류 방식 (기존 거부와 같게)
--   delete_brand  : 325 가 RAISE EXCEPTION '한국어 문구 %…' USING ERRCODE='22023' 형식 → 같은 형식. 화면
--                   deleteBrandConfirm(admin-brand.js)은 e.message 를 그대로 「삭제 실패: …」 토스트에 싣는다 → 한국어 문구가 그대로 보인다.
--   merge_brands  : 467 의 거부는 RAISE EXCEPTION '…' USING ERRCODE='22023'. 요청대로 코드 문자열 'brand_has_account_links' 를 메시지로 쓴다.
--                   화면 doBrandMerge 는 e.message 를 「병합 실패: …」 토스트에 그대로 싣는다 → 코드 문자열이 그대로 보인다(조각 10 에서 한국어로 매핑).
--   invite_admin  : 417 의 거부는 ERRCODE 없는 RAISE EXCEPTION '영어 문구' → 같은 형식(ERRCODE 생략 = P0001).
--                   화면 admin-accounts.js 는 friendlyError(e.message) 를 쓰는데 이 코드는 매핑이 없어 「처리 중 오류가 발생했습니다 [ERR_UNHANDLED]」 로 보인다(조각 10 에서 매핑).
--
-- 결정: 해제된(released) 연결만 있는 브랜드의 삭제 → 막는다 (지우지 않는다)
--   · brand_account_links.brand_id 는 ON DELETE RESTRICT 라 그대로 두면 외래키 오류(23503)가 나고,
--     화면에는 「연결된 데이터가 있어 처리할 수 없습니다」라는 모호한 문구만 뜬다 → 함수가 먼저 친절하게 막는다.
--   · released 행은 526 가 「이력으로 남긴다」고 정한 감사 기록(누가 이 브랜드를 볼 수 있었나)이다. 삭제 때 함께 지우면
--     그 기록이 조용히 사라진다. 지우는 쪽이 되돌릴 수 없고, 막는 쪽은 병합(원본 archived)으로 우회 가능하므로 막는 쪽이 안전하다.
--   · 병합은 해제 연결만 있는 원본을 막지 않는다(활성만 검사) — 이력은 보관된 원본 브랜드에 남는다.
--
-- 대상 브랜드 쪽 연결: merge_brands 는 p_target 의 brand_account_links 를 읽지도 바꾸지도 않는다 →
--   이동을 받는 쪽에 활성 연결이 있어도 병합은 그대로 된다(아래 시험 T5).
--
-- 롤백 (이 변경만 되돌린다 — DROP 금지)
--   delete_brand : 325_audit_remediation_bundle_i_deletion.sql 의 delete_brand 함수 정의(423~474행) 재실행
--   merge_brands : 467_merge_brands_move_memos.sql 전체 재실행
--   invite_admin : 417_audit_d5_d6_i2_promo_channel_chain_lock_invite_email.sql 의 「I-2」 절(invite_admin 정의, 544~628행)만 재실행
--   (사본 한 벌: 이 파일의 함수 본문에서 [528] 표시 구역을 빼면 베이스와 같다)
--
-- 배포 순서  (사용자 결정 P-1: 브랜드 로그인은 개발서버에서만 동작, 운영 보류)
--   1) 526 → 527 이 먼저 적용돼 있어야 한다.
--   2) 개발서버 SQL 편집기에 이 파일 전체를 실행한다.
--   3) 🔴 운영 주의: 세 함수는 운영에 이미 있다. 526 표(brand_accounts·brand_account_links)가 없는 운영에
--      528 만 들어가면 함수 본문의 표 참조가 첫 호출에서 relation does not exist 로 터져
--      브랜드 삭제·병합·관리자 초대가 전부 깨진다(함수 생성은 표 존재를 검사하지 않아 적용은 Success 로 끝난다).
--      운영 반영 때는 반드시 526 → 527 → 528 순서로, 한 번에, 같은 점검 창에서 한다. 528 단독 적용 금지.
--
-- 적용 뒤 확인 (1단계씩 — 앞 단계 결과를 보고 다음으로)
--   V1 실행 권한이 적용 전후 같은지 — 적용 전에 한 번, 적용 후에 한 번 돌려 두 결과를 눈으로 비교(완전히 같아야 한다):
--        SELECT p.proname, p.prosecdef, p.proconfig::text, p.proacl::text
--          FROM pg_proc p
--         WHERE p.pronamespace = 'public'::regnamespace
--           AND p.proname IN ('delete_brand','merge_brands','invite_admin')
--         ORDER BY 1;
--   V2 원본과 차이가 가드 줄뿐인지 — 로컬 터미널(저장소 루트)에서. 각 함수마다 「>」(추가) 줄만 나오고 「<」(삭제) 줄이 0이어야 한다:
--        f() { sed -n "/^CREATE OR REPLACE FUNCTION public.$2/,/^\$\$;/p" "$1"; }
--        cd supabase/migrations
--        diff <(f 325_audit_remediation_bundle_i_deletion.sql delete_brand) <(f 528_brand_account_guards.sql delete_brand)
--        diff <(f 467_merge_brands_move_memos.sql merge_brands)             <(f 528_brand_account_guards.sql merge_brands)
--        diff <(f 417_audit_d5_d6_i2_promo_channel_chain_lock_invite_email.sql invite_admin) <(f 528_brand_account_guards.sql invite_admin)
--   V3 되돌림 시험 — 개발서버 SQL 편집기. 아래 블록(또는 같은 내용의 별도 파일)을 그대로 실행한다.
--        끝에서 일부러 RAISE EXCEPTION 으로 전부 되돌리므로 오류 화면이 정상이다. 그 오류 문구에 T1~T8 이 모두 「OK」여야 한다.
--        T1 활성 연결 브랜드 삭제 거부 / T2 연결 없는 브랜드 삭제 성공 / T3 해제 연결만 있는 브랜드 삭제 거부 /
--        T4 활성 연결 원본 병합 거부 / T5 연결 있는 브랜드를 대상으로 병합 통과 / T6 해제 연결만 있는 원본 병합 통과 /
--        T7 브랜드 계정 이메일 초대 거부(대소문자·공백 달라도) / T8 일반 이메일 초대 통과
--        (별도 파일: scratchpad 의 527_v3.sql. 아래는 주석 접두를 붙인 같은 내용)
--   DO $t$
--   DECLARE
--     v_admin uuid;
--     v_user  uuid := gen_random_uuid();
--     v_a uuid; v_b uuid; v_c uuid; v_d uuid;
--     v_out text := '';
--     v_res jsonb;
--   BEGIN
--     -- 관리자 흉내: 최고 관리자 한 명을 자동 선택(삭제·병합은 캠페인 관리자 이상, 초대는 최고 관리자만 통과)
--     SELECT auth_id INTO v_admin FROM public.admins WHERE role = 'super_admin' LIMIT 1;
--     IF v_admin IS NULL THEN RAISE EXCEPTION 'super_admin 이 없어 시험할 수 없다'; END IF;
--     PERFORM set_config('request.jwt.claims',
--       jsonb_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
--   
--     -- 시험 계정(인증 사용자 + 브랜드 계정). 전부 마지막 RAISE 로 되돌아간다.
--     INSERT INTO auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
--       confirmation_token,recovery_token,email_change,email_change_token_new,email_change_token_current,
--       phone_change,phone_change_token,reauthentication_token,raw_app_meta_data,raw_user_meta_data)
--     VALUES ('00000000-0000-0000-0000-000000000000', v_user,'authenticated','authenticated',
--       'zz-528-brand@example.invalid','',now(),now(),now(),
--       '','','','','','','','',
--       '{"provider":"email","providers":["email"],"account_kind":"brand"}',
--       jsonb_build_object('sub',v_user::text,'email','zz-528-brand@example.invalid',
--         'email_verified',true,'phone_verified',false));
--     INSERT INTO public.brand_accounts (auth_id, email) VALUES (v_user, 'zz-528-brand@example.invalid');
--   
--     -- 시험 브랜드 넷: A=활성 연결 / B=연결 없음 / C=연결 없음 / D=해제 연결만
--     INSERT INTO public.brands (name) VALUES ('zz-528-A-' || gen_random_uuid()) RETURNING id INTO v_a;
--     INSERT INTO public.brands (name) VALUES ('zz-528-B-' || gen_random_uuid()) RETURNING id INTO v_b;
--     INSERT INTO public.brands (name) VALUES ('zz-528-C-' || gen_random_uuid()) RETURNING id INTO v_c;
--     INSERT INTO public.brands (name) VALUES ('zz-528-D-' || gen_random_uuid()) RETURNING id INTO v_d;
--     INSERT INTO public.brand_account_links (auth_id, brand_id, role) VALUES (v_user, v_a, 'owner');
--     INSERT INTO public.brand_account_links (auth_id, brand_id, role, status, released_at)
--       VALUES (v_user, v_d, 'owner', 'released', now());
--   
--     -- T1 활성 연결 있는 브랜드 삭제 → 거부(「계정 연결」)
--     BEGIN
--       PERFORM public.delete_brand(v_a);
--       v_out := v_out || E'\nT1 FAIL 삭제가 통과했다';
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT1 ' || CASE WHEN SQLERRM LIKE '%계정 연결%' THEN 'OK ' ELSE 'FAIL ' END || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T2 연결 없는 브랜드 삭제 → 성공
--     BEGIN
--       v_res := public.delete_brand(v_b);
--       v_out := v_out || E'\nT2 ' || CASE WHEN (v_res->>'ok') = 'true' THEN 'OK ' ELSE 'FAIL ' END || v_res::text;
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT2 FAIL ' || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T3 해제 연결만 있는 브랜드 삭제 → 거부(이력 보존 문구)
--     BEGIN
--       PERFORM public.delete_brand(v_d);
--       v_out := v_out || E'\nT3 FAIL 삭제가 통과했다';
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT3 ' || CASE WHEN SQLERRM LIKE '%해제된 계정 연결%' THEN 'OK ' ELSE 'FAIL ' END || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T4 활성 연결 있는 브랜드를 원본으로 병합 → 거부
--     BEGIN
--       PERFORM public.merge_brands(v_a, v_c);
--       v_out := v_out || E'\nT4 FAIL 병합이 통과했다';
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT4 ' || CASE WHEN SQLERRM LIKE '%brand_has_account_links%' THEN 'OK ' ELSE 'FAIL ' END || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T5 연결 있는 브랜드(A)를 「대상」으로 병합 → 통과(대상 쪽 연결은 영향 없음)
--     BEGIN
--       v_res := public.merge_brands(v_c, v_a);
--       v_out := v_out || E'\nT5 ' || CASE WHEN (v_res->>'unchanged') = 'false' THEN 'OK ' ELSE 'FAIL ' END || v_res::text;
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT5 FAIL ' || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T6 해제 연결만 있는 브랜드를 원본으로 병합 → 통과
--     BEGIN
--       v_res := public.merge_brands(v_d, v_a);
--       v_out := v_out || E'\nT6 ' || CASE WHEN (v_res->>'unchanged') = 'false' THEN 'OK ' ELSE 'FAIL ' END || v_res::text;
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT6 FAIL ' || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T7 브랜드 계정 이메일(대소문자·공백이 달라도)로 관리자 초대 → 거부
--     BEGIN
--       PERFORM public.invite_admin('  ZZ-528-Brand@Example.invalid ', 'zz 시험', 'campaign_manager');
--       v_out := v_out || E'\nT7 FAIL 초대가 통과했다';
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT7 ' || CASE WHEN SQLERRM LIKE '%brand_account_email%' THEN 'OK ' ELSE 'FAIL ' END || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     -- T8 일반 새 이메일 초대 → 통과(지금처럼)
--     BEGIN
--       PERFORM public.invite_admin('zz-528-normal@example.invalid', 'zz 시험', 'campaign_manager');
--       v_out := v_out || E'\nT8 OK 일반 초대 통과';
--     EXCEPTION WHEN OTHERS THEN
--       v_out := v_out || E'\nT8 FAIL ' || SQLSTATE || ' ' || SQLERRM;
--     END;
--   
--     RAISE EXCEPTION '528 시험 결과 (전부 되돌림, 기대: T1~T8 전부 OK):%', v_out;
--   END
--   $t$;
--   V4 회귀 — 개발서버 관리자 화면에서 눈으로: 연결 없는 시험 브랜드 삭제(성공) · 관리자 초대(기존처럼 메일 발송 흐름까지 진행).
--        ⚠️ 개발서버는 메일을 실제로 보내지 않는 정책이라 초대는 등록 성공(admins 행 생성)까지만 확인한다.
--   ⚠️ 관리자 가드가 걸린 함수라 SQL 편집기(서비스 키)에서는 V3 처럼 jwt 클레임을 흉내 내야 가드 분기가 돈다.
-- ============================================================

BEGIN;

-- ── ① delete_brand — 베이스 325 + 계정 연결 가드 ─────────────

CREATE OR REPLACE FUNCTION public.delete_brand(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camps  bigint;
  v_apps   bigint;
  v_sheets bigint;
  v_exists boolean;
  v_links  bigint;  -- [528] 활성 계정 연결 수
  v_rel    bigint;  -- [528] 해제된 계정 연결(이력) 수
BEGIN
  -- 권한: campaign_admin 이상 (174/191 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;

  SELECT EXISTS(SELECT 1 FROM public.brands WHERE id = p_brand_id) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION '브랜드를 찾을 수 없습니다' USING ERRCODE = '22023';
  END IF;

  -- [325 I-6] 보관 삭제(deleted_at NOT NULL)된 캠페인은 카운트에서 제외.
  -- 30일 뒤 자동 완전삭제되거나 super_admin 이 즉시 완전삭제하면(purge_campaign, 257)
  -- 어차피 행 자체가 사라지므로, 보관 중인 캠페인이 브랜드 삭제를 막을 이유가 없다.
  SELECT count(*) INTO v_camps
    FROM public.campaigns
   WHERE brand_id = p_brand_id
     AND deleted_at IS NULL;
  SELECT count(*) INTO v_apps   FROM public.brand_applications WHERE brand_id = p_brand_id;
  SELECT count(*) INTO v_sheets FROM public.orient_sheets      WHERE brand_id = p_brand_id;

  IF v_camps > 0 OR v_apps > 0 OR v_sheets > 0 THEN
    RAISE EXCEPTION
      '연결된 캠페인 %건, 신청 %건, 오리엔시트 %건이 있어 삭제할 수 없습니다. 병합 기능을 사용하세요.',
      v_camps, v_apps, v_sheets
      USING ERRCODE = '22023';
  END IF;

  -- [528] 브랜드 계정 연결(526). 활성 연결이 있으면 거부, 해제된 연결(이력)만 있어도 거부한다.
  --   brand_account_links.brand_id 가 ON DELETE RESTRICT 라 막지 않으면 외래키 오류(23503)로 터진다.
  --   해제 이력은 「누가 이 브랜드를 볼 수 있었나」 감사 기록이라 지우지 않는다 → 병합을 쓰게 한다.
  SELECT count(*) INTO v_links FROM public.brand_account_links WHERE brand_id = p_brand_id AND status = 'active';
  SELECT count(*) INTO v_rel   FROM public.brand_account_links WHERE brand_id = p_brand_id AND status <> 'active';
  IF v_links > 0 THEN
    RAISE EXCEPTION
      '계정 연결 %건이 있어 삭제할 수 없습니다. 먼저 브랜드 계정 연결을 해제하세요.', v_links
      USING ERRCODE = '22023';
  END IF;
  IF v_rel > 0 THEN
    RAISE EXCEPTION
      '해제된 계정 연결 이력 %건이 있어 삭제할 수 없습니다(이력 보존). 병합 기능을 사용하세요.', v_rel
      USING ERRCODE = '22023';
  END IF;

  DELETE FROM public.brands WHERE id = p_brand_id;

  RETURN jsonb_build_object('ok', true, 'deleted', p_brand_id);
END;
$$;

COMMENT ON FUNCTION public.delete_brand(uuid) IS
  '[174+191+325+528] 브랜드 hard delete (연결 0건 한정). campaign_admin 가드. '
  '연결된 캠페인·신청·오리엔시트가 있으면 22023 + 병합 안내. '
  '[325] 캠페인 카운트에서 보관 삭제(deleted_at NOT NULL)된 캠페인 제외. '
  '[528] 브랜드 계정 연결이 활성이면 22023(계정 연결 N건), 해제 이력만 있어도 22023(이력 보존 — 병합 안내).';

-- ── ② merge_brands — 베이스 467 + 활성 계정 연결 가드 ─────────

CREATE OR REPLACE FUNCTION public.merge_brands(
  p_source uuid,
  p_target uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_source        record;
  v_target        record;

  v_app           record;
  v_old_app_no    text;
  v_new_app_seq   integer;
  v_new_app_no    text;

  v_camp          record;
  v_old_camp_no   text;
  v_new_camp_no   text;
  v_app_seq_parsed integer;
  v_new_camp_seq  integer;
  v_new_ext_seq   integer;
  v_new_app_no_for_camp text;

  v_moved_apps         integer := 0;
  v_moved_campaigns    integer := 0;
  v_moved_orient_sheets integer := 0;  -- [328, I-5]
  v_moved_memos        integer := 0;  -- [467] 영업 메모(brand_memos)
BEGIN
  -- 0. 권한 + 입력 검증 (175 원본과 동일)
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR p_target IS NULL THEN
    RAISE EXCEPTION 'source_id 와 target_id 가 모두 필요합니다' USING ERRCODE = '22023';
  END IF;
  IF p_source = p_target THEN
    RAISE EXCEPTION '원본과 대상이 같은 브랜드입니다' USING ERRCODE = '22023';
  END IF;

  -- 1. 잠금 2단 (uuid 작은 쪽 먼저 — 데드락 회피) (175 원본과 동일)
  IF p_source < p_target THEN
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext(p_target::text)::bigint);
    PERFORM pg_advisory_xact_lock(hashtext(p_source::text)::bigint);
  END IF;

  -- 2. 브랜드 행 조회 (FOR UPDATE) (175 원본과 동일)
  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_source FROM public.brands WHERE id = p_source FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '원본 브랜드를 찾을 수 없습니다: %', p_source USING ERRCODE = '22023';
  END IF;

  SELECT id, name, name_ja, name_en, company_id, brand_seq, status
    INTO v_target FROM public.brands WHERE id = p_target FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION '대상 브랜드를 찾을 수 없습니다: %', p_target USING ERRCODE = '22023';
  END IF;

  -- [528] 원본 브랜드에 활성 브랜드 계정 연결이 있으면 병합 거부.
  --   원본은 병합 뒤 archived 가 되는데 계정은 그 브랜드에 그대로 묶여 있어 로그인한 담당자가
  --   보관된 브랜드를 보게 된다. 연결을 먼저 해제하거나 옮긴 뒤 병합한다.
  --   대상(p_target) 쪽 연결은 보지 않는다 — 대상은 이동을 받는 쪽이라 영향이 없다.
  --   멱등성 판정(4번)보다 앞에 둔다: 보관된 원본에 활성 연결이 남은 비정상 상태도 막는다.
  IF EXISTS (SELECT 1 FROM public.brand_account_links
              WHERE brand_id = p_source AND status = 'active') THEN
    RAISE EXCEPTION 'brand_has_account_links' USING ERRCODE = '22023';
  END IF;

  -- 3. 회사 검증 없음 (175 원본과 동일, 무변경)

  -- [328, I-5] 4. 멱등성 — source 이미 archived + 연결 0건(신청·캠페인·오리엔시트
  --   모두)이면 no-op. orient_sheets 를 새로 추가한 것이 이 파일의 핵심 변경점 —
  --   위 파일 상단 "멱등성 체크에 orient_sheets 추가(필수)" 참고.
  IF v_source.status = 'archived'
     AND NOT EXISTS (SELECT 1 FROM public.brand_applications WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.campaigns          WHERE brand_id = p_source)
     AND NOT EXISTS (SELECT 1 FROM public.orient_sheets      WHERE brand_id = p_source)
     -- [467] 메모만 남은 보관 브랜드가 재호출에서 안 옮겨지는 함정을 막는다(328 이 오리엔시트에서 겪은 것과 같다)
     AND NOT EXISTS (SELECT 1 FROM public.brand_memos       WHERE brand_id = p_source)
  THEN
    RETURN jsonb_build_object(
      'source_id', p_source, 'target_id', p_target,
      'moved_apps', 0, 'moved_campaigns', 0, 'moved_orient_sheets', 0, 'moved_memos', 0,
      'source_archived', true, 'unchanged', true);
  END IF;

  -- 5. ① 신청 이동 + A-seq 재발급 (175 원본과 동일)
  FOR v_app IN
    SELECT id, application_no, legacy_no
      FROM public.brand_applications
     WHERE brand_id = p_source
     ORDER BY created_at
  LOOP
    v_old_app_no := v_app.application_no;

    INSERT INTO public.brand_application_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_application_counter.last_seq + 1
    RETURNING last_seq INTO v_new_app_seq;

    IF v_new_app_seq > 999 THEN
      RAISE EXCEPTION 'A-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_app_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                 || '-A' || lpad(v_new_app_seq::text, 3, '0');

    UPDATE public.brand_applications
       SET brand_id = p_target,
           application_no = v_new_app_no,
           legacy_no = public._accumulate_legacy_no(v_app.legacy_no, v_old_app_no)
     WHERE id = v_app.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('brand_application', v_app.id, COALESCE(v_app.legacy_no, v_old_app_no), v_new_app_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_apps := v_moved_apps + 1;
  END LOOP;

  -- 6. ② 신청 파생 캠페인 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT c.id, c.campaign_no, c.legacy_no, c.source_application_id
      FROM public.campaigns c
      JOIN public.brand_applications ba ON ba.id = c.source_application_id
     WHERE ba.brand_id = p_target
       AND c.brand_id  = p_source
     ORDER BY c.created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    SELECT application_no INTO v_new_app_no_for_camp
      FROM public.brand_applications WHERE id = v_camp.source_application_id;

    IF v_new_app_no_for_camp SIMILAR TO 'B[0-9]{4}-A[0-9]{3}' THEN
      v_app_seq_parsed := split_part(v_new_app_no_for_camp, '-A', 2)::integer;
    ELSE
      RAISE EXCEPTION '신청번호 형식이 예상과 다릅니다: % (기대값 B####-A###)', v_new_app_no_for_camp
        USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.application_campaign_counter (application_id, last_seq)
    VALUES (v_camp.source_application_id, 1)
    ON CONFLICT (application_id)
    DO UPDATE SET last_seq = public.application_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_camp_seq;

    IF v_new_camp_seq > 999 THEN
      RAISE EXCEPTION 'C-seq 오버플로 (>999): application_id=%', v_camp.source_application_id USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-A' || lpad(v_app_seq_parsed::text, 3, '0')
                  || '-C' || lpad(v_new_camp_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- 7. ③ 외부 캠페인(source_application_id NULL) 이동 + 재채번 (175 원본과 동일)
  FOR v_camp IN
    SELECT id, campaign_no, legacy_no
      FROM public.campaigns
     WHERE brand_id = p_source AND source_application_id IS NULL
     ORDER BY created_at
  LOOP
    v_old_camp_no := v_camp.campaign_no;

    INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
    VALUES (p_target, 1)
    ON CONFLICT (brand_id)
    DO UPDATE SET last_seq = public.brand_external_campaign_counter.last_seq + 1
    RETURNING last_seq INTO v_new_ext_seq;

    IF v_new_ext_seq > 999 THEN
      RAISE EXCEPTION '외부 C-seq 오버플로 (>999): target brand_id=%', p_target USING ERRCODE = '22003';
    END IF;

    v_new_camp_no := 'B' || lpad(v_target.brand_seq::text, 4, '0')
                  || '-C' || lpad(v_new_ext_seq::text, 3, '0');

    UPDATE public.campaigns
       SET brand_id = p_target,
           campaign_no = v_new_camp_no,
           legacy_no = public._accumulate_legacy_no(v_camp.legacy_no, v_old_camp_no),
           updated_at = now()
     WHERE id = v_camp.id;

    INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
    VALUES ('campaign', v_camp.id, COALESCE(v_camp.legacy_no, v_old_camp_no), v_new_camp_no, now())
    ON CONFLICT (entity_type, entity_id)
    DO UPDATE SET new_no = EXCLUDED.new_no, migrated_at = now();

    v_moved_campaigns := v_moved_campaigns + 1;
  END LOOP;

  -- [328, I-5] 7-2. 오리엔시트 이동 — brand_id 만 옮긴다(재채번 없음, 위 파일
  --   상단 "orient_no 를 재채번하지 않는 이유" 참고). 캠페인·신청 이동이 모두
  --   끝난 뒤에 옮기지만, 사실 순서와 무관하게 안전하다(orient_sheets 는 다른
  --   테이블의 이동 로직에 값을 공급하지도, 그로부터 값을 받지도 않는다 —
  --   application_id 참조는 이미 ①에서 옮겨진 brand_applications.id 를 그대로
  --   가리키므로 무변경으로 계속 유효하다).
  UPDATE public.orient_sheets
     SET brand_id   = p_target,
         updated_at = now()
   WHERE brand_id = p_source;
  GET DIAGNOSTICS v_moved_orient_sheets = ROW_COUNT;

  -- 8. ④ 이동된(+기존) target 캠페인 비정규화 컬럼 동기화 (175 원본과 동일)
  UPDATE public.campaigns
     SET brand = v_target.name, brand_ja = v_target.name_ja, brand_en = v_target.name_en,
         updated_at = now()
   WHERE brand_id = p_target;

  -- 9. ⑤ 원본 보관 처리 (175 원본과 동일)
  -- [467] 영업 메모를 대상 브랜드로 옮긴다(사용자 결정 2026-09-23).
  --   🔴 본문 앞에 **어느 브랜드 시절 글인지**를 남긴다 — 안 남기면 두 브랜드 기록이 한 줄에 섞여
  --      나중에 구분할 방법이 없다. 되돌릴 수 없는 함수라 이 표시가 유일한 단서다.
  --   ⚠️ author_id·author_name 은 **그대로 둔다**(누가 썼는지는 병합과 무관하다).
  --   ⚠️ 이미 표시가 붙은 글에는 또 붙이지 않는다(두 번 병합된 브랜드에서 접두가 겹친다).
  --   ⚠️ updated_at 트리거가 돌아 「수정됨」으로 보이는 것은 감수한다 — 본문이 실제로 바뀌기 때문이다.
  UPDATE public.brand_memos
     SET brand_id  = p_target,
         body_html = CASE
           WHEN body_html LIKE '<p>(구 %' THEN body_html
           ELSE '<p>(구 ' || COALESCE(v_source.name, '이름 없음') || ')</p>' || body_html
         END
   WHERE brand_id = p_source;
  GET DIAGNOSTICS v_moved_memos = ROW_COUNT;

  UPDATE public.brands SET status = 'archived' WHERE id = p_source;

  RETURN jsonb_build_object(
    'source_id', p_source, 'target_id', p_target,
    'moved_apps', v_moved_apps, 'moved_campaigns', v_moved_campaigns,
    'moved_orient_sheets', v_moved_orient_sheets,  -- [328, I-5] 신규
    'moved_memos', v_moved_memos,                  -- [467] 신규
    'source_archived', true, 'unchanged', false);
END;
$$;

COMMENT ON FUNCTION public.merge_brands(uuid, uuid) IS
  '[467+528] 브랜드 병합 — 신청·캠페인·오리엔시트·영업 메모를 대상 브랜드로 옮기고 채번을 재발급한다. '
  '원본은 archived. is_campaign_admin 가드. 멱등성 판정에 brand_applications·campaigns·'
  'orient_sheets·brand_memos 존재 여부를 모두 본다(328 + 467). '
  '메모는 본문 앞에 「(구 원본브랜드명)」 을 붙여 어느 브랜드 시절 글인지 남긴다. '
  '[528] 원본에 활성 브랜드 계정 연결이 있으면 brand_has_account_links 로 거부(대상 쪽 연결은 영향 없음).';

-- ── ③ invite_admin — 베이스 417 + 브랜드 계정 이메일 가드 ─────

CREATE OR REPLACE FUNCTION public.invite_admin(admin_email text, admin_name text, admin_role text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  existing_user_id uuid;
  new_user_id       uuid;
  target_user_id    uuid;
  temp_password     text;
  is_promotion      boolean := false;
BEGIN
  -- [417] 이메일은 대소문자·앞뒤 공백을 무시한다(전수조사 I-2). 예전엔 `email = admin_email`
  --   글자 그대로 비교라 대소문자가 다르면 기존 계정을 못 찾아 「신규」 갈래로 가고(유일 제약에
  --   걸림), admins 중복 검사도 못 잡았다. 인증 서비스가 저장하는 대소문자와 **무관하게** 이 함수가
  --   양쪽을 소문자로 맞춰 비교·저장하므로 안전하다(CLAUDE.md 가 화면 조회에 ilike 를 쓰는 이유와 같다).
  admin_email := lower(btrim(admin_email));
  IF NOT EXISTS (SELECT 1 FROM public.admins WHERE auth_id = auth.uid() AND role = 'super_admin') THEN
    RAISE EXCEPTION 'Permission denied: super_admin only';
  END IF;

  IF EXISTS (SELECT 1 FROM public.admins WHERE lower(email) = admin_email) THEN
    RAISE EXCEPTION 'Admin with this email already exists';
  END IF;

  -- [528] 브랜드 계정(526)의 이메일이면 관리자로 초대·승격하지 않는다(사용자 결정 P-10).
  --   브랜드 담당자가 관리자 권한을 얻는 경로를 막는다. 세 갈래를 본다:
  --   ① brand_accounts.email 이 같다  ② 인증 사용자 중 이메일이 같은 사람이 브랜드 계정이다(승격 갈래).
  IF EXISTS (SELECT 1 FROM public.brand_accounts ba
              WHERE lower(btrim(ba.email)) = admin_email
                 OR ba.auth_id IN (SELECT u.id FROM auth.users u WHERE lower(btrim(u.email)) = admin_email))
     -- ③ 앱 메타데이터에 브랜드 표시만 있고 brand_accounts 행이 아직 없는 순간(526 [C] 와 같은 틈 — 528 리뷰 권고)
     OR EXISTS (SELECT 1 FROM auth.users u
                 WHERE lower(btrim(u.email)) = admin_email
                   AND u.raw_app_meta_data->>'account_kind' = 'brand') THEN
    RAISE EXCEPTION 'brand_account_email';
  END IF;

  SELECT id INTO existing_user_id FROM auth.users WHERE lower(email) = admin_email LIMIT 1;

  IF existing_user_id IS NOT NULL THEN
    -- ────────────────────────────────────────────────────────
    -- 승격: 기존 계정(주로 인플루언서)을 관리자로 올린다.
    -- [245] 비밀번호는 절대 건드리지 않는다 — 이미 본인이 쓰고 있는 유효한 비밀번호를
    -- 덮어쓸 기술적 필요가 없다(031 원본은 여기서 encrypted_password 를 임시 랜덤값으로
    -- 덮어써 그 사람의 기존 로그인을 즉시 끊었다).
    -- 로그인 차단 방지용 메타데이터 보정만 유지 — 전부 COALESCE 라 기존 값이 있으면
    -- 그대로 두고, 비어 있던 값만 채운다(부작용 없음).
    -- ────────────────────────────────────────────────────────
    is_promotion := true;

    UPDATE auth.users
       SET email_confirmed_at = COALESCE(email_confirmed_at, now()),
           email_change       = COALESCE(email_change, ''),
           raw_app_meta_data  = COALESCE(raw_app_meta_data, jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')))
     WHERE id = existing_user_id;

    target_user_id := existing_user_id;
  ELSE
    -- 신규 생성: 기존 031 동작과 완전히 동일. 임시 32자 랜덤 비밀번호(받는 사람은
    -- 초대 메일 링크로만 로그인 가능 — 이 경로가 유일한 로그인 수단이므로 여기서만
    -- temp_password 를 생성한다).
    temp_password := encode(extensions.gen_random_bytes(24), 'base64');

    new_user_id := gen_random_uuid();
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
      new_user_id, 'authenticated', 'authenticated', admin_email,
      extensions.crypt(temp_password, extensions.gen_salt('bf', 10)),
      now(), now(), now(),
      '', '', '', '', '', '', '', '',
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true, 'phone_verified', false)
    );
    INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, created_at, updated_at)
    VALUES (
      gen_random_uuid(), new_user_id,
      jsonb_build_object('sub', new_user_id::text, 'email', admin_email, 'email_verified', true),
      'email', new_user_id::text, now(), now()
    );
    target_user_id := new_user_id;
  END IF;

  INSERT INTO public.admins (auth_id, email, name, role, promoted_at)
  VALUES (target_user_id, admin_email, admin_name, admin_role, CASE WHEN is_promotion THEN now() ELSE NULL END);

  RETURN target_user_id;
END;
$$;

COMMENT ON FUNCTION public.invite_admin(text, text, text) IS
  '[245+417+528] 관리자 초대. 기존 auth.users 계정 승격 시 비밀번호를 덮어쓰지 않음(031 원본은 '
  '임시 랜덤값으로 덮어써 기존 로그인을 끊었음). 승격 여부는 admins.promoted_at 에 기록. '
  '신규 생성 분기는 031 원본과 동일(임시 랜덤 비밀번호 + auth.identities 생성). '
  '[417] 이메일 lower(btrim()) 정규화. [528] 브랜드 계정(brand_accounts) 이메일이면 brand_account_email 로 거부.';

COMMIT;
