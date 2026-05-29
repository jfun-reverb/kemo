-- =============================================================================
-- 패치: 단일채널 캠페인 review_image post_channel 백필
-- 작성일: 2026-05-29
-- 대상 서버: 운영 (도쿄 nrwtujmlbktxjgdwlpjj)
-- 목적:
--   마이그레이션 158 배포(채널별 분리) 이전에 제출된 kind='review_image' 행의
--   post_channel이 NULL이어서 관리자 검수 화면(reviewByChannel 매칭)에서 누락됨.
--   단일채널 캠페인(channel 컬럼에 콤마 없음) 367건 대상 중 340건 백필.
--   미백필 27건 = skip 19(이미 같은 채널 신버전 존재) + 잔존 8(한 신청 중복 오래된 행).
--   [운영 적용 완료 2026-05-29: UPDATE 340행, 단일채널 NULL 잔존 27 검증]
--
-- 이번 대상 아닌 것:
--   다채널 캠페인(channel에 콤마 포함) 28건 — 별도 단계에서 처리.
--
-- 유니크 인덱스 (마이그레이션 158):
--   deliverables_review_image_app_channel_uniq ON (application_id, post_channel)
--   WHERE kind = 'review_image' AND post_channel IS NOT NULL
--   → NULL 행은 인덱스 범위 밖이었으나, 백필 후 범위 안에 들어옴.
--   → 같은 application_id에 NULL review_image 2건이 있으면 동일 채널로 백필 시 충돌.
--
-- 실행 순서: 1 → 2 → 3 → (3b 조건부) → 4 → 5
--   각 단계 결과 확인 후 다음 단계 진행.
--   3단계에서 충돌 후보 발견 시 3b 처리 후 4단계 실행.
--
-- 롤백:
--   UPDATE public.deliverables
--   SET post_channel = NULL
--   WHERE kind = 'review_image'
--     AND post_channel IS NOT NULL
--     AND id IN (
--       SELECT d.id FROM public.deliverables d
--       JOIN public.applications a ON a.id = d.application_id
--       JOIN public.campaigns c ON c.id = a.campaign_id
--       WHERE d.kind = 'review_image'
--         AND d.post_channel IS NOT NULL
--         AND c.channel NOT LIKE '%,%'
--         AND d.updated_at >= '2026-05-29'  -- 실제 백필 실행 시각으로 교체
--     );
-- =============================================================================


-- =============================================================================
-- 1단계: 백필 대상 전체 건수 및 분포 확인 (읽기 전용)
--
-- 기대값:
--   - 단일채널 캠페인의 NULL review_image 총합이 약 367건
--   - status별 분포: approved≈256, pending≈104, rejected≈7
-- =============================================================================
SELECT
  c.channel                                  AS campaign_channel,
  d.status,
  COUNT(*)                                   AS null_review_image_count,
  COUNT(DISTINCT a.id)                       AS application_count,
  COUNT(DISTINCT c.id)                       AS campaign_count
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel NOT LIKE '%,%'     -- 단일채널만
  AND c.channel IS NOT NULL
  AND c.channel <> ''
GROUP BY c.channel, d.status
ORDER BY d.status, null_review_image_count DESC;


-- =============================================================================
-- 2단계: 실제 백필 시 어떻게 채워질지 미리보기 SELECT (읽기 전용, 실행 금지 아님)
--
-- 기대값: 367행 반환. proposed_channel이 비어있는 행 없는지 확인.
-- =============================================================================
SELECT
  d.id                AS deliverable_id,
  d.application_id,
  d.status,
  d.submitted_at,
  c.channel           AS proposed_channel
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel NOT LIKE '%,%'
  AND c.channel IS NOT NULL
  AND c.channel <> ''
ORDER BY d.application_id, d.submitted_at;


