-- ============================================================
-- 372_withdrawal_ops_alert_message_attachments.sql
-- 2026-08-21
--
-- 목적:
--   관리자 「탈퇴 처리 점검」 경고에 **응모건 메시지 사진 파기**를 더한다.
--   368 이 건수 함수를 만들었지만 **아무도 부르지 않아** 화면에 안 보였다.
--
-- 🔴 왜 별도 마이그레이션인가 — 이게 없으면 파기가 멈춰도 조용하다
--   368 의 `count_overdue_withdrawal_message_attachment_purge()` 는
--   관리자만 부를 수 있는데, 관리자 화면이 그걸 부르는 자리가 0곳이었다.
--   예약 실행이 멈추면 사진이 계속 남는데 **아무 데도 안 뜬다** — 영수증
--   파기(364·366)에서 이미 같은 판단으로 경고를 만들어 뒀으므로 같은 자리에
--   합류시킨다.
--
-- ★ **베이스는 366 이다.** 이 함수는 `CREATE OR REPLACE` 로 갈아끼우므로,
--   가장 번호가 큰 정의를 베이스로 삼지 않으면 366 이 넣은 겸직 분리·상한
--   50 같은 것이 조용히 사라진다([[feedback_function_redefine_latest_base]] —
--   실제로 262 초안이 232 를 베이스로 써서 알림 잠금이 소실될 뻔했다).
--   366 대비 **추가만** 했고 기존 항목은 한 글자도 안 건드렸다.
--
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md
-- 작업표: docs/specs/2026-08-21-message-attachment-purge-breakdown.md 작업 12-B-5
--
-- 선행: 368 적용 완료(건수 함수가 있어야 한다).
--
-- 적용 이력 (★ 파일 이름으로 판단하지 말 것 — 데이터베이스에만 남는다):
--   - 개발: **2026-08-21 적용 완료**
--   - 운영: **2026-09-02 적용 완료**
--
--   개발 적용 후 확인한 것(적용 성공은 확인이 아니다 — 첫 호출에서 터진다):
--     · 관리자 브라우저에서 `get_withdrawal_ops_alert` 호출 → **열쇠말 8개**가 다 나오고
--       366 의 기존 6개도 그대로. 새 둘은 0.
--     · 화면 캐시에 값을 넣어 렌더 확인 — 버튼 「탈퇴 처리 점검 3건」이 뜨고,
--       모달 넷째 줄에 「파기 기한이 지난 응모건 메시지 사진 3건」 +
--       「그중 1건은 관리자 계정을 겸한 회원…」 안내가 나온다.
--       `image_not_supported` 아이콘도 글자가 아니라 그림으로 그려진다(저장소 첫 사용).
--     · 0건으로 되돌리니 버튼이 통째로 사라진다(0건이면 아무것도 안 그린다).
--
-- 롤백:
--   366 의 함수 정의를 그대로 다시 실행한다.
--   ⚠️ 화면(`admin-core.js`)이 새 열쇠말을 읽는데 없으면 `Number(undefined||0)`
--      = 0 이라 **그 줄만 안 그려질 뿐 나머지는 정상**이다. 배포 순서가
--      뒤바뀌어도 화면이 깨지지 않게 그렇게 만들었다.
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

  RETURN jsonb_build_object(
    'media_overdue',                          v_media_overdue,
    'media_overdue_admin_locked',             v_media_admin_locked,
    'email_block_overdue',                    v_email_overdue,
    'message_attachment_overdue',             v_msg_overdue,        -- 372 추가
    'message_attachment_overdue_admin_locked', v_msg_admin_locked,  -- 372 추가
    'stuck_confirm',                          v_stuck,
    'stuck_confirm_admin_locked',             v_stuck_admin_locked,
    'stuck_influencer_ids',                   to_jsonb(v_stuck_ids)
  );
END;
$fn$;

COMMENT ON FUNCTION public.get_withdrawal_ops_alert() IS
'관리자 「탈퇴 처리 점검」 경고용 집계(마이그레이션 366 → 372). '
'밀린 파기 3종(영수증·인증샷 / 재가입 차단 기록 / 메시지 사진) + 멈춘 확정 + '
'그중 관리자 겸직 몫. 권한 없으면 42501. '
'⚠️ 겸직 판정은 서버만 할 수 있다 — 확정되면 352 가 이메일을 바꿔 화면의 관리자 대조가 무력해진다. '
'⚠️ 예정일 비교는 `<`(오늘 제외) — 예약 실행이 04:45 라 오늘 건은 아직 정상이다. '
'⚠️ 재정의할 때 베이스는 **가장 번호가 큰 정의**(현재 372).';

-- 366 과 같은 권한 — 관리자 화면이 부른다.
REVOKE ALL ON FUNCTION public.get_withdrawal_ops_alert() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_withdrawal_ops_alert() TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인
-- (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — 함수 본문의 자료형·컬럼은
--  적용 시점에 검사되지 않고 **첫 호출에서** 터진다.
--  `.claude/rules/supabase.md`)
-- ============================================================
--
-- [V1] SQL 편집기에서 호출 — ⚠️ **권한 오류가 나는 것이 정상이다**
--      (서비스 키라 is_admin() 이 false).
--   SELECT public.get_withdrawal_ops_alert();
--   기대: **42501 'forbidden'**.
--
-- [V2] ★ 관리자 브라우저 콘솔(로그인 상태) — 여기가 진짜 첫 호출이다:
--   await db.rpc('get_withdrawal_ops_alert')
--   기대: 열쇠말 8개가 모두 있고, 새로 더한 둘이 보인다:
--     message_attachment_overdue: 0,
--     message_attachment_overdue_admin_locked: 0
--   → 0 이 정상이다(아직 확정된 탈퇴가 없다).
--   → **열쇠말이 없으면** 372 가 안 들어간 것이다(366 정의가 그대로).
--
-- [V3] 실제로 잡히는지 (개발서버):
--   371 의 [V3]-1·2 로 시험 데이터를 만든 뒤 [V2] 를 다시 호출.
--   기대: message_attachment_overdue 가 그 회원의 첨부 메시지 수만큼 오른다.
--   → 그 상태에서 관리자 화면을 새로고침하면 사이드바 「인플루언서」 항목에
--     경고 아이콘이 뜨고, 「탈퇴 처리 점검」 버튼 안에 새 줄이 보여야 한다.
--   정리는 371 의 [V6].
--
-- [V4] 겸직 분리:
--   [V3] 상태에서 그 시험 계정을 관리자로 만든 뒤 [V2] 호출.
--   기대: message_attachment_overdue 는 그대로이고
--         message_attachment_overdue_admin_locked 가 같은 수로 오른다.
--   확인 뒤 관리자 권한 해제 + 시험 행 삭제.
-- ============================================================
