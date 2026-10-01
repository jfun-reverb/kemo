// ══════════════════════════════════════
// AUTH — 로그인, 회원가입, 로그아웃
// ══════════════════════════════════════

function updateGnb() {
  const gnbRight = $('gnbRight');
  // GNB 우측은 항상 비움 (로그인/가입은 하단 CTA, Admin은 햄버거 메뉴)
  if (gnbRight) gnbRight.innerHTML = '';
  // 햄버거 메뉴 항목 갱신 (비로그인/관리자 분기)
  if (typeof renderNavMenu === 'function') renderNavMenu();
  if (typeof refreshNotifBadge === 'function') refreshNotifBadge();
  if (typeof updateFloatingAuthCta === 'function') updateFloatingAuthCta();
}

// 생년월일 년/월/일 select 채우기 (멱등). prefix 로 가입('signup')·응모 게이트('gate') 공용.
// 가입 폼 입력을 바꾸면 즉시 에러 문구를 지움 (값을 고쳐도 에러가 다음 제출까지 남는 문제 방지)
function bindSignupErrorClear() {
  const area = $('signupFormArea'), errEl = $('signupError');
  if (!area || !errEl || area.dataset.errClearBound) return;
  area.dataset.errClearBound = '1';
  const clear = () => { errEl.style.display = 'none'; };
  area.addEventListener('input', clear);   // 텍스트·이메일·비밀번호
  area.addEventListener('change', clear);  // 생년월일·성별 select
}

function populateBirthdateSelects(prefix) {
  prefix = prefix || 'signup';
  if (prefix === 'signup') bindSignupErrorClear();
  const yEl = $(prefix+'BirthYear'), mEl = $(prefix+'BirthMonth'), dEl = $(prefix+'BirthDay');
  if (!yEl || !mEl || !dEl || yEl.dataset.filled) return;
  const curY = new Date().getFullYear();
  for (let y = curY; y >= 1940; y--) {
    const o = document.createElement('option'); o.value = String(y); o.textContent = String(y); yEl.appendChild(o);
  }
  for (let mo = 1; mo <= 12; mo++) {
    const o = document.createElement('option'); o.value = String(mo); o.textContent = String(mo); mEl.appendChild(o);
  }
  for (let d = 1; d <= 31; d++) {
    const o = document.createElement('option'); o.value = String(d); o.textContent = String(d); dEl.appendChild(o);
  }
  yEl.dataset.filled = '1';
}

// 가입 이메일 도메인 점검(2026-10-01 — 운영 실측: `@gmail`·`@gmail.co`·`@i.softbank.jo` 로 가입한 4계정이
//   확인 메일을 영영 못 받아 로그인 못 한 채 남았다). 입력칸의 `type="email"` 은 웹 표준상 점 없는 도메인도 통과시키고
//   인증 서비스도 막지 않는다.
//   ①점이 없거나 끝이 글자 2자 이상이 아니면 **막는다**(메일이 갈 수 없는 주소)
//   ②흔한 오타 도메인은 **한 번 알리고**, 같은 주소로 다시 누르면 통과(사용자 결정 — 드물게 실재하는 도메인을 막지 않게)
//   ⚠️ 판정은 화면에서만 한다(서버 검사 아님) — 목적은 실수 방지다.
const SIGNUP_EMAIL_TYPO_DOMAINS = {
  'gmail.co': 'gmail.com', 'gmail.con': 'gmail.com', 'gmail.cm': 'gmail.com', 'gmail.om': 'gmail.com',
  'gmail.comm': 'gmail.com', 'gmail.cmo': 'gmail.com', 'gmail.jp': 'gmail.com', 'gmail.co.jp': 'gmail.com',
  'gmial.com': 'gmail.com', 'gamil.com': 'gmail.com', 'gmai.com': 'gmail.com', 'gmal.com': 'gmail.com', 'gnail.com': 'gmail.com',
  'yahoo.co.j': 'yahoo.co.jp', 'yahoo.co.jo': 'yahoo.co.jp', 'yahoo.co.jpp': 'yahoo.co.jp', 'yaho.co.jp': 'yahoo.co.jp',
  'yahooo.co.jp': 'yahoo.co.jp', 'yahoo.jp': 'yahoo.co.jp', 'yahoo.co': 'yahoo.co.jp',
  'icloud.co': 'icloud.com', 'icloud.con': 'icloud.com', 'icoud.com': 'icloud.com', 'iclod.com': 'icloud.com', 'icould.com': 'icloud.com',
  'i.softbank.jo': 'i.softbank.jp', 'softbank.jp': 'i.softbank.jp', 'i.softbank.co.jp': 'i.softbank.jp',
  'docomo.ne.j': 'docomo.ne.jp', 'docomo.ne.jo': 'docomo.ne.jp', 'docomo.co.jp': 'docomo.ne.jp', 'docomo.jp': 'docomo.ne.jp',
  'ezweb.ne.j': 'ezweb.ne.jp', 'ezweb.ne.jo': 'ezweb.ne.jp',
  'hotmail.co': 'hotmail.com', 'hotmail.con': 'hotmail.com', 'hotmial.com': 'hotmail.com',
  'outlook.co': 'outlook.com', 'outlook.con': 'outlook.com', 'outlok.com': 'outlook.com',
};
function signupEmailCheck(email) {
  const at = email.lastIndexOf('@');
  const domain = at > 0 ? email.slice(at + 1).toLowerCase() : '';
  if (!/^([a-z0-9-]+\.)+[a-z]{2,}$/.test(domain)) return { invalid: true };
  let suggest = SIGNUP_EMAIL_TYPO_DOMAINS[domain] || null;
  if (!suggest && /\.con$/.test(domain)) suggest = domain.replace(/\.con$/, '.com');
  return suggest ? { domain, suggest } : {};
}
// 오타 안내를 이미 본 주소 — 같은 주소로 다시 누르면 통과시킨다(주소를 고치면 다시 점검)
let _signupEmailTypoAcked = '';

