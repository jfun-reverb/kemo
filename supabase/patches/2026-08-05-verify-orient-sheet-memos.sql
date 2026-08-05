-- ============================================================
-- 2026-08-05-verify-orient-sheet-memos.sql
--
-- 마이그레이션 297(메모 표 2개)·298(서버 함수 2종) 검증 — 개발 데이터베이스에서 1회 실행.
--
-- ⚠️ 이 파일은 마이그레이션이 아니다. 아무것도 남기지 않는다.
--    전체를 트랜잭션 안에서 돌린 뒤 **일부러 오류를 내 되돌린다.**
--    되돌리는 주체는 마지막 ROLLBACK 이 아니라 그 오류다 — 검사가 불합격이든
--    중간에 다른 오류가 나든 같은 방식으로 되돌려져 시험 데이터가 안 남는다.
--
-- ✅ 정상 결과는 **빨간 오류 상자**로 나온다. 그 안에 검사 7줄이 들어 있고,
--    모두 「합격」이면 통과다. (298 파일 안 주석 블록과 같은 내용)
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_admin_id uuid;
  v_brand_id uuid;
  v_sheet_id uuid;
  v_memo1_id uuid;
  v_memo2_id uuid;
  v_marked   integer;
  v_row      record;
  ok         boolean;
  rpt        text := '';
  fails      int := 0;
