-- ============================================================
-- 연령 정책 자동 시행 검증 SQL
-- 파일: supabase/patches/2026-06-18_verify_age_policy_trigger.sql
-- 대상: 개발 DB (qysmxtipobomefudyixw) 전용 — 운영 실행 금지
--
-- 목적:
--   age_policy_settings.effective_date 에 시행일을 설정했을 때
--   check_age_policy 트리거가 KST 날짜 기준으로 차단/통과를
--   정확히 판정하는지 확인한다.
--
-- 실행 방법:
--   개발 Supabase 대시보드 → SQL Editor → 아래 시나리오를 1개씩 복사 실행
--   각 시나리오는 BEGIN/ROLLBACK으로 감싸 실제 데이터 변경이 남지 않는다.
--
-- 주의:
--   - 이 파일의 SQL을 전체 한 번에 실행하면 트랜잭션이 섞인다.
--     반드시 === 구분선 기준으로 1개씩 복사해서 실행할 것.
--   - ROLLBACK 후 age_policy_settings.effective_date 는 원래 값(NULL)으로
--     자동 복귀된다. 별도로 되돌릴 필요 없다.
--   - lock_influencer_birthdate 트리거가 이미 birthdate 가 설정된 인플에
--     대한 UPDATE를 차단하므로, 시나리오 내에서 birthdate = NULL 인 인플
--     행을 직접 UPDATE해 테스트한다. TX 안에서 UPDATE → INSERT → ROLLBACK
--     순서를 사용하면 원본이 남지 않는다.
-- ============================================================

-- ============================================================
-- [사전 확인] 현재 설정 + 헬퍼 함수 동작 확인
-- 이 쿼리만 먼저 실행해 환경이 정상인지 확인한다 (TX 불필요)
-- ============================================================

-- 현재 시행일 설정 확인 (NULL = 차단 비활성이 정상)
SELECT
  id,
  effective_date,
  description,
  updated_at
FROM public.age_policy_settings
WHERE id = 1;
-- 기대: effective_date = NULL

-- KST 오늘 날짜 + 만 나이 헬퍼 확인
SELECT
  (now() AT TIME ZONE 'Asia/Tokyo')::date                AS today_kst,
  public.calc_age_kst('2008-06-18'::date)                AS age_should_be_17,
  public.calc_age_kst('2008-06-17'::date)                AS age_should_be_18,
  public.calc_age_kst('1990-01-01'::date)                AS age_should_be_36;
-- 기대 (2026-06-18 KST 기준):
--   today_kst       = 2026-06-18
--   age_should_be_17 = 17  (오늘 생일인 2008년생은 아직 17세)
--   age_should_be_18 = 18  (어제 생일 지난 2008년생은 18세)
--   age_should_be_36 = 36

-- 트리거 존재 확인
SELECT trigger_name, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'public'
  AND trigger_name IN ('trg_age_policy', 'trg_lock_influencer_birthdate')
ORDER BY trigger_name;
-- 기대: 2행 (trg_age_policy, trg_lock_influencer_birthdate)

-- 테스트에 사용할 인플루언서 id 확인 (birthdate = NULL 인 행 아무거나)
SELECT id, email, birthdate
FROM public.influencers
WHERE birthdate IS NULL
LIMIT 3;
-- 기대: id 값 1~3개가 표시됨. 아래 시나리오에서 이 id 중 하나를 사용.
-- (모든 인플이 birthdate = NOT NULL 이면 마지막 "birthdate 있는 성인" 시나리오 참조)


-- ============================================================
-- [시나리오 A] effective_date = 미래 날짜 → 18세 미만이어도 통과 (시행 전)
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    effective_date 가 오늘보다 미래이면 check_age_policy 가 통과(RETURN NEW)해야 한다.
    2100년 미래 설정 → 미성년 birthdate 로 INSERT 시도 → 오류 없이 통과.
    ROLLBACK 으로 모두 되돌림.
*/
BEGIN;

-- (1) 시행일을 먼 미래로 설정
UPDATE public.age_policy_settings
   SET effective_date = '2100-01-01'
 WHERE id = 1;

-- (2) birthdate 없는 인플 행에 미성년 날짜 임시 세팅
--     (lock_influencer_birthdate 는 NULL → 값 변경은 허용)
--     아래 WHERE 절의 이메일을 [사전 확인]에서 조회한 실제 이메일로 변경
UPDATE public.influencers
   SET birthdate = '2015-01-01'   -- 만 11세 (명백히 미성년)
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;         -- birthdate NULL 인 행만 (잠금 트리거 우회 조건)

