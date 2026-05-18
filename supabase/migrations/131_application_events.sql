-- ============================================================
-- 131_application_events.sql
-- 2026-05-18
--
-- 목적:
--   관리자 일일 통합 다이제스트 (notify-admin-daily-digest) 의
--   「재처리 일감」 섹션에서 사용할 신청(applications) status 변경
--   audit 테이블 신설. 기존 deliverable_events (035) 와 동일 패턴.
--
-- 사양서:
--   docs/specs/2026-05-18-mail-pipeline-consolidation.md §13~§14 (확정)
--   docs/specs/2026-05-18-HANDOFF-mail-pipeline-consolidation.md §4
--
-- 트래킹 범위 (사양 §14-1 확정):
--   운영자 액션만 — approve / reject / revert_to_pending
--   본인 취소(cancel_application RPC, status='cancelled' 전이) 는 제외
--   → 이미 applications.cancelled_at 으로 다이제스트 §2 (응모 취소
--     섹션) 가 잡음. 중복 트래킹 방지.
--   본인 재응모는 마이그레이션 104 partial unique index 패턴으로
--   새 INSERT 행이 되므로 다이제스트 §1 (신청 접수 섹션) 이 잡음.
--
-- 액션 매핑 (supabase-expert 검토 반영):
--   pending     → approved   = approve
--   pending     → rejected   = reject
--   approved/rejected → pending = revert_to_pending
--   approved   → rejected    = reject   (UI 단계 생략 또는 직접 SQL 대비)
--   rejected   → approved    = approve  (UI 단계 생략 또는 직접 SQL 대비)
--   *          → cancelled   = 무시
--   cancelled  → pending     = 무시 (UI 없는 케이스, 추후 필요 시 확장)
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 테이블 존재 확인
--   SELECT to_regclass('public.application_events');
--   -- 기대값: application_events
--
--   -- [2] 트리거 등록 확인
--   SELECT tgname FROM pg_trigger
--    WHERE tgrelid = 'public.applications'::regclass
--      AND tgname = 'trg_application_status_event';
--   -- 기대값: 1 row
--
--   -- [3] 행 단위 보안 정책(RLS) 확인
--   SELECT polname, polcmd FROM pg_policy
--    WHERE polrelid = 'public.application_events'::regclass;
--   -- 기대값: application_events_select / r (SELECT)
--
--   -- [4] 기능 검증 — 개발서버에서 임의 pending 신청 1건 approved 로 UPDATE
--   --     UPDATE applications SET status='approved' WHERE id='<테스트>';
--   --     이후 아래 조회:
--   SELECT action, from_status, to_status, changed_by_name, created_at
--     FROM application_events
--    ORDER BY created_at DESC LIMIT 5;
--   -- 기대값: 신규 row 1개 (action='approve')
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_application_status_event ON public.applications;
--   DROP FUNCTION IF EXISTS public.record_application_status_event();
--   DROP TABLE IF EXISTS public.application_events;
-- ============================================================


-- ============================================================
-- 1. application_events 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.application_events (
  id              uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid        NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  action          text        NOT NULL CHECK (action IN ('approve', 'reject', 'revert_to_pending')),
  from_status     text        CHECK (from_status IN ('pending', 'approved', 'rejected', 'cancelled')),
  to_status       text        CHECK (to_status   IN ('pending', 'approved', 'rejected', 'cancelled')),
  changed_by      uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  changed_by_name text,
  memo            text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.application_events IS
  '신청 status 변경 audit (운영자 액션 한정). 트리거 trg_application_status_event 만 INSERT.';
COMMENT ON COLUMN public.application_events.action IS
  'approve / reject / revert_to_pending — 본인 취소·재응모는 미기록';
COMMENT ON COLUMN public.application_events.changed_by IS
  '변경 시점 auth.uid(). 관리자 삭제 시 SET NULL (changed_by_name 으로 추적).';
COMMENT ON COLUMN public.application_events.changed_by_name IS
  '변경 시점 관리자 이름 스냅샷. auth.users 삭제 후에도 audit 보존 목적.';


-- ============================================================
-- 2. 인덱스
-- ============================================================
-- 신청별 audit 타임라인 조회
CREATE INDEX IF NOT EXISTS idx_application_events_application_created
  ON public.application_events (application_id, created_at DESC);

-- 다이제스트 「어제 KST 윈도우」 범위 조회 (모든 액션 한 번에)
CREATE INDEX IF NOT EXISTS idx_application_events_created_at
  ON public.application_events (created_at DESC);


-- ============================================================
-- 3. 행 단위 보안 정책 (RLS) — SELECT 만 관리자, INSERT/UPDATE/DELETE 정책 없음
--    INSERT 는 SECURITY DEFINER 트리거만 가능
-- ============================================================
ALTER TABLE public.application_events ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS application_events_select ON public.application_events;
CREATE POLICY application_events_select
  ON public.application_events FOR SELECT
  USING (is_admin());


-- ============================================================
-- 4. 트리거 함수 — applications.status 변경 자동 기록
-- ============================================================
CREATE OR REPLACE FUNCTION public.record_application_status_event()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_action      text;
  v_admin_name  text;
BEGIN
  -- no-op (status 동일) 스킵
  IF OLD.status = NEW.status THEN
    RETURN NEW;
  END IF;

  -- 운영자 액션 매핑.
  -- cancelled 로의 전이는 cancel_application RPC 가 처리 (cancelled_at 별도 추적).
  -- cancelled → pending 은 현재 UI 없음 — 추후 필요 시 매핑 확장.
  v_action := CASE
    WHEN OLD.status = 'pending'                AND NEW.status = 'approved' THEN 'approve'
    WHEN OLD.status = 'pending'                AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status IN ('approved','rejected') AND NEW.status = 'pending'  THEN 'revert_to_pending'
    WHEN OLD.status = 'approved'               AND NEW.status = 'rejected' THEN 'reject'
    WHEN OLD.status = 'rejected'               AND NEW.status = 'approved' THEN 'approve'
    ELSE NULL
  END;

  -- 매핑 외 케이스 (cancelled 전이 등) 는 기록 안 함
  IF v_action IS NULL THEN
    RETURN NEW;
  END IF;

  -- 관리자 이름 스냅샷 (auth.uid() 가 admins 에 등록돼 있을 때만)
  SELECT a.name INTO v_admin_name
    FROM public.admins a
   WHERE a.auth_id = auth.uid();

  INSERT INTO public.application_events (
    application_id,
    action,
    from_status,
    to_status,
    changed_by,
    changed_by_name,
    memo
  ) VALUES (
    NEW.id,
    v_action,
    OLD.status,
    NEW.status,
    auth.uid(),
    v_admin_name,
    NULL
  );

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.record_application_status_event() IS
  '[131] applications.status 변경 시 application_events 자동 INSERT. SECURITY DEFINER — 트리거에서만 호출.';


DROP TRIGGER IF EXISTS trg_application_status_event ON public.applications;
CREATE TRIGGER trg_application_status_event
  AFTER UPDATE OF status ON public.applications
  FOR EACH ROW
  EXECUTE FUNCTION public.record_application_status_event();
