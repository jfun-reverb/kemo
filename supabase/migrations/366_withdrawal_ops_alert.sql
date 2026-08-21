-- ============================================================
-- 366_withdrawal_ops_alert.sql
-- 2026-08-20
--
-- 목적:
--   관리자 화면의 「탈퇴 처리 점검」 경고가 쓸 값을 **서버가 한 번에** 센다.
--   밀린 파기 건수 + 예정일이 지났는데 확정되지 않은 탈퇴 + 그중 관리자
--   계정을 겸해 막힌 몫.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 14
--
-- ============================================================
-- 🔴 왜 화면이 아니라 서버가 세는가 — 화면은 원리적으로 못 센다
-- ============================================================
--   「밀린 파기가 0 으로 안 내려가는」 원인은 **확정됐는데 관리자 계정을
--   겸한 회원**이다(352 가 그런 회원의 파기를 거부하므로 확정 전이 자체가
--   매일 롤백된다).
--
--   그런데 화면은 관리자를 **이메일로** 판별한다(`_adminEmails`). 확정되는
--   순간 352 가 그 이메일을 자리표시 주소로 바꾸므로, **대조할 값이
--   사라진다.** 서버는 `admins.auth_id = influencers.id` 로 보기 때문에
--   그 영향을 안 받는다.
--
--   → 화면이 흉내 내면 「원인 모를 숫자가 영영 떠 있는」 상태가 된다.
--     그건 이 경고가 막으려던 바로 그 상황이다.
--
-- ============================================================
-- ⚠️ 감지 대상은 「관리자 겸직」이 아니라 「멈춘 확정」이다 (상위집합)
-- ============================================================
--   작업표는 ③을 「관리자 겸직 파기 실패」라고 적었지만, 확정이 멈추는
--   원인은 셋이다:
--     ① 관리자 계정 겸직 (352 가 거부)
--     ② 예상 못 한 오류 (파기 실패 → 확정 전이째 롤백)
--     ③ **예약 실행 자체가 멈춤**
--   셋 다 증상이 같다 — `status='scheduled'` 인데 예정일이 지났다.
--   겸직만 감지하면 **③(가장 큰 사고)을 못 본다.** 이 저장소에는 위반 증빙
--   파기가 「만들어 놓고 안 도는」 채로 남은 전례가 있다(마이그레이션 325).
--
--   → `stuck_confirm` 으로 전부 세고, 그중 겸직 몫을 따로 분리해 화면이
--     「권한 해제하면 풀린다」와 「개발 담당자에게 알려라」를 구분해 안내한다.
--
-- ============================================================
-- ⚠️ 날짜 판정을 서버가 한다
-- ============================================================
--   화면이 `scheduled_date <= 오늘` 을 다시 계산하면 **관리자 PC 시계**에
--   의존한다. 방문자수 차트(332)에서 자정 직후 시계가 몇 분만 느려도 그릴
--   칸이 0개가 되던 함정을 실제로 겪었다.
--
--   ⚠️ **부호는 `<` 이고 `<=` 가 아니다.** 예약 실행(350)이 한국·일본 04:45 에
--   도므로, **오늘이 예정일인 건은 00:00~04:45 사이엔 아직 정상**이다.
--   `<=` 로 하면 매일 새벽 오탐이 뜨고, 그러면 「원래 빨간 화면」이 된다.
--
-- 되돌리기:
--   DROP FUNCTION IF EXISTS public.get_withdrawal_ops_alert();
--   기존 함수를 하나도 재정의하지 않으므로 이것으로 완전히 되돌아간다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.get_withdrawal_ops_alert()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_media_overdue         integer;
  v_media_admin_locked    integer;
  v_email_overdue         integer;
  v_stuck                 integer;
  v_stuck_admin_locked    integer;
  v_stuck_ids             uuid[];
  v_today_jst             date;
