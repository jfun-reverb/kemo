// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════

// 비밀번호 재설정 URL 감지 — 스크립트 로드 즉시 (Supabase SDK가 URL 소비하기 전에)
(function detectRecoveryUrlEarly() {
  try {
    const hasCode = new URLSearchParams(location.search).has('code');
    const hasRecoveryHash = location.hash.includes('type=recovery') || location.hash.includes('access_token=');
    // 새 형식 링크 #reset-pw?token_hash=... (2026-07-20) — 기존 조건은 그대로 두고 조건만 추가.
    // 검증 성공 시 진짜 로그인 상태가 되므로, 비밀번호를 안 바꾸고 이탈해도 로그인된 채로 남지 않도록
    // 기존 「재설정 중에는 로그인 취급 안 함」 장치를 그대로 타게 한다.
    const hasNewRecoveryLink = location.hash.startsWith('#reset-pw?');
    if (hasCode || hasRecoveryHash || hasNewRecoveryLink) {
      sessionStorage.setItem('reverb.recovery', '1');
    }
  } catch(e) {}
})();

let _detailFrom = null;
let _screenTitle = null;  // iOS GNB 제목용 — openCampaign/openActivityPage 가 담고 navigate 가 읽는다

// ── 뒤로가기 — 쌓은 만큼만 되감는다 ─────────────────────────────
// 화면에 들어오며 히스토리 항목을 쌓았는지 기억해 두고, 뒤로가기 버튼은 그것을 **소비해서**
// 돌아간다(history.back). 예전에는 뒤로가기가 목적지로 **새 항목을 쌓는** 방식이라, 같은 화면을
// 왕복할 때마다 스택이 두 칸씩 길어졌다. 그러면 가장자리 스와이프로 뒤로 갈 때 지나온 화면이
// 몇 번씩 다시 나온다(입장 티켓을 반복해서 열면 응모이력이 계속 나오던 실제 보고).
//   쌓지 않고 들어온 경우(새로고침·popstate 복원)는 되감을 항목이 없으므로 폴백으로 이동한다.
const _pushedInto = {};
function markPushedInto(screen, pushed) { _pushedInto[screen] = (pushed !== false); }
function goBackFrom(screen, fallback) {
  if (_pushedInto[screen]) { _pushedInto[screen] = false; history.back(); return; }
  if (typeof fallback === 'function') fallback();
}

// iOS GNB 뒤로가기 버튼의 동작 — 현재 화면에 맞는 복귀 함수로 위임.
//   상세와 활동관리는 돌아갈 곳이 서로 달라 화면 id 로 분기한다.
function gnbBackAction() {
  const active = document.querySelector('#appShell .page.active');
  if (active && active.id === 'page-activity' && typeof navigateBackFromActivity === 'function') {
    navigateBackFromActivity();
    return;
  }
  // 마이페이지 서브 화면(기본정보·SNS 등) → 마이페이지 목록으로
  if (active && active.id === 'page-mypage' && typeof openMypageList === 'function') {
    openMypageList();
    return;
  }
  navigateBackFromDetail();
}

