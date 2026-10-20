-- ============================================================
-- 557_cs_case_auto_create_and_backfill.sql
-- CS 이력 관리 — 작업 1-3 (회원 글 → CS 건 자동 생성 트리거 + 최근 3개월 백필, 한 파일)
-- 사양서: docs/specs/2026-10-16-cs-history-management.md D-3·D-6·D-7·D-12·D-17 · 4-2·4-3 · 4-4 ③·3-a·⑤
-- 작업표: docs/specs/2026-10-19-cs-history-management-breakdown.md 1-3 (S-5)
--
-- ① 트리거 `trg_cs_case_on_member_message` — application_messages 에 회원 글(sender_kind='influencer')이
--    들어오면 그 대화(응모건 = application_id / 서비스 문의 = general_thread_id)의
--      · 열린 건(진행중·확인필요)이 있으면 → 접수가 가장 늦은 열린 건에 글을 붙인다(3-a)
--      · 없으면 → 새 건(진행중). 그 대화에 완료 건이 있으면 가장 늦은 완료 건을 「이전 건」으로(재문의 — D-6)
--    운영팀 글·일괄 발송은 운영팀 글이라 건을 만들지 않는다(조건 sender_kind).
--    🔴 **트리거가 실패해도 회원의 글은 들어가야 한다** — 예외를 삼키고 경고만 남긴다. 그러지 않으면
--       트리거의 작은 결함 하나로 회원 문의가 통째로 멈춘다(S-5 · 작업표 1-3 주의). 대가: 실패한 글은
--       건에 안 붙는다 — 화면(1-4)은 붙지 않은 회원 글을 「건 없음」으로 보이고, 운영자가 「CS 추가」로 붙인다.
--    🔴 정의자 권한(SECURITY DEFINER) + search_path='' — 회원 글은 정의자 권한 발신 함수(509·508)로 들어오고,
--       CS 표에는 쓰기 권한·정책이 없다(556). 발신 함수 자체는 건드리지 않는다(규칙 D — 다시 정의할 일 없음).
--    같은 대화에 글이 동시에 둘 들어와 건이 둘 생기지 않게 대화 단위 트랜잭션 잠금(advisory)을 건다.
-- ② 백필(D-7) — 이 파일 안에서 트리거 바로 뒤에 한 번. 사이에 끼는 회원 글이 없도록 같은 트랜잭션이다
--    (편집기는 파일 전체를 한 트랜잭션으로 돌린다). 「최근 3개월 대화」 = 마지막 보이는 회원 글이 3개월 안.
--      · 대화마다 한 건 · 접수 = 3개월 창 안 첫 보이는 회원 글 · 창 안의 보이는 회원 글을 그 건에 붙인다
--      · 상태: 지금 미응대면 진행중, 아니면 완료(항목 「미분류(과거)」 · 완료 시각 = 마지막 응대 완료 시각 ·
--        완료한 사람 비움) · 만들어진 경위 = 과거 이관
--      · 대응 안내 내용 = 접수 뒤 그 대화의 마지막 보이는 운영팀 글(일괄 발송 제외) + 그 글의 번역(D-17 · 4-4 ⑧ —
--        옮겨 온 값은 자동 번역하지 않고 원본의 번역을 쓴다)
--      · 캠페인 제목을 `manual_campaign_name` 에 스냅샷(2026-10-20 사용자 결정 — 캠페인·응모가 지워져도
--        「어느 캠페인 문의였나」가 남게. 회원 이름은 개인정보라 남기지 않는다) — 트리거도 같다
--    「미응대」 판정은 받은편지함 배지와 같은 기준:
--      · 응모건: 응대 완료 기록(application_message_resolutions.resolved_after_message_at) 뒤에 보이는 회원 글이 있음
--      · 서비스 문의: 뷰 general_inquiry_thread_summary.needs_reply(508 — 열림 + 마지막 보이는 글이 회원)
--    진행중 백필 건은 항목을 비워 둔다 — 「미분류(과거)」는 고르는 자리에서 숨기므로(555), 넣어 두면 완료 양식이
--    숨은 값을 들고 열린다. 완료 건만 그 항목을 쓴다(검사 규칙상 완료는 항목 필수).
--
-- 「보이는 글」 = 숨김(hidden_by_admin_at)·본인 회수(self_withdrawn_at) 아닌 글.
--
-- 확인한 것(2026-10-20)
--   [트리거 없음] application_messages 에는 마이그레이션이 만든 트리거가 없다(S-5). 번역 웹훅은 대시보드에서 만든
--     것이라 이 파일과 무관(삽입 뒤 비동기). 이 트리거는 AFTER 라 웹훅과 순서가 겹치지 않는다.
--   [회원 id] applications.user_id = influencers.id(인플루언서 행은 id 로 찾는다 — apply-and-cancel 규칙)
--   [서비스 문의 판정] 508 뷰(general_inquiry_thread_summary)의 needs_reply · 닫은 시각 closed_at(504)
--
-- 편집기 경고: 뜸 — 무해(트리거를 지우고 같은 이름으로 다시 만든다. 백필은 행을 넣기만 한다)
-- 롤백: 파일 하단.
-- ============================================================

