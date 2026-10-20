-- ============================================================
-- 552_personal_data_logs.sql   (번호는 dev 병합 직전 origin/dev·열린 병합 요청과 다시 대조 — 겹치면 파일 이름만 바꾼다)
-- 2026-10-20 · 개발서버만(운영은 브랜드 묶음 출시 날 L1)
--
-- 작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 P1」 · 결정 D16·D26
-- 사양서 docs/specs/2026-10-19-personal-data-access-records.md §4
--
-- 하는 일 (적용만으로 바뀌는 기존 동작은 없다 — 새 표 둘과 새 함수 여섯뿐)
--   ① 표 brand_provision_logs   — 브랜드에 인플루언서 정보를 보여 준/전한 기록 (보관 3년)
--   ② 표 personal_data_access_logs — 관리자가 개인정보를 열람·내려받은 기록 (보관 1년)
--   ③ 내부 함수 _record_brand_provision        — ①에 쓰는 유일한 길 (D16 합치기도 여기 한 곳)
--   ④ 서버 전용 service_record_brand_provision — 서버 함수(브랜드 결과물)가 ③을 부르는 입구
--   ⑤ record_admin_data_access                  — ②에 쓰는 유일한 길 (관리자 화면이 부름)
--   ⑥ 읽기 셋 admin_get_brand_provision_logs · admin_get_brand_provision_persons · admin_get_data_access_logs (최고 관리자만)
--
-- ============================================================
-- 확인한 것 (2026-10-20, 저장소 검색)
-- ============================================================
--   [이름 충돌 없음] supabase/migrations·dev/ 전체에서 brand_provision_logs · personal_data_access_logs ·
--     _record_brand_provision · service_record_brand_provision · record_admin_data_access ·
--     admin_get_brand_provision_logs · admin_get_brand_provision_persons · admin_get_data_access_logs 0건.
--     (마지막 번호는 작성 시점 551 — 번호는 만들기 직전 origin/dev·열린 병합 요청까지 보고 정할 것)
--   [520 탈퇴 파기 함수는 이 두 표를 건드리지 않는다] 520_*.sql 에 두 표 이름이 없고, 520 이 읽거나 바꾸는 표는
--     admins · influencers · withdrawal_requests · applications · client_error_logs 뿐이다.
--     → 탈퇴 확정 회원의 이름은 persons 안에 "그때 표시 이름" 으로 3년 남는다. 이것은 의도다(사양서 ② §2-6 — 「내 정보를
--       어느 브랜드에 언제 줬나」 답변용 법적 기록). 방침 문구는 L1 의 방침 개정 조각 몫.
--   [외래 키 없음] 보관 삭제·delete_brand(528)·merge_brands 와 무관하게 3년 남아야 하므로 번호 + 이름 스냅샷만 둔다.
--
-- ============================================================
-- 설계 판단 (작업표와 달라졌거나 작업표가 비워 둔 곳)
-- ============================================================
--   [J1] 합치기(D16)가 새 줄을 만들지 않을 때, 이번 호출의 사람 목록 중 기존 줄에 없는 사람은 그 줄에 덧붙인다
--        (persons·person_count 만 — at 은 「처음 봤을 때」 그대로). 안 덧붙이면 30분 안에 새로 추가된 배송 줄을
--        브랜드가 봤는데도 기록에 없는 구멍이 생긴다. 열(columns)은 합집합. 합치기가 없는 종류(전달·엑셀·공개 설정)는 늘 새 줄.
--   [J2] 합치기 대상 종류 = shipping_view · results_view 둘뿐. 같은 계정·같은 캠페인·같은 종류·30분 안.
--        동시에 두 요청이 들어와 줄이 둘 생기는 것을 pg_advisory_xact_lock 으로 막는다(키 = 계정+캠페인+종류).
--   [J3] service_record_brand_provision 은 받은 계정이 「그 캠페인의 브랜드에 활성 연결된 브랜드 계정」인지 한 번 더 검사한다.
--        근거: 서버 함수가 토큰으로 이미 확인했더라도, 이 함수는 service_role 이면 누구 이름으로든 기록을 쓸 수 있는
--        유일한 입구라 가짜 「누가」를 막는 마지막 문이 값싸다. 검사 식은 530 my_brand_role 의 사본(활성 연결 + 활성 브랜드)
--        — 그 식을 바꾸면 여기도 함께. 실패는 예외 not_brand_account (R1 서버 함수는 record_failed 로 옮긴다).
--        또 브랜드 쪽 입구에서는 브랜드가 할 수 있는 종류 넷(shipping_view · shipping_excel · results_view · results_excel)만 받는다.
--   [J4] actor_kind 를 비우면 계정으로 판정한다(admins 에 있으면 admin, brand_accounts 에 있으면 brand, 둘 다 아니면 예외).
--        자동 추가 트리거는 'system' 을 넘기고 그때 actor_auth_id 는 늘 NULL, 이름은 '시스템(자동)'.
--        관리자 이름은 admins.name(비면 이메일), 브랜드 계정 이름은 brand_accounts.name(비면 이메일) 스냅샷.
--   [J5] persons 는 [{influencer_id, name}] 배열이어야 하고 columns 는 배열이어야 한다(아니면 예외 invalid_payload).
--        person_count = 배열 길이(부르는 쪽이 따로 넘기지 않는다). 사람 목록은 2000명까지(과대 입력 방어).
--   [J6] 읽기 함수의 반환은 jsonb {rows:[…], has_more:bool}. 「더 보기」는 before_at + before_id 커서(offset 쓰지 않음 — 기록이 계속 쌓이므로).
--        목록 줄에는 persons 를 싣지 않고(무겁다) person_count 만, 사람 목록은 admin_get_brand_provision_persons 로 따로.
--        기간은 일본 날짜 기준(from 그날 0시 이상, to 그날 끝 이하).
--   [J7] 표 권한을 한 겹 더 조인다 — anon·authenticated 의 모든 표 권한을 걷고 authenticated 에 SELECT 만 준다
--        (행 단위 보안이 막아 주지만, 쓰기는 함수로만이라는 규칙을 권한으로도 못 박는다).
--   [J8] record_admin_data_access 는 관리자라면 등급 무관 누구나 부를 수 있다(캠페인 매니저도 엑셀을 받는다). 대신 source 길이와
--        meta 크기에 상한을 둬 기록 표를 부풀리는 호출을 막는다.
--
-- ============================================================
-- 읽기 함수 필터 키 (p_filters jsonb — 모르는 키는 무시, 값이 null 이거나 빈 문자열이면 그 거르기는 없음)
-- ============================================================
--   admin_get_brand_provision_logs(p_filters):
--     from           'YYYY-MM-DD'  일본 날짜 기준 이 날 0시부터
--     to             'YYYY-MM-DD'  일본 날짜 기준 이 날 끝까지
--     brand_id       uuid          브랜드 (브랜드 상세 「제공 기록」이 쓴다)
--     actor_auth_id  uuid          누가 (계정)
--     actor_kind     text          'brand' | 'admin' | 'system'
--     action         text          9개 종류 중 하나
--     campaign_id    uuid          캠페인
--     campaign_no    text          캠페인 번호 (앞부분 일치, 대소문자 무시)
--     person_name    text          인플루언서 이름 (사람 목록 안 이름에 포함, 대소문자 무시)
--     influencer_id  uuid          인플루언서 (회원 번호 정확히)
--     limit          integer       한 번에 가져올 줄 수 (기본 50, 최대 200)
--     before_at      timestamptz   「더 보기」 커서 — 이 줄보다 오래된 것
--     before_id      uuid          「더 보기」 커서 — before_at 과 같이
--   admin_get_data_access_logs(p_filters):
--     from · to · actor_auth_id · limit · before_at · before_id  (위와 같은 뜻)
--     source         text          어디서 (정확히 일치)
--   기간 형식이 틀리면 22007 오류가 그대로 난다(화면은 날짜 선택기라 정상 호출에선 안 난다).
--
-- ============================================================
-- 롤백 (다른 조각이 이 함수를 부르기 시작한 뒤에는 그 조각부터 먼저 되돌린다)
-- ============================================================
--   DROP FUNCTION IF EXISTS public.admin_get_data_access_logs(jsonb);
--   DROP FUNCTION IF EXISTS public.admin_get_brand_provision_persons(uuid);
--   DROP FUNCTION IF EXISTS public.admin_get_brand_provision_logs(jsonb);
--   DROP FUNCTION IF EXISTS public.record_admin_data_access(text, jsonb, integer, jsonb);
--   DROP FUNCTION IF EXISTS public.service_record_brand_provision(uuid, uuid, text, jsonb, jsonb);
--   DROP FUNCTION IF EXISTS public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text);
--   DROP TABLE IF EXISTS public.personal_data_access_logs;
--   DROP TABLE IF EXISTS public.brand_provision_logs;
--   (표를 지우면 쌓인 기록이 사라진다 — 법 기록이므로 운영에서는 지우기 전에 반드시 사용자 확인)
-- ============================================================

