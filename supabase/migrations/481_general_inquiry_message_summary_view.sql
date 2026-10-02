-- ============================================================
-- 481_general_inquiry_message_summary_view.sql
-- 일반 문의 창구 — 데이터 모델 ⑧ 관리자 목록용 새 뷰 (단계 2)
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-4 ⑤ · §5-5 ⑧ · §5-6 ①
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 2
-- 선행: 475(칸) · 477(응대 완료 표)
--
-- 베이스: 144 의 뷰 application_message_summary(유일한 정의 — 212·216·415 는 이름만 나오고 정의가 아니다).
--   열 이름·순서·타입·FILTER 조건·미응대 CASE 를 그대로 복사하고, **기준만** 응모 → 회원으로 바꿨다.
--   열: application_id(항상 NULL) · influencer_id · campaign_id(항상 NULL) · message_count ·
--       unread_for_influencer · unresolved_for_admin_team · last_message_at
--   → 화면(fetchAdminMessageThreads 계열)이 두 뷰의 행을 같은 모양으로 다룰 수 있다.
--   security_invoker = true — 접근 정책(관리자 조회 415 / 회원 본인 조회 476)이 그대로 적용된다.
--   감사용·탈퇴 칸은 넣지 않는다(사양서 5-6 ① — 화면이 따로 조회해 붙인다).
--
-- ⚠️ 사양서·작업표는 「기준 표 influencers」라 했으나 **influencers 를 기준으로 삼지 않았다**(결정 필요 — 보고서 참조).
--   security_invoker 뷰가 influencers 를 읽으면 호출자의 행 단위 보안이 적용되는데, 마이그레이션 312 가
--   influencers 표의 「관리자 조회」 정책(influencers_select_admin)을 **삭제**했다 — 관리자가 이 뷰를 읽으면
--   자기 행 하나만 보이고 일반 문의 목록이 **조용히 빈 결과**가 된다(오류도 안 난다). 그래서
--   application_messages 자체를 회원별로 묶는다(WHERE application_id IS NULL). 부수 효과로 문의가 없는 회원의
--   빈 행이 안 생긴다(수천 행 방지). 회원 이름·감사용 표시는 화면이 influencers_admin_view 로 따로 붙인다(기존과 같은 방식).
--
-- ── 적용 뒤 검증 ──
--   [V1] 열 모양이 144 뷰와 같은가:
--     SELECT 'app' AS v, column_name, data_type, ordinal_position FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='application_message_summary'
--     UNION ALL
--     SELECT 'gen', column_name, data_type, ordinal_position FROM information_schema.columns
--      WHERE table_schema='public' AND table_name='general_inquiry_message_summary'
--     ORDER BY 4, 1;
--     기대: 같은 순번마다 이름·타입이 짝으로 같다(7열)
--   [V2] security_invoker 켜짐: SELECT reloptions FROM pg_class WHERE oid='public.general_inquiry_message_summary'::regclass;
--        기대: {security_invoker=true}
--   [V3] 🔴 로그인 브라우저: 관리자 — await db.from('general_inquiry_message_summary').select('*')  → 일반 문의가 있는 회원 행
--        회원 — 같은 조회가 **본인 행만** 나온다(남의 행 0). 서비스 키(SQL 편집기)로는 정책이 안 걸려 재현 불가.
--   [V4] 응모건 뷰가 그대로인가: SELECT count(*) FROM public.application_message_summary;  (적용 전후 같음 — 이 파일은 그 뷰를 안 건드린다)
--
-- ── 되돌리는 방법 ──
--   DROP VIEW IF EXISTS public.general_inquiry_message_summary;
-- ============================================================

BEGIN;

CREATE OR REPLACE VIEW public.general_inquiry_message_summary
  WITH (security_invoker = true)
AS
SELECT
  NULL::uuid    AS application_id,
  m.influencer_id,
  NULL::uuid    AS campaign_id,
  -- message_count: 강제 숨김 제외 (self_withdrawn 포함 — placeholder 표시됨) — 144 와 동일
  count(m.*) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS message_count,
  -- 회원 미열람: 관리자 회수 메시지는 본문 못 보므로 제외 — 144 와 동일
  count(m.*) FILTER (
    WHERE m.sender_kind = 'admin'
      AND m.read_by_influencer_at IS NULL
      AND m.hidden_by_admin_at IS NULL
      AND m.self_withdrawn_at IS NULL
  ) AS unread_for_influencer,
  -- 미응대: resolutions 없거나 마지막 회원 메시지(살아있는 것)가 응대 완료 시점 이후 — 144 와 동일(기준 표만 477)
  CASE
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind = 'influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) IS NULL THEN false
    WHEN r.resolved_after_message_at IS NULL THEN true
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind = 'influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) > r.resolved_after_message_at THEN true
    ELSE false
  END AS unresolved_for_admin_team,
  max(m.created_at) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS last_message_at
FROM public.application_messages m
LEFT JOIN public.general_inquiry_resolutions r ON r.influencer_id = m.influencer_id
WHERE m.application_id IS NULL
  AND m.influencer_id IS NOT NULL
GROUP BY m.influencer_id, r.resolved_after_message_at;

COMMENT ON VIEW public.general_inquiry_message_summary IS
  '[481] 일반 문의(응모 없는 메시지) 회원별 집계. 144 application_message_summary 와 같은 7열·같은 판정(기준만 회원). '
  'security_invoker — 관리자는 전체, 회원은 본인 행만. application_id·campaign_id 열은 항상 NULL. '
  '문의가 있는 회원만 행이 생긴다(influencers 기준으로 짜면 312 이후 관리자에게 빈 결과가 됨).';

NOTIFY pgrst, 'reload schema';

COMMIT;
