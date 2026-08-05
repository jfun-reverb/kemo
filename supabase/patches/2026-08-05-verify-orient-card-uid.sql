-- ============================================================
-- 2026-08-05-verify-orient-card-uid.sql
--
-- 마이그레이션 293(카드 고유 번호 안전망) 검증 — 개발 데이터베이스에서 1회 실행.
--
-- ⚠️ 이 파일은 마이그레이션이 아니다. 아무것도 바꾸지 않는다.
--    전체를 트랜잭션 안에서 돌린 뒤 **반드시 되돌린다.**
--
--    되돌리는 주체는 마지막 `ROLLBACK` 문이 아니라 **일부러 내는 오류**(RAISE
--    EXCEPTION)다. 오류가 나면 트랜잭션이 실패 상태로 바뀌어 어떤 경로로 끝나든
--    되돌려진다 — 검사가 불합격이든 중간에 다른 오류가 나든 마찬가지다.
--    (여러 문장을 한 번에 보내면 오류 지점 뒤는 처리되지 않으므로, 맨 아래
--     `ROLLBACK` 은 실행되지 않을 수 있다. 남겨 둔 것은 한 문장씩 실행하는
--     경우를 위한 보조 장치다.)
--
--    그래서:
--      · 시험용 시트가 데이터베이스에 남지 않는다
--      · 6번 검사가 제출 함수를 부르지만 **제출 알림 메일이 나가지 않는다**
--        (웹훅 발송 예약도 되돌려지므로. 개발서버 메일 발송 테스트 금지 규칙 정합)
--
-- 실행 방법: 이 파일 전체를 복사해 개발 SQL Editor 에 붙여넣고 한 번 실행.
--
-- ✅ 정상 결과는 **빨간 오류 상자**로 나온다. 그 안에 검사 6줄이 들어 있다.
--    되돌리기를 강제하려고 일부러 오류를 내는 것이라, 오류로 나오는 것이 정상이다.
--    모든 줄이 「합격」이면 통과.
-- ============================================================

BEGIN;

DO $$
DECLARE
  v_token  uuid := gen_random_uuid();
  v_brand  uuid;
  v_ver    int;
  v_res    jsonb;
  v_status text;
  u1 text; u2 text;          -- 1번 검사에서 새로 붙은 번호
  a1 text; a2 text;          -- 2번 검사(물려받기) 결과
  b1 text;                   -- 3번 검사(개수 불일치) 결과
  c1 text; c2 text;          -- 4번 검사(중복) 결과
  d1 text; d2 text; d3 text; -- 5번 검사(문자열 아님) 결과
  e1 text; e2 text; e3 text; -- 6번 검사(제출) 결과
  ok       boolean;
  rpt      text := '';
  fails    int := 0;
