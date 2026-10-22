-- ============================================================
-- 584_brand_restriction_admin_functions.sql
-- 브랜드 계정 이용 제한 · 결과물 열람 정지 — 제한 4: 관리자 함수 · 권한 시드 · 제공 기록 종류 · 조회 · 메일 선점 · 병합 거부
--   (사양서 4-6 · 4-9 · 5-4 · 5-5 · 5-6 · 5-7 · A1·A4·A11·A12 · 작업표 기본값 2·4·5 · stale 8)
-- 사양서: docs/specs/2026-10-21-brand-account-restriction.md · 작업표 docs/specs/2026-10-21-brand-account-restriction-breakdown.md 「제한 4」
--
-- 왜: 관리자가 이용 제한·열람 정지를 걸고·바꾸고·풀고, 상태를 보고, 알림 메일을 한 번만 보내게 한다.
--
-- 만드는 것 · 바꾸는 것
--   0) 권한 시드 brand.restriction_manage — 최고 관리자·캠페인 관리자 write · 캠페인 매니저 hidden(default_level 같은 값). 🔴 함수와 같은 파일(미등록이면 등급별로 판정이 반대)
--   1) 제공 기록 동작 종류 검사 제약(552 — 줄 안 선언이라 자동 이름) → 11종(results_suspend·results_unsuspend 추가). 이름을 찾아 지우고 이름을 붙여 다시 만든다.
--      목록 함수 admin_get_brand_provision_logs(552)는 종류를 같음 비교로만 걸러 고치지 않는다
--   2) 쓰기 다섯(반환 {result, …} jsonb · 가드 has_permission('brand.restriction_manage','write') 아니면 forbidden)
--      · admin_restrict_brand_account(auth_id, reason_code, reason_note, until) → ok·restriction_id | forbidden·invalid_reason·note_required·note_too_long(1,000자 넘음)·invalid_until·not_found·not_active_account·already_restricted
--        (비밀번호를 정한 브랜드 계정만 — 기본값 2. 같은 계정 잠금 뒤 판정으로 겹침을 막는다 — A4)
--      · admin_change_brand_restriction_period(restriction_id, until) → ok·restriction_id(새 줄) | forbidden·not_restricted·invalid_until·same_period
--        (지금 줄을 period_changed 로 닫고 같은 사유로 새 줄 prev_id — 한 거래, A1)
--      · admin_lift_brand_account_restriction(restriction_id) → ok | forbidden·not_restricted (close_reason='lifted')
--      · admin_suspend_brand_results(brand_id, reason_code, reason_note, include_shipping) → ok·suspension_id | forbidden·invalid_reason·note_required·note_too_long·brand_not_found(없거나 보관)·already_suspended
--        + 같은 거래에서 제공 기록 results_suspend(캠페인 칸 비움, columns = 막는 대상 results·excel·receipt[+shipping])
--      · admin_lift_brand_results_suspension(brand_id) → ok·suspension_id | forbidden·not_suspended + results_unsuspend 기록
--      ⚠️ 날짜 기준은 일본 날짜 — 「날짜까지」는 오늘(일본, 포함) 이후만(A2). 잠금 열쇠 brand_restriction:<계정> · brand_results_suspension:<브랜드>
--   3) 조회 둘(가드 is_admin — 아니면 42501, 브랜드 상세를 볼 수 있는 관리자 모두)
--      · admin_get_brand_account_status(uuid)(578 베이스) — 기존 칸 전부 + members[] 줄마다 restriction{id, reason_code, reason_note, until_date, created_at,
--        created_by_name, linked_brands[{id,name}]}|null(🔴 다른 브랜드 연결도 실어 F1 배지·모달 문구에 쓴다) + results_suspension{id, reason_code, reason_note,
--        include_shipping, created_at, created_by_name}|null + can_restrict(권한 write)
--      · admin_get_brand_results_suspended_map(uuid[]) → {"<brand_id>": true, …}(정지 중만)
--   4) 메일 선점 둘(서비스 키 전용 — postgres·service_role 만, 「알림 1건 = 메일 1통」)
--      · service_claim_brand_sanction_mail(ref_kind, ref_id, mail_kind, caller) → {result:ok, claimed_at, recipients[{auth_id,email,name}], payload{…}}
--        | forbidden(caller 가 권한 없음 — 서비스 키라 has_permission 대신 caller 등급으로 직접 판정, 269 와 같은 비대칭: 최고 관리자 통과)
--        · not_found · not_eligible(종류 짝 어긋남 · 줄 상태와 종류 불일치) · already_claimed. 거부 때는 선점 줄을 만들지 않는다
--        선점은 한 문장(INSERT … ON CONFLICT DO UPDATE … WHERE 보내지 않았고 15분 지난 선점 — 561 과 같은 재시도 창)
--        받는 사람: account_* = 그 계정 한 명(A8, 이메일 있을 때) / results_* = _brand_mailable_accounts(브랜드)(R4·R5 — 제한 계정 제외)
--        payload: reason_code·reason_note·until_date('YYYY-MM-DD'|null)·account_name·brand_names[문자열] / brand_name·include_shipping
--        eligible: account_restrict = prev_id 없는 줄이고 지금 걸려 있는 줄 · account_period = prev_id 있는 줄이고 지금 걸려 있는 줄
--                  · account_lift = close_reason='lifted' · results_suspend = 아직 풀지 않은 줄 · results_lift = lifted_at 있음
--                  (걸자마자 기간을 바꾸면 account_restrict 는 not_eligible — account_period 메일만 나간다. 메일 함수는 not_eligible 을 조용히 넘긴다)
--      · service_mark_brand_sanction_mail_sent(ref_kind, ref_id, mail_kind, claimed_at, ok, failed) → void — 내 선점(claimed_at 같고 아직 안 보냄)만:
--        ok=true → sent_at·ok·failed 기록 / ok=false → 선점 줄을 지운다(다시 시도 가능 — 561 방식)
--   5) merge_brands(528 베이스) — 흡수되는 원본 브랜드가 열람 정지 중이면 거부 source_results_suspended(22023 — 528 의 brand_has_account_links 와 같은 방식,
--      2026-10-22 사용자 결정 ⓐ). 대상 쪽 정지는 막지 않는다(원본에 계정 연결이 없어 528 이 이미 걸러 해가 없다)
--
-- 실행 권한: 관리자 함수 일곱 postgres·authenticated·service_role 부여 → PUBLIC 회수 → anon 회수 · 서비스 함수 둘 postgres·service_role 만 →
--   PUBLIC 회수 → anon·authenticated 회수 · 내부 도우미 _brand_restriction_json postgres 만 · 바꾼 함수(578·528)는 CREATE OR REPLACE 라 보존
-- 🔴 개발서버 적용 → 제한 9(kemo-45)·13-b(kemo-af) 병합 같은 날, 제한 6 메일 함수 배포는 적용 뒤.
-- 🔴 다음 재정의 베이스: admin_get_brand_account_status·merge_brands 는 이 파일(578·528 베이스 금지) · 제공 기록 종류 검사 제약도 이 파일(11종).
-- 편집기 경고: 뜸 — 「destructive operations」(ALTER TABLE … DROP CONSTRAINT · service_mark_brand_sanction_mail_sent 본문의 DELETE — 함수 본문이라 실행 시 삭제 아님). 「Run query」.
-- 롤백: 새 함수 아홉 DROP(admin_restrict_brand_account·admin_change_brand_restriction_period·admin_lift_brand_account_restriction·
--   admin_suspend_brand_results·admin_lift_brand_results_suspension·admin_get_brand_results_suspended_map·service_claim_brand_sanction_mail·
--   service_mark_brand_sanction_mail_sent·_brand_restriction_json) → 578 admin_get_brand_account_status 블록 · 528 merge_brands 블록 재실행
--   → 검사 제약 9종으로(새 종류 줄이 있으면 먼저 지울지 사용자 확인 — 법 기록) → 시드 3행 삭제
-- ============================================================
BEGIN;

