-- ============================================================
-- 376_event_selection_mode_column.sql
-- 비공개 행사, 선착순형과 선정형 중 고르기 — 1/4 (방식 칸 + 알림 종류 확장)
-- 사양서: docs/specs/2026-08-24-event-invite-only-selection.md
-- 작업표: docs/specs/2026-08-24-event-invite-only-selection-breakdown.md 「S-1」
-- 선행: 280(캠페인 event_mode·is_invite_only) · 283(알림 종류 11종 원본)
--
-- 🔴 이 파일은 순수 추가만 한다. 적용해도 동작이 하나도 안 바뀐다.
--    기존 캠페인은 전부 새 칸의 기본값(선착순형)이 되고, 뒤따르는 마이그레이션
--    3개(승격 차단·선정형 접수·뽑기/떨어뜨리기 함수)가 이 칸을 참조해 갈라진다.
--
-- 이 파일이 만드는 것:
--   [A] campaigns.event_selection_mode  — 'first_come'(선착순형, 기본값) | 'selection'(선정형)
--   [B] campaigns_selection_mode_scope_chk — 행사(event_mode)이면서 비공개(is_invite_only)일
--       때만 선정형을 켤 수 있다는 것을 데이터베이스에서도 강제
--   [D] notifications_kind_check 재정의 — 알림 종류를 11종 → 12종으로 확장
--       (행사 당선 전용 알림 event_selection_won 추가)
--
-- ⚠️ 두 값짜리 글자 칸을 쓰는 이유(참·거짓 칸을 쓰지 않는다) — 작업표 §4-1:
--    「선정형이 아니다」라는 이중 부정이 화면 12자리에 번지는 것을 막고, 나중에
--    갈래를 늘릴 때(예: 추첨형) 칸을 새로 만들지 않아도 되게 한다.
--
-- 🔴 [C] 새 취소 사유 코드(lookup_values) — 만들지 않는다.
--    작업표 §12 확정 사항 1 — 떨어뜨린 응모는 cancelled 가 아니라 rejected 로 두기로
--    했다. cancel_reason_code 는 응모가 「취소됨」일 때 쓰는 칸이라, rejected 로 두는
--    이상 이 칸 자체가 필요 없다. 낙선 문구는 dev/lib/i18n/ja.js 의 기존
--    rejected: '落選' 배지가 그대로 감당한다(새 문구도 새 코드도 안 만든다).
--
-- ⚠️ [D] 알림 종류 확장 — 283 의 11종을 하나도 빠뜨리지 않고 그대로 옮기고
--    event_selection_won 1종만 더한다. 하나라도 빠뜨리면 그 종류의 알림이
--    CHECK 위반으로 전부 실패한다(283 헤더가 같은 경고를 남겼다).
--    event_selection_won 은 「없던 걸 만드는 것」이 아니라 「다른 모집 형식에
--    이미 있는 당선 알림(application_approved, 154)을 방문객 문구로 되살리는 것」이다
--    (283 이 행사에서 그 알림을 끈 이유 ①이 「결과물 제출을 요구하는 문구가
--    방문객에게 안 맞는다」였을 뿐, 당선 자체를 알리지 말라는 뜻이 아니었다).
--    새 종류를 따로 두는 이유는 클릭 목적지 — 이 종류라야 입장 티켓 화면으로
--    바로 보낼 수 있다(기존 application_approved 를 재사용하면 응모이력을 거쳐
--    티켓 버튼을 한 번 더 눌러야 한다).
--
-- 마이그레이션 275(캠페인 동시 저장 방어)와의 관계 — 자동 보호 대상:
--    275 의 campaigns_bump_version() 트리거는 제외 6개(version·updated_at·
--    view_count·applied_count·order_index·first_active_at)를 뺀 나머지가 실제로
--    바뀌면 version +1 이다(fail-closed). event_selection_mode 는 제외 목록에
--    없으므로 아무 조치 없이 자동으로 보호 대상이 된다(280 이 event_mode·
--    is_invite_only 에 적용한 것과 같은 판단). 관리자 편집 저장은
--    updateCampaign(id, updates, expectedVersion) 을 그대로 쓴다.
--
-- 마이그레이션 265·266(캠페인 전체 항목 변경 이력)과의 관계 — 의도적 제외:
--    변경 이력 화이트리스트는 세 곳(265 CHECK · 266 v_fields · 266 트리거의
--    AFTER UPDATE OF 목록)이 항상 같은 집합이어야 하고, 어긋나면 CHECK 위반으로
--    캠페인 저장 자체가 통째로 실패한다. 행사 캠페인은 소수·기간 한정이라
--    이 칸도 event_mode·is_invite_only 와 같은 이유로 화이트리스트에
--    추가하지 않는다(280 과 같은 판단, 작업표 §4-1 [E]).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

