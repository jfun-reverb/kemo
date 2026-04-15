-- migration: 034_add_channel_match
-- purpose: campaigns 테이블에 channel_match 컬럼 추가
--          채널 복수 선택 캠페인에서 OR/AND 표기 구분용 (자격 검증 로직 변화 없음)
--
-- rollback:
--   ALTER TABLE campaigns DROP COLUMN IF EXISTS channel_match;

ALTER TABLE campaigns
  ADD COLUMN IF NOT EXISTS channel_match text
    DEFAULT 'or'
    CHECK (channel_match IN ('or', 'and'));

COMMENT ON COLUMN campaigns.channel_match IS
  'OR: 선택 채널 중 하나 이상 해당 / AND: 선택 채널 모두 해당. NULL은 OR로 해석. 표시 전용 — 자격 검증 로직 변경 없음.';
