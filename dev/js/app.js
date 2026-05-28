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
  // messages-{id} — 응모건 메시지 페이지 (모달→페이지 전환, 2026-05-22)
  if (page.startsWith('messages-')) {
    pageName = 'messages';
  }
  // #unsubscribe?token=... — 해시에 쿼리가 붙은 형태. 페이지명만 분리
  if (page.startsWith('unsubscribe')) {
    pageName = 'unsubscribe';
  }

  // 메시지 페이지를 떠나면 폴링·상태 정리 (같은 페이지 내 다른 응모건 이동은 제외)
  const _prevActivePage = document.querySelector('#appShell .page.active');
  if (_prevActivePage && _prevActivePage.id === 'page-messages' && pageName !== 'messages'
      && typeof cleanupMessagesPage === 'function') {
    cleanupMessagesPage();
  }

  // Vercel Web Analytics — 인플 앱 페이지별 접속 카운트
  try {
    if (typeof window.va === 'function') {
      window.va('event', { name: 'pv_inf', page: pageName });
    }
  } catch (e) { /* analytics 실패 무시 */ }

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
  if (gnbBurger) gnbBurger.style.display = ['login','signup','forgot','reset-pw','unsubscribe'].includes(pageName) ? 'none' : '';
  // 비로그인 플로팅 CTA (인증 페이지 제외)
  if (typeof updateFloatingAuthCta === 'function') updateFloatingAuthCta(pageName);

  if (pageName === 'home') { loadCampaigns(); if (typeof renderPolicyNoticeBanner === 'function') renderPolicyNoticeBanner(); }
  else { const _pnb = document.getElementById('policyNoticeBannerWrap'); if (_pnb) _pnb.style.display = 'none'; }  // 배너는 fixed 오버레이 → 홈 외 페이지에선 숨김
  if (pageName === 'campaigns') loadCampaignsPage();
  if (pageName === 'mypage') {
    if (!currentUser) { navigate('login'); return; }
    closeMypageSub();
    loadMyPage();
  }
}

// 메일 1-click 수신거부 처리 (#unsubscribe?token=...)
// 토큰만으로 익명 호출 → 성공/무효 화면 토글. 비로그인 상태에서도 동작.
async function handleUnsubscribePage(token) {
  const elLoading = $('unsubLoading');
  const elSuccess = $('unsubSuccess');
  const elInvalid = $('unsubInvalid');
  const show = (target) => {
    [elLoading, elSuccess, elInvalid].forEach(el => { if (el) el.style.display = 'none'; });
    if (target) target.style.display = '';
  };
  show(elLoading);
  if (!token) { show(elInvalid); return; }
  try {
    const res = (typeof unsubscribeByToken === 'function') ? await unsubscribeByToken(token) : {ok:false};
    if (res.ok) {
      // 이름은 DB 값 — textContent 로 주입 (교차 사이트 스크립팅 방지)
      const nameEl = $('unsubName');
      if (nameEl) nameEl.textContent = res.name || '';
      show(elSuccess);
    } else {
      show(elInvalid);
    }
  } catch(e) {
    show(elInvalid);
  }
}

