// ════════════════════════════════════════════════════════════════════
// SECTION: COMPANIES — 회사 관리 페인 (브랜드 운영 재설계 PR 2)
//   회사(companies) 마스터 CRUD + 브랜드(brands) 일괄 할당.
//   회사 1개 = 브랜드 N개 (4단 계층: 회사 > 브랜드 > 신청 > 캠페인)
//   데이터베이스·행 단위 보안 정책은 마이그레이션 118~121 에서 완료.
//   기존 「브랜드 관리」(admin-brand.js) 의 자유 텍스트 company_name 과는
//   별개 개념(정규화 엔티티). 이번 단계에서는 분리 유지.
// ════════════════════════════════════════════════════════════════════

var _companiesCache = [];
var _companiesUnassignedCount = 0;
var _companyCurrentId = null;
// 브랜드 폼 등에서 회사 모달을 띄울 때 저장 후 실행할 콜백 (있으면 회사 페인 대신 콜백 실행)
var _companySavedCallback = null;
var companiesLazy;
var COMPANIES_PAGE_SIZE = 50;

// 회사 추가/수정/삭제 권한: campaign_admin 이상 (campaign_manager 는 읽기 전용)
function canEditCompanies() {
  var r = (typeof currentAdminInfo !== 'undefined' && currentAdminInfo) ? currentAdminInfo.role : null;
  return r === 'super_admin' || r === 'campaign_admin';
}

async function loadCompanies() {
  var tbody = $('companiesTableBody');
  if (tbody) tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  var statusF = $('companiesStatusFilter')?.value || 'active';
  var q = (($('companiesSearch')?.value) || '').trim();
  _companiesCache = await fetchCompanies({ status: statusF, search: q });
  // 미분류(회사 미할당) 브랜드 수 — 인디케이터용
  var unassigned = await fetchBrandsForAssign({ unassignedOnly: true });
  _companiesUnassignedCount = (unassigned || []).length;
  renderCompanyList();
}

function renderCompanyList() {
  var tbody = $('companiesTableBody');
  if (!tbody) return;
  var list = _companiesCache || [];
  var count = $('companiesTotalCount');
  if (count) count.textContent = '(' + list.length + '개)';

  // 미분류 브랜드 인디케이터 갱신
  var ind = $('companiesUnassignedIndicator');
  if (ind) {
    if (_companiesUnassignedCount > 0) {
      ind.style.display = '';
      ind.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">link_off</span> 미분류 브랜드 ' + _companiesUnassignedCount + '개'
        + (canEditCompanies() ? ' <span style="text-decoration:underline">→ 할당</span>' : '');
    } else {
      ind.style.display = 'none';
    }
  }

  // 추가 버튼 권한 가드 (campaign_manager 비활성 + 안내)
  var addBtn = $('companyAddBtn');
  if (addBtn) {
    if (canEditCompanies()) {
      addBtn.disabled = false;
      addBtn.removeAttribute('title');
      addBtn.style.opacity = '';
      addBtn.style.cursor = '';
    } else {
      addBtn.disabled = true;
      addBtn.title = '회사 추가 권한이 없습니다 (캠페인 관리자 이상)';
      addBtn.style.opacity = '.5';
      addBtn.style.cursor = 'not-allowed';
    }
  }

  if (list.length === 0) {
    tbody.innerHTML = '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:40px">회사가 없습니다' + (canEditCompanies() ? ' · 「+ 회사 추가」로 등록하세요' : '') + '</td></tr>';
    return;
  }

  var editable = canEditCompanies();
  var renderRow = function(c) {
    var statusBadge = c.status === 'archived'
      ? '<span style="background:#F0F0F0;color:#888;font-size:10px;font-weight:600;padding:2px 8px;border-radius:10px">보관</span>'
      : '<span style="background:#E8F5E9;color:#16a34a;font-size:10px;font-weight:600;padding:2px 8px;border-radius:10px">활성</span>';
    var brandCount = c.total_brands || 0;

    // 작업 버튼 — 권한 없으면 비활성 + 안내
    var noPerm = ' disabled title="회사 수정 권한이 없습니다 (캠페인 관리자 이상)" style="opacity:.4;cursor:not-allowed"';
    var assignBtn = '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openBrandAssignModal(\'' + esc(c.id) + '\')"' + (editable ? '' : noPerm) + '>브랜드 할당</button>';
    var archiveLabel = c.status === 'archived' ? '복귀' : '보관';
    var archiveBtn = '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();toggleArchiveCompany(\'' + esc(c.id) + '\',' + (c.status === 'archived' ? 'false' : 'true') + ')"' + (editable ? '' : noPerm) + '>' + archiveLabel + '</button>';
    // 삭제는 소속 0건일 때만 노출
    var deleteBtn = (brandCount === 0)
      ? '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();deleteCompanyConfirm(\'' + esc(c.id) + '\')"' + (editable ? ' style="color:#c0392b"' : noPerm) + '>삭제</button>'
      : '';

    return '<tr data-id="' + esc(c.id) + '" style="cursor:pointer" onclick="openCompanyModal(\'' + esc(c.id) + '\')">'
      + '<td><div style="font-weight:600;color:var(--ink)">' + esc(c.name_ko || '—') + '</div>'
        + (c.business_no ? '<div style="font-size:11px;color:var(--muted);margin-top:2px">' + esc(c.business_no) + '</div>' : '')
      + '</td>'
      + '<td style="font-size:12px;color:var(--ink)">' + esc(c.name_ja || '—') + '</td>'
      + '<td style="text-align:center;font-variant-numeric:tabular-nums;font-weight:600">' + brandCount + '</td>'
      + '<td>' + statusBadge + '</td>'
      + '<td style="white-space:nowrap">' + assignBtn + ' ' + archiveBtn + ' ' + deleteBtn + '</td>'
      + '</tr>';
  };

  if (companiesLazy) companiesLazy.destroy();
  companiesLazy = mountLazyList({
    tbody: tbody,
    scrollRoot: tbody.closest('.admin-table-wrap'),
    rows: list,
    renderRow: renderRow,
    pageSize: COMPANIES_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="5" style="text-align:center;color:var(--muted);padding:40px">회사가 없습니다</td></tr>'
  });
}

