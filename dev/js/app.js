// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════
let _detailFrom = null;

function navigateBackFromDetail() {
  if (_detailFrom === 'mypage') {
    _detailFrom = null;
    navigate('mypage');
    openMypageSub('applications');
  } else {
    _detailFrom = null;
    navigate('home');
  }
}

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
  if (page === 'mypage' && e.state?.sub) {
    navigate('mypage', false);
    openMypageSub(e.state.sub);
  } else if (page === 'mypage' && !e.state?.sub) {
    navigate('mypage', false);
    closeMypageSub();
  } else if (page.startsWith('detail-')) {
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
  // lookup_values 사전 로드 (채널/카테고리 라벨 동적 표시용, 인증과 무관하게 익명 SELECT 허용)
  if (db) {
    try {
      await Promise.all([fetchLookups('channel'), fetchLookups('category')]);
      // 라벨이 갱신되었으므로 활성 페이지 재렌더
      if (allCampaigns && allCampaigns.length && document.getElementById('page-home')?.classList.contains('active')) {
        updateStats(allCampaigns);
        renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
      }
    } catch(_) {}
  }
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

  // 비밀번호 복구 URL 감지 (이벤트보다 먼저 판단)
  // - implicit flow: #access_token=...&type=recovery
  // - PKCE flow: ?code=... (with recovery intent)
  const hashStr = location.hash.replace('#','');
  const hashParams = new URLSearchParams(hashStr.includes('&') ? hashStr : '');
  const queryParams = new URLSearchParams(location.search);
  const urlType = hashParams.get('type') || queryParams.get('type');
  const hasRecoveryHash = hashStr.includes('type=recovery');
  const hasAccessToken = hashParams.get('access_token') && !urlType;
  const isRecoveryUrl = urlType === 'recovery' || hasRecoveryHash;

  // recovery URL로 들어온 경우 플래그 저장 (다른 탭 동기화 대응)
  if (isRecoveryUrl) {
    try { sessionStorage.setItem('reverb.recovery', '1'); } catch(e) {}
  }

  // 비밀번호 복구 이벤트 감지
  if (db) {
    db.auth.onAuthStateChange(async (event, session) => {
      if (event === 'PASSWORD_RECOVERY') {
        try { sessionStorage.setItem('reverb.recovery', '1'); } catch(e) {}
        navigate('reset-pw');
        return;
      }
      if ((event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') && session?.user) {
        // recovery 모드에서는 SIGNED_IN을 받아도 reset-pw로 유도
        let isRecovery = false;
        try { isRecovery = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}
        if (isRecovery) {
          navigate('reset-pw');
          return;
        }
        if (!currentUser) {
          currentUser = session.user;
          const {data:adminData} = await db.from('admins').select('*').eq('auth_id', currentUser.id).maybeSingle();
          if (adminData) {
            currentUser._isAdmin = true;
            currentUserProfile = {name: adminData.name || 'Admin', email: currentUser.email};
          } else {
            const {data:profile} = await db.from('influencers').select('*').eq('id', currentUser.id).maybeSingle();
            currentUserProfile = profile;
          }
          updateGnb();
        }
      }
      if (event === 'SIGNED_OUT' || event === 'SESSION_EXPIRED') {
        try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
        currentUser = null;
        currentUserProfile = null;
        updateGnb();
      }
    });
    // 초기 URL이 명시적 recovery인 경우에만 즉시 이동 (access_token만 있을 때는 이벤트 기다림)
    if (isRecoveryUrl) {
      navigate('reset-pw');
    }
    // 링크 만료/에러 감지
    const urlError = hashParams.get('error') || new URLSearchParams(location.search).get('error');
    if (urlError) {
      const errDesc = hashParams.get('error_description') || new URLSearchParams(location.search).get('error_description') || '';
      const isExpired = errDesc.includes('expired') || errDesc.includes('invalid');
      if (isExpired) {
        navigate('forgot');
        setTimeout(() => toast('リンクの有効期限が切れました。もう一度お試しください。','error'), 300);
      } else {
        navigate('home');
      }
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
  } else if (hash && hash.startsWith('mypage-')) {
    const sub = hash.replace('mypage-','');
    navigate('mypage', false);
    openMypageSub(sub);
  } else if (hash && hash !== 'home') {
    navigate(hash, false);
  } else {
    history.replaceState({page:'home'}, '', '#home');
  }

  // 초기화 완료 — cloak 해제
  const cloak = document.getElementById('app-cloak');
  if (cloak) cloak.remove();
}

document.addEventListener('DOMContentLoaded', async function() {
  // 해시에 맞는 페이지를 즉시 활성화 (깜빡임 방지)
  const initHash = location.hash.replace('#','') || 'home';
  const initPage = initHash.startsWith('detail-') ? 'detail' : initHash.startsWith('mypage-') ? 'mypage' : initHash;
  const initEl = $('page-' + initPage);
  if (initEl) initEl.classList.add('active');
  else $('page-home')?.classList.add('active');

  allCampaigns = DEMO_CAMPAIGNS.slice();
  if (initPage === 'home') {
    renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
    updateStats(allCampaigns);
  }
  await init();

  // 모바일 키보드 대응: visualViewport로 appShell 높이 동적 조절
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
