// ══════════════════════════════════════
// ADMIN
// ══════════════════════════════════════

// ── 태그 입력 ──
function initTagInput(wrapId) {
  const wrap = $(wrapId);
  if (!wrap) return;
  const input = wrap.querySelector('.tag-input');
  if (!input || input._tagInit) return;
  input._tagInit = true;
  const targetId = input.dataset.target;
  const prefix = input.dataset.prefix || '';
  const forbidden = prefix === '#' ? '#' : '@';
  const warnEl = $('tagWarn_' + targetId);

  wrap.addEventListener('click', () => input.focus());

  input.addEventListener('input', () => {
    if (input.value.includes(forbidden)) {
      input.value = input.value.replace(new RegExp('\\' + forbidden, 'g'), '');
      if (warnEl) { warnEl.textContent = `${forbidden} 는 입력할 수 없습니다. 텍스트만 입력해주세요`; warnEl.style.display = 'block'; }
    } else {
      if (warnEl) warnEl.style.display = 'none';
    }
    // IME 입력 중 콤마 처리
    if (input.value.includes(',')) {
      const parts = input.value.split(',');
      parts.forEach(p => { const v = p.replace(/[#@]/g, '').trim(); if (v) addTag(wrapId, targetId, prefix, v); });
      input.value = '';
    }
  });

  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      const val = input.value.replace(/[,#@]/g, '').trim();
      if (val) { addTag(wrapId, targetId, prefix, val); input.value = ''; }
    }
    if (e.key === 'Backspace' && !input.value) {
      const tags = wrap.querySelectorAll('.tag-label');
      if (tags.length) tags[tags.length - 1].remove();
      syncTagValue(wrapId, targetId, prefix);
    }
  });
}

function addTag(wrapId, targetId, prefix, text) {
  const wrap = $(wrapId);
  const input = wrap.querySelector('.tag-input');
  const label = document.createElement('span');
  label.className = 'tag-label';
  label.innerHTML = `${esc(prefix + text)}<button onclick="this.parentElement.remove();syncTagValue('${wrapId}','${targetId}','${prefix}')">&times;</button>`;
  wrap.insertBefore(label, input);
  syncTagValue(wrapId, targetId, prefix);
}

function syncTagValue(wrapId, targetId, prefix) {
  const wrap = $(wrapId);
  const hidden = $(targetId);
  if (!wrap || !hidden) return;
  const tags = Array.from(wrap.querySelectorAll('.tag-label')).map(el => el.textContent.replace('×', '').trim());
  hidden.value = tags.join(',');
}

function loadTagsFromValue(wrapId, targetId, prefix, value) {
  const wrap = $(wrapId);
  if (!wrap) return;
  // 기존 태그 제거
  wrap.querySelectorAll('.tag-label').forEach(el => el.remove());
  if (!value) return;
  value.split(',').map(s => s.replace(/[#@]/g, '').trim()).filter(Boolean).forEach(t => addTag(wrapId, targetId, prefix, t));
}

// 에러 메시지를 한국어로 변환
function friendlyError(msg) {
  if (!msg) return '알 수 없는 오류 [ERR_UNKNOWN]';
  const s = String(msg);
  if (s.includes('Already registered as admin')) return '이미 관리자로 등록된 계정입니다. [ERR_ADMIN_EXISTS]';
  if (s.includes('duplicate key') || s.includes('unique constraint') || s.includes('already exists')) return '이미 등록된 데이터입니다. [ERR_DUPLICATE_23505]';
  if (s.includes('Permission denied') || s.includes('permission denied')) return '권한이 없습니다. [ERR_PERMISSION_42501]';
  if (s.includes('gen_salt') || s.includes('does not exist')) return 'DB 함수 오류입니다. 관리자에게 문의해주세요. [ERR_FUNC_42883]';
  if (s.includes('violates foreign key')) return '연결된 데이터가 있어 처리할 수 없습니다. [ERR_FK_23503]';
  if (s.includes('violates not-null')) return '필수 항목이 누락되었습니다. [ERR_NULL_23502]';
  if (s.includes('network') || s.includes('fetch') || s.includes('Failed to fetch')) return '네트워크 오류입니다. 인터넷 연결을 확인해주세요. [ERR_NETWORK]';
  if (s.includes('rate limit') || s.includes('429')) return '요청이 너무 많습니다. 잠시 후 다시 시도해주세요. [ERR_RATE_LIMIT_429]';
  if (s.includes('not found') || s.includes('no rows')) return '데이터를 찾을 수 없습니다. [ERR_NOT_FOUND_404]';
  if (s.includes('timeout') || s.includes('timed out')) return '요청 시간이 초과되었습니다. [ERR_TIMEOUT_408]';
  if (s.includes('unauthorized') || s.includes('JWT')) return '인증이 만료되었습니다. 다시 로그인해주세요. [ERR_AUTH_401]';
  if (s.includes('email_not_confirmed')) return '이메일 인증이 완료되지 않았습니다. [ERR_EMAIL_UNVERIFIED]';
  return s + ' [ERR_UNHANDLED]';
}

function switchAdminPane(pane, el, pushHistory) {
  document.querySelectorAll('.admin-pane').forEach(p=>p.classList.remove('on'));
  document.querySelectorAll('.admin-si').forEach(s=>s.classList.remove('on'));
  const paneEl = $('adminPane-'+pane);
  if (paneEl) paneEl.classList.add('on');
  // 사이드바 활성 상태를 data-pane 속성으로 검색
  if (!el) {
    const sidePane = {'add-campaign':'campaigns','edit-campaign':'campaigns',
      'camp-applicants':'campaigns','influencer-detail':'influencers'}[pane] || pane;
    el = document.querySelector('.admin-si[data-pane="'+sidePane+'"]');
  }
  if (el) el.classList.add('on');
  const loaders = {
    applications: loadApplications,
    campaigns: loadAdminCampaigns,
    influencers: loadAdminInfluencers,
    'admin-accounts': loadAdminAccounts,
    'my-account': loadMyAdminInfo,
    'lookups': loadLookupsPane,
    'deliverables': loadDeliverables
  };
  // 브라우저 히스토리 기록 (뒤로가기 지원)
  if (pushHistory !== false) {
    history.pushState({pane: pane}, '', '#' + pane);
  }
  if (pane === 'add-campaign') {
    initTagInput('tagWrap_newCampHashtags');
    initTagInput('tagWrap_newCampMentions');
    loadTagsFromValue('tagWrap_newCampHashtags', 'newCampHashtags', '#', '');
    loadTagsFromValue('tagWrap_newCampMentions', 'newCampMentions', '@', '');
    // 모집 타입 기본값: 리뷰어(monitor)
    const defaultRt = document.querySelector('input[name="recruitType"][value="monitor"]');
    if (defaultRt) { defaultRt.checked = true; toggleRT(defaultRt); }
    // lookup_values 동적 렌더
    renderChannelCheckboxes('new', 'monitor', []);
    renderContentTypeCheckboxes('new', []);
    renderCategorySelect('new', '');
    applyMinFollowersVisibility('new', 'monitor');
    applyDeadlineFieldsVisibility('new', 'monitor');
    // Quill 리치 에디터 lazy init (pane이 보여야 치수 측정 성공하므로 다음 tick)
    setTimeout(() => {
      ['newCampDesc','newCampAppeal','newCampGuide','newCampNg'].forEach(id => setRichValue(id, ''));
    }, 0);
    // 참여방법 번들 초기화 (기본 recruit_type='monitor')
    _psetState.new = [];
    populateCampPsetDropdown('new', 'monitor', null);
    renderCampSteps('new');
  }
  if (loaders[pane]) {
    return Promise.resolve(loaders[pane]());
  }
}

// 브라우저 뒤로가기/앞으로가기 처리
window.addEventListener('popstate', function(e) {
  var pane = (e.state && e.state.pane) || location.hash.replace('#','') || 'dashboard';
  // 해당 사이드바 아이템 찾기
  var sideItem = null;
  document.querySelectorAll('.admin-si').forEach(function(si) {
    if (si.getAttribute('onclick') && si.getAttribute('onclick').indexOf("'" + pane + "'") > -1) sideItem = si;
  });
  switchAdminPane(pane, sideItem, false);
});

// 관리자 이메일 목록 (배지 표시용)
var _adminEmails = [];
async function loadAdminEmails() {
  if (!db) return;
  const {data} = await db.from('admins').select('email');
  _adminEmails = (data||[]).map(a=>a.email);
}
function isAdminEmail(email) { return _adminEmails.includes(email); }
function adminBadge(email) { return isAdminEmail(email) ? ' <span style="background:var(--pink);color:#fff;font-size:9px;font-weight:700;padding:1px 6px;border-radius:4px;margin-left:4px">관리자</span>' : ''; }

async function loadAdminData() {
  await loadAdminEmails();
  const camps = await fetchCampaigns();
  const users = await fetchInfluencers();
  const apps = await fetchApplications();
  const approved = apps.filter(a=>a.status==='approved');
  const pending = apps.filter(a=>a.status==='pending');

  $('kpiCampaigns').textContent = camps.length;
  $('kpiInfluencers').textContent = users.length;
  $('kpiApplications').textContent = apps.length;
  $('kpiApproved').textContent = approved.length;
  renderCampaignBreakdown(camps);
  loadAdminCampaigns();
  loadAdminInfluencers();

  // 회원가입 차트 + KPI
  _allUsers = users;
  renderSignupKPIs(users);
  renderSignupChart(users, 30);
  renderProfileCompletion(users);
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round">assignment</span><span class="si-text">신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length>99?'99+':pending.length}</span>`:''}`;

  // Recent apps — 신청관리와 동일 UI
  const recent = apps.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
  $('recentAppsBody').innerHTML = recent.length ? recent.map(a=>{
    const camp = camps.find(c=>c.id===a.campaign_id)||{};
    const _dRem = Math.max((camp.slots||0)-apps.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    return `<tr>
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,160)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:5px">${typeLabel}<strong style="font-size:13px;cursor:pointer" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong></div>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
            ${camp.slots?`<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_dRem>0?'var(--green)':'var(--red)'};font-weight:600">${_dRem>0?_dRem+'건':'없음'}</span></div>`:''}
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${users.find(u=>u.email===a.user_email)?.id||''}')">${esc(a.user_name)||'—'}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)}</div>
      </td>
      <td style="max-width:180px;font-size:12px;color:var(--ink)">${esc(a.message)||'—'}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${_dRem<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(a.reviewed_by||'')} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
      </td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

function renderCampaignBreakdown(camps) {
  const statusEl = $('campStatusBreakdown');
  const chEl = $('campChannelBreakdown');
  if (!statusEl || !chEl) return;

  const statusDef = [
    {key:'draft', label:'준비', color:'#9aa0a6', bg:'#F1F3F4'},
    {key:'scheduled', label:'모집예정', color:'#5B7CFF', bg:'#EEF2FF'},
    {key:'active', label:'모집중', color:'#0E7E4A', bg:'#E8F7EF'},
    {key:'paused', label:'일시정지', color:'#B26A00', bg:'#FFF4E5'},
    {key:'closed', label:'종료', color:'#6B6B6B', bg:'#EEEEEE'},
  ];
  const statusCount = {};
  camps.forEach(c => { const s=c.status||'draft'; statusCount[s]=(statusCount[s]||0)+1; });
  statusEl.innerHTML = statusDef.map(s => `
    <div style="flex:1;min-width:90px;background:${s.bg};border-radius:10px;padding:10px 12px">
      <div style="font-size:20px;font-weight:800;color:${s.color}">${statusCount[s.key]||0}</div>
      <div style="font-size:11px;color:var(--muted);margin-top:2px">${s.label}</div>
    </div>`).join('');

  const chDef = [
    {key:'instagram', label:'Instagram', color:'#C13584', bg:'#FCE8F3'},
    {key:'x', label:'X(Twitter)', color:'#0F1419', bg:'#EEEEEE'},
    {key:'qoo10', label:'Qoo10', color:'#B26A00', bg:'#FFF4E5'},
    {key:'tiktok', label:'TikTok', color:'#010101', bg:'#E8F7F9'},
    {key:'youtube', label:'YouTube', color:'#C4302B', bg:'#FDECEC'},
  ];
  const chCount = {};
  camps.forEach(c => {
    (c.channel||'').split(',').map(s=>s.trim()).filter(Boolean).forEach(ch => {
      chCount[ch]=(chCount[ch]||0)+1;
    });
  });
  chEl.innerHTML = chDef.map(c => `
    <div style="flex:1;min-width:90px;background:${c.bg};border-radius:10px;padding:10px 12px">
      <div style="font-size:20px;font-weight:800;color:${c.color}">${chCount[c.key]||0}</div>
      <div style="font-size:11px;color:var(--muted);margin-top:2px">${c.label}</div>
    </div>`).join('');
}

let adminCampTypeFilter = 'all';

var adminCampSortKey = '';
var adminCampSortDir = '';

function filterAdminCampaigns() { loadAdminCampaigns(true); }

function resetCampSort() {
  adminCampSortKey = '';
  adminCampSortDir = '';
  updateSortArrows();
  updateCampTableHead();
  const btn = $('btnCampSortReset'); if (btn) btn.style.display = 'none';
  filterAdminCampaigns();
}

function updateCampSortResetBtn() {
  const btn = $('btnCampSortReset');
  if (btn) btn.style.display = adminCampSortKey ? '' : 'none';
}

function toggleCampSort(key) {
  if (adminCampSortKey === key) {
    adminCampSortDir = adminCampSortDir === 'desc' ? 'asc' : 'desc';
  } else {
    adminCampSortKey = key;
    adminCampSortDir = 'desc';
  }
  updateSortArrows();
  updateCampSortResetBtn();
  filterAdminCampaigns();
}

function updateSortArrows() {
  document.querySelectorAll('.sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === adminCampSortKey) {
      el.classList.add(adminCampSortDir);
      el.textContent = adminCampSortDir === 'asc' ? '▲' : '▼';
    }
  });
}

var adminReorderMode = false;

function resetCampFilters() {
  adminCampSortKey = '';
  adminCampSortDir = '';
  const search = $('adminCampSearch'); if (search) search.value = '';
  const status = $('adminCampStatusFilter'); if (status) status.value = 'all';
  const type = $('adminCampTypeFilter'); if (type) type.value = 'all';
  updateSortArrows();
}

function updateCampTableHead() {
  const head = $('adminCampTableHead');
  if (!head) return;
  if (adminReorderMode) {
    head.innerHTML = `<tr><th>순서</th><th>캠페인</th><th>상태</th><th>조회</th><th>신청</th><th>등록일</th><th>수정일</th></tr>`;
  } else {
    head.innerHTML = `<tr>
      <th>캠페인</th><th>상태 <span class="sort-arrows" data-sort="status" onclick="toggleCampSort('status')">${adminCampSortKey==='status'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>조회 <span class="sort-arrows" data-sort="views" onclick="toggleCampSort('views')">${adminCampSortKey==='views'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>신청 <span class="sort-arrows" data-sort="apps" onclick="toggleCampSort('apps')">${adminCampSortKey==='apps'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>등록일 <span class="sort-arrows" data-sort="created" onclick="toggleCampSort('created')">${adminCampSortKey==='created'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>수정일 <span class="sort-arrows" data-sort="updated" onclick="toggleCampSort('updated')">${adminCampSortKey==='updated'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th></th></tr>`;
  }
}

function enterReorderMode() {
  resetCampFilters();
  adminReorderMode = true;
  updateCampTableHead();
  filterAdminCampaigns();
  const btn = $('btnReorderMode');
  if (btn) { btn.textContent = '순서 변경 완료'; btn.onclick = exitReorderMode; btn.classList.add('btn-primary'); btn.classList.remove('btn-ghost'); }
}

function exitReorderMode() {
  adminReorderMode = false;
  updateCampTableHead();
  filterAdminCampaigns();
  const btn = $('btnReorderMode');
  if (btn) { btn.textContent = '순서 변경'; btn.onclick = enterReorderMode; btn.classList.remove('btn-primary'); btn.classList.add('btn-ghost'); }
}

// 이미지 리스트의 crop 정보를 {img1:{x,y,w,h},...} 맵으로 직렬화
function buildImageCrops(imgList) {
  const out = {};
  (imgList || []).forEach((img, i) => {
    if (i < 8 && img?.crop) out['img' + (i+1)] = img.crop;
  });
  return out;
}
// 저장된 image_crops를 imgList 항목에 주입 (편집 로드 시)
function applyImageCropsToList(imgList, cropsMap) {
  if (!cropsMap || !imgList) return;
  imgList.forEach((img, i) => {
    const key = 'img' + (i+1);
    if (cropsMap[key]) img.crop = cropsMap[key];
  });
}

async function loadAdminCampaigns(useCache) {
  let camps = useCache ? allCampaigns.slice() : await fetchCampaigns();
  if (!useCache) allCampaigns = camps.slice();

  // 상태별 건수 요약 (필터 전 전체 기준)
  const stCounts = {};
  allCampaigns.forEach(c => { stCounts[c.status] = (stCounts[c.status]||0) + 1; });
  const stLabels = {active:'모집중',scheduled:'모집예정',draft:'준비',paused:'일시정지',closed:'종료'};
  const stColors = {active:'var(--green)',scheduled:'#5B7CFF',draft:'var(--muted)',paused:'var(--gold)',closed:'var(--muted)'};
  const el = $('adminCampStatusCounts');
  if (el) el.innerHTML = Object.keys(stLabels).filter(k=>stCounts[k]).map(k =>
    `<span style="color:${stColors[k]};font-weight:600">${stLabels[k]} ${stCounts[k]}</span>`
  ).join('<span style="margin:0 4px;color:var(--line)">·</span>');

  // 타입 필터
  const typeFilter = $('adminCampTypeFilter')?.value || 'all';
  if (typeFilter !== 'all') camps = camps.filter(c => c.recruit_type === typeFilter);

  // 상태 필터
  const statusFilter = $('adminCampStatusFilter')?.value || 'all';
  if (statusFilter !== 'all') camps = camps.filter(c => c.status === statusFilter);

  // 검색 필터
  const searchVal = ($('adminCampSearch')?.value || '').trim().toLowerCase();
  if (searchVal) camps = camps.filter(c => (c.title||'').toLowerCase().includes(searchVal) || (c.brand||'').toLowerCase().includes(searchVal));

  const allApps = await fetchApplications();

  // 정렬
  const appCount = id => allApps.filter(a=>a.campaign_id===id).length;
  if (adminReorderMode) {
    camps.sort((a,b) => {
      if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
      return new Date(b.created_at)-new Date(a.created_at);
    });
  } else if (adminCampSortKey) {
    const dir = adminCampSortDir === 'asc' ? 1 : -1;
    const statusOrder = {draft:0,scheduled:1,active:2,paused:3,closed:4};
    const getVal = {
      status: c => statusOrder[c.status]??99,
      created: c => new Date(c.created_at).getTime(),
      updated: c => new Date(c.updated_at||c.created_at).getTime(),
      views: c => c.view_count||0,
      apps: c => appCount(c.id)
    };
    const fn = getVal[adminCampSortKey];
    if (fn) camps.sort((a,b) => (fn(a)-fn(b))*dir);
  } else {
    camps.sort((a,b) => new Date(b.created_at)-new Date(a.created_at));
  }

  // 필터/검색/정렬 중에는 순서 변경 비활성화
  const isFiltered = searchVal || typeFilter !== 'all' || statusFilter !== 'all' || !!adminCampSortKey;

  const typeLabel = t => getRecruitTypeBadgeKoSm(t);
  const statusLabel = {draft:'준비',scheduled:'모집예정',active:'모집중',paused:'일시정지',closed:'종료'};
  const statusBadgeClass = {draft:'badge-gray',scheduled:'badge-blue',active:'badge-green',paused:'badge-gold',closed:'badge-gray'};
  const statusBadge = s => {
    const cls = statusBadgeClass[s]||'badge-gray';
    const dashed = s==='draft' ? 'border:1.5px dashed var(--muted);' : '';
    return `<div style="position:relative;display:inline-block">
      <span class="badge ${cls}" style="cursor:pointer;${dashed}display:inline-flex;align-items:center;gap:3px" onclick="toggleStatusDropdown(this)">${statusLabel[s]||s}<span style="font-size:10px;opacity:.7">▾</span></span>
    </div>`;
  };
  $('adminCampsBody').innerHTML = camps.map((c,i)=>{
    const campApps = allApps.filter(a=>a.campaign_id===c.id);
    const approvedCnt = campApps.filter(a=>a.status==='approved').length;
    const pendingCnt = campApps.filter(a=>a.status==='pending').length;
    const pct = c.slots > 0 ? Math.round(approvedCnt/c.slots*100) : 0;
    const barColor = pct>=100?'var(--red)':pct>=60?'var(--gold)':'var(--green)';
    const imgs = [c.img1,c.img2,c.img3,c.img4,c.img5,c.img6,c.img7,c.img8,c.image_url].filter(Boolean).filter((v,idx,a)=>a.indexOf(v)===idx);
    const thumbUrl = imgs[0] || '';
    const imgCount = imgs.length;
    return `<tr data-camp-id="${c.id}">
      ${adminReorderMode ? `<td style="white-space:nowrap">
        <div style="display:flex;gap:3px">
          <button class="btn btn-ghost btn-xs" ${i===0?'disabled':''} onclick="moveCampOrder('${c.id}',-1)" style="padding:2px 6px;font-size:13px">↑</button>
          <button class="btn btn-ghost btn-xs" ${i===camps.length-1?'disabled':''} onclick="moveCampOrder('${c.id}',1)" style="padding:2px 6px;font-size:13px">↓</button>
        </div>
      </td>` : ''}
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:44px;height:44px;flex-shrink:0;border-radius:8px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? renderCroppedImg(thumbUrl, (c.image_crops||{}).img1, {thumb:160, lazy:true}) : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:20px">${esc(c.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:var(--muted)">inventory_2</span>'}</span>`}
            ${imgCount > 1 ? `<span style="position:absolute;bottom:0;left:0;background:rgba(0,0,0,.65);color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:0 4px 0 0">+${imgCount}</span>` : ''}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:5px">${typeLabel(c.recruit_type)}<strong style="cursor:pointer;color:var(--ink)" onclick="openCampPreviewModal('${c.id}')">${esc(c.title)}</strong></div>
            <div style="font-size:11px;color:var(--muted);margin-top:2px">${esc(c.brand)}</div>
            ${c.post_deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:1px">게시: ~${formatDate(c.post_deadline)} ${dDayLabel(c.post_deadline)}</div>` : ''}
          </div>
        </div>
      </td>
      <td>${statusBadge(c.status)}</td>
      <td style="font-size:13px;font-weight:600;color:var(--ink)">${(c.view_count||0).toLocaleString()}</td>
      <td>
        <div style="display:flex;align-items:center;gap:8px">
          <div style="width:48px;height:8px;background:var(--line);border-radius:4px;overflow:hidden">
            <div style="width:${Math.min(pct,100)}%;height:100%;background:${barColor};border-radius:4px"></div>
          </div>
          <button class="btn btn-ghost btn-xs" style="padding:2px 8px 4px;font-weight:700;color:${approvedCnt>0?'var(--pink)':'var(--muted)'};border-color:${approvedCnt>0?'var(--pink)':'var(--line)'}" data-camp-title="${esc(c.title)}" onclick="openCampApplicants('${c.id}',this.dataset.campTitle)">
            ${approvedCnt} / ${c.slots}명
          </button>${pendingCnt>0?`<span style="font-size:10px;font-weight:700;color:var(--gold)">+${pendingCnt}대기</span>`:''}
        </div>
        ${c.deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:12px">마감: ${formatDate(c.deadline)} ${dDayLabel(c.deadline)}</div>` : ''}
      </td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDate(c.created_at)}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDateTime(c.updated_at||c.created_at)}</td>
      ${adminReorderMode ? '' : `<td style="position:relative">
        <span class="material-icons-round camp-more-btn" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s" data-camp-title="${esc(c.title)}" onclick="toggleCampMoreMenu(event,this,'${c.id}',this.dataset.campTitle)">more_vert</span>
      </td>`}
    </tr>`;
  }).join('') || `<tr><td colspan="${adminReorderMode?8:8}" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>`;
}

// ── Quill 리치 텍스트 에디터 관리 ──
const RICH_EDITOR_IDS = ['editCampDesc','editCampAppeal','editCampGuide','editCampNg','newCampDesc','newCampAppeal','newCampGuide','newCampNg'];
const richEditors = {};

function getRichEditor(id) {
  if (richEditors[id]) return richEditors[id];
  const host = document.getElementById(id);
  if (!host || typeof Quill === 'undefined') return null;
  const q = new Quill(host, {
    theme: 'snow',
    modules: {
      toolbar: [
        [{ 'header': [2, 3, 4, false] }],
        ['bold','italic','underline','strike'],
        [{ 'list': 'ordered' }, { 'list': 'bullet' }],
        ['link','blockquote'],
        ['clean']
      ],
      clipboard: { matchVisual: false }
    },
    formats: ['header','bold','italic','underline','strike','list','link','blockquote']
  });
  richEditors[id] = q;
  return q;
}
function setRichValue(id, html) {
  const q = getRichEditor(id);
  if (!q) return;
  const safe = (typeof sanitizeRich === 'function') ? sanitizeRich(html||'') : (html||'');
  q.clipboard.dangerouslyPasteHTML(safe, 'silent');
}
function getRichValue(id) {
  const q = getRichEditor(id);
  if (!q) return '';
  const raw = q.root.innerHTML;
  // 빈 에디터 판정: Quill의 기본 placeholder 처리
  const plain = q.getText().trim();
  if (!plain) return '';
  return (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
}

// ── 캠페인 편집 ──
async function openEditCampaign(campId) {
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  const camps = await fetchCampaigns();
  const camp = camps.find(c=>c.id===campId);
  if (!camp) { toast('캠페인을 찾을 수 없습니다','error'); return; }

  const sv = (id, val) => {
    if (RICH_EDITOR_IDS.includes(id)) { setRichValue(id, val||''); return; }
    const el=$(id); if(el) el.value = val||'';
  };
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
  sv('editCampPurchaseStart', camp.purchase_start||'');
  sv('editCampPurchaseEnd', camp.purchase_end||'');
  sv('editCampVisitStart', camp.visit_start||'');
  sv('editCampVisitEnd', camp.visit_end||'');
  sv('editCampSubmissionEnd', camp.submission_end||'');
  sv('editCampWinnerAnnounce', camp.winner_announce || '選考後、LINEにてご連絡');
  sv('editCampDesc', camp.description||'');
  sv('editCampHashtags', camp.hashtags||'');
  sv('editCampMentions', camp.mentions||'');
  initTagInput('tagWrap_editCampHashtags');
  initTagInput('tagWrap_editCampMentions');
  loadTagsFromValue('tagWrap_editCampHashtags', 'editCampHashtags', '#', camp.hashtags||'');
  loadTagsFromValue('tagWrap_editCampMentions', 'editCampMentions', '@', camp.mentions||'');
  sv('editCampAppeal', camp.appeal||'');
  sv('editCampGuide', camp.guide||'');
  sv('editCampNg', camp.ng||'');
  sv('editCampMinFollowers', camp.min_followers||0);
  if ($('editCampStatus')) $('editCampStatus').value = camp.status||'active';

  // 모집 타입 라디오 복원 — 라벨 스타일 + 아이콘 상태 모두 갱신
  const rtVal = camp.recruit_type || 'monitor';
  document.querySelectorAll('input[name="editRecruitType"]').forEach(r=>{r.checked=(r.value===rtVal);});
  const checkedRt = document.querySelector(`input[name="editRecruitType"][value="${rtVal}"]`);
  if (checkedRt) toggleEditRT(checkedRt);
  applyDeadlineFieldsVisibility('edit', rtVal);

  // lookup_values 동적 렌더 (병렬)
  const selectedChannels = (camp.channel||'').split(',').map(s=>s.trim()).filter(Boolean);
  const selectedContent = (camp.content_types||'').split(',').map(t=>t.trim()).filter(Boolean);
  await Promise.all([
    renderChannelCheckboxes('edit', rtVal, selectedChannels),
    renderContentTypeCheckboxes('edit', selectedContent),
    renderCategorySelect('edit', camp.category||'')
  ]);
  // 기준 채널 선택값 복원 (없으면 첫 번째 채널)
  const primary = camp.primary_channel || selectedChannels[0] || '';
  refreshPrimaryChannelOptions('edit', primary);
  // 채널 매칭 표시 방식 복원 (기본 or)
  const matchVal = camp.channel_match === 'and' ? 'and' : 'or';
  document.querySelectorAll('input[name="editChannelMatch"]').forEach(r => r.checked = (r.value === matchVal));
  applyChannelMatchVisibility('edit');
  // 모집 타입에 따라 기준 채널/최소 팔로워수 영역 표시
  applyMinFollowersVisibility('edit', rtVal);

  // 기존 이미지 로드
  editCampImgChanged = false;
  editCampImgData.length = 0;
  [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8]
    .filter(Boolean).forEach(url => editCampImgData.push({data: url}));
  // 저장된 crop 좌표 복원
  applyImageCropsToList(editCampImgData, camp.image_crops || {});
  renderImgPreview(editCampImgData, 'editCampImgPreviewWrap', 'editCampImgCounter', 'editCampImgData');

  // 참여방법 번들 복원 (스냅샷 우선, 번들 드롭다운도 recruit_type 필터로 채움)
  _psetState.edit = Array.isArray(camp.participation_steps)
    ? camp.participation_steps.map(s => ({...s}))
    : [];
  await populateCampPsetDropdown('edit', rtVal, camp.participation_set_id || null);
  renderCampSteps('edit');

  switchAdminPane('edit-campaign', null);
}

// ── 편집용 이미지 관리 ──
var editCampImgData = [];
var editCampImgChanged = false;
registerImgList('editCampImgData', editCampImgData);

function handleEditCampImgSelect(input) {
  editCampImgChanged = true;
  addImagesToList(Array.from(input.files), editCampImgData, 'editCampImgPreviewWrap', 'editCampImgCounter', 'editCampImgData');
  input.value = '';
}

function removeEditCampImg(idx) {
  editCampImgChanged = true;
  editCampImgData.splice(idx, 1);
  renderImgPreview(editCampImgData, 'editCampImgPreviewWrap', 'editCampImgCounter', 'editCampImgData');
}

// 커스텀 confirm 모달 (Promise 반환)
let _confirmResolver = null;
function showConfirm(message) {
  return new Promise(resolve => {
    _confirmResolver = resolve;
    const msg = $('confirmModalMessage');
    if (msg) msg.textContent = message;
    openModal('confirmModal');
  });
}
function resolveConfirmModal(ok) {
  closeModal('confirmModal');
  if (_confirmResolver) { _confirmResolver(!!ok); _confirmResolver = null; }
}

// 모집 마감일 입력 시 게시 마감일을 +14일로 자동 채우기 (확인 모달)
async function suggestPostDeadline(deadlineId, postDeadlineId) {
  const dl = $(deadlineId)?.value;
  if (!dl) return;
  const post = new Date(dl);
  post.setDate(post.getDate() + 14);
  const yyyy = post.getFullYear();
  const mm = String(post.getMonth() + 1).padStart(2, '0');
  const dd = String(post.getDate()).padStart(2, '0');
  const suggested = `${yyyy}-${mm}-${dd}`;
  const postEl = $(postDeadlineId);
  if (!postEl) return;
  // 이미 입력된 값이 같으면 무시
  if (postEl.value === suggested) return;
  const ok = await showConfirm(`게시 마감일을 ${yyyy}년 ${mm}월 ${dd}일로 입력하시겠습니까?\n(모집 마감일 + 2주)`);
  if (ok) postEl.value = suggested;
}

function validateDeadlines(deadlineId, postDeadlineId, warnId) {
  const dl = $(deadlineId)?.value;
  const pdl = $(postDeadlineId)?.value;
  const warn = $(warnId);
  if (!warn) return;
  if (dl && pdl && new Date(pdl) < new Date(dl)) {
    warn.textContent = '게시 마감일은 모집 마감일 이후여야 합니다';
    warn.style.display = 'block';
  } else {
    warn.style.display = 'none';
  }
}

async function saveCampaignEdit() {
  try {
    const campId = $('editCampId').value;
    if (!campId) { toast('ID를 찾을 수 없습니다','error'); return; }
    const gv = id => {
      if (RICH_EDITOR_IDS.includes(id)) return getRichValue(id);
      return $(id)?.value||'';
    };
    const title = gv('editCampTitle').trim();
    const brand = gv('editCampBrand').trim();
    if (!title||!brand) { toast('캠페인명과 브랜드명은 필수입니다','error'); return; }

    const editDeadline = gv('editCampDeadline');
    const editPostDeadline = gv('editCampPostDeadline');
    if (editPostDeadline && editDeadline && new Date(editPostDeadline) < new Date(editDeadline)) {
      toast('게시 마감일은 모집 마감일 이후여야 합니다','error');
      return;
    }
    const editStatus = gv('editCampStatus');
    if (editDeadline && (editStatus === 'active' || editStatus === 'scheduled')) {
      const dl = new Date(editDeadline); dl.setHours(23,59,59,999);
      if (new Date() > dl) {
        const label = editStatus === 'active' ? '모집중' : '모집예정';
        toast(`모집 마감일이 지났으므로 「${label}」 상태로 저장할 수 없습니다`,'error');
        return;
      }
    }

    const recruitTypeEl = document.querySelector('input[name="editRecruitType"]:checked');
    const contentTypes = Array.from(document.querySelectorAll('input[name="editContentType"]:checked')).map(c=>c.value).join(',');

    const updates = {
      title, brand,
      product: gv('editCampProduct'),
      product_url: cleanUrl(gv('editCampProductUrl')),
      slots: parseInt(gv('editCampSlots'))||20,
      recruit_type: recruitTypeEl?.value||'monitor',
      channel: Array.from(document.querySelectorAll('input[name="editChannel"]:checked')).map(c=>c.value).join(','),
      channel_match: document.querySelector('input[name="editChannelMatch"]:checked')?.value || 'or',
      min_followers: (recruitTypeEl?.value === 'monitor') ? 0 : (parseInt(gv('editCampMinFollowers'))||0),
      primary_channel: (recruitTypeEl?.value === 'monitor') ? null : (gv('editCampPrimaryChannel') || null),
      category: gv('editCampCategory'),
      content_types: contentTypes,
      product_price: parseInt(gv('editCampProductPrice'))||0,
      reward: parseInt(gv('editCampReward'))||0,
      deadline: gv('editCampDeadline')||null,
      post_deadline: gv('editCampPostDeadline')||null,
      purchase_start: gv('editCampPurchaseStart')||null,
      purchase_end: gv('editCampPurchaseEnd')||null,
      visit_start: gv('editCampVisitStart')||null,
      visit_end: gv('editCampVisitEnd')||null,
      submission_end: gv('editCampSubmissionEnd')||null,
      winner_announce: gv('editCampWinnerAnnounce') || '選考後、LINEにてご連絡',
      description: gv('editCampDesc'),
      hashtags: gv('editCampHashtags'),
      mentions: gv('editCampMentions'),
      appeal: gv('editCampAppeal'),
      guide: gv('editCampGuide'),
      ng: gv('editCampNg'),
      status: gv('editCampStatus'),
      ...collectCampPsetPayload('edit'),
    };

    // 이미지가 변경된 경우에만 업로드
    if (editCampImgChanged) {
      toast('이미지 업로드 중...','');
      const imgUrls = await uploadCampImages(editCampImgData);
      updates.image_url = imgUrls[0];
      updates.img1 = imgUrls[0]; updates.img2 = imgUrls[1];
      updates.img3 = imgUrls[2]; updates.img4 = imgUrls[3];
      updates.img5 = imgUrls[4]; updates.img6 = imgUrls[5];
      updates.img7 = imgUrls[6]; updates.img8 = imgUrls[7];
      updates.image_crops = buildImageCrops(editCampImgData);
    }

    await updateCampaign(campId, updates);
    allCampaigns = await fetchCampaigns();
    toast('변경 사항을 저장했습니다','success');
    switchAdminPane('campaigns', null);
  } catch(err) {
    toast('저장 오류: '+friendlyError(err.message),'error');
  }
}

// 캠페인 복제
async function duplicateCampaign(campId) {
  try {
    const camps = await fetchCampaigns();
    const src = camps.find(c=>c.id===campId);
    if (!src) { toast('캠페인을 찾을 수 없습니다','error'); return; }
    const copy = {
      title: '[복사] ' + src.title,
      brand: src.brand, product: src.product, product_url: src.product_url,
      type: src.type, channel: src.channel, channel_match: src.channel_match || 'or', min_followers: src.min_followers||0, category: src.category,
      recruit_type: src.recruit_type, content_types: src.content_types,
      emoji: src.emoji, description: src.description,
      hashtags: src.hashtags, mentions: src.mentions,
      appeal: src.appeal, guide: src.guide, ng: src.ng,
      product_price: src.product_price, reward: src.reward,
      slots: src.slots, applied_count: 0,
      deadline: src.deadline, post_deadline: src.post_deadline, post_days: src.post_days,
      purchase_start: src.purchase_start, purchase_end: src.purchase_end,
      visit_start: src.visit_start, visit_end: src.visit_end,
      submission_end: src.submission_end,
      winner_announce: src.winner_announce,
      image_url: src.image_url,
      img1: src.img1, img2: src.img2, img3: src.img3, img4: src.img4,
      img5: src.img5, img6: src.img6, img7: src.img7, img8: src.img8,
      order_index: src.order_index,
      participation_set_id: src.participation_set_id || null,
      participation_steps: src.participation_steps || null,
      status: 'draft'
    };
    await insertCampaign(copy);
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
    toast('캠페인이 복제되었습니다 (준비 상태)','success');
  } catch(e) {
    toast('복제 오류: ' + friendlyError(e.message),'error');
  }
}

// 캠페인 삭제 — 캠페인 관리자(campaign_admin) 이상만 가능
function deleteCampaign(campId, campTitle) {
  // 권한 체크: campaign_admin 또는 super_admin만 삭제 가능
  var adminInfo = currentAdminInfo;
  if (!adminInfo || adminInfo.role === 'campaign_manager') {
    toast('삭제 권한이 없습니다. 캠페인 관리자 이상만 삭제할 수 있습니다.','error');
    return;
  }
  $('deleteCampId').value = campId;
  $('deleteCampTitle').value = campTitle;
  $('deleteCampName').textContent = campTitle;
  $('deleteCampConfirmInput').value = '';
  $('deleteCampError').style.display = 'none';
  $('deleteCampBtn').disabled = true;
  $('deleteCampBtn').style.opacity = '.4';
  $('deleteCampBtn').style.cursor = 'not-allowed';
  var modal = $('deleteCampModal');
  document.body.appendChild(modal);
  modal.style.display = 'flex';
}

function checkDeleteConfirm() {
  var input = $('deleteCampConfirmInput').value.trim();
  var title = $('deleteCampTitle').value;
  var btn = $('deleteCampBtn');
  if (input === title) {
    btn.disabled = false; btn.style.opacity = '1'; btn.style.cursor = 'pointer';
  } else {
    btn.disabled = true; btn.style.opacity = '.4'; btn.style.cursor = 'not-allowed';
  }
}

function closeDeleteCampModal() {
  $('deleteCampModal').style.display = 'none';
}

async function executeDeleteCampaign() {
  var campId = $('deleteCampId').value;
  var input = $('deleteCampConfirmInput').value.trim();
  var title = $('deleteCampTitle').value;
  var err = $('deleteCampError');
  if (input !== title) { err.textContent = '캠페인명이 일치하지 않습니다'; err.style.display = 'block'; return; }
  try {
    if (db) await db.from('applications').delete().eq('campaign_id', campId);
    if (db) {
      var result = await db.from('campaigns').delete().eq('id', campId);
      if (result.error) throw result.error;
    }
    closeDeleteCampModal();
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
    toast('캠페인이 삭제되었습니다','success');
  } catch(e) {
    err.textContent = '삭제 오류: ' + friendlyError(e.message); err.style.display = 'block';
  }
}

// 상태 순환: 준비 → 모집예정 → 모집중 → 일시정지 → 종료 → 준비
function openCampPreviewModal(campId) {
  const frame = $('campPreviewFrame');
  const editBtn = $('campPreviewEditBtn');
  if (!frame) return;
  frame.src = '/?v=' + Date.now() + '#detail-' + campId;
  editBtn.onclick = function() { closeModal('campPreviewModal'); openEditCampaign(campId); };
  openModal('campPreviewModal');
}

function toggleCampMoreMenu(e, btnEl, campId, campTitle) {
  e.stopPropagation();
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());

  const rect = btnEl.getBoundingClientRect();
  const menu = document.createElement('div');
  menu.className = 'camp-more-menu';
  menu.innerHTML = `
    <div class="camp-more-item" onclick="openEditCampaign('${campId}')"><span class="material-icons-round" style="font-size:16px">edit</span>편집</div>
    <div class="camp-more-item" onclick="duplicateCampaign('${campId}')"><span class="material-icons-round" style="font-size:16px">content_copy</span>복제</div>
    <div class="camp-more-item camp-more-danger" data-camp-title="${esc(campTitle)}" onclick="deleteCampaign('${campId}',this.dataset.campTitle)"><span class="material-icons-round" style="font-size:16px">delete</span>삭제</div>
  `;
  document.body.appendChild(menu);
  menu.style.left = (rect.left - menu.offsetWidth) + 'px';
  menu.style.top = rect.top + 'px';

  setTimeout(() => {
    document.addEventListener('click', function _close(ev) {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener('click', _close);
      }
    });
  }, 0);
}

function toggleStatusDropdown(badgeEl) {
  // 기존 드롭다운 닫기
  document.querySelectorAll('.status-dropdown').forEach(d => d.remove());

  const tr = badgeEl.closest('tr');
  const campId = tr?.dataset.campId;
  if (!campId) return;

  const items = [
    {val:'draft', label:'준비', cls:'badge-gray'},
    {val:'scheduled', label:'모집예정', cls:'badge-blue'},
    {val:'active', label:'모집중', cls:'badge-green'},
    {val:'paused', label:'일시정지', cls:'badge-gold'},
    {val:'closed', label:'종료', cls:'badge-gray'}
  ];

  const dd = document.createElement('div');
  dd.className = 'status-dropdown';
  dd.innerHTML = items.map(it =>
    `<div class="status-dropdown-item" onclick="changeCampStatus('${campId}','${it.val}')">
      <span class="badge ${it.cls}" style="pointer-events:none">${it.label}</span>
    </div>`
  ).join('');
  // body에 붙여 부모의 overflow:hidden 클리핑 회피
  document.body.appendChild(dd);
  const rect = badgeEl.getBoundingClientRect();
  dd.style.position = 'fixed';
  dd.style.top = (rect.bottom + 4) + 'px';
  dd.style.left = rect.left + 'px';

  // 외부 클릭 시 닫기
  setTimeout(() => {
    document.addEventListener('click', function _close(e) {
      if (!dd.contains(e.target) && e.target !== badgeEl) {
        dd.remove();
        document.removeEventListener('click', _close);
      }
    });
  }, 0);
}

async function changeCampStatus(campId, newStatus) {
  document.querySelectorAll('.status-dropdown').forEach(d => d.remove());
  if (newStatus === 'active' || newStatus === 'scheduled') {
    const camp = allCampaigns.find(c => c.id === campId);
    if (camp?.deadline) {
      const dl = new Date(camp.deadline); dl.setHours(23,59,59,999);
      if (new Date() > dl) {
        const label = newStatus === 'active' ? '모집중' : '모집예정';
        toast(`모집 마감일이 지났으므로 「${label}」으로 변경할 수 없습니다`,'error');
        return;
      }
    }
  }
  try {
    await updateCampaign(campId, {status: newStatus});
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
    if (typeof renderCampaigns === 'function') renderCampaigns(allCampaigns);
  } catch(e) {
    toast('상태 변경 오류','error');
  }
}

async function moveCampOrder(campId, dir) {
  // 로컬 캐시로 즉시 UI 업데이트
  const camps = allCampaigns.slice().sort((a,b)=>{
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

  // allCampaigns도 즉시 반영
  const a = allCampaigns.find(c=>c.id===camps[idx].id);
  const b = allCampaigns.find(c=>c.id===camps[swapIdx].id);
  if (a) a.order_index = camps[idx].order_index;
  if (b) b.order_index = camps[swapIdx].order_index;

  // 즉시 UI 업데이트 (캐시 사용)
  loadAdminCampaigns(true);
  const movedRow = document.querySelector(`tr[data-camp-id="${campId}"]`);
  if (movedRow) {
    movedRow.style.transition = 'background .3s';
    movedRow.style.background = 'rgba(200,120,163,.12)';
    setTimeout(() => { movedRow.style.background = ''; }, 600);
  }

  // DB는 백그라운드에서 저장
  try {
    await Promise.all([
      updateCampaign(camps[idx].id, {order_index: camps[idx].order_index}),
      updateCampaign(camps[swapIdx].id, {order_index: camps[swapIdx].order_index})
    ]);
  } catch(e) {
    toast('순서 저장 오류','error');
    allCampaigns = await fetchCampaigns();
    loadAdminCampaigns();
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

  const camp = allCampaigns.find(c=>c.id===currentCampApplicantId);
  const slots = camp?.slots || 0;
  const allApproved = (await fetchApplications({campaign_id: currentCampApplicantId, status: 'approved'})).length;
  const remaining = Math.max(slots - allApproved, 0);
  $('campApplicantsSlots').innerHTML = `모집 인원: <strong>${slots}명</strong> · 빈자리: <strong style="color:${remaining>0?'var(--green)':'var(--red)'}">${remaining>0?remaining+'건':'없음'}</strong>`;

  $('campApplicantsSubtitle').textContent = `신청자 목록`;
  $('campApplicantsStats').innerHTML = `
    <span style="color:var(--ink);font-weight:600">${total}명 신청</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--green)">승인 ${approved}명</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--gold)">심사중 ${pending}명</span>
  `;

  const _users = await fetchInfluencers();
  // Stage 4: 이 캠페인의 모든 결과물을 한 번에 받아 application_id로 그룹핑
  const allDelivs = await fetchDeliverablesByCampaign(currentCampApplicantId);
  const delivByApp = {};
  allDelivs.forEach(d => {
    const arr = (delivByApp[d.application_id] ||= []);
    arr.push(d);
  });
  const isPostType = (camp?.recruit_type === 'gifting' || camp?.recruit_type === 'visit');
  const selectedChannels = (camp?.channel || '').split(',').map(s=>s.trim()).filter(Boolean);
  const channelMatch = camp?.channel_match || 'or';
  $('campApplicantsBody').innerHTML = apps.length ? apps.map(a=>{
    const _u = _users.find(u=>u.email===a.user_email)||{};
    const otCell = renderOtCell(a, isPostType);
    const delivCell = renderDelivCell(delivByApp[a.id] || [], a.status, selectedChannels, channelMatch, isPostType);
    return `<tr>
    <td>
      <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${adminBadge(a.user_email)}</div>
      <div style="font-size:11px;color:var(--muted)">${[esc(a.user_email)||'', _u.line_id?`LINE: ${esc(_u.line_id)}`:''].filter(Boolean).join(' · ')}</div>
    </td>
    <td>${a.ig_id?`<a href="https://instagram.com/${esc(a.ig_id)}" target="_blank" style="color:var(--pink);font-weight:600">@${esc(a.ig_id)}</a>`:esc(a.user_ig)||'—'}</td>
    <td style="font-weight:600">${(a.user_followers||0).toLocaleString()}</td>
    <td style="max-width:200px;font-size:12px;color:var(--muted)">${esc(a.message)||'—'}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadgeKo(a.status)}</td>
    <td>${otCell}</td>
    <td>${delivCell}</td>
    <td style="white-space:nowrap">
      ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${remaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
      :`<div><div style="font-size:10px;color:var(--muted)">${esc(a.reviewed_by||'')} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
    </td>
  </tr>`;}).join('') : '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>';
}

// Stage 4: OT 체크박스 셀 (gifting/visit 승인 건만 활성)
function renderOtCell(a, isPostType) {
  if (!isPostType) return '<span style="font-size:10px;color:var(--muted)">—</span>';
  if (a.status !== 'approved') return '<span style="font-size:10px;color:var(--muted)">—</span>';
  const checked = !!a.oriented_at;
  const label = checked ? formatDate(a.oriented_at) : '미발송';
  return `<label style="display:inline-flex;align-items:center;gap:6px;cursor:pointer;font-size:11px">
    <input type="checkbox" ${checked?'checked':''} onchange="onOtToggle('${a.id}', this)" style="margin:0">
    <span style="color:${checked?'var(--green)':'var(--muted)'}">${label}</span>
  </label>`;
}

async function onOtToggle(appId, checkbox) {
  const wantChecked = checkbox.checked;
  if (!wantChecked) {
    const ok = await showConfirm('OT 발송 체크를 해제하시겠습니까?\n"미발송" 상태로 되돌립니다.');
    if (!ok) { checkbox.checked = true; return; }
  }
  const isoOrNull = wantChecked ? new Date().toISOString() : null;
  const ok = await updateApplicationOrientedAt(appId, isoOrNull);
  if (!ok) {
    toast('OT 상태 변경에 실패했습니다', 'warn');
    checkbox.checked = !wantChecked;
    return;
  }
  toast(wantChecked ? 'OT 발송으로 체크했습니다' : 'OT 발송 체크를 해제했습니다');
  loadCampApplicants();
}

// Stage 4: 결과물 요약 셀 (건수 + 상태 분포 + 상세 링크)
// Stage 5: channel_match('and')면 선택 채널 각각 approved post deliverable 필요 → 완료 판정
function renderDelivCell(list, appStatus, selectedChannels, channelMatch, isPostType) {
  if (appStatus !== 'approved') return '<span style="font-size:10px;color:var(--muted)">—</span>';
  if (!list.length) return '<span style="font-size:11px;color:var(--muted)">미제출</span>';
  const counts = {pending: 0, approved: 0, rejected: 0};
  list.forEach(d => { counts[d.status] = (counts[d.status] || 0) + 1; });
  const parts = [];
  if (counts.approved) parts.push(`<span style="color:#2D7A3E">승인 ${counts.approved}</span>`);
  if (counts.pending) parts.push(`<span style="color:#B8741A">검수대기 ${counts.pending}</span>`);
  if (counts.rejected) parts.push(`<span style="color:#C33">반려 ${counts.rejected}</span>`);
  const complete = isApplicationComplete(list, selectedChannels, channelMatch, isPostType);
  const completeBadge = complete
    ? '<div style="display:inline-block;margin-top:3px;background:#E4F5E8;color:#2D7A3E;font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px">完了</div>'
    : '';
  const latest = list[0];
  return `<div style="font-size:10px">${parts.join(' · ')}</div>
    ${completeBadge}
    <button class="btn btn-ghost btn-xs" style="margin-top:3px;font-size:10px;padding:2px 6px" onclick="openDelivDetail('${latest.id}')">상세</button>`;
}

// Stage 5: 완료 판정 — channel_match별
// - post 타입 AND: 선택 채널 각각 approved post deliverable 필요
// - post 타입 OR: 1개라도 approved면 완료
// - receipt 타입(monitor): 1개라도 approved면 완료 (채널 개념 없음)
function isApplicationComplete(delivs, selectedChannels, channelMatch, isPostType) {
  const approved = delivs.filter(d => d.status === 'approved');
  if (!approved.length) return false;
  if (!isPostType) return true;  // monitor는 approved 하나면 완료
  if (channelMatch === 'and') {
    if (!selectedChannels.length) return false;  // 채널 미설정 AND는 완료 불가
    return selectedChannels.every(ch => approved.some(d => (d.post_channel || '') === ch));
  }
  return true;  // or
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

var infSortKey = 'created';
var infSortDir = 'desc';

function toggleInfSort(key) {
  if (infSortKey === key) {
    infSortDir = infSortDir === 'desc' ? 'asc' : 'desc';
  } else {
    infSortKey = key;
    infSortDir = 'desc';
  }
  updateInfSortUI();
  loadAdminInfluencers();
}

function resetInfSort() {
  infSortKey = 'created';
  infSortDir = 'desc';
  updateInfSortUI();
  loadAdminInfluencers();
}

function updateInfSortUI() {
  document.querySelectorAll('.inf-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === infSortKey) {
      el.classList.add(infSortDir);
      el.textContent = infSortDir === 'asc' ? '▲' : '▼';
    }
  });
  const resetBtn = $('btnInfSortReset');
  if (resetBtn) resetBtn.style.display = (infSortKey === 'created' && infSortDir === 'desc') ? 'none' : '';
}

function sortInfUsers(users) {
  if (!infSortKey) return users;
  const dir = infSortDir === 'asc' ? 1 : -1;
  const getVal = {
    name: u => (u.name_kanji||u.name||'').toLowerCase(),
    ig: u => u.ig_followers||0,
    x: u => u.x_followers||0,
    tiktok: u => u.tiktok_followers||0,
    youtube: u => u.youtube_followers||0,
    total: u => (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0),
    line: u => u.line_id ? 1 : 0,
    addr: u => u.prefecture ? 1 : 0,
    bank: u => u.paypal_email ? 1 : 0,
    created: u => new Date(u.created_at).getTime(),
    followers: u => u[{instagram:'ig_followers',x:'x_followers',tiktok:'tiktok_followers',youtube:'youtube_followers'}[currentInfTab]]||0
  };
  const fn = getVal[infSortKey];
  if (!fn) return users;
  return users.slice().sort((a,b) => {
    const va = fn(a), vb = fn(b);
    if (typeof va === 'string') return va.localeCompare(vb) * dir;
    return (va - vb) * dir;
  });
}

function infSortTh(label, key) {
  return `${label} <span class="sort-arrows inf-sort-arrows" data-sort="${key}" onclick="toggleInfSort('${key}')">${infSortKey===key?(infSortDir==='asc'?'▲':'▼'):'▲▼'}</span>`;
}

function renderInfTable(users, ch) {
  const titleEl = $('infTableTitle');
  const headEl = $('infTableHead');
  const bodyEl = $('adminInfluencersBody');
  if (!bodyEl) return;

  let filtered = users;

  if (ch === 'all') {
    if (titleEl) titleEl.textContent = '인플루언서 전체';
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${infSortTh('Instagram','ig')}</th><th>${infSortTh('X(Twitter)','x')}</th><th>${infSortTh('TikTok','tiktok')}</th><th>${infSortTh('YouTube','youtube')}</th><th>${infSortTh('합계','total')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('PayPal','bank')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = sortInfUsers(filtered);
    bodyEl.innerHTML = filtered.length ? filtered.map(u => {
      const igF = (u.ig_followers||0).toLocaleString();
      const xF = (u.x_followers||0).toLocaleString();
      const ttF = (u.tiktok_followers||0).toLocaleString();
      const ytF = (u.youtube_followers||0).toLocaleString();
      const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)).toLocaleString();
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.paypal_email ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
      return `<tr>
        <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerDetail('${u.id}')">${esc(u.name_kanji||u.name)||'—'}${adminBadge(u.email)}</div><div style="font-size:11px;color:var(--muted)">${esc(u.email)}</div></td>
        <td>${u.ig?`<a href="https://instagram.com/${esc(u.ig.replace('@',''))}" target="_blank" style="color:var(--pink)">@${esc(u.ig.replace('@',''))}</a>`:'—'}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
        <td>${u.x?`@${esc(u.x.replace('@',''))}`:'—'}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
        <td>${u.tiktok?`@${esc(u.tiktok.replace('@',''))}`:'—'}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
        <td>${u.youtube?`@${esc(u.youtube.replace('@',''))}`:'—'}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
        <td style="font-weight:700;color:var(--pink)">${total}</td>
        <td style="font-size:12px;color:var(--muted)">${esc(u.line_id)||'—'}</td>
        <td style="font-size:12px;color:var(--muted)">${esc(addr)}</td>
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
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${chLabel} ID</th><th>${infSortTh('팔로워','followers')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('PayPal','bank')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = infSortKey ? sortInfUsers(filtered) : filtered.sort((a,b)=>(b[fKey]||0)-(a[fKey]||0));
    bodyEl.innerHTML = filtered.length ? filtered.map(u => {
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.paypal_email ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
      return `<tr>
        <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerDetail('${u.id}')">${esc(u.name_kanji||u.name)||'—'}${adminBadge(u.email)}</div><div style="font-size:11px;color:var(--muted)">${esc(u.email)}</div></td>
        <td>${u[idKey]?`@${esc(u[idKey].replace('@',''))}`:'—'}</td>
        <td style="font-weight:700;color:var(--pink)">${(u[fKey]||0).toLocaleString()}명</td>
        <td style="font-size:12px;color:var(--muted)">${esc(u.line_id)||'—'}</td>
        <td style="font-size:12px;color:var(--muted)">${esc(addr)}</td>
        <td>${bank}</td>
        <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
      </tr>`;
    }).join('') : `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>`;
  }
}

// ── 인플루언서 상세 ──
async function openInfluencerDetail(userId) {
  const users = await fetchInfluencers();
  const u = users.find(x => x.id === userId);
  if (!u) { toast('인플루언서를 찾을 수 없습니다','error'); return; }

  $('infDetailTitle').innerHTML = esc(u.name_kanji || u.name || u.email) + adminBadge(u.email);

  // 기본 정보
  const row = (label, val) => `<div style="display:flex;padding:8px 0;border-bottom:1px solid var(--surface-dim,var(--bg))"><div style="width:100px;font-size:12px;font-weight:600;color:var(--muted);flex-shrink:0">${label}</div><div style="font-size:13px;color:var(--ink);flex:1">${esc(val)||'—'}</div></div>`;

  $('infDetailBasic').innerHTML =
    row('이름 (한자)', u.name_kanji || u.name) +
    row('이름 (카나)', u.name_kana) +
    row('이메일', u.email) +
    row('카테고리', u.category) +
    row('자기소개', u.bio) +
    row('가입일', formatDate(u.created_at));

  // SNS
  const snsRow = (icon, id, followers) => `<div style="display:flex;align-items:center;padding:10px 0;border-bottom:1px solid var(--surface-dim,var(--bg));gap:12px">
    <div style="font-size:12px;font-weight:600;color:var(--muted);width:80px;flex-shrink:0">${icon}</div>
    <div style="flex:1;font-size:13px">${id ? `@${esc(id.replace('@',''))}` : '—'}</div>
    <div style="font-size:13px;font-weight:700;color:var(--pink)">${(followers||0).toLocaleString()}명</div>
  </div>`;
  const totalF = (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0);
  $('infDetailSns').innerHTML =
    snsRow('Instagram', u.ig, u.ig_followers) +
    snsRow('X (Twitter)', u.x, u.x_followers) +
    snsRow('TikTok', u.tiktok, u.tiktok_followers) +
    snsRow('YouTube', u.youtube, u.youtube_followers) +
    `<div style="display:flex;align-items:center;padding:12px 0;gap:12px"><div style="font-size:12px;font-weight:700;color:var(--ink);width:80px">총 팔로워</div><div style="font-size:18px;font-weight:800;color:var(--pink)">${totalF.toLocaleString()}명</div></div>`;

  // 연락처
  $('infDetailContact').innerHTML =
    row('LINE ID', u.line_id) +
    row('전화번호', u.phone);

  // 배송지
  const fullAddr = u.zip ? `〒${u.zip} ${u.prefecture||''}${u.city||''}${u.building?' '+u.building:''}` : u.address;
  $('infDetailAddress').innerHTML =
    row('우편번호', u.zip) +
    row('도도부현', u.prefecture) +
    row('시구정촌', u.city) +
    row('건물명', u.building) +
    row('전체 주소', fullAddr);

  // PayPal — row() 내에서 esc() 처리됨
  $('infDetailBank').innerHTML = u.paypal_email
    ? row('PayPal 이메일', u.paypal_email)
    : '<div style="text-align:center;color:var(--muted);padding:16px;font-size:13px">PayPal 미등록</div>';

  // 신청 이력
  const apps = await fetchApplications({user_id: userId});
  const camps = await fetchCampaigns();
  $('infDetailAppCount').textContent = `${apps.length}건`;
  $('infDetailAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const typeLabel = getRecruitTypeBadgeKo(camp.recruit_type);
    return `<tr>
      <td style="font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td>
      <td>${typeLabel}</td>
      <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}</td>
    </tr>`;
  }).join('') : '<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:24px">신청 이력 없음</td></tr>';

  switchAdminPane('influencer-detail', null);
}

async function openInfluencerModal(userId) {
  const users = await fetchInfluencers();
  const u = users.find(x => x.id === userId);
  if (!u) { toast('인플루언서를 찾을 수 없습니다','error'); return; }

  $('infModalTitle').innerHTML = esc(u.name_kanji || u.name || u.email) + adminBadge(u.email);

  const row = (label, val) => `<div style="display:flex;padding:6px 0;border-bottom:1px solid var(--surface-dim,var(--bg))"><div style="width:80px;font-size:11px;font-weight:600;color:var(--muted);flex-shrink:0">${label}</div><div style="font-size:12px;color:var(--ink);flex:1">${esc(val)||'—'}</div></div>`;

  $('infModalBasic').innerHTML =
    row('이름(한자)', u.name_kanji||u.name) + row('이름(카나)', u.name_kana) +
    row('이메일', u.email) + row('카테고리', u.category) +
    row('자기소개', u.bio) + row('가입일', formatDate(u.created_at));

  const snsUrls = {Instagram:'https://instagram.com/',X:'https://x.com/',TikTok:'https://tiktok.com/@',YouTube:'https://youtube.com/@'};
  const snsRow = (icon, id, f) => {
    const clean = id ? id.replace('@','') : '';
    const url = snsUrls[icon];
    const link = clean && url ? `<a href="${url}${esc(clean)}" target="_blank" style="color:var(--pink);text-decoration:none">@${esc(clean)}</a>` : '—';
    return `<div style="display:flex;align-items:center;padding:6px 0;border-bottom:1px solid var(--surface-dim,var(--bg));gap:8px"><div style="font-size:11px;font-weight:600;color:var(--muted);width:70px;flex-shrink:0">${icon}</div><div style="flex:1;font-size:12px">${link}</div><div style="font-size:12px;font-weight:700;color:var(--pink)">${(f||0).toLocaleString()}</div></div>`;
  };
  const totalF = (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0);
  $('infModalSns').innerHTML =
    snsRow('Instagram', u.ig, u.ig_followers) + snsRow('X', u.x, u.x_followers) +
    snsRow('TikTok', u.tiktok, u.tiktok_followers) + snsRow('YouTube', u.youtube, u.youtube_followers) +
    `<div style="display:flex;align-items:center;padding:8px 0;gap:8px"><div style="font-size:11px;font-weight:700;width:70px">총 팔로워</div><div style="font-size:16px;font-weight:800;color:var(--pink)">${totalF.toLocaleString()}</div></div>`;

  $('infModalContact').innerHTML = row('LINE ID', u.line_id) + row('전화번호', u.phone);

  const fullAddr2 = u.zip ? `〒${u.zip} ${u.prefecture||''}${u.city||''}${u.building?' '+u.building:''}` : u.address;
  $('infModalAddress').innerHTML = row('전체 주소', fullAddr2);

  $('infModalBank').innerHTML = u.paypal_email
    ? row('PayPal', u.paypal_email)
    : '<div style="text-align:center;color:var(--muted);padding:12px;font-size:12px">PayPal 미등록</div>';

  const apps = await fetchApplications({user_id: userId});
  const camps = await fetchCampaigns();
  $('infModalAppCount').textContent = `${apps.length}건`;
  $('infModalAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const tl = getRecruitTypeBadgeKo(camp.recruit_type);
    return `<tr><td style="font-size:12px;font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td><td>${tl}</td><td style="font-size:11px;color:var(--muted)">${formatDate(a.created_at)}</td><td>${getStatusBadgeKo(a.status)}</td></tr>`;
  }).join('') : '<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:16px">신청 이력 없음</td></tr>';

  openModal('infDetailModal');
}

// ── 신청 관리 (캠페인별) ──
let currentAppTypeTab = 'all';
let currentAppCampId = null;

async function loadApplications() {
  renderAppCampList();
}

var appSortKey = 'created';
var appSortDir = 'desc';

function toggleAppSort(key) {
  if (appSortKey === key) {
    appSortDir = appSortDir === 'desc' ? 'asc' : 'desc';
  } else {
    appSortKey = key;
    appSortDir = 'desc';
  }
  document.querySelectorAll('.app-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === appSortKey) {
      el.classList.add(appSortDir);
      el.textContent = appSortDir === 'asc' ? '▲' : '▼';
    }
  });
  const btn = $('btnAppSortReset');
  if (btn) btn.style.display = (appSortKey === 'created' && appSortDir === 'desc') ? 'none' : '';
  renderAppCampList();
}

function resetAppSort() {
  appSortKey = 'created';
  appSortDir = 'desc';
  document.querySelectorAll('.app-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === 'created') { el.classList.add('desc'); el.textContent = '▼'; }
  });
  const btn = $('btnAppSortReset'); if (btn) btn.style.display = 'none';
  renderAppCampList();
}

