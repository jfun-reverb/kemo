-- ============================================================
-- 393. 일괄 발송 — 관리자 전용 제목 고치기
--
-- 무엇을 바꾸나
--   `application_message_broadcasts.title` 을 나중에 고칠 수 있게 하는 함수 하나를 만든다.
--
-- 왜
--   제목은 **보낼 때 한 번**만 정할 수 있었다(`bulkTitle` 입력칸). 그 뒤로는 고칠 길이
--   아예 없었다 — 이 표에는 **읽기 정책만** 있고(144 `admin_read_broadcasts`) 쓰기는
--   서버 함수만 하는데, 제목을 고치는 함수가 없었기 때문이다.
--   그래서 오타를 내거나 나중에 찾기 어려운 이름을 붙이면 **영영 그대로 굳었다.**
--
-- 누가 고칠 수 있나 — **`is_campaign_admin()`**(캠페인 관리자 이상)
--   사용자 결정(2026-08-27): 「일괄발송할 수 있는 누구나」.
--   일괄 발송(`send_application_message_bulk`, 390)의 가드가 정확히 이것이라 같게 맞췄다.
--   ⚠️ **보낸 본인으로 좁히지 않는다.** 회수(`withdraw_broadcast`, 167)는 「본인 또는 최고
--      관리자」인데 그것과 다르다 — 회수는 **인플루언서가 보는 것**을 바꾸지만 제목은
--      관리자에게만 보이는 내부 이름표다. 본인으로 좁히면 **보낸 사람이 회사를 떠난 발송은
--      영영 이름을 못 고친다.**
--
-- 회수된 발송도 고칠 수 있나 — **그렇다**
--   사용자 결정(2026-08-27). 회수는 「보낸 것을 가린다」이지 기록을 지우는 게 아니고,
--   나중에 찾아보려고 이름을 고치는 일은 오히려 회수된 것에 더 많다.
--
-- ⚠️ 바꾼 기록은 남기지 않는다
--   이 표에는 변경 이력이 없고, 제목은 금전·발송 내용처럼 감사가 필요한 값이 아니다.
--   대신 「누가 언제 뭐라고 바꿨는지」는 알 수 없다. 오리엔 메모(297)에서 같은 판단을 했다.
--
-- ⚠️ 낙관적 잠금 없음 — 마지막 저장이 이긴다.
--   한 줄짜리 이름표라 동시에 고쳐 어긋나도 잃는 것이 없다.
--
-- 되돌리는 방법
--   DROP FUNCTION IF EXISTS public.update_broadcast_title(uuid, text);
-- ============================================================

CREATE OR REPLACE FUNCTION public.update_broadcast_title(
  p_broadcast_id uuid,
  p_title        text
)
RETURNS text                      -- 저장된 제목(비웠으면 NULL)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_title text;
BEGIN
  -- [1] 권한 — 일괄 발송과 같은 조건
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)'
      USING ERRCODE = '42501';
  END IF;

  IF p_broadcast_id IS NULL THEN
    RAISE EXCEPTION '발송을 지정해 주세요' USING ERRCODE = '22023';
  END IF;

  -- [2] 다듬기 — 공백만 남으면 「제목 없음」으로 되돌린다.
  --     ⚠️ 빈 문자열로 저장하면 화면이 「제목이 있다」로 읽어 빈 줄을 그린다.
  v_title := NULLIF(btrim(COALESCE(p_title, '')), '');

  -- [3] 길이 — 입력칸(maxlength=100)과 같은 한도를 서버에서도 지킨다.
  --     ⚠️ 화면만 믿으면 함수를 직접 부르는 경로로 얼마든지 길어진다.
  IF v_title IS NOT NULL AND length(v_title) > 100 THEN
    RAISE EXCEPTION '제목은 100자까지입니다' USING ERRCODE = '22023';
  END IF;

  -- [4] 저장. 회수된 발송도 대상이다(위 머리말 참조).
  UPDATE public.application_message_broadcasts
     SET title = v_title
   WHERE id = p_broadcast_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION '그 발송을 찾지 못했습니다' USING ERRCODE = '22023';
  END IF;

  RETURN v_title;
END;
$$;

COMMENT ON FUNCTION public.update_broadcast_title(uuid, text) IS
  '일괄 발송의 관리자 전용 제목을 고친다. campaign_admin 이상. '
  '회수된 발송도 대상. 공백만 넣으면 제목 없음으로 되돌아간다. 변경 이력은 남기지 않는다.';

-- 🔴 실행 권한 — 기본값이 둘 겹친다.
--    Postgres 는 새 함수에 PUBLIC 실행 권한을 주고, Supabase 는 거기 더해 anon·authenticated
--    에 개별로 준다. 두 회수는 **서로를 대신하지 못한다**(369·370 이 그래서 둘로 나뉘어 있다).
--    ⚠️ 이 파일을 나중에 `DROP` 후 `CREATE` 로 재작성하면 아래 두 줄을 **반드시 그 파일에
--       다시 넣을 것.** 안 넣으면 비로그인 누구나 남의 발송 제목을 바꿀 수 있다.
--       (2026-08-27 에 387 에서 실제로 이 함정을 밟았다.)
REVOKE EXECUTE ON FUNCTION public.update_broadcast_title(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.update_broadcast_title(uuid, text) TO authenticated;

-- ============================================================
-- 적용 뒤 확인
--
-- ── [1] 권한이 제대로 닫혔나 ──
--    기대: anon열림 = false / 로그인열림 = true / 누구나열림_위험 = false
-- SELECT p.proname,
--        has_function_privilege('anon', p.oid, 'EXECUTE')          AS anon열림,
--        has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인열림,
--        (COALESCE(p.proacl::text,'') LIKE '{=X/%')                AS 누구나열림_위험,
--        COALESCE(p.proacl::text,'(기본값=누구나)')                AS 권한원문
--   FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--  WHERE n.nspname = 'public' AND p.proname = 'update_broadcast_title';
--
-- ── [2] 관리자 가드가 도는가 ──
--    ⚠️ SQL 편집기는 서비스 키라 로그인 사용자가 비어 있어 `is_campaign_admin()` 이
--       false 가 된다. 즉 **여기서 부르면 42501 이 나오는 것이 정상**이다.
--       실제 동작은 로그인한 관리자 브라우저에서 확인할 것.
-- SELECT public.update_broadcast_title('00000000-0000-0000-0000-000000000000', '시험');
--
-- ── [3] 브라우저(로그인한 캠페인 관리자 이상)에서 ──
--    const r = await db.rpc('update_broadcast_title',
--                { p_broadcast_id: '<발송id>', p_title: '  새 이름  ' });
--    기대: r.data === '새 이름'  (앞뒤 공백이 다듬어진다)
--
--    const r2 = await db.rpc('update_broadcast_title',
--                { p_broadcast_id: '<발송id>', p_title: '   ' });
--    기대: r2.data === null  (제목 없음으로 되돌아감)
--
--    const r3 = await db.rpc('update_broadcast_title',
--                { p_broadcast_id: '<발송id>', p_title: 'x'.repeat(101) });
--    기대: 오류 「제목은 100자까지입니다」
--
--    const r4 = await db.rpc('update_broadcast_title',
--                { p_broadcast_id: '00000000-0000-0000-0000-000000000000', p_title: 'a' });
--    기대: 오류 「그 발송을 찾지 못했습니다」 — 조용히 0건 고치고 지나가면 안 된다.
--
-- ── [4] 회수된 발송도 고쳐지는가 ──
--    회수 배지가 붙은 발송으로 [3] 을 한 번 더. 기대: 똑같이 저장된다.
-- ============================================================
