-- ============================================================
-- 234_orient_notify_debounce.sql
-- 2026-07-13
--
-- 목적:
--   오리엔시트 제출 알림(notify-orient-submitted) 과다 발송 수정.
--   사용자 결정: 재제출 실시간 메일 유지 + 30분 간격 디바운스.
--
--   1) orient_sheets.last_notified_at 컬럼 추가
--      - Edge Function 이 관리자 알림 메일을 실제로 1통 이상 발송한 직후
--        이번 제출 시각(record.last_submitted_at)을 기록.
--      - 다음 UPDATE 웹훅에서 "마지막 알림 후 30분 경과했는지" 판정 기준.
--
--   원인 진단(마이그레이션 202 이후 확인):
--     mark_orient_card_consumed(196, 관리자 카드별 발행)가 orient_sheets 를
--     UPDATE 하면서 status='submitted' 를 유지 → 데이터베이스 웹훅 Row filter
--     (status='submitted')를 다시 통과해 "[수정 재제출]" 메일이 오발송됨.
--     last_submitted_at 은 submit_orient_sheet(제출 전용 함수)만 갱신하므로,
--     Edge Function 이 old_record.last_submitted_at 과 비교해 실제 제출인지
--     판별하도록 게이트를 추가(코드 변경 — 이 마이그레이션은 컬럼만 추가).
--
--   함께 배포:
--     supabase/functions/notify-orient-submitted/index.ts
--       게이트 1) last_submitted_at 이 old_record 와 동일하면 스킵
--                (발행 오발송 차단 + 이 함수 자신의 last_notified_at UPDATE 로
--                 인한 재트리거 무한루프도 동일 게이트에서 차단)
--       게이트 2) 재제출(신규 제출 아님) 은
--                (record.last_submitted_at - record.last_notified_at) < 30분이면 스킵.
--                신규 제출은 게이트 2 를 거치지 않고 항상 발송.
--
-- 기존 기능 영향:
--   - last_notified_at 컬럼: NULL 허용 신규 컬럼 → 기존 행 NULL 시작, 영향 없음
--     (NULL = "아직 알림 발송 이력 없음" → 게이트2 에서 무조건 발송으로 처리)
--   - submit_orient_sheet / mark_orient_card_consumed 함수 시그니처·동작 불변
--     (이 컬럼을 건드리지 않음 — Edge Function 이 service_role 로 별도 UPDATE)
--   - RLS 불필요: orient_sheets 는 익명 직접 접근 0(토큰 함수로만) 정책 유지,
--     이 컬럼도 service_role(Edge Function)만 UPDATE — 클라이언트 경로 없음
--   - 인플루언서·관리자 화면 무관 (조회 화면에서 이 컬럼 미노출)
--
-- 롤백:
--   ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS last_notified_at;
--   -- Edge Function 은 이전 커밋으로 되돌리기 (게이트 2개 제거)
-- ============================================================

BEGIN;

ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS last_notified_at timestamptz;

COMMENT ON COLUMN public.orient_sheets.last_notified_at IS
  '[234] notify-orient-submitted Edge Function 이 관리자 알림 메일을 마지막으로 '
  '발송했을 때의 제출 시각(record.last_submitted_at 스냅샷). '
  '재제출 30분 디바운스 판정 기준. NULL = 아직 알림 발송 이력 없음. '
  '이 Edge Function 만 UPDATE(service_role) — DB 함수는 건드리지 않음.';

-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';

COMMIT;
