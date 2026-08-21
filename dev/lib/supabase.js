// ══════════════════════════════════════
// CONFIG — Supabase 연결 설정 (환경별 자동 분기)
// ══════════════════════════════════════
// production: globalreverb.com / www.globalreverb.com
// staging:    dev.globalreverb.com, *.vercel.app, localhost, 127.0.0.1, file://
const SUPABASE_ENVS = {
  production: {
    url: 'https://nrwtujmlbktxjgdwlpjj.supabase.co',
    key: 'sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP'
  },
  staging: {
    url: 'https://qysmxtipobomefudyixw.supabase.co',
    key: 'sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv'
  }
};

// 정규식은 globalreverb.com / www.globalreverb.com만 엄격히 매칭.
// 다른 서브도메인(dev, staging, preview 등)이 실수로 production DB에 접근하는 것을 방지.
//
// ⚠️ 네이티브 앱(iOS)은 주소로 가를 수 없다 — 파일을 앱 안에 담아 띄우므로 hostname 이 늘
//    'localhost' 라 아래 정규식에 절대 안 걸린다(= 언제나 staging). 그래서 **앱 빌드가 심어 둔
//    값**을 먼저 본다. 값은 iOS 빌드 스크립트가 <head> 에 넣으며, 웹에는 이 값이 없어 종전 그대로다.
//    ⚠️ 값이 SUPABASE_ENVS 에 실제로 있는 이름일 때만 따른다 — 오타가 들어오면 조용히
//       undefined 로 접속하는 대신 아래 주소 판정으로 떨어지게 한다(안전한 쪽 = staging).
function resolveSupabaseEnv(hostname) {
  const forced = (typeof window !== 'undefined') ? window.__REVERB_FORCE_ENV__ : null;
  if (forced && Object.prototype.hasOwnProperty.call(SUPABASE_ENVS, forced)) return forced;
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
try {
  if (window.supabase) {
    db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        flowType: 'pkce',
        detectSessionInUrl: true,
        persistSession: true,
        autoRefreshToken: true
      }
    });
  }
} catch(e) {}

// 비밀번호 찾기 「요청」 전용 보조 클라이언트 (2026-07-20)
//   전역 db 는 flowType:'pkce' 라, 재설정 메일 토큰이 요청한 그 브라우저에서만 검증 가능한
//   형태(pkce_...)로 발급된다 → PC 에서 요청하고 폰에서 메일을 열면 실패한다.
//   인플루언서는 폰으로 메일을 보는 비율이 높아 이 조합이 실패의 주원인.
//   ⚠️ 전역 db 설정은 절대 바꾸지 않는다 — 로그인·세션 유지·회원가입 확인이 전부 거기 얹혀 있다.
//   저장소에 아무것도 쓰지 않는 인스턴스라 전역 세션과 섞이지 않는다.
//   ※ 메일을 「받은 뒤」의 검증(verifyOtp)은 pkce 여부와 무관한 별개 경로라 전역 db 를 그대로 쓴다.
let dbAuthRequest = null;
try {
  if (window.supabase) {
    dbAuthRequest = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        flowType: 'implicit',      // 브라우저 종속 토큰(pkce_) 발급 방지 — 핵심
        persistSession: false,     // 저장소에 세션을 쓰지 않음
        autoRefreshToken: false,
        detectSessionInUrl: false, // 주소의 인증 값을 이 인스턴스가 가로채지 않게
        storageKey: 'reverb.authRequest'  // 저장 칸 분리(안전장치 — 위 설정만으로도 저장은 없음)
      }
    });
  }
} catch(e) {}
