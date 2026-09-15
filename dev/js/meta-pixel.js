// ════════════════════════════════════════════════════════════════════
// 메타 픽셀 — 인플루언서 앱 공용 전송 함수 (사양서 docs/specs/2026-09-03-meta-pixel.md)
// ════════════════════════════════════════════════════════════════════
// 사양서 「인플루언서 앱 쪽 흐름」 1~7 과 ⑯(민감 주소)을 이 파일 하나의 상태 기계로 옮겼다.
//   작업표 docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 5」.
//
// 🔴 인플루언서 앱 전용. 관리자 앱(dev/admin/index.html · ADMIN_JS_FILES)에는 넣지 않는다(사양서 ⑥).
// 🔴 이벤트 이름·상태 값은 여기 문자열로 쓰지 말고 dev/lib/shared.js 의
//    META_PIXEL_EVENTS · META_PIXEL_REG_STATUS 를 쓴다(이름 고정 — 결정 5).
// 🔴 아이디는 dev/lib/storage.js fetchPublicMetaPixelId() 로만 받는다 — '' = 보내지 않음, null = 조회 실패.
// 🔴 고급 매칭(이메일·전화 등 회원 정보)을 넘기지 않는다 — fbq('init') 에 세 번째 인자를 절대 붙이지 말 것(결정 11).
//    붙이면 「메타의 직접 취득이라 동의가 필요 없다」는 법적 전제가 무너진다.
// 🔴 어떤 실패도 화면을 막지 않는다 — 공개 함수는 전부 try/catch 로 삼킨다.
//
// 상태 셋(흐름 5):
//   'pending' 판정 전 — 수동 이벤트를 버리지 않고 줄에 쌓는다(부팅 중 확인 링크 착지·광고 링크 상세 진입)
//   'on'      켜짐   — 바로 보낸다
//   'off'     꺼짐   — 버리고 줄도 비운다(미리보기·민감 주소·아이디 없음·잠금·조회 실패 등 사유 무관)

// 흐름 1 — 관리자 캠페인 미리보기는 처음부터 꺼짐. 표시는 dev/index.html 머리의 스크립트가
//   이 파일보다 먼저 <html> 에 붙인다.
let _metaPixelState = (function () {
  try { return document.documentElement.classList.contains('preview-mode') ? 'off' : 'pending'; }
  catch (e) { return 'off'; }
})();
let _metaPixelQueue = [];
let _metaPixelLoginSeq = 0;       // 로그인 순번 — 조회 도중 로그인이 있었는지 가른다(흐름 7)
let _metaPixelBootReached = false; // 흐름 2 자리에 왔는가
let _metaPixelFetching = false;    // 조회가 진행 중인가(부팅·로그인 재조회 공통)
let _metaPixelUserId = null;       // 마지막으로 본 로그인 계정 — 로그인 「전이」 판정용(S3)
let _metaPixelLoaded = false;      // 픽셀 스크립트를 이미 불러왔는가(한 탭에 한 번)

const META_PIXEL_QUEUE_MAX = 50;   // 판정 전 줄 상한 — 조회가 멈춰도 메모리가 계속 늘지 않게
const META_PIXEL_SCRIPT_URL = 'https://connect.facebook.net/en_US/fbevents.js';