BEGIN;

-- ── 1. 표 ────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.brand_provision_logs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  at            timestamptz NOT NULL DEFAULT now(),
  -- 🔴 외래 키 없음 — 브랜드·캠페인이 지워져도(보관 삭제·delete_brand·merge_brands) 3년 남아야 한다
  brand_id      uuid,
  brand_name    text,
  campaign_id   uuid,
  campaign_no   text,
  actor_auth_id uuid,
  actor_kind    text        NOT NULL CHECK (actor_kind IN ('brand','admin','system')),
  actor_name    text,
  action        text        NOT NULL CHECK (action IN (
                  'shipping_deliver','shipping_auto_add','shipping_view','shipping_excel',
                  'results_view','results_excel',
                  'publish_on','publish_off','publish_columns')),
  columns       jsonb       NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(columns) = 'array'),
  -- [{influencer_id, name}] — name 은 부르는 쪽이 넘긴 값 그대로(결과물은 가린 이름, 배송은 전체 이름)
  persons       jsonb       NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(persons) = 'array'),
  person_count  integer     NOT NULL DEFAULT 0 CHECK (person_count >= 0)
);

COMMENT ON TABLE public.brand_provision_logs IS
  '[P1] 브랜드 제공 기록(보관 3년). 외래 키 없음 — 번호 + 이름 스냅샷. 쓰기는 _record_brand_provision 만, 읽기는 최고 관리자만. 탈퇴 파기(520)는 건드리지 않는다.';

