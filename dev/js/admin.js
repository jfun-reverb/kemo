// ══════════════════════════════════════
// ADMIN
// ══════════════════════════════════════
function switchAdminPane(pane, el) {
  document.querySelectorAll('.admin-pane').forEach(p=>p.classList.remove('on'));
  document.querySelectorAll('.admin-si').forEach(s=>s.classList.remove('on'));
  const paneEl = $('adminPane-'+pane);
  if (paneEl) paneEl.classList.add('on');
  if (el) el.classList.add('on');
  if (pane==='applications') loadApplications();
  if (pane==='campaigns') loadAdminCampaigns();
  if (pane==='influencers') loadAdminInfluencers();
}

async function loadAdminData() {
  const camps = await fetchCampaigns();
  const users = await fetchInfluencers();
  const apps = await fetchApplications();
  const approved = apps.filter(a=>a.status==='approved');
  const pending = apps.filter(a=>a.status==='pending');

  $('kpiCampaigns').textContent = camps.length;
  $('kpiInfluencers').textContent = users.length;
  $('kpiApplications').textContent = apps.length;
  $('kpiApproved').textContent = approved.length;
  loadAdminCampaigns();
  loadAdminInfluencers();
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `📋 신청 관리${pending.length>0?`<span class="admin-si-badge">${pending.length}</span>`:''}`;

  // Recent apps
  const recent = apps.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
  $('recentAppsBody').innerHTML = recent.length ? recent.map(a=>{
    const camp = camps.find(c=>c.id===a.campaign_id)||{};
    return `<tr>
      <td><strong>${a.user_name||a.user_email}</strong><br><small style="color:var(--muted)">${a.user_email}</small></td>
      <td>${camp.emoji||'📦'} ${camp.title||a.campaign_id}</td>
      <td>${formatDate(a.created_at)}</td>
      <td>${getStatusBadge(a.status)}</td>
      <td><div style="display:flex;gap:5px">
        ${a.status==='pending'?`<button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected')">미승인</button>`:'—'}
      </div></td>
    </tr>`;
  }).join('') : '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

let adminCampTypeFilter = 'all';

function switchAdminCampTab(type, btn) {
  adminCampTypeFilter = type;
  document.querySelectorAll('[id^="adminCampTab-"]').forEach(b=>{
    b.style.color='var(--muted)'; b.style.borderBottomColor='transparent'; b.style.fontWeight='600';
  });
  btn.style.color='var(--pink)'; btn.style.borderBottomColor='var(--pink)'; btn.style.fontWeight='700';
  const titleEl = $('adminCampTableTitle');
  if (titleEl) titleEl.textContent = type==='all'?'캠페인 목록':type==='monitor'?'리뷰어 목록':'기프팅 목록';
  loadAdminCampaigns();
}

async function loadAdminCampaigns() {
  let camps = await fetchCampaigns();
  if (adminCampTypeFilter === 'monitor') camps = camps.filter(c=>c.recruit_type==='monitor');
  else if (adminCampTypeFilter === 'gifting') camps = camps.filter(c=>c.recruit_type==='gifting');
  camps = camps.slice().sort((a,b)=>{
    if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
    return new Date(b.created_at)-new Date(a.created_at);
  });
  const allApps = await fetchApplications();
  const typeLabel = t => t==='monitor'?'<span class="badge badge-blue">리뷰어</span>':t==='gifting'?'<span class="badge badge-gold">기프팅</span>':'<span class="badge badge-gray">—</span>';
  const statusBadge = s => {
    if (s==='active') return `<span class="badge badge-green" style="cursor:pointer" title="클릭으로 변경" onclick="cycleCampStatus(this,'${s}')">진행중</span>`;
    if (s==='paused') return `<span class="badge badge-gold" style="cursor:pointer" title="클릭으로 변경" onclick="cycleCampStatus(this,'${s}')">일시정지</span>`;
    return `<span class="badge badge-gray" style="cursor:pointer" title="클릭으로 변경" onclick="cycleCampStatus(this,'${s}')">종료</span>`;
  };
  $('adminCampsBody').innerHTML = camps.map((c,i)=>{
    const cnt = allApps.filter(a=>a.campaign_id===c.id).length;
    const pct = c.slots > 0 ? Math.round(cnt/c.slots*100) : 0;
    const barColor = pct>=100?'var(--red)':pct>=60?'var(--gold)':'var(--green)';
    return `<tr data-camp-id="${c.id}">
      <td style="white-space:nowrap">
        <div style="display:flex;gap:3px">
          <button class="btn btn-ghost btn-xs" ${i===0?'disabled':''} onclick="moveCampOrder('${c.id}',-1)" style="padding:2px 6px;font-size:13px">↑</button>
          <button class="btn btn-ghost btn-xs" ${i===camps.length-1?'disabled':''} onclick="moveCampOrder('${c.id}',1)" style="padding:2px 6px;font-size:13px">↓</button>
        </div>
      </td>
      <td style="max-width:200px"><strong>${c.title}</strong><div style="font-size:11px;color:var(--muted);margin-top:2px">${c.brand}</div></td>
      <td>${statusBadge(c.status)}</td>
      <td>${typeLabel(c.recruit_type)}</td>
      <td style="color:var(--muted);font-size:12px">${c.brand}</td>
      <td>
        <div style="display:flex;align-items:center;gap:8px">
          <button class="btn btn-ghost btn-xs" style="font-weight:700;color:${cnt>0?'var(--pink)':'var(--muted)'};border-color:${cnt>0?'var(--pink)':'var(--line)'}" onclick="openCampApplicants('${c.id}','${c.title.replace(/'/g,'')}')">
            ${cnt} / ${c.slots}명
          </button>
          <div style="width:48px;height:5px;background:var(--line);border-radius:3px;overflow:hidden">
            <div style="width:${Math.min(pct,100)}%;height:100%;background:${barColor};border-radius:3px"></div>
          </div>
        </div>
      </td>
      <td style="white-space:nowrap;display:flex;gap:4px">
        <button class="btn btn-primary btn-xs" onclick="openEditCampaign('${c.id}')">편집</button>
        <button class="btn btn-ghost btn-xs" onclick="openCampaign('${c.id}');navigate('detail')">상세</button>
      </td>
    </tr>`;
  }).join('') || '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>';
}

// ── 캠페인 편집 ──
async function openEditCampaign(campId) {
  const camps = await fetchCampaigns();
  const camp = camps.find(c=>c.id===campId);
  if (!camp) { toast('캠페인을 찾을 수 없습니다','error'); return; }

  const sv = (id, val) => { const el=$(id); if(el) el.value = val||''; };
  $('editCampId').value = campId;
  sv('editCampTitle', camp.title);
  sv('editCampBrand', camp.brand);
  sv('editCampProduct', camp.product);
  sv('editCampProductUrl', camp.product_url||'');
  sv('editCampSlots', camp.slots);
  sv('editCampProductPrice', camp.product_price||0);
  sv('editCampReward', camp.reward||0);
  sv('editCampDeadline', camp.deadline||'');
  sv('editCampPostDeadline', camp.post_deadline||'');
  sv('editCampDesc', camp.description||'');
  sv('editCampHashtags', camp.hashtags||'');
  sv('editCampMentions', camp.mentions||'');
  sv('editCampAppeal', camp.appeal||'');
  sv('editCampGuide', camp.guide||'');
  sv('editCampNg', camp.ng||'');
  if ($('editCampChannel')) $('editCampChannel').value = camp.channel||'instagram';
  if ($('editCampCategory')) $('editCampCategory').value = camp.category||'beauty';
  if ($('editCampStatus')) $('editCampStatus').value = camp.status||'active';

  document.querySelectorAll('[id^="edit-rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';l.style.fontWeight='600';});
  const rtEl = $('edit-rt-'+(camp.recruit_type||'monitor'));
  if (rtEl) { rtEl.style.borderColor='var(--pink)';rtEl.style.background='var(--light-pink)';rtEl.style.color='var(--pink)';rtEl.style.fontWeight='700'; }
  document.querySelectorAll('input[name="editRecruitType"]').forEach(r=>{r.checked=(r.value===(camp.recruit_type||'monitor'));});

  const ctMap = {'フィード':'feed','リール':'reels','ストーリー':'story','ショート動画':'short','動画':'video','画像':'image'};
  const selected = (camp.content_types||'').split(',').map(t=>t.trim());
  document.querySelectorAll('input[name="editContentType"]').forEach(cb=>{
    cb.checked = selected.includes(cb.value);
    toggleEditCT(cb);
  });

  switchAdminPane('edit-campaign', null);
}

function toggleEditRT(rb) {
  document.querySelectorAll('[id^="edit-rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';l.style.fontWeight='600';});
  const label=rb.closest('label');
  label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';label.style.fontWeight='700';
}

function toggleEditCT(cb) {
  const label=cb.closest('label');
  if(cb.checked){label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';}
  else{label.style.borderColor='var(--line)';label.style.background='';label.style.color='';}
}

async function saveCampaignEdit() {
  try {
    const campId = $('editCampId').value;
    if (!campId) { toast('ID를 찾을 수 없습니다','error'); return; }
    const gv = id => $(id)?.value||'';
    const title = gv('editCampTitle').trim();
    const brand = gv('editCampBrand').trim();
    if (!title||!brand) { toast('캠페인명과 브랜드명은 필수입니다','error'); return; }

    const recruitTypeEl = document.querySelector('input[name="editRecruitType"]:checked');
    const contentTypes = Array.from(document.querySelectorAll('input[name="editContentType"]:checked')).map(c=>c.value).join(',');

    const updates = {
      title, brand,
      product: gv('editCampProduct'),
      product_url: gv('editCampProductUrl'),
      slots: parseInt(gv('editCampSlots'))||20,
      recruit_type: recruitTypeEl?.value||'monitor',
      channel: gv('editCampChannel'),
      category: gv('editCampCategory'),
      content_types: contentTypes,
      product_price: parseInt(gv('editCampProductPrice'))||0,
      reward: parseInt(gv('editCampReward'))||0,
      deadline: gv('editCampDeadline')||null,
      post_deadline: gv('editCampPostDeadline')||null,
      description: gv('editCampDesc'),
      hashtags: gv('editCampHashtags'),
      mentions: gv('editCampMentions'),
      appeal: gv('editCampAppeal'),
      guide: gv('editCampGuide'),
      ng: gv('editCampNg'),
      status: gv('editCampStatus'),
    };

    await updateCampaign(campId, updates);
    allCampaigns = await fetchCampaigns();
    toast('변경 사항을 저장했습니다 ✓','success');
    const campSi = (() => { let r=null; document.querySelectorAll('.admin-si').forEach(e=>{if(e.textContent.includes('캠페인 관리'))r=e;}); return r; })();
    switchAdminPane('campaigns', campSi);
  } catch(err) {
    toast('저장 오류: '+err.message,'error');
  }
}

// 상태 순환: 진행중 → 일시정지 → 종료 → 진행중
async function cycleCampStatus(el, currentStatus) {
  const tr = el.closest('tr');
  const campId = tr?.dataset.campId;
  if (!campId) return;
  const cycle = {active:'paused', paused:'closed', closed:'active'};
  const next = cycle[currentStatus] || 'active';
  try {
    await updateCampaign(campId, {status: next});
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
    renderCampaigns(allCampaigns);
  } catch(e) {
    toast('상태 변경 오류','error');
  }
}

async function moveCampOrder(campId, dir) {
  const camps = (await fetchCampaigns()).slice().sort((a,b)=>{
    if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
    return new Date(b.created_at)-new Date(a.created_at);
  });
  camps.forEach((c,i) => { if (c.order_index==null) c.order_index = i; });
  const idx = camps.findIndex(c=>c.id===campId);
  if (idx<0) return;
  const swapIdx = idx+dir;
  if (swapIdx<0||swapIdx>=camps.length) return;
  const tmpOrder = camps[idx].order_index;
  camps[idx].order_index = camps[swapIdx].order_index;
  camps[swapIdx].order_index = tmpOrder;
  try {
    await updateCampaign(camps[idx].id, {order_index: camps[idx].order_index});
    await updateCampaign(camps[swapIdx].id, {order_index: camps[swapIdx].order_index});
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
    renderCampaigns(allCampaigns);
  } catch(e) {
    toast('순서 변경 오류','error');
  }
}

// 캠페인별 신청자 표시
let currentCampApplicantId = null;
async function openCampApplicants(campId, campTitle) {
  currentCampApplicantId = campId;
  $('campApplicantsTitle').textContent = campTitle;
  switchAdminPane('camp-applicants', null);
  loadCampApplicants();
}

async function loadCampApplicants() {
  const filter = $('campAppFilterStatus')?.value || '';
  let apps = await fetchApplications({campaign_id: currentCampApplicantId});
  const total = apps.length;
  if (filter) apps = apps.filter(a=>a.status===filter);
  const approved = apps.filter(a=>a.status==='approved').length;
  const pending = apps.filter(a=>a.status==='pending').length;

  $('campApplicantsSubtitle').textContent = `신청자 목록`;
  $('campApplicantsStats').innerHTML = `
    <span style="color:var(--ink);font-weight:600">${total}명 신청</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--green)">승인 ${approved}명</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--gold)">심사중 ${pending}명</span>
  `;

  $('campApplicantsBody').innerHTML = apps.length ? apps.map(a=>`<tr>
    <td>
      <div style="font-weight:600">${a.user_name||'—'}</div>
      <div style="font-size:11px;color:var(--muted)">${a.user_email||''}</div>
    </td>
    <td>${a.ig_id?`<a href="https://instagram.com/${a.ig_id}" target="_blank" style="color:var(--pink);font-weight:600">@${a.ig_id}</a>`:a.user_ig||'—'}</td>
    <td style="font-weight:600">${(a.user_followers||0).toLocaleString()}</td>
    <td style="max-width:200px;font-size:12px;color:var(--muted)">${a.message||'—'}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadge(a.status)}</td>
    <td><div style="display:flex;gap:5px">
      ${a.status==='pending'?`
        <button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved');loadCampApplicants()">승인</button>
        <button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected');loadCampApplicants()">✕</button>
      `:'—'}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>';
}

