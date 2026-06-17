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
// 보기 초기화 — 필터·검색·정렬을 한 번에 기본값으로 (목록 페인 공통 패턴)
function resetAppView() {
  resetMultiFilter('appTypeMulti', '전체 타입');
  resetMultiFilter('appCampStatusMulti', '전체 상태');
  resetMultiFilter('appStatusMulti', '전체 상태');
  resetMultiFilter('appCampMulti', '전체 캠페인');
  const s = $('appSearch'); if (s) s.value = '';
  appSortKey = 'created'; appSortDir = 'desc';
  document.querySelectorAll('.app-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc'); el.textContent = '▲▼';
    if (el.dataset.sort === 'created') { el.classList.add('desc'); el.textContent = '▼'; }
  });
  renderAppCampList();
}


// 캠페인 전용 래퍼 — 라벨은 캠페인 제목, subLabel에 브랜드명 · 캠페인 번호(B0019-C001 형식) 표시
//   counts: {[campaignId]: number} 형태로 옵션별 건수를 받아 옆에 (00)으로 표시
//   subLabel은 검색 대상에도 포함되므로(admin-core.js matchSearchTokens) 브랜드명으로도 검색됨
function syncCampMultiFilter(containerId, sortedCamps, onChange, counts) {
  const options = sortedCamps.map(c => {
    const brand = (typeof brandLabelAdmin === 'function') ? brandLabelAdmin(c) : (c.brand || '');
    return {
      value: c.id,
      label: c.title || '(제목 없음)',
      subLabel: [brand, c.campaign_no].filter(Boolean).join(' · '),
      count: counts ? (counts[c.id] || 0) : null
    };
  });
  // 캠페인 목록이 길어 검색형 활성화 (delivCampMulti·appCampMulti 양쪽 자동 통일)
  syncMultiFilter(containerId, '전체 캠페인', options, onChange, { searchable: true, searchPlaceholder: '캠페인명 · 브랜드 · 번호 검색' });
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
    head.innerHTML = `<tr><th>순서</th><th>캠페인</th><th>채널</th><th>브랜드</th><th>제품</th><th>상태 ${statusHelpIcon}</th><th>노출</th><th>신청</th><th>조회</th><th>등록일</th><th>수정일</th></tr>`;
  } else {
    head.innerHTML = `<tr>
      <th style="width:44px;min-width:44px;max-width:44px;text-align:center;padding:8px 4px"><input type="checkbox" id="campSelectAll" onchange="toggleCampSelectAll(this.checked)" title="필터 결과 전체 선택"></th>
      <th>캠페인</th>
      <th>채널</th>
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
    {value:'closed',    label:'모집마감', count: stCounts.closed || 0},
    {value:'ended',     label:'종료',     count: stCounts.ended || 0},
    {value:'expired',   label:'노출종료', count: stCounts.expired || 0},
  ], () => filterAdminCampaigns());
  // closed(모집마감)·ended(종료)는 실제 DB 상태(마이그레이션 156)라 필터·요약·배지 모두 분리.
  const stLabels = {active:'모집중',scheduled:'모집예정',draft:'준비',closed:'모집마감',ended:'종료',expired:'노출종료'};
  // 노출 그룹(scheduled/active/closed/ended)은 컬러, 비노출(draft/expired)은 회색·점선으로 시각 구분
  const stColors = {active:'var(--green)',scheduled:'#5B7CFF',draft:'var(--muted)',closed:'#B91C5C',ended:'#5E35B1',expired:'#666666'};
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

  // 검색 필터 — 단어 단위 AND 매칭 (matchSearchTokens, 전각/반각 공백 무관)
  const searchVal = ($('adminCampSearch')?.value || '').trim().toLowerCase();
  if (searchVal) {
    camps = camps.filter(c => matchSearchTokens(searchVal,
      [c.title, c.brand, c.brand_ko, c.brand_ja, c.brand_en, c.product, c.product_ko, c.campaign_no]));
  }

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
    const statusOrder = {draft:0,scheduled:1,active:2,closed:3,ended:4,expired:5};
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
  // 상태 배지 — closed 는 submission_end 경과 여부로 「모집마감」/「종료」 자동 구분 (shared.js campaignStatusLabelKey)
  //   노출 그룹(scheduled/active/closed)과 비노출 그룹(draft/expired)을 색·점선으로 구분
  //   scheduled=파랑, active=초록, closed_recruit=핑크(모집마감·제출 진행), closed_done=남보라(활동 종료), draft/expired=회색+점선
  const statusBadge = camp => {
    const key = campaignStatusLabelKey(camp);
    const cls = CAMPAIGN_STATUS_BADGE_CLASS[key] || 'badge-gray';
    const label = CAMPAIGN_STATUS_LABEL[key] || camp.status;
    // draft만 점선 인라인 — expired는 .badge-expired 자체에 dashed 정의되어 있어 인라인 불필요
    const dashed = camp.status==='draft' ? 'border:1.5px dashed var(--muted);' : '';
    return `<div style="position:relative;display:inline-block">
      <span class="badge ${cls}" style="cursor:pointer;${dashed}display:inline-flex;align-items:center;gap:3px" onclick="toggleStatusDropdown(this)">${label}<span style="font-size:10px;opacity:.7">▾</span></span>
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
      <td>${channelChipsHtml(c.channel, c.channel_match)}</td>
      ${(()=>{
        const bp = brandLabelAdmin(c);
        const bs = '';
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
      <td style="white-space:nowrap;min-width:90px">${statusBadge(c)}</td>
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
        // 셀 헬퍼는 dev/js/ui.js 의 공용 periodRangeCell/periodSingleCell (결과물 관리와 공용).
        var ps = (c.recruit_type === 'monitor') ? c.purchase_start
               : (c.recruit_type === 'visit')   ? c.visit_start  : '';
        var pe = (c.recruit_type === 'monitor') ? c.purchase_end
               : (c.recruit_type === 'visit')   ? c.visit_end    : '';
        return `
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${periodRangeCell(c.recruit_start, c.deadline)}</td>
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${periodRangeCell(ps, pe)}</td>
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">${periodSingleCell(c.submission_end)}</td>`;
      })()}
      <td style="font-size:13px;font-weight:600;color:var(--ink);white-space:nowrap">${(c.view_count||0).toLocaleString()}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDate(c.created_at)}</td>
      <td style="font-size:11px;color:var(--muted);white-space:nowrap">${formatDateTime(c.updated_at||c.created_at)}</td>
      ${adminReorderMode ? '' : `<td style="position:relative">
        <span class="material-icons-round notranslate camp-more-btn" translate="no" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s" data-camp-title="${esc(c.title)}" onclick="toggleCampMoreMenu(event,this,'${c.id}',this.dataset.campTitle)">more_vert</span>
      </td>`}
    </tr>`;
  };
  // 일반 모드 15컬럼(체크/캠페인/채널/브랜드/제품/상태/노출/신청/모집기간/구매기간/제출마감/조회/등록일/수정일/액션)
  // 순서변경 모드(순서/캠페인/채널/브랜드/제품/상태/노출/신청/조회/등록일/수정일) / 일반 모드 컬럼 수
  const emptyHtml = `<tr><td colspan="${adminReorderMode ? 11 : 15}" style="text-align:center;color:var(--muted);padding:24px">캠페인 없음</td></tr>`;
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
  const isLocked = status === 'closed' || status === 'ended' || status === 'expired';
  const lockLabel = status === 'expired' ? '노출종료' : status === 'ended' ? '종료' : '모집마감';
  // 모집마감·종료·노출종료 상태에서는 상태 드롭다운을 현재 상태로 고정(임의 변경·빈값 저장 차단).
  // 상태 되돌리기가 필요하면 「캠페인 노출」 토글로 처리한다.
  const statusSel = $('editCampStatus');
  if (statusSel) {
    statusSel.disabled = isLocked;
    statusSel.title = isLocked ? `${lockLabel} 캠페인의 상태는 변경할 수 없습니다 (「캠페인 노출」 토글로 조정)` : '';
    statusSel.style.opacity = isLocked ? '0.6' : '';
    statusSel.style.cursor = isLocked ? 'not-allowed' : '';
  }
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
    if (body) body.innerHTML = `<div style="padding:24px;color:#B3261E;font-size:13px">이력 불러오기 실패: ${esc(friendlyError(e.message||String(e)))}</div>`;
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
    // 브랜드명 일본어/영문 — 마스터(brands)에서 복사. brand_id 연결 캠페인은 173 트리거가 이후 동기화.
    const _editBrand = (_campBrandsCache || []).find(b => b.id === brandId);
    const brandJa = (_editBrand?.name_ja || '').trim();
    const brandEn = (_editBrand?.name_en || '').trim();

    const editDeadline = gv('editCampDeadline');
    const editDateErrs = validateCampDateRanges('editCamp');
    if (editDateErrs.length) { toast(editDateErrs[0].msg, 'error'); validateCampDateRangesInline('editCamp'); return; }
    // 빈값 가드 — 드롭다운에 없는 상태(disabled 등)거나 값이 비면 원본 상태로 폴백.
    // 종료(ended) 캠페인 편집 시 status='' 저장으로 campaigns_status_check 위반하던 버그 방지.
    const editStatus = gv('editCampStatus') || (_editCampOriginal && _editCampOriginal.status) || 'active';
    if (editDeadline && (editStatus === 'active' || editStatus === 'scheduled')) {
      const dl = new Date(editDeadline); dl.setHours(23,59,59,999);
      if (new Date() > dl) {
        const label = editStatus === 'active' ? '모집중' : '모집예정';
        toast(`모집 마감일이 지났으므로 「${label}」 상태로 저장할 수 없습니다`,'error');
        return;
      }
    }

    const recruitTypeEl = document.querySelector('input[name="editRecruitType"]:checked');
    const editRecruitType = recruitTypeEl?.value || 'monitor';
    const editChannel = Array.from(document.querySelectorAll('input[name="editChannel"]:checked')).map(c=>c.value).join(',');
    // 리뷰어형 캠페인은 채널 1개+ 강제 (사양 2 PR 1, 2026-05-28 — 결과물 채널별 카드 N개와 정합)
    if (editRecruitType === 'monitor' && !editChannel) {
      toast('리뷰어형 캠페인은 채널을 1개 이상 선택해야 합니다','error');
      return;
    }
    const contentTypes = Array.from(document.querySelectorAll('input[name="editContentType"]:checked')).map(c=>c.value).join(',');

    const updates = {
      title, brand,
      brand_id: brandId,
      source_application_id: sourceAppId || null,
      brand_ko: gv('editCampBrandKo')?.trim() || null,
      brand_ja: brandJa || null,
      brand_en: brandEn || null,
      product: gv('editCampProduct'),
      product_ko: gv('editCampProductKo')?.trim() || null,
      product_url: cleanUrl(gv('editCampProductUrl')),
      slots: parseInt(gv('editCampSlots'))||20,
      recruit_type: editRecruitType,
      channel: editChannel,
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
      status: editStatus,
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
    if (origStatus === 'closed' || origStatus === 'ended' || origStatus === 'expired') {
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
      brand_ja: src.brand_ja || null, brand_en: src.brand_en || null,
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
          ${(()=>{const bl=brandLabelInflu(camp);return bl?`<div class="cp-brand">${esc(bl)}</div>`:'';})()}
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
  // 변경 이력·감사용 흔적 청소 항목은 super_admin 한정 (audit 데이터, 일반 매니저 노출 X)
  const isSuper = currentAdminInfo?.role === 'super_admin';
  const historyItem = isSuper
    ? `<div class="camp-more-item" onclick="openCautionHistoryModal('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">history</span>변경 이력</div>`
    : '';
  const auditPurgeItem = isSuper
    ? `<div class="camp-more-item camp-more-danger" onclick="purgeCampaignAuditData('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">cleaning_services</span>감사용 흔적 청소</div>`
    : '';
  menu.innerHTML = `
    <div class="camp-more-item" onclick="openEditCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">edit</span>편집</div>
    <div class="camp-more-item" onclick="duplicateCampaign('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">content_copy</span>복제</div>
    <div class="camp-more-item" onclick="exportCampaignDeliverables('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>결과물 엑셀</div>
    <div class="camp-more-item" onclick="exportCampaignApplicationsExcel('${campId}')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">download</span>신청자 엑셀</div>
    ${historyItem}
    ${auditPurgeItem}
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

