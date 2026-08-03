// ══════════════════════════════════════════════════════════════
// 오프라인 팝업 방문 예약(티켓팅) — 관리자 화면
//   사양서: docs/specs/2026-07-30-offline-popup-ticketing.md §4-5
//   작업표: docs/specs/2026-07-30-offline-popup-ticketing-breakdown.md 「작업 2」
//   데이터: 마이그레이션 280~283
//
// 이 파일이 담당하는 것
//   ① 캠페인 등록·편집 폼의 「행사 모드」·「비공개」·초대 번호·리워드 잠금
//   ② 타임(시간대) 관리 페인 — 줄 단위 편집 + 하루치 일괄 생성
//   ③ 예약 현황 페인 — 타임별 집계 + 방문객 명단 + 입장 처리
//
// ⚠️ 데이터 접근은 전부 dev/lib/storage.js 의 함수를 쓴다. 이 파일에서 직접
//    db.from(...) 을 부르지 않는다(작업 1이 접근 함수를 한곳에 모아 둔 이유).
// ══════════════════════════════════════════════════════════════

// ── 상태 ──────────────────────────────────────────────────────
let _eventPaneCampId = null;     // 타임 관리·예약 현황이 보고 있는 캠페인
let _eventPaneCampTitle = '';
let _eventSlotsCache = [];
let _eventSlotCounts = {};
let _eventTicketsCache = [];
let _eventTicketSlotFilter = '';  // 예약 현황의 타임 필터('' = 전체)
let _eventTicketStatusTab = '';   // '' = 전체
// 신규 등록 폼에서 만든 초대 번호는 캠페인이 저장되기 전까지 갈 곳이 없다.
// addCampaign 이 성공한 뒤 그 캠페인 id 로 넣기 위해 잠시 들고 있는다.
let _pendingNewInviteCode = null;
// 행사 모드를 켜기 직전의 모집 형식. 끄면 여기로 되돌린다(리뷰 지적 — 조용한 형식 변경 방지).
const _recruitTypeBeforeEvent = {new: null, edit: null};

function _currentRecruitType(prefix) {
  const name = (prefix === 'edit') ? 'editRecruitType' : 'recruitType';
  return document.querySelector(`input[name="${name}"]:checked`)?.value || null;
}

const EVENT_TICKET_STATUS_TABS = [
  {key: '',          label: '전체'},
  {key: 'confirmed', label: '확정'},
  {key: 'waitlist',  label: '대기'},
  {key: 'entered',   label: '입장 완료'},
  {key: 'noshow',    label: '미입장'},
  {key: 'cancelled', label: '취소'},
];

// ══════════════════════════════════════════════════════════════
// ① 캠페인 폼 — 행사 모드·비공개·초대 번호
// ══════════════════════════════════════════════════════════════