-- birthdate 가 세팅됐는지 확인 (1행이어야 함)
SELECT id, email, birthdate FROM public.influencers WHERE email = 'sakura.test@reverb.jp';

-- (3) active 캠페인 id 확인 (INSERT 에 campaign_id 필요)
SELECT id, title, status FROM public.campaigns WHERE status = 'active' LIMIT 1;

-- (4) 응모 INSERT 시도 — 통과돼야 함 (P0002 안 나야 함)
--     아래 user_id 와 campaign_id 를 위 쿼리 결과로 교체
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 A 검증용 — 시행 전 통과 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 성공 메시지가 보이면 시나리오 A 통과 ✓
-- "1 row(s) inserted" 가 보여야 정상. P0002 오류가 나오면 시행 전 통과 로직 버그.

ROLLBACK;
-- ROLLBACK 후 age_policy_settings.effective_date 는 원래 NULL 로 복귀,
-- applications INSERT 도 취소, influencers.birthdate 도 원래 NULL 로 복귀.


-- ============================================================
-- [시나리오 B-1] effective_date = 과거 날짜 + birthdate NULL → P0002 차단
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    시행일이 이미 지났고 인플루언서의 birthdate 가 NULL 이면 P0002 를 발생시켜야 한다.
    즉 생년월일 미입력 상태로는 응모 불가.
*/
BEGIN;

-- (1) 시행일을 과거로 설정 (이미 시행된 상태 시뮬레이션)
UPDATE public.age_policy_settings
   SET effective_date = '2000-01-01'
 WHERE id = 1;

-- (2) 대상 인플루언서가 birthdate = NULL 인지 확인
--     (NULL 이 아닌 경우 UPDATE 로 NULL 로 되돌리려 하면 lock_influencer_birthdate 가 차단함 — 주의)
--     이 시나리오는 birthdate 가 이미 NULL 인 인플로만 테스트 가능.
SELECT id, email, birthdate FROM public.influencers WHERE email = 'sakura.test@reverb.jp';
-- birthdate = NULL 이어야 함. 값이 있으면 yui.test@reverb.jp 로 바꿔 시도.

-- (3) 응모 INSERT 시도 → P0002 차단 기대
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 B-1 검증용 — birthdate NULL 차단 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: ERROR  P0002: 응모하려면 먼저 생년월일을 입력해 주세요 (연령 정책 2026)
-- 위 오류가 나오면 시나리오 B-1 검증 통과 ✓

ROLLBACK;


-- ============================================================
-- [시나리오 B-2] effective_date = 과거 날짜 + birthdate = 미성년 → P0002 차단
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    시행일이 지났고 인플루언서의 birthdate 가 18세 미만이면 P0002 차단.
    생년월일 입력은 했지만 미성년인 경우.
*/
BEGIN;

-- (1) 시행일을 과거로 설정
UPDATE public.age_policy_settings
   SET effective_date = '2000-01-01'
 WHERE id = 1;

-- (2) 미성년 birthdate 임시 세팅 (NULL → 값 변경은 lock_influencer_birthdate 가 허용)
UPDATE public.influencers
   SET birthdate = '2015-01-01'   -- 만 11세
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

-- 세팅 확인
SELECT id, email, birthdate, public.calc_age_kst(birthdate) AS age
FROM public.influencers
WHERE email = 'sakura.test@reverb.jp';
-- 기대: age = 11

-- (3) 응모 INSERT 시도 → P0002 차단 기대
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 B-2 검증용 — 미성년 차단 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: ERROR  P0002: 본 서비스는 만 18세 이상만 응모할 수 있습니다 (현재 만 11세)
-- 위 오류가 나오면 시나리오 B-2 검증 통과 ✓

ROLLBACK;


-- ============================================================
-- [시나리오 C] effective_date = NULL → 미성년이어도 통과 (현재 운영 상태)
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    effective_date 가 NULL(=차단 비활성)이면 어떤 birthdate 여도 통과해야 한다.
    현재 운영서버 상태에서 기존 인플루언서 응모가 영향받지 않음을 확인.
*/
BEGIN;