// ──────────────────────────────────────
// 회사 추가/수정 모달
// ──────────────────────────────────────
var COMPANY_FIELDS = [
  { key: 'name_ko', label: '회사명 (한국어)', required: true },
  { key: 'name_ja', label: '회사명 (일본어)' },
  { key: 'name_en', label: '회사명 (영어)' },
  { key: 'business_no', label: '사업자등록번호' },
  { key: 'homepage_url', label: '홈페이지 URL' },
  { key: 'address', label: '주소' },
  { key: 'billing_email', label: '청구 이메일' },
  { key: 'billing_address', label: '청구 주소' },
  { key: 'memo', label: '메모', textarea: true }
];

// opts.onSaved(company) — 브랜드 폼 등에서 신규 회사 등록 후 콜백.
//   콜백이 있으면 회사 모달을 다른 모달 위에 띄우고(z-index 상향), 저장 후 콜백 실행.
function openCompanyModal(id, opts) {
  _companySavedCallback = (opts && typeof opts.onSaved === 'function') ? opts.onSaved : null;
  var readOnly = !canEditCompanies();
  // 신규 추가는 권한 없으면 진입 차단. 기존 회사 행 클릭은 읽기 전용으로 열람 허용.
  if (!id && readOnly) { toast('회사 추가 권한이 없습니다 (캠페인 관리자 이상)'); _companySavedCallback = null; return; }
  _companyCurrentId = id || null;
  var c = id ? (_companiesCache || []).find(function(x){ return x.id === id; }) : null;
  var title = $('companyModalTitle');
  if (title) title.textContent = readOnly ? '회사 정보 (읽기 전용)' : (c ? '회사 수정' : '새 회사 추가');
  var dis = readOnly ? ' disabled' : '';

  var body = $('companyModalBody');
  if (body) {
    var rows = COMPANY_FIELDS.map(function(f) {
      var val = c ? (c[f.key] || '') : '';
      var input = f.textarea
        ? '<textarea id="companyF_' + f.key + '" class="form-input" rows="2" style="font-size:14px;width:100%"' + dis + '>' + esc(val) + '</textarea>'
        : '<input id="companyF_' + f.key + '" class="form-input" style="font-size:14px;width:100%" value="' + esc(val) + '"' + dis + '>';
      return '<div style="margin-bottom:12px">'
        + '<label style="display:block;font-size:12px;font-weight:600;color:var(--ink);margin-bottom:4px">' + esc(f.label) + (f.required ? ' <span style="color:#c0392b">*</span>' : '') + '</label>'
        + input + '</div>';
    }).join('');
    // 상태 선택 (수정 시에만 노출, 신규는 active 고정)
    var statusRow = '';
    if (c) {
      var st = c.status || 'active';
      statusRow = '<div style="margin-bottom:12px">'
        + '<label style="display:block;font-size:12px;font-weight:600;color:var(--ink);margin-bottom:4px">상태</label>'
        + '<select id="companyF_status" class="form-input" style="font-size:14px;width:100%"' + dis + '>'
        + '<option value="active"' + (st === 'active' ? ' selected' : '') + '>활성</option>'
        + '<option value="archived"' + (st === 'archived' ? ' selected' : '') + '>보관</option>'
        + '</select></div>';
    }
    body.innerHTML = rows + statusRow;
  }
  var saveBtn = $('companySaveBtn');
  if (saveBtn) saveBtn.style.display = readOnly ? 'none' : '';
  // 콜백 모드(브랜드 폼 위 중첩)면 z-index 상향, 아니면 표준값(612)
  var modalEl = $('companyModal');
  if (modalEl) modalEl.style.zIndex = _companySavedCallback ? '620' : '612';
  openModal('companyModal');
}

