// ════════════════════════════════════════════════════════════════════
// SECTION: BRAND DETAIL (TABS) — 관리자 브랜드 상세 탭 4개 새 페이지
//   사양서 docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 …-breakdown.md
//   피그마 「레버브시딩_브랜드」 a03-00d(틀·머리·탭) · a03-09(떠날 때 확인) · a03-07·07a·07b(회사 모달)
//   🔴 개발서버만 연다 — `openBrandDetail` 맨 앞 한 줄이 `_brandAccountEnabled()` 일 때만 이 페이지로 보낸다(작업표 S0).
//      운영은 출시 날까지 admin-brand.js 의 옛 페이지 그대로.
//   🔴 상태(`_brandsCurrentId`·`_brandDetailTab`·`_brandFormContacts`·`_brandFormCompanies` …)는 admin-brand.js 의 것을 그대로 쓴다 —
//      오리엔시트 구역 다시 그리기(refreshBrandDetailSheets)·메모·계정 줄·공개 기본 열이 그 이름으로 돈다.
//   🔴 브랜드 정보 탭(`#brandDetailPane_info`)은 편집 폼이다 — 탭 전환·요약 줄·다른 탭 다시 그리기가 **이 영역을 건드리지 않는다**.
//   저장은 탭마다 따로다 — 브랜드 정보 탭 「저장」 = 575 admin_update_brand_info(바뀐 칸만·연 순간 값 대조, 조각 7·8),
//      담당자 = 줄 단위 창(574, 조각 12), 계정 = 동작마다(533·573, 조각 11). 옛 saveBrandDetail 은 이 페이지에서 부르지 않는다(운영 옛 창 전용).
// ════════════════════════════════════════════════════════════════════

var _brandDetailBrand = null;           // 연(또는 마지막으로 저장한) 브랜드 행 — 머리·요약 줄이 읽는다
var _brandDetailAccountStatus = undefined;   // 계정 상태 조회 — undefined 아직 / null 실패 / 객체
var _brandDetailAccountReq = 0;
var _bdBaseline = null;                 // 떠날 때 확인 기준값 {칸 열쇠: 값} — 브랜드 정보 탭만
var _bdLeaveGo = null;                  // 「저장하지 않고 나가기」가 이어 갈 동작
var _brandInfoPrev = null;              // 브랜드 정보 탭 「연(또는 저장한) 순간 값」 — 575 의 p_prev(열쇠 여덟)
var _bdPublishData = undefined;         // 공개 기본 열 조회 — undefined 아직 / null 실패 / {global_spec, brand_spec, brand_updated_*}
var _bdInfoBusy = false;

// 새 페이지가 지금 화면에 떠 있는가
function brandDetailIsTabsPage() {
  var paneEl = $('adminPane-brand-detail');
  return !!(paneEl && paneEl.classList.contains('on') && $('brandDetailPane_info') && _brandsCurrentId);
}

async function openBrandDetailTabs(id, opts) {
  opts = opts || {};
  if (!canOpenBrandDetail()) { if (typeof toast === 'function') toast('접근 권한이 없는 메뉴입니다.', 'error'); return; }
  // 고치던 값이 있는데 다른(또는 같은) 브랜드를 다시 열면 먼저 묻는다(조각 6 — 운영 현황·발급 창·배송 탭에서 들어오는 길)
  if (!opts._guarded && brandDetailDirty()) {
    brandDetailLeaveGuard(function(){ openBrandDetailTabs(id, Object.assign({}, opts, { _guarded: true })); });
    return;
  }
  _brandsCurrentId = id;
  // 🔴 보이는 값을 먼저 비운다 — 옛 페이지 openBrandDetail 과 같은 순서(메모·계정 줄·구역 요청 번호)
  _brandMemos = undefined;
  _brandMemoDraft = '';
  _brandMemoEditDraft = {};
  _brandDetailFrom = 'brands';   // 새 페이지는 들어온 곳을 돌아가기에 쓰지 않는다(D12)
  _brandDetailStale = false;
  _brandDetailSheetsReq++;
  _brandFormPrimaryOriginal = { contactId: null, email: null };
  _brandAccountNotice = null;
  _brandAccountLastStatus = undefined;
  _brandAccountRowReq++;
  _brandDetailBrand = null;
  _brandDetailAccountStatus = undefined;
  _brandDetailAccountReq++;
  _bdBaseline = null;
  _brandInfoPrev = null;
  _bdPublishData = undefined;
  _bdInfoBusy = false;
  clearBrandModalBody();
  var titleEl = $('brandDetailPaneHeader');
  var bodyEl = $('brandDetailPaneBody');
  if (!bodyEl) return;
  bodyEl.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)"><span class="spinner" style="width:18px;height:18px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink);display:inline-block;vertical-align:middle;margin-right:6px"></span>불러오는 중…</div>';
  if (titleEl) titleEl.innerHTML = '';
  switchAdminPane('brand-detail');
  // 🔴 실패는 전부 `null` 이고 자리마다 표시가 따로 있다 — 「0건인 척」 그리지 않는다.
  var res = await Promise.all([
    fetchBrandById(id),
    (typeof fetchOrientSheetsByBrand === 'function' ? fetchOrientSheetsByBrand(id) : Promise.resolve(null)),
    (typeof countBrandApplicationsByBrand === 'function' ? countBrandApplicationsByBrand(id) : Promise.resolve(null)),
    (typeof fetchCompanies === 'function' ? fetchCompanies({ status: 'all' }) : Promise.resolve([])),
    (typeof countCampaignsByBrand === 'function' ? countCampaignsByBrand(id) : Promise.resolve(null))
  ]);
  var b = res[0], sheets = res[1], surveyCount = res[2], companies = res[3], campCount = res[4];
  if (_brandsCurrentId !== id) return;
  if (!b) { bodyEl.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">데이터를 불러올 수 없습니다</div>'; return; }
  _brandDetailTab = (opts.tab === 'people') ? 'people' : 'info';   // 처음 탭 = 브랜드 정보, 발급 창 계정 경고만 담당자·계정(D7·A5)
  _brandDetailCamps = undefined;
  _brandDetailPublishStates = null;
  var campMap = {};
  try {
    var campIds = collectOrientCampaignIds(sheets);
    _brandDetailSheetCampIds = campIds.slice();
    if (campIds.length && typeof fetchCampaignsByIds === 'function') campMap = await fetchCampaignsByIds(campIds);
  } catch (_) { campMap = {}; }
  // 🔴 두 번째 기다림 뒤에도 다시 대조한다(옛 페이지 H-3 과 같은 이유 — 앞 브랜드 폼이 뒤늦게 덮는다)
  if (_brandsCurrentId !== id) return;
  _brandFormCompanies = companies || [];
  _brandDetailSurveyCount = surveyCount;
  _brandDetailBrand = b;
  _brandInfoPrev = _bdInfoPrevFromBrand(b, undefined);
  _brandFormPrimaryOriginal = _brandPrimarySnapshotFromContacts(b.contacts);
  _initBrandFormContacts(b);

  var isAdm = (typeof isCampaignAdminOrAbove === 'function' && isCampaignAdminOrAbove());
  // 🔴 삭제 판정 두 단계 — 옛 페이지와 같다(셋 중 하나라도 조회 실패면 잠그고 안내, 셋 다 0 일 때만)
  var countsKnown = Array.isArray(sheets) && (surveyCount !== null && surveyCount !== undefined)
                    && (campCount !== null && campCount !== undefined);
  var canDeleteBrand = countsKnown && (sheets.length === 0) && (surveyCount === 0) && (campCount === 0) && isAdm;

  if (titleEl) titleEl.innerHTML = _bdHeadHtml(b, {
    isAdm: isAdm, canDelete: canDeleteBrand, countsKnown: countsKnown,
    sheetCnt: Array.isArray(sheets) ? String(sheets.length) : '…',
    campCnt: (campCount === null || campCount === undefined) ? '…' : String(campCount)
  });
  bodyEl.innerHTML = '<div class="bd-grid">'
    + '<div class="bd-main">'
      + '<div id="brandDetailPane_info"' + (_brandDetailTab === 'info' ? '' : ' style="display:none"') + '>' + _bdInfoPaneHtml(b) + '</div>'
      + '<div id="brandDetailPane_people"' + (_brandDetailTab === 'people' ? '' : ' style="display:none"') + '>' + _bdPeoplePaneHtml(b) + '</div>'
      + '<div id="brandDetailPane_sheets" style="display:none">' + renderBrandOrientSheetsView(sheets, campMap) + renderBrandSurveyNoteHtml(surveyCount) + '</div>'
      + '<div id="brandDetailPane_camps" style="display:none">' + renderBrandCampaignsView(undefined) + '</div>'
    + '</div>'
    // 영업 메모 — 오른쪽 칸(네 탭 공통, 즉시 저장). 🔴 자체 스크롤이 없으면 메모가 쌓였을 때 아래가 안 닿는다
    + '<aside class="bd-memo">'
      + '<div id="brandMemoPanel">' + renderBrandMemoPanelHtml(b) + '</div>'
    + '</aside>'
  + '</div>';
  onBrandCompanyChange();   // 회사 카드 끝 줄을 「수정 / 보기」 링크로(카드가 DOM 에 붙은 뒤라야 위치로 가를 수 있다)
  renderBrandPeopleTab();   // 계정 상태가 오기 전 — 담당자 줄만(계정 칸 「불러오는 중」)
  _bdBindInfoPane();
  brandDetailMarkClean();
  // 공개 기본 열은 따로 받는다(조각 7 — 칸 안 단추 없이 탭 「저장」이 함께 저장). 받은 뒤 그 칸만 기준값에 더한다
  _bdLoadPublishBox(id, undefined);
  syncBrandDetailTabOffset();
  renderBrandDetailSummaryLine();
  _bdLoadAccountStatus(id);
  loadBrandMemos(id);
}

// ── 머리(a03-00d) ── 「← 목록」 · 브랜드명 · 번호 칩 · 상태 배지 / 요약 한 줄 / 「병합」 · 「오리엔시트 발급」 · 「…」 / 탭 줄
function _bdHeadHtml(b, o) {
  var id = b.id;
  var icon = function(name) { return '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">' + name + '</span>'; };
  var tab = function(code, label, cnt) {
    return '<button type="button" class="status-tab-btn' + (code === _brandDetailTab ? ' on' : '') + '" id="brandDetailTab_' + code + '" onclick="setBrandDetailTab(\'' + code + '\')">'
      + esc(label)
      + (cnt === null ? '' : '<span class="tab-count">(' + esc(cnt) + ')</span>')
      + (code === 'info' ? '<span class="brand-detail-dirty-dot" title="저장하지 않은 변경이 있습니다" style="display:none"></span>' : '')
    + '</button>';
  };
  // 「…」 항목 — 「제공 기록」(최고 관리자·개발서버) · 「삭제」(삭제 조건). 🔴 「삭제」 아이디는 옛 그대로 —
  //   오리엔시트가 생기면 refreshBrandDetailSheets 가 그 아이디로 뗀다. 항목이 0개면 「…」 를 안 그린다(D4)
  var items = '';
  if (typeof _privacyLogsAllowed === 'function' && _privacyLogsAllowed()) {
    items += '<div class="camp-more-item" onclick="brandDetailCloseMoreMenu();openPrivacyLogs({brandId:' + jsStr(id) + ',brandName:' + jsStr(b.name || '') + '})">' + icon('policy') + '제공 기록</div>';
  }
  if (o.canDelete) {
    items += '<div class="camp-more-item" id="brandDetailDeleteBtn" style="color:#c0392b" onclick="brandDetailCloseMoreMenu();deleteBrandConfirm()">' + icon('delete_outline') + '삭제</div>';
  }
  var more = items
    ? '<div class="bd-more-wrap" id="brandDetailMoreWrap">'
        + '<button type="button" class="btn btn-ghost btn-sm bd-more-btn" id="brandDetailMoreBtn" aria-label="더 보기" aria-haspopup="menu" aria-expanded="false" onclick="brandDetailToggleMoreMenu(event)">' + icon('more_horiz') + '</button>'
        + '<div class="camp-more-menu bd-more-menu" id="brandDetailMoreMenu" role="menu" style="display:none">' + items + '</div>'
      + '</div>'
    : '';
  return '<div class="bd-head">'
    + '<div class="bd-head-row">'
      + '<button type="button" class="btn btn-ghost btn-sm" onclick="brandDetailGoList()" style="display:inline-flex;align-items:center;gap:4px">' + icon('arrow_back') + '목록</button>'
      + '<span data-brand-name class="bd-title">' + esc(b.name || '') + '</span>'
      + '<span class="bd-no-chip">' + esc(b.brand_no || '') + '</span>'
      + '<span id="brandDetailStatusBadge">' + _bdStatusBadgeHtml(b.status) + '</span>'
      // 결과물 열람 정지 배지 자리(제한 11) — 계정 상태 조회가 끝나면 bdSanctionSyncHead 가 채운다
      + '<span id="brandDetailSuspendBadge"></span>'
      + '<div class="bd-head-actions">'
        // 🔴 삭제를 잠근 이유를 말한다 — 캠페인 수 조회 실패는 이 줄이 유일한 안내다(옛 페이지와 같다)
        + ((!o.countsKnown && o.isAdm) ? '<span class="bd-lock-note">일부 정보를 불러오지 못해 삭제를 잠갔습니다</span>' : '')
        + (o.isAdm ? '<button type="button" class="btn btn-ghost btn-sm" onclick="openBrandMergeModal(' + jsStr(id) + ')" style="display:inline-flex;align-items:center;gap:4px;color:#c0392b">' + icon('merge') + '병합</button>' : '')
        // 캠페인 매니저에게도 보인다(지금과 같다 — 작업표 M4)
        + '<button type="button" class="btn btn-ghost btn-sm" onclick="osOpenCreate({brandId:' + jsStr(id) + ',lockBrand:true})" style="display:inline-flex;align-items:center;gap:4px">' + icon('assignment_turned_in') + '오리엔시트 발급</button>'
        + more
      + '</div>'
    + '</div>'
    + '<div id="brandDetailSummaryLine" class="bd-summary"></div>'
    + '<div class="status-tab-bar bd-tabs" role="tablist">'
      + tab('info', '브랜드 정보', null)
      + tab('people', '담당자·계정', String(_brandFormContacts.length))
      + tab('sheets', '오리엔시트', o.sheetCnt)
      + tab('camps', '캠페인', o.campCnt)
    + '</div>'
  + '</div>';
}

function _bdStatusBadgeHtml(status) {
  return status === 'archived'
    ? '<span class="bd-status is-archived">● 비활성</span>'
    : '<span class="bd-status is-active">● 활성</span>';
}

// 요약 한 줄 — 「회사 ○○ · 대표 담당자 ○○ (브랜드 페이지 사용 중) · 멤버 n / m명 · 초대 대기 k 포함」(사양서 4-0)
//   🔴 이 줄만 다시 그린다 — 브랜드 정보 영역을 건드리지 않는다. 값은 **저장된** 브랜드 행 기준(고치는 중인 칸이 아니라).
//   멤버 구절은 계정 상태를 받았을 때만 — 조회 실패·계정 기능 꺼짐이면 구절째 뺀다(0으로 그리지 않는다)
function renderBrandDetailSummaryLine() {
  var el = $('brandDetailSummaryLine');
  var b = _brandDetailBrand;
  if (!el || !b) return;
  var parts = [];
  var co = b.company_id ? (_brandFormCompanies || []).find(function(c){ return c.id === b.company_id; }) : null;
  var coName = co ? (co.name_ko || co.name_ja || co.name_en || '') : (b.company_name || '');
  parts.push(coName ? '회사 ' + esc(coName) : '회사 미지정');
  var contacts = Array.isArray(b.contacts) ? b.contacts : [];
  var primary = contacts.find(function(c){ return c && c.is_primary; });
  var primaryName = primary ? (primary.name || primary.email || '') : (b.primary_contact_name || '');
  var st = _brandDetailAccountStatus;
  var ownerActive = !!(st && st.status === 'active');
  parts.push(primaryName
    ? '대표 담당자 ' + esc(primaryName) + (ownerActive ? ' (브랜드 페이지 사용 중)' : (bdLinkPending(st) ? ' (연결 요청 보냄)' : ''))
    : (bdLinkPending(st) ? '대표 담당자 없음 (연결 요청 보냄)' : '대표 담당자 없음'));
  if (st && st.member_limit !== undefined && st.member_limit !== null && st.seat_used !== undefined && st.seat_used !== null) {
    var pend = Number(st.pending_invite_count) || 0;
    parts.push('멤버 ' + esc(String(st.seat_used)) + ' / ' + esc(String(st.member_limit)) + '명' + (pend > 0 ? ' · 초대 대기 ' + pend + ' 포함' : ''));
  }
  el.innerHTML = parts.join(' · ');
  syncBrandDetailTabOffset();
}

async function _bdLoadAccountStatus(brandId) {
  if (!brandId || typeof fetchBrandAccountStatus !== 'function') return;
  var req = ++_brandDetailAccountReq;
  var st = await fetchBrandAccountStatus(brandId);
  if (req !== _brandDetailAccountReq || _brandsCurrentId !== brandId) return;
  _brandDetailAccountStatus = st;
  renderBrandDetailSummaryLine();
  renderBrandPeopleTab();
  if (typeof bdSanctionSyncHead === 'function') bdSanctionSyncHead();
}

