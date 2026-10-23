-- ============================================================
-- 589_campaigns_select_hide_record_only.sql
-- 2026-10-23 — 캠페인 조회 정책: 관리자가 아니면 기록용 캠페인 행을 받지 못한다
--   사양서 docs/specs/2026-07-15-brand-portal.md 16-5 15번 ⑥ · 작업표 docs/specs/2026-10-23-record-only-campaign-breakdown.md 조각 2
--   사용자 결정 S1(서버 조회 정책 + 화면)
--
-- 🔴 운영에 먼저 나가는 작업(사양서 배포 순서 ①) — 588 바로 뒤에만(칸이 없으면 정책 생성이 실패한다)
--
-- 고치는 것
--   campaigns_select_public(001 — USING (true)) 를 지우고 같은 이름으로 다시 만든다:
--     USING (is_record_only = false OR (SELECT public.is_admin()))
--   · (SELECT …) 로 감싸 행마다가 아니라 조회마다 한 번 평가(137·415 와 같은 방식)
--   · 대상 역할은 001 과 같이 지정하지 않는다(= public — 비로그인·회원·브랜드 계정·관리자 모두 이 정책 하나)
--   · 바꾸지 않는 것: campaigns_insert_admin · campaigns_update_admin · campaigns_delete_admin(001)
--
-- 착수 전 확인(2026-10-23, 두 서버 조회 — 바꾸는 문장 없음)
--   is_admin() 실행 권한에 anon=X 있음(개발·운영 모두) — 없으면 비로그인 캠페인 목록 조회가 통째로 실패한다
--   campaigns 조회 정책은 campaigns_select_public 하나뿐(개발·운영 모두)
--
-- 관리자가 아닌 사람이 campaigns 를 읽는 자리 — 이름 전파 세 형태로 센 결과(2026-10-23)
--   찾은 방법: 개발 데이터베이스 카탈로그(public 함수 본문 prosrc 에 'campaigns' 가 있는 것을 정의자/호출자 권한으로 나눔 · 뷰 정의 ·
--   다른 표 정책 조건) + dev/ 글자 검색(① from('campaigns') ② 표 이름을 인자로 받는 헬퍼 ③ campaigns:campaign_id(…) 끼움)
--   · 서버: campaigns 를 읽는 함수 91개(일반 77 · 트리거 14) 전부 정의자 권한(SECURITY DEFINER) — 정책을 지나지 않아 영향 없음.
--     호출자 권한 함수 0 · campaigns 를 읽는 뷰 0 · 다른 표 정책 조건에서 campaigns 를 읽는 곳 0
--     → 브랜드 응답(547·565·587·557)·홍보 메일(471)·공유 리포트(545)·응모 차단 트리거(588)·행사 예약(378)은 그대로 기록용 행을 본다
--   · 서버 함수(supabase/functions)에서 campaigns 를 읽는 자리 5곳(notify-campaign-promo-digest 3 · notify-influencer-daily-digest ·
--     notify-admin-daily-digest, 끼움 notify-deliverable-decision 1)은 모두 서비스 키라 정책을 지나지 않는다 — 시험 발송 갈래는 조각 5 가 따로 거른다
--   · 화면 ①: 회원 앱이 부르는 것은 storage.js fetchCampaigns(144) 하나 — 기록용 행이 빠진다(의도). 나머지 from('campaigns') 는 관리자 화면·
--     event-scan.html(관리자 전용) — 관리자는 그대로 받는다
--   · 화면 ②: _proxyFetchByIds('campaigns', …)(admin-deliverables.js) — 관리자 전용
--   · 화면 ③: storage.js 1207·1228·1272·1332·1515·2227·6826 campaigns:campaign_id(…) — 응모·결과물 행에 끼어 있다. 기록용은 응모가 없어(588) 해당 행이 0
--   · 브랜드 화면은 campaigns 를 직접 읽지 않는다(dev/js/brand-*.js 0건 — 모두 정의자 권한 함수)
--
-- 편집기 경고: Supabase SQL 편집기의 「Success」는 이전 실행 잔상일 수 있다 — 끝의 기록 줄을 기록 표에서 확인한다.
--   🔴 SQL 편집기·서비스 키는 정책을 지나지 않아 효과를 재현하지 못한다 — 로그인한 브라우저(또는 역할을 바꾼 시험)로 확인한다
--
-- 롤백(조각 3·4·5 를 먼저 되돌린 뒤, 칸(588)을 지우기 전에)
--   DROP POLICY IF EXISTS campaigns_select_public ON public.campaigns;
--   CREATE POLICY campaigns_select_public ON public.campaigns FOR SELECT USING (true);
--
-- 검증(개발서버)
--   로그아웃 캠페인 목록 장수가 적용 전과 같다(기록용 0건일 때)
--   기록용 시험 캠페인: 비로그인·회원·브랜드 계정 직접 조회 0행 / 관리자 1행 · 브랜드 캠페인 목록 화면에는 보인다
-- ============================================================
BEGIN;

DROP POLICY IF EXISTS campaigns_select_public ON public.campaigns;
CREATE POLICY campaigns_select_public
  ON public.campaigns FOR SELECT
  USING (is_record_only = false OR (SELECT public.is_admin()));

COMMENT ON POLICY campaigns_select_public ON public.campaigns IS
  '[589] 캠페인 조회 — 기록용(is_record_only) 행은 관리자만. 그 밖은 누구나(001 의 USING (true) 를 대체). '
  '정의자 권한 함수·서비스 키는 이 정책을 지나지 않는다. 사양서 brand-portal.md 16-5 15번 ⑥.';

NOTIFY pgrst, 'reload schema';

INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '589', '589_campaigns_select_hide_record_only.sql');
COMMIT;
