-- ============================================================
-- 340_mark_settlements_paid_bulk.sql
-- 정산대기 여러 건을 **한 번에** 송금완료로 (정산 3단계 · 작업표 「작업 3 — D」)
--
-- ▶ 왜
--   지금은 송금완료가 **한 건씩**만 된다. 실무는 회차마다 수십~수백 건을 한꺼번에
--   보내고 오는데, 한 건씩 누르면 중간에 브라우저가 끊기거나 사람이 지쳐 **일부만 기록된
--   상태**로 끝난다. 그 상태가 가장 나쁘다 — 무엇이 기록됐고 무엇이 안 됐는지 모른다.
--
-- ▶ 🔴 알림 잠금 게이트를 **명시적으로** 넣었다
--   이 함수는 **신설**이라 241 이 `mark_settlement_paid` 에 넣은 잠금이 **저절로 따라오지
--   않는다.** 빠뜨리면 인플루언서에게 정산을 아직 안 열었는데(`influencer_visible=false`)
--   **이 함수 하나로 그 결정이 통째로 우회**된다. 아래 `v_public` 이 그 게이트다.
--   ⚠️ `settlement_events` 감사 이력은 **잠금과 무관하게 항상** 남긴다(241 과 같은 원칙 —
--      돈이 오간 기록은 잠금 상태에서도 남아야 한다).
--
-- ▶ 실패 처리 — **통째로 되돌리지 않고 건너뛰고 알린다**(324 원칙)
--   건너뛰는 사유 3가지를 **각각 세어서 돌려준다.** 「몇 건 처리했습니다」만 돌려주면
--   나머지가 왜 빠졌는지 아무도 모르고, 그게 이 저장소가 반복해 겪은 「조용히 사라짐」이다.
--     · `skipped_no_paypal_count`   — 페이팔 미등록 (돈 보낼 곳이 없다)
--     · `skipped_not_pending_count` — 이미 처리됨·보류·취소 (다른 관리자가 먼저 눌렀다)
--     · `not_found_count`           — 그 사이 사라진 행
--   ⚠️ 오류를 던지지 않는 이유: 500건 중 1건이 페이팔 미등록이라고 **499건을 되돌리면**
--      실무가 멈춘다. 대신 화면이 건너뛴 건수를 반드시 보여줘야 한다(작업 6).
--
-- ▶ 왜 반복문인가 (집합 처리가 아니라)
--   한 문장 안에서 잠그고·판정하고·고치면 스냅샷 시점 문제를 따져야 하고, 이 저장소는
--   그런 종류의 미묘한 결함을 실제로 겪었다(2026-08-18 마이그레이션 335). 건수가 많아야
--   수백이라 반복문으로 **읽어서 검증 가능한 쪽**을 골랐다.
--   ⚠️ `ORDER BY` 로 **항상 같은 순서로 잠근다** — 두 관리자가 겹치는 목록을 동시에 누를 때
--      서로를 기다리며 멈추는 것(교착)을 막는다.
--
-- ▶ 실제 송금액(`paid_amount_jpy`)은 **여기서 안 건드린다**
--   일괄이라 건마다 다른 금액을 하나의 값으로 넣을 수 없다. 계산값 그대로 보낸 건이
--   대부분이고(`NULL` = 계산값과 같음), 다른 건은 등록 뒤
--   `correct_settlement_payment`(마이그레이션 E)로 개별 정정한다.
--
-- ⚠️ 낙관적 잠금(version)을 인자로 받지 않는 이유
--   목록에서 수백 건을 고르는 화면이라 건마다 version 을 실어 보내면 화면이 무거워지고,
--   한 건만 어긋나도 전체가 막힌다. 대신 **행을 잠근 뒤 상태를 다시 읽어**
--   `pending` 이 아니면 건너뛴다 — 「다른 사람이 먼저 처리한 건은 안 건드린다」는
--   같은 보호를 얻으면서 나머지는 처리된다. version 은 처리한 건만 +1 한다.
--
-- ⚠️ 이 마이그레이션은 **화면 잠금을 풀지 않는다.** 세 문은 작업 7에서 함께 연다.
--
-- ⚠️ 번호 안내 — 334~340 사용. 다음은 341.
--    332 는 **이 저장소 dev 에 이미 `site_daily_visits` 로 확정**돼 있다(iOS 와 무관).
--    333 만 `feature/ios-app` 브랜치와 겹쳐 비워 둔 것이다 — 그 브랜치를 dev 로 합치는
--    날 재번호가 필요하다(337 파일이 같은 내용을 정확히 적어 두었다).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.mark_settlements_paid_bulk(
  p_settlement_ids uuid[],
  p_paid_at        timestamptz DEFAULT NULL,
  p_memo           text        DEFAULT NULL
)
RETURNS TABLE (
  paid_count                integer,
  skipped_no_paypal_count   integer,
  skipped_not_pending_count integer,
  not_found_count           integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id            uuid;
  v_row           record;
  v_paypal_fresh  text;
  v_paid_at       timestamptz;
  v_memo          text;
  v_public        boolean;
  v_paid          integer := 0;
  v_skip_paypal   integer := 0;
  v_skip_status   integer := 0;
  v_missing       integer := 0;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write (241·324 와 동일) ──────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ⚠️ 「비었나」를 길이만으로 보면 안 된다. `[null]` 은 길이가 1이라 이 검사를 통과한 뒤
  --   반복문에서 걸러져 **네 건수가 전부 0인 채 조용히 성공**으로 끝난다 — 이 함수가
  --   머리말에서 없애겠다고 한 바로 그 「조용히 사라짐」이다. 실제 값이 하나라도 있는지 본다.
  IF p_settlement_ids IS NULL
     OR array_length(p_settlement_ids, 1) IS NULL
     OR NOT EXISTS (SELECT 1 FROM unnest(p_settlement_ids) AS x WHERE x IS NOT NULL) THEN
    RAISE EXCEPTION 'empty_settlement_ids: 처리할 정산을 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── 앞날 날짜 방어 (339 와 같은 기준·같은 이유) ────────────────
  --   연도 하나 잘못 친 오타가 그대로 들어가면 「지급일별 실적」에 없는 회차가 생기고,
  --   금전 기록이라 나중에 어느 것이 오타였는지 가려내기 어렵다. 시계 어긋남에 하루 여유.
  --   ⚠️ 과거 쪽은 안 막는다 — 이미 보낸 건을 실제 날짜로 적는 것이 이 인자의 목적이다.
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  v_paid_at := COALESCE(p_paid_at, now());
  v_memo    := COALESCE(NULLIF(btrim(p_memo), ''), '일괄 송금완료');

  -- ★ 잠금 판정을 **반복문 밖에서 한 번만** 읽는다. 안에서 매번 읽으면 처리 도중 누가
  --   스위치를 바꿨을 때 **같은 배치의 앞부분만 알림이 나가는** 반쪽 상태가 된다.
  v_public := public.is_settlement_public();

  -- ⚠️ DISTINCT + ORDER BY — 같은 id 가 두 번 와도 한 번만 처리하고,
  --    항상 같은 순서로 잠가 동시 실행 시 교착을 막는다.
  FOR v_id IN
    SELECT DISTINCT x FROM unnest(p_settlement_ids) AS x WHERE x IS NOT NULL ORDER BY 1
  LOOP
    SELECT s.id, s.status, s.influencer_id, s.memo
      INTO v_row
      FROM public.settlements s
     WHERE s.id = v_id
     FOR UPDATE;

    IF NOT FOUND THEN
      v_missing := v_missing + 1;
      CONTINUE;
    END IF;

    -- 다른 관리자가 먼저 처리했거나 보류·취소된 건 — 건드리지 않는다.
    IF v_row.status <> 'pending' THEN
      v_skip_status := v_skip_status + 1;
      CONTINUE;
    END IF;

    -- 페이팔 최신값 재조회 (마스킹 뷰 우회 — DEFINER 로 원본 표 직접 조회, 241 과 동일)
    SELECT NULLIF(btrim(i.paypal_email), '')
      INTO v_paypal_fresh
      FROM public.influencers i
     WHERE i.id = v_row.influencer_id;

    IF v_paypal_fresh IS NULL THEN
      v_skip_paypal := v_skip_paypal + 1;
      CONTINUE;
    END IF;

    UPDATE public.settlements s
       SET status       = 'paid',
           paid_at      = v_paid_at,
           paid_by      = auth.uid(),
           paypal_email = v_paypal_fresh,
           -- ★ 메모는 **덮어쓰지 않고 덧붙인다.** 단건(241)은 덮어쓰지만, 일괄은 한 문장을
           --   수백 행에 밀어 넣는 것이라 덮으면 행마다 갖고 있던 사연
           --   (예: 「과거 이관 (수동 처리)」)이 **한꺼번에** 사라진다.
           memo         = CASE
                            WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_memo
                            ELSE s.memo || E'\n' || v_memo
                          END,
           -- ⚠️ paid_amount_jpy 는 안 건드린다 — 위 머리말 참조(NULL = 계산값과 같음).
           version      = s.version + 1
     WHERE s.id = v_id;

    -- ── 금전 감사 이력: 잠금과 무관하게 **항상** 남는다 (241 원칙) ──
    INSERT INTO public.settlement_events
      (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_id, 'pay', 'pending', 'paid', auth.uid(), v_memo);

    -- ── 🔴 인플루언서 알림 — 잠금이 열렸을 때만 ────────────────────
    IF v_public THEN
      INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
      VALUES (
        v_row.influencer_id, 'settlement_paid', 'settlements', v_id,
        '報酬のお振込みが完了しました',
        -- ⚠️ 「報酬・精算」 은 마이페이지에 **실제로 있는** 메뉴 이름이다
        --    (dev/lib/i18n/ja.js `settlements`). 222·241 은 「報酬・お支払い」 라는
        --    **화면에 없는 이름**을 안내하고 있었다 — 마이그레이션 339 에서 함께 정정한다.
        'キャンペーンの報酬をPayPalにお振込みしました。マイページの「報酬・精算」からご確認ください。'
      );
    END IF;

    v_paid := v_paid + 1;
  END LOOP;

  RETURN QUERY SELECT v_paid, v_skip_paypal, v_skip_status, v_missing;
END;
$$;

COMMENT ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) IS
  '정산대기 여러 건을 한 번에 송금완료로. 실패는 통째로 되돌리지 않고 건너뛰며 사유별 건수를 돌려준다 '
  '(페이팔 미등록 / 이미 처리됨·보류·취소 / 사라진 행). 인플루언서 알림은 is_settlement_public() 이 '
  '열렸을 때만 — 신설 함수라 241 의 잠금이 저절로 안 따라와 명시적으로 넣었다. settlement_events 는 항상 기록. '
  'paid_amount_jpy 는 건드리지 않는다(건마다 달라 하나로 못 넣는다 — correct_settlement_payment 로 개별 정정). '
  '메모는 덮어쓰지 않고 덧붙인다.';

