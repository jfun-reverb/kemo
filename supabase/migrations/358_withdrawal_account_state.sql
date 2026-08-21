-- ============================================================
-- 358_withdrawal_account_state.sql
--
-- 회원 탈퇴 — 작업 8 「로그인 차단」 1/2 (판정 함수)
--   359 = 실제 차단 장치 (이 파일 뒤에)
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 8」·Q4
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md
--
-- ============================================================
-- ① 이 파일만 적용하면 동작이 바뀌나 — **데이터베이스는 안 바뀌지만, 화면은 바뀐다**
-- ============================================================
--   데이터베이스 쪽으로는 판정 함수 둘을 만들 뿐 차단 장치가 없다(그건 359).
--
--   🔴 **그런데 화면은 다르다.** 같은 묶음에서 나가는 `enforceWithdrawalLogout()` 이
--     앱 시작·로그인 시점에 이 함수를 이미 부른다. 즉 **이 파일을 적용하는 순간부터,
--     탈퇴가 확정된(`done`) 계정은 다음 화면 로드에서 강제 로그아웃된다.**
--     「데이터베이스만 보면 아무 일도 안 일어난다」가 「사용자에게 아무 일도 안 일어난다」는
--     뜻이 아니다.
--
--   → 적용 전에 **지금 `done` 인 계정이 있는지** 아래 사전 조회로 먼저 본다. 그리고
--     적용한 뒤 **실제 회원들에게 어떤 값이 나오는지 눈으로 본 다음** 359 로 쓰기 차단을
--     켠다. 둘을 합쳐 넣으면 판정이 틀렸을 때 그 순간 회원이 막힌다.
--
-- ============================================================
-- ② ★ 판정이 왜 **둘**인가 — 하나로 합치면 탈퇴 취소가 막힌다
-- ============================================================
--   이 저장소는 「같은 판단이 여러 곳」으로 반복해 사고를 냈고, 그래서 판정을 한 곳에
--   두는 것이 원칙이다. 그런데 여기서는 **목적이 다른 두 값**이 필요하다.
--
--   | | 무엇을 답하나 | 기준 |
--   |---|---|---|
--   | `login_blocked` | 이 사람을 **로그아웃시킬 것인가** | `done` 뿐 (좁다) |
--   | `write_blocked` | 이 사람의 **쓰기를 막을 것인가**   | `done` **또는 예정일 경과** (넓다) |
--
--   🔴 **합치면 안 되는 이유** — 예정일이 지났는데 예약 실행(새벽 04:45)이 아직 안 돈
--     구간이 있다. 그 회원을 로그아웃시키면 **탈퇴 취소 버튼에 닿지 못한다.** 취소는
--     회원에게 유리한 동작이라 절대 막으면 안 된다(349 에 아무 가드도 안 거는 이유와
--     같다). 그 구간의 회원은 **「로그인은 되는데 응모는 안 되는」 상태**가 맞다.
--
--   ⚠️ 두 값을 **서버가 함께 계산해 내려보낸다** — 화면이 「예정일이 오늘보다 이전인가」를
--     스스로 따지면 기기 시계로 갈린다. 353 의 설계 결정 ㄷ(「화면 모습은 서버가 정한다」)과
--     같은 형태다.
--
-- ============================================================
-- ③ ★ 부호는 `<=` 다 (`<` 가 아니다)
-- ============================================================
--   예약 실행(352)이 `scheduled_date <= 오늘(일본)` 에서 확정시킨다. 차단도 **문자 그대로
--   같은 부호**여야 한다.
--   `<` 로 쓰면 **예정일 당일**, 배치가 도는 새벽 04:45 이전 몇 시간 동안 응모가 열리고,
--   그 응모가 살아 있는 채로 같은 날 파기가 일어난다.
--
-- ============================================================
-- ④ `cancelled` 는 판정 대상이 아니다
-- ============================================================
--   탈퇴를 취소한 회원은 **즉시 정상으로 돌아온다** — 따로 풀어 주는 처리가 필요 없다.
--   ⚠️ 다만 `done` 행이 하나라도 있으면 잠긴다. 확정은 되돌릴 수 없기 때문이다
--     (한 사람에 여러 신청 행이 쌓이는 구조라 명시해 둔다).
--
-- ============================================================
-- ⑤ 353 의 `get_withdrawal_precheck()` 와 헷갈리지 말 것
-- ============================================================
--   저쪽은 「**지금 탈퇴를 신청할 수 있나**」(잠금·걸린 것)를 답한다.
--   이쪽은 「**이 계정이 지금 어떤 상태인가**」(이미 신청했고 어디까지 갔나)를 답한다.
--   목적이 달라 합치지 않았다.
--
-- ============================================================
-- ⑥ 되돌리기
-- ============================================================
--   DROP FUNCTION IF EXISTS public.get_my_withdrawal_state();
--   DROP FUNCTION IF EXISTS public._withdrawal_account_blocked(uuid);
--   ⚠️ 359 를 먼저 되돌린 뒤에 할 것 — 그쪽 차단 장치가 이 함수를 부른다.
-- ============================================================

