-- ============================================================
-- 453_quote_settings_tier_slots.sql
-- 2026-09-18 — 오리엔시트 구간별 모집 인원을 기준 데이터로 · 마이그레이션 ①
--   사양서 docs/specs/2026-09-18-orient-tier-slots-as-settings.md §3-1 · §3-6 · §3-7
--   베이스: 442_quote_settings_tiered.sql(group_ko·라벨) + 448_orient_tier_500_fixed_and_fee_lookup.sql(500건 라벨)
--
-- 계기: 가격표(구글 시트)를 만들다 **둘째 구간이 150명**인데 구현은 **100명**인 것을 발견.
--   구간별 모집 인원(50·100·300·500)이 서버 판정식(_orient_compute_quote)·작성 폼 단추(TIER_OPTIONS)·
--   기준값 라벨(quote_settings.label_ko) 세 곳에 글자로 박혀 있어, 값을 바꾸려면 배포가 필요했다.
--   이 파일은 그 인원을 quote_settings 행 4개로 뺀다. 판정식·조회 함수가 그 값을 읽게 하는 것은
--   다음 파일(454)이다 — **이 파일이 반드시 먼저** 적용돼야 한다(454 가 없는 행을 읽으면 실패한다).
--
-- 🔴 열쇠말(t50·t100·t300·t500plus)은 그대로 둔다 — 값만 데이터가 된다. `t100` 은 **둘째 구간**이라는
--   뜻이고 100명을 뜻하지 않는다(사양서 §2-④ 결정). 150 으로 고쳐도 열쇠말은 t100 그대로다.
--
-- 이 파일이 하는 일 셋
--   [A] quote_settings.unit CHECK 에 'count' 추가(구간 인원은 금액이 아니다 — §2-⑥)
--   [B] 신규 4행 — tier_slots_t50·t100·t300·t500plus, unit='count', group_ko='구간'
--   [C] 기존 24행(리뷰어 4 + 시딩 20)의 label_ko 에서 건수 숫자를 뺀다(§2-③·§3-6) —
--       기준값을 150 으로 고쳐도 라벨이 「(100건)」인 채로 거짓말하지 않도록.
--
-- ------------------------------------------------------------
-- 🔴 [C] — 실제 현재 값을 직접 확인하고 쓴 것이지 442 파일만 보고 짐작한 게 아니다
-- ------------------------------------------------------------
--   442(구간 요금 도입)가 24행을 만들 때 라벨 형태가 **둘로 갈린다**:
--     · 리뷰어 3행(t50·t100·t300): "모집비 — {티어명} ({N}건)"   ← 티어 이름이 괄호 밖에 있다
--     · 시딩 15행(5채널×3티어):    "진행비 — {채널} ({티어명} {N}건)" ← 티어 이름이 괄호 **안**에 있다
--   그리고 448(500건 고정)이 "500건 이상" → "500건"으로 6행(리뷰어 1 + 시딩 5)을 고쳐, 지금은:
--     · 리뷰어 t500plus: "모집비 — 500건"                (괄호가 아예 없다 — 이름 자리를 숫자가 대신한다)
--     · 시딩 t500plus:   "진행비 — {채널} (500건)"         (괄호 안에 숫자만 — 티어 이름이 없다)
--   즉 실제로는 **네 가지 구조**가 섞여 있어(리뷰어 일반 3 / 리뷰어 500건 1 / 시딩 일반 15 / 시딩 500건 5,
--   3+1+15+5=24), 단 하나의 정규식으로 안전하게 지울 수 없다. (작성 중 442 파일만 보고 "이상"이 붙은
--   6행까지 포함해 세면 18줄로 보이는 착시가 있었다 — 448 이 그 "이상"을 이미 지웠으므로 지금
--   실제 표는 24행 전부가 "이상" 없는 형태다. 아래 [V0] 으로 적용 전 실제 값을 먼저 확인할 것.)
--   → 아래 네 UPDATE 는 **key 로 대상을 좁혀서**(이게 진짜 안전장치다 — 정규식 모양이 아니라 key 로
--     구분하면 "1건당" 같은 무관한 값을 건드릴 일이 구조적으로 없다) 각 구조에 맞는 치환을 쓴다.
--     리뷰어 500+행·시딩 500+행은 숫자 자리에 이름이 없어 숫자를 그냥 지우면 "모집비 — " 처럼
--     이름이 통째로 비므로, 새로 만드는 tier_slots_t500plus 의 라벨과 같은 이름("실검작업 구간")을
--     붙인다 — 이미 이 저장소가 쓰는 낱말이다(443 의 견적 줄 "실검작업 — 담당자 협의").
--
-- ⚠️ 되돌리는 대상 밖(안 건드리는 것): reviewer_transfer_fee_krw("1건당 해외 송금 수수료"),
--   reviewer_option_fee_krw_lips/cosme("(1건당)") — 이 셋의 "1건당"은 구간 인원이 아니라
--   "1건에 대해" 라는 단가 설명이라 지울 대상이 아니다. key 로 좁혔으므로 자동으로 제외된다.
--
-- 롤백: 이 파일 맨 아래 「되돌리기」 블록을 그대로 실행.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- [A] unit 검사 제약에 'count' 추가
-- ------------------------------------------------------------
ALTER TABLE public.quote_settings
  DROP CONSTRAINT IF EXISTS quote_settings_unit_check;
