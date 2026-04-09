// ══════════════════════════════════════
// ADMIN
// ══════════════════════════════════════
// エラーメッセージを韓国語に変換
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
  // サイドバーのアクティブ状態をpane名で自動検索
  if (!el) {
    const parentPane = {
      'add-campaign':'campaigns','edit-campaign':'campaigns',
      'camp-applicants':'campaigns','influencer-detail':'influencers'
    }[pane] || pane;
    document.querySelectorAll('.admin-si').forEach(s => {
      if (s.getAttribute('onclick') && s.getAttribute('onclick').includes("'" + parentPane + "'")) el = s;
    });
  }
  if (el) el.classList.add('on');
  if (pane==='applications') loadApplications();
  if (pane==='campaigns') loadAdminCampaigns();
  if (pane==='influencers') loadAdminInfluencers();
  if (pane==='admin-accounts') loadAdminAccounts();
  if (pane==='my-account') loadMyAdminInfo();
  // 브라우저 히스토리 기록 (뒤로가기 지원)
  if (pushHistory !== false) {
    history.pushState({pane: pane}, '', '#' + pane);
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
  loadAdminCampaigns();
  loadAdminInfluencers();

  // 회원가입 차트 + KPI
  _allUsers = users;
  renderSignupKPIs(users);
  renderSignupChart(users, 30);
  renderProfileCompletion(users);
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round">assignment</span><span class="si-text">신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length}</span>`:''}`;

  // Recent apps — 신청관리와 동일 UI
  const recent = apps.sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
  $('recentAppsBody').innerHTML = recent.length ? recent.map(a=>{
    const camp = camps.find(c=>c.id===a.campaign_id)||{};
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = camp.recruit_type==='monitor'?'<span class="badge badge-blue" style="font-size:9px">리뷰어</span>':camp.recruit_type==='gifting'?'<span class="badge badge-gold" style="font-size:9px">기프팅</span>':'';
    return `<tr>
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${thumbUrl}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:4px"><strong style="font-size:13px">${esc(camp.title)||'—'}</strong>${typeLabel}</div>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${users.find(u=>u.email===a.user_email)?.id||''}')">${esc(a.user_name)||'—'}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)}</div>
      </td>
      <td style="max-width:180px;font-size:12px;color:var(--ink)">${esc(a.message)||'—'}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadge(a.status)}</td>
      <td style="white-space:nowrap"><div style="display:flex;gap:4px">
        ${a.status==='pending'?`<button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected')">미승인</button>`:'—'}
      </div></td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
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

async function loadAdminCampaigns(useCache) {
  let camps = useCache ? allCampaigns.slice() : await fetchCampaigns();
  if (!useCache) allCampaigns = camps.slice();
  // タイプフィルタ
  const typeFilter = $('adminCampTypeFilter')?.value || 'all';
  if (typeFilter !== 'all') camps = camps.filter(c => c.recruit_type === typeFilter);

  // ステータスフィルタ
  const statusFilter = $('adminCampStatusFilter')?.value || 'all';
  if (statusFilter !== 'all') camps = camps.filter(c => c.status === statusFilter);

  // 検索フィルタ
  const searchVal = ($('adminCampSearch')?.value || '').trim().toLowerCase();
  if (searchVal) camps = camps.filter(c => (c.title||'').toLowerCase().includes(searchVal) || (c.brand||'').toLowerCase().includes(searchVal));

  const allApps = await fetchApplications();

  // ソート
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

  // フィルタ・検索・ソート中は順序変更を無効化
  const isFiltered = searchVal || typeFilter !== 'all' || statusFilter !== 'all' || !!adminCampSortKey;

  const typeLabel = t => t==='monitor'?'<span class="badge badge-blue" style="font-size:9px;padding:1px 6px">리뷰어</span>':t==='gifting'?'<span class="badge badge-gold" style="font-size:9px;padding:1px 6px">기프팅</span>':'';
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
    const cnt = allApps.filter(a=>a.campaign_id===c.id).length;
    const pct = c.slots > 0 ? Math.round(cnt/c.slots*100) : 0;
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
            ${thumbUrl ? `<img src="${thumbUrl}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:20px">${esc(c.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:var(--muted)">inventory_2</span>'}</span>`}
            ${imgCount > 1 ? `<span style="position:absolute;bottom:0;left:0;background:rgba(0,0,0,.65);color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:0 4px 0 0">+${imgCount}</span>` : ''}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:5px">${typeLabel(c.recruit_type)}<strong>${esc(c.title)}</strong></div>
            <div style="font-size:11px;color:var(--muted);margin-top:2px">${esc(c.brand)}</div>
            ${c.post_deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:1px">게시: ~${formatDate(c.post_deadline)} ${dDayLabel(c.post_deadline)}</div>` : ''}
          </div>
        </div>
      </td>
      <td>${statusBadge(c.status)}</td>
      <td style="font-size:13px;font-weight:600;color:var(--ink)">${(c.view_count||0).toLocaleString()}</td>
      <td>
        <div style="display:flex;align-items:center;gap:8px">
          <button class="btn btn-ghost btn-xs" style="font-weight:700;color:${cnt>0?'var(--pink)':'var(--muted)'};border-color:${cnt>0?'var(--pink)':'var(--line)'}" data-camp-title="${esc(c.title)}" onclick="openCampApplicants('${c.id}',this.dataset.campTitle)">
            ${cnt} / ${c.slots}명
          </button>
          <div style="width:48px;height:5px;background:var(--line);border-radius:3px;overflow:hidden">
            <div style="width:${Math.min(pct,100)}%;height:100%;background:${barColor};border-radius:3px"></div>
          </div>
        </div>
        ${c.deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:3px">마감: ${formatDate(c.deadline)} ${dDayLabel(c.deadline)}</div>` : ''}
      </td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDate(c.created_at)}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDateTime(c.updated_at||c.created_at)}</td>
      ${adminReorderMode ? '' : `<td style="position:relative">
        <span class="material-icons-round camp-more-btn" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s" data-camp-title="${esc(c.title)}" onclick="toggleCampMoreMenu(event,this,'${c.id}',this.dataset.campTitle)">more_vert</span>
      </td>`}
    </tr>`;
  }).join('') || `<tr><td colspan="${adminReorderMode?8:8}" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>`;
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

  // 기존 이미지 로드
  editCampImgChanged = false;
  editCampImgData.length = 0;
  [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8]
    .filter(Boolean).forEach(url => editCampImgData.push({data: url}));
  renderImgPreview(editCampImgData, 'editCampImgPreviewWrap', 'editCampImgCounter', 'editCampImgData');

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
    const gv = id => $(id)?.value||'';
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
    if (editDeadline && editStatus === 'active') {
      const dl = new Date(editDeadline); dl.setHours(23,59,59,999);
      if (new Date() > dl) {
        toast('모집 마감일이 지났으므로 「모집중」 상태로 저장할 수 없습니다','error');
        return;
      }
    }

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

    // 이미지가 변경된 경우에만 업로드
    if (editCampImgChanged) {
      toast('이미지 업로드 중...','');
      const imgUrls = await uploadCampImages(editCampImgData);
      updates.image_url = imgUrls[0];
      updates.img1 = imgUrls[0]; updates.img2 = imgUrls[1];
      updates.img3 = imgUrls[2]; updates.img4 = imgUrls[3];
      updates.img5 = imgUrls[4]; updates.img6 = imgUrls[5];
      updates.img7 = imgUrls[6]; updates.img8 = imgUrls[7];
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
      type: src.type, channel: src.channel, category: src.category,
      recruit_type: src.recruit_type, content_types: src.content_types,
      emoji: src.emoji, description: src.description,
      hashtags: src.hashtags, mentions: src.mentions,
      appeal: src.appeal, guide: src.guide, ng: src.ng,
      product_price: src.product_price, reward: src.reward,
      slots: src.slots, applied_count: 0,
      deadline: src.deadline, post_deadline: src.post_deadline, post_days: src.post_days,
      image_url: src.image_url,
      img1: src.img1, img2: src.img2, img3: src.img3, img4: src.img4,
      img5: src.img5, img6: src.img6, img7: src.img7, img8: src.img8,
      order_index: src.order_index,
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
  // 既存ドロップダウンを閉じる
  document.querySelectorAll('.status-dropdown').forEach(d => d.remove());

  const wrapper = badgeEl.parentElement;
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
  wrapper.appendChild(dd);

  // 外部クリックで閉じる
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
  if (newStatus === 'active') {
    const camp = allCampaigns.find(c => c.id === campId);
    if (camp?.deadline) {
      const dl = new Date(camp.deadline); dl.setHours(23,59,59,999);
      if (new Date() > dl) {
        toast('모집 마감일이 지났으므로 「모집중」으로 변경할 수 없습니다','error');
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
  // ローカルキャッシュで即時UI更新
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

  // allCampaignsも即時反映
  const a = allCampaigns.find(c=>c.id===camps[idx].id);
  const b = allCampaigns.find(c=>c.id===camps[swapIdx].id);
  if (a) a.order_index = camps[idx].order_index;
  if (b) b.order_index = camps[swapIdx].order_index;

  // 即座にUI更新（キャッシュ使用）
  loadAdminCampaigns(true);
  const movedRow = document.querySelector(`tr[data-camp-id="${campId}"]`);
  if (movedRow) {
    movedRow.style.transition = 'background .3s';
    movedRow.style.background = 'rgba(200,120,163,.12)';
    setTimeout(() => { movedRow.style.background = ''; }, 600);
  }

  // DBはバックグラウンドで保存
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

  $('campApplicantsSubtitle').textContent = `신청자 목록`;
  $('campApplicantsStats').innerHTML = `
    <span style="color:var(--ink);font-weight:600">${total}명 신청</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--green)">승인 ${approved}명</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--gold)">심사중 ${pending}명</span>
  `;

  const _users = await fetchInfluencers();
  $('campApplicantsBody').innerHTML = apps.length ? apps.map(a=>{
    const _u = _users.find(u=>u.email===a.user_email)||{};
    return `<tr>
    <td>
      <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${adminBadge(a.user_email)}</div>
      <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>
    </td>
    <td>${a.ig_id?`<a href="https://instagram.com/${esc(a.ig_id)}" target="_blank" style="color:var(--pink);font-weight:600">@${esc(a.ig_id)}</a>`:esc(a.user_ig)||'—'}</td>
    <td style="font-weight:600">${(a.user_followers||0).toLocaleString()}</td>
    <td style="max-width:200px;font-size:12px;color:var(--muted)">${esc(a.message)||'—'}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadge(a.status)}</td>
    <td><div style="display:flex;gap:5px">
      ${a.status==='pending'?`
        <button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved');loadCampApplicants()">승인</button>
        <button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected');loadCampApplicants()">미승인</button>
      `:'—'}
    </div></td>
  </tr>`;}).join('') : '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>';
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
    bank: u => u.bank_name ? 1 : 0,
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
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${infSortTh('Instagram','ig')}</th><th>${infSortTh('X(Twitter)','x')}</th><th>${infSortTh('TikTok','tiktok')}</th><th>${infSortTh('YouTube','youtube')}</th><th>${infSortTh('합계','total')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('계좌','bank')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = sortInfUsers(filtered);
    bodyEl.innerHTML = filtered.length ? filtered.map(u => {
      const igF = (u.ig_followers||0).toLocaleString();
      const xF = (u.x_followers||0).toLocaleString();
      const ttF = (u.tiktok_followers||0).toLocaleString();
      const ytF = (u.youtube_followers||0).toLocaleString();
      const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)).toLocaleString();
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.bank_name ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
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
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${chLabel} ID</th><th>${infSortTh('팔로워','followers')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('계좌','bank')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = infSortKey ? sortInfUsers(filtered) : filtered.sort((a,b)=>(b[fKey]||0)-(a[fKey]||0));
    bodyEl.innerHTML = filtered.length ? filtered.map(u => {
      const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
      const bank = u.bank_name ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
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

  // 계좌 — row()内でesc()済み
  const bankType = {'普通':'보통예금','当座':'당좌예금'}[u.bank_type] || u.bank_type;
  $('infDetailBank').innerHTML = u.bank_name
    ? row('은행명', u.bank_name) + row('지점명', u.bank_branch) + row('계좌 종류', bankType) + row('계좌번호', u.bank_number) + row('예금주', u.bank_holder)
    : '<div style="text-align:center;color:var(--muted);padding:16px;font-size:13px">계좌 미등록</div>';

  // 신청 이력
  const apps = await fetchApplications({user_id: userId});
  const camps = await fetchCampaigns();
  $('infDetailAppCount').textContent = `${apps.length}건`;
  $('infDetailAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const typeLabel = camp.recruit_type==='monitor'?'<span class="badge badge-blue">리뷰어</span>':'<span class="badge badge-gold">기프팅</span>';
    return `<tr>
      <td style="font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td>
      <td>${typeLabel}</td>
      <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
      <td>${getStatusBadge(a.status)}</td>
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

  const bankType2 = {'普通':'보통예금','当座':'당좌예금'}[u.bank_type] || u.bank_type;
  $('infModalBank').innerHTML = u.bank_name
    ? row('은행', u.bank_name) + row('지점', u.bank_branch) + row('종류', bankType2) + row('계좌번호', u.bank_number) + row('예금주', u.bank_holder)
    : '<div style="text-align:center;color:var(--muted);padding:12px;font-size:12px">계좌 미등록</div>';

  const apps = await fetchApplications({user_id: userId});
  const camps = await fetchCampaigns();
  $('infModalAppCount').textContent = `${apps.length}건`;
  $('infModalAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const tl = camp.recruit_type==='monitor'?'<span class="badge badge-blue">리뷰어</span>':'<span class="badge badge-gold">기프팅</span>';
    return `<tr><td style="font-size:12px;font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td><td>${tl}</td><td style="font-size:11px;color:var(--muted)">${formatDate(a.created_at)}</td><td>${getStatusBadge(a.status)}</td></tr>`;
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
  let apps = await fetchApplications();
  const users = await fetchInfluencers();

  // タイプフィルタ
  const typeFilter = $('appTypeFilter')?.value || 'all';
  if (typeFilter !== 'all') {
    const filteredCampIds = camps.filter(c => c.recruit_type === typeFilter).map(c => c.id);
    apps = apps.filter(a => filteredCampIds.includes(a.campaign_id));
  }

  // ステータスフィルタ
  const statusFilter = $('appStatusFilter')?.value || 'all';
  if (statusFilter !== 'all') apps = apps.filter(a => a.status === statusFilter);

  // 検索フィルタ
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
  apps.sort((a,b) => (new Date(a.created_at) - new Date(b.created_at)) * appDir);

  if (countEl) countEl.textContent = `총 ${apps.length}건`;

  bodyEl.innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c => c.id === a.campaign_id) || {};
    const u = users.find(u => u.email === a.user_email) || {};
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = camp.recruit_type==='monitor'?'<span class="badge badge-blue" style="font-size:9px">리뷰어</span>':camp.recruit_type==='gifting'?'<span class="badge badge-gold" style="font-size:9px">기프팅</span>':'';
    return `<tr>
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${thumbUrl}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:4px"><strong style="font-size:13px">${esc(camp.title)||'—'}</strong>${typeLabel}</div>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>
      </td>
      <td style="max-width:180px;font-size:12px;color:var(--ink)">${esc(a.message)||'—'}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadge(a.status)}</td>
      <td style="white-space:nowrap"><div style="display:flex;gap:4px">
        ${a.status==='pending'?`<button class="btn btn-green btn-xs" onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" onclick="updateAppStatus('${a.id}','rejected')">미승인</button>`:'—'}
      </div></td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

async function updateAppStatus(appId, status) {
  try {
    await updateApplication(appId, {status});
    toast(status==='approved'?'승인했습니다':'미승인 처리했습니다', status==='approved'?'success':'');
    renderAppCampList();
    loadAdminData();
  } catch(e) {
    toast('상태 변경 오류: '+friendlyError(e.message),'error');
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
  const postDeadline = $('newCampPostDeadline')?.value;
  if (postDeadline && deadline && new Date(postDeadline) < new Date(deadline)) {
    toast('게시 마감일은 모집 마감일 이후여야 합니다','error');
    return;
  }
  const catEmojiMap = {beauty:'💄',food:'🍜',fashion:'👗',health:'💪',other:'📦'};
  const cat = $('newCampCategory').value;
  const ch = $('newCampChannel').value;
  const existing = await fetchCampaigns();
  const minOrder = existing.length > 0 ? Math.min(...existing.map(c=>c.order_index||0)) : 0;
  // 이미지를 Storage에 업로드
  toast('이미지 업로드 중...','');
  const imgUrls = await uploadCampImages(campImgData);

  const camp = {
    title, brand, product,
    type: ch==='qoo10'?'qoo10':'nano', channel:ch, category:cat,
    recruit_type: recruitType,
    order_index: minOrder - 1,
    content_types: contentTypes,
    image_url: imgUrls[0],
    img1: imgUrls[0], img2: imgUrls[1],
    img3: imgUrls[2], img4: imgUrls[3],
    img5: imgUrls[4], img6: imgUrls[5],
    img7: imgUrls[6], img8: imgUrls[7],
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
    status:'draft'
  };

  await insertCampaign(camp);
  toast('캠페인이 등록되었습니다','success');
  campImgData.length = 0;
  renderImgPreview(campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');

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
      ${a.role !== 'super_admin' ? `<button class="btn btn-ghost btn-xs" style="color:#B3261E" data-email="${esc(a.email)}" onclick="deleteAdmin('${a.id}',this.dataset.email)">삭제</button>` : ''}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>';

  // 현재 로그인한 관리자 정보 로드
  currentAdminInfo = admins.find(a => a.auth_id === currentUser?.id) || null;
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
  $('adminFormPw').value = '';
  $('adminFormPwGroup').style.display = '';
  $('adminFormName').value = '';
  $('adminFormRole').value = 'campaign_admin';
  $('adminFormBtn').textContent = '추가';
  $('adminFormError').style.display = 'none';
  $('addAdminModal').classList.add('open');
}

function openEditAdmin(id, email, name, role) {
  $('addAdminModalTitle').textContent = '관리자 수정';
  $('editAdminId').value = id;
  $('adminFormEmail').value = email;
  $('adminFormEmail').disabled = true;
  $('adminFormPwGroup').style.display = 'none';
  $('adminFormName').value = name;
  $('adminFormRole').value = role;
  $('adminFormBtn').textContent = '저장';
  $('adminFormError').style.display = 'none';
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
    // 추가 모드
    const email = $('adminFormEmail').value.trim();
    const pw = $('adminFormPw').value;
    const name = $('adminFormName').value.trim();
    const role = $('adminFormRole').value;
    if (!email || !pw || !name) { err.textContent = '모든 항목을 입력해주세요'; err.style.display = 'block'; return; }
    if (pw.length < 8) { err.textContent = '비밀번호는 8자 이상이어야 합니다'; err.style.display = 'block'; return; }
    try {
      const {data, error} = await db.rpc('create_admin', {
        admin_email: email, admin_password: pw, admin_name: name, admin_role: role
      });
      if (error) throw error;
      toast('관리자가 추가되었습니다','success');
      closeModal('addAdminModal');
      loadAdminAccounts();
    } catch(e) {
      err.textContent = '추가 오류: ' + friendlyError(e.message); err.style.display = 'block';
    }
  }
}

async function deleteAdmin(id, email) {
  if (!confirm(`${email} 관리자를 삭제하시겠습니까?`)) return;
  try {
    await db.from('admins').delete().eq('id', id);
    toast('관리자가 삭제되었습니다','success');
    loadAdminAccounts();
  } catch(e) {
    toast('삭제 오류: ' + friendlyError(e.message),'error');
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
  const hasBank = users.filter(u => u.bank_name).length;

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
    bar('계좌', pct(hasBank), '#28C76F', false);
}
