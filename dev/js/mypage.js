// ══════════════════════════════════════
// MY PAGE
// ══════════════════════════════════════
function loadMyPage() {
  if (!currentUser) { navigate('login'); return; }
  const p = currentUserProfile || {};
  const displayName = p.name_kanji || p.name || currentUser.email;
  $('mypageAv').textContent = (displayName||'U')[0].toUpperCase();
  $('mypageName').textContent = displayName;
  $('mypageHandle').textContent = p.ig ? `@${p.ig}` : p.ig_url || currentUser.email;

  // プロフィールフィールド設定
  const setVal = (id, val) => { const el = $(id); if(el) el.value = val||''; };
  setVal('profileNameKanji', p.name_kanji||p.name);
  setVal('profileNameKana', p.name_kana);
  setVal('profileCategory', p.category);
  setVal('profileLine', p.line_id);
  setVal('profileBio', p.bio);
  setVal('profileIg', p.ig||p.ig_url);
  setVal('profileIgFollowers', p.ig_followers||p.followers);
  setVal('profileX', p.x||p.x_url);
  setVal('profileXFollowers', p.x_followers);
  setVal('profileTiktok', p.tiktok);
  setVal('profileTiktokFollowers', p.tiktok_followers);
  setVal('profileYoutube', p.youtube);
  setVal('profileYoutubeFollowers', p.youtube_followers);
  setVal('profileZip', p.zip);
  if(p.prefecture && $('profilePrefecture')) $('profilePrefecture').value = p.prefecture;
  setVal('profileCity', p.city);
  setVal('profileBuilding', p.building);
  setVal('profilePhone', p.phone);
  // 口座
  setVal('bankName', p.bank_name);
  setVal('bankBranch', p.bank_branch);
  if(p.bank_type && $('bankType')) $('bankType').value = p.bank_type;
  setVal('bankNumber', p.bank_number);
  setVal('bankHolder', p.bank_holder);

  loadMyApplications();
}

async function loadMyApplications() {
  if (!currentUser) return;
  let apps = [];
  if (DEMO_MODE) {
    apps = demoGetApps().filter(a=>a.user_id===currentUser.id);
  } else {
    const {data} = await db?.from('applications').select('*,campaigns(title,emoji,brand)').eq('user_id',currentUser.id).order('created_at',{ascending:false});
    apps = data||[];
  }
  const container = $('myApplicationsList');
  if (!apps.length) {
    container.innerHTML = `<div class="empty-state"><div class="empty-icon">📋</div><div class="empty-text">まだ応募したキャンペーンはありません</div><div class="empty-sub">今すぐKブランド体験団に応募してみましょう！</div><button class="btn btn-primary" style="margin-top:16px" onclick="navigate('home')">キャンペーンを見る</button></div>`;
    return;
  }
  container.innerHTML = apps.map(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id) || DEMO_CAMPAIGNS.find(c=>c.id===a.campaign_id) || {};
    return `<div class="apply-item">
      <div class="apply-thumb">${camp.emoji||'📦'}</div>
      <div class="apply-item-info">
        <div class="apply-item-name">${camp.title||a.campaign_id}</div>
        <div class="apply-item-meta">${camp.brand||''} · 応募日 ${formatDate(a.created_at)}</div>
      </div>
      <div class="apply-item-status">${getStatusBadge(a.status)}</div>
    </div>`;
  }).join('');
}

async function saveProfile() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value||'';
  const zip = getVal('profileZip');
  const pref = getVal('profilePrefecture');
  const city = getVal('profileCity');
  const building = getVal('profileBuilding');
  const address = zip ? `〒${zip} ${pref}${city}${building?' '+building:''}` : '';
  const updated = {
    name: getVal('profileNameKanji'),
    name_kanji: getVal('profileNameKanji'),
    name_kana: getVal('profileNameKana'),
    category: getVal('profileCategory'),
    line_id: getVal('profileLine'),
    bio: getVal('profileBio'),
    ig: getVal('profileIg'), ig_followers: parseInt(getVal('profileIgFollowers'))||0,
    x: getVal('profileX'), x_followers: parseInt(getVal('profileXFollowers'))||0,
    tiktok: getVal('profileTiktok'), tiktok_followers: parseInt(getVal('profileTiktokFollowers'))||0,
    youtube: getVal('profileYoutube'), youtube_followers: parseInt(getVal('profileYoutubeFollowers'))||0,
    zip, prefecture: pref, city, building, address,
    phone: getVal('profilePhone'),
    followers: (parseInt(getVal('profileIgFollowers'))||0)+(parseInt(getVal('profileXFollowers'))||0)
  };
  if (DEMO_MODE) {
    const users = demoGetUsers();
    const idx = users.findIndex(u=>u.id===currentUser.id);
    if (idx>=0) { Object.assign(users[idx], updated); demoSaveUsers(users); currentUserProfile = users[idx]; }
  } else {
    await db?.from('influencers').update(updated).eq('id',currentUser.id);
  }
  toast('保存しました','success'); loadMyPage();
}

async function saveBankInfo() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value||'';
  const bankData = {
    bank_name: getVal('bankName'), bank_branch: getVal('bankBranch'),
    bank_type: getVal('bankType'), bank_number: getVal('bankNumber'),
    bank_holder: getVal('bankHolder')
  };
  if (DEMO_MODE) {
    const users = demoGetUsers();
    const idx = users.findIndex(u=>u.id===currentUser.id);
    if (idx>=0) { Object.assign(users[idx], bankData); demoSaveUsers(users); currentUserProfile = users[idx]; }
  } else {
    await db?.from('influencers').update(bankData).eq('id',currentUser.id);
  }
  toast('口座情報を保存しました','success');
}

async function changePassword() {
  const cur = $('currentPw')?.value;
  const nw = $('newPw')?.value;
  const nw2 = $('newPw2')?.value;
  const err = $('pwChangeError');
  err.style.display='none';
  if (!cur || !nw) { err.textContent='すべての項目を入力してください'; err.style.display='block'; return; }
  if (nw.length < 8) { err.textContent='新しいパスワードは8文字以上にしてください'; err.style.display='block'; return; }
  if (nw !== nw2) { err.textContent='パスワードが一致しません'; err.style.display='block'; return; }
  if (DEMO_MODE) { toast('パスワードを変更しました','success'); $('currentPw').value=''; $('newPw').value=''; $('newPw2').value=''; return; }
  const {error} = await db.auth.updateUser({password: nw});
  if (error) { err.textContent=error.message; err.style.display='block'; return; }
  toast('パスワードを変更しました','success');
  $('currentPw').value=''; $('newPw').value=''; $('newPw2').value='';
}

function switchMyTab(tab, el) {
  document.querySelectorAll('.mypage-tab').forEach(t=>t.classList.remove('on'));
  document.querySelectorAll('.mypage-tab-pane').forEach(t=>t.classList.remove('on'));
  el.classList.add('on'); $('tab-'+tab).classList.add('on');
}
