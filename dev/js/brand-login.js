// 브랜드 페이지 — 로그인·비밀번호 찾기·메일 링크(설정·재설정) 화면 동작
//   (Figma 「[1차] 01 로그인」, 사양서 docs/specs/2026-07-15-brand-portal.md §16-6, 분해표 「조각 8」)
//   연결(brandDb·brandSetupDb)은 brand-core.js, 부팅·주소 착지는 brand-app.js.
//   초대 수락(bw01-03) 동작은 brand-invite.js(묶음 ② 조각 3). 여기는 미리보기 예시 채우기(fillInviteScreen)만.
//   ⚠️ 이메일 변경(bw01-04)은 아직 서버와 연결하지 않았다 — 미리보기 막대 전용(brandFakeRequest).
//   로그인 뒤 틀·세션 상태는 brand-shell.js.

const BRAND_MSG = {
  emailEmpty: '이메일을 입력해 주십시오.',
  emailFormat: '이메일 형식이 올바르지 않습니다. 「@」 뒤에 「company.com」처럼 「.(점)」까지 입력해 주십시오.',
  pwEmpty: '비밀번호를 입력해 주십시오.',
  // ④ 계정 열거 방지 — 「없는 이메일」·「틀린 비밀번호」를 나누지 않는다 (.claude/rules/security.md)
  loginFail: '이메일 또는 비밀번호가 올바르지 않습니다. 비밀번호가 기억나지 않으면 아래 「비밀번호를 잊으셨습니까?」를 눌러 주십시오.',
  tooMany: '로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주십시오.',
  // 비밀번호는 맞았는데 로그인 뒤 판정을 못 받았을 때 / 연결이 끊겼을 때 — 일반 실패와 구분한다
  checkFail: '로그인을 확인하지 못했습니다. 잠시 후 다시 시도해 주십시오.',
  nameEmpty: '이름을 입력해 주십시오.',
  pw2Empty: '비밀번호를 한 번 더 입력해 주십시오.',
  pwMismatch: '비밀번호가 서로 다릅니다. 한 번 더 확인해 주십시오.',
  agreeRequired: '필수 항목에 모두 동의해 주십시오. 동의하지 않으면 계정을 쓸 수 없습니다.',
  samePassword: '지금 쓰는 비밀번호와 다른 비밀번호로 정해 주십시오.',
  weakPassword: '쓸 수 없는 비밀번호입니다. 8자 이상, 영문 소문자와 기호를 넣어 다른 비밀번호로 정해 주십시오.',
  saveFail: '저장하지 못했습니다. 잠시 후 다시 시도해 주십시오. 계속되면 REVERB 운영팀에 문의해 주십시오.',
  setupFinishFail: '비밀번호 설정을 마치지 못했습니다. 잠시 후 「비밀번호 설정하고 시작하기」를 다시 눌러 주십시오.',
  setupDoneRelogin: '비밀번호를 설정했습니다. 새 비밀번호로 로그인해 주십시오.',
  previewOnly: '미리보기 화면이라 저장하지 않습니다. 실제 설정은 메일 속 링크로 들어와야 합니다.'
};

// 약관 판 문자열 — 🔴 개발서버 임시 판. 브랜드용 약관이 확정되면(선결 조건 P-7) 실제 판으로 바꾼다.
const BRAND_TERMS_VERSION = 'dev-2026-10-14';

// 미리보기 화면에 채우는 예시 값 (Figma 화면의 예시 그대로)
const BRAND_SAMPLE = {
  setpwOwner: { email: 'manager@company.com', desc: '레버브 운영팀이 「레버브」 브랜드 계정을 만들었습니다. 비밀번호를 정하면 바로 시작할 수 있습니다.' },
  setpwMember: { email: 'park@harudam.co.kr', desc: '「하루담」 브랜드의 김대표님이 회원님을 멤버로 초대했습니다. 이름과 비밀번호를 정하면 바로 시작할 수 있습니다.' },
  invite: { email: 'manager@company.com', desc: '「하루담」 브랜드의 대표 담당자 김대표님이 회원님을 멤버로 초대했습니다.' },
  emailChange: { next: 'kim@harudam.co.kr', current: 'ceo@harudam.co.kr' },
  resetEmail: 'manager@company.com'
};
// 실제 설정 화면 설명 — 로그인 전이라 브랜드 이름을 알 수 없어(링크 판정 함수는 유효 여부만 돌려준다) 이름 없이 쓴다
const BRAND_SETPW_REAL_DESC = 'REVERB 운영팀이 브랜드 계정을 만들었습니다. 비밀번호를 정하면 바로 시작할 수 있습니다.';

