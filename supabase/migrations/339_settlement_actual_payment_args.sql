-- ============================================================
-- 339_settlement_actual_payment_args.sql
-- 송금완료 두 함수에 **실제 보낸 날짜·금액** 인자 추가
-- (정산 3단계 · 작업표 「작업 2 — C」)
--
-- ▶ 왜
--   지금은 송금완료를 누르는 순간 **오늘 날짜·계산 금액으로 확정**되고 되돌릴 수 없다.
--   그래서 1·2단계가 기록 경로를 **세 곳 다 잠가** 두었다. 이 마이그레이션이 그 잠금을
--   풀 수 있게 만드는 것이다 — 이미 시스템 밖에서 지급이 끝난 건을 **실제 날짜**로
--   적으려면 이 인자가 있어야 한다.
--
-- ▶ 무엇을 바꾸나 — **인자 추가 + 저장 두 줄 + 방어 조항**. 그 밖은 베이스 그대로다.
--   ① `mark_settlement_paid`      (베이스 **241**) — `p_paid_at`·`p_paid_amount_jpy`
--   ② `register_past_settlements` (베이스 **324**) — `p_paid_at` **하나만**
--      (일괄이라 건마다 금액이 달라 하나의 값으로 못 넣는다 → 등록 후 E 로 개별 정정)
--   두 인자 모두 **생략 가능** — 생략하면 종전과 한 글자도 다르지 않게 동작한다.
--   ③ ②의 **도입일(컷오프) 조건 제거** — 337 이 목록 함수에서만 없애 「목록엔 뜨는데
--      등록하면 조용히 빠지는」 어긋남이 남았고, 337 파일이 **여기서 함께 다루라**고
--      적어 두었다. 안 다루면 작업 7에서 잠금을 푸는 순간 되살아난다.
--
-- ⚠️ **베이스 번호를 지킨 이유**
--   · 241 이 넣은 것은 **인플루언서 알림 잠금 게이트**(`IF public.is_settlement_public()`
--     안에서만 알림 INSERT). **222 를 베이스로 삼으면 그 게이트가 사라진다.**
--   · 324 가 넣은 것은 **일괄 처리의 페이팔 확인**(H-4)·**cert_at 저장**(H-5).
--     300 을 베이스로 삼으면 페이팔 없는 건에 송금완료가 찍힌다.
--   아래 본문은 각각 그 파일에서 **그대로 떼어 왔고** 게이트 구간은 안 건드렸다.
--
-- ⚠️ **인자가 늘면 서명이 달라져 `CREATE OR REPLACE` 로 안 된다 → `DROP` 후 재생성.**
--    기존 호출부(`storage.js` 의 `markSettlementPaid`·`registerPastSettlements`)는
--    기본값 덕에 그대로 동작한다. DROP 과 CREATE 사이 함수가 잠깐 없으므로 한 트랜잭션에 넣는다.
--
-- ⚠️ 이 마이그레이션은 **화면 잠금을 풀지 않는다.** 세 문(지급 준비 발송·과거 미등록
--    일괄·단건 송금완료)은 작업 7에서 함께 연다.
--
-- ⚠️ 번호 안내 — 334~339 사용. 다음은 340.
--    332 는 **이 저장소 dev 에 이미 `site_daily_visits` 로 확정**돼 있다(iOS 와 무관).
--    333 만 `feature/ios-app` 브랜치와 겹쳐 비워 둔 것이다 — 그 브랜치를 dev 로 합치는
--    날 재번호가 필요하다(337 파일이 같은 내용을 정확히 적어 두었다).
-- ============================================================

BEGIN;

-- ── ① 단건 송금완료 ──────────────────────────────────────────
-- ⚠️ 3인자 판을 명시적으로 지운다. 기본값이 붙은 새 판과 **함께 남으면 호출이 모호**해져
--    3인자로 부를 때 오히려 오류가 난다.
DROP FUNCTION IF EXISTS public.mark_settlement_paid(uuid, integer, text);

