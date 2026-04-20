-- ============================================
-- 개발서버(staging) 전용: deliverables 플로우 검증용 테스트 캠페인 3종
--   1. monitor (리뷰어) — 구매기간 + 제출마감
--   2. gifting (기프팅) — 제출마감만
--   3. visit   (방문형) — 방문기간 + 제출마감
-- 주의: 운영서버 실행 금지.
-- 선행: 036_add_campaign_deadlines 적용 완료 후 실행 (Stage 1)
--
-- 롤백:
--   DELETE FROM campaigns WHERE brand LIKE '[TEST]%';
-- ============================================

INSERT INTO campaigns (
  title, brand, product, type, recruit_type, channel, channel_match, category, emoji,
  image_url, img1, product_price, reward, slots, applied_count,
  deadline, post_deadline, purchase_start, purchase_end, visit_start, visit_end, submission_end,
  content_types, description, hashtags, mentions,
  appeal, guide, ng, status, min_followers, order_index, created_at
)
VALUES
-- ── 1. monitor (리뷰어) ──
(
  '[TEST] モニター用テストキャンペーン', '[TEST] TestBrand A', 'テスト商品 A (モニター)',
  'monitor', 'monitor', 'instagram', 'or', 'beauty', '🧪',
  'https://placehold.co/600x600?text=monitor',
  'https://placehold.co/600x600?text=monitor',
  3200, 0, 20, 0,
  current_date + 14,           -- deadline (모집마감)
  current_date + 45,           -- post_deadline (게시마감)
  current_date + 1,            -- purchase_start
  current_date + 21,           -- purchase_end
  NULL, NULL,                  -- visit_start/end (해당 없음)
  current_date + 40,           -- submission_end
  'インスタ/フィード',
  'deliverables 테스트용 모니터(리뷰어) 캠페인입니다.',
  '#test #monitor', '@test_brand',
  'テスト用アピールポイント。', 'テスト用撮影ガイド。', 'テスト用NG事項。',
  'active', 0, 900, now()
),

-- ── 2. gifting (기프팅) ──
(
  '[TEST] ギフティング用テストキャンペーン', '[TEST] TestBrand B', 'テスト商品 B (ギフティング)',
  'gifting', 'gifting', 'instagram', 'or', 'beauty', '🎁',
  'https://placehold.co/600x600?text=gifting',
  'https://placehold.co/600x600?text=gifting',
  0, 0, 15, 0,
  current_date + 14,
  current_date + 45,
  NULL, NULL, NULL, NULL,
  current_date + 40,           -- submission_end (제출마감만)
  'インスタ/フィード',
  'deliverables 테스트용 기프팅 캠페인입니다.',
  '#test #gifting', '@test_brand',
  'テスト用アピールポイント。', 'テスト用撮影ガイド。', 'テスト用NG事項。',
  'active', 0, 901, now()
),

-- ── 3. visit (방문형) ──
(
  '[TEST] 訪問型テストキャンペーン', '[TEST] TestBrand C', 'テスト店舗訪問',
  'visit', 'visit', 'instagram', 'or', 'food', '📍',
  'https://placehold.co/600x600?text=visit',
  'https://placehold.co/600x600?text=visit',
  0, 0, 10, 0,
  current_date + 14,
  current_date + 45,
  NULL, NULL,
  current_date + 7,            -- visit_start
  current_date + 35,           -- visit_end
  current_date + 40,
  'インスタ/フィード',
  'deliverables 테스트용 방문형 캠페인입니다.',
  '#test #visit', '@test_brand',
  'テスト用アピールポイント。', 'テスト用撮影ガイド。', 'テスト用NG事項。',
  'active', 0, 902, now()
)
ON CONFLICT DO NOTHING;

-- 결과 확인
SELECT id, title, type, status, purchase_start, visit_start, submission_end
  FROM campaigns
 WHERE brand LIKE '[TEST]%'
 ORDER BY type;
