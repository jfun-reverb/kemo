-- ============================================================
-- 273_submission_deadline_change_notify.sql
-- 결과물 제출 마감일(submission_end) 변경 시 승인된 응모자에게 앱 알림 발송
-- 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md
--         §설계 5-(7)「인플루언서 안내 — 알림 대상은 배타적이다」/ 확정 결정 13
--         단계 분할표 「1단계-B」의 ⑧ 항목(마이그레이션 1개)
--
-- ▶ 무엇을, 왜
--   결과물 제출 마감일(campaigns.submission_end)이 바뀌면 그 캠페인의 승인(approved)
--   응모자에게 알림을 보낸다. 연장이든 단축이든 보낸다 — 근거는 사양서 그대로:
--     · 연장: 마감이 지나 못 냈던 사람은 폼이 다시 열린 것을 알 방법이 없다(사용자 지시 원문)
--     · 단축: 제출 기회를 직접 빼앗는 불리한 변경이라 통지 의무
--   반대로 모집 마감일(deadline)이 바뀌는 것은 이번 대상이 아니다 — 응모 상태 자체가
--   변하지 않으므로 알림은 불안만 만든다(주의사항 변경을 알림 없이 응모이력 비교 표시로만
--   처리한 선례와 같은 판단, 사양서 §5-(7) 표).
--
-- ▶ notifications.kind CHECK 현재 목록 실측(재발 방지 — supabase.md 「기준 데이터 중복 확인」
--   과 같은 정신) — supabase/migrations 전체에서 notifications_kind_check 를 정의/확장한
--   최신 파일을 grep 해 확인함. 219(정산 PR1)가 최신이며 9종, 그 이후(220~272) 파일 중
--   notifications.kind CHECK 를 건드린 파일 없음(222·231~233·241·242·262 는 이미 있는
--   kind='settlement_paid' 등을 함수 본문에서 "쓰기"만 할 뿐 CHECK 자체는 안 건드림).
--   현행 9종 + 이번 신규 1종 = 10종.
--
-- ▶ 신규 kind 이름: submission_deadline_changed
--   명명 규칙 확인 — 기존 kind 는 전부 "<대상>_<동사과거형>" 형태
--   (application_approved/cancelled, deliverable_rejected/changed/approved/proxy_submitted,
--    settlement_paypal_required/paid). 대상은 "무엇이 바뀌었나"인 submission_deadline,
--    동사는 change 계열이 자연스러워 deliverable_changed 와 같은 어미(changed)를 맞춤.
--   연장(extended)·단축(shortened) 을 kind 2종으로 나누지 않고 1종으로 묶은 이유는
--   아래 §설계 결정 참고.
--
-- ▶ 설계 결정 1 — 발행 주체: campaigns AFTER UPDATE 트리거 (원격 호출 함수 아님)
--   사양서가 제시한 두 선택지 중 (가) 트리거를 택함. 근거:
--     · updateCampaign() 은 dev/lib/storage.js:392 단일 진입점이지만, 그 앞단
--       saveCampaignEdit()(admin.js) 처럼 항상 submission_end 를 포함한 전체 필드를
--       매번 UPDATE 페이로드에 담아 보낸다(값이 안 바뀌어도 키 자체는 항상 존재) —
--       "실제로 값이 바뀔 때만" 판정을 원격 호출 함수 호출 시점에 맡기면 호출부가
--       하나뿐이라도 "호출을 빠뜨리는" 회귀 위험이 남는다. 트리거는 UPDATE 문에
--       submission_end 가 어떤 값으로 오든 데이터베이스가 직접 판정하므로 호출 경로가
--       늘어나도(예: 향후 캠페인 일괄 수정 도구) 새지 않는다.
--     · application_approved(154)·deliverable_*(037) 알림 전부 이 프로젝트에서
--       "트리거가 상태 전이를 감지해 알림을 만든다" 패턴을 이미 쓰고 있어 일관성 유지.
--   campaign_change_history 기록 트리거(266)와의 관계 — 266 은
--   `AFTER UPDATE OF <48개 컬럼>` 이고 그 목록에 submission_end 가 포함돼 있다.
--   이 마이그레이션의 트리거는 `AFTER UPDATE OF submission_end` 하나만 지정해
--   컬럼 축을 좁혔다. 두 트리거 모두 NEW 를 변형하지 않고 각자 INSERT 만 하므로
--   실행 순서와 무관하게 서로 간섭하지 않는다(266 파일 자체가 "이 트리거만 AFTER
--   UPDATE, 조건 없음"이라고 명시한 것과 동일한 계약 — 이번 트리거도 그 계약을
--   지킨다). PostgreSQL 표준 규칙대로 AFTER 트리거는 이름 알파벳순 실행이지만,
--   두 트리거 다 순서에 의존하는 로직이 없어 실행 순서를 신경 쓸 필요가 없다.
--
-- ▶ 설계 결정 2 — kind 1종으로 연장/단축을 함께 묶음 (2종 분리 안 함)
--   이유: (1) 클라이언트 라우팅(dev/js/notifications.js)이 kind 로 분기하는 지점이
--   늘어날수록 유지보수 지점이 늘어난다 — 1종이면 라우팅 분기 1곳으로 끝난다.
--   (2) NULL 을 낀 전이(무기한→값, 값→무기한)는 "연장이냐 단축이냐"가 애매해질 수
--   있는데, 제목/본문 문구만 다르게 하고 kind 는 하나로 유지하면 이 애매함이 라우팅
--   로직에 새지 않는다(문구 판정은 함수 안에서만 분기). (3) message_received 도
--   실제로는 매번 다른 내용의 메시지지만 kind 는 1종으로 통일된 선례와 같은 결.
--
-- ▶ 설계 결정 3 — 방향(연장/단축) 판정과 NULL 경계(경계 상황 6 대응)
--   submission_end 는 NULL 을 "무기한(제한 없음)"으로 취급하는 컬럼이다(사양서
--   §설계 7 「마감일이 NULL → 통과(무기한)」과 같은 해석):
--     · OLD 있음 → NEW NULL(마감을 지움)              = '연장'(무제한이 됐으므로)
--     · OLD NULL(원래 무기한) → NEW 있음(마감이 새로 생김) = '단축'(있던 자유가 줄었으므로)
--     · 둘 다 값이 있으면 날짜 비교(NEW > OLD 연장 / NEW < OLD 단축)
--   이 판정은 알림 문구 선택에만 쓰이고, 서버 마감 차단 판정(1단계 트리거)이나
--   화면 확인창 로직과는 무관한 별도 축이다.
--
-- ▶ 설계 결정 4 — 멱등성·중복 방지: message_received(145)·application_approved(154)
--   와 동일한 "미읽음 존재 시 skip" 패턴을 그대로 따름 — 같은 응모건(ref_id=
--   application.id)에 대해 미읽음 submission_deadline_changed 알림이 이미 있으면
--   새로 INSERT 하지 않는다.
--     · 이 패턴이 안전한 이유: WHEN 절(`NEW.submission_end IS DISTINCT FROM
--       OLD.submission_end`)이 이미 "값이 실제로 바뀐 UPDATE 문에서만" 함수 실행을
--       보장한다 — 같은 값을 다시 저장하는 이중 클릭·재저장은 이 단계에서 이미
--       걸러진다. 미읽음 skip 은 그 다음 방어선으로, 아주 짧은 시간에 값이 여러 번
--       실제로 바뀌는 드문 경우(오타 정정 등)에 알림이 쌓이는 것만 막는다.
--     · 알려진 트레이드오프(message_received 와 동일): 마감일이 다시 바뀌었는데
--       이전 미읽음 알림이 남아 있으면 새 알림을 안 보내 문구가 최신 날짜와
--       어긋날 수 있다. 그러나 알림을 누르면 활동관리 화면에서 실제 최신
--       submission_end 값을 그대로 보여주므로(폼 자체가 진실의 원천) 실질적 피해는
--       없다 — message_received 가 여러 통의 새 메시지를 미읽음 배지 1개로 뭉치는
--       것과 같은 트레이드오프를 그대로 수용한다.
--
-- ▶ 설계 결정 5 — 감사용 계정(is_audit) 예외 없음
--   다른 알림 트리거(application_approved/deliverable_*)의 선례를 그대로 따름 —
--   그 트리거들은 is_audit 를 전혀 참조하지 않는다. is_audit 격리는 "집계·통계·
--   운영현황·정산"처럼 실 운영 수치를 왜곡하는 곳에만 적용되는 것이지(CLAUDE.md
--   「감사용 계정 메커니즘」 참조), 개인 알림처럼 "그 계정에 실제로 일어난 일을
--   그 계정에 알리는" 성격의 트리거에는 적용된 선례가 없다. 감사용 계정도 실제
--   응모·승인 행을 갖고 있으므로(운영팀이 실사용자 동선을 그대로 재현하는 게
--   목적) 다른 알림과 동일하게 받는 것이 오히려 "실사용자와 동일 경험"이라는
--   감사용 계정의 존재 목적에 부합한다. 정산처럼 별도 테이블에 새 행을 만들어
--   금액을 왜곡하는 것과 달리 이 알림은 부수 데이터(집계값)를 전혀 건드리지 않는다.
--
-- ▶ 경계 상황 대응 (사양서 항목 6)
--   · submission_end NULL → 값 / 값 → NULL          : 설계 결정 3 에서 처리
--   · 승인자 0명                                       : 루프가 0회 돌고 끝, 정상
--   · 보관 삭제(deleted_at IS NOT NULL) 캠페인          : 신청이 삭제 시 즉시 파기되어
--     실제로는 승인자 자체가 없지만, 방어적으로 NEW.deleted_at IS NOT NULL 이면
--     즉시 RETURN(트리거 본문 최상단 가드)
--   · 배치·마이그레이션(서비스 키, auth.uid() IS NULL) 변경 : 알림 발행 제외
--     (아래 참고 — 이번 케이스는 응모 마감 트리거(272)의 "auth.uid() IS NULL → 통과"
--     와 반대 방향의 판단임에 주의)
--
-- ▶ auth.uid() IS NULL 을 "제외" 조건으로 쓰는 이유(272 와 반대 방향인 이유)
--   272(응모 마감 차단)의 auth.uid() IS NULL 통과 조항은 "차단을 우회시키지 않기
--   위해"(배치가 막히면 안 됨) 존재한다. 이번 트리거는 반대로 "알림을 안 만드는"
--   쪽을 기본값으로 둔다 — 사유: 캠페인 CUD 는 관리자 전용 행 단위 보안 정책
--   (001_enable_rls.sql, campaigns UPDATE 는 is_admin() 만 통과)이라 실제 관리자
--   화면 저장은 인증 세션을 타고 항상 auth.uid() 가 채워진다. auth.uid() 가 NULL 인
--   경로는 SQL Editor 직접 실행·서비스 키 배치 스크립트뿐이며, 이런 경로는 대개
--   "데이터 정정"(예: 과거 날짜 오타 일괄 수정)이지 "운영자의 실제 마감일 변경
--   결정"이 아니다. 데이터 정정성 일괄 UPDATE 가 실 회원에게 "마감일이 바뀌었다"는
--   알림을 대량 발송하는 사고를 막기 위해 이 경로는 알림을 만들지 않는다(단
--   campaign_change_history(266)의 감사 기록은 이 트리거와 무관하게 그대로 남는다
--   — 'system' change_source 로 기록됨).
--
-- ▶ ref_table/ref_id·클라이언트 라우팅 (직접 수정하지 않음 — 메인 세션 몫, 아래
--   "클라이언트 반영 필요" 섹션에 위치·코드 명시)
--   kind='submission_deadline_changed', ref_table='applications', ref_id=신청 id.
--   활동관리(결과물 제출) 화면으로 보내려면 openActivityPage(applicationId,
--   campaignId, 'mypage') 호출이 필요한데 campaign_id 는 notifications 테이블에
--   없으므로, 클라이언트가 ref_id(신청 id)로 신청 행을 조회해 campaign_id 를
--   얻어야 한다 — deliverables 알림 라우팅이 이미 쓰는 것과 동일한 패턴
--   (notifications.js:334-343 fetchDeliverablesForUser 로 refId 매칭 후
--   openActivityPage 호출).
--
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_submission_deadline_change_notify ON public.campaigns;
--   DROP FUNCTION IF EXISTS public.notify_submission_deadline_change();
--   ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
--   ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--     'deliverable_rejected', 'deliverable_changed', 'deliverable_approved',
--     'application_cancelled', 'message_received', 'application_approved',
--     'deliverable_proxy_submitted', 'settlement_paypal_required', 'settlement_paid'
--   ));
-- ============================================================

