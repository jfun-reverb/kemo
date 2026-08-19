-- ============================================================
-- 346_withdraw_reason_lookup_seed.sql
-- 회원 탈퇴 — 작업 4 (탈퇴 사유 기준 데이터)
-- 사양서: docs/specs/2026-08-18-member-withdrawal.md §4-3
-- 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 4 (stale 점검 ③)
--
-- 새 kind 'withdraw_reason' 을 lookup_values 에 추가한다. CHECK 제약을
-- 먼저 확장하지 않으면 아래 시드 INSERT 가 통째로 실패한다(kind CHECK
-- 위반) — 345(탈퇴 신청 표) 보다 반드시 먼저 적용할 필요는 없지만, 345의
-- reason_code 가 이 kind 를 참조하므로 회원 화면(후속 작업 9)이 열리기
-- 전에는 반드시 적용돼 있어야 한다.
--
-- ⚠️ CHECK 제약의 현재 최신 정의는 마이그레이션 227(15종)이다 — 106·144·
--   160 을 거쳐 227 이 마지막으로 DROP+ADD 했다. 이 파일은 227 을 베이스로
--   'withdraw_reason' 1종을 더해 16종으로 확장한다(작업표 stale 점검 ③).
--
-- ⚠️ 기존 동종 항목 중복 확인 완료(.claude/rules/supabase.md 「기준 데이터
--   추가 시 중복 확인」):
--   grep -rni "withdraw_reason\|withdrawal_requests" supabase/seed/ supabase/migrations/
--   → 0건(이 파일 작성 전 기준). 가장 근접한 기존 kind 는 'cancel_reason'
--   (응모 취소 사유, 마이그레이션 104)이지만 응모 취소와 회원 탈퇴는 다른
--   사건이라 같은 kind 를 재사용하지 않고 새 kind 로 분리한다 — cancel_reason
--   항목(예: "일정이 안 맞아서")과 withdraw_reason 항목(예: "앱이 불편해서")은
--   의미가 겹치지 않는다.
--
-- ⚠️ 이 kind 는 관리자 「기준 데이터」 편집 화면(dev/js/admin-lookups.js
--   #lookups 페인)에 UI 탭으로 노출되지 않는다 — 그 화면은 kind 를 전부
--   보여주는 구조가 아니라 LOOKUP_KIND_LABEL_KO 에 등록된 7종
--   (channel/category/content_type/ng_set/participation_set/reject_reason/
--   caution) 만 고정 탭으로 보여준다. cancel_reason·blacklist_reason·
--   admin_email_kind 등 나머지 kind 들도 전부 같은 이유로 이 화면 밖에서
--   시드로만 관리된다 — withdraw_reason 도 같은 부류다(회원 탈퇴 화면에서
--   드롭다운으로 선택되는 값일 뿐, 운영팀이 화면에서 늘리려면 이 화면에
--   탭을 추가하는 별도 작업이 필요하다 — 이번 마이그레이션 범위 밖).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. lookup_values.kind CHECK 확장 (15종 → 16종, 베이스 227)
-- ============================================================
ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;

ALTER TABLE public.lookup_values
  ADD CONSTRAINT lookup_values_kind_check
  CHECK (kind IN (
    'channel',
    'category',
    'content_type',
    'ng_item',
    'reject_reason',
    'blacklist_reason',
    'violation_reason',
    'caution',
    'admin_email_kind',
    'cancel_reason',
    'message_hide_reason',
    'admin_proxy_reason',
    'ob_series',
    'ob_category',
    'ob_tier',
    'withdraw_reason'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | '
  'violation_reason | caution | admin_email_kind | cancel_reason | message_hide_reason | '
  'admin_proxy_reason | ob_series | ob_category | ob_tier | withdraw_reason';

-- ============================================================
-- 2. 시드 — withdraw_reason (탈퇴 사유, 사양서 §4-4 예시와 동일)
-- ============================================================
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('withdraw_reason', 'no_fit',       '캠페인이 잘 안 맞아서',   'キャンペーンが合わない',   10, true),
  ('withdraw_reason', 'not_selected', '응모해도 잘 안 돼서',     '応募しても当選しない',     20, true),
  ('withdraw_reason', 'app_hard',     '앱이 불편해서',           'アプリが使いにくい',       30, true),
  ('withdraw_reason', 'other',        '기타',                    'その他',                   40, true)
ON CONFLICT (kind, code) DO UPDATE SET
  name_ko = EXCLUDED.name_ko,
  name_ja = EXCLUDED.name_ja,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active,
  updated_at = now();

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] CHECK 제약 확장 확인 (16종 포함 여부, 'withdraw_reason' 이 목록에 있는지)
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname = 'lookup_values_kind_check';

-- [V1] 시드 확인 (4행, code/한국어/일본어/순서/활성 여부)
SELECT code, name_ko, name_ja, sort_order, active
FROM lookup_values
WHERE kind = 'withdraw_reason'
ORDER BY sort_order;

-- [V2] 다른 kind 와 이름이 의미상 겹치지 않는지 재확인(중복 점검 — 특히
--   cancel_reason 과 비교. code 는 kind 가 달라 유니크 충돌은 원천적으로
--   없지만, 화면에 같은 뜻의 항목이 두 번 보이면 안 되므로 이름 자체를 대조)
SELECT kind, code, name_ko, name_ja
FROM lookup_values
WHERE kind IN ('withdraw_reason', 'cancel_reason')
ORDER BY kind, sort_order;

-- [V3] 345(withdrawal_requests) 가 먼저 적용돼 있다면, reason_code 후보로
--   쓸 code 값이 실제로 이 표에 다 있는지 교차 확인(참고용 — 실제 신청은
--   후속 작업 5의 함수가 담당)
SELECT code FROM lookup_values WHERE kind = 'withdraw_reason' AND active = true ORDER BY sort_order;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ⚠️ CHECK 확장을 되돌리려면 그 kind 의 행을 먼저 지워야 한다 — 옛 CHECK
--   (16종 → 15종, 'withdraw_reason' 제외)를 먼저 걸면 이미 남아 있는
--   withdraw_reason 행 4개가 그 순간 위반 상태가 되어 ALTER TABLE 자체가
--   실패한다. 반드시 아래 순서(① DELETE → ② DROP+ADD CHECK)를 지킬 것.
--   또한 345(withdrawal_requests.reason_code)가 이미 이 kind 를 참조해
--   저장된 값이 있다면(회원이 실제로 탈퇴를 신청한 뒤라면) 그 참조는
--   FK 가 아니라 주석뿐인 컨벤션이라 DB 단에서 막히진 않지만, reason_code
--   가 가리키는 값이 사라지므로 화면에 사유가 빈 값으로 보이게 된다 —
--   되돌리기 전에 반드시 345 도 함께 되돌릴지(또는 데이터 영향을) 판단할 것.
--
-- -- ① 시드 삭제
-- DELETE FROM lookup_values WHERE kind = 'withdraw_reason';
--
-- -- ② CHECK 를 227 정의(15종)로 되돌림
-- ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
-- ALTER TABLE public.lookup_values
--   ADD CONSTRAINT lookup_values_kind_check
--   CHECK (kind IN (
--     'channel','category','content_type','ng_item','reject_reason',
--     'blacklist_reason','violation_reason','caution','admin_email_kind',
--     'cancel_reason','message_hide_reason','admin_proxy_reason',
--     'ob_series','ob_category','ob_tier'
--   ));
-- COMMENT ON COLUMN public.lookup_values.kind IS
--   'channel | category | content_type | ng_item | reject_reason | blacklist_reason | '
--   'violation_reason | caution | admin_email_kind | cancel_reason | message_hide_reason | '
--   'admin_proxy_reason | ob_series | ob_category | ob_tier';
