-- ============================================================
-- 089_hierarchical_numbering_backfill.sql
-- 계층 채번 시스템 — 기존 데이터 재채번 + 카운터 동기화
--
-- 목적:
--   088에서 만든 스키마를 기존 데이터로 채운다.
--
--   실행 순서:
--     STEP 1.  테스트/이상 brands 식별 뷰 (EXECUTE 전 관리자 확인용)
--     STEP 2.  brands.brand_seq 채번 (created_at ASC 순)
--     STEP 3.  brand_seq_counter.seq 동기화
--     STEP 4.  campaigns.brand_id 백필 (free-text brand → brands 매핑)
--     STEP 5.  매칭 안 된 free-text brand → brands 신규 INSERT
--     STEP 6.  legacy_no 복사 (기존 번호 보존)
--     STEP 7.  brand_applications 신규 번호 부여
--     STEP 8.  campaigns 신규 번호 부여
--     STEP 9.  카운터 테이블 last_seq 동기화
--     STEP 10. numbering_legacy_map 채우기
--     STEP 11. 인라인 검증 (실패 시 ROLLBACK)
--     STEP 12. campaigns.brand_id NOT NULL 전환
--
-- 동시성 주의:
--   이 마이그레이션은 단일 트랜잭션(BEGIN..COMMIT)으로 실행한다.
--   실행 중 신규 INSERT(신청/캠페인)가 들어오면 이 트랜잭션이 해당 행을
--   잠그므로 신규 INSERT가 대기한다. 재채번은 새벽 저트래픽 시간에 적용.
--
-- 전제:
--   - 088 적용 완료 (카운터/컬럼/FK 존재)
--   - 083 적용 완료 (brand_applications.brand_id 이미 채워짐)
--   - 운영 brands 테스트 데이터 사전 정리 완료 (아래 STEP 0 식별 쿼리 먼저 실행)
--
-- 작성일: 2026-05-04
-- ============================================================


-- ============================================================
-- STEP 0 (사전 실행 — 트랜잭션 밖):
-- 테스트/이상 brands 식별. 삭제 전 관리자가 확인·승인 필요.
-- brand_applications 연결 건이 있으면 ON DELETE RESTRICT로 차단되므로
-- 반드시 연결 건 먼저 확인할 것.
-- ============================================================
/*
SELECT
  b.id,
  b.brand_no,
  b.name,
  b.status,
  b.total_applications,
  b.created_at,
  -- 의심 패턴
  (b.name ~ '^\[QA' OR b.name ~ '^\[TEST' OR b.name ~ '<script'
   OR b.name ~ '^[0-9]+$' OR length(b.name) < 3) AS is_suspicious
FROM public.brands b
WHERE
  b.name ~ '^\[QA'      -- [QA-TEST-...] 패턴
  OR b.name ~ '^\[TEST' -- [TEST-...] 패턴
  OR b.name ~ '<script' -- XSS 패턴
  OR b.name ~ '^[0-9]+$' -- 숫자만
  OR length(b.name) < 3  -- 너무 짧은 이름
ORDER BY b.created_at;

-- 연결된 brand_applications 확인
SELECT
  b.name AS brand_name,
  ba.application_no,
  ba.status,
  ba.created_at
FROM public.brand_applications ba
JOIN public.brands b ON b.id = ba.brand_id
WHERE
  b.name ~ '^\[QA'
  OR b.name ~ '^\[TEST'
  OR b.name ~ '<script'
  OR b.name ~ '^[0-9]+$'
  OR length(b.name) < 3
ORDER BY b.name, ba.created_at;
*/


BEGIN;

-- 실행 중 외부 동시 INSERT 차단 (재채번 안전성 보장)
-- brand_applications와 campaigns를 EXCLUSIVE로 잠근다
LOCK TABLE public.brand_applications IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.campaigns          IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.brands             IN SHARE ROW EXCLUSIVE MODE;


-- ============================================================
-- STEP 2: brands.brand_seq 채번
--   created_at ASC 순으로 1부터 순차 부여.
--   이미 brand_seq가 있는 행은 건너뜀 (멱등성).
-- ============================================================