-- (1) effective_date = NULL 유지 확인 (이미 NULL 이어야 함 — 전 시나리오 ROLLBACK 이후)
SELECT effective_date FROM public.age_policy_settings WHERE id = 1;
-- 기대: NULL

-- (2) 미성년 birthdate 임시 세팅
UPDATE public.influencers
   SET birthdate = '2015-01-01'
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

-- (3) 응모 INSERT 시도 → 통과 기대 (차단 비활성이므로)
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 C 검증용 — NULL 비활성 통과 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: "1 row(s) inserted" (오류 없이 통과)
-- P0002 가 나오면 effective_date NULL 판정 로직 버그.

ROLLBACK;


-- ============================================================
-- [시나리오 D] KST 날짜 경계 검증 — effective_date = 오늘(KST) → 차단 활성
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    effective_date 가 오늘 KST 날짜와 같을 때 차단이 활성화되는지 확인.
    트리거 조건: v_today_kst < v_effective_date → 통과 (오늘 < 내일)
                 v_today_kst >= v_effective_date → 차단 판정 진입 (오늘 = 오늘)
    즉 effective_date = 오늘이면 "당일부터 차단"이 된다.
*/
BEGIN;

-- (1) effective_date = 오늘 KST 날짜로 설정
UPDATE public.age_policy_settings
   SET effective_date = (now() AT TIME ZONE 'Asia/Tokyo')::date
 WHERE id = 1;

-- 설정 확인
SELECT
  effective_date,
  (now() AT TIME ZONE 'Asia/Tokyo')::date AS today_kst,
  ((now() AT TIME ZONE 'Asia/Tokyo')::date < effective_date) AS is_before_effective  -- false 기대
FROM public.age_policy_settings
WHERE id = 1;
-- 기대: is_before_effective = false (오늘 = effective_date 이므로 시행 전 조건 불충족 → 차단 판정)

-- (2) 미성년 birthdate 임시 세팅
UPDATE public.influencers
   SET birthdate = '2015-01-01'
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

-- (3) 응모 INSERT 시도 → P0002 차단 기대
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 D 검증용 — 당일 경계 차단 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: ERROR  P0002 (차단됨)
-- effective_date = 오늘이면 당일 KST 0시부터 즉시 차단됨을 확인.

ROLLBACK;


-- ============================================================
-- [시나리오 E] effective_date = 내일 KST → 아직 시행 전 → 통과
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    effective_date 가 내일이면 아직 시행 전이라 통과해야 한다.
    "7/19 0시(KST)부터 차단"을 원하면 effective_date = '2026-07-19' 로 설정하면 됨.
    7/18 23:59 KST 에는 아직 7/18이므로 v_today_kst='2026-07-18' < '2026-07-19' → 통과.
    7/19 00:00 KST 에는 v_today_kst='2026-07-19' = effective_date → 차단 판정 진입.
*/
BEGIN;

-- (1) effective_date = 내일 KST 날짜로 설정
UPDATE public.age_policy_settings
   SET effective_date = (now() AT TIME ZONE 'Asia/Tokyo')::date + 1
 WHERE id = 1;

-- 설정 확인
SELECT
  effective_date,
  (now() AT TIME ZONE 'Asia/Tokyo')::date AS today_kst,
  ((now() AT TIME ZONE 'Asia/Tokyo')::date < effective_date) AS is_before_effective  -- true 기대
FROM public.age_policy_settings
WHERE id = 1;
-- 기대: is_before_effective = true (오늘 < 내일 → 시행 전 → 통과 경로)

-- (2) 미성년 birthdate 임시 세팅
UPDATE public.influencers
   SET birthdate = '2015-01-01'
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

-- (3) 응모 INSERT 시도 → 통과 기대
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 E 검증용 — 내일 시행 전 통과 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: "1 row(s) inserted" (오류 없이 통과)

ROLLBACK;


-- ============================================================
-- [시나리오 F] 성인 birthdate → 시행 후에도 통과
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    시행일이 지났더라도 만 18세 이상이면 정상 통과해야 한다.
    연령 정책의 핵심: 미성년만 차단, 성인은 영향 없음.
*/
BEGIN;

-- (1) 시행일을 과거로 설정
UPDATE public.age_policy_settings
   SET effective_date = '2000-01-01'
 WHERE id = 1;

-- (2) 성인 birthdate 임시 세팅 (만 30세)
UPDATE public.influencers
   SET birthdate = '1996-01-01'
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

