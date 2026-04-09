// ══════════════════════════════════════
// AUTH — 로그인, 회원가입, 로그아웃
// ══════════════════════════════════════

function updateGnb() {
  const gnbRight = $('gnbRight');
  if (currentUser) {
    const isAdmin = currentUser._isAdmin || currentUser.email === ADMIN_EMAIL;
    gnbRight.innerHTML = isAdmin
      ? `<button class="gnb-btn gnb-btn-ghost" onclick="window.open('/admin/','_blank')">Admin</button>`
      : '';
  } else {
    gnbRight.innerHTML = `
      <button class="gnb-btn gnb-btn-ghost" onclick="navigate('login')">Log In</button>
      <button class="gnb-btn gnb-btn-red" onclick="navigate('signup')">Sign Up</button>
    `;
  }
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
  if (!name || !nameKana) { errEl.textContent='Please enter your name'; errEl.style.display='block'; return; }
  if (pw !== pw2) { errEl.textContent='Passwords do not match'; errEl.style.display='block'; return; }
  if (pw.length < 8) { errEl.textContent='Password must be 8+ characters'; errEl.style.display='block'; return; }

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  const userData = {
    email, name, name_kanji: name, name_kana: nameKana,
    created_at: new Date().toISOString()
  };

  if (!db) {
    errEl.textContent='Cannot connect to server'; errEl.style.display='block';
    btn.disabled=false; btn.textContent='Sign Up'; return;
  }

  try {
    const {data, error} = await db.auth.signUp({email, password: pw});
    if (error) { errEl.textContent=error.message; errEl.style.display='block'; btn.disabled=false; btn.textContent='Sign Up'; return; }
    if (data.user?.id) {
      try {
        await upsertInfluencer({id: data.user.id, ...userData});
      } catch(dbErr) {
        // DB 저장 실패해도 Auth 계정은 생성됨 — 로그인 후 프로필 저장 가능
      }
      currentUser = {id: data.user.id, email};
      currentUserProfile = {id: data.user.id, ...userData};
    }
  } catch(e) {
    errEl.textContent='Sign up error: ' + (e.message || String(e)); errEl.style.display='block';
    btn.disabled=false; btn.textContent='Sign Up'; return;
  }

  toast('Welcome to REVERB!','success');
  updateGnb();
  btn.disabled=false; btn.textContent='Sign Up';
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
    errEl.textContent='Cannot connect to server'; errEl.style.display='block';
    btn.disabled=false; btn.textContent='Log In'; return;
  }

  try {
    const {data, error} = await db.auth.signInWithPassword({email, password: pw});
    if (error) {
      errEl.textContent='Please check your email or password'; errEl.style.display='block';
      btn.disabled=false; btn.textContent='Log In'; return;
    }
    currentUser = data.user;
    // 관리자 테이블에서 확인
    const {data:adminData} = await db.from('admins').select('*').eq('auth_id', data.user.id).maybeSingle();
    if (adminData) {
      currentUser._isAdmin = true;
      currentUserProfile = {name: adminData.name || 'Admin', email};
      toast('Logged in as Admin','success'); updateGnb();
      setTimeout(() => { window.open('/admin/', '_blank'); }, 500);
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
    errEl.textContent='Login error occurred'; errEl.style.display='block';
  }
  btn.disabled=false; btn.textContent='Log In';
}

async function handleLogout() {
  if (db) { try { await db.auth.signOut(); } catch(e){} }
  currentUser=null; currentUserProfile=null;
  toast('Logged out'); updateGnb(); navigate('home');
}

// ── パスワード再設定 ──
async function handleForgotPassword(e) {
  e.preventDefault();
  const email = $('forgotEmail').value.trim();
  const errEl = $('forgotError');
  const successEl = $('forgotSuccess');
  const btn = $('forgotBtn');

  errEl.style.display = 'none';
  successEl.style.display = 'none';

  if (!db) {
    errEl.textContent = 'サーバーに接続できません';
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
      successEl.textContent = 'メールを送信しました。メールボックスをご確認ください。';
      successEl.style.display = 'block';
      $('forgotForm').reset();
    }
  } catch (err) {
    errEl.textContent = 'エラーが発生しました';
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = 'リセットメールを送信';
}

async function handleResetPassword(e) {
  e.preventDefault();
  const pw = $('resetPwNew').value;
  const pw2 = $('resetPwConfirm').value;
  const errEl = $('resetPwError');
  const btn = $('resetPwBtn');

  errEl.style.display = 'none';

  if (pw.length < 8) {
    errEl.textContent = 'パスワードは8文字以上で入力してください';
    errEl.style.display = 'block';
    return;
  }
  if (pw !== pw2) {
    errEl.textContent = 'パスワードが一致しません';
    errEl.style.display = 'block';
    return;
  }

  if (!db) {
    errEl.textContent = 'サーバーに接続できません';
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
      toast('パスワードが変更されました', 'success');
      navigate('login');
    }
  } catch (err) {
    errEl.textContent = 'エラーが発生しました';
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = 'パスワードを変更';
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
    if (!kanji || !kana) { err.textContent='Please enter your name'; err.style.display='block'; return; }
    if (!email) { err.textContent='Please enter your email'; err.style.display='block'; return; }
    if (!pw || pw.length < 8) { err.textContent='Password must be 8+ characters'; err.style.display='block'; return; }
    if (pw !== pw2) { err.textContent='Passwords do not match'; err.style.display='block'; return; }
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
