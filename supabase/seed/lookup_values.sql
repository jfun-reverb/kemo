-- ============================================
-- lookup_values 초기 시드
-- 추출 시점: 2026-04-14 (production 기준)
-- 용도: 신규 환경(staging/production) 초기 데이터 투입
-- 재실행: (kind, code) 기준 UPSERT - 안전
-- ============================================

INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, active, recruit_types) VALUES
  -- category
  ('category', 'beauty',           '뷰티/코스메',                                  'ビューティ',                            10, true, '{}'),
  ('category', 'food',             '푸드/그르메',                                  'フード',                               20, true, '{}'),
  ('category', 'fashion',          '패션/라이프',                                  'ファッション',                          30, true, '{}'),
  ('category', 'health',           '헬스/웰니스',                                  'ヘルスケア',                            40, true, '{}'),
  ('category', 'other',            '기타',                                        'その他',                                50, true, '{}'),

  -- channel (recruit_types 사용)
  ('channel',  'instagram',        'Instagram',                                  'Instagram',                            10, true, '{gifting,visit}'),
  ('channel',  'x',                'X(Twitter)',                                 'X(Twitter)',                           20, true, '{gifting,visit}'),
  ('channel',  'tiktok',           'TikTok',                                     'TikTok',                               30, true, '{gifting,visit}'),
  ('channel',  'youtube',          'YouTube',                                    'YouTube',                              40, true, '{gifting,visit}'),
  ('channel',  'qoo10',            'Qoo10',                                      'Qoo10',                                50, true, '{monitor}'),
  ('channel',  'channel-96r9y3',   '엣코스메',                                     '@Cosme',                               60, true, '{monitor}'),

  -- content_type
  ('content_type', 'feed',         '피드',                                        'フィード',                              10, true, '{}'),
  ('content_type', 'reels',        '릴스',                                        'リール',                                20, true, '{}'),
  ('content_type', 'story',        '스토리',                                      'ストーリー',                            30, true, '{}'),
  ('content_type', 'short',        '쇼츠',                                        'ショート動画',                          40, true, '{}'),
  ('content_type', 'video',        '동영상',                                      '動画',                                  50, true, '{}'),
  ('content_type', 'image',        '이미지',                                      '画像',                                  60, true, '{}'),

  -- ng_item
  ('ng_item', 'competitor_brand',  '경쟁사 기업명·상품명·상품 노출 금지',                      '競合他社の企業名・商品名・商品の露出 NG',           10, true, '{}'),
  ('ng_item', 'dark_lighting',     '어두운 장소에서 촬영해 상품이 잘 보이지 않는 사진 금지',           '暗い場所での撮影により商品が見えにくいもの NG',       20, true, '{}'),
  ('ng_item', 'logo_reverse',      '로고가 뒤집힌 사진 금지',                               'ロゴが逆向きになっているもの NG',                30, true, '{}'),
  ('ng_item', 'unclear_brand',     '브랜드명·상품명·패키지·상품의 색감이 잘 보이지 않는 사진 금지',        'ブランド名・商品名・パッケージ・商品の発色が見えにくいもの NG', 40, true, '{}'),
  ('ng_item', 'negative',          '본 상품/서비스에 대한 부정적인 표현 금지',                    '本商品／サービスに対するネガティブな表現 NG',         50, true, '{}'),
  ('ng_item', 'swatch_only',       '상품을 실제로 사용하지 않고 스와치 게시물만 등록 금지',              '商品を実際に使用せずスウォッチ投稿のみ NG',          60, true, '{}')
ON CONFLICT (kind, code) DO UPDATE SET
  name_ko = EXCLUDED.name_ko,
  name_ja = EXCLUDED.name_ja,
  sort_order = EXCLUDED.sort_order,
  active = EXCLUDED.active,
  recruit_types = EXCLUDED.recruit_types,
  updated_at = now();

-- 검증:
-- SELECT kind, COUNT(*) FROM lookup_values GROUP BY kind ORDER BY kind;
-- 예상: category=5, channel=6, content_type=6, ng_item=6 (총 23)
