-- ============================================================
-- 214_role_permissions_default_level.sql
-- 관리자 동적 권한 관리 「기본값 복원」 PR1 — 1/2 (데이터베이스: 컬럼 추가 + 백필)
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--
-- 목적:
--   role_permissions 각 행(role × feature_key)에 "이 기능의 기본값이 원래 무엇인가"를
--   같은 테이블 컬럼(default_level)으로 저장한다. PR2(설정 화면)의 「기본값 복원」 버튼이
--   access_level ≠ default_level 인 셀만 하이라이트하고, 전용 RPC(마이그레이션 215)가
--   그 값들을 default_level 로 되돌린다.
--
-- 백필값 = "현재 의도(intended baseline)" — 아래 두 소스를 명시적으로 옮긴 것이며
--   실행 시점의 라이브 access_level 을 그대로 복사하지 않는다(작업 전 super_admin 이
--   개발 그리드를 실험 저장했을 수 있어 라이브 값은 신뢰할 근거가 아님):
--     ① 마이그레이션 207_role_permissions.sql SECTION 3 시드 72행 (feature_key 36개 × 2등급)
--     ② 마이그레이션 211_role_permissions_save.sql SECTION 2 시드 2행 (menu.permissions × 2등급)
--   → 합쳐서 feature_key 37개 × 2등급 = 74행. 단 1곳 예외:
--     - influencer.sensitive_pii, campaign_manager: 207 원본 시드는 'read' 였으나
--       마이그레이션 213_activate_pii_masking.sql 이 실제로 'hidden' 으로 낮춰 서버 차단을
--       발동시켰다(2026-07-06 사용자 결정). "기본값" 은 213 이후의 현재 의도이므로
--       campaign_manager 의 default_level 은 'hidden' 으로 백필한다
--       (campaign_admin 은 213 영향 없음 — 그대로 'read').
--
-- denylist 3개(permissions.manage · admin.manage · menu.permissions) 의 기본값은
--   두 등급 모두 'hidden' — 207/211 시드 원문 그대로, 변경 없음.
--
-- 멱등성: ADD COLUMN IF NOT EXISTS + UPDATE(값 지정) + DROP/ADD CONSTRAINT 패턴(180 참고) +
--   SET NOT NULL 은 매번 재적용해도 안전(이미 NOT NULL 이면 no-op). 재실행 안전.
--
-- ⚠️ 안전장치: 아래 백필 UPDATE 이후 default_level 이 NULL 로 남은 행이 있으면(=이
--   테이블에 37개 카탈로그 밖의 feature_key 가 존재 = 데이터 드리프트) 맨 아래
--   SET NOT NULL 단계에서 즉시 에러로 멈춘다. 자동으로 잘못된 값을 채우지 않고
--   드리프트를 사람이 확인하게 하기 위한 의도적 설계 — 에러가 나면 해당 feature_key를
--   role_permissions 에서 직접 조회해 원인을 먼저 파악할 것.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. 컬럼 추가 (nullable로 시작 — 백필 후 NOT NULL 전환)
-- ============================================================
ALTER TABLE public.role_permissions
  ADD COLUMN IF NOT EXISTS default_level text;

COMMENT ON COLUMN public.role_permissions.default_level IS
  '이 기능(role × feature_key)의 "기본값" — 최초 시드(207/211) + 213 반영(campaign_manager의 '
  'influencer.sensitive_pii만 hidden) 기준 baseline. access_level 과 다르면 관리자가 커스터마이즈한 '
  '상태. restore_role_permissions_defaults() RPC(마이그레이션 215)가 이 값으로 access_level 을 되돌림. '
  '⚠️ 향후 정책 변경 마이그레이션(213처럼 access_level 을 의도적으로 바꾸는 것)은 반드시 이 컬럼도 '
  '함께 UPDATE 할 것 — 안 하면 그 정책 변경이 "복원" 버튼 한 번에 도로 풀려버린다(드리프트).';