WITH ranked AS (
  SELECT
    id,
    ROW_NUMBER() OVER (ORDER BY created_at, id) AS new_seq
  FROM public.brands
  WHERE brand_seq IS NULL
)
UPDATE public.brands b
SET brand_seq = r.new_seq
FROM ranked r
WHERE b.id = r.id;


-- ============================================================
-- STEP 3: brand_seq_counter.seq 동기화
--   STEP 2 채번 후 최대값으로 설정. 이후 brands INSERT가 이어받음.
-- ============================================================

UPDATE public.brand_seq_counter
SET seq = (SELECT COALESCE(MAX(brand_seq), 0) FROM public.brands)
WHERE id = 1;


-- ============================================================
-- STEP 4: campaigns.brand_id 백필
--   campaigns.brand (free-text) → brands.name_normalized 매칭
--   이미 brand_id가 채워진 행은 건너뜀.
-- ============================================================

UPDATE public.campaigns c
SET brand_id = b.id
FROM public.brands b
WHERE c.brand_id IS NULL
  AND b.name_normalized = lower(trim(regexp_replace(c.brand, '\s+', ' ', 'g')));


-- ============================================================
-- STEP 5: 매칭 안 된 free-text brand → brands 신규 INSERT
--   매칭 실패 = free-text brand 이름으로 brands에 존재하지 않는 경우
--   신규 brands 행 INSERT 후 campaigns.brand_id 연결
-- ============================================================

-- 5-1. 매칭 안 된 distinct brand 이름으로 brands 신규 INSERT
WITH unmatched AS (
  SELECT DISTINCT
    lower(trim(regexp_replace(c.brand, '\s+', ' ', 'g'))) AS name_normalized,
    c.brand AS name_original
  FROM public.campaigns c
  WHERE c.brand_id IS NULL
    AND COALESCE(trim(c.brand), '') <> ''
)
INSERT INTO public.brands (name, status)
SELECT
  u.name_original,
  'active'
FROM unmatched u
WHERE NOT EXISTS (
  SELECT 1 FROM public.brands b2
  WHERE b2.name_normalized = u.name_normalized
)
-- trg_brand_name_normalized: name_normalized 자동 계산
-- trg_brand_no:              brand_no 자동 채번
;

-- 5-2. 신규 INSERT된 brands에도 brand_seq 채번 (brand_seq IS NULL 조건)
WITH ranked AS (
  SELECT
    id,
    (SELECT COALESCE(MAX(brand_seq), 0) FROM public.brands)
      + ROW_NUMBER() OVER (ORDER BY created_at, id) AS new_seq
  FROM public.brands
  WHERE brand_seq IS NULL
)
UPDATE public.brands b
SET brand_seq = r.new_seq
FROM ranked r
WHERE b.id = r.id;

-- 5-3. brand_seq_counter 재동기화
UPDATE public.brand_seq_counter
SET seq = (SELECT COALESCE(MAX(brand_seq), 0) FROM public.brands)
WHERE id = 1;

-- 5-4. campaigns.brand_id 2차 연결 (STEP 5-1에서 새로 생긴 brands 포함)
UPDATE public.campaigns c
SET brand_id = b.id
FROM public.brands b
WHERE c.brand_id IS NULL
  AND b.name_normalized = lower(trim(regexp_replace(c.brand, '\s+', ' ', 'g')));

-- 5-5. brand 컬럼이 NULL/빈 문자열인 캠페인은 브랜드 미상으로 기록
--   → 전용 "브랜드 미상" brands 행을 만들지 않는다.
--   → 운영자가 수동 연결해야 하며, brand_id=NULL로 남겨둔다.
--   → STEP 11 검증에서 이 수를 허용(경고만)


-- ============================================================
-- STEP 6: legacy_no 복사 (기존 번호 보존)
--   아직 legacy_no가 비어있는 행만 채움 (멱등성).
-- ============================================================

UPDATE public.brand_applications
SET legacy_no = application_no
WHERE legacy_no IS NULL;

