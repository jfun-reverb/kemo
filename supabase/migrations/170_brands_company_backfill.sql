-- ════════════════════════════════════════════════════════════════════
-- 170_brands_company_backfill.sql
-- 2026-06-05
--
-- 목적:
--   brands 표의 자유 텍스트 회사 정보(company_name · business_no ·
--   billing_email)를 companies 회사 명부로 옮기고,
--   brands.company_id 외래 키(다른 표를 가리키는 연결)를 채운다.
--
--   사양서: docs/specs/2026-06-04-brand-company-linking.md (PR 1)
--
-- 대상:
--   company_id IS NULL 이고 company_name 이 빈칸이 아닌 brands 행.
--   (이미 연결된 행, company_name 이 NULL/공백뿐인 행은 제외)
--
-- 그룹핑 키:
--   lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))
--   ── companies.name_normalized 트리거(migration 119 교체 버전)와
--      동일한 패턴. INSERT 후 트리거가 재계산하므로 결과가 일치.
--   ⚠️ migration 119 이전 트리거(lower+trim, 공백 압축 없음)와는 다름.
--      현재(119 이후) 트리거 기준으로 맞췄음.
--
-- 멱등성:
--   - ON CONFLICT (name_normalized) DO NOTHING → 재실행 시 중복 회사 안 생김
--   - UPDATE WHERE company_id IS NULL → 이미 연결된 행 재처리 안 함
--
-- total_brands 트리거:
--   trg_brands_company_total_brands (migration 118) 가
--   brands.company_id UPDATE 마다 +1 자동 누적함.
--   백필 끝에 명시적 재계산으로 안전망 추가.
--
-- ROLLBACK (긴급 되돌리기):
--   -- brands 연결 해제 (이 백필로 생긴 회사만 해제)
--   UPDATE public.brands b
--      SET company_id = NULL
--     FROM public.companies c
--    WHERE b.company_id = c.id
--      AND c.memo LIKE '[자동백필]%'
--      AND c.created_at >= '2026-06-05 00:00:00+00';
--
--   -- 이 백필로 생긴 회사 삭제 (brands 연결 해제 후)
--   DELETE FROM public.companies
--    WHERE memo LIKE '[자동백필]%'
--      AND created_at >= '2026-06-05 00:00:00+00';
--
--   -- 위 조건이 부정확하면 id 목록으로 좁혀 실행할 것.
-- ════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_rec             RECORD;
  v_company_id      uuid;
  v_is_new_company  boolean;

  -- 그룹 내 비어있지 않은 값 후보 (첫 값 채택, 2개 이상이면 memo 병기)
  v_first_biz_no    text;
  v_first_billing   text;

  -- 결과 집계
  v_cnt_created     integer := 0;
  v_cnt_reused      integer := 0;
  v_cnt_linked      integer := 0;
  v_cnt_skipped     integer := 0;  -- company_name 빈칸으로 건너뛴 brands 수

  -- 충돌 병기용 메모 조각
  v_memo_parts      text[];
  v_memo_text       text;

  -- 정규화 키 계산을 위한 임시 변수
  v_norm_key        text;

  -- UPDATE 영향 행 수 누적용 임시 변수
  v_tmp_rowcount    integer;