// 아직 서버와 연결하지 않은 화면(초대 수락·이메일 변경) 미리보기 전용
function brandFakeRequest(result) {
  return new Promise(resolve => setTimeout(() => resolve(result), 700));
}

function validateEmailField(id) {
  const v = document.getElementById(id).value.trim();
  if (!v) { setFieldError(id, BRAND_MSG.emailEmpty); return false; }
  if (!isEmailFormat(v)) { setFieldError(id, BRAND_MSG.emailFormat); return false; }
  setFieldError(id, '');
  return true;
}

// 메일 링크 착지 맥락 — brand-app.js handleBrandLinkLanding 이 채운다.
//   { linkId, mode:'setup'|'reset', email, hasSession }  · 없으면 null(미리보기 화면)
let brandLinkCtx = null;
let _brandConfirmTarget = null;

// 로그인 오류를 화면 문구로 — 서버의 영어 문구는 그대로 보여 주지 않는다
function brandSignInErrorMsg(err) {
  const msg = String((err && err.message) || '');
  if ((err && err.status === 429) || /rate limit|too many/i.test(msg)) return BRAND_MSG.tooMany;
  // 연결 끊김(응답 없음)은 비밀번호 문제가 아니다
  if (err && (err.status === 0 || err.name === 'AuthRetryableFetchError')) return BRAND_MSG.checkFail;
  return BRAND_MSG.loginFail;
}

// 로그인 직후 판정 — 결과: { state, name, email, brands } 또는 null(호출 실패)
async function fetchBrandLoginState() {
  const { data, error } = await brandRpc('get_my_brand_login_state');
  if (error || !data || typeof data !== 'object' || !data.state) return null;
  return data;
}

// 판정 결과에 따라 화면을 정한다. ok 가 아니면 세션을 남기지 않는다(로그아웃 후 안내).
//   loginError 문구는 로그인 화면으로 돌아갈 때만 쓴다.
async function applyBrandLoginState(state) {
  if (state && state.state === 'ok') {
    _brandInviteCtx = null;
    setBrandAuthed(state);
    return 'ok';
  }
  const kind = state ? state.state : null;
  // 연결된 브랜드는 없지만 수락할 초대가 있다 — 로그아웃하지 않고 초대 수락 화면으로(조각 3).
  //   초대 목록을 못 받으면(실패·그사이 만료) 아래 원래 갈래(로그아웃 + 연결된 브랜드 없음)로 간다.
  if (kind === 'no_active_brand' && state.has_pending_invite) {
    setBrandAuthed(null);
    if (await enterInviteOnly(state)) return 'invite';
  }
  _brandInviteCtx = null;
  await brandSignOutLocal();
  setBrandAuthed(null);
  if (kind === 'not_brand') { goBrandScreen('not-brand'); return kind; }
  if (kind === 'no_active_brand') { goBrandScreen('no-brand'); return kind; }
  // setup_incomplete — 비밀번호가 비어 실제로는 로그인 자체가 실패하는 상태라 일반 실패 문구
  goBrandScreen('login');
  setNotice('loginError', kind === 'setup_incomplete' ? BRAND_MSG.loginFail : BRAND_MSG.checkFail);
  return kind || 'error';
}

