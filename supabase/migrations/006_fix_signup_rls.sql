-- ============================================
-- REVERB JP — 회원가입 RLS 수정
-- 회원가입 직후 influencer 프로필 저장이 안 되는 문제 해결
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- 문제: 회원가입 직후 이메일 인증이 안 된 상태에서
-- auth.uid()가 null이라 influencers INSERT가 RLS에 의해 차단됨

-- 해결: 인증된 사용자(로그인된 상태)면 자기 ID로 INSERT 허용
-- + 서비스 역할(service_role)은 항상 허용

-- 기존 정책 삭제 후 재생성
DROP POLICY IF EXISTS "influencers_insert_own" ON influencers;

-- 새 정책: 인증된 사용자는 자기 프로필 INSERT 가능
CREATE POLICY "influencers_insert_own"
  ON influencers FOR INSERT
  WITH CHECK (
    auth.uid() = id
    OR auth.role() = 'service_role'
  );

-- 추가: 인증된 모든 사용자에게 INSERT 허용 (자기 ID만)
-- Supabase signUp 후 자동 로그인 안 되는 경우 대비
DROP POLICY IF EXISTS "influencers_insert_authenticated" ON influencers;

CREATE POLICY "influencers_insert_authenticated"
  ON influencers FOR INSERT
  WITH CHECK (
    auth.role() = 'authenticated'
    AND auth.uid() = id
  );


-- ══════════════════════════════════════
-- 기존 데이터 확인용 쿼리 (결과 확인용)
-- ══════════════════════════════════════
SELECT id, email, confirmed_at, last_sign_in_at
FROM auth.users
ORDER BY created_at DESC;
