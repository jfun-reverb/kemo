-- ============================================================
-- 416. 정산 보류 해제가 송금 기록 3칸을 비운다 · 일괄 송금완료가 단건과 같은 칸을 쓴다
-- ============================================================
-- 조치 계획: docs/specs/2026-09-02-audit-remediation-plan.md 묶음 B — B-1
-- 조사 원문: docs/research/2026-09-02-codebase-audit-findings.md §2-1
-- 결정(2026-09-07 사용자): 3칸은 **보류 해제 때만** 비운다. 보류·취소는 환수 근거로 보존.
--
-- ── 무엇이 문제였나 ─────────────────────────────────────────
-- 「송금완료 → 보류(환수) → 보류 해제 → 정산대기」로 돌아온 행에 **실제 송금액 칸
-- (`paid_amount_jpy`, 338)·송금일·송금자**가 그대로 남는다. 224 가 「금전 칸 보존」을
-- 정할 때 실제 송금액 칸은 존재하지도 않았고, 338 이 그 칸을 만들 때 224 를 다시 안 봤다.
--
-- 지급 준비 화면의 합계(`settlementEffectiveAmount`)는 실제 송금액을 **우선** 쓰므로,
-- 계산액 ¥3,200 을 ¥1,000 만 보내 기록했다가 보류 해제하면 정산대기 소계가 **¥1,000**
-- 으로 잡히고 **그게 곧 페이팔에 치는 숫자**다 — ¥2,200 과소 송금. 화면은 「정산대기」인데
-- 「송금완료일」에 날짜가 찍혀 이미 보낸 것으로도 읽힌다.
-- 운영 실측(M3, 2026-09-02): 그런 행 **0건** — 잠복. 버튼 두 번이면 도달한다.
--
-- ── 무엇을 바꾸나 ───────────────────────────────────────────
-- ① `mark_settlement_revert`(현재 원본 224) — on_hold → pending 으로 돌아갈 때
--    `paid_at`·`paid_by`·`paid_amount_jpy` 를 **NULL 로 비운다.** 정산대기는 「아직 안 보낸」
--    상태이므로 송금 기록이 붙어 있으면 안 된다.
--    ⚠️ 비우기 전 값을 **이력(`settlement_events.memo`)에 적는다** — 환수 사실이 화면에서
--       사라지더라도 「이력」 모달에서 언제·얼마를 보냈었는지 되찾을 수 있게.
--    ⚠️ `paypal_email` 은 그대로 둔다 — 송금 기록이 아니라 수신처 스냅샷이고, 다음
--       송금완료가 어차피 최신값으로 다시 채운다(343).
-- ② `mark_settlements_paid_bulk`(현재 원본 **343** — 340 이 만들고 343 이 알림을 걷어냈다)
--    — UPDATE 에 `paid_amount_jpy = NULL` 을 **명시**한다. 단건(`mark_settlement_paid`, 343)은
--    인자값으로 무조건 덮어쓰는데(인자가 없으면 NULL) 일괄은 그 칸을 안 건드려, **같은 행이
--    어느 단추를 누르느냐에 따라 다른 금액으로 기록**됐다. 일괄은 건별 금액을 받지 않으므로
--    「계산액 그대로」= NULL 이 단건과 같은 뜻이다.
--    🔴 **343 을 베이스로 통째로 옮겼다** — 340 을 베이스로 쓰면 343 이 걷어낸
--       인플루언서 알림 블록이 되살아난다.
-- ③ 보류(`mark_settlement_hold`)·취소(`mark_settlement_cancel`)는 **안 건드린다** — 223·224 의
--    「환수 근거 보존」은 그대로다.
--
-- ── 화면 쪽 짝 ───────────────────────────────────────────────
-- `settlementEffectiveAmount`(dev/lib/shared.js)가 **정산대기(pending) 행은 실제 송금액을
-- 무시**하게 함께 고쳤다 — 이 함수가 돌기 전에 이미 어긋난 행이 있어도(운영 0건) 합계가
-- 틀리지 않게 하는 안전판. 서버가 먼저다.
--
-- 롤백: 224 의 mark_settlement_revert · 343 의 mark_settlements_paid_bulk 로 되돌린다
--       (둘 다 CREATE OR REPLACE — 시그니처·권한 불변).
-- ============================================================