// ── 「…」 메뉴 ──
function brandDetailToggleMoreMenu(e) {
  if (e) e.stopPropagation();
  var menu = $('brandDetailMoreMenu');
  var btn = $('brandDetailMoreBtn');
  if (!menu) return;
  var open = menu.style.display === 'none';
  menu.style.display = open ? '' : 'none';
  if (btn) btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  if (!open) return;
  setTimeout(function() {
    document.addEventListener('click', function _close(ev) {
      var m = $('brandDetailMoreMenu');
      if (m && m.contains(ev.target)) return;
      brandDetailCloseMoreMenu();
      document.removeEventListener('click', _close);
    });
  }, 0);
}
function brandDetailCloseMoreMenu() {
  var menu = $('brandDetailMoreMenu'); if (menu) menu.style.display = 'none';
  var btn = $('brandDetailMoreBtn'); if (btn) btn.setAttribute('aria-expanded', 'false');
}
// 항목이 0개가 되면 「…」 를 지운다 — 오리엔시트가 생겨 「삭제」가 떨어질 때(refreshBrandDetailSheets 가 부른다)
function brandDetailSyncMoreMenu() {
  var menu = $('brandDetailMoreMenu');
  if (menu && !menu.querySelector('.camp-more-item')) { var w = $('brandDetailMoreWrap'); if (w) w.remove(); }
}

// ── 브랜드 정보 탭 (조각 7 — 피그마 a03-00d · 사양서 4-1 · D3·D8·D13·D14) ──
//   칸: 기본 정보(회사·상태·이름 셋) → SNS 정보(Instagram·X) → 브랜드 공개 기본 열. 소개·어필·Qoo10 은 뺐다(D14).
//   「저장」 = 575 admin_update_brand_info — 바뀐 칸만, 연 순간 값(_brandInfoPrev)과 대조. 🔴 담당자 목록은 보내지 않는다(D8 — 담당자는 담당자 창이 줄 단위로).
//   🔴 입력칸 아이디는 옛 페이지·「새 브랜드」 창과 같다(onBrandCompanyChange 등이 그 아이디로 읽는다) — 화면에 둘이 되지 않게
//      clearBrandModalBody·clearBrandDetailPaneBody 한 세트가 지킨다.
function _bdSection(title, rightHtml, contentHtml) {
  return '<section class="bd-section">'
    + '<div class="bd-section-head"><span>' + esc(title) + '</span>' + (rightHtml || '') + '</div>'
    + contentHtml
  + '</section>';
}
function _bdLabel(text, forId) {
  return '<label class="bd-label"' + (forId ? ' for="' + forId + '"' : '') + '>' + esc(text) + '</label>';
}
function _bdInput(id, label, val, placeholder) {
  return '<div>' + _bdLabel(label, id) + '<input type="text" id="' + id + '" class="admin-filter" autocomplete="off" data-lpignore="true" value="' + esc(val || '') + '" placeholder="' + esc(placeholder || '') + '" style="width:100%;box-sizing:border-box"></div>';
}

function _bdInfoPaneHtml(b) {
  var status = b.status || 'active';
  var canNewCompany = (typeof canEditCompanies === 'function') && canEditCompanies();
  return _bdSection('기본 정보', '',
      '<div class="bd-company-row">'
        + '<div>' + _bdLabel('회사 (회사 관리 명부에서 선택)', 'brandFormCompanyId')
          + '<div style="display:flex;gap:8px;align-items:center">'
            + '<select id="brandFormCompanyId" class="admin-filter" onchange="onBrandCompanyChange()" style="flex:1;min-width:0;box-sizing:border-box">' + _brandCompanyOptionsHtml(b.company_id || '') + '</select>'
            + (canNewCompany ? '<button type="button" class="btn btn-ghost btn-xs" onclick="openCompanyModalForBrand()" style="display:inline-flex;align-items:center;gap:3px;white-space:nowrap"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">add</span> 신규 회사 등록</button>' : '')
          + '</div>'
        + '</div>'
        + '<div>' + _bdLabel('상태', 'brandFormStatus')
          + '<select id="brandFormStatus" class="admin-filter" style="width:100%;box-sizing:border-box">'
            + '<option value="active"' + (status === 'active' ? ' selected' : '') + '>● 활성</option>'
            + '<option value="archived"' + (status === 'archived' ? ' selected' : '') + '>● 비활성</option>'
          + '</select>'
        + '</div>'
      + '</div>'
      + '<div id="brandCompanyInfoCard" style="margin-top:10px">' + renderBrandCompanyInfoCardInner(b.company_id || '') + '</div>'
      + '<div class="bd-grid-3" style="margin-top:14px">'
        + _bdInput('brandFormName', '브랜드명 (한국어) *', b.name)
        + _bdInput('brandFormNameJa', '브랜드명 (일본어)', b.name_ja)
        + _bdInput('brandFormNameEn', '브랜드명 (영문)', b.name_en)
      + '</div>')
    + _bdSection('SNS 정보', '',
      '<div class="bd-grid-2">'
        + _bdInput('brandFormInstagramUrl', '공식 Instagram URL', b.official_instagram_url, 'https://www.instagram.com/...')
        + _bdInput('brandFormXUrl', '공식 X URL', b.official_x_url, 'https://x.com/...')
      + '</div>')
    + _bdSection('브랜드 공개 기본 열', '',
      '<div class="bd-save-note" style="margin:-4px 0 10px">이 브랜드 캠페인에서 「브랜드 공개」를 처음 켤 때 미리 체크되는 열입니다. 이미 공개를 켠 캠페인은 바뀌지 않습니다.</div>'
      + '<div id="brandPublishDefaultBox"><div style="padding:12px;text-align:center;color:var(--muted);font-size:12px">불러오는 중…</div></div>')
    // 아래 띠 — 바뀐 칸이 있을 때만(_bdSyncDirtyUi)
    + '<div id="brandInfoSaveBar" class="bd-savebar" style="display:none" role="region" aria-label="저장하지 않은 변경">'
      + '<span class="material-icons-round notranslate" translate="no">edit_note</span>'
      + '<span class="bd-savebar-text">저장하지 않은 변경이 있습니다 — 이 탭의 내용은 「저장」을 눌러야 저장됩니다.</span>'
      + '<button type="button" class="btn btn-ghost btn-sm" id="brandInfoRevertBtn" onclick="revertBrandInfoTab()">되돌리기</button>'
      + '<button type="button" class="btn btn-primary btn-sm" id="brandInfoSaveBtn" onclick="saveBrandInfoTab()">저장</button>'
    + '</div>';
}

// 연 순간 값 — 열쇠 여덟. publish_default 는 공개 기본 열을 받았을 때만(undefined = 아직·실패 — 그때는 보내지 않는다)
var BRAND_INFO_KEYS = ['name', 'name_ja', 'name_en', 'company_id', 'status', 'official_instagram_url', 'official_x_url'];
function _bdNorm(v) { var t = (v === null || v === undefined) ? '' : String(v).trim(); return t === '' ? null : t; }
function _bdInfoPrevFromBrand(b, publish) {
  var p = {};
  BRAND_INFO_KEYS.forEach(function(k){ p[k] = (k === 'status') ? (b.status || 'active') : _bdNorm(b[k]); });
  if (publish && typeof publish === 'object') p.publish_default = Array.isArray(publish.brand_spec) ? publish.brand_spec.slice() : null;
  return p;
}
function _bdSpecKey(v) { return Array.isArray(v) ? JSON.stringify(v.slice().sort()) : 'null'; }

// 공개 기본 열 칸을 그린다(data 를 넘기면 다시 받지 않는다). 받은 뒤 그 칸만 떠날 때 확인 기준값에 더한다
function _bdLoadPublishBox(brandId, data) {
  if (typeof renderBrandPublishDefaultBox !== 'function') return Promise.resolve();
  return renderBrandPublishDefaultBox(brandId, {
    embedded: true,
    data: data,
    onLoaded: function(d) {
      if (_brandsCurrentId !== brandId) return;
      _bdPublishData = d;
      if (_brandInfoPrev) {
        if (d) _brandInfoPrev.publish_default = Array.isArray(d.brand_spec) ? d.brand_spec.slice() : null;
        else delete _brandInfoPrev.publish_default;
      }
    }
  }).then(function() {
    if (_brandsCurrentId !== brandId || !_bdBaseline) return;
    var now = _bdSnapshot();
    Object.keys(now).forEach(function(k){ if (!Object.prototype.hasOwnProperty.call(_bdBaseline, k)) _bdBaseline[k] = now[k]; });
    _bdSyncDirtyUi();
  });
}

// 바뀐 칸만 → {fields, prev, keys}. 🔴 report.share 쓰기 권한이 아니면 publish_default 를 아예 넣지 않는다(575 가 forbidden 으로 전체 거부)
function collectBrandInfoChanges() {
  var prev = _brandInfoPrev || {};
  var cur = {
    name: _bdNorm($('brandFormName') && $('brandFormName').value),
    name_ja: _bdNorm($('brandFormNameJa') && $('brandFormNameJa').value),
    name_en: _bdNorm($('brandFormNameEn') && $('brandFormNameEn').value),
    company_id: _bdNorm($('brandFormCompanyId') && $('brandFormCompanyId').value),
    status: ($('brandFormStatus') && $('brandFormStatus').value) || 'active',
    official_instagram_url: _bdNorm($('brandFormInstagramUrl') && $('brandFormInstagramUrl').value),
    official_x_url: _bdNorm($('brandFormXUrl') && $('brandFormXUrl').value)
  };
  var fields = {}, pv = {}, keys = [];
  BRAND_INFO_KEYS.forEach(function(k) {
    if (cur[k] !== prev[k]) { fields[k] = cur[k]; pv[k] = prev[k]; keys.push(k); }
  });
  var canPublish = (typeof _bpCanEditDefaults === 'function') && _bpCanEditDefaults();
  // 🔴 칸이 실제로 그려져 있을 때만 — 다시 받는 중(「불러오는 중」)이면 라디오가 없어 값이 null(전체 기본값)로 읽혀 따로 정한 열이 지워진다
  var boxReady = !!document.querySelector('#brandPublishDefaultBox input[name="bpBrandMode"]');
  if (canPublish && boxReady && _bdPublishData && Object.prototype.hasOwnProperty.call(prev, 'publish_default') && typeof brandPublishDefaultBoxValue === 'function') {
    var spec = brandPublishDefaultBoxValue();
    if (_bdSpecKey(spec) !== _bdSpecKey(prev.publish_default)) { fields.publish_default = spec; pv.publish_default = prev.publish_default; keys.push('publish_default'); }
  }
  return { fields: fields, prev: pv, keys: keys };
}

var BRAND_INFO_LABELS = {
  name: '브랜드명 (한국어)', name_ja: '브랜드명 (일본어)', name_en: '브랜드명 (영문)', company_id: '회사', status: '상태',
  official_instagram_url: '공식 Instagram URL', official_x_url: '공식 X URL', publish_default: '브랜드 공개 기본 열'
};
var BRAND_INFO_INPUT = {
  name: 'brandFormName', name_ja: 'brandFormNameJa', name_en: 'brandFormNameEn', company_id: 'brandFormCompanyId', status: 'brandFormStatus',
  official_instagram_url: 'brandFormInstagramUrl', official_x_url: 'brandFormXUrl'
};

function _bdInfoSetBusy(on) {
  _bdInfoBusy = !!on;
  ['brandInfoSaveBtn', 'brandInfoRevertBtn'].forEach(function(id){ var b = $(id); if (b) b.disabled = !!on; });
  var sb = $('brandInfoSaveBtn'); if (sb) sb.textContent = on ? '저장하는 중…' : '저장';
}

// 「저장」 — opts.fields·opts.prev 는 저장 충돌 창의 「내 값으로 저장」(지금 서버 값을 새 연 순간 값으로)
async function saveBrandInfoTab(opts) {
  opts = opts || {};
  if (_bdInfoBusy) return;
  var brandId = _brandsCurrentId;
  if (!brandId || !brandDetailIsTabsPage()) return;
  var ch = opts.fields ? { fields: opts.fields, prev: opts.prev, keys: Object.keys(opts.fields) } : collectBrandInfoChanges();
  if (!ch.keys.length) { toast('바뀐 내용이 없습니다.'); brandDetailMarkClean(); return; }
  if (Object.prototype.hasOwnProperty.call(ch.fields, 'name') && !ch.fields.name) {
    toast('브랜드명(한국어)을 입력하세요.', 'warn'); var n = $('brandFormName'); if (n) n.focus(); return;
  }
  _bdInfoSetBusy(true);
  var res = await saveBrandInfoAdmin(brandId, ch.fields, ch.prev);
  _bdInfoSetBusy(false);
  if (_brandsCurrentId !== brandId || !brandDetailIsTabsPage()) return;
  if (!res.ok) {
    if (/forbidden|42501/.test(String(res.error || ''))) { toast('권한이 바뀌어 저장할 수 없습니다. 페이지를 새로고침해 주십시오.', 'error'); return; }
    toast('브랜드 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error'); return;
  }
  var r = res.result;
  if (r === 'ok') { _bdAfterInfoSaved(ch.fields); return; }
  if (r === 'stale') { openBrandInfoConflictModal(ch); return; }
  if (r === 'duplicate_name') { toast('이미 같은 이름의 브랜드가 등록돼 있습니다. (띄어쓰기·대소문자는 같은 것으로 봅니다)', 'error'); var nm = $('brandFormName'); if (nm) nm.focus(); return; }
  if (r === 'forbidden') { toast('권한이 바뀌어 저장할 수 없습니다. 페이지를 새로고침해 주십시오.', 'error'); return; }
  if (r === 'not_found') { toast('브랜드를 찾지 못했습니다 — 목록에서 다시 열어 주십시오.', 'error'); return; }
  if (r === 'invalid_input') {
    var f = res.field || '';
    var label = BRAND_INFO_LABELS[f];
    var msg = !label ? '저장할 수 없는 값이 있습니다 [' + f + ']'
      : (f === 'official_instagram_url' || f === 'official_x_url') ? label + '은 https:// 로 시작하는 주소로 넣어 주십시오.'
      : f === 'name' ? '브랜드명(한국어)을 입력하세요.'
      : label + ' 값이 올바르지 않습니다.';
    toast(msg, 'warn');
    var el = BRAND_INFO_INPUT[f] && $(BRAND_INFO_INPUT[f]); if (el) el.focus();
    return;
  }
  toast('브랜드 정보를 저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error');
}

// 저장 성공 — 저장한 값으로 행·연 순간 값·머리(제목·배지)·요약 줄을 맞추고 띠·점을 끈다. 화면 칸은 그대로(다시 그리지 않는다)
function _bdAfterInfoSaved(fields) {
  var b = _brandDetailBrand;
  if (b) {
    Object.keys(fields).forEach(function(k){ if (k !== 'publish_default') b[k] = fields[k]; });
    if (Object.prototype.hasOwnProperty.call(fields, 'company_id')) {
      var co = fields.company_id ? (_brandFormCompanies || []).find(function(c){ return c.id === fields.company_id; }) : null;
      b.company_name = co ? (co.name_ko || null) : null;
    }
  }
  _brandInfoPrev = Object.assign({}, _brandInfoPrev || {});
  Object.keys(fields).forEach(function(k){ _brandInfoPrev[k] = (k === 'publish_default' && Array.isArray(fields[k])) ? fields[k].slice() : fields[k]; });
  if (Object.prototype.hasOwnProperty.call(fields, 'publish_default') && _bdPublishData) {
    _bdPublishData = Object.assign({}, _bdPublishData, { brand_spec: fields.publish_default });
  }
  if (b) {
    var nameEl = document.querySelector('#brandDetailPaneHeader [data-brand-name]');
    if (nameEl) nameEl.textContent = b.name || '';
    var badge = $('brandDetailStatusBadge'); if (badge) badge.innerHTML = _bdStatusBadgeHtml(b.status);
  }
  renderBrandDetailSummaryLine();
  brandDetailMarkClean();
  toast('브랜드 정보를 저장했습니다.');
  if (typeof refreshPane === 'function') refreshPane('brands');
}

// 탭을 주어진 값으로 다시 그린다(되돌리기·다시 불러오기) — 🔴 이 탭만. 담당자·계정 탭·메모는 건드리지 않는다
async function _bdRenderInfoPane(b, publishData) {
  var pane = $('brandDetailPane_info');
  var brandId = _brandsCurrentId;
  if (!pane || !b) return;
  pane.innerHTML = _bdInfoPaneHtml(b);
  onBrandCompanyChange();
  brandDetailMarkClean();
  if (publishData !== undefined) await _bdLoadPublishBox(brandId, publishData);
  else _bdLoadPublishBox(brandId, undefined);
  if (_brandsCurrentId === brandId) brandDetailMarkClean();
}

// 「되돌리기」 — 확인 없이 연(또는 저장한) 순간 값으로(A4)
function revertBrandInfoTab() {
  if (_bdInfoBusy || !_brandDetailBrand) return;
  _bdRenderInfoPane(_brandDetailBrand, _bdPublishData);
}

