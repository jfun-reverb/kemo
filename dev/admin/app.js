// ══════════════════════════════════════
// ADMIN APP — 관리자 페이지 초기화
// ══════════════════════════════════════

// 관리자 페이지 네비게이션 (사이드바 패널 전환)
function navigate(page) {
  // admin 페이지 내에서는 사이드바 패널만 전환
  if (page === 'home' || page === 'detail') {
    window.open('/', '_blank');
    return;
  }
}

async function adminLogout() {
  if (db) { try { await db.auth.signOut(); } catch(e) {} }
  currentUser = null; currentUserProfile = null;
  window.location.href = '/';
}

async function init() {
  // 세션 확인
  var sessionResult = await (db?.auth.getSession() || {data:{session:null}});
  var session = sessionResult.data.session;

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

  // 이미지 리스트 등록
  registerImgList('campImgData', campImgData);

  // 캠페인 + 대시보드 로드
  allCampaigns = await fetchCampaigns();
  loadAdminData();

  // URL 해시가 있으면 해당 패널로 이동
  var hash = location.hash.replace('#','');
  if (hash && hash !== 'dashboard') {
    switchAdminPane(hash, null, false);
  } else {
    history.replaceState({pane:'dashboard'}, '', '#dashboard');
  }
}

document.addEventListener('DOMContentLoaded', function() {
  // 해시에 맞는 패널을 즉시 활성화 (깜빡임 방지)
  var initHash = location.hash.replace('#','') || 'dashboard';
  if (initHash !== 'dashboard') {
    document.querySelectorAll('.admin-pane').forEach(function(p) { p.classList.remove('on'); });
    var initPane = document.getElementById('adminPane-' + initHash);
    if (initPane) initPane.classList.add('on');
  }

  allCampaigns = typeof DEMO_CAMPAIGNS !== 'undefined' ? DEMO_CAMPAIGNS.slice() : [];
  init();
});