-- 메시지 표에 거는 트리거 생성은 표 잠금을 잡는다 — 이미 긴 조회가 있으면 줄 맨 앞에서 뒤 조회를 다 막으므로
-- 5초 안에 못 잡으면 실패시키고 다시 돌린다(대기열 정체 방지). 이 잠금 덕에 트리거와 백필 사이에 끼는 회원 글은 없다.
SET LOCAL lock_timeout = '5s';

-- ── ① 자동 생성 트리거 ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public._cs_case_on_member_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
SET lock_timeout = '2s'   -- 대화 잠금 대기를 2초에서 끊어 예외로 흘린다(무한 대기면 회원 발신이 8초 제한에 걸려 통째로 실패)
AS $$
DECLARE
  v_source        text;
  v_influencer    uuid;
  v_campaign      uuid;
  v_campaign_name text;
  v_case          uuid;
  v_prev          uuid;
BEGIN
  BEGIN
    IF NEW.application_id IS NOT NULL THEN
      v_source := 'campaign_inquiry';
      PERFORM pg_advisory_xact_lock(hashtext('cs_case_conv:' || NEW.application_id::text));
      SELECT i.id, a.campaign_id, c.title
        INTO v_influencer, v_campaign, v_campaign_name
        FROM public.applications a
        LEFT JOIN public.influencers i ON i.id = a.user_id
        LEFT JOIN public.campaigns   c ON c.id = a.campaign_id
       WHERE a.id = NEW.application_id;

      SELECT id INTO v_case FROM public.cs_cases
       WHERE application_id = NEW.application_id AND status <> 'done'
       ORDER BY received_at DESC, created_at DESC LIMIT 1;
      IF v_case IS NULL THEN
        SELECT id INTO v_prev FROM public.cs_cases
         WHERE application_id = NEW.application_id AND status = 'done'
         ORDER BY received_at DESC, created_at DESC LIMIT 1;
      END IF;

    ELSIF NEW.general_thread_id IS NOT NULL THEN
      v_source := 'service_inquiry';
      PERFORM pg_advisory_xact_lock(hashtext('cs_case_conv:' || NEW.general_thread_id::text));
      SELECT t.influencer_id INTO v_influencer
        FROM public.general_inquiry_threads t WHERE t.id = NEW.general_thread_id;

      SELECT id INTO v_case FROM public.cs_cases
       WHERE general_thread_id = NEW.general_thread_id AND status <> 'done'
       ORDER BY received_at DESC, created_at DESC LIMIT 1;
      IF v_case IS NULL THEN
        SELECT id INTO v_prev FROM public.cs_cases
         WHERE general_thread_id = NEW.general_thread_id AND status = 'done'
         ORDER BY received_at DESC, created_at DESC LIMIT 1;
      END IF;

    ELSE
      RETURN NULL;   -- 대화를 알 수 없는 글(옛 형식) — 건을 만들지 않는다
    END IF;

    IF v_case IS NULL THEN
      INSERT INTO public.cs_cases (
        source, application_id, general_thread_id, influencer_id, campaign_id, manual_campaign_name,
        status, received_at, summary_message_id, previous_case_id, origin
      ) VALUES (
        v_source,
        CASE WHEN v_source = 'campaign_inquiry' THEN NEW.application_id END,
        CASE WHEN v_source = 'service_inquiry'  THEN NEW.general_thread_id END,
        v_influencer, v_campaign, left(v_campaign_name, 500),
        'in_progress', NEW.created_at, NEW.id, v_prev, 'live'
      )
      RETURNING id INTO v_case;
    END IF;

    INSERT INTO public.cs_case_messages (message_id, case_id)
    VALUES (NEW.id, v_case)
    ON CONFLICT (message_id) DO NOTHING;

  EXCEPTION WHEN others THEN
    -- 회원 글은 살린다(위 머리말). 실패 내용만 남긴다 — 회원 본문은 남기지 않는다
    RAISE WARNING 'cs_case_auto_create_failed message=% state=% err=%', NEW.id, SQLSTATE, SQLERRM;
  END;
  RETURN NULL;
