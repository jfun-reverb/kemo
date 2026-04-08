// ══════════════════════════════════════
// MY PAGE
// ══════════════════════════════════════
function loadMyPage() {
  if (!currentUser) { navigate('login'); return; }
  const p = currentUserProfile || {};
  const displayName = p.name_kanji || p.name || currentUser.email;
  $('mypageAv').textContent = (displayName||'U')[0].toUpperCase();
  $('mypageName').textContent = displayName;
  $('mypageHandle').textContent = p.ig ? `@${p.ig}` : currentUser.email;

  const setVal = (id, val) => { const el = $(id); if(el) el.value = val||''; };
  setVal('profileNameKanji', p.name_kanji||p.name);
  setVal('profileNameKana', p.name_kana);
  setVal('profileCategory', p.category);
  setVal('profileLine', p.line_id);
  setVal('profileBio', p.bio);
  setVal('profileIg', p.ig);
  setVal('profileIgFollowers', p.ig_followers||p.followers);
  setVal('profileX', p.x);
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
  if (db) {
    const {data} = await db.from('applications').select('*,campaigns(title,emoji,brand)').eq('user_id', currentUser.id).order('created_at', {ascending:false});
    apps = data || [];
  }
  const container = $('myApplicationsList');
  if (!apps.length) {
    container.innerHTML = `<div class="empty-state"><div class="empty-icon">📋</div><div class="empty-text">まだ応募したキャンペーンはありません</div><div class="empty-sub">今すぐKブランド体験団に応募してみましょう！</div><button class="btn btn-primary" style="margin-top:16px" onclick="navigate('home')">キャンペーンを見る</button></div>`;
    return;
  }
  container.innerHTML = apps.map(a => {
    const camp = a.campaigns || allCampaigns.find(c=>c.id===a.campaign_id) || {};
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
    followers: (parseInt(getVal('profileIgFollowers'))||0)+(parseInt(getVal('profileXFollowers'))||0)+(parseInt(getVal('profileTiktokFollowers'))||0)+(parseInt(getVal('profileYoutubeFollowers'))||0)
  };
  try {
    await updateInfluencer(currentUser.id, updated);
    currentUserProfile = Object.assign(currentUserProfile || {}, updated);
    toast('저장했습니다','success'); loadMyPage();
  } catch(e) {
    toast('저장 오류: '+e.message,'error');
  }
}

async function saveBankInfo() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value||'';
  const bankData = {
    bank_name: getVal('bankName'), bank_branch: getVal('bankBranch'),
    bank_type: getVal('bankType'), bank_number: getVal('bankNumber'),
    bank_holder: getVal('bankHolder')
  };
  try {
    await updateInfluencer(currentUser.id, bankData);
    currentUserProfile = Object.assign(currentUserProfile || {}, bankData);
    toast('계좌 정보를 저장했습니다','success');
  } catch(e) {
    toast('저장 오류: '+e.message,'error');
  }
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
  if (!db) { err.textContent='サーバーに接続できません'; err.style.display='block'; return; }
  const {error} = await db.auth.updateUser({password: nw});
  if (error) { err.textContent=error.message; err.style.display='block'; return; }
  toast('パスワードを変更しました','success');
  $('currentPw').value=''; $('newPw').value=''; $('newPw2').value='';
}

function openMypageSub(sub) {
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  const target = $('mypage-sub-' + sub);
  if (target) target.classList.add('active');
}

function closeMypageSub() {
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  $('mypage-list').classList.add('active');
}
