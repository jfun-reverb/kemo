-- ============================================================
-- 506_general_inquiry_thread_summary_view.sql
-- 서비스 문의 「회원 한 명이 여러 대화」 — 데이터 ③ 대화별 요약 뷰
--
-- 사양서: docs/specs/2026-10-06-service-inquiry-threads.md 「설계 · 데이터」 마이그레이션 3 · P-5
-- 선행: 504(대화 표) · 505(옮기기·함수). 옛 뷰 general_inquiry_message_summary(481)는 그대로 둔다
--       (옛 화면이 남는 몇 분 + 옛 배지 조회 maybeSingle 이 그대로 돈다 — 지우는 것은 후속 정리 마이그레이션).
--
-- 🔴 대화 표에서 출발해 메시지를 붙인다 — 대화 한 줄 = 대화 표 한 행. 회원은 본인 조회 정책(504)으로, 관리자는 관리자 조회 정책(504)으로
--    자기 몫의 행을 본다. 회원 표(influencers)를 기준으로 삼지 않는다(312 로 관리자 조회 정책이 없어 관리자에게 빈 뷰가 된다 — 481 머리말).
--    그래서 글이 숨겨지거나 회수돼도 대화 줄은 사라지지 않는다(보이는 글 0건 대화 = 메시지 칸이 비고 message_count 0).
-- 🔴 메시지에서 구하는 칸은 **전부 숨김·회수된 글을 뺀다** — message_count·last_message_at·last_sender_kind·두 미리보기·번역 칸·
--    unread_for_influencer·needs_reply 가 같은 글을 가리킨다(회원이 마지막 글을 회수하면 그 앞 글이 기준).
--    (481 은 message_count 에 회수된 글을 포함했다 — 이 뷰는 사양서대로 뺀다. 관리자 화면은 `.gt('message_count',0)` 를 쓰지 않는다.)
-- security_invoker = true — 권한은 호출자의 행 단위 보안을 따른다.
--
-- 칸(15)
--   thread_id · influencer_id · status · opened_at · closed_at                            ← 대화 표
--   message_count · last_message_at · last_sender_kind                                    ← 보이는 글
--   first_message_preview · last_message_preview(각 앞 100자·공백 한 칸으로 정리 — 첨부만 있는 글은 빈 문자열)
--   last_message_preview_translated · last_translate_status                               ← 마지막 보이는 글의 번역 칸(관리자 미리보기용)
--   unread_for_influencer                                                                 ← 회원이 안 읽은 운영팀 글 수
--   needs_reply = status='open' AND last_sender_kind='influencer'  (P-5 「미응대」. 열림이고 아니면 「회원 답 대기」)
--   influencer_thread_count = 그 회원의 대화 수(이 대화·닫힌 것 포함, 호출자가 볼 수 있는 행 기준 — 거름과 무관)
--
-- 편집기 경고: 안 뜸.
--
-- ── 적용 뒤 검증 조회 (1단계씩) ──
--   [V1] 칸 이름·순서(15칸):
--     SELECT column_name, data_type FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='general_inquiry_thread_summary' ORDER BY ordinal_position;
--   [V2] security_invoker 켜짐:  SELECT reloptions FROM pg_class WHERE oid='public.general_inquiry_thread_summary'::regclass;   기대: {security_invoker=true}
--   [V3] 서비스 키(SQL 편집기 — 행 단위 보안이 안 걸린다)로 옮긴 데이터가 줄로 보이나:
--     SELECT thread_id, influencer_id, status, message_count, last_sender_kind, needs_reply, influencer_thread_count
--       FROM public.general_inquiry_thread_summary ORDER BY opened_at;
--     기대: 대화 표 행 수와 같은 줄 수. 505 [V1] 의 threads 와 같아야 한다
--   [V4] 🔴 로그인 브라우저: 관리자 — await db.from('general_inquiry_thread_summary').select('*')  → 전체 대화 줄
--        회원 — 같은 조회가 본인 대화만(남의 행 0). 회원 시험 글을 하나 회수해 보이는 글 0건 대화가 줄로 남는지(message_count 0, needs_reply false)
--
-- ── 되돌리는 방법 ──
--   DROP VIEW IF EXISTS public.general_inquiry_thread_summary;
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.general_inquiry_thread_summary
  WITH (security_invoker = true)
AS
SELECT
  t.id            AS thread_id,
  t.influencer_id,
  t.status,
  t.opened_at,
  t.closed_at,
  COALESCE(agg.message_count, 0)::bigint        AS message_count,
  agg.last_message_at,
  lastm.sender_kind                              AS last_sender_kind,
  firstm.preview                                 AS first_message_preview,
  lastm.preview                                  AS last_message_preview,
  lastm.preview_translated                       AS last_message_preview_translated,
  lastm.translate_status                         AS last_translate_status,
  COALESCE(agg.unread_for_influencer, 0)::bigint AS unread_for_influencer,
  COALESCE(t.status = 'open' AND lastm.sender_kind = 'influencer', false) AS needs_reply,
  (SELECT count(*) FROM public.general_inquiry_threads t2
    WHERE t2.influencer_id = t.influencer_id)::bigint       AS influencer_thread_count
FROM public.general_inquiry_threads t
LEFT JOIN LATERAL (
  SELECT count(*)         AS message_count,
         max(m.created_at) AS last_message_at,
         count(*) FILTER (
           WHERE m.sender_kind = 'admin' AND m.read_by_influencer_at IS NULL
         )                AS unread_for_influencer
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
) agg ON true
LEFT JOIN LATERAL (
  SELECT m.sender_kind,
         left(regexp_replace(btrim(m.body), '\s+', ' ', 'g'), 100)            AS preview,
         NULLIF(left(regexp_replace(btrim(COALESCE(m.body_translated, '')), '\s+', ' ', 'g'), 100), '') AS preview_translated,
         m.translate_status
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
   ORDER BY m.created_at DESC, m.id DESC
   LIMIT 1
) lastm ON true
LEFT JOIN LATERAL (
  SELECT left(regexp_replace(btrim(m.body), '\s+', ' ', 'g'), 100) AS preview
    FROM public.application_messages m
   WHERE m.general_thread_id = t.id
     AND m.hidden_by_admin_at IS NULL
     AND m.self_withdrawn_at  IS NULL
   ORDER BY m.created_at ASC, m.id ASC
   LIMIT 1
) firstm ON true;

COMMENT ON VIEW public.general_inquiry_thread_summary IS
  '[506] 서비스 문의 대화별 요약(한 줄 = 대화 한 건). 대화 표에서 출발하는 security_invoker 뷰 — 회원은 본인 대화, 관리자는 전체. '
  '메시지에서 구하는 칸은 모두 숨김·회수 글 제외. needs_reply = 열림 + 마지막 보이는 글이 회원(P-5). 보이는 글 0건 대화도 줄이 남는다. '
  '옛 뷰 general_inquiry_message_summary(481)는 그대로(후속 정리에서 삭제).';

NOTIFY pgrst, 'reload schema';

COMMIT;
