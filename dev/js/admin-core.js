// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-core.js
// ═════════════════════════════════════════════════════════════════
//
// 전역 공용 헬퍼·상태 (admin.js 파일 분리 Phase 0).
//   · 태그 입력 (initTagInput/addTag/syncTagValue/loadTagsFromValue)
//   · friendlyError — 에러 메시지 한국어 변환
//   · switchAdminPane + popstate — 페인 라우팅
//   · 관리자 이메일 캐시 (loadAdminEmails/isAdminEmail/adminBadge)
//   · 다중선택 필터 (initMultiFilters/createMultiFilter/syncMultiFilter/getMultiFilterValues 등)
//   · 공통 셀 헬퍼 (formatReviewer/msgCell/openMsgModal/consentBadge/openCautionConsentModal)
//   · 범용 확인 모달 (showConfirm/resolveConfirmModal)
//   · 이미지 라이트박스 (openImageLightbox/closeImageLightbox)
//   · 상태: _adminEmails / _multiFiltersInitialized / _cautionConsentCache / _confirmResolver / currentAdminInfo
//
// ⚠ 빌드 이어붙이기(build.sh)에서 다른 admin-* 파일보다 앞에 위치해야 함.
// ⚠ 이름 변경 금지 — HTML onclick 강결합 + switchAdminPane loaders 참조.
// ═════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 태그 입력 헬퍼
// ════════════════════════════════════════════════════════════════════

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
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 친화적 에러 메시지
// ════════════════════════════════════════════════════════════════════

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

// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 페인 라우팅 (switchAdminPane)
//   각 페인 진입 함수를 이름으로 참조하므로, 페인 분리 후에도 전역
//   에 살아 있어야 한다. 새 페인 추가 시 loaders 객체에도 등록.
// ════════════════════════════════════════════════════════════════════

function switchAdminPane(pane, el, pushHistory) {
  // Vercel Web Analytics — 관리자 앱 페인별 접속 카운트
  try {
    if (typeof window.va === 'function') {
      window.va('event', { name: 'pv_admin', page: pane });
    }
  } catch (e) { /* analytics 실패 무시 */ }

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
      'camp-applicants':'campaigns','brand-ops-detail':'brand-ops'}[pane] || pane;
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
    'faq': loadFaqPane,
    'deliverables': loadDeliverables,
    'brand-applications': loadBrandApplications,
    'brand-dashboard': loadBrandDashboard,
    'brand-ops': loadBrandOps,
    'brand-ops-detail': loadBrandOpsDetail,
    'companies': loadCompanies,
    'brands': loadBrandsPane,
    'admin-notices': loadAdminNotices,
    'messages': loadMessagesInbox,
    'errors': loadClientErrors
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
    // 캠페인 노출 토글 초기값 ON (기본)
    if (typeof _resetNewCampVisibilityToggle === 'function') _resetNewCampVisibilityToggle();
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
      ['newCampDesc','newCampAppeal','newCampGuide'].forEach(id => setRichValue(id, ''));
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
    // NG 사항 번들 초기화 (migration 107 — caution_sets 패턴 미러)
    _nsetState.new = [];
    populateCampNsetDropdown('new', 'monitor', null);
    renderCampNgItems('new');
    renderCampBundleSummary('nset', 'new');
    setupCampPreview('new');
    // brand 드롭다운 로드 (캐시는 _campBrandsCache로 재사용)
    loadCampBrandSelect('new', '').then(() => onCampBrandChange('new'));
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
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 관리자 이메일 캐시 + 배지
// ════════════════════════════════════════════════════════════════════

async function loadAdminEmails() {
  if (!db) return;
  const {data} = await db?.from('admins').select('email');
  _adminEmails = (data||[]).map(a=>a.email);
}
function isAdminEmail(email) { return _adminEmails.includes(email); }
function adminBadge(email) { return isAdminEmail(email) ? ' <span style="background:var(--pink);color:#fff;font-size:9px;font-weight:700;padding:1px 6px;border-radius:4px;margin-left:4px">관리자</span>' : ''; }

