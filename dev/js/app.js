// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════

function navigate(page, pushHistory) {
  const appShell = $('appShell');
  const adminPage = $('page-admin');

  // 브라우저 히스토리에 기록 (뒤로가기 지원)
  if (pushHistory !== false) {
    history.pushState({page}, '', '#' + page);
  }

  if (page === 'admin') {
    if (appShell) appShell.style.display = 'none';
    if (adminPage) { adminPage.classList.add('active'); adminPage.style.display = 'block'; }
    document.body.style.background = '#F8F5F8';
    loadAdminData();
    return;
  }

  if (appShell) appShell.style.display = '';
  if (adminPage) { adminPage.classList.remove('active'); adminPage.style.display = 'none'; }
  document.body.style.background = '#E8E0EC';

  document.querySelectorAll('#appShell .page').forEach(p => p.classList.remove('active'));
  const el = $('page-'+page);
  if (el) el.classList.add('active');
  var _sh = $('appShell'); if(_sh) _sh.scrollTo(0,0); else window.scrollTo(0,0);

  const fb = $('detailFloatBar');
  if (fb && page !== 'detail') fb.style.display = 'none';

  const tabBar = $('bottomTabBar');
  if (tabBar) {
    tabBar.style.display = ['login','signup'].includes(page) ? 'none' : 'flex';
  }
  updateTabBar(page);

  if (page === 'home') loadCampaigns();
  if (page === 'campaigns') loadCampaignsPage();
  if (page === 'mypage') {
    if (!currentUser) { navigate('login'); return; }
    loadMyPage();
  }
}

// 브라우저 뒤로가기/앞으로가기 버튼 처리
window.addEventListener('popstate', function(e) {
  const page = e.state?.page || location.hash.replace('#','') || 'home';
  navigate(page, false);
});

function navigateTab(page, el) {
  if (page === 'mypage' && !currentUser) { navigate('login'); return; }
  navigate(page);
}

function updateTabBar(page) {
  const map = {home:'tab-home',detail:'tab-home',mypage:'tab-mypage',campaigns:'tab-camp'};
  document.querySelectorAll('.tab-item').forEach(t=>t.classList.remove('on'));
  const activeEl = $(map[page]||'tab-home');
  if (activeEl) activeEl.classList.add('on');
}

// ══════════════════════════════════════
// INIT
// ══════════════════════════════════════
async function init() {
  // 로그인 세션 복원
  const {data:{session}} = await (db?.auth.getSession() || {data:{session:null}});
  if (session) {
    currentUser = session.user;
    // 관리자 테이블에서 확인
    const {data:adminData} = await db?.from('admins').select('*').eq('auth_id', currentUser.id).maybeSingle();
    if (adminData) {
      currentUser._isAdmin = true;
      currentUserProfile = {name: adminData.name || 'Admin', email: currentUser.email};
    } else {
      const {data:profile} = await db?.from('influencers').select('*').eq('id', currentUser.id).maybeSingle();
      currentUserProfile = profile;
    }
  }
  updateGnb();

  // 캠페인 불러오기
  allCampaigns = await fetchCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);

  // 이미지 드래그앤드롭 영역 초기화
  initImgDropZone('campImgDropZone', 'campImgFileInput');
  initImgDropZone('editCampImgDropZone', 'editCampImgFileInput');

  // URL 해시가 있으면 해당 페이지로 이동
  const hash = location.hash.replace('#','');
  if (hash && hash !== 'home') {
    navigate(hash, false);
  } else {
    history.replaceState({page:'home'}, '', '#home');
  }
}

document.addEventListener('DOMContentLoaded', function() {
  allCampaigns = DEMO_CAMPAIGNS.slice();
  renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
  updateStats(allCampaigns);
  init();
  var _sh=$('appShell');if(_sh)_sh.scrollTop=0;else window.scrollTo(0,0);
});
