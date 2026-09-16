-- ============================================================
-- 442_quote_settings_tiered.sql
-- 2026-09-16 — 오리엔시트 구간 요금 · 마이그레이션 ① (작업 1)
--   사양서 docs/specs/2026-09-16-orient-sheet-tiered-pricing-and-fields.md §4-2
--   작업표 docs/specs/2026-09-16-orient-sheet-tiered-pricing-breakdown.md 「작업 1」
--   베이스: 426_quote_settings.sql
--
-- 무엇을 하나
--   [A] quote_settings.group_ko 추가 — 화면 묶음 머리(공통 · 리뷰어 · 시딩)
--   [B] 기존 9행에 묶음·이름·순서 부여
--   [C] 신규 26행 — 리뷰어 모집비 4구간 · 추가 옵션 2 · 시딩 5채널 × 4구간
--   [D] 옛 6행 삭제 — 구간 없는 모집비 1 + 시딩 채널 5
--   [E] get_quote_settings() 재정의(반환 8칸) 🔴 DROP 후 CREATE 라 실행 권한을 다시 건다
--   → 적용 뒤 29행.
--
-- ------------------------------------------------------------
-- 🔴 시딩 20행은 「한눈에 가짜인 값」 99001~99020 으로 시드한다 (사양서 §4-2 · 결정 17)
-- ------------------------------------------------------------
--   0 으로 두면 채널을 바꿔도 구간을 바꿔도 견적이 같아, **그 채널·그 구간 행을 제대로 읽는지**
--   확인할 방법이 없다. 20개가 전부 다르면 견적서 숫자만 보고 어느 행을 읽었는지 바로 안다
--   (인스타그램-피드 스탠다드 = 99002 · 틱톡 라이트 = 99013).
--   🔴 **진짜 금액은 운영 담당자가 「견적 기준값」 화면에서 넣는다** — 배포 도중(관리자 화면이 나간
--      뒤, 작성 폼이 나가기 전)이고, 그때 **금액이 `99,0` 으로 시작하는 행이 하나도 없는지 눈으로**
--      본다. 프로그램이 막아 주지 않는다 — 안 바꾸면 그 금액이 그대로 브랜드 견적서에 찍힌다.
--
-- ------------------------------------------------------------
-- ⚠️ 환율 단위는 반드시 krw (426 의 교훈)
-- ------------------------------------------------------------
--   rate 로 두면 화면이 「1000 %」로 그리고 update_quote_setting 의 「비율은 1 이하」 거부에 걸려
--   **수정 자체가 막힌다.** 이 파일은 환율 행의 단위를 건드리지 않는다.
--
-- ------------------------------------------------------------
-- 🔴 get_quote_settings() 는 CREATE OR REPLACE 로 안 된다
-- ------------------------------------------------------------
--   반환 칸이 7 → 8 로 바뀌어 **지우고 다시 만들어야** 하고, 그 순간 426 이 건 회수·부여가 사라진다.
--   → 같은 파일에서 **회수 두 줄(PUBLIC · anon) + 부여 한 줄(authenticated)** 을 다시 건다.
--   ⚠️ 빠뜨리면 오류가 아니라 **화면에 0행**으로 나타난다(조용한 실패 — 424·387 선례).
--
-- ------------------------------------------------------------
-- ⚠️ 이 파일만 적용하고 ②(견적 계산 재정의)를 미루면 — 조용히 옛 방식으로 계산된다
-- ------------------------------------------------------------
--   `_orient_compute_quote`(현재 원본 431)는 옛 열쇠말(`reviewer_recruit_fee_krw`·`seeding_fee_krw_{채널}`)을
--   `COALESCE(…, 0)` 으로 읽는다. [D] 가 그 행을 지우면 **오류 없이 0 으로 계산**된다.
--   지금은 그 여섯 값이 이미 0 이라 결과가 같지만, **신규 26행에 실제 금액을 먼저 넣어 두면**
--   견적은 계속 0 을 내면서 「왜 반영이 안 되지」가 된다. ②를 함께 넣을 것.
--
-- 롤백: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행(산문이 아니라 실행문이다).
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] 묶음 이름 칸
-- ------------------------------------------------------------
ALTER TABLE public.quote_settings
  ADD COLUMN IF NOT EXISTS group_ko text NULL;

