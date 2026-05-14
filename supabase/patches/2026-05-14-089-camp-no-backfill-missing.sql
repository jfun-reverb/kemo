-- ============================================================
-- 2026-05-14-089-camp-no-backfill-missing.sql
-- 089 STEP 8 미완료 캠페인 재채번 (one-off 패치)
--
-- 배경:
--   2026-05-14 운영 DB(twofagomeizrtkwlhsuv) PR1 적용 중 089 백필이
--   부분 진행된 흔적 발견. 트리거 088+090 모두 v090 버전 적용됐고
--   brands 47/47 brand_seq 채워졌으나, campaigns 109건 중
--   77건만 B-format 으로 백필 완료되고 32건이 CAMP-format 잔존
--   (신청 파생 4건 + 외부 28건).
--
--   089 STEP 8 의 ROW_NUMBER 일괄 채번을 재실행하면 이미 채번된
--   77건과 unique 충돌(예: B0041-C002). 따라서 32건만 안전하게
--   재채번하는 patch 가 필요함.
--
-- 설계:
--   각 파티션(브랜드 / 신청)별로 이미 발급된 max C-seq 를 구하고,
--   미채번 행에 ROW_NUMBER 오프셋을 더해 새 번호 발급:
--       new_seq = COALESCE(already_max_in_partition, 0) + offset
--   advisory lock 불필요 (단일 트랜잭션 + LOCK TABLE SHARE ROW EXCLUSIVE).
--   STEP 9 GREATEST 동기화 재실행으로 카운터 정합성 보장.
--   STEP 10 매핑 UPSERT 로 numbering_legacy_map 채움.
--
-- 전제:
--   - 088 + 090 트리거 운영 DB 적용 완료
--   - 089 부분 적용 상태 (77/109 백필 완료)
--   - brands.brand_seq 모두 채워짐
--   - 089 STEP 9 (카운터 동기화) 부분 실행돼 last_seq 값 존재
--
-- 실행 순서:
--   1. [PRE-CHECK] BEGIN 없이 SELECT 블록만 먼저 실행해 대상·새 번호 미리 확인
--   2. 이상 없으면 BEGIN..COMMIT 블록 실행 (멱등 + 인라인 검증)
--   3. [POST-CHECK] COMMIT 후 SELECT 로 완료 확인
--
-- ROLLBACK: 파일 하단 「ROLLBACK SQL」 참조
-- ============================================================


-- ============================================================
-- [PRE-CHECK] 실제 적용 전 확인 (트랜잭션 없이 단독 실행)
-- ============================================================
/*

-- [PC1] 대상 32건 식별
SELECT c.id,
       c.campaign_no                        AS current_no,
       b.brand_seq,
       c.source_application_id IS NOT NULL  AS is_derived,
       c.created_at
  FROM public.campaigns c
  LEFT JOIN public.brands b ON b.id = c.brand_id
 WHERE c.campaign_no ~ '^CAMP-'
   AND c.brand_id IS NOT NULL
 ORDER BY c.source_application_id NULLS LAST, c.brand_id, c.created_at;

-- [PC2] 외부 캠페인 브랜드별 기존 max(ext_seq) + 미채번 카운트
SELECT b.brand_seq,
       b.name AS brand_name,
       MAX(
         CASE WHEN c.campaign_no ~ '^B\d{4}-C\d{3}$'
              THEN split_part(c.campaign_no, '-C', 2)::integer
              ELSE 0 END
       ) AS current_max_ext_seq,
       COUNT(*) FILTER (
         WHERE c.campaign_no ~ '^CAMP-'
           AND c.source_application_id IS NULL
       ) AS unassigned_count
  FROM public.campaigns c
  JOIN public.brands     b ON b.id = c.brand_id
 WHERE c.source_application_id IS NULL
 GROUP BY b.brand_seq, b.name
HAVING COUNT(*) FILTER (
         WHERE c.campaign_no ~ '^CAMP-'
           AND c.source_application_id IS NULL
       ) > 0
 ORDER BY b.brand_seq;

-- [PC3] 신청 파생 4건 신청별 기존 max(camp_seq)
SELECT ba.application_no,
       b.brand_seq,
       MAX(
         CASE WHEN c.campaign_no ~ '^B\d{4}-A\d{3}-C\d{3}$'
              THEN split_part(c.campaign_no, '-C', 2)::integer
              ELSE 0 END
       ) AS current_max_camp_seq,
       COUNT(*) FILTER (WHERE c.campaign_no ~ '^CAMP-') AS unassigned_count
  FROM public.campaigns c
  JOIN public.brand_applications ba ON ba.id = c.source_application_id
  JOIN public.brands             b  ON b.id  = c.brand_id
 WHERE c.source_application_id IS NOT NULL
 GROUP BY ba.application_no, b.brand_seq
HAVING COUNT(*) FILTER (WHERE c.campaign_no ~ '^CAMP-') > 0
 ORDER BY ba.application_no;

*/


