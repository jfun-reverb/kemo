-- ============================================================
-- 542_orient_close_token_link_form.sql
-- 2026-10-19 — 오리엔시트 옛 「토큰 링크 작성 폼」 서버 경로 닫기
--   작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 「작업 9」·결정 16
--
-- 목적
--   오리엔시트 작성은 이제 브랜드 페이지(로그인 계정 함수 540·541)에서만 한다.
--   옛 토큰 링크 폼(dev/sales/orient.html)이 부르던 서버 경로를 닫는다.
--   견적서 끼워 넣기 모드(?embed=quote)는 서버를 안 쓰므로 영향 없음.
--
-- 바꾸는 것 (이름·인자·반환형·LANGUAGE·SECURITY DEFINER·search_path·변동성·권한 전부 원본 그대로 — CREATE OR REPLACE 만, DROP 없음)
--   [A] 토큰 함수 다섯이 무조건 {"success":false,"reason":"moved"} 를 돌려준다
--       get_orient_sheet(uuid)                          원본 524 (VOLATILE)
--       save_orient_draft(uuid, jsonb, int)             원본 539 (VOLATILE)
--       submit_orient_sheet(uuid, jsonb, int)           원본 539 (VOLATILE)
--       preview_orient_quote(uuid, jsonb)               원본 539 (VOLATILE)
--       get_orient_tier_fees(uuid)                      원본 539 (STABLE)
--   [B] orient_token_can_upload(text)  원본 200 (STABLE) — 늘 false
--       (정책 orient_images_anon_insert 는 지우지 않는다 — 허가 함수만 거짓 고정)
--   [C] orient_lookup_gate(text)       원본 428 — 늘 false
--       (서버 함수 qoo10-product-lookup 의 옛 토큰 갈래가 이것으로 막힌다. 서버 함수는 고치지 않는다.
--        계정 갈래 orient_lookup_gate_account(541)는 건드리지 않는다)
--   ※ 본체 *_core 함수(_orient_save_core 등)는 로그인 계정 함수(540)가 쓰므로 그대로 둔다.
--
-- 🔴 운영 적용 순서
--   ① 브랜드 페이지(오리엔시트 탭)와 orient.html 의 이동 코드가 운영에 반영된 것을 확인한다.
--      🔴 orient.html 의 이동 갈래는 운영 주소에서 막혀 있다(`token && SUPABASE_ENV !== 'production'`).
--         **그 막음을 걷는 코드가 운영 sales 에 반영되고, 운영 옛 링크가 브랜드 페이지로 실제로 넘어가는 것을 눈으로 확인한 뒤에만**
--         이 파일을 적용한다. 막음을 둔 채 이 파일만 넣으면 운영 링크 폼 사용자는 이동 없이 「옮겨 감」 안내 화면에서 멈춘다.
--   ② 그 뒤에 이 파일을 적용한다. 반대면 옛 링크 폼이 오류 화면이 된다.
--   개발서버: sales-dev 의 orient.html 이동 코드 반영을 확인한 뒤 적용한다.
--
-- 권한: CREATE OR REPLACE 는 기존 실행 권한을 보존하므로 REVOKE/GRANT 를 새로 걸지 않는다(끝의 확인 조회 [3]으로 확인).
--   ⚠️ orient_lookup_gate 를 DROP 하면 428 의 service_role 전용 권한이 풀리니 절대 DROP 하지 말 것.
--
-- 롤백(함수 본문만 되돌린다 — 권한은 그대로)
--   토큰 함수 넷(save_orient_draft · submit_orient_sheet · preview_orient_quote · get_orient_tier_fees)
--     → 539_orient_core_functions.sql 「[7] 토큰 함수 넷」 블록(765행~900행 부근)의 CREATE OR REPLACE 넷을 다시 실행
--   get_orient_sheet → 524_orient_sheet_draft_functions.sql 「[A] get_orient_sheet」 블록(39행~, 함수 하나)을 다시 실행
--   orient_token_can_upload → 200_orient_upload_bucket_and_policy.sql 의 CREATE OR REPLACE FUNCTION 블록(95행~)을 다시 실행
--   orient_lookup_gate → 428_orient_lookup_gate.sql 「[B] 관문 함수」 블록(40행~)을 다시 실행
--   (GRANT/REVOKE 줄은 다시 실행하지 않아도 된다)
--
-- 🔴 다음 재정의의 베이스는 이 파일(542) — 위 아홉 함수를 또 고치면 524·539·200·428 이 아니라 여기서 시작한다
--   (되살릴 때는 위 롤백 블록으로).
-- ============================================================

BEGIN;