// ══ 저장 충돌 확인 (조각 8 — 피그마 a03-10 · 사양서 4-6 · D5) ══════════════════════
//   575 가 stale 을 주면 연다 — 서버 값을 다시 받아 **내가 보낸 칸 중 값이 달라진 칸만** 표로(기본값 4).
//   누가·언제 = brand_profile_history(이름·SNS·회사·상태) · 공개 기본 열은 544 표의 저장자·시각(575 가 읽기 함수에 더함).
//   이력 조회가 실패하면 한 줄 안내 + 같은 두 단추.
var _bdConflict = null;   // {ch, fresh, freshPublish, nowPrev}
var _bdConflictReturnFocus = null;
async function openBrandInfoConflictModal(ch) {
  var brandId = _brandsCurrentId;
  var needPublish = Object.prototype.hasOwnProperty.call(ch.fields, 'publish_default');
  var histKeys = ch.keys.filter(function(k){ return k !== 'publish_default'; });
  var res = await Promise.all([
    fetchBrandById(brandId),
    needPublish ? fetchBrandPublishDefaults(brandId) : Promise.resolve(undefined),
    histKeys.length ? fetchBrandProfileHistory(brandId, histKeys) : Promise.resolve([])
  ]);
  if (_brandsCurrentId !== brandId || !brandDetailIsTabsPage()) return;
  var fresh = res[0], freshPublish = res[1], hist = res[2];
  if (!fresh || (needPublish && !freshPublish)) {
    toast('다른 사람이 그사이 이 브랜드 정보를 고쳤습니다. 지금 값을 불러오지 못했습니다 — 잠시 후 다시 「저장」을 눌러 주십시오.', 'error');
    return;
  }
  var nowPrev = _bdInfoPrevFromBrand(fresh, needPublish ? freshPublish : undefined);
  var rows = [];
  ch.keys.forEach(function(k) {
    var nowV = nowPrev[k], oldV = ch.prev[k];
    var differs = (k === 'publish_default') ? (_bdSpecKey(nowV) !== _bdSpecKey(oldV)) : (_bdNorm(nowV) !== _bdNorm(oldV));
    if (!differs) return;
    var who = null, when = null;
    if (k === 'publish_default') { who = freshPublish.brand_updated_by_name || null; when = freshPublish.brand_updated_at || null; }
    else if (Array.isArray(hist)) {
      var h = hist.find(function(x){ return x.field_name === k; });
      if (h) { who = h.changed_by_name || (h.change_source === 'system' ? '시스템' : h.change_source === 'brand' ? '브랜드 담당자' : '관리자'); when = h.changed_at; }
    }
    rows.push({ key: k, now: nowV, mine: ch.fields[k], who: who, when: when });
  });
  _bdConflict = { ch: ch, fresh: fresh, freshPublish: freshPublish, nowPrev: nowPrev };
  _bdRenderConflictModal(rows, hist === null);
}
function _bdInfoValueText(k, v) {
  if (k === 'publish_default') return Array.isArray(v) ? '이 브랜드만 따로 정함 · ' + v.length + '개 열' : '전체 기본값 따르기';
  if (k === 'status') return v === 'archived' ? '비활성' : '활성';
  if (k === 'company_id') {
    if (!v) return '(회사 미지정)';
    var co = (_brandFormCompanies || []).find(function(c){ return c.id === v; });
    return co ? (co.name_ko || co.name_ja || co.name_en || v) : v;
  }
  return (v === null || v === undefined || v === '') ? '(비어 있음)' : String(v);
}
function _bdRenderConflictModal(rows, histFailed) {
  var ov = $('brandInfoConflictModal');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'brandInfoConflictModal';
    ov.className = 'modal-overlay';
    ov.style.zIndex = '800';
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-labelledby', 'brandInfoConflictTitle');
    ov.addEventListener('keydown', function(e) { _bdModalKeydown(ov, e, brandInfoConflictClose); });
    document.body.appendChild(ov);
  }
  if (!ov.classList.contains('open')) _bdConflictReturnFocus = document.activeElement;
  var table = '';
  if (!histFailed && rows.length) {
    table = '<div class="admin-table-wrap bd-people-wrap" style="margin-bottom:6px"><table class="data-table bd-conflict-table">'
      + '<thead><tr><th>칸</th><th>지금 저장된 값</th><th>내가 고친 값</th><th>누가</th><th>언제</th></tr></thead><tbody>'
      + rows.map(function(r) {
          return '<tr><td class="bd-people-name">' + esc(BRAND_INFO_LABELS[r.key] || r.key) + '</td>'
            + '<td>' + esc(_bdInfoValueText(r.key, r.now)) + '</td>'
            + '<td>' + esc(_bdInfoValueText(r.key, r.mine)) + '</td>'
            + '<td>' + esc(r.who || '—') + '</td>'
            + '<td>' + esc(r.when ? formatDateTime(r.when) : '—') + '</td></tr>';
        }).join('')
      + '</tbody></table></div>';
  }
  ov.innerHTML = '<div class="modal" style="max-width:640px;border-radius:16px;margin:auto">'
    + '<div class="modal-body" style="padding:24px 24px 20px">'
      + '<div id="brandInfoConflictTitle" class="bd-acct-title">다른 사람이 그사이 이 브랜드 정보를 고쳤습니다</div>'
      + (table
          ? '<div class="bd-acct-text">이 화면을 연 뒤 아래 칸이 바뀌었습니다. 지금 저장하면 그 값이 내 값으로 바뀝니다.</div>' + table
          : '<div class="bd-acct-text">이 화면을 연 뒤 다른 사람이 같은 칸을 고쳤습니다. 지금 저장하면 그 값이 내 값으로 바뀝니다.</div>')
      + _bdBullets([
          '「다시 불러와서 확인」을 누르면 내가 고친 값은 버리고, 지금 저장된 값으로 이 탭을 다시 채웁니다.',
          '「내 값으로 저장」을 누르면 위 칸을 내 값으로 저장합니다.'
        ])
      + '<div class="bd-acct-btns">'
        + '<button type="button" class="btn btn-ghost" onclick="reloadBrandInfoFromServer()">다시 불러와서 확인</button>'
        + '<button type="button" class="btn btn-primary" onclick="brandInfoConflictSaveMine()">내 값으로 저장</button>'
      + '</div>'
    + '</div></div>';
  ov.classList.add('open');
  var first = ov.querySelector('.bd-acct-btns .btn'); if (first) setTimeout(function(){ first.focus(); }, 30);
}
function brandInfoConflictClose() {
  _bdConflict = null;
  var ov = $('brandInfoConflictModal'); if (ov) ov.classList.remove('open');
  var back = _bdConflictReturnFocus; _bdConflictReturnFocus = null;
  if (back && document.contains(back) && typeof back.focus === 'function') back.focus();
}
// 「다시 불러와서 확인」 — 이 탭만 서버 값으로 다시 채운다(내 변경은 버린다 — 창 문구에 적음)
async function reloadBrandInfoFromServer() {
  var c = _bdConflict;
  brandInfoConflictClose();
  if (!c || !_brandDetailBrand) return;
  BRAND_INFO_KEYS.concat(['company_name']).forEach(function(k){ _brandDetailBrand[k] = c.fresh[k]; });
  _brandInfoPrev = _bdInfoPrevFromBrand(_brandDetailBrand, undefined);
  var nameEl = document.querySelector('#brandDetailPaneHeader [data-brand-name]');
  if (nameEl) nameEl.textContent = _brandDetailBrand.name || '';
  var badge = $('brandDetailStatusBadge'); if (badge) badge.innerHTML = _bdStatusBadgeHtml(_brandDetailBrand.status);
  renderBrandDetailSummaryLine();
  // 공개 기본 열은 다시 받은 값이 있으면 그것으로, 없으면 다시 받는다
  await _bdRenderInfoPane(_brandDetailBrand, c.freshPublish !== undefined ? c.freshPublish : undefined);
  toast('지금 저장된 값으로 다시 불러왔습니다.');
}
// 「내 값으로 저장」 — 다시 받은 서버 값을 새 연 순간 값으로 삼아 같은 칸을 다시 저장
function brandInfoConflictSaveMine() {
  var c = _bdConflict;
  brandInfoConflictClose();
  if (!c) return;
  var prev = {};
  c.ch.keys.forEach(function(k){ prev[k] = c.nowPrev[k]; });
  // 다른 칸의 연 순간 값도 서버 값으로 맞춘다 — 다음 저장이 같은 충돌을 다시 만나지 않게
  _brandInfoPrev = Object.assign({}, _brandInfoPrev || {}, c.nowPrev);
  saveBrandInfoTab({ fields: c.ch.fields, prev: prev });
}

// ══ 담당자·계정 탭 (조각 10 — a03-00 · 00a · 00f · 91 · 92 · 93 ③④) ══════════════════════
//   표 = 담당자 줄 ∪ 계정 줄(대표·멤버). 같은 사람은 이메일로 묶는다(A8 — 앞뒤 공백·대소문자 무시, `_brandAccountNormEmail`).
//   초대 줄은 없다 — 숫자로만(§16-5 11번).
//   🔴 이 탭의 다시 그리기는 **이 영역(#bdPeopleCard)·탭 숫자·요약 줄만** — 브랜드 정보 영역을 건드리지 않는다(사양서 6절 ②).
//   🔴 계정 버튼 표시 판정은 서버 상태 조회의 `can_manage` 하나(작업표 기본값 6). 조회 실패면 버튼 없음 — 실패를 「권한 있음」·「계정 없음」으로 그리지 않는다.
//   「브랜드 연결 추가」(a03-04)·연결 요청 칩(a03-91a)은 조각 13 — 계정이 없는 대표 줄(ⓐ)에만. 요청 대기 중에는 ⓐ 단추 대신 「다시 보내기」·「요청 취소」.
//   계정 동작(만들기·다시 보내기·대표 바꾸기·해제·상한)은 조각 11 — 버튼은 `bdAccountAction(동작, 인자)` 한 곳으로 모은다.
var BRAND_SETUP_LINK_HOURS = 24;   // 설정 메일 링크 유효 시간(인증 설정 Email OTP Expiration 86400 — 표시 전용, 작업표 기본값 7)
var _bdPeopleReq = 0;

function _bdPeoplePaneHtml(b) {
  return '<div id="bdPeopleCard" class="bd-card"></div>';
}

// 대표 계정 상태 ⓐ~ⓔ — 판정은 이 한 곳. null = 상태를 모름(조회 실패·아직)
function bdOwnerState(st) {
  if (!st || typeof st !== 'object') return null;
  if (st.status === 'none') return 'none';
  if (st.status === 'mail_pending') return 'mail_pending';
  if (st.status === 'active') return 'active';
  if (st.status === 'mail_sent') {
    var sent = st.setup_mail_sent_at ? new Date(st.setup_mail_sent_at).getTime() : NaN;
    if (!isNaN(sent) && Date.now() > sent + BRAND_SETUP_LINK_HOURS * 3600 * 1000) return 'link_expired';
    return 'mail_sent';
  }
  return null;
}

// 연결 요청(조각 13 — 578 owner_link_request) {request_id, status: pending|expired|declined|cancelled, email, sent_at, expires_at} | null
//   🔴 pending 은 서버가 「만료 전」으로 판정한 값 — 화면이 시각으로 다시 가르지 않는다
function bdLinkRequest(st) {
  var r = st && typeof st === 'object' ? st.owner_link_request : null;
  return (r && typeof r === 'object' && r.status) ? r : null;
}
function bdLinkPending(st) { var r = bdLinkRequest(st); return !!(r && r.status === 'pending'); }

// 줄 합치기 → [{kind:'owner'|'member'|'contact', contact, member}] — 대표 → 멤버 → 담당자 순
function bdMergePeopleRows(contacts, st) {
  var norm = (typeof _brandAccountNormEmail === 'function') ? _brandAccountNormEmail : function(v){ return String(v || '').trim().toLowerCase(); };
  var members = (st && Array.isArray(st.members)) ? st.members.slice() : [];
  var used = {};
  var rows = [];
  var ownerState = bdOwnerState(st);
  (Array.isArray(contacts) ? contacts : []).forEach(function(c) {
    if (!c) return;
    var em = norm(c.email);
    var mi = em ? members.findIndex(function(m, i){ return !used[i] && norm(m.email) === em; }) : -1;
    var m = mi >= 0 ? members[mi] : null;
    if (mi >= 0) used[mi] = true;
    var kind;
    if (m) kind = (m.role === 'owner') ? 'owner' : 'member';
    // 계정이 없는 브랜드(ⓐ)·상태를 모를 때는 대표 표시 줄이 대표 줄이다. 대표 계정이 따로 있는데 이메일이 다르면 그 줄은 담당자 줄
    else if (c.is_primary && (ownerState === 'none' || ownerState === null)) kind = 'owner';
    else kind = 'contact';
    rows.push({ kind: kind, contact: c, member: m });
  });
  members.forEach(function(m, i) { if (!used[i]) rows.push({ kind: m.role === 'owner' ? 'owner' : 'member', contact: null, member: m }); });
  var rank = { owner: 0, member: 1, contact: 2 };
  return rows.map(function(r, i){ return { r: r, i: i }; })
    .sort(function(a, b){ return (rank[a.r.kind] - rank[b.r.kind]) || (a.i - b.i); })
    .map(function(x){ return x.r; });
}

// 담당자·계정 탭을 누를 때마다 — 브랜드 담당자 목록과 계정 상태를 새로 받는다(다른 창·서버의 대표 이동 반영, 사양서 6절 ③)
function brandDetailOnPeopleTab() { bdReloadPeopleTab(); }

async function bdReloadPeopleTab() {
  var id = _brandsCurrentId;
  if (!id || !brandDetailIsTabsPage()) return;
  var req = ++_bdPeopleReq;
  _brandDetailAccountReq++;   // 앞서 떠난 상태 조회 결과는 버린다
  var res = await Promise.all([
    fetchBrandById(id),
    (typeof fetchBrandAccountStatus === 'function' ? fetchBrandAccountStatus(id) : Promise.resolve(null))
  ]);
  if (req !== _bdPeopleReq || _brandsCurrentId !== id) return;
  var b = res[0];
  // 브랜드를 못 받으면 담당자 목록은 앞의 것 그대로(빈 목록으로 그리지 않는다)
  if (b && _brandDetailBrand) {
    _brandDetailBrand.contacts = b.contacts;
    _brandDetailBrand.primary_contact_name = b.primary_contact_name;
    _brandDetailBrand.primary_phone = b.primary_phone;
    _brandDetailBrand.primary_email = b.primary_email;
    // 화면 사본(_brandFormContacts — 요약 줄·담당자 모달이 쓴다)도 서버 값으로. 브랜드 정보 탭 입력칸은 건드리지 않는다
    _initBrandFormContacts(b);
  }
  _brandDetailAccountStatus = res[1];
  renderBrandDetailSummaryLine();
  renderBrandPeopleTab();
  if (typeof bdSanctionSyncHead === 'function') bdSanctionSyncHead();
  _bdContactRerenderIfOpen();   // 담당자 창이 열려 있으면 잠금·대표 표시를 새 상태로(쳐 둔 값은 그대로)
}

function renderBrandPeopleTab() {
  var card = $('bdPeopleCard');
  if (!card) return;
  var st = _brandDetailAccountStatus;           // undefined 아직 · null 실패 · 객체
  var known = !!(st && typeof st === 'object');
  var canManage = known && st.can_manage === true;
  var ownerState = bdOwnerState(st);
  var rows = bdMergePeopleRows(_brandFormContacts, known ? st : null);
  // 대표 줄이 없는 브랜드에 연결 요청이 있으면 그 칩을 그릴 대표 자리를 만든다(요청이 표에서 사라지지 않게)
  var lreq = known ? bdLinkRequest(st) : null;
  if (lreq && ownerState === 'none' && !rows.some(function(r){ return r.kind === 'owner'; })) {
    rows.unshift({ kind: 'owner', contact: null, member: { name: '', email: lreq.email || '' } });
  }
  var icon = function(name) { return '<span class="material-icons-round notranslate" translate="no" style="font-size:14px">' + name + '</span>'; };

  // 탭 숫자 — 표 줄 수(담당자 ∪ 계정)
  var cnt = $('brandDetailTab_people') && $('brandDetailTab_people').querySelector('.tab-count');
  if (cnt) cnt.textContent = '(' + rows.length + ')';
  // 계정이 연결된 브랜드는 서버가 삭제를 거부한다(528) — 「…」 의 「삭제」를 뗀다(보이는데 누르면 실패 방지)
  if (known && Array.isArray(st.members) && st.members.length) {
    var del = $('brandDetailDeleteBtn');
    if (del) { del.remove(); brandDetailSyncMoreMenu(); }
  }

  var seat = (known && st.member_limit !== undefined && st.member_limit !== null && st.seat_used !== undefined && st.seat_used !== null)
    ? '멤버 ' + esc(String(st.seat_used)) + ' / ' + esc(String(st.member_limit)) + '명'
      + ((Number(st.pending_invite_count) || 0) > 0 ? ' · 초대 대기 ' + (Number(st.pending_invite_count) || 0) + ' 포함' : '')
    : '';
  var head = '<div class="bd-card-head">'
    + '<span class="bd-card-title">담당자 · 브랜드 페이지 계정</span>'
    + '<div class="bd-card-actions">'
      + (seat ? '<span class="bd-seat">' + seat + '</span>' : '')
      + (canManage ? '<button type="button" class="btn btn-ghost btn-sm" onclick="bdAccountAction(\'member_limit\')">멤버 상한 바꾸기</button>' : '')
      + '<button type="button" class="btn btn-ghost btn-sm" onclick="bdOpenContactModal(null)" style="display:inline-flex;align-items:center;gap:3px">' + icon('add') + '담당자 추가</button>'
    + '</div></div>';

  var lead = '';
  if (known) {
    lead = canManage
      ? (ownerState === 'none'
          ? (bdLinkPending(st)
              ? '연결 요청을 보냈습니다 — 받는 사람이 24시간 안에 수락하면 이 브랜드의 대표 담당자가 됩니다. 그동안 대표 담당자 줄은 바꿀 수 없습니다.'
              : '대표 담당자 계정을 만들면 비밀번호 설정 메일이 갑니다. 이미 다른 브랜드 계정이 있는 이메일이면 「브랜드 연결 추가」로 연결을 요청합니다(본인이 수락해야 연결).')
          :'멤버는 대표 담당자가 초대합니다. 관리자는 대표 담당자 계정 만들기 · 대표 담당자 바꾸기 · 해제 · 멤버 상한을 합니다.')
      : '멤버는 대표 담당자가 초대합니다. 계정 만들기 · 다시 보내기 · 대표 담당자 바꾸기 · 해제 · 멤버 상한은 「브랜드 페이지 계정 관리」 권한이 있는 관리자만 할 수 있습니다.';
  }
  var notes = lead ? '<div class="bd-card-lead">' + esc(lead) + '</div>' : '';
  // 대표 줄이 없거나 이메일이 비면 계정을 만들 수 없다 — 권한이 있을 때만 안내(D15)
  var ownerRow = rows.find(function(r){ return r.kind === 'owner'; });
  if (canManage && ownerState === 'none' && !bdLinkPending(st) && (!ownerRow || !ownerRow.contact || !String(ownerRow.contact.email || '').trim())) {
    notes += '<div class="bd-card-note">먼저 「+ 담당자 추가」로 대표 담당자를 등록하십시오.</div>';
  }

  if (!rows.length) {
    card.innerHTML = head + notes + '<div class="bd-empty">담당자가 없습니다. 「+ 담당자 추가」를 눌러 등록하십시오.</div>';
    return;
  }
  card.innerHTML = head + notes
    + '<div class="admin-table-wrap bd-people-wrap"><table class="data-table bd-people-table">'
      + '<thead><tr><th>이름</th><th>이메일</th><th>역할</th><th>브랜드 페이지 계정</th><th style="text-align:right">관리</th></tr></thead>'
      + '<tbody>' + rows.map(function(r){ return _bdPeopleRowHtml(r, st, known, canManage, ownerState); }).join('') + '</tbody>'
    + '</table></div>';
}

