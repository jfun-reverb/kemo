-- ============================================================
-- 419_withdrawal_ops_alert_mail_failures.sql
-- 전수조사 2차(2026-09-02) 3-3(C-3, 중간) — 예정일 안내 메일 실패를 화면에 드러낸다
--   docs/research/2026-09-02-codebase-audit-findings.md
--   docs/specs/2026-09-02-audit-remediation-plan.md
--
-- 베이스: 372 의 public.get_withdrawal_ops_alert() (366 → 372 → 이 파일). 확인:
--   grep -ln "CREATE OR REPLACE FUNCTION public.get_withdrawal_ops_alert" supabase/migrations/*.sql
--
-- 무엇이 문제였나
--   회원 탈퇴 「예정일 안내 메일」(Edge Function notify-withdrawal-scheduled, 351 예약)은
--   status='scheduled' AND scheduled_mail_sent_at IS NULL 만 대상으로 매일 09:00 재시도한다.
--   예정일이 지나 done 이 되면 대상에서 빠져 **영영 안 나간다.** 실패 횟수 칸
--   scheduled_mail_attempt_count 는 350 이 「작업 14 화면이 보여줄 수 있다」고 적었는데
--   그 화면(366)이 그 칸을 읽지 않았다. 이 메일은 정산 알림을 없앤 뒤(343) 회원에게
--   닿는 **유일한 통지**라, 안 나간 것을 아무도 모르면 회원은 「내가 신청한 적 없는데」
--   (대행)·「언제 확정되는지」를 알 길이 없다.
--
-- 무엇을 하나 (범위 = 보이게 한다. 재발송은 만들지 않는다)
--   반환 jsonb 에 열쇠말 둘 추가 — mail_retrying(예정인데 아직 안 나감) / mail_lost(최근 30일, 못 받은 채 확정).
--   화면(admin-core.js 「탈퇴 처리 점검」 모달 + admin-influencers.js 탈퇴 카드)이 이 값만 그린다.
--   ⚠️ done 행에 뒤늦게 「5일 뒤 확정」 메일을 보내는 재발송은 만들지 않는다 — 문구가 사실과
--      다르다. 필요하면 별도 「확정 안내」 메일이 기획거리다.
--   ⚠️ 기획 검토(2026-09-07)가 바꾼 것 셋 — ①mail_lost 는 30일 한정(영구 경고 방지) ②mail_retrying 에
--      시간 기준 추가(파이프라인 정지도 잡히게) ③멈춘 확정과 겹치는 행 제외(중복 집계 방지).
--   ⚠️ 운영 적용 때 351 예약(withdrawal-scheduled-mail-daily)이 cron.job 에 실제로 있는지 함께 본다 —
--      없으면 이 감지는 「결함」이 아니라 「구조적으로 늘 발생」을 세게 된다.
--
-- CREATE OR REPLACE 만 — 366 의 권한(anon 회수·authenticated 부여)이 보존된다.
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
  v_msg_overdue           integer;   -- 372 추가
  v_msg_admin_locked      integer;   -- 372 추가
  v_stuck                 integer;
  v_stuck_admin_locked    integer;
  v_stuck_ids             uuid[];
  v_mail_retrying         integer;   -- 419 추가
  v_mail_lost             integer;   -- 419 추가
  v_today_jst             date;
BEGIN
  -- 권한 없으면 0 이 아니라 오류 — 364 [E]·[F] 와 같은 관행이고, 화면이
  -- 「밀린 것 없음」과 「볼 권한 없음」을 구분할 수 있어야 한다.
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  v_today_jst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  -- ── 밀린 파기 (364·368 의 함수를 그대로 재사용 — 판정을 두 벌로 만들지 않는다) ──
  v_media_overdue := public.count_overdue_withdrawal_media_purge();
  v_email_overdue := public.count_overdue_withdrawal_email_blocks();
  v_msg_overdue   := public.count_overdue_withdrawal_message_attachment_purge();   -- 372 추가

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

  -- ── 372 추가: 메시지 사진도 같은 구조 ──
  --   ⚠️ 368 의 목록 함수 조건과 **글자 그대로 같아야** 한다(겸직 조건만 반대).
  --      어긋나면 「목록엔 없는데 건수엔 있는」 값이 나와 원인을 못 찾는다.
  SELECT COUNT(*)::integer INTO v_msg_admin_locked
    FROM public.application_messages am
    JOIN public.applications a ON a.id = am.application_id
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = a.user_id
   WHERE am.sender_kind = 'influencer'
     AND am.attachments <> '[]'::jsonb
     AND am.attachments_purged_at IS NULL
     AND public._influencer_is_admin_account(a.user_id);

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

  -- ── 419 추가: 예정일 안내 메일(notify-withdrawal-scheduled) 실패 ──
  --   이 메일은 정산 알림을 없앤 뒤 회원에게 닿는 **유일한 통지**인데, 실패 횟수 칸
  --   (scheduled_mail_attempt_count, 350)을 읽는 화면이 0곳이었다(전수조사 2차 3-3).
  --   ⚠️ 판정은 여기 한 곳 — 화면은 이 값만 그린다.
  --
  --   ① 아직 안 나감(scheduled) — 둘 중 하나면 센다:
  --      (a) 한 번 이상 실패했다(attempt_count ≥ 1), 또는
  --      (b) 예정 상태가 된 날(scheduled_date − 5 — 세 경로 350·352·357 모두 today+5 로
  --          잡는다)의 09:30(일본 시각)이 지났는데도 발송 표시가 없다. 전이는 04:45, 발송은
  --          09:00 이라 그날 09:30 이 첫 판정 시점 — 날짜 단위(「전이 다음 날부터」)로 하면
  --          00:00~09:00 에 하루 이르게 뜨고, 그날 09:00 실패분은 하루 늦게 뜬다(검토 지적).
  --      🔴 (b) 가 핵심이다 — attempt_count 는 Edge Function 이 **행 하나를 처리하다
  --         실패했을 때만** 오른다. 예약이 안 돌거나·함수가 403/500 으로 시작조차 못 하면
  --         그 값은 영원히 0 이라, (a) 만으로는 가장 흔한 사고(파이프라인 정지)를 못 잡는다
  --         (기획 검토 지적). 시도 0회·전이 당일은 09:00 이 아직 안 온 정상 상태라 안 센다.
  --      ⚠️ 예정일이 이미 지난 행은 뺀다 — 그 행은 「멈춘 확정」(stuck_confirm)이 이미 세고
  --         있고, 같은 행을 두 줄에서 다른 조치로 안내하면 원인이 하나인데 셋으로 보인다.
  SELECT COUNT(*)::integer INTO v_mail_retrying
    FROM public.withdrawal_requests w
   WHERE w.status = 'scheduled'
     AND w.scheduled_mail_sent_at IS NULL
     AND w.scheduled_date IS NOT NULL
     AND w.scheduled_date >= v_today_jst
     AND (COALESCE(w.scheduled_mail_attempt_count, 0) >= 1
          OR (now() AT TIME ZONE 'Asia/Tokyo')
             >= ((w.scheduled_date - 5)::timestamp + interval '9 hours 30 minutes'));

  --   ② 못 받은 채 확정됨(done) — 대상 조회(status='scheduled')에서 빠져 메일 함수가
  --      다시 집지 않는다. **다시 보낼 방법이 없다**(확정 뒤에 「5일 뒤 확정된다」는 문구를
  --      보내는 것도 맞지 않다).
  --      🔴 최근 30일 확정분만 — 이 값은 누구도 0 으로 되돌릴 수 없어(재발송 없음), 기간을
  --         안 자르면 한 건만 생겨도 경고가 **영구히** 켜져 「원래 빨간 화면」이 된다
  --         (366 이 경계한 학습 효과). 30일이 지나면 저절로 빠진다 — 그동안 응대에 참고.
  --      ⚠️ 탈퇴 기능(345~359)과 이 메일(351)은 같은 날(2026-08-20) 운영에 들어갔다 —
  --         메일 기능 이전에 확정된 행은 없으므로 시점 조건은 두지 않는다.
  --      ⚠️ 회원 고유번호 목록은 주지 않는다 — 확정된 회원은 352 가 이름·이메일을 비워
  --         「회원 열기」로 가도 빈 행이다(stuck 목록은 확정 전이라 뜻이 있다).
  SELECT COUNT(*)::integer INTO v_mail_lost
    FROM public.withdrawal_requests w
   WHERE w.status = 'done'
     AND w.scheduled_date IS NOT NULL
     AND w.scheduled_mail_sent_at IS NULL
     AND w.completed_at >= now() - interval '30 days';

  RETURN jsonb_build_object(
    'media_overdue',                          v_media_overdue,
    'media_overdue_admin_locked',             v_media_admin_locked,
    'email_block_overdue',                    v_email_overdue,
    'message_attachment_overdue',             v_msg_overdue,        -- 372 추가
    'message_attachment_overdue_admin_locked', v_msg_admin_locked,  -- 372 추가
    'stuck_confirm',                          v_stuck,
    'stuck_confirm_admin_locked',             v_stuck_admin_locked,
    'stuck_influencer_ids',                   to_jsonb(v_stuck_ids),
    'mail_retrying',                          v_mail_retrying,      -- 419 추가
    'mail_lost',                              v_mail_lost           -- 419 추가
  );
END;
$fn$;

COMMENT ON FUNCTION public.get_withdrawal_ops_alert() IS
'관리자 「탈퇴 처리 점검」 경고용 집계(마이그레이션 366 → 372 → 419). '
'밀린 파기 3종(영수증·인증샷 / 재가입 차단 기록 / 메시지 사진) + 멈춘 확정 + '
'그중 관리자 겸직 몫 + [419] 예정일 안내 메일 2종(예정인데 아직 안 나감 — 실패 또는 예약 정지 / 최근 30일에 못 받은 채 확정됨). 권한 없으면 42501. '
'⚠️ 겸직 판정은 서버만 할 수 있다 — 확정되면 352 가 이메일을 바꿔 화면의 관리자 대조가 무력해진다. '
'⚠️ 예정일 비교는 `<`(오늘 제외) — 예약 실행이 04:45 라 오늘 건은 아직 정상이다. '
'⚠️ 재정의할 때 베이스는 **가장 번호가 큰 정의**(현재 419).';

-- 366·372 와 같은 권한 — 관리자 화면이 부른다(CREATE OR REPLACE 라 보존되지만 명시).
REVOKE ALL ON FUNCTION public.get_withdrawal_ops_alert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인
-- ============================================================
-- [V1] SQL 편집기 — 권한 오류가 정상(서비스 키라 is_admin() 이 false):
--   SELECT public.get_withdrawal_ops_alert();   → 42501 'forbidden'
-- [V2] 관리자로 가장한 되돌리기 트랜잭션(SQL 편집기):
--   begin; set local role authenticated;
--   select set_config('request.jwt.claims','{"sub":"<관리자 auth_id>","role":"authenticated"}',true);
--   select public.get_withdrawal_ops_alert(); rollback;
--   기대: 열쇠말 10개, mail_retrying·mail_lost 가 보인다.
-- [V3] 실제로 잡히는지 — DO 블록 안에서 시험 행을 심고 다시 호출한 뒤 RAISE EXCEPTION 으로
--   결과를 실어 낸다(전부 되돌아간다. 개발서버는 351 예약이 일부러 없어 시험 행을 남기면
--   5일 뒤 mail_lost 로 굳으므로 반드시 되돌린다):
--   done(어제 확정, 미발송) → lost +1 / scheduled(오늘+4, 시도 2회) → retrying +1 /
--   scheduled(오늘+5, 시도 0회) → 오늘 09:30(일본) 전이면 안 셈, 뒤면 retrying +1 /
--   scheduled(오늘+3, 시도 0회) → retrying +1(시간 기준) / scheduled(어제, 미발송) → retrying 에 안 셈(stuck 이 센다).
--
-- [V3 실측 블록 — 개발 2026-09-07] 기준 retrying=0 lost=0 stuck=0 → 시험 후(09:30 전 판정 기준) retrying=2 lost=1 stuck=1;
--   09:30 판정으로 바꾼 뒤 17시대 재실측 retrying=3(전이 당일 미발송도 잡힘) lost=1 stuck=1,
--   열쇠말 10개. 시험 행은 예외로 전부 되돌아갔다(재조회 0건). 아래를 그대로 붙여 넣으면 된다.
-- DO $$
-- DECLARE v_ids uuid[]; r0 jsonb; r1 jsonb;
-- BEGIN
--   PERFORM set_config('request.jwt.claims','{"sub":"<관리자 auth_id>","role":"authenticated"}',true);
--   r0 := public.get_withdrawal_ops_alert();
--   -- 활성 신청이 없는 회원 5명
--   SELECT array_agg(id) INTO v_ids FROM (SELECT i.id FROM public.influencers i WHERE i.is_audit=false AND NOT EXISTS (SELECT 1 FROM public.withdrawal_requests w WHERE w.influencer_id=i.id AND w.status IN ('pending_payout','scheduled')) ORDER BY i.created_at DESC LIMIT 5) s;
--   -- 1) 어제 확정, 미발송 → lost +1
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, completed_at, requested_by_kind, scheduled_mail_attempt_count) VALUES (v_ids[1], 'done', current_date - 1, now(), 'self', 1);
--   -- 2) 예정(오늘+4), 시도 2회 → retrying +1
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, requested_by_kind, scheduled_mail_attempt_count) VALUES (v_ids[2], 'scheduled', current_date + 4, 'self', 2);
--   -- 3) 예정(오늘+5 = 전이 당일), 시도 0회 → 안 셈
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, requested_by_kind, scheduled_mail_attempt_count) VALUES (v_ids[3], 'scheduled', current_date + 5, 'self', 0);
--   -- 4) 예정(오늘+3), 시도 0회 → 시간 기준으로 retrying +1
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, requested_by_kind, scheduled_mail_attempt_count) VALUES (v_ids[4], 'scheduled', current_date + 3, 'self', 0);
--   -- 5) 예정일 어제, 미발송 → retrying 에 안 셈(stuck 이 센다)
--   INSERT INTO public.withdrawal_requests (influencer_id, status, scheduled_date, requested_by_kind, scheduled_mail_attempt_count) VALUES (v_ids[5], 'scheduled', current_date - 1, 'self', 0);
--   r1 := public.get_withdrawal_ops_alert();
--   RAISE EXCEPTION '기준 retrying=% lost=% stuck=% ||| 시험 후 retrying=% lost=% stuck=% | 열쇠말수=% | 기대: retrying +2(일본 09:30 전) 또는 +3(뒤), lost +1, stuck +1',
--     r0->>'mail_retrying', r0->>'mail_lost', r0->>'stuck_confirm', r1->>'mail_retrying', r1->>'mail_lost', r1->>'stuck_confirm', (SELECT count(*) FROM jsonb_object_keys(r1));
-- END $$;
