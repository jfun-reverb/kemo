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

// ── 아웃바운드 전용 모드 (?app=outbound) ──────────────────────────────
// 같은 관리자 앱·같은 로그인이지만 별도 입구 URL(globalreverb.com/admin/?app=outbound).
// 이 모드에선 사이드바를 아웃바운드 관련 항목만 남기고 나머지·그룹 라벨을 숨겨,
// 영업팀이 REVERB 운영 메뉴와 덜 섞인 화면으로 진입한다. 기존 관리자가 두 모드를 오감
// (복귀 링크로 전환). 보안 경계 아님 — 데이터는 outbound.view RLS 가 서버 강제.
window._adminAppMode = (new URLSearchParams(location.search).get('app') === 'outbound') ? 'outbound' : null;

// 모드 UI 적용: 아웃바운드·내계정 외 사이드바 항목 + 그룹 라벨 숨김 + 복귀 링크 노출.
// 권한 없는(menu.outbound hidden = campaign_manager) 사용자는 모드 해제(빈 화면 함정 방지).
function applyOutboundModeUI() {
  if (window._adminAppMode !== 'outbound') return;
  if (typeof isHidden === 'function' && isHidden('menu.outbound')) {
    // 권한 없음(campaign_manager) — 모드 해제 + 이미 적용됐을 필터·페인 복원.
    // (DOMContentLoaded 가 권한 로드 전 fail-open 으로 모드를 켜놨을 수 있음)
    // ⚠️ 개별 .admin-si[data-pane] 항목은 여기서 복원하지 않는다 — 이 함수는 반드시 init()에서
    //   applyLookupMenuVisibility() 뒤에 호출돼(app.js init 순서), 개별 항목은 이미 권한 기준으로
    //   설정된 상태다. 여기서 다 보이게 하면 오히려 hidden 항목(정산 등)이 노출된다. 두 호출 순서 유지 필수.
    window._adminAppMode = null;
    document.querySelectorAll('.admin-si-lbl').forEach(function(l){ l.style.display = ''; });
    // outbound 페인이 이미 활성화됐으면 대시보드로 명시 이동(빈 화면 함정 방지).
    // switchAdminPane 이 있으면(init 단계) 여기서 처리하고 부트 페인 진입을 스킵시킴.
    if (typeof switchAdminPane === 'function') {
      switchAdminPane('dashboard', null, false);
      window._bootPaneHandled = true;
    }
    return;
  }
  document.querySelectorAll('.admin-si-lbl').forEach(function(l){ l.style.display = 'none'; });
  document.querySelectorAll('.admin-si[data-pane]').forEach(function(si){
    var p = si.dataset.pane;
    if (p !== 'outbound' && p !== 'my-account') si.style.display = 'none';
  });
}

// 화면 이동 드롭다운 — 전체 관리자 / 아웃바운드 전용(?app=outbound) / 인플루언서 화면 전환.
function switchAdminScreen(target) {
  if (target === 'outbound') window.location.href = location.pathname + '?app=outbound';
  else if (target === 'influencer') window.location.href = '/';
  else window.location.href = location.pathname;   // full: 쿼리 제거하고 전체 관리자
}

// 드롭다운 현재값을 실제 화면 상태에 맞춤 (아웃바운드 전용 모드면 그 항목 선택).
function setAdminScreenSelect() {
  var sel = document.getElementById('adminScreenSelect');
  if (sel) sel.value = (window._adminAppMode === 'outbound') ? 'outbound' : 'full';
}

