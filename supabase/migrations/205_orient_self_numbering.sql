-- ============================================================
-- 205_orient_self_numbering.sql
-- 2026-06-30
--
-- 목적:
--   오리엔시트에 자체 식별번호 orient_no = B{brand_seq 4자리}-O{orient_seq 3자리}
--   (예: B0001-O001)를 부여한다.
--   신청 번호(application_no) 의존에서 분리, 비-서베이 직접 발급 케이스도 식별 가능.
--
-- 사양서:
--   docs/specs/2026-06-30-orient-self-numbering.md §3·§4·§7(PR 1)
--
-- 채번 설계:
--   형식 : B{lpad(brand_seq,4,'0')}-O{lpad(orient_seq,3,'0')}
--   범위 : 브랜드별 독립 순번(O001~O999). 브랜드 간 번호 중복은 prefix(B 세그먼트)로 구분.
--   카운터: brand_orient_counter 테이블(brand_application_counter 패턴 미러).
--   동시성: pg_advisory_xact_lock(hashtext(brand_id::text)::bigint) + ON CONFLICT DO UPDATE
--          → 090 계층 채번 패턴(generate_brand_application_no)과 동일.
--
-- 변경 내용:
--   [A] brand_orient_counter 신규 테이블
--       - brand_id PRIMARY KEY + last_seq. ON DELETE CASCADE.
--       - 직접 UPDATE 금지 — create_orient_sheet 함수 전용.
--   [B] orient_sheets.orient_no text 컬럼 추가
--       - NULL 허용으로 추가 → [C] 백필 → NOT NULL + UNIQUE 제약
--   [C] 기존 행 백필
--       - orient_no IS NULL 행만 처리(멱등성 보장).
--       - 브랜드별 created_at ASC 정렬 → O001부터 부여.
--       - 백필 완료 후 brand_orient_counter 동기화(신규 발급 정합).
--   [D] create_orient_sheet(uuid, uuid DEFAULT NULL) 함수 수정
--       - 195 대비 변경: brand_seq + 카운터 채번 + orient_no INSERT.
--       - 반환값에 orient_no 키 추가 (기존 키 유지 — 하위호환).
--
-- 이전 마이그레이션 의존:
--   088_hierarchical_numbering_schema.sql — brand_seq_counter, brand_seq 컬럼
--   090_hierarchical_numbering_triggers.sql — generate_brand_seq 트리거
--   186_orient_sheets_table.sql — orient_sheets 테이블 존재
--   191_delete_brand_orient_count.sql — delete_brand에 orient_sheets 카운트 체크 추가됨
--   195_create_orient_sheet_cards_redesign.sql — 교체 대상 함수(CREATE OR REPLACE 덮어씀)
--
-- merge_brands(175) 영향:
--   merge_brands는 orient_sheets 행을 이동하지 않는다.
--   병합 후 source 오리엔(B{source}-O...)은 source 브랜드에 남고,
--   target 신규 오리엔(B{target}-O...)은 target 카운터에서 계속 발급된다.
--   번호 prefix가 달라 충돌 없음. 단 archived source에 orient_sheets 잔류 가능.
--   → 별도 개선 과제(PR 1 범위 밖). 관리자 주의 사항으로 운영 가이드에 추가 예정.
--
-- 운영 데이터 영향:
--   - brand_orient_counter: 신규 테이블 (기존 데이터 없음)
--   - orient_sheets.orient_no: NULL 허용 컬럼 추가 → 백필 → NOT NULL. 기존 행 일괄 갱신.
--   - create_orient_sheet: 반환값에 orient_no 추가. 기존 키 유지로 클라이언트 하위호환.
--
-- 적용 순서:
--   개발서버 먼저 → 검증 → 운영서버 적용 (git.md 배포 워크플로)
--
-- 롤백:
--   1. DROP FUNCTION IF EXISTS public.create_orient_sheet(uuid, uuid);
--   2. 195_create_orient_sheet_cards_redesign.sql의 CREATE OR REPLACE 재실행 (195 함수 복원)
--   3. ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS orient_no;
--   4. DROP TABLE IF EXISTS public.brand_orient_counter;
-- ============================================================

BEGIN;


-- ============================================================
-- A. brand_orient_counter 신규 테이블
--    brand_application_counter(088) 패턴 미러링.
--    직접 UPDATE 금지 — create_orient_sheet 함수만 INCREMENT 권한 보유.
-- ============================================================
CREATE TABLE IF NOT EXISTS public.brand_orient_counter (
  brand_id uuid    PRIMARY KEY REFERENCES public.brands(id) ON DELETE CASCADE,
  last_seq integer NOT NULL DEFAULT 0
);