-- ── ① 보류 해제 — 송금 기록 3칸 비우기 (베이스 224) ──────────
CREATE OR REPLACE FUNCTION public.mark_settlement_revert(
  p_settlement_id uuid,
  p_version       integer,
  p_memo          text
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_row         record;
  v_new_version integer;
  v_event_memo  text;
BEGIN
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 보류 해제 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- [416] 비우기 전 값을 이력에 남기려고 송금 기록 3칸도 함께 읽는다.
  SELECT id, status, version, paid_at, paid_by, paid_amount_jpy, amount_jpy
    INTO v_row
    FROM public.settlements
   WHERE id = p_settlement_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION '정산 내역을 찾을 수 없습니다 (id: %)', p_settlement_id USING ERRCODE = '02000';
  END IF;

  IF v_row.version <> p_version THEN
    RETURN -1;
  END IF;

  IF v_row.status <> 'on_hold' THEN
    RAISE EXCEPTION '보류(on_hold) 상태만 해제할 수 있습니다 (현재 상태: %)', v_row.status
      USING ERRCODE = '22023';
  END IF;

  -- [416] 송금 기록이 있던 행(= paid 에서 보류로 온 행)이면 이력 메모에 옛 값을 적는다.
  --   ⚠️ 「자동 보류」 같은 연속 표현은 쓰지 않는다 — 화면이 그 문자열로 배지를 그린다(302).
  v_event_memo := p_memo;
  IF v_row.paid_at IS NOT NULL OR v_row.paid_amount_jpy IS NOT NULL THEN
    v_event_memo := COALESCE(NULLIF(btrim(p_memo), ''), '보류 해제')
      || E'\n[송금 기록 초기화] 송금일 '
      || COALESCE(to_char(v_row.paid_at AT TIME ZONE 'Asia/Tokyo', 'YYYY-MM-DD HH24:MI'), '없음')
      || ' · 송금액 '
      || CASE WHEN v_row.paid_amount_jpy IS NULL
              THEN '계산액 그대로(¥' || COALESCE(v_row.amount_jpy::text, '?') || ')'
              ELSE '¥' || v_row.paid_amount_jpy::text
         END
      || ' — 정산대기로 돌아가며 비움';
  END IF;

  -- [416] 정산대기로 돌아가면 「아직 안 보낸」 상태다 — 송금 기록 3칸을 비운다.
  --   paypal_email 은 수신처 스냅샷이라 그대로 둔다(다음 송금완료가 최신값으로 다시 채운다).
  UPDATE public.settlements
     SET status          = 'pending',
         memo            = p_memo,
         paid_at         = NULL,
         paid_by         = NULL,
         paid_amount_jpy = NULL,
         version         = version + 1
   WHERE id = p_settlement_id;

  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'revert', v_row.status, 'pending', auth.uid(), v_event_memo);

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_revert(uuid, integer, text) IS
  '[224→416] 관리자가 보류(on_hold) 정산을 정산대기(pending)로 되돌리는 RPC. '
  'SECURITY DEFINER, has_permission(''settlement.pay'',''write'') 게이트. 낙관적 락 충돌 시 -1. '
  '[416] paid_at/paid_by/paid_amount_jpy 를 NULL 로 비우고 옛 값은 settlement_events.memo 에 남긴다 '
  '(정산대기에 송금 기록이 남으면 지급 준비 합계가 그 값을 써 과소 송금). paypal_email 은 보존. 인플루언서 알림 없음.';

-- ── ② 일괄 송금완료 — paid_amount_jpy 를 단건과 같게 명시 (베이스 343) ──
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
  v_paid          integer := 0;
  v_skip_paypal   integer := 0;
  v_skip_status   integer := 0;
  v_missing       integer := 0;
