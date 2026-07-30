-- ============================================================
-- 274_deliverable_deadline_guard.sql
-- 결과물 제출 마감 후 제출(deliverables INSERT·UPDATE)을 데이터베이스에서 차단
-- 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md (2단계 — §설계 1-(나))
--
-- ▶ 무엇을 왜 막는가
--   결과물 저장 경로는 실제로는 INSERT 1개 + UPDATE 2개(재제출 교체·최종 제출)뿐이다
--   (storage.js insertDraftDeliverable/submitDrafts, 사양서 「결과물 저장 경로」 표).
--   화면 마감 비교(application.js applyFormGating 등)는 기기 로컬 시간을 쓰고, 서버에는
--   막는 장치가 전무했다 — INSERT 만 막으면 재제출·최종 제출(둘 다 UPDATE)이 뚫린다.
--
-- ▶ 만든 것 2개
--   1. 판정 함수 public.can_submit_deliverable(application_id, kind, post_channel)
--      → jsonb {allowed, reason, submission_end}. STABLE·SECURITY DEFINER·search_path=''·
--        GRANT authenticated. 화면(3단계)·대조 게이트(2단계 배포 전)·트리거가 전부 이
--        함수 하나만 본다 — 판정 구현은 이거 하나뿐(사양서 §설계 3 "구현을 둘 만들지 않는다").
--   2. 검사 장치 trg_deliverable_deadline_guard — deliverables BEFORE INSERT OR UPDATE.
--      자체 판정 로직 없이 1번 함수만 호출한다.
--
-- ▶ 판정 함수의 4단계 (사양서 §설계 1-(나) 순서 그대로)
--   0. 호출자 검증(사양서에 없는 추가 보강, 아래 "★설계 보강 1" 참조) — GRANT authenticated 라
--      아무 로그인 사용자나 부를 수 있어, 본인 신청이 아니면 permission_denied 로 막는다.
--      auth.uid() IS NULL(서비스 키·대조 게이트 SQL Editor 배치 조회)과 관리자는 예외.
--   1. 신청 → 캠페인 submission_end 조회. NULL 이면 allowed=true, reason='no_deadline'.
--   2. (now() AT TIME ZONE 'Asia/Tokyo')::date <= submission_end → allowed=true, 'within_deadline'.
--   3. 마감 후 → 반려 예외 판정. "최신 1건"은 status<>'draft' 인 행을
--      ORDER BY created_at DESC, id DESC 로 정렬한 첫 행:
--        review_image = 같은 신청·같은 kind·같은 post_channel (채널 단위)
--        post         = 같은 신청·같은 kind (2단계까지는 채널 무시 — 현행 화면 정책,
--                        채널 단위 전환은 3단계 §설계 4)
--        receipt      = 같은 신청·같은 kind (채널 개념 없음)
--      그 행이 rejected 면 allowed=true. post_channel IS NULL 인 옛 행은 애초에
--      d.post_channel = p_post_channel 비교가 NULL=NULL 이 아니라 NULL(불일치)로 평가되어
--      review_image 검색에서 자동 제외된다(사양서 "post_channel IS NULL 인 옛 행은 판정
--      대상에서 제외" 요구사항 — 별도 IS NOT NULL 분기 없이 SQL NULL 비교 의미론으로 충족됨).
--   4. 그 외 거부 → reason='submission_deadline_passed'.
--
-- ▶ ★설계 보강 2 (사양서 문언 그대로라면 안 보이는 재제출 타이밍 문제 — 반드시 읽을 것)
--   사양서 §설계 1-(나) 3번을 "deliverables 테이블의 현재 status" 만으로 문자 그대로
--   구현하면(위 3번을 Tier 1 이라 부른다), review_image·post 는 실제로 마감 후 재제출이
--   막힌다 — 사양서가 의도한 것과 정반대다. 원인:
--     - review_image·post 의 재제출은 "새 행 INSERT"가 아니라 "기존 행을 draft 로
--       되돌리는 UPDATE"다(storage.js:1080-1142 insertDraftDeliverable, 채널당 1행
--       재사용 패턴 — 158 유니크 인덱스·2026-06-02 채널당 1건 정책).
--     - 인플루언서의 실제 조작은 항상 두 단계로 나뉜다: ①파일/URL 선택 즉시
--       insertDraftDeliverable 호출(rejected→draft, "임시 저장" 토스트) ②별도의
--       "提出" 버튼 클릭으로 submitDrafts 호출(draft→pending). 이 둘은 서로 다른
--       트랜잭션(별도의 statement)이다.
--     - ①이 실행되는 순간에는 그 행의 커밋된 상태가 아직 'rejected'(트리거는 실제
--       UPDATE 가 반영되기 전에 도는 BEFORE 트리거이므로) 이라 Tier 1 이 정확히
--       "rejected" 를 찾아 통과시킨다. 그런데 ①이 커밋되고 나면 그 행의 현재 상태는
--       'draft' 로 바뀌어 있다 — 즉 반려 흔적이 테이블에서 사라진다. ②가 나중에(같은
--       세션이라도 별도 요청으로) 실행될 때 Tier 1 이 "status<>'draft' 인 행"을 다시
--       찾으면 이제 아무 것도 없다(그 행 자신이 draft 이므로 제외됨) → 거부돼 버린다.
--       검증 시나리오 9("마감 후 리뷰 인증샷 A채널만 반려 → A 재제출 성공")를 실제로
--       끝까지(제출 버튼까지) 밀어붙이면 이 경로에서 반드시 재현된다.
--     - receipt 는 재제출이 "기존 행 UPDATE"가 아니라 "새 행 INSERT"라서(같은 파일
--       insertDraftDeliverable 의 receipt 분기는 기존 행을 찾지 않고 바로 INSERT) 이
--       문제가 없다 — 예전 rejected 행이 그대로 남아 있어 Tier 1 이 항상 찾아낸다.
--   해결(Tier 2, 위 SELECT 다음에 추가): Tier 1 이 아무 것도 못 찾았을 때만(=대상 행이
--   전부 draft 이거나 아예 없을 때만) deliverable_events 이력에서 "마지막 결정(승인 또는
--   반려) 이벤트"를 본다. 이게 가능한 이유: 073_fix_deliverable_event_trigger_for_draft.sql
--   이 "OLD 또는 NEW 가 draft 인 전이는 이벤트를 남기지 않는다"고 이미 정해 놨다 — 즉
--   ①(rejected→draft)도 ②(draft→pending)도 이벤트를 안 남기므로, 원래의 reject 결정
--   이벤트(pending→rejected, 어느 쪽도 draft 가 아니므로 정상 기록됨)가 그 사이에 지워지지
--   않고 "가장 최근 결정"으로 그대로 남아 있다. Tier 2 는 그 이벤트의 to_status 가
--   'rejected' 인지만 본다.
--     결정 2("최신 상태가 검수중·승인 이면 예외 없음")를 Tier 2 가 침해하지 않는 이유:
--     현재 상태가 'pending'(검수중) 또는 'approved'(승인) 이면 그 자체가 status<>'draft'
--     인 행이므로 Tier 1 이 먼저 답하고 Tier 2 까지 내려가지 않는다. Tier 2 는 오직
--     "현재 상태가 전부 draft(또는 무행)"일 때만 실행되므로 결정 2 의 "검수중·승인"
--     케이스와 겹치지 않는다.
--   ⚠️ 이 Tier 2 는 사양서 원문에 없는 추가 로직이다. 판정 결과(allowed/reason 최종값)는
--   사양서가 의도한 그대로("반려 건은 마감 후에도 재제출 가능") 만들기 위한 구현
--   디테일일 뿐, 판정 정책 자체를 바꾸지 않는다 — 대조 게이트(§설계 3-(2)) 실행 시
--   이 사실을 반드시 감안할 것(아래 "검증 순서" §D 참조, 화면 함수는 이 타이밍 문제를
--   애초에 모르므로 스냅샷 비교만으로는 이 경로가 드러나지 않는다 — 별도 시나리오로
--   직접 재현해야 한다).
--
-- ▶ 검사 장치가 이 함수만 호출하고 자체 판정을 두지 않는 이유
--   구조를 좁히는 순서(사양서 §설계 1-(나)):
--     1. auth.uid() IS NULL → 통과 (배치·마이그레이션·서비스 키. 익명 쓰기는
--        deliverables_insert_own/update_own_* 행 단위 보안 정책이 이미 차단해
--        도달 못 함 — 272 의 동일 논리 그대로)
--     2. is_admin() → 통과 (검수·되돌리기·대리 등록·게시물 교체 전부 면제 — 아래
--        "관리자 예외가 실제로 통하는 근거" 참조)
--     3. NEW.status NOT IN ('draft','pending') → 통과 (본인 제출 방향 연산이 아님)
--     4. 남은 것만 판정 함수 호출 — 거부 시 예외.
--
-- ▶ 관리자 예외가 실제로 통하는 근거 (조항별 확인 — 이 마이그레이션 작성 시 직접 추적)
--   - 승인·반려·되돌리기: dev/lib/storage.js updateDeliverableStatus() →
--     RPC update_deliverable_status(035, "IF NOT public.is_admin() THEN RAISE") →
--     내부에서 UPDATE public.deliverables ... 실행. SECURITY DEFINER 라도 auth.uid()
--     는 호출한 관리자 세션 그대로(권한 상승은 테이블 접근에만 적용, 세션 아이덴티티
--     함수는 안 바뀐다) → 이 UPDATE 가 트리거를 타도 2번 조항(is_admin())에서 즉시
--     통과. is_admin() 은 admins 테이블에 행이 있으면 role 무관 true 이므로
--     campaign_manager 도 여기까진 통과한다(아래 캠페인 매니저 항목 참조).
--   - 대리 등록·게시물 교체: RPC admin_create_deliverable_proxy(184, "IF NOT
--     public.is_campaign_admin() THEN RAISE ... 42501") 내부에서 UPDATE/INSERT.
--     is_campaign_admin() 을 통과한 사람은 admins 테이블 행이 있는 사람(campaign_admin
--     이상)이므로 반드시 is_admin() 도 true → 트리거 2번 조항에서 통과. 즉 이 RPC
--     자체의 상위 권한 가드가 이미 더 엄격해서, 트리거의 관대한 is_admin() 통과가
--     추가로 뚫는 구멍이 없다.
--   - campaign_manager: is_admin() 이 role 을 안 가리므로 트리거 검사 장치는
--     campaign_manager 도 면제한다. 그러나 admin_create_deliverable_proxy 는
--     is_campaign_admin() 을 요구해 campaign_manager 를 걸러낸다 — 즉 "검사 장치가
--     면제한다"가 "실제로 대리 등록이 가능하다"를 의미하지 않는다(사양서 §7 그대로).
--     campaign_manager 가 deliverables 를 직접 UPDATE 할 다른 경로는 코드베이스에
--     없음(admin.js/admin-deliverables.js 의 승인·반려 버튼도 전부 위 RPC 경유).
--
-- ▶ 감사용 계정(influencers.is_audit)과의 상호작용
--   is_admin() 은 admins 테이블만 보고 influencers.is_audit 은 보지 않는다 — 감사용
--   계정이 관리자 계정으로 별도 등록돼 있지 않은 한 일반 인플루언서와 동일하게 마감
--   후 제출이 차단된다(결정 7과 일치). 동일인이 관리자 계정으로 로그인한 동안은
--   2번 조항으로 통과하므로, 감사용 동선 확인은 관리자 권한 없는 계정으로 할 것
--   (사양서 §7과 동일 주의, 272 파일과 동일 문구).
--
-- ▶ 기존 deliverables 트리거 4개와의 관계 (전수 확인, 2026-07-30)
--   - trg_deliverables_updated_at (BEFORE UPDATE, 035) — updated_at 자동 갱신만.
--     이 트리거(BEFORE)가 예외를 던지면 트랜잭션이 즉시 중단돼 그 뒤 트리거는 아예
--     실행되지 않으므로 서로 간섭 없음. 이름 알파벳순으로는
--     "trg_deliverable_deadline_guard" 가 "trg_deliverables_updated_at" 보다 앞선다
--     ('deliverable' 다음 문자가 '_'(95) vs 's'(115), 언더스코어가 먼저 온다) — 순서가
--     결과에 영향을 주지 않으므로 의도적으로 맞추지는 않았다(272 는 마감 메시지
--     우선순위를 위해 의도적으로 이름을 골랐지만, 여기는 그럴 필요가 없다 — 아래
--     "동시 위반 시 메시지 우선순위" 참조).
--   - trg_deliverable_status_event (AFTER UPDATE, 035/073) — status 변경 이력 기록.
--     AFTER 트리거라 이 새 BEFORE 트리거가 거부하면 아예 실행되지 않는다. 정상
--     통과된 UPDATE 에 한해서만 동작하므로 영향 없음.
--   - trg_deliverable_notify (AFTER UPDATE, 037) — 인플루언서 알림 생성. 위와 동일 이유로
--     영향 없음.
--   - trg_receipts_to_deliverables (레거시 receipts 테이블 트리거, 035) — deliverables
--     가 아니라 receipts 테이블에 걸려 있어 이 마이그레이션과 무관.
--   - 마이그레이션 246/247(정산 자동 보류·송금완료 반려 차단)은 applications 테이블
--     트리거이지 deliverables 트리거가 아니다 — 확인 결과 간섭 없음.
--
-- ▶ 동시 위반 시 메시지 우선순위
--   deliverables 는 age_policy·monitor_slots 같은 "동시에 여러 사유로 거부될 수 있는"
--   다른 BEFORE INSERT 트리거가 없다(그 트리거들은 전부 applications 테이블 것).
--   이 트리거가 유일한 BEFORE 판정 트리거이므로 메시지 우선순위 문제 자체가 없다.
--
-- ▶ 취소 후 재응모 / 보관 삭제 캠페인과의 관계
--   취소 후 재응모는 applications 에 새 행을 만드는 것이고 deliverables 와는 무관 —
--   재응모한 새 신청에 대한 결과물 제출은 이 트리거를 정상적으로 그대로 탄다.
--   보관 삭제(soft delete)된 캠페인은 신청·결과물이 삭제 시점에 즉시 파기되므로
--   (CLAUDE.md "캠페인 삭제는 보관 삭제") 이 트리거가 평가할 행 자체가 존재하지 않는다.
--
-- ▶ 롤백
--   DROP TRIGGER IF EXISTS trg_deliverable_deadline_guard ON public.deliverables;
--   DROP FUNCTION IF EXISTS public.check_deliverable_deadline();
--   DROP FUNCTION IF EXISTS public.can_submit_deliverable(uuid, text, text);
--
-- ▶ 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md (2단계)
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. 판정 함수 — 단일 소스. 트리거·대조 게이트·(3단계) 화면이 전부 이것만 부른다.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.can_submit_deliverable(
  p_application_id uuid,
  p_kind           text,
  p_post_channel   text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_submission_end  date;
  v_today_kst       date;
  v_latest_status   text;
  v_hist_to_status  text;
BEGIN
  -- 0. 호출자 검증 (사양서에 없는 보강) — GRANT authenticated 라 아무 로그인 사용자나
  --    이 함수를 직접 부를 수 있다. 본인 신청이 아니면 다른 사람의 반려 이력 존재
  --    여부를 추론할 수 있게 되므로, 로그인 세션이면서 관리자가 아닌 경우 본인
  --    신청인지 확인한다. auth.uid() IS NULL(서비스 키·SQL Editor 대조 게이트 배치
  --    조회)과 관리자는 이 검사에서 제외(그 경로는 이미 신뢰된 컨텍스트).
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = p_application_id AND a.user_id = auth.uid()
    ) THEN
      RETURN jsonb_build_object('allowed', false, 'reason', 'permission_denied', 'submission_end', NULL);
    END IF;
  END IF;

  -- 1. 신청 → 캠페인 제출 마감일(submission_end) 조회
  SELECT c.submission_end
    INTO v_submission_end
    FROM public.applications a
    JOIN public.campaigns c ON c.id = a.campaign_id
   WHERE a.id = p_application_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('allowed', false, 'reason', 'application_not_found', 'submission_end', NULL);
  END IF;

  IF v_submission_end IS NULL THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'no_deadline', 'submission_end', NULL);
  END IF;

  -- 2. 일본 시각(Asia/Tokyo) 기준 오늘 <= 마감일이면 통과 — 마감일 당일 23:59:59(JST)까지
  --    허용(연령 정책 calc_age_kst·272 응모 마감 트리거와 동일 표현으로 통일).
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  IF v_today_kst <= v_submission_end THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'within_deadline', 'submission_end', v_submission_end);
  END IF;

  -- 3. 마감 후 — 반려 예외 판정 (Tier 1: deliverables 의 현재 상태 기준. 사양서 §설계
  --    1-(나) 3번 문구 그대로 — "최신 1건"은 status<>'draft' 인 행 중
  --    created_at DESC, id DESC 로 정렬한 첫 행). review_image 만 채널 단위로 좁히고
  --    (post_channel = p_post_channel — 옛 채널 미지정 행은 NULL 비교라 자동 제외),
  --    post 는 2단계까지 kind 단위(현행 화면 정책), receipt 는 채널 개념 없음.
  SELECT d.status
    INTO v_latest_status
    FROM public.deliverables d
   WHERE d.application_id = p_application_id
     AND d.kind = p_kind
     AND d.status <> 'draft'
     AND (p_kind <> 'review_image' OR d.post_channel = p_post_channel)
   ORDER BY d.created_at DESC, d.id DESC
   LIMIT 1;

  IF v_latest_status IS NOT NULL THEN
    IF v_latest_status = 'rejected' THEN
      RETURN jsonb_build_object('allowed', true, 'reason', 'rejected_exception', 'submission_end', v_submission_end);
    ELSE
      -- 최신 상태가 pending(검수중) 또는 approved(승인) — 결정 2 "예외 없음"
      RETURN jsonb_build_object('allowed', false, 'reason', 'submission_deadline_passed', 'submission_end', v_submission_end);
    END IF;
  END IF;

  -- 3-보강 (Tier 2: 이력 기반 폴백, 사양서에 없는 보강 — 파일 상단 "★설계 보강 2" 참조).
  --    Tier 1 이 대상 행을 하나도 못 찾았을 때만(=전부 draft 이거나 행 자체가 없을
  --    때만) 도달. review_image/post 는 재제출이 "같은 행을 draft 로 되돌리는
  --    UPDATE"라 반려 흔적이 현재 상태에서 사라지므로, deliverable_events 이력에서
  --    "가장 최근 결정(승인 또는 반려)"을 대신 본다. draft 가 관련된 전이는 애초에
  --    이벤트로 안 남으므로(073_fix_deliverable_event_trigger_for_draft.sql)
  --    원래의 reject 결정 이벤트가 지워지지 않고 남아 있다.
  SELECT e.to_status
    INTO v_hist_to_status
    FROM public.deliverable_events e
    JOIN public.deliverables d ON d.id = e.deliverable_id
   WHERE d.application_id = p_application_id
     AND d.kind = p_kind
     AND (p_kind <> 'review_image' OR d.post_channel = p_post_channel)
     AND e.to_status IN ('approved', 'rejected')
   ORDER BY e.created_at DESC
   LIMIT 1;

  IF v_hist_to_status = 'rejected' THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'rejected_exception_history', 'submission_end', v_submission_end);
  END IF;

  -- 4. 그 외 거부 — 반려 이력 자체가 없는 신규 제출(§7 "마감 후 남은 임시저장"
  --    포함)이거나, 마지막 결정이 approved 인 경우.
  RETURN jsonb_build_object('allowed', false, 'reason', 'submission_deadline_passed', 'submission_end', v_submission_end);
