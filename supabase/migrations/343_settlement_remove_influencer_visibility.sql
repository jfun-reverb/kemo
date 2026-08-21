-- ============================================================
-- 343_settlement_remove_influencer_visibility.sql
-- 정산 인플루언서 노출·알림 경로를 아예 없앤다 (사용자 결정 2026-08-19)
--
-- ▶ 배경 — 이건 「더 잠그는」 마이그레이션이 아니라 「지우는」 마이그레이션이다
--   정산은 지금 두 겹으로 잠겨 있다 — ①`settlement_settings.influencer_visible=false`
--   가 알림 발행·본인 조회를 막고 ②`cutoff_at=null`이 자동 생성 자체를 막는다.
--   이 마이그레이션을 만든 쪽(개발 세션)은 「이미 두 겹으로 잠겨 있고, 지우는 작업
--   자체가 그 잠금을 깨뜨릴 위험이 더 크다」고 우려를 전달했다. **사용자가 그 우려를
--   들은 뒤에도 그대로 진행을 선택**했다 — 인플루언서 노출·알림 경로를 잠그는 것을
--   넘어 **아예 삭제**하기로 했고, 본인 조회 정책도 함께 지우기로 했다.
--   운영 실측(2026-08-19): `influencer_visible=false` · `cutoff_at=null` ·
--   `is_settlement_public()→false` · `settlement_paid` 알림 0건 · `settlement_paypal_required`
--   알림 0건 — 지울 과거 데이터가 없다(순수 코드 정리).
--
-- ▶ 무엇을 지우나 — **딱 두 가지**
--   ① 세 함수에서 인플루언서 알림 INSERT 구간만 제거(함수 자체는 남는다)
--   ② `settlements` 의 본인 조회 정책(`settlements_select_own`) 삭제
--
-- ▶ 절대 건드리지 않은 것
--   · `backfill_settlements` 의 `paypal_missing_count` 집계 — 관리자 화면이 그 숫자를
--     쓴다. 지우는 건 알림 INSERT 뿐, 집계 자체는 그대로.
--   · `settlement_events` 감사 이력 — 돈이 오간 기록은 세 함수 어디서도 그대로 남는다.
--   · 반환 타입·인자 서명·나머지 판정 로직 — 세 함수 모두 인자·반환 타입이 그대로라
--     `CREATE OR REPLACE` 로 끝난다(`DROP FUNCTION` 불필요).
--   · `settlements_select_admin`(관리자 조회 정책) — 무변경.
--   · `notifications.kind` CHECK 제약의 `settlement_paid`/`settlement_paypal_required`
--     값 — 과거 행이 없어도 제약을 좁히면 되살릴 때 또 넓혀야 한다. 그대로 둔다.
--   · `is_settlement_public()` 함수, `settlement_settings.influencer_visible` 칸 —
--     **의도적으로 안 지운다.** 아래 「지우지 않은 이유」 참고.
--
-- ▶ 지우지 않은 이유 — `is_settlement_public()` / `influencer_visible`
--   서버에서 이 함수를 부르는 곳은 이 마이그레이션 이후 0곳이 된다. 하지만
--   **인플루언서 앱 클라이언트가 지금도 이 함수를 직접 부른다**
--   (`dev/lib/storage.js` `isSettlementPublic()` → `db.rpc('is_settlement_public')`,
--   `dev/js/notifications.js:73,348` · `dev/js/mypage.js:481` 이 그 결과를 캐싱한
--   `settlementPublic()` 으로 메뉴 노출·알림 필터·라우팅을 결정한다). 그 호출부 제거는
--   이 작업과 **별도로**(같은 작업의 클라이언트 쪽에서) 진행된다.
--   함수를 이 마이그레이션에서 먼저 지우면, 데이터베이스 배포가 클라이언트 배포보다
--   먼저 나가는 순간 그 사이 클라이언트가 존재하지 않는 원격 호출 함수(RPC)를 불러
--   `PGRST202`(함수 없음) 오류를 만든다. `isSettlementPublic()` 의 catch 블록이 `false`
--   로 폴백해 화면이 깨지지는 않지만, `client_error_logs` 에 예상 못 한 오류가 쌓인다
--   (오류 로그는 「진짜 이상 신호」를 찾는 도구라 — `.claude/rules/supabase.md`
--   「신규 데이터베이스 함수는 적용 성공이 동작 확인이 아니다」와 같은 정신 —
--   불필요한 노이즈를 쌓지 않는 쪽을 택한다).
--   `influencer_visible` 컬럼도 같은 이유로 남긴다 — 지금 이 칸을 읽는 곳은
--   `is_settlement_public()` 뿐이라, 함수가 남아 있는 한 칸도 함께 남아야 한다.
--   **함수·칸을 함께 지우는 정리는 클라이언트 배포·검증이 끝난 뒤 별도 마이그레이션으로.**
--   (함수는 지금도 `false`만 반환하므로, 남겨 둬도 클라이언트 동작은 이 마이그레이션
--   전후로 한 글자도 달라지지 않는다 — 안전한 선택.)
--
-- ▶ 전수 확인 — 정산 알림을 넣는 다른 자리가 더 있는지
--   `grep -rn "INSERT INTO public.notifications" supabase/migrations/` 로 나온 모든
--   파일을 열어 `settlement_paid`/`settlement_paypal_required` 를 실제로 쓰는 곳만
--   추렸다. `mark_settlement_hold`(223)·`mark_settlement_cancel`(223)·
--   `mark_settlement_revert`(224)·`register_past_settlements`(324, 233 원칙 그대로
--   「알림 둘 다 발행하지 않음」 명시)·`correct_settlement_payment`(341) 는 애초에
--   정산 알림을 넣지 않는다(233 이 세운 원칙 — 일괄·정정 경로는 무알림). 트리거 중에도
--   정산 알림을 넣는 것은 없다(정산은 트리거가 아니라 함수 호출로만 상태가 바뀐다).
--   → 아래 세 함수가 **전부**다.
--
-- ▶ 각 함수의 「베이스 대비 지운 줄」(다음 사람이 눈으로 대조할 수 있도록)
--
--   ① `mark_settlement_paid`      — 베이스 **339**(인자 5개: uuid, integer, text,
--      timestamptz, bigint — 241 의 3인자 판이 아니라 339 가 늘린 5인자 판이 현재
--      유효한 정의다). 지운 것 = UPDATE 문 다음, `settlement_events` INSERT 다음에
--      있던 아래 블록 통째(주석 3줄 + `IF ~ END IF` 5줄, 총 8줄):
--        IF public.is_settlement_public() THEN
--          INSERT INTO public.notifications (...) VALUES (..., 'settlement_paid', ...);
--        END IF;
--      그 앞뒤 — 권한 가드·앞날 날짜 방어·금액 방어·행 잠금·낙관적 락·상태 검증·
--      PayPal 재조회·UPDATE·감사 이력 INSERT — 는 339 와 **한 글자도 다르지 않다.**
--
--   ② `mark_settlements_paid_bulk` — 베이스 **340**(신설 함수, 이 함수의 유일한 정의).
--      지운 것 세 군데:
--        · DECLARE 목록의 `v_public boolean;` 1줄
--        · 반복문 밖 `v_public := public.is_settlement_public();` 대입 줄(설명 주석
--          2줄 포함)
--        · 반복문 안, `settlement_events` INSERT 다음에 있던 아래 블록 통째(주석
--          포함 약 12줄):
--            IF v_public THEN
--              INSERT INTO public.notifications (...) VALUES (..., 'settlement_paid', ...);
--            END IF;
--      그 앞뒤 — 권한 가드·빈 배열 방어·앞날 날짜 방어·행 잠금 반복(`FOR ... ORDER BY`)·
--      상태 확인·PayPal 재조회·UPDATE(메모 덧붙이기 포함)·감사 이력 INSERT·반환 4종
--      집계 — 는 340 과 **한 글자도 다르지 않다.**
--
--   ③ `backfill_settlements`      — 베이스 **324**(0·H-5 cert_at 저장까지 반영된
--      가장 최신 정의 — 262·300 은 324 가 이미 계승했다). 지운 것 세 군데:
--        · DECLARE 목록의 `v_notify boolean;` 1줄(+ 설명 주석)
--        · `v_notify := public.is_settlement_public();` 대입 줄(+ 설명 주석 2줄,
--          「⚠️ 절대 제거 금지」 로 적혀 있던 그 줄 — 이번이 그 예외다)
--        · WITH 체인의 `notif_candidates AS (...)` CTE 통째(주석 8줄 포함)
--        · WITH 체인의 `notif_ins AS (...)` CTE 통째(주석 10줄 포함)
--        → CTE 체인은 `cert AS (...), inserted AS (...), events_ins AS (...)` 로
--          끝나고 그 뒤에 바로 최종 `SELECT ... INTO v_created, v_paypal_missing` 가
--          붙는다(콤마 정리).
--      그 앞뒤 — 권한 가드·컷오프 조회·`_settlement_cert_candidates()` 호출·저장 대상
--      필터(H-5 cert_at 포함)·`ON CONFLICT DO NOTHING`·`events_ins` 감사 이력·
--      `paypal_missing_count` 집계 — 는 324 와 **한 글자도 다르지 않다.**
--
-- ⚠️ 세 함수 모두 인자·반환 타입 무변경 → `CREATE OR REPLACE FUNCTION` 으로 끝난다.
--    `DROP FUNCTION` 이 필요했다면 그 자체가 서명이 달라졌다는 신호였을 것이다.
--
-- 번호 안내 — 다음은 344.
-- ============================================================

