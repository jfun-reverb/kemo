-- ============================================================
-- 385. 최소 팔로워수 — 「그리고」 갈래의 채널별 값 (2단계 ①)
--
--   사양서 docs/specs/2026-08-27-min-followers-channel-match.md 설계 2
--
--   무엇을 더하나
--     `campaigns.min_followers_by_channel` (jsonb) — 예: {"instagram": 10000, "x": 5000}
--     「그리고」 갈래(채널 2개+ · channel_match='and')만 이 칸을 읽는다.
--     「채널 1개」·「또는」은 기존 `min_followers` 하나를 계속 쓴다.
--
-- ⚠️ **값을 안 채운 채널은 「그 채널은 검사하지 않는다」로 본다**(0 이 아니라 「없음」).
--    담당자가 인스타만 조건을 걸고 X 는 아무나 받고 싶을 수 있다. 판정 결과는 0 으로 봐도
--    같지만(0명 이상 = 전원 통과) **화면 표기가 갈린다** — 「0명 이상」보다 「제한 없음」이 낫다.
--    사양서가 이것을 「물을 분기가 아니라 결정」으로 닫았다. 되살리지 말 것.
--
-- ⚠️ **기존 캠페인은 손대지 않는다** — 이 칸은 비어 있고(`'{}'`), 비어 있으면 종전과 같다.
--    운영의 「그리고」 5건은 전부 리뷰어형이라 팔로워 검사 자체를 건너뛴다.
--
-- 🔴 **이 칸은 낙관적 락(275)의 자동 보호 대상이다** — `campaigns_bump_version()` 의 제외
--    6개에 없으므로, 값이 바뀌면 `version` 이 오른다. 편집 저장은 종전대로
--    `updateCampaign(id, updates, expectedVersion)` 을 거쳐야 한다.
-- ⚠️ **변경 이력 화이트리스트(265·266)에는 넣지 않는다** — 세 곳(265 CHECK · 266 v_fields ·
--    266 트리거 `AFTER UPDATE OF` 목록)을 동시에 고쳐야 하고 어긋나면 CHECK 위반으로
--    저장이 통째로 실패한다. 행사 칸들과 같은 판단이다.
-- ============================================================

BEGIN;

ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS min_followers_by_channel jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.campaigns.min_followers_by_channel IS
  '[385] 「그리고」 갈래(채널 2개+ · channel_match=''and'')의 채널별 최소 팔로워수. '
  '예: {"instagram": 10000, "x": 5000}. 값이 없는 채널은 「검사하지 않음」(0 아님). '
  '「채널 1개」·「또는」 갈래는 이 칸을 안 읽고 min_followers 하나를 쓴다. '
  '입력칸은 팔로워 값을 가진 네 채널(instagram·x·tiktok·youtube)에만 만든다 — '
  'LIPS·@cosme 는 팔로워를 담는 자리가 없어 항상 0 이고, Qoo10 은 Instagram 값을 빌려 쓴다.';

COMMIT;

-- ============================================================
-- 적용 후 확인
--
-- -- [1] 칸이 생겼는가 · 기본값이 빈 객체인가 (기대: jsonb / '{}'::jsonb)
-- SELECT data_type, column_default, is_nullable
--   FROM information_schema.columns
--  WHERE table_schema='public' AND table_name='campaigns'
--    AND column_name='min_followers_by_channel';
--
-- -- [2] 기존 행이 전부 빈 객체인가 (기대: 비어있지 않은 행 0건)
-- SELECT count(*) AS 값이있는행
--   FROM public.campaigns
--  WHERE min_followers_by_channel <> '{}'::jsonb;
--
-- -- [3] 🔴 낙관적 락 제외 목록에 안 들어갔는가 = 보호 대상인가
-- --     (기대: 함수 본문에 min_followers_by_channel 이 안 나온다 → 0)
-- SELECT count(*) AS 제외목록에있음
--   FROM pg_proc
--  WHERE proname = 'campaigns_bump_version'
--    AND prosrc LIKE '%min_followers_by_channel%';
-- ============================================================