async function renderAppCampList() {
  const bodyEl = $('appTableBody');
  const countEl = $('appTotalCount');
  if (!bodyEl) return;

  let camps = await fetchCampaigns();
  const allAppsRaw = await fetchApplications();
  let apps = allAppsRaw.slice();
  const users = await fetchInfluencers();

  // 타입 필터
  const typeFilter = $('appTypeFilter')?.value || 'all';
  if (typeFilter !== 'all') {
    const filteredCampIds = camps.filter(c => c.recruit_type === typeFilter).map(c => c.id);
    apps = apps.filter(a => filteredCampIds.includes(a.campaign_id));
  }

  // 상태 필터
  const statusFilter = $('appStatusFilter')?.value || 'pending';
  if (statusFilter !== 'all') apps = apps.filter(a => a.status === statusFilter);

  // 검색 필터
  const searchVal = ($('appSearch')?.value || '').trim().toLowerCase();
  if (searchVal) {
    apps = apps.filter(a => {
      const camp = camps.find(c => c.id === a.campaign_id) || {};
      return (camp.title||'').toLowerCase().includes(searchVal)
        || (camp.brand||'').toLowerCase().includes(searchVal)
        || (a.user_name||'').toLowerCase().includes(searchVal)
        || (a.user_email||'').toLowerCase().includes(searchVal);
    });
  }

  const appDir = appSortDir === 'asc' ? 1 : -1;
  if (appSortKey === 'status') {
    const statusOrder = {pending:0, approved:1, rejected:2};
    apps.sort((a,b) => ((statusOrder[a.status]??9) - (statusOrder[b.status]??9)) * appDir);
  } else if (appSortKey === 'name') {
    apps.sort((a,b) => (a.user_name||'').localeCompare(b.user_name||'', 'ja') * appDir);
  } else {
    apps.sort((a,b) => (new Date(a.created_at) - new Date(b.created_at)) * appDir);
  }

  if (countEl) countEl.textContent = `총 ${apps.length}건`;

  bodyEl.innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c => c.id === a.campaign_id) || {};
    const u = users.find(u => u.email === a.user_email) || {};
    const _campRemaining = Math.max((camp.slots||0)-allAppsRaw.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    return `<tr>
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,160)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:5px">${typeLabel}<strong style="font-size:13px;cursor:pointer" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong></div>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
            ${camp.slots?(()=>{const _r=Math.max(camp.slots-allAppsRaw.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);return `<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_r>0?'var(--green)':'var(--red)'};font-weight:600">${_r>0?_r+'건':'없음'}</span></div>`;})():''}
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}</div>
        <div style="font-size:11px;color:var(--muted)">${[esc(a.user_email)||'', u.line_id?`LINE: ${esc(u.line_id)}`:''].filter(Boolean).join(' · ')}</div>
      </td>
      <td style="max-width:180px;font-size:12px;color:var(--ink)">${esc(a.message)||'—'}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${_campRemaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(a.reviewed_by||'')} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
      </td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