-- 만 나이 확인
SELECT public.calc_age_kst('1996-01-01'::date) AS age;
-- 기대: 30

-- (3) 응모 INSERT 시도 → 통과 기대
INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 F 검증용 — 성인 시행 후 통과 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;

-- 기대: "1 row(s) inserted" (오류 없이 통과)
-- P0002 가 나오면 성인 통과 로직 버그.

ROLLBACK;


-- ============================================================
-- [시나리오 G] 만 18세 경계값 — 오늘이 생일인 경우
-- 복사해서 SQL Editor에 붙여넣고 실행
-- ============================================================
/*
  검증 목표:
    만 18세가 되는 생일 당일에도 통과해야 한다.
    calc_age_kst 의 age() 함수는 생일 당일에 만 나이를 올린다.
    즉 오늘 생일인 2008년생 → 만 18세 → 통과.
    어제 생일인 2008년생도 만 18세 → 통과.
    내일 생일인 2008년생은 만 17세 → 차단.

    [!] 이 시나리오는 실행 날짜에 따라 birthdate 값을 조정해야 함.
    오늘(KST) - 18년 = 경계 날짜. 아래 쿼리로 자동 계산.
*/
BEGIN;

-- (1) 시행일을 과거로 설정
UPDATE public.age_policy_settings
   SET effective_date = '2000-01-01'
 WHERE id = 1;

-- (2) 오늘 기준 만 18세 생일 날짜 계산
SELECT
  (now() AT TIME ZONE 'Asia/Tokyo')::date AS today_kst,
  ((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '18 years')::date AS birthday_exactly_18,
  (((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '18 years')::date + 1) AS birthday_17_until_tomorrow;
-- birthday_exactly_18 = 오늘 기준 만 18세가 되는 생일 (이 날짜 이전 생일 → 18세)
-- birthday_17_until_tomorrow = 내일 생일 → 아직 17세

-- (3) 오늘 생일인 만 18세로 세팅 → 통과 기대
UPDATE public.influencers
   SET birthdate = ((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '18 years')::date
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

SELECT public.calc_age_kst(birthdate) AS age FROM public.influencers WHERE email = 'sakura.test@reverb.jp';
-- 기대: 18

INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 G 검증용 — 만 18세 생일 당일 통과 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;
-- 기대: "1 row(s) inserted" (통과)

ROLLBACK;

-- (4) 별도 TX: 내일이 생일인 만 17세 → 차단 확인
BEGIN;

UPDATE public.age_policy_settings
   SET effective_date = '2000-01-01'
 WHERE id = 1;

UPDATE public.influencers
   SET birthdate = (((now() AT TIME ZONE 'Asia/Tokyo')::date - INTERVAL '18 years')::date + 1)
 WHERE email = 'sakura.test@reverb.jp'
   AND birthdate IS NULL;

SELECT public.calc_age_kst(birthdate) AS age FROM public.influencers WHERE email = 'sakura.test@reverb.jp';
-- 기대: 17

INSERT INTO public.applications (user_id, campaign_id, message, status)
SELECT
  inf.id,
  camp.id,
  '시나리오 G-2 검증용 — 만 17세 차단 확인',
  'pending'
FROM public.influencers inf
CROSS JOIN (SELECT id FROM public.campaigns WHERE status = 'active' LIMIT 1) camp
WHERE inf.email = 'sakura.test@reverb.jp'
LIMIT 1;
-- 기대: P0002 차단

ROLLBACK;


-- ============================================================
-- [사후 확인] 모든 시나리오 ROLLBACK 이후 원상태 확인
-- ROLLBACK 다 끝낸 후 이 쿼리만 실행
-- ============================================================

SELECT
  (SELECT effective_date FROM public.age_policy_settings WHERE id = 1) AS effective_date_should_be_null,
  (SELECT birthdate FROM public.influencers WHERE email = 'sakura.test@reverb.jp') AS sakura_birthdate_should_be_null,
  (SELECT COUNT(*) FROM public.applications WHERE message LIKE '시나리오%검증용%') AS test_rows_should_be_0;
-- 기대:
--   effective_date_should_be_null = NULL (원래 비활성 상태로 복귀)
--   sakura_birthdate_should_be_null = NULL (birthdate 미변경 상태 복귀)
--   test_rows_should_be_0 = 0 (ROLLBACK 으로 테스트 행 없음)
