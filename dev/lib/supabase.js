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

// 브랜드 화면(dev/brand/index.html)은 이 파일을 싣되 전역 연결을 만들지 않는다 — window.REVERB_SKIP_GLOBAL_DB = true.
//   전역 db 는 기본 저장 칸 + detectSessionInUrl:true 라, 브랜드 화면에서 만들어지면 ①인플루언서 세션과 저장 칸을 섞고
//   ②메일 링크 주소의 인증 값을 먼저 가로챈다. 브랜드 화면은 자기 연결(저장 칸 'reverb.brandAuth')을 따로 만든다.
//   ⚠️ 인플루언서·관리자 화면은 이 표시를 두지 않는다 — 두면 그 화면의 db 가 null 이 된다.
const REVERB_SKIP_GLOBAL_DB = window.REVERB_SKIP_GLOBAL_DB === true;

let db = null;
try {
  if (window.supabase && !REVERB_SKIP_GLOBAL_DB) {
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
  if (window.supabase && !REVERB_SKIP_GLOBAL_DB) {
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
