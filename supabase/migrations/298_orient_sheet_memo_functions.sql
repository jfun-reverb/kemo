-- ============================================================
-- 298_orient_sheet_memo_functions.sql
-- 2026-08-05
--
-- 목적:
--   오리엔시트 내부 메모(마이그레이션 297)를 위한 원격 호출 함수 2개.
--   brand_application_memo_reads 의 mark_brand_app_memos_read /
--   get_brand_app_memo_summaries(마이그레이션 125)와 같은 형태.
--
-- 사양서:
--   docs/specs/2026-08-05-orient-sheet-internal-memo.md §설계 3, §의심 11
--   작업표  docs/specs/2026-08-05-orient-sheet-internal-memo-breakdown.md 작업 5
--
-- 신규 함수 2개:
--   [A] mark_orient_sheet_memos_read(p_orient_sheet_id uuid) → integer
--       읽음 처리 — **시트 단위**. 카드 고유 번호를 인자로 받지 않는다.
--       그 시트에 붙은 메모 전부(카드에 붙은 것 + 카드가 사라진 고아 메모)를
--       본인(auth.uid()) 기준으로 한 번에 읽음 처리한다.
--       (125의 mark_brand_app_memos_read 는 (신청, 제품) 페어 단위였지만,
--        이번은 "카드 하나하나"가 아니라 "시트 전체"가 단위 — 사양서 §의심 11:
--        상세 모달을 열면 그 시트의 안 읽은 수가 통째로 0이 되는 단순한 규칙)
--
--   [B] get_orient_sheet_memo_summaries() → TABLE(...)
--       집계 조회 — (시트, 카드 고유 번호) 짝마다 전체 개수·안 읽은 개수(본인 기준)·
--       최근 메모 본문·최근 메모 시각을 한 번에 반환한다.
--       ⚠️ 집계는 orient_sheet_memos 표 기준으로만 낸다. orient_sheets 의 현재
--       data.cards 목록과 대조해서 거르지 않는다 — 걸러 버리면 카드가 지워져
--       고아가 된 메모가 개수에서 빠져, 상세 화면이 "삭제된 모집 건의 메모"로
--       끌어와 그릴 재료가 사라진다(사양서 §설계 3 경고, 의도된 설계).
--
-- 이 파일이 하지 않는 것:
--   메모 자체의 작성·수정·삭제는 이 함수들에 없다 — 297의 행 단위 보안 정책으로
--   일반 조회/쓰기 경로를 그대로 쓴다(brand_application_memos 와 동일).
--
-- 보안:
--   두 함수 모두 SECURITY DEFINER + SET search_path = '' + public.is_admin() 가드.
--   등급 분기 없음(관리자 전원) — 표(297)의 행 단위 보안 정책과 동일한 결.
--   REVOKE FROM anon(비로그인 차단) → GRANT TO authenticated(관리자 아닌
--   authenticated 는 함수 안 is_admin() 가드에서 걸러진다 — 125와 동일 패턴).
--
-- 선행 조건: 마이그레이션 297(표 2개) 적용 완료.
--
-- 롤백: 함수 2개 DROP. 파일 하단 [롤백 SQL] 참조.
-- ============================================================

BEGIN;


