-- ============================================================
-- 212_influencers_admin_view.sql
-- 관리자 동적 권한 관리 PR3 조각 A — 인플루언서 민감정보 가림막 뷰
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--
-- 배경(갭1): has_permission('influencer.sensitive_pii') 은 PR1(마이그레이션 207~210)
--   에서 이미 만들어졌지만, 실제로 관리자 화면·조회 함수 어디도 이 값을 참조하지
--   않는다. 그 결과 campaign_manager(권한 시드값 'read')도 campaign_admin 과 똑같이
--   민감정보 6종을 전부 열람할 수 있는 상태다 — 이게 "화면 토글만 있고 실제 차단은
--   없는" 갭1.
--
-- 이번 마이그레이션(PR3 조각 A, 2026-07-06 결정)은 **가림막 뷰 방식**으로 갭1을 막는
-- 인프라만 추가한다. 이 파일 하나만으로는 서비스 동작이 전혀 바뀌지 않는다:
--   - 아직 dev/lib/storage.js 의 조회 함수는 base 테이블 public.influencers 를 그대로
--     조회한다 (조회 경로를 이 뷰로 바꾸는 건 PR3 조각 B).
--   - role_permissions 시드값도 campaign_admin='read', campaign_manager='read' 로
--     동일하다 (campaign_manager 를 실제로 낮추는 건 PR3 조각 C).
--   - 즉 이번 조각은 "뷰가 존재하고 컬럼·마스킹 로직이 정확한지"만 검증 대상이다.
--
-- 뷰 이름 확정: influencers_admin_view (기존 CLAUDE.md/PANE_REFRESHERS 의
--   admin-influencers 페인과 이름을 맞춤. 기존 유일한 선례 application_message_summary
--   는 "요약 집계" 성격이라 이름 패턴이 다르고, 이 뷰는 "관리자가 보는 influencers 원본
--   + 마스킹"이라 _admin_view 가 의도를 더 정확히 드러낸다).
--
-- security_invoker = true 필수 이유: 이 뷰가 SECURITY DEFINER 뷰(기본값 false)로
--   생성되면 뷰 소유자(보통 postgres)의 권한으로 실행되어 public.influencers 의
--   행 단위 보안 정책(RLS)을 완전히 우회해버린다. security_invoker=true 로 만들면
--   뷰를 호출한 사람(=로그인한 관리자 또는 인플루언서 본인) 의 권한으로 실행되어,
--   기존 influencers_select_admin(is_admin()) / influencers_select_own(auth.uid()=id)
--   RLS 정책이 뷰를 통해서도 그대로 적용된다 — "관리자만 전체 조회, 본인은 자기 행만"
--   유지. 참고: application_message_summary(마이그레이션 144)도 같은 옵션 사용.
--
-- 마스킹 대상 6종 (사용자 확정 — 엑셀 민감정보 기준과 동일):
--   phone, line_id, paypal_email, zip, building, address
--   → CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii','read'))
--          THEN <컬럼> ELSE NULL END
--   (SELECT ...) 로 감싸는 이유: has_permission 은 STABLE SECURITY DEFINER 함수라
--   행마다 다시 평가해도 결과가 똑같다(현재 로그인한 관리자·요청 시점은 쿼리 전체에서
--   불변). 스칼라 서브쿼리로 감싸면 PostgreSQL 플래너가 InitPlan(쿼리 시작 시 1회
--   평가 후 캐시)으로 승격시켜, influencers 가 수천 행이어도 함수가 행 수만큼
--   반복 호출되지 않는다. 마이그레이션 137((SELECT auth.uid()) 패턴)과 동일한 최적화.
--
-- 존재 여부 불리언 3종(has_phone/has_line/has_paypal): 마스킹과 무관하게 항상 실제
--   값을 노출한다. campaign_manager 처럼 실제 값(전화번호 자체)은 못 보더라도
--   "등록/미등록" 배지나 필터(예: PayPal 미등록자만 보기)는 계속 동작해야 하기 때문.
--   zip/building/address 는 대응하는 별도 boolean 을 만들지 않았다(사용자 확정 사양에
--   3종만 명시 — 필요해지면 후속 조각에서 추가 가능, 이 마이그레이션에는 포함하지 않음).
--
-- 컬럼 전체 목록: 2026-07-06 기준 개발 데이터베이스(qysmxtipobomefudyixw)
--   information_schema.columns 실측(50개 컬럼) 그대로 나열 — 아래 SECTION 1 참고.
--   특히 마이그레이션 179(is_audit) · 180(gender/birthdate) · 185(age_consent_at) ·
--   140(unsubscribe_token/marketing_unsubscribed_at) 신규 컬럼이 빠지지 않았는지
--   실측으로 재확인함(문서만 보고 나열하면 최신 컬럼이 누락될 위험이 있어 실제 DB 조회).
--
-- 이번 마이그레이션에 포함되지 않은 것(다른 조각 몫):
--   - dev/lib/storage.js 조회 경로를 이 뷰로 바꾸는 작업 (PR3 조각 B)
--   - campaign_manager 의 influencer.sensitive_pii 를 실제로 'hidden'/'read' 낮추는
--     역할 설정 변경 (PR3 조각 C, role_permissions UPDATE 또는 관리자 화면에서 직접 저장)
--   - influencer.excel_sensitive 관련 엑셀 다운로드 서버측 가드 (별도 조각)
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- SECTION 1. 가림막 뷰 생성
-- ============================================================
CREATE OR REPLACE VIEW public.influencers_admin_view
  WITH (security_invoker = true)
AS
SELECT
  -- ── 식별·기본 정보 (마스킹 없음) ──────────────────────────
  -- ⚠️ pw · bank_* 레거시 컬럼은 뷰에서 제외(SELECT 안 함, 2026-07-06 결정):
  --   코드 미사용 + 비밀번호·계좌라는 민감정보 → 어느 관리자 등급에도 노출 불필요.
  --   base 테이블에는 남아있으나(개발 DB 실측 0건) 관리자 조회 뷰로는 아예 안 내보냄.
  id,
  email,
  name,
  ig,
  x,
  followers,
  category,
  bio,
  created_at,
  name_kanji,
  name_kana,
  ig_followers,
  x_followers,
  tiktok,
  tiktok_followers,
  youtube,
  youtube_followers,
  prefecture,
  city,
  primary_sns,
  terms_agreed_at,
  privacy_agreed_at,
  marketing_opt_in,
  marketing_agreed_at,
  is_verified,
  verified_at,
  verified_by,
  is_blacklisted,
  blacklisted_at,
  blacklisted_by,
  blacklist_reason_code,
  blacklist_reason_note,
  unsubscribe_token,
  marketing_unsubscribed_at,
  is_audit,
  birthdate,
  gender,
  age_consent_at,

  -- ── 마스킹 대상 6종 ────────────────────────────────────────
  -- (SELECT ...) 스칼라 서브쿼리로 감싸 InitPlan 1회 평가(마이그레이션 137 패턴)
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN phone ELSE NULL END AS phone,
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN line_id ELSE NULL END AS line_id,
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN paypal_email ELSE NULL END AS paypal_email,
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN zip ELSE NULL END AS zip,
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN building ELSE NULL END AS building,
  CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
       THEN address ELSE NULL END AS address,

  -- ── 존재 여부 불리언 3종 (마스킹과 무관하게 항상 실제 값) ──────
  (phone IS NOT NULL AND phone <> '')                 AS has_phone,
  (line_id IS NOT NULL AND line_id <> '')             AS has_line,
  (paypal_email IS NOT NULL AND paypal_email <> '')   AS has_paypal

FROM public.influencers;

COMMENT ON VIEW public.influencers_admin_view IS
  '관리자용 인플루언서 가림막 뷰. security_invoker=true 로 base 테이블 influencers 의 RLS '
  '(관리자 전체/본인 행만)를 호출자 기준 그대로 적용. phone/line_id/paypal_email/zip/'
  'building/address 6종은 has_permission(influencer.sensitive_pii, read) 가 false 인 '
  '관리자 등급(예: campaign_manager 낮춤 후)에게 NULL 마스킹. has_phone/has_line/has_paypal '
  '3종은 마스킹 무관 항상 실제 존재 여부. PR3 조각 A(2026-07-06) — 이 마이그레이션만으로는 '
  '조회 경로가 아직 이 뷰를 쓰지 않아 서비스 동작 변화 없음(PR3 조각 B·C 는 후속).';

GRANT SELECT ON public.influencers_admin_view TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 롤백
-- ============================================================
-- DROP VIEW IF EXISTS public.influencers_admin_view;
