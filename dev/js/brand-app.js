// 브랜드 페이지 — 부팅·화면 주소(#해시) 전환·메일 링크 착지·개발서버 미리보기 막대. 맨 마지막에 싣는다.
//   운영 주소(IS_STAGING=false — dev/lib/supabase.js 의 도메인 판정)에서는 「준비 중」 카드만 보이고
//   연결을 만들지 않으며 다른 화면·미리보기 막대도 그리지 않는다(사용자 결정 P-1).

const BRAND_EXPIRED_MSG = '로그인 시간이 지났습니다. 다시 로그인해 주십시오.';

// 미리보기 막대에서 고른 값 — brand-login.js 가 읽는다(서버와 연결 안 된 화면 전용)
const brandPreviewState = {
  setpwKind: 'owner',    // 'owner'(운영팀이 만든 계정) | 'member'(초대받은 멤버)
  confirmKind: 'setup'   // bw01-08 제목 — 'setup' | 'reset'
};

// 미리보기 목록 — 로그인 뒤 틀(brand-shell.js)은 세션이 있어야 해서 넣지 않는다.
//   bw01-04 이메일 변경(email-change)은 피그마 섹션에서 빠져(F-5) 목록에서 뺐다. 마크업·동작은 다음 작업용으로 남겨 둔다.
const BRAND_PREVIEW_SCREENS = [
  { hash: 'login', label: 'bw01-00 로그인' },
  { hash: 'forgot', label: 'bw01-01 비밀번호 찾기' },
  { hash: 'forgot-sent', label: 'bw01-01a 메일 발송' },
  { hash: 'setpw', label: 'bw01-02 비밀번호 설정' },
  { hash: 'invite', label: 'bw01-03 초대 수락' },
  { hash: 'link-invalid', label: 'bw01-05 쓸 수 없는 링크' },
  { hash: 'not-brand', label: 'bw01-06 브랜드 계정이 아님' },
  { hash: 'no-brand', label: 'bw01-06a 연결된 브랜드 없음' },
  { hash: 'resetpw', label: 'bw01-07 새 비밀번호 정하기' },
  { hash: 'reset-done', label: 'bw01-07a 비밀번호 바꾸기 완료' },
  { hash: 'confirm', label: 'bw01-08 계속하기' }
];

// 로그인 상태(get_my_brand_login_state 의 ok 결과). null 이면 로그아웃 상태.
//   화면 쪽 세션 값(brandSession — 지금 브랜드 등)은 brand-shell.js 가 함께 갱신한다.
let brandAuthed = null;
function setBrandAuthed(state, opts) {
  brandAuthed = state || null;
  setBrandSessionFromState(brandAuthed, opts);
  updatePreviewVisibility();
}

