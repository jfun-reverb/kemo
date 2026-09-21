-- ============================================================
-- 451_withdrawal_mail_alert_first_send_window.sql
--   사양서 `docs/specs/2026-09-18-withdrawal-mail-alert-false-positive.md` §3-3·§3-5②
--   「예정일 안내 메일이 아직 안 나감」 경고의 **첫 판정 시점**을 450 이 심은 `scheduled_at` 기준으로
--   바꾼다 — 그 행이 처음 발송 대상이 될 수 있었던 09:00 + 1시간.
--
--   🔴 **450 을 먼저 적용해야 한다** (§3-5) — 이 파일은 `withdrawal_requests.scheduled_at` 을 읽는다.
--   ⚠️ CREATE OR REPLACE 만 — 366 의 권한(anon 회수·authenticated 부여)이 보존된다.
--      베이스는 **가장 번호가 큰 정의인 419**(366 → 372 → 419 → 이 파일).
--   ⚠️ 바꾸는 것은 (b) 조건 하나뿐이다. (a)(`attempt_count >= 1`)와 나머지 계산 여덟 가지,
--      반환 열쇠말 10개는 419 에서 **그대로** 가져왔다.
--   ⚠️ 감지력은 그대로다 (§2-⑥) — 예약이 멈추거나 함수가 시작조차 못 하면 `attempt_count` 는
--      영원히 0 이라 (b) 가 유일한 수단인데, 새 기준도 그 경우 **반드시 참**이 된다. 오탐만 사라진다.
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
  --      (b) **그 행이 처음으로 발송 대상이 될 수 있었던 09:00 + 1시간**이 지났는데도 발송
  --          표시가 없다(451 — 사양서 2026-09-18-withdrawal-mail-alert-false-positive §3-3).
  --          🔴 **419 는 이 시점을 「예정이 된 날의 09:30」으로 쟀고 그것이 오탐을 냈다** —
  --             날짜만으로는 **09:00 이후에 예정이 된 행**을 가릴 수 없는데, 그 행은 그날
  --             배치가 이미 지나가 **다음 날 09:00** 이 첫 기회다. 2026-09-18 운영에서 3건이
  --             그렇게 떴고(어제 저녁 신청분) 그날 09:00 발송으로 저절로 사라졌다 — 메일도
  --             예약도 정상이었다. 정상 흐름에서 빨간 숫자가 뜨는 것은 366 이 경계한
  --             「원래 빨간 화면」 그 자체라 감지 자체가 무력해진다.
  --          ⚠️ 그래서 **450 이 「예정이 된 시각」(scheduled_at)을 기록**하고 여기서 그것을 쓴다.
  --             신청 시각(created_at)이 아니다 — 미지급 대기를 거친 건은 둘이 몇 달 차이 난다.
  --          ⚠️ 여유는 **1시간**(419 의 30분에서 넓힘, §2-③) — 09:00 발송이 끝나기 전에 재면
  --             매일 아침 잠깐 오탐이 뜬다. 회원이 늘면 발송이 길어진다.
  --          ⚠️ `scheduled_at` 이 NULL 인 옛 행(450 이전)은 **옛 식으로 떨어뜨린다**(§2-②) —
  --             「안 센다」로 하면 그 사이에 진짜 실패한 옛 행을 놓친다.
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
          OR (now() AT TIME ZONE 'Asia/Tokyo') >= (
               CASE
                 -- 450 이후 행 — 예정이 된 그 시각 뒤 **처음 오는 09:00** 이 첫 발송 기회다.
                 --   ⚠️ 초까지 본다(§2-④) — 09:00:01 은 그날 배치가 이미 대상을 뽑은 뒤라
                 --      「그날」로 묶으면 하루 이르게 센다.
                 WHEN w.scheduled_at IS NOT NULL THEN
                   CASE
                     WHEN (w.scheduled_at AT TIME ZONE 'Asia/Tokyo')::time <= time '09:00:00'
                       THEN ((w.scheduled_at AT TIME ZONE 'Asia/Tokyo')::date)::timestamp
                            + interval '9 hours'
                     ELSE ((w.scheduled_at AT TIME ZONE 'Asia/Tokyo')::date + 1)::timestamp
                          + interval '9 hours'
                   END + interval '1 hour'          -- 여유 1시간 → 10:00 (§2-③)
                 -- 450 이전 행 — 그 시각을 아무 데서도 알 수 없다. 옛 식 그대로 둔다(§2-②).
                 --   「안 센다」로 하면 그 사이에 진짜 실패한 옛 행을 놓친다.
                 ELSE ((w.scheduled_date - 5)::timestamp + interval '9 hours 30 minutes')
               END));

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
'관리자 「탈퇴 처리 점검」 경고용 집계(마이그레이션 366 → 372 → 419 → 451). '
'밀린 파기 3종(영수증·인증샷 / 재가입 차단 기록 / 메시지 사진) + 멈춘 확정 + 그중 관리자 겸직 몫 + '
'예정일 안내 메일 2종. 권한 없으면 42501. '
'⚠️ 겸직 판정은 서버만 할 수 있다 — 확정되면 352 가 이메일을 바꿔 화면의 관리자 대조가 무력해진다. '
'⚠️ 예정일 비교는 `<`(오늘 제외) — 예약 실행이 04:45 라 오늘 건은 아직 정상이다. '
'⚠️ [451] 메일 「아직 안 나감」의 첫 판정 시점은 **`scheduled_at` 뒤 처음 오는 09:00 + 1시간**이다. '
'`scheduled_at` 이 NULL 인 450 이전 행만 옛 식(전이일 09:30). '
'⚠️ 재정의할 때 베이스는 **가장 번호가 큰 정의**(현재 451).';

