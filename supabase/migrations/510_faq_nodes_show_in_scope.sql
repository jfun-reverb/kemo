-- 마이그레이션 510: faq_nodes 노출 범위 2칸 추가 (캠페인 문의 / 서비스 문의)
--
-- 편집기 경고: 안 뜸 (ALTER TABLE ADD COLUMN · UPDATE 에 WHERE 있음 · DROP/DELETE 없음)
--
-- 목적
--   자주 묻는 질문 노드(카테고리·항목 모두)를 "캠페인 문의 / 서비스 문의" 중 어디에 보일지 운영자가 고르게 한다.
--   지금은 서비스 문의 쪽 노출이 화면 코드(dev/js/messaging.js `_faqNodeInGeneral` + `FAQ_GENERAL_CATEGORY_IDS`)에 박혀 있다.
--
-- 사용자 결정 (2026-10-07)
--   - show_in_campaign boolean NOT NULL DEFAULT true  / show_in_service boolean NOT NULL DEFAULT false
--   - 노출 판정 = 자기 칸 AND 모든 상위 카테고리의 같은 칸 (active 상속과 같은 모양 — 판정은 화면 코드 몫)
--   - 둘 다 false 허용 (검사 제약 없음)
--
-- 백필: 현재 동작을 그대로 보존
--   - campaign: 전 행 true (현재 캠페인 쪽은 활성 노드를 전부 보여준다 — 기본값 그대로)
--   - service : 맨 위 카테고리가 {…0005, …0006, …0007} 이고
--               (자기가 카테고리이거나 relevant_stages 가 NULL/빈 배열) 인 행만 true. 나머지 false.
--               맨 위 카테고리 찾기는 재귀 쿼리(항목 아래 항목 등 중첩도 처리).
--               ⚠️ active 는 백필에 안 쓴다 — 화면이 active 를 따로 거른다(상속).
--
-- 접근 정책: 변경 없음
--   기존 146 정책이 그대로 덮는다 — SELECT 는 authenticated(USING true, 열 제한 없음),
--   INSERT/UPDATE/DELETE 는 is_campaign_admin(). 새 열도 같은 행 정책을 따르므로 추가 정책·함수 변경 불필요.
--
-- 배포 순서: 🔴 데이터베이스(이 파일) 먼저 → 코드 나중.
--   (코드가 먼저 나가면 없는 열을 읽고 쓰다 자주 묻는 질문 화면이 통째로 실패)
--
-- 적용 전 점검 (조회만)
--   SELECT count(*) AS roots_found FROM public.faq_nodes
--    WHERE id IN ('00000001-0000-0000-0000-000000000005','00000001-0000-0000-0000-000000000006','00000001-0000-0000-0000-000000000007');
--   SELECT kind, count(*) FROM public.faq_nodes GROUP BY kind;
--   -- 뿌리 3개가 모두 있으면 roots_found = 3. 0 이면 서비스 쪽 true 가 0건이 되니 멈추고 확인.
--
-- 적용 후 검증 (조회만 — 한 단계씩)
--   1) 서비스 true 건수 vs 현재 규칙을 독립 계산한 건수 (두 수가 같아야 함)
--      WITH RECURSIVE t AS (
--        SELECT id, id AS root FROM public.faq_nodes WHERE parent_id IS NULL
--        UNION ALL
--        SELECT c.id, t.root FROM public.faq_nodes c JOIN t ON c.parent_id = t.id
--      )
--      SELECT
--        (SELECT count(*) FROM public.faq_nodes WHERE show_in_service) AS service_true,
--        (SELECT count(*) FROM public.faq_nodes n JOIN t ON t.id = n.id
--          WHERE t.root IN ('00000001-0000-0000-0000-000000000005','00000001-0000-0000-0000-000000000006','00000001-0000-0000-0000-000000000007')
--            AND (n.kind = 'category' OR n.relevant_stages IS NULL OR cardinality(n.relevant_stages) = 0)) AS rule_count;
--   2) 캠페인 칸이 전부 true / 총 행 수
--      SELECT count(*) AS total, count(*) FILTER (WHERE show_in_campaign) AS camp_true FROM public.faq_nodes;
--   3) 열 정의 (NOT NULL · 기본값)
--      SELECT column_name, is_nullable, column_default FROM information_schema.columns
--       WHERE table_schema='public' AND table_name='faq_nodes' AND column_name LIKE 'show_in_%';
--
-- 롤백
--   ALTER TABLE public.faq_nodes DROP COLUMN show_in_campaign, DROP COLUMN show_in_service;
--   (⚠️ 롤백하면 운영자가 정한 노출 선택이 사라진다. 코드를 먼저 되돌린 뒤 실행)

ALTER TABLE public.faq_nodes
  ADD COLUMN IF NOT EXISTS show_in_campaign boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_in_service  boolean NOT NULL DEFAULT false;

-- 백필: 현재 서비스 문의 규칙 그대로 (뿌리에서 아래로 내려가며 뿌리 아이디를 달고 간다)
WITH RECURSIVE tree AS (
  SELECT id, id AS root_id
    FROM public.faq_nodes
   WHERE id IN ('00000001-0000-0000-0000-000000000005',
                '00000001-0000-0000-0000-000000000006',
                '00000001-0000-0000-0000-000000000007')
     AND parent_id IS NULL
  UNION ALL
  SELECT c.id, tree.root_id
    FROM public.faq_nodes c
    JOIN tree ON c.parent_id = tree.id
)
UPDATE public.faq_nodes n
   SET show_in_service = true
  FROM tree
 WHERE n.id = tree.id
   AND (n.kind = 'category'
        OR n.relevant_stages IS NULL
        OR cardinality(n.relevant_stages) = 0);