// ── bw01-00 로그인
function initLoginForm() {
  const form = document.getElementById('loginForm');
  const btn = document.getElementById('loginSubmit');
  let busy = false;
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    setNotice('loginError', '');
    // ② 빈 칸 · ③ 형식 오류 — 화면에서만 검사하고 서버에는 묻지 않는다
    const emailOk = validateEmailField('loginEmail');
    const pwInput = document.getElementById('loginPw');
    const pwOk = !!pwInput.value;
    setFieldError('loginPw', pwOk ? '' : BRAND_MSG.pwEmpty);
    if (!emailOk || !pwOk) {
      (emailOk ? pwInput : document.getElementById('loginEmail')).focus();
      return;
    }
    const email = document.getElementById('loginEmail').value.trim();
    // ⑤ 로그인 중 — 두 번 눌리지 않게 잠근다
    busy = true;
    setFormBusy(form, true);
    btn.textContent = '로그인 중…';
    let failMsg = '';
    try {
      let signErr = null;
      try {
        const { error } = await brandDb.auth.signInWithPassword({ email, password: pwInput.value });
        signErr = error;
      } catch (ex) { signErr = ex || new Error('sign_in_failed'); }
      if (signErr) {
        failMsg = brandSignInErrorMsg(signErr);
      } else {
        const state = await fetchBrandLoginState();
        const result = await applyBrandLoginState(state);
        if (result === 'ok') {
          setNotice('loginExpiredNotice', '');
          pwInput.value = '';
          // 초대 메일 링크로 왔다가 로그인하러 온 경우 — 그 초대 화면으로 돌아간다(bw01-03 「로그인 뒤 이 화면으로」)
          if (!(await resumeBrandInviteLink())) enterBrandApp(state);
        } else {
          // 대기 초대만 있는 계정은 초대 화면이 받은 초대를 모두 보여 준다 — 보관한 링크는 버린다
          clearBrandInviteLink();
          pwInput.value = '';
        }
        return;
      }
    } finally {
      busy = false;
      setFormBusy(form, false);
      btn.textContent = '로그인';
    }
    // ④ 실패 · ⑥ 시도 과다 — 이메일은 남기고 비밀번호 칸만 비운다
    setNotice('loginError', failMsg);
    pwInput.value = '';
    pwInput.focus();
  });
  ['loginEmail', 'loginPw'].forEach(id => {
    document.getElementById(id).addEventListener('input', () => setFieldError(id, ''));
  });
}

// ── bw01-01 비밀번호 찾기 → bw01-01a 메일 발송
//   🔴 brandDb.auth.resetPasswordForEmail 을 쓰지 않는다 — pkce 검증값이 요청한 브라우저에 묶여
//      다른 기기에서 메일을 열면 실패하고, 인플루언서 메일 양식과 섞인다. 서버 함수만 부른다(조각 5).
//   서버 함수는 계정이 있든 없든 같은 응답(최소 2.5초)이라 결과를 보지 않고 다음 화면으로 간다.
async function requestBrandPasswordReset(email) {
  try {
    await fetch(SUPABASE_URL + '/functions/v1/brand-password-reset-request', {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY
      },
      body: JSON.stringify({ email })
    });
  } catch (e) { /* 계정 존재 비노출 — 실패여도 같은 화면 */ }
}

function initForgotForm() {
  const form = document.getElementById('forgotForm');
  const btn = document.getElementById('forgotSubmit');
  let busy = false;
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    if (!validateEmailField('forgotEmail')) { document.getElementById('forgotEmail').focus(); return; }
    busy = true;
    setFormBusy(form, true);
    btn.textContent = '보내는 중…';
    try {
      await requestBrandPasswordReset(document.getElementById('forgotEmail').value.trim());
    } finally {
      busy = false;
      setFormBusy(form, false);
      btn.textContent = '재설정 메일 보내기';
    }
    // 계정이 있든 없든 같은 화면으로 간다 (계정 존재 비노출)
    goBrandScreen('forgot-sent');
  });
  document.getElementById('forgotEmail').addEventListener('input', () => setFieldError('forgotEmail', ''));
}

// ── bw01-08 「계속하기」 — 메일 링크의 #confirm= 에 담긴 인증 서비스 주소로 직접 누를 때만 넘긴다
//   ★목적지는 현재 환경 프로젝트 주소 + /auth/v1/verify 정확 일치(admin-setpw.html readConfirmTarget 과 같은 방식).
//     *.supabase.co 를 통짜로 허용하면 남의 프로젝트를 거쳐 피싱 사이트로 넘어갈 수 있다.
function readBrandConfirmTarget(raw) {
  if (!raw) return null;
  try {
    const u = new URL(raw);
    const expectedHost = new URL(SUPABASE_URL).hostname;
    if (u.protocol !== 'https:') return null;
    if (u.hostname !== expectedHost) return null;
    if (u.pathname !== '/auth/v1/verify') return null;
    return u.toString();
  } catch (e) { return null; }
}

function fillConfirmScreen(mode, target) {
  document.getElementById('confirmTitle').textContent =
    mode === 'reset' ? '비밀번호를 다시 정하시겠습니까?' : '비밀번호를 설정하시겠습니까?';
  document.getElementById('confirmDesc').textContent = '아래 「계속하기」를 누르면 비밀번호 설정 화면으로 넘어갑니다.';
  _brandConfirmTarget = target || null;
  const btn = document.getElementById('confirmBtn');
  btn.disabled = false; btn.textContent = '계속하기';
}

