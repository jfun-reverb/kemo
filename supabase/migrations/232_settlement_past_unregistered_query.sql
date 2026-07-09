-- ============================================================
-- 232_settlement_past_unregistered_query.sql
-- 정산 과거분 컷오프 PR2 — 1/2 (공통 판정 헬퍼 + 과거 미등록 조회 RPC)
-- 사양서: docs/specs/2026-07-09-settlement-cutoff-past-handling.md §「설계」②「확정 설계 결정」③④⑦
--
-- ── 이 마이그레이션이 하는 일 ──
--   1) 인증 성공 판정(computeCertStatus 서버 재현) 로직을 private 헬퍼 함수
--      `public._settlement_cert_candidates()` 로 추출한다.
--      마이그레이션 231(backfill_settlements)에 인라인으로 작성돼 있던 5개 CTE
--      (candidates/receipt_latest/post_latest/review_channel_latest/channel_cert/cert)를
--      그대로 옮긴 것 — 판정 조건 자체는 단 한 글자도 바꾸지 않았다.
--   2) `public.backfill_settlements()` 를 CREATE OR REPLACE 로 이 헬퍼를 호출하도록
--      리팩터링한다(시그니처·반환 타입·게이트·컷오프 조건·이력/알림 INSERT 는 231과
--      100% 동일 — 오직 "cert 판정 CTE 계산" 부분만 헬퍼 호출로 대체).
--   3) 신규 조회 RPC `public.get_past_unregistered_settlements()` — 같은 헬퍼를 호출해
--      "인증 성공했지만 아직 settlements 행이 없는" 응모 목록을 반환한다(PR2 화면용).
--
-- ── 왜 이렇게 하나(사양서 지시 — "232·233 판정이 231과 정확히 동일해야 함") ──
--   마이그레이션 파일은 영구 보관·수정 금지(.claude/rules/supabase.md)이므로 231 파일
--   자체는 건드리지 않는다. 대신 231이 정의한 함수(public.backfill_settlements)를
--   이 마이그레이션에서 CREATE OR REPLACE 로 "재정의"해 헬퍼에 위임한다 — 이미 이
--   프로젝트에 선례가 있는 패턴이다(예: 마이그레이션 210 이 이전 마이그레이션이 만든
--   is_campaign_admin() 을 CREATE OR REPLACE 로 다시 고침).
--   이렇게 하면 이 마이그레이션이 적용된 "이후" 시점부터는:
--     - 자동 백필(backfill_settlements, 지금부터는 헬퍼 위임 버전)
--     - 과거 미등록 조회(get_past_unregistered_settlements, 이 파일)
--     - 과거 건 수동 처리(register_past_settlements, 마이그레이션 233)
--   세 곳이 전부 물리적으로 동일한 SQL 코드(헬퍼 함수 1개)를 실행한다 — "복붙 동기화"가
--   아니라 "함수 재사용"이므로 향후 판정 로직이 바뀌어도 헬퍼 하나만 고치면 3곳 모두
--   같이 바뀐다(드리프트 원천 차단). 231 파일 자체의 텍스트(과거 기록)는 그대로 두되,
--   "지금 실제로 실행되는 backfill_settlements() 함수 본문"은 이 마이그레이션이 다시
--   정의한 버전이 된다(PostgreSQL 함수는 이름으로 참조되고 최신 CREATE OR REPLACE 가
--   유효 — 이는 231/222/223 등 기존 함수들도 전부 동일하게 따르는 표준 동작이다).
--
-- ── 헬퍼를 private 로 두는 이유(직접 RPC 호출 차단) ──
--   `_settlement_cert_candidates()` 는 응모별 인플루언서 id·PayPal 원본 이메일·금액을
--   그대로 반환하므로, anon/authenticated 가 REST 경유로 직접 호출 가능하면 권한 게이트
--   (has_permission) 없이 개인정보가 새 나간다. 따라서:
--     - REVOKE ALL ... FROM PUBLIC 만 실행하고 authenticated 에 GRANT 하지 않는다.
--     - PostgreSQL 표준 동작상 "REVOKE ALL FROM PUBLIC" 은 PUBLIC 의 기본 실행 권한만
--       제거할 뿐 함수 소유자(owner) 고유의 실행 권한은 없어지지 않는다(오브젝트
--       소유자는 자신이 만든 오브젝트에 항상 접근 가능 — GRANT/REVOKE 로 뺏을 수
--       없는 고유 권리). 이 마이그레이션에서 만드는 다른 SECURITY DEFINER 함수들
--       (backfill_settlements/get_past_unregistered_settlements, 그리고 마이그레이션
--       233의 register_past_settlements)은 전부 같은 소유자(마이그레이션 실행 role)가
--       소유하므로, SECURITY DEFINER 실행 중 current_user 가 그 소유자로 전환돼
--       헬퍼를 문제없이 호출할 수 있다. 반면 브라우저에서 PostgREST 로
--       `/rest/v1/rpc/_settlement_cert_candidates` 를 직접 호출하면 호출자 역할
--       (authenticated/anon)에 EXECUTE 권한이 없어 42501 로 차단된다.
--     - 즉 권한 게이트는 "래퍼(get_past_unregistered_settlements 등)의 has_permission
--       체크" + "헬퍼 자체가 애초에 외부에 노출 안 됨" 이중 방어다.
--
-- ── get_past_unregistered_settlements() 컬럼·필터(사양서 §설계②) ──
--   "과거 미등록" = is_success=true(헬퍼가 이미 "NOT EXISTS settlements"만 대상) AND
--   **명시적 컷오프 필터**: cert_at < cutoff_at(컷오프 이전 인증성공) OR cert_at NULL
--   (레거시 reviewed_at 누락 — 판정시각 불명) OR cutoff_at NULL(미설정 — 세팅 전엔 전부
--   수동 대상). backfill_settlements 의 "cert_at >= cutoff_at" 와 정확히 상보다.
--   ⚠️ 초기 설계는 "candidates 가 NOT EXISTS settlements 라 컷오프 이후분은 backfill 이
--   이미 넣어 자연 제외" 라는 호출 순서 가정에 의존했으나, backfill 미호출 상태에서
--   컷오프 이후 신규 건이 이 목록에 섞이면 수동 처리(무알림) 시 알림이 영구 스킵되는
--   사고가 있어(reviewer 지적 2026-07-09) 함수에 컷오프 조건을 명시적으로 넣었다.
--   민감정보: influencers.paypal_email 원본 문자열은 반환하지 않고 존재 여부
--   불리언 has_paypal 만 반환한다(마이그레이션 212 influencers_admin_view 의
--   has_phone/has_line/has_paypal 컨벤션과 동일). 인플 표시는 name_kanji/name_kana만
--   (가림막 뷰가 아닌 원본 influencers 직접 조회 — SECURITY DEFINER 함수라 RLS 우회는
--   맞지만, has_permission 게이트가 이미 열람 자격을 검증했으므로 명칭 2종만 노출하는
--   것은 마스킹 대상 6종[phone/line_id/paypal_email/zip/building/address]에 해당하지
--   않아 무방 — has_paypal 로 대체한 paypal_email 자체는 여기서도 노출하지 않는다).
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. 공통 판정 헬퍼 (private — PUBLIC/authenticated 직접 실행 불가)
-- ============================================================
CREATE OR REPLACE FUNCTION public._settlement_cert_candidates()
RETURNS TABLE (
  application_id      uuid,
  influencer_id       uuid,
  campaign_id         uuid,
  campaign_title      text,
  reward              bigint,
  recruit_type        text,
  paypal_email        text,
  influencer_name     text,
  influencer_name_kana text,
  is_success          boolean,
  cert_at             timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 리워드>0 + 감사용 제외 + 아직 정산행 없음(멱등).
    -- 마이그레이션 231의 candidates CTE 와 조건 100% 동일(그대로 이관).
    SELECT
      a.id                                AS application_id,
      a.user_id                           AS influencer_id,
      a.campaign_id                       AS campaign_id,
      c.title                             AS campaign_title,
      c.reward                            AS reward,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase,
      inf.paypal_email                    AS paypal_email,
      inf.name_kanji                      AS influencer_name,
      inf.name_kana                       AS influencer_name_kana
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.status = 'approved'
      AND c.reward > 0
      AND inf.is_audit = false
      AND NOT EXISTS (
        SELECT 1 FROM public.settlements s WHERE s.application_id = a.id
      )
  ),
  receipt_latest AS (
    -- 231 과 동일: 응모별 영수증(receipt) 최신 1건 상태+승인시각
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 231 과 동일: 응모별 게시물(post) 최신 1건 상태+승인시각
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 231 과 동일: 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 231 과 동일: 리뷰어(monitor 일반) 응모의 캠페인 채널 전체 인증샷 승인시각 최댓값 +
    -- 완전성 강제(any_null) — 상세 근거는 231 파일 주석 참고(그대로 이관).
    SELECT
      cd.application_id,
      MAX(rcl.reviewed_at)                      AS max_channel_reviewed_at,
      bool_or(rcl.reviewed_at IS NULL)           AS any_null
    FROM candidates cd
    CROSS JOIN LATERAL unnest(string_to_array(cd.channel, ',')) AS ch(name)
    LEFT JOIN review_channel_latest rcl
      ON rcl.application_id = cd.application_id
     AND rcl.post_channel   = btrim(ch.name)
    WHERE cd.recruit_type = 'monitor' AND NOT cd.proxy_purchase
      AND btrim(ch.name) <> ''
    GROUP BY cd.application_id
  )
  SELECT
    cd.application_id,
    cd.influencer_id,
    cd.campaign_id,
    cd.campaign_title,
    cd.reward,
    cd.recruit_type,
    cd.paypal_email,
    cd.influencer_name,
    cd.influencer_name_kana,
    -- ── is_success: 231 cert CTE 의 CASE 문 그대로 이관 ──
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        COALESCE(rl.status = 'approved', false)
      WHEN cd.recruit_type = 'monitor' THEN
        COALESCE(rl.status = 'approved', false)
        AND EXISTS (
          SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          WHERE btrim(ch.name) <> ''
        )
        AND NOT EXISTS (
          SELECT 1
          FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          LEFT JOIN review_channel_latest rcl
            ON rcl.application_id = cd.application_id
           AND rcl.post_channel   = btrim(ch.name)
          WHERE btrim(ch.name) <> ''
            AND COALESCE(rcl.status, 'none') <> 'approved'
        )
      ELSE
        COALESCE(pl.status = 'approved', false)
    END AS is_success,
    -- ── cert_at: 231 cert CTE 의 CASE 문 그대로 이관 ──
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        rl.reviewed_at
      WHEN cd.recruit_type = 'monitor' THEN
        CASE
          WHEN rl.reviewed_at IS NULL OR COALESCE(cc.any_null, true) THEN NULL
          ELSE GREATEST(rl.reviewed_at, cc.max_channel_reviewed_at)
        END
      ELSE
        pl.reviewed_at
    END AS cert_at
  FROM candidates cd
  LEFT JOIN receipt_latest rl  ON rl.application_id = cd.application_id
  LEFT JOIN post_latest    pl  ON pl.application_id = cd.application_id
  LEFT JOIN channel_cert   cc  ON cc.application_id = cd.application_id;