// 캠페인 상세 뒤로가기 — openCampaign 이 기록한 진입 출처로 돌아간다.
//   목록에서 들어왔는데 홈으로 튕기던 문제 때문에 'campaigns' 분기를 추가했다.
function navigateBackFromDetail() {
  const from = _detailFrom;
  _detailFrom = null;
  const _fallback = function () {
    if (from === 'mypage') {
      navigate('mypage', false);
      openMypageSub('applications');
    } else if (from === 'campaigns') {
      navigate('campaigns');
    } else {
      navigate('home');
    }
  };
  // 들어오며 쌓은 항목이 있으면 그것을 되감는다 — 새 항목을 쌓아 돌아가면 상세를 반복해서
  // 열고 닫을 때마다 스택이 길어져, 스와이프 뒤로가기가 지나온 화면을 여러 번 보여 준다.
  goBackFrom('detail', _fallback);
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
  // legal-{terms|privacy} — 약관 종류를 해시에 실어 새로고침·공유 링크로도 본문 복원
  if (page.startsWith('legal-')) {
    pageName = 'legal';
  }
  // ticket / ticket-{id} — 입장 티켓 화면 (오프라인 행사 예약, 2026-08-03)
  //   티켓 없이 들어오는 경로(햄버거)도 있어 접두어가 아니라 'ticket' 자체도 받는다.
  if (page === 'ticket' || page.startsWith('ticket-')) {
    pageName = 'ticket';
  }
  // #unsubscribe?token=... — 해시에 쿼리가 붙은 형태. 페이지명만 분리
  if (page.startsWith('unsubscribe')) {
    pageName = 'unsubscribe';
  }
  // #reset-pw?token_hash=... — 비밀번호 재설정 새 형식(수신거부와 같은 모양). 페이지명만 분리
  if (page.startsWith('reset-pw')) {
    pageName = 'reset-pw';
    // 값 없이 들어오는 경우(옛 형식 착지·만료 화면을 본 뒤 재진입)는 폼 상태로 복원.
    // 값이 있는 경우는 handleRecoveryTokenLink 가 상태를 직접 관리한다.
    if (!page.includes('?')) {
      const _v = $('resetPwVerifying'), _f = $('resetPwFormWrap'), _x = $('resetPwExpired');
      if (_v) _v.style.display = 'none';
      if (_x) _x.style.display = 'none';
      if (_f) _f.style.display = '';
    }
  }

  // 제출 연타 잠금 초기화 — 화면을 옮기면 잠금 키를 전부 비운다.
  //   ⚠️ 이게 없으면 업로드 도중 화면을 나갔다 다시 들어왔을 때 키가 남아 **다음 제출이
  //      조용히 막힌다**(아무 반응이 없어 사용자가 원인을 알 수 없는 형태).
  //      잠금은 한 화면 안에서 연타를 막는 게 목적이라 화면이 바뀌면 유지할 이유가 없다.
  if (typeof clearSubmitLocks === 'function') clearSubmitLocks();

  // 메시지 페이지를 떠나면 폴링·상태 정리 (같은 페이지 내 다른 응모건 이동은 제외)
  const _prevActivePage = document.querySelector('#appShell .page.active');
  if (_prevActivePage && _prevActivePage.id === 'page-messages' && pageName !== 'messages'
      && typeof cleanupMessagesPage === 'function') {
    cleanupMessagesPage();
  }
  // 티켓 화면을 떠나면 그린 내용을 비운다 — 다음에 들어올 때 남의 예약(또는 옛 예약)이
  // 잠깐 보이는 것을 막는다. 같은 페이지 안 티켓 전환은 제외.
  if (_prevActivePage && _prevActivePage.id === 'page-ticket' && pageName !== 'ticket'
      && typeof cleanupTicketPage === 'function') {
    cleanupTicketPage();
  }

  // Vercel Web Analytics — 인플 앱 페이지별 접속 카운트
  try {
    if (typeof window.va === 'function') {
      window.va('event', { name: 'pv_inf', page: pageName });
    }
  } catch (e) { /* analytics 실패 무시 */ }

  // 브라우저 히스토리에 기록 (뒤로가기 지원)
  //   ⚠️ 같은 화면으로 다시 오는 경우는 쌓지 않는다 — 탭을 두 번 누르거나 이미 보고 있는 화면으로
  //      이동하는 경로가 여럿이라, 쌓아 두면 뒤로가기가 화면 변화 없이 헛돈다.
  if (pushHistory !== false) {
    // 「같은 화면인가」는 쿼리를 뺀 부분끼리 비교한다.
    //   ⚠️ 해시에 쿼리가 붙는 화면이 있다 — 초대 링크(#detail-{id}?invite=CODE)·비밀번호 재설정
    //      (#reset-pw?token_hash=...). 통째로 비교하면 그 화면을 다시 그릴 때마다 「다른 화면」으로
    //      보여 항목이 쌓이고, 뒤로가기가 그 자리를 맴돌아 아무 데도 못 간다.
    //   ⚠️ 양쪽 다 정규화해야 한다. 한쪽만 하면 page 에 쿼리가 실려 오는 재설정 링크가 어긋난다.
    const _hashBase = location.hash.split('?')[0];
    const _pageBase = '#' + page.split('?')[0];
    if (_hashBase === _pageBase) {
      // 같은 화면 재렌더 — 주소 인자를 아예 넘기지 않아 지금 주소를 그대로 둔다.
      //   ⚠️ '#' + page 로 덮으면 ?invite=CODE 가 지워져, 새로고침 시 비공개 캠페인에 다시 못 들어간다.
      history.replaceState({page}, '');
    } else {
      history.pushState({page}, '', '#' + page);
      // 되감을 항목이 생긴 바로 그 순간에만 표시한다 — 화면을 **다시 그리는** 호출(신청 완료 후
      // 상세 재렌더·티켓 날짜 전환 등)은 여기 오지 않으므로 이미 세워 둔 표시를 지우지 않는다.
      //   ⚠️ 표시를 각 화면 함수에서 하면 재렌더가 「안 쌓았다」로 덮어써, 뒤로가기가 되감기 대신
      //      새 항목을 쌓는 옛 동작으로 돌아간다.
      markPushedInto(pageName, true);
    }
  }

  if (page === 'admin') {
    // 앱 번들에는 관리자 페이지가 없다. /admin/ 로 보내면 Capacitor 가 그 주소에서
    // 인플루언서 index.html 을 대신 띄워 자산 경로가 어긋난다(테마 전체 미적용).
    const _isNativeApp = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
    if (_isNativeApp) {
      if (typeof toast === 'function') toast('管理者ページはブラウザからご利用ください', 'error');
      return;
    }
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
  // iOS 탭바 활성 동기화 (응모이력/마이페이지 세부 구분은 tabNav 가 보정)
  if (typeof updateActiveTab === 'function') updateActiveTab({home:'home', campaigns:'campaigns', mypage:'mypage'}[pageName] || '');
  // iOS GNB 제목 — 캠페인 목록·상세만 여기서 설정. 마이페이지 계열은 openMypage* 가 보정. 홈은 로고(빈 제목)
  //   상세·활동관리 제목은 openCampaign/openActivityPage 가 _screenTitle 에 담아 둔 캠페인명을 쓴다.
  if (typeof setGnbTitle === 'function') {
    let _title = '';
    if (pageName === 'campaigns') _title = (typeof t === 'function' ? t('tab.campaigns') : '');
    else if (pageName === 'detail' || pageName === 'activity') _title = _screenTitle || '';
    setGnbTitle(_title);
  }
  // iOS 하단 뒤로가기 — 상세·활동관리에서만. 다른 화면 진입 시 반드시 꺼서 잔존 노출 방지
  if (typeof setGnbBack === 'function') setGnbBack(pageName === 'detail' || pageName === 'activity');
  // iOS GNB 검색 버튼 — 캠페인 목록에서만
  if (typeof setGnbSearch === 'function') setGnbSearch(pageName === 'campaigns');
  // 큰 제목 관찰자는 화면을 떠날 때 항상 해제 (활동관리 진입이 다시 켠다)
  if (typeof teardownLargeTitle === 'function') teardownLargeTitle();
  // 응모 바 도킹 관찰자도 해제 (상세 진입이 다시 켠다)
  if (typeof teardownFloatBarDock === 'function') teardownFloatBarDock();
  // 마이페이지를 떠나면 상단바에 올려 둔 응모이력 상태 필터를 제자리로 돌려놓는다
  if (pageName !== 'mypage' && typeof moveApplyFilterToGnb === 'function') moveApplyFilterToGnb(false);
  // iOS: 화면 안에 자체 헤더(뒤로가기·제목)를 가진 페이지는 GNB 로고 줄이 중복된다 → 상단바 숨김.
  //   ⚠️ 자체 헤더(.detail-back)를 쓰는 화면을 새로 만들면 이 목록에도 넣어야 한다.
  //      빠뜨리면 헤더가 두 줄로 겹쳐 보인다(입장 티켓·응모 취소가 실제로 그랬다).
  //   웹은 '' 로 되돌려 CSS 를 따른다(항상 표시).
  const _selfHeaderPages = ['legal', 'messages', 'ticket', 'app-cancel'];
  const _gnb = document.querySelector('.gnb');
  if (_gnb) {
    const _isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
    _gnb.style.display = (_isNative && _selfHeaderPages.includes(pageName)) ? 'none' : '';
  }
  // 가입 페이지 진입 시 생년월일 select 채우기 (멱등)
  if (pageName === 'signup' && typeof populateBirthdateSelects === 'function') populateBirthdateSelects();
  // 인증 페이지에선 햄버거·탭바 숨김
  const gnbBurger = $('gnbBurger');
  const _isAuthPage = ['login','signup','forgot','reset-pw','unsubscribe'].includes(pageName);
  if (gnbBurger) gnbBurger.style.display = _isAuthPage ? 'none' : '';
  const _tabbar = document.getElementById('iosTabbar');
  // 메시지 화면도 탭바를 숨긴다 — 입력창이 화면 맨 아래에 붙어 있어 탭바와 겹친다(자체 헤더에 뒤로가기가 있다)
  const _hideTabbar = _isAuthPage || pageName === 'messages';
  if (_tabbar) _tabbar.style.display = _hideTabbar ? 'none' : '';  // '' = CSS 따름(웹 none / iOS flex)
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
    // ⚠️ 통신 장애도 「잘못된 링크」 화면이 된다 — 수신거부를 하려던 사람이
    //    링크가 죽은 줄 알고 포기한다(법적으로 민감한 경로라 흔적이 필요하다).
    logAppError('handleUnsubscribePage', e);
    show(elInvalid);
  }
}