CREATE FUNCTION public.mark_settlement_paid(
  p_settlement_id   uuid,
  p_version         integer,
  p_memo            text,
  -- ★ [339] 실제로 보낸 날짜·금액. **둘 다 생략 가능** — 생략하면 종전과 똑같이
  --   `now()` · `NULL`(계산값과 같음) 로 동작한다. 기존 호출부가 안 깨지는 이유다.
  p_paid_at         timestamptz DEFAULT NULL,
  p_paid_amount_jpy bigint      DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row          record;
  v_paypal_fresh text;
  v_new_version  integer;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write ──────────────────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ★ [339] 앞날 날짜 방어. 송금은 앞날에 일어날 수 없다.
  --   화면 입력 오타(연도 하나)가 그대로 들어가면 「지급일별 실적」에 없는 회차가 생기고,
  --   금전 기록이라 나중에 어느 것이 오타였는지 가려내기 어렵다. 시계 어긋남을 감안해
  --   하루치 여유를 둔다. ⚠️ 과거 쪽은 막지 않는다 — 2026-05 에 보낸 건을 지금 적는 것이
  --   이 인자를 만든 이유다.
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- ★ [339] 금액 방어. 338 이 이 칸에 CHECK 를 안 건 것은 「계산값보다 많거나 적을 수
  --   있다」는 뜻이지 **음수·0 이어도 된다는 뜻이 아니다.** 막지 않으면 정산 화면에
  --   「-500円」 같은 값이 그대로 나온다. `amount_jpy` 의 `CHECK(>0)` 과 같은 기준.
  IF p_paid_amount_jpy IS NOT NULL AND p_paid_amount_jpy <= 0 THEN
    RAISE EXCEPTION 'invalid_paid_amount: 송금액은 0보다 커야 합니다 (입력값: %)', p_paid_amount_jpy
      USING ERRCODE = '22023';
  END IF;

  -- ── 대상 행 잠금 조회 ─────────────────────────────────────────
  SELECT id, status, version, influencer_id
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  -- ── 낙관적 락: 버전 불일치 시 충돌(-1) ─────────────────────────
  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  -- ── 상태 전이 검증: pending 만 송금 처리 가능 ───────────────────
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION '정산 대기(pending) 상태만 송금 처리할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- ── PayPal 최신값 재조회(마스킹 뷰 우회 — DEFINER 원본 테이블 직접 조회) ──────
  SELECT NULLIF(btrim(paypal_email), '') INTO v_paypal_fresh
    FROM public.influencers
   WHERE id = v_row.influencer_id;

  IF v_paypal_fresh IS NULL THEN
    RAISE EXCEPTION 'PayPal 이메일이 등록되지 않아 송금 처리할 수 없습니다 (인플루언서: %)', v_row.influencer_id
      USING ERRCODE = '22023';
  END IF;

  -- ── settlements UPDATE ──────────────────────────────────────
  UPDATE public.settlements
     SET status       = 'paid',
         -- ★ 실제 보낸 날짜를 받으면 그것을, 안 받으면 종전대로 지금 시각을 적는다.
         --   ⚠️ 이미 시스템 밖에서 지급이 끝난 건을 오늘 날짜로 찍으면 「언제 보냈나」가
         --      영영 사라진다 — 그게 이 인자를 만든 이유다.
         paid_at      = COALESCE(p_paid_at, now()),
         -- ★ 실제 보낸 금액. NULL 이면 「계산값(amount_jpy)과 같음」이다 — 0원이 아니다.
         --   ⚠️ amount_jpy 는 **덮지 않는다.** 그 값은 계산 근거(영수증 금액·상한·출처)와
         --      짝을 이루는 스냅샷이라, 덮으면 왜 그 금액인지 설명할 수 없게 된다.
         paid_amount_jpy = p_paid_amount_jpy,
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  -- ── settlement_events 감사 이력 ─────────────────────────────
  -- [240] 스위치와 무관하게 항상 남는다 — 금전 감사는 잠금 상태에서도 필수.
  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  -- ── 인플루언서 알림(일본어 — 초등학생 눈높이, ui.md 컨벤션) ─────────
  -- [241] settlement_settings.influencer_visible = true 일 때만 발송.
  --   잠금(false, 기본) 상태에서는 관리자가 송금 완료 처리를 해도
  --   인플루언서에게 어떤 알림도 나가지 않는다.
  -- ★ [339] 본문의 메뉴 이름을 「報酬・お支払い」 → **「報酬・精算」** 으로 고쳤다.
  --   222·241 이 안내하던 그 이름은 **마이페이지에 존재하지 않는다**(실제 이름은
  --   `dev/lib/i18n/ja.js` 의 `settlements: '報酬・精算'`). 아직 잠겨 있어 아무도 못 받았을
  --   뿐, 5단계에서 잠금을 여는 순간 **없는 메뉴를 찾아보라고 안내**하게 된다.
  IF public.is_settlement_public() THEN
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    VALUES (
      v_row.influencer_id, 'settlement_paid', 'settlements', p_settlement_id,
      '報酬のお振込みが完了しました',
      'キャンペーンの報酬をPayPalにお振込みしました。マイページの「報酬・精算」からご確認ください。'
    );
  END IF;

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) IS
  '정산 단건을 송금완료로. [339] 실제 보낸 날짜(p_paid_at)·금액(p_paid_amount_jpy)을 받을 수 있고 '
  '둘 다 생략하면 종전대로 now()·NULL 로 동작한다. paid_amount_jpy 의 NULL 은 「계산값과 같음」이지 0원이 아니다. '
  'amount_jpy 는 계산 근거와 짝을 이루는 스냅샷이라 덮지 않는다. 알림 잠금 게이트(241)는 그대로.';

