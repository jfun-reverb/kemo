-- ============================================================
-- 230_settlement_settings_cutoff.sql
-- 정산 과거분 컷오프 PR1 — 1/2 (도입일 설정 싱글톤)
-- 사양서: docs/specs/2026-07-09-settlement-cutoff-past-handling.md §「확정 설계 결정」①②⑧
--
-- 배경(문제, 사양서 §배경):
--   backfill_settlements()(마이그레이션 218)에 시간 컷오프가 없어, 운영 배포 후
--   관리자가 정산 화면을 처음 열면 "과거에 이미 인증 성공한 모든 승인 응모"까지
--   한꺼번에 pending 정산으로 생성된다. 그 중 이미 외부 PayPal로 지급 완료한 건도
--   시스템엔 지급 기록이 없어 pending으로 잡히고, PayPal 미등록 과거 인플에게
--   settlement_paypal_required 알림이 대량 발송되는 부작용이 있다.
--
-- 목적:
--   "정산 도입일(cutoff_at)"을 저장하는 싱글톤 설정 테이블을 만든다.
--   이 값은 이후 마이그레이션 231(backfill_settlements 컷오프 조건)이 참조해
--   "인증 성공일(=마지막 필요 결과물의 reviewed_at) >= cutoff_at" 인 응모만
--   자동 pending 정산 생성 대상으로 삼는다. 컷오프 이전 인증 성공 건은 PR2(과거
--   미등록 조회·수동 처리 RPC — 이번 작업 범위 밖)에서 관리자가 건별/일괄 처리한다.
--
-- 설계 참고(연령 정책 age_policy_settings, 마이그레이션 180 B안과 동일 패턴):
--   A안) 함수 내 상수 — 변경마다 함수 재배포 필요. 채택 안 함.
--   B안) 이 테이블 1행(채택) — UPDATE 1줄로 도입일 변경 가능, 배포 시점에 값 세팅.
--
-- ⚠️ NULL 처리 정책(사양서 §의심 3, 매우 중요):
--   cutoff_at IS NULL 이면 "컷오프 미설정" 상태다. 이 경우 마이그레이션 231의
--   backfill_settlements() 는 **자동 생성 0건**으로 동작한다(안전측 — 값을 세팅하지
--   않은 채 배포되면 과거 전체가 쏟아지는 사고를 원천 차단). 정산 운영 배포 시
--   반드시 이 테이블의 cutoff_at 을 배포 시각(또는 확정 도입일)으로 UPDATE할 것
--   (사양서 §사용자 확인 필요 — 배포일 세팅 vs 특정일 지정은 배포 시점에 확정).
--
-- 권한 게이트(사양서 §확정 설계 결정 ⑦):
--   SELECT: has_permission('settlement.view','read') — 정산 조회 권한과 동일 기준
--     (campaign_manager 는 settlement.view 가 hidden 이라 이 설정값도 볼 수 없음,
--     마이그레이션 220 시드).
--   UPDATE: is_super_admin() — 도입일은 정산 과거분 전체를 좌우하는 스위치라
--     (잘못 세팅하면 과거 폭주 또는 정산 누락) 실수 방지를 위해 최고 관리자 전용으로
--     잠근다(사용자 확정 2026-07-09). age_policy_settings(마이그레이션 180)의
--     UPDATE is_super_admin() 선례와 일관. 값 세팅은 배포 시 1회(SQL Editor)면 충분.
--
-- updated_at/updated_by 는 트리거로 서버가 채운다(클라이언트 입력 신뢰 안 함) —
--   settlements 테이블의 touch_settlements_updated_at 컨벤션과 동일.
--
-- 롤백: 파일 하단 참고.
-- ============================================================

