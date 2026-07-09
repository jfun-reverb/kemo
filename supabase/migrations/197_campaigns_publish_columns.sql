-- ============================================================
-- 197_campaigns_publish_columns.sql
-- 2026-06-23
--
-- 목적:
--   오리엔시트 자동 채움 발행(PR⑦)에 필요한 campaigns 보조 컬럼 추가.
--   ① proxy_purchase: 가구매(영수증만·리뷰 게시물 불필요) 캠페인 플래그
--   ② emergency_publish_reason / emergency_published_by / emergency_published_at:
--      일본어 미보완 긴급 발행 감사 추적용 컬럼
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md
--   §15-2 (proxy_purchase 형식), §15-10 (가구매 확정)
--
-- 전제:
--   public.campaigns 테이블 기존 정의
--   186~196 마이그레이션 이미 적용
--
-- 변경 내용:
--   [A] proxy_purchase boolean NOT NULL DEFAULT false
--       - 오리엔시트 카드의 form_type = 'proxy_purchase' 인 경우 발행 시 true 설정
--       - 인증성공 판정 로직(computeCertStatus·admin-deliverables.js)에서
--         review_image 검수 단계를 건너뛰는 분기에 활용 (후속 JS 변경)
--       - NULL 불허, 기본값 false → 기존 전체 캠페인 영향 없음
--
--   [B] emergency_publish_reason text NULL
--       - 일본어 미보완 상태로 긴급 발행할 때 관리자가 입력하는 사유 메모
--       - 클라 게이트: campaign_admin 이상만 긴급 발행 UI 접근(DB 가드 아님)
--       - NULL 허용 — 일반 발행(일본어 완보완)은 NULL
--
--   [C] emergency_published_by uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL
--       - 긴급 발행을 수행한 관리자(auth.users.id)
--       - 참조 관리자가 삭제되면 SET NULL (감사 이력은 reason·at으로 보존)
--
--   [D] emergency_published_at timestamptz NULL
--       - 긴급 발행 시각 (UTC)
--
-- RLS 영향:
--   campaigns 테이블의 기존 행 단위 보안 정책(RLS)을 변경하지 않는다.
--   CUD 는 기존 "is_admin()" 정책에 자동 포함 — 컬럼 추가로 RLS 재등록 불필요.
--   긴급 발행 권한 제한(campaign_admin 이상)은 클라이언트 게이트로 구현한다.
--
-- 인덱스:
--   proxy_purchase: 부분 인덱스 (true 인 행만) — 가구매 캠페인 필터링 성능
--   emergency_published_by: 없음 (감사 조회 빈도 낮음)
--
-- 운영 데이터 영향:
--   ALTER TABLE ADD COLUMN 이므로 기존 캠페인 행은 모두 새 컬럼의 기본값/NULL 적용:
--     proxy_purchase = false (기본값, 변경 없음)
--     emergency_* = NULL (긴급 발행 이력 없음, 변경 없음)
--   기존 INSERT/UPDATE 쿼리가 새 컬럼을 명시하지 않아도 기본값/NULL로 정상 동작.
--
-- 적용 순서:
--   196_mark_orient_card_consumed.sql → 이 파일(197)
--
-- 롤백:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS proxy_purchase;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS emergency_publish_reason;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS emergency_published_by;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS emergency_published_at;
--   DROP INDEX IF EXISTS idx_campaigns_proxy_purchase;
-- ============================================================

BEGIN;


-- ============================================================
-- A. proxy_purchase 컬럼 추가
--    가구매(proxy_purchase) 형식 캠페인 플래그.
--    NOT NULL DEFAULT false → 기존 캠페인 전부 false (영향 없음).
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS proxy_purchase boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.campaigns.proxy_purchase IS
  '[197] 가구매(proxy_purchase) 캠페인 플래그. '
  '오리엔시트 카드 form_type=proxy_purchase 로 발행된 캠페인은 true. '
  'true 이면 인증성공 판정 시 review_image(리뷰 캡처) 검수를 건너뜀. '
  '일반 리뷰어·기프팅·방문형 캠페인은 false(기본값).';


-- proxy_purchase=true 캠페인만 대상 부분 인덱스 (필터 조회 성능)
CREATE INDEX IF NOT EXISTS idx_campaigns_proxy_purchase
  ON public.campaigns (id)
  WHERE proxy_purchase = true;


-- ============================================================
-- B. emergency_publish_reason 컬럼 추가
--    일본어 미보완 긴급 발행 사유 메모.
--    NULL = 정상 발행 (일본어 완보완).
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS emergency_publish_reason text NULL;

COMMENT ON COLUMN public.campaigns.emergency_publish_reason IS
  '[197] 일본어 미보완 긴급 발행 사유 메모. '
  'NULL = 정상 발행(일본어 완보완). '
  'NOT NULL = 긴급 발행 — 사유 필수 기재. '
  '클라 게이트: campaign_admin 이상만 긴급 발행 UI 진입 가능 (DB 가드 아님).';


-- ============================================================
-- C. emergency_published_by 컬럼 추가
--    긴급 발행 수행 관리자(auth.users.id).
--    관리자 삭제 시 SET NULL (감사 이력은 reason·at으로 보존).
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS emergency_published_by uuid NULL
    REFERENCES auth.users(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.campaigns.emergency_published_by IS
  '[197] 긴급 발행을 수행한 관리자(auth.users.id 참조). '
  'NULL = 정상 발행. NOT NULL = 긴급 발행 수행자. '
  '참조 관리자 삭제 시 SET NULL (감사 이력은 emergency_publish_reason·at으로 보존).';


-- ============================================================
-- D. emergency_published_at 컬럼 추가
--    긴급 발행 시각 (UTC).
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS emergency_published_at timestamptz NULL;

COMMENT ON COLUMN public.campaigns.emergency_published_at IS
  '[197] 긴급 발행 시각(UTC). NULL = 정상 발행. '
  'Not NULL = 긴급 발행 완료 시각.';


-- ============================================================
-- 스모크 테스트용 SELECT 예시 (주석 — SQL Editor에서 확인 용도)
-- ============================================================
--
-- [1] 컬럼 추가 확인
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema = 'public'
--     AND table_name   = 'campaigns'
--     AND column_name IN (
--       'proxy_purchase',
--       'emergency_publish_reason',
--       'emergency_published_by',
--       'emergency_published_at'
--     )
--   ORDER BY ordinal_position;
--   -- 4행 반환되어야 함
--
-- [2] 기존 캠페인 기본값 확인 (전체가 false, NULL)
--   SELECT COUNT(*) AS total,
--          COUNT(*) FILTER (WHERE proxy_purchase = false) AS proxy_false,
--          COUNT(*) FILTER (WHERE emergency_publish_reason IS NULL) AS reason_null
--   FROM public.campaigns;
--   -- total = proxy_false = reason_null 이어야 함
--
-- [3] 부분 인덱스 확인
--   SELECT indexname, indexdef
--   FROM pg_indexes
--   WHERE tablename = 'campaigns'
--     AND indexname = 'idx_campaigns_proxy_purchase';


-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';


COMMIT;
