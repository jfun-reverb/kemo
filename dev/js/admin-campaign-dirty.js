// ══════════════════════════════════════
// 캠페인 폼 — 저장 안 한 변경을 두고 나가려 할 때 묻기
//   사용자 요청 2026-08-05. 계획은 reverb-planner 조사 결과를 따른다.
//
// 설계 요지 3줄
//   ① 기준값은 **화면(DOM)에서** 뜬다 — 데이터베이스 값과 비교하면 리치 텍스트 왕복·
//      번들 청소로 글자가 미세하게 달라져 「안 바꿨는데 경고」가 뜬다(이 폼에서 이미 두 번 터진 유형).
//   ② 기준값은 **늦게 도착하는 칸이 다 채워진 뒤** 뜬다(브랜드·행사 묶음·초대 번호).
//      그 전에 뜨면 값이 도착하는 순간 「사용자가 고친 것」이 된다 → 열자마자 경고.
//   ③ 기준값이 없으면 **묻지 않는다.** 이 기능은 없어도 원래대로 돌아갈 뿐이라,
//      거짓 경고보다 미검출이 낫다. 한 번 거짓 경고가 나면 그때부터 아무도 안 읽는다.
// ══════════════════════════════════════

// ⚠️ 모듈 전역 3종. 캠페인마다 비우는 자리를 반드시 지킨다 —
//    안 비우면 캠페인 A 의 기준값이 B 를 덮어 B 에서 즉시 경고가 뜨거나
//    B 의 진짜 변경을 놓친다(_recruitTypeBeforeEvent 와 같은 함정, 2026-08-03 사고 유형).
let _campDirtyBaseline = null;    // 기준값 {키: 값}
let _campDirtyFor = '';           // 그 기준값이 어느 캠페인 것인지
let _campDirtyPrefix = '';        // 어느 폼('edit'|'new') 것인지 — 다르면 비교하지 않는다.
                                  //   안 두면 편집 폼 기준값으로 신규 폼을 재는 순간
                                  //   **모든 칸이 「바뀜」**으로 잡힌다(리뷰에서 잡힌 결함).
let _campFormOpenSeq = 0;         // 폼을 연 횟수. 늦게 도착한 기준값이 지금 것인지 가른다

// 감지에서 빼는 것 — **이미 저장된 것**과 비교가 무의미한 것.
//   「저장 안 됨」이라고 말하면 거짓이 되는 항목이 여기 들어간다.
const CAMP_DIRTY_SKIP_PREFIX = [
  'eventSlot',      // 행사 시간대 — 누르는 즉시 저장된다
  // 시간대 **일괄 만들기** 입력칸(날짜·시작·간격·정원 등). 캠페인 저장과 아무 상관이 없고
  //   「만들기」를 누르면 그 자리에서 시간대가 저장된다. 빼지 않으면 관리자가 시간대를
  //   만들려고 값을 넣기만 해도 나갈 때 「저장하지 않은 변경이 있습니다」가 뜬다 —
  //   그 경고는 사실이 아니고, 그 값들은 저장할 대상도 아니다(2026-08-06 전수 점검에서 발견).
  'eventBulk',
  'tagWrap_',       // 태그 위젯의 임시 입력칸(칩으로 확정되기 전 값)
];
// ⚠️ 상태 드롭다운(editCampStatus)은 **빼지 않는다.** 관리자가 손으로 바꾸는 칸이기도 해서
//    통째로 빼면 그 변경을 못 잡는다. 대신 「노출 토글」이 즉시 저장한 직후에만
//    기준값의 그 칸을 새 값으로 맞춰, 토글로 인한 변화만 조용히 넘긴다(syncCampDirtyStatus).
//   숨은 칸은 사람이 고칠 수 없으므로 「고친 항목」에 뜨면 안 된다.
const CAMP_DIRTY_SKIP_IDS = ['editCampId'];

// ⚠️ id 가 없다고 건너뛰면 **모집 타입·채널·콘텐츠 종류가 통째로 빠진다** — 이 셋은
//    id 없이 name 만 갖거나(라디오), 체크박스에 id 가 없다(채널·콘텐츠는 화면에서 그린다).
//    가장 자주 만지는 칸들이라 빠지면 기능이 반쪽이 된다(리뷰에서 잡힌 결함).
//    → id 가 없으면 name 을 키로 쓰고, 그것도 없을 때만 건너뛴다.
function campDirtyKey(el) {
  const id = el.id || '';
  if (id) return id;
  const nm = el.getAttribute('name') || '';
  if (!nm) return '';
  // 같은 name 의 라디오·체크박스가 여럿이므로 값까지 키에 담아 각각을 구분한다.
  if (el.type === 'radio' || el.type === 'checkbox') return `name:${nm}:${el.value}`;
  return `name:${nm}`;
}