// 사이드바 메뉴 클릭 — SPA 페인 전환 (전체 페이지 reload 제거).
// switchAdminPane이 페인별 loader를 호출해 fresh load 보장하므로 stale 이슈 없음.
// 같은 페인 재클릭 시엔 loader만 다시 호출해 강제 갱신.
function navAdminPaneReload(pane) {
  pane = pane || 'dashboard';
  const go = () => {
    if (typeof switchAdminPane === 'function') {
      switchAdminPane(pane, null, true);
    } else {
      location.hash = '#' + pane;
    }
  };
  // 캠페인 폼에 저장 안 한 변경이 있으면 먼저 묻는다.
  //   ⚠️ 게이트를 switchAdminPane 에 두지 않는 이유 — 그 함수는 **저장 성공 후 목록
  //      복귀**·동시 저장 충돌 복귀·권한 리다이렉트·브라우저 뒤로가기가 전부 지나간다.
  //      거기 두면 「저장했는데 저장 안 됐다고 묻는」 모습이 된다. 사이드바는 이 함수
  //      하나로 모이므로 여기가 정확한 자리다.
  if (typeof campLeaveGuard === 'function') { campLeaveGuard(go); return; }
  go();
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
      // 관리자 전용 로그인 화면으로. 예전에는 인플루언서 앱(/#login)으로 보냈는데,
      // 그 화면은 일본어·모바일 전용이라 관리자가 일본어 화면에서 로그인하게 됐다.
      // (세션은 있으나 admins 행이 없는 경우는 아래 분기 그대로 — 여기로 보내면 무한 왕복)
      window.location.href = '/admin-setpw.html?mode=login';
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
    // 동적 권한 로드 (실패해도 fail-open — boot 계속). 메뉴 숨김이 이 맵을 참조.
    if (typeof fetchRolePermissions === 'function' && typeof setRolePermMap === 'function') {
      try { setRolePermMap(await fetchRolePermissions()); } catch (_) { /* fail-open */ }
    }
    if (typeof applyLookupMenuVisibility === 'function') applyLookupMenuVisibility();
    applyOutboundModeUI();   // 아웃바운드 전용 모드면 권한 기준 노출 위에 사이드바 필터 덮어씀
    setAdminScreenSelect();  // 화면 이동 드롭다운 현재값 반영(모드 확정 후)
    if (typeof updateSidebarProfile === 'function') updateSidebarProfile();

    // 세션 만료/갱신 감지
    db.auth.onAuthStateChange(function(event) {
      if (event === 'SIGNED_OUT' || event === 'SESSION_EXPIRED') {
        currentUser = null; currentUserProfile = null;
        // 부팅 시 무세션 진입과 같은 목적지 — 세션이 끊겨 다시 로그인해야 하는 상황이라
        // 관리자 전용 한국어 로그인 화면으로 보낸다(예전엔 인플루언서 앱 일본어 화면).
        window.location.href = '/admin-setpw.html?mode=login';
      }
    });

    // 이미지 리스트 등록
    registerImgList('campImgData', campImgData);

    // 관리자 큰 모달 드래그·리사이즈 옵저버 부착 (정적 overlay 전부, 1회)
    if (typeof initDraggableModals === 'function') initDraggableModals();

    // 사이드바 배지 4종 — 화면 진입을 막지 않도록 백그라운드로 갱신 (전부 가벼운 count 쿼리)
    if (typeof refreshApplySidebarBadge === 'function') refreshApplySidebarBadge();
    if (typeof refreshDelivSidebarBadge === 'function') refreshDelivSidebarBadge();
    if (typeof refreshSettlementSidebarBadge === 'function') refreshSettlementSidebarBadge();
    if (typeof refreshBrandAppBadge === 'function') refreshBrandAppBadge();
    if (typeof refreshOrientBadge === 'function') refreshOrientBadge();
    // 사용자 앱 오류 — **부팅 시 1회.** 예전에는 오류 로그 화면을 열 때(목록을 그릴 때)만
    //   갱신해서, **그 화면에 들어가야 비로소 숫자가 떴다.** 오류는 들어가 볼 이유가 없을 때
    //   쌓이는 것이라, 「들어가야만 알 수 있는 알림」은 알림이 아니다(2026-08-10 사용자 지적).
    //   0건이면 아무것도 안 그린다. 「예상 못 한 오류」만 센다(정상 거부는 제외).
    if (typeof updateClientErrorBadge === 'function') updateClientErrorBadge();
    // 채널 코드 어긋남 — **부팅 시 1회.** 해당 화면에 들어가야만 알 수 있으면 늦다
    //   (이번 사고가 「두 달간 아무도 몰랐다」였다). 0건이면 아무 표시도 안 뜬다.
    if (typeof refreshChannelDriftIndicators === 'function') refreshChannelDriftIndicators();
    // 「올려두고 미제출」 — 부팅 시 1회. 같은 이유다. 이 건은 **본인 화면에만 남아 있어**
    //   운영팀 쪽에서는 아무 신호도 없었고, 그래서 운영 26건이 4개월간 쌓였다.
    //   0건이면 아무 표시도 안 뜬다. 조회 실패도 마찬가지(0인 척하지 않는다).
    if (typeof refreshStalledDraftIndicators === 'function') refreshStalledDraftIndicators();
    // 막힌 표 감지 — 부팅 시 1회. **그 화면에 들어가야만 알 수 있으면 늦다**
    //   (2026-08-07 사고가 11일간 안 보였던 이유가 그것이다).
    if (typeof refreshBlockedTableIndicators === 'function') refreshBlockedTableIndicators();
    // 탈퇴 처리 점검 — 부팅 시 1회. 위와 같은 이유다.
    //   ⚠️ 이 경고는 **「항상 0 이 정상」이 아니다** — 관리자 계정을 겸한 회원이
    //   있으면 숫자가 0 으로 안 내려간다(모달이 조치 방법을 안내한다).
    if (typeof refreshWithdrawalOpsIndicators === 'function') refreshWithdrawalOpsIndicators();
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
    // 아웃바운드 전용 모드는 진입 화면이 없으면(또는 dashboard면) 아웃바운드로 직행
    if (window._adminAppMode === 'outbound' && (!hash || hash === 'dashboard')) hash = 'outbound';
    if (window._bootPaneHandled) {
      // applyOutboundModeUI 가 권한 없는 모드 진입을 대시보드로 이미 전환·로드함 → 중복 스킵
    } else if (hash && hash !== 'dashboard') {
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
  var initHash = location.hash.replace('#','') || (window._adminAppMode === 'outbound' ? 'outbound' : 'dashboard');
  // 예약 현황도 「어느 캠페인인지」를 화면 상태로만 들고 있어(주소에 없다),
  // 새로고침하면 캠페인을 잃고 빈 표만 남는다 → 캠페인 목록으로 돌려보낸다.
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
  // 아웃바운드 전용 모드면 cloak 제거 전 사이드바 필터 적용 (초기 깜빡임 방지).
  // 권한 기준 최종 판정(campaign_manager 해제)은 init()의 applyLookupMenuVisibility 뒤 재호출.
  applyOutboundModeUI();
  setAdminScreenSelect();
  // 패널 설정 완료 후 body 표시
  var cloak = document.getElementById('admin-cloak');
  if (cloak) cloak.remove();
  // 로딩 화면도 함께 걷는다(가림막과 짝 — 하나만 지우면 화면이 가려진 채 남는다).
  var boot = document.getElementById('admin-boot');
  if (boot) boot.remove();

  allCampaigns = typeof DEMO_CAMPAIGNS !== 'undefined' ? DEMO_CAMPAIGNS.slice() : [];
  init();
});