BEGIN

  -- ── 0. 건너뛴 brands 수(company_name 빈칸) 집계 ──
  SELECT COUNT(*) INTO v_cnt_skipped
    FROM public.brands
   WHERE company_id IS NULL
     AND (company_name IS NULL OR btrim(company_name) = '');

  RAISE NOTICE '[170 백필 시작] company_name 빈칸으로 제외될 brands: % 건', v_cnt_skipped;

  -- ── 1. 정규화 키 기준 그룹별 처리 ──
  --
  --   각 그룹 = 같은 lower(trim(regexp_replace(...))) 키를 가진 brands 묶음.
  --   그룹마다:
  --     a) companies 에 같은 name_normalized 가 있으면 재사용
  --     b) 없으면 신규 INSERT
  --     c) 그룹 내 모든 brands.company_id 를 해당 id 로 UPDATE

  FOR v_rec IN
    SELECT
      lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))
                                              AS norm_key,
      -- 대표 원문 (정렬 기준 첫 값 — 결정론적으로 MIN 사용)
      MIN(company_name)                       AS rep_name,
      -- 비어있지 않은 business_no 전체 (중복 제거, 정렬)
      array_agg(DISTINCT btrim(business_no) ORDER BY btrim(business_no))
        FILTER (WHERE btrim(business_no) <> '' AND business_no IS NOT NULL)
                                              AS biz_nos,
      -- 비어있지 않은 billing_email 전체 (중복 제거, 정렬)
      array_agg(DISTINCT lower(btrim(billing_email)) ORDER BY lower(btrim(billing_email)))
        FILTER (WHERE btrim(billing_email) <> '' AND billing_email IS NOT NULL)
                                              AS billing_emails,
      -- 이 그룹에 속한 brand id 목록
      array_agg(id)                           AS brand_ids
    FROM public.brands
   WHERE company_id IS NULL
     AND company_name IS NOT NULL
     AND btrim(company_name) <> ''
   GROUP BY lower(trim(regexp_replace(company_name, '\s+', ' ', 'g')))
   ORDER BY MIN(created_at)  -- 오래된 그룹 먼저 처리 (일관성)
  LOOP

    v_norm_key := v_rec.norm_key;

    -- 1-a. companies 에 같은 name_normalized 가 이미 있는지 확인
    SELECT id INTO v_company_id
      FROM public.companies
     WHERE name_normalized = v_norm_key
     LIMIT 1;

    IF v_company_id IS NOT NULL THEN
      -- 기존 회사 재사용 — INSERT 없이 id 그대로 사용
      v_is_new_company := false;
      v_cnt_reused := v_cnt_reused + 1;

    ELSE
      -- 1-b. 신규 회사 INSERT
      v_is_new_company := true;

      -- business_no / billing_email: 비어있지 않은 첫 값 채택
      v_first_biz_no  := (v_rec.biz_nos)[1];
      v_first_billing := (v_rec.billing_emails)[1];

      -- 충돌 병기 메모 조립
      -- ── 같은 그룹에 서로 다른 값이 2개 이상이면 전체 후보를 memo 에 기록
      --    (첫 값만 채택해서 생기는 정보 손실 방지)
      v_memo_parts := ARRAY['[자동백필] migration 170'];

      IF array_length(v_rec.biz_nos, 1) >= 2 THEN
        v_memo_parts := v_memo_parts ||
          format('사업자번호 후보: %s', array_to_string(v_rec.biz_nos, ', '));
      END IF;

      IF array_length(v_rec.billing_emails, 1) >= 2 THEN
        v_memo_parts := v_memo_parts ||
          format('청구이메일 후보: %s', array_to_string(v_rec.billing_emails, ', '));
      END IF;

      v_memo_text := array_to_string(v_memo_parts, E'\n');

      -- INSERT: name_ko 만 넣으면 트리거가 name_normalized 자동 계산.
      -- ON CONFLICT DO NOTHING — 멱등 안전 (재실행 시 중복 방지).
      -- total_brands 는 DEFAULT 0, brands UPDATE 트리거가 자동 증가시킴.
      INSERT INTO public.companies (
        name_ko,
        business_no,
        billing_email,
        memo,
        status
      )
      VALUES (
        v_rec.rep_name,
        v_first_biz_no,
        v_first_billing,
        v_memo_text,
        'active'
      )
      ON CONFLICT (name_normalized) DO NOTHING
      RETURNING id INTO v_company_id;

      -- INSERT 가 ON CONFLICT 로 건너뛰어진 경우 재조회
      -- (동시 실행 가능성이 거의 없는 마이그레이션이지만 안전하게)
      IF v_company_id IS NULL THEN
        SELECT id INTO v_company_id
          FROM public.companies
         WHERE name_normalized = v_norm_key
         LIMIT 1;

        v_is_new_company := false;
        v_cnt_reused := v_cnt_reused + 1;
      ELSE
        v_cnt_created := v_cnt_created + 1;
      END IF;

    END IF;  -- 신규/재사용 분기 끝

    -- 1-c. 그룹 내 brands.company_id 채우기
    --   trg_brands_company_total_brands 가 각 행 UPDATE 마다 +1 자동 누적.
    --   company_name 은 스냅샷 성격이므로 덮어쓰지 않음.
    UPDATE public.brands
       SET company_id = v_company_id
     WHERE id = ANY(v_rec.brand_ids)
       AND company_id IS NULL;

    GET DIAGNOSTICS v_tmp_rowcount = ROW_COUNT;
    v_cnt_linked := v_cnt_linked + v_tmp_rowcount;

  END LOOP;

  -- ── 2. total_brands 명시적 재계산 (트리거 안전망) ──
  --
  --   트리거가 행 단위로 이미 +1 했지만, 트랜잭션 안에서의 트리거 발화 순서나
  --   이 마이그레이션 이전에 수동 변경이 있었을 경우를 대비해 전체 재계산.
  UPDATE public.companies c
     SET total_brands = sub.cnt
    FROM (
      SELECT company_id, COUNT(*) AS cnt
        FROM public.brands
       WHERE company_id IS NOT NULL
       GROUP BY company_id
    ) sub
   WHERE c.id = sub.company_id;

  -- total_brands = 0 인 회사(brands 연결 없는 경우) 도 0 으로 명시
  UPDATE public.companies
     SET total_brands = 0
   WHERE id NOT IN (
     SELECT DISTINCT company_id FROM public.brands WHERE company_id IS NOT NULL
   );

  -- ── 3. 결과 로그 출력 ──
  RAISE NOTICE '─────────────────────────────────────';
  RAISE NOTICE '[170 백필 완료]';
  RAISE NOTICE '  신규 생성 회사 수  : % 건', v_cnt_created;
  RAISE NOTICE '  기존 재사용 회사 수 : % 건', v_cnt_reused;
  RAISE NOTICE '  연결된 brand 수    : % 건', v_cnt_linked;
  RAISE NOTICE '  미처리(빈칸) brand : % 건', v_cnt_skipped;
  RAISE NOTICE '─────────────────────────────────────';