// ── 인플루언서 목록 ──
let currentInfTab = 'all';

async function loadAdminInfluencers() {
  const users = await fetchInfluencers();
  const cnt = ch => users.filter(u => ch==='instagram'?u.ig_followers>0:ch==='x'?u.x_followers>0:ch==='tiktok'?u.tiktok_followers>0:u.youtube_followers>0).length;
  ['instagram','x','tiktok','youtube'].forEach(ch => {
    const el = $('infCnt-'+ch);
    if (el) el.textContent = cnt(ch);
  });
  const totalEl = $('infTotalCount');
  if (totalEl) totalEl.textContent = `${users.length}명 등록`;
  renderInfTable(users, currentInfTab);
}

function switchInfTab(ch, btn) {
  currentInfTab = ch;
  document.querySelectorAll('[id^="infTab-"]').forEach(b => {
    b.style.color = 'var(--muted)'; b.style.borderBottomColor = 'transparent'; b.style.fontWeight = '600';
  });
  btn.style.color = 'var(--pink)'; btn.style.borderBottomColor = 'var(--pink)'; btn.style.fontWeight = '700';
  loadAdminInfluencers();
}

function renderInfTable(users, ch) {
  const titleEl = $('infTableTitle');
  const headEl = $('infTableHead');
  const bodyEl = $('adminInfluencersBody');
  if (!bodyEl) return;

  let filtered = users;

  if (ch === 'all') {
    if (titleEl) titleEl.textContent = '인플루언서 전체';
    if (headEl) headEl.innerHTML = '<tr><th>이름</th><th>Instagram</th><th>X(Twitter)</th><th>TikTok</th><th>YouTube</th><th>합계</th><th>LINE</th><th>배송지</th><th>계좌</th><th>등록일</th></tr>';
    bodyEl.innerHTML = filtered.length ? filtered.map(u => {
      const igF = (u.ig_followers||0).toLocaleString();
      const xF = (u.x_followers||0).toLocaleString();
      const ttF = (u.tiktok_followers||0).toLocaleString();
      const ytF = (u.youtube_followers||0).toLocaleString();
      const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)).toLocaleString();
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.bank_name ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
      return `<tr>
        <td><div style="font-weight:600">${u.name_kanji||u.name||'—'}</div><div style="font-size:11px;color:var(--muted)">${u.email}</div></td>
        <td>${u.ig?`<a href="https://instagram.com/${u.ig.replace('@','')}" target="_blank" style="color:var(--pink)">@${u.ig.replace('@','')}</a>`:'—'}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
        <td>${u.x?`@${u.x.replace('@','')}`:'—'}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
        <td>${u.tiktok?`@${u.tiktok.replace('@','')}`:'—'}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
        <td>${u.youtube?`@${u.youtube.replace('@','')}`:'—'}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
        <td style="font-weight:700;color:var(--pink)">${total}</td>
        <td style="font-size:12px;color:var(--muted)">${u.line_id||'—'}</td>
        <td style="font-size:12px;color:var(--muted)">${addr}</td>
        <td>${bank}</td>
        <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
      </tr>`;
    }).join('') : `<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>`;
  } else {
    const chLabel = {instagram:'Instagram',x:'X(Twitter)',tiktok:'TikTok',youtube:'YouTube'}[ch];
    const fKey = {instagram:'ig_followers',x:'x_followers',tiktok:'tiktok_followers',youtube:'youtube_followers'}[ch];
    const idKey = {instagram:'ig',x:'x',tiktok:'tiktok',youtube:'youtube'}[ch];
    if (titleEl) titleEl.textContent = `${chLabel} 등록자`;
    filtered = users.filter(u => u[fKey] > 0);
    if (headEl) headEl.innerHTML = `<tr><th>이름</th><th>${chLabel} ID</th><th>팔로워</th><th>LINE</th><th>배송지</th><th>계좌</th><th>등록일</th></tr>`;
    bodyEl.innerHTML = filtered.length ? filtered.sort((a,b)=>(b[fKey]||0)-(a[fKey]||0)).map(u => {
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.bank_name ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
      return `<tr>
        <td><div style="font-weight:600">${u.name_kanji||u.name||'—'}</div><div style="font-size:11px;color:var(--muted)">${u.email}</div></td>
        <td>${u[idKey]?`@${u[idKey].replace('@','')}`:'—'}</td>
        <td style="font-weight:700;color:var(--pink)">${(u[fKey]||0).toLocaleString()}명</td>
        <td style="font-size:12px;color:var(--muted)">${u.line_id||'—'}</td>
        <td style="font-size:12px;color:var(--muted)">${addr}</td>
        <td>${bank}</td>
        <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
      </tr>`;
    }).join('') : `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>`;
  }
}

