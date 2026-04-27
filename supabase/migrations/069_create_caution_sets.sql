-- ============================================================
-- 069_create_caution_sets.sql
-- 주의사항(caution) 번들 관리 — participation_sets 패턴 미러링
-- 작성일: 2026-04-23
-- ============================================================
-- 배경:
--   migration 067에서 lookup_values(kind='caution') + campaigns.caution_lookup_codes(참조)
--   구조로 주의사항을 구현했으나, 원래 설계 의도인 "참여방법처럼 번들 단위
--   관리 + 캠페인 저장 시점 스냅샷 복사" 를 충족하지 못했다.
--
--   이 마이그레이션은 참여방법(participation_sets)과 동일한 패턴으로
--   주의사항을 재구성한다. 기존 067 컬럼은 **DROP 하지 않고 유지**
--   (점진 전환). 후속 마이그레이션(070 예정)에서 1주 관찰 후 DROP.
--
-- 영향 테이블:
--   caution_sets          — 신규 (번들 테이블)
--   campaigns             — caution_set_id, caution_items 컬럼 추가
--   campaigns             — 전수 백필 (기본 번들 7 items 복사)
--   (067 컬럼 유지): caution_lookup_codes, caution_custom_html
--   (067 RLS 유지): lookup_values kind='caution' 시드 5건
--
-- RLS:
--   caution_sets SELECT: 관리자 전용 (참여방법과 동일)
--   인플루언서는 campaigns.caution_items 스냅샷으로만 접근 (캠페인 공개 SELECT)
--
-- items jsonb 구조:
--   { html_ko, html_ja }
--   각 언어별 HTML 조각 1개. 관리자 UI 의 미니 에디터(bold/italic/underline/
--   strike/link 5종)로 입력받고 DOMPurify 로 sanitize 해 저장·렌더.
--   허용 태그: b, strong, i, em, u, s, strike, a[href]
--
-- 롤백:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS caution_items;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS caution_set_id;
--   DROP TABLE IF EXISTS public.caution_sets CASCADE;
--   DROP FUNCTION IF EXISTS public.touch_caution_sets_updated_at();
-- ============================================================

BEGIN;

-- ============================================================
-- Step 1: caution_sets 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.caution_sets (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ko        text        NOT NULL,
  name_ja        text        NOT NULL,
  recruit_types  text[]      NOT NULL DEFAULT '{}',
  items          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  sort_order     integer     NOT NULL DEFAULT 0,
  active         boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.caution_sets                IS '주의사항 번들. 캠페인 등록 시 선택하면 items 스냅샷이 campaigns.caution_items 에 복사된다. participation_sets 패턴.';
COMMENT ON COLUMN public.caution_sets.recruit_types  IS 'monitor | gifting | visit 복수 가능. 빈 배열이면 전 타입 공통.';
COMMENT ON COLUMN public.caution_sets.items          IS '배열 원소: {html_ko, html_ja}. 언어별 HTML 조각 (inline 서식만, DOMPurify sanitize 보장). 항목 수 상한은 앱 레벨 소프트 제약.';
COMMENT ON COLUMN public.caution_sets.active         IS 'false면 관리 화면에서 숨김(soft delete). 기존 캠페인 스냅샷에는 영향 없음.';

CREATE INDEX IF NOT EXISTS idx_caution_sets_active_sort
  ON public.caution_sets (active, sort_order);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_caution_sets_name_ko'
  ) THEN
    ALTER TABLE public.caution_sets
      ADD CONSTRAINT uq_caution_sets_name_ko UNIQUE (name_ko);
  END IF;
END $$;

-- updated_at 자동 갱신
CREATE OR REPLACE FUNCTION public.touch_caution_sets_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_caution_sets_updated_at ON public.caution_sets;
CREATE TRIGGER trg_caution_sets_updated_at
  BEFORE UPDATE ON public.caution_sets
  FOR EACH ROW EXECUTE FUNCTION public.touch_caution_sets_updated_at();

-- ============================================================
-- Step 2: RLS (participation_sets 와 동일 정책)
-- ============================================================
ALTER TABLE public.caution_sets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "caution_sets_select_admin"            ON public.caution_sets;
DROP POLICY IF EXISTS "caution_sets_insert_campaign_admin"   ON public.caution_sets;
DROP POLICY IF EXISTS "caution_sets_update_campaign_admin"   ON public.caution_sets;
DROP POLICY IF EXISTS "caution_sets_delete_campaign_admin"   ON public.caution_sets;

