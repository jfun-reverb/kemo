// ══════════════════════════════════════
// MY PAGE
// ══════════════════════════════════════
async function loadMyPage() {
  if (!currentUser) { navigate('login'); return; }
  // 진입 시마다 인플루언서 프로필 새로고침 — 관리자 화면이나 다른 탭에서 변경된
  // 이름·SNS·배송지·인증/위반 상태 등이 stale 상태로 남지 않도록.
  if (db && !currentUser._isAdmin) {
    try {
      const {data: freshProfile} = await db.from('influencers').select('*').eq('id', currentUser.id).maybeSingle();
      if (freshProfile) currentUserProfile = freshProfile;
    } catch(e) { /* 네트워크 실패 시 stale 그대로 사용 */ }
  }
  const p = currentUserProfile || {};
  const displayName = p.name_kanji || p.name || currentUser.email;
  $('mypageAv').textContent = (displayName||'U')[0].toUpperCase();
  $('mypageName').textContent = displayName;
  // Stage 6 알림은 햄버거 메뉴 모달로 이전 (refreshNotifBadge에서 처리)
  if (typeof refreshNotifBadge === 'function') refreshNotifBadge();
  // SNS 대표 계정: primary_sns 설정 → 미설정 시 자동 선택
  const snsMap = {instagram: p.ig, x: p.x, tiktok: p.tiktok, youtube: p.youtube};
  const primary = p.primary_sns && snsMap[p.primary_sns] ? snsMap[p.primary_sns] : p.ig || p.x || p.tiktok || p.youtube || '';
  $('mypageHandle').textContent = primary ? `@${primary}` : t('profile.unregistered');
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

  // SNS 입력란: blur 시 핸들 자동 추출 (URL 붙여넣기 → 핸들로 정리)
  const bindSnsExtract = (id, channel) => {
    const el = $(id);
    if (!el || el.dataset.snsExtractBound === '1') return;
    el.dataset.snsExtractBound = '1';
    el.addEventListener('blur', () => {
      const next = extractSnsHandle(channel, el.value);
      if (next !== el.value) el.value = next;
    });
  };
  bindSnsExtract('profileIg', 'instagram');
  bindSnsExtract('profileX', 'x');
  bindSnsExtract('profileTiktok', 'tiktok');
  bindSnsExtract('profileYoutube', 'youtube');
  if(p.primary_sns && $('profilePrimarySns')) $('profilePrimarySns').value = p.primary_sns;
  setVal('profileZip', p.zip);
  if(p.prefecture && $('profilePrefecture')) $('profilePrefecture').value = p.prefecture;
  setVal('profileCity', p.city);
  setVal('profileBuilding', p.building);
  setVal('profilePhone', p.phone);
  setVal('paypalEmail', p.paypal_email);
  setVal('paypalEmailConfirm', p.paypal_email);

  // 미등록 배지 표시
  // 이름은 한자·가나 둘 다 채워져야 등록으로 간주 ("-"는 미등록)
  const nameKanji = ((p.name_kanji || p.name || '') + '').trim();
  const nameKana = ((p.name_kana || '') + '').trim();
  const hasName = nameKanji && nameKanji !== '-' && nameKana && nameKana !== '-';
  const hasSns = p.ig || p.x || p.tiktok || p.youtube;
  const hasAddress = p.zip && p.prefecture && p.city && p.phone;
  const hasPaypal = !!p.paypal_email;
  const badgeName = $('menuBadgeName');
  const badgeSns = $('menuBadgeSns');
  const badgeAddr = $('menuBadgeAddress');
  const badgePaypal = $('menuBadgePaypal');
  if (badgeName) badgeName.style.display = hasName ? 'none' : '';
  if (badgeSns) badgeSns.style.display = hasSns ? 'none' : '';
  if (badgeAddr) badgeAddr.style.display = hasAddress ? 'none' : '';
  if (badgePaypal) badgePaypal.style.display = hasPaypal ? 'none' : '';

  // 필수 필드 경고 표시
  const reqMsg = t('profile.requiredHint');
  const snsFields = [{id:'profileIg',val:p.ig},{id:'profileX',val:p.x},{id:'profileTiktok',val:p.tiktok},{id:'profileYoutube',val:p.youtube}];
  const addrFields = [{id:'profileZip',val:p.zip},{id:'profilePrefecture',val:p.prefecture},{id:'profileCity',val:p.city},{id:'profilePhone',val:p.phone}];
  // SNS: 하나도 없으면 전부 경고
  if (!hasSns) snsFields.forEach(f => markRequired(f.id, reqMsg));
  else snsFields.forEach(f => clearRequired(f.id));
  // 배송지: 개별 체크
  addrFields.forEach(f => f.val ? clearRequired(f.id) : markRequired(f.id, reqMsg));
  // PayPal: 개별 체크
  if (hasPaypal) clearRequired('paypalEmail'); else markRequired('paypalEmail', reqMsg);

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
  // 캠페인 데이터도 진입 시마다 새로고침 — 응모이력 행에 노출되는 캠페인 상태/제목 stale 방지
  allCampaigns = await fetchCampaigns();
  renderMyApplyTabs();
  renderMyApplyList();
}