// 행사 모드일 때 폼을 잠근다.
//   · 리워드는 0 고정 — 1엔이라도 들어가면 정산 대기가 생긴다(사양서 §2-5).
//     리워드가 0이면 정산 후보 조건에서 시딩·방문형이 제외되므로(마이그레이션 264)
//     정산 화면에 아무것도 새지 않는다.
//   · 모집 형식은 방문형 고정 — 리뷰어형에 켜지면 자동 승인 트리거가 「대기」를
//     승인으로 덮어써 티켓과 신청 상태가 어긋난다(마이그레이션 280 CHECK 와 같은 이유).
function applyEventModeFormLock(prefix) {
  const on = !!$(prefix + 'CampEventMode')?.checked;

  const reward = $(prefix + 'CampReward');
  if (reward) {
    if (on) {
      reward.value = '0';
      reward.readOnly = true;
      reward.classList.add('field-locked');
    } else {
      reward.readOnly = false;
      reward.classList.remove('field-locked');
    }
    // 인라인 스타일로 색을 칠하던 옛 방식의 잔재 제거(클래스로 일원화)
    reward.style.background = '';
    reward.style.color = '';
  }
  const rewardHint = $(prefix + 'CampRewardEventHint');
  if (rewardHint) rewardHint.style.display = on ? '' : 'none';
  const rewardNote = $(prefix + 'CampRewardLockNote');
  if (rewardNote) rewardNote.style.display = on ? '' : 'none';

  // 모집 형식 라디오 — 행사 모드면 방문형으로 고정하고 나머지를 잠근다.
  //   ⚠️ 라디오 name 이 폼마다 다르다: 신규는 recruitType, 편집은 editRecruitType.
  //      `${prefix}RecruitType` 로 쓰면 신규 폼에서 아무것도 안 잡힌다.
  const rtName = (prefix === 'edit') ? 'editRecruitType' : 'recruitType';
  document.querySelectorAll(`input[name="${rtName}"]`).forEach(r => {
    if (on) {
      if (r.value === 'visit' && !r.checked) {
        r.checked = true;
        // 형식이 바뀌면 채널 목록·최소 팔로워 칸이 따라 바뀌어야 한다.
        // 라디오의 onchange 가 하는 일을 그대로 태운다(판정을 새로 만들지 않는다).
        if (prefix === 'edit') { if (typeof toggleEditRT === 'function') toggleEditRT(r); }
        else                   { if (typeof toggleRT === 'function') toggleRT(r); }
        if (typeof filterChannelsByRecruitType === 'function') filterChannelsByRecruitType(prefix, 'visit');
        if (typeof applyMinFollowersVisibility === 'function') applyMinFollowersVisibility(prefix, 'visit');
      }
      r.disabled = (r.value !== 'visit');
    } else {
      r.disabled = false;
    }
    // 라디오 input 은 display:none 이고 라벨이 모양을 담당한다 — input 의 disabled 만으로는
    // 화면상 아무 변화가 없어 「고를 수 없는 항목」인지 알 수 없다. 라벨에 직접 표시한다.
    const lab = r.closest('label');
    if (lab) lab.classList.toggle('choice-locked', !!r.disabled);
  });

  // 모집 타입 제목 옆 「행사 모드라 방문형 고정」 안내 배지
  const rtNote = $(prefix + 'CampRecruitTypeLockNote');
  if (rtNote) rtNote.style.display = on ? '' : 'none';

  // 행사 모드를 껐으면 모집 형식을 원래대로 되돌린다.
  //   안 되돌리면 실수로 켰다 끈 관리자가 「형식이 조용히 방문형으로 바뀐 것」을
  //   모른 채 저장한다(2026-08-03 리뷰 지적).
  if (on) {
    // 켜기 직전 형식을 기억해 둔다(이미 기억해 둔 값이 있으면 덮어쓰지 않는다).
    if (_recruitTypeBeforeEvent[prefix] == null) {
      _recruitTypeBeforeEvent[prefix] = _currentRecruitType(prefix);
    }
  } else if (_recruitTypeBeforeEvent[prefix] != null) {
    const back = _recruitTypeBeforeEvent[prefix];
    _recruitTypeBeforeEvent[prefix] = null;
    if (back && back !== 'visit') {
      const el = document.querySelector(`input[name="${rtName}"][value="${back}"]`);
      if (el) {
        el.checked = true;
        if (prefix === 'edit') { if (typeof toggleEditRT === 'function') toggleEditRT(el); }
        else                   { if (typeof toggleRT === 'function') toggleRT(el); }
        if (typeof filterChannelsByRecruitType === 'function') filterChannelsByRecruitType(prefix, back);
        if (typeof applyMinFollowersVisibility === 'function') applyMinFollowersVisibility(prefix, back);
      }
    }
  }

  const opts = $(prefix + 'CampEventOpts');
  if (opts) opts.style.display = on ? '' : 'none';
  if (!on) {
    // 행사 모드를 끄면 비공개도 함께 내린다 — 비공개는 행사 전용 개념이다.
    const inv = $(prefix + 'CampInviteOnly');
    if (inv) inv.checked = false;
    applyInviteOnlyRow(prefix);
  }
}

function onEventModeToggle(prefix) {
  applyEventModeFormLock(prefix);
}

function applyInviteOnlyRow(prefix) {
  const on = !!$(prefix + 'CampInviteOnly')?.checked;
  const row = $(prefix + 'CampInviteRow');
  if (row) row.style.display = on ? '' : 'none';
}

function onInviteOnlyToggle(prefix) {
  applyInviteOnlyRow(prefix);
  // 비공개를 켰는데 번호가 없으면 하나 만들어 둔다(운영자가 잊고 저장하는 것 방지).
  if ($(prefix + 'CampInviteOnly')?.checked && !$(prefix + 'CampInviteCode')?.value) {
    genInviteCode(prefix);
  }
}