// ══════════════════════════════════════
// 가입 이메일 인증번호 (사양서 2026-10-01 설계 ③ · 작업표 S1)
//   「認証する」 → 메일로 6자리 → 입력·「確認」 → 확인증(ticket) → 「登録する」 활성.
//   🔴 시각은 전부 서버 응답 값으로 그린다 — 이 파일에 유효 시간 숫자를 두지 않는다(완료 기준 4-2).
//   🔴 이메일을 고치면 인증이 풀린다 — 확인증은 그 주소 전용이다(경우의 수 6).
// ══════════════════════════════════════
const _signupCode = {
  email: '',            // 번호를 보낸(또는 확인한) 정규화 주소
  opened: false,        // 이번 화면에서 번호 칸이 열린 적이 있나(발송 제한 응답만 받았으면 열지 않는다)
  codeExpiresAt: 0,     // 번호 만료(ms)
  resendAt: 0,          // 재발송 가능(ms)
  ticket: '',           // 확인증 원문
  ticketExpiresAt: 0,   // 확인증 만료(ms)
  busy: false,
  submitting: false,    // 「登録する」 처리 중
  timer: null,
};
function _signupNormEmail(v) { return String(v || '').trim().toLowerCase(); }
function _signupMs(iso) { const n = iso ? Date.parse(iso) : NaN; return isNaN(n) ? 0 : n; }
function _signupFmtRemain(ms) {
  const s = Math.max(0, Math.ceil(ms / 1000));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}
function _signupCodeMsg(text, kind) {
  const el = $('signupCodeMsg'); if (!el) return;
  el.className = 'signup-code-msg' + (kind ? ' is-' + kind : '');
  el.textContent = text || '';
  el.style.display = text ? 'block' : 'none';
}
function _signupHasValidTicket() {
  return !!_signupCode.ticket && _signupCode.ticketExpiresAt > Date.now()
    && _signupCode.email === _signupNormEmail($('signupEmail')?.value);
}
function _signupSyncSubmit() {
  const ok = _signupHasValidTicket();
  const btn = $('signupBtn'); if (btn && !_signupCode.submitting) btn.disabled = !ok;
  const hint = $('signupNeedVerify'); if (hint) hint.style.display = ok ? 'none' : 'block';
}
// 1초마다 — 남은 시간·재발송 대기·확인증 만료를 다시 그린다
function _signupTick() {
  const now = Date.now();
  const timer = $('signupCodeTimer');
  const resend = $('signupCodeResendBtn');
  const input = $('signupCodeInput');
  const confirmBtn = $('signupCodeConfirmBtn');
  if (_signupCode.ticket) {
    if (_signupCode.ticketExpiresAt <= now) {
      // 확인증 만료 — 인증을 풀고 다시 받게 한다
      resetSignupEmailVerification(false);
      _signupCodeMsg(t('auth.signup.code.ticketExpired'), 'error');
    }
    _signupSyncSubmit();
    return;
  }
  if (_signupCode.opened) {
    const left = _signupCode.codeExpiresAt - now;
    if (left > 0) {
      if (timer) timer.textContent = t('auth.signup.code.remaining').replace('{time}', _signupFmtRemain(left));
      if (input) input.disabled = false;
    } else {
      if (timer) timer.textContent = t('auth.signup.code.expired');
      if (input) input.disabled = true;
      if (confirmBtn) confirmBtn.disabled = true;
    }
  }
  if (resend) {
    const wait = _signupCode.resendAt - now;
    if (wait > 0) {
      resend.disabled = true;
      const sec = Math.ceil(wait / 1000);
      resend.textContent = sec > 90
        ? t('auth.signup.code.resendWaitMin').replace('{min}', String(Math.ceil(sec / 60)))
        : t('auth.signup.code.resendWait').replace('{sec}', String(sec));
    } else {
      resend.disabled = _signupCode.busy;
      resend.textContent = t('auth.signup.code.resendBtn');
    }
  }
  _signupSyncSubmit();
}
function _signupStartTimer() {
  if (_signupCode.timer) return;
  _signupCode.timer = setInterval(() => {
    // 가입 화면을 떠나면 멈춘다
    if (!$('page-signup')?.classList.contains('active')) { clearInterval(_signupCode.timer); _signupCode.timer = null; return; }
    _signupTick();
  }, 1000);
}

// 가입 화면에 들어올 때(app.js navigate) — 진행 중이던 인증 상태가 있으면 타이머를 다시 켠다
function onSignupPageEnter() {
  if (_signupCode.opened || _signupCode.ticket || _signupCode.resendAt) _signupStartTimer();
  _signupTick();
}
// 이메일 칸을 고치면 — 인증 상태와 어긋나지 않게 정리한다
function onSignupEmailInput() {
  if (_signupCode.email && _signupCode.email !== _signupNormEmail($('signupEmail')?.value)) {
    resetSignupEmailVerification(false);
  }
  _signupSyncSubmit();
}
function onSignupCodeInput() {
  const input = $('signupCodeInput'); if (!input) return;
  const digits = input.value.replace(/\D/g, '').slice(0, 6);
  if (input.value !== digits) input.value = digits;
  const confirmBtn = $('signupCodeConfirmBtn');
  if (confirmBtn) confirmBtn.disabled = digits.length !== 6 || _signupCode.busy || _signupCode.codeExpiresAt <= Date.now();
}
// 「変更」 또는 주소를 고쳤을 때 — 인증을 처음 상태로
function resetSignupEmailVerification(focusEmail) {
  Object.assign(_signupCode, { email: '', opened: false, codeExpiresAt: 0, resendAt: 0, ticket: '', ticketExpiresAt: 0, busy: false });
  const email = $('signupEmail');
  if (email) email.readOnly = false;
  const show = (id, on) => { const el = $(id); if (el) el.style.display = on ? '' : 'none'; };
  show('signupEmailVerifyBtn', true); show('signupEmailChangeBtn', false);
  show('signupEmailVerified', false); show('signupCodeArea', false);
  const vb = $('signupEmailVerifyBtn'); if (vb) { vb.disabled = false; vb.textContent = t('auth.signup.code.verifyBtn'); }
  const input = $('signupCodeInput'); if (input) { input.value = ''; input.disabled = false; }
  const timer = $('signupCodeTimer'); if (timer) timer.textContent = '';
  _signupCodeMsg('');
  _signupSyncSubmit();
  if (focusEmail && email) email.focus();
}

