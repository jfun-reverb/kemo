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
  initMultiFilters();
  document.querySelectorAll('.admin-pane').forEach(p=>p.classList.remove('on'));
  document.querySelectorAll('.admin-si').forEach(s=>s.classList.remove('on'));
  const paneEl = $('adminPane-'+pane);
  if (paneEl) paneEl.classList.add('on');
  // 캠페인 등록·편집 진입 시 flatpickr range/single picker mount (idempotent)
  if (pane === 'add-campaign' || pane === 'edit-campaign') {
    if (typeof setupCampRangePickers === 'function') setupCampRangePickers();
    if (typeof setupCampSinglePickers === 'function') setupCampSinglePickers();
  } else {
    // 다른 페인으로 전환 시 열린 picker 모두 닫기 (appendTo:body popup이 z:2000으로 잔존 방지)
    if (typeof _campRangePickers === 'object' && _campRangePickers) {
      Object.values(_campRangePickers).forEach(fp => { if (fp && fp.isOpen) fp.close(); });
    }
    if (typeof _campSinglePickers === 'object' && _campSinglePickers) {
      Object.values(_campSinglePickers).forEach(fp => { if (fp && fp.isOpen) fp.close(); });
    }
  }
  // 사이드바 활성 상태를 data-pane 속성으로 검색
  if (!el) {
    const sidePane = {'add-campaign':'campaigns','edit-campaign':'campaigns',
      'camp-applicants':'campaigns'}[pane] || pane;
    el = document.querySelector('.admin-si[data-pane="'+sidePane+'"]');
  }
  if (el) el.classList.add('on');
  const loaders = {
    dashboard: loadAdminData,
    applications: loadApplications,
    campaigns: loadAdminCampaigns,
    influencers: loadAdminInfluencers,
    'admin-accounts': loadAdminAccounts,
    'my-account': loadMyAdminInfo,
    'lookups': loadLookupsPane,
    'deliverables': loadDeliverables,
    'brand-applications': loadBrandApplications,
    'brand-dashboard': loadBrandDashboard,
    'admin-notices': loadAdminNotices
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
    renderContentTypeCheckboxes('new', [], 'monitor');
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
    renderCampBundleSummary('pset', 'new');
    // 주의사항 번들 초기화 (신규는 빈 상태 — 관리자가 번들 선택 후 불러옴)
    _csetState.new = [];
    populateCampCsetDropdown('new', 'monitor', null);
    renderCampCautionItems('new');
    renderCampBundleSummary('cset', 'new');
    setupCampPreview('new');
  }
  if (pane === 'edit-campaign') {
    setupCampPreview('edit');
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
  const {data} = await db?.from('admins').select('email');
  _adminEmails = (data||[]).map(a=>a.email);
}
function isAdminEmail(email) { return _adminEmails.includes(email); }
function adminBadge(email) { return isAdminEmail(email) ? ' <span style="background:var(--pink);color:#fff;font-size:9px;font-weight:700;padding:1px 6px;border-radius:4px;margin-left:4px">관리자</span>' : ''; }