function initConfirm() {
  const btn = document.getElementById('confirmBtn');
  btn.addEventListener('click', () => {
    if (btn.disabled) return;
    if (_brandInviteLanding) { continueBrandInviteLanding(); return; }   // 초대 메일 링크(brand-invite.js)
    if (!_brandConfirmTarget) { showBrandLinkInvalid(); return; }
    btn.disabled = true;
    btn.textContent = '이동하는 중…';
    window.location.href = _brandConfirmTarget;
  });
}

// ── bw01-02 비밀번호 설정 · bw01-02b 초대받은 멤버
//   실제(메일 링크로 들어옴)면 brandLinkCtx.mode==='setup', 아니면 미리보기 예시 값
function resetSetpwForm() {
  const form = document.getElementById('setpwForm');
  form.reset();
  clearFormErrors(form);
  resetPasswordToggles(form);
  setNotice('setpwAgreeError', '');
  document.getElementById('setpwAgree').classList.remove('is-error');
  setNotice('setpwResult', '');
}

function fillSetpwScreen(kind) {
  const isMember = kind === 'member';
  const s = isMember ? BRAND_SAMPLE.setpwMember : BRAND_SAMPLE.setpwOwner;
  document.querySelectorAll('#setpwForm [data-member-only]').forEach(el => { el.hidden = !isMember; });
  resetSetpwForm();
  document.getElementById('setpwDesc').textContent = s.desc;
  document.getElementById('setpwEmail').value = s.email;
}

function fillSetpwReal(email) {
  document.querySelectorAll('#setpwForm [data-member-only]').forEach(el => { el.hidden = true; });
  resetSetpwForm();
  document.getElementById('setpwDesc').textContent = BRAND_SETPW_REAL_DESC;
  document.getElementById('setpwEmail').value = email || '';
}

function syncAgreeAll() {
  const items = document.querySelectorAll('#setpwAgree .agree-item');
  document.getElementById('agreeAll').checked = Array.from(items).every(i => i.checked);
}

// updateUser 오류 분류 — 인증 서비스의 오류 코드(err.code)로 가른다. 문구 정규식은 코드가 없을 때의 보조.
//   반환: 'link'(→ 쓸 수 없는 링크) | 'same'(지금 비밀번호와 같음) | 화면 문구
//   reauthentication_needed 는 이 화면에서 재인증할 길이 없어 막다른 길이 되므로 쓸 수 없는 링크로 보낸다.
const BRAND_PW_LINK_CODES = ['session_not_found', 'session_expired', 'bad_jwt', 'no_authorization', 'reauthentication_needed'];
function brandUpdatePwErrorKind(err) {
  const code = (err && err.code) || '';
  const msg = String((err && err.message) || '');
  if (BRAND_PW_LINK_CODES.includes(code) || (err && err.name === 'AuthSessionMissingError')) return 'link';
  if (code === 'same_password') return 'same';
  if (code === 'weak_password') return BRAND_MSG.weakPassword;
  // 보조 — 코드가 비어 오는 옛 응답
  if (!code) {
    if (/different from the old password/i.test(msg)) return 'same';
    if ((err && err.status === 401) || /session missing|jwt|not authenticated/i.test(msg)) return 'link';
  }
  return BRAND_MSG.saveFail;
}

// 입력한 비밀번호를 같은 화면 안에서 비교하기 위한 지문(원문은 남기지 않는다). 해시 기능이 없으면 null
async function brandPwFingerprint(pw) {
  try {
    if (!(window.crypto && crypto.subtle)) return null;
    const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(pw));
    return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
  } catch (e) { return null; }
}

const _brandSleep = (ms) => new Promise(r => setTimeout(r, ms));

// 설정 완료 기록 — password_not_set 이면 최대 2회 더 시도. 반환: 결과 문자열 또는 null(호출 실패)
async function completeBrandSetup(linkId) {
  for (let i = 0; i < 3; i++) {
    let r;
    try {
      r = await brandSetupDb.rpc('complete_brand_account_setup', { p_link_id: linkId, p_terms_version: BRAND_TERMS_VERSION });
    } catch (e) { r = { data: null, error: e }; }
    if (r.error || typeof r.data !== 'string') {
      if (i < 2) { await _brandSleep(600); continue; }
      return null;
    }
    if (r.data !== 'password_not_set') return r.data;
    if (i < 2) await _brandSleep(600);
  }
  return 'password_not_set';
}