-- ── 0. 권한 시드 (530 brand.account_manage 와 같은 방식) ──────────────
--   🔴 행이 없으면 has_permission 이 등급 2종은 거부, 슈퍼 관리자만 통과(269) — 같은 마이그레이션에서 넣는다.
INSERT INTO public.role_permissions (role, feature_key, access_level, default_level)
VALUES
  ('super_admin',      'brand.restriction_manage', 'write',  'write'),
  ('campaign_admin',   'brand.restriction_manage', 'write',  'write'),
  ('campaign_manager', 'brand.restriction_manage', 'hidden', 'hidden')
ON CONFLICT (role, feature_key) DO NOTHING;

-- ── 1. 제공 기록 동작 종류 11종 (552 — 줄 안 선언이라 이름을 찾아 지운다) ─────────
DO $do$
DECLARE
  v_name text;
BEGIN
  FOR v_name IN
    SELECT c.conname
      FROM pg_constraint c
     WHERE c.conrelid = 'public.brand_provision_logs'::regclass
       AND c.contype = 'c'
       AND pg_get_constraintdef(c.oid) LIKE '%shipping_deliver%'
  LOOP
    EXECUTE format('ALTER TABLE public.brand_provision_logs DROP CONSTRAINT %I', v_name);
  END LOOP;
END
$do$;

ALTER TABLE public.brand_provision_logs
  ADD CONSTRAINT brand_provision_logs_action_check CHECK (action IN (
    'shipping_deliver','shipping_auto_add','shipping_view','shipping_excel',
    'results_view','results_excel',
    'publish_on','publish_off','publish_columns',
    'results_suspend','results_unsuspend'));   -- 584: 결과물 열람 정지·해제(A11)

-- ── 2. 내부 도우미 — 제한 줄 하나를 관리자 화면 모양으로 ─────────────────
CREATE OR REPLACE FUNCTION public._brand_restriction_json(p_restriction_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
           'id',              r.id,
           'reason_code',     r.reason_code,
           'reason_note',     r.reason_note,
           'until_date',      to_char(r.until_date, 'YYYY-MM-DD'),
           'created_at',      r.created_at,
           'created_by_name', r.created_by_name,
           -- 그 계정의 활성 연결 전부(다른 브랜드 포함 — F1 배지·모달 「연결된 브랜드 N개」)
           'linked_brands',   (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) ORDER BY b.name), '[]'::jsonb)
                                 FROM public.brand_account_links l
                                 JOIN public.brands b ON b.id = l.brand_id
                                WHERE l.auth_id = r.auth_id AND l.status = 'active'))
    FROM public.brand_account_restrictions r
   WHERE r.id = p_restriction_id;