// 초대 번호 생성 — 예약번호와 같은 규칙(혼동 글자 0 O 1 I L 제외 31자, 8자리).
// 운영자가 전화로 불러 줄 수도 있어 읽기 쉬운 글자만 쓴다.
function genInviteCode(prefix) {
  // 이미 번호가 있으면 되묻는다 — 번호를 바꾸는 순간 이미 보낸 초대 링크가 전부 죽는다.
  //   첫 발급(칸이 비어 있음)은 묻지 않는다.
  const prev = $(prefix + 'CampInviteCode')?.value || '';
  if (prev && !window.confirm('초대 번호를 새로 만들면 이미 보낸 초대 링크는 즉시 쓸 수 없게 됩니다.\n계속할까요?')) {
    return prev;
  }
  const warn = $(prefix + 'CampInviteWarn');
  if (warn && prev) warn.style.display = '';

  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  let code = '';
  const buf = new Uint32Array(8);
  (window.crypto || window.msCrypto).getRandomValues(buf);
  for (let i = 0; i < 8; i++) code += alphabet[buf[i] % alphabet.length];
  const el = $(prefix + 'CampInviteCode');
  if (el) el.value = code;
  if (prefix === 'new') _pendingNewInviteCode = code;
  return code;
}

// 초대 링크 형식 — **여기서 단 한 번 결정한다.** 작업 5(방문객 쪽)가 이 형식을 파싱한다.
//   해시 뒤에 물음표를 붙이는 방식은 이미 선례가 있다(메일 수신거부 #unsubscribe?token=).
function eventInviteLink(campaignId, code) {
  const host = location.origin;
  return `${host}/#detail-${campaignId}?invite=${encodeURIComponent(code || '')}`;
}

async function copyInviteLink(prefix) {
  const campId = prefix === 'edit' ? ($('editCampId')?.value || '') : '';
  const code = $(prefix + 'CampInviteCode')?.value || '';
  if (!campId) {
    toast('먼저 캠페인을 저장해야 링크를 만들 수 있습니다', 'error');
    return;
  }
  if (!code) { toast('초대 번호를 먼저 만들어 주세요', 'error'); return; }
  const link = eventInviteLink(campId, code);
  try {
    await navigator.clipboard.writeText(link);
    toast('초대 링크를 복사했습니다');
  } catch (e) {
    // 클립보드 권한이 없는 환경 대비 — 값을 보여 주고 수동 복사하게 한다.
    window.prompt('아래 링크를 복사해 주세요', link);
  }
}

// 편집 폼을 열 때 행사 설정을 채운다. 초대 번호는 캠페인 표가 아니라 별도 표에 있다
// (마이그레이션 280 — 캠페인 표에 두면 브라우저로 유출된다).
async function loadEventSettingsIntoEditForm(camp) {
  const em = $('editCampEventMode');
  const io = $('editCampInviteOnly');
  if (em) em.checked = !!camp?.event_mode;
  if (io) io.checked = !!camp?.is_invite_only;
  const pl = $('editCampEventPlace');
  if (pl) pl.value = camp?.event_place || '';
  applyEventModeFormLock('edit');
  applyInviteOnlyRow('edit');

  const warnEl = $('editCampInviteWarn');
  if (warnEl) warnEl.style.display = 'none';

  const codeEl = $('editCampInviteCode');
  if (codeEl) {
    codeEl.value = '';
    if (camp?.is_invite_only && typeof fetchEventInvite === 'function') {
      try {
        const row = await fetchEventInvite(camp.id);
        if (row?.code) codeEl.value = row.code;
      } catch (e) { console.warn('[loadEventSettings] 초대 번호 조회 실패', e); }
    }
  }
}

// 캠페인 저장 뒤 초대 번호를 표에 넣는다(등록·편집 공용).
//   ⚠️ 캠페인 저장과 **분리된 호출**이라 실패해도 캠페인 저장은 이미 끝나 있다.
//      실패를 조용히 넘기면 「비공개인데 번호가 없어 아무도 못 들어오는」 캠페인이
//      생기므로, 실패는 반드시 화면에 알린다.
async function saveEventInviteAfterCampaignSave(prefix, campaignId) {
  const inviteOnly = !!$(prefix + 'CampInviteOnly')?.checked;
  const eventMode = !!$(prefix + 'CampEventMode')?.checked;
  if (!eventMode || !inviteOnly) return;

  const code = $(prefix + 'CampInviteCode')?.value
    || (prefix === 'new' ? _pendingNewInviteCode : '')
    || '';
  if (!code) {
    toast('비공개 캠페인인데 초대 번호가 없습니다. 편집에서 번호를 만들어 주세요', 'error');
    return;
  }
  try {
    await upsertEventInvite(campaignId, code);
  } catch (e) {
    console.error('[saveEventInvite]', e);
    toast('초대 번호 저장에 실패했습니다. 편집 화면에서 다시 시도해 주세요 — 저장 전까지 아무도 예약할 수 없습니다', 'error');
  } finally {
    if (prefix === 'new') _pendingNewInviteCode = null;
  }
}

