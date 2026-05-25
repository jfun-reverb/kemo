// ════════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin.js
// ════════════════════════════════════════════════════════════════════
//
// 분리 작업 진행 중 (docs/refactoring/admin-js-split-plan.md §4 — Phase 0).
// 본 파일은 페인 단위 분리 직전의 마지막 단일 파일 스냅샷이다.
// 아래 SECTION 경계 주석은 향후 dev/js/admin/<pane>.js 로 옮겨질
// 1:1 매핑이며, 분리 PR 진행 시 grep 기준점으로 사용한다.
//
// ── 페인 인덱스 (대략 위치) ──────────────────────────────────────
//   CORE                  광역 헬퍼 (switchAdminPane, multi-filter,
//                         friendlyError, formatReviewer, msgCell,
//                         consentBadge, openImageLightbox, _adminEmails,
//                         showConfirm 등) — 파일 곳곳에 분포
//   DASHBOARD             loadAdminData / 캠페인 분포 / 가입 추이 /
//                         프로필 완성률 / 주소 도넛
//   CAMPAIGNS · LIST      필터·정렬·드롭다운·더보기·미리보기·삭제·복제
//   CAMPAIGNS · FORM      Quill / flatpickr / 민감 변경 잠금 /
//                         pset·cset 캠페인 폼 통합 / addCampaign /
//                         saveCampaignEdit / brand FK 셀렉트
//   CAMP-APPLICANTS       캠페인별 신청자 페인 (OT 체크 + 결과물 셀)
//   INFLUENCERS           목록 + 상세 모달 + verify/violation/blacklist
//   APPLICATIONS          신청 관리 (renderAppCampList 캐시 공유)
//   MY-ACCOUNT            본인 계정 + updateSidebarProfile
//   ADMIN-ACCOUNTS        관리자 계정 CRUD + 초대/삭제 RPC
//   LOOKUPS               기준 데이터 (channel/category/content_type/
//                         ng_item/reject_reason/violation/blacklist 등)
//   PARTICIPATION-SETS    참여방법 번들
//   CAUTION-SETS          주의사항 번들 (미니 에디터 + 링크 팝오버)
//   DELIVERABLES          결과물 검수 페인 + 라이트박스
//   EXCEL                 ExcelJS lazy-load + 4종 export 함수
//   ADMIN-NOTICES         공지사항 페인 + 대시보드 카드 + 미읽음 팝업
//
//   (BRAND 5종은 PR #148 에서 이미 dev/js/admin-brand.js 로 분리됨)
//
// ── 분리 시 주의 ─────────────────────────────────────────────────
// · HTML 162곳 onclick 호출이 전역 함수 이름에 강결합 → 이름 변경 금지
// · `_adminEmails` `_currentDetailInfluencer` `_delivCache` 등
//   상태 변수는 한 파일에서만 선언 (양쪽 잔존 시 캐시 회귀)
// · `loadAdminData` 가 `refreshAdminNoticeBadge` /
//   `renderDashboardNotices` / `showAdminUnreadNoticesIfAny` /
//   `refreshDelivSidebarBadge` / `fetchViolationCountsByInfluencer`
//   를 직접 호출 → 빌드 순서 / typeof 가드 확인
// · `switchAdminPane` 의 loaders 객체가 각 페인 진입 함수를 이름으로
//   참조 → 페인 분리 후에도 전역에 살아 있어야 함
// · 분리 직전 함수 집합 baseline 확보용 :
//     grep -E "^(async )?function " dev/js/admin.js | wc -l
//
// ════════════════════════════════════════════════════════════════════


// ════════════════════════════════════════════════════════════════════
// SECTION: DASHBOARD — 메인 로드 + 캠페인 분포
//   refreshAdminNoticeBadge / renderDashboardNotices /
//   showAdminUnreadNoticesIfAny / refreshDelivSidebarBadge /
//   fetchViolationCountsByInfluencer 를 직접 호출 — 빌드 순서 확인
// ════════════════════════════════════════════════════════════════════

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
  // 대시보드는 apps 전건을 KPI용으로 이미 보유 → 추가 count 쿼리 없이 인라인 계산.
  // 그 외 경로(부트의 대시보드 외 페인)는 refreshApplySidebarBadge() 가 가벼운 count 로 갱신.
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length>999?'999+':pending.length}</span>`:''}`;
  refreshDelivSidebarBadge();
}

// 최근 신청 렌더 — 대시보드에서 운영 현황 페인으로 이관 (브랜드 운영 재설계 PR 3)
// 운영 현황 페인(loadBrandOps)에서 apps/camps/users 를 넘겨 호출한다.
function renderRecentAppsTable(apps, camps, users) {
  if (!$('recentAppsBody')) return;
  const recent = apps.slice().sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
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
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,96,70)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
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
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
      </td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

