// =============================================================================
// 사용자(인플루언서) 앱 에러 수집 — 관리자 오류 로그 전송 (실시간 아님, 백그라운드 무음)
//   사양서: docs/specs/2026-06-02-client-error-reporting.md
//   - 전역 미처리 예외(window.onerror·unhandledrejection) + 처리된 에러(friendlyErrorJa) 수집
//   - 클라 1차 마스킹(이메일·전화·우편번호·토큰) 후 report_client_error RPC 로 전송
//   - 서버에서 2차 마스킹 + fingerprint 묶음 (마이그레이션 165)
//   - 절대 throw 안 함(보고 실패가 앱을 막지 않음), 재진입·디바운스 가드
// =============================================================================
(function () {
  let _reporting = false;              // 재진입 가드 (보고 중 발생한 에러로 무한루프 방지)
  const _recentFp = new Map();         // fingerprint → 마지막 전송 시각 (디바운스)
  const DEBOUNCE_MS = 60000;           // 같은 fingerprint 60초 내 1회만 전송

  // 우리 책임이 아닌/무의미한 에러 (네트워크 끊김·브라우저 확장·CORS 가림 등) — 수집 제외
  const NOISE = [
    /ResizeObserver loop/i,
    /^Script error\.?$/i,              // CORS 로 가려진 외부 스크립트 에러
    /AbortError/i,
    /Load failed/i,
    /NetworkError|Failed to fetch/i,   // 사용자 네트워크 끊김
    /Non-Error promise rejection/i,
    /chrome-extension|moz-extension|safari-extension/i,
    /browser\.runtime/i,               // 아이폰 Safari 확장이 주입한 확장 API 접근 에러 (앱 코드 아님)
    /webkit-masked-url/i,              // Safari 가 확장 스크립트 출처를 가린 URL (스택에만 등장)
    /__firefox__|window\.__gCrWeb|__edgeReader/i,  // iOS 브라우저(Firefox/Brave/Chrome/Edge) 리더뷰 주입 스크립트 (앱 코드 아님)
  ];

  function _toMessage(v) {
    try {
      if (typeof v === 'string') return v;
      if (v && v.message) return String(v.message);
      return String(v);
    } catch (_) { return ''; }
  }

  // 클라 1차 마스킹 (서버 RPC 가 2차로 한 번 더 가림)
  function _mask(s) {
    if (!s) return s;
    return String(s)
      .replace(/[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/g, '[email]')
      .replace(/(\+81|\+82|0)\d[\d\-]{8,12}/g, '[phone]')
      .replace(/\d{3}-\d{4}/g, '[zip]')                 // 하이픈 필수 (7자리 ID 과마스킹 방지)
      .replace(/Bearer\s+\S+/g, 'Bearer [token]');
  }

  // 32bit 해시 (외부 의존 없는 간단 해시)
  function _hash(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
    return 'fp' + (h >>> 0).toString(36);
  }

  // fingerprint: 메시지 정규화(숫자·UUID 제거) + 스택 첫 위치
  function _fingerprint(msg, stack) {
    const norm = (msg || '')
      .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '#uuid#')
      .replace(/\d+/g, '#')
      .slice(0, 200);
    const loc = ((stack || '').split('\n')[1] || '')
      .replace(/:\d+:\d+/g, '')
      .replace(/\d+/g, '#')
      .slice(0, 120);
    return _hash(norm + '|' + loc);
  }

  function _isNoise(msg, stack) {
    // 메시지·스택을 각각 검사 (합치면 끝에 공백이 붙어 ^...$ 앵커 정규식이 빗나감 — "Script error." 누락 버그)
    return NOISE.some((re) => re.test(msg || '') || re.test(stack || ''));
  }

  // 에러 1건 수집 → 마스킹 → reportClientError RPC. 절대 throw 안 함.
  async function collectClientError(err, kind) {
    if (_reporting) return;
    try {
      const msg = _toMessage(err);
      if (!msg) return;
      const stack = (err && err.stack) ? String(err.stack) : '';
      if (_isNoise(msg, stack)) return;

      const fp = _fingerprint(msg, stack);
      const now = Date.now();
      const last = _recentFp.get(fp);
      if (last && (now - last) < DEBOUNCE_MS) return;   // 디바운스
      _recentFp.set(fp, now);
      // 메모리 누수 방지 — 디바운스 맵이 커지면 오래된 항목 정리
      if (_recentFp.size > 200) {
        for (const [k, ts] of _recentFp) { if (now - ts > DEBOUNCE_MS) _recentFp.delete(k); }
      }

      const codeMatch = msg.match(/\[(ERR_[A-Z]+_\d+)\]/);
      const payload = {
        p_fingerprint: fp,
        p_source: 'influencer',
        p_kind: kind,
        p_message: _mask(msg).slice(0, 1000),
        p_error_code: codeMatch ? codeMatch[1] : null,
        p_stack: _mask(stack).slice(0, 4000),
        p_page_hash: _mask((location.hash || '').replace(/\d+/g, '#')).slice(0, 200),
        p_context: null,
        p_user_agent: (navigator.userAgent || '').slice(0, 512),
      };

      _reporting = true;
      try {
        if (typeof reportClientError === 'function') await reportClientError(payload);
      } finally {
        _reporting = false;
      }
    } catch (_) {
      // 보고 자체가 실패해도 완전 무음 — 앱 동작을 절대 막지 않는다
      _reporting = false;
    }
  }

  // 전역 미처리 예외 핸들러 등록 (앱 부트 시 1회)
  function initErrorReporting() {
    window.addEventListener('error', function (e) {
      collectClientError(e.error || e.message, 'unhandled');
    });
    window.addEventListener('unhandledrejection', function (e) {
      collectClientError(e.reason, 'rejection');
    });
  }

  // 전역 노출 (concat 빌드 — 다른 파일에서 호출)
  window.collectClientError = collectClientError;
  window.initErrorReporting = initErrorReporting;
})();