COMMENT ON COLUMN public.quote_settings.group_ko IS
  '[442] 견적 기준값 화면의 묶음 머리 — 공통 · 리뷰어 · 시딩. 화면이 이 값이 바뀌는 자리에 머리 줄을 넣는다.';

-- ------------------------------------------------------------
-- [B] 기존 9행 — 묶음·이름·순서 갱신 (금액은 건드리지 않는다)
-- ------------------------------------------------------------
UPDATE public.quote_settings SET group_ko = '공통', sort_order = 10 WHERE key = 'exchange_rate_krw_per_jpy';
UPDATE public.quote_settings SET group_ko = '공통', sort_order = 11 WHERE key = 'vat_rate';
UPDATE public.quote_settings SET group_ko = '리뷰어', sort_order = 20,
       label_ko = '1건당 해외 송금 수수료'                    WHERE key = 'reviewer_transfer_fee_krw';

-- ------------------------------------------------------------
-- [C] 신규 26행 (있으면 건드리지 않는다 — 재실행 안전)
--   ⚠️ 리뷰어 모집비 4 · 추가 옵션 2 는 확정 금액이라 그대로 시드한다.
--      시딩 20 은 위 머리말대로 99001~99020(표 순서).
-- ------------------------------------------------------------
INSERT INTO public.quote_settings (key, amount, unit, label_ko, group_ko, sort_order) VALUES
  ('reviewer_recruit_fee_krw_t50',       8000, 'krw', '모집비 — 라이트 (50건)',        '리뷰어', 21),
  ('reviewer_recruit_fee_krw_t100',      7500, 'krw', '모집비 — 스탠다드 (100건)',     '리뷰어', 22),
  ('reviewer_recruit_fee_krw_t300',      7000, 'krw', '모집비 — 프리미엄 (300건)',     '리뷰어', 23),
  ('reviewer_recruit_fee_krw_t500plus',  6500, 'krw', '모집비 — 500건 이상',           '리뷰어', 24),
  ('reviewer_option_fee_krw_lips',       5000, 'krw', '추가 옵션 — LIPS (1건당)',      '리뷰어', 25),
  ('reviewer_option_fee_krw_cosme',      5000, 'krw', '추가 옵션 — @cosme (1건당)',    '리뷰어', 26),

  ('seeding_fee_krw_instagram_feed_t50',       99001, 'krw', '진행비 — 인스타그램-피드 (라이트 50건)',      '시딩', 40),
  ('seeding_fee_krw_instagram_feed_t100',      99002, 'krw', '진행비 — 인스타그램-피드 (스탠다드 100건)',   '시딩', 41),
  ('seeding_fee_krw_instagram_feed_t300',      99003, 'krw', '진행비 — 인스타그램-피드 (프리미엄 300건)',   '시딩', 42),
  ('seeding_fee_krw_instagram_feed_t500plus',  99004, 'krw', '진행비 — 인스타그램-피드 (500건 이상)',       '시딩', 43),

  ('seeding_fee_krw_instagram_reels_t50',      99005, 'krw', '진행비 — 인스타그램-릴스 (라이트 50건)',      '시딩', 50),
  ('seeding_fee_krw_instagram_reels_t100',     99006, 'krw', '진행비 — 인스타그램-릴스 (스탠다드 100건)',   '시딩', 51),
  ('seeding_fee_krw_instagram_reels_t300',     99007, 'krw', '진행비 — 인스타그램-릴스 (프리미엄 300건)',   '시딩', 52),
  ('seeding_fee_krw_instagram_reels_t500plus', 99008, 'krw', '진행비 — 인스타그램-릴스 (500건 이상)',       '시딩', 53),

  ('seeding_fee_krw_x_t50',                    99009, 'krw', '진행비 — X (라이트 50건)',                    '시딩', 60),
  ('seeding_fee_krw_x_t100',                   99010, 'krw', '진행비 — X (스탠다드 100건)',                 '시딩', 61),
  ('seeding_fee_krw_x_t300',                   99011, 'krw', '진행비 — X (프리미엄 300건)',                 '시딩', 62),
  ('seeding_fee_krw_x_t500plus',               99012, 'krw', '진행비 — X (500건 이상)',                     '시딩', 63),

  ('seeding_fee_krw_tiktok_t50',               99013, 'krw', '진행비 — 틱톡 (라이트 50건)',                 '시딩', 70),
  ('seeding_fee_krw_tiktok_t100',              99014, 'krw', '진행비 — 틱톡 (스탠다드 100건)',              '시딩', 71),
  ('seeding_fee_krw_tiktok_t300',              99015, 'krw', '진행비 — 틱톡 (프리미엄 300건)',              '시딩', 72),
  ('seeding_fee_krw_tiktok_t500plus',          99016, 'krw', '진행비 — 틱톡 (500건 이상)',                  '시딩', 73),

  ('seeding_fee_krw_youtube_t50',              99017, 'krw', '진행비 — 유튜브 (라이트 50건)',               '시딩', 80),
  ('seeding_fee_krw_youtube_t100',             99018, 'krw', '진행비 — 유튜브 (스탠다드 100건)',            '시딩', 81),
  ('seeding_fee_krw_youtube_t300',             99019, 'krw', '진행비 — 유튜브 (프리미엄 300건)',            '시딩', 82),
  ('seeding_fee_krw_youtube_t500plus',         99020, 'krw', '진행비 — 유튜브 (500건 이상)',                '시딩', 83)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------