BEGIN
  SELECT auth_id INTO v_admin_id FROM public.admins ORDER BY created_at LIMIT 1;
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION '검증 불가: 관리자 계정이 한 곳도 없습니다.';
  END IF;

  SELECT id INTO v_brand_id FROM public.brands ORDER BY created_at LIMIT 1;
  IF v_brand_id IS NULL THEN
    RAISE EXCEPTION '검증 불가: 브랜드가 한 곳도 없어 시험용 시트를 만들 수 없습니다.';
  END IF;

  -- 관리자로 로그인한 것처럼 흉내(이 트랜잭션 안에서만 유효 — 마이그레이션 272 §검증과 동일 기법)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_id::text)::text, true);

  -- 시험용 시트 1개(카드 1개만 등록 — 아래 메모 2 는 "카드 목록에 없는" 고아 메모로 취급)
  INSERT INTO public.orient_sheets (brand_id, token, status, data, version, token_expires_at, orient_no)
  VALUES (
    v_brand_id, gen_random_uuid(), 'draft',
    '{"cards":[{"uid":"aaaa-1111","product_name":"검증용A"}]}'::jsonb,
    1, now() + interval '1 day',
    'BTEST-M' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6)
  )
  RETURNING id INTO v_sheet_id;

  -- ⚠️ 아래 두 메모는 작성자를 **비워 둔다**(author_id = NULL).
  --    집계 함수는 「본인이 쓴 메모는 읽은 것으로」 보므로, 이 검증을 도는 관리자를
  --    작성자로 넣으면 안 읽은 수가 처음부터 0이 되어 1·2번 검사가 아무것도 확인하지
  --    못한다. 작성자를 비워 「남이 쓴 메모」를 흉내 낸다.
  --    (본인이 쓴 메모가 읽은 것으로 잡히는지는 아래 6번에서 따로 확인한다.)

  -- 메모 1: 현재 카드(aaaa-1111)에 붙는 메모
  INSERT INTO public.orient_sheet_memos (orient_sheet_id, card_uid, card_name_snapshot, body_html, author_id, author_name)
  VALUES (v_sheet_id, 'aaaa-1111', '검증용A', '<b>검증 메모 1</b>', NULL, '검증관리자(남이 쓴 것 흉내)')
  RETURNING id INTO v_memo1_id;

  -- 메모 2: 카드 목록에 없는 uid(= 브랜드가 그 카드를 지운 상황을 흉내) — 고아 메모
  INSERT INTO public.orient_sheet_memos (orient_sheet_id, card_uid, card_name_snapshot, body_html, author_id, author_name)
  VALUES (v_sheet_id, 'bbbb-2222', '검증용B(삭제됨)', '<i>검증 메모 2 — 고아</i>', NULL, '검증관리자(남이 쓴 것 흉내)')
  RETURNING id INTO v_memo2_id;

  -- ── 1·2. 집계 조회 — 카드 메모·고아 메모 둘 다 잡히는지 ──────────
  SELECT * INTO v_row FROM public.get_orient_sheet_memo_summaries()
   WHERE orient_sheet_id = v_sheet_id AND card_uid = 'aaaa-1111';
  ok := FOUND AND v_row.total_count = 1 AND v_row.unread_count = 1;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('1. 카드 메모 집계(전체1/안읽음1) ............. %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  SELECT * INTO v_row FROM public.get_orient_sheet_memo_summaries()
   WHERE orient_sheet_id = v_sheet_id AND card_uid = 'bbbb-2222';
  ok := FOUND AND v_row.total_count = 1 AND v_row.unread_count = 1;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('2. ★고아 메모도 집계에 잡힘(카드 목록과 무관) . %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 3. 읽음 처리 — 시트 단위로 카드 메모 + 고아 메모가 함께 처리되는지 ──
  SELECT public.mark_orient_sheet_memos_read(v_sheet_id) INTO v_marked;
  ok := (v_marked = 2);
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('3. 읽음 처리(시트 단위, 카드번호 인자 없음) %s건 처리(기대 2) %s',
                        v_marked, CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 4·5. 읽음 처리 후 안 읽은 수가 0이 됐는지(카드 메모·고아 메모 둘 다) ──
  SELECT * INTO v_row FROM public.get_orient_sheet_memo_summaries()
   WHERE orient_sheet_id = v_sheet_id AND card_uid = 'aaaa-1111';
  ok := FOUND AND v_row.unread_count = 0;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('4. 읽음 처리 뒤 안 읽은 수 0 (카드 메모) ...... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  SELECT * INTO v_row FROM public.get_orient_sheet_memo_summaries()
   WHERE orient_sheet_id = v_sheet_id AND card_uid = 'bbbb-2222';
  ok := FOUND AND v_row.unread_count = 0;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('5. 읽음 처리 뒤 안 읽은 수 0 (고아 메모) ...... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 6. ★본인이 쓴 메모는 「안 읽음」에 안 잡히는지 ────────────────
  --   읽음 처리는 상세를 열 때 1회 도는데 메모는 그보다 뒤에 생긴다.
  --   본인 글을 빼지 않으면, 메모를 남기고 창을 닫는 순간 목록 배지에
  --   자기가 방금 쓴 글이 「안 읽음 1」로 떠 버린다.
  INSERT INTO public.orient_sheet_memos (orient_sheet_id, card_uid, card_name_snapshot, body_html, author_id, author_name)
  VALUES (v_sheet_id, 'aaaa-1111', '검증용A', '<u>검증 메모 3 — 본인 작성</u>', v_admin_id, '검증관리자');

  SELECT * INTO v_row FROM public.get_orient_sheet_memo_summaries()
   WHERE orient_sheet_id = v_sheet_id AND card_uid = 'aaaa-1111';
  ok := FOUND AND v_row.total_count = 2 AND v_row.unread_count = 0;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('6. ★본인 글은 안 읽음에 안 잡힘(전체2/안읽음0) %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 7. 시트 삭제 시 메모·읽음기록 연쇄 삭제 확인 ──
  DELETE FROM public.orient_sheets WHERE id = v_sheet_id;
  ok := NOT EXISTS (SELECT 1 FROM public.orient_sheet_memos WHERE id IN (v_memo1_id, v_memo2_id))
        AND NOT EXISTS (SELECT 1 FROM public.orient_sheet_memo_reads WHERE memo_id IN (v_memo1_id, v_memo2_id));
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('7. 시트 삭제 시 메모·읽음기록 연쇄 삭제 ....... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  RAISE EXCEPTION E'\n\n===== 마이그레이션 297·298 검증 결과 =====\n%\n판정: %\n\n(이 오류는 시험 데이터를 되돌리기 위해 일부러 낸 것입니다.\n 위 7줄이 모두 「합격」이면 통과입니다.)\n',
    rpt,
    CASE WHEN fails = 0 THEN '전체 통과 ✅' ELSE fails::text || '건 불합격 ❌' END;
END;
$$;

ROLLBACK;

