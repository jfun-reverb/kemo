-- ============================================================
-- 560_cs_case_query_functions.sql   (559 는 같은 날 브랜드 공개 기록이 먼저 씀)
-- CS 이력 관리 — 작업 1-4 (조회 함수: 표 · 요약 · 대화별 · 메모 요약)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md 4-1(표·요약 줄)·4-3(시간 계산)·4-4 ④·D-12·D-18·D-20
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-4
--
-- 함수 넷 + 내부 하나. 전부 정의자 권한 + search_path='' + **메시지 메뉴 권한 검사**(556 의 표 정책과 같은 기준 —
-- Q2). 정의자 권한인 이유: 회원 이름·이메일은 인플루언서 표에서 읽는데 그 표는 312 이후 관리자 통과 정책이 없다
-- (관리자 화면은 가림막 뷰로 읽는다). 이메일·이름은 가림막 6종(전화·LINE·PayPal·주소)이 아니라 그대로 준다.
--   · `_cs_case_rows(from, to, application_id, thread_id, include_audit)` — 내부. 표·요약·패널이 **같은 줄**을 쓰도록
--     한 곳에서 계산(첫 답장·감사용 제외). 대화별 패널만 include_audit=true
--   · `get_cs_cases(from, to)`     — 표(jsonb 배열 — 1,000행 상한을 피하려 행 집합이 아닌 값 하나로 준다)
--   · `get_cs_summary(from, to)`   — 요약 줄(항목별·진행현황별·출처별 건수 + 응답·해결 시간 평균·중앙값 전체·항목별)
--   · `get_cs_cases_for_conversation(application_id | thread_id)` — 대화 옆 CS 패널(건마다 붙은 회원 글 번호 포함)
--   · `get_cs_comment_summaries(case_ids)` — 건별 메모 전체 수·안 읽은 수(본인 글 제외 — COALESCE)
--
-- 규칙(4-3)
--   · 첫 답장: 앱 건 = 접수 **뒤** 그 대화의 첫 운영팀 글(일괄 발송·숨김·회수 제외) — 매번 계산. 수기 건 = 저장값.
--     「시간 미상」 건은 비운다(D-17). 한 대화의 여러 건이 같은 답장을 첫 답장으로 가질 수 있다(받아들임).
--   · 감사용 계정(influencers.is_audit) 건은 표·요약에서 뺀다. 대화별 패널은 감사용 회원 대화도 그대로 보인다(p_include_audit).
--   · 기간은 접수 시각 기준(비우면 전체).
--   · 시간 통계는 값이 없거나 「시간 미상」인 건을 빼고, 건수에는 넣는다.
--
-- ⚠️ 반환 칸을 바꾸려면 jsonb 라 함수 정의만 고치면 된다(행 집합이 아니어서 DROP 이 필요 없다 — 실행 권한 회수 유지).
-- 편집기 경고: 안 뜸(함수 생성·권한만)
-- 롤백: 파일 하단.
-- ============================================================

