-- ============================================================
-- 574_brand_contact_row_functions.sql
-- 관리자 브랜드 상세 탭 재구성 — 작업 2(담당자 한 줄 저장·삭제 · 사양서 5-2)
-- 사양서: docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 docs/specs/2026-10-21-admin-brand-detail-tabs-breakdown.md
--
-- 왜: 관리자 화면이 담당자 목록(brands.contacts)을 통째로 덮어써서, 그사이 서버가 옮긴 대표 표시(531)나
--   다른 관리자가 고친 줄이 사라진다. 담당자를 「한 줄씩」 저장·삭제하는 서버 함수로 바꾼다.
--
-- 만드는 것
--   1) _brand_set_contacts(brand, contacts)            — 내부 전용. 담당자 목록 저장 + 옛 대표 칸 셋
--      (primary_contact_name·primary_phone·primary_email)을 대표 줄로 맞춘다. 🔴 서버가 contacts 를 고치는 자리는
--      이 함수를 부른다(맞추는 규칙 한 곳). 브랜드 목록 「대표 담당자」 열이 옛 칸 셋을 읽는다.
--   2) _brand_contacts_locked(brand) → boolean         — 내부 전용. 「계정이 있는 동안」 판정 한 곳.
--      지금은 「활성 대표 연결 있음」. 🔴 연결 요청(별도 작업표)이 「살아 있는 요청」을 OR 로 더해 재정의한다.
--   3) admin_save_brand_contact(brand, contact_id, name, phone, email, is_primary) → jsonb
--   4) admin_delete_brand_contact(brand, contact_id) → jsonb
--   5) _brand_contacts_mark_primary 재정의(베이스 531) — 마지막 UPDATE 를 _brand_set_contacts 로(작업표 M1 —
--      지금은 contacts 만 고쳐 옛 대표 칸 셋이 옛 사람으로 남는다). 나머지 본문은 531 글자 그대로.
--   6) 아이디 없는 담당자 줄에 아이디 붙이기(멱등 — 빈 아이디 줄만)
--
-- 결과 값 (둘 다 jsonb {result, contact_id?, contacts?} — contacts 는 ok 일 때만, 저장 뒤 배열 전체)
--   save:   ok · forbidden(관리자 아님) · brand_not_found · contact_not_found · name_required · invalid_email
--           · primary_email_required(대표 줄인데 이메일 빔) · primary_required(계정 없는 브랜드에서 유일한 대표 줄의
--             표시만 끔 — 대표가 0명이 된다. 작업표 기본값 8 의 추가 거부) · primary_locked(계정이 있는 동안
--             대표 줄 이메일 변경·대표 해제) · primary_move_needs_owner_change(계정이 있는 동안 다른 줄을 대표로 —
--             화면은 a03-02 「대표 담당자 바꾸기」로 보낸다)
--   delete: ok · forbidden · brand_not_found · contact_not_found · primary_locked
--
-- 규칙
--   · 가드 is_admin()(지금 brands 직접 쓰기 정책 082 와 같은 기준 — 캠페인 매니저 포함)
--   · 브랜드 잠금은 527·531·533 과 같은 열쇠 pg_advisory_xact_lock(hashtext('brand_account_upsert:' || brand))
--   · 줄 아이디는 글자(text) — uuid 가 아닌 옛 아이디(c-<시각>-<난수>, k1 등)가 있다. 새 줄은 gen_random_uuid()::text
--   · 새 줄: 계정이 없고 대표 줄이 없으면(첫 줄 포함) 자동 대표(작업표 기본값 2). 계정이 있는 동안 새 줄은 대표가 될 수 없다
--   · 기존 줄의 p_is_primary 가 NULL 이면 지금 대표 여부를 유지한다(화면이 빠뜨려도 대표가 풀리지 않게)
--   · 삭제로 대표가 넘어간 줄은 이메일 검사를 하지 않는다(지금 화면 removeBrandContact 규칙과 같다 — 이메일 빈 대표가 생길 수 있다)
--   · 계정 없을 때 대표를 이 줄로 옮기면 같은 호출에서 옛 대표 표시를 끈다. 메일·연결 요청 없음
--   · 삭제: 계정 없을 때 대표 줄을 지우면 남은 첫 줄이 대표(기본값 2)
--   · 줄의 다른 열쇠(있다면)는 보존하고 name·phone·email·is_primary 만 바꾼다. 빈 칸은 '' 로 저장(화면 형식과 같다)
--   · 🔴 S7=B(2026-10-21 사용자 결정 — 함께 바꾸기): 저장한 줄이 대표 줄이고 활성 대표 계정의 이메일과 같으면
--     (대소문자·앞뒤 공백 무시) brand_accounts 의 이름·연락처도 맞춘다 — **호출자가 has_permission('brand.account_manage','write')
--     일 때만**(매니저가 저장하면 담당자 목록만 바뀐다). 533 같은-이메일 갈래가 하던 일을 옮긴 것이다(근거 줄 아이디도 맞춘다).
--     본인이 마이페이지에서 고친 이름이 관리자 저장으로 덮일 수 있다(사용자가 알고 고름). 멤버 줄은 계정을 건드리지 않는다
--
-- 알고 있는 것
--   · 091 admin_create_brand_application 의 대표 줄 덮기(정의자 권한)는 이 잠금을 모른다 — 생성 단추가 비활성이라 지금은 도달하지 않는다
--   · 087·397 공개 신청서는 새 브랜드 삽입 때만 contacts 를 쓴다(이 잠금과 무관)
--   · 화면 직접 쓰기(saveBrandDetail·osSaveIssuedContact)는 작업 15 가 서버에서 막는다
--
-- 선결 S4 데이터 셈(2026-10-21, 아이디 없는 담당자 줄): 개발서버 브랜드 44 · 아이디 없음 0 · 겹침 0 · 대표 둘 이상 0
--   · 일반 형식 아닌 아이디 4 / 운영서버 브랜드 81 · 전부 0 → 6) 은 지금 바뀌는 줄이 없다(앞으로 생길 줄 대비 + 멱등)
--
-- 🔴 다음에 _brand_contacts_mark_primary 를 다시 정의할 때 베이스는 이 파일(531 베이스 금지 — 옛 대표 칸 맞추기가 사라진다).
-- 편집기 경고: 확인 못 함(2026-10-21 개발서버 적용 — 편집기 화면이 「Running」에 멈췄으나 기록 표 574 줄 12:28:34 JST·함수 다섯·권한 확인)
-- 개발서버 실제 호출(2026-10-21, 로그인 관리자 콘솔 · 시험 브랜드 「시험브랜드0923…」 — 끝난 뒤 이 함수로 비우고 계정 해제, 원래 상태 확인):
--   계정 없음: 첫 줄 자동 대표 · 새 줄 대표 지정·기존 줄 대표 이동 시 옛 표시 꺼짐 · 유일한 대표 해제 primary_required
--     · p_is_primary NULL 은 지금 값 유지 · 대표 줄 삭제 시 남은 줄 대표 · 옛 대표 칸 셋 맞춰짐 · contact_not_found·name_required·invalid_email
--   계정 있음(설정 전 대표): 대표 줄 이메일 변경·해제 primary_locked · 새 줄·다른 줄 대표 primary_move_needs_owner_change
--     · 대표 줄 삭제 primary_locked · 다른 줄 삭제 ok · 최고 관리자가 대표 줄 이름·연락처 변경 → 계정 이름·연락처도 바뀜(S7=B)
--   캠페인 매니저(SQL 편집기에서 manager.test 로 흉내 — is_admin true · 계정 관리 권한 false): 대표 줄 이름 변경 ok, 계정 이름 그대로
--   (시험 중 만든 로그인 계정 zz-574-b@example.com 은 지울 함수가 없어 남는다 — 연결 없음)
-- 롤백: DROP FUNCTION admin_save_brand_contact(uuid,text,text,text,text,boolean), admin_delete_brand_contact(uuid,text),
--   _brand_contacts_locked(uuid) → 531 의 _brand_contacts_mark_primary 블록(381~436줄) 재실행 → DROP FUNCTION _brand_set_contacts(uuid,jsonb).
--   (🔴 화면 작업 12 를 먼저 되돌린다) 아이디 부여는 되돌리지 않는다(무해)
-- ============================================================
BEGIN;

