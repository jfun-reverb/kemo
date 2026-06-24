-- ============================================================
-- 198_advance_to_orient_sheet_sent.sql
-- 2026-06-24
--
-- 목적:
--   오리엔시트 발급 메일이 발송되면, 연결된 광고주 신청의 진행 단계를
--   'orient_sheet_sent'(오리엔시트 발송됨)로 자동 전진시킨다.
--   메일 발송을 담당하는 Edge Function(notify-orient-sheet)이
--   service_role 로 이 함수를 호출한다.
--
-- 안전장치 2종 (사용자 확정, 2026-06-24):
--   ① 역행 방지 — 현재 단계가 orient_sheet_sent 보다 '이전'(5단계)일 때만 전진.
--      이미 그 이상(일정 공유·캠페인 등록 등)이면 건드리지 않는다(재발송 시 단계 역행 방지).
--   ② 신청 연결 건만 — application_id 가 NULL 이면(비-서베이 발급) 전이 대상 아님.
--
-- 사양서:
--   docs/specs/2026-06-18-brand-self-orient-sheet.md §14 (발급 메일·상태 전이)
--
-- 전제:
--   076_brand_application_status_kakao_room.sql — status CHECK 10단계 확정본
--     (new → reviewing → quoted → paid → kakao_room_created →
--      orient_sheet_sent → schedule_sent → campaign_registered → done / rejected)
--   079 — trg_brand_app_history (status 변경 시 brand_application_history 자동 INSERT)
--   trg_brand_app_touch — BEFORE UPDATE 로 version+1·updated_at=now() 자동 처리
--
-- 설계 결정 (reverb-supabase-expert):
--   - FOR UPDATE 행 잠금으로 동시 호출 방어. version 낙관적 락은 체크하지 않는다
--     (단계 전이는 필드 동시수정 충돌과 다른 시나리오 — BEFORE UPDATE 트리거가
--      version 을 자동 증가시켜 UI 낙관적 락 상태는 자연 무효화).
--   - 조건부 전이라 멱등: 같은 발급에 두 번 호출돼도 두 번째는 이미 orient_sheet_sent
--     이상이라 already_advanced 반환(단계 안 꼬임).
--   - 감사 행위자(changed_by) 는 service_role 호출이라 auth.uid()=NULL → "시스템 자동 전이"
--     로 기록(의도된 동작).
--
-- 권한:
--   REVOKE PUBLIC — anon·authenticated 직접 호출 차단. service_role(Edge Function)만 실행.
--
-- 적용 순서:
--   … → 197 → 이 파일(198)
--
-- 롤백:
--   DROP FUNCTION IF EXISTS public.advance_to_orient_sheet_sent(uuid);
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.advance_to_orient_sheet_sent(
  p_application_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status text;
BEGIN
  -- ── 안전장치 ②: 신청 연결 건만 ────────────────────────────────────────
  IF p_application_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_application');
  END IF;

  -- ── 행 잠금 후 현재 단계 조회(동시 호출 방어) ────────────────────────
  SELECT status
    INTO v_status
    FROM public.brand_applications
   WHERE id = p_application_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'reason', 'no_application');
  END IF;

  -- ── 안전장치 ①: 역행 방지 — orient_sheet_sent 이전 단계 5개일 때만 전진 ──
  --   (이미 orient_sheet_sent·schedule_sent·campaign_registered·done·rejected 면 그대로 둠)
  IF v_status NOT IN ('new', 'reviewing', 'quoted', 'paid', 'kakao_room_created') THEN
    RETURN jsonb_build_object(
      'success', false,
      'reason',  'already_advanced',
      'current', v_status
    );
  END IF;

  -- ── 전진 (version·updated_at 은 BEFORE UPDATE 트리거가 자동 처리,
  --     status 변경 audit 는 trg_brand_app_history 가 자동 INSERT) ──────────
  UPDATE public.brand_applications
     SET status = 'orient_sheet_sent'
   WHERE id = p_application_id;

  RETURN jsonb_build_object(
    'success', true,
    'from',    v_status,
    'to',      'orient_sheet_sent'
  );
END;
$$;

-- 기본 PUBLIC 실행 권한 회수 — service_role(Edge Function)만 호출.
REVOKE EXECUTE ON FUNCTION public.advance_to_orient_sheet_sent(uuid) FROM PUBLIC;

COMMENT ON FUNCTION public.advance_to_orient_sheet_sent(uuid) IS
  '[198] 오리엔시트 발급 메일 발송 시 연결 광고주 신청을 orient_sheet_sent 로 자동 전진. '
  '안전장치: ①역행 방지(이전 5단계일 때만) ②신청 연결 건만(NULL=no_application). '
  'FOR UPDATE 행 잠금·멱등(already_advanced). SECURITY DEFINER + search_path 고정. '
  'service_role 전용(REVOKE PUBLIC).';

-- PostgREST 스키마 캐시 재로드
NOTIFY pgrst, 'reload schema';

COMMIT;
