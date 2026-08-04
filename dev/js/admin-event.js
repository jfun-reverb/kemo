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
let _eventSlotDateTab = '';                 // 「행사 시간」 날짜 탭('' = 전체)
let _eventSlotsLoadedFor = null;            // 시간대 목록을 마지막으로 채운 캠페인
const _eventSlotSelected = new Set();       // 선택 삭제로 고른 타임
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
  // ⚠️ 아래 리워드 잠금·안내는 **행사 모드에서는 화면에 안 보인다** — 리워드 묶음
  //    전체를 applyEventModeFieldVisibility 가 숨기기 때문. 그래도 지우지 않는다:
  //    행사 모드를 **끄는** 경로에서 readOnly 를 풀어 주는 일을 이 코드가 한다.
  const rewardHint = $(prefix + 'CampRewardEventHint');
  if (rewardHint) rewardHint.style.display = on ? '' : 'none';
  const rewardNote = $(prefix + 'CampRewardLockNote');
  if (rewardNote) rewardNote.style.display = on ? '' : 'none';

  // 모집 형식 라디오 — 행사 모드면 방문형으로 고정하고 나머지를 잠근다.
  //   ⚠️ 라디오 name 이 폼마다 다르다: 신규는 recruitType, 편집은 editRecruitType.
  //      `${prefix}RecruitType` 로 쓰면 신규 폼에서 아무것도 안 잡힌다.
  const rtName = (prefix === 'edit') ? 'editRecruitType' : 'recruitType';

  // ★ 켜기 직전 형식을 **라디오를 건드리기 전에** 기억한다.
  //   아래 반복문이 방문형으로 바꾼 뒤에 읽으면 「방문형」이 기억되고, 끌 때
  //   되돌릴 값이 방문형이라 아무 일도 안 일어난다 — 실제로 그랬다(2026-08-03 QA 실측).
  if (on && _recruitTypeBeforeEvent[prefix] == null) {
    _recruitTypeBeforeEvent[prefix] = _currentRecruitType(prefix);
  }
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
  if (!on && _recruitTypeBeforeEvent[prefix] != null) {
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
  applyEventModeFieldVisibility(prefix);
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
  // ★ 「행사 모드를 켜기 직전의 모집 형식」 기억을 **캠페인마다 비운다.**
  //   이 값은 모듈 전역이라, 캠페인 A 에서 행사 모드를 켠 뒤 비우지 않고 나가면
  //   다음에 연 캠페인 B 의 라디오가 **A 의 옛 형식으로 조용히 바뀐다.** 그러면
  //   B 의 방문 기간이 비워지고 콘텐츠 종류 일부가 사라진 채 저장된다
  //   (2026-08-03 점검에서 발견 — 확인창도 없어 알아채기 어렵다).
  //   비우는 자리는 여기다: 편집 폼에 캠페인이 실리는 유일한 길목.
  _recruitTypeBeforeEvent.edit = null;

  const em = $('editCampEventMode');
  const io = $('editCampInviteOnly');
  if (em) em.checked = !!camp?.event_mode;
  if (io) io.checked = !!camp?.is_invite_only;
  const pl = $('editCampEventPlace');
  if (pl) pl.value = camp?.event_place || '';
  applyEventModeFormLock('edit');
  applyEventModeFieldVisibility('edit');
  applyInviteOnlyRow('edit');

  const warnEl = $('editCampInviteWarn');
  if (warnEl) warnEl.style.display = 'none';

  // 시간대 구역의 표시·목록 불러오기는 위 applyEventModeFieldVisibility 가 이미
  // editCampId 기준으로 처리했다. 여기서 또 부르면 같은 조회가 두 번 날아가고,
  // 늦게 도착한 쪽이 화면을 덮는 경쟁이 생긴다. 제목만 맞춰 둔다.
  if (camp?.event_mode) _eventPaneCampTitle = camp.title || '';

  // 날짜 규칙(달력 경계·인라인 경고)은 「행사인가」에 따라 달라지는데, openEditCampaign 이
  // 그것을 계산하는 시점엔 위 체크박스가 아직 안 채워져 있다 — 직전에 보던 캠페인의
  // 행사 여부로 계산돼 방문 기간 달력이 엉뚱하게 잠기거나 경고가 잘못 뜬다.
  // 체크박스가 확정된 지금 다시 맞춘다.
  if (typeof syncCampDateMinMax === 'function') syncCampDateMinMax('editCamp');
  if (typeof validateCampDateRangesInline === 'function') validateCampDateRangesInline('editCamp');

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
  applyEventModeFieldVisibility(prefix);
  applyInviteOnlyRow(prefix);
}