-- ── 1. 담당자 목록 저장 + 옛 대표 칸 셋 맞추기 (내부 전용) ──────────────
CREATE OR REPLACE FUNCTION public._brand_set_contacts(p_brand_id uuid, p_contacts jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_contacts jsonb := CASE WHEN jsonb_typeof(p_contacts) = 'array' THEN p_contacts ELSE '[]'::jsonb END;
  v_prim     jsonb;
BEGIN
  SELECT e.elem INTO v_prim
    FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
   WHERE jsonb_typeof(e.elem) = 'object' AND e.elem->>'is_primary' = 'true'
   ORDER BY e.ord
   LIMIT 1;

  UPDATE public.brands
     SET contacts             = v_contacts,
         primary_contact_name = NULLIF(btrim(COALESCE(v_prim->>'name',  '')), ''),
         primary_phone        = NULLIF(btrim(COALESCE(v_prim->>'phone', '')), ''),
         primary_email        = NULLIF(btrim(COALESCE(v_prim->>'email', '')), '')
   WHERE id = p_brand_id;
END;
$$;

COMMENT ON FUNCTION public._brand_set_contacts(uuid, jsonb) IS
  '[574] 내부 도우미. brands.contacts 저장 + 옛 대표 칸 셋(primary_contact_name·primary_phone·primary_email)을 대표 줄(is_primary 첫 줄)로 맞춘다(대표 줄 없으면 셋 다 NULL). 서버가 contacts 를 고치는 자리는 이것을 부른다. 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_set_contacts(uuid, jsonb) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_set_contacts(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_set_contacts(uuid, jsonb) FROM anon, authenticated;

-- ── 2. 「계정이 있는 동안」 판정 (내부 전용 — 판정 한 곳) ─────────────────
CREATE OR REPLACE FUNCTION public._brand_contacts_locked(p_brand_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.brand_account_links l
     WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active');
$$;

COMMENT ON FUNCTION public._brand_contacts_locked(uuid) IS
  '[574] 내부 판정. 브랜드 담당자 대표 줄이 잠기는 동안인가 — 지금은 활성 대표 연결 있음. 연결 요청(별도 작업표)이 살아 있는 요청을 OR 로 더해 재정의한다. 화면(bdOwnerLocked)은 상태 조회 값을 읽기만. 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_contacts_locked(uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_locked(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_locked(uuid) FROM anon, authenticated;

-- ── 3. 담당자 한 줄 저장 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_save_brand_contact(
  p_brand_id   uuid,
  p_contact_id text,
  p_name       text,
  p_phone      text,
  p_email      text,
  p_is_primary boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_contacts  jsonb;
  v_locked    boolean;
  v_cid       text := NULLIF(btrim(COALESCE(p_contact_id, '')), '');
  v_name      text := btrim(COALESCE(p_name,  ''));
  v_phone     text := btrim(COALESCE(p_phone, ''));
  v_email     text := btrim(COALESCE(p_email, ''));
  v_idx       integer;            -- 0 부터 — 고칠 줄 위치(새 줄이면 NULL)
  v_prim_idx  integer;            -- 0 부터 — 지금 대표 줄 위치(없으면 NULL)
  v_old       jsonb;
  v_make_prim boolean;
  v_new_row   jsonb;
  v_link      public.brand_account_links%ROWTYPE;
  v_acct      public.brand_accounts%ROWTYPE;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT COALESCE(b.contacts, '[]'::jsonb) INTO v_contacts
    FROM public.brands b WHERE b.id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found');
  END IF;
  IF jsonb_typeof(v_contacts) <> 'array' THEN v_contacts := '[]'::jsonb; END IF;

  IF v_name = '' THEN
    RETURN jsonb_build_object('result', 'name_required');
  END IF;
  IF v_email <> '' AND (length(v_email) > 254 OR v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN
    RETURN jsonb_build_object('result', 'invalid_email');
  END IF;

  v_locked := public._brand_contacts_locked(p_brand_id);

  SELECT (e.ord - 1)::int INTO v_prim_idx
    FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
   WHERE jsonb_typeof(e.elem) = 'object' AND e.elem->>'is_primary' = 'true'
   ORDER BY e.ord LIMIT 1;

  IF v_cid IS NOT NULL THEN
    SELECT (e.ord - 1)::int INTO v_idx
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
     WHERE jsonb_typeof(e.elem) = 'object' AND NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') = v_cid
     ORDER BY e.ord LIMIT 1;
    IF v_idx IS NULL THEN
      RETURN jsonb_build_object('result', 'contact_not_found');
    END IF;
    v_old := v_contacts -> v_idx;
  END IF;

  -- 이 줄이 저장 뒤 대표인가
  IF v_idx IS NULL THEN
    -- 새 줄: 계정 없고 대표 줄이 없으면 자동 대표
    v_make_prim := COALESCE(p_is_primary, false) OR (NOT v_locked AND v_prim_idx IS NULL);
  ELSE
    -- 기존 줄: 값이 안 오면(NULL) 지금 대표 여부 그대로
    v_make_prim := COALESCE(p_is_primary, (v_old->>'is_primary') = 'true');
  END IF;

  IF v_locked THEN
    IF v_idx IS NOT NULL AND v_idx = v_prim_idx THEN
      -- 대표 줄: 이름·연락처만
      IF NOT v_make_prim
         OR lower(v_email) IS DISTINCT FROM lower(btrim(COALESCE(v_old->>'email', ''))) THEN
        RETURN jsonb_build_object('result', 'primary_locked');
      END IF;
    ELSIF v_make_prim THEN
      RETURN jsonb_build_object('result', 'primary_move_needs_owner_change');
    END IF;
  ELSIF v_idx IS NOT NULL AND v_idx = v_prim_idx AND NOT v_make_prim THEN
    -- 계정 없음: 유일한 대표 줄의 표시만 끄면 대표가 0명 — 다른 줄을 대표로 체크해서 옮긴다
    RETURN jsonb_build_object('result', 'primary_required');
  END IF;

  IF v_make_prim AND v_email = '' THEN
    RETURN jsonb_build_object('result', 'primary_email_required');
  END IF;

  -- 줄 만들기(다른 열쇠 보존)
  IF v_idx IS NULL THEN
    v_cid := gen_random_uuid()::text;
    v_new_row := jsonb_build_object('id', v_cid, 'name', v_name, 'phone', v_phone, 'email', v_email, 'is_primary', v_make_prim);
  ELSE
    v_new_row := v_old || jsonb_build_object('name', v_name, 'phone', v_phone, 'email', v_email, 'is_primary', v_make_prim);
  END IF;

  -- 대표가 이 줄이면 다른 줄의 표시를 끈다(계정이 있는 동안은 대표 줄 자신을 고칠 때만 여기 온다 — 다른 줄은 이미 꺼져 있다)
  IF v_make_prim THEN
    SELECT COALESCE(jsonb_agg(
             CASE WHEN jsonb_typeof(e.elem) = 'object' THEN e.elem || jsonb_build_object('is_primary', false) ELSE e.elem END
             ORDER BY e.ord), '[]'::jsonb)
      INTO v_contacts
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord);
  END IF;

  IF v_idx IS NULL THEN
    v_contacts := v_contacts || jsonb_build_array(v_new_row);
  ELSE
    v_contacts := jsonb_set(v_contacts, ARRAY[v_idx::text], v_new_row);
  END IF;

  PERFORM public._brand_set_contacts(p_brand_id, v_contacts);

  -- S7=B: 대표 줄 = 활성 대표 계정 이메일이면 계정 이름·연락처도 맞춘다(계정 관리 권한이 있을 때만)
  IF v_make_prim AND v_email <> '' AND public.has_permission('brand.account_manage', 'write') THEN
    SELECT l.* INTO v_link
      FROM public.brand_account_links l
     WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.status = 'active';
    IF FOUND THEN
      SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_link.auth_id FOR UPDATE;
      IF FOUND AND lower(btrim(v_acct.email)) = lower(v_email) THEN
        IF v_acct.name IS DISTINCT FROM NULLIF(v_name, '') OR v_acct.phone IS DISTINCT FROM NULLIF(v_phone, '') THEN
          UPDATE public.brand_accounts SET name = NULLIF(v_name, ''), phone = NULLIF(v_phone, '') WHERE auth_id = v_acct.auth_id;
        END IF;
        IF v_link.source_contact_id IS DISTINCT FROM v_cid THEN
          UPDATE public.brand_account_links SET source_contact_id = v_cid WHERE id = v_link.id;
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'contact_id', v_cid, 'contacts', v_contacts);
END;
$$;

COMMENT ON FUNCTION public.admin_save_brand_contact(uuid, text, text, text, text, boolean) IS
  '[574] 관리자 브랜드 담당자 한 줄 저장(관리자 전원). p_contact_id NULL = 새 줄. 반환 {result, contact_id, contacts(ok 일 때 저장 뒤 배열)}. result = ok·forbidden·brand_not_found·contact_not_found·name_required·invalid_email·primary_email_required·primary_required·primary_locked·primary_move_needs_owner_change. 계정이 있는 동안(_brand_contacts_locked) 대표 줄은 이름·연락처만. 대표 줄 = 활성 대표 계정 이메일이면 brand.account_manage 쓰기 권한자 저장에 한해 계정 이름·연락처도 맞춘다(S7=B). 옛 대표 칸 셋은 _brand_set_contacts 가 맞춘다.';

GRANT  EXECUTE ON FUNCTION public.admin_save_brand_contact(uuid, text, text, text, text, boolean) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_save_brand_contact(uuid, text, text, text, text, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_save_brand_contact(uuid, text, text, text, text, boolean) FROM anon;

-- ── 4. 담당자 한 줄 삭제 ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_delete_brand_contact(p_brand_id uuid, p_contact_id text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_contacts jsonb;
  v_cid      text := NULLIF(btrim(COALESCE(p_contact_id, '')), '');
  v_idx      integer;
  v_was_prim boolean;
BEGIN
  IF NOT public.is_admin() THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_account_upsert:' || p_brand_id::text));

  SELECT COALESCE(b.contacts, '[]'::jsonb) INTO v_contacts
    FROM public.brands b WHERE b.id = p_brand_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'brand_not_found');
  END IF;
  IF jsonb_typeof(v_contacts) <> 'array' THEN v_contacts := '[]'::jsonb; END IF;

  IF v_cid IS NOT NULL THEN
    SELECT (e.ord - 1)::int INTO v_idx
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
     WHERE jsonb_typeof(e.elem) = 'object' AND NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') = v_cid
     ORDER BY e.ord LIMIT 1;
  END IF;
  IF v_idx IS NULL THEN
    RETURN jsonb_build_object('result', 'contact_not_found');
  END IF;

  v_was_prim := (v_contacts -> v_idx ->> 'is_primary') = 'true';
  IF v_was_prim AND public._brand_contacts_locked(p_brand_id) THEN
    RETURN jsonb_build_object('result', 'primary_locked');
  END IF;

  v_contacts := v_contacts - v_idx;

  -- 대표 줄을 지웠으면 남은 첫 객체 줄이 대표(대표 표시가 이미 다른 줄에 없을 때만)
  IF v_was_prim AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_contacts) e(elem)
        WHERE jsonb_typeof(e.elem) = 'object' AND e.elem->>'is_primary' = 'true') THEN
    SELECT (e.ord - 1)::int INTO v_idx
      FROM jsonb_array_elements(v_contacts) WITH ORDINALITY AS e(elem, ord)
     WHERE jsonb_typeof(e.elem) = 'object'
     ORDER BY e.ord LIMIT 1;
    IF v_idx IS NOT NULL THEN
      v_contacts := jsonb_set(v_contacts, ARRAY[v_idx::text, 'is_primary'], 'true'::jsonb);
    END IF;
  END IF;

  PERFORM public._brand_set_contacts(p_brand_id, v_contacts);

  RETURN jsonb_build_object('result', 'ok', 'contacts', v_contacts);
END;
$$;

COMMENT ON FUNCTION public.admin_delete_brand_contact(uuid, text) IS
  '[574] 관리자 브랜드 담당자 한 줄 삭제(관리자 전원). 반환 {result, contacts(ok 일 때 저장 뒤 배열)}. result = ok·forbidden·brand_not_found·contact_not_found·primary_locked(계정이 있는 동안 대표 줄). 계정 없을 때 대표 줄을 지우면 남은 첫 줄이 대표.';

GRANT  EXECUTE ON FUNCTION public.admin_delete_brand_contact(uuid, text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_delete_brand_contact(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_brand_contact(uuid, text) FROM anon;

-- ── 5. _brand_contacts_mark_primary 재정의 (베이스 531 — 마지막 UPDATE 만 _brand_set_contacts 로) ──
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

  -- 574: 옛 대표 칸 셋도 함께 맞춘다(531 은 contacts 만 고쳐 브랜드 목록 「대표 담당자」 열이 옛 사람으로 남았다)
  PERFORM public._brand_set_contacts(p_brand_id, v_contacts);
END;
$$;

COMMENT ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid) IS
  '[574] (531 재정의: 저장을 _brand_set_contacts 로 — 옛 대표 칸 셋도 맞춤) 내부 도우미. brands.contacts 의 대표 표시(is_primary)를 이 계정으로 옮긴다 — 이메일(lower(btrim()))로 같은 사람 판정, 없으면 계정의 이름·이메일·연락처로 줄을 한 번 더한다. 옛 줄은 표시만 뗀다. 메일 없음. 대표 판정은 호출하는 쪽 몫. 호출 불가(안쪽 전용).';

GRANT  EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_contacts_mark_primary(uuid, uuid) FROM anon, authenticated;

-- ── 6. 아이디 없는 담당자 줄에 아이디 붙이기 (멱등 — 빈 아이디 객체 줄만, 다른 줄·순서 그대로) ──
UPDATE public.brands b
   SET contacts = (
         SELECT jsonb_agg(
                  CASE WHEN jsonb_typeof(e.elem) = 'object' AND NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') IS NULL
                       THEN e.elem || jsonb_build_object('id', gen_random_uuid()::text)
                       ELSE e.elem END
                  ORDER BY e.ord)
           FROM jsonb_array_elements(b.contacts) WITH ORDINALITY AS e(elem, ord))
 WHERE jsonb_typeof(b.contacts) = 'array'
   AND EXISTS (SELECT 1 FROM jsonb_array_elements(b.contacts) e(elem)
                WHERE jsonb_typeof(e.elem) = 'object' AND NULLIF(btrim(COALESCE(e.elem->>'id', '')), '') IS NULL);

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '574', '574_brand_contact_row_functions.sql');
COMMIT;