BEGIN;

-- ============================================================
-- (1) notifications.kind CHECK 제약 확장 — submission_deadline_changed 추가
--     현행(219 누적) 9종 + 신규 1종 = 10종
-- ============================================================
ALTER TABLE public.notifications
  DROP CONSTRAINT IF EXISTS notifications_kind_check;

ALTER TABLE public.notifications
  ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
    'deliverable_rejected',
    'deliverable_changed',
    'deliverable_approved',
    'application_cancelled',
    'message_received',
    'application_approved',
    'deliverable_proxy_submitted',
    'settlement_paypal_required',
    'settlement_paid',
    'submission_deadline_changed'   -- 273 신규: 결과물 제출 마감일 변경(연장·단축 공용) 안내
  ));

COMMENT ON COLUMN public.notifications.kind IS
  'deliverable_rejected | deliverable_changed | deliverable_approved | application_cancelled | '
  'message_received | application_approved | deliverable_proxy_submitted | '
  'settlement_paypal_required | settlement_paid | submission_deadline_changed';

-- ============================================================
-- (2) 트리거 함수 — campaigns.submission_end 실제 변경 시 승인 응모자에게 알림
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_submission_deadline_change()
  RETURNS trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path = ''
AS $$
DECLARE
  v_actor     uuid := auth.uid();
  v_direction text;
  v_new_text  text;
  v_title     text;
  v_body      text;
  r           record;