// 캠페인별 감사용 흔적 청소 — super_admin 전용.
// 이 캠페인에서 감사용 계정(is_audit=true)이 만든 응모·결과물·메시지를 모두 삭제한다.
async function purgeCampaignAuditData(campId) {
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  if (currentAdminInfo?.role !== 'super_admin') return;
  const ok = await showConfirm('이 캠페인에서 감사용 계정이 만든 응모·결과물·메시지를 모두 삭제합니다. 되돌릴 수 없습니다. 진행할까요?');
  if (!ok) return;
  try {
    const res = await purgeAuditDataForCampaign(campId);
    const rpc = res?.rpc;
    if (!rpc || rpc.status === 'no_audit_account' || !rpc.deleted || (rpc.deleted.applications || 0) === 0) {
      toast('삭제할 감사용 데이터 없음', '');
    } else {
      const n = rpc.deleted.applications || 0;
      toast(`감사용 응모 ${n}건·결과물 등 삭제됨`, 'success');
    }
    // 진행현황 페인이 열려 있으면 그쪽을, 아니면 캠페인 목록 갱신
    const applicantsPaneActive = $('adminPane-camp-applicants')?.classList.contains('on');
    await refreshPane(applicantsPaneActive ? 'camp-applicants' : 'campaigns');
  } catch (e) {
    console.error('[purgeCampaignAuditData]', e);
    toast('감사용 흔적 청소 실패: ' + (e?.message || e), 'error');
  }
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
    {val:'closed',    label:'모집마감', cls:'badge-pink'},
    {val:'ended',     label:'종료',     cls:'badge-done'},
    {val:'expired',   label:'노출종료', cls:'badge-expired'}
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
  // 브랜드명 일본어/영문 — 마스터(brands)에서 복사. brand_id 연결 캠페인은 173 트리거가 이후 동기화.
  const brandJa = (_pickedBrand?.name_ja || '').trim();
  const brandEn = (_pickedBrand?.name_en || '').trim();
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
    brand_ja: brandJa || null,
    brand_en: brandEn || null,
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
    // 참여방법 desc 는 미니에디터 HTML(이미지·서식) — cset/nset 요약처럼 렌더해야 raw 태그 노출 방지
    const renderRich = (typeof miniRichHtml === 'function') ? miniRichHtml : (x => esc(String(x||'')));
    const renderStep = (s, i, lang) => {
      const title = lang === 'ko' ? (s.title_ko || s.title_ja || '—') : (s.title_ja || s.title_ko || '—');
      const desc  = lang === 'ko' ? (s.desc_ko || s.desc_ja || '') : (s.desc_ja || s.desc_ko || '');
      return `<div class="summary-step"><div class="summary-step-title">STEP ${i+1} · ${esc(title)}</div>${desc?`<div class="summary-step-desc rich-content">${renderRich(desc)}</div>`:''}</div>`;
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
    var labels = { draft: '준비', scheduled: '모집예정', active: '모집중', closed: '모집마감', ended: '종료', expired: '노출종료 (수동)' };
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
        toast('캠페인 노출이 OFF (노출종료) 로 변경되었습니다');
        _renderCampVisibilityToggle(prefix, 'expired', { recruit_start: toggle.dataset.recruitStart, deadline: toggle.dataset.deadline });
        // 폼 상태 드롭다운도 갱신 (있으면)
        var statusSel = $('editCampStatus');
        if (statusSel) statusSel.value = 'expired';
        await refreshPane('campaigns');
      } catch (e) {
        console.error('[toggleCampaignVisibility OFF]', e);
        toast('변경 실패: ' + friendlyError(e.message || e), 'error');
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
        toast('변경 실패: ' + friendlyError(e.message || e), 'error');
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
    toast('변경 실패: ' + friendlyError(e.message || e), 'error');
  }
}

// 신규 등록 폼이 열릴 때 토글 초기 상태(ON)로 리셋 — switchAdminPane 에서 사용
function _resetNewCampVisibilityToggle() {
  _renderCampVisibilityToggle('new', 'active', { recruit_start: '', deadline: '' });
}