END;
$$;

COMMENT ON FUNCTION public._cs_case_on_member_message() IS
  '[557] 회원 글 → CS 건 자동 생성·연결(3-a·D-6). 실패해도 회원 글은 들어간다(예외를 삼키고 경고만).';

REVOKE ALL ON FUNCTION public._cs_case_on_member_message() FROM PUBLIC;
REVOKE ALL ON FUNCTION public._cs_case_on_member_message() FROM anon, authenticated;

DROP TRIGGER IF EXISTS trg_cs_case_on_member_message ON public.application_messages;
CREATE TRIGGER trg_cs_case_on_member_message
  AFTER INSERT ON public.application_messages
  FOR EACH ROW
  WHEN (NEW.sender_kind = 'influencer')
  EXECUTE FUNCTION public._cs_case_on_member_message();

-- ── ② 백필(D-7) — 최근 3개월 대화마다 한 건 ─────────────────────
-- 대화 키: 응모건이면 'a:'||application_id, 서비스 문의면 't:'||general_thread_id
WITH visible AS (
  SELECT m.id, m.application_id, m.general_thread_id, m.sender_kind, m.created_at,
         m.broadcast_id, m.body, m.body_translated, m.translated_lang, m.translate_status,
         CASE WHEN m.application_id IS NOT NULL THEN 'a:' || m.application_id::text
              ELSE 't:' || m.general_thread_id::text END AS conv
    FROM public.application_messages m
   WHERE m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at IS NULL
     AND m.created_at >= now() - interval '3 months'   -- 필요한 글은 전부 창 안(운영팀 글도 접수 뒤라 창 안)
     AND (m.application_id IS NOT NULL OR m.general_thread_id IS NOT NULL)
),
member_win AS (   -- 3개월 창 안의 보이는 회원 글
  SELECT * FROM visible
   WHERE sender_kind = 'influencer'
     AND created_at >= now() - interval '3 months'
),
conv AS (         -- 대상 대화 = 창 안에 회원 글이 있는 대화(= 마지막 회원 글이 3개월 안)
  SELECT conv,
         min(application_id::text)::uuid     AS application_id,
         min(general_thread_id::text)::uuid  AS general_thread_id,
         min(created_at)                     AS received_at,
         max(created_at)                     AS last_member_at,
         (array_agg(id ORDER BY created_at, id))[1] AS first_msg_id
    FROM member_win
   GROUP BY conv
),
-- 대화에 이미 건이 있으면 건너뛴다(같은 파일을 다시 돌려도 두 벌이 생기지 않게)
todo AS (
  SELECT c.* FROM conv c
   WHERE NOT EXISTS (
     SELECT 1 FROM public.cs_cases k
      WHERE (c.application_id    IS NOT NULL AND k.application_id    = c.application_id)
         OR (c.general_thread_id IS NOT NULL AND k.general_thread_id = c.general_thread_id))
),
judged AS (
  SELECT t.*,
         CASE
           WHEN t.application_id IS NOT NULL THEN
             -- 응대 완료 기록 뒤에 회원 글이 있으면(또는 기록이 없으면) 미응대
             (r.application_id IS NULL OR r.resolved_after_message_at < t.last_member_at)
           ELSE COALESCE(s.needs_reply, true)
         END AS unanswered,
         r.resolved_at        AS app_resolved_at,
         th.closed_at         AS thread_closed_at,
         th.influencer_id     AS thread_influencer
    FROM todo t
    LEFT JOIN public.application_message_resolutions r ON r.application_id = t.application_id
    LEFT JOIN public.general_inquiry_thread_summary  s ON s.thread_id      = t.general_thread_id
    LEFT JOIN public.general_inquiry_threads         th ON th.id           = t.general_thread_id
),
last_admin AS (   -- 접수 뒤 그 대화의 마지막 보이는 운영팀 글(일괄 발송 제외) — 대응 안내 내용 미리 채움
  SELECT DISTINCT ON (j.conv)
         j.conv, v.body, v.body_translated, v.translated_lang, v.translate_status, v.created_at
    FROM judged j
    JOIN visible v ON v.conv = j.conv
   WHERE v.sender_kind = 'admin'
     AND v.broadcast_id IS NULL
     AND v.created_at > j.received_at
   ORDER BY j.conv, v.created_at DESC
),
ins AS (
  INSERT INTO public.cs_cases (
    source, application_id, general_thread_id, influencer_id, campaign_id, manual_campaign_name,
    category_code, status, received_at, completed_at,
    response_body, response_translated, response_translated_lang, response_translate_status,
    summary_message_id, origin
  )
  SELECT
    CASE WHEN j.application_id IS NOT NULL THEN 'campaign_inquiry' ELSE 'service_inquiry' END,
    j.application_id,
    j.general_thread_id,
    COALESCE(ai.id, j.thread_influencer),
    a.campaign_id,
    left(c.title, 500),
    CASE WHEN j.unanswered THEN NULL ELSE 'legacy_unclassified' END,
    CASE WHEN j.unanswered THEN 'in_progress' ELSE 'done' END,
    j.received_at,
    CASE WHEN j.unanswered THEN NULL
         ELSE GREATEST(j.received_at,
                       COALESCE(j.app_resolved_at, j.thread_closed_at, la.created_at, j.last_member_at)) END,
    -- 첨부만 있는 운영팀 글은 본문이 빈 글이라 대응 안내를 비워 둔다
    NULLIF(btrim(left(la.body, 10000)), ''),
    CASE WHEN NULLIF(btrim(la.body), '') IS NOT NULL AND la.translate_status = 'done' THEN left(la.body_translated, 10000) END,
    CASE WHEN NULLIF(btrim(la.body), '') IS NOT NULL AND la.translate_status = 'done' THEN la.translated_lang END,
    CASE WHEN NULLIF(btrim(la.body), '') IS NULL THEN NULL WHEN la.translate_status = 'done' AND la.body_translated IS NOT NULL THEN 'done' ELSE 'skipped' END,
    j.first_msg_id,
    'backfill'
  FROM judged j
  LEFT JOIN public.applications a  ON a.id  = j.application_id
  LEFT JOIN public.influencers  ai ON ai.id = a.user_id
  LEFT JOIN public.campaigns    c  ON c.id  = a.campaign_id
  LEFT JOIN last_admin          la ON la.conv = j.conv
  RETURNING id, application_id, general_thread_id
)
INSERT INTO public.cs_case_messages (message_id, case_id)
SELECT mw.id, ins.id
  FROM ins
  JOIN member_win mw
    ON (ins.application_id    IS NOT NULL AND mw.application_id    = ins.application_id)
    OR (ins.general_thread_id IS NOT NULL AND mw.general_thread_id = ins.general_thread_id)
