-- ============================================================
-- 156_campaign_status_ended.sql
-- 2026-05-27
--
-- 목적:
--   캠페인 상태에 「종료」(ended) 를 신규 추가한다.
--
-- 배경:
--   현행 closed = 「모집 마감」(deadline 경과, 결과물 제출 진행 중, 인플 화면 노출 유지).
--   결과물 제출 마감(submission_end)까지 경과한 완전 종료 상태를 별도로 구분하기 위해
--   ended 를 추가한다.
--
-- 방식 선택: B안(영향 최소)
--   closed 의미·식별자를 그대로 보존(= 모집마감).
--   ended 신규 추가(= 활동 완전 종료, submission_end 경과).
--   기존 closed 참조 코드(인플 노출·응모차단·클라이언트 자동전이)는 그대로 유지.
--
-- 최종 상태 6개:
--   draft(준비) → scheduled(모집예정) → active(모집중)
--     → closed(모집마감, submission_end까지 노출)
--     → ended(종료, 완전 비활성)
--     expired(노출마감, 수동 OFF)
--
-- 변경 내용:
--   [단계 1] 락 트리거 함수 재정의
--              현행 (마이그레이션 108): OLD.status = 'closed' AND NEW.status = 'closed'
--              변경: OLD.status IN ('closed','ended','expired')
--                    AND NEW.status IN ('closed','ended','expired')
--              → closed/ended/expired 상태의 주의사항·참여방법·NG 수정을 모두 차단
--              (마이그레이션 097 이 extended 했지만 108 이 단일 조건으로 덮어씬 것을 바로잡음)
--   [단계 2] CHECK 제약 갱신 (ended 추가)
--              기존: ('draft','scheduled','active','closed','expired')
--              변경: ('draft','scheduled','active','closed','ended','expired')
--   [단계 3] 기존 closed 캠페인 중 submission_end 가 KST 오늘 날짜 기준 이미 경과한 행을 ended 로 백필
--              대상: status='closed' AND submission_end IS NOT NULL
--                    AND submission_end < (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date
--
-- KST 날짜 판정 근거:
--   submission_end 는 date 타입 (마이그레이션 036).
--   date 컬럼은 시간대 없이 연도·월·일만 저장되므로,
--   "오늘 KST 날짜"와 비교하는 것이 자연스럽다.
--   클라이언트(storage.js) 도 setHours(0,0,0,0) 로 로컬 자정 기준을 쓰고 있어,
--   DB 백필도 KST 자정 기준으로 일관시킨다.
--
-- 주의:
--   ended 상태에서 인플루언서 노출·응모차단·자동전이 로직은 PR 2·3·4 에서 구현.
--   이 마이그레이션은 DB 상태값 추가 + 백필 + 락 트리거 확장만 담당.
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 백필 건수 확인
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행 + 백필 건수 확인
--      ※ 운영 적용 전 대상 건수 사전 확인 권장:
--         SELECT COUNT(*) FROM public.campaigns
--         WHERE status = 'closed'
--           AND submission_end IS NOT NULL
--           AND submission_end < (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date;
--
-- 검증 쿼리 (아래 「개발 DB 적용 + 검증 안내」 섹션 참조)
--
-- 롤백:
--   하단 롤백 주석 참고
-- ============================================================

BEGIN;


-- ============================================================
-- 단계 1: 락 트리거 함수 재정의
--   대상 함수: public.block_closed_campaign_caution_participation_update()
--   최종 정의: 마이그레이션 108 (closed 단일 조건)
--              → ended/expired 도 포함하도록 확장
--   보호 대상 컬럼: caution_set_id / caution_items (마이그레이션 075)
--                   participation_set_id / participation_steps (마이그레이션 075)
--                   ng_set_id / ng_items (마이그레이션 108)
--   차단 조건:
--     OLD.status IN ('closed','ended','expired')
--     AND NEW.status IN ('closed','ended','expired')
--     AND 보호 컬럼 중 하나라도 변경
--   통과 조건 예시:
--     - active → closed 전환 (NEW.status='closed' 이지만 OLD.status='active' 이므로 차단 안 됨)
--     - closed → ended 전환 (상태 전이만, 보호 컬럼 변경 없으면 통과)
-- ============================================================

CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- closed · ended · expired 상태에서 보호 컬럼 변경 시 차단
  -- 상태 전이 자체(예: closed→ended)는 보호 컬럼을 건드리지 않으면 통과
  IF OLD.status IN ('closed', 'ended', 'expired')
     AND NEW.status IN ('closed', 'ended', 'expired')
  THEN
    -- 주의사항 잠금 (마이그레이션 075 기존)
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
    THEN
      RAISE EXCEPTION '모집마감/종료/노출마감 캠페인의 주의사항은 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;

    -- 참여방법 잠금 (마이그레이션 075 기존)
    IF OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '모집마감/종료/노출마감 캠페인의 참여방법은 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;

    -- NG 사항 잠금 (마이그레이션 108 기존)
    IF OLD.ng_set_id IS DISTINCT FROM NEW.ng_set_id
       OR OLD.ng_items::text IS DISTINCT FROM NEW.ng_items::text
    THEN
      RAISE EXCEPTION '모집마감/종료/노출마감 캠페인의 NG 사항은 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.block_closed_campaign_caution_participation_update() IS
  'closed/ended/expired 캠페인의 caution_items/caution_set_id/participation_steps/participation_set_id/ng_items/ng_set_id 변경 차단 (075 정의 → 097 확장 → 108 축소 → 156 재확장)';

-- 트리거 재등록 (함수 교체 후 트리거는 자동 반영되지만 명시적으로 재생성)
DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
CREATE TRIGGER trg_block_closed_caution_participation
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_closed_campaign_caution_participation_update();


-- ============================================================
-- 단계 2: CHECK 제약 갱신 (ended 추가)
--   멱등 처리:
--     이미 ended 포함 제약이 있으면 스킵.
--     그렇지 않으면 기존 status 관련 제약을 찾아 DROP 후 새 제약 ADD.
-- ============================================================

DO $$
DECLARE
  v_conname text;
BEGIN
  -- 재실행 안전성: 이미 ended 포함 CHECK 제약이 있으면 전체 스킵
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.campaigns'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%ended%'
  ) THEN
    RAISE NOTICE '[156] CHECK 제약 이미 최신 (ended 포함) — 스킵';
  ELSE
    -- 기존 status 관련 CHECK 제약 이름 찾기
    SELECT conname INTO v_conname
    FROM pg_constraint
    WHERE conrelid = 'public.campaigns'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
    LIMIT 1;

    IF v_conname IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.campaigns DROP CONSTRAINT %I', v_conname);
      RAISE NOTICE '[156] 기존 status CHECK 제약 삭제: %', v_conname;
    ELSE
      RAISE NOTICE '[156] 기존 status CHECK 제약 없음 — 신규 추가만';
    END IF;

    ALTER TABLE public.campaigns
      ADD CONSTRAINT campaigns_status_check
      CHECK (status IN ('draft', 'scheduled', 'active', 'closed', 'ended', 'expired'));
    RAISE NOTICE '[156] campaigns_status_check 추가 완료 (ended 포함 6종)';
  END IF;
END;
$$;

COMMENT ON COLUMN public.campaigns.status IS
  'draft(준비) / scheduled(모집예정) / active(모집중) / closed(모집마감, submission_end까지 노출) / ended(종료, 활동 완전 종료) / expired(노출마감, 수동 OFF). paused는 migration 097에서 제거됨. ended는 migration 156에서 추가됨.';


-- ============================================================
-- 단계 3: 기존 closed 캠페인 → ended 백필
--   대상: status='closed' AND submission_end IS NOT NULL
--         AND submission_end < (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date
--   근거:
--     submission_end 가 date 타입이므로 KST 당일 날짜(:: date)와 비교.
--     부등호 < 로 「오늘 KST 날짜보다 이전인 날」만 대상 (오늘 마감은 ended 미적용).
--     submission_end IS NOT NULL 조건: 제출 마감일 미설정 캠페인은 ended 판정 불가, 보수적으로 제외.
--   이 UPDATE 는 caution/participation/ng 를 건드리지 않으므로
--   단계 1 의 트리거에 의해 차단되지 않는다
--   (OLD.status='closed', NEW.status='ended' → IN ('closed','ended','expired') 양쪽 해당이지만,
--    보호 컬럼 변경이 없으면 차단 조건 불충족으로 RETURN NEW 통과).
-- ============================================================

UPDATE public.campaigns
SET    status = 'ended'
WHERE  status = 'closed'
  AND  submission_end IS NOT NULL
  AND  submission_end < (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date;

-- 백필 결과 NOTICE (SQL Editor Message 탭에 표시됨)
DO $$
DECLARE
  v_ended_count bigint;
  v_closed_remain bigint;
BEGIN
  SELECT COUNT(*) INTO v_ended_count FROM public.campaigns WHERE status = 'ended';
  SELECT COUNT(*) INTO v_closed_remain FROM public.campaigns WHERE status = 'closed';
  RAISE NOTICE '[156] 백필 완료 — ended 상태 캠페인: %건 / 남은 closed 캠페인: %건',
    v_ended_count, v_closed_remain;
END;
$$;


COMMIT;


-- ============================================================
-- 개발 DB 적용 + 검증 안내
-- ============================================================
--
-- 파일 경로: /Users/younggeunkim/Documents/projects/reverb-jp/supabase/migrations/156_campaign_status_ended.sql
--
-- [사전 확인 쿼리] — 적용 전 대상 건수 확인 (백필 결과 예측용)
--
-- SELECT status, COUNT(*) AS cnt
-- FROM public.campaigns
-- GROUP BY status
-- ORDER BY status;
--
-- SELECT COUNT(*) AS backfill_targets
-- FROM public.campaigns
-- WHERE status = 'closed'
--   AND submission_end IS NOT NULL
--   AND submission_end < (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul')::date;
--
-- ============================================================


-- ============================================================
-- 롤백 (적용 취소 시 아래 블록을 SQL Editor 에서 실행)
-- 주의:
--   ended 로 전환된 캠페인이 있으면 closed 로 되돌린 뒤 제약 교체할 것.
-- ============================================================
/*

BEGIN;

-- [1] ended 행 → closed 원복
UPDATE public.campaigns SET status = 'closed' WHERE status = 'ended';

-- [2] 트리거 함수 원복 (마이그레이션 108 상태로)
CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'closed' AND NEW.status = 'closed' THEN
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
    THEN
      RAISE EXCEPTION '종료된 캠페인은 주의사항을 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
    IF OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '종료된 캠페인은 참여방법을 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
    IF OLD.ng_set_id IS DISTINCT FROM NEW.ng_set_id
       OR OLD.ng_items::text IS DISTINCT FROM NEW.ng_items::text
    THEN
      RAISE EXCEPTION '모집이 종료된 캠페인의 NG 사항은 변경할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
CREATE TRIGGER trg_block_closed_caution_participation
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_closed_campaign_caution_participation_update();

-- [3] CHECK 제약 원복 (ended 제거)
ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_status_check;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_status_check
  CHECK (status IN ('draft', 'scheduled', 'active', 'closed', 'expired'));

COMMIT;

*/