function _bdChip(cls, text) { return '<span class="bd-chip' + (cls ? ' ' + cls : '') + '">' + esc(text) + '</span>'; }

function _bdPeopleRowHtml(r, st, known, canManage, ownerState) {
  var c = r.contact, m = r.member;
  var name = (c && c.name) || (m && m.name) || '';
  var email = (c && c.email) || (m && m.email) || '';
  var sub = function(t) { return '<div class="bd-sub">' + esc(t) + '</div>'; };
  var btn = function(label, action, arg, cls) {
    return '<button type="button" class="btn btn-sm ' + (cls || 'btn-ghost') + '" onclick="bdAccountAction(\'' + action + '\'' + (arg ? ',' + jsStr(arg) : '') + ')">' + esc(label) + '</button>';
  };
  var role, acct = '', acts = [];
  // 「수정」 — 담당자 정보가 있는 줄에만(a03-08, 조각 12). 권한과 무관
  var editBtn = c ? '<button type="button" class="btn btn-ghost btn-sm" onclick="bdOpenContactModal(' + jsStr(c.id || '') + ')">수정</button>' : '';

  if (r.kind === 'owner') {
    role = (ownerState === 'active') ? _bdChip('is-owner', '대표') : _bdChip('is-owner-pending', '대표 담당자');
    if (!known) {
      acct = (st === null)
        ? _bdChip('is-error', '확인 불가') + sub('계정 상태를 불러오지 못했습니다')
        : '<span class="bd-muted">불러오는 중…</span>';
      if (st === null) acts.push('<button type="button" class="btn btn-ghost btn-sm" onclick="bdReloadPeopleTab()">다시 불러오기</button>');
    } else if (ownerState === 'none') {
      // 연결 요청(조각 13 · a03-91a) — 서버가 대표가 생기면 늘 null 로 준다(연결 요청 사양서 4-2)
      var lr = bdLinkRequest(st);
      var lrDevLink = (typeof _brandAccountDevLinks !== 'undefined') ? _brandAccountDevLinks[_brandsCurrentId] : null;
      if (lr && lr.status === 'pending') {
        acct = _bdChip('is-sent', '연결 요청 보냄')
          + sub((lr.email ? lr.email + ' · ' : '') + (lr.expires_at ? formatDateTime(lr.expires_at) + '까지' : ''));
        if (lrDevLink) acct += '<div class="bd-devlink"><button type="button" class="btn btn-ghost btn-xs" onclick="copyBrandAccountDevLink(' + jsStr(_brandsCurrentId) + ')">개발서버 링크 복사</button></div>';
        if (canManage) {
          acts.push(btn('다시 보내기', 'link_resend'));
          acts.push(btn('요청 취소', 'link_cancel', lr.request_id || '', 'btn-ghost bd-danger'));
        }
      } else {
        var lrText = lr ? { expired: '연결 요청 만료됨', declined: '연결 요청 거절됨', cancelled: '연결 요청 취소됨' }[lr.status] : null;
        acct = lrText
          ? _bdChip(lr.status === 'expired' ? 'is-warn' : '', '계정 없음 · ' + lrText)
            + sub((lr.email ? lr.email + ' · ' : '') + (lr.sent_at ? formatDateTime(lr.sent_at) + ' 보냄' : ''))
          : _bdChip('', '계정 없음');
        if (canManage && c && String(c.email || '').trim()) acts.push(btn('계정 만들기', 'create', null, 'btn-primary'));
        if (canManage) acts.push(btn('브랜드 연결 추가', 'link_add'));
      }
    } else {
      var sentAt = st.setup_mail_sent_at ? new Date(st.setup_mail_sent_at) : null;
      var self = st.setup_mail_sent_by === 'self' ? ' (본인 요청)' : '';
      if (ownerState === 'mail_pending') {
        acct = _bdChip('', '메일 미발송') + sub('계정은 만들었으나 메일 발송 실패');
      } else if (ownerState === 'mail_sent') {
        var until = sentAt ? new Date(sentAt.getTime() + BRAND_SETUP_LINK_HOURS * 3600 * 1000) : null;
        acct = _bdChip('is-sent', '메일 보냄')
          + (sentAt ? sub(formatDateTime(sentAt.toISOString()) + ' · ' + formatDateTime(until.toISOString()) + '까지 유효(예상)' + self) : '');
      } else if (ownerState === 'link_expired') {
        acct = _bdChip('is-warn', '링크 만료 · 설정 안 함') + (sentAt ? sub(formatDateTime(sentAt.toISOString()) + ' 보냄' + self) : '');
      } else if (ownerState === 'active') {
        acct = _bdChip('is-active', '사용 중' + (st.password_set_at ? ' · ' + formatDate(st.password_set_at) + ' 설정' : ''))
          + ((m && m.last_active_at) ? sub('마지막 접속 ' + formatDateTime(m.last_active_at)) : '');
      }
      // 개발서버 「메일 대신 링크」(조각 11 — 설정 메일 함수의 두 겹 잠금이 개발서버에서만 돌려준다). 설정이 끝나면 지운다
      var devLink = (typeof _brandAccountDevLinks !== 'undefined') ? _brandAccountDevLinks[_brandsCurrentId] : null;
      if (ownerState === 'active') { if (devLink) delete _brandAccountDevLinks[_brandsCurrentId]; }
      else if (devLink) acct += '<div class="bd-devlink"><button type="button" class="btn btn-ghost btn-xs" onclick="copyBrandAccountDevLink(' + jsStr(_brandsCurrentId) + ')">개발서버 링크 복사</button></div>';
      if (canManage) {
        if (ownerState === 'active') acts.push(btn('대표 담당자 바꾸기', 'owner_change'));
        else acts.push(btn('다시 보내기', 'resend', null, ownerState === 'link_expired' ? 'btn-primary' : 'btn-ghost'));
        acts.push(btn('해제', 'release', st.owner_auth_id || (m && m.auth_id) || '', 'btn-ghost bd-danger'));
      }
      // 이용 제한(제한 10 — admin-brand-sanction.js): 배지는 누구에게나, 단추·「…」 는 사용 중 대표 줄 + can_restrict 만
      if (m && typeof bdRestrictionBadgeHtml === 'function') {
        acct += bdRestrictionBadgeHtml(m.restriction);
        if (ownerState === 'active') acts.push(bdRestrictionActionsHtml(m, st));
      }
    }
  } else if (r.kind === 'member') {
    role = _bdChip('is-member', '멤버');
    acct = _bdChip('is-active', '사용 중') + ((m && m.last_active_at) ? sub('마지막 접속 ' + formatDateTime(m.last_active_at)) : '');
    if (canManage && m && m.auth_id) acts.push(btn('해제', 'release', m.auth_id, 'btn-ghost bd-danger'));
    if (m && typeof bdRestrictionBadgeHtml === 'function') {
      acct += bdRestrictionBadgeHtml(m.restriction);
      acts.push(bdRestrictionActionsHtml(m, st));
    }
  } else {
    role = _bdChip('is-member', '담당자');
    acct = !known
      ? '<span class="bd-muted">' + (st === null ? '확인 불가' : '불러오는 중…') + '</span>'
      : _bdChip('', ownerState === 'none' ? '계정 없음 — 대표 담당자가 생기면 초대' : '계정 없음 — 대표 담당자가 초대');
  }
  return '<tr>'
    + '<td class="bd-people-name">' + (name ? esc(name) : '<span class="bd-muted">이름 없음</span>') + '</td>'
    + '<td>' + (email ? esc(email) : '<span class="bd-muted">—</span>') + '</td>'
    + '<td>' + role + '</td>'
    + '<td>' + acct + '</td>'
    + '<td><div class="bd-row-actions">' + editBtn + acts.join('') + '</div></td>'
  + '</tr>';
}

// 계정 동작 입구 — 조각 11 이 채운다(만들기·다시 보내기·대표 바꾸기·해제·멤버 상한)
function bdAccountAction(action, arg) {
  if (typeof bdRunAccountAction === 'function') return bdRunAccountAction(action, arg);
  toast('이 기능은 준비 중입니다.', 'warn');
}
// 담당자 추가·수정 모달 입구 — 조각 12 가 채운다(a03-08)
function bdOpenContactModal(contactId) {
  if (typeof openBrandContactModal === 'function') return openBrandContactModal(contactId);
  toast('담당자 추가·수정 창은 준비 중입니다.', 'warn');
}

// 옛 「저장」 성공 뒤(조각 5 임시) — 저장한 값으로 머리·요약 줄·기준값을 맞춘다.
//   ⚠️ 조각 7 부터 새 페이지는 saveBrandDetail 을 부르지 않아 이 함수가 돌 일이 없다(saveBrandDetail 의 typeof 호출만 남음) — 출시 뒤 조각 18 에서 함께 지운다
function brandDetailAfterLegacySave(brandId, patch) {
  if (!brandDetailIsTabsPage() || brandId !== _brandsCurrentId || !_brandDetailBrand) return;
  Object.assign(_brandDetailBrand, patch || {});
  var badge = $('brandDetailStatusBadge');
  if (badge) badge.innerHTML = _bdStatusBadgeHtml(_brandDetailBrand.status);
  renderBrandDetailSummaryLine();
  renderBrandPeopleTab();
  brandDetailMarkClean();
}

// ── 회사 카드 끝 줄 「수정 / 보기」(조각 9 — a03-07·07b). renderBrandCompanyInfoCardInner 가 새 페이지 안일 때 부른다 ──
function brandDetailCompanyCardFootHtml(c) {
  var canEdit = (typeof canEditCompanies === 'function') && canEditCompanies() && c.status !== 'archived';
  return '<div style="margin-top:6px;font-size:11px;color:var(--muted)">이 정보는 「회사 관리」에 있습니다. '
    + '<button type="button" class="bd-link-btn" onclick="openBrandCompanyEdit()">' + (canEdit ? '수정' : '보기') + '</button></div>';
}

// 회사 정보 수정 모달 — 🔴 회사 값은 아이디로 서버에서 새로 받는다(「회사 관리」 목록 보관값에 기대면 빈 폼으로 덮는다).
//   고른 회사 = 선택칸의 **지금 값**(저장 전 바꿨으면 새로 고른 회사 — 사양서 4-1). 받기 실패면 열지 않는다.
//   매니저·보관 회사 → 읽기 전용(a03-07b) — 보관 회사를 브랜드 상세에서 되살리지 않는다(4-4)
async function openBrandCompanyEdit() {
  var sel = $('brandFormCompanyId');
  var companyId = sel ? sel.value : '';
  if (!companyId || typeof openCompanyModal !== 'function') return;
  var brandId = _brandsCurrentId;
  var res = await Promise.all([
    fetchCompanyById(companyId),
    (typeof fetchCompanyActiveBrandNames === 'function' ? fetchCompanyActiveBrandNames(companyId) : Promise.resolve(null))
  ]);
  if (_brandsCurrentId !== brandId || !brandDetailIsTabsPage()) return;
  var company = res[0], names = res[1];
  if (!company) { toast('회사 정보를 불러오지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error'); return; }
  var archived = company.status === 'archived';
  var canEdit = (typeof canEditCompanies === 'function') && canEditCompanies() && !archived;
  var notice;
  if (!canEdit) {
    notice = archived
      ? '보관된 회사라 여기서는 보기만 합니다. 다시 쓰려면 「회사 관리」에서 활성으로 바꿔 주십시오.'
      : '회사 정보는 캠페인 관리자 이상이 고칠 수 있습니다. 이 화면은 보기만 합니다.';
  } else if (Array.isArray(names) && names.length) {
    // N = 그 회사의 활성 브랜드 수 — 브랜드 화면과 같은 기준(작업표 M5)
    var max = (typeof COMPANY_BRAND_NAMES_MAX !== 'undefined') ? COMPANY_BRAND_NAMES_MAX : 6;
    var shown = names.slice(0, max).join(' · ') + (names.length > max ? ' 외 ' + (names.length - max) + '개' : '');
    notice = '이 회사에 속한 브랜드 ' + names.length + '개(' + shown + ')에 함께 바뀝니다.';
  } else {
    notice = '이 회사 정보를 바꾸면 이 회사에 속한 브랜드 모두에 함께 바뀝니다.';
  }
  openCompanyModal(companyId, { company: company, notice: notice, readOnly: !canEdit, onSaved: _bdAfterCompanySaved });
}

// 회사 저장 뒤 — 회사 카드·선택칸 이름·요약 줄만. 🔴 고치던 브랜드 값(선택칸의 지금 값 포함)은 그대로
function _bdAfterCompanySaved(company) {
  if (!company || !company.id) return;
  var list = _brandFormCompanies || [];
  var i = list.findIndex(function(c){ return c.id === company.id; });
  if (i >= 0) list[i] = Object.assign({}, list[i], company); else list.push(company);
  _brandFormCompanies = list;
  var sel = $('brandFormCompanyId');
  if (sel) _rebuildBrandCompanySelect(sel.value);
  onBrandCompanyChange();
  renderBrandDetailSummaryLine();
  // 회사 관리 목록이 받아 둔 값이 있으면 그것도 새로(숨은 목록 — 다음에 열 때 새 이름)
  if (typeof _companiesCache !== 'undefined' && Array.isArray(_companiesCache) && _companiesCache.length && typeof refreshPane === 'function') refreshPane('companies');
}

// ══ 떠날 때 확인 (조각 6 — a03-09) ══════════════════════════════════════
//   판정 = 브랜드 정보 탭 칸의 **연(또는 저장한) 순간 값과 지금 값 비교**(캠페인 폼 campDirty 와 같은 스냅샷 방식).
//   탭 전환은 떠나는 것이 아니다. 가로채는 자리 넷(작업표 조각 6): ①사이드바 navAdminPaneReload(admin/app.js)
//   ②브라우저 뒤로가기 popstate(admin-core.js — 주소가 이미 바뀐 뒤라 되돌리고 묻는다) ③openBrandDetailTabs 진입
//   ④「← 목록」·캠페인 줄(brandDetailOpenCampProgress). 그 밖에 「새 브랜드」 모달·오리엔시트 「신규 캠페인 발행」도 같은 확인.
//   🔴 switchAdminPane 안에는 걸지 않는다 — 저장 뒤 복귀·권한 리다이렉트가 지나간다(campLeaveGuard 와 같은 원칙).

// 칸 스냅샷 — {열쇠: 값}. 공개 기본 열 칸도 든다(조각 7 — 탭 「저장」이 함께 저장). 그 칸은 늦게 그려져 _bdLoadPublishBox 가 기준값에 더한다
function _bdSnapshot() {
  var pane = $('brandDetailPane_info');
  var snap = {};
  if (!pane) return snap;
  var els = pane.querySelectorAll('input, select, textarea');
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    var key = el.id || ((el.name || el.tagName) + '#' + i);
    snap[key] = (el.type === 'checkbox' || el.type === 'radio') ? (el.checked ? '1' : '0') : String(el.value);
  }
  return snap;
}

function brandDetailMarkClean() {
  _bdBaseline = $('brandDetailPane_info') ? _bdSnapshot() : null;
  _bdSyncDirtyUi();
}

function brandDetailDirty() {
  if (!brandDetailIsTabsPage() || !_bdBaseline) return false;
  var now = _bdSnapshot();
  var keys = Object.keys(now);
  for (var i = 0; i < keys.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(_bdBaseline, keys[i])) continue;   // 나중에 생긴 칸(없음 — 방어)
    if (_bdBaseline[keys[i]] !== now[keys[i]]) return true;
  }
  return false;
}

function _bdSyncDirtyUi() {
  var dirty = brandDetailDirty();
  var dot = document.querySelector('#brandDetailTab_info .brand-detail-dirty-dot');
  if (dot) dot.style.display = dirty ? '' : 'none';
  var bar = $('brandInfoSaveBar');
  if (bar) bar.style.display = dirty ? '' : 'none';
}

function _bdBindInfoPane() {
  var pane = $('brandDetailPane_info');
  if (!pane) return;
  pane.addEventListener('input', _bdSyncDirtyUi);
  pane.addEventListener('change', _bdSyncDirtyUi);
}

