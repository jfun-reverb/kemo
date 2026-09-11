-- ============================================================
-- 433_campaign_cert_success_counts.sql
-- 관리자 일일 메일 「조치가 필요한 캠페인」 절 — 데이터베이스 함수 ①
-- 캠페인별 인증 성공 인원(내부 전용, get_campaign_action_alerts() 전용 재료)
--
-- 사양서: docs/specs/2026-09-11-admin-digest-deadline-section.md §3-1 ①
-- 작업표: docs/specs/2026-09-11-admin-digest-deadline-section-breakdown.md 작업 1
--
-- ── 무엇을 하나 ──
--   캠페인 식별자 배열을 받아 캠페인마다 「인증 성공 인원 수」를 돌려준다.
--   434_campaign_action_alerts.sql 의 get_campaign_action_alerts() 가 이 함수를
--   SECURITY DEFINER 소유자 권한으로 안쪽에서만 부른다 — 그 밖에는 아무도 못 부른다
--   (postgres·service_role 에만 실행 권한, 아래 GRANT/REVOKE 참고).
--
-- 🔴 베낄 원본은 **화면 판정**(dev/js/admin-deliverables.js 의 computeCertStatus·
--    countCertSuccess·buildDeliverableGroups·_finalizeMonitorReprs·_finalizePostReprs)
--    이다 — **정산 함수(마이그레이션 331 _settlement_cert_candidates)가 아니다.**
--    완료 기준이 「일정 뷰 화면의 결과물 승인률 분자와 같은 수」를 요구하므로
--    화면을 베껴야 그 시험이 성립한다(사양서 §2-2 결정 근거).
--    구조(CTE 형태·채널 EXISTS/NOT EXISTS 쌍)만 331 을 참고했다 — 331 의
--    candidates CTE(승인 응모만·정산행 미존재·무보수 시딩/방문형 제외 등 정산
--    전용 조건)는 **가져오지 않는다.**
--
-- ── 판정 규칙(화면과 완전히 동일) ──
--   제외 셋 — 감사용 계정(influencers.is_audit) · 임시저장(deliverables.status='draft')
--   · 반려·취소된 신청(applications.status IN ('rejected','cancelled') — 화면의
--   isCertExcluded 와 같은 기준).
--
--   리뷰어형(monitor):
--     · 가구매(proxy_purchase=true) — 영수증 최신 1건이 승인이면 성공(리뷰
--       인증샷 미요구).
--     · 일반 — 영수증 최신 1건 승인 **그리고** 캠페인이 요구하는 채널 전부에
--       승인된 인증샷(review_image)이 있어야 성공. 채널이 비어 있으면(공백뿐)
--       성공이 아니다.
--   시딩(gifting)·방문형(visit):
--     · 캠페인이 요구하는 채널 전부에 승인된 게시물(post)이 있어야 성공.
--       채널이 비어 있으면 성공이 아니다.
--
--   채널 비교 규칙은 마이그레이션 319 로 통일된 축과 동일 — 캠페인 쪽 채널
--   토큰만 btrim, deliverables.post_channel 쪽 값은 원본 그대로(대소문자·공백
--   변환 없음) 비교.
--
--   "최신 1건" 고르는 기준은 **정산(331)과 글자 그대로 동일** — draft 제외 후
--   submitted_at DESC, updated_at DESC 로 응모(×채널)당 1건.
--   ⚠️ 화면(buildDeliverableGroups)은 submitted_at 문자열 비교만 하고 updated_at 을
--   2차 기준으로 안 쓴다. 다만 그 앞의 조회(_queryDeliverables)가 배열을 updated_at DESC
--   로 정렬해 넘겨서 **결과적으로** 같은 행이 뽑힌다 — 「같은 기준」이 아니라
--   「다른 경로로 같은 결과」다. 화면 조회의 정렬을 바꾸면 이 동치가 깨진다.
--
-- ── 실행 권한(중요) ──
--   내부 전용 함수라 이름을 `_` 로 시작한다. SECURITY DEFINER 라 434 가 소유자
--   권한으로 안쪽에서 부르므로, 이 함수 자체는 **postgres·service_role 에만**
--   실행 권한을 준다. 🔴 선언만으로는 안 닫힌다 — 기본 부여가 두 갈래(Postgres
--   가 PUBLIC 에, Supabase 가 anon·authenticated 에 각각)라 서로를 대신하지
--   못한다. REVOKE FROM PUBLIC 과 REVOKE FROM anon, authenticated **둘 다**
--   넣는다. 안 넣으면 「postgres·service_role 에만」이 거짓이 되어 로그인한
--   회원 누구나 이 함수를 직접 부를 수 있다.
--   ⚠️ 나중에 고칠 때 CREATE OR REPLACE 로 — DROP 후 재생성하면 이 회수가
--   통째로 풀리고 오류도 표시도 없다(마이그레이션 375 선례).
--
-- 롤백: DROP FUNCTION IF EXISTS public._campaign_cert_success_counts(uuid[]);
--   (434 가 이 함수를 부르므로, 롤백은 434 를 먼저 되돌린 뒤 이 함수를 지운다.)
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
      COALESCE(c.proxy_purchase, false)   AS proxy_purchase
    FROM public.applications a
    JOIN public.campaigns   c   ON c.id = a.campaign_id
    JOIN public.influencers inf ON inf.id = a.user_id
    WHERE a.campaign_id = ANY(p_campaign_ids)
      AND a.status NOT IN ('rejected', 'cancelled')
      AND inf.is_audit = false
  ),
  receipt_latest AS (
    -- 응모별 영수증(receipt) 최신 1건 — draft 제외(제외 셋 중 나머지 하나).
    SELECT DISTINCT ON (d.application_id)
      d.application_id, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'receipt'
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.submitted_at DESC, d.updated_at DESC
  ),
  review_channel_latest AS (
    -- 리뷰어형 응모×채널별 인증샷(review_image) 최신 1건.
    SELECT DISTINCT ON (d.application_id, d.post_channel)
      d.application_id, d.post_channel, d.status
    FROM public.deliverables d
    JOIN candidates cd ON cd.application_id = d.application_id
    WHERE d.kind = 'review_image' AND d.post_channel IS NOT NULL
      AND d.status <> 'draft'
    ORDER BY d.application_id, d.post_channel, d.submitted_at DESC, d.updated_at DESC
  ),
  post_channel_latest AS (
    -- 시딩·방문형 응모×채널별 게시물(post) 최신 1건.
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
          -- 가구매 — 영수증만.
          COALESCE(rl.status = 'approved', false)
        WHEN cd.recruit_type = 'monitor' THEN
          -- 일반 리뷰어형 — 영수증 승인 + 캠페인 채널 전부 인증샷 승인.
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
          -- 시딩·방문형 — 캠페인 채널 전부 게시물 승인. 채널 0개(NULL/빈
          -- 문자열/공백뿐)면 EXISTS 가 거짓이라 항상 실패(monitor 와 동일 규칙).
          --
          -- 🔴 모집 형식을 **이름으로 지목**한다 — `ELSE` 로 두면 `recruit_type IS NULL`
          --    인 캠페인이 여기로 들어온다(제약 399 가 NULL 을 허용한다).
          --    화면은 `_finalizePostReprs`(admin-deliverables.js:713)가
          --    `if (rt !== 'gifting' && rt !== 'visit') continue;` 로 NULL 을 건너뛰어
          --    대표 상태가 안 생기므로 **NULL 캠페인은 화면에서 영원히 성공이 못 된다.**
          --    이름으로 안 지목하면 서버만 성공을 내서 「화면 동작 변화 0」이 깨진다.
          cd.recruit_type IN ('gifting', 'visit')
          AND EXISTS (
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
      END AS is_success
    FROM candidates cd
    LEFT JOIN receipt_latest rl ON rl.application_id = cd.application_id
  )
  -- 요청받은 캠페인 식별자 전부를 돌려준다(성공 0건인 캠페인도 cert_count=0 으로
  -- 포함) — 호출부(434)가 결측 행을 따로 신경 쓰지 않게.
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
  '화면 판정(computeCertStatus·countCertSuccess, dev/js/admin-deliverables.js)을 '
  '옮긴 사본이며, 같은 판정이 화면·회원 일일 메일·관리자 일일 메일(이 함수)·'
  '리포트·정산(마이그레이션 331 _settlement_cert_candidates)에 있어 한 곳을 '
  '고치면 다섯을 함께 본다. 내부 전용 — public.get_campaign_action_alerts() 만 '
  '부른다(postgres·service_role 실행 권한만 부여, anon·authenticated 는 회수).';

-- 서비스 키·소유자 권한을 먼저 못 박는다(마이그레이션 375 「부여 먼저, 회수
-- 나중」 선례 — 최종 상태만 보면 순서가 바뀌어도 트랜잭션이라 무해하지만,
-- 이 저장소 관행을 그대로 따른다).
GRANT EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) TO postgres, service_role;

