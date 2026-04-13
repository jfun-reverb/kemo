// ══════════════════════════════════════
// MY PAGE
// ══════════════════════════════════════
function loadMyPage() {
  if (!currentUser) { navigate('login'); return; }
  const p = currentUserProfile || {};
  const displayName = p.name_kanji || p.name || currentUser.email;
  $('mypageAv').textContent = (displayName||'U')[0].toUpperCase();
  $('mypageName').textContent = displayName;
  // SNS 대표 계정: primary_sns 설정 → 미설정 시 자동 선택
  const snsMap = {instagram: p.ig, x: p.x, tiktok: p.tiktok, youtube: p.youtube};
  const primary = p.primary_sns && snsMap[p.primary_sns] ? snsMap[p.primary_sns] : p.ig || p.x || p.tiktok || p.youtube || '';
  $('mypageHandle').textContent = primary ? `@${primary}` : '未登録';
  $('mypageEmail').textContent = currentUser.email;

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
  if(p.primary_sns && $('profilePrimarySns')) $('profilePrimarySns').value = p.primary_sns;
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

  // 미등록 배지 표시
  const hasSns = p.ig || p.x || p.tiktok || p.youtube;
  const hasAddress = p.zip && p.prefecture && p.city && p.phone;
  const hasBank = p.bank_name;
  const badgeSns = $('menuBadgeSns');
  const badgeAddr = $('menuBadgeAddress');
  const badgeBank = $('menuBadgeBank');
  if (badgeSns) badgeSns.style.display = hasSns ? 'none' : '';
  if (badgeAddr) badgeAddr.style.display = hasAddress ? 'none' : '';
  if (badgeBank) badgeBank.style.display = hasBank ? 'none' : '';

  // 필수 필드 경고 표시
  const reqMsg = 'キャンペーン応募に必須の入力項目です';
  const snsFields = [{id:'profileIg',val:p.ig},{id:'profileX',val:p.x},{id:'profileTiktok',val:p.tiktok},{id:'profileYoutube',val:p.youtube}];
  const addrFields = [{id:'profileZip',val:p.zip},{id:'profilePrefecture',val:p.prefecture},{id:'profileCity',val:p.city},{id:'profilePhone',val:p.phone}];
  const bankFields = [{id:'bankName',val:p.bank_name}];
  // SNS: 하나도 없으면 전부 경고
  if (!hasSns) snsFields.forEach(f => markRequired(f.id, reqMsg));
  else snsFields.forEach(f => clearRequired(f.id));
  // 배송지: 개별 체크
  addrFields.forEach(f => f.val ? clearRequired(f.id) : markRequired(f.id, reqMsg));
  // 입금 계좌: 개별 체크
  bankFields.forEach(f => f.val ? clearRequired(f.id) : markRequired(f.id, reqMsg));

  loadMyApplications();
}

let _myApps = [];
let _myAppsTab = 'all';

async function loadMyApplications() {
  if (!currentUser) return;
  if (db) {
    const {data} = await db.from('applications').select('*').eq('user_id', currentUser.id).order('created_at', {ascending:false});
    _myApps = data || [];
  }
  if (!allCampaigns || !allCampaigns.length) allCampaigns = await fetchCampaigns();
  renderMyApplyTabs();
  renderMyApplyList();
}

function renderMyApplyTabs() {
  const tabs = $('myApplyTabs');
  if (!tabs) return;
  const counts = {all: _myApps.length, pending: 0, approved: 0, rejected: 0};
  _myApps.forEach(a => { if (counts[a.status] !== undefined) counts[a.status]++; });
  const labels = {all:'すべて', pending:'審査中', approved:'承認', rejected:'非承認'};
  tabs.innerHTML = Object.keys(labels).map(k =>
    `<div class="apply-tab${_myAppsTab===k?' on':''}" onclick="_myAppsTab='${k}';renderMyApplyTabs();renderMyApplyList()">${labels[k]}<span class="apply-tab-count">${counts[k]}</span></div>`
  ).join('');
}

function renderMyApplyList() {
  const container = $('myApplicationsList');
  let filtered = _myAppsTab === 'all' ? _myApps.slice() : _myApps.filter(a => a.status === _myAppsTab);

  // 캠페인 상태 필터
  const campStatusFilter = $('myApplyCampStatus')?.value || '';
  if (campStatusFilter) {
    filtered = filtered.filter(a => {
      const camp = allCampaigns.find(c=>c.id===a.campaign_id);
      return camp?.status === campStatusFilter;
    });
  }

  // 정렬
  const sortVal = $('myApplySort')?.value || 'newest';
  filtered.sort((a,b) => sortVal === 'oldest'
    ? new Date(a.created_at) - new Date(b.created_at)
    : new Date(b.created_at) - new Date(a.created_at));

  if (!filtered.length) {
    container.innerHTML = `<div class="empty-state"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${_myAppsTab==='all'?'まだ応募したキャンペーンはありません':'該当する応募はありません'}</div>${_myAppsTab==='all'?'<div class="empty-sub">今すぐKブランド体験団に応募してみましょう！</div><button class="btn btn-primary" style="margin-top:16px" onclick="navigate(\'home\')">キャンペーンを見る</button>':''}</div>`;
    return;
  }
  container.innerHTML = filtered.map(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id) || {};
    const imgs = [camp.img1,camp.img2,camp.image_url].filter(Boolean);
    const thumb = imgs[0]
      ? `<img src="${esc(thumbUrl(imgs[0],240))}" data-orig="${esc(imgs[0])}" loading="lazy" decoding="async" alt="" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}">`
      : `<span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:var(--muted)">inventory_2</span>`;
    const clickAction = a.status==='approved' ? `onclick="openActivityPage('${a.id}','${a.campaign_id}','mypage')"` : `onclick="_detailFrom='mypage';openCampaign('${a.campaign_id}')"`;
    return `<div class="apply-item" style="cursor:pointer" ${clickAction}>
      <div class="apply-thumb">${thumb}</div>
      <div class="apply-item-info">
        <div class="apply-item-name">${esc(camp.title||a.campaign_id)}</div>
        <div class="apply-item-meta">${esc(camp.brand||'')} · 応募日 ${formatDate(a.created_at)}</div>
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
    primary_sns: getVal('profilePrimarySns'),
    zip, prefecture: pref, city, building, address,
    phone: getVal('profilePhone'),
    followers: (parseInt(getVal('profileIgFollowers'))||0)+(parseInt(getVal('profileXFollowers'))||0)+(parseInt(getVal('profileTiktokFollowers'))||0)+(parseInt(getVal('profileYoutubeFollowers'))||0)
  };
  try {
    await updateInfluencer(currentUser.id, updated);
    currentUserProfile = Object.assign(currentUserProfile || {}, updated);
    toast('保存しました','success'); loadMyPage();
  } catch(e) {
    toast('保存エラー: '+e.message,'error');
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
    toast('口座情報を保存しました','success');
  } catch(e) {
    toast('保存エラー: '+e.message,'error');
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
  history.pushState({page:'mypage', sub}, '', '#mypage-' + sub);
}

function closeMypageSub() {
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  $('mypage-list').classList.add('active');
  history.pushState({page:'mypage'}, '', '#mypage');
}