function brandDetailLeaveGuard(go) {
  if (!brandDetailDirty()) { go(); return; }
  _bdLeaveGo = go;
  var ov = $('brandDetailLeaveModal');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'brandDetailLeaveModal';
    ov.className = 'modal-overlay';
    ov.style.zIndex = '800';   // 오리엔시트 상세·발행 창 위에서도 보이게
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-labelledby', 'brandDetailLeaveTitle');
    ov.innerHTML = '<div class="modal" style="max-width:480px;border-radius:16px;margin:auto">'
      + '<div class="modal-body" style="padding:24px 24px 20px">'
        + '<div id="brandDetailLeaveTitle" style="font-size:16px;font-weight:800;color:var(--ink);margin-bottom:10px">저장하지 않은 변경이 있습니다</div>'
        + '<div style="font-size:13px;color:var(--ink);line-height:1.7;margin-bottom:12px">브랜드 정보 탭에서 고친 내용이 아직 저장되지 않았습니다. 이대로 나가면 고친 내용이 사라집니다.</div>'
        + '<ul style="margin:0;padding-left:16px;font-size:12px;color:var(--muted);line-height:1.7">'
          + '<li>「머물기」를 누르면 이 페이지에 그대로 남아요(고치던 값 유지).</li>'
          + '<li>담당자·계정 탭의 동작과 영업 메모는 이미 저장되어 있습니다.</li>'
        + '</ul>'
        + '<div style="display:flex;gap:8px;margin-top:20px;justify-content:flex-end">'
          + '<button type="button" class="btn btn-ghost" id="brandDetailLeaveStayBtn" onclick="brandDetailLeaveStay()">머물기</button>'
          + '<button type="button" class="btn btn-primary" style="background:#c0392b;border-color:#c0392b" onclick="brandDetailLeaveDiscard()">저장하지 않고 나가기</button>'
        + '</div>'
      + '</div></div>';
    document.body.appendChild(ov);
  }
  ov.classList.add('open');
  var stay = $('brandDetailLeaveStayBtn'); if (stay) stay.focus();
}
function brandDetailLeaveStay() {
  _bdLeaveGo = null;
  var ov = $('brandDetailLeaveModal'); if (ov) ov.classList.remove('open');
}
function brandDetailLeaveDiscard() {
  var go = _bdLeaveGo;
  _bdLeaveGo = null;
  var ov = $('brandDetailLeaveModal'); if (ov) ov.classList.remove('open');
  if (typeof go === 'function') go();
}

// 「← 목록」 — 어디서 들어왔든 브랜드 목록(D12)
function brandDetailGoList() {
  brandDetailLeaveGuard(function(){ switchAdminPane('brands'); });
}

// 새로고침·탭 닫기 — 브라우저 기본 경고(문구는 브라우저가 정한다 — A2)
window.addEventListener('beforeunload', function(e) {
  if (typeof brandDetailDirty === 'function' && brandDetailDirty()) { e.preventDefault(); e.returnValue = ''; }
});

// ══ 계정 동작 다섯 (조각 11 — 피그마 a03-01·01a·01b·02·02a·02b·03·03a·05·05a·05b, 토스트 a03-90) ══════
//   입구는 bdAccountAction → bdRunAccountAction 한 곳. 창은 #bdAccountModal 하나를 동작마다 다시 그린다(동적 생성).
//   🔴 모든 동작 뒤 bdReloadPeopleTab() — 이 탭·탭 숫자·요약 줄만 다시 그린다(브랜드 정보 영역 안 건드림).
//   🔴 개발서버 실제 메일 발송 시험은 하지 않는다 — 개발서버는 설정 메일 함수가 메일 대신 링크(dev_link)를 돌려준다(두 겹 잠금).
//   이미 다른 브랜드 계정이 있는 이메일은 새 계정을 만들지 않고 연결 요청 확인 창(a03-01c — 조각 13)으로 넘긴다.
var _bdAcct = null;     // {action, brandId, ...} — 창이 열린 동안의 대상
var _bdAcctBusy = false;
var BD_TOAST_FAIL = '저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.';

function bdRunAccountAction(action, arg) {
  if (!_brandsCurrentId) return;
  var st = _brandDetailAccountStatus;
  if (!(st && typeof st === 'object') || st.can_manage !== true) { toast('브랜드 페이지 계정 관리 권한이 없습니다.', 'warn'); return; }
  if (action === 'create') return openBrandAccountCreateModal();
  if (action === 'resend') return brandAccountResend();
  if (action === 'owner_change') return openBrandOwnerChangeModal(arg || null);
  if (action === 'release') return openBrandAccountReleaseModal(arg);
  if (action === 'member_limit') return openBrandMemberLimitModal();
  if (action === 'link_add') return openBrandLinkRequestModal(null, 'add');
  if (action === 'link_resend') return brandLinkRequestResend();
  if (action === 'link_cancel') return openBrandLinkCancelModal(arg);
}

// ── 창 틀 ──
function _bdAcctModalEl() {
  var ov = $('bdAccountModal');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'bdAccountModal';
    ov.className = 'modal-overlay';
    ov.style.zIndex = '800';
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-labelledby', 'bdAccountModalTitle');
    ov.addEventListener('keydown', function(e) { _bdModalKeydown(ov, e, function(){ if (!_bdAcctBusy) bdAccountModalClose(); }); });
    document.body.appendChild(ov);
  }
  return ov;
}
// 창 공용 키 처리 — Esc 닫기 · 초점을 창 안에 가둔다(키보드로 창 뒤 화면에 빠지지 않게)
function _bdModalKeydown(ov, e, onEscape) {
      if (e.key === 'Escape') { onEscape(); return; }
      if (e.key !== 'Tab') return;
      var f = Array.prototype.filter.call(ov.querySelectorAll('button:not([disabled]), input:not([disabled]), [tabindex]:not([tabindex="-1"])'), function(el){ return el.offsetParent !== null; });
      if (!f.length) return;
      var first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
}
// parts = {title, body(HTML), error(문구), buttons:[{label, onclick, kind:'ghost'|'primary'|'danger', disabled, id}]}
var _bdAcctReturnFocus = null;   // 창을 연 단추 — 닫으면 초점을 돌려준다
function _bdAcctModalRender(parts) {
  var ov = _bdAcctModalEl();
  if (!ov.classList.contains('open')) _bdAcctReturnFocus = document.activeElement;
  var btns = (parts.buttons || []).map(function(b) {
    var style = b.kind === 'danger' ? ' style="background:#c0392b;border-color:#c0392b"' : '';
    return '<button type="button" class="btn ' + (b.kind === 'ghost' ? 'btn-ghost' : 'btn-primary') + '"' + style
      + (b.id ? ' id="' + b.id + '"' : '') + (b.disabled ? ' disabled' : '') + ' onclick="' + b.onclick + '">' + esc(b.label) + '</button>';
  }).join('');
  ov.innerHTML = '<div class="modal" style="max-width:480px;border-radius:16px;margin:auto">'
    + '<div class="modal-body" style="padding:24px 24px 20px">'
      + '<div id="bdAccountModalTitle" class="bd-acct-title">' + esc(parts.title || '') + '</div>'
      + (parts.error ? '<div class="bd-acct-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span><span>' + esc(parts.error) + '</span></div>' : '')
      + (parts.body || '')
      + '<div class="bd-acct-btns">' + btns + '</div>'
    + '</div></div>';
  ov.classList.add('open');
  var focus = ov.querySelector('[data-autofocus]') || ov.querySelector('.bd-acct-btns .btn:not([disabled])');
  if (focus) setTimeout(function(){ focus.focus(); }, 30);
}
function bdAccountModalClose() {
  if (_bdAcctBusy) return;
  _bdAcct = null;
  var ov = $('bdAccountModal'); if (ov) ov.classList.remove('open');
  var back = _bdAcctReturnFocus; _bdAcctReturnFocus = null;
  if (back && document.contains(back) && typeof back.focus === 'function') back.focus();
}
function _bdAcctSetBusy(on, btnId, busyLabel) {
  _bdAcctBusy = !!on;
  var b = btnId ? $(btnId) : null;
  if (b) { b.disabled = !!on; if (on && busyLabel) b.textContent = busyLabel; }
}
function _bdBullets(items) {
  return '<ul class="bd-acct-list">' + items.filter(Boolean).map(function(t){ return '<li>' + esc(t) + '</li>'; }).join('') + '</ul>';
}
// 계정 줄 이름 — 계정 이름 → 같은 이메일 담당자 이름 → 이메일
function _bdMemberName(m) {
  if (!m) return '';
  if (m.name) return m.name;
  var norm = (typeof _brandAccountNormEmail === 'function') ? _brandAccountNormEmail : function(v){ return String(v || '').trim().toLowerCase(); };
  var c = (_brandFormContacts || []).find(function(x){ return x && x.email && norm(x.email) === norm(m.email); });
  return (c && c.name) || m.email || '';
}
function _bdAfterAction(msg, level) {
  if (msg) toast(msg, level);
  bdReloadPeopleTab();
}

// ── ① 계정 만들기 (a03-01 · 01a · 01b) ──
function openBrandAccountCreateModal() {
  var st = _brandDetailAccountStatus;
  if (bdOwnerState(st) !== 'none') { toast('이미 대표 담당자 계정이 있습니다.', 'warn'); bdReloadPeopleTab(); return; }
  if (bdLinkPending(st)) { toast('연결 요청이 기다리는 중이라 계정을 만들 수 없습니다.', 'warn'); bdReloadPeopleTab(); return; }
  // 🔴 받을 이메일은 담당자 목록의 대표 줄로만(D15) — 손으로 넣는 칸을 두지 않는다
  var owner = bdMergePeopleRows(_brandFormContacts, st).find(function(r){ return r.kind === 'owner' && r.contact; });
  var c = owner && owner.contact;
  if (!c || !String(c.email || '').trim()) { toast('먼저 「+ 담당자 추가」로 대표 담당자를 등록하십시오.', 'warn'); return; }
  _bdAcct = { action: 'create', brandId: _brandsCurrentId, contactId: c.id || null, email: String(c.email).trim(), accountMade: false };
  _bdRenderCreateModal(null);
}
function _bdRenderCreateModal(error) {
  var a = _bdAcct; if (!a) return;
  _bdAcctModalRender({
    title: '대표 담당자 계정을 만드시겠습니까?',
    error: error,
    body: '<div class="bd-acct-mailbox"><div class="bd-acct-mailbox-label">비밀번호 설정 메일을 받을 이메일</div>'
        + '<div class="bd-acct-mailbox-email">' + esc(a.email) + '</div></div>'
      + _bdBullets([
          '이 주소가 틀리면 다른 사람이 계정을 받게 됩니다. 받은 문의의 주소와 한 글자씩 맞춰 보십시오.',
          '메일에는 누가(레버브 운영팀) 왜 보냈는지와 개인정보 이용 안내가 함께 들어갑니다.'
        ]),
    buttons: error
      ? [{label:'닫기', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'다시 보내기', kind:'primary', id:'bdAcctSubmit', onclick:'bdAccountCreateSubmit()'}]
      : [{label:'취소', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'메일 보내기', kind:'primary', id:'bdAcctSubmit', onclick:'bdAccountCreateSubmit()'}]
  });
}
var BD_CREATE_FAIL = '메일을 보내지 못했습니다 — 연결·서버 오류입니다. 잠시 후 「다시 보내기」를 눌러 주십시오. 계정이 이미 만들어졌으면 이 모달을 닫아도 대표 담당자 계정 줄이 「미발송」으로 남아 거기서 다시 보낼 수 있습니다.';
function _bdRenderCreateRefused(email) {
  _bdAcctModalRender({
    title: '이 이메일로는 계정을 만들 수 없습니다',
    // 🔴 어느 계정(인플루언서·관리자)인지 말하지 않는다(D6)
    body: '<div class="bd-acct-text">이미 다른 용도로 쓰는 이메일입니다 — 다른 이메일을 받아 주십시오. (' + esc(email) + ')</div>'
      + '<div class="bd-acct-text is-muted">대표 담당자에게 다른 이메일을 받아 담당자 정보를 고친 뒤 다시 「계정 만들기」를 눌러 주십시오.</div>',
    buttons: [{label:'확인', kind:'primary', onclick:'bdAccountModalClose()'}]
  });
}
async function bdAccountCreateSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'create' || _bdAcctBusy) return;
  _bdAcctSetBusy(true, 'bdAcctSubmit', '보내는 중…');
  try {
    // 계정은 이미 만들어졌고 메일만 실패한 뒤의 「다시 보내기」 — 메일만 다시
    if (!a.accountMade) {
      var chk = await checkBrandAccountEmail(a.brandId, a.email);
      if (!chk.ok) {
        _bdAcctBusy = false;
        // 겹침 확인은 권한이 없으면 서버가 'forbidden'(42501)을 던진다 — 연결 오류 문구로 덮지 않는다
        if (/forbidden|42501/.test(String(chk.error || ''))) { bdAccountModalClose(); toast('브랜드 페이지 계정 관리 권한이 없습니다.', 'warn'); return; }
        _bdRenderCreateModal(BD_CREATE_FAIL); return;
      }
      var cd = chk.data || {};
      if (cd.result === 'invalid_email') { _bdAcctBusy = false; _bdRenderCreateModal('이메일 형식이 올바르지 않습니다 — 「수정」으로 대표 담당자 이메일을 고친 뒤 다시 눌러 주십시오.'); return; }
      // 이용 제한 중인 브랜드 계정 — 연결 요청 확인 대신 제한 안내(제한 11 · A12)
      if (cd.restricted === true) { _bdAcctBusy = false; bdShowRestrictedAccount(a.email, cd); return; }
      if (cd.email_kind === 'influencer' || cd.email_kind === 'admin') { _bdAcctBusy = false; _bdRenderCreateRefused(a.email); return; }
      if (cd.email_kind === 'brand') {
        // 이미 다른 브랜드 계정 — 새 계정을 만들지 않고 연결 요청 확인(a03-01c)으로
        _bdAcctBusy = false;
        openBrandLinkRequestModal(a.email, 'create', { name: cd.name || '', count: cd.linked_brand_count });
        return;
      }
      var up = await upsertBrandOwnerAccount(a.brandId, a.contactId, a.email);
      if (!up.ok) { _bdAcctBusy = false; _bdRenderCreateModal(BD_CREATE_FAIL); return; }
      var d = up.data || {};
      var r = d.result;
      if (r === 'conflict_influencer' || r === 'conflict_admin') { _bdAcctBusy = false; _bdRenderCreateRefused(d.email || a.email); return; }
      if (r === 'invalid_email') { _bdAcctBusy = false; _bdRenderCreateModal('이메일 형식이 올바르지 않습니다 — 「수정」으로 대표 담당자 이메일을 고친 뒤 다시 눌러 주십시오.'); return; }
      if (r === 'noop') {
        // 앞선 「메일 보내기」의 계정 만들기가 서버에서는 됐는데 응답만 잃었을 수 있다 — 설정 전 계정이면 메일만 보낸다
        await bdReloadPeopleTab();
        var ns = bdOwnerState(_brandDetailAccountStatus);
        if (ns === 'mail_pending' || ns === 'mail_sent' || ns === 'link_expired') { a.accountMade = true; r = 'created'; d.needs_mail = true; }
      }
      // 서버가 브랜드 계정 겹침으로 판정(겹침 확인 뒤 그사이 생긴 경우) — 연결 요청 확인으로
      if (r === 'conflict_brand') { _bdAcctBusy = false; openBrandLinkRequestModal(d.email || a.email, 'create', null); return; }
      if (r !== 'created') {
        var msg = {
          request_exists: ['연결 요청이 기다리는 중이라 계정을 만들 수 없습니다 — 계정 칸을 다시 불러왔습니다.', 'warn'],
          noop: ['이미 대표 담당자 계정이 있습니다.', 'warn'],
          primary_moved: ['이미 대표 담당자 계정이 있습니다 — 목록을 다시 불러왔습니다.', 'warn'],
          password_already_set: ['이미 대표 담당자 계정이 있습니다 — 목록을 다시 불러왔습니다.', 'warn'],
          email_change_locked: ['계정이 있는 동안 대표 담당자 이메일은 바꿀 수 없습니다. 바꾸려면 「해제」한 뒤 다시 만드십시오.', 'warn'],
          no_primary_email: ['먼저 「+ 담당자 추가」로 대표 담당자를 등록하십시오.', 'warn'],
          brand_archived: ['비활성 브랜드라 계정을 만들 수 없습니다.', 'warn'],
          brand_not_found: ['브랜드를 찾지 못했습니다.', 'error'],
          forbidden: ['브랜드 페이지 계정 관리 권한이 없습니다.', 'warn']
        }[r] || [BD_TOAST_FAIL + ' [' + String(r || 'empty') + ']', 'error'];
        _bdAcctBusy = false; bdAccountModalClose(); _bdAfterAction(msg[0], msg[1]);
        return;
      }
      a.accountMade = true;
      if (d.needs_mail !== true) {   // 메일이 필요 없는 계정(비밀번호를 이미 정한 계정 다시 연결)
        _bdAcctBusy = false; bdAccountModalClose(); _bdAfterAction('대표 담당자 계정을 연결했습니다 — 이미 비밀번호를 정한 계정이라 메일은 보내지 않았습니다.');
        return;
      }
    }
    var mail = await sendBrandAccountSetupMail(a.brandId, 'setup');
    _bdAcctBusy = false;
    if (mail && mail.sent) {
      if (mail.dev_link) _brandAccountDevLinks[a.brandId] = mail.dev_link; else delete _brandAccountDevLinks[a.brandId];
      bdAccountModalClose();
      _bdAfterAction(mail.dev_link ? '계정 생성 메일을 보냈습니다. (개발서버 — 메일 대신 링크를 만들었습니다)' : '계정 생성 메일을 보냈습니다.');
      return;
    }
    // 계정은 생겼는데 메일 실패 — 창에 남겨 다시 보내게 하고, 뒤의 표는 「메일 미발송」으로
    _bdRenderCreateModal(BD_CREATE_FAIL + ' [' + String((mail && (mail.reason || mail.error)) || 'unknown') + ']');
    bdReloadPeopleTab();
  } catch (e) {
    console.error('[bdAccountCreateSubmit]', e);
    _bdAcctBusy = false; _bdRenderCreateModal(BD_CREATE_FAIL);
  }
}