async function submitSetpwReal(pw) {
  const ctx = brandLinkCtx;
  // 🔴 재시도 막다른 길 방지 — 비밀번호 저장은 됐는데 완료 기록이 실패해 다시 누른 경우,
  //   같은 비밀번호로 updateUser 를 또 부르면 same_password 로 거절돼 영영 못 끝낸다.
  //   그래서 저장에 성공한 입력의 지문을 이 화면의 메모리(brandLinkCtx)에만 두고, 같은 입력이면 저장을 건너뛰고 완료 기록만 다시 부른다.
  const fp = await brandPwFingerprint(pw);
  const alreadyApplied = !!(ctx.pwAppliedFp && fp && ctx.pwAppliedFp === fp);
  if (!alreadyApplied) {
    const { error: upErr } = await brandSetupDb.auth.updateUser({ password: pw });
    if (upErr) {
      const kind = brandUpdatePwErrorKind(upErr);
      // 이미 한 번 바꾼 상태에서 same_password = 지금 비밀번호가 곧 이 입력 → 저장된 것으로 보고 진행
      if (!(kind === 'same' && ctx.pwAppliedFp)) {
        if (kind === 'link') { await showBrandLinkInvalid(); return; }
        setNotice('setpwResult', kind === 'same' ? BRAND_MSG.samePassword : kind);
        return;
      }
    }
    ctx.pwAppliedFp = fp || 'applied';
  }
  const result = await completeBrandSetup(ctx.linkId);
  if (result === 'link_mismatch' || result === 'already_set') { await showBrandLinkInvalid(); return; }
  if (result === 'not_brand') {
    await brandSetupSignOutLocal();
    endBrandLinkFlow();
    goBrandScreen('not-brand');
    return;
  }
  if (result !== 'ok') { setNotice('setpwResult', BRAND_MSG.setupFinishFail); return; }

  // 설정 완료 — 임시 세션을 정리하고 로그인 연결로 새 비밀번호 로그인(설정은 로그인된 채 첫 화면, 피그마 F-1)
  const email = ctx.email;
  await brandSetupSignOutLocal();
  endBrandLinkFlow();
  let signErr = null;
  try {
    const { error } = await brandDb.auth.signInWithPassword({ email, password: pw });
    signErr = error;
  } catch (ex) { signErr = ex || new Error('sign_in_failed'); }
  if (signErr) {
    goBrandScreen('login');
    document.getElementById('loginEmail').value = email || '';
    setNotice('loginExpiredNotice', BRAND_MSG.setupDoneRelogin);
    return;
  }
  const state = await fetchBrandLoginState();
  const r2 = await applyBrandLoginState(state);
  if (r2 === 'ok') enterBrandApp(state);
}