BEGIN
  -- 권한 없으면 0 이 아니라 오류 — 364 [E]·[F] 와 같은 관행이고, 화면이
  -- 「밀린 것 없음」과 「볼 권한 없음」을 구분할 수 있어야 한다.
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_today_jst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- ── 밀린 파기 (364 의 함수를 그대로 재사용 — 판정을 두 벌로 만들지 않는다) ──
  v_media_overdue := public.count_overdue_withdrawal_media_purge();
  v_email_overdue := public.count_overdue_withdrawal_email_blocks();

  -- 그중 관리자 계정을 겸해 자동으로 안 지워지는 몫.
  -- ⚠️ 364 [C] 의 목록 함수는 이런 회원을 **제외**하고, [E] 의 건수는
  --    **포함**한다(의도 — 눈에 보이게). 그 차이가 여기서 설명된다.
  SELECT COUNT(*)::integer INTO v_media_admin_locked
    FROM public.deliverables d
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = d.user_id
   WHERE d.kind IN ('receipt', 'review_image')
     AND d.receipt_url IS NOT NULL
     AND d.media_purged_at IS NULL
     AND public._influencer_is_admin_account(d.user_id);

  -- ── 멈춘 확정 ──
  SELECT COUNT(*)::integer INTO v_stuck
    FROM public.withdrawal_requests w
   WHERE w.status = 'scheduled'
     AND w.scheduled_date IS NOT NULL
     AND w.scheduled_date < v_today_jst;

  SELECT COUNT(*)::integer INTO v_stuck_admin_locked
    FROM public.withdrawal_requests w
   WHERE w.status = 'scheduled'
     AND w.scheduled_date IS NOT NULL
     AND w.scheduled_date < v_today_jst
     AND public._influencer_is_admin_account(w.influencer_id);

  -- 화면이 「회원 열기」 버튼을 그릴 수 있게 **고유번호만** 준다.
  -- ⚠️ 이름·이메일은 주지 않는다 — 그 회원들은 개인정보가 이미 파기됐거나
  --    파기 직전이다. 상세 화면이 필요한 값을 자기 권한으로 다시 조회한다.
  -- ⚠️ 상한 50 — 이 값이 수백이면 개별 조치가 아니라 예약 실행 점검이 답이라
  --    목록을 다 줄 이유가 없다. 화면이 「외 N명」으로 알린다.
  SELECT COALESCE(array_agg(x.influencer_id), '{}')::uuid[] INTO v_stuck_ids
    FROM (
      SELECT w.influencer_id
        FROM public.withdrawal_requests w
       WHERE w.status = 'scheduled'
         AND w.scheduled_date IS NOT NULL
         AND w.scheduled_date < v_today_jst
       ORDER BY w.scheduled_date
       LIMIT 50
    ) x;

  RETURN jsonb_build_object(
    'media_overdue',              v_media_overdue,
    'media_overdue_admin_locked', v_media_admin_locked,
    'email_block_overdue',        v_email_overdue,
    'stuck_confirm',              v_stuck,
    'stuck_confirm_admin_locked', v_stuck_admin_locked,
    'stuck_influencer_ids',       to_jsonb(v_stuck_ids)
  );
END;
$fn$;

COMMENT ON FUNCTION public.get_withdrawal_ops_alert() IS
'관리자 「탈퇴 처리 점검」 경고용 집계(마이그레이션 366, 작업 14). '
'밀린 파기 2종 + 멈춘 확정 + 그중 관리자 겸직 몫. 권한 없으면 42501. '
'⚠️ 겸직 판정은 서버만 할 수 있다 — 확정되면 352 가 이메일을 바꿔 화면의 관리자 대조가 무력해진다. '
'⚠️ 예정일 비교는 `<`(오늘 제외) — 예약 실행이 04:45 라 오늘 건은 아직 정상이다.';

REVOKE ALL ON FUNCTION public.get_withdrawal_ops_alert() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인
-- (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — 신규 함수는 적용이 성공하고
--  **첫 호출에서** 자료형·컬럼 오류가 터진다. `.claude/rules/supabase.md`)
-- ============================================================
--
-- [V1] SQL 편집기에서 호출 — ⚠️ **권한 오류가 나는 것이 정상이다**
--      (서비스 키라 is_admin() 이 false).
--   SELECT public.get_withdrawal_ops_alert();
--   기대: **42501 'forbidden'**.
--   → 여기서 값이 나오면 권한 검사가 안 걸린 것이므로 확인할 것.
--
-- [V2] ★ 관리자 브라우저 콘솔(로그인 상태)에서 — 여기가 진짜 첫 호출이다:
--   await db.rpc('get_withdrawal_ops_alert')
--   기대: {data: {media_overdue: 0, media_overdue_admin_locked: 0,
--                 email_block_overdue: 0, stuck_confirm: 0,
--                 stuck_confirm_admin_locked: 0, stuck_influencer_ids: []},
--          error: null}
--   → 전부 0 이고 배열이 비어 있어야 정상이다(아직 확정된 탈퇴가 없다).
--
-- [V3] 「멈춘 확정」이 실제로 잡히는지 (개발서버, 시험 계정):
--   1) 시험 신청을 하나 만들고 예정일을 어제로:
--        INSERT INTO public.withdrawal_requests
--          (influencer_id, status, requested_by_kind, scheduled_date)
--        VALUES ('<시험 인플루언서 id>', 'scheduled', 'self',
--                (now() AT TIME ZONE 'Asia/Tokyo')::date - 1);
--   2) [V2] 를 다시 호출 → stuck_confirm=1, stuck_influencer_ids 에 그 id.
--   3) ★ **오늘 날짜로 바꿔** 다시 호출:
--        UPDATE public.withdrawal_requests SET scheduled_date =
--          (now() AT TIME ZONE 'Asia/Tokyo')::date WHERE …;
--      기대: **stuck_confirm=0** — 오늘 건은 예약 실행 전이라 정상이다.
--      (이걸 확인해야 매일 새벽 오탐이 안 난다는 것이 증명된다)
--   4) 정리: DELETE FROM public.withdrawal_requests WHERE …;
--
-- [V4] 겸직 분리가 되는지:
--   [V3]-1 상태에서 그 시험 계정을 관리자로 만든 뒤 [V2] 호출.
--   기대: stuck_confirm=1 **이면서** stuck_confirm_admin_locked=1.
--   → 화면이 「권한 해제하면 다음 새벽에 풀린다」로 안내할 근거다.
--   확인 뒤 관리자 권한 해제 + 시험 행 삭제.
-- ============================================================