-- ============================================================
-- 본 실행 (단일 트랜잭션 + 인라인 검증)
-- ============================================================
BEGIN;

LOCK TABLE public.campaigns          IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.brands             IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.brand_applications IN SHARE ROW EXCLUSIVE MODE;


-- ============================================================
-- STEP P-1: legacy_no 보완 (089 STEP 6 누락분만)
-- ============================================================
UPDATE public.campaigns
   SET legacy_no = campaign_no
 WHERE campaign_no ~ '^CAMP-'
   AND legacy_no IS NULL;


-- ============================================================
-- STEP P-2: 외부 캠페인 재채번
--   already_max(brand_id별) + ROW_NUMBER 오프셋 = 새 ext_seq
-- ============================================================
WITH already_ext AS (
  SELECT brand_id,
         MAX(
           CASE WHEN campaign_no ~ '^B\d{4}-C\d{3}$'
                THEN split_part(campaign_no, '-C', 2)::integer
                ELSE 0 END
         ) AS current_max
    FROM public.campaigns
   WHERE brand_id IS NOT NULL
     AND source_application_id IS NULL
     AND campaign_no ~ '^B\d{4}-C\d{3}$'
   GROUP BY brand_id
),
unassigned_ext AS (
  SELECT c.id,
         c.brand_id,
         ROW_NUMBER() OVER (
           PARTITION BY c.brand_id
           ORDER BY c.created_at, c.id
         ) AS offset_seq
    FROM public.campaigns c
   WHERE c.campaign_no ~ '^CAMP-'
     AND c.source_application_id IS NULL
     AND c.brand_id IS NOT NULL
)
UPDATE public.campaigns c
   SET campaign_no =
         'B' || lpad(b.brand_seq::text, 4, '0')
         || '-C' || lpad(
              (COALESCE(ae.current_max, 0) + ue.offset_seq)::text,
              3, '0')
  FROM unassigned_ext ue
  JOIN public.brands  b  ON b.id = ue.brand_id
  LEFT JOIN already_ext ae ON ae.brand_id = ue.brand_id
 WHERE c.id = ue.id;


-- ============================================================
-- STEP P-3: 신청 파생 캠페인 재채번
--   already_max(source_application_id별) + ROW_NUMBER 오프셋
-- ============================================================
WITH already_derived AS (
  SELECT source_application_id,
         MAX(
           CASE WHEN campaign_no ~ '^B\d{4}-A\d{3}-C\d{3}$'
                THEN split_part(campaign_no, '-C', 2)::integer
                ELSE 0 END
         ) AS current_max
    FROM public.campaigns
   WHERE source_application_id IS NOT NULL
     AND campaign_no ~ '^B\d{4}-A\d{3}-C\d{3}$'
   GROUP BY source_application_id
),
unassigned_derived AS (
  SELECT c.id,
         c.source_application_id,
         c.brand_id,
         ROW_NUMBER() OVER (
           PARTITION BY c.source_application_id
           ORDER BY c.created_at, c.id
         ) AS offset_seq
    FROM public.campaigns c
   WHERE c.campaign_no ~ '^CAMP-'
     AND c.source_application_id IS NOT NULL
     AND c.brand_id IS NOT NULL
),
app_info AS (
  SELECT ba.id                                              AS application_id,
         split_part(ba.application_no, '-A', 2)::integer    AS app_seq
    FROM public.brand_applications ba
   WHERE ba.application_no ~ '^B\d{4}-A\d{3}$'
)
UPDATE public.campaigns c
   SET campaign_no =
         'B' || lpad(b.brand_seq::text, 4, '0')
         || '-A' || lpad(ai.app_seq::text, 3, '0')
         || '-C' || lpad(
              (COALESCE(ad.current_max, 0) + ud.offset_seq)::text,
              3, '0')
  FROM unassigned_derived ud
  JOIN public.brands     b  ON b.id = ud.brand_id
  JOIN app_info          ai ON ai.application_id = ud.source_application_id
  LEFT JOIN already_derived ad ON ad.source_application_id = ud.source_application_id
 WHERE c.id = ud.id;


-- ============================================================
-- STEP P-4: 카운터 재동기화 (089 STEP 9 GREATEST 패턴 재실행)
--   재채번 후 다음 INSERT 가 올바른 값을 이어받도록 보장.
-- ============================================================
INSERT INTO public.application_campaign_counter (application_id, last_seq)
SELECT source_application_id, COUNT(*)::integer
  FROM public.campaigns
 WHERE source_application_id IS NOT NULL AND brand_id IS NOT NULL
 GROUP BY source_application_id
    ON CONFLICT (application_id) DO UPDATE
   SET last_seq = GREATEST(
         public.application_campaign_counter.last_seq,
         EXCLUDED.last_seq
       );