function closeCompanyModal() {
  var modalEl = $('companyModal');
  if (modalEl) modalEl.style.zIndex = '612';
  closeModal('companyModal');
  _companyCurrentId = null;
  _companySavedCallback = null;
}

async function saveCompany() {
  if (!canEditCompanies()) { toast('권한이 없습니다'); return; }
  var payload = {};
  if (_companyCurrentId) payload.id = _companyCurrentId;
  COMPANY_FIELDS.forEach(function(f) {
    var el = $('companyF_' + f.key);
    payload[f.key] = el ? el.value.trim() : '';
  });
  if (!payload.name_ko) { toast('회사명 (한국어)은 필수입니다'); return; }
  var stEl = $('companyF_status');
  if (stEl) payload.status = stEl.value;

  var btn = $('companySaveBtn');
  if (btn) { btn.disabled = true; btn.textContent = '저장 중…'; }
  var res = await upsertCompany(payload);
  if (btn) { btn.disabled = false; btn.textContent = '저장'; }
  if (!res.ok) {
    var em = res.error || '';
    // name_normalized UNIQUE 충돌 = 같은 회사명 중복
    if (em.indexOf('duplicate') >= 0 || em.indexOf('23505') >= 0) {
      toast('이미 등록된 회사명입니다');
    } else {
      toast('저장에 실패했습니다: ' + friendlyError({ message: em }));
    }
    return;
  }
  toast(_companyCurrentId ? '회사 정보를 저장했습니다' : '회사를 추가했습니다');
  // 콜백 모드(브랜드 폼 위에서 신규 등록)면 회사 페인 갱신 대신 콜백 실행
  var cb = _companySavedCallback;
  closeCompanyModal();  // 내부에서 _companySavedCallback = null
  if (cb) { cb(res.data); return; }
  await refreshPane('companies');
}

async function toggleArchiveCompany(id, archive) {
  if (!canEditCompanies()) { toast('권한이 없습니다'); return; }
  var ok = await showConfirm(archive ? '이 회사를 보관(archived) 처리할까요?' : '이 회사를 다시 활성화할까요?');
  if (!ok) return;
  var res = await archiveCompany(id, archive);
  if (!res.ok) { toast('처리에 실패했습니다: ' + friendlyError({ message: res.error })); return; }
  toast(archive ? '보관 처리했습니다' : '활성화했습니다');
  await refreshPane('companies');
}

async function deleteCompanyConfirm(id) {
  if (!canEditCompanies()) { toast('권한이 없습니다'); return; }
  var ok = await showConfirm('이 회사를 완전히 삭제할까요? 되돌릴 수 없습니다.');
  if (!ok) return;
  var res = await deleteCompanyHard(id);
  if (!res.ok) {
    if (res.code === 'HAS_BRANDS') {
      toast('소속 브랜드가 있어 삭제할 수 없습니다. 먼저 브랜드를 다른 회사로 옮기거나 미분류로 해제하세요');
    } else {
      toast('삭제에 실패했습니다: ' + friendlyError({ message: res.error }));
    }
    return;
  }
  toast('회사를 삭제했습니다');
  await refreshPane('companies');
}

// ──────────────────────────────────────
// 브랜드 할당 모달
//   현재 소속 + 미분류 브랜드를 다중 체크박스로 일괄 할당.
//   companyId=null(미분류 인디케이터 클릭) 이면 미분류 목록만 + 회사 선택 드롭다운.
// ──────────────────────────────────────
var _assignCompanyId = null;
var _assignOriginalIds = [];   // 모달 열 때 이미 이 회사 소속인 브랜드 id
var _assignBrandList = [];

async function openBrandAssignModal(companyId) {
  if (!canEditCompanies()) { toast('브랜드 할당 권한이 없습니다 (캠페인 관리자 이상)'); return; }
  _assignCompanyId = companyId || null;
  var c = companyId ? (_companiesCache || []).find(function(x){ return x.id === companyId; }) : null;
  var title = $('brandAssignModalTitle');
  if (title) title.textContent = c ? ('브랜드 할당 — ' + (c.name_ko || '')) : '미분류 브랜드 할당';

  var body = $('brandAssignModalBody');
  if (body) body.innerHTML = '<div style="text-align:center;padding:30px;color:var(--muted)"><span class="spinner" style="width:18px;height:18px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink);display:inline-block;vertical-align:middle;margin-right:6px"></span>불러오는 중…</div>';
  openModal('brandAssignModal');

  _assignBrandList = await fetchBrandsForAssign({ companyId: companyId || null, unassignedOnly: !companyId });
  _assignOriginalIds = (_assignBrandList || [])
    .filter(function(b){ return companyId && b.company_id === companyId; })
    .map(function(b){ return b.id; });

  renderBrandAssignBody();
}