-- ============================================================
-- A. mark_orient_sheet_memos_read — 읽음 처리 (시트 단위)
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_orient_sheet_memos_read(
  p_orient_sheet_id uuid
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_marked  integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[mark_orient_sheet_memos_read] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION '[mark_orient_sheet_memos_read] auth.uid() is null'
      USING ERRCODE = '28000';
  END IF;

  -- 그 시트의 모든 메모(카드에 붙은 것 + 카드가 사라진 고아 메모 포함)를
  -- 본인 read 로 UPSERT (이미 읽었으면 read_at 갱신). 카드 번호로 거르지 않는다.
  WITH ins AS (
    INSERT INTO public.orient_sheet_memo_reads (memo_id, auth_id, read_at)
    SELECT m.id, v_uid, now()
    FROM public.orient_sheet_memos m
    WHERE m.orient_sheet_id = p_orient_sheet_id
    ON CONFLICT (memo_id, auth_id) DO UPDATE
      SET read_at = now()
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_marked FROM ins;

  RETURN COALESCE(v_marked, 0);
END;
$$;

COMMENT ON FUNCTION public.mark_orient_sheet_memos_read IS
  '[298] 오리엔시트 하나(p_orient_sheet_id)의 모든 내부 메모를 본인(auth.uid()) 기준 '
  '일괄 읽음 처리. 카드 고유 번호를 받지 않음 — 읽음 처리 단위는 카드가 아니라 시트. '
  '카드가 사라진 고아 메모도 함께 처리된다. 반환: 처리된 행 수.';

REVOKE EXECUTE ON FUNCTION public.mark_orient_sheet_memos_read(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.mark_orient_sheet_memos_read(uuid) TO authenticated;


-- ============================================================
-- B. get_orient_sheet_memo_summaries — 집계 조회
--   (orient_sheet_id, card_uid) 짝 단위 total_count/unread_count(본인 기준)/
--   latest_body_html/latest_created_at. get_brand_app_memo_summaries(125)와
--   같은 ranked-CTE 형태.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_orient_sheet_memo_summaries()
RETURNS TABLE (
  orient_sheet_id    uuid,
  card_uid           text,
  total_count        integer,
  unread_count       integer,
  latest_body_html   text,
  latest_created_at  timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '[get_orient_sheet_memo_summaries] permission denied: admin only'
      USING ERRCODE = '42501';
  END IF;

  -- ⚠️ orient_sheet_memos 표 기준으로만 집계한다. orient_sheets.data.cards 의
  --    현재 카드 목록과 대조해서 거르지 않는다(의도된 설계) — 걸러 버리면 카드가
  --    지워져 고아가 된 메모가 여기서 빠지고, 상세 화면의 "삭제된 모집 건의 메모"
  --    묶음이 그릴 재료를 잃는다.
  RETURN QUERY
  WITH ranked AS (
    SELECT
      m.orient_sheet_id,
      m.card_uid,
      m.body_html,
      m.created_at,
      ROW_NUMBER() OVER (
        PARTITION BY m.orient_sheet_id, m.card_uid
        ORDER BY m.created_at DESC
      ) AS rn,
      -- 읽음 판정 = 읽음 기록이 있거나 **본인이 쓴 메모**.
      --   본인 메모를 빼지 않으면, 메모를 남기고 창을 닫는 순간 목록 배지에
      --   자기가 방금 쓴 메모가 「안 읽음 1」로 뜬다. 읽음 처리는 상세를 열 때
      --   1회 도는데 메모는 그보다 뒤에 생기기 때문이다. 배지의 뜻이
      --   「내가 아직 열어보지 않은 새 메모」이므로 자기 글은 애초에 대상이 아니다.
      --   ⚠️ COALESCE 필수 — 작성자 계정이 지워지면 author_id 가 비고,
      --   그 비교는 참도 거짓도 아닌 값이 되어 「안 읽음」 집계에서 조용히 빠진다.
      (r.read_at IS NOT NULL OR COALESCE(m.author_id = v_uid, false)) AS is_read
    FROM public.orient_sheet_memos m
    LEFT JOIN public.orient_sheet_memo_reads r
      ON r.memo_id = m.id AND r.auth_id = v_uid
  )
  SELECT
    ranked.orient_sheet_id,
    ranked.card_uid,
    count(*)::integer                                            AS total_count,
    sum(CASE WHEN NOT ranked.is_read THEN 1 ELSE 0 END)::integer  AS unread_count,
    max(CASE WHEN ranked.rn = 1 THEN ranked.body_html END)        AS latest_body_html,
    max(CASE WHEN ranked.rn = 1 THEN ranked.created_at END)       AS latest_created_at
  FROM ranked
  GROUP BY ranked.orient_sheet_id, ranked.card_uid;
END;
$$;

COMMENT ON FUNCTION public.get_orient_sheet_memo_summaries IS
  '[298] (orient_sheet_id, card_uid) 짝 단위 내부 메모 집계. 반환: total_count/'
  'unread_count(본인 기준 — 읽음 기록이 있거나 **본인이 쓴 메모**는 읽은 것으로 본다)/'
  'latest_body_html/latest_created_at. '
  '⚠️ orient_sheet_memos 표 기준으로만 낸다 — orient_sheets.data.cards 의 현재 '
  '카드 목록으로 거르지 않는다(카드가 지워진 고아 메모도 집계에 포함, 의도된 설계).';

REVOKE EXECUTE ON FUNCTION public.get_orient_sheet_memo_summaries() FROM anon;
GRANT  EXECUTE ON FUNCTION public.get_orient_sheet_memo_summaries() TO authenticated;


-- ============================================================
-- PostgREST 스키마 캐시 재로드
-- ============================================================
NOTIFY pgrst, 'reload schema';


COMMIT;


-- ════════════════════════════════════════════════════════════
-- [검증 SQL] — 개발 서버에서 마이그레이션 적용 후 SQL Editor 에서 전체 실행
--
-- ⚠️ 이 파일은 아무것도 남기지 않는다. BEGIN ~ 강제 오류로 끝나 트랜잭션이
--    통째로 되돌려진다(293의 검증 패치 supabase/patches/2026-08-05-verify-
--    orient-card-uid.sql 과 같은 방식). 메일 발송 위험은 이 검증에 없다
--    (submit_orient_sheet 를 호출하지 않으므로 제출 알림 웹훅이 돌지 않는다) —
--    그럼에도 시험 데이터를 남기지 않는 같은 방식을 따른다.
--
-- ⚠️ mark_orient_sheet_memos_read·get_orient_sheet_memo_summaries 는 둘 다
--    is_admin() 가드가 있어, 로그인 세션이 없는 SQL Editor 에서는 auth.uid() 가
--    NULL 이라 그대로 부르면 "permission denied" 로 막힌다. 기존 관리자 계정 1명을
--    빌려 그 사람으로 로그인한 것처럼 request.jwt.claims 를 흉내낸다 — 마이그레이션
--    272 §검증에서 쓰인 것과 같은 표준 기법이며, 트랜잭션 안에서만 유효하고 그
--    관리자의 실제 세션에는 아무 영향이 없다.
--
-- ✅ 정상 결과는 "빨간 오류 상자"로 나온다. 그 안에 검사 6줄이 들어 있다.
--    모든 줄이 「합격」이면 통과.
-- ════════════════════════════════════════════════════════════
/*

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

*/


-- ════════════════════════════════════════════════════════════
-- [롤백 SQL] — 운영 적용 후 문제 발생 시 실행
-- ════════════════════════════════════════════════════════════
/*

DROP FUNCTION IF EXISTS public.get_orient_sheet_memo_summaries();
DROP FUNCTION IF EXISTS public.mark_orient_sheet_memos_read(uuid);

NOTIFY pgrst, 'reload schema';

*/
