-- ════════════════════════════════════════════════════════════════════
-- migration 106: lookup_values.kind CHECK 제약 확장
-- ════════════════════════════════════════════════════════════════════
--
-- 배경:
--   - migration 067 에서 lookup_values_kind_check 를 8개 kind 로 한정
--     (channel/category/content_type/ng_item/reject_reason/
--     blacklist_reason/violation_reason/caution)
--   - migration 103 (admin_email_subscriptions) 가 'admin_email_kind'
--     시드를 INSERT 하는데 CHECK 제약을 확장하지 않아 23514 에러
--   - migration 104 (application_cancellation) 도 'cancel_reason' 시드
--     를 INSERT 하므로 동일 문제
--
-- 본 마이그레이션은 CHECK 제약을 두 신규 kind 까지 확장한다.
-- 103/104 의 INSERT 가 ON CONFLICT DO NOTHING 으로 멱등이므로
-- 본 마이그레이션 실행 후 103/104 를 재실행하면 시드가 정상 INSERT 된다.
--
-- 적용 순서 (이미 23514 가 발생한 환경):
--   1) 본 마이그레이션 106 을 SQL Editor 에서 실행
--   2) migration 103 을 다시 실행 (이미 적용된 부분은 IF NOT EXISTS /
--      ON CONFLICT 로 건너뜀; INSERT 만 새로 추가됨)
--   3) migration 104 실행
--   4) migration 105 실행
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;

ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN (
    'channel',
    'category',
    'content_type',
    'ng_item',
    'reject_reason',
    'blacklist_reason',
    'violation_reason',
    'caution',
    'admin_email_kind',
    'cancel_reason'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | violation_reason | caution | admin_email_kind | cancel_reason';