-- [D] 옛 6행 삭제 — 구간이 없어 더 이상 읽히지 않는다
--   ⚠️ 견적 계산(마이그레이션 ②)이 구간 열쇠말만 읽게 바뀐 뒤에도 이 행이 남아 있으면
--      화면에 「안 쓰이는데 고칠 수 있는 값」이 보여 운영자가 그걸 고치고 반영을 기다린다.
-- ------------------------------------------------------------
DELETE FROM public.quote_settings
 WHERE key IN (
   'reviewer_recruit_fee_krw',
   'seeding_fee_krw_instagram_feed',
   'seeding_fee_krw_instagram_reels',
   'seeding_fee_krw_x',
   'seeding_fee_krw_tiktok',
   'seeding_fee_krw_youtube'
 );

-- ------------------------------------------------------------
-- [E] get_quote_settings — 반환 8칸 (group_ko 추가)
--   🔴 DROP 후 CREATE 라 426 의 회수·부여가 사라진다 → 아래에서 다시 건다
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_quote_settings();

CREATE FUNCTION public.get_quote_settings()
-- ⚠️ 새 칸은 **맨 끝**에 붙인다 — 부르는 쪽이 이름으로 읽어 지금은 위치가 상관없지만,
--    가운데 끼우면 다음에 자리로 읽는 코드가 생겼을 때 조용히 어긋난다
RETURNS TABLE (key text, amount numeric, unit text, label_ko text,
               sort_order integer, updated_at timestamptz, updated_by uuid, group_ko text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT q.key, q.amount, q.unit, q.label_ko, q.sort_order, q.updated_at, q.updated_by, q.group_ko
  FROM public.quote_settings q
  WHERE public.is_admin()
  ORDER BY q.sort_order, q.key;
$$;

REVOKE ALL ON FUNCTION public.get_quote_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quote_settings() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_quote_settings() TO authenticated;

COMMENT ON FUNCTION public.get_quote_settings() IS
  '[442, 베이스 426] 견적 기준값 전체 조회 — 관리자(is_admin)만, 아니면 0행. 반환에 group_ko(화면 묶음 머리) 추가. '
  '⚠️ 반환 칸을 또 늘리면 다시 DROP 후 CREATE 라 실행 권한(PUBLIC·anon 회수 + authenticated 부여)을 같은 파일에서 다시 걸 것.';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후 — 사양서 §9-1 1·2번)
