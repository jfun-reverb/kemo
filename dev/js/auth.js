// ══════════════════════════════════════
// AUTH — 로그인, 회원가입, 로그아웃
// ══════════════════════════════════════

function updateGnb() {
  const gnbRight = $('gnbRight');
  if (currentUser) {
    const initial = (currentUserProfile?.name || currentUser.email || 'U')[0].toUpperCase();
    const isAdmin = currentUser.email === ADMIN_EMAIL;
    gnbRight.innerHTML = `
      <div class="gnb-user">
        <div class="gnb-user-av">${initial}</div>
        <span>${currentUserProfile?.name || currentUser.email}</span>
      </div>
      ${isAdmin ? `<button class="gnb-btn gnb-btn-ghost" onclick="navigate('admin')">Admin</button>` : ''}
      <button class="gnb-btn gnb-btn-ghost" onclick="navigate('mypage')">My Page</button>
      <span class="gnb-logout" onclick="handleLogout()">Log Out</span>
    `;
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
  const ig = $('signupIg').value.trim();
  const xUrl = $('signupX').value.trim();
  const igFollowers = parseInt($('signupIgFollowers').value)||0;
  const xFollowers = parseInt($('signupXFollowers').value)||0;
  const tiktok = $('signupTiktok').value.trim();
  const tiktokFollowers = parseInt($('signupTiktokFollowers').value)||0;
  const youtube = $('signupYoutube').value.trim();
  const youtubeFollowers = parseInt($('signupYoutubeFollowers').value)||0;
  const lineId = $('signupLine').value.trim();
  const category = $('signupCategory').value;
  const bio = $('signupBio').value.trim();
  const zip = $('signupZip').value.trim();
  const prefecture = $('signupPrefecture').value;
  const city = $('signupCity').value.trim();
  const building = $('signupBuilding').value.trim();
  const phone = $('signupPhone').value.trim();
  const address = `〒${zip} ${prefecture}${city}${building?' '+building:''}`;
  const errEl = $('signupError');
  const btn = $('signupBtn');

  errEl.style.display='none';
  if (pw !== pw2) { errEl.textContent='Passwords do not match'; errEl.style.display='block'; return; }
  if (!zip || !prefecture || !city) { errEl.textContent='Please enter shipping address'; errEl.style.display='block'; return; }

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  const userData = {
    email, name, name_kanji: name, name_kana: nameKana,
    ig, x: xUrl, ig_followers: igFollowers, x_followers: xFollowers,
    tiktok, tiktok_followers: tiktokFollowers, youtube, youtube_followers: youtubeFollowers,
    line_id: lineId, followers: igFollowers + xFollowers + tiktokFollowers + youtubeFollowers,
    category, address, zip, prefecture, city, building, phone, bio,
    created_at: new Date().toISOString()
  };

  if (!db) {
    errEl.textContent='Cannot connect to server'; errEl.style.display='block';
    btn.disabled=false; btn.textContent='Sign Up ✓'; return;
  }

  try {
    const {data, error} = await db.auth.signUp({email, password: pw});
    if (error) { errEl.textContent=error.message; errEl.style.display='block'; btn.disabled=false; btn.textContent='Sign Up ✓'; return; }
    if (data.user?.id) {
      await upsertInfluencer({id: data.user.id, ...userData});
      currentUser = {id: data.user.id, email};
      currentUserProfile = {id: data.user.id, ...userData};
    }
  } catch(e) {
    errEl.textContent='Sign up error occurred'; errEl.style.display='block';
    btn.disabled=false; btn.textContent='Sign Up ✓'; return;
  }

  toast('Welcome to REVERB! 🎉','success');
  updateGnb();
  btn.disabled=false; btn.textContent='Sign Up ✓';
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
    if (email === ADMIN_EMAIL) {
      currentUserProfile = {name:'Admin', email: ADMIN_EMAIL};
      toast('Logged in as Admin','success'); updateGnb();
      setTimeout(() => { navigate('admin'); loadAdminData(); }, 100);
    } else {
      const {data:profile} = await db.from('influencers').select('*').eq('id', data.user.id).maybeSingle();
      currentUserProfile = profile;
      toast('Welcome back 👋','success'); updateGnb(); navigate('home');
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