-- =============================================================================
-- 3단계: 유니크 충돌 후보 조회 — 같은 application_id에 NULL review_image 2건+
--        (백필 시 같은 채널 코드 2개가 되어 유니크 인덱스 위반 가능)
--
-- 결과가 0건이면 → 4단계로 바로 진행.
-- 결과가 1건 이상이면 → 3b단계 처리 후 4단계 진행.
-- =============================================================================
SELECT
  d.application_id,
  c.channel           AS proposed_channel,
  COUNT(*)            AS dup_count,
  ARRAY_AGG(d.id ORDER BY d.submitted_at DESC) AS deliverable_ids,
  ARRAY_AGG(d.status ORDER BY d.submitted_at DESC) AS statuses,
  ARRAY_AGG(d.submitted_at ORDER BY d.submitted_at DESC) AS submitted_ats
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel NOT LIKE '%,%'
  AND c.channel IS NOT NULL
  AND c.channel <> ''
GROUP BY d.application_id, c.channel
HAVING COUNT(*) >= 2
ORDER BY d.application_id;


-- =============================================================================
-- 3b단계: 충돌 후보 처리 (3단계에서 1건 이상 나온 경우에만 실행)
--
-- 정책: 같은 application_id에 NULL review_image 2건+ 중
--   - 가장 최근 submitted_at(또는 id DESC) 1건 → post_channel 채움 (백필 대상 유지)
--   - 나머지 오래된 행 → post_channel을 '__legacy_dup__' 또는 고유 접미사로 보존?
--     → 아니면 삭제? 아니면 NULL 유지(인덱스 범위 밖이라 검수 계속 누락)?
--
-- ※ 이 단계는 사용자 확인 후 방법 결정:
--
-- [옵션 A] 오래된 중복 행을 NULL 그대로 유지 (검수 화면에서 계속 누락, 하지만 DB 안전)
--   → 추가 SQL 없음. 4단계 UPDATE를 최신 1건에만 적용하도록 수정 실행.
--
-- [옵션 B] 오래된 중복 행을 삭제 (운영 데이터 삭제 — 신중)
--   → 아래 DELETE 실행 (TRANSACTION 안에서 확인 후 COMMIT/ROLLBACK 권장):
--
-- BEGIN;
-- DELETE FROM public.deliverables
-- WHERE id IN (
--   SELECT DISTINCT ON (d.application_id, c.channel) d.id
--   FROM public.deliverables d
--   JOIN public.applications a ON a.id = d.application_id
--   JOIN public.campaigns c ON c.id = a.campaign_id
--   WHERE d.kind = 'review_image'
--     AND d.post_channel IS NULL
--     AND c.channel NOT LIKE '%,%'
--     AND c.channel IS NOT NULL
--     AND c.channel <> ''
--     AND d.application_id IN (
--       /* 3단계에서 나온 application_id 목록을 여기에 붙여넣기 */
--     )
--   ORDER BY d.application_id, c.channel, d.submitted_at ASC  -- 오래된 것 먼저
-- );
-- SELECT COUNT(*) AS deleted_count;  -- 삭제 확인
-- ROLLBACK;  -- 확인 후 COMMIT으로 교체
-- =============================================================================


-- =============================================================================
-- 4단계: 실제 백필 UPDATE — BEGIN/COMMIT으로 감싸서 결과 확인 후 커밋
--
-- 3단계 결과가 0건이면 그대로 실행.
-- 3단계에서 충돌 후보가 나왔고 3b(옵션 A)를 선택했다면,
--   아래 UPDATE에 충돌 후보 application_id를 EXCEPT 조건으로 추가하거나
--   대신 아래 주석 처리된 "최신 1건만 UPDATE" 버전을 사용.
--
-- 기대값: 약 367건 (충돌 후보 건수만큼 차감될 수 있음)
-- =============================================================================
BEGIN;

UPDATE public.deliverables d
SET post_channel = c.channel
FROM public.applications a
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.application_id = a.id
  AND d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel NOT LIKE '%,%'
  AND c.channel IS NOT NULL
  AND c.channel <> '';

-- 변경 건수 확인 (COMMIT 전에 반드시 확인)
SELECT COUNT(*) AS updated_rows
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NOT NULL
  AND d.post_channel = c.channel
  AND c.channel NOT LIKE '%,%'
  AND d.updated_at >= NOW() - INTERVAL '1 minute';