UPDATE public.campaigns
SET legacy_no = campaign_no
WHERE legacy_no IS NULL;


-- ============================================================
-- STEP 7: brand_applications 신규 번호 부여
--   각 brand 내에서 created_at ASC 순으로 A001부터 시퀀셜 부여.
--
--   포맷: B{lpad(brand_seq,4,'0')}-A{lpad(app_seq,3,'0')}
--   예:   B0001-A001
--
--   트리거 재발동 방지: generate_brand_application_no는 application_no ≠ ''
--   이면 건너뛰도록 설계되어 있으므로 직접 UPDATE 시 트리거 재발동 없음.
--   (BEFORE INSERT 트리거이므로 UPDATE에는 영향 없음)
-- ============================================================

WITH ranked_apps AS (
  SELECT
    ba.id,
    b.brand_seq,
    ROW_NUMBER() OVER (
      PARTITION BY ba.brand_id
      ORDER BY ba.created_at, ba.id
    ) AS app_seq
  FROM public.brand_applications ba
  JOIN public.brands b ON b.id = ba.brand_id
  WHERE ba.brand_id IS NOT NULL
)
UPDATE public.brand_applications ba
SET application_no =
      'B' || lpad(r.brand_seq::text, 4, '0')
      || '-A' || lpad(r.app_seq::text, 3, '0')
FROM ranked_apps r
WHERE ba.id = r.id;


-- ============================================================
-- STEP 8: campaigns 신규 번호 부여
--
--   [A] source_application_id NOT NULL (신청 파생 캠페인)
--       포맷: B{brand_seq}-A{app_seq}-C{camp_seq}
--       camp_seq: 신청별 created_at ASC 순
--
--   [B] source_application_id NULL + brand_id NOT NULL (외부 캠페인)
--       포맷: B{brand_seq}-C{ext_seq}
--       ext_seq: 브랜드별 created_at ASC 순
--
--   [C] brand_id IS NULL (브랜드 미상) — campaign_no 변경 없음 (CAMP-YYYY-NNNN 유지)
--       운영자가 수동으로 brand_id 연결 후 번호 수동 갱신 필요
-- ============================================================

-- [A] 신청 파생 캠페인
WITH ranked_camp_a AS (
  SELECT
    c.id,
    b.brand_seq,
    -- 신청의 A seq 추출: application_no에서 'A' 뒤 숫자
    CASE
      WHEN ba.application_no ~ '^B\d{4}-A\d{3}$'
      THEN split_part(split_part(ba.application_no, '-A', 2), '-', 1)::integer
      ELSE NULL
    END AS app_seq,
    ROW_NUMBER() OVER (
      PARTITION BY c.source_application_id
      ORDER BY c.created_at, c.id
    ) AS camp_seq
  FROM public.campaigns c
  JOIN public.brands              b  ON b.id  = c.brand_id
  JOIN public.brand_applications  ba ON ba.id = c.source_application_id
  WHERE c.source_application_id IS NOT NULL
    AND c.brand_id               IS NOT NULL
)
UPDATE public.campaigns c
SET campaign_no =
      'B' || lpad(r.brand_seq::text, 4, '0')
      || '-A' || lpad(r.app_seq::text,   3, '0')
      || '-C' || lpad(r.camp_seq::text,  3, '0')
FROM ranked_camp_a r
WHERE c.id = r.id
  AND r.app_seq IS NOT NULL;  -- app_seq 파싱 실패 시 업데이트 스킵

-- [B] 외부 캠페인 (source_application_id IS NULL, brand_id NOT NULL)
WITH ranked_camp_b AS (
  SELECT
    c.id,
    b.brand_seq,
    ROW_NUMBER() OVER (
      PARTITION BY c.brand_id
      ORDER BY c.created_at, c.id
    ) AS ext_seq
  FROM public.campaigns c
  JOIN public.brands b ON b.id = c.brand_id
  WHERE c.source_application_id IS NULL
    AND c.brand_id               IS NOT NULL
)
UPDATE public.campaigns c
SET campaign_no =
      'B' || lpad(r.brand_seq::text, 4, '0')
      || '-C' || lpad(r.ext_seq::text, 3, '0')
