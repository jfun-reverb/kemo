-- ============================================================
-- 2026-08-03-dev-reset-event-checkin.sql
-- 【개발 데이터베이스 전용】 입장 확인 기록 초기화 — 반복 테스트용
--
-- ⚠️⚠️ **운영 데이터베이스에는 절대 적용하지 않는다.** ⚠️⚠️
--   그래서 마이그레이션(supabase/migrations/)이 아니라 패치(supabase/patches/)에 둔다.
--   마이그레이션 체인에 넣으면 운영 적용 시 함께 딸려 들어가고, 그러면 행사 당일
--   누군가 실수로 눌러 **실제 방문객의 입장 기록을 전부 지울 수 있다.**
--
-- 왜 필요한가:
--   현장 확인 화면(event-scan.html)을 테스트하려면 같은 티켓을 여러 번 스캔해 봐야 하는데,
--   한 번 입장 처리되면 그 뒤로는 계속 「이미 입장 완료」만 나온다. 티켓을 새로 만들려면
--   예약을 취소하고 다시 잡아야 해서 반복 테스트가 매우 번거롭다.
--
-- 이중 안전장치:
--   ① 이 함수는 **개발 데이터베이스에만 존재**한다(운영에 적용 안 함) — 진짜 방어선
--   ② 화면 버튼은 개발 도메인일 때만 그린다(event-scan.html) — 표시 제어일 뿐
--
-- 되돌리는 값: entered_at · entered_by · entered_by_name · scan_count
--   예약 자체(status·waitlist_position)는 건드리지 않는다 — 입장 기록만 지운다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public.dev_reset_event_checkin(
  p_campaign_id uuid DEFAULT NULL,   -- NULL 이면 모든 행사
  p_slot_date   date DEFAULT NULL    -- NULL 이면 모든 날짜
) RETURNS integer
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_reset integer;
BEGIN
  -- 관리자만. 화면 버튼이 개발 도메인에서만 보이더라도 함수는 스스로 지킨다.
  IF auth.uid() IS NULL OR NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied' USING ERRCODE = '42501';
  END IF;

  UPDATE public.event_tickets t
     SET entered_at      = NULL,
         entered_by      = NULL,
         entered_by_name = NULL,
         scan_count      = 0,
         version         = t.version + 1
    FROM public.event_slots s
   WHERE s.id = t.slot_id
     AND t.entered_at IS NOT NULL
     AND (p_campaign_id IS NULL OR t.campaign_id = p_campaign_id)
     AND (p_slot_date   IS NULL OR s.slot_date   = p_slot_date);

  GET DIAGNOSTICS v_reset = ROW_COUNT;
  RETURN v_reset;
END;
$$;

COMMENT ON FUNCTION public.dev_reset_event_checkin(uuid, date) IS
  '【개발 전용】 입장 확인 기록(entered_at·entered_by·scan_count)을 되돌린다. 반복 테스트용. '
  '운영 데이터베이스에는 만들지 않는다 — 실제 방문객 입장 기록이 지워질 수 있다.';

REVOKE ALL ON FUNCTION public.dev_reset_event_checkin(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.dev_reset_event_checkin(uuid, date) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- 1) 함수가 생겼는지
-- SELECT proname FROM pg_proc
--  WHERE pronamespace='public'::regnamespace AND proname='dev_reset_event_checkin';
--
-- 2) ⚠️ 운영 데이터베이스에서 아래를 실행하면 **0건**이어야 한다(= 함수가 없어야 정상)
--    SELECT count(*) FROM pg_proc
--     WHERE pronamespace='public'::regnamespace AND proname='dev_reset_event_checkin';
--
-- ============================================================
-- 롤백 (테스트가 끝나면 개발 데이터베이스에서도 지우는 것을 권한다)
-- ============================================================
-- DROP FUNCTION IF EXISTS public.dev_reset_event_checkin(uuid, date);