BEGIN
  -- ── 권한 가드: settlement.pay 최소 write (340 과 동일) ──────────
  IF NOT public.has_permission('settlement.pay', 'write') THEN
    RAISE EXCEPTION 'permission_denied: 정산 송금 처리 권한이 없습니다' USING ERRCODE = '42501';
  END IF;

  -- ⚠️ 「비었나」를 길이만으로 보면 안 된다(340 그대로). `[null]` 은 길이가 1이라
  --   이 검사를 통과한 뒤 반복문에서 걸러져 네 건수가 전부 0인 채 조용히 성공으로
  --   끝난다. 실제 값이 하나라도 있는지 본다.
  IF p_settlement_ids IS NULL
     OR array_length(p_settlement_ids, 1) IS NULL
     OR NOT EXISTS (SELECT 1 FROM unnest(p_settlement_ids) AS x WHERE x IS NOT NULL) THEN
    RAISE EXCEPTION 'empty_settlement_ids: 처리할 정산을 1건 이상 선택해야 합니다'
      USING ERRCODE = '22023';
  END IF;

  -- ── 앞날 날짜 방어 (340 과 같은 기준) ───────────────────────────
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  v_paid_at := COALESCE(p_paid_at, now());
  v_memo    := COALESCE(NULLIF(btrim(p_memo), ''), '일괄 송금완료');

  -- ⚠️ DISTINCT + ORDER BY — 같은 id 가 두 번 와도 한 번만 처리하고,
  --    항상 같은 순서로 잠가 동시 실행 시 교착을 막는다(340 그대로).
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

    -- 페이팔 최신값 재조회 (마스킹 뷰 우회 — DEFINER 로 원본 표 직접 조회)
    SELECT NULLIF(btrim(i.paypal_email), '')
      INTO v_paypal_fresh
      FROM public.influencers i
     WHERE i.id = v_row.influencer_id;

    IF v_paypal_fresh IS NULL THEN
      v_skip_paypal := v_skip_paypal + 1;
      CONTINUE;
    END IF;

    UPDATE public.settlements s
       SET status          = 'paid',
           paid_at         = v_paid_at,
           paid_by         = auth.uid(),
           -- [416] 일괄은 건별 금액을 받지 않는다 = 「계산액 그대로」. 단건(343)이 인자 없을 때
           --   NULL 로 덮어쓰는 것과 같은 뜻으로 **명시**한다 — 안 적으면 옛 값이 남은 행에서
           --   단건과 일괄이 다른 금액을 기록한다.
           paid_amount_jpy = NULL,
           paypal_email    = v_paypal_fresh,
           -- 메모는 덮어쓰지 않고 덧붙인다(340 그대로).
           memo            = CASE
                               WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_memo
                               ELSE s.memo || E'\n' || v_memo
                             END,
           version         = s.version + 1
     WHERE s.id = v_id;

    -- ── 금전 감사 이력: 항상 남는다 ──────────────────────────────
    INSERT INTO public.settlement_events
      (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_id, 'pay', 'pending', 'paid', auth.uid(), v_memo);

    -- [343] 인플루언서 알림(settlement_paid) INSERT 구간은 343 에서 제거됐고 여기서도 없다.

    v_paid := v_paid + 1;
  END LOOP;

  RETURN QUERY SELECT v_paid, v_skip_paypal, v_skip_status, v_missing;
END;
$$;

COMMENT ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) IS
  '[340→343→416] 정산 여러 건을 한 번에 송금완료로. 건너뛴 사유 3종을 각각 센다. '
  '[416] paid_amount_jpy = NULL 을 명시해 단건(mark_settlement_paid)과 같은 칸을 같은 뜻으로 쓴다. '
  '인플루언서 알림 없음(343).';

-- 권한은 CREATE OR REPLACE 로 보존된다(224·343 이 건 REVOKE FROM PUBLIC / GRANT authenticated).

-- ============================================================
-- 검증 (개발 DB, 한 트랜잭션 안에서 돌리고 ROLLBACK — 데이터 안 남김)
-- ============================================================
-- ⚠️ 두 함수 모두 has_permission 가드가 있어 SQL 편집기 기본 권한(postgres)으로는
--    auth.uid() 가 비어 거부된다. 관리자 계정을 흉내낸다:
--
--   begin;
--   set local role authenticated;
--   select set_config('request.jwt.claims', '{"sub":"<관리자 auth_id>","role":"authenticated"}', true);
--   -- 송금완료 행 하나를 골라 보류 → 해제
--   select public.mark_settlement_hold('<paid 행 id>', <version>, '검증 보류');
--   select public.mark_settlement_revert('<같은 id>', <version+1>, '검증 해제');
--   select status, paid_at, paid_by, paid_amount_jpy, paypal_email, version
--     from public.settlements where id = '<같은 id>';
--   -- 기대: status=pending · paid_at/paid_by/paid_amount_jpy 전부 NULL · paypal_email 그대로
--   select action, memo from public.settlement_events where settlement_id = '<같은 id>' order by at desc limit 2;
--   -- 기대: revert 행 memo 에 「[송금 기록 초기화] 송금일 … · 송금액 …」
--   rollback;
--
-- 일괄: pending 행 id 로 mark_settlements_paid_bulk(array[...]) 를 부른 뒤 같은 행의
--   paid_amount_jpy 가 NULL 인지 본다(그 전에 그 칸에 값을 넣어 두고 돌리면 NULL 로 덮이는 것까지 확인).
-- ============================================================
