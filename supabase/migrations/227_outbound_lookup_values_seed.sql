-- ============================================================
-- 227_outbound_lookup_values_seed.sql
-- 인플루언서 추천 도구 1단계-a — 2/4 (기준 데이터 3종)
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md §현재 상태·B-⑤
-- 인계서: docs/specs/2026-07-09-influencer-recommendation-stage1-handoff.md §계열 매핑
--
-- 신규 kind 3종을 lookup_values 에 추가한다(160_admin_proxy_deliverable.sql 이후
-- 최신 CHECK 제약 12종에 3종을 더해 15종으로 확장 — 106/160 의
-- DROP CONSTRAINT IF EXISTS → ADD CONSTRAINT 패턴을 그대로 미러):
--   - ob_series   (계열: 뷰티/패션/라이프/푸드/미분류)
--   - ob_category (세분: 색조·기초·패션·브이로그·키즈맘·푸드·기타)
--   - ob_tier     (등급: 사양서 §현재 상태 "등급(마이크로 1~5만 / 미들 5~30만 /
--                  메가 30만+)" 원본 시트 정의 그대로 3단계 — REVERB 기존
--                  min_followers 정책과 무관한 아웃바운드 전용 구간)
--
-- ⚠️ 세분→계열 매핑(색조/기초→뷰티, 브이로그/키즈맘→라이프 등)은 lookup_values 에
--   부모 컬럼을 두지 않는다. 매핑은 클라이언트 코드 상수
--   `OB_CATEGORY_SERIES`(dev/lib/shared.js, PR 1단계-b 예정)에 두고,
--   outbound_influencers.category_code 저장 시 series_code 를 자동 채운다
--   (HANDOFF §PR-a 2번 항목 — "lookup에 부모 컬럼이 없으므로" 명시).
--
-- ⚠️ 기존 중복 확인 완료(.claude/rules/supabase.md 「기준 데이터 추가 시 중복 확인」):
--   grep -rni "ob_series\|ob_category\|ob_tier\|outbound" supabase/seed/ supabase/migrations/
--   결과 0건(사양서·인계서 조사 시점 확인). 기존 category kind(beauty/food/fashion/
--   health/other)는 캠페인 등록 폼용 대분류라 이 신규 kind 와 이름은 겹치되(food 등)
--   kind 가 달라 UNIQUE(kind, code) 충돌 없음 — 의미상으로도 완전히 다른 용도(캠페인
--   카테고리 vs 아웃바운드 명단 계열)라 별도 kind 신설이 맞다고 판단.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. lookup_values.kind CHECK 확장 (12종 → 15종)
--    현재(160 누적): channel/category/content_type/ng_item/reject_reason/
--    blacklist_reason/violation_reason/caution/admin_email_kind/cancel_reason/
--    message_hide_reason/admin_proxy_reason
--    추가: ob_series/ob_category/ob_tier
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
    'ob_tier'
  ));

COMMENT ON COLUMN public.lookup_values.kind IS
  'channel | category | content_type | ng_item | reject_reason | blacklist_reason | '
  'violation_reason | caution | admin_email_kind | cancel_reason | message_hide_reason | '
  'admin_proxy_reason | ob_series | ob_category | ob_tier';

-- ============================================================
-- 2. 시드 — ob_series (계열)
-- ============================================================
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('ob_series', 'beauty',  '뷰티',   'ビューティ', 10, true),
  ('ob_series', 'fashion', '패션',   'ファッション', 20, true),
  ('ob_series', 'life',    '라이프', 'ライフ',      30, true),
  ('ob_series', 'food',    '푸드',   'フード',      40, true),
  ('ob_series', 'other',  '미분류', '未分類',      50, true)
ON CONFLICT (kind, code) DO UPDATE SET
  name_ko = EXCLUDED.name_ko,
  name_ja = EXCLUDED.name_ja,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active,
  updated_at = now();

-- ============================================================
-- 3. 시드 — ob_category (세분, HANDOFF §계열 매핑 확정표)
--    뷰티=색조·기초 / 패션=패션 / 라이프=브이로그·키즈맘 / 푸드=푸드(독립) / 미분류=기타
-- ============================================================
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('ob_category', 'color',   '색조',     'カラー',       10, true),
  ('ob_category', 'base',    '기초',     'ベースケア',   20, true),
  ('ob_category', 'fashion', '패션',     'ファッション', 30, true),
  ('ob_category', 'vlog',    '브이로그', 'Vlog',         40, true),
  ('ob_category', 'kidsmom', '키즈맘',   'ママ・キッズ', 50, true),
  ('ob_category', 'food',    '푸드',     'フード',       60, true),
  ('ob_category', 'other',   '기타',     'その他',       70, true)
ON CONFLICT (kind, code) DO UPDATE SET
  name_ko = EXCLUDED.name_ko,
  name_ja = EXCLUDED.name_ja,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active,
  updated_at = now();

-- ============================================================
-- 4. 시드 — ob_tier (등급, 사양서 §현재 상태 원본 시트 3단계 그대로)
--    이름에 팔로워 구간을 병기(HANDOFF "등급, name에 팔로워 구간 병기").
--    ⚠️ REVERB 기존 campaigns.min_followers 단일 값 정책과 무관한
--       아웃바운드 명단 전용 구간 — 팔로워 자동계산 안 함(시트값 우선, HANDOFF 결정 #3).
-- ============================================================
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active) VALUES
  ('ob_tier', 'micro',  '마이크로 (1만~5만)',  'マイクロ (1万〜5万)',  10, true),
  ('ob_tier', 'middle', '미들 (5만~30만)',     'ミドル (5万〜30万)',   20, true),
  ('ob_tier', 'mega',   '메가 (30만~)',        'メガ (30万〜)',        30, true)
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

-- [V0] CHECK 제약 확장 확인 (15종 포함 여부)
SELECT pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conname = 'lookup_values_kind_check';

-- [V1] 시드 확인 (ob_series 5행 / ob_category 7행 / ob_tier 3행 = 총 15행)
SELECT kind, code, name_ko, name_ja, sort_order, active
FROM lookup_values
WHERE kind IN ('ob_series', 'ob_category', 'ob_tier')
ORDER BY kind, sort_order;

-- [V2] 기존 category(캠페인용) kind 와 신규 ob_series/ob_category 가 서로
--   완전히 분리된 kind 인지(코드 중복은 허용되지만 의미상 다른 테이블에서만 참조) 재확인
SELECT kind, code, name_ko FROM lookup_values
WHERE kind IN ('category', 'ob_series', 'ob_category') AND code IN ('food', 'fashion', 'other')
ORDER BY kind, code;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DELETE FROM lookup_values WHERE kind IN ('ob_series', 'ob_category', 'ob_tier');
--
-- ALTER TABLE public.lookup_values DROP CONSTRAINT IF EXISTS lookup_values_kind_check;
-- ALTER TABLE public.lookup_values
--   ADD CONSTRAINT lookup_values_kind_check
--   CHECK (kind IN (
--     'channel','category','content_type','ng_item','reject_reason',
--     'blacklist_reason','violation_reason','caution','admin_email_kind',
--     'cancel_reason','message_hide_reason','admin_proxy_reason'
--   ));
