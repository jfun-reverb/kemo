-- ============================================
-- lookup_values 테이블 — 캠페인 기준 데이터 통합 관리
-- 채널 / 카테고리 / 콘텐츠 종류 / NG 사항 프리셋
-- ============================================

CREATE TABLE IF NOT EXISTS lookup_values (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind         text NOT NULL CHECK (kind IN ('channel','category','content_type','ng_item')),
  code         text NOT NULL,
  name_ko      text NOT NULL,
  name_ja      text NOT NULL,
  sort_order   integer NOT NULL DEFAULT 0,
  active       boolean NOT NULL DEFAULT true,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (kind, code)
);

CREATE INDEX IF NOT EXISTS idx_lookup_kind_active_sort
  ON lookup_values (kind, active, sort_order);

COMMENT ON TABLE lookup_values IS '캠페인 기준 데이터 통합 (채널/카테고리/콘텐츠/NG 프리셋). kind 컬럼으로 종류 구분';
COMMENT ON COLUMN lookup_values.kind IS 'channel | category | content_type | ng_item';
COMMENT ON COLUMN lookup_values.code IS '영문 식별자 (캠페인 DB의 channel/category 컬럼 값과 일치)';
COMMENT ON COLUMN lookup_values.active IS 'false면 신규 등록 폼에서 숨김. 기존 캠페인 데이터는 영향 없음';

-- updated_at 자동 갱신
CREATE OR REPLACE FUNCTION public.touch_lookup_values_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS trg_lookup_values_updated_at ON lookup_values;
CREATE TRIGGER trg_lookup_values_updated_at
  BEFORE UPDATE ON lookup_values
  FOR EACH ROW EXECUTE FUNCTION public.touch_lookup_values_updated_at();

-- ============================================
-- 권한 함수: campaign_admin 또는 super_admin
-- ============================================
CREATE OR REPLACE FUNCTION public.is_campaign_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM admins
    WHERE auth_id = auth.uid()
      AND role IN ('super_admin','campaign_admin')
  );
$$;

-- ============================================
-- RLS
-- ============================================
ALTER TABLE lookup_values ENABLE ROW LEVEL SECURITY;

-- SELECT: 모든 인증 사용자 (캠페인 등록 폼에서 조회 필요)
CREATE POLICY "lookup_select_all" ON lookup_values
  FOR SELECT TO authenticated USING (true);

-- 익명도 SELECT 허용 (인플루언서 비로그인 상태에서도 채널 라벨 등 표시)
CREATE POLICY "lookup_select_anon" ON lookup_values
  FOR SELECT TO anon USING (active = true);

-- INSERT/UPDATE/DELETE: campaign_admin 이상만
CREATE POLICY "lookup_insert_campaign_admin" ON lookup_values
  FOR INSERT TO authenticated WITH CHECK (is_campaign_admin());

CREATE POLICY "lookup_update_campaign_admin" ON lookup_values
  FOR UPDATE TO authenticated
  USING (is_campaign_admin())
  WITH CHECK (is_campaign_admin());

CREATE POLICY "lookup_delete_campaign_admin" ON lookup_values
  FOR DELETE TO authenticated USING (is_campaign_admin());

-- ============================================
-- 시드 데이터 — 기존 하드코딩 값 모두 이관
-- ============================================

-- 채널
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order) VALUES
  ('channel', 'instagram', 'Instagram',  'Instagram',  10),
  ('channel', 'x',         'X(Twitter)', 'X(Twitter)', 20),
  ('channel', 'qoo10',     'Qoo10',      'Qoo10',      30),
  ('channel', 'tiktok',    'TikTok',     'TikTok',     40),
  ('channel', 'youtube',   'YouTube',    'YouTube',    50)
ON CONFLICT (kind, code) DO NOTHING;

-- 카테고리
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order) VALUES
  ('category', 'beauty',  '뷰티/코스메',   'ビューティ',     10),
  ('category', 'food',    '푸드/그르메',   'フード',         20),
  ('category', 'fashion', '패션/라이프',   'ファッション',   30),
  ('category', 'health',  '헬스/웰니스',   'ヘルスケア',     40),
  ('category', 'other',   '기타',          'その他',         50)
ON CONFLICT (kind, code) DO NOTHING;

-- 콘텐츠 종류 (캠페인 DB는 일본어 라벨을 그대로 저장 중이므로 code = 일본어로 통일)
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order) VALUES
  ('content_type', 'feed',   '피드',     'フィード',     10),
  ('content_type', 'reels',  '릴스',     'リール',       20),
  ('content_type', 'story',  '스토리',   'ストーリー',   30),
  ('content_type', 'short',  '쇼츠',     'ショート動画', 40),
  ('content_type', 'video',  '동영상',   '動画',         50),
  ('content_type', 'image',  '이미지',   '画像',         60)
ON CONFLICT (kind, code) DO NOTHING;

-- NG 사항 프리셋 (기존 신규 캠페인 폼의 기본값 6줄)
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order) VALUES
  ('ng_item', 'competitor_brand',
    '경쟁사 기업명·상품명·상품 노출 금지',
    '競合他社の企業名・商品名・商品の露出 NG', 10),
  ('ng_item', 'dark_lighting',
    '어두운 장소에서 촬영해 상품이 잘 보이지 않는 사진 금지',
    '暗い場所での撮影により商品が見えにくいもの NG', 20),
  ('ng_item', 'logo_reverse',
    '로고가 뒤집힌 사진 금지',
    'ロゴが逆向きになっているもの NG', 30),
  ('ng_item', 'unclear_brand',
    '브랜드명·상품명·패키지·상품의 색감이 잘 보이지 않는 사진 금지',
    'ブランド名・商品名・パッケージ・商品の発色が見えにくいもの NG', 40),
  ('ng_item', 'negative',
    '본 상품/서비스에 대한 부정적인 표현 금지',
    '本商品／サービスに対するネガティブな表現 NG', 50),
  ('ng_item', 'swatch_only',
    '상품을 실제로 사용하지 않고 스와치 게시물만 등록 금지',
    '商品を実際に使用せずスウォッチ投稿のみ NG', 60)
ON CONFLICT (kind, code) DO NOTHING;