-- 🔴 적용 전에 눈으로 볼 것 — 지금 이 판정에 걸리는 회원이 몇 명인가.
--   숫자가 예상과 다르면 **359 를 켜기 전에 멈춘다.**
--   (352 파일의 [PRE] 절과 같은 형태 — 켜기 전에 대상을 세는 습관)
DO $$
DECLARE v_done integer; v_overdue integer; v_admin_stuck integer;
BEGIN
  SELECT count(*) INTO v_done
    FROM public.withdrawal_requests WHERE status = 'done';

  SELECT count(*) INTO v_overdue
    FROM public.withdrawal_requests
   WHERE status = 'scheduled'
     AND scheduled_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- 관리자를 겸한 회원이 「예정일은 지났는데 확정이 롤백돼 갇힌」 상태인가.
  --   352 가 그런 계정의 파기를 거부하고, 실패하면 확정 전이가 통째로 되돌아간다.
  SELECT count(*) INTO v_admin_stuck
    FROM public.withdrawal_requests w
   WHERE w.status = 'scheduled'
     AND w.scheduled_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date
     AND EXISTS (SELECT 1 FROM public.admins a WHERE a.auth_id = w.influencer_id);

  RAISE NOTICE '[358] 확정된 회원 %명 · 예정일 지난 회원 %명 · 그중 관리자 겸직 %명',
    v_done, v_overdue, v_admin_stuck;
END $$;

BEGIN;

-- ============================================================
-- [A] _withdrawal_account_blocked(uuid) — 쓰기를 막을 것인가 (넓은 판정)
--
--   359 의 차단 장치 셋과 [B] 의 조회 함수가 **모두 이 함수 하나**를 부른다.
--
--   ⚠️ **아무에게도 실행 권한을 주지 않는다**(밑줄 접두어 관례 — `_withdrawal_unpaid_count`
--     (350)·`_withdrawal_lock_blockers`(353)와 같다). 화면은 [B] 를 통한다.
-- ============================================================
CREATE OR REPLACE FUNCTION public._withdrawal_account_blocked(
  p_influencer_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.withdrawal_requests w
     WHERE w.influencer_id = p_influencer_id
       AND (
         -- 확정됨 — 되돌릴 수 없다
         w.status = 'done'
         OR
         -- 예정일이 지났다 — 예약 실행이 하루 멈춰도 막힌다.
         --   ⚠️ 부호가 `<=` 인 것이 중요하다(위 헤더 ③).
         (w.status = 'scheduled'
          AND w.scheduled_date IS NOT NULL
          AND w.scheduled_date <= (now() AT TIME ZONE 'Asia/Tokyo')::date)
       )
  );
$fn$;

COMMENT ON FUNCTION public._withdrawal_account_blocked(uuid) IS
  '[358] 이 회원의 쓰기를 막아야 하나 — 탈퇴가 확정됐거나(done) 예정일이 지났으면 참. '
  '359 의 차단 장치 셋과 get_my_withdrawal_state() 가 모두 이 함수를 쓴다(판정 단일 소스). '
  '⚠️ 부호는 `<=` — 예약 실행(352)이 같은 부호로 확정시키므로 문자 그대로 같은 기준이어야 '
  '한다. `<` 로 쓰면 예정일 당일 새벽 배치 전까지 응모가 열린다. '
  '⚠️ 로그아웃 판정(login_blocked)과 **다른 값**이다 — 그쪽은 done 뿐이다. 합치면 예정일이 '
  '지났지만 확정 전인 회원이 로그아웃돼 **탈퇴 취소 버튼에 닿지 못한다**. '
  '⚠️ cancelled 는 대상이 아니다(취소하면 즉시 정상 복귀). '
  '내부 전용 — authenticated 에 GRANT 하지 않는다.';

REVOKE ALL ON FUNCTION public._withdrawal_account_blocked(uuid) FROM PUBLIC;