function campDirtySkip(el) {
  if (el.type === 'file') return true;
  const key = campDirtyKey(el);
  if (!key) return true;
  const id = el.id || '';
  if (id && CAMP_DIRTY_SKIP_IDS.includes(id)) return true;
  if (id && CAMP_DIRTY_SKIP_PREFIX.some(p => id.startsWith(p))) return true;
  // 화면에서 그리는 시간대 표는 id 가 없을 수 있으니 소속 구역으로도 거른다.
  if (el.closest && el.closest('[id^="eventSlot"], [id$="EventSlotsBox"]')) return true;
  return false;
}

// 폼 한 벌의 현재 값을 모은다. prefix 는 'edit' | 'new'.
function snapshotCampForm(prefix) {
  const pane = document.getElementById('adminPane-' + (prefix === 'edit' ? 'edit-campaign' : 'add-campaign'));
  if (!pane) return null;
  const snap = {};
  pane.querySelectorAll('input, select, textarea').forEach(el => {
    if (campDirtySkip(el)) return;
    snap[campDirtyKey(el)] = (el.type === 'checkbox' || el.type === 'radio') ? String(el.checked) : String(el.value ?? '');
  });
  // 리치 텍스트는 DOM 칸이 아니라 편집기 안에 있다. 저장 때 쓰는 값을 그대로 읽고,
  //   비교 전 정규화한다(서식만 다른 경우를 「바뀜」으로 보지 않으려고 — 기존 함수 재사용).
  RICH_EDITOR_IDS.forEach(id => {
    if (!id.startsWith(prefix)) return;
    try {
      const v = (typeof getRichValue === 'function') ? getRichValue(id) : '';
      snap['rich:' + id] = (typeof normalizeRichForCompare === 'function') ? normalizeRichForCompare(v) : v;
    } catch (e) { /* 편집기가 아직 없으면 건너뛴다 */ }
  });
  return snap;
}

// 기준값 뜨기. 늦게 도착하는 칸까지 채워진 뒤에 불러야 한다.
//   seq 가 지금 열린 폼의 것과 다르면 **버린다**(옆 캠페인 오염 차단).
function captureCampDirtyBaseline(prefix, campId, seq) {
  if (seq !== undefined && seq !== _campFormOpenSeq) return;
  _campDirtyBaseline = snapshotCampForm(prefix);
  _campDirtyFor = campId || '';
  _campDirtyPrefix = prefix;
}

// 폼을 열 때 맨 앞에서 부른다. 늦게 오는 옛 기준값을 무효로 만든다.
function resetCampDirtyBaseline() {
  _campFormOpenSeq += 1;
  _campDirtyBaseline = null;
  _campDirtyFor = '';
  _campDirtyPrefix = '';
  _campDirtyImmediateTouched = false;
  return _campFormOpenSeq;
}

// 「누르는 즉시 저장되는 것」을 이번에 만졌는지. 경고창 안내 한 줄을 붙일지 가른다.
let _campDirtyImmediateTouched = false;
function markCampImmediateSaved() { _campDirtyImmediateTouched = true; }

// 노출 토글이 즉시 저장한 뒤, 그 때문에 바뀐 상태 칸을 기준값에도 반영한다.
//   이렇게 해야 「토글만 눌렀는데 저장 안 됨」 거짓 경고가 안 뜨면서,
//   관리자가 상태를 **손으로** 바꾼 경우는 그대로 잡힌다.
function syncCampDirtyStatus(prefix) {
  if (!_campDirtyBaseline) return;
  const el = document.getElementById(prefix + 'CampStatus');
  if (el) _campDirtyBaseline[el.id] = String(el.value ?? '');
}

// 화면에 라벨이 없는 칸의 이름. 열쇠는 `newCamp`·`editCamp` 접두어를 뗀 나머지라
//   신규·편집 양쪽이 한 줄을 함께 쓴다.
//   ⚠️ 여기에 없어도 사용자에게 영문 이름이 새지는 않는다(못 찾으면 「그 밖의 항목」).
//      다만 그렇게만 보이므로, 자주 고치는 칸이면 이름을 적어 두는 게 낫다.
//   ⚠️ 화면에 라벨이 **있는** 칸은 여기 적지 않는다 — 위 두 자리에서 이미 찾으므로
//      영원히 안 쓰이는 줄이 되고, 나중에 화면 라벨을 고쳐도 여기가 안 따라온다.
const CAMP_DIRTY_FIELD_NAMES = {
  InviteCode: '초대 번호'
};

