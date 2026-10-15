// 브랜드 페이지 공용 — 화면 전환·입력 칸 오류 표시·검사 규칙
//   ⚠️ 관리자·인플루언서 빌드에 들어가지 않는 독립 화면(dev/brand/index.html) 전용이다.
//   ⚠️ ui.js 를 싣지 않는다 — 전역 키보드·클릭·끌어놓기 처리기가 함께 붙기 때문.

// 로그인 저장 칸 이름. supabase-js 기본값(sb-…-auth-token)을 쓰면
// 같은 주소의 인플루언서·관리자 로그인과 세션이 섞인다 — 브랜드는 반드시 이 이름으로 분리한다.
const BRAND_AUTH_STORAGE_KEY = 'reverb.brandAuth';
// 메일 링크로 생기는 임시 세션 칸 이름 — persistSession:false 라 실제로는 쓰지 않는다(안전장치)
const BRAND_SETUP_STORAGE_KEY = 'reverb.brandSetup';

// 로그인 전 카드 화면. 로그인 뒤 틀 안 페이지(#orient·#members 등)는 brand-shell.js 의 등록부가 따로 갖는다.
const BRAND_SCREENS = ['login', 'forgot', 'forgot-sent', 'setpw', 'resetpw', 'reset-done', 'confirm',
  'invite', 'email-change', 'link-invalid', 'not-brand', 'no-brand', 'check-fail'];

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
    closed: '브랜드 페이지', login: '브랜드 로그인', forgot: '비밀번호 찾기', 'forgot-sent': '메일을 확인해 주십시오',
    setpw: '비밀번호 설정', resetpw: '새 비밀번호 정하기', 'reset-done': '비밀번호를 바꿨습니다', confirm: '링크 확인',
    invite: '브랜드 초대', 'email-change': '로그인 이메일 바꾸기', 'link-invalid': '링크를 쓸 수 없습니다',
    'not-brand': '브랜드 계정이 아닙니다', 'no-brand': '연결된 브랜드가 없습니다',
    'check-fail': '로그인을 확인하지 못했습니다'
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
//   문구는 피그마 w01-92 ① 한 줄(빠진 조건과 상관없이 같은 안내).
const BRAND_PW_RULE_MSG = '8자 이상으로, 영문 소문자와 기호(! @ # 등)를 넣어 주십시오.';
function brandPasswordIssue(pw) {
  if (!pw || pw.length < 8) return BRAND_PW_RULE_MSG;
  if (!/[a-z]/.test(pw)) return BRAND_PW_RULE_MSG;
  if (!/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]/.test(pw)) return BRAND_PW_RULE_MSG;
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

// ── 공용 부품 (묶음 ② 작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 1)
//   ui.js 를 싣지 않는 자립형 화면이라 토스트·확인 창·날짜 표기를 여기 따로 둔다.

// 토스트 — 글자만(아이콘·이모지 없음). 화면 아래에 잠깐 떴다 사라진다.
let _brandToastTimer = null;
function brandToast(msg, opts) {
  let el = document.getElementById('brandToast');
  if (!el) {
    el = document.createElement('div');
    el.id = 'brandToast';
    el.className = 'brand-toast';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    document.body.appendChild(el);
  }
  el.textContent = msg || '';
  el.classList.toggle('is-error', !!(opts && opts.error));   // 실패 토스트는 빨강(피그마 w06-90)
  el.classList.add('is-show');
  clearTimeout(_brandToastTimer);
  _brandToastTimer = setTimeout(() => el.classList.remove('is-show'), 3200);
}

