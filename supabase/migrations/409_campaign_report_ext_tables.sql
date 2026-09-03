-- ============================================================
-- 409. 리포트 외부 첨부 표 2개 (포인테일 등 외부 서비스 결과물)
-- ============================================================
-- 작업표: docs/specs/2026-09-03-campaign-report-builder-breakdown.md 「작업 12」
-- 사양서 : docs/specs/2026-09-03-campaign-report-builder.md 「외부 파일(포인테일) 실측 구조」
--
-- 무엇인가 — 관리자가 포인테일(스토어링크) 결과물 엑셀을 리포트에 붙이면,
-- **파일이 아니라 파싱한 행**을 여기 담는다. 원본 파일은 저장하지 않는다.
--
-- 🔴 **한 사람이 한 행**이다. 한 덩어리(jsonb)로 넣으면 563명이 한 행에 들어가
--    조회가 무겁고 갱신이 통째가 된다.
-- 🔴 **`influencers` 와 아무 연결을 만들지 않는다.** 외부 참가자는 우리 회원이 아니고,
--    「우리 회원 데이터와 구분되는 것」이 보관 근거의 조건이다(사양서 「보관 근거」).
--
-- ⚠️ 여기 담기는 것 = 외부 참가자의 계정 아이디(일부 이메일)·주문번호·구매금액·
--    증빙 이미지 주소. **개인정보처리방침 §2.3 에 「제휴 서비스로부터 제공받음」이
--    실린 뒤에만 운영에 올린다**(작업 16 — 방침 문구 없이 이 배포를 내보내지 않는다).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- ① 첨부 1건 = 외부 캠페인 파일 하나
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_report_sources (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  report_id        uuid NOT NULL REFERENCES public.campaign_reports(id) ON DELETE CASCADE,
  service_code     text NOT NULL,                       -- 'pointail' (서비스가 늘면 값이 는다)
  ext_campaign_no  text NOT NULL,                       -- 외부 캠페인 번호 (예: 102905)
  ext_campaign_name text NOT NULL,                      -- 관리자가 모달에 적은 이름 → 표 「캠페인명」
  file_name        text,                                -- 어떤 파일이었는지 (원본은 저장 안 함)
  attached_by      uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  attached_by_name text,                                -- 405 와 같은 이유의 이름 스냅샷
  attached_at      timestamptz NOT NULL DEFAULT now(),  -- 🔴 리포트 머리말 「외부 — (붙인 시각) 기준」이 이 값
  row_count        integer NOT NULL DEFAULT 0,
  CONSTRAINT campaign_report_sources_service_chk CHECK (service_code IN ('pointail'))
);

-- 같은 리포트에 같은 외부 캠페인 번호는 하나 — 또 붙이면 「갱신」이지 「추가」가 아니다(사양서 ⑩)
CREATE UNIQUE INDEX IF NOT EXISTS campaign_report_sources_report_ext_uidx
  ON public.campaign_report_sources (report_id, service_code, ext_campaign_no);

COMMENT ON TABLE public.campaign_report_sources IS
  '[409] 리포트에 붙인 외부 서비스 결과물 파일 1건. 원본 파일은 저장하지 않고 파싱 결과만 ext_rows 에 담는다.';

-- ------------------------------------------------------------
-- ② 참가자 행 — 한 사람 = 한 행. 칸 이름은 **파서(report-parsers.js)의 출력과 글자 그대로 같다.**
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.campaign_report_ext_rows (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id       uuid NOT NULL REFERENCES public.campaign_report_sources(id) ON DELETE CASCADE,
  member_no       text NOT NULL,          -- 외부 회원번호 — 탭끼리 짝짓는 유일 열쇠(실측: 563/563 유일)
  account_id      text,                   -- 채널 계정 ID (일부는 원본부터 가려져 있다: jiecai**@)
  mission_status  text,                   -- 구매 미션 상태 (완료/미완료)
  order_no        text,
  purchase_amount numeric,
  receipt_url     text,                   -- 구매하기 탭 「인증 자료」 — 여러 장이면 줄바꿈으로
  receipt_at      timestamptz,            -- 구매 미션 완료일
  review_kind     text,                   -- 'text' / 'photo' / NULL(리뷰 없음) → 표 「구분」 A-1 / A-2
  qoo10_urls      text,                   -- 텍스트/포토 리뷰 「증빙자료」 — 여러 장이면 줄바꿈
  qoo10_at        timestamptz,
  cosme_urls      text,                   -- @cosme 탭 「증빙자료」 (탭이 없는 파일이면 NULL)
  cosme_at        timestamptz,
  CONSTRAINT campaign_report_ext_rows_kind_chk CHECK (review_kind IS NULL OR review_kind IN ('text','photo'))
);

CREATE INDEX IF NOT EXISTS campaign_report_ext_rows_source_idx
  ON public.campaign_report_ext_rows (source_id);

COMMENT ON TABLE public.campaign_report_ext_rows IS
  '[409] 외부 서비스 참가자 1명 = 1행. influencers 와 연결하지 않는다(우리 회원이 아니다).';

-- ------------------------------------------------------------
-- ③ 행 단위 보안 정책 — 402 와 같은 규칙(읽기만, 쓰기는 함수)
--    🔴 인플루언서 계정에서는 0행이어야 한다(작업 12 완료 정의).
-- ------------------------------------------------------------
ALTER TABLE public.campaign_report_sources  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.campaign_report_ext_rows ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS campaign_report_sources_select ON public.campaign_report_sources;
CREATE POLICY campaign_report_sources_select ON public.campaign_report_sources
  FOR SELECT TO authenticated
  USING (public.has_permission('menu.reports', 'read'));

DROP POLICY IF EXISTS campaign_report_ext_rows_select ON public.campaign_report_ext_rows;
CREATE POLICY campaign_report_ext_rows_select ON public.campaign_report_ext_rows
  FOR SELECT TO authenticated
  USING (public.has_permission('menu.reports', 'read'));

-- 쓰기 정책은 두지 않는다 — INSERT/UPDATE/DELETE 는 410 의 SECURITY DEFINER 함수만.

COMMIT;

NOTIFY pgrst, 'reload schema';


-- ============================================================
-- 검증
-- ============================================================
/*
-- [V1] 표 2개 · 정책 2개
SELECT tablename, rowsecurity FROM pg_tables
 WHERE schemaname='public' AND tablename IN ('campaign_report_sources','campaign_report_ext_rows');
SELECT tablename, policyname, cmd FROM pg_policies
 WHERE tablename IN ('campaign_report_sources','campaign_report_ext_rows');
-- 기대: 표 2 (rowsecurity true) · 정책 2 (SELECT 만)

-- [V2] 🔴 인플루언서 계정 브라우저 콘솔에서 0행
--   (await db.from('campaign_report_ext_rows').select('id',{count:'exact'})).count   // 0
*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP TABLE IF EXISTS public.campaign_report_ext_rows;
-- DROP TABLE IF EXISTS public.campaign_report_sources;
