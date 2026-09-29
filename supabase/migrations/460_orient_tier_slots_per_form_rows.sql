-- ============================================================
-- 460_orient_tier_slots_per_form_rows.sql
-- 2026-09-21 — 오리엔시트 구간 인원을 리뷰어·시딩 따로 · 마이그레이션 ①(행 추가만)
--   사양서 docs/specs/2026-09-21-orient-tier-slots-per-form.md §3-1 · §3-5
--   베이스: 458_quote_settings_tmin_rows.sql(같은 성격 — 행 추가만) + 453_quote_settings_tier_slots.sql
--           (unit='count' CHECK 를 처음 허용한 파일 — 이 파일은 그 값을 그대로 씀) +
--           459_orient_tier_five_and_direct_input.sql(지금 공용 5행의 뜻·값의 최종 상태)
--
-- 무엇을 하나 — 새 10행 추가만. 기존 행은 단 한 줄도 UPDATE·DELETE 하지 않는다. 함수 재정의도 없다.
--   [A] reviewer_tier_min_slots · reviewer_tier_slots_t50/t100/t300/t500plus   (리뷰어 구간 인원 5행)
--   [B] seeding_tier_min_slots  · seeding_tier_slots_t50/t100/t300/t500plus   (시딩 구간 인원 5행)
--   → 적용 뒤 quote_settings 는 40 + 10 = 50행(458 까지 적용된 40행 기준).
--
-- 값은 **지금 공용 5행(tier_min_slots·tier_slots_t50/t100/t300/t500plus)에서 그대로 복사**한다
-- (INSERT … SELECT … LEFT JOIN, 개발 DB 에서 누가 값을 이미 고쳐 뒀어도 그 값을 이어받는다).
-- 옛 행이 하나라도 없으면(재현 환경 등) 사양서 §3-1 이 정한 기본값(1·50·150·300·500)으로 채운다.
--
-- 🔴 이 파일이 하는 일은 "행을 추가하는 것"뿐이라, 적용 뒤에도 이 10행을 읽는 코드가 아직 없다
--   (그 코드는 461 이 만든다) — 그래서 **견적 금액·폼 표시가 한 가지도 안 바뀐다**(파일 하단 [V1]).
--   458 가 같은 이유로 같은 방식을 썼다(머리말 참고) — ①과 ②를 분리하는 이 저장소의 관례.
--
-- ------------------------------------------------------------
-- 🔴 sort_order 28~37 — 지금 비어 있는 자리(2026-09-21 확인, 사양서 §3-1)
-- ------------------------------------------------------------
--   현재 점유: 공통(10·11) · 구간(12~16, 458 의 tier_min_slots=16 포함) · 리뷰어(20~27) ·
--   시딩(39~43·49~53·59~63·69~73·79~83, 458 의 tmin 5행이 각 채널 블록 앞 39·49·59·69·79 를 이미 씀).
--   즉 리뷰어 블록(27) 과 시딩 블록(39) 사이 28~38 이 통째로 비어 있다 — 새 10행을 그 사이(28~37)에 둔다.
--   ⚠️ `sort_order` 에 유일 제약이 없어 겹쳐도 오류가 안 나고 조용히 `key` 알파벳순으로 자리가
--   바뀐다(458 머리말이 이미 겪은 함정) — 이 파일도 적용 전 겹침 여부를 육안으로 확인했다.
--
-- ------------------------------------------------------------
-- ⚠️ `unit` 은 반드시 'count' — 453 이 CHECK 제약에 이미 추가해 둔 값이라 이 파일은 새 제약이 필요 없다.
--   'count' 가 아니면 관리자 화면(quoteAmountText, admin-lookups.js)이 "50 원" 으로 그린다.
-- ------------------------------------------------------------
--
-- 롤백: 이 파일이 만든 10행만 DELETE(맨 아래 「되돌리기」). 🔴 461 을 먼저 되돌린 뒤에 이 파일을
--   되돌릴 것 — 461 의 함수들은 이 10행을 읽으므로, 이 파일을 먼저 되돌리면(행을 지우면) 461 의
--   판정식이 전부 fee_missing 이 된다(453/458 되돌리기 순서와 같은 이유).
-- ============================================================

BEGIN;

