-- 444_campaigns_purchase_guide_mode.sql
-- 캠페인에 「구매 가이드」 판 구분 칸 하나를 더한다.
-- 사양서: docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-12 (결정 23·24)
-- 작업표: docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 작업 5 (마이그레이션 ⑥)
--
-- ── 무엇을 가르는 칸인가 ────────────────────────────────────────────────
-- 이번 개편은 리뷰어형 캠페인의 「캠페인 설명」 칸 **이름**을 「구매 가이드」로 바꾼다.
-- 그런데 그 칸은 이미 운영 중인 리뷰어형 캠페인이 쓰고 있고 거기에는 제품·브랜드 설명이 들어 있다.
-- 이름만 바꾸면 **옛 글이 새 이름 아래 놓여** 회원이 「이게 구매 방법인가」로 읽는다.
--   → 그래서 이 칸에 **값이 있으면 새 판, NULL 이면 옛 판**으로 가른다.
--
-- 🔴 날짜로 가르지 않는다(결정 24) — 「그날 이후 생성」으로 판정하면 화면에 보이는 것이 그날 전후로
--    갈리는데 **그 이유가 데이터 어디에도 안 남는다.** 칸 값으로 가르면 그 행을 열어 보면 바로 보인다.
--
-- ── 이 파일이 하는 일 ──────────────────────────────────────────────────
-- `campaigns.purchase_guide_mode text NULL` 한 칸 추가. 그것뿐이다.
--   'free'  = 자율구매   'fixed' = 지정구매   NULL = 고르지 않음(옛 판)
--
-- 🔴 DEFAULT 를 주지 않는다. 기본값을 주는 순간 기존 행이 전부 값을 갖게 되어
--    **운영 캠페인 전부가 그 자리에서 새 판이 된다**(검증 16번이 그것을 잡는다).
-- 🔴 NOT NULL 도 걸지 않는다 — 「고르지 않음」이 있어야 옛 캠페인을 있는 그대로 보여 줄 수 있고,
--    잘못 고른 것을 되돌릴 수 있다. 필수로 만들면 지금 있는 리뷰어형 캠페인을 아무것도 저장할 수 없게 된다.
--
-- ⚠️ 변경 이력 허용 목록(265 CHECK · 266 v_fields · 266 트리거의 AFTER UPDATE OF 목록)에
--    이 칸을 **넣지 않는다**. 세 곳을 동시에 고쳐야 하는 데다, 이 값은 사람이 바꾸는 설정이 아니라
--    **판을 가르는 표시**라 이력에 남길 실익이 적다(행사 칸 4종을 일부러 뺀 선례와 같다 — §4-12).
--    ⚠️ 그 목록에 안 넣었다고 이 칸의 UPDATE 가 막히지는 않는다. 265 의 CHECK 는 이력 표에만 걸린다.
--
-- ⚠️ 이 칸은 `campaigns_bump_version()`(275)의 제외 6개에 없으므로 **바뀌면 version 이 +1 된다.**
--    의도한 동작이다 — 동시 저장 방어가 이 칸에도 걸려야 한다.
--
-- ⚠️ 본문은 이 칸에 안 들어간다 — 지금처럼 `campaigns.description` 이다.
--    이 칸은 **어느 판인지와 자율/지정만** 담는다.

BEGIN;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS purchase_guide_mode text NULL;

-- 값은 셋뿐이다. 빈 문자열을 막는 것이 핵심 —
-- 🔴 빈 문자열은 「값이 있음」이라 화면이 **새 판으로 잘못 판정**한다(§4-12 「저장」).
ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_purchase_guide_mode_check;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_purchase_guide_mode_check
  CHECK (purchase_guide_mode IS NULL OR purchase_guide_mode IN ('free', 'fixed'));

COMMENT ON COLUMN public.campaigns.purchase_guide_mode IS
  '구매 가이드 판 구분(2026-09-16 §4-12) — free=자율구매 / fixed=지정구매 / NULL=고르지 않음(옛 판). 본문은 description 에 있다.';

-- 공개 데이터베이스 접근 계층(PostgREST)의 스키마 캐시를 즉시 갱신 —
-- 안 넣으면 배포 직후 잠깐 전체 조회에 이 칸이 안 보이는 구간이 생긴다(이 저장소 관행: 440~443 전부 있다)
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ══════════════════════════════════════════════════════════════════════
-- 검증 (적용 직후 — 사양서 §9-1 16·17번)
-- ══════════════════════════════════════════════════════════════════════
--
-- [V1] 🔴 16번 — 소급 변경 0건. **반드시 0 이어야 한다.**
--      한 건이라도 나오면 기본값을 잘못 준 것이고, 그 순간 운영 캠페인 전부가 새 판이 된다.
--
--   SELECT count(*) AS 값이_있는_행
--   FROM public.campaigns
--   WHERE purchase_guide_mode IS NOT NULL;
--   -- 기대: 0
--
-- [V2] 칸이 실제로 생겼는지 + 기본값이 없는지
--
--   SELECT column_name, data_type, is_nullable, column_default
--   FROM information_schema.columns
--   WHERE table_schema = 'public' AND table_name = 'campaigns'
--     AND column_name = 'purchase_guide_mode';
--   -- 기대: text / YES / column_default 가 비어 있음(NULL)
--
-- [V3] 17번 — 한 건에 값을 넣어 보고 되돌린다(되돌리기까지 한 묶음으로).
--      ⚠️ 그 캠페인의 version 이 +1 된다(275 트리거) — 의도한 동작이다.
--
--   BEGIN;
--     -- 리뷰어형 한 건을 골라 값을 넣는다
--     UPDATE public.campaigns SET purchase_guide_mode = 'free'
--     WHERE id = (SELECT id FROM public.campaigns
--                 WHERE recruit_type = 'monitor' AND deleted_at IS NULL
--                 ORDER BY created_at DESC LIMIT 1);
--     -- ⚠️ `type` 이 아니라 `recruit_type` 이다. 둘은 서로 무관한 별개 칸이고
--     --    `type` 에는 'qoo10'·'nano' 만 들어가 'monitor' 가 될 수 없다(항상 0행이 나온다).
--     SELECT count(*) AS 새_판 FROM public.campaigns WHERE purchase_guide_mode IS NOT NULL;
--     -- 기대: 1 (그 한 건만)
--   ROLLBACK;   -- 🔴 되돌린다. 커밋하면 그 캠페인이 새 판으로 남는다
--
-- [V4] 빈 문자열이 막히는지 — CHECK 가 실제로 도는지 본다
--
--   BEGIN;
--     UPDATE public.campaigns SET purchase_guide_mode = ''
--     WHERE id = (SELECT id FROM public.campaigns ORDER BY created_at DESC LIMIT 1);
--     -- 기대: 23514 (check constraint "campaigns_purchase_guide_mode_check" 위반)
--   ROLLBACK;
--
-- ══════════════════════════════════════════════════════════════════════
-- 되돌리기 (그대로 실행하면 이 파일이 한 일이 전부 사라진다)
-- ══════════════════════════════════════════════════════════════════════
--
--   BEGIN;
--   ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_purchase_guide_mode_check;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS purchase_guide_mode;
--   COMMIT;
--
-- ⚠️ 칸을 지우면 그때까지 고른 자율/지정 값도 함께 사라진다(되살릴 수 없다).
--    코드가 이미 그 칸을 읽고 있으면 **화면이 먼저 죽는다** — 되돌릴 때는 코드를 먼저 되돌린다.