INSERT INTO public.brand_external_campaign_counter (brand_id, last_seq)
SELECT brand_id, COUNT(*)::integer
  FROM public.campaigns
 WHERE source_application_id IS NULL AND brand_id IS NOT NULL
 GROUP BY brand_id
    ON CONFLICT (brand_id) DO UPDATE
   SET last_seq = GREATEST(
         public.brand_external_campaign_counter.last_seq,
         EXCLUDED.last_seq
       );


-- ============================================================
-- STEP P-5: numbering_legacy_map UPSERT
--   이번 패치 대상(legacy_no ~ '^CAMP-') 만 매핑
-- ============================================================
INSERT INTO public.numbering_legacy_map
  (entity_type, entity_id, legacy_no, new_no, migrated_at)
SELECT 'campaign', c.id, c.legacy_no, c.campaign_no, now()
  FROM public.campaigns c
 WHERE c.legacy_no IS NOT NULL
   AND c.legacy_no <> c.campaign_no
   AND c.legacy_no ~ '^CAMP-'
    ON CONFLICT (entity_type, entity_id) DO UPDATE
   SET new_no      = EXCLUDED.new_no,
       migrated_at = EXCLUDED.migrated_at;


-- ============================================================
-- STEP P-6: 인라인 검증 — 실패 시 트랜잭션 자동 ROLLBACK
-- ============================================================
DO $$
DECLARE
  v_remaining integer;
  v_dup       integer;
BEGIN
  -- [PV1] brand_id 연결된 캠페인 중 CAMP-format 잔존 0건
  SELECT COUNT(*) INTO v_remaining
    FROM public.campaigns
   WHERE campaign_no ~ '^CAMP-'
     AND brand_id IS NOT NULL;
  IF v_remaining > 0 THEN
    RAISE EXCEPTION '[PATCH-V1] brand_id 연결 캠페인 중 CAMP-format 잔존 % 건 — 롤백', v_remaining;
  END IF;

  -- [PV2] campaign_no UNIQUE 위반 없음
  SELECT COUNT(*) INTO v_dup
    FROM (
      SELECT campaign_no
        FROM public.campaigns
       GROUP BY campaign_no HAVING COUNT(*) > 1
    ) t;
  IF v_dup > 0 THEN
    RAISE EXCEPTION '[PATCH-V2] campaign_no 중복 발생 % 건 — 롤백', v_dup;
  END IF;
END $$;


NOTIFY pgrst, 'reload schema';

COMMIT;


-- ============================================================
-- [POST-CHECK] COMMIT 후 별도 실행 — 완료 확인
-- ============================================================
/*

SELECT
  COUNT(*)                                                                  AS total,
  COUNT(*) FILTER (WHERE campaign_no ~ '^B\d{4}-A\d{3}-C\d{3}$')           AS derived,
  COUNT(*) FILTER (WHERE campaign_no ~ '^B\d{4}-C\d{3}$')                   AS external,
  COUNT(*) FILTER (WHERE campaign_no ~ '^CAMP-' AND brand_id IS NOT NULL)   AS remaining_camp,
  COUNT(*) FILTER (WHERE campaign_no ~ '^CAMP-' AND brand_id IS NULL)       AS legacy_no_brand
  FROM public.campaigns;
-- remaining_camp = 0 이어야 패치 완료

SELECT entity_type, legacy_no, new_no, migrated_at
  FROM public.numbering_legacy_map
 WHERE legacy_no ~ '^CAMP-'
 ORDER BY migrated_at DESC
 LIMIT 50;

*/


-- ============================================================
-- ROLLBACK SQL (COMMIT 후 문제 발견 시 별도 트랜잭션 실행)
-- ============================================================
/*

BEGIN;

LOCK TABLE public.campaigns IN SHARE ROW EXCLUSIVE MODE;

-- 캠페인 번호를 legacy_no(이전 CAMP-format) 로 되돌림 — 이번 패치 대상만
UPDATE public.campaigns
   SET campaign_no = legacy_no
 WHERE legacy_no ~ '^CAMP-'
   AND campaign_no ~ '^B\d{4}-';

-- 매핑 행 제거 — 이번 패치 대상만
DELETE FROM public.numbering_legacy_map
 WHERE entity_type = 'campaign'
   AND legacy_no   ~ '^CAMP-';

-- 카운터는 GREATEST 패턴으로 누적된 값이라 되돌릴 필요 없음
-- (초과된 last_seq 는 신규 INSERT 시 사용된 번호를 자동으로 건너뜀)

COMMIT;

NOTIFY pgrst, 'reload schema';

*/