-- ── 내부: 표·요약 공용 줄 ──────────────────────────────────
CREATE OR REPLACE FUNCTION public._cs_case_rows(
  p_from timestamptz, p_to timestamptz,
  p_application_id uuid DEFAULT NULL, p_thread_id uuid DEFAULT NULL,
  p_include_audit boolean DEFAULT false   -- 대화별 패널은 감사용 회원 대화도 그대로 보인다
)
RETURNS TABLE (
  id uuid, case_no bigint, source text, application_id uuid, general_thread_id uuid,
  influencer_id uuid, influencer_name text, influencer_email text,
  campaign_id uuid, campaign_title text, recruit_type text, thread_title text,
  manual_name text, manual_email text, manual_category text,
  category_code text, status text, received_at timestamptz, first_reply_at timestamptz,
  completed_at timestamptz, completed_by_name text,
  summary_text text, summary_translated text, summary_translated_lang text, summary_edited boolean,
  response_body text, previous_case_id uuid, previous_case_no bigint,
  time_unknown boolean, origin text, source_deleted boolean, same_conversation_count bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT
    k.id, k.case_no, k.source, k.application_id, k.general_thread_id,
    k.influencer_id, i.name, i.email,
    k.campaign_id, COALESCE(c.title, k.manual_campaign_name), c.recruit_type, th.title,
    k.manual_name, k.manual_email, k.manual_category,
    k.category_code, k.status, k.received_at,
    CASE
      WHEN k.time_unknown THEN NULL
      WHEN k.source IN ('mail','line','other') THEN k.first_reply_at
      ELSE (
        SELECT min(m.created_at) FROM public.application_messages m
         WHERE m.sender_kind = 'admin'
           AND m.broadcast_id IS NULL
           AND m.hidden_by_admin_at IS NULL
           AND m.self_withdrawn_at IS NULL
           AND m.created_at > k.received_at
           AND CASE WHEN k.application_id IS NOT NULL THEN m.application_id = k.application_id
                    ELSE m.general_thread_id = k.general_thread_id END)
    END,
    k.completed_at, k.completed_by_name,
    -- 요약: 저장된 요약 글이 있으면 그것, 없으면 시작 회원 글(D-12)
    COALESCE(k.summary_body, sm.body),
    CASE WHEN k.summary_body IS NOT NULL THEN k.summary_translated
         WHEN sm.translate_status = 'done' THEN sm.body_translated END,
    CASE WHEN k.summary_body IS NOT NULL THEN k.summary_translated_lang
         WHEN sm.translate_status = 'done' THEN sm.translated_lang END,
    k.summary_edited,
    k.response_body, k.previous_case_id, pk.case_no,
    k.time_unknown, k.origin,
    (k.source IN ('campaign_inquiry','service_inquiry') AND k.application_id IS NULL AND k.general_thread_id IS NULL),
    CASE WHEN k.application_id IS NULL AND k.general_thread_id IS NULL THEN 1
         WHEN k.application_id IS NOT NULL THEN
              (SELECT count(*) FROM public.cs_cases s WHERE s.application_id = k.application_id)
         ELSE (SELECT count(*) FROM public.cs_cases s WHERE s.general_thread_id = k.general_thread_id) END
  FROM public.cs_cases k
  LEFT JOIN public.influencers             i  ON i.id  = k.influencer_id
  LEFT JOIN public.campaigns               c  ON c.id  = k.campaign_id
  LEFT JOIN public.general_inquiry_threads th ON th.id = k.general_thread_id
  LEFT JOIN public.application_messages    sm ON sm.id = k.summary_message_id
  LEFT JOIN public.cs_cases                pk ON pk.id = k.previous_case_id
  WHERE (p_from IS NULL OR k.received_at >= p_from)
    AND (p_to   IS NULL OR k.received_at <  p_to)
    AND (p_application_id IS NULL OR k.application_id    = p_application_id)
    AND (p_thread_id      IS NULL OR k.general_thread_id = p_thread_id)
    AND (p_include_audit OR COALESCE(i.is_audit, false) = false);
$$;
COMMENT ON FUNCTION public._cs_case_rows(timestamptz, timestamptz, uuid, uuid, boolean) IS
  '[560] 내부 — 표·요약·대화별 패널 공용 줄. 첫 답장 계산·감사용 제외가 여기 한 곳.';
REVOKE ALL ON FUNCTION public._cs_case_rows(timestamptz, timestamptz, uuid, uuid, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public._cs_case_rows(timestamptz, timestamptz, uuid, uuid, boolean) FROM anon, authenticated;

-- ── 표 ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_cs_cases(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
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
  RETURN COALESCE(
    (SELECT jsonb_agg(to_jsonb(r) ORDER BY r.received_at DESC, r.case_no DESC)
       FROM public._cs_case_rows(p_from, p_to) r),
    '[]'::jsonb);
END;
$$;

-- ── 요약 줄 ─────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.get_cs_summary(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
BEGIN
  IF NOT public.has_permission('menu.messages', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;

  WITH r AS (
    SELECT *,
           extract(epoch FROM (first_reply_at - received_at)) AS response_sec,
           extract(epoch FROM (completed_at   - received_at)) AS resolve_sec
      FROM public._cs_case_rows(p_from, p_to)
  ),
  t AS (   -- 시간 통계 대상(시간 미상 제외 · 음수 제외)
    SELECT category_code,
           CASE WHEN NOT time_unknown AND response_sec >= 0 THEN response_sec END AS response_sec,
           CASE WHEN NOT time_unknown AND status = 'done' AND resolve_sec >= 0 THEN resolve_sec END AS resolve_sec
      FROM r
  )
  SELECT jsonb_build_object(
    'total', (SELECT count(*) FROM r),
    'by_status',   COALESCE((SELECT jsonb_object_agg(status, n) FROM (SELECT status, count(*) n FROM r GROUP BY status) x), '{}'::jsonb),
    'by_source',   COALESCE((SELECT jsonb_object_agg(source, n) FROM (SELECT source, count(*) n FROM r GROUP BY source) x), '{}'::jsonb),
    -- 항목이 빈 건(진행중 미분류)은 키 '' 로
    'by_category', COALESCE((SELECT jsonb_object_agg(COALESCE(category_code, ''), n)
                               FROM (SELECT category_code, count(*) n FROM r GROUP BY category_code) x), '{}'::jsonb),
    'response', (SELECT jsonb_build_object(
                   'count',     count(response_sec),
                   'avg_sec',   round(avg(response_sec)),
                   'median_sec', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY response_sec))::numeric))
                 FROM t),
    'resolve',  (SELECT jsonb_build_object(
                   'count',     count(resolve_sec),
                   'avg_sec',   round(avg(resolve_sec)),
                   'median_sec', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY resolve_sec))::numeric))
                 FROM t),
    -- 집계를 겹치지 않게 안에서 묶고 바깥에서 객체로(42803)
    'by_category_time', COALESCE((
       SELECT jsonb_object_agg(z.k, z.v)
         FROM (SELECT COALESCE(category_code, '') AS k,
                      jsonb_build_object(
                        'response_avg_sec',    round(avg(response_sec)),
                        'response_median_sec', round((percentile_cont(0.5) WITHIN GROUP (ORDER BY response_sec))::numeric),
                        'resolve_avg_sec',     round(avg(resolve_sec)),
                        'resolve_median_sec',  round((percentile_cont(0.5) WITHIN GROUP (ORDER BY resolve_sec))::numeric)) AS v
                 FROM t GROUP BY category_code) z), '{}'::jsonb)
  ) INTO v;
  RETURN v;