var _multiFiltersInitialized = false;
function initMultiFilters() {
  if (_multiFiltersInitialized) return;
  _multiFiltersInitialized = true;
  // 캠페인관리
  createMultiFilter('campTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => filterAdminCampaigns());
  createMultiFilter('campStatusMulti', '전체 상태', [
    {value:'draft',label:'준비'},{value:'scheduled',label:'모집예정'},{value:'active',label:'모집중'},{value:'paused',label:'일시정지'},{value:'closed',label:'종료'}
  ], () => filterAdminCampaigns());
  // 신청관리
  createMultiFilter('appTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => renderAppCampList());
  createMultiFilter('appStatusMulti', '전체 상태', [
    {value:'pending',label:'심사중'},{value:'approved',label:'승인'},{value:'rejected',label:'미승인'}
  ], () => renderAppCampList());
  // 결과물관리
  createMultiFilter('delivKindMulti', '전체 타입', [
    {value:'receipt',label:'영수증'},{value:'post',label:'게시물 URL'}
  ], () => renderDeliverablesList());
  createMultiFilter('delivStatusMulti', '전체 상태', [
    {value:'pending',label:'검수 대기'},{value:'approved',label:'승인'},{value:'rejected',label:'반려'}
  ], () => renderDeliverablesList());
  // 광고주 신청
  createMultiFilter('brandAppFormMulti', '전체 폼', [
    {value:'reviewer',label:'Qoo10 리뷰어'},{value:'seeding',label:'나노 시딩'}
  ], () => renderBrandApplicationsList());
  createMultiFilter('brandAppStatusMulti', '전체 상태', [
    {value:'new',label:'신규'},{value:'reviewing',label:'검토중'},{value:'quoted',label:'견적 전달'},{value:'paid',label:'입금완료'},{value:'orient_sheet_sent',label:'오리엔시트 전달'},{value:'schedule_sent',label:'일정 전달'},{value:'campaign_registered',label:'캠페인 등록'},{value:'done',label:'최종완료'},{value:'rejected',label:'반려'}
  ], () => renderBrandApplicationsList());
}

async function loadAdminData(preloaded) {
  initMultiFilters();
  updateSidebarProfile();

  // 병렬 fetch — preloaded 있으면 재사용 (init에서 이미 가져온 경우)
  const fetches = preloaded
    ? Promise.resolve(preloaded)
    : Promise.all([fetchCampaigns(), fetchInfluencers(), fetchApplications()]);
  const adminEmailsPromise = (_adminEmails && _adminEmails.length) ? null : loadAdminEmails();
  const [camps, users, apps] = await fetches;
  if (adminEmailsPromise) await adminEmailsPromise;

  allCampaigns = camps.slice();
  // 관리자 초기 진입 시 위반 카운트도 미리 로드 — 배지 전역 노출용
  fetchViolationCountsByInfluencer().then(vc => { _infViolationCounts = vc; }).catch(()=>{});
  // 관리자 공지 — 사이드바 배지·대시보드 최근·로그인 팝업
  fetchAdminNotices().then(list => {
    _adminNoticesCache = list;
    refreshAdminNoticeBadge();
    renderDashboardNotices();
    if (!window._adminNoticeUnreadShown) {
      window._adminNoticeUnreadShown = true;
      showAdminUnreadNoticesIfAny();
    }
  }).catch(()=>{});
  const approved = apps.filter(a=>a.status==='approved');
  const pending = apps.filter(a=>a.status==='pending');

  $('kpiCampaigns').textContent = camps.length;
  $('kpiInfluencers').textContent = users.length;
  $('kpiApplications').textContent = apps.length;
  $('kpiApproved').textContent = approved.length;
  renderCampaignBreakdown(camps);
  // 목록 페인(loadAdminCampaigns/loadAdminInfluencers)은 해당 pane 진입 시에만 로드

  // 회원가입 차트 + KPI
  _allUsers = users;
  renderSignupKPIs(users);
  renderSignupChart(users, 30);
  renderProfileCompletion(users);
  // 배송지 분포(도도부현 Top N) — 이미 fetch한 users 재사용 (중복 쿼리 방지)
  renderAddressDistribution(users);
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length>999?'999+':pending.length}</span>`:''}`;
  refreshDelivSidebarBadge();

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
            <div>${typeLabel}</div>
            <strong style="font-size:13px;cursor:pointer" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
            ${camp.slots?`<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_dRem>0?'var(--green)':'var(--red)'};font-weight:600">${_dRem>0?_dRem+'건':'없음'}</span></div>`:''}
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${users.find(u=>u.email===a.user_email)?.id||''}')">${esc(a.user_name)||'—'}${influencerStatusBadges(users.find(u=>u.email===a.user_email)||{})}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)}</div>
      </td>
      <td>${msgCell(a.message, a)}</td>
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

// 신청 사유: 2줄 말줄임 + 더보기 모달
function msgCell(text, app) {
  const consent = app ? consentBadge(app) : '';
  if (!text) return consent || '—';
  const safe = esc(text);
  const short = `<div style="max-width:200px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-size:12px;color:var(--ink)">${safe}</div>`;
  const more = text.length > 40
    ? `<a href="javascript:void(0)" style="font-size:10px;color:var(--pink);text-decoration:underline;cursor:pointer" onclick="event.stopPropagation();openMsgModal(this)" data-msg="${safe}">더보기</a>`
    : '';
  return short + more + consent;
}
function openMsgModal(btn) {
  const msg = btn.dataset.msg;
  const el = $('alertModalMessage');
  if (el) el.innerHTML = `<div style="font-size:13px;line-height:1.7;white-space:pre-wrap;max-height:60vh;overflow-y:auto">${msg}</div>`;
  openModal('alertModal');
}

// ── 주의사항 동의 정보 (신청 행 배지 + 상세 모달) ──
const _cautionConsentCache = {};
function consentBadge(app) {
  if (!app || !app.caution_agreed_at) return '';
  _cautionConsentCache[app.id] = { agreed_at: app.caution_agreed_at, snapshot: app.caution_snapshot || null };
  const dt = formatDateTime(app.caution_agreed_at);
  return `<div style="margin-top:6px"><a href="javascript:void(0)" onclick="event.stopPropagation();openCautionConsentModal('${esc(app.id)}')" style="font-size:10px;color:var(--green);text-decoration:none;cursor:pointer;display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>주의사항 동의 ${esc(dt)}</a></div>`;
}
function openCautionConsentModal(appId) {
  const cached = _cautionConsentCache[appId];
  const el = $('alertModalMessage');
  if (!el) return;
  if (!cached) {
    el.innerHTML = `<div style="font-size:13px;color:var(--muted)">동의 정보를 불러올 수 없습니다</div>`;
    openModal('alertModal');
    return;
  }
  const snap = cached.snapshot;
  let html = `<div style="font-size:13px;line-height:1.7"><strong>동의 시각</strong> · ${esc(formatDateTime(cached.agreed_at))}</div>`;
  if (snap && typeof snap === 'object') {
    // v2 (migration 069 이후): items 배열 기반 스냅샷 — html_ko/html_ja 동시 렌더 (관리자 열람 목적)
    if (snap.version === 2 && Array.isArray(snap.items) && snap.items.length) {
      const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => String(h||''));
      html += `<div style="margin-top:12px"><strong style="font-size:13px">주의사항 (동의 시점 스냅샷)</strong><ul style="margin:6px 0 0 18px;padding:0;font-size:12px;line-height:1.8;display:flex;flex-direction:column;gap:4px">` +
        snap.items.map(it => {
          const ko = sanitize(it.html_ko || '');
          const ja = sanitize(it.html_ja || '');
          return `<li><div style="color:var(--ink)">${ko}</div><div style="color:var(--muted);font-size:11px;margin-top:1px">${ja}</div></li>`;
        }).join('') +
        `</ul></div>`;
    }
    // v1 (migration 067 — 2026-04-22 이전 신청): lookup_labels / custom_html 기반 — 하위 호환 뷰어
    else if (Array.isArray(snap.lookup_labels) && snap.lookup_labels.length) {
      html += `<div style="margin-top:12px"><strong style="font-size:13px">표준 주의사항 <span style="font-size:10px;color:var(--muted);font-weight:400">· v1 스냅샷</span></strong><ul style="margin:6px 0 0 18px;padding:0;font-size:12px;line-height:1.7">` +
        snap.lookup_labels.map(l => {
          const ko = esc(l.name_ko || l.ko || '');
          const ja = esc(l.name_ja || l.ja || '');
          return `<li style="margin:2px 0"><span style="color:var(--ink)">${ko}</span> <span style="color:var(--muted);font-size:11px">/ ${ja}</span></li>`;
        }).join('') +
        `</ul></div>`;
    }
    if (snap.version !== 2 && snap.custom_html) {
      const rendered = (typeof richHtml === 'function')
        ? richHtml(snap.custom_html)
        : esc(String(snap.custom_html || '')).replace(/\n/g, '<br>');
      html += `<div style="margin-top:12px"><strong style="font-size:13px">캠페인 고유 주의사항 <span style="font-size:10px;color:var(--muted);font-weight:400">· v1 스냅샷</span></strong><div style="margin-top:6px;padding:10px 12px;background:#fff5f5;border-left:3px solid var(--red);border-radius:6px;font-size:12px;line-height:1.7">${rendered}</div></div>`;
    }
    if (snap.agreed_lang) {
      const langLabel = snap.agreed_lang === 'ja' ? '日本語' : (snap.agreed_lang === 'ko' ? '한국어' : snap.agreed_lang);
      html += `<div style="margin-top:10px;color:var(--muted);font-size:11px">동의 시점 사용자 언어: ${esc(langLabel)}</div>`;
    }
  } else {
    html += `<div style="margin-top:10px;color:var(--muted);font-size:12px">동의 시점 스냅샷이 저장되지 않았습니다</div>`;
  }
  el.innerHTML = `<div style="max-height:60vh;overflow-y:auto">${html}</div>`;
  openModal('alertModal');
}

// 필터 select: 전체(all)가 아닌 값 선택 시 배경 흰색으로 활성 표시
function highlightFilter(el) {
  el.classList.toggle('active', el.value !== 'all');
}

// 테이블 wrap 높이를 화면에 맞춰 설정 → wrap 안에서만 스크롤
function updateTableScrollHeight(paneId) {
  setTimeout(() => {
    const pane = $(paneId);
    if (!pane) return;
    const wrap = pane.querySelector('.admin-table-wrap');
    if (!wrap) return;
    const rect = wrap.getBoundingClientRect();
    wrap.style.maxHeight = (window.innerHeight - rect.top - 16) + 'px';
    wrap.style.overflowY = 'auto';
  }, 0);
}

// 다중 필터 리셋
function resetMultiFilter(containerId, allLabel) {
  const wrap = $(containerId);
  if (!wrap) return;
  const btn = wrap.querySelector('.mf-btn');
  const allCb = wrap.querySelector('input[value="all"]');
  const items = wrap.querySelectorAll('.mf-drop input:not([value="all"])');
  if (allCb) allCb.checked = true;
  items.forEach(c => c.checked = false);
  if (btn) { btn.textContent = allLabel; btn.classList.remove('has-selection'); }
}
function updateFilterResetBtn(btnId, multiIds, searchId) {
  const btn = $(btnId);
  if (!btn) return;
  const hasMulti = multiIds.some(id => getMultiFilterValues(id).length > 0);
  const hasSearch = searchId && $(searchId)?.value?.trim();
  btn.style.display = (hasMulti || hasSearch) ? '' : 'none';
}
function resetCampFilters() {
  resetMultiFilter('campTypeMulti', '전체 타입');
  resetMultiFilter('campStatusMulti', '전체 상태');
  const s = $('adminCampSearch'); if (s) s.value = '';
  filterAdminCampaigns();
}
function resetAppFilters() {
  resetMultiFilter('appTypeMulti', '전체 타입');
  resetMultiFilter('appStatusMulti', '전체 상태');
  resetMultiFilter('appCampMulti', '전체 캠페인');
  const s = $('appSearch'); if (s) s.value = '';
  renderAppCampList();
}

// 다중 선택 드롭다운 공통 헬퍼 — 옵션 리스트 변화 시에만 재생성, 이전 선택 상태 보존
// options: [{value, label}]
function syncMultiFilter(containerId, allLabel, options, onChange) {
  const wrap = $(containerId);
  if (!wrap) return;
  const drop = wrap.querySelector('.mf-drop');
  if (!drop) return;
  const newKey = options.map(o => o.value).join('|');
  if (wrap.dataset.optKey === newKey && drop.children.length > 0) return;
  const prev = getMultiFilterValues(containerId);
  createMultiFilter(containerId, allLabel, options, onChange);
  wrap.dataset.optKey = newKey;
  if (prev.length > 0) {
    const allCb = drop.querySelector('input[value="all"]');
    let restored = 0;
    prev.forEach(v => {
      const cb = drop.querySelector(`input[value="${CSS && CSS.escape ? CSS.escape(v) : v.replace(/"/g,'\\"')}"]`);
      if (cb) { cb.checked = true; restored++; }
    });
    if (restored > 0 && allCb) {
      allCb.checked = false;
      const btn = wrap.querySelector('.mf-btn');
      const itemCbs = [...drop.querySelectorAll('input:not([value="all"])')];
      const selected = itemCbs.filter(c => c.checked);
      if (btn) {
        btn.textContent = selected.map(c => c.parentElement.textContent.trim()).join(', ');
        btn.classList.add('has-selection');
      }
    }
  }
}

// 캠페인 전용 래퍼 (label 포맷 `[CAMP-XXX] 제목`)
function syncCampMultiFilter(containerId, sortedCamps, onChange) {
  const options = sortedCamps.map(c => ({
    value: c.id,
    label: (c.campaign_no ? `[${c.campaign_no}] ` : '') + (c.title || '(제목 없음)')
  }));
  syncMultiFilter(containerId, '전체 캠페인', options, onChange);
}

// ── 다중 선택 드롭다운 필터 ──
function createMultiFilter(containerId, allLabel, options, onChange) {
  const wrap = $(containerId);
  if (!wrap) return;
  const btn = wrap.querySelector('.mf-btn');
  const drop = wrap.querySelector('.mf-drop');
  if (!btn || !drop) return;
  // 드롭다운 아이템 생성
  drop.innerHTML = `<label class="mf-item all-item"><input type="checkbox" value="all" checked> ${esc(allLabel)}</label>`
    + options.map(o => `<label class="mf-item"><input type="checkbox" value="${esc(o.value)}"> ${esc(o.label)}</label>`).join('');
  btn.textContent = allLabel;
  // 토글
  btn.onclick = (e) => { e.stopPropagation(); drop.classList.toggle('open'); };
  // 체크 로직
  const allCb = drop.querySelector('input[value="all"]');
  const itemCbs = [...drop.querySelectorAll('input:not([value="all"])')];
  const update = () => {
    const selected = itemCbs.filter(c => c.checked);
    if (selected.length === 0 || selected.length === itemCbs.length) {
      allCb.checked = true;
      itemCbs.forEach(c => c.checked = false);
      btn.textContent = allLabel;
      btn.classList.remove('has-selection');
    } else {
      allCb.checked = false;
      btn.textContent = selected.map(c => c.parentElement.textContent.trim()).join(', ');
      btn.classList.add('has-selection');
    }
    onChange(getMultiFilterValues(containerId));
  };
  allCb.onchange = () => {
    if (allCb.checked) { itemCbs.forEach(c => c.checked = false); }
    update();
  };
  itemCbs.forEach(c => { c.onchange = () => { if (c.checked) allCb.checked = false; update(); }; });
  // 바깥 클릭 닫기 (wrap 당 1회만 등록)
  if (!wrap._mfClickBound) {
    wrap._mfClickBound = true;
    document.addEventListener('click', (e) => { if (!wrap.contains(e.target)) drop.classList.remove('open'); });
  }
}
function getMultiFilterValues(containerId) {
  const wrap = $(containerId);
  if (!wrap) return [];
  const allCb = wrap.querySelector('input[value="all"]');
  if (allCb?.checked) return [];
  return [...wrap.querySelectorAll('.mf-drop input:checked')].map(c => c.value);
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



function updateCampTableHead() {
  const head = $('adminCampTableHead');
  if (!head) return;
  if (adminReorderMode) {
    head.innerHTML = `<tr><th>순서</th><th>캠페인</th><th>브랜드</th><th>제품</th><th>상태</th><th>조회</th><th>신청</th><th>등록일</th><th>수정일</th></tr>`;
  } else {
    head.innerHTML = `<tr>
      <th>캠페인</th>
      <th>브랜드</th>
      <th>제품</th>
      <th>상태 <span class="sort-arrows" data-sort="status" onclick="toggleCampSort('status')">${adminCampSortKey==='status'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>조회 <span class="sort-arrows" data-sort="views" onclick="toggleCampSort('views')">${adminCampSortKey==='views'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>신청 (신청/모집)(승인/대기) <span class="sort-arrows" data-sort="apps" onclick="toggleCampSort('apps')">${adminCampSortKey==='apps'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
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

var campsLazy = null;
const CAMPS_PAGE_SIZE = 50;

async function loadAdminCampaigns(useCache) {
  updateCampTableHead();
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

  // 타입 필터 (다중 선택)
  const typeVals = getMultiFilterValues('campTypeMulti');
  if (typeVals.length) camps = camps.filter(c => typeVals.includes(c.recruit_type));

  // 상태 필터 (다중 선택)
  const statusVals = getMultiFilterValues('campStatusMulti');
  if (statusVals.length) camps = camps.filter(c => statusVals.includes(c.status));

  // 검색 필터
  const searchVal = ($('adminCampSearch')?.value || '').trim().toLowerCase();
  if (searchVal) camps = camps.filter(c => (c.title||'').toLowerCase().includes(searchVal) || (c.brand||'').toLowerCase().includes(searchVal) || (c.campaign_no||'').toLowerCase().includes(searchVal));

  updateFilterResetBtn('btnCampFilterReset', ['campTypeMulti','campStatusMulti'], 'adminCampSearch');

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
  const isFiltered = searchVal || typeVals.length > 0 || statusVals.length > 0 || !!adminCampSortKey;

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
  const campsBody = $('adminCampsBody');
  if (!campsBody) return;
  const buildCampRow = (c, i, totalLen) => {
    const campApps = allApps.filter(a=>a.campaign_id===c.id);
    const approvedCnt = campApps.filter(a=>a.status==='approved').length;
    const pendingCnt = campApps.filter(a=>a.status==='pending').length;
    const pct = c.slots > 0 ? Math.round(approvedCnt/c.slots*100) : 0;
    const barColor = pct>=100?'var(--red)':pct>=60?'var(--gold)':'var(--green)';
    const imgs = [c.img1,c.img2,c.img3,c.img4,c.img5,c.img6,c.img7,c.img8,c.image_url].filter(Boolean).filter((v,idx,a)=>a.indexOf(v)===idx);
    const thumbUrl = imgs[0] || '';
    const imgCount = imgs.length;
    return `<tr data-camp-id="${c.id}" data-id="${esc(c.id)}">
      ${adminReorderMode ? `<td style="white-space:nowrap">
        <div style="display:flex;gap:3px">
          <button class="btn btn-ghost btn-xs" ${i===0?'disabled':''} onclick="moveCampOrder('${c.id}',-1)" style="padding:2px 6px;font-size:13px">↑</button>
          <button class="btn btn-ghost btn-xs" ${i===totalLen-1?'disabled':''} onclick="moveCampOrder('${c.id}',1)" style="padding:2px 6px;font-size:13px">↓</button>
        </div>
      </td>` : ''}
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:44px;height:44px;flex-shrink:0;border-radius:8px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? renderCroppedImg(thumbUrl, (c.image_crops||{}).img1, {thumb:160, lazy:true}) : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:20px">${esc(c.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:var(--muted)">inventory_2</span>'}</span>`}
            ${imgCount > 1 ? `<span style="position:absolute;bottom:0;left:0;background:rgba(0,0,0,.65);color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:0 4px 0 0">+${imgCount}</span>` : ''}
          </div>
          <div style="min-width:0">
            <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
              ${typeLabel(c.recruit_type)}
              ${c.campaign_no ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted);letter-spacing:0.02em">${esc(c.campaign_no)}</span>` : ''}
            </div>
            <strong style="cursor:pointer;color:var(--ink)" onclick="openCampPreviewModal('${c.id}')">${esc(c.title)}</strong>
            ${c.post_deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:1px">캠페인 노출: ~${formatDate(c.post_deadline)} ${dDayLabel(c.post_deadline)}</div>` : ''}
          </div>
        </div>
      </td>
      ${(()=>{
        const bp = c.brand_ko || c.brand || '';
        const bs = (c.brand_ko && c.brand && c.brand_ko !== c.brand) ? c.brand : '';
        const pp = c.product_ko || c.product || '';
        const ps = (c.product_ko && c.product && c.product_ko !== c.product) ? c.product : '';
        return `<td style="font-size:12px;color:var(--ink);min-width:100px">
          ${bp?esc(bp):'—'}
          ${bs?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(bs)}</div>`:''}
        </td>
        <td style="font-size:12px;color:var(--ink);min-width:120px">
          ${pp?esc(pp):'—'}
          ${ps?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(ps)}</div>`:''}
        </td>`;
      })()}
      <td>${statusBadge(c.status)}</td>
      <td style="font-size:13px;font-weight:600;color:var(--ink)">${(c.view_count||0).toLocaleString()}</td>
      <td>
        <div style="display:flex;align-items:center;gap:8px">
          <div style="width:48px;height:8px;background:var(--line);border-radius:4px;overflow:hidden">
            <div style="width:${Math.min(pct,100)}%;height:100%;background:${barColor};border-radius:4px"></div>
          </div>
          <button class="btn btn-ghost btn-xs" style="padding:2px 8px 4px;font-weight:700;color:${campApps.length>0?'var(--ink)':'var(--muted)'};border-color:var(--line)" data-camp-title="${esc(c.title)}" onclick="openCampApplicants('${c.id}',this.dataset.campTitle)">
            ${campApps.length} / ${c.slots}명
          </button>
          <span style="font-size:10px;font-weight:600;color:${approvedCnt>0?'var(--pink)':'var(--muted)'}">${approvedCnt}승인${pendingCnt>0?` · <span style="color:var(--gold)">${pendingCnt}대기</span>`:''}</span>
        </div>
        ${c.deadline ? `<div style="font-size:10px;color:var(--muted);margin-top:12px">마감: ${formatDate(c.deadline)} ${dDayLabel(c.deadline)}</div>` : ''}
      </td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDate(c.created_at)}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDateTime(c.updated_at||c.created_at)}</td>
      ${adminReorderMode ? '' : `<td style="position:relative">
        <span class="material-icons-round notranslate camp-more-btn" translate="no" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s" data-camp-title="${esc(c.title)}" onclick="toggleCampMoreMenu(event,this,'${c.id}',this.dataset.campTitle)">more_vert</span>
      </td>`}
    </tr>`;
  };
  const emptyHtml = `<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>`;
  if (adminReorderMode) {
    // 순서변경 모드: 전체 DOM 필요 (↑↓ 위치 인덱스 기반). lazy 비활성.
    if (campsLazy) { campsLazy.destroy(); campsLazy = null; }
    campsBody.innerHTML = camps.length ? camps.map((c, i) => buildCampRow(c, i, camps.length)).join('') : emptyHtml;
  } else {
    if (campsLazy) campsLazy.destroy();
    campsLazy = mountLazyList({
      tbody: campsBody,
      scrollRoot: campsBody.closest('.admin-table-wrap'),
      rows: camps,
      renderRow: (c) => buildCampRow(c, 0, camps.length),
      pageSize: CAMPS_PAGE_SIZE,
      emptyHtml,
    });
  }
}

// ── Quill 리치 텍스트 에디터 관리 ──
const RICH_EDITOR_IDS = ['editCampDesc','editCampAppeal','editCampGuide','editCampNg','newCampDesc','newCampAppeal','newCampGuide','newCampNg'];
const richEditors = {};

function getRichEditor(id) {
  if (richEditors[id]) return richEditors[id];
  const host = document.getElementById(id);
  if (!host || typeof Quill === 'undefined') return null;
  // Quill 기본 link tooltip 을 우리 커스텀 팝오버로 완전 대체하기 위해
  // toolbar.handlers.link 를 오버라이드. 링크 생성/Ctrl+K 경로 모두 이 handler 통과.
  let q;
  const linkHandler = function() {
    if (!q) return;
    const range = q.getSelection();
    if (!range || range.length === 0) { toast('링크로 만들 텍스트를 먼저 선택하세요','error'); return; }
    const url = prompt('링크 URL (https:// 또는 mailto:)', 'https://');
    if (!url) return;
    const clean = url.trim();
    if (!/^https?:\/\/|^mailto:/i.test(clean)) { toast('http/https/mailto URL 만 허용됩니다','error'); return; }
    q.format('link', clean);
    // target=_blank + rel 추가 (Quill Link Blot 기본값이 target 지정하지 않음)
    setTimeout(() => {
      q.root.querySelectorAll('a[href]').forEach(a => {
        if (a.getAttribute('href') === clean) {
          a.setAttribute('target', '_blank');
          a.setAttribute('rel', 'noopener noreferrer');
        }
      });
    }, 0);
  };
  q = new Quill(host, {
    theme: 'snow',
    modules: {
      toolbar: {
        container: [
          [{ 'header': [2, 3, 4, false] }],
          ['bold','italic','underline','strike'],
          [{ 'list': 'ordered' }, { 'list': 'bullet' }],
          ['link','blockquote'],
          ['clean']
        ],
        handlers: { link: linkHandler }
      },
      clipboard: { matchVisual: false }
    },
    formats: ['header','bold','italic','underline','strike','list','link','blockquote']
  });
  // 툴바+본문을 wrap 으로 감싸 미니 에디터와 같은 통합 박스 외관으로 전환
  const toolbar = q.getModule('toolbar')?.container;
  if (toolbar && toolbar.parentElement && !toolbar.parentElement.classList.contains('quill-wrap')) {
    const wrap = document.createElement('div');
    wrap.className = 'quill-wrap';
    host.parentElement.insertBefore(wrap, toolbar);
    wrap.appendChild(toolbar);
    wrap.appendChild(host);
  }
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
  // 캠페인 번호 배지 (CAMP-YYYY-NNNN)
  var noBadge = $('editCampNoBadge');
  if (noBadge) {
    if (camp.campaign_no) {
      noBadge.textContent = camp.campaign_no;
      noBadge.style.display = 'inline-block';
      noBadge.onclick = function() {
        try {
          navigator.clipboard.writeText(camp.campaign_no);
          toast(camp.campaign_no + ' 복사됨');
        } catch(e) {}
      };
    } else {
      noBadge.style.display = 'none';
    }
  }
  sv('editCampTitle', camp.title);
  sv('editCampBrand', camp.brand);
  sv('editCampBrandKo', camp.brand_ko || '');
  sv('editCampProduct', camp.product);
  sv('editCampProductKo', camp.product_ko || '');
  sv('editCampProductUrl', camp.product_url||'');
  sv('editCampSlots', camp.slots);
  sv('editCampProductPrice', camp.product_price||0);
  sv('editCampReward', camp.reward||0);
  sv('editCampRewardNote', camp.reward_note||'');
  sv('editCampPostDeadline', camp.post_deadline||'');
  sv('editCampSubmissionEnd', camp.submission_end||'');
  // flatpickr range picker mount + 값 주입 (모집·구매·방문 3개)
  setupCampRangePickers();
  applyCampRangeValues('editCamp', {
    recruit:  [camp.recruit_start || '', camp.deadline || ''],
    purchase: [camp.purchase_start || '', camp.purchase_end || ''],
    visit:    [camp.visit_start || '', camp.visit_end || ''],
  });
  // 일자 입력 min/max 동기화 + 인라인 경고 초기 평가
  syncCampDateMinMax('editCamp');
  validateCampDateRangesInline('editCamp');
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
    renderContentTypeCheckboxes('edit', selectedContent, rtVal),
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
  renderCampBundleSummary('pset', 'edit');

  // 주의사항 번들 복원 (migration 069 — 스냅샷 우선, 드롭다운은 recruit_type 필터)
  _csetState.edit = Array.isArray(camp.caution_items)
    ? camp.caution_items.map(normalizeCsetItem)
    : [];
  await populateCampCsetDropdown('edit', rtVal, camp.caution_set_id || null);
  renderCampCautionItems('edit');
  renderCampBundleSummary('cset', 'edit');

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

// 모집 종료일 입력 시 결과물 제출 마감일을 +14일로 자동 제안 (확인 모달)
async function suggestSubmissionEnd(prefix) {
  const dl = $(prefix+'Deadline')?.value;
  if (!dl) return;
  const target = new Date(dl);
  target.setDate(target.getDate() + 14);
  const yyyy = target.getFullYear();
  const mm = String(target.getMonth() + 1).padStart(2, '0');
  const dd = String(target.getDate()).padStart(2, '0');
  const suggested = `${yyyy}-${mm}-${dd}`;
  const seEl = $(prefix+'SubmissionEnd');
  if (!seEl || seEl.value === suggested) return;
  const ok = await showConfirm(`결과물 제출 마감일을 ${yyyy}년 ${mm}월 ${dd}일로 입력하시겠습니까?\n(모집 종료일 + 2주)`);
  if (ok) {
    seEl.value = suggested;
    syncCampDateMinMax(prefix);
    validateCampDateRangesInline(prefix);
  }
}

// 일자 자식 input들의 min/max 를 운영 흐름에 맞춰 동기화 (브라우저 단 차단)
//   구매·방문: [recruit_start||deadline] ~ [submission_end || post_deadline]
//   결과물 제출 마감일: max(recruit_start||deadline, purchase_end, visit_end) ~ post_deadline
//   캠페인 노출 마감일: deadline ~ (없음)
function syncCampDateMinMax(prefix) {
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const pdl = $(prefix+'PostDeadline')?.value || '';
  const pe = $(prefix+'PurchaseEnd')?.value || '';
  const ve = $(prefix+'VisitEnd')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const lower = rs || dl || '';
  const upperPV = se || pdl || '';
  // 구매·방문: lower ~ upperPV
  ['PurchaseStart','PurchaseEnd','VisitStart','VisitEnd'].forEach(suffix => {
    const el = $(prefix+suffix);
    if (!el) return;
    if (lower) el.min = lower; else el.removeAttribute('min');
    if (upperPV) el.max = upperPV; else el.removeAttribute('max');
  });
  // 결과물 제출 마감일: 구매·방문 종료일 이후 (없으면 lower) ~ 캠페인 노출 마감일
  const seEl = $(prefix+'SubmissionEnd');
  if (seEl) {
    const seLower = [lower, pe, ve].filter(Boolean).sort().pop() || '';
    if (seLower) seEl.min = seLower; else seEl.removeAttribute('min');
    if (pdl) seEl.max = pdl; else seEl.removeAttribute('max');
  }
  // 캠페인 노출 마감일: 결과물 제출 마감일(우선) 또는 모집 종료일 이후
  const postEl = $(prefix+'PostDeadline');
  if (postEl) {
    const postLower = se || dl || '';
    if (postLower) postEl.min = postLower; else postEl.removeAttribute('min');
    postEl.removeAttribute('max');
  }
  // flatpickr range picker (구매·방문) 도 같은 경계로 비활성 날짜 처리
  if (typeof syncCampRangePickerBounds === 'function') syncCampRangePickerBounds(prefix);
  // 단일 picker(SubmissionEnd / PostDeadline) 비활성 날짜 동기화
  // flatpickr.set('minDate', ...) 는 selectedDates를 재검증하면서 input.value를
  // selectedDates 기준으로 덮어쓸 수 있음 → 호출 직전에 input.value ↔ selectedDates 동기화 필수
  if (typeof _campSinglePickers === 'object' && _campSinglePickers) {
    const _syncFpToInput = (fp, val) => {
      if (!fp) return;
      const cur = fp.selectedDates && fp.selectedDates[0] ? _fpFormatYmd(fp.selectedDates[0]) : '';
      if (val && cur !== val) fp.setDate(val, false);
      else if (!val && cur) fp.clear(false);
    };
    const seFp = _campSinglePickers[prefix + 'SubmissionEnd'];
    if (seFp) {
      _syncFpToInput(seFp, $(prefix+'SubmissionEnd')?.value || '');
      const seLower = [lower, pe, ve].filter(Boolean).sort().pop() || '';
      seFp.set('minDate', seLower || null);
      seFp.set('maxDate', pdl || null);
    }
    const postFp = _campSinglePickers[prefix + 'PostDeadline'];
    if (postFp) {
      _syncFpToInput(postFp, $(prefix+'PostDeadline')?.value || '');
      const postLower = se || dl || '';
      postFp.set('minDate', postLower || null);
      postFp.set('maxDate', null);
    }
  }
}

// flatpickr range picker 의 minDate/maxDate 를 hidden input 값에 맞춰 동적 갱신
//   구매·방문: [recruit_start || deadline] ~ [submission_end || post_deadline]
//   모집: 제한 없음 (관리자가 자유 입력)
function syncCampRangePickerBounds(prefix) {
  if (!_campRangePickers) return;
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const pdl = $(prefix+'PostDeadline')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const lower = rs || dl || '';
  const upperPV = se || pdl || '';
  ['Purchase', 'Visit'].forEach(kind => {
    const fp = _campRangePickers[prefix + kind + 'Range'];
    if (!fp) return;
    fp.set('minDate', lower || null);
    fp.set('maxDate', upperPV || null);
  });
}

// 입력값 검증 (저장 시 + onchange 인라인 경고). 위반 메시지 배열 반환.
//   경계: 모집 시작일 ~ 캠페인 노출 마감일 사이
function validateCampDateRanges(prefix) {
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const pdl = $(prefix+'PostDeadline')?.value || '';
  const ps = $(prefix+'PurchaseStart')?.value || '';
  const pe = $(prefix+'PurchaseEnd')?.value || '';
  const vs = $(prefix+'VisitStart')?.value || '';
  const ve = $(prefix+'VisitEnd')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const errs = [];
  const lower = rs || dl || '';
  const between = (val) => {
    if (!val) return true;
    if (lower && new Date(val) < new Date(lower)) return false;
    if (pdl && new Date(val) > new Date(pdl)) return false;
    return true;
  };
  // 구매·방문 일자의 상한은 결과물 제출 마감일(우선) 또는 캠페인 노출 마감일(폴백)
  const upperPV = se || pdl || '';
  const inPVRange = (val) => {
    if (!val) return true;
    if (lower && new Date(val) < new Date(lower)) return false;
    if (upperPV && new Date(val) > new Date(upperPV)) return false;
    return true;
  };
  const upperPVLabel = se ? '결과물 제출 마감일' : '캠페인 노출 마감일';
  if (rs && dl && new Date(dl) < new Date(rs)) errs.push({kind:'recruit', msg:'모집 종료일은 모집 시작일 이후여야 합니다'});
  if (dl && pdl && new Date(pdl) < new Date(dl)) errs.push({kind:'post', msg:'캠페인 노출 마감일은 모집 종료일 이후여야 합니다'});
  if (se && pdl && new Date(pdl) < new Date(se)) errs.push({kind:'post', msg:'캠페인 노출 마감일은 결과물 제출 마감일 이후여야 합니다'});
  if (!inPVRange(ps)) errs.push({kind:'purchase', msg:`구매 시작일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (!inPVRange(pe)) errs.push({kind:'purchase', msg:`구매 마감일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (ps && pe && new Date(pe) < new Date(ps)) errs.push({kind:'purchase', msg:'구매 마감일은 구매 시작일 이후여야 합니다'});
  if (!inPVRange(vs)) errs.push({kind:'visit', msg:`방문 시작일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (!inPVRange(ve)) errs.push({kind:'visit', msg:`방문 마감일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (vs && ve && new Date(ve) < new Date(vs)) errs.push({kind:'visit', msg:'방문 마감일은 방문 시작일 이후여야 합니다'});
  // 결과물 제출 마감일: 모집 시작 ~ 캠페인 노출 마감 사이 + 구매·방문 종료일 이후
  if (se && lower && new Date(se) < new Date(lower)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 모집 시작일 이후여야 합니다'});
  if (se && pdl && new Date(se) > new Date(pdl)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 캠페인 노출 마감일 이전이어야 합니다'});
  if (se && pe && new Date(se) < new Date(pe)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 구매 종료일 이후여야 합니다'});
  if (se && ve && new Date(se) < new Date(ve)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 방문 종료일 이후여야 합니다'});
  return errs;
}

// 종류별 row 아래 div 매핑 — 한 row에 여러 위반이 있으면 같은 div에 누적 표시
const CAMP_DATE_WARN_TARGETS = {
  recruit:    'RecruitWarn',
  post:       'PostDeadlineWarn',
  purchase:   'PurchaseWarn',
  visit:      'VisitWarn',
  submission: 'SubmissionWarn',
};

// ─────────────────────────────────────────────────────────────────
// flatpickr range picker 통합 (모집·구매·방문 3개 영역)
//   - input[data-range-prefix][data-range-kind] 마크업을 mount 대상으로 사용
//   - hidden start/end input 두 개에 값을 동기화 (저장 로직은 hidden ID 그대로)
//   - 모집 종료일 변경 시 결과물 제출 마감일 자동 제안 + min/max 갱신 + 인라인 검증
// ─────────────────────────────────────────────────────────────────
const _campRangePickers = Object.create(null);
const _campSinglePickers = Object.create(null);
const RANGE_KIND_HIDDEN_IDS = {
  recruit:  ['RecruitStart', 'Deadline'],
  purchase: ['PurchaseStart', 'PurchaseEnd'],
  visit:    ['VisitStart', 'VisitEnd'],
};

// flatpickr 캘린더 popup 하단에 추가하는 인라인 경고 div를 1회만 생성·재사용
// (경고는 푸터보다 먼저 append되어야 시각적으로 푸터 위에 위치)
function _ensureFpWarnNode(fp) {
  if (fp && fp._reverbWarnNode) return fp._reverbWarnNode;
  if (!fp || !fp.calendarContainer) return null;
  const node = document.createElement('div');
  node.className = 'fp-past-warn';
  node.style.cssText = 'display:none;padding:8px 12px;font-size:11px;font-weight:600;color:#C62828;background:#FFEBEE;border-top:1px solid #FFCDD2;text-align:center;line-height:1.5';
  // 푸터가 이미 있으면 그 앞에 삽입
  const footer = fp._reverbFooterNode;
  if (footer && footer.parentNode === fp.calendarContainer) {
    fp.calendarContainer.insertBefore(node, footer);
  } else {
    fp.calendarContainer.appendChild(node);
  }
  fp._reverbWarnNode = node;
  return node;
}

// 캘린더 popup 하단 커스텀 푸터: 좌 「YYYY-MM-DD ~ YYYY-MM-DD (N일)」 요약 + 우 「초기화 / 적용」
// 「초기화」 = popup 안 선택만 비움 (hidden input·검증·minMax 그대로, 적용 누르기 전까지 미반영)
// 「적용」    = 현재 selectedDates 를 hidden input에 반영 + 검증 + minMax + close
//               (외부 클릭으로 popup 닫히면 hidden input 그대로 → 사용자가 의도적으로 적용 눌러야만 변경)
function _ensureFpFooterNode(fp) {
  if (fp && fp._reverbFooterNode) return fp._reverbFooterNode;
  if (!fp || !fp.calendarContainer) return null;
  const node = document.createElement('div');
  node.className = 'fp-custom-footer';
  node.innerHTML =
    '<div class="fp-footer-summary">날짜를 선택하세요</div>' +
    '<div class="fp-footer-actions">' +
      '<button type="button" class="fp-btn-clear">초기화</button>' +
      '<button type="button" class="fp-btn-apply">적용</button>' +
    '</div>';
  fp.calendarContainer.appendChild(node);
  fp._reverbFooterNode = node;
  const clearBtn = node.querySelector('.fp-btn-clear');
  const applyBtn = node.querySelector('.fp-btn-apply');
  if (clearBtn) {
    clearBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // popup 안의 시각 선택만 비움. hidden input은 「적용」 누르기 전까지 변경 안 됨.
      fp.clear();
      // popup 유지 — close() 호출 안 함
    });
  }
  if (applyBtn) {
    applyBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // range는 시작일·종료일 둘 다 선택돼야 적용 가능 (시작일만으로 hidden input 부분 저장 차단)
      const dates = fp.selectedDates || [];
      if (!dates[0] || !dates[1]) {
        if (typeof toast === 'function') toast('시작일과 종료일을 모두 선택해주세요','error');
        return;
      }
      _commitFpRangeToHiddenInputs(fp);
      fp.close();
    });
  }
  return node;
}

// 「적용」 클릭 시 selectedDates를 hidden input에 반영하고 검증/minMax/제안 일괄 실행.
// fp._reverbMeta = {prefix, kind, startSuffix, endSuffix} 가 setupCampRangePickers에서 부착돼 있어야 함.
function _commitFpRangeToHiddenInputs(fp) {
  const meta = fp && fp._reverbMeta;
  if (!meta) return;
  const {prefix, kind, startSuffix, endSuffix} = meta;
  const dates = (fp.selectedDates) || [];
  const start = dates[0] || null;
  const end   = dates[1] || null;
  const startEl = $(prefix + startSuffix);
  const endEl   = $(prefix + endSuffix);
  if (startEl) startEl.value = _fpFormatYmd(start);
  if (endEl)   endEl.value   = _fpFormatYmd(end);
  if (kind === 'recruit') {
    updateRecruitPastWarn(fp, start);
    if (end) suggestSubmissionEnd(prefix);
  }
  syncCampDateMinMax(prefix);
  validateCampDateRangesInline(prefix);
}

// 푸터 요약 텍스트 동기화 (selectedDates 기반)
function _updateFpFooterSummary(fp) {
  const node = fp && fp._reverbFooterNode;
  if (!node) return;
  const summary = node.querySelector('.fp-footer-summary');
  if (!summary) return;
  const dates = (fp.selectedDates) || [];
  const start = dates[0];
  const end = dates[1];
  if (!start) {
    summary.textContent = '날짜를 선택하세요';
    summary.classList.remove('has-range');
    return;
  }
  const s = _fpFormatYmd(start);
  if (!end) {
    summary.textContent = s + ' ~ (종료일 선택)';
    summary.classList.remove('has-range');
    return;
  }
  const e = _fpFormatYmd(end);
  // 포함식 일수 (시작일·종료일 같은 날이면 1일)
  const MS_PER_DAY = 86400000;
  const diffDays = Math.round((end - start) / MS_PER_DAY) + 1;
  summary.textContent = s + ' ~ ' + e + ' (' + diffDays + '일)';
  summary.classList.add('has-range');
}

// ─────────────────────────────────────────────────────────────────
// 단일 날짜 picker (결과물 제출 마감일 / 캠페인 노출 마감일)
//   - input.fp-single[data-single-prefix][data-single-target] 마크업 mount
//   - input value를 직접 사용 (별도 hidden input 없음)
//   - 「초기화」 = popup 안 선택만 비움 (input value는 「적용」 시까지 그대로)
//   - 「적용」    = selectedDates → input.value 반영 + syncCampDateMinMax + validateCampDateRangesInline + close
// ─────────────────────────────────────────────────────────────────
function setupCampSinglePickers() {
  if (typeof flatpickr === 'undefined') return;
  const els = document.querySelectorAll('input.fp-single[data-single-prefix]');
  els.forEach(el => {
    const id = el.id;
    if (_campSinglePickers[id]) return;
    const prefix = el.dataset.singlePrefix;
    const target = el.dataset.singleTarget;
    if (!prefix || !target) return;
    _campSinglePickers[id] = flatpickr(el, {
      mode: 'single',
      dateFormat: 'Y-m-d',
      altInput: false,
      locale: (typeof flatpickr !== 'undefined' && flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
      showMonths: 1,
      static: false,
      appendTo: document.body,
      position: 'auto',
      closeOnSelect: false,
      onReady: (_sel, _str, fpInst) => {
        if (fpInst.calendarContainer) {
          fpInst.calendarContainer.classList.add('reverb-range-cal');
          fpInst.calendarContainer.classList.add('reverb-single-cal');
        }
        fpInst._reverbSingleMeta = {prefix, target};
        _ensureFpSingleFooterNode(fpInst);
        _updateFpSingleFooterSummary(fpInst);
      },
      onOpen: (_selectedDates, _str, fpInst) => {
        // 다른 picker(range·single 모두) 자동 close
        Object.values(_campRangePickers).forEach(otherFp => { if (otherFp && otherFp !== fpInst && otherFp.isOpen) otherFp.close(); });
        Object.values(_campSinglePickers).forEach(otherFp => { if (otherFp && otherFp !== fpInst && otherFp.isOpen) otherFp.close(); });
        // 외부에서 input.value 직접 변경됐을 수 있으니 popup state 동기화
        const v = el.value || '';
        if (v) fpInst.setDate(v, false);
        else fpInst.clear(false);
        // input value 비어있고 minDate 있으면 minDate 월로 점프 (today 기준 4월에 모든 날짜 회색으로 보이는 혼란 방지)
        if (!v) {
          const mn = fpInst.config && fpInst.config.minDate;
          if (mn) fpInst.jumpToDate(mn);
        }
        _updateFpSingleFooterSummary(fpInst);
      },
      onChange: (_selectedDates, _str, fpInst) => {
        // popup 안 시각·푸터 요약만 (input.value는 「적용」 시 commit)
        _updateFpSingleFooterSummary(fpInst);
      },
      onClose: (_sel, _str, fpInst) => {
        // 외부 클릭으로 닫혔을 때 input.value 기준 popup state 복원
        const v = el.value || '';
        if (v) fpInst.setDate(v, false);
        else fpInst.clear(false);
        _updateFpSingleFooterSummary(fpInst);
      },
    });
  });
}

// 단일 picker 푸터 (요약 + 초기화/적용)
function _ensureFpSingleFooterNode(fp) {
  if (fp && fp._reverbFooterNode) return fp._reverbFooterNode;
  if (!fp || !fp.calendarContainer) return null;
  const node = document.createElement('div');
  node.className = 'fp-custom-footer';
  node.innerHTML =
    '<div class="fp-footer-summary">날짜를 선택하세요</div>' +
    '<div class="fp-footer-actions">' +
      '<button type="button" class="fp-btn-clear">초기화</button>' +
      '<button type="button" class="fp-btn-apply">적용</button>' +
    '</div>';
  fp.calendarContainer.appendChild(node);
  fp._reverbFooterNode = node;
  const clearBtn = node.querySelector('.fp-btn-clear');
  const applyBtn = node.querySelector('.fp-btn-apply');
  if (clearBtn) {
    clearBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // popup 안 시각 선택만 비움. input.value는 「적용」 누르기 전까지 그대로 유지.
      // (fp.clear()는 input.value까지 자동으로 비우므로 호출 전후로 input.value 백업·복원 필요)
      const savedValue = fp.input ? fp.input.value : '';
      fp.clear(false);
      if (fp.input) fp.input.value = savedValue;
      _updateFpSingleFooterSummary(fp);
    });
  }
  if (applyBtn) {
    applyBtn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      _commitFpSingleToInput(fp);
      fp.close();
    });
  }
  return node;
}

function _updateFpSingleFooterSummary(fp) {
  const node = fp && fp._reverbFooterNode;
  if (!node) return;
  const summary = node.querySelector('.fp-footer-summary');
  if (!summary) return;
  const dates = (fp.selectedDates) || [];
  if (!dates[0]) {
    summary.textContent = '날짜를 선택하세요';
    summary.classList.remove('has-range');
    return;
  }
  summary.textContent = _fpFormatYmd(dates[0]);
  summary.classList.add('has-range');
}

function _commitFpSingleToInput(fp) {
  const meta = fp && fp._reverbSingleMeta;
  if (!meta) return;
  const {prefix, target} = meta;
  const dates = (fp.selectedDates) || [];
  const v = _fpFormatYmd(dates[0] || null);
  const el = $(prefix + target);
  if (el) el.value = v;
  syncCampDateMinMax(prefix);
  validateCampDateRangesInline(prefix);
}
// 모집 시작일이 오늘 이전이면 캘린더 popup 하단에 빨간 글씨 표시 (차단·모달 닫힘 없음)
function updateRecruitPastWarn(fp, startDate) {
  const node = _ensureFpWarnNode(fp);
  if (!node) return;
  if (!startDate) { node.style.display = 'none'; return; }
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const start = new Date(startDate); start.setHours(0, 0, 0, 0);
  if (start < today) {
    node.textContent = '모집 시작일이 오늘보다 이전입니다. 과거 날짜로 등록하는 것이 맞는지 확인해주세요.';
    node.style.display = 'block';
  } else {
    node.style.display = 'none';
  }
}
function _fpFormatYmd(d) {
  if (!d) return '';
  const yyyy = d.getFullYear();
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  return `${yyyy}-${mm}-${dd}`;
}
function setupCampRangePickers() {
  if (typeof flatpickr === 'undefined') return; // CDN 로드 실패 fallback (text input 그대로)
  const els = document.querySelectorAll('input.fp-range[data-range-prefix]');
  els.forEach(el => {
    const id = el.id;
    if (_campRangePickers[id]) return; // 이미 mount
    const prefix = el.dataset.rangePrefix;
    const kind   = el.dataset.rangeKind;
    const [startSuffix, endSuffix] = RANGE_KIND_HIDDEN_IDS[kind] || [];
    if (!startSuffix || !endSuffix) return;
    _campRangePickers[id] = flatpickr(el, {
      mode: 'range',
      dateFormat: 'Y-m-d',
      altInput: false,
      locale: (typeof flatpickr !== 'undefined' && flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
      showMonths: 2,           // 좌(현재월) + 우(다음월) 2개월 동시 노출
      static: false,           // body에 floating으로 mount — form-group(절반 폭) 잘림 방지
      appendTo: document.body, // 모달 z-index 위로 띄우기 위해 body에 직접 append
      position: 'auto',        // input 기준 자동 위치 (above/below)
      closeOnSelect: false,    // 종료일 클릭 후에도 popup 유지 — 「적용」 누를 때만 close + 반영
      onReady: (_sel, _str, fpInst) => {
        // 캠페인 폼 전용 스타일 스코핑
        if (fpInst.calendarContainer) fpInst.calendarContainer.classList.add('reverb-range-cal');
        // 「적용」 버튼 핸들러에서 사용할 메타데이터 부착 (1회)
        fpInst._reverbMeta = {prefix, kind, startSuffix, endSuffix};
        // 푸터(요약 + 초기화/적용) 1회 주입 + 초기 요약 텍스트 세팅
        _ensureFpFooterNode(fpInst);
        _updateFpFooterSummary(fpInst);
      },
      onOpen: (_selectedDates, _str, fpInst) => {
        // 한 picker가 열릴 때 같은 폼의 다른 picker는 닫음
        // (appendTo:body 모드라 flatpickr가 자동 close 처리하지 않음)
        Object.values(_campRangePickers).forEach(otherFp => {
          if (otherFp && otherFp !== fpInst && otherFp.isOpen) otherFp.close();
        });
        Object.values(_campSinglePickers).forEach(otherFp => {
          if (otherFp && otherFp !== fpInst && otherFp.isOpen) otherFp.close();
        });
        // 첫 표시 월을 「선택 가능한 월」로 이동
        //   - hidden input에 값이 있으면 그 월
        //   - 없고 minDate 있으면 minDate 월 (today 기준 회색만 가득한 혼란 방지)
        const sv = $(prefix + startSuffix)?.value || '';
        if (sv) fpInst.jumpToDate(sv);
        else {
          const mn = fpInst.config && fpInst.config.minDate;
          if (mn) fpInst.jumpToDate(mn);
        }
        // 외부에서 hidden input 직접 변경됐을 수 있으니 푸터 요약 재동기화
        _updateFpFooterSummary(fpInst);
        if (kind !== 'recruit') return;
        // 캘린더 열릴 때마다 현재 hidden input의 시작일을 기준으로 경고 평가
        updateRecruitPastWarn(fpInst, sv ? new Date(sv) : null);
      },
      // popup 안의 시각 피드백만 갱신 (hidden input은 「적용」 클릭 시까지 그대로)
      onChange: (selectedDates, _str, fpInst) => {
        if (kind === 'recruit') {
          updateRecruitPastWarn(fpInst, selectedDates[0] || null);
        }
        _updateFpFooterSummary(fpInst);
      },
      // popup 닫힐 때 hidden input 기준으로 popup state 복원
      // (「초기화」 후 외부 클릭으로 닫혔을 때 다음 열림 시 기존 값 보이도록)
      onClose: (_sel, _str, fpInst) => {
        const sv = $(prefix + startSuffix)?.value || '';
        const ev = $(prefix + endSuffix)?.value || '';
        if (sv && ev) fpInst.setDate([sv, ev], false);
        else if (sv) fpInst.setDate([sv], false);
        else fpInst.clear(false);
        _updateFpFooterSummary(fpInst);
      },
    });
  });
}
// 편집 모달 열림·신규 폼 진입 시 외부에서 setDate 로 값 주입 (또는 클리어)
function applyCampRangeValues(prefix, values) {
  // values = { recruit:[start,end], purchase:[start,end], visit:[start,end] }
  Object.keys(RANGE_KIND_HIDDEN_IDS).forEach(kind => {
    const id = prefix + (kind === 'recruit' ? 'RecruitRange' : kind === 'purchase' ? 'PurchaseRange' : 'VisitRange');
    const fp = _campRangePickers[id];
    const pair = (values && values[kind]) || [null, null];
    const [s, e] = pair;
    const [startSuffix, endSuffix] = RANGE_KIND_HIDDEN_IDS[kind];
    if ($(prefix + startSuffix)) $(prefix + startSuffix).value = s || '';
    if ($(prefix + endSuffix))   $(prefix + endSuffix).value   = e || '';
    if (fp) {
      if (s && e) fp.setDate([s, e], false);
      else if (s) fp.setDate([s], false);
      else fp.clear(false);
      // setDate는 triggerChange=false라 onChange가 안 불려 푸터가 stale → 명시적으로 동기화
      if (typeof _updateFpFooterSummary === 'function') _updateFpFooterSummary(fp);
    }
  });
}

// onchange 인라인 경고 — 종류별로 분산해서 해당 row 바로 아래 div 에 출력 (저장 차단은 별도 체크)
function validateCampDateRangesInline(prefix) {
  const errs = validateCampDateRanges(prefix);
  const groups = Object.create(null);
  Object.keys(CAMP_DATE_WARN_TARGETS).forEach(k => { groups[k] = []; });
  errs.forEach(e => { if (groups[e.kind]) groups[e.kind].push(e.msg); });
  Object.keys(CAMP_DATE_WARN_TARGETS).forEach(k => {
    const div = $(prefix + CAMP_DATE_WARN_TARGETS[k]);
    if (!div) return;
    const list = groups[k];
    if (!list || list.length === 0) {
      div.style.display = 'none';
      div.textContent = '';
    } else {
      div.innerHTML = list.map(m => `· ${esc(m)}`).join('<br>');
      div.style.display = 'block';
    }
  });
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
      toast('캠페인 노출 마감일은 모집 종료일 이후여야 합니다','error');
      return;
    }
    const editDateErrs = validateCampDateRanges('editCamp');
    if (editDateErrs.length) { toast(editDateErrs[0].msg, 'error'); validateCampDateRangesInline('editCamp'); return; }
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
      brand_ko: gv('editCampBrandKo')?.trim() || null,
      product: gv('editCampProduct'),
      product_ko: gv('editCampProductKo')?.trim() || null,
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
      reward_note: gv('editCampRewardNote') || null,
      recruit_start: gv('editCampRecruitStart')||null,
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
      // 067 legacy 컬럼은 더 이상 갱신하지 않음 (070 마이그레이션에서 DROP 예정)
      status: gv('editCampStatus'),
      ...collectCampPsetPayload('edit'),
      ...collectCampCsetPayload('edit'),
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
      brand: src.brand, brand_ko: src.brand_ko || null,
      product: src.product, product_ko: src.product_ko || null,
      product_url: src.product_url,
      type: src.type, channel: src.channel, channel_match: src.channel_match || 'or', min_followers: src.min_followers||0, category: src.category,
      recruit_type: src.recruit_type, content_types: src.content_types,
      emoji: src.emoji, description: src.description,
      hashtags: src.hashtags, mentions: src.mentions,
      appeal: src.appeal, guide: src.guide, ng: src.ng,
      // 주의사항 번들 스냅샷도 함께 복제 (번들 원본은 참조만, items는 deep copy)
      caution_set_id: src.caution_set_id || null,
      caution_items: Array.isArray(src.caution_items) ? JSON.parse(JSON.stringify(src.caution_items)) : [],
      product_price: src.product_price, reward: src.reward, reward_note: src.reward_note,
      slots: src.slots, applied_count: 0,
      recruit_start: src.recruit_start, deadline: src.deadline, post_deadline: src.post_deadline, post_days: src.post_days,
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
    if (db) await db?.from('applications').delete().eq('campaign_id', campId);
    if (db) {
      var result = await db?.from('campaigns').delete().eq('id', campId);
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

// ── 캠페인 폼 실시간 미리보기 (add/edit 사이드 패널 iframe) ──

// 폼 입력값 → 가짜 camp 객체 (인플루언서 상세 렌더용)
function buildPreviewCamp(mode) {
  const g = mode === 'edit' ? 'editCamp' : 'newCamp';
  const chName = mode === 'edit' ? 'editChannel' : 'newChannel';
  const ctName = mode === 'edit' ? 'editContentType' : 'contentType';
  const rtName = mode === 'edit' ? 'editRecruitType' : 'recruitType';
  const cmName = mode === 'edit' ? 'editChannelMatch' : 'newChannelMatch';
  const val = id => document.getElementById(id)?.value || '';
  const channels = Array.from(document.querySelectorAll(`input[name="${chName}"]:checked`)).map(cb => cb.value);
  const contentTypes = Array.from(document.querySelectorAll(`input[name="${ctName}"]:checked`)).map(cb => cb.value);
  const recruitType = document.querySelector(`input[name="${rtName}"]:checked`)?.value || 'monitor';
  const channelMatch = document.querySelector(`input[name="${cmName}"]:checked`)?.value || 'or';
  // edit/add 모두 {data: url} shape (campImgData는 업로드 직후 {data, file} 구조, editCampImgData는 복원 시 {data: url})
  const imgList = mode === 'edit'
    ? (typeof editCampImgData !== 'undefined' ? editCampImgData : [])
    : (typeof campImgData !== 'undefined' ? campImgData : []);
  const imgUrls = imgList.map(x => x?.url || x?.data || x).filter(Boolean);
  const crops = (typeof buildImageCrops === 'function') ? buildImageCrops(imgList) : {};
  const pset = (typeof collectCampPsetPayload === 'function') ? collectCampPsetPayload(mode) : {};
  return {
    id: '__preview__',
    title: val(g+'Title') || '(캠페인명)',
    brand: val(g+'Brand') || '(브랜드)',
    product: val(g+'Product'),
    product_url: val(g+'ProductUrl'),
    product_price: parseInt(val(g+'ProductPrice'))||0,
    reward: parseInt(val(g+'Reward'))||0,
    reward_note: val(g+'RewardNote') || null,
    recruit_type: recruitType,
    channel: channels.join(','),
    channel_match: channelMatch,
    content_types: contentTypes.join(','),
    category: val(g+'Category'),
    slots: parseInt(val(g+'Slots'))||10,
    min_followers: parseInt(val(g+'MinFollowers'))||0,
    primary_channel: val(g+'PrimaryChannel')||null,
    recruit_start: val(g+'RecruitStart')||null,
    deadline: val(g+'Deadline')||null,
    post_deadline: val(g+'PostDeadline')||null,
    purchase_start: val(g+'PurchaseStart')||null,
    purchase_end: val(g+'PurchaseEnd')||null,
    visit_start: val(g+'VisitStart')||null,
    visit_end: val(g+'VisitEnd')||null,
    submission_end: val(g+'SubmissionEnd')||null,
    winner_announce: val(g+'WinnerAnnounce')||'',
    description: typeof getRichValue === 'function' ? getRichValue(g+'Desc') : '',
    appeal: typeof getRichValue === 'function' ? getRichValue(g+'Appeal') : '',
    guide: typeof getRichValue === 'function' ? getRichValue(g+'Guide') : '',
    ng: typeof getRichValue === 'function' ? getRichValue(g+'Ng') : '',
    hashtags: val(g+'Hashtags'),
    mentions: val(g+'Mentions'),
    image_url: imgUrls[0]||null,
    img1: imgUrls[0]||null, img2: imgUrls[1]||null, img3: imgUrls[2]||null, img4: imgUrls[3]||null,
    img5: imgUrls[4]||null, img6: imgUrls[5]||null, img7: imgUrls[6]||null, img8: imgUrls[7]||null,
    image_crops: crops,
    status: mode === 'edit' ? (val('editCampStatus') || 'active') : 'active',
    applied_count: 0,
    view_count: 0,
    created_at: new Date().toISOString(),
    ...pset,
  };
}

// 캠페인 폼 미리보기 — 우측 패널에 간소화된 카드를 직접 렌더
const _previewState = {new: null, edit: null};

function renderCampPreview(mode) {
  const el = document.getElementById(mode === 'edit' ? 'editCampPreviewContent' : 'newCampPreviewContent');
  if (!el) return;
  let camp;
  try { camp = buildPreviewCamp(mode); }
  catch(e) { console.warn('[preview] buildPreviewCamp 실패:', e); return; }

  const hasAnyValue = camp.title || camp.brand || camp.product || camp.img1 || camp.product_price > 0 || camp.reward > 0 || camp.reward_note;
  if (!hasAnyValue) { el.innerHTML = ''; return; }

  // 이미지 슬라이드 목록 (중복 제거) — 상세 페이지와 동일한 구성
  const imgCandidates = [camp.img1, camp.img2, camp.img3, camp.img4, camp.img5, camp.img6, camp.img7, camp.img8, camp.image_url].filter(Boolean);
  const _seen = new Set();
  const slideUrls = imgCandidates.filter(u => _seen.has(u) ? false : (_seen.add(u), true));
  const img = slideUrls[0] || '';
  const rtLabel = camp.recruit_type === 'monitor' ? 'レビュアー' : camp.recruit_type === 'gifting' ? 'ギフティング' : camp.recruit_type === 'visit' ? '訪問型' : '';
  const rtBadgeMap = {
    monitor: {bg:'var(--blue-l)', color:'var(--blue)', label:'Reviewer'},
    gifting: {bg:'var(--gold-l)', color:'var(--gold)', label:'Gifting'},
    visit:   {bg:'#E8F7EF', color:'#0E7E4A', label:'Visit'}
  };
  const rtBadge = rtBadgeMap[camp.recruit_type];
  const channelCodes = (camp.channel||'').split(',').map(s=>s.trim()).filter(Boolean);
  const channelNames = channelCodes.map(c => (typeof getChannelLabel === 'function' ? getChannelLabel(c) : c));
  const chSep = camp.channel_match === 'and' ? '&' : 'or';
  const contentTypeCodes = (camp.content_types||'').split(',').map(s=>s.trim()).filter(Boolean);
  const contentTypeNames = contentTypeCodes.map(c => (typeof getLookupLabel === 'function' ? getLookupLabel('content_type', c) : c));
  const richFn = (typeof richHtml === 'function') ? richHtml : (s => esc(s).replace(/\n/g,'<br>'));
  const fmt = v => v ? (typeof formatDate === 'function' ? formatDate(v) : v) : '—';
  const rewardText = (camp.product_price>0 || camp.reward>0)
    ? `${camp.product_price>0?`¥${camp.product_price.toLocaleString()} 円相当の製品を無償提供`:'商品無償提供'}${camp.reward>0?` + ¥${camp.reward.toLocaleString()} 報酬`:''}`
    : '';

  // 참여방법 (스냅샷 > legacy)
  const legacySteps = [
    {title_ja:'応募フォームを提出', desc_ja:'当選された方には当選日にLINEにてご連絡いたします。'},
    {title_ja:'製品を使用してSNSにレビューを投稿', desc_ja:'① 投稿ガイドを確認 ② SNSにレビューを投稿'},
    {title_ja:'LINEで投稿リンクを送る', desc_ja:'SNSの投稿リンクをコピーして、LINEで送信してください。'}
  ];
  const steps = (Array.isArray(camp.participation_steps) && camp.participation_steps.length) ? camp.participation_steps : legacySteps;

  el.innerHTML = `
    <div class="cp-frame">
      <div class="cp-gnb">
        <div class="cp-gnb-logo">Reverb</div>
        <div class="cp-gnb-badge">プレビュー</div>
      </div>
      <div class="cp-body-scroll">
        <div class="cp-hero">
          ${img?(typeof renderCroppedImg==='function'?renderCroppedImg(img,null,{thumb:480,quality:80}):`<img src="${esc(img)}" style="width:100%;height:100%;object-fit:contain;display:block;background:#f5f5f5">`):'<span style="color:rgba(255,255,255,.7)">画像なし</span>'}
          ${contentTypeNames.length?`<div class="cp-hero-ct">${contentTypeNames.map(n=>`<span class="cp-hero-ct-chip">${esc(n)}</span>`).join('')}</div>`:''}
          ${slideUrls.length>1?`<div class="cp-hero-count">1/${slideUrls.length}</div>`:''}
        </div>
        <div class="cp-head">
          ${camp.brand?`<div class="cp-brand">${esc(camp.brand)}</div>`:''}
          ${rtLabel?`<div class="cp-rt">${esc(rtLabel)}</div>`:''}
          <div class="cp-title">${esc(camp.title||'(캠페인명)')}</div>
          ${camp.product_price>0?`<div class="cp-price-box"><span class="cp-price-amount">¥${camp.product_price.toLocaleString()}</span><span class="cp-price-label">円相当の製品を無償提供</span></div>`:''}
          ${camp.reward>0?`<div class="cp-reward-cash">+ ¥${camp.reward.toLocaleString()} 報酬</div>`:''}
        </div>
        <div class="cp-info">
          <div class="cp-info-row"><div class="cp-info-key">製品名</div><div class="cp-info-val">${esc(camp.product||'—')}</div></div>
          <div class="cp-info-row"><div class="cp-info-key">募集タイプ</div><div class="cp-info-val">${rtBadge?`<span class="cp-rt-badge" style="background:${rtBadge.bg};color:${rtBadge.color}">${rtBadge.label}</span>`:'—'}</div></div>
          ${channelNames.length?`<div class="cp-info-row"><div class="cp-info-key">チャンネル</div><div class="cp-info-val"><div class="cp-chips">${channelNames.map((n,i)=>(i>0?`<span class="cp-chip-sep">${chSep}</span>`:'')+`<span class="cp-chip">${esc(n)}</span>`).join('')}</div></div></div>`:''}
          ${contentTypeNames.length?`<div class="cp-info-row"><div class="cp-info-key">コンテンツ種類</div><div class="cp-info-val"><div class="cp-chips">${contentTypeNames.map(n=>`<span class="cp-chip cp-chip-sm">${esc(n)}</span>`).join('')}</div></div></div>`:''}
          <div class="cp-info-row"><div class="cp-info-key">募集期間</div><div class="cp-info-val">${fmt(camp.recruit_start || new Date())} 〜 ${fmt(camp.deadline)}</div></div>
          ${camp.slots?`<div class="cp-info-row"><div class="cp-info-key">募集人数</div><div class="cp-info-val">${camp.slots}名</div></div>`:''}
          ${camp.min_followers?`<div class="cp-info-row"><div class="cp-info-key">最小フォロワー</div><div class="cp-info-val">${camp.min_followers.toLocaleString()}</div></div>`:''}
          <div class="cp-info-row"><div class="cp-info-key">当選発表</div><div class="cp-info-val">${esc(camp.winner_announce||'選考後、LINEにてご連絡')}</div></div>
          ${(camp.recruit_type==='monitor'&&(camp.purchase_start||camp.purchase_end))?`<div class="cp-info-row"><div class="cp-info-key">購入期間</div><div class="cp-info-val">${fmt(camp.purchase_start)} 〜 ${fmt(camp.purchase_end)}</div></div>`:''}
          ${(camp.recruit_type==='visit'&&(camp.visit_start||camp.visit_end))?`<div class="cp-info-row"><div class="cp-info-key">訪問期間</div><div class="cp-info-val">${fmt(camp.visit_start)} 〜 ${fmt(camp.visit_end)}</div></div>`:''}
          ${camp.submission_end?`<div class="cp-info-row"><div class="cp-info-key">提出締切</div><div class="cp-info-val" style="font-weight:600">${fmt(camp.submission_end)}</div></div>`:''}
          ${(rewardText||camp.reward_note)?`<div class="cp-info-row"><div class="cp-info-key">報酬</div><div class="cp-info-val cp-info-val-pink">${rewardText?esc(rewardText):''}${camp.reward_note?`<div style="margin-top:${rewardText?'6px':'0'};font-size:11px;color:var(--muted);font-weight:400;line-height:1.6;white-space:pre-wrap">${esc(camp.reward_note)}</div>`:''}</div></div>`:''}
        </div>
        <div class="cp-participation">
          <div class="cp-section-heading">参加方法</div>
          ${steps.map((s,i)=>{
            const title = s.title_ja || s.title_ko || '';
            const desc = s.desc_ja || s.desc_ko || '';
            return `<div class="cp-step"><div class="cp-step-num">STEP ${i+1}</div><div><div class="cp-step-title">${esc(title)}</div>${desc?`<div class="cp-step-desc">${esc(desc)}</div>`:''}</div></div>`;
          }).join('')}
        </div>
        ${camp.product_url?`<div class="cp-product-link"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">shopping_bag</span> 商品ページ</div>`:''}
        ${camp.description?`<div class="cp-sec"><div class="cp-section-heading">キャンペーン説明</div><div class="cp-sec-desc-body rich-content">${richFn(camp.description)}</div></div>`:''}
        ${(camp.appeal||camp.hashtags||camp.mentions)?`<div class="cp-sec"><div class="cp-section-heading">投稿ガイドライン</div>
          ${camp.appeal?`<div style="margin-bottom:12px"><div class="cp-sec-subtitle">ブランドアピール</div><div class="cp-sec-body cp-sec-bg-pink rich-content">${richFn(camp.appeal)}</div></div>`:''}
          ${camp.hashtags?`<div style="margin-bottom:10px"><div class="cp-sec-subtitle">必須ハッシュタグ</div><div class="cp-chips">${camp.hashtags.split(',').filter(Boolean).map(t=>`<span class="cp-chip">${esc(t.trim())}</span>`).join('')}</div></div>`:''}
          ${camp.mentions?`<div><div class="cp-sec-subtitle">必須メンション</div><div class="cp-chips">${camp.mentions.split(',').filter(Boolean).map(t=>`<span class="cp-chip cp-chip-mention">${esc(t.trim())}</span>`).join('')}</div></div>`:''}
        </div>`:''}
        ${camp.guide?`<div class="cp-sec"><div class="cp-section-heading">撮影ガイド</div><div class="cp-sec-body cp-sec-bg-guide rich-content">${richFn(camp.guide)}</div></div>`:''}
        ${camp.ng?`<div class="cp-sec"><div class="cp-section-heading">NG事項</div><div class="cp-sec-body cp-sec-bg-ng rich-content">${richFn(camp.ng)}</div></div>`:''}
        ${(Array.isArray(camp.caution_items) && camp.caution_items.length) ? (() => {
          const s = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => String(h||''));
          const lis = camp.caution_items.map(it => `<li>${s(it.html_ja || it.html_ko || '')}</li>`).join('');
          return `<div class="cp-sec"><div class="cp-section-heading">注意事項</div><ul class="cp-sec-body" style="margin:0;padding-left:16px;display:flex;flex-direction:column;gap:4px;line-height:1.65">${lis}</ul></div>`;
        })() : ''}
      </div>
      <div class="cp-cta">
        <div class="cp-cta-name">${esc(camp.title||'—')}<small>${camp.product_price>0?`¥${camp.product_price.toLocaleString()} 円相当の製品を無償提供`:''}</small></div>
        <div class="cp-cta-btn">応募</div>
      </div>
    </div>`;
}

function setupCampPreview(mode) {
  const pane = document.getElementById(mode === 'edit' ? 'adminPane-edit-campaign' : 'adminPane-add-campaign');
  if (!pane) return;
  const st = _previewState[mode];
  if (st?.attached) { renderCampPreview(mode); return; }
  const entry = {attached: true, timer: null};
  entry.render = function() { renderCampPreview(mode); };
  entry.debounced = function() {
    clearTimeout(entry.timer);
    entry.timer = setTimeout(entry.render, 100);
  };
  pane.addEventListener('input', entry.debounced);
  pane.addEventListener('change', entry.debounced);
  window.addEventListener('reverb:campFormChange', entry.debounced);
  // Quill text-change 훅 (lazy init retry)
  (function tryHookQuill(retries) {
    const g = mode === 'edit' ? 'editCamp' : 'newCamp';
    let allHooked = true;
    ['Desc','Appeal','Guide','Ng'].forEach(function(k) {
      // lazy init 보장: 아직 생성 전이면 즉시 초기화
      const quill = richEditors[g + k] || getRichEditor(g + k);
      if (quill && !quill.__previewHooked) {
        quill.on('text-change', entry.debounced);
        quill.__previewHooked = true;
      } else if (!quill) allHooked = false;
    });
    if (!allHooked && retries > 0) setTimeout(function(){tryHookQuill(retries-1);}, 300);
  })(5);
  _previewState[mode] = entry;
  renderCampPreview(mode);
}

// 미리보기 패널 접기/펼치기
function toggleCampPreviewPane(mode) {
  const pane = document.getElementById(mode === 'edit' ? 'editCampPreviewPane' : 'newCampPreviewPane');
  if (pane) pane.classList.toggle('collapsed');
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
    <div class="camp-more-item" onclick="openEditCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">edit</span>편집</div>
    <div class="camp-more-item" onclick="duplicateCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">content_copy</span>복제</div>
    <div class="camp-more-item" onclick="exportCampaignDeliverables('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>결과물 엑셀</div>
    <div class="camp-more-item" onclick="exportCampaignApplicationsExcel('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>신청자 엑셀</div>
    <div class="camp-more-item camp-more-danger" data-camp-title="${esc(campTitle)}" onclick="deleteCampaign('${campId}',this.dataset.campTitle)"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">delete</span>삭제</div>
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

var campApplicantsLazy = null;
const CAMP_APPLICANTS_PAGE_SIZE = 50;

async function loadCampApplicants() {
  const filter = $('campAppFilterStatus')?.value || '';
  const searchQ = ($('campAppSearch')?.value || '').trim().toLowerCase();
  let apps = await fetchApplications({campaign_id: currentCampApplicantId});
  const total = apps.length;
  const allApproved = apps.filter(a => a.status === 'approved').length;
  if (filter) apps = apps.filter(a=>a.status===filter);
  if (searchQ) {
    const users = await fetchInfluencers();
    apps = apps.filter(a => {
      const u = users.find(x => x.email === a.user_email) || {};
      const bag = [
        a.user_name, a.user_email,
        u.name_kanji, u.name, u.name_kana,
        a.ig_id, a.user_ig,
        u.ig, u.x, u.tiktok, u.youtube,
      ].filter(Boolean).join(' ').toLowerCase();
      return bag.includes(searchQ);
    });
  }
  const approved = apps.filter(a=>a.status==='approved').length;
  const pending = apps.filter(a=>a.status==='pending').length;

  const camp = allCampaigns.find(c=>c.id===currentCampApplicantId);
  const slots = camp?.slots || 0;
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
  const body = $('campApplicantsBody');
  if (!body) return;
  const snsCell = (channel, raw) => {
    const handle = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, raw) : (raw || '').replace(/^@/,'').trim();
    if (!handle) return '—';
    const safe = esc(handle);
    const url = (typeof snsProfileUrl === 'function') ? snsProfileUrl(channel, handle) : '';
    const inner = url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${safe}</a>` : `@${safe}`;
    return `<div style="max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${safe}">${inner}</div>`;
  };
  const renderCampApplicantRow = (a) => {
    const _u = _users.find(u=>u.email===a.user_email)||{};
    const igF = (_u.ig_followers||0).toLocaleString();
    const xF  = (_u.x_followers||0).toLocaleString();
    const ttF = (_u.tiktok_followers||0).toLocaleString();
    const ytF = (_u.youtube_followers||0).toLocaleString();
    const totalF = ((_u.ig_followers||0)+(_u.x_followers||0)+(_u.tiktok_followers||0)+(_u.youtube_followers||0)).toLocaleString();
    const otCell = renderOtCell(a, isPostType);
    const delivCell = renderDelivCell(delivByApp[a.id] || [], a.status, selectedChannels, channelMatch, isPostType);
    return `<tr data-id="${esc(a.id)}">
    <td>
      <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${adminBadge(a.user_email)}${influencerStatusBadges(_u)}</div>
      <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${_u.line_id?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(_u.line_id)}</div>`:''}
    </td>
    <td>${snsCell('instagram', _u.ig || a.ig_id || a.user_ig)}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
    <td>${snsCell('x', _u.x)}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
    <td>${snsCell('tiktok', _u.tiktok)}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
    <td>${snsCell('youtube', _u.youtube)}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
    <td style="font-weight:700;color:var(--pink)">${totalF}</td>
    <td>${msgCell(a.message, a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadgeKo(a.status)}</td>
    <td>${otCell}</td>
    <td>${delivCell}</td>
    <td style="white-space:nowrap">
      ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${remaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
      :`<div><div style="font-size:10px;color:var(--muted)">${esc(a.reviewed_by||'')} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
    </td>
  </tr>`;
  };
  if (campApplicantsLazy) campApplicantsLazy.destroy();
  campApplicantsLazy = mountLazyList({
    tbody: body,
    scrollRoot: body.closest('.admin-table-wrap'),
    rows: apps,
    renderRow: renderCampApplicantRow,
    pageSize: CAMP_APPLICANTS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="12" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>',
  });
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

var infUsersCache = null;
var _infViolationCounts = {};

async function loadAdminInfluencers() {
  const [users, violations] = await Promise.all([
    fetchInfluencers(),
    fetchViolationCountsByInfluencer(),
  ]);
  infUsersCache = users;
  _infViolationCounts = violations;
  renderInfluencersPane(infUsersCache);
}

function rerenderInfluencersFromCache() {
  if (!infUsersCache) { loadAdminInfluencers(); return; }
  renderInfluencersPane(infUsersCache);
}

function renderInfluencersPane(users) {
  const verifiedSel = $('infFilterVerifiedSelect')?.value || 'all';
  const violationSel = $('infFilterViolationSelect')?.value || 'all';
  const searchQ = ($('infSearch')?.value || '').trim().toLowerCase();
  const matchSearch = (u) => {
    if (!searchQ) return true;
    const bag = [
      u.name_kanji, u.name, u.name_kana, u.email,
      u.ig, u.x, u.tiktok, u.youtube,
    ].filter(Boolean).join(' ').toLowerCase();
    return bag.includes(searchQ);
  };
  const filtered = users.filter(u => {
    if (verifiedSel === 'verified' && !u.is_verified) return false;
    if (verifiedSel === 'unverified' && u.is_verified) return false;
    const vc = (_infViolationCounts && _infViolationCounts[u.id]) || 0;
    if (violationSel === 'clean' && (vc > 0 || u.is_blacklisted)) return false;
    if (violationSel === 'has' && vc === 0 && !u.is_blacklisted) return false;
    if (violationSel === 'blacklist' && !u.is_blacklisted) return false;
    if (!matchSearch(u)) return false;
    return true;
  });
  const totalEl = $('infTotalCount');
  if (totalEl) totalEl.textContent = `${filtered.length}명 표시 (전체 ${users.length}명)`;
  const resetBtn = $('btnInfFilterReset');
  const anyActive = (verifiedSel !== 'all' || violationSel !== 'all' || currentInfTab !== 'all' || !!searchQ);
  if (resetBtn) resetBtn.style.display = anyActive ? '' : 'none';
  renderInfTable(filtered, currentInfTab);
}

function resetInfluencerFilters() {
  const v = $('infFilterVerifiedSelect'); if (v) v.value = 'all';
  const w = $('infFilterViolationSelect'); if (w) w.value = 'all';
  const c = $('infChannelFilter'); if (c) c.value = 'all';
  const s = $('infSearch'); if (s) s.value = '';
  currentInfTab = 'all';
  rerenderInfluencersFromCache();
}

function switchInfTabFromSelect(ch) {
  currentInfTab = ch || 'all';
  rerenderInfluencersFromCache();
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
  rerenderInfluencersFromCache();
}

function resetInfSort() {
  infSortKey = 'created';
  infSortDir = 'desc';
  updateInfSortUI();
  rerenderInfluencersFromCache();
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
    paypal: u => u.paypal_email ? 1 : 0,
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

var infLazy = null;
const INF_PAGE_SIZE = 80;

// 인증/위반/블랙 상태 배지 (목록용)
// - 블랙리스트: 블랙 배지만 표시 (위반·인증 숨김)
// - 외: 인증(있을 때) + 위반 N건 (항상)
function influencerStatusBadges(u) {
  if (u.is_blacklisted) {
    return `<span title="블랙리스트" style="display:inline-flex;align-items:center;gap:2px;background:#FFEBEE;color:#C62828;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">block</span>블랙리스트</span>`;
  }
  const parts = [];
  if (u.is_verified) {
    parts.push(`<span title="인증됨" style="display:inline-flex;align-items:center;gap:2px;background:#E3F2FD;color:#1565C0;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">verified</span>인증</span>`);
  }
  const vc = (_infViolationCounts && _infViolationCounts[u.id]) || 0;
  if (vc > 0) {
    parts.push(`<span title="위반 기록 ${vc}건" style="display:inline-flex;align-items:center;gap:2px;background:#F5F5F5;color:#616161;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">report</span>위반 ${vc}</span>`);
  }
  return parts.join('');
}

function buildInfRowAll(u) {
  const igF = (u.ig_followers||0).toLocaleString();
  const xF = (u.x_followers||0).toLocaleString();
  const ttF = (u.tiktok_followers||0).toLocaleString();
  const ytF = (u.youtube_followers||0).toLocaleString();
  const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)).toLocaleString();
  const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
  const paypalBadge = u.paypal_email ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
  const snsCell = (channel, raw) => {
    const handle = extractSnsHandle(channel, raw);
    if (!handle) return '—';
    const safe = esc(handle);
    const url = snsProfileUrl(channel, handle);
    const inner = url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${safe}</a>` : `@${safe}`;
    return `<div style="max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${safe}">${inner}</div>`;
  };
  const ellip = (s, w=140) => `<div style="max-width:${w}px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(s||'')}">${esc(s)||'—'}</div>`;
  return `<tr data-id="${esc(u.id)}"${u.is_blacklisted?' style="opacity:.55"':''}>
    <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerDetail('${u.id}')">${esc(u.name_kanji||u.name)||'—'}${adminBadge(u.email)}${influencerStatusBadges(u)}</div><div style="font-size:11px;color:var(--muted)">${esc(u.email)}</div></td>
    <td>${snsCell('instagram', u.ig)}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
    <td>${snsCell('x', u.x)}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
    <td>${snsCell('tiktok', u.tiktok)}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
    <td>${snsCell('youtube', u.youtube)}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
    <td style="font-weight:700;color:var(--pink)">${total}</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(u.line_id, 120)}</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(addr, 160)}</td>
    <td>${paypalBadge}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
  </tr>`;
}

function buildInfRowChannel(u, ch, idKey, fKey) {
  const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : u.address||'—';
  const paypalBadge = u.paypal_email ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
  const idVal = extractSnsHandle(ch, u[idKey]);
  const idUrl = snsProfileUrl(ch, idVal);
  const idCell = idVal
    ? `<div style="max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(idVal)}">${idUrl ? `<a href="${idUrl}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${esc(idVal)}</a>` : `@${esc(idVal)}`}</div>`
    : '—';
  const ellip = (s, w=140) => `<div style="max-width:${w}px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(s||'')}">${esc(s)||'—'}</div>`;
  return `<tr data-id="${esc(u.id)}"${u.is_blacklisted?' style="opacity:.55"':''}>
    <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerDetail('${u.id}')">${esc(u.name_kanji||u.name)||'—'}${adminBadge(u.email)}${influencerStatusBadges(u)}</div><div style="font-size:11px;color:var(--muted)">${esc(u.email)}</div></td>
    <td>${idCell}</td>
    <td style="font-weight:700;color:var(--pink)">${(u[fKey]||0).toLocaleString()}명</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(u.line_id, 120)}</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(addr, 160)}</td>
    <td>${paypalBadge}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
  </tr>`;
}

function renderInfTable(users, ch) {
  const titleEl = $('infTableTitle');
  const headEl = $('infTableHead');
  const bodyEl = $('adminInfluencersBody');
  if (!bodyEl) return;

  let filtered = users;
  let renderRow;
  let colspan;

  if (ch === 'all') {
    if (titleEl) titleEl.textContent = '인플루언서 전체';
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${infSortTh('Instagram','ig')}</th><th>${infSortTh('X(Twitter)','x')}</th><th>${infSortTh('TikTok','tiktok')}</th><th>${infSortTh('YouTube','youtube')}</th><th>${infSortTh('합계','total')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('PayPal','paypal')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = sortInfUsers(filtered);
    renderRow = buildInfRowAll;
    colspan = 10;
  } else {
    const chLabel = {instagram:'Instagram',x:'X(Twitter)',tiktok:'TikTok',youtube:'YouTube'}[ch];
    const fKey = {instagram:'ig_followers',x:'x_followers',tiktok:'tiktok_followers',youtube:'youtube_followers'}[ch];
    const idKey = {instagram:'ig',x:'x',tiktok:'tiktok',youtube:'youtube'}[ch];
    if (titleEl) titleEl.textContent = `${chLabel} 등록자`;
    filtered = users.filter(u => u[fKey] > 0);
    if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${chLabel} ID</th><th>${infSortTh('팔로워','followers')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('PayPal','paypal')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
    filtered = infSortKey ? sortInfUsers(filtered) : filtered.sort((a,b)=>(b[fKey]||0)-(a[fKey]||0));
    renderRow = (u) => buildInfRowChannel(u, ch, idKey, fKey);
    colspan = 7;
  }

  const scrollRoot = bodyEl.closest('.admin-table-wrap');
  const emptyHtml = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>`;
  if (infLazy) infLazy.destroy();
  infLazy = mountLazyList({
    tbody: bodyEl,
    scrollRoot,
    rows: filtered,
    renderRow,
    pageSize: INF_PAGE_SIZE,
    emptyHtml,
  });
}

// ── 인플루언서 상세 ──
async function openInfluencerDetail(userId) {
  const users = await fetchInfluencers();
  const u = users.find(x => x.id === userId);
  if (!u) { toast('인플루언서를 찾을 수 없습니다','error'); return; }

  $('infDetailTitle').innerHTML = esc(u.name_kanji || u.name || u.email) + adminBadge(u.email) + influencerStatusBadges(u);

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
  const snsRow = (label, channel, raw, followers) => {
    const handle = extractSnsHandle(channel, raw);
    const url = snsProfileUrl(channel, handle);
    const idHtml = handle
      ? (url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink);text-decoration:none">@${esc(handle)}</a>` : `@${esc(handle)}`)
      : '—';
    return `<div style="display:flex;align-items:center;padding:10px 0;border-bottom:1px solid var(--surface-dim,var(--bg));gap:12px">
      <div style="font-size:12px;font-weight:600;color:var(--muted);width:80px;flex-shrink:0">${label}</div>
      <div style="flex:1;font-size:13px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(handle||'')}">${idHtml}</div>
      <div style="font-size:13px;font-weight:700;color:var(--pink)">${(followers||0).toLocaleString()}명</div>
    </div>`;
  };
  const totalF = (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0);
  $('infDetailSns').innerHTML =
    snsRow('Instagram', 'instagram', u.ig, u.ig_followers) +
    snsRow('X (Twitter)', 'x', u.x, u.x_followers) +
    snsRow('TikTok', 'tiktok', u.tiktok, u.tiktok_followers) +
    snsRow('YouTube', 'youtube', u.youtube, u.youtube_followers) +
    `<div style="display:flex;align-items:center;padding:12px 0;gap:12px"><div style="font-size:12px;font-weight:700;color:var(--ink);width:80px">총 팔로워</div><div style="font-size:18px;font-weight:800;color:var(--pink)">${totalF.toLocaleString()}명</div></div>`;

  // 연락처
  $('infDetailContact').innerHTML =
    row('LINE ID', u.line_id) +
    row('전화번호', formatPhoneDisplay(u.phone));

  // 배송지
  const fullAddr = u.zip ? `〒${u.zip} ${u.prefecture||''}${u.city||''}${u.building?' '+u.building:''}` : u.address;
  $('infDetailAddress').innerHTML =
    row('우편번호', u.zip) +
    row('도도부현', u.prefecture) +
    row('시구정촌', u.city) +
    row('건물명', u.building) +
    row('전체 주소', fullAddr);

  // PayPal — row() 내에서 esc() 처리됨
  $('infDetailPaypal').innerHTML = u.paypal_email
    ? row('PayPal 이메일', u.paypal_email)
    : '<div style="text-align:center;color:var(--muted);padding:16px;font-size:13px">PayPal 미등록</div>';

  // 상태 관리 (인증 / 위반 관리 · 관리자 이력 포함)
  await renderInfluencerStatusPanel(u);
  renderInfluencerFlagsPanel(u.id);

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

  openModal('influencerFullDetailModal');
}

// 상태 관리 패널 — 인증 토글 + 블랙리스트 등록/해제 + 사유 입력
var _currentDetailInfluencer = null;
var _blacklistReasonsCache = null;
var _violationReasonsCache = null;
// 증빙 파일: 등록 폼 ({file, previewUrl}[]) / 편집 모달 ({file, previewUrl}[] + keptPaths[])
var _pendingFlagFiles = [];
var _editingKeptPaths = [];
var _editingNewFiles = [];

function onFlagFileInput(input, targetList) {
  const arr = targetList === 'editing' ? _editingNewFiles : _pendingFlagFiles;
  [...input.files].forEach(f => {
    const url = f.type && f.type.startsWith('image/') ? URL.createObjectURL(f) : null;
    arr.push({file: f, previewUrl: url});
  });
  input.value = '';
  if (targetList === 'editing') renderEditingFilePreview();
  else renderFlagFilePreview();
}

function fileChipHtml(item, idx, targetList) {
  const thumb = item.previewUrl
    ? `<img src="${esc(item.previewUrl)}" style="width:48px;height:48px;object-fit:cover;border-radius:4px" onclick="openImageLightbox('${esc(item.previewUrl)}')">`
    : `<div style="width:48px;height:48px;background:#F0F0F0;display:flex;align-items:center;justify-content:center;border-radius:4px;font-size:10px;color:#666">${esc((item.file.name||'').split('.').pop().toUpperCase())}</div>`;
  return `<div style="position:relative;display:inline-block">${thumb}<button onclick="removePendingFile(${idx},'${targetList}')" style="position:absolute;top:-6px;right:-6px;width:18px;height:18px;border-radius:50%;background:#C62828;color:#fff;border:none;cursor:pointer;font-size:11px;line-height:1;padding:0" aria-label="삭제">×</button></div>`;
}

function renderFlagFilePreview() {
  const el = $('flagFilePreview');
  if (!el) return;
  el.innerHTML = _pendingFlagFiles.map((it, i) => fileChipHtml(it, i, 'pending')).join('');
}

function renderEditingFilePreview() {
  const el = $('editFilePreview');
  if (!el) return;
  const kept = _editingKeptPaths.map((p, i) => {
    const url = _editingKeptUrlMap[p];
    const thumb = url
      ? `<img src="${esc(url)}" style="width:48px;height:48px;object-fit:cover;border-radius:4px" onclick="openImageLightbox('${esc(url)}')">`
      : `<div style="width:48px;height:48px;background:#F0F0F0;display:flex;align-items:center;justify-content:center;border-radius:4px;font-size:10px;color:#666">파일</div>`;
    return `<div style="position:relative;display:inline-block" data-kept="${esc(p)}">${thumb}<button onclick="removeKeptPath(${i})" style="position:absolute;top:-6px;right:-6px;width:18px;height:18px;border-radius:50%;background:#C62828;color:#fff;border:none;cursor:pointer;font-size:11px;line-height:1;padding:0" aria-label="삭제">×</button></div>`;
  }).join('');
  const added = _editingNewFiles.map((it, i) => fileChipHtml(it, i, 'editing')).join('');
  el.innerHTML = kept + added;
}

function removePendingFile(idx, targetList) {
  const arr = targetList === 'editing' ? _editingNewFiles : _pendingFlagFiles;
  arr.splice(idx, 1);
  if (targetList === 'editing') renderEditingFilePreview();
  else renderFlagFilePreview();
}

function removeKeptPath(idx) {
  _editingKeptPaths.splice(idx, 1);
  renderEditingFilePreview();
}

async function uploadAllFiles(items, flagIdOrPrefix) {
  const paths = [];
  for (const it of items) {
    const p = await uploadFlagEvidence(it.file, flagIdOrPrefix);
    paths.push(p);
  }
  return paths;
}

var _editingKeptUrlMap = {};

async function renderInfluencerStatusPanel(u) {
  _currentDetailInfluencer = u;
  // 모달 다시 열릴 때 이전 세션의 펜딩 파일 초기화
  _pendingFlagFiles = [];
  const body = $('infDetailStatusBody');
  const summary = $('infDetailStatusSummary');
  if (!body) return;
  if (_blacklistReasonsCache == null) _blacklistReasonsCache = await fetchBlacklistReasons();
  if (_violationReasonsCache == null) _violationReasonsCache = await fetchViolationReasons();
  if (summary) summary.textContent = (u.is_verified?'인증됨':'미인증') + ' · ' + (u.is_blacklisted?'블랙 등록':'정상');
  // 위반/블랙 공유 사유 풀 — 합집합 (code dedupe)
  const reasonChecks = mergedReasonList().map(r =>
    `<label class="status-chip"><input type="checkbox" class="bl-reason-cb" value="${esc(r.code)}"><span>${esc(r.name_ko)}</span></label>`
  ).join('');
  const pillOk = `background:#F1F3F5;color:#868E96`;
  const pillVerified = `background:#E3F2FD;color:#1565C0`;
  const pillBlack = `background:#FFEBEE;color:#C62828`;
  body.innerHTML = `
    <style>
      .status-card{padding:16px 18px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;display:flex;flex-direction:column;gap:10px}
      .status-card-head{display:flex;align-items:center;justify-content:space-between}
      .status-card .title{display:flex;align-items:center;gap:6px;font-size:13px;font-weight:700;color:var(--ink);line-height:1}
      .status-card .title .material-icons-round{line-height:1}
      .status-pill{font-size:11px;font-weight:700;padding:3px 10px;border-radius:20px;letter-spacing:.02em}
      .status-meta{font-size:11px;color:var(--muted)}
      .status-actions{display:flex;gap:6px;justify-content:flex-end}
      .status-banner{padding:10px 12px;background:#FFF5F5;border-left:3px solid #C62828;border-radius:4px;display:flex;flex-direction:column;gap:4px}
      .status-chip{display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:4px 10px;border:1px solid var(--line);border-radius:20px;cursor:pointer;background:#fff;transition:all .12s}
      .status-chip:hover{border-color:#BDBDBD}
      .status-chip input{margin:0}
      .status-chip input:checked + span{color:#C62828;font-weight:600}
      .status-note{width:100%;font-size:12px;padding:8px 10px;border:1px solid var(--line);border-radius:6px;resize:vertical;font-family:inherit}
      .status-btn-orange{background:#FB8C00;color:#fff;border:none}
      .status-btn-red{background:#C62828;color:#fff;border:none}
    </style>
    <div style="display:flex;flex-direction:column;gap:14px">
      <!-- 인증 -->
      <div class="status-card">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
          <div class="title">
            <span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:${u.is_verified?'#1565C0':'#9E9E9E'}">verified</span>
            ${u.is_verified?'인증':'미인증'}
          </div>
          <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
            ${u.is_verified ? `
              <span class="status-meta">${u.verified_at?formatDateTime(u.verified_at):''}</span>
              <button class="btn btn-ghost btn-xs" onclick="onInfluencerUnverify()">인증 해제</button>
            ` : `
              <button class="btn btn-primary btn-xs" onclick="onInfluencerVerify()">인증 처리</button>
            `}
          </div>
        </div>
      </div>
      <!-- 위반 / 블랙 -->
      <div class="status-card">
        <div class="status-card-head">
          <div class="title"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:${(((_infViolationCounts||{})[u.id]||0)>0 || u.is_blacklisted)?'#C62828':'#9E9E9E'}">report</span>위반 관리</div>
          ${u.is_blacklisted
            ? `<button class="btn btn-ghost btn-xs" onclick="onInfluencerUnblacklist()">블랙 해제</button>`
            : `<button class="btn btn-xs status-btn-red" onclick="onInfluencerBlacklist()">블랙리스트 등록</button>`}
        </div>
        ${u.is_blacklisted ? `
          <div class="status-banner">
            <div class="status-meta">${u.blacklisted_at?formatDateTime(u.blacklisted_at):''}</div>
            ${u.blacklist_reason_code?`<div style="font-size:12px;color:var(--ink)"><strong style="font-weight:700">사유</strong> · ${esc(blacklistReasonLabel(u.blacklist_reason_code))}</div>`:''}
            ${u.blacklist_reason_note?`<div style="font-size:11px;color:var(--muted);white-space:pre-wrap">${esc(u.blacklist_reason_note)}</div>`:''}
          </div>
        ` : ''}
        <div>
          <div class="status-meta" style="margin-bottom:6px">사유 (1개 이상 선택)</div>
          <div style="display:flex;flex-wrap:wrap;gap:6px">${reasonChecks}</div>
        </div>
        <textarea id="blNoteInput" class="status-note" rows="2" placeholder="자유 메모 (선택)"></textarea>
        <div>
          <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;color:var(--pink);cursor:pointer">
            <input type="file" accept="image/*,application/pdf" multiple onchange="onFlagFileInput(this,'pending')" style="display:none">
            <span class="material-icons-round notranslate" translate="no" style="font-size:14px">attach_file</span>
            <span>파일 첨부</span>
          </label>
          <div id="flagFilePreview" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px"></div>
        </div>
        <div class="status-actions">
          <button class="btn btn-xs status-btn-orange" onclick="onInfluencerRecordViolation()">위반 등록</button>
        </div>
        <!-- 관리자 이력 (상태 관리 섹션 안으로 통합) -->
        <div style="margin-top:6px;padding-top:14px;border-top:1px solid var(--line)">
          <div style="display:flex;align-items:center;gap:6px;margin-bottom:8px">
            <div style="font-size:12px;font-weight:700;color:var(--ink);line-height:1">관리자 이력</div>
            <span id="infDetailFlagsCount" style="font-size:11px;color:var(--muted)"></span>
          </div>
          <div id="infDetailFlagsBody" style="border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff"><div style="padding:14px;text-align:center;color:var(--muted);font-size:12px">이력 없음</div></div>
        </div>
      </div>
    </div>
  `;
}

// 사유 코드 단건 조회 — blacklist/violation 양쪽 lookup 에서 검색
function findReasonByCode(code) {
  return (_blacklistReasonsCache||[]).find(x => x.code === code)
      || (_violationReasonsCache||[]).find(x => x.code === code)
      || null;
}

// 체크박스 옵션 — blacklist_reason 한 가지 세트만 사용 (violation_reason 은 과거 기록 호환용 폴백)
// 'other'(기타) 코드는 항상 맨 마지막에 배치
function mergedReasonList() {
  const list = (_blacklistReasonsCache || []);
  const nonOthers = list.filter(r => r.code !== 'other');
  const others = list.filter(r => r.code === 'other');
  return [...nonOthers, ...others];
}

// 콤마 구분 코드 문자열을 한국어 라벨로 변환 (복수 사유 지원)
function blacklistReasonLabel(codeStr) {
  if (!codeStr) return '';
  return codeStr.split(',').map(c => {
    const code = c.trim();
    const r = findReasonByCode(code);
    return r ? r.name_ko : code;
  }).filter(Boolean).join(', ');
}

var _currentFlagsCache = [];

async function renderInfluencerFlagsPanel(influencerId) {
  const body = $('infDetailFlagsBody');
  const count = $('infDetailFlagsCount');
  if (!body) return;
  const flags = await fetchInfluencerFlags(influencerId);
  _currentFlagsCache = flags;
  // evidence signed URL 일괄 생성
  const allPaths = [...new Set(flags.flatMap(f => f.evidence_paths || []))];
  const signedMap = {};
  await Promise.all(allPaths.map(async p => {
    try { signedMap[p] = await getFlagEvidenceSignedUrl(p); } catch {}
  }));
  if (count) count.textContent = `${flags.length}건`;
  if (!flags.length) {
    body.innerHTML = '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">이력 없음</div>';
    return;
  }
  // 사유별 누적 건수 집계 (violation + blacklist 통합, 콤마 구분 코드 각각 카운트)
  const reasonCounts = {};
  flags.forEach(f => {
    if (!f.reason_code) return;
    f.reason_code.split(',').forEach(c => {
      const code = c.trim();
      if (!code) return;
      reasonCounts[code] = (reasonCounts[code] || 0) + 1;
    });
  });
  const pillEntries = Object.entries(reasonCounts).sort((a, b) => b[1] - a[1]);
  const pills = pillEntries.map(([code, n]) =>
    `<span style="display:inline-flex;align-items:center;gap:4px;background:#F5F5F5;color:#616161;font-size:11px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(blacklistReasonLabel(code))}<strong style="color:#424242;font-weight:700">${n}</strong></span>`
  ).join('');
  const summaryHtml = pills
    ? `<div style="padding:10px 16px;background:var(--bg);border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:6px;align-items:center"><strong style="font-size:11px;color:var(--muted);font-weight:600;margin-right:4px">사유 누적</strong>${pills}</div>`
    : '';
  const actionLabel = {verify:'인증', unverify:'인증 해제', violation:'위반 기록', blacklist:'블랙 등록', unblacklist:'블랙 해제'};
  const actionColor = {verify:'#1565C0', unverify:'var(--muted)', violation:'#FB8C00', blacklist:'#C62828', unblacklist:'var(--green)'};
  body.innerHTML = summaryHtml + '<div style="padding:0">' + flags.map(f => {
    const editBtn = f.action === 'violation'
      ? `<button class="btn btn-ghost btn-xs" onclick="openEditViolationById('${esc(f.id)}')" title="수정" style="padding:2px 6px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">edit</span></button>`
      : '';
    const updatedLine = f.updated_at
      ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">수정 ${esc(f.updated_by_name||'—')} · ${formatDateTime(f.updated_at)}</div>`
      : '';
    const thumbs = (f.evidence_paths || []).map(p => {
      const url = signedMap[p];
      if (!url) return '';
      return `<img src="${esc(url)}" alt="증빙" onclick="openImageLightbox('${esc(url)}')" style="width:40px;height:40px;object-fit:cover;border-radius:4px;cursor:pointer;border:1px solid var(--line)">`;
    }).filter(Boolean).join('');
    return `
    <div style="padding:10px 16px;border-bottom:1px solid var(--line);display:flex;gap:12px;align-items:flex-start">
      <div style="font-size:11px;font-weight:700;color:${actionColor[f.action]||'var(--muted)'};min-width:70px;padding-top:2px">${actionLabel[f.action]||esc(f.action)}</div>
      <div style="flex:1;min-width:0">
        ${f.reason_code?`<div style="font-size:12px;color:var(--ink)">${esc(blacklistReasonLabel(f.reason_code))}</div>`:''}
        ${f.note?`<div style="font-size:11px;color:var(--muted);white-space:pre-wrap;margin-top:2px">${esc(f.note)}</div>`:''}
        ${thumbs?`<div style="display:flex;flex-wrap:wrap;gap:4px;margin-top:6px">${thumbs}</div>`:''}
      </div>
      <div style="text-align:right;flex-shrink:0">
        <div style="font-size:11px;color:var(--muted)">${esc(f.set_by_name||'—')}</div>
        <div style="font-size:10px;color:var(--muted)">${f.set_at?formatDateTime(f.set_at):''}</div>
        ${updatedLine}
        ${editBtn}
      </div>
    </div>
    `;
  }).join('') + '</div>';
}

async function onInfluencerVerify() {
  if (!_currentDetailInfluencer) return;
  try {
    await setInfluencerVerified(_currentDetailInfluencer.id, true, null);
    toast('인증 처리되었습니다', 'success');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

async function onInfluencerUnverify() {
  if (!_currentDetailInfluencer) return;
  if (!confirm('인증을 해제할까요?')) return;
  try {
    await setInfluencerVerified(_currentDetailInfluencer.id, false, null);
    toast('인증이 해제되었습니다');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

// 위반 기록 편집 — _currentFlagsCache 에서 id로 찾아 모달 오픈
var _editingFlagId = null;

async function openEditViolationById(flagId) {
  const flag = (_currentFlagsCache || []).find(f => f.id === flagId);
  if (!flag) { toast('이력을 찾을 수 없습니다', 'error'); return; }
  if (flag.action !== 'violation') { toast('위반 기록만 수정 가능합니다', 'error'); return; }
  _editingFlagId = flagId;
  _editingKeptPaths = [...(flag.evidence_paths || [])];
  _editingNewFiles = [];
  _editingKeptUrlMap = {};
  // 기존 파일의 signed URL 미리 로드
  for (const p of _editingKeptPaths) {
    try { _editingKeptUrlMap[p] = await getFlagEvidenceSignedUrl(p); } catch {}
  }
  const selectedCodes = (flag.reason_code || '').split(',').map(c => c.trim()).filter(Boolean);
  const reasons = mergedReasonList();
  const checks = reasons.map(r =>
    `<label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:3px 8px;border:1px solid var(--line);border-radius:4px;cursor:pointer"><input type="checkbox" class="fe-reason-cb" value="${esc(r.code)}"${selectedCodes.includes(r.code)?' checked':''}>${esc(r.name_ko)}</label>`
  ).join('');
  const body = $('flagEditBody');
  if (body) {
    body.innerHTML = `
      <div style="font-size:11px;color:var(--muted);margin-bottom:6px">사유 (1개 이상 선택)</div>
      <div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px">${checks}</div>
      <textarea id="feNoteInput" class="form-input" rows="3" placeholder="자유 메모 (선택)" style="width:100%;font-size:12px;padding:8px;resize:vertical">${esc(flag.note||'')}</textarea>
      <div style="margin-top:10px">
        <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;color:var(--pink);cursor:pointer">
          <input type="file" accept="image/*,application/pdf" multiple onchange="onFlagFileInput(this,'editing')" style="display:none">
          <span class="material-icons-round notranslate" translate="no" style="font-size:14px">attach_file</span>
          <span>파일 첨부</span>
        </label>
        <div id="editFilePreview" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px"></div>
      </div>
      <div style="display:flex;gap:8px;margin-top:14px;justify-content:flex-end">
        <button class="btn btn-ghost btn-xs" onclick="closeModal('influencerFlagEditModal')">취소</button>
        <button class="btn btn-primary btn-xs" onclick="onSaveEditViolation()">저장</button>
      </div>
    `;
  }
  openModal('influencerFlagEditModal');
  renderEditingFilePreview();
}

async function onSaveEditViolation() {
  if (!_editingFlagId) return;
  const modal = $('influencerFlagEditModal');
  const codes = [...(modal || document).querySelectorAll('.fe-reason-cb:checked')].map(cb => cb.value);
  const note = $('feNoteInput')?.value || '';
  if (codes.length === 0) { toast('사유를 1개 이상 선택해주세요', 'error'); return; }
  try {
    let finalPaths;
    if (_editingNewFiles.length > 0) {
      toast('첨부 파일 업로드 중...', 'info');
      const newPaths = await uploadAllFiles(_editingNewFiles, _editingFlagId);
      finalPaths = [..._editingKeptPaths, ...newPaths];
    } else {
      // 기존 수만 유지/감소. 원본 개수보다 줄었으면 교체, 같으면 미변경 처리
      const orig = ((_currentFlagsCache || []).find(f => f.id === _editingFlagId)?.evidence_paths) || [];
      if (_editingKeptPaths.length !== orig.length) finalPaths = _editingKeptPaths;
      else finalPaths = undefined; // 미변경
    }
    await updateInfluencerViolation(_editingFlagId, codes.join(','), note || null, finalPaths);
    toast('수정되었습니다', 'success');
    closeModal('influencerFlagEditModal');
    _editingFlagId = null;
    _editingKeptPaths = [];
    _editingNewFiles = [];
    _editingKeptUrlMap = {};
    if (_currentDetailInfluencer) await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

async function onInfluencerRecordViolation() {
  if (!_currentDetailInfluencer) return;
  const modal = $('influencerFullDetailModal');
  const codes = [...(modal || document).querySelectorAll('.bl-reason-cb:checked')].map(cb => cb.value);
  const note = $('blNoteInput')?.value || '';
  if (codes.length === 0) { toast('위반 사유를 1개 이상 선택해주세요', 'error'); return; }
  try {
    let evidencePaths = null;
    if (_pendingFlagFiles.length > 0) {
      toast('첨부 파일 업로드 중...', 'info');
      const prefix = 'tmp/' + Date.now();
      evidencePaths = await uploadAllFiles(_pendingFlagFiles, prefix);
    }
    await recordInfluencerViolation(_currentDetailInfluencer.id, codes.join(','), note || null, evidencePaths);
    toast('위반 기록이 등록되었습니다', 'success');
    _pendingFlagFiles = [];
    _infViolationCounts[_currentDetailInfluencer.id] = (_infViolationCounts[_currentDetailInfluencer.id] || 0) + 1;
    rerenderInfluencersFromCache();
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

async function onInfluencerBlacklist() {
  if (!_currentDetailInfluencer) return;
  const modal = $('influencerFullDetailModal');
  const codes = [...(modal || document).querySelectorAll('.bl-reason-cb:checked')].map(cb => cb.value);
  const note = $('blNoteInput')?.value || '';
  if (codes.length === 0) { toast('블랙리스트 사유를 1개 이상 선택해주세요', 'error'); return; }
  if (!confirm('블랙리스트에 등록할까요?')) return;
  try {
    await setInfluencerBlacklist(_currentDetailInfluencer.id, true, codes.join(','), note || null);
    toast('블랙리스트에 등록되었습니다', 'success');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

async function onInfluencerUnblacklist() {
  if (!_currentDetailInfluencer) return;
  if (!confirm('블랙리스트를 해제할까요?')) return;
  try {
    await setInfluencerBlacklist(_currentDetailInfluencer.id, false, null, null);
    toast('블랙리스트가 해제되었습니다');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

// 인플루언서 이름 클릭 = 어디서든 풀 상세 모달(상태 관리·이력 포함)로 통일
async function openInfluencerModal(userId) {
  if (!userId) return;
  return openInfluencerDetail(userId);
}

// ── 신청 관리 (캠페인별) ──
let currentAppTypeTab = 'all';
let currentAppCampId = null;

async function loadApplications() {
  invalidateAppListCache();
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

var appLazy = null;
const APP_PAGE_SIZE = 50;
var _appListCache = null;

function invalidateAppListCache() { _appListCache = null; }

async function renderAppCampList() {
  const bodyEl = $('appTableBody');
  const countEl = $('appTotalCount');
  if (!bodyEl) return;

  if (!_appListCache) {
    const [cs, as, us] = await Promise.all([fetchCampaigns(), fetchApplications(), fetchInfluencers()]);
    _appListCache = { camps: cs, allAppsRaw: as, users: us };
  }
  let camps = _appListCache.camps.slice();
  const allAppsRaw = _appListCache.allAppsRaw;
  let apps = allAppsRaw.slice();
  const users = _appListCache.users;

  // 캠페인 ↔ 타입 쌍별 연동: 현재 선택값 스냅샷
  const typeValsRaw = getMultiFilterValues('appTypeMulti');
  const campValsRaw = getMultiFilterValues('appCampMulti');

  // 캠페인 옵션: 타입 제약 있으면 해당 타입 캠페인만 노출
  const sortedCampsAll = camps.slice().sort((a,b) => new Date(b.created_at) - new Date(a.created_at));
  const campOptionsSource = typeValsRaw.length > 0
    ? sortedCampsAll.filter(c => typeValsRaw.includes(c.recruit_type))
    : sortedCampsAll;

  // 타입 옵션: 캠페인 제약 있으면 해당 캠페인들의 타입 합집합만 노출
  const ALL_RECRUIT_TYPES = ['monitor','gifting','visit'];
  const availableTypes = campValsRaw.length > 0
    ? ALL_RECRUIT_TYPES.filter(t => camps.some(c => campValsRaw.includes(c.id) && c.recruit_type === t))
    : ALL_RECRUIT_TYPES;

  // stale 선택 감지 → 경고 토스트 (자동 해제는 syncMultiFilter 복원 단계에서 자연 탈락)
  const campStale = campValsRaw.filter(v => !campOptionsSource.some(c => c.id === v));
  const typeStale = typeValsRaw.filter(v => !availableTypes.includes(v));
  if (campStale.length > 0 && typeof toast === 'function') toast(`선택한 캠페인 ${campStale.length}건이 타입 필터에 맞지 않아 해제되었습니다`, 'info');
  if (typeStale.length > 0 && typeof toast === 'function') toast(`선택한 타입 ${typeStale.length}건이 캠페인 필터에 맞지 않아 해제되었습니다`, 'info');

  // 드롭다운 동기화
  syncCampMultiFilter('appCampMulti', campOptionsSource, () => renderAppCampList());
  syncMultiFilter('appTypeMulti', '전체 타입',
    availableTypes.map(t => ({value:t, label:RECRUIT_TYPE_LABEL_KO[t] || t})),
    () => renderAppCampList());

  // 타입 필터 (다중 선택) — stale 제거 후 최종값
  const appTypeVals = getMultiFilterValues('appTypeMulti');
  if (appTypeVals.length) {
    const filteredCampIds = camps.filter(c => appTypeVals.includes(c.recruit_type)).map(c => c.id);
    apps = apps.filter(a => filteredCampIds.includes(a.campaign_id));
  }

  // 상태 필터 (다중 선택)
  const appStatusVals = getMultiFilterValues('appStatusMulti');
  if (appStatusVals.length) apps = apps.filter(a => appStatusVals.includes(a.status));

  // 캠페인 다중 선택 필터 — stale 제거 후 최종값
  const campFilterVals = getMultiFilterValues('appCampMulti');
  if (campFilterVals.length) apps = apps.filter(a => campFilterVals.includes(a.campaign_id));

  // 검색 필터
  const searchVal = ($('appSearch')?.value || '').trim().toLowerCase();
  if (searchVal) {
    apps = apps.filter(a => {
      const camp = camps.find(c => c.id === a.campaign_id) || {};
      return (camp.title||'').toLowerCase().includes(searchVal)
        || (camp.brand||'').toLowerCase().includes(searchVal)
        || (camp.brand_ko||'').toLowerCase().includes(searchVal)
        || (camp.product||'').toLowerCase().includes(searchVal)
        || (camp.product_ko||'').toLowerCase().includes(searchVal)
        || (camp.campaign_no||'').toLowerCase().includes(searchVal)
        || (a.user_name||'').toLowerCase().includes(searchVal)
        || (a.user_email||'').toLowerCase().includes(searchVal);
    });
  }

  updateFilterResetBtn('btnAppFilterReset', ['appTypeMulti','appStatusMulti','appCampMulti'], 'appSearch');

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

  const renderAppRow = (a) => {
    const camp = camps.find(c => c.id === a.campaign_id) || {};
    const u = users.find(u => u.email === a.user_email) || {};
    const _campRemaining = Math.max((camp.slots||0)-allAppsRaw.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    const brandPrimary = camp.brand_ko || camp.brand || '';
    const brandSub     = (camp.brand_ko && camp.brand && camp.brand_ko !== camp.brand) ? camp.brand : '';
    const productPrimary = camp.product_ko || camp.product || '';
    const productSub     = (camp.product_ko && camp.product && camp.product_ko !== camp.product) ? camp.product : '';
    return `<tr data-id="${esc(a.id)}">
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,160)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div>${typeLabel}</div>
            <strong style="font-size:13px;cursor:pointer" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong>
            ${camp.slots?(()=>{const _r=Math.max(camp.slots-allAppsRaw.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);return `<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_r>0?'var(--green)':'var(--red)'};font-weight:600">${_r>0?_r+'건':'없음'}</span></div>`;})():''}
          </div>
        </div>
      </td>
      <td style="font-size:12px;color:var(--ink);min-width:100px">
        ${brandPrimary?esc(brandPrimary):'—'}
        ${brandSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(brandSub)}</div>`:''}
      </td>
      <td style="font-size:12px;color:var(--ink);min-width:120px">
        ${productPrimary?esc(productPrimary):'—'}
        ${productSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(productSub)}</div>`:''}
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}${influencerStatusBadges(u)}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${u.line_id?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(u.line_id)}</div>`:''}
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${_campRemaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(a.reviewed_by||'')} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
      </td>
    </tr>`;
  };
  const scrollRoot = bodyEl.closest('.admin-table-wrap');
  if (appLazy) appLazy.destroy();
  appLazy = mountLazyList({
    tbody: bodyEl,
    scrollRoot,
    rows: apps,
    renderRow: renderAppRow,
    pageSize: APP_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>',
  });
}

async function updateAppStatus(appId, status) {
  try {
    // 승인 시 모집인원 초과 체크
    if (status === 'approved') {
      const {data: app} = await db?.from('applications').select('campaign_id').eq('id', appId).maybeSingle();
      if (app) {
        const {data: camp} = await db?.from('campaigns').select('slots').eq('id', app.campaign_id).maybeSingle();
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
    invalidateAppListCache();
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
  const brandKo = ($('newCampBrandKo')?.value || '').trim();
  const product = $('newCampProduct').value.trim();
  const productKo = ($('newCampProductKo')?.value || '').trim();
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
    toast('캠페인 노출 마감일은 모집 종료일 이후여야 합니다','error');
    return;
  }
  const newDateErrs = validateCampDateRanges('newCamp');
  if (newDateErrs.length) { toast(newDateErrs[0].msg, 'error'); validateCampDateRangesInline('newCamp'); return; }
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
    brand_ko: brandKo || null,
    product_ko: productKo || null,
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
    reward_note: ($('newCampRewardNote')?.value || '').trim() || null,
    slots, applied_count:0,
    recruit_start: $('newCampRecruitStart')?.value||null,
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
    // 067 legacy 컬럼은 더 이상 갱신하지 않음 (070 마이그레이션에서 DROP 예정)
    status:'draft',
    ...collectCampPsetPayload('new'),
    ...collectCampCsetPayload('new'),
  };

  await insertCampaign(camp);
  toast('캠페인이 등록되었습니다','success');
  campImgData.length = 0;
  renderImgPreview(campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');

  ['newCampTitle','newCampBrand','newCampProduct','newCampProductUrl',
   'newCampSlots','newCampRecruitStart','newCampDeadline','newCampPostDeadline',
   'newCampPurchaseStart','newCampPurchaseEnd','newCampVisitStart','newCampVisitEnd',
   'newCampSubmissionEnd','newCampHashtags','newCampMentions',
   'newCampProductPrice','newCampReward','newCampRewardNote'].forEach(id => { const el=$(id); if(el) el.value=''; });
  // flatpickr range picker 클리어
  applyCampRangeValues('newCamp', { recruit:[null,null], purchase:[null,null], visit:[null,null] });
  // 리치 에디터 초기화
  ['newCampDesc','newCampAppeal','newCampGuide','newCampNg'].forEach(id => setRichValue(id, ''));
  document.querySelectorAll('input[name="recruitType"]').forEach(r=>r.checked=false);
  document.querySelectorAll('[id^="rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';});
  // 동적 영역 재렌더 (체크 해제 + 전체 채널 다시 표시)
  await Promise.all([
    renderChannelCheckboxes('new', null, []),
    renderContentTypeCheckboxes('new', [], null),
    renderCategorySelect('new', '')
  ]);
  // 주의사항 번들 초기화 (신규 캠페인은 빈 상태로 시작 — 관리자가 번들 선택)
  _csetState.new = [];
  await populateCampCsetDropdown('new', null, null);
  renderCampCautionItems('new');

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

function updateSidebarProfile() {
  const name = currentAdminInfo?.name || currentUserProfile?.name || currentUser?.email || '관리자';
  const initial = (name || 'A').charAt(0).toUpperCase();
  const el = $('sidebarAdminName');
  const av = $('sidebarAdminAvatar');
  if (el) el.textContent = name;
  if (av) av.textContent = initial;
  // STAGING 배지
  const sb = $('stagingBadgeSide');
  const sbOrig = $('stagingBadge');
  if (sb && sbOrig && sbOrig.style.display !== 'none') sb.style.display = '';
}

async function loadAdminAccounts() {
  if (!db) return;
  const {data} = await db?.from('admins').select('*').order('created_at');
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
    <td style="text-align:center">
      <label class="lookup-toggle" title="브랜드 서베이 접수 시 알림 메일 수신" onclick="event.stopPropagation()">
        <input type="checkbox" ${a.receive_brand_notify ? 'checked' : ''} onchange="toggleAdminBrandNotify('${a.id}', this.checked)">
        <span class="lookup-toggle-slider"></span>
      </label>
    </td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td><div style="display:flex;gap:5px">
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" data-name="${esc(a.name||'')}" onclick="openEditAdmin('${a.id}',this.dataset.email,this.dataset.name,'${a.role}')">수정</button>
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" onclick="openResetPwModal('${a.auth_id}',this.dataset.email)">비밀번호</button>
      ${(isSuper && a.auth_id !== currentUser?.id) ? `<button class="btn btn-ghost btn-xs" style="color:#B3261E" data-email="${esc(a.email)}" data-auth-id="${a.auth_id}" onclick="openDeleteAdminModal('${a.id}',this.dataset.authId,this.dataset.email)">삭제</button>` : ''}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>';

  applyLookupMenuVisibility();
}

// 광고주 신청 알림 수신 토글 (admins.receive_brand_notify)
async function toggleAdminBrandNotify(adminId, checked) {
  if (!db) return;
  try {
    const {error} = await db?.from('admins').update({receive_brand_notify: !!checked}).eq('id', adminId);
    if (error) throw error;
    toast(checked ? '알림 수신 켜짐' : '알림 수신 꺼짐');
  } catch(e) {
    toast('저장 실패: ' + (e.message || '알 수 없는 오류'), 'error');
    loadAdminAccounts();
  }
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
const LOOKUP_KIND_LABEL_KO = {channel:'채널', category:'카테고리', content_type:'콘텐츠 종류', ng_item:'NG 사항', participation_set:'참여방법', reject_reason:'반려사유', caution:'주의사항'};
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
  if (_currentLookupKind === 'caution') { await renderCsetTable(); return; }
  const isChannel = _currentLookupKind === 'channel';
  const showRt = isChannel || _currentLookupKind === 'reject_reason';
  // 헤더 렌더
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>한국어 명칭</th>
      <th>일본어 명칭</th>
      ${showRt ? '<th style="width:140px">모집 타입</th>' : ''}
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = 5 + (showRt ? 1 : 0);
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
    const rts = r.recruit_types || [];
    const rtCell = showRt
      ? `<td><div style="display:flex;gap:3px;flex-wrap:wrap">${
          rts.length
            ? rts.map(t => {
                const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
                return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
              }).join('')
            : `<span class="badge badge-gray" style="font-size:9px;padding:1px 6px">공통</span>`
        }</div></td>`
      : '';
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong></td>
      <td style="color:var(--ink);font-size:13px">${esc(r.name_ja)}</td>
      ${rtCell}
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

async function renderContentTypeCheckboxes(formMode, preSelectedLabels, recruitType) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  const wrap = $(cfg.ctWrap); if (!wrap) return;
  let items = [];
  try { items = await fetchLookups('content_type'); } catch(e) { return; }
  // 리뷰어(monitor) 캠페인은 Qoo10 리뷰 형식상 콘텐츠가 동영상·이미지 위주이므로 옵션 제한.
  // 기존에 다른 코드(피드/릴스 등)가 저장되어 있다면 옵션 미노출이라 저장 시 자동 폐기됨 (운영 의도).
  if (recruitType === 'monitor') {
    const dropped = (preSelectedLabels || []).filter(lbl => !items.some(c => (c.code === 'video' || c.code === 'image') && c.name_ja === lbl));
    if (dropped.length) console.warn('[renderContentTypeCheckboxes] monitor 캠페인이라 다음 콘텐츠 코드는 폼에서 폐기됨:', dropped);
    items = items.filter(c => c.code === 'video' || c.code === 'image');
  }
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

// (migration 069 이후 제거됨 — 주의사항은 caution_sets 번들 패턴으로 대체)
// 기존 renderCautionCheckboxes / collectCautionCodes 함수는
// caution_lookup_codes / caution_custom_html 경로와 함께 제거되었으며,
// campForm 의 새로운 caution UI 는 populateCampCsetDropdown / renderCampCautionItems 참조.

async function filterChannelsByRecruitType(formMode, recruitType) {
  const cfg = _formCfg[formMode]; if (!cfg) return;
  // 현재 체크된 코드 보존
  const checked = Array.from(document.querySelectorAll(`input[name="${cfg.chName}"]:checked`)).map(c => c.value);
  await renderChannelCheckboxes(formMode, recruitType, checked);
  // 콘텐츠 종류도 모집 타입에 맞춰 재렌더 (monitor=동영상·이미지만, gifting/visit=전체)
  const checkedCT = Array.from(document.querySelectorAll(`input[name="${cfg.ctName}"]:checked`)).map(c => c.value);
  await renderContentTypeCheckboxes(formMode, checkedCT, recruitType);
  // 참여방법 번들 드롭다운도 모집 타입에 맞춰 갱신 (선택값은 유지 시도)
  const psetSel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  await populateCampPsetDropdown(formMode, recruitType, psetSel?.value || null);
  // 주의사항 번들 드롭다운도 동일 패턴으로 필터링 (migration 069)
  const csetSel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  await populateCampCsetDropdown(formMode, recruitType, csetSel?.value || null);
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
  if (_currentLookupKind === 'caution') { openCsetAddModal(); return; }
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
  if (_currentLookupKind === 'caution') { openCsetEditModal(row); return; }
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
    else if (_currentLookupKind === 'caution') await swapCautionSetOrder(idA, idB);
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
    } else if (_currentLookupKind === 'caution') {
      if (nextActive) await activateCautionSet(id); else await deactivateCautionSet(id);
    } else {
      if (nextActive) await activateLookup(id); else await deactivateLookup(id);
    }
    renderLookupsTable();
  } catch(e) {
    toast('상태 변경 실패: ' + (e.message||String(e)),'error');
  }
}

async function handleLookupDelete(row) {
  // 번들(caution_sets / participation_sets) 여부 판별: row.kind 미존재 또는 현재 kind가 번들 탭
  if (_currentLookupKind === 'caution' || (_currentLookupKind === 'participation_set') || row.kind === undefined) {
    const ok = await showConfirm(`'${row.name_ko}' 번들을 영구 삭제하시겠습니까?\n이미 해당 번들을 쓴 캠페인은 스냅샷이 저장돼 영향 없습니다.`);
    if (!ok) return;
    try {
      if (_currentLookupKind === 'caution') await deleteCautionSet(row.id);
      else await deleteParticipationSet(row.id);
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
const RECRUIT_TYPE_LABEL_JA = {monitor:'モニター', gifting:'ギフティング', visit:'訪問'};
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
// 주의사항 번들 (caution_sets) — 관리자 UI (migration 069)
//   참여방법 번들 패턴 완전 미러링. 캠페인 저장 시 items 스냅샷이
//   campaigns.caution_items 로 복사된다.
// ══════════════════════════════════════
let _csetCurrentItems = []; // 편집 중 items 상태
const MAX_CSET_ITEMS = 15;

async function renderCsetTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  if (!tbody) return;
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>번들 이름 (한국어 / 일본어)</th>
      <th style="width:140px">모집 타입</th>
      <th style="width:80px">항목 수</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 6;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try { rows = await fetchCautionSetsAll(); } catch(e) {
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
    const rtBadges = (r.recruit_types||[]).length
      ? (r.recruit_types||[]).map(t => {
          const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
          return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
        }).join(' ')
      : '<span style="font-size:10px;color:var(--muted)">공통</span>';
    const itemCount = Array.isArray(r.items) ? r.items.length : 0;
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong><div style="color:var(--muted);font-size:11px;margin-top:2px">${esc(r.name_ja)}</div></td>
      <td><div style="display:flex;gap:3px;flex-wrap:wrap">${rtBadges}</div></td>
      <td style="font-size:12px;color:var(--ink)">${itemCount}개</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openCsetEditModal(${JSON.stringify(r)})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${JSON.stringify(r)})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openCsetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('csetModalTitle').textContent = '주의사항 번들 추가';
  $('csetEditId').value = '';
  $('csetNameKo').value = '';
  $('csetNameJa').value = '';
  document.querySelectorAll('input[name="csetRT"]').forEach(cb => cb.checked = false);
  _csetCurrentItems = [makeBlankCsetItem()];
  renderCsetItems();
  $('csetEditError').style.display = 'none';
  openModal('csetEditModal');
}

function openCsetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('csetModalTitle').textContent = '주의사항 번들 편집';
  $('csetEditId').value = row.id;
  $('csetNameKo').value = row.name_ko || '';
  $('csetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="csetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _csetCurrentItems = Array.isArray(row.items) && row.items.length
    ? row.items.map(normalizeCsetItem)
    : [makeBlankCsetItem()];
  renderCsetItems();
  $('csetEditError').style.display = 'none';
  openModal('csetEditModal');
}

function makeBlankCsetItem() {
  return {html_ko:'', html_ja:''};
}
// 레거시/신규 item 모두 {html_ko, html_ja} 정규화 (migration 069 전환 완료 후 v1 키 제거 예정)
function normalizeCsetItem(s) {
  if (!s) return makeBlankCsetItem();
  // v2 (신규): html_ko / html_ja
  if (s.html_ko != null || s.html_ja != null) {
    return {html_ko: s.html_ko || '', html_ja: s.html_ja || ''};
  }
  // v1 레거시 호환 (초안 069에 남아있을 수 있는 캐시 데이터용 - 즉시 html 로 합치기)
  const esc = v => (v == null ? '' : String(v))
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const buildLang = (lang) => {
    const body = s['text_'+lang] || '';
    const url = (s.link_url || '').trim();
    if (!url) return esc(body);
    const label = s['link_label_'+lang] || url;
    const after = s['text_after_'+lang] || '';
    const safeUrl = /^https?:\/\/|^mailto:/i.test(url) ? url : '';
    if (!safeUrl) return esc(body) + esc(after);
    return `${esc(body)}<a href="${esc(safeUrl)}" target="_blank" rel="noopener noreferrer">${esc(label)}</a>${esc(after)}`;
  };
  return {html_ko: buildLang('ko'), html_ja: buildLang('ja')};
}

// 미니 에디터 (contenteditable + execCommand) — B/I/U/S/Link 5버튼만 제공
function miniEditorHtml(initialHtml, onChangeAttr, placeholder) {
  const safe = (typeof sanitizeCautionHtml === 'function')
    ? sanitizeCautionHtml(initialHtml || '')
    : String(initialHtml || '').replace(/<script/gi, '&lt;script');
  const ph = esc(placeholder || '');
  return `
    <div class="mini-editor-wrap" style="border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff">
      <div class="mini-editor-toolbar" style="display:flex;gap:2px;padding:4px 6px;border-bottom:1px solid var(--line);background:#fafafa">
        <button type="button" onclick="miniEditorCmd(this,'bold')" title="굵게"        style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-weight:700;font-size:12px">B</button>
        <button type="button" onclick="miniEditorCmd(this,'italic')" title="기울임"    style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-style:italic;font-size:12px">I</button>
        <button type="button" onclick="miniEditorCmd(this,'underline')" title="밑줄"   style="border:0;background:transparent;cursor:pointer;padding:4px 8px;text-decoration:underline;font-size:12px">U</button>
        <button type="button" onclick="miniEditorCmd(this,'strikeThrough')" title="취소선" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;text-decoration:line-through;font-size:12px">S</button>
        <span style="width:1px;background:var(--line);margin:2px 4px"></span>
        <button type="button" onclick="miniEditorCmd(this,'link')" title="링크 추가 (텍스트 선택 후 클릭)" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-size:12px;color:var(--pink);display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">link</span>링크</button>
      </div>
      <div class="mini-editor-content" contenteditable="true" data-placeholder="${ph}" style="padding:8px 10px;font-size:13px;min-height:48px;line-height:1.6;outline:none" oninput="${onChangeAttr}" onpaste="miniEditorPaste(event)">${safe}</div>
    </div>`;
}

// 툴바 버튼 클릭 핸들러 — 현재 셀렉션에 cmd 적용
function miniEditorCmd(btn, cmd) {
  const wrap = btn.closest('.mini-editor-wrap');
  const content = wrap?.querySelector('.mini-editor-content');
  if (!content) return;
  content.focus();
  if (cmd === 'link') {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) { toast('링크로 만들 텍스트를 먼저 선택하세요','error'); return; }
    const url = prompt('링크 URL (https:// 또는 mailto:)', 'https://');
    if (!url) return;
    const clean = url.trim();
    if (!/^https?:\/\/|^mailto:/i.test(clean)) { toast('http/https/mailto URL 만 허용됩니다','error'); return; }
    document.execCommand('createLink', false, clean);
    // target=_blank + rel 추가 (execCommand 는 이 속성을 설정하지 않음)
    content.querySelectorAll('a[href]').forEach(a => {
      if (a.getAttribute('href') === clean) {
        a.setAttribute('target', '_blank');
        a.setAttribute('rel', 'noopener noreferrer');
      }
    });
  } else {
    document.execCommand(cmd, false, null);
  }
  // oninput 수동 트리거 (execCommand 는 input 이벤트 생성 안 하는 브라우저 대응)
  content.dispatchEvent(new Event('input', {bubbles:true}));
}

// paste 시 서식 제거 — plain text 로만 삽입해 외부 block 태그 유입 차단
function miniEditorPaste(e) {
  e.preventDefault();
  const text = (e.clipboardData || window.clipboardData)?.getData('text/plain') || '';
  document.execCommand('insertText', false, text);
}

// ══════════════════════════════════════
// 미니 에디터 — 링크 팝오버 (클릭 시 URL 편집/복사/삭제)
//   .mini-editor-content 내부 <a> 를 클릭하면 말풍선 팝오버 노출.
//   - URL 인풋으로 href 실시간 수정 (http/https/mailto 화이트리스트)
//   - 복사 버튼 → 현재 href 를 clipboard 로 복사
//   - 삭제 버튼 → <a> 언래핑(텍스트만 남김) + oninput 트리거
//   - 외부 클릭 또는 ESC 로 닫기
// ══════════════════════════════════════
var _miniEditorLinkPopover = null;

function closeMiniEditorLinkPopover() {
  if (_miniEditorLinkPopover) {
    _miniEditorLinkPopover.remove();
    _miniEditorLinkPopover = null;
    document.removeEventListener('mousedown', _miniEditorLinkPopoverOutside, true);
    document.removeEventListener('keydown', _miniEditorLinkPopoverKey, true);
  }
}

function _miniEditorLinkPopoverOutside(e) {
  if (!_miniEditorLinkPopover) return;
  if (_miniEditorLinkPopover.contains(e.target)) return;
  // 다른 링크 클릭이면 팝오버 교체 (위임 핸들러에서 다시 openMiniEditorLinkPopover 호출)
  if (e.target.closest && e.target.closest('.mini-editor-content a[href], .ql-editor a[href]')) return;
  closeMiniEditorLinkPopover();
}

function _miniEditorLinkPopoverKey(e) {
  if (e.key === 'Escape') closeMiniEditorLinkPopover();
}

function openMiniEditorLinkPopover(aEl, contentDiv) {
  closeMiniEditorLinkPopover();
  const rect = aEl.getBoundingClientRect();
  const pop = document.createElement('div');
  pop.className = 'mini-editor-link-popover';
  const href = aEl.getAttribute('href') || '';
  // position:fixed 기반 — viewport 좌표 그대로 사용 (CSS 에서 position:fixed 지정)
  pop.style.top = (rect.bottom + 6) + 'px';
  pop.style.left = Math.max(8, rect.left) + 'px';
  pop.innerHTML = `
    <input type="url" class="melp-url" value="${esc(href)}" placeholder="https:// 또는 mailto:" spellcheck="false">
    <button type="button" class="melp-btn melp-copy" title="링크 URL 복사"><span class="material-icons-round notranslate" translate="no">content_copy</span></button>
    <button type="button" class="melp-btn melp-open" title="새 탭으로 열기"><span class="material-icons-round notranslate" translate="no">open_in_new</span></button>
    <button type="button" class="melp-btn melp-delete" title="링크 제거"><span class="material-icons-round notranslate" translate="no">link_off</span></button>
  `;
  document.body.appendChild(pop);
  _miniEditorLinkPopover = pop;

  const input = pop.querySelector('.melp-url');
  const btnCopy = pop.querySelector('.melp-copy');
  const btnOpen = pop.querySelector('.melp-open');
  const btnDelete = pop.querySelector('.melp-delete');

  // 초기 URL 이 화이트리스트 미매치면 빨간색 피드백 (javascript:/data: 등 비정상 스킴 가시화)
  if (href && !/^https?:\/\/|^mailto:/i.test(href)) {
    input.style.color = 'var(--red)';
  }

  // URL 편집: http/https/mailto 면 즉시 href 반영, 아니면 href 미변경(입력창만 유지)
  input.addEventListener('input', () => {
    const val = input.value.trim();
    if (val && /^https?:\/\/|^mailto:/i.test(val)) {
      aEl.setAttribute('href', val);
      input.style.color = '';
      contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    } else if (val) {
      input.style.color = 'var(--red)';
    } else {
      input.style.color = '';
    }
  });

  // 복사
  btnCopy.addEventListener('click', async () => {
    const v = aEl.getAttribute('href') || '';
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(v);
      } else {
        // 구형 브라우저 폴백
        const ta = document.createElement('textarea');
        ta.value = v; document.body.appendChild(ta);
        ta.select(); document.execCommand('copy'); document.body.removeChild(ta);
      }
      toast('링크를 복사했습니다','success');
    } catch(e) { toast('복사 실패: ' + (e.message||String(e)),'error'); }
  });

  // 새 탭으로 열기 (편집 중에도 실제 링크 확인 가능)
  btnOpen.addEventListener('click', () => {
    const v = aEl.getAttribute('href') || '';
    if (/^https?:\/\/|^mailto:/i.test(v)) window.open(v, '_blank', 'noopener,noreferrer');
  });

  // 링크 제거: <a> 를 자식 텍스트로 언래핑
  btnDelete.addEventListener('click', () => {
    const parent = aEl.parentNode;
    if (!parent) return;
    while (aEl.firstChild) parent.insertBefore(aEl.firstChild, aEl);
    parent.removeChild(aEl);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    closeMiniEditorLinkPopover();
  });

  // 팝오버 밖 클릭·ESC 로 닫기
  setTimeout(() => {
    document.addEventListener('mousedown', _miniEditorLinkPopoverOutside, true);
    document.addEventListener('keydown', _miniEditorLinkPopoverKey, true);
  }, 0);

  input.focus();
  input.select();
}

// 위임 핸들러 — 미니 에디터 + Quill 에디터 내부 <a> 클릭 → 팝오버 (새 탭 이동 차단)
document.addEventListener('click', function(e) {
  const a = e.target.closest && e.target.closest('.mini-editor-content a[href], .ql-editor a[href]');
  if (!a) return;
  const contentDiv = a.closest('.mini-editor-content, .ql-editor');
  if (!contentDiv) return;
  e.preventDefault();
  openMiniEditorLinkPopover(a, contentDiv);
});

function renderCsetItems() {
  const wrap = $('csetItemsWrap');
  if (!wrap) return;
  wrap.innerHTML = _csetCurrentItems.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">항목 ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="csetMoveItem(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_csetCurrentItems.length-1?'disabled':''} onclick="csetMoveItem(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_csetCurrentItems.length<=1?'disabled':''} onclick="csetRemoveItem(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_csetCurrentItems[${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">本文 (日本語)</div>
          ${miniEditorHtml(s.html_ja, `_csetCurrentItems[${idx}].html_ja=this.innerHTML`, '本文 (日本語)')}
        </div>
      </div>
    </div>
  `).join('');
  const addBtn = $('csetAddItemBtn');
  if (addBtn) addBtn.disabled = _csetCurrentItems.length >= MAX_CSET_ITEMS;
}

function csetAddItem() {
  if (_csetCurrentItems.length >= MAX_CSET_ITEMS) { toast(`항목은 최대 ${MAX_CSET_ITEMS}개까지 입니다`,'error'); return; }
  _csetCurrentItems.push(makeBlankCsetItem());
  renderCsetItems();
}

function csetRemoveItem(idx) {
  if (_csetCurrentItems.length <= 1) return;
  _csetCurrentItems.splice(idx, 1);
  renderCsetItems();
}

function csetMoveItem(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _csetCurrentItems.length) return;
  const [s] = _csetCurrentItems.splice(idx, 1);
  _csetCurrentItems.splice(j, 0, s);
  renderCsetItems();
}

// caution item html 이 실질적으로 비어있는지 (미니 에디터는 빈 상태에서도 <br> 같은 것을 남길 수 있음)
function isCsetItemEmpty(htmlKo, htmlJa) {
  const plain = String((htmlKo || '') + ' ' + (htmlJa || ''))
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .trim();
  return plain.length === 0;
}

async function saveCsetEdit() {
  const errEl = $('csetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('csetEditId').value;
  const name_ko = $('csetNameKo').value.trim();
  const name_ja = $('csetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 번들 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="csetRT"]:checked')).map(cb => cb.value);
  // 저장 직전 DOMPurify sanitize — DB에 안전한 HTML만 저장 (렌더 단도 2중 sanitize)
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _csetCurrentItems
    .filter(s => !isCsetItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  if (!items.length) { show('항목을 1개 이상 입력해주세요 (본문 한국어 또는 일본어 필수)'); return; }
  if (items.length > MAX_CSET_ITEMS) { show(`항목은 최대 ${MAX_CSET_ITEMS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, items};
  try {
    if (id) await updateCautionSet(id, payload);
    else await insertCautionSet(payload);
    closeModal('csetEditModal');
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
  // 단계 DOM 재생성 후 미리보기 트리거 (add/remove/move/reload 경로 커버 — 타이핑은 bubble된 input 이벤트가 자체 처리)
  window.dispatchEvent(new Event('reverb:campFormChange'));
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

// ══════════════════════════════════════
// 캠페인 폼: 주의사항 번들 + 인라인 items 편집 (migration 069)
//   참여방법(_psetState) 패턴 완전 미러링
// ══════════════════════════════════════
const _csetState = { new: [], edit: [] }; // 모드별 현재 items 배열
const _csetCache = { new: [], edit: [] }; // 모드별 드롭다운 원본 번들 리스트

async function populateCampCsetDropdown(formMode, recruitType, selectedSetId) {
  const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  if (!sel) return;
  let sets = [];
  try { sets = await fetchCautionSets(recruitType); } catch(e) { sets = []; }
  _csetCache[formMode] = sets;
  sel.innerHTML = `<option value="">— 번들 선택 —</option>` +
    sets.map(s => `<option value="${esc(s.id)}" ${selectedSetId===s.id?'selected':''}>${esc(s.name_ko)}</option>`).join('');
}

function onCsetSelectChange(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  if (!sel) return;
  const set = _csetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  const hasContent = _csetState[formMode].some(s => !isCsetItemEmpty(s.html_ko, s.html_ja));
  const apply = () => {
    _csetState[formMode] = (set.items||[]).map(normalizeCsetItem);
    renderCampCautionItems(formMode);
  };
  if (!hasContent) { apply(); return; }
  showConfirm('현재 입력된 주의사항을 덮어쓸까요?').then(ok => { if (ok) apply(); else sel.value = ''; });
}

async function reloadCsetFromBundle(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  if (!sel || !sel.value) { toast('먼저 번들을 선택하세요','error'); return; }
  const set = _csetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  const ok = await showConfirm(`번들 "${set.name_ko}"의 현재 내용으로 덮어쓸까요?`);
  if (!ok) return;
  _csetState[formMode] = (set.items||[]).map(normalizeCsetItem);
  renderCampCautionItems(formMode);
}

function renderCampCautionItems(formMode) {
  const wrap = $(formMode === 'edit' ? 'editCampCautionItems' : 'newCampCautionItems');
  if (!wrap) return;
  const arr = _csetState[formMode];
  if (!arr.length) {
    wrap.innerHTML = `<div style="font-size:12px;color:var(--muted);padding:8px 0">주의사항 항목이 없습니다. 번들을 선택하거나 항목을 추가하세요.</div>`;
    window.dispatchEvent(new Event('reverb:campFormChange'));
    return;
  }
  wrap.innerHTML = arr.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">항목 ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="moveCampCsetItem('${formMode}',${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===arr.length-1?'disabled':''} onclick="moveCampCsetItem('${formMode}',${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" onclick="removeCampCsetItem('${formMode}',${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_csetState['${formMode}'][${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">本文 (日本語)</div>
          ${miniEditorHtml(s.html_ja, `_csetState['${formMode}'][${idx}].html_ja=this.innerHTML`, '本文 (日本語)')}
        </div>
      </div>
    </div>
  `).join('');
  window.dispatchEvent(new Event('reverb:campFormChange'));
}

function addCampCsetItem(formMode) {
  if (_csetState[formMode].length >= MAX_CSET_ITEMS) { toast(`항목은 최대 ${MAX_CSET_ITEMS}개까지`,'error'); return; }
  _csetState[formMode].push(makeBlankCsetItem());
  renderCampCautionItems(formMode);
}

function removeCampCsetItem(formMode, idx) {
  _csetState[formMode].splice(idx, 1);
  renderCampCautionItems(formMode);
}

function moveCampCsetItem(formMode, idx, dir) {
  const arr = _csetState[formMode];
  const j = idx + dir;
  if (j < 0 || j >= arr.length) return;
  const [s] = arr.splice(idx, 1);
  arr.splice(j, 0, s);
  renderCampCautionItems(formMode);
}

// 저장 payload: {caution_set_id, caution_items} — items 는 {html_ko, html_ja} 형식 + 저장 전 sanitize
function collectCampCsetPayload(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _csetState[formMode]
    .filter(s => !isCsetItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  return {
    caution_set_id: sel?.value || null,
    caution_items: items  // 빈 배열이면 '[]'로 저장됨 (NOT NULL)
  };
}

// ══════════════════════════════════════
// 캠페인 폼: 참여방법/주의사항을 요약 카드 + 편집 모달로 분리
//   메인 폼이 세로로 너무 길어져서 두 섹션의 인라인 편집 UI 를 모달로 이동.
//   편집 form-group DOM 은 숨겨둔 상태로 원위치에 유지되며, 모달 열기 시
//   일시적으로 campBundleModalHost 로 이동하고 닫을 때 원위치 복귀.
// ══════════════════════════════════════
let _campBundleModalReturn = null;  // { group, parent, next, kind, formMode }

function renderCampBundleSummary(kind, formMode) {
  const summaryId = (formMode === 'edit' ? 'editCamp' : 'newCamp') + (kind === 'pset' ? 'PsetSummary' : 'CsetSummary');
  const summary = $(summaryId);
  if (!summary) return;
  const body = summary.querySelector('.bundle-summary-body');
  if (!body) return;
  if (kind === 'pset') {
    const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
    const bundleName = sel?.selectedOptions?.[0]?.text && sel.value ? sel.selectedOptions[0].text : '';
    const steps = _psetState[formMode] || [];
    if (!steps.length) {
      body.innerHTML = '<div class="summary-head" style="color:var(--muted)">번들 미선택 — 편집 버튼으로 단계를 추가하거나 번들을 선택하세요</div>';
      return;
    }
    const renderStep = (s, i, lang) => {
      const title = lang === 'ko' ? (s.title_ko || s.title_ja || '—') : (s.title_ja || s.title_ko || '—');
      const desc  = lang === 'ko' ? (s.desc_ko || s.desc_ja || '') : (s.desc_ja || s.desc_ko || '');
      return `<div class="summary-step"><div class="summary-step-title">STEP ${i+1} · ${esc(title)}</div>${desc?`<div class="summary-step-desc">${esc(desc)}</div>`:''}</div>`;
    };
    const koCol = steps.map((s,i) => renderStep(s, i, 'ko')).join('');
    const jaCol = steps.map((s,i) => renderStep(s, i, 'ja')).join('');
    body.innerHTML = `<div class="summary-head">${bundleName ? `<span style="font-weight:600">${esc(bundleName)}</span> · ` : ''}<span style="color:var(--muted)">${steps.length}단계</span></div>`
      + `<div class="summary-lang-grid"><div class="summary-lang-col"><div class="summary-lang-title">한국어</div>${koCol}</div><div class="summary-lang-col"><div class="summary-lang-title">日本語</div>${jaCol}</div></div>`;
  } else {
    const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
    const bundleName = sel?.selectedOptions?.[0]?.text && sel.value ? sel.selectedOptions[0].text : '';
    const items = _csetState[formMode] || [];
    if (!items.length) {
      body.innerHTML = '<div class="summary-head" style="color:var(--muted)">번들 미선택 — 편집 버튼으로 항목을 추가하거나 번들을 선택하세요</div>';
      return;
    }
    const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
    const koCol = items.map(it => `<li>${sanitize(it.html_ko || it.html_ja || '')}</li>`).join('');
    const jaCol = items.map(it => `<li>${sanitize(it.html_ja || it.html_ko || '')}</li>`).join('');
    body.innerHTML = `<div class="summary-head">${bundleName ? `<span style="font-weight:600">${esc(bundleName)}</span> · ` : ''}<span style="color:var(--muted)">${items.length}개 항목</span></div>`
      + `<div class="summary-lang-grid"><div class="summary-lang-col"><div class="summary-lang-title">한국어</div><ul class="summary-lang-list">${koCol}</ul></div><div class="summary-lang-col"><div class="summary-lang-title">日本語</div><ul class="summary-lang-list">${jaCol}</ul></div></div>`;
  }
}

function openCampBundleModal(kind, formMode) {
  const groupId = (formMode === 'edit' ? 'editCamp' : 'newCamp') + (kind === 'pset' ? 'PsetGroup' : 'CsetGroup');
  const group = $(groupId);
  const host = $('campBundleModalHost');
  if (!group || !host) return;
  // DOM 이동: 원위치 복귀를 위해 현재 부모와 다음 형제 저장
  _campBundleModalReturn = {
    group: group,
    parent: group.parentNode,
    next: group.nextSibling,
    kind: kind,
    formMode: formMode
  };
  group.style.display = '';  // 모달 안에서는 보이게
  host.innerHTML = '';
  host.appendChild(group);
  const title = $('campBundleModalTitle');
  if (title) title.textContent = (kind === 'pset' ? '참여방법' : '주의사항') + ' 편집';
  openModal('campBundleModal');
}

function closeCampBundleModal() {
  const ret = _campBundleModalReturn;
  if (ret && ret.group && ret.parent) {
    ret.group.style.display = 'none';  // 원위치에서는 숨김
    if (ret.next) ret.parent.insertBefore(ret.group, ret.next);
    else ret.parent.appendChild(ret.group);
  }
  closeModal('campBundleModal');
  if (ret) renderCampBundleSummary(ret.kind, ret.formMode);
  _campBundleModalReturn = null;
}

async function loadMyAdminInfo() {
  if (!currentAdminInfo && db) {
    const {data} = await db?.from('admins').select('*').eq('auth_id', currentUser?.id).maybeSingle();
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
    await db?.from('admins').update({name}).eq('id', currentAdminInfo.id);
    currentAdminInfo.name = name;
    updateSidebarProfile();
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
      await retryWithRefresh(() => db?.from('admins').update({name, role}).eq('id', editId));
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
var _addressDistChart = null;

// 일본 도도부현 한국어 표기 매핑 (47개 전체)
var PREFECTURE_KO = {
  '北海道':'홋카이도','青森県':'아오모리현','岩手県':'이와테현','宮城県':'미야기현',
  '秋田県':'아키타현','山形県':'야마가타현','福島県':'후쿠시마현','茨城県':'이바라키현',
  '栃木県':'도치기현','群馬県':'군마현','埼玉県':'사이타마현','千葉県':'지바현',
  '東京都':'도쿄도','神奈川県':'가나가와현','新潟県':'니가타현','富山県':'도야마현',
  '石川県':'이시카와현','福井県':'후쿠이현','山梨県':'야마나시현','長野県':'나가노현',
  '岐阜県':'기후현','静岡県':'시즈오카현','愛知県':'아이치현','三重県':'미에현',
  '滋賀県':'시가현','京都府':'교토부','大阪府':'오사카부','兵庫県':'효고현',
  '奈良県':'나라현','和歌山県':'와카야마현','鳥取県':'돗토리현','島根県':'시마네현',
  '岡山県':'오카야마현','広島県':'히로시마현','山口県':'야마구치현','徳島県':'도쿠시마현',
  '香川県':'가가와현','愛媛県':'에히메현','高知県':'고치현','福岡県':'후쿠오카현',
  '佐賀県':'사가현','長崎県':'나가사키현','熊本県':'구마모토현','大分県':'오이타현',
  '宮崎県':'미야자키현','鹿児島県':'가고시마현','沖縄県':'오키나와현'
};

// 파이 차트용 컬러 팔레트 (Top 10 + 미등록/해외)
var ADDRESS_DIST_COLORS = [
  '#E8344E','#5B7CFF','#4ECDC4','#F4A43A','#9B59B6',
  '#5BA86E','#E87A96','#3E79B8','#D49158','#7CA565'
];

// Chart.js 옵션 빌더 — legend/tooltip 퍼센티지 포맷 (렌더 함수 길이 축소 목적 분리)
function buildAddressChartOptions(stats) {
  const totalForPct = stats && stats.total ? stats.total : 0;
  const pctOf = (value) => totalForPct ? ((value / totalForPct) * 100).toFixed(1) : '0.0';
  return {
    responsive: true,
    maintainAspectRatio: false,
    cutout: '55%',
    plugins: {
      legend: {
        position: 'right',
        labels: {
          boxWidth: 12,
          padding: 10,
          font: { size: 12 },
          generateLabels(chart) {
            const data = chart.data;
            return data.labels.map((label, i) => {
              const value = data.datasets[0].data[i];
              return {
                text: `${label}  ${value}명 (${pctOf(value)}%)`,
                fillStyle: data.datasets[0].backgroundColor[i],
                strokeStyle: '#fff',
                lineWidth: 1,
                index: i
              };
            });
          }
        }
      },
      tooltip: {
        callbacks: {
          label: ctx => `${ctx.label}: ${ctx.parsed}명 (${pctOf(ctx.parsed)}%)`
        }
      }
    }
  };
}

// 배송지(도도부현) 분포 파이 차트 렌더 — Top N + 미등록 + 해외
// - loadAdminData가 이미 가져온 users 배열을 받아 중복 쿼리 없이 집계
function renderAddressDistribution(users) {
  const canvas = $('addressDistChart');
  const totalLabel = $('addressDistTotal');
  const emptyLabel = $('addressDistEmpty');
  const loading = $('addressDistLoading');
  if (!canvas) return;

  try {
    const stats = computePrefectureStats(users || []);
    if (loading) loading.style.display = 'none';
    if (totalLabel) totalLabel.textContent = `전체 ${stats.total}명`;

    // 라벨을 한국어로 변환 (매핑 없으면 원문 유지)
    const labels = stats.top.map(r => PREFECTURE_KO[r.name] || r.name);
    const values = stats.top.map(r => r.count);
    const colors = stats.top.map((_, i) => ADDRESS_DIST_COLORS[i % ADDRESS_DIST_COLORS.length]);

    if (stats.unregistered > 0) { labels.push('미등록'); values.push(stats.unregistered); colors.push('#BDBDC4'); }
    if (stats.overseas > 0) { labels.push('해외'); values.push(stats.overseas); colors.push('#8A8A90'); }

    if (_addressDistChart) { _addressDistChart.destroy(); _addressDistChart = null; }

    if (labels.length === 0) {
      canvas.style.display = 'none';
      if (emptyLabel) emptyLabel.style.display = 'block';
      return;
    }

    canvas.style.display = 'block';
    if (emptyLabel) emptyLabel.style.display = 'none';

    _addressDistChart = new Chart(canvas.getContext('2d'), {
      type: 'doughnut',
      data: {
        labels,
        datasets: [{
          data: values,
          backgroundColor: colors,
          borderColor: '#fff',
          borderWidth: 2
        }]
      },
      options: buildAddressChartOptions(stats)
    });
  } catch (e) {
    if (loading) loading.style.display = 'none';
    console.error('[addressDist] render failed:', e);
  }
}

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
  const hasPaypal = users.filter(u => u.paypal_email).length;

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
    bar('PayPal', pct(hasPaypal), '#28C76F', false);
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
  resetMultiFilter('delivKindMulti', '전체 타입');
  resetMultiFilter('delivStatusMulti', '전체 상태');
  resetMultiFilter('delivCampMulti', '전체 캠페인');
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
  await renderDeliverablesList();  // 끝에서 refreshDelivSidebarBadge 호출됨
}

// 사이드바 "결과물 관리" 메뉴 옆 검수 대기(pending) 배지 갱신
async function refreshDelivSidebarBadge() {
  const el = $('adminDelivSi');
  if (!el) return;
  try {
    const n = await fetchPendingDeliverableCount();
    el.innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">fact_check</span><span class="si-text">결과물 관리</span>${n>0?`<span class="admin-si-badge">${n>999?'999+':n}</span>`:''}`;
  } catch(e) { /* 무시 */ }
}

var delivLazy = null;
const DELIV_PAGE_SIZE = 50;

async function renderDeliverablesList() {
  const tbody = $('delivTableBody');
  if (!tbody) return;
  tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  // 캠페인 리스트 로드 + 결과물타입↔캠페인 쌍별 연동
  const campsForFilter = await fetchCampaigns().catch(() => []);
  const sortedCampsForFilter = campsForFilter.slice().sort((a,b) => new Date(b.created_at) - new Date(a.created_at));

  // recruit_type ↔ kind 매핑
  // monitor → receipt (영수증), gifting/visit → post (게시물 URL)
  const RECRUIT_TYPE_TO_KIND = { monitor: 'receipt', gifting: 'post', visit: 'post' };
  const KIND_TO_RECRUIT_TYPES = { receipt: ['monitor'], post: ['gifting', 'visit'] };

  const delivKindValsRaw = getMultiFilterValues('delivKindMulti');
  const delivCampValsRaw = getMultiFilterValues('delivCampMulti');

  // 캠페인 옵션: kind 필터 있으면 해당 kind의 recruit_type 캠페인만
  const allowedRecruitTypes = delivKindValsRaw.length > 0
    ? [...new Set(delivKindValsRaw.flatMap(k => KIND_TO_RECRUIT_TYPES[k] || []))]
    : null; // null = 제약 없음
  const campOptionsSource = allowedRecruitTypes
    ? sortedCampsForFilter.filter(c => allowedRecruitTypes.includes(c.recruit_type))
    : sortedCampsForFilter;

  // kind 옵션: 캠페인 필터 있으면 선택 캠페인들의 recruit_type → 대응 kind 합집합
  const ALL_KINDS = ['receipt', 'post'];
  const KIND_LABEL = { receipt: '영수증', post: '게시물 URL' };
  const availableKinds = delivCampValsRaw.length > 0
    ? [...new Set(campsForFilter.filter(c => delivCampValsRaw.includes(c.id)).map(c => RECRUIT_TYPE_TO_KIND[c.recruit_type]).filter(Boolean))]
    : ALL_KINDS;

  // stale 감지
  const campStale = delivCampValsRaw.filter(v => !campOptionsSource.some(c => c.id === v));
  const kindStale = delivKindValsRaw.filter(v => !availableKinds.includes(v));
  if (campStale.length > 0 && typeof toast === 'function') toast(`선택한 캠페인 ${campStale.length}건이 결과물 타입 필터에 맞지 않아 해제되었습니다`, 'info');
  if (kindStale.length > 0 && typeof toast === 'function') toast(`선택한 결과물 타입 ${kindStale.length}건이 캠페인 필터에 맞지 않아 해제되었습니다`, 'info');

  // 드롭다운 동기화
  syncCampMultiFilter('delivCampMulti', campOptionsSource, () => renderDeliverablesList());
  syncMultiFilter('delivKindMulti', '전체 타입',
    availableKinds.map(k => ({ value: k, label: KIND_LABEL[k] || k })),
    () => renderDeliverablesList());

  const delivStatusVals = getMultiFilterValues('delivStatusMulti');
  const delivKindVals = getMultiFilterValues('delivKindMulti');
  const delivCampVals = getMultiFilterValues('delivCampMulti');
  const status = delivStatusVals.length === 1 ? delivStatusVals[0] : 'all';
  const kind = delivKindVals.length === 1 ? delivKindVals[0] : 'all';
  const campId = delivCampVals.length === 1 ? delivCampVals[0] : 'all';
  const search = ($('delivSearch')?.value || '').trim().toLowerCase();
  const rows = await fetchDeliverables({status, kind, campaign_id: campId});
  _delivCache = rows;
  // 다중 선택 시 클라이언트 필터링
  let filtered = rows.slice();
  if (delivStatusVals.length > 1) filtered = filtered.filter(r => delivStatusVals.includes(r.status));
  if (delivKindVals.length > 1) filtered = filtered.filter(r => delivKindVals.includes(r.kind));
  if (delivCampVals.length > 1) filtered = filtered.filter(r => delivCampVals.includes(r.campaign_id));
  if (search) filtered = filtered.filter(r => {
    const n = (r.influencers?.name || '') + ' ' + (r.influencers?.name_kana || '') + ' ' + (r.influencers?.email || '');
    const camp = r.campaigns || {};
    return n.toLowerCase().includes(search)
      || (camp.title || '').toLowerCase().includes(search)
      || (camp.brand || '').toLowerCase().includes(search)
      || (camp.campaign_no || '').toLowerCase().includes(search);
  });
  updateFilterResetBtn('btnDelivFilterReset', ['delivKindMulti','delivStatusMulti','delivCampMulti'], 'delivSearch');
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
  const renderDelivRow = (d) => {
    const kindBadge = d.kind === 'receipt'
      ? '<span style="display:inline-flex;align-items:center;gap:3px;background:#fdf5fb;color:var(--dark-pink);font-size:11px;font-weight:600;padding:3px 8px;border-radius:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">receipt</span> 영수증</span>'
      : '<span style="display:inline-flex;align-items:center;gap:3px;background:#eef5ff;color:#2c5fa8;font-size:11px;font-weight:600;padding:3px 8px;border-radius:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">link</span> 게시물</span>';
    const camp = d.campaigns || {};
    const inf = d.influencers || {};
    const stBadge = delivStatusBadge(d.status);
    const infName = esc(inf.name || '—');
    const infEmail = esc(inf.email || '');
    const infLine = inf.line_id ? `LINE: ${esc(inf.line_id)}` : '';
    const infSub = infEmail + (infLine ? `<br>${infLine}` : '');
    const reviewedCell = d.reviewed_at
      ? `<span style="font-size:12px">${formatDateTime(d.reviewed_at)}</span>`
      : '<span style="font-size:11px;color:var(--muted)">—</span>';
    return `<tr data-id="${esc(d.id)}">
      <td>${kindBadge}</td>
      <td><div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">${getRecruitTypeBadgeKoSm(camp.recruit_type)}${camp.campaign_no ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted)">${esc(camp.campaign_no)}</span>` : ''}</div>${esc(camp.title || '—')}<div style="font-size:10px;color:var(--muted)">${esc(camp.brand || '')}</div></td>
      <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${inf.id||''}')">${infName}${influencerStatusBadges(inf)}</div>${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}</td>
      <td style="font-size:12px">${formatDateTime(d.submitted_at)}</td>
      <td>${reviewedCell}</td>
      <td>${stBadge}</td>
      <td><button class="btn btn-ghost btn-xs" onclick="openDelivDetail('${d.id}')">상세</button></td>
    </tr>`;
  };
  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (delivLazy) delivLazy.destroy();
  delivLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows: filtered,
    renderRow: renderDelivRow,
    pageSize: DELIV_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 결과물이 없습니다.</td></tr>',
  });
  // 검수 후 사이드바 배지(검수 대기 개수) 자동 동기화
  refreshDelivSidebarBadge();
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

// ══════════════════════════════════════
// BRAND APPLICATIONS (광고주 신청 관리 — PR-4)
// ══════════════════════════════════════

var _brandApps = [];          // 캐시된 전체 목록
var _brandAppSort = {field: 'created', dir: 'desc'};
var _brandAppCurrentId = null; // 상세 모달 열린 신청 ID

// 상태 라벨·컬러 (객체 키 순서가 드롭다운 옵션 순서)
var BRAND_APP_STATUS = {
  'new':                 {label:'신규',             color:'#C33',   bg:'#FEE'},
  'reviewing':           {label:'검토중',           color:'#B88',   bg:'#FFE'},
  'quoted':              {label:'견적 전달',        color:'#08A',   bg:'#DEF'},
  'paid':                {label:'입금완료',         color:'#6A2',   bg:'#EFE'},
  'orient_sheet_sent':   {label:'오리엔시트 전달',  color:'#735',   bg:'#F2E6F0'},
  'schedule_sent':       {label:'일정 전달',        color:'#A36',   bg:'#FDEEF4'},
  'campaign_registered': {label:'캠페인 등록',      color:'#274',   bg:'#E6F3E8'},
  'done':                {label:'최종완료',         color:'#555',   bg:'#EEE'},
  'rejected':            {label:'반려',             color:'#999',   bg:'#F5F5F5'}
};

function brandAppStatusBadge(status) {
  var s = BRAND_APP_STATUS[status] || {label: status, color:'#666', bg:'#EEE'};
  return '<span style="background:'+s.bg+';color:'+s.color+';font-size:11px;font-weight:700;padding:2px 8px;border-radius:4px">'+esc(s.label)+'</span>';
}

// 요청사항 셀: 2줄 말줄임 + 더보기 모달 (msgCell 패턴 재사용)
// openMsgModal 헬퍼 공유 — data-msg 안 HTML은 esc 후 주입
function brandAppNoteCell(text) {
  if (!text) return '<span style="color:var(--muted);font-size:12px">—</span>';
  var safe = esc(text);
  var short = '<div style="max-width:220px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-size:12px;color:var(--ink);line-height:1.4">' + safe + '</div>';
  // 40자 또는 개행 포함 시 "더보기" 노출 (2줄 미리보기에서 잘릴 가능성 있음)
  var hasMore = text.length > 40 || /\n/.test(text);
  var more = hasMore
    ? '<a href="javascript:void(0)" style="font-size:10px;color:var(--pink);text-decoration:underline;cursor:pointer;margin-top:2px;display:inline-block" onclick="event.stopPropagation();openMsgModal(this)" data-msg="' + safe + '">더보기</a>'
    : '';
  return short + more;
}

// 뱃지 스타일 상태 select 공통 렌더러
function brandAppStatusSelectStyled(opts) {
  var status = opts.status;
  var s = BRAND_APP_STATUS[status] || {color:'#666', bg:'#EEE'};
  var optionsHtml = Object.keys(BRAND_APP_STATUS).map(function(k) {
    return '<option value="'+k+'"'+(status===k?' selected':'')+'>'+esc(BRAND_APP_STATUS[k].label)+'</option>';
  }).join('');
  var sizeSm = opts.size === 'sm';
  var padding = sizeSm ? '3px 22px 3px 10px' : '7px 28px 7px 14px';
  var fontSize = sizeSm ? '11px' : '13px';
  var arrowPos1 = sizeSm ? 'calc(100% - 10px) 8px' : 'calc(100% - 12px) 50%';
  var arrowPos2 = sizeSm ? 'calc(100% - 6px) 8px' : 'calc(100% - 8px) 50%';
  var arrowSize = sizeSm ? '4px 4px' : '5px 5px';
  var extraAttrs = (opts.id ? ' id="'+esc(opts.id)+'"' : '')
    + (opts.disabled ? ' disabled' : '')
    + (opts.onchange ? ' onchange="'+opts.onchange+'"' : '')
    + (opts.onclick ? ' onclick="'+opts.onclick+'"' : '');
  return '<select class="brand-app-status-sel"' + extraAttrs
    + ' style="background:'+s.bg+';color:'+s.color+';font-size:'+fontSize+';font-weight:700;padding:'+padding+';border-radius:6px;'
    + 'border:0;cursor:pointer;appearance:none;-webkit-appearance:none;'
    + 'background-image:linear-gradient(45deg,transparent 50%,'+s.color+' 50%),linear-gradient(-45deg,transparent 50%,'+s.color+' 50%);'
    + 'background-position:'+arrowPos1+','+arrowPos2+';background-size:'+arrowSize+';background-repeat:no-repeat">'
    + optionsHtml + '</select>';
}

// 리스트용 shortcut (즉시 저장)
function brandAppStatusSelect(a) {
  return brandAppStatusSelectStyled({
    status: a.status,
    size: 'sm',
    onchange: 'quickChangeBrandAppStatus(\''+esc(a.id)+'\', this.value, '+a.version+')',
    onclick: 'event.stopPropagation()'
  });
}

// 상세 모달 내 select 색상 자동 갱신 (선택만 변경, 저장은 별도 버튼)
function onBrandAppEditStatusChange(sel) {
  var s = BRAND_APP_STATUS[sel.value] || {color:'#666', bg:'#EEE'};
  sel.style.background = s.bg;
  sel.style.color = s.color;
  sel.style.backgroundImage = 'linear-gradient(45deg,transparent 50%,' + s.color + ' 50%),linear-gradient(-45deg,transparent 50%,' + s.color + ' 50%)';
  sel.style.backgroundRepeat = 'no-repeat';
}

// 리스트에서 즉시 상태 변경 (낙관적 락 체크)
async function quickChangeBrandAppStatus(id, newStatus, expectedVersion) {
  var cur = _brandApps.find(function(a){ return a.id === id; });
  if (!cur) return;
  if (cur.status === newStatus) return;
  var patch = {status: newStatus};
  // 최초 검수 진입 시 reviewed_by/at 기록
  if (cur.status === 'new' && newStatus !== 'new') {
    patch.reviewed_by = currentUser?.id || null;
    patch.reviewed_at = new Date().toISOString();
  }
  var result = await updateBrandApplication(id, patch, expectedVersion);
  if (result.conflict) {
    toast('다른 관리자가 먼저 처리했습니다. 목록을 새로고침합니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('상태 변경 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    await loadBrandApplications();
    return;
  }
  toast('상태가 ' + (BRAND_APP_STATUS[newStatus]?.label || newStatus) + '(으)로 변경됨');
  await loadBrandApplications();
}

function brandAppFormLabel(formType) {
  return formType === 'reviewer' ? 'Qoo10 리뷰어' : (formType === 'seeding' ? '나노 시딩' : formType);
}

// 광고주가 입력한 URL을 http/https만 허용 (javascript:, data: 스킴 차단)
function safeBrandUrl(url) {
  if (!url) return null;
  try {
    var u = new URL(url);
    return (u.protocol === 'https:' || u.protocol === 'http:') ? url : null;
  } catch(e) { return null; }
}

function fmtKrw(n) {
  if (n === null || n === undefined || n === '') return '—';
  var v = Number(n);
  if (!isFinite(v) || v === 0) return '—';
  return '₩ ' + v.toLocaleString('ko-KR');
}

function fmtDate(iso) {
  if (!iso) return '—';
  try {
    var d = new Date(iso);
    return d.toLocaleDateString('ko-KR', {year:'numeric', month:'2-digit', day:'2-digit'}).replace(/\s+/g,'');
  } catch(e) { return '—'; }
}

// ══════════════════════════════════════
// 캠페인 결과물 엑셀 다운로드 (exceljs 지연 로드 + 이미지 임베드)
// ══════════════════════════════════════
var _excelJsLoading = null;
function loadExcelJS() {
  if (window.ExcelJS) return Promise.resolve();
  if (_excelJsLoading) return _excelJsLoading;
  _excelJsLoading = new Promise(function(resolve, reject) {
    var s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js';
    s.onload = function() { resolve(); };
    s.onerror = function() { reject(new Error('ExcelJS 로드 실패')); };
    document.head.appendChild(s);
  });
  return _excelJsLoading;
}

// Supabase Storage 이미지를 Image→Canvas를 거쳐 jpeg ArrayBuffer로 변환
// fetch 기반보다 CORS·binary 안정성이 좋고 webp 등 예외 포맷도 jpeg로 통일
function imgToJpegArrayBuffer(url, maxW, maxH) {
  return new Promise(function(resolve, reject) {
    var img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = function() {
      try {
        var ratio = Math.min((maxW || 800) / img.width, (maxH || 800) / img.height, 1);
        var w = Math.max(1, Math.round(img.width * ratio));
        var h = Math.max(1, Math.round(img.height * ratio));
        var canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        canvas.toBlob(function(blob) {
          if (!blob) { reject(new Error('canvas toBlob returned null')); return; }
          blob.arrayBuffer().then(function(buf) {
            resolve({buffer: buf, ext: 'jpeg'});
          }).catch(reject);
        }, 'image/jpeg', 0.85);
      } catch(e) { reject(e); }
    };
    img.onerror = function() { reject(new Error('image load failed: ' + url)); };
    img.src = url;
  });
}

// 캠페인별 신청자 목록 엑셀 다운로드 (전체 상태, 4채널 SNS+팔로워 포함)
async function exportCampaignApplicationsExcel(campId) {
  try {
    document.querySelectorAll('.camp-more-menu').forEach(function(d){ d.remove(); });

    var camp = (Array.isArray(allCampaigns) ? allCampaigns : []).find(function(c){ return c.id === campId; });
    if (!camp && db) {
      var res = await db?.from('campaigns').select('*').eq('id', campId).maybeSingle();
      camp = res?.data;
    }
    if (!camp) { toast('캠페인을 찾을 수 없습니다', 'error'); return; }

    toast('엑셀 생성 중...');
    await loadExcelJS();

    var apps = await fetchApplications({ campaign_id: campId });
    if (!apps || apps.length === 0) { toast('신청자가 없습니다', 'error'); return; }

    var users = await fetchInfluencers();
    var userByEmail = {};
    (users || []).forEach(function(u){ if (u.email) userByEmail[u.email] = u; });

    var statusLabel = function(s) {
      if (s === 'approved') return '승인';
      if (s === 'pending') return '심사중';
      if (s === 'rejected') return '미승인';
      return s || '';
    };
    var snsHandleStr = function(channel, raw) {
      if (!raw) return '';
      if (typeof extractSnsHandle === 'function') {
        var h = extractSnsHandle(channel, raw);
        return h ? '@' + h : '';
      }
      return String(raw).trim();
    };
    var addrStr = function(u, fallbackAddress) {
      if (u && u.zip) {
        return '〒' + u.zip + ' ' + (u.prefecture || '') + (u.city || '') + (u.building ? ' ' + u.building : '');
      }
      return fallbackAddress || '';
    };

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var sheetName = (camp.campaign_no || camp.title || '신청자').substring(0, 28);
    var ws = wb.addWorksheet(sheetName);

    ws.columns = [
      { header: '신청일',            key: 'created',    width: 20 },
      { header: '상태',              key: 'status',     width: 10 },
      { header: '인플루언서명',      key: 'name',       width: 18 },
      { header: '이메일',            key: 'email',      width: 26 },
      { header: '연락처',            key: 'phone',      width: 16 },
      { header: 'Instagram',         key: 'ig',         width: 22 },
      { header: 'Instagram 팔로워', key: 'igF',        width: 14 },
      { header: 'TikTok',            key: 'tt',         width: 22 },
      { header: 'TikTok 팔로워',    key: 'ttF',        width: 14 },
      { header: 'X',                 key: 'x',          width: 22 },
      { header: 'X 팔로워',          key: 'xF',         width: 14 },
      { header: 'YouTube',           key: 'yt',         width: 22 },
      { header: 'YouTube 팔로워',    key: 'ytF',        width: 14 },
      { header: '배송지',            key: 'address',    width: 40 },
      { header: '신청 메시지',       key: 'message',    width: 40 },
      { header: '심사일',            key: 'reviewedAt', width: 20 },
      { header: '리뷰어',            key: 'reviewedBy', width: 16 }
    ];

    var header = ws.getRow(1);
    header.font = { bold: true, color: { argb: 'FF222222' } };
    header.alignment = { vertical: 'middle', horizontal: 'center' };
    header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    header.height = 22;

    apps.forEach(function(a) {
      var u = userByEmail[a.user_email] || {};
      var createdStr = '';
      if (a.created_at) {
        try { createdStr = new Date(a.created_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { createdStr = String(a.created_at); }
      }
      var reviewedStr = '';
      if (a.reviewed_at) {
        try { reviewedStr = new Date(a.reviewed_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { reviewedStr = String(a.reviewed_at); }
      }
      ws.addRow({
        created:    createdStr,
        status:     statusLabel(a.status),
        name:       u.name_kanji || u.name || a.user_name || '',
        email:      a.user_email || '',
        phone:      formatPhoneDisplay(u.phone),
        ig:         snsHandleStr('instagram', u.ig || a.ig_id || a.user_ig),
        igF:        Number(u.ig_followers || 0),
        tt:         snsHandleStr('tiktok', u.tiktok),
        ttF:        Number(u.tiktok_followers || 0),
        x:          snsHandleStr('x', u.x),
        xF:         Number(u.x_followers || 0),
        yt:         snsHandleStr('youtube', u.youtube),
        ytF:        Number(u.youtube_followers || 0),
        address:    addrStr(u, a.address),
        message:    a.message || '',
        reviewedAt: reviewedStr,
        reviewedBy: a.reviewed_by || ''
      });
    });

    ['igF','ttF','xF','ytF'].forEach(function(k) {
      ws.getColumn(k).numFmt = '#,##0';
      ws.getColumn(k).alignment = { horizontal: 'right' };
    });
    ws.getColumn('message').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('address').alignment = { wrapText: true, vertical: 'top' };

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    var ts = new Date();
    var yyyy = ts.getFullYear();
    var mm = String(ts.getMonth()+1).padStart(2,'0');
    var dd = String(ts.getDate()).padStart(2,'0');
    var safeTitle = (camp.campaign_no || camp.title || 'campaign').replace(/[\\\/:*?"<>|]/g, '_').substring(0, 40);
    a.download = `applicants-${safeTitle}-${yyyy}${mm}${dd}.xlsx`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + apps.length + '건)');
  } catch (e) {
    console.error('[exportCampaignApplicationsExcel]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  }
}

// 브랜드 서베이 신청 목록 엑셀 다운로드 (현재 필터·정렬 결과)
async function exportBrandApplicationsExcel() {
  try {
    var res = getFilteredBrandApps();
    var list = res.list;
    if (!list || list.length === 0) { toast('내보낼 데이터가 없습니다', 'error'); return; }

    toast('엑셀 생성 중...');
    await loadExcelJS();

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var ws = wb.addWorksheet('브랜드 서베이');

    ws.columns = [
      { header: '신청일',              key: 'created',     width: 20 },
      { header: '신청번호',            key: 'no',          width: 22 },
      { header: '폼 종류',             key: 'form',        width: 14 },
      { header: '업체/브랜드명',       key: 'brand',       width: 28 },
      { header: '담당자명',            key: 'contact',     width: 14 },
      { header: '담당자이메일',        key: 'email',       width: 28 },
      { header: '연락처',              key: 'phone',       width: 18 },
      { header: '세금계산서 발행주소', key: 'billing',     width: 28 },
      { header: '예상견적',            key: 'estimated',   width: 16 },
      { header: '상태',                key: 'status',      width: 12 },
      { header: '요청사항',            key: 'requestNote', width: 40 }
    ];

    // 헤더 스타일
    var header = ws.getRow(1);
    header.font = { bold: true, color: { argb: 'FF222222' } };
    header.alignment = { vertical: 'middle', horizontal: 'center' };
    header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    header.height = 22;

    list.forEach(function(a) {
      var createdStr = '';
      if (a.created_at) {
        try { createdStr = new Date(a.created_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { createdStr = String(a.created_at); }
      }
      ws.addRow({
        created:     createdStr,
        no:          a.application_no || '',
        form:        brandAppFormLabel(a.form_type),
        brand:       a.brand_name || '',
        contact:     a.contact_name || '',
        email:       a.email || '',
        phone:       formatPhoneDisplay(a.phone),
        billing:     a.billing_email || '',
        estimated:   (a.estimated_krw == null || a.estimated_krw === '') ? '' : Number(a.estimated_krw),
        status:      (BRAND_APP_STATUS[a.status]?.label) || a.status || '',
        requestNote: a.request_note || ''
      });
    });

    // 예상견적 통화 포맷 (열 단위)
    ws.getColumn('estimated').numFmt = '#,##0';
    ws.getColumn('estimated').alignment = { horizontal: 'right' };

    // 데이터 행 기본 정렬. 요청사항 셀만 wrapText + top 으로 개행/장문 보존
    // (row.alignment 을 쓰면 셀 단위 설정이 덮어씌워지므로 셀 단위로 개별 설정)
    ws.eachRow({ includeEmpty: false }, function(row, idx) {
      if (idx === 1) return;
      row.eachCell({ includeEmpty: true }, function(cell) {
        cell.alignment = Object.assign({ vertical: 'middle' }, cell.alignment || {});
      });
      var noteCell = row.getCell('requestNote');
      if (noteCell) {
        noteCell.alignment = { wrapText: true, vertical: 'top' };
      }
    });

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    var ts = new Date();
    var yyyy = ts.getFullYear();
    var mm = String(ts.getMonth()+1).padStart(2,'0');
    var dd = String(ts.getDate()).padStart(2,'0');
    a.download = `brand-survey-${yyyy}${mm}${dd}.xlsx`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + list.length + '건)');
  } catch (e) {
    console.error('[exportBrandApplicationsExcel]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  }
}

async function exportCampaignDeliverables(campId) {
  try {
    document.querySelectorAll('.camp-more-menu').forEach(function(d){ d.remove(); });
    toast('엑셀 생성 중...');
    await loadExcelJS();

    // 1) 캠페인 로드
    var camp = (Array.isArray(allCampaigns) ? allCampaigns : []).find(function(c){ return c.id === campId; });
    if (!camp && db) {
      var res = await db?.from('campaigns').select('*').eq('id', campId).maybeSingle();
      camp = res?.data;
    }
    if (!camp) { toast('캠페인을 찾을 수 없습니다', 'error'); return; }

    // 2) 승인된 결과물 로드
    var delivs = await fetchDeliverables({campaign_id: campId, status: 'approved'});
    if (!delivs.length) { toast('승인된 결과물이 없습니다', 'warn'); return; }

    // 3) 영수증 이미지 Image→Canvas로 jpeg 재인코딩 (CORS·포맷 호환성 보장)
    var imgBuffers = {};
    await Promise.all(delivs.filter(function(d){
      return d.kind === 'receipt' && d.receipt_url;
    }).map(async function(d) {
      try {
        var url = d.receipt_url;
        if (url && !/^https?:\/\//.test(url) && db?.storage) {
          var sig = await db.storage.from('campaign-images').createSignedUrl(url, 3600);
          url = sig?.data?.signedUrl;
        }
        if (!url) return;
        var result = await imgToJpegArrayBuffer(url, 400, 400);
        if (result && result.buffer && result.buffer.byteLength > 0) {
          imgBuffers[d.id] = result;
        }
      } catch(e) {
        console.warn('[excel] receipt fetch failed', d.id, e);
      }
    }));

    // 4) 워크북 생성
    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var ws = wb.addWorksheet('결과물');

    // 헤더 (A1:J1, A2:J2) — 총 10열
    ws.mergeCells('A1:J1');
    var t = ws.getCell('A1');
    t.value = (camp.campaign_no ? camp.campaign_no + '  ' : '') + (camp.title || '');
    t.font = {bold: true, size: 14};
    t.alignment = {vertical: 'middle'};
    ws.getRow(1).height = 26;

    ws.mergeCells('A2:J2');
    var m = ws.getCell('A2');
    m.value = '브랜드: ' + (camp.brand || '—') + '  ·  승인 건수: ' + delivs.length + '건  ·  생성일: ' + new Date().toLocaleString('ko-KR');
    m.font = {color: {argb: 'FF888888'}, size: 11};
    ws.getRow(2).height = 20;

    // 컬럼 헤더 (4행)
    ws.getRow(4).values = [
      '인플루언서', 'SNS 아이디', '타입', '제출일', '검수일',
      '상태', '영수증', 'URL', '구매일', '구매금액 (¥)'
    ];
    ws.getRow(4).font = {bold: true, color: {argb: 'FF222222'}};
    ws.getRow(4).fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFF0F0F0'}};
    ws.getRow(4).alignment = {vertical: 'middle', horizontal: 'center'};
    ws.getRow(4).height = 24;

    // 컬럼 너비 (G=영수증 16, H=URL 40)
    ws.columns = [
      {width: 18}, {width: 20}, {width: 10}, {width: 14}, {width: 14},
      {width: 10}, {width: 16}, {width: 40}, {width: 14}, {width: 14}
    ];

    // 본문 행
    delivs.forEach(function(d, i) {
      var rowNum = 5 + i;
      var inf = d.influencers || {};
      var kindLabel = d.kind === 'receipt' ? '영수증' : '게시물';
      var statusLabel = {pending:'검수대기', approved:'승인', rejected:'반려'}[d.status] || d.status;
      var row = ws.getRow(rowNum);
      row.height = 84;

      // post_submissions 최신 URL 우선 (재제출 이력 중 마지막)
      var postUrl = d.post_url || '';
      if (d.kind === 'post' && Array.isArray(d.post_submissions) && d.post_submissions.length) {
        var last = d.post_submissions[d.post_submissions.length - 1];
        postUrl = (last && last.url) || postUrl;
      }

      // 영수증 열 (G): receipt → 이미지만 임베드 / post → 공란
      // URL 열 (H): post → 게시물 URL / receipt → '영수증 보기' 하이퍼링크
      var urlCellValue = '';
      if (d.kind === 'post' && postUrl) {
        urlCellValue = {text: postUrl, hyperlink: postUrl};
      } else if (d.kind === 'receipt' && d.receipt_url) {
        var receiptUrl = /^https?:\/\//.test(d.receipt_url)
          ? d.receipt_url
          : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
        urlCellValue = {text: '영수증 보기', hyperlink: receiptUrl};
      }

      row.values = [
        inf.name || '—',
        inf.primary_sns || '',
        kindLabel,
        d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '',
        d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '',
        statusLabel,
        '',
        urlCellValue,
        d.purchase_date || '',
        d.purchase_amount ? Number(d.purchase_amount) : ''
      ];
      row.alignment = {vertical: 'middle', wrapText: true};

      // 하이퍼링크 셀 스타일 (H열 = URL)
      var urlCell = row.getCell(8);
      if (urlCell && urlCell.value && urlCell.value.hyperlink) {
        urlCell.font = {color: {argb: 'FFE8344E'}, underline: true};
      }

      // 이미지 셀 내부 임베드 (receipt만, G열)
      // 레인지 문자열(`G5:G5`)로 셀 경계에 정확히 앵커 — 셀 이동·크기 조정 시 따라감
      if (d.kind === 'receipt' && imgBuffers[d.id]) {
        var imgId = wb.addImage({buffer: imgBuffers[d.id].buffer, extension: imgBuffers[d.id].ext});
        ws.addImage(imgId, 'G' + rowNum + ':G' + rowNum);
      }
    });

    // 구매금액 숫자 포맷 (J열 = 10번째)
    ws.getColumn(10).numFmt = '#,##0';

    // 5) 파일 저장
    var buffer = await wb.xlsx.writeBuffer();
    var blob = new Blob([buffer], {type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
    var safeBrand = (camp.brand || 'brand').replace(/[\/\\?%*:|"<>]/g, '_');
    var today = new Date().toISOString().slice(0, 10);
    var fname = (camp.campaign_no || camp.id.slice(0,8)) + '_' + safeBrand + '_결과물_' + today + '.xlsx';

    var link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = fname;
    link.click();
    setTimeout(function(){ URL.revokeObjectURL(link.href); }, 1000);

    toast('엑셀 다운로드 완료');
  } catch(e) {
    console.error('[exportCampaignDeliverables]', e);
    toast('엑셀 생성 실패: ' + (e.message || String(e)), 'error');
  }
}

// 임의 텍스트를 클립보드에 복사 (execCommand fallback 포함)
function copyTextToClipboard(text, successMsg) {
  var msg = successMsg || '복사됨';
  try {
    navigator.clipboard.writeText(text);
    toast(msg);
  } catch (e) {
    var tmp = document.createElement('input');
    tmp.value = text;
    document.body.appendChild(tmp);
    tmp.select();
    try { document.execCommand('copy'); toast(msg); } catch(_) { toast('복사 실패', 'error'); }
    document.body.removeChild(tmp);
  }
}

// 광고주 신청 페이지 URL을 클립보드에 복사 (영업팀 공유용)
function copyBrandSalesUrl() {
  copyTextToClipboard('https://sales.globalreverb.com/', 'https://sales.globalreverb.com/ 복사됨');
}

// 제품 URL 복사 (상세 모달의 상품 테이블에서 사용)
function copyBrandProductUrl(url) {
  copyTextToClipboard(url, 'URL 복사됨');
}

// ══════════════════════════════════════
// 브랜드 서베이 현황 대시보드 (#brand-dashboard)
// - brand_applications 전체 조회 후 클라이언트 집계
// - 차트: Form 도넛 / Status 도넛 / 일별 추이 바 (기본 7일, 토글 가능)
// - KPI: 전체·폼별·월별·대기·완료·평균 처리일·견적 합계
// ══════════════════════════════════════
var _brandDashApps = null;
var _brandTrendChart = null;
var _brandFormDonut = null;
var _brandStatusDonut = null;
var _brandTrendDays = 7;

var BRAND_STATUS_LABEL_KO = {
  new: '신규', reviewing: '검토중', quoted: '견적 전달', paid: '입금완료',
  orient_sheet_sent: '오리엔시트 전달', schedule_sent: '일정 전달',
  campaign_registered: '캠페인 등록', done: '최종완료', rejected: '반려'
};
// 색상은 단계의 의미에 따라 유지 (코드 ↔ 의미 매핑 불변)
var BRAND_STATUS_COLOR = {
  new:                 '#C878A3',   // 핑크 (대기)
  reviewing:           '#E8A355',   // 오렌지
  quoted:              '#5B8FD6',   // 블루 (견적)
  paid:                '#6BB38E',   // 그린 (입금)
  orient_sheet_sent:   '#8C6BC0',   // 퍼플 (오리엔시트)
  schedule_sent:       '#D97AA6',   // 진한 핑크 (일정)
  campaign_registered: '#4CA070',   // 연한 그린 (등록)
  done:                '#1F9D55',   // 짙은 그린 (최종완료)
  rejected:            '#B0B0B8'    // 회색 (종료)
};
var BRAND_FUNNEL_STAGES = [
  {key:'new',                 label:'접수 (new)'},
  {key:'reviewing',           label:'검토 (reviewing)'},
  {key:'quoted',              label:'견적 전달 (quoted)'},
  {key:'paid',                label:'입금 완료 (paid)'},
  {key:'orient_sheet_sent',   label:'오리엔시트 전달 (orient_sheet_sent)'},
  {key:'schedule_sent',       label:'일정 전달 (schedule_sent)'},
  {key:'campaign_registered', label:'캠페인 등록 (campaign_registered)'},
  {key:'done',                label:'최종 완료 (done)'}
];
// 전환 깔때기용: status가 이 단계 이상이면 도달한 것으로 간주 (rejected 제외)
var BRAND_STATUS_ORDER_FOR_FUNNEL = {new:0, reviewing:1, quoted:2, paid:3, orient_sheet_sent:4, schedule_sent:5, campaign_registered:6, done:7, rejected:-1};

async function loadBrandDashboard() {
  // 로딩 표시
  setBrandDashLoading(true);
  _brandDashApps = await fetchBrandApplications();
  setBrandDashLoading(false);
  renderBrandDashboard();
}

function setBrandDashLoading(loading) {
  var ids = ['brandKpiTotal','brandKpiReviewer','brandKpiSeeding','brandKpiThisMonth',
             'brandKpiPending','brandKpiQuoted','brandKpiDone','brandKpiLeadTime',
             'brandKpiEstimated','brandKpiFinal'];
  if (loading) {
    ids.forEach(function(id){
      var el = $(id);
      if (el) el.innerHTML = '<span class="spinner" style="width:16px;height:16px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span>';
    });
  }
}

function renderBrandDashboard() {
  var apps = _brandDashApps || [];
  renderBrandKPIs(apps);
  renderBrandFunnel(apps);
  renderBrandFormDonut(apps);
  renderBrandStatusDonut(apps);
  renderBrandTrendChart(apps, _brandTrendDays);
  renderBrandRecent(apps);
  renderBrandLongPending(apps);
}

function renderBrandKPIs(apps) {
  var now = new Date();
  var thisMonth = now.toISOString().slice(0,7); // 'YYYY-MM'
  var reviewerN = apps.filter(function(a){ return a.form_type === 'reviewer'; }).length;
  var seedingN  = apps.filter(function(a){ return a.form_type === 'seeding'; }).length;
  var thisMonthN = apps.filter(function(a){ return (a.created_at||'').slice(0,7) === thisMonth; }).length;
  var pendingN = apps.filter(function(a){ return a.status === 'new' || a.status === 'reviewing'; }).length;
  var quotedN  = apps.filter(function(a){ return a.status === 'quoted'; }).length;
  var doneN    = apps.filter(function(a){ return a.status === 'done'; }).length;

  // 평균 처리일: done 건만 대상, created_at -> reviewed_at 차이(폴백 updated_at)
  var leadDays = [];
  apps.forEach(function(a){
    if (a.status !== 'done') return;
    var start = a.created_at ? new Date(a.created_at).getTime() : null;
    var endSrc = a.reviewed_at || a.quote_sent_at || a.updated_at;
    var end = endSrc ? new Date(endSrc).getTime() : null;
    if (start && end && end >= start) {
      leadDays.push((end - start) / (1000*60*60*24));
    }
  });
  var avgLead = leadDays.length
    ? (leadDays.reduce(function(s,v){return s+v;},0) / leadDays.length)
    : null;

  // 견적 합계
  var estimated = apps.reduce(function(s,a){ return s + (Number(a.estimated_krw) || 0); }, 0);
  var finalSum = apps
    .filter(function(a){ return ['quoted','paid','orient_sheet_sent','schedule_sent','campaign_registered','done'].indexOf(a.status) !== -1; })
    .reduce(function(s,a){ return s + (Number(a.final_quote_krw) || Number(a.estimated_krw) || 0); }, 0);

  var fmtKRW = function(n) { return '₩ ' + Math.round(n).toLocaleString('ko-KR'); };

  $('brandKpiTotal').textContent    = apps.length;
  $('brandKpiReviewer').textContent = reviewerN;
  $('brandKpiSeeding').textContent  = seedingN;
  $('brandKpiThisMonth').textContent = thisMonthN;
  $('brandKpiPending').textContent  = pendingN;
  $('brandKpiQuoted').textContent   = quotedN;
  $('brandKpiDone').textContent     = doneN;
  $('brandKpiLeadTime').textContent = avgLead !== null ? avgLead.toFixed(1) + '일' : '—';
  $('brandKpiEstimated').textContent = fmtKRW(estimated);
  $('brandKpiFinal').textContent     = fmtKRW(finalSum);
}

function renderBrandFunnel(apps) {
  var host = $('brandFunnel');
  if (!host) return;
  if (!apps.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);text-align:center;padding:20px">데이터 없음</div>';
    return;
  }
  // rejected 제외한 총 접수 건수 (깔때기 분모)
  var activeTotal = apps.filter(function(a){ return a.status !== 'rejected'; }).length;
  var html = BRAND_FUNNEL_STAGES.map(function(stage, idx) {
    var threshold = BRAND_STATUS_ORDER_FOR_FUNNEL[stage.key];
    var reached = apps.filter(function(a){
      var ord = BRAND_STATUS_ORDER_FOR_FUNNEL[a.status];
      return ord !== -1 && ord >= threshold;
    }).length;
    var ratio = activeTotal ? Math.round((reached / activeTotal) * 100) : 0;
    var prev = idx === 0 ? activeTotal : apps.filter(function(a){
      var ord = BRAND_STATUS_ORDER_FOR_FUNNEL[a.status];
      var prevThreshold = BRAND_STATUS_ORDER_FOR_FUNNEL[BRAND_FUNNEL_STAGES[idx-1].key];
      return ord !== -1 && ord >= prevThreshold;
    }).length;
    var stepConv = prev ? Math.round((reached / prev) * 100) : 0;
    return '<div style="display:grid;grid-template-columns:160px 1fr 80px 70px;gap:10px;align-items:center">'
      + '<div style="font-size:12px;font-weight:600;color:var(--ink)">' + esc(stage.label) + '</div>'
      + '<div style="height:22px;background:rgba(200,120,163,.08);border-radius:100px;overflow:hidden;position:relative">'
      + '  <div style="height:100%;width:' + ratio + '%;background:linear-gradient(90deg,var(--pink),#E8A355);transition:width 0.4s"></div>'
      + '</div>'
      + '<div style="font-size:12px;font-weight:700;color:var(--ink);text-align:right;font-variant-numeric:tabular-nums">' + reached + '건</div>'
      + '<div style="font-size:11px;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums">' + ratio + '% · ' + (idx === 0 ? '—' : ('→' + stepConv + '%')) + '</div>'
      + '</div>';
  }).join('');
  host.innerHTML = html;
}

function renderBrandFormDonut(apps) {
  var canvas = $('brandFormDonut');
  var empty = $('brandFormEmpty');
  var totalLabel = $('brandFormTotal');
  if (!canvas) return;
  if (_brandFormDonut) { _brandFormDonut.destroy(); _brandFormDonut = null; }

  var reviewerN = apps.filter(function(a){ return a.form_type === 'reviewer'; }).length;
  var seedingN  = apps.filter(function(a){ return a.form_type === 'seeding'; }).length;
  var total = reviewerN + seedingN;
  if (totalLabel) totalLabel.textContent = total ? ('전체 ' + total + '건') : '';
  if (!total) {
    canvas.style.display = 'none';
    if (empty) empty.style.display = 'flex';
    return;
  }
  canvas.style.display = 'block';
  if (empty) empty.style.display = 'none';

  _brandFormDonut = new Chart(canvas.getContext('2d'), {
    type: 'doughnut',
    data: {
      labels: ['Qoo10 리뷰어', '나노 시딩'],
      datasets: [{
        data: [reviewerN, seedingN],
        backgroundColor: ['#C878A3', '#5B8FD6'],
        borderColor: '#fff',
        borderWidth: 2
      }]
    },
    options: {
      responsive: true, maintainAspectRatio: false, cutout: '62%',
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } },
        tooltip: {
          callbacks: {
            label: function(ctx) {
              var pct = total ? Math.round((ctx.parsed / total) * 100) : 0;
              return ctx.label + ': ' + ctx.parsed + '건 (' + pct + '%)';
            }
          }
        }
      }
    }
  });
}

function renderBrandStatusDonut(apps) {
  var canvas = $('brandStatusDonut');
  var empty = $('brandStatusEmpty');
  var totalLabel = $('brandStatusTotal');
  if (!canvas) return;
  if (_brandStatusDonut) { _brandStatusDonut.destroy(); _brandStatusDonut = null; }

  var keys = ['new','reviewing','quoted','paid','orient_sheet_sent','schedule_sent','campaign_registered','done','rejected'];
  var counts = keys.map(function(k){ return apps.filter(function(a){ return a.status === k; }).length; });
  var total = counts.reduce(function(s,n){ return s+n; }, 0);
  if (totalLabel) totalLabel.textContent = total ? ('전체 ' + total + '건') : '';
  if (!total) {
    canvas.style.display = 'none';
    if (empty) empty.style.display = 'flex';
    return;
  }
  canvas.style.display = 'block';
  if (empty) empty.style.display = 'none';

  _brandStatusDonut = new Chart(canvas.getContext('2d'), {
    type: 'doughnut',
    data: {
      labels: keys.map(function(k){ return BRAND_STATUS_LABEL_KO[k]; }),
      datasets: [{
        data: counts,
        backgroundColor: keys.map(function(k){ return BRAND_STATUS_COLOR[k]; }),
        borderColor: '#fff',
        borderWidth: 2
      }]
    },
    options: {
      responsive: true, maintainAspectRatio: false, cutout: '62%',
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } },
        tooltip: {
          callbacks: {
            label: function(ctx) {
              var pct = total ? Math.round((ctx.parsed / total) * 100) : 0;
              return ctx.label + ': ' + ctx.parsed + '건 (' + pct + '%)';
            }
          }
        }
      }
    }
  });
}

function renderBrandTrendChart(apps, days) {
  var canvas = $('brandTrendChart');
  if (!canvas) return;
  if (_brandTrendChart) { _brandTrendChart.destroy(); _brandTrendChart = null; }

  var now = new Date();
  var labels = [];
  var reviewerData = [];
  var seedingData = [];
  for (var i = days - 1; i >= 0; i--) {
    var d = new Date(now);
    d.setDate(d.getDate() - i);
    var dateStr = d.toISOString().slice(0, 10);
    labels.push((d.getMonth()+1) + '/' + d.getDate());
    reviewerData.push(apps.filter(function(a){ return a.form_type === 'reviewer' && (a.created_at||'').slice(0,10) === dateStr; }).length);
    seedingData.push(apps.filter(function(a){ return a.form_type === 'seeding' && (a.created_at||'').slice(0,10) === dateStr; }).length);
  }

  _brandTrendChart = new Chart(canvas, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        { label: 'Qoo10 리뷰어', data: reviewerData, backgroundColor: '#C878A3', borderRadius: 3, stack: 'applications' },
        { label: '나노 시딩',    data: seedingData,  backgroundColor: '#5B8FD6', borderRadius: 3, stack: 'applications' }
      ]
    },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } }
      },
      scales: {
        x: { stacked: true, ticks: { font: { size: 10 } }, grid: { display: false } },
        y: { stacked: true, beginAtZero: true, ticks: { stepSize: 1, font: { size: 10 } }, grid: { color: 'rgba(0,0,0,.05)' } }
      }
    }
  });
}

function switchBrandTrendPeriod(days, btn) {
  _brandTrendDays = days;
  document.querySelectorAll('.brand-trend-btn').forEach(function(b){ b.classList.remove('on'); });
  if (btn) btn.classList.add('on');
  renderBrandTrendChart(_brandDashApps || [], days);
}

function renderBrandRecent(apps) {
  var host = $('brandRecentList');
  if (!host) return;
  var top5 = apps.slice().sort(function(a,b){
    return (b.created_at || '').localeCompare(a.created_at || '');
  }).slice(0, 5);
  if (!top5.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);padding:20px;text-align:center">데이터 없음</div>';
    return;
  }
  host.innerHTML = top5.map(function(a){
    var formLabel = a.form_type === 'reviewer' ? 'Qoo10 리뷰어' : (a.form_type === 'seeding' ? '나노 시딩' : a.form_type);
    var dateStr = (a.created_at || '').slice(0,10);
    var statusColor = BRAND_STATUS_COLOR[a.status] || '#888';
    var statusLabel = BRAND_STATUS_LABEL_KO[a.status] || a.status;
    return '<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;cursor:pointer;transition:background 0.15s" onmouseover="this.style.background=\'rgba(200,120,163,.04)\'" onmouseout="this.style.background=\'transparent\'" onclick="openBrandAppDetail(\'' + esc(a.id) + '\')">'
      + '<div style="flex:1;min-width:0">'
      +   '<div style="font-size:12px;font-weight:700;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(a.brand_name || '(브랜드명 없음)') + '</div>'
      +   '<div style="font-size:10px;color:var(--muted);margin-top:2px">' + esc(formLabel) + ' · ' + esc(a.application_no || '') + ' · ' + esc(dateStr) + '</div>'
      + '</div>'
      + '<span style="flex-shrink:0;font-size:10px;font-weight:700;padding:3px 8px;border-radius:10px;background:' + statusColor + '20;color:' + statusColor + '">' + esc(statusLabel) + '</span>'
      + '</div>';
  }).join('');
}

function renderBrandLongPending(apps) {
  var host = $('brandLongPendingList');
  var countLabel = $('brandLongPendingCount');
  if (!host) return;
  var threeDaysAgo = Date.now() - 3 * 24 * 60 * 60 * 1000;
  var longPending = apps.filter(function(a){
    if (a.status !== 'new') return false;
    var ts = a.created_at ? new Date(a.created_at).getTime() : 0;
    return ts > 0 && ts < threeDaysAgo;
  }).sort(function(a,b){
    return (a.created_at || '').localeCompare(b.created_at || '');
  });
  if (countLabel) countLabel.textContent = longPending.length ? (longPending.length + '건') : '';
  if (!longPending.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);padding:20px;text-align:center">3일 이상 대기 중인 신청 없음</div>';
    return;
  }
  host.innerHTML = longPending.slice(0,5).map(function(a){
    var formLabel = a.form_type === 'reviewer' ? 'Qoo10 리뷰어' : '나노 시딩';
    var dateStr = (a.created_at || '').slice(0,10);
    var waitDays = Math.floor((Date.now() - new Date(a.created_at).getTime()) / (1000*60*60*24));
    return '<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid #E8A355;border-radius:8px;cursor:pointer;transition:background 0.15s;background:rgba(232,163,85,.04)" onmouseover="this.style.background=\'rgba(232,163,85,.1)\'" onmouseout="this.style.background=\'rgba(232,163,85,.04)\'" onclick="openBrandAppDetail(\'' + esc(a.id) + '\')">'
      + '<div style="flex:1;min-width:0">'
      +   '<div style="font-size:12px;font-weight:700;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(a.brand_name || '(브랜드명 없음)') + '</div>'
      +   '<div style="font-size:10px;color:var(--muted);margin-top:2px">' + esc(formLabel) + ' · ' + esc(dateStr) + '</div>'
      + '</div>'
      + '<span style="flex-shrink:0;font-size:10px;font-weight:700;padding:3px 8px;border-radius:10px;background:#E8A35520;color:#E8A355">' + waitDays + '일 대기</span>'
      + '</div>';
  }).join('');
}

async function loadBrandApplications() {
  var tbody = $('brandAppTableBody');
  if (tbody) tbody.innerHTML = '<tr><td colspan="11" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  _brandApps = await fetchBrandApplications();
  renderBrandApplicationsList();
  refreshBrandAppBadge();
}

async function refreshBrandAppBadge() {
  var el = $('adminBrandAppSi');
  if (!el) return;
  var count = await fetchBrandAppPendingCount();
  var badge = count > 0 ? '<span class="admin-si-badge">'+(count > 999 ? '999+' : count)+'</span>' : '';
  el.innerHTML = '<span class="si-icon material-icons-round notranslate" translate="no">storefront</span><span class="si-text">신청 목록</span>' + badge;
}

var brandAppLazy = null;
var BRAND_APP_PAGE_SIZE = 50;

// 현재 UI 필터/정렬 기준으로 브랜드 서베이 리스트를 추출 (렌더·엑셀 export 공용)
function getFilteredBrandApps() {
  var formVals = getMultiFilterValues('brandAppFormMulti');
  var statusVals = getMultiFilterValues('brandAppStatusMulti');
  var from = ($('brandAppFromDate')?.value) || '';
  var to = ($('brandAppToDate')?.value) || '';
  var q = ((($('brandAppSearch')?.value) || '').trim().toLowerCase());

  var list = _brandApps.slice();
  if (formVals.length > 0) list = list.filter(a => formVals.indexOf(a.form_type) >= 0);
  if (statusVals.length > 0) list = list.filter(a => statusVals.indexOf(a.status) >= 0);
  if (from) list = list.filter(a => (a.created_at || '') >= from);
  if (to) list = list.filter(a => (a.created_at || '') <= to + 'T23:59:59');
  if (q) list = list.filter(a =>
    (a.brand_name || '').toLowerCase().includes(q) ||
    (a.contact_name || '').toLowerCase().includes(q) ||
    (a.email || '').toLowerCase().includes(q) ||
    (a.application_no || '').toLowerCase().includes(q) ||
    (a.request_note || '').toLowerCase().includes(q)
  );

  list.sort(function(a, b) {
    var av, bv;
    if (_brandAppSort.field === 'estimated') {
      av = Number(a.estimated_krw || 0); bv = Number(b.estimated_krw || 0);
    } else if (_brandAppSort.field === 'status') {
      var BRAND_APP_STATUS_ORDER = {new:0, reviewing:1, quoted:2, paid:3, orient_sheet_sent:4, schedule_sent:5, campaign_registered:6, done:7, rejected:8};
      av = BRAND_APP_STATUS_ORDER[a.status] ?? 99;
      bv = BRAND_APP_STATUS_ORDER[b.status] ?? 99;
    } else {
      av = a.created_at || ''; bv = b.created_at || '';
    }
    if (av < bv) return _brandAppSort.dir === 'asc' ? -1 : 1;
    if (av > bv) return _brandAppSort.dir === 'asc' ? 1 : -1;
    return 0;
  });

  var filterActive = !!(formVals.length > 0 || statusVals.length > 0 || from || to || q);
  return { list: list, filterActive: filterActive };
}

function renderBrandApplicationsList() {
  var tbody = $('brandAppTableBody');
  if (!tbody) return;

  var res = getFilteredBrandApps();
  var list = res.list;
  var filterActive = res.filterActive;
  var resetBtn = $('btnBrandAppFilterReset');
  if (resetBtn) resetBtn.style.display = filterActive ? 'inline-block' : 'none';

  var count = $('brandAppTotalCount');
  if (count) {
    var totalAll = (_brandApps || []).length;
    var reviewerN = (_brandApps || []).filter(function(a){ return a.form_type === 'reviewer'; }).length;
    var seedingN  = (_brandApps || []).filter(function(a){ return a.form_type === 'seeding'; }).length;
    var summary = '전체 ' + totalAll + '건 · 리뷰어 ' + reviewerN + ' · 시딩 ' + seedingN;
    count.textContent = filterActive
      ? '(필터 ' + list.length + ' / ' + summary + ')'
      : '(' + summary + ')';
  }

  var renderBrandAppRow = function(a) {
    return '<tr data-id="' + esc(a.id) + '">'
      + '<td>'
        + '<div style="font-size:11px;font-weight:600;color:var(--ink)">' + esc(a.application_no || '—') + '</div>'
        + '<div style="margin-top:3px"><span style="background:#F0F0F0;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">' + esc(brandAppFormLabel(a.form_type)) + '</span></div>'
      + '</td>'
      + '<td style="font-weight:600">' + esc(a.brand_name || '—') + '</td>'
      + '<td>'
        + '<div>' + esc(a.contact_name || '—') + '</div>'
        + (a.email ? '<div style="font-size:11px;color:var(--muted);margin-top:2px;word-break:break-all">' + esc(a.email) + '</div>' : '')
      + '</td>'
      + '<td style="font-size:12px">' + esc(formatPhoneDisplay(a.phone) || '—') + '</td>'
      + '<td style="font-size:12px;color:' + (a.billing_email ? 'var(--ink)' : 'var(--muted)') + ';word-break:break-all">' + esc(a.billing_email || '—') + '</td>'
      + '<td>' + brandAppNoteCell(a.request_note) + '</td>'
      + '<td style="text-align:right;font-variant-numeric:tabular-nums">' + fmtKrw(a.estimated_krw) + '</td>'
      + '<td style="text-align:right;font-variant-numeric:tabular-nums;font-weight:600">' + fmtKrw(a.final_quote_krw) + '</td>'
      + '<td>' + brandAppStatusSelect(a) + '</td>'
      + '<td style="font-size:11px;color:var(--muted)">' + fmtDate(a.created_at) + '</td>'
      + '<td><button class="btn btn-ghost btn-xs" onclick="openBrandAppDetail(\'' + esc(a.id) + '\')">상세</button></td>'
      + '</tr>';
  };
  if (brandAppLazy) brandAppLazy.destroy();
  brandAppLazy = mountLazyList({
    tbody: tbody,
    scrollRoot: tbody.closest('.admin-table-wrap'),
    rows: list,
    renderRow: renderBrandAppRow,
    pageSize: BRAND_APP_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="11" style="text-align:center;color:var(--muted);padding:40px">신청 내역이 없습니다</td></tr>',
  });
}

function resetBrandAppFilters() {
  resetMultiFilter('brandAppFormMulti', '전체 폼');
  resetMultiFilter('brandAppStatusMulti', '전체 상태');
  if ($('brandAppFromDate')) $('brandAppFromDate').value = '';
  if ($('brandAppToDate')) $('brandAppToDate').value = '';
  if ($('brandAppSearch')) $('brandAppSearch').value = '';
  ['brandAppFromDate','brandAppToDate'].forEach(function(id){
    var el = $(id); if (el) el.classList.remove('filter-active');
  });
  renderBrandApplicationsList();
}

function toggleBrandAppSort(field) {
  if (_brandAppSort.field === field) {
    _brandAppSort.dir = _brandAppSort.dir === 'asc' ? 'desc' : 'asc';
  } else {
    _brandAppSort = {field: field, dir: 'desc'};
  }
  updateBrandAppSortIndicators();
  renderBrandApplicationsList();
}

// 정렬 화살표 활성 상태 시각화 (▲ asc / ▼ desc / ▲▼ inactive)
function updateBrandAppSortIndicators() {
  document.querySelectorAll('#adminPane-brand-applications .sort-arrows').forEach(function(el) {
    var field = el.getAttribute('data-sort');
    if (field === _brandAppSort.field) {
      el.textContent = _brandAppSort.dir === 'asc' ? '▲' : '▼';
      el.style.color = 'var(--pink)';
    } else {
      el.textContent = '▲▼';
      el.style.color = '';
    }
  });
}

async function openBrandAppDetail(id) {
  _brandAppCurrentId = id;
  var modal = $('brandAppDetailModal');
  if (modal) modal.classList.add('open');
  var body = $('brandAppDetailBody');
  var footer = $('brandAppDetailFooter');
  if (body) body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  if (footer) footer.innerHTML = '';

  var a = await fetchBrandApplicationById(id);
  if (!a) {
    if (body) body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">데이터를 불러올 수 없습니다</div>';
    return;
  }

  // 모달 타이틀: [폼 종류 뱃지] 신청번호
  var title = $('brandAppDetailTitle');
  if (title) title.innerHTML = ''
    + '<span style="background:#F0F0F0;color:#555;font-size:11px;font-weight:700;padding:3px 10px;border-radius:4px;margin-right:8px;vertical-align:middle">'
    + esc(brandAppFormLabel(a.form_type))
    + '</span>'
    + '<span style="vertical-align:middle">' + esc(a.application_no) + '</span>';

  // 제품 테이블
  var productsHtml = '<div style="color:var(--muted);font-size:12px;padding:12px">제품 정보 없음</div>';
  if (Array.isArray(a.products) && a.products.length > 0) {
    productsHtml = '<table class="data-table" style="font-size:12px;margin:0;table-layout:fixed">'
      + '<thead><tr>'
        + '<th style="width:30%">제품명</th>'
        + '<th>URL</th>'
        + '<th style="width:80px;text-align:right">수량</th>'
        + '<th style="width:110px;text-align:right">가격 (¥)</th>'
        + '<th style="width:130px;text-align:right">총액 (¥)</th>'
      + '</tr></thead>'
      + '<tbody>' + a.products.map(function(p){
        var price = Number(p.price) || 0;
        var qty = Number(p.qty) || 0;
        var lineTotal = price * qty;
        var safe = safeBrandUrl(p.url);
        var urlCell = '<span style="color:var(--muted)">—</span>';
        if (safe) {
          var jsSafe = safe.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
          urlCell = '<div style="display:flex;align-items:flex-start;gap:4px;min-width:0">'
            + '<a href="' + esc(safe) + '" target="_blank" rel="noopener" title="' + esc(p.url) + '"'
              + ' style="flex:1;min-width:0;color:var(--pink);word-break:break-all;'
              + 'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;line-height:1.4;max-height:2.8em">'
              + esc(p.url) + '</a>'
            + '<button type="button" class="btn btn-ghost btn-xs" onclick="copyBrandProductUrl(\'' + jsSafe + '\')" '
              + 'title="URL 복사" style="padding:2px 6px;flex-shrink:0">'
              + '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">content_copy</span>'
            + '</button>'
          + '</div>';
        } else if (p.url) {
          urlCell = '<span style="color:var(--muted);word-break:break-all">' + esc(p.url) + '</span>';
        }
        return '<tr>'
          + '<td style="font-weight:600;color:var(--ink);word-break:break-word">' + esc(p.name || '—') + '</td>'
          + '<td>' + urlCell + '</td>'
          + '<td style="text-align:right;font-variant-numeric:tabular-nums">' + qty.toLocaleString('ja-JP') + '</td>'
          + '<td style="text-align:right;font-variant-numeric:tabular-nums">' + price.toLocaleString('ja-JP') + '</td>'
          + '<td style="text-align:right;font-variant-numeric:tabular-nums;font-weight:600">' + lineTotal.toLocaleString('ja-JP') + '</td>'
        + '</tr>';
      }).join('') + '</tbody></table>';
  }

  // 편집 가능 여부 — done 또는 rejected면 읽기전용
  var editableDisabled = (a.status === 'done' || a.status === 'rejected') ? 'disabled' : '';

  // 섹션 재사용 스타일
  var sectionLabel = function(txt) {
    return '<div style="font-size:11px;font-weight:700;color:var(--ink);letter-spacing:0.08em;text-transform:uppercase;margin-bottom:10px">' + esc(txt) + '</div>';
  };
  var kvCard = function(label, value) {
    return '<div><div style="color:var(--muted);font-size:11px;margin-bottom:3px;font-weight:600">' + esc(label) + '</div><div style="font-size:13px;color:var(--ink);word-break:break-all">' + (value || '<span style="color:var(--muted)">—</span>') + '</div></div>';
  };

  // 총 상품가/수량 요약
  var productsSummary = '';
  if (Array.isArray(a.products) && a.products.length > 0) {
    productsSummary = '<span style="font-weight:400;color:var(--muted);margin-left:8px;font-size:11px">'
      + (a.products.length) + '종 · ' + (a.total_qty || 0) + '개 · 상품 총액 ¥' + (Number(a.total_jpy)||0).toLocaleString('ja-JP')
      + '</span>';
  }

  if (body) body.innerHTML = ''
    // § 기본 정보
    + '<div style="padding-bottom:16px;margin-bottom:16px;border-bottom:1px solid var(--line)">'
      + sectionLabel('기본 정보')
      + '<div style="display:grid;grid-template-columns:1fr 1fr;gap:14px 20px">'
        + kvCard('브랜드', '<strong>' + esc(a.brand_name) + '</strong>')
        + kvCard('담당자', esc(a.contact_name))
        + kvCard('연락처', esc(formatPhoneDisplay(a.phone)))
        + kvCard('이메일', esc(a.email))
        + (a.billing_email ? '<div style="grid-column:1 / -1">' + kvCard('계산서 이메일', esc(a.billing_email)).replace(/^<div>/,'').replace(/<\/div>$/,'') + '</div>' : '')
      + '</div>'
    + '</div>'

    // § 신청 상품
    + '<div style="padding-bottom:16px;margin-bottom:16px;border-bottom:1px solid var(--line)">'
      + '<div style="display:flex;align-items:baseline;margin-bottom:10px">' + sectionLabel('신청 상품') + productsSummary + '</div>'
      + productsHtml
    + '</div>'

    // § 신청자 요청사항 (신청자가 직접 입력. 관리자 메모와 구분)
    + (a.request_note ? (
        '<div style="padding-bottom:16px;margin-bottom:16px;border-bottom:1px solid var(--line)">'
          + sectionLabel('신청자 요청사항')
          + '<div style="background:#FFF9F0;border:1px solid #E8D0A0;border-radius:8px;padding:12px 14px;font-size:13px;color:var(--ink);white-space:pre-wrap;word-break:break-word;line-height:1.6">'
          + esc(a.request_note)
          + '</div>'
        + '</div>'
      ) : '')

    // § 관리자 처리
    + '<div style="padding-bottom:16px;margin-bottom:16px">'
      + sectionLabel('관리자 처리')
      + '<div style="display:grid;grid-template-columns:1fr 1fr;gap:14px 16px">'
        + '<div><label style="color:var(--muted);font-size:11px;font-weight:600;display:block;margin-bottom:4px">상태</label>'
          + brandAppStatusSelectStyled({id:'brandAppEditStatus', status:a.status, disabled: !!editableDisabled, onchange:'onBrandAppEditStatusChange(this)'})
        + '</div>'
        + '<div><label style="color:var(--muted);font-size:11px;font-weight:600;display:block;margin-bottom:4px">예상 견적 (자동)</label>'
          + '<input type="text" class="admin-filter" value="' + fmtKrw(a.estimated_krw) + '" readonly style="background:#F7F7F7;color:var(--muted)">'
        + '</div>'
        + '<div><label style="color:var(--muted);font-size:11px;font-weight:600;display:block;margin-bottom:4px">확정 견적 (₩)</label>'
          + '<input type="number" id="brandAppEditFinalQuote" class="admin-filter" value="' + (a.final_quote_krw || '') + '" placeholder="0" ' + editableDisabled + '>'
        + '</div>'
        + '<div style="display:flex;flex-direction:column;justify-content:flex-end">'
          + '<label style="display:flex;align-items:center;gap:6px;color:var(--ink);font-size:13px;cursor:pointer">'
            + '<input type="checkbox" id="brandAppEditQuoteSent" ' + (a.quote_sent_at ? 'checked' : '') + ' ' + editableDisabled + '>'
            + '견적서 전달 완료'
          + '</label>'
          + '<div style="font-size:10px;color:var(--muted);margin-top:3px">' + (a.quote_sent_at ? '전달일 ' + fmtDate(a.quote_sent_at) : '미전달') + '</div>'
        + '</div>'
      + '</div>'
      + '<div style="margin-top:14px">'
        + '<label style="color:var(--muted);font-size:11px;font-weight:600;display:block;margin-bottom:4px">내부 메모</label>'
        + '<textarea id="brandAppEditMemo" class="admin-filter" rows="3" style="resize:vertical" placeholder="관리자끼리 공유할 메모 (광고주에게 노출되지 않음)" ' + editableDisabled + '>' + esc(a.admin_memo || '') + '</textarea>'
      + '</div>'
    + '</div>'

    // § 이력
    + '<div style="padding-top:12px;border-top:1px solid var(--line);display:flex;gap:16px;flex-wrap:wrap;font-size:11px;color:var(--muted)">'
      + '<span><span style="font-weight:600;text-transform:uppercase;letter-spacing:0.05em;margin-right:4px">신청일</span>' + fmtDate(a.created_at) + '</span>'
      + (a.reviewed_at ? '<span><span style="font-weight:600;text-transform:uppercase;letter-spacing:0.05em;margin-right:4px">검수일</span>' + fmtDate(a.reviewed_at) + '</span>' : '')
      + '<span style="margin-left:auto"><span style="font-weight:600;text-transform:uppercase;letter-spacing:0.05em;margin-right:4px">ver</span>' + a.version + '</span>'
    + '</div>';

  if (footer) footer.innerHTML = ''
    + '<button class="btn btn-ghost" onclick="closeBrandAppDetail()">닫기</button>'
    + (a.status !== 'new' ? '<button class="btn btn-ghost" onclick="revertBrandApp()">되돌리기</button>' : '')
    + '<button class="btn btn-primary" onclick="saveBrandAppChanges(' + a.version + ')">저장</button>';

  // 현재 row 버전·원본 저장 (낙관적 락용)
  window._brandAppCurrent = a;
}

function closeBrandAppDetail() {
  var modal = $('brandAppDetailModal');
  if (modal) modal.classList.remove('open');
  _brandAppCurrentId = null;
  window._brandAppCurrent = null;
}

async function saveBrandAppChanges(expectedVersion) {
  var cur = window._brandAppCurrent;
  if (!cur) return;
  var status = $('brandAppEditStatus')?.value;
  var finalQuote = $('brandAppEditFinalQuote')?.value;
  var quoteSentChecked = $('brandAppEditQuoteSent')?.checked;
  var memo = $('brandAppEditMemo')?.value || '';

  var patch = {
    status: status,
    final_quote_krw: finalQuote ? Number(finalQuote) : null,
    quote_sent_at: quoteSentChecked ? (cur.quote_sent_at || new Date().toISOString()) : null,
    admin_memo: memo || null
  };
  // 최초 검수 진입 시 reviewed_by/at 기록
  if (cur.status === 'new' && status !== 'new') {
    patch.reviewed_by = currentUser?.id || null;
    patch.reviewed_at = new Date().toISOString();
  }

  var result = await updateBrandApplication(cur.id, patch, expectedVersion);
  if (result.conflict) {
    // 낙관적 락 충돌 — 사용자 입력값은 유실됨(의도적 동작).
    // 복원 로직 대신 최신 상태를 다시 로드해 사용자가 재확인·재입력하도록 유도.
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await openBrandAppDetail(cur.id);
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  toast('저장되었습니다.');
  closeBrandAppDetail();
  await loadBrandApplications();
}

async function revertBrandApp() {
  var cur = window._brandAppCurrent;
  if (!cur) return;
  if (!await showConfirm('상태를 신규로 되돌리고 검수 기록을 초기화합니다.\n계속할까요?')) return;
  var result = await updateBrandApplication(cur.id, {
    status: 'new',
    reviewed_by: null,
    reviewed_at: null
  }, cur.version);
  if (result.conflict) { toast('다른 관리자가 먼저 처리했습니다.', 'warn'); return; }
  if (!result.ok) { toast('되돌리기 실패', 'error'); return; }
  toast('되돌렸습니다.');
  closeBrandAppDetail();
  await loadBrandApplications();
}

// ══════════════════════════════════════
// ADMIN NOTICES (관리자 전용 공지 — migration 063)
// ══════════════════════════════════════

var _adminNoticesCache = [];
var _adminNoticeCurrent = null;
var _adminNoticeQuill = null;

const ADMIN_NOTICE_CAT_LABEL = {
  system_update: '시스템 업데이트',
  release: '릴리스',
  warning: '경고',
  general: '일반',
};
const ADMIN_NOTICE_CAT_STYLE = {
  system_update: 'background:#E3F2FD;color:#1565C0',
  release: 'background:#E8F5E9;color:#2E7D32',
  warning: 'background:#FFEBEE;color:#C62828',
  general: 'background:#F5F5F5;color:#616161',
};

function adminNoticeCatPill(cat) {
  const style = ADMIN_NOTICE_CAT_STYLE[cat] || ADMIN_NOTICE_CAT_STYLE.general;
  return `<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;${style}">${esc(ADMIN_NOTICE_CAT_LABEL[cat]||cat)}</span>`;
}

// migration 071: 게시 상태 pill (draft/published)
function adminNoticeStatusPill(status) {
  if (status === 'published') {
    return '<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;background:#E8F5E9;color:#2E7D32">게시</span>';
  }
  return '<span style="display:inline-block;font-size:10px;font-weight:700;padding:2px 8px;border-radius:3px;background:#EEEEEE;color:#616161">초안</span>';
}

async function loadAdminNotices() {
  _adminNoticesCache = await fetchAdminNotices();
  renderAdminNotices();
  refreshAdminNoticeBadge();
}

// 사이드바 배지: published 미읽음만 카운트
function refreshAdminNoticeBadge() {
  const badge = $('adminNoticesBadge');
  if (!badge) return;
  const unread = (_adminNoticesCache || []).filter(n => n.status === 'published' && !n.is_read).length;
  if (unread > 0) { badge.textContent = unread > 9 ? '9+' : unread; badge.style.display = ''; }
  else badge.style.display = 'none';
}

function renderAdminNotices() {
  const body = $('adminNoticeBody');
  if (!body) return;
  const cat = $('adminNoticeCatFilter')?.value || 'all';
  const status = $('adminNoticeStatusFilter')?.value || 'all';
  const q = ($('adminNoticeSearch')?.value || '').trim().toLowerCase();
  let list = (_adminNoticesCache || []).slice();
  if (cat !== 'all') list = list.filter(n => n.category === cat);
  if (status !== 'all') list = list.filter(n => (n.status || 'draft') === status);
  if (q) list = list.filter(n => (n.title || '').toLowerCase().includes(q));
  const total = $('adminNoticeTotal');
  if (total) total.textContent = `${list.length}건`;
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const canEdit = (n) => isSuper || n.created_by === currentUser?.id;
  body.innerHTML = list.length ? list.map(n => {
    const isPub = n.status === 'published';
    const showUnread = isPub && !n.is_read;
    const unreadDot = showUnread ? `<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:#C62828;margin-right:4px;vertical-align:middle"></span>` : '';
    const readCellInner = !isPub
      ? '<span style="font-size:11px;color:var(--muted)">—</span>'
      : (n.is_read
          ? '<span style="font-size:11px;color:var(--muted)">읽음</span>'
          : '<span style="font-size:11px;color:#C62828;font-weight:700">미읽음</span>');
    const pinIcon = n.is_pinned ? `<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--pink);vertical-align:-2px" title="상단 고정">push_pin</span> ` : '';
    const dateStr = isPub
      ? (n.published_at ? formatDateTime(n.published_at) : (n.created_at ? formatDateTime(n.created_at) : ''))
      : (n.created_at ? `<span style="color:#999">— · ${formatDateTime(n.created_at)} 작성</span>` : '');
    return `<tr data-id="${esc(n.id)}" style="cursor:pointer;${showUnread?'background:#FFFBEF':''}" onclick="openAdminNoticeView(this.dataset.id)">
      <td>${unreadDot}${readCellInner}</td>
      <td>${adminNoticeStatusPill(n.status)}</td>
      <td>${adminNoticeCatPill(n.category)}</td>
      <td style="font-weight:600;color:var(--ink)">${pinIcon}${esc(n.title)}</td>
      <td style="font-size:12px;color:var(--muted)">${esc(n.created_by_name || '—')}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${dateStr}</td>
      <td>${canEdit(n) ? `<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openAdminNoticeEdit(this.closest('tr').dataset.id)"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">edit</span> 수정</button>` : ''}</td>
    </tr>`;
  }).join('') : '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">공지 없음</td></tr>';
}

// 보기 모달. 자동 읽음 처리는 published 공지에만. 푸터 버튼은 권한·상태별 분기.
async function openAdminNoticeView(id) {
  const n = (_adminNoticesCache || []).find(x => x.id === id);
  if (!n) return;
  _adminNoticeCurrent = n;
  const isPub = n.status === 'published';
  $('adminNoticeViewTitle').innerHTML = esc(n.title);
  const dateBlock = isPub
    ? (n.published_at ? `<span>${formatDateTime(n.published_at)} 게시</span>` : '')
    : `<span style="color:#999">${n.created_at?formatDateTime(n.created_at)+' 작성':''}</span>`;
  $('adminNoticeViewMeta').innerHTML = `${adminNoticeStatusPill(n.status)}${adminNoticeCatPill(n.category)}<span>${esc(n.created_by_name || '—')}</span>${dateBlock}${n.is_pinned?'<span style="color:var(--pink);font-weight:700;display:inline-flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">push_pin</span>상단 고정</span>':''}`;
  const bodyEl = $('adminNoticeViewBody');
  if (typeof renderRich === 'function') renderRich(bodyEl, n.body_html || '');
  else if (typeof sanitizeRich === 'function') bodyEl.innerHTML = sanitizeRich(n.body_html || '');
  else bodyEl.innerHTML = n.body_html || '';
  // 푸터: 작성자/super 만 표시
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const canEdit = isSuper || n.created_by === currentUser?.id;
  const footer = $('adminNoticeViewFooter');
  if (footer) {
    footer.style.display = canEdit ? 'flex' : 'none';
    const editBtn = $('btnEditAdminNoticeFromView');
    const pubBtn = $('btnPublishAdminNoticeFromView');
    const unpubBtn = $('btnUnpublishAdminNoticeFromView');
    if (editBtn) editBtn.style.display = canEdit ? '' : 'none';
    if (pubBtn) pubBtn.style.display = canEdit && !isPub ? '' : 'none';
    if (unpubBtn) unpubBtn.style.display = canEdit && isPub ? '' : 'none';
  }
  openModal('adminNoticeViewModal');
  if (isPub && !n.is_read) {
    try {
      await markAdminNoticeRead(id);
      n.is_read = true;
      refreshAdminNoticeBadge();
      renderAdminNotices();
      renderDashboardNotices();
    } catch(e) {}
  }
}

// 보기 모달에서 "수정" 클릭 → 편집 모달로 전환
function onEditAdminNoticeFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  closeModal('adminNoticeViewModal');
  openAdminNoticeEdit(id);
}

// 보기 모달에서 "지금 게시" 클릭
async function onPublishFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  if (!confirm('이 공지를 지금 게시할까요? 모든 관리자에게 미읽음으로 노출됩니다.')) return;
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  try {
    await publishAdminNotice(id, name);
    toast('게시되었습니다', 'success');
    closeModal('adminNoticeViewModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('게시 오류: ' + (e.message || e), 'error'); }
}

// 보기 모달에서 "게시 회수" 클릭 — published → draft (published_at 유지)
async function onUnpublishFromView() {
  if (!_adminNoticeCurrent) return;
  const id = _adminNoticeCurrent.id;
  if (!confirm('이 공지를 회수(초안으로 되돌리기)할까요? 노출 채널에서 사라지며 작성자/super_admin 만 볼 수 있습니다.')) return;
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  try {
    await unpublishAdminNotice(id, name);
    toast('초안으로 되돌렸습니다', 'success');
    closeModal('adminNoticeViewModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('회수 오류: ' + (e.message || e), 'error'); }
}

function openAdminNoticeEdit(id) {
  const n = id ? (_adminNoticesCache || []).find(x => x.id === id) : null;
  _adminNoticeCurrent = n;
  const isNew = !n;
  const isPub = n?.status === 'published';
  $('adminNoticeEditTitle').textContent = isNew ? '공지 작성' : (isPub ? '게시중인 공지 수정' : '초안 수정');
  $('anEditTitle').value = n?.title || '';
  $('anEditCategory').value = n?.category || 'system_update';
  $('anEditPinned').checked = !!(n?.is_pinned);
  const delBtn = $('btnDeleteAdminNotice');
  if (delBtn) delBtn.style.display = n ? '' : 'none';
  // 푸터 버튼 분기:
  //   신규 / draft 편집  → [초안 저장] [게시하기]
  //   published 편집     → [게시 유지하며 저장] [초안으로 되돌리고 저장]
  const btnDraft     = $('btnSaveAdminNoticeDraft');
  const btnPublish   = $('btnPublishAdminNotice');
  const btnKeepPub   = $('btnSaveAdminNoticeKeepPublished');
  const btnRevertDr  = $('btnSaveAdminNoticeRevertDraft');
  if (btnDraft)    btnDraft.style.display    = isPub ? 'none' : '';
  if (btnPublish)  btnPublish.style.display  = isPub ? 'none' : '';
  if (btnKeepPub)  btnKeepPub.style.display  = isPub ? '' : 'none';
  if (btnRevertDr) btnRevertDr.style.display = isPub ? '' : 'none';
  // 상태 안내 pill (모달 푸터 좌측)
  const pillEl = $('adminNoticeEditStatusPill');
  if (pillEl) {
    if (isNew) pillEl.innerHTML = '';
    else if (isPub) pillEl.innerHTML = `${adminNoticeStatusPill('published')} <span style="font-size:11px;color:var(--muted)">${n.published_at?formatDateTime(n.published_at)+' 게시':''}</span>`;
    else pillEl.innerHTML = adminNoticeStatusPill('draft');
  }
  // HTML 모드 기본 off. 기존 공지 중 '<p>&lt;' 같이 태그가 텍스트로 저장된 케이스 감지 시 자동 HTML 모드
  const rawHtml = n?.body_html || '';
  const tagAsText = /&lt;\w+/.test(rawHtml);
  $('anEditHtmlMode').checked = tagAsText;
  $('anEditBodyRaw').value = rawHtml;
  openModal('adminNoticeEditModal');
  setTimeout(() => {
    if (!_adminNoticeQuill && typeof Quill !== 'undefined') {
      _adminNoticeQuill = new Quill('#anEditBodyQuill', {
        theme: 'snow',
        modules: { toolbar: [[{header:[2,3,4,false]}],['bold','italic','underline','strike'],[{list:'ordered'},{list:'bullet'}],['link','blockquote'],['clean']], clipboard:{matchVisual:false} },
        formats: ['header','bold','italic','underline','strike','list','link','blockquote']
      });
    }
    if (_adminNoticeQuill) {
      const initHtml = (typeof sanitizeRich === 'function') ? sanitizeRich(rawHtml) : rawHtml;
      _adminNoticeQuill.clipboard.dangerouslyPasteHTML(initHtml, 'silent');
    }
    toggleNoticeHtmlMode();
  }, 0);
}

function toggleNoticeHtmlMode() {
  const isHtml = !!$('anEditHtmlMode')?.checked;
  const quillHost = $('anEditBodyQuill');
  const raw = $('anEditBodyRaw');
  const toolbar = document.querySelector('#adminNoticeEditModal .ql-toolbar');
  if (isHtml) {
    if (_adminNoticeQuill && raw.value === '') raw.value = _adminNoticeQuill.root.innerHTML;
    if (quillHost) quillHost.style.display = 'none';
    if (toolbar) toolbar.style.display = 'none';
    if (raw) raw.style.display = '';
  } else {
    if (_adminNoticeQuill && raw.value) {
      const initHtml = (typeof sanitizeRich === 'function') ? sanitizeRich(raw.value) : raw.value;
      _adminNoticeQuill.clipboard.dangerouslyPasteHTML(initHtml, 'silent');
    }
    if (raw) raw.style.display = 'none';
    if (quillHost) quillHost.style.display = '';
    if (toolbar) toolbar.style.display = '';
  }
}

// 저장 모드 4종:
//   'draft'           : 신규 INSERT 또는 draft UPDATE 후 status=draft 유지
//   'publish'         : 신규 INSERT 또는 draft UPDATE 후 status=published 전환
//   'keep_published'  : published 편집 — status=published 유지 (오탈자 즉시 수정)
//   'revert_draft'    : published 편집 — status=draft 회귀 (안전 우선 기본)
async function onSaveAdminNotice(mode) {
  const title = ($('anEditTitle')?.value || '').trim();
  const category = $('anEditCategory')?.value || 'general';
  const is_pinned = !!$('anEditPinned')?.checked;
  if (!title) { toast('제목을 입력해주세요', 'error'); return; }
  let body_html = '';
  const isHtmlMode = !!$('anEditHtmlMode')?.checked;
  if (isHtmlMode) {
    const raw = $('anEditBodyRaw')?.value || '';
    body_html = (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
  } else if (_adminNoticeQuill) {
    const raw = _adminNoticeQuill.root.innerHTML;
    body_html = (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
  }
  const name = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
  const safeMode = mode || 'draft';
  try {
    if (_adminNoticeCurrent) {
      const patch = {title, body_html, category, is_pinned, updated_by_name: name};
      if (safeMode === 'publish' || safeMode === 'keep_published') patch.status = 'published';
      else if (safeMode === 'revert_draft') patch.status = 'draft';
      // 'draft' 모드 (draft 편집): status 유지
      await updateAdminNotice(_adminNoticeCurrent.id, patch);
      const okMsg = safeMode === 'publish' ? '게시되었습니다'
                  : safeMode === 'keep_published' ? '게시 유지하며 저장되었습니다'
                  : safeMode === 'revert_draft' ? '초안으로 되돌리고 저장되었습니다'
                  : '초안 저장되었습니다';
      toast(okMsg, 'success');
    } else {
      const wantPublish = safeMode === 'publish';
      await insertAdminNotice({title, body_html, category, is_pinned, created_by_name: name, status: wantPublish ? 'published' : 'draft'});
      toast(wantPublish ? '게시되었습니다' : '초안 저장되었습니다', 'success');
    }
    closeModal('adminNoticeEditModal');
    await loadAdminNotices();
    renderDashboardNotices();
  } catch(e) { toast('저장 오류: ' + (e.message || e), 'error'); }
}

async function onDeleteAdminNotice() {
  if (!_adminNoticeCurrent) return;
  if (!confirm('공지를 삭제할까요? 모든 관리자의 읽음 이력도 함께 삭제됩니다.')) return;
  try {
    await deleteAdminNotice(_adminNoticeCurrent.id);
    toast('삭제되었습니다');
    closeModal('adminNoticeEditModal');
    await loadAdminNotices();
  } catch(e) { toast('삭제 오류: ' + (e.message || e), 'error'); }
}

// 대시보드 최근 공지 3건 렌더 — published 만 노출
function renderDashboardNotices() {
  const card = $('dashboardNoticesCard');
  const body = $('dashboardNoticesBody');
  if (!card || !body) return;
  const list = (_adminNoticesCache || []).filter(n => n.status === 'published').slice(0, 3);
  if (!list.length) { card.style.display = 'none'; return; }
  card.style.display = '';
  body.innerHTML = list.map(n => `
    <div style="padding:12px 16px;border-bottom:1px solid var(--line);display:flex;align-items:center;gap:10px;cursor:pointer" onclick="openAdminNoticeView('${esc(n.id)}')">
      ${!n.is_read ? '<span style="display:inline-block;width:6px;height:6px;border-radius:50%;background:#C62828;flex-shrink:0"></span>' : '<span style="display:inline-block;width:6px;height:6px;flex-shrink:0"></span>'}
      ${adminNoticeCatPill(n.category)}
      <div style="flex:1;font-size:13px;color:var(--ink);font-weight:${n.is_read?'400':'600'};overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${n.is_pinned?'<span class="material-icons-round notranslate" translate="no" style="font-size:13px;color:var(--pink);vertical-align:-2px">push_pin</span> ':''}${esc(n.title)}</div>
      <div style="font-size:11px;color:var(--muted);flex-shrink:0">${n.published_at?formatDate(n.published_at):(n.created_at?formatDate(n.created_at):'')}</div>
    </div>
  `).join('');
}

// 로그인 직후 미읽음 공지 팝업 — published 미읽음만
async function showAdminUnreadNoticesIfAny() {
  if (!Array.isArray(_adminNoticesCache) || _adminNoticesCache.length === 0) return;
  const unread = _adminNoticesCache.filter(n => n.status === 'published' && !n.is_read);
  if (unread.length === 0) return;
  const countEl = $('adminNoticeUnreadCount');
  if (countEl) countEl.textContent = `${unread.length}건`;
  const body = $('adminNoticeUnreadBody');
  if (body) {
    body.innerHTML = unread.slice(0, 5).map(n => `
      <div style="padding:14px;border:1px solid var(--line);border-radius:8px;margin-bottom:10px">
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px">${adminNoticeCatPill(n.category)}<div style="font-weight:700;font-size:14px;color:var(--ink)">${n.is_pinned?'<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--pink);vertical-align:-2px">push_pin</span> ':''}${esc(n.title)}</div></div>
        <div style="font-size:11px;color:var(--muted);margin-bottom:8px">${esc(n.created_by_name||'—')} · ${n.published_at?formatDateTime(n.published_at):(n.created_at?formatDateTime(n.created_at):'')}</div>
        <div class="rich-content" data-notice-body="${esc(n.id)}" style="font-size:12px;line-height:1.6;color:var(--ink);max-height:140px;overflow:hidden"></div>
        <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:8px">
          <button class="btn btn-primary btn-xs" onclick="onShowDetailFromUnreadPopup('${esc(n.id)}')">상세 보기</button>
        </div>
      </div>
    `).join('');
    // 본문 부분만 renderRich(el, raw) 시그니처로 주입
    unread.slice(0, 5).forEach(n => {
      const el = document.querySelector(`[data-notice-body="${n.id}"]`);
      if (!el) return;
      if (typeof renderRich === 'function') renderRich(el, n.body_html || '');
      else if (typeof sanitizeRich === 'function') el.innerHTML = sanitizeRich(n.body_html || '');
      else el.innerHTML = n.body_html || '';
    });
  }
  openModal('adminNoticeUnreadModal');
}

// 미읽음 팝업 → 상세 모달로 전환 (전환 시 자동 읽음 처리는 openAdminNoticeView가 담당)
function onShowDetailFromUnreadPopup(id) {
  closeModal('adminNoticeUnreadModal');
  openAdminNoticeView(id);
}
