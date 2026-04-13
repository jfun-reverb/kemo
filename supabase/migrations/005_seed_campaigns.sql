-- ============================================
-- REVERB JP — 기본 캠페인 6개 DB 등록
-- Supabase SQL Editor에서 실행하세요
-- ============================================

INSERT INTO campaigns (title, brand, product, type, channel, category, emoji, image_url, img1, product_price, reward, slots, applied_count, deadline, post_days, content_types, recruit_type, order_index, description, hashtags, mentions, appeal, guide, ng, status, created_at)
VALUES
-- 1. 이니스프리 그린티세럼
('グリーンティセラム ナノ体験団', 'INNISFREE · イニスフリー', 'グリーンティセラム 80ml', 'nano', 'instagram', 'beauty', '🌿',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0016/A00000016477202.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0016/A00000016477202.jpg',
 3200, 0, 25, 0, '2026-05-30', 7, 'インスタ/フィード,インスタ/リール', 'monitor', 1,
 'イニスフリーの人気スキンケアアイテム、グリーンティセラムを体験していただける方を募集します。',
 '#innisfree #イニスフリー #グリーンティセラム #スキンケア', '@innisfree_official_jp',
 'グリーンティ由来の保湿成分が肌深部まで浸透。',
 '明るい自然光で撮影してください。商品のテクスチャーがわかるようにアップで撮影。',
 '競合ブランド商品との比較投稿はNG。ネガティブ表現はNG。',
 'active', '2026-04-01T00:00:00.000Z'),

-- 2. 라운드랩 바치울라 토너
('ラウンドラボ バーチュラ体験団', 'ROUND LAB · ラウンドラボ', 'バーチュラトナー 200ml', 'nano', 'instagram', 'beauty', '🌿',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018208201.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018208201.jpg',
 4500, 0, 20, 0, '2026-05-25', 10, 'インスタ/フィード', 'monitor', 2,
 'ROUND LABの大人気バーチュラトナーを体験していただける方を募集します。',
 '#roundlab #ラウンドラボ #バーチュラトナー #韓国コスメ', '@roundlab_jp',
 '白樺水配合で肌を優しく整えるトナー。乾燥肌・敏感肌の方に特におすすめ。',
 '清潔感のある明るい背景で撮影。使用前後の肌の変化を表現してください。',
 '他ブランドとの比較NG。フィルター過剰使用NG。',
 'active', '2026-04-01T00:00:00.000Z'),

-- 3. DR.G 쿠션 파운데이션
('DR.G クッションファンデ体験団', 'DR.G · ドクタージー', 'レッドブレミッシュクッション', 'nano', 'instagram', 'beauty', '💄',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',
 3800, 1000, 15, 0, '2026-06-01', 14, 'インスタ/フィード,インスタ/リール,インスタ/ストーリー', 'monitor', 3,
 'DR.Gの人気クッションファンデーションを体験していただける方を募集！リワード¥1,000付き。',
 '#drg #ドクタージー #クッションファンデ #韓国コスメ', '@drg_japan',
 '赤みをカバーしながら素肌感を演出。SPF50+PA+++で紫外線対策も。',
 '使用前後のビフォーアフターが伝わる投稿。明るい自然光での撮影推奨。',
 '過度なフィルター加工NG。競合製品との比較NG。',
 'active', '2026-04-01T00:00:00.000Z'),

-- 4. 메디힐 마스크팩
('MEDIHEAL マスクパック体験団', 'MEDIHEAL · メディヒール', 'TEAトゥリーケアマスクパック 10枚', 'nano', 'instagram', 'beauty', '🩺',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',
 2000, 0, 30, 0, '2026-05-20', 7, 'インスタ/フィード,TikTok', 'gifting', 4,
 'MEDIHEALのTEAトゥリーマスクパックを体験していただける方を募集します。',
 '#mediheal #メディヒール #マスクパック #スキンケア', '@mediheal_japan',
 'ティーツリー成分が肌トラブルをケア。毛穴引き締め効果も。',
 '着用中・着用後の自然な表情を撮影。朝・夜のスキンケアシーンに合わせてください。',
 '加工しすぎた写真NG。マスク着用以外の用途での撮影NG。',
 'active', '2026-04-01T00:00:00.000Z'),

-- 5. 페리페라 립
('PERIPERA リップ体験団', 'PERIPERA · ペリペラ', 'インクムードグロウティント', 'nano', 'instagram', 'beauty', '💋',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',
 1500, 500, 20, 0, '2026-05-31', 7, 'インスタ/リール,TikTok', 'gifting', 5,
 'PERIPERAの人気リップを体験！リワード¥500付き。カラー発色が美しいグロウティントです。',
 '#peripera #ペリペラ #リップ #韓国コスメ #Kビューティ', '@peripera_japan',
 'ウォータリーなテクスチャーで唇に密着。鮮やかな発色が長時間持続。',
 'リップスウォッチや着用シーンを撮影。明るい照明で発色が伝わるように。',
 '口元以外の過度なフィルターNG。競合リップとの比較NG。',
 'active', '2026-04-01T00:00:00.000Z'),

-- 6. 비비고 만두 (Qoo10)
('BIBIGO 餃子 Qoo10体験団', 'CJ BIBIGO · ビビゴ', '王餃子 420g', 'qoo10', 'qoo10', 'food', '🥟',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',
 'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',
 1200, 2000, 10, 0, '2026-06-15', 10, 'インスタ/フィード,X投稿', 'gifting', 6,
 'BIBIGOの人気王餃子をQoo10でレビュー！リワード¥2,000付き。',
 '#bibigo #ビビゴ #王餃子 #韓国フード #Qoo10', '@bibigo_japan',
 '本場韓国の味をそのままに。もちもちの皮と旨味たっぷりの肉あん。',
 '調理過程・完成品を美しく撮影。食欲をそそるシズル感を大切に。',
 '他社冷凍食品との比較NG。料理以外での使用シーンNG。',
 'active', '2026-04-01T00:00:00.000Z');