ALTER TABLE public.quote_settings
  ADD CONSTRAINT quote_settings_unit_check
  CHECK (unit IN ('krw', 'jpy', 'rate', 'count'));

COMMENT ON COLUMN public.quote_settings.unit IS
  '[453, 베이스 426] krw=원 금액 · jpy=엔 금액 · rate=비율(0.10 = 10%) · count=인원(구간 경계값, 금액 아님).';

-- ------------------------------------------------------------
-- [B] 신규 4행 — 구간 인원 (있으면 건드리지 않는다 — 재실행 안전)
--   sort_order 12~15 — 공통(10·11) 다음, 리뷰어(20~)·시딩(40~) 앞. 구간 인원은 그 두 표가
--   같이 참조하는 값이라 "공통" 바로 아래, 실제 금액표들 위에 두는 것이 읽는 순서에 맞다.
-- ------------------------------------------------------------
INSERT INTO public.quote_settings (key, amount, unit, label_ko, group_ko, sort_order) VALUES
  ('tier_slots_t50',       50,  'count', '구간 인원 — 라이트',        '구간', 12),
  ('tier_slots_t100',      100, 'count', '구간 인원 — 스탠다드',       '구간', 13),
  ('tier_slots_t300',      300, 'count', '구간 인원 — 프리미엄',       '구간', 14),
  ('tier_slots_t500plus',  500, 'count', '구간 인원 — 실검작업 구간',  '구간', 15)
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------
-- [C-1] 리뷰어 일반 3행 — "모집비 — {티어명} ({N}건)" → "모집비 — {티어명}"
--   괄호 안이 숫자+건 뿐이라 괄호째 지운다(티어 이름은 괄호 밖에 이미 있다).
-- ------------------------------------------------------------
UPDATE public.quote_settings
   SET label_ko = regexp_replace(label_ko, '\s*\(\d+건\)$', '')
 WHERE key IN ('reviewer_recruit_fee_krw_t50', 'reviewer_recruit_fee_krw_t100', 'reviewer_recruit_fee_krw_t300')
   AND label_ko ~ '\(\d+건\)$';

-- ------------------------------------------------------------
-- [C-2] 리뷰어 500+행 — "모집비 — 500건" → "모집비 — 실검작업 구간"
--   괄호가 없다 — 숫자 자리가 곧 이름 자리라, 지우면 이름이 통째로 사라진다. 새 tier_slots_t500plus
--   라벨과 같은 이름을 붙인다.
-- ------------------------------------------------------------
UPDATE public.quote_settings
   SET label_ko = '모집비 — 실검작업 구간'
 WHERE key = 'reviewer_recruit_fee_krw_t500plus'
   AND label_ko ~ '\d+건';

-- ------------------------------------------------------------
-- [C-3] 시딩 일반 15행 — "진행비 — {채널} ({티어명} {N}건)" → "진행비 — {채널} ({티어명})"
--   괄호 안에 티어 이름 + 숫자가 같이 있다 — 숫자 부분만 지우고 괄호는 남긴다.
-- ------------------------------------------------------------
UPDATE public.quote_settings
   SET label_ko = regexp_replace(label_ko, '\s+\d+건\)$', ')')
 WHERE (key LIKE 'seeding_fee_krw_%_t50' OR key LIKE 'seeding_fee_krw_%_t100' OR key LIKE 'seeding_fee_krw_%_t300')
   AND label_ko ~ '\d+건\)$';