// 신규 등록 폼 초기화 시 호출 (폼을 비울 때 행사 설정도 함께 초기화)
function resetEventFormFields(prefix) {
  const em = $(prefix + 'CampEventMode'); if (em) em.checked = false;
  const io = $(prefix + 'CampInviteOnly'); if (io) io.checked = false;
  const cc = $(prefix + 'CampInviteCode'); if (cc) cc.value = '';
  const pl = $(prefix + 'CampEventPlace'); if (pl) pl.value = '';
  if (prefix === 'new') _pendingNewInviteCode = null;
  _recruitTypeBeforeEvent[prefix] = null;
  const warn = $(prefix + 'CampInviteWarn');
  if (warn) warn.style.display = 'none';
  applyEventModeFormLock(prefix);
  applyInviteOnlyRow(prefix);
}

// ══════════════════════════════════════════════════════════════
// ② 타임(시간대) 관리 페인
// ══════════════════════════════════════════════════════════════

async function openEventSlotsPane(campId, campTitle) {
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  _eventPaneCampId = campId;
  _eventPaneCampTitle = campTitle || '';
  switchAdminPane('event-slots', null, true);
  await renderEventSlotsPane(campId);
}

async function renderEventSlotsPane(campaignId) {
  const campId = campaignId || _eventPaneCampId;
  if (!campId) return;
  _eventPaneCampId = campId;

  const titleEl = $('eventSlotsTitle');
  if (titleEl) titleEl.textContent = _eventPaneCampTitle || '';

  const body = $('eventSlotsBody');
  if (body) body.innerHTML = `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">불러오는 중…</td></tr>`;

  const [slots, counts] = await Promise.all([
    fetchEventSlots(campId),
    fetchEventSlotCounts(campId)
  ]);
  _eventSlotsCache = slots || [];
  _eventSlotCounts = counts || {};

  renderEventSlotsTable();
  renderEventSlotsSummary();
}

function renderEventSlotsSummary() {
  const el = $('eventSlotsSummary');
  if (!el) return;
  const rows = _eventSlotsCache;
  const totalCap = rows.reduce((s, r) => s + Number(r.capacity || 0), 0);
  const days = new Set(rows.map(r => String(r.slot_date).slice(0, 10))).size;
  const booked = Object.values(_eventSlotCounts).reduce((s, c) => s + Number(c.confirmed || 0), 0);
  el.innerHTML = `타임 <b>${rows.length}</b>줄 · ${days}일 · 정원 합계 <b>${totalCap.toLocaleString()}</b>명 · 확정 <b>${booked.toLocaleString()}</b>명`;
}

function renderEventSlotsTable() {
  const body = $('eventSlotsBody');
  if (!body) return;
  if (!_eventSlotsCache.length) {
    body.innerHTML = `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:30px">등록된 타임이 없습니다. 위 「하루치 일괄 생성」으로 한 번에 만들거나 「줄 추가」로 하나씩 넣으세요.</td></tr>`;
    return;
  }
  body.innerHTML = _eventSlotsCache.map(s => {
    const c = _eventSlotCounts[s.id] || {confirmed: 0, waitlist: 0, remaining: Number(s.capacity || 0)};
    const full = c.remaining <= 0;
    return `
      <tr data-slot-id="${s.id}">
        <td>${esc(String(s.slot_date).slice(0, 10))}</td>
        <td>${esc(fmtSlotTime(s))}</td>
        <td><input type="number" min="0" class="admin-filter" style="width:80px"
              value="${Number(s.capacity || 0)}" onchange="onEventSlotCapacityChange('${s.id}', this.value)"></td>
        <td>${esc(s.audience_label || '-')}</td>
        <td style="color:${full ? 'var(--pink)' : 'var(--ink)'}">
          ${c.confirmed}/${Number(s.capacity || 0)}${full ? ' <b>(마감)</b>' : ''}
        </td>
        <td>${c.waitlist ? c.waitlist + '명' : '-'}</td>
        <td style="white-space:nowrap">
          <button class="btn btn-ghost btn-sm" onclick="toggleEventSlotActive('${s.id}')">${s.is_active ? '사용 중' : '사용 안 함'}</button>
          <button class="btn btn-ghost btn-sm" onclick="deleteEventSlotRow('${s.id}')">삭제</button>
        </td>
      </tr>`;
  }).join('');
}

