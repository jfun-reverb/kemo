-- 428 — 큐텐 상품 읽기 함수(qoo10-product-lookup)의 관문 ①③ 을 데이터베이스가 판정
--
-- 배경 (오리엔시트 단순화 3단계, 사양서 docs/specs/2026-09-08-orient-sheet-simplify-and-quote.md §4-7 작업 22)
--   작성 폼이 공개 키로 Edge Function 을 부르고, 그 함수가 Supabase 를 시켜 큐텐 상품 페이지를 읽는다.
--   관문 3종 = ①살아 있는 작성 토큰 ②qoo10.jp 호스트+상품 번호 ③토큰당 분당 5회.
--   🔴 ③을 함수 인스턴스 메모리로 만들었더니 개발서버 실측(2026-09-08)에서 6회 연속 호출이 전부 통과했다 —
--      Edge Function 은 요청마다 인스턴스가 갈릴 수 있어 메모리 계수기가 사실상 0 회를 센다. 그래서 여기로 옮긴다.
--
-- 만드는 것
--   [A] 표  public.orient_lookup_hits — 토큰별 호출 시각(토큰·시각뿐. 상품 주소·응답은 담지 않는다)
--   [B] 함수 public.orient_lookup_gate(p_token text) → boolean
--        ① orient_token_can_upload(200) 로 토큰 생사 확인 → 죽었으면 false (기록 안 함)
--        ③ 최근 60초 호출이 5회 이상이면 false, 아니면 1회 기록 후 true
--        지나간 기록은 부를 때마다 1시간 넘은 것을 지운다(예약 작업 없이도 표가 안 자란다)
--   권한: service_role 만(함수가 서비스 키로 부른다). 공개 키·로그인 회원에게는 열지 않는다 —
--        열면 남의 토큰으로 호출 횟수를 태워 정상 브랜드의 자동 채움을 막을 수 있다.
--
-- ⚠️ 관문 ②(호스트·상품 번호)는 데이터베이스 왕복 없이 거를 수 있어 Edge Function 에 그대로 둔다.
--
-- 롤백 방법(함수 배포를 먼저 되돌린 뒤):
--   DROP FUNCTION IF EXISTS public.orient_lookup_gate(text);
--   DROP TABLE IF EXISTS public.orient_lookup_hits;
--   (Edge Function 이 남아 있으면 관문 호출이 오류 → false 로 처리돼 조용히 전부 거부된다 — 폼은 「자동으로 못 불러왔어요」)

BEGIN;

-- [A] 호출 기록 표
CREATE TABLE IF NOT EXISTS public.orient_lookup_hits (
  id      bigserial PRIMARY KEY,
  token   uuid        NOT NULL,
  hit_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_orient_lookup_hits_token_at ON public.orient_lookup_hits (token, hit_at DESC);
ALTER TABLE public.orient_lookup_hits ENABLE ROW LEVEL SECURITY;
-- 정책 없음 — 화면·회원·관리자 누구도 직접 읽거나 쓰지 않는다(아래 함수만, SECURITY DEFINER)
REVOKE ALL ON public.orient_lookup_hits FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.orient_lookup_hits IS '큐텐 상품 읽기 함수 호출 기록(토큰당 분당 5회 제한용). 1시간 지난 행은 orient_lookup_gate 가 지운다';

-- [B] 관문 함수
CREATE OR REPLACE FUNCTION public.orient_lookup_gate(p_token text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_token uuid;
  v_recent integer;
BEGIN
  -- 형식이 아니면 바로 거부(uuid 캐스트 오류를 false 로)
  BEGIN
    v_token := p_token::uuid;
  EXCEPTION WHEN others THEN
    RETURN false;
  END;

  -- ① 살아 있는 작성 토큰만(200 의 판정 그대로 — 미매칭·만료·소비 전부 false)
  IF NOT COALESCE(public.orient_token_can_upload(p_token), false) THEN
    RETURN false;
  END IF;

  -- 지나간 기록 정리(가벼운 범위 — 1시간 넘은 것)
  DELETE FROM public.orient_lookup_hits WHERE hit_at < now() - interval '1 hour';

  -- ③ 토큰당 분당 5회 — 같은 토큰의 동시 호출이 겹치지 않게 토큰 단위로 잠근다
  PERFORM pg_advisory_xact_lock(hashtext('orient_lookup_gate'), hashtext(p_token));
  SELECT count(*) INTO v_recent
    FROM public.orient_lookup_hits
   WHERE token = v_token AND hit_at >= now() - interval '60 seconds';
  IF v_recent >= 5 THEN
    RETURN false;
  END IF;

  INSERT INTO public.orient_lookup_hits (token) VALUES (v_token);
  RETURN true;
END;
$$;

-- 권한: 부여 먼저, 회수 나중(순서를 바꾸면 service_role 이 PUBLIC 경유로만 갖고 있던 권한이 함께 사라진다)
GRANT EXECUTE ON FUNCTION public.orient_lookup_gate(text) TO postgres, service_role;
REVOKE EXECUTE ON FUNCTION public.orient_lookup_gate(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.orient_lookup_gate(text) FROM anon, authenticated;

COMMENT ON FUNCTION public.orient_lookup_gate(text) IS
  '큐텐 상품 읽기 함수의 관문 ①③ — 살아 있는 토큰이고 최근 60초 호출이 5회 미만이면 1회 기록 후 true. service_role 전용';

COMMIT;

-- ── 검증(개발 SQL 편집기, 되돌리기 블록) ─────────────────────────────────
-- DO $v$ DECLARE t text := '<살아 있는 토큰>'; r boolean[] := '{}'; BEGIN
--   FOR i IN 1..6 LOOP r := r || public.orient_lookup_gate(t); END LOOP;
--   RAISE EXCEPTION 'RESULT alive=% expired=% garbage=%', r,
--     public.orient_lookup_gate('<만료 토큰>'), public.orient_lookup_gate('abc');
-- END $v$;
-- 기대: alive={t,t,t,t,t,f} expired=f garbage=f  (예외로 되돌려져 기록이 남지 않는다)
