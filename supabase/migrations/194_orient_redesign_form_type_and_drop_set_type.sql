-- ============================================================
-- 194_orient_redesign_form_type_and_drop_set_type.sql
-- 2026-06-23
--
-- 목적:
--   §15 "1 링크 다형식·cards 배열" 재설계에 따른 DB 변경.
--   ① orient_sheets.form_type CHECK를 3종(proxy_purchase 추가)으로 확장.
--   ② "1 링크 = 1 형식" 전제였던 set_orient_form_type(188/189)을 폐기(DROP).
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md
--   §15-2 (형식 3종), §15-10 (가구매 proxy_purchase 확정),
--   §15-11 (form_type 컬럼 = 폐기 또는 대표값, set_orient_form_type 재설계)
--
-- 전제:
--   186_orient_sheets_table.sql  — orient_sheets 테이블 존재
--   187_orient_sheets_functions.sql — 익명 토큰 함수 3종(get/save/submit)
--   188_orient_set_form_type.sql / 189_orient_set_form_type_draft_editable.sql
--     — DROP 대상 함수
--
-- 변경 내용:
--   [A] orient_sheets.form_type CHECK 제약 교체
--       현행: form_type IS NULL OR form_type IN ('reviewer', 'seeding')
--       변경: form_type IS NULL OR form_type IN ('reviewer', 'seeding', 'proxy_purchase')
--       ※ 컬럼 자체는 존속 — 운영 배포 후 대표값 또는 메타 태깅용으로 사용 가능.
--         cards 배열 안 각 카드가 자체 form_type을 갖게 돼 컬럼의 주된 역할은 의미 축소됨.
--
--   [B] set_orient_form_type(uuid, text) DROP
--       188/189 에서 CREATE OR REPLACE로 정의된 함수를 제거.
--       "카드마다 form_type"인 구조에서는 이 함수가 개념적으로 맞지 않음.
--       호출부: dev/sales/orient.html의 selectType() 함수 (PR 폼 재작성 시 제거).
--
-- 운영 데이터 영향:
--   - orient_sheets 테이블: CHECK 제약 변경만. 기존 행의 form_type 값(reviewer/seeding/NULL)은
--     새 제약에서 모두 유효 → 기존 행 변경 없음.
--   - 개발서버 dev DB에는 테스트 행이 있을 수 있으나,
--     이 PR과 같은 작업으로 사용자 확정에 따라 DELETE 처리(별도 SQL, 이 파일 외).
--   - 운영서버에는 orient_sheets 행이 없음(운영 미배포) → 영향 없음.
--
-- 적용 순서:
--   186 → 187 → 188 → 189 → 190 → 191 → 192 → 193 → 이 파일(194)
--
-- 롤백:
--   [A] CHECK 되돌리기:
--     ALTER TABLE public.orient_sheets DROP CONSTRAINT IF EXISTS orient_sheets_form_type_check;
--     ALTER TABLE public.orient_sheets ADD CONSTRAINT orient_sheets_form_type_check
--       CHECK (form_type IS NULL OR form_type IN ('reviewer', 'seeding'));
--   [B] set_orient_form_type 복구:
--     189_orient_set_form_type_draft_editable.sql 을 SQL Editor에서 BEGIN~COMMIT 재실행.
-- ============================================================

BEGIN;


-- ============================================================
-- A. orient_sheets.form_type CHECK 제약 교체
--    ① 기존 제약 이름 확인 후 DROP
--    ② proxy_purchase 포함 3종 새 제약 추가
--
--    PostgreSQL 은 CHECK 제약 이름을 자동 생성하는 경우 보통
--    "{테이블명}_{컬럼명}_check" 패턴을 쓴다(186 마이그레이션 인라인 CHECK).
--    혹시 이름이 다를 경우에 대비해 IF EXISTS 로 안전하게 DROP.
-- ============================================================

-- 기존 CHECK 제약 제거
ALTER TABLE public.orient_sheets
  DROP CONSTRAINT IF EXISTS orient_sheets_form_type_check;

-- 새 CHECK 제약 추가: 3종 + NULL 허용
ALTER TABLE public.orient_sheets
  ADD CONSTRAINT orient_sheets_form_type_check
  CHECK (form_type IS NULL OR form_type IN ('reviewer', 'seeding', 'proxy_purchase'));

COMMENT ON COLUMN public.orient_sheets.form_type IS
  '[186/194] reviewer | seeding | proxy_purchase | NULL. '
  '§15-11 재설계 이후 cards 배열 내 카드별 form_type이 실질 데이터. '
  '이 컬럼은 대표값·메타 태깅용으로 존속(NULL = 발급 시 미결정).';


-- ============================================================
-- B. set_orient_form_type(uuid, text) DROP
--    188/189 에서 정의된 함수. CREATE OR REPLACE 가 두 번 실행됐으므로
--    최종 등록 시그니처 set_orient_form_type(uuid, text) 단일 버전만 존재.
--    DROP FUNCTION ... IF EXISTS 로 안전하게 제거.
--
--    ⚠️ 이 DROP 이후 아래 호출부는 동작 불가 — 폼 재작성 PR에서 제거 필요:
--       dev/sales/orient.html  :730  selectType() → sb.rpc('set_orient_form_type', ...)
--       sales/orient.html       :730  (dev/sales 의 빌드 복사본 — 동일 내용)
--
--    ⚠️ storage.js 에는 setOrientFormType 래퍼가 없었으므로 JS 파일 변경 불필요.
--       (orient.html 이 storage.js 를 쓰지 않고 sb.rpc 직접 호출)
-- ============================================================

DROP FUNCTION IF EXISTS public.set_orient_form_type(uuid, text);


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