// ── 민감 주소 판정 (사양서 ⑯ · 작업표 S1·S2) ─────────────────────────────
//   🔴 판정은 **이 함수 한 곳**이다. 밖에서 따로 만들지 않는다(작업표 공유 지점 7).
//   🔴 검색부(location.search)와 해시(location.hash) **둘 다** 본다 — 이 앱은 값을 두 자리에 싣는다.
//   대상(2026-09-15 코드·메일 링크 대조로 확정):
//     code          가입 확인 코드 `?code=` (검색부)
//     invite        초대 번호 `#detail-{id}?invite=`
//     token         수신거부 토큰 `#unsubscribe?token=` — 이 값이면 남의 수신 설정을 끌 수 있다
//     token_hash    비밀번호 재설정 `#reset-pw?token_hash=` — 🔴 이 값이면 남의 비밀번호를 바꿀 수 있다
//     access_token / refresh_token, type=recovery   옛 방식 재설정 해시 `#access_token=…&type=recovery`
//     promo_token   홍보 메일 캠페인 링크 `#detail-{id}?promo_token=` — 값이 수신거부 토큰과 **같다**
//                   (notify-campaign-promo-digest). 앱이 읽지 않아 주소에 그대로 남는다
//   ⚠️ 이름에 token 이 들어간 열쇠는 목록에 없어도 민감으로 본다 — 새 링크가 생겨도 새지 않는 쪽으로.
const META_PIXEL_SENSITIVE_KEYS = ['code', 'invite'];

