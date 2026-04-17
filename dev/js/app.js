// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════

// 비밀번호 재설정 URL 감지 — 스크립트 로드 즉시 (Supabase SDK가 URL 소비하기 전에)
(function detectRecoveryUrlEarly() {
  try {
    const hasCode = new URLSearchParams(location.search).has('code');
    const hasRecoveryHash = location.hash.includes('type=recovery') || location.hash.includes('access_token=');
    if (hasCode || hasRecoveryHash) {
      sessionStorage.setItem('reverb.recovery', '1');
    }
  } catch(e) {}
})();

// 관리자 캠페인 폼의 실시간 미리보기 모드
// URL hash #preview-mode로 진입 → body.preview-mode 클래스 + postMessage 수신 대기
window.__isPreviewMode = location.hash === '#preview-mode';

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
  document.body.style.background = '#E5E5E5';

  document.querySelectorAll('#appShell .page').forEach(p => p.classList.remove('active'));
  const el = $('page-'+pageName);
  if (el) el.classList.add('active');
  // 새 페이지 진입 시 최상단으로 스크롤 (실제 스크롤 컨테이너는 .page.active)
  if (el && el.scrollTo) el.scrollTo(0, 0);
  else window.scrollTo(0, 0);

  const fb = $('detailFloatBar');
  if (fb && pageName !== 'detail') fb.style.display = 'none';

  // 햄버거 메뉴 활성 표시
  if (typeof updateActiveNav === 'function') updateActiveNav(pageName);
  // 인증 페이지에선 햄버거 숨김
  const gnbBurger = $('gnbBurger');
  if (gnbBurger) gnbBurger.style.display = ['login','signup','forgot','reset-pw'].includes(pageName) ? 'none' : '';
  // 비로그인 플로팅 CTA (인증 페이지 제외)
  if (typeof updateFloatingAuthCta === 'function') updateFloatingAuthCta(pageName);

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

// 언어 전환 시 현재 페이지 재렌더 (lookup_values 기반 라벨 갱신)
window.addEventListener('langchange', function() {
  const page = location.hash.replace('#','') || 'home';
  if (page === 'home') { if (typeof loadCampaigns === 'function') loadCampaigns(); }
  else if (page === 'campaigns') { if (typeof loadCampaignsPage === 'function') loadCampaignsPage(); }
  else if (page.startsWith('detail-')) { if (typeof openCampaign === 'function') openCampaign(page.replace('detail-','')); }
  // 햄버거 메뉴 재렌더 (언어에 따라 라벨 갱신)
  if (typeof renderNavMenu === 'function') renderNavMenu();
});

// Step 3: 햄버거 메뉴 활성 페이지 하이라이트
function updateActiveNav(page) {
  const map = {home:'home', detail:'home', mypage:'mypage', campaigns:'campaigns', activity:'mypage'};
  const active = map[page] || 'home';
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('on', el.dataset.nav === active);
  });
}

// ══════════════════════════════════════
// INIT
// ══════════════════════════════════════
async function init() {
  // lookup_values + 캠페인을 병렬 발사 (둘 다 익명 SELECT 허용)
  // 이후 getSession·admins 체크와 waterfall 구조에서 벗어나 초기 렌더 시간 단축
  let campaignsPromise = null;
  if (db) {
    try {
      campaignsPromise = fetchCampaigns();  // 병렬 발사, 나중에 await
      await Promise.all([fetchLookups('channel'), fetchLookups('category'), fetchLookups('content_type')]);
      // 라벨이 갱신되었으므로 활성 페이지 재렌더
      if (allCampaigns && allCampaigns.length && document.getElementById('page-home')?.classList.contains('active')) {
        updateStats(allCampaigns);
        renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
      }
    } catch(_) {}
  }
  // 로그인 세션 복원 — 단, 비밀번호 재설정 중인 세션은 로그인 상태로 취급하지 않음
  let inRecoveryInit = false;
  try { inRecoveryInit = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}
  const {data:{session}} = await (db?.auth.getSession() || {data:{session:null}});
  if (session && !inRecoveryInit) {
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
          // 로그인 시 알림 폴링 시작
          if (typeof startNotifPolling === 'function') startNotifPolling();
        }
      }
      if (event === 'SIGNED_OUT' || event === 'SESSION_EXPIRED') {
        try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
        currentUser = null;
        currentUserProfile = null;
        updateGnb();
        // 로그아웃 시 알림 폴링 중지
        if (typeof stopNotifPolling === 'function') stopNotifPolling();
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

  // 캠페인 불러오기 (init 초입에서 병렬 발사해둔 promise 재사용)
  allCampaigns = campaignsPromise ? (await campaignsPromise) : await fetchCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);

  // 이미지 리스트 등록
  registerImgList('campImgData', campImgData);

  // URL 해시가 있으면 해당 페이지로 이동
  const hash = location.hash.replace('#','');

  // recovery 진행 중이면 초기 라우팅 스킵 (Supabase SDK가 PASSWORD_RECOVERY 이벤트로 reset-pw 이동시킴)
  let isRecoveryInProgress = false;
  try { isRecoveryInProgress = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}
  const urlHasRecoveryCode = new URLSearchParams(location.search).has('code') ||
                             location.hash.includes('type=recovery') ||
                             location.hash.includes('access_token=');

  if (isRecoveryInProgress || urlHasRecoveryCode) {
    // 초기 라우팅 건너뜀. PASSWORD_RECOVERY 핸들러가 reset-pw로 이동시킴.
  } else if (hash && hash.startsWith('detail-')) {
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
  // 미리보기 모드: 관리자 캠페인 폼 iframe 안에서 동작 (same-origin)
  // init() 호출을 스킵하여 db/currentUser를 미초기화 상태로 유지 → DB 부작용 자동 차단
  if (window.__isPreviewMode) {
    document.body.classList.add('preview-mode');
    allCampaigns = [];
    // 부모 창이 iframe.contentWindow.__reverbPreviewApply(camp)를 직접 호출
    window.__reverbPreviewApply = function(camp) {
      if (!camp || !camp.id) return;
      allCampaigns = allCampaigns.filter(c => c.id !== '__preview__');
      allCampaigns.push(camp);
      document.querySelectorAll('.page').forEach(function(p){p.classList.remove('active');});
      const pd = document.getElementById('page-detail');
      if (pd) pd.classList.add('active');
      if (typeof openCampaign !== 'function') { console.warn('[preview] openCampaign 미정의'); return; }
      try { openCampaign('__preview__'); }
      catch(e) { console.warn('[preview] openCampaign 실패:', e); }
    };
    window.__reverbPreviewReady = true;
    console.log('[preview] iframe ready');
    return;
  }

  // recovery 진행 중이면 home 대신 reset-pw 페이지 활성화
  let inRecovery = false;
  try { inRecovery = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}

  const initHash = location.hash.replace('#','') || 'home';
  const initPage = inRecovery ? 'reset-pw'
    : (initHash.startsWith('detail-') ? 'detail' : initHash.startsWith('mypage-') ? 'mypage' : initHash);
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
