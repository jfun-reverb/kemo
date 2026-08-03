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
    s.src = 'https://cdn.jsdelivr.net/npm/qrcode@1.5.3/build/qrcode.min.js';
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
  // 확정 — QR + 예약번호. QR 이 안 그려져도 예약번호만으로 입장할 수 있어야 한다.
  return `
    <div class="ticket-qr-wrap">
      <canvas id="ticketQrCanvas" width="200" height="200"></canvas>
      <div id="ticketQrFallback" class="ticket-msg-err" style="display:none">${esc(t('event.ticketQrFailed'))}</div>
    </div>
    <div class="ticket-hint">${esc(t('event.ticketQrHint'))}</div>
    ${ticket.entered_at ? `<div class="ticket-entered">${esc(t('event.ticketEnteredAt').replace('{time}', formatDateTime(ticket.entered_at)))}</div>` : ''}`;
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

  if (ticket.status === 'confirmed') renderTicketQr(ticket.ticket_code, 'ticketQrCanvas');
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

// ── 본인 취소 ─────────────────────────────────────────────────
async function cancelMyTicket(ticketId) {
  // 화면의 비활성은 안내일 뿐이고, 실제 판정은 서버가 일본 시각 기준으로 한다.
  if (!window.confirm(t('event.ticketCancelConfirm'))) return;

  let res;
  try {
    res = await cancelEventTicket(ticketId);
  } catch (e) {
    console.error('[cancelMyTicket]', e);
    toast(t('event.ticketCancelFailGeneric'), 'error');
    return;
  }

  if (!res || !res.ok) {
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
    toast(t('event.ticketLoadFailed'), 'error');
    return;
  }
  const mine = _ticketList.filter(x => x.campaign_id === campaignId);
  // 취소분보다 살아 있는 예약을 먼저 연다.
  const target = mine.find(x => x.status !== 'cancelled') || mine[0];
  if (!target) { toast(t('event.ticketNotFound'), 'error'); return; }
  await openTicketPage(target.id, 'mypage');
}