-- ============================================================
-- 2. 백필 — 명시적 매핑 (마이그레이션 207 SECTION 3 + 211 SECTION 2 시드값 그대로 이관)
-- ============================================================
WITH baseline(feature_key, campaign_admin_default, campaign_manager_default) AS (
  VALUES
    -- ── 메뉴(페인) 20개 — 207 SECTION 3 19개 + 211 SECTION 2 menu.permissions 1개 ──
    ('menu.admin-notices',       'write',  'write'),
    ('menu.upcoming',            'write',  'write'),
    ('menu.dashboard',           'write',  'write'),
    ('menu.brand-ops',           'write',  'write'),
    ('menu.campaigns',           'write',  'write'),
    ('menu.applications',        'write',  'write'),
    ('menu.deliverables',        'write',  'write'),
    ('menu.messages',            'write',  'write'),
    ('menu.brand-dashboard',     'write',  'write'),
    ('menu.companies',           'write',  'write'),
    ('menu.brands',              'write',  'write'),
    ('menu.orient-sheets',       'write',  'write'),
    ('menu.brand-applications',  'write',  'write'),
    ('menu.influencers',         'write',  'write'),
    ('menu.lookups',             'write',  'hidden'),
    ('menu.faq',                 'write',  'hidden'),
    ('menu.admin-accounts',      'write',  'write'),
    ('menu.errors',              'write',  'write'),
    ('menu.my-account',          'write',  'write'),
    ('menu.permissions',         'hidden', 'hidden'),  -- 211 시드(설계상 super_admin 전용)

    -- ── 주요 기능 17개 — 207 SECTION 3 그대로 (단, 아래 1행은 213 반영해 예외 적용) ──
    -- influencer.sensitive_pii: 207 원본 시드는 (read, read) 였으나 213이 campaign_manager를
    --   hidden 으로 낮춰 실제 차단을 발동함(2026-07-06). "기본값" = 213 이후 현재 의도이므로
    --   여기서는 campaign_admin=read(불변) / campaign_manager=hidden(213 반영) 으로 명시.
    ('influencer.sensitive_pii',      'read',   'hidden'),
    ('influencer.excel_sensitive',    'write',  'hidden'),
    ('influencer.flag',               'write',  'hidden'),
    ('deliverable.receipt_edit',      'write',  'hidden'),
    ('deliverable.proxy_create',      'write',  'hidden'),
    ('company.cud',                   'write',  'hidden'),
    ('brand.delete_merge',            'write',  'hidden'),
    ('lookup.cud',                    'write',  'hidden'),
    ('faq.cud',                       'write',  'hidden'),
    ('message.bulk_send',             'write',  'hidden'),
    ('message.hide',                  'write',  'hidden'),
    ('message.unhide',                'hidden', 'hidden'),
    ('notice.create',                 'write',  'hidden'),
    ('notice.manage_others',          'hidden', 'hidden'),
    ('campaign.caution_history_view', 'hidden', 'hidden'),
    ('admin.manage',                  'hidden', 'hidden'),
    ('permissions.manage',            'hidden', 'hidden')
)
UPDATE public.role_permissions rp
SET default_level = CASE rp.role
                       WHEN 'campaign_admin'   THEN baseline.campaign_admin_default
                       WHEN 'campaign_manager' THEN baseline.campaign_manager_default
                     END
FROM baseline
WHERE rp.feature_key = baseline.feature_key
  AND rp.default_level IS NULL;  -- 재실행 시 이미 채워진 행은 건드리지 않음(멱등)

-- ============================================================
-- 3. CHECK 제약 (180_age_policy.sql DROP→ADD 패턴 — 재실행 안전)
-- ============================================================
ALTER TABLE public.role_permissions
  DROP CONSTRAINT IF EXISTS role_permissions_default_level_check;
ALTER TABLE public.role_permissions
  ADD CONSTRAINT role_permissions_default_level_check
    CHECK (default_level IN ('write', 'read', 'hidden'));

-- ============================================================
-- 4. NOT NULL 전환 — 백필 누락 행이 있으면 여기서 에러로 멈춤(의도된 안전장치, 상단 설명 참고)
-- ============================================================
ALTER TABLE public.role_permissions
  ALTER COLUMN default_level SET NOT NULL;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 컬럼·제약 확인
SELECT column_name, is_nullable, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'role_permissions' AND column_name = 'default_level';
-- 기대: is_nullable = 'NO'

-- [V1] 전체 행 수 확인 (37 feature_key × 2 role = 74)
SELECT count(*) FROM public.role_permissions;
-- 기대: 74

-- [V2] default_level NULL 인 행이 없는지 (0건이어야 정상 — SET NOT NULL 이 이미 보증하지만 재확인)
SELECT count(*) FROM public.role_permissions WHERE default_level IS NULL;
-- 기대: 0

-- [V3] 213 반영 확인 — campaign_manager의 influencer.sensitive_pii는 access_level='hidden',
--   default_level도 'hidden'(둘 다 같아야 "복원 필요 없음" 상태)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key = 'influencer.sensitive_pii'
ORDER BY role;
-- 기대: campaign_admin  read/read,  campaign_manager  hidden/hidden

-- [V4] denylist 3개 기본값 확인 (모두 hidden/hidden)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE feature_key IN ('permissions.manage', 'admin.manage', 'menu.permissions')
ORDER BY feature_key, role;

-- [V5] 지금 시점 access_level 과 default_level 이 다른 행 = 이미 커스터마이즈된 셀
--   (개발 DB에서 실험 저장한 적 있으면 여기 나타남 — 정상, PR2 "복원" 버튼 대상)
SELECT role, feature_key, access_level, default_level
FROM public.role_permissions
WHERE access_level <> default_level
ORDER BY feature_key, role;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- ALTER TABLE public.role_permissions ALTER COLUMN default_level DROP NOT NULL;
-- ALTER TABLE public.role_permissions DROP CONSTRAINT IF EXISTS role_permissions_default_level_check;
-- ALTER TABLE public.role_permissions DROP COLUMN IF EXISTS default_level;
-- NOTIFY pgrst, 'reload schema';