// 'HH:MM:SS' 를 'HH:MM' 으로 줄이고, 끝시각이 있으면 구간으로 표기한다.
function fmtSlotTime(s) {
  const st = String(s.start_time || '').slice(0, 5);
  const en = s.end_time ? String(s.end_time).slice(0, 5) : '';
  return en ? `${st}~${en}` : st;
}

async function onEventSlotCapacityChange(slotId, value) {
  const cap = parseInt(value, 10);
  if (!Number.isFinite(cap) || cap < 0) { toast('정원은 0 이상 숫자여야 합니다', 'error'); return; }
  try {
    await upsertEventSlot({id: slotId, capacity: cap});
    toast('정원을 저장했습니다');
    await renderEventSlotsPane(_eventPaneCampId);
  } catch (e) {
    console.error('[onEventSlotCapacityChange]', e);
    toast(friendlyError(e), 'error');
  }
}

async function toggleEventSlotActive(slotId) {
  const s = _eventSlotsCache.find(x => x.id === slotId);
  if (!s) return;
  try {
    await upsertEventSlot({id: slotId, is_active: !s.is_active});
    await renderEventSlotsPane(_eventPaneCampId);
  } catch (e) {
    console.error('[toggleEventSlotActive]', e);
    toast(friendlyError(e), 'error');
  }
}

async function deleteEventSlotRow(slotId) {
  const s = _eventSlotsCache.find(x => x.id === slotId);
  const c = _eventSlotCounts[slotId] || {confirmed: 0, waitlist: 0};
  const booked = Number(c.confirmed || 0) + Number(c.waitlist || 0);
  if (booked > 0) {
    // 서버도 막지만(마이그레이션 281 트리거) 여기서 이유를 먼저 설명한다.
    toast(`이 타임에 예약 ${booked}건이 있어 삭제할 수 없습니다. 모집만 닫으려면 「사용 안 함」으로 내려 주세요`, 'error');
    return;
  }
  const ok = await showConfirm(`${String(s?.slot_date || '').slice(0, 10)} ${fmtSlotTime(s || {})} 타임을 삭제할까요?`);
  if (!ok) return;
  try {
    await deleteEventSlot(slotId);
    toast('삭제했습니다');
    await renderEventSlotsPane(_eventPaneCampId);
  } catch (e) {
    console.error('[deleteEventSlotRow]', e);
    toast(friendlyError(e), 'error');
  }
}

// ── 줄 추가 (한 줄씩) ─────────────────────────────────────────
async function addEventSlotRow() {
  const date  = $('eventSlotNewDate')?.value || '';
  const start = $('eventSlotNewStart')?.value || '';
  const end   = $('eventSlotNewEnd')?.value || '';
  const cap   = parseInt($('eventSlotNewCapacity')?.value, 10);
  const label = $('eventSlotNewLabel')?.value || '';

  if (!date || !start) { toast('날짜와 시작 시각은 필수입니다', 'error'); return; }
  if (!Number.isFinite(cap) || cap < 0) { toast('정원을 숫자로 입력해 주세요', 'error'); return; }
  if (end && end <= start) { toast('종료 시각은 시작 시각보다 뒤여야 합니다', 'error'); return; }

  try {
    await upsertEventSlot({
      campaign_id: _eventPaneCampId,
      slot_date: date,
      start_time: start,
      end_time: end || null,
      capacity: cap,
      audience_label: label || null,
      sort_order: _eventSlotsCache.length
    });
    toast('타임을 추가했습니다');
    await renderEventSlotsPane(_eventPaneCampId);
  } catch (e) {
    console.error('[addEventSlotRow]', e);
    // 같은 날짜·같은 시작 시각이 이미 있으면 유일 제약(23505)에 걸린다.
    if (String(e?.code) === '23505') toast('같은 날짜·같은 시작 시각의 타임이 이미 있습니다', 'error');
    else toast(friendlyError(e), 'error');
  }
}