BEGIN
  -- 배치·마이그레이션(서비스 키) 경로는 알림 대상에서 제외 — 위 파일 상단
  -- "auth.uid() IS NULL 을 제외 조건으로 쓰는 이유" 참고. 실제 관리자 화면 저장은
  -- 인증 세션을 타므로 이 조건에 걸리지 않는다.
  IF v_actor IS NULL THEN
    RETURN NEW;
  END IF;

  -- 보관 삭제된 캠페인은 신청이 즉시 파기되어 대상이 없지만 방어적으로 한 번 더 확인
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- 방향 판정 — 설계 결정 3 그대로. NULL 은 "무기한"으로 취급.
  v_direction := CASE
    WHEN NEW.submission_end IS NULL THEN 'extended'   -- 마감을 지움 → 무제한이 됨
    WHEN OLD.submission_end IS NULL THEN 'shortened'   -- 원래 무기한이었는데 마감이 새로 생김
    WHEN NEW.submission_end > OLD.submission_end THEN 'extended'
    ELSE 'shortened'
  END;

  -- 문구 조립 — 사용자 확정 요구사항: 새 제출 기한 / 그때까지 내면 된다 / 문의 경로, 3단계
  IF NEW.submission_end IS NULL THEN
    v_title := '提出期限がなくなりました';
    v_body  := '1. 「' || COALESCE(NEW.title, 'キャンペーン') || '」の提出期限がなくなりました。いつでも提出できます。' || E'\n'
            || '2. 準備ができたら提出してください。' || E'\n'
            || '3. わからないことがあれば、「メッセージ」から聞いてください。';
  ELSE
    v_new_text := to_char(NEW.submission_end, 'YYYY年MM月DD日');
    IF v_direction = 'extended' THEN
      v_title := '提出期限が延長されました';
      v_body  := '1. 「' || COALESCE(NEW.title, 'キャンペーン') || '」の提出期限が、' || v_new_text || 'に変わりました。' || E'\n'
              || '2. その日までに提出してください。' || E'\n'
              || '3. わからないことがあれば、「メッセージ」から聞いてください。';
    ELSE
      v_title := '提出期限が変更されました';
      v_body  := '1. 「' || COALESCE(NEW.title, 'キャンペーン') || '」の提出期限が、' || v_new_text || 'に変わりました（早まりました）。' || E'\n'
              || '2. その日までに提出してください。' || E'\n'
              || '3. わからないことがあれば、「メッセージ」から聞いてください。';
    END IF;
  END IF;

  -- 대상: 이 캠페인의 승인(approved) 응모자 전원. 감사용 계정 예외 없음(설계 결정 5).
  FOR r IN
    SELECT a.id AS application_id, a.user_id
    FROM public.applications a
    WHERE a.campaign_id = NEW.id
      AND a.status = 'approved'
  LOOP
    -- 미읽음 중복 방지 — message_received(145)·application_approved(154) 와 동일 패턴
    IF NOT EXISTS (
      SELECT 1 FROM public.notifications
      WHERE user_id   = r.user_id
        AND kind      = 'submission_deadline_changed'
        AND ref_table = 'applications'
        AND ref_id    = r.application_id
        AND read_at   IS NULL
    ) THEN
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (r.user_id, 'submission_deadline_changed', 'applications', r.application_id, v_title, v_body);
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.notify_submission_deadline_change IS
  '[273] campaigns.submission_end 실제 변경 시(WHEN 절로 no-op 재저장 배제) 그 캠페인의 '
  '승인(approved) 응모자 전원에게 notifications INSERT(kind=submission_deadline_changed). '
  '연장·단축·NULL 경계는 함수 내부에서 문구만 분기, kind 는 1종. '
  'auth.uid() IS NULL(배치·서비스 키)이면 알림 생략. is_audit 예외 없음. '
  'SECURITY DEFINER — 트리거 전용.';