FROM ranked_camp_b r
WHERE c.id = r.id;


-- ============================================================
-- STEP 9: 카운터 테이블 last_seq 동기화
--   재채번 완료 후 다음 INSERT가 올바른 값을 이어받도록 설정.
-- ============================================================

-- [A] brand_application_counter
INSERT INTO public.brand_application_counter (brand_id, last_seq)
SELECT
  ba.brand_id,
  COUNT(*)::integer AS last_seq
FROM public.brand_applications ba
WHERE ba.brand_id IS NOT NULL
GROUP BY ba.brand_id
ON CONFLICT (brand_id) DO UPDATE
  SET last_seq = GREATEST(
    public.brand_application_counter.last_seq,
    EXCLUDED.last_seq
  );

-- [B] application_campaign_counter
INSERT INTO public.application_campaign_counter (application_id, last_seq)
SELECT
  c.source_application_id,
  COUNT(*)::integer AS last_seq
FROM public.campaigns c
WHERE c.source_application_id IS NOT NULL
  AND c.brand_id               IS NOT NULL
GROUP BY c.source_application_id
ON CONFLICT (application_id) DO UPDATE
  SET last_seq = GREATEST(
    public.application_campaign_counter.last_seq,
    EXCLUDED.last_seq
  );

-- [C] brand_external_campaign_counter
INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
SELECT
  c.brand_id,
  COUNT(*)::integer AS last_seq
FROM public.campaigns c
WHERE c.source_application_id IS NULL
  AND c.brand_id               IS NOT NULL
GROUP BY c.brand_id
ON CONFLICT (brand_id) DO UPDATE
  SET last_seq = GREATEST(
    public.brand_external_campaign_counter.last_seq,
    EXCLUDED.last_seq
  );


-- ============================================================
-- STEP 10: numbering_legacy_map 채우기
-- ============================================================

INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
SELECT
  'brand_application',
  ba.id,
  ba.legacy_no,
  ba.application_no,
  now()
FROM public.brand_applications ba
WHERE ba.legacy_no IS NOT NULL
  AND ba.legacy_no <> ba.application_no  -- 번호가 바뀐 행만
ON CONFLICT (entity_type, entity_id) DO UPDATE
  SET
    new_no       = EXCLUDED.new_no,
    migrated_at  = EXCLUDED.migrated_at;

INSERT INTO public.numbering_legacy_map (entity_type, entity_id, legacy_no, new_no, migrated_at)
SELECT
  'campaign',
  c.id,
  c.legacy_no,
  c.campaign_no,
  now()
FROM public.campaigns c
WHERE c.legacy_no IS NOT NULL
  AND c.legacy_no <> c.campaign_no  -- 번호가 바뀐 행만
ON CONFLICT (entity_type, entity_id) DO UPDATE
  SET
    new_no       = EXCLUDED.new_no,
    migrated_at  = EXCLUDED.migrated_at;


-- ============================================================
-- STEP 11: 인라인 검증 (실패 시 ROLLBACK)
-- ============================================================

-- [V1] brands.brand_seq 모두 채워짐
DO $$
DECLARE v_null integer;
BEGIN
  SELECT count(*) INTO v_null FROM public.brands WHERE brand_seq IS NULL;
  IF v_null > 0 THEN
    RAISE EXCEPTION '[089-V1] brands.brand_seq NULL % 건. 재채번 실패.', v_null;
  END IF;
END; $$;

-- [V2] brands.brand_seq UNIQUE (중복 없음)
DO $$
DECLARE v_dup integer;
BEGIN
  SELECT count(*) INTO v_dup
  FROM (
    SELECT brand_seq FROM public.brands GROUP BY brand_seq HAVING count(*) > 1
  ) t;
  IF v_dup > 0 THEN
    RAISE EXCEPTION '[089-V2] brands.brand_seq 중복 % 건.', v_dup;
  END IF;
END; $$;

