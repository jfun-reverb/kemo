-- ============================================================
-- 216_drop_legacy_columns.sql
-- 관리자 동적 권한 관리 PR3(마이그레이션 212 가림막 뷰) 후속 백로그 —
-- 코드에서 참조가 완전히 사라진 레거시 컬럼 정리
-- 2026-07-07, 사용자 확정("둘 다 삭제")
--
-- ── 삭제 대상 ①: public.influencers 비밀번호·계좌 6개 열 ──────────
--   - pw              : 마이그레이션 파일에 정의 없음(초기 스키마 잔재).
--                       DROP COLUMN IF EXISTS 로 안전 삭제.
--   - bank_name / bank_branch / bank_type / bank_number / bank_holder
--                       : 마이그레이션 002_sync_schema.sql:37-41 에서 추가.
--   마이그레이션 212(influencers_admin_view) 작성 시점에 개발 데이터베이스
--   실측 결과 6개 열 모두 0건이었고, 관리자 가림막 뷰 influencers_admin_view
--   의 SELECT 목록에서 이미 제외되어 있다(212 파일 주석 "⚠️ pw · bank_*
--   레거시 컬럼은 뷰에서 제외" 참고). dev/lib/storage.js 등 클라이언트 코드
--   에서도 참조 없음(2026-07-07 grep 재확인).
--
-- ── 삭제 대상 ②: public.companies 담당자 3개 열 ────────────────────
--   - contact_name / contact_email / contact_phone
--   마이그레이션 118_companies_master.sql:49-51 에서 추가.
--   2026-06-05 브랜드↔회사 정보 일원화(PR #436, project_brand_company_linking)
--   로 담당자 정보는 brands.primary_contact_name / primary_phone / primary_email
--   로 이관 완료 — 회사 등록/수정 모달의 입력칸 제거, storage.js 의 companies
--   조회·저장 쿼리(upsertCompany 등)에서도 이 3열을 다루지 않음(2026-07-07
--   grep 재확인, dev/lib/storage.js 의 company* 함수는 primary_contact_name 등
--   brands 컬럼만 다룸).
--   ⚠️ base 테이블에는 과거 입력값이 남아있을 수 있음 — 이번 삭제로 함께
--      소실된다(사용자 승인 완료, 아래 롤백 주석 참고).
--
-- ── 안전성 점검 결과 (2026-07-07, grep + information_schema 확인 기반) ──
--   1) 인덱스: 위 9개 열 중 어느 것에도 인덱스 없음(단독/복합 모두 없음)
--   2) 제약(CHECK/UNIQUE/FK): bank_type 의 DEFAULT '普通' 외 CHECK 제약 없음.
--      companies.contact_* 3열에는 UNIQUE/CHECK/FK 없음(companies 의 유일한
--      제약은 name_normalized UNIQUE·status CHECK — 118_companies_master.sql)
--   3) 트리거: companies 테이블 트리거 3종(trg_companies_name_normalized /
--      trg_companies_updated_at / trg_brands_company_total_brands) 중 어느
--      것도 contact_* 를 참조하지 않음(name_normalized·total_brands 만 다룸)
--   4) 뷰: influencers_admin_view(마이그레이션 212)는 pw·bank_* 를 SELECT
--      하지 않으므로 이번 삭제로 뷰가 깨지지 않음. companies 를 SELECT하는
--      뷰는 현재 없음(application_message_summary 등 기존 뷰는 companies
--      미참조)
--   5) 함수(원격 호출 함수 포함): grep 결과 pw·bank_*·companies.contact_* 를
--      본문에서 다루는 함수 없음(brand_applications.contact_name·
--      brands.primary_contact_name 등 이름이 비슷한 다른 테이블 컬럼을
--      다루는 함수는 다수 있으나 이번 삭제 대상과 무관 — 절대 건드리지 않음)
--   6) 행 단위 보안 정책(RLS): PostgreSQL RLS 는 행 단위 정책이라 컬럼
--      삭제와 무관(정책 조건절에서 이 9개 열을 참조하는 정책도 없음)
--   → CASCADE 불필요. 전부 RESTRICT(기본값)로 안전하게 삭제 가능.
--
-- ── 개인정보 관점 ──────────────────────────────────────────────
--   비밀번호 해시 잔재(pw)·계좌 정보(bank_*)·회사 담당자 개인정보(contact_*)
--   를 제거하는 것은 더 이상 쓰지 않는 개인정보를 지우는 개인정보 최소화
--   (수집·보유 범위 축소)에 해당한다. 개인정보처리방침상 회원에게 불리한
--   변경이 아니므로 별도 통지·재동의 절차 불필요.
--
-- ── 롤백 ───────────────────────────────────────────────────────
--   ALTER TABLE public.influencers ADD COLUMN pw text;
--   ALTER TABLE public.influencers ADD COLUMN bank_name text;
--   ALTER TABLE public.influencers ADD COLUMN bank_branch text;
--   ALTER TABLE public.influencers ADD COLUMN bank_type text DEFAULT '普通';
--   ALTER TABLE public.influencers ADD COLUMN bank_number text;
--   ALTER TABLE public.influencers ADD COLUMN bank_holder text;
--   ALTER TABLE public.companies ADD COLUMN contact_name text;
--   ALTER TABLE public.companies ADD COLUMN contact_email text;
--   ALTER TABLE public.companies ADD COLUMN contact_phone text;
--   ⚠️ 컬럼 구조만 되돌릴 뿐, 삭제된 실제 데이터(비밀번호 해시·계좌번호·
--      담당자 연락처)는 복구 불가 — 백업 없이는 원복 불가능.
-- ============================================================

-- ============================================================
-- SECTION 1. influencers — 비밀번호·계좌 6개 열 삭제
-- ============================================================
ALTER TABLE public.influencers DROP COLUMN IF EXISTS pw;
ALTER TABLE public.influencers DROP COLUMN IF EXISTS bank_name;
ALTER TABLE public.influencers DROP COLUMN IF EXISTS bank_branch;
ALTER TABLE public.influencers DROP COLUMN IF EXISTS bank_type;
ALTER TABLE public.influencers DROP COLUMN IF EXISTS bank_number;
ALTER TABLE public.influencers DROP COLUMN IF EXISTS bank_holder;

-- ============================================================
-- SECTION 2. companies — 담당자 3개 열 삭제
-- ============================================================
ALTER TABLE public.companies DROP COLUMN IF EXISTS contact_name;
ALTER TABLE public.companies DROP COLUMN IF EXISTS contact_email;
ALTER TABLE public.companies DROP COLUMN IF EXISTS contact_phone;

-- ============================================================
-- SECTION 3. PostgREST 스키마 캐시 갱신
-- ============================================================
NOTIFY pgrst, 'reload schema';
