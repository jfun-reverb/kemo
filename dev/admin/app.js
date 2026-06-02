// ══════════════════════════════════════
// ADMIN APP — 관리자 페이지 초기화
// ══════════════════════════════════════

// 사이드바 접기/펼치기
function toggleAdminSidebar() {
  const layout = document.querySelector('.admin-layout');
  layout.classList.toggle('collapsed');
  const icon = $('sidebarToggleBtn').querySelector('.material-icons-round');
  icon.textContent = layout.classList.contains('collapsed') ? 'menu_open' : 'menu';
}

// 사이드바 메뉴 클릭 — SPA 페인 전환 (전체 페이지 reload 제거).
// switchAdminPane이 페인별 loader를 호출해 fresh load 보장하므로 stale 이슈 없음.
// 같은 페인 재클릭 시엔 loader만 다시 호출해 강제 갱신.
function navAdminPaneReload(pane) {
  pane = pane || 'dashboard';
  if (typeof switchAdminPane === 'function') {
    switchAdminPane(pane, null, true);
  } else {
    location.hash = '#' + pane;
  }
}

// 관리자 페이지 네비게이션 (사이드바 패널 전환)
function navigate(page) {
  // admin 페이지 내에서는 사이드바 패널만 전환
  if (page === 'home' || page === 'detail') {
    window.location.href = '/';
    return;
  }
}

async function adminLogout() {
  if (db) { try { await db.auth.signOut(); } catch(e) {} }
  currentUser = null; currentUserProfile = null;
  window.location.href = '/';
}

async function init() {
  try {
    // 세션 확인
    var sessionResult = await (db?.auth.getSession() || {data:{session:null}});
    var session = sessionResult?.data?.session;

    if (!session) {
      window.location.href = '/#login';
      return;
    }

    currentUser = session.user;

    // 관리자 확인
    var adminResult = await db.from('admins').select('*').eq('auth_id', currentUser.id).maybeSingle();
    if (!adminResult.data) {
      toast('관리자 권한이 없습니다','error');
      setTimeout(function() { window.location.href = '/'; }, 1500);
      return;
    }

    currentUser._isAdmin = true;
    currentUserProfile = {name: adminResult.data.name || 'Admin', email: currentUser.email};
    currentAdminInfo = adminResult.data;
    if (typeof applyLookupMenuVisibility === 'function') applyLookupMenuVisibility();
    if (typeof updateSidebarProfile === 'function') updateSidebarProfile();

    // 세션 만료/갱신 감지
    db.auth.onAuthStateChange(function(event) {
      if (event === 'SIGNED_OUT' || event === 'SESSION_EXPIRED') {
        currentUser = null; currentUserProfile = null;
        window.location.href = '/#login';
      }
    });

    // 이미지 리스트 등록
    registerImgList('campImgData', campImgData);

    // 관리자 큰 모달 드래그·리사이즈 옵저버 부착 (정적 overlay 전부, 1회)
    if (typeof initDraggableModals === 'function') initDraggableModals();

    // 사이드바 배지 4종 — 화면 진입을 막지 않도록 백그라운드로 갱신 (전부 가벼운 count 쿼리)
    if (typeof refreshApplySidebarBadge === 'function') refreshApplySidebarBadge();
    if (typeof refreshDelivSidebarBadge === 'function') refreshDelivSidebarBadge();
    if (typeof refreshBrandAppBadge === 'function') refreshBrandAppBadge();
    // 메시지 배지는 refreshInboxData 끝의 updateInboxSidebarBadge 가 갱신 — 부트에서도 호출해
    // 새로고침 시 즉시 노출 (기존엔 페인 클릭 시에만 갱신되어 0으로 보이던 회귀).
    if (typeof refreshInboxData === 'function') refreshInboxData();

    // 채널·카테고리·콘텐츠 종류 lookup 캐시 선로딩 (페인 분기보다 먼저, 모든 화면 공통).
    // getChannelLabel 등은 동기 함수라 캐시가 없으면 @cosme(code: channel-xxxx)·LIPS 처럼
    // CHANNEL_LABEL_FALLBACK 에 없는 채널이 코드 원문으로 노출됨. 진입 전에 1회 보장.
    try { await Promise.all([fetchLookups('channel'), fetchLookups('category'), fetchLookups('content_type')]); } catch(e) { /* 폴백 OK — 화면 깨짐 없음 */ }

    // PR 3 부트 경량화 — 진입 화면(hash)에 필요한 데이터만 로드
    //  - dashboard: KPI·차트용 무거운 3종(캠페인/인플/신청 전건)을 여기서만 로드
    //  - 그 외 페인: 각 페인 loader 가 자기 데이터를 스스로 fetch → 무거운 3종 스킵
    //    (allCampaigns 는 shared.js 에서 []로 초기화. 캠페인 페인은 loadAdminCampaigns 가 lite 로 채움)
    var hash = location.hash.replace('#','');
    if (hash && hash !== 'dashboard') {
      await Promise.resolve(switchAdminPane(hash, null, false));
    } else {
      history.replaceState({pane:'dashboard'}, '', '#dashboard');
      var preloaded = await Promise.all([fetchCampaigns(), fetchInfluencers(), fetchApplications()]);
      allCampaigns = preloaded[0].slice();
      await loadAdminData(preloaded);
    }
  } catch(e) {
    toast('초기화 오류: ' + (e.message||'알 수 없는 오류'), 'error');
  }
}