// 「認証する」·「再送信」
async function requestSignupCodeFromForm(isResend) {
  if (_signupCode.busy) return;
  const errEl = $('signupError'); if (errEl) errEl.style.display = 'none';
  const raw = ($('signupEmail')?.value || '').trim();
  if (!raw) { _signupCodeMsg(t('authError.enterEmail'), 'error'); $('signupEmail')?.focus(); return; }
  // 도메인 점검 — 메일이 갈 수 없는 주소는 보내지 않는다(작업표 S1 주의)
  const check = signupEmailCheck(raw);
  if (check.invalid) { _signupCodeMsg(t('authError.emailInvalid'), 'error'); $('signupEmail')?.focus(); return; }
  if (check.suggest && _signupEmailTypoAcked !== raw) {
    _signupEmailTypoAcked = raw;
    _signupCodeMsg(t('authError.emailTypoVerify').replace('{typed}', check.domain).replace('{suggest}', check.suggest), 'notice');
    $('signupEmail')?.focus(); return;
  }
  const email = _signupNormEmail(raw);
  // 다른 주소로 다시 보내면 앞의 번호 상태는 버린다
  if (_signupCode.email && _signupCode.email !== email) resetSignupEmailVerification(false);

  // 개발서버 전용 — 메일 대신 「받은 메일」 새 창(서버·화면 두 겹 잠금, 2026-10-01 사용자 결정).
  //   🔴 창은 **누른 순간 바로** 연다 — 응답을 기다린 뒤 열면 브라우저가 팝업으로 막는다.
  //   운영(IS_STAGING=false)에서는 창을 아예 안 연다.
  let devMailWin = null;
  if (typeof IS_STAGING !== 'undefined' && IS_STAGING) {
    devMailWin = window.open('', 'reverbDevSignupMail', 'width=640,height=760');
    try { devMailWin?.document.write('<p style="font-family:sans-serif;color:#888;padding:24px">送信中…</p>'); } catch(_) {}
  }

  _signupCode.busy = true;
  const vb = $('signupEmailVerifyBtn');
  const resend = $('signupCodeResendBtn');
  if (vb) { vb.disabled = true; vb.innerHTML = '<span class="spinner"></span>'; }
  if (resend) resend.disabled = true;
  const r = (typeof requestSignupCode === 'function') ? await requestSignupCode(email) : null;
  _signupCode.busy = false;
  if (vb) { vb.disabled = false; vb.textContent = t('auth.signup.code.verifyBtn'); }

  _showDevSignupMail(devMailWin, r && r.devMail);
  if (!r || r.error) {
    // 통신 실패·메일 실패·서버 오류 — 같은 안내(다시 누르면 된다)
    _signupCodeMsg(t('auth.signup.code.sendFailed'), 'error');
    _signupTick();
    return;
  }
  _signupCode.email = email;
  _signupCode.resendAt = _signupMs(r.resendAvailableAt);
  if (r.status === 'rate_limited') {
    // 🔴 번호 칸이 이미 열려 있으면 그대로(옛 번호는 아직 입력 가능), 처음이면 열지 않는다
    _signupCodeMsg(t('auth.signup.code.rateLimited'), 'notice');
    _signupStartTimer(); _signupTick();
    return;
  }
  _signupCode.opened = true;
  _signupCode.codeExpiresAt = _signupMs(r.codeExpiresAt);
  const area = $('signupCodeArea'); if (area) area.style.display = '';
  const input = $('signupCodeInput'); if (input) { input.value = ''; input.disabled = false; input.focus(); }
  onSignupCodeInput();
  _signupCodeMsg(t('auth.signup.code.sent'));
  _signupStartTimer(); _signupTick();
}

// 개발서버 전용 「받은 메일」 창 채우기 — 메일이 없으면(발송 제한·실패·운영) 창을 닫는다.
//   html 은 우리 서버 함수가 만든 메일 본문 그대로다(운영 메일과 같은 양식). 개발서버 화면에서만 들어온다.
function _showDevSignupMail(win, devMail) {
  if (!win) return;
  if (!devMail) { try { win.close(); } catch(_) {} return; }
  try {
    const d = win.document;
    d.open();
    d.write('<!DOCTYPE html><html lang="ja"><head><meta charset="UTF-8"><title>[DEV] ' + esc(devMail.subject || '') + '</title></head>'
      + '<body style="margin:0;padding:20px;background:#F5F5F7;font-family:sans-serif">'
      + '<div style="max-width:600px;margin:0 auto 12px;padding:10px 14px;background:#FFF7E6;border:1px solid #FFD591;border-radius:8px;font-size:12px;color:#874D00;line-height:1.6">'
      + '<b>開発サーバー専用</b> — 実際のメールは送られていません。運営サーバーでは、この内容がメールで届きます。</div>'
      + '<div style="max-width:600px;margin:0 auto 12px;font-size:12px;color:#555;line-height:1.7">'
      + '<div><b>To:</b> ' + esc(devMail.to || '') + '</div><div><b>件名:</b> ' + esc(devMail.subject || '') + '</div></div>'
      + '<div style="max-width:600px;margin:0 auto">' + devMail.html + '</div></body></html>');
    d.close();
  } catch(_) { /* 창이 이미 닫혔으면 무시 */ }
}

// 「確認」
async function verifySignupCodeFromForm() {
  if (_signupCode.busy) return;
  const code = ($('signupCodeInput')?.value || '').replace(/\D/g, '');
  if (code.length !== 6 || !_signupCode.email) return;
  _signupCode.busy = true;
  const cb = $('signupCodeConfirmBtn');
  if (cb) { cb.disabled = true; cb.innerHTML = '<span class="spinner"></span>'; }
  const r = (typeof verifySignupCode === 'function') ? await verifySignupCode(_signupCode.email, code) : null;
  _signupCode.busy = false;
  if (cb) cb.textContent = t('auth.signup.code.confirmBtn');
  onSignupCodeInput();

  if (!r) { _signupCodeMsg(t('auth.signup.code.verifyFailed'), 'error'); return; }
  if (r.ok) {
    _signupCode.ticket = r.ticket;
    _signupCode.ticketExpiresAt = _signupMs(r.ticketExpiresAt);
    const email = $('signupEmail'); if (email) email.readOnly = true;
    const show = (id, on) => { const el = $(id); if (el) el.style.display = on ? '' : 'none'; };
    show('signupCodeArea', false); show('signupEmailVerifyBtn', false);
    show('signupEmailChangeBtn', true); show('signupEmailVerified', true);
    _signupCodeMsg('');
    _signupStartTimer(); _signupTick();
    return;
  }
  const input = $('signupCodeInput');
  if (r.reason === 'mismatch' && r.attemptsLeft > 0) {
    _signupCodeMsg(t('auth.signup.code.mismatch').replace('{n}', String(r.attemptsLeft)), 'error');
    if (input) { input.select?.(); input.focus(); }
    return;
  }
  if (r.reason === 'contact_support') {
    // 다른 기록이 있는 옛 미인증 계정 — 번호 칸을 닫고 연락처를 준다(사양서 설계 ③).
    //   ⚠️ innerHTML 은 번역 파일 고정 문구 + 고정 링크뿐 — 사용자 입력이 섞이지 않는다
    const area = $('signupCodeArea'); if (area) area.style.display = 'none';
    _signupCode.opened = false;
    const el = $('signupCodeMsg');
    if (el) {
      el.className = 'signup-code-msg is-error';
      el.innerHTML = esc(t('auth.signup.code.contactSupport'))
        + ' <a href="https://line.me/R/ti/p/@reverb.jp" target="_blank" rel="noopener">LINE @reverb.jp</a>';
      el.style.display = 'block';
    }
    return;
  }
  if (r.reason === 'expired') {
    _signupCode.codeExpiresAt = 0; _signupTick();
    _signupCodeMsg(t('auth.signup.code.expiredMsg'), 'error');
    return;
  }
  // 틀린 횟수 상한(mismatch 0회 남음)·locked·no_code — 이 번호는 더 못 쓴다. 다시 받게 한다
  if (r.reason === 'mismatch' || r.reason === 'locked' || r.reason === 'no_code') {
    _signupCode.codeExpiresAt = 0; _signupTick();
    _signupCodeMsg(t('auth.signup.code.locked'), 'error');
    return;
  }
  _signupCodeMsg(t('auth.signup.code.verifyFailed'), 'error');
}