async function updateAppStatus(appId, status) {
  try {
    // 승인 시 모집인원 초과 체크
    if (status === 'approved') {
      const {data: app} = await db.from('applications').select('campaign_id').eq('id', appId).maybeSingle();
      if (app) {
        const {data: camp} = await db.from('campaigns').select('slots').eq('id', app.campaign_id).maybeSingle();
        const approvedApps = await fetchApplications({campaign_id: app.campaign_id, status: 'approved'});
        const slots = camp?.slots || 0;
        if (slots > 0 && approvedApps.length >= slots) {
          $('alertModalMessage').innerHTML = `이 캠페인의 모집 정원은 <strong>${esc(String(slots))}명</strong>으로<br>이미 모두 찼습니다.`;
          openModal('alertModal');
          return;
        }
      }
    }
    const reviewerName = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
    await updateApplication(appId, {
      status,
      reviewed_by: reviewerName,
      reviewed_at: new Date().toISOString()
    });
    const msgs = {approved:'승인했습니다', rejected:'미승인 처리했습니다', pending:'심사중으로 되돌렸습니다'};
    toast(msgs[status]||'상태가 변경되었습니다', status==='approved'?'success':'');
    renderAppCampList();
    loadAdminData();
    if (typeof loadCampApplicants === 'function' && currentCampApplicantId) loadCampApplicants();
  } catch(e) {
    toast('상태 변경 오류: '+friendlyError(e.message),'error');
  }
}