-- ============================================================
-- 1. 방식 칸 [A]
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_selection_mode text NOT NULL DEFAULT 'first_come';

ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_event_selection_mode_chk;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_event_selection_mode_chk
  CHECK (event_selection_mode IN ('first_come', 'selection'));

-- ============================================================
-- 2. 범위 제약 [B] — 선정형은 행사(event_mode) + 비공개(is_invite_only) 일 때만
-- ============================================================
-- 기존 행은 전부 event_selection_mode='first_come' 이라 이 제약을 그냥 통과한다
-- (도입 영향 0). 이름은 「무엇을 막는지」를 알 수 있게 짓는다 — 280 의
-- campaigns_event_mode_visit_chk 와 같은 명명 관례.
--
-- ⚠️ 이 제약 때문에 생기는 저장 코드의 의무(작업표 §4-1·S-6):
--    화면이 「행사 모드를 끈다」또는 「비공개를 끈다」 저장을 할 때, 방식이
--    이미 'selection' 이면 함께 'first_come' 으로 되돌려야 한다. 안 하면 그
--    저장이 이 제약에 막혀 데이터베이스 원문 오류로 실패한다(이 마이그레이션이
--    막는 범위가 아니라 화면 쪽 조각의 몫이다 — 여기서는 제약만 건다).
ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_selection_mode_scope_chk;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_selection_mode_scope_chk
  CHECK (event_selection_mode = 'first_come' OR (event_mode AND is_invite_only));

-- ============================================================
-- 3. 칸 주석 [E]
-- ============================================================
COMMENT ON COLUMN public.campaigns.event_selection_mode IS
  '[376] 행사(티켓) 캠페인의 접수 방식. first_come=선착순형(정원이 남아 있으면 그 '
  '자리에서 즉시 당선, 종전과 동일) | selection=선정형(정원과 무관하게 접수만 받고 '
  '관리자가 뽑는다). 켤 수 있는 조건은 campaigns_selection_mode_scope_chk 로 강제 '
  '(행사 모드 AND 비공개일 때만). 판정은 이 칸 하나로만(클라이언트 헬퍼 '
  'isSelectionEvent, dev/lib/shared.js) — 이 칸은 265·266 캠페인 변경 이력 '
  '화이트리스트에 일부러 넣지 않았다(280 의 event_mode·is_invite_only 와 같은 '
  '판단). 275 낙관적 락의 자동 보호 대상(제외 목록에 없음).';

-- ============================================================
-- 4. 알림 종류 확장 [D] — 11종 → 12종
-- ============================================================
-- ⚠️ 현행 목록의 원본은 283(번호가 가장 큰 정의)이다. 283 의 11종을 그대로
--    옮기고 event_selection_won 1종만 더한다.
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
    'submission_deadline_changed',
    'event_waitlist_promoted',
    'event_selection_won'   -- 376 신규: 선정형 행사 당선 안내(입장 티켓 화면으로 직행)
  ));

COMMENT ON COLUMN public.notifications.kind IS
  'deliverable_rejected | deliverable_changed | deliverable_approved | application_cancelled | '
  'message_received | application_approved | deliverable_proxy_submitted | '
  'settlement_paypal_required | settlement_paid | submission_deadline_changed | '
  'event_waitlist_promoted | event_selection_won';

COMMIT;