// ── ② 다시 보내기 (확인 창 없음) ──
async function brandAccountResend() {
  var brandId = _brandsCurrentId;
  if (_bdAcctBusy || !brandId) return;
  _bdAcctBusy = true;
  var mail;
  try { mail = await sendBrandAccountSetupMail(brandId, 'resend'); } finally { _bdAcctBusy = false; }
  if (mail && mail.sent) {
    if (mail.dev_link) _brandAccountDevLinks[brandId] = mail.dev_link; else delete _brandAccountDevLinks[brandId];
    _bdAfterAction(mail.dev_link ? '계정 생성 메일을 다시 보냈습니다. (개발서버 — 메일 대신 링크를 만들었습니다)' : '계정 생성 메일을 다시 보냈습니다.');
    return;
  }
  var reason = String((mail && (mail.reason || mail.error)) || 'unknown');
  var text = {
    password_already_set: ['이미 비밀번호를 정한 계정이라 메일을 보내지 않았습니다.', 'warn'],
    no_account: ['대표 담당자 계정이 없어 메일을 보내지 못했습니다 — 목록을 다시 불러왔습니다.', 'error'],
    forbidden: ['브랜드 페이지 계정 관리 권한이 없습니다.', 'warn']
  }[reason] || ['메일을 보내지 못했습니다. 잠시 후 다시 시도해 주십시오. [' + reason + ']', 'error'];
  _bdAfterAction(text[0], text[1]);
}

// ── ⑥ 연결 요청 (조각 13 — a03-01c · 04 · 04a · 91a, 연결 요청 사양서 4-6) ──
//   이미 있는 브랜드 계정을 대표 담당자가 없는 이 브랜드의 대표로 잇자는 요청 — 본인이 24시간 안에 수락해야 연결된다.
//   from 'create' = 계정 만들기에서 겹침(01c — 이메일 고정, 이름·연결된 브랜드 수) / 'add' = 「브랜드 연결 추가」(04 — 이메일 입력).
//   요청 → 메일(notify-brand-invite). 메일이 실패해도 요청은 남는다 — 다시 보내기 = 같은 이메일로 요청 다시(같은 줄 다시 발급, 옛 링크 무효).
//   🔴 개발서버는 메일 대신 dev_mail{subject, text} — 본문 안 링크를 「개발서버 링크 복사」로 둔다(실제 메일 시험 안 함).
function _bdDevMailLink(dm) {
  var m = dm && typeof dm.text === 'string' ? dm.text.match(/https?:\/\/\S*[?&]link=\S+/) : null;
  return m ? m[0].replace(/[)\]>.,]+$/, '') : null;
}
function openBrandLinkRequestModal(email, from, info) {
  if (!_brandsCurrentId) return;
  var st = _brandDetailAccountStatus;
  if (bdOwnerState(st) !== 'none') { bdAccountModalClose(); toast('이 브랜드에는 이미 대표 담당자가 있습니다.', 'warn'); bdReloadPeopleTab(); return; }
  if (from === 'add' && !email) {
    // 기본값 = 대표 담당자 줄 이메일(없으면 빈 칸)
    var owner = bdMergePeopleRows(_brandFormContacts, st).find(function(r){ return r.kind === 'owner' && r.contact; });
    email = (owner && owner.contact && owner.contact.email) || '';
  }
  _bdAcct = { action: 'link', from: from === 'create' ? 'create' : 'add', brandId: _brandsCurrentId, email: String(email || '').trim(),
              info: info || null, requested: false, fieldErr: null };
  _bdRenderLinkModal(null);
}
var BD_LINK_NOT_BRAND = '브랜드 계정이 아닌 이메일입니다. 「브랜드 연결 추가」는 이미 브랜드 계정이 있는 이메일만 쓸 수 있습니다. 새 사람이면 담당자를 대표 담당자로 표시한 뒤 「계정 만들기」를 쓰십시오.';
var BD_LINK_MAIL_FAIL = '연결 요청은 만들었지만 메일을 보내지 못했습니다 — 「다시 보내기」를 눌러 주십시오. 창을 닫아도 계정 칸의 「다시 보내기」로 보낼 수 있습니다.';
function _bdRenderLinkModal(error) {
  var a = _bdAcct; if (!a || a.action !== 'link') return;
  var brandName = (_brandDetailBrand && _brandDetailBrand.name) || '이 브랜드';
  var body, title;
  if (a.from === 'create') {
    title = '브랜드 연결 요청 확인';
    var who = a.info && (a.info.name || a.info.count != null)
      ? '(' + [a.info.name, (a.info.count != null ? '연결된 브랜드 ' + a.info.count + '개' : '')].filter(Boolean).join(' · ') + ')'
      : '';
    body = '<div class="bd-acct-text">이미 브랜드 계정이 있는 이메일입니다' + esc(who) + '. (' + esc(a.email) + ')</div>'
      + '<div class="bd-acct-text">새 계정을 만들지 않고, 이 사람에게 ' + esc(brandName) + ' 대표 담당자 연결 요청을 보냅니다. 본인이 24시간 안에 수락해야 이 브랜드에 연결됩니다. 비밀번호를 아직 정하지 않은 계정이면 메일 링크에서 비밀번호를 정하며 수락합니다.</div>';
  } else {
    title = '다른 브랜드 계정에 이 브랜드 연결을 요청하시겠습니까?';
    var fe = a.fieldErr;
    body = '<div class="bd-ct-field"><label class="bd-acct-label" for="bdLinkEmail">이미 브랜드 계정이 있는 이메일</label>'
      + '<input id="bdLinkEmail" type="email" class="admin-filter' + (fe ? ' is-invalid' : '') + '" value="' + esc(a.email) + '" placeholder="example@brand.com" autocomplete="off"'
        + ' aria-invalid="' + (fe ? 'true' : 'false') + '"' + (a.requested ? ' readonly aria-readonly="true"' : '') + ' data-autofocus>'
      + (fe ? '<div class="bd-acct-field-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span>' + esc(fe) + '</div>' : '')
      + '</div>'
      + _bdBullets(fe
          ? ['그 사람이 수락하면 ' + brandName + '의 대표 담당자가 됩니다(대표 담당자가 없을 때만 요청할 수 있습니다).',
             '그 사람에게 「브랜드 연결 요청」 메일이 갑니다. 24시간 안에 수락해야 연결됩니다.']
          : ['그 사람이 수락하면 ' + brandName + '의 대표 담당자가 됩니다(대표 담당자가 없을 때만 요청할 수 있습니다).',
             '그 사람에게 「브랜드 연결 요청」 메일이 가고, 브랜드 페이지 마이페이지 「받은 초대」에도 표시됩니다.',
             '수락하기 전에는 연결되지 않습니다. 24시간 안에 수락하지 않으면 요청이 끝나며, 「다시 보내기」로 새로 보낼 수 있습니다. 비밀번호를 아직 정하지 않은 계정은 메일 링크에서 비밀번호를 정하며 수락합니다.']);
  }
  _bdAcctModalRender({
    title: title,
    error: error,
    body: body,
    buttons: [{label: a.requested ? '닫기' : '취소', kind:'ghost', onclick:'bdAccountModalClose()'},
              {label: a.requested ? '다시 보내기' : '연결 요청 보내기', kind:'primary', id:'bdLinkSubmit', onclick:'bdLinkRequestSubmit()'}]
  });
}
// 요청 + 메일 — 창(01c·04)의 「연결 요청 보내기」·「다시 보내기」와 계정 칸 「다시 보내기」가 같이 쓴다.
//   반환 {done:true, devLink} | {done:false, result, mailFailed, reason}
async function _bdLinkRequestAndMail(brandId, email) {
  var rq = await requestBrandOwnerLink(brandId, email);
  if (!rq.ok) return { done: false, result: /forbidden|42501/.test(String(rq.error || '')) ? 'forbidden' : 'error' };
  var d = rq.data || {};
  if (d.result !== 'ok') return { done: false, result: d.result || 'empty' };
  var mail = await sendBrandOwnerLinkMail(d.request_id);
  // already_sent = 이번 발급분 메일이 이미 나갔다(두 번 누르기) — 보낸 것으로 본다
  if (mail && (mail.sent || mail.reason === 'already_sent')) {
    // already_sent 는 앞 누름이 이미 보냈다 — 그때 만든 개발서버 링크를 지우지 않는다
    if (mail.sent) {
      var link = mail.dev_mail ? _bdDevMailLink(mail.dev_mail) : null;
      if (link) _brandAccountDevLinks[brandId] = link; else delete _brandAccountDevLinks[brandId];
    }
    return { done: true, dev: !!mail.dev_mail };
  }
  // 메일 함수가 거부한 사유는 메일 실패와 가른다 — not_pending = 그사이 취소·수락됨, forbidden = 권한
  var mr = String((mail && (mail.reason || mail.error)) || 'unknown');
  if (mail && mail.reason === 'not_pending') return { done: false, result: 'mail_not_pending' };
  if (mail && mail.reason === 'forbidden') return { done: false, result: 'forbidden' };
  return { done: false, result: 'ok', mailFailed: true, reason: mr };
}
// 요청 결과 → [문구, 단계] (창을 닫고 토스트로 끝나는 것들)
function _bdLinkResultToast(r) {
  return {
    owner_exists: ['이 브랜드에는 이미 대표 담당자가 있습니다 — 목록을 다시 불러왔습니다.', 'warn'],
    request_exists: ['다른 이메일로 보낸 연결 요청이 기다리는 중입니다 — 계정 칸을 다시 불러왔습니다.', 'warn'],
    already_linked: ['이미 이 브랜드에 연결된 계정입니다.', 'warn'],
    mail_not_pending: ['메일을 보내기 전에 요청이 끝났습니다(취소·수락) — 계정 칸을 다시 불러왔습니다.', 'warn'],
    brand_archived: ['비활성 브랜드라 연결 요청을 보낼 수 없습니다.', 'warn'],
    brand_not_found: ['브랜드를 찾지 못했습니다.', 'error'],
    forbidden: ['브랜드 페이지 계정 관리 권한이 없습니다.', 'warn']
  }[r] || null;
}
async function bdLinkRequestSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'link' || _bdAcctBusy) return;
  if (a.from === 'add' && !a.requested) {
    var inp = $('bdLinkEmail');
    a.email = String((inp && inp.value) || '').trim();
    if (!_bdEmailOk(a.email)) { a.fieldErr = '이메일 형식이 올바르지 않습니다.'; _bdRenderLinkModal(null); return; }
  }
  a.fieldErr = null;
  _bdAcctSetBusy(true, 'bdLinkSubmit', '보내는 중…');
  var res;
  try { res = await _bdLinkRequestAndMail(a.brandId, a.email); }
  catch (e) { console.error('[bdLinkRequestSubmit]', e); res = { done: false, result: 'error' }; }
  _bdAcctBusy = false;
  if (_bdAcct !== a) return;
  if (res.done) {
    bdAccountModalClose();
    _bdAfterAction(res.dev ? '연결 요청을 보냈습니다. (개발서버 — 메일 대신 링크를 만들었습니다)' : '연결 요청을 보냈습니다.');
    return;
  }
  if (res.mailFailed) { a.requested = true; _bdRenderLinkModal(BD_LINK_MAIL_FAIL + ' [' + res.reason + ']'); bdReloadPeopleTab(); return; }
  if (res.result === 'account_restricted') { bdShowRestrictedAccount(a.email, null); return; }   // 제한 11 · A12
  if (res.result === 'not_brand_account') {
    if (a.from === 'add') { a.fieldErr = BD_LINK_NOT_BRAND; _bdRenderLinkModal(null); }
    else _bdRenderLinkModal(BD_LINK_NOT_BRAND);
    return;
  }
  if (res.result === 'invalid_email') {
    if (a.from === 'add') { a.fieldErr = '이메일 형식이 올바르지 않습니다.'; _bdRenderLinkModal(null); }
    else _bdRenderLinkModal('이메일 형식이 올바르지 않습니다 — 「수정」으로 대표 담당자 이메일을 고친 뒤 다시 눌러 주십시오.');
    return;
  }
  var t = _bdLinkResultToast(res.result);
  if (t) { bdAccountModalClose(); _bdAfterAction(t[0], t[1]); return; }
  _bdRenderLinkModal('연결 요청을 보내지 못했습니다 — 연결·서버 오류입니다. 잠시 후 다시 눌러 주십시오. [' + String(res.result) + ']');
}
// 계정 칸 「다시 보내기」(요청 대기 중) — 확인 창 없음. 같은 이메일로 다시 발급되어 앞서 보낸 링크는 쓸 수 없게 된다
async function brandLinkRequestResend() {
  var brandId = _brandsCurrentId;
  var lr = bdLinkRequest(_brandDetailAccountStatus);
  if (_bdAcctBusy || !brandId || !lr || !lr.email) { bdReloadPeopleTab(); return; }
  _bdAcctBusy = true;
  var res;
  try { res = await _bdLinkRequestAndMail(brandId, lr.email); }
  catch (e) { console.error('[brandLinkRequestResend]', e); res = { done: false, result: 'error' }; }
  finally { _bdAcctBusy = false; }
  if (res.done) { _bdAfterAction(res.dev ? '연결 요청을 다시 보냈습니다. (개발서버 — 메일 대신 링크를 만들었습니다)' : '연결 요청을 다시 보냈습니다. 앞서 보낸 링크는 쓸 수 없게 됐습니다.'); return; }
  if (res.mailFailed) { _bdAfterAction('메일을 보내지 못했습니다. 잠시 후 다시 시도해 주십시오. [' + res.reason + ']', 'error'); return; }
  if (res.result === 'account_restricted') { bdShowRestrictedAccount(lr.email, null); return; }
  var t = _bdLinkResultToast(res.result);
  _bdAfterAction(t ? t[0] : '연결 요청을 다시 보내지 못했습니다. 잠시 후 다시 시도해 주십시오. [' + String(res.result) + ']', t ? t[1] : 'error');
}
// 요청 취소 — 계정 관리 권한이면 누구나(L7)
function openBrandLinkCancelModal(requestId) {
  var lr = bdLinkRequest(_brandDetailAccountStatus);
  if (!lr || lr.status !== 'pending' || !requestId || lr.request_id !== requestId) { toast('기다리는 연결 요청이 없습니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  _bdAcct = { action: 'link_cancel', brandId: _brandsCurrentId, requestId: requestId, email: lr.email || '' };
  _bdAcctModalRender({
    title: '연결 요청을 취소하시겠습니까?',
    body: '<div class="bd-acct-text">' + esc(lr.email || '') + ' 에게 보낸 연결 요청을 취소합니다.</div>'
      + _bdBullets(['이미 간 메일의 링크는 쓸 수 없게 됩니다.', '다시 보내려면 계정 칸의 「브랜드 연결 추가」를 누르십시오.']),
    buttons: [{label:'닫기', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'요청 취소', kind:'danger', id:'bdLinkCancelGo', onclick:'bdLinkCancelSubmit()'}]
  });
}
async function bdLinkCancelSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'link_cancel' || _bdAcctBusy) return;
  _bdAcctSetBusy(true, 'bdLinkCancelGo', '취소하는 중…');
  var res = await cancelBrandOwnerLink(a.brandId, a.requestId);
  _bdAcctBusy = false;
  if (_bdAcct !== a) return;
  var r = res.ok ? (res.data || {}).result : (/forbidden|42501/.test(String(res.error || '')) ? 'forbidden' : null);
  bdAccountModalClose();
  if (r === 'ok') { delete _brandAccountDevLinks[a.brandId]; _bdAfterAction('연결 요청을 취소했습니다.'); return; }
  if (r === 'not_pending') { _bdAfterAction('이미 끝난 요청입니다(수락·만료·취소) — 계정 칸을 다시 불러왔습니다.', 'warn'); return; }
  if (r === 'forbidden') { _bdAfterAction('브랜드 페이지 계정 관리 권한이 없습니다.', 'warn'); return; }
  _bdAfterAction('요청을 취소하지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error');
}

