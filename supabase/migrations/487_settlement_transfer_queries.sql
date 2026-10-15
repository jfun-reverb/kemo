-- 487_settlement_transfer_queries.sql
-- 정산 송금 묶음 조회 함수 (조각 7 — 목록 · 월별 · 회차별 · 수수료 기록 없음 + 회차 판정 헬퍼)
-- 사양서: docs/specs/2026-09-30-settlement-transfer-fee-record.md (D-4·D-5)
-- 작업표: docs/specs/2026-09-30-settlement-transfer-fee-record-breakdown.md 「조각 7」
--
-- 선행: 484 · 485 · 486. 이 파일은 읽기 전용 함수만 만든다(표·칸·기존 함수 변경 없음).
--
-- ▶ 함수 다섯
--   _settlement_payout_due(timestamptz)             — 회차(원래 지급 예정일) 판정. 내부 전용
--   get_settlement_transfers(date, date)            — 송금 묶음 1줄 + 포함 건 jsonb
--   get_settlement_transfer_monthly(date, date)     — 송금일(일본 시각) 달별 합계
--   get_settlement_transfer_by_round(date, date)    — 회차별 합계
--   get_settlement_transfer_unrecorded()            — 「수수료 기록 없음」 건수·보낸 금액
--
-- ▶ 공통
--   · 모두 SECURITY DEFINER · SET search_path='' · STABLE. 가드 has_permission('settlement.view','read') 아니면 forbidden(42501).
--   · 합계는 **저장값만** 더한다(수수료를 다시 계산하지 않는다).
--   · 🔴 페이팔 주소를 내보내지 않는다(485 머리말 — 363 파기 대상 밖 사본 방지). 이름은 influencers.name 을 **저장된 그대로**(아래 참고).
--   · 기간 필터의 날짜는 모두 「일본 날짜」다(Asia/Tokyo). NULL = 그쪽 끝 열림.
--
-- ▶ 결정한 것들 (열린 점)
--   [1] 받는 사람 이름 — 탈퇴 확정 회원은 352(파기)가 influencers.name 을 NULL 로 비우므로 **NULL 이 그대로 온다**
--       (자리표시 문자열은 이메일 칸에만 들어간다). 화면이 「(탈퇴한 회원)」 등으로 그린다.
--   [2] 수수료 재확인 표시 fee_stale (「금액이 바뀌었는데 수수료는 손으로 고친 값」) —
--       규칙: fee_manual = true 이고, **수수료를 마지막으로 정한 시점 이후에** 건별 송금액 정정(correct_settlement_payment 가
--       남기는 settlement_transfer_events 'correct', prev/next 에 sent_total_jpy 칸이 있고 값이 다름)이 있으면 true.
--       「수수료를 마지막으로 정한 시점」 = 'create' 이벤트 또는, 수수료가 실제로 바뀐 묶음 정정 이벤트(correct_settlement_transfer 가
--       남기는 것 — prev 에 sent_total_jpy 칸이 없고 prev.fee_jpy ≠ next.fee_jpy)의 가장 늦은 at.
--       → 손으로 고친 수수료를 사람이 다시 손봤으면(묶음 정정) 표시가 꺼지고, 그 뒤 금액이 또 바뀌면 다시 켜진다.
--       ⚠️ 한계: 수수료를 같은 값으로 「다시 입력」한 정정(fee_manual 만 false→true)은 수수료가 안 바뀐 것으로 보아 시점에 안 넣는다.
--       fee_manual=false(자동값)는 correct_settlement_payment 가 스냅샷 규칙으로 다시 계산하므로 항상 false.
--   [3] 월별 settlement_count — 그 묶음들의 **연결 행 전부**(보류 해제로 끊긴 옛 연결 포함)를 센다. 돈이 실제로 나간 건수이고,
--       묶음 합(sent_total_jpy)도 486 이 연결 행 전체의 합으로 유지하므로 「금액과 건수의 기준이 같다」.
--       (한 정산 건이 보류 해제 뒤 다시 송금되어 두 묶음에 걸치면 그 건은 두 번 센다 — 보낸 횟수 기준.)
--   [4] 회차별 — 보낸 금액은 연결 행마다 **그 정산 건 자신의 회차**(_settlement_payout_due(settlements.cert_at))에,
--       수수료는 묶음별로 **그 묶음 연결 행들의 원래 회차 중 가장 늦은 것**에 통째로(D-4). 연결 행은 [3] 과 같이 전부 대상.
--       cert_at 이 NULL 인 건은 due_date NULL 「지급일 기록 없음」 줄로 모은다. 묶음의 모든 건이 NULL 이면 수수료도 그 줄로.
--       settlement_count = 그 회차에 속한 연결 행 수(정산 건 기준 distinct).
--       기간 필터는 due_date 기준. **NULL 줄은 p_from 과 p_to 가 둘 다 NULL(전체 조회)일 때만** 포함 — 기간을 준 조회에서는
--       날짜 없는 줄이 어느 기간에도 속하지 않기 때문. (그래서 월별과 달리 기간을 주면 같은 기간 합이 일치하지 않는다 —
--       월별은 송금일 기준, 회차별은 지급 예정일 기준이라 기준 축이 다르다. 전체 조회에서만 세 합이 같다.)
--   [5] 수수료 기록 없음 — 상태 무관(송금완료·보류·취소) paid_at IS NOT NULL AND current_transfer_id IS NULL.
--       총계 외에 상태별(paid / on_hold / cancelled) 건수·금액도 한 줄로 함께 돌려준다(싸다 — 같은 스캔).
--       금액 = COALESCE(paid_amount_jpy, amount_jpy).
--
-- ▶ 정렬 — get_settlement_transfers 는 ORDER BY sent_at, id (유일 정렬). 원격 호출은 1,000행에서 잘리므로 클라이언트가
--   range() 로 나눠 받는다(조각 9 fetchAllPaged). 나머지 셋은 행 수가 작아 한 번에 받는다.
--
-- ▶ 두 벌 경고 — _settlement_payout_due 는 dev/lib/shared.js 의 payoutDueDate 의 SQL 사본이다(판정 두 벌).
--   한쪽만 고치면 화면의 회차와 서버 집계 회차가 조용히 갈린다.
--
-- 롤백 (새 함수뿐 — 다른 객체 영향 없음. 화면(조각 9 이후)이 붙은 뒤에는 그쪽을 먼저 걷을 것):
--   DROP FUNCTION IF EXISTS public.get_settlement_transfer_unrecorded();
--   DROP FUNCTION IF EXISTS public.get_settlement_transfer_by_round(date, date);
--   DROP FUNCTION IF EXISTS public.get_settlement_transfer_monthly(date, date);
--   DROP FUNCTION IF EXISTS public.get_settlement_transfers(date, date);
--   DROP FUNCTION IF EXISTS public._settlement_payout_due(timestamptz);

