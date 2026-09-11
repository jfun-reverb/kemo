-- ============================================================
-- 399. 모집 형식(recruit_type)에 허용값 제약을 건다
-- ============================================================
-- 전수조사(2차) 묶음 B — B-6. (보안이 아니라 데이터 정합)
-- 조사 근거: docs/research/2026-09-02-codebase-audit-findings.md §2-6
--
-- ── 무엇이 문제였나 ────────────────────────────────────────
-- `campaigns.recruit_type` 에 **허용값 제약이 없다**(`002_sync_schema.sql:58`).
-- 세 값(`monitor`·`gifting`·`visit`) 밖의 문자열이 들어가면
--   · 서버 인증 판정(`_settlement_cert_candidates`, 331)은 **시딩·방문형 갈래로 빠져
--     인증 성공으로 본다**
--   · 화면 판정(`admin-deliverables.js`)은 **절대 성공으로 안 본다**
-- → 같은 응모가 서버에선 지급 대상, 화면에선 미완료가 된다. 오류는 안 난다.
--
-- ── 왜 지금인가 (창이 닫힌다) ─────────────────────────────
-- 🔴 **제약은 위반 행이 0건일 때만 걸 수 있다.**
--    2026-09-03 운영 실측: `campaigns` 212건의 `recruit_type` 이
--    **`gifting` · `monitor` · `visit` 세 값뿐**이고 빈값도 없다.
--    네 번째 값이 하나라도 생기면 이 제약은 못 건다.
--
-- ── 무엇을 막고 무엇을 안 막나 ────────────────────────────
--  막는다   : 세 값 밖의 문자열
--  안 막는다: **NULL** — `CHECK` 는 NULL 을 「알 수 없음」으로 보고 통과시킨다.
--             ⚠️ 일부러 그렇게 뒀다. `NOT NULL` 을 함께 거는 것은 **다른 결정**이고,
--                그 칸을 비운 채 만드는 경로가 있는지 확인하지 않았다.
--
-- ⚠️ 화면이 보내는 값과 일치한다 — 관리자 등록·편집 폼의 라디오가
--    `monitor`·`gifting`·`visit` 셋뿐이다(`dev/admin/index.html`).
--    **값을 늘리려면 이 제약을 먼저 고쳐야 한다** — 안 고치면 저장이 거부된다.
--
-- ⚠️ `NOT VALID` 를 쓰지 않았다 — 위반이 0건이라 즉시 검증해도 잠금 시간이 짧고,
--    `NOT VALID` 로 두면 「걸어 놓고 검증 안 한」 상태가 남는다.
-- ============================================================

-- 적용 전 확인 (0이 아니면 적용하지 말 것)
DO $$
DECLARE v_bad integer;
BEGIN
  SELECT count(*) INTO v_bad
    FROM public.campaigns
   WHERE recruit_type IS NOT NULL
     AND recruit_type NOT IN ('monitor', 'gifting', 'visit');
  IF v_bad > 0 THEN
    RAISE EXCEPTION '허용값 밖 모집 형식이 %건 있다 — 제약을 걸기 전에 그 행부터 확인할 것', v_bad;
  END IF;
END $$;

ALTER TABLE public.campaigns
  DROP CONSTRAINT IF EXISTS campaigns_recruit_type_check;

ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_recruit_type_check
  CHECK (recruit_type IS NULL OR recruit_type IN ('monitor', 'gifting', 'visit'));

COMMENT ON CONSTRAINT campaigns_recruit_type_check ON public.campaigns IS
  '[399] 모집 형식 허용값. 세 값 밖이면 서버 인증 판정과 화면 판정이 갈린다(조사 §2-6). '
  'NULL 은 일부러 허용 — NOT NULL 은 별도 결정.';


-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 제약이 붙었는가
SELECT conname, pg_get_constraintdef(oid)
  FROM pg_constraint
 WHERE conrelid = 'public.campaigns'::regclass
   AND conname = 'campaigns_recruit_type_check';

-- [V2] 네 번째 값이 실제로 막히는가 (되돌린다)
BEGIN;
  UPDATE public.campaigns SET recruit_type = 'something_else'
   WHERE id = (SELECT id FROM public.campaigns LIMIT 1);
ROLLBACK;
-- 기대: new row for relation "campaigns" violates check constraint

-- [V3] 기존 세 값은 그대로 되는가
BEGIN;
  UPDATE public.campaigns SET recruit_type = recruit_type;
ROLLBACK;
-- 기대: 오류 없음
*/


-- ============================================================
-- 롤백
-- ============================================================
-- ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_recruit_type_check;
