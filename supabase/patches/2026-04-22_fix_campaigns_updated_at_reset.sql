-- 2026-04-22_fix_campaigns_updated_at_reset.sql
-- 운영/개발 DB 수동 패치 기록
--
-- 배경: migration 066의 초기 버전이
--   ALTER TABLE campaigns ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
-- 로 작성돼 ALTER 시점 now()가 전 레코드에 일괄 주입됨.
-- 이어진 UPDATE의 WHERE 조건(`updated_at < created_at`)이 매칭되지 않아
-- '모든 캠페인 수정일이 몇 분 전으로 동일' 상태가 발생.
--
-- 적용: 양 서버 Supabase SQL Editor에서 직접 실행 (2026-04-22)
-- migration 066 파일은 3단계 패턴으로 retrofit 됐으므로 신규 환경에선 재발 없음.

UPDATE campaigns SET updated_at = created_at;

-- 검증
-- SELECT id, created_at, updated_at FROM campaigns ORDER BY created_at DESC LIMIT 5;
-- 기대: created_at == updated_at 동일