async function addCampaign() {
  try {
  const title = $('newCampTitle').value.trim();
  const brand = $('newCampBrand').value.trim();
  const product = $('newCampProduct').value.trim();
  const productUrl = cleanUrl($('newCampProductUrl')?.value)||'';
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
  const postDeadline = $('newCampPostDeadline')?.value;
  if (postDeadline && deadline && new Date(postDeadline) < new Date(deadline)) {
    toast('게시 마감일은 모집 마감일 이후여야 합니다','error');
    return;
  }
  const catEmojiMap = {beauty:'💄',food:'🍜',fashion:'👗',health:'💪',other:'📦'};
  const cat = $('newCampCategory').value;
  const ch = Array.from(document.querySelectorAll('input[name="newChannel"]:checked')).map(c=>c.value).join(',');
  if (!ch) { toast('채널을 1개 이상 선택해주세요','error'); return; }
  const existing = await fetchCampaigns();
  const minOrder = existing.length > 0 ? Math.min(...existing.map(c=>c.order_index||0)) : 0;
  // 이미지를 Storage에 업로드
  toast('이미지 업로드 중...','');
  const imgUrls = await uploadCampImages(campImgData);

  const camp = {
    title, brand, product,
    type: ch.split(',').includes('qoo10')?'qoo10':'nano', channel:ch, channel_match: document.querySelector('input[name="newChannelMatch"]:checked')?.value || 'or', primary_channel: (recruitType==='monitor') ? null : ($('newCampPrimaryChannel')?.value || null), min_followers: (recruitType==='monitor') ? 0 : (parseInt($('newCampMinFollowers')?.value)||0), category:cat,
    recruit_type: recruitType,
    order_index: minOrder - 1,
    content_types: contentTypes,
    image_url: imgUrls[0],
    img1: imgUrls[0], img2: imgUrls[1],
    img3: imgUrls[2], img4: imgUrls[3],
    img5: imgUrls[4], img6: imgUrls[5],
    img7: imgUrls[6], img8: imgUrls[7],
    image_crops: buildImageCrops(campImgData),
    product_url: productUrl,
    product_price: parseInt($('newCampProductPrice')?.value)||0,
    reward: parseInt($('newCampReward').value)||0,
    slots, applied_count:0,
    deadline: deadline||null,
    post_deadline: $('newCampPostDeadline')?.value||null,
    post_days: $('newCampPostDeadline')?.value
      ? Math.ceil((new Date($('newCampPostDeadline').value) - new Date()) / (1000*60*60*24))
      : 14,
    purchase_start: $('newCampPurchaseStart')?.value||null,
    purchase_end: $('newCampPurchaseEnd')?.value||null,
    visit_start: $('newCampVisitStart')?.value||null,
    visit_end: $('newCampVisitEnd')?.value||null,
    submission_end: $('newCampSubmissionEnd')?.value||null,
    winner_announce: $('newCampWinnerAnnounce')?.value || '選考後、LINEにてご連絡',
    description: getRichValue('newCampDesc'),
    hashtags:$('newCampHashtags').value, mentions:$('newCampMentions').value,
    appeal: getRichValue('newCampAppeal'), guide: getRichValue('newCampGuide'), ng: getRichValue('newCampNg'),
    status:'draft',
    ...collectCampPsetPayload('new'),
  };

  await insertCampaign(camp);
  toast('캠페인이 등록되었습니다','success');
  campImgData.length = 0;
  renderImgPreview(campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');

  ['newCampTitle','newCampBrand','newCampProduct','newCampProductUrl',
   'newCampSlots','newCampDeadline','newCampPostDeadline',
   'newCampHashtags','newCampMentions',
   'newCampProductPrice','newCampReward'].forEach(id => { const el=$(id); if(el) el.value=''; });
  // 리치 에디터 초기화
  ['newCampDesc','newCampAppeal','newCampGuide','newCampNg'].forEach(id => setRichValue(id, ''));
  document.querySelectorAll('input[name="recruitType"]').forEach(r=>r.checked=false);
  document.querySelectorAll('[id^="rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';});
  // 동적 영역 재렌더 (체크 해제 + 전체 채널 다시 표시)
  await Promise.all([
    renderChannelCheckboxes('new', null, []),
    renderContentTypeCheckboxes('new', []),
    renderCategorySelect('new', '')
  ]);

  allCampaigns = await fetchCampaigns();

  switchAdminPane('campaigns', null);
  } catch(err) {
    toast('오류: ' + friendlyError(err.message||String(err)), 'error');
  }
}