BEGIN;

-- ── ① mark_settlement_paid — 알림 구간만 제거 (베이스 339) ──────────────
CREATE OR REPLACE FUNCTION public.mark_settlement_paid(
  p_settlement_id   uuid,
  p_version         integer,
  p_memo            text,
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

  -- 앞날 날짜 방어. 송금은 앞날에 일어날 수 없다(339 그대로).
  IF p_paid_at IS NOT NULL AND p_paid_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'paid_at_in_future: 송금일이 앞날입니다 (입력값: %)', p_paid_at
      USING ERRCODE = '22023';
  END IF;

  -- 금액 방어. 음수·0 은 허용하지 않는다(339 그대로).
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
         paid_at      = COALESCE(p_paid_at, now()),
         paid_amount_jpy = p_paid_amount_jpy,
         paid_by      = auth.uid(),
         paypal_email = v_paypal_fresh,
         memo         = p_memo,
         version      = version + 1
   WHERE id = p_settlement_id;

  -- ── settlement_events 감사 이력 ─────────────────────────────
  -- 인플루언서 노출·알림과 무관하게 항상 남는다 — 금전 감사는 그대로 유지.
  INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
  VALUES (p_settlement_id, 'pay', 'pending', 'paid', auth.uid(), p_memo);

  -- [343] 인플루언서 알림(settlement_paid) INSERT 구간을 여기서 제거했다.
  --   241 이 만들고 339 가 문구만 정정했던 `IF public.is_settlement_public() THEN
  --   INSERT INTO public.notifications ... END IF` 블록이 있던 자리다.
  --   settlement_events 감사 이력은 위에서 그대로 남는다.

  SELECT version INTO v_new_version FROM public.settlements WHERE id = p_settlement_id;
  RETURN v_new_version;
END;
$$;

COMMENT ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) IS
  '정산 단건을 송금완료로. [343] 인플루언서 알림(settlement_paid) 발행을 제거 — '
  '사용자 결정(2026-08-19)으로 정산 인플루언서 노출·알림 경로를 아예 없앤다. '
  'settlement_events 감사 이력은 그대로. 339 의 실제 보낸 날짜(p_paid_at)·금액(p_paid_amount_jpy) '
  '인자·방어 로직은 무변경.';

