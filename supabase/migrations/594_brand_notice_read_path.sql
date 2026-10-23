-- ============================================================
-- 594_brand_notice_read_path.sql
-- 브랜드 계정이 공지(admin_notices audience='brand', 593)를 보는 길
--
-- 왜: 브랜드 페이지 좌측 아래 「도움말」(피그마 bw03-05 빨간 점 · 05a 최근 공지 한 줄 · bw03-06 공지 모달).
--     공지 표의 조회 정책은 관리자 전용 그대로 두고, 브랜드 계정은 아래 정의자 권한 함수로만 읽는다.
--
-- 🔴 본 기록은 공지마다 한 줄이다(시각 하나가 아니다) — published_at 은 관리자 PC 시계로 찍히고 다시 게시해도
--    처음 시각이 남아, 「마지막으로 본 시각」과 비교하면 점이 영영 안 켜질 수 있다(2026-10-23 계약 변경).
--
-- 만드는 것:
--   표 brand_notice_seen(auth_id, notice_id, seen_at) PK(auth_id, notice_id) — 계정이 본 브랜드 공지.
--     admin_notice_reads 와 섞지 않는다. 직접 접근 없음(행 단위 보안 켜고 정책 없음 + 표 권한 회수) — 함수만 쓴다.
--     공지가 지워지면·브랜드 계정이 지워지면 함께 지워진다.
--   _brand_visible_notices() — 🔴 「보이는 공지」 판정 한 곳(서버 now() 기준):
--     audience='brand' AND status='published' AND help_show_from <= now()
--     시작 전 공지는 브랜드에 아예 안 보인다(예약 게시처럼). 게시 취소하면 즉시 안 보인다(남은 본 기록은 그대로).
--   _brand_notice_caller() — 호출자 판정 한 곳:
--     브랜드 계정 아님(brand_accounts 에 행 없음 — 526 get_my_account_kind 와 같은 식. 그 표는 앱 메타데이터
--     account_kind='brand' 계정만 만든다) → 오류 'forbidden'
--     이용 제한 중(_brand_account_restricted, 581) → 오류 'account_restricted'(P0001 — 582 관문들과 같은 글자,
--     브랜드 화면 공통 입구 handleBrandAccountRestricted 가 받는다)
--     활성 연결 없음(활성 연결 + 활성 브랜드 — my_brand_role 530 식의 사본) → false(빈 결과) · 그 밖 → true
--   get_my_brand_notices() → [{id,title,body_html,brand_kind,published_at,is_new}] 보이는 공지 전부(기간 끝난 것 포함),
--     published_at 최신순. is_new = 내 본 기록 없음. 작성자·게시자 이름은 싣지 않는다.
--   get_my_brand_notice_summary() → {latest:{id,title,brand_kind,published_at}|null, unread_count}
--     「기간 안」 = 보이는 공지 중 now() <= help_show_until. latest = 그중 published_at 가장 최근 하나 ·
--     unread_count = 그중 내 본 기록이 없는 수.
--   mark_my_brand_notices_seen() — 인자 없음. 지금 보이는 브랜드 공지 전부를 내 본 기록으로(ON CONFLICT DO NOTHING).
--     번호를 받지 않아 관리자 공지·지운 번호를 넣을 길이 없다.
--   내용만 고친 저장(게시 유지)은 점을 다시 켜지 않는다(본 기록 그대로 — 의도).
--
-- 🔴 초안·관리자 공지는 절대 안 나간다 — 판정은 _brand_visible_notices 한 곳, 세 함수가 모두 그것만 읽는다.
-- 실행 권한: 공개 셋은 부여(postgres·authenticated·service_role) 먼저 → PUBLIC 회수 → anon 회수 / 내부 둘은 postgres 만
--   (369·370·375 의 방향 둘).
-- 운영: 브랜드 페이지 출시 묶음 — 593 뒤에만(앞이면 없는 칸을 읽어 함수 생성은 되지만 첫 호출에서 터진다).
-- 개발서버: 계약 변경 전 판(시각 하나 표)을 한 번 돌렸다 — 그 표·함수를 지우고 이 판을 다시 실행했다(기록 표에 594 세 줄 — 첫 실행 · 정정 메모 · 다시 실행).
--
-- ROLLBACK:
--   DROP FUNCTION IF EXISTS public.mark_my_brand_notices_seen();
--   DROP FUNCTION IF EXISTS public.get_my_brand_notices();
--   DROP FUNCTION IF EXISTS public.get_my_brand_notice_summary();
--   DROP FUNCTION IF EXISTS public._brand_notice_caller();
--   DROP FUNCTION IF EXISTS public._brand_visible_notices();
--   DROP TABLE IF EXISTS public.brand_notice_seen;
-- ============================================================
BEGIN;

