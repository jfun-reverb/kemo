-- ============================================================
-- 312_influencers_admin_view_lockdown.sql
-- 전수조사 후속 조치 묶음 E — E-2: 원본 표(influencers) 관리자 조회 허가를
-- 가림막 통로(influencers_admin_view, 마이그레이션 212)만 남기고 좁힌다.
--
-- 근거: docs/research/2026-08-07-codebase-audit-findings.md §1-3
--   "influencers_select_admin(「관리자면 통과」)이 한 번도 삭제·교체되지 않았다.
--    가림막 뷰(212)는 원본 표의 정책을 그대로 상속하는 방식이라, 원본을 직접
--    부르면 마스킹을 안 거친다." — 즉 지금은 campaign_manager 를 포함한 모든
--    관리자가 PostgREST 로 /rest/v1/influencers 를 직접 불러 전화·LINE·PayPal·
--    우편번호·건물·상세주소를 뷰의 마스킹 없이 그대로 받을 수 있다.
-- 조치 계획: docs/specs/2026-08-07-audit-remediation-plan.md 묶음 E, E-2
--   (⚠️ E-1이 먼저 되어 있어야 한다 — 이 파일 시점에 dev/js/admin-applications.js·
--   admin-brand-ops.js 의 원본 표 직접 호출 3곳은 이미 influencers_admin_view 로
--   교체돼 있음, 커밋 전 워킹트리 확인 완료).
--
-- ────────────────────────────────────────────────────────────
-- 왜 "정책만 좁히기"로 끝나지 않는가 — 뷰와 표가 RLS 를 공유하는 구조적 결합
-- ────────────────────────────────────────────────────────────
-- influencers_admin_view(212)는 `WITH (security_invoker = true)` 로 만들어졌다.
-- PostgreSQL 의 security_invoker 뷰는 "뷰를 부른 사람의 권한으로 그 사람이 직접
-- 원본 표를 조회한 것"과 동일하게 행 단위 보안 정책(RLS)을 평가한다 — 뷰를
-- 거쳤다는 사실 자체는 RLS 판정에 아무 영향을 주지 않는다. 즉 지금 구조에서는
-- "원본 표 직접 조회"와 "뷰를 통한 조회"가 **같은 RLS 정책을 100% 공유**한다.
--
-- 그래서 단순히 influencers_select_admin(「관리자면 통과」) 정책만 지우면:
--   - 원본 표 직접 조회 → (의도대로) 막힘
--   - 뷰를 통한 조회도 → **똑같이 막힌다** (뷰가 기대는 유일한 관리자 가시성 규칙이
--     바로 이 정책이었으므로). 관리자 화면(인플루언서 목록·신청 승인·운영현황)이
--     전부 빈 화면이 된다.
--
-- "원본은 좁히고 뷰만 살린다"는 요구는 security_invoker=true 로는 구조적으로
-- 불가능하다 — 뷰와 표가 같은 RLS 평가를 쓰는 한 항상 함께 움직인다.
--
-- 검토한 방향과 기각 이유:
--   ① 뷰를 정의자(SECURITY DEFINER류) 권한으로 바꾸고 뷰 안에 명시적 is_admin()
--      조건을 넣는다 → **채택**. 아래 참고.
--   ② 열 단위 권한(GRANT SELECT (컬럼목록))으로 phone 등 6종만 원본 표에서 차단한다
--      → 기각. security_invoker=true 인 뷰는 열람 시 "부른 사람"의 권한으로 원본
--      표의 컬럼 권한도 함께 검사한다. CASE WHEN 마스킹 식은 조건이 거짓일 때도
--      phone 컬럼을 표현식 안에서 **참조는 한다**(결과를 버릴 뿐) — 그 컬럼에 대한
--      SELECT 권한 자체가 없으면 참조 시점에 42501 로 뷰가 통째로 깨진다. 마스킹을
--      하고 싶어서 뺀 컬럼이 뷰 자체를 못 쓰게 만드는 역설.
--   ③ 정의자 권한 함수(RPC)로 새 조회 통로를 만들고 정책은 본인만 남긴다
--      → 기각(이번엔 아님). 화면 코드가 이미 `.from('influencers_admin_view')`
--      로 맞춰져 있다(E-1). RPC 로 바꾸면 5개 호출부(storage.js 2곳 +
--      admin-applications.js 2곳 + admin-brand-ops.js 1곳)를 전부 다시 고쳐야
--      한다. ①이 정확히 같은 보호 수준을 "뷰"라는 기존 그릇 안에서 주므로,
--      호출부를 안 건드리는 ①이 되돌리기도 더 쉽다(그릇은 그대로, 안의 정의만
--      바뀜 — CREATE OR REPLACE VIEW 로 원복 가능).
--
-- ① 을 택하면 마이그레이션 212 의 명시적 결정("정의자 권한으로 만들면 RLS 를
-- 완전히 우회해버린다")을 뒤집는 셈이다. 212 가 경계했던 위험은 "무조건 뒤집으면
-- 위험하다"이지, "뒤집으면 항상 틀리다"가 아니다 — 위험의 실체는 "RLS 가 하던
-- 판정을 뷰 정의 안에 명시적으로 재현하지 않고 뷰를 정의자로 바꾸는 것"이다.
-- 이 마이그레이션은 정확히 그 판정(`is_admin()`)을 뷰의 WHERE 절에 1:1 로
-- 그대로 옮겨 적는다 — 원본 표에서 "관리자면 통과"로 보이던 행 집합과, 이 뷰가
-- "관리자면 통과"로 보여주는 행 집합이 여전히 동일하다. 달라지는 건 그 판정이
-- 어디서 집행되는가(RLS → 뷰 SQL 자체)뿐이다. 오히려 지금은 "관리자면 통과"
-- 규칙이 RLS 정책 한 줄에 묻혀 있어 이번 전수조사 전까지 아무도 원본 표
-- 직접조회 경로를 못 봤다 — 뷰 안에 명시하면 CREATE VIEW 정의 한 곳만 읽어도
-- 판정 전체가 보인다(더 낮은 발견 비용).
--
-- 뷰가 정의자 권한이 되면 원본 표에 대해 RLS 를 통째로 우회하는(=표 소유자 권한)
-- 것은 사실이다 — 그래서 뷰의 WHERE 절이 유일한 방어선이 된다. 이 파일의 SECTION 2
-- 가 그 방어선(`WHERE (SELECT public.is_admin())`)을 뷰 정의와 같은 트랜잭션에
-- 반드시 포함한다.
--
-- ────────────────────────────────────────────────────────────
-- 이 마이그레이션이 하는 일
-- ────────────────────────────────────────────────────────────
-- 1. influencers_select_admin 정책 삭제 — 원본 표 SELECT 는 이제
--    influencers_select_own(본인) 하나만 남는다. 관리자가 원본 표를 직접
--    조회하면(자기 자신의 인플루언서 행이 없는 한) 0행.
-- 2. influencers_admin_view 를 재정의 — WITH (security_invoker = false) 로
--    전환 + WHERE (SELECT public.is_admin()) 명시. 컬럼 목록·마스킹 CASE 6종·
--    존재 여부 불리언 3종은 212 그대로 1글자도 안 바꿈(변경 지점을 좁혀서
--    회귀 위험 최소화).
--
-- ────────────────────────────────────────────────────────────
-- 영향받지 않는 것 (grep 으로 전수 확인, 2026-08-07)
-- ────────────────────────────────────────────────────────────
-- - 인플루언서 본인 조회 5곳 — auth.js:174, app.js:380·430, notifications.js:26,
--   mypage.js:25 — 전부 원본 표를 `eq('id', currentUser.id)` 로 조회하고
--   influencers_select_own(auth.uid()=id) 로 통과한다. 이 마이그레이션이
--   건드리는 건 influencers_select_admin 뿐이라 무관.
-- - 관리자 화면 5곳(storage.js 의 fetchInfluencers/fetchInfluencersByIds +
--   admin-applications.js 2곳 + admin-brand-ops.js 1곳) — 전부 이미
--   `influencers_admin_view` 를 쓴다(E-1). 뷰가 정의자 권한 + 명시적
--   is_admin() 판정으로 바뀌어도 "관리자면 전체, 마스킹은 권한별" 이라는
--   응답 내용은 이전과 동일 — 화면 쪽 코드 변경 불필요.
-- - 인증/블랙리스트/위반 RPC 4종(set_influencer_verified/set_influencer_blacklist/
--   record_influencer_violation/update_influencer_violation, 마이그레이션
--   059~062) — 전부 SECURITY DEFINER 함수 안에서 `UPDATE/SELECT public.influencers`
--   를 직접 실행한다. SECURITY DEFINER 함수는 함수 소유자(테이블 소유자와 동일,
--   이 프로젝트는 FORCE ROW LEVEL SECURITY 를 어디에도 걸지 않았음 — 전수 grep
--   확인)의 권한으로 실행되어 원래도 RLS 를 우회하고 있었다. 이번에 SELECT
--   정책을 좁혀도 이 RPC 들의 동작은 그 전과 100% 동일.
--
-- 롤백: 파일 하단.
-- ============================================================

-- ============================================================
-- SECTION 1. 원본 표 SELECT 정책 좁히기
-- ============================================================
DROP POLICY IF EXISTS "influencers_select_admin" ON public.influencers;

COMMENT ON POLICY "influencers_select_own" ON public.influencers IS
  '[312] influencers 원본 표 SELECT 는 이제 본인 행(auth.uid()=id)만. 관리자가 '
  '다른 사람의 인플루언서 행을 보려면 influencers_admin_view(가림막, 마이그레이션 '
  '212·312) 를 거쳐야 한다 — 그 뷰는 이제 정의자 권한이라 이 표의 RLS 와 별개로 '
  '자체 WHERE (SELECT public.is_admin()) 로 관리자 가시성을 판정한다.';

-- ============================================================
-- SECTION 2. 가림막 뷰를 정의자 권한으로 전환 + 관리자 판정 명시
--   컬럼 목록·마스킹 CASE 6종·존재 여부 불리언 3종은 마이그레이션 212 와
--   1글자도 다르지 않음(diff 대상은 WITH 옵션 + WHERE 절 추가뿐).
-- ============================================================
CREATE OR REPLACE VIEW public.influencers_admin_view
  WITH (security_invoker = false)
AS
SELECT
  -- ── 식별·기본 정보 (마스킹 없음) ──────────────────────────
  -- ⚠️ pw · bank_* 레거시 컬럼은 뷰에서 제외(212 결정 유지, 216 에서 표 자체에서도 삭제됨)
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

FROM public.influencers
-- ⚠️ 이 WHERE 가 이제 이 뷰의 유일한 행 가시성 방어선이다(뷰가 정의자 권한이라
--    원본 표 RLS 를 우회하므로). is_admin() 이 거짓이면 이 뷰는 그 세션에
--    아무 행도 내보내지 않는다 — 원본 표 직접조회가 본인 행만 보이는 것과
--    별개로, 이 뷰는 "관리자 전용" 통로 그 자체다(본인 조회는 여전히 원본
--    표 직접 조회 경로를 쓰므로 이 뷰를 거칠 필요가 없다).
WHERE (SELECT public.is_admin());

COMMENT ON VIEW public.influencers_admin_view IS
  '관리자용 인플루언서 가림막 뷰. [312] security_invoker=false(정의자 권한)로 전환 — '
  'WHERE (SELECT public.is_admin()) 를 뷰 정의 안에 명시해 원본 표 RLS 와 무관하게 '
  '"관리자만" 행을 반환한다(원본 표 influencers_select_admin 정책은 312 에서 삭제됨, '
  '원본 표 직접조회는 이제 본인 행만 가능). phone/line_id/paypal_email/zip/'
  'building/address 6종은 has_permission(influencer.sensitive_pii, read) 가 false 인 '
  '관리자 등급(예: campaign_manager)에게 NULL 마스킹(212 그대로). has_phone/has_line/'
  'has_paypal 3종은 마스킹 무관 항상 실제 존재 여부.';

GRANT SELECT ON public.influencers_admin_view TO authenticated;

-- ⚠️ 이중 안전장치: CREATE OR REPLACE VIEW 의 WITH(...) 절이 기존 리로션(reloption)을
--    확실히 덮어쓰는지가 PostgreSQL 버전에 따라 애매할 수 있어(문서에 "컬럼 목록은
--    이전과 같아야 한다"만 명시돼 있고 reloption 갱신 여부는 명시가 약함), 위
--    CREATE OR REPLACE 직후 ALTER VIEW ... SET 으로 한 번 더 못박는다. 이미
--    security_invoker=false 로 적용됐다면 이 문장은 아무 것도 안 바꾸는 no-op.
ALTER VIEW public.influencers_admin_view SET (security_invoker = false);

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 구조 확인 (이건 SQL 편집기로 해도 된다 — 메타데이터 조회일 뿐 RLS 판정을
-- 우회해서 보는 게 아니다. reloptions 에 security_invoker=false 가 찍혀야 한다)
-- ============================================================
-- SELECT relname, reloptions FROM pg_class WHERE relname = 'influencers_admin_view';

-- ============================================================
-- 행동 검증 (SQL 편집기로는 불가능 — 편집기 세션은 RLS 를 우회하는 서비스 키로
-- 돌기 때문에 "정책이 막는지" 자체를 관찰할 수 없다. 반드시 실제 로그인
-- 세션 기준으로 확인한다.)
-- ============================================================
-- 1. 브라우저에서 campaign_manager 등급 관리자 계정으로 로그인 후,
--    개발자 도구 콘솔에서 Supabase 클라이언트로 원본 표를 직접 조회:
--      await db.from('influencers').select('*').limit(5)
--    → data 가 빈 배열([])이어야 한다(본인 소유 인플루언서 행이 없다면).
--    관리자 계정은 보통 별도 auth.users 행이라 influencers 행이 없는 게
--    정상이므로 0행이 기대값이다.
--
-- 2. 같은 세션에서 인플루언서 목록 화면(#adminPane-influencers) 을 열어
--    목록이 정상 노출되는지 확인 — 뷰(influencers_admin_view) 경유라
--    campaign_manager 도 명단은 보이되(has_permission 기본 read 등급이면
--    민감정보만 마스킹), 화면 자체가 비지 않아야 한다.
--
-- 3. 신청 승인(펜딩 → 승인) 1건을 campaign_manager 계정으로 처리해
--    admin-applications.js 의 감사용 계정 판정(is_audit 조회)이 오류 없이
--    동작하는지 확인 — 오류 토스트 없이 정상 승인되면 OK.
--
-- 4. 브랜드 서베이 운영현황(#adminPane-brand-dashboard) 진입 시 감사용
--    인원 집계가 오류 없이 로드되는지 확인(admin-brand-ops.js:212 경유).
--
-- 5. 인플루언서 앱에서 테스트 계정(sakura.test@reverb.jp 등)으로 로그인해
--    정상 로그인 + 마이페이지 진입을 확인 — 원본 표 직접조회(본인) 경로가
--    이 마이그레이션으로 전혀 안 바뀌었으므로 실패하면 이 마이그레이션이
--    아니라 다른 원인이다(회귀 아님을 구분하기 위한 대조군 확인).
-- ============================================================

-- ============================================================
-- 롤백
-- ============================================================
-- CREATE POLICY "influencers_select_admin"
--   ON public.influencers FOR SELECT
--   USING (public.is_admin());
--
-- CREATE OR REPLACE VIEW public.influencers_admin_view
--   WITH (security_invoker = true)
-- AS
-- SELECT
--   id, email, name, ig, x, followers, category, bio, created_at,
--   name_kanji, name_kana, ig_followers, x_followers, tiktok, tiktok_followers,
--   youtube, youtube_followers, prefecture, city, primary_sns,
--   terms_agreed_at, privacy_agreed_at, marketing_opt_in, marketing_agreed_at,
--   is_verified, verified_at, verified_by, is_blacklisted, blacklisted_at,
--   blacklisted_by, blacklist_reason_code, blacklist_reason_note,
--   unsubscribe_token, marketing_unsubscribed_at, is_audit, birthdate, gender,
--   age_consent_at,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN phone ELSE NULL END AS phone,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN line_id ELSE NULL END AS line_id,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN paypal_email ELSE NULL END AS paypal_email,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN zip ELSE NULL END AS zip,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN building ELSE NULL END AS building,
--   CASE WHEN (SELECT public.has_permission('influencer.sensitive_pii', 'read'))
--        THEN address ELSE NULL END AS address,
--   (phone IS NOT NULL AND phone <> '')                 AS has_phone,
--   (line_id IS NOT NULL AND line_id <> '')             AS has_line,
--   (paypal_email IS NOT NULL AND paypal_email <> '')   AS has_paypal
-- FROM public.influencers;
--
-- ALTER VIEW public.influencers_admin_view SET (security_invoker = true);
-- GRANT SELECT ON public.influencers_admin_view TO authenticated;
-- NOTIFY pgrst, 'reload schema';
--
-- ⚠️ 롤백하면 마이그레이션 212 이전과 동일하게 원본 표 직접조회로 민감정보
--    마스킹을 우회할 수 있는 상태로 되돌아간다 — 임시 조치로만 사용할 것.
-- ============================================================
