-- ============================================
-- 회원가입 시 influencers 자동 생성 트리거
-- auth.users에 새 유저가 등록되면 influencers에 기본 프로필 자동 생성
-- Supabase SQL Editor에서 실행하세요
-- ============================================

-- 트리거 함수 생성
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  INSERT INTO public.influencers (id, email, created_at)
  VALUES (NEW.id, NEW.email, now())
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

-- auth.users에 INSERT 트리거 연결
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- 기존에 influencers에 없는 유저 보정
INSERT INTO public.influencers (id, email, created_at)
SELECT id, email, created_at FROM auth.users
WHERE id NOT IN (SELECT id FROM public.influencers)
AND email != 'admin@kemo.jp'
ON CONFLICT (id) DO NOTHING;

-- 확인
SELECT u.email, CASE WHEN i.id IS NOT NULL THEN '✓' ELSE '✗' END as has_profile
FROM auth.users u
LEFT JOIN public.influencers i ON u.id = i.id
WHERE u.email != 'admin@kemo.jp'
ORDER BY u.created_at;