REVOKE ALL ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) TO authenticated;

-- ── ② 과거 미등록 일괄 등록 ──────────────────────────────────
DROP FUNCTION IF EXISTS public.register_past_settlements(uuid[], text, text);

CREATE FUNCTION public.register_past_settlements(
  p_application_ids uuid[],
  p_target_status   text,
  p_memo            text,
  -- ★ [339] 실제로 보낸 날짜. **생략 가능**(생략 시 종전대로 `now()`).
  --   ⚠️ **금액 인자는 일부러 안 받는다** — 일괄이라 건마다 금액이 다른데 하나의 값으로
  --      넣을 수 없다. 계산값과 다른 건은 등록한 뒤 `correct_settlement_payment`
  --      (마이그레이션 E)로 개별 정정한다.
  p_paid_at         timestamptz DEFAULT NULL
)
RETURNS TABLE (
  registered_count         integer,
  skipped_no_paypal_count  integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_registered        integer := 0;
  v_skipped_no_paypal integer := 0;
  v_memo              text;
BEGIN
  -- ── 권한 게이트: settlement.pay 최소 write (300 과 동일) ──
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ── 목표 상태 검증: paid | pending 만 허용 (300 과 동일) ──
  IF p_target_status NOT IN ('paid', 'pending') THEN
    RAISE EXCEPTION 'invalid_target_status: paid 또는 pending 만 허용됩니다 (입력값: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  IF p_application_ids IS NULL OR array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION 'empty_application_ids: 처리할 응모를 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ★ [339] 앞날 날짜 방어 (단건 함수와 같은 기준·같은 이유)
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- ★ [339] 「정산대기로 등록」인데 송금일을 준 경우 — 조용히 버리지 않고 막는다.
  --   정산대기는 아직 안 보낸 상태라 송금일이 성립하지 않는다. 인자를 무시하면 화면에서는
  --   날짜를 넣었는데 아무 데도 안 남아, 나중에 「왜 비었나」를 못 찾는다.
  IF p_paid_at IS NOT NULL AND p_target_status <> 'paid' THEN
    RAISE EXCEPTION 'paid_at_requires_paid: 송금일은 송금완료로 등록할 때만 넣을 수 있습니다 (목표 상태: %)', p_target_status
      USING ERRCODE = '22023';
  END IF;

  v_memo := COALESCE(NULLIF(btrim(p_memo), ''), '과거 이관 (수동 처리)');

  WITH targets AS (
    -- ── 서버 재검증(300 원칙 유지) + [324, H-5] cert_at 함께 조회 ──
    SELECT c.application_id, c.influencer_id, c.campaign_id,
           c.amount_jpy, c.amount_source, c.reward_part_jpy,
           c.receipt_amount_jpy, c.amount_cap_jpy, c.cert_at, c.paypal_email,
           -- [324, H-4] 이 건의 페이팔 등록 여부 — 아래에서 paid 목표일 때만 사용.
           (NULLIF(btrim(c.paypal_email), '') IS NULL) AS no_paypal
    FROM public._settlement_cert_candidates() c
    WHERE c.application_id = ANY(p_application_ids)
      AND c.is_success
      AND c.amount_issue IS NULL
      -- ★ [339] 도입일(컷오프) 조건을 **없앴다.** 337 이 목록 함수에서만 없애면서
      --   「목록에는 뜨는데 골라서 누르면 여기서 조용히 걸러져 등록 건수만 줄어드는」
      --   어긋남을 남겼고(오류도 사유 표시도 없다), **여기서 함께 다루라고 337 파일에
      --   적어 두었다.** 2단계가 이 버튼을 잠가 둬서 아직 드러나지 않았을 뿐이라,
      --   작업 7에서 잠금을 푸는 순간 되살아난다.
      --   ⚠️ 중복 등록은 아래 `ON CONFLICT (application_id) DO NOTHING` 이 막는다 —
      --      이 조건이 하던 「자동 등록과 겹치지 않게」 역할은 그쪽이 이미 하고 있다.
  ),
  blocked AS (
    -- [324, H-4] "송금완료로 만드는데 페이팔이 없는" 건 — 이 배치에서 제외.
    SELECT * FROM targets WHERE p_target_status = 'paid' AND no_paypal
  ),
  eligible AS (
    -- pending 목표는 페이팔 유무와 무관하게 전부 통과(아직 실제 송금이 일어나지
    -- 않았으므로). paid 목표는 페이팔이 있는 건만 통과.
    SELECT * FROM targets WHERE NOT (p_target_status = 'paid' AND no_paypal)
  ),
  inserted AS (
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, cert_at,
      status, paypal_email, paid_at, paid_by, memo
    )
    SELECT
      t.influencer_id, t.application_id, t.campaign_id,
      t.amount_jpy, t.amount_source, t.reward_part_jpy,
      t.receipt_amount_jpy, t.amount_cap_jpy, t.cert_at,
      p_target_status,
      NULLIF(t.paypal_email, ''),
      -- ★ [339] 받은 송금일을, 없으면 종전대로 지금 시각을. 정산대기는 여전히 NULL.
      CASE WHEN p_target_status = 'paid' THEN COALESCE(p_paid_at, now()) ELSE NULL END,
      CASE WHEN p_target_status = 'paid' THEN auth.uid() ELSE NULL END,
      v_memo
    FROM eligible t
    -- 동시 처리 경쟁 방지(이중 방어 — 300 과 동일).
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id
  ),
  events_ins AS (
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행.
    -- ⚠️ notifications INSERT 는 여기 없음(233 「알림 없음」 원칙 그대로 — 의도적).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, p_target_status, auth.uid(), v_memo
    FROM inserted
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM blocked)
  INTO v_registered, v_skipped_no_paypal;

  RETURN QUERY SELECT v_registered, v_skipped_no_paypal;