// ── ③ 대표 담당자 바꾸기 (a03-02 · 02a · 02b) ──
//   후보 = 계정 멤버 중 비밀번호를 정한 사람(담당자 목록과 무관)
function _bdOwnerCandidates() {
  var st = _brandDetailAccountStatus;
  return ((st && Array.isArray(st.members)) ? st.members : []).filter(function(m){ return m && m.role === 'member' && m.password_set_at && m.auth_id; });
}
function openBrandOwnerChangeModal(preselectAuthId) {
  _bdAcct = { action: 'owner_change', brandId: _brandsCurrentId, selected: preselectAuthId || null };
  _bdRenderOwnerChangeModal(null);
}
function _bdRenderOwnerChangeModal(error) {
  var a = _bdAcct; if (!a) return;
  var st = _brandDetailAccountStatus || {};
  var owner = (st.members || []).find(function(m){ return m && m.role === 'owner'; });
  var cands = _bdOwnerCandidates();
  if (!cands.some(function(m){ return m.auth_id === a.selected; })) a.selected = cands.length ? cands[0].auth_id : null;
  var note = '<div class="bd-acct-text is-muted">멤버가 한 명도 없으면: 대표 담당자를 「해제」해 「대표 담당자 없음」으로 만든 뒤 「계정 만들기」로 새 대표 담당자를 세웁니다.</div>';
  if (!cands.length) {
    _bdAcctModalRender({
      title: '대표 담당자를 누구로 바꾸시겠습니까?',
      error: error,
      body: '<div class="bd-acct-text">대표 담당자를 넘길 멤버가 없습니다. 대표 담당자는 기존 멤버 중에서만 고를 수 있습니다.</div>'
        + '<div class="bd-acct-empty"><span class="material-icons-round notranslate" translate="no">group_off</span>고를 수 있는 멤버가 없습니다 (멤버 0명)</div>' + note,
      buttons: [{label:'닫기', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'대표 담당자로 지정', kind:'primary', disabled:true, onclick:''}]
    });
    return;
  }
  _bdAcctModalRender({
    title: '대표 담당자를 누구로 바꾸시겠습니까?',
    error: error,
    body: '<div class="bd-acct-text">멤버 중에서 고릅니다. 지금 대표 담당자' + (owner ? '(' + esc(_bdMemberName(owner)) + ')' : '') + '는 멤버로 내려갑니다.</div>'
      + '<div class="bd-acct-radios" role="radiogroup">' + cands.map(function(m) {
          return '<label class="bd-acct-radio"><input type="radio" name="bdOwnerPick" value="' + esc(m.auth_id) + '"'
            + (m.auth_id === a.selected ? ' checked data-autofocus' : '') + ' onchange="_bdAcct && (_bdAcct.selected=this.value)">'
            + '<span>' + esc(_bdMemberName(m)) + ' · ' + esc(m.email || '') + '</span></label>';
        }).join('') + '</div>' + note,
    buttons: [{label:'취소', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'대표 담당자로 지정', kind:'primary', id:'bdAcctSubmit', onclick:'bdOwnerChangeSubmit()'}]
  });
}
async function bdOwnerChangeSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'owner_change' || _bdAcctBusy || !a.selected) return;
  var st = _brandDetailAccountStatus || {};
  _bdAcctSetBusy(true, 'bdAcctSubmit', '바꾸는 중…');
  var res = await changeBrandOwner(a.brandId, a.selected, st.owner_auth_id || null);
  _bdAcctBusy = false;
  if (!res.ok) { _bdRenderOwnerChangeModal(BD_TOAST_FAIL); return; }
  if (res.data === 'ok') { bdAccountModalClose(); _bdAfterAction('대표 담당자를 바꿨습니다.'); return; }
  if (res.data === 'forbidden') { bdAccountModalClose(); _bdAfterAction('브랜드 페이지 계정 관리 권한이 없습니다.', 'warn'); return; }
  // owner_changed · not_member — 목록을 다시 받고 창에 남는다
  await bdReloadPeopleTab();
  if (!_bdAcct) return;
  _bdRenderOwnerChangeModal(res.data === 'owner_changed'
    ? '다른 관리자가 먼저 대표 담당자를 바꿨습니다. 목록을 다시 불러왔습니다 — 확인한 뒤 다시 골라 주십시오.'
    : '고른 사람이 더 이상 이 브랜드의 멤버가 아닙니다. 목록을 다시 불러왔습니다 — 확인한 뒤 다시 골라 주십시오.');
}

// ── ④ 해제 (a03-05 대표 · 05a 멤버 · 05b 멤버 있는 대표) ──
function openBrandAccountReleaseModal(authId) {
  var st = _brandDetailAccountStatus || {};
  var members = Array.isArray(st.members) ? st.members : [];
  var m = members.find(function(x){ return x && x.auth_id === authId; });
  if (!authId) { toast('해제할 계정을 찾지 못했습니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  var isOwner = (m && m.role === 'owner') || authId === st.owner_auth_id;
  _bdAcct = { action: 'release', brandId: _brandsCurrentId, authId: authId, isOwner: isOwner, name: _bdMemberName(m) || (isOwner ? (st.email || '대표 담당자') : '') };
  _bdRenderReleaseModal(null);
}
function _bdRenderReleaseModal(error) {
  var a = _bdAcct; if (!a) return;
  var st = _brandDetailAccountStatus || {};
  var members = (Array.isArray(st.members) ? st.members : []).filter(function(x){ return x && x.role === 'member'; });
  var who = a.name || '이 계정';
  if (a.isOwner && members.length) {   // A7 — 멤버가 있으면 대표를 바로 해제하지 않는다
    _bdAcctModalRender({
      title: who + '님은 지금 해제할 수 없습니다',
      error: error,
      body: '<div class="bd-acct-text">이 브랜드에는 멤버가 있어요(' + esc(members.map(_bdMemberName).join(', ')) + '). 대표 담당자를 바로 해제하면 초대·멤버 관리를 할 사람이 없어집니다. '
        + '먼저 「대표 담당자 바꾸기」로 멤버 중 한 명을 대표 담당자로 지정하십시오 — ' + esc(who) + '님은 멤버로 내려가고, 그다음 해제할 수 있습니다.</div>',
      buttons: [{label:'닫기', kind:'primary', onclick:'bdAccountModalClose()'}]
    });
    return;
  }
  var items;
  if (a.isOwner) {
    var cancel = Number(st.release_cancel_count) || 0;
    items = [
      '대표 담당자를 해제하면 「대표 담당자 없음」이 됩니다.',
      cancel > 0 ? '이 브랜드의 대기 중인 초대 ' + cancel + '건도 함께 취소됩니다. 받은 사람의 초대 링크는 쓸 수 없게 됩니다.' : null,
      '그 사람이 다른 브랜드에 연결돼 있으면 그 브랜드는 그대로입니다.',
      '만든 오리엔시트는 브랜드에 남습니다.',
      '대표 담당자 이메일을 바꾸려면 해제한 뒤 담당자 이메일을 고치고 다시 「계정 만들기」를 누르십시오.'
    ];
  } else {
    var brandName = (_brandDetailBrand && _brandDetailBrand.name) || '';
    var used = (st.seat_used === null || st.seat_used === undefined) ? NaN : Number(st.seat_used), lim = st.member_limit;
    items = [
      who + '님은 바로 이 브랜드' + (brandName ? '(' + brandName + ')' : '') + '의 오리엔시트·캠페인을 볼 수 없게 됩니다.',
      (!isNaN(used) && used > 0 && lim !== null && lim !== undefined)
        ? '멤버 자리에서 바로 빠져요(멤버 ' + used + ' / ' + lim + '명 → ' + (used - 1) + ' / ' + lim + '명).' : null,
      '다른 브랜드에 연결돼 있으면 그 브랜드는 그대로입니다.',
      who + '님이 만든 오리엔시트는 브랜드에 남습니다.'
    ];
  }
  _bdAcctModalRender({
    title: who + '님을 이 브랜드에서 해제하시겠습니까?',
    error: error,
    body: _bdBullets(items),
    buttons: [{label:'취소', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'해제', kind:'danger', id:'bdAcctSubmit', onclick:'bdReleaseSubmit()'}]
  });
}
async function bdReleaseSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'release' || _bdAcctBusy) return;
  _bdAcctSetBusy(true, 'bdAcctSubmit', '해제하는 중…');
  var res = await releaseBrandAccount(a.brandId, a.authId);
  _bdAcctBusy = false;
  if (!res.ok) { _bdRenderReleaseModal(BD_TOAST_FAIL); return; }
  var r = (res.data || {}).result;
  if (r === 'ok') {
    if (a.isOwner) delete _brandAccountDevLinks[a.brandId];
    bdAccountModalClose(); _bdAfterAction('해제했습니다.'); return;
  }
  if (r === 'owner_has_members') {   // 그사이 멤버가 생겼다 — 목록을 다시 받아 05b 로
    await bdReloadPeopleTab();
    if (_bdAcct) _bdRenderReleaseModal(null);
    return;
  }
  bdAccountModalClose();
  if (r === 'not_linked') _bdAfterAction('이미 해제된 계정입니다 — 목록을 다시 불러왔습니다.', 'warn');
  else if (r === 'forbidden') _bdAfterAction('브랜드 페이지 계정 관리 권한이 없습니다.', 'warn');
  else _bdAfterAction(BD_TOAST_FAIL + ' [' + String(r || 'empty') + ']', 'error');
}

// ── ⑤ 멤버 상한 바꾸기 (a03-03 · 03a) ──
function openBrandMemberLimitModal() {
  var st = _brandDetailAccountStatus || {};
  _bdAcct = { action: 'member_limit', brandId: _brandsCurrentId, value: (st.member_limit !== null && st.member_limit !== undefined) ? String(st.member_limit) : '' };
  _bdRenderMemberLimitModal(null);
}
function _bdRenderMemberLimitModal(error) {
  var a = _bdAcct; if (!a) return;
  var st = _brandDetailAccountStatus || {};
  var used = (st.seat_used === null || st.seat_used === undefined) ? NaN : Number(st.seat_used);   // 모르면 문구를 뺀다(0명으로 그리지 않는다)
  _bdAcctModalRender({
    title: '멤버 상한 바꾸기',
    body: '<label class="bd-acct-label" for="bdMemberLimitInput">이 브랜드의 멤버 상한 (대표 담당자·초대 대기 포함)</label>'
      + '<div class="bd-acct-num"><input id="bdMemberLimitInput" type="number" inputmode="numeric" min="1" max="50" step="1" class="admin-filter' + (error ? ' is-invalid' : '') + '"'
        + ' value="' + esc(a.value) + '" data-autofocus aria-invalid="' + (error ? 'true' : 'false') + '"'
        + ' oninput="_bdAcct && (_bdAcct.value=this.value)" onkeydown="if(event.key===\'Enter\')bdMemberLimitSubmit()"><span>명</span></div>'
      + (error ? '<div class="bd-acct-field-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span>' + esc(error) + '</div>' : '')
      + '<div class="bd-acct-text is-muted">' + (!isNaN(used) ? '지금 ' + used + '명이 쓰고 있습니다. ' : '')
        + '상한을 줄여도 이미 있는 멤버와 보낸 초대는 그대로 두고, 새 초대만 막습니다.</div>',
    buttons: [{label:'취소', kind:'ghost', onclick:'bdAccountModalClose()'}, {label:'저장', kind:'primary', id:'bdAcctSubmit', onclick:'bdMemberLimitSubmit()'}]
  });
}
function _bdMemberLimitIssue(v) {
  var s = String(v == null ? '' : v).trim();
  if (!/^-?\d+$/.test(s)) return '숫자(정수)로 넣어 주십시오.';
  var n = Number(s);
  if (n < 1) return '1명 이상으로 정해 주십시오 — 대표 담당자도 1자리로 셉니다.';
  if (n > 50) return '50명까지 정할 수 있습니다.';
  return null;
}
async function bdMemberLimitSubmit() {
  var a = _bdAcct;
  if (!a || a.action !== 'member_limit' || _bdAcctBusy) return;
  var inp = $('bdMemberLimitInput'); if (inp) a.value = inp.value;
  var issue = _bdMemberLimitIssue(a.value);
  if (issue) { _bdRenderMemberLimitModal(issue); return; }
  _bdAcctSetBusy(true, 'bdAcctSubmit', '저장하는 중…');
  var res = await setBrandMemberLimit(a.brandId, Number(String(a.value).trim()));
  _bdAcctBusy = false;
  if (!res.ok) { bdAccountModalClose(); toast(BD_TOAST_FAIL, 'error'); return; }
  var r = (res.data || {}).result;
  if (r === 'ok') { bdAccountModalClose(); _bdAfterAction('멤버 상한을 저장했습니다.'); return; }
  if (r === 'invalid_limit') { _bdRenderMemberLimitModal('1명부터 50명까지 정할 수 있습니다.'); return; }
  bdAccountModalClose();
  _bdAfterAction(r === 'forbidden' ? '브랜드 페이지 계정 관리 권한이 없습니다.' : BD_TOAST_FAIL + ' [' + String(r || 'empty') + ']', r === 'forbidden' ? 'warn' : 'error');
}

// ══ 담당자 추가·수정 창 (조각 12 — 피그마 a03-08 · 08a~08e, 서버 574) ══════════════════════════
//   그 줄만 서버에 바로 저장한다(브랜드 정보 탭 「저장」과 무관). 성공·실패 뒤 bdReloadPeopleTab().
//   🔴 대표 표시: 계정이 없으면 「다른 줄을 대표로 체크」로만 옮긴다 — 대표 줄의 체크는 끌 수 없다(서버 primary_required).
//      계정이 있는 동안(bdOwnerLocked)은 대표 줄 이메일·체크·삭제 잠금(08e), 다른 줄은 멤버 계정이 있을 때만
//      체크 → 「대표 담당자 바꾸기」(a03-02)로 넘긴다(08d). 계정 관리 권한이 없으면 잠긴 동안 체크칸을 숨긴다.
//   🔴 is_primary 는 항상 참/거짓으로 보낸다(574 — 비면 서버가 지금 값을 유지).
//   만료 전 연결 요청 중(조각 13)도 잠금에 든다 — bdOwnerLocked 가 본다(578 `_brand_contacts_locked` 와 같은 기준).
var _bdCt = null;        // {contactId, isNew, wasPrimary, name, phone, email, primary, error, fieldErr, confirmDelete}
var _bdCtBusy = false;
var _bdCtReturnFocus = null;
var BD_CT_FAIL = '저장하지 못했습니다 — 연결·서버 오류입니다. 입력한 값은 그대로 있습니다. 잠시 후 다시 「저장」을 눌러 주십시오.';
var BD_CT_EMAIL_NOTE = '여기서 이메일을 바꿔도 브랜드 페이지 로그인 이메일은 바뀌지 않습니다(1차에는 로그인 이메일을 바꾸는 기능이 없습니다).';
var BD_CT_PRIMARY_NOTE = '대표 표시는 브랜드 페이지 대표 담당자와 같습니다. 대표 담당자 계정이 있는 브랜드에서 다른 줄로 옮기면 대표 담당자도 그 사람으로 바뀌고, 지금 대표 담당자는 멤버가 됩니다. 브랜드 페이지 멤버인 사람에게만 옮길 수 있습니다.';

// 「계정이 있는 동안」 — 대표 계정 ⓑ~ⓔ 또는 만료 전 연결 요청(578 `_brand_contacts_locked` 와 같은 기준).
//   상태를 모르면(null·아직) 잠긴 것으로 본다(서버가 다시 판정한다)
function bdOwnerLocked() {
  var st = _brandDetailAccountStatus;
  return bdOwnerState(st) !== 'none' || bdLinkPending(st);
}
// 잠긴 이유가 연결 요청 대기인가(대표 계정은 없음) — 안내 문구만 가른다
function _bdLockedByRequest() {
  var st = _brandDetailAccountStatus;
  return bdOwnerState(st) === 'none' && bdLinkPending(st);
}
var BD_REQ_LOCK = '연결 요청 대기 중에는 대표 담당자를 바꿀 수 없습니다. 담당자·계정 탭에서 「요청 취소」하거나 요청이 끝난 뒤 바꾸십시오.';
function _bdEmailOk(v) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(v || '').trim()); }
function _bdNormEmail(v) { return (typeof _brandAccountNormEmail === 'function') ? _brandAccountNormEmail(v) : String(v || '').trim().toLowerCase(); }
// 서버에 실제로 있는 줄인가 — 담당자 목록이 비어 옛 대표 칸으로 화면이 만든 줄은 새 줄로 저장한다
function _bdContactOnServer(id) {
  var list = (_brandDetailBrand && Array.isArray(_brandDetailBrand.contacts)) ? _brandDetailBrand.contacts : [];
  return !!id && list.some(function(c){ return c && c.id === id; });
}

