// ════════════════════════════════════════════════════════════════════
// SECTION: BRAND DETAIL (TABS) — 관리자 브랜드 상세 탭 4개 새 페이지
//   사양서 docs/specs/2026-10-21-admin-brand-detail-tabs.md · 작업표 …-breakdown.md
//   피그마 「레버브시딩_브랜드」 a03-00d(틀·머리·탭) · a03-09(떠날 때 확인) · a03-07·07a·07b(회사 모달)
//   🔴 개발서버만 연다 — `openBrandDetail` 맨 앞 한 줄이 `_brandAccountEnabled()` 일 때만 이 페이지로 보낸다(작업표 S0).
//      운영은 출시 날까지 admin-brand.js 의 옛 페이지 그대로.
//   🔴 상태(`_brandsCurrentId`·`_brandDetailTab`·`_brandFormContacts`·`_brandFormCompanies` …)는 admin-brand.js 의 것을 그대로 쓴다 —
//      오리엔시트 구역 다시 그리기(refreshBrandDetailSheets)·메모·계정 줄·공개 기본 열이 그 이름으로 돈다.
//   🔴 브랜드 정보 탭(`#brandDetailPane_info`)은 편집 폼이다 — 탭 전환·요약 줄·다른 탭 다시 그리기가 **이 영역을 건드리지 않는다**.
//   ⚠️ 조각 5 의 중간 상태(개발서버에서만 보인다): 브랜드 정보 탭은 옛 폼 절(소개·어필·Qoo10 포함)과 옛 「저장」(saveBrandDetail)을,
//      담당자·계정 탭은 옛 담당자 줄·계정 줄을 임시로 둔다 — 조각 7(새 저장)·10(담당자·계정 표)이 바꾼다.
// ════════════════════════════════════════════════════════════════════

var _brandDetailBrand = null;           // 연(또는 마지막으로 저장한) 브랜드 행 — 머리·요약 줄이 읽는다
var _brandDetailAccountStatus = undefined;   // 계정 상태 조회 — undefined 아직 / null 실패 / 객체
var _brandDetailAccountReq = 0;
var _bdBaseline = null;                 // 떠날 때 확인 기준값 {칸 열쇠: 값} — 브랜드 정보 탭만
var _bdLeaveGo = null;                  // 「저장하지 않고 나가기」가 이어 갈 동작

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
  renderBrandContactsRows();
  onBrandCompanyChange();   // 회사 카드 끝 줄을 「수정 / 보기」 링크로(카드가 DOM 에 붙은 뒤라야 위치로 가를 수 있다)
  renderBrandAccountRow(id);
  // 공개 기본 열은 따로 받는다. ⚠️ 조각 5 동안은 칸 안 자기 「기본 열 저장」이 있어 떠날 때 확인 대상에서 뺀다(_bdSnapshot)
  if (typeof renderBrandPublishDefaultBox === 'function') renderBrandPublishDefaultBox(id);
  _bdBindInfoPane();
  brandDetailMarkClean();
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
    ? '대표 담당자 ' + esc(primaryName) + (ownerActive ? ' (브랜드 페이지 사용 중)' : '')
    : '대표 담당자 없음');
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

// ── 브랜드 정보 탭 (조각 5 임시 — 옛 폼 절 + 옛 「저장」. 조각 7 이 칸 정리·새 저장으로 바꾼다) ──
//   🔴 입력칸 아이디는 옛 페이지·「새 브랜드」 모달과 같다(옛 saveBrandDetail 이 그 아이디로 읽는다) — 화면에 둘이 되지 않게
//      clearBrandModalBody·clearBrandDetailPaneBody 한 세트가 지킨다. 접두어 바꾸기는 조각 7 에서(작업표 M3)
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
function _bdTextarea(id, label, val, placeholder) {
  return '<div>' + _bdLabel(label, id) + '<textarea id="' + id + '" class="admin-filter" rows="3" style="resize:vertical;font-family:inherit;width:100%" placeholder="' + esc(placeholder || '') + '">' + esc(val || '') + '</textarea></div>';
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
    // ⚠️ 소개·어필·Qoo10 은 조각 7 에서 뺀다(D14). 지금 옛 저장이 이 칸을 읽어 — 칸이 없으면 빈 값으로 덮는다 — 임시로 남긴다
    + _bdSection('브랜드 콘텐츠 · SNS 정보', '',
      '<div class="bd-grid-2" style="margin-bottom:14px">'
        + _bdTextarea('brandFormDescription', '브랜드 소개', b.description, '브랜드 한줄 소개·수상 이력 등')
        + _bdTextarea('brandFormAppealPoints', '어필 포인트', b.appeal_points, '제품·시장에서의 강점')
      + '</div>'
      + '<div class="bd-grid-3">'
        + _bdInput('brandFormQoo10Url', 'Qoo10 상품 주소', b.official_qoo10_url, 'https://www.qoo10.jp/...')
        + _bdInput('brandFormInstagramUrl', '공식 Instagram URL', b.official_instagram_url, 'https://www.instagram.com/...')
        + _bdInput('brandFormXUrl', '공식 X URL', b.official_x_url, 'https://x.com/...')
      + '</div>')
    + _bdSection('브랜드 공개 기본 열', '', '<div id="brandPublishDefaultBox"><div style="padding:12px;text-align:center;color:var(--muted);font-size:12px">불러오는 중…</div></div>')
    + '<div class="bd-save-row"><span class="bd-save-note">이 탭의 내용은 「저장」을 눌러야 저장됩니다.</span>'
      + '<button type="button" class="btn btn-primary btn-sm" onclick="saveBrandDetail()">저장</button></div>';
}

