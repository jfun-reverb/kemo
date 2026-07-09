-- ============================================================
-- 201_orient_mail_sent_tracking.sql
-- 2026-06-29
--
-- 목적:
--   오리엔시트 발급 메일 발송 추적. 이미 발송한 시트는 재발송 모달에서
--   「메일 발송」 버튼을 비활성하고 발송 일시를 표시하기 위함.
--   (Edge Function notify-orient-sheet 가 발송 성공 시 기록)
--
-- 사양서: docs/specs/2026-06-18-brand-self-orient-sheet.md
--
-- 변경:
--   orient_sheets 에 컬럼 2개 추가
--     - mail_sent_at  timestamptz NULL : 최근 발송 성공 시각(NULL=미발송)
--     - mail_sent_to  text        NULL : 최근 발송 수신 이메일(재발송 비교·표시용)
--
-- 운영 데이터 영향:
--   신규 컬럼(둘 다 NULL 허용) — 기존 행은 NULL(미발송)로 시작, 영향 없음.
--   행 단위 보안 정책 변경 없음(기존 UPDATE 정책 유지, Edge Function 은 service_role).
--
-- 롤백:
--   ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS mail_sent_at;
--   ALTER TABLE public.orient_sheets DROP COLUMN IF EXISTS mail_sent_to;
-- ============================================================

BEGIN;

ALTER TABLE public.orient_sheets
  ADD COLUMN IF NOT EXISTS mail_sent_at timestamptz,
  ADD COLUMN IF NOT EXISTS mail_sent_to text;

COMMIT;
