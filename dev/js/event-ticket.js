// ══════════════════════════════════════════════════════════════
// 입장 티켓(QR) 화면 — 오프라인 팝업 방문 예약
//   사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-3
//   작업표: 「작업 4」 · 데이터: 마이그레이션 280~284
//
// 방문객이 자기 예약을 확인하는 유일한 화면이다. 1차 범위에서는 확정 안내
// 메일이 없어(사양서 §0 결정 11) **이 화면이 티켓 그 자체**다.
//
// ⚠️ QR 은 브라우저에서만 그린다(외부 전송 0). 담는 값은 예약번호 8자리뿐이라
//    QR 사진이 SNS 에 올라가도 이름·이메일이 새지 않는다(사양서 §2-9 · §7-3).
// ══════════════════════════════════════════════════════════════

let _ticketList = [];        // 내 티켓 전체(취소분 포함 — 취소 이력도 보여 준다)
let _currentTicketId = null;
let _ticketFrom = 'mypage';  // 뒤로가기 목적지
let _qrLibLoading = null;    // 라이브러리 중복 로드 방지

// QR 라이브러리는 티켓 화면에 처음 들어올 때만 불러온다(글자인식·엑셀과 같은 방식).
function loadQrLib() {
  if (typeof window.QRCode !== 'undefined') return Promise.resolve();
  if (_qrLibLoading) return _qrLibLoading;
  _qrLibLoading = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    // ⚠️ 버전을 **1.5.1 로 고정**한다. 최신(1.5.3~1.5.6)은 브라우저용 묶음 파일
    //    build/qrcode.min.js 가 배포에서 빠져 404 다. 같은 버전의 lib/browser.min.js 는
    //    200 이 뜨지만 묶이지 않은 원본이라 브라우저에서 `require is not defined` 로
    //    죽고 전역 QRCode 가 끝내 안 생긴다 — 주소만 보고 고치면 여전히 QR 이 안 뜬다.
    //    (2026-08-03: 404 → QA 발견, lib 경로 → 리뷰 발견. 둘 다 실측으로 확인)
    //    1.5.1 의 build/qrcode.min.js 는 전역 QRCode.toCanvas 를 만드는 정상 묶음이다.
    s.src = 'https://cdn.jsdelivr.net/npm/qrcode@1.5.1/build/qrcode.min.js';
    s.onload = () => resolve();
    s.onerror = () => { _qrLibLoading = null; reject(new Error('qr_lib_failed')); };
    document.head.appendChild(s);
  });
  return _qrLibLoading;
}

// 예약이 하나라도 있는가 — 햄버거 메뉴에 「입장 티켓」을 넣을지 판단한다.
//   ⚠️ 취소분은 세지 않는다. 취소만 남은 사람에게 메뉴를 띄우면 눌러도 볼 게 없다.
function hasEventTicket() {
  return _ticketList.some(t => t && t.status !== 'cancelled');
}

// 티켓 목록을 미리 받아 둔다(햄버거 메뉴 표시 판단용). 로그인 직후·메뉴 열 때 호출.
async function preloadEventTickets() {
  if (!currentUser) { _ticketList = []; return; }
  try {
    _ticketList = await fetchMyEventTickets();
  } catch (e) {
    console.warn('[preloadEventTickets]', e);
    // 조회 실패는 「예약 없음」으로 두지 않는다 — 있던 목록을 그대로 유지한다.
    // 통신이 잠깐 끊겼다고 메뉴에서 티켓이 사라지면 방문객이 예약을 잃은 줄 안다.
  }
}

// ── 화면 열기 ─────────────────────────────────────────────────
// ticketId 를 안 주면 가장 가까운 예약(확정 우선)을 연다 — 햄버거에서 들어오는 경로.
async function openTicketPage(ticketId, from, push) {
  _ticketFrom = from || 'mypage';
  navigate('ticket' + (ticketId ? '-' + ticketId : ''), push !== false);

  const body = $('ticketBody');
  if (body) body.innerHTML = `<div class="ticket-msg">${esc(t('common.loading'))}</div>`;

  try {
    _ticketList = await fetchMyEventTickets();
  } catch (e) {
    console.error('[openTicketPage]', e);
    logAppError('openTicketPage', e);
    if (body) body.innerHTML = `<div class="ticket-msg ticket-msg-err">${esc(t('event.ticketLoadFailed'))}</div>`;
    return;
  }

  const usable = _ticketList.filter(x => x.status !== 'cancelled');
  const target = ticketId
    ? _ticketList.find(x => x.id === ticketId)
    : (usable[0] || _ticketList[0]);

  if (!target) {
    if (body) body.innerHTML = `<div class="ticket-msg">${esc(t(ticketId ? 'event.ticketNotFound' : 'event.ticketEmpty'))}</div>`;
    _currentTicketId = null;
    return;
  }
  _currentTicketId = target.id;
  renderTicket(target);
}

