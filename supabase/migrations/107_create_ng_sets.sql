-- ============================================================
-- 107_create_ng_sets.sql
-- NG 사항 번들 관리 — caution_sets 패턴 완전 미러링
-- 작성일: 2026-05-12
-- ============================================================
-- 배경:
--   기존 campaigns.ng (Quill HTML 자유 입력) + lookup_values(kind='ng_item') 6건 방식은
--   캠페인 간 일관성이 없고 번들 단위 재사용이 불가했다.
--
--   이 마이그레이션은 주의사항(caution_sets, migration 069)과 동일한 패턴으로
--   NG 사항 번들을 구성한다:
--     - ng_sets 신규 테이블 (번들 정의)
--     - campaigns.ng_set_id + campaigns.ng_items 컬럼 추가
--     - 캠페인 저장 시 번들 items 스냅샷 복사 → 번들 수정과 기존 캠페인 격리
--     - 기존 campaigns.ng (legacy) 컬럼은 유지 (1주 관찰 후 NG-PR-F에서 DROP 검토)
--
--   백필: 하지 않음. 모든 캠페인 ng_items='[]'로 시작.
--   인플루언서 화면: ng_items 비어있으면 legacy campaigns.ng 폴백 (PR-B에서 처리).
--
-- 영향 테이블:
--   ng_sets              — 신규 (번들 테이블)
--   campaigns            — ng_set_id, ng_items 컬럼 추가
--   lookup_values        — kind='ng_item' 6건 비활성
--
-- 행 단위 보안 정책(RLS):
--   ng_sets SELECT: 관리자 전용 (is_admin())
--   인플루언서는 campaigns.ng_items 스냅샷 경유 (campaigns SELECT 공개)
--
-- items jsonb 구조:
--   { html_ko, html_ja }
--   언어별 HTML 조각. DOMPurify sanitize 보장 (저장+렌더 이중).
--   허용 태그: b, strong, i, em, u, s, strike, a[href]
--
-- 롤백:
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS ng_items;
--   ALTER TABLE public.campaigns DROP COLUMN IF EXISTS ng_set_id;
--   DROP TABLE IF EXISTS public.ng_sets CASCADE;
--   DROP FUNCTION IF EXISTS public.touch_ng_sets_updated_at();
--   UPDATE public.lookup_values SET active = true, updated_at = now() WHERE kind = 'ng_item';
-- ============================================================

BEGIN;

-- ============================================================
-- Step 1: ng_sets 테이블
-- ============================================================
CREATE TABLE IF NOT EXISTS public.ng_sets (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name_ko        text        NOT NULL,
  name_ja        text        NOT NULL,
  recruit_types  text[]      NOT NULL DEFAULT '{}',
  items          jsonb       NOT NULL DEFAULT '[]'::jsonb,
  sort_order     integer     NOT NULL DEFAULT 0,
  active         boolean     NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid        REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid        REFERENCES auth.users(id) ON DELETE SET NULL
);

COMMENT ON TABLE  public.ng_sets                IS 'NG 사항 번들. 캠페인 등록 시 선택하면 items 스냅샷이 campaigns.ng_items 에 복사된다. caution_sets 패턴 미러링.';
COMMENT ON COLUMN public.ng_sets.recruit_types  IS 'monitor | gifting | visit 복수 가능. 빈 배열이면 전 타입 공통.';
COMMENT ON COLUMN public.ng_sets.items          IS '배열 원소: {html_ko, html_ja}. 언어별 HTML 조각 (inline 서식만, DOMPurify sanitize 보장). 항목 수 상한은 앱 레벨 소프트 제약.';
COMMENT ON COLUMN public.ng_sets.active         IS 'false면 관리 화면에서 숨김(soft delete). 기존 캠페인 스냅샷에는 영향 없음.';

CREATE INDEX IF NOT EXISTS ng_sets_active_sort_idx
  ON public.ng_sets (active, sort_order);

-- name_ko 중복 방지 (ON CONFLICT DO NOTHING 시드 안전망)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_ng_sets_name_ko'
  ) THEN
    ALTER TABLE public.ng_sets
      ADD CONSTRAINT uq_ng_sets_name_ko UNIQUE (name_ko);
  END IF;
END $$;

-- updated_at 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public.touch_ng_sets_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;

COMMENT ON FUNCTION public.touch_ng_sets_updated_at() IS
  'ng_sets.updated_at 자동 갱신 트리거 함수 (migration 107)';

DROP TRIGGER IF EXISTS trg_ng_sets_updated_at ON public.ng_sets;
CREATE TRIGGER trg_ng_sets_updated_at
  BEFORE UPDATE ON public.ng_sets
  FOR EACH ROW EXECUTE FUNCTION public.touch_ng_sets_updated_at();

