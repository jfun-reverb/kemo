-- ============================================================
-- 566_cs_case_version_fields.sql
-- CS 이력 관리 — 작업 2-0(화면 공용 기반)이 필요로 한 조회 칸
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 「구현 결과」 2-0
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 2-0
--
-- 왜: 쓰기 함수(562)는 p_version(동시 저장 막기)을 요구하는데 조회 함수(560)는 version 을 주지 않는다.
--   화면이 표를 따로 읽어 version 을 붙이면, 두 조회 사이에 다른 관리자가 저장한 경우 **옛 내용 + 새 version** 이
--   되어 저장이 남의 변경을 경고 없이 덮는다. 그래서 같은 조회(한 문장) 안에서 version 을 함께 준다.
--
--   · `_cs_case_extra(cs_cases)` — 내부. 패널·건 하나 공용 추가 칸(version · 비운 시각 · 수기 칸 · 대응 안내 번역)
--   · `get_cs_cases_for_conversation` — 560 판 베이스(563 은 이 함수를 안 고쳤다). 추가 칸을 `_cs_case_extra` 로
--   · `get_cs_case(p_case_id)` — 신설. 건 상세 모달·수기 편집용 한 건(감사용 회원 건도 — 표에서 빠진 건은 열 일이 없다)
--   · `_cs_case_rows`(563 판)는 그대로 — 반환 칸을 늘리려면 DROP 이 필요해 건드리지 않는다
--
-- 🔴 수기 칸은 563 이 비운 건(personal_purged_at)에서 이미 NULL 이다 — 여기서 따로 가리지 않는다
-- 편집기 경고: 안 뜸(함수 생성·권한만)
-- 롤백: 파일 하단
-- ============================================================

-- ── 내부: 추가 칸 ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cs_case_extra(k public.cs_cases)
RETURNS jsonb
LANGUAGE sql
STABLE   -- timestamptz → jsonb 는 시간대 설정을 따른다(IMMUTABLE 아님)
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'version',                  k.version,
    'personal_purged_at',       k.personal_purged_at,
    'response_translated',      k.response_translated,
    'response_translated_lang', k.response_translated_lang,
    'manual_campaign_name',     k.manual_campaign_name,
    'manual_inquiry_ja',        k.manual_inquiry_ja,
    'manual_inquiry_ko',        k.manual_inquiry_ko,
    'manual_response_ja',       k.manual_response_ja,
    'manual_response_ko',       k.manual_response_ko,
    -- 수기 건 편집 칸 — 반환의 first_reply_at 은 「시간 미상」이면 비우므로 저장값을 따로
    'first_reply_at_stored',    k.first_reply_at);
$$;
REVOKE ALL ON FUNCTION public._cs_case_extra(public.cs_cases) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._cs_case_extra(public.cs_cases) FROM anon, authenticated;

-- ── 대화별(CS 패널) — 560 판 + 추가 칸 ─────────────────────
CREATE OR REPLACE FUNCTION public.get_cs_cases_for_conversation(
  p_application_id uuid DEFAULT NULL,
  p_thread_id      uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('menu.messages', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF (p_application_id IS NULL) = (p_thread_id IS NULL) THEN
    RAISE EXCEPTION 'invalid_conversation' USING ERRCODE = '22023';
  END IF;

  RETURN COALESCE((
    SELECT jsonb_agg(
             to_jsonb(r) || public._cs_case_extra(k) || jsonb_build_object(
               'message_ids', COALESCE((SELECT jsonb_agg(l.message_id ORDER BY m.created_at)
                                          FROM public.cs_case_messages l
                                          JOIN public.application_messages m ON m.id = l.message_id
                                         WHERE l.case_id = r.id), '[]'::jsonb))
             ORDER BY r.received_at, r.case_no)
      FROM public._cs_case_rows(NULL, NULL, p_application_id, p_thread_id, true) r
      JOIN public.cs_cases k ON k.id = r.id
  ), '[]'::jsonb);
END;
$$;

-- ── 건 하나(건 상세 모달·수기 편집) ─────────────────────────
-- 없거나 권한이 없으면: 권한 없음 → forbidden(42501) · 없음 → NULL
CREATE OR REPLACE FUNCTION public.get_cs_case(p_case_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NOT public.has_permission('menu.messages', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  IF p_case_id IS NULL THEN RETURN NULL; END IF;

  -- 기간 인자를 비운 공용 줄에서 한 건만 — 감사용 회원 건도 연다(include_audit)
  RETURN (
    SELECT to_jsonb(r) || public._cs_case_extra(k)
      FROM public._cs_case_rows(NULL, NULL, NULL, NULL, true) r
      JOIN public.cs_cases k ON k.id = r.id
     WHERE r.id = p_case_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_cs_case(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cs_case(uuid) TO authenticated;
-- get_cs_cases_for_conversation 은 CREATE OR REPLACE 라 560 의 권한(로그인만)이 그대로다

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버) — 관리자 역할 흉내로
-- ============================================================
/*
SELECT (public.get_cs_cases_for_conversation(<application_id>, NULL)->0)->>'version';   -- 숫자
SELECT public.get_cs_case(<case_id>)->>'version';                                        -- 숫자
SELECT public.get_cs_case('00000000-0000-0000-0000-000000000000');                       -- NULL
-- 회원 역할 흉내로 → forbidden(42501)
*/

-- ============================================================
-- 롤백 — 560 의 get_cs_cases_for_conversation 정의를 다시 실행한 뒤
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(함수 삭제)
-- DROP FUNCTION IF EXISTS public.get_cs_case(uuid);
-- DROP FUNCTION IF EXISTS public._cs_case_extra(public.cs_cases);