async function handleSignup(e) {
  e.preventDefault();
  const name = ($('signupNameKanji')?.value||'').trim();
  const nameKana = ($('signupNameKana')?.value||'').trim();
  const birthYear = $('signupBirthYear')?.value || '';
  const birthMonth = $('signupBirthMonth')?.value || '';
  const birthDay = $('signupBirthDay')?.value || '';
  const gender = $('signupGender')?.value || '';
  const email = $('signupEmail').value.trim();
  const pw = $('signupPw').value;
  const pw2 = $('signupPw2').value;
  const errEl = $('signupError');
  const btn = $('signupBtn');

  errEl.style.display='none';
  if (!name || !nameKana) { errEl.textContent=t('authError.enterName'); errEl.style.display='block'; return; }
  // 생년월일 필수 + 유효 날짜 + 만 18세 이상 검증
  if (!birthYear || !birthMonth || !birthDay) { errEl.textContent=t('authError.enterBirthdate'); errEl.style.display='block'; return; }
  const birthdate = `${birthYear}-${String(birthMonth).padStart(2,'0')}-${String(birthDay).padStart(2,'0')}`;
  const bdObj = new Date(birthdate + 'T00:00:00+09:00');
  if (isNaN(bdObj.getTime()) || (bdObj.getMonth()+1) !== Number(birthMonth) || bdObj.getDate() !== Number(birthDay)) {
    errEl.textContent=t('authError.invalidBirthdate'); errEl.style.display='block'; return;
  }
  const age = calcAgeFromBirthdate(birthdate);
  if (age === null || age < AGE_POLICY_MIN_AGE) { errEl.textContent=t('authError.under18'); errEl.style.display='block'; return; }
  // 성별 필수 (回答しない 포함 4종 — 빈 값만 차단)
  if (!gender) { errEl.textContent=t('authError.enterGender'); errEl.style.display='block'; return; }
  if (pw !== pw2) { errEl.textContent = (typeof t==='function') ? t('auth.pwMismatch', 'パスワードが一致しません。') : 'パスワードが一致しません。'; errEl.style.display='block'; return; }
  const pwErr = validatePasswordPolicy(pw);
  if (pwErr) { errEl.textContent = pwErr; errEl.style.display='block'; return; }
  if (!$('agreeTerms')?.checked || !$('agreePrivacy')?.checked) {
    errEl.textContent = t('authError.agreeRequired');
    errEl.style.display = 'block';
    return;
  }
  const marketingOptIn = !!$('agreeMarketing')?.checked;
  // 이메일 인증번호를 확인했어야 한다(결정 2). 도메인 점검은 「認証する」 단계에서 이미 했다.
  //   ⚠️ 확인증은 그 주소 전용 — 관문(마이그레이션 497)이 정규화 주소로 대조하므로 같은 정규화로 보낸다
  if (!_signupHasValidTicket()) {
    errEl.textContent = t('auth.signup.code.needVerify'); errEl.style.display = 'block';
    _signupSyncSubmit(); $('signupEmail')?.focus(); return;
  }
  const signupEmail = _signupCode.email;
  const signupTicket = _signupCode.ticket;

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';
  _signupCode.submitting = true;

  const nowIso = new Date().toISOString();
  const userData = {
    email, name, name_kanji: name, name_kana: nameKana,
    birthdate, gender,
    terms_agreed_at: nowIso,
    privacy_agreed_at: nowIso,
    marketing_opt_in: marketingOptIn,
    marketing_agreed_at: marketingOptIn ? nowIso : null,
    created_at: nowIso
  };

  // 가입 버튼을 되살리는 자리가 여럿이라 한 곳에 모은다(확인증이 살아 있을 때만 켠다)
  const _restoreBtn = () => { _signupCode.submitting = false; btn.textContent = t('auth.signup.btn'); _signupSyncSubmit(); };

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    _restoreBtn(); return;
  }

  // 탈퇴 후 재가입 제한 기간인가 (마이그레이션 361·362 — 작업 11)
  //   ⚠️ 이 대조는 **방어선이 아니다** — 막는 것은 서버 트리거(362)다. 여기서 먼저
  //     걸러 주는 이유는 셋이다: ①서버 거부는 인증 서비스가 일반 오류로 덮어 회원이
  //     이유를 알 수 없다 ②그 오류가 관리자 오류 로그에 「미해결」로 쌓인다
  //     ③그런데 그 오류는 「정상 거부」 목록에 넣을 수 없다(일반 문구를 넣으면 진짜
  //     데이터베이스 장애까지 함께 침묵한다).
  //   ⚠️ 조회에 실패하면 **가입을 막지 않는다** — 서버가 최종 방어선이고, 통신 장애로
  //     정상 가입을 막는 쪽이 훨씬 나쁘다.
  if (typeof isEmailWithdrawalBlocked === 'function') {
    const blocked = await isEmailWithdrawalBlocked(signupEmail);
    if (blocked === true) {
      // ⚠️ 여기만 innerHTML 을 쓴다 — 연락처를 **누를 수 있는 링크**로 줘야 하기
      //   때문이다(2026-08-20 사용자 지시: 「안 되면 어디로 연락하는지 같이 안내」).
      //   넣는 값은 번역 파일의 고정 문구라 사용자 입력이 섞이지 않는다.
      showSignupFailure(errEl);
      errEl.style.display='block';
      _restoreBtn();
      return;
    }
  }

  // 메타 픽셀 새로고침 보류(작업표 어긋남 ⑪) — 가입 응답에 세션이 오면 그 순간 픽셀 로그인 재조회가 돌고,
  //   조회가 실패하면 화면이 곧바로 새로고침되어 가입 직후 화면과 줄에 쌓인 `confirmed` 가 사라진다.
  //   로그인 화면과 같은 짝 — 일반 회원으로 끝나는 갈래에서만 풀고, 오류 경로는 시간이 지나면 저절로 풀린다.
  if (typeof metaPixelHoldReload === 'function') metaPixelHoldReload();
  let _signupLoggedIn = false;
  try {
    // 🔴 폼 값을 계정 정보에 실어 보낸다 — **이게 유일한 저장 경로다.**
    //    받는 쪽은 가입 트리거(마이그레이션 382·420)이고, 트리거가 회원 행에 옮긴 **직후 이 자리를 지운다.**
    //    ⚠️ `created_at` 은 보내지 않는다 — 서버가 계정 생성 시각을 쓴다(브라우저 시계를 믿지 않는다).
    //    🔴 `signup_ticket` = 인증번호 확인증. 가입 관문(마이그레이션 497)이 대조해 맞으면 그 자리에서
    //       인증 완료로 표시하고 이 열쇠를 지운다. 이메일은 확인증을 받은 **정규화 주소 그대로** 보낸다.
    const {data, error} = await db.auth.signUp({
      email: signupEmail, password: pw,
      options: { data: {
        name, name_kanji: name, name_kana: nameKana,
        birthdate, gender,
        terms_agreed_at: nowIso,
        privacy_agreed_at: nowIso,
        marketing_opt_in: marketingOptIn,
        marketing_agreed_at: marketingOptIn ? nowIso : null,
        signup_ticket: signupTicket
      } }
    });
    // 계정 열거 방지: 서버 원문(영문) 노출 금지, 모호한 일반 메시지로 통일. 원문은 기록해 둔다.
    //   ⚠️ 관문이 거부(확인증 무효·강제)해도 인증 서비스가 일반 오류로 덮어 여기로 온다(362 와 같다)
    //   ⚠️ 확인증은 버리지 않는다 — 거부되면 그 트랜잭션이 되돌아가 사용 표시도 안 남는다(살아 있는 확인증이면 다시 눌러도 된다)
    if (error) { logAppError('handleSignup', error); showSignupFailure(errEl); _restoreBtn(); return; }
    // 확인증은 한 번만 쓴다 — 결과와 관계없이 버린다(성공이면 서버가 사용 표시를 했다)
    _signupCode.ticket = ''; _signupCode.ticketExpiresAt = 0;
    if (!data?.user?.id) { showSignupFailure(errEl); _restoreBtn(); return; }

    // ① 이미 가입된 주소 — 인증 서비스가 오류 대신 **신원 목록이 빈** 가짜 사용자를 돌려준다(계정 열거 방지).
    //    자동 로그인을 시도하지 않고 일반 실패 + 로그인·비밀번호 찾기 안내. 픽셀도 안 보낸다(새 가입이 아니다)
    if (Array.isArray(data.user.identities) && data.user.identities.length === 0) {
      showSignupFailure(errEl);
      errEl.insertAdjacentHTML('beforeend', '<br>' + esc(t('authError.alreadyRegisteredHint')));
      resetSignupEmailVerification(false);   // 확인증을 썼다 — 「認証済み」 표시를 남기지 않는다
      _restoreBtn(); return;
    }
    const confirmed = !!data.user.email_confirmed_at;
    // 메타 픽셀 — 그 자리에서 인증 완료면 `confirmed` 한 번(새 방식), 아니면 옛 흐름처럼 `pending_email`
    if (typeof trackMetaPixelEvent === 'function') {
      trackMetaPixelEvent(META_PIXEL_EVENTS.COMPLETE_REGISTRATION,
        { status: confirmed ? META_PIXEL_REG_STATUS.CONFIRMED : META_PIXEL_REG_STATUS.PENDING_EMAIL });
    }

    if (data.session) {
      // ② 세션이 왔다 — 그대로 로그인 상태(단계 0 실측상 새 방식의 주 경로)
      currentUser = data.user;
    } else if (confirmed) {
      // ③ 세션은 없지만 인증 완료 — 방금 입력한 값으로 곧바로 로그인한다(사용자에게 묻지 않는다)
      const {data: li, error: liErr} = await db.auth.signInWithPassword({ email: signupEmail, password: pw });
      if (liErr || !li?.user) {
        if (liErr) logAppError('handleSignup.autoLogin', liErr);
        resetSignupEmailVerification(false);
        _restoreBtn();
        toast(t('auth.signup.doneLogin'), 'success');
        const le = $('loginEmail'); if (le) le.value = signupEmail;
        navigate('login');
        return;
      }
      currentUser = li.user;
    } else {
      // ④ 인증 완료가 아니다(옛 흐름 구간 — 관문이 대기이고 대조를 통과하지 못한 가입) → 메일 확인 안내
      resetSignupEmailVerification(false);
      _restoreBtn();
      errEl.style.display='none';
      $('signupFormArea').style.display='none';
      $('signupConfirmMsg').style.display='block';
      return;
    }
    // 🔴 여기서 회원 행을 쓰지 않는다 — 가입 트리거(마이그레이션 382)가 이미 넣었다.
    //    `upsertInfluencer` 는 행 전체를 대체해 트리거가 넣은 값을 되돌린다(created_at 등).
    currentUserProfile = {id: currentUser.id, ...userData, email: signupEmail};
    _signupLoggedIn = true;
  } catch(e) {
    // 영문 예외 메시지 노출 금지 — 일반 안내로 통일
    logAppError('handleSignup', e);
    showSignupFailure(errEl);
    _restoreBtn(); return;
  }
  if (!_signupLoggedIn) { _restoreBtn(); return; }

  toast(t('auth.toast.welcome'),'success');
  updateGnb();
  resetSignupEmailVerification(false);
  _restoreBtn();
  // 초대 링크로 들어와 가입한 경우 그 캠페인으로 되돌린다(사양서 §2-8 U7).
  //   안 돌려보내면 가입만 하고 이탈한다 — 첫날 초대분이 그대로 새는 자리다.
  const _toInvite = typeof consumeInviteReturn === 'function' && consumeInviteReturn();
  // 일반 회원으로 끝났다 — 픽셀 새로고침 보류를 푼다(초대 복귀 **뒤** — 로그인 화면과 같은 순서)
  if (typeof metaPixelReleaseReload === 'function') metaPixelReleaseReload();
  if (_toInvite) return;
  navigate('home');
}