document.addEventListener('DOMContentLoaded', function() {
  // STAGING 환경 배지 표시
  try {
    if (typeof IS_STAGING !== 'undefined' && IS_STAGING) {
      var badge = document.getElementById('stagingBadge');
      if (badge) badge.style.display = 'inline-block';
      var badgeSide = document.getElementById('stagingBadgeSide');
      if (badgeSide) badgeSide.style.display = 'inline-block';
    }
  } catch(e) {}

  // 새로고침 시 브라우저 폼 자동 복원으로 검색/날짜 필터에 이전 값이 남는 문제 방지
  try {
    document.querySelectorAll('.admin-filter-search, .admin-filter[type="date"], #brandAppDateRange').forEach(function(el){ el.value = ''; });
  } catch(e) {}

  // 브랜드 서베이 신청 기간 flatpickr range picker mount
  try { if (typeof setupBrandAppDateRange === 'function') setupBrandAppDateRange(); } catch(e) {}

  // 데이터 컨텍스트가 필요한 하위 패널은 부모 패널로 리다이렉트
  var initHash = location.hash.replace('#','') || 'dashboard';
  var subToParent = {'edit-campaign':'campaigns','camp-applicants':'campaigns','influencer-detail':'influencers','brand-ops-detail':'brand-ops'};
  if (subToParent[initHash]) {
    initHash = subToParent[initHash];
    history.replaceState({pane: initHash}, '', '#' + initHash);
  }
  var sidePane = {'add-campaign':'campaigns'}[initHash] || initHash;
  document.querySelectorAll('.admin-pane').forEach(function(p) { p.classList.remove('on'); });
  document.querySelectorAll('.admin-si').forEach(function(s) { s.classList.remove('on'); });
  var initPane = document.getElementById('adminPane-' + initHash) || document.getElementById('adminPane-dashboard');
  if (initPane) initPane.classList.add('on');
  document.querySelectorAll('.admin-si').forEach(function(s) {
    if (s.dataset.pane === sidePane) s.classList.add('on');
  });
  // 패널 설정 완료 후 body 표시
  var cloak = document.getElementById('admin-cloak');
  if (cloak) cloak.remove();

  allCampaigns = typeof DEMO_CAMPAIGNS !== 'undefined' ? DEMO_CAMPAIGNS.slice() : [];
  init();
});
