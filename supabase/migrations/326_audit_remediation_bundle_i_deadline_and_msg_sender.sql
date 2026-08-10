-- ============================================================
-- 326_audit_remediation_bundle_i_deadline_and_msg_sender.sql
-- 전수조사 후속 조치 — 묶음 I(삭제·파기·그 밖) 중 데이터베이스 조각 2개(I-12·I-14)
-- 사양: docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I — 삭제·파기·그 밖」
--
-- ── 이 파일이 하지 않는 것 ──
--   이 파일은 화면 코드(dev/js/*.js, dev/lib/storage.js)를 전혀 건드리지 않는다.
--   데이터베이스 함수만 바꾼다. 두 조각 모두 화면이 실제로 반영하려면 후속 화면
--   작업이 필요하다 — 각 절 하단 "화면 변경 필요" 참고. 요약은 이 파일 맨 아래
--   보고 섹션에도 정리했다.
--
-- ── 재정의 기준 (전수 확인, feedback_function_redefine_latest_base 메모리 규칙) ──
--   check_application_deadline  → 272(현재 유일한 원본). 이 파일은 272 베이스.
--     (트리거 trg_application_deadline_guard 자체는 재생성하지 않는다 — 트리거는
--      함수를 이름으로 참조하므로 CREATE OR REPLACE FUNCTION 만으로 그대로 유지된다.
--      트리거 실행 순서 근거인 이름 "trg_application_deadline_guard" 도 무변경.)
--   get_application_messages    → 144 → 235(현재 원본). 이 파일은 235 베이스.
--     (145·315 는 이 함수를 언급만 하고 재정의하지 않는다 — grep 확인 완료:
--      `grep -n "CREATE OR REPLACE FUNCTION public.get_application_messages" supabase/migrations/*.sql`
--      결과 144·235 두 곳뿐이었다.)
--
-- 조각별 요약:
--   I-12 check_application_deadline(272) 재정의 — 캠페인 상태·보관 삭제 여부를
--        함께 본다. 지금은 마감일 날짜만 봐서 draft·scheduled·closed(수동전환)·
--        ended·expired·보관삭제 캠페인도 마감일만 미래면 서버가 응모를 받는다.
--   I-14 get_application_messages(235) 재정의 — 반환에 sender_id 를 추가한다.
--        관리자 호출자에게만(마스킹 규칙은 body 와 동일 분기) 채우고, 인플루언서
--        호출자에게는 항상 NULL. 지금은 이 값이 없어 화면(admin-messaging.js)이
--        "운영팀 발신 + 25분 이내"로만 회수 버튼을 그려 다른 관리자 메시지에도
--        버튼이 뜨고, 누르면 withdraw_own_message(144, 무변경)가 본인이 아니라며
--        거부한다(일본어 원문 그대로 노출 — 이 파일은 그 오류 문구 자체는 손대지
--        않는다. 아래 I-14 절 "화면 변경 필요" 참고).
--
-- 롤백: 각 절 하단 참고. 전체를 한꺼번에 되돌리려면 파일 맨 아래 "전체 롤백" 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- I-12. check_application_deadline 재정의
--   — 캠페인 상태·보관 삭제 여부를 함께 본다 (272 베이스, 로직 추가만)
--
--   ── 판정 순서 (272 원문의 통과 조항 2종은 그대로 둔 채, 그 사이·뒤에 끼워 넣는다) ──
--     1. auth.uid() IS NULL            → 통과 (272 원문 그대로, 무변경 — 배치·서비스 키)
--     2. 캠페인 조회 (status·deadline·deleted_at 한 번에) → 못 찾으면 통과
--        (272 원문은 deadline 만 조회했다. 캠페인이 안 찾아지면 272 원문도 "무기한
--         캠페인"과 동일하게 통과시켰으므로, 이 파일도 같은 상황에서 같은 결론을
--         유지한다 — applications.campaign_id 외래 키 제약이 있으면 이 뒤에서
--         표준 외래 키 오류로 걸러진다. 실제 화면은 항상 조회된 캠페인 id 로만
--         응모하므로 이 경로는 정상 흐름에서 도달하지 않는다.)
--     3. (신규) 보관 삭제(deleted_at IS NOT NULL) → **무조건 거부, 관리자 예외 없음**
--        soft_delete_campaign(255)이 이 캠페인의 신청을 이미 즉시 완전 삭제했다
--        (개인정보 즉시 파기 원칙). 그 뒤 누구든(관리자 포함) 새 신청을 끼워
--        넣으면 "삭제된 캠페인에 살아있는 신청이 있다"는 모순이 생긴다. 관리자
--        예외를 주지 않는 것은 reserve_event_ticket(316)의 deleted_at 검사와
--        같은 설계 — 316 파일도 이 검사에는 관리자 예외를 주지 않는다(그 파일의
--        deadline·연령 검사만 관리자 예외가 있다).
--     4. is_admin()                     → 통과 (272 원문 그대로, 무변경 — 현재는
--        관리자 대리 응모 경로가 없어 도달하지 않는 대비 조항). ⚠️ 위 3번(보관
--        삭제)을 이미 지난 뒤에만 이 조항에 도달하므로, 관리자도 보관 삭제된
--        캠페인에는 이 조항으로 우회할 수 없다 — "기존 통과 조항 2종을 없애지
--        말 것"은 이 두 줄(auth.uid() IS NULL / is_admin())의 존재와 그 아래
--        (상태·마감일) 검사를 건너뛰는 동작을 그대로 보존한다는 뜻이지, 이번에
--        새로 추가하는 보관 삭제 검사까지 우회시킨다는 뜻이 아니다.
--     5. (신규) 캠페인 상태가 'active' 가 아니면 → 거부 (관리자는 예외로 통과)
--        화면이 실제로 응모 버튼을 누를 수 있게 두는 상태는 'active' 하나뿐이다
--        (dev/js/application.js:406~421 floatApplyBtn 분기 — draft/expired 는
--        비노출·closedBtn·scheduledBtn·endedBtn 으로 전부 비활성, isFull 도 별도
--        차단). reserve_event_ticket(316)이 이미 같은 근거로 같은 기준(status
--        <> 'active' 면 관리자 제외 거부)을 쓰고 있어 이번 검사가 그 기준과
--        어긋나지 않는다(파일 상단 "재정의 기준" 및 대조 완료). closed 는
--        마감일이 아직 안 지났어도 관리자가 상태 드롭다운으로 수동 전환할 수
--        있어(CLAUDE.md 「상태 변경 드롭다운 전이 규칙」) 아래 6번(마감일)
--        검사만으로는 못 잡는다 — 이 검사가 그 구멍을 막는다.
--     6. 마감일 (272 원문 그대로, 무변경) — status='active' 인데 deadline 만
--        지난 좁은 경합(자정을 넘긴 직후, 아무도 목록을 불러오지 않아
--        autoCloseCampaigns 가 아직 안 돈 상태)을 잡는다. 5번이 있어도 이
--        경합에서는 status 가 여전히 'active' 로 남아 있으므로 5번만으로는
--        못 막는다 — 두 검사는 서로 다른 구멍을 막아 상호 보완한다.
--
--   ── 거부 사유 코드 (신규 2종, 기존 코드 재사용 여부 검토 결과) ──
--     기존 dev/js/ui.js _ERR_DICT 에 이 두 상황(캠페인 삭제됨 / 캠페인이 모집
--     상태가 아님)에 정확히 들어맞는 코드가 없다(recruit_deadline_passed 는
--     "기간이 끝났다"는 뜻이라 draft·scheduled처럼 "아직 시작도 안 했다"인
--     경우에 붙이면 사용자에게 반대 인상을 준다 — 316 파일이 이미 이 이유로
--     'not_found' 를 골랐던 것과 같은 판단). 새 코드 2개를 쓴다:
--       campaign_deleted   — 보관 삭제된 캠페인
--       recruit_not_open   — 상태가 'active' 아님
--     ⚠️ 이 두 코드는 아직 dev/js/ui.js friendlyErrorJa() 의 _ERR_DICT 에 매칭
--     규칙이 없다 — 매칭되는 접두어가 없으므로 그 함수의 마지막 fallback인
--     t.unknown("エラーが発生しました"/"오류가 발생했습니다")으로 표시된다.
--     이 두 경로는 화면 버튼이 이미 막고 있어 정상 흐름에서 도달하지 않는
--     최종 방어선이므로(292·316 파일과 동일한 판단), "완벽한 문구"보다
--     "틀린 인상을 주지 않는" 제네릭 문구를 우선한 것 — 316 파일의 사유 코드
--     선택 논리와 같다. 화면에 정확한 안내 문구가 필요하면 ui.js 에 두 접두어
--     매칭 규칙을 추가하는 후속 화면 작업이 필요하다(아래 "화면 변경 필요" 참고).
--
--   이 절이 바꾸지 않는 것: 함수 시그니처(인자 없음, RETURNS trigger) 불변 —
--   DROP 불필요, CREATE OR REPLACE 로 충분(트리거 재생성도 불필요). 마감일 판정
--   로직(272 4단계의 4번) 문자 그대로 보존. auth.uid() IS NULL·is_admin() 두
--   통과 조항의 "그 뒤 검사를 스킵한다"는 효과도 보존(신규 보관삭제 검사 이후
--   위치로 옮긴 것은 순서 재배치이지 그 조항 자체의 삭제가 아니다).
--
--   ⚠️ 화면 변경 필요: 없음(이 조각 단독으로는). 화면은 이미 status='active'
--   에서만 버튼을 활성화하므로 정상 사용자 동선에서 이 검사가 새로 막는
--   케이스는 없다(아래 "실제로 막게 되는 경우" 조회 참고). 단, 위에서 설명한
--   신규 오류 코드 2종의 정확한 일본어/한국어 문구가 필요하면 ui.js 갱신이
--   후속으로 필요하다.
-- ============================================================

CREATE OR REPLACE FUNCTION public.check_application_deadline()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_camp_status      text;
  v_camp_deadline    date;
  v_camp_deleted_at  timestamptz;
  v_today_kst        date;
  v_is_admin         boolean;
BEGIN
  -- 1. 배치·마이그레이션·서비스 키 — 로그인 세션이 없으면 통과.
  --    (272 원문 그대로, 무변경. 익명 anon 쓰기는 applications_insert_own 행 단위
  --     보안 정책에서 이미 차단되어 여기까지 도달하지 못한다 — 272 파일 상단 주석 참조)
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;

  -- [326] 캠페인 상태·마감일·보관 삭제 여부를 한 번에 조회 (272 원문은 deadline 만 봤다).
  SELECT c.status, c.deadline, c.deleted_at
    INTO v_camp_status, v_camp_deadline, v_camp_deleted_at
    FROM public.campaigns c
   WHERE c.id = NEW.campaign_id;

  -- 캠페인을 찾을 수 없으면 통과 (272 원문이 deadline=NULL 을 "무기한 캠페인"으로
  -- 통과시킨 것과 동일한 결론 — 이 경로는 정상 흐름에서 도달하지 않는다. 위 파일
  -- 헤더 "판정 순서 2." 참고).
  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  -- [326] 2. 보관 삭제(deleted_at)된 캠페인 — 관리자·서비스 키(이 지점 이후) 예외 없이
  --    무조건 거부. reserve_event_ticket(316)의 deleted_at 검사와 같은 설계(그 함수도
  --    이 검사에는 관리자 예외를 주지 않는다) — 위 파일 헤더 "판정 순서 3." 참고.
  IF v_camp_deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'campaign_deleted: 삭제된 캠페인에는 응모할 수 없습니다 (campaign_id=%)', NEW.campaign_id
      USING ERRCODE = 'P0001';
  END IF;

  -- 3. 관리자 — 아래(상태·마감일) 검사는 건너뛴다.
  --    (272 원문 그대로, 무변경 — 현재는 관리자 대리 응모 경로가 없어 도달하지 않는
  --     대비 조항. 단 위 2번(보관 삭제)을 이미 지난 뒤에만 도달하므로, 관리자도
  --     보관 삭제된 캠페인에는 이 조항으로 우회할 수 없다.)
  v_is_admin := public.is_admin();
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  -- [326] 4. 캠페인 상태 — 화면의 응모 버튼이 실제로 눌리는 상태는 'active' 하나뿐이다
  --    (dev/js/application.js:406~421, reserve_event_ticket 316 과 동일 판정 근거 —
  --    위 파일 헤더 "판정 순서 5." 참고). closed 는 마감일 전이어도 관리자가 상태
  --    드롭다운으로 수동 전환할 수 있어 아래 마감일 검사만으로는 못 잡는다.
  IF v_camp_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'recruit_not_open: 현재 모집 중이 아닌 캠페인입니다 (status=%)', COALESCE(v_camp_status, 'unknown')
      USING ERRCODE = 'P0001';
  END IF;

  -- 5. 일본 시각(Asia/Tokyo) 기준 오늘 날짜가 마감일을 넘었는지 판정.
  --    (272 원문 그대로, 무변경. status='active' 인데 deadline 만 지난 좁은 경합을
  --     이 검사가 잡는다 — 위 4번만으로는 못 막는 케이스.)
  v_today_kst := (now() AT TIME ZONE 'Asia/Tokyo')::date;

  IF v_camp_deadline IS NULL OR v_today_kst <= v_camp_deadline THEN
    RETURN NEW;
  END IF;

  RAISE EXCEPTION 'recruit_deadline_passed: 모집 기간이 종료되었습니다'
    USING ERRCODE = 'P0001';
END;
$$;

COMMENT ON FUNCTION public.check_application_deadline() IS
  '[272+326] 모집 마감 응모 차단 트리거 함수. BEFORE INSERT ON applications.
   판정: auth.uid() NULL 통과 → 캠페인 조회(못 찾으면 통과) → deleted_at 있으면
   무조건 거부(campaign_deleted, 관리자 예외 없음) → is_admin() 통과 →
   status<>''active'' 면 거부(recruit_not_open) →
   (now() AT TIME ZONE ''Asia/Tokyo'')::date <= deadline 이면 통과, 아니면
   ''recruit_deadline_passed: ...'' 예외(ERRCODE P0001).
   [326] 캠페인 상태·보관 삭제 여부 검사 추가 — 사양서
   docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I」 I-12.
   원본: docs/specs/2026-07-29-deadline-server-enforcement.md 1단계.';

-- 이 절 롤백:
--   272_recruit_deadline_guard.sql 의 CREATE OR REPLACE FUNCTION 블록을 그대로
--   재실행하면 된다(트리거는 재생성 불필요 — 함수 이름 불변).


-- ============================================================
-- I-14. get_application_messages 재정의
--   — 반환에 sender_id 를 추가한다 (235 베이스, 반환 컬럼 추가라 DROP 필요)
--
--   ── 왜 필요한가 ──
--   dev/js/admin-messaging.js 의 회수 버튼은 "sender_kind==='admin' + 25분 이내"
--   로만 그려진다(누가 보냈는지는 안 본다) — 지금 조회 함수가 발신자 식별 값을
--   안 돌려주기 때문에 화면이 판정할 근거 자체가 없다. 그래서 다른 관리자가
--   보낸 메시지에도 회수 버튼이 뜨고, 누르면 withdraw_own_message(144, 이 파일은
--   손대지 않음)가 "sender_id <> auth.uid()" 로 거부한다(일본어 원문
--   '自分のメッセージのみ取り消し可能です' 가 한국어 관리자 화면에 그대로 노출 —
--   admin-messaging.js 의 P0001 오류 표시 규칙이 e.message 를 그대로 보여주기
--   때문. 이 오류 문구 자체는 이 파일 범위 밖 — 아래 "화면 변경 필요" 참고).
--
--   ── 마스킹과의 관계 ──
--   sender_id 는 body 와 완전히 동일한 마스킹 CASE 분기를 그대로 따른다 —
--   관리자 호출자에게는 케이스 E(인플루언서 본인 회수)만 NULL, 그 외(D·F·G)는
--   원본 유지(235 원문의 body 분기와 동일). 이건 새 정보를 흘리지 않는다 —
--   sender_name(발신자 표시 이름)은 235 원문에서도 애초에 어떤 마스킹 분기도
--   없이 항상 그대로 반환돼 왔으므로(마스킹된 메시지도 "누가 보냈는지"는
--   이름으로 이미 노출돼 있었다), sender_id(익명 식별자)를 body 와 같은 수준
--   으로 마스킹하는 것은 기존 노출 수준보다 더 보수적이면 보수적이지 완화가
--   아니다.
--
--   ── 인플루언서 호출자에게는 항상 NULL ──
--   v_caller_is_admin 이 false 면(=인플루언서 본인 조회) sender_id 는 마스킹
--   분기 없이 항상 NULL 을 돌려준다 — 관리자 개인 식별 값(auth.users.id)을
--   인플루언서 화면에 내려보낼 이유가 없다(요청사항 그대로).
--
--   ── 반환 타입 변경 → DROP 필요, 호출부 전수 확인 ──
--   RETURNS TABLE 에 컬럼이 늘어나므로 235 원문과 같은 이유로 DROP 후 CREATE가
--   필요하다(235 파일 주석: "기존 컬럼 뒤에 컬럼만 추가하는 것도 RETURNS TABLE
--   특성상 OUT 파라미터 목록이 바뀌어 DROP 필수"). DROP 시 GRANT/REVOKE 가 함께
--   사라지므로 235 원문과 동일하게 재적용한다.
--   호출부 전수 확인(grep 완료, 2026-08-10):
--     dev/lib/storage.js:3199 fetchApplicationMessages() — db.rpc('get_application_messages', ...)
--       가 유일한 호출부. 인플루언서 화면(dev/js/messaging.js)과 관리자 화면
--       (dev/js/admin-messaging.js)이 이 함수 하나를 공용으로 쓴다(빌드가 두
--       화면 번들에 storage.js 를 각각 이어붙이는 구조 — CLAUDE.md 「Architecture」).
--     다른 데이터베이스 함수가 get_application_messages 를 호출하는 곳 없음
--       (grep "get_application_messages" supabase/migrations/*.sql 결과 144·235
--       정의부와 145 의 주석 언급 1건뿐 — 실제 호출 없음).
--     supabase/functions/*(Edge Function)에서 호출하는 곳 없음.
--
--   ── 일괄 발송 쪽과 이름·의미 맞추기 ──
--   application_message_broadcasts.sender_id (144) 와 같은 이름·같은 의미
--   (발신자의 auth.uid()) 로 맞췄다 — admin-messaging.js:1543 의 회수 가능 판정
--   (b.sender_id === currentAdminInfo?.auth_id)과 화면 쪽에서 같은 패턴으로
--   비교할 수 있게 하기 위함.
--
--   ⚠️ 화면 변경 필요 (이 데이터베이스 변경만으로는 버튼이 계속 뜬다):
--     dev/js/admin-messaging.js 의 회수 버튼 렌더 조건(대략 786행 부근,
--     "운영팀 발신 + 25분 이내" 분기)에 msg.sender_id === currentAdminInfo?.auth_id
--     비교를 추가해야 한다. ⚠️ admin-messaging.js:1543(일괄 발송 회수)의
--     "|| currentAdminInfo?.role === 'super_admin'" 을 그대로 옮겨 붙이지
--     말 것 — withdraw_own_message(144, 이 파일에서 손대지 않음)는 super_admin
--     예외가 전혀 없이 "sender_id <> auth.uid()" 만 본다. 그대로 옮기면
--     super_admin 에게는 버튼이 뜨는데 눌러도 여전히 실패하는, 지금과 같은
--     종류의 어긋남이 super_admin 한정으로 새로 생긴다. 개별 메시지도
--     super_admin 회수를 허용하려면 withdraw_own_message 쪽에 별도 예외를
--     추가하는 결정이 먼저 필요하다(이번 조각 범위 밖).
--     그 외에도 withdraw_own_message 의 본인 아님 거부 문구
--     '自分のメッセージのみ取り消し可能です' 가 여전히 일본어 하드코딩이라,
--     화면이 위 비교로 버튼을 완전히 숨기지 못하는 예외적 경합(예: 캐시가
--     오래된 상태에서 클릭)에서는 이 문구가 그대로 노출될 수 있다 — 필요하면
--     별도 후속 마이그레이션으로 코드 접두어를 붙이고 dev/js/ui.js 또는
--     admin-messaging.js 쪽에 매칭 규칙을 추가하는 것을 검토할 것(이번 조각
--     범위 밖, 이 파일은 손대지 않았다).
-- ============================================================

DROP FUNCTION IF EXISTS public.get_application_messages(uuid);

CREATE OR REPLACE FUNCTION public.get_application_messages(
  p_application_id uuid
) RETURNS TABLE (
  id                      uuid,
  application_id          uuid,
  sender_kind             text,
  sender_name             text,
  body                    text,        -- 마스킹 시 NULL
  attachments             jsonb,       -- 마스킹 시 '[]'::jsonb
  created_at              timestamptz,
  read_by_influencer_at   timestamptz,
  broadcast_id            uuid,
  hidden_by_admin_at      timestamptz,
  self_withdrawn_at       timestamptz,
  self_withdrawn_by_kind  text,
  mask_state              text,        -- 'visible' | 'hidden_by_admin' | 'self_withdrawn_influencer' | 'self_withdrawn_admin'
  body_translated         text,        -- [235] 번역본. 마스킹 시 NULL (body 와 동일 분기)
  translated_lang         text,        -- [235] 'ko'|'ja'. 마스킹 시 NULL
  translate_status        text,        -- [235] 'pending'|'done'|'failed'|'skipped'. 마스킹 시 NULL
  sender_id               uuid         -- [326] 발신자 auth.uid(). 관리자 호출자에게만(body 와
                                        --       동일 마스킹 분기), 인플루언서 호출자에게는 항상 NULL
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
#variable_conflict use_column
DECLARE
  v_caller_is_admin  boolean;
  v_app_owner        uuid;
BEGIN
  -- 응모 소유자 확인
  SELECT user_id INTO v_app_owner
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '応募が見つかりません';
  END IF;

  -- 호출자 권한 판별
  v_caller_is_admin := public.is_admin();

  -- 인플루언서 본인 또는 관리자가 아니면 차단
  IF NOT v_caller_is_admin AND v_app_owner <> auth.uid() THEN
    RAISE EXCEPTION '権限がありません';
  END IF;

  RETURN QUERY
  SELECT
    m.id,
    m.application_id,
    m.sender_kind,
    m.sender_name,
    -- body 마스킹 분기 (144 원본과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        -- 관리자: 인플루언서 본인 회수(케이스 E)만 마스킹
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL  -- 케이스 E: 양쪽 마스킹 (관리자도 못 봄)
          ELSE m.body  -- 케이스 D(강제숨김), F(관리자회수), G(visible) 모두 원본 유지
        END
      ELSE
        -- 인플루언서: 강제 숨김(A) 또는 회수(B) 시 마스킹
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL  -- 케이스 A
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL  -- 케이스 B
          ELSE m.body                                      -- 케이스 C
        END
    END AS body,
    -- attachments 마스킹 분기 (body 와 동일 로직)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN '[]'::jsonb
          ELSE m.attachments
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN '[]'::jsonb
          WHEN m.self_withdrawn_at  IS NOT NULL THEN '[]'::jsonb
          ELSE m.attachments
        END
    END AS attachments,
    m.created_at,
    m.read_by_influencer_at,
    m.broadcast_id,
    m.hidden_by_admin_at,
    m.self_withdrawn_at,
    m.self_withdrawn_by_kind,
    -- mask_state 계산 (144 원본과 동일)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          -- 우선순위: 인플루언서 본인 회수(E)를 D보다 먼저 판별
          -- (혹시 hidden_by_admin_at + self_withdrawn_at 둘 다 있는 예외 케이스 대비)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'  -- 케이스 E
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'            -- 케이스 D
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'       -- 케이스 F
          ELSE 'visible'                      -- 케이스 G
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL
            THEN 'hidden_by_admin'                    -- 케이스 A
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN 'self_withdrawn_influencer'           -- 케이스 B (본인 회수)
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'admin'
            THEN 'self_withdrawn_admin'               -- 케이스 B (관리자 회수)
          ELSE 'visible'                              -- 케이스 C
        END
    END AS mask_state,
    -- [235] body_translated — body 와 완전히 동일한 마스킹 분기
    --       (원문이 가려지면 번역본도 가려 "번역이 있었다"는 힌트조차 차단)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.body_translated
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.body_translated
        END
    END AS body_translated,
    -- [235] translated_lang — body_translated 와 동일 분기로 마스킹
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translated_lang
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translated_lang
        END
    END AS translated_lang,
    -- [235] translate_status — 동일 분기로 마스킹 (진행 상태 자체도 숨김)
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.translate_status
        END
      ELSE
        CASE
          WHEN m.hidden_by_admin_at IS NOT NULL THEN NULL
          WHEN m.self_withdrawn_at  IS NOT NULL THEN NULL
          ELSE m.translate_status
        END
    END AS translate_status,
    -- [326] sender_id — 관리자 호출자에게만, body 와 완전히 동일한 마스킹 분기.
    --       인플루언서 호출자에게는 항상 NULL(관리자 개인 식별 값을 내려보내지 않는다).
    CASE
      WHEN v_caller_is_admin THEN
        CASE
          WHEN m.self_withdrawn_at IS NOT NULL AND m.self_withdrawn_by_kind = 'influencer'
            THEN NULL
          ELSE m.sender_id
        END
      ELSE NULL
    END AS sender_id
  FROM public.application_messages m
  WHERE m.application_id = p_application_id
  ORDER BY m.created_at ASC;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_application_messages(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_application_messages(uuid) TO authenticated;

COMMENT ON FUNCTION public.get_application_messages(uuid) IS
  '[144, 235, 326] 응모건 메시지 목록 조회 RPC. 서버 측 마스킹 처리 (사양서 §9). '
  '인플루언서: 강제숨김+회수 시 body=NULL, attachments=[]. '
  '관리자: 인플루언서 본인 회수만 양쪽 마스킹, 강제숨김·관리자회수는 원본 유지 (비대칭). '
  'mask_state: visible|hidden_by_admin|self_withdrawn_influencer|self_withdrawn_admin. '
  '[235] body_translated/translated_lang/translate_status 추가 — 자동 번역 파이프라인. '
  '[326] sender_id 추가 — 관리자 호출자에게만(body 와 동일 마스킹 분기) 발신자 auth.uid() 반환, '
  '인플루언서 호출자에게는 항상 NULL. 화면의 「회수」 버튼이 본인 메시지인지 판정할 근거로 사용 '
  '(사양서 docs/specs/2026-08-07-audit-remediation-plan.md 「묶음 I」 I-14). '
  'SECURITY DEFINER + search_path 고정.';

-- 이 절 롤백:
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.get_application_messages(uuid);
--   -- 235_message_translation.sql 의 "2. get_application_messages 재정의" 절의
--   -- CREATE OR REPLACE FUNCTION 블록(sender_id 없는 버전)을 그대로 재실행.
--   COMMIT;

COMMIT;

-- ============================================================
-- 검증 (1단계씩 — 결과 확인 후 다음 단계로. .claude/rules/supabase.md
-- 「SQL 검증 순차 안내」)
-- ============================================================
/*

-- ── I-12 검증 ──

-- [1] 함수 재정의 확인 (트리거는 재생성하지 않았으므로 트리거 존재도 함께 확인)
SELECT p.proname, p.prosecdef,
       t.tgname, t.tgenabled
  FROM pg_proc p
  JOIN pg_trigger t ON t.tgfoid = p.oid
 WHERE p.proname = 'check_application_deadline'
   AND p.pronamespace = 'public'::regnamespace;
-- 기대: 1행, prosecdef=true, tgname='trg_application_deadline_guard', tgenabled='O'
--       (272 검증 [1]단계와 동일 — 트리거를 재생성하지 않았으니 바뀌지 않아야 정상)

-- [2] 트리거 실행 순서 재확인 (326 이 순서를 바꾸지 않았는지)
SELECT tgname
  FROM pg_trigger
 WHERE tgrelid = 'public.applications'::regclass
   AND tgname LIKE 'trg_%'
   AND NOT tgisinternal
 ORDER BY tgname;
-- 기대: trg_age_policy, trg_application_deadline_guard,
--       trg_application_insert_status_guard, trg_monitor_auto_approve,
--       trg_monitor_slots_guard 순서로 **5행**
--   ⚠️ 272 파일에는 4행이라 적혀 있는데, 그 뒤 마이그레이션 314 가
--   trg_application_insert_status_guard 를 끼워 넣어 지금은 5행이 정상이다.
--   확인할 것은 개수가 아니라 **trg_application_deadline_guard 가 trg_monitor_* 보다
--   앞에 오는지**다(마감·정원이 동시에 걸리면 마감 메시지가 먼저 나오게 한 순서).

-- [3] 함수 본문에 신규 검사 2종이 실제로 들어갔는지
SELECT prosrc ILIKE '%campaign_deleted%' AS has_deleted_check,
       prosrc ILIKE '%recruit_not_open%' AS has_status_check
  FROM pg_proc
 WHERE proname = 'check_application_deadline' AND pronamespace = 'public'::regnamespace;
-- 기대: 둘 다 true

-- [4] ⚠️ 실제 차단 재현은 272 검증 [3]단계와 동일하게 SQL 편집기에서
--   set_config('request.jwt.claims', ...) 로 auth.uid() 를 흉내내야 한다(서비스 키
--   세션은 auth.uid() 가 NULL 이라 이 트리거를 우회한다 — 272 파일 하단 참고).
--   ⚠️ 반드시 BEGIN ~ ROLLBACK 사이에서만 실행할 것(운영 데이터에 남기지 않기 위함).
--
--   a. 보관 삭제된 캠페인 차단 확인 (관리자로도 막혀야 한다)
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 또는 관리자 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message)
--     VALUES ('<위와 동일 auth_id>'::uuid, '<deleted_at 이 세팅된 캠페인 id>'::uuid, '검증용');
--     -- 기대: ERROR: campaign_deleted: 삭제된 캠페인에는 응모할 수 없습니다 (campaign_id=...)
--   ROLLBACK;
--
--   b. 모집 상태가 아닌 캠페인 차단 확인 (일반 인플루언서 계정 — 관리자는 통과해야 함)
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<테스트 인플루언서 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message)
--     VALUES ('<위와 동일 auth_id>'::uuid, '<status가 draft 또는 scheduled 인 캠페인 id>'::uuid, '검증용');
--     -- 기대: ERROR: recruit_not_open: 현재 모집 중이 아닌 캠페인입니다 (status=draft)
--   ROLLBACK;
--
--   c. 정상 케이스 무회귀 확인 (status='active', deadline 미경과 캠페인)
--   BEGIN;
--     SELECT set_config('request.jwt.claims',
--       json_build_object('sub', '<위 캠페인에 아직 응모하지 않은 테스트 인플루언서 auth_id>')::text, true);
--     INSERT INTO public.applications (user_id, campaign_id, message)
--     VALUES ('<위와 동일 auth_id>'::uuid, '<status=''active'' 캠페인 id>'::uuid, '검증용');
--     -- 기대: 정상 INSERT 성공 (326 이전과 동일)
--   ROLLBACK;

-- ── I-12: 「운영 데이터에서 실제로 막히는 경우가 있는지」 확인용 조회 ──
--   (326 적용 전, 개발·운영 각 서버에서 조회만 해보는 것 — INSERT 없이 안전)
--   deadline 미경과인데 응모를 이미 받고 있었을 수도 있는 "구멍" 후보:
--   상태가 active 가 아니면서 deadline 이 아직 지나지 않은(=326 이전엔 서버가
--   막지 못했던) 캠페인, 그리고 실제로 이 케이스에서 들어온 응모가 있는지.
SELECT c.id, c.title, c.status, c.deadline, c.deleted_at,
       (SELECT count(*) FROM public.applications a WHERE a.campaign_id = c.id) AS app_count
  FROM public.campaigns c
 WHERE (c.status <> 'active' OR c.deleted_at IS NOT NULL)
   AND (c.deadline IS NULL OR c.deadline >= (now() AT TIME ZONE 'Asia/Tokyo')::date)
 ORDER BY app_count DESC, c.created_at DESC;
-- app_count > 0 인 행이 있으면: 그 캠페인이 비-active(또는 삭제) 상태인 채로
-- 이미 응모를 받은 적이 있다는 뜻 — 326 적용 후에는 "그 상태로 있는 동안"
-- 신규 응모가 더 이상 들어오지 않는다(기존 응모 행은 그대로 유지, 소급 삭제 아님).


-- ── I-14 검증 ──

-- [5] 함수 재정의 확인 (반환 컬럼에 sender_id 포함됐는지)
SELECT p.oid::regprocedure AS signature,
       pg_get_function_result(p.oid) AS return_columns
  FROM pg_proc p
 WHERE p.proname = 'get_application_messages' AND p.pronamespace = 'public'::regnamespace;
-- 기대: signature 1건, return_columns 문자열에 "sender_id uuid" 포함

-- [6] 오버로드가 안 생겼는지 (DROP 후 CREATE 라 시그니처는 그대로여야 함)
SELECT count(*) FROM pg_proc
 WHERE proname = 'get_application_messages' AND pronamespace = 'public'::regnamespace;
-- 기대: 1

-- [7] ⚠️ 이 함수도 본인 응모 소유자 검증(RAISE EXCEPTION '応募が見つかりません') 이
--   있어 완전한 동작 검증은 실제 로그인 세션이 필요하다. 관리자 세션(브라우저
--   개발자 도구 콘솔)에서:
--     const { data } = await window.db.rpc('get_application_messages', {p_application_id:'<응모id>'});
--     console.table(data);
--   → 각 행에 sender_id 컬럼이 채워져 있는지(관리자 발신 메시지는 실제 관리자 auth_id,
--     인플루언서 발신 메시지는 인플루언서 id) 확인.
--   인플루언서 세션(테스트 인플루언서 로그인, 본인 응모건)에서 같은 호출을 하면
--   → 모든 행의 sender_id 가 null 이어야 한다.

*/

-- ============================================================
-- 전체 롤백 (조각 2개를 한 번에 되돌릴 때)
-- ============================================================
-- BEGIN;
--   DROP FUNCTION IF EXISTS public.get_application_messages(uuid);
--   -- 235_message_translation.sql 의 "2. get_application_messages 재정의" 절
--   -- CREATE 문(sender_id 없는 버전)을 그대로 재실행
--   -- check_application_deadline 은 DROP 하지 않고 CREATE OR REPLACE 만 했으므로,
--   -- 272_recruit_deadline_guard.sql 의 CREATE OR REPLACE FUNCTION 블록을 그대로
--   -- 재실행하면 원상 복구된다(트리거는 그대로 유지).
-- COMMIT;
-- ============================================================
