-- 066_add_campaigns_updated_at.sql
-- campaigns 테이블에 updated_at 컬럼 추가
-- 관리자 편집(폼 저장·상태 변경·순서 변경) 시점 기록용
-- updateCampaign() 클라이언트 헬퍼(storage.js)가 호출 시점에 now() 세팅

BEGIN;

ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- 기존 레코드는 created_at 값으로 초기화 (편집 이력 없음 의미)
UPDATE campaigns
  SET updated_at = created_at
  WHERE updated_at < created_at OR updated_at IS NULL;

COMMENT ON COLUMN campaigns.updated_at IS
  '관리자 편집 시점. updateCampaign() 호출 시 클라이언트가 now() 세팅. 조회수/자동 종료 등 시스템 UPDATE는 이 함수를 거치지 않아 수정일 오염 없음.';

-- PostgREST schema cache 즉시 재로드
NOTIFY pgrst, 'reload schema';

COMMIT;

-- 롤백:
-- ALTER TABLE campaigns DROP COLUMN IF EXISTS updated_at;