-- [V3] brand_applications.application_no 모두 새 포맷
DO $$
DECLARE v_old integer;
BEGIN
  SELECT count(*) INTO v_old
  FROM public.brand_applications
  WHERE application_no NOT SIMILAR TO 'B[0-9]{4}-A[0-9]{3}'
    AND brand_id IS NOT NULL;
  IF v_old > 0 THEN
    RAISE EXCEPTION '[089-V3] brand_applications 새 포맷 미전환 % 건.', v_old;
  END IF;
END; $$;

-- [V4] brand_applications.application_no UNIQUE (중복 없음)
DO $$
DECLARE v_dup integer;
BEGIN
  SELECT count(*) INTO v_dup
  FROM (
    SELECT application_no
    FROM public.brand_applications
    GROUP BY application_no
    HAVING count(*) > 1
  ) t;
  IF v_dup > 0 THEN
    RAISE EXCEPTION '[089-V4] brand_applications.application_no 중복 % 건.', v_dup;
  END IF;
END; $$;

-- [V5] campaigns 브랜드 연결 건은 새 포맷
DO $$
DECLARE v_old integer;
BEGIN
  SELECT count(*) INTO v_old
  FROM public.campaigns
  WHERE brand_id IS NOT NULL
    AND campaign_no NOT SIMILAR TO 'B[0-9]{4}-(A[0-9]{3}-)?C[0-9]{3}';
  IF v_old > 0 THEN
    RAISE EXCEPTION '[089-V5] campaigns 새 포맷 미전환 % 건 (brand_id IS NOT NULL).', v_old;
  END IF;
END; $$;

-- [V6] campaign_no UNIQUE (중복 없음)
DO $$
DECLARE v_dup integer;
BEGIN
  SELECT count(*) INTO v_dup
  FROM (
    SELECT campaign_no
    FROM public.campaigns
    GROUP BY campaign_no
    HAVING count(*) > 1
  ) t;
  IF v_dup > 0 THEN
    RAISE EXCEPTION '[089-V6] campaigns.campaign_no 중복 % 건.', v_dup;
  END IF;
END; $$;

-- [V7] legacy_no 모두 채워짐 (brand_applications)
DO $$
DECLARE v_null integer;
BEGIN
  SELECT count(*) INTO v_null
  FROM public.brand_applications
  WHERE legacy_no IS NULL;
  IF v_null > 0 THEN
    RAISE EXCEPTION '[089-V7] brand_applications.legacy_no NULL % 건.', v_null;
  END IF;
END; $$;

-- [V8] 카운터 일치 (brand_application_counter)
DO $$
DECLARE v_mismatch integer;
BEGIN
  SELECT count(*) INTO v_mismatch
  FROM public.brand_application_counter bac
  WHERE bac.last_seq <> (
    SELECT count(*)::integer
    FROM public.brand_applications ba
    WHERE ba.brand_id = bac.brand_id
  );
  IF v_mismatch > 0 THEN
    RAISE EXCEPTION '[089-V8] brand_application_counter 불일치 % 브랜드.', v_mismatch;
  END IF;
END; $$;

-- [V9] brand_id NULL 캠페인 수 경고 (차단하지 않음 — 운영자 수동 처리 필요)
DO $$
DECLARE v_null integer;
BEGIN
  SELECT count(*) INTO v_null
  FROM public.campaigns
  WHERE brand_id IS NULL;
  IF v_null > 0 THEN
    RAISE WARNING '[089-V9] campaigns.brand_id NULL % 건. 운영자가 수동으로 브랜드 연결 필요.', v_null;
  END IF;
END; $$;