function cleanupTicketPage() {
  stopTicketWatch();
  _currentTicketId = null;
  const body = $('ticketBody');
  if (body) body.innerHTML = '';
}

function backFromTicket() {
  if (_ticketFrom === 'detail') { history.back(); return; }
  navigate('mypage', false);
  if (typeof openMypageSub === 'function') openMypageSub('applications');
}

// ── 렌더 ──────────────────────────────────────────────────────
// 티켓 가운데 영역 — 상태에 따라 QR / 대기 순번 / 취소 안내로 갈린다.
function ticketMainHtml(ticket) {
  if (ticket.status === 'cancelled') {
    return `
      <div class="ticket-state ticket-state-off">
        <span class="material-icons-round notranslate" translate="no">event_busy</span>
        <div>${esc(t('event.ticketCancelledTitle'))}</div>
      </div>`;
  }
  if (ticket.status === 'waitlist') {
    return `
      <div class="ticket-state ticket-state-wait">
        <span class="material-icons-round notranslate" translate="no">hourglass_top</span>
        <div class="ticket-state-title">${esc(t('event.ticketWaitlistTitle').replace('{n}', ticket.waitlist_position || '-'))}</div>
        <div class="ticket-state-hint">${esc(t('event.ticketWaitlistHint'))}</div>
      </div>`;
  }
  // 이미 입장했으면 **QR 자리에** 인증 완료를 띄운다(사용자 요청 2026-08-03).
  //   확인이 끝난 뒤에도 QR 이 그대로 있으면 방문객이 또 보여 줘야 하나 헷갈린다.
  if (ticket.entered_at) {
    return `
      <div class="ticket-state ticket-state-done">
        <svg class="ticket-check" viewBox="0 0 88 88" aria-hidden="true">
          <circle cx="44" cy="44" r="38"></circle>
          <path d="M26 45 L39 58 L63 33"></path>
        </svg>
        <div class="ticket-state-title">${esc(t('event.ticketEnteredTitle'))}</div>
        <div class="ticket-entered">${esc(t('event.ticketEnteredAt').replace('{time}', formatDateTime(ticket.entered_at)))}</div>
        <div class="ticket-state-hint">${esc(t('event.ticketEnteredHint'))}</div>
      </div>`;
  }
  // 확정 — QR + 예약번호. QR 이 안 그려져도 예약번호만으로 입장할 수 있어야 한다.
  return `
    <div class="ticket-qr-wrap">
      <canvas id="ticketQrCanvas" width="200" height="200"></canvas>
      <div id="ticketQrFallback" class="ticket-msg-err" style="display:none">${esc(t('event.ticketQrFailed'))}</div>
    </div>
    <div class="ticket-hint">${esc(t('event.ticketQrHint'))}</div>`;
}

// 예약이 여러 건일 때(취소 후 재예약 등) 위에 두는 전환 탭.
function ticketSwitchHtml(current) {
  if (_ticketList.length <= 1) return '';
  return `
    <div class="ticket-switch">
      ${_ticketList.map(x => `
        <button type="button" class="ticket-switch-btn${x.id === current.id ? ' on' : ''}"
                onclick="openTicketPage('${x.id}', '${esc(_ticketFrom)}', false)">
          ${esc(formatTicketWhenShort(x.event_slots || {}))}${x.status === 'cancelled' ? ` (${esc(t('event.ticketTabCancelled'))})` : ''}
        </button>`).join('')}
    </div>`;
}