// ══════════════════════════════════════
// 관리자 계정 관리
// ══════════════════════════════════════
let currentAdminInfo = null;

async function loadAdminAccounts() {
  if (!db) return;
  const {data} = await db.from('admins').select('*').order('created_at');
  const admins = data || [];
  // 현재 로그인한 관리자 정보 먼저 확정 (렌더 시 권한 판단에 사용)
  currentAdminInfo = admins.find(a => a.auth_id === currentUser?.id) || null;
  const isSuper = currentAdminInfo?.role === 'super_admin';

  const roleLabel = r => r === 'super_admin'
    ? '<span class="badge badge-red">슈퍼관리자</span>'
    : r === 'campaign_admin'
    ? '<span class="badge badge-blue">캠페인관리자</span>'
    : '<span class="badge badge-gray">캠페인매니저</span>';

  $('adminAccountsBody').innerHTML = admins.length ? admins.map(a => `<tr>
    <td style="font-weight:600">${esc(a.name)||'—'}</td>
    <td>${esc(a.email)}</td>
    <td>${roleLabel(a.role)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td><div style="display:flex;gap:5px">
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" data-name="${esc(a.name||'')}" onclick="openEditAdmin('${a.id}',this.dataset.email,this.dataset.name,'${a.role}')">수정</button>
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" onclick="openResetPwModal('${a.auth_id}',this.dataset.email)">비밀번호</button>
      ${(isSuper && a.auth_id !== currentUser?.id) ? `<button class="btn btn-ghost btn-xs" style="color:#B3261E" data-email="${esc(a.email)}" data-auth-id="${a.auth_id}" onclick="openDeleteAdminModal('${a.id}',this.dataset.authId,this.dataset.email)">삭제</button>` : ''}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>';

  applyLookupMenuVisibility();
}

// 권한에 따라 "기준 데이터" 메뉴 표시/숨김
function isCampaignAdminOrAbove() {
  const r = currentAdminInfo?.role;
  return r === 'super_admin' || r === 'campaign_admin';
}
function applyLookupMenuVisibility() {
  const el = document.getElementById('adminLookupsSi');
  if (el) el.style.display = isCampaignAdminOrAbove() ? '' : 'none';
}

// ══════════════════════════════════════
// 기준 데이터 (lookup_values) 관리
// ══════════════════════════════════════
const LOOKUP_KIND_LABEL_KO = {channel:'채널', category:'카테고리', content_type:'콘텐츠 종류', ng_item:'NG 사항', participation_set:'참여방법', reject_reason:'반려사유'};
let _currentLookupKind = 'channel';

async function loadLookupsPane() {
  applyLookupMenuVisibility();
  if (!isCampaignAdminOrAbove()) {
    const tbody = $('lookupsTableBody');
    if (tbody) tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">권한이 없습니다 (campaign_admin 이상)</td></tr>';
    return;
  }
  await renderLookupsTable();
}

function switchLookupTab(kind, btn) {
  _currentLookupKind = kind;
  // 탭 전환 시 reorder 모드 자동 종료
  if (_lookupReorderMode) {
    _lookupReorderMode = false;
    const rb = $('btnLookupReorderMode');
    if (rb) { rb.textContent = '순서 변경'; rb.onclick = enterLookupReorderMode; rb.classList.remove('btn-primary'); rb.classList.add('btn-ghost'); }
  }
  document.querySelectorAll('.lookup-tab').forEach(b => {
    b.style.color = 'var(--muted)';
    b.style.borderBottomColor = 'transparent';
    b.style.fontWeight = '600';
  });
  if (btn) {
    btn.style.color = 'var(--pink)';
    btn.style.borderBottomColor = 'var(--pink)';
    btn.style.fontWeight = '700';
  }
  renderLookupsTable();
}

async function renderLookupsTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  const title = $('lookupTableTitle');
  if (!tbody) return;
  if (title) title.textContent = LOOKUP_KIND_LABEL_KO[_currentLookupKind] + ' 목록';
  if (_currentLookupKind === 'participation_set') { await renderPsetTable(); return; }
  const isChannel = _currentLookupKind === 'channel';
  // 헤더 렌더
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>한국어 명칭${isChannel?' / 모집 타입':''}</th>
      <th>일본어 명칭</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 5;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try {
    rows = await fetchLookupsAll(_currentLookupKind);
  } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(e.message||String(e))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 항목이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const showRt = isChannel || _currentLookupKind === 'reject_reason';
    const rts = r.recruit_types || [];
    const rtBadges = showRt
      ? (rts.length
        ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:4px">${rts.map(t => {
            const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
            return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
          }).join('')}</div>`
        : `<div style="margin-top:4px"><span class="badge badge-gray" style="font-size:9px;padding:1px 6px">공통</span></div>`)
      : '';
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong>${rtBadges}</td>
      <td style="color:var(--ink);font-size:13px">${esc(r.name_ja)}</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openLookupEditModal(${JSON.stringify(r)})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${JSON.stringify(r)})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

const RECRUIT_TYPE_LABEL_KO = {monitor:'리뷰어', gifting:'기프팅', visit:'방문형'};
let _lookupReorderMode = false;

// ══════════════════════════════════════
// 캠페인 폼: lookup_values 동적 렌더
// ══════════════════════════════════════
const _formCfg = {
  new:  { chWrap:'newCampChannelWrap',  chName:'newChannel',  chPrefix:'ch-',
          ctWrap:'newCampContentTypeWrap',  ctName:'contentType',  ctPrefix:'ct-',
          catSelect:'newCampCategory',  primarySelect:'newCampPrimaryChannel' },
  edit: { chWrap:'editCampChannelWrap', chName:'editChannel', chPrefix:'edit-ch-',
          ctWrap:'editCampContentTypeWrap', ctName:'editContentType', ctPrefix:'edit-ct-',
          catSelect:'editCampCategory', primarySelect:'editCampPrimaryChannel' }
};

// 모집 타입에 따라 기준 채널/최소 팔로워수 영역 표시 토글
// 리뷰어(monitor)는 영수증 검증이라 팔로워 조건 불필요
function applyMinFollowersVisibility(formMode, recruitType) {
  const wrapId = formMode === 'edit' ? 'editCampMinFollowersGroup' : 'newCampMinFollowersGroup';
  const wrap = $(wrapId);
  if (!wrap) return;
  wrap.style.display = recruitType === 'monitor' ? 'none' : '';
}

// 채널 체크 변경 시 기준 채널 셀렉트 옵션 갱신
function refreshPrimaryChannelOptions(formMode, preferredCode) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const sel = $(cfg.primarySelect); if (!sel) return;
  const checked = Array.from(document.querySelectorAll(`input[name="${cfg.chName}"]:checked`));
  const prevValue = preferredCode || sel.value;
  if (checked.length === 0) {
    sel.innerHTML = '<option value="">채널을 먼저 선택하세요</option>';
    sel.disabled = true;
    return;
  }
  sel.disabled = false;
  sel.innerHTML = checked.map(cb => {
    const label = cb.closest('label')?.textContent.trim() || cb.value;
    return `<option value="${esc(cb.value)}">${esc(label)}</option>`;
  }).join('');
  // 기존 값 유지 (체크 목록에 있으면)
  if (prevValue && checked.some(cb => cb.value === prevValue)) sel.value = prevValue;
}

