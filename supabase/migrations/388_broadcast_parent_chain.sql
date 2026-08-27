-- ============================================================
-- 388. 일괄 발송 사슬 — 부모 칸 추가 (후속 발송 1단계 ①)
--
-- 왜 필요한가
--   「같은 조건으로, 아직 안 받은 사람에게만 추가 발송」을 하려면
--   **어느 발송의 추가분인가**를 남겨야 한다. 그래야 3차 발송이
--   1차·2차 수신자를 **둘 다** 뺄 수 있다(한 겹만 보면 2차 수신자가 또 받는다).
--
-- 🔴 뺄 대상은 「부모 하나」가 아니라 **뿌리와 그 뿌리의 모든 자손**이다.
--    다음 마이그레이션(대상 고르기 함수)이 이 칸을 타고 위로 올라가 뿌리를 찾고,
--    다시 아래로 내려가며 전부 모은다.
--
-- ⚠️ ON DELETE SET NULL 인 이유 — 부모가 지워져도 **자식 발송 기록은 남아야** 한다
--    (누구에게 무엇을 보냈나는 지워지면 안 되는 기록이다).
--    🔴 그런데 그 순간 자식이 **스스로 뿌리가 되어** 앞선 수신자들이 뺄 집합에서
--       통째로 빠진다 — 이 기능이 막으려던 중복 발송이 그대로 일어난다.
--    ⚠️ **지금은 안전하다** — 발송 그룹 행이 지워지는 경로는 「넣은 통이 0건일 때」
--       하나뿐이고, 0건 발송은 **자식이 생길 기회 자체가 없다**(부모가 되려면 그
--       발송 상세에서 「추가 발송」을 눌러야 하는데 0건이면 그룹 행이 이미 없다).
--    🔴 **발송 그룹을 지우는 경로가 새로 생기면 이 근거가 깨진다.** 그때는 뿌리
--       판정을 다시 볼 것.
--
-- ⚠️ 이 파일만 적용된 상태는 **동작 변화가 0** 이다 — 이 칸을 채우는 경로가 아직 없다.
--
-- 사양서 `docs/specs/2026-08-27-bulk-message-followup-send.md` 설계 2
-- ============================================================

BEGIN;

ALTER TABLE public.application_message_broadcasts
  ADD COLUMN IF NOT EXISTS parent_broadcast_id uuid NULL
    REFERENCES public.application_message_broadcasts(id) ON DELETE SET NULL;

COMMENT ON COLUMN public.application_message_broadcasts.parent_broadcast_id IS
  '[388] 이 발송이 어느 발송의 추가분인가. 최초 발송은 NULL. '
  '사슬은 나무가 아니라 줄이어야 한다 — 한 뿌리에 「진행 중인 추가 발송」은 한 줄만 두고, '
  '새 추가 발송은 항상 그 줄의 마지막에 붙인다(서버가 거부로 강제한다). '
  '뺄 집합은 뿌리와 그 뿌리의 모든 자손이며, 회수된 발송의 수신자도 뺀다 '
  '(회수는 가리는 것이지 안 보낸 것이 아니다).';

-- 사슬을 아래로 훑을 때 쓰는 색인. 부모가 있는 행만 담는다(대부분의 발송은 NULL).
CREATE INDEX IF NOT EXISTS idx_broadcasts_parent
  ON public.application_message_broadcasts (parent_broadcast_id)
  WHERE parent_broadcast_id IS NOT NULL;

COMMIT;

-- ── 적용 후 확인 ──
-- [1] 칸이 생겼고 비어 있는가 (기대: 1, 0)
-- SELECT
--   (SELECT count(*) FROM information_schema.columns
--     WHERE table_schema='public' AND table_name='application_message_broadcasts'
--       AND column_name='parent_broadcast_id')                       AS 칸_1,
--   (SELECT count(*) FROM public.application_message_broadcasts
--     WHERE parent_broadcast_id IS NOT NULL)                         AS 값있는행_0;
--
-- [2] 지움 규칙이 SET NULL 인가 (기대: SET NULL)
-- SELECT rc.delete_rule
--   FROM information_schema.referential_constraints rc
--   JOIN information_schema.key_column_usage k
--     ON k.constraint_name = rc.constraint_name
--  WHERE k.table_schema = 'public'
--    AND k.table_name   = 'application_message_broadcasts'
--    AND k.column_name  = 'parent_broadcast_id';
--
-- [3] 기존 발송 이력이 그대로인가 (기대: 적용 전과 같은 수)
-- SELECT count(*) AS 발송이력_수 FROM public.application_message_broadcasts;
