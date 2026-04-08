-- campaigns テーブルに view_count カラムを追加
ALTER TABLE campaigns ADD COLUMN IF NOT EXISTS view_count INTEGER DEFAULT 0;