async function handleLogin(e) {
  e.preventDefault();
  const email = $('loginEmail').value.trim();
  const pw = $('loginPw').value;
  const errEl = $('loginError');
  const btn = $('loginBtn');
  errEl.style.display='none'; btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';
  // 가입 확인 착지가 남긴 초록 안내(#loginNotice)는 로그인을 시도하는 순간 걷는다
  const noticeEl = $('loginNotice'); if (noticeEl) noticeEl.style.display='none';

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
  }

  // 메타 픽셀 새로고침 보류(흐름 6) — 로그인 요청 도중 픽셀 재조회가 먼저 끝나 새로고침하면 아래 관리자
  //   이동(/admin/)이 실행되지 못한다. 일반 회원으로 끝나는 갈래에서만 풀고, 오류 경로는 시간이 지나면 풀린다.
  if (typeof metaPixelHoldReload === 'function') metaPixelHoldReload();
  try {
    const {data, error} = await db.auth.signInWithPassword({email, password: pw});
    if (error) {
      // 비밀번호 오입력·메일 미확인은 정상 거부로 자동 분류된다(shared.js 패턴 목록).
      logAppError('handleLogin', error);
      if (error.message?.includes('Email not confirmed')) {
        errEl.textContent=t('authError.emailUnverifiedDetail');
      } else {
        errEl.textContent=t('authError.checkCredentials');
      }
      errEl.style.display='block';
      btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
    }
    currentUser = data.user;
    // 메타 픽셀 로그인 재판정(흐름 6) — app.js 로그인 처리기와 둘 다 부르고 함수가 같은 계정 중복을 거른다
    if (typeof notifyMetaPixelSignedIn === 'function') notifyMetaPixelSignedIn(data.user.id);
    // 관리자 테이블에서 확인
    const {data:adminData} = await db.from('admins').select('*').eq('auth_id', data.user.id).maybeSingle();
    if (adminData) {
      currentUser._isAdmin = true;
      currentUserProfile = {name: adminData.name || 'Admin', email};
      toast(t('auth.toast.adminLogin'),'success'); updateGnb();
      window.location.href = '/admin/';
    } else {
      const {data:profile, error:profileErr} = await db.from('influencers').select('*').eq('id', data.user.id).maybeSingle();
      currentUserProfile = profile || null;
      // 🔴 조회 실패와 0건을 가른다 — 2026-09-10 운영에서 로그인 직후 조회가 비로그인으로 나가
      //    401 이 「0건」으로 읽혀 삽입까지 갔다(조사 문서 2026-09-10-signup-confirm-link-misrouted-to-reset).
      //    실패면 삽입하지 않고 기록만 남긴 채 진행한다(정상 거부 아님 — 오류 로그 배지에 뜬다, 의도).
      if (profileErr) {
        logAppError('handleLogin.profileFetch', profileErr);
      } else if (!profile) {
      // 프로필이 없으면 기본 프로필 생성 (회원가입 시 RLS로 실패한 경우)
        try {
          await upsertInfluencer({id: data.user.id, email, created_at: new Date().toISOString()});
          currentUserProfile = {id: data.user.id, email};
        } catch(e) {
          // ⚠️ 프로필 없는 계정을 되살리는 마지막 구제 경로다. 여기까지 실패하면
          //    그 사람은 프로필 없이 앱을 쓰게 되는데 지금까지 무음이었다.
          logAppError('handleLogin.upsertInfluencer', e);
        }
      }
      toast(t('auth.toast.welcomeBack'),'success'); updateGnb();
      // 초대 링크로 들어와 로그인한 경우 그 캠페인으로 되돌린다(가입 경로와 같은 이유).
      const returnedToInvite = typeof consumeInviteReturn === 'function' && consumeInviteReturn();
      // 일반 회원으로 끝났다 — 메타 픽셀 새로고침 보류를 푼다. 관리자 갈래에서는 부르지 않는다.
      //   ⚠️ 초대 복귀 **뒤에** 푼다 — 복귀가 주소를 캠페인 상세로 바꿔 두어야 새로고침해도 그 자리로 온다
      //      (복귀 기억은 한 번 쓰면 지워져, 먼저 새로고침하면 캠페인으로 못 돌아간다).
      if (typeof metaPixelReleaseReload === 'function') metaPixelReleaseReload();
      if (returnedToInvite) return;
      navigate('home');
    }
  } catch(e) {
    logAppError('handleLogin', e);
    errEl.textContent=t('authError.genericError'); errEl.style.display='block';
  }
  btn.disabled=false; btn.textContent=t('auth.login.btn');
}

