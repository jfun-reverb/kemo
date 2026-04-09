// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════

function navigate(page, pushHistory) {
  const appShell = $('appShell');

  // detail-{id} 형식 처리
  let pageName = page;
  if (page.startsWith('detail-')) {
    pageName = 'detail';
  }

  // 브라우저 히스토리에 기록 (뒤로가기 지원)
  if (pushHistory !== false) {
    history.pushState({page}, '', '#' + page);
  }

  if (page === 'admin') {
    window.open('/admin/', '_blank');
    return;
  }

  if (appShell) appShell.style.display = '';
  document.body.style.background = '#E8E0EC';

  document.querySelectorAll('#appShell .page').forEach(p => p.classList.remove('active'));
  const el = $('page-'+pageName);
  if (el) el.classList.add('active');
  var _sh = $('appShell'); if(_sh) _sh.scrollTo(0,0); else window.scrollTo(0,0);

  const fb = $('detailFloatBar');
  if (fb && pageName !== 'detail') fb.style.display = 'none';

  const tabBar = $('bottomTabBar');
  if (tabBar) {
    tabBar.style.display = ['login','signup','forgot','reset-pw'].includes(pageName) ? 'none' : 'flex';
  }
  updateTabBar(pageName);

  if (pageName === 'home') loadCampaigns();
  if (pageName === 'campaigns') loadCampaignsPage();
  if (pageName === 'mypage') {
    if (!currentUser) { navigate('login'); return; }
    closeMypageSub();
    loadMyPage();
  }
}

// 브라우저 뒤로가기/앞으로가기 버튼 처리
window.addEventListener('popstate', function(e) {
  const page = e.state?.page || location.hash.replace('#','') || 'home';
  if (page.startsWith('detail-')) {
    openCampaign(page.replace('detail-',''));
  } else {
    navigate(page, false);
  }
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

  // パスワードリカバリーイベント検知
  if (db) {
    db.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') {
        navigate('reset-pw');
      }
    });
    // URL にリカバリートークンが含まれている場合の検知
    const hashParams = new URLSearchParams(location.hash.replace('#','').split('?').pop());
    const urlType = hashParams.get('type') || new URLSearchParams(location.search).get('type');
    if (urlType === 'recovery' || location.hash.includes('type=recovery')) {
      navigate('reset-pw');
    }
  }

  // 캠페인 불러오기
  allCampaigns = await fetchCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);

  // 이미지 리스트 등록
  registerImgList('campImgData', campImgData);

  // URL 해시가 있으면 해당 페이지로 이동
  const hash = location.hash.replace('#','');
  if (hash && hash.startsWith('detail-')) {
    const campId = hash.replace('detail-','');
    openCampaign(campId);
  } else if (hash && hash !== 'home') {
    navigate(hash, false);
  } else {
    history.replaceState({page:'home'}, '', '#home');
  }
}

document.addEventListener('DOMContentLoaded', function() {
  // 해시에 맞는 페이지를 즉시 활성화 (깜빡임 방지)
  const initHash = location.hash.replace('#','') || 'home';
  const initPage = initHash.startsWith('detail-') ? 'detail' : initHash;
  const initEl = $('page-' + initPage);
  if (initEl) initEl.classList.add('active');
  else $('page-home')?.classList.add('active');

  allCampaigns = DEMO_CAMPAIGNS.slice();
  if (initPage === 'home') {
    renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
    updateStats(allCampaigns);
  }
  init();

  // モバイルキーボード対応: visualViewportでappShell高さを動的調整
  if (window.visualViewport) {
    var appShell = $('appShell');
    function adjustHeight() {
      var vh = window.visualViewport.height;
      var offsetTop = window.visualViewport.offsetTop;
      appShell.style.height = vh + 'px';
      appShell.style.top = offsetTop + 'px';
    }
    window.visualViewport.addEventListener('resize', adjustHeight);
    window.visualViewport.addEventListener('scroll', adjustHeight);
  }
});
