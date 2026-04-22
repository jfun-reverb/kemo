-- ============================================================
-- 063_admin_notices.sql
-- 관리자 공지사항 + 읽음 이력
--
-- 테이블:
--   admin_notices       — 공지 본문 (리치 텍스트, 카테고리, 고정)
--   admin_notice_reads  — 읽음 이력 (관리자별)
--
-- RPC:
--   upsert_admin_notice_read(p_notice_id uuid) — 읽음 처리 (SECURITY DEFINER)
--
-- ROLLBACK 방법:
--   DROP FUNCTION IF EXISTS public.upsert_admin_notice_read(uuid);
--   DROP TABLE IF EXISTS public.admin_notice_reads;
--   DROP TABLE IF EXISTS public.admin_notices;
-- ============================================================

-- ============================================================
-- Step 1: admin_notices 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_notices (
  id               uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  title            text        NOT NULL,
  body_html        text        NOT NULL,                   -- DOMPurify sanitize 된 Quill HTML
  category         text        NOT NULL
                               CHECK (category IN ('system_update','general','warning','release')),
  is_pinned        boolean     NOT NULL DEFAULT false,
  pinned_at        timestamptz,                            -- 고정 시점 (정렬 기준)
  created_by       uuid,                                   -- admins.auth_id soft ref
  created_by_name  text,                                   -- 작성자 이름 스냅샷 (삭제 후 표시용)
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,                                   -- admins.auth_id soft ref
  updated_by_name  text                                    -- 최종 수정자 이름 스냅샷
);

-- 목록 정렬용 인덱스: 고정 공지 최상단 → 고정 시점 역순 → 작성일 역순
CREATE INDEX IF NOT EXISTS idx_admin_notices_list
  ON public.admin_notices (is_pinned DESC, pinned_at DESC NULLS LAST, created_at DESC);

-- updated_at 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public.touch_admin_notices_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_admin_notices_updated_at ON public.admin_notices;
CREATE TRIGGER trg_admin_notices_updated_at
  BEFORE UPDATE ON public.admin_notices
  FOR EACH ROW EXECUTE FUNCTION public.touch_admin_notices_updated_at();

-- ============================================================
-- Step 2: admin_notice_reads 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.admin_notice_reads (
  notice_id  uuid        NOT NULL REFERENCES public.admin_notices(id) ON DELETE CASCADE,
  auth_id    uuid        NOT NULL,
  read_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (notice_id, auth_id)
);

-- auth_id 단독 인덱스: "내가 읽지 않은 공지 수" 쿼리용
CREATE INDEX IF NOT EXISTS idx_admin_notice_reads_auth
  ON public.admin_notice_reads (auth_id);

-- ============================================================
-- Step 3: RLS — admin_notices
-- ============================================================
ALTER TABLE public.admin_notices ENABLE ROW LEVEL SECURITY;

-- SELECT: 모든 관리자
CREATE POLICY "admin_notices_select"
  ON public.admin_notices FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: campaign_admin 이상 (super_admin 포함)
CREATE POLICY "admin_notices_insert"
  ON public.admin_notices FOR INSERT
  TO authenticated
  WITH CHECK (public.is_campaign_admin());

-- UPDATE: super_admin은 전체, 일반 관리자는 본인 작성 공지만
CREATE POLICY "admin_notices_update"
  ON public.admin_notices FOR UPDATE
  TO authenticated
  USING (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = auth.uid())
  )
  WITH CHECK (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = auth.uid())
  );

-- DELETE: UPDATE 와 동일 규칙
CREATE POLICY "admin_notices_delete"
  ON public.admin_notices FOR DELETE
  TO authenticated
  USING (
    public.is_campaign_admin()
    AND (public.is_super_admin() OR created_by = auth.uid())
  );

-- ============================================================
-- Step 4: RLS — admin_notice_reads
-- ============================================================
ALTER TABLE public.admin_notice_reads ENABLE ROW LEVEL SECURITY;

-- SELECT:
--   (a) 본인 읽음 이력 조회 (마이 읽음 상태 확인)
--   (b) is_admin() 전체 허용 — 공지 목록과 LEFT JOIN 할 때 본인 행만 필터링은
--       클라이언트 또는 RPC 레벨에서 처리. 정책은 관리자면 전체 허용.
CREATE POLICY "admin_notice_reads_select"
  ON public.admin_notice_reads FOR SELECT
  TO authenticated
  USING (public.is_admin());

