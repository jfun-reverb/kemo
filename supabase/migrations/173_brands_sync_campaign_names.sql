-- ============================================================
-- 173: brands 브랜드명 변경 시 연결된 campaigns 자동 동기화 트리거
--
-- 「항상 마스터 최신」 구현 — 마스터(brands)에서 name/name_ja/name_en 을 고치면
-- 연결된 모든 campaigns 의 brand/brand_ja/brand_en 을 즉시 갱신.
-- (인플/관리자는 campaigns 만 읽으므로 brands RLS·민감 컬럼 노출 변화 없음)
--
-- 사양서: docs/specs/2026-06-08-brand-name-i18n.md (B안)
-- 의존: 172 (campaigns.brand_ja/brand_en 컬럼)
-- 롤백:
--   DROP TRIGGER IF EXISTS trg_brands_sync_campaigns ON public.brands;
--   DROP FUNCTION IF EXISTS public.sync_campaign_brand_names();
-- ============================================================

CREATE OR REPLACE FUNCTION public.sync_campaign_brand_names()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- 이름 3종 중 하나라도 바뀌었을 때만 campaigns 갱신 (불필요한 UPDATE 방지)
  IF (NEW.name    IS DISTINCT FROM OLD.name)
  OR (NEW.name_ja IS DISTINCT FROM OLD.name_ja)
  OR (NEW.name_en IS DISTINCT FROM OLD.name_en)
  THEN
    UPDATE public.campaigns
    SET
      brand    = NEW.name,       -- 한국어 (관리자 표시·검색 haystack 기준)
      brand_ja = NEW.name_ja,
      brand_en = NEW.name_en
    WHERE brand_id = NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.sync_campaign_brand_names() IS
  'brands.name / name_ja / name_en 변경 시 연결된 campaigns 행 동기화. AFTER UPDATE 트리거. trg_brand_name_normalized(BEFORE) 이후 발화.';

DROP TRIGGER IF EXISTS trg_brands_sync_campaigns ON public.brands;
CREATE TRIGGER trg_brands_sync_campaigns
  AFTER UPDATE OF name, name_ja, name_en
  ON public.brands
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_campaign_brand_names();

-- 검증 (트리거 등록 확인)
-- SELECT trigger_name, event_manipulation, action_timing
-- FROM information_schema.triggers
-- WHERE event_object_table = 'brands' ORDER BY action_timing, trigger_name;
