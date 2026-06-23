-- ============================================
-- 마이그레이션 193: @cosme 채널 code 중복 정리
-- 의존: 024 (lookup_values 테이블), 025 (recruit_types 컬럼),
--       157 (cosme 행 최초 INSERT)
-- 대상: 개발서버 + 운영서버 (code 기준 단일 마이그레이션으로 양 서버 동일 적용)
-- 요약:
--   lookup_values(kind='channel')에 '@cosme' 채널이
--   code='channel-96r9y3' (157 이전 시드 행)와
--   code='cosme'          (157 INSERT 행)로 중복 존재 → 캠페인 등록 폼에 2개 노출.
--   code='cosme'를 정식 행으로 통합:
--     STEP 1. campaigns.channel 콤마 목록에서 'channel-96r9y3' → 'cosme' 치환
--             (이미 'cosme'가 있으면 중복 제거·순서 보존)
--     STEP 2. campaigns.primary_channel = 'channel-96r9y3' 방어 치환 (양 서버 0건이나 안전망)
--     STEP 3. lookup_values code='cosme' 행: active=true, sort_order=60 승계
--     STEP 4. lookup_values code='channel-96r9y3' 행 삭제
-- 사용 현황(작성 시점): 개발 campaigns.channel 4건 / 운영 9건(+cosme 1건). primary 양쪽 0건.
-- 위험도: 낮음 (단일 트랜잭션, 롤백 SQL 하단 주석).
-- 영향 외: deliverables.post_channel(클라가 항상 'cosme' 저장), applications,
--          bulk_message RPC(167·168·169·171: 이미 'cosme' 사용),
--          caution/participation/ng_sets.recruit_types(채널 code 미저장) — 모두 무관.
-- FK: lookup_values.code 는 문자열 참조라 외래 키 제약 없음 → DELETE 안전.
-- 시드: supabase/seed/lookup_values.sql 의 channel-96r9y3 행도 동일 커밋에서 cosme 로 교체.
-- 검증 쿼리: 본 파일 하단 [실행 전]/[실행 후] 주석 참고.
-- ============================================

BEGIN;

-- ============================================
-- STEP 1. campaigns.channel 치환 (항목 단위 정확 비교 + 중복 제거 + 순서 보존)
-- ============================================
UPDATE campaigns
SET channel = (
  SELECT array_to_string(array_agg(new_code ORDER BY ord), ',')
  FROM (
    SELECT DISTINCT ON (new_code)
           CASE WHEN trim(elem) = 'channel-96r9y3' THEN 'cosme'
                ELSE trim(elem)
           END AS new_code,
           ord
      FROM unnest(string_to_array(channel, ',')) WITH ORDINALITY AS t(elem, ord)
     ORDER BY new_code, ord
  ) AS deduped
)
WHERE channel LIKE '%channel-96r9y3%';

-- ============================================
-- STEP 2. campaigns.primary_channel 방어 치환
-- ============================================
UPDATE campaigns
SET primary_channel = 'cosme'
WHERE primary_channel = 'channel-96r9y3';

-- ============================================
-- STEP 3. lookup_values code='cosme' 행 승계 (멱등)
-- ============================================
UPDATE lookup_values
SET active        = true,
    sort_order    = 60,
    name_ko       = '엣코스메',
    name_ja       = '@cosme',
    recruit_types = ARRAY['monitor']
WHERE kind = 'channel'
  AND code = 'cosme';

-- ============================================
-- STEP 4. lookup_values code='channel-96r9y3' 행 삭제
-- ============================================
DELETE FROM lookup_values
WHERE kind = 'channel'
  AND code = 'channel-96r9y3';

COMMIT;

-- ============================================
-- [실행 전] 현황 확인 (읽기 전용)
-- ============================================
--   SELECT id, code, name_ko, name_ja, sort_order, active
--     FROM lookup_values
--    WHERE kind='channel' AND code IN ('channel-96r9y3','cosme') ORDER BY sort_order;
--   -- 두 code를 동시에 가진 캠페인(있으면 STEP 1 이 중복 제거):
--   SELECT id, title, channel FROM campaigns
--    WHERE channel LIKE '%channel-96r9y3%' AND channel LIKE '%cosme%';

-- ============================================
-- [실행 후] 검증
-- ============================================
--   SELECT id, code, name_ko, name_ja, sort_order, active, recruit_types
--     FROM lookup_values
--    WHERE kind='channel' AND code IN ('channel-96r9y3','cosme') ORDER BY sort_order;
--   -- 기대: cosme 1행만 (active=true, sort_order=60, name_ko/ja='@cosme', recruit_types='{monitor}')
--   SELECT COUNT(*) FROM campaigns WHERE channel LIKE '%channel-96r9y3%';
--   -- 기대: 0

-- ============================================
-- [롤백] 필요 시 STEP 역순 수동 실행
-- ============================================
-- BEGIN;
--   INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active, recruit_types)
--   VALUES ('channel','channel-96r9y3','엣코스메','@Cosme',60,true,ARRAY['monitor'])
--   ON CONFLICT (kind, code) DO NOTHING;
--   UPDATE lookup_values SET active=true, sort_order=70, name_ko='@cosme', name_ja='@cosme'
--    WHERE kind='channel' AND code='cosme';
--   UPDATE campaigns SET channel = (
--     SELECT array_to_string(array_agg(
--       CASE WHEN trim(elem)='cosme' THEN 'channel-96r9y3' ELSE trim(elem) END ORDER BY ord), ',')
--     FROM unnest(string_to_array(channel, ',')) WITH ORDINALITY AS t(elem, ord))
--    WHERE channel LIKE '%cosme%';
-- COMMIT;
