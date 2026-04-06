// ══════════════════════════════════════
// AUTH — ログイン・会員登録・ログアウト
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
      ${isAdmin ? `<button class="gnb-btn gnb-btn-ghost" onclick="navigate('admin')">管理者</button>` : ''}
      <button class="gnb-btn gnb-btn-ghost" onclick="navigate('mypage')">マイページ</button>
      <span class="gnb-logout" onclick="handleLogout()">ログアウト</span>
    `;
  } else {
    gnbRight.innerHTML = `
      <button class="gnb-btn gnb-btn-ghost" onclick="navigate('login')">ログイン</button>
      <button class="gnb-btn gnb-btn-red" onclick="navigate('signup')">無料登録</button>
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
  if (pw !== pw2) { errEl.textContent='パスワードが一致しません'; errEl.style.display='block'; return; }
  if (!zip || !prefecture || !city) { errEl.textContent='配送先住所を入力してください'; errEl.style.display='block'; return; }

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  const userData = {email,pw,name,ig,x:xUrl,ig_followers:igFollowers,x_followers:xFollowers,
    tiktok,tiktok_followers:tiktokFollowers,youtube,youtube_followers:youtubeFollowers,
    line_id:lineId,followers:igFollowers+xFollowers+tiktokFollowers+youtubeFollowers,
    category,address,zip,prefecture,city,building,phone,bio,created_at:new Date().toISOString()};

  await new Promise(r=>setTimeout(r,500));
  const users = demoGetUsers();
  if (users.find(u=>u.email===email)) {
    errEl.textContent='このメールアドレスはすでに使用されています'; errEl.style.display='block';
    btn.disabled=false; btn.textContent='登録完了 ✓'; return;
  }
  const user = {id:'user-'+Date.now(),...userData};
  users.push(user); demoSaveUsers(users);
  localStorage.setItem(DEMO_SESSION_KEY, JSON.stringify({id:user.id,email}));
  currentUser = {id:user.id,email}; currentUserProfile = user;

  if (!DEMO_MODE && db) {
    try {
      const {data,error} = await (db?.auth.signUp({email,password:pw}) || {data:null,error:true});
      if (!error && data.user?.id) {
        await db?.from('influencers').upsert({id:data.user.id,...userData});
      }
    } catch(e) {}
  }

  toast('登録完了！ようこそ 🎉','success');
  updateGnb();
  btn.disabled=false; btn.textContent='登録完了 ✓';
  navigate('home');
}

async function handleLogin(e) {
  e.preventDefault();
  const email = $('loginEmail').value.trim();
  const pw = $('loginPw').value;
  const errEl = $('loginError');
  const btn = $('loginBtn');
  errEl.style.display='none'; btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  if (DEMO_MODE) {
    await new Promise(r=>setTimeout(r,600));
    if (email===ADMIN_EMAIL && pw==='admin1234') {
      currentUser={id:'admin',email:ADMIN_EMAIL};
      currentUserProfile={name:'管理者',email:ADMIN_EMAIL};
      localStorage.setItem(DEMO_SESSION_KEY,JSON.stringify({id:'admin',email:ADMIN_EMAIL}));
      toast('管理者としてログインしました','success'); updateGnb();
      setTimeout(()=>{ navigate('admin'); loadAdminData(); }, 100);
      btn.disabled=false; btn.textContent='ログイン'; return;
    }
    const users = demoGetUsers();
    const user = users.find(u=>u.email===email && u.pw===pw);
    if (!user) { errEl.textContent='メールアドレスまたはパスワードが正しくありません'; errEl.style.display='block'; btn.disabled=false; btn.textContent='ログイン'; return; }
    localStorage.setItem(DEMO_SESSION_KEY,JSON.stringify({id:user.id,email}));
    currentUser={id:user.id,email}; currentUserProfile=user;
    toast('ログインしました 👋','success'); updateGnb(); navigate('home');
  } else {
    const localUsers = demoGetUsers();
    const localUser = localUsers.find(u=>u.email===email && u.pw===pw);
    if (localUser) {
      localStorage.setItem(DEMO_SESSION_KEY,JSON.stringify({id:localUser.id,email}));
      currentUser={id:localUser.id,email}; currentUserProfile=localUser;
      if (email===ADMIN_EMAIL) {
        toast('管理者としてログインしました','success'); updateGnb();
        setTimeout(()=>{ navigate('admin'); loadAdminData(); }, 100);
      } else {
        toast('ログインしました 👋','success'); updateGnb(); navigate('home');
      }
      btn.disabled=false; btn.textContent='ログイン'; return;
    }
    if (db) {
      try {
        const {data,error} = await db.auth.signInWithPassword({email,password:pw});
        if (!error && data.user) {
          currentUser = data.user;
          localStorage.setItem(DEMO_SESSION_KEY,JSON.stringify({id:data.user.id,email}));
          if (email===ADMIN_EMAIL) {
            currentUserProfile={name:'管理者',email:ADMIN_EMAIL};
            toast('管理者としてログインしました','success'); updateGnb();
            setTimeout(()=>{ navigate('admin'); loadAdminData(); }, 100);
          } else {
            const {data:profile} = await db?.from('influencers').select('*').eq('id',data.user.id).maybeSingle();
            currentUserProfile = profile;
            toast('ログインしました 👋','success'); updateGnb(); navigate('home');
          }
          btn.disabled=false; btn.textContent='ログイン'; return;
        }
      } catch(e) {}
    }
    errEl.textContent='メールアドレスまたはパスワードをご確認ください'; errEl.style.display='block';
  }
  btn.disabled=false; btn.textContent='ログイン';
}

async function handleLogout() {
  if (DEMO_MODE) { localStorage.removeItem(DEMO_SESSION_KEY); }
  else if (db) { try { await db.auth.signOut(); } catch(e){} }
  currentUser=null; currentUserProfile=null;
  toast('ログアウトしました'); updateGnb(); navigate('home');
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
    if (!kanji || !kana) { err.textContent='お名前を入力してください'; err.style.display='block'; return; }
    if (!email) { err.textContent='メールアドレスを入力してください'; err.style.display='block'; return; }
    if (!pw || pw.length < 8) { err.textContent='パスワードは8文字以上で入力してください'; err.style.display='block'; return; }
    if (pw !== pw2) { err.textContent='パスワードが一致しません'; err.style.display='block'; return; }
    err.style.display='none';
  }
  if (step === 3) {
    const ig = $('signupIg')?.value.trim();
    const igF = $('signupIgFollowers')?.value;
    const err = $('step2Error');
    if (!ig) { err.textContent='Instagram IDを入力してください（必須）'; err.style.display='block'; return; }
    if (!igF) { err.textContent='Instagramフォロワー数を入力してください（必須）'; err.style.display='block'; return; }
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