// 칸 하나의 **사람이 읽을 이름**. 못 찾으면 빈 문자열을 준다(부르는 쪽이 대체 이름을 넣는다).
//   ⚠️ 여기서 **절대 영문 id 를 돌려주지 않는다.** `newCampEventMode` 같은 글자가 사용자
//      화면에 그대로 뜬 적이 있고(2026-08-06 지적), 사용자는 비개발자라 읽을 수 없다.
//      「못 찾았다」를 빈 문자열로만 알리고, 영문인지 아닌지를 글자 모양으로 짐작하지 않는다
//      (짐작하면 「PayPal 이메일」 같은 정상 라벨이 언젠가 함께 걸린다).
function resolveCampDirtyFieldLabel(el, id) {
  const grp = el && el.closest ? el.closest('.form-group') : null;
  const lb = grp ? grp.querySelector('.form-label') : null;
  if (lb) {
    // 라벨에는 「필수」 배지·잠금 안내 같은 곁가지가 붙어 있다. 첫 줄의 이름만 남긴다 —
    //   안 그러면 「모집 타입 lock행사 모드 — 방문형 고정」처럼 읽기 어려운 이름이 나온다.
    const own = [...lb.childNodes]
      .filter(n => n.nodeType === 3)          // 글자 마디만(배지·아이콘 제외)
      .map(n => n.textContent).join(' ');
    const name = (own || lb.textContent).replace(/필수|선택/g, '').split('\n')[0].trim();
    if (name) return name;
  }
  // 체크박스·라디오는 `.form-group`+`.form-label` 구조가 아니라 **자기 <label> 안에**
  //   글자가 있다(행사 모드·비공개 등). 위에서 못 찾으면 여기서 찾는다.
  if (el && el.closest) {
    const own = el.closest('label');
    if (own) {
      const name = (own.textContent || '').replace(/\s+/g, ' ').trim();
      if (name) return name;
    }
  }
  // 라벨이 아예 없는 칸(초대 번호처럼 버튼 옆에 홀로 있는 입력칸)은 이름을 정해 둔다.
  return CAMP_DIRTY_FIELD_NAMES[String(id).replace(/^(new|edit)Camp/, '')] || '';
}

// 바뀐 항목의 **한국어 이름** 목록. 없으면 빈 배열.
//   기준값이 없으면(아직 안 떴거나 폼이 아니면) 빈 배열 — 모르면 막지 않는다.
function campDirtyChangedLabels(prefix) {
  if (!_campDirtyBaseline) return [];
  if (_campDirtyPrefix !== prefix) return [];   // 다른 폼의 기준값으로는 재지 않는다
  const now = snapshotCampForm(prefix);
  if (!now) return [];
  const labels = [];
  const seen = {};
  const pushLabel = (key) => {
    let id = key.startsWith('rich:') ? key.slice(5) : key;
    let el = null;
    if (id.startsWith('name:')) {
      const nm = id.split(':')[1];
      el = document.querySelector(`#adminPane-${prefix === 'edit' ? 'edit' : 'add'}-campaign [name="${nm}"]`);
    }
    if (!el) el = document.getElementById(id);
    // 못 찾으면 빈 문자열이 온다 — 그때만 대체 이름을 쓴다. 찾은 이름은 모양을 따지지 않는다.
    let name = resolveCampDirtyFieldLabel(el, id);
    if (!name) name = '그 밖의 항목';
    // 긴 라벨은 목록이 읽히지 않으므로 자른다(체크박스 글자가 문장인 경우가 있다).
    if (name.length > 24) name = name.slice(0, 23) + '…';
    if (seen[name]) return;
    seen[name] = 1;
    labels.push(name);
  };
  Object.keys(now).forEach(k => { if (_campDirtyBaseline[k] !== now[k]) pushLabel(k); });
  // 이미지는 별도 플래그가 이미 있다(추가·삭제·순서·자르기 모두 세운다).
  if (prefix === 'edit' && typeof editCampImgChanged !== 'undefined' && editCampImgChanged) {
    if (!seen['이미지']) { seen['이미지'] = 1; labels.push('이미지'); }
  }
  // 주의사항·참여방법·금지사항 번들은 기존 비교 함수를 그대로 쓴다 —
  //   거짓 감지를 막는 정규화가 이미 들어 있고, 그 자리에서 회귀가 두 번 났다.
  if (prefix === 'edit' && typeof detectSensitiveChange === 'function') {
    try {
      const d = detectSensitiveChange(buildSensitivePayloadForDirty());
      if (d && d.changed && !seen['주의사항·참여방법·금지사항']) {
        seen['주의사항·참여방법·금지사항'] = 1;
        labels.push('주의사항·참여방법·금지사항');
      }
    } catch (e) { /* 비교 못 하면 그냥 넘어간다 */ }
  }
  return labels;
}

