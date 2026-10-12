-- =============================================================================
-- 마이그레이션 518: resolve_client_error — 같은 지문·같은 상태 행이 이미 있으면 「합치기」
-- 베이스  : 165 (현재 원본, 재정의 없음)
-- 인수인계: docs/specs/2026-10-12-error-log-reignore-blocked-handoff.md (안 A — 합치기)
-- 대상    : 개발서버 → 운영서버
-- 위험도  : 낮음 — 관리자 전용 처리 함수 하나. 표 구조·수집 함수(report_client_error, 308)는 그대로
-- 편집기 경고: 뜸 — 무해 (함수 본문 안의 DELETE 단어 때문. 합친 뒤 옮겨 간 행 1개만 지운다)
--
-- 문제: 표에 UNIQUE (fingerprint, status)(165). 한 번 무시(또는 해결)한 오류가 재발하면 새 open 행이 생기고,
--   그 행을 다시 무시하려는 순간 기존 ignored 행과 겹쳐 유일 제약 위반 → 화면 「처리에 실패했습니다」.
--   「미해결로 되돌리기」도 같은 지문의 open 행이 이미 있으면 같은 식으로 실패한다.
--
-- 고침: 목표 상태(p_status)의 같은 지문 행이 **다른 id 로** 이미 있으면 그 행으로 합친다.
--   · 횟수 = 두 행의 합, 처음 발생 = 더 이른 쪽(least), 마지막 발생 = 더 늦은 쪽(greatest)
--   · 처리 정보(처리자·시각·메모) — 목표가 resolved/ignored 면 지금 처리로 갱신(메모를 비워 보내면 기존 메모 유지).
--     목표가 open 이면 비운다(165 와 같은 규칙)
--   · 오류 원문·스택·화면·브라우저·예상된 거부 여부(is_expected, 308) 등은 **마지막 발생이 더 늦은 행의 값**을 남긴다(최근 모습이 더 쓸모 있다)
--   · 그다음 지금 행을 지운다
--   없으면 165 와 똑같이 상태만 바꾼다.
--
-- 🔴 잠금: 두 행을 id 순서로 FOR UPDATE — 수집 함수(308)가 같은 open 행의 횟수를 올리는 것과 겹쳐도
--    횟수가 사라지지 않게(잠긴 동안 308 의 ON CONFLICT DO UPDATE 가 기다린다)
-- ⚠️ CREATE OR REPLACE(인자 그대로) — 실행 권한(authenticated) 보존. DROP 하지 말 것
--
-- 되돌리기: 165 의 resolve_client_error 블록(CREATE OR REPLACE ~ GRANT)을 다시 적용. 합쳐진 행은 그대로 남는다
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.resolve_client_error(
  p_id     uuid,
  p_status text,
  p_note   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_cur    public.client_error_logs%ROWTYPE;
  v_tgt    public.client_error_logs%ROWTYPE;
  v_tgt_id uuid;
  v_newer  public.client_error_logs%ROWTYPE;
BEGIN
  -- 관리자 권한 가드
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission denied';
  END IF;

  -- 허용 status 가드
  IF p_status NOT IN ('open', 'resolved', 'ignored') THEN
    RAISE EXCEPTION 'invalid status: %', p_status;
  END IF;

  SELECT * INTO v_cur FROM public.client_error_logs WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_error_log not found: %', p_id;
  END IF;

  -- 목표 상태의 같은 지문 행이 (다른 id 로) 없으면 165 와 똑같이 상태만 바꾼다
  SELECT t.id INTO v_tgt_id
    FROM public.client_error_logs t
   WHERE t.fingerprint = v_cur.fingerprint AND t.status = p_status AND t.id <> p_id;

  IF v_tgt_id IS NULL THEN
    UPDATE public.client_error_logs
       SET status       = p_status,
           resolved_by  = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
           resolved_at  = CASE WHEN p_status = 'open' THEN NULL ELSE now()      END,
           resolve_note = CASE WHEN p_status = 'open' THEN NULL ELSE p_note     END
     WHERE id = p_id;
    RETURN;
  END IF;

  -- ── 합치기: 두 행을 id 순서로 잠근 뒤 최신 값으로 다시 읽는다(교착 방지) ──
  PERFORM 1 FROM public.client_error_logs
   WHERE id IN (p_id, v_tgt_id) ORDER BY id FOR UPDATE;
  SELECT * INTO v_cur FROM public.client_error_logs WHERE id = p_id;
  SELECT * INTO v_tgt FROM public.client_error_logs WHERE id = v_tgt_id;
  IF v_cur.id IS NULL OR v_tgt.id IS NULL THEN
    RAISE EXCEPTION 'client_error_log changed concurrently: %', p_id;
  END IF;

  -- 원문·스택 등은 마지막 발생이 더 늦은 행의 값
  v_newer := CASE WHEN v_cur.last_seen_at > v_tgt.last_seen_at THEN v_cur ELSE v_tgt END;

  -- 지금 행을 먼저 지운다 — 목표 행은 이미 그 상태라 유일 제약과 무관하지만, 순서를 고정해 둔다
  DELETE FROM public.client_error_logs WHERE id = p_id;

  UPDATE public.client_error_logs t
     SET occurrence_count = v_tgt.occurrence_count + v_cur.occurrence_count,
         first_seen_at    = LEAST(v_tgt.first_seen_at, v_cur.first_seen_at),
         last_seen_at     = GREATEST(v_tgt.last_seen_at, v_cur.last_seen_at),
         source           = v_newer.source,
         kind             = v_newer.kind,
         message          = v_newer.message,
         error_code       = v_newer.error_code,
         stack            = v_newer.stack,
         page_hash        = v_newer.page_hash,
         context          = v_newer.context,
         user_agent       = v_newer.user_agent,
         user_id          = v_newer.user_id,
         is_expected      = v_newer.is_expected,   -- 308 이 더한 칸(예상된 업무 거부 구분)
         resolved_by      = CASE WHEN p_status = 'open' THEN NULL ELSE auth.uid() END,
         resolved_at      = CASE WHEN p_status = 'open' THEN NULL ELSE now()      END,
         resolve_note     = CASE WHEN p_status = 'open' THEN NULL
                                 ELSE COALESCE(NULLIF(btrim(p_note), ''), v_tgt.resolve_note) END
   WHERE t.id = v_tgt_id;
END;
$$;

COMMENT ON FUNCTION public.resolve_client_error(uuid, text, text) IS
  '[518, 베이스 165] 오류 묶음 상태 변경(open/resolved/ignored, 관리자). 같은 지문·같은 목표 상태의 다른 행이 있으면 그 행으로 합친다(횟수 합·처음/마지막 발생·최근 원문) — 재발한 오류를 다시 무시·해결·되돌릴 때 UNIQUE(fingerprint,status) 위반을 피한다.';

GRANT EXECUTE ON FUNCTION public.resolve_client_error(uuid, text, text) TO authenticated;

COMMIT;

-- ============================================================
-- 검증 (개발서버 — 관리자 브라우저 콘솔. SQL 편집기는 서비스 키라 is_admin() 가 거짓이다)
--   ① await db.rpc('report_client_error', {p_fingerprint:'fp-518-test', p_source:'admin', p_kind:'handled', p_message:'518 test'})
--      → 오류 로그 화면에서 그 행 「무시」
--   ② ① 의 report 를 한 번 더 → 새 open 행 → 「무시」 → 성공하고 ignored 행 하나에 횟수 2
--   ③ 같은 방식으로 「해결됨」·「미해결로 되돌리기」(같은 지문 open 행이 있을 때)도 성공
--   권한: SELECT p.proacl::text FROM pg_proc p WHERE p.proname = 'resolve_client_error';
-- ============================================================
