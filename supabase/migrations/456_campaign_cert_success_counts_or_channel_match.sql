-- ============================================================
-- 456_campaign_cert_success_counts_or_channel_match.sql
-- 캠페인별 인증 성공 인원 집계(관리자 일일 메일·운영현황 일정 뷰 전용) —
-- 「또는」(channel_match='or') 캠페인은 요구 채널 중 하나만 승인돼도 성공으로
-- 센다. 마이그레이션 455(_settlement_cert_candidates)와 **같은 규칙**.
--
-- 사양서: docs/specs/2026-09-21-or-channel-deliverable-judgement.md §3-2
-- 작업표: docs/specs/2026-09-21-or-channel-deliverable-judgement-breakdown.md
--         「1. 고칠 자리 — 여섯 조각」의 F
--
-- ── 재정의 기준 확인(전수 grep) ──
--   `_campaign_cert_success_counts` 를 정의(CREATE/CREATE OR REPLACE FUNCTION)한
--   파일은 **433** 하나뿐이다. 434(get_campaign_action_alerts)는 이 함수를
--   안쪽에서 부르기만 할 뿐 재정의하지 않는다(434 파일 151행, SELECT 문). 이
--   마이그레이션은 433 의 함수 본문을 그대로 베이스로 삼는다.
--
-- ── 🔴 이 함수의 베낄 원본은 화면 판정이지 455(정산)가 아니다 ──
--   433 자신의 헤더가 이미 명시한다 — "완료 기준이 「일정 뷰 화면의 결과물
--   승인률 분자와 같은 수」를 요구하므로 화면(dev/js/admin-deliverables.js 의
--   computeCertStatus·countCertSuccess·_finalizeMonitorReprs·_finalizePostReprs)
--   을 베껴야 그 시험이 성립한다." 이 마이그레이션도 같은 원칙을 지킨다 — 화면
--   쪽이 이번 배포 묶음에서 함께 channel_match 갈래 분기를 얻는다(작업표 「B」
--   조각, 이 마이그레이션과 별도로 dev/js/admin-deliverables.js 에 반영된다).
--   여기서는 **구조**(candidates·채널별 최신 1건 CTE·EXISTS/NOT EXISTS 쌍)만
--   433/455 와 같은 모양을 유지하고, "무엇을 베끼는가"는 433 원본 그대로
--   화면이다. 작업표가 "F 는 A 와 같은 규칙"이라고 한 것은 **채널 갈래 판정
--   규칙 자체**(single/and/or 세 줄)가 같다는 뜻이지, 이 함수의 candidates
--   조건(승인·감사용·반려취소 제외 등, 455 의 정산 전용 조건과 다름)까지
--   455 를 베낀다는 뜻이 아니다 — 그 조건은 433 원본 그대로 손대지 않는다.
--
-- ── 바꾸는 것(전부) ──
--   1) candidates CTE — c.channel_match 컬럼 추가(433 은 이 값을 아예 읽지
--      않았다).
--   2) 신규 CTE channel_kind — 응모별 채널 갈래(single/and/or). 마이그레이션
--      455 의 channel_kind 와 글자 그대로 같은 식(= dev/lib/shared.js
--      campaignFollowerKind 와 같은 기준).
--   3) success CTE 의 is_success CASE — 리뷰어형(monitor) 일반 분기와
--      시딩·방문형 분기 각각에 `CASE ck.kind WHEN 'or' THEN(EXISTS 단독) ELSE
--      (433 원본 EXISTS+NOT EXISTS 쌍 그대로) END` 를 씌운다.
--
-- ── 절대 바꾸지 않는 것(433 과 완전히 동일) ──
--   candidates CTE 의 나머지 조건(반려·취소 제외·감사용 제외 — 정산과 달리
--   "승인된 응모만"으로 좁히지 않음, 433 원본 그대로) / receipt_latest·
--   review_channel_latest·post_channel_latest 정의 / 가구매(proxy_purchase)
--   분기(채널을 아예 안 봄) / recruit_type IS NULL 캠페인을 이름으로 지목해
--   제외하는 부분(433 의 "🔴 모집 형식을 이름으로 지목한다" 주석 그대로 — ELSE
--   로 바꾸지 않는다. 화면이 그 갈래를 안 세므로 이 함수도 세면 안 된다) /
--   최종 SELECT(campaign_id 별 성공 인원 집계, unnest+LEFT JOIN 으로 0건도
--   포함) / 실행 권한(postgres·service_role 만) / RETURNS TABLE 시그니처.
--
--   434(get_campaign_action_alerts)는 이 함수가 돌려주는 컬럼·타입이 그대로라
--   재정의할 필요가 없다.
--
-- ── ⚠️ 채널 비교 규칙(마이그레이션 319) — 여기서도 바꾸지 않는다 ──
--   캠페인 쪽 채널 토큰만 btrim, deliverables.post_channel 쪽 값은 원본 그대로
--   비교. 455 와 완전히 같은 규칙.
--
-- ── ⚠️ 같은 판정이 여섯 곳(사양서 §2-②) — 이 파일은 그중 F 만 ──
--   나머지(서버 정산=A=455·검수 화면=B·엑셀+브랜드 공유 화면=C·결과물 검수
--   결과 메일=D·일일 메일 리뷰 인증샷=E)는 같은 배포 묶음의 다른 작업이 본다.
--
-- 롤백: DROP 없이 433 원본으로 CREATE OR REPLACE 되돌리기(파일 하단 참고).
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public._campaign_cert_success_counts(p_campaign_ids uuid[])
RETURNS TABLE (
  campaign_id uuid,
  cert_count  integer
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH candidates AS (
    -- 433 원본과 완전히 동일하되 [456 신규] c.channel_match 컬럼만 추가.
    -- 제외 셋 중 둘(감사용·반려/취소) — 화면 isCertExcluded 와 같은 기준.
    -- 화면과 달리 "승인된 신청만"으로 좁히지 않는다 — pending 신청은 어차피
    -- 결과물이 없어 success 계산에서 자연히 빠진다(정산 후보 조건인 "승인된
    -- 응모만"·"정산행 미존재"·"무보수 시딩/방문형 제외"는 여기 없음 — 이
    -- 함수는 정산이 아니라 결과물 인증 성공만 본다).
    SELECT
      a.id                                AS application_id,
      a.campaign_id                       AS campaign_id,
      c.recruit_type                      AS recruit_type,
      c.channel                           AS channel,
      c.channel_match                     AS channel_match,
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.campaign_id = ANY(p_campaign_ids)
      AND a.status NOT IN ('rejected', 'cancelled')
      AND inf.is_audit = false
  ),
  channel_kind AS (
    -- [456 신규] 응모별 채널 갈래 — 마이그레이션 455 의 channel_kind 와 글자
    -- 그대로 같은 식(= dev/lib/shared.js campaignFollowerKind 와 같은 기준).
    --   채널 1개 이하                       → single
    --   btrim(lower(channel_match))='and'   → and
    --   그 밖(NULL 포함)                    → or   (🔴 기본값 — "and 가 아니면 or")
    SELECT
      cd.application_id,
      CASE
        WHEN (
          SELECT count(*) FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
          WHERE btrim(ch.name) <> ''
        ) <= 1 THEN 'single'
        WHEN btrim(lower(cd.channel_match)) = 'and' THEN 'and'
        ELSE 'or'
      END AS kind
    FROM candidates cd
  ),
  receipt_latest AS (
    -- 433 원본과 완전히 동일(변경 없음) — 응모별 영수증(receipt) 최신 1건 — draft 제외.
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 433 원본과 완전히 동일(변경 없음) — 리뷰어형 응모×채널별 인증샷(review_image) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  post_channel_latest AS (
    -- 433 원본과 완전히 동일(변경 없음) — 시딩·방문형 응모×채널별 게시물(post) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'post' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  success AS (
    SELECT
      cd.application_id,
      cd.campaign_id,
      CASE
        WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
          -- 가구매 — 영수증만. 433 원본과 완전히 동일(변경 없음).
          COALESCE(rl.status = 'approved', false)
        WHEN cd.recruit_type = 'monitor' THEN
          -- 일반 리뷰어형 — 영수증 승인 + [456] ck.kind 에 따라 채널 요구 갈림.
          CASE ck.kind
            WHEN 'or' THEN
              -- [456 신규] 영수증 승인 + 요구 채널 중 하나라도 인증샷 승인.
              COALESCE(rl.status = 'approved', false)
              AND EXISTS (
                SELECT 1
                FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
                LEFT JOIN review_channel_latest rcl
                  ON rcl.application_id = cd.application_id
                 AND rcl.post_channel   = btrim(ch.name)
                WHERE btrim(ch.name) <> ''
                  AND rcl.status = 'approved'
              )
            ELSE
              -- 433 원본과 완전히 동일(변경 없음) — and·single 은 캠페인 채널 전부 인증샷 승인.
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
          END
        ELSE
          -- 시딩·방문형 — [456] ck.kind 에 따라 채널 요구 갈림.
          --
          -- 🔴 모집 형식을 **이름으로 지목**한다 — `ELSE` 로 두면 `recruit_type IS NULL`
          --    인 캠페인이 여기로 들어온다(제약 399 가 NULL 을 허용한다). 화면은
          --    `_finalizePostReprs`(admin-deliverables.js:713)가
          --    `if (rt !== 'gifting' && rt !== 'visit') continue;` 로 NULL 을 건너뛰어
          --    대표 상태가 안 생기므로 **NULL 캠페인은 화면에서 영원히 성공이 못 된다.**
          --    이름으로 안 지목하면 서버만 성공을 내서 「화면 동작 변화 0」이 깨진다.
          --    (433 원본과 완전히 동일 — 변경 없음)
          cd.recruit_type IN ('gifting', 'visit')
          AND CASE ck.kind
            WHEN 'or' THEN
              -- [456 신규] 요구 채널 중 하나라도 승인된 게시물이 있으면 충족.
              EXISTS (
                SELECT 1
                FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
                LEFT JOIN post_channel_latest pcl
                  ON pcl.application_id = cd.application_id
                 AND pcl.post_channel   = btrim(ch.name)
                WHERE btrim(ch.name) <> ''
                  AND pcl.status = 'approved'
              )
            ELSE
              -- 433 원본과 완전히 동일(변경 없음) — and·single 은 캠페인 채널 전부 게시물 승인.
              EXISTS (
                SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
                WHERE btrim(ch.name) <> ''
              )
              AND NOT EXISTS (
                SELECT 1
                FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
                LEFT JOIN post_channel_latest pcl
                  ON pcl.application_id = cd.application_id
                 AND pcl.post_channel   = btrim(ch.name)
                WHERE btrim(ch.name) <> ''
                  AND COALESCE(pcl.status, 'none') <> 'approved'
              )
          END
      END AS is_success
    FROM candidates cd
    LEFT JOIN channel_kind    ck ON ck.application_id = cd.application_id
    LEFT JOIN receipt_latest  rl ON rl.application_id = cd.application_id
  )
  -- 요청받은 캠페인 식별자 전부를 돌려준다(성공 0건인 캠페인도 cert_count=0 으로
  -- 포함) — 호출부(434)가 결측 행을 따로 신경 쓰지 않게. 433 원본과 완전히 동일.
  SELECT
    ids.campaign_id,
    COALESCE(cnt.cert_count, 0)::integer AS cert_count
  FROM unnest(p_campaign_ids) AS ids(campaign_id)
  LEFT JOIN (
    SELECT s.campaign_id, COUNT(*)::integer AS cert_count
    FROM success s
    WHERE s.is_success
    GROUP BY s.campaign_id
  ) cnt ON cnt.campaign_id = ids.campaign_id;
$$;

COMMENT ON FUNCTION public._campaign_cert_success_counts(uuid[]) IS
  '[456 재정의, 433 원본 대체(반환 컬럼 무변경 — is_success 의 채널 완전성 판정만 '
  'channel_match 갈래별로 분기)] 화면 판정(computeCertStatus·countCertSuccess, '
  'dev/js/admin-deliverables.js)을 옮긴 사본이며, 같은 판정이 화면·회원 일일 '
  '메일·관리자 일일 메일(이 함수)·리포트·정산(마이그레이션 455 '
  '_settlement_cert_candidates)에 있어 한 곳을 고치면 다섯을 함께 본다. '
  '[456] campaigns.channel_match 갈래(dev/lib/shared.js campaignFollowerKind 와 '
  '동일 기준 — 채널 1개 이하=single, and=and, 그 밖(NULL 포함)=or)에 따라 채널 '
  '완전성 요구가 갈린다: and·single 은 종전대로 캠페인이 요구하는 채널 전부에 '
  '승인이 있어야 하고, or 은 하나라도 승인이면 충족한다(리뷰어형 인증샷·시딩·'
  '방문형 게시물 둘 다). 내부 전용 — public.get_campaign_action_alerts() 만 '
  '부른다(postgres·service_role 실행 권한만 부여, anon·authenticated 는 회수).';

-- 서비스 키·소유자 권한을 먼저 못 박는다(마이그레이션 375 「부여 먼저, 회수
-- 나중」 선례 — 최종 상태만 보면 순서가 바뀌어도 트랜잭션이라 무해하지만,
-- 이 저장소 관행을 그대로 따른다). CREATE OR REPLACE 라 433 의 권한 설정은
-- 원래 보존되지만, 그 사실에만 기대지 않고 이번에도 명시한다.
GRANT EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) TO postgres, service_role;

REVOKE EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor 에서 1단계씩 실행 — 결과 확인 후 다음
-- 단계로. ⚠️ [V0] 은 위 CREATE OR REPLACE 를 실행하기 *전에* 먼저 돌린다.
-- ============================================================
/*

-- ══════════════ [V0] 필수 — 반드시 위 CREATE OR REPLACE 를 실행하기 *전에* ══════════════
-- 먼저 돌린다. 지금(433 상태) 실제로 배포된 함수와, 이 파일이 도입하는 새
-- 규칙을 처음부터 다시 계산한 것을 대조한다. 대상은 「채널 2개 이상 + or」
-- 캠페인 전체(활성·모집마감 상태 — 이 함수는 434 를 통해 그런 캠페인만
-- 부른다) + 「채널 2개 이상 + and」캠페인(무변화 확인).
--
-- 🔴 이 변경은 or 요구를 "전부"에서 "하나라도"로 완화하는 것뿐이라, 이론상
--    true→false 로 바뀌는 응모는 0건이어야 한다. 1건이라도 나오면 즉시 멈추고
--    원인을 먼저 본다.
WITH target_campaigns AS (
  SELECT id AS campaign_id, campaign_no, title, channel, channel_match, recruit_type
  FROM public.campaigns
  WHERE status IN ('active', 'scheduled', 'closed', 'ended') AND deleted_at IS NULL
    AND (SELECT count(*) FROM unnest(string_to_array(channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '') >= 2
),
old_result AS (
  SELECT campaign_id, cert_count
  FROM public._campaign_cert_success_counts(ARRAY(SELECT campaign_id FROM target_campaigns))
),
candidates AS (
  SELECT
    a.id AS application_id, a.campaign_id, c.recruit_type, c.channel, c.channel_match,
    COALESCE(c.proxy_purchase, false) AS proxy_purchase
  FROM public.applications a
  JOIN target_campaigns c ON c.campaign_id = a.campaign_id
  JOIN public.influencers inf ON inf.id = a.user_id
  WHERE a.status NOT IN ('rejected', 'cancelled')
    AND inf.is_audit = false
),
channel_kind AS (
  SELECT
    cd.application_id,
    CASE
      WHEN (SELECT count(*) FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '') <= 1 THEN 'single'
      WHEN btrim(lower(cd.channel_match)) = 'and' THEN 'and'
      ELSE 'or'
    END AS kind
  FROM candidates cd
),
receipt_latest AS (
  SELECT DISTINCT ON (d.application_id) d.application_id, d.status
  FROM public.deliverables d
  JOIN candidates cd ON cd.application_id = d.application_id
  WHERE d.kind = 'receipt' AND d.status <> 'draft'
  ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
),
review_latest AS (
  SELECT DISTINCT ON (d.application_id, d.post_channel) d.application_id, d.post_channel, d.status
  FROM public.deliverables d
  JOIN candidates cd ON cd.application_id = d.application_id
  WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL AND d.status <> 'draft'
  ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
),
post_latest AS (
  SELECT DISTINCT ON (d.application_id, d.post_channel) d.application_id, d.post_channel, d.status
  FROM public.deliverables d
  JOIN candidates cd ON cd.application_id = d.application_id
  WHERE d.kind = 'post' AND d.post_channel IS NOT NULL AND d.status <> 'draft'
  ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
),
new_success AS (
  SELECT
    cd.application_id, cd.campaign_id, cd.recruit_type, ck.kind,
    CASE
      WHEN cd.recruit_type = 'monitor' AND cd.proxy_purchase THEN
        COALESCE(rl.status = 'approved', false)
      WHEN cd.recruit_type = 'monitor' THEN
        CASE ck.kind
          WHEN 'or' THEN
            COALESCE(rl.status = 'approved', false)
            AND EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN review_latest rv ON rv.application_id = cd.application_id AND rv.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND rv.status = 'approved'
            )
          ELSE
            COALESCE(rl.status = 'approved', false)
            AND EXISTS (SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '')
            AND NOT EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN review_latest rv ON rv.application_id = cd.application_id AND rv.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND COALESCE(rv.status,'none') <> 'approved'
            )
        END
      ELSE
        cd.recruit_type IN ('gifting', 'visit')
        AND CASE ck.kind
          WHEN 'or' THEN
            EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_latest pl ON pl.application_id = cd.application_id AND pl.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND pl.status = 'approved'
            )
          ELSE
            EXISTS (SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '')
            AND NOT EXISTS (
              SELECT 1 FROM unnest(string_to_array(cd.channel, ',')) AS ch(name)
              LEFT JOIN post_latest pl ON pl.application_id = cd.application_id AND pl.post_channel = btrim(ch.name)
              WHERE btrim(ch.name) <> '' AND COALESCE(pl.status,'none') <> 'approved'
            )
        END
    END AS is_success
  FROM candidates cd
  JOIN channel_kind ck ON ck.application_id = cd.application_id
  LEFT JOIN receipt_latest rl ON rl.application_id = cd.application_id
),
new_result AS (
  SELECT campaign_id, count(*) FILTER (WHERE is_success) AS cert_count
  FROM new_success
  GROUP BY campaign_id
)
SELECT
  tc.campaign_no, tc.title, tc.recruit_type, tc.channel_match,
  COALESCE(o.cert_count, 0) AS old_cert_count,
  COALESCE(n.cert_count, 0) AS new_cert_count,
  COALESCE(n.cert_count, 0) - COALESCE(o.cert_count, 0) AS "차이(음수면_즉시중단)"
FROM target_campaigns tc
LEFT JOIN old_result o ON o.campaign_id = tc.campaign_id
LEFT JOIN new_result n ON n.campaign_id = tc.campaign_id
ORDER BY tc.channel_match, tc.campaign_no;
-- 기대: 「차이」가 모든 행에서 0 이상. channel_match='and' 행은 모두 0(코드가
-- 그 갈래를 한 글자도 안 바꿨으므로). channel_match='or'(또는 NULL) 행 중
-- 이번에 새로 잡히는 만큼만 양수 — 마이그레이션 455 의 [V0] 결과(응모 단위
-- 80 안팎)와 캠페인 단위로 합이 맞는지 눈으로 대조한다(집계 단위가 달라
-- 정확히 일치하지 않을 수 있다 — 응모 vs 캠페인).

-- ⚠️⚠️ 위 조회의 「차이」가 모든 행에서 0 이상임을 확인한 뒤 이 지점에서
-- 파일 상단의 CREATE OR REPLACE 블록을 SQL Editor 에 적용한다 ⚠️⚠️

-- ══════════════ [V1] 실행 권한 — postgres·service_role 만 true, anon·authenticated 는 false ══════════════
SELECT has_function_privilege('postgres',      p.oid, 'EXECUTE') AS postgres,
       has_function_privilege('service_role',  p.oid, 'EXECUTE') AS service_role,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS 로그인,
       has_function_privilege('anon',          p.oid, 'EXECUTE') AS 비로그인
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public' AND p.proname = '_campaign_cert_success_counts';

-- [V1-b] 🔴 PUBLIC 부여가 남아 있으면 [V1] 은 로그인·비로그인 둘 다 true 로
-- 보일 수 있다 — 실제 목록의 맨 앞에 `=X/` 가 없는지 눈으로 확인.
--   SELECT p.proname, p.proacl::text
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public' AND p.proname = '_campaign_cert_success_counts';

-- ══════════════ [V2] 적용 후 재집계 — [V0] 대상 캠페인으로 다시 호출해 일치하는지 ══════════════
-- (postgres role 로 실행)
SELECT c.campaign_id, c.cert_count
FROM public._campaign_cert_success_counts(
  ARRAY(
    SELECT id FROM public.campaigns
    WHERE status IN ('active','scheduled','closed','ended') AND deleted_at IS NULL
      AND (SELECT count(*) FROM unnest(string_to_array(channel, ',')) AS ch(name) WHERE btrim(ch.name) <> '') >= 2
  )
) c
ORDER BY c.cert_count DESC;

-- ══════════════ [V3] 운영현황 일정 뷰 화면 대조 ══════════════
-- 관리자로 로그인한 브라우저 콘솔에서 운영현황 「일정」 뷰를 펼쳐, [V0] 에서
-- 새로 잡힌 or 캠페인의 「결과물 승인률」 분자(countCertSuccess 결과)가 [V2]
-- 의 cert_count 와 같은 수인지 대조한다. (⚠️ 화면 쪽 channel_match 분기는
-- 이 마이그레이션과 별도로 admin-deliverables.js 에 반영돼야 값이 맞는다 —
-- 작업표 「B」 조각이 아직 안 나갔다면 화면 숫자는 옛 값 그대로일 수 있다.)

-- ══════════════ [V4] 모집 형식이 비어 있는 캠페인 — 참고용(433 과 동일 확인) ══════════════
SELECT id, campaign_no, title, status FROM public.campaigns
 WHERE recruit_type IS NULL AND status IN ('active','closed') AND deleted_at IS NULL;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- 반환 타입(컬럼 구성)이 433 과 동일하므로 DROP 없이 CREATE OR REPLACE 로
-- 되돌릴 수 있다.
-- 1) 433_campaign_cert_success_counts.sql 파일을 열어
--    "CREATE OR REPLACE FUNCTION public._campaign_cert_success_counts(...)"
--    블록부터 그 COMMENT ON FUNCTION 문장까지를 그대로 복사해 SQL Editor 에서
--    실행한다.
-- 2) GRANT/REVOKE 세 줄(433 과 동일)을 다시 실행한다(이미 같은 상태라 사실상
--    무해하지만, 명시적으로 재확인).
-- 434(get_campaign_action_alerts)는 손대지 않았으므로 함께 되돌릴 필요 없음.
-- ============================================================