COMMENT ON TABLE public.brand_orient_counter IS
  '[205] 브랜드별 오리엔시트 순번 카운터. '
  'O{lpad(last_seq,3,''0'')} 세그먼트 생성용. 직접 UPDATE 금지 — SECURITY DEFINER 함수 전용. '
  '088 brand_application_counter 패턴 미러.';

COMMENT ON COLUMN public.brand_orient_counter.brand_id IS
  '[205] 브랜드(brands.id) 참조. PRIMARY KEY. ON DELETE CASCADE.';

COMMENT ON COLUMN public.brand_orient_counter.last_seq IS
  '[205] 마지막 발급 순번. 신규 발급마다 +1. 0 = 아직 발급 없음.';

ALTER TABLE public.brand_orient_counter ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자 전체 조회 (088 카운터 테이블 정책 패턴 동일)
CREATE POLICY "brand_orient_counter_select_admin"
  ON public.brand_orient_counter FOR SELECT
  USING (public.is_admin());


-- ============================================================
-- B. orient_sheets.orient_no 컬럼 추가
--    NULL 허용으로 추가 → [C] 백필 → [C-2] NOT NULL + UNIQUE.
-- ============================================================
ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS orient_no text;

COMMENT ON COLUMN public.orient_sheets.orient_no IS
  '[205] 자체 식별번호. B{brand_seq 4자리}-O{orient_seq 3자리} (예: B0001-O001). '
  '브랜드별 발급순 순번. create_orient_sheet 함수가 발급 시 채번. '
  'NOT NULL + UNIQUE (백필 완료 후 제약 추가). '
  '신청 번호(application_no) 의존 분리 목적 — 비-서베이 직접 발급에도 식별 가능.';


-- ============================================================
-- C. 기존 행 백필
--    orient_no IS NULL 행만 처리 (멱등성 — 이미 번호 있는 행 스킵).
--    브랜드별 created_at ASC 정렬 → O001부터 부여.
--    백필 완료 후 brand_orient_counter 동기화.
-- ============================================================
DO $$
DECLARE
  v_brand_id   uuid;
  v_brand_seq  integer;
  v_sheet_id   uuid;
  v_seq        integer;
BEGIN
  -- 오리엔 번호 미부여 행이 있는 브랜드를 순회
  FOR v_brand_id, v_brand_seq IN
    SELECT DISTINCT os.brand_id, b.brand_seq
      FROM public.orient_sheets os
      JOIN public.brands         b ON b.id = os.brand_id
     WHERE os.orient_no IS NULL
     ORDER BY os.brand_id
  LOOP
    v_seq := 0;

    -- 브랜드 내 created_at 오름차순으로 orient_no 부여
    FOR v_sheet_id IN
      SELECT os.id
        FROM public.orient_sheets os
       WHERE os.brand_id  = v_brand_id
         AND os.orient_no IS NULL
       ORDER BY os.created_at ASC, os.id ASC  -- created_at 동일 시 id(UUID v4) 보조 정렬
    LOOP
      v_seq := v_seq + 1;

      UPDATE public.orient_sheets
         SET orient_no = 'B' || lpad(v_brand_seq::text, 4, '0')
                      || '-O' || lpad(v_seq::text, 3, '0')
       WHERE id = v_sheet_id;
    END LOOP;

    -- 카운터 동기화 (신규 발급 시 다음 순번 정합 보장)
    --   백필된 브랜드 행이 1개 이상인 경우에만 INSERT/UPDATE.
    --   GREATEST: 이미 카운터 행이 있을 경우(재실행 등) 더 큰 값 유지.
    IF v_seq > 0 THEN
      INSERT INTO public.brand_orient_counter (brand_id, last_seq)
      VALUES (v_brand_id, v_seq)
      ON CONFLICT (brand_id)
      DO UPDATE SET last_seq = GREATEST(
        public.brand_orient_counter.last_seq,
        EXCLUDED.last_seq
      );
    END IF;
  END LOOP;
END;
$$;


-- ============================================================
-- C-2. NOT NULL + UNIQUE 제약 추가 (백필 완료 후)
--   백필 후 orient_no IS NULL 행이 있으면 NOT NULL 추가 시 오류 발생.
--   → 의도된 동작: 백필 누락을 트랜잭션 실패로 즉시 감지.
-- ============================================================
ALTER TABLE public.orient_sheets
  ALTER COLUMN orient_no SET NOT NULL;

ALTER TABLE public.orient_sheets
  ADD CONSTRAINT orient_sheets_orient_no_key UNIQUE (orient_no);