BEGIN
  SELECT id INTO v_brand FROM public.brands ORDER BY created_at LIMIT 1;
  IF v_brand IS NULL THEN
    RAISE EXCEPTION '검증 불가: 브랜드가 한 곳도 없어 시험용 시트를 만들 수 없습니다.';
  END IF;

  INSERT INTO public.orient_sheets
    (brand_id, token, status, data, version, token_expires_at, orient_no)
  VALUES
    (v_brand, v_token, 'draft',
     '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb,
     1, now() + interval '30 days',
     'BTEST-O' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));

  -- ── 1. 번호 없던 카드 2개 → 둘 다 새 번호가 붙는가 ────────────────
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.save_orient_draft(v_token,
             '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb, v_ver);
  SELECT data->'cards'->0->>'uid', data->'cards'->1->>'uid'
    INTO u1, u2 FROM public.orient_sheets WHERE token = v_token;

  ok := (v_res->>'success') = 'true'
        AND u1 ~ '^[0-9a-f]{32}$' AND u2 ~ '^[0-9a-f]{32}$' AND u1 <> u2;
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('1. 번호 없던 카드에 새 번호 부여 ....... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 2. ★핵심: 개수가 같으면 기존 번호를 물려받는가 ────────────────
  --    (옛 화면이 번호 없이 저장해도 번호가 안 날아간다는 증거)
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.save_orient_draft(v_token,
             '{"cards":[{"product_name":"검증용A"},{"product_name":"검증용B"}]}'::jsonb, v_ver);
  SELECT data->'cards'->0->>'uid', data->'cards'->1->>'uid'
    INTO a1, a2 FROM public.orient_sheets WHERE token = v_token;

  ok := (a1 = u1 AND a2 = u2);
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('2. ★개수 같으면 번호 물려받기 ......... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 3. ★핵심: 개수가 다르면 물려주지 않는가 ───────────────────────
  --    (물려주면 번호가 한 칸씩 밀려 메모가 엉뚱한 카드에 붙는다)
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.save_orient_draft(v_token,
             '{"cards":[{"product_name":"검증용A"}]}'::jsonb, v_ver);
  SELECT data->'cards'->0->>'uid' INTO b1 FROM public.orient_sheets WHERE token = v_token;

  ok := (b1 ~ '^[0-9a-f]{32}$' AND b1 <> u1 AND b1 <> u2);
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('3. ★개수 다르면 새 번호(밀림 차단) .... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 4. 같은 번호가 두 번 들어오면 뒤엣것만 새 번호가 되는가 ────────
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.save_orient_draft(v_token,
             '{"cards":[{"product_name":"C1","uid":"dupe-test"},{"product_name":"C2","uid":"dupe-test"}]}'::jsonb, v_ver);
  SELECT data->'cards'->0->>'uid', data->'cards'->1->>'uid'
    INTO c1, c2 FROM public.orient_sheets WHERE token = v_token;

  ok := (c1 = 'dupe-test' AND c2 IS DISTINCT FROM 'dupe-test' AND c2 ~ '^[0-9a-f]{32}$');
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('4. 중복 번호는 처음 것만 인정 ......... %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 5. 번호가 문자열이 아니면 걸러내는가 ──────────────────────────
  --    카드를 3개 보내 개수를 어긋나게 한다 — 2개면 물려받기가 돌아 검사가 가려진다
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.save_orient_draft(v_token,
             '{"cards":[{"product_name":"C1","uid":123},{"product_name":"C2","uid":true},{"product_name":"C3"}]}'::jsonb, v_ver);
  SELECT data->'cards'->0->>'uid', data->'cards'->1->>'uid', data->'cards'->2->>'uid'
    INTO d1, d2, d3 FROM public.orient_sheets WHERE token = v_token;

  ok := (d1 ~ '^[0-9a-f]{32}$' AND d2 ~ '^[0-9a-f]{32}$' AND d3 ~ '^[0-9a-f]{32}$'
         AND d1 <> d2 AND d2 <> d3 AND d1 <> d3);
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('5. 문자열 아닌 번호(숫자·참거짓) 차단 . %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 6. 제출 함수도 같은 보정을 타는가 + 202 반환 키가 남아 있는가 ──
  --    ⚠️ 제출 알림 웹훅 조건을 통과하지만, 이 트랜잭션을 되돌리므로 메일은 안 나간다
  SELECT version INTO v_ver FROM public.orient_sheets WHERE token = v_token;
  v_res := public.submit_orient_sheet(v_token,
             '{"cards":[{"product_name":"C1"},{"product_name":"C2"},{"product_name":"C3"}]}'::jsonb, v_ver);
  SELECT status, data->'cards'->0->>'uid', data->'cards'->1->>'uid', data->'cards'->2->>'uid'
    INTO v_status, e1, e2, e3 FROM public.orient_sheets WHERE token = v_token;

  ok := (v_res->>'success') = 'true'
        AND v_status = 'submitted'
        AND e1 = d1 AND e2 = d2 AND e3 = d3
        AND jsonb_exists(v_res, 'last_submitted_at')
        AND jsonb_exists(v_res, 'is_first_submission')
        AND jsonb_exists(v_res, 'orient_sheet_id')
        AND jsonb_exists(v_res, 'brand_id')
        AND jsonb_exists(v_res, 'form_type')
        AND jsonb_exists(v_res, 'application_id');
  IF NOT ok THEN fails := fails + 1; END IF;
  rpt := rpt || format('6. 제출 함수도 보정 + 반환 키 6종 보존 . %s', CASE WHEN ok THEN '합격' ELSE '불합격' END) || chr(10);

  -- ── 결과 출력 + 강제 되돌리기 ─────────────────────────────────────
  RAISE EXCEPTION E'\n\n===== 마이그레이션 293 검증 결과 =====\n%\n판정: %\n\n(이 오류는 시험 데이터를 되돌리고 제출 알림 메일을 막기 위해\n 일부러 낸 것입니다. 위 6줄이 모두 「합격」이면 통과입니다.)\n',
    rpt,
    CASE WHEN fails = 0 THEN '전체 통과 ✅' ELSE fails::text || '건 불합격 ❌' END;
END;
$$;

ROLLBACK;
