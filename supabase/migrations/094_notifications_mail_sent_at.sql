-- ============================================================
-- 094_notifications_mail_sent_at.sql
-- purpose  : notifications 테이블에 메일 중복 발송 차단용 컬럼 추가
--            - mail_sent_at timestamptz NULL: NULL이면 미발송, 값이 있으면 발송 완료
--            - Edge Function이 "mail_sent_at IS NULL" 조건으로 멱등성 가드
--
-- 설계 결정:
--   - NULL 허용: 기존 행(알림은 존재하나 메일 미발송)을 NULL로 처리
--   - partial index: WHERE mail_sent_at IS NULL 조건. 미발송 행만 빠르게 스캔
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행
--   2. Edge Function 코드에서 mail_sent_at IS NULL 가드 로직 구현 + 테스트
--   3. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--      ※ 운영 적용 직후 추가 SQL 1줄 실행 필수 (하단 [운영 일괄 마킹] 섹션 참고)
--        — 기존 알림 전체를 '발송 완료'로 마킹하여 소급 메일 발송 차단
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. mail_sent_at 컬럼 추가
--    - NULL 기본값: 기존 행 및 신규 알림 모두 NULL로 시작
--    - Edge Function이 발송 완료 후 UPDATE SET mail_sent_at = now() 로 마킹
-- ============================================================

ALTER TABLE public.notifications
  ADD COLUMN IF NOT EXISTS mail_sent_at timestamptz;

COMMENT ON COLUMN public.notifications.mail_sent_at IS
  '알림 메일 발송 완료 시각. NULL = 미발송(발송 대기 또는 메일 알림 대상 아님). Edge Function이 발송 후 now()로 갱신. 중복 발송 방지 가드용.';


-- ============================================================
-- 2. partial index 생성
--    미발송 행만 인덱싱 → Edge Function의 발송 대상 조회 성능 최적화
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_notifications_mail_unsent
  ON public.notifications(created_at DESC)
  WHERE mail_sent_at IS NULL;

COMMENT ON INDEX public.idx_notifications_mail_unsent IS
  '미발송 알림만 인덱싱. Edge Function의 발송 대상 조회 성능 최적화.';


-- ============================================================
-- 3. 보안 트리거 — mail_sent_at 컬럼은 service_role만 변경 가능
--
--    배경: notifications_update_own 정책은 본인 행 전체 UPDATE 허용.
--    인플루언서가 mail_sent_at을 직접 임의 시각으로 채우면 메일이 영구 미발송
--    상태로 마킹되어 발송 차단됨. 이를 차단하기 위해 BEFORE UPDATE OF mail_sent_at
--    트리거로 호출 권한을 검증.
--
--    auth.role() 값:
--      - 'authenticated': 인플루언서·관리자 클라이언트 (차단)
--      - 'anon': 비로그인 (차단)
--      - 'service_role': Edge Function (허용)
--      - NULL: SQL Editor·트리거 등 super_user (허용 — 마이그레이션·디버깅용)
-- ============================================================

-- SECURITY INVOKER (기본값 명시) — 이 함수는 auth.role()만 호출하고 테이블 접근 없음.
-- DEFINER로 두면 미래에 로직이 추가될 때 권한 상승 경로가 생길 위험. INVOKER가 안전.
CREATE OR REPLACE FUNCTION public.guard_notifications_mail_sent_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  -- mail_sent_at 값이 변경된 경우에만 검증 (read_at 등 다른 컬럼 UPDATE는 통과)
  IF NEW.mail_sent_at IS DISTINCT FROM OLD.mail_sent_at THEN
    -- authenticated/anon 차단, service_role 또는 NULL(super)만 허용
    IF auth.role() IN ('authenticated', 'anon') THEN
      RAISE EXCEPTION 'mail_sent_at can only be updated by service_role'
        USING ERRCODE = '42501',
              HINT = 'Use Edge Function (notify-deliverable-decision) to update mail_sent_at';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_notifications_mail_sent_at IS
  '[094] notifications.mail_sent_at 변경 권한을 service_role/super 로만 제한. authenticated/anon이 직접 UPDATE 시 42501 예외.';

