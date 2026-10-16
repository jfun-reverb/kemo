-- 541 — 오리엔시트 로그인 계정용 큐텐 불러오기 관문 + orient-images 통 업로드 허가 (브랜드 오리엔시트 탭 작업 4)
--
-- 배경 (작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 작업 4 · 결정 15)
--   브랜드 로그인 화면은 작성 토큰 없이 시트 번호로 일한다. 그래서 ①큐텐 상품 불러오기 ②첨부 이미지 업로드가
--   「로그인 계정 + 시트」 기준으로 열려야 한다. 옛 토큰 갈래(428·200)는 그대로 둔다(작업 9 에서 닫음).
--
-- 만드는 것
--   [A] orient_lookup_hits : auth_id 칸 추가 · token NULL 허용 · CHECK(token 또는 auth_id) · 색인 (auth_id, hit_at DESC)
--   [B] orient_lookup_gate_account(p_auth_id, p_sheet_id) → boolean — 서비스 키 전용 관문
--        ①계정이 시트 브랜드에 활성 연결 + 브랜드 활성 ②시트 작성 가능 ③계정 단위 최근 60초 5회 미만(시트를 바꿔도 합산)
--   [C] orient_account_can_upload(p_sheet text) → boolean — 로그인 계정 업로드 정책용 판정
--   [D] 정책 orient_images_account_insert (storage.objects FOR INSERT TO authenticated)
--        경로 s/{시트 번호}/{난수}.{확장자}. 기존 anon 정책 orient_images_anon_insert 는 건드리지 않는다.
--
-- 🔴 운영 보류 — 브랜드 로그인 묶음(526 → … → 540)과 같이 나간다. 서버 함수(qoo10-product-lookup)는 개발 프로젝트에만 배포
--    (--project-ref qysmxtipobomefudyixw). 운영에 이 파일이 없는 채 새 갈래 함수가 나가면 새 갈래는 늘 {ok:false}(관문 함수 없음 → 거부).
-- ⚠️ SQL 편집기 경고: [D] 의 DROP POLICY 때문에 「destructive operation」 확인창이 뜬다. 정책을 지우고 곧바로 다시 만드는
--    재실행 안전용 문장이라 「Run this query」 로 진행한다(같은 파일 안 한 트랜잭션).
--
-- 모호점 판단
--   · 「기한 안」 = token_expires_at IS NULL OR token_expires_at > now() — 저장 함수(539 _orient_save_core)와 200 판정이 NULL 을 「기한 없음」으로
--     통과시키므로 같게 맞췄다(저장은 되는데 업로드·불러오기만 막히는 어긋남 방지).
--   · 「consumed 아님」 = status IN ('draft','submitted') 로 충분하다(consumed·expired 는 그 목록 밖). 일부 등록 옛 구조 시트는 status 가 submitted 라 통과.
--   · 활성 연결 식은 530 my_brand_role 과 같다(brand_account_links.status='active' AND brands.status='active'). 관문은 서비스 키 호출이라
--     auth.uid() 가 없어 my_brand_role 을 못 쓰므로 계정 번호 인자로 같은 식을 다시 썼다 — 530 식이 바뀌면 여기도 같이 본다(사본 1개).
--   · 계정이 브랜드에 연결돼 있지 않은 경우·시트 없음은 기록 없이 false(남의 시트 번호로 호출 횟수를 태우지 못하게 — 428 과 같은 순서).
--
-- 롤백 순서 (이 순서로)
--   1) 서버 함수를 먼저 되돌린다(새 갈래 없는 판으로 재배포) — 남아 있으면 관문 호출이 오류 → false 로 처리돼 조용히 거부만 된다.
--   2) DROP POLICY IF EXISTS "orient_images_account_insert" ON storage.objects;
--   3) DROP FUNCTION IF EXISTS public.orient_account_can_upload(text);
--      DROP FUNCTION IF EXISTS public.orient_lookup_gate_account(uuid, uuid);
--   4) DROP INDEX IF EXISTS public.idx_orient_lookup_hits_auth_at;
--      ALTER TABLE public.orient_lookup_hits DROP CONSTRAINT IF EXISTS orient_lookup_hits_subject_check;
--      🔴 token NOT NULL 복귀는 auth_id 행(token 이 NULL)이 남아 있으면 실패한다 — 먼저
--         DELETE FROM public.orient_lookup_hits WHERE token IS NULL;   (그 뒤)
--      ALTER TABLE public.orient_lookup_hits ALTER COLUMN token SET NOT NULL;
--      ALTER TABLE public.orient_lookup_hits DROP COLUMN IF EXISTS auth_id;