-- ============================================================
-- STEP 12: campaigns.brand_id NOT NULL 전환
--   V9에서 brand_id NULL 건이 0이면 아래를 활성화한다.
--   NULL 건이 남아 있으면 주석 유지하고 수동 연결 후 별도 실행.
-- ============================================================
/*
-- brand_id NULL 캠페인이 없음을 확인 후 활성화
DO $$
DECLARE v_null integer;
BEGIN
  SELECT count(*) INTO v_null FROM public.campaigns WHERE brand_id IS NULL;
  IF v_null > 0 THEN
    RAISE EXCEPTION '캠페인 brand_id NULL % 건. NOT NULL 전환 불가.', v_null;
  END IF;
END; $$;

ALTER TABLE public.campaigns
  ALTER COLUMN brand_id SET NOT NULL;
*/


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ============================================================
-- COMMIT 후 사후 검증 SQL (SQL Editor에서 별도 실행)
-- ============================================================
/*

-- [1] 재채번 요약
SELECT
  count(*)                                            AS total_apps,
  count(*) FILTER (WHERE application_no SIMILAR TO 'B[0-9]{4}-A[0-9]{3}')
                                                      AS new_format,
  count(*) FILTER (WHERE legacy_no <> application_no) AS renumbered
FROM public.brand_applications;

-- [2] 캠페인 재채번 요약
SELECT
  count(*)                                            AS total_camps,
  count(*) FILTER (WHERE campaign_no SIMILAR TO 'B[0-9]{4}-A[0-9]{3}-C[0-9]{3}')
                                                      AS derived_from_app,
  count(*) FILTER (WHERE campaign_no SIMILAR TO 'B[0-9]{4}-C[0-9]{3}')
                                                      AS external,
  count(*) FILTER (WHERE brand_id IS NULL)            AS no_brand,
  count(*) FILTER (WHERE legacy_no <> campaign_no)    AS renumbered
FROM public.campaigns;

-- [3] 매핑 테이블 확인 (샘플 10건)
SELECT entity_type, legacy_no, new_no, migrated_at
FROM public.numbering_legacy_map
ORDER BY migrated_at DESC
LIMIT 10;

-- [4] 카운터 일치 확인
SELECT
  b.brand_no,
  b.name,
  bac.last_seq AS counter_seq,
  count(ba.id) AS actual_apps
FROM public.brand_application_counter bac
JOIN public.brands b ON b.id = bac.brand_id
LEFT JOIN public.brand_applications ba ON ba.brand_id = b.id
GROUP BY b.brand_no, b.name, bac.last_seq
HAVING bac.last_seq <> count(ba.id)::integer;
-- 0건이어야 함

-- [5] legacy → new 번호 조회 예시
SELECT legacy_no, new_no
FROM public.numbering_legacy_map
WHERE legacy_no LIKE 'JFUN-%'
ORDER BY migrated_at;

-- [6] campaigns.brand_id NULL 잔존 (0이어야 이상적)
SELECT c.id, c.campaign_no, c.brand, c.created_at
FROM public.campaigns c
WHERE c.brand_id IS NULL
ORDER BY c.created_at;

*/


-- ============================================================
-- 롤백 SQL (COMMIT 후 문제 발생 시 역순 실행)
-- ============================================================
/*

BEGIN;

-- 1. brand_applications 번호 원복
UPDATE public.brand_applications
SET application_no = legacy_no
WHERE legacy_no IS NOT NULL
  AND application_no <> legacy_no;

-- 2. campaigns 번호 원복
UPDATE public.campaigns
SET campaign_no = legacy_no
WHERE legacy_no IS NOT NULL
  AND campaign_no <> legacy_no;

-- 3. campaigns.brand_id 초기화 (088에서 추가된 컬럼만 초기화, campaigns.brand free-text는 유지)
UPDATE public.campaigns SET brand_id = NULL, source_application_id = NULL;

-- 4. 카운터 테이블 초기화
DELETE FROM public.brand_external_campaign_counter;
DELETE FROM public.application_campaign_counter;
DELETE FROM public.brand_application_counter;

-- 5. brands.brand_seq 초기화
UPDATE public.brands SET brand_seq = NULL;
UPDATE public.brand_seq_counter SET seq = 0 WHERE id = 1;

-- 6. legacy_no 초기화 (마이그레이션 전 상태 복원)
UPDATE public.brand_applications SET legacy_no = NULL;
UPDATE public.campaigns SET legacy_no = NULL;

-- 7. 매핑 테이블 비우기 (테이블 자체는 088 롤백에서 DROP)
DELETE FROM public.numbering_legacy_map;

COMMIT;

NOTIFY pgrst, 'reload schema';

*/