REVOKE ALL ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlement_paid(uuid, integer, text, timestamptz, bigint) TO authenticated;

-- ── ② mark_settlements_paid_bulk — 알림 구간만 제거 (베이스 340) ─────────
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
       SET status       = 'paid',
           paid_at      = v_paid_at,
           paid_by      = auth.uid(),
           paypal_email = v_paypal_fresh,
           -- 메모는 덮어쓰지 않고 덧붙인다(340 그대로).
           memo         = CASE
                            WHEN NULLIF(btrim(s.memo), '') IS NULL THEN v_memo
                            ELSE s.memo || E'\n' || v_memo
                          END,
           version      = s.version + 1
     WHERE s.id = v_id;

    -- ── 금전 감사 이력: 항상 남는다 ──────────────────────────────
    INSERT INTO public.settlement_events
      (settlement_id, action, prev_status, next_status, actor, memo)
    VALUES (v_id, 'pay', 'pending', 'paid', auth.uid(), v_memo);

    -- [343] 인플루언서 알림(settlement_paid) INSERT 구간을 여기서 제거했다.
    --   340 이 신설하면서 명시적으로 넣었던 `IF v_public THEN INSERT INTO
    --   public.notifications ... END IF` 블록과, 그 판정을 반복문 밖에서 한 번만
    --   읽던 `v_public boolean` 변수·대입문이 있던 자리다. settlement_events
    --   감사 이력은 위에서 그대로 남는다.

    v_paid := v_paid + 1;
  END LOOP;

  RETURN QUERY SELECT v_paid, v_skip_paypal, v_skip_status, v_missing;