function openBrandContactModal(contactId) {
  if (!_brandsCurrentId) return;
  var c = contactId ? (_brandFormContacts || []).find(function(x){ return x && x.id === contactId; }) : null;
  if (contactId && !c) { toast('담당자를 찾지 못했습니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  _bdCt = {
    contactId: c ? c.id : null,
    isNew: !c,
    wasPrimary: !!(c && c.is_primary),
    name: c ? (c.name || '') : '', phone: c ? (c.phone || '') : '', email: c ? (c.email || '') : '',
    primary: !!(c && c.is_primary),
    error: null, fieldErr: {}, confirmDelete: false,
    everOnServer: !!(c && _bdContactOnServer(c.id))
  };
  _bdCtRender();
}

// 지금 상태에서 이 줄의 대표 표시 칸을 어떻게 그릴지
function _bdCtPrimaryMode() {
  var a = _bdCt;
  var st = _brandDetailAccountStatus;
  var canManage = !!(st && typeof st === 'object' && st.can_manage === true);
  var locked = bdOwnerLocked();
  var contacts = _brandFormContacts || [];
  if (!locked) {
    if (a.isNew && !contacts.some(function(c){ return c && c.is_primary; })) return { kind: 'auto' };       // 첫 줄·대표 없음 → 자동 대표
    if (a.wasPrimary) return { kind: 'fixed' };                                                            // 끌 수 없다 — 다른 줄을 체크
    return { kind: 'free' };
  }
  // 계정 관리 권한이 없으면 잠긴 동안 체크칸을 숨긴다(사양서 4-5 · D15). 대표 줄이면 이메일·삭제 잠금은 그대로(primaryLocked)
  if (!canManage) return { kind: 'hidden', primaryLocked: a.wasPrimary };
  if (a.wasPrimary) return { kind: 'locked' };                                                             // 08e
  if (_bdLockedByRequest()) return { kind: 'blocked', text: BD_REQ_LOCK };                                 // 연결 요청 대기(멤버 없음)
  if (a.isNew) return { kind: 'blocked', text: '대표 담당자 계정이 있는 동안 새 담당자는 대표로 표시할 수 없습니다. 먼저 대표 담당자가 이 사람을 멤버로 초대해야 합니다.' };
  var m = ((st && st.members) || []).find(function(x){ return x && x.role === 'member' && x.password_set_at && _bdNormEmail(x.email) && _bdNormEmail(x.email) === _bdNormEmail(a.email); });
  if (m) return { kind: 'member', authId: m.auth_id };
  var ownerSet = bdOwnerState(st) === 'active';
  return { kind: 'blocked', text: ownerSet
    ? '먼저 대표 담당자가 이 사람을 멤버로 초대해야 합니다. 대표 표시는 이 브랜드의 브랜드 페이지 멤버인 사람에게만 옮길 수 있습니다.'
    : '먼저 지금 대표 담당자를 해제한 뒤 새 사람으로 계정을 만들어 주십시오.' };
}
// 대표 줄 잠금(08e) — 이메일·삭제 잠김. 권한이 없어 체크칸을 숨긴 대표 줄도 같다
function emailLockedNow(mode) { return mode.kind === 'locked' || !!mode.primaryLocked; }
// 이 줄이 저장 뒤 대표인가(이메일 필수 판정)
function _bdCtWillBePrimary(mode) {
  return mode.kind === 'auto' || mode.kind === 'fixed' || emailLockedNow(mode) || (mode.kind === 'free' && _bdCt.primary);
}

function _bdCtModalEl() {
  var ov = $('brandContactModal');
  if (!ov) {
    ov = document.createElement('div');
    ov.id = 'brandContactModal';
    ov.className = 'modal-overlay';
    ov.style.zIndex = '790';   // 계정 창(800 — 대표 바꾸기)이 이 위에 뜬다
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-labelledby', 'brandContactModalTitle');
    ov.addEventListener('keydown', function(e) {
      if ($('bdAccountModal') && $('bdAccountModal').classList.contains('open')) return;   // 위 창이 받는다
      _bdModalKeydown(ov, e, function(){ if (!_bdCtBusy) brandContactModalClose(); });
    });
    document.body.appendChild(ov);
  }
  return ov;
}
function _bdCtCollect() {
  var a = _bdCt; if (!a) return;
  var n = $('bdCtName'), p = $('bdCtPhone'), e = $('bdCtEmail'), k = $('bdCtPrimary');
  if (n) a.name = n.value;
  if (p) a.phone = p.value;
  if (e && !e.readOnly) a.email = e.value;
  if (k && !k.disabled) a.primary = k.checked;
}
function _bdContactRerenderIfOpen() {
  var ov = $('brandContactModal');
  if (!_bdCt || !ov || !ov.classList.contains('open')) return;
  _bdCtCollect();
  // 다른 창에서 이 줄이 지워졌으면 닫는다
  var c = _bdCt.isNew ? null : (_brandFormContacts || []).find(function(x){ return x && x.id === _bdCt.contactId; });
  if (!_bdCt.isNew && !c) {
    // 옛 대표 칸으로 화면이 만든 줄은 다시 받을 때마다 아이디가 바뀐다 — 서버에 없던 줄이면 닫지 않는다(저장은 새 줄로)
    if (!_bdCt.everOnServer) { _bdCtRender(true); return; }
    _bdCtBusy = false; brandContactModalClose(); toast('이 담당자는 이미 삭제됐습니다 — 목록을 다시 불러왔습니다.', 'warn'); return;
  }
  if (c) {
    var was = _bdCt.wasPrimary;
    _bdCt.wasPrimary = !!c.is_primary;
    if (_bdCt.wasPrimary) _bdCt.primary = true;
    else if (was) _bdCt.primary = false;   // 대표가 다른 줄로 옮겨졌다 — 체크를 그대로 두면 저장 때 대표를 되찾는다
  }
  _bdCtRender(true);
}

function _bdCtRender(keepFocus) {
  var a = _bdCt; if (!a) return;
  var ov = _bdCtModalEl();
  if (!ov.classList.contains('open')) _bdCtReturnFocus = document.activeElement;
  var mode = _bdCtPrimaryMode();
  var emailLocked = emailLockedNow(mode);
  var emailReq = _bdCtWillBePrimary(mode);
  var fe = a.fieldErr || {};
  var field = function(id, label, value, opts) {
    opts = opts || {};
    var err = fe[opts.key];
    return '<div class="bd-ct-field"><label class="bd-acct-label" for="' + id + '">' + esc(label) + (opts.req ? ' <span class="bd-req">*</span>' : '') + '</label>'
      + '<input id="' + id + '" type="' + (opts.type || 'text') + '" class="admin-filter' + (err ? ' is-invalid' : '') + '" value="' + esc(value) + '"'
        + (opts.ph ? ' placeholder="' + esc(opts.ph) + '"' : '') + (opts.readonly ? ' readonly aria-readonly="true"' : '')
        + ' aria-invalid="' + (err ? 'true' : 'false') + '"' + (opts.auto ? ' autocomplete="' + opts.auto + '"' : '') + '>'
      + (err ? '<div class="bd-acct-field-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span>' + esc(err) + '</div>' : '')
      + (opts.note ? '<div class="bd-ct-note' + (opts.noteWarn ? ' is-warn' : '') + '">' + esc(opts.note) + '</div>' : '')
    + '</div>';
  };
  // 대표 표시 칸
  var prim = '';
  if (mode.kind !== 'hidden') {
    var checked = mode.kind === 'auto' || mode.kind === 'fixed' || mode.kind === 'locked' || (mode.kind === 'free' && a.primary);
    var disabled = mode.kind !== 'free' && mode.kind !== 'member';
    var note = {
      auto: '첫 담당자(또는 대표가 없는 브랜드의 새 담당자)는 대표 담당자가 됩니다 — 이메일이 필요합니다.',
      fixed: '대표 표시는 끌 수 없습니다. 대표를 옮기려면 다른 담당자의 「수정」에서 「대표 담당자로 표시」를 켜십시오.',
      locked: _bdLockedByRequest()
        ? '연결 요청 대기 중에는 대표 표시를 끌 수 없습니다. 바꾸려면 담당자·계정 탭에서 「요청 취소」하십시오. 이름·연락처는 고칠 수 있습니다.'
        : '대표 표시는 끌 수 없습니다. 대표 담당자를 바꾸려면 다른 멤버 줄에서 「대표 담당자로 표시」를 켜거나 「해제」하십시오. 이름·연락처는 고칠 수 있습니다.',
      free: BD_CT_PRIMARY_NOTE,
      member: BD_CT_PRIMARY_NOTE,
      blocked: mode.text
    }[mode.kind];
    prim = '<div class="bd-ct-field"><label class="bd-ct-check"><input id="bdCtPrimary" type="checkbox"' + (checked ? ' checked' : '') + (disabled ? ' disabled' : '')
      + (mode.kind === 'member' ? ' onchange="bdContactPrimaryToMember(this)"' : ' onchange="_bdCt && (_bdCt.primary=this.checked); _bdCtRefreshEmailReq()"') + '>'
      + '<span>대표 담당자로 표시</span></label>'
      + '<div class="bd-ct-note' + (mode.kind === 'blocked' ? ' is-warn' : '') + '">' + esc(note) + '</div></div>';
  }
  var canDelete = !a.isNew && !emailLocked;
  var foot;
  if (a.confirmDelete) {
    foot = '<div class="bd-ct-confirm"><span>이 담당자를 삭제하시겠습니까?</span>'
      + '<button type="button" class="btn btn-ghost" onclick="_bdCt && (_bdCt.confirmDelete=false); _bdCtCollect(); _bdCtRender()">취소</button>'
      + '<button type="button" class="btn btn-primary" id="bdCtDeleteGo" style="background:#c0392b;border-color:#c0392b" onclick="bdContactDeleteSubmit()" data-autofocus>삭제</button></div>';
  } else {
    foot = '<div class="bd-acct-btns bd-ct-btns">'
      + (canDelete ? '<button type="button" class="btn btn-ghost bd-danger bd-ct-del" onclick="_bdCtCollect(); _bdCt.confirmDelete=true; _bdCtRender()">담당자 삭제</button>' : '')
      + '<button type="button" class="btn btn-ghost" onclick="brandContactModalClose()">닫기</button>'
      + '<button type="button" class="btn btn-primary" id="bdCtSave" onclick="bdContactSaveSubmit()">저장</button></div>';
  }
  ov.innerHTML = '<div class="modal" style="max-width:480px;border-radius:16px;margin:auto">'
    + '<div class="modal-body" style="padding:22px 24px 20px">'
      + '<div class="bd-ct-head"><div id="brandContactModalTitle" class="bd-acct-title" style="margin:0">'
        + esc(a.isNew ? '담당자 추가' : '담당자 수정 — ' + (a.name || '이름 없음')) + '</div>'
        + '<button type="button" class="bd-ct-x" aria-label="닫기" onclick="brandContactModalClose()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>'
      + (a.error ? '<div class="bd-acct-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span><span>' + esc(a.error) + '</span></div>' : '')
      + field('bdCtName', '이름', a.name, { key: 'name', req: true, ph: '담당자명', auto: 'off' })
      + field('bdCtPhone', '연락처', a.phone, { key: 'phone', ph: '010-0000-0000', type: 'tel', auto: 'off' })
      + '<div id="bdCtEmailWrap">' + field('bdCtEmail', '이메일', a.email, { key: 'email', req: emailReq, ph: 'example@brand.com', type: 'email', auto: 'off',
          readonly: emailLocked,
          note: emailLocked
            ? (_bdLockedByRequest()
                ? '연결 요청 대기 중에는 대표 줄의 이메일을 바꿀 수 없습니다. 이메일이 잘못됐으면 먼저 담당자·계정 탭에서 「요청 취소」하십시오.'
                : '대표 담당자 계정이 있는 동안 대표 줄의 이메일은 바꿀 수 없습니다. 이메일이 잘못됐으면 먼저 담당자·계정 탭에서 「해제」하십시오.')
            : BD_CT_EMAIL_NOTE,
          noteWarn: emailLocked }) + '</div>'
      + prim
      + foot
    + '</div></div>';
  ov.classList.add('open');
  // 탭을 다시 받아 그리는 경우(keepFocus)는 초점을 옮기지 않는다 — 위의 계정 창·입력 중인 칸에서 초점을 뺏지 않게
  if (keepFocus) return;
  var focus = ov.querySelector('[data-autofocus]') || (fe.name ? $('bdCtName') : fe.email ? $('bdCtEmail') : (a.isNew ? $('bdCtName') : $('bdCtSave')));
  if (focus) setTimeout(function(){ focus.focus(); }, 30);
}
// 「대표 담당자로 표시」를 켜고 끌 때 이메일 칸의 필수 표시만 바꾼다(창 전체를 다시 그리지 않는다)
function _bdCtRefreshEmailReq() {
  var lab = document.querySelector('label[for="bdCtEmail"]');
  if (!lab || !_bdCt) return;
  var req = _bdCtWillBePrimary(_bdCtPrimaryMode());
  lab.innerHTML = '이메일' + (req ? ' <span class="bd-req">*</span>' : '');
}
// 잠긴 동안 멤버 줄의 체크 → 대표 바꾸기 창(그 멤버를 고른 채). 체크칸은 되돌린다 — 대표 이동은 창에서만, 다른 칸은 「저장」으로 따로
function bdContactPrimaryToMember(box) {
  var mode = _bdCtPrimaryMode();
  box.checked = false;
  if (mode.kind !== 'member') return;
  openBrandOwnerChangeModal(mode.authId);
}
function brandContactModalClose() {
  if (_bdCtBusy) return;
  _bdCt = null;
  var ov = $('brandContactModal'); if (ov) ov.classList.remove('open');
  var back = _bdCtReturnFocus; _bdCtReturnFocus = null;
  if (back && document.contains(back) && typeof back.focus === 'function') back.focus();
}

async function bdContactSaveSubmit() {
  var a = _bdCt;
  if (!a || _bdCtBusy) return;
  _bdCtCollect();
  var mode = _bdCtPrimaryMode();
  var willPrimary = _bdCtWillBePrimary(mode);
  var fe = {};
  if (!String(a.name).trim()) fe.name = '이름을 입력해 주십시오.';
  var em = String(a.email || '').trim();
  if (em && !_bdEmailOk(em)) fe.email = '이메일 형식이 올바르지 않습니다.';
  else if (!em && willPrimary && !emailLockedNow(mode)) fe.email = '대표 담당자는 이메일이 필요합니다.';
  a.fieldErr = fe; a.error = null;
  if (fe.name || fe.email) { _bdCtRender(); return; }
  _bdCtBusy = true;
  var b = $('bdCtSave'); if (b) { b.disabled = true; b.textContent = '저장하는 중…'; }
  var brandId = _brandsCurrentId;
  var onServer = !a.isNew && _bdContactOnServer(a.contactId);
  var res = await saveBrandContact(brandId, onServer ? a.contactId : null, {
    name: String(a.name).trim(), phone: String(a.phone || '').trim(), email: em,
    is_primary: (mode.kind === 'member' || mode.kind === 'blocked' || (mode.kind === 'hidden' && !mode.primaryLocked)) ? false : willPrimary
  });
  _bdCtBusy = false;
  if (!_bdCt || _brandsCurrentId !== brandId) return;
  if (!res.ok) {
    if (/forbidden|42501/.test(String(res.error || ''))) { a.error = '담당자를 저장할 권한이 없습니다.'; _bdCtRender(); return; }
    a.error = BD_CT_FAIL; _bdCtRender(); return;
  }
  var d = res.data || {};
  var r = d.result;
  if (r === 'ok') {
    if (_brandDetailBrand && Array.isArray(d.contacts)) { _brandDetailBrand.contacts = d.contacts; _initBrandFormContacts(_brandDetailBrand); }
    var wasNew = a.isNew || !onServer;
    _bdCtBusy = false; brandContactModalClose();
    _bdAfterAction(wasNew ? '담당자를 추가했습니다.' : '담당자를 저장했습니다.');
    return;
  }
  var map = {
    name_required: function(){ a.fieldErr = { name: '이름을 입력해 주십시오.' }; },
    invalid_email: function(){ a.fieldErr = { email: '이메일 형식이 올바르지 않습니다.' }; },
    primary_email_required: function(){ a.fieldErr = { email: '대표 담당자는 이메일이 필요합니다.' }; },
    primary_required: function(){ a.error = '대표 표시는 끌 수 없습니다. 대표를 옮기려면 다른 담당자의 「수정」에서 「대표 담당자로 표시」를 켜십시오.'; },
    // 잠긴 이유가 연결 요청 대기일 수 있다(578) — 그때는 「요청 취소」로 안내
    primary_locked: function(){ a.error = _bdLockedByRequest() ? BD_REQ_LOCK : '대표 담당자 계정이 있는 동안 대표 줄의 이메일과 대표 표시는 바꿀 수 없습니다. 이메일이 잘못됐으면 먼저 담당자·계정 탭에서 「해제」하십시오.'; },
    primary_move_needs_owner_change: function(){ a.error = _bdLockedByRequest() ? BD_REQ_LOCK : '대표 담당자 계정이 있는 동안에는 「대표 담당자 바꾸기」로만 대표를 옮길 수 있습니다.'; },
    forbidden: function(){ a.error = '담당자를 저장할 권한이 없습니다.'; }
  }[r];
  if (r === 'contact_not_found' || r === 'brand_not_found') {
    brandContactModalClose(); _bdAfterAction('담당자를 찾지 못했습니다 — 목록을 다시 불러왔습니다.', 'warn'); return;
  }
  if (map) map(); else a.error = BD_CT_FAIL + ' [' + String(r || 'empty') + ']';
  if (r === 'primary_locked' || r === 'primary_move_needs_owner_change' || r === 'primary_required') { await bdReloadPeopleTab(); if (!_bdCt) return; }
  _bdCtRender();
}

async function bdContactDeleteSubmit() {
  var a = _bdCt;
  if (!a || _bdCtBusy || a.isNew) return;
  var brandId = _brandsCurrentId;
  // 서버에 없는 줄(옛 대표 칸으로 화면이 만든 줄)은 지울 것이 없다
  if (!_bdContactOnServer(a.contactId)) { brandContactModalClose(); _bdAfterAction('저장되지 않은 담당자라 지울 것이 없습니다.', 'warn'); return; }
  _bdCtBusy = true;
  var b = $('bdCtDeleteGo'); if (b) { b.disabled = true; b.textContent = '삭제하는 중…'; }
  var res = await deleteBrandContact(brandId, a.contactId);
  _bdCtBusy = false;
  if (!_bdCt || _brandsCurrentId !== brandId) return;
  var r = res.ok ? (res.data || {}).result : null;
  if (r === 'ok') {
    if (_brandDetailBrand && Array.isArray(res.data.contacts)) { _brandDetailBrand.contacts = res.data.contacts; _initBrandFormContacts(_brandDetailBrand); }
    brandContactModalClose(); _bdAfterAction('담당자를 삭제했습니다.'); return;
  }
  if (r === 'contact_not_found' || r === 'brand_not_found') { brandContactModalClose(); _bdAfterAction('이미 삭제된 담당자입니다 — 목록을 다시 불러왔습니다.', 'warn'); return; }
  a.confirmDelete = false;
  a.error = r === 'primary_locked'
    ? (_bdLockedByRequest()
        ? '연결 요청 대기 중에는 대표 줄을 삭제할 수 없습니다. 먼저 담당자·계정 탭에서 「요청 취소」하십시오.'
        : '대표 담당자 계정이 있는 동안 대표 줄은 삭제할 수 없습니다. 먼저 담당자·계정 탭에서 「해제」하십시오.')
    : (r === 'forbidden' || /forbidden|42501/.test(String(res.error || '')) ? '담당자를 삭제할 권한이 없습니다.' : '삭제하지 못했습니다 — 연결·서버 오류입니다. 잠시 후 다시 시도해 주십시오.');
  if (r === 'primary_locked') { await bdReloadPeopleTab(); if (!_bdCt) return; }
  _bdCtRender();
}