function _metaPixelParamSources() {
  const out = [];
  if (location.search) out.push(location.search.replace(/^\?/, ''));
  const h = (location.hash || '').replace(/^#/, '');
  if (h.includes('?')) out.push(h.slice(h.indexOf('?') + 1));
  else if (h.includes('=')) out.push(h); // 옛 방식 해시 — `#access_token=…&type=recovery`
  return out;
}

function metaPixelUrlHasSensitiveValue() {
  try {
    for (const src of _metaPixelParamSources()) {
      for (const [rawKey, rawVal] of new URLSearchParams(src)) {
        const key = rawKey.toLowerCase();
        if (META_PIXEL_SENSITIVE_KEYS.includes(key) || key.includes('token')) return true;
        if (key === 'type' && String(rawVal).toLowerCase() === 'recovery') return true;
      }
    }
    return false;
  } catch (e) {
    return true; // 판정이 깨지면 새지 않는 쪽 — 이 방문은 픽셀을 불러오지 않는다
  }
}

// ── 픽셀 불러오기 ────────────────────────────────────────────────────────
//   메타 공식 설치 코드와 같은 동작을 읽기 쉽게 풀어 쓴 것이다. 스크립트가 도착하기 전 호출은
//   fbq 가 자체 줄에 담아 두었다가 도착하면 보낸다.
function _metaPixelLoadScript(pixelId) {
  if (_metaPixelLoaded) return;
  _metaPixelLoaded = true;
  if (!window.fbq) {
    const fbq = function () {
      if (fbq.callMethod) fbq.callMethod.apply(fbq, arguments);
      else fbq.queue.push(arguments);
    };
    fbq.push = fbq; fbq.loaded = true; fbq.version = '2.0'; fbq.queue = [];
    window.fbq = fbq;
    if (!window._fbq) window._fbq = fbq;
    const s = document.createElement('script');
    s.async = true;
    s.src = META_PIXEL_SCRIPT_URL;
    document.head.appendChild(s);
  }
  // 자동 이벤트(버튼 클릭·페이지 정보 수집) 끄기 — 회원 정보를 보내지 않는다는 전제(결정 11)를
  //   코드 쪽에서도 지킨다. ⚠️ 이 설정이 화면 전환 페이지뷰 자동 감지에 영향을 주는지는
  //   1-검증 ②(작업 8)에서 시험용 픽셀로 확인한다.
  window.fbq('set', 'autoConfig', false, pixelId);
  window.fbq('init', pixelId); // 🔴 세 번째 인자(고급 매칭) 금지 — 결정 11
  window.fbq('track', META_PIXEL_EVENTS.PAGE_VIEW); // 흐름 3 — 초기화 시 페이지뷰 1회
}

function _metaPixelSend(name, params) {
  try {
    if (typeof window.fbq !== 'function') return;
    if (params) window.fbq('track', name, params);
    else window.fbq('track', name);
  } catch (e) { /* 전송 실패가 화면을 막지 않는다 */ }
}

function _metaPixelFlush() {
  const q = _metaPixelQueue;
  _metaPixelQueue = [];
  q.forEach(ev => _metaPixelSend(ev.name, ev.params));
}

function _metaPixelSetOff() {
  _metaPixelState = 'off';
  _metaPixelQueue = [];
}

// ── 조회 (흐름 3·4·6·7) ──────────────────────────────────────────────────
//   origin: 'boot'  부팅 조회 — 부정 결과면 꺼짐(흐름 4)
//           'login' 켜진 탭의 로그인 재조회 — 부정 결과면 새로고침(흐름 6)
//   🔴 부팅 조회가 흐름 7 로 다시 도는 경우도 origin 은 'boot' 그대로다(사양서 흐름 5 「꺼짐」 괄호).
// ── 흐름 6 새로고침 보류 ─────────────────────────────────────────────────
//   🔴 로그인 화면은 관리자 계정이면 `/admin/` 으로 옮긴다(auth.js handleLogin). 그 판정(관리자 표 조회)이
//      끝나기 전에 여기서 새로고침하면 **이동 코드 자체가 실행되지 못해** 관리자가 인플루언서 화면에 남는다.
//      로그인 사건 처리기(app.js)가 로그인 함수보다 먼저 불려 재조회를 시작하므로, 호출 순서를 바꾸는 것으로는
//      못 막는다 → 로그인 화면이 처리하는 동안 새로고침을 **보류**하고, 일반 회원으로 끝나면 풀어 준다.
//   ⚠️ 관리자로 끝나면 풀지 않는다(곧 다른 문서로 떠나 전송이 멈춘다). 오류로 끝나는 경로는 시간이 지나면
//      저절로 풀린다 — 풀리지 않은 보류가 이후 로그인의 새로고침을 영영 막지 않게.
//   ⚠️ 보류 중에도 상태는 판정 전이라 수동 이벤트는 줄에 남아 나가지 않는다.
const META_PIXEL_RELOAD_HOLD_MS = 15000;
let _metaPixelReloadHoldUntil = 0;
let _metaPixelReloadWanted = false;
let _metaPixelLeaving = false;     // 페이지를 떠나기 시작했는가(보류·재조회 동안만 듣는다)
function _metaPixelOnLeave() { _metaPixelLeaving = true; }

function _metaPixelMaybeReload() {
  if (!_metaPixelReloadWanted || _metaPixelLeaving) return;
  if (Date.now() < _metaPixelReloadHoldUntil) return;
  _metaPixelReloadWanted = false;
  location.reload();
}

// 로그인 화면이 로그인 요청 **직전**에 부른다. 반환 없음 — 풀기는 metaPixelReleaseReload().
function metaPixelHoldReload() {
  try {
    _metaPixelReloadHoldUntil = Date.now() + META_PIXEL_RELOAD_HOLD_MS;
    window.addEventListener('beforeunload', _metaPixelOnLeave);
    setTimeout(_metaPixelMaybeReload, META_PIXEL_RELOAD_HOLD_MS + 50);
  } catch (e) { /* 보류 실패가 로그인을 막지 않는다 */ }
}

// 로그인 화면이 **일반 회원으로 끝났을 때만** 부른다(관리자로 이동하는 갈래에서는 부르지 않는다).
function metaPixelReleaseReload() {
  try {
    _metaPixelReloadHoldUntil = 0;
    if (!_metaPixelFetching) window.removeEventListener('beforeunload', _metaPixelOnLeave);
    _metaPixelMaybeReload();
  } catch (e) { /* 새로고침 실패가 화면을 막지 않는다 */ }
}

async function _metaPixelFetch(origin) {
  _metaPixelFetching = true;
  _metaPixelState = 'pending';
  // 떠나기 시작하면 브라우저가 알려 주는 사건을 재조회 동안에도 듣는다(상시로 달면 뒤로가기 캐시에 영향)
  if (origin === 'login') window.addEventListener('beforeunload', _metaPixelOnLeave);
  let id = null;
  // 흐름 7 — 응답(성공·실패)을 받았는데 그사이 로그인이 있었으면 결과를 쓰지 않고 다시 묻는다.
  //   반복은 조회 도중 일어난 로그인 횟수를 넘지 않는다.
  for (;;) {
    const seq = _metaPixelLoginSeq;
    try { id = await fetchPublicMetaPixelId(); } catch (e) { id = null; }
    if (seq === _metaPixelLoginSeq) break;
  }
  // 보류 중이면 떠남 감지를 계속 둔다 — 보류가 끝나기 전 관리자 이동이 시작될 수 있다
  if (origin === 'login' && Date.now() >= _metaPixelReloadHoldUntil) {
    window.removeEventListener('beforeunload', _metaPixelOnLeave);
  }
  _metaPixelFetching = false;
  try {
    _metaPixelApplyResult(origin, id);
  } catch (e) {
    // 부르는 쪽이 기다리지 않는 비동기라 여기서 새면 처리 안 된 오류가 된다 — 꺼짐으로 닫는다
    _metaPixelSetOff();
    if (typeof logAppError === 'function') logAppError('metaPixelApplyResult', e);
  }
}

// 앱이 이미 알고 있는 「관리자·감사용 계정」 표시 — 서버 판정(438)의 **보조** 확인이다.
//   🔴 로그인 직후 조회가 드물게 로그인 정보 없이 나가면(라이브러리가 매 호출 저장소를 다시 읽다 실패하는 경우 —
//      2026-09-10 운영 실측, docs/research/2026-09-10-signup-confirm-link-misrouted-to-reset.md) 서버는 비로그인으로
//      보고 아이디를 준다. 픽셀은 한 번 불러오면 걷어낼 수 없어, 앱이 아는 표시가 있으면 아이디를 받아도 쓰지 않는다.
//   ⚠️ 관리자 표 조회가 픽셀 조회보다 늦게 끝나면 이 표시가 아직 없다 — 완전한 차단이 아니라 확률을 줄이는 장치다.
function _metaPixelLocalExcluded() {
  const u = (typeof currentUser !== 'undefined') ? currentUser : null;
  const p = (typeof currentUserProfile !== 'undefined') ? currentUserProfile : null;
  return !!(u && u._isAdmin === true) || !!(p && p.is_audit === true);
}

function _metaPixelApplyResult(origin, id) {
  const ok = typeof id === 'string' && /^[0-9]+$/.test(id) && !_metaPixelLocalExcluded();
  if (ok) {
    // ⚠️ 이미 불러온 탭에서 아이디가 바뀌었으면 옛 아이디로 계속 보낸다(사양서 ⑬ — 새로고침 전까지)
    _metaPixelLoadScript(id);
    _metaPixelState = 'on';
    _metaPixelFlush();
    return;
  }
  if (origin === 'login') {
    // 흐름 6 — 이유(관리자 계정·전체 끄기·아이디 삭제·잠금·통신 실패)를 가르지 않고 새로고침.
    //   이미 불러온 픽셀은 걷어낼 수 없어 새로고침으로 확실히 멈춘다. 새로 켜진 앱이 부팅 조회로
    //   다시 판정하고, 거기서도 실패하면 꺼짐으로 끝나 반복되지 않는다.
    //   ⚠️ 로그인 화면이 처리 중이면 보류했다가 끝나면 새로고침한다(위 「새로고침 보류」). 상태는 판정 전으로
    //      남겨 그사이 수동 이벤트는 줄에만 쌓인다.
    _metaPixelReloadWanted = true;
    _metaPixelMaybeReload();
    return;
  }
  _metaPixelSetOff();
}

// ── 공개 함수 ────────────────────────────────────────────────────────────

// 흐름 2 — app.js init() 의 세션 복원·방문자 집계 바로 뒤에서 부팅 1회 부른다.
//   🔴 세션 복원 전에 부르면 관리자가 비로그인으로 보여 서버가 아이디를 내준다.
//   🔴 민감 값 판정은 **여기서 한 번**이다 — 가입 확인 코드는 이 자리 전에 지워져 있어야
//      4번 이벤트가 산다(작업표 S8, 사양서 ⑯ 표).
function initMetaPixel() {
  try {
    if (_metaPixelBootReached) return;
    _metaPixelBootReached = true;
    _metaPixelUserId = (typeof currentUser !== 'undefined' && currentUser && currentUser.id) || null;
    if (_metaPixelState === 'off') { _metaPixelSetOff(); return; } // 흐름 1(미리보기)
    if (metaPixelUrlHasSensitiveValue()) { _metaPixelSetOff(); return; }
    if (typeof fetchPublicMetaPixelId !== 'function') { _metaPixelSetOff(); return; }
    _metaPixelFetch('boot');
  } catch (e) {
    _metaPixelSetOff();
    if (typeof logAppError === 'function') logAppError('initMetaPixel', e);
  }
}

// 수동 이벤트는 전부 이 함수를 거친다(흐름 5). 픽셀이 스스로 보내는 자동 페이지뷰는 거치지 않는다.
//   name 은 META_PIXEL_EVENTS 값만 받는다 — 문자열을 직접 넘기면 조용히 버린다(이름 고정, 결정 5).
function trackMetaPixelEvent(name, params) {
  try {
    if (!Object.values(META_PIXEL_EVENTS).includes(name)) return;
    if (_metaPixelState === 'off') return;
    if (_metaPixelState === 'on') { _metaPixelSend(name, params); return; }
    if (_metaPixelQueue.length < META_PIXEL_QUEUE_MAX) _metaPixelQueue.push({name, params});
  } catch (e) { /* 이벤트 기록 실패가 화면을 막지 않는다 */ }
}

// 흐름 6 — 로그인 사건 훅. app.js onAuthStateChange 와 auth.js handleLogin 두 자리에서 부른다.
//   🔴 「로그인 사건」 = **로그인 계정이 바뀐 순간 한 번**(작업표 S3). app.js 처리기는 SIGNED_IN 과
//      TOKEN_REFRESHED 를 한 조건으로 받으므로, 사건 이름으로 거르면 켜진 탭이 토큰 갱신마다
//      재조회하고 관리자가 픽셀을 끈 뒤라면 응모서를 쓰던 화면이 새로고침된다. 그래서 계정
//      고유번호로 가른다 — 같은 계정의 반복 호출(토큰 갱신·두 자리 중복 호출)은 전부 무시된다.
//   🔴 이 함수 안에서 조회를 **기다리지(await) 말 것.** 토큰 갱신 알림은 라이브러리가 내부 빗장을 건 채
//      보내므로, 여기서 조회 응답을 기다리면 빗장을 서로 기다리는 교착이 생긴다(supabase-js 2.116 확인).
//   ⚠️ 로그아웃 때 기억을 비우지 않는다 — 같은 계정이 다시 로그인하면 관리자 여부가 바뀔 일이 없어
//      재조회가 필요 없고, 다른 계정이면 고유번호가 달라 전이로 잡힌다.
function notifyMetaPixelSignedIn(userId) {
  try {
    if (!_metaPixelBootReached) return; // 흐름 2 전 — 흐름 2 가 로그인 상태에서 판정한다
    const uid = userId || null;
    if (!uid || uid === _metaPixelUserId) return;
    _metaPixelUserId = uid;
    _metaPixelLoginSeq++;
    if (_metaPixelFetching) return;       // 조회 중 — 흐름 7 이 순번을 보고 다시 묻는다
    if (_metaPixelState !== 'on') return; // 꺼짐 — 탭 도중에 픽셀을 새로 불러오지 않는다
    _metaPixelFetch('login');
  } catch (e) { /* 재판정 실패가 로그인을 막지 않는다 */ }
}