CREATE INDEX IF NOT EXISTS idx_brand_provision_logs_at         ON public.brand_provision_logs (at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_brand_provision_logs_brand      ON public.brand_provision_logs (brand_id, at DESC);
-- D16 합치기 조회용 (같은 계정·캠페인·종류의 최근 줄)
CREATE INDEX IF NOT EXISTS idx_brand_provision_logs_merge      ON public.brand_provision_logs (campaign_id, action, actor_auth_id, at DESC);

CREATE TABLE IF NOT EXISTS public.personal_data_access_logs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  at            timestamptz NOT NULL DEFAULT now(),
  actor_auth_id uuid,
  actor_name    text,
  actor_role    text,
  source        text        NOT NULL,
  columns       jsonb       NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(columns) = 'array'),
  person_count  integer     NOT NULL DEFAULT 0 CHECK (person_count >= 0),
  meta          jsonb       NOT NULL DEFAULT '{}'::jsonb
);

COMMENT ON TABLE public.personal_data_access_logs IS
  '[P1] 관리자 개인정보 접속 기록(보관 1년). 인플루언서 목록은 담지 않는다(몇 명만). 쓰기는 record_admin_data_access 만, 읽기는 최고 관리자만.';

CREATE INDEX IF NOT EXISTS idx_personal_data_access_logs_at    ON public.personal_data_access_logs (at DESC, id DESC);
CREATE INDEX IF NOT EXISTS idx_personal_data_access_logs_actor ON public.personal_data_access_logs (actor_auth_id, at DESC);

-- ── 2. 행 단위 보안 — 읽기 최고 관리자 하나, 쓰기 정책 없음 ──────────

ALTER TABLE public.brand_provision_logs     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.personal_data_access_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS brand_provision_logs_select ON public.brand_provision_logs;
CREATE POLICY brand_provision_logs_select ON public.brand_provision_logs
  FOR SELECT TO authenticated
  USING ((SELECT public.is_super_admin()));

DROP POLICY IF EXISTS personal_data_access_logs_select ON public.personal_data_access_logs;
CREATE POLICY personal_data_access_logs_select ON public.personal_data_access_logs
  FOR SELECT TO authenticated
  USING ((SELECT public.is_super_admin()));

-- [J7] 표 권한도 조인다
REVOKE ALL ON public.brand_provision_logs      FROM anon, authenticated;
REVOKE ALL ON public.personal_data_access_logs FROM anon, authenticated;
GRANT SELECT ON public.brand_provision_logs      TO authenticated;
GRANT SELECT ON public.personal_data_access_logs TO authenticated;

-- ── 3. 내부 함수 — 제공 기록을 쓰는 유일한 길 ───────────────────