-- ============================================================
-- 1. settlement_settings 테이블 (싱글톤, id=1 고정)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.settlement_settings (
  id          integer     PRIMARY KEY DEFAULT 1
                            CONSTRAINT settlement_settings_singleton CHECK (id = 1),
  cutoff_at   timestamptz NULL,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  uuid        NULL REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.settlement_settings IS
  '[230] 정산 도입일(컷오프) 싱글톤 설정. id=1 고정 1행. '
  'backfill_settlements()(마이그레이션 231)가 cutoff_at 을 참조해 '
  '"인증 성공일 >= cutoff_at" 인 응모만 자동 pending 정산 생성. '
  'cutoff_at IS NULL = 미설정(자동 생성 0건, 안전측). 과거분은 PR2 수동 처리 대상.';
COMMENT ON COLUMN public.settlement_settings.cutoff_at IS
  '정산 도입일(UTC 저장, timestamptz). 이 시각 이후 인증 성공한 응모만 자동 백필 대상. '
  'NULL 이면 자동 백필 전체 차단(폭주 방지). 정산 운영 배포 시 반드시 값 세팅.';

-- 초기 1행 INSERT (cutoff_at = NULL → 자동 백필 비활성. 배포 시 UPDATE 필수)
INSERT INTO public.settlement_settings (id, cutoff_at)
VALUES (1, NULL)
ON CONFLICT (id) DO NOTHING;

-- ── updated_at/updated_by 자동 기록 트리거 (settlements 컨벤션과 동일) ──
CREATE OR REPLACE FUNCTION public.touch_settlement_settings()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at := now();
  NEW.updated_by := auth.uid();
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.touch_settlement_settings() IS
  '[230] settlement_settings.updated_at/updated_by 자동 기록 트리거 함수. '
  '클라이언트가 보낸 updated_by 값은 무시하고 항상 auth.uid() 로 덮어씀(감사 신뢰성).';

REVOKE ALL ON FUNCTION public.touch_settlement_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.touch_settlement_settings() TO PUBLIC;

DROP TRIGGER IF EXISTS trg_settlement_settings_touch ON public.settlement_settings;
CREATE TRIGGER trg_settlement_settings_touch
  BEFORE UPDATE ON public.settlement_settings
  FOR EACH ROW
  EXECUTE FUNCTION public.touch_settlement_settings();

-- ============================================================
-- 2. settlement_settings RLS
-- ============================================================
ALTER TABLE public.settlement_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS settlement_settings_select ON public.settlement_settings;
CREATE POLICY settlement_settings_select ON public.settlement_settings
  FOR SELECT TO authenticated
  USING (public.has_permission('settlement.view', 'read'));

DROP POLICY IF EXISTS settlement_settings_update ON public.settlement_settings;
CREATE POLICY settlement_settings_update ON public.settlement_settings
  FOR UPDATE TO authenticated
  USING (public.is_super_admin())
  WITH CHECK (public.is_super_admin());

-- INSERT/DELETE: 정책 없음(허용 안 함) — 싱글톤이라 이 마이그레이션의 초기 INSERT 1회 외
-- 행 추가·삭제 경로 자체를 열어두지 않는다(PK CHECK id=1 과 이중 방어).

NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 SQL (개발 DB 적용 후 SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 테이블·컬럼 생성 확인
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'settlement_settings'
ORDER BY ordinal_position;

-- [V1] 초기 1행 확인 (cutoff_at = NULL 이어야 함)
SELECT id, cutoff_at, updated_at, updated_by FROM public.settlement_settings;

-- [V2] RLS 정책 확인
SELECT policyname, cmd FROM pg_policies
WHERE tablename = 'settlement_settings' ORDER BY policyname;

-- [V3] 트리거 확인
SELECT trigger_name, event_manipulation FROM information_schema.triggers
WHERE event_object_table = 'settlement_settings';

*/

-- ============================================================
-- 롤백
-- ============================================================
-- DROP TRIGGER IF EXISTS trg_settlement_settings_touch ON public.settlement_settings;
-- DROP FUNCTION IF EXISTS public.touch_settlement_settings();
-- DROP POLICY IF EXISTS settlement_settings_select ON public.settlement_settings;
-- DROP POLICY IF EXISTS settlement_settings_update ON public.settlement_settings;
-- DROP TABLE IF EXISTS public.settlement_settings;
