-- ════════════════════════════════════════════════════════════════════
-- migration 121: 캠페인-신청 연결/해제 원격 호출 함수 2종
-- ────────────────────────────────────────────────────────────────────
-- 사양: docs/specs/2026-05-13-brand-ops-redesign.md §4-5
-- 의존: 088~090 (계층 채번), 118~120 (회사·운영현황 RPC)
--
-- 신규 함수:
--   1. _accumulate_legacy_no(p_existing text, p_current text) RETURNS text
--        legacy_no 콤마 누적 헬퍼. 중복 추가 방어. 순수 함수(IMMUTABLE).
--
--   2. link_campaign_to_application(p_campaign_id uuid, p_application_id uuid) RETURNS jsonb
--        직접 등록 캠페인 또는 다른 신청에 묶인 캠페인을 지정한 신청으로 연결.
--        - 같은 brand_id 검증
--        - source_application_id 변경 + 새 채번(B{B}-A{A}-C{new}) 발급
--        - 이전 campaign_no는 campaigns.legacy_no 에 콤마 누적
--        - numbering_legacy_map 매핑 갱신(new_no 만)
--        - 동일 application 재호출은 no-op + unchanged:true 반환
--        - 가드: is_campaign_admin()
--
--   3. unlink_campaign_from_application(p_campaign_id uuid) RETURNS jsonb
--        신청에 연결된 캠페인을 직접 등록 캠페인으로 되돌림.
--        - source_application_id := NULL + 새 채번(B{B}-C{new}) 발급
--        - 이전 campaign_no는 legacy_no 콤마 누적
--        - numbering_legacy_map 매핑 갱신
--        - 이미 직접 등록(source_application_id IS NULL) 캠페인은 no-op + unchanged:true
--        - 가드: is_campaign_admin()
--
-- 동시성:
--   pg_advisory_xact_lock 으로 직렬화. 잠금 순서 고정 → 데드락 회피:
--     link  : campaign_id → application_id
--     unlink: campaign_id → brand_id
--   (사양서의 "version 낙관적 락"은 campaigns.version 컬럼이 없어 advisory lock 단독으로 대체)
--
-- 권한:
--   SECURITY DEFINER + SET search_path = ''
--   REVOKE FROM PUBLIC/anon, GRANT EXECUTE TO authenticated (120 패턴 동일)
--   가드 함수 is_campaign_admin() 가 1차 방어선 — 인플루언서 호출 시 42501
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.unlink_campaign_from_application(uuid);
--   DROP FUNCTION IF EXISTS public.link_campaign_to_application(uuid, uuid);
--   DROP FUNCTION IF EXISTS public._accumulate_legacy_no(text, text);
-- ════════════════════════════════════════════════════════════════════

BEGIN;


-- ════════════════════════════════════════════════════════════════════
-- SECTION 1. 내부 헬퍼 — legacy_no 콤마 누적 (중복 방어)
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public._accumulate_legacy_no(
  p_existing text,
  p_current  text
)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v_parts text[];
BEGIN
  IF p_current IS NULL OR p_current = '' THEN
    RETURN p_existing;
  END IF;

  IF p_existing IS NULL OR p_existing = '' THEN
    RETURN p_current;
  END IF;

  -- 콤마 분리해서 이미 포함되어 있으면 누적 안 함
  v_parts := string_to_array(p_existing, ',');
  IF p_current = ANY(v_parts) THEN
    RETURN p_existing;
  END IF;

  RETURN p_existing || ',' || p_current;
END;
$$;

COMMENT ON FUNCTION public._accumulate_legacy_no(text, text) IS
  '[121] legacy_no 콤마 누적 헬퍼. 중복 추가 방어 포함. 외부 호출 차단 — link/unlink 내부 전용.';