END;
$$;

COMMENT ON FUNCTION public.register_past_settlements(uuid[], text, text, timestamptz) IS
  '과거 미등록 정산을 일괄 등록. [339] 실제 보낸 날짜(p_paid_at)를 받을 수 있고 생략하면 종전대로 now(). '
  '금액 인자는 일부러 없다(건마다 달라 하나로 못 넣는다 — correct_settlement_payment 로 개별 정정). '
  '정산대기 목표에 송금일을 주면 조용히 버리지 않고 막는다. 324 의 페이팔 확인·cert_at 저장·알림 없음 원칙은 그대로.';

REVOKE ALL ON FUNCTION public.register_past_settlements(uuid[], text, text, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_past_settlements(uuid[], text, text, timestamptz) TO authenticated;

-- ⚠️ 서명이 바뀌었으니 PostgREST 에 스키마를 다시 읽으라고 알린다. 베이스 241·324 도
--    같은 구문을 넣었다. 안 넣으면 첫 호출이 「함수를 찾을 수 없다」(PGRST202)로 실패할 수 있다.
NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다) ────────────────
-- [1] 옛 판이 사라지고 새 판만 남았나 (기대: 각 1행)
--   SELECT p.oid::regprocedure AS 시그니처
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname='public'
--      AND p.proname IN ('mark_settlement_paid','register_past_settlements')
--    ORDER BY p.proname;
--   기대: mark_settlement_paid(uuid,integer,text,timestamp with time zone,bigint)
--         register_past_settlements(uuid[],text,text,timestamp with time zone)
--
-- [2] 241 의 알림 잠금 게이트가 그대로 있나 (기대: 1)
--   SELECT count(*) FROM pg_proc
--    WHERE proname='mark_settlement_paid'
--      AND pg_get_functiondef(oid) LIKE '%is_settlement_public()%';
--
-- [3] 324 의 페이팔 확인이 그대로 있나 (기대: 1)
--   SELECT count(*) FROM pg_proc
--    WHERE proname='register_past_settlements'
--      AND pg_get_functiondef(oid) LIKE '%no_paypal%';
--
-- [4] ★ **실제로 한 번 부른다.** 함수를 만드는 구문은 본문 자료형을 검사하지 않아
--     적용은 성공하고 첫 호출에서 터진다(2026-08-18 마이그레이션 335, 42804).
--   ⚠️ SQL 편집기는 서비스 키라 has_permission 가드에 막힌다(42501) — **관리자 브라우저**에서:
--       // ㄱ) 인자를 생략해도 종전과 같은가 (없는 id 라 「찾을 수 없습니다」가 나오면 본문 통과)
--       await db.rpc('mark_settlement_paid',
--         { p_settlement_id:'00000000-0000-0000-0000-000000000000', p_version:1, p_memo:'시험' })
--       // ㄴ) 앞날 날짜 방어가 도는가 (기대: paid_at_in_future)
--       await db.rpc('mark_settlement_paid',
--         { p_settlement_id:'00000000-0000-0000-0000-000000000000', p_version:1, p_memo:'시험',
--           p_paid_at:'2030-01-01T00:00:00+09:00' })
--       // ㄷ) 정산대기에 송금일을 주면 막히는가 (기대: paid_at_requires_paid)
--       await db.rpc('register_past_settlements',
--         { p_application_ids:['00000000-0000-0000-0000-000000000000'],
--           p_target_status:'pending', p_memo:'시험', p_paid_at:'2026-06-01T00:00:00+09:00' })
--   ⚠️ 화면의 기록 경로는 아직 잠겨 있다(작업 7에서 푼다). 위 호출은 그 잠금을 우회하므로
--      **없는 id 로만** 하고 운영의 실제 행에는 하지 말 것.
--
-- [5] 등록 함수에 컷오프 조건이 남아 있지 않나 (기대: 0)
--   SELECT count(*) FROM pg_proc
--    WHERE proname='register_past_settlements'
--      AND pg_get_functiondef(oid) LIKE '%v_cutoff%';
--
-- 롤백 (역순):
--   DROP FUNCTION IF EXISTS public.register_past_settlements(uuid[], text, text, timestamptz);
--   DROP FUNCTION IF EXISTS public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint);
--   이어서 324 의 register_past_settlements 절과 241 의 함수 정의를 다시 적용한다.
