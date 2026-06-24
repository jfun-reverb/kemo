// ══════════════════════════════════════════════════════
// REVERB JP — iOS 앱 전용 네이티브 푸시 알림 (1단계: 권한 요청 + 토큰 등록)
//   이 파일은 ios-app/www 에만 있고 sync-ios.sh 가 앱 빌드에만 주입한다.
//   → 운영 웹(globalreverb.com)에는 절대 실리지 않음(웹 누출 0).
//   추가로 isNativePlatform 가드로 이중 안전(웹뷰가 아닌 곳에선 즉시 종료).
//
//   등록/해지 DB 호출은 storage.js 의 registerPushToken / revokePushToken(공용) 사용.
//   발송(서버 → 기기)은 다음 단계(PR 2)에서 구현.
// ══════════════════════════════════════════════════════
(function () {
  var Cap = window.Capacitor;
  // 네이티브 앱(WKWebView)에서만 동작 — 웹 브라우저면 즉시 종료
  if (!Cap || typeof Cap.isNativePlatform !== 'function' || !Cap.isNativePlatform()) return;

  var Push = Cap.Plugins && Cap.Plugins.PushNotifications;
  if (!Push) return;

  var _lastToken = null;     // 이 기기의 마지막 APNs 토큰 (로그아웃 해지용)
  var _listenersBound = false;

  function bindListeners() {
    if (_listenersBound) return;
    _listenersBound = true;

    // 기기 토큰 수신 → 서버에 등록(UPSERT)
    Push.addListener('registration', function (token) {
      var value = token && token.value;
      if (!value) return;
      _lastToken = value;
      if (typeof registerPushToken === 'function') {
        try { registerPushToken(value, 'ios'); } catch (e) {}
      }
    });

    // 등록 실패는 조용히 (사용자 흐름 방해 금지)
    Push.addListener('registrationError', function () {});

    // 푸시 탭 시 처리 — deep-link(해당 화면 이동)는 다음 단계(PR 3)
    Push.addListener('pushNotificationActionPerformed', function () {});
  }

  // 로그인 후 호출: 권한 확인/요청 → 허용 시 토큰 등록 시작
  async function enablePush() {
    try {
      bindListeners();
      var perm = await Push.checkPermissions();
      if (perm.receive === 'prompt' || perm.receive === 'prompt-with-rationale') {
        perm = await Push.requestPermissions();
      }
      if (perm.receive !== 'granted') return;   // 거부 시 조용히 종료
      await Push.register();                     // → 'registration' 리스너로 토큰 전달
    } catch (e) {}
  }

  // 로그아웃 시 호출: 이 기기 토큰 해지(다른 사람이 같은 기기 로그인 시 알림 오염 방지)
  async function revokePushOnLogout() {
    if (!_lastToken) return;
    if (typeof revokePushToken === 'function') {
      try { await revokePushToken(_lastToken); } catch (e) {}
    }
    _lastToken = null;
  }

  // auth.js(로그인/로그아웃)에서 호출하는 전역 훅
  window._enablePush = enablePush;
  window._revokePushOnLogout = revokePushOnLogout;
})();
