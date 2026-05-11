-- ════════════════════════════════════════════════════════════════════
-- migration 105: notifications.kind CHECK 제약에 application_cancelled 추가
-- ════════════════════════════════════════════════════════════════════
--
-- 사양: docs/specs/2026-05-11-application-cancel.md §4-10
-- 배경: migration 037 에서 notifications.kind CHECK 제약을
--       (deliverable_rejected / deliverable_changed / deliverable_approved)
--       3종으로 한정. PR-B (인플루언서 본인 응모 취소 UI) 가 본인 취소
--       완료 알림(kind='application_cancelled') 1건을 클라이언트에서
--       INSERT 하므로 CHECK 제약 확장이 필요.
--
-- reviewer 검수에서 발견 — migration 104(RPC + 컬럼) 와 PR-B 사이
-- 누락된 항목을 본 마이그레이션으로 보완.
-- ════════════════════════════════════════════════════════════════════

ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled'
  ));

COMMENT ON COLUMN public.notifications.kind IS
  '알림 종류. deliverable_* 3종(037)·application_cancelled(105). '
  '관리자 알림은 admin_notices 테이블 별도.';