BEGIN;

-- [A] 기록 표 확장 — 계정 단위 호출 기록
ALTER TABLE public.orient_lookup_hits ADD COLUMN IF NOT EXISTS auth_id uuid NULL;
ALTER TABLE public.orient_lookup_hits ALTER COLUMN token DROP NOT NULL;
ALTER TABLE public.orient_lookup_hits DROP CONSTRAINT IF EXISTS orient_lookup_hits_subject_check;
ALTER TABLE public.orient_lookup_hits
  ADD CONSTRAINT orient_lookup_hits_subject_check CHECK (token IS NOT NULL OR auth_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_orient_lookup_hits_auth_at ON public.orient_lookup_hits (auth_id, hit_at DESC);
COMMENT ON COLUMN public.orient_lookup_hits.auth_id IS '[541] 로그인 계정 갈래의 호출 계정 번호(외래 키 없음 — 1시간 뒤 지워지는 기록). 토큰 갈래 행은 NULL';

-- [B] 로그인 계정 관문
CREATE OR REPLACE FUNCTION public.orient_lookup_gate_account(p_auth_id uuid, p_sheet_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recent integer;
BEGIN
  IF p_auth_id IS NULL OR p_sheet_id IS NULL THEN
    RETURN false;
  END IF;

  -- ①②  계정이 시트 브랜드에 활성 연결 + 브랜드 활성(530 my_brand_role 과 같은 식) + 시트 작성 가능
  --     (draft·submitted 만 = consumed·expired 제외, 기한 안 — NULL 은 기한 없음)
  IF NOT EXISTS (
    SELECT 1
      FROM public.orient_sheets s
      JOIN public.brands b ON b.id = s.brand_id
      JOIN public.brand_account_links l ON l.brand_id = s.brand_id
     WHERE s.id = p_sheet_id
       AND s.status IN ('draft', 'submitted')
       AND (s.token_expires_at IS NULL OR s.token_expires_at > now())
       AND b.status = 'active'
       AND l.auth_id = p_auth_id
       AND l.status = 'active'
  ) THEN
    RETURN false;
  END IF;

  -- 지나간 기록 정리(1시간 넘은 것 — 428 과 같은 관례)
  DELETE FROM public.orient_lookup_hits WHERE hit_at < now() - interval '1 hour';

  -- ③ 계정 단위 최근 60초 5회 — 같은 계정의 동시 호출이 겹치지 않게 계정 단위로 잠근 뒤 센다(시트를 바꿔도 합산)
  PERFORM pg_advisory_xact_lock(hashtext('orient_lookup_gate_account'), hashtext(p_auth_id::text));
  SELECT count(*) INTO v_recent
    FROM public.orient_lookup_hits
   WHERE auth_id = p_auth_id AND hit_at >= now() - interval '60 seconds';
  IF v_recent >= 5 THEN
    RETURN false;
  END IF;

  INSERT INTO public.orient_lookup_hits (auth_id) VALUES (p_auth_id);
  RETURN true;
END;
$$;

-- 권한: 부여 먼저, 회수 나중(428 과 같은 순서)
GRANT EXECUTE ON FUNCTION public.orient_lookup_gate_account(uuid, uuid) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.orient_lookup_gate_account(uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.orient_lookup_gate_account(uuid, uuid) FROM anon, authenticated;

COMMENT ON FUNCTION public.orient_lookup_gate_account(uuid, uuid) IS
  '[541] 큐텐 상품 읽기(로그인 갈래)의 관문 — 계정이 시트 브랜드에 활성 연결·작성 가능 시트·계정당 60초 5회 미만이면 1회 기록 후 true. service_role 전용(authenticated 에 열면 남의 계정 번호로 횟수를 태울 수 있다)';

-- [C] 로그인 계정 업로드 판정 — 정책 평가가 호출자(authenticated) 권한으로 돈다
CREATE OR REPLACE FUNCTION public.orient_account_can_upload(p_sheet text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF p_sheet IS NULL OR p_sheet !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
    RETURN false;   -- 형식 아니면 예외 없이 거부
  END IF;
  v_id := p_sheet::uuid;
  RETURN COALESCE((
    SELECT public.is_my_brand(s.brand_id)
      FROM public.orient_sheets s
     WHERE s.id = v_id
       AND s.status IN ('draft', 'submitted')
       AND (s.token_expires_at IS NULL OR s.token_expires_at > now())
  ), false);
END;
$$;

GRANT EXECUTE ON FUNCTION public.orient_account_can_upload(text) TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.orient_account_can_upload(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.orient_account_can_upload(text) FROM anon;

COMMENT ON FUNCTION public.orient_account_can_upload(text) IS
  '[541] orient-images 로그인 계정 업로드 정책용 — 경로의 시트 번호가 uuid 이고, 그 시트가 내 브랜드(is_my_brand)이며 작성 가능(draft·submitted·기한 안)이면 true. authenticated 전용';

-- [D] 정책 — 경로 s/{시트 번호}/{난수}.{확장자}. 기존 anon 정책은 그대로.
--     화면 업로드는 upsert:false(472 — true 면 SELECT 권한이 필요해 막힌다)
DROP POLICY IF EXISTS "orient_images_account_insert" ON storage.objects;
CREATE POLICY "orient_images_account_insert"
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'orient-images'
    AND (storage.foldername(name))[1] = 's'
    AND public.orient_account_can_upload((storage.foldername(name))[2])
  );

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ── 적용 후 확인 (한 단계씩 실행하고 결과를 본 뒤 다음으로) ─────────────────
-- [V1] 칸·검사·색인
--   SELECT (SELECT is_nullable FROM information_schema.columns WHERE table_schema='public' AND table_name='orient_lookup_hits' AND column_name='token') AS token_nullable,
--          (SELECT data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='orient_lookup_hits' AND column_name='auth_id') AS auth_type,
--          (SELECT count(*) FROM pg_constraint WHERE conname='orient_lookup_hits_subject_check') AS chk,
--          (SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND indexname='idx_orient_lookup_hits_auth_at') AS idx;
--   기대: token_nullable=YES · auth_type=uuid · chk=1 · idx=1.
-- [V2] 함수 권한 — has_function_privilege 만 보지 말고 proacl 맨 앞 `=X/` 유무를 함께
--   SELECT p.proname, p.proacl::text AS acl,
--          has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_can,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_can,
--          has_function_privilege('service_role', p.oid, 'EXECUTE') AS svc_can
--     FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
--    WHERE n.nspname='public' AND p.proname IN ('orient_lookup_gate_account','orient_account_can_upload') ORDER BY 1;
--   기대: acl 맨 앞 `=X/` 없음 · anon_can 둘 다 false · 관문은 auth_can=false · 업로드 판정은 auth_can=true · svc_can 둘 다 true.
-- [V3] 정책 존재(기존 anon 정책도 그대로인지 함께)
--   SELECT policyname, cmd, roles FROM pg_policies
--    WHERE schemaname='storage' AND tablename='objects' AND policyname IN ('orient_images_account_insert','orient_images_anon_insert') ORDER BY 1;
--   기대: 2행 — account_insert = INSERT · {authenticated} / anon_insert = INSERT · {anon}.
-- [V4] 함수 1회 실제 호출 — 편집기(서비스 권한). 기록이 남지 않는 호출만(없는 계정·시트라 ①에서 false)
--   SELECT public.orient_lookup_gate_account(gen_random_uuid(), gen_random_uuid()) AS gate_missing,
--          public.orient_account_can_upload('xx') AS bad_format,
--          public.orient_account_can_upload(gen_random_uuid()::text) AS random_uuid;
--   기대: 셋 다 false(오류 없이). 그 뒤 SELECT count(*) FROM public.orient_lookup_hits WHERE auth_id IS NOT NULL; 로 기록이 안 늘었는지.
--   ⚠️ 편집기는 auth.uid() 가 없어 is_my_brand 가 늘 false — 「참」 경로와 업로드는 로그인 브라우저·curl 시험이며 메인이 한다.
