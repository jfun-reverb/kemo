-- 051_add_reward_note.sql
-- 캠페인에 리워드 금액 외 추가 안내(지급 조건/정산 시점 등) 저장용 텍스트 컬럼 추가
-- NULL 허용 · 최대 500자 (애플리케이션에서 maxlength 강제, DB는 자유)

ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS reward_note text;

COMMENT ON COLUMN campaigns.reward_note IS
  '리워드 금액 외 추가 안내 (지급 조건·정산 시점·수수료 등). 관리자 입력 자유 텍스트, 인플루언서 상세에 노출';

-- 롤백:
-- ALTER TABLE campaigns DROP COLUMN IF EXISTS reward_note;