// ── 신청 관리 (캠페인별) ──
let currentAppTypeTab = 'all';
let currentAppCampId = null;

async function loadApplications() {
  currentAppCampId = null;
  const listEl = $('appCampList');
  const detailEl = $('appCampDetail');
  if (listEl) listEl.style.display = '';
  if (detailEl) detailEl.style.display = 'none';
  renderAppCampList();
}

function switchAppTypeTab(type, btn) {
  currentAppTypeTab = type;
  document.querySelectorAll('[id^="appTypeTab-"]').forEach(b => {
    b.style.color = 'var(--muted)'; b.style.borderBottomColor = 'transparent'; b.style.fontWeight = '600';
  });
  btn.style.color = 'var(--pink)'; btn.style.borderBottomColor = 'var(--pink)'; btn.style.fontWeight = '700';
  renderAppCampList();
}

async function renderAppCampList() {
  const listEl = $('appCampList');
  if (!listEl) return;
  let camps = await fetchCampaigns();
  if (currentAppTypeTab === 'monitor') camps = camps.filter(c=>c.recruit_type==='monitor');
  else if (currentAppTypeTab === 'gifting') camps = camps.filter(c=>c.recruit_type==='gifting');
  const apps = await fetchApplications();
  if (!camps.length) { listEl.innerHTML = '<div style="text-align:center;color:var(--muted);padding:40px">캠페인 없음</div>'; return; }
  listEl.innerHTML = camps.map(camp => {
    const campApps = apps.filter(a=>a.campaign_id===camp.id);
    const pending = campApps.filter(a=>a.status==='pending').length;
    const approved = campApps.filter(a=>a.status==='approved').length;
    const rejected = campApps.filter(a=>a.status==='rejected').length;
    const typeLabel = camp.recruit_type==='monitor'?'<span class="badge badge-blue">리뷰어</span>':camp.recruit_type==='gifting'?'<span class="badge badge-gold">기프팅</span>':'';
    return `<div class="admin-card" style="margin-bottom:12px;cursor:pointer;transition:.15s" onclick="openAppCampDetail('${camp.id}')" onmouseenter="this.style.borderColor='var(--pink)'" onmouseleave="this.style.borderColor='var(--line)'">
      <div style="display:flex;align-items:center;justify-content:space-between;padding:16px 20px">
        <div style="flex:1;min-width:0">
          <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px">
            ${typeLabel}
            <span style="font-size:15px;font-weight:700;color:var(--ink)">${camp.title}</span>
          </div>
          <div style="font-size:12px;color:var(--muted)">${camp.brand} · 마감 ${formatDate(camp.deadline)}</div>
        </div>
        <div style="display:flex;align-items:center;gap:16px;flex-shrink:0">
          <div style="text-align:center">
            <div style="font-size:18px;font-weight:800;color:var(--ink)">${campApps.length}</div>
            <div style="font-size:10px;color:var(--muted)">총 신청</div>
          </div>
          <div style="text-align:center">
            <div style="font-size:18px;font-weight:800;color:var(--gold)">${pending}</div>
            <div style="font-size:10px;color:var(--muted)">심사중</div>
          </div>
          <div style="text-align:center">
            <div style="font-size:18px;font-weight:800;color:var(--green)">${approved}</div>
            <div style="font-size:10px;color:var(--muted)">승인</div>
          </div>
          <div style="text-align:center">
            <div style="font-size:18px;font-weight:800;color:var(--muted)">${rejected}</div>
            <div style="font-size:10px;color:var(--muted)">미승인</div>
          </div>
          <div style="background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:6px 14px;font-size:12px;font-weight:600;color:var(--ink)">${campApps.length} / ${camp.slots}명 →</div>
        </div>
      </div>
    </div>`;
  }).join('');
}