async function renderChannelCheckboxes(formMode, recruitType, preSelectedCodes) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const wrap = $(cfg.chWrap); if (!wrap) return;
  let channels = [];
  try { channels = await fetchLookups('channel'); } catch(e) { return; }
  if (recruitType) {
    channels = channels.filter(c => Array.isArray(c.recruit_types) && c.recruit_types.includes(recruitType));
  }
  const checked = new Set(preSelectedCodes || []);
  if (!channels.length) {
    wrap.innerHTML = `<div style="font-size:12px;color:var(--muted);padding:6px 0">선택한 모집 타입에서 사용 가능한 채널이 없습니다</div>`;
    return;
  }
  wrap.innerHTML = channels.map(c =>
    `<label style="display:flex;align-items:center;gap:5px;padding:6px 13px;border:1.5px solid var(--line);border-radius:20px;cursor:pointer;font-size:13px;font-weight:500;transition:.15s" id="${esc(cfg.chPrefix+c.code)}"><input type="checkbox" name="${esc(cfg.chName)}" value="${esc(c.code)}" onchange="toggleCH(this);refreshPrimaryChannelOptions('${formMode}');applyChannelMatchVisibility('${formMode}')" style="display:none">${esc(c.name_ja)}</label>`
  ).join('');
  wrap.querySelectorAll('input[type="checkbox"]').forEach(cb => {
    if (checked.has(cb.value)) { cb.checked = true; toggleCH(cb); }
  });
  refreshPrimaryChannelOptions(formMode);
  applyChannelMatchVisibility(formMode);
}

// 채널이 2개 이상 선택된 경우에만 or/& 토글 노출
function applyChannelMatchVisibility(formMode) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const group = $(formMode === 'edit' ? 'editCampChannelMatchGroup' : 'newCampChannelMatchGroup');
  if (!group) return;
  const count = document.querySelectorAll(`input[name="${cfg.chName}"]:checked`).length;
  group.style.display = count >= 2 ? 'flex' : 'none';
}

async function renderContentTypeCheckboxes(formMode, preSelectedLabels) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const wrap = $(cfg.ctWrap); if (!wrap) return;
  let items = [];
  try { items = await fetchLookups('content_type'); } catch(e) { return; }
  const checked = new Set(preSelectedLabels || []);
  wrap.innerHTML = items.map(c =>
    `<label style="display:flex;align-items:center;gap:5px;padding:6px 13px;border:1.5px solid var(--line);border-radius:20px;cursor:pointer;font-size:13px;font-weight:500;transition:.15s" id="${esc(cfg.ctPrefix+c.code)}"><input type="checkbox" name="${esc(cfg.ctName)}" value="${esc(c.name_ja)}" onchange="toggleCT(this)" style="display:none">${esc(c.name_ko)}</label>`
  ).join('');
  wrap.querySelectorAll('input[type="checkbox"]').forEach(cb => {
    if (checked.has(cb.value)) { cb.checked = true; toggleCT(cb); }
  });
}

async function renderCategorySelect(formMode, currentCode) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const sel = $(cfg.catSelect); if (!sel) return;
  let items = [];
  try { items = await fetchLookups('category'); } catch(e) { return; }
  sel.innerHTML = items.map(c => `<option value="${esc(c.code)}">${esc(c.name_ko)}</option>`).join('');
  if (currentCode && items.some(c => c.code === currentCode)) sel.value = currentCode;
}

async function filterChannelsByRecruitType(formMode, recruitType) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  // 현재 체크된 코드 보존
  const checked = Array.from(document.querySelectorAll(`input[name="${cfg.chName}"]:checked`)).map(c => c.value);
  await renderChannelCheckboxes(formMode, recruitType, checked);
  // 참여방법 번들 드롭다운도 모집 타입에 맞춰 갱신 (선택값은 유지 시도)
  const psetSel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  await populateCampPsetDropdown(formMode, recruitType, psetSel?.value || null);
  // 타입별 기한 필드 표시/숨김
  applyDeadlineFieldsVisibility(formMode, recruitType);
}

// Stage 1: 모집 타입별 기한 필드 표시/숨김 (monitor=구매기간, visit=방문기간)
// 숨겨지는 필드는 값도 초기화 — 타입 변경 후 저장 시 잔여 값 DB 오염 방지
function applyDeadlineFieldsVisibility(formMode, recruitType) {
  const prefix = formMode === 'edit' ? 'editCamp' : 'newCamp';
  const purchaseRow = $(prefix + 'PurchaseRow');
  const visitRow = $(prefix + 'VisitRow');
  const showPurchase = (recruitType === 'monitor');
  const showVisit = (recruitType === 'visit');
  if (purchaseRow) purchaseRow.style.display = showPurchase ? '' : 'none';
  if (visitRow) visitRow.style.display = showVisit ? '' : 'none';
  if (!showPurchase) {
    const ps = $(prefix + 'PurchaseStart'); if (ps) ps.value = '';
    const pe = $(prefix + 'PurchaseEnd'); if (pe) pe.value = '';
  }
  if (!showVisit) {
    const vs = $(prefix + 'VisitStart'); if (vs) vs.value = '';
    const ve = $(prefix + 'VisitEnd'); if (ve) ve.value = '';
  }
}

function enterLookupReorderMode() {
  _lookupReorderMode = true;
  const btn = $('btnLookupReorderMode');
  if (btn) { btn.textContent = '순서 변경 완료'; btn.onclick = exitLookupReorderMode; btn.classList.add('btn-primary'); btn.classList.remove('btn-ghost'); }
  renderLookupsTable();
}
function exitLookupReorderMode() {
  _lookupReorderMode = false;
  const btn = $('btnLookupReorderMode');
  if (btn) { btn.textContent = '순서 변경'; btn.onclick = enterLookupReorderMode; btn.classList.remove('btn-primary'); btn.classList.add('btn-ghost'); }
  renderLookupsTable();
}

function applyLookupModalKindUI(kind, recruitTypes) {
  // 채널·반려사유 탭에서 모집 타입 선택 표시 (반려사유: 빈 배열=공통)
  const grp = $('lookupRecruitTypesGroup');
  if (grp) grp.style.display = (kind === 'channel' || kind === 'reject_reason') ? '' : 'none';
  // 체크박스 상태 초기화
  const set = new Set(recruitTypes || []);
  document.querySelectorAll('input[name="lookupRT"]').forEach(cb => {
    cb.checked = set.has(cb.value);
  });
}

function openLookupAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  if (_currentLookupKind === 'participation_set') { openPsetAddModal(); return; }
  $('lookupModalTitle').textContent = LOOKUP_KIND_LABEL_KO[_currentLookupKind] + ' 추가';
  $('lookupEditId').value = '';
  $('lookupEditKind').value = _currentLookupKind;
  $('lookupNameKo').value = '';
  $('lookupNameJa').value = '';
  $('lookupCode').value = '';
  $('lookupEditError').style.display = 'none';
  // 신규 추가 시 채널이면 기본값으로 3개 모두 체크
  applyLookupModalKindUI(_currentLookupKind, ['monitor','gifting','visit']);
  openModal('lookupEditModal');
}

function openLookupEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  if (_currentLookupKind === 'participation_set') { openPsetEditModal(row); return; }
  $('lookupModalTitle').textContent = LOOKUP_KIND_LABEL_KO[row.kind] + ' 편집';
  $('lookupEditId').value = row.id;
  $('lookupEditKind').value = row.kind;
  $('lookupNameKo').value = row.name_ko || '';
  $('lookupNameJa').value = row.name_ja || '';
  $('lookupCode').value = row.code || '';
  $('lookupEditError').style.display = 'none';
  applyLookupModalKindUI(row.kind, row.recruit_types || []);
  openModal('lookupEditModal');
}

async function saveLookupEdit() {
  const id = $('lookupEditId').value;
  const kind = $('lookupEditKind').value;
  const name_ko = $('lookupNameKo').value.trim();
  const name_ja = $('lookupNameJa').value.trim();
  const code = $('lookupCode').value.trim();
  const err = $('lookupEditError');
  if (!name_ko || !name_ja) {
    err.textContent = '한국어/일본어 명칭은 필수입니다';
    err.style.display = 'block';
    return;
  }
  // 채널이면 모집 조건 1개 이상 필수. 반려사유는 선택(빈 배열=공통)
  let recruitTypes = null;
  if (kind === 'channel' || kind === 'reject_reason') {
    recruitTypes = Array.from(document.querySelectorAll('input[name="lookupRT"]:checked')).map(cb => cb.value);
    if (kind === 'channel' && recruitTypes.length === 0) {
      err.textContent = '모집 타입을 1개 이상 선택해주세요';
      err.style.display = 'block';
      return;
    }
  }
  try {
    if (id) {
      const updates = {name_ko, name_ja};
      if (code) updates.code = code;
      if (recruitTypes) updates.recruit_types = recruitTypes;
      await updateLookup(id, updates);
      toast('수정했습니다','success');
    } else {
      const payload = {kind, name_ko, name_ja, code};
      if (recruitTypes) payload.recruit_types = recruitTypes;
      await insertLookup(payload);
      toast('추가했습니다','success');
    }
    closeModal('lookupEditModal');
    renderLookupsTable();
  } catch(e) {
    err.textContent = '저장 실패: ' + (e.message || String(e));
    err.style.display = 'block';
  }
}

async function moveLookup(idA, idB) {
  if (!idA || !idB) return;
  try {
    if (_currentLookupKind === 'participation_set') await swapParticipationSetOrder(idA, idB);
    else await swapLookupOrder(idA, idB);
    renderLookupsTable();
  } catch(e) {
    toast('정렬 변경 실패: ' + (e.message||String(e)),'error');
  }
}

async function toggleLookupActive(id, nextActive) {
  try {
    if (_currentLookupKind === 'participation_set') {
      if (nextActive) await activateParticipationSet(id); else await deactivateParticipationSet(id);
    } else {
      if (nextActive) await activateLookup(id); else await deactivateLookup(id);
    }
    renderLookupsTable();
  } catch(e) {
    toast('상태 변경 실패: ' + (e.message||String(e)),'error');
  }
}

async function handleLookupDelete(row) {
  if (_currentLookupKind === 'participation_set' || row.kind === undefined) {
    const ok = await showConfirm(`'${row.name_ko}' 번들을 영구 삭제하시겠습니까?\n이미 해당 번들을 쓴 캠페인은 스냅샷이 저장돼 영향 없습니다.`);
    if (!ok) return;
    try {
      await deleteParticipationSet(row.id);
      toast('삭제했습니다','success');
      renderLookupsTable();
    } catch(e) {
      toast('삭제 실패: ' + (e.message||String(e)),'error');
    }
    return;
  }
  let inUse = false;
  try { inUse = await isLookupInUse(row); } catch(e) {}
  if (inUse) {
    toast('이미 캠페인에서 사용 중입니다. 비활성으로 변경해주세요.','error');
    return;
  }
  const ok = await showConfirm(`'${row.name_ko}' 항목을 영구 삭제하시겠습니까?\n삭제 후에는 복구할 수 없습니다.`);
  if (!ok) return;
  try {
    await deleteLookup(row.id);
    toast('삭제했습니다','success');
    renderLookupsTable();
  } catch(e) {
    toast('삭제 실패: ' + (e.message||String(e)),'error');
  }
}

// ══════════════════════════════════════
// 참여방법 번들 (participation_sets) — 관리자 UI
// ══════════════════════════════════════
const RECRUIT_TYPES_ALL = ['monitor','gifting','visit'];
const RECRUIT_TYPE_LABEL_JA = {monitor:'モニター', gifting:'ギフティング', visit:'来店'};
let _psetCurrentSteps = []; // 편집 중 steps 상태
const MAX_PSET_STEPS = 6;

async function renderPsetTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  if (!tbody) return;
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>번들 이름 (한국어 / 일본어)</th>
      <th style="width:140px">모집 타입</th>
      <th style="width:80px">단계</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 6;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try { rows = await fetchParticipationSetsAll(); } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(e.message||String(e))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 번들이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const rtBadges = (r.recruit_types||[]).map(t => {
      const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
      return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
    }).join(' ');
    const stepCount = Array.isArray(r.steps) ? r.steps.length : 0;
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong><div style="color:var(--muted);font-size:11px;margin-top:2px">${esc(r.name_ja)}</div></td>
      <td><div style="display:flex;gap:3px;flex-wrap:wrap">${rtBadges}</div></td>
      <td style="font-size:12px;color:var(--ink)">${stepCount}개</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openPsetEditModal(${JSON.stringify(r)})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${JSON.stringify(r)})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openPsetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('psetModalTitle').textContent = '참여방법 번들 추가';
  $('psetEditId').value = '';
  $('psetNameKo').value = '';
  $('psetNameJa').value = '';
  document.querySelectorAll('input[name="psetRT"]').forEach(cb => cb.checked = false);
  _psetCurrentSteps = [{title_ko:'', title_ja:'', desc_ko:'', desc_ja:''}];
  renderPsetSteps();
  $('psetEditError').style.display = 'none';
  openModal('psetEditModal');
}

function openPsetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('psetModalTitle').textContent = '참여방법 번들 편집';
  $('psetEditId').value = row.id;
  $('psetNameKo').value = row.name_ko || '';
  $('psetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="psetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _psetCurrentSteps = Array.isArray(row.steps) && row.steps.length
    ? row.steps.map(s => ({title_ko:s.title_ko||'', title_ja:s.title_ja||'', desc_ko:s.desc_ko||'', desc_ja:s.desc_ja||''}))
    : [{title_ko:'', title_ja:'', desc_ko:'', desc_ja:''}];
  renderPsetSteps();
  $('psetEditError').style.display = 'none';
  openModal('psetEditModal');
}

function renderPsetSteps() {
  const wrap = $('psetStepsWrap');
  if (!wrap) return;
  wrap.innerHTML = _psetCurrentSteps.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">STEP ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="psetMoveStep(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_psetCurrentSteps.length-1?'disabled':''} onclick="psetMoveStep(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_psetCurrentSteps.length<=1?'disabled':''} onclick="psetRemoveStep(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <input type="text" class="form-input" placeholder="제목 (한국어)" value="${esc(s.title_ko)}" style="font-size:13px;padding:8px 10px" oninput="_psetCurrentSteps[${idx}].title_ko=this.value">
        <input type="text" class="form-input" placeholder="タイトル (日本語)" value="${esc(s.title_ja)}" style="font-size:13px;padding:8px 10px" oninput="_psetCurrentSteps[${idx}].title_ja=this.value">
        <textarea class="form-input" placeholder="설명 (한국어)" rows="2" style="resize:vertical;font-size:13px;padding:8px 10px;line-height:1.5" oninput="_psetCurrentSteps[${idx}].desc_ko=this.value">${esc(s.desc_ko)}</textarea>
        <textarea class="form-input" placeholder="説明 (日本語)" rows="2" style="resize:vertical;font-size:13px;padding:8px 10px;line-height:1.5" oninput="_psetCurrentSteps[${idx}].desc_ja=this.value">${esc(s.desc_ja)}</textarea>
      </div>
    </div>
  `).join('');
  const addBtn = $('psetAddStepBtn');
  if (addBtn) addBtn.disabled = _psetCurrentSteps.length >= MAX_PSET_STEPS;
}

function psetAddStep() {
  if (_psetCurrentSteps.length >= MAX_PSET_STEPS) { toast(`단계는 최대 ${MAX_PSET_STEPS}개까지 입니다`,'error'); return; }
  _psetCurrentSteps.push({title_ko:'', title_ja:'', desc_ko:'', desc_ja:''});
  renderPsetSteps();
}

function psetRemoveStep(idx) {
  if (_psetCurrentSteps.length <= 1) return;
  _psetCurrentSteps.splice(idx, 1);
  renderPsetSteps();
}

function psetMoveStep(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _psetCurrentSteps.length) return;
  const [s] = _psetCurrentSteps.splice(idx, 1);
  _psetCurrentSteps.splice(j, 0, s);
  renderPsetSteps();
}

async function savePsetEdit() {
  const errEl = $('psetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('psetEditId').value;
  const name_ko = $('psetNameKo').value.trim();
  const name_ja = $('psetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="psetRT"]:checked')).map(cb => cb.value);
  if (!recruit_types.length) { show('사용 가능한 모집 타입을 1개 이상 선택해주세요'); return; }
  const steps = _psetCurrentSteps.filter(s => (s.title_ja||s.title_ko||'').trim());
  if (!steps.length) { show('단계를 1개 이상 입력해주세요 (제목 필수)'); return; }
  if (steps.length > MAX_PSET_STEPS) { show(`단계는 최대 ${MAX_PSET_STEPS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, steps};
  try {
    if (id) await updateParticipationSet(id, payload);
    else await insertParticipationSet(payload);
    closeModal('psetEditModal');
    toast('저장했습니다','success');
    renderLookupsTable();
  } catch(e) {
    show('저장 실패: ' + (e.message||String(e)));
  }
}

// ══════════════════════════════════════
// 캠페인 폼: 참여방법 번들 + 인라인 단계 편집
// ══════════════════════════════════════
const _psetState = { new: [], edit: [] }; // 모드별 현재 단계 배열
const _psetCache = { new: [], edit: [] }; // 모드별 드롭다운 원본 번들 리스트

async function populateCampPsetDropdown(formMode, recruitType, selectedSetId) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  if (!sel) return;
  let sets = [];
  try { sets = await fetchParticipationSets(recruitType); } catch(e) { sets = []; }
  _psetCache[formMode] = sets;
  sel.innerHTML = `<option value="">— 번들 선택 —</option>` +
    sets.map(s => `<option value="${esc(s.id)}" ${selectedSetId===s.id?'selected':''}>${esc(s.name_ko)}</option>`).join('');
}