-- ── 표 ─────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.brand_notice_seen (
  auth_id    uuid        NOT NULL REFERENCES public.brand_accounts(auth_id) ON DELETE CASCADE,
  notice_id  uuid        NOT NULL REFERENCES public.admin_notices(id) ON DELETE CASCADE,
  seen_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (auth_id, notice_id)
);

-- 공지 삭제 때 CASCADE 가 이 표를 notice_id 로 찾는다
CREATE INDEX IF NOT EXISTS idx_brand_notice_seen_notice ON public.brand_notice_seen (notice_id);

COMMENT ON TABLE public.brand_notice_seen IS
  '[594] 브랜드 계정이 본 브랜드 공지(공지마다 한 줄) — 도움말 빨간 점·새 공지 표시. 직접 접근 없음, mark_my_brand_notices_seen 으로만 쓴다.';

ALTER TABLE public.brand_notice_seen ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.brand_notice_seen FROM PUBLIC, anon, authenticated;

-- ── 내부: 보이는 공지 판정 한 곳 ───────────────────────────
CREATE OR REPLACE FUNCTION public._brand_visible_notices()
RETURNS SETOF public.admin_notices
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT n.*
    FROM public.admin_notices n
   WHERE n.audience = 'brand'
     AND n.status = 'published'
     AND n.help_show_from <= now();
$$;

COMMENT ON FUNCTION public._brand_visible_notices() IS
  '[594] 브랜드에 보이는 공지 판정 한 곳 — audience=brand · 게시됨 · help_show_from <= now()(서버 시각). 기간 끝난 것 포함. 실행 권한 postgres 만(호출자 검사 없음).';

-- ── 내부: 호출자 판정 한 곳 ────────────────────────────────
CREATE OR REPLACE FUNCTION public._brand_notice_caller()
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF v_uid IS NULL OR NOT EXISTS (SELECT 1 FROM public.brand_accounts WHERE auth_id = v_uid) THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = 'P0001';
  END IF;
  IF public._brand_account_restricted(v_uid) THEN
    RAISE EXCEPTION 'account_restricted' USING ERRCODE = 'P0001';
  END IF;
  -- 활성 연결 + 활성 브랜드(530 my_brand_role 식의 사본)
  RETURN EXISTS (
    SELECT 1
      FROM public.brand_account_links l
      JOIN public.brands b ON b.id = l.brand_id
     WHERE l.auth_id = v_uid
       AND l.status = 'active'
       AND b.status = 'active'
  );
END;
$$;

COMMENT ON FUNCTION public._brand_notice_caller() IS
  '[594] 브랜드 공지 함수 호출자 판정 — 브랜드 계정 아님 forbidden · 이용 제한 account_restricted · 활성 연결 없음 false(빈 결과) · 그 밖 true. 실행 권한 postgres 만.';

-- ── 목록: 보이는 공지 전부 ─────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_notices()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF NOT public._brand_notice_caller() THEN
    RETURN '[]'::jsonb;
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', n.id, 'title', n.title, 'body_html', n.body_html,
             'brand_kind', n.brand_kind, 'published_at', n.published_at,
             'is_new', NOT EXISTS (SELECT 1 FROM public.brand_notice_seen s
                                    WHERE s.auth_id = v_uid AND s.notice_id = n.id))
           ORDER BY n.published_at DESC NULLS LAST, n.created_at DESC)
      FROM public._brand_visible_notices() n
  ), '[]'::jsonb);
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_notices() IS
  '[594] 브랜드 공지 모달 — 보이는 공지 전부(기간 끝난 것 포함) published_at 최신순 + is_new. 이름 칸 없음. '
  '브랜드 계정 아님 forbidden · 이용 제한 account_restricted · 활성 연결 없음 [].';