-- INSERT: 본인 행만, 관리자여야 함
CREATE POLICY "admin_notice_reads_insert"
  ON public.admin_notice_reads FOR INSERT
  TO authenticated
  WITH CHECK (auth_id = auth.uid() AND public.is_admin());

-- UPDATE/DELETE 정책 없음 — upsert_admin_notice_read RPC 전용 (직접 조작 차단)

-- ============================================================
-- Step 5: RPC — upsert_admin_notice_read
--   현재 로그인한 관리자의 읽음을 upsert.
--   SECURITY DEFINER이므로 RLS bypass — INSERT 권한 문제 없이 동작.
--   search_path = '' 로 schema 탈취 방어.
-- ============================================================
CREATE OR REPLACE FUNCTION public.upsert_admin_notice_read(p_notice_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  -- 비관리자 호출 차단
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission denied: admin only';
  END IF;

  -- 공지가 존재하는지 확인 (없으면 FK 위반으로 바로 에러)
  INSERT INTO public.admin_notice_reads (notice_id, auth_id, read_at)
  VALUES (p_notice_id, v_uid, now())
  ON CONFLICT (notice_id, auth_id) DO UPDATE
    SET read_at = now();         -- 재방문 시 read_at 갱신
END;
$$;

-- anon 호출 차단 (authenticated 만 exec 허용)
REVOKE EXECUTE ON FUNCTION public.upsert_admin_notice_read(uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.upsert_admin_notice_read(uuid) TO authenticated;

-- ============================================================
-- 검증 쿼리 (수동 실행)
-- ============================================================

-- [1] 테이블 존재 확인
-- SELECT table_name
-- FROM information_schema.tables
-- WHERE table_schema = 'public'
--   AND table_name IN ('admin_notices','admin_notice_reads')
-- ORDER BY table_name;
-- 기대: 2개 행

-- [2] RLS 정책 목록
-- SELECT tablename, policyname, cmd, qual
-- FROM pg_policies
-- WHERE tablename IN ('admin_notices','admin_notice_reads')
-- ORDER BY tablename, policyname;
-- 기대: admin_notices 4건 (select/insert/update/delete)
--       admin_notice_reads 2건 (select/insert)

-- [3] RPC prosecdef 확인
-- SELECT proname, prosecdef, proconfig
-- FROM pg_proc
-- WHERE proname = 'upsert_admin_notice_read';
-- 기대: prosecdef = true, proconfig 에 'search_path=' 포함

-- [4] 샘플 INSERT + RPC 테스트 (관리자 세션에서 실행)
-- INSERT INTO public.admin_notices
--   (title, body_html, category, is_pinned, pinned_at, created_by, created_by_name)
-- VALUES
--   ('시스템 점검 안내',
--    '<p>2026-04-25 02:00 ~ 04:00 시스템 점검 예정입니다.</p>',
--    'system_update', true, now(),
--    auth.uid(), '테스트관리자')
-- RETURNING id, created_at;
--
-- SELECT public.upsert_admin_notice_read('<위에서 나온 id>');
--
-- SELECT * FROM public.admin_notice_reads
-- WHERE notice_id = '<위에서 나온 id>';
-- 기대: read_at 기록된 1행

-- [5] 미읽음 공지 수 확인 쿼리 (fetchUnreadAdminNotices 내부 동일 로직)
-- SELECT COUNT(*)
-- FROM public.admin_notices n
-- WHERE NOT EXISTS (
--   SELECT 1 FROM public.admin_notice_reads r
--   WHERE r.notice_id = n.id
--     AND r.auth_id = auth.uid()
-- );
-- 기대: upsert 전 공지 총 수, upsert 후 1 감소

-- ============================================================
-- 실행 체크리스트
-- ============================================================
-- 개발서버(qysmxtipobomefudyixw):
--   [ ] Supabase SQL Editor에서 이 파일 전체 실행
--   [ ] 검증 쿼리 [1]~[5] 순서대로 확인
--   [ ] fetchAdminNotices / markAdminNoticeRead 클라이언트 함수 동작 확인
--   [ ] 개발서버 화면에서 공지 등록 → 목록 노출 → 읽음 처리 확인
--
-- 운영서버(twofagomeizrtkwlhsuv):
--   [ ] 개발서버 검증 완료 후 동일 SQL 실행
--   [ ] 검증 쿼리 [1]~[3] 재확인 (데이터 INSERT는 선택)