function renderCampaignBreakdown(camps) {
  const statusEl = $('campStatusBreakdown');
  const chEl = $('campChannelBreakdown');
  if (!statusEl || !chEl) return;

  const statusDef = [
    {key:'draft',     label:'준비',     color:'#9aa0a6', bg:'#F1F3F4'},
    {key:'scheduled', label:'모집예정', color:'#5B7CFF', bg:'#EEF2FF'},
    {key:'active',    label:'모집중',   color:'#0E7E4A', bg:'#E8F7EF'},
    {key:'closed',    label:'종료',     color:'#B91C5C', bg:'#FFE4EC'},
    {key:'expired',   label:'노출마감', color:'#666666', bg:'#EEEEEE'},
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

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · LIST — 필터/소트 표면
// ════════════════════════════════════════════════════════════════════

function filterAdminCampaigns() { loadAdminCampaigns(true); }
// 검색창 전용 — 글자 연타 시 마지막 입력만 반영(0.3초). 드롭다운 필터는 즉시 호출 유지.
const debouncedFilterAdminCampaigns = debounce(filterAdminCampaigns, 300);

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


// 캠페인 전용 래퍼 — 라벨은 캠페인 제목, 캠페인 번호(B0019-C001 형식)는 subLabel로 분리
//   counts: {[campaignId]: number} 형태로 옵션별 건수를 받아 옆에 (00)으로 표시
function syncCampMultiFilter(containerId, sortedCamps, onChange, counts) {
  const options = sortedCamps.map(c => ({
    value: c.id,
    label: c.title || '(제목 없음)',
    subLabel: c.campaign_no || '',
    count: counts ? (counts[c.id] || 0) : null
  }));
  syncMultiFilter(containerId, '전체 캠페인', options, onChange);
}

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · LIST — 정렬/상태/순서/이미지/목록
// ════════════════════════════════════════════════════════════════════

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



// 캠페인 상태별 클라이언트 노출 도움말 모달 노출
function openCampStatusHelp() {
  if (typeof openModal === 'function') openModal('campStatusHelpModal');
}

function updateCampTableHead() {
  const head = $('adminCampTableHead');
  if (!head) return;
  const statusHelpIcon = `<span class="material-icons-round notranslate" translate="no" title="상태별 클라이언트 노출 안내" style="font-size:14px;cursor:pointer;color:var(--muted);vertical-align:middle;margin-left:2px" onclick="event.stopPropagation();openCampStatusHelp()">info_outline</span>`;
  if (adminReorderMode) {
    head.innerHTML = `<tr><th>순서</th><th>캠페인</th><th>브랜드</th><th>제품</th><th>상태 ${statusHelpIcon}</th><th>노출</th><th>신청</th><th>조회</th><th>등록일</th><th>수정일</th></tr>`;
  } else {
    head.innerHTML = `<tr>
      <th style="width:44px;min-width:44px;max-width:44px;text-align:center;padding:8px 4px"><input type="checkbox" id="campSelectAll" onchange="toggleCampSelectAll(this.checked)" title="필터 결과 전체 선택"></th>
      <th>캠페인</th>
      <th>브랜드</th>
      <th>제품</th>
      <th>상태 ${statusHelpIcon} <span class="sort-arrows" data-sort="status" onclick="toggleCampSort('status')">${adminCampSortKey==='status'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th style="width:64px;min-width:64px;text-align:center" title="캠페인 노출 토글 (OFF 시 인플 화면 비노출)">노출</th>
      <th>신청 (신청/모집)(승인/대기) <span class="sort-arrows" data-sort="apps" onclick="toggleCampSort('apps')">${adminCampSortKey==='apps'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
      <th>모집기간</th>
      <th>구매기간</th>
      <th>결과물 제출 마감</th>
      <th>조회 <span class="sort-arrows" data-sort="views" onclick="toggleCampSort('views')">${adminCampSortKey==='views'?(adminCampSortDir==='asc'?'▲':'▼'):'▲▼'}</span></th>
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

// 캠페인 목록의 신청 집계 캐시 — { [campaign_id]: {total, approved, pending} } 맵.
// 검색/필터/정렬(useCache=true)에서는 재사용해 서버 재조회를 막는다.
// 페인 재진입·실데이터 갱신(useCache=false) 시에만 새로 fetch (allCampaigns 와 동일한 갱신 정책).
// ⚠️ 이 캐시는 useCache=falsy(인자 없는 호출) 경로로만 갱신된다.
//    신청 승인/반려 후 캠페인 페인으로 돌아오면 switchAdminPane('campaigns') → loaders.campaigns()
//    가 loadAdminCampaigns 를 인자 없이 호출하므로 자동 갱신된다.
//    loadAdminCampaigns(true) 직접 호출은 캐시를 갱신하지 않으니, 신청 상태가 바뀐 직후 경로에서는 쓰지 말 것.
var _campListCounts = null;

// 캠페인 다중 선택 — 현재 필터/정렬 적용된 캠페인 리스트 캐시
// loadAdminCampaigns 가 매 호출마다 갱신. toggleCampSelectAll·updateCampSelectionUI 에서 참조
var _currentFilteredCamps = [];
function getCurrentFilteredCamps() { return _currentFilteredCamps; }

async function loadAdminCampaigns(useCache) {
  updateCampTableHead();
  // PR 2 데이터 다이어트: 목록 전용 가벼운 함수 사용 (participation_steps 등 무거운 컬럼 제외)
  let camps = useCache ? allCampaigns.slice() : await fetchCampaignsForAdminList();
  if (!useCache) allCampaigns = camps.slice();

  // 상태·모집타입별 건수 요약 (필터 전 전체 기준)
  const stCounts = {};
  const rtCounts = {};
  allCampaigns.forEach(c => {
    stCounts[c.status] = (stCounts[c.status]||0) + 1;
    if (c.recruit_type) rtCounts[c.recruit_type] = (rtCounts[c.recruit_type]||0) + 1;
  });
  // 다중 선택 드롭다운에 옵션별 (NN) 건수 업데이트
  syncMultiFilter('campTypeMulti', '전체 타입', [
    {value:'monitor', label:'리뷰어',  count: rtCounts.monitor || 0},
    {value:'gifting', label:'기프팅',  count: rtCounts.gifting || 0},
    {value:'visit',   label:'방문형',  count: rtCounts.visit || 0},
  ], () => filterAdminCampaigns());
  syncMultiFilter('campStatusMulti', '전체 상태', [
    {value:'draft',     label:'준비',     count: stCounts.draft || 0},
    {value:'scheduled', label:'모집예정', count: stCounts.scheduled || 0},
    {value:'active',    label:'모집중',   count: stCounts.active || 0},
    {value:'closed',    label:'종료',     count: stCounts.closed || 0},
    {value:'expired',   label:'노출마감', count: stCounts.expired || 0},
  ], () => filterAdminCampaigns());
  const stLabels = {active:'모집중',scheduled:'모집예정',draft:'준비',closed:'종료',expired:'노출마감'};
  // 노출 그룹(scheduled/active/closed)은 컬러, 비노출(draft/expired)은 회색·점선으로 시각 구분
  const stColors = {active:'var(--green)',scheduled:'#5B7CFF',draft:'var(--muted)',closed:'#B91C5C',expired:'#666666'};
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
  if (searchVal) camps = camps.filter(c => (c.title||'').toLowerCase().includes(searchVal) || (c.brand||'').toLowerCase().includes(searchVal) || (c.brand_ko||'').toLowerCase().includes(searchVal) || (c.product||'').toLowerCase().includes(searchVal) || (c.product_ko||'').toLowerCase().includes(searchVal) || (c.campaign_no||'').toLowerCase().includes(searchVal));

  updateFilterResetBtn('btnCampFilterReset', ['campTypeMulti','campStatusMulti'], 'adminCampSearch');

  // useCache(검색/필터/정렬)면 캐시 재사용 → 서버 재조회 0회. 캐시가 비어있으면 1회만 조회.
  // PR 4 서버 집계: 신청 전건 전송 대신 서버 집계 함수 1회 호출로 전환.
  const counts = (useCache && _campListCounts) ? _campListCounts : (_campListCounts = await fetchCampaignApplicationCounts());

  // 정렬
  const appCount = id => (counts[id]?.total || 0);
  if (adminReorderMode) {
    camps.sort((a,b) => {
      if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
      return new Date(b.created_at)-new Date(a.created_at);
    });
  } else if (adminCampSortKey) {
    const dir = adminCampSortDir === 'asc' ? 1 : -1;
    const statusOrder = {draft:0,scheduled:1,active:2,closed:3,expired:4};
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
  const statusLabel = {draft:'준비',scheduled:'모집예정',active:'모집중',closed:'종료',expired:'노출마감'};
  // 노출 그룹(scheduled/active/closed)과 비노출 그룹(draft/expired)을 색·점선으로 구분
  //   scheduled=파랑, active=초록, closed=핑크(게시 기간 살아있는 동안 노출 중)
  //   draft=회색+점선, expired=비노출 강조 회색+점선
  const statusBadgeClass = {draft:'badge-gray',scheduled:'badge-blue',active:'badge-green',closed:'badge-pink',expired:'badge-expired'};
  const statusBadge = s => {
    const cls = statusBadgeClass[s]||'badge-gray';
    // draft만 점선 인라인 — expired는 .badge-expired 자체에 dashed 정의되어 있어 인라인 불필요
    const dashed = s==='draft' ? 'border:1.5px dashed var(--muted);' : '';
    return `<div style="position:relative;display:inline-block">
      <span class="badge ${cls}" style="cursor:pointer;${dashed}display:inline-flex;align-items:center;gap:3px" onclick="toggleStatusDropdown(this)">${statusLabel[s]||s}<span style="font-size:10px;opacity:.7">▾</span></span>
    </div>`;
  };
  // 캠페인 노출 토글 (사양서 2026-05-13) — 별도 「노출」 컬럼. draft 비활성, expired=OFF, 그 외=ON
  const visibilityToggle = s => {
    const toggleDisabled = s === 'draft' ? ' is-disabled' : '';
    const toggleOn = (s !== 'expired' && s !== 'draft') ? ' is-on' : '';
    const ariaChecked = (s !== 'expired' && s !== 'draft') ? 'true' : 'false';
    const toggleAttrs = s === 'draft' ? 'disabled' : '';
    return `<button type="button" class="visibility-toggle is-mini${toggleOn}${toggleDisabled}" role="switch" aria-checked="${ariaChecked}" title="캠페인 노출 ON/OFF" ${toggleAttrs} onclick="onCampQuickVisibilityToggle(event, this.closest('tr')?.dataset.campId, '${s}')"><span class="visibility-toggle-knob"></span></button>`;
  };
  // 캠페인 다중 선택 — 현재 필터 결과를 전역 캐시 (전체 선택 헤더가 참조)
  _currentFilteredCamps = camps.slice();

  const campsBody = $('adminCampsBody');
  if (!campsBody) return;
  const buildCampRow = (c, i, totalLen) => {
    const cc = counts[c.id] || { total: 0, approved: 0, pending: 0 };
    const approvedCnt = cc.approved;
    const pendingCnt  = cc.pending;
    const pct = c.slots > 0 ? Math.round(approvedCnt/c.slots*100) : 0;
    const barColor = pct>=100?'var(--red)':pct>=60?'var(--gold)':'var(--green)';
    const imgs = [c.img1,c.img2,c.img3,c.img4,c.img5,c.img6,c.img7,c.img8,c.image_url].filter(Boolean).filter((v,idx,a)=>a.indexOf(v)===idx);
    const thumbUrl = imgs[0] || '';
    const imgCount = imgs.length;
    const isSelected = (_selectedCampIds && _selectedCampIds.has(c.id));
    return `<tr data-camp-id="${c.id}" data-id="${esc(c.id)}">
      ${adminReorderMode ? `<td style="white-space:nowrap">
        <div style="display:flex;gap:3px">
          <button class="btn btn-ghost btn-xs" ${i===0?'disabled':''} onclick="moveCampOrder('${c.id}',-1)" style="padding:2px 6px;font-size:13px">↑</button>
          <button class="btn btn-ghost btn-xs" ${i===totalLen-1?'disabled':''} onclick="moveCampOrder('${c.id}',1)" style="padding:2px 6px;font-size:13px">↓</button>
        </div>
      </td>` : `<td style="text-align:center;width:44px;min-width:44px;max-width:44px;padding:8px 4px"><input type="checkbox" class="camp-select-cb" data-camp-id="${esc(c.id)}" ${isSelected?'checked':''} onchange="toggleCampSelect('${c.id}', this.checked)"></td>`}
      <td style="min-width:300px;max-width:380px">
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:44px;height:44px;flex-shrink:0;border-radius:8px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? renderCroppedImg(thumbUrl, (c.image_crops||{}).img1, {thumb:96, quality:70, lazy:true}) : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:20px">${esc(c.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:var(--muted)">inventory_2</span>'}</span>`}
            ${imgCount > 1 ? `<span style="position:absolute;bottom:0;left:0;background:rgba(0,0,0,.65);color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:0 4px 0 0">+${imgCount}</span>` : ''}
          </div>
          <div style="min-width:0;flex:1">
            <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
              ${typeLabel(c.recruit_type)}
              ${c.campaign_no ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted);letter-spacing:0.02em">${esc(c.campaign_no)}</span>` : ''}
            </div>
            <strong style="cursor:pointer;color:var(--ink);display:block;word-break:break-word;line-height:1.4" onclick="openCampPreviewModal('${c.id}')">${esc(c.title)}</strong>
          </div>
        </div>
      </td>
      ${(()=>{
        const bp = c.brand_ko || c.brand || '';
        const bs = (c.brand_ko && c.brand && c.brand_ko !== c.brand) ? c.brand : '';
        const pp = c.product_ko || c.product || '';
        const ps = (c.product_ko && c.product && c.product_ko !== c.product) ? c.product : '';
        return `<td style="font-size:12px;color:var(--ink);min-width:100px;max-width:160px;word-break:break-word">
          ${bp?esc(bp):'—'}
          ${bs?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(bs)}</div>`:''}
        </td>
        <td style="font-size:12px;color:var(--ink);min-width:120px;max-width:220px;word-break:break-word">
          ${pp?esc(pp):'—'}
          ${ps?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(ps)}</div>`:''}
        </td>`;
      })()}
      <td style="white-space:nowrap;min-width:90px">${statusBadge(c.status)}</td>
      <td style="text-align:center;white-space:nowrap;min-width:64px">${visibilityToggle(c.status)}</td>
      <td>
        <div style="display:flex;align-items:center;gap:8px">
          <div style="width:48px;height:8px;background:var(--line);border-radius:4px;overflow:hidden">
            <div style="width:${Math.min(pct,100)}%;height:100%;background:${barColor};border-radius:4px"></div>
          </div>
          <button class="btn btn-ghost btn-xs" style="padding:2px 8px 4px;font-weight:700;color:${cc.total>0?'var(--ink)':'var(--muted)'};border-color:var(--line)" data-camp-title="${esc(c.title)}" onclick="openCampApplicants('${c.id}',this.dataset.campTitle)">
            ${cc.total} / ${c.slots}명
          </button>
          <span style="font-size:10px;font-weight:600;color:${approvedCnt>0?'var(--pink)':'var(--muted)'}">${approvedCnt}승인${pendingCnt>0?` · <span style="color:var(--gold)">${pendingCnt}대기</span>`:''}</span>
        </div>
      </td>
      ${adminReorderMode ? '' : (()=>{
        // 모집기간·구매기간·결과물 제출 마감 — 2026-05-15 컬럼 3종.
        //   각 셀 종료일 옆에 D-day 라벨 (모집 마감·구매 마감·결과물 마감 임박 시각화)
        //   recruit_type 별 분기: monitor=purchase_*, visit=visit_*, gifting=빈칸
        var ps = (c.recruit_type === 'monitor') ? c.purchase_start
               : (c.recruit_type === 'visit')   ? c.visit_start  : '';
        var pe = (c.recruit_type === 'monitor') ? c.purchase_end
               : (c.recruit_type === 'visit')   ? c.visit_end    : '';
        // 기간 셀: 시작 ~ 종료 + 종료일 기준 D-day 라벨
        var rangeCell = function(s, e) {
          if (!s && !e) return '<span style="color:var(--muted)">—</span>';
          var startTxt = s ? formatDate(s) : '—';
          var endTxt   = e ? formatDate(e) : '—';
          return startTxt + ' ~ ' + endTxt + (e ? ' ' + dDayLabel(e) : '');
        };
        var singleCell = function(d) {
          if (!d) return '<span style="color:var(--muted)">—</span>';
          return formatDate(d) + ' ' + dDayLabel(d);
        };
        return `
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${rangeCell(c.recruit_start, c.deadline)}</td>
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${rangeCell(ps, pe)}</td>
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${singleCell(c.submission_end)}</td>`;
      })()}
      <td style="font-size:13px;font-weight:600;color:var(--ink);white-space:nowrap">${(c.view_count||0).toLocaleString()}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDate(c.created_at)}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDateTime(c.updated_at||c.created_at)}</td>
      ${adminReorderMode ? '' : `<td style="position:relative">
        <span class="material-icons-round notranslate camp-more-btn" translate="no" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s" data-camp-title="${esc(c.title)}" onclick="toggleCampMoreMenu(event,this,'${c.id}',this.dataset.campTitle)">more_vert</span>
      </td>`}
    </tr>`;
  };
  // 일반 모드 13컬럼(체크/캠페인/브랜드/제품/상태/신청/모집기간/구매기간/제출마감/조회/등록일/수정일/액션)
  // 순서변경 모드 9컬럼(순서/캠페인/브랜드/제품/상태/신청/조회/등록일/수정일)
  const emptyHtml = `<tr><td colspan="${adminReorderMode ? 10 : 14}" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>`;
  if (adminReorderMode) {
    // 순서변경 모드: 전체 DOM 필요 (↑↓ 위치 인덱스 기반). lazy 비활성.
    if (campsLazy) { campsLazy.destroy(); campsLazy = null; }
    campsBody.innerHTML = camps.length ? camps.map((c, i) => buildCampRow(c, i, camps.length)).join('') : emptyHtml;
  } else if (campsLazy) {
    // 인스턴스 재생성 없이 행만 교체 (sentinel 정리·스크롤 복귀는 reset 내부 처리)
    campsLazy.reset(camps);
  } else {
    campsLazy = mountLazyList({
      tbody: campsBody,
      scrollRoot: campsBody.closest('.admin-table-wrap'),
      rows: camps,
      renderRow: (c) => buildCampRow(c, 0, camps.length),
      pageSize: CAMPS_PAGE_SIZE,
      emptyHtml,
    });
  }
  // 행 렌더 후 선택 UI (버튼/배지/select-all indeterminate) 동기화
  if (typeof updateCampSelectionUI === 'function') {
    setTimeout(updateCampSelectionUI, 0);
  }
}

// ── Quill 리치 텍스트 에디터 관리 ──
const RICH_EDITOR_IDS = ['editCampDesc','editCampAppeal','editCampGuide','newCampDesc','newCampAppeal','newCampGuide'];
const richEditors = {};

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — Quill 리치 텍스트 헬퍼
// ════════════════════════════════════════════════════════════════════

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
  // 빈 에디터 판정: Quill의 기본 placeholder 처리
  const plain = q.getText().trim();
  if (!plain) return '';
  // 2026-05-07: root.innerHTML이 인접 리스트를 분리해 출력하는 버그 회피.
  // Quill 2.x getSemanticHTML 우선 사용, 미존재 시 root.innerHTML로 폴백.
  let raw;
  try {
    raw = (typeof q.getSemanticHTML === 'function')
      ? q.getSemanticHTML(0)
      : q.root.innerHTML;
  } catch(_) {
    raw = q.root.innerHTML;
  }
  return (typeof sanitizeRich === 'function') ? sanitizeRich(raw) : raw;
}

// ── 캠페인 편집 ──
// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 편집 모달 + 민감 잠금 + 변경 이력
// ════════════════════════════════════════════════════════════════════

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
  // brand 드롭다운 + 신청 cascade 로드 (camp.brand_id, camp.source_application_id)
  loadCampBrandSelect('edit', camp.brand_id || '').then(async () => {
    if (camp.brand_id) {
      await loadCampSourceAppSelect('edit', camp.brand_id, camp.source_application_id || '');
      var srcWrap = $('editCampSourceAppContainer');
      if (srcWrap) srcWrap.style.display = '';
    }
    // hint 갱신
    onCampBrandChange('edit');
  });
  sv('editCampProduct', camp.product);
  sv('editCampProductKo', camp.product_ko || '');
  sv('editCampProductUrl', camp.product_url||'');
  sv('editCampSlots', camp.slots);
  sv('editCampProductPrice', camp.product_price||0);
  sv('editCampReward', camp.reward||0);
  sv('editCampRewardNote', camp.reward_note||'');
  sv('editCampSubmissionEnd', camp.submission_end||'');
  // 캠페인 노출 토글 — status 기준으로 ON/OFF 표시
  _renderCampVisibilityToggle('edit', camp.status, { recruit_start: camp.recruit_start, deadline: camp.deadline });
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

  // NG 사항 번들 복원 (migration 107 — 스냅샷 우선, 드롭다운은 recruit_type 필터)
  _nsetState.edit = Array.isArray(camp.ng_items)
    ? camp.ng_items.map(normalizeNgItem)
    : [];
  await populateCampNsetDropdown('edit', rtVal, camp.ng_set_id || null);
  renderCampNgItems('edit');
  renderCampBundleSummary('nset', 'edit');

  // 신청 동의 영향 영역(주의사항/참여방법) 변경 감지용 원본 스냅샷 보관
  // saveCampaignEdit 에서 신청자 ≥1건일 때 변경 여부를 비교하여 경고 모달 표시
  _editCampOriginal = {
    id: camp.id,
    status: camp.status || '',
    caution_set_id: camp.caution_set_id || null,
    caution_items: Array.isArray(camp.caution_items) ? JSON.parse(JSON.stringify(camp.caution_items)) : [],
    participation_set_id: camp.participation_set_id || null,
    participation_steps: Array.isArray(camp.participation_steps) ? JSON.parse(JSON.stringify(camp.participation_steps)) : [],
    ng_set_id: camp.ng_set_id || null,
    ng_items: Array.isArray(camp.ng_items) ? JSON.parse(JSON.stringify(camp.ng_items)) : [],
  };
  // closed 캠페인은 신청 동의 영향 영역을 readonly 처리 (DB 트리거가 이중 차단)
  applyEditFormSensitiveLocks(camp.status || '');

  switchAdminPane('edit-campaign', null);
}

// 캠페인 편집 폼: 신청 동의 영향 영역 readonly 토글
//   대상: 주의사항(caution) / 참여방법(participation) 요약 카드의 「편집」 버튼
//   조건: status === 'closed' 또는 'expired' 일 때 비활성화 + 잠금 메시지 노출
function applyEditFormSensitiveLocks(status) {
  const isLocked = status === 'closed' || status === 'expired';
  const lockLabel = status === 'expired' ? '노출마감' : '종료';
  ['Pset', 'Cset', 'Nset'].forEach(kind => {
    const card = $('editCamp' + kind + 'Summary');
    if (!card) return;
    const editBtn = card.querySelector('button[onclick*="openCampBundleModal"]');
    if (editBtn) {
      editBtn.disabled = isLocked;
      editBtn.style.opacity = isLocked ? '0.5' : '';
      editBtn.style.cursor = isLocked ? 'not-allowed' : '';
      editBtn.title = isLocked ? `${lockLabel} 캠페인은 수정할 수 없습니다` : '';
    }
    let lockMsg = card.querySelector('.bundle-lock-msg');
    if (isLocked) {
      if (!lockMsg) {
        lockMsg = document.createElement('div');
        lockMsg.className = 'bundle-lock-msg';
        lockMsg.style.cssText = 'font-size:11px;color:var(--muted);margin-top:6px;display:flex;align-items:center;gap:4px';
        card.appendChild(lockMsg);
      }
      lockMsg.innerHTML = `<span class="material-icons-round notranslate" translate="no" style="font-size:14px">lock</span>${lockLabel} 캠페인은 수정할 수 없습니다`;
    } else if (lockMsg) {
      lockMsg.remove();
    }
  });
}

// 주의사항/참여방법 변경 감지 (저장 직전 호출)
//   editPayload: collectCampCsetPayload + collectCampPsetPayload 결과
//   반환: {cautionChanged, participationChanged, anyChanged}
//   주의: JSON.stringify 키 순서 false-positive 방지를 위해 양쪽을 동일 키 순서로 정규화 후 비교
//         (DB jsonb 가 내려주는 키 순서가 collect*Payload 의 고정 순서와 다르면
//          값 변경 없이도 stringify 결과가 달라져 불필요한 경고 모달이 뜨는 회귀)
function detectSensitiveChange(editPayload) {
  const orig = _editCampOriginal || {};
  const normSteps = arr => {
    if (!Array.isArray(arr) || !arr.length) return null;
    return arr.map(s => ({
      title_ko: s.title_ko || '',
      title_ja: s.title_ja || '',
      desc_ko: s.desc_ko || '',
      desc_ja: s.desc_ja || '',
    }));
  };
  const normCautionItems = arr => {
    if (!Array.isArray(arr) || !arr.length) return [];
    return arr.map(s => ({
      html_ko: s.html_ko || '',
      html_ja: s.html_ja || '',
    }));
  };
  const normNgItems = arr => {
    if (!Array.isArray(arr) || !arr.length) return [];
    return arr.map(s => ({
      html_ko: s.html_ko || '',
      html_ja: s.html_ja || '',
    }));
  };
  const stable = v => JSON.stringify(v ?? null);
  const cautionChanged =
    (orig.caution_set_id || null) !== (editPayload.caution_set_id || null)
    || stable(normCautionItems(orig.caution_items)) !== stable(normCautionItems(editPayload.caution_items));
  const participationChanged =
    (orig.participation_set_id || null) !== (editPayload.participation_set_id || null)
    || stable(normSteps(orig.participation_steps)) !== stable(normSteps(editPayload.participation_steps));
  const ngChanged =
    (orig.ng_set_id || null) !== (editPayload.ng_set_id || null)
    || stable(normNgItems(orig.ng_items)) !== stable(normNgItems(editPayload.ng_items));
  return {
    cautionChanged,
    participationChanged,
    ngChanged,
    anyChanged: cautionChanged || participationChanged || ngChanged
  };
}

// 신청 동의 영향 영역 변경 경고 모달 (Promise<boolean> 반환)
//   기존 신청자 ≥1건 + caution/participation 변경 시 명시적 확인을 요구
//   기존 신청자가 동의한 시점의 스냅샷은 applications.caution_snapshot 에 보존되어 효력 유지됨을 안내
let _sensitiveChangeResolver = null;
function showSensitiveChangeConfirm({appCount, cautionChanged, participationChanged, ngChanged, orig, next}) {
  return new Promise(resolve => {
    _sensitiveChangeResolver = resolve;
    const safeRich = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => esc(String(h||'')));
    const renderCautionItems = (arr) => {
      if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
      return arr.map(it => `<li>${safeRich(it.html_ja || it.html_ko || '')}</li>`).join('');
    };
    const renderNgItemsForModal = (arr) => {
      if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
      return arr.map(it => `<li>${safeRich(it.html_ko || it.html_ja || '')}</li>`).join('');
    };
    const renderPsetSteps = (arr) => {
      if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
      const renderDesc = (typeof miniRichHtml === 'function') ? miniRichHtml : (h => esc(String(h||'')));
      return arr.map((s, i) => {
        const t = s.title_ko || s.title_ja || '';
        const d = s.desc_ko || s.desc_ja || '';
        return `<li><b>STEP ${i+1}</b> · ${esc(t)}${d ? `<div class="rich-content" style="font-size:11px;color:var(--muted)">${renderDesc(d)}</div>` : ''}</li>`;
      }).join('');
    };
    const sections = [];
    if (cautionChanged) {
      sections.push(`
        <div style="margin-top:14px">
          <div style="font-size:13px;font-weight:700;color:var(--ink);margin-bottom:6px">주의사항 변경</div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
            <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:var(--surface-container-low)">
              <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6">${renderCautionItems(orig?.caution_items)}</ul>
            </div>
            <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
              <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6">${renderCautionItems(next?.caution_items)}</ul>
            </div>
          </div>
        </div>
      `);
    }
    if (participationChanged) {
      sections.push(`
        <div style="margin-top:14px">
          <div style="font-size:13px;font-weight:700;color:var(--ink);margin-bottom:6px">참여방법 변경</div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
            <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:var(--surface-container-low)">
              <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6;list-style:none">${renderPsetSteps(orig?.participation_steps)}</ul>
            </div>
            <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
              <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6;list-style:none">${renderPsetSteps(next?.participation_steps)}</ul>
            </div>
          </div>
        </div>
      `);
    }
    if (ngChanged) {
      sections.push(`
        <div style="margin-top:14px">
          <div style="font-size:13px;font-weight:700;color:var(--ink);margin-bottom:6px">NG 사항 변경</div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
            <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:var(--surface-container-low)">
              <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6">${renderNgItemsForModal(orig?.ng_items)}</ul>
            </div>
            <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
              <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
              <ul style="margin:0;padding-left:18px;line-height:1.6">${renderNgItemsForModal(next?.ng_items)}</ul>
            </div>
          </div>
        </div>
      `);
    }
    const body = $('sensitiveChangeModalBody');
    if (body) {
      body.innerHTML = `
        <div style="font-size:13px;line-height:1.7;color:var(--ink)">
          이 캠페인에는 이미 <b style="color:#B3261E">${appCount}명</b>의 신청자가 있습니다.<br>
          변경 사항은 <b>이후 신규 신청자에게만 적용</b>되며, 기존 신청자가 동의한 시점의 문구는 그대로 효력을 유지합니다.
        </div>
        ${sections.join('')}
        <div style="margin-top:14px;padding:10px 12px;background:var(--surface-container-low);border-radius:8px;font-size:12px;color:var(--muted);line-height:1.6">
          ※ 변경 이력은 캠페인 더보기(︙) 메뉴 → 「변경 이력」에서 확인할 수 있습니다 (super_admin 한정).
        </div>
      `;
    }
    openModal('sensitiveChangeModal');
  });
}
function resolveSensitiveChangeModal(ok) {
  closeModal('sensitiveChangeModal');
  if (_sensitiveChangeResolver) { _sensitiveChangeResolver(!!ok); _sensitiveChangeResolver = null; }
}

// ── Phase 2: 캠페인 변경 이력 모달 (super_admin 한정) ──
//   더보기 메뉴 「변경 이력」 클릭 시 호출. campaign_caution_history 행을 시간 역순 타임라인으로 출력.
//   각 항목 헤더 클릭 → 해당 변경의 prev/next diff 펼침/접기 (배열 인덱스로 toggle)
const _cautionHistoryState = { list: [], openIndex: null, campId: null };

async function openCautionHistoryModal(campId) {
  if (!campId) return;
  if (currentAdminInfo?.role !== 'super_admin') {
    toast('변경 이력은 super_admin 만 열람할 수 있습니다','error');
    return;
  }
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  _cautionHistoryState.campId = campId;
  _cautionHistoryState.openIndex = null;
  const body = $('cautionHistoryModalBody');
  if (body) body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  openModal('cautionHistoryModal');
  try {
    const list = await fetchCautionHistory(campId);
    _cautionHistoryState.list = Array.isArray(list) ? list : [];
    renderCautionHistoryModal();
  } catch(e) {
    if (body) body.innerHTML = `<div style="padding:24px;color:#B3261E;font-size:13px">이력 불러오기 실패: ${esc(e.message||String(e))}</div>`;
  }
}

function renderCautionHistoryModal() {
  const body = $('cautionHistoryModalBody');
  if (!body) return;
  const list = _cautionHistoryState.list || [];
  const camp = (typeof allCampaigns !== 'undefined' ? allCampaigns : [])
    .find(c => c.id === _cautionHistoryState.campId);
  const headerLine = camp
    ? `<div style="font-size:12px;color:var(--muted);margin-bottom:14px">캠페인 · <b style="color:var(--ink)">${esc(camp.title || '')}</b>${camp.campaign_no ? ` <span style="color:var(--muted)">[${esc(camp.campaign_no)}]</span>` : ''}</div>`
    : '';
  if (!list.length) {
    body.innerHTML = `${headerLine}<div style="text-align:center;padding:40px;color:var(--muted);font-size:13px">아직 변경 이력이 없습니다.<br><span style="font-size:11px">주의사항/참여방법/NG 사항 변경이 발생하면 자동 기록됩니다.</span></div>`;
    return;
  }
  const safeRich = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => esc(String(h||'')));
  const renderCautionItems = (arr) => {
    if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
    return arr.map(it => `<li>${safeRich(it.html_ja || it.html_ko || '')}</li>`).join('');
  };
  // NG 항목: 관리자 페이지 한국어 원칙 — html_ko 우선, 없으면 html_ja 폴백
  const renderNgItems = (arr) => {
    if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
    return arr.map(it => `<li>${safeRich(it.html_ko || it.html_ja || '')}</li>`).join('');
  };
  const renderPsetSteps = (arr) => {
    if (!Array.isArray(arr) || !arr.length) return '<li style="color:var(--muted)">(없음)</li>';
    const renderDesc = (typeof miniRichHtml === 'function') ? miniRichHtml : (h => esc(String(h||'')));
    return arr.map((s, i) => {
      const t = s.title_ko || s.title_ja || '';
      const d = s.desc_ko || s.desc_ja || '';
      return `<li><b>STEP ${i+1}</b> · ${esc(t)}${d ? `<div class="rich-content" style="font-size:11px;color:var(--muted)">${renderDesc(d)}</div>` : ''}</li>`;
    }).join('');
  };
  const items = list.map((row, idx) => {
    const cautionChanged =
      (row.prev_caution_set_id || null) !== (row.next_caution_set_id || null)
      || JSON.stringify(row.prev_caution_items ?? null) !== JSON.stringify(row.next_caution_items ?? null);
    const participationChanged =
      (row.prev_participation_set_id || null) !== (row.next_participation_set_id || null)
      || JSON.stringify(row.prev_participation_steps ?? null) !== JSON.stringify(row.next_participation_steps ?? null);
    // NG 사항 변경 감지 — migration 109에서 추가된 컬럼 (없으면 null 취급)
    const ngChanged =
      (row.ng_set_id_prev || null) !== (row.ng_set_id_next || null)
      || JSON.stringify(row.ng_items_prev ?? null) !== JSON.stringify(row.ng_items_next ?? null);
    const tags = [];
    if (cautionChanged) tags.push('<span class="badge badge-pink" style="font-size:10px">주의사항</span>');
    if (participationChanged) tags.push('<span class="badge badge-blue" style="font-size:10px">참여방법</span>');
    if (ngChanged) tags.push('<span class="badge badge-ng" style="font-size:10px">NG 사항</span>');
    const ackBadge = row.bypass_warning_ack
      ? '<span class="badge badge-gold" style="font-size:10px" title="신청자 ≥1건 + 경고 모달 통과">경고 확인</span>'
      : '<span class="badge badge-gray" style="font-size:10px" title="신청자 0건 — 모달 미표시">자동</span>';
    const isOpen = _cautionHistoryState.openIndex === idx;
    const detailHtml = !isOpen ? '' : `
      <div style="padding:14px 16px;background:var(--surface-container-low);border-top:1px solid var(--line)">
        ${cautionChanged ? `
          <div style="margin-bottom:14px">
            <div style="font-size:12px;font-weight:700;color:var(--ink);margin-bottom:6px">주의사항</div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
              <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:#fff">
                <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6">${renderCautionItems(row.prev_caution_items)}</ul>
              </div>
              <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
                <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6">${renderCautionItems(row.next_caution_items)}</ul>
              </div>
            </div>
          </div>` : ''}
        ${participationChanged ? `
          <div${cautionChanged || ngChanged ? ' style="margin-bottom:14px"' : ''}>
            <div style="font-size:12px;font-weight:700;color:var(--ink);margin-bottom:6px">참여방법</div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
              <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:#fff">
                <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6;list-style:none">${renderPsetSteps(row.prev_participation_steps)}</ul>
              </div>
              <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
                <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6;list-style:none">${renderPsetSteps(row.next_participation_steps)}</ul>
              </div>
            </div>
          </div>` : ''}
        ${ngChanged ? `
          <div>
            <div style="font-size:12px;font-weight:700;color:var(--ink);margin-bottom:6px">NG 사항</div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:10px;font-size:12px">
              <div style="border:1px solid var(--line);border-radius:8px;padding:10px;background:#fff">
                <div style="font-size:11px;color:var(--muted);margin-bottom:4px">변경 전</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6">${renderNgItems(row.ng_items_prev)}</ul>
              </div>
              <div style="border:1px solid #f5b1b1;border-radius:8px;padding:10px;background:#fff5f5">
                <div style="font-size:11px;color:#B3261E;margin-bottom:4px;font-weight:700">변경 후</div>
                <ul style="margin:0;padding-left:18px;line-height:1.6">${renderNgItems(row.ng_items_next)}</ul>
              </div>
            </div>
          </div>` : ''}
        ${!cautionChanged && !participationChanged && !ngChanged ? `
          <div style="font-size:12px;color:var(--muted);padding:8px 0">변경 내용이 기록되지 않았습니다.</div>` : ''}
      </div>
    `;
    return `
      <div style="border:1px solid var(--line);border-radius:10px;margin-bottom:10px;overflow:hidden;background:#fff">
        <div style="padding:12px 16px;cursor:pointer;display:flex;align-items:center;gap:12px;justify-content:space-between" onclick="toggleCautionHistoryItem(${idx})">
          <div style="display:flex;flex-direction:column;gap:4px;min-width:0;flex:1">
            <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">
              ${tags.join('')} ${ackBadge}
              <span style="font-size:11px;color:var(--muted)">신청자 ${row.app_count_at_change}명</span>
            </div>
            <div style="font-size:12px;color:var(--ink)">
              <span style="font-weight:600">${esc(row.changed_by_name || '관리자')}</span>
              <span style="color:var(--muted)"> · ${esc(formatDateTime(row.changed_at))}</span>
            </div>
          </div>
          <span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted);transition:transform .2s;${isOpen?'transform:rotate(180deg)':''}">expand_more</span>
        </div>
        ${detailHtml}
      </div>
    `;
  }).join('');
  body.innerHTML = `${headerLine}<div>${items}</div>`;
}

function toggleCautionHistoryItem(idx) {
  _cautionHistoryState.openIndex = (_cautionHistoryState.openIndex === idx) ? null : idx;
  renderCautionHistoryModal();
}

function closeCautionHistoryModal() {
  closeModal('cautionHistoryModal');
  _cautionHistoryState.list = [];
  _cautionHistoryState.openIndex = null;
  _cautionHistoryState.campId = null;
}

// ── 편집용 이미지 관리 ──
var editCampImgData = [];
var editCampImgChanged = false;
registerImgList('editCampImgData', editCampImgData);

// 편집 진입 시점의 신청 동의 영향 영역 스냅샷 (caution/participation)
//   saveCampaignEdit 에서 변경 감지하여 신청자 ≥1건일 때 경고 모달 표시
var _editCampOriginal = null;

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


// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 날짜 / flatpickr (range + single)
//   _campRangePickers / _campSinglePickers 는 switchAdminPane 가
//   참조하므로 파일 분리 시 같은 모듈로 묶기
// ════════════════════════════════════════════════════════════════════

// 결과물 제출 마감일을 +19일로 자동 제안 (확인 모달)
//   baseKind: 'purchase'(monitor) | 'visit' | 'recruit'(gifting fallback)
//   - monitor: 구매 기간 종료일 + 19일
//   - visit:   방문 기간 종료일 + 19일
//   - gifting: 구매·방문 기간 없으므로 모집 종료일 + 19일
async function suggestSubmissionEnd(prefix, baseKind) {
  const baseSuffix = baseKind === 'purchase' ? 'PurchaseEnd'
    : baseKind === 'visit' ? 'VisitEnd'
    : 'Deadline';
  const baseDate = $(prefix + baseSuffix)?.value;
  if (!baseDate) return;
  const target = new Date(baseDate);
  target.setDate(target.getDate() + 19);
  const yyyy = target.getFullYear();
  const mm = String(target.getMonth() + 1).padStart(2, '0');
  const dd = String(target.getDate()).padStart(2, '0');
  const suggested = `${yyyy}-${mm}-${dd}`;
  const seEl = $(prefix+'SubmissionEnd');
  if (!seEl || seEl.value === suggested) return;
  const baseLabel = {purchase: '구매 기간 종료', visit: '방문 기간 종료', recruit: '모집 종료'}[baseKind] || '기준일';
  const ok = await showConfirm(`결과물 제출 마감일을 ${yyyy}년 ${mm}월 ${dd}일로 입력하시겠습니까?\n(${baseLabel} + 19일)`);
  if (ok) {
    seEl.value = suggested;
    syncCampDateMinMax(prefix);
    validateCampDateRangesInline(prefix);
  }
}

// 일자 자식 input들의 min/max 를 운영 흐름에 맞춰 동기화 (브라우저 단 차단)
//   구매·방문: [recruit_start||deadline] ~ [submission_end]
//   결과물 제출 마감일: max(recruit_start||deadline, purchase_end, visit_end) ~ (상한 없음)
function syncCampDateMinMax(prefix) {
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const pe = $(prefix+'PurchaseEnd')?.value || '';
  const ve = $(prefix+'VisitEnd')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const lower = rs || dl || '';
  const upperPV = se || '';
  // 구매·방문: lower ~ upperPV
  ['PurchaseStart','PurchaseEnd','VisitStart','VisitEnd'].forEach(suffix => {
    const el = $(prefix+suffix);
    if (!el) return;
    if (lower) el.min = lower; else el.removeAttribute('min');
    if (upperPV) el.max = upperPV; else el.removeAttribute('max');
  });
  // 결과물 제출 마감일: 구매·방문 종료일 이후 (없으면 lower) ~ (상한 없음 — post_deadline 제거)
  const seEl = $(prefix+'SubmissionEnd');
  if (seEl) {
    const seLower = [lower, pe, ve].filter(Boolean).sort().pop() || '';
    if (seLower) seEl.min = seLower; else seEl.removeAttribute('min');
    seEl.removeAttribute('max');
  }
  // 캠페인 노출 마감일 picker 는 사양서 §6-3 에 따라 제거됨 (토글로 대체)
  // flatpickr range picker (구매·방문) 도 같은 경계로 비활성 날짜 처리
  if (typeof syncCampRangePickerBounds === 'function') syncCampRangePickerBounds(prefix);
  // 단일 picker(SubmissionEnd) 비활성 날짜 동기화
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
      seFp.set('maxDate', null);
    }
  }
}

// flatpickr range picker 의 minDate/maxDate 를 hidden input 값에 맞춰 동적 갱신
//   구매·방문: [recruit_start || deadline] ~ [submission_end]
//   모집: 제한 없음 (관리자가 자유 입력)
function syncCampRangePickerBounds(prefix) {
  if (!_campRangePickers) return;
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const lower = rs || dl || '';
  const upperPV = se || '';
  ['Purchase', 'Visit'].forEach(kind => {
    const fp = _campRangePickers[prefix + kind + 'Range'];
    if (!fp) return;
    fp.set('minDate', lower || null);
    fp.set('maxDate', upperPV || null);
  });
}

// 입력값 검증 (저장 시 + onchange 인라인 경고). 위반 메시지 배열 반환.
//   경계: 모집 시작일 ~ 결과물 제출 마감일 (post_deadline 제거 — migration 129)
function validateCampDateRanges(prefix) {
  const rs = $(prefix+'RecruitStart')?.value || '';
  const dl = $(prefix+'Deadline')?.value || '';
  const ps = $(prefix+'PurchaseStart')?.value || '';
  const pe = $(prefix+'PurchaseEnd')?.value || '';
  const vs = $(prefix+'VisitStart')?.value || '';
  const ve = $(prefix+'VisitEnd')?.value || '';
  const se = $(prefix+'SubmissionEnd')?.value || '';
  const errs = [];
  const lower = rs || dl || '';
  // 구매·방문 일자의 상한은 결과물 제출 마감일
  const upperPV = se || '';
  const inPVRange = (val) => {
    if (!val) return true;
    if (lower && new Date(val) < new Date(lower)) return false;
    if (upperPV && new Date(val) > new Date(upperPV)) return false;
    return true;
  };
  const upperPVLabel = se ? '결과물 제출 마감일' : '제한 없음';
  if (rs && dl && new Date(dl) < new Date(rs)) errs.push({kind:'recruit', msg:'모집 종료일은 모집 시작일 이후여야 합니다'});
  if (!inPVRange(ps)) errs.push({kind:'purchase', msg:`구매 시작일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (!inPVRange(pe)) errs.push({kind:'purchase', msg:`구매 마감일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (ps && pe && new Date(pe) < new Date(ps)) errs.push({kind:'purchase', msg:'구매 마감일은 구매 시작일 이후여야 합니다'});
  if (!inPVRange(vs)) errs.push({kind:'visit', msg:`방문 시작일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (!inPVRange(ve)) errs.push({kind:'visit', msg:`방문 마감일은 모집 시작일~${upperPVLabel} 사이여야 합니다`});
  if (vs && ve && new Date(ve) < new Date(vs)) errs.push({kind:'visit', msg:'방문 마감일은 방문 시작일 이후여야 합니다'});
  // 결과물 제출 마감일: 모집 시작 이후 + 구매·방문 종료일 이후
  if (se && lower && new Date(se) < new Date(lower)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 모집 시작일 이후여야 합니다'});
  if (se && pe && new Date(se) < new Date(pe)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 구매 종료일 이후여야 합니다'});
  if (se && ve && new Date(se) < new Date(ve)) errs.push({kind:'submission', msg:'결과물 제출 마감일은 방문 종료일 이후여야 합니다'});
  return errs;
}

// 종류별 row 아래 div 매핑 — 한 row에 여러 위반이 있으면 같은 div에 누적 표시
const CAMP_DATE_WARN_TARGETS = {
  recruit:    'RecruitWarn',
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
    // gifting 캠페인은 구매·방문 기간이 없으므로 모집 종료일 기준 +19일 fallback 제안
    const rtName = prefix === 'editCamp' ? 'editRecruitType' : 'newRecruitType';
    const currentRt = document.querySelector(`input[name="${rtName}"]:checked`)?.value || 'monitor';
    if (currentRt === 'gifting' && end) suggestSubmissionEnd(prefix, 'recruit');
  }
  // monitor=구매 종료, visit=방문 종료 기준 +19일 제안
  if ((kind === 'purchase' || kind === 'visit') && end) {
    suggestSubmissionEnd(prefix, kind);
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
// flatpickr appendTo:body 모드 viewport 좌우 경계 보정
//   - flatpickr position:'auto'는 위/아래만 자동 결정. 좌우는 input
//     의 left 좌표를 그대로 따라가 viewport 밖으로 잘리는 사고 발생.
//   - 캘린더가 우측 viewport를 넘으면 left를 줄여 안으로 이동.
//   - 캘린더가 좌측 viewport를 넘으면 left를 늘려 안으로 이동.
//   - 위치 계산이 끝난 뒤 다음 프레임에 보정 (race 회피).
// ─────────────────────────────────────────────────────────────────
function _clampFpToViewport(fpInst) {
  if (!fpInst || !fpInst.calendarContainer) return;
  const cal = fpInst.calendarContainer;
  requestAnimationFrame(() => {
    const margin = 8;
    const vw = document.documentElement.clientWidth;
    let rect = cal.getBoundingClientRect();
    let currLeft = parseFloat(cal.style.left) || 0;
    if (rect.right > vw - margin) {
      currLeft -= (rect.right - (vw - margin));
      cal.style.left = currLeft + 'px';
    }
    rect = cal.getBoundingClientRect();
    if (rect.left < margin) {
      currLeft += (margin - rect.left);
      cal.style.left = currLeft + 'px';
    }
  });
}

// ─────────────────────────────────────────────────────────────────
// 캘린더를 input 위치에 맞춰 재정렬 (스크롤 동기화용)
//   - appendTo:document.body 모드라 캘린더는 페이지 좌표 기준 absolute
//   - 관리자 메인 영역 스크롤은 body 스크롤이 아니라 input의 viewport
//     rect가 변경됨 → 캘린더는 그 자리에 남아 input과 따로 놀게 됨
//   - 캘린더 top/left를 input.getBoundingClientRect() + 페이지 스크롤
//     offset 으로 재계산해서 input 바로 아래(또는 viewport 하단 잘림
//     시 위)에 다시 붙임
//   - viewport 우/좌 잘림은 _clampFpToViewport 재사용
// ─────────────────────────────────────────────────────────────────
function _repositionFpAtInput(fpInst) {
  if (!fpInst || !fpInst.isOpen || !fpInst.calendarContainer || !fpInst.input) return;
  const cal = fpInst.calendarContainer;
  const inputRect = fpInst.input.getBoundingClientRect();
  const margin = 4;
  const calHeight = cal.offsetHeight;
  const vh = document.documentElement.clientHeight;
  const scrollY = window.pageYOffset || document.documentElement.scrollTop || 0;
  const scrollX = window.pageXOffset || document.documentElement.scrollLeft || 0;
  // 기본: input 아래
  let top = inputRect.bottom + margin;
  // viewport 하단을 넘고 위쪽 공간이 충분하면 input 위로 flip
  if (top + calHeight > vh - margin && inputRect.top - margin - calHeight > 0) {
    top = inputRect.top - margin - calHeight;
  }
  // 페이지 스크롤 좌표로 환산 (body가 스크롤 안 되면 0)
  cal.style.top = (top + scrollY) + 'px';
  cal.style.left = (inputRect.left + scrollX) + 'px';
  // 좌우 viewport 보정 (다음 프레임)
  _clampFpToViewport(fpInst);
}

// ─────────────────────────────────────────────────────────────────
// 스크롤 시 캘린더가 input 위치를 따라오도록 listener 부착/해제
//   - capture:true 로 등록해 관리자 메인 영역의 스크롤까지 잡음
//     (메인 영역은 body 가 아닌 자체 overflow:auto 컨테이너로 스크롤됨)
//   - passive:true 로 스크롤 성능 영향 최소화
//   - onOpen 시 부착, onClose 시 해제 (메모리 누수 방지)
// ─────────────────────────────────────────────────────────────────
function _attachFpScrollSync(fpInst) {
  if (!fpInst || fpInst._reverbScrollHandler) return;
  // requestAnimationFrame throttle: 빠른 스크롤 중 rAF 콜백이 누적되지 않도록
  // 1프레임 동안 한 번만 reposition 호출. 관리자 PC 환경에서 실측 부하는 낮으나
  // 안전망 차원에서 적용.
  let rafId = null;
  fpInst._reverbScrollHandler = () => {
    if (rafId) return;
    rafId = requestAnimationFrame(() => {
      rafId = null;
      _repositionFpAtInput(fpInst);
    });
  };
  window.addEventListener('scroll', fpInst._reverbScrollHandler, { passive: true, capture: true });
  window.addEventListener('resize', fpInst._reverbScrollHandler, { passive: true });
}
function _detachFpScrollSync(fpInst) {
  if (!fpInst || !fpInst._reverbScrollHandler) return;
  window.removeEventListener('scroll', fpInst._reverbScrollHandler, { capture: true });
  window.removeEventListener('resize', fpInst._reverbScrollHandler);
  fpInst._reverbScrollHandler = null;
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
        _clampFpToViewport(fpInst);
        _attachFpScrollSync(fpInst);
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
        _detachFpScrollSync(fpInst);
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
        // viewport 좌우 보정 (recruit 조기 반환 전에 호출해 모든 range picker 적용)
        _clampFpToViewport(fpInst);
        // 페이지·메인 영역 스크롤 시 캘린더가 input 위치를 따라가도록 listener 부착
        _attachFpScrollSync(fpInst);
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
        _detachFpScrollSync(fpInst);
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

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 편집 저장
// ════════════════════════════════════════════════════════════════════

async function saveCampaignEdit() {
  try {
    const campId = $('editCampId').value;
    if (!campId) { toast('ID를 찾을 수 없습니다','error'); return; }
    const gv = id => {
      if (RICH_EDITOR_IDS.includes(id)) return getRichValue(id);
      return $(id)?.value||'';
    };
    const title = gv('editCampTitle').trim();
    const brandId = $('editCampBrandId')?.value || '';
    if (!title || !brandId) { toast('캠페인명과 브랜드는 필수입니다','error'); return; }
    const sourceAppId = $('editCampSourceAppId')?.value || null;
    const brand = gv('editCampBrand').trim();

    const editDeadline = gv('editCampDeadline');
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
      brand_id: brandId,
      source_application_id: sourceAppId || null,
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
      // 067 legacy 컬럼은 더 이상 갱신하지 않음 (070 마이그레이션에서 DROP 예정)
      // ng legacy 컬럼은 NG-PR-B에서 갱신 중단 — ng_set_id/ng_items 로 대체 (NG-PR-F에서 DROP 예정)
      status: gv('editCampStatus'),
      ...collectCampPsetPayload('edit'),
      ...collectCampCsetPayload('edit'),
      ...collectCampNsetPayload('edit'),
    };

    // 신청 동의 영향 영역(주의사항/참여방법) 변경 게이트
    //   1) closed 캠페인: UI 카드가 lock 상태라 사용자가 직접 수정할 수 없음. collect 결과의
    //      sanitize 한 번 더 적용 등 미세 차이로 detectSensitiveChange 가 false-positive를
    //      잡아 「날짜만 수정해도 차단」되는 회귀가 있어, 안전하게 caution/participation
    //      필드 4개를 updates에서 제거하고 비교 자체를 skip — db 값 그대로 유지된다.
    //   2) draft~closed 캠페인: 신청자 ≥1건 + 변경 감지 시 경고 모달로 명시적 확인 요구
    //   3) Phase 2 — 변경 감지 시 audit 이력 기록 (campaign_caution_history)
    const origStatus = (_editCampOriginal && _editCampOriginal.status) || '';
    let _historyAppCount = 0;
    let _historyBypassAck = false;
    let change = {cautionChanged:false, participationChanged:false, ngChanged:false, anyChanged:false};
    if (origStatus === 'closed' || origStatus === 'expired') {
      delete updates.caution_set_id;
      delete updates.caution_items;
      delete updates.participation_set_id;
      delete updates.participation_steps;
      delete updates.ng_set_id;
      delete updates.ng_items;
    } else {
      change = detectSensitiveChange(updates);
      if (change.anyChanged) {
        _historyAppCount = await countActiveApplications(campId);
        if (_historyAppCount >= 1) {
          const ok = await showSensitiveChangeConfirm({
            appCount: _historyAppCount,
            cautionChanged: change.cautionChanged,
            participationChanged: change.participationChanged,
            ngChanged: change.ngChanged,
            orig: _editCampOriginal,
            next: updates
          });
          if (!ok) return;
          _historyBypassAck = true;
        }
      }
    }

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

    // Phase 2 — 주의사항/참여방법 변경 감지 시 audit 이력 기록
    //   updateCampaign 성공 직후 호출. 실패해도 캠페인 저장은 이미 완료됐으므로
    //   사용자 흐름은 차단하지 않고 콘솔 경고만 남긴다 (audit 부재 ≠ 데이터 손상).
    if (change.anyChanged) {
      try {
        await recordCautionHistory({
          campaign_id: campId,
          prev: {
            caution_set_id: _editCampOriginal?.caution_set_id || null,
            caution_items: _editCampOriginal?.caution_items || [],
            participation_set_id: _editCampOriginal?.participation_set_id || null,
            participation_steps: _editCampOriginal?.participation_steps || null,
            ng_set_id: _editCampOriginal?.ng_set_id || null,
            ng_items: _editCampOriginal?.ng_items || [],
          },
          next: {
            caution_set_id: updates.caution_set_id || null,
            caution_items: updates.caution_items || [],
            participation_set_id: updates.participation_set_id || null,
            participation_steps: updates.participation_steps || null,
            ng_set_id: updates.ng_set_id || null,
            ng_items: updates.ng_items || [],
          },
          app_count: _historyAppCount,
          bypass_ack: _historyBypassAck,
        });
      } catch(histErr) {
        console.warn('[caution-history] 기록 실패 (캠페인 저장은 정상):', histErr);
      }
    }

    allCampaigns = await fetchCampaigns();
    toast('변경 사항을 저장했습니다','success');
    switchAdminPane('campaigns', null);
  } catch(err) {
    toast('저장 오류: '+friendlyError(err.message),'error');
  }
}

// 캠페인 복제
// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · LIST — 복제/삭제/미리보기/더보기/상태 드롭다운
// ════════════════════════════════════════════════════════════════════

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
      // NG 사항 번들 스냅샷도 함께 복제 (migration 107)
      ng_set_id: src.ng_set_id || null,
      ng_items: Array.isArray(src.ng_items) ? JSON.parse(JSON.stringify(src.ng_items)) : [],
      product_price: src.product_price, reward: src.reward, reward_note: src.reward_note,
      slots: src.slots, applied_count: 0,
      recruit_start: src.recruit_start, deadline: src.deadline,
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
  const cset = (typeof collectCampCsetPayload === 'function') ? collectCampCsetPayload(mode) : {};
  const nset = (typeof collectCampNsetPayload === 'function') ? collectCampNsetPayload(mode) : {};
  // edit 모드: NG legacy(`camp.ng`) 폴백을 _editCampOriginal에서 가져옴 (폼에 더 이상 NG Quill 없음)
  const ngLegacy = (mode === 'edit' && typeof _editCampOriginal !== 'undefined') ? (_editCampOriginal?.ng || '') : '';
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
    purchase_start: val(g+'PurchaseStart')||null,
    purchase_end: val(g+'PurchaseEnd')||null,
    visit_start: val(g+'VisitStart')||null,
    visit_end: val(g+'VisitEnd')||null,
    submission_end: val(g+'SubmissionEnd')||null,
    winner_announce: val(g+'WinnerAnnounce')||'',
    description: typeof getRichValue === 'function' ? getRichValue(g+'Desc') : '',
    appeal: typeof getRichValue === 'function' ? getRichValue(g+'Appeal') : '',
    guide: typeof getRichValue === 'function' ? getRichValue(g+'Guide') : '',
    ng: ngLegacy,
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
    ...cset,
    ...nset,
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
  // monitor(리뷰어) 캠페인은 「ペイバック」 워딩, 그 외는 기존 「相当の製品を無償提供」
  const isMonitorPreview = camp.recruit_type === 'monitor';
  const rewardLabelJa = isMonitorPreview ? '円ペイバック' : '円相当の製品を無償提供';
  const rewardText = (camp.product_price>0 || camp.reward>0)
    ? `${camp.product_price>0?`¥${camp.product_price.toLocaleString()} ${rewardLabelJa}`:'商品無償提供'}${camp.reward>0?` + ¥${camp.reward.toLocaleString()} 報酬`:''}`
    : '';

  // 참여방법 (스냅샷만 사용 — legacy 폴백 제거, migration 110으로 운영 백필 완료)
  const steps = Array.isArray(camp.participation_steps) ? camp.participation_steps : [];

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
          ${camp.product_price>0?`<div class="cp-price-box"><span class="cp-price-amount">¥${camp.product_price.toLocaleString()}</span><span class="cp-price-label">${rewardLabelJa}</span></div>`:''}
          ${camp.reward>0?`<div class="cp-reward-cash">+ ¥${camp.reward.toLocaleString()} 報酬</div>`:''}
        </div>
        <div class="cp-info">
          ${(()=>{
            // 시간 흐름 순: 製品名 → 募集タイプ → チャンネル → コンテンツ → 募集期間 → 購入/訪問 → 提出締切 → 募集人数
            //              → (monitor 외) 当選発表 → (monitor 외) 報酬
            const rows = [];
            rows.push(`<div class="cp-info-row"><div class="cp-info-key">製品名</div><div class="cp-info-val">${esc(camp.product||'—')}</div></div>`);
            rows.push(`<div class="cp-info-row"><div class="cp-info-key">募集タイプ</div><div class="cp-info-val">${rtBadge?`<span class="cp-rt-badge" style="background:${rtBadge.bg};color:${rtBadge.color}">${rtBadge.label}</span>`:'—'}</div></div>`);
            if (channelNames.length) rows.push(`<div class="cp-info-row"><div class="cp-info-key">チャンネル</div><div class="cp-info-val"><div class="cp-chips">${channelNames.map((n,i)=>(i>0?`<span class="cp-chip-sep">${chSep}</span>`:'')+`<span class="cp-chip">${esc(n)}</span>`).join('')}</div></div></div>`);
            if (contentTypeNames.length) rows.push(`<div class="cp-info-row"><div class="cp-info-key">コンテンツ種類</div><div class="cp-info-val"><div class="cp-chips">${contentTypeNames.map(n=>`<span class="cp-chip cp-chip-sm">${esc(n)}</span>`).join('')}</div></div></div>`);
            rows.push(`<div class="cp-info-row"><div class="cp-info-key">募集期間</div><div class="cp-info-val">${fmt(camp.recruit_start || new Date())} 〜 ${fmt(camp.deadline)}</div></div>`);
            if (isMonitorPreview && (camp.purchase_start || camp.purchase_end)) rows.push(`<div class="cp-info-row"><div class="cp-info-key">購入および領収書提出期間</div><div class="cp-info-val">${fmt(camp.purchase_start)} 〜 ${fmt(camp.purchase_end)}</div></div>`);
            if (camp.recruit_type === 'visit' && (camp.visit_start || camp.visit_end)) rows.push(`<div class="cp-info-row"><div class="cp-info-key">訪問期間</div><div class="cp-info-val">${fmt(camp.visit_start)} 〜 ${fmt(camp.visit_end)}</div></div>`);
            if (camp.submission_end) rows.push(`<div class="cp-info-row"><div class="cp-info-key">提出締切</div><div class="cp-info-val" style="font-weight:600">${fmt(camp.submission_end)}</div></div>`);
            if (camp.slots) rows.push(`<div class="cp-info-row"><div class="cp-info-key">募集人数</div><div class="cp-info-val">${camp.slots}名</div></div>`);
            if (camp.min_followers) rows.push(`<div class="cp-info-row"><div class="cp-info-key">最小フォロワー</div><div class="cp-info-val">${camp.min_followers.toLocaleString()}</div></div>`);
            // 리뷰어(monitor) 캠페인은 当選発表·報酬 행 제외
            if (!isMonitorPreview) {
              rows.push(`<div class="cp-info-row"><div class="cp-info-key">当選発表</div><div class="cp-info-val">${esc(camp.winner_announce||'選考後、LINEにてご連絡')}</div></div>`);
              if (rewardText || camp.reward_note) rows.push(`<div class="cp-info-row"><div class="cp-info-key">報酬</div><div class="cp-info-val cp-info-val-pink">${rewardText?esc(rewardText):''}${camp.reward_note?`<div style="margin-top:${rewardText?'6px':'0'};font-size:11px;color:var(--muted);font-weight:400;line-height:1.6;white-space:pre-wrap">${esc(camp.reward_note)}</div>`:''}</div></div>`);
            }
            return rows.join('');
          })()}
        </div>
        ${steps.length ? `<div class="cp-participation">
          <div class="cp-section-heading">参加方法</div>
          ${steps.map((s,i)=>{
            const title = s.title_ja || s.title_ko || '';
            const desc = s.desc_ja || s.desc_ko || '';
            const descHtml = (typeof miniRichHtml === 'function') ? miniRichHtml(desc) : esc(desc);
            return `<div class="cp-step"><div class="cp-step-num">STEP ${i+1}</div><div><div class="cp-step-title">${esc(title)}</div>${desc?`<div class="cp-step-desc rich-content">${descHtml}</div>`:''}</div></div>`;
          }).join('')}
        </div>` : ''}
        ${camp.product_url?`<div class="cp-product-link"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">shopping_bag</span> 商品ページ</div>`:''}
        ${camp.description?`<div class="cp-sec"><div class="cp-section-heading">キャンペーン説明</div><div class="cp-sec-desc-body rich-content">${richFn(camp.description)}</div></div>`:''}
        ${(camp.appeal||camp.hashtags||camp.mentions)?`<div class="cp-sec"><div class="cp-section-heading">投稿ガイドライン</div>
          ${camp.appeal?`<div style="margin-bottom:12px"><div class="cp-sec-subtitle">ブランドアピール</div><div class="cp-sec-body cp-sec-bg-pink rich-content">${richFn(camp.appeal)}</div></div>`:''}
          ${camp.hashtags?`<div style="margin-bottom:10px"><div class="cp-sec-subtitle">必須ハッシュタグ</div><div class="cp-chips">${camp.hashtags.split(',').filter(Boolean).map(t=>`<span class="cp-chip">${esc(t.trim())}</span>`).join('')}</div></div>`:''}
          ${camp.mentions?`<div><div class="cp-sec-subtitle">必須メンション</div><div class="cp-chips">${camp.mentions.split(',').filter(Boolean).map(t=>`<span class="cp-chip cp-chip-mention">${esc(t.trim())}</span>`).join('')}</div></div>`:''}
        </div>`:''}
        ${camp.guide?`<div class="cp-sec"><div class="cp-section-heading">撮影ガイド</div><div class="cp-sec-body cp-sec-bg-guide rich-content">${richFn(camp.guide)}</div></div>`:''}
        ${(() => {
          // NG 사항: ng_items(jsonb) 우선, 없으면 legacy camp.ng(Quill html) 폴백
          const ngItems = Array.isArray(camp.ng_items) ? camp.ng_items : [];
          const s = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => String(h||''));
          if (ngItems.length) {
            const lis = ngItems.map(it => `<li>${s(it.html_ja || it.html_ko || '')}</li>`).join('');
            return `<div class="cp-sec"><div class="cp-section-heading">NG事項</div><div class="cp-sec-body cp-sec-bg-ng"><ul style="margin:0;padding-left:18px;line-height:1.7">${lis}</ul></div></div>`;
          }
          if (camp.ng) {
            return `<div class="cp-sec"><div class="cp-section-heading">NG事項</div><div class="cp-sec-body cp-sec-bg-ng rich-content">${richFn(camp.ng)}</div></div>`;
          }
          return '';
        })()}
        ${(Array.isArray(camp.caution_items) && camp.caution_items.length) ? (() => {
          const s = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => String(h||''));
          const lis = camp.caution_items.map(it => `<li>${s(it.html_ja || it.html_ko || '')}</li>`).join('');
          return `<div class="cp-sec"><div class="cp-section-heading">注意事項</div><div class="cp-sec-body"><ul style="margin:0;padding-left:18px;line-height:1.7">${lis}</ul></div></div>`;
        })() : ''}
      </div>
      <div class="cp-cta">
        <div class="cp-cta-name">${esc(camp.title||'—')}<small>${camp.product_price>0?`¥${camp.product_price.toLocaleString()} ${rewardLabelJa}`:''}</small></div>
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

// position:fixed 로 body 에 append 된 팝오버/드롭다운을 anchor 위치에 배치하되 viewport 안에 머무르게 보정.
//   menuEl       : 이미 body 에 append 되어 offsetWidth/offsetHeight 측정 가능한 상태여야 함
//   anchorRect   : anchor 의 getBoundingClientRect() 결과
//   opts.placement
//     'left-of' — anchor 왼쪽에 띄움 (캠페인 더보기 ⋮ 패턴). 좌측 공간 부족 시 우측으로 폴백.
//     'below'   — anchor 아래에 띄움 (상태 드롭다운·링크 팝오버 패턴). 하단 공간 부족 시 위로 폴백.
//   opts.gap     : anchor 와 메뉴 사이 간격 (px, 기본 4)
//   opts.margin  : viewport 가장자리 여백 (px, 기본 8)
function _positionMenuInViewport(menuEl, anchorRect, opts) {
  opts = opts || {};
  var placement = opts.placement || 'below';
  var gap = (opts.gap != null) ? opts.gap : 4;
  var margin = (opts.margin != null) ? opts.margin : 8;
  var vw = window.innerWidth;
  var vh = window.innerHeight;
  var mw = menuEl.offsetWidth;
  var mh = menuEl.offsetHeight;

  // 좌우 위치 결정
  var left;
  if (placement === 'left-of') {
    left = anchorRect.left - mw - gap;
    // 좌측 공간 부족하면 우측으로 폴백 (anchor 우측에 띄움)
    if (left < margin) left = anchorRect.right + gap;
  } else {
    left = anchorRect.left;
  }
  // viewport 가로 클램프
  if (left + mw > vw - margin) left = vw - mw - margin;
  if (left < margin) left = margin;

  // 상하 위치 결정
  var top;
  if (placement === 'left-of') {
    // 기본은 anchor 상단에 맞춤. 하단 넘치면 anchor 하단에 메뉴 하단 정렬 (사용자 요청 — 더보기 버튼 화면 끝에서 메뉴 위로 펼치기)
    top = anchorRect.top;
    if (top + mh > vh - margin) top = anchorRect.bottom - mh;
  } else {
    // 'below' — anchor 아래 우선, 부족하면 위로
    top = anchorRect.bottom + gap;
    if (top + mh > vh - margin) {
      var aboveTop = anchorRect.top - mh - gap;
      if (aboveTop >= margin) {
        top = aboveTop;
      } else {
        top = vh - mh - margin;
      }
    }
  }
  if (top < margin) top = margin;

  menuEl.style.top = top + 'px';
  menuEl.style.left = left + 'px';
}

function toggleCampMoreMenu(e, btnEl, campId, campTitle) {
  e.stopPropagation();
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());

  const rect = btnEl.getBoundingClientRect();
  const menu = document.createElement('div');
  menu.className = 'camp-more-menu';
  // 변경 이력 항목은 super_admin 한정 (audit 데이터, 일반 매니저 노출 X)
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const historyItem = isSuper
    ? `<div class="camp-more-item" onclick="openCautionHistoryModal('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">history</span>변경 이력</div>`
    : '';
  menu.innerHTML = `
    <div class="camp-more-item" onclick="openEditCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">edit</span>편집</div>
    <div class="camp-more-item" onclick="duplicateCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">content_copy</span>복제</div>
    <div class="camp-more-item" onclick="exportCampaignDeliverables('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>결과물 엑셀</div>
    <div class="camp-more-item" onclick="exportCampaignApplicationsExcel('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>신청자 엑셀</div>
    ${historyItem}
    <div class="camp-more-item camp-more-danger" data-camp-title="${esc(campTitle)}" onclick="deleteCampaign('${campId}',this.dataset.campTitle)"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">delete</span>삭제</div>
  `;
  document.body.appendChild(menu);
  // 더보기 버튼 왼쪽에 펼침 + viewport 경계 자동 보정 (하단 넘치면 메뉴 하단을 버튼 하단에 정렬)
  _positionMenuInViewport(menu, rect, {placement: 'left-of'});

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
    {val:'draft',     label:'준비',     cls:'badge-gray'},
    {val:'scheduled', label:'모집예정', cls:'badge-blue'},
    {val:'active',    label:'모집중',   cls:'badge-green'},
    {val:'closed',    label:'종료',     cls:'badge-pink'},
    {val:'expired',   label:'노출마감', cls:'badge-expired'}
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
  // viewport 경계 자동 보정 (하단 넘치면 위로 폴백)
  _positionMenuInViewport(dd, rect, {placement: 'below', gap: 4});

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
    // PR 2: loadAdminCampaigns 가 fetchCampaignsForAdminList 로 allCampaigns 를 갱신.
    //        기존 fetchCampaigns() 이중 조회 제거. renderCampaigns 는 admin 빌드에 없어 dead code.
    loadAdminCampaigns();
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
// ════════════════════════════════════════════════════════════════════
// SECTION: CAMP-APPLICANTS — 캠페인별 신청자 페인 (OT + 결과물 셀)
// ════════════════════════════════════════════════════════════════════

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
  await loadApplicantMsgUnread();  // 응모건 메시지 본인 미열람 배지 맵
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
      <div style="margin-top:4px">${renderApplicantMsgBtn(a)}</div>
    </td>
    <td>${snsCell('instagram', _u.ig || a.ig_id || a.user_ig)}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
    <td>${snsCell('x', _u.x)}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
    <td>${snsCell('tiktok', _u.tiktok)}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
    <td>${snsCell('youtube', _u.youtube)}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
    <td style="font-weight:700;color:var(--pink)">${totalF}</td>
    <td>${msgCell(a.message, a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadgeKo(a.status)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
    <td>${otCell}</td>
    <td>${delivCell}</td>
    <td style="white-space:nowrap">
      ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${remaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
      :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
      :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
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
    ? '<div style="display:inline-block;margin-top:3px;background:#E4F5E8;color:#2D7A3E;font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px">완료</div>'
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

// ════════════════════════════════════════════════════════════════════
// SECTION: INFLUENCERS — 목록 + 필터 + 정렬 + 행 빌더
// ════════════════════════════════════════════════════════════════════

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
// ════════════════════════════════════════════════════════════════════
// SECTION: INFLUENCERS — 상세 모달 + 파일 업로드 + 인증/위반/블랙 패널
// ════════════════════════════════════════════════════════════════════

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
  await ensureCancelReasonsCache();
  $('infDetailAppCount').textContent = `${apps.length}건`;
  $('infDetailAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const typeLabel = getRecruitTypeBadgeKo(camp.recruit_type);
    const mainRow = `<tr>
      <td style="font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td>
      <td>${typeLabel}</td>
      <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
    </tr>`;
    if (a.status !== 'cancelled') return mainRow;
    // 취소 사유 보조 행
    const catLabel = a.cancel_reason_code ? esc(cancelReasonLabelKo(a.cancel_reason_code)) : '—';
    const noteHtml = a.cancel_reason ? `<div style="font-size:12px;color:var(--ink);margin-top:4px;white-space:pre-wrap"><strong style="font-weight:700">보충</strong> · ${esc(a.cancel_reason)}</div>` : '';
    const phaseLabel = esc(cancelPhaseLabelKo(a.cancel_phase));
    const whenStr = a.cancelled_at ? formatDateTime(a.cancelled_at) : '—';
    const appPayload = esc(JSON.stringify({
      id: a.id,
      cancel_reason: a.cancel_reason || '',
      cancel_reason_code: a.cancel_reason_code || '',
      cancel_phase: a.cancel_phase || '',
      cancel_category_ko: a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : ''
    }));
    return mainRow + `<tr><td colspan="4" style="padding:0">
      <div style="background:#FFF5F5;border-left:3px solid #C62828;padding:10px 14px;margin:0 0 4px;border-radius:0 6px 6px 0">
        <div style="font-size:11px;font-weight:700;color:#C62828;margin-bottom:6px">취소 사유</div>
        <div style="font-size:12px;color:var(--ink)"><strong style="font-weight:700">카테고리</strong> · ${catLabel}</div>
        ${noteHtml}
        <div style="font-size:11px;color:var(--muted);margin-top:6px"><strong style="font-weight:700">시점</strong> · ${phaseLabel} <span style="margin:0 4px;color:var(--line)">|</span> <strong style="font-weight:700">일시</strong> · ${whenStr}</div>
        <div style="margin-top:8px"><button class="btn btn-xs status-btn-orange" onclick='prefillViolationFromCancel(${appPayload})'>이 취소 건으로 위반 등록</button></div>
      </div>
    </td></tr>`;
  }).join('') : '<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:24px">신청 이력 없음</td></tr>';

  openModal('influencerFullDetailModal');
}

// 상태 관리 패널 — 인증 토글 + 블랙리스트 등록/해제 + 사유 입력
var _currentDetailInfluencer = null;
var _blacklistReasonsCache = null;
var _violationReasonsCache = null;
var _cancelReasonsCache = null;

// 취소 시점(cancel_phase) → 한국어 라벨
const CANCEL_PHASE_LABEL_KO = {
  recruit: '모집기간',
  purchase: '구매기간',
  visit: '방문기간',
  post: '결과물 제출기간',
  other: '기타'
};
function cancelPhaseLabelKo(phase) {
  return CANCEL_PHASE_LABEL_KO[phase] || phase || '—';
}

// cancel_reason 카테고리 캐시 lazy load
async function ensureCancelReasonsCache() {
  if (_cancelReasonsCache == null) _cancelReasonsCache = await fetchCancelReasons();
  return _cancelReasonsCache;
}
function cancelReasonLabelKo(code) {
  if (!code) return '';
  const r = (_cancelReasonsCache || []).find(x => x.code === code);
  return r?.name_ko || code;
}

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
    await refreshPane('influencers');
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
    await refreshPane('influencers');
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
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + (e.message || e), 'error'); }
}