// ══════════════════════════════════════════════════════════════
// ② 타임(시간대) 관리 페인
// ══════════════════════════════════════════════════════════════

// 시간대 관리는 **캠페인 편집 화면 안**에 있다(사용자 요청 2026-08-03 — 더보기 메뉴 진입 폐지).
//   시간대는 그 캠페인에 속한 설정이라 캠페인을 고쳐 쓰는 자리에 함께 있는 것이 자연스럽다.
//   ⚠️ 신규 등록 화면에는 없다 — 시간대는 캠페인 식별자가 있어야 붙일 수 있어서,
//      저장 전에는 걸 곳이 없다. 신규 폼에는 그렇게 안내만 띄운다.
async function renderEventSlotsPane(campaignId) {
  const campId = campaignId || _eventPaneCampId;
  if (!campId) return;
  // 이 함수는 정원 수정·타임 추가·삭제·일괄 생성 **뒤에도** 불린다. 접기를 무조건
  //   실행하면 하루치를 만들자마자 패널이 닫혀, 이틀차·삼일차를 만들려면 매번 다시
  //   펼쳐야 한다. 「캠페인이 바뀌었을 때」만 접는다.
  const _isOtherCampaign = (campId !== _eventSlotsLoadedFor);
  _eventSlotsLoadedFor = campId;
  _eventPaneCampId = campId;

  // 읽어 오기 전에 먼저 비운다 — 안 비우면 조회가 끝나기 전까지 **직전에 보던
  //   캠페인의 시간대**가 남아, 미리보기와 모집 인원이 그 값으로 한 번 그려진다.
  _eventSlotsCache = [];
  _eventSlotCounts = {};

  const body = $('eventSlotsBody');
  if (body) body.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:24px">불러오는 중…</td></tr>`;

  const [slots, counts] = await Promise.all([
    fetchEventSlots(campId),
    fetchEventSlotCounts(campId)
  ]);
  _eventSlotsCache = slots || [];
  _eventSlotCounts = counts || {};

  setupEventSlotPickers();      // 날짜·시각 선택기(한 번만 붙는다)
  _eventSlotSelected.clear();   // 목록이 바뀌었으니 고른 것도 무효다
  if (_isOtherCampaign) toggleEventBulkPanel(false);   // 새 캠페인은 접은 채로 시작
  renderEventSlotDateTabs();
  renderEventSlotsTable();
  renderEventSlotsSummary();
  syncEventDerivedFields();
}

// 행사 캠페인에서 「방문 기간」·「모집 인원」은 따로 입력할 값이 아니라 **행사 시간에서 나오는 값**이다.
//   예전엔 셋이 따로 놀아서, 방문 기간을 9월로 적어 두고 시간대는 8월에 만들면 방문객 화면에
//   서로 다른 두 날짜가 나란히 떴고, 「모집 인원 20명」인데 실제 정원은 270명인 일이 생겼다.
//   (예약 정원 판정은 서버에서 event_slots.capacity 로만 한다 — campaigns.slots 는 아예 안 본다.)
//   그래서 화면에서는 잠그고, 저장할 때 시간대에서 다시 계산한다(saveCampaignEdit).
//   ⚠️ 시간대가 0줄이면 잠그지 않는다 — 계산할 근거가 없는데 잠그면 아무 값도 못 넣게 된다.
function eventDerivedFromSlots(rows) {
  const list = (rows || []).filter(r => r && r.slot_date);
  if (!list.length) return null;
  const dates = list.map(r => String(r.slot_date).slice(0, 10)).sort();
  return {
    visit_start: dates[0],
    visit_end:   dates[dates.length - 1],
    slots:       list.reduce((n, r) => n + Number(r.capacity || 0), 0)
  };
}