-- ============================================================
-- (3) 트리거 — submission_end 값이 실제로 바뀐 UPDATE 문에서만 발동
--     ⚠️ AFTER UPDATE OF submission_end 는 "UPDATE 문에 그 컬럼이 SET 절에
--     언급되면" 발동하는 것이지 값이 바뀌었는지는 안 본다(admin.js saveCampaignEdit
--     의 updateCampaign() 은 매 저장마다 submission_end 를 포함한 전 필드를 보낸다
--     — 이 함수 자체가 그렇게 짜여 있음, dev/lib/storage.js:392). 그래서 WHEN 절로
--     "실제 값 변경"을 한 번 더 좁힌다 — 266(campaign_change_history)이 이미 쓰는
--     IS DISTINCT FROM 비교와 동일한 계약.
-- ============================================================
DROP TRIGGER IF EXISTS trg_submission_deadline_change_notify ON public.campaigns;

CREATE TRIGGER trg_submission_deadline_change_notify
  AFTER UPDATE OF submission_end
  ON public.campaigns
  FOR EACH ROW
  WHEN (NEW.submission_end IS DISTINCT FROM OLD.submission_end)
  EXECUTE FUNCTION public.notify_submission_deadline_change();

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발서버 SQL Editor 에서 반드시 1단계씩 순서대로 실행하고
-- 각 단계 결과를 확인한 뒤 다음 단계로 진행할 것 (.claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ════════════════════════════════════════════════════════════
/*

-- [1단계] CHECK 제약에 신규 kind 포함 여부 확인
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'public.notifications'::regclass
  AND conname  = 'notifications_kind_check';
-- 기대값: 식에 'submission_deadline_changed' 포함(10종)

-- [2단계] 트리거 켜짐 확인
SELECT tgname, tgenabled
FROM pg_trigger
WHERE tgrelid = 'public.campaigns'::regclass
  AND tgname = 'trg_submission_deadline_change_notify';
-- 기대값: 1행, tgenabled='O'

-- [3단계] 검증용 캠페인 준비 — submission_end 있고 승인 응모(approved) 1건 이상인
-- 캠페인 1개 확보 (없으면 개발서버에서 임의 응모 1건을 승인으로 바꿔서 준비)
SELECT c.id, c.title, c.submission_end,
       (SELECT count(*) FROM public.applications a
         WHERE a.campaign_id = c.id AND a.status = 'approved') AS approved_cnt
FROM public.campaigns c
WHERE c.submission_end IS NOT NULL
ORDER BY approved_cnt DESC
LIMIT 5;

-- [4단계] SQL Editor 직접 UPDATE(서비스 키, auth.uid() IS NULL) → 알림 0건 기대
-- (설계 결정: 배치성 변경은 알림 생략)
UPDATE public.campaigns SET submission_end = submission_end + 1 WHERE id = '<검증용_ID>';
SELECT count(*) FROM public.notifications
WHERE ref_table='applications' AND kind='submission_deadline_changed'
  AND ref_id IN (SELECT id FROM public.applications WHERE campaign_id = '<검증용_ID>');
-- 기대값: 0 (SQL Editor 는 auth.uid() 가 NULL 이라 알림 생략 — 정상)

-- ⚠️ 위 [4단계]가 "정상적으로 알림이 안 뜨는지"만 확인하는 단계라, 실제 알림 생성은
-- 반드시 개발서버 관리자 화면에서 로그인한 세션으로 캠페인 편집 저장을 통해 재현할 것
-- (아래 [5단계]는 그 결과를 확인하는 조회 전용 SQL).

-- [5단계] 관리자 화면에서 실제로 제출 마감일을 연장 저장한 뒤 알림 생성 확인
SELECT n.kind, n.title, n.body, n.ref_table, n.ref_id, n.created_at
FROM public.notifications n
WHERE n.kind = 'submission_deadline_changed'
ORDER BY n.created_at DESC
LIMIT 10;
-- 기대값: 방금 저장한 캠페인의 승인 응모자 수만큼 행 생성, body 에 새 날짜 포함

-- [6단계] 미읽음 중복 방지 확인 — 같은 캠페인을 다시 다른 날짜로 한 번 더 저장
-- (직전 알림을 아직 안 읽은 상태에서)
SELECT count(*) FROM public.notifications
WHERE kind='submission_deadline_changed'
  AND ref_id IN (SELECT id FROM public.applications WHERE campaign_id = '<검증용_ID>')
  AND read_at IS NULL;
-- 기대값: 승인 응모자 수와 동일(추가 저장에도 건수가 늘지 않음 — 미읽음 skip 정상)

-- [7단계] 모집 마감일(deadline)만 변경 → 알림 0건 기대(회귀 확인)
UPDATE public.campaigns SET deadline = deadline WHERE id = '<검증용_ID>';
-- (deadline 만 실제로 바꿔도 무방 — 위는 no-op 예시)
SELECT count(*) FROM public.notifications
WHERE kind='submission_deadline_changed' AND created_at > now() - interval '1 minute';
-- 기대값: 직전 단계와 동일(증가 없음)

-- [8단계] 같은 값으로 재저장(no-op) → 알림 0건 기대
UPDATE public.campaigns SET submission_end = submission_end WHERE id = '<검증용_ID>';
SELECT count(*) FROM public.notifications
WHERE kind='submission_deadline_changed' AND created_at > now() - interval '1 minute';
-- 기대값: 증가 없음 (WHEN 절이 값 불변 UPDATE 를 걸러냄)

*/
