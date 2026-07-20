-- ============================================================
-- 240_settlement_influencer_visibility_lock.sql
-- 정산(settlements) 인플루언서 공개 잠금 스위치 도입
--
-- 배경(목적):
--   정산 기능은 이미 has_permission('settlement.view'/'settlement.pay') 시드
--   (마이그레이션 220·221, campaign_manager=hidden)와 settlement_settings.cutoff_at
--   NULL(마이그레이션 230, 자동 백필 0건)로 "관리자 화면 노출·자동 생성"은 잠겨 있다.
--   그러나 이 상태에서도 관리자가 backfill_settlements()/mark_settlement_paid() 를
--   수동 호출하면 인플루언서에게 settlement_paid·settlement_paypal_required 알림이
--   나가고, 인플루언서 본인은 마이페이지에서 자신의 정산 행을 조회할 수 있다
--   (settlements_select_own RLS, 마이그레이션 217). "관리자만 기록하는 단계"로
--   완전히 잠그려면 이 세 경로(알림 2종 + 본인 조회)를 별도 스위치로 막아야 한다.
--
-- 설계 결정:
--   [D1] 스위치 위치: 기존 싱글톤 settlement_settings(230)에 컬럼 추가
--        — 별도 테이블을 새로 만들지 않고 "정산 운영 설정"을 한 곳에 모은다.
--   [D2] 함수 패턴: is_brand_survey_open()(마이그레이션 206 §4.5)을 그대로 미러링.
--        LANGUAGE sql SECURITY DEFINER SET search_path='' STABLE, COALESCE(...,false)
--        로 fail-closed. 단, 206과 달리 **anon GRANT 는 하지 않는다** — 정산은
--        비로그인 사용자가 알 필요가 없는 로그인 전용 기능이라 authenticated 로만
--        노출 범위를 최소화한다.
--   [D3] settlements_select_own(217) 정책을 DROP 후 조건 추가 재생성.
--        settlements_select_admin(관리자, has_permission 기반) 정책은 이 마이그레이션이
--        건드리지 않는다 — 관리자는 스위치 상태와 무관하게 항상 조회 가능해야
--        "관리자만 기록"이 성립한다.
--   [D4] 알림 차단은 마이그레이션 241(mark_settlement_paid)·242(backfill_settlements)
--        에서 각 함수의 notifications INSERT 부분만 조건화한다. settlement_events
--        감사 이력은 스위치와 무관하게 항상 남는다(이 마이그레이션 영향 없음).
--
-- 기본값: influencer_visible = false (잠금 — 사용자 확정 사항 ⑤)
--
-- 나중에 공개할 때 실행할 SQL (관리자 대시보드 대신 SQL Editor 직접 실행):
--   UPDATE public.settlement_settings SET influencer_visible = true WHERE id = 1;
--   (공개 후 되돌리려면 false 로 다시 UPDATE — 코드 재배포 불필요)
--
-- 롤백: 파일 하단 참고.
-- 작성일: 2026-07-20
-- ============================================================

-- ============================================================
-- 1. settlement_settings 컬럼 추가
-- ============================================================
ALTER TABLE public.settlement_settings
  ADD COLUMN IF NOT EXISTS influencer_visible boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.settlement_settings.influencer_visible IS
  '[240] true = 인플루언서에게 정산 관련 알림 발송 + 본인 정산 내역 조회 허용. '
  'false(기본, 잠금) = settlement_paid/settlement_paypal_required 알림 미발송, '
  'settlements_select_own RLS 도 차단(본인이라도 조회 불가). '
  '공개 전환은 이 컬럼 UPDATE 한 줄로 코드 재배포 없이 가능 '
  '(UPDATE public.settlement_settings SET influencer_visible = true WHERE id = 1).';

-- ============================================================
-- 2. is_settlement_public() — 인플루언서 공개 여부 조회 함수
--    is_brand_survey_open()(마이그레이션 206 §4.5) 패턴 그대로 미러링.
--    SECURITY DEFINER로 RLS 우회 — settlement_settings SELECT 정책은
--    has_permission('settlement.view','read') 라서 일반 인플루언서는
--    이 테이블을 직접 읽을 권한이 없다(정책 존재 자체가 이 함수 필요 이유).
--    anon GRANT 는 하지 않는다(로그인 전용 기능이라 비로그인 사용자에게 불필요 —
--    206의 is_brand_survey_open과 다른 점).
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_settlement_public()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT COALESCE(
    (SELECT influencer_visible FROM public.settlement_settings WHERE id = 1),
    false
  );
$$;

COMMENT ON FUNCTION public.is_settlement_public() IS
  '[240] 정산(settlements) 인플루언서 공개 여부(boolean) 조회. '
  'settlements_select_own RLS + mark_settlement_paid(241)/backfill_settlements(242)의 '
  '알림 발송 조건에 사용. fail-closed(설정 행 없거나 NULL이면 false). '
  'authenticated 전용(anon 미부여) — 로그인 전용 기능.';

REVOKE ALL ON FUNCTION public.is_settlement_public() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_settlement_public() TO authenticated;

-- ============================================================
-- 3. settlements_select_own RLS 정책 교체 (217 원본에 스위치 조건 추가)
--    settlements_select_admin(관리자, has_permission 기반)은 무변경 —
--    관리자는 스위치 상태와 무관하게 항상 조회 가능.
-- ============================================================
DROP POLICY IF EXISTS settlements_select_own ON public.settlements;
CREATE POLICY settlements_select_own ON public.settlements
  FOR SELECT TO authenticated
  USING (influencer_id = auth.uid() AND public.is_settlement_public());

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 컬럼 추가 확인 (influencer_visible, NOT NULL, DEFAULT false)
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'settlement_settings'
  AND column_name = 'influencer_visible';

-- [V1] 초기값 확인 — false 이어야 함
SELECT id, cutoff_at, influencer_visible FROM public.settlement_settings;

-- [V2] 함수 fail-closed 확인 (SQL Editor는 auth.uid() NULL — SECURITY DEFINER라 오류 없이 값만 반환)
SELECT public.is_settlement_public();
-- 기대: false

-- [V3] RLS 정책 교체 확인
SELECT policyname, cmd, qual
FROM pg_policies
WHERE tablename = 'settlements' AND policyname = 'settlements_select_own';
-- qual 에 is_settlement_public() 문자열 포함 확인

-- [V4] 관리자 조회 정책 무변경 확인 (settlements_select_admin 그대로인지)
SELECT policyname, cmd, qual
FROM pg_policies
WHERE tablename = 'settlements' AND policyname = 'settlements_select_admin';

*/

-- ============================================================
-- 롤백
-- ============================================================
/*

-- 원래(217) 정책으로 되돌리기 (스위치 조건 제거)
DROP POLICY IF EXISTS settlements_select_own ON public.settlements;
CREATE POLICY settlements_select_own ON public.settlements
  FOR SELECT TO authenticated
  USING (influencer_id = auth.uid());

DROP FUNCTION IF EXISTS public.is_settlement_public();

ALTER TABLE public.settlement_settings
  DROP COLUMN IF EXISTS influencer_visible;

NOTIFY pgrst, 'reload schema';

*/