INSERT INTO public.quote_settings (key, amount, unit, label_ko, group_ko, sort_order)
SELECT v.key,
       COALESCE(o.amount, v.default_amount),
       'count',
       v.label_ko,
       v.group_ko,
       v.sort_order
  FROM (VALUES
    -- [A] 리뷰어 구간 인원 5행 — sort_order 28~32
    ('reviewer_tier_min_slots',      'tier_min_slots',      1::numeric,
       '리뷰어 — 최소 모집 인원 (이 값보다 적은 인원은 접수하지 않음)', '리뷰어 구간 인원', 28),
    ('reviewer_tier_slots_t50',      'tier_slots_t50',      50::numeric,
       '리뷰어 — 라이트 시작 인원 (이 값부터 라이트 구간)', '리뷰어 구간 인원', 29),
    ('reviewer_tier_slots_t100',     'tier_slots_t100',     150::numeric,
       '리뷰어 — 스탠다드 시작 인원 (이 값부터 스탠다드 구간)', '리뷰어 구간 인원', 30),
    ('reviewer_tier_slots_t300',     'tier_slots_t300',     300::numeric,
       '리뷰어 — 프리미엄 시작 인원 (이 값부터 프리미엄 구간)', '리뷰어 구간 인원', 31),
    ('reviewer_tier_slots_t500plus', 'tier_slots_t500plus', 500::numeric,
       '리뷰어 — 실검작업 구간 시작 인원 (이 값 이상이면 실검작업 구간)', '리뷰어 구간 인원', 32),
    -- [B] 시딩 구간 인원 5행 — sort_order 33~37. 값은 리뷰어와 같은 옛 공용 행에서 복사(초기값은 사용자
    --   결정 미확정 — 사양서 §2-3. 운영 배포 전 담당자가 「견적 기준값」 화면에서 실제 값으로 고친다).
    ('seeding_tier_min_slots',       'tier_min_slots',      1::numeric,
       '시딩 — 최소 모집 인원 (이 값보다 적은 인원은 접수하지 않음)', '시딩 구간 인원', 33),
    ('seeding_tier_slots_t50',       'tier_slots_t50',      50::numeric,
       '시딩 — 라이트 시작 인원 (이 값부터 라이트 구간)', '시딩 구간 인원', 34),
    ('seeding_tier_slots_t100',      'tier_slots_t100',     150::numeric,
       '시딩 — 스탠다드 시작 인원 (이 값부터 스탠다드 구간)', '시딩 구간 인원', 35),
    ('seeding_tier_slots_t300',      'tier_slots_t300',     300::numeric,
       '시딩 — 프리미엄 시작 인원 (이 값부터 프리미엄 구간)', '시딩 구간 인원', 36),
    ('seeding_tier_slots_t500plus',  'tier_slots_t500plus', 500::numeric,
       '시딩 — 실검작업 구간 시작 인원 (이 값 이상이면 실검작업 구간)', '시딩 구간 인원', 37)
  ) AS v(key, old_key, default_amount, label_ko, group_ko, sort_order)
  LEFT JOIN public.quote_settings o ON o.key = v.old_key
ON CONFLICT (key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후)
-- ============================================================
/*
-- [V1] 10행이 정확히 들어갔는가 · 전체 건수 40 + 10 = 50(458 까지 적용된 40행 기준)
SELECT count(*) FROM public.quote_settings;  -- 기대: 50
SELECT key, amount, unit, group_ko, sort_order FROM public.quote_settings
 WHERE key LIKE 'reviewer_tier_%' OR key LIKE 'seeding_tier_%'
 ORDER BY sort_order;
-- 기대: 10행. reviewer_tier_min_slots=1 · _t50=50 · _t100=150 · _t300=300 · _t500plus=500 (옛 공용 행과 같은 값),
--       seeding_ 5행도 값이 같음(초기 복사) — unit 전부 'count'

-- [V2] 🔴 이 파일만 적용된 상태에서는 견적 금액·폼 표시가 한 가지도 안 바뀐다
--   (461 이전이라 옛 함수는 여전히 tier_slots_t50 등 공용 열쇠만 읽는다 — 아래는 그대로 t50 이어야 한다)
SELECT public._orient_compute_quote(
  '{"issued":{"form_type":"reviewer","channel":null},
    "cards":[{"product":{"slots":"30"},"sale":{"price_regular":"3429"}}]}'::jsonb,
  'B0001-A001-C001', now() + interval '30 days', now()) -> 'quote' ->> 'tier';
-- 기대: t50 (아직 새 열쇠를 아무도 안 읽는다 — 461 적용 후에는 tmin 으로 바뀐다, 최소 인원 1 기준)

-- [V3] sort_order 겹침 없는가(458 까지의 값과 이 파일의 28~37 이 안 겹치는지)
SELECT sort_order, count(*) FROM public.quote_settings GROUP BY sort_order HAVING count(*) > 1;
-- 기대: 0행

-- [V4] 견적 기준값 화면에 50행이 보이는가(관리자 로그인 브라우저 콘솔)
--   await db.rpc('get_quote_settings')  → 50행, group_ko 에 '리뷰어 구간 인원'·'시딩 구간 인원' 포함
*/

-- ============================================================
-- 되돌리기 (그대로 실행)
-- ============================================================
/*
BEGIN;
DELETE FROM public.quote_settings WHERE key IN (
  'reviewer_tier_min_slots', 'reviewer_tier_slots_t50', 'reviewer_tier_slots_t100',
  'reviewer_tier_slots_t300', 'reviewer_tier_slots_t500plus',
  'seeding_tier_min_slots', 'seeding_tier_slots_t50', 'seeding_tier_slots_t100',
  'seeding_tier_slots_t300', 'seeding_tier_slots_t500plus'
);
NOTIFY pgrst, 'reload schema';
COMMIT;
*/