// ── 담당자·계정 탭 (조각 5 임시 — 옛 담당자 줄·계정 줄. 조각 10 이 표로 바꾼다) ──
function _bdPeoplePaneHtml(b) {
  return _bdSection('담당자',
      '<button type="button" class="btn btn-ghost btn-xs" onclick="addBrandContact()" style="display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">add</span> 담당자 추가</button>',
      renderBrandContactsBlockHtml(b)
      + '<div class="bd-save-note" style="margin-top:8px">담당자는 지금은 「브랜드 정보」 탭의 「저장」으로 함께 저장됩니다.</div>');
}

// 담당자·계정 탭을 누를 때마다 — 지금은 계정 줄만 다시 받는다(조각 10 이 담당자·계정 표 전체 다시 받기로 바꾼다)
function brandDetailOnPeopleTab() {
  if (!_brandsCurrentId) return;
  renderBrandAccountRow(_brandsCurrentId);
  _bdLoadAccountStatus(_brandsCurrentId);
}

// 옛 「저장」 성공 뒤(조각 5 임시) — 저장한 값으로 머리·요약 줄·기준값을 맞춘다
function brandDetailAfterLegacySave(brandId, patch) {
  if (!brandDetailIsTabsPage() || brandId !== _brandsCurrentId || !_brandDetailBrand) return;
  Object.assign(_brandDetailBrand, patch || {});
  var badge = $('brandDetailStatusBadge');
  if (badge) badge.innerHTML = _bdStatusBadgeHtml(_brandDetailBrand.status);
  var cnt = $('brandDetailTab_people') && $('brandDetailTab_people').querySelector('.tab-count');
  if (cnt && Array.isArray(_brandDetailBrand.contacts)) cnt.textContent = '(' + _brandDetailBrand.contacts.length + ')';
  renderBrandDetailSummaryLine();
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

// 칸 스냅샷 — {열쇠: 값}. ⚠️ 공개 기본 열 칸(#brandPublishDefaultBox)은 조각 5 동안 자기 「기본 열 저장」이 따로 있어 뺀다(조각 7 이 탭 저장에 합치며 넣는다)
function _bdSnapshot() {
  var pane = $('brandDetailPane_info');
  var snap = {};
  if (!pane) return snap;
  var box = $('brandPublishDefaultBox');
  var els = pane.querySelectorAll('input, select, textarea');
  for (var i = 0; i < els.length; i++) {
    var el = els[i];
    if (box && box.contains(el)) continue;
    var key = el.id || ((el.name || el.tagName) + '#' + i);
    snap[key] = (el.type === 'checkbox' || el.type === 'radio') ? (el.checked ? '1' : '0') : String(el.value);
  }
  // ⚠️ 조각 5 중간 상태 — 담당자 줄은 아직 브랜드 정보 탭 「저장」으로 함께 저장되므로 같은 판정에 넣는다.
  //    조각 12(담당자 줄 단위 바로 저장)가 들어오면 이 두 줄을 뺀다.
  if ($('brandContactsWrap') && $('brandContactsWrap').closest('#brandDetailPane_people')) {
    snap.__contacts = JSON.stringify((_brandFormContacts || []).map(function(c){ return [c.id, c.name, c.phone, c.email, !!c.is_primary]; }));
  }
  return snap;
}

// 담당자 줄이 늘거나 줄거나 대표가 바뀐 뒤(renderBrandContactsRows 가 부른다) — 탭 숫자·저장 안 한 표시만
function brandDetailOnContactsChanged() {
  if (!brandDetailIsTabsPage()) return;
  var cnt = $('brandDetailTab_people') && $('brandDetailTab_people').querySelector('.tab-count');
  if (cnt) cnt.textContent = '(' + (_brandFormContacts || []).length + ')';
  _bdSyncDirtyUi();
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
  var dot = document.querySelector('#brandDetailTab_info .brand-detail-dirty-dot');
  if (dot) dot.style.display = brandDetailDirty() ? '' : 'none';
}

function _bdBindInfoPane() {
  var pane = $('brandDetailPane_info');
  if (!pane) return;
  pane.addEventListener('input', _bdSyncDirtyUi);
  pane.addEventListener('change', _bdSyncDirtyUi);
  // 조각 5 중간 상태 — 담당자 줄 입력도(위 _bdSnapshot 의 __contacts)
  var people = $('brandDetailPane_people');
  if (people) people.addEventListener('input', _bdSyncDirtyUi);
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
          // ⚠️ 조각 5 중간 상태 동안은 담당자 줄도 「저장」으로 저장되므로 그 문장을 빼고 메모만 말한다 — 조각 12 에서 a03-09 원문으로
          + '<li>영업 메모는 이미 저장되어 있습니다.</li>'
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
