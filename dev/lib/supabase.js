// ══════════════════════════════════════
// CONFIG — Supabase 接続設定
// ══════════════════════════════════════
const SUPABASE_URL = 'https://twofagomeizrtkwlhsuv.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_3KgWYIf5w5J727Q2g3Cl7Q_ETD1Swps';
const ADMIN_EMAIL = 'admin@kemo.jp';

let db = null;
try { if (window.supabase) db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY); } catch(e) {}