CREATE POLICY "caution_sets_select_admin" ON public.caution_sets
  FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY "caution_sets_insert_campaign_admin" ON public.caution_sets
  FOR INSERT TO authenticated
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "caution_sets_update_campaign_admin" ON public.caution_sets
  FOR UPDATE TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "caution_sets_delete_campaign_admin" ON public.caution_sets
  FOR DELETE TO authenticated
  USING (public.is_campaign_admin());

-- ============================================================
-- Step 3: campaigns 컬럼 추가 (067 컬럼은 유지 — 점진 전환)
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS caution_set_id uuid
    REFERENCES public.caution_sets (id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS caution_items jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.campaigns.caution_set_id IS '선택한 주의사항 번들 원본 참조. 번들 삭제 시 SET NULL. 스냅샷은 caution_items 에 별도 보존.';
COMMENT ON COLUMN public.campaigns.caution_items  IS '저장 시점의 번들 items 스냅샷 (jsonb). 번들 수정 후에도 기존 캠페인은 영향 없음. 인플루언서 상세 페이지/신청 모달 동일 소스.';

-- ============================================================
-- Step 4: 기본 번들 seed — 7개 기본 주의사항
-- ============================================================
INSERT INTO public.caution_sets (name_ko, name_ja, recruit_types, items, sort_order, active)
VALUES (
  '기본 주의사항',
  'デフォルト注意事項',
  '{}',  -- 전 타입 공통
  '[
    {
      "html_ko": "기한 내 대응이 어려우신 분은 신청을 삼가해주세요.",
      "html_ja": "期限内での対応が難しい方は、申請をご遠慮いただくようお願いいたします。"
    },
    {
      "html_ko": "게시가 기한 내에 이루어지지 않으면 원고료 지급이 불가합니다.",
      "html_ja": "投稿が期限内に行われない場合、原稿料のお支払いはできません。"
    },
    {
      "html_ko": "가이드라인을 준수하여 작성하고, 미준수 시 수정을 요청드립니다.",
      "html_ja": "ガイドラインを遵守したうえで作成し、遵守されていない場合は修正をお願いします。"
    },
    {
      "html_ko": "게시된 리뷰는 브랜드 마케팅 목적으로 활용될 수 있습니다.",
      "html_ja": "掲載されたレビューはブランドのマーケティング目的で活用される場合があります。"
    },
    {
      "html_ko": "게시물은 6개월 이상 유지가 필수입니다.",
      "html_ja": "投稿は6ヶ月以上の掲載が必須です。"
    },
    {
      "html_ko": "비선정자에게는 별도 연락을 드리지 않습니다.",
      "html_ja": "当選されなかった方への個別のご連絡は実施しておりません。"
    },
    {
      "html_ko": "문의사항은 <a href=\"https://line.me/R/ti/p/@reverb.jp\" target=\"_blank\" rel=\"noopener noreferrer\">LINE(@reverb.jp)</a> 으로.",
      "html_ja": "ご不明点は <a href=\"https://line.me/R/ti/p/@reverb.jp\" target=\"_blank\" rel=\"noopener noreferrer\">LINE(@reverb.jp)</a> まで。"
    }
  ]'::jsonb,
  0,
  true
)
ON CONFLICT (name_ko) DO NOTHING;

-- ============================================================
-- Step 5: 기존 캠페인 전수 백필
--   caution_items 가 비어 있는 모든 campaigns 에 기본 번들 스냅샷 복사
--   (DEFAULT '[]'::jsonb 로 NOT NULL 보장했으므로 caution_items = '[]' 조건으로 안전 판별)
--
--   의도적 전수 덮어쓰기: caution_lookup_codes/caution_custom_html (067 컬럼)가
--   이미 설정된 캠페인도 caution_items = '[]' 상태이므로 기본 번들로 초기화됨.
--   점진 전환 기간 중 caution_items 는 기본값으로 통일하고,
--   UI 전환 후 각 캠페인에서 재편집하는 방식을 채택.
--   (단, caution_lookup_codes 사용 중인 캠페인만 선별 처리하려면
--    WHERE 절에 AND caution_lookup_codes = '{}' 조건 추가 필요)
-- ============================================================
WITH def AS (
  SELECT id, items FROM public.caution_sets WHERE name_ko = '기본 주의사항' LIMIT 1
)
UPDATE public.campaigns c
SET
  caution_set_id = def.id,
  caution_items  = def.items
FROM def
WHERE c.caution_items = '[]'::jsonb;

-- ============================================================
-- 검증 쿼리 (수동 실행 후 확인):
--   SELECT count(*) FROM public.campaigns
--     WHERE jsonb_array_length(caution_items) > 0;  -- 전체 건수와 일치해야 함
--   SELECT count(*) FROM public.campaigns
--     WHERE caution_set_id IS NULL;                  -- 기존 캠페인은 0이어야 함
-- ============================================================

COMMIT;