REVOKE ALL ON FUNCTION public._accumulate_legacy_no(text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._accumulate_legacy_no(text, text) FROM authenticated;
REVOKE ALL ON FUNCTION public._accumulate_legacy_no(text, text) FROM anon;


-- ════════════════════════════════════════════════════════════════════
-- SECTION 2. link_campaign_to_application
-- ────────────────────────────────────────────────────────────────────
-- 캠페인을 신청에 연결. 새 채번 B{brand_seq}-A{app_seq}-C{new_camp_seq}.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.link_campaign_to_application(
  p_campaign_id    uuid,
  p_application_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign        record;
  v_application     record;
  v_brand_seq       integer;
  v_app_seq         integer;
  v_camp_seq        integer;
  v_old_no          text;
  v_new_no          text;
  v_new_legacy_no   text;
BEGIN
  -- 1차 방어선: 권한 가드
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION 'forbidden: requires campaign_admin or higher'
      USING ERRCODE = '42501';
  END IF;

  IF p_campaign_id IS NULL OR p_application_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id and application_id are required'
      USING ERRCODE = '22023';
  END IF;

  -- ── 잠금 1: campaign_id (먼저 잡아 데드락 방지)
  PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::text)::bigint);

  -- 캠페인 조회
  SELECT id, brand_id, source_application_id, campaign_no, legacy_no
    INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found: %', p_campaign_id
      USING ERRCODE = '22023';
  END IF;

  -- 멱등성: 이미 같은 신청에 연결되어 있으면 no-op
  IF v_campaign.source_application_id = p_application_id THEN
    RETURN jsonb_build_object(
      'campaign_id',    v_campaign.id,
      'old_no',         v_campaign.campaign_no,
      'new_no',         v_campaign.campaign_no,
      'application_id', p_application_id,
      'unchanged',      true
    );
  END IF;

  -- brand_id 누락 캠페인(legacy) 은 차단 — brand_seq를 알 수 없어 새 번호 발급 불가
  IF v_campaign.brand_id IS NULL THEN
    RAISE EXCEPTION 'campaign has no brand_id (legacy row); assign a brand to the campaign first'
      USING ERRCODE = '22023';
  END IF;

  -- 신청 조회
  SELECT id, brand_id, application_no
    INTO v_application
    FROM public.brand_applications
   WHERE id = p_application_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application not found: %', p_application_id
      USING ERRCODE = '22023';
  END IF;

  -- 같은 브랜드 검증
  IF v_application.brand_id IS NULL OR v_application.brand_id <> v_campaign.brand_id THEN
    RAISE EXCEPTION
      'campaign and application must belong to the same brand (campaign.brand_id=%, application.brand_id=%)',
      v_campaign.brand_id, v_application.brand_id
      USING ERRCODE = '22023';
  END IF;

  -- ── 잠금 2: application_id (카운터 직렬화)
  PERFORM pg_advisory_xact_lock(hashtext(p_application_id::text)::bigint);

  -- brand_seq 조회
  SELECT brand_seq INTO v_brand_seq
    FROM public.brands
   WHERE id = v_campaign.brand_id;

  IF v_brand_seq IS NULL THEN
    RAISE EXCEPTION 'brands.brand_seq is NULL for brand_id=%', v_campaign.brand_id
      USING ERRCODE = '22023';
  END IF;

  -- application_no 형식 검증 + A 세그먼트 파싱
  IF v_application.application_no SIMILAR TO 'B[0-9]{4}-A[0-9]{3}' THEN
    v_app_seq := split_part(v_application.application_no, '-A', 2)::integer;
  ELSE
    RAISE EXCEPTION 'application_no format unexpected: % (expected B####-A###)',
      v_application.application_no
      USING ERRCODE = '22023';
  END IF;

  -- application_campaign_counter atomic 증가
  INSERT INTO public.application_campaign_counter (application_id, last_seq)
  VALUES (p_application_id, 1)
  ON CONFLICT (application_id)
  DO UPDATE SET last_seq = public.application_campaign_counter.last_seq + 1
  RETURNING last_seq INTO v_camp_seq;

  IF v_camp_seq > 999 THEN
    RAISE EXCEPTION 'C-seq overflow (>999) for application_id=%', p_application_id
      USING ERRCODE = '22003';
  END IF;

  v_old_no := v_campaign.campaign_no;
  v_new_no := 'B' || lpad(v_brand_seq::text, 4, '0')
           || '-A' || lpad(v_app_seq::text, 3, '0')
           || '-C' || lpad(v_camp_seq::text, 3, '0');

  v_new_legacy_no := public._accumulate_legacy_no(v_campaign.legacy_no, v_old_no);

  -- campaigns 행 갱신 (단일 UPDATE)
  UPDATE public.campaigns
     SET source_application_id = p_application_id,
         campaign_no           = v_new_no,
         legacy_no             = v_new_legacy_no,
         updated_at            = now()
   WHERE id = p_campaign_id;

  -- numbering_legacy_map UPSERT — new_no만 최신값으로 덮어쓰기
  -- (legacy_no 필드는 최초 이주 시점 원래 번호 유지, ON CONFLICT 시 변경 안 함)
  INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
  VALUES (
    'campaign',
    p_campaign_id,
    COALESCE(v_campaign.legacy_no, v_old_no),
    v_new_no,
    now()
  )
  ON CONFLICT (entity_type, entity_id)
  DO UPDATE SET new_no      = EXCLUDED.new_no,
                migrated_at = now();

  RETURN jsonb_build_object(
    'campaign_id',    p_campaign_id,
    'old_no',         v_old_no,
    'new_no',         v_new_no,
    'application_id', p_application_id,
    'unchanged',      false
  );
