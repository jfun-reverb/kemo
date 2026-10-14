// 브랜드 페이지 — 로그인 전 화면 동작 (Figma 「[1차] 01 로그인」, 사양서 docs/specs/2026-07-15-brand-portal.md §15·§16)
//   ⚠️ 아직 서버에 묻지 않는다. 「로그인」·「메일 보내기」 결과는 개발서버 미리보기 막대에서 고른 값을 따른다
//      (brandPreviewState — brand-app.js). 로그인을 연결할 때 brandFakeRequest 자리만 바꾼다.

const BRAND_MSG = {
  emailEmpty: '이메일을 입력해 주세요.',
  emailFormat: '이메일 형식이 올바르지 않습니다. 「@」 뒤에 「company.com」처럼 「.(점)」까지 입력해 주세요.',
  pwEmpty: '비밀번호를 입력해 주세요.',
  // ④ 계정 열거 방지 — 「없는 이메일」·「틀린 비밀번호」를 나누지 않는다 (.claude/rules/security.md)
  loginFail: '이메일 또는 비밀번호가 올바르지 않습니다. 비밀번호가 기억나지 않으면 아래 「비밀번호를 잊으셨나요?」를 눌러 주세요.',
  tooMany: '로그인 시도가 너무 많습니다. 잠시 후 다시 시도해 주세요.',
  nameEmpty: '이름을 입력해 주세요.',
  pw2Empty: '비밀번호를 한 번 더 입력해 주세요.',
  pwMismatch: '두 비밀번호가 같지 않습니다.',
  agreeRequired: '필수 약관 두 개에 모두 동의해 주세요.'
};

// 미리보기 화면에 채우는 예시 값 (Figma 화면의 예시 그대로)
const BRAND_SAMPLE = {
  setpwOwner: { email: 'manager@company.com', desc: '레버브 운영팀이 「레버브」 브랜드 계정을 만들었어요. 비밀번호를 정하면 바로 시작할 수 있어요.' },
  setpwMember: { email: 'park@harudam.co.kr', desc: '「하루담」 브랜드의 김대표님이 회원님을 멤버로 초대했어요. 이름과 비밀번호를 정하면 바로 시작할 수 있어요.' },
  invite: { email: 'manager@company.com', desc: '「하루담」 브랜드의 대표 담당자 김대표님이 회원님을 멤버로 초대했어요.' },
  emailChange: { next: 'kim@harudam.co.kr', current: 'ceo@harudam.co.kr' }
};

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

// ── w01-00 로그인
function initLoginForm() {
  const form = document.getElementById('loginForm');
  const btn = document.getElementById('loginSubmit');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
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
    // ⑤ 로그인 중 — 두 번 눌리지 않게 잠근다
    setFormBusy(form, true);
    btn.textContent = '로그인 중…';
    let result;
    try {
      result = await brandFakeRequest(brandPreviewState.loginResult);
    } finally {
      setFormBusy(form, false);
      btn.textContent = '로그인';
    }
    if (result === 'ok') {
      setNotice('loginError', '');
      pwInput.value = '';
      // 로그인 뒤 화면이 아직 없어 위쪽 안내 띠에 결과만 띄운다
      setNotice('loginExpiredNotice', '미리보기: 로그인에 성공했다고 가정합니다. 로그인 뒤 화면은 아직 없습니다.');
      return;
    }
    // ④ 실패 · ⑥ 시도 과다 — 이메일은 남기고 비밀번호 칸만 비운다
    setNotice('loginError', result === 'too-many' ? BRAND_MSG.tooMany : BRAND_MSG.loginFail);
    pwInput.value = '';
    pwInput.focus();
  });
  ['loginEmail', 'loginPw'].forEach(id => {
    document.getElementById(id).addEventListener('input', () => setFieldError(id, ''));
  });
}