// 확인 창 — Promise<boolean>. 모달을 그때그때 만든다(index.html 을 화면마다 고치지 않게).
//   Esc·바깥 누르기 = 취소. 열 때 「취소」에 초점(되돌릴 수 없는 동작을 엔터 한 번에 누르지 않게), 닫으면 원래 초점으로.
//   단추 순서는 화면마다 피그마대로(opts.okFirst · opts.single — 아래 주석).
function brandConfirm(opts) {
  const o = opts || {};
  return new Promise(resolve => {
    const prevFocus = document.activeElement;
    const _cancelBtn = '<button type="button" class="brand-btn brand-btn-line" data-act="cancel">' + brandEsc(o.cancelLabel || '취소') + '</button>';
    const wrap = document.createElement('div');
    wrap.className = 'brand-modal';
    wrap.setAttribute('role', 'dialog');
    wrap.setAttribute('aria-modal', 'true');
    wrap.setAttribute('aria-labelledby', 'brandConfirmTitle');
    wrap.innerHTML =
      // o.card — 회색 상자 + 흰 카드 + 오른쪽 정렬 단추(피그마 w06-02·03, 초대 모달 w06-01 과 같은 모양)
      '<div class="brand-modal-box' + (o.card ? ' is-card' : '') + '">' +
        '<h2 id="brandConfirmTitle">' + brandEsc(o.title || '') + '</h2>' +
        // o.card 면 내용을 흰 카드 안에(피그마 w06-02·03 — 「· 」로 시작하는 여러 줄)
        (o.body ? (o.card ? '<div class="brand-modal-card"><p class="brand-modal-lines">' + brandEsc(o.body) + '</p></div>' : '<p>' + brandEsc(o.body) + '</p>') : '') +
        // 단추 순서는 화면마다 피그마대로 — 기본 「취소 · 실행」(w06-02·03), o.okFirst 면 「실행 · 취소」(w01-10).
        //   o.single 이면 「확인」 하나(w06-01a). 처음 초점은 「취소」(실수로 엔터 한 번에 실행되지 않게), 하나뿐이면 그 단추
        '<div class="brand-modal-actions' + (o.single ? ' is-single' : '') + (o.card ? ' is-right' : '') + '">' +
          (o.single ? '' : (o.okFirst ? '' : _cancelBtn)) +
          '<button type="button" class="brand-btn' + (o.danger ? ' brand-btn-danger' : '') + '" data-act="ok">' + brandEsc(o.okLabel || '확인') + '</button>' +
          (o.single ? '' : (o.okFirst ? _cancelBtn : '')) +
        '</div>' +
      '</div>';
    let done = false;
    const close = (val) => {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      wrap.remove();
      if (prevFocus && prevFocus.isConnected && typeof prevFocus.focus === 'function') prevFocus.focus();
      resolve(val);
    };
    const onKey = (e) => {
      if (e.key === 'Escape') { e.stopPropagation(); close(false); return; }
      if (e.key === 'Tab') {
        // 창 안에서만 초점이 돌게
        const btns = Array.from(wrap.querySelectorAll('button'));
        const i = btns.indexOf(document.activeElement);
        if (i === -1) { e.preventDefault(); btns[0].focus(); return; }   // 바깥으로 나간 초점을 창 안으로
        if (e.shiftKey && i <= 0) { e.preventDefault(); btns[btns.length - 1].focus(); }
        else if (!e.shiftKey && i === btns.length - 1) { e.preventDefault(); btns[0].focus(); }
      }
    };
    wrap.addEventListener('click', (e) => {
      if (e.target === wrap) { close(false); return; }
      const act = e.target.closest('[data-act]');
      if (act) close(act.dataset.act === 'ok');
    });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(wrap);
    (wrap.querySelector('[data-act="cancel"]') || wrap.querySelector('[data-act="ok"]')).focus();
  });
}

// 서버 함수(Edge Function) 호출 — { status, body }. 2xx 가 아니어도 본문(JSON)을 읽는다
//   (functions.invoke 는 2xx 가 아니면 본문을 오류 객체 안에 감춰 reason 을 못 읽는다 — 묶음 ① 넘김 3).
//   opts.auth=true 면 로그인 연결의 접근 토큰을 싣고, 401 이면 토큰을 한 번 갱신해 다시 부른다.
//   연결 끊김·운영 주소(brandDb 없음)는 { status:0, body:null }.
async function brandCallFunction(name, payload, opts) {
  if (!brandDb) return { status: 0, body: null };
  const auth = !!(opts && opts.auth);
  const send = async () => {
    let token = SUPABASE_ANON_KEY;
    if (auth) {
      try {
        const { data } = await brandDb.auth.getSession();
        token = data && data.session ? data.session.access_token : '';
      } catch (e) { token = ''; }
      if (!token) return { status: 401, body: null };
    }
    const res = await fetch(SUPABASE_URL + '/functions/v1/' + name, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'apikey': SUPABASE_ANON_KEY, 'Authorization': 'Bearer ' + token },
      body: JSON.stringify(payload || {})
    });
    let body = null;
    try { body = await res.json(); } catch (e) { body = null; }
    return { status: res.status, body };
  };
  try {
    let r = await send();
    if (auth && r.status === 401) {
      try {
        const { error } = await brandDb.auth.refreshSession();
        if (!error) r = await send();
      } catch (e) { /* 아래에서 그대로 돌려준다 */ }
    }
    return r;
  } catch (e) {
    return { status: 0, body: null };
  }
}

// 날짜 표기 — 관리자 formatDate(2026/10/15)·formatDateTime(2026/10/15 14:05)과 같은 모양.
//   ⚠️ ui.js 를 싣지 않아 사본을 둔다. 빈 값·잘못된 값은 빈 문자열.
function _brandPad2(n) { return String(n).padStart(2, '0'); }
function brandFormatDate(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '';
  return d.getFullYear() + '/' + _brandPad2(d.getMonth() + 1) + '/' + _brandPad2(d.getDate());
}
function brandFormatDateTime(iso) {
  const day = brandFormatDate(iso);
  if (!day) return '';
  const d = new Date(iso);
  return day + ' ' + _brandPad2(d.getHours()) + ':' + _brandPad2(d.getMinutes());
}