END;
$$;

-- ── 대화별(CS 패널) ──────────────────────────────────────────
-- 응모건이면 p_application_id, 서비스 문의면 p_thread_id — 정확히 하나
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
             to_jsonb(r) || jsonb_build_object(
               'message_ids', COALESCE((SELECT jsonb_agg(l.message_id ORDER BY m.created_at)
                                          FROM public.cs_case_messages l
                                          JOIN public.application_messages m ON m.id = l.message_id
                                         WHERE l.case_id = r.id), '[]'::jsonb),
               'response_translated',      k.response_translated,
               'response_translated_lang', k.response_translated_lang,
               'manual_campaign_name',     k.manual_campaign_name)
             ORDER BY r.received_at, r.case_no)
      FROM public._cs_case_rows(NULL, NULL, p_application_id, p_thread_id, true) r
      JOIN public.cs_cases k ON k.id = r.id
  ), '[]'::jsonb);
END;
$$;

-- ── 메모 요약(표의 메모 열 · 패널의 분홍 숫자 — D-20) ────────────
-- p_case_ids 를 비우면 전부. 안 읽은 수 = 내가 안 읽은 + 내가 쓰지 않은 + 지우지 않은 메모
CREATE OR REPLACE FUNCTION public.get_cs_comment_summaries(p_case_ids uuid[] DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_me uuid := auth.uid();
BEGIN
  IF NOT public.has_permission('menu.messages', 'read') THEN
    RAISE EXCEPTION 'forbidden' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_object_agg(case_id, jsonb_build_object('total', total, 'unread', unread))
      FROM (
        SELECT cm.case_id,
               count(*) AS total,
               count(*) FILTER (
                 WHERE COALESCE(cm.author_id = v_me, false) = false
                   AND NOT EXISTS (SELECT 1 FROM public.cs_case_comment_reads rd
                                    WHERE rd.comment_id = cm.id AND rd.admin_auth_id = v_me)) AS unread
          FROM public.cs_case_comments cm
         WHERE cm.deleted_at IS NULL
           AND (p_case_ids IS NULL OR cm.case_id = ANY (p_case_ids))
         GROUP BY cm.case_id
      ) s
  ), '{}'::jsonb);
END;
$$;

-- ── 실행 권한: 로그인 사용자만(안에서 메시지 메뉴 권한을 본다) ────────
REVOKE ALL ON FUNCTION public.get_cs_cases(timestamptz, timestamptz)              FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_cs_summary(timestamptz, timestamptz)            FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_cs_cases_for_conversation(uuid, uuid)           FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_cs_comment_summaries(uuid[])                    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_cs_cases(timestamptz, timestamptz)           TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_cs_summary(timestamptz, timestamptz)         TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_cs_cases_for_conversation(uuid, uuid)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_cs_comment_summaries(uuid[])                 TO authenticated;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증(개발서버) — 관리자 역할로 한 번씩 실제 호출(42804·42702 유형은 호출해야 드러난다)
-- ============================================================
/*
-- SQL 편집기에서 관리자 역할 흉내: set_config('request.jwt.claims', {"sub":<관리자 auth_id>,"role":"authenticated"}) + SET ROLE authenticated
SELECT jsonb_array_length(public.get_cs_cases(NULL, NULL));          -- 백필 건수와 같아야(감사용 제외)
SELECT public.get_cs_summary(NULL, NULL);
SELECT public.get_cs_cases_for_conversation(<application_id>, NULL);
SELECT public.get_cs_comment_summaries(NULL);                        -- 메모 없으면 {}
-- 회원 역할 흉내로 같은 호출 → forbidden(42501)
*/

-- ============================================================
-- 롤백
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(함수 삭제)
-- DROP FUNCTION IF EXISTS public.get_cs_comment_summaries(uuid[]);
-- DROP FUNCTION IF EXISTS public.get_cs_cases_for_conversation(uuid, uuid);
-- DROP FUNCTION IF EXISTS public.get_cs_summary(timestamptz, timestamptz);
-- DROP FUNCTION IF EXISTS public.get_cs_cases(timestamptz, timestamptz);
-- DROP FUNCTION IF EXISTS public._cs_case_rows(timestamptz, timestamptz, uuid, uuid, boolean);