// 브라우저 뒤로가기/앞으로가기 버튼 처리
window.addEventListener('popstate', function(e) {
  const page = e.state?.page || location.hash.replace('#','') || 'home';
  // 마이페이지: state.page='mypage'(서브 동반) 또는 해시가 '#mypage-xxx'(state 유실)인 경우 모두 처리.
  // 랜딩 화면 제거 후 closeMypageSub 가 응모이력으로 복귀하므로 빈 화면이 나오지 않도록 한다.
  if (page === 'mypage' || page.startsWith('mypage-')) {
    navigate('mypage', false);
    const sub = e.state?.sub || (page.startsWith('mypage-') ? page.replace('mypage-','') : null);
    // popstate 는 이미 history 가 그 entry 로 이동한 상태 — openMypageSub 의 pushState 를 또 호출하면
    // 새 entry 가 추가돼 뒤로가기가 어긋남. false 전달로 push 스킵.
    if (sub) openMypageSub(sub, false); else closeMypageSub();
  } else if (page.startsWith('detail-')) {
    openCampaign(page.replace('detail-',''));
  } else if (page.startsWith('messages-')) {
    if (typeof openMessagesPage === 'function') openMessagesPage(page.replace('messages-',''), 'mypage', false);
    else navigate('mypage', false);
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
  else if (page === 'app-cancel') {
    // 응모 취소 페이지: data-i18n 정적 텍스트는 applyI18n 가 처리하지만
    // JS 로 동적 채운 영역(경고 메시지, 카테고리 select)은 stale.
    // 현재 대상 신청 ID 가 있으면 페이지 데이터 재렌더.
    if (typeof _cancelTargetAppId !== 'undefined' && _cancelTargetAppId
        && typeof openCancelModalFor === 'function') {
      openCancelModalFor(_cancelTargetAppId);
    }
  }
  // 햄버거 메뉴 재렌더 (언어에 따라 라벨 갱신)
  if (typeof renderNavMenu === 'function') renderNavMenu();
});

// Step 3: 햄버거 메뉴 활성 페이지 하이라이트
function updateActiveNav(page) {
  const map = {home:'home', detail:'home', mypage:'mypage', campaigns:'campaigns', activity:'mypage', messages:'mypage', 'app-cancel':'mypage'};
  const active = map[page] || 'home';
  document.querySelectorAll('.nav-item').forEach(el => {
    el.classList.toggle('on', el.dataset.nav === active);
  });
}

// ══════════════════════════════════════
// Pull-to-Refresh — 모바일 네이티브 앱처럼 페이지 최상단에서 아래로 당기면 새로고침
//   #appShell 내부 .page.active(스크롤 컨테이너) 의 touch 이벤트로 작동.
//   인증 페이지(login/signup/forgot/reset-pw)는 비활성. activity 등 기타 페이지 모두 허용.
//   임계값 80px 충족 후 손 놓으면 location.reload() 로 진짜 페이지 새로고침.
// ══════════════════════════════════════
function setupPTR() {
  const appShell = $('appShell');
  const indicator = $('ptrIndicator');
  if (!appShell || !indicator) return;
  if (appShell.dataset.ptrBound === '1') return;
  appShell.dataset.ptrBound = '1';

  // page-messages 는 스크롤이 페이지가 아니라 내부 #msgModalThread 에서 일어나 page.scrollTop 이
  //   항상 0 → PTR 이 "최상단"으로 오인해 이전 메시지 스크롤 중 새로고침이 발동. 헤더 새로고침 버튼이
  //   있으므로 PTR 비활성 (2026-05-27).
  const PTR_BLOCKLIST = ['page-login','page-signup','page-forgot','page-reset-pw','page-messages'];
  const RESISTANCE = 0.5;     // 당기는 거리에 0.5 곱해 자연스러운 저항감
  const TRIGGER_AT = 90;      // 인디케이터 활성화 임계값(px, RESISTANCE 적용 후)
                              // — 실제 손가락 이동 거리 약 180px
  const MAX_PULL = 130;       // 최대 당김 거리 클램프

  let startY = 0;
  let pullY = 0;
  let pulling = false;
  let activePage = null;
  let isRefreshing = false;

  const reset = () => {
    indicator.style.transform = 'translate(-50%, -56px)';
    indicator.classList.remove('active');
    if (activePage) {
      activePage.style.transition = 'transform .25s ease';
      activePage.style.transform = '';
      setTimeout(() => { if (activePage) activePage.style.transition = ''; }, 250);
    }
    pulling = false;
    activePage = null;
    pullY = 0;
  };

  appShell.addEventListener('touchstart', (e) => {
    if (isRefreshing) return;
    const page = document.querySelector('#appShell .page.active');
    if (!page) return;
    if (PTR_BLOCKLIST.includes(page.id)) return;
    // 모달/오버레이 등 활성 페이지 바깥을 터치하면 PTR 비활성 — 모달 내부 스크롤과 충돌 방지
    if (!page.contains(e.target)) return;
    if ((page.scrollTop || 0) > 0) return;
    activePage = page;
    startY = e.touches[0].clientY;
    pullY = 0;
    pulling = true;
  }, { passive: true });

  appShell.addEventListener('touchmove', (e) => {
    if (!pulling || !activePage || isRefreshing) return;
    const dy = e.touches[0].clientY - startY;
    if (dy < 0) { reset(); return; }
    // 컨테이너가 다시 스크롤된 상태로 바뀌면 PTR 종료
    if ((activePage.scrollTop || 0) > 0) { reset(); return; }
    pullY = dy;
    const adjusted = Math.min(pullY * RESISTANCE, MAX_PULL);
    indicator.style.transform = `translate(-50%, ${Math.min(adjusted - 16, 40)}px)`;
    activePage.style.transform = `translateY(${adjusted}px)`;
    if (adjusted >= TRIGGER_AT) indicator.classList.add('active');
    else indicator.classList.remove('active');
  }, { passive: true });

  appShell.addEventListener('touchend', () => {
    if (!pulling || !activePage || isRefreshing) return;
    const adjusted = Math.min(pullY * RESISTANCE, MAX_PULL);
    if (adjusted >= TRIGGER_AT) {
      // 새로고침 실행 — 인디케이터를 임계 위치에 고정하고 회전 애니메이션
      isRefreshing = true;
      indicator.style.transform = `translate(-50%, 24px)`;
      indicator.classList.add('refreshing');
      // location.reload() 직전에 약간 지연을 두어 사용자에게 회전 애니메이션 노출
      setTimeout(() => { window.location.reload(); }, 250);
    } else {
      reset();
    }
  });
  // 시스템 인터럽트(전화·알림·멀티터치) 시에도 페이지가 들뜬 상태로 남지 않도록 reset
  appShell.addEventListener('touchcancel', () => {
    if (pulling) reset();
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
          // 정책 변경 사전 통지 — 로그인 직후 1회 팝업 + 홈 배너 갱신
          if (typeof maybeShowPolicyNotice === 'function') maybeShowPolicyNotice();
          if (typeof renderPolicyNoticeBanner === 'function') renderPolicyNoticeBanner();
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
  } else if (hash && hash.startsWith('unsubscribe')) {
    // 메일 1-click 수신거부 — #unsubscribe?token=... (비로그인 진입 가능)
    const token = new URLSearchParams(hash.split('?')[1] || '').get('token');
    navigate('unsubscribe', false);
    handleUnsubscribePage(token);
  } else if (hash && hash.startsWith('mypage-')) {
    const sub = hash.replace('mypage-','');
    navigate('mypage', false);
    // 새로고침 init — URL 이 이미 #mypage-sub 라 openMypageSub 의 pushState 는 동일 entry 중복.
    openMypageSub(sub, false);
  } else if (hash && hash.startsWith('messages-')) {
    // 응모건 메시지 페이지 새로고침 복원 — openMessagesPage 가 캐시(_myApps) 보장
    const appId = hash.replace('messages-','');
    if (typeof openMessagesPage === 'function') openMessagesPage(appId, 'mypage', false);
    else navigate('mypage', false);
  } else if (hash === 'activity') {
    // 활동관리 페이지 새로고침 — _activityAppId·_activityCamp 글로벌이 NULL 이라 데이터 복원 불가.
    // 빈 폼·뒤로가기 회귀 → 응모이력으로 안전 폴백.
    // history 정리: 현재 entry 의 URL/state 자체를 #mypage-applications 로 replaceState
    // (#activity entry 가 stack 에 남으면 뒤로가기 시 또 마주침). openMypageSub 도 false 로 호출.
    history.replaceState({page:'mypage', sub:'applications'}, '', '#mypage-applications');
    navigate('mypage', false);
    if (typeof openMypageSub === 'function') openMypageSub('applications', false);
  } else if (hash && hash !== 'home') {
    navigate(hash, false);
  } else {
    history.replaceState({page:'home'}, '', '#home');
  }

  // 초기화 완료 — cloak 해제
  const cloak = document.getElementById('app-cloak');
  if (cloak) cloak.remove();

  // 정책 변경 사전 통지 — 이미 로그인된 채 진입한 회원에게 1회 팝업 + 홈 배너 갱신.
  //   초기 해시 #home 은 navigate('home') 미경유(replaceState 만)라 배너 훅이 안 걸려 여기서 직접 호출.
  if (typeof maybeShowPolicyNotice === 'function') maybeShowPolicyNotice();
  if (typeof renderPolicyNoticeBanner === 'function') renderPolicyNoticeBanner();
}

document.addEventListener('DOMContentLoaded', async function() {
  // recovery 진행 중이면 home 대신 reset-pw 페이지 활성화
  let inRecovery = false;
  try { inRecovery = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}

  const initHash = location.hash.replace('#','') || 'home';
  const initPage = inRecovery ? 'reset-pw'
    : (initHash.startsWith('detail-') ? 'detail'
    : initHash.startsWith('mypage-') ? 'mypage'
    : initHash.startsWith('messages-') ? 'messages'
    : initHash.startsWith('unsubscribe') ? 'unsubscribe'
    : initHash);
  const initEl = $('page-' + initPage);
  if (initEl) initEl.classList.add('active');
  else $('page-home')?.classList.add('active');

  allCampaigns = DEMO_CAMPAIGNS.slice();
  if (initPage === 'home') {
    renderCampaigns(allCampaigns.filter(c => c.status !== 'closed'));
    updateStats(allCampaigns);
  }
  await init();
  // Pull-to-Refresh 등록 (1회) — appShell 단일 리스너
  if (typeof setupPTR === 'function') setupPTR();

  // 모바일 키보드 대응: visualViewport로 appShell 높이 동적 조절.
  //   resize·scroll 이 키보드 애니메이션 중 연속 발생하므로 requestAnimationFrame 으로
  //   1프레임 1회로 묶고, 값이 실제 바뀔 때만 스타일 적용 → 리플로우 반복(깜빡임) 방지 (2026-05-27).
  if (window.visualViewport) {
    var appShell = $('appShell');
    var _vvLastVh = -1, _vvLastTop = -1, _vvRaf = false;
    function adjustHeight() {
      if (_vvRaf) return;
      _vvRaf = true;
      requestAnimationFrame(function() {
        _vvRaf = false;
        var vh = Math.round(window.visualViewport.height);
        var offsetTop = Math.round(window.visualViewport.offsetTop);
        if (vh === _vvLastVh && offsetTop === _vvLastTop) return; // 변경 없으면 skip
        _vvLastVh = vh; _vvLastTop = offsetTop;
        appShell.style.height = vh + 'px';
        appShell.style.top = offsetTop + 'px';
        // 메시지 페이지: 키보드로 높이가 바뀌면 마지막 메시지가 보이도록 대화 영역 최하단 유지
        var _ap = appShell.querySelector('.page.active');
        if (_ap && _ap.id === 'page-messages') {
          var _th = document.getElementById('msgModalThread');
          if (_th) _th.scrollTop = _th.scrollHeight;
        }
      });
    }
    window.visualViewport.addEventListener('resize', adjustHeight);
    window.visualViewport.addEventListener('scroll', adjustHeight);
  }
});
