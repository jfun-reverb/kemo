-- ============================================================
-- 482_withdrawal_purge_include_general_inquiry.sql
-- 일반 문의 창구 — 데이터 모델 ⑦ 탈퇴 첨부 파기 목록·건수 + 탈퇴 운영 경고가 응모 없는 행도 잡게 한다
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-5 ⑦ · §12 ④
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 3 (마이그 ⑦)
-- 선행: 475(칸)
--
-- 왜: 세 곳이 application_messages 를 applications 와 **안쪽 결합**해서, 응모 없는 행(일반 문의)은
--   **오류도 건수도 없이 조용히 빠진다** — 탈퇴 확정 6개월 뒤에도 회원이 보낸 사진이 저장소에 남는다.
--   파기 서버 함수(purge-withdrawal-message-attachments)는 경로 규칙을 보지 않고 목록 함수가 준 경로를 그대로
--   지우므로, **고칠 것은 조회뿐**이다(서버 함수·예약 등록·mark 함수는 무변경).
--
-- 베이스(정의 파일을 갈라 확인 — grep 으로 이름이 나오는 파일: 368·371·372·419·451)
--   list_pending_withdrawal_message_attachment_purge  → 368 (유일한 정의. 371 은 예약 등록, 372·419·451 은 경고 함수)
--   count_overdue_withdrawal_message_attachment_purge  → 368 (유일한 정의)
--   get_withdrawal_ops_alert                           → 451 (366 → 372 → 419 → 451. 마지막 정의)
--   ⚠️ 사양서 §5-2 표기 「탈퇴 첨부 파기 목록·건수 함수」 이름은 저장소에서 `message_attachment`(단수)이다.
--   본문은 각 베이스를 통째로 복사하고 **결합 방식 한 가지만** 바꿨다:
--       INNER JOIN applications a ON a.id = am.application_id  +  due.influencer_id = a.user_id
--     → LEFT  JOIN applications a ON a.id = am.application_id  +  due.influencer_id = COALESCE(am.influencer_id, a.user_id)
--     (관리자 겸직 판정도 같은 COALESCE 값으로). 시그니처·반환 모양·권한·나머지 조항은 글자 그대로 같다.
--   451 은 「셋이 글자 그대로 같은 판정」이어야 한다고 적고 있다 — 세 곳 모두 같은 식이다.
--   CREATE OR REPLACE 라 권한이 보존된다(368: list=postgres·service_role 전용 / count·alert=authenticated).
--   경고 함수의 REVOKE·GRANT 세 줄만 451 처럼 다시 적었다(같은 상태 — 무해).
--
-- ── 적용 전후 확인 ──
--   [P1] 🔴 적용 **전에** 응모 있는 행의 대상 건수를 적어 둔다(SQL 편집기 가능 — 표 직접 조회):
--     SELECT count(*) FROM public.application_messages am
--       JOIN public.applications a ON a.id = am.application_id
--       JOIN public._withdrawal_media_purge_due_ids() due ON due.influencer_id = a.user_id
--      WHERE am.sender_kind='influencer' AND am.attachments <> '[]'::jsonb AND am.attachments_purged_at IS NULL;
--     (지금은 확정 탈퇴 6개월 경과 회원이 0 이라 0 일 수 있다 — 0 이어도 전후가 같은지가 확인 대상)
--   [V1] 적용 뒤 같은 조회를 **새 식**으로 — 응모 있는 행만 세도록 `AND am.application_id IS NOT NULL` 을 붙여 [P1] 과 같아야 한다:
--     SELECT count(*) FROM public.application_messages am
--       LEFT JOIN public.applications a ON a.id = am.application_id
--       JOIN public._withdrawal_media_purge_due_ids() due ON due.influencer_id = COALESCE(am.influencer_id, a.user_id)
--      WHERE am.application_id IS NOT NULL AND am.sender_kind='influencer'
--        AND am.attachments <> '[]'::jsonb AND am.attachments_purged_at IS NULL;
--   [V2] 목록 함수 첫 호출(서비스 키 가능 — 0행이어도 호출이 성공하는지가 확인 대상):
--     SELECT * FROM public.list_pending_withdrawal_message_attachment_purge(10);
--   [V3] 건수·경고: SQL 편집기에서는 42501 이 나는 것이 정상. 관리자 로그인 브라우저에서
--     await db.rpc('count_overdue_withdrawal_message_attachment_purge')   // 정수
--     await db.rpc('get_withdrawal_ops_alert')                            // message_attachment_overdue* 열 포함 10키
--   [V4] 🔴 응모 없는 행이 실제로 새로 잡히는지(개발서버 시험): 탈퇴 확정 6개월 경과 시험 회원에게 일반 문의 첨부 행(sender_kind='influencer',
--        attachments 에 path 가 있는 것)을 넣고 [V2] 를 다시 — 그 행이 1행으로 나와야 한다. 끝나면 시험 행을 지운다.
--   [V5] 권한 보존: SELECT p.proname, p.proacl::text FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
--          AND p.proname IN ('list_pending_withdrawal_message_attachment_purge',
--            'count_overdue_withdrawal_message_attachment_purge','get_withdrawal_ops_alert');
--        기대: list 는 authenticated·anon 없음(postgres·service_role 만), 나머지 둘은 anon 없음·authenticated 있음, 셋 다 맨 앞 =X/ 없음
--
-- ── 되돌리는 방법 ──
--   368 파일의 [B]·[D] 함수 정의와 451 파일의 get_withdrawal_ops_alert 정의를 그대로 다시 실행(CREATE OR REPLACE).
-- ============================================================