// 신청 이력의 cancelled 보조 행에서 호출 — 위반 등록 폼에 자동 prefill
// payload = {id, cancel_reason, cancel_reason_code, cancel_phase, cancel_category_ko}
function prefillViolationFromCancel(payload) {
  if (!payload) return;
  const modal = $('influencerFullDetailModal');
  if (!modal) return;
  const cancelCode = 'cancel_after_purchase_start';
  const cancelLookup = (_violationReasonsCache || []).find(r => r.code === cancelCode);

  // 사유 체크박스 컨테이너 — reasonChecks 영역
  const cbContainer = modal.querySelector('.status-chip')?.parentElement;
  if (cbContainer) {
    // 모든 체크 해제
    cbContainer.querySelectorAll('input.bl-reason-cb').forEach(cb => { cb.checked = false; });
    // cancel_after_purchase_start 체크박스가 이미 있는지
    let cancelCb = cbContainer.querySelector('input.bl-reason-cb[value="' + cancelCode + '"]');
    if (!cancelCb && cancelLookup) {
      // 동적으로 맨 앞에 추가
      const wrapper = document.createElement('label');
      wrapper.className = 'status-chip';
      wrapper.innerHTML = `<input type="checkbox" class="bl-reason-cb" value="${esc(cancelLookup.code)}"><span>${esc(cancelLookup.name_ko)}</span>`;
      cbContainer.insertBefore(wrapper, cbContainer.firstChild);
      cancelCb = wrapper.querySelector('input.bl-reason-cb');
    }
    if (cancelCb) cancelCb.checked = true;
  }

  // 메모 prefill — 기존 값 비어 있을 때만 (사용자 입력 덮어쓰기 방지)
  const noteInput = $('blNoteInput');
  if (noteInput && !(noteInput.value || '').trim()) {
    const lines = ['[취소 사유]'];
    if (payload.cancel_category_ko) lines.push(`카테고리: ${payload.cancel_category_ko}`);
    if (payload.cancel_reason) lines.push(`보충: ${payload.cancel_reason}`);
    if (payload.cancel_phase) lines.push(`시점: ${cancelPhaseLabelKo(payload.cancel_phase)}`);
    noteInput.value = lines.join('\n');
  }

  // 상태 관리 영역으로 스크롤 + 메모 포커스
  const targetCard = $('infDetailStatusBody');
  if (targetCard) targetCard.scrollIntoView({behavior:'smooth', block:'start'});
  setTimeout(() => { noteInput?.focus(); }, 400);
  if (typeof toast === 'function') toast('위반 등록 폼에 사유·메모 prefill 됨', 'info');
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
    await refreshPane('influencers');
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
    await refreshPane('influencers');
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

// ════════════════════════════════════════════════════════════════════
// SECTION: APPLICATIONS — 신청 관리 (renderAppCampList 캐시 공유)
// ════════════════════════════════════════════════════════════════════

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
  // 응모건 메시지 본인 미열람 배지 맵 (응모 행 메시지 버튼용)
  await loadApplicantMsgUnread();
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

  // 옵션별 카운트 계산 (전체 신청 기준 — 다른 필터 무관)
  const appCampCounts = {};
  const appTypeCounts = {};
  const appStatusCountsMap = {};
  const campRtLookup = new Map(camps.map(c => [c.id, c.recruit_type]));
  for (const a of allAppsRaw) {
    if (a.campaign_id) appCampCounts[a.campaign_id] = (appCampCounts[a.campaign_id] || 0) + 1;
    const rt = campRtLookup.get(a.campaign_id);
    if (rt) appTypeCounts[rt] = (appTypeCounts[rt] || 0) + 1;
    if (a.status) appStatusCountsMap[a.status] = (appStatusCountsMap[a.status] || 0) + 1;
  }

  // 드롭다운 동기화 — count 포함
  syncCampMultiFilter('appCampMulti', campOptionsSource, () => renderAppCampList(), appCampCounts);
  syncMultiFilter('appTypeMulti', '전체 타입',
    availableTypes.map(t => ({value:t, label:RECRUIT_TYPE_LABEL_KO[t] || t, count: appTypeCounts[t] || 0})),
    () => renderAppCampList());
  syncMultiFilter('appStatusMulti', '전체 상태', [
    {value:'pending',   label:'심사중', count: appStatusCountsMap.pending   || 0},
    {value:'approved',  label:'승인',   count: appStatusCountsMap.approved  || 0},
    {value:'rejected',  label:'미승인', count: appStatusCountsMap.rejected  || 0},
    {value:'cancelled', label:'취소',   count: appStatusCountsMap.cancelled || 0},
  ], () => renderAppCampList());

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
        || (a.user_email||'').toLowerCase().includes(searchVal)
        || (a.cancel_reason||'').toLowerCase().includes(searchVal)
        || (a.cancel_reason_code||'').toLowerCase().includes(searchVal);
    });
  }

  updateFilterResetBtn('btnAppFilterReset', ['appTypeMulti','appStatusMulti','appCampMulti'], 'appSearch');

  const appDir = appSortDir === 'asc' ? 1 : -1;
  if (appSortKey === 'status') {
    const statusOrder = {pending:0, approved:1, rejected:2, cancelled:3};
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
      <td style="max-width:260px">
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,96,70)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0;flex:1">
            <div>${typeLabel}</div>
            <strong style="font-size:13px;cursor:pointer;display:block;word-break:break-word;line-height:1.4" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong>
            ${camp.slots?(()=>{const _r=Math.max(camp.slots-allAppsRaw.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);return `<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_r>0?'var(--green)':'var(--red)'};font-weight:600">${_r>0?_r+'건':'없음'}</span></div>`;})():''}
          </div>
        </div>
      </td>
      <td style="font-size:12px;color:var(--ink);min-width:100px;max-width:160px;word-break:break-word">
        ${brandPrimary?esc(brandPrimary):'—'}
        ${brandSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(brandSub)}</div>`:''}
      </td>
      <td style="font-size:12px;color:var(--ink);min-width:120px;max-width:220px;word-break:break-word">
        ${productPrimary?esc(productPrimary):'—'}
        ${productSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(productSub)}</div>`:''}
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}${influencerStatusBadges(u)}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${u.line_id?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(u.line_id)}</div>`:''}
        <div style="margin-top:4px">${renderApplicantMsgBtn(a)}</div>
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${_campRemaining<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
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
  // cancel_reason 캐시 미리 채움 — 상세 모달에서 카테고리 라벨 즉시 표시
  ensureCancelReasonsCache();
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

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 신규 등록 저장
// ════════════════════════════════════════════════════════════════════

async function addCampaign() {
  try {
  const title = $('newCampTitle').value.trim();
  const brandId = $('newCampBrandId')?.value || '';
  if (!brandId) { toast('브랜드를 선택해주세요','error'); return; }
  const sourceAppId = $('newCampSourceAppId')?.value || null;
  // brand 텍스트는 select 캐시에서 직접 추출 (hidden #newCampBrand가 race 시점에 비어있을 수 있어 fallback 보강)
  const _pickedBrand = (_campBrandsCache || []).find(b => b.id === brandId);
  const brand = (_pickedBrand?.name || $('newCampBrand').value || '').trim();
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
    brand_id: brandId,
    source_application_id: sourceAppId || null,
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
    purchase_start: $('newCampPurchaseStart')?.value||null,
    purchase_end: $('newCampPurchaseEnd')?.value||null,
    visit_start: $('newCampVisitStart')?.value||null,
    visit_end: $('newCampVisitEnd')?.value||null,
    submission_end: $('newCampSubmissionEnd')?.value||null,
    winner_announce: $('newCampWinnerAnnounce')?.value || '選考後、LINEにてご連絡',
    description: getRichValue('newCampDesc'),
    hashtags:$('newCampHashtags').value, mentions:$('newCampMentions').value,
    appeal: getRichValue('newCampAppeal'), guide: getRichValue('newCampGuide'),
    // 067 legacy 컬럼은 더 이상 갱신하지 않음 (070 마이그레이션에서 DROP 예정)
    // ng legacy 컬럼은 NG-PR-B에서 갱신 중단 — ng_set_id/ng_items 로 대체 (NG-PR-F에서 DROP 예정)
    status:'draft',
    ...collectCampPsetPayload('new'),
    ...collectCampCsetPayload('new'),
    ...collectCampNsetPayload('new'),
  };

  await insertCampaign(camp);
  toast('캠페인이 등록되었습니다','success');
  campImgData.length = 0;
  renderImgPreview(campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');

  ['newCampTitle','newCampBrand','newCampBrandKo','newCampBrandId','newCampSourceAppId',
   'newCampProduct','newCampProductUrl',
   'newCampSlots','newCampRecruitStart','newCampDeadline',
   'newCampPurchaseStart','newCampPurchaseEnd','newCampVisitStart','newCampVisitEnd',
   'newCampSubmissionEnd','newCampHashtags','newCampMentions',
   'newCampProductPrice','newCampReward','newCampRewardNote'].forEach(id => { const el=$(id); if(el) el.value=''; });
  var newSrcWrap = $('newCampSourceAppContainer'); if (newSrcWrap) newSrcWrap.style.display = 'none';
  var newSrcSel = $('newCampSourceAppId'); if (newSrcSel) { newSrcSel.value = ''; _srcAppSyncTrigger('new'); }
  // flatpickr range picker 클리어
  applyCampRangeValues('newCamp', { recruit:[null,null], purchase:[null,null], visit:[null,null] });
  // 리치 에디터 초기화
  ['newCampDesc','newCampAppeal','newCampGuide'].forEach(id => setRichValue(id, ''));
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
  // NG 사항 번들 초기화 (migration 107)
  _nsetState.new = [];
  await populateCampNsetDropdown('new', null, null);
  renderCampNgItems('new');

  allCampaigns = await fetchCampaigns();

  switchAdminPane('campaigns', null);
  } catch(err) {
    toast('오류: ' + friendlyError(err.message||String(err)), 'error');
  }
}

// ══════════════════════════════════════
// 관리자 계정 관리
// ══════════════════════════════════════

// ════════════════════════════════════════════════════════════════════
// SECTION: MY-ACCOUNT — 사이드바 프로필 표시
// ════════════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-ACCOUNTS — 목록 + 광고주 알림 토글 + 권한 헬퍼
//   isCampaignAdminOrAbove / applyLookupMenuVisibility 도 함께 이동
// ════════════════════════════════════════════════════════════════════

// 메일 종류 카탈로그 캐시 (모달 + 칩 라벨 양쪽에서 재사용)
let _adminEmailKindsCache = null;
async function _getAdminEmailKinds() {
  if (_adminEmailKindsCache) return _adminEmailKindsCache;
  _adminEmailKindsCache = await fetchAdminEmailKinds();
  return _adminEmailKindsCache;
}

async function loadAdminAccounts() {
  if (!db) return;
  const {data} = await db?.from('admins').select('*').order('created_at');
  const admins = data || [];
  // 현재 로그인한 관리자 정보 먼저 확정 (렌더 시 권한 판단에 사용)
  currentAdminInfo = admins.find(a => a.auth_id === currentUser?.id) || null;
  const isSuper = currentAdminInfo?.role === 'super_admin';

  // 구독 상태 + 메일 종류 카탈로그 일괄 로드
  const adminIds = admins.map(a => a.id);
  const [subs, kinds] = await Promise.all([
    fetchAdminEmailSubscriptions(adminIds),
    _getAdminEmailKinds()
  ]);
  const kindLabel = code => (kinds.find(k => k.code === code) || {}).name_ko || code;

  const roleLabel = r => r === 'super_admin'
    ? '<span class="badge badge-red">슈퍼관리자</span>'
    : r === 'campaign_admin'
    ? '<span class="badge badge-blue">캠페인관리자</span>'
    : '<span class="badge badge-gray">캠페인매니저</span>';

  // 메일받기 셀: 켜진 종류 회색 칩 나열 + 「설정」 버튼.
  // 본인 행은 항상 편집 가능. 다른 관리자 행은 super_admin 만 편집 가능.
  const renderMailCell = a => {
    const codes = subs[a.id] || [];
    const chips = codes.length
      ? codes.map(c => `<span class="badge badge-gray" style="font-size:10px;padding:1px 6px;border-radius:8px;line-height:1.5;white-space:nowrap">${esc(kindLabel(c))}</span>`).join(' ')
      : '<span style="color:var(--muted);font-size:12px">—</span>';
    const canEdit = isSuper || a.auth_id === currentUser?.id;
    const btn = canEdit
      ? `<button class="btn btn-ghost btn-xs" data-name="${esc(a.name||'')}" data-email="${esc(a.email)}" onclick="openAdminEmailSubsModal('${a.id}', this.dataset.name, this.dataset.email)">설정</button>`
      : '';
    return `<div style="display:flex;align-items:center;gap:8px">
      <div style="flex:1;min-width:0;display:flex;flex-wrap:wrap;gap:4px">${chips}</div>
      ${btn}
    </div>`;
  };

  $('adminAccountsBody').innerHTML = admins.length ? admins.map(a => `<tr>
    <td style="font-weight:600">${esc(a.name)||'—'}</td>
    <td>${esc(a.email)}</td>
    <td>${roleLabel(a.role)}</td>
    <td>${renderMailCell(a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td><div style="display:flex;gap:5px">
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" data-name="${esc(a.name||'')}" onclick="openEditAdmin('${a.id}',this.dataset.email,this.dataset.name,'${a.role}')">수정</button>
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" onclick="openResetPwModal('${a.auth_id}',this.dataset.email)">비밀번호</button>
      ${(isSuper && a.auth_id !== currentUser?.id) ? `<button class="btn btn-ghost btn-xs" style="color:#B3261E" data-email="${esc(a.email)}" data-auth-id="${a.auth_id}" onclick="openDeleteAdminModal('${a.id}',this.dataset.authId,this.dataset.email)">삭제</button>` : ''}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>';

  applyLookupMenuVisibility();
}

// ──────────────────────────────────────
// 「메일 받기 설정」 모달 (admin_email_subscriptions)
// ──────────────────────────────────────
// 현재 편집 중인 관리자 id (저장 시 사용)
let _adminEmailSubsEditingId = null;
// 모달 안의 메일 종류 목록 (저장 시 사용)
let _adminEmailSubsModalKinds = [];

async function openAdminEmailSubsModal(adminId, adminName, adminEmail) {
  if (!db) return;
  _adminEmailSubsEditingId = adminId;
  // 헤더에 관리자 정보 + 안내문
  const hdr = $('adminEmailSubsHeader');
  if (hdr) hdr.textContent = `${adminName || '—'} (${adminEmail || ''})`;
  // 메일 종류 카탈로그 + 현재 구독 상태 로드
  const [kinds, subs] = await Promise.all([
    _getAdminEmailKinds(),
    fetchAdminEmailSubscriptions([adminId])
  ]);
  _adminEmailSubsModalKinds = kinds;
  const currentSet = new Set(subs[adminId] || []);
  // 본문 동적 렌더
  const body = $('adminEmailSubsBody');
  if (body) {
    body.innerHTML = kinds.length ? kinds.map(k => `
      <label style="display:flex;gap:10px;align-items:flex-start;padding:10px;border:1px solid var(--line);border-radius:10px;margin-bottom:8px;cursor:pointer">
        <input type="checkbox" class="adm-email-sub-cb" data-code="${esc(k.code)}" ${currentSet.has(k.code) ? 'checked' : ''} style="margin-top:3px">
        <div style="flex:1">
          <div style="font-weight:600;color:var(--ink);font-size:13px">${esc(k.name_ko)}</div>
          <div style="font-size:11px;color:var(--muted);margin-top:2px">${esc(_adminEmailKindDesc(k.code))}</div>
        </div>
      </label>
    `).join('') : '<div style="color:var(--muted);font-size:12px;padding:12px">등록된 메일 종류가 없습니다.</div>';
  }
  openModal('adminEmailSubsModal');
}

// 메일 종류별 보조 설명 (사용자 친화 카피)
function _adminEmailKindDesc(code) {
  const map = {
    'brand_notify':       '광고주(브랜드)가 sales 페이지에서 신청 폼을 제출했을 때 접수 알림',
    'application_cancel': '인플루언서가 구매기간 이후에 응모를 취소했을 때 알림'
  };
  return map[code] || '';
}

async function saveAdminEmailSubsFromModal() {
  if (!_adminEmailSubsEditingId) { closeModal('adminEmailSubsModal'); return; }
  // 모달 안 체크박스 상태 → Set
  const checked = new Set();
  document.querySelectorAll('#adminEmailSubsBody .adm-email-sub-cb:checked').forEach(cb => {
    const code = cb.getAttribute('data-code');
    if (code) checked.add(code);
  });
  const res = await saveAdminEmailSubscriptions(_adminEmailSubsEditingId, checked, _adminEmailSubsModalKinds);
  if (!res.ok) {
    toast('저장 실패: ' + (res.error || '알 수 없는 오류'), 'error');
    return;
  }
  toast('메일 수신 설정을 저장했습니다');
  closeModal('adminEmailSubsModal');
  _adminEmailSubsEditingId = null;
  _adminEmailSubsModalKinds = [];
  await refreshPane('admin-accounts');
}

// 권한에 따라 "기준 데이터" 메뉴 표시/숨김
function isCampaignAdminOrAbove() {
  const r = currentAdminInfo?.role;
  return r === 'super_admin' || r === 'campaign_admin';
}
function applyLookupMenuVisibility() {
  const show = isCampaignAdminOrAbove() ? '' : 'none';
  const el = document.getElementById('adminLookupsSi');
  if (el) el.style.display = show;
  // 자주 묻는 질문(FAQ) 메뉴도 동일 권한(campaign_admin 이상)으로 노출
  const faqEl = document.getElementById('adminFaqSi');
  if (faqEl) faqEl.style.display = show;
}

// ══════════════════════════════════════
// 기준 데이터 (lookup_values) 관리
// ══════════════════════════════════════
const LOOKUP_KIND_LABEL_KO = {channel:'채널', category:'카테고리', content_type:'콘텐츠 종류', ng_set:'NG 사항', participation_set:'참여방법', reject_reason:'반려사유', caution:'주의사항'};
let _currentLookupKind = 'channel';

// ════════════════════════════════════════════════════════════════════
// SECTION: LOOKUPS — 기준 데이터 페인 로드 + 탭 + 테이블
// ════════════════════════════════════════════════════════════════════

async function loadLookupsPane() {
  applyLookupMenuVisibility();
  if (!isCampaignAdminOrAbove()) {
    const tbody = $('lookupsTableBody');
    if (tbody) tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">권한이 없습니다 (campaign_admin 이상)</td></tr>';
    return;
  }
  await renderLookupsTable();
}

// ════════════════════════════════════════════════════════════════════
// SECTION: FAQ (자동응답) — 마이그레이션 146. 좌우 2단 마스터-디테일 페인
// ════════════════════════════════════════════════════════════════════

// 화면이동 드롭다운 라벨 (action_target → 한국어 라벨). 미리보기·렌더용
const FAQ_ACTION_LABEL_KO = {
  '#mypage-applications': '응모이력',
  '#activity': '활동관리(결과물 제출)',
  '#mypage-profile-sns': 'SNS 계정',
  '#mypage-profile-address': '배송지',
  '#mypage-paypal': 'PayPal',
  '#mypage-profile-basic': '기본정보',
  '#mypage-password': '비밀번호 변경',
  '#mypage-email-settings': '메일 수신 설정'
};
// 맞춤 노출 단계 라벨 (한국어)
const FAQ_STAGE_LABEL_KO = {
  pending: '심사중', approved_purchase: '승인-구매기간', approved_visit: '승인-방문기간',
  approved_post: '승인-제출단계', rejected: '비승인', done: '완료'
};

let _faqNodes = [];          // 전체 노드 캐시 (active 무관)
let _faqStats = {};          // 노드별 측정 집계
let _faqSelectedCatId = null;// 선택된 카테고리 id
let _faqReorder = { category: false, item: false };

// 페인 로드 — 노드 + 측정 조회 후 좌우 렌더
async function loadFaqPane() {
  applyLookupMenuVisibility();
  if (!isCampaignAdminOrAbove()) {
    const el = $('faqCatList');
    if (el) el.innerHTML = '<div style="text-align:center;color:var(--muted);padding:24px">권한이 없습니다 (campaign_admin 이상)</div>';
    return;
  }
  [_faqNodes, _faqStats] = await Promise.all([fetchFaqNodes(), fetchFaqInteractionStats()]);
  // 선택 카테고리 유효성 검증 (삭제됐으면 첫 카테고리로)
  const cats = _faqCategories();
  if (!_faqSelectedCatId || !cats.some(c => c.id === _faqSelectedCatId)) {
    _faqSelectedCatId = cats.length ? cats[0].id : null;
  }
  renderFaqCategories();
  renderFaqItems(_faqSelectedCatId);
}

// 카테고리 노드만 (sort_order 순 — fetch 가 이미 정렬)
function _faqCategories() {
  return _faqNodes.filter(n => n.kind === 'category');
}
// 특정 카테고리의 1차 질문 항목 (분기 노드의 자식 item 은 우측 목록에서 제외)
function _faqItemsOf(categoryId) {
  return _faqNodes.filter(n => n.kind === 'item' && n.parent_id === categoryId);
}

// 좌측 카테고리 목록 렌더
function renderFaqCategories() {
  const wrap = $('faqCatList');
  if (!wrap) return;
  const cats = _faqCategories();
  if (!cats.length) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:24px">등록된 카테고리가 없습니다</div>';
    return;
  }
  const reorder = _faqReorder.category;
  wrap.innerHTML = cats.map((c, i) => {
    const cnt = _faqItemsOf(c.id).length;
    const sel = c.id === _faqSelectedCatId ? ' faq-item-sel' : '';
    const upId = i === 0 ? '' : cats[i-1].id;
    const downId = i === cats.length-1 ? '' : cats[i+1].id;
    return `<div class="faq-item${sel}${c.active?'':' faq-item-off'}" onclick="selectFaqCategory('${c.id}')">
      <div class="faq-item-main">
        <div class="faq-item-label">${esc(c.label_ko)} <span class="faq-item-count">질문 ${cnt}개</span></div>
        <div class="faq-item-sub">${esc(c.label_ja)}</div>
      </div>
      <div class="faq-item-actions" onclick="event.stopPropagation()">
        ${reorder
          ? `<button class="btn btn-ghost btn-xs" ${upId?'':'disabled'} onclick="moveFaqNode('${c.id}','${upId}')">↑</button>
             <button class="btn btn-ghost btn-xs" ${downId?'':'disabled'} onclick="moveFaqNode('${c.id}','${downId}')">↓</button>`
          : `<label class="lookup-toggle" title="${c.active?'활성':'비활성'}"><input type="checkbox" ${c.active?'checked':''} onchange="toggleFaqNodeActive('${c.id}',this.checked)"><span class="lookup-toggle-slider"></span></label>
             <button class="btn btn-ghost btn-xs" onclick="openFaqEditModal('${c.id}',null,'category')">편집</button>
             <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick="deleteFaqCategory('${c.id}')">삭제</button>`}
      </div>
    </div>`;
  }).join('');
}