-- 권한 정리 — 함수는 트리거 전용
REVOKE ALL ON FUNCTION public.guard_notifications_mail_sent_at() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.guard_notifications_mail_sent_at() FROM authenticated;
REVOKE ALL ON FUNCTION public.guard_notifications_mail_sent_at() FROM anon;

-- 트리거 등록 (멱등 — 기존 트리거가 있으면 교체)
DROP TRIGGER IF EXISTS trg_guard_notifications_mail_sent_at ON public.notifications;
CREATE TRIGGER trg_guard_notifications_mail_sent_at
  BEFORE UPDATE OF mail_sent_at ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.guard_notifications_mail_sent_at();


-- ============================================================
-- 4. Edge Function 연동 가이드 (참고)
--
--    발송 전 중복 체크 패턴:
--      SELECT * FROM notifications
--      WHERE mail_sent_at IS NULL
--        AND kind IN ('deliverable_rejected', 'deliverable_approved')
--        AND created_at > now() - interval '24 hours'
--      FOR UPDATE SKIP LOCKED;
--
--    발송 완료 후 마킹:
--      UPDATE notifications
--      SET mail_sent_at = now()
--      WHERE id = '<notification_uuid>';
-- ============================================================


COMMIT;


-- ============================================================
-- [운영 일괄 마킹] — 운영서버 적용 시 위 BEGIN/COMMIT 직후에 한 번 더 실행
--   목적: 운영서버 배포 시점 이전 알림(누적된 모든 알림)을 '발송 완료'로 마킹
--         소급 메일 발송 완전 차단 (사용자 결정 — 2026-05-06)
--   주의: 개발서버에는 실행하지 말 것 (개발 알림 데이터 변형)
-- ============================================================
/*

UPDATE public.notifications
SET mail_sent_at = now()
WHERE mail_sent_at IS NULL;

-- 마킹 결과 확인
SELECT
  COUNT(*) AS total,
  COUNT(*) FILTER (WHERE mail_sent_at IS NOT NULL) AS marked_sent,
  COUNT(*) FILTER (WHERE mail_sent_at IS NULL) AS still_unsent
FROM public.notifications;
-- 기대값: total = marked_sent, still_unsent = 0

*/


-- ============================================================
-- 검증 쿼리 (적용 후 실행)
-- ============================================================
/*

-- [1] 컬럼 추가 확인
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'notifications'
  AND column_name = 'mail_sent_at';
-- 기대값: timestamptz, YES(nullable), NULL(기본값 없음)

-- [2] partial index 생성 확인
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'notifications'
  AND indexname = 'idx_notifications_mail_unsent';
-- 기대값: WHERE (mail_sent_at IS NULL) 포함

-- [3] 기존 알림 행 영향 없음 확인 (개발서버)
SELECT COUNT(*) AS total, COUNT(mail_sent_at) AS already_sent
FROM public.notifications;
-- 개발서버 기대값: already_sent = 0 (기존 행 모두 NULL)
-- 운영서버는 [운영 일괄 마킹] 실행 후 already_sent = total

*/


-- ============================================================
-- 롤백 (적용 취소 시 아래 실행)
-- ============================================================
/*

BEGIN;

-- 1) 트리거·함수 제거
DROP TRIGGER IF EXISTS trg_guard_notifications_mail_sent_at ON public.notifications;
DROP FUNCTION IF EXISTS public.guard_notifications_mail_sent_at();

-- 2) 인덱스 제거
DROP INDEX IF EXISTS public.idx_notifications_mail_unsent;

-- 3) 컬럼 제거 (이미 채워진 mail_sent_at 데이터는 영구 손실 — 주의)
ALTER TABLE public.notifications
  DROP COLUMN IF EXISTS mail_sent_at;

COMMIT;

*/
