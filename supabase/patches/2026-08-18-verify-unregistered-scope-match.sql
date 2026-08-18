-- ============================================================
-- 2026-08-18-verify-unregistered-scope-match.sql
-- 「미등록 목록에 뜨는 건수」와 「그 전부를 등록 함수에 넣었을 때 등록되는 건수」가
-- 같은지 대조한다. ★ **아무것도 남기지 않는다** — 끝에서 되돌린다.
--
-- ▶ 왜 필요한가
--   337 이 목록 함수의 범위를 넓히고 등록 함수는 안 넓혀, 「목록엔 뜨는데 눌러도 조용히
--   빠지는」 어긋남이 있었다. 339 가 그것을 맞췄다고 **주장**하지만, 두 함수의 범위가
--   정말 같은지는 **읽어서는 알 수 없다**(또 다른 조건이 숨어 있는지 모른다).
--   실제로 넣어 보는 것 말고 확인할 길이 없다.
--
-- ▶ 🔴 되돌리는 거래로 감싸야 하는 이유
--   그냥 돌리면 **수백 건이 되돌릴 수 없이 등록된다.** 아래는 `BEGIN` 으로 열고
--   `ROLLBACK` 으로 닫아 **숫자만 얻고 아무것도 안 남긴다.**
--   ⚠️ **반드시 파일 전체를 한 번에** 실행할 것. 나눠서 실행하면 거래가 끊겨
--      되돌리기가 안 걸리고 진짜로 등록된다.
--
-- ▶ ⚠️ 관리자로 가장하는 이유
--   두 함수 모두 `has_permission(...)` 가드가 있는데, SQL 편집기는 서비스 키라
--   **로그인한 사용자가 없어** 그 가드에 막힌다(이 저장소에서 반복된 함정 —
--   마이그레이션 272·332 주석 참조). 그래서 `request.jwt.claims` 로 최고 관리자
--   한 명을 가장한다. 되돌리는 거래 안에서만 유효하다.
--
-- ▶ 언제 돌리나
--   ★ **작업 7(화면 잠금 해제) 전에.** 문을 연 뒤에 하면 운영자가 실수로 진짜 버튼을
--   누를 수 있는 상태와 겹친다.
-- ============================================================

BEGIN;

-- ① 최고 관리자 한 명으로 가장 (되돌리는 거래 안에서만)
SELECT set_config(
  'request.jwt.claims',
  json_build_object(
    'sub',  (SELECT a.auth_id::text FROM public.admins a
              WHERE a.role = 'super_admin' AND a.auth_id IS NOT NULL
              ORDER BY a.created_at LIMIT 1),
    'role', 'authenticated'
  )::text,
  true   -- true = 이 거래 안에서만
) AS 가장_설정;

SET LOCAL ROLE authenticated;

-- ② 목록 함수가 돌려주는 건수
--    · 전체 = 「미등록」 탭에 뜨는 줄 수
--    · 고를 수 있는 건 = 화면이 선택을 허용하는 줄(금액 미확정은 잠겨 있다)
SELECT
  count(*)                                          AS "목록에 뜨는 건수",
  count(*) FILTER (WHERE amount_issue IS NULL)      AS "화면에서 고를 수 있는 건수",
  count(*) FILTER (WHERE amount_issue IS NOT NULL)  AS "금액 미확정(선택 잠김)"
FROM public.get_past_unregistered_settlements();

-- ③ 그 「고를 수 있는 건」 전부를 등록 함수에 넣어 본다 (되돌린다)
--    ⚠️ 목표 상태를 **정산대기**로 둔다 — 송금완료로 넣으면 페이팔 확인에 걸려
--       건너뛴 건수가 섞여, 「범위가 같은가」라는 이 대조의 질문이 흐려진다.
SELECT
  registered_count        AS "실제로 등록되는 건수",
  skipped_no_paypal_count AS "페이팔 미등록으로 빠진 건수(정산대기라 0이어야 함)"
FROM public.register_past_settlements(
  ARRAY(
    SELECT application_id FROM public.get_past_unregistered_settlements()
     WHERE amount_issue IS NULL
  ),
  'pending',
  '범위 대조 시험 — 되돌림',
  NULL   -- 송금일 없음(정산대기라 넣으면 서버가 거부한다)
);

ROLLBACK;

-- ── 읽는 법 ────────────────────────────────────────────────
-- ★ **「화면에서 고를 수 있는 건수」 = 「실제로 등록되는 건수」** 여야 한다.
--
--   같다  → 두 함수의 범위가 일치한다. 작업 7 진행 가능.
--   적다  → 등록 함수에 **아직 남은 조건**이 있다. 그 차이만큼이 「목록엔 뜨는데
--           눌러도 빠지는」 건이다. **작업 7 전에 원인을 찾을 것.**
--   많다  → 있을 수 없다. 있으면 목록 함수가 뭔가를 빼고 있다는 뜻이다.
--
-- ⚠️ 되돌렸는지 확인 — 아래가 실행 전과 같아야 한다.
--   SELECT count(*) FROM public.settlements;