var _multiFiltersInitialized = false;
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 다중선택 필터 부트스트랩
// ════════════════════════════════════════════════════════════════════

function initMultiFilters() {
  if (_multiFiltersInitialized) return;
  _multiFiltersInitialized = true;
  // 캠페인관리
  createMultiFilter('campTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => filterAdminCampaigns());
  createMultiFilter('campStatusMulti', '전체 상태', [
    {value:'draft',label:'준비'},{value:'scheduled',label:'모집예정'},{value:'active',label:'모집중'},{value:'closed',label:'모집마감'},{value:'ended',label:'종료'},{value:'expired',label:'노출종료'}
  ], () => filterAdminCampaigns());
  // 신청관리
  createMultiFilter('appTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => renderAppCampList());
  createMultiFilter('appStatusMulti', '전체 상태', [
    {value:'pending',label:'심사중'},{value:'approved',label:'승인'},{value:'rejected',label:'미승인'}
  ], () => renderAppCampList());
  // 결과물관리 — 신청(application) 1행 단위로 영수증·결과물 양쪽 상태를 같이 표시
  createMultiFilter('delivRecruitTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => renderDeliverablesList());
  createMultiFilter('delivReceiptStatusMulti', '전체', [
    {value:'pending',label:'검수대기'},{value:'approved',label:'승인'},{value:'rejected',label:'비승인'},{value:'none',label:'미제출'}
  ], () => renderDeliverablesList());
  createMultiFilter('delivResultStatusMulti', '전체', [
    {value:'pending',label:'검수대기'},{value:'approved',label:'승인'},{value:'rejected',label:'비승인'},{value:'none',label:'미제출'}
  ], () => renderDeliverablesList());
  // 광고주 신청
  createMultiFilter('brandAppFormMulti', '전체 폼', [
    {value:'reviewer',label:'리뷰어'},{value:'seeding',label:'나노 시딩'}
  ], () => renderBrandApplicationsList());
  // brandAppStatusMulti 드롭다운은 상태 탭 바로 대체됨 (admin-brand.js의 renderBrandAppStatusTabs)
}
// 검수자 표시 — applications.reviewed_by 컬럼 값 변환.
// migration 049 트리거가 monitor 캠페인 자동 승인 시 '自動承認' 텍스트를 저장하지만,
// 관리자 페이지는 한국어 UI 원칙(.claude/rules/ui.md)이라 표시 시에만 한글로 변환.
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 공통 셀 헬퍼 (리뷰어/메시지/주의사항 동의 배지)
// ════════════════════════════════════════════════════════════════════

function formatReviewer(name) {
  if (!name) return '';
  if (name === '自動承認') return '자동 승인';
  return name;
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
      const langLabel = snap.agreed_lang === 'ja' ? '일본어' : (snap.agreed_lang === 'ko' ? '한국어' : snap.agreed_lang);
      html += `<div style="margin-top:10px;color:var(--muted);font-size:11px">동의 시점 사용자 언어: ${esc(langLabel)}</div>`;
    }
  } else {
    html += `<div style="margin-top:10px;color:var(--muted);font-size:12px">동의 시점 스냅샷이 저장되지 않았습니다</div>`;
  }
  el.innerHTML = `<div style="max-height:60vh;overflow-y:auto">${html}</div>`;
  openModal('alertModal');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 다중선택 필터 유틸 (sync/create/reset)
// ════════════════════════════════════════════════════════════════════

// 다중 필터 리셋
function resetMultiFilter(containerId, allLabel) {
  const wrap = $(containerId);
  if (!wrap) return;
  const btn = wrap.querySelector('.mf-btn');
  const allCb = wrap.querySelector('input[value="all"]');
  const items = wrap.querySelectorAll('.mf-drop input[type="checkbox"]:not([value="all"])');
  if (allCb) { allCb.checked = true; allCb.indeterminate = false; }
  items.forEach(c => c.checked = true); // 전체 = 모든 항목 체크 표시
  if (btn) { btn.textContent = allLabel; btn.classList.remove('has-selection'); }
}
// 모두 해제 — 일괄발송처럼 "명시 선택 강제" 맥락에서 사용.
//   resetMultiFilter 는 "전체=모두 체크"(빈 배열 시맨틱)라 미선택 표현이 안 됨.
//   이 헬퍼는 전체 해제 + placeholder 라벨 → getMultiFilterValues 가 [] 반환(=대상 없음으로 처리).
function clearMultiFilter(containerId, placeholderLabel) {
  const wrap = $(containerId);
  if (!wrap) return;
  wrap.querySelectorAll('.mf-drop input[type="checkbox"]').forEach(c => { c.checked = false; c.indeterminate = false; });
  const btn = wrap.querySelector('.mf-btn');
  if (btn) { btn.textContent = placeholderLabel || '선택'; btn.classList.remove('has-selection'); }
}
function updateFilterResetBtn(btnId, multiIds, searchId) {
  const btn = $(btnId);
  if (!btn) return;
  const hasMulti = multiIds.some(id => getMultiFilterValues(id).length > 0);
  const hasSearch = searchId && $(searchId)?.value?.trim();
  btn.style.display = (hasMulti || hasSearch) ? '' : 'none';
}
// 다중 선택 드롭다운 공통 헬퍼 — 옵션 리스트 변화 시에만 재생성, 이전 선택 상태 보존
// options: [{value, label}]
function syncMultiFilter(containerId, allLabel, options, onChange, opts = {}) {
  const wrap = $(containerId);
  if (!wrap) return;
  const drop = wrap.querySelector('.mf-drop');
  if (!drop) return;
  // 옵션 키에 count·subLabel·searchable 포함 — 카운트/검색형 변경 시 재생성되어 (NN) 라벨·검색창 즉시 반영
  const newKey = options.map(o => `${o.value}:${o.count ?? ''}:${o.subLabel || ''}`).join('|') + (opts.searchable ? '|__search' : '');
  if (wrap.dataset.optKey === newKey && drop.children.length > 0) return;
  const prev = getMultiFilterValues(containerId);
  createMultiFilter(containerId, allLabel, options, onChange, opts);
  wrap.dataset.optKey = newKey;
  if (prev.length > 0) {
    // 일부 선택 상태 복원 — 모두 해제 후 prev 항목만 체크 (검색 input[type=search] 제외)
    const itemCbs = [...drop.querySelectorAll('input[type="checkbox"]:not([value="all"])')];
    itemCbs.forEach(c => c.checked = false);
    prev.forEach(v => {
      const cb = drop.querySelector(`input[value="${CSS && CSS.escape ? CSS.escape(v) : v.replace(/"/g,'\\"')}"]`);
      if (cb) cb.checked = true;
    });
    if (typeof wrap._mfUpdate === 'function') wrap._mfUpdate();
  }
}

// ── 다중 선택 드롭다운 필터 ──
// 초기 상태: 모두 비체크 = 필터 없음 (전체 표시). 사용자가 체크한 항목만 필터 적용.
// "전체" 체크박스 클릭 시 모든 옵션 토글. 일부만 체크 시 "전체" indeterminate.
// 데이터 모델: 모두 비체크 또는 모두 체크 → 빈 배열 반환(=필터 없음). 일부만 체크 → 그 배열 반환.
//
// options = [{value, label, subLabel?, count?}]
//   - subLabel(있으면): 라벨 아래 회색 작은 글씨 (예: 캠페인 번호 B0019-C001)
//   - count(0 이상의 정수면 표시, null/undefined면 미표시): 라벨 옆 (NN) 건수
function createMultiFilter(containerId, allLabel, options, onChange, opts = {}) {
  const wrap = $(containerId);
  if (!wrap) return;
  const btn = wrap.querySelector('.mf-btn');
  const drop = wrap.querySelector('.mf-drop');
  if (!btn || !drop) return;
  // 옵션 행 렌더 — subLabel·count 지원. 초기 비체크 (사용자가 명시적으로 선택해야 필터 적용)
  const renderOptionItem = (o) => {
    const countHtml = (o.count != null) ? ` <span class="mf-item-count">(${o.count})</span>` : '';
    const subHtml = o.subLabel ? `<div class="mf-item-sub">${esc(o.subLabel)}</div>` : '';
    return `<label class="mf-item${o.subLabel ? ' has-sub' : ''}"><input type="checkbox" value="${esc(o.value)}" data-label="${esc(o.label)}"><div class="mf-item-text"><div class="mf-item-label">${esc(o.label)}${countHtml}</div>${subHtml}</div></label>`;
  };
  // 검색형(opt-in) — 옵션이 많은 드롭다운(캠페인 등)에서만 사용. 기본 false → 기존 전 페인 무영향
  const searchHtml = opts.searchable
    ? `<div class="mf-search-box"><input type="search" class="mf-search" autocomplete="off" data-lpignore="true" data-1p-ignore="true" placeholder="${esc(opts.searchPlaceholder || '検索')}"></div>`
    : '';
  const emptyHtml = opts.searchable ? `<div class="mf-search-empty" style="display:none">일치하는 항목이 없습니다</div>` : '';
  // 드롭다운 아이템 생성 — 초기 상태: 모두 비체크 = 필터 없음 (전체 표시)
  drop.innerHTML = searchHtml
    + `<label class="mf-item all-item"><input type="checkbox" value="all"><div class="mf-item-text"><div class="mf-item-label">${esc(allLabel)}</div></div></label>`
    + options.map(renderOptionItem).join('')
    + emptyHtml;
  btn.textContent = allLabel;
  // 토글 — 검색형이면 열 때 검색 input 포커스
  btn.onclick = (e) => {
    e.stopPropagation();
    drop.classList.toggle('open');
    if (opts.searchable && drop.classList.contains('open')) {
      const si = drop.querySelector('.mf-search'); if (si) setTimeout(() => si.focus(), 0);
    }
  };
  // 체크 로직 — 옵션 체크박스만 (검색 input[type=search] 은 제외)
  const allCb = drop.querySelector('input[value="all"]');
  const itemCbs = [...drop.querySelectorAll('input[type="checkbox"]:not([value="all"])')];
  const update = () => {
    const selected = itemCbs.filter(c => c.checked);
    if (selected.length === itemCbs.length) {
      // 모두 체크 = 전체 (필터 없음)
      allCb.checked = true;
      allCb.indeterminate = false;
      btn.textContent = allLabel;
      btn.classList.remove('has-selection');
    } else if (selected.length === 0) {
      // 모두 해제 — 사용자가 「전체」 체크박스를 눌러 전체 해제한 표준 동작.
      // 자동 복귀하지 않고 「선택 없음」 상태 유지. 데이터상으로는 「전체」와 같은
      // 빈 배열을 반환하지만(필터 없음 = 전체 표시), 사용자가 다시 체크하면 정상 동작.
      allCb.checked = false;
      allCb.indeterminate = false;
      btn.textContent = allLabel;
      btn.classList.remove('has-selection');
    } else {
      // 일부 — 전체는 indeterminate
      allCb.checked = false;
      allCb.indeterminate = true;
      // input에 data-label 보관(subLabel/count 영향 없음)
      btn.textContent = selected.map(c => c.dataset.label || c.parentElement.textContent.trim()).join(', ');
      btn.classList.add('has-selection');
    }
    onChange(getMultiFilterValues(containerId));
  };
  allCb.onchange = () => {
    // 전체 토글 — 모든 항목을 같이 체크/해제 (해제 시 update가 자동으로 전체로 복귀)
    itemCbs.forEach(c => c.checked = allCb.checked);
    allCb.indeterminate = false;
    update();
  };
  itemCbs.forEach(c => { c.onchange = update; });
  // 검색형: 입력 시 옵션 행 show/hide (체크 상태·getMultiFilterValues 반환값 불변, 「전체」 항상 노출)
  if (opts.searchable) {
    const si = drop.querySelector('.mf-search');
    const emptyEl = drop.querySelector('.mf-search-empty');
    const optItems = [...drop.querySelectorAll('.mf-item:not(.all-item)')];
    if (si) si.oninput = () => {
      const q = (si.value || '').trim().toLowerCase();
      let visible = 0;
      optItems.forEach(item => {
        const cb = item.querySelector('input[type="checkbox"]');
        const sub = item.querySelector('.mf-item-sub')?.textContent || '';
        const show = matchSearchTokens(q, [cb?.dataset.label || '', sub]);
        item.style.display = show ? '' : 'none';
        if (show) visible++;
      });
      if (emptyEl) emptyEl.style.display = visible === 0 ? '' : 'none';
    };
  }
  // 외부에서 prev 복원 후 다시 호출할 수 있도록 노출
  wrap._mfUpdate = update;
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
  // 전체(모두 체크) = 필터 없음 → 빈 배열
  if (allCb?.checked && !allCb.indeterminate) return [];
  return [...wrap.querySelectorAll('.mf-drop input[type="checkbox"]:not([value="all"]):checked')].map(c => c.value);
}
// 커스텀 confirm 모달 (Promise 반환)
let _confirmResolver = null;
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 범용 확인 모달
// ════════════════════════════════════════════════════════════════════

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
let currentAdminInfo = null;
// ──────────────────────────────────────
// 이미지 라이트박스 — 결과물 이미지(영수증·리뷰 캡쳐)를 새 탭이 아닌
// 같은 페이지 모달로 확대 노출. 인플루언서 위반 증빙 라이트박스(#imageLightbox,
// z-index 900)를 재사용하므로 합본 검수 모달(605) 위에 자동으로 떠 있음.
// ⚠ ui.js 에도 openImageLightbox(url, alt) 가 있다(분리 전부터 존재한 기존 중복).
//    빌드 이어붙이기 순서가 ui.js → admin-core.js 라 이 1인자 버전이 관리자 앱에서 우선 적용된다
//    (분리 전 ui.js → admin.js 와 동일 동작). 관리자 호출처는 모두 1인자 형태. 단일화는 추후 검토.
// ──────────────────────────────────────
function openImageLightbox(url) {
  if (!url) return;
  const img = $('imageLightboxImg');
  if (img) img.src = url;
  openModal('imageLightbox');
}
function closeImageLightbox() {
  closeModal('imageLightbox');
  const img = $('imageLightboxImg');
  if (img) img.src = '';
}

// ──────────────────────────────────────
// 관리자 모달 드래그·리사이즈 (2026-05-29, 사양서 docs/specs/2026-05-28-admin-modal-draggable.md)
//   - 큰 입력/상세/검수 모달만 대상 (DRAGGABLE_ADMIN_MODALS 화이트리스트). 작은 확인·알럿·라이트박스는 제외.
//   - 적용 시점: overlay 에 .open 이 붙는 순간을 MutationObserver 로 감지 → open 방식(openModal/직접 classList) 무관 일괄 적용.
//   - 매 열림: 화면 가운데로 위치·크기 초기화 (사양서 결정 — 위치 저장은 v2).
//   - mousemove/mouseup 리스너는 모달당 1회만 등록(dataset.dragInit 가드, 중복 누적 방지). 헤더 드래그, 닫기·입력 요소 제외, 헤더 일부 항상 화면 안(클램프).
// ──────────────────────────────────────
const DRAGGABLE_ADMIN_MODALS = new Set([
  // 인플루언서
  'influencerFullDetailModal', 'infDetailModal', 'influencerFlagEditModal',
  // 캠페인·번들
  'campPreviewModal', 'campBundleModal', 'psetEditModal', 'csetEditModal', 'nsetEditModal', 'cautionHistoryModal',
  // 신청·결과물
  'delivDetailModal', 'delivCombinedModal', 'delivRejectModal', 'adminProxyDelivModal',
  // 브랜드 서베이·회사
  'companyModal', 'brandAssignModal', 'brandDetailModal', 'newBrandAppModal', 'brandAppMemoModal', 'brandAppHistoryModal', 'linkCampaignModal',
  // 공지·기준데이터·계정
  'adminNoticeEditModal', 'adminNoticeViewModal', 'lookupEditModal', 'faqEditModal', 'addAdminModal', 'adminEmailSubsModal',
  // 메시지
  'admMsgModal', 'admHideModal',
  // 일괄 발송 (PR 3) — 대상 선택·발송 상세는 내용이 길어 드래그·리사이즈 유용
  'bulkMessageModal', 'broadcastDetailModal',
]);

function makeModalDraggableResizable(modalEl) {
  if (!modalEl) return;
  modalEl.classList.add('draggable');

  // 최초 1회: 모달 원래 인라인 max-width/max-height 백업 (열 때마다 기본 크기 복원용).
  if (modalEl.dataset.origMaxW === undefined) {
    modalEl.dataset.origMaxW = modalEl.style.maxWidth || '';
    modalEl.dataset.origMaxH = modalEl.style.maxHeight || '';
  }

  // 매 열림 초기화 — 위치·크기·최대치 제거 → CSS 기본(정중앙 transform) + 모달 원래 크기·최대폭 복원.
  modalEl.style.left = '';
  modalEl.style.top = '';
  modalEl.style.transform = '';
  modalEl.style.width = '';
  modalEl.style.height = '';
  modalEl.style.maxWidth = modalEl.dataset.origMaxW;
  modalEl.style.maxHeight = modalEl.dataset.origMaxH;

  if (modalEl.dataset.dragInit) return;  // 핸들·리스너는 모달당 1회만 등록
  modalEl.dataset.dragInit = '1';

  // transform 기반 정중앙 → 드래그/리사이즈 시작 시 1회 left/top/width/height px 로 고정(transform 해제).
  //   + max-width/height 제한 해제 → 리사이즈로 화면 끝까지 넓게 볼 수 있음(닫았다 열면 위 초기화로 기본 크기 복원).
  const pinPosition = () => {
    // 인라인 transform 이 '' (CSS translate(-50%,-50%) 활성) 또는 다른 값이면 px 로 고정.
    // 'none'(이미 고정됨)일 때만 스킵 — 빈 문자열을 falsy 로 누락하면 드래그 시작 시 모달이 왼쪽으로 튐.
    if (modalEl.style.transform !== 'none') {
      const r = modalEl.getBoundingClientRect();   // ★ max 해제 전 현재 크기 측정 (94vw 등이 max 풀리며 튀는 것 방지)
      modalEl.style.left = r.left + 'px';
      modalEl.style.top = r.top + 'px';
      modalEl.style.width = r.width + 'px';
      modalEl.style.height = r.height + 'px';
      modalEl.style.transform = 'none';
    }
    // width/height 를 현재 px 로 고정한 뒤에 max 제한 해제 → 리사이즈로만 넓어지고 클릭 즉시 튀지 않음.
    modalEl.style.maxWidth = 'none';
    modalEl.style.maxHeight = 'none';
  };

  // ── 드래그(이동) 핸들 결정 ──
  //   기본은 .modal-header 를 드래그 핸들로 사용(2026-05-29 구조 통일로 표준 모달은 모두 header 보유).
  //   .modal-header 없는 비표준 모달만 .modal-body 첫 요소를 fallback 핸들로 사용.
  let dragHandle = modalEl.querySelector('.modal-header');
  if (!dragHandle) {
    const bodyEl = modalEl.querySelector('.modal-body');
    if (bodyEl && bodyEl.firstElementChild) {
      dragHandle = bodyEl.firstElementChild;
      dragHandle.style.cursor = 'move';
      dragHandle.style.userSelect = 'none';
    }
  }
  let drag = null;
  if (dragHandle) {
    dragHandle.addEventListener('mousedown', (e) => {
      if (e.target.closest('.modal-close, input, textarea, select, button, a')) return;
      pinPosition();
      const r = modalEl.getBoundingClientRect();
      drag = { dx: e.clientX - r.left, dy: e.clientY - r.top };
      document.body.style.userSelect = 'none';
      e.preventDefault();
    });
  }

  // ── 8방향 리사이즈 핸들 (상하좌우 + 4모서리). 커서만으로 표시, 무늬 없음 ──
  let rsz = null;
  const MINW = 320, MINH = 160;
  ['n','s','e','w','ne','nw','se','sw'].forEach((dir) => {
    const h = document.createElement('div');
    h.className = 'modal-rsz modal-rsz-' + dir;
    h.addEventListener('mousedown', (e) => {
      e.preventDefault();
      e.stopPropagation();
      pinPosition();
      const r = modalEl.getBoundingClientRect();
      rsz = { dir, x: e.clientX, y: e.clientY, w: r.width, h: r.height, l: r.left, t: r.top };
      document.body.style.userSelect = 'none';
    });
    modalEl.appendChild(h);
  });

  // 공용 mousemove/mouseup — 드래그·리사이즈 모두 처리 (모달당 1쌍, dragInit 가드로 중복 없음)
  document.addEventListener('mousemove', (e) => {
    if (drag) {
      const left = Math.max(-100, Math.min(window.innerWidth - 100, e.clientX - drag.dx));
      const top = Math.max(0, Math.min(window.innerHeight - 60, e.clientY - drag.dy));
      modalEl.style.left = left + 'px';
      modalEl.style.top = top + 'px';
    } else if (rsz) {
      const dx = e.clientX - rsz.x, dy = e.clientY - rsz.y;
      let w = rsz.w, h = rsz.h, l = rsz.l, t = rsz.t;
      if (rsz.dir.includes('e')) w = Math.max(MINW, rsz.w + dx);
      if (rsz.dir.includes('s')) h = Math.max(MINH, rsz.h + dy);
      if (rsz.dir.includes('w')) { w = Math.max(MINW, rsz.w - dx); l = rsz.l + (rsz.w - w); }
      if (rsz.dir.includes('n')) { h = Math.max(MINH, rsz.h - dy); t = rsz.t + (rsz.h - h); }
      modalEl.style.width = w + 'px';
      modalEl.style.height = h + 'px';
      modalEl.style.left = l + 'px';
      modalEl.style.top = t + 'px';
    }
  });
  document.addEventListener('mouseup', () => {
    if (drag || rsz) { drag = null; rsz = null; document.body.style.userSelect = ''; }
  });
}

// overlay 에 .open 이 추가되면 화이트리스트 모달에 드래그·리사이즈 적용
function _applyDraggableIfOpen(overlay) {
  if (!overlay.classList.contains('open')) return;
  if (!DRAGGABLE_ADMIN_MODALS.has(overlay.id)) return;
  const modal = overlay.querySelector('.modal');
  if (modal) makeModalDraggableResizable(modal);
}

// 관리자 부트 시 1회 호출 (admin/app.js). 정적 overlay(index.html) 전부에 class 변화 옵저버 부착.
function initDraggableModals() {
  document.querySelectorAll('.modal-overlay').forEach((overlay) => {
    if (overlay.dataset.dragObserved) return;
    overlay.dataset.dragObserved = '1';
    new MutationObserver(() => _applyDraggableIfOpen(overlay))
      .observe(overlay, { attributes: true, attributeFilter: ['class'] });
  });
}
