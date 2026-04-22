-- 066_add_campaigns_updated_at.sql
-- campaigns 테이블에 updated_at 컬럼 추가
-- 관리자 편집(폼 저장·상태 변경·순서 변경) 시점 기록용
-- updateCampaign() 클라이언트 헬퍼(storage.js)가 호출 시점에 now() 세팅
--
-- 구현 노트 (2026-04-22 보정):
-- 처음엔 ADD COLUMN ... NOT NULL DEFAULT now() 했다가 모든 기존 레코드가
-- ALTER 시점의 동일 now() 값으로 채워져 '모든 캠페인 수정일이 ALTER 시점으로'
-- 동기화되는 버그 발생. 지금은 NULL 허용 → created_at 값 복원 → NOT NULL 고정
-- 3단계 패턴으로 안전하게 처리.

BEGIN;

-- 1) 먼저 NULL 허용 + DEFAULT 없는 컬럼 추가
ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS updated_at timestamptz;

-- 2) 기존 레코드는 created_at 값으로 초기화 (편집 이력 없음 의미)
UPDATE campaigns
  SET updated_at = created_at
  WHERE updated_at IS NULL;

-- 3) NOT NULL + DEFAULT 확정 (이후 신규 INSERT도 자동 채움)
ALTER TABLE campaigns
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now();

COMMENT ON COLUMN campaigns.updated_at IS
  '관리자 편집 시점. updateCampaign() 호출 시 클라이언트가 now() 세팅. 조회수/자동 종료 등 시스템 UPDATE는 이 함수를 거치지 않아 수정일 오염 없음.';

-- PostgREST schema cache 즉시 재로드
NOTIFY pgrst, 'reload schema';

COMMIT;

-- 롤백:
-- ALTER TABLE campaigns DROP COLUMN IF EXISTS updated_at;
