-- ============================================================
-- 097_campaigns_status_redesign.sql
-- 2026-05-07
--
-- 목적:
--   1. paused 상태 제거 (사용 빈도 낮음, 기존 데이터는 closed로 일괄 변환)
--   2. expired 상태 추가 (한국어 라벨: 「노출마감」)
--      - post_deadline 경과 시 closed → expired 자동 전이 (클라이언트 측 처리)
--      - 인플루언서 화면에서 완전히 숨겨지는 상태 (closed는 post_deadline까지 노출)
--   3. 075 트리거 함수 재정의
--      - 기존: OLD.status = 'closed' AND NEW.status = 'closed' 일 때만 차단
--      - 변경: closed 또는 expired 중 하나라도 포함 시 차단
--
-- 최종 상태 5개:
--   draft(준비) → scheduled(모집예정) → active(모집중) → closed(종료) → expired(노출마감)
--
-- 변경 내용:
--   [단계 1] paused → closed 일괄 변환 (WHERE status='paused', 멱등)
--            * 주의: 075 트리거가 closed 캠페인 caution/participation 수정을 차단하므로
--              트리거 재정의를 단계 1 보다 먼저 실행해야 함.
--              paused → closed UPDATE는 caution/participation을 건드리지 않으므로
--              기존 트리거에서도 차단되지 않음. 하지만 안전을 위해
--              트리거 재정의(단계 3)를 먼저 배치함.
--   [단계 2] CHECK 제약 갱신
--            - 기존: ('draft','scheduled','active','paused','closed')
--            - 변경: ('draft','scheduled','active','closed','expired')
--   [단계 3] 075 트리거 함수 재정의 (SECURITY DEFINER, SET search_path = '')
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor 실행 + 기능 검증
--   2. 운영서버(twofagomeizrtkwlhsuv) SQL Editor 실행
--      ※ 운영 적용 전 paused 건수 확인 권장:
--         SELECT status, COUNT(*) FROM campaigns GROUP BY status ORDER BY status;
--
-- 검증 쿼리 (적용 후 실행):
--   -- [1] 상태별 건수 — paused=0 확인
--   SELECT status, COUNT(*) AS cnt FROM public.campaigns GROUP BY status ORDER BY status;
--
--   -- [2] CHECK 제약 정의 확인
--   SELECT conname, pg_get_constraintdef(oid) AS definition
--   FROM pg_constraint
--   WHERE conrelid = 'public.campaigns'::regclass
--     AND contype = 'c'
--     AND conname LIKE '%status%';
--   -- 기대값: ('draft','scheduled','active','closed','expired') 포함, paused 미포함
--
--   -- [3] 현재 campaigns 테이블의 모든 CHECK 제약 목록 (사전 확인용)
--   SELECT conname FROM pg_constraint WHERE conrelid='public.campaigns'::regclass AND contype='c';
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;


-- ============================================================
-- 단계 1: 075 트리거 함수 재정의
--   실행 순서 이유:
--     paused → closed 변환(단계 2 전) 시 075 트리거가 오작동할 여지 없음
--     (paused UPDATE는 caution/participation을 변경하지 않음).
--     그러나 expired 추가 이후 closed ↔ expired 간 전이에서 트리거가
--     올바르게 작동하도록 먼저 재정의.
--
--   변경점:
--     기존: OLD.status = 'closed' AND NEW.status = 'closed'
--     변경: OLD.status IN ('closed','expired') AND NEW.status IN ('closed','expired')
--           → closed/expired 상태 캠페인의 caution/participation 수정을 모두 차단
--   차단 메시지 갱신:
--     기존: '종료된 캠페인은 주의사항/참여방법을 수정할 수 없습니다'
--     변경: '종료/노출마감 캠페인의 주의사항·참여방법은 수정할 수 없습니다.'
-- ============================================================

CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- closed 또는 expired 상태에서 caution/participation 4개 컬럼 변경 시 차단
  -- (상태 전이 자체 — 예: closed→expired — 는 caution/participation을 건드리지 않으면 통과)
  IF OLD.status IN ('closed', 'expired') AND NEW.status IN ('closed', 'expired') THEN
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
       OR OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '종료/노출마감 캠페인의 주의사항·참여방법은 수정할 수 없습니다 (campaign_id=%)', OLD.id
        USING ERRCODE = 'P0001';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 트리거 재등록 (함수 교체 후 트리거는 자동 반영되지만 명시적으로 재생성)
DROP TRIGGER IF EXISTS trg_block_closed_caution_participation ON public.campaigns;
CREATE TRIGGER trg_block_closed_caution_participation
  BEFORE UPDATE ON public.campaigns
  FOR EACH ROW
  EXECUTE FUNCTION public.block_closed_campaign_caution_participation_update();

COMMENT ON FUNCTION public.block_closed_campaign_caution_participation_update() IS
  'closed/expired 캠페인의 caution_items/caution_set_id/participation_steps/participation_set_id 변경 차단 (migration 075 정의 → 097 재정의)';


