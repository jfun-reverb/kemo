-- ============================================
-- REVERB JP — RLS (Row Level Security) 설정
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- ══════════════════════════════════════
-- 1. 모든 테이블에 RLS 활성화
-- ══════════════════════════════════════
ALTER TABLE campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE influencers ENABLE ROW LEVEL SECURITY;
ALTER TABLE applications ENABLE ROW LEVEL SECURITY;


-- ══════════════════════════════════════
-- 2. 헬퍼 함수: 관리자 판별
-- ══════════════════════════════════════
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT coalesce(auth.jwt() ->> 'email', '') = 'admin@kemo.jp';
$$;


-- ══════════════════════════════════════
-- 3. campaigns 정책
-- ══════════════════════════════════════

-- 누구나 조회 가능 (인플루언서가 캠페인 목록을 봄)
CREATE POLICY "campaigns_select_public"
  ON campaigns FOR SELECT
  USING (true);

-- 관리자만 등록 가능
CREATE POLICY "campaigns_insert_admin"
  ON campaigns FOR INSERT
  WITH CHECK (is_admin());

-- 관리자만 수정 가능
CREATE POLICY "campaigns_update_admin"
  ON campaigns FOR UPDATE
  USING (is_admin())
  WITH CHECK (is_admin());

-- 관리자만 삭제 가능
CREATE POLICY "campaigns_delete_admin"
  ON campaigns FOR DELETE
  USING (is_admin());


-- ══════════════════════════════════════
-- 4. influencers 정책
-- ══════════════════════════════════════

-- 관리자는 전체 조회 가능
CREATE POLICY "influencers_select_admin"
  ON influencers FOR SELECT
  USING (is_admin());

-- 본인만 자기 프로필 조회 가능
CREATE POLICY "influencers_select_own"
  ON influencers FOR SELECT
  USING (auth.uid() = id);

-- 인증된 사용자가 자기 프로필 생성 (회원가입 시)
CREATE POLICY "influencers_insert_own"
  ON influencers FOR INSERT
  WITH CHECK (auth.uid() = id);

-- 본인만 자기 프로필 수정 가능
CREATE POLICY "influencers_update_own"
  ON influencers FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- 삭제는 관리자만
CREATE POLICY "influencers_delete_admin"
  ON influencers FOR DELETE
  USING (is_admin());


-- ══════════════════════════════════════
-- 5. applications 정책
-- ══════════════════════════════════════

-- 관리자는 전체 신청 조회 가능
CREATE POLICY "applications_select_admin"
  ON applications FOR SELECT
  USING (is_admin());

-- 본인 신청만 조회 가능
CREATE POLICY "applications_select_own"
  ON applications FOR SELECT
  USING (auth.uid() = user_id);

-- 인증된 사용자가 자기 신청 생성
CREATE POLICY "applications_insert_own"
  ON applications FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- 관리자만 상태 변경 가능
CREATE POLICY "applications_update_admin"
  ON applications FOR UPDATE
  USING (is_admin())
  WITH CHECK (is_admin());

-- 삭제는 관리자만
CREATE POLICY "applications_delete_admin"
  ON applications FOR DELETE
  USING (is_admin());
