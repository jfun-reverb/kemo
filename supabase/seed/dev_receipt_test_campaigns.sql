-- ============================================================
-- dev_receipt_test_campaigns.sql
-- 목적 : 인플루언서 영수증 제출 흐름(구매일·주문번호·구매금액) 테스트용
--        리뷰어(recruit_type='monitor') 더미 캠페인 5개 INSERT
--
-- 대상 DB : 개발서버(qysmxtipobomefudyixw) SQL Editor 전용
-- 실행 역할 : SQL Editor = service_role → 행 단위 보안 정책(RLS) 자동 우회
--
-- 채번 트리거 동작 (campaign_no 직접 지정 금지):
--   · brand_id 있음 → B{brand_seq}-C{ext_seq} (외부 캠페인, 분기 B)
--   · brand_id NULL → CAMP-YYYY-NNNN (임시 번호, 분기 C)
--   아래 SQL은 brands 첫 번째 행을 brand_id로 사용.
--   brands 행이 0건이면 brand_id=NULL 경로로 폴백되어 CAMP-YYYY-NNNN 채번.
--
-- 인플루언서 화면 노출 조건:
--   status='active' + deadline 미래 → 즉시 목록에 노출 + 신청 가능
--   min_followers=0 → 팔로워 체크 차단 없음
--
-- ── 실행 전 확인 권장 ──
-- SELECT id, brand_seq, name FROM public.brands ORDER BY brand_seq LIMIT 3;
-- (0건이면 brand_id=NULL로 채번됨 — 동작에는 문제 없음)
-- ============================================================


