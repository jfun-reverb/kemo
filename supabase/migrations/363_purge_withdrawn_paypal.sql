-- ============================================================
-- 363_purge_withdrawn_paypal.sql
--
-- 회원 탈퇴 — 작업 13 「파기 ㄷ · 5년 · 페이팔」
--
-- 작업표 : docs/specs/2026-08-19-member-withdrawal-breakdown.md 「작업 13」
-- 사양서 : docs/specs/2026-08-18-member-withdrawal.md §4-7(파기 시점표) · §4-5(방침 개정)
--
-- ============================================================
-- ① 무엇을 하나
-- ============================================================
--   탈퇴가 **확정된 날부터 5년**이 지난 회원의 페이팔 이메일을 비운다.
--   **두 곳이다** — `influencers.paypal_email` 과 `settlements.paypal_email`.
--   ⚠️ 한쪽만 지우면 다른 쪽에 그대로 남는다(사양서 §4-7 이 굳이 「두 곳」이라 적은 이유).
--
--   왜 5년인가 — **세법상 지급 기록 보관 의무**다. 그래서 확정 즉시 지우는 18개 칸
--   (352)과 달리 이 항목만 따로 5년을 기다린다.
--
-- ============================================================
-- ② ★ 기준일은 「확정일」이지 「신청일」이 아니다
-- ============================================================
--   `withdrawal_requests.completed_at` 을 쓴다. 신청일(`requested_at`)로 세면
--   **받을 보수가 남아 대기가 길었던 회원은 몇 달 일찍 지워진다** — 세법상 보관
--   기간을 못 채운다.
--   ⚠️ 사양서 §4-5 도 방침 문구를 「탈퇴 후 5년」에서 **「탈퇴가 확정된 날부터 5년」**
--     으로 고치기로 했다(기간이 아니라 **기준일**을 고치는 것). 이 함수가 그 문구의 근거다.
--
-- ============================================================
-- ③ 행은 지우지 않는다 — 칸만 비운다
-- ============================================================
--   정산 행은 `settlement_events` 가 `ON DELETE RESTRICT` 라 **삭제할 수 없다**
--   (사양서 §4-7 ㅂ). 지급 금액·시각 같은 거래 기록은 그대로 두고 **개인을 알아볼 수
--   있는 페이팔 주소만** 비운다.
--
-- ============================================================
-- ④ 막히지 않는가 — 확인한 것
-- ============================================================
--   · `influencers` 수정 전 차단 장치(359)  → 예약 실행은 로그인 정보가 없어 **통과**
--   · 이메일 해시 담기 트리거(361)          → `OF email` 이라 페이팔 칸 수정에는 **안 돈다**
--   · `settlements` 에는 수정 전 차단 장치가 **없다**(전수 확인)
--
-- ============================================================
-- ⑤ 효과를 확인하는 데 5년이 걸리는 유일한 조각
-- ============================================================
--   지금 대상은 **0건**이다(서비스가 5년이 안 됐다). 그래서 「돌았다」를 눈으로 볼 수
--   없고, **시험 데이터로 확정일을 5년 전으로 돌려** 확인하는 수밖에 없다.
--   → 아래 검증 절차가 그 방법이다. **반드시 한 번은 돌려 볼 것** — 위반 기록 증빙
--     파일처럼 「만들어 놓고 안 도는」 선례가 이 저장소에 있다(마이그레이션 325).
--
-- ============================================================
-- ⑥ 되돌리기
-- ============================================================
--   SELECT cron.unschedule('withdrawal-paypal-retention-daily');
--   DROP FUNCTION IF EXISTS public.purge_withdrawn_paypal();
--   ⚠️ **이미 지워진 페이팔 주소는 되돌아오지 않는다.** 함수를 지워도 그렇다.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.purge_withdrawn_paypal()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  v_cutoff       timestamptz := now() - interval '5 years';
  v_inf_count    integer := 0;
  v_settle_count integer := 0;