function syncEventDerivedFields() {
  const slotsEl = $('editCampSlots');
  if (!slotsEl) return;
  const on = (typeof isEventModeForm === 'function') && isEventModeForm('edit');
  const d = on ? eventDerivedFromSlots(_eventSlotsCache) : null;
  const hint = $('editCampSlotsEventHint');
  if (d) {
    slotsEl.value = d.slots;
    slotsEl.readOnly = true;
    slotsEl.classList.add('field-locked');
    if (hint) {
      hint.style.display = '';
      hint.textContent = `행사 시간의 정원 합계입니다 (${d.visit_start} ~ ${d.visit_end}). 인원을 바꾸려면 아래 「행사 시간」에서 정원을 고치세요.`;
    }
  } else {
    slotsEl.readOnly = false;
    slotsEl.classList.remove('field-locked');
    if (hint) hint.style.display = 'none';
  }
  // ⚠️ 미리보기는 사람이 칸을 칠 때(input 사건)만 다시 그린다. 코드가 `.value` 를
  //    바꾸는 건 그 사건을 일으키지 않아, 미리보기에 **저장돼 있던 옛 인원**이 그대로
  //    남는다(실제로 화면 115명 · 미리보기 1440명이 나왔다). 직접 다시 그리게 한다.
  if (typeof renderCampPreview === 'function') renderCampPreview('edit');
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

// 행사 시간의 날짜·시각 칸을 이 화면 나머지와 같은 선택기(flatpickr)로 바꾼다.
//   브라우저 기본 달력·시계는 운영체제마다 생김새가 달라 관리자 화면 안에서 혼자 튄다.
//   ⚠️ 값의 형태는 그대로 둔다 — 날짜 `YYYY-MM-DD`, 시각 `HH:MM`. 읽는 쪽(미리 보기·
//      일괄 생성·타임 추가)이 문자열 비교를 하고 있어 형태가 바뀌면 조용히 깨진다.
const _eventFp = Object.create(null);

function setupEventSlotPickers() {
  if (typeof flatpickr === 'undefined') return;   // CDN 실패 시 그냥 텍스트 칸으로 남는다
  const loc = (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default';
  document.querySelectorAll('.evt-fp-date').forEach(el => {
    if (!el.id || _eventFp[el.id]) return;
    _eventFp[el.id] = flatpickr(el, {
      dateFormat: 'Y-m-d', locale: loc, altInput: false,
      appendTo: document.body, position: 'auto', disableMobile: true,
      // ⚠️ 핑크 테마 규칙이 **두 클래스를 함께** 요구한다(admin.css). 하나만 붙이면
      //    기본 파란 달력이 떠서, 바로 위 「결과물 제출 마감일」 달력과 색이 달라진다.
      onReady: (_d, _s, fp) => { if (fp.calendarContainer) fp.calendarContainer.classList.add('reverb-range-cal', 'reverb-single-cal'); },
      onChange: () => { if (typeof previewBulkSlots === 'function') previewBulkSlots(); }
    });
  });
  document.querySelectorAll('.evt-fp-time').forEach(el => {
    if (!el.id || _eventFp[el.id]) return;
    _eventFp[el.id] = flatpickr(el, {
      noCalendar: true, enableTime: true, time_24hr: true, dateFormat: 'H:i',
      minuteIncrement: 5, locale: loc, altInput: false,
      appendTo: document.body, position: 'auto', disableMobile: true,
      // 빈 칸을 열면 0시가 떠서, **종료** 시각으로는 늘 「시작보다 이른 값」이 된다.
      //   시작 칸에는 걸지 않는다 — 0시는 이상해 보여 알아채지만, 12시는 그럴듯해서
      //   고르지도 않은 값이 그대로 저장될 수 있다.
      ...(el.id === 'eventSlotNewEnd' ? {defaultHour: 12, defaultMinute: 0} : {}),
      defaultDate: el.value || null,
      // 시각 선택기는 이 프로젝트에 선례가 없어 강조색이 기본 파랑이다 — 전용 클래스를
      // 붙여 달력과 같은 핑크로 맞춘다(규칙은 admin.css 「evt-time-cal」).
      onReady: (_d, _s, fp) => { if (fp.calendarContainer) fp.calendarContainer.classList.add('evt-time-cal'); },
      onChange: () => {
        syncEventTimeClearBtns();
        if (typeof previewBulkSlots === 'function') previewBulkSlots();
      }
    });
  });
  syncEventTimeClearBtns();   // 붙인 직후 현재 값 기준으로 한 번
}

// 시각 칸 비우기 — 시각 선택기는 **열기만 해도** 값을 채운다. 「종료(선택)」에서는 그 값이
//   시작보다 이르면 「종료 시각은 시작 시각보다 뒤여야 합니다」로 막히는데 되돌릴 길이
//   없었다(2026-08-04 사용자 지적). 시작 칸도 마찬가지로, 잘못 열려 박힌 값을 지울
//   수단이 있어야 한다 — 그쪽은 오히려 그럴듯한 시각이라 그대로 저장될 위험이 크다.
function clearEventTimeField(id) {
  const fp = _eventFp[id];
  if (fp) fp.clear();          // 입력칸 값까지 함께 비운다(4.6.13)
  const el = $(id);            // 선택기가 아직 안 붙은 경우의 대비
  if (el) el.value = '';
  syncEventTimeClearBtns();
}

// 비우기 단추는 **값이 있을 때만** 보인다. 빈 칸 옆에 늘 떠 있으면 무슨 표시인지
//   알 수 없고(칸 사이에 낀 곱하기처럼 읽힌다), 지울 것도 없는데 자리만 차지한다.
function syncEventTimeClearBtns() {
  document.querySelectorAll('.evt-time-clearable').forEach(wrap => {
    const input = wrap.querySelector('input');
    wrap.classList.toggle('has-value', !!(input && input.value));
  });
}

// 「하루치 일괄 생성」 입력 항목 설명 — 제목 옆 물음표로만 연다.
function toggleEventBulkHelp() {
  const el = $('eventBulkHelp');
  if (el) el.style.display = (el.style.display === 'none') ? '' : 'none';
}

// 「하루치 일괄 생성」 펼치기·접기. 처음 만들 때만 쓰는 도구라 평소엔 접어 둔다.
function toggleEventBulkPanel(force) {
  const panel = $('eventBulkPanel');
  const btn = $('eventBulkToggleBtn');
  if (!panel) return;
  const open = (force === undefined) ? (panel.style.display === 'none') : !!force;
  panel.style.display = open ? '' : 'none';
  if (!open) { const help = $('eventBulkHelp'); if (help) help.style.display = 'none'; }
  const icon = btn && btn.querySelector('.material-icons-round');
  if (icon) icon.textContent = open ? 'expand_less' : 'expand_more';
  if (open && typeof previewBulkSlots === 'function') previewBulkSlots();
}

// 지금 표에 그릴 타임 — 날짜 탭이 골라져 있으면 그 날짜만.
function visibleEventSlots() {
  if (!_eventSlotDateTab) return _eventSlotsCache;
  return _eventSlotsCache.filter(s => String(s.slot_date).slice(0, 10) === _eventSlotDateTab);
}

// 날짜 탭 — 하루짜리 행사에는 그리지 않는다(고를 게 없는 탭은 자리만 차지한다).
function renderEventSlotDateTabs() {
  const el = $('eventSlotDateTabs');
  if (!el) return;
  const dates = [...new Set(_eventSlotsCache.map(s => String(s.slot_date).slice(0, 10)))].sort();
  if (dates.length <= 1) {
    el.style.display = 'none';
    _eventSlotDateTab = '';
    return;
  }
  // 골라 둔 날짜의 타임이 전부 지워졌으면 전체로 되돌린다 — 안 그러면 빈 표가 남는다.
  if (_eventSlotDateTab && !dates.includes(_eventSlotDateTab)) _eventSlotDateTab = '';
  // ⚠️ 클래스 이름은 바로 아래 예약 현황 탭(renderEventTicketStatusTabs)과 같아야 한다.
  //    다른 이름을 쓰면 정의된 스타일이 하나도 안 붙어 맨 버튼으로 그려진다.
  const tab = (key, label, n) =>
    `<button type="button" class="status-tab-btn${_eventSlotDateTab === key ? ' on' : ''}${n === 0 && key !== '' ? ' zero-count' : ''}" onclick="setEventSlotDateTab('${esc(key)}')">${esc(label)}<span class="tab-count">(${n})</span></button>`;
  el.style.display = '';
  el.innerHTML = tab('', '전체', _eventSlotsCache.length)
    + dates.map(d => tab(d, d.replace(/-/g, '/').slice(5), _eventSlotsCache.filter(s => String(s.slot_date).slice(0, 10) === d).length)).join('');
}

function setEventSlotDateTab(key) {
  _eventSlotDateTab = key || '';
  // 안 보이는 줄을 고른 채로 두면 「3개 선택」인데 표에는 하나도 없는 상태가 된다.
  clearEventSlotSelection();
  renderEventSlotDateTabs();
  renderEventSlotsTable();
}

function renderEventSlotsTable() {
  const body = $('eventSlotsBody');
  if (!body) return;
  if (!_eventSlotsCache.length) {
    body.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">등록된 타임이 없습니다. 위 「하루치 일괄 생성」으로 한 번에 만들거나 「타임 추가」로 하나씩 넣으세요.</td></tr>`;
    syncEventSlotBulkBar();
    return;
  }
  body.innerHTML = visibleEventSlots().map(s => {
    const c = _eventSlotCounts[s.id] || {confirmed: 0, waitlist: 0, remaining: Number(s.capacity || 0)};
    const full = c.remaining <= 0;
    const booked = Number(c.confirmed || 0) + Number(c.waitlist || 0);
    return `
      <tr data-slot-id="${s.id}">
        <td style="text-align:center;padding:4px">${booked > 0
          ? `<span class="material-icons-round notranslate" translate="no" style="font-size:16px;color:var(--muted)" title="예약 ${booked}건이 있어 삭제할 수 없습니다">lock</span>`
          : `<input type="checkbox" class="event-slot-cb" data-slot-id="${s.id}" ${_eventSlotSelected.has(s.id) ? 'checked' : ''} onchange="toggleEventSlotSelect('${s.id}', this.checked)">`}</td>
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
  syncEventSlotBulkBar();
}

// ── 선택 삭제 ─────────────────────────────────────────────────
//   예약이 걸린 타임은 애초에 고를 수 없다(체크박스 대신 자물쇠). 서버도 막지만
//   (마이그레이션 281 트리거) 고르게 해 놓고 나중에 거절하면 왜 안 되는지 알기 어렵다.
function selectableEventSlots() {
  return visibleEventSlots().filter(s => {
    const c = _eventSlotCounts[s.id] || {};
    return (Number(c.confirmed || 0) + Number(c.waitlist || 0)) === 0;
  });
}

function toggleEventSlotSelect(slotId, checked) {
  if (checked) _eventSlotSelected.add(slotId); else _eventSlotSelected.delete(slotId);
  syncEventSlotBulkBar();
}

function toggleEventSlotSelectAll(checked) {
  const ids = selectableEventSlots().map(s => s.id);
  ids.forEach(id => { if (checked) _eventSlotSelected.add(id); else _eventSlotSelected.delete(id); });
  document.querySelectorAll('.event-slot-cb').forEach(cb => {
    if (ids.includes(cb.dataset.slotId)) cb.checked = !!checked;
  });
  syncEventSlotBulkBar();
}

function clearEventSlotSelection() {
  _eventSlotSelected.clear();
  document.querySelectorAll('.event-slot-cb').forEach(cb => { cb.checked = false; });
  const all = $('eventSlotSelectAll');
  if (all) { all.checked = false; all.indeterminate = false; }
  syncEventSlotBulkBar();
}

function syncEventSlotBulkBar() {
  const bar = $('eventSlotBulkBar');
  const cnt = $('eventSlotBulkCount');
  const n = _eventSlotSelected.size;
  if (bar) bar.style.display = n ? 'flex' : 'none';
  if (cnt) cnt.textContent = `${n}개 선택`;
  const all = $('eventSlotSelectAll');
  if (all) {
    const total = selectableEventSlots().length;
    all.checked = total > 0 && n >= total;
    all.indeterminate = n > 0 && n < total;
  }
}

async function deleteSelectedEventSlots() {
  const ids = [..._eventSlotSelected];
  if (!ids.length) { toast('삭제할 타임을 골라 주세요', 'error'); return; }
  const rows = ids.map(id => _eventSlotsCache.find(s => s.id === id)).filter(Boolean);
  const dates = [...new Set(rows.map(r => String(r.slot_date).slice(0, 10)))].sort();
  const ok = await showConfirm(
    `고른 타임 ${ids.length}개를 삭제할까요?\n\n` +
    `${dates.join(', ')}\n\n` +
    `되돌릴 수 없습니다. 모집만 닫으려면 「사용 안 함」으로 내려 주세요.`,
    '삭제');
  if (!ok) return;
  // 한 건씩 지운다 — 하나가 실패해도 나머지는 지워지고, 실패한 것만 알려 준다.
  const failed = [];
  for (const id of ids) {
    try { await deleteEventSlot(id); }
    catch (e) { console.error('[deleteSelectedEventSlots]', id, e); failed.push(id); }
  }
  _eventSlotSelected.clear();
  toast(failed.length
    ? `${ids.length - failed.length}개를 삭제했습니다. ${failed.length}개는 실패했습니다`
    : `${ids.length}개를 삭제했습니다`, failed.length ? 'error' : 'success');
  await renderEventSlotsPane(_eventPaneCampId);
}

// 'HH:MM:SS' 를 'HH:MM' 으로 줄이고, 끝시각이 있으면 구간으로 표기한다.
function fmtSlotTime(s) {
  const st = String(s.start_time || '').slice(0, 5);
  const en = s.end_time ? String(s.end_time).slice(0, 5) : '';
  if (!en) return st;
  // 끝 시각이 시작보다 이르면 자정을 넘긴 것이다. 표에 「23:30~00:30」 으로만 적으면
  // 거꾸로 적힌 것처럼 보인다 — 일괄 생성 미리 보기와 같은 말로 맞춘다.
  //   (표에 넣을 날짜 칸이 따로 없어 시각 문자열로만 구분한다)
  return en < st ? `${st}~익일 ${en}` : `${st}~${en}`;
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

// ── 타임 추가 (한 줄씩) ───────────────────────────────────────
async function addEventSlotRow() {
  const date  = $('eventSlotNewDate')?.value || '';
  const start = $('eventSlotNewStart')?.value || '';
  const end   = $('eventSlotNewEnd')?.value || '';
  const cap   = parseInt($('eventSlotNewCapacity')?.value, 10);
  const label = $('eventSlotNewLabel')?.value || '';

  if (!date || !start) { toast('날짜와 시작 시각은 필수입니다', 'error'); return; }
  if (!Number.isFinite(cap) || cap < 0) { toast('정원을 숫자로 입력해 주세요', 'error'); return; }
  if (end && end <= start) { toast('종료 시각은 시작 시각보다 뒤여야 합니다. 안 쓸 거면 옆 「비우기」 버튼을 눌러 주세요', 'error'); return; }

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
  // ⚠️ 날짜를 미리 보기의 조건으로 삼지 않는다. 몇 시에 몇 줄이 나오는지는 날짜와
  //    아무 상관이 없는데, 예전엔 날짜가 비면 목록이 통째로 사라져 「입력해도 아무것도
  //    안 나온다」로 보였다(2026-08-04 사용자 지적). 날짜는 실제로 만들 때만 필요하다.
  if (!start || !last) { el.textContent = ''; return; }
  if (last < start) {
    el.innerHTML = '<span style="color:var(--red-d)">「마지막 시작 시각」이 「시작 시각」보다 이릅니다.</span>';
    return;
  }
  const dur = parseInt($('eventBulkDuration')?.value, 10) || 0;
  const times = buildBulkSlotTimes(start, last, step, skip);
  // 길이를 넣었으면 끝 시각까지 보여 준다 — 겹치는지 눈으로 알 수 있어야 한다.
  const label = t => {
    if (!dur) return t;
    const [h, m] = t.split(':').map(n => parseInt(n, 10));
    const v = h * 60 + m + dur;
    const end = `${String(Math.floor(v / 60) % 24).padStart(2, '0')}:${String(v % 60).padStart(2, '0')}`;
    return v >= 24 * 60 ? `${t}~익일 ${end}` : `${t}~${end}`;   // 자정을 넘기면 그렇다고 적는다
  };
  const overlap = dur > 0 && dur > step
    ? `<div style="margin-top:4px;color:var(--gold)">한 타임 길이(${dur}분)가 간격(${step}분)보다 길어 타임끼리 시간이 겹칩니다.</div>` : '';
  // 날짜가 비어 있으면 목록은 그대로 보여 주되, 만들려면 날짜가 필요하다고 알린다.
  //   ⚠️ 이때 첫 문장을 「만들어집니다」로 두면, 바로 아래 「고르면 만들어집니다」와
  //      부딪혀 지금 만들어지는 건지 아닌지를 두 번 읽게 된다. 시제를 갈라 둔다.
  const needDate = date ? ''
    : '<div style="margin-top:4px;color:var(--gold)">「날짜」를 고르면 이대로 만들어집니다.</div>';
  const lead = date ? `<b>${times.length}줄</b>이 만들어집니다` : `<b>${times.length}줄</b>`;
  el.innerHTML = times.length
    ? `${lead} — ${esc(times.map(label).join(', '))}${overlap}${needDate}`
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

// 예약 현황은 이제 **캠페인 진행현황 화면의 탭**이다(사용자 요청 2026-08-04).
//   별도 화면이던 시절의 호출부가 남아 있어도 같은 자리로 가도록 남겨 둔다.
async function openEventTicketsPane(campId, campTitle) {
  document.querySelectorAll('.camp-more-menu').forEach(d => d.remove());
  _eventTicketSlotFilter = '';
  _eventTicketStatusTab = '';
  if (typeof openCampApplicants === 'function') {
    await openCampApplicants(campId, campTitle || '');
    if (typeof setCampDetailTabByCode === 'function') setCampDetailTabByCode('tickets');
  }
}

async function renderEventTicketsPane(campaignId) {
  const campId = campaignId || _eventPaneCampId;
  if (!campId) return;
  _eventPaneCampId = campId;

  // 제목은 진행현황 헤더(campApplicantsTitle)가 이미 보여 준다 — 여기서 또 그리지 않는다.
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

// 예약 수치 계산 — 진행현황 요약 카드(campOpsStatusCard)와 **같은 판정**을 쓰려고
//   숫자만 따로 돌려주는 함수로 나눴다. 두 곳이 각자 세면 값이 갈린다.
function eventTicketCounts(slotFilter) {
  const f = (slotFilter === undefined) ? _eventTicketSlotFilter : slotFilter;
  const pool = _eventTicketsCache.filter(t => !f || t.slot_id === f);
  const confirmed = pool.filter(t => t.status === 'confirmed').length;
  const entered   = pool.filter(t => t.status === 'confirmed' && t.entered_at).length;
  return {
    confirmed, entered,
    waitlist:  pool.filter(t => t.status === 'waitlist').length,
    cancelled: pool.filter(t => t.status === 'cancelled').length,
    noshow:    confirmed - entered
  };
}

function renderEventTicketsSummary() {
  const el = $('eventTicketsSummary');
  if (!el) return;      // 진행현황 안으로 옮긴 뒤로는 이 자리가 없다 — 요약 카드가 대신 그린다
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
    // 「시간대를 아직 안 만들었다」와 「시간대는 있는데 예약이 0건이다」는 할 일이 다르다.
    const msg = !_eventSlotsCache.length
      ? '행사 시간이 아직 없습니다. 「편집」에서 모집 조건의 <b>행사 시간</b>을 먼저 등록해 주세요.'
      : (_eventTicketSlotFilter || _eventTicketStatusTab)
        ? '조건에 맞는 예약이 없습니다.'
        : '아직 예약이 없습니다.';
    body.innerHTML = `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">${msg}</td></tr>`;
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
async function checkInFromAdmin(ticketCode, confirmOtherDay) {
  try {
    const res = await checkInTicket(ticketCode, confirmOtherDay);

    // 예약 날짜가 오늘이 아니면 서버가 기록하지 않고 되돌려보낸다(마이그레이션 287).
    //   운영자가 날짜를 보고 판단한 뒤에만 기록한다 — 먼저 기록하고 알리면 거를 기회가 없다.
    if (!res?.ok && res?.reason === 'other_day') {
      const s = res.slot || {};
      const when = `${String(s.slot_date || '').slice(0, 10)} ${String(s.start_time || '').slice(0, 5)}`;
      const ok = await showConfirm(
        `${res.name_kanji || ''} 님의 예약은 오늘이 아닙니다.\n\n예약: ${when}\n\n그래도 입장 처리할까요?`);
      if (!ok) return;
      return checkInFromAdmin(ticketCode, true);
    }

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
    other_day:             '오늘 예약이 아닙니다',
    permission_denied:     '권한이 없습니다'
  })[reason] || '확인하지 못했습니다';
}

// ══════════════════════════════════════════════════════════════
// 행사 모드에서 쓰이지 않는 입력칸 숨기기 (사용자 요청 2026-08-03)
// ══════════════════════════════════════════════════════════════
// 왜 숨기나: 오프라인 행사는 SNS 게시물도 배송도 리워드도 없다. 그런데도 칸이 남아
//   있으면 운영자가 「채워야 하나」 망설이고, 채운 값은 아무 데도 쓰이지 않는다.
//   실제로 이 값들이 행사 캠페인에서 무슨 일을 하는지:
//     · 채널·기준 채널·최소 팔로워 — 신청 게이트가 행사 모드에서 이 검사를 통째로
//       건너뛴다(application.js). 값을 넣어도 아무 일도 안 일어난다
//     · 콘텐츠 종류 — 결과물을 내지 않으므로 쓰이지 않는다
//     · 결과물 제출 마감일 — 제출할 결과물이 없다
//     · 당선 발표 안내 — 예약은 그 자리에서 확정된다(당선 발표가 없다)
//     · 리워드·제품 금액 — 리워드는 0 고정이고(정산에 새지 않게), 판매 제품이 없다
// ⚠️ 숨기기만 하면 저장 검증에 걸린다(채널 1개 이상 필수 등) — admin.js 의 검증도
//    같은 판정으로 건너뛴다. 한쪽만 하면 「보이지도 않는 칸 때문에 저장이 막힌다」가 된다.
// 행사 모드에서 숨기는 칸들의 「비운 값」. 등록·편집 두 저장 경로가 같은 값을 쓰게
// 한곳에 둔다 — 따로 적으면 한쪽만 고쳐져 어긋난다.
const EVENT_MODE_CLEARED_FIELDS = {
  channel: '', channel_match: 'or', primary_channel: null,
  content_types: '', min_followers: 0,
  submission_end: null, product_price: 0, reward: 0, reward_note: null,
  // 방문 기간은 「행사 시간」에서 계산한다. 편집 저장은 이 뒤에 시간대에서 읽은 값으로
  // 다시 덮어쓰고(시간대가 0줄이면 그대로 비어 있는 게 맞다), 신규 등록은 시간대가
  // 아직 없으므로 비운 채로 저장된다 — 손으로 적은 날짜가 남지 않게 한다.
  visit_start: null, visit_end: null
};

function applyEventModeFieldVisibility(prefix) {
  const on = !!$(prefix + 'CampEventMode')?.checked;
  const groupOf = id => $(prefix + id)?.closest('.form-group');

  // 시간대 구역은 편집 화면에만 있다(신규는 캠페인 식별자가 없어 걸 곳이 없다)
  const slotSec = $('editCampSlotSection');
  if (slotSec && prefix === 'edit') {
    // ⚠️ 여기서 _eventPaneCampId 를 쓰면 안 된다. 그 변수는 예약 현황 화면과 공유하는
    //    상태라 **다른 캠페인을 가리키고 있을 수 있다.** 일반 캠페인을 편집하다 행사
    //    모드를 처음 켜는 순간엔 아직 갱신되지 않아, 직전에 보던 캠페인의 시간대가
    //    이 화면에 그려지고 「타임 추가」·「정원 변경」이 **그 캠페인에 쓰인다**
    //    (2026-08-03 리뷰 지적). 지금 편집 중인 캠페인은 항상 editCampId 칸에 있다.
    const editingId = $('editCampId')?.value || '';
    slotSec.style.display = on ? '' : 'none';
    if (on && editingId) {
      _eventPaneCampId = editingId;   // 예약 현황 이동 버튼 등 다른 곳도 이 값을 본다
      renderEventSlotsPane(editingId);
    }
  }

  // ── ㉠ 행사 모드만 결정하는 칸 — 켜면 숨기고, 끄면 그냥 보이면 된다 ──
  const groups = [
    groupOf('CampChannelWrap'),        // 채널(+ 표시 방식 or/&)
    groupOf('CampContentTypeWrap'),    // 콘텐츠 종류
    groupOf('CampSubmissionEnd'),      // 결과물 제출 마감일
    groupOf('CampWinnerAnnounce'),     // 당선 발표 안내
    groupOf('CampReward'),             // 리워드 금액
    groupOf('CampRewardNote'),         // 리워드 추가 정보
    groupOf('CampProductPrice'),       // 제품 금액
  ];
  groups.forEach(g => { if (g) g.style.display = on ? 'none' : ''; });

  // ── ㉡ 모집 형식**도** 정하는 칸(방문 기간 · 기준 채널+최소 팔로워수) ──
  //   여기서 직접 보이거나 숨기지 않는다. 두 규칙(형식·행사)이 한 요소를 서로
  //   반대로 건드리면 나중에 실행된 쪽이 이겨서, 켜고 끄는 순서·비동기 렌더가
  //   끝나는 시점에 따라 결과가 달라진다. 행사 판정은 각 함수 안으로 옮겼으니
  //   여기서는 그 함수에 다시 물어보기만 한다.
  const rt = _currentRecruitType(prefix);
  if (typeof applyDeadlineFieldsVisibility === 'function') applyDeadlineFieldsVisibility(prefix, rt || 'monitor');
  if (typeof applyMinFollowersVisibility === 'function')   applyMinFollowersVisibility(prefix, rt || 'monitor');

  // 모집 인원 잠금은 시간대 개수에 달렸다 — 켜고 끌 때마다 다시 판정한다.
  if (prefix === 'edit') syncEventDerivedFields();
}

// 저장 직전에 시간대를 **다시 읽어** 방문 기간·모집 인원을 계산한다.
//   화면 캐시(_eventSlotsCache)를 쓰면 다른 관리자가 그 사이 고친 시간대를 놓친다.
async function fetchEventDerivedForSave(campaignId) {
  if (!campaignId || typeof fetchEventSlots !== 'function') return null;
  try { return eventDerivedFromSlots(await fetchEventSlots(campaignId)); }
  catch (e) { console.warn('[fetchEventDerivedForSave]', e); return null; }
}

// 이 캠페인이 행사 모드인가 — 저장 검증이 「보이지도 않는 칸」을 요구하지 않게 하는 판정.
//   ⚠️ 저장 시점에는 화면 체크박스가 곧 저장될 값이므로 그것을 본다.
function isEventModeForm(prefix) {
  return !!$(prefix + 'CampEventMode')?.checked;
}
