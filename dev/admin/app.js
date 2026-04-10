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

    // GNB에 관리자 이름 표시
    var gnbInfo = document.getElementById('adminGnbInfo');
    if (gnbInfo) {
      var initial = (adminResult.data.name || 'A')[0].toUpperCase();
      gnbInfo.innerHTML = '<div style="width:28px;height:28px;border-radius:50%;background:var(--pink);display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;color:#fff">' + initial + '</div><span>' + (adminResult.data.name || '관리자') + '</span>';
    }

    // 세션 만료/갱신 감지
    db.auth.onAuthStateChange(function(event) {
      if (event === 'SIGNED_OUT' || event === 'SESSION_EXPIRED') {
        currentUser = null; currentUserProfile = null;
        window.location.href = '/#login';
      }
    });

    // 이미지 리스트 등록
    registerImgList('campImgData', campImgData);

    allCampaigns = await fetchCampaigns();

    // 신청 뱃지는 항상 업데이트
    var _apps = await fetchApplications();
    var _pending = _apps.filter(function(a){return a.status==='pending'});
    if ($('adminApplySi')) $('adminApplySi').innerHTML = '<span class="si-icon material-icons-round">assignment</span><span class="si-text">신청 관리</span>' + (_pending.length>0?'<span class="admin-si-badge">'+(_pending.length>99?'99+':_pending.length)+'</span>':'');

    // URL 해시가 있으면 해당 패널로 이동
    var hash = location.hash.replace('#','');
    if (hash && hash !== 'dashboard') {
      await Promise.resolve(switchAdminPane(hash, null, false));
    } else {
      history.replaceState({pane:'dashboard'}, '', '#dashboard');
      await loadAdminData();
    }
  } catch(e) {
    toast('초기화 오류: ' + (e.message||'알 수 없는 오류'), 'error');
  }
}

document.addEventListener('DOMContentLoaded', function() {
  // 데이터 컨텍스트가 필요한 하위 패널은 부모 패널로 리다이렉트
  var initHash = location.hash.replace('#','') || 'dashboard';
  var subToParent = {'edit-campaign':'campaigns','camp-applicants':'campaigns','influencer-detail':'influencers'};
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
