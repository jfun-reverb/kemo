-- ============================================================
-- 099_seeding_transfer_fee_force_zero.sql
-- form_type='seeding' 행의 products[].transfer_fee_krw 를 무조건 0 으로 일괄 정규화
--
-- 배경:
--   098 마이그레이션이 fill_reviewer_transfer_fee() 트리거를 확장해서
--   신규 시딩 INSERT 시 0 을 자동으로 채우도록 했고 backfill 도 수행했음.
--   그러나 098 backfill 조건은 "키 없거나 null/빈 문자열"만 채우는 구조여서,
--   098 적용 전 운영팀이 관리자 화면 신규 신청 등록 모달에서 placeholder
--   ("reviewer 자동 2500")만 보고 시딩 신청에도 직접 2500 을 입력해 두었던
--   기존 행은 "명시 입력값" 으로 간주되어 그대로 남음.
--
--   운영 화면에서 시딩 신청 14건 모두 ₩2,500 으로 표시되는 회귀 발생.
--
-- 해결:
--   form_type='seeding' 행의 products 배열 모든 원소에 대해 transfer_fee_krw 키
--   기존 값과 무관하게 0 으로 강제 설정. 사용자 의도(시딩 = 무조건 0)에 맞춤.
--   reviewer 행은 절대 건드리지 않음.
--
-- 영향 분석:
--   ※ trg_brand_app_touch(052) BEFORE UPDATE 트리거가 version 을 +1 증가시키고
--     updated_at 을 갱신함. 운영 시간대 피해 실행 권장.
--   ※ 098 backfill 후에도 키가 누락된 행이 새로 들어왔다면 이 마이그레이션도 함께 채움
--     (NULL 잔존도 0 으로 정규화 → 멱등성 보장).
--   ※ 향후 관리자 모달 placeholder 가 098 변경으로 "리뷰어 자동 2500 / 시딩 자동 0"
--     으로 갱신됐으므로 이번 종류의 운영팀 입력 실수는 재발 방지됨.
--
-- 작성일: 2026-05-07
-- ============================================================


-- ============================================================
-- 1. 시딩 행 일괄 정규화 UPDATE
--
--    products 배열 각 원소에 transfer_fee_krw 키를 0 으로 덮어씀.
--    reviewer 행은 WHERE 조건에서 완전히 제외됨.
--    멱등성 보장: 재실행해도 모든 시딩 행은 이미 0 이라 EXISTS 가 false → no-op.
--
--    조건 분기:
--      - 키 없음                 → 0 채움
--      - 키 있고 jsonb null      → 0 으로 덮어씀
--      - 키 있고 NULL 문자열     → 0 으로 덮어씀
--      - 키 있고 빈 문자열       → 0 으로 덮어씀
--      - 키 있고 0 이 아닌 숫자  → 0 으로 덮어씀
--      - 키 있고 0               → 변경 없음 (멱등)
-- ============================================================
UPDATE public.brand_applications
SET products = (
  SELECT jsonb_agg(elem || jsonb_build_object('transfer_fee_krw', 0))
  FROM jsonb_array_elements(products) AS elem
)
WHERE form_type = 'seeding'
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(products) e
    WHERE
      NOT (e ? 'transfer_fee_krw')
      OR e->'transfer_fee_krw' = 'null'::jsonb
      OR (e->>'transfer_fee_krw') IS NULL
      OR (e->>'transfer_fee_krw') = ''
      OR (e->>'transfer_fee_krw')::int <> 0
  );


-- ============================================================
-- 검증 SQL (적용 후 SQL Editor 에서 실행)
-- ============================================================
/*

-- [V0] 사전 영향 행 수 카운트 (실행 전에 실행해서 대상 건수 파악)
SELECT COUNT(*) AS force_zero_target_count
FROM public.brand_applications
WHERE form_type = 'seeding'
  AND products IS NOT NULL
  AND jsonb_typeof(products) = 'array'
  AND jsonb_array_length(products) > 0
  AND EXISTS (
    SELECT 1 FROM jsonb_array_elements(products) e
    WHERE
      NOT (e ? 'transfer_fee_krw')
      OR e->'transfer_fee_krw' = 'null'::jsonb
      OR (e->>'transfer_fee_krw') IS NULL
      OR (e->>'transfer_fee_krw') = ''
      OR (e->>'transfer_fee_krw')::int <> 0
  );


-- [V1] 시딩 신청 transfer_fee_krw 값 분포 — 적용 전후 비교용
SELECT
  COALESCE((e->>'transfer_fee_krw')::int::text, '(NULL)') AS fee_value,
  COUNT(*) AS cnt
FROM public.brand_applications,
     jsonb_array_elements(products) AS e
WHERE form_type = 'seeding'
GROUP BY 1
ORDER BY cnt DESC;
-- 적용 후: '0' 만 남고 다른 값/(NULL) 0건 이어야 함.


-- [V2] 사후 검증 — 시딩 행에 0 이 아닌 transfer_fee_krw 잔존 0건 확인
SELECT COUNT(*) AS non_zero_remaining
FROM public.brand_applications,
     jsonb_array_elements(products) AS e
WHERE form_type = 'seeding'
  AND (
    NOT (e ? 'transfer_fee_krw')
    OR e->'transfer_fee_krw' = 'null'::jsonb
    OR (e->>'transfer_fee_krw') IS NULL
    OR (e->>'transfer_fee_krw') = ''
    OR (e->>'transfer_fee_krw')::int <> 0
  );
-- 0 이어야 함.


-- [V3] reviewer 행 transfer_fee_krw 영향 없음 확인
SELECT
  COALESCE((e->>'transfer_fee_krw')::int::text, '(NULL)') AS fee_value,
  COUNT(*) AS cnt
FROM public.brand_applications,
     jsonb_array_elements(products) AS e
WHERE form_type = 'reviewer'
GROUP BY 1
ORDER BY cnt DESC;
-- 099 적용 전후 분포 동일해야 함 (대부분 2500, 명시 입력값 유지).

*/


-- ============================================================
-- 롤백 SQL
--
-- 099 는 시딩 행의 transfer_fee_krw 를 0 으로 덮어쓰는 데이터 변경이므로
-- 이전 값(2500 등)을 그대로 복원하려면 적용 직전 백업이 필요.
-- audit 컬럼이 없어 SQL 만으로는 이전 값 식별 불가.
--
-- 사전 백업 권장 명령(SQL Editor 외부):
--   pg_dump --table=public.brand_applications --data-only \
--     -h <host> -U <user> -d postgres > brand_applications_backup_pre099.sql
--
-- 실행 직전에 INSERT 된 행 + audit 부재 조합이라 롤백은 백업 의존.
-- 099 자체를 reverse 하는 SQL 은 의미가 없음 (이전 값을 알 수 없음).
-- ============================================================
