-- ============================================================
-- 248_count_pending_review_applications.sql
-- 결과물 관리 사이드바 검수대기 배지 — 신청 단위 + 최신 결과물 기준 집계 함수
-- 사양서: (별도 사양서 없음 — 운영 배지 과대 카운트 버그 수정, 사용자 확정 규칙 기반)
--
-- ── 문제 ──
--   기존 fetchPendingDeliverableCount() 는 deliverables 를 status='pending' 조건으로
--   "행 단위"로 그냥 COUNT 했다. 결과물은 재제출마다 새 행을 INSERT 하고 옛 행은
--   이력 보존을 위해 그대로 남겨두는 설계(CLAUDE.md deliverables 섹션)라서, 이미
--   재제출로 대체된 옛 pending 행까지 중복으로 세어 배지가 과대 표시됐다
--   (운영 관측치: 배지 31, 실제 검수 필요 신청 수는 그보다 훨씬 적음).
--
-- ── 이 함수가 세는 단위 ──
--   "검수해야 할 신청(application) 건수" — 한 신청에 영수증·게시물이 둘 다
--   검수대기여도 1건으로 센다(사용자 확정). 화면(dev/js/admin-deliverables.js
--   buildDeliverableGroups)의 신청 단위 그룹핑과 같은 관점.
--
-- ── "최신 1건" 판정 기준 (buildDeliverableGroups 재현) ──
--   같은 신청 안에서 종류(kind)가 같고 채널(post_channel)이 같은 결과물은
--   재제출 이력이 여러 행으로 쌓여 있을 수 있으므로, (application_id, kind,
--   post_channel) 조합별로 제출시각(submitted_at) 최신 1건만 대표로 본다.
--     - receipt(영수증): post_channel 이 없는 kind라 사실상 신청당 최신 1건
--     - review_image(리뷰어 채널별 인증샷): 채널별로 별도 대표 1건
--     - post(기프팅·방문형 게시물): post_channel 별 최신 1건
--       (화면의 buildDeliverableGroups 는 post 를 채널 구분 없이 "신청 전체
--       최신 1건"으로 대표를 잡지만, 이 함수는 사용자가 지정한 단순 규칙대로
--       (kind, channel) 조합 최신을 그대로 쓴다 — 다채널 기프팅/방문형 신청에서
--       "이미 승인된 채널 A + 방금 재제출한 채널 B" 조합이면 화면은 신청 전체
--       최신 1건 status 만 보므로 실제로는 근소한 차이가 날 수 있다. 정확한
--       computeCertStatus 재현은 이 배지의 목적[대략적 검수 업무량 표시]에는
--       과한 복잡도라 판단해 단순화했다 — 사용자 명시 결정)
--   draft 상태 행은 애초에 제출 완료가 아니므로 최신 판정 대상에서 제외한다.
--
-- ── 반려·취소 신청 제외 ──
--   applications.status IN ('rejected','cancelled') 인 신청은 이미 "검수 불필요"로
--   운영 로직에 반영되어 있으므로(예: 마이그레이션 176 캠페인 종료 자동 낙첨,
--   마이그레이션 247 반려 가드) 이 집계에서도 동일하게 제외한다.
--
-- ── 화면(buildDeliverableGroups)과의 관계 — 드리프트 주의 ──
--   이 함수는 화면의 신청 단위·최신 기준 집계 로직을 "배지 전용"으로 SQL에
--   재현한 것이지, 화면 로직을 호출해서 쓰는 게 아니다(화면은 클라이언트
--   JavaScript). 향후 buildDeliverableGroups 의 최신 판정·제외 조건이
--   바뀌면 이 함수도 함께 검토해야 두 수치가 벌어지지 않는다.
--
-- 권한: is_admin() (super_admin/campaign_admin/campaign_manager 전부 — 결과물
--   관리 페인은 세 등급 모두 접근 가능하므로 is_campaign_admin() 이 아니라
--   is_admin() 이 맞다).
--
-- 적용 순서: 개발 DB 먼저 적용 → 검증 → 운영 DB 적용.
-- ============================================================

