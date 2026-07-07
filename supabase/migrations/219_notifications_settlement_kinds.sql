-- ============================================================
-- 219_notifications_settlement_kinds.sql
-- 인플루언서 정산 관리 PR1 — 3/4 (notifications.kind CHECK 확장)
-- 사양서: docs/specs/2026-06-22-influencer-settlement.md §4, §9
--
-- 현재(마이그레이션 160 누적 7종, CLAUDE.md 및 아래 grep 으로 재확인):
--   ('deliverable_rejected', 'deliverable_changed', 'deliverable_approved',
--    'application_cancelled', 'message_received', 'application_approved',
--    'deliverable_proxy_submitted')
--
-- 이후(219): 위 7종 + 아래 2종 추가 = 9종
--   - 'settlement_paypal_required' : PayPal 미등록 안내 (backfill_settlements()가 INSERT, 마이그레이션 218)
--   - 'settlement_paid'            : 송금 완료 알림 (실제 INSERT 로직은 PR2 mark_settlement_paid RPC 몫.
--                                     PR1은 CHECK 확장만 — 아직 아무도 이 kind 로 INSERT 하지 않음)
--
-- ⚠️ 확인 방법(재발 방지): supabase/migrations 전체에서 notifications_kind_check 를
--   정의/확장한 최신 파일을 grep 해 현재 전체 목록을 실측 확인한 뒤 작성함(160이 최신,
--   그 이후 159/168 은 kind CHECK 를 건드리지 않음 — deliverables.kind 필터일 뿐).
--   하나라도 빠뜨리면 기존 알림 INSERT가 전부 깨지므로 전수 나열 필수.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved',
    'deliverable_proxy_submitted',
    'settlement_paypal_required',  -- 219 신규: 정산 PayPal 미등록 안내 (backfill_settlements)
    'settlement_paid'              -- 219 신규: 송금 완료 알림 (INSERT 로직은 PR2)
  ));

COMMENT ON COLUMN public.notifications.kind IS
  'deliverable_rejected | deliverable_changed | deliverable_approved | application_cancelled | '
  'message_received | application_approved | deliverable_proxy_submitted | '
  'settlement_paypal_required | settlement_paid';

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행)
-- ============================================================
/*

-- [V0] CHECK 제약 확장 확인 (9종 모두 포함돼야 함)
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.notifications'::regclass
  AND conname  = 'notifications_kind_check';

*/

-- ============================================================
-- 롤백 (160 버전 7종으로 복원)
-- ============================================================
-- ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
-- ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--   'deliverable_rejected', 'deliverable_changed', 'deliverable_approved',
--   'application_cancelled', 'message_received', 'application_approved',
--   'deliverable_proxy_submitted'
-- ));