$$;

COMMENT ON FUNCTION public._settlement_cert_candidates() IS
  '[232] private 헬퍼 — 정산 미등록(settlements 행 없음) 응모 전체에 대해 인증 성공 여부'
  '(is_success)·인증 성공일(cert_at, computeCertStatus 서버 재현)을 계산. 마이그레이션 231'
  '의 candidates/cert CTE 를 그대로 이관 — 판정 조건 불변. backfill_settlements()'
  '(231→232 재정의)·get_past_unregistered_settlements()(232)·register_past_settlements()'
  '(233) 3곳이 전부 이 함수 하나를 호출해 판정 로직 드리프트를 원천 차단한다. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 RPC 호출 불가) — 소유자 권한으로 실행되는 '
  'SECURITY DEFINER 함수 내부에서만 호출 가능.';

-- PUBLIC 기본 실행 권한 제거. authenticated 에도 부여하지 않는다(의도적 — 위 주석 참고).
REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

-- ============================================================
-- 2. backfill_settlements() 재정의 — 헬퍼에 위임(231과 동작 동일, cert 계산만 위임)
-- ============================================================
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
  -- ── 권한 게이트: settlement.view 최소 read (231 과 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  WITH cert AS (
    -- 231 에 인라인으로 있던 5개 CTE 전체를 헬퍼 호출 1줄로 대체(판정 조건 불변).
    SELECT * FROM public._settlement_cert_candidates()
  ),
  inserted AS (
    INSERT INTO public.settlements (influencer_id, application_id, campaign_id, amount_jpy, paypal_email)
    SELECT influencer_id, application_id, campaign_id, reward, NULLIF(paypal_email, '')
    FROM cert
    WHERE is_success
      AND cert_at IS NOT NULL          -- reviewed_at 누락(레거시) → 판정 시각 불명, 자동 대상 제외(PR2로 이관)
      AND v_cutoff IS NOT NULL         -- 컷오프 미설정 → 자동 백필 전체 차단(안전측)
      AND cert_at >= v_cutoff          -- 컷오프 이전 인증 성공 → 과거분, 자동 대상 제외(PR2 수동 처리)
    ON CONFLICT (application_id) DO NOTHING
    RETURNING id, application_id, influencer_id, paypal_email
  ),
  events_ins AS (
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_ins AS (
    INSERT INTO public.notifications (user_id, kind, ref_table, ref_id, title, body)
    SELECT i.influencer_id, 'settlement_paypal_required', 'settlements', i.id,
           'PayPalメールアドレス未登録のお知らせ',
           '報酬のお振込みにはPayPalメールアドレスの登録が必要です。マイページから登録をお願いします。'
    FROM inserted i
    WHERE i.paypal_email IS NULL
      AND NOT EXISTS (
        SELECT 1 FROM public.notifications x
        WHERE x.user_id = i.influencer_id
          AND x.kind    = 'settlement_paypal_required'
          AND x.read_at IS NULL
      )
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
  '[232 재정의, 231 원본 대체] 인증 성공 판정을 _settlement_cert_candidates() 헬퍼에 위임'
  '(조건 자체는 231과 동일 — "cert_at >= settlement_settings.cutoff_at" 인 것만 생성). '
  '컬럼·게이트·이력/알림 INSERT 는 231 그대로. 이 마이그레이션 이후 실제 실행되는 '
  '함수 본문은 이 버전이다(PostgreSQL 함수는 최신 CREATE OR REPLACE 가 유효).';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

-- ============================================================
-- 3. 과거 미등록 인증성공 조회 RPC
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_past_unregistered_settlements()
RETURNS TABLE (
  application_id       uuid,
  influencer_id        uuid,
  influencer_name       text,
  influencer_name_kana  text,
  has_paypal            boolean,
  campaign_id           uuid,
  campaign_title        text,
  recruit_type          text,
  amount_jpy            bigint,
  cert_at               timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cutoff timestamptz;
BEGIN
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  SELECT cutoff_at INTO v_cutoff FROM public.settlement_settings WHERE id = 1;

  RETURN QUERY
  SELECT
    c.application_id,
    c.influencer_id,
    c.influencer_name,
    c.influencer_name_kana,
    (c.paypal_email IS NOT NULL AND btrim(c.paypal_email) <> '') AS has_paypal,
    c.campaign_id,
    c.campaign_title,
    c.recruit_type,
    c.reward AS amount_jpy,
    c.cert_at
  FROM public._settlement_cert_candidates() c
  WHERE c.is_success
    -- ── 명시적 컷오프 필터(호출 순서 비의존, reviewer 지적 2026-07-09) ──
    -- "과거분" = 컷오프 이전 인증성공(cert_at < v_cutoff) 또는 판정시각 불명 레거시
    -- (cert_at NULL) 또는 컷오프 미설정(v_cutoff NULL — 세팅 전엔 전부 수동 대상).
    -- 컷오프 이후 신규 인증성공(자동 백필 대상)이 backfill 미호출 상태에서 이 목록에
    -- 섞여 수동 처리(무알림)되면 원래 갈 settlement_paypal_required 알림이 영구
    -- 스킵되는 사고를 차단한다(backfill_settlements 의 cert_at >= v_cutoff 와 정확히 상보).
    AND (v_cutoff IS NULL OR c.cert_at IS NULL OR c.cert_at < v_cutoff);
END;
$$;

COMMENT ON FUNCTION public.get_past_unregistered_settlements() IS
  '[232] 과거 미등록 인증성공 응모 목록(정산 페인 「과거 미등록」 UI, PR2). '
  '_settlement_cert_candidates() 의 is_success=true AND 명시적 컷오프 필터(cert_at < '
  'cutoff_at OR cert_at NULL OR cutoff_at NULL) — backfill_settlements 의 "cert_at >= '
  'cutoff_at" 와 상보. 호출 순서 비의존(컷오프 이후 신규건이 섞여 무알림 처리되는 사고 차단). '
  'PayPal 원본 이메일 대신 has_paypal 불리언만 반환(마이그레이션 212 컨벤션). '
  'has_permission(''settlement.view'',''read'') 게이트.';

REVOKE ALL ON FUNCTION public.get_past_unregistered_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_past_unregistered_settlements() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 230·231 까지 적용된 뒤에 실행할 것.
-- ============================================================
/*

-- [V0] 함수 3개 생성 확인 (반환 타입 포함)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name IN (
    '_settlement_cert_candidates',
    'backfill_settlements',
    'get_past_unregistered_settlements'
  );

-- [V1] 헬퍼가 PUBLIC 에 노출 안 됐는지 확인 (authenticated 행이 없어야 함)
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만 — authenticated/anon/PUBLIC 없어야 함)

-- [V2] backfill_settlements() 이 여전히 컷오프를 지키는지 회귀 확인
--   (231 검증 [V1]~[V3] 재현 — cutoff NULL 이면 created_count=0)
SELECT cutoff_at FROM public.settlement_settings;
SELECT * FROM public.backfill_settlements();

-- [V3] get_past_unregistered_settlements() 스모크 호출
--   (SQL Editor 직접 실행은 auth.uid() 가 NULL 이라 permission_denied 로 막힐 수 있음 —
--    정상 동작. 앱에서 campaign_admin 로그인 세션으로 확인)
-- SELECT * FROM public.get_past_unregistered_settlements() ORDER BY cert_at NULLS FIRST;

-- [V4] 과거분 존재 확인용 참고 쿼리 — cutoff 이전 인증 성공(레거시 cert_at NULL 포함)이
--   몇 건인지 대략 파악(개발 DB 실측용, 함수 호출 대신 헬퍼 직접 조회는 owner 권한
--   SQL Editor 세션이면 가능 — postgres role 로 실행 시):
-- SELECT count(*) FROM public._settlement_cert_candidates() WHERE is_success;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 방법 A) 이 마이그레이션이 새로 만든 것만 되돌리려면:
--   DROP FUNCTION IF EXISTS public.get_past_unregistered_settlements();
--   -- backfill_settlements() 를 231 원본(헬퍼 미사용, 인라인 CTE)으로 되돌리려면
--   -- 231_backfill_settlements_cutoff.sql 의 CREATE OR REPLACE 블록을 그대로 재실행.
--   DROP FUNCTION IF EXISTS public._settlement_cert_candidates();
--   -- (단, 위 DROP 은 backfill_settlements 를 먼저 231 원본으로 되돌린 뒤에 실행할 것 —
--   --  헬퍼가 사라진 채로 232 버전 backfill_settlements 가 남으면 호출 시 에러남)
-- 방법 B) 마이그레이션 233(register_past_settlements)도 이 헬퍼를 사용하므로,
--   233 을 먼저 롤백한 뒤 이 파일을 롤백할 것(역순 롤백 원칙).