async function handleLogout() {
  if (db) { try { await db.auth.signOut(); } catch(e){} }
  currentUser=null; currentUserProfile=null;
  toast(t('auth.toast.loggedOut')); updateGnb(); navigate('home');
}

// ── 비밀번호 재설정 ──
// 재전송 대기 동안 버튼을 잠근다. 시간이 지나면 스스로 풀린다.
//   ⚠️ 남은 초를 버튼에 **세어 보여주지 않는다** — 문구에 안 쓰는 이유와 같다.
//   ⚠️ 상한 300초는 **정책이 아니라 방어값**이다. 대기 시간은 인증 설정 화면에 항목이 없어
//      (2026-08-31 운영 확인 — Rate Limits 는 전부 시간당·5분당 「횟수」다) 근거로 삼을 값이 없다.
//      관측된 것은 43초·50초 둘뿐이라, 서버가 이상한 값을 줘도 영영 안 잠기게만 막는다.
let _forgotCooldownTimer = null;
function startForgotCooldown(seconds) {
  const btn = $('forgotBtn');
  if (!btn) return;
  if (_forgotCooldownTimer) { clearInterval(_forgotCooldownTimer); _forgotCooldownTimer = null; }
  let left = Math.min(Math.max(Number(seconds) || 60, 1), 300);
  btn.disabled = true;
  btn.textContent = t('auth.forgot.waitingBtn');
  _forgotCooldownTimer = setInterval(() => {
    left -= 1;
    if (left > 0) return;
    clearInterval(_forgotCooldownTimer);
    _forgotCooldownTimer = null;
    btn.disabled = false;
    btn.textContent = t('auth.forgot.btn');
  }, 1000);
}