function renderTicket(ticket) {
  const body = $('ticketBody');
  if (!body) return;

  const slot = ticket.event_slots || {};
  const camp = allCampaigns.find(c => c.id === ticket.campaign_id) || {};
  const p = currentUserProfile || {};
  const name = (p.name_kanji || p.name || '').trim();

  const when = formatTicketWhen(slot);
  // 장소는 캠페인의 행사장 안내 칸(마이그레이션 285). 아직 안 정해졌으면 그렇다고
  // 알린다 — 빈칸으로 두면 「어디로 가야 하는지 안 적힌 티켓」이 된다.
  const place = (camp.event_place || '').trim();

  const others = ticketSwitchHtml(ticket);

  const main = ticketMainHtml(ticket);

  const canCancel = ticket.status !== 'cancelled' && !ticket.entered_at;
  const windowPassed = (typeof eventCancelWindowPassed === 'function')
    && eventCancelWindowPassed(slot.slot_date, slot.start_time);

  body.innerHTML = `
    ${others}
    <div class="ticket-card${ticket.status === 'cancelled' ? ' off' : ''}">
      <div class="ticket-camp">${esc(camp.title || '')}</div>
      ${main}
      <div class="ticket-rows">
        <div class="ticket-row"><span>${esc(t('event.ticketCodeLabel'))}</span><b class="ticket-code">${esc(ticket.ticket_code)}</b></div>
        <div class="ticket-row"><span>${esc(t('event.ticketNameLabel'))}</span><b>${esc(name)}</b></div>
        <div class="ticket-row"><span>${esc(t('event.ticketWhenLabel'))}</span><b>${esc(when)}</b></div>
        <div class="ticket-row"><span>${esc(t('event.ticketPlaceLabel'))}</span><b>${esc(place || t('event.ticketPlaceTbd'))}</b></div>
      </div>
    </div>
    ${canCancel ? `
      <button type="button" class="btn btn-ghost btn-block ticket-cancel"
              ${windowPassed ? 'disabled' : ''} onclick="cancelMyTicket('${ticket.id}')">
        ${esc(windowPassed ? t('event.ticketCancelClosedShort') : t('event.ticketCancelBtn'))}
      </button>
      ${windowPassed ? `<div class="ticket-hint">${esc(t('event.ticketCancelClosed'))}</div>` : ''}
    ` : ''}`;

  if (ticket.status === 'confirmed' && !ticket.entered_at) renderTicketQr(ticket.ticket_code, 'ticketQrCanvas');
  startTicketWatch(ticket);
}

async function renderTicketQr(ticketCode, elId) {
  const canvas = $(elId);
  if (!canvas) return;
  try {
    await loadQrLib();
    await window.QRCode.toCanvas(canvas, String(ticketCode), {width: 200, margin: 1});
  } catch (e) {
    console.warn('[renderTicketQr]', e);
    // QR 이 없어도 예약번호로 입장할 수 있다 — 그렇게 안내하고 화면을 막지 않는다.
    canvas.style.display = 'none';
    const fb = $('ticketQrFallback');
    if (fb) fb.style.display = '';
  }
}

// 'YYYY-MM-DD' + 'HH:MM' → '8月28日(金) 11:00〜13:00'
function formatTicketWhen(slot) {
  if (!slot || !slot.slot_date) return '';
  const d = (typeof formatEventSlotDateLabel === 'function')
    ? formatEventSlotDateLabel(String(slot.slot_date).slice(0, 10))
    : String(slot.slot_date).slice(0, 10);
  const st = String(slot.start_time || '').slice(0, 5);
  const en = slot.end_time ? String(slot.end_time).slice(0, 5) : '';
  return `${d} ${en ? `${st}〜${en}` : st}`;
}

function formatTicketWhenShort(slot) {
  if (!slot || !slot.slot_date) return '-';
  const dt = String(slot.slot_date).slice(5, 10).replace('-', '/');
  return `${dt} ${String(slot.start_time || '').slice(0, 5)}`;
}

// ── 입장 확인 감시 ────────────────────────────────────────────
// 운영진이 QR 을 읽는 순간, 방문객 화면도 「인증 완료」로 바뀌어야 한다.
// 서버가 화면으로 먼저 알려 주는 구조가 아니라 우리가 주기적으로 물어본다.
//   ⚠️ 물어보는 조건을 좁게 둔다 — 티켓 화면이 켜져 있고, 확정이며, 아직 입장 전일 때만.
//      입장이 확인되면 즉시 멈춘다. 그러지 않으면 아무도 안 보는 화면이 하루 종일 서버를 두드린다.
let _ticketWatchTimer = null;
const TICKET_WATCH_MS = 5000;   // 입구에 서 있는 동안 바뀌는 것이 보이도록 짧게

function startTicketWatch(ticket) {
  stopTicketWatch();
  if (!ticket || ticket.status !== 'confirmed' || ticket.entered_at) return;
  _ticketWatchTimer = setInterval(() => checkTicketEntered(ticket.id), TICKET_WATCH_MS);
}