function onPsetSelectChange(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  if (!sel) return;
  const set = _psetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  // 현재 단계가 비어있지 않으면 confirm
  const hasContent = _psetState[formMode].some(s => (s.title_ja||s.title_ko||s.desc_ja||s.desc_ko||'').trim());
  const apply = () => {
    _psetState[formMode] = (set.steps||[]).map(s => ({...s}));
    renderCampSteps(formMode);
  };
  if (!hasContent) { apply(); return; }
  showConfirm('현재 입력된 단계를 덮어쓸까요?').then(ok => { if (ok) apply(); else sel.value = ''; });
}

async function reloadPsetFromBundle(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  if (!sel || !sel.value) { toast('먼저 번들을 선택하세요','error'); return; }
  const set = _psetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  const ok = await showConfirm(`번들 "${set.name_ko}"의 현재 내용으로 덮어쓸까요?`);
  if (!ok) return;
  _psetState[formMode] = (set.steps||[]).map(s => ({...s}));
  renderCampSteps(formMode);
}

function renderCampSteps(formMode) {
  const wrap = $(formMode === 'edit' ? 'editCampParticipationSteps' : 'newCampParticipationSteps');
  if (!wrap) return;
  const arr = _psetState[formMode];
  if (!arr.length) {
    wrap.innerHTML = `<div style="font-size:12px;color:var(--muted);padding:8px 0">단계가 없습니다. 번들을 선택하거나 단계를 추가하세요.</div>`;
    return;
  }
  wrap.innerHTML = arr.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">STEP ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="moveCampPsetStep('${formMode}',${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===arr.length-1?'disabled':''} onclick="moveCampPsetStep('${formMode}',${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" onclick="removeCampPsetStep('${formMode}',${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <input type="text" class="form-input" placeholder="제목 (한국어)" value="${esc(s.title_ko||'')}" style="font-size:13px;padding:8px 10px" oninput="_psetState['${formMode}'][${idx}].title_ko=this.value">
        <input type="text" class="form-input" placeholder="タイトル (日本語)" value="${esc(s.title_ja||'')}" style="font-size:13px;padding:8px 10px" oninput="_psetState['${formMode}'][${idx}].title_ja=this.value">
        <textarea class="form-input" placeholder="설명 (한국어)" rows="2" style="resize:vertical;font-size:13px;padding:8px 10px;line-height:1.5" oninput="_psetState['${formMode}'][${idx}].desc_ko=this.value">${esc(s.desc_ko||'')}</textarea>
        <textarea class="form-input" placeholder="説明 (日本語)" rows="2" style="resize:vertical;font-size:13px;padding:8px 10px;line-height:1.5" oninput="_psetState['${formMode}'][${idx}].desc_ja=this.value">${esc(s.desc_ja||'')}</textarea>
      </div>
    </div>
  `).join('');
}

function addCampPsetStep(formMode) {
  if (_psetState[formMode].length >= MAX_PSET_STEPS) { toast(`단계는 최대 ${MAX_PSET_STEPS}개까지`,'error'); return; }
  _psetState[formMode].push({title_ko:'', title_ja:'', desc_ko:'', desc_ja:''});
  renderCampSteps(formMode);
}

function removeCampPsetStep(formMode, idx) {
  _psetState[formMode].splice(idx, 1);
  renderCampSteps(formMode);
}

function moveCampPsetStep(formMode, idx, dir) {
  const arr = _psetState[formMode];
  const j = idx + dir;
  if (j < 0 || j >= arr.length) return;
  const [s] = arr.splice(idx, 1);
  arr.splice(j, 0, s);
  renderCampSteps(formMode);
}

function collectCampPsetPayload(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  const steps = _psetState[formMode].filter(s => (s.title_ja||s.title_ko||'').trim())
    .map(s => ({title_ko:s.title_ko||'', title_ja:s.title_ja||'', desc_ko:s.desc_ko||'', desc_ja:s.desc_ja||''}));
  return {
    participation_set_id: sel?.value || null,
    participation_steps: steps.length ? steps : null
  };
}

async function loadMyAdminInfo() {
  if (!currentAdminInfo && db) {
    const {data} = await db.from('admins').select('*').eq('auth_id', currentUser?.id).maybeSingle();
    currentAdminInfo = data;
  }
  if (!currentAdminInfo) return;
  if ($('myAdminEmail')) $('myAdminEmail').value = currentAdminInfo.email;
  if ($('myAdminName')) $('myAdminName').value = currentAdminInfo.name || '';
  if ($('myAdminRole')) $('myAdminRole').value = currentAdminInfo.role === 'super_admin' ? '슈퍼관리자' : currentAdminInfo.role === 'campaign_admin' ? '캠페인관리자' : '캠페인매니저';
  applyLookupMenuVisibility();
}

async function saveMyAdminInfo() {
  if (!currentAdminInfo || !db) return;
  const name = $('myAdminName')?.value.trim();
  try {
    await db.from('admins').update({name}).eq('id', currentAdminInfo.id);
    currentAdminInfo.name = name;
    toast('정보가 저장되었습니다','success');
  } catch(e) {
    toast('저장 오류: ' + e.message,'error');
  }
}

async function changeMyAdminPassword() {
  const cur = $('myAdminCurrentPw')?.value;
  const nw = $('myAdminNewPw')?.value;
  const nw2 = $('myAdminNewPw2')?.value;
  const err = $('myPwError');
  err.style.display = 'none';
  if (!cur || !nw) { err.textContent='모든 항목을 입력해주세요'; err.style.display='block'; return; }
  if (nw.length < 8) { err.textContent='새 비밀번호는 8자 이상이어야 합니다'; err.style.display='block'; return; }
  if (nw !== nw2) { err.textContent='비밀번호가 일치하지 않습니다'; err.style.display='block'; return; }
  try {
    const {error} = await db.auth.updateUser({password: nw});
    if (error) { err.textContent = error.message; err.style.display='block'; return; }
    toast('비밀번호가 변경되었습니다','success');
    $('myAdminCurrentPw').value = '';
    $('myAdminNewPw').value = '';
    $('myAdminNewPw2').value = '';
  } catch(e) {
    err.textContent = '변경 오류: ' + friendlyError(e.message); err.style.display='block';
  }
}

function openAddAdminModal() {
  $('addAdminModalTitle').textContent = '관리자 추가';
  $('editAdminId').value = '';
  $('adminFormEmail').value = '';
  $('adminFormEmail').disabled = false;
  $('adminFormName').value = '';
  $('adminFormRole').value = 'campaign_admin';
  $('adminFormBtn').textContent = '추가';
  $('adminFormError').style.display = 'none';
  const inviteNotice = document.getElementById('adminFormInviteNotice');
  if (inviteNotice) inviteNotice.style.display = '';
  $('addAdminModal').classList.add('open');
}

function openEditAdmin(id, email, name, role) {
  $('addAdminModalTitle').textContent = '관리자 수정';
  $('editAdminId').value = id;
  $('adminFormEmail').value = email;
  $('adminFormEmail').disabled = true;
  $('adminFormName').value = name;
  $('adminFormRole').value = role;
  $('adminFormBtn').textContent = '저장';
  $('adminFormError').style.display = 'none';
  const inviteNotice = document.getElementById('adminFormInviteNotice');
  if (inviteNotice) inviteNotice.style.display = 'none';
  $('addAdminModal').classList.add('open');
}

async function saveAdmin() {
  const err = $('adminFormError');
  err.style.display = 'none';
  const editId = $('editAdminId').value;

  if (editId) {
    // 수정 모드
    const name = $('adminFormName').value.trim();
    const role = $('adminFormRole').value;
    try {
      await db.from('admins').update({name, role}).eq('id', editId);
      toast('관리자 정보가 수정되었습니다','success');
      closeModal('addAdminModal');
      loadAdminAccounts();
    } catch(e) {
      err.textContent = '수정 오류: ' + friendlyError(e.message); err.style.display = 'block';
    }
  } else {
    // 추가 모드 (초대 플로우)
    const email = $('adminFormEmail').value.trim();
    const name = $('adminFormName').value.trim();
    const role = $('adminFormRole').value;
    if (!email || !name) { err.textContent = '모든 항목을 입력해주세요'; err.style.display = 'block'; return; }
    try {
      const {data, error} = await db.rpc('invite_admin', {
        admin_email: email, admin_name: name, admin_role: role
      });
      if (error) throw error;

      // 초대 메일 발송 (비밀번호 설정 링크)
      const redirectUrl = location.origin + '/#reset-pw';
      const {error: mailErr} = await db.auth.resetPasswordForEmail(email, {redirectTo: redirectUrl});
      if (mailErr) {
        toast('관리자 등록 성공. 단 초대 메일 발송 실패: ' + friendlyError(mailErr.message), 'error');
      } else {
        toast('관리자가 추가되었습니다. 초대 이메일이 발송되었습니다.', 'success');
      }
      closeModal('addAdminModal');
      loadAdminAccounts();
    } catch(e) {
      err.textContent = '추가 오류: ' + friendlyError(e.message); err.style.display = 'block';
    }
  }
}

function openDeleteAdminModal(adminId, authId, email) {
  const modal = document.getElementById('deleteAdminModal');
  if (!modal) return;
  document.getElementById('deleteAdminEmail').textContent = email;
  document.getElementById('deleteAdminAuthId').value = authId;
  document.getElementById('deleteAdminAdminId').value = adminId;
  modal.classList.add('open');
}

function closeDeleteAdminModal() {
  document.getElementById('deleteAdminModal')?.classList.remove('open');
}

async function executeRemoveRole() {
  const authId = document.getElementById('deleteAdminAuthId').value;
  if (!authId) return;
  try {
    const { error } = await db.rpc('remove_admin_role', { target_auth_id: authId });
    if (error) throw error;
    toast('관리자 권한이 해제되었습니다 (인플루언서 계정은 유지)', 'success');
    closeDeleteAdminModal();
    loadAdminAccounts();
  } catch(e) {
    toast('권한 해제 오류: ' + friendlyError(e.message), 'error');
  }
}

async function executeDeleteCompletely() {
  const authId = document.getElementById('deleteAdminAuthId').value;
  if (!authId) return;
  try {
    const { error } = await db.rpc('delete_admin_completely', { target_auth_id: authId });
    if (error) throw error;
    toast('계정이 완전 삭제되었습니다', 'success');
    closeDeleteAdminModal();
    loadAdminAccounts();
  } catch(e) {
    toast('삭제 오류: ' + friendlyError(e.message), 'error');
  }
}

function openResetPwModal(authId, email) {
  $('resetPwTargetId').value = authId;
  $('resetPwTargetEmail').textContent = email;
  $('resetPwNew').value = '';
  $('resetPwError').style.display = 'none';
  $('resetPwModal').classList.add('open');
}

async function executeResetPw() {
  const authId = $('resetPwTargetId').value;
  const newPw = $('resetPwNew').value;
  const err = $('resetPwError');
  err.style.display = 'none';
  if (!newPw || newPw.length < 8) { err.textContent = '비밀번호는 8자 이상이어야 합니다'; err.style.display = 'block'; return; }
  try {
    const {error} = await db.rpc('reset_admin_password', {target_auth_id: authId, new_password: newPw});
    if (error) throw error;
    toast('비밀번호가 초기화되었습니다','success');
    closeModal('resetPwModal');
  } catch(e) {
    err.textContent = '초기화 오류: ' + friendlyError(e.message); err.style.display = 'block';
  }
}

async function sendResetEmail() {
  const email = $('resetPwTargetEmail').textContent;
  try {
    const {error} = await db.auth.resetPasswordForEmail(email);
    if (error) throw error;
    toast(`${email}로 재설정 링크를 보냈습니다`,'success');
    closeModal('resetPwModal');
  } catch(e) {
    toast('이메일 발송 오류: ' + friendlyError(e.message),'error');
  }
}

// ══════════════════════════════════════
// 회원가입 차트 / KPI / 프로필 완성률
// ══════════════════════════════════════
var _allUsers = [];
var _signupChart = null;

function renderSignupKPIs(users) {
  const now = new Date();
  const todayStr = now.toISOString().slice(0, 10);
  const weekAgo = new Date(now); weekAgo.setDate(weekAgo.getDate() - 7);

  const today = users.filter(u => (u.created_at || '').slice(0, 10) === todayStr).length;
  const week = users.filter(u => new Date(u.created_at) >= weekAgo).length;

  $('kpiSignupToday').textContent = today;
  $('kpiSignupWeek').textContent = week;

  const fmt = d => `${d.getMonth()+1}/${d.getDate()}`;
  $('kpiWeekRange').textContent = `${fmt(weekAgo)} ~ ${fmt(now)}`;
}

function renderSignupChart(users, days) {
  const now = new Date();
  const labels = [];
  const counts = [];

  if (days === 0) {
    // 전체: 월별 집계
    const monthMap = {};
    users.forEach(u => {
      const m = (u.created_at || '').slice(0, 7);
      if (m) monthMap[m] = (monthMap[m] || 0) + 1;
    });
    const months = Object.keys(monthMap).sort();
    months.forEach(m => {
      labels.push(m);
      counts.push(monthMap[m]);
    });
  } else {
    // 일별 집계
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
      const dateStr = d.toISOString().slice(0, 10);
      const label = `${d.getMonth() + 1}/${d.getDate()}`;
      const count = users.filter(u => (u.created_at || '').slice(0, 10) === dateStr).length;
      labels.push(label);
      counts.push(count);
    }
  }

  const canvas = $('signupChart');
  if (!canvas) return;
  if (_signupChart) _signupChart.destroy();

  _signupChart = new Chart(canvas, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [{
        label: '신규 가입',
        data: counts,
        backgroundColor: 'rgba(200,120,163,.6)',
        borderColor: 'rgba(200,120,163,1)',
        borderWidth: 1,
        borderRadius: 4
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false }
      },
      scales: {
        y: { beginAtZero: true, ticks: { stepSize: 1, font: { size: 11 } }, grid: { color: 'rgba(0,0,0,.05)' } },
        x: { ticks: { font: { size: 10 } }, grid: { display: false } }
      }
    }
  });
}

function switchSignupPeriod(days, btn) {
  document.querySelectorAll('.signup-period-btn').forEach(b => b.classList.remove('on'));
  btn.classList.add('on');
  renderSignupChart(_allUsers, days);
}

function renderProfileCompletion(users) {
  if (!users.length) { $('profileCompletionBars').innerHTML = '<div style="font-size:11px;color:var(--muted)">데이터 없음</div>'; return; }
  const total = users.length;
  const hasSns = users.filter(u => u.ig || u.x || u.tiktok || u.youtube).length;
  const hasIg = users.filter(u => u.ig).length;
  const hasX = users.filter(u => u.x).length;
  const hasTiktok = users.filter(u => u.tiktok).length;
  const hasYt = users.filter(u => u.youtube).length;
  const hasAddr = users.filter(u => u.zip || u.address).length;
  const hasBank = users.filter(u => u.paypal_email).length;

  const pct = v => Math.round(v / total * 100);
  const bar = (label, val, color, sub) => `
    <div style="margin-bottom:${sub ? 4 : 8}px;${sub ? 'padding-left:12px' : ''}">
      <div style="display:flex;justify-content:space-between;font-size:${sub ? 10 : 11}px;margin-bottom:3px">
        <span style="color:${sub ? 'var(--muted)' : 'var(--ink)'}">${label}</span><span style="color:var(--muted);font-weight:600">${val}%</span>
      </div>
      <div style="height:${sub ? 4 : 6}px;background:var(--bg);border-radius:3px;overflow:hidden">
        <div style="height:100%;width:${val}%;background:${color};border-radius:3px;transition:width .4s;opacity:${sub ? '.6' : '1'}"></div>
      </div>
    </div>`;

  $('profileCompletionBars').innerHTML =
    bar('SNS', pct(hasSns), '#5B7CFF', false) +
    bar('Instagram', pct(hasIg), '#5B7CFF', true) +
    bar('X (Twitter)', pct(hasX), '#5B7CFF', true) +
    bar('TikTok', pct(hasTiktok), '#5B7CFF', true) +
    bar('YouTube', pct(hasYt), '#5B7CFF', true) +
    '<div style="margin-top:4px"></div>' +
    bar('배송지', pct(hasAddr), '#FF9F43', false) +
    bar('PayPal', pct(hasBank), '#28C76F', false);
}

// ============================================================
// Stage 2: 결과물 관리 (Deliverables)
// ============================================================
let _delivCache = [];
let _delivDetailCurrent = null;  // 열려 있는 상세 {id, version}
let _delivSort = {col: null, dir: null};  // 수동 정렬 상태 (null이면 기본 정렬 사용)

function toggleDelivSort(col) {
  // 같은 컬럼: asc → desc → 해제
  if (_delivSort.col === col) {
    if (_delivSort.dir === 'asc') _delivSort.dir = 'desc';
    else if (_delivSort.dir === 'desc') { _delivSort.col = null; _delivSort.dir = null; }
    else _delivSort.dir = 'asc';
  } else {
    _delivSort.col = col;
    _delivSort.dir = 'asc';
  }
  renderDeliverablesList();
}

function resetDelivFiltersAndSort() {
  const k = $('delivKindFilter'); if (k) k.value = 'all';
  const s = $('delivStatusFilter'); if (s) s.value = 'pending';
  const c = $('delivCampFilter'); if (c) c.value = 'all';
  const q = $('delivSearch'); if (q) q.value = '';
  _delivSort = {col: null, dir: null};
  renderDeliverablesList();
}

function applyDelivSortIndicators() {
  document.querySelectorAll('#adminPane-deliverables .sort-arrows').forEach(el => {
    const col = el.getAttribute('data-sort');
    if (_delivSort.col === col) {
      el.textContent = _delivSort.dir === 'asc' ? '▲' : '▼';
      el.style.color = 'var(--dark-pink)';
    } else {
      el.textContent = '▲▼';
      el.style.color = '';
    }
  });
}

async function loadDeliverables() {
  // 캠페인 드롭다운 채우기 (첫 로드만)
  const sel = $('delivCampFilter');
  if (sel && sel.options.length <= 1) {
    const camps = await fetchCampaigns().catch(() => []);
    camps.forEach(c => {
      const opt = document.createElement('option');
      opt.value = c.id;
      opt.textContent = c.title;
      sel.appendChild(opt);
    });
  }
  await renderDeliverablesList();
}

async function renderDeliverablesList() {
  const tbody = $('delivTableBody');
  if (!tbody) return;
  tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  const status = $('delivStatusFilter')?.value || 'pending';
  const kind = $('delivKindFilter')?.value || 'all';
  const campId = $('delivCampFilter')?.value || 'all';
  const search = ($('delivSearch')?.value || '').trim().toLowerCase();
  const rows = await fetchDeliverables({status, kind, campaign_id: campId});
  _delivCache = rows;
  let filtered = search
    ? rows.filter(r => {
        const n = (r.influencers?.name || '') + ' ' + (r.influencers?.name_kana || '') + ' ' + (r.influencers?.email || '');
        return n.toLowerCase().includes(search);
      })
    : rows.slice();
  // 수동 정렬 적용 (설정돼 있으면 fetchDeliverables의 order()를 덮어씀)
  if (_delivSort.col) {
    const dir = _delivSort.dir === 'desc' ? -1 : 1;
    const statusOrder = {pending: 0, approved: 1, rejected: 2};
    filtered.sort((a, b) => {
      let av, bv;
      switch (_delivSort.col) {
        case 'kind':      av = a.kind || ''; bv = b.kind || ''; break;
        case 'submitted': av = a.submitted_at || ''; bv = b.submitted_at || ''; break;
        case 'reviewed':  av = a.reviewed_at || ''; bv = b.reviewed_at || ''; break;
        case 'status':    av = statusOrder[a.status] ?? 99; bv = statusOrder[b.status] ?? 99; break;
        default: return 0;
      }
      if (av < bv) return -1 * dir;
      if (av > bv) return 1 * dir;
      return 0;
    });
  }
  applyDelivSortIndicators();
  const cnt = $('delivTotalCount');
  if (cnt) cnt.textContent = `총 ${filtered.length}건`;
  if (!filtered.length) {
    tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 결과물이 없습니다.</td></tr>';
    return;
  }
  tbody.innerHTML = filtered.map(d => {
    const kindBadge = d.kind === 'receipt'
      ? '<span style="display:inline-flex;align-items:center;gap:3px;background:#fdf5fb;color:var(--dark-pink);font-size:11px;font-weight:600;padding:3px 8px;border-radius:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">receipt</span> 영수증</span>'
      : '<span style="display:inline-flex;align-items:center;gap:3px;background:#eef5ff;color:#2c5fa8;font-size:11px;font-weight:600;padding:3px 8px;border-radius:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">link</span> 게시물</span>';
    const camp = d.campaigns || {};
    const inf = d.influencers || {};
    const stBadge = delivStatusBadge(d.status);
    const infName = esc(inf.name || '—');
    const infEmail = esc(inf.email || '');
    const infLine = inf.line_id ? `LINE: ${esc(inf.line_id)}` : '';
    const infSub = [infEmail, infLine].filter(Boolean).join(' · ');
    const reviewedCell = d.reviewed_at
      ? `<span style="font-size:12px">${formatDateTime(d.reviewed_at)}</span>`
      : '<span style="font-size:11px;color:var(--muted)">—</span>';
    return `<tr>
      <td>${kindBadge}</td>
      <td>${esc(camp.title || '—')}<div style="font-size:10px;color:var(--muted)">${esc(camp.brand || '')}</div></td>
      <td>${infName}${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}</td>
      <td style="font-size:12px">${formatDateTime(d.submitted_at)}</td>
      <td>${reviewedCell}</td>
      <td>${stBadge}</td>
      <td><button class="btn btn-ghost btn-xs" onclick="openDelivDetail('${d.id}')">상세</button></td>
    </tr>`;
  }).join('');
}

function statusLabelKo(status) {
  return {pending: '검수대기', approved: '승인', rejected: '반려'}[status] || status;
}

function delivStatusBadge(status) {
  const map = {
    pending: '<span style="background:#FFF4E4;color:#B8741A;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">검수대기</span>',
    approved: '<span style="background:#E4F5E8;color:#2D7A3E;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">승인</span>',
    rejected: '<span style="background:#FFE4E4;color:#C33;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">반려</span>'
  };
  return map[status] || status;
}

async function openDelivDetail(id) {
  const modal = $('delivDetailModal');
  if (!modal) return;
  openModal('delivDetailModal');
  const body = $('delivDetailBody');
  const footer = $('delivDetailFooter');
  if (body) body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  if (footer) footer.innerHTML = '';
  const [d, events] = await Promise.all([
    fetchDeliverableById(id),
    fetchDeliverableEvents(id)
  ]);
  if (!d) {
    if (body) body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">결과물을 찾을 수 없습니다.</div>';
    return;
  }
  _delivDetailCurrent = {id: d.id, version: d.version, recruit_type: d.campaigns?.recruit_type || null};
  const camp = d.campaigns || {};
  const inf = d.influencers || {};
  const titleEl = $('delivDetailTitle');
  if (titleEl) titleEl.innerHTML = `${esc(camp.title || '캠페인')} <span style="font-size:12px;color:var(--muted);font-weight:400">· ${esc(inf.name || '—')}</span>`;

  // 본문
  let contentHtml = '';
  if (d.kind === 'receipt') {
    const amt = d.purchase_amount != null ? `¥${Number(d.purchase_amount).toLocaleString('ja-JP')}` : '—';
    contentHtml = `
      <div style="display:grid;grid-template-columns:240px 1fr;gap:16px">
        <div>
          ${d.receipt_url
            ? `<a href="${esc(d.receipt_url)}" target="_blank" rel="noopener"><img src="${esc(d.receipt_url)}" alt="영수증" style="width:100%;border:1px solid var(--line);border-radius:8px;cursor:zoom-in"></a>`
            : '<div style="width:100%;height:180px;background:#f5f5f5;border-radius:8px;display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:12px">이미지 없음</div>'}
        </div>
        <div style="font-size:13px">
          <div style="margin-bottom:8px"><span style="color:var(--muted)">구매일</span> · ${d.purchase_date ? formatDate(d.purchase_date) : '—'}</div>
          <div style="margin-bottom:8px"><span style="color:var(--muted)">구매 금액</span> · <strong>${amt}</strong></div>
          ${d.memo ? `<div style="margin-bottom:8px"><span style="color:var(--muted)">메모</span> · ${esc(d.memo)}</div>` : ''}
          <div style="margin-top:14px;padding-top:10px;border-top:1px dashed var(--line);font-size:11px;color:var(--muted)">
            제출일 · ${formatDate(d.submitted_at)}<br>
            최종 수정 · ${formatDate(d.updated_at)}<br>
            version · ${d.version}
          </div>
        </div>
      </div>`;
  } else {
    // post (Stage 3에서 본격 사용)
    const subs = Array.isArray(d.post_submissions) ? d.post_submissions : [];
    contentHtml = `
      <div style="font-size:13px">
        <div style="margin-bottom:10px"><span style="color:var(--muted)">채널</span> · <strong>${esc(d.post_channel || '—')}</strong></div>
        <div style="margin-bottom:10px"><span style="color:var(--muted)">URL</span> · ${d.post_url ? `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" style="color:var(--dark-pink);word-break:break-all">${esc(d.post_url)}</a>` : '—'}</div>
        ${subs.length ? `<div style="margin-top:12px"><span style="color:var(--muted);font-size:11px">제출 이력 (${subs.length}건)</span><ul style="margin:6px 0 0;padding-left:18px;font-size:11px">${subs.map(s => `<li>${esc(s.submitted_at || '')} · ${esc(s.channel || '')}</li>`).join('')}</ul></div>` : ''}
      </div>`;
  }

  // 반려 사유 (있을 때만)
  if (d.status === 'rejected' && d.reject_reason) {
    contentHtml += `<div style="margin-top:14px;padding:10px 12px;background:#FFF5F5;border-left:3px solid #C33;border-radius:4px;font-size:12px">
      <div style="font-weight:600;color:#C33;margin-bottom:4px">반려 사유</div>
      <div style="white-space:pre-wrap;color:var(--ink)">${esc(d.reject_reason)}</div>
    </div>`;
  }

  // 이력 타임라인
  if (events.length) {
    contentHtml += '<div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--line)"><div style="font-size:12px;font-weight:600;color:var(--ink);margin-bottom:8px">변경 이력</div><div style="font-size:11px">';
    contentHtml += events.map(e => {
      const label = {submit:'제출', resubmit:'재제출', approve:'승인', reject:'반려', revert:'되돌리기'}[e.action] || e.action;
      return `<div style="padding:5px 0;border-bottom:1px dashed var(--line);display:flex;justify-content:space-between;gap:10px">
        <span><strong>${label}</strong>${e.from_status ? ` · ${statusLabelKo(e.from_status)} → ${statusLabelKo(e.to_status)}` : ''}${e.reason ? ` · ${esc(e.reason.slice(0, 60))}` : ''}</span>
        <span style="color:var(--muted);white-space:nowrap">${formatDate(e.created_at)}</span>
      </div>`;
    }).join('');
    contentHtml += '</div></div>';
  }

  if (body) body.innerHTML = contentHtml;

  // 푸터 액션
  let footerHtml = '';
  if (d.status === 'pending') {
    footerHtml = `
      <button class="btn btn-ghost" onclick="closeDelivDetail()">닫기</button>
      <button class="btn btn-ghost" onclick="openDelivRejectModal('${d.id}', ${d.version})" style="color:#C33;border-color:#C33">반려</button>
      <button class="btn btn-primary" onclick="approveDeliv('${d.id}', ${d.version})">승인</button>
    `;
  } else {
    footerHtml = `
      <button class="btn btn-ghost" onclick="closeDelivDetail()">닫기</button>
      <button class="btn btn-ghost" onclick="revertDeliv('${d.id}', ${d.version})">되돌리기 (검수대기로)</button>
    `;
  }
  if (footer) footer.innerHTML = footerHtml;
}

function closeDelivDetail() {
  closeModal('delivDetailModal');
  _delivDetailCurrent = null;
}

async function approveDeliv(id, version) {
  const ret = await updateDeliverableStatus(id, 'approved', version);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    closeDelivDetail();
    await renderDeliverablesList();
    return;
  }
  toast('승인 처리되었습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
}

async function revertDeliv(id, version) {
  const ok = await showConfirm('검수 결과를 되돌리시겠습니까?\n상태가 검수대기로 변경됩니다.\n\n인플루언서가 이미 결과를 확인했을 수 있습니다.');
  if (!ok) return;
  const ret = await updateDeliverableStatus(id, 'pending', version);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다.', 'warn');
    closeDelivDetail();
    await renderDeliverablesList();
    return;
  }
  toast('검수대기로 되돌렸습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
}

// 반려 모달 상태
let _delivRejectCtx = null;  // {id, version}

async function openDelivRejectModal(id, version) {
  _delivRejectCtx = {id, version};
  const tpl = $('delivRejectTemplate');
  const reason = $('delivRejectReason');
  // 현재 열려 있는 deliverable의 캠페인 recruit_type 추출
  const campRt = _delivDetailCurrent?.recruit_type
    || (_delivCache.find(d => d.id === id)?.campaigns?.recruit_type)
    || null;
  if (tpl) {
    tpl.innerHTML = '<option value="">— 직접 입력 —</option>';
    try {
      const items = await fetchLookupsAll('reject_reason');
      items.filter(v => v.active).filter(v => {
        const rts = Array.isArray(v.recruit_types) ? v.recruit_types : [];
        // 빈 배열 = 공통, 아니면 캠페인 타입과 매칭
        return !rts.length || !campRt || rts.includes(campRt);
      }).forEach(v => {
        const opt = document.createElement('option');
        opt.value = v.code;
        opt.textContent = v.name_ko;
        opt.dataset.desc = v.name_ja || '';
        tpl.appendChild(opt);
      });
    } catch(e) {}
    const otherOpt = document.createElement('option');
    otherOpt.value = 'other';
    otherOpt.textContent = '기타';
    tpl.appendChild(otherOpt);
    tpl.value = '';
  }
  if (reason) reason.value = '';
  openModal('delivRejectModal');
}

function closeDelivRejectModal() {
  closeModal('delivRejectModal');
  _delivRejectCtx = null;
}

function onDelivRejectTemplateChange() {
  const tpl = $('delivRejectTemplate');
  const reason = $('delivRejectReason');
  if (!tpl || !reason) return;
  const selected = tpl.options[tpl.selectedIndex];
  const desc = selected?.dataset?.desc || '';
  if (tpl.value && tpl.value !== 'other' && desc) {
    reason.value = desc;
  } else if (tpl.value === 'other') {
    reason.value = '';
  }
}

async function submitDelivReject() {
  if (!_delivRejectCtx) return;
  const reason = ($('delivRejectReason')?.value || '').trim();
  const templateCode = $('delivRejectTemplate')?.value || null;
  if (!reason) {
    toast('반려 사유를 입력해주세요.', 'warn');
    return;
  }
  const {id, version} = _delivRejectCtx;
  const ret = await updateDeliverableStatus(id, 'rejected', version, reason, templateCode);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다.', 'warn');
    closeDelivRejectModal();
    closeDelivDetail();
    await renderDeliverablesList();
    return;
  }
  toast('반려 처리되었습니다.');
  closeDelivRejectModal();
  closeDelivDetail();
  await renderDeliverablesList();
}