// ── 하루치 일괄 생성 ──────────────────────────────────────────
// 이틀차 16줄·삼일차 13줄을 손으로 넣지 않게 하는 보조 도구(사양서 §4-5).
// 「마지막 시작 시각」까지 포함해서 만든다 — 끝나는 시각이 아니라 **마지막 줄의 시작**이라
// 몇 줄이 나올지 운영자가 미리 셀 수 있다.
function buildBulkSlotTimes(startHHMM, lastStartHHMM, intervalMin, skipList) {
  const toMin = t => {
    const [h, m] = String(t).split(':').map(n => parseInt(n, 10));
    return h * 60 + m;
  };
  const pad = n => String(n).padStart(2, '0');
  const fromMin = v => `${pad(Math.floor(v / 60))}:${pad(v % 60)}`;

  const skip = new Set((skipList || '').split(',').map(s => s.trim()).filter(Boolean).map(s => s.slice(0, 5)));
  const out = [];
  const step = Math.max(1, Number(intervalMin) || 30);
  for (let v = toMin(startHHMM); v <= toMin(lastStartHHMM); v += step) {
    const t = fromMin(v);
    if (!skip.has(t)) out.push(t);
  }
  return out;
}

function previewBulkSlots() {
  const date  = $('eventBulkDate')?.value || '';
  const start = $('eventBulkStart')?.value || '';
  const last  = $('eventBulkLastStart')?.value || '';
  const step  = parseInt($('eventBulkInterval')?.value, 10) || 30;
  const skip  = $('eventBulkSkip')?.value || '';
  const el = $('eventBulkPreview');
  if (!el) return;
  if (!date || !start || !last || last < start) { el.textContent = ''; return; }
  const times = buildBulkSlotTimes(start, last, step, skip);
  el.innerHTML = times.length
    ? `<b>${times.length}줄</b>이 만들어집니다 — ${esc(times.join(', '))}`
    : '만들어질 줄이 없습니다. 시작·마지막 시각과 제외 시각을 확인해 주세요.';
}

async function bulkGenerateSlots(campaignId, opts) {
  const campId = campaignId || _eventPaneCampId;
  const o = opts || {
    date:     $('eventBulkDate')?.value || '',
    start:    $('eventBulkStart')?.value || '',
    lastStart:$('eventBulkLastStart')?.value || '',
    interval: parseInt($('eventBulkInterval')?.value, 10) || 30,
    skip:     $('eventBulkSkip')?.value || '',
    capacity: parseInt($('eventBulkCapacity')?.value, 10),
    label:    $('eventBulkLabel')?.value || '',
    durationMin: parseInt($('eventBulkDuration')?.value, 10) || 0
  };

  if (!campId) { toast('캠페인을 찾을 수 없습니다', 'error'); return; }
  if (!o.date || !o.start || !o.lastStart) { toast('날짜·시작 시각·마지막 시작 시각은 필수입니다', 'error'); return; }
  if (o.lastStart < o.start) { toast('마지막 시작 시각이 시작 시각보다 앞섭니다', 'error'); return; }
  if (!Number.isFinite(o.capacity) || o.capacity < 0) { toast('정원을 숫자로 입력해 주세요', 'error'); return; }

  const times = buildBulkSlotTimes(o.start, o.lastStart, o.interval, o.skip);
  if (!times.length) { toast('만들어질 타임이 없습니다', 'error'); return; }

  const ok = await showConfirm(
    `${o.date} 에 타임 ${times.length}줄을 만듭니다.\n` +
    `${times.join(', ')}\n\n정원은 각 ${o.capacity}명입니다. 계속할까요?`);
  if (!ok) return;

  const pad = n => String(n).padStart(2, '0');
  const addMin = (t, m) => {
    const [h, mm] = t.split(':').map(n => parseInt(n, 10));
    const v = h * 60 + mm + m;
    return `${pad(Math.floor(v / 60) % 24)}:${pad(v % 60)}`;
  };

  let made = 0, dup = 0, failed = 0;
  const base = _eventSlotsCache.length;
  for (let i = 0; i < times.length; i++) {
    try {
      await upsertEventSlot({
        campaign_id: campId,
        slot_date: o.date,
        start_time: times[i],
        end_time: o.durationMin > 0 ? addMin(times[i], o.durationMin) : null,
        capacity: o.capacity,
        audience_label: o.label || null,
        sort_order: base + i
      });
      made++;
    } catch (e) {
      // 이미 있는 줄은 건너뛴다 — 같은 버튼을 두 번 눌러도 중복이 안 생긴다.
      if (String(e?.code) === '23505') dup++;
      else { failed++; console.error('[bulkGenerateSlots]', times[i], e); }
    }
  }

  let msg = `${made}줄을 만들었습니다`;
  if (dup)    msg += ` · 이미 있던 ${dup}줄은 건너뜀`;
  if (failed) msg += ` · ${failed}줄 실패`;
  toast(msg, failed ? 'error' : 'success');
  await renderEventSlotsPane(campId);
}

