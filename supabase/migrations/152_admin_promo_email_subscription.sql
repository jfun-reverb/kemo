-- ============================================================
-- 152_admin_promo_email_subscription.sql
-- 2026-05-27
--
-- 목적:
--   관리자가 캠페인 홍보 메일을 수신할 수 있도록 DB 기반 구축.
--   사양서: docs/specs/2026-05-27-admin-promo-email-subscription.md §2-1, §2-2, §3 PR 1
--
-- 변경 내용 2가지:
--   [1] lookup_values 시드 1줄
--       kind='admin_email_kind', code='campaign_promo'
--       → 관리자 「메일 받기 설정」 모달에 토글 자동 노출 (앱 코드 수정 불필요)
--       → 수신자 조회는 기존 get_subscribed_admin_emails('campaign_promo') 재사용
--
--   [2] 신규 함수 get_promo_digest_campaign_pool(p_digest_date date)
--       그날 홍보 대상 캠페인 전체(신규 + 마감 D-1)를 반환.
--       get_promo_digest_targets (마이그레이션 141·143) 와 같은 캠페인 조건 사용.
--       단, "이미 응모/노출/클릭한 캠페인 제외" 조건은 빼고 풀 전체 반환
--       (관리자는 응모 주체가 아님 — 사양서 §2-2).
--
-- 신규 테이블·컬럼·RLS 변경 없음.
--
-- 전제 조건:
--   마이그레이션 103 (admin_email_subscriptions, get_subscribed_admin_emails)
--   마이그레이션 140 (campaigns.first_active_at)
--   마이그레이션 143 (최신 get_promo_digest_targets — 캠페인 조건 참조 기준)
--   위 3개 적용 완료 상태에서 실행
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 스모크 호출
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--
-- 롤백:
--   DELETE FROM public.lookup_values
--     WHERE kind = 'admin_email_kind' AND code = 'campaign_promo';
--   DROP FUNCTION IF EXISTS public.get_promo_digest_campaign_pool(date);
-- ============================================================

BEGIN;


-- ============================================================
-- [1] lookup_values 시드 — admin_email_kind 에 campaign_promo 추가
--
--   sort_order 패턴 (기존 순서 맞춤):
--     10  brand_notify        브랜드 서베이 접수     (마이그레이션 103)
--     20  application_cancel  응모 취소 알림         (마이그레이션 103)
--     30  application_received 캠페인 신청 접수      (마이그레이션 130)
--     40  campaign_promo      캠페인 홍보 메일       ← 신규
--
--   lookup_values 유니크 제약: (kind, code)
--   ON CONFLICT DO NOTHING 으로 재실행 안전 (멱등)
-- ============================================================
INSERT INTO public.lookup_values (kind, code, name_ko, name_ja, sort_order, active)
VALUES (
  'admin_email_kind',
  'campaign_promo',
  '캠페인 홍보 메일',
  'キャンペーン宣伝メール',
  40,
  true
)
ON CONFLICT (kind, code) DO NOTHING;