-- ------------------------------------------------------------
-- [C-4] 시딩 500+행 5개 — "진행비 — {채널} (500건)" → "진행비 — {채널} (실검작업 구간)"
--   괄호 안이 숫자뿐이라(티어 이름이 없다) [C-2] 와 같은 이유로 이름을 채워 넣는다 —
--   같은 채널의 나머지 세 티어가 "(라이트)"/"(스탠다드)"/"(프리미엄)" 형태가 되므로 통일된다.
-- ------------------------------------------------------------
UPDATE public.quote_settings
   SET label_ko = regexp_replace(label_ko, '\(\d+건\)$', '(실검작업 구간)')
 WHERE key LIKE 'seeding_fee_krw_%_t500plus'
   AND label_ko ~ '\(\d+건\)$';

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ============================================================
-- 검증 (개발 적용 후)
-- ------------------------------------------------------------
-- [V0] 적용 **전에** 먼저 돌려서 실제 현재 라벨을 눈으로 본다(이 파일 머리말의 "24행" 근거).
--   SELECT key, label_ko FROM public.quote_settings
--    WHERE key LIKE 'reviewer_recruit_fee_krw_t%' OR key LIKE 'seeding_fee_krw_%_t%'
--    ORDER BY sort_order;
--
-- [V1] 적용 후 — 구간 인원 4행 존재 + unit='count'
--   SELECT key, amount, unit, group_ko, sort_order FROM public.quote_settings
--    WHERE key LIKE 'tier_slots_%' ORDER BY sort_order;
--   기대: 4행, amount 50/100/300/500, unit 전부 'count', group_ko 전부 '구간'
--
-- [V2] 🔴 라벨에 숫자가 남아 있지 않은가 — 기존 24행 + 새 4행 둘 다
--   SELECT count(*) AS still_has_digit FROM public.quote_settings
--    WHERE (key LIKE 'reviewer_recruit_fee_krw_t%' OR key LIKE 'seeding_fee_krw_%_t%' OR key LIKE 'tier_slots_%')
--      AND label_ko ~ '[0-9]';
--   기대: 0
--
-- [V3] 손대지 않아야 할 3행은 그대로인가("1건당"은 구간 인원이 아니다)
--   SELECT key, label_ko FROM public.quote_settings
--    WHERE key IN ('reviewer_transfer_fee_krw', 'reviewer_option_fee_krw_lips', 'reviewer_option_fee_krw_cosme');
--   기대: '1건당 해외 송금 수수료' / '추가 옵션 — LIPS (1건당)' / '추가 옵션 — @cosme (1건당)' — 무변경
--
-- [V4] unit 검사 제약 — 잘못된 값은 여전히 거부되는가
--   INSERT INTO public.quote_settings (key, amount, unit, label_ko) VALUES ('zz_test', 1, 'won', '테스트');
--   기대: 23514(check_violation) — 반드시 실패해야 하고, 성공하면 이 행을 바로 DELETE 로 지울 것
--
-- [V5] 전체 건수 — 29(426+442) + 4(신규) = 33
--   SELECT count(*) FROM public.quote_settings;  -- 33
--
-- [V6] 시딩 라벨 표본 — 채널 이름·괄호 구조가 살아 있는가
--   SELECT key, label_ko FROM public.quote_settings WHERE key LIKE 'seeding_fee_krw_instagram_feed_%' ORDER BY sort_order;
--   기대: '진행비 — 인스타그램-피드 (라이트)' / '(스탠다드)' / '(프리미엄)' / '(실검작업 구간)'
-- ============================================================