END;
$$;

COMMENT ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) IS
  '정산대기 여러 건을 한 번에 송금완료로. [343] 인플루언서 알림(settlement_paid) 발행을 '
  '제거 — 사용자 결정(2026-08-19)으로 정산 인플루언서 노출·알림 경로를 아예 없앤다. '
  '실패는 통째로 되돌리지 않고 건너뛰며 사유별 건수를 돌려준다(페이팔 미등록 / '
  '이미 처리됨·보류·취소 / 사라진 행). settlement_events 는 항상 기록. '
  'paid_amount_jpy 는 건드리지 않는다(correct_settlement_payment 로 개별 정정). '
  '메모는 덮어쓰지 않고 덧붙인다.';

REVOKE ALL ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.mark_settlements_paid_bulk(uuid[], timestamptz, text) TO authenticated;

-- ── ③ backfill_settlements — 알림 구간만 제거 (베이스 324) ──────────────
CREATE OR REPLACE FUNCTION public.backfill_settlements()
RETURNS TABLE(created_count integer, paypal_missing_count integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_created         integer := 0;
  v_paypal_missing  integer := 0;
  v_cutoff          timestamptz;
BEGIN
  -- ── 권한 게이트: settlement.view 최소 read (324 와 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  WITH cert AS (
    SELECT * FROM public._settlement_cert_candidates()
  ),
  inserted AS (
    -- cert_at 컬럼(324, H-5) — 인증 성공 시점을 정산 생성 시점에 함께 저장한다.
    INSERT INTO public.settlements (
      influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
      receipt_amount_jpy, amount_cap_jpy, cert_at, paypal_email
    )
    SELECT influencer_id, application_id, campaign_id, amount_jpy, amount_source, reward_part_jpy,
           receipt_amount_jpy, amount_cap_jpy, cert_at,
           NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외
      AND amount_issue IS NULL         -- 금액 미확정 건은 CHECK(amount_jpy>0) 위반으로 배치 전체가
                                        -- 실패하는 것을 막기 위해 저장 대상에서 제외
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  )
  SELECT
    (SELECT count(*)::integer FROM inserted),
    (SELECT count(*)::integer FROM inserted WHERE paypal_email IS NULL)
  INTO v_created, v_paypal_missing;

  RETURN QUERY SELECT v_created, v_paypal_missing;
END;
$$;

COMMENT ON FUNCTION public.backfill_settlements() IS
  '[343 재정의, 324 원본 대체] 인플루언서 알림(settlement_paypal_required) 발행을 제거 — '
  '사용자 결정(2026-08-19)으로 정산 인플루언서 노출·알림 경로를 아예 없앤다. '
  'paypal_missing_count 집계는 그대로 남는다(관리자 화면이 사용). '
  '금액을 _settlement_cert_candidates() 헬퍼가 계산한 값으로 저장, cert_at(인증 성공 시점, 324) '
  '도 함께 저장. amount_issue 가 있는 건은 저장 대상에서 제외해 CHECK(amount_jpy>0) 위반으로 '
  '배치 전체가 실패하는 것을 방지. 컷오프·이력 기록은 324 그대로(변경 없음).';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

-- ── ④ 인플루언서 본인 조회 정책 삭제 (240 이 만든 것) ──────────────────
-- settlements_select_admin(관리자, has_permission 기반)은 이 마이그레이션이
-- 건드리지 않는다 — 관리자 조회는 무변경.
DROP POLICY IF EXISTS settlements_select_own ON public.settlements;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 성공」은 「동작 확인」이 아니다 — 실제로 한 번 부른다)
-- 개발 DB 적용 후 SQL Editor 에서 1단계씩 실행 — 결과 확인 후 다음 단계로.
-- ============================================================
/*

-- [V0] 세 함수에 알림 INSERT 가 더 이상 없나 (기대: 모두 0)
SELECT p.proname,
       pg_get_functiondef(p.oid) LIKE '%settlement_paid%'             AS has_paid_kind,
       pg_get_functiondef(p.oid) LIKE '%settlement_paypal_required%'  AS has_paypal_kind
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('mark_settlement_paid','mark_settlements_paid_bulk','backfill_settlements')
 ORDER BY p.proname;
-- 기대: 세 행 모두 has_paid_kind=false, has_paypal_kind=false

-- [V1] settlement_events 감사 이력 INSERT 는 그대로 있나 (기대: 모두 1)
SELECT p.proname, count(*) FILTER (
         WHERE pg_get_functiondef(p.oid) LIKE '%INSERT INTO public.settlement_events%'
       ) AS has_audit_insert
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('mark_settlement_paid','mark_settlements_paid_bulk','backfill_settlements')
 GROUP BY p.proname;

-- [V2] backfill_settlements 의 paypal_missing_count 집계는 살아있나 (기대: 1)
SELECT count(*) FROM pg_proc
 WHERE proname='backfill_settlements'
   AND pg_get_functiondef(oid) LIKE '%v_paypal_missing%';

-- [V3] 정책이 실제로 사라졌나 (기대: 0행)
SELECT policyname, cmd, qual
  FROM pg_policies
 WHERE tablename='settlements' AND policyname='settlements_select_own';

-- [V4] 관리자 조회 정책은 무변경인가 (기대: 1행, 217 원본과 동일)
SELECT policyname, cmd, qual
  FROM pg_policies
 WHERE tablename='settlements' AND policyname='settlements_select_admin';

-- [V5] ★ 실제로 한 번 부른다 — 함수를 만드는 구문은 본문 자료형을 검사하지 않아
--     적용은 성공하고 첫 호출에서 터질 수 있다(2026-08-18 마이그레이션 335, 42804 선례).
--   ⚠️ 세 함수 모두 has_permission 가드가 있어 SQL 편집기(서비스 키)로는 재현되지
--      않는다(42501) — **관리자로 로그인한 브라우저 콘솔**에서:
--
--     // ㄱ) 없는 id — 기대: "정산 내역을 찾을 수 없습니다" 오류(02000). 알림 0건이어야 함.
--     await db.rpc('mark_settlement_paid',
--       { p_settlement_id:'00000000-0000-0000-0000-000000000000', p_version:1, p_memo:'시험' })
--
--     // ㄴ) 없는 id 배열 — 기대: paid_count:0, not_found_count:1. 알림 0건이어야 함.
--     await db.rpc('mark_settlements_paid_bulk',
--       { p_settlement_ids:['00000000-0000-0000-0000-000000000000'], p_memo:'시험' })
--
--     // ㄷ) 운영 실측 기준 cutoff_at=null 이라 안전 — 실제로 불러도 created_count:0 이어야 함.
--     //     (정산 화면을 열 때마다 이미 호출되는 함수라 새 위험이 아니다)
--     await db.rpc('backfill_settlements')
--
--   위 세 호출 뒤 아래로 알림이 0건인지 다시 확인한다(호출 전후 건수 비교):
--   SELECT count(*) FROM public.notifications
--    WHERE kind IN ('settlement_paid','settlement_paypal_required')
--      AND created_at > now() - interval '10 minutes';

-- [V6] 인플루언서 본인 계정으로 로그인해 settlements 를 조회하면 0행인가
--   (이전에도 influencer_visible=false 라 0행이었다 — 정책을 지운 뒤에도 결과는
--   동일해야 한다. 클라이언트 콘솔에서: await db.from('settlements').select('*'))

*/

-- ============================================================
-- 롤백
-- ============================================================
/*

-- ① settlements_select_own 정책 되살리기 (240 정의 그대로, 스위치 조건 포함)
CREATE POLICY settlements_select_own ON public.settlements
  FOR SELECT TO authenticated
  USING (influencer_id = auth.uid() AND public.is_settlement_public());

-- ② 세 함수의 알림 INSERT 되살리기 — 아래 파일의 CREATE OR REPLACE 블록을 그대로 재실행
--   · mark_settlement_paid       → supabase/migrations/339_settlement_actual_payment_args.sql
--   · mark_settlements_paid_bulk → supabase/migrations/340_mark_settlements_paid_bulk.sql
--   · backfill_settlements       → supabase/migrations/324_settlement_audit_fixes_h1_h3_h4_h5_h8.sql
--     (해당 파일의 backfill_settlements 정의 구간만)

NOTIFY pgrst, 'reload schema';

*/
