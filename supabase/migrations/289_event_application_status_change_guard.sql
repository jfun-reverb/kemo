-- ============================================================
-- 289_event_application_status_change_guard.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 행사 캠페인의 신청 상태 직접 변경 차단
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
-- 선행: 280~288 (반드시 288 다음에 적용 — 이유는 아래 「왜 이 순서인가」)
--
-- 왜 필요한가:
--   관리자 화면(dev/js/admin-applications.js updateAppStatus)은 신청 상태를
--   원격 호출 함수(RPC) 없이 `db.from('applications').update({status:...})` 로
--   **직접** 바꾼다(RLS 정책 applications_update_admin 이 허용). 행사(티켓) 캠페인은
--   신청 상태가 event_tickets 와 짝을 이루는 파생값이라, 이 직접 수정 경로로
--   신청만 바뀌면 티켓은 그대로 남아 어긋난다 — 288 파일 헤더가 설명한 바로 그
--   사고(반려된 사람이 현장에서 입장 처리됨)의 근본 원인이다. 288 이 「수단」을
--   만들었으니, 이 파일이 「잘못된 길」을 막는다.
--
-- 왜 이 순서인가 (288 → 289):
--   순서를 뒤집으면(289 를 먼저 적용) 관리자가 예약을 정리할 수단이 하나도
--   없는 채로 직접 수정 경로만 막히는 구간이 생긴다 — 그 사이엔 행사 캠페인의
--   신청 상태를 **아무도** 바꿀 수 없다(사용자 요청 원문 그대로).
--
-- 이 파일이 만드는 것:
--   1) public.guard_event_application_status_change() — BEFORE UPDATE OF status
--      트리거 함수. applications.campaign_id 가 가리키는 캠페인이 event_mode 면
--      막는다. 단, 288 의 예약 함수 3종이 세워 둔 bypass 표시가 있으면 통과시킨다.
--   2) 트리거 trg_guard_event_application_status_change 등록.
--   3) public.reject_pending_on_campaign_end() 재정의(마이그레이션 176 원본에
--      조건 한 줄 추가) — 이유는 아래 「막으면 안 되는 경로」③ 참고.
--
-- ── 막으면 안 되는 경로 (요청사항 — 반드시 통과해야 하는 것) ────────
--
--   ① 예약 함수가 신청 행을 만들고 되살리는 경로 — reserve_event_ticket(288)
--      의 「되살리기(취소 후 재예약)」 UPDATE. 288 에서 이 함수 시작에 bypass
--      표시를 세워 두었으므로 통과한다.
--
--   ② 취소 함수가 cancelled 로 바꾸는 경로 — cancel_event_ticket(본인, 283+288)·
--      cancel_event_ticket_admin(관리자, 288) 이 신청을 cancelled 로 바꾸는
--      UPDATE. 두 함수 모두 bypass 표시를 세운 뒤 UPDATE 하므로 통과한다.
--
--   ③ 대기 → 확정 승격 시 pending → approved 경로 — 위 두 취소 함수가 호출하는
--      _promote_next_event_waitlist(288) 안의 UPDATE. 호출부가 이미 bypass 표시를
--      세운 같은 트랜잭션 안에서 실행되므로 통과한다(트랜잭션 범위 표시라 별도로
--      또 세울 필요 없음).
--
--   ④ (요청사항엔 없었지만 검토 중 발견 — 반드시 함께 막아야 실제로 안전하다)
--      캠페인 종료 자동 낙첨 — 마이그레이션 176 의 reject_pending_on_campaign_end()
--      가 campaigns.status 가 ended/expired 로 바뀔 때 그 캠페인의 pending 신청을
--      **일괄** rejected 로 바꾼다. 행사 캠페인에 대기(waitlist) 티켓이 하나라도
--      있으면 그 신청도 pending 이라 이 일괄 UPDATE 에 걸리는데, 이 UPDATE 는
--      288 의 bypass 표시 없이 들어오므로 위 트리거 1)에 막혀 예외가 던져진다.
--      행 단위 트리거의 예외는 그 UPDATE 문 전체를 롤백시키므로 — **캠페인 자체의
--      ended/expired 전이(campaigns.status UPDATE)까지 함께 실패한다.** 즉 대기
--      티켓이 하나라도 있는 행사 캠페인은 자동 종료가 영영 안 되는 사고가 난다.
--      → reject_pending_on_campaign_end() 에 `AND NOT event_mode` 조건을 추가해
--        행사 캠페인을 이 일괄 처리에서 아예 제외한다(3번 항목). 행사의 대기
--        티켓은 이 자동 낙첨의 대상이 아니다 — event_tickets 로만 정리한다
--        (행사가 끝나도 데이터 정리가 급하지 않으면 waitlist 로 남아 있어도
--        무해하고, 관리자가 288 의 cancel_event_ticket_admin 으로 정리할 수 있다).
--
-- ── 차단 메시지 ─────────────────────────────────────────────────
--   'event_status_change_blocked: 오프라인 행사 신청은 이 화면에서 상태를
--   바꿀 수 없습니다. 캠페인의 「진행현황 → 예약 현황」 탭에서 예약을
--   취소해 주세요.' — dev/js/admin-core.js 의 friendlyError() 가 한글 포함
--   메시지를 그대로 보여주므로(128행 「DB 트리거·함수(RAISE)가 한글 안내
--   메시지를 던지면 그대로 보여준다」), 이 문구가 관리자 화면 토스트에
--   그대로 뜬다 — 별도 클라이언트 수정 없이 무엇을 해야 하는지 안내된다.
--
-- ── 기존 트리거와의 실행 순서 확인 ─────────────────────────────────
--   applications 표의 기존 BEFORE UPDATE OF status 트리거는 1개뿐이다:
--     trg_guard_reject_with_paid_settlement (마이그레이션 247).
--   Postgres 는 같은 타이밍(BEFORE)·같은 이벤트의 트리거를 **트리거 이름
--   알파벳순**으로 실행한다. 이름 비교:
--     trg_guard_event_application_status_change   (이 파일)
--     trg_guard_reject_with_paid_settlement        (247)
--   'e' < 'r' 이므로 이 파일의 트리거가 **먼저** 실행된다.
--     · bypass 있음(288 의 함수들) → 즉시 통과 → 247 로 넘어감(정상, 247 은
--       OLD.status='approved' 이고 paid 정산이 있을 때만 반응하므로 이 파일과
--       독립적으로 동작).
--     · bypass 없음 + event_mode → 이 파일이 먼저 예외를 던져 247 까지 도달
--       하지 않는다. 어차피 막힐 UPDATE 이므로 어느 트리거가 먼저 막든 결과는
--       같다(메시지만 다르다).
--   AFTER 트리거(131/154 record_application_status_event · 246 자동 보류)는
--   이 파일과 타이밍이 달라 순서 경쟁이 없다 — 283 이 event_mode 캠페인에서
--   131/154 를 조기 반환하도록 이미 재정의해 두었다(무변경).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 차단 트리거 함수
-- ============================================================
CREATE OR REPLACE FUNCTION public.guard_event_application_status_change()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_event_mode boolean;
BEGIN
  -- 값이 실제로 안 바뀌는 UPDATE(다른 컬럼만 바뀌며 status 를 같은 값으로
  -- 다시 적는 경우)는 통과시킨다. WHEN 절과 같은 조건을 함수 안에도 한 번 더
  -- 두는 것은 247 의 관례(이중 방어 — 함수가 단독으로 호출돼도 안전).
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN
    RETURN NEW;
  END IF;

  -- 288 의 예약 함수 3종(reserve_event_ticket · cancel_event_ticket ·
  -- cancel_event_ticket_admin)이 세워 둔 표시. 있으면 이 트랜잭션은 그
  -- 함수들이 낸 변경이라는 뜻이므로 통과시킨다.
  IF COALESCE(current_setting('reverb.event_ticket_bypass', true), '') = 'on' THEN
    RETURN NEW;
  END IF;

  -- 캠페인을 찾지 못하면(데이터 정합 문제로 campaign_id 가 고아인 경우 등)
  -- 이 트리거의 책임 범위 밖이므로 막지 않는다(fail-open) — 이 트리거는 행사
  -- 캠페인 전용 보호 장치이지 일반 데이터 무결성 검사기가 아니다.
  SELECT c.event_mode INTO v_event_mode
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  IF COALESCE(v_event_mode, false) THEN
    RAISE EXCEPTION 'event_status_change_blocked: 오프라인 행사 신청은 이 화면에서 상태를 바꿀 수 없습니다. 캠페인의 「진행현황 → 예약 현황」 탭에서 예약을 취소해 주세요.'
      USING ERRCODE = 'P0001';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.guard_event_application_status_change() IS
  '[289] 오프라인 행사(event_mode) 캠페인의 신청 상태를 관리자 화면 등에서 직접 '
  'UPDATE 하는 것을 차단한다. 신청 상태는 반드시 event_tickets 예약 함수(288 '
  'reserve_event_ticket·cancel_event_ticket·cancel_event_ticket_admin)를 거쳐야 '
  '티켓과 어긋나지 않는다. 그 함수들은 set_config(''reverb.event_ticket_bypass'', '
  '''on'', true) 로 자신을 표시하고 이 트리거는 그 표시가 없을 때만 막는다.';

DROP TRIGGER IF EXISTS trg_guard_event_application_status_change ON public.applications;
CREATE TRIGGER trg_guard_event_application_status_change
  BEFORE UPDATE OF status ON public.applications
  FOR EACH ROW
  WHEN (NEW.status IS DISTINCT FROM OLD.status)
  EXECUTE FUNCTION public.guard_event_application_status_change();

COMMENT ON TRIGGER trg_guard_event_application_status_change ON public.applications IS
  '[289] 행사 캠페인 신청 상태 직접 변경 차단. 288 예약 함수가 세운 bypass 표시가 '
  '있으면 통과. 기존 trg_guard_reject_with_paid_settlement(247)보다 이름 알파벳순으로 '
  '먼저 실행됨(e < r) — 상세는 파일 헤더 참고.';

-- ============================================================
-- 2. reject_pending_on_campaign_end() 재정의 — 행사 캠페인 제외
--    (마이그레이션 176 원본 + 조건 한 줄. 트리거 자체는 이미 등록돼 있어
--    재등록 불필요 — 함수 본문만 CREATE OR REPLACE)
-- ============================================================
CREATE OR REPLACE FUNCTION public.reject_pending_on_campaign_end()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
BEGIN
  -- ended 또는 expired 로 새로 전환된 경우에만 처리.
  -- COALESCE(OLD.status,'') 로 OLD.status 가 NULL 인 엣지케이스도 안전하게 처리.
  -- [289] 행사(event_mode) 캠페인은 이 일괄 처리에서 제외한다 — 이유는 이
  -- 파일 헤더 「막으면 안 되는 경로 ④」 참고. NEW 는 campaigns 행 자체이므로
  -- 조인 없이 NEW.event_mode 로 바로 판정한다.
  IF NEW.status IN ('ended', 'expired')
     AND COALESCE(OLD.status, '') NOT IN ('ended', 'expired')
     AND NOT COALESCE(NEW.event_mode, false)
  THEN
    UPDATE public.applications
      SET status             = 'rejected',
          auto_reject_reason = CASE NEW.status
                                 WHEN 'ended'   THEN 'campaign_ended'
                                 ELSE                'campaign_expired'
                               END,
          reviewed_by        = '시스템(캠페인 종료)',
          -- reviewed_at = NULL: 어제KST 비교 조건에서 자동 제외 → 다이제스트 메일 미발송.
          reviewed_at        = NULL
      WHERE campaign_id = NEW.id
        AND status      = 'pending';
        -- approved / rejected / cancelled 는 WHERE 조건으로 완전 보호.
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.reject_pending_on_campaign_end() IS
  '[176+289] campaigns.status 가 ended/expired 로 전환될 때 해당 캠페인의 pending '
  '신청을 자동으로 rejected 처리. [289] 행사(event_mode) 캠페인은 제외 — 이 일괄 '
  'UPDATE 가 대기(waitlist) 티켓의 신청까지 rejected 로 바꾸려 하면 289 의 차단 '
  '트리거에 막혀 UPDATE 문 전체(=캠페인 상태 전환 자체)가 롤백된다. 행사의 대기 '
  '티켓은 event_tickets 로만 정리한다(288 cancel_event_ticket_admin). reviewed_at=NULL '
  '로 인플루언서 다이제스트 메일 제외. SECURITY DEFINER — 트리거에서만 호출.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 진행하고, 중간에 기대와 다르면 멈추고 원인부터 확인
-- ============================================================
-- [1] 트리거·함수 생성 확인
-- SELECT tgname, tgenabled FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND tgname = 'trg_guard_event_application_status_change';
--   → 1행, tgenabled='O'
--
-- [2] 실행 순서 확인 — applications 의 트리거 전체와 정의를 눈으로 확인
--     (이름 알파벳순으로 이 파일 트리거가 247 보다 먼저 오는지)
-- SELECT tgname, pg_get_triggerdef(oid) AS def
--   FROM pg_trigger
--  WHERE tgrelid = 'public.applications'::regclass
--    AND NOT tgisinternal
--  ORDER BY tgname;
--   → trg_guard_event_application_status_change 가 trg_guard_reject_with_paid_settlement
--     보다 이름순으로 앞서 나오는지 확인. 각 def 에 BEFORE/AFTER, UPDATE OF status 가
--     기대대로 찍혀 있는지도 함께 확인.
--
-- [3] 차단 동작 확인 — 행사 캠페인의 pending 신청 하나를 관리자 직접 UPDATE 로 승인 시도
--     (SQL Editor 는 관리자 로그인 세션이 아니라 RLS 를 우회하는 서비스 키다 —
--      applications_update_admin 정책과 무관하게 UPDATE 자체는 되지만, 이 트리거는
--      역할과 무관하게 항상 발동하므로 SQL Editor 로도 재현 가능하다. 272 마감 트리거와는
--      다른 특성 — 그쪽은 auth.uid() 를 보는 INSERT 트리거라 SQL Editor 로 재현 안 됐다.)
--     UPDATE public.applications SET status='approved' WHERE id='<행사 캠페인의 pending 신청 id>';
--   → ERROR: event_status_change_blocked: 오프라인 행사 신청은... (트랜잭션 롤백, 상태 안 바뀜)
--
-- [4] 통과 경로 확인 — 288 의 관리자 취소 함수는 여전히 동작하는지
--     (관리자 브라우저 세션에서) cancel_event_ticket_admin 호출 → {"ok":true, ...}
--     여기서 실패하면 289 가 288 의 정상 경로까지 막은 것이므로 즉시 원인 파악.
--
-- [5] 일반(비-행사) 캠페인 회귀 확인 — 지금까지와 동일하게 동작하는지
--     일반 캠페인의 pending 신청 하나를 관리자 화면에서 승인
--   → 정상 승인 + application_events 'approve' 감사 기록 +
--     notifications 'application_approved' 알림 (기존 154 동작 그대로)
--
-- [6] 행사 캠페인 자동 종료 회귀 확인 — 대기 티켓이 있는 행사 캠페인의
--     campaigns.status 를 ended 로 전이시켜도 실패하지 않는지
--     UPDATE public.campaigns SET status='ended' WHERE id='<대기 티켓 있는 행사 캠페인 id>';
--   → 정상 UPDATE 성공. 그 뒤
--     SELECT status FROM public.applications WHERE campaign_id='<위 id>' AND status='pending';
--   → 대기(waitlist) 신청은 그대로 pending 으로 남아 있어야 한다(자동 낙첨 제외 확인).
--
-- ============================================================
-- 롤백
-- ============================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS trg_guard_event_application_status_change ON public.applications;
-- DROP FUNCTION IF EXISTS public.guard_event_application_status_change();
-- -- reject_pending_on_campaign_end() 는 176 원본 정의로 되돌린다
-- --   (176 파일의 CREATE OR REPLACE 블록을 그대로 재실행)
-- COMMIT;
