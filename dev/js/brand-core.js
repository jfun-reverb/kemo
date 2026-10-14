// 브랜드 페이지 공용 — 화면 전환·입력 칸 오류 표시·검사 규칙
//   ⚠️ 관리자·인플루언서 빌드에 들어가지 않는 독립 화면(dev/brand/index.html) 전용이다.
//   ⚠️ ui.js 를 싣지 않는다 — 전역 키보드·클릭·끌어놓기 처리기가 함께 붙기 때문.

// 로그인 저장 칸 이름. supabase-js 기본값(sb-…-auth-token)을 쓰면
// 같은 주소의 인플루언서·관리자 로그인과 세션이 섞인다 — 브랜드는 반드시 이 이름으로 분리한다.
const BRAND_AUTH_STORAGE_KEY = 'reverb.brandAuth';
// 메일 링크로 생기는 임시 세션 칸 이름 — persistSession:false 라 실제로는 쓰지 않는다(안전장치)
const BRAND_SETUP_STORAGE_KEY = 'reverb.brandSetup';

const BRAND_SCREENS = ['login', 'forgot', 'forgot-sent', 'setpw', 'resetpw', 'reset-done', 'confirm',
  'invite', 'email-change', 'link-invalid', 'not-brand', 'no-brand', 'home', 'check-fail'];

// ── 연결 둘 (사양서 분해표 「조각 8」 착수 전 주의 ①②⑤)
//   brandDb      : 로그인 연결. pkce + 저장 칸 'reverb.brandAuth' + 주소의 인증 값은 읽지 않는다(detectSessionInUrl:false).
//   brandSetupDb : 메일 링크(설정·재설정) 전용 임시 연결. implicit — 서버 발급 링크는 #access_token=… 으로 돌아오므로
//                  pkce 면 못 읽는다(admin-setpw.html 399행과 같은 이유). 저장하지 않고, 토큰은 화면이 직접 setSession 한다.
//   🔴 운영 주소(IS_STAGING=false)에서는 만들지 않는다 — 운영은 「준비 중」 카드만(사용자 결정 P-1).
let brandDb = null;
let brandSetupDb = null;
function initBrandClients() {
  if (typeof IS_STAGING === 'undefined' || !IS_STAGING) return false;
  if (!window.supabase || typeof window.supabase.createClient !== 'function') return false;
  try {
    brandDb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        storageKey: BRAND_AUTH_STORAGE_KEY,
        flowType: 'pkce',
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: false
      }
    });
    brandSetupDb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      auth: {
        storageKey: BRAND_SETUP_STORAGE_KEY,
        flowType: 'implicit',
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false
      }
    });
  } catch (e) {
    brandDb = null; brandSetupDb = null;
    return false;
  }
  return true;
}

// 접근 토큰이 만료돼 거절된 오류인지 — storage.js 의 retryWithRefresh 와 같은 판정(이 화면은 storage.js 를 싣지 않는다)
function isBrandJwtError(err) {
  if (!err) return false;
  const msg = String(err.message || '');
  return err.code === 'PGRST301' || err.status === 401 || /jwt|token is expired/i.test(msg);
}

// 로그인 연결로 원격 호출 — 토큰 만료면 한 번 갱신하고 다시 부른다. 실패면 { data:null, error }
async function brandRpc(name, args) {
  if (!brandDb) return { data: null, error: new Error('no_client') };
  let r;
  try { r = await brandDb.rpc(name, args || {}); } catch (e) { return { data: null, error: e }; }
  // postgrest 는 상태 코드를 응답 최상위(r.status)에 둔다 — 오류 객체만 보면 401 을 놓친다
  if (r.error && (isBrandJwtError(r.error) || r.status === 401)) {
    try {
      const { error: refErr } = await brandDb.auth.refreshSession();
      if (!refErr) r = await brandDb.rpc(name, args || {});
    } catch (e) { /* 아래에서 실패로 돌려준다 */ }
  }
  return r;
}

// 로그아웃 — 🔴 scope:'local'(기본 global 은 같은 사용자의 다른 기기 세션까지 끊는다).
//   우리가 스스로 끊을 때 나는 SIGNED_OUT 을 「로그인 시간 만료」로 읽지 않게 표시를 세운다(brand-app.js).
let _brandSigningOut = false;
async function brandSignOutLocal() {
  if (!brandDb) return;
  _brandSigningOut = true;
  try { await brandDb.auth.signOut({ scope: 'local' }); } catch (e) { /* 저장 칸만 비면 된다 */ }
  finally { _brandSigningOut = false; }
}
async function brandSetupSignOutLocal() {
  if (!brandSetupDb) return;
  try { await brandSetupDb.auth.signOut({ scope: 'local' }); } catch (e) { /* 메모리 세션뿐이라 무시 */ }
}

function brandEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function showBrandScreen(name) {
  document.querySelectorAll('.brand-card[data-screen]').forEach(el => {
    el.hidden = el.dataset.screen !== name;
  });
  const titles = {
    closed: '브랜드 페이지', login: '브랜드 로그인', forgot: '비밀번호 찾기', 'forgot-sent': '메일을 확인해 주세요',
    setpw: '비밀번호 설정', resetpw: '새 비밀번호 정하기', 'reset-done': '비밀번호를 바꿨어요', confirm: '링크 확인',
    invite: '브랜드 초대', 'email-change': '로그인 이메일 바꾸기', 'link-invalid': '링크를 쓸 수 없어요',
    'not-brand': '브랜드 계정이 아니에요', 'no-brand': '연결된 브랜드가 없어요', home: '브랜드 페이지',
    'check-fail': '로그인을 확인하지 못했어요'
  };
  document.title = (titles[name] || '브랜드') + ' · REVERB JP';
}

// 칸 아래 오류 문구 + 빨간 테두리. msg 가 비면 지운다.
function setFieldError(inputId, msg) {
  const input = document.getElementById(inputId);
  const err = document.getElementById(inputId + 'Error');
  if (input) {
    input.classList.toggle('is-error', !!msg);
    if (msg) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    if (err) {
      if (msg) input.setAttribute('aria-describedby', err.id); else input.removeAttribute('aria-describedby');
    }
  }
  if (err) { err.textContent = msg || ''; err.hidden = !msg; }
}

function clearFormErrors(form) {
  form.querySelectorAll('.brand-input').forEach(el => { if (el.id) setFieldError(el.id, ''); });
}

function setNotice(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg || '';
  el.hidden = !msg;
}

// 이메일 형식 — 화면에서만 본다(가입 여부와 무관). 「@」 뒤에 「.」이 있어야 통과.
function isEmailFormat(v) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
}

// 비밀번호 규칙 — 8자 + 영문 소문자 + 기호.
//   ⚠️ 같은 규칙의 사본이 셋이다: ui.js passwordPolicyIssue · admin-setpw.html validateAdminPassword · 여기.
//      규칙을 바꾸면 셋을 함께 고친다. (ui.js 를 싣지 않아 사본을 둔다 — 파일 머리말 참고)
function brandPasswordIssue(pw) {
  if (!pw || pw.length < 8) return '비밀번호는 8자 이상으로 정해 주세요.';
  if (!/[a-z]/.test(pw)) return '영문 소문자를 하나 이상 넣어 주세요.';
  if (!/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]/.test(pw)) return '기호(! @ # 같은 글자)를 하나 이상 넣어 주세요.';
  return '';
}

// 비밀번호 「보기」 단추 — data-pw-toggle="입력칸 id"
function bindPasswordToggles() {
  document.querySelectorAll('[data-pw-toggle]').forEach(btn => {
    btn.addEventListener('click', () => {
      const input = document.getElementById(btn.dataset.pwToggle);
      if (!input) return;
      const show = input.type === 'password';
      input.type = show ? 'text' : 'password';
      btn.setAttribute('aria-pressed', String(show));
      btn.setAttribute('aria-label', show ? '비밀번호 숨기기' : '비밀번호 보기');
      const icon = btn.querySelector('.material-icons-round');
      if (icon) icon.textContent = show ? 'visibility_off' : 'visibility';
    });
  });
}

// 「보기」로 글자를 보이게 해 둔 칸을 다시 가린다 (화면을 다시 채울 때)
function resetPasswordToggles(scope) {
  scope.querySelectorAll('[data-pw-toggle]').forEach(btn => {
    const input = document.getElementById(btn.dataset.pwToggle);
    if (input) input.type = 'password';
    btn.setAttribute('aria-pressed', 'false');
    btn.setAttribute('aria-label', '비밀번호 보기');
    const icon = btn.querySelector('.material-icons-round');
    if (icon) icon.textContent = 'visibility';
  });
}

// 폼 칸·버튼 잠금 (Figma ⑤ 로그인 중)
function setFormBusy(form, busy) {
  form.querySelectorAll('input, button').forEach(el => { el.disabled = busy; });
}
