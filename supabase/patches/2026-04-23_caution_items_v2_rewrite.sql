-- ============================================================
-- 2026-04-23_caution_items_v2_rewrite.sql
-- 목적:
--   migration 069 초기 버전으로 이미 DB 에 들어간 구 구조 items
--   ({text_ko, text_ja, link_url, link_label_*, text_after_*}) 를
--   현 버전 v2 구조 ({html_ko, html_ja}) 로 덮어쓰기.
--
-- 배경:
--   파일 069 를 in-place 로 v2 구조로 재작성했으나, ON CONFLICT
--   DO NOTHING 때문에 기본 번들이 덮어써지지 않고, 캠페인 전수
--   백필도 구 구조 그대로 들어가 있는 상태.
--
-- 실행 대상:
--   DB 에 migration 069 초기 버전을 한 번 적용한 환경 (개발 DB)
--
-- 영향:
--   - caution_sets '기본 주의사항' 번들의 items 를 v2 html 구조로 교체
--   - 아직 관리자 커스터마이즈 하지 않은 (첫 항목이 html_ko 키를 갖지
--     않는) campaigns.caution_items 를 v2 기본 번들 items 로 덮어쓰기
--
-- 안전 규칙:
--   - 이미 v2 구조로 저장된 번들/캠페인은 건드리지 않음 (멱등)
--   - 관리자가 이미 v2 로 편집한 캠페인도 보존
-- ============================================================

BEGIN;

-- Step 1: 기본 번들 seed items 를 v2 html 구조로 재작성
UPDATE public.caution_sets
SET items = '[
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
]'::jsonb
WHERE name_ko = '기본 주의사항';

-- Step 2: 관리자 커스터마이즈 전인 캠페인들에 v2 items 스냅샷 덮어쓰기
--   판별 조건: 첫 항목에 html_ko 키가 없으면 v1 구조로 간주
WITH def AS (
  SELECT items FROM public.caution_sets WHERE name_ko = '기본 주의사항' LIMIT 1
)
UPDATE public.campaigns c
SET caution_items = def.items
FROM def
WHERE jsonb_array_length(c.caution_items) > 0
  AND NOT (c.caution_items -> 0 ? 'html_ko');

COMMIT;

-- ============================================================
-- 검증 (실행 후):
--   SELECT jsonb_pretty(items) FROM caution_sets WHERE name_ko='기본 주의사항';
--   -- html_ko / html_ja 구조여야 함
--
--   SELECT count(*) FROM campaigns
--     WHERE jsonb_array_length(caution_items) > 0
--       AND NOT (caution_items -> 0 ? 'html_ko');
--   -- 0 이어야 함 (남은 v1 없음)
-- ============================================================
