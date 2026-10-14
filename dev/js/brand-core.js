// 브랜드 페이지 공용 — 화면 전환·입력 칸 오류 표시·검사 규칙
//   ⚠️ 관리자·인플루언서 빌드에 들어가지 않는 독립 화면(dev/brand/index.html) 전용이다.
//   ⚠️ ui.js 를 싣지 않는다 — 전역 키보드·클릭·끌어놓기 처리기가 함께 붙기 때문.

// 로그인을 연결할 때 쓸 저장 칸 이름. supabase-js 기본값(sb-…-auth-token)을 쓰면
// 같은 주소의 인플루언서·관리자 로그인과 세션이 섞인다 — 브랜드는 반드시 이 이름으로 분리한다.
const BRAND_AUTH_STORAGE_KEY = 'reverb.brandAuth';

const BRAND_SCREENS = ['login', 'forgot', 'forgot-sent', 'setpw', 'invite', 'email-change', 'link-invalid'];

function brandEsc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function showBrandScreen(name) {
  document.querySelectorAll('.brand-card[data-screen]').forEach(el => {
    el.hidden = el.dataset.screen !== name;
  });
  const titles = {
    closed: '브랜드 페이지', login: '브랜드 로그인', forgot: '비밀번호 찾기', 'forgot-sent': '메일을 확인해 주세요',
    setpw: '비밀번호 설정', invite: '브랜드 초대', 'email-change': '로그인 이메일 바꾸기', 'link-invalid': '링크를 쓸 수 없어요'
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
