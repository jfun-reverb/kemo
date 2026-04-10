-- ============================================
-- influencers テーブルに代表SNSアカウント選択カラム追加
-- Supabase SQL Editor で実行してください
-- ============================================

ALTER TABLE influencers ADD COLUMN IF NOT EXISTS primary_sns text DEFAULT '';