-- 결과 확인 후:
-- 기대 건수면 → COMMIT; 실행
-- 예상과 다르면 → ROLLBACK; 실행 후 원인 파악
ROLLBACK;  -- 처음엔 ROLLBACK 유지, 확인 후 COMMIT으로 교체


-- =============================================================================
-- 4b단계: 옵션 A — 신청별 최신 1건만 백필 (2026-05-29 실제 실행 버전)
--   4단계(전체 UPDATE)는 충돌 때문에 미사용.
--   충돌 유형 2가지를 모두 회피:
--     (A) 한 신청에 NULL review_image 2건+ → DISTINCT ON (application_id, channel)
--         + ORDER BY submitted_at DESC 로 신청당 최신 1건만 선택 (오래된 중복 8행 NULL 유지).
--     (B) 한 신청에 NULL 1건 + 이미 같은 채널로 채워진(신 코드 재제출) NOT NULL 1건+
--         → NOT EXISTS 로 제외 (19행 skip — 화면엔 신버전이 이미 보이므로 무방).
--   ※ UPDATE ... FROM 의 FROM 절 JOIN 은 대상 테이블 d 참조 불가 →
--     서브쿼리가 channel 까지 반환하고 SET 에서 latest.channel 사용.
--   실측: 백필 340행. 미백필 = skip(B) 19 + 잔존(A 오래된) 8 = 27행 NULL 유지. (340+19+8=367)
-- =============================================================================
UPDATE public.deliverables d
SET post_channel = latest.channel
FROM (
  SELECT DISTINCT ON (d2.application_id, c2.channel)
         d2.id      AS deliverable_id,
         c2.channel AS channel
  FROM public.deliverables d2
  JOIN public.applications a2 ON a2.id = d2.application_id
  JOIN public.campaigns c2 ON c2.id = a2.campaign_id
  WHERE d2.kind = 'review_image'
    AND d2.post_channel IS NULL
    AND c2.channel NOT LIKE '%,%'
    AND c2.channel IS NOT NULL
    AND c2.channel <> ''
    AND NOT EXISTS (
      SELECT 1 FROM public.deliverables d3
      WHERE d3.application_id = d2.application_id
        AND d3.kind = 'review_image'
        AND d3.post_channel = c2.channel
    )
  ORDER BY d2.application_id, c2.channel, d2.submitted_at DESC
) latest
WHERE d.id = latest.deliverable_id
  AND d.kind = 'review_image'
  AND d.post_channel IS NULL;
-- 기대: UPDATE 340


-- =============================================================================
-- 5단계: 백필 완료 검증 (4단계 COMMIT 후 실행)
--
-- 기대값:
--   - remaining_null_single_channel: 0 (3b 옵션 A 선택 시는 충돌 후보 수)
--   - backfilled_count: 약 367건
--   - status별 approved/pending/rejected 분포 기존과 동일
--   - 유니크 인덱스 위반 없음 (쿼리 자체가 성공이면 충돌 없음)
-- =============================================================================

-- 5-1: 단일채널 NULL 잔존 여부
SELECT
  COUNT(*) AS remaining_null_single_channel
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel NOT LIKE '%,%'
  AND c.channel IS NOT NULL
  AND c.channel <> '';

-- 5-2: 백필된 행 status별 분포
SELECT
  d.status,
  COUNT(*) AS backfilled_count
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NOT NULL
  AND d.post_channel = c.channel
  AND c.channel NOT LIKE '%,%'
GROUP BY d.status
ORDER BY d.status;

-- 5-3: 유니크 인덱스 존재 확인 (인덱스가 살아있어야 백필이 안전하게 적용된 것)
SELECT indexname, indexdef
FROM pg_indexes
WHERE indexname = 'deliverables_review_image_app_channel_uniq';

-- 5-4: 다채널 캠페인 NULL 잔존 현황 (이번 대상 아님 — 다음 단계 확인용)
SELECT
  COUNT(*) AS remaining_null_multichannel
FROM public.deliverables d
JOIN public.applications a ON a.id = d.application_id
JOIN public.campaigns c ON c.id = a.campaign_id
WHERE d.kind = 'review_image'
  AND d.post_channel IS NULL
  AND c.channel LIKE '%,%';