function renderBrandAssignBody() {
  var body = $('brandAssignModalBody');
  if (!body) return;
  var list = _assignBrandList || [];

  // 미분류 인디케이터 경로(회사 미지정)이면 회사 선택 드롭다운 노출
  var companySelector = '';
  if (!_assignCompanyId) {
    var opts = (_companiesCache || [])
      .filter(function(c){ return c.status !== 'archived'; })
      .map(function(c){ return '<option value="' + esc(c.id) + '">' + esc(c.name_ko || '') + '</option>'; }).join('');
    companySelector = '<div style="margin-bottom:12px">'
      + '<label style="display:block;font-size:12px;font-weight:600;color:var(--ink);margin-bottom:4px">할당할 회사 <span style="color:#c0392b">*</span></label>'
      + '<select id="assignTargetCompany" class="form-input" style="font-size:14px;width:100%"><option value="">선택하세요</option>' + opts + '</select></div>';
  }

  if (list.length === 0) {
    body.innerHTML = companySelector + '<div style="text-align:center;padding:30px;color:var(--muted)">' + (_assignCompanyId ? '할당 가능한 브랜드가 없습니다' : '미분류 브랜드가 없습니다') + '</div>';
    return;
  }

  var rows = list.map(function(b) {
    var checked = _assignCompanyId && b.company_id === _assignCompanyId ? ' checked' : '';
    var subInfo = b.brand_seq ? '<span style="font-size:11px;color:var(--muted)">#' + esc(String(b.brand_seq)) + '</span>' : '';
    var assignedTo = (b.company_id && b.company_id !== _assignCompanyId)
      ? '<span style="font-size:10px;color:#c0392b;margin-left:6px">다른 회사 소속</span>' : '';
    return '<label style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-bottom:1px solid var(--line);cursor:pointer">'
      + '<input type="checkbox" class="assignBrandChk" value="' + esc(b.id) + '"' + checked + '>'
      + '<span style="flex:1;font-size:13px;color:var(--ink)">' + esc(b.name || '—') + ' ' + subInfo + assignedTo + '</span>'
      + '</label>';
  }).join('');

  body.innerHTML = companySelector
    + '<div style="font-size:11px;color:var(--muted);margin-bottom:6px">체크한 브랜드를 이 회사에 소속시킵니다. 체크를 해제하면 미분류로 돌아갑니다.</div>'
    + '<div style="max-height:50vh;overflow-y:auto;border:1px solid var(--line);border-radius:8px">' + rows + '</div>';
}

function closeBrandAssignModal() { closeModal('brandAssignModal'); _assignCompanyId = null; _assignOriginalIds = []; _assignBrandList = []; }

async function saveBrandAssign() {
  if (!canEditCompanies()) { toast('권한이 없습니다'); return; }
  var targetCompanyId = _assignCompanyId;
  if (!targetCompanyId) {
    var sel = $('assignTargetCompany');
    targetCompanyId = sel ? sel.value : '';
    if (!targetCompanyId) { toast('할당할 회사를 선택하세요'); return; }
  }
  var checkedIds = Array.prototype.slice.call(document.querySelectorAll('.assignBrandChk:checked')).map(function(el){ return el.value; });

  // 새로 할당할 브랜드 = 체크됨
  var toAssign = checkedIds;
  // 해제할 브랜드 = 원래 이 회사 소속이었으나 체크 해제됨 → 미분류 복귀
  var toUnassign = (_assignOriginalIds || []).filter(function(id){ return checkedIds.indexOf(id) < 0; });

  if (toAssign.length === 0 && toUnassign.length === 0) { toast('변경 사항이 없습니다'); closeBrandAssignModal(); return; }

  var btn = $('brandAssignSaveBtn');
  if (btn) { btn.disabled = true; btn.textContent = '저장 중…'; }
  var failed = null;
  if (toAssign.length) {
    var r1 = await assignBrandsToCompany(targetCompanyId, toAssign);
    if (!r1.ok) failed = r1.error;
  }
  if (!failed && toUnassign.length) {
    var r2 = await assignBrandsToCompany(null, toUnassign);
    if (!r2.ok) failed = r2.error;
  }
  if (btn) { btn.disabled = false; btn.textContent = '저장'; }
  if (failed) { toast('할당에 실패했습니다: ' + friendlyError({ message: failed })); return; }
  toast('브랜드 소속을 변경했습니다');
  closeBrandAssignModal();
  await refreshPane('companies');
}