-- 366·372·419 와 같은 권한 — 관리자 화면이 부른다(CREATE OR REPLACE 라 보존되지만 명시).
REVOKE ALL ON FUNCTION public.get_withdrawal_ops_alert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인 (사양서 §4)
-- ============================================================
-- [V1] 경고 값 — 관리자 로그인 브라우저에서(SQL 편집기는 is_admin() 을 재현 못 한다)
--   await db.rpc('get_withdrawal_ops_alert')
--   기대: mail_retrying = 0 (2026-09-18 기준 예정 건은 전부 발송 완료)
--
-- [V2] 🔴 오탐이 실제로 사라지는지 — **두 판정의 「첫 판정 시각」을 나란히** 뽑아 비교한다.
--   ⚠️ 「지금 셀까」를 묻지 않는다 — 그 답은 실행 시각에 따라 바뀌어, 늦게 돌린 사람이
--      「고침이 실패했다」고 오판한다. 기준 시각끼리 비교하면 시각과 무관하다.
--   SELECT
--     d.label,
--     ((d.scheduled_date - 5)::timestamp + interval '9 hours 30 minutes')      AS "419 기준(옛 판)",
--     (CASE WHEN d.scheduled_jst::time <= time '09:00:00'
--             THEN (d.scheduled_jst::date)::timestamp     + interval '9 hours'
--           ELSE (d.scheduled_jst::date + 1)::timestamp   + interval '9 hours'
--      END + interval '1 hour')                                                AS "451 기준(새 판)"
--   FROM (VALUES
--     ('저녁에 예정이 됨(오탐이던 경우)', date '2026-09-22', timestamp '2026-09-17 20:48'),
--     ('아침에 예정이 됨',                date '2026-09-23', timestamp '2026-09-18 07:39'),
--     ('04:45 배치 전이',                 date '2026-09-25', timestamp '2026-09-20 04:45')
--   ) AS d(label, scheduled_date, scheduled_jst);
--
--   기대(실행 시각과 무관):
--     · 저녁    → 419 는 09-17 09:30 / 451 은 **09-18 10:00** (하루 뒤 — 오탐이 사라진다)
--     · 아침    → 419 는 09-18 09:30 / 451 은 09-18 10:00 (30분 차이뿐)
--     · 배치    → 419 는 09-20 09:30 / 451 은 09-20 10:00 (30분 차이뿐)
--
-- [V3] 옛 행(scheduled_at IS NULL)이 옛 식으로 떨어지는가 — 450 [V1] 에서 본 그 행들이다.
--   지금 예정 6건은 전부 발송 완료라 판정 대상이 아니므로 값은 0 그대로여야 한다.
--
-- [V4] 되돌리기 — 419 파일을 그대로 다시 실행하면 옛 판정으로 돌아간다(권한 보존).
--   그때 450 의 칸은 남겨 둬도 무해하다(아무도 안 읽는다).