// 우측 질문 항목 목록 렌더 (측정 배지 포함)
function renderFaqItems(categoryId) {
  const wrap = $('faqItemList');
  const title = $('faqItemsTitle');
  const footer = $('faqItemFooter');
  const reorderBtn = $('btnFaqItemReorder');
  if (!wrap) return;
  const cat = _faqNodes.find(n => n.id === categoryId);
  if (!cat) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:32px">좌측에서 카테고리를 선택하세요</div>';
    if (title) title.textContent = '질문';
    if (footer) footer.style.display = 'none';
    if (reorderBtn) reorderBtn.style.display = 'none';
    return;
  }
  if (title) title.textContent = '「' + cat.label_ko + '」 질문';
  if (footer) footer.style.display = '';
  if (reorderBtn) reorderBtn.style.display = '';
  const items = _faqItemsOf(categoryId);
  if (!items.length) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:32px">등록된 질문이 없습니다</div>';
    return;
  }
  const reorder = _faqReorder.item;
  wrap.innerHTML = items.map((q, i) => {
    const upId = i === 0 ? '' : items[i-1].id;
    const downId = i === items.length-1 ? '' : items[i+1].id;
    return `<div class="faq-item${q.active?'':' faq-item-off'}">
      <div class="faq-item-main">
        <div class="faq-item-label">${esc(q.label_ko)}${faqItemBadges(q)}</div>
        <div class="faq-item-sub">${esc(q.label_ja)}</div>
        ${faqStatBadges(q.id)}
      </div>
      <div class="faq-item-actions">
        ${reorder
          ? `<button class="btn btn-ghost btn-xs" ${upId?'':'disabled'} onclick="moveFaqNode('${q.id}','${upId}')">↑</button>
             <button class="btn btn-ghost btn-xs" ${downId?'':'disabled'} onclick="moveFaqNode('${q.id}','${downId}')">↓</button>`
          : `<label class="lookup-toggle" title="${q.active?'활성':'비활성'}"><input type="checkbox" ${q.active?'checked':''} onchange="toggleFaqNodeActive('${q.id}',this.checked)"><span class="lookup-toggle-slider"></span></label>
             <button class="btn btn-ghost btn-xs" onclick="openFaqEditModal('${q.id}','${categoryId}','item')">편집</button>
             <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick="deleteFaqItem('${q.id}')">삭제</button>`}
      </div>
    </div>`;
  }).join('');
}

// 질문 속성 배지 (handoff / 화면이동 / 단계 태그)
function faqItemBadges(q) {
  const out = [];
  if (q.is_human_handoff) out.push('<span class="badge badge-gold" style="font-size:9px;padding:1px 6px;margin-left:4px">직접문의</span>');
  if (q.action_type === 'navigate' && q.action_target) {
    out.push(`<span class="badge badge-blue" style="font-size:9px;padding:1px 6px;margin-left:4px">→ ${esc(FAQ_ACTION_LABEL_KO[q.action_target] || q.action_target)}</span>`);
  }
  (q.relevant_stages || []).forEach(s => {
    out.push(`<span class="badge badge-gray" style="font-size:9px;padding:1px 6px;margin-left:4px">${esc(FAQ_STAGE_LABEL_KO[s] || s)}</span>`);
  });
  return out.join('');
}

// 측정 배지 (조회수 · 직접문의 전환수 + 전환율 높으면 경고)
function faqStatBadges(nodeId) {
  const s = _faqStats[nodeId];
  if (!s || (!s.viewed && !s.handoff)) return '';
  // 직접문의 전환율 = handoff / (viewed + handoff). 50% 이상이면 부실 답변 경고
  const denom = s.viewed + s.handoff;
  const rate = denom ? Math.round((s.handoff / denom) * 100) : 0;
  const warn = denom >= 5 && rate >= 50;
  return `<div class="faq-stats">
    <span class="faq-stat">조회 ${s.viewed}</span>
    <span class="faq-stat">직접문의 ${s.handoff}</span>
    ${warn ? `<span class="faq-stat faq-stat-warn" title="직접문의 전환율이 높습니다 — 답변 보강 검토">전환율 ${rate}%</span>` : ''}
  </div>`;
}

// 카테고리 선택 → 우측 갱신
function selectFaqCategory(id) {
  _faqSelectedCatId = id;
  _faqReorder.item = false;
  const rb = $('btnFaqItemReorder');
  if (rb) rb.textContent = '순서 변경';
  renderFaqCategories();
  renderFaqItems(id);
}

// 순서변경 모드 토글 (category | item)
function toggleFaqReorder(kind) {
  _faqReorder[kind] = !_faqReorder[kind];
  const btn = $(kind === 'category' ? 'btnFaqCatReorder' : 'btnFaqItemReorder');
  if (btn) {
    btn.textContent = _faqReorder[kind] ? '완료' : '순서 변경';
    btn.classList.toggle('btn-primary', _faqReorder[kind]);
    btn.classList.toggle('btn-ghost', !_faqReorder[kind]);
  }
  if (kind === 'category') renderFaqCategories();
  else renderFaqItems(_faqSelectedCatId);
}

// 순서 위/아래 이동 — 인접 노드와 sort_order 교환
async function moveFaqNode(id, otherId) {
  if (!otherId) return;
  const a = _faqNodes.find(n => n.id === id);
  const b = _faqNodes.find(n => n.id === otherId);
  if (!a || !b) return;
  const r = await swapFaqNodeOrder(a.id, a.sort_order, b.id, b.sort_order);
  if (!r.ok) { toast('순서 변경 실패: ' + (r.error || ''), 'error'); return; }
  await refreshPane('faq');
}

// 활성 토글
async function toggleFaqNodeActive(id, active) {
  const r = await setFaqNodeActive(id, active);
  if (!r.ok) { toast('상태 변경 실패: ' + (r.error || ''), 'error'); await refreshPane('faq'); return; }
  const n = _faqNodes.find(x => x.id === id);
  if (n) n.active = !!active;
  toast('변경되었습니다');
}

// 카테고리 삭제 (자식 질문 cascade 경고)
async function deleteFaqCategory(id) {
  const cat = _faqNodes.find(n => n.id === id);
  if (!cat) return;
  const cnt = _faqItemsOf(id).length;
  const msg = cnt
    ? `카테고리 「${cat.label_ko}」 와 그 안의 질문 ${cnt}개가 모두 삭제됩니다. 계속할까요?`
    : `카테고리 「${cat.label_ko}」 를 삭제할까요?`;
  if (!confirm(msg)) return;
  const r = await deleteFaqNode(id);
  if (!r.ok) { toast('삭제 실패: ' + (r.error || ''), 'error'); return; }
  if (_faqSelectedCatId === id) _faqSelectedCatId = null;
  toast('삭제되었습니다');
  await refreshPane('faq');
}

// 질문 삭제
async function deleteFaqItem(id) {
  const q = _faqNodes.find(n => n.id === id);
  if (!q) return;
  if (!confirm(`질문 「${q.label_ko}」 를 삭제할까요?`)) return;
  const r = await deleteFaqNode(id);
  if (!r.ok) { toast('삭제 실패: ' + (r.error || ''), 'error'); return; }
  toast('삭제되었습니다');
  await refreshPane('faq');
}

// 선택 카테고리에 질문 추가
function openFaqAddItem() {
  if (!_faqSelectedCatId) { toast('먼저 카테고리를 선택하세요', 'error'); return; }
  openFaqEditModal(null, _faqSelectedCatId, 'item');
}

// 편집 모달 열기 (nodeId=null 이면 신규)
function openFaqEditModal(nodeId, parentId, kind) {
  const node = nodeId ? _faqNodes.find(n => n.id === nodeId) : null;
  const isCategory = kind === 'category';
  $('faqEditId').value = nodeId || '';
  $('faqEditParentId').value = parentId || (node ? node.parent_id || '' : '');
  $('faqEditKind').value = kind;
  $('faqModalTitle').textContent = (isCategory ? '카테고리 ' : '질문 ') + (nodeId ? '편집' : '추가');
  // 라벨 텍스트 (카테고리명 vs 질문 제목)
  const koLbl = isCategory ? '카테고리명 (한국어)' : '질문 제목 (한국어)';
  const jaLbl = isCategory ? '카테고리명 (일본어)' : '질문 제목 (일본어)';
  $('faqLabelKoLabel').innerHTML = koLbl + ' <span style="color:var(--red)">*</span>';
  $('faqLabelJaLabel').innerHTML = jaLbl + ' <span style="color:var(--red)">*</span>';
  $('faqLabelKo').value = node ? node.label_ko || '' : '';
  $('faqLabelJa').value = node ? node.label_ja || '' : '';
  // 카테고리는 답변·화면이동·단계·미리보기 숨김
  $('faqBodyGroup').style.display = isCategory ? 'none' : '';
  $('faqPreviewWrap').style.display = isCategory ? 'none' : '';
  $('faqBodyKo').value = node ? node.body_ko || '' : '';
  $('faqBodyJa').value = node ? node.body_ja || '' : '';
  $('faqActionTarget').value = node && node.action_type === 'navigate' ? (node.action_target || '') : '';
  $('faqActionLabelKo').value = node ? node.action_label_ko || '' : '';
  $('faqActionLabelJa').value = node ? node.action_label_ja || '' : '';
  $('faqHandoff').checked = node ? !!node.is_human_handoff : false;
  $('faqActive').checked = node ? !!node.active : true;
  const stages = (node && node.relevant_stages) || [];
  document.querySelectorAll('input[name="faqStage"]').forEach(cb => { cb.checked = stages.includes(cb.value); });
  onFaqActionTargetChange();
  onFaqHandoffChange();
  // 미리보기 초기화 (접힘)
  const pb = $('faqPreviewBox');
  if (pb) pb.style.display = 'none';
  $('faqPreviewToggleLabel').textContent = '미리보기 (일본어 화면)';
  const err = $('faqEditError');
  if (err) err.style.display = 'none';
  openModal('faqEditModal');
}

// 화면이동 선택 시 버튼 라벨 입력 노출
function onFaqActionTargetChange() {
  const has = !!$('faqActionTarget').value;
  $('faqActionLabelGroup').style.display = has ? '' : 'none';
}

// handoff 켜면 답변·화면이동은 무의미 → 안내 위해 비활성 처리하지 않고 그대로 둠(저장 시 정리)
function onFaqHandoffChange() { /* UI 토글만 — 저장 로직에서 일관 처리 */ }

// 저장
async function saveFaqNode() {
  const err = $('faqEditError');
  const setErr = (m) => { if (err) { err.textContent = m; err.style.display = ''; } };
  const id = $('faqEditId').value || null;
  const kind = $('faqEditKind').value;
  const labelKo = $('faqLabelKo').value.trim();
  const labelJa = $('faqLabelJa').value.trim();
  if (!labelKo || !labelJa) { setErr('한국어·일본어 제목을 모두 입력하세요.'); return; }
  const uid = currentUser?.id || null;
  const row = { label_ko: labelKo, label_ja: labelJa, active: $('faqActive').checked, updated_by: uid };
  if (kind === 'category') {
    row.kind = 'category'; row.parent_id = null;
  } else {
    row.kind = 'item';
    row.parent_id = $('faqEditParentId').value || null;
    if (!row.parent_id) { setErr('카테고리 정보가 없습니다.'); return; }
    row.body_ko = $('faqBodyKo').value.trim() || null;
    row.body_ja = $('faqBodyJa').value.trim() || null;
    const target = $('faqActionTarget').value;
    row.action_type = target ? 'navigate' : 'none';
    row.action_target = target || null;
    row.action_label_ko = target ? ($('faqActionLabelKo').value.trim() || null) : null;
    row.action_label_ja = target ? ($('faqActionLabelJa').value.trim() || null) : null;
    row.is_human_handoff = $('faqHandoff').checked;
    const stages = Array.from(document.querySelectorAll('input[name="faqStage"]:checked')).map(cb => cb.value);
    row.relevant_stages = stages.length ? stages : null;
  }
  // 신규는 sort_order 를 형제 노드 최대값 + 10 으로
  if (!id) {
    const siblings = kind === 'category' ? _faqCategories() : _faqItemsOf(row.parent_id);
    const maxSort = siblings.reduce((m, s) => Math.max(m, s.sort_order || 0), 0);
    row.sort_order = maxSort + 10;
    row.created_by = uid;
  }
  const r = id ? await updateFaqNode(id, row) : await insertFaqNode(row);
  if (!r.ok) { setErr('저장 실패: ' + (r.error || '')); return; }
  // 신규 카테고리면 자동 선택
  if (!id && kind === 'category' && r.data?.id) _faqSelectedCatId = r.data.id;
  closeModal('faqEditModal');
  toast('저장되었습니다');
  await refreshPane('faq');
}

// 미리보기 토글 — 일본어 본문을 인플루언서 화면처럼 렌더 (번호 단계 + 화면이동 버튼)
function toggleFaqPreview() {
  const box = $('faqPreviewBox');
  if (!box) return;
  const show = box.style.display === 'none';
  $('faqPreviewToggleLabel').textContent = show ? '미리보기 닫기' : '미리보기 (일본어 화면)';
  if (!show) { box.style.display = 'none'; return; }
  box.innerHTML = renderFaqPreviewHtml();
  box.style.display = '';
}

// 미리보기 HTML 생성 — 인플루언서 일본어 화면 흉내
function renderFaqPreviewHtml() {
  const handoff = $('faqHandoff').checked;
  const labelJa = $('faqLabelJa').value.trim();
  if (handoff) {
    return `<div class="faq-pv-title">${esc(labelJa || '(質問タイトル未入力)')}</div>
      <div class="faq-pv-body" style="color:var(--muted)">この質問は「直接お問い合わせ」につながります。</div>`;
  }
  const bodyJa = $('faqBodyJa').value;
  const target = $('faqActionTarget').value;
  const btnJa = $('faqActionLabelJa').value.trim() || (target ? '画面を開く' : '');
  // 본문을 줄 단위로 — 번호로 시작하는 줄은 단계로 강조
  const lines = (bodyJa || '').split('\n').map(l => l.trim()).filter(Boolean);
  const bodyHtml = lines.length
    ? lines.map(l => /^[0-9０-９]+[.\．、)]/.test(l)
        ? `<div class="faq-pv-step">${esc(l)}</div>`
        : `<div class="faq-pv-line">${esc(l)}</div>`).join('')
    : '<div class="faq-pv-line" style="color:var(--muted)">(回答本文未入力)</div>';
  const btnHtml = (target && btnJa)
    ? `<div class="faq-pv-btn"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">open_in_new</span> ${esc(btnJa)}</div>`
    : '';
  return `<div class="faq-pv-title">${esc(labelJa || '(質問タイトル未入力)')}</div>
    <div class="faq-pv-body">${bodyHtml}</div>${btnHtml}`;
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
  if (_currentLookupKind === 'ng_set') { await renderNgSetTable(); return; }
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
// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 폼 가시성 / 채널 / 콘텐츠 / 카테고리
//   lookup_values 의존이지만 의미상 캠페인 폼 보조 — 분리 시 form 모듈
// ════════════════════════════════════════════════════════════════════

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
  // NG 사항 번들 드롭다운도 동일 패턴으로 필터링 (migration 107)
  const nsetSel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
  await populateCampNsetDropdown(formMode, recruitType, nsetSel?.value || null);
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

// ════════════════════════════════════════════════════════════════════
// SECTION: LOOKUPS — 재정렬 모드 + 추가/편집 모달 + 삭제/토글
// ════════════════════════════════════════════════════════════════════

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
  if (_currentLookupKind === 'ng_set') { openNgSetAddModal(); return; }
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
  if (_currentLookupKind === 'ng_set') { openNgSetEditModal(row); return; }
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
    else if (_currentLookupKind === 'ng_set') await swapNgSetOrder(idA, idB);
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
    } else if (_currentLookupKind === 'ng_set') {
      if (nextActive) await activateNgSet(id); else await deactivateNgSet(id);
    } else {
      if (nextActive) await activateLookup(id); else await deactivateLookup(id);
    }
    renderLookupsTable();
  } catch(e) {
    toast('상태 변경 실패: ' + (e.message||String(e)),'error');
  }
}

