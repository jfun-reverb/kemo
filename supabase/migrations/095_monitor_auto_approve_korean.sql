-- ============================================================
-- 095_monitor_auto_approve_korean.sql
-- purpose  : auto_approve_monitor() 트리거 함수가 applications.reviewed_by에
--            저장하는 값을 일본어 '自動承認' → 한국어 '자동 승인'으로 통일.
--            관리자 페이지 UI 한국어 원칙(.claude/rules/ui.md)에 따른 데이터 일관성 확보.
--
-- 변경 내용:
--   1. auto_approve_monitor() 함수 재정의
--      - NEW.reviewed_by := '自動承認'  →  NEW.reviewed_by := '자동 승인'
--      - 나머지 로직 동일 (status='approved', reviewed_at=now())
--   2. 기존 데이터 일괄 UPDATE
--      - applications.reviewed_by = '自動承認' → '자동 승인'
--      - WHERE 조건이 매번 0건 매칭이면 자동으로 noop (멱등성)
--   3. 클라이언트 formatReviewer() 헬퍼(admin.js:378)는 하위호환을 위해 유지
--      (개발/운영 DB에 095 적용 후 '自動承認' 행이 사라지면 헬퍼는 항상 pass-through)
--
-- 트리거 실행 순서 (BEFORE INSERT, 이름 알파벳순 — 095 적용 후에도 동일):
--   1. trg_monitor_auto_approve (049 정의, 이 파일이 함수만 교체) — status='approved'
--   2. trg_monitor_slots_guard  (048 정의) — 정원 초과 시 INSERT 차단
--
-- 적용 순서:
--   1. 개발서버(qysmxtipobomefudyixw) SQL Editor에서 이 파일 전체 실행
--   2. 개발서버에서 monitor 캠페인 신청 테스트 → reviewed_by = '자동 승인' 확인
--   3. 운영서버(twofagomeizrtkwlhsuv) SQL Editor에서 이 파일 전체 실행
--   4. 운영서버에서 기존 '自動承認' 행이 '자동 승인'으로 변환됐는지 확인:
--      SELECT COUNT(*) FROM public.applications WHERE reviewed_by = '自動承認';
--      -- 결과: 0이어야 정상
--
-- rollback:
--   (하단 주석 참고)
-- ============================================================

BEGIN;

-- ============================================================
-- 1. auto_approve_monitor() 함수 재정의 (한국어 값으로 교체)
-- ============================================================
CREATE OR REPLACE FUNCTION auto_approve_monitor()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_recruit_type text;
BEGIN
  SELECT recruit_type INTO v_recruit_type
    FROM public.campaigns
   WHERE id = NEW.campaign_id;

  IF v_recruit_type = 'monitor' THEN
    NEW.status      := 'approved';
    NEW.reviewed_by := '자동 승인';   -- 변경: '自動承認' → '자동 승인'
    NEW.reviewed_at := now();
  END IF;

  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. 기존 데이터 일괄 UPDATE (멱등성: 매칭 행 없으면 noop)
-- ============================================================
UPDATE public.applications
   SET reviewed_by = '자동 승인'
 WHERE reviewed_by = '自動承認';

COMMIT;

-- ============================================================
-- rollback (필요 시 수동 실행 — BEGIN/COMMIT 제거 후 실행)
-- ============================================================
-- 트리거 함수 원복 (일본어 값으로 되돌리기):
-- CREATE OR REPLACE FUNCTION auto_approve_monitor()
-- RETURNS trigger
-- LANGUAGE plpgsql
-- SECURITY DEFINER
-- SET search_path = ''
-- AS $$
-- DECLARE
--   v_recruit_type text;
-- BEGIN
--   SELECT recruit_type INTO v_recruit_type
--     FROM public.campaigns
--    WHERE id = NEW.campaign_id;
--
--   IF v_recruit_type = 'monitor' THEN
--     NEW.status      := 'approved';
--     NEW.reviewed_by := '自動承認';
--     NEW.reviewed_at := now();
--   END IF;
--
--   RETURN NEW;
-- END;
-- $$;
--
-- 기존 데이터 역방향 UPDATE:
-- UPDATE public.applications
--    SET reviewed_by = '自動承認'
--  WHERE reviewed_by = '자동 승인'
--    AND reviewed_at IS NOT NULL;
-- ※ 주의: 위 역방향 UPDATE는 관리자가 수동으로 '자동 승인'을 입력한 행도
--          '自動承認'으로 되돌릴 수 있음. 운영 rollback 시 영향 범위 확인 필수.
