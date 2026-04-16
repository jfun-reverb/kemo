-- migration: 045_retag_reject_reasons
-- 목적: reject_reason 템플릿의 recruit_types 태깅을 비즈니스 상식대로 재정렬
--
-- 배경:
--   - commit a128738에서 모집타입별 결과물 매핑이 역방향(monitor=URL, gifting=이미지)으로 잘못 구현됨
--   - 그 상태에서 일부 반려 사유의 recruit_types 태깅이 원래 의도(migration 040)와 달라진 환경 발생
--   - 원래 스펙 복구 후 반려 사유 태깅도 아래 규칙으로 정렬
--
-- 최종 규칙 (2026-04-16 확정):
--   - pr_tag_missing   → ['gifting','visit']  (PR 태그는 SNS 게시물에만 적용)
--   - image_unclear    → ['monitor','visit']  (monitor=영수증, visit=현장 사진. 이미지 제출 타입)
--   - amount_mismatch  → ['monitor']           (영수증 금액·구매일은 monitor 전용)
--   - post_deleted     → ['gifting','visit']  (SNS 게시물 삭제/비공개)
--   - mention_missing  → ['gifting','visit']  (해시태그·멘션도 SNS 게시물에 적용)
--
-- idempotent: 이미 올바른 값이면 변화 없음

UPDATE public.lookup_values
   SET recruit_types = ARRAY['gifting','visit']
 WHERE kind = 'reject_reason'
   AND code IN ('pr_tag_missing','mention_missing','post_deleted');

UPDATE public.lookup_values
   SET recruit_types = ARRAY['monitor','visit']
 WHERE kind = 'reject_reason'
   AND code = 'image_unclear';

UPDATE public.lookup_values
   SET recruit_types = ARRAY['monitor']
 WHERE kind = 'reject_reason'
   AND code = 'amount_mismatch';