$$;

COMMENT ON FUNCTION public._brand_restriction_json(uuid) IS
  '[584] 이용 제한 줄 하나 → {id, reason_code, reason_note, until_date(YYYY-MM-DD|null), created_at, created_by_name, linked_brands[{id,name}]}. 내부 전용(상태 조회가 부른다).';

GRANT  EXECUTE ON FUNCTION public._brand_restriction_json(uuid) TO postgres;
REVOKE EXECUTE ON FUNCTION public._brand_restriction_json(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_restriction_json(uuid) FROM anon, authenticated, service_role;

-- ── 3. 이용 제한 걸기 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_restrict_brand_account(
  p_auth_id     uuid,
  p_reason_code text,
  p_reason_note text,
  p_until       date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := (SELECT auth.uid());
  v_note  text := btrim(COALESCE(p_reason_note, ''));
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_acct  public.brand_accounts%ROWTYPE;
  v_name  text;
  v_id    uuid;
BEGIN
  IF NOT public.has_permission('brand.restriction_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'restriction_id', NULL);
  END IF;
  IF p_reason_code IS NULL OR p_reason_code NOT IN ('terms_8', 'account_sharing', 'other') THEN
    RETURN jsonb_build_object('result', 'invalid_reason', 'restriction_id', NULL);
  END IF;
  IF v_note = '' THEN
    RETURN jsonb_build_object('result', 'note_required', 'restriction_id', NULL);
  END IF;
  IF char_length(v_note) > 1000 THEN   -- 메일 본문에 그대로 들어간다
    RETURN jsonb_build_object('result', 'note_too_long', 'restriction_id', NULL);
  END IF;
  IF p_until IS NOT NULL AND p_until < v_today THEN   -- 오늘(일본, 포함) 이후만(A2)
    RETURN jsonb_build_object('result', 'invalid_until', 'restriction_id', NULL);
  END IF;

  SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = p_auth_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_found', 'restriction_id', NULL);
  END IF;
  IF v_acct.password_set_at IS NULL THEN   -- 기본값 2 — 비밀번호를 정한(사용 중) 계정만
    RETURN jsonb_build_object('result', 'not_active_account', 'restriction_id', NULL);
  END IF;

  -- 같은 계정 잠금 먼저, 그 뒤 판정(A4 — 지금 걸린 줄은 계정마다 하나)
  PERFORM pg_advisory_xact_lock(hashtext('brand_restriction:' || p_auth_id::text));
  IF public._brand_account_restricted(p_auth_id) THEN
    RETURN jsonb_build_object('result', 'already_restricted', 'restriction_id', public._brand_active_restriction_id(p_auth_id));
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  INSERT INTO public.brand_account_restrictions (auth_id, reason_code, reason_note, until_date, created_by, created_by_name)
  VALUES (p_auth_id, p_reason_code, v_note, p_until, v_uid, v_name)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('result', 'ok', 'restriction_id', v_id);
END;
$$;

COMMENT ON FUNCTION public.admin_restrict_brand_account(uuid, text, text, date) IS
  '[584] 관리자 — 브랜드 계정 이용 제한 걸기(계정 전체, F1). p_until NULL = 해제할 때까지. 반환 {result: ok|forbidden|invalid_reason|note_required|note_too_long|invalid_until|not_found|not_active_account|already_restricted, restriction_id}. 가드 has_permission(brand.restriction_manage, write). 메일은 서버 함수 notify-brand-restriction(account_restrict).';

-- ── 4. 이용 제한 기간 바꾸기 (A1 — 지금 줄을 닫고 새 줄) ─────────────────
CREATE OR REPLACE FUNCTION public.admin_change_brand_restriction_period(p_restriction_id uuid, p_until date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid   uuid := (SELECT auth.uid());
  v_today date := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  v_row   public.brand_account_restrictions%ROWTYPE;
  v_name  text;
  v_id    uuid;
BEGIN
  IF NOT public.has_permission('brand.restriction_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'restriction_id', NULL);
  END IF;

  SELECT r.* INTO v_row FROM public.brand_account_restrictions r WHERE r.id = p_restriction_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_restricted', 'restriction_id', NULL);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_restriction:' || v_row.auth_id::text));
  -- 잠금 안에서: 이 줄이 지금 걸려 있는 줄인가(그사이 해제·기간 바꾸기·기간 끝남)
  IF public._brand_active_restriction_id(v_row.auth_id) IS DISTINCT FROM p_restriction_id THEN
    RETURN jsonb_build_object('result', 'not_restricted', 'restriction_id', NULL);
  END IF;
  SELECT r.* INTO v_row FROM public.brand_account_restrictions r WHERE r.id = p_restriction_id FOR UPDATE;

  IF p_until IS NOT NULL AND p_until < v_today THEN
    RETURN jsonb_build_object('result', 'invalid_until', 'restriction_id', NULL);
  END IF;
  IF p_until IS NOT DISTINCT FROM v_row.until_date THEN
    RETURN jsonb_build_object('result', 'same_period', 'restriction_id', NULL);
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  UPDATE public.brand_account_restrictions
     SET lifted_by = v_uid, lifted_by_name = v_name, lifted_at = now(), close_reason = 'period_changed'
   WHERE id = v_row.id;

  INSERT INTO public.brand_account_restrictions
    (auth_id, reason_code, reason_note, until_date, created_by, created_by_name, prev_id)
  VALUES
    (v_row.auth_id, v_row.reason_code, v_row.reason_note, p_until, v_uid, v_name, v_row.id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('result', 'ok', 'restriction_id', v_id);
END;
$$;

COMMENT ON FUNCTION public.admin_change_brand_restriction_period(uuid, date) IS
  '[584] 관리자 — 이용 제한 기간 바꾸기(A1): 지금 걸린 줄을 period_changed 로 닫고 같은 사유·설명으로 새 줄(prev_id). 반환 {result: ok|forbidden|not_restricted|invalid_until|same_period, restriction_id(새 줄)}. 메일은 account_period(새 줄 번호로).';

-- ── 5. 이용 제한 해제 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lift_brand_account_restriction(p_restriction_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_auth uuid;
  v_name text;
BEGIN
  IF NOT public.has_permission('brand.restriction_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;

  SELECT r.auth_id INTO v_auth FROM public.brand_account_restrictions r WHERE r.id = p_restriction_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_restricted');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_restriction:' || v_auth::text));
  IF public._brand_active_restriction_id(v_auth) IS DISTINCT FROM p_restriction_id THEN
    RETURN jsonb_build_object('result', 'not_restricted');
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  UPDATE public.brand_account_restrictions
     SET lifted_by = v_uid, lifted_by_name = v_name, lifted_at = now(), close_reason = 'lifted'
   WHERE id = p_restriction_id;

  RETURN jsonb_build_object('result', 'ok');
END;
$$;

COMMENT ON FUNCTION public.admin_lift_brand_account_restriction(uuid) IS
  '[584] 관리자 — 이용 제한 해제(close_reason=lifted). 지금 걸린 줄만. 반환 {result: ok|forbidden|not_restricted}. 메일은 account_lift(체크했을 때).';

-- ── 6. 결과물 열람 정지 걸기 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_suspend_brand_results(
  p_brand_id         uuid,
  p_reason_code      text,
  p_reason_note      text,
  p_include_shipping boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_note text := btrim(COALESCE(p_reason_note, ''));
  v_ship boolean := COALESCE(p_include_shipping, false);
  v_name text;
  v_id   uuid;
BEGIN
  IF NOT public.has_permission('brand.restriction_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'suspension_id', NULL);
  END IF;
  IF p_reason_code IS NULL OR p_reason_code NOT IN ('terms_8', 'other') THEN
    RETURN jsonb_build_object('result', 'invalid_reason', 'suspension_id', NULL);
  END IF;
  IF v_note = '' THEN
    RETURN jsonb_build_object('result', 'note_required', 'suspension_id', NULL);
  END IF;
  IF char_length(v_note) > 1000 THEN   -- 메일 본문에 그대로 들어간다
    RETURN jsonb_build_object('result', 'note_too_long', 'suspension_id', NULL);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'suspension_id', NULL);
  END IF;

  -- 잠금 먼저(merge_brands 가 같은 열쇠를 쥔다) — 그 뒤 활성 확인: 보관(병합·정리)된 브랜드에는 걸지 않는다(병합 재호출의 멱등 반환을 막지 않게)
  PERFORM pg_advisory_xact_lock(hashtext('brand_results_suspension:' || p_brand_id::text));
  IF NOT EXISTS (SELECT 1 FROM public.brands b WHERE b.id = p_brand_id AND b.status = 'active') THEN
    RETURN jsonb_build_object('result', 'brand_not_found', 'suspension_id', NULL);
  END IF;
  IF public._brand_active_suspension(p_brand_id) IS NOT NULL THEN
    RETURN jsonb_build_object('result', 'already_suspended', 'suspension_id', (public._brand_active_suspension(p_brand_id) ->> 'id')::uuid);
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  INSERT INTO public.brand_results_suspensions (brand_id, reason_code, reason_note, include_shipping, created_by, created_by_name)
  VALUES (p_brand_id, p_reason_code, v_note, v_ship, v_uid, v_name)
  RETURNING id INTO v_id;

  -- 제공 기록(A11) — 캠페인 칸 비움, 막는 대상
  PERFORM public._record_brand_provision(
    p_brand_id, NULL, 'results_suspend',
    CASE WHEN v_ship THEN '["results","excel","receipt","shipping"]'::jsonb ELSE '["results","excel","receipt"]'::jsonb END,
    '[]'::jsonb, v_uid, 'admin');

  RETURN jsonb_build_object('result', 'ok', 'suspension_id', v_id);
END;
$$;

COMMENT ON FUNCTION public.admin_suspend_brand_results(uuid, text, text, boolean) IS
  '[584] 관리자 — 브랜드 결과물 열람 정지 걸기(배송 리스트 포함 여부 F2). 같은 거래에서 제공 기록 results_suspend. 반환 {result: ok|forbidden|invalid_reason|note_required|note_too_long|brand_not_found|already_suspended, suspension_id}. 메일은 results_suspend.';

-- ── 7. 결과물 열람 정지 해제 ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_lift_brand_results_suspension(p_brand_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_row  public.brand_results_suspensions%ROWTYPE;
  v_name text;
BEGIN
  IF NOT public.has_permission('brand.restriction_manage', 'write') THEN
    RETURN jsonb_build_object('result', 'forbidden', 'suspension_id', NULL);
  END IF;
  IF p_brand_id IS NULL THEN
    RETURN jsonb_build_object('result', 'not_suspended', 'suspension_id', NULL);
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('brand_results_suspension:' || p_brand_id::text));
  SELECT s.* INTO v_row
    FROM public.brand_results_suspensions s
   WHERE s.brand_id = p_brand_id AND s.lifted_at IS NULL
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('result', 'not_suspended', 'suspension_id', NULL);
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  UPDATE public.brand_results_suspensions
     SET lifted_by = v_uid, lifted_by_name = v_name, lifted_at = now()
   WHERE id = v_row.id;

  PERFORM public._record_brand_provision(
    p_brand_id, NULL, 'results_unsuspend',
    CASE WHEN v_row.include_shipping THEN '["results","excel","receipt","shipping"]'::jsonb ELSE '["results","excel","receipt"]'::jsonb END,
    '[]'::jsonb, v_uid, 'admin');

  RETURN jsonb_build_object('result', 'ok', 'suspension_id', v_row.id);
END;
$$;

COMMENT ON FUNCTION public.admin_lift_brand_results_suspension(uuid) IS
  '[584] 관리자 — 브랜드 결과물 열람 정지 해제. 같은 거래에서 제공 기록 results_unsuspend. 반환 {result: ok|forbidden|not_suspended, suspension_id}. 메일은 results_lift(체크했을 때, 이 suspension_id 로).';

-- ── 8. 브랜드별 정지 일괄 조회 ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.admin_get_brand_results_suspended_map(p_brand_ids uuid[])
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN (SELECT COALESCE(jsonb_object_agg(s.brand_id::text, true), '{}'::jsonb)
            FROM public.brand_results_suspensions s
           WHERE s.lifted_at IS NULL
             AND s.brand_id = ANY (COALESCE(p_brand_ids, '{}'::uuid[])));
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_results_suspended_map(uuid[]) IS
  '[584] 관리자 — 브랜드별 결과물 열람 정지 여부 {"<brand_id>": true}(정지 중만). 캠페인 목록·진행현황 「열람 정지」 배지. 가드 is_admin(아니면 42501). 정지 판정(_brand_active_suspension)과 같은 조건(lifted_at IS NULL).';

-- ── 9. 브랜드 계정 상태 조회 (베이스 578) ─────────────────────────
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
  v_req     public.brand_invites%ROWTYPE;   -- 578
  v_req_j   jsonb;                          -- 578: owner_link_request
  v_susp    jsonb;                          -- 584: results_suspension
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
  -- 584: 줄마다 지금 걸린 이용 제한(restriction — 다른 브랜드 연결 포함) | null
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'auth_id',         a.auth_id,
           'role',            l.role,
           'name',            a.name,
           'email',           a.email,
           'phone',           a.phone,
           'last_active_at',  CASE WHEN a.password_set_at IS NOT NULL THEN l.last_active_at ELSE NULL END,
           'password_set_at', a.password_set_at,
           'restriction',     CASE WHEN rx.rid IS NULL THEN NULL ELSE public._brand_restriction_json(rx.rid) END   -- 584
         ) ORDER BY (l.role = 'owner') DESC, l.created_at, l.id), '[]'::jsonb)
    INTO v_members
    FROM public.brand_account_links l
    JOIN public.brand_accounts a ON a.auth_id = l.auth_id
    CROSS JOIN LATERAL (SELECT public._brand_active_restriction_id(a.auth_id) AS rid OFFSET 0) rx
   WHERE l.brand_id = p_brand_id AND l.status = 'active';

  -- 578: 가장 최근 연결 요청 하나. 활성 대표가 있거나, 그 요청 발급 뒤에 대표 연결이 생긴 적이 있으면 null
  --   (수락·계정 만들기·대표 바꾸기 어느 길이든 — 그 대표를 해제한 뒤에도 옛 요청 칩을 그리지 않게)
  IF v_owner IS NULL THEN
    SELECT i.* INTO v_req
      FROM public.brand_invites i
     WHERE i.brand_id = p_brand_id AND i.invite_kind = 'owner_link'
     ORDER BY i.issued_at DESC, i.id DESC
     LIMIT 1;
    IF FOUND AND v_req.status <> 'accepted'   -- 수락된 요청은 대표 연결로 보인다(칩 없음)
       AND NOT EXISTS (SELECT 1 FROM public.brand_account_links l
                              WHERE l.brand_id = p_brand_id AND l.role = 'owner' AND l.created_at > v_req.issued_at) THEN
      v_req_j := jsonb_build_object(
        'request_id', v_req.id,
        'status',     CASE WHEN v_req.status = 'pending' AND v_req.expires_at > now() THEN 'pending'
                           WHEN v_req.status = 'pending' THEN 'expired'
                           ELSE v_req.status END,
        'email',      v_req.email,
        'sent_at',    v_req.issued_at,
        'expires_at', v_req.expires_at);
    END IF;
  END IF;

  -- 584: 결과물 열람 정지(브랜드 머리 배지·「정지 해제」)
  SELECT jsonb_build_object(
           'id',               s.id,
           'reason_code',      s.reason_code,
           'reason_note',      s.reason_note,
           'include_shipping', s.include_shipping,
           'created_at',       s.created_at,
           'created_by_name',  s.created_by_name)
    INTO v_susp
    FROM public.brand_results_suspensions s
   WHERE s.id = (public._brand_active_suspension(p_brand_id) ->> 'id')::uuid;

  RETURN jsonb_build_object(
    'status',               v_status,
    'email',                CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.email END,
    'setup_mail_sent_at',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_at END,
    'password_set_at',      CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.password_set_at END,
    'setup_mail_sent_by',   CASE WHEN v_owner IS NULL THEN NULL ELSE v_acct.setup_mail_sent_by END,
    'owner_auth_id',        v_owner,
    'members',              v_members,
    'pending_invite_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending' AND i.expires_at > now()
                                AND i.invite_kind = 'member'),   -- 578: 멤버 초대만
    'release_cancel_count', (SELECT count(*) FROM public.brand_invites i
                              WHERE i.brand_id = p_brand_id AND i.status = 'pending'
                                AND i.invite_kind = 'member'),   -- 578: 멤버 초대만
    'seat_used',            public._brand_seat_usage(p_brand_id),
    'member_limit',         public._brand_member_limit(p_brand_id),
    'can_manage',           public.has_permission('brand.account_manage', 'write'),
    'owner_link_request',   v_req_j,         -- 578: {request_id, status: pending|expired|declined|cancelled, email, sent_at, expires_at} | null
    'results_suspension',   v_susp,          -- 584: {id, reason_code, reason_note, include_shipping, created_at, created_by_name} | null
    'can_restrict',         public.has_permission('brand.restriction_manage', 'write')   -- 584
  );
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_account_status(uuid) IS
  '[584] (578 재정의 — members[].restriction · results_suspension · can_restrict) 관리자 화면 계정 줄 상태(관리자 전원, 아니면 42501). 527 칸 유지(status none/mail_pending/mail_sent/active · email · setup_mail_sent_at · password_set_at) + setup_mail_sent_by · owner_auth_id · members[](활성 연결 전원, 대표 먼저: auth_id·role·name·email·phone·last_active_at[비밀번호 미설정 계정은 null]·password_set_at·restriction{id,reason_code,reason_note,until_date,created_at,created_by_name,linked_brands[{id,name}]}|null) · pending_invite_count(만료 전 대기) · release_cancel_count(상태가 대기인 초대 전부) · seat_used · member_limit · can_manage(brand.account_manage 쓰기) · owner_link_request · results_suspension{id,reason_code,reason_note,include_shipping,created_at,created_by_name}|null · can_restrict(brand.restriction_manage 쓰기). 멤버 초대 줄·이메일은 싣지 않는다.';

-- ── 10. 메일 선점 (서비스 키 전용) ────────────────────────────────
CREATE OR REPLACE FUNCTION public.service_claim_brand_sanction_mail(
  p_ref_kind  text,
  p_ref_id    uuid,
  p_mail_kind text,
  p_caller    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_role     text;
  v_level    text;
  v_r        public.brand_account_restrictions%ROWTYPE;
  v_s        public.brand_results_suspensions%ROWTYPE;
  v_acct     public.brand_accounts%ROWTYPE;
  v_claimed  timestamptz;
  v_recip    jsonb;
  v_payload  jsonb;
BEGIN
  -- ① 호출 관리자 권한 — 서비스 키라 has_permission() 은 auth.uid() 가 없어 못 쓴다. 269 와 같은 판정을 caller 로(최고 관리자는 통과, 나머지는 줄이 write 여야)
  SELECT a.role INTO v_role FROM public.admins a WHERE a.auth_id = p_caller;
  IF v_role IS NULL THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  IF v_role <> 'super_admin' THEN
    SELECT rp.access_level INTO v_level FROM public.role_permissions rp
     WHERE rp.role = v_role AND rp.feature_key = 'brand.restriction_manage';
    IF v_level IS DISTINCT FROM 'write' THEN
      RETURN jsonb_build_object('result', 'forbidden');
    END IF;
  END IF;

  -- ② 종류 짝 — 계정 메일 셋은 제한 줄, 브랜드 메일 둘은 정지 줄(581 표 검사와 같은 짝)
  IF p_ref_kind IS NULL OR p_mail_kind IS NULL OR p_ref_id IS NULL
     OR NOT ((p_ref_kind = 'restriction' AND p_mail_kind IN ('account_restrict', 'account_period', 'account_lift'))
       OR (p_ref_kind = 'suspension'  AND p_mail_kind IN ('results_suspend', 'results_lift'))) THEN
    RETURN jsonb_build_object('result', 'not_eligible');
  END IF;

  -- ③ 원본 줄 · 줄 상태와 종류 · 받는 사람 · 본문 재료
  IF p_ref_kind = 'restriction' THEN
    SELECT r.* INTO v_r FROM public.brand_account_restrictions r WHERE r.id = p_ref_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('result', 'not_found');
    END IF;
    -- 걸기·기간 바꾸기 메일은 「지금 걸려 있는 줄」에만(이미 풀렸거나 다시 바뀐 줄에 옛 기간·사유가 나가지 않게)
    IF (p_mail_kind = 'account_restrict' AND (v_r.prev_id IS NOT NULL               -- 건 순간의 줄(기간 바꾸기로 이어진 줄은 account_period)
                                               OR public._brand_active_restriction_id(v_r.auth_id) IS DISTINCT FROM v_r.id))
       OR (p_mail_kind = 'account_period' AND (v_r.prev_id IS NULL
                                               OR public._brand_active_restriction_id(v_r.auth_id) IS DISTINCT FROM v_r.id))
       OR (p_mail_kind = 'account_lift'   AND v_r.close_reason IS DISTINCT FROM 'lifted') THEN
      RETURN jsonb_build_object('result', 'not_eligible');
    END IF;
    SELECT a.* INTO v_acct FROM public.brand_accounts a WHERE a.auth_id = v_r.auth_id;
    v_recip := CASE WHEN FOUND AND NULLIF(btrim(v_acct.email), '') IS NOT NULL
                    THEN jsonb_build_array(jsonb_build_object('auth_id', v_acct.auth_id,
                                                              'email',   lower(btrim(v_acct.email)),
                                                              'name',    NULLIF(btrim(v_acct.name), '')))
                    ELSE '[]'::jsonb END;   -- A8 — 그 계정 한 명
    v_payload := jsonb_build_object(
      'reason_code',  v_r.reason_code,
      'reason_note',  v_r.reason_note,
      'until_date',   to_char(v_r.until_date, 'YYYY-MM-DD'),
      'account_name', NULLIF(btrim(v_acct.name), ''),
      'brand_names',  (SELECT COALESCE(jsonb_agg(b.name ORDER BY b.name), '[]'::jsonb)
                         FROM public.brand_account_links l
                         JOIN public.brands b ON b.id = l.brand_id
                        WHERE l.auth_id = v_r.auth_id AND l.status = 'active'));
  ELSE
    SELECT s.* INTO v_s FROM public.brand_results_suspensions s WHERE s.id = p_ref_id;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('result', 'not_found');
    END IF;
    IF (p_mail_kind = 'results_lift' AND v_s.lifted_at IS NULL)          -- 아직 정지 중
       OR (p_mail_kind = 'results_suspend' AND v_s.lifted_at IS NOT NULL) THEN   -- 이미 풀린 정지
      RETURN jsonb_build_object('result', 'not_eligible');
    END IF;
    v_recip := (SELECT COALESCE(jsonb_agg(jsonb_build_object('auth_id', m->'auth_id', 'email', m->'email', 'name', m->'name')), '[]'::jsonb)
                  FROM jsonb_array_elements(public._brand_mailable_accounts(v_s.brand_id)) m);   -- R4·R5
    v_payload := jsonb_build_object(
      'reason_code',      v_s.reason_code,
      'reason_note',      v_s.reason_note,
      'brand_name',       (SELECT b.name FROM public.brands b WHERE b.id = v_s.brand_id),
      'include_shipping', v_s.include_shipping);
  END IF;

  -- ④ 선점 — 한 문장. 새 줄이거나, 아직 안 보냈고 15분 넘은 선점이면 다시 잡는다(561 과 같은 재시도 창)
  INSERT INTO public.brand_sanction_mail_claims AS m (ref_kind, ref_id, mail_kind, claimed_by, claimed_at)
  VALUES (p_ref_kind, p_ref_id, p_mail_kind, p_caller, clock_timestamp())
  ON CONFLICT (ref_kind, ref_id, mail_kind) DO UPDATE
     SET claimed_at = clock_timestamp(), claimed_by = EXCLUDED.claimed_by
   WHERE m.sent_at IS NULL AND m.claimed_at < now() - interval '15 minutes'
  RETURNING m.claimed_at INTO v_claimed;
  IF v_claimed IS NULL THEN
    RETURN jsonb_build_object('result', 'already_claimed');
  END IF;

  RETURN jsonb_build_object('result', 'ok', 'claimed_at', v_claimed, 'recipients', v_recip, 'payload', v_payload);
END;
$$;

COMMENT ON FUNCTION public.service_claim_brand_sanction_mail(text, uuid, text, uuid) IS
  '[584] 서비스 키 전용(notify-brand-restriction). 이용 제한·열람 정지 알림 메일 선점(알림 1건 = 메일 1통). caller 권한(brand.restriction_manage write, 최고 관리자 통과) → 종류 짝 → 원본 줄·상태 → 한 문장 선점(15분 재시도 창). 거부 땐 선점 줄 없음. 반환 {result: ok|forbidden|not_found|not_eligible|already_claimed, claimed_at, recipients[{auth_id,email,name}], payload{reason_code,reason_note,until_date,account_name,brand_names | reason_code,reason_note,brand_name,include_shipping}}. 받는 사람이 0명이어도 ok(빈 배열) — 함수가 no_recipient 로 판단.';

CREATE OR REPLACE FUNCTION public.service_mark_brand_sanction_mail_sent(
  p_ref_kind   text,
  p_ref_id     uuid,
  p_mail_kind  text,
  p_claimed_at timestamptz,
  p_ok         boolean,
  p_failed     jsonb
)
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF COALESCE(p_ok, false) THEN
    UPDATE public.brand_sanction_mail_claims
       SET sent_at = now(), ok = true,
           failed  = CASE WHEN jsonb_typeof(p_failed) = 'array' THEN p_failed ELSE NULL END
     WHERE ref_kind = p_ref_kind AND ref_id = p_ref_id AND mail_kind = p_mail_kind
       AND claimed_at = p_claimed_at AND sent_at IS NULL;
  ELSE
    -- 실패면 내 선점만 지운다(다시 시도 가능 — 561 의 선점 되돌리기와 같은 뜻)
    DELETE FROM public.brand_sanction_mail_claims
     WHERE ref_kind = p_ref_kind AND ref_id = p_ref_id AND mail_kind = p_mail_kind
       AND claimed_at = p_claimed_at AND sent_at IS NULL;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.service_mark_brand_sanction_mail_sent(text, uuid, text, timestamptz, boolean, jsonb) IS
  '[584] 서비스 키 전용. 선점 결과 기록 — 내 선점(claimed_at 같고 아직 안 보냄)만. ok=true → sent_at·ok·failed(이메일 문자열 배열, 일부 실패) / ok=false(전원 실패) → 선점 줄 삭제(다시 시도 가능).';

-- ── 11. merge_brands — 정지 중인 원본 병합 거부 (베이스 528) ────────────
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

  -- [584] 흡수되는 원본 브랜드가 결과물 열람 정지 중이면 병합 거부(2026-10-22 사용자 결정 ⓐ).
  --   정지 줄은 브랜드 번호에 묶여 병합으로 옮겨 가지 않는다 — 그대로 병합하면 정지가 사실상 풀린다.
  --   정지를 먼저 풀거나(관리자 「정지 해제」) 대상 브랜드에 다시 건 뒤 병합한다. 대상 쪽 정지는 막지 않는다(원본에 계정 연결이 없어 위 528 판정이 이미 거른다).
  PERFORM pg_advisory_xact_lock(hashtext('brand_results_suspension:' || p_source::text));   -- 정지 걸기(같은 열쇠)와 순서를 정한다
  IF public._brand_active_suspension(p_source) IS NOT NULL THEN
    RAISE EXCEPTION 'source_results_suspended' USING ERRCODE = '22023';
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
  '[584] (528 재정의 — 원본이 결과물 열람 정지 중이면 source_results_suspended) [467+528] 브랜드 병합 — 신청·캠페인·오리엔시트·영업 메모를 대상 브랜드로 옮기고 채번을 재발급한다. '
  '원본은 archived. is_campaign_admin 가드. 멱등성 판정에 brand_applications·campaigns·'
  'orient_sheets·brand_memos 존재 여부를 모두 본다(328 + 467). '
  '메모는 본문 앞에 「(구 원본브랜드명)」 을 붙여 어느 브랜드 시절 글인지 남긴다. '
  '[528] 원본에 활성 브랜드 계정 연결이 있으면 brand_has_account_links 로 거부(대상 쪽 연결은 영향 없음).';

-- ── 12. 실행 권한 ───────────────────────────────────────────
GRANT  EXECUTE ON FUNCTION public.admin_restrict_brand_account(uuid, text, text, date)            TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_change_brand_restriction_period(uuid, date)                TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_lift_brand_account_restriction(uuid)                      TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_suspend_brand_results(uuid, text, text, boolean)          TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_lift_brand_results_suspension(uuid)                       TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.admin_get_brand_results_suspended_map(uuid[])                   TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.admin_restrict_brand_account(uuid, text, text, date)            FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_change_brand_restriction_period(uuid, date)                FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_lift_brand_account_restriction(uuid)                      FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_suspend_brand_results(uuid, text, text, boolean)          FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_lift_brand_results_suspension(uuid)                       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_results_suspended_map(uuid[])                   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_restrict_brand_account(uuid, text, text, date)            FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_change_brand_restriction_period(uuid, date)                FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_lift_brand_account_restriction(uuid)                      FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_suspend_brand_results(uuid, text, text, boolean)          FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_lift_brand_results_suspension(uuid)                       FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_results_suspended_map(uuid[])                   FROM anon;

GRANT  EXECUTE ON FUNCTION public.service_claim_brand_sanction_mail(text, uuid, text, uuid)                         TO postgres, service_role;
GRANT  EXECUTE ON FUNCTION public.service_mark_brand_sanction_mail_sent(text, uuid, text, timestamptz, boolean, jsonb) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.service_claim_brand_sanction_mail(text, uuid, text, uuid)                         FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_sanction_mail_sent(text, uuid, text, timestamptz, boolean, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_claim_brand_sanction_mail(text, uuid, text, uuid)                         FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.service_mark_brand_sanction_mail_sent(text, uuid, text, timestamptz, boolean, jsonb) FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '584', '584_brand_restriction_admin_functions.sql');
COMMIT;