BEGIN;

-- ============================================================
-- 1. _settlement_payout_due(timestamptz) — 회차(원래 지급 예정일)
--    ⚠️ 두 벌 — dev/lib/shared.js 의 payoutDueDate 와 같이 고칠 것.
--    규칙: 인증 성공 시각을 **일본 시각**으로 옮겨 날짜(일)를 본다.
--      1~15일  → 다음 달 15일
--      16~말일 → 다음 달 말일
--    NULL → NULL (STRICT). 실행 권한을 아무에게도 주지 않는다(부르는 쪽은 전부 SECURITY DEFINER).
-- ============================================================
CREATE OR REPLACE FUNCTION public._settlement_payout_due(p_cert_at timestamptz)
RETURNS date
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = ''
AS $$
  SELECT CASE
           WHEN extract(day FROM (p_cert_at AT TIME ZONE 'Asia/Tokyo'))::integer <= 15
             THEN (date_trunc('month', p_cert_at AT TIME ZONE 'Asia/Tokyo')::date + interval '1 month' + interval '14 days')::date
           ELSE   (date_trunc('month', p_cert_at AT TIME ZONE 'Asia/Tokyo')::date + interval '2 month' - interval '1 day')::date
         END;
$$;

COMMENT ON FUNCTION public._settlement_payout_due(timestamptz) IS
  '[487] 지급 회차(원래 지급 예정일) = 일본 시각 1~15일 → 다음 달 15일 / 16~말일 → 다음 달 말일 / NULL → NULL. '
  '두 벌 — dev/lib/shared.js 의 payoutDueDate 와 같이 고칠 것. 내부 전용.';

REVOKE ALL ON FUNCTION public._settlement_payout_due(timestamptz) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._settlement_payout_due(timestamptz) FROM anon;
REVOKE ALL ON FUNCTION public._settlement_payout_due(timestamptz) FROM authenticated;

