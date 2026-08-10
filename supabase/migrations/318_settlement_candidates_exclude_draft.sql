-- ============================================================
-- 318_settlement_candidates_exclude_draft.sql
-- 정산 후보 판정도 "최신 결과물" 고를 때 임시저장(draft)을 제외한다
-- 사양서: docs/specs/2026-08-07-audit-remediation-plan.md 묶음 G, 조각 G-4
-- 조사 근거: docs/research/2026-08-07-codebase-audit-findings.md §5-4
--   (`300:161-179` vs `250:62`·`276:237`·`storage.js:905`)
--
-- ── 무엇이 문제였나 ──
--   public._settlement_cert_candidates() 의 receipt_latest·post_latest·
--   review_channel_latest 세 CTE 는 "그 응모(또는 응모×채널)의 결과물 중 가장 최근에
--   제출된 1건"을 DISTINCT ON (...) ORDER BY submitted_at DESC 로 고른다. 이 세 CTE
--   에는 상태 조건이 전혀 없어 status='draft' 행도 "최신 1건" 후보에 그대로 들어간다.
--
--   반면 화면(dev/js/admin-deliverables.js)이 인증 상태를 계산할 때 쓰는 결과물
--   목록은 애초에 draft 를 안 받는다 — dev/lib/storage.js:905 의 fetchDeliverables() 가
--   `.neq('status', 'draft')` 로 조회 단계에서 걸러낸다. 즉 화면의 "최신"은 이미
--   "최신 비-draft"다.
--
--   두 "최신"의 정의가 어긋나면서 아래 구조의 응모가 생긴다.
--   ⚠️ 적용 후 재실측 결과 **실제 해당 건은 1건**이다(2026-08-10). 처음 이 파일에
--   적었던 "14건"은 잘못 센 것으로, 그건 「임시저장이 최신인 응모」 수(게시물 14·
--   영수증 1)였고 「승인이 가려진 응모」 수가 아니었다. 뒤에 승인된 행이 실제로
--   있던 것은 2건(게시물 1·영수증 1)이고, 그중 후보로 살아난 것은 영수증 1건이다.
--   나머지는 임시저장만 있어 이 변경 전에도 후에도 후보가 아니다 —
--   **「임시저장이 최신」과 「승인이 가려졌다」는 다른 조건**이라는 게 요점이다:
--     ① 채널 A(또는 유일 결과물)가 과거에 approved 로 승인됨
--     ② 그 뒤 재제출·재시도가 새 행(영수증) 또는 다른 채널 신규 행(게시물, 채널이
--        다르면 insertDraftDeliverable 이 UPDATE 재사용이 아니라 새 INSERT — 마이그
--        158/문서 §3-2 참조)으로 생성되고 status='draft' 인 채 마무리되지 않음
--        (예: 폼 이탈·네트워크 오류로 finalize 단계 status='pending' 갱신이 안 됨)
--     ③ 그 draft 행의 submitted_at 이 ①의 approved 행보다 늦음
--   → 화면: draft 행을 애초에 안 가져오므로 "최신"은 여전히 ①(approved) = 인증성공으로
--     표시된다.
--   → _settlement_cert_candidates(): draft 를 걸러내지 않으므로 "최신"은 ②(draft) =
--     status<>'approved' → is_success=false = 정산 후보에서 조용히 빠진다.
--   결과: "화면에는 인증성공(승인)으로 보이는데 정산 후보에는 없는" 응모가 생긴다.
--
-- ── 다른 곳은 이미 이렇게 하고 있다(같은 패턴, 참고용 — 로직 복제 아님) ──
--   250_count_pending_review_post_channel_agnostic.sql:62
--     `WHERE d.status <> 'draft' AND ...` 를 DISTINCT ON 서브쿼리 WHERE 절에 둔다.
--   276_deliverable_gate_batch_and_post_channel_exception.sql:237
--     같은 자리에 같은 조건.
--   이 마이그레이션도 동일한 자리(DISTINCT ON 을 적용하는 서브쿼리의 WHERE 절)에 같은
--   조건을 추가한다 — 새로운 판정 방식을 만들지 않는다.
--
-- ── 재정의 기준 확인(전수 grep, feedback_function_redefine_latest_base 메모리 규칙) ──
--   grep -rl "_settlement_cert_candidates" supabase/migrations/*.sql
--   → 정의(CREATE/CREATE OR REPLACE FUNCTION)한 파일은 232 → 262 → 264 → 300 네 곳.
--   그중 번호가 가장 큰 300 이 현재 유효한 원본이다(300 파일 자신도 "264 가 원본"이라고
--   적어뒀던 232→262→264 계보를 이어받아 262 의 컬럼 2종[receipt_amount_jpy·
--   amount_cap_jpy]을 추가한 버전). 277·278·288 은 주석에서만 이름을 언급할 뿐 함수를
--   재정의하지 않는다(grep 으로 CREATE 라인 없음을 확인 완료 — 재정의 후보 아님).
--   이 마이그레이션은 300 의 함수 본문을 그대로 베이스로 삼고, 아래 "바꾸는 지점"에
--   적은 3줄만 추가한다.
--
-- ── 이 마이그레이션이 바꾸는 것(전부) ──
--   receipt_latest / post_latest / review_channel_latest 세 CTE 의 WHERE 절에
--   `AND d.status <> 'draft'` 한 줄씩 추가. 그 외 SELECT 목록·DISTINCT ON 키·
--   ORDER BY·바깥 SELECT(금액 계산·is_success·cert_at·amount_issue)는 300 과
--   글자 하나 다르지 않다.
--
--   ⚠️ RETURNS TABLE 시그니처(컬럼 이름·타입)는 300 과 완전히 동일 — 반환 타입이
--   안 바뀌므로 DROP 없이 CREATE OR REPLACE 로 충분하다(262·300 이 했던 DROP 후
--   재생성은 "반환 컬럼 추가/변경" 때문이었고, 이번은 WHERE 절만 바뀐다).
--   이 헬퍼를 호출하는 backfill_settlements()·get_past_unregistered_settlements()·
--   register_past_settlements() 3곳(전수 확인 — 277·278·288 은 호출부 아님, 주석
--   언급뿐)은 헬퍼가 돌려주는 컬럼·타입이 그대로라 **재정의할 필요가 없다.**
--
-- ── 절대 바꾸지 않는 것(인증 성공 판정 그 자체, 반드시 300 과 동일) ──
--   candidates CTE(승인 응모·감사용 제외·정산행 미존재·264 의 무보수 시딩/방문형 제외
--   조건) / receipt_latest·post_latest·review_channel_latest 의 SELECT 목록·
--   DISTINCT ON 키·ORDER BY(어느 행이 "최신"인지 판정 순서 자체는 무변경 — 그 후보군만
--   draft 를 뺀 상태에서 같은 순서로 고른다) / channel_cert CTE / 금액 계산 CASE 문
--   (min(영수증, 상시가) 절사, 264→300 도입분) / amount_issue 판정 3종 / is_success·
--   cert_at CASE 문(264 원본 그대로 이관분) — 전부 300 원본과 한 글자도 다르지 않다.
--   가구매(proxy_purchase) 분기·채널별 완전성(any_null) 요구도 무변경.
--
-- ── ⚠️ 반대 방향 위험 점검(사용자 지적 사항 5) ──
--   draft 를 빼면 "draft 가 최신이지만 그 앞에 approved 행이 있는" 경우 approved 행이
--   다시 "최신"으로 잡힌다. 이것이 바로 화면이 이미 하고 있는 동작이다 — 화면은
--   fetchDeliverables() 가 draft 를 조회 단계에서 원천 배제하므로, 화면 입장에서
--   "최신"은 애초부터 "최신 비-draft"였다(파일 상단 "무엇이 문제였나" ①~③ 참조).
--   즉 이 변경은 새로운 동작을 만드는 것이 아니라, 서버 판정을 화면이 이미 쓰던
--   정의로 맞추는 것이다.
--
-- ── 정산 행 생성에 미치는 실질 영향 ──
--   이 변경으로 정산 후보(candidates 중 is_success=true)가 늘어난다(운영 실측 1건 — 위 정정 참고).
--   그러나 실제로 settlements 행이 새로 생기는지는 이 마이그레이션과 별개로 두 조건에
--   더 달려 있다:
--     1) backfill_settlements() 는 `v_cutoff IS NOT NULL AND cert_at >= v_cutoff` 를
--        요구한다 — 이 문서 작성 시점 운영은 settlement_settings.cutoff_at 이
--        미설정(NULL)이라 자동 백필 자체가 0건이다(created_count 는 이 변경과
--        무관하게 여전히 0). cutoff_at 이 나중에 설정되고, 그 건의 cert_at 이
--        cutoff 이후라면 그때 비로소 자동 생성 대상이 된다.
--     2) get_past_unregistered_settlements()(「과거 미등록」 수동 처리 화면)는
--        컷오프와 무관하게 후보를 보여준다 — 새로 든 건은 이 변경 적용 직후 바로 그
--        목록에 나타난다(관리자가 수동으로 확인 후 처리하는 경로이므로 알림 발송
--        없음, 233/262/300 원칙 그대로).
--   금액 계산 로직 자체는 이 마이그레이션에서 손대지 않으므로, 새로 후보에 들어온
--   건도 기존 300 의 min(영수증,상시가) 절사·amount_issue 판정을 그대로 받는다.
--   ⚠️ 그 화면에는 정산 공개 전부터 쌓인 **과거분 수백 건**이 원래 있다. 이 변경이
--   더한 몫과 원래 있던 몫을 섞어 보지 말 것 — 되돌릴 수 없는 「송금완료 기록」
--   버튼이 있는 화면이다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

CREATE OR REPLACE FUNCTION public._settlement_cert_candidates()
RETURNS TABLE (
  application_id      uuid,
  influencer_id       uuid,
  campaign_id         uuid,
  campaign_no         text,
  campaign_title      text,
  reward              bigint,
  recruit_type        text,
  paypal_email        text,
  influencer_name     text,
  influencer_name_kana text,
  amount_jpy          bigint,
  amount_source       text,
  reward_part_jpy     bigint,
  receipt_amount_jpy  bigint,
  amount_cap_jpy      bigint,
  amount_issue        text,
  is_success          boolean,
  cert_at             timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 정산 대상 후보: 승인된 응모 + 감사용 제외 + 아직 정산행 없음(멱등)
    -- + [264, 유지] 무보수 시딩·방문형 제외. 300 원본과 완전히 동일(318 은 여기를
    -- 손대지 않는다 — draft 제외는 아래 세 CTE 에서만 이뤄진다).
    SELECT
      a.id                                AS application_id,
      a.user_id                           AS influencer_id,
      a.campaign_id                       AS campaign_id,
      c.campaign_no                       AS campaign_no,
      c.title                             AS campaign_title,
      c.reward                            AS reward,
      c.product_price                     AS product_price,
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
      AND inf.is_audit = false
      AND NOT EXISTS (
        SELECT 1 FROM public.settlements s WHERE s.application_id = a.id
      )
      -- [264, 유지] 시딩(gifting)·방문형(visit) 이면서 현금 리워드가 없는 캠페인은
      -- "금액 오류"가 아니라 "제품만 제공하는 정상 무보수 캠페인"이라 애초에 후보에서
      -- 제외한다. monitor 는 이 조건의 영향을 받지 않는다.
      AND NOT (
        c.recruit_type <> 'monitor'
        AND (c.reward IS NULL OR c.reward <= 0)
      )
  ),
  receipt_latest AS (
    -- [318 변경] `AND d.status <> 'draft'` 1줄 추가 — 그 외(SELECT 목록·DISTINCT ON
    -- 키·ORDER BY)는 300(=264=262=232 원본)과 완전히 동일. draft 를 "최신 1건" 후보에서
    -- 미리 빼야, 화면(fetchDeliverables 의 `.neq('status','draft')`)이 보는 "최신"과
    -- 같은 행을 가리킨다(파일 상단 "무엇이 문제였나" 참조).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at, d.purchase_amount
    FROM public.deliverables d
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  post_latest AS (
    -- [318 변경] `AND d.status <> 'draft'` 1줄 추가. 그 외 무변경(응모별 게시물(post)
    -- 최신 1건 상태+승인시각 — 채널 무관, 화면 g.result 와 동일 기준).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'post'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- [318 변경] `AND d.status <> 'draft'` 1줄 추가. 그 외 무변경(응모×채널별
    -- 인증샷(review_image) 최신 1건 상태+승인시각).
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status, d.reviewed_at
    FROM public.deliverables d
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  channel_cert AS (
    -- 300(=264=262=232 원본)와 동일: 리뷰어(monitor 일반) 응모의 캠페인 채널 전체 인증샷
    -- 승인시각 최댓값 + 완전성 강제(any_null). (변경 없음 — 인증 성공 판정은 그대로)
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
    cd.campaign_no,
    cd.campaign_title,
    cd.reward,
    cd.recruit_type,
    cd.paypal_email,
    cd.influencer_name,
    cd.influencer_name_kana,
    -- ── 금액 계산: 리뷰어형(monitor, 가구매 포함) = min(영수증, 상시가) 절사 ──
    -- 300 원본과 완전히 동일(변경 없음). LEAST() 의 NULL 무시 동작 때문에 두 값이
    -- 모두 유효할 때만 호출한다(300 파일 상단 경고 그대로 적용).
    CASE
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount IS NOT NULL AND rl.purchase_amount > 0
           AND cd.product_price   IS NOT NULL AND cd.product_price   > 0
        THEN NULLIF(GREATEST(floor(LEAST(rl.purchase_amount, cd.product_price::numeric)), 0), 0)::bigint
      WHEN cd.recruit_type = 'monitor' THEN NULL::bigint  -- 아래 amount_issue 로 사유가 채워짐
      ELSE cd.reward
    END AS amount_jpy,
    CASE
      WHEN cd.recruit_type = 'monitor' THEN 'receipt_amount'
      ELSE 'reward'
    END AS amount_source,
    NULL::bigint AS reward_part_jpy,  -- 합산 미구현 — 항상 NULL(261 부터 그대로)
    -- ── 감사용 칸 2개(299) — 리뷰어형만 채움, 그 외 NULL. 300 원본과 동일 ──
    CASE WHEN cd.recruit_type = 'monitor' THEN floor(rl.purchase_amount)::bigint ELSE NULL::bigint END AS receipt_amount_jpy,
    CASE WHEN cd.recruit_type = 'monitor' THEN cd.product_price ELSE NULL::bigint END AS amount_cap_jpy,
    -- ── amount_issue: 조건 3종(300 그대로 — ㉰ 버림 결과 0 이하 누락 시 배치 실패 위험) ──
    CASE
      WHEN cd.recruit_type = 'monitor' AND (rl.purchase_amount IS NULL OR rl.purchase_amount <= 0)
        THEN '리뷰어형 영수증 결제 금액(purchase_amount) 값 없음 또는 0 이하'
      WHEN cd.recruit_type = 'monitor' AND (cd.product_price IS NULL OR cd.product_price <= 0)
        THEN '리뷰어형 제품 가격(product_price, 지급 상한) 값 없음 또는 0 이하'
      WHEN cd.recruit_type = 'monitor'
           AND rl.purchase_amount > 0 AND cd.product_price > 0
           AND floor(LEAST(rl.purchase_amount, cd.product_price::numeric)) <= 0
        THEN '리뷰어형 정산 금액이 소수점 절사 후 0 이하'
      ELSE NULL
    END AS amount_issue,
    -- ── is_success: 300(=264=262=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
    -- ── cert_at: 300(=264=262=232=231 원본) CASE 문 그대로 이관(변경 없음) ──
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
  '[318 재정의, 300 원본 대체(반환 컬럼 무변경 — WHERE 절만 변경)] private 헬퍼 — '
  '정산 미등록(settlements 행 없음) 응모 전체에 대해 인증 성공 여부(is_success)·인증 성공일'
  '(cert_at)·모집 형식별 정산 금액(amount_jpy)·금액 출처(amount_source)·감사용 원금액/상한'
  '(receipt_amount_jpy/amount_cap_jpy)·금액 미확정 사유(amount_issue)를 계산한다(판정 로직은 '
  '300 그대로 무변경). '
  '[318] receipt_latest·post_latest·review_channel_latest 세 CTE 가 "최신 1건"을 고를 때 '
  'status=draft 행을 제외하도록 WHERE 절에 조건을 추가 — 화면(dev/lib/storage.js '
  'fetchDeliverables 의 `.neq(status,draft)`)이 보는 "최신"과 같은 행을 가리키게 맞춤 '
  '(250·276 이 이미 쓰던 같은 패턴). '
  'backfill_settlements()·get_past_unregistered_settlements()·register_past_settlements() '
  '3곳이 이 함수 하나를 호출해 판정·금액 로직 드리프트를 원천 차단. '
  'PUBLIC/authenticated 에 EXECUTE 미부여(직접 RPC 호출 불가) — 300 과 동일 정책.';

REVOKE ALL ON FUNCTION public._settlement_cert_candidates() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
--   ⚠️ SQL Editor 세션은 auth.uid() 가 NULL 이라 has_permission 게이트가 있는 함수
--   (backfill_settlements 등)는 postgres(소유자) role 로 실행해야 permission_denied
--   없이 호출된다. 헬퍼(_settlement_cert_candidates) 자체는 오너 권한이면 직접 SELECT 가능.
-- ============================================================
/*

-- [V0] 적용 전 스냅샷 — 반드시 318 적용 *직전*에 먼저 실행해 두고 결과를 따로 보관할 것.
--   "임시저장이 최신이라 후보에서 빠지는" 응모를 직접 지목한다(재현 조사문서 §5-4 방식과 동일:
--   application_id 별 결과물 kind 별 "실제 최신 1건"의 status 가 draft 인 경우를 찾는다).
WITH latest_any AS (
  SELECT DISTINCT ON (
    d.application_id, d.kind,
    CASE WHEN d.kind = 'review_image' THEN COALESCE(d.post_channel, '') ELSE '' END
  )
    d.application_id, d.kind, d.status,
    CASE WHEN d.kind = 'review_image' THEN d.post_channel ELSE NULL END AS post_channel
  FROM public.deliverables d
  WHERE d.kind IN ('receipt', 'post', 'review_image')
  ORDER BY
    d.application_id, d.kind,
    CASE WHEN d.kind = 'review_image' THEN COALESCE(d.post_channel, '') ELSE '' END,
    d.submitted_at DESC, d.updated_at DESC
)
SELECT kind, count(*) AS latest_is_draft_cnt, array_agg(DISTINCT application_id) AS application_ids
FROM latest_any
WHERE status = 'draft'
GROUP BY kind
ORDER BY kind;
-- 기대(적용 전, 조사 시점 실측): receipt 1건 · post 13건 · review_image 0건(운영 실측 기준).
-- 개발 DB 데이터는 운영과 다를 수 있으니 정확한 수는 달라질 수 있다 — 여기서는
-- "0건이 아니다" 자체가 재현 확인 포인트다. 이 SELECT 의 application_ids 를 메모해 둔다.

-- [V1] 318 적용 *전* candidate 스냅샷(권장 — 비교 기준선)
--   postgres role 세션으로 실행. 위 [V0] 에서 얻은 application_id 들이 여기서
--   is_success=false 로 나오는지 확인(= 화면엔 승인인데 후보에서 빠지는 증거).
SELECT application_id, recruit_type, is_success, amount_issue
FROM public._settlement_cert_candidates()
WHERE application_id = ANY(ARRAY[]::uuid[])  -- ← [V0] 결과의 application_ids 를 채워 실행
ORDER BY application_id;

-- ⚠️⚠️ 이 지점에서 이 마이그레이션 파일(318)을 SQL Editor 에 적용한다 ⚠️⚠️

-- [V2] 함수 반환 타입이 300 과 동일한지 확인(컬럼 개수·이름 무변경 확인)
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public' AND routine_name = '_settlement_cert_candidates';

-- [V3] 헬퍼가 여전히 PUBLIC/authenticated 에 노출 안 됐는지 확인
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = '_settlement_cert_candidates';
-- 기대: 0 row (또는 owner 행만)

-- [V4] 적용 *후* — [V0]/[V1] 에서 지목한 그 application_id 들이 이제 is_success=true 로
--   바뀌는지 확인(단 그 결과물이 "draft 를 뺀 최신"으로 approved 인 경우에 한함 — 실제로
--   화면에서 승인으로 보이던 건이라면 true 가 나와야 한다).
SELECT application_id, recruit_type, is_success, amount_issue, amount_jpy, cert_at
FROM public._settlement_cert_candidates()
WHERE application_id = ANY(ARRAY[]::uuid[])  -- ← [V0] 결과의 application_ids 그대로 재사용
ORDER BY application_id;
-- [V1]과 대조: 같은 application_id 가 is_success=false → true 로 바뀌면 이번 수정이
-- 의도대로 동작한 것. (단, candidates CTE 조건 — 이미 정산행이 있거나 감사용 계정이면
-- 애초에 결과 자체가 안 나온다 — 그 경우는 이 헬퍼 대상이 아니므로 정상.)

-- [V5] 전체 집계 전후 비교(§5-1 방식과 동일 — recruit_type 별 후보/성공 건수가
--   "그 외에는" 그대로인지, monitor·gifting·visit 각각에서 늘어난 성공 건수가
--   [V0] 에서 찾은 draft-최신 건수와 대략 일치하는지 확인).
SELECT
  recruit_type,
  amount_source,
  count(*) AS candidate_cnt,
  count(*) FILTER (WHERE is_success) AS success_cnt,
  count(*) FILTER (WHERE is_success AND amount_issue IS NOT NULL) AS success_but_amount_issue_cnt,
  sum(amount_jpy) FILTER (WHERE is_success AND amount_issue IS NULL) AS success_amount_sum
FROM public._settlement_cert_candidates()
GROUP BY recruit_type, amount_source
ORDER BY recruit_type;
-- [V5]의 success_cnt 합계가 적용 전(300 상태에서 같은 쿼리를 미리 한번 더 돌려 기록해 둔
-- 값)보다 [V0]에서 찾은 건수만큼 늘어났는지 확인. candidate_cnt(후보 전체 수)는
-- draft 제외와 무관하게 바뀌지 않아야 한다(후보군 자체는 candidates CTE 가 정하고
-- 318 은 그 CTE 를 손대지 않았으므로).

-- [V6] backfill_settlements() 회귀 확인 — cutoff_at 미설정이면 여전히 created_count=0
--   (이 문서 작성 시점 운영은 cutoff_at NULL — 318 이 후보를 늘려도 자동 생성 0건 유지가
--   맞는 동작이다. postgres role 로 실행하거나, has_permission 통과하는 관리자 세션 필요).
SELECT cutoff_at, influencer_visible FROM public.settlement_settings WHERE id = 1;
SELECT * FROM public.backfill_settlements();

-- [V7] get_past_unregistered_settlements() 스모크 — [V0] 에서 찾은 application_id 들이
--   이제 이 목록에 나타나는지(컷오프 무관하게 노출되는 화면이므로 즉시 보여야 함).
--   (앱에서 campaign_admin 이상 세션으로 확인 권장 — SQL Editor 직접 호출은
--   permission_denied 가능)
-- SELECT application_id, recruit_type, amount_source, amount_issue, amount_jpy, cert_at
-- FROM public.get_past_unregistered_settlements()
-- WHERE application_id = ANY(ARRAY[]::uuid[])
-- ORDER BY cert_at NULLS FIRST;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 반환 타입(컬럼 구성)이 300 과 동일하므로 DROP 없이 CREATE OR REPLACE 로 되돌릴 수 있다.
-- 1) 300_settlement_amount_receipt_basis.sql 파일을 열어
--    "1. 공통 판정·금액 계산 헬퍼 재생성" 블록(CREATE FUNCTION public._settlement_cert_candidates()
--    ~ 그 COMMENT ON FUNCTION 까지)을 그대로 복사한다.
-- 2) 맨 앞의 `CREATE FUNCTION` 을 `CREATE OR REPLACE FUNCTION` 으로 바꿔 SQL Editor 에서 실행한다
--    (300 원본은 DROP 뒤 CREATE 라 그대로 실행하면 "이미 있음" 오류가 날 수 있어 OR REPLACE 로
--    바꿔 실행 — 반환 타입이 같으므로 안전하다).
-- 3) `NOTIFY pgrst, 'reload schema';` 실행.
-- 이 작업은 receipt_latest·post_latest·review_channel_latest 세 CTE 의
-- `AND d.status <> 'draft'` 3줄만 제거하는 것과 동일한 효과다 — backfill_settlements()·
-- get_past_unregistered_settlements()·register_past_settlements() 는 318 에서 손대지
-- 않았으므로 함께 되돌릴 필요가 없다.