-- [A] 토큰 함수 다섯 — 토큰 인자를 쓰지 않고 바로 moved
CREATE OR REPLACE FUNCTION public.get_orient_sheet(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object('success', false, 'reason', 'moved');
END;
$$;

CREATE OR REPLACE FUNCTION public.save_orient_draft(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object('success', false, 'reason', 'moved');
END;
$$;

CREATE OR REPLACE FUNCTION public.submit_orient_sheet(
  p_token   uuid,
  p_data    jsonb,
  p_version int
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object('success', false, 'reason', 'moved');
END;
$$;

CREATE OR REPLACE FUNCTION public.preview_orient_quote(p_token uuid, p_data jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object('success', false, 'reason', 'moved');
END;
$$;

CREATE OR REPLACE FUNCTION public.get_orient_tier_fees(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN jsonb_build_object('success', false, 'reason', 'moved');
END;
$$;

-- [B] 업로드 허가 — 늘 false (정책 orient_images_anon_insert 는 그대로 둔다)
CREATE OR REPLACE FUNCTION public.orient_token_can_upload(p_token text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN false;
END;
$$;

-- [C] 큐텐 관문(토큰 갈래) — 늘 false
CREATE OR REPLACE FUNCTION public.orient_lookup_gate(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  RETURN false;
END;
$$;

COMMENT ON FUNCTION public.get_orient_sheet(uuid) IS
  '[542] 옛 토큰 링크 폼 서버 경로 닫음 — 늘 {"success":false,"reason":"moved"}. 작성은 브랜드 페이지(540). 되살릴 베이스는 524.';
COMMENT ON FUNCTION public.save_orient_draft(uuid, jsonb, int) IS
  '[542] 옛 토큰 링크 폼 서버 경로 닫음 — 늘 moved. 되살릴 베이스는 539([7] 블록). 본체 _orient_save_core 는 540 계정 함수가 쓴다.';
COMMENT ON FUNCTION public.submit_orient_sheet(uuid, jsonb, int) IS
  '[542] 옛 토큰 링크 폼 서버 경로 닫음 — 늘 moved. 되살릴 베이스는 539([7] 블록). 본체 _orient_submit_core 는 540 계정 함수가 쓴다.';
COMMENT ON FUNCTION public.preview_orient_quote(uuid, jsonb) IS
  '[542] 옛 토큰 링크 폼 서버 경로 닫음 — 늘 moved. 되살릴 베이스는 539([7] 블록).';
COMMENT ON FUNCTION public.get_orient_tier_fees(uuid) IS
  '[542] 옛 토큰 링크 폼 서버 경로 닫음 — 늘 moved. 되살릴 베이스는 539([7] 블록).';
COMMENT ON FUNCTION public.orient_token_can_upload(text) IS
  '[542] 늘 false — 옛 토큰 업로드 닫음(정책 orient_images_anon_insert 는 남겨 둠). 되살릴 베이스는 200.';
COMMENT ON FUNCTION public.orient_lookup_gate(text) IS
  '[542] 늘 false — 큐텐 상품 읽기의 옛 토큰 갈래 닫음. service_role 전용 권한 유지. 되살릴 베이스는 428. 계정 갈래는 orient_lookup_gate_account(541).';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 개발서버 확인 (개발 SQL 편집기 — 한 단계씩 실행하고 결과를 본 뒤 다음으로. 이 아래는 전부 주석)
-- ============================================================
-- [1] 다섯 함수 호출 — 전부 {"success": false, "reason": "moved"} 여야 한다
--   SELECT public.get_orient_sheet(gen_random_uuid())                       AS a,
--          public.save_orient_draft(gen_random_uuid(), '{}'::jsonb, 1)      AS b,
--          public.submit_orient_sheet(gen_random_uuid(), '{}'::jsonb, 1)    AS c,
--          public.preview_orient_quote(gen_random_uuid(), '{}'::jsonb)      AS d,
--          public.get_orient_tier_fees(gen_random_uuid())                   AS e;
--
-- [2] 두 관문 — 둘 다 false
--   SELECT public.orient_token_can_upload(gen_random_uuid()::text) AS can_upload,
--          public.orient_lookup_gate(gen_random_uuid()::text)      AS gate;
--
-- [3] 권한이 이전과 같은지 — proacl 을 본다(맨 앞 `=X/` 가 없어야 PUBLIC 부여 없음)
--   기대: get_orient_sheet · save_orient_draft · submit_orient_sheet 등 토큰 폼 함수는 anon(authenticated) 부여 유지,
--         orient_lookup_gate 는 postgres·service_role 만(anon·authenticated 없음)
--   SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.provolatile, p.prosecdef, p.proacl::text
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('get_orient_sheet','save_orient_draft','submit_orient_sheet','preview_orient_quote',
--                        'get_orient_tier_fees','orient_token_can_upload','orient_lookup_gate')
--    ORDER BY p.proname;
--   (같은 이름이 두 줄 이상 나오면 인자가 다른 오버로드가 남아 있는 것)