CREATE OR REPLACE FUNCTION public.count_pending_review_applications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_count integer;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'permission_denied: 관리자만 호출할 수 있습니다'
      USING ERRCODE = '42501';
  END IF;

  WITH latest AS (
    -- 신청×종류×채널 조합별 최신 1건(제출시각 내림차순, 동률이면 updated_at 내림차순).
    -- post_channel 이 NULL 인 kind(receipt, 채널 미지정 레거시 review_image)는
    -- coalesce('') 로 묶어 하나의 조합으로 취급한다.
    SELECT DISTINCT ON (d.application_id, d.kind, COALESCE(d.post_channel, ''))
      d.application_id,
      d.status
    FROM public.deliverables d
    WHERE d.status <> 'draft'
    ORDER BY
      d.application_id, d.kind, COALESCE(d.post_channel, ''),
      d.submitted_at DESC NULLS LAST,
      d.updated_at DESC
  )
  SELECT COUNT(DISTINCT l.application_id)::integer
  INTO v_count
  FROM latest l
  JOIN public.applications a ON a.id = l.application_id
  WHERE l.status = 'pending'
    AND a.status NOT IN ('rejected', 'cancelled');

  RETURN COALESCE(v_count, 0);
END;
$$;

COMMENT ON FUNCTION public.count_pending_review_applications() IS
  '[248] 결과물 관리 사이드바 검수대기 배지 — 신청(application) 단위로 "검수해야 할 '
  '신청 수"를 센다. 재제출로 쌓인 이력 행은 (application_id, kind, post_channel) 조합별 '
  '최신 1건만 판정 대상(draft 제외). 반려·취소(rejected/cancelled) 신청은 제외. '
  'buildDeliverableGroups(dev/js/admin-deliverables.js) 의 신청 단위 그룹핑을 배지 '
  '전용으로 단순 재현한 것이며 화면 로직을 직접 호출하지 않으므로, 화면의 최신 판정 '
  '조건이 바뀌면 이 함수도 함께 검토할 것(드리프트 주의). is_admin() 가드.';

REVOKE ALL ON FUNCTION public.count_pending_review_applications() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.count_pending_review_applications() TO authenticated;

-- ── 성능 보조 인덱스 ──
-- DISTINCT ON 정렬이 (application_id, kind, post_channel, submitted_at)
-- 순서를 그대로 타도록 복합 인덱스 추가. deliverables 는 이미
-- idx_deliverables_application_id / idx_deliverables_status_kind /
-- idx_deliverables_submitted_at 개별 인덱스가 있지만, 이 함수 전용 정렬
-- 패턴에 맞는 복합 인덱스는 없었다. 현재 데이터 규모(수천 건)에서는 개별
-- 인덱스만으로도 충분히 빠르지만, 사이드바 로드마다 호출되는 함수라
-- 향후 데이터 증가에 대비해 미리 추가한다.
CREATE INDEX IF NOT EXISTS idx_deliverables_app_kind_channel_submitted
  ON public.deliverables (application_id, kind, post_channel, submitted_at DESC);

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 함수 생성 확인
SELECT routine_name, data_type
FROM information_schema.routines
WHERE routine_schema = 'public'
  AND routine_name = 'count_pending_review_applications';

-- [V1] 권한 확인 (authenticated 만 있어야 함, PUBLIC/anon 없어야 함)
SELECT grantee, privilege_type
FROM information_schema.role_routine_grants
WHERE routine_name = 'count_pending_review_applications';

-- [V2] 스모크 호출 — SQL Editor 는 auth.uid() 가 NULL 이라
--   permission_denied(42501) 로 막히는 것이 정상 동작이다. 실제 값 확인은
--   관리자 로그인 세션(앱 또는 서비스 롤 우회)에서 한다:
-- SELECT public.count_pending_review_applications();

-- [V3] 화면 대조용 참고 쿼리 — 함수와 같은 로직을 SELECT 로 직접 풀어서
--   신청별 판정 내역을 눈으로 확인(어떤 신청이 왜 검수대기로 잡혔는지):
-- WITH latest AS (
--   SELECT DISTINCT ON (d.application_id, d.kind, COALESCE(d.post_channel, ''))
--     d.application_id, d.kind, d.post_channel, d.status, d.submitted_at
--   FROM public.deliverables d
--   WHERE d.status <> 'draft'
--   ORDER BY d.application_id, d.kind, COALESCE(d.post_channel, ''),
--            d.submitted_at DESC NULLS LAST, d.updated_at DESC
-- )
-- SELECT a.id, a.status AS app_status, l.kind, l.post_channel, l.status AS latest_status
-- FROM latest l
-- JOIN public.applications a ON a.id = l.application_id
-- WHERE l.status = 'pending' AND a.status NOT IN ('rejected','cancelled')
-- ORDER BY a.id;

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP FUNCTION IF EXISTS public.count_pending_review_applications();
-- DROP INDEX IF EXISTS public.idx_deliverables_app_kind_channel_submitted;
-- (storage.js fetchPendingDeliverableCount() 를 이 마이그레이션 이전 버전
--  — status='pending' 행 단위 COUNT 방식 — 으로 되돌리는 코드 롤백 병행 필요)