function stopTicketWatch() {
  if (_ticketWatchTimer) { clearInterval(_ticketWatchTimer); _ticketWatchTimer = null; }
}

async function checkTicketEntered(ticketId) {
  // 화면이 가려져 있으면 건너뛴다(주머니 속에서 계속 두드리지 않게).
  if (document.hidden) return;
  // 다른 화면으로 넘어갔으면 멈춘다.
  const page = document.querySelector('#appShell .page.active');
  if (!page || page.id !== 'page-ticket') { stopTicketWatch(); return; }

  try {
    const list = await fetchMyEventTickets();
    const fresh = (list || []).find(x => x.id === ticketId);
    if (!fresh) return;
    if (fresh.entered_at) {
      _ticketList = list;
      stopTicketWatch();
      renderTicket(fresh);   // QR 자리가 「인증 완료」로 바뀐다
    }
  } catch (e) {
    // 통신이 잠깐 끊긴 것뿐일 수 있다. 화면을 건드리지 않고 다음 차례에 다시 본다.
    console.warn('[checkTicketEntered]', e);
  }
}

// 화면으로 돌아오면 기다리지 않고 바로 한 번 확인한다.
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && _ticketWatchTimer && _currentTicketId) checkTicketEntered(_currentTicketId);
});

// ── 본인 취소 ─────────────────────────────────────────────────
async function cancelMyTicket(ticketId) {
  // 화면의 비활성은 안내일 뿐이고, 실제 판정은 서버가 일본 시각 기준으로 한다.
  if (!window.confirm(t('event.ticketCancelConfirm'))) return;

  let res;
  try {
    res = await cancelEventTicket(ticketId);
  } catch (e) {
    console.error('[cancelMyTicket]', e);
    logAppError('cancelEventTicket', e);
    toast(t('event.ticketCancelFailGeneric'), 'error');
    return;
  }

  if (!res || !res.ok) {
    // 사전에 있는 사유는 정상 거부, 그 밖의 값(서버 결함 등)은 예상 못 한 오류로 기록한다.
    //   ⚠️ `permission_denied` 는 **일부러 뺐다** — 본인 예약만 취소할 수 있으므로
    //      이 값이 나오면 정상 동작이 아니다(결함 또는 잘못된 호출).
    logAppError('cancelEventTicket', (res && res.reason) || 'no_result', [
      'cancel_window_passed', 'already_entered', 'cancelled',
      'settlement_paid_cannot_cancel', 'not_found'
    ]);
    const map = {
      cancel_window_passed:          'event.ticketCancelClosed',
      already_entered:               'event.ticketCancelFailEntered',
      cancelled:                     'event.ticketAlreadyCancelled',
      settlement_paid_cannot_cancel: 'event.ticketCancelFailGeneric',
      not_found:                     'event.ticketNotFound',
      permission_denied:             'event.ticketCancelFailGeneric',
    };
    toast(t(map[res && res.reason] || 'event.ticketCancelFailGeneric'), 'error');
    // 서버가 거부한 이유가 화면과 어긋난 상태(예: 이미 입장) 때문일 수 있으니 다시 받아온다.
    await openTicketPage(ticketId, _ticketFrom, false);
    return;
  }

  toast(t('event.ticketCancelDone'), 'success');
  await openTicketPage(ticketId, _ticketFrom, false);
  // 응모 이력도 함께 갱신 — 취소한 건이 「당선」으로 남아 보이지 않게.
  if (typeof loadMyApplications === 'function') { try { await loadMyApplications(); } catch (e) {} }
}

// 캠페인으로 내 티켓을 찾아 연다 — 응모 이력 카드에서 들어오는 경로.
//   응모 이력에는 티켓 식별자가 없어(신청과 티켓은 다른 표) 캠페인으로 찾는다.
async function openTicketForCampaign(campaignId) {
  try {
    _ticketList = await fetchMyEventTickets();
  } catch (e) {
    console.error('[openTicketForCampaign]', e);
    logAppError('openTicketForCampaign', e);
    toast(t('event.ticketLoadFailed'), 'error');
    return;
  }
  const mine = _ticketList.filter(x => x.campaign_id === campaignId);
  // 취소분보다 살아 있는 예약을 먼저 연다.
  const target = mine.find(x => x.status !== 'cancelled') || mine[0];
  if (!target) { toast(t('event.ticketNotFound'), 'error'); return; }
  await openTicketPage(target.id, 'mypage');
}