-- ============================================================
-- [2] get_promo_digest_campaign_pool — 관리자 홍보 메일 캠페인 풀 조회
--
--   반환 컬럼:
--     new_campaign_ids         uuid[]   — 신규 캠페인 ID 배열 (마감일 오름차순)
--     new_total_count          integer  — 신규 캠페인 총수
--     deadline_d1_campaign_ids uuid[]   — D-1 임박 캠페인 ID 배열 (마감일 오름차순)
--     deadline_d1_total_count  integer  — D-1 임박 캠페인 총수
--
--   반환 형태 설계 근거:
--     Edge Function (PR 2) 이 캠페인 ID 로 campaigns 테이블을 별도 조회해
--     카드 렌더에 필요한 상세 정보(title·brand·reward 등)를 가져오는 구조.
--     본 함수에서 상세 컬럼을 포함하면 ID 배열 반환으로 통일된 get_promo_digest_targets
--     와 시그니처가 어긋남 → ID 배열만 반환해 일관성 유지.
--     총수(total_count)는 「他 N件のキャンペーン」 안내 표시용.
--
--   캠페인 풀 조건 (사양서 §2-2 + 마이그레이션 143 get_promo_digest_targets 동기화):
--     신규:
--       - status = 'active'
--       - (first_active_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
--       - deadline >= CURRENT_DATE  (마감 안 됨)
--       - monitor 캠페인: approved 수 < slots (슬롯 잔여)
--     D-1 임박:
--       - status = 'active'
--       - deadline = CURRENT_DATE + 1  (내일 마감)
--       - monitor 캠페인: 동일 슬롯 조건
--
--   ※ get_promo_digest_targets 의 인플 개인화 조건(채널 매칭·팔로워·응모/노출/클릭 제외)은
--     관리자 풀에서 모두 제외. 관리자는 그날 홍보 가능한 캠페인 전체를 본다.
--
--   보안:
--     SECURITY DEFINER + SET search_path = '' (search_path 탈취 방어)
--     REVOKE PUBLIC·anon (익명 직접 호출 차단)
--     GRANT authenticated (운영자 수동 트리거 대비)
--     service_role 은 RLS 우회로 자동 실행 가능 (Edge Function 호출 용도)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_promo_digest_campaign_pool(p_digest_date date)
RETURNS TABLE (
  new_campaign_ids         uuid[],
  new_total_count          integer,
  deadline_d1_campaign_ids uuid[],
  deadline_d1_total_count  integer
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  WITH

  -- ──────────────────────────────────────────────────────────
  -- [A] 신규 캠페인 (p_digest_date 에 KST 기준 first_active_at 발생)
  --     조건은 get_promo_digest_targets 의 new_campaigns CTE 와 완전 동기화:
  --       - status = 'active'
  --       - first_active_at KST 날짜 = p_digest_date
  --       - deadline 미경과
  --       - monitor 캠페인: approved 수 < slots (슬롯 잔여)
  --     개인화 조건(응모·노출·클릭 제외) 없음 — 관리자는 풀 전체 조회
  -- ──────────────────────────────────────────────────────────
  new_campaigns AS (
    SELECT
      c.id,
      c.deadline
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND (c.first_active_at AT TIME ZONE 'Asia/Seoul')::date = p_digest_date
      AND c.deadline >= CURRENT_DATE
      AND (
        -- monitor(리뷰어) 캠페인: 슬롯 잔여 확인
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [B] D-1 임박 캠페인 (내일 마감, 아직 active)
  --     조건은 get_promo_digest_targets 의 deadline_d1_campaigns CTE 와 완전 동기화
  -- ──────────────────────────────────────────────────────────
  deadline_d1_campaigns AS (
    SELECT
      c.id,
      c.deadline
    FROM public.campaigns c
    WHERE c.status = 'active'
      AND c.deadline = CURRENT_DATE + 1
      AND (
        c.recruit_type <> 'monitor'
        OR (
          SELECT COUNT(*)
            FROM public.applications a
           WHERE a.campaign_id = c.id
             AND a.status = 'approved'
        ) < c.slots
      )
  ),

  -- ──────────────────────────────────────────────────────────
  -- [C] 신규 캠페인 집계 — ID 배열(마감일 오름차순) + 총수
  --     Edge Function 이 전체 배열을 받아 카드 5건 상한은 자체 처리
  --     (get_promo_digest_targets 는 [1:5] 슬라이스지만 관리자 풀은
  --      상한 없이 전체 반환 — 관리자 메일에서 「他 N件」 안내를 정확히 표시하기 위함)
  -- ──────────────────────────────────────────────────────────
  new_agg AS (
    SELECT
      array_agg(id ORDER BY deadline ASC) AS campaign_ids,
      COUNT(*)::integer                   AS total_count
    FROM new_campaigns
  ),

  -- ──────────────────────────────────────────────────────────
  -- [D] D-1 임박 캠페인 집계 — ID 배열(마감일 오름차순) + 총수
  -- ──────────────────────────────────────────────────────────
  d1_agg AS (
    SELECT
      array_agg(id ORDER BY deadline ASC) AS campaign_ids,
      COUNT(*)::integer                   AS total_count
    FROM deadline_d1_campaigns
  )

  -- ──────────────────────────────────────────────────────────
  -- [E] 최종 반환 — 단일 행 (항상 1행 반환, 캠페인 없으면 빈 배열)
  --     COALESCE 로 NULL → 빈 배열 처리 (Edge Function 안전)
  -- ──────────────────────────────────────────────────────────
  SELECT
    COALESCE(na.campaign_ids,   '{}')  AS new_campaign_ids,
    COALESCE(na.total_count,    0)     AS new_total_count,
    COALESCE(da.campaign_ids,   '{}')  AS deadline_d1_campaign_ids,
    COALESCE(da.total_count,    0)     AS deadline_d1_total_count
  FROM (SELECT 1) dummy  -- 집계 결과가 0건이어도 반드시 1행 반환
  LEFT JOIN new_agg na ON true
  LEFT JOIN d1_agg  da ON true;
$$;

-- PUBLIC·anon 직접 호출 차단 (service_role 은 RLS 우회로 자동 실행)
REVOKE EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) FROM PUBLIC, anon;
-- authenticated GRANT: 운영자 수동 트리거 + 스모크 호출 편의
GRANT  EXECUTE ON FUNCTION public.get_promo_digest_campaign_pool(date) TO authenticated;

COMMENT ON FUNCTION public.get_promo_digest_campaign_pool(date) IS
  '[152] 관리자 홍보 메일용 캠페인 풀 조회. '
  '신규·D-1 섹션 캠페인 ID 배열 + 총수 반환. '
  'get_promo_digest_targets 와 캠페인 선정 조건 동기화. '
  '인플 개인화 조건(채널 매칭·팔로워·응모/노출/클릭 제외) 없음 — 관리자는 풀 전체. '
  'SECURITY DEFINER + search_path 고정.';


COMMIT;