BEGIN
  -- ① 회원 행의 페이팔 주소
  WITH target AS (
    -- ⚠️ **가장 최근 확정일**을 본다. `DISTINCT` + 행별 비교로 쓰면 「확정 행 중
    --   하나라도 5년이 지났으면」이 되어, 옛 확정이 있는 회원의 **최근 확정건까지
    --   함께 지워진다** — 세법상 보관 기간을 못 채운다(2026-08-20 검토 지적).
    --   ⚠️ 한 회원에게 확정 행이 둘 이상 생기는 것을 막는 장치가 **지금 없다**
    --     (활성 신청 유일 색인은 `done` 을 제외하고, 신청 함수도 확정 이력을 안 본다).
    SELECT w.influencer_id
      FROM public.withdrawal_requests w
     WHERE w.status = 'done'
       AND w.completed_at IS NOT NULL
     GROUP BY w.influencer_id
    HAVING MAX(w.completed_at) <= v_cutoff
  )
  UPDATE public.influencers i
     SET paypal_email = NULL
    FROM target t
   WHERE i.id = t.influencer_id
     AND i.paypal_email IS NOT NULL;   -- 이미 빈 것은 건드리지 않는다
  GET DIAGNOSTICS v_inf_count = ROW_COUNT;

  -- ② 정산 행의 페이팔 주소 — **여기를 빠뜨리면 그대로 남는다**
  --    ⚠️ 정산 행 자체는 지우지 않는다(settlement_events 가 ON DELETE RESTRICT).
  --      지급 금액·시각 같은 거래 기록은 세법상 계속 보관한다.
  WITH target AS (
    -- ⚠️ **가장 최근 확정일**을 본다. `DISTINCT` + 행별 비교로 쓰면 「확정 행 중
    --   하나라도 5년이 지났으면」이 되어, 옛 확정이 있는 회원의 **최근 확정건까지
    --   함께 지워진다** — 세법상 보관 기간을 못 채운다(2026-08-20 검토 지적).
    --   ⚠️ 한 회원에게 확정 행이 둘 이상 생기는 것을 막는 장치가 **지금 없다**
    --     (활성 신청 유일 색인은 `done` 을 제외하고, 신청 함수도 확정 이력을 안 본다).
    SELECT w.influencer_id
      FROM public.withdrawal_requests w
     WHERE w.status = 'done'
       AND w.completed_at IS NOT NULL
     GROUP BY w.influencer_id
    HAVING MAX(w.completed_at) <= v_cutoff
  )
  UPDATE public.settlements s
     SET paypal_email = NULL
    FROM target t
   WHERE s.influencer_id = t.influencer_id
     AND s.paypal_email IS NOT NULL;
  GET DIAGNOSTICS v_settle_count = ROW_COUNT;

  RAISE NOTICE '[363] 5년 지난 페이팔 주소 파기 — 회원 %건 · 정산 %건',
    v_inf_count, v_settle_count;

  RETURN jsonb_build_object(
    'ok',                true,
    'influencers_purged', v_inf_count,
    'settlements_purged', v_settle_count
  );
END;
$fn$;

COMMENT ON FUNCTION public.purge_withdrawn_paypal() IS
  '[363] 탈퇴가 **확정된 날부터 5년**이 지난 회원의 페이팔 이메일을 비운다(세법상 지급 '
  '기록 보관 기간). ⚠️ **두 곳이다** — influencers 와 settlements. 한쪽만 지우면 다른 '
  '쪽에 그대로 남는다. ⚠️ 기준일은 completed_at(확정일)이다 — 신청일로 세면 지급 대기가 '
  '길었던 회원이 몇 달 일찍 지워져 보관 기간을 못 채운다. ⚠️ **행은 지우지 않는다** — '
  '정산 행은 settlement_events 가 ON DELETE RESTRICT 라 삭제할 수 없고, 거래 기록은 '
  '계속 보관해야 한다. 지우는 것은 개인을 알아볼 수 있는 주소뿐이다.';

REVOKE ALL ON FUNCTION public.purge_withdrawn_paypal() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.purge_withdrawn_paypal() TO postgres;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 예약 등록 (트랜잭션 밖 — cron.schedule 은 자체 커밋)
--
--   한국·일본 05:00(협정 세계시 20:00). 새벽 04:00~04:45 구간은 이미 붐빈다
--   (04:00 위반기록 · 04:15 비밀번호찾기 · **04:30 세 개** · 04:45 탈퇴 상태 전이).
--   이 작업은 5년짜리라 급할 것이 없어 한산한 자리로 뺐다.
-- ============================================================
SELECT cron.unschedule(jobid)
  FROM cron.job
 WHERE jobname = 'withdrawal-paypal-retention-daily';

SELECT cron.schedule(
  'withdrawal-paypal-retention-daily',
  '0 20 * * *',
  $cron$ SELECT public.purge_withdrawn_paypal(); $cron$
);