function initSetpwForm() {
  const form = document.getElementById('setpwForm');
  const btn = document.getElementById('setpwSubmit');
  const agreeBox = document.getElementById('setpwAgree');
  let busy = false;
  document.getElementById('agreeAll').addEventListener('change', (e) => {
    agreeBox.querySelectorAll('.agree-item').forEach(i => { i.checked = e.target.checked; });
    setNotice('setpwAgreeError', ''); agreeBox.classList.remove('is-error');
  });
  agreeBox.querySelectorAll('.agree-item').forEach(i => i.addEventListener('change', () => {
    syncAgreeAll();
    setNotice('setpwAgreeError', ''); agreeBox.classList.remove('is-error');
  }));
  ['setpwName', 'setpwPw', 'setpwPw2'].forEach(id => {
    document.getElementById(id).addEventListener('input', () => setFieldError(id, ''));
  });
  bindBrandCommonPwWarning('setpwPw', BRAND_COMMON_PW_MSG);   // 설정(bw01-02)·초대받은 멤버(bw01-02b) 공용 칸 — 경고만(조각 9)

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    setNotice('setpwResult', '');
    const isReal = !!(brandLinkCtx && brandLinkCtx.mode === 'setup' && brandLinkCtx.hasSession);
    const isInviteNew = !isReal && !!_brandInviteNewCtx;   // 초대 메일 링크로 온 새 이메일 멤버(bw01-02b)
    let firstBad = null;
    const isMember = isInviteNew || (!isReal && brandPreviewState.setpwKind === 'member');
    if (isMember) {
      const name = document.getElementById('setpwName').value.trim();
      setFieldError('setpwName', name ? '' : BRAND_MSG.nameEmpty);
      if (!name) firstBad = firstBad || 'setpwName';
    }
    const pw = document.getElementById('setpwPw').value;
    const pw2 = document.getElementById('setpwPw2').value;
    const pwIssue = brandPasswordIssue(pw);
    setFieldError('setpwPw', pwIssue);
    if (pwIssue) firstBad = firstBad || 'setpwPw';
    const pw2Issue = !pw2 ? BRAND_MSG.pw2Empty : (pw2 !== pw ? BRAND_MSG.pwMismatch : '');
    setFieldError('setpwPw2', pw2Issue);
    if (pw2Issue) firstBad = firstBad || 'setpwPw2';
    const agreed = document.getElementById('agreeTerms').checked && document.getElementById('agreePrivacy').checked;
    setNotice('setpwAgreeError', agreed ? '' : BRAND_MSG.agreeRequired);
    agreeBox.classList.toggle('is-error', !agreed);
    if (!agreed) firstBad = firstBad || 'agreeTerms';
    if (firstBad) { document.getElementById(firstBad).focus(); return; }

    if (!isReal && !isInviteNew) { setNotice('setpwResult', BRAND_MSG.previewOnly); return; }

    busy = true;
    setFormBusy(form, true);
    btn.textContent = '설정하는 중…';
    try {
      if (isInviteNew) await submitInviteNew(pw);
      else await submitSetpwReal(pw);
    } catch (ex) {
      setNotice('setpwResult', BRAND_MSG.saveFail);
    } finally {
      busy = false;
      setFormBusy(form, false);
      btn.textContent = '비밀번호 설정하고 시작하기';
    }
  });
}

// ── bw01-07 새 비밀번호 정하기(재설정) → bw01-07a 완료
function fillResetpwScreen(email) {
  const form = document.getElementById('resetpwForm');
  form.reset();
  clearFormErrors(form);
  resetPasswordToggles(form);
  setNotice('resetpwResult', '');
  document.getElementById('resetpwEmail').value = email || '';
}

function initResetpwForm() {
  const form = document.getElementById('resetpwForm');
  const btn = document.getElementById('resetpwSubmit');
  let busy = false;
  ['resetpwPw', 'resetpwPw2'].forEach(id => {
    document.getElementById(id).addEventListener('input', () => setFieldError(id, ''));
  });
  bindBrandCommonPwWarning('resetpwPw', BRAND_COMMON_PW_MSG);   // 재설정(bw01-07) — 경고만(조각 9)
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (busy) return;
    setNotice('resetpwResult', '');
    const pw = document.getElementById('resetpwPw').value;
    const pw2 = document.getElementById('resetpwPw2').value;
    let firstBad = null;
    const pwIssue = brandPasswordIssue(pw);
    setFieldError('resetpwPw', pwIssue);
    if (pwIssue) firstBad = 'resetpwPw';
    const pw2Issue = !pw2 ? BRAND_MSG.pw2Empty : (pw2 !== pw ? BRAND_MSG.pwMismatch : '');
    setFieldError('resetpwPw2', pw2Issue);
    if (pw2Issue) firstBad = firstBad || 'resetpwPw2';
    if (firstBad) { document.getElementById(firstBad).focus(); return; }

    const ctx = brandLinkCtx;
    if (!(ctx && ctx.mode === 'reset' && ctx.hasSession)) { setNotice('resetpwResult', BRAND_MSG.previewOnly); return; }

    busy = true;
    setFormBusy(form, true);
    btn.textContent = '바꾸는 중…';
    try {
      const { error: upErr } = await brandSetupDb.auth.updateUser({ password: pw });
      if (upErr) {
        const kind = brandUpdatePwErrorKind(upErr);
        if (kind === 'link') { await showBrandLinkInvalid(); return; }
        setNotice('resetpwResult', kind === 'same' ? BRAND_MSG.samePassword : kind);
        return;
      }
      let r;
      try { r = await brandSetupDb.rpc('complete_brand_password_reset', { p_link_id: ctx.linkId }); }
      catch (ex) { r = { data: null, error: ex }; }
      if (r.data === 'link_mismatch') { await showBrandLinkInvalid(); return; }
      // 비밀번호는 이미 바뀌었다 — 번호 비우기가 실패해도(not_brand·호출 실패) 완료 화면으로 간다.
      //   남은 링크 번호는 같은 메일 링크를 다시 열어도 인증 서비스 쪽 일회용 값이 이미 소진돼 쓸 수 없다.
      const resetUserId = ctx.userId;
      // 🔴 재설정 경로만 scope:'global' — 비밀번호를 다시 정하는 사람은 계정 탈취를 의심했을 수 있어,
      //   같은 사용자의 다른 기기 세션(갱신 토큰)까지 폐기한다. 설정(setup) 경로는 처음 쓰는 계정이라 local 유지.
      //   ⚠️ 한계: 이미 발급된 접근 토큰은 폐기되지 않아 만료(최대 1시간)까지는 유효하다 — 갱신만 막힌다.
      let globalErr = null;
      try { ({ error: globalErr } = await brandSetupDb.auth.signOut({ scope: 'global' })); }
      catch (ex) { globalErr = ex || new Error('sign_out_failed'); }
      if (globalErr) await brandSetupSignOutLocal(); // 서버 폐기가 실패해도 이 화면의 임시 세션은 지운다
      // 같은 사람이 이 브라우저에 로그인돼 있었다면 그 세션도 끊는다(「이 화면에서는 로그아웃했어요」)
      try {
        const { data } = await brandDb.auth.getSession();
        if (data && data.session && data.session.user && data.session.user.id === resetUserId) {
          await brandSignOutLocal();
          setBrandAuthed(null);
        }
      } catch (ex) { /* 무시 */ }
      endBrandLinkFlow('reset-done');
    } catch (ex) {
      setNotice('resetpwResult', BRAND_MSG.saveFail);
    } finally {
      busy = false;
      setFormBusy(form, false);
      btn.textContent = '비밀번호 바꾸기';
    }
  });
}