async function handleLookupDelete(row) {
  // 번들(ng_sets / caution_sets / participation_sets) 여부 판별: row.kind 미존재 또는 현재 kind가 번들 탭
  if (_currentLookupKind === 'ng_set' || _currentLookupKind === 'caution' || (_currentLookupKind === 'participation_set') || row.kind === undefined) {
    const ok = await showConfirm(`'${row.name_ko}' 번들을 영구 삭제하시겠습니까?\n이미 해당 번들을 쓴 캠페인은 스냅샷이 저장돼 영향 없습니다.`);
    if (!ok) return;
    try {
      if (_currentLookupKind === 'ng_set') await deleteNgSet(row.id);
      else if (_currentLookupKind === 'caution') await deleteCautionSet(row.id);
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

// ════════════════════════════════════════════════════════════════════
// SECTION: PARTICIPATION-SETS — 참여방법 번들 (테이블 + 편집 모달)
// ════════════════════════════════════════════════════════════════════

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
        <input type="text" class="form-input" placeholder="제목 (일본어)" value="${esc(s.title_ja)}" style="font-size:13px;padding:8px 10px" oninput="_psetCurrentSteps[${idx}].title_ja=this.value">
        ${miniEditorHtml(s.desc_ko, `_psetCurrentSteps[${idx}].desc_ko=this.innerHTML`, '설명 (한국어)')}
        ${miniEditorHtml(s.desc_ja, `_psetCurrentSteps[${idx}].desc_ja=this.innerHTML`, '설명 (일본어)')}
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
  const steps = _sanitizePsetStepsForSave(
    _psetCurrentSteps.filter(s => (s.title_ja||s.title_ko||'').trim())
  );
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

// ════════════════════════════════════════════════════════════════════
// SECTION: CAUTION-SETS — 주의사항 번들 (미니 에디터 + 링크 팝오버)
// ════════════════════════════════════════════════════════════════════

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

// 미니 에디터 (contenteditable + execCommand) — B/I/U/S/Link/Image 6버튼
//   이미지 버튼: 파일 선택 다이얼로그 → uploadContentImage → 커서 위치 <img> 삽입
//   외부 URL 직접 삽입 차단 (sanitize 단계 src 화이트리스트로 후방 차단)
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
        <button type="button" onclick="miniEditorInsertImageClick(this)" title="이미지 삽입 (5MB 이하 jpg/png/webp)" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-size:12px;color:var(--pink);display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">image</span>이미지</button>
      </div>
      <div class="mini-editor-content" contenteditable="true" data-placeholder="${ph}" style="padding:8px 10px;font-size:13px;min-height:48px;line-height:1.6;outline:none" oninput="${onChangeAttr}" onpaste="miniEditorPaste(event)">${safe}</div>
    </div>`;
}

// 이미지 버튼 클릭 — 숨김 file input 생성 → 파일 선택 → 업로드 → <img> 삽입
//   캡션·크기 옵션 없음 (사양 §1: 기본만, .rich-img 가로 100% 자동 적용)
function miniEditorInsertImageClick(btn) {
  const wrap = btn.closest('.mini-editor-wrap');
  const content = wrap?.querySelector('.mini-editor-content');
  if (!content) return;
  // 임시 file input — DOM 에 부착해야 일부 브라우저에서 click() 동작
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/jpeg,image/png,image/webp';
  input.style.display = 'none';
  document.body.appendChild(input);
  input.addEventListener('change', async () => {
    try {
      const file = input.files && input.files[0];
      if (!file) return;
      if (!['image/jpeg','image/png','image/webp'].includes(file.type)) {
        toast('JPG/PNG/WebP 형식만 업로드할 수 있습니다','error');
        return;
      }
      if (file.size > 5 * 1024 * 1024) {
        toast('이미지는 5MB 이하만 업로드할 수 있습니다','error');
        return;
      }
      content.focus();
      toast('이미지 업로드 중…','info');
      const url = await uploadContentImage(file);
      // sanitize 가 src 화이트리스트 + .rich-img 클래스를 후처리에서 부여하므로
      // 여기서는 단순히 <img src="..."> 만 삽입. oninput 트리거로 sanitize 가 다시 통과.
      const html = '<img src="' + url + '" alt="">';
      // execCommand insertHTML 폴백: contenteditable 에서 selection 위치 보존
      const ok = document.execCommand('insertHTML', false, html);
      if (!ok) {
        // 폴백: 끝에 append
        content.insertAdjacentHTML('beforeend', html);
      }
      content.dispatchEvent(new Event('input', {bubbles:true}));
      toast('이미지를 추가했습니다','success');
    } catch (e) {
      const msg = (e && e.message) || String(e);
      if (msg === 'file_too_large') toast('이미지는 5MB 이하만 업로드할 수 있습니다','error');
      else if (msg === 'file_type_not_allowed') toast('JPG/PNG/WebP 형식만 업로드할 수 있습니다','error');
      else toast('이미지 업로드 실패: ' + msg,'error');
    } finally {
      input.remove();
    }
  }, {once: true});
  input.click();
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
  pop.innerHTML = `
    <input type="url" class="melp-url" value="${esc(href)}" placeholder="https:// 또는 mailto:" spellcheck="false">
    <button type="button" class="melp-btn melp-copy" title="링크 URL 복사"><span class="material-icons-round notranslate" translate="no">content_copy</span></button>
    <button type="button" class="melp-btn melp-open" title="새 탭으로 열기"><span class="material-icons-round notranslate" translate="no">open_in_new</span></button>
    <button type="button" class="melp-btn melp-delete" title="링크 제거"><span class="material-icons-round notranslate" translate="no">link_off</span></button>
  `;
  document.body.appendChild(pop);
  // CSS 에서 position:fixed 지정. viewport 경계 자동 보정 (하단 넘치면 위로 폴백)
  _positionMenuInViewport(pop, rect, {placement: 'below', gap: 6});
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

// 위임 핸들러 — 미니 에디터 내부 <img> 클릭 → 사이즈 팝오버 (작게/중간/크게/원본·삭제)
// 신규 삽입 직후(sanitize 전)는 .rich-img 클래스가 없으므로 img 전체 매칭.
document.addEventListener('click', function(e) {
  const img = e.target.closest && e.target.closest('.mini-editor-content img');
  if (!img) return;
  const contentDiv = img.closest('.mini-editor-content');
  if (!contentDiv) return;
  e.preventDefault();
  openMiniEditorImagePopover(img, contentDiv);
});

// ══════════════════════════════════════
// 미니 에디터 — 이미지 사이즈 팝오버 (작게/중간/크게/원본·삭제)
//   .mini-editor-content 내부 <img.rich-img> 클릭 시 말풍선 팝오버 노출.
//   - 4개 사이즈 버튼: 작게(sm 25%) / 중간(md 50%) / 크게(lg 75%) / 원본(100%)
//   - 현재 적용 사이즈 버튼 활성 표시
//   - 삭제 버튼 → <img> 제거 + oninput 트리거
//   - 외부 클릭 또는 ESC 로 닫기
//   - data-rich-size 속성으로 저장, sanitize 후처리에서 class 부여
// ══════════════════════════════════════
var _miniEditorImagePopover = null;

function closeMiniEditorImagePopover() {
  if (_miniEditorImagePopover) {
    // 선택 outline 정리 (.rich-img 가 아직 없는 신규 이미지도 포함)
    document.querySelectorAll('.mini-editor-content img.is-selected')
      .forEach(el => el.classList.remove('is-selected'));
    _miniEditorImagePopover.remove();
    _miniEditorImagePopover = null;
    document.removeEventListener('mousedown', _miniEditorImagePopoverOutside, true);
    document.removeEventListener('keydown', _miniEditorImagePopoverKey, true);
  }
}

function _miniEditorImagePopoverOutside(e) {
  if (!_miniEditorImagePopover) return;
  if (_miniEditorImagePopover.contains(e.target)) return;
  // 다른 이미지 클릭이면 팝오버 교체 (위임 핸들러가 새 openMiniEditorImagePopover 호출)
  if (e.target.closest && e.target.closest('.mini-editor-content img')) return;
  closeMiniEditorImagePopover();
}

function _miniEditorImagePopoverKey(e) {
  if (e.key === 'Escape') closeMiniEditorImagePopover();
}

function openMiniEditorImagePopover(imgEl, contentDiv) {
  closeMiniEditorImagePopover();
  imgEl.classList.add('is-selected');
  const rect = imgEl.getBoundingClientRect();
  const pop = document.createElement('div');
  pop.className = 'mini-editor-img-popover';
  const currentSize = (imgEl.getAttribute('data-rich-size') || 'orig').toLowerCase();
  const btn = (val, label) =>
    `<button type="button" class="meip-size ${currentSize===val?'is-active':''}" data-size="${val}" title="${label}">${label}</button>`;
  pop.innerHTML = `
    ${btn('sm','작게')}
    ${btn('md','중간')}
    ${btn('lg','크게')}
    ${btn('orig','원본')}
    <span class="meip-sep"></span>
    <button type="button" class="meip-delete" title="이미지 제거"><span class="material-icons-round notranslate" translate="no">delete</span></button>
  `;
  document.body.appendChild(pop);
  // 위치 계산 — 기존 링크 팝오버와 동일한 viewport-aware 헬퍼 사용
  _positionMenuInViewport(pop, rect, {placement: 'below', gap: 6});
  _miniEditorImagePopover = pop;

  const apply = (size) => {
    if (size === 'orig') imgEl.removeAttribute('data-rich-size');
    else imgEl.setAttribute('data-rich-size', size);
    // 즉시 시각 반영 — sanitize 가 다시 통과하기 전 미리보기 일치
    imgEl.classList.remove('rich-img-sm','rich-img-md','rich-img-lg');
    if (size === 'sm' || size === 'md' || size === 'lg') imgEl.classList.add('rich-img-' + size);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    // 활성 상태 갱신
    pop.querySelectorAll('.meip-size').forEach(b => {
      b.classList.toggle('is-active', b.dataset.size === size);
    });
  };

  pop.querySelectorAll('.meip-size').forEach(b => {
    b.addEventListener('click', () => apply(b.dataset.size));
  });

  pop.querySelector('.meip-delete').addEventListener('click', () => {
    const parent = imgEl.parentNode;
    if (!parent) return;
    parent.removeChild(imgEl);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    closeMiniEditorImagePopover();
  });

  // 팝오버 밖 클릭·ESC 로 닫기
  setTimeout(() => {
    document.addEventListener('mousedown', _miniEditorImagePopoverOutside, true);
    document.addEventListener('keydown', _miniEditorImagePopoverKey, true);
  }, 0);
}

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
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_csetCurrentItems[${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
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

// ══════════════════════════════════════════════════════════════════════
// SECTION: NG-SETS — NG 사항 번들 기준 데이터 페인 (migration 107)
//   caution_sets(cset) 패턴 완전 미러링. 캠페인 폼의 editModal 과
//   동일 nset 헬퍼를 재활용. 번들 자체 편집이므로 "번들 다시 불러오기" 없음.
// ══════════════════════════════════════════════════════════════════════
let _nsetCurrentItems = []; // 기준 데이터 페인 편집 중 items 상태
const MAX_NSET_ITEMS = 20;

async function renderNgSetTable() {
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
  try { rows = await fetchNgSetsAll(); } catch(e) {
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
        <button class="btn btn-ghost btn-xs" onclick='openNgSetEditModal(${JSON.stringify(r)})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${JSON.stringify(r)})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openNgSetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('nsetModalTitle').textContent = 'NG 사항 번들 추가';
  $('nsetEditId').value = '';
  $('nsetNameKo').value = '';
  $('nsetNameJa').value = '';
  document.querySelectorAll('input[name="nsetRT"]').forEach(cb => cb.checked = false);
  _nsetCurrentItems = [{html_ko:'', html_ja:''}];
  renderNgSetItems();
  $('nsetEditError').style.display = 'none';
  openModal('nsetEditModal');
}

function openNgSetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('nsetModalTitle').textContent = 'NG 사항 번들 편집';
  $('nsetEditId').value = row.id;
  $('nsetNameKo').value = row.name_ko || '';
  $('nsetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="nsetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _nsetCurrentItems = Array.isArray(row.items) && row.items.length
    ? row.items.map(normalizeNgItem)
    : [{html_ko:'', html_ja:''}];
  renderNgSetItems();
  $('nsetEditError').style.display = 'none';
  openModal('nsetEditModal');
}

function renderNgSetItems() {
  const wrap = $('nsetItemsWrap');
  if (!wrap) return;
  wrap.innerHTML = _nsetCurrentItems.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:#B3261E">NG ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="nsetMoveItem(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_nsetCurrentItems.length-1?'disabled':''} onclick="nsetMoveItem(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_nsetCurrentItems.length<=1?'disabled':''} onclick="nsetRemoveItem(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_nsetCurrentItems[${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_nsetCurrentItems[${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
        </div>
      </div>
    </div>
  `).join('');
  const addBtn = $('nsetAddItemBtn');
  if (addBtn) addBtn.disabled = _nsetCurrentItems.length >= MAX_NSET_ITEMS;
}

function nsetAddItem() {
  if (_nsetCurrentItems.length >= MAX_NSET_ITEMS) { toast(`NG 항목은 최대 ${MAX_NSET_ITEMS}개까지`,'error'); return; }
  _nsetCurrentItems.push({html_ko:'', html_ja:''});
  renderNgSetItems();
}

function nsetRemoveItem(idx) {
  if (_nsetCurrentItems.length <= 1) return;
  _nsetCurrentItems.splice(idx, 1);
  renderNgSetItems();
}

function nsetMoveItem(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _nsetCurrentItems.length) return;
  const [s] = _nsetCurrentItems.splice(idx, 1);
  _nsetCurrentItems.splice(j, 0, s);
  renderNgSetItems();
}

async function saveNgSetEdit() {
  const errEl = $('nsetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('nsetEditId').value;
  const name_ko = $('nsetNameKo').value.trim();
  const name_ja = $('nsetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 번들 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="nsetRT"]:checked')).map(cb => cb.value);
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _nsetCurrentItems
    .filter(s => !isNgItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  if (!items.length) { show('항목을 1개 이상 입력해주세요 (본문 한국어 또는 일본어 필수)'); return; }
  if (items.length > MAX_NSET_ITEMS) { show(`NG 항목은 최대 ${MAX_NSET_ITEMS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, items};
  try {
    if (id) await updateNgSet(id, payload);
    else await insertNgSet(payload);
    closeModal('nsetEditModal');
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

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — 번들(pset/cset) 캠페인 폼 통합
//   참여방법·주의사항 번들 select + 인라인 편집 + 미리보기 카드
// ════════════════════════════════════════════════════════════════════

async function populateCampPsetDropdown(formMode, recruitType, selectedSetId) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  if (!sel) return;
  let sets = [];
  try { sets = await fetchParticipationSets(recruitType); } catch(e) { sets = []; }
  _psetCache[formMode] = sets;

  // 운영 캠페인 보호 안전망:
  //   participation_set_id=NULL이지만 participation_steps가 존재할 때
  //   — 활성 번들 중 steps 완전 일치 번들을 자동 매칭 (UI 선택 표시만, DB는 NULL 유지)
  //   — 일치 없으면 가상 옵션 「(현재 캠페인 항목 — 번들 미선택)」 추가
  let resolvedSetId = selectedSetId;
  let showInlineOption = false;
  if (!selectedSetId && formMode === 'edit' && _editCampOriginal) {
    const currentSteps = Array.isArray(_editCampOriginal.participation_steps) ? _editCampOriginal.participation_steps : [];
    if (currentSteps.length > 0) {
      const matchedBundle = sets.find(s => JSON.stringify(s.steps) === JSON.stringify(currentSteps));
      if (matchedBundle) {
        resolvedSetId = matchedBundle.id;
      } else {
        showInlineOption = true;
      }
    }
  }

  const inlineOpt = showInlineOption
    ? `<option value="__INLINE__" selected>(현재 캠페인 항목 — 번들 미선택)</option>`
    : '';
  sel.innerHTML = `<option value="">— 번들 선택 —</option>${inlineOpt}` +
    sets.map(s => `<option value="${esc(s.id)}" ${resolvedSetId===s.id?'selected':''}>${esc(s.name_ko)}</option>`).join('');
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
        <input type="text" class="form-input" placeholder="제목 (일본어)" value="${esc(s.title_ja||'')}" style="font-size:13px;padding:8px 10px" oninput="_psetState['${formMode}'][${idx}].title_ja=this.value">
        ${miniEditorHtml(s.desc_ko||'', `_psetState['${formMode}'][${idx}].desc_ko=this.innerHTML`, '설명 (한국어)')}
        ${miniEditorHtml(s.desc_ja||'', `_psetState['${formMode}'][${idx}].desc_ja=this.innerHTML`, '설명 (일본어)')}
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

// 미니 에디터 desc(html) 값을 저장 전 sanitize — 외부 URL <img>·이벤트 핸들러 차단.
// title 은 평문 input 이라 별도 처리 불필요.
function _sanitizePsetStepsForSave(steps) {
  if (!Array.isArray(steps)) return [];
  var safe = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : function(h){ return String(h||''); };
  return steps.map(function(s){
    return {
      title_ko: (s.title_ko||''),
      title_ja: (s.title_ja||''),
      desc_ko : safe(s.desc_ko||''),
      desc_ja : safe(s.desc_ja||'')
    };
  });
}

// __INLINE__ 가상 옵션: 기존 캠페인 항목 유지 (set_id=NULL, steps 변동 없음)
function collectCampPsetPayload(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampPsetSelect' : 'newCampPsetSelect');
  const rawSetId = sel?.value || '';
  const steps = _sanitizePsetStepsForSave(
    _psetState[formMode].filter(s => (s.title_ja||s.title_ko||'').trim())
  );
  return {
    participation_set_id: (rawSetId === '' || rawSetId === '__INLINE__') ? null : rawSetId,
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

  // 운영 캠페인 보호 안전망:
  //   caution_set_id=NULL이지만 caution_items가 존재할 때
  //   — 활성 번들 중 items 완전 일치 번들을 자동 매칭 (UI 선택 표시만, DB는 NULL 유지)
  //   — 일치 없으면 가상 옵션 「(현재 캠페인 항목 — 번들 미선택)」 추가
  let resolvedSetId = selectedSetId;
  let showInlineOption = false;
  if (!selectedSetId && formMode === 'edit' && _editCampOriginal) {
    const currentItems = Array.isArray(_editCampOriginal.caution_items) ? _editCampOriginal.caution_items : [];
    if (currentItems.length > 0) {
      const matchedBundle = sets.find(s => JSON.stringify(s.items) === JSON.stringify(currentItems));
      if (matchedBundle) {
        resolvedSetId = matchedBundle.id; // UI 선택 표시 (DB set_id는 NULL 유지)
      } else {
        showInlineOption = true;
      }
    }
  }

  const inlineOpt = showInlineOption
    ? `<option value="__INLINE__" selected>(현재 캠페인 항목 — 번들 미선택)</option>`
    : '';
  sel.innerHTML = `<option value="">— 번들 선택 —</option>${inlineOpt}` +
    sets.map(s => `<option value="${esc(s.id)}" ${resolvedSetId===s.id?'selected':''}>${esc(s.name_ko)}</option>`).join('');
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
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_csetState['${formMode}'][${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
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
// __INLINE__ 가상 옵션: 기존 캠페인 항목 유지 (set_id=NULL, items 변동 없음)
function collectCampCsetPayload(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampCsetSelect' : 'newCampCsetSelect');
  const rawSetId = sel?.value || '';
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _csetState[formMode]
    .filter(s => !isCsetItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  return {
    caution_set_id: (rawSetId === '' || rawSetId === '__INLINE__') ? null : rawSetId,
    caution_items: items  // 빈 배열이면 '[]'로 저장됨 (NOT NULL)
  };
}

// ══════════════════════════════════════
// 캠페인 폼: NG 사항 번들 + 인라인 items 편집 (migration 107)
//   caution_sets(_csetState) 패턴 완전 미러링
// ══════════════════════════════════════
const _nsetState = { new: [], edit: [] }; // 모드별 현재 items 배열
const _nsetCache = { new: [], edit: [] }; // 모드별 드롭다운 원본 번들 리스트

async function populateCampNsetDropdown(formMode, recruitType, selectedSetId) {
  const sel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
  if (!sel) return;
  let sets = [];
  try { sets = await fetchNgSets(recruitType); } catch(e) { sets = []; }
  _nsetCache[formMode] = sets;

  // 운영 캠페인 보호 안전망:
  //   ng_set_id=NULL이지만 ng_items가 존재할 때
  //   — 활성 번들 중 items 완전 일치 번들을 자동 매칭 (UI 선택 표시만, DB는 NULL 유지)
  //   — 일치 없으면 가상 옵션 「(현재 캠페인 항목 — 번들 미선택)」 추가
  let resolvedSetId = selectedSetId;
  let showInlineOption = false;
  if (!selectedSetId && formMode === 'edit' && _editCampOriginal) {
    const currentItems = Array.isArray(_editCampOriginal.ng_items) ? _editCampOriginal.ng_items : [];
    if (currentItems.length > 0) {
      const matchedBundle = sets.find(s => JSON.stringify(s.items) === JSON.stringify(currentItems));
      if (matchedBundle) {
        resolvedSetId = matchedBundle.id;
      } else {
        showInlineOption = true;
      }
    }
  }

  const inlineOpt = showInlineOption
    ? `<option value="__INLINE__" selected>(현재 캠페인 항목 — 번들 미선택)</option>`
    : '';
  sel.innerHTML = `<option value="">— 번들 선택 —</option>${inlineOpt}` +
    sets.map(s => `<option value="${esc(s.id)}" ${resolvedSetId===s.id?'selected':''}>${esc(s.name_ko)}</option>`).join('');
}

function onNsetSelectChange(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
  if (!sel) return;
  const set = _nsetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  const hasContent = _nsetState[formMode].some(s => !isNgItemEmpty(s.html_ko, s.html_ja));
  const apply = () => {
    _nsetState[formMode] = (set.items||[]).map(normalizeNgItem);
    renderCampNgItems(formMode);
  };
  if (!hasContent) { apply(); return; }
  showConfirm('현재 입력된 NG 사항을 덮어쓸까요?').then(ok => { if (ok) apply(); else sel.value = ''; });
}

async function reloadNsetFromBundle(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
  if (!sel || !sel.value) { toast('먼저 번들을 선택하세요','error'); return; }
  const set = _nsetCache[formMode].find(s => s.id === sel.value);
  if (!set) return;
  const ok = await showConfirm(`번들 "${set.name_ko}"의 현재 내용으로 덮어쓸까요?`);
  if (!ok) return;
  _nsetState[formMode] = (set.items||[]).map(normalizeNgItem);
  renderCampNgItems(formMode);
}

function renderCampNgItems(formMode) {
  const wrap = $(formMode === 'edit' ? 'editCampNgItems' : 'newCampNgItems');
  if (!wrap) return;
  const arr = _nsetState[formMode];
  if (!arr.length) {
    wrap.innerHTML = `<div style="font-size:12px;color:var(--muted);padding:8px 0">NG 항목이 없습니다. 번들을 선택하거나 항목을 추가하세요.</div>`;
    window.dispatchEvent(new Event('reverb:campFormChange'));
    return;
  }
  wrap.innerHTML = arr.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:#B3261E">NG ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="moveCampNsetItem('${formMode}',${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===arr.length-1?'disabled':''} onclick="moveCampNsetItem('${formMode}',${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" onclick="removeCampNsetItem('${formMode}',${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_nsetState['${formMode}'][${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_nsetState['${formMode}'][${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
        </div>
      </div>
    </div>
  `).join('');
  window.dispatchEvent(new Event('reverb:campFormChange'));
}

function addCampNsetItem(formMode) {
  if (_nsetState[formMode].length >= MAX_NSET_ITEMS) { toast(`NG 항목은 최대 ${MAX_NSET_ITEMS}개까지`,'error'); return; }
  _nsetState[formMode].push({html_ko:'', html_ja:''});
  renderCampNgItems(formMode);
}

function removeCampNsetItem(formMode, idx) {
  _nsetState[formMode].splice(idx, 1);
  renderCampNgItems(formMode);
}

function moveCampNsetItem(formMode, idx, dir) {
  const arr = _nsetState[formMode];
  const j = idx + dir;
  if (j < 0 || j >= arr.length) return;
  const [s] = arr.splice(idx, 1);
  arr.splice(j, 0, s);
  renderCampNgItems(formMode);
}

function isNgItemEmpty(htmlKo, htmlJa) {
  const strip = h => (h||'').replace(/<[^>]*>/g,'').replace(/&nbsp;/g,' ').trim();
  return !strip(htmlKo) && !strip(htmlJa);
}

// ng_item 정규화 — {html_ko, html_ja} 구조 보장
function normalizeNgItem(s) {
  if (!s) return {html_ko:'', html_ja:''};
  return { html_ko: s.html_ko || '', html_ja: s.html_ja || '' };
}

// 저장 payload: {ng_set_id, ng_items} — items 는 {html_ko, html_ja} 형식 + 저장 전 sanitize
// __INLINE__ 가상 옵션: 기존 캠페인 항목 유지 (set_id=NULL, items 변동 없음)
function collectCampNsetPayload(formMode) {
  const sel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
  const rawSetId = sel?.value || '';
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _nsetState[formMode]
    .filter(s => !isNgItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  return {
    ng_set_id: (rawSetId === '' || rawSetId === '__INLINE__') ? null : rawSetId,
    ng_items: items  // 빈 배열이면 '[]'로 저장됨 (NOT NULL)
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
  let summarySuffix;
  if (kind === 'pset') summarySuffix = 'PsetSummary';
  else if (kind === 'cset') summarySuffix = 'CsetSummary';
  else summarySuffix = 'NsetSummary'; // nset
  const summaryId = (formMode === 'edit' ? 'editCamp' : 'newCamp') + summarySuffix;
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
      + `<div class="summary-lang-grid"><div class="summary-lang-col"><div class="summary-lang-title">한국어</div>${koCol}</div><div class="summary-lang-col"><div class="summary-lang-title">일본어</div>${jaCol}</div></div>`;
  } else if (kind === 'cset') {
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
      + `<div class="summary-lang-grid"><div class="summary-lang-col"><div class="summary-lang-title">한국어</div><ul class="summary-lang-list">${koCol}</ul></div><div class="summary-lang-col"><div class="summary-lang-title">일본어</div><ul class="summary-lang-list">${jaCol}</ul></div></div>`;
  } else {
    // nset — NG 사항 번들 요약 카드 (caution 패턴 완전 미러링)
    const sel = $(formMode === 'edit' ? 'editCampNsetSelect' : 'newCampNsetSelect');
    const bundleName = sel?.selectedOptions?.[0]?.text && sel.value ? sel.selectedOptions[0].text : '';
    const items = _nsetState[formMode] || [];
    if (!items.length) {
      body.innerHTML = '<div class="summary-head" style="color:var(--muted)">번들 미선택 또는 항목 없음 — 편집 버튼으로 항목을 추가하거나 번들을 선택하세요</div>';
      return;
    }
    const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
    const koCol = items.map(it => `<li>${sanitize(it.html_ko || it.html_ja || '')}</li>`).join('');
    const jaCol = items.map(it => `<li>${sanitize(it.html_ja || it.html_ko || '')}</li>`).join('');
    body.innerHTML = `<div class="summary-head">${bundleName ? `<span style="font-weight:600">${esc(bundleName)}</span> · ` : ''}<span style="color:var(--muted)">${items.length}개 항목</span></div>`
      + `<div class="summary-lang-grid"><div class="summary-lang-col"><div class="summary-lang-title">한국어</div><ul class="summary-lang-list">${koCol}</ul></div><div class="summary-lang-col"><div class="summary-lang-title">일본어</div><ul class="summary-lang-list">${jaCol}</ul></div></div>`;
  }
}

function openCampBundleModal(kind, formMode) {
  let groupSuffix;
  if (kind === 'pset') groupSuffix = 'PsetGroup';
  else if (kind === 'cset') groupSuffix = 'CsetGroup';
  else groupSuffix = 'NsetGroup';  // nset
  const groupId = (formMode === 'edit' ? 'editCamp' : 'newCamp') + groupSuffix;
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
  if (title) {
    const titleMap = { pset: '참여방법', cset: '주의사항', nset: 'NG 사항' };
    title.textContent = (titleMap[kind] || kind) + ' 편집';
  }
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
  // 모달 안에서 한 편집(텍스트·이미지 위치 변경 포함)은 페인 input 리스너에
  // bubble 되지 않는다 (DOM 이 한동안 페인 밖에 있어서). 닫을 때 명시적으로
  // 미리보기 갱신 트리거 — _psetState/_csetState/_nsetState 에서 최신 값 재수집.
  window.dispatchEvent(new Event('reverb:campFormChange'));
  _campBundleModalReturn = null;
}

// ════════════════════════════════════════════════════════════════════
// SECTION: MY-ACCOUNT — 본인 계정 정보/비밀번호
// ════════════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-ACCOUNTS — 추가/편집/삭제 모달 + 초대(RPC) + 비밀번호
// ════════════════════════════════════════════════════════════════════

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
// ════════════════════════════════════════════════════════════════════
// SECTION: DASHBOARD — 주소 도넛 + 가입 추이 + 프로필 완성률
// ════════════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════════════
// SECTION: DELIVERABLES — 결과물 검수 페인 + 라이트박스 + 통합 보기
// ════════════════════════════════════════════════════════════════════

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
  resetMultiFilter('delivRecruitTypeMulti', '전체 타입');
  resetMultiFilter('delivReceiptStatusMulti', '전체');
  resetMultiFilter('delivResultStatusMulti', '전체');
  resetMultiFilter('delivCampMulti', '전체 캠페인');
  const q = $('delivSearch'); if (q) q.value = '';
  const cb = $('delivIncludeMissing'); if (cb) cb.checked = false;
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

// 신청 관리 사이드바 배지 — 대기(pending) 개수 (가벼운 count 쿼리, 전건 fetch 불필요)
async function refreshApplySidebarBadge() {
  const el = $('adminApplySi');
  if (!el) return;
  try {
    const n = await fetchPendingApplicationCount();
    el.innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">신청 관리</span>${n>0?`<span class="admin-si-badge">${n>999?'999+':n}</span>`:''}`;
  } catch(e) { /* 무시 */ }
}

var delivLazy = null;
const DELIV_PAGE_SIZE = 50;

async function renderDeliverablesList() {
  const tbody = $('delivTableBody');
  if (!tbody) return;
  tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  await loadApplicantMsgUnread();  // 응모건 메시지 본인 미열람 배지 맵

  // 캠페인 리스트 로드 + 모집타입↔캠페인 캐스케이드
  const campsForFilter = await fetchCampaigns().catch(() => []);
  const sortedCampsForFilter = campsForFilter.slice().sort((a,b) => new Date(b.created_at) - new Date(a.created_at));

  const recruitTypeVals = getMultiFilterValues('delivRecruitTypeMulti');
  const delivCampValsRaw = getMultiFilterValues('delivCampMulti');

  // 캠페인 옵션: 모집 타입 필터 있으면 해당 타입 캠페인만 노출
  const campOptionsSource = recruitTypeVals.length > 0
    ? sortedCampsForFilter.filter(c => recruitTypeVals.includes(c.recruit_type))
    : sortedCampsForFilter;

  const campStale = delivCampValsRaw.filter(v => !campOptionsSource.some(c => c.id === v));
  if (campStale.length > 0 && typeof toast === 'function') toast(`선택한 캠페인 ${campStale.length}건이 모집 타입 필터에 맞지 않아 해제되었습니다`, 'info');

  const receiptStatusVals = getMultiFilterValues('delivReceiptStatusMulti');
  const resultStatusVals = getMultiFilterValues('delivResultStatusMulti');
  const delivCampVals = getMultiFilterValues('delivCampMulti');
  const includeMissing = !!$('delivIncludeMissing')?.checked;
  const search = ($('delivSearch')?.value || '').trim().toLowerCase();

  // deliverables 전체 조회 (status·kind는 클라이언트에서 분기)
  const allDelivs = await fetchDeliverables({status: 'all', kind: 'all', campaign_id: 'all'});
  _delivCache = allDelivs;

  // 미제출 토글 ON 시 당첨된(approved) 신청도 fetch — deliverable 0건 행 노출
  let approvedApps = [];
  let infMissingMap = {};
  if (includeMissing) {
    approvedApps = await fetchApplications({status: 'approved'});
    const userIds = [...new Set(approvedApps.map(a => a.user_id).filter(Boolean))];
    infMissingMap = await fetchInfluencersByIds(userIds);
  }

  // 신청(application_id) 단위 group — 한 신청에 영수증·결과물 둘 다 묶음
  // result 슬롯 = review_image (monitor) 또는 post (gifting/visit)
  const groups = new Map();
  const upsertGroup = (appId, camp, inf) => {
    if (!groups.has(appId)) {
      groups.set(appId, {
        application_id: appId,
        campaign: camp || null,
        influencer: inf || null,
        receipt: null,    // kind === 'receipt' 최신
        result: null,     // kind === 'review_image' 또는 'post' 최신
        latest_submitted_at: null,
      });
    }
    return groups.get(appId);
  };
  const campMap = new Map(campsForFilter.map(c => [c.id, c]));
  for (const d of allDelivs) {
    if (!d.application_id) continue;
    const camp = d.campaigns || campMap.get(d.campaign_id) || null;
    const g = upsertGroup(d.application_id, camp, d.influencers);
    if (!g.influencer && d.influencers) g.influencer = d.influencers;
    const subAt = d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image' || d.kind === 'post') {
      if (!g.result || subAt > (g.result.submitted_at || '')) g.result = d;
    }
    if (!g.latest_submitted_at || subAt > g.latest_submitted_at) g.latest_submitted_at = subAt;
  }
  if (includeMissing) {
    for (const app of approvedApps) {
      if (groups.has(app.id)) continue;
      upsertGroup(app.id, campMap.get(app.campaign_id) || null, infMissingMap[app.user_id] || null);
    }
  }

  // 옵션별 카운트 — 사용자가 「리스트에 해당하는 건수」를 미리 보고 선택할 수 있도록
  // 다른 필터는 무시하고 「전체 데이터에서 그 옵션 만족하는 group 수」 기준
  const allGroups = Array.from(groups.values());
  const campCounts = {};
  const recruitTypeCounts = {};
  const receiptStatusCounts = {pending:0, approved:0, rejected:0, none:0};
  const resultStatusCounts = {pending:0, approved:0, rejected:0, none:0};
  for (const g of allGroups) {
    const cid = g.campaign?.id;
    if (cid) campCounts[cid] = (campCounts[cid] || 0) + 1;
    const rt = g.campaign?.recruit_type;
    if (rt) recruitTypeCounts[rt] = (recruitTypeCounts[rt] || 0) + 1;
    const rs = g.receipt ? g.receipt.status : 'none';
    if (rs in receiptStatusCounts) receiptStatusCounts[rs]++;
    const xs = g.result ? g.result.status : 'none';
    if (xs in resultStatusCounts) resultStatusCounts[xs]++;
  }

  // 캠페인 드롭다운 sync — 카운트 + subLabel(캠페인 번호) 포함
  syncCampMultiFilter('delivCampMulti', campOptionsSource, () => renderDeliverablesList(), campCounts);
  // 모집 타입 드롭다운 — 옵션 자체는 고정이지만 카운트 갱신
  syncMultiFilter('delivRecruitTypeMulti', '전체 타입', [
    {value:'monitor', label:'리뷰어',  count: recruitTypeCounts.monitor || 0},
    {value:'gifting', label:'기프팅',  count: recruitTypeCounts.gifting || 0},
    {value:'visit',   label:'방문형',  count: recruitTypeCounts.visit || 0},
  ], () => renderDeliverablesList());
  // 영수증·결과물 상태 드롭다운 — 카운트 갱신
  syncMultiFilter('delivReceiptStatusMulti', '전체', [
    {value:'pending',  label:'검수대기', count: receiptStatusCounts.pending},
    {value:'approved', label:'승인',    count: receiptStatusCounts.approved},
    {value:'rejected', label:'비승인',  count: receiptStatusCounts.rejected},
    {value:'none',     label:'미제출',  count: receiptStatusCounts.none},
  ], () => renderDeliverablesList());
  syncMultiFilter('delivResultStatusMulti', '전체', [
    {value:'pending',  label:'검수대기', count: resultStatusCounts.pending},
    {value:'approved', label:'승인',    count: resultStatusCounts.approved},
    {value:'rejected', label:'비승인',  count: resultStatusCounts.rejected},
    {value:'none',     label:'미제출',  count: resultStatusCounts.none},
  ], () => renderDeliverablesList());

  // 필터 적용
  let filtered = Array.from(groups.values());
  if (recruitTypeVals.length > 0) filtered = filtered.filter(g => g.campaign && recruitTypeVals.includes(g.campaign.recruit_type));
  if (delivCampVals.length > 0) filtered = filtered.filter(g => g.campaign && delivCampVals.includes(g.campaign.id));
  if (receiptStatusVals.length > 0) filtered = filtered.filter(g => {
    const s = g.receipt ? g.receipt.status : 'none';
    return receiptStatusVals.includes(s);
  });
  if (resultStatusVals.length > 0) filtered = filtered.filter(g => {
    const s = g.result ? g.result.status : 'none';
    return resultStatusVals.includes(s);
  });
  if (search) filtered = filtered.filter(g => {
    const inf = g.influencer || {};
    const camp = g.campaign || {};
    const n = (inf.name || '') + ' ' + (inf.name_kana || '') + ' ' + (inf.email || '');
    return n.toLowerCase().includes(search)
      || (camp.title || '').toLowerCase().includes(search)
      || (camp.brand || '').toLowerCase().includes(search)
      || (camp.campaign_no || '').toLowerCase().includes(search);
  });

  updateFilterResetBtn('btnDelivFilterReset', ['delivRecruitTypeMulti','delivReceiptStatusMulti','delivResultStatusMulti','delivCampMulti'], 'delivSearch');

  // 정렬: 수동 sort 있으면 그대로, 없으면 검수대기 우선 → 최근 제출일 내림차순
  if (_delivSort.col === 'submitted') {
    const dir = _delivSort.dir === 'desc' ? -1 : 1;
    filtered.sort((a, b) => (a.latest_submitted_at || '').localeCompare(b.latest_submitted_at || '') * dir);
  } else {
    filtered.sort((a, b) => {
      const aPending = (a.receipt?.status === 'pending') || (a.result?.status === 'pending') ? 0 : 1;
      const bPending = (b.receipt?.status === 'pending') || (b.result?.status === 'pending') ? 0 : 1;
      if (aPending !== bPending) return aPending - bPending;
      return (b.latest_submitted_at || '').localeCompare(a.latest_submitted_at || '');
    });
  }
  applyDelivSortIndicators();

  const cnt = $('delivTotalCount');
  if (cnt) cnt.textContent = `총 ${filtered.length}건`;

  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (delivLazy) delivLazy.destroy();
  delivLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows: filtered,
    renderRow: renderDelivAppRow,
    pageSize: DELIV_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 결과물이 없습니다.</td></tr>',
  });
  refreshDelivSidebarBadge();
}

