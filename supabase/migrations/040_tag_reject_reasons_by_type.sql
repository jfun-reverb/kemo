-- ============================================================
-- migration: 040_tag_reject_reasons_by_type
-- purpose  : 반려사유 템플릿을 모집 타입별로 태깅
--            - monitor(영수증)용, gifting/visit(게시물 URL)용, 공통
--            - 반려 모달에서 캠페인 타입에 맞는 사유만 노출
--
-- 사용 규칙:
--   recruit_types = [] (빈 배열) → 모든 타입에 노출
--   recruit_types = ['monitor'] → 리뷰어 전용
--   recruit_types = ['gifting','visit'] → 기프팅·방문형 전용
--
-- rollback:
--   UPDATE lookup_values SET recruit_types = '{}' WHERE kind='reject_reason';
-- ============================================================

-- monitor(영수증) 전용
UPDATE lookup_values SET recruit_types = ARRAY['monitor']
 WHERE kind = 'reject_reason' AND code IN ('image_unclear', 'amount_mismatch');

-- gifting·visit(게시물 URL) 전용
UPDATE lookup_values SET recruit_types = ARRAY['gifting', 'visit']
 WHERE kind = 'reject_reason' AND code = 'post_deleted';

-- 모든 타입 공통 (빈 배열 유지)
UPDATE lookup_values SET recruit_types = '{}'
 WHERE kind = 'reject_reason' AND code IN ('pr_tag_missing', 'mention_missing');
