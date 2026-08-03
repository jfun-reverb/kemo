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
      parts.forEach(p => { const v = p.replace(/[#@\uFF03\uFF20]/g, '').trim(); if (v) addTag(wrapId, targetId, prefix, v); });
      input.value = '';
    }
  });

  input.addEventListener('keydown', e => {
    if (e.key === 'Enter') {
      e.preventDefault();
      // 중간 공백이 든 채로 한 덩어리 태그가 만들어지지 않게 공백에서도 끊는다
      // (해시태그·멘션은 공백을 담을 수 없고, 담기면 저장·재편집에서 뭉개진다)
      input.value.replace(/[,#@\uFF03\uFF20]/g, '').split(/\s+/).map(s => s.trim()).filter(Boolean)
        .forEach(v => addTag(wrapId, targetId, prefix, v));
      input.value = '';
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
  // ⚠️ 구분자는 쉼표 + 공백 둘 다.
  //    저장은 쉼표로 하지만 예전 데이터·손입력은 「#テスト #韓国スナック」처럼 공백으로 구분돼 있다.
  //    쉼표로만 나누면 통째로 한 덩어리가 되고 안쪽 # 이 전부 지워져,
  //    편집 저장 한 번에 여러 태그가 하나로 뭉개진다(2026-07-27 운영 확인).
  //    해시태그·멘션은 값 안에 공백이 들어가면 안 되는 값이라(입력 단계에서도 공백으로 끊음)
  //    공백을 구분자로 써도 안전하다.
  value.split(/[,\s]+/).map(s => s.replace(/[#@\uFF03\uFF20]/g, '').trim()).filter(Boolean)
    .forEach(t => addTag(wrapId, targetId, prefix, t));
}

// 에러 메시지를 한국어로 변환
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 친화적 에러 메시지
// ════════════════════════════════════════════════════════════════════

function friendlyError(msg) {
  if (!msg) return '알 수 없는 오류 [ERR_UNKNOWN]';
  const s = String(msg);
  // 마이그레이션 251 — 정산 기록이 있는 대상 삭제 차단(사전 체크 트리거)
  if (s.includes('settlement_exists_cannot_delete')) return '정산 기록이 있어 삭제할 수 없습니다. 먼저 정산 관리 화면에서 상태를 확인해 주세요. [ERR_SETTLEMENT_EXISTS]';
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
  if (s.includes('violates check constraint') || s.includes('check_violation')) return '허용되지 않는 값입니다. 입력 내용을 다시 확인해주세요. [ERR_CHECK_23514]';
  // DB 트리거·함수(RAISE)가 한글 안내 메시지를 던지면 그대로 보여준다 (예: 「모집마감 캠페인의 주의사항은…」)
  if (/[가-힣]/.test(s)) return s;
  // 미분류 영어 원문 — 화면에는 일반 안내만 노출하고, 원문은 콘솔에 기록(운영자 추적용)
  try { console.warn('[friendlyError unhandled]', s); } catch (_) {}
  return '처리 중 오류가 발생했습니다. 잠시 후 다시 시도하거나 관리자에게 문의해주세요. [ERR_UNHANDLED]';
}

// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 페인 라우팅 (switchAdminPane)
//   각 페인 진입 함수를 이름으로 참조하므로, 페인 분리 후에도 전역
//   에 살아 있어야 한다. 새 페인 추가 시 loaders 객체에도 등록.
// ════════════════════════════════════════════════════════════════════

function switchAdminPane(pane, el, pushHistory) {
  // 동적 권한 진입 가드 (PR2 조각 C) — 화면 표시 제어. ⚠️ 클라 가드일 뿐 데이터는 서버가 여전히 반환(실차단은 PR3 서버 가드).
  //   ① permissions 는 super_admin 전용. ② menu.* 가 hidden 인 페인은 대시보드로 리다이렉트(dashboard 자체는 무한 재귀 방지로 항상 허용).
  const _isSuper = (typeof currentAdminInfo !== 'undefined' && currentAdminInfo && currentAdminInfo.role === 'super_admin');
  if (pane === 'permissions') {
    // ⚠️ 권한 관리 화면은 등급만 보고 판단하며, 숨김 설정을 절대 적용하지 않는다.
    //    슈퍼관리자가 스스로를 제한할 수 있게 되면서(마이그레이션 268~270), 이 화면까지
    //    숨길 수 있으면 되돌릴 방법이 없어진다. 여기가 유일한 복구 경로다.
    if (!_isSuper) {
      if (typeof toast === 'function') toast('권한 관리 화면은 슈퍼관리자만 접근할 수 있습니다.', 'error');
      return switchAdminPane('dashboard', null, pushHistory);
    }
  } else if (pane !== 'dashboard' && typeof isHidden === 'function' && isHidden('menu.' + pane)) {
    if (typeof toast === 'function') toast('접근 권한이 없는 메뉴입니다.', 'error');
    return switchAdminPane('dashboard', null, pushHistory);
  }
  // Vercel Web Analytics — 관리자 앱 페인별 접속 카운트
  try {
    if (typeof window.va === 'function') {
      window.va('event', { name: 'pv_admin', page: pane });
    }
  } catch (e) { /* analytics 실패 무시 */ }

  // 오리엔시트 발행 컨텍스트는 add-campaign 진입마다 초기화 (수동 신규 캠페인이 오리엔 발행으로 오인되지 않도록).
  // 오리엔 발행 경로(applyOrientCardPrefill)는 switchAdminPane 호출 직후 컨텍스트를 다시 세팅한다.
  if (pane === 'add-campaign') window._orientPublishCtx = null;
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
    'settlements': loadSettlements,
    'outbound': loadOutbound,
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
    'errors': loadClientErrors,
    'upcoming': renderUpcomingFeatures,
    'orient-sheets': loadOrientSheets,
    'permissions': loadPermissionsPane
  };
  // 브라우저 히스토리 기록 (뒤로가기 지원)
  if (pushHistory !== false) {
    history.pushState({pane: pane}, '', '#' + pane);
  }
  if (pane === 'add-campaign') {
    // ★ 행사 모드 초기화를 **가장 먼저** 한다.
    //   안 하면 직전에 켠 체크박스가 남아, 바로 아래에서 모집 형식을 리뷰어로 되돌리는
    //   순간 「행사 모드 ON + 리뷰어형」이라는 금지 조합이 되어 다음 캠페인 등록이
    //   데이터베이스 제약(마이그레이션 280)에 걸려 통째로 실패한다. 그 오류 문구로는
    //   원인이 화면 위쪽 체크박스라는 걸 알 수 없다(2026-08-03 리뷰 지적).
    if (typeof resetEventFormFields === 'function') resetEventFormFields('new');
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
  // 캠페인 상태 필터는 다중선택 드롭다운 → 상태별 탭(admin.js CAMP_STATUS_TABS)으로 교체됨
  // 신청관리
  createMultiFilter('appTypeMulti', '전체 타입', [
    {value:'monitor',label:'리뷰어'},{value:'gifting',label:'기프팅'},{value:'visit',label:'방문형'}
  ], () => renderAppCampList());
  // 신청 상태는 다중 필터가 아니라 상태 탭(appStatusTabBar)으로 분리 — admin-applications.js 참조
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
  // 인증 상태는 다중 필터가 아니라 상태 탭(delivCertStatusTabBar)으로 분리 — admin-deliverables.js 참조
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
  const short = `<div style="max-width:280px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-size:12px;color:var(--ink)">${safe}</div>`;
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
  if (btn) { btn.textContent = allLabel; btn.classList.remove('has-selection'); btn.removeAttribute('title'); }
}
// 모두 해제 — 일괄발송처럼 "명시 선택 강제" 맥락에서 사용.
//   resetMultiFilter 는 "전체=모두 체크"(빈 배열 시맨틱)라 미선택 표현이 안 됨.
//   이 헬퍼는 전체 해제 + placeholder 라벨 → getMultiFilterValues 가 [] 반환(=대상 없음으로 처리).
function clearMultiFilter(containerId, placeholderLabel) {
  const wrap = $(containerId);
  if (!wrap) return;
  wrap.querySelectorAll('.mf-drop input[type="checkbox"]').forEach(c => { c.checked = false; c.indeterminate = false; });
  const btn = wrap.querySelector('.mf-btn');
  if (btn) { btn.textContent = placeholderLabel || '선택'; btn.classList.remove('has-selection'); btn.removeAttribute('title'); }
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
      + `<button type="button" class="mf-search-only" style="display:none;width:calc(100% - 16px);margin:0 8px 4px;font-size:12px;font-weight:700;color:var(--pink,#1A1A1A);background:var(--light-pink,#F4F4F5);border:1px solid var(--pink,#1A1A1A);border-radius:6px;padding:5px 8px;cursor:pointer">이 검색 결과만 선택</button>`
    : '';
  const emptyHtml = opts.searchable ? `<div class="mf-search-empty" style="display:none">일치하는 항목이 없습니다</div>` : '';
  // 드롭다운 아이템 생성 — 초기 상태: 모두 비체크 = 필터 없음 (전체 표시)
  drop.innerHTML = searchHtml
    + `<label class="mf-item all-item"><input type="checkbox" value="all"><div class="mf-item-text"><div class="mf-item-label">${esc(allLabel)}</div></div></label>`
    + options.map(renderOptionItem).join('')
    + emptyHtml;
  btn.textContent = opts.placeholder || allLabel;   // placeholder(있으면 미선택 안내) 우선, 없으면 allLabel
  // 토글 — 열 때 선택 항목을 상단으로 재정렬(체크 토글 중엔 순서 고정, 열 때만 1회), 검색형이면 검색 input 포커스
  btn.onclick = (e) => {
    e.stopPropagation();
    const willOpen = !drop.classList.contains('open');
    drop.classList.toggle('open');
    if (willOpen) {
      reorderSelectedFirst(drop);
      if (opts.searchable) {
        const si = drop.querySelector('.mf-search'); if (si) setTimeout(() => si.focus(), 0);
      }
    }
  };
  // 체크 로직 — 옵션 체크박스만 (검색 input[type=search] 은 제외)
  const allCb = drop.querySelector('input[value="all"]');
  const itemCbs = [...drop.querySelectorAll('input[type="checkbox"]:not([value="all"])')];
  const update = () => {
    const selected = itemCbs.filter(c => c.checked);
    if (selected.length === itemCbs.length) {
      // 모두 체크 = 전체. countLabel(명시 선택형, 일괄발송 캠페인)이면 「다중 선택 N건」, 아니면 allLabel
      allCb.checked = true;
      allCb.indeterminate = false;
      btn.textContent = opts.countLabel ? ('다중 선택 ' + selected.length + '건') : allLabel;
      btn.removeAttribute('title');
      btn.classList.toggle('has-selection', !!opts.countLabel);
    } else if (selected.length === 0) {
      // 모두 해제 — placeholder(있으면 「선택하세요」 안내) 우선. 없으면 allLabel(미선택=전체 시맨틱).
      allCb.checked = false;
      allCb.indeterminate = false;
      btn.textContent = opts.placeholder || allLabel;
      btn.removeAttribute('title');
      btn.classList.remove('has-selection');
    } else {
      // 일부 — 전체는 indeterminate. 1건이면 항목명, 2건 이상이면 「다중 선택 N건」(선택 항목명은 tooltip 보존)
      allCb.checked = false;
      allCb.indeterminate = true;
      const names = selected.map(c => c.dataset.label || c.parentElement.textContent.trim());
      btn.textContent = selected.length === 1 ? names[0] : ('다중 선택 ' + selected.length + '건');
      btn.title = names.join(', ');
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
    const onlyBtn = drop.querySelector('.mf-search-only');
    const allItem = drop.querySelector('.all-item');
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
      // 검색 중엔 「전체」 항목을 숨기고 「이 검색 결과만 선택」 버튼으로 대체(검색어 지우면 「전체」 복귀).
      if (allItem) allItem.style.display = q ? 'none' : '';
      if (onlyBtn) onlyBtn.style.display = (q && visible > 0) ? '' : 'none';
    };
    // 검색에 보이는 항목만 선택(나머지 해제) → 그 캠페인들만 필터링. 「전체」 체크 상태도 자동 해제(부분 선택).
    // itemCbs는 createMultiFilter 시점 스냅샷 — reorderSelectedFirst 로 DOM 순서가 바뀌어도 display 기준 판정이라 정합성 무영향.
    if (onlyBtn) onlyBtn.onclick = (e) => {
      e.stopPropagation();
      itemCbs.forEach(c => { c.checked = (c.closest('.mf-item')?.style.display !== 'none'); });
      update();
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

// ── 도도부현·팔로워 공용 분류 헬퍼 (인플 조합 필터·대시보드 재사용) ──
// prefecture 값을 「정식 도도부현 키(일본어)」 | '未登録' | '海外' 로 분류.
//  · NULL/빈값 = 未登録, PREFECTURE_KO 키에 있으면 정식, 그 외 비어있지 않은 값 = 海外
function classifyPrefecture(pref) {
  const p = (pref == null) ? '' : String(pref).trim();
  if (!p) return '未登録';
  const map = (typeof PREFECTURE_KO !== 'undefined') ? PREFECTURE_KO : {};
  return map[p] ? p : '海外';
}

// 채널 기준 팔로워 수. 'all'(또는 미지정)이면 4개 채널 합계, 특정 채널이면 그 채널만.
//  · LIPS·@cosme 는 팔로워 컬럼이 없어 합계에서 제외됨
function followerValueByChannel(u, ch) {
  const map = { instagram: 'ig_followers', x: 'x_followers', tiktok: 'tiktok_followers', youtube: 'youtube_followers' };
  if (ch && map[ch]) return u[map[ch]] || 0;
  return (u.ig_followers || 0) + (u.x_followers || 0) + (u.tiktok_followers || 0) + (u.youtube_followers || 0);
}

// 드롭다운 열 때 선택된 항목을 「전체」 항목 바로 아래로 모으고 구분선 삽입(선택 항목 상단 정렬).
// 열 때 1회만 호출 → 체크 토글 중에는 순서가 튀지 않음. 한쪽만 있으면(전부/없음) 정렬 생략.
function reorderSelectedFirst(drop) {
  if (!drop) return;
  drop.querySelectorAll('.mf-selected-divider').forEach(d => d.remove());
  const items = [...drop.querySelectorAll('.mf-item:not(.all-item)')];
  const checked = items.filter(it => it.querySelector('input[type="checkbox"]')?.checked);
  const unchecked = items.filter(it => !it.querySelector('input[type="checkbox"]')?.checked);
  if (!checked.length || !unchecked.length) return;
  // 기준점: 「전체」 항목(없으면 검색창) 뒤에 선택→구분선→미선택 순으로 재배치
  let ref = drop.querySelector('.all-item') || drop.querySelector('.mf-search-box');
  if (!ref) return;
  checked.forEach(it => { ref.after(it); ref = it; });
  const divider = document.createElement('div');
  divider.className = 'mf-selected-divider';
  ref.after(divider);
  ref = divider;
  unchecked.forEach(it => { ref.after(it); ref = it; });
}
// 커스텀 confirm 모달 (Promise 반환)
let _confirmResolver = null;
// ════════════════════════════════════════════════════════════════════
// SECTION: CORE — 범용 확인 모달
// ════════════════════════════════════════════════════════════════════

// showConfirm(message[, okLabel, cancelLabel])
//   버튼 이름을 상황에 맞게 지정할 수 있다(2026-07-30). 안 주면 「확인/취소」 기본값이라
//   기존 호출부는 전혀 영향받지 않는다.
//   ⚠️ 버튼이 「확인/취소」로 고정돼 있던 탓에 「취소하면 저장되지 않습니다」 같은 설명을 본문에
//      욱여넣어야 했고 문구가 어색해졌다. 되돌릴 수 없는 동작은 버튼 이름에 행동을 적는 게 안전하다.
function showConfirm(message, okLabel, cancelLabel) {
  return new Promise(resolve => {
    _confirmResolver = resolve;
    const msg = $('confirmModalMessage');
    if (msg) msg.textContent = message;
    const okBtn = $('confirmModalOkBtn');
    const cancelBtn = $('confirmModalCancelBtn');
    if (okBtn) okBtn.textContent = okLabel || '확인';
    if (cancelBtn) cancelBtn.textContent = cancelLabel || '취소';
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
let _lbZoom = 1;
const LB_ZOOM_MIN = 0.5, LB_ZOOM_MAX = 5;
function openImageLightbox(url) {
  if (!url) return;
  const img = $('imageLightboxImg');
  if (img) img.src = url;
  _lbZoom = 1;            // 열 때마다 배율 초기화
  applyLightboxZoom();
  openModal('imageLightbox');
}
function closeImageLightbox() {
  closeModal('imageLightbox');
  const img = $('imageLightboxImg');
  if (img) img.src = '';
}
// 이미지 배율 적용 — 1배는 창에 맞춤(contain), 1배 초과는 width %로 키우고 넘치면 modal-body 스크롤
function applyLightboxZoom() {
  const img = $('imageLightboxImg');
  if (!img) return;
  const body = img.parentElement;
  if (Math.abs(_lbZoom - 1) < 0.001) {
    img.style.maxWidth = '100%'; img.style.maxHeight = '100%';
    img.style.width = ''; img.style.height = '';
    // 1배는 창 중앙
    if (body) { body.style.alignItems = 'center'; body.style.justifyContent = 'center'; }
  } else {
    img.style.maxWidth = 'none'; img.style.maxHeight = 'none';
    img.style.width = Math.round(_lbZoom * 100) + '%';
    img.style.height = 'auto';
    // 줌인 시 flex 중앙 정렬이 오버플로 상단·좌측을 잘라 스크롤 접근을 막으므로 시작점 정렬로 전환
    if (body) { body.style.alignItems = 'flex-start'; body.style.justifyContent = 'flex-start'; }
  }
  const lbl = $('lightboxZoomLabel');
  if (lbl) lbl.textContent = Math.round(_lbZoom * 100) + '%';
}
function lightboxZoom(delta) {
  _lbZoom = Math.max(LB_ZOOM_MIN, Math.min(LB_ZOOM_MAX, Math.round((_lbZoom + delta) * 100) / 100));
  applyLightboxZoom();
}
function lightboxZoomReset() { _lbZoom = 1; applyLightboxZoom(); }

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
  // 채널 어긋남 경고 — 조치 방법을 보면서 다른 화면을 조작해야 하므로 드래그·크기 조정 필수
  'channelDriftModal',
  // 신청·결과물
  'delivDetailModal', 'delivCombinedModal', 'delivRejectModal', 'adminProxyDelivModal',
  // 브랜드 서베이·회사
  'companyModal', 'brandAssignModal', 'brandDetailModal', 'newBrandAppModal', 'brandAppMemoModal', 'brandAppHistoryModal', 'linkCampaignModal', 'brandAppOrientListModal',
  // 공지·기준데이터·계정
  'adminNoticeEditModal', 'adminNoticeViewModal', 'lookupEditModal', 'faqEditModal', 'addAdminModal', 'adminEmailSubsModal',
  // 오리엔시트 (동적 생성 — ensureOrientModals 가 initDraggableModals 재호출로 옵저버 부착)
  'orientDetailModal', 'orientCreateModal', 'orientPublishModal',
  // 메시지
  'admMsgModal', 'admHideModal',
  // 일괄 발송 (PR 3) — 대상 선택·발송 상세는 내용이 길어 드래그·리사이즈 유용
  'bulkMessageModal', 'broadcastDetailModal',
  // 이미지 확대 창 — 배경 안 덮고(뒤 화면 조작 가능) 드래그·리사이즈로 영수증 보며 입력
  'imageLightbox',
  // 아웃바운드 인플루언서 명단 등록·편집 (입력 항목 많아 드래그·리사이즈 유용)
  'outboundEditModal',
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

// ════════════════════════════════════════════════════════════════════
// SECTION: 채널 코드 어긋남 경보 배너 (마이그레이션 277·278)
// ════════════════════════════════════════════════════════════════════
//   2026-07-30 @cosme 사고 — 승인된 리뷰 인증샷 55건이 두 달간 화면·인증 성공·정산
//   세 곳에서 사라져 보였는데 **감지 수단이 없어 아무도 몰랐다.** 그 감지 결과를
//   사람이 매일 보는 자리에 띄운다.
//
//   ⚠️ **0건이면 아무것도 그리지 않는다.** 숫자가 늘 떠 있으면 「원래 빨간 게 있는
//      화면」으로 학습되어, 정작 진짜 문제가 생겼을 때 또 두 달을 놓친다. 운영 실측을
//      A·B·C 전부 0으로 만든 뒤에 이 배너를 켰다(2026-07-31).
//   ⚠️ 조회 실패 시에도 안 그린다 — 감지 실패가 본 업무를 막지 않는다.

// 층별 의미 — 사람이 읽을 문구. 코드가 아니라 「무엇이 잘못됐는지」를 말한다.
//   ⚠️ `fix` 는 **담당자가 실제로 무엇을 눌러야 하는지**를 말한다. 원인만 알리고 조치를
//      안 알려주면 담당자가 「그래서 뭘 어떻게?」에서 막히고, 결국 경고를 무시하게 된다 —
//      그러면 배너를 안 만든 것과 같아진다(2026-07-31 사용자 지적).
//   ⚠️ `fix` 만 `esc()` 없이 그대로 넣는다(강조 태그 `<b>` 를 쓰기 위해). **여기 있는
//      세 문구는 전부 코드 상수**라 안전하다 — 데이터베이스나 사용자 입력에서 온 값은
//      이 표에 절대 넣지 말 것. 배너의 다른 값(캠페인명·채널 코드)은 전부 `esc()` 를 거친다.
const CHANNEL_DRIFT_LAYERS = {
  A: {
    label: '지금 판정에서 빠져 있는 결과물',
    desc: '캠페인이 요구하지 않는 채널로 저장돼 있어, 인플루언서 화면·인증 성공·정산에서 함께 빠집니다.',
    severe: true
  },
  B: {
    label: '기준 데이터에 없는 채널을 쓰는 캠페인',
    desc: '아직 결과물은 멀쩡하지만, 이 상태로 결과물이 쌓이면 위 문제로 이어집니다.',
    severe: false
  },
  C: {
    label: '기준 데이터에 없는 채널로 제출된 결과물',
    desc: '어떤 캠페인 채널과도 영영 일치하지 않는 값입니다.',
    severe: false
  }
};

// 조치 안내 — **결과물 종류(kind)마다 실제로 할 수 있는 일이 다르다.**
//   ⚠️ 「검수 창의 채널 불일치 표시에서 지운다」는 도구는 **게시물(post)에만 있다**
//      (admin-deliverables.js 의 mismatchedBox·deleteMismatchedPostRow 는 kind='post'
//      전용이고 그것도 시딩·방문형에서만 계산된다). **리뷰 인증샷(review_image)은
//      채널이 어긋나면 그 채널로 조회되지 않아 검수 창에 아예 안 나타난다** — 정리
//      도구가 없다. 2026-07-30 @cosme 사고가 정확히 이 경우였다.
//      종류를 안 가리고 「검수 창에서 지우세요」라고 안내하면, 정작 같은 사고가 또 났을 때
//      **없는 도구를 찾게 만든다.** 그래서 종류별로 분기하고, 도구가 없으면 없다고 말한다.
//   반환값은 HTML(강조 태그 포함) — 전부 코드 상수라 esc 하지 않는다. 데이터에서 온 값을
//   이 문자열에 절대 끼워 넣지 말 것.
function channelDriftFixHtml(layer, kind) {
  const CLEANUP_POST =
    '결과물 관리에서 그 건의 검수 창을 열면 「채널 불일치」 표시가 있고, <b>슈퍼관리자</b>가 그 행을 지울 수 있습니다(이미 승인된 결과물은 보호되어 안 지워집니다).';
  const CLEANUP_REVIEW =
    '<b>리뷰 인증샷은 관리자 화면에 정리 도구가 없습니다.</b> 채널이 어긋나면 검수 창에서 그 채널로 조회되지 않아 화면에 나타나지 않습니다(2026-07-30 사고가 이 경우였습니다). <b>개발 담당자에게 알려 데이터베이스에서 직접 고쳐야 합니다.</b>';
  const cleanup = (kind === 'review_image') ? CLEANUP_REVIEW : CLEANUP_POST;

  if (layer === 'A') {
    return '<b>둘 중 어느 쪽이 맞는지 먼저 정하세요.</b><br>' +
      '① <b>캠페인 쪽이 맞다면</b>(그 채널은 원래 안 받는 게 맞다) 결과물을 정리합니다 — ' + cleanup + '<br>' +
      '② <b>결과물 쪽이 맞다면</b>(인플루언서가 실제로 그 채널에 올린 게 맞다) 아래 「캠페인 편집 열기」로 가서 그 채널을 체크해 추가합니다. ' +
      '단 모집 형식에서 고를 수 없는 채널이면 이 길은 막혀 있어 ①만 가능합니다.';
  }
  if (layer === 'B') {
    return '아래 「캠페인 편집 열기」로 가서 <b>채널을 올바른 값으로 다시 고르세요.</b> ' +
      '그 채널이 원래 있어야 하는 것이라면, 기준 데이터에서 같은 코드로 다시 만들어도 됩니다.';
  }
  // C — 기준 데이터에 없는 값이라 캠페인에 추가하는 길 자체가 없다
  return '<b>결과물을 정리하는 것 말고는 방법이 없습니다.</b> 기준 데이터에 없는 값이라 캠페인에 추가할 수도 없습니다.<br>' +
    '이 항목은 캠페인이 특정되지 않습니다(여러 캠페인의 값이 함께 묶일 수 있음). ' +
    '결과물 관리에서 <b>위에 적힌 채널 값</b>으로 찾은 뒤 정리하세요 — ' + cleanup;
}

// ── 감지 결과 상태 ──
//   부팅 시 1회 조회해 사이드바에 표시한다. **화면에 들어가야만 알 수 있으면 늦다** —
//   이번 사고가 「두 달간 아무도 몰랐다」였으므로 어느 화면에 있든 눈에 띄어야 한다.
let _channelDriftRows = null;   // null = 아직 조회 안 함 / [] = 어긋남 없음

// 감지 결과를 새로 받아 사이드바 표시·페인 버튼을 갱신한다.
//   0건이면 전부 숨긴다 — 숫자가 늘 떠 있으면 「원래 빨간 게 있는 화면」으로 학습돼
//   정작 진짜 문제를 또 놓친다.
async function refreshChannelDriftIndicators() {
  const rows = await fetchChannelDriftAlerts();
  _channelDriftRows = Array.isArray(rows) ? rows : [];
  applyChannelDriftIndicators();
}

// 캐시된 결과로 사이드바·페인 버튼을 다시 그린다(재조회 없음).
function applyChannelDriftIndicators() {
  const rows = _channelDriftRows || [];
  const has = rows.length > 0;
  const severe = rows.some(function(r) { return r.layer === 'A'; });
  const total = rows.reduce(function(n, r) { return n + Number(r.affected_count || 0); }, 0);

  // 사이드바 — 결과물 관리(발견하는 자리)·기준 데이터(원인을 만드는 자리) 두 곳.
  //   ⚠️ **메뉴 아이콘 자체를 경고 모양으로 바꾼다**(별도 표시를 옆에 붙이지 않는다).
  //      접힌 사이드바에서는 아이콘만 보이므로, 아이콘이 바뀌어야 접힌 상태에서도 눈에 띈다.
  //      원래 아이콘 이름은 data 속성에 보관해 두고 경고가 없어지면 그대로 되돌린다 —
  //      하드코딩해 두면 나중에 메뉴 아이콘을 바꿀 때 여기가 stale 이 된다.
  //   ⚠️ 아이콘 클릭은 **기존대로 화면 이동**이다. 모달은 그 화면의 제목 옆 버튼으로 연다
  //      (작은 아이콘에 다른 동작을 얹으면 메뉴를 누르려다 모달이 뜬다).
  [['adminDelivSi', 'fact_check'], ['adminLookupsSi', 'tune']].forEach(function(pair) {
    const item = document.getElementById(pair[0]);
    if (!item) return;
    const icon = item.querySelector('.si-icon');
    if (!icon) return;
    if (!icon.dataset.baseIcon) icon.dataset.baseIcon = (icon.textContent || pair[1]).trim();
    if (has) {
      icon.textContent = 'report_problem';
      icon.style.color = severe ? '#C33' : '#B8741A';
      item.title = `채널 코드가 어긋난 항목 ${total}건 — 이 화면에서 조치 방법을 볼 수 있습니다`;
    } else {
      icon.textContent = icon.dataset.baseIcon;
      icon.style.color = '';
      item.title = '';
    }
  });

  // 페인 제목 옆 버튼 — 경고가 없으면 버튼 자체를 감춘다
  ['delivDriftBtn', 'lookupDriftBtn'].forEach(function(id) {
    const btn = document.getElementById(id);
    if (!btn) return;
    btn.style.display = has ? 'inline-flex' : 'none';
    if (!has) return;
    btn.style.background = severe ? '#FFF5F5' : '#FEF3C7';
    btn.style.borderColor = severe ? '#C33' : '#FBBF24';
    btn.style.color = severe ? '#C33' : '#92400E';
    btn.innerHTML = `<span class="material-icons-round notranslate" translate="no" style="font-size:15px">report_problem</span> 채널 어긋남 ${total}건`;
  });
}

// 경고 모달 — 조치 방법을 보면서 따라 할 수 있게 **띄워둔 채 다른 화면을 조작**할 수 있다
//   (DRAGGABLE_ADMIN_MODALS 등록 → 드래그·크기 조정 가능).
async function openChannelDriftModal() {
  const body = document.getElementById('channelDriftModalBody');
  const overlay = document.getElementById('channelDriftModal');
  if (!body || !overlay) return;
  overlay.classList.add('open');
  if (_channelDriftRows === null) {
    body.innerHTML = '<div style="padding:16px;text-align:center;color:var(--muted);font-size:13px">확인 중…</div>';
    await refreshChannelDriftIndicators();
  }
  body.innerHTML = channelDriftModalHtml(_channelDriftRows || []);
}

function closeChannelDriftModal() {
  const overlay = document.getElementById('channelDriftModal');
  if (overlay) overlay.classList.remove('open');
}

// 모달 본문 — 층별로 「무엇이 잘못됐나 → 어느 건인가 → 어떻게 조치하나」 순서.
//   조치는 **행마다** 붙인다. 같은 층 안에서도 결과물 종류가 다르면 할 수 있는 일이 다르다.
// 어긋남 1행 카드 — 「어느 캠페인·어느 채널·몇 건」 + 그 행에 맞는 조치 방법.
//   조치는 결과물 종류마다 다르므로 행 단위로 붙인다(channelDriftFixHtml).
function channelDriftRowHtml(layer, r) {
  const camp = r.campaign_no
    ? `${esc(r.campaign_no)} ${esc(r.campaign_title || '')}`
    : '<span style="color:var(--muted)">(캠페인이 특정되지 않음)</span>';
  const kindKo = r.kind ? esc(channelDriftKindKo(r.kind)) : '';
  const goBtn = r.campaign_id
    ? `<button class="btn btn-ghost btn-xs" style="margin-top:8px" onclick="openEditCampaign('${esc(r.campaign_id)}')">캠페인 편집 열기</button>`
    : '';
  return `
    <div style="padding:11px 13px;background:#fff;border:1px solid var(--line);border-radius:8px;margin-top:8px">
      <div style="font-size:13px;font-weight:700;color:var(--ink)">${camp}</div>
      <div style="font-size:12px;color:var(--muted);margin-top:3px">
        저장된 채널 <code>${esc(r.channel_code || '')}</code>${kindKo ? ' · ' + kindKo : ''} · ${Number(r.affected_count || 0)}건
      </div>
      <div style="margin-top:8px;padding:9px 11px;background:var(--bg);border-radius:6px;font-size:12px;line-height:1.7;color:var(--ink)">
        <b>조치 방법</b><br>${channelDriftFixHtml(layer, r.kind)}
      </div>
      ${goBtn}
    </div>`;
}

function channelDriftModalHtml(rows) {
  if (!rows.length) {
    return '<div style="padding:16px;text-align:center;color:var(--muted);font-size:13px">어긋난 채널 코드가 없습니다.</div>';
  }
  const byLayer = {};
  rows.forEach(function(r) {
    const L = r.layer || '?';
    if (!byLayer[L]) byLayer[L] = {count: 0, rows: []};
    byLayer[L].count += Number(r.affected_count || 0);
    byLayer[L].rows.push(r);
  });

  const blocks = Object.keys(CHANNEL_DRIFT_LAYERS)
    .filter(function(L) { return byLayer[L]; })
    .map(function(L) {
      const meta = CHANNEL_DRIFT_LAYERS[L];
      const g = byLayer[L];
      const tone = meta.severe ? {bg: '#FFF5F5', bd: '#C33', ink: '#C33'} : {bg: '#FEF3C7', bd: '#FBBF24', ink: '#92400E'};
      const items = g.rows.map(function(r) { return channelDriftRowHtml(L, r); }).join('');
      return `
        <div style="margin-bottom:18px">
          <div style="padding:10px 13px;background:${tone.bg};border:1px solid ${tone.bd};border-radius:8px;color:${tone.ink}">
            <div style="font-size:13px;font-weight:700">${esc(meta.label)} — 모두 ${g.count}건</div>
            <div style="font-size:12px;margin-top:2px;opacity:.9">${esc(meta.desc)}</div>
          </div>
          ${items}
        </div>`;
    }).join('');

  return blocks + `
    <div style="padding:11px 13px;background:var(--bg);border-radius:8px;font-size:12px;line-height:1.7;color:var(--muted)">
      <b>왜 이런 일이 생기나</b><br>
      시스템은 「캠페인이 요구한 채널」과 「제출된 결과물의 채널」이 <b>같은 글자인지</b>로 판단합니다.
      한쪽만 바뀌면 그 결과물은 인플루언서 화면·인증 성공·정산 <b>세 곳에서 동시에</b> 빠집니다.
      그래서 채널 코드를 바꾸거나 지울 때는 <b>기준 데이터 · 캠페인 · 이미 제출된 결과물</b> 세 곳을 함께 옮겨야 합니다.
    </div>`;
}

// 결과물 종류 코드를 사람이 읽는 말로
function channelDriftKindKo(kind) {
  const MAP = {receipt: '영수증', review_image: '리뷰 인증샷', post: '게시물'};
  return MAP[kind] || kind || '';
}