-- ============================================================
/*
-- [V1] 29행인가 · 옛 6행은 사라졌나
SELECT count(*) AS total FROM public.quote_settings;                                  -- 29
SELECT count(*) AS old_rows FROM public.quote_settings
 WHERE key IN ('reviewer_recruit_fee_krw','seeding_fee_krw_instagram_feed','seeding_fee_krw_instagram_reels',
               'seeding_fee_krw_x','seeding_fee_krw_tiktok','seeding_fee_krw_youtube');  -- 0

-- [V2] 🔴 실행 권한 — proacl 맨 앞에 =X/ (공개) 없음, anon 없음, authenticated 있음
SELECT proname, proacl::text FROM pg_proc
 WHERE pronamespace = 'public'::regnamespace AND proname = 'get_quote_settings';

-- [V3] 시딩 20행이 표 순서대로 99001~99020 인가 (0 이 아니다)
SELECT key, amount, group_ko, sort_order FROM public.quote_settings
 WHERE group_ko = '시딩' ORDER BY sort_order;                                          -- 20행, 99001..99020

-- [V4] 묶음·환율 단위
SELECT group_ko, count(*) FROM public.quote_settings GROUP BY group_ko ORDER BY group_ko;  -- 공통 2 · 리뷰어 7 · 시딩 20
SELECT key, unit FROM public.quote_settings WHERE key = 'exchange_rate_krw_per_jpy';       -- krw

-- [V5] (관리자 로그인 브라우저 콘솔) await db.rpc('get_quote_settings')  → 29행, group_ko 채워짐
*/

-- ============================================================
-- 되돌리기 (그대로 실행 — 위에서 아래 순서로)
-- ============================================================
--   🔴 ①함수부터 되돌린다. 426 의 함수 블록은 `CREATE OR REPLACE` 라 **반환 칸이 달라 그대로는 실패**한다
--      ("cannot change return type of existing function") — 반드시 DROP 이 먼저다.
--   🔴 ②[B] 가 고친 세 행은 426 의 시드(`ON CONFLICT DO NOTHING`)로 안 돌아온다 — 아래 UPDATE 로 되돌린다.
/*
BEGIN;

-- ① 함수 — 426 판(반환 7칸)으로
DROP FUNCTION IF EXISTS public.get_quote_settings();
CREATE FUNCTION public.get_quote_settings()
RETURNS TABLE (key text, amount numeric, unit text, label_ko text, sort_order integer, updated_at timestamptz, updated_by uuid)
LANGUAGE sql SECURITY DEFINER SET search_path = ''
AS $rb$
  SELECT q.key, q.amount, q.unit, q.label_ko, q.sort_order, q.updated_at, q.updated_by
  FROM public.quote_settings q WHERE public.is_admin() ORDER BY q.sort_order, q.key;
$rb$;
REVOKE ALL ON FUNCTION public.get_quote_settings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_quote_settings() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_quote_settings() TO authenticated;

-- ② [C] 가 넣은 26행 삭제
DELETE FROM public.quote_settings
 WHERE key LIKE 'reviewer_recruit_fee_krw_%'
    OR key LIKE 'reviewer_option_fee_krw_%'
    OR key LIKE 'seeding_fee_krw_%_t%';

-- ③ [D] 가 지운 옛 6행 복구 (426 의 값 그대로 — 모집비 0 · 시딩 0)
INSERT INTO public.quote_settings (key, amount, unit, label_ko, sort_order) VALUES
  ('reviewer_recruit_fee_krw',        0, 'krw', '리뷰어 1명당 모집비',                 30),
  ('seeding_fee_krw_instagram_feed',  0, 'krw', '시딩 1명당 진행비 — 인스타그램 피드',  40),
  ('seeding_fee_krw_instagram_reels', 0, 'krw', '시딩 1명당 진행비 — 인스타그램 릴스',  41),
  ('seeding_fee_krw_x',               0, 'krw', '시딩 1명당 진행비 — X',               42),
  ('seeding_fee_krw_tiktok',          0, 'krw', '시딩 1명당 진행비 — 틱톡',            43),
  ('seeding_fee_krw_youtube',         0, 'krw', '시딩 1명당 진행비 — 유튜브',          44)
ON CONFLICT (key) DO NOTHING;

-- ④ [B] 가 고친 세 행 되돌리기 (426 의 값)
UPDATE public.quote_settings SET sort_order = 10 WHERE key = 'exchange_rate_krw_per_jpy';
UPDATE public.quote_settings SET sort_order = 90 WHERE key = 'vat_rate';
UPDATE public.quote_settings SET sort_order = 20, label_ko = '리뷰어 1명당 해외 송금 수수료'
 WHERE key = 'reviewer_transfer_fee_krw';

-- ⑤ 칸 삭제
ALTER TABLE public.quote_settings DROP COLUMN IF EXISTS group_ko;

NOTIFY pgrst, 'reload schema';
COMMIT;
*/