-- ============================================================
-- 단계 2: 기존 paused 데이터 → closed 일괄 변환
--   멱등 조건: WHERE status = 'paused' (paused 행이 없으면 0행 UPDATE, 정상)
--   이 UPDATE는 caution/participation을 건드리지 않으므로
--   단계 1의 트리거에 의해 차단되지 않음.
-- ============================================================

UPDATE public.campaigns
SET status = 'closed'
WHERE status = 'paused';

-- 변환 건수 확인용 NOTICE (SQL Editor에서 실행 시 Message 탭에 표시됨)
DO $$
BEGIN
  RAISE NOTICE '[097] paused → closed 변환 완료. 현재 paused 건수: %',
    (SELECT COUNT(*) FROM public.campaigns WHERE status = 'paused');
END;
$$;


-- ============================================================
-- 단계 3: CHECK 제약 갱신
--   기존 제약이 있으면 동적으로 찾아 DROP, 없으면 스킵 (멱등).
--   새 제약은 명시적 이름 campaigns_status_check 으로 추가
--   (이미 동일 이름이 존재하면 ADD는 오류 → DO 블록으로 처리).
--
--   기존 제약명이 자동 이름(campaigns_status_check1 등)일 수 있으므로
--   content ILIKE '%status%' + NOT ILIKE '%expired%' 조건으로 탐색.
-- ============================================================

DO $$
DECLARE
  v_conname text;
BEGIN
  -- 재실행 안전성: 이미 expired 포함 CHECK 제약이 있으면 ADD까지 모두 스킵.
  -- 그렇지 않으면 status 관련 구 제약을 찾아 DROP한 뒤 새 제약을 ADD.
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.campaigns'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%expired%'
  ) THEN
    RAISE NOTICE '[097] CHECK 제약 이미 최신 (expired 포함) — 스킵';
  ELSE
    SELECT conname INTO v_conname
    FROM pg_constraint
    WHERE conrelid = 'public.campaigns'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
    LIMIT 1;

    IF v_conname IS NOT NULL THEN
      EXECUTE format('ALTER TABLE public.campaigns DROP CONSTRAINT %I', v_conname);
      RAISE NOTICE '[097] 기존 status CHECK 제약 삭제: %', v_conname;
    ELSE
      RAISE NOTICE '[097] 기존 status CHECK 제약 없음 — 신규 추가만';
    END IF;

    ALTER TABLE public.campaigns
      ADD CONSTRAINT campaigns_status_check
      CHECK (status IN ('draft', 'scheduled', 'active', 'closed', 'expired'));
    RAISE NOTICE '[097] campaigns_status_check 추가 완료';
  END IF;
END;
$$;

COMMENT ON COLUMN public.campaigns.status IS
  'draft(준비) / scheduled(모집예정) / active(모집중) / closed(종료, post_deadline까지 노출) / expired(노출마감, 완전 비노출). paused는 migration 097에서 제거됨.';


COMMIT;


-- ============================================================
-- 롤백 (적용 취소 시 아래 실행)
-- 주의:
--   - paused로 되돌릴 캠페인 목록을 알 수 없으므로 데이터 원복 불가
--     (운영 적용 전 대상 건수/ID를 반드시 별도 메모)
--   - expired 행이 이미 존재하면 DELETE 후 롤백 필요
-- ============================================================
/*

BEGIN;

-- [1] 트리거 함수 원복 (075 원본)
CREATE OR REPLACE FUNCTION public.block_closed_campaign_caution_participation_update()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'closed' AND NEW.status = 'closed' THEN
    IF OLD.caution_set_id IS DISTINCT FROM NEW.caution_set_id
       OR OLD.caution_items::text IS DISTINCT FROM NEW.caution_items::text
       OR OLD.participation_set_id IS DISTINCT FROM NEW.participation_set_id
       OR COALESCE(OLD.participation_steps::text, '') IS DISTINCT FROM COALESCE(NEW.participation_steps::text, '')
    THEN
      RAISE EXCEPTION '종료된 캠페인은 주의사항/참여방법을 수정할 수 없습니다 (campaign_id=%)', OLD.id
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

-- [2] expired 행 확인 (있으면 처리 후 진행)
SELECT id, title, status FROM public.campaigns WHERE status = 'expired';
-- expired 행을 closed로 되돌리거나 삭제 후 아래 실행

-- [3] CHECK 제약 원복 (paused 복원, expired 제거)
ALTER TABLE public.campaigns DROP CONSTRAINT IF EXISTS campaigns_status_check;
ALTER TABLE public.campaigns
  ADD CONSTRAINT campaigns_status_check
  CHECK (status IN ('draft', 'scheduled', 'active', 'paused', 'closed'));

-- [4] paused 원복은 수동 — 마이그레이션 전 기록한 ID/목록 기준으로 직접 UPDATE
-- UPDATE public.campaigns SET status = 'paused' WHERE id IN ('<uuid1>', '<uuid2>', ...);

COMMIT;

*/