// ══════════════════════════════════════════════════════════════
// ③ 예약 현황 페인
// ══════════════════════════════════════════════════════════════

async function openEventTicketsPane(campId, campTitle) {
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  _eventPaneCampId = campId;
  _eventPaneCampTitle = campTitle || '';
  _eventTicketSlotFilter = '';
  _eventTicketStatusTab = '';
  switchAdminPane('event-tickets', null, true);
  await renderEventTicketsPane(campId);
}

async function renderEventTicketsPane(campaignId) {
  const campId = campaignId || _eventPaneCampId;
  if (!campId) return;
  _eventPaneCampId = campId;

  const titleEl = $('eventTicketsTitle');
  if (titleEl) titleEl.textContent = _eventPaneCampTitle || '';

  const body = $('eventTicketsBody');
  if (body) body.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:24px">불러오는 중…</td></tr>`;

  const [slots, tickets] = await Promise.all([
    fetchEventSlots(campId),
    fetchEventTicketsByCampaign(campId)
  ]);
  _eventSlotsCache = slots || [];
  _eventTicketsCache = tickets || [];

  renderEventTicketSlotFilter();
  renderEventTicketStatusTabs();
  renderEventTicketsSummary();
  renderEventTicketsTable();
}

// 티켓 1건의 화면 상태 — 예약 상태와 입장 여부를 합쳐 사람이 읽는 말로 만든다.
function eventTicketViewStatus(t) {
  if (t.status === 'cancelled') return 'cancelled';
  if (t.status === 'waitlist')  return 'waitlist';
  return t.entered_at ? 'entered' : 'noshow';   // 확정인데 입장 전 = 아직 안 옴
}

function eventTicketStatusLabel(key) {
  return ({
    confirmed: '확정',
    waitlist:  '대기',
    entered:   '입장 완료',
    noshow:    '미입장',
    cancelled: '취소'
  })[key] || key;
}

function filteredEventTickets() {
  return _eventTicketsCache.filter(t => {
    if (_eventTicketSlotFilter && t.slot_id !== _eventTicketSlotFilter) return false;
    if (!_eventTicketStatusTab) return true;
    const v = eventTicketViewStatus(t);
    if (_eventTicketStatusTab === 'confirmed') return t.status === 'confirmed';
    return v === _eventTicketStatusTab;
  });
}

function renderEventTicketSlotFilter() {
  const sel = $('eventTicketSlotFilter');
  if (!sel) return;
  sel.innerHTML = `<option value="">전체 타임</option>` + _eventSlotsCache.map(s =>
    `<option value="${s.id}"${_eventTicketSlotFilter === s.id ? ' selected' : ''}>${esc(String(s.slot_date).slice(0, 10))} ${esc(fmtSlotTime(s))}</option>`
  ).join('');
}

function onEventTicketSlotFilterChange(v) {
  _eventTicketSlotFilter = v || '';
  renderEventTicketStatusTabs();
  renderEventTicketsSummary();
  renderEventTicketsTable();
}