-- 새 컬럼이 생겨 API 계층 스키마 캐시를 새로 읽게 한다.
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 — 1단계씩 순서대로 확인 (한 번에 전부 실행하지 말 것)
-- ============================================================
-- 1) 칸·제약 생성 확인
-- SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns'
--    AND column_name = 'event_selection_mode';
--   → text, NO, 'first_come'::text
--
-- SELECT conname, pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid = 'public.campaigns'::regclass
--    AND conname IN ('campaigns_event_selection_mode_chk', 'campaigns_selection_mode_scope_chk');
--   → 2행
--
-- 2) 기존 캠페인이 전부 기본값인지(도입 즉시 동작 변화 0)
-- SELECT event_selection_mode, count(*) FROM public.campaigns GROUP BY 1;
--   → 'first_come' 한 줄만 나와야 한다
--
-- 3) 범위 제약이 실제로 막는지 — 조건이 둘(행사 모드 그리고 비공개)이므로
--    각각 따로 확인한다. 세 경우 다 시험한 뒤 반드시 롤백(마지막 UPDATE)한다.
--
--    3-a) 행사도 비공개도 아닌 캠페인에 selection 을 넣으면 거부되는지
--    SELECT id FROM public.campaigns WHERE NOT event_mode AND NOT is_invite_only LIMIT 1;
--    UPDATE public.campaigns SET event_selection_mode='selection' WHERE id='<위 id>';
--      → ERROR: new row for relation "campaigns" violates check constraint
--        "campaigns_selection_mode_scope_chk" 가 나와야 한다(정상)
--
--    3-b) 행사만 켜고(비공개는 꺼진 채) selection 을 넣으면 거부되는지
--    UPDATE public.campaigns SET event_mode=true, is_invite_only=false WHERE id='<위 id>';
--    UPDATE public.campaigns SET event_selection_mode='selection' WHERE id='<위 id>';
--      → 마찬가지로 거부되어야 한다(둘 중 하나만 만족하면 여전히 막힘)
--
--    3-c) 행사 + 비공개를 둘 다 켠 뒤에는 통과하는지, 그리고 원복
--    UPDATE public.campaigns SET is_invite_only=true WHERE id='<위 id>';
--    UPDATE public.campaigns SET event_selection_mode='selection' WHERE id='<위 id>';
--      → 성공해야 한다(둘 다 만족)
--    UPDATE public.campaigns
--       SET event_selection_mode='first_come', event_mode=false, is_invite_only=false
--     WHERE id='<위 id>';
--      → 원래 값으로 되돌리는 것을 잊지 말 것
--
-- 4) 알림 종류 12개를 눈으로 세기 — 283 의 11종이 하나도 안 빠졌는지 확인
-- SELECT pg_get_constraintdef(oid)
--   FROM pg_constraint
--  WHERE conrelid = 'public.notifications'::regclass
--    AND conname = 'notifications_kind_check';
--   → IN 목록에 12개 값이 있어야 한다. 옛 11종(283)이 전부 있는지 하나씩 대조:
--     deliverable_rejected · deliverable_changed · deliverable_approved ·
--     application_cancelled · message_received · application_approved ·
--     deliverable_proxy_submitted · settlement_paypal_required · settlement_paid ·
--     submission_deadline_changed · event_waitlist_promoted (11개, 빠짐없음)
--     + event_selection_won (신규 1개) = 12개
--
-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ 되돌리기 전에 새 종류(event_selection_won) 알림 행을 먼저 지워야 한다.
--    남아 있으면 옛 11종 CHECK 재추가가 실패한다(283 파일이 같은 경고를 남겼다).
--
-- BEGIN;
-- DELETE FROM public.notifications WHERE kind = 'event_selection_won';
--
-- ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_kind_check;
-- ALTER TABLE public.notifications ADD CONSTRAINT notifications_kind_check CHECK (kind IN (
--   'deliverable_rejected','deliverable_changed','deliverable_approved',
--   'application_cancelled','message_received','application_approved',
--   'deliverable_proxy_submitted','settlement_paypal_required','settlement_paid',
--   'submission_deadline_changed','event_waitlist_promoted'
-- ));
--
-- ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_selection_mode_scope_chk;
-- ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_event_selection_mode_chk;
-- ALTER TABLE public.campaigns DROP COLUMN IF EXISTS event_selection_mode;
-- COMMIT;
--
-- NOTIFY pgrst, 'reload schema';