BEGIN;

-- ============================================================
-- [B] list_pending_withdrawal_message_attachment_purge — 368 베이스, 결합만 변경
-- ============================================================
CREATE OR REPLACE FUNCTION public.list_pending_withdrawal_message_attachment_purge(
  p_limit integer DEFAULT 500
)
RETURNS TABLE (
  message_id   uuid,
  delete_paths text[],
  keep_paths   text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
  WITH target AS (
    SELECT am.id
      FROM public.application_messages am
      LEFT JOIN public.applications a ON a.id = am.application_id
      JOIN public._withdrawal_media_purge_due_ids() due
        ON due.influencer_id = COALESCE(am.influencer_id, a.user_id)
     WHERE am.sender_kind = 'influencer'
       AND am.attachments <> '[]'::jsonb
       AND am.attachments_purged_at IS NULL
       -- 관리자를 겸한 회원은 건드리지 않는다(358·359·361·364 와 같은 판단).
       -- 눈에 보이게 남겨 [D] 의 밀린 건수에 계속 잡히게 한다.
       AND NOT public._influencer_is_admin_account(COALESCE(am.influencer_id, a.user_id))
     ORDER BY am.id
     LIMIT GREATEST(COALESCE(p_limit, 500), 1)
  ),
  -- 아직 안 지운(=파기되지 않은) 모든 메시지의 첨부 경로. 대상 배치뿐
  -- 아니라 표 전체를 본다 — 대상 밖 메시지가 같은 경로를 붙들고 있는지
  -- 확인해야 하기 때문이다(분해표 §2 ⑤, 캠페인 설명 이미지 참조세기 선례).
  all_active_paths AS (
    SELECT am.id AS message_id, (elem ->> 'path') AS path
      FROM public.application_messages am,
           jsonb_array_elements(am.attachments) AS elem
     WHERE am.attachments_purged_at IS NULL
       AND (elem ->> 'path') IS NOT NULL
  ),
  target_elem AS (
    SELECT ap.message_id,
           ap.path,
           EXISTS (
             SELECT 1
               FROM all_active_paths o
              WHERE o.path = ap.path
                AND o.message_id <> ap.message_id
                AND o.message_id NOT IN (SELECT t.id FROM target t)
           ) AS referenced_outside
      FROM all_active_paths ap
      JOIN target t ON t.id = ap.message_id
  )
  -- ⚠️ **COALESCE 를 빼면 안 된다.** array_agg(...) FILTER 는 걸리는 원소가
  --    하나도 없으면 **빈 배열이 아니라 NULL** 을 돌려준다. 그대로 내보내면
  --    12-B-2(파기 함수)가 그 값을 순회하다 터지거나, 더 나쁘게는 조용히
  --    「지울 것 없음」으로 넘어간다. 소비하는 쪽이 실수할 수 없게 **여기서**
  --    빈 배열로 맞춘다 — 계약을 문서로 경고하는 것보다 낫다.
  SELECT te.message_id,
         COALESCE(array_agg(DISTINCT te.path) FILTER (WHERE NOT te.referenced_outside), '{}'::text[]) AS delete_paths,
         COALESCE(array_agg(DISTINCT te.path) FILTER (WHERE te.referenced_outside),     '{}'::text[]) AS keep_paths
    FROM target_elem te
   GROUP BY te.message_id;
$fn$;

COMMENT ON FUNCTION public.list_pending_withdrawal_message_attachment_purge(integer) IS
'탈퇴 확정 6개월이 지나 파기해야 할 메시지 사진 목록(마이그레이션 368, 482 에서 일반 문의 포함). '
'sender_kind=''influencer'' 메시지만 대상이다(admin 발신 응대 기록은 제외). '
'[482] 응모 없는 일반 문의 행도 잡힌다 — LEFT JOIN applications + COALESCE(am.influencer_id, a.user_id). '
'🔴 postgres·service_role 전용. 관리자에게는 건수만 (count_overdue_withdrawal_message_attachment_purge). '
'⚠️ 364 의 list_pending_withdrawal_media_purge 와는 별개 장치다. '
'⚠️ delete_paths·keep_paths 는 **비어도 NULL 이 아니라 빈 배열**이다.';

-- ============================================================
-- [D] count_overdue_withdrawal_message_attachment_purge — 368 베이스, 결합만 변경
-- ============================================================
CREATE OR REPLACE FUNCTION public.count_overdue_withdrawal_message_attachment_purge()
RETURNS integer
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT COUNT(*)::integer INTO v_count
    FROM public.application_messages am
    LEFT JOIN public.applications a ON a.id = am.application_id
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = COALESCE(am.influencer_id, a.user_id)
   WHERE am.sender_kind = 'influencer'
     AND am.attachments <> '[]'::jsonb
     AND am.attachments_purged_at IS NULL;

  RETURN v_count;
END;
$fn$;

COMMENT ON FUNCTION public.count_overdue_withdrawal_message_attachment_purge() IS
'파기 기한이 지났는데 아직 안 지워진 메시지 사진 건수(마이그레이션 368, 482 에서 일반 문의 포함). '
'경로는 주지 않는다 — 관리자에게도. 0 이 정상이고, 권한이 없으면 0 이 아니라 42501 오류다. '
'⚠️ 관리자를 겸한 회원의 메시지는 목록에서는 빠지지만 여기에는 계속 잡힌다(의도). '
'[482] 응모 없는 일반 문의 행 포함(LEFT JOIN + COALESCE).';

-- ============================================================
-- get_withdrawal_ops_alert — 451 베이스, 메시지 사진 겸직 몫 계산만 변경
-- ============================================================
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
  --   [482] 셋(목록·건수·이 계산)이 모두 `LEFT JOIN applications` + `COALESCE(am.influencer_id, a.user_id)` —
  --         응모 없는 일반 문의 행(influencer_id 만 참)도 잡히게. 응모 있는 행은 종전과 결과가 같다.
  --      어긋나면 「목록엔 없는데 건수엔 있는」 값이 나와 원인을 못 찾는다.
  SELECT COUNT(*)::integer INTO v_msg_admin_locked
    FROM public.application_messages am
    LEFT JOIN public.applications a ON a.id = am.application_id
    JOIN public._withdrawal_media_purge_due_ids() due
      ON due.influencer_id = COALESCE(am.influencer_id, a.user_id)
   WHERE am.sender_kind = 'influencer'
     AND am.attachments <> '[]'::jsonb
     AND am.attachments_purged_at IS NULL
     AND public._influencer_is_admin_account(COALESCE(am.influencer_id, a.user_id));

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
'관리자 「탈퇴 처리 점검」 경고용 집계(마이그레이션 366 → 372 → 419 → 451 → 482). '
'밀린 파기 3종(영수증·인증샷 / 재가입 차단 기록 / 메시지 사진) + 멈춘 확정 + 그중 관리자 겸직 몫 + '
'예정일 안내 메일 2종. 권한 없으면 42501. '
'⚠️ 겸직 판정은 서버만 할 수 있다 — 확정되면 352 가 이메일을 바꿔 화면의 관리자 대조가 무력해진다. '
'⚠️ 예정일 비교는 `<`(오늘 제외) — 예약 실행이 04:45 라 오늘 건은 아직 정상이다. '
'⚠️ [451] 메일 「아직 안 나감」의 첫 판정 시점은 **`scheduled_at` 뒤 처음 오는 09:00 + 1시간**이다. '
'`scheduled_at` 이 NULL 인 450 이전 행만 옛 식(전이일 09:30). '
'[482] 메시지 사진 겸직 몫이 응모 없는 일반 문의 행도 센다(368 의 목록·건수 함수와 같은 판정). '
'⚠️ 재정의할 때 베이스는 **가장 번호가 큰 정의**(현재 482).';

-- 366·372·419·451 과 같은 권한 — 관리자 화면이 부른다(CREATE OR REPLACE 라 보존되지만 명시).
REVOKE ALL ON FUNCTION public.get_withdrawal_ops_alert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