REVOKE ALL ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) TO authenticated;

-- ⚠️ 새 함수를 PostgREST 가 알아보도록 스키마를 다시 읽으라고 알린다(241·324 관례).
--    안 넣으면 첫 호출이 「함수를 찾을 수 없다」(PGRST202)로 실패할 수 있다.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다) ────────────────
-- [1] 함수가 생겼나 (기대: 1행)
--   SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public' AND p.proname='mark_settlements_paid_bulk';
--
-- [2] 🔴 알림 잠금 게이트가 들어 있나 (기대: 1 — 이게 이 조각의 핵심 검증이다)
--   SELECT count(*) FROM pg_proc
--    WHERE proname='mark_settlements_paid_bulk'
--      AND pg_get_functiondef(oid) LIKE '%is_settlement_public()%';
--
-- [3] ★ **실제로 한 번 부른다.** 함수를 만드는 구문은 본문 자료형을 검사하지 않아
--     적용은 성공하고 첫 호출에서 터진다(2026-08-18 마이그레이션 335, 42804).
--   ⚠️ SQL 편집기는 서비스 키라 has_permission 가드에 막힌다(42501) — **관리자 브라우저**에서:
--       // 없는 id 하나로 — 기대: paid 0 / not_found 1 (아무것도 안 바뀐다)
--       await db.rpc('mark_settlements_paid_bulk',
--         { p_settlement_ids:['00000000-0000-0000-0000-000000000000'], p_memo:'시험' })
--       // 앞날 날짜 방어 — 기대: paid_at_in_future 오류
--       await db.rpc('mark_settlements_paid_bulk',
--         { p_settlement_ids:['00000000-0000-0000-0000-000000000000'],
--           p_paid_at:'2030-01-01T00:00:00+09:00', p_memo:'시험' })
--   ⚠️ 화면의 일괄 버튼은 아직 잠겨 있다(작업 7). 위 호출은 그 잠금을 우회하므로
--      **없는 id 로만** 하고 운영의 실제 행에는 하지 말 것.
--
-- 롤백: DROP FUNCTION IF EXISTS public.mark_settlements_paid_bulk(uuid[], timestamptz, text);
--   ⚠️ 이미 이 함수로 처리한 행은 롤백되지 않는다(정상 — 돈이 오간 기록이다).