-- ============================================================
-- 검증 (개발 데이터베이스 적용 후)
--
-- 🔴 **지금 대상은 0건이다**(서비스가 5년이 안 됐다). 그래서 「0건 처리됨」만 보고
--    끝내면 **이 함수가 실제로 도는지 영영 모른다** — 위반 기록 증빙 파일처럼
--    「만들어 놓고 안 도는」 선례가 있다(마이그레이션 325).
--    반드시 [V2] 까지 할 것.
-- ============================================================
/*

-- [V0] 예약이 걸렸나
SELECT jobname, schedule, active FROM cron.job
 WHERE jobname = 'withdrawal-paypal-retention-daily';
-- 기대: '0 20 * * *' 활성

-- [V1] 함수가 도는가 (대상 0건이어도 오류 없이 반환돼야 한다)
SELECT public.purge_withdrawn_paypal();
-- 기대: {"ok":true,"influencers_purged":0,"settlements_purged":0}

-- [V2] ★ 실제로 지워지는가 — 시험 데이터로 확인
--   ⚠️ **되돌릴 수 없다.** 시험 계정으로만, 그리고 아래 [V3] 로 원상 복구할 것.
--
--   (가) 확정된 시험 회원을 하나 고르고, 페이팔 주소가 들어 있는지 확인
--     SELECT w.influencer_id, w.completed_at, i.paypal_email
--       FROM public.withdrawal_requests w
--       JOIN public.influencers i ON i.id = w.influencer_id
--      WHERE w.status = 'done'
--      LIMIT 5;
--     ⚠️ 0행이면 확정된 회원이 아직 없다 — 352 검증에서 만든 시험 계정을 쓰거나,
--        먼저 시험 계정을 확정까지 굴린다
--
--   (나-0) ★ **원래 값을 먼저 적어 둔다**(덮어쓴 뒤에는 못 되찾는다)
--     SELECT i.paypal_email AS 회원_원래값,
--            (SELECT string_agg(DISTINCT s.paypal_email, ', ')
--               FROM public.settlements s WHERE s.influencer_id = i.id) AS 정산_원래값,
--            (SELECT string_agg(w.completed_at::text, ', ')
--               FROM public.withdrawal_requests w
--              WHERE w.influencer_id = i.id AND w.status = 'done') AS 확정일_원래값
--       FROM public.influencers i WHERE i.id = '<회원id>';
--
--   (나) 그 회원에게 페이팔 주소를 넣고 확정일을 5년 전으로 돌린다
--     UPDATE public.influencers  SET paypal_email = 'test-5y@example.com' WHERE id = '<회원id>';
--     UPDATE public.settlements  SET paypal_email = 'test-5y@example.com' WHERE influencer_id = '<회원id>';
--     UPDATE public.withdrawal_requests
--        SET completed_at = now() - interval '5 years 1 day'
--      WHERE influencer_id = '<회원id>' AND status = 'done';
--
--   (다) 돌린다
--     SELECT public.purge_withdrawn_paypal();
--     기대: influencers_purged 와 settlements_purged 가 **둘 다 1 이상**
--     🔴 정산 쪽이 0 이면 두 번째 문장이 안 도는 것이다 — 그대로 두면 5년 뒤에
--        페이팔 주소가 정산 행에만 조용히 남는다
--
--   (라) 눈으로 확인
--     SELECT i.paypal_email AS 회원, s.paypal_email AS 정산
--       FROM public.influencers i
--       LEFT JOIN public.settlements s ON s.influencer_id = i.id
--      WHERE i.id = '<회원id>';
--     기대: 둘 다 비어 있다

-- [V3] 시험 데이터 원상 복구
--   UPDATE public.withdrawal_requests
--      SET completed_at = <원래 값>
--    WHERE influencer_id = '<회원id>' AND status = 'done';
--   ⚠️ 지워진 페이팔 주소는 시험용이라 되살릴 필요가 없지만, 원래 주소가 있었다면
--     기록해 두고 되돌릴 것

-- [V3-b] ★ 확정 행이 둘일 때 — **최근 것 기준으로 판정되는가**
--   같은 회원에게 확정 행을 하나 더 만들고(하나는 5년 전, 하나는 최근),
--   페이팔 주소를 넣은 뒤 함수를 돌린다.
--   기대: **안 지워진다**(최근 확정일이 아직 5년이 안 됐으므로)
--   🔴 지워지면 「가장 오래된 것」 기준으로 도는 것이다 — 보관 기간을 어긴다

-- [V4] 아직 5년이 안 된 회원은 **안 지워지는가**
--   확정일이 최근인 회원의 페이팔 주소를 넣고 함수를 돌린 뒤, 그대로 남아 있는지 확인
--   🔴 여기서 지워지면 기준일 조건이 잘못된 것이다 — 세법상 보관 기간을 어긴다

*/
