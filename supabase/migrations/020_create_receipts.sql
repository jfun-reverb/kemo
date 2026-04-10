-- ============================================
-- receipts テーブル作成 — 購入レシート登録
-- Supabase SQL Editor で実行してください
-- ============================================

CREATE TABLE IF NOT EXISTS receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id uuid NOT NULL REFERENCES applications(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  receipt_url text NOT NULL,
  purchase_date date,
  purchase_amount integer DEFAULT 0,
  memo text,
  created_at timestamptz DEFAULT now()
);

ALTER TABLE receipts ENABLE ROW LEVEL SECURITY;

-- 本人のレシートのみ閲覧・作成可能
CREATE POLICY "receipts_select_own" ON receipts FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "receipts_insert_own" ON receipts FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "receipts_update_own" ON receipts FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- 管理者は全件閲覧・更新可能
CREATE POLICY "receipts_select_admin" ON receipts FOR SELECT USING (is_admin());
CREATE POLICY "receipts_update_admin" ON receipts FOR UPDATE USING (is_admin()) WITH CHECK (is_admin());
CREATE POLICY "receipts_delete_admin" ON receipts FOR DELETE USING (is_admin());

CREATE INDEX IF NOT EXISTS idx_receipts_application_id ON receipts(application_id);
CREATE INDEX IF NOT EXISTS idx_receipts_user_id ON receipts(user_id);
CREATE INDEX IF NOT EXISTS idx_receipts_campaign_id ON receipts(campaign_id);