// ── w01-01 비밀번호 찾기 → w01-01a 메일 발송
function initForgotForm() {
  const form = document.getElementById('forgotForm');
  const btn = document.getElementById('forgotSubmit');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    if (!validateEmailField('forgotEmail')) { document.getElementById('forgotEmail').focus(); return; }
    setFormBusy(form, true);
    btn.textContent = '보내는 중…';
    try {
      await brandFakeRequest('ok');
    } finally {
      setFormBusy(form, false);
      btn.textContent = '재설정 메일 보내기';
    }
    // 계정이 있든 없든 같은 화면으로 간다 (계정 존재 비노출)
    location.hash = '#forgot-sent';
  });
  document.getElementById('forgotEmail').addEventListener('input', () => setFieldError('forgotEmail', ''));
}

// ── w01-02 비밀번호 설정 · w01-02b 초대받은 멤버
function fillSetpwScreen(kind) {
  const isMember = kind === 'member';
  const s = isMember ? BRAND_SAMPLE.setpwMember : BRAND_SAMPLE.setpwOwner;
  document.getElementById('setpwDesc').textContent = s.desc;
  document.getElementById('setpwEmail').value = s.email;
  document.querySelectorAll('#setpwForm [data-member-only]').forEach(el => { el.hidden = !isMember; });
  const form = document.getElementById('setpwForm');
  form.reset();
  document.getElementById('setpwEmail').value = s.email;
  clearFormErrors(form);
  resetPasswordToggles(form);
  setNotice('setpwAgreeError', '');
  document.getElementById('setpwAgree').classList.remove('is-error');
  setNotice('setpwResult', '');
}

function syncAgreeAll() {
  const items = document.querySelectorAll('#setpwAgree .agree-item');
  document.getElementById('agreeAll').checked = Array.from(items).every(i => i.checked);
}

function initSetpwForm() {
  const form = document.getElementById('setpwForm');
  const btn = document.getElementById('setpwSubmit');
  const agreeBox = document.getElementById('setpwAgree');
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

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    setNotice('setpwResult', '');
    let firstBad = null;
    const isMember = brandPreviewState.setpwKind === 'member';
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

    setFormBusy(form, true);
    btn.textContent = '설정하는 중…';
    try {
      await brandFakeRequest('ok');
    } finally {
      setFormBusy(form, false);
      btn.textContent = '비밀번호 설정하고 시작하기';
    }
    setNotice('setpwResult', '미리보기: 비밀번호가 설정됐다고 가정합니다. 실제로는 여기서 로그인 뒤 첫 화면으로 갑니다.');
  });
}

// ── w01-03 초대 수락
function fillInviteScreen() {
  document.getElementById('inviteDesc').textContent = BRAND_SAMPLE.invite.desc;
  document.getElementById('inviteEmail').value = BRAND_SAMPLE.invite.email;
  setNotice('inviteResult', '');
  const btn = document.getElementById('inviteSubmit');
  btn.disabled = false; btn.textContent = '초대 수락';
}

function initInvite() {
  const btn = document.getElementById('inviteSubmit');
  btn.addEventListener('click', async () => {
    btn.disabled = true; btn.textContent = '수락하는 중…';
    await brandFakeRequest('ok');
    btn.textContent = '수락했어요';
    setNotice('inviteResult', '미리보기: 「하루담」 브랜드가 계정에 연결됐다고 가정합니다.');
  });
}

// ── w01-04 이메일 변경 확인
function fillEmailChangeScreen() {
  document.getElementById('emailChangeNew').value = BRAND_SAMPLE.emailChange.next;
  document.getElementById('emailChangeNote').textContent =
    '요청하지 않았다면 이 화면을 닫아 주세요. 지금 이메일(' + BRAND_SAMPLE.emailChange.current + ')은 그대로예요.';
  setNotice('emailChangeResult', '');
  const btn = document.getElementById('emailChangeSubmit');
  btn.disabled = false; btn.textContent = '확인';
}

function initEmailChange() {
  const btn = document.getElementById('emailChangeSubmit');
  btn.addEventListener('click', async () => {
    btn.disabled = true; btn.textContent = '바꾸는 중…';
    await brandFakeRequest('ok');
    btn.textContent = '바꿨어요';
    setNotice('emailChangeResult', '로그인 이메일이 ' + BRAND_SAMPLE.emailChange.next + ' 로 바뀌었어요. 다음부터 이 이메일로 로그인해 주세요.');
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
  initSetpwForm();
  initInvite();
  initEmailChange();
  initLegalModal();
}
