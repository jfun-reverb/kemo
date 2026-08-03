-- ============================================================
-- 285_campaign_event_place.sql
-- 오프라인 팝업 방문 예약(티켓팅) — 행사장 안내 한 줄
-- 사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-3 · §9-1
-- 선행: 280~284
--
-- 왜 필요한가:
--   사양서 §4-3 은 티켓 화면에 「QR + 예약번호 + 이름 + 날짜·타임 + **장소**」를
--   넣으라고 했는데, 캠페인 표에 행사장을 담을 칸이 없었다. 어디로 가야 하는지
--   적히지 않은 티켓은 티켓 구실을 못 한다.
--   §9-1 이 「행사장 이름·주소는 아직 미정, 임시 문구로 만들고 나중에 교체」라고
--   한 것은 **내용**이 미정이라는 뜻이지 칸이 필요 없다는 뜻이 아니다.
--
-- 왜 새 칸인가 (기존 칸 재사용을 안 하는 이유):
--   설명·참가방법 같은 긴 글에 섞어 두면 티켓에 한 줄로 뽑아낼 수 없다.
--   방문형의 visit_start/visit_end 는 날짜라 장소와 무관하다.
--
-- 표시 대상: **인플루언서 화면**이라 일본어로 넣는다(관리자 폼 안내에 명시).
--   한 줄 요약용이라 상세 약도·주의사항은 기존 안내문에 쓴다.
--
-- 275(캠페인 동시 저장 방어)와의 관계: 제외 목록에 없으므로 이 칸도 자동으로
--   보호 대상이 된다(280 의 두 칸과 같다).
-- 265·266(변경 이력 화이트리스트)에는 **넣지 않는다** — 280 과 같은 판단.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

BEGIN;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS event_place text;

COMMENT ON COLUMN public.campaigns.event_place IS
  '[285] 오프라인 행사장 안내 한 줄(일본어). 입장 티켓 화면에 그대로 표시된다. '
  '행사 모드(event_mode) 캠페인에서만 쓴다. 비어 있으면 티켓에 「장소는 정해지는 대로 '
  '안내」라는 문구가 대신 나간다.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증
-- ============================================================
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns' AND column_name='event_place';
--   → text, YES
--
-- 기존 캠페인은 전부 NULL 이라 동작 변화 0:
-- SELECT count(*) FROM public.campaigns WHERE event_place IS NOT NULL;   -- 0
--
-- ============================================================
-- 롤백
-- ============================================================
-- ALTER TABLE public.campaigns DROP COLUMN IF EXISTS event_place;