// 비밀번호 재설정 새 형식 링크 처리 (#reset-pw?token_hash=...) — 2026-07-20
//   메일 서식이 일회용 값을 주소의 `#` 뒤에 담아 보내므로, 메일 추적 서버·보안 스캐너가
//   주소를 열어도 값이 서버에 전달되지 않아 소모되지 않는다. 실제 소모는 아래 verifyOtp
//   호출(브라우저에서 사람이 도착한 뒤)에서 처음 일어난다.
//   성공 시 세션이 생기고, 기존 #page-reset-pw 폼 + handleResetPassword 를 그대로 탄다.
async function handleRecoveryTokenLink(tokenHash) {
  const elVerifying = $('resetPwVerifying');
  const elForm = $('resetPwFormWrap');
  const elExpired = $('resetPwExpired');
  const show = (target) => {
    [elVerifying, elForm, elExpired].forEach(el => { if (el) el.style.display = 'none'; });
    if (target) target.style.display = '';
  };

  // 검증 성공 시 진짜 로그인 세션이 만들어진다. 재설정 플래그를 먼저 세워
  // 기존 안전장치(로그인 취급 안 함 / 재설정 화면 유도)를 그대로 작동시킨다.
  try { sessionStorage.setItem('reverb.recovery', '1'); } catch(e) {}

  // 검증 실패 = 세션이 만들어지지 않음. 플래그를 남겨두면 「재설정 중」으로 오인해
  // 이후 새로고침 시 빈 재설정 폼으로 떨어진다 → 실패 시 반드시 되돌린다.
  const failed = () => {
    try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
    show(elExpired);
  };

  show(elVerifying);
  if (!tokenHash || !db) { failed(); return; }
  try {
    const {error} = await db.auth.verifyOtp({token_hash: tokenHash, type: 'recovery'});
    // 만료된 링크는 정상 거부지만, 그 밖의 원인이면 비밀번호를 못 바꾸는 상태가 된다.
    if (error) { logAppError('handleRecoveryTokenLink', error); failed(); return; }
    show(elForm);
    // 주소에서 일회용 값 제거 — 이미 쓴 값이라, 남겨두면 새로고침 시 만료 화면이 떠 혼란을 준다.
    try { history.replaceState({page:'reset-pw'}, '', '#reset-pw'); } catch(e) {}
  } catch(e) {
    logAppError('handleRecoveryTokenLink', e);
    failed();
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
    if (sub === 'list') { if (typeof openMypageList === 'function') openMypageList(false); }
    else if (sub) openMypageSub(sub, false);
    else closeMypageSub();
  } else if (page.startsWith('detail-')) {
    // 뒤로/앞으로 이동으로 여기 도착했다는 것은 스택 안에 되감을 항목이 있다는 뜻이다.
    // 표시해 두지 않으면 화면 안 뒤로가기 버튼이 되감기 대신 새 항목을 쌓는다.
    markPushedInto('detail', true);
    // 초대 링크(#detail-{id}?invite=CODE)로 들어올 수 있어 식별자만 떼어낸다.
    //   ⚠️ replace 만 하면 '?invite=...' 까지 캠페인 식별자로 넘어가 캠페인을 못 찾는다.
    openCampaign(typeof captureInviteFromHash === 'function' ? captureInviteFromHash(page) : page.replace('detail-',''));
  } else if (page.startsWith('messages-')) {
    markPushedInto('messages', true);
    if (typeof openMessagesPage === 'function') openMessagesPage(page.replace('messages-',''), 'mypage', false);
    else navigate('mypage', false);
  } else if (page.startsWith('legal-')) {
    // popstate 로 되돌아온 legal 항목은 앱 안에서 만든 기록이므로 「앱에서 열었음」으로 되살린다.
    //   안 그러면 앞으로가기로 재진입한 뒤 뒤로가기가 history.back() 대신 홈으로 새어 기록이 꼬인다.
    _legalOpenedInApp = true;
    openLegalPage(page.replace('legal-',''), undefined, false);
  } else if (page === 'activity') {
    markPushedInto('activity', true);
    // 앞으로가기로 활동관리 복귀. openActivityPage 를 부르면 그 안의 navigate 가 히스토리를 또 쌓으므로
    // 화면 전환만 하고, iOS 큰 제목 관찰자만 다시 건다(제목은 _screenTitle 이 그대로 유지).
    navigate(page, false);
    if (typeof setupLargeTitle === 'function') setupLargeTitle('page-activity', 'activityCampTitle');
  } else if (page === 'ticket' || page.startsWith('ticket-')) {
    markPushedInto('ticket', true);
    // 뒤로가기로 티켓 화면에 돌아온 경우 — pushState 를 또 하지 않도록 false 전달.
    if (typeof openTicketPage === 'function') openTicketPage(page.replace('ticket-','').replace('ticket',''), 'mypage', false);
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
  else if (page.startsWith('detail-')) { if (typeof openCampaign === 'function') openCampaign(typeof captureInviteFromHash === 'function' ? captureInviteFromHash(page) : page.replace('detail-','')); }
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

// ── iOS 바텀 탭바 (iOS 앱 전용) ──
// 탭 클릭 라우팅. 응모이력=마이페이지 안 응모이력 화면, 마이페이지=목록(목차) 화면.
// 탭바가 직접 가리키는 네 화면. 「지금 탭 화면에 있나」를 판정하는 데만 쓴다.
const TAB_HASHES = ['#home', '#campaigns', '#mypage-applications', '#mypage-list'];

function tabNav(tab) {
  // 탭 「사이」 이동은 히스토리에 쌓지 않는다 — 네 탭은 위아래 관계가 아니라 나란한 화면이라
  // 「뒤로」의 대상이 아니다(iOS 탭바 앱의 표준). 쌓으면 탭을 오간 만큼 뒤로가기가 화면 변화
  // 없이 헛돌아, 사용자에겐 「몇 번을 눌러도 같은 화면」으로 보인다(실제 보고).
  //   ⚠️ 단 **탭 위에 얹힌 화면**(캠페인 상세·활동관리·티켓)에서 탭을 누른 경우는 쌓는다.
  //      거기서도 지워 버리면 보고 있던 상세가 뒤로가기로 돌아갈 수 없게 사라진다.
  //   ⚠️ 이 값은 아래 navigate() 가 화면을 바꾸기 **전에** 읽어야 한다.
  const _fromTabScreen = TAB_HASHES.includes(location.hash);
  let _state = null, _hash = '';
  if (tab === 'home') { navigate('home', false); _state = {page:'home'}; _hash = '#home'; }
  else if (tab === 'campaigns') { navigate('campaigns', false); _state = {page:'campaigns'}; _hash = '#campaigns'; }
  else if (tab === 'activity') {
    if (!currentUser) { navigate('login'); return; }   // 로그인 화면은 정상적으로 쌓는다(돌아올 곳이 있어야 한다)
    navigate('mypage', false);
    if (typeof openMypageSub === 'function') openMypageSub('applications', false);
    _state = {page:'mypage', sub:'applications'}; _hash = '#mypage-applications';
  } else if (tab === 'mypage') {
    if (!currentUser) { navigate('login'); return; }
    navigate('mypage', false);
    if (typeof openMypageList === 'function') openMypageList(false);
    _state = {page:'mypage', sub:'list'}; _hash = '#mypage-list';
  }
  // 탭에서 탭으로면 현재 항목을 갈아 끼우고, 상세·활동관리·티켓 위에서 눌렀으면 새로 쌓는다.
  //   어느 쪽이든 주소는 갱신돼야 새로고침·공유가 지금 화면을 복원한다.
  if (_hash) {
    if (_fromTabScreen) history.replaceState(_state, '', _hash);
    else history.pushState(_state, '', _hash);
  }
  updateActiveTab(tab);
}
// 활성 탭 하이라이트
function updateActiveTab(tab) {
  document.querySelectorAll('#iosTabbar .ios-tab').forEach(t => t.classList.toggle('on', t.dataset.tab === tab));
}
// GNB 화면 제목 (iOS 앱 전용) — title 있으면 제목 표시+로고 숨김, 없으면 Reverb 로고
function setGnbTitle(title) {
  const titleEl = document.getElementById('gnbTitle');
  const logoEl = document.getElementById('gnbLogo');
  if (!titleEl || !logoEl) return;
  const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
  if (isNative && title) {
    titleEl.textContent = title;
    titleEl.style.display = '';
    logoEl.style.display = 'none';
  } else {
    titleEl.style.display = 'none';
    logoEl.style.display = '';
  }
}
// GNB 검색 버튼 (iOS 앱 전용) — 캠페인 목록에서만. 본문 헤더의 검색 버튼을 상단바로 올린 것.
function setGnbSearch(show) {
  const el = document.getElementById('gnbSearchBtn');
  if (!el) return;
  const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
  el.style.display = (isNative && show) ? '' : 'none';
}

// 캠페인 상세 응모 바 도킹 (iOS 앱 전용)
//   대표 이미지 아래 제목이 상단바 뒤로 넘어가면 응모 바를 화면 위로 붙인다.
//   제목은 이미 상단바에 있으므로 도킹 상태에서는 바 안의 제목 줄을 숨긴다(ios-theme).
let _floatBarObserver = null;
function setupFloatBarDock() {
  teardownFloatBarDock();
  const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
  if (!isNative || !('IntersectionObserver' in window)) return;
  const root = document.getElementById('page-detail');
  const target = document.getElementById('detailCampTitle');
  const bar = document.getElementById('detailFloatBar');
  if (!root || !target || !bar) return;
  const gnb = document.querySelector('.gnb');
  const gnbH = gnb ? gnb.offsetHeight : 0;
  _floatBarObserver = new IntersectionObserver(entries => {
    // 제목이 상단바 아래 영역에서 사라지면(위로 지나가면) 도킹
    entries.forEach(e => bar.classList.toggle('docked', !e.isIntersecting && e.boundingClientRect.top < gnbH));
  }, {root, rootMargin: `-${gnbH}px 0px 0px 0px`, threshold: 0});
  _floatBarObserver.observe(target);
}
function teardownFloatBarDock() {
  if (_floatBarObserver) { _floatBarObserver.disconnect(); _floatBarObserver = null; }
  const bar = document.getElementById('detailFloatBar');
  if (bar) bar.classList.remove('docked');
}

// iOS 「큰 제목」 패턴 (iOS 앱 전용)
//   화면 맨 위에서는 본문의 큰 제목이 전체를 보여주고 GNB 제목은 투명하게 감춘다.
//   스크롤해서 본문 제목이 화면 밖으로 나가면 GNB 제목이 나타난다(긴 이름은 말줄임).
//   → 같은 이름이 두 곳에 동시에 보이지 않고, 전체 이름은 최상단에서 확인할 수 있다.
let _largeTitleObserver = null;
function setupLargeTitle(scrollRootId, titleElId) {
  teardownLargeTitle();
  const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
  if (!isNative || !('IntersectionObserver' in window)) return;
  const root = document.getElementById(scrollRootId);
  const target = document.getElementById(titleElId);
  const gnbTitle = document.getElementById('gnbTitle');
  if (!root || !target || !gnbTitle) return;
  gnbTitle.classList.add('at-top');   // 진입 직후는 최상단 → GNB 제목 감춤
  // GNB 는 콘텐츠 위에 떠 있으므로(absolute), 그 높이만큼 관찰 범위 위쪽을 잘라낸다.
  //   안 그러면 본문 제목이 GNB 뒤에 가려져도 "보이는 중"으로 판정돼 전환이 안 일어난다.
  const gnb = document.querySelector('.gnb');
  const gnbH = gnb ? gnb.offsetHeight : 0;
  _largeTitleObserver = new IntersectionObserver(entries => {
    entries.forEach(e => gnbTitle.classList.toggle('at-top', e.isIntersecting));
  }, {root, rootMargin: `-${gnbH}px 0px 0px 0px`, threshold: 0});
  _largeTitleObserver.observe(target);
}
function teardownLargeTitle() {
  if (_largeTitleObserver) { _largeTitleObserver.disconnect(); _largeTitleObserver = null; }
  const gnbTitle = document.getElementById('gnbTitle');
  if (gnbTitle) gnbTitle.classList.remove('at-top');
}

// GNB 뒤로가기 버튼 (iOS 앱 전용) — 상세 화면에서만 표시. 다른 화면은 navigate 가 꺼 준다.
//   마이페이지 서브 화면은 탭바로 이동하므로 뒤로가기를 두지 않는다(목적지가 없음).
// 뒤로가기 버튼(iOS 앱 전용) — 탭바 왼쪽 원형 버튼. 'on' 이면 튀어나온다(ios-theme).
//   돌아갈 곳이 있는 화면(상세·활동관리·마이페이지 서브)에서만 켠다.
function setGnbBack(show) {
  const el = document.getElementById('iosTabBack');
  if (!el) return;
  const isNative = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
  el.classList.toggle('on', !!(isNative && show));
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
    // 숨김 위치 — components.css 의 초기값과 같은 식. --ptr-offset 은 화면 맨 위에서 얼마나
    // 내려 시작하는지(iOS 앱은 노치 높이)이고, 그만큼 더 올려야 완전히 감춰진다.
    indicator.style.transform = 'translate(-50%, calc(-56px - var(--ptr-offset)))';
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
  // 정산 인플루언서 공개 스위치 로드 (로그인 상태에서만 조회 가능).
  // updateGnb → renderNavMenu 보다 먼저 채워야 햄버거에 「報酬・精算」이 깜빡 보였다 사라지지 않는다.
  if (currentUser && typeof isSettlementPublic === 'function') {
    try { setSettlementPublic(await isSettlementPublic()); } catch(_) {}
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
          // 정산 인플루언서 공개 스위치 로드 (init 과 동일 — 로그인 직후 메뉴 렌더 전에 확정)
          if (typeof isSettlementPublic === 'function') {
            try { setSettlementPublic(await isSettlementPublic()); } catch(_) {}
          }
          updateGnb();
          // 로그인 시 알림 폴링 시작
          if (typeof startNotifPolling === 'function') startNotifPolling();
          // 정책 변경 사전 통지 — 로그인 직후 1회 팝업 + 홈 배너 갱신
          if (typeof maybeShowPolicyNotice === 'function') maybeShowPolicyNotice();
          if (typeof renderPolicyNoticeBanner === 'function') renderPolicyNoticeBanner();
          // 초대 링크로 들어와 가입한 뒤 **확인 메일 링크로 돌아온** 경우의 복귀.
          //   운영서버는 가입 시 이메일 확인이 필수라 handleSignup 이 세션 없이 먼저 끝난다
          //   → 그 경로는 auth.js 의 복귀 코드에 닿지 못한다. 확인 링크로 세션이 생기는
          //   이 자리가 신규 가입자의 실제 복귀 지점이다(2026-08-03 리뷰 지적).
          if (typeof consumeInviteReturn === 'function') { try { consumeInviteReturn(); } catch(_){} }
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

  if (hash && hash.startsWith('reset-pw?')) {
    // 비밀번호 재설정 새 형식 — #reset-pw?token_hash=... (비로그인 진입).
    // 위 recovery 스킵 분기보다 먼저 둔다. 새 형식도 재설정 플래그를 세우므로
    // 뒤에 두면 스킵에 걸려 검증이 실행되지 않는다.
    const tokenHash = new URLSearchParams(hash.split('?')[1] || '').get('token_hash');
    navigate('reset-pw', false);
    handleRecoveryTokenLink(tokenHash);
  } else if (isRecoveryInProgress || urlHasRecoveryCode) {
    // 초기 라우팅 건너뜀. PASSWORD_RECOVERY 핸들러가 reset-pw로 이동시킴.
  } else if (hash && hash.startsWith('detail-')) {
    // 초대 링크로 처음 들어온 경우 — 번호를 먼저 기억해 두고 상세를 연다.
    //   기억해 두지 않으면 상세 게이트가 번호를 다시 묻고, 예약 함수에도 못 넘긴다.
    const campId = (typeof captureInviteFromHash === 'function')
      ? captureInviteFromHash(hash) : hash.replace('detail-','');
    openCampaign(campId);
  } else if (hash && (hash.startsWith('legal-') || hash === 'legal')) {
    // 약관 딥링크·새로고침 — 종류 없는 구 링크(#legal)는 이용약관으로
    const kind = hash === 'legal' ? 'terms' : hash.replace('legal-','');
    openLegalPage(kind, undefined, false);
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
  } else if (hash === 'ticket' || (hash && hash.startsWith('ticket-'))) {
    // 티켓 화면 새로고침 복원 — openTicketPage 가 목록을 다시 받아오므로 상태 의존이 없다.
    const tid = hash.replace('ticket-', '').replace('ticket', '');
    if (typeof openTicketPage === 'function') openTicketPage(tid, 'mypage', false);
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
    // iOS 탭바 — 이 분기만 navigate() 를 안 거치므로(replaceState 뿐) 탭을 여기서 직접 켠다.
    //   ⚠️ 이 호출을 위 분기 바깥(공통 자리)으로 빼지 말 것. 다른 분기는 navigate·openMypageSub·
    //      openTicketPage 가 이미 정확한 탭을 켜 둔 뒤라, 공통 자리에서 화면 id 만 보고 다시 켜면
    //      그 값을 덮어쓴다. 실제로 #mypage-applications 로 새로고침하면 화면은 응모이력인데
    //      탭만 マイページ 로 남았다(티켓 화면 복귀 버그와 같은 원인).
    if (typeof updateActiveTab === 'function') updateActiveTab('home');
  }

  // 초기화 완료 — cloak 해제
  const cloak = document.getElementById('app-cloak');
  if (cloak) cloak.remove();

  // 정책 변경 사전 통지 — 이미 로그인된 채 진입한 회원에게 1회 팝업 + 홈 배너 갱신.
  //   초기 해시 #home 은 navigate('home') 미경유(replaceState 만)라 배너 훅이 안 걸려 여기서 직접 호출.
  if (typeof maybeShowPolicyNotice === 'function') maybeShowPolicyNotice();
  if (typeof renderPolicyNoticeBanner === 'function') renderPolicyNoticeBanner();

  // (iOS 탭바 초기 활성화는 위 라우팅 분기 안에서 각자 처리한다 — 여기서 화면 id 만 보고
  //  일괄로 켜면 서브 화면 구분이 없어 応募履歴 를 マイページ 로 덮어쓴다.)
}

document.addEventListener('DOMContentLoaded', async function() {
  // 햄버거 메뉴를 명시적으로 닫힌 상태로 초기화 — 새로고침(location.reload) 시 웹뷰가
  //   이전 DOM 상태(메뉴 열림)를 드물게 복원하는 현상 방어. 부팅 시 메뉴는 항상 닫혀 있어야 함.
  if (typeof closeNavPanel === 'function') closeNavPanel();
  // 전역 에러 수집 핸들러 등록 (가능한 일찍 — 마이그레이션 165)
  if (typeof initErrorReporting === 'function') { try { initErrorReporting(); } catch(_){} }
  // recovery 진행 중이면 home 대신 reset-pw 페이지 활성화
  let inRecovery = false;
  try { inRecovery = sessionStorage.getItem('reverb.recovery') === '1'; } catch(e) {}

  const initHash = location.hash.replace('#','') || 'home';
  const initPage = inRecovery ? 'reset-pw'
    : (initHash.startsWith('detail-') ? 'detail'
    : initHash.startsWith('mypage-') ? 'mypage'
    : initHash.startsWith('messages-') ? 'messages'
    : (initHash === 'ticket' || initHash.startsWith('ticket-')) ? 'ticket'
    : initHash.startsWith('unsubscribe') ? 'unsubscribe'
    : initHash.startsWith('reset-pw') ? 'reset-pw'
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
        // 키보드 열림 시 바텀 탭바 숨김 — 입력칸 가림 방지(과거 바텀탭 제거 사유 회피)
        //   기준은 documentElement.clientHeight — iOS 앱(WKWebView)의 window.innerHeight 는
        //   키보드를 따라 줄어들어 차이가 늘 0 이라 키보드를 못 알아본다.
        var _kbOpen = (document.documentElement.clientHeight - vh) > 120;
        var _tb = document.getElementById('iosTabbar');
        if (_tb) _tb.classList.toggle('kb-hidden', _kbOpen);
        // 하단 원형 뒤로가기도 함께 (CSS 형제 선택자로는 순서가 안 맞아 여기서 토글)
        var _tbBack = document.getElementById('iosTabBack');
        if (_tbBack) _tbBack.classList.toggle('kb-hidden', _kbOpen);
        // 탭바가 숨었으니 그 자리로 비워 둔 페이지 하단 여백도 걷는다(iOS 앱 전용 CSS).
        //   안 걷으면 키보드 바로 위에 그 여백이 흰 띠로 남는다.
        document.body.classList.toggle('kb-open', _kbOpen);
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
    // 앱을 백그라운드에 두는 동안 키보드가 닫히면 복귀 시 resize 가 안 올 수 있다.
    // 캐시를 비워 다음 계산을 강제 → kb-open 이 남아 여백이 사라진 채로 굳는 것을 막는다.
    document.addEventListener('visibilitychange', function() {
      if (document.visibilityState !== 'visible') return;
      _vvLastVh = -1; _vvLastTop = -1;
      adjustHeight();
    });
  }
});
