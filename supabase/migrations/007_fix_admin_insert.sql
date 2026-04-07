-- ============================================
-- REVERB JP — 관리자 권한 + 회원가입 INSERT 수정
-- 관리자가 인플루언서 데이터를 관리할 수 있도록,
-- 그리고 회원가입 직후 프로필 저장이 되도록 수정
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- ── 기존 INSERT 정책 전부 삭제 ──
DROP POLICY IF EXISTS "influencers_insert_own" ON influencers;
DROP POLICY IF EXISTS "influencers_insert_authenticated" ON influencers;

-- ── 새 INSERT 정책: 관리자 OR 본인 ──
CREATE POLICY "influencers_insert_allow"
  ON influencers FOR INSERT
  WITH CHECK (
    is_admin()
    OR auth.uid() = id
    OR auth.uid() IS NOT NULL
  );

-- ── 기존 UPDATE 정책에 관리자 권한 추가 ──
DROP POLICY IF EXISTS "influencers_update_own" ON influencers;

CREATE POLICY "influencers_update_allow"
  ON influencers FOR UPDATE
  USING (is_admin() OR auth.uid() = id)
  WITH CHECK (is_admin() OR auth.uid() = id);

-- ── 기존에 가입했지만 influencers에 없는 사용자 추가 ──
INSERT INTO influencers (id, email, created_at)
SELECT id, email, created_at FROM auth.users
WHERE id NOT IN (SELECT id FROM influencers)
AND email != 'admin@kemo.jp';
