-- ============================================
-- participation_sets 테이블 — 참여방법 번들 관리
-- 작성일: 2026-04-15
-- ============================================
-- 롤백 방법:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS participation_steps;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS participation_set_id;
--   DROP TABLE IF EXISTS public.participation_sets CASCADE;
--   DROP FUNCTION IF EXISTS public.touch_participation_sets_updated_at();
-- ============================================

-- 1) 테이블 생성
CREATE TABLE IF NOT EXISTS public.participation_sets (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ko        text        NOT NULL,
  name_ja        text        NOT NULL,
  recruit_types  text[]      NOT NULL DEFAULT '{}',
  steps          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  sort_order     integer     NOT NULL DEFAULT 0,
  active         boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.participation_sets                IS '참여방법 번들. 캠페인 등록 시 선택하면 steps 스냅샷이 campaigns.participation_steps에 복사된다.';
COMMENT ON COLUMN public.participation_sets.recruit_types  IS 'monitor | gifting | visit 복수 가능. 빈 배열이면 전 타입 공통.';
COMMENT ON COLUMN public.participation_sets.steps          IS '배열 원소: {title_ko, title_ja, desc_ko, desc_ja}. 1~6개 상한은 앱 레벨 소프트 제약.';
COMMENT ON COLUMN public.participation_sets.active         IS 'false면 관리 화면에서 숨김(soft delete). 기존 캠페인 스냅샷에는 영향 없음.';

-- 2) 인덱스 + 유니크 제약 (seed 재실행 멱등성 확보)
CREATE INDEX IF NOT EXISTS idx_participation_sets_active_sort
  ON public.participation_sets (active, sort_order);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_participation_sets_name_ko'
  ) THEN
    ALTER TABLE public.participation_sets
      ADD CONSTRAINT uq_participation_sets_name_ko UNIQUE (name_ko);
  END IF;
END $$;

-- 3) updated_at 자동 갱신 트리거 함수
CREATE OR REPLACE FUNCTION public.touch_participation_sets_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_participation_sets_updated_at ON public.participation_sets;
CREATE TRIGGER trg_participation_sets_updated_at
  BEFORE UPDATE ON public.participation_sets
  FOR EACH ROW EXECUTE FUNCTION public.touch_participation_sets_updated_at();

-- 4) RLS 활성화
ALTER TABLE public.participation_sets ENABLE ROW LEVEL SECURITY;

-- SELECT: 관리자만 (인플루언서는 campaigns.participation_steps 스냅샷으로만 접근)
CREATE POLICY "participation_sets_select_admin" ON public.participation_sets
  FOR SELECT TO authenticated
  USING (public.is_admin());

-- INSERT: campaign_admin 이상
CREATE POLICY "participation_sets_insert_campaign_admin" ON public.participation_sets
  FOR INSERT TO authenticated
  WITH CHECK (public.is_campaign_admin());

-- UPDATE: campaign_admin 이상
CREATE POLICY "participation_sets_update_campaign_admin" ON public.participation_sets
  FOR UPDATE TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

-- DELETE (hard): campaign_admin 이상. 운영 중 삭제는 active=false(soft) 권장.
CREATE POLICY "participation_sets_delete_campaign_admin" ON public.participation_sets
  FOR DELETE TO authenticated
  USING (public.is_campaign_admin());

-- 5) campaigns 테이블 컬럼 추가
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS participation_set_id uuid
    REFERENCES public.participation_sets (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS participation_steps  jsonb NULL;

COMMENT ON COLUMN public.campaigns.participation_set_id IS '선택한 번들 원본 참조. 번들 삭제 시 SET NULL.';
COMMENT ON COLUMN public.campaigns.participation_steps  IS '저장 시점의 steps 스냅샷 (jsonb). 번들 수정 후에도 기존 캠페인은 영향 없음.';