// 신청 1건 = 1행. 영수증 셀 / 결과물 셀 각각 상태 배지·미리보기 노출.
// 양쪽 모두 「승인」(또는 gifting의 경우 결과물 단독 「승인」)이면 좌측 초록 보더 = 「완료」
function renderDelivAppRow(g) {
  const camp = g.campaign || {};
  const inf = g.influencer || {};
  const rt = camp.recruit_type;
  const rtBadge = (typeof getRecruitTypeBadgeKoSm === 'function') ? getRecruitTypeBadgeKoSm(rt) : esc(rt || '—');
  const infName = esc(inf.name || '—');
  const infEmail = esc(inf.email || '');
  const infLine = inf.line_id ? `LINE: ${esc(inf.line_id)}` : '';
  const infSub = infEmail + (infLine ? `<br>${infLine}` : '');

  const receiptCell = renderDelivStatusCell(g.receipt, 'receipt', rt);
  const resultCell = renderDelivStatusCell(g.result, 'result', rt);

  // 영수증은 monitor(리뷰어) 캠페인에서만 사용. gifting/visit은 영수증 단계 없음.
  // (CLAUDE.md: monitor=영수증, gifting/visit=SNS 게시 URL)
  const useReceipt = rt === 'monitor';
  const completed = useReceipt
    ? (g.receipt?.status === 'approved' && g.result?.status === 'approved')
    : (g.result?.status === 'approved');
  const rowStyle = completed ? 'border-left:4px solid #2D7A3E' : '';

  const submittedCell = g.latest_submitted_at
    ? `<span style="font-size:12px">${formatDate(g.latest_submitted_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">미제출</span>';

  const campNoBadge = camp.campaign_no
    ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted);margin-right:6px">${esc(camp.campaign_no)}</span>`
    : '';

  return `<tr data-app-id="${esc(g.application_id)}" style="${rowStyle}">
    <td>${rtBadge}</td>
    <td>${campNoBadge}<div>${esc(camp.title || '—')}</div><div style="font-size:10px;color:var(--muted)">${esc(camp.brand || '')}</div></td>
    <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${esc(inf.id||'')}')">${infName}${(typeof influencerStatusBadges === 'function') ? influencerStatusBadges(inf) : ''}</div>${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}<div style="margin-top:4px">${renderApplicantMsgBtn({id: g.application_id, campaign_id: (camp && camp.id) || ''})}</div></td>
    <td>${receiptCell}</td>
    <td>${resultCell}</td>
    <td>${submittedCell}</td>
    <td><button class="btn btn-ghost btn-xs" onclick="openDelivCombined('${esc(g.application_id)}')">검수</button></td>
  </tr>`;
}