END;
$$;

COMMENT ON FUNCTION public.can_submit_deliverable(uuid, text, text) IS
  '[274] 결과물(deliverables) 제출 가부 판정 — 단일 소스. 마감 전이면 통과, 마감 후엔
   "최신 비-draft 행이 rejected"(Tier 1) 또는 그마저 전부 draft 면 이력상 마지막 결정이
   reject(Tier 2, review_image/post 재제출의 draft 플립 타이밍 보강)일 때만 예외 통과.
   화면(3단계)·트리거·대조 게이트가 전부 이 함수 하나만 소비해야 한다(직접 재구현 금지).
   사양서 docs/specs/2026-07-29-deadline-server-enforcement.md 2단계.';

REVOKE ALL ON FUNCTION public.can_submit_deliverable(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_submit_deliverable(uuid, text, text) TO authenticated;


-- ────────────────────────────────────────────────────────────
-- 2. 검사 장치 — deliverables BEFORE INSERT OR UPDATE. 자체 판정 없이 위 함수만 호출.
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.check_deliverable_deadline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb;
BEGIN
  -- 1. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (익명 쓰기는 deliverables_insert_own/update_own_* 행 단위 보안 정책에서
  --     이미 차단되어 여기까지 도달하지 못한다 — 272 와 동일 논리)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- 2. 관리자(모든 role) — 검수·되돌리기·대리 등록·게시물 교체 전부 면제.
  --    실제로 뚫리지 않는 근거는 파일 상단 "관리자 예외가 실제로 통하는 근거" 참조.
  IF public.is_admin() THEN
    RETURN NEW;
  END IF;

  -- 3. NEW.status 가 draft/pending 이 아니면(=본인이 만드는 "제출 방향" 연산이 아니면)
  --    통과. 여기 도달했다는 것 자체가 RLS 구조상 이례적이지만(2번에서 관리자가 이미
  --    걸러졌으므로 본인 계정으로 approved/rejected 를 만들 방법이 없다) 방어적으로 둔다.
  IF NEW.status NOT IN ('draft', 'pending') THEN
    RETURN NEW;
  END IF;

  -- 4. 판정 함수 호출 — 자체 판정 로직 없음(단일 소스 원칙, 사양서 §설계 3).
  v_result := public.can_submit_deliverable(NEW.application_id, NEW.kind, NEW.post_channel);

  IF COALESCE((v_result->>'allowed')::boolean, false) THEN
    RETURN NEW;
  END IF;

  -- 머신 판독용 코드 접두어 — dev/js/ui.js friendlyErrorJa() 가 이미 이 문자열을
  -- 정규식으로 매칭하도록 배선돼 있다(2026-07-30 확인, _ERR_DICT.submissionDeadlinePassed
  -- + /submission_deadline_passed/ 정규식 — 이 마이그레이션 작성 시점에 이미 존재).
  RAISE EXCEPTION 'submission_deadline_passed: 제출 기한이 지났습니다'
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION public.check_deliverable_deadline() IS
  '[274] 결과물 제출 마감 차단 트리거 함수. BEFORE INSERT OR UPDATE ON deliverables.
   판정: auth.uid() NULL 통과 → is_admin() 통과 → NEW.status NOT IN (draft,pending)
   통과 → can_submit_deliverable() 호출, 거부 시 ''submission_deadline_passed: ...''
   예외(ERRCODE P0001). 사양서 docs/specs/2026-07-29-deadline-server-enforcement.md 2단계.';

DROP TRIGGER IF EXISTS trg_deliverable_deadline_guard ON public.deliverables;
CREATE TRIGGER trg_deliverable_deadline_guard
  BEFORE INSERT OR UPDATE ON public.deliverables
  FOR EACH ROW
  EXECUTE FUNCTION public.check_deliverable_deadline();

COMMIT;

-- ============================================================
-- (A) 대조 게이트용 조회문 (§설계 3-(2) "집합 A") — 배포 직전, SQL Editor 에서 실행
--     승인 신청 × 필요한 kind 전개(리뷰 인증샷은 캠페인 채널별로) 후 판정 함수 호출.
--     결과를 (B)의 "집합 B"(화면 함수 복사본으로 만든 결과)와 A EXCEPT B / B EXCEPT A
--     로 대조한다. 양쪽 0행이어야 배포 가능.
-- ============================================================
-- WITH approved_apps AS (
--   SELECT a.id AS application_id, a.campaign_id,
--          c.recruit_type, c.proxy_purchase, c.channel
--     FROM public.applications a
--     JOIN public.campaigns c ON c.id = a.campaign_id
--    WHERE a.status = 'approved'
-- ),
-- required_items AS (
--   -- receipt: monitor(리뷰어형) 전체 — 가구매(proxy_purchase) 여부 무관, 영수증은 항상 필요
--   SELECT application_id, 'receipt'::text AS kind, NULL::text AS channel
--     FROM approved_apps
--    WHERE recruit_type = 'monitor'
--   UNION ALL
--   -- review_image: monitor 이면서 가구매가 아닐 때만, 캠페인 채널별로 전개
--   SELECT application_id, 'review_image'::text AS kind, trim(ch) AS channel
--     FROM approved_apps, unnest(string_to_array(channel, ',')) AS ch
--    WHERE recruit_type = 'monitor' AND COALESCE(proxy_purchase, false) = false
--   UNION ALL
--   -- post: gifting/visit(시딩·방문형), 캠페인 채널별로 전개
--   SELECT application_id, 'post'::text AS kind, trim(ch) AS channel
--     FROM approved_apps, unnest(string_to_array(channel, ',')) AS ch
--    WHERE recruit_type IN ('gifting', 'visit')
-- )
-- SELECT
--   application_id,
--   kind,
--   channel,
--   (public.can_submit_deliverable(application_id, kind, channel)->>'allowed')::boolean AS allowed
-- FROM required_items
-- ORDER BY application_id, kind, channel;
--
-- ⚠️ 위 쿼리는 SQL Editor(서비스 키, auth.uid() IS NULL)에서 실행할 것 — 그래야
--    can_submit_deliverable 내부 0번 "호출자 검증"이 통과 조항(auth.uid() IS NULL)으로
--    빠져 모든 신청을 조회할 수 있다.
--
-- ============================================================
-- (B) 동률 행 탐지 조회문 (§설계 3-(3) "동률이면 수동 확인") — 대조 전 별도 실행
--     같은 신청·같은 kind(·채널) 안에서 created_at 이 완전히 같은 비-draft 행이
--     2개 이상이면 "최신 1건" 판정이 화면(동률 규칙 없음)과 서버(id DESC 로 확정)
--     사이에서 갈릴 수 있다 — 이런 건은 (A)/(B) 대조에서 "불일치"로 세지 말고 여기서
--     따로 뽑아 수동 확인한다.
-- ============================================================
-- SELECT application_id, kind, post_channel, created_at, COUNT(*) AS tie_count,
--        array_agg(id ORDER BY id) AS ids,
--        array_agg(status ORDER BY id) AS statuses
--   FROM public.deliverables
--  WHERE status <> 'draft'
--  GROUP BY application_id, kind, post_channel, created_at
-- HAVING COUNT(*) > 1
--  ORDER BY application_id, kind, post_channel;
--
-- ============================================================
-- 검증 쿼리 (SQL Editor — 아래를 1단계씩 순서대로 실행. 결과 확인 후 다음 단계)
-- ============================================================
--
-- 1단계 — 함수·트리거 존재 확인:
--   SELECT p.proname, p.prosecdef, p.provolatile,
--          t.tgname, t.tgenabled
--     FROM pg_proc p
--     LEFT JOIN pg_trigger t ON t.tgfoid = p.oid
--    WHERE p.proname IN ('can_submit_deliverable', 'check_deliverable_deadline')
--      AND p.pronamespace = 'public'::regnamespace;
--   → can_submit_deliverable: prosecdef=true, provolatile='s'(stable), tgname NULL(트리거 아님)
--   → check_deliverable_deadline: prosecdef=true, tgname='trg_deliverable_deadline_guard', tgenabled='O'
--
-- 2단계 — deliverables 트리거 전체 목록 확인 (간섭 재확인):
--   SELECT tgname, tgtype
--     FROM pg_trigger
--    WHERE tgrelid = 'public.deliverables'::regclass
--      AND NOT tgisinternal
--    ORDER BY tgname;
--   → trg_deliverable_deadline_guard(신규), trg_deliverable_notify,
--     trg_deliverable_status_event, trg_deliverables_updated_at 4행 기대
--
-- 3단계 — 판정 함수 단독 호출 스모크 테스트 (서비스 키, 부작용 없음 — SELECT 전용):
--   -- 마감이 지난 캠페인의 승인된 신청 하나를 확인해 둔다:
--   SELECT a.id AS application_id, c.title, c.submission_end, a.status
--     FROM public.applications a
--     JOIN public.campaigns c ON c.id = a.campaign_id
--    WHERE a.status = 'approved'
--      AND c.submission_end < (now() AT TIME ZONE 'Asia/Tokyo')::date
--    LIMIT 1;
--   -- 그 application_id 로 (필요한 kind 는 캠페인 recruit_type 에 맞춰):
--   SELECT public.can_submit_deliverable('<application_id>'::uuid, 'receipt', NULL);
--   → {"allowed": false, "reason": "submission_deadline_passed", "submission_end": "..."}
--     (그 신청에 반려 이력이 없다면). 반려 이력이 있는 신청으로 테스트하면
--     {"allowed": true, "reason": "rejected_exception", ...} 이어야 함.
--
-- 4단계 — 실제 차단 확인 (안전한 방법: 반드시 ROLLBACK)
--   ⚠️ SQL Editor 는 서비스 키 세션이라 auth.uid() 가 NULL 로 통과되어 이 트리거를
--      있는 그대로 재현하지 못한다(272 와 동일 제약). 아래 두 방법 중 하나로 확인:
--
--   방법 1 (권장) — 개발서버에 실제 로그인한 인플루언서 브라우저에서, 마감 지난
--   캠페인의 승인된 자기 응모의 활동관리 화면에 진입해 새 결과물을 제출/재제출해 본다.
--
--   방법 2 — SQL Editor 에서 request.jwt.claims 를 흉내내 auth.uid() 를 설정(272 와 동일 패턴):
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 auth_id>')::text, true);
--     -- 반려 이력이 없는 신규 draft 시도 — 거부돼야 함:
--     INSERT INTO public.deliverables (application_id, user_id, campaign_id, kind, status, receipt_url)
--     VALUES ('<마감 지난 승인 신청 id>'::uuid, '<테스트 인플루언서 auth_id>'::uuid,
--             '<캠페인 id>'::uuid, 'receipt', 'draft', 'https://example.com/test.jpg');
--     -- 기대: ERROR: submission_deadline_passed: 제출 기한이 지났습니다
--   ROLLBACK;
--   ⚠️ 실행 후 반드시 ROLLBACK 해서 검증용 행이 남지 않게 할 것.
-- ============================================================
