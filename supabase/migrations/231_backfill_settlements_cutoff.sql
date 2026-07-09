-- ============================================================
-- 231_backfill_settlements_cutoff.sql
-- 정산 과거분 컷오프 PR1 — 2/2 (backfill_settlements 컷오프 조건 추가)
-- 사양서: docs/specs/2026-07-09-settlement-cutoff-past-handling.md §「설계」①
--
-- CREATE OR REPLACE FUNCTION public.backfill_settlements() — 시그니처·반환 타입·권한
-- 게이트·이력/알림 INSERT 는 마이그레이션 218 그대로 유지한다. 이 마이그레이션은
-- "인증 성공 판정" 뒤에 "인증 성공일(cert_at) >= settlement_settings.cutoff_at" 조건
-- 하나만 추가한다 — 호출부(dev/js/admin-settlements.js backfillSettlements())는 무변경.
--
-- ── 인증 성공일(cert_at) 계산 근거 ──
-- "인증 성공"에 필요한 마지막 결과물이 승인(approved)된 시각(deliverables.reviewed_at)을
-- 그 응모의 인증 성공일로 정의한다(사양서 §의심 1 — 클라 시각 신뢰 금지, 서버 판정).
-- 218 의 3개 CTE(receipt_latest/post_latest/review_channel_latest)에 reviewed_at 컬럼을
-- 추가하고, cert CTE에서 판정 종류별로 아래처럼 계산한다:
--
--   - 가구매(monitor + proxy_purchase=true): 영수증 하나만 승인되면 성공
--       → cert_at = receipt_latest.reviewed_at
--   - 리뷰어(monitor 일반): 영수증 + 캠페인 채널 "전부"의 인증샷이 모두 승인돼야 성공
--       → cert_at = (영수증 reviewed_at, 채널별 인증샷 reviewed_at) 전부가 존재할 때만
--         그 중 최댓값(GREATEST) — 하나라도 비어있으면(아래 NULL 처리) cert_at 자체가 NULL
--         (전부 승인이어야 하므로, 가장 늦게 승인된 시각이 실제 "성공이 확정된 시점")
--   - 시딩·방문(gifting/visit): 게시물 하나만 승인되면 성공
--       → cert_at = post_latest.reviewed_at
--
-- 신규 CTE `channel_cert`가 캠페인 채널(콤마 분리) 전체에 걸친 review_channel_latest
-- reviewed_at 의 MAX() 와, "그 중 하나라도 reviewed_at 이 비어있는지(any_null)"를 응모
-- 단위로 미리 집계한다(cert CTE 안에서 직접 서브쿼리를 쓰면 상관 서브쿼리가 되어
-- 가독성이 떨어지므로 분리).
--
-- ── cutoff_at IS NULL 처리(사양서 §확정 설계 결정 ②, 매우 중요) ──
-- 함수 시작 시 settlement_settings.cutoff_at 을 v_cutoff 변수로 1회 조회한다.
-- v_cutoff IS NULL 이면 최종 INSERT WHERE 절의 `v_cutoff IS NOT NULL AND cert_at >= v_cutoff`
-- 가 항상 FALSE 가 되어 **자동 생성 0건**으로 동작한다(마이그레이션 230 설계 그대로 —
-- 값을 세팅하지 않은 채 배포돼도 폭주하지 않는 안전측 기본값).
--
-- ── reviewed_at IS NULL 처리(사양서 「⚠️ reviewed_at 이 NULL 인 승인 결과물」, 매우 중요) ──
-- 아주 오래된 데이터 등으로 승인(approved) 상태인데 reviewed_at 이 비어있는 행이
-- 있을 수 있다. PostgreSQL의 GREATEST()는 기본적으로 NULL 을 무시하고 나머지 값 중
-- 최댓값을 반환하므로(완전 NULL이 되려면 "모든" 인자가 NULL 이어야 함), 그대로 두면
-- 채널 중 하나만 reviewed_at 이 비어 있어도 "나머지 값으로 대체된 cert_at"이 나와
-- 컷오프 판정이 실제보다 이르게(또는 늦게) 왜곡될 수 있다. 이를 막기 위해 **의도적으로
-- 완전성(completeness)을 강제**한다: 리뷰어 케이스에서 영수증 reviewed_at 또는 채널들
-- 중 하나라도 NULL 이면(cc.any_null) cert_at 을 곧바로 NULL 로 만든다(GREATEST의
-- null-무시 동작을 CASE 로 우회 차단). cert_at 이 끝내 NULL 이면 최종 WHERE 의
-- `cert_at IS NOT NULL` 조건에 걸려 **자동 생성 대상에서 제외**된다 — "판정 시각을
-- 정확히 모르면 과거로 간주해 자동 처리하지 않고 PR2 수동 처리로 넘긴다"는 안전측
-- 정책을 그대로 구현한다. 가구매·시딩/방문 케이스는 단일 값이라 reviewed_at 이
-- NULL 이면 cert_at 도 자동으로 NULL(추가 처리 불필요).
--
-- 역방향(인증 깨짐→on_hold)·과거 미등록 조회/수동 처리 RPC 는 여전히 이 마이그레이션
-- 범위 밖(PR2, 사양서 §PR 분할).
--
-- 롤백: 파일 하단 참고. 롤백 시 218 원본을 그대로 CREATE OR REPLACE 하면 컷오프
-- 조건 없는 원래 동작으로 복귀한다(218 파일 참고).
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
  -- ── 권한 게이트: settlement.view 최소 read (218 과 동일) ──
  IF NOT public.has_permission('settlement.view', 'read') THEN
    RAISE EXCEPTION 'permission_denied: settlement.view 권한이 없습니다'
      USING ERRCODE = '42501';
  END IF;

  -- ── 정산 도입일(컷오프) 조회. 행이 없으면(이론상 없어야 함) NULL → 전체 차단 ──
  SELECT cutoff_at INTO v_cutoff
  FROM public.settlement_settings
  WHERE id = 1;

  -- 신규 생성분(inserted)을 뒤 이력·알림 INSERT CTE(events_ins/notif_ins)가 재참조한다.
  -- 데이터 변경 CTE는 최종 쿼리가 그 결과를 읽지 않아도 "부수효과용"으로 항상 완전히
  -- 실행된다(218 과 동일 근거 — PostgreSQL 공식 문서 WITH Queries 절).
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 리워드>0 + 감사용 제외 + 아직 정산행 없음(멱등)
    SELECT
      a.id                                AS application_id,
      a.user_id                           AS influencer_id,
      a.campaign_id                       AS campaign_id,
      c.reward                            AS reward,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase,
      inf.paypal_email                    AS paypal_email
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
    -- 응모별 영수증(receipt) 최신 1건 상태+승인시각 (computeCertStatus: g.receipt = 최신 제출)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- 응모별 게시물(post) 최신 1건 상태+승인시각 (gifting/visit — g.result = 최신 제출, 채널 무관)
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 응모×채널별 인증샷(review_image) 최신 1건 상태+승인시각 (monitor 채널별 g.reviewByChannel)
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 리뷰어(monitor 일반) 응모에 한해, 캠페인 채널(콤마 분리) 전체의 인증샷 승인시각
    -- 최댓값 + "그 중 하나라도 reviewed_at 이 비어있는지(any_null)"를 응모 단위로 집계.
    -- any_null 은 cert CTE 에서 GREATEST 의 null-무시 동작을 우회해 완전성을 강제하는 데 쓴다
    -- (전부 승인이어야 성공이므로, 가장 늦은 승인시각이 "그 응모가 실제로 인증 성공 확정된 시점" —
    -- 단, 값이 하나라도 비어있으면 그 시점을 정확히 알 수 없으므로 신뢰하지 않는다).
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
  ),
  cert AS (
    SELECT
      cd.application_id,
      cd.influencer_id,
      cd.campaign_id,
      cd.reward,
      cd.paypal_email,
      CASE
        -- 가구매: 영수증 승인만 확인 (리뷰 인증샷 미요구)
        WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
          COALESCE(rl.status = 'approved', false)

        -- 리뷰어 일반: 영수증 승인 AND 캠페인 채널 전부 인증샷 승인
        WHEN cd.recruit_type = 'monitor' THEN
          COALESCE(rl.status = 'approved', false)
          AND EXISTS (
            -- 채널이 최소 1개는 있어야 함(0개면 클라 로직상 절대 'approved' repr 가 안 됨)
            SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
            WHERE btrim(ch.name) <> ''
          )
          AND NOT EXISTS (
            -- 채널 중 하나라도 승인 아님(미제출/검수중/반려)이면 실패
            SELECT 1
            FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
            LEFT JOIN review_channel_latest rcl
              ON rcl.application_id = cd.application_id
             AND rcl.post_channel   = btrim(ch.name)
            WHERE btrim(ch.name) <> ''
              AND COALESCE(rcl.status, 'none') <> 'approved'
          )

        -- 시딩·방문: 게시물 단독 승인
        ELSE
          COALESCE(pl.status = 'approved', false)
      END AS is_success,

      -- ── 인증 성공일(cert_at) — 판정 종류별 마지막 승인 시각 ──
      -- (완전성 강제: 리뷰어 케이스는 영수증·채널 중 하나라도 reviewed_at 이 비어있으면
      --  GREATEST 의 null-무시 동작으로 대체되지 않도록 명시적으로 NULL 처리한다.)
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
    LEFT JOIN channel_cert   cc  ON cc.application_id = cd.application_id
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
    -- 금전 감사 이력: 새로 생성된 정산행마다 action='create' 1행 (218 과 동일).
    INSERT INTO public.settlement_events (settlement_id, action, prev_status, next_status, actor, memo)
    SELECT id, 'create', NULL, 'pending', auth.uid(), 'backfill_settlements 자동 생성'
    FROM inserted
    RETURNING 1
  ),
  notif_ins AS (
    -- PayPal 미등록 안내 알림: 인플루언서당 미읽음 1건만(멱등 — 218 과 동일 dedup 방식).
    -- 컷오프 이전 응모는 애초에 inserted 에 안 들어오므로 이 알림도 과거분에는 발송되지
    -- 않는다(사양서 §확정 설계 결정 ⑤ "과거 처리·과거분은 어떤 알림도 발송 안 함").
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
  '[231] 인증 성공 응모(computeCertStatus==success 서버 재현) 중 '
  '"인증 성공일(cert_at, 마지막 필요 결과물의 reviewed_at) >= settlement_settings.cutoff_at" '
  '인 것만 settlements UPSERT 생성. cutoff_at NULL 이면 자동 생성 0건(안전측). '
  'cert_at 이 NULL(레거시 reviewed_at 누락)이거나 컷오프 이전이면 자동 대상에서 제외 '
  '— 과거 미등록 조회·수동 처리는 PR2(마이그레이션 232+ 예정). '
  '관리자가 정산 화면 진입 시 호출(트리거 아님, B안). has_permission(''settlement.view'',''read'') 게이트. '
  'PayPal 미등록 인플에게 settlement_paypal_required 알림 동시 발행(컷오프 이후 신규 생성분만). '
  '역방향(인증 깨짐→on_hold)은 PR1 범위 밖.';

REVOKE ALL ON FUNCTION public.backfill_settlements() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.backfill_settlements() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ 마이그레이션 230(settlement_settings) 까지 적용된 뒤에 실행할 것.
--   ⚠️ 아래 [V1]·[V2] 전에 cutoff_at 을 의도적으로 세팅/해제하며 대조하는 절차이므로,
--      운영 DB 에서 실행할 땐 검증 후 반드시 최종적으로 원하는 cutoff_at 값으로
--      되돌려 놓을 것(안 그러면 다음 정산 화면 진입 시 의도와 다르게 백필됨).
-- ============================================================
/*

-- [V0] 함수 재정의 확인 (반환 타입 동일한지)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = 'backfill_settlements';

-- [V1] cutoff_at 미설정(NULL) 상태에서 호출 — created_count = 0 이어야 함
SELECT cutoff_at FROM public.settlement_settings;  -- NULL 확인
SELECT * FROM public.backfill_settlements();       -- created_count=0 기대(과거분 존재해도)

-- [V2] cutoff_at 을 과거 임의 시점(예: 서비스 시작일)으로 세팅 후 호출 —
--   컷오프 이전 인증 성공 건까지 전부 잡히는지 확인(회귀 확인용, 실제 운영 값 아님)
-- UPDATE public.settlement_settings SET cutoff_at = '2020-01-01T00:00:00+09:00' WHERE id = 1;
-- SELECT * FROM public.backfill_settlements();

-- [V3] cutoff_at 을 미래(now() 이후)로 세팅 후 호출 — created_count = 0 이어야 함
--   (모든 인증 성공 건이 컷오프 이전으로 취급되는지 확인)
-- UPDATE public.settlement_settings SET cutoff_at = now() + interval '1 day' WHERE id = 1;
-- SELECT * FROM public.backfill_settlements();

-- [V4] 검증 종료 후 원하는 실제 컷오프 값으로 되돌리기 (예: 배포 시각)
-- UPDATE public.settlement_settings SET cutoff_at = now() WHERE id = 1;

-- [V5] 멱등성 확인 — 같은 함수를 다시 호출해도 created_count=0 이어야 함
SELECT * FROM public.backfill_settlements();

*/

-- ============================================================
-- 롤백 (218 원본 동작으로 복귀 — 컷오프 없이 전체 백필)
-- ============================================================
-- 방법 A) 이 함수만 되돌리려면 218_backfill_settlements_fn.sql 의 CREATE OR REPLACE 블록을
--         그대로 다시 실행(컷오프 조건 없는 원본 재적용).
-- 방법 B) 함수 자체를 지우려면:
--   DROP FUNCTION IF EXISTS public.backfill_settlements();
--   (단, 정산 기능 자체가 이 함수에 의존하므로 완전 롤백 시 반드시 218 원본을 다시
--    CREATE 할 것 — 함수를 아예 없앤 채로 두지 말 것)
