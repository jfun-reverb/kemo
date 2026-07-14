-- ============================================================
-- 236_outbound_category_health_tech.sql
-- 2026-07-14
--
-- 목적:
--   아웃바운드 명단 전량 재이관(구글시트 917명)에서 발견된 신규 세분 카테고리
--   2종을 기준데이터 `ob_category` 에 추가한다.
--     - health (헬스/다이어트) — 시트 46명
--     - tech   (테크/기타)     — 시트 17명
--   기존 227 시드는 7종(color/base/fashion/vlog/kidsmom/food/other)이라, 이 2종이
--   없으면 재이관 seed 의 category_code='health'/'tech' 행이 화면 라벨·다중필터에서
--   raw 코드로 노출되고 2단계 조건 추천 매칭이 깨진다.
--
--   계열(series) 매핑은 코드 상수 `OB_CATEGORY_SERIES`(dev/lib/shared.js)에서 처리:
--     health → life(라이프),  tech → other(미분류)  — 사용자 확정(2026-07-14)
--   (lookup 에 부모 컬럼이 없어 매핑은 코드 상수. HANDOFF §PR-a 2번 항목 패턴)
--
-- 적용 순서:
--   이 마이그레이션(236) → seed `outbound_influencers_import.sql`(917행) 순서.
--   개발 DB 먼저 → 검증 → 운영 DB.
--
-- 기존 기능 영향:
--   - `lookup_values.kind` CHECK 에 'ob_category' 이미 포함(227) → CHECK 변경 없음, INSERT 만.
--   - 멱등: ON CONFLICT (kind, code) DO UPDATE → 재실행 안전.
--   - 기존 7종·다른 kind 무영향. 캠페인 등록 폼(category kind)과 무관(별도 kind).
--
-- 롤백:
--   DELETE FROM public.lookup_values WHERE kind='ob_category' AND code IN ('health','tech');
-- ============================================================

BEGIN;

INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES
  ('ob_category', 'health', '헬스', 'ヘルス', 65, true),
  ('ob_category', 'tech',   '테크', 'テック', 68, true)
ON CONFLICT (kind, code) DO UPDATE
  SET name_ko     = EXCLUDED.name_ko,
      name_ja     = EXCLUDED.name_ja,
      sort_order  = EXCLUDED.sort_order,
      active      = EXCLUDED.active;

NOTIFY pgrst, 'reload schema';

COMMIT;
