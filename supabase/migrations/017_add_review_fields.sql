-- applications テーブルに審査情報カラムを追加
ALTER TABLE applications ADD COLUMN IF NOT EXISTS reviewed_by text;
ALTER TABLE applications ADD COLUMN IF NOT EXISTS reviewed_at timestamptz;
