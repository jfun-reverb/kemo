-- ============================================================
-- 207_role_permissions.sql
-- 관리자 동적 권한 관리 PR1 — 1/4
-- 사양서: docs/specs/2026-06-15-admin-permission-management.md
--         docs/specs/2026-06-15-admin-permission-matrix.md (§B = 이 시드의 단일 소스)
--
-- role_permissions: 등급(campaign_admin/campaign_manager) × 기능(feature_key)별
--   접근 수준(write>read>hidden)을 저장하는 설정 테이블.
--
-- ⚠️ 잠금 방지 (매우 중요): super_admin 행은 이 테이블에 절대 저장하지 않는다.
--   role CHECK 자체가 ('campaign_admin','campaign_manager')만 허용 — super_admin 삽입 시도는
--   제약 위반으로 즉시 실패한다. has_permission() 함수(마이그레이션 209)는 super_admin을
--   테이블 조회 전에 코드로 무조건 통과시키므로, 이 테이블에 어떤 값이 들어가도
--   super_admin 권한은 절대 축소되지 않는다(자기잠금 원천 차단).
--
-- ⚠️ 시드값은 "목표(future)" 가 아니라 "현재 상태(current)" 그대로다.
--   특히 인플루언서 민감정보(influencer.sensitive_pii)는 매트릭스 §B 갭1에서
--   campaign_manager 에게도 서버가 이미 열려있음(🔓)을 지적한 항목이라, 시드는
--   그 열린 상태(read/read)를 그대로 반영한다 — 이 마이그레이션은 아무것도 차단하지
--   않는다. 실제 차단은 2단계(PR3+, server_enforced=true 기능부터 점진 적용) 몫이다.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.role_permissions (
  role         text        NOT NULL CHECK (role IN ('campaign_admin', 'campaign_manager')),
  feature_key  text        NOT NULL,
  access_level text        NOT NULL CHECK (access_level IN ('write', 'read', 'hidden')),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  PRIMARY KEY (role, feature_key)
);

COMMENT ON TABLE public.role_permissions IS
  '관리자 등급(campaign_admin/campaign_manager)별 기능(feature_key) 접근 수준. '
  'super_admin 행은 절대 저장하지 않음(잠금 방지 — has_permission()이 코드로 무조건 통과시킴). '
  '카탈로그(feature_key 목록)의 단일 소스는 dev/lib/shared.js ADMIN_PERMISSION_CATALOG.';
COMMENT ON COLUMN public.role_permissions.feature_key IS
  'dev/lib/shared.js ADMIN_PERMISSION_CATALOG[].key 와 1:1 대응. 미등록 키는 has_permission()에서 안전측 거부(false).';
COMMENT ON COLUMN public.role_permissions.access_level IS
  'write(쓰기·전체) > read(읽기 전용) > hidden(숨김). 상위는 하위 포함.';
COMMENT ON COLUMN public.role_permissions.updated_by IS
  '마지막으로 이 행을 변경한 super_admin. PR1 시점에는 갱신 경로(RPC)가 없어 시드 삽입 시 NULL.';

-- ============================================================
-- 2. RLS
-- ============================================================
ALTER TABLE public.role_permissions ENABLE ROW LEVEL SECURITY;

-- SELECT: 전 관리자 (자기 등급의 권한을 알아야 화면 분기 가능)
CREATE POLICY role_permissions_select ON public.role_permissions
  FOR SELECT TO authenticated
  USING (is_admin());

-- CUD: super_admin만 (PR1에는 실제 저장 화면이 없어 이 정책은 PR2 그리드가 사용)
CREATE POLICY role_permissions_write ON public.role_permissions
  FOR INSERT TO authenticated
  WITH CHECK (is_super_admin());

CREATE POLICY role_permissions_update ON public.role_permissions
  FOR UPDATE TO authenticated
  USING (is_super_admin())
  WITH CHECK (is_super_admin());

CREATE POLICY role_permissions_delete ON public.role_permissions
  FOR DELETE TO authenticated
  USING (is_super_admin());

-- ============================================================
-- 3. 시드 — 매트릭스 §B "현재 상태" 열 그대로 (무변동)
--    feature_key 는 dev/lib/shared.js ADMIN_PERMISSION_CATALOG 와 1:1.
-- ============================================================
WITH seed(feature_key, campaign_admin_level, campaign_manager_level) AS (
  VALUES
    -- ── 메뉴(페인) 19개 — 사이드바 data-pane 노출 여부 그대로 ──
    -- (기준 데이터·FAQ만 campaign_manager 숨김 — admin-accounts.js:186 현행)
    ('menu.admin-notices',       'write', 'write'),
    ('menu.upcoming',            'write', 'write'),
    ('menu.dashboard',           'write', 'write'),
    ('menu.brand-ops',           'write', 'write'),
    ('menu.campaigns',           'write', 'write'),
    ('menu.applications',        'write', 'write'),
    ('menu.deliverables',        'write', 'write'),
    ('menu.messages',            'write', 'write'),
    ('menu.brand-dashboard',     'write', 'write'),
    ('menu.companies',           'write', 'write'),
    ('menu.brands',              'write', 'write'),
    ('menu.orient-sheets',       'write', 'write'),
    ('menu.brand-applications',  'write', 'write'),
    ('menu.influencers',         'write', 'write'),
    ('menu.lookups',             'write', 'hidden'),
    ('menu.faq',                 'write', 'hidden'),
    ('menu.admin-accounts',      'write', 'write'),
    ('menu.errors',              'write', 'write'),
    ('menu.my-account',          'write', 'write'),

    -- ── 주요 기능 17개 — 매트릭스 §B 「기능별 권한」 표 그대로 ──
    -- influencer.sensitive_pii: 갭1 — 현재 campaign_manager 도 서버에서 전부 열려있음(🔓).
    --   시드는 이 열린 상태 그대로(read/read). 차단은 2단계(PR3+) 몫.
    ('influencer.sensitive_pii',      'read',   'read'),
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
    -- message.unhide: 현행 super_admin 전용 — campaign_admin 도 불가
    ('message.unhide',                'hidden', 'hidden'),
    ('notice.create',                 'write',  'hidden'),
    -- notice.manage_others: 본인 작성분 외 타인 공지 관리는 현행 super_admin 전용
    ('notice.manage_others',          'hidden', 'hidden'),
    -- campaign.caution_history_view: 현행 super_admin 전용(campaign_caution_history SELECT)
    ('campaign.caution_history_view', 'hidden', 'hidden'),
    -- admin.manage: 현행 super_admin 전용(invite_admin/delete_admin_completely)
    ('admin.manage',                  'hidden', 'hidden'),
    -- permissions.manage: 신설 화면(PR2) 자체 접근 — 설계상 super_admin 전용
    ('permissions.manage',            'hidden', 'hidden')
)
INSERT INTO public.role_permissions (role, feature_key, access_level)
SELECT 'campaign_admin', feature_key, campaign_admin_level FROM seed
UNION ALL
SELECT 'campaign_manager', feature_key, campaign_manager_level FROM seed
ON CONFLICT (role, feature_key) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 롤백
-- ============================================================
-- DROP POLICY IF EXISTS role_permissions_select ON public.role_permissions;
-- DROP POLICY IF EXISTS role_permissions_write  ON public.role_permissions;
-- DROP POLICY IF EXISTS role_permissions_update ON public.role_permissions;
-- DROP POLICY IF EXISTS role_permissions_delete ON public.role_permissions;
-- DROP TABLE IF EXISTS public.role_permissions;