function renderEventTicketStatusTabs() {
  const bar = $('eventTicketStatusTabs');
  if (!bar) return;
  // 건수는 타임 필터를 적용한 뒤 센다 — 탭 숫자와 목록 길이가 어긋나지 않게.
  const pool = _eventTicketsCache.filter(t => !_eventTicketSlotFilter || t.slot_id === _eventTicketSlotFilter);
  bar.innerHTML = EVENT_TICKET_STATUS_TABS.map(tab => {
    const n = tab.key === ''
      ? pool.length
      : pool.filter(t => tab.key === 'confirmed' ? t.status === 'confirmed' : eventTicketViewStatus(t) === tab.key).length;
    const cls = 'status-tab-btn' + (_eventTicketStatusTab === tab.key ? ' on' : '')
      + (n === 0 && tab.key !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" onclick="onEventTicketStatusTab('${tab.key}')">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

function onEventTicketStatusTab(key) {
  _eventTicketStatusTab = key || '';
  renderEventTicketStatusTabs();
  renderEventTicketsTable();
}

function renderEventTicketsSummary() {
  const el = $('eventTicketsSummary');
  if (!el) return;
  const pool = _eventTicketsCache.filter(t => !_eventTicketSlotFilter || t.slot_id === _eventTicketSlotFilter);
  const confirmed = pool.filter(t => t.status === 'confirmed').length;
  const entered   = pool.filter(t => t.status === 'confirmed' && t.entered_at).length;
  const waitlist  = pool.filter(t => t.status === 'waitlist').length;
  const cancelled = pool.filter(t => t.status === 'cancelled').length;
  const noshow    = confirmed - entered;
  const rate = confirmed ? Math.round(entered / confirmed * 100) : 0;
  el.innerHTML =
    `확정 <b>${confirmed}</b>명 · 입장 <b>${entered}</b>명(${rate}%) · 미입장 <b>${noshow}</b>명 · 대기 <b>${waitlist}</b>명 · 취소 ${cancelled}명`;
}

function renderEventTicketsTable() {
  const body = $('eventTicketsBody');
  if (!body) return;
  const rows = filteredEventTickets();
  if (!rows.length) {
    body.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">해당하는 예약이 없습니다.</td></tr>`;
    return;
  }
  body.innerHTML = rows.map(t => {
    const s = t.event_slots || {};
    const inf = t.influencers || {};
    const v = eventTicketViewStatus(t);
    const badgeColor = ({entered: '#16A34A', noshow: 'var(--muted)', waitlist: '#D97706', cancelled: '#DC2626'})[v] || 'var(--ink)';
    const audit = (typeof auditBadgeHtml === 'function') ? auditBadgeHtml(inf) : '';
    const canCheckIn = (t.status === 'confirmed' && !t.entered_at);
    return `
      <tr>
        <td>${esc(String(s.slot_date || '').slice(0, 10))}</td>
        <td>${esc(fmtSlotTime(s))}</td>
        <td>${esc(inf.name_kanji || '-')}${audit}<div style="font-size:11px;color:var(--muted)">${esc(inf.name_kana || '')}</div></td>
        <td style="font-family:monospace">${esc(t.ticket_code)}</td>
        <td style="color:${badgeColor};font-weight:700">
          ${eventTicketStatusLabel(v)}${t.status === 'waitlist' && t.waitlist_position ? ` ${t.waitlist_position}번` : ''}
        </td>
        <td>${t.entered_at ? esc(formatDateTime(t.entered_at)) : '-'}</td>
        <td>${esc(t.entered_by_name || '')}${t.scan_count > 1 ? `<div style="font-size:11px;color:var(--muted)">확인 ${t.scan_count}회</div>` : ''}</td>
        <td>${canCheckIn
              ? `<button class="btn btn-ghost btn-sm" onclick="checkInFromAdmin('${esc(t.ticket_code)}')">입장 처리</button>`
              : '-'}</td>
      </tr>`;
  }).join('');
}

// 관리자 화면의 「입장 처리」 — 현장 확인 페이지(작업 7)와 **같은** 서버 함수를 쓴다.
// 그래서 첫 입장 시각 보존·중복 감지가 두 경로에서 똑같이 동작한다.
// 쓰임새: 행사장 인터넷이 끊겨 종이 명단으로 대조한 뒤, 복구되면 손으로 반영하는 경로(사양서 §2-8 U1).
async function checkInFromAdmin(ticketCode) {
  try {
    const res = await checkInTicket(ticketCode);
    if (!res?.ok) {
      toast(eventCheckInFailMessage(res?.reason), 'error');
      return;
    }
    if (res.already_entered) {
      toast(`이미 입장 처리된 예약입니다 (첫 입장 ${formatDateTime(res.entered_at)})`, 'error');
    } else {
      toast(`${res.name_kanji || ''} 입장 처리했습니다`);
    }
    await renderEventTicketsPane(_eventPaneCampId);
  } catch (e) {
    console.error('[checkInFromAdmin]', e);
    toast(friendlyError(e), 'error');
  }
}

// 입장 확인 실패 사유를 관리자용 한국어로 바꾼다.
// ⚠️ 현장 확인 페이지(작업 7)는 이 파일을 못 쓰므로 같은 문구를 그 파일에도 둔다.
function eventCheckInFailMessage(reason) {
  return ({
    not_found:             '없는 예약번호입니다',
    cancelled:             '취소된 예약입니다',
    waitlist_cannot_enter: '대기 상태라 입장할 수 없습니다',
    permission_denied:     '권한이 없습니다'
  })[reason] || '확인하지 못했습니다';
}