async function handleForgotPassword(e) {
  e.preventDefault();
  const email = $('forgotEmail').value.trim();
  const errEl = $('forgotError');
  const successEl = $('forgotSuccess');
  const btn = $('forgotBtn');

  // 지난 호출이 주황 안내(form-notice)로 바꿔 놨을 수 있다 — **매번 기본값으로 되돌린다.**
  //   경로마다 되돌리면 빠뜨리는 곳이 생긴다(실제로 `!db`·catch 두 갈래를 빠뜨렸다).
  errEl.className = 'form-error';
  errEl.style.display = 'none';
  successEl.style.display = 'none';

  if (!db) {
    errEl.textContent = t('authError.serverError');
    errEl.style.display = 'block';
    return;
  }

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>';

  try {
    // 보조 클라이언트로 요청 — 다른 기기에서도 열 수 있는 토큰을 받기 위함(supabase.js 주석 참조).
    // redirectTo 는 일부러 넘기지 않는다: 넘기면 인증 서버가 그 주소를 검증·정규화하면서
    //   `#` 뒷부분을 통째로 버려(`.../#` 만 남음) 착지 화면을 못 찾는다.
    //   되돌아갈 주소는 메일 서식이 `{{ .SiteURL }}/#reset-pw?token_hash=...` 로 직접 만든다.
    const authClient = (typeof dbAuthRequest !== 'undefined' && dbAuthRequest) ? dbAuthRequest : db;
    const {error} = await authClient.auth.resetPasswordForEmail(email);
    if (error) {
      // 영문 서버 메시지·계정 존재 힌트 노출 금지 — 일반 안내로 통일.
      //   ⚠️ 인플루언서 비밀번호 찾기는 실제로 고장 난 적이 있는 경로다(2026-07-20).
      //      화면 문구는 그대로 두고 원인만 남긴다.
      logAppError('handleForgotPassword', error);
      // 연타 방지(재전송 대기)는 **실패가 아니라 「아직 이르다」**는 안내다. 일반 문구로 덮으면
      //   몇 초 기다려야 하는지 몰라 회원이 계속 누른다 — 운영 오류 로그에 그 흔적이 5회 있다.
      //   위 handleResetPassword 의 「예전과 같은 비밀번호」와 **같은 방식**으로 갈라낸다.
      //   ⚠️ `error.code` 는 **보조로만** 쓴다 — 오류 로그의 코드 열이 전부 비어 있어(수집기가
      //      `ERR_` 형식만 뽑는다) 이 오류의 실제 code 값은 확인되지 않았다. 확인된 근거는
      //      메시지 정규식 쪽이다(운영 실측 문구: `... after 43 seconds.` · `... after 50 seconds.`).
      //   ⚠️ 계정 열거 방지에 안 걸린다 — 이 대기는 **계정 존재와 무관하게** 걸리므로
      //      「잠시 후 다시」를 보여줘도 계정 정보가 새지 않는다.
      const _msg = String(error.message || '');
      const _wait = _msg.match(/after (\d+) seconds?/i);
      if (_wait || /security purposes/i.test(_msg)
          || String(error.code || '') === 'over_email_send_rate_limit') {
        // ⚠️ 빨강(오류)으로 두면 문구가 「실패가 아니다」라고 말하는데 화면은 실패라고 말한다.
        //    주황 안내로 바꾼다. **같은 요소를 다른 오류가 재사용하므로 아래에서 반드시 되돌린다.**
        errEl.className = 'form-notice';
        errEl.textContent = t('auth.forgot.tooSoon');
        errEl.style.display = 'block';
        // ⚠️ 남은 초는 **문구에 안 쓴다** — 정확히 보여주면 회원이 초를 세고 있다가 누른다.
        //    뽑은 초는 **버튼을 잠그는 시간**으로만 쓴다.
        startForgotCooldown(_wait ? Number(_wait[1]) : 60);
        // 🔴 여기서 반드시 return — 함수 끝의 `btn.disabled = false` 가 잠금을 즉시 풀어 버린다.
        return;
      }
      // 🔴 「잠시 후 다시」가 아닌 오류도 **성공과 같은 문구**를 띄운다(사양서 결정 6 · 완료 기준 16).
      //   가입 관문(마이그레이션 497)이 미인증 계정의 재설정 요청을 거부하면 여기로 오는데, 문구가 다르면
      //   「그 주소에 미인증 계정이 있다」가 드러난다. 진짜 고장도 같은 문구가 되지만 위에서 오류 로그에 남겼다.
      successEl.textContent = t('auth.forgot.successMsg');
      successEl.style.display = 'block';
      $('forgotForm').reset();
    } else {
      successEl.textContent = t('auth.forgot.successMsg');
      successEl.style.display = 'block';
      $('forgotForm').reset();
    }
  } catch (err) {
    // 통신 예외도 같다(완료 기준 16) — 오류 로그에만 남긴다
    logAppError('handleForgotPassword', err);
    successEl.textContent = t('auth.forgot.successMsg');
    successEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = t('auth.forgot.btn');
}

async function handleResetPassword(e) {
  e.preventDefault();
  const pw = $('resetPwNew').value;
  const pw2 = $('resetPwConfirm').value;
  const errEl = $('resetPwError');
  const btn = $('resetPwBtn');

  errEl.style.display = 'none';

  const pwErr = validatePasswordPolicy(pw);
  if (pwErr) {
    errEl.textContent = pwErr;
    errEl.style.display = 'block';
    return;
  }
  if (pw !== pw2) {
    errEl.textContent = (typeof t==='function') ? t('auth.pwMismatch') : 'パスワードが一致しません';
    errEl.style.display = 'block';
    return;
  }

  if (!db) {
    errEl.textContent = t('authError.serverError');
    errEl.style.display = 'block';
    return;
  }

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>';

  try {
    const {error} = await db.auth.updateUser({password: pw});
    if (error) {
      // 영문 서버 메시지 노출 금지 — 일반 안내로 통일
      logAppError('handleResetPassword', error);
      // 「세션 없음」은 링크가 만료됐거나 이미 쓰인 것이다. 일반 문구로 덮으면
      //   사용자는 **무엇을 해야 할지 알 수 없다**(2026-08-08 운영 오류 1건 — 아이폰 사파리).
      //   이미 있는 만료 안내 화면(다시 보내기 버튼 포함)으로 보낸다.
      if (/Auth session missing/i.test(String(error.message || ''))) {
        const _f = $('resetPwFormWrap'), _x = $('resetPwExpired');
        if (_f && _x) { _f.style.display = 'none'; _x.style.display = ''; }
        else { errEl.textContent = t('authError.genericError'); errEl.style.display = 'block'; }
        try { sessionStorage.removeItem('reverb.recovery'); } catch(_e) {}
        btn.disabled = false;
        btn.textContent = t('auth.reset.btn');
        return;
      }
      // 「예전과 같은 비밀번호」도 같은 이유로 갈라낸다 — 이 화면은 지금 쓰는 비밀번호를
      //   입력받지 않아 화면에서 미리 막을 수 없고, **서버가 거부한 뒤에야** 알 수 있다.
      //   일반 문구로 덮으면 왜 안 되는지 몰라 같은 비밀번호를 다시 넣게 된다 —
      //   운영에서 한 사람이 **5번 반복**했다(2026-08-11~12 오류 로그).
      //   ⚠️ 서버 영문 메시지를 그대로 보여주지 않는다. 마이페이지 비밀번호 변경이 이미
      //      쓰는 번역 문구(auth.pwSameAsCurrent)를 **같이** 쓴다 — 두 화면이 같은 말을 해야 한다.
      if (/different from the old password/i.test(String(error.message || ''))
          || String(error.code || '') === 'same_password') {
        errEl.textContent = t('auth.pwSameAsCurrent');
        errEl.style.display = 'block';
        btn.disabled = false;
        btn.textContent = t('auth.reset.btn');
        return;
      }
      errEl.textContent = t('authError.genericError');
      errEl.style.display = 'block';
    } else {
      try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
      await db.auth.signOut();
      toast(t('profile.pwChanged'), 'success');
      navigate('login');
    }
  } catch (err) {
    logAppError('handleResetPassword', err);
    errEl.textContent = t('authError.genericError');
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = t('auth.reset.btn');
}


// ══════════════════════════════════════
// 탈퇴가 확정된 계정을 로그아웃시킨다 (마이그레이션 358·359 — 작업 8)
//
//   ⚠️ 이건 **보조 장치**다. 최종 방어선은 서버의 차단 장치(359)이고, 이 함수는
//      화면을 안 거치는 사람까지 막지 못한다. 그래도 필요한 이유는, 파기로 비워진
//      마이페이지를 회원이 계속 들여다보며 **다시 입력하라고 재촉받는** 상태를
//      끊어 주기 때문이다.
//
//   ★ **`login_blocked` 만 본다 — `write_blocked` 를 쓰면 안 된다.**
//      예정일이 지났지만 예약 실행이 아직 안 돈 구간의 회원까지 로그아웃시키면
//      **탈퇴 취소 버튼에 닿지 못한다.** 취소는 회원에게 유리한 동작이다.
//
//   ⚠️ 조회에 실패하면 **아무것도 하지 않는다**(fail-open). 통신 장애로 정상 회원을
//      쫓아내는 쪽이 훨씬 나쁘고, 서버가 최종 방어선이라 실피해가 없다.
//      (마이그레이션 276 이 세운 「서버에 못 물어본 경우엔 막지 않는다」 원칙)
// ══════════════════════════════════════
let _withdrawalLogoutChecked = false;

async function enforceWithdrawalLogout() {
  // 같은 세션에서 두 번 이상 돌지 않게 — 부팅과 로그인 이벤트 양쪽에서 불린다
  if (_withdrawalLogoutChecked) return;
  if (!currentUser) return;
  // 관리자는 대상이 아니다(관리자를 겸한 회원은 파기 자체가 거부된다 — 마이그레이션 352)
  if (currentUser._isAdmin) return;
  if (typeof fetchMyWithdrawalState !== 'function') return;

  _withdrawalLogoutChecked = true;

  const st = await fetchMyWithdrawalState();
  // ok 가 아니거나 login_blocked 가 명시적으로 true 가 아니면 아무것도 안 한다
  if (!st || st.ok !== true || st.login_blocked !== true) return;

  const msg = typeof t === 'function' ? t('auth.withdrawnLogout')
    : '退会手続きが完了したため、ログアウトしました。ご不明な点は運営までLINEでご連絡ください。';

  try {
    await db?.auth?.signOut();
  } catch (e) {
    console.error('[enforceWithdrawalLogout] signOut', e);
  }
  currentUser = null;
  currentUserProfile = null;
  if (typeof updateGnb === 'function') updateGnb();
  if (typeof navigate === 'function') navigate('login');

  // 안내는 사라지지 않게 로그인 화면에 남긴다 — 되돌릴 수 없는 사건이라 2.8초 뒤
  //   사라지는 알림으로는 부족하다. (#loginError 는 정적 요소라 다시 그려지지 않는다)
  const errEl = typeof $ === 'function' ? $('loginError') : null;
  if (errEl) {
    errEl.textContent = msg;
    errEl.style.display = '';
  } else if (typeof toast === 'function') {
    toast(msg);
  }
}


// 회원가입 실패를 화면에 알린다 — **모든 실패가 이 함수 하나를 쓴다**
//
//   ★ **왜 실패했는지 구분해 보여주지 않는다.** 이미 가입된 이메일이든, 탈퇴 후
//     재가입 제한 기간이든, 서버 오류든 **똑같은 문구**가 뜬다.
//     구분해 보여주면 아무나 임의의 이메일로 가입을 시도해 보고 **「이 사람이 최근에
//     탈퇴했다」를 알아낼 수 있다** — 가입 화면은 누구나 열 수 있기 때문이다.
//     (2026-08-20 검토 지적: 「본인은 메일로 이미 안다」는 근거는 계정 열거 방지
//      논리로 성립하지 않는다 — 문제는 본인이 아니라 제3자다)
//   ★ **연락할 곳은 항상 함께 준다**(2026-08-20 사용자 지시). 이유를 안 알리면서 갈
//     곳도 없으면 회원은 고장으로 오해한 채 막힌다. 연락처를 **차단된 경우에만** 붙이면
//     그 자체가 구분 신호가 되므로, **모든 실패에** 붙이는 것이 두 요구를 함께 지키는
//     유일한 방법이다.
//   ⚠️ 앱 안 문의 창구가 생기면(작업 2) 이 연락처를 그것으로 바꾼다.
//   ⚠️ 여기만 innerHTML 을 쓴다 — 연락처를 **누를 수 있는 링크**로 줘야 하기 때문이다.
//     넣는 값은 번역 파일의 고정 문구라 사용자 입력이 섞이지 않는다.
function showSignupFailure(errEl) {
  if (!errEl) return;
  const msg  = typeof t === 'function' ? t('authError.signupFailed')
    : '登録に失敗しました。しばらくしてからもう一度お試しください';
  const help = typeof t === 'function' ? t('authError.signupHelp')
    : 'お困りの場合は LINE までご連絡ください。';
  errEl.innerHTML = esc(msg) + '<br>' + esc(help)
    + ' <a href="https://line.me/R/ti/p/@reverb.jp" target="_blank" rel="noopener"'
    + ' style="color:var(--pink);text-decoration:underline">@reverb.jp</a>';
  errEl.style.display = 'block';
}