// 영수증·결과물 셀 — slot: 'receipt' | 'result', rt: campaign.recruit_type
function renderDelivStatusCell(d, slot, rt) {
  // 영수증은 monitor에서만 사용. gifting/visit은 영수증 단계 없음 → 「-」 표시
  if (slot === 'receipt' && rt !== 'monitor') {
    return '<span style="font-size:11px;color:var(--muted)">—</span>';
  }
  if (!d) {
    return '<span style="display:inline-block;background:#f5f5f5;color:var(--muted);font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">미제출</span>';
  }
  let preview = '';
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    if (d.receipt_url) {
      const thumb = (typeof imgThumb === 'function') ? imgThumb(d.receipt_url, 64, 80) : d.receipt_url;
      preview = `<img src="${esc(thumb)}" data-orig="${esc(d.receipt_url)}" loading="lazy" decoding="async" style="width:32px;height:32px;border-radius:4px;object-fit:cover;cursor:pointer;background:#f5f5f5" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" onclick="event.stopPropagation();openImageLightbox('${esc(d.receipt_url)}')">`;
    }
  } else if (d.kind === 'post') {
    if (d.post_url) {
      let host = '';
      try { host = new URL(d.post_url).hostname.replace(/^www\./, ''); } catch(e) { host = d.post_url; }
      preview = `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" onclick="event.stopPropagation()" style="font-size:10px;color:var(--dark-pink);text-decoration:none;display:inline-block;max-width:100px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:middle">${esc(host)}</a>`;
    }
  }
  return `<div style="display:flex;align-items:center;gap:6px">${preview}${delivStatusBadge(d.status)}</div>`;
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
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    // receipt(영수증) + review_image(monitor 2단계 리뷰 캡처) 모두 receipt_url 컬럼을 재사용 (093 마이그레이션)
    // receipt kind 는 주문번호·구매일·구매금액 마스킹 해제 + 수정 폼 + 변경 이력 (마이그레이션 128)
    const altText = d.kind === 'receipt' ? '영수증' : '리뷰 이미지';
    const receiptInfoBlock = (d.kind === 'receipt') ? renderReceiptInfoBlock(d) : '';
    contentHtml = `
      <div style="display:grid;grid-template-columns:240px 1fr;gap:16px">
        <div>
          ${d.receipt_url
            ? `<img src="${esc(d.receipt_url)}" alt="${esc(altText)}" style="width:100%;border:1px solid var(--line);border-radius:8px;cursor:zoom-in" onclick="openImageLightbox('${esc(d.receipt_url)}')">`
            : '<div style="width:100%;height:180px;background:#f5f5f5;border-radius:8px;display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:12px">이미지 없음</div>'}
        </div>
        <div style="font-size:13px">
          <div style="margin-bottom:8px"><span style="color:var(--muted)">결과물 종류</span> · <strong>${esc(altText)}</strong></div>
          ${receiptInfoBlock}
          ${d.memo ? `<div style="margin-bottom:8px"><span style="color:var(--muted)">메모</span> · ${esc(d.memo)}</div>` : ''}
          <div style="margin-top:14px;padding-top:10px;border-top:1px dashed var(--line);font-size:11px;color:var(--muted)">
            제출일 · ${formatDate(d.submitted_at)}<br>
            최종 수정 · ${formatDate(d.updated_at)}<br>
            version · ${d.version}
          </div>
        </div>
      </div>`;
  } else {
    // post (gifting/visit 게시물 URL)
    const subs = Array.isArray(d.post_submissions) ? d.post_submissions : [];
    contentHtml = `
      <div style="font-size:13px">
        <div style="margin-bottom:10px"><span style="color:var(--muted)">채널</span> · <strong>${esc(d.post_channel || '—')}</strong></div>
        <div style="margin-bottom:10px"><span style="color:var(--muted)">URL</span> · ${d.post_url ? `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" style="color:var(--dark-pink);word-break:break-all">${esc(d.post_url)}</a>` : '—'}</div>
        ${subs.length ? `<div style="margin-top:12px"><span style="color:var(--muted);font-size:11px">제출 이력 (${subs.length}건)</span><ul style="margin:6px 0 0;padding-left:18px;font-size:11px">${subs.map(s => `<li>${esc(s.submitted_at || '')} · ${esc(s.channel || '')}</li>`).join('')}</ul></div>` : ''}
      </div>`;
  }

  // 변경 이력 — 최근 2건 + 「더보기」 토글 (2026-05-15 사용자 요청)
  if (events.length) {
    contentHtml += '<div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--line)"><div style="font-size:12px;font-weight:600;color:var(--ink);margin-bottom:8px">변경 이력</div>';
    contentHtml += renderDeliverableEventsTimeline(events, 'detail-' + d.id);
    contentHtml += '</div>';
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
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('승인 처리되었습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
}

async function revertDeliv(id, version) {
  const ok = await showConfirm('검수 결과를 되돌리시겠습니까?\n상태가 검수대기로 변경됩니다.\n\n인플루언서가 이미 결과를 확인했을 수 있습니다.');
  if (!ok) return;
  const ret = await updateDeliverableStatus(id, 'pending', version);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다.', 'warn');
    closeDelivDetail();
    await renderDeliverablesList();
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('검수대기로 되돌렸습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
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
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('반려 처리되었습니다.');
  closeDelivRejectModal();
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
}


// ──────────────────────────────────────
// 결과물 관리 페인 합본 검수 모달 (Phase 2)
// 한 신청(application) 안의 영수증·결과물 양쪽을 한 화면에서 검수.
// 액션 버튼은 기존 approveDeliv/revertDeliv/openDelivRejectModal을 재사용하고,
// 처리 후 _delivCombinedRefreshAppId가 가리키는 application의 패널을 다시 렌더링.
// ──────────────────────────────────────
let _delivCombinedRefreshAppId = null;

async function openDelivCombined(applicationId) {
  const modal = $('delivCombinedModal');
  if (!modal) return;
  _delivCombinedRefreshAppId = applicationId;
  openModal('delivCombinedModal');
  await renderDelivCombinedBody(applicationId);
}

function closeDelivCombined() {
  closeModal('delivCombinedModal');
  _delivCombinedRefreshAppId = null;
}

async function renderDelivCombinedBody(applicationId) {
  const body = $('delivCombinedBody');
  const titleEl = $('delivCombinedTitle');
  if (!body) return;
  body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';

  // 1차: deliverables를 캠페인 join 포함해서 fetch (가장 안정적인 정보 출처)
  let allDelivs = [];
  let camp = null;
  let userId = null;
  if (db) {
    const delivRes = await db.from('deliverables').select(`
      id, kind, status, version, application_id, user_id, campaign_id,
      receipt_url, post_url, post_channel, post_submissions, memo,
      order_number, purchase_date, purchase_amount,
      reject_reason, reject_template_code,
      submitted_at, reviewed_at, updated_at, reviewed_by,
      campaigns:campaign_id (id, campaign_no, title, brand, recruit_type)
    `).eq('application_id', applicationId).neq('status', 'draft').order('submitted_at', {ascending: false});
    if (delivRes?.error) console.error('[deliv-combined deliv]', delivRes.error);
    allDelivs = delivRes?.data || [];
    if (allDelivs[0]) {
      camp = allDelivs[0].campaigns || null;
      userId = allDelivs[0].user_id || null;
    }
  }

  // 2차 fallback: deliverable이 0건(미제출 토글 ON으로 진입한 케이스)이면 applications에서 직접 fetch
  if (!camp && db) {
    const appRes = await db.from('applications').select('user_id, campaign_id, campaigns:campaign_id (id, campaign_no, title, brand, recruit_type)').eq('id', applicationId).maybeSingle();
    if (appRes?.error) console.error('[deliv-combined app]', appRes.error);
    const app = appRes?.data || null;
    if (app) {
      camp = app.campaigns || null;
      userId = app.user_id || null;
    }
  }

  if (!camp) {
    body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">캠페인 정보를 찾을 수 없습니다.</div>';
    return;
  }

  const rt = camp.recruit_type;
  const infMap = userId ? await fetchInfluencersByIds([userId]) : {};
  const inf = infMap[userId] || null;

  if (titleEl) {
    const campLabel = camp.campaign_no ? `[${esc(camp.campaign_no)}] ${esc(camp.title || '')}` : esc(camp.title || '캠페인');
    const infLabel = inf?.name || '—';
    titleEl.innerHTML = `${campLabel} <span style="font-size:12px;color:var(--muted);font-weight:400">· ${esc(infLabel)}</span>`;
  }

  // submitted_at 내림차순으로 정렬되어 있으므로 find = 최신 1건
  const receipt = allDelivs.find(d => d.kind === 'receipt') || null;
  const result = allDelivs.find(d => d.kind === 'review_image' || d.kind === 'post') || null;

  // 변경 이력 (제출/재제출/승인/반려/되돌리기 타임라인) — deliverable별 events fetch
  const [receiptEvents, resultEvents] = await Promise.all([
    receipt ? fetchDeliverableEvents(receipt.id) : Promise.resolve([]),
    result ? fetchDeliverableEvents(result.id) : Promise.resolve([]),
  ]);

  // 영수증 패널은 monitor에서만 노출. gifting/visit은 영수증 단계 없음.
  const showReceipt = rt === 'monitor';
  const resultLabel = rt === 'monitor' ? '결과물 (리뷰 캡쳐)' : '결과물 (게시 URL)';
  const stepLabel = rt === 'monitor' ? '<span style="font-size:10px;color:var(--muted);font-weight:400">· STEP 1</span>' : '';
  const stepLabel2 = rt === 'monitor' ? '<span style="font-size:10px;color:var(--muted);font-weight:400">· STEP 2</span>' : '';

  // 패널 헤더 우측에 상태 배지 노출 (deliverable 있을 때만)
  const receiptStatusBadge = receipt ? delivStatusBadge(receipt.status) : '';
  const resultStatusBadge = result ? delivStatusBadge(result.status) : '';

  body.innerHTML = `
    <div class="deliv-combined-grid">
      ${showReceipt
        ? `<div class="deliv-combined-panel">
            <div class="deliv-combined-panel-header"><span>영수증 ${stepLabel}</span>${receiptStatusBadge}</div>
            <div class="deliv-combined-panel-body">${renderDelivPanelContent(receipt, receiptEvents)}</div>
          </div>`
        : `<div class="deliv-combined-panel" style="opacity:.6">
            <div class="deliv-combined-panel-header" style="color:var(--muted)"><span>영수증 (해당 없음)</span></div>
            <div class="deliv-combined-panel-body" style="color:var(--muted);text-align:center;padding:40px;font-size:13px">이 모집 타입은 영수증 단계가 없습니다.</div>
          </div>`}
      <div class="deliv-combined-panel">
        <div class="deliv-combined-panel-header"><span>${esc(resultLabel)} ${stepLabel2}</span>${resultStatusBadge}</div>
        <div class="deliv-combined-panel-body">${renderDelivPanelContent(result, resultEvents)}</div>
      </div>
    </div>
  `;
}

// ─── 영수증 정보 블록 (마이그레이션 128) ─────────────────────
// kind='receipt' 결과물의 주문번호·구매일·구매금액을 노출.
// campaign_admin 이상은 인플레이스 수정 폼 + 변경 이력 토글 사용.
// (review_image kind는 이 블록 대상이 아니다 — 영수증과 별개 단계)
function renderReceiptInfoBlock(d) {
  if (!d || d.kind !== 'receipt') return '';
  const canEdit = isCampaignAdminOrAbove();
  const id = String(d.id);
  const orderNo = d.order_number || '';
  const purchaseDate = d.purchase_date || '';
  const amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
    ? null
    : Number(d.purchase_amount);
  const fmtMissing = '<span style="color:#C33">미입력</span>';
  const amtView = (amt === null || !Number.isFinite(amt)) ? fmtMissing : `¥${amt.toLocaleString()}`;
  const viewHtml = `
    <div id="receiptInfoView-${esc(id)}" style="font-size:12px;line-height:1.7;margin-bottom:10px;padding:10px 12px;background:#FAFAFA;border:1px solid var(--line);border-radius:8px">
      <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:4px">
        <strong style="font-size:12px;color:var(--ink)">영수증 정보</strong>
        ${canEdit ? `<button class="btn btn-ghost btn-xs" style="font-size:10px;padding:2px 8px" onclick="enterReceiptEditMode('${esc(id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">edit</span> 수정</button>` : ''}
      </div>
      <div><span style="color:var(--muted)">주문번호</span> · ${orderNo ? `<strong>${esc(orderNo)}</strong>` : fmtMissing}</div>
      <div><span style="color:var(--muted)">구매일</span> · ${purchaseDate ? esc(purchaseDate) : fmtMissing}</div>
      <div><span style="color:var(--muted)">구매금액</span> · ${amtView}</div>
      <div style="margin-top:6px"><button class="btn btn-ghost btn-xs" style="font-size:10px;padding:2px 8px" onclick="toggleReceiptHistory('${esc(id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">history</span> 변경 이력 보기</button></div>
      <div id="receiptHistoryBox-${esc(id)}" style="display:none;margin-top:8px;padding-top:8px;border-top:1px dashed var(--line)"></div>
    </div>`;
  const editHtml = canEdit ? `
    <div id="receiptInfoEdit-${esc(id)}" style="display:none;font-size:12px;margin-bottom:10px;padding:10px 12px;background:#FFF9E6;border:1px solid #F5C518;border-radius:8px">
      <div style="font-weight:600;margin-bottom:8px">영수증 정보 수정</div>
      <div style="margin-bottom:6px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">주문번호 *</label>
        <input id="receiptEditOrder-${esc(id)}" type="text" maxlength="200" value="${esc(orderNo)}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="margin-bottom:6px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">구매일 *</label>
        <input id="receiptEditDate-${esc(id)}" type="date" value="${esc(purchaseDate)}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="margin-bottom:8px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">구매금액 (엔) *</label>
        <input id="receiptEditAmount-${esc(id)}" type="number" min="0" step="1" value="${(amt === null || !Number.isFinite(amt)) ? '' : amt}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="display:flex;gap:6px;justify-content:flex-end">
        <button class="btn btn-ghost btn-xs" style="font-size:11px;padding:4px 10px" onclick="cancelReceiptEdit('${esc(id)}')">취소</button>
        <button class="btn btn-primary btn-xs" style="font-size:11px;padding:4px 10px" onclick="saveReceiptEdit('${esc(id)}')">저장</button>
      </div>
    </div>` : '';
  return viewHtml + editHtml;
}

function enterReceiptEditMode(id) {
  const v = document.getElementById('receiptInfoView-' + id);
  const e = document.getElementById('receiptInfoEdit-' + id);
  if (v) v.style.display = 'none';
  if (e) e.style.display = '';
}

function cancelReceiptEdit(id) {
  const v = document.getElementById('receiptInfoView-' + id);
  const e = document.getElementById('receiptInfoEdit-' + id);
  if (v) v.style.display = '';
  if (e) e.style.display = 'none';
}

async function saveReceiptEdit(id) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  const orderNo = (document.getElementById('receiptEditOrder-' + id)?.value || '').trim();
  const purchaseDate = document.getElementById('receiptEditDate-' + id)?.value || '';
  const rawAmount = document.getElementById('receiptEditAmount-' + id)?.value || '';
  if (!orderNo) { toast('주문번호를 입력해주세요','error'); return; }
  if (orderNo.length > 200) { toast('주문번호는 200자 이내로 입력해주세요','error'); return; }
  if (!purchaseDate) { toast('구매일을 입력해주세요','error'); return; }
  if (rawAmount === '' || rawAmount === null || rawAmount === undefined) {
    toast('구매금액을 입력해주세요','error'); return;
  }
  const amount = Number(rawAmount);
  if (!Number.isFinite(amount) || amount < 0) {
    toast('구매금액은 0 이상의 숫자를 입력해주세요','error'); return;
  }
  try {
    await updateReceiptAdmin(id, orderNo, purchaseDate, amount);
    toast('영수증 정보를 수정했습니다','success');
    // 현재 열린 모달 재로딩 (통합 검수 모달 우선, 단일 상세 모달 후순)
    if (typeof _delivCombinedRefreshAppId !== 'undefined' && _delivCombinedRefreshAppId) {
      await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    } else if (typeof _delivDetailCurrent !== 'undefined' && _delivDetailCurrent?.id) {
      await openDelivDetail(_delivDetailCurrent.id);
    }
    if (typeof refreshPane === 'function') await refreshPane('deliverables');
  } catch(e) {
    const msg = (e && e.message) ? e.message : String(e);
    toast(friendlyError(msg), 'error');
  }
}

async function toggleReceiptHistory(id) {
  const box = document.getElementById('receiptHistoryBox-' + id);
  if (!box) return;
  if (box.style.display !== 'none') { box.style.display = 'none'; return; }
  box.style.display = '';
  box.innerHTML = '<div style="font-size:11px;color:var(--muted)">불러오는 중...</div>';
  const rows = await fetchReceiptEditHistory(id);
  if (!rows.length) {
    box.innerHTML = '<div style="font-size:11px;color:var(--muted)">변경 이력이 없습니다.</div>';
    return;
  }
  const fmtAmt = v => (v === null || v === undefined || v === '')
    ? '(빈값)'
    : '¥' + Number(v).toLocaleString();
  const html = rows.map(r => {
    const lines = [];
    if ((r.order_number_prev || '') !== (r.order_number_next || '')) {
      lines.push(`<div>주문번호 · ${esc(r.order_number_prev || '(빈값)')} → <strong>${esc(r.order_number_next || '(빈값)')}</strong></div>`);
    }
    if (String(r.purchase_date_prev || '') !== String(r.purchase_date_next || '')) {
      lines.push(`<div>구매일 · ${esc(r.purchase_date_prev || '(빈값)')} → <strong>${esc(r.purchase_date_next || '(빈값)')}</strong></div>`);
    }
    if (String(r.purchase_amount_prev ?? '') !== String(r.purchase_amount_next ?? '')) {
      lines.push(`<div>구매금액 · ${fmtAmt(r.purchase_amount_prev)} → <strong>${fmtAmt(r.purchase_amount_next)}</strong></div>`);
    }
    return `<div style="padding:5px 0;border-bottom:1px dashed var(--line);font-size:11px">
      <div style="display:flex;justify-content:space-between;gap:10px;margin-bottom:3px">
        <span><strong>${esc(r.changed_by_name || '(이름미상)')}</strong></span>
        <span style="color:var(--muted);white-space:nowrap">${formatDate(r.changed_at)}</span>
      </div>
      ${lines.join('') || '<div style="color:var(--muted)">변경 사항 없음</div>'}
    </div>`;
  }).join('');
  box.innerHTML = `<div style="font-size:11px;font-weight:600;color:var(--ink);margin-bottom:4px">변경 이력 (${rows.length}건)</div>${html}`;
}

// ─── 결과물 변경 이력 타임라인 (최근 2건 + 더보기 토글, 2026-05-15 사용자 요청) ─
// 영수증 패널·결과물 패널·단일 결과물 모달 모두 동일 패턴으로 사용
// events: created_at DESC 정렬된 deliverable_events 배열
// scopeId: deliverable.id (각 패널마다 unique element id 생성용)
function renderDeliverableEventsTimeline(events, scopeId) {
  if (!Array.isArray(events) || !events.length) return '';
  var VISIBLE = 2;
  var total = events.length;
  var recent = events.slice(0, VISIBLE);
  var rest = events.slice(VISIBLE);
  var renderItem = function(e) {
    var labelMap = {submit:'제출', resubmit:'재제출', approve:'승인', reject:'반려', revert:'되돌리기'};
    var label = labelMap[e.action] || e.action;
    var transition = e.from_status
      ? ' · ' + esc(statusLabelKo(e.from_status)) + ' → ' + esc(statusLabelKo(e.to_status))
      : '';
    var reasonLine = e.reason
      ? '<div style="margin-top:4px;color:#C33;white-space:pre-wrap;line-height:1.5">' + esc(e.reason) + '</div>'
      : '';
    return '<div style="padding:5px 0;border-bottom:1px dashed var(--line)">'
      + '<div style="display:flex;justify-content:space-between;gap:10px">'
      + '<span><strong>' + esc(label) + '</strong>' + transition + '</span>'
      + '<span style="color:var(--muted);white-space:nowrap">' + formatDate(e.created_at) + '</span>'
      + '</div>' + reasonLine + '</div>';
  };
  var html = '<div style="font-size:11px">' + recent.map(renderItem).join('');
  if (rest.length > 0) {
    var sid = esc(String(scopeId));
    html += '<div id="delivEventsRest-' + sid + '" style="display:none">' + rest.map(renderItem).join('') + '</div>';
    html += '<div style="text-align:center;padding:6px 0">'
      + '<button id="delivEventsToggleBtn-' + sid + '" class="btn btn-ghost btn-xs" style="font-size:10px;padding:3px 10px" '
      + 'onclick="toggleDelivEventsRest(\'' + sid + '\', ' + rest.length + ')">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_more</span>'
      + ' 더보기 (' + rest.length + '건)'
      + '</button></div>';
  }
  html += '</div>';
  return html;
}

function toggleDelivEventsRest(scopeId, hiddenCount) {
  var box = document.getElementById('delivEventsRest-' + scopeId);
  var btn = document.getElementById('delivEventsToggleBtn-' + scopeId);
  if (!box || !btn) return;
  var isHidden = box.style.display === 'none';
  box.style.display = isHidden ? '' : 'none';
  btn.innerHTML = isHidden
    ? '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_less</span> 접기'
    : '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_more</span> 더보기 (' + hiddenCount + '건)';
}

// 합본 모달 안 한 패널의 본문 — 이미지/URL/메타/반려사유/이력 타임라인/액션버튼
// events: deliverable_events 배열 (제출/재제출/승인/반려/되돌리기 타임라인)
function renderDelivPanelContent(d, events) {
  if (!d) {
    return '<div style="text-align:center;color:var(--muted);padding:40px;font-size:13px">아직 제출되지 않았습니다.</div>';
  }
  let html = '';
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    html += `<div style="text-align:center;margin-bottom:12px">
      ${d.receipt_url
        ? `<img src="${esc(d.receipt_url)}" style="max-width:100%;max-height:280px;border:1px solid var(--line);border-radius:8px;cursor:zoom-in" onclick="openImageLightbox('${esc(d.receipt_url)}')">`
        : '<div style="height:140px;background:#f5f5f5;border-radius:8px;display:flex;align-items:center;justify-content:center;color:var(--muted)">이미지 없음</div>'}
    </div>`;
    // 영수증(receipt)만 주문번호·구매일·구매금액 정보 + 수정 + 이력 표시 (마이그레이션 128)
    // review_image kind는 해당 없음
    if (d.kind === 'receipt') {
      html += renderReceiptInfoBlock(d);
    }
  } else {
    html += `<div style="font-size:13px;line-height:1.7;margin-bottom:10px">
      <div><span style="color:var(--muted)">채널</span> · <strong>${esc(d.post_channel || '—')}</strong></div>
      <div style="margin-top:6px"><span style="color:var(--muted)">URL</span> · ${d.post_url ? `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" style="color:var(--dark-pink);word-break:break-all">${esc(d.post_url)}</a>` : '—'}</div>
      ${(Array.isArray(d.post_submissions) && d.post_submissions.length) ? `<div style="margin-top:8px;font-size:11px;color:var(--muted)">제출 이력 ${d.post_submissions.length}건</div>` : ''}
    </div>`;
  }
  // 상태는 패널 헤더 우측에 노출되므로 여기에선 제거. 제출일·검수일만 한 줄로 압축.
  html += `<div style="margin-bottom:10px;font-size:11px;color:var(--muted)">제출일 ${formatDate(d.submitted_at)}${d.reviewed_at ? ` · 검수일 ${formatDate(d.reviewed_at)}` : ''}</div>`;
  // 변경 이력 타임라인 — 최근 2건 + 「더보기」 토글 (2026-05-15 사용자 요청)
  if (Array.isArray(events) && events.length) {
    html += '<div style="margin-bottom:10px;padding-top:10px;border-top:1px solid var(--line)"><div style="font-size:12px;font-weight:600;color:var(--ink);margin-bottom:6px">변경 이력</div>';
    html += renderDeliverableEventsTimeline(events, 'panel-' + d.id);
    html += '</div>';
  }
  if (d.status === 'pending') {
    html += `<div style="display:flex;gap:6px;margin-top:12px;justify-content:flex-end">
      <button class="btn btn-ghost btn-sm" style="color:#C33;border-color:#C33;font-size:12px;padding:6px 12px" onclick="openDelivRejectModal('${esc(d.id)}', ${d.version})">반려</button>
      <button class="btn btn-primary btn-sm" style="font-size:12px;padding:6px 12px" onclick="approveDeliv('${esc(d.id)}', ${d.version})">승인</button>
    </div>`;
  } else {
    html += `<div style="display:flex;gap:6px;margin-top:12px;justify-content:flex-end">
      <button class="btn btn-ghost btn-sm" style="font-size:12px;padding:6px 12px" onclick="revertDeliv('${esc(d.id)}', ${d.version})">검수대기로 되돌리기</button>
    </div>`;
  }
  return html;
}


// ══════════════════════════════════════
// 캠페인 결과물 엑셀 다운로드 (exceljs 지연 로드 + 이미지 임베드)
// ══════════════════════════════════════
var _excelJsLoading = null;
// ════════════════════════════════════════════════════════════════════
// SECTION: EXCEL — ExcelJS lazy-load + 4종 export (캠페인 신청자/결과물)
// ════════════════════════════════════════════════════════════════════

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

// ─── 엑셀 export 공용 헬퍼 ─────────────────────────────────────────
// 인플루언서 이름 — 한자/가나 별도 컬럼용 (사용자 요청 형식)
function _excelInfluencerNameParts(u) {
  if (!u) return {kanji: '', kana: ''};
  return {
    kanji: (u.name_kanji || '').trim(),
    kana:  (u.name_kana || u.name || '').trim()
  };
}

// SNS 핸들 → 전체 URL 변환 (각 SNS 공식 URL 형식 유지). TikTok/YouTube 는 @ 필수
function _excelSnsUrl(channel, raw) {
  if (!raw) return '';
  var handle = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, raw) : String(raw).replace(/^@/, '').trim();
  if (!handle) return '';
  switch (channel) {
    case 'instagram': return 'https://www.instagram.com/' + handle + '/';
    case 'tiktok':    return 'https://www.tiktok.com/@' + handle;
    case 'x':         return 'https://x.com/' + handle;
    case 'youtube':   return 'https://www.youtube.com/@' + handle;
    default: return handle;
  }
}

// 우편번호 (별도 컬럼용). 〒 prefix 제거, 하이픈 유지
function _excelZip(u) {
  if (!u || !u.zip) return '';
  return String(u.zip).replace(/^〒\s*/, '').trim();
}

// 주소 본문 (우편번호 제외). 도도부현 + 시군구 + 건물
function _excelAddressOnly(u, fallback) {
  if (u && (u.prefecture || u.city || u.building)) {
    return (u.prefecture || '') + (u.city || '') + (u.building ? ' ' + u.building : '');
  }
  return fallback || '';
}

// ─── 캠페인 다중 선택 + 통합 엑셀 ────────────────────────────────────
// _selectedCampIds: 사용자가 체크한 캠페인 id 집합. 페인 이동/새로고침 시 초기화.
// 필터·정렬·lazy-load remount 와 무관하게 Set 기반 절대 선택 유지.
var _selectedCampIds = new Set();

// 다운로드 쿨다운 가드 — 단시간 다중 클릭 방지
var _exportInProgress = false;
var _lastExportAt = 0;
var EXPORT_COOLDOWN_MS = 5000;

function _checkExportAllowed() {
  if (_exportInProgress) {
    toast('다운로드가 진행 중입니다. 잠시 기다려주세요.', 'warn');
    return false;
  }
  var now = Date.now();
  var elapsed = now - _lastExportAt;
  if (elapsed < EXPORT_COOLDOWN_MS) {
    var wait = Math.ceil((EXPORT_COOLDOWN_MS - elapsed) / 1000);
    toast(wait + '초 후 다시 시도해주세요', 'warn');
    return false;
  }
  return true;
}

function _markExportStart() { _exportInProgress = true; }
function _markExportEnd() { _exportInProgress = false; _lastExportAt = Date.now(); }

function toggleCampSelect(campId, checked) {
  if (checked) _selectedCampIds.add(campId);
  else _selectedCampIds.delete(campId);
  updateCampSelectionUI();
}

function toggleCampSelectAll(checked) {
  // 필터 결과 전체 — getCurrentFilteredCamps() 반환을 우선, 없으면 캠페인 전체 캐시
  var filtered = (typeof getCurrentFilteredCamps === 'function') ? getCurrentFilteredCamps() : null;
  if (!filtered) filtered = (Array.isArray(allCampaigns) ? allCampaigns : []);
  if (checked) {
    filtered.forEach(function(c) { _selectedCampIds.add(c.id); });
  } else {
    filtered.forEach(function(c) { _selectedCampIds.delete(c.id); });
  }
  // DOM 행의 체크박스도 동기 (현재 렌더된 행만)
  document.querySelectorAll('.camp-select-cb').forEach(function(cb) {
    var id = cb.dataset.campId;
    cb.checked = _selectedCampIds.has(id);
  });
  updateCampSelectionUI();
}

function clearCampSelection() {
  _selectedCampIds.clear();
  document.querySelectorAll('.camp-select-cb').forEach(function(cb) { cb.checked = false; });
  var sa = document.getElementById('campSelectAll');
  if (sa) { sa.checked = false; sa.indeterminate = false; }
  updateCampSelectionUI();
}

function updateCampSelectionUI() {
  var n = _selectedCampIds.size;
  var btnApp = document.getElementById('btnCampSelectApplicants');
  var btnDel = document.getElementById('btnCampSelectDeliverables');
  var btnClr = document.getElementById('btnCampSelectClear');
  var cntEl = document.getElementById('adminCampSelectedCount');
  if (btnApp) {
    btnApp.disabled = (n === 0);
    btnApp.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">download</span> ' + (n > 0 ? '선택 ' + n + '개 ' : '') + '신청자 엑셀';
  }
  if (btnDel) {
    btnDel.disabled = (n === 0);
    btnDel.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">download</span> ' + (n > 0 ? '선택 ' + n + '개 ' : '') + '결과물 엑셀';
  }
  if (btnClr) btnClr.style.display = n > 0 ? '' : 'none';
  if (cntEl) {
    if (n > 0) { cntEl.textContent = '· ' + n + '개 선택'; cntEl.style.display = ''; }
    else { cntEl.textContent = ''; cntEl.style.display = 'none'; }
  }
  // 전체 선택 체크박스 indeterminate
  var sa = document.getElementById('campSelectAll');
  if (sa) {
    var filtered = (typeof getCurrentFilteredCamps === 'function') ? getCurrentFilteredCamps() : null;
    if (!filtered) filtered = (Array.isArray(allCampaigns) ? allCampaigns : []);
    var total = filtered.length;
    var selectedInFiltered = filtered.filter(function(c) { return _selectedCampIds.has(c.id); }).length;
    sa.checked = (total > 0 && selectedInFiltered === total);
    sa.indeterminate = (selectedInFiltered > 0 && selectedInFiltered < total);
  }
}

// 시트1 헬퍼: 선택한 캠페인 N개 요약 행
//   appsByCampId: {campaignId: appsArray} — 시트2 export 시 이미 fetch한 결과 재사용 (round-trip 절약)
function _buildCampaignSummarySheet(wb, campaigns, appsByCampId) {
  var ws = wb.addWorksheet('캠페인 정보');
  ws.columns = [
    { header: '캠페인 번호',     key: 'no',       width: 18 },
    { header: '제목',            key: 'title',    width: 36 },
    { header: '브랜드',          key: 'brand',    width: 18 },
    { header: '제품',            key: 'product',  width: 22 },
    { header: '모집 타입',       key: 'rtype',    width: 10 },
    { header: '상태',            key: 'status',   width: 10 },
    { header: '모집 시작',       key: 'rstart',   width: 14 },
    { header: '모집 마감',       key: 'deadline', width: 14 },
    // 2026-05-15 추가: 운영자가 캠페인 일정 한 번에 보기용 기간 3종.
    //   monitor 캠페인은 purchase_start/end, visit 캠페인은 visit_start/end 를 같은 컬럼에 매핑.
    //   gifting 캠페인은 구매·방문 개념이 없어 빈칸.
    //   2026-05-18: 게시 마감/노출 마감 컬럼 제거 (post_deadline 폐기 — migration 129)
    { header: '구매기간 시작',   key: 'pstart',   width: 14 },
    { header: '구매기간 마감',   key: 'pend',     width: 14 },
    { header: '결과물 제출 마감',key: 'subend',   width: 16 },
    { header: '슬롯',            key: 'slots',    width: 8 },
    { header: '신청 수',         key: 'apps',     width: 10 },
    { header: '승인 수',         key: 'approved', width: 10 }
  ];
  var header = ws.getRow(1);
  header.font = { bold: true, color: { argb: 'FF222222' } };
  header.alignment = { vertical: 'middle', horizontal: 'center' };
  header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
  header.height = 22;
  var rtypeLabel = function(t) { return t === 'monitor' ? '리뷰어' : t === 'gifting' ? '기프팅' : t === 'visit' ? '방문형' : (t || ''); };
  var statusKo = function(s) { return s === 'draft' ? '준비' : s === 'scheduled' ? '모집예정' : s === 'active' ? '모집중' : s === 'closed' ? '종료' : s === 'expired' ? '노출마감' : (s || ''); };
  // 캠페인 종류별 구매·방문 기간 매핑 (monitor=purchase_*, visit=visit_*, gifting=빈칸)
  var pickPurchStart = function(c) {
    if (c.recruit_type === 'monitor') return c.purchase_start || '';
    if (c.recruit_type === 'visit')   return c.visit_start || '';
    return '';
  };
  var pickPurchEnd = function(c) {
    if (c.recruit_type === 'monitor') return c.purchase_end || '';
    if (c.recruit_type === 'visit')   return c.visit_end || '';
    return '';
  };
  campaigns.forEach(function(c) {
    var campApps = (appsByCampId && appsByCampId[c.id]) || [];
    var approvedCnt = campApps.filter(function(a){ return a.status === 'approved'; }).length;
    var ps = pickPurchStart(c);
    var pe = pickPurchEnd(c);
    ws.addRow({
      no:       c.campaign_no || '',
      title:    c.title || '',
      brand:    c.brand_ko || c.brand || '',
      product:  c.product_ko || c.product || '',
      rtype:    rtypeLabel(c.recruit_type),
      status:   statusKo(c.status),
      rstart:   c.recruit_start ? formatDate(c.recruit_start) : '',
      deadline: c.deadline ? formatDate(c.deadline) : '',
      pstart:   ps ? formatDate(ps) : '',
      pend:     pe ? formatDate(pe) : '',
      subend:   c.submission_end ? formatDate(c.submission_end) : '',
      slots:    Number(c.slots || 0),
      apps:     campApps.length,
      approved: approvedCnt
    });
  });
  return ws;
}

// 50개 이상 경고 모달
function _confirmLargeExport(n) {
  if (n < 50) return Promise.resolve(true);
  return new Promise(function(resolve) {
    var ok = confirm(n + '개 캠페인 선택했습니다.\n엑셀 생성에 수십 초~수 분 걸릴 수 있습니다.\n\n계속할까요?');
    resolve(!!ok);
  });
}

// 캠페인 다중 선택 신청자 엑셀 — 시트1 캠페인 정보 + 시트2 통합 신청자 리스트
//   idsOverride: 인자로 직접 ids 배열 받기 가능 (단일 캠페인 더보기 메뉴 호출용)
async function exportSelectedCampaignsApplicants(idsOverride) {
  if (!_checkExportAllowed()) return;
  var ids = (Array.isArray(idsOverride) && idsOverride.length > 0) ? idsOverride : Array.from(_selectedCampIds);
  if (ids.length === 0) { toast('캠페인을 1개 이상 선택하세요', 'warn'); return; }
  if (!(await _confirmLargeExport(ids.length))) return;

  _markExportStart();
  try {
    toast('엑셀 생성 중...');
    await loadExcelJS();
    var camps = (Array.isArray(allCampaigns) ? allCampaigns : []).filter(function(c){ return ids.indexOf(c.id) !== -1; });
    if (camps.length === 0) { toast('선택한 캠페인을 찾을 수 없습니다', 'error'); return; }
    // 모든 캠페인의 신청자 + 인플루언서 한 번에 fetch
    await ensureCancelReasonsCache();
    var users = await fetchInfluencers();
    var userByEmail = {};
    (users || []).forEach(function(u){ if (u.email) userByEmail[u.email] = u; });
    // 신청자: 캠페인별로 fetch (서버 round-trip) — appsByCampId 캐시도 동시 빌드
    var allCampApps = [];
    var appsByCampId = {};
    for (var i = 0; i < camps.length; i++) {
      var c = camps[i];
      var apps = await fetchApplications({ campaign_id: c.id });
      appsByCampId[c.id] = apps || [];
      (apps || []).forEach(function(a){ a._campMeta = c; allCampApps.push(a); });
    }

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    _buildCampaignSummarySheet(wb, camps, appsByCampId);

    var ws = wb.addWorksheet('신청자');
    ws.columns = [
      { header: '캠페인 번호',   key: 'campNo',     width: 16 },
      { header: '캠페인 제목',   key: 'campTitle',  width: 28 },
      { header: '신청일',        key: 'created',    width: 20 },
      { header: '상태',          key: 'status',     width: 10 },
      { header: '이름(한자)',    key: 'nameKanji',  width: 16 },
      { header: '이름(가나)',    key: 'nameKana',   width: 16 },
      { header: '이메일',        key: 'email',      width: 26 },
      { header: '연락처',        key: 'phone',      width: 16 },
      { header: 'Instagram URL', key: 'ig',         width: 36 },
      { header: 'Instagram 팔로워', key: 'igF',     width: 14 },
      { header: 'TikTok URL',    key: 'tt',         width: 36 },
      { header: 'TikTok 팔로워', key: 'ttF',        width: 14 },
      { header: 'X URL',         key: 'x',          width: 36 },
      { header: 'X 팔로워',      key: 'xF',         width: 14 },
      { header: 'YouTube URL',   key: 'yt',         width: 36 },
      { header: 'YouTube 팔로워',key: 'ytF',        width: 14 },
      { header: '우편번호',      key: 'zip',        width: 10 },
      { header: '배송지',        key: 'address',    width: 36 },
      { header: '신청 메시지',   key: 'message',    width: 32 },
      { header: '심사일',        key: 'reviewedAt', width: 20 },
      { header: '리뷰어',        key: 'reviewedBy', width: 14 },
      { header: '취소일',        key: 'cancelledAt',width: 20 },
      { header: '취소 사유',     key: 'cancelReason',width: 24 },
      { header: '취소 카테고리', key: 'cancelCategory', width: 18 },
      { header: '취소 시점',     key: 'cancelPhase', width: 12 }
    ];
    var hdr = ws.getRow(1);
    hdr.font = { bold: true, color: { argb: 'FF222222' } };
    hdr.alignment = { vertical: 'middle', horizontal: 'center' };
    hdr.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    hdr.height = 22;

    var statusKo = function(s) { return s === 'approved' ? '승인' : s === 'pending' ? '심사중' : s === 'rejected' ? '미승인' : s === 'cancelled' ? '취소' : (s || ''); };
    var fmtKR = function(iso) { if (!iso) return ''; try { return new Date(iso).toLocaleString('ko-KR', {timeZone:'Asia/Seoul'}); } catch(e) { return String(iso); } };

    allCampApps.forEach(function(a) {
      var u = userByEmail[a.user_email] || {};
      var c = a._campMeta || {};
      var nm = _excelInfluencerNameParts(u);
      ws.addRow({
        campNo:        c.campaign_no || '',
        campTitle:     c.title || '',
        created:       fmtKR(a.created_at),
        status:        statusKo(a.status),
        nameKanji:     nm.kanji || a.user_name || '',
        nameKana:      nm.kana || '',
        email:         a.user_email || '',
        phone:         formatPhoneDisplay(u.phone),
        ig:            _excelSnsUrl('instagram', u.ig || a.ig_id || a.user_ig),
        igF:           Number(u.ig_followers || 0),
        tt:            _excelSnsUrl('tiktok', u.tiktok),
        ttF:           Number(u.tiktok_followers || 0),
        x:             _excelSnsUrl('x', u.x),
        xF:            Number(u.x_followers || 0),
        yt:            _excelSnsUrl('youtube', u.youtube),
        ytF:           Number(u.youtube_followers || 0),
        zip:           _excelZip(u),
        address:       _excelAddressOnly(u, a.address),
        message:       a.message || '',
        reviewedAt:    fmtKR(a.reviewed_at),
        reviewedBy:    formatReviewer(a.reviewed_by),
        cancelledAt:   fmtKR(a.cancelled_at),
        cancelReason:  a.cancel_reason || '',
        cancelCategory:a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : '',
        cancelPhase:   a.cancel_phase ? cancelPhaseLabelKo(a.cancel_phase) : ''
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
    var aEl = document.createElement('a');
    aEl.href = url;
    var ts = new Date();
    var ymd = ts.getFullYear() + String(ts.getMonth()+1).padStart(2,'0') + String(ts.getDate()).padStart(2,'0');
    aEl.download = 'applicants-' + camps.length + 'campaigns-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + camps.length + '개 캠페인, ' + allCampApps.length + '건 신청)');
  } catch (e) {
    console.error('[exportSelectedCampaignsApplicants]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}

// 캠페인 다중 선택 결과물 엑셀 — 시트1 캠페인 정보 + 시트2 통합 결과물 리스트 (이미지 임베드 생략, URL만)
//   idsOverride: 인자로 직접 ids 배열 받기 가능 (단일 캠페인 더보기 메뉴 호출용)
async function exportSelectedCampaignsDeliverables(idsOverride) {
  if (!_checkExportAllowed()) return;
  var ids = (Array.isArray(idsOverride) && idsOverride.length > 0) ? idsOverride : Array.from(_selectedCampIds);
  if (ids.length === 0) { toast('캠페인을 1개 이상 선택하세요', 'warn'); return; }
  if (!(await _confirmLargeExport(ids.length))) return;

  _markExportStart();
  try {
    toast('엑셀 생성 중...');
    await loadExcelJS();
    var camps = (Array.isArray(allCampaigns) ? allCampaigns : []).filter(function(c){ return ids.indexOf(c.id) !== -1; });
    if (camps.length === 0) { toast('선택한 캠페인을 찾을 수 없습니다', 'error'); return; }

    var users = await fetchInfluencers();
    // 시트1 캠페인 요약 「신청 수」 컬럼을 채우기 위해 신청 전체 fetch 1회 + groupBy
    var allAppsForSummary = await fetchApplications();
    var appsByCampId = {};
    (allAppsForSummary || []).forEach(function(a){
      if (!appsByCampId[a.campaign_id]) appsByCampId[a.campaign_id] = [];
      appsByCampId[a.campaign_id].push(a);
    });
    // 결과물 fetch (전체 상태) + 이미지 다운로드
    var allDelivs = [];
    for (var i = 0; i < camps.length; i++) {
      var c = camps[i];
      var dels = await fetchDeliverables({ campaign_id: c.id });
      (dels || []).forEach(function(d){ d._campMeta = c; allDelivs.push(d); });
    }
    if (allDelivs.length === 0) { toast('결과물이 없습니다', 'warn'); return; }

    // 인플루언서 id 매핑 (단일 함수와 동일 패턴)
    var usersById = {};
    (users || []).forEach(function(u){ if (u && u.id) usersById[u.id] = u; });

    // 영수증·리뷰 이미지 Image→Canvas→JPEG 재인코딩 (CORS·포맷 호환성)
    var imgBuffers = {};
    await Promise.all(allDelivs.filter(function(d){
      return (d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url;
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
      } catch(e) { console.warn('[excel] receipt fetch failed', d.id, e); }
    }));

    // application_id 단위 그룹핑 (캠페인 정보 보존). 동일 신청 receipt + result 한 행에 펼침
    var groups = {};
    allDelivs.forEach(function(d) {
      var ck = (d._campMeta && d._campMeta.id) || '';
      var key = ck + '|' + (d.application_id || ('user-' + d.user_id));
      if (!groups[key]) {
        groups[key] = { key: key, camp: d._campMeta || {}, application_id: d.application_id, user_id: d.user_id, receipt: null, result: null };
      }
      var g = groups[key];
      if (d.kind === 'receipt') {
        if (!g.receipt || (d.updated_at || '') > (g.receipt.updated_at || '')) g.receipt = d;
      } else if (d.kind === 'review_image' || d.kind === 'post') {
        if (!g.result || (d.updated_at || '') > (g.result.updated_at || '')) g.result = d;
      }
    });
    var groupList = Object.values(groups);
    // 정렬: 캠페인 번호 → 인플루언서 한자 이름
    groupList.sort(function(a, b) {
      var ca = (a.camp.campaign_no || '').toString();
      var cb = (b.camp.campaign_no || '').toString();
      if (ca !== cb) return ca.localeCompare(cb, 'ja');
      var ua = usersById[a.user_id] || {};
      var ub = usersById[b.user_id] || {};
      var na = (ua.name_kanji || ua.name || '').toString();
      var nb = (ub.name_kanji || ub.name || '').toString();
      return na.localeCompare(nb, 'ja');
    });

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();

    // 시트1 캠페인 정보 (기존 유지)
    _buildCampaignSummarySheet(wb, camps, appsByCampId);

    // 시트2 결과물 — 24컬럼 (캠페인 2 + 인플루언서 7 + 영수증 9 + 결과물 6)
    // 영수증 9컬럼: 타입 / 제출일 / 검수일 / 상태 / 주문번호 / 구매일 / 구매금액 / 이미지 / URL (마이그레이션 128)
    var ws = wb.addWorksheet('결과물');

    // 머리글 (A1:X1, A2:X2)
    ws.mergeCells('A1:X1');
    var tCell = ws.getCell('A1');
    tCell.value = '선택한 ' + camps.length + '개 캠페인 결과물 통합';
    tCell.font = {bold: true, size: 14};
    tCell.alignment = {vertical: 'middle'};
    ws.getRow(1).height = 26;

    ws.mergeCells('A2:X2');
    var mCell = ws.getCell('A2');
    mCell.value = '캠페인 수: ' + camps.length + '개'
      + '  ·  신청 건수: ' + groupList.length + '건'
      + '  ·  결과물 합계: ' + allDelivs.length + '건'
      + '  ·  생성일: ' + new Date().toLocaleString('ko-KR');
    mCell.font = {color: {argb: 'FF888888'}, size: 11};
    ws.getRow(2).height = 20;

    // 그룹 헤더 (3행)
    ws.mergeCells('A3:B3'); ws.getCell('A3').value = '캠페인';
    ws.mergeCells('C3:I3'); ws.getCell('C3').value = '인플루언서 정보';
    ws.mergeCells('J3:R3'); ws.getCell('J3').value = '영수증';
    ws.mergeCells('S3:X3'); ws.getCell('S3').value = '결과물';
    ['A3','C3','J3','S3'].forEach(function(addr) {
      var c2 = ws.getCell(addr);
      c2.font = {bold: true, color: {argb: 'FF222222'}};
      c2.alignment = {vertical: 'middle', horizontal: 'center'};
      c2.fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFE8E8E8'}};
    });
    ws.getRow(3).height = 22;

    // 컬럼 헤더 (4행)
    ws.getRow(4).values = [
      '캠페인 번호', '캠페인 제목',
      '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
      '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL',
      '타입', '제출일', '검수일', '상태', '이미지', 'URL'
    ];
    ws.getRow(4).font = {bold: true, color: {argb: 'FF222222'}};
    ws.getRow(4).fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFF0F0F0'}};
    ws.getRow(4).alignment = {vertical: 'middle', horizontal: 'center'};
    ws.getRow(4).height = 24;

    // 컬럼 너비
    ws.columns = [
      {width: 18}, {width: 28},
      {width: 18}, {width: 18}, {width: 28}, {width: 36}, {width: 36}, {width: 36}, {width: 36},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 18}, {width: 12}, {width: 12}, {width: 16}, {width: 32},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 16}, {width: 32}
    ];

    // 결과물 1건 → 6컬럼 값 (post / review_image)
    var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려', changed:'재제출요청'};
    var renderDeliverableCells = function(d) {
      if (!d) return ['', '', '', '', '', ''];
      var kindLabel = d.kind === 'receipt' ? '영수증'
        : d.kind === 'review_image' ? '리뷰 이미지'
        : '게시물';
      var submittedStr = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
      var reviewedStr = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
      var statusStr = statusLabelMap[d.status] || d.status || '';
      var urlCellValue = '';
      if (d.kind === 'post') {
        var postUrl = d.post_url || '';
        if (Array.isArray(d.post_submissions) && d.post_submissions.length) {
          var last = d.post_submissions[d.post_submissions.length - 1];
          postUrl = (last && last.url) || postUrl;
        }
        if (postUrl) urlCellValue = {text: postUrl, hyperlink: postUrl};
      } else if ((d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url) {
        var imgUrl = /^https?:\/\//.test(d.receipt_url)
          ? d.receipt_url
          : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
        var linkText = d.kind === 'receipt' ? '영수증 보기' : '리뷰 이미지 보기';
        urlCellValue = {text: linkText, hyperlink: imgUrl};
      }
      return [kindLabel, submittedStr, reviewedStr, statusStr, '', urlCellValue];
    };

    // 영수증(receipt) 전용 9컬럼 — 기본 4 + 주문번호·구매일·구매금액 + 이미지·URL (마이그레이션 128)
    var renderReceiptCells9 = function(d) {
      if (!d) return ['', '', '', '', '', '', '', '', ''];
      var base = renderDeliverableCells(d);  // [type, submitted, reviewed, status, '', url]
      var orderNo = d.order_number || '';
      var purchaseDate = d.purchase_date || '';
      var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
        ? '' : Number(d.purchase_amount);
      // 결과: [type, submitted, reviewed, status, order_no, purchase_date, purchase_amount, image, url]
      return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
    };

    // 본문 행 — 그룹 1개 = 1행
    groupList.forEach(function(g, idx) {
      var rowNum = 5 + idx;
      var u = usersById[g.user_id] || {};
      var cc = g.camp || {};
      var row = ws.getRow(rowNum);
      row.height = 84;
      var receiptCells = renderReceiptCells9(g.receipt);
      var resultCells = renderDeliverableCells(g.result);
      row.values = [
        cc.campaign_no || '', cc.title || '',
        u.name_kanji || u.name || '—',
        u.name_kana || '',
        u.email || '',
        _excelSnsUrl('instagram', u.ig),
        _excelSnsUrl('tiktok', u.tiktok),
        _excelSnsUrl('x', u.x),
        _excelSnsUrl('youtube', u.youtube),
        receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8],
        resultCells[0], resultCells[1], resultCells[2], resultCells[3], resultCells[4], resultCells[5]
      ];
      row.alignment = {vertical: 'middle', wrapText: true};
      // 하이퍼링크 색상 (R열=18 영수증 URL, X열=24 결과물 URL)
      [18, 24].forEach(function(colNum) {
        var cell = row.getCell(colNum);
        if (cell && cell.value && cell.value.hyperlink) {
          cell.font = {color: {argb: 'FFE8344E'}, underline: true};
        }
      });
      // 이미지 임베드 (Q열=17 영수증, W열=23 결과물)
      if (g.receipt && imgBuffers[g.receipt.id]) {
        var rImgId = wb.addImage({buffer: imgBuffers[g.receipt.id].buffer, extension: imgBuffers[g.receipt.id].ext});
        ws.addImage(rImgId, 'Q' + rowNum + ':Q' + rowNum);
      }
      if (g.result && g.result.kind === 'review_image' && imgBuffers[g.result.id]) {
        var sImgId = wb.addImage({buffer: imgBuffers[g.result.id].buffer, extension: imgBuffers[g.result.id].ext});
        ws.addImage(sImgId, 'W' + rowNum + ':W' + rowNum);
      }
    });

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var aEl = document.createElement('a');
    aEl.href = url;
    var ts = new Date();
    var ymd = ts.getFullYear() + String(ts.getMonth()+1).padStart(2,'0') + String(ts.getDate()).padStart(2,'0');
    var fnTag = camps.length === 1
      ? ((camps[0].campaign_no || camps[0].title || 'campaign').replace(/[\\\/:*?"<>|]/g, '_').substring(0, 40))
      : (camps.length + 'campaigns');
    aEl.download = 'deliverables-' + fnTag + '-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + camps.length + '개 캠페인, ' + groupList.length + '건 신청, ' + allDelivs.length + '건 결과물)');
  } catch (e) {
    console.error('[exportSelectedCampaignsDeliverables]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}

// 캠페인별 신청자 목록 엑셀 다운로드 (전체 상태, 4채널 SNS+팔로워 포함)
async function exportCampaignApplicationsExcel(campId) {
  if (!_checkExportAllowed()) return;
  _markExportStart();
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
      if (s === 'cancelled') return '취소';
      return s || '';
    };
    // 취소 카테고리 라벨 캐시 (cancelled 행 있으면 미리 채움)
    await ensureCancelReasonsCache();
    // 인라인 헬퍼 폐기 — _excelInfluencerNameParts / _excelSnsUrl / _excelZip / _excelAddressOnly 공용 헬퍼 사용

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var sheetName = (camp.campaign_no || camp.title || '신청자').substring(0, 28);
    var ws = wb.addWorksheet(sheetName);

    ws.columns = [
      { header: '신청일',            key: 'created',    width: 20 },
      { header: '상태',              key: 'status',     width: 10 },
      { header: '이름(한자)',        key: 'nameKanji',  width: 16 },
      { header: '이름(가나)',        key: 'nameKana',   width: 16 },
      { header: '이메일',            key: 'email',      width: 26 },
      { header: '연락처',            key: 'phone',      width: 16 },
      { header: 'Instagram URL',     key: 'ig',         width: 36 },
      { header: 'Instagram 팔로워', key: 'igF',        width: 14 },
      { header: 'TikTok URL',        key: 'tt',         width: 36 },
      { header: 'TikTok 팔로워',    key: 'ttF',        width: 14 },
      { header: 'X URL',             key: 'x',          width: 36 },
      { header: 'X 팔로워',          key: 'xF',         width: 14 },
      { header: 'YouTube URL',       key: 'yt',         width: 36 },
      { header: 'YouTube 팔로워',    key: 'ytF',        width: 14 },
      { header: '우편번호',          key: 'zip',        width: 10 },
      { header: '배송지',            key: 'address',    width: 40 },
      { header: '신청 메시지',       key: 'message',    width: 40 },
      { header: '심사일',            key: 'reviewedAt', width: 20 },
      { header: '리뷰어',            key: 'reviewedBy', width: 16 },
      { header: '취소일',            key: 'cancelledAt',    width: 20 },
      { header: '취소 사유(보충)',   key: 'cancelReason',   width: 30 },
      { header: '취소 카테고리',     key: 'cancelCategory', width: 22 },
      { header: '취소 시점',         key: 'cancelPhase',    width: 14 }
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
      var cancelledStr = '';
      if (a.cancelled_at) {
        try { cancelledStr = new Date(a.cancelled_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { cancelledStr = String(a.cancelled_at); }
      }
      var nmS = _excelInfluencerNameParts(u);
      ws.addRow({
        created:        createdStr,
        status:         statusLabel(a.status),
        nameKanji:      nmS.kanji || a.user_name || '',
        nameKana:       nmS.kana || '',
        email:          a.user_email || '',
        phone:          formatPhoneDisplay(u.phone),
        ig:             _excelSnsUrl('instagram', u.ig || a.ig_id || a.user_ig),
        igF:            Number(u.ig_followers || 0),
        tt:             _excelSnsUrl('tiktok', u.tiktok),
        ttF:            Number(u.tiktok_followers || 0),
        x:              _excelSnsUrl('x', u.x),
        xF:             Number(u.x_followers || 0),
        yt:             _excelSnsUrl('youtube', u.youtube),
        ytF:            Number(u.youtube_followers || 0),
        zip:            _excelZip(u),
        address:        _excelAddressOnly(u, a.address),
        message:        a.message || '',
        reviewedAt:     reviewedStr,
        reviewedBy:     formatReviewer(a.reviewed_by),
        cancelledAt:    cancelledStr,
        cancelReason:   a.cancel_reason || '',
        cancelCategory: a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : '',
        cancelPhase:    a.cancel_phase ? cancelPhaseLabelKo(a.cancel_phase) : ''
      });
    });

    ['igF','ttF','xF','ytF'].forEach(function(k) {
      ws.getColumn(k).numFmt = '#,##0';
      ws.getColumn(k).alignment = { horizontal: 'right' };
    });
    ws.getColumn('message').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('address').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('cancelReason').alignment = { wrapText: true, vertical: 'top' };

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
  } finally {
    _markExportEnd();
  }
}


async function exportCampaignDeliverables(campId) {
  if (!_checkExportAllowed()) return;
  _markExportStart();
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

    // 3) 인플루언서 전체 조회 (SNS 핸들·한자 이름은 fetchDeliverables의 인플루언서 매핑에 포함되지 않음)
    var users = await fetchInfluencers();
    var userById = {};
    (users || []).forEach(function(u){ if (u && u.id) userById[u.id] = u; });

    // 4) 영수증·리뷰 이미지 Image→Canvas로 jpeg 재인코딩 (CORS·포맷 호환성 보장)
    //    receipt(영수증) + review_image(monitor 2단계 리뷰 캡처) 모두 receipt_url 컬럼을 재사용
    var imgBuffers = {};
    await Promise.all(delivs.filter(function(d){
      return (d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url;
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

    // 5) application_id 단위로 그룹핑 — 한 신청 = 한 행 (영수증 + 결과물 6컬럼씩 펼침)
    //    receipt: kind='receipt' / result: kind='review_image' 또는 'post' 중 최신
    var groups = {};
    delivs.forEach(function(d) {
      var key = d.application_id || ('user-' + d.user_id);  // application_id 없으면 user_id 폴백
      if (!groups[key]) {
        groups[key] = {key: key, application_id: d.application_id, user_id: d.user_id, receipt: null, result: null};
      }
      var g = groups[key];
      if (d.kind === 'receipt') {
        // 동일 application에 receipt 여러 건이면 최신(updated_at 기준) 우선
        if (!g.receipt || (d.updated_at || '') > (g.receipt.updated_at || '')) g.receipt = d;
      } else if (d.kind === 'review_image' || d.kind === 'post') {
        if (!g.result || (d.updated_at || '') > (g.result.updated_at || '')) g.result = d;
      }
    });
    var groupList = Object.values(groups);
    // 인플루언서 이름순 정렬 (한자 우선)
    groupList.sort(function(a, b) {
      var ua = userById[a.user_id] || {};
      var ub = userById[b.user_id] || {};
      var na = (ua.name_kanji || ua.name || '').toString();
      var nb = (ub.name_kanji || ub.name || '').toString();
      return na.localeCompare(nb, 'ja');
    });

    // 6) 워크북 생성
    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var ws = wb.addWorksheet('결과물');

    // 헤더 (A1:V1, A2:V2) — 총 22열 (영수증 6→9 확장, 마이그레이션 128)
    ws.mergeCells('A1:V1');
    var t = ws.getCell('A1');
    t.value = (camp.campaign_no ? camp.campaign_no + '  ' : '') + (camp.title || '');
    t.font = {bold: true, size: 14};
    t.alignment = {vertical: 'middle'};
    ws.getRow(1).height = 26;

    ws.mergeCells('A2:V2');
    var m = ws.getCell('A2');
    m.value = '브랜드: ' + (camp.brand || '—')
      + '  ·  신청 건수: ' + groupList.length + '건'
      + '  ·  결과물 합계: ' + delivs.length + '건'
      + '  ·  생성일: ' + new Date().toLocaleString('ko-KR');
    m.font = {color: {argb: 'FF888888'}, size: 11};
    ws.getRow(2).height = 20;

    // 그룹 헤더 (3행) — 인플루언서 7컬럼 / 영수증 9컬럼 / 결과물 6컬럼 (마이그레이션 128로 영수증 6→9 확장)
    ws.mergeCells('A3:G3'); ws.getCell('A3').value = '인플루언서 정보';
    ws.mergeCells('H3:P3'); ws.getCell('H3').value = '영수증';
    ws.mergeCells('Q3:V3'); ws.getCell('Q3').value = '결과물';
    ['A3','H3','Q3'].forEach(function(addr) {
      var c = ws.getCell(addr);
      c.font = {bold: true, color: {argb: 'FF222222'}};
      c.alignment = {vertical: 'middle', horizontal: 'center'};
      c.fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFE8E8E8'}};
    });
    ws.getRow(3).height = 22;

    // 컬럼 헤더 (4행)
    // 영수증 9컬럼: 타입 / 제출일 / 검수일 / 상태 / 주문번호 / 구매일 / 구매금액 / 이미지 / URL
    ws.getRow(4).values = [
      '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
      '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL',
      '타입', '제출일', '검수일', '상태', '이미지', 'URL'
    ];
    ws.getRow(4).font = {bold: true, color: {argb: 'FF222222'}};
    ws.getRow(4).fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFF0F0F0'}};
    ws.getRow(4).alignment = {vertical: 'middle', horizontal: 'center'};
    ws.getRow(4).height = 24;

    // 컬럼 너비 (이름 18·이메일 28·SNS URL 36, 영수증 9컬럼·결과물 6컬럼)
    ws.columns = [
      {width: 18}, {width: 18}, {width: 28}, {width: 36}, {width: 36}, {width: 36}, {width: 36},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 18}, {width: 12}, {width: 12}, {width: 16}, {width: 32},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 16}, {width: 32}
    ];

    // SNS URL 변환은 공용 _excelSnsUrl 헬퍼 사용 (handle → 전체 URL)
    // 헬퍼: 결과물 1건의 6컬럼 값 계산 — 타입/제출일/검수일/상태/이미지(빈 셀, 임베드는 별도)/URL
    var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려'};
    var renderDeliverableCells = function(d) {
      if (!d) return ['', '', '', '', '', ''];
      var kindLabel = d.kind === 'receipt' ? '영수증'
        : d.kind === 'review_image' ? '리뷰 이미지'
        : '게시물';
      var submittedStr = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
      var reviewedStr = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
      var statusStr = statusLabelMap[d.status] || d.status || '';
      // URL 셀: post는 게시물 URL, receipt/review_image는 receipt_url 기반 하이퍼링크
      var urlCellValue = '';
      if (d.kind === 'post') {
        var postUrl = d.post_url || '';
        if (Array.isArray(d.post_submissions) && d.post_submissions.length) {
          var last = d.post_submissions[d.post_submissions.length - 1];
          postUrl = (last && last.url) || postUrl;
        }
        if (postUrl) urlCellValue = {text: postUrl, hyperlink: postUrl};
      } else if ((d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url) {
        var imgUrl = /^https?:\/\//.test(d.receipt_url)
          ? d.receipt_url
          : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
        var linkText = d.kind === 'receipt' ? '영수증 보기' : '리뷰 이미지 보기';
        urlCellValue = {text: linkText, hyperlink: imgUrl};
      }
      return [kindLabel, submittedStr, reviewedStr, statusStr, '', urlCellValue];
    };

    // 영수증(receipt) 전용 9컬럼 (마이그레이션 128) — 기본 4 + 주문번호·구매일·구매금액 + 이미지·URL
    var renderReceiptCells9 = function(d) {
      if (!d) return ['', '', '', '', '', '', '', '', ''];
      var base = renderDeliverableCells(d);  // [type, submitted, reviewed, status, '', url]
      var orderNo = d.order_number || '';
      var purchaseDate = d.purchase_date || '';
      var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
        ? '' : Number(d.purchase_amount);
      return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
    };

    // 본문 행 — 그룹 1개 = 1행
    groupList.forEach(function(g, i) {
      var rowNum = 5 + i;
      var u = userById[g.user_id] || {};
      var row = ws.getRow(rowNum);
      row.height = 84;

      var receiptCells = renderReceiptCells9(g.receipt);
      var resultCells = renderDeliverableCells(g.result);

      row.values = [
        // 인플루언서 정보 7컬럼
        u.name_kanji || u.name || '—',
        u.name_kana || '',
        u.email || '',
        _excelSnsUrl('instagram', u.ig),
        _excelSnsUrl('tiktok', u.tiktok),
        _excelSnsUrl('x', u.x),
        _excelSnsUrl('youtube', u.youtube),
        // 영수증 9컬럼
        receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8],
        // 결과물 6컬럼
        resultCells[0], resultCells[1], resultCells[2], resultCells[3], resultCells[4], resultCells[5]
      ];
      row.alignment = {vertical: 'middle', wrapText: true};

      // 하이퍼링크 셀 스타일 (P열=16 영수증 URL, V열=22 결과물 URL)
      [16, 22].forEach(function(colNum) {
        var c = row.getCell(colNum);
        if (c && c.value && c.value.hyperlink) {
          c.font = {color: {argb: 'FFE8344E'}, underline: true};
        }
      });

      // 영수증 이미지 임베드 (O열=15)
      if (g.receipt && imgBuffers[g.receipt.id]) {
        var rImgId = wb.addImage({buffer: imgBuffers[g.receipt.id].buffer, extension: imgBuffers[g.receipt.id].ext});
        ws.addImage(rImgId, 'O' + rowNum + ':O' + rowNum);
      }
      // 결과물 이미지 임베드 (review_image, U열=21). post는 이미지 없음.
      if (g.result && g.result.kind === 'review_image' && imgBuffers[g.result.id]) {
        var dImgId = wb.addImage({buffer: imgBuffers[g.result.id].buffer, extension: imgBuffers[g.result.id].ext});
        ws.addImage(dImgId, 'U' + rowNum + ':U' + rowNum);
      }
    });

    // 7) 파일 저장
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

    toast('엑셀 다운로드 완료 (' + groupList.length + '건)');
  } catch(e) {
    console.error('[exportCampaignDeliverables]', e);
    toast('엑셀 생성 실패: ' + (e.message || String(e)), 'error');
  }
}



// ── 캠페인 폼 brand 드롭다운 + 신청 cascade ──
var _campBrandsCache = null;
var _campAppsCache = {};  // brandId → applications[]

// ════════════════════════════════════════════════════════════════════
// SECTION: CAMPAIGNS · FORM — brand 외래 키 셀렉트 + 소스 신청 cascade
//   admin-brand.js(브랜드 마스터) 와 분리되어 캠페인 폼에서만 사용
// ════════════════════════════════════════════════════════════════════

async function loadCampBrandSelect(prefix, currentBrandId) {
  var sel = $(prefix + 'CampBrandId');
  if (!sel) return;
  if (!_campBrandsCache) {
    _campBrandsCache = await fetchBrands({status: 'active'}) || [];
  }
  var current = currentBrandId || sel.value || '';
  var html = '<option value="">-- 브랜드 선택 --</option>';
  for (var i = 0; i < _campBrandsCache.length; i++) {
    var b = _campBrandsCache[i];
    var label = esc(b.name) + (b.brand_no ? ' [' + esc(b.brand_no) + ']' : '');
    html += '<option value="' + esc(b.id) + '"' + (current === b.id ? ' selected' : '') + '>' + label + '</option>';
  }
  sel.innerHTML = html;
}

async function onCampBrandChange(prefix) {
  var sel = $(prefix + 'CampBrandId');
  var hiddenName = $(prefix + 'CampBrand');
  var hiddenNameKo = $(prefix + 'CampBrandKo');
  var sourceSel = $(prefix + 'CampSourceAppId');
  var hint = $(prefix + 'CampBrandHint');
  if (!sel) return;
  var brandId = sel.value || '';
  // hidden brand 컬럼은 legacy 호환 — 선택한 brand의 name 자동 채움
  var picked = (_campBrandsCache || []).find(function(b){ return b.id === brandId; });
  if (hiddenName) hiddenName.value = picked ? (picked.name || '') : '';
  if (hiddenNameKo) hiddenNameKo.value = '';  // 086 이후 brands는 단일 name. 한국어 표기는 brand 마스터에서 관리
  // 신청 cascade
  if (sourceSel) {
    var sourceWrap = $(prefix + 'CampSourceAppContainer');
    if (!brandId) {
      if (sourceWrap) sourceWrap.style.display = 'none';
      sourceSel.innerHTML = '<option value="">선택 안 함 (외부 캠페인)</option>';
      sourceSel.value = '';
      _srcAppSyncTrigger(prefix);
    } else {
      if (sourceWrap) sourceWrap.style.display = '';
      await loadCampSourceAppSelect(prefix, brandId);
    }
  }
  if (hint) {
    if (!brandId) {
      hint.textContent = '브랜드를 먼저 선택해주세요.';
    } else {
      var seq = Number.isInteger(picked?.brand_seq) ? lpad(picked.brand_seq, 4) : '????';
      var fmt = (sourceSel && sourceSel.value)
        ? 'B' + seq + '-A###-C###'
        : 'B' + seq + '-C###';
      hint.innerHTML = '캠페인 번호: <code>' + esc(fmt) + '</code> 형식'
        + (sourceSel && sourceSel.value ? '' : ' (외부 캠페인)');
    }
  }
}

// 부모 신청 선택 — 커스텀 드롭다운 (제품명 큰 글씨 + 메타 작은 글씨 2줄)
// native <select>는 화면 밖으로 숨겨두고 옵션 클릭 시 select.value 갱신 + change 이벤트 발화 →
// 기존 호출처(sel.value, FormData, onchange 인라인)는 무손상 그대로 동작
async function loadCampSourceAppSelect(prefix, brandId, currentAppId) {
  var sel = $(prefix + 'CampSourceAppId');
  if (!sel) return;
  if (!_campAppsCache[brandId]) {
    _campAppsCache[brandId] = await fetchBrandApplicationsByBrand(brandId) || [];
  }
  var apps = _campAppsCache[brandId];
  var current = currentAppId || sel.value || '';
  // 1) 숨김 select 옵션 재구성 — 라벨은 단순 텍스트(검색·접근성 용)
  var optHtml = '<option value="">선택 안 함 (외부 캠페인)</option>';
  for (var i = 0; i < apps.length; i++) {
    var a = apps[i];
    var statusLabel = (typeof BRAND_APP_STATUS !== 'undefined' && BRAND_APP_STATUS[a.status] && BRAND_APP_STATUS[a.status].label) || a.status;
    var optLabel = (a.application_no || a.id.slice(0,8)) + ' · ' + (a.form_type === 'reviewer' ? '리뷰어' : '시딩') + ' · ' + statusLabel;
    optHtml += '<option value="' + esc(a.id) + '"' + (current === a.id ? ' selected' : '') + '>' + esc(optLabel) + '</option>';
  }
  sel.innerHTML = optHtml;
  sel.value = current;
  // 2) 커스텀 패널 옵션 카드 그리기
  var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
  if (panel) {
    var panelHtml = '<div class="custom-srcapp-option" data-srcapp-value="" role="option">'
      + '<div class="custom-srcapp-option-main is-empty">선택 안 함 (외부 캠페인)</div>'
      + '</div>';
    for (var j = 0; j < apps.length; j++) {
      var ap = apps[j];
      var st = (typeof BRAND_APP_STATUS !== 'undefined' && BRAND_APP_STATUS[ap.status] && BRAND_APP_STATUS[ap.status].label) || ap.status;
      panelHtml += '<div class="custom-srcapp-option' + (current === ap.id ? ' is-selected' : '') + '" data-srcapp-value="' + esc(ap.id) + '" role="option" aria-selected="' + (current === ap.id ? 'true' : 'false') + '">'
        + '<div class="custom-srcapp-option-main">' + _srcAppProductLabel(ap.products) + '</div>'
        + '<div class="custom-srcapp-option-meta">' + esc(_srcAppMetaLine(ap, st)) + '</div>'
        + '</div>';
    }
    panel.innerHTML = panelHtml;
  }
  // 3) 트리거 라벨 동기화
  _srcAppSyncTrigger(prefix);
}

// 제품명 라벨 — 첫 제품(name 또는 name_ja) + 외 N개 / 제품 없으면 안내
function _srcAppProductLabel(products) {
  var arr = Array.isArray(products) ? products : [];
  if (!arr.length) return '<span class="is-empty">(제품 정보 없음)</span>';
  var first = arr[0] || {};
  var name = first.name || first.name_ja || '';
  if (!name) return '<span class="is-empty">(제품명 미입력)</span>';
  var extra = arr.length > 1 ? '<span class="custom-srcapp-option-extra">외 ' + (arr.length - 1) + '개</span>' : '';
  return esc(name) + extra;
}

// 메타 라인 — 신청번호 · 폼타입 · 상태
function _srcAppMetaLine(a, statusLabel) {
  var no = a.application_no || (a.id ? a.id.slice(0,8) : '');
  var ft = a.form_type === 'reviewer' ? '리뷰어' : '시딩';
  return no + ' · ' + ft + ' · ' + statusLabel;
}

// 트리거 버튼 표시 갱신
function _srcAppSyncTrigger(prefix) {
  var sel = $(prefix + 'CampSourceAppId');
  var trigger = document.querySelector('[data-srcapp-trigger="' + prefix + '"]');
  if (!sel || !trigger) return;
  var mainEl = trigger.querySelector('[data-srcapp-trigger-main]');
  var existingMeta = trigger.querySelector('.custom-srcapp-trigger-meta');
  if (existingMeta) existingMeta.remove();
  var apps = _campAppsCache[ $(prefix + 'CampBrandId')?.value || '' ] || [];
  var picked = apps.find(function(x){ return x.id === sel.value; });
  if (!picked) {
    if (mainEl) { mainEl.className = 'custom-srcapp-trigger-main is-placeholder'; mainEl.textContent = '선택 안 함 (외부 캠페인)'; }
    return;
  }
  if (mainEl) {
    mainEl.className = 'custom-srcapp-trigger-main';
    mainEl.innerHTML = _srcAppProductLabel(picked.products);
  }
  var st = (typeof BRAND_APP_STATUS !== 'undefined' && BRAND_APP_STATUS[picked.status] && BRAND_APP_STATUS[picked.status].label) || picked.status;
  var metaEl = document.createElement('div');
  metaEl.className = 'custom-srcapp-trigger-meta';
  metaEl.textContent = _srcAppMetaLine(picked, st);
  trigger.appendChild(metaEl);
}

// 옵션 선택 — select.value 갱신 + change 이벤트 발화로 onchange 인라인 핸들러 트리거
function _srcAppPick(prefix, value) {
  var sel = $(prefix + 'CampSourceAppId');
  if (!sel) return;
  sel.value = value;
  sel.dispatchEvent(new Event('change', { bubbles: true }));
  // is-selected / aria-selected 재동기화 (접근성)
  var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
  if (panel) {
    panel.querySelectorAll('.custom-srcapp-option').forEach(function(o){
      var match = (o.getAttribute('data-srcapp-value') || '') === (value || '');
      o.classList.toggle('is-selected', match);
      o.setAttribute('aria-selected', match ? 'true' : 'false');
    });
  }
  _srcAppSyncTrigger(prefix);
  _srcAppClosePanel(prefix);
}

function _srcAppOpenPanel(prefix) {
  // 다른 prefix 패널 닫기
  document.querySelectorAll('.custom-srcapp-panel.is-open').forEach(function(p){
    if (p.getAttribute('data-srcapp-panel') !== prefix) p.classList.remove('is-open');
  });
  document.querySelectorAll('.custom-srcapp-trigger.is-open').forEach(function(t){
    if (t.getAttribute('data-srcapp-trigger') !== prefix) { t.classList.remove('is-open'); t.setAttribute('aria-expanded','false'); }
  });
  var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
  var trigger = document.querySelector('[data-srcapp-trigger="' + prefix + '"]');
  if (!panel || !trigger) return;
  panel.classList.add('is-open');
  trigger.classList.add('is-open');
  trigger.setAttribute('aria-expanded', 'true');
  // 현재 선택된 옵션을 active 로
  var selValue = $(prefix + 'CampSourceAppId')?.value || '';
  var opts = panel.querySelectorAll('.custom-srcapp-option');
  opts.forEach(function(o){ o.classList.remove('is-active'); });
  var match = panel.querySelector('.custom-srcapp-option[data-srcapp-value="' + (selValue || '') + '"]');
  if (match) match.classList.add('is-active');
}

function _srcAppClosePanel(prefix) {
  var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
  var trigger = document.querySelector('[data-srcapp-trigger="' + prefix + '"]');
  if (panel) panel.classList.remove('is-open');
  if (trigger) { trigger.classList.remove('is-open'); trigger.setAttribute('aria-expanded','false'); }
}

function _srcAppMoveActive(prefix, dir) {
  var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
  if (!panel) return;
  var opts = Array.prototype.slice.call(panel.querySelectorAll('.custom-srcapp-option'));
  if (!opts.length) return;
  var idx = opts.findIndex(function(o){ return o.classList.contains('is-active'); });
  if (idx < 0) idx = opts.findIndex(function(o){ return o.classList.contains('is-selected'); });
  if (idx < 0) idx = (dir > 0 ? -1 : opts.length);
  var next = idx + dir;
  if (next < 0) next = opts.length - 1;
  if (next >= opts.length) next = 0;
  opts.forEach(function(o){ o.classList.remove('is-active'); });
  opts[next].classList.add('is-active');
  opts[next].scrollIntoView({ block: 'nearest' });
}

// 클릭(트리거·옵션) + 외부 클릭 닫기 + 키보드 핸들링 — 위임 한 번만 등록
(function _srcAppBindHandlers(){
  if (window._srcAppHandlersBound) return;
  window._srcAppHandlersBound = true;
  document.addEventListener('click', function(e){
    var trigger = e.target.closest('[data-srcapp-trigger]');
    if (trigger) {
      e.preventDefault();
      var prefix = trigger.getAttribute('data-srcapp-trigger');
      var isOpen = trigger.classList.contains('is-open');
      if (isOpen) _srcAppClosePanel(prefix);
      else _srcAppOpenPanel(prefix);
      return;
    }
    var opt = e.target.closest('.custom-srcapp-option');
    if (opt) {
      var panel = opt.closest('[data-srcapp-panel]');
      if (!panel) return;
      var prefix2 = panel.getAttribute('data-srcapp-panel');
      var value = opt.getAttribute('data-srcapp-value') || '';
      _srcAppPick(prefix2, value);
      return;
    }
    // 외부 클릭 — 모든 패널 닫기
    document.querySelectorAll('.custom-srcapp-trigger.is-open').forEach(function(t){
      _srcAppClosePanel(t.getAttribute('data-srcapp-trigger'));
    });
  });
  document.addEventListener('keydown', function(e){
    // 어느 트리거에 포커스가 있는지
    var trigger = document.activeElement && document.activeElement.closest && document.activeElement.closest('[data-srcapp-trigger]');
    if (!trigger) return;
    var prefix = trigger.getAttribute('data-srcapp-trigger');
    var isOpen = trigger.classList.contains('is-open');
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (!isOpen) { _srcAppOpenPanel(prefix); }
      else { _srcAppMoveActive(prefix, 1); }
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      if (!isOpen) { _srcAppOpenPanel(prefix); }
      else { _srcAppMoveActive(prefix, -1); }
    } else if (e.key === 'Enter' || e.key === ' ') {
      if (!isOpen) {
        e.preventDefault();
        _srcAppOpenPanel(prefix);
        return;
      }
      e.preventDefault();
      var panel = document.querySelector('[data-srcapp-panel="' + prefix + '"]');
      var active = panel && panel.querySelector('.custom-srcapp-option.is-active');
      if (active) _srcAppPick(prefix, active.getAttribute('data-srcapp-value') || '');
    } else if (e.key === 'Escape') {
      if (isOpen) { e.preventDefault(); _srcAppClosePanel(prefix); }
    } else if (e.key === 'Tab') {
      if (isOpen) _srcAppClosePanel(prefix);
    }
  });
})();

function onCampSourceAppChange(prefix) {
  // hint 갱신 (onCampBrandChange 가 sourceSel.value 를 다시 읽어 캠페인 번호 형식 갱신)
  return onCampBrandChange(prefix);
}

function lpad(v, n) {
  var s = String(v == null ? '' : v);
  while (s.length < n) s = '0' + s;
  return s;
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

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-NOTICES — 공지사항 페인 + 대시보드 카드 + 미읽음 팝업
// ════════════════════════════════════════════════════════════════════

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
    if (_adminNoticeQuill && raw.value === '') {
      // 2026-05-07: HTML source 토글 시에도 root.innerHTML 대신 getSemanticHTML 우선
      let extracted;
      try {
        extracted = (typeof _adminNoticeQuill.getSemanticHTML === 'function')
          ? _adminNoticeQuill.getSemanticHTML(0)
          : _adminNoticeQuill.root.innerHTML;
      } catch(_) {
        extracted = _adminNoticeQuill.root.innerHTML;
      }
      raw.value = extracted;
    }
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
    // 2026-05-07: root.innerHTML은 인접 리스트를 분리해 출력하는 버그가 있어
    // (공지 ol이 5개로 쪼개져 모두 "1."로 보임), Quill 2.x getSemanticHTML 우선 사용
    let raw;
    try {
      raw = (typeof _adminNoticeQuill.getSemanticHTML === 'function')
        ? _adminNoticeQuill.getSemanticHTML(0)
        : _adminNoticeQuill.root.innerHTML;
    } catch(_) {
      raw = _adminNoticeQuill.root.innerHTML;
    }
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
    await refreshPane('admin-notices');
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

// ════════════════════════════════════════════════════════════════════
// 캠페인 노출 토글 — 폼 최상단 + 목록 빠른 토글 (사양서 2026-05-13)
// ════════════════════════════════════════════════════════════════════

// 폼 토글 영역 렌더 — status 가 expired 면 OFF, 그 외는 ON
//   draft 상태는 토글 비활성 (사양서 §7-2)
//   상태 텍스트는 현재 status 의 한국어 라벨 표시
function _renderCampVisibilityToggle(prefix, status, dateRefs) {
  var toggle = $(prefix + 'CampVisibilityToggle');
  var statusEl = $(prefix + 'CampVisibilityStatus');
  if (!toggle) return;
  var isOff = status === 'expired';
  var isDraft = status === 'draft';
  toggle.classList.toggle('is-on', !isOff);
  toggle.classList.toggle('is-disabled', isDraft);
  toggle.setAttribute('aria-checked', isOff ? 'false' : 'true');
  toggle.disabled = isDraft;
  if (statusEl) {
    var labels = { draft: '준비', scheduled: '모집예정', active: '모집중', closed: '종료', expired: '노출마감 (수동)' };
    statusEl.textContent = '상태: ' + (labels[status] || status || '미정');
    statusEl.classList.toggle('is-off', isOff);
  }
  // dateRefs 는 ON 클릭 시 status 재계산에 사용 — 폼 hidden 으로 보관
  toggle.dataset.recruitStart = (dateRefs && dateRefs.recruit_start) || '';
  toggle.dataset.deadline = (dateRefs && dateRefs.deadline) || '';
}

// 토글 클릭 핸들러 — OFF 시 확인 모달 후 status=expired, ON 시 즉시 자연 상태 재계산
async function onCampVisibilityToggle(prefix) {
  var toggle = $(prefix + 'CampVisibilityToggle');
  if (!toggle || toggle.disabled) return;
  var isCurrentlyOn = toggle.classList.contains('is-on');
  var campId = (prefix === 'edit') ? ($('editCampId')?.value || null) : null;
  if (isCurrentlyOn) {
    // ON → OFF: 확인 모달
    var ok = confirm('「캠페인 노출」을 OFF 합니다.\n\n인플루언서 화면에서 이 캠페인이 즉시 사라집니다.\n계속할까요?');
    if (!ok) return;
    if (campId) {
      try {
        await toggleCampaignVisibility(campId, false);
        toast('캠페인 노출이 OFF (노출마감) 로 변경되었습니다');
        _renderCampVisibilityToggle(prefix, 'expired', { recruit_start: toggle.dataset.recruitStart, deadline: toggle.dataset.deadline });
        // 폼 상태 드롭다운도 갱신 (있으면)
        var statusSel = $('editCampStatus');
        if (statusSel) statusSel.value = 'expired';
        await refreshPane('campaigns');
      } catch (e) {
        console.error('[toggleCampaignVisibility OFF]', e);
        toast('변경 실패: ' + (e.message || e), 'error');
      }
    } else {
      // 신규 등록 폼은 아직 DB에 없음 — UI 상태만 변경
      _renderCampVisibilityToggle(prefix, 'expired', { recruit_start: toggle.dataset.recruitStart, deadline: toggle.dataset.deadline });
    }
  } else {
    // OFF → ON: 즉시 자연 상태 재계산
    if (campId) {
      try {
        var newStatus = await toggleCampaignVisibility(campId, true);
        toast('캠페인 노출이 ON 으로 변경되었습니다');
        _renderCampVisibilityToggle(prefix, newStatus, { recruit_start: toggle.dataset.recruitStart, deadline: toggle.dataset.deadline });
        var statusSel = $('editCampStatus');
        if (statusSel) statusSel.value = newStatus;
        await refreshPane('campaigns');
      } catch (e) {
        console.error('[toggleCampaignVisibility ON]', e);
        toast('변경 실패: ' + (e.message || e), 'error');
      }
    } else {
      // 신규 등록 폼 — 기본 active 로 가정
      _renderCampVisibilityToggle(prefix, 'active', { recruit_start: toggle.dataset.recruitStart, deadline: toggle.dataset.deadline });
    }
  }
}

// 캠페인 목록 「상태」 셀 안 빠른 토글 클릭 — 단순 위임 핸들러
async function onCampQuickVisibilityToggle(ev, campId, currentStatus) {
  if (ev && ev.stopPropagation) ev.stopPropagation();
  if (!campId) return;
  var willTurnOff = currentStatus !== 'expired';
  if (willTurnOff) {
    var ok = confirm('「캠페인 노출」을 OFF 합니다.\n\n인플루언서 화면에서 이 캠페인이 즉시 사라집니다.\n계속할까요?');
    if (!ok) return;
  }
  try {
    var newStatus = await toggleCampaignVisibility(campId, !willTurnOff);
    toast(willTurnOff ? '캠페인 노출이 OFF 로 변경되었습니다' : '캠페인 노출이 ON 으로 변경되었습니다');
    await refreshPane('campaigns');
  } catch (e) {
    console.error('[onCampQuickVisibilityToggle]', e);
    toast('변경 실패: ' + (e.message || e), 'error');
  }
}

// 신규 등록 폼이 열릴 때 토글 초기 상태(ON)로 리셋 — switchAdminPane 에서 사용
function _resetNewCampVisibilityToggle() {
  _renderCampVisibilityToggle('new', 'active', { recruit_start: '', deadline: '' });
}
