-- ============================================================
-- 479_admin_unread_counts_exclude_general.sql
-- 일반 문의 창구 — 데이터 모델 ⑤ 관리자 안읽음 집계에 「응모가 있는 행만」 방어 조건 한 줄
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-4 ③ · §5-5 ⑤
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ⑤)
-- 선행: 없음(475 와 **같은 배포**에 넣는다 — 응모 없는 행이 생기기 시작하는 순간부터 필요)
--
-- 왜: application_message_admin_unread_counts 는 application_id 로 묶는다. 일반 문의 행은
--   application_id 가 NULL 이라 **NULL 하나가 한 묶음**이 되어 여러 회원의 문의가 뒤섞인 유령 행이 나온다.
--   일반 문의의 안읽음은 478 의 general_inquiry_admin_unread_counts(회원 기준)가 센다.
--
-- 베이스: 144 (이 함수의 유일한 정의 파일 — grep 결과 144 하나뿐. 시그니처·반환 모양·가드 불변).
--   바뀐 것은 WHERE 절의 `AND m.application_id IS NOT NULL` 한 줄과 COMMENT 뿐이다.
--   CREATE OR REPLACE 라 권한(144 의 REVOKE PUBLIC·anon / GRANT authenticated)은 보존된다 — DROP 하지 않는다.
--
-- ── 적용 전후 확인 ──
--   [P1] 적용 전(관리자 로그인 브라우저 콘솔): 결과를 저장해 둔다
--        await db.rpc('application_message_admin_unread_counts')
--   [V1] 적용 뒤 같은 호출 — 응모건 행은 [P1] 과 한 건도 안 달라야 한다(일반 문의 행이 아직 없으므로 동일).
--   [V2] 권한 보존: SELECT p.proacl::text FROM pg_proc p
--         WHERE p.pronamespace='public'::regnamespace AND p.proname='application_message_admin_unread_counts';
--        기대: 맨 앞 =X/ 없음, anon 없음, authenticated=X 있음
--   [V3] 함수 본문에 새 조건이 들어갔나:
--        SELECT prosrc LIKE '%m.application_id IS NOT NULL%' FROM pg_proc
--         WHERE pronamespace='public'::regnamespace AND proname='application_message_admin_unread_counts';  기대: t
--
-- ── 되돌리는 방법 ──
--   144 파일의 「8. 함수 application_message_admin_unread_counts」 정의(CREATE OR REPLACE)를 그대로 다시 실행.
--   (일반 문의 행이 생긴 뒤에 되돌리면 NULL 유령 행이 다시 나온다.)
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.application_message_admin_unread_counts(
  p_admin_auth_id uuid DEFAULT NULL  -- NULL 이면 auth.uid() 사용
) RETURNS TABLE (application_id uuid, unread_count bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
  -- 관리자 전용 가드: 인플루언서가 호출하면 전체 미읽음 집계가 노출되는 취약점 차단
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '관리자 전용 함수입니다'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  RETURN QUERY
  SELECT
    m.application_id,
    count(*) AS unread_count
  FROM public.application_messages m
  LEFT JOIN public.application_message_admin_reads r
    ON r.message_id = m.id
   AND r.admin_auth_id = COALESCE(p_admin_auth_id, auth.uid())
  WHERE m.sender_kind = 'influencer'
    AND m.application_id IS NOT NULL  -- [479] 일반 문의(응모 없는 행)는 NULL 한 묶음이 되어 유령 행이 되므로 뺀다
    AND m.hidden_by_admin_at IS NULL
    AND m.self_withdrawn_at IS NULL  -- 인플루언서 본인 회수 메시지는 관리자 미읽음 집계에서 제외
    AND r.message_id IS NULL         -- 본인이 안 읽음
  GROUP BY m.application_id;
END;
$$;

COMMENT ON FUNCTION public.application_message_admin_unread_counts(uuid) IS
  '[144][479] 관리자 본인 기준 응모건별 미읽음 인플루언서 메시지 수 집계. '
  'is_admin() 가드 포함 — 비관리자 호출 시 insufficient_privilege 예외. '
  'LANGUAGE plpgsql (RAISE EXCEPTION 사용 위해). p_admin_auth_id NULL = auth.uid(). SECURITY DEFINER + search_path 고정. '
  '[479] 응모가 없는 행(일반 문의)은 제외 — 그쪽은 general_inquiry_admin_unread_counts(478)가 회원 기준으로 센다. '
  '인플루언서 GNB 미읽음 배지는 application_message_summary 뷰(security_invoker=true)로 직접 조회.';

NOTIFY pgrst, 'reload schema';

COMMIT;