// ── bw01-03 초대 수락 — 미리보기 예시 값(실제 동작은 brand-invite.js)
function fillInviteScreen() {
  document.getElementById('inviteDesc').textContent = BRAND_SAMPLE.invite.desc;
  document.getElementById('inviteEmail').value = BRAND_SAMPLE.invite.email;
  setNotice('inviteResult', '');
  _setInviteBusy(false);
}

// ── bw01-04 이메일 변경 확인
function fillEmailChangeScreen() {
  document.getElementById('emailChangeNew').value = BRAND_SAMPLE.emailChange.next;
  document.getElementById('emailChangeNote').textContent =
    '요청하지 않았다면 이 화면을 닫아 주십시오. 지금 이메일(' + BRAND_SAMPLE.emailChange.current + ')은 그대로입니다.';
  setNotice('emailChangeResult', '');
  const btn = document.getElementById('emailChangeSubmit');
  btn.disabled = false; btn.textContent = '확인';
}

function initEmailChange() {
  const btn = document.getElementById('emailChangeSubmit');
  btn.addEventListener('click', async () => {
    btn.disabled = true; btn.textContent = '바꾸는 중…';
    await brandFakeRequest('ok');
    btn.textContent = '바꿨습니다';
    setNotice('emailChangeResult', '로그인 이메일이 ' + BRAND_SAMPLE.emailChange.next + ' 로 바뀌었습니다. 다음부터 이 이메일로 로그인해 주십시오.');
  });
}

// ── 약관 「보기」 창
let _legalReturnFocus = null;
function openLegalModal(kind) {
  const modal = document.getElementById('legalModal');
  document.getElementById('legalModalTitle').textContent = kind === 'privacy' ? '개인정보처리방침' : '이용약관';
  _legalReturnFocus = document.activeElement;
  modal.hidden = false;
  document.getElementById('legalModalClose').focus();
}
function closeLegalModal() {
  document.getElementById('legalModal').hidden = true;
  if (_legalReturnFocus) _legalReturnFocus.focus();
}
function initLegalModal() {
  document.querySelectorAll('[data-legal]').forEach(b => b.addEventListener('click', () => openLegalModal(b.dataset.legal)));
  document.getElementById('legalModalClose').addEventListener('click', closeLegalModal);
  const modal = document.getElementById('legalModal');
  modal.addEventListener('click', (e) => { if (e.target === modal) closeLegalModal(); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !modal.hidden) closeLegalModal(); });
}

function initBrandLoginScreens() {
  bindPasswordToggles();
  initLoginForm();
  initForgotForm();
  initConfirm();
  initSetpwForm();
  initResetpwForm();
  initInvite();
  initEmailChange();
  initLegalModal();
}
