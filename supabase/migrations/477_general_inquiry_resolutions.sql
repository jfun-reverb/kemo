-- ============================================================
-- 477_general_inquiry_resolutions.sql
-- 일반 문의 창구 — 데이터 모델 ③ 응대 완료용 새 표
--
-- 사양서: 2026-05-21-general-inquiry-desk.md §5-4 ④ · §5-5 ③
-- 작업표: 2026-05-21-general-inquiry-desk-breakdown.md 조각 1 (마이그 ③)
-- 선행: 475
--
-- 왜 새 표인가: 기존 application_message_resolutions(144)는 기본키 자체가 application_id 라
--   빈 값을 기본키로 쓸 수 없다(사양서 5-4 ④). 열 모양은 144 표와 같되 기준 키만 회원(influencer_id)이다.
-- 쓰기 정책 없음 — 넣고 지우는 것은 478 의 함수(SECURITY DEFINER)만 한다.
-- 조회는 관리자 전원(415 방식으로 is_admin() 을 SELECT 로 감싸 행마다 재평가되지 않게 한다).
--
-- ── 적용 뒤 검증 ──
--   [V1] SELECT column_name, data_type FROM information_schema.columns
--         WHERE table_schema='public' AND table_name='general_inquiry_resolutions' ORDER BY ordinal_position;
--        기대: influencer_id, resolved_at, resolved_by, resolved_by_name, resolved_after_message_at, resolution_method
--   [V2] SELECT policyname, cmd FROM pg_policies WHERE tablename='general_inquiry_resolutions';
--        기대: 1행(SELECT). 쓰기 정책 없음.
--   [V3] SELECT relrowsecurity FROM pg_class WHERE oid='public.general_inquiry_resolutions'::regclass;  기대: t
--
-- ── 되돌리는 방법 ──
--   DROP TABLE IF EXISTS public.general_inquiry_resolutions;   -- 478·480·481 을 먼저 되돌릴 것
-- ============================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.general_inquiry_resolutions (
  influencer_id             uuid        PRIMARY KEY
    REFERENCES public.influencers(id) ON DELETE CASCADE,
  resolved_at               timestamptz NOT NULL DEFAULT now(),
  resolved_by               uuid        NOT NULL,
  resolved_by_name          text        NOT NULL,
  resolved_after_message_at timestamptz NOT NULL,   -- 응대 완료 시점의 마지막 회원 메시지 시각
  resolution_method         text        NOT NULL
    CHECK (resolution_method IN ('auto_replied','manual'))
);

ALTER TABLE public.general_inquiry_resolutions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_read_general_inquiry_resolutions" ON public.general_inquiry_resolutions;
CREATE POLICY "admin_read_general_inquiry_resolutions"
  ON public.general_inquiry_resolutions FOR SELECT
  USING ((SELECT public.is_admin()));

-- INSERT/UPDATE/DELETE 정책 없음 — send_general_inquiry_message · mark_general_inquiry_resolved(478)만 쓴다.

COMMENT ON TABLE public.general_inquiry_resolutions IS
  '[477] 일반 문의(응모 없는 메시지) 회원별 응대 완료 상태. application_message_resolutions(144)의 회원 기준 짝. '
  '쓰기는 478 의 함수만.';

NOTIFY pgrst, 'reload schema';

COMMIT;