-- ============================================================
-- 되돌리기 (그대로 실행 — 위에서 아래 순서로)
--   🔴 454 를 먼저 되돌린 뒤에 이 파일을 되돌릴 것 — 454 는 이 파일이 만든 tier_slots_* 행을
--      읽으므로, 이 파일을 먼저 되돌리면(행을 지우면) 454 의 판정식이 전부 fee_missing 이 된다.
-- ============================================================
/*
BEGIN;

-- ① [C] 라벨 복구 — 442·448 이 시드한 원래 문구 그대로
UPDATE public.quote_settings SET label_ko = '모집비 — 라이트 (50건)'        WHERE key = 'reviewer_recruit_fee_krw_t50';
UPDATE public.quote_settings SET label_ko = '모집비 — 스탠다드 (100건)'     WHERE key = 'reviewer_recruit_fee_krw_t100';
UPDATE public.quote_settings SET label_ko = '모집비 — 프리미엄 (300건)'     WHERE key = 'reviewer_recruit_fee_krw_t300';
UPDATE public.quote_settings SET label_ko = '모집비 — 500건'                WHERE key = 'reviewer_recruit_fee_krw_t500plus';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-피드 (라이트 50건)'      WHERE key = 'seeding_fee_krw_instagram_feed_t50';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-피드 (스탠다드 100건)'   WHERE key = 'seeding_fee_krw_instagram_feed_t100';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-피드 (프리미엄 300건)'   WHERE key = 'seeding_fee_krw_instagram_feed_t300';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-피드 (500건)'            WHERE key = 'seeding_fee_krw_instagram_feed_t500plus';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-릴스 (라이트 50건)'      WHERE key = 'seeding_fee_krw_instagram_reels_t50';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-릴스 (스탠다드 100건)'   WHERE key = 'seeding_fee_krw_instagram_reels_t100';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-릴스 (프리미엄 300건)'   WHERE key = 'seeding_fee_krw_instagram_reels_t300';
UPDATE public.quote_settings SET label_ko = '진행비 — 인스타그램-릴스 (500건)'            WHERE key = 'seeding_fee_krw_instagram_reels_t500plus';
UPDATE public.quote_settings SET label_ko = '진행비 — X (라이트 50건)'                    WHERE key = 'seeding_fee_krw_x_t50';
UPDATE public.quote_settings SET label_ko = '진행비 — X (스탠다드 100건)'                 WHERE key = 'seeding_fee_krw_x_t100';
UPDATE public.quote_settings SET label_ko = '진행비 — X (프리미엄 300건)'                 WHERE key = 'seeding_fee_krw_x_t300';
UPDATE public.quote_settings SET label_ko = '진행비 — X (500건)'                          WHERE key = 'seeding_fee_krw_x_t500plus';
UPDATE public.quote_settings SET label_ko = '진행비 — 틱톡 (라이트 50건)'                 WHERE key = 'seeding_fee_krw_tiktok_t50';
UPDATE public.quote_settings SET label_ko = '진행비 — 틱톡 (스탠다드 100건)'              WHERE key = 'seeding_fee_krw_tiktok_t100';
UPDATE public.quote_settings SET label_ko = '진행비 — 틱톡 (프리미엄 300건)'              WHERE key = 'seeding_fee_krw_tiktok_t300';
UPDATE public.quote_settings SET label_ko = '진행비 — 틱톡 (500건)'                       WHERE key = 'seeding_fee_krw_tiktok_t500plus';
UPDATE public.quote_settings SET label_ko = '진행비 — 유튜브 (라이트 50건)'               WHERE key = 'seeding_fee_krw_youtube_t50';
UPDATE public.quote_settings SET label_ko = '진행비 — 유튜브 (스탠다드 100건)'            WHERE key = 'seeding_fee_krw_youtube_t100';
UPDATE public.quote_settings SET label_ko = '진행비 — 유튜브 (프리미엄 300건)'            WHERE key = 'seeding_fee_krw_youtube_t300';
UPDATE public.quote_settings SET label_ko = '진행비 — 유튜브 (500건)'                     WHERE key = 'seeding_fee_krw_youtube_t500plus';

-- ② [B] 신규 4행 삭제
DELETE FROM public.quote_settings WHERE key LIKE 'tier_slots_%';

-- ③ [A] unit 검사 제약 원복
ALTER TABLE public.quote_settings DROP CONSTRAINT IF EXISTS quote_settings_unit_check;
ALTER TABLE public.quote_settings ADD CONSTRAINT quote_settings_unit_check CHECK (unit IN ('krw', 'jpy', 'rate'));
COMMENT ON COLUMN public.quote_settings.unit IS 'krw=원 금액 · jpy=엔 금액 · rate=비율(0.10 = 10%)';

NOTIFY pgrst, 'reload schema';
COMMIT;
*/