function renderMyApplyTabs() {
  const tabs = $('myApplyTabs');
  if (!tabs) return;
  const counts = {all: _myApps.length, pending: 0, approved: 0, rejected: 0, cancelled: 0};
  _myApps.forEach(a => { if (counts[a.status] !== undefined) counts[a.status]++; });
  const labels = {
    all:       t('appHistory.all'),
    pending:   t('appHistory.pending'),
    approved:  t('appHistory.approved'),
    rejected:  t('appHistory.rejected'),
    cancelled: t('appHistory.cancelled')
  };
  tabs.innerHTML = Object.keys(labels).map(k =>
    `<div class="apply-tab${_myAppsTab===k?' on':''}" onclick="_myAppsTab='${k}';renderMyApplyTabs();renderMyApplyList()">${labels[k]}<span class="apply-tab-count">${counts[k]}</span></div>`
  ).join('');
}

let _myDelivsByApp = {};

async function renderMyApplyList() {
  const container = $('myApplicationsList');
  let filtered = _myAppsTab === 'all' ? _myApps.slice() : _myApps.filter(a => a.status === _myAppsTab);
  // Phase 2: 비교 캐시는 매 렌더마다 초기화 — 필터 변경/언어 전환 시 stale 데이터 방지
  if (typeof _cautionCompareCache === 'object' && _cautionCompareCache) {
    Object.keys(_cautionCompareCache).forEach(k => delete _cautionCompareCache[k]);
  }

  // Stage 6: 결과물 상태 배지용 — 본인 결과물 전체를 application별 그룹핑
  if (currentUser) {
    try {
      const delivs = await fetchDeliverablesForUser({user_id: currentUser.id});
      _myDelivsByApp = {};
      delivs.forEach(d => { (_myDelivsByApp[d.application_id] ||= []).push(d); });
    } catch(e) { _myDelivsByApp = {}; }
  }

  // 캠페인 상태 필터
  const campStatusFilter = $('myApplyCampStatus')?.value || '';
  if (campStatusFilter) {
    filtered = filtered.filter(a => {
      const camp = allCampaigns.find(c=>c.id===a.campaign_id);
      return camp?.status === campStatusFilter;
    });
  }

  // 채널 필터 (공용 populateMyApplyChannelOptions에서 드롭다운 채움)
  populateMyApplyChannelOptions();
  const channelFilter = $('myApplyChannel')?.value || '';
  if (channelFilter) {
    filtered = filtered.filter(a => {
      const camp = allCampaigns.find(c=>c.id===a.campaign_id);
      if (!camp?.channel) return false;
      return camp.channel.split(',').map(s=>s.trim()).includes(channelFilter);
    });
  }

  // 정렬
  const sortVal = $('myApplySort')?.value || 'newest';
  filtered.sort((a,b) => sortVal === 'oldest'
    ? new Date(a.created_at) - new Date(b.created_at)
    : new Date(b.created_at) - new Date(a.created_at));

  if (!filtered.length) {
    container.innerHTML = `<div class="empty-state"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${_myAppsTab==='all'?t('appHistory.emptyAll'):t('appHistory.emptyFiltered')}</div>${_myAppsTab==='all'?`<div class="empty-sub">${t('appHistory.emptySub')}</div><button class="btn btn-primary" style="margin-top:16px" onclick="navigate('home')">${t('appHistory.emptyBtn')}</button>`:''}</div>`;
    return;
  }
  container.innerHTML = filtered.map(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id) || {};
    const imgs = [camp.img1,camp.img2,camp.image_url].filter(Boolean);
    const thumb = imgs[0]
      ? `<img src="${esc(imgThumb(imgs[0],120))}" data-orig="${esc(imgs[0])}" loading="lazy" decoding="async" alt="" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}">`
      : `<span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:var(--muted)">inventory_2</span>`;
    // 카드 클릭 동선:
    //   - cancelled: 사유 확인 모달 (openCancelDetailModal)
    //   - approved: 활동관리 페이지 (단, cancelled 였다가 재진입이라면 사양 §4-8에 따라 차단)
    //   - 그 외: 캠페인 상세
    const clickAction = a.status==='cancelled'
      ? `onclick="openCancelDetailModal('${a.id}')"`
      : (a.status==='approved'
          ? `onclick="openActivityPage('${a.id}','${a.campaign_id}','mypage')"`
          : `onclick="_detailFrom='mypage';openCampaign('${a.campaign_id}')"`);
    // ⋮ 메뉴: pending/approved 카드에 표시.
    //   클릭 시 액션 모달(applyActionModal) — 「결과물 제출」/「응모 취소」 선택.
    //   결과물 제출 옵션: status=approved 일 때만 활성 (pending 은 안내문만).
    //   응모 취소 옵션: 결과물 1건이라도 approved 면 비활성 (모달 내부에서 비활성 처리).
    //   cancelled/rejected 카드는 메뉴 자체 비표시.
    //   모바일 터치 영역 보강: 버튼 최소 44×44px (애플 HIG / 머티리얼 권장).
    let menuHtml = '';
    if (a.status === 'pending' || a.status === 'approved') {
      menuHtml = `<button type="button" class="apply-card-menu-btn" onclick="event.stopPropagation();openApplyActionModal('${a.id}')" aria-label="${esc(t('appHistory.action.title'))}" style="min-width:44px;min-height:44px;display:inline-flex;align-items:center;justify-content:center;border:none;background:transparent;border-radius:22px;cursor:pointer;color:var(--muted)"><span class="material-icons-round notranslate" translate="no" style="font-size:24px">more_vert</span></button>`;
    }
    // cancelled 행: 취소일 표시
    const cancelledLine = a.status === 'cancelled' && a.cancelled_at
      ? `<div class="apply-item-cancelled-at" style="font-size:11px;color:var(--muted);margin-top:2px">${esc(t('appHistory.cancelDetail.datetime'))}: ${formatDate(a.cancelled_at)}</div>`
      : '';
    // Stage 6: 결과물 상태 배지 — 당첨(approved) 신청 행 카드 하단에 「{종류} {상태}」 라벨로 노출.
    // 단순 「승인」만으론 영수증 승인/결과물 승인 구분이 안 되므로 종류 prefix를 붙임.
    // monitor 캠페인은 영수증·리뷰 캡쳐 두 단계가 별도 진행 → 라벨도 두 줄로 표시.
    let delivBadgeLine = '';
    if (a.status === 'approved') {
      const ds = (_myDelivsByApp[a.id] || []);
      // kind별로 가장 최신 1건만 추출 (재제출 시 더 최근 행 우선)
      const byKind = {};
      ds.forEach(d => {
        const cur = byKind[d.kind];
        if (!cur || (d.submitted_at || '') > (cur.submitted_at || '')) byKind[d.kind] = d;
      });
      const KIND_TO_KEY = {receipt: 'receipt', review_image: 'reviewImage', post: 'post'};
      const order = ['receipt', 'review_image', 'post'];
      const items = [];
      for (const kind of order) {
        const d = byKind[kind];
        if (!d) continue;
        const kindLabel = t('delivKind.' + (KIND_TO_KEY[kind] || kind));
        const statusLabel = t('delivStatus.' + d.status);
        let bg = '#FFF4E4', color = '#B8741A';
        if (d.status === 'approved') { bg = '#E4F5E8'; color = '#2D7A3E'; }
        else if (d.status === 'rejected') { bg = '#FFE4E4'; color = '#C33'; }
        items.push(`<span style="display:inline-block;background:${bg};color:${color};font-size:11px;font-weight:700;padding:2px 8px;border-radius:3px">${esc(kindLabel)} ${esc(statusLabel)}</span>`);
      }
      if (items.length) {
        // 영수증 제출 / 리뷰 캡쳐 등 종류별 라벨이 둘 이상이면 세로로 쌓이도록 column 배치
        delivBadgeLine = `<div class="apply-item-deliv" style="display:flex;flex-direction:column;gap:4px;align-items:flex-end">${items.join('')}</div>`;
      }
    }
    const cautionLine = a.caution_agreed_at
      ? `<div class="apply-item-caution" style="font-size:11px;color:var(--green);margin-top:2px;display:inline-flex;align-items:center;gap:3px;flex-wrap:wrap"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>${t('appHistory.cautionAgreed')} ${formatDate(a.caution_agreed_at)}${cautionCompareButton(a, camp)}</div>`
      : '';
    return `<div class="apply-item" style="cursor:pointer;position:relative" ${clickAction}>
      <div class="apply-thumb">${thumb}</div>
      <div class="apply-item-info">
        ${camp.recruit_type ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:2px">${esc(getRecruitTypeLabelJa(camp.recruit_type))}</div>` : ''}
        <div class="apply-item-name" style="display:flex;align-items:center;gap:6px;flex-wrap:wrap"><span class="apply-item-name-status">${getStatusBadge(a.status)}</span><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1">${esc(camp.title||a.campaign_id)}</span></div>
        <div class="apply-item-meta">${esc(camp.brand||'')} · ${t('appHistory.applyDate')} ${formatDate(a.created_at)}</div>
        ${cautionLine}
        ${cancelledLine}
      </div>
      <div class="apply-item-status" style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">${delivBadgeLine}${menuHtml ? `<div class="apply-item-menu">${menuHtml}</div>` : ''}</div>
    </div>`;
  }).join('');
}

// ── Phase 2: 주의사항 비교 (응모이력 셀 토글) ──
//   동의 시점 스냅샷(applications.caution_snapshot) vs 현재 캠페인 문구(campaigns.caution_items) 비교
//   동일하면 토글 자체 노출 X (변경 없을 때 노이즈 방지)
//   v1 스냅샷(lookup_labels 기반)은 비교 대상 아님 — 자동 숨김
const _cautionCompareCache = {};

function _normCautionItems(arr) {
  if (!Array.isArray(arr) || !arr.length) return [];
  return arr.map(it => ({
    html_ko: (it && it.html_ko) || '',
    html_ja: (it && it.html_ja) || '',
  }));
}

function cautionCompareButton(app, camp) {
  if (!app || !camp) return '';
  const snap = app.caution_snapshot;
  // v2 스냅샷만 비교 가능 (v1 lookup_labels 형태는 캠페인 items 와 구조가 달라 비교 의미 없음)
  if (!snap || snap.version !== 2 || !Array.isArray(snap.items)) return '';
  const snapItems = _normCautionItems(snap.items);
  const currItems = _normCautionItems(camp.caution_items);
  if (JSON.stringify(snapItems) === JSON.stringify(currItems)) return '';  // 동일 → 토글 미노출
  _cautionCompareCache[app.id] = { snap: snapItems, curr: currItems, agreedAt: app.caution_agreed_at };
  // event.stopPropagation 으로 카드 onclick 차단
  return ` <button type="button" onclick="event.stopPropagation();openCautionCompareModal('${esc(app.id)}')" style="background:#FFEFEF;color:#B3261E;border:1px solid #f5b1b1;border-radius:10px;font-size:10px;font-weight:600;padding:2px 8px;cursor:pointer;display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:12px">compare_arrows</span>${t('mypage.caution.compareToggle')}</button>`;
}

function openCautionCompareModal(appId) {
  const cached = _cautionCompareCache[appId];
  const body = $('cautionCompareModalBody');
  if (!body) return;
  const safe = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => esc(String(h||'')));
  if (!cached) {
    body.innerHTML = `<div style="padding:24px 0;color:var(--muted);font-size:13px;text-align:center">${t('mypage.caution.empty')}</div>`;
    openModal('cautionCompareModal');
    return;
  }
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const pickHtml = (it) => lang === 'ko' ? (it.html_ko || it.html_ja) : (it.html_ja || it.html_ko);
  const agreedLabel = cached.agreedAt ? formatDate(cached.agreedAt) : '';
  const renderList = (arr) => {
    if (!Array.isArray(arr) || !arr.length) return `<li style="color:var(--muted)">—</li>`;
    return arr.map(it => `<li>${safe(pickHtml(it))}</li>`).join('');
  };
  body.innerHTML = `
    <div style="display:flex;flex-direction:column;gap:14px">
      <div style="border:1px solid #d1e7d3;border-radius:10px;background:#f3faf4;padding:12px 14px">
        <div style="font-size:11px;font-weight:700;color:#1f7a1f;margin-bottom:6px;display:flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>${t('mypage.caution.agreedAt')} ${esc(agreedLabel)}</div>
        <ul style="margin:0;padding-left:18px;font-size:13px;line-height:1.7;color:var(--ink);display:flex;flex-direction:column;gap:4px">${renderList(cached.snap)}</ul>
      </div>
      <div style="border:1px solid #f5b1b1;border-radius:10px;background:#fff5f5;padding:12px 14px">
        <div style="font-size:11px;font-weight:700;color:#B3261E;margin-bottom:6px;display:flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">campaign</span>${t('mypage.caution.currentNow')}</div>
        <ul style="margin:0;padding-left:18px;font-size:13px;line-height:1.7;color:var(--ink);display:flex;flex-direction:column;gap:4px">${renderList(cached.curr)}</ul>
      </div>
      <div style="font-size:11px;color:var(--muted);line-height:1.6;background:var(--surface-container-low);border-radius:8px;padding:10px 12px">${t('mypage.caution.diffNote')}</div>
    </div>
  `;
  openModal('cautionCompareModal');
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
    toast(t('profile.saved'),'success'); loadMyPage();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}

async function savePaypalInfo() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value?.trim()||'';
  const email = getVal('paypalEmail');
  const confirm = getVal('paypalEmailConfirm');
  const err = $('paypalError');
  const showErr = msg => { if (err) { err.textContent = msg; err.style.display = 'block'; } };
  if (err) err.style.display = 'none';
  const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!email) return showErr(t('profile.paypalRequired'));
  if (!emailRe.test(email)) return showErr(t('profile.paypalInvalid'));
  if (email !== confirm) return showErr(t('profile.paypalMismatch'));
  try {
    await updateInfluencer(currentUser.id, { paypal_email: email });
    currentUserProfile = Object.assign(currentUserProfile || {}, { paypal_email: email });
    toast(t('profile.paypalSaved'),'success');
    loadMyPage();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}

async function changePassword() {
  const cur = $('currentPw')?.value;
  const nw = $('newPw')?.value;
  const nw2 = $('newPw2')?.value;
  const err = $('pwChangeError');
  err.style.display='none';
  if (!cur || !nw) { err.textContent=t('profile.fillAll'); err.style.display='block'; return; }
  if (cur === nw) { err.textContent = (typeof t==='function') ? t('auth.pwSameAsCurrent', '現在のパスワードと同じパスワードは使用できません。') : '現在のパスワードと同じパスワードは使用できません。'; err.style.display='block'; return; }
  const pwErr = (typeof validatePasswordPolicy === 'function') ? validatePasswordPolicy(nw) : null;
  if (pwErr) { err.textContent = pwErr; err.style.display='block'; return; }
  if (nw !== nw2) { err.textContent = (typeof t==='function') ? t('auth.pwMismatch', 'パスワードが一致しません。') : 'パスワードが一致しません。'; err.style.display='block'; return; }
  if (!db) { err.textContent=t('authError.serverError'); err.style.display='block'; return; }
  const {error} = await db.auth.updateUser({password: nw});
  if (error) { err.textContent=error.message; err.style.display='block'; return; }
  toast(t('profile.pwChanged'),'success');
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

// 언어 토글 버튼 상태 업데이트
function updateLangToggleUI() {
  const current = typeof getLang === 'function' ? getLang() : 'ja';
  document.querySelectorAll('.lang-toggle .lang-btn').forEach(btn => {
    btn.classList.toggle('on', btn.getAttribute('data-lang') === current);
  });
}

// 회원 탈퇴 핸들러 (i18n 대응)
function handleWithdraw() {
  const confirmMsg = typeof t === 'function' ? t('mypage.withdrawConfirm') : '本当に退会しますか？';
  const toastMsg = typeof t === 'function' ? t('mypage.withdrawToast') : '退会申請を受け付けました。運営にLINEでご連絡ください。';
  if (confirm(confirmMsg)) toast(toastMsg);
}

// 초기 + langchange 이벤트에서 토글 상태 갱신
document.addEventListener('DOMContentLoaded', updateLangToggleUI);
window.addEventListener('langchange', updateLangToggleUI);

// 응모이력: 내가 응모한 캠페인에 등장한 모든 채널을 드롭다운에 채움
function populateMyApplyChannelOptions() {
  const sel = $('myApplyChannel');
  if (!sel) return;
  const prev = sel.value;
  // 내 응모 캠페인의 채널 집합
  const chSet = new Set();
  _myApps.forEach(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id);
    if (!camp?.channel) return;
    camp.channel.split(',').map(s=>s.trim()).filter(Boolean).forEach(c => chSet.add(c));
  });
  const channels = Array.from(chSet).sort();
  const head = `<option value="" data-i18n="appHistory.allChannels">${t('appHistory.allChannels')}</option>`;
  const options = channels.map(c => `<option value="${esc(c)}">${esc(getChannelLabel(c))}</option>`).join('');
  sel.innerHTML = head + options;
  if (prev && channels.includes(prev)) sel.value = prev;
}
// Stage 6 알림 로직은 dev/js/notifications.js (햄버거 메뉴 모달)로 이전됨

// ════════════════════════════════════════════════════════════════════
// 신청 본인 취소 (migration 104, 사양 docs/specs/2026-05-11-application-cancel.md §4)
// ════════════════════════════════════════════════════════════════════

let _cancelTargetAppId = null;
let _cancelReasonsCache = null;

// 클라이언트측 cancel_phase 계산 — 서버 RPC 의 CASE 와 동일 우선순위.
// 모달 분기(단순 vs 사유 입력)와 phase 라벨 표시에 사용. 서버가 최종 검증.
function _computeCancelPhase(camp) {
  if (!camp) return 'other';
  const now = Date.now();
  const toMs = (d) => d ? Date.parse(d) : null;
  const recruitDeadline = toMs(camp.deadline);
  const purchaseStart = toMs(camp.purchase_start);
  const purchaseEnd   = toMs(camp.purchase_end);
  const visitStart    = toMs(camp.visit_start);
  const visitEnd      = toMs(camp.visit_end);
  const submissionEnd = toMs(camp.submission_end);
  if (purchaseStart && now >= purchaseStart && (!purchaseEnd || now <= purchaseEnd)) return 'purchase';
  if (visitStart    && now >= visitStart    && (!visitEnd    || now <= visitEnd))    return 'visit';
  if (submissionEnd && now > submissionEnd) return 'post';
  if (purchaseEnd   && now > purchaseEnd)   return 'post';
  if (visitEnd      && now > visitEnd)      return 'post';
  if (recruitDeadline && now <= recruitDeadline) return 'recruit';
  return 'other';
}

// ⋮ 메뉴 액션 모달: 「결과물 제출」 / 「응모 취소」 선택.
//   pending 상태:  결과물 제출 옵션 비활성(안내 텍스트만), 응모 취소 활성
//   approved 상태: 결과물 제출 옵션 활성 → 활동관리 페이지 이동
//                  응모 취소 옵션 — 결과물 1건이라도 approved 면 비활성 + tooltip
let _applyActionTargetAppId = null;

function openApplyActionModal(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  _applyActionTargetAppId = appId;
  const isApproved = app.status === 'approved';
  const ds = (_myDelivsByApp[appId] || []);
  const hasApprovedDeliv = ds.some(d => d.status === 'approved');
  // 결과물 제출 버튼: approved 만 활성. pending 은 비활성 + 안내 텍스트
  const submitBtn = $('applyActionSubmitBtn');
  const submitHint = $('applyActionSubmitHint');
  if (submitBtn && submitHint) {
    submitBtn.disabled = !isApproved;
    submitBtn.style.opacity = isApproved ? '1' : '.5';
    submitBtn.style.cursor = isApproved ? 'pointer' : 'not-allowed';
    submitBtn.onclick = isApproved
      ? () => { closeApplyActionModal(); if (typeof openActivityPage === 'function') openActivityPage(app.id, app.campaign_id, 'mypage'); }
      : null;
    submitHint.textContent = isApproved
      ? t('appHistory.action.submitHintApproved')
      : t('appHistory.action.submitHintPending');
  }
  // 응모 취소 버튼: 결과물 approved 있으면 비활성 + tooltip, 없으면 활성
  const cancelBtn = $('applyActionCancelBtn');
  const cancelHint = $('applyActionCancelHint');
  if (cancelBtn && cancelHint) {
    cancelBtn.disabled = hasApprovedDeliv;
    cancelBtn.style.opacity = hasApprovedDeliv ? '.5' : '1';
    cancelBtn.style.cursor = hasApprovedDeliv ? 'not-allowed' : 'pointer';
    cancelBtn.title = hasApprovedDeliv ? t('appHistory.cancelDisabledDeliv') : '';
    cancelBtn.onclick = hasApprovedDeliv
      ? null
      : () => { closeApplyActionModal(); openCancelModalFor(app.id); };
    cancelHint.textContent = hasApprovedDeliv
      ? t('appHistory.cancelDisabledDeliv')
      : t('appHistory.action.cancelHint');
  }
  openModal('applyActionModal');
}

function closeApplyActionModal() {
  closeModal('applyActionModal');
  _applyActionTargetAppId = null;
}

async function openCancelModalFor(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  const camp = allCampaigns.find(c => c.id === app.campaign_id) || {};
  _cancelTargetAppId = appId;
  const phase = _computeCancelPhase(camp);
  const titleEl = $('cancelModalTitle');
  if (titleEl) titleEl.textContent = t('appHistory.cancel.title');
  const campNameEl = $('cancelModalCampaign');
  if (campNameEl) campNameEl.textContent = camp.title || app.campaign_id || '';
  // recruit 단계: 단순형 — 경고/사유/동의 영역 숨김
  const isSimple = phase === 'recruit';
  const warnBox  = $('cancelModalWarning');
  const reasonBox = $('cancelModalReason');
  const noteBox  = $('cancelModalNoteWrap');
  const ackBox   = $('cancelModalAckWrap');
  const simpleBody = $('cancelModalSimpleBody');
  if (warnBox)   warnBox.style.display   = isSimple ? 'none' : 'block';
  if (reasonBox) reasonBox.style.display = isSimple ? 'none' : 'block';
  if (noteBox)   noteBox.style.display   = isSimple ? 'none' : 'block';
  if (ackBox)    ackBox.style.display    = isSimple ? 'none' : 'block';
  if (simpleBody) simpleBody.style.display = isSimple ? 'block' : 'none';
  // 경고 카피
  const warnTextEl = $('cancelModalWarningText');
  if (warnTextEl && !isSimple) {
    const key = `appHistory.cancel.warning${phase.charAt(0).toUpperCase()}${phase.slice(1)}`;
    warnTextEl.textContent = t(key);
  }
  // 사유 셀렉트: 카탈로그 캐시
  if (!isSimple) {
    if (!_cancelReasonsCache) _cancelReasonsCache = await fetchCancelReasons();
    const sel = $('cancelModalReasonSelect');
    if (sel) {
      // 현재 언어 토글에 맞춰 카테고리 라벨 선택 (ko 모드에서 한국어, 그 외 일본어)
      const lang = (typeof getLang === 'function') ? getLang() : 'ja';
      const pickLabel = (r) => (lang === 'ko' ? (r.name_ko || r.name_ja) : (r.name_ja || r.name_ko));
      const placeholder = `<option value="">${esc(t('appHistory.cancel.reasonSelect'))}</option>`;
      const opts = _cancelReasonsCache.map(r => `<option value="${esc(r.code)}">${esc(pickLabel(r))}</option>`).join('');
      sel.innerHTML = placeholder + opts;
      sel.value = '';
    }
    const note = $('cancelModalNote');
    if (note) note.value = '';
    const ack = $('cancelModalAck');
    if (ack) ack.checked = false;
  }
  // phase 정보 hidden
  const phaseEl = $('cancelModalPhase');
  if (phaseEl) phaseEl.value = phase;
  // 에러 메시지 영역 초기화
  const errEl = $('cancelModalError');
  if (errEl) { errEl.textContent = ''; errEl.style.display = 'none'; }
  openModal('cancelModal');
  // 모바일 키보드 대응: visualViewport 가 줄어들면 modal max-height 도
  // 그만큼 줄여 textarea 가 키보드 위로 보이도록.
  _attachCancelModalKeyboardSync();
}

function closeCancelModal() {
  _detachCancelModalKeyboardSync();
  closeModal('cancelModal');
  _cancelTargetAppId = null;
}

// ── 모바일 키보드 대응 ─────────────────────────────────────────
//   modal-overlay 가 position:fixed;inset:0 라 키보드가 올라와도 자동 보정
//   안 됨. visualViewport.height 로 modal max-height 동적 갱신 + textarea
//   focus 시 textarea 를 modal-body 안에서 중앙으로 스크롤.
let _cancelModalVvHandler = null;
let _cancelModalTextareaFocusHandler = null;

function _attachCancelModalKeyboardSync() {
  if (!window.visualViewport) return;
  if (_cancelModalVvHandler) return;
  const overlay = document.getElementById('cancelModal');
  const modalEl = overlay?.querySelector('.modal');
  _cancelModalVvHandler = () => {
    if (!overlay || !overlay.classList.contains('open')) return;
    const vh = window.visualViewport.height;
    const offsetTop = window.visualViewport.offsetTop;
    // overlay 가 position:fixed;inset:0 라 키보드와 무관하게 window 전체를
    // 차지. app.js 의 appShell 보정 패턴을 그대로 적용해 overlay 를
    // visualViewport 안으로 옮긴다 → 모달이 키보드 위에 떠 있게 됨.
    overlay.style.height = vh + 'px';
    overlay.style.top = offsetTop + 'px';
    overlay.style.bottom = 'auto';
    // 모달 자체도 visualViewport 안에 fit. 32px 여백 (상하 16px 씩).
    if (modalEl) modalEl.style.maxHeight = Math.max(240, vh - 32) + 'px';
  };
  window.visualViewport.addEventListener('resize', _cancelModalVvHandler);
  window.visualViewport.addEventListener('scroll', _cancelModalVvHandler);
  _cancelModalVvHandler();

  // textarea focus 시 0.3s 후 modal-body 안에서 중앙으로 스크롤
  const ta = document.getElementById('cancelModalNote');
  if (ta) {
    _cancelModalTextareaFocusHandler = () => {
      setTimeout(() => {
        try { ta.scrollIntoView({block: 'center', behavior: 'smooth'}); } catch(_e) {}
      }, 300);
    };
    ta.addEventListener('focus', _cancelModalTextareaFocusHandler);
  }
}

function _detachCancelModalKeyboardSync() {
  if (window.visualViewport && _cancelModalVvHandler) {
    window.visualViewport.removeEventListener('resize', _cancelModalVvHandler);
    window.visualViewport.removeEventListener('scroll', _cancelModalVvHandler);
    _cancelModalVvHandler = null;
  }
  const ta = document.getElementById('cancelModalNote');
  if (ta && _cancelModalTextareaFocusHandler) {
    ta.removeEventListener('focus', _cancelModalTextareaFocusHandler);
    _cancelModalTextareaFocusHandler = null;
  }
  // overlay 위치 + 모달 max-height 원복
  const overlay = document.getElementById('cancelModal');
  if (overlay) {
    overlay.style.height = '';
    overlay.style.top = '';
    overlay.style.bottom = '';
  }
  const modalEl = document.querySelector('#cancelModal .modal');
  if (modalEl) modalEl.style.maxHeight = '';
}

async function submitCancelApplication() {
  if (!_cancelTargetAppId) return;
  const phase = $('cancelModalPhase')?.value || 'other';
  const isSimple = phase === 'recruit';
  const errEl = $('cancelModalError');
  const showErr = (msg) => {
    if (!errEl) { toast(msg, 'error'); return; }
    errEl.textContent = msg;
    errEl.style.display = 'block';
  };
  let reasonCode = null, reasonNote = null, acknowledged = false;
  if (!isSimple) {
    reasonCode = $('cancelModalReasonSelect')?.value || '';
    reasonNote = $('cancelModalNote')?.value || '';
    acknowledged = !!$('cancelModalAck')?.checked;
    if (!reasonCode) { showErr(t('appHistory.cancel.errorReason')); return; }
    if (!acknowledged) { showErr(t('appHistory.cancel.errorAck')); return; }
    if (reasonNote.length > 500) reasonNote = reasonNote.slice(0, 500);
  }
  const submitBtn = $('cancelModalSubmitBtn');
  if (submitBtn) submitBtn.disabled = true;
  const res = await cancelApplication(_cancelTargetAppId, {
    reasonCode: reasonCode || null,
    reasonNote: reasonNote || null,
    acknowledged
  });
  if (submitBtn) submitBtn.disabled = false;
  if (!res.ok) {
    const errKey = {
      'not_owner':                    'appHistory.cancel.errorOwner',
      'invalid_status':               'appHistory.cancel.errorStatus',
      'deliverable_already_approved': 'appHistory.cancel.errorDeliverable',
      'reason_required':              'appHistory.cancel.errorReason',
      'acknowledgement_required':     'appHistory.cancel.errorAck'
    }[res.error] || 'appHistory.cancel.errorGeneric';
    showErr(t(errKey));
    return;
  }
  // 성공 — 캠페인 정보로 알림 생성, 토스트, 닫기, 응모이력 새로고침
  const camp = allCampaigns.find(c => c.id === (_myApps.find(a => a.id === _cancelTargetAppId)?.campaign_id)) || {};
  try {
    if (typeof insertApplicationCancelledNotification === 'function') {
      await insertApplicationCancelledNotification(_cancelTargetAppId, camp.title || '');
    }
  } catch(_e) { /* 알림 실패는 사용자 흐름 차단 안 함 */ }
  toast(t('appHistory.cancel.success'));
  closeCancelModal();
  await loadMyApplications();
  // 활동관리 페이지에서 취소한 경우 응모이력으로 이동 (cancelled 상태는
  // 활동관리 진입 차단 대상이라 현재 페이지에 머물면 안 됨).
  const activeIsActivity = document.getElementById('page-activity')?.classList?.contains('active');
  if (activeIsActivity && typeof navigate === 'function') {
    navigate('mypage');
    if (typeof openMypageSub === 'function') openMypageSub('applications');
  }
}

async function openCancelDetailModal(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  if (!_cancelReasonsCache) _cancelReasonsCache = await fetchCancelReasons();
  const reason = _cancelReasonsCache.find(r => r.code === app.cancel_reason_code);
  const setText = (id, text) => { const el = $(id); if (el) el.textContent = text || ''; };
  setText('cancelDetailDatetime', app.cancelled_at ? formatDate(app.cancelled_at) : '—');
  // 현재 언어 토글에 맞춰 카테고리 라벨 표시
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const reasonLabel = reason ? (lang === 'ko' ? (reason.name_ko || reason.name_ja) : (reason.name_ja || reason.name_ko)) : '—';
  setText('cancelDetailCategory', reasonLabel);
  setText('cancelDetailPhase', t(`appHistory.cancelPhase.${app.cancel_phase || 'other'}`));
  // 보충 텍스트는 있을 때만 행 노출.
  // noteRow 는 display:contents 로 grid 가상 행이라 'none'↔'contents' 로 명시 복원.
  const noteRow = $('cancelDetailNoteRow');
  const noteEl  = $('cancelDetailNote');
  if (app.cancel_reason && app.cancel_reason.trim()) {
    if (noteEl) noteEl.textContent = app.cancel_reason;
    if (noteRow) noteRow.style.display = 'contents';
  } else {
    if (noteRow) noteRow.style.display = 'none';
  }
  openModal('cancelDetailModal');
}

function closeCancelDetailModal() {
  closeModal('cancelDetailModal');
}

// 활동관리 페이지 진입 시 호출 — cancelled 신청이면 회색 안내 화면으로 차단
// dev/js/application.js 의 openActivityPage / 활동관리 라우팅에서 사용
function isApplicationCancelled(appId) {
  const app = _myApps.find(a => a.id === appId);
  return !!(app && app.status === 'cancelled');
}
