-- ============================================================
-- 535_companies_address_detail.sql
-- 브랜드 정보 페이지 — 작업 1: 회사(companies) 에 「상세 주소」 칸 추가
--   작업표 docs/specs/2026-10-16-brand-info-page-breakdown.md 「작업 1 — 회사 상세 주소 칸」
--
-- 목적
--   companies.address(기본 주소) 옆에 상세 주소(동·호수 등)를 따로 담는 address_detail text NULL 을 더한다.
--   정책·트리거·함수·뷰는 바꾸지 않는다(칸만 추가). 기존 행은 NULL 그대로.
--
-- 🔴 운영 반영 — 이 칸은 526~534 브랜드 계정 묶음과 무관하게 **운영에 먼저 따로** 넣는다.
--   · 관리자 회사 화면 코드(조각 2)가 main 으로 가기 전에 적용해야 한다.
--   · 이유: fetchCompanies(storage.js)가 칸을 이름으로 지정해 조회하므로, 칸이 없는 서버에서는
--     조회가 오류가 되어 회사 목록이 [] 로 돌아오고, 브랜드가 회사에서 떨어져 보인다.
--   · 순서: 이 마이그레이션(운영 SQL 편집기) → 조각 2 코드 머지. 반대로 하면 위 증상.
--   · 개발서버: SQL 편집기에 이 파일 전체를 실행.
--
-- 안전성: ADD COLUMN IF NOT EXISTS(NULL 허용·기본값 없음)는 표를 다시 쓰지 않고 즉시 끝난다. 멱등.
--
-- 롤백(주석)
--   1) 먼저 조각 2 코드(address_detail 을 읽고 쓰는 화면·storage.js)를 되돌려 배포한다 — 칸을 지정해 조회하는 코드가
--      남은 채 칸을 지우면 회사 목록이 [] 가 된다.
--   2) 그 다음:
--        ALTER TABLE public.companies DROP COLUMN IF EXISTS address_detail;
--      (입력된 상세 주소 값은 함께 사라진다. 필요하면 먼저 백업)
-- ============================================================

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS address_detail text NULL;

COMMENT ON COLUMN public.companies.address_detail IS '상세 주소 — 기본 주소는 address';