ON CONFLICT (message_id) DO NOTHING;

NOTIFY pgrst, 'reload schema';

-- 백필 결과(파일 끝 확인 조회 — 편집기 결과 창에 마지막 결과로 보인다)
SELECT
  count(*)                                                   AS backfill_cases,
  count(*) FILTER (WHERE status = 'in_progress')             AS in_progress,
  count(*) FILTER (WHERE status = 'done')                    AS done,
  count(*) FILTER (WHERE source = 'campaign_inquiry')        AS campaign_inquiry,
  count(*) FILTER (WHERE source = 'service_inquiry')         AS service_inquiry,
  count(*) FILTER (WHERE response_body IS NOT NULL)          AS with_response,
  (SELECT count(*) FROM public.cs_case_messages l JOIN public.cs_cases k ON k.id = l.case_id
    WHERE k.origin = 'backfill')                             AS linked_messages
FROM public.cs_cases WHERE origin = 'backfill';

-- ============================================================
-- 검증 (개발서버 — 실제 발신으로, 작업표 1-3 완료 정의)
-- ============================================================
/*
-- 시험 회원으로 로그인한 화면에서: ① 승인된 응모건에 문의 1통 ② 서비스 문의 1통 → 각각 건이 하나씩 생겼는지
SELECT case_no, source, status, origin, received_at, previous_case_id IS NOT NULL AS reinquiry, manual_campaign_name
FROM public.cs_cases WHERE origin = 'live' ORDER BY created_at DESC LIMIT 5;
-- ③ 같은 대화에 한 통 더 → 새 건이 생기지 않고 같은 건에 붙는다(연결 수 2)
-- ④ (1-5 함수 전에는) 편집기에서 그 건을 완료로 바꾼 뒤 한 통 더 → 새 건 + previous_case_id 가 옛 건
--    UPDATE public.cs_cases SET status='done', category_code='other', completed_at=now() WHERE case_no = <번호>;
-- ⑤ 관리자 답장·일괄 발송으로는 건이 늘지 않는다
-- ⑥ 발신 자체가 실패하지 않는다(화면에 보낸 글이 보임)
-- ⑦ 서비스 문의: 닫힌 대화에 다시 쓰면(새 대화가 열리면 그 대화의 첫 건) / 열린 대화 완료 뒤 재문의 → previous_case_id
-- ⑧ 두 브라우저에서 같은 대화로 동시에 발신 → 건이 하나
-- ⑨ 트리거 안 오류(편집기에서 트랜잭션 안에 cs_cases 이름을 잠깐 바꿔 시험 후 rollback)에도 발신 성공 + WARNING
-- ⚠️ 1-5 에서 같은 대화 잠금(hashtext('cs_case_conv:'||…))을 잡는 함수를 만들면 「잠금 먼저 → 응대 완료·메시지 행 나중」 순서로
*/

-- ============================================================
-- 롤백 (1-5 화면 쓰기가 생기기 전에만)
-- ============================================================
-- 편집기 경고: 뜸 — 롤백 전용(트리거·함수 삭제, 백필 행 삭제)
-- DROP TRIGGER IF EXISTS trg_cs_case_on_member_message ON public.application_messages;
-- DROP FUNCTION IF EXISTS public._cs_case_on_member_message();
-- DELETE FROM public.cs_cases WHERE origin = 'backfill';   -- 연결(cs_case_messages)은 함께 지워진다