-- ============================================================
-- 2. get_settlement_transfers(p_from, p_to) — 송금 묶음 목록 (묶음 1줄 + 포함 건 jsonb)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_settlement_transfers(p_from date, p_to date)
RETURNS TABLE (
  id                uuid,
  sent_at           timestamptz,
  influencer_id     uuid,
  influencer_name   text,
  sent_total_jpy    bigint,
  fee_jpy           bigint,
  fee_manual        boolean,
  fee_rate_percent  numeric,
  fee_fixed_jpy     integer,
  fee_rounding      text,
  paypal_txn_id     text,
  memo              text,
  source            text,
  recorded_by       uuid,
  recorded_by_name  text,
  recorded_at       timestamptz,
  version           integer,
  total_spend_jpy   bigint,
  fee_stale         boolean,
  items             jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT t.id,
         t.sent_at,
         t.influencer_id,
         i.name,
         t.sent_total_jpy,
         t.fee_jpy,
         t.fee_manual,
         t.fee_rate_percent,
         t.fee_fixed_jpy,
         t.fee_rounding,
         t.paypal_txn_id,
         t.memo,
         t.source,
         t.recorded_by,
         (SELECT a.name FROM public.admins a WHERE a.auth_id = t.recorded_by LIMIT 1),
         t.recorded_at,
         t.version,
         (t.sent_total_jpy + t.fee_jpy),
         -- [2] fee_stale — 파일 머리말 규칙
         (t.fee_manual AND EXISTS (
            SELECT 1
              FROM public.settlement_transfer_events pe
             WHERE pe.transfer_id = t.id
               AND pe.action = 'correct'
               AND pe.prev ? 'sent_total_jpy'
               AND pe.next ? 'sent_total_jpy'
               AND (pe.prev ->> 'sent_total_jpy') IS DISTINCT FROM (pe.next ->> 'sent_total_jpy')
               AND pe.at > COALESCE((
                     SELECT max(fe.at)
                       FROM public.settlement_transfer_events fe
                      WHERE fe.transfer_id = t.id
                        AND (fe.action = 'create'
                             OR (fe.action = 'correct'
                                 AND NOT (fe.prev ? 'sent_total_jpy')
                                 AND (fe.prev ->> 'fee_jpy') IS DISTINCT FROM (fe.next ->> 'fee_jpy')))
                   ), '-infinity'::timestamptz)
         )),
         COALESCE((
           SELECT jsonb_agg(jsonb_build_object(
                    'settlement_id',   ti.settlement_id,
                    'application_id',  s.application_id,
                    'campaign_id',     s.campaign_id,
                    'campaign_no',     c.campaign_no,
                    'campaign_title',  c.title,
                    'amount_jpy',      ti.amount_jpy,
                    'due_date',        public._settlement_payout_due(s.cert_at),
                    'cert_at',         s.cert_at,
                    'is_current',      (ti.revert_event_id IS NULL),
                    'revert_event_id', ti.revert_event_id
                  ) ORDER BY ti.created_at, ti.id)
             FROM public.settlement_transfer_items ti
             JOIN public.settlements s ON s.id = ti.settlement_id
             LEFT JOIN public.campaigns c ON c.id = s.campaign_id
            WHERE ti.transfer_id = t.id
         ), '[]'::jsonb)
    FROM public.settlement_transfers t
    LEFT JOIN public.influencers i ON i.id = t.influencer_id
   WHERE (p_from IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date >= p_from)
     AND (p_to   IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date <= p_to)
   ORDER BY t.sent_at, t.id;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfers(date, date) IS
  '[487] 송금 묶음 목록(송금일=일본 날짜 기준 기간, NULL=열림). 묶음 1줄 + items(포함 건: 캠페인·연결 금액·원래 지급 예정일·현재 연결 여부) + fee_stale. '
  '정렬 sent_at,id 유일. 페이팔 주소 미노출. fee_stale 규칙은 487 머리말 [2].';

REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfers(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfers(date, date) TO authenticated;

-- ============================================================
-- 3. get_settlement_transfer_monthly(p_from, p_to) — 송금일(일본 시각) 달별
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_settlement_transfer_monthly(p_from date, p_to date)
RETURNS TABLE (
  month            date,
  transfer_count   bigint,
  settlement_count bigint,
  sent_total_jpy   bigint,
  fee_jpy          bigint,
  total_spend_jpy  bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH tr AS (
    SELECT t.id,
           date_trunc('month', t.sent_at AT TIME ZONE 'Asia/Tokyo')::date AS m,
           t.sent_total_jpy AS sent_total,
           t.fee_jpy        AS fee,
           (SELECT count(*) FROM public.settlement_transfer_items ti WHERE ti.transfer_id = t.id) AS n_items
      FROM public.settlement_transfers t
     WHERE (p_from IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date >= p_from)
       AND (p_to   IS NULL OR (t.sent_at AT TIME ZONE 'Asia/Tokyo')::date <= p_to)
  )
  SELECT tr.m,
         count(*)::bigint,
         sum(tr.n_items)::bigint,
         sum(tr.sent_total)::bigint,
         sum(tr.fee)::bigint,
         (sum(tr.sent_total) + sum(tr.fee))::bigint
    FROM tr
   GROUP BY tr.m
   ORDER BY tr.m;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfer_monthly(date, date) IS
  '[487] 송금일(일본 시각) 달별 합계 — 송금 횟수·건수(연결 행 전부)·보낸 금액·수수료·총지출. 저장값만 더한다. 487 머리말 [3].';

REVOKE ALL ON FUNCTION public.get_settlement_transfer_monthly(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfer_monthly(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfer_monthly(date, date) TO authenticated;

-- ============================================================
-- 4. get_settlement_transfer_by_round(p_from, p_to) — 회차별
--    보낸 금액 = 연결 행마다 그 건 자신의 회차 / 수수료 = 묶음별로 가장 늦은 원래 회차에 통째로
--    cert_at NULL → due_date NULL 줄. 487 머리말 [4].
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_settlement_transfer_by_round(p_from date, p_to date)
RETURNS TABLE (
  due_date         date,
  settlement_count bigint,
  sent_total_jpy   bigint,
  fee_jpy          bigint,
  total_spend_jpy  bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH it AS (
    SELECT ti.transfer_id,
           ti.settlement_id,
           ti.amount_jpy AS amt,
           public._settlement_payout_due(s.cert_at) AS due
      FROM public.settlement_transfer_items ti
      JOIN public.settlements s ON s.id = ti.settlement_id
  ),
  -- 묶음마다 가장 늦은 원래 회차(NULL 은 max 가 무시 — 전부 NULL 이면 NULL)
  fee_due AS (
    SELECT t.id AS transfer_id,
           t.fee_jpy AS fee,
           (SELECT max(it.due) FROM it WHERE it.transfer_id = t.id) AS due
      FROM public.settlement_transfers t
  ),
  rows_all AS (
    SELECT it.due, it.settlement_id AS sid, it.amt AS amt, 0::bigint AS fee FROM it
    UNION ALL
    SELECT fd.due, NULL::uuid, 0::bigint, fd.fee FROM fee_due fd
  )
  SELECT r.due,
         count(DISTINCT r.sid)::bigint,
         sum(r.amt)::bigint,
         sum(r.fee)::bigint,
         (sum(r.amt) + sum(r.fee))::bigint
    FROM rows_all r
   WHERE (p_from IS NULL AND p_to IS NULL)
      OR (r.due IS NOT NULL
          AND (p_from IS NULL OR r.due >= p_from)
          AND (p_to   IS NULL OR r.due <= p_to))
   GROUP BY r.due
   ORDER BY r.due NULLS LAST;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfer_by_round(date, date) IS
  '[487] 회차(원래 지급 예정일)별 합계. 보낸 금액=연결 행마다 그 건의 회차, 수수료=묶음 안 가장 늦은 원래 회차에 통째로. cert_at NULL → due_date NULL 줄(기간을 주면 제외). '
  '월별과 기준 축이 달라 기간을 주면 합이 안 맞는 것이 정상. 두 벌 — _settlement_payout_due.';

REVOKE ALL ON FUNCTION public.get_settlement_transfer_by_round(date, date) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfer_by_round(date, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfer_by_round(date, date) TO authenticated;

-- ============================================================
-- 5. get_settlement_transfer_unrecorded() — 「수수료 기록 없음」
--    paid_at IS NOT NULL AND current_transfer_id IS NULL (상태 무관). 한 줄.
--    0 으로 더하지 않는다 — 수수료 칸이 없다(건수·보낸 금액만).
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_settlement_transfer_unrecorded()
RETURNS TABLE (
  unrecorded_count          bigint,
  sent_total_jpy            bigint,
  paid_count                bigint,
  paid_sent_total_jpy       bigint,
  on_hold_count             bigint,
  on_hold_sent_total_jpy    bigint,
  cancelled_count           bigint,
  cancelled_sent_total_jpy  bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
#variable_conflict use_column
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT count(*)::bigint,
         COALESCE(sum(COALESCE(s.paid_amount_jpy, s.amount_jpy)), 0)::bigint,
         count(*) FILTER (WHERE s.status = 'paid')::bigint,
         COALESCE(sum(COALESCE(s.paid_amount_jpy, s.amount_jpy)) FILTER (WHERE s.status = 'paid'), 0)::bigint,
         count(*) FILTER (WHERE s.status = 'on_hold')::bigint,
         COALESCE(sum(COALESCE(s.paid_amount_jpy, s.amount_jpy)) FILTER (WHERE s.status = 'on_hold'), 0)::bigint,
         count(*) FILTER (WHERE s.status = 'cancelled')::bigint,
         COALESCE(sum(COALESCE(s.paid_amount_jpy, s.amount_jpy)) FILTER (WHERE s.status = 'cancelled'), 0)::bigint
    FROM public.settlements s
   WHERE s.paid_at IS NOT NULL
     AND s.current_transfer_id IS NULL;
END;
$$;

COMMENT ON FUNCTION public.get_settlement_transfer_unrecorded() IS
  '[487] 「수수료 기록 없음」 — paid_at 이 있고 현재 묶음이 없는 정산 건(상태 무관)의 건수·보낸 금액(COALESCE(paid_amount_jpy, amount_jpy)) + 상태별 세부. 수수료는 0 으로 더하지 않는다(칸 없음).';

REVOKE ALL ON FUNCTION public.get_settlement_transfer_unrecorded() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_settlement_transfer_unrecorded() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_settlement_transfer_unrecorded() TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (개발 DB 적용 후, 한 단계씩)
-- ⚠️ SQL 편집기는 서비스 키라 가드(forbidden)가 안 돈다 → 가드·결과 확인은 로그인한 관리자 브라우저 콘솔에서:
--   (await db.rpc('get_settlement_transfers',{p_from:null,p_to:null})).data
--   (await db.rpc('get_settlement_transfer_monthly',{p_from:null,p_to:null})).data
--   (await db.rpc('get_settlement_transfer_by_round',{p_from:null,p_to:null})).data
--   (await db.rpc('get_settlement_transfer_unrecorded')).data
--   campaign_manager 로는 네 함수 모두 error 'forbidden'.
-- [1] SQL 편집기: 권한 확인 — 다섯 함수 모두 proacl 맨 앞 '=X/' 없음, anon= 없음. 헬퍼(_settlement_payout_due)는 authenticated= 도 없음
--   SELECT p.proname, p.proacl::text FROM pg_proc p
--    WHERE p.proname IN ('_settlement_payout_due','get_settlement_transfers','get_settlement_transfer_monthly',
--                        'get_settlement_transfer_by_round','get_settlement_transfer_unrecorded');
-- [2] SQL 편집기: 회차 판정 경계값 (일본 시각 기준)
--   SELECT public._settlement_payout_due('2026-09-15 14:59:59+00') AS d15_jst_0h_before,  -- JST 9/15 23:59:59 → 2026-10-15
--          public._settlement_payout_due('2026-09-15 15:00:00+00') AS d16_jst_0h,          -- JST 9/16 00:00:00 → 2026-10-31
--          public._settlement_payout_due('2026-12-20 00:00:00+00') AS dec,                  -- → 2027-01-31
--          public._settlement_payout_due('2026-01-31 00:00:00+00') AS jan,                  -- JST 1/31 → 2026-02-28
--          public._settlement_payout_due(NULL)                     AS nul;                  -- NULL
--   (화면 payoutDueDate 와 같은 입력으로 브라우저 콘솔에서도 같은 값인지 대조 — 두 벌)
-- [3] SQL 편집기: 「수수료 기록 없음」 건수 = 새 묶음을 하나도 안 만든 개발 DB 의 옛 송금 건수
--   SELECT count(*) FROM public.settlements WHERE paid_at IS NOT NULL AND current_transfer_id IS NULL;
--   -- 위 함수의 unrecorded_count 와 같아야 한다. (⚠️ record_settlement_transfers 시험 호출 전에 — 486 머리말 「옛 경로 거부」)
-- [4] 묶음을 만든 뒤(브라우저, 시험 계정으로 기록) 같은 기간(전체)에서 세 합이 같다:
--   목록의 fee_jpy 합 = 월별 fee_jpy 합 = 회차별 fee_jpy 합 (p_from·p_to 둘 다 null 일 때 — 회차별은 기간을 주면 기준 축이 달라 어긋나는 것이 정상)
--   목록의 sent_total_jpy 합 = 월별 = 회차별 sent_total_jpy 합(NULL 줄 포함)
-- [5] fee_stale — 수수료를 손으로 넣어 기록한 묶음에서 그 건의 송금액을 correct_settlement_payment 로 바꾸면 true,
--   correct_settlement_transfer 로 수수료를 다시 손봐 값이 바뀌면 false 로 돌아간다. 자동 계산 묶음은 항상 false.