INSERT INTO public.campaigns (
  title,
  brand,
  brand_ko,
  brand_ja,
  brand_en,
  product,
  product_ko,
  brand_id,
  source_application_id,
  type,
  channel,
  channel_match,
  recruit_type,
  category,
  content_types,
  slots,
  applied_count,
  min_followers,
  recruit_start,
  deadline,
  purchase_start,
  purchase_end,
  submission_end,
  reward,
  reward_note,
  product_price,
  product_url,
  winner_announce,
  description,
  hashtags,
  mentions,
  status,
  order_index
)
VALUES
-- ── 1번: 스킨케어 세럼 (Instagram 피드) ──
(
  '[テスト] 영수증 OCR 더미 1 — セラム',
  '[テスト]REVERB TEST BRAND',
  '[테스트]리버브 테스트 브랜드',
  '[テスト]REVERB TEST BRAND',
  '[TEST]REVERB TEST BRAND',
  'テスト美容液 30ml',
  '테스트 미용액 30ml',
  (SELECT id FROM public.brands ORDER BY brand_seq LIMIT 1),
  NULL,
  'nano',
  'instagram',
  'or',
  'monitor',
  'beauty',
  'インスタ/フィード',
  10, 0, 0,
  CURRENT_DATE - INTERVAL '10 days',
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE - INTERVAL '5 days',
  CURRENT_DATE + INTERVAL '35 days',
  CURRENT_DATE + INTERVAL '60 days',
  0, NULL,
  3000,
  'https://example.com/product/1',
  '選考後、LINEにてご連絡',
  'テスト用キャンペーンです。実際の商品ではありません。',
  '#テスト #beauty',
  '@test_brand',
  'active',
  -100
),
-- ── 2번: 선크림 (Instagram 피드+릴스) ──
(
  '[テスト] 영수증 OCR 더미 2 — 日焼け止め',
  '[テスト]REVERB TEST BRAND',
  '[테스트]리버브 테스트 브랜드',
  '[テスト]REVERB TEST BRAND',
  '[TEST]REVERB TEST BRAND',
  'テスト日焼け止め SPF50+',
  '테스트 선크림 SPF50+',
  (SELECT id FROM public.brands ORDER BY brand_seq LIMIT 1),
  NULL,
  'nano',
  'instagram',
  'or',
  'monitor',
  'beauty',
  'インスタ/フィード,インスタ/リール',
  10, 0, 0,
  CURRENT_DATE - INTERVAL '7 days',
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE - INTERVAL '3 days',
  CURRENT_DATE + INTERVAL '32 days',
  CURRENT_DATE + INTERVAL '60 days',
  0, NULL,
  2500,
  'https://example.com/product/2',
  '選考後、LINEにてご連絡',
  'テスト用キャンペーンです。実際の商品ではありません。',
  '#テスト #日焼け止め',
  '@test_brand',
  'active',
  -101
),
-- ── 3번: 마스크팩 (Instagram 피드) ──
(
  '[テスト] 영수증 OCR 더미 3 — マスクパック',
  '[テスト]REVERB TEST BRAND',
  '[테스트]리버브 테스트 브랜드',
  '[テスト]REVERB TEST BRAND',
  '[TEST]REVERB TEST BRAND',
  'テストマスクパック 10枚入り',
  '테스트 마스크팩 10매',
  (SELECT id FROM public.brands ORDER BY brand_seq LIMIT 1),
  NULL,
  'nano',
  'instagram',
  'or',
  'monitor',
  'beauty',
  'インスタ/フィード',
  10, 0, 0,
  CURRENT_DATE - INTERVAL '5 days',
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE - INTERVAL '2 days',
  CURRENT_DATE + INTERVAL '33 days',
  CURRENT_DATE + INTERVAL '60 days',
  0, NULL,
  1500,
  'https://example.com/product/3',
  '選考後、LINEにてご連絡',
  'テスト用キャンペーンです。実際の商品ではありません。',
  '#テスト #マスクパック',
  '@test_brand',
  'active',
  -102
),
-- ── 4번: 식품 (Qoo10 채널) ──
(
  '[テスト] 영수증 OCR 더미 4 — Qoo10食品',
  '[テスト]REVERB TEST BRAND',
  '[테스트]리버브 테스트 브랜드',
  '[テスト]REVERB TEST BRAND',
  '[TEST]REVERB TEST BRAND',
  'テスト韓国スナック 200g',
  '테스트 한국과자 200g',
  (SELECT id FROM public.brands ORDER BY brand_seq LIMIT 1),
  NULL,
  'qoo10',
  'qoo10',
  'or',
  'monitor',
  'food',
  'Qoo10レビュー',
  10, 0, 0,
  CURRENT_DATE - INTERVAL '3 days',
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE - INTERVAL '1 days',
  CURRENT_DATE + INTERVAL '31 days',
  CURRENT_DATE + INTERVAL '60 days',
  0, NULL,
  800,
  'https://example.com/product/4',
  '選考後、LINEにてご連絡',
  'テスト用キャンペーンです。実際の商品ではありません。',
  '#テスト #韓国スナック',
  '@test_brand',
  'active',
  -103
),
-- ── 5번: 헤어케어 (X 채널) ──
(
  '[テスト] 영수증 OCR 더미 5 — ヘアケア',
  '[テスト]REVERB TEST BRAND',
  '[테스트]리버브 테스트 브랜드',
  '[テスト]REVERB TEST BRAND',
  '[TEST]REVERB TEST BRAND',
  'テストヘアオイル 100ml',
  '테스트 헤어오일 100ml',
  (SELECT id FROM public.brands ORDER BY brand_seq LIMIT 1),
  NULL,
  'nano',
  'x',
  'or',
  'monitor',
  'beauty',
  'X投稿',
  10, 0, 0,
  CURRENT_DATE - INTERVAL '2 days',
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE,
  CURRENT_DATE + INTERVAL '30 days',
  CURRENT_DATE + INTERVAL '60 days',
  0, NULL,
  2000,
  'https://example.com/product/5',
  '選考後、LINEにてご連絡',
  'テスト用キャンペーンです。実際の商品ではありません。',
  '#テスト #ヘアケア',
  '@test_brand',
  'active',
  -104
);


-- ============================================================
-- 실행 후 확인 SQL (주석 해제 후 별도 실행)
-- ============================================================
/*
SELECT
  campaign_no,
  title,
  status,
  recruit_type,
  channel,
  deadline,
  purchase_start,
  purchase_end,
  submission_end,
  slots,
  min_followers
FROM public.campaigns
WHERE title LIKE '[テスト] 영수증 OCR 더미%'
ORDER BY order_index DESC;
*/


-- ============================================================
-- 되돌리기(삭제) SQL (주석 해제 후 별도 실행)
-- 이 캠페인에 연결된 applications, deliverables 등도
-- CASCADE로 함께 삭제됩니다.
-- ============================================================
/*
DELETE FROM public.campaigns
WHERE title LIKE '[テスト] 영수증 OCR 더미%';
*/