END;
$$;


-- ── 최종 검산: total_brands 정합성 확인 (트랜잭션 안) ──
--   actual(실제 연결 수) 와 cached(캐시 컬럼) 가 일치하는지 확인.
--   불일치 행이 없으면 백필 정상.
DO $$
DECLARE
  v_mismatch integer;
BEGIN
  SELECT COUNT(*) INTO v_mismatch
    FROM public.companies c
   WHERE c.total_brands <> (
     SELECT COUNT(*) FROM public.brands b WHERE b.company_id = c.id
   );

  IF v_mismatch > 0 THEN
    RAISE WARNING '[170 검산] total_brands 불일치 % 건 — 수동 확인 필요', v_mismatch;
  ELSE
    RAISE NOTICE '[170 검산] total_brands 전체 일치 — 정상';
  END IF;
END;
$$;


COMMIT;


-- ════════════════════════════════════════════════════════════════════
-- 백필 후 검산 SELECT (트랜잭션 밖 — SQL Editor 에서 수동 실행)
-- ════════════════════════════════════════════════════════════════════
/*

-- [검산 1] 생성된 회사 목록 + total_brands 캐시 vs 실제 연결 수 비교
SELECT
  c.name_ko,
  c.business_no,
  c.billing_email,
  c.total_brands                AS cached_brands,
  (SELECT COUNT(*) FROM public.brands b WHERE b.company_id = c.id) AS actual_brands,
  c.memo,
  c.created_at
FROM public.companies c
ORDER BY c.created_at DESC;

-- [검산 2] brands 연결 현황 (연결됨 / 미연결 / 전체)
SELECT
  COUNT(*)                                              AS total_brands,
  COUNT(*) FILTER (WHERE company_id IS NOT NULL)        AS linked,
  COUNT(*) FILTER (WHERE company_id IS NULL)            AS unlinked,
  COUNT(*) FILTER (WHERE company_id IS NULL
                     AND company_name IS NOT NULL
                     AND btrim(company_name) <> '')     AS unlinked_with_name
FROM public.brands;

-- [검산 3] 아직 미연결인 brands (company_name 있음 → 수동 정리 대상)
SELECT id, name, company_name, business_no, billing_email, created_at
  FROM public.brands
 WHERE company_id IS NULL
   AND company_name IS NOT NULL
   AND btrim(company_name) <> ''
 ORDER BY created_at;

*/