function currentBrandHash() {
  return location.hash.replace(/^#/, '');
}

// 해시로 화면을 바꾼다 — 이미 그 해시면 hashchange 가 안 나므로 직접 그린다
function goBrandScreen(name) {
  if (location.hash === '#' + name) routeBrand();
  else location.hash = '#' + name;
}

function routeBrand() {
  // 메일 링크 화면(설정·재설정·계속하기)에 있다가 주소가 바뀌면(뒤로 가기·직접 입력) 그 흐름을 끝낸다
  if (brandLinkCtx) {
    brandSetupSignOutLocal();
    brandLinkCtx = null;
    _brandConfirmTarget = null;
    history.replaceState(null, '', location.pathname + location.hash);
  }
  _brandCheckPending = false;
  // 초대 메일 링크 흐름(계속하기·새 이메일 설정 화면)에 있다가 주소가 바뀌면 그 흐름을 끝낸다
  if (_brandInviteLanding || _brandInviteNewCtx) { _brandInviteLanding = null; endBrandInviteNew(); clearBrandInviteLink(); }
  const hash = currentBrandHash();
  // 로그인돼 있으면 틀 안 페이지만(카드 화면 해시로 오면 첫 페이지) / 로그인 안 했으면 틀 페이지로 못 간다
  if (brandAuthed) {
    const page = isBrandShellPage(hash) ? hash : BRAND_FIRST_PAGE;
    // 카드 화면 해시(#login 등)·빈 해시로 왔으면 주소창도 실제 페이지로 맞춘다
    if (page !== hash) history.replaceState(null, '', location.pathname + location.search + '#' + page);
    showBrandShellPage(page);
    updatePreviewVisibility();
    return;
  }
  const name = BRAND_SCREENS.includes(hash) ? hash : 'login';

  // 들어올 때마다 그 화면을 처음 상태로 채운다(미리보기 예시 값 — 실제 링크 흐름은 showBrandFlowScreen)
  if (name === 'setpw') fillSetpwScreen(brandPreviewState.setpwKind);
  if (name === 'resetpw') fillResetpwScreen(BRAND_SAMPLE.resetEmail);
  if (name === 'confirm') fillConfirmScreen(brandPreviewState.confirmKind, null);
  if (name === 'invite') {
    // 실제 초대 맥락이 있으면 그 화면 그대로(뒤로·앞으로 가기로 돌아온 경우), 없으면 미리보기 예시
    if (_brandInviteCtx) { paintBrandScreen('invite'); return; }
    fillInviteScreen();
  } else if (_brandInviteCtx) {
    // 초대 수락 화면을 떠남
    const src = _brandInviteCtx.source;
    _brandInviteCtx = null;
    if (src === 'link') {
      // 메일 링크로 연 초대 — 계정 자체는 정상일 수 있다. 판정을 다시 받아 원래 화면으로(브랜드 있음 = 틀, 대기 초대만 = 초대 화면)
      restoreBrandSession();
      return;
    }
    // 로그인 경로(대기 초대만 있는 계정) — 세션을 두면 틀 없이 로그인된 채 남는다. 이 기기에서 로그아웃
    brandSignOutLocal();
  }
  if (name === 'email-change') fillEmailChangeScreen();
  if (name === 'forgot') {
    clearBrandInviteLink();   // 비밀번호 찾기로 빠지면 보관한 초대 링크를 지운다
    // 로그인 칸에 넣던 이메일을 이어받는다
    const f = document.getElementById('forgotEmail');
    if (!f.value) f.value = document.getElementById('loginEmail').value.trim();
  }
  if (name !== 'login') setNotice('loginError', '');
  paintBrandScreen(name);
}

function paintBrandScreen(name) {
  hideBrandShell();
  showBrandScreen(name);
  updatePreviewBar(name);
  updatePreviewVisibility();
  window.scrollTo(0, 0);
  // 숨겨진 칸(멤버 전용 이름·연락처 등)은 건너뛰고 보이는 첫 칸에 초점
  const firstInput = Array.from(document.querySelectorAll('.brand-card[data-screen="' + name + '"] .brand-input:not([readonly])'))
    .find(el => el.offsetParent !== null);
  if (firstInput && window.matchMedia('(min-width: 601px)').matches) firstInput.focus();
}

// 메일 링크 흐름 화면 — 주소 해시를 쓰지 않는다(해시를 바꾸면 routeBrand 가 흐름을 끝낸다).
//   주소에는 ?link=…&mode=… 만 남는다. 새로고침하면 토큰이 없어 「쓸 수 없는 링크」로 간다(임시 세션은 저장하지 않는다).
function showBrandFlowScreen(name) {
  paintBrandScreen(name);
}

// 링크 흐름을 끝내고 주소에서 쿼리를 걷는다. next 가 있으면 그 화면으로.
function endBrandLinkFlow(next) {
  brandLinkCtx = null;
  _brandConfirmTarget = null;
  history.replaceState(null, '', location.pathname + (next ? '#' + next : ''));
  if (next) routeBrand();
}

async function showBrandLinkInvalid() {
  await brandSetupSignOutLocal();
  endBrandLinkFlow('link-invalid');
}

const BRAND_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// 링크 유효 판정 — 'valid' | 'invalid' | null(호출 실패)
async function fetchBrandLinkState(client, linkId, mode) {
  try {
    const { data, error } = await client.rpc('get_brand_link_state', { p_link_id: linkId, p_kind: mode });
    if (error || (data !== 'valid' && data !== 'invalid')) return null;
    return data;
  } catch (e) { return null; }
}

// ── 메일 링크 착지 (?link=<번호>&mode=setup|reset)
//   메일 링크: …/brand/?link=<번호>&mode=…#confirm=<인증 서비스 verify 주소>
//   verify 뒤 돌아옴: …/brand/?link=<번호>&mode=…#access_token=…&refresh_token=…&type=recovery
//   실패로 돌아옴: …#error=…&error_code=otp_expired (쿼리로 올 수도 있다)
async function handleBrandLinkLanding(params) {
  const linkId = params.get('link') || '';
  const mode = params.get('mode');
  const rawHash = location.hash.startsWith('#') ? location.hash.slice(1) : location.hash;
  const hp = new URLSearchParams(rawHash);

  if (!BRAND_UUID_RE.test(linkId) || (mode !== 'setup' && mode !== 'reset')) { await showBrandLinkInvalid(); return; }
  if (hp.get('error') || hp.get('error_code') || params.get('error') || params.get('error_code')) {
    await showBrandLinkInvalid();
    return;
  }

  // b) verify 뒤 돌아옴 — 🔴 토큰을 꺼낸 즉시 주소에서 지운다(주소창·방문 기록에 남지 않게, 성공·실패 무관)
  if (hp.get('access_token')) {
    const at = hp.get('access_token');
    const rt = hp.get('refresh_token') || '';
    history.replaceState(null, '', location.pathname + location.search);
    let session = null;
    try {
      const { data, error } = await brandSetupDb.auth.setSession({ access_token: at, refresh_token: rt });
      if (!error && data && data.session) session = data.session;
    } catch (e) { /* 아래에서 실패 처리 */ }
    if (!session) { await showBrandLinkInvalid(); return; }

    // 링크 번호가 아직 유효한지 다시 본다. 호출 실패(null)는 막지 않는다 — 완료 함수가 같은 번호를 다시 확인한다
    const st = await fetchBrandLinkState(brandSetupDb, linkId, mode);
    if (st === 'invalid') { await showBrandLinkInvalid(); return; }

    const email = (session.user && session.user.email) || '';
    brandLinkCtx = { linkId, mode, email, userId: session.user && session.user.id, hasSession: true };
    if (mode === 'setup') { fillSetpwReal(email); showBrandFlowScreen('setpw'); }
    else { fillResetpwScreen(email); showBrandFlowScreen('resetpw'); }
    return;
  }

  // a) 메일 링크를 처음 엶 — 열기만 해서는 아무것도 소진하지 않는다(「계속하기」를 눌러야 인증 서비스로 간다)
  if (hp.has('confirm')) {
    const target = readBrandConfirmTarget(hp.get('confirm'));
    const st = await fetchBrandLinkState(brandSetupDb, linkId, mode);
    if (st === 'invalid' || !target) { await showBrandLinkInvalid(); return; }
    // 호출 실패(null)면 막지 않고 진행 — 돌아온 뒤 다시 판정한다(일시 오류로 멀쩡한 링크를 죽이지 않게)
    brandLinkCtx = { linkId, mode, email: '', hasSession: false };
    fillConfirmScreen(mode, target);
    showBrandFlowScreen('confirm');
    return;
  }

  // 토큰도 확인 주소도 없음 — 설정 화면에서 새로고침한 경우 등(임시 세션은 저장하지 않아 이어 갈 수 없다)
  await showBrandLinkInvalid();
}

// ── 새로고침 때 로그인 연결의 세션 복원
async function restoreBrandSession() {
  let hadStored = false;
  try { hadStored = !!localStorage.getItem(BRAND_AUTH_STORAGE_KEY); } catch (e) { /* 저장소 막힘 */ }
  let session = null;
  try {
    const { data } = await brandDb.auth.getSession();
    session = data && data.session;
  } catch (e) { session = null; }
  if (!session) {
    // 저장된 세션이 있었는데 이어 가지 못했다 = 갱신 실패(로그인 시간 만료)
    if (hadStored) setNotice('loginExpiredNotice', BRAND_EXPIRED_MSG);
    routeBrand();
    return;
  }
  const state = await fetchBrandLoginState();
  // 판정 호출 실패(null)는 일시 오류일 수 있다 — 세션을 지우지 않고 「다시 시도」 화면.
  //   로그아웃은 판정 결과(not_brand 등)가 나왔을 때만 한다(로그인 직후의 실패는 applyBrandLoginState 가 로그아웃 — 그쪽은 세션이 방금 생긴 것).
  if (state === null) {
    _brandCheckPending = true;
    paintBrandScreen('check-fail');
    return;
  }
  _brandCheckPending = false;
  const result = await applyBrandLoginState(state);
  if (result === 'ok') routeBrand();
}

function updatePreviewBar(name) {
  const sel = document.getElementById('previewScreen');
  if (sel) sel.value = BRAND_PREVIEW_SCREENS.some(s => s.hash === name) ? name : '';
  document.querySelectorAll('[data-preview-for]').forEach(row => {
    row.hidden = row.dataset.previewFor !== name;
  });
}

// 미리보기 막대는 로그인 중·메일 링크 흐름 중에는 감춘다(실제 화면을 덮어쓰지 않게)
let _brandPreviewReady = false;
let _brandCheckPending = false;   // 새로고침 판정 실패 화면(check-fail)에 있는 동안
function updatePreviewVisibility() {
  const bar = document.getElementById('brandPreview');
  if (!bar) return;
  bar.hidden = !_brandPreviewReady || !!brandAuthed || !!brandLinkCtx || _brandCheckPending || !!_brandInviteCtx
    || !!_brandInviteLanding || !!_brandInviteNewCtx;
}

function initPreviewBar() {
  const sel = document.getElementById('previewScreen');
  sel.innerHTML = BRAND_PREVIEW_SCREENS
    .map(s => '<option value="' + brandEsc(s.hash) + '">' + brandEsc(s.label) + '</option>').join('');
  sel.addEventListener('change', () => { location.hash = '#' + sel.value; });

  document.getElementById('previewExpired').addEventListener('change', (e) => {
    setNotice('loginExpiredNotice', e.target.checked ? BRAND_EXPIRED_MSG : '');
  });
  document.getElementById('previewSetpwKind').addEventListener('change', (e) => {
    brandPreviewState.setpwKind = e.target.value;
    fillSetpwScreen(brandPreviewState.setpwKind);
  });
  document.getElementById('previewConfirmKind').addEventListener('change', (e) => {
    brandPreviewState.confirmKind = e.target.value;
    fillConfirmScreen(brandPreviewState.confirmKind, null);
  });
  _brandPreviewReady = true;
  updatePreviewVisibility();
}

function initBrandAuthEvents() {
  // ⚠️ 이 콜백 안에서 인증 연결을 await 하지 않는다(라이브러리 잠금과 엇갈린다)
  brandDb.auth.onAuthStateChange((event) => {
    if (event === 'SIGNED_OUT') {
      // 우리가 스스로 로그아웃한 것(로그아웃 단추·판정 뒤 정리)은 무시
      if (_brandSigningOut) return;
      // 그 밖 = 토큰 갱신 실패 등으로 세션이 끊김 → 로그인 시간 만료 안내
      // 대기 초대만 있는 계정(초대 수락 화면)도 세션이 있으므로 같이 본다
      if (brandAuthed || _brandInviteCtx) {
        _brandInviteCtx = null;
        setBrandAuthed(null);
        setNotice('loginExpiredNotice', BRAND_EXPIRED_MSG);
        goBrandScreen('login');
      }
    }
    // TOKEN_REFRESHED: 라이브러리가 저장 칸('reverb.brandAuth')을 갱신한다 — 화면은 할 일 없음
  });
  // 판정 실패 화면 「다시 시도」 — 세션 복원부터 다시
  const retryBtn = document.getElementById('checkRetryBtn');
  retryBtn.addEventListener('click', async () => {
    if (retryBtn.disabled) return;
    retryBtn.disabled = true; retryBtn.textContent = '확인하는 중…';
    try { await restoreBrandSession(); }
    finally { retryBtn.disabled = false; retryBtn.textContent = '다시 시도'; }
  });
  // 「계속하기」로 인증 서비스에 다녀온 뒤 뒤로 가기 — 브라우저가 멈춰 둔 화면(bfcache)이 잠긴 단추 그대로 돌아온다.
  //   그 링크는 한 번 쓰면 소진되므로 쓸 수 없는 링크 화면으로 보낸다.
  window.addEventListener('pageshow', (e) => {
    if (!e.persisted || !brandLinkCtx) return;
    const btn = document.getElementById('confirmBtn');
    const onConfirm = !document.querySelector('.brand-card[data-screen="confirm"]').hidden;
    if (onConfirm && btn.disabled) showBrandLinkInvalid();
  });
  // 「확인하지 못했어요」 화면의 탈출구 — 세션을 이 기기에서만 지우고 로그인 화면으로
  const checkLogoutBtn = document.getElementById('checkLogoutBtn');
  if (checkLogoutBtn) checkLogoutBtn.addEventListener('click', async (e) => {
    e.preventDefault();
    await brandSignOutLocal();
    document.getElementById('loginEmail').value = '';
    document.getElementById('loginPw').value = '';
    goBrandScreen('login');
  });
  // 「다른 계정으로 로그인」 — 앞서 넣은 이메일·비밀번호를 비운다
  document.querySelectorAll('[data-clear-login]').forEach(a => a.addEventListener('click', () => {
    document.getElementById('loginEmail').value = '';
    document.getElementById('loginPw').value = '';
  }));
}

async function bootBrand() {
  if (typeof IS_STAGING === 'undefined' || !IS_STAGING || !initBrandClients()) {
    showBrandScreen('closed');
    return;
  }
  initBrandLoginScreens();
  initBrandShell();
  initBrandAuthEvents();
  initPreviewBar();
  window.addEventListener('hashchange', routeBrand);

  // 메일 링크 착지가 해시 라우팅보다 먼저다(해시가 #access_token=… 이면 routeBrand 는 login 으로 떨어진다 — stale 3)
  const params = new URLSearchParams(location.search);
  // 초대 메일 링크(?link=…&kind=invite) — 일회용 인증 값이 없는 링크라 설정·재설정 착지와 따로 처리한다
  if (params.get('kind') === 'invite') {
    await handleBrandInviteLanding(params);
    return;
  }
  if (params.has('link') || params.has('mode')) {
    await handleBrandLinkLanding(params);
    return;
  }
  await restoreBrandSession();
}

bootBrand();
