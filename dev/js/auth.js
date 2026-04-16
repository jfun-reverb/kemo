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

async function handleSignup(e) {
  e.preventDefault();
  const name = ($('signupNameKanji')?.value||'').trim();
  const nameKana = ($('signupNameKana')?.value||'').trim();
  const email = $('signupEmail').value.trim();
  const pw = $('signupPw').value;
  const pw2 = $('signupPw2').value;
  const errEl = $('signupError');
  const btn = $('signupBtn');

  errEl.style.display='none';
  if (!name || !nameKana) { errEl.textContent=t('authError.enterName'); errEl.style.display='block'; return; }
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
    if (error) { errEl.textContent=error.message; errEl.style.display='block'; btn.disabled=false; btn.textContent=t('auth.signup.btn'); return; }
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
    errEl.textContent=t('authError.genericError') + ': ' + (e.message || String(e)); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.signup.btn'); return;
  }

  toast('Welcome to REVERB!','success');
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
      toast('Logged in as Admin','success'); updateGnb();
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
      toast('Welcome back','success'); updateGnb(); navigate('home');
    }
  } catch(e) {
    errEl.textContent=t('authError.genericError'); errEl.style.display='block';
  }
  btn.disabled=false; btn.textContent=t('auth.login.btn');
}

async function handleLogout() {
  if (db) { try { await db.auth.signOut(); } catch(e){} }
  currentUser=null; currentUserProfile=null;
  toast('Logged out'); updateGnb(); navigate('home');
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
      errEl.textContent = error.message;
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
      errEl.textContent = error.message;
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

// ── SIGNUP STEP NAVIGATION ──
function goStep(step) {
  if (step === 2) {
    const kanji = $('signupNameKanji')?.value.trim();
    const kana = $('signupNameKana')?.value.trim();
    const email = $('signupEmail')?.value.trim();
    const pw = $('signupPw')?.value;
    const pw2 = $('signupPw2')?.value;
    const err = $('step1Error');
    if (!kanji || !kana) { err.textContent=t('authError.enterName'); err.style.display='block'; return; }
    if (!email) { err.textContent=t('authError.enterEmail'); err.style.display='block'; return; }
    if (!pw || pw.length < 8) { err.textContent=t('authError.pwMin8'); err.style.display='block'; return; }
    if (pw !== pw2) { err.textContent=t('authError.pwNoMatch'); err.style.display='block'; return; }
    err.style.display='none';
  }
  if (step === 3) {
    const ig = $('signupIg')?.value.trim();
    const igF = $('signupIgFollowers')?.value;
    const err = $('step2Error');
    if (!ig) { err.textContent='Please enter Instagram ID (required)'; err.style.display='block'; return; }
    if (!igF) { err.textContent='Please enter Instagram followers (required)'; err.style.display='block'; return; }
    err.style.display='none';
  }
  [1,2,3].forEach(s => {
    const el = $('signupStep'+s);
    if (el) el.style.display = s === step ? 'block' : 'none';
  });
  [1,2,3].forEach(s => {
    if (s === 1) return;
    const c = $('step'+s+'circle');
    const l = $('step'+s+'label');
    if (c) { c.style.background = s <= step ? 'var(--pink)' : 'var(--line)'; c.style.color = s <= step ? '#fff' : 'var(--muted)'; }
    if (l) { l.style.color = s <= step ? 'var(--pink)' : 'var(--muted)'; }
  });
  var _sh=$('appShell');if(_sh)_sh.scrollTop=0;else window.scrollTo(0,0);
}