REVOKE EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._campaign_cert_success_counts(uuid[]) FROM anon, authenticated;

COMMIT;

-- ============================================================
-- 적용 후 확인 (⚠️ 「적용 Success」는 검증이 아니다 — 함수 본문의 자료형·
-- 컬럼 참조는 적용 시 검사되지 않고 첫 호출에서 터진다)
-- ============================================================
/*
-- [V1] 실행 권한 — postgres·service_role 만 true, anon·authenticated 는 false
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

-- [V2] 실제 캠페인 몇 건으로 호출 — 서비스 키(SQL 편집기)로 호출 가능해야 한다
-- (postgres 권한으로 실행되므로). 캠페인 식별자는 아래를 먼저 뽑아 채운다.
--   SELECT id, campaign_no, title FROM public.campaigns
--    WHERE status IN ('active','closed') AND deleted_at IS NULL LIMIT 5;
--
--   SELECT * FROM public._campaign_cert_success_counts(
--     ARRAY['<캠페인식별자1>','<캠페인식별자2>']::uuid[]
--   );
--
-- [V3] 같은 캠페인에 대해 일정 뷰 화면의 「결과물 승인률」 분자(countCertSuccess
-- 결과)와 이 함수의 cert_count 가 같은 수인지 대조 — 관리자로 로그인한 브라우저
-- 콘솔에서 운영현황 「일정」 뷰를 펼쳐 같은 날 같은 캠페인의 숫자를 비교한다.
--
-- [V4] 모집 형식이 비어 있는 캠페인이 있는지 — 참고용(있어도 이 함수는 성공으로
-- 안 센다. 위 ELSE 갈래를 이름으로 지목했기 때문). 0건이 아니면 그 캠페인들이
-- 화면에서도 인증 성공이 안 되는 게 맞는지 한 번 눈으로 볼 것.
--   SELECT id, campaign_no, title, status FROM public.campaigns
--    WHERE recruit_type IS NULL AND status IN ('active','closed') AND deleted_at IS NULL;
*/

-- 롤백: DROP FUNCTION IF EXISTS public._campaign_cert_success_counts(uuid[]);
--   (434_campaign_action_alerts.sql 이 이 함수를 부르므로, 434 를 먼저
--   되돌린 뒤에 지운다.)