-- ============================================================
-- D. create_orient_sheet(uuid, uuid DEFAULT NULL) 함수 수정
--    195 대비 변경점:
--      · 브랜드 검증 시 brand_seq + brands.name 동시 취득 (195: EXISTS만)
--      · advisory lock + brand_orient_counter atomic 증가 추가
--      · orient_no 생성 및 INSERT
--      · 반환 jsonb에 orient_no 키 추가 (기존 키 유지 — 하위호환)
--    불변 유지:
--      · 함수 시그니처 (uuid, uuid DEFAULT NULL)
--      · is_admin() 가드 (campaign_manager 포함 전체 관리자)
--      · brand_id 정합·application 존재 검증 로직
--      · data 초기값 구조 {brand:{name,intro,official_accounts}, cards:[]}
--      · token_expires_at = now()+30일, status='draft'
--      · SECURITY DEFINER + SET search_path = ''
-- ============================================================
CREATE OR REPLACE FUNCTION public.create_orient_sheet(
  p_brand_id        uuid,
  p_application_id  uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- [205] 채번용 변수
  v_brand_seq     integer;   -- brands.brand_seq (orient_no 앞자리)
  v_brands_name   text;      -- brands.name (백업 — ba.brand_name 폴백용)
  -- 기존 195 변수
  v_app_brand_id  uuid;
  v_brand_name    text;      -- 최종 prefill 브랜드명 (ba.brand_name > brands.name)
  -- [205] 채번 결과
  v_orient_seq    integer;   -- 브랜드 내 오리엔 순번
  v_orient_no     text;      -- 최종 채번값 (B{B}-O{O})
  -- INSERT용
  v_new_id        uuid;
  v_new_token     uuid;
  v_expires_at    timestamptz;
  v_init_data     jsonb;
BEGIN
  -- ── 권한 가드: campaign_manager 포함 전체 관리자 ──────────────────────
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자 로그인 필요)' USING ERRCODE = '42501';
  END IF;

  -- ── [205 변경] 브랜드 존재 검증 + brand_seq + brands.name 취득 ─────────
  --   195는 EXISTS(SELECT 1)만 사용. 205는 brand_seq·name을 함께 취득해 재쿼리 최소화.
  SELECT b.brand_seq, b.name
    INTO v_brand_seq, v_brands_name
    FROM public.brands b
   WHERE b.id = p_brand_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_not_found');
  END IF;

  -- brand_seq 미부여 브랜드 (088 마이그레이션 이전 생성된 극히 드문 레거시 행)
  IF v_brand_seq IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'brand_seq_missing');
  END IF;

  -- ── brand.name prefill 결정 ──────────────────────────────────────────
  --   우선순위: brand_applications.brand_name(연결 신청 스냅샷) > brands.name
  IF p_application_id IS NOT NULL THEN
    SELECT ba.brand_id, ba.brand_name
      INTO v_app_brand_id, v_brand_name
      FROM public.brand_applications ba
     WHERE ba.id = p_application_id;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'reason', 'application_not_found');
    END IF;

    -- brand_id 정합 검증
    IF v_app_brand_id IS DISTINCT FROM p_brand_id THEN
      RETURN jsonb_build_object('success', false, 'reason', 'brand_mismatch');
    END IF;

    -- [205 변경] ba.brand_name 없으면 이미 취득한 v_brands_name으로 폴백
    --   195는 이 경우 2차 SELECT brands.name 수행. 205는 재쿼리 없이 변수 활용.
    IF v_brand_name IS NULL OR v_brand_name = '' THEN
      v_brand_name := v_brands_name;
    END IF;

  ELSE
    -- 신청 미연결: [205 변경] 이미 취득한 v_brands_name 직접 사용 (195: SELECT brands.name)
    v_brand_name := v_brands_name;
  END IF;

  -- ── [205 추가] 동시성: 동일 브랜드 내 동시 발급 직렬화 ─────────────────
  --   동일 brand_id에 대한 동시 INSERT가 카운터 순번을 중복 취득하는 것을 방지.
  --   090 generate_brand_application_no() 패턴 동일.
  PERFORM pg_advisory_xact_lock(hashtext(p_brand_id::text)::bigint);

  -- ── [205 추가] brand_orient_counter atomic 증가 ───────────────────────
  INSERT INTO public.brand_orient_counter (brand_id, last_seq)
  VALUES (p_brand_id, 1)
  ON CONFLICT (brand_id)
  DO UPDATE SET last_seq = public.brand_orient_counter.last_seq + 1
  RETURNING last_seq INTO v_orient_seq;

  IF v_orient_seq > 999 THEN
    RAISE EXCEPTION
      '[create_orient_sheet] O-seq 오버플로 (>999) for brand_id=%', p_brand_id
      USING ERRCODE = '22003';
  END IF;

  -- ── [205 추가] orient_no 생성: B{brand_seq 4자리}-O{orient_seq 3자리} ──
  v_orient_no := 'B' || lpad(v_brand_seq::text, 4, '0')
              || '-O' || lpad(v_orient_seq::text, 3, '0');

  -- ── data 초기값 구성 (195와 동일) ─────────────────────────────────────
  -- §15-11 구조: {brand:{name,intro,official_accounts}, cards:[]}
  v_init_data := jsonb_build_object(
    'brand', jsonb_build_object(
      'name',              COALESCE(v_brand_name, ''),
      'intro',             '',
      'official_accounts', ''
    ),
    'cards', '[]'::jsonb
  );

  -- ── INSERT ────────────────────────────────────────────────────────────
  v_new_id     := gen_random_uuid();
  v_new_token  := gen_random_uuid();
  v_expires_at := now() + interval '30 days';

  INSERT INTO public.orient_sheets (
    id,
    brand_id,
    application_id,
    form_type,        -- NULL: cards 배열 안 각 카드가 form_type 결정(§15-11)
    token,
    token_expires_at,
    created_by,
    status,
    data,
    version,
    orient_no         -- [205 추가] 채번된 자체 식별번호
  ) VALUES (
    v_new_id,
    p_brand_id,
    p_application_id,
    NULL,
    v_new_token,
    v_expires_at,
    auth.uid(),
    'draft',
    v_init_data,
    0,
    v_orient_no       -- [205 추가]
  );

  RETURN jsonb_build_object(
    -- 기존 반환 키 유지 (195 클라이언트 하위호환)
    'success',          true,
    'id',               v_new_id,
    'token',            v_new_token,
    'token_expires_at', v_expires_at,
    -- [205 추가] orient_no (PR 2에서 화면·메일 표시에 활용)
    'orient_no',        v_orient_no
  );
