// ══════════════════════════════════════
// CONFIG — Supabase 연결 설정 (환경별 자동 분기)
// ══════════════════════════════════════
// production: globalreverb.com / www.globalreverb.com
// staging:    dev.globalreverb.com, *.vercel.app, localhost, 127.0.0.1, file://
const SUPABASE_ENVS = {
  production: {
    url: 'https://twofagomeizrtkwlhsuv.supabase.co',
    key: 'sb_publishable_3KgWYIf5w5J727Q2g3Cl7Q_ETD1Swps'
  },
  staging: {
    url: 'https://qysmxtipobomefudyixw.supabase.co',
    key: 'sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv'
  }
};

// 정규식은 globalreverb.com / www.globalreverb.com만 엄격히 매칭.
// 다른 서브도메인(dev, staging, preview 등)이 실수로 production DB에 접근하는 것을 방지.
function resolveSupabaseEnv(hostname) {
  if (/^(www\.)?globalreverb\.com$/.test(hostname)) return 'production';
  return 'staging';
}

const SUPABASE_ENV = resolveSupabaseEnv(location.hostname);
const SUPABASE_URL = SUPABASE_ENVS[SUPABASE_ENV].url;
const SUPABASE_ANON_KEY = SUPABASE_ENVS[SUPABASE_ENV].key;
const IS_STAGING = SUPABASE_ENV === 'staging';
const ADMIN_EMAIL = 'admin@kemo.jp';

// 디버깅용 전역 노출
window.__REVERB_ENV__ = SUPABASE_ENV;

let db = null;
try { if (window.supabase) db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY); } catch(e) {}