-- ── 요약: 최근 공지 한 줄 + 새 공지 수 ─────────────────────
CREATE OR REPLACE FUNCTION public.get_my_brand_notice_summary()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid    uuid := (SELECT auth.uid());
  v_latest jsonb;
  v_count  integer;
BEGIN
  IF NOT public._brand_notice_caller() THEN
    RETURN jsonb_build_object('latest', NULL, 'unread_count', 0);
  END IF;

  SELECT jsonb_build_object('id', n.id, 'title', n.title, 'brand_kind', n.brand_kind, 'published_at', n.published_at)
    INTO v_latest
    FROM public._brand_visible_notices() n
   WHERE now() <= n.help_show_until
   ORDER BY n.published_at DESC NULLS LAST, n.created_at DESC
   LIMIT 1;

  SELECT count(*)::integer INTO v_count
    FROM public._brand_visible_notices() n
   WHERE now() <= n.help_show_until
     AND NOT EXISTS (SELECT 1 FROM public.brand_notice_seen s
                      WHERE s.auth_id = v_uid AND s.notice_id = n.id);

  RETURN jsonb_build_object('latest', v_latest, 'unread_count', COALESCE(v_count, 0));
END;
$$;

COMMENT ON FUNCTION public.get_my_brand_notice_summary() IS
  '[594] 브랜드 도움말 메뉴 — {latest, unread_count}. 보이는 공지 중 기간 안(now() <= help_show_until)만, 안 읽음 = 본 기록 없음. '
  '브랜드 계정 아님 forbidden · 이용 제한 account_restricted · 활성 연결 없음 빈 결과.';

-- ── 본 기록: 지금 보이는 공지 전부 ─────────────────────────
CREATE OR REPLACE FUNCTION public.mark_my_brand_notices_seen()
RETURNS void
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid uuid := (SELECT auth.uid());
BEGIN
  IF NOT public._brand_notice_caller() THEN
    RETURN;
  END IF;

  INSERT INTO public.brand_notice_seen (auth_id, notice_id)
  SELECT v_uid, n.id FROM public._brand_visible_notices() n
  ON CONFLICT (auth_id, notice_id) DO NOTHING;
END;
$$;

COMMENT ON FUNCTION public.mark_my_brand_notices_seen() IS
  '[594] 지금 보이는 브랜드 공지 전부를 내 본 기록으로(이미 있으면 그대로). 인자 없음. '
  '브랜드 계정 아님 forbidden · 이용 제한 account_restricted · 활성 연결 없음 아무것도 안 함.';

-- ── 실행 권한 ──────────────────────────────────────────────
-- 내부 둘: postgres 만
GRANT  EXECUTE ON FUNCTION public._brand_visible_notices() TO postgres;
GRANT  EXECUTE ON FUNCTION public._brand_notice_caller()   TO postgres;
REVOKE EXECUTE ON FUNCTION public._brand_visible_notices() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_notice_caller()   FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._brand_visible_notices() FROM anon, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public._brand_notice_caller()   FROM anon, authenticated, service_role;
-- 공개 셋: 부여 먼저 → PUBLIC 회수 → anon 회수
GRANT  EXECUTE ON FUNCTION public.get_my_brand_notice_summary() TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.get_my_brand_notices()        TO postgres, authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.mark_my_brand_notices_seen()  TO postgres, authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_notice_summary() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_notices()        FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_notices_seen()  FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_notice_summary() FROM anon;
REVOKE EXECUTE ON FUNCTION public.get_my_brand_notices()        FROM anon;
REVOKE EXECUTE ON FUNCTION public.mark_my_brand_notices_seen()  FROM anon;

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '594', '594_brand_notice_read_path.sql');
COMMIT;