END;
$$;

-- GRANT 재부여: CREATE OR REPLACE는 기존 GRANT를 초기화하지 않지만 명시 재선언 (195 동일)
REVOKE EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.create_orient_sheet(uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.create_orient_sheet(uuid, uuid) IS
  '[195+205] 오리엔시트 발급. '
  'is_admin() 가드 — campaign_manager 포함 전체 관리자. '
  'p_brand_id 필수. p_application_id 선택(연결 시 brand_id 정합 + brand_name prefill). '
  'form_type = NULL(카드마다 결정). '
  'data 초기값 = {brand:{name,intro,official_accounts}, cards:[]}. '
  'token_expires_at = now()+30일, status=draft. '
  '[205] orient_no = B{brand_seq 4자리}-O{orient_seq 3자리} 자동 채번. '
  'brand_orient_counter + advisory lock 동시 발급 직렬화. '
  'SECURITY DEFINER + search_path 고정.';


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor에서 1단계씩 실행 — supabase.md 순차 안내 규칙)
-- ※ 아래는 주석처리된 가이드. 실제 실행은 사용자와 1단계씩 진행.
-- ============================================================
/*

-- [V1] brand_orient_counter 테이블 존재 + 정책 확인
SELECT table_name, row_security
  FROM information_schema.tables
 WHERE table_schema = 'public' AND table_name = 'brand_orient_counter';
-- 1행: table_name='brand_orient_counter', row_security='YES'

-- [V2] orient_sheets.orient_no 컬럼 + 제약 확인
SELECT column_name, data_type, is_nullable
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name   = 'orient_sheets'
   AND column_name  = 'orient_no';
-- 1행: orient_no, text, NO (NOT NULL)

SELECT constraint_name, constraint_type
  FROM information_schema.table_constraints
 WHERE table_schema  = 'public'
   AND table_name    = 'orient_sheets'
   AND constraint_name = 'orient_sheets_orient_no_key';
-- 1행: UNIQUE

-- [V3] 백필 결과 확인
SELECT os.orient_no, b.brand_seq, os.brand_id, os.created_at
  FROM public.orient_sheets os
  JOIN public.brands b ON b.id = os.brand_id
 ORDER BY os.brand_id, os.created_at
 LIMIT 20;
-- orient_no 가 모두 B{NNNN}-O{NNN} 형식인지 확인

-- [V4] brand_orient_counter 동기화 확인
SELECT boc.brand_id, boc.last_seq,
       count(os.id) AS orient_count
  FROM public.brand_orient_counter boc
  LEFT JOIN public.orient_sheets os ON os.brand_id = boc.brand_id
 GROUP BY boc.brand_id, boc.last_seq
 ORDER BY boc.brand_id;
-- last_seq = 해당 브랜드의 orient_count와 일치해야 함

-- [V5] create_orient_sheet 함수 신규 발급 테스트 (BEGIN~ROLLBACK으로 실행)
BEGIN;
  -- 브랜드 1개 선택
  WITH b AS (SELECT id FROM public.brands LIMIT 1)
  SELECT public.create_orient_sheet(b.id) FROM b;
  -- 반환: {success:true, id:..., token:..., token_expires_at:..., orient_no:'B????-O???'}
  -- orient_no 가 해당 브랜드의 기존 last_seq+1 인지 확인
ROLLBACK;

*/