-- ============================================================
-- Step 2: 행 단위 보안 정책(RLS) — caution_sets 와 동일 정책
-- ============================================================
ALTER TABLE public.ng_sets ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "ng_sets_select_admin"            ON public.ng_sets;
DROP POLICY IF EXISTS "ng_sets_insert_campaign_admin"   ON public.ng_sets;
DROP POLICY IF EXISTS "ng_sets_update_campaign_admin"   ON public.ng_sets;
DROP POLICY IF EXISTS "ng_sets_delete_campaign_admin"   ON public.ng_sets;

-- anon 접근 차단 — ng_sets는 관리자 전용. 인플루언서는 campaigns.ng_items 스냅샷 경유.
CREATE POLICY "ng_sets_select_admin" ON public.ng_sets
  FOR SELECT TO authenticated
  USING (public.is_admin());

CREATE POLICY "ng_sets_insert_campaign_admin" ON public.ng_sets
  FOR INSERT TO authenticated
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "ng_sets_update_campaign_admin" ON public.ng_sets
  FOR UPDATE TO authenticated
  USING (public.is_campaign_admin())
  WITH CHECK (public.is_campaign_admin());

CREATE POLICY "ng_sets_delete_campaign_admin" ON public.ng_sets
  FOR DELETE TO authenticated
  USING (public.is_campaign_admin());

-- ============================================================
-- Step 3: campaigns 컬럼 추가
--   legacy campaigns.ng 컬럼은 유지 (NG-PR-F에서 1주 관찰 후 DROP 검토)
-- ============================================================
ALTER TABLE public.campaigns
  ADD COLUMN IF NOT EXISTS ng_set_id uuid
    REFERENCES public.ng_sets(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ng_items  jsonb NOT NULL DEFAULT '[]'::jsonb;

COMMENT ON COLUMN public.campaigns.ng_set_id IS '선택한 NG 번들 원본 참조. 번들 삭제 시 SET NULL. 스냅샷은 ng_items 에 별도 보존.';
COMMENT ON COLUMN public.campaigns.ng_items  IS '저장 시점의 번들 items 스냅샷 (jsonb). 번들 수정 후에도 기존 캠페인은 영향 없음. 인플루언서 상세 페이지에서 소스.';
COMMENT ON COLUMN public.campaigns.ng        IS 'DEPRECATED (2026-05-12). 신규 ng_items jsonb로 전환. 1주 관찰 후 별도 마이그레이션으로 DROP 검토.';

-- ============================================================
-- Step 4: 「기본 NG 묶음」 시드 1건 — 기존 ng_item 6건 흡수
-- ============================================================
INSERT INTO public.ng_sets (name_ko, name_ja, recruit_types, items, sort_order, active)
VALUES (
  '기본 NG 묶음',
  '基本NGリスト',
  '{}',  -- 전 타입 공통 (빈 배열 = 모든 모집 타입 호환)
  jsonb_build_array(
    jsonb_build_object('html_ko', '경쟁 브랜드 동시 노출 금지',          'html_ja', '競合ブランドの同時露出禁止'),
    jsonb_build_object('html_ko', '어두운 조명·낮은 화질로 촬영 금지',  'html_ja', '暗い照明や低画質での撮影禁止'),
    jsonb_build_object('html_ko', '브랜드 로고 좌우 반전 금지',           'html_ja', 'ブランドロゴの左右反転禁止'),
    jsonb_build_object('html_ko', '브랜드명이 식별되지 않는 컷 금지',     'html_ja', 'ブランド名が確認できないカット禁止'),
    jsonb_build_object('html_ko', '부정적·비방 표현 금지',               'html_ja', 'ネガティブ・批判的な表現禁止'),
    jsonb_build_object('html_ko', '스와치(컬러칩)만 노출하는 컷 금지',    'html_ja', 'スウォッチ(カラーチップ)のみのカット禁止')
  ),
  10,
  true
)
ON CONFLICT (name_ko) DO NOTHING;  -- 멱등 재실행 안전망

-- ============================================================
-- Step 5: 기존 lookup_values(kind='ng_item') 비활성 처리
--   행은 hard delete 하지 않고 active=false만 — 향후 회귀 시 복원 가능
--   향후 별도 마이그레이션에서 정식 DELETE 검토
-- ============================================================
UPDATE public.lookup_values
   SET active     = false,
       updated_at = now()
 WHERE kind = 'ng_item';

-- ============================================================
-- 검증 쿼리 (수동 실행 후 확인):
--   SELECT count(*) FROM public.ng_sets WHERE active = true;           -- 1 (기본 NG 묶음)
--   SELECT jsonb_array_length(items) FROM public.ng_sets WHERE name_ko = '기본 NG 묶음';  -- 6
--   SELECT count(*) FROM public.lookup_values WHERE kind = 'ng_item' AND active = true; -- 0
--   SELECT count(*) FROM public.campaigns WHERE ng_items != '[]'::jsonb;               -- 0 (백필 안 함)
-- ============================================================

COMMIT;
