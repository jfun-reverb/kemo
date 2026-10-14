// 브랜드 페이지 — 부팅·화면 주소(#해시) 전환·개발서버 미리보기 막대. 맨 마지막에 싣는다.
//   운영 주소(IS_STAGING=false — dev/lib/supabase.js 의 도메인 판정)에서는 「준비 중」 카드만 보이고
//   다른 화면·미리보기 막대는 그리지 않는다.

const BRAND_EXPIRED_MSG = '로그인 시간이 지났습니다. 다시 로그인해 주세요.';

// 미리보기 막대에서 고른 값 — brand-login.js 가 읽는다
const brandPreviewState = {
  loginResult: 'fail',   // 'fail' | 'too-many' | 'ok'
  setpwKind: 'owner'     // 'owner'(운영팀이 만든 계정) | 'member'(초대받은 멤버)
};

const BRAND_PREVIEW_SCREENS = [
  { hash: 'login', label: 'w01-00 로그인' },
  { hash: 'forgot', label: 'w01-01 비밀번호 찾기' },
  { hash: 'forgot-sent', label: 'w01-01a 메일 발송' },
  { hash: 'setpw', label: 'w01-02 비밀번호 설정' },
  { hash: 'invite', label: 'w01-03 초대 수락' },
  { hash: 'email-change', label: 'w01-04 이메일 변경 확인' },
  { hash: 'link-invalid', label: 'w01-05 쓸 수 없는 링크' }
];

function currentBrandScreen() {
  const h = location.hash.replace(/^#/, '');
  return BRAND_SCREENS.includes(h) ? h : 'login';
}

function routeBrand() {
  const name = currentBrandScreen();
  // 들어올 때마다 그 화면을 처음 상태로 채운다
  if (name === 'setpw') fillSetpwScreen(brandPreviewState.setpwKind);
  if (name === 'invite') fillInviteScreen();
  if (name === 'email-change') fillEmailChangeScreen();
  if (name === 'forgot') {
    // 로그인 칸에 넣던 이메일을 이어받는다
    const f = document.getElementById('forgotEmail');
    if (!f.value) f.value = document.getElementById('loginEmail').value.trim();
  }
  showBrandScreen(name);
  updatePreviewBar(name);
  window.scrollTo(0, 0);
  // 숨겨진 칸(멤버 전용 이름·연락처 등)은 건너뛰고 보이는 첫 칸에 초점
  const firstInput = Array.from(document.querySelectorAll('.brand-card[data-screen="' + name + '"] .brand-input:not([readonly])'))
    .find(el => el.offsetParent !== null);
  if (firstInput && window.matchMedia('(min-width: 601px)').matches) firstInput.focus();
}

function updatePreviewBar(name) {
  const sel = document.getElementById('previewScreen');
  if (sel) sel.value = name;
  document.querySelectorAll('[data-preview-for]').forEach(row => {
    row.hidden = row.dataset.previewFor !== name;
  });
}

function initPreviewBar() {
  const bar = document.getElementById('brandPreview');
  const sel = document.getElementById('previewScreen');
  sel.innerHTML = BRAND_PREVIEW_SCREENS
    .map(s => '<option value="' + brandEsc(s.hash) + '">' + brandEsc(s.label) + '</option>').join('');
  sel.addEventListener('change', () => { location.hash = '#' + sel.value; });

  document.getElementById('previewLoginResult').addEventListener('change', (e) => {
    brandPreviewState.loginResult = e.target.value;
  });
  document.getElementById('previewExpired').addEventListener('change', (e) => {
    setNotice('loginExpiredNotice', e.target.checked ? BRAND_EXPIRED_MSG : '');
  });
  document.getElementById('previewSetpwKind').addEventListener('change', (e) => {
    brandPreviewState.setpwKind = e.target.value;
    fillSetpwScreen(brandPreviewState.setpwKind);
  });
  bar.hidden = false;
}

function bootBrand() {
  if (typeof IS_STAGING === 'undefined' || !IS_STAGING) {
    showBrandScreen('closed');
    return;
  }
  initBrandLoginScreens();
  initPreviewBar();
  window.addEventListener('hashchange', routeBrand);
  routeBrand();
}

bootBrand();
