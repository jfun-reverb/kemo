-- ============================================
-- lookup_values.recruit_types 컬럼 추가
-- 채널(kind='channel')에만 의미: 해당 채널을 사용할 수 있는 모집 타입 목록
-- 값: monitor / gifting / visit (캠페인 recruit_type 코드와 일치)
-- ============================================

ALTER TABLE lookup_values
  ADD COLUMN IF NOT EXISTS recruit_types text[] NOT NULL DEFAULT '{}';

COMMENT ON COLUMN lookup_values.recruit_types IS
  '채널 전용. 이 채널을 선택 가능한 캠페인 모집 타입 목록 (monitor/gifting/visit)';

-- 기존 채널은 모든 타입에서 사용 가능하도록 기본값 채움
UPDATE lookup_values
   SET recruit_types = ARRAY['monitor','gifting','visit']
 WHERE kind = 'channel'
   AND (recruit_types IS NULL OR cardinality(recruit_types) = 0);