CREATE OR REPLACE FUNCTION public._record_brand_provision(
  p_brand_id      uuid,
  p_campaign_id   uuid,
  p_action        text,
  p_columns       jsonb,
  p_persons       jsonb,
  p_actor_auth_id uuid DEFAULT NULL,
  p_actor_kind    text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_actor      uuid;
  v_kind       text;
  v_name       text;
  v_brand_id   uuid := p_brand_id;
  v_brand_name text;
  v_camp_no    text;
  v_columns    jsonb := COALESCE(p_columns, '[]'::jsonb);
  v_persons    jsonb := COALESCE(p_persons, '[]'::jsonb);
  v_existing   public.brand_provision_logs%ROWTYPE;
  v_new_persons jsonb;
BEGIN
  IF jsonb_typeof(v_columns) <> 'array' OR jsonb_typeof(v_persons) <> 'array' THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(v_persons) > 2000 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';   -- [J5]
  END IF;
  -- 같은 회원이 두 번 들어와도 한 번만(회원 번호 기준, 처음 나온 순서 유지) — 합치기 덧붙임·person_count 과다 방지
  SELECT COALESCE(jsonb_agg(d.elem ORDER BY d.ord), '[]'::jsonb) INTO v_persons
    FROM (SELECT DISTINCT ON (COALESCE(p.elem->>'influencer_id', p.ord::text)) p.elem, p.ord
            FROM jsonb_array_elements(v_persons) WITH ORDINALITY AS p(elem, ord)
           ORDER BY COALESCE(p.elem->>'influencer_id', p.ord::text), p.ord) d;

  -- 누가 [J4]
  IF p_actor_kind = 'system' THEN
    v_actor := NULL;
    v_kind  := 'system';
    v_name  := '시스템(자동)';
  ELSE
    v_actor := COALESCE(p_actor_auth_id, (SELECT auth.uid()));
    IF v_actor IS NULL THEN
      RAISE EXCEPTION 'actor_unknown' USING ERRCODE = '22023';
    END IF;
    v_kind := p_actor_kind;
    IF v_kind IS NULL THEN
      IF EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = v_actor) THEN
        v_kind := 'admin';
      ELSIF EXISTS (SELECT 1 FROM public.brand_accounts b WHERE b.auth_id = v_actor) THEN
        v_kind := 'brand';
      ELSE
        RAISE EXCEPTION 'actor_unknown' USING ERRCODE = '22023';
      END IF;
    END IF;
    IF v_kind = 'admin' THEN
      SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email) INTO v_name
        FROM public.admins a WHERE a.auth_id = v_actor LIMIT 1;
    ELSIF v_kind = 'brand' THEN
      SELECT COALESCE(NULLIF(btrim(b.name), ''), b.email) INTO v_name
        FROM public.brand_accounts b WHERE b.auth_id = v_actor LIMIT 1;
    ELSE
      RAISE EXCEPTION 'invalid_actor_kind' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- 브랜드·캠페인 스냅샷 (캠페인이 있으면 캠페인의 브랜드가 우선 — 넘긴 브랜드와 어긋나는 기록을 막는다)
  IF p_campaign_id IS NOT NULL THEN
    SELECT c.campaign_no, COALESCE(v_brand_id, c.brand_id)
      INTO v_camp_no, v_brand_id
      FROM public.campaigns c WHERE c.id = p_campaign_id;
  END IF;
  IF v_brand_id IS NOT NULL THEN
    SELECT b.name INTO v_brand_name FROM public.brands b WHERE b.id = v_brand_id;
  END IF;

  -- D16 합치기 — 열람 계열만, 같은 계정·캠페인·종류가 30분 안이면 새 줄을 만들지 않는다 [J1][J2]
  IF p_action IN ('results_view','shipping_view') AND v_actor IS NOT NULL AND p_campaign_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(v_actor::text || '|' || p_campaign_id::text || '|' || p_action, 0));

    SELECT * INTO v_existing
      FROM public.brand_provision_logs l
     WHERE l.campaign_id   = p_campaign_id
       AND l.action        = p_action
       AND l.actor_auth_id = v_actor
       AND l.at            > now() - interval '30 minutes'
     ORDER BY l.at DESC
     LIMIT 1;

    IF FOUND THEN
      -- 기존 줄에 없는 사람만 덧붙인다(회원 번호 기준)
      SELECT COALESCE(jsonb_agg(p.elem), '[]'::jsonb) INTO v_new_persons
        FROM jsonb_array_elements(v_persons) AS p(elem)
       WHERE NOT EXISTS (
               SELECT 1 FROM jsonb_array_elements(v_existing.persons) AS e(elem)
                WHERE e.elem->>'influencer_id' IS NOT DISTINCT FROM p.elem->>'influencer_id');

      IF jsonb_array_length(v_new_persons) > 0 OR NOT (v_columns <@ v_existing.columns) THEN
        UPDATE public.brand_provision_logs l
           SET persons      = l.persons || v_new_persons,
               person_count = l.person_count + jsonb_array_length(v_new_persons),
               columns      = (SELECT COALESCE(jsonb_agg(DISTINCT x), '[]'::jsonb)
                                 FROM jsonb_array_elements(l.columns || v_columns) AS t(x))
         WHERE l.id = v_existing.id;
      END IF;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.brand_provision_logs
    (brand_id, brand_name, campaign_id, campaign_no, actor_auth_id, actor_kind, actor_name,
     action, columns, persons, person_count)
  VALUES
    (v_brand_id, v_brand_name, p_campaign_id, v_camp_no, v_actor, v_kind, v_name,
     p_action, v_columns, v_persons, jsonb_array_length(v_persons));
  -- p_action 이 9개 밖이면 CHECK 위반(23514)으로 거부된다
