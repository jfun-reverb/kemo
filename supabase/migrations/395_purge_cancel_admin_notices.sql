-- ════════════════════════════════════════════════════════════════════
-- 395 — 이미 쌓인 「응모 취소 —」 공지사항을 지운다 (일회성)
--
-- 왜
--   394 가 자동 등록을 멈췄지만 **이미 쌓인 것은 그대로 남는다.** 그 공지들은
--   `published` 상태라 미읽음 배지와 로그인 팝업에 계속 뜨고, 운영 공지 75건 중
--   **64건(85%)이 이것**이라 사람이 쓴 공지 11건이 그 안에 묻힌다.
--   🔴 그리고 본문에 **회원 이름·이메일이 복사돼** 있는데 탈퇴 파기 함수(352)는
--      `admin_notices` 를 한 번도 안 건드린다 — 취소 이력이 있는 회원이 탈퇴하면
--      그 사본이 그대로 남는다. **394 와 이 파일이 함께 있어야 그 경로가 닫힌다.**
--   사양서 §3-3 · 인계 `docs/specs/2026-09-01-cancel-notice-stop-handoff.md` §4-B
--
-- 🔴 되돌릴 수 없다. 적용 전에 아래 [사전 확인]을 반드시 눈으로 볼 것.
--
-- 지우는 조건 — 넷을 모두 만족하는 행만
--   ① created_by IS NULL AND created_by_name = 'system'   (자동 등록이 넣은 값)
--   ② published_by IS NULL AND published_by_name = 'system'
--   ③ title LIKE '응모 취소 — %'                          (그 함수가 만든 제목)
--   ④ updated_by IS NULL AND updated_by_name IS NULL      (사람이 손댄 적 없음)
--
--   ⚠️ ①②③ 만으로도 운영 실측은 64건으로 같았지만(2026-09-01), **④를 빼지 않는다.**
--      나중에 누가 그 공지 하나를 열어 고쳐 두면 ④가 그 한 건을 살려 준다.
--      「지금 0건이니까」는 조건을 뺄 이유가 못 된다.
--   ⚠️ ③의 구분자는 **긴 붙임표(—, U+2014)** 다. 보통 붙임표(-)로 쓰면 0건이 나온다.
--      356 의 `'응모 취소 — '` 를 그대로 옮긴 것이다.
--
-- ⚠️ 읽음 기록(admin_notice_reads)은 따로 안 지운다 — `ON DELETE CASCADE` 라
--    공지 행이 사라지면 함께 사라진다(063). 운영 실측 35건.
--
-- ⚠️ 이 파일은 **한 번 돌리면 끝**이다. 다시 돌려도 해가 없지만(조건에 맞는 행이
--    없으므로 0건) 394 가 먼저 적용돼 있지 않으면 **지운 뒤에 또 쌓인다.**
--    🔴 **394 → 395 순서로 적용할 것.**
-- ════════════════════════════════════════════════════════════════════

-- ── [사전 확인] 지우기 전에 이것부터 돌려 눈으로 볼 것 ──────────────
--   기대: 지울것 = 64, 사람이손댄것 = 0, 전체 = 75
--
--   SELECT
--     count(*) FILTER (
--       WHERE created_by IS NULL AND created_by_name = 'system'
--         AND published_by IS NULL AND published_by_name = 'system'
--         AND title LIKE '응모 취소 — %'
--         AND updated_by IS NULL AND updated_by_name IS NULL
--     ) AS 지울것,
--     count(*) FILTER (
--       WHERE title LIKE '응모 취소 — %'
--         AND (updated_by IS NOT NULL OR updated_by_name IS NOT NULL)
--     ) AS 사람이손댄것,
--     count(*) FILTER (WHERE title LIKE '응모 취소 — %') AS 취소공지전체,
--     count(*) AS 전체
--   FROM public.admin_notices;
--
--   ⚠️ 「지울것」과 「취소공지전체」가 다르면 **사람이 손댄 것이 섞여 있다는 뜻**이다.
--      그 차이만큼은 일부러 안 지우는 것이니, 숫자를 확인하고 넘어갈 것.
-- ────────────────────────────────────────────────────────────────────

DO $$
DECLARE
  v_before  bigint;
  v_target  bigint;
  v_deleted bigint;
  v_reads   bigint;
BEGIN
  SELECT count(*) INTO v_before FROM public.admin_notices;

  SELECT count(*) INTO v_target
  FROM public.admin_notices
  WHERE created_by IS NULL AND created_by_name = 'system'
    AND published_by IS NULL AND published_by_name = 'system'
    AND title LIKE '응모 취소 — %'
    AND updated_by IS NULL AND updated_by_name IS NULL;

  -- 함께 사라질 읽음 기록 수 (CASCADE — 따로 지우지 않는다)
  SELECT count(*) INTO v_reads
  FROM public.admin_notice_reads r
  WHERE EXISTS (
    SELECT 1 FROM public.admin_notices n
    WHERE n.id = r.notice_id
      AND n.created_by IS NULL AND n.created_by_name = 'system'
      AND n.published_by IS NULL AND n.published_by_name = 'system'
      AND n.title LIKE '응모 취소 — %'
      AND n.updated_by IS NULL AND n.updated_by_name IS NULL
  );

  DELETE FROM public.admin_notices
  WHERE created_by IS NULL AND created_by_name = 'system'
    AND published_by IS NULL AND published_by_name = 'system'
    AND title LIKE '응모 취소 — %'
    AND updated_by IS NULL AND updated_by_name IS NULL;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- 지운 건수가 미리 센 것과 다르면 그 자리에서 되돌린다.
  --   같은 트랜잭션이라 사이에 끼어들 여지는 거의 없지만, 조건을 잘못 적었을 때
  --   **조용히 다 지우는 것**을 막는 마지막 방어선이다.
  IF v_deleted <> v_target THEN
    RAISE EXCEPTION '지울 것으로 센 수(%)와 실제 지운 수(%)가 다릅니다 — 되돌립니다',
      v_target, v_deleted;
  END IF;

  RAISE NOTICE '[395] 공지 % 건 중 % 건 삭제 (남은 것 %), 함께 사라진 읽음 기록 % 건',
    v_before, v_deleted, v_before - v_deleted, v_reads;
END $$;

-- ── [적용 후 확인] ──────────────────────────────────────────────────
--   기대: 취소공지 = 0, 남은공지 = 11 (사람이 쓴 것만)
--
--   SELECT
--     count(*) FILTER (WHERE title LIKE '응모 취소 — %') AS 취소공지,
--     count(*) AS 남은공지,
--     count(*) FILTER (WHERE created_by_name = 'system') AS 자동등록물
--   FROM public.admin_notices;
--
--   ⚠️ 「자동등록물」이 0 이 아니면 이 조건에 안 걸린 자동 공지가 있다는 뜻이다.
--      제목이 다른 종류일 수 있으니 확인할 것.
-- ────────────────────────────────────────────────────────────────────
