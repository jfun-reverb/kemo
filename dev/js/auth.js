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

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

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

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.signup.btn'); return;
  }

  try {
    const {data, error} = await db.auth.signUp({email, password: pw});
    // 계정 열거 방지: 이미 가입된 이메일 등 서버 원문(영문) 노출 금지, 모호한 일반 메시지로 통일
    if (error) { errEl.textContent=t('authError.signupFailed'); errEl.style.display='block'; btn.disabled=false; btn.textContent=t('auth.signup.btn'); return; }
    if (data.user?.id) {
      // 이메일 확인 대기 중인 경우 (identities가 비어있음)
      if (!data.session && data.user) {
        btn.disabled=false; btn.textContent=t('auth.signup.btn');
        errEl.style.display='none';
        $('signupFormArea').style.display='none';
        $('signupConfirmMsg').style.display='block';
        return;
      }
      try {
        await upsertInfluencer({id: data.user.id, ...userData});
      } catch(dbErr) {}
      currentUser = data.user;
      currentUserProfile = {id: data.user.id, ...userData};
    }
  } catch(e) {
    // 영문 예외 메시지 노출 금지 — 일반 안내로 통일
    errEl.textContent=t('authError.signupFailed'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.signup.btn'); return;
  }

  toast(t('auth.toast.welcome'),'success');
  updateGnb();
  btn.disabled=false; btn.textContent=t('auth.signup.btn');
  navigate('home');
}

async function handleLogin(e) {
  e.preventDefault();
  const email = $('loginEmail').value.trim();
  const pw = $('loginPw').value;
  const errEl = $('loginError');
  const btn = $('loginBtn');
  errEl.style.display='none'; btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
  }

  try {
    const {data, error} = await db.auth.signInWithPassword({email, password: pw});
    if (error) {
      if (error.message?.includes('Email not confirmed')) {
        errEl.textContent=t('authError.emailUnverifiedDetail');
      } else {
        errEl.textContent=t('authError.checkCredentials');
      }
      errEl.style.display='block';
      btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
    }
    currentUser = data.user;
    // 관리자 테이블에서 확인
    const {data:adminData} = await db.from('admins').select('*').eq('auth_id', data.user.id).maybeSingle();
    if (adminData) {
      currentUser._isAdmin = true;
      currentUserProfile = {name: adminData.name || 'Admin', email};
      toast(t('auth.toast.adminLogin'),'success'); updateGnb();
      window.location.href = '/admin/';
    } else {
      const {data:profile} = await db.from('influencers').select('*').eq('id', data.user.id).maybeSingle();
      currentUserProfile = profile;
      // 프로필이 없으면 기본 프로필 생성 (회원가입 시 RLS로 실패한 경우)
      if (!profile) {
        try {
          await upsertInfluencer({id: data.user.id, email, created_at: new Date().toISOString()});
          currentUserProfile = {id: data.user.id, email};
        } catch(e) {}
      }
      toast(t('auth.toast.welcomeBack'),'success'); updateGnb(); navigate('home');
    }
  } catch(e) {
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
async function handleForgotPassword(e) {
  e.preventDefault();
  const email = $('forgotEmail').value.trim();
  const errEl = $('forgotError');
  const successEl = $('forgotSuccess');
  const btn = $('forgotBtn');

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
    const redirectUrl = location.origin + '/#reset-pw';
    const {error} = await db.auth.resetPasswordForEmail(email, {redirectTo: redirectUrl});
    if (error) {
      // 영문 서버 메시지·계정 존재 힌트 노출 금지 — 일반 안내로 통일
      errEl.textContent = t('authError.genericError');
      errEl.style.display = 'block';
    } else {
      successEl.textContent = t('auth.forgot.successMsg');
      successEl.style.display = 'block';
      $('forgotForm').reset();
    }
  } catch (err) {
    errEl.textContent = t('authError.genericError');
    errEl.style.display = 'block';
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
      errEl.textContent = t('authError.genericError');
      errEl.style.display = 'block';
    } else {
      try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
      await db.auth.signOut();
      toast(t('profile.pwChanged'), 'success');
      navigate('login');
    }
  } catch (err) {
    errEl.textContent = t('authError.genericError');
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = t('auth.reset.btn');
}