async function openAppCampDetail(campId) {
  currentAppCampId = campId;
  const camps = await fetchCampaigns();
  const camp = camps.find(c=>c.id===campId);
  if (!camp) return;
  $('appCampList').style.display = 'none';
  $('appCampDetail').style.display = '';
  $('appDetailCampName').textContent = camp.title;
  if ($('appDetailFilter')) $('appDetailFilter').value = '';
  renderAppDetail();
}

async function renderAppDetail() {
  const bodyEl = $('appDetailBody');
  const statsEl = $('appDetailStats');
  if (!bodyEl||!currentAppCampId) return;
  let apps = await fetchApplications({campaign_id: currentAppCampId});
  const filter = $('appDetailFilter')?.value||'';
  const users = await fetchInfluencers();
  if (statsEl) statsEl.textContent = `총 ${apps.length}명 / 승인 ${apps.filter(a=>a.status==='approved').length}명`;
  if (filter) apps = apps.filter(a=>a.status===filter);
  apps.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at));
  bodyEl.innerHTML = apps.length ? apps.map(a => {
    const u = users.find(u=>u.email===a.user_email)||{};
    const igF = (u.ig_followers||a.user_followers||0).toLocaleString();
    const xF = u.x_followers ? `X: ${u.x_followers.toLocaleString()}` : '';
    const ttF = u.tiktok_followers ? `TT: ${u.tiktok_followers.toLocaleString()}` : '';
    const ytF = u.youtube_followers ? `YT: ${u.youtube_followers.toLocaleString()}` : '';
    const others = [xF,ttF,ytF].filter(Boolean).join(' / ');
    const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)||a.user_followers||0).toLocaleString();
    return `<tr>
      <td><strong>${a.user_name||'—'}</strong><div style="font-size:11px;color:var(--muted)">${a.user_email||''} · ${u.line_id?`LINE: ${u.line_id}`:''}</div></td>
      <td>${u.ig?`<a href="https://instagram.com/${u.ig.replace('@','')}" target="_blank" style="color:var(--pink)">@${u.ig.replace('@','')}</a>`:'—'}<div style="font-size:11px;color:var(--muted)">IG: ${igF}명</div></td>
      <td style="font-size:11px;color:var(--muted)">${others||'—'}</td>
      <td style="font-weight:700;color:var(--pink)">${total}명</td>
      <td style="max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px">${a.message||'—'}</td>
      <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
      <td>${getStatusBadge(a.status)}</td>
      <td><div style="display:flex;gap:5px">
        ${a.status==='pending'?`<button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected')">미승인</button>`:'—'}
      </div></td>
    </tr>`;
  }).join('') : '<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

async function updateAppStatus(appId, status) {
  try {
    await updateApplication(appId, {status});
    toast(status==='approved'?'✓ 승인했습니다':'미승인 처리했습니다', status==='approved'?'success':'');
    if (currentAppCampId) renderAppDetail();
    else loadApplications();
    loadAdminData();
  } catch(e) {
    toast('상태 변경 오류: '+e.message,'error');
  }
}

async function addCampaign() {
  try {
  const title = $('newCampTitle').value.trim();
  const brand = $('newCampBrand').value.trim();
  const product = $('newCampProduct').value.trim();
  const productUrl = $('newCampProductUrl')?.value.trim()||'';
  const slots = parseInt($('newCampSlots').value) || parseInt($('newCampSlots').placeholder) || 20;
  const deadline = $('newCampDeadline').value;
  const img1 = campImgData[0]?.data || '';
  const contentTypes = Array.from(document.querySelectorAll('input[name="contentType"]:checked')).map(c=>c.value).join(',');
  const recruitTypeEl = document.querySelector('input[name="recruitType"]:checked');
  const recruitType = recruitTypeEl ? recruitTypeEl.value : 'monitor';
  if (!title||!brand||!product||!deadline) {
    toast('필수 항목을 모두 입력해주세요','error');
    return;
  }
  const catEmojiMap = {beauty:'💄',food:'🍜',fashion:'👗',health:'💪',other:'📦'};
  const cat = $('newCampCategory').value;
  const ch = $('newCampChannel').value;
  const existing = await fetchCampaigns();
  const minOrder = existing.length > 0 ? Math.min(...existing.map(c=>c.order_index||0)) : 0;
  const camp = {
    title, brand, product,
    type: ch==='qoo10'?'qoo10':'nano', channel:ch, category:cat,
    recruit_type: recruitType,
    order_index: minOrder - 1,
    content_types: contentTypes,
    image_url: img1,
    img1: campImgData[0]?.data||'', img2: campImgData[1]?.data||'',
    img3: campImgData[2]?.data||'', img4: campImgData[3]?.data||'',
    img5: campImgData[4]?.data||'', img6: campImgData[5]?.data||'',
    img7: campImgData[6]?.data||'', img8: campImgData[7]?.data||'',
    product_url: productUrl,
    product_price: parseInt($('newCampProductPrice')?.value)||0,
    reward: parseInt($('newCampReward').value)||0,
    slots, applied_count:0,
    deadline: deadline||null,
    post_deadline: $('newCampPostDeadline')?.value||null,
    post_days: $('newCampPostDeadline')?.value
      ? Math.ceil((new Date($('newCampPostDeadline').value) - new Date()) / (1000*60*60*24))
      : 14,
    description:$('newCampDesc').value,
    hashtags:$('newCampHashtags').value, mentions:$('newCampMentions').value,
    appeal:$('newCampAppeal')?.value||'', guide:$('newCampGuide').value, ng:$('newCampNg').value,
    status:'active'
  };

  await insertCampaign(camp);
  toast('캠페인이 등록되었습니다 🎉','success');
  campImgData.length = 0;
  renderCampImgPreview();

  ['newCampTitle','newCampBrand','newCampProduct','newCampProductUrl',
   'newCampSlots','newCampDeadline','newCampPostDeadline','newCampDesc',
   'newCampHashtags','newCampMentions','newCampAppeal','newCampGuide',
   'newCampProductPrice','newCampReward'].forEach(id => { const el=$(id); if(el) el.value=''; });
  document.querySelectorAll('input[name="recruitType"]').forEach(r=>r.checked=false);
  document.querySelectorAll('input[name="contentType"]').forEach(cb=>{
    cb.checked=false; toggleCT(cb);
  });
  document.querySelectorAll('[id^="rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';});

  allCampaigns = await fetchCampaigns();

  const allSi = document.querySelectorAll('.admin-si');
  let campSi = null;
  allSi.forEach(el => { if(el.textContent.includes('캠페인 관리')) campSi = el; });
  if (campSi) switchAdminPane('campaigns', campSi);
  else switchAdminPane('campaigns', null);
  } catch(err) {
    toast('오류: ' + (err.message||String(err)), 'error');
  }
}
