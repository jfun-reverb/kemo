-- ============================================================
-- 276_deliverable_gate_batch_and_post_channel_exception.sql
-- 3단계 (1/2) — 화면 판정을 서버 판정으로 일원화하기 위한 배치 조회 함수 신설
-- 3단계 (2/2) — 게시물(post) 반려 예외를 종류 단위 → 채널 단위로 전환
-- 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md (§설계 3-(1), §설계 4)
--
-- ▶ 재정의 베이스 확인 (feedback_function_redefine_latest_base 메모리 규칙)
--   grep -l "FUNCTION public.can_submit_deliverable" supabase/migrations/*.sql
--     → 274_deliverable_deadline_guard.sql 단 1곳. 274 가 "가장 큰 번호의 정의" ==
--       "유일한 정의". 이 파일은 274 의 can_submit_deliverable 본문을 베이스로
--       CREATE OR REPLACE 한다 — Tier 1 호출자 검증 + Tier 2 이력 폴백을 그대로 유지한다
--       (아래 "274 대비 diff" 참조. 빠뜨리면 마감 후 review_image·post 재제출이
--       다시 막히는 회귀가 재발한다 — 274 파일 상단 "★설계 보강 2" 참고).
--
-- ▶ 만든 것 2가지
--   1. 배치 조회 함수 public.get_deliverable_gate(p_application_id uuid)
--      → 그 신청에 필요한 항목(영수증/채널별 게시물/채널별 리뷰 인증샷) 전부를
--        한 번의 호출로 반환. 화면(3단계)이 활동관리 진입 시 1회 호출해 폼 게이팅·
--        제출 버튼 노출을 전부 이 결과로 결정한다(사양서 §설계 3-(1)).
--   2. public.can_submit_deliverable() 재정의 — 'post' 의 반려 예외 판정을
--      review_image 와 동일하게 "같은 post_channel" 조건으로 좁힌다(사양서 §설계 4).
--      트리거 check_deliverable_deadline() 은 이 함수만 호출하므로 트리거 자체는
--      재정의하지 않아도 채널 단위가 자동 적용된다(아래 "트리거 재정의 불필요" 참조).
--
-- ────────────────────────────────────────────────────────────
-- (A) can_submit_deliverable — 274 대비 diff (변경 지점은 이것뿐)
-- ────────────────────────────────────────────────────────────
--   274 (2단계, 현행 화면 정책 그대로):
--     Tier 1: AND (p_kind <> 'review_image' OR d.post_channel = p_post_channel)
--     Tier 2: AND (p_kind <> 'review_image' OR d.post_channel = p_post_channel)
--     → 'post' 는 채널 무시, 캠페인 안의 아무 채널 게시물이나 반려면 전체 재제출 허용
--
--   276 (3단계, §설계 4 — 채널 단위 전환):
--     Tier 1: AND (p_kind NOT IN ('review_image','post') OR d.post_channel = p_post_channel)
--     Tier 2: AND (p_kind NOT IN ('review_image','post') OR d.post_channel = p_post_channel)
--     → 'post' 도 review_image 와 동일하게 "같은 채널" 행만 본다. 인스타그램 게시물이
--       반려됐으면 인스타그램만 마감 후 재제출 가능, 틱톡 신규 제출은 차단(검증
--       시나리오 10, 사양서 §검증 계획).
--
--   ⚠️ Tier 2(이력 폴백)는 그대로 유지 — 삭제·축소하지 않음. review_image·post 는
--   재제출이 "새 행 INSERT" 가 아니라 "기존 행을 draft 로 되돌리는 UPDATE" 라서
--   (storage.js insertDraftDeliverable, 채널당 1행 재사용), Tier 1 만으로는 반려
--   흔적이 draft 플립 순간 사라진다 — 274 파일 상단 "★설계 보강 2" 전체 설명을
--   그대로 재사용(로직 무변경, 필터 조건만 review_image→'review_image','post' 로 확장).
--   그 외(호출자 검증·no_deadline·within_deadline·거부 사유 코드)는 274 와 완전히 동일.
--
-- ▶ 기존 데이터에 미치는 영향 — post_channel 이 NULL 인 옛 post 행
--   'post' 에는 review_image 의 158 유니크 인덱스(app+kind+channel) 같은 채널별
--   1건 강제가 DB 레벨엔 없다(035 의 uidx_deliverables_post_url 은 URL 중복
--   방지일 뿐, 채널 유니크가 아니다) — 채널당 1건은 어디까지나 앱 레벨 정책
--   (insertDraftDeliverable 이 같은 채널 행을 찾아 UPDATE, 2026-06-02 정책).
--   즉 그 정책 이전에 만들어진 레거시 post 행은 post_channel 이 NULL 일 수 있다.
--   274 의 review_image 와 동일한 SQL NULL 비교 의미론(NULL = 'instagram' → NULL,
--   즉 불일치로 평가)으로 이런 행은 어떤 채널의 "최신 1건"에도 안 잡혀 판정
--   대상에서 자동 제외된다 — 즉 "그 행이 rejected 였어도 채널 예외 대상이 되지
--   못한다"는 뜻. 250_count_pending_review_post_channel_agnostic.sql 이 이미
--   "관리자 목록 표시는 post 를 채널 무관 신청당 최신 1건으로 본다"는 별개
--   맥락(집계용 요약 표시)을 남겼지만, 그것은 이 판정 함수의 채널 예외 로직과는
--   무관하다(다른 목적의 다른 코드) — 혼동 주의.
--   ▶ 배포 전 확인할 조회문(개발·운영 각각, SQL Editor):
--     -- 1) channel NULL 인 post 행이 얼마나 있는지
--     SELECT count(*) FROM public.deliverables
--      WHERE kind = 'post' AND post_channel IS NULL;
--     -- 2) 그중 "반려가 최신 상태"인 행 — 채널 전환으로 예외 자격을 잃는 후보
--     SELECT d.id, d.application_id, d.status, d.created_at
--       FROM public.deliverables d
--      WHERE d.kind = 'post' AND d.post_channel IS NULL AND d.status = 'rejected'
--        AND d.created_at = (
--          SELECT max(d2.created_at) FROM public.deliverables d2
--           WHERE d2.application_id = d.application_id AND d2.kind = 'post'
--             AND d2.status <> 'draft'
--        );
--     -- 3) 그 신청들의 캠페인이 이미 마감(submission_end 경과)인지까지 좁히면
--     --    "3단계 배포 직후 실제로 재제출이 막히는" 진짜 영향 범위가 나온다:
--     SELECT d.application_id, c.submission_end
--       FROM public.deliverables d
--       JOIN public.applications a ON a.id = d.application_id
--       JOIN public.campaigns c ON c.id = a.campaign_id
--      WHERE d.kind = 'post' AND d.post_channel IS NULL AND d.status = 'rejected'
--        AND c.submission_end < (now() AT TIME ZONE 'Asia/Tokyo')::date;
--   결과가 0건이면(2단계 배포 전 실측처럼) 영향 없이 전환 가능. 0건이 아니면 그
--   신청 건들은 관리자 대리 등록으로 구제(사양서 §7 "마감 후 남은 임시저장"과 동일 원칙).
--
-- ────────────────────────────────────────────────────────────
-- (B) get_deliverable_gate — 반환 형태 선택 근거
-- ────────────────────────────────────────────────────────────
--   RETURNS TABLE(kind text, post_channel text, allowed boolean, reason text,
--                 submission_end date) 로 결정 — jsonb_agg 로 단일 jsonb 배열을
--   만드는 대안도 검토했으나 TABLE 을 택한 이유:
--     - PostgREST 는 SETOF/TABLE 함수를 호출하면 이미 "행 배열"(JS 배열의 순수
--       객체들)로 응답한다 — jsonb_agg 로 감싸 다시 순회하며 필드를 꺼낼 필요가
--       없다. supabase-js 쪽에서는 `data`가 바로
--       `[{kind,post_channel,allowed,reason,submission_end}, ...]` 이다.
--     - 각 필드가 실제 타입(boolean/date)으로 오므로 화면에서 문자열을 다시
--       파싱(`row.allowed === 'true'` 같은 실수)할 여지가 없다. jsonb 배열이면
--       내부 값도 전부 jsonb 이므로 boolean 캐스팅을 화면이 직접 해야 한다.
--     - 대조 게이트(2단계에서 이미 쓰던 SELECT 문 형태)와 결과 스키마가 그대로
--       호환된다 — 274 파일 하단 "(A) 대조 게이트용 조회문"의 컬럼 구성과 동일.
--
-- ▶ 항목 전개 규칙 (사양서 §설계 3-(1), admin-deliverables.js 의 실제 조건과 정합
--   확인 — renderDelivResultCellMonitor:757-759, application.js:988)
--     - recruit_type = 'monitor' :
--         · receipt 1건 (channel 없음) — proxy_purchase 여부 무관, 항상 필요
--         · review_image, 캠페인 channel 개수만큼 — 단, proxy_purchase=true 이거나
--           channel 이 비어 있는(레거시) 캠페인은 review_image 자체를 요구하지 않음
--     - recruit_type IN ('gifting','visit') :
--         · post, 캠페인 channel 개수만큼 (channel 이 비어 있으면 0건)
--     - 그 외 recruit_type(방어적 — 현재 코드베이스엔 이 두 갈래 외 값 없음): 0건
--   channel 은 campaigns.channel 콤마 구분 문자열을 split→trim→빈 문자열 제외.
--
-- ▶ 보안 — 본인 신청만 조회 가능 (can_submit_deliverable 274 의 "0. 호출자 검증"과
--   동일 원칙을 함수 진입점에서 한 번만 수행 — 항목별로 중복 검증하지 않음).
--   auth.uid() IS NULL(서비스 키·SQL Editor 배치 조회)과 is_admin() 은 예외.
--   위반 시 42501 로 즉시 예외(개별 행마다 permission_denied 를 조용히 섞어
--   내려보내는 대신, 배치 함수 레벨에서 한 번에 명확히 거부 — get_deliverable_gate
--   는 "그 신청 전체"에 대한 조회이므로 부분 허용이 의미가 없다).
--
-- ▶ 가구매·리뷰어·시딩·방문형 4형식 반환 예시
--   - 가구매(monitor, proxy_purchase=true, channel='instagram,tiktok') → 1행
--       [{kind:'receipt', post_channel:null, ...}]
--   - 리뷰어(monitor, proxy_purchase=false, channel='instagram,tiktok') → 3행
--       [{kind:'receipt', post_channel:null, ...},
--        {kind:'review_image', post_channel:'instagram', ...},
--        {kind:'review_image', post_channel:'tiktok', ...}]
--   - 리뷰어(monitor, channel='' — 레거시 무채널) → 1행 (receipt 만, review_image 없음)
--   - 시딩(gifting, channel='instagram,x') → 2행
--       [{kind:'post', post_channel:'instagram', ...},
--        {kind:'post', post_channel:'x', ...}]
--   - 방문형(visit, channel='instagram') → 1행 [{kind:'post', post_channel:'instagram', ...}]
--   - (방어적) channel 이 완전히 빈 gifting/visit → 0행. 이런 캠페인은 현재
--     캠페인 등록 폼에서 만들 수 없지만(채널 필수 선택), 데이터 방어 차원.
--
-- ▶ 트리거(check_deliverable_deadline) 재정의 필요 여부 — 필요 없음
--   274 의 트리거 함수는 자체 판정 로직 없이 `public.can_submit_deliverable(
--   NEW.application_id, NEW.kind, NEW.post_channel)` 한 줄만 호출한다(274:310).
--   post 행의 UPDATE/INSERT 도 NEW.post_channel 을 이미 그대로 넘기고 있었으므로
--   (274 는 kind 를 안 가리고 항상 post_channel 을 전달했다 — 단지 함수 내부에서
--   'post' 일 때 그 값을 안 썼을 뿐), 함수 내부의 필터 조건만 바뀌면 호출부
--   변경 없이 채널 단위가 그대로 적용된다. CREATE OR REPLACE 로 트리거 함수를
--   다시 선언할 이유가 없다(로직도 텍스트도 무변경이므로 재실행 자체가 무의미).
--
-- ▶ 화면(3단계) 소비 방법 — 메인 세션이 dev/js/application.js 를 수정할 때 참고용
--   (이 마이그레이션 파일은 dev/ 를 건드리지 않는다. 아래는 안내만)
--   - 활동관리 진입 시(현재 데이터 로드 직후 applyFormGating(all) 을 호출하는 지점,
--     application.js:1005 부근) `await db.rpc('get_deliverable_gate', {
--     p_application_id: applicationId })` 1회 호출.
--   - 반환된 행 배열을 kind(+post_channel) 로 찾아 폼 활성/비활성·안내 문구를
--     결정 — `_latestNonDraftIsRejected()`(application.js:1010)와 그 소비부인
--     `applyFormGating()`(application.js:1022)을 이 결과로 대체하고
--     `_latestNonDraftIsRejected` 자체는 삭제(사양서 §설계 3-(1) "이중 구현 금지").
--   - review_image 채널별 카드(renderActivityReviewImageList, application.js:1165)는
--     이미 채널 단위라 kind='review_image' 이고 post_channel 이 일치하는 행을 찾으면
--     그대로 대응된다. post 카드(renderActivityPostList)는 지금은 종류 단위로만
--     게이팅했으므로, 이 3단계에서 채널별로 나눠 각 채널 폼을 개별 비활성화하도록
--     함께 손봐야 한다(§설계 4의 "인스타그램만 재제출 가능·틱톡은 차단" UI 반영).
--   - 조회 실패(네트워크 오류 등) 시에는 화면에 판정 로직을 되살리지 말고 폼을
--     열어 둘 것(사양서 §설계 3-(1) "조회 실패 시…막지 않는다" — 최종 방어선은
--     여전히 트리거).
--   - 죽은 함수 storage.js insertPostDeliverable()(호출부 0건, 사양서 3단계 항목)의
--     정리도 이번 3단계 작업 범위 — 이 마이그레이션과는 무관한 dev/ 쪽 정리.
--
-- ▶ 롤백
--   -- get_deliverable_gate 제거:
--   DROP FUNCTION IF EXISTS public.get_deliverable_gate(uuid);
--   -- can_submit_deliverable 을 274 시점(post 채널 무시)으로 되돌리려면 274 파일의
--   -- CREATE OR REPLACE FUNCTION 블록을 그대로 재실행할 것(본 파일이 아래 diff만
--   -- 바꿨으므로 274 원본 재실행이 정확한 롤백이다).
--
-- ▶ 사양서: docs/specs/2026-07-29-deadline-server-enforcement.md (3단계)
-- ============================================================

BEGIN;

-- ────────────────────────────────────────────────────────────
-- 1. can_submit_deliverable 재정의 — 'post' 반려 예외를 채널 단위로 전환
--    (274 본문 그대로 + 아래 표시한 2줄만 변경. 그 외 전부 동일)
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
  -- 0. 호출자 검증 (274 와 동일 — 본인 신청만 조회 가능. 다른 사람의 반려 이력
  --    존재 여부를 추론당하지 않도록 함)
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = p_application_id AND a.user_id = auth.uid()
    ) THEN
      RETURN jsonb_build_object('allowed', false, 'reason', 'permission_denied', 'submission_end', NULL);
    END IF;
  END IF;

  -- 1. 신청 → 캠페인 제출 마감일(submission_end) 조회 (274 와 동일)
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

  -- 2. 일본 시각(Asia/Tokyo) 기준 오늘 <= 마감일이면 통과 (274 와 동일)
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;
  IF v_today_kst <= v_submission_end THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'within_deadline', 'submission_end', v_submission_end);
  END IF;

  -- 3. 마감 후 — 반려 예외 판정 (Tier 1: 현재 status 기준).
  --    ★ 276 변경점 — review_image 만 채널 단위였던 것을 post 도 포함하도록 확장.
  --    post_channel IS NULL 인 옛 행은 NULL = p_post_channel 비교가 항상 NULL(불일치)로
  --    평가되어 review_image 와 동일하게 자동 제외된다(파일 상단 "기존 데이터에
  --    미치는 영향" 참조).
  SELECT d.status
    INTO v_latest_status
    FROM public.deliverables d
   WHERE d.application_id = p_application_id
     AND d.kind = p_kind
     AND d.status <> 'draft'
     AND (p_kind NOT IN ('review_image', 'post') OR d.post_channel = p_post_channel)
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

  -- 3-보강 (Tier 2: 이력 기반 폴백 — 274 「★설계 보강 2」 전체 설명 그대로 유지,
  --    필터 조건만 review_image→'review_image','post' 로 확장). Tier 1 이 대상 행을
  --    하나도 못 찾았을 때만(=전부 draft 이거나 행 자체가 없을 때만) 도달한다.
  --    review_image·post 의 재제출은 "같은 행을 draft 로 되돌리는 UPDATE" 라 반려
  --    흔적이 현재 상태에서 사라지므로, deliverable_events 이력에서 "가장 최근
  --    결정(승인 또는 반려)"을 대신 본다. draft 가 관련된 전이는 이벤트로 안
  --    남으므로(073) 원래의 reject 결정 이벤트가 지워지지 않고 남아 있다.
  SELECT e.to_status
    INTO v_hist_to_status
    FROM public.deliverable_events e
    JOIN public.deliverables d ON d.id = e.deliverable_id
   WHERE d.application_id = p_application_id
     AND d.kind = p_kind
     AND (p_kind NOT IN ('review_image', 'post') OR d.post_channel = p_post_channel)
     AND e.to_status IN ('approved', 'rejected')
   ORDER BY e.created_at DESC
   LIMIT 1;

  IF v_hist_to_status = 'rejected' THEN
    RETURN jsonb_build_object('allowed', true, 'reason', 'rejected_exception_history', 'submission_end', v_submission_end);
  END IF;

  -- 4. 그 외 거부 (274 와 동일)
  RETURN jsonb_build_object('allowed', false, 'reason', 'submission_deadline_passed', 'submission_end', v_submission_end);
END;
$$;

COMMENT ON FUNCTION public.can_submit_deliverable(uuid, text, text) IS
  '[276] 결과물(deliverables) 제출 가부 판정 — 단일 소스. 마감 전이면 통과, 마감 후엔
   "최신 비-draft 행이 rejected"(Tier 1, review_image·post 는 채널 단위) 또는 그마저
   전부 draft 면 이력상 마지막 결정이 reject(Tier 2)일 때만 예외 통과. post 반려 예외를
   274(kind 단위) → 276(채널 단위)로 전환(사양서 §설계 4, 3단계). 화면·트리거·대조
   게이트가 전부 이 함수 하나만 소비해야 한다(직접 재구현 금지).
   사양서 docs/specs/2026-07-29-deadline-server-enforcement.md 3단계.';

REVOKE ALL ON FUNCTION public.can_submit_deliverable(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.can_submit_deliverable(uuid, text, text) TO authenticated;


-- ────────────────────────────────────────────────────────────
-- 2. 배치 조회 함수 — 화면이 활동관리 진입 시 1회 호출해 그 신청에 필요한
--    항목 전체의 판정을 받는다 (사양서 §설계 3-(1)).
-- ────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_deliverable_gate(
  p_application_id uuid
)
RETURNS TABLE (
  kind           text,
  post_channel   text,
  allowed        boolean,
  reason         text,
  submission_end date
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type   text;
  v_proxy_purchase boolean;
  v_channel        text;
  v_channels       text[];
BEGIN
  -- 0. 호출자 검증 — 본인 신청 전체 조회이므로 can_submit_deliverable 처럼 항목별로
  --    조용히 permission_denied 를 섞어 내려보내지 않고, 함수 진입점에서 한 번에
  --    명확히 거부한다. auth.uid() IS NULL(서비스 키·SQL Editor)과 관리자는 예외.
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = p_application_id AND a.user_id = auth.uid()
    ) THEN
      RAISE EXCEPTION 'permission_denied: 본인 신청만 조회할 수 있습니다'
        USING ERRCODE = '42501';
    END IF;
  END IF;

  -- 1. 캠페인 정보 조회 (recruit_type/proxy_purchase/channel — 항목 전개 기준)
  SELECT c.recruit_type, c.proxy_purchase, c.channel
    INTO v_recruit_type, v_proxy_purchase, v_channel
    FROM public.applications a
    JOIN public.campaigns c ON c.id = a.campaign_id
   WHERE a.id = p_application_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'application_not_found: 신청 정보를 찾을 수 없습니다'
      USING ERRCODE = 'P0001';
  END IF;

  -- 캠페인 channel 콤마 구분 문자열 → 배열 (trim + 빈 문자열 제외).
  -- string_to_array('', ',') 는 빈 배열을 반환하므로(PostgreSQL 문서) channel 이
  -- NULL/빈 문자열이면 v_channels 도 빈 배열이 된다.
  SELECT COALESCE(array_agg(t) FILTER (WHERE t <> ''), ARRAY[]::text[])
    INTO v_channels
    FROM (
      SELECT trim(x) AS t
        FROM unnest(string_to_array(COALESCE(v_channel, ''), ',')) AS x
    ) s;

  -- 2. 항목 전개 (사양서 §설계 3-(1), admin-deliverables.js 실제 조건과 정합)
  IF v_recruit_type = 'monitor' THEN
    -- 영수증 1건 — proxy_purchase 여부 무관, 리뷰어형은 항상 필요
    RETURN QUERY
      SELECT 'receipt'::text, NULL::text,
             (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
        FROM public.can_submit_deliverable(p_application_id, 'receipt', NULL) AS r;

    -- 채널별 리뷰 인증샷 — 가구매(proxy_purchase) 또는 채널 없는 레거시 monitor 는
    -- 요구하지 않음 (admin-deliverables.js:757-759, application.js:988 과 동일 조건)
    IF NOT COALESCE(v_proxy_purchase, false) AND array_length(v_channels, 1) > 0 THEN
      RETURN QUERY
        SELECT 'review_image'::text, ch,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM unnest(v_channels) AS ch
          CROSS JOIN LATERAL public.can_submit_deliverable(p_application_id, 'review_image', ch) AS r;
    END IF;

  ELSIF v_recruit_type IN ('gifting', 'visit') THEN
    -- 채널별 게시물
    IF array_length(v_channels, 1) > 0 THEN
      RETURN QUERY
        SELECT 'post'::text, ch,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM unnest(v_channels) AS ch
          CROSS JOIN LATERAL public.can_submit_deliverable(p_application_id, 'post', ch) AS r;
    END IF;

    -- ★ 방문형(visit)은 **현장 사진(receipt)도 제출한다** (2026-07-30 리뷰에서 누락 발견).
    --   화면이 showImage = (rt === 'monitor' || rt === 'visit') 로 영수증 폼을 띄우고
    --   addDraftImage() 가 recruit_type 과 무관하게 kind='receipt' 로 저장하기 때문이다.
    --   이 행을 안 내보내면 화면이 「항목 없음 = 통과」로 처리해 마감 후에도 폼이 열리고,
    --   제출하면 트리거가 거부한다 — 3단계가 없애려던 바로 그 「화면은 열렸는데 서버가 거부」다.
    --   ⚠️ 인증 성공 판정(computeCertStatus)이 방문형에서 영수증을 안 보는 것과는 **다른 축**이다.
    --      그건 「인증 성공의 정의」이고 이건 「제출 가능 여부」다.
    IF v_recruit_type = 'visit' THEN
      RETURN QUERY
        SELECT 'receipt'::text, NULL::text,
               (r->>'allowed')::boolean, r->>'reason', (r->>'submission_end')::date
          FROM public.can_submit_deliverable(p_application_id, 'receipt', NULL) AS r;
    END IF;
  END IF;
  -- 그 외 recruit_type(방어적 — 현재 값 2종 외 없음): 0행 반환

  RETURN;
END;
$$;

COMMENT ON FUNCTION public.get_deliverable_gate(uuid) IS
  '[276] 결과물 제출 가부 배치 조회 — 신청 1건에 필요한 항목(영수증/채널별 게시물/
   채널별 리뷰 인증샷) 전부를 can_submit_deliverable() 호출로 모아 반환. 화면(3단계)이
   활동관리 진입 시 1회 호출해 폼 게이팅·제출 버튼 노출을 이 결과로 결정한다
   (이중 구현 금지, 사양서 §설계 3). 본인 신청 또는 관리자만 호출 가능(42501).
   사양서 docs/specs/2026-07-29-deadline-server-enforcement.md 3단계.';

REVOKE ALL ON FUNCTION public.get_deliverable_gate(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_deliverable_gate(uuid) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 쿼리 (SQL Editor — 아래를 1단계씩 순서대로 실행. 결과 확인 후 다음 단계)
-- ============================================================
--
-- 1단계 — 함수 존재·시그니처 확인:
--   SELECT proname, prosecdef, provolatile, pronargs
--     FROM pg_proc
--    WHERE proname IN ('can_submit_deliverable', 'get_deliverable_gate')
--      AND pronamespace = 'public'::regnamespace;
--   → can_submit_deliverable: prosecdef=true, provolatile='s', pronargs=3
--   → get_deliverable_gate:   prosecdef=true, provolatile='s', pronargs=1
--
-- 2단계 — 배치 함수 스모크 호출 (서비스 키 세션, auth.uid() NULL → 통과 조항 경유,
--   부작용 없음 — SELECT/함수 호출만):
--   -- 형식별 확인용 신청 하나씩 뽑기:
--   SELECT a.id AS application_id, c.recruit_type, c.proxy_purchase, c.channel
--     FROM public.applications a
--     JOIN public.campaigns c ON c.id = a.campaign_id
--    WHERE a.status = 'approved'
--    ORDER BY random() LIMIT 5;
--   -- 위에서 얻은 application_id 로:
--   SELECT * FROM public.get_deliverable_gate('<application_id>'::uuid);
--   → recruit_type='monitor'+proxy_purchase=false+channel 2개 → 3행(receipt 1 +
--     review_image 2) / proxy_purchase=true → 1행(receipt) / gifting·visit →
--     channel 개수만큼 post 행.
--
-- 3단계 — 채널 단위 전환 확인 (post 반려 예외) — 개발서버 한정, 조합을 인위적으로
--   만들어야 한다(사양서 §검증 계획 "인위적 조합 검증 3종"과 동일 방법론):
--   1) gifting/visit 캠페인 submission_end 를 과거로 조정
--   2) 그 신청의 인스타그램 post 행을 rejected 로, 틱톡 post 행을 approved(또는
--      미제출)로 만들어 둔 뒤:
--   SELECT public.can_submit_deliverable('<application_id>'::uuid, 'post', 'instagram');
--   → {"allowed": true, "reason": "rejected_exception", ...}
--   SELECT public.can_submit_deliverable('<application_id>'::uuid, 'post', 'tiktok');
--   → {"allowed": false, "reason": "submission_deadline_passed", ...}
--   (274 배포 당시라면 두 호출 모두 true 였을 것 — 이 차이가 3단계 전환의 실효 확인)
--
-- 4단계 — 본인 신청 외 조회 차단 확인 (안전, 반드시 ROLLBACK):
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서A auth_id>')::text, true);
--     -- 인플루언서A 소유가 아닌 신청 id 로 조회 시도 — 예외 기대:
--     SELECT * FROM public.get_deliverable_gate('<인플루언서B 소유 application_id>'::uuid);
--     -- 기대: ERROR: permission_denied: 본인 신청만 조회할 수 있습니다
--   ROLLBACK;
-- ============================================================