END;
$$;

COMMENT ON FUNCTION public.link_campaign_to_application(uuid, uuid) IS
  '[121] 캠페인을 신청에 연결. 채번 B{B}-A{A}-C{C}. legacy_no 콤마 누적, numbering_legacy_map 갱신. 같은 brand_id 강제, is_campaign_admin() 가드.';

REVOKE ALL ON FUNCTION public.link_campaign_to_application(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.link_campaign_to_application(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.link_campaign_to_application(uuid, uuid) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- SECTION 3. unlink_campaign_from_application
-- ────────────────────────────────────────────────────────────────────
-- 캠페인을 직접 등록 캠페인으로 되돌림. 새 채번 B{brand_seq}-C{new_ext_seq}.
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.unlink_campaign_from_application(
  p_campaign_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_campaign        record;
  v_brand_seq       integer;
  v_ext_seq         integer;
  v_old_no          text;
  v_new_no          text;
  v_new_legacy_no   text;
BEGIN
  -- 1차 방어선: 권한 가드
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION 'forbidden: requires campaign_admin or higher'
      USING ERRCODE = '42501';
  END IF;

  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'campaign_id is required'
      USING ERRCODE = '22023';
  END IF;

  -- ── 잠금 1: campaign_id
  PERFORM pg_advisory_xact_lock(hashtext(p_campaign_id::text)::bigint);

  -- 캠페인 조회
  SELECT id, brand_id, source_application_id, campaign_no, legacy_no
    INTO v_campaign
    FROM public.campaigns
   WHERE id = p_campaign_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'campaign not found: %', p_campaign_id
      USING ERRCODE = '22023';
  END IF;

  -- 멱등성: 이미 직접 등록 캠페인이면 no-op
  IF v_campaign.source_application_id IS NULL THEN
    RETURN jsonb_build_object(
      'campaign_id', v_campaign.id,
      'old_no',      v_campaign.campaign_no,
      'new_no',      v_campaign.campaign_no,
      'unchanged',   true
    );
  END IF;

  IF v_campaign.brand_id IS NULL THEN
    RAISE EXCEPTION 'campaign has no brand_id (legacy row); cannot generate external campaign_no'
      USING ERRCODE = '22023';
  END IF;

  -- ── 잠금 2: brand_id (외부 캠페인 카운터 직렬화)
  PERFORM pg_advisory_xact_lock(hashtext(v_campaign.brand_id::text)::bigint);

  -- brand_seq 조회
  SELECT brand_seq INTO v_brand_seq
    FROM public.brands
   WHERE id = v_campaign.brand_id;

  IF v_brand_seq IS NULL THEN
    RAISE EXCEPTION 'brands.brand_seq is NULL for brand_id=%', v_campaign.brand_id
      USING ERRCODE = '22023';
  END IF;

  -- brand_external_campaign_counter atomic 증가
  INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
  VALUES (v_campaign.brand_id, 1)
  ON CONFLICT (brand_id)
  DO UPDATE SET last_seq = public.brand_external_campaign_counter.last_seq + 1
  RETURNING last_seq INTO v_ext_seq;

  IF v_ext_seq > 999 THEN
    RAISE EXCEPTION 'ext-C-seq overflow (>999) for brand_id=%', v_campaign.brand_id
      USING ERRCODE = '22003';
  END IF;

  v_old_no := v_campaign.campaign_no;
  v_new_no := 'B' || lpad(v_brand_seq::text, 4, '0')
           || '-C' || lpad(v_ext_seq::text, 3, '0');

  v_new_legacy_no := public._accumulate_legacy_no(v_campaign.legacy_no, v_old_no);

  -- campaigns 행 갱신
  UPDATE public.campaigns
     SET source_application_id = NULL,
         campaign_no           = v_new_no,
         legacy_no             = v_new_legacy_no,
         updated_at            = now()
   WHERE id = p_campaign_id;

  -- numbering_legacy_map UPSERT
  INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
  VALUES (
    'campaign',
    p_campaign_id,
    COALESCE(v_campaign.legacy_no, v_old_no),
    v_new_no,
    now()
  )
  ON CONFLICT (entity_type, entity_id)
  DO UPDATE SET new_no      = EXCLUDED.new_no,
                migrated_at = now();

  RETURN jsonb_build_object(
    'campaign_id', p_campaign_id,
    'old_no',      v_old_no,
    'new_no',      v_new_no,
    'unchanged',   false
  );
END;
$$;

COMMENT ON FUNCTION public.unlink_campaign_from_application(uuid) IS
  '[121] 신청 연결 캠페인을 직접 등록 캠페인으로 환원. 채번 B{B}-C{C}. legacy_no 콤마 누적, numbering_legacy_map 갱신. is_campaign_admin() 가드.';

REVOKE ALL ON FUNCTION public.unlink_campaign_from_application(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.unlink_campaign_from_application(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.unlink_campaign_from_application(uuid) TO authenticated;


-- ════════════════════════════════════════════════════════════════════
-- PostgREST 스키마 캐시 재로드
-- ════════════════════════════════════════════════════════════════════
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 검증 SQL (트랜잭션 밖, SQL Editor 에서 수동 실행)
-- ────────────────────────────────────────────────────────────────────
/*

-- [V1] 함수 3종 존재 확인
SELECT proname, pronargs
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND proname IN ('_accumulate_legacy_no',
                   'link_campaign_to_application',
                   'unlink_campaign_from_application')
 ORDER BY proname;
-- 3행

-- [V2] 권한 확인 — link/unlink 는 authenticated 만 EXECUTE
SELECT proname,
       has_function_privilege('authenticated', oid, 'EXECUTE') AS auth_exec,
       has_function_privilege('anon', oid, 'EXECUTE')          AS anon_exec
  FROM pg_proc
 WHERE proname IN ('link_campaign_to_application',
                   'unlink_campaign_from_application');
-- auth_exec=true, anon_exec=false

-- [V3] 권한 가드 — anon 호출 시 42501 (실제로는 권한 부재로 함수 미발견 에러)
-- (별도 anon 컨텍스트에서 .rpc() 호출하여 확인)

-- [V4] _accumulate_legacy_no 순수 함수 동작
SELECT
  public._accumulate_legacy_no(NULL, 'B0001-C001')                AS t1,  -- 'B0001-C001'
  public._accumulate_legacy_no('B0001-C001', 'B0001-C002')        AS t2,  -- 'B0001-C001,B0001-C002'
  public._accumulate_legacy_no('B0001-C001', 'B0001-C001')        AS t3,  -- 'B0001-C001' (중복 방어)
  public._accumulate_legacy_no('A,B,C', 'B')                      AS t4;  -- 'A,B,C'

-- [V5] link 동작 시나리오 (실제 데이터 기준)
-- 준비: 같은 브랜드의 직접 등록 캠페인 1개 + 신청 1개 확보
BEGIN;

WITH target AS (
  SELECT c.id AS campaign_id, c.brand_id, c.campaign_no AS old_no,
         (SELECT id FROM public.brand_applications a
           WHERE a.brand_id = c.brand_id LIMIT 1) AS application_id
    FROM public.campaigns c
   WHERE c.source_application_id IS NULL
     AND c.brand_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM public.brand_applications a WHERE a.brand_id = c.brand_id)
   LIMIT 1
)
SELECT public.link_campaign_to_application(
         (SELECT campaign_id FROM target),
         (SELECT application_id FROM target)
       ) AS link_result;
-- {"campaign_id":"...","old_no":"B####-C###","new_no":"B####-A###-C###",
--  "application_id":"...","unchanged":false}

-- 변경 확인
SELECT campaign_no, legacy_no, source_application_id
  FROM public.campaigns
 WHERE id = (SELECT campaign_id FROM (
              SELECT c.id AS campaign_id FROM public.campaigns c
              WHERE c.source_application_id IS NOT NULL LIMIT 1) x);

ROLLBACK;


-- [V6] unlink 동작 시나리오
BEGIN;

WITH target AS (
  SELECT id AS campaign_id, campaign_no AS old_no
    FROM public.campaigns
   WHERE source_application_id IS NOT NULL
     AND brand_id IS NOT NULL
   LIMIT 1
)
SELECT public.unlink_campaign_from_application(
         (SELECT campaign_id FROM target)
       ) AS unlink_result;
-- {"campaign_id":"...","old_no":"B####-A###-C###","new_no":"B####-C###",
--  "unchanged":false}

ROLLBACK;


-- [V7] 멱등성 — 이미 연결된 신청에 같은 신청 재호출
BEGIN;

WITH already_linked AS (
  SELECT id AS campaign_id, source_application_id
    FROM public.campaigns
   WHERE source_application_id IS NOT NULL LIMIT 1
)
SELECT public.link_campaign_to_application(
         (SELECT campaign_id FROM already_linked),
         (SELECT source_application_id FROM already_linked)
       ) AS noop_result;
-- {"unchanged":true, ...}

ROLLBACK;


-- [V8] 다른 브랜드 신청에 연결 시도 → 22023 에러
-- (수동 실행: 캠페인 X의 brand_id 와 다른 신청 Y의 brand_id 가 다른 케이스)

-- [V9] brand_id NULL legacy 캠페인 link 시도 → 22023 에러
-- (legacy 캠페인이 남아 있는 경우만 의미 있음)

-- [V10] 권한 — 인플루언서(authenticated 이지만 admins 미등록) 호출 시 42501
-- (별도 세션에서 anon Supabase client 로 .rpc() 호출)

*/


-- ════════════════════════════════════════════════════════════════════
-- ROLLBACK SQL (필요 시 SQL Editor 에서 수동 실행)
-- ────────────────────────────────────────────────────────────────────
/*

BEGIN;

DROP FUNCTION IF EXISTS public.unlink_campaign_from_application(uuid);
DROP FUNCTION IF EXISTS public.link_campaign_to_application(uuid, uuid);
DROP FUNCTION IF EXISTS public._accumulate_legacy_no(text, text);

COMMIT;

NOTIFY pgrst, 'reload schema';

*/