// 번들 비교에 넘길 값.
// ⚠️ **저장 경로가 부르는 함수를 그대로 쓴다.** 값을 손으로 흉내 내면 이름이 하나만
//    달라도 항상 빈 값이 넘어가 **모든 캠페인에서 거짓 경고**가 뜬다(리뷰에서 실제로 잡힌 결함).
function buildSensitivePayloadForDirty() {
  const p = {};
  if (typeof collectCampCsetPayload === 'function') Object.assign(p, collectCampCsetPayload('edit'));
  if (typeof collectCampPsetPayload === 'function') Object.assign(p, collectCampPsetPayload('edit'));
  if (typeof collectCampNsetPayload === 'function') Object.assign(p, collectCampNsetPayload('edit'));
  return p;
}

// 지금 편집·신규 폼이 열려 있고 저장 안 한 변경이 있으면 그 접두사를 돌려준다.
function activeDirtyCampForm() {
  const isVisible = id => {
    const p = document.getElementById(id);
    return p && getComputedStyle(p).display !== 'none';
  };
  if (isVisible('adminPane-edit-campaign')) {
    const labels = campDirtyChangedLabels('edit');
    if (labels.length) return {prefix: 'edit', labels};
  }
  if (isVisible('adminPane-add-campaign')) {
    const labels = campDirtyChangedLabels('new');
    if (labels.length) return {prefix: 'new', labels};
  }
  return null;
}

// ── 경고창 ────────────────────────────────────────────────
// 기존 showConfirm 은 버튼 2개 고정이라 쓸 수 없다(저장하고 나가기 / 저장 안 하고 나가기 / 취소).
let _campLeaveGo = null;   // 「나가기」를 고르면 실행할 이동 함수
let _campLeaveSavePrefix = '';   // 「저장」이 어느 폼을 저장할지('edit' | 'new')

function campLeaveGuard(go) {
  const d = activeDirtyCampForm();
  if (!d) { go(); return; }        // 변경 없음 — 그냥 보낸다
  _campLeaveGo = go;

  // 어느 폼을 저장할지 기억해 둔다 — 「저장」이 부를 함수가 갈린다.
  _campLeaveSavePrefix = d.prefix;

  // 아직 저장 안 된 것이 「새로 적은 것」인지 「고친 것」인지에 따라 말이 달라진다.
  //   ⚠️ 바뀐 항목 목록은 **일부러 보여주지 않는다**(2026-08-06 사용자 결정) —
  //      나갈지 말지 정하는 자리라 목록을 읽을 일이 없고, 길어지면 버튼을 가린다.
  const title = document.getElementById('campLeaveModalTitle');
  if (title) {
    title.textContent = (d.prefix === 'edit') ? '수정된 정보가 있습니다' : '입력한 정보가 있습니다';
  }

  // 「저장하지 않고 나가기」를 눌러도 되돌아가지 않는 것이 있으면 그때만 알린다.
  const note = document.getElementById('campLeaveModalNote');
  if (note) {
    note.style.display = _campDirtyImmediateTouched ? '' : 'none';
  }

  openModal('campLeaveModal');
}

// 저장하고 나가기 — 경고창을 **먼저 닫는다.** 저장 함수가 확인창을 또 띄울 수 있는데,
//   확인창 인프라는 결과를 담는 자리가 하나뿐이라 겹쳐 띄우면 서로를 잡아먹는다.
// ⚠️ 여기서 화면 이동을 하지 않는다. 저장이 성공하면 저장 함수가 스스로 목록으로 가고,
//    실패·취소면 폼에 남는 게 맞다(고친 내용을 들고 화면을 떠나면 그대로 유실된다).
// 「저장」 — 두 저장 함수 모두 **성공하면 스스로 목록으로 나가고 실패하면 폼에 남는다.**
//   그래서 여기서 따로 이동시키지 않는다. 필수 항목이 비어 저장이 막히면 관리자는
//   폼에 남아 무엇이 빠졌는지 보게 된다(그대로 내보내면 입력이 사라진다).
function campLeaveSaveAndGo() {
  const prefix = _campLeaveSavePrefix;
  closeModal('campLeaveModal');
  _campLeaveGo = null;
  if (prefix === 'edit') {
    if (typeof saveCampaignEdit === 'function') saveCampaignEdit();
  } else if (typeof addCampaign === 'function') {
    addCampaign();
  }
}

function campLeaveDiscardAndGo() {
  closeModal('campLeaveModal');
  const go = _campLeaveGo;
  _campLeaveGo = null;
  resetCampDirtyBaseline();   // 기준값을 비워 다음 화면에서 옛 값으로 판단하지 않게 한다
  if (typeof go === 'function') go();
}

function campLeaveCancel() {
  closeModal('campLeaveModal');
  _campLeaveGo = null;
}