-- ============================================================
-- [B] get_my_withdrawal_state() — 화면이 부르는 본인 상태 조회
--
--   반환 jsonb:
--     { ok:true, has_request, status, scheduled_date,
--       login_blocked, write_blocked }
--   실패: { ok:false, reason:'not_authenticated' }
--
--   ⚠️ 인자가 없다 — **본인 것만**. 남의 상태는 관리자 화면이
--     get_withdrawal_precheck(353) 또는 withdrawal_requests 직접 조회로 본다.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_withdrawal_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_uid    uuid := auth.uid();
  v_req    public.withdrawal_requests%ROWTYPE;
  v_found  boolean := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'not_authenticated');
  END IF;

  -- 지금 기준이 되는 행 하나 — 확정된 것이 있으면 그것이 우선이고,
  -- 없으면 가장 최근 활성 신청.
  SELECT * INTO v_req
    FROM public.withdrawal_requests
   WHERE influencer_id = v_uid
     AND status IN ('done', 'pending_payout', 'scheduled')
   ORDER BY (status = 'done') DESC, requested_at DESC
   LIMIT 1;
  v_found := FOUND;

  RETURN jsonb_build_object(
    'ok',             true,
    'has_request',    v_found,
    'status',         CASE WHEN v_found THEN v_req.status         ELSE NULL END,
    'scheduled_date', CASE WHEN v_found THEN v_req.scheduled_date ELSE NULL END,
    -- 로그아웃 기준 — **확정된 경우만**(위 헤더 ②)
    'login_blocked',  COALESCE(v_found AND v_req.status = 'done', false),
    -- 쓰기 차단 기준 — 359 의 차단 장치와 **같은 함수**를 쓴다
    'write_blocked',  public._withdrawal_account_blocked(v_uid)
  );
END;
$fn$;

COMMENT ON FUNCTION public.get_my_withdrawal_state() IS
  '[358] 본인의 탈퇴 진행 상태. 화면이 이 결과만 보고 판단한다 — 「예정일이 오늘보다 '
  '이전인가」를 화면이 스스로 따지면 기기 시계로 갈린다. ★ login_blocked(확정만)와 '
  'write_blocked(확정 또는 예정일 경과)가 **다른 값인 것이 핵심**이다: 예정일이 지났지만 '
  '배치가 아직 안 돈 회원은 로그인은 되고 쓰기만 막혀야 **탈퇴 취소 권리를 뺏지 않는다**. '
  '⚠️ 353 의 get_withdrawal_precheck() 와 목적이 다르다 — 저쪽은 「신청할 수 있나」, '
  '이쪽은 「이미 신청했고 어디까지 갔나」.';

REVOKE ALL ON FUNCTION public.get_my_withdrawal_state() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_withdrawal_state() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
-- ============================================================
/*

-- ── SQL 편집기 ──────────────────────────────────────────────

-- [V0] 적용 시 뜬 NOTICE 를 확인했는가 — 「확정 N명 · 예정일 지난 N명 · 관리자 겸직 N명」
--   ⚠️ 관리자 겸직이 0이 아니면 359 를 켜기 전에 그 계정들을 어떻게 할지 정해야 한다
--     (359 는 is_admin() 통과 조항으로 구제하지만, 그 사람들이 왜 갇혔는지는 별개 문제다)

-- [V1] 넓은 판정이 실제로 도는가 (자료형 오류는 첫 호출에서만 드러난다)
SELECT public._withdrawal_account_blocked(
  (SELECT id FROM public.influencers WHERE is_audit = false LIMIT 1)
) AS "쓰기_막을까";
-- 기대: false (탈퇴 신청이 없는 평범한 회원)

-- [V2] ★ 실제로 걸리는 회원이 있으면 손으로 센 것과 맞는지 대조
SELECT w.influencer_id, w.status, w.scheduled_date,
       public._withdrawal_account_blocked(w.influencer_id) AS "판정"
  FROM public.withdrawal_requests w
 WHERE w.status IN ('done', 'scheduled')
 ORDER BY w.requested_at DESC
 LIMIT 20;
-- 기대: status='done' 은 전부 true · 'scheduled' 는 예정일이 오늘 이하일 때만 true

-- ── 로그인한 인플루언서 브라우저 콘솔 ────────────────────────

-- [V3] 탈퇴 신청이 없는 평범한 회원
--   await db.rpc('get_my_withdrawal_state', {})
--   기대: { ok:true, has_request:false, login_blocked:false, write_blocked:false }

-- [V4] ★ 예정일 경과 + 확정 전 구간 — **이 파일의 핵심**
--   시험 계정으로 탈퇴를 신청한 뒤(request_withdrawal), 서비스 키로
--   scheduled_date 를 어제로 바꾼다. 그리고 그 계정 콘솔에서:
--   await db.rpc('get_my_withdrawal_state', {})
--   기대: login_blocked:false · write_blocked:**true**  ← 두 값이 달라야 한다
--   🔴 둘이 같게 나오면 판정을 합쳐 버린 것이다 — 그대로 359 를 켜면 그 회원이
--      로그아웃돼 탈퇴 취소를 못 하게 된다
--   그리고 같은 계정에서 취소가 되는지도 확인:
--   await db.rpc('cancel_withdrawal', {})  → ok:true

-- [V5] 취소한 뒤 다시
--   기대: has_request:false · 두 값 모두 false (즉시 정상 복귀)

-- [V6] 시험 데이터 정리
--   DELETE FROM public.withdrawal_requests WHERE influencer_id = '<시험 계정>';

*/