END;
$$;

COMMENT ON FUNCTION public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text) IS
  '[P1] 브랜드 제공 기록을 쓰는 유일한 길(내부 전용). 브랜드 이름·캠페인 번호 스냅샷은 여기서 채우고 사람 이름은 넘긴 값 그대로. D16 합치기(열람 계열 30분)도 이 한 곳. actor 를 비우면 auth.uid(), 자동 추가는 p_actor_kind=''system''.';

-- ── 4. 서버 전용 입구 — 브랜드 결과물 서버 함수가 부른다 ─────────

CREATE OR REPLACE FUNCTION public.service_record_brand_provision(
  p_actor_auth_id uuid,
  p_campaign_id   uuid,
  p_action        text,
  p_columns       jsonb,
  p_persons       jsonb
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_brand_id uuid;
BEGIN
  IF p_actor_auth_id IS NULL OR p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;
  -- [J3] 브랜드가 만들 수 있는 종류 넷만
  IF p_action NOT IN ('shipping_view','shipping_excel','results_view','results_excel') THEN
    RAISE EXCEPTION 'invalid_action' USING ERRCODE = '22023';
  END IF;

  SELECT c.brand_id INTO v_brand_id FROM public.campaigns c WHERE c.id = p_campaign_id;
  IF v_brand_id IS NULL THEN
    RAISE EXCEPTION 'campaign_not_found' USING ERRCODE = 'P0002';
  END IF;

  -- [J3] 받은 계정이 그 브랜드에 활성 연결된 브랜드 계정인가 — 530 my_brand_role 식의 사본(활성 연결 + 활성 브랜드)
  IF NOT EXISTS (
    SELECT 1
      FROM public.brand_account_links l
      JOIN public.brands b ON b.id = l.brand_id
     WHERE l.auth_id  = p_actor_auth_id
       AND l.brand_id = v_brand_id
       AND l.status   = 'active'
       AND b.status   = 'active'
  ) THEN
    RAISE EXCEPTION 'not_brand_account' USING ERRCODE = '42501';
  END IF;

  PERFORM public._record_brand_provision(v_brand_id, p_campaign_id, p_action, p_columns, p_persons, p_actor_auth_id, 'brand');
END;
$$;

COMMENT ON FUNCTION public.service_record_brand_provision(uuid, uuid, text, jsonb, jsonb) IS
  '[P1] 서버 함수(brand-campaign-results 등)가 서비스 키로 부르는 브랜드 제공 기록 입구. service_role 전용. 브랜드 번호는 캠페인에서 읽고 계정 연결을 검사한다.';

-- ── 5. 관리자 접속 기록 ──────────────────────────────────────

CREATE OR REPLACE FUNCTION public.record_admin_data_access(
  p_source       text,
  p_columns      jsonb,
  p_person_count integer,
  p_meta         jsonb
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid  uuid := (SELECT auth.uid());
  v_name text;
  v_role text;
  v_cols jsonb := COALESCE(p_columns, '[]'::jsonb);
  v_meta jsonb := COALESCE(p_meta, '{}'::jsonb);
  v_id   uuid;
BEGIN
  IF v_uid IS NULL OR NOT (SELECT public.is_admin()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_source IS NULL OR btrim(p_source) = '' OR length(p_source) > 100 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(v_cols) <> 'array' OR jsonb_typeof(v_meta) <> 'object'
     OR COALESCE(p_person_count, 0) < 0 OR pg_column_size(v_meta) > 8192 OR pg_column_size(v_cols) > 8192 THEN
    RAISE EXCEPTION 'invalid_payload' USING ERRCODE = '22023';   -- [J8]
  END IF;

  SELECT COALESCE(NULLIF(btrim(a.name), ''), a.email), a.role INTO v_name, v_role
    FROM public.admins a WHERE a.auth_id = v_uid LIMIT 1;

  INSERT INTO public.personal_data_access_logs
    (actor_auth_id, actor_name, actor_role, source, columns, person_count, meta)
  VALUES
    (v_uid, v_name, v_role, btrim(p_source), v_cols, COALESCE(p_person_count, 0), v_meta)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

COMMENT ON FUNCTION public.record_admin_data_access(text, jsonb, integer, jsonb) IS
  '[P1] 관리자 개인정보 접속 기록 쓰기(authenticated, 안에서 is_admin() 가드). 관리자 이름·등급은 서버가 스냅샷. 실패면 예외 — 화면이 「기록 실패」로 읽는다.';

-- ── 6. 읽기 함수 셋 (최고 관리자만) ───────────────────────────

CREATE OR REPLACE FUNCTION public.admin_get_brand_provision_logs(p_filters jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  f          jsonb := COALESCE(p_filters, '{}'::jsonb);
  v_limit    integer := LEAST(GREATEST(COALESCE(NULLIF(f->>'limit','')::integer, 50), 1), 200);
  v_from     timestamptz;
  v_to       timestamptz;
  v_before_at timestamptz := NULLIF(f->>'before_at','')::timestamptz;
  v_before_id uuid        := NULLIF(f->>'before_id','')::uuid;
  v_brand    uuid := NULLIF(f->>'brand_id','')::uuid;
  v_actor    uuid := NULLIF(f->>'actor_auth_id','')::uuid;
  v_kind     text := NULLIF(f->>'actor_kind','');
  v_action   text := NULLIF(f->>'action','');
  v_campaign uuid := NULLIF(f->>'campaign_id','')::uuid;
  v_camp_no  text := NULLIF(btrim(COALESCE(f->>'campaign_no','')),'');
  v_pname    text := NULLIF(btrim(COALESCE(f->>'person_name','')),'');
  v_inf      text := NULLIF(f->>'influencer_id','');
  v_rows     jsonb;
  v_count    integer;
BEGIN
  IF NOT (SELECT public.is_super_admin()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(f->>'from','') IS NOT NULL THEN
    v_from := ((f->>'from')::date)::timestamp AT TIME ZONE 'Asia/Tokyo';
  END IF;
  IF NULLIF(f->>'to','') IS NOT NULL THEN
    v_to := (((f->>'to')::date) + 1)::timestamp AT TIME ZONE 'Asia/Tokyo';   -- to 그날 끝까지 = 다음 날 0시 미만
  END IF;
  -- LIKE 특수문자 이스케이프
  IF v_camp_no IS NOT NULL THEN v_camp_no := replace(replace(replace(v_camp_no,'\','\\'),'%','\%'),'_','\_'); END IF;
  IF v_pname   IS NOT NULL THEN v_pname   := replace(replace(replace(v_pname,'\','\\'),'%','\%'),'_','\_'); END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.at DESC, t.id DESC), '[]'::jsonb), count(*)
    INTO v_rows, v_count
    FROM (
      SELECT l.id, l.at, l.brand_id, l.brand_name, l.campaign_id, l.campaign_no,
             l.actor_auth_id, l.actor_kind, l.actor_name, l.action, l.columns, l.person_count
        FROM public.brand_provision_logs l
       WHERE (v_from   IS NULL OR l.at >= v_from)
         AND (v_to     IS NULL OR l.at <  v_to)
         AND (v_brand  IS NULL OR l.brand_id = v_brand)
         AND (v_actor  IS NULL OR l.actor_auth_id = v_actor)
         AND (v_kind   IS NULL OR l.actor_kind = v_kind)
         AND (v_action IS NULL OR l.action = v_action)
         AND (v_campaign IS NULL OR l.campaign_id = v_campaign)
         AND (v_camp_no IS NULL OR l.campaign_no ILIKE v_camp_no || '%' ESCAPE '\')
         AND (v_inf    IS NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(l.persons) e(elem) WHERE e.elem->>'influencer_id' = v_inf))
         AND (v_pname  IS NULL OR EXISTS (SELECT 1 FROM jsonb_array_elements(l.persons) e(elem) WHERE e.elem->>'name' ILIKE '%' || v_pname || '%' ESCAPE '\'))
         AND (v_before_at IS NULL OR (l.at, l.id) < (v_before_at, COALESCE(v_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
       ORDER BY l.at DESC, l.id DESC
       LIMIT v_limit + 1
    ) t;

  -- 한 줄 더 가져와 has_more 를 가른 뒤 그 한 줄은 버린다
  IF v_count > v_limit THEN
    v_rows := (SELECT COALESCE(jsonb_agg(x.elem ORDER BY x.ord), '[]'::jsonb)
                 FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS x(elem, ord)
                WHERE x.ord <= v_limit);
  END IF;
  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_count > v_limit);
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_provision_logs(jsonb) IS
  '[P1] 브랜드 제공 기록 목록(최고 관리자). 필터 키: from·to(일본 날짜)·brand_id·actor_auth_id·actor_kind·action·campaign_id·campaign_no·person_name·influencer_id·limit(≤200)·before_at·before_id. 반환 {rows,has_more}, 줄에 persons 는 없음(person_count 만).';

CREATE OR REPLACE FUNCTION public.admin_get_brand_provision_persons(p_log_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_persons jsonb;
BEGIN
  IF NOT (SELECT public.is_super_admin()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  SELECT l.persons INTO v_persons FROM public.brand_provision_logs l WHERE l.id = p_log_id;
  RETURN COALESCE(v_persons, '[]'::jsonb);   -- 없는 줄도 빈 배열(존재 여부를 구분하지 않는다)
END;
$$;

COMMENT ON FUNCTION public.admin_get_brand_provision_persons(uuid) IS
  '[P1] 제공 기록 한 줄의 인플루언서 목록 [{influencer_id, name}] (최고 관리자 전용 — 「사람 보기」).';

CREATE OR REPLACE FUNCTION public.admin_get_data_access_logs(p_filters jsonb)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  f          jsonb := COALESCE(p_filters, '{}'::jsonb);
  v_limit    integer := LEAST(GREATEST(COALESCE(NULLIF(f->>'limit','')::integer, 50), 1), 200);
  v_from     timestamptz;
  v_to       timestamptz;
  v_before_at timestamptz := NULLIF(f->>'before_at','')::timestamptz;
  v_before_id uuid        := NULLIF(f->>'before_id','')::uuid;
  v_actor    uuid := NULLIF(f->>'actor_auth_id','')::uuid;
  v_source   text := NULLIF(f->>'source','');
  v_rows     jsonb;
  v_count    integer;
BEGIN
  IF NOT (SELECT public.is_super_admin()) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(f->>'from','') IS NOT NULL THEN
    v_from := ((f->>'from')::date)::timestamp AT TIME ZONE 'Asia/Tokyo';
  END IF;
  IF NULLIF(f->>'to','') IS NOT NULL THEN
    v_to := (((f->>'to')::date) + 1)::timestamp AT TIME ZONE 'Asia/Tokyo';
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.at DESC, t.id DESC), '[]'::jsonb), count(*)
    INTO v_rows, v_count
    FROM (
      SELECT l.id, l.at, l.actor_auth_id, l.actor_name, l.actor_role, l.source, l.columns, l.person_count, l.meta
        FROM public.personal_data_access_logs l
       WHERE (v_from   IS NULL OR l.at >= v_from)
         AND (v_to     IS NULL OR l.at <  v_to)
         AND (v_actor  IS NULL OR l.actor_auth_id = v_actor)
         AND (v_source IS NULL OR l.source = v_source)
         AND (v_before_at IS NULL OR (l.at, l.id) < (v_before_at, COALESCE(v_before_id, 'ffffffff-ffff-ffff-ffff-ffffffffffff'::uuid)))
       ORDER BY l.at DESC, l.id DESC
       LIMIT v_limit + 1
    ) t;

  IF v_count > v_limit THEN
    v_rows := (SELECT COALESCE(jsonb_agg(x.elem ORDER BY x.ord), '[]'::jsonb)
                 FROM jsonb_array_elements(v_rows) WITH ORDINALITY AS x(elem, ord)
                WHERE x.ord <= v_limit);
  END IF;
  RETURN jsonb_build_object('rows', v_rows, 'has_more', v_count > v_limit);
END;
$$;

COMMENT ON FUNCTION public.admin_get_data_access_logs(jsonb) IS
  '[P1] 관리자 접속 기록 목록(최고 관리자). 필터 키: from·to(일본 날짜)·actor_auth_id·source·limit(≤200)·before_at·before_id. 반환 {rows,has_more}.';

-- ── 7. 실행 권한 ─────────────────────────────────────────────
-- 🔴 회수는 두 방향이다(PUBLIC 과 anon·authenticated 각각 — 서로 대신하지 못한다).
-- 🔴 service_role 은 부여 먼저, 회수 나중(375 순서). 부여를 전부 앞에 모은다.

-- 부여
GRANT EXECUTE ON FUNCTION public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text)      TO postgres;
GRANT EXECUTE ON FUNCTION public.service_record_brand_provision(uuid, uuid, text, jsonb, jsonb)           TO postgres, service_role;
GRANT EXECUTE ON FUNCTION public.record_admin_data_access(text, jsonb, integer, jsonb)                    TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_brand_provision_logs(jsonb)                                    TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_brand_provision_persons(uuid)                                  TO postgres, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_get_data_access_logs(jsonb)                                        TO postgres, authenticated, service_role;

-- 내부 함수(③) — 셋 다 회수. 안쪽 호출은 감싸는 함수가 SECURITY DEFINER(postgres 소유)라 산다.
REVOKE EXECUTE ON FUNCTION public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text) FROM anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._record_brand_provision(uuid, uuid, text, jsonb, jsonb, uuid, text) FROM service_role;

-- 서버 전용(④) — service_role 만
REVOKE EXECUTE ON FUNCTION public.service_record_brand_provision(uuid, uuid, text, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.service_record_brand_provision(uuid, uuid, text, jsonb, jsonb) FROM anon, authenticated;

-- 관리자 화면이 부르는 넷(⑤⑥) — authenticated 만(안쪽 가드가 최종), 비로그인은 막는다
REVOKE EXECUTE ON FUNCTION public.record_admin_data_access(text, jsonb, integer, jsonb)   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.record_admin_data_access(text, jsonb, integer, jsonb)   FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_provision_logs(jsonb)                   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_provision_logs(jsonb)                   FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_provision_persons(uuid)                 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_brand_provision_persons(uuid)                 FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_get_data_access_logs(jsonb)                       FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_data_access_logs(jsonb)                       FROM anon;

COMMIT;

-- ============================================================
-- 적용 뒤 확인 (한 단계씩 — 앞 결과를 보고 다음으로. 개발서버에서 먼저)
-- ============================================================
-- ※ SQL 편집기는 서비스 권한이라 auth.uid() 가 비어 있다. 아래 ①~③은 그 성질을 이용한 거부 확인이고,
--   성공 호출은 로그인한 브라우저(최고 관리자) 콘솔에서 한다.
--
-- [1단계] 권한 조회 — 기대: _record_… 는 authenticated=false·service_role=false, service_record_… 는 service_role=true·authenticated=false,
--         나머지 넷은 authenticated=true·anon=false. proacl 맨 앞에 `=X/` 가 없어야 한다(PUBLIC 부여 없음).
--   SELECT p.proname,
--          has_function_privilege('anon',          p.oid, 'EXECUTE') AS anon_ok,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_ok,
--          has_function_privilege('service_role',  p.oid, 'EXECUTE') AS svc_ok,
--          p.proacl::text AS acl
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN ('_record_brand_provision','service_record_brand_provision','record_admin_data_access',
--                        'admin_get_brand_provision_logs','admin_get_brand_provision_persons','admin_get_data_access_logs')
--    ORDER BY p.proname;
--
-- [2단계] 표 확인 — 기대: 두 표 모두 rowsecurity=true, 정책 1개씩(SELECT)
--   SELECT c.relname, c.relrowsecurity FROM pg_class c WHERE c.relname IN ('brand_provision_logs','personal_data_access_logs');
--   SELECT tablename, policyname, cmd FROM pg_policies WHERE tablename IN ('brand_provision_logs','personal_data_access_logs');
--
-- [3단계] 서버 전용 입구 호출(SQL 편집기 = 서비스 권한). 시험용 브랜드 계정(zz-b2-owner)과 그 브랜드의 캠페인 번호를 넣는다.
--   기대: 계정 연결이 맞으면 오류 없이 끝남 → 4단계에서 줄 확인. 맞지 않는 계정이면 not_brand_account(42501).
--   SELECT public.service_record_brand_provision(
--            '<zz-b2-owner 의 auth_id>'::uuid, '<그 브랜드 캠페인 id>'::uuid, 'results_view',
--            '["reward"]'::jsonb, '[{"influencer_id":"00000000-0000-0000-0000-000000000001","name":"테*"}]'::jsonb);
--   같은 호출을 한 번 더 → 줄이 늘지 않아야 한다(D16). 'results_excel' 로 부르면 새 줄이 생긴다.
--
-- [4단계] 줄 확인 및 시험 줄 정리(개발서버 한정)
--   SELECT at, brand_name, campaign_no, actor_kind, actor_name, action, person_count FROM public.brand_provision_logs ORDER BY at DESC LIMIT 5;
--   DELETE FROM public.brand_provision_logs WHERE persons @> '[{"influencer_id":"00000000-0000-0000-0000-000000000001"}]'::jsonb;
--
-- [5단계] 로그인한 브라우저 콘솔 — 최고 관리자 (개발서버 관리자 화면에서 supabase 클라이언트 변수 이름은 `db`)
--   await db.rpc('record_admin_data_access', {p_source:'test', p_columns:['phone'], p_person_count:1, p_meta:{}})   // → uuid
--   await db.rpc('admin_get_data_access_logs', {p_filters:{limit:5}})                                               // → {rows:[…], has_more}
--   await db.rpc('admin_get_brand_provision_logs', {p_filters:{limit:5}})
--   await db.rpc('admin_get_brand_provision_persons', {p_log_id:'<위 줄 id>'})
--   캠페인 관리자·매니저로 로그인하면 읽기 셋은 모두 42501, record_admin_data_access 는 성공해야 한다. 비로그인은 모두 권한 오류.
--   시험 줄 정리: DELETE FROM public.personal_data_access_logs WHERE source = 'test';
--
-- [6단계] 520 확인 — 기대: 0행
--   SELECT 1 FROM pg_proc WHERE proname = 'purge_withdrawn_personal_data'
--      AND pg_get_functiondef(oid) ~ '(brand_provision_logs|personal_data_access_logs)';
