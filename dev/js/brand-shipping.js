// 브랜드 페이지 — 시딩형 배송 카드(캠페인 상세) + 배송 리스트(#campaigns/<캠페인 번호>/shipping)
//   작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S5」 · 사양서 ① §4-2·§4-3
//   피그마 Brand 1차 bw05-01b(배송 카드) · bw05-02(PC 리스트) · bm05-02(모바일 — 보기 + 한 줄 입력, 결정 12) · bw05-90·91·94(토스트·상태)
//   서버(557): get_my_brand_shipping_summary(카드 — 숫자만, 기록 없음) · get_my_brand_shipping_list(리스트 — 제공 기록 shipping_view)
//              · save_my_brand_shipping_rows(한 줄 저장 — 지금 승인인 줄만 · 종료면 campaign_ended)
//   🔴 줄 상태·기한·「새로 추가」·탈퇴·주소 가림은 서버 값 그대로 그린다(판정 사본 없음)
//   🔴 조회 실패(null)는 오류 화면, 0줄은 「지금 보낼 분이 없습니다」(bw05-94 ⑤) — 섞지 않는다
//   🔴 송장 형식 BRAND_SHIP_TRACKING_RE 는 서버 _shipping_check_row 의 사본(관리자 admin-shipping.js SHIP_TRACKING_RE 와 셋이 같은 식)
//   · 전화번호는 회원이 적은 그대로(D24) · 탈퇴로 이름이 비면 「탈퇴한 회원」(D25) · 종료면 입력·수정·지우기 단추 없음(D2)
//   · 엑셀 내려받기·올리기는 S6 · 모바일은 엑셀 없음(결정 12)

const BRAND_SHIP_TRACKING_RE = /^[A-Za-z0-9 -]{4,40}$/;
const BRAND_SHIP_TARGET_KEY = 'reverb.brandShippingTarget';   // 메일 링크 ?shipping=<캠페인 번호>(D20) — 세션 저장소
const BRAND_SHIP_OTHER = '__other';

const BRAND_SHIP_MSG = {
  saved: '송장번호를 저장했습니다.',
  cleared: '송장번호를 지웠습니다. 「발송 전」으로 돌아갔습니다.',
  saveFail: '저장하지 못했습니다. 잠시 뒤 다시 시도해 주십시오.',
  cancelled: '이미 취소된 분입니다. 송장을 등록할 수 없습니다.',
  conflict: '다른 곳에서 먼저 바뀌었습니다. 최신 내용으로 다시 불러왔습니다.',
  ended: '캠페인이 종료되어 송장을 더 입력하거나 고칠 수 없습니다.',
  notFound: '이 줄을 찾지 못했습니다. 최신 내용으로 다시 불러왔습니다.',
  carrierRequired: '택배사를 골라 주십시오',
  otherRequired: '택배사 이름을 적어 주십시오',
  trackingRequired: '송장번호를 적어 주십시오',
  trackingFormat: '영문·숫자·하이픈·띄어쓰기만 4~40자로 넣을 수 있습니다',
  carrierInvalid: '택배사를 다시 골라 주십시오',
  shippedOnInvalid: '발송일이 올바르지 않습니다',
  listFailTitle: '배송 리스트를 불러오지 못했습니다',
  listFailDesc: '잠시 뒤 다시 시도해 주십시오. 계속되면 운영팀에 알려 주십시오.',
  notFoundTitle: '이 배송 리스트를 볼 수 없습니다',
  notFoundDesc: '아직 운영팀이 전달하지 않았거나, 지금 브랜드에서 볼 수 없는 캠페인입니다. 캠페인 상세로 돌아가 확인해 주십시오.',
  emptyTitle: '지금 보낼 분이 없습니다',
  emptyDescCancelled: '전달 뒤 선정이 모두 취소되었습니다. 「취소됨」 탭에서 보낼 필요가 없는 분을 확인할 수 있습니다.',
  emptyDesc: '선정된 분이 생기면 이 리스트에 자동으로 추가됩니다.'
};

let _bsSum = null;     // 상세 카드 { id, state:'loading'|'error'|'notready'|'ok', data }
let _bsSumSeq = 0;
let _bsList = null;    // 리스트 { id, state:'loading'|'error'|'not_found'|'ok', data }
let _bsListSeq = 0;
let _bsTab = '';       // '' | 'pending'(기한 지남 포함) | 'shipped' | 'cancelled'
let _bsEdit = null;    // 입력 중인 줄 { rowNo, carrier, other, tracking, errors:{carrier, tracking} }
let _bsSaving = false;

// ── 메일 링크 ?shipping=<캠페인 번호> — 부팅 때 세션 저장소에 옮기고 주소에서 지운다(brand-app.js bootBrand)
function captureBrandShippingTarget(params) {
  const id = params.get('shipping');
  if (!id) return;
  if (BRAND_UUID_RE.test(id)) {
    try { sessionStorage.setItem(BRAND_SHIP_TARGET_KEY, id); } catch (e) { /* 저장소 막힘 — 로그인 뒤 첫 페이지로 */ }
  }
  params.delete('shipping');
  const q = params.toString();
  history.replaceState(null, '', location.pathname + (q ? '?' + q : '') + location.hash);
}
// 로그인 뒤(또는 세션 복원 뒤) 갈 주소 — 한 번 꺼내면 지운다. 없으면 null
function takeBrandShippingTarget() {
  let id = null;
  try { id = sessionStorage.getItem(BRAND_SHIP_TARGET_KEY); sessionStorage.removeItem(BRAND_SHIP_TARGET_KEY); } catch (e) { id = null; }
  return (id && BRAND_UUID_RE.test(id)) ? 'campaigns/' + id + '/shipping' : null;
}

// ── 표시 조각
function _bsReceivers(k) { return (Number(k.total) || 0) - (Number(k.cancelled) || 0); }
function _bsPendingAll(k) { return (Number(k.pending) || 0) + (Number(k.overdue) || 0); }
function _bsName(r) { return r.withdrawn ? '탈퇴한 회원' : (r.name || ''); }
function _bsStatusBadge(r) {
  if (r.status === 'shipped') return '<span class="bs-badge is-shipped">발송함</span>';
  if (r.status === 'overdue') return '<span class="bs-badge is-overdue">발송 전 · 기한 지남</span>';
  if (r.status === 'cancelled') return '<span class="bs-badge is-cancelled">취소됨</span>';
  return '<span class="bs-badge is-pending">발송 전</span>';
}
function _bsNewBadge(r) {
  return r.is_new ? '<span class="bs-badge is-new">' + brandEsc(_bcShort(r.added_on)) + ' 새로 추가</span>' : '';
}
function _bsCarrierText(r) {
  return r.carrier_name || r.carrier_other || '';
}

// ── 캠페인 상세 배송 카드(bw05-01b · bw05-91 ①) — 시딩형만. 숫자만, 개인정보·기록 없음
function brandShippingCardHtml(c) {
  if (!c || c.recruit_type !== 'gifting') return '';
  const st = (_bsSum && _bsSum.id === c.id) ? _bsSum : { state: 'loading' };
  const open = '<section class="bc-card" id="bsShipSection">';
  if (st.state === 'loading') return open + '<h2 class="bc-card-title">배송</h2><div class="bo-state" aria-busy="true"><p class="bo-state-desc">불러오는 중…</p></div></section>';
  if (st.state === 'error') {
    return open + '<h2 class="bc-card-title">배송</h2><p class="bc-card-desc">배송 현황을 불러오지 못했습니다.</p>' +
      '<button type="button" class="brand-btn brand-btn-line bs-retry" data-bs-act="retry-sum">다시 시도</button></section>';
  }
  if (st.state === 'notready') {
    return open + '<div class="bs-card-head"><h2 class="bc-card-title">배송</h2><span class="bs-badge is-ready">준비 중</span></div>' +
      '<p class="bs-card-desc">운영팀이 선정을 마치고 배송 리스트를 전달하면 여기에서 보고 송장번호를 등록할 수 있습니다. 전달되면 「배송 리스트 열기」 단추가 생깁니다.</p></section>';
  }
  const d = st.data || {};
  const k = d.counts || {};
  const overdue = Number(k.overdue) || 0;
  return open +
    '<div class="bs-card-head"><h2 class="bc-card-title">배송</h2><span class="bs-badge is-delivered">배송 리스트 전달됨</span>' +
      '<a class="brand-btn bs-open-btn" href="#campaigns/' + brandEsc(c.id) + '/shipping">' +
        '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">local_shipping</span>배송 리스트 열기</a></div>' +
    '<p class="bs-card-desc">운영팀이 ' + brandEsc(brandFormatDateTime(d.delivered_at) || '') + '에 배송 리스트를 전달했습니다. 받은 날부터 3일 안에 발송하고 송장번호를 등록해 주십시오.</p>' +
    '<div class="br-counts bs-counts">' +
      '<div class="br-count"><span>받는 사람</span><b>' + _bsReceivers(k) + '</b></div>' +
      '<div class="br-count"><span>발송함</span><b>' + (Number(k.shipped) || 0) + '</b></div>' +
      '<div class="br-count"><span>발송 전</span><b class="' + (_bsPendingAll(k) ? 'is-warn' : '') + '">' + _bsPendingAll(k) + '</b>' +
        (overdue ? '<em class="bs-overdue">기한 지남 ' + overdue + '</em>' : '') + '</div>' +
      '<div class="br-count"><span>취소됨</span><b>' + (Number(k.cancelled) || 0) + '</b></div>' +
    '</div></section>';
}

async function loadBrandShippingSummary(id) {
  const seq = ++_bsSumSeq;
  if (!_bsSum || _bsSum.id !== id || _bsSum.state !== 'ok') _bsSum = { id, state: 'loading' };
  _bsSumRerender();
  const { data, error } = await brandRpc('get_my_brand_shipping_summary', { p_campaign_id: id });
  if (seq !== _bsSumSeq) return;
  if (error || !data || data.success !== true) _bsSum = { id, state: 'error' };
  else if (data.ready !== true) _bsSum = { id, state: 'notready' };
  else _bsSum = { id, state: 'ok', data };
  _bsSumRerender();
}
function _bsSumRerender() {
  const sec = document.getElementById('bsShipSection');
  if (!sec || !_bcDetail || _bcDetail.state !== 'ok' || !_bsSum || _bcDetail.id !== _bsSum.id) return;
  sec.outerHTML = brandShippingCardHtml(_bcDetail.camp);
}

// ── 배송 리스트 페이지(bw05-02 · bm05-02)
function _bsHeadHtml(id, d) {
  const sub = d ? [d.product, d.campaign_no, '시딩'].filter(Boolean).join(' · ') : '';
  return '<div class="bc-detail-head">' +
    '<a class="bc-back" href="#campaigns/' + brandEsc(id) + '"><span aria-hidden="true">‹</span> 캠페인 상세</a>' +
    '<div class="bc-detail-title"><h1>배송 리스트</h1></div>' +
    (sub ? '<p class="bc-detail-sub">' + brandEsc(sub) + '</p>' : '') + '</div>';
}
function _bsInfoHtml(d) {
  const lines = ['운영팀이 ' + (brandFormatDateTime(d.delivered_at) || '') + '에 전달했습니다', '선정된 분만 보입니다',
    '이 정보는 제품 배송에만 쓰고, 다 쓰면 내려받은 파일까지 지워 주십시오(이용약관 제8조).'];
  return '<div class="bs-info" role="note"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">info</span>' +
    '<span>' + brandEsc(lines.join(' · ')) + '</span></div>' +
    (d.editable === false ? '<div class="bs-info is-warn" role="note"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">lock</span>' +
      '<span>' + brandEsc(BRAND_SHIP_MSG.ended) + ' 보기는 계속할 수 있습니다.</span></div>' : '');
}
function _bsTabsHtml(k) {
  const tabs = [
    { key: '', label: '전체', n: Number(k.total) || 0 },
    { key: 'pending', label: '발송 전', n: _bsPendingAll(k) },
    { key: 'shipped', label: '발송함', n: Number(k.shipped) || 0 },
    { key: 'cancelled', label: '취소됨', n: Number(k.cancelled) || 0 }
  ];
  return '<div class="bo-tabs bs-tabs" role="tablist" aria-label="배송 상태">' + tabs.map(t => {
    const on = t.key === _bsTab;
    return '<button type="button" role="tab" class="bo-tab' + (on ? ' is-on' : '') + '" aria-selected="' + on + '" data-bs-act="tab" data-tab="' + t.key + '">' +
      '<span class="bo-tab-name">' + brandEsc(t.label) + '</span><span class="bo-tab-count">' + t.n + '</span></button>';
  }).join('') + '</div>';
}
function _bsInTab(r) {
  if (!_bsTab) return true;
  if (_bsTab === 'pending') return r.status === 'pending' || r.status === 'overdue';
  return r.status === _bsTab;
}

// 입력 칸(한 줄 입력 — PC 는 표 칸 안, 모바일은 카드 안)
function _bsCarrierSelectHtml(d, e) {
  const carriers = Array.isArray(d.carriers) ? d.carriers : [];
  let opts = '<option value="">택배사 선택</option>';
  carriers.forEach(c => { opts += '<option value="' + brandEsc(c.code) + '"' + (e.carrier === c.code ? ' selected' : '') + '>' + brandEsc(c.name) + '</option>'; });
  // 목록에서 꺼진 택배사로 저장된 줄 — 이름은 보이되 다시 고를 수 없다(서버가 거부)
  if (e.carrier && e.carrier !== BRAND_SHIP_OTHER && !carriers.some(c => c.code === e.carrier)) {
    opts += '<option value="' + brandEsc(e.carrier) + '" selected disabled>' + brandEsc(e.carrierName || e.carrier) + ' (다시 골라 주십시오)</option>';
  }
  opts += '<option value="' + BRAND_SHIP_OTHER + '"' + (e.carrier === BRAND_SHIP_OTHER ? ' selected' : '') + '>기타(직접 입력)</option>';
  return '<select class="brand-input bs-in' + (e.errors.carrier ? ' is-error' : '') + '" data-bs-field="carrier" aria-label="택배사">' + opts + '</select>';
}
function _bsEditFieldsHtml(d, e) {
  return '<div class="bs-edit-carrier">' + _bsCarrierSelectHtml(d, e) +
      (e.carrier === BRAND_SHIP_OTHER ? '<input class="brand-input bs-in' + (e.errors.other ? ' is-error' : '') + '" data-bs-field="other" maxlength="50" placeholder="택배사 이름" aria-label="택배사 이름" value="' + brandEsc(e.other) + '">' : '') +
      (e.errors.carrier || e.errors.other ? '<p class="brand-field-error">' + brandEsc(e.errors.carrier || e.errors.other) + '</p>' : '') +
    '</div>' +
    '<div class="bs-edit-track"><input class="brand-input bs-in' + (e.errors.tracking ? ' is-error' : '') + '" data-bs-field="tracking" maxlength="40" inputmode="text" autocomplete="off" placeholder="송장번호" aria-label="송장번호" value="' + brandEsc(e.tracking) + '">' +
      (e.errors.tracking ? '<p class="brand-field-error">' + brandEsc(e.errors.tracking) + '</p>' : '') + '</div>';
}
function _bsActionHtml(r, d, editing) {
  if (r.status === 'cancelled') return '<span class="bs-dont">보내지 마십시오</span>';
  if (d.editable === false) return '';
  if (editing) {
    return '<button type="button" class="bs-link is-strong" data-bs-act="save" data-row="' + r.row_no + '"' + (_bsSaving ? ' disabled' : '') + '>' + (_bsSaving ? '저장 중…' : '저장') + '</button>' +
      '<button type="button" class="bs-link is-muted" data-bs-act="cancel-edit"' + (_bsSaving ? ' disabled' : '') + '>취소</button>' +
      (r.tracking_no ? '<button type="button" class="bs-link is-danger" data-bs-act="clear" data-row="' + r.row_no + '"' + (_bsSaving ? ' disabled' : '') + '>송장 지우기</button>' : '');
  }
  return '<button type="button" class="bs-link" data-bs-act="edit" data-row="' + r.row_no + '">' + (r.tracking_no ? '수정' : '입력') + '</button>';
}
function _bsTableHtml(d, rows) {
  const body = rows.map(r => {
    const cancelled = r.status === 'cancelled';
    const editing = _bsEdit && _bsEdit.rowNo === r.row_no && !cancelled;
    const name = '<div class="bs-name">' + brandEsc(_bsName(r)) + ' ' + _bsNewBadge(r) + '</div>' + (r.name_kana ? '<div class="bs-kana">' + brandEsc(r.name_kana) + '</div>' : '');
    const dash = _bcDash();
    return '<tr class="' + (cancelled ? 'is-cancelled' : '') + (editing ? ' is-editing' : '') + '">' +
      '<td class="c-center">' + (r.row_no != null ? r.row_no : dash) + '</td>' +
      '<td>' + name + '</td>' +
      '<td>' + (cancelled ? dash : (brandEsc(r.postal_code || '') || dash)) + '</td>' +
      '<td>' + (cancelled ? '<span class="bs-hidden">취소되어 가렸습니다</span>' : (brandEsc(r.address || '') || dash)) + '</td>' +
      '<td>' + (cancelled ? dash : (brandEsc(r.phone || '') || dash)) + '</td>' +
      (editing ? '<td colspan="2" class="bs-edit-cell"><div class="bs-edit-row">' + _bsEditFieldsHtml(d, _bsEdit) + '</div></td>'
        : '<td>' + (brandEsc(_bsCarrierText(r)) || dash) + '</td><td class="bs-track">' + (brandEsc(r.tracking_no || '') || dash) + '</td>') +
      '<td>' + (r.shipped_on ? brandEsc(_bcShort(r.shipped_on)) : dash) + '</td>' +
      '<td>' + _bsStatusBadge(r) + (r.due_on && r.status !== 'shipped' && !cancelled ? '<div class="bs-due">기한 ' + brandEsc(_bcShort(r.due_on)) + '</div>' : '') + '</td>' +
      '<td class="bs-act">' + _bsActionHtml(r, d, editing) + '</td>' +
    '</tr>';
  }).join('');
  return '<div class="bo-table-scroll"><table class="bs-table">' +
    '<thead><tr><th class="w-no">No</th><th class="w-name">이름</th><th class="w-zip">우편번호</th><th class="w-addr">주소</th><th class="w-tel">전화번호</th>' +
    '<th class="w-car">택배사</th><th class="w-trk">송장번호</th><th class="w-date">발송일</th><th class="w-st">상태</th><th class="w-act"><span class="bs-sr">관리</span></th></tr></thead>' +
    '<tbody>' + body + '</tbody></table></div>';
}
function _bsCardsHtml(d, rows) {
  return '<div class="bs-cards">' + rows.map(r => {
    const cancelled = r.status === 'cancelled';
    const editing = _bsEdit && _bsEdit.rowNo === r.row_no && !cancelled;
    let body;
    if (cancelled) body = '<p class="bs-hidden">취소되어 주소·전화번호를 가렸습니다 — 보내지 마십시오</p>';
    else {
      const addr = [r.postal_code ? '〒' + r.postal_code : '', r.address || ''].filter(Boolean).join(' ');
      body = (r.name_kana ? '<p class="bs-kana">' + brandEsc(r.name_kana) + '</p>' : '') +
        (addr ? '<p class="bs-line">' + brandEsc(addr) + '</p>' : '') +
        (r.phone ? '<p class="bs-line">' + brandEsc(r.phone) + '</p>' : '');
      if (editing) {
        body += '<div class="bs-card-edit">' + _bsEditFieldsHtml(d, _bsEdit) +
          '<button type="button" class="brand-btn" data-bs-act="save" data-row="' + r.row_no + '"' + (_bsSaving ? ' disabled' : '') + '>' + (_bsSaving ? '저장 중…' : '저장') + '</button>' +
          '<div class="bs-card-edit-sub"><button type="button" class="bs-link is-muted" data-bs-act="cancel-edit"' + (_bsSaving ? ' disabled' : '') + '>취소</button>' +
            (r.tracking_no ? '<button type="button" class="bs-link is-danger" data-bs-act="clear" data-row="' + r.row_no + '"' + (_bsSaving ? ' disabled' : '') + '>송장 지우기</button>' : '') + '</div></div>';
      } else if (r.tracking_no) {
        body += '<p class="bs-line is-ship">' + brandEsc([_bsCarrierText(r), r.tracking_no, _bcShort(r.shipped_on)].filter(Boolean).join(' · ')) +
          (d.editable !== false ? ' <button type="button" class="bs-link" data-bs-act="edit" data-row="' + r.row_no + '">수정</button>' : '') + '</p>';
      } else if (d.editable !== false) {
        body += '<button type="button" class="bs-link" data-bs-act="edit" data-row="' + r.row_no + '">송장 입력</button>';
      }
    }
    return '<article class="bs-card' + (cancelled ? ' is-cancelled' : '') + '">' +
      '<div class="bs-card-top"><p class="bs-card-name">' + (r.row_no != null ? r.row_no + ' ' : '') + brandEsc(_bsName(r)) + '</p>' +
        '<span class="bs-card-badges">' + _bsNewBadge(r) + _bsStatusBadge(r) + '</span></div>' + body + '</article>';
  }).join('') + '</div>';
}

function renderBrandShippingPage(host, id) {
  const st = (_bsList && _bsList.id === id) ? _bsList : { state: 'loading' };
  const d = st.state === 'ok' ? st.data : null;
  let inner = _bsHeadHtml(id, d);
  if (st.state === 'loading') {
    inner += '<div class="bs-skel" aria-busy="true" aria-label="불러오는 중"><i></i><i></i><i></i></div>';
  } else if (st.state === 'error') {
    inner += '<div class="bo-panel"><div class="bo-state" role="alert"><p class="bo-state-title">' + brandEsc(BRAND_SHIP_MSG.listFailTitle) + '</p>' +
      '<p class="bo-state-desc">' + brandEsc(BRAND_SHIP_MSG.listFailDesc) + '</p>' +
      '<button type="button" class="brand-btn brand-btn-line bo-state-btn" data-bs-act="retry-list">다시 시도</button></div></div>';
  } else if (st.state === 'not_found') {
    inner += '<div class="bo-panel"><div class="bo-state"><p class="bo-state-title">' + brandEsc(BRAND_SHIP_MSG.notFoundTitle) + '</p>' +
      '<p class="bo-state-desc">' + brandEsc(BRAND_SHIP_MSG.notFoundDesc) + '</p>' +
      '<a class="brand-btn bo-state-btn" href="#campaigns/' + brandEsc(id) + '">캠페인 상세</a></div></div>';
  } else {
    const k = d.counts || {};
    const rows = (Array.isArray(d.rows) ? d.rows : []).filter(_bsInTab);
    const mobile = _bcMobileMq.matches;
    let list;
    if (!(Number(k.total) || 0)) list = '<div class="bs-empty"><p class="bs-empty-title">' + brandEsc(BRAND_SHIP_MSG.emptyTitle) + '</p><p class="bs-empty-desc">' + brandEsc(BRAND_SHIP_MSG.emptyDesc) + '</p></div>';
    else if (!rows.length) list = '<div class="bs-empty"><p class="bs-empty-desc">이 상태인 분이 없습니다. 「전체」 탭에서 모든 분을 볼 수 있습니다.</p></div>';
    else list = mobile ? _bsCardsHtml(d, rows) : _bsTableHtml(d, rows);
    // 받는 사람 0명(모두 취소) — 전체 탭 위에 안내(bw05-94 ⑤)
    const allCancelled = (Number(k.total) || 0) > 0 && _bsReceivers(k) === 0 && !_bsTab;
    inner += _bsInfoHtml(d) +
      '<section class="bo-panel bs-panel" aria-label="배송 리스트">' +
        '<div class="bs-panel-head">' + _bsTabsHtml(k) + '</div>' +
        (allCancelled ? '<div class="bs-empty"><p class="bs-empty-title">' + brandEsc(BRAND_SHIP_MSG.emptyTitle) + '</p><p class="bs-empty-desc">' + brandEsc(BRAND_SHIP_MSG.emptyDescCancelled) + '</p></div>' : '') +
        '<div class="bs-list">' + list + '</div>' +
        '<p class="br-note bs-note">송장번호를 저장하면 바로 「발송함」이 됩니다. 운영팀도 같은 내용을 봅니다. 인플루언서에게는 보이지 않습니다.</p>' +
      '</section>';
  }
  host.innerHTML = '<div class="bc-page bc-detail bs-page">' + inner + '</div>';
}

async function loadBrandShippingPage(id) {
  const seq = ++_bsListSeq;
  if (!_bsList || _bsList.id !== id) { _bsList = { id, state: 'loading' }; _bsTab = ''; _bsEdit = null; _bsRerenderIfShown(); }
  // 다른 내 브랜드의 캠페인이면 그 브랜드로 바꾼다(메일 링크로 들어온 경우 — 상세와 같은 방식). 판정은 캠페인 상세 함수가 준다
  const det = await brandRpc('get_my_brand_campaign', { p_campaign_id: id });
  if (seq !== _bsListSeq) return;
  const camp = det && !det.error && det.data && det.data.success === true ? det.data.campaign : null;
  if (camp && camp.brand_id && camp.brand_id !== getCurrentBrandId()) {
    _bcAutoSwitching = true;
    let r;
    try { r = await switchBrand(camp.brand_id); } finally { _bcAutoSwitching = false; }
    if (seq !== _bsListSeq) return;
    if (r !== 'ok') { _bsList = { id, state: r === 'not_linked' ? 'not_found' : 'error' }; _bsRerenderIfShown(); return; }
  }
  const { data, error } = await brandRpc('get_my_brand_shipping_list', { p_campaign_id: id });
  if (seq !== _bsListSeq) return;
  if (!error && data && data.success === false) _bsList = { id, state: 'not_found' };
  else if (error || !data || data.success !== true) _bsList = { id, state: 'error' };
  else _bsList = { id, state: 'ok', data };
  _bsRerenderIfShown();
}
function _bsCurrentId() {
  const parts = splitBrandHash(location.hash.replace(/^#/, ''));
  if (parts.page !== 'campaigns') return null;
  const [id, sub] = String(parts.arg || '').split('/');
  return sub === 'shipping' ? id : null;
}
function _bsRerenderIfShown() {
  const id = _bsCurrentId();
  if (!id || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (!host) return;
  // 입력 칸에 친 글자를 다시 그리기 전에 옮겨 둔다(그리면 칸이 새로 만들어진다)
  _bsPullEditInputs();
  const a = document.activeElement;
  const focusField = a && host.contains(a) && a.dataset ? a.dataset.bsField || null : null;
  renderBrandShippingPage(host, id);
  if (focusField) { const el = host.querySelector('[data-bs-field="' + focusField + '"]'); if (el) el.focus(); }
}
function _bsPullEditInputs() {
  if (!_bsEdit) return;
  const host = document.getElementById('brandPageHost');
  if (!host) return;
  const sel = host.querySelector('[data-bs-field="carrier"]');
  const oth = host.querySelector('[data-bs-field="other"]');
  const trk = host.querySelector('[data-bs-field="tracking"]');
  if (sel) _bsEdit.carrier = sel.value;
  if (oth) _bsEdit.other = oth.value;
  if (trk) _bsEdit.tracking = trk.value;
}

// ── 저장(한 줄) · 송장 지우기
function _bsRow(rowNo) {
  const d = _bsList && _bsList.state === 'ok' ? _bsList.data : null;
  return d ? (d.rows || []).find(r => r.row_no === rowNo) || null : null;
}
function _bsStartEdit(rowNo) {
  const r = _bsRow(rowNo);
  if (!r) return;
  _bsEdit = {
    rowNo,
    carrier: r.carrier_code || (r.carrier_other ? BRAND_SHIP_OTHER : ''),
    carrierName: r.carrier_name || '',
    other: r.carrier_other || '',
    tracking: r.tracking_no || '',
    errors: {}
  };
  _bsRerenderIfShown();
  const el = document.querySelector('#brandPageHost [data-bs-field="' + (_bsEdit.carrier ? 'tracking' : 'carrier') + '"]');
  if (el) el.focus();
}
const BRAND_SHIP_SKIP_FIELD = {
  invalid_tracking: ['tracking', 'trackingFormat'],
  carrier_required: ['carrier', 'carrierRequired'],
  invalid_carrier: ['carrier', 'carrierInvalid'],
  invalid_shipped_on: ['tracking', 'shippedOnInvalid']
};
async function _bsSave(rowNo, clear) {
  const r = _bsRow(rowNo);
  const id = _bsList && _bsList.id;
  if (!r || !id || _bsSaving) return;
  let payload;
  if (clear) {
    const ok = await brandConfirm({ title: '송장번호를 지울까요?', body: '이 분은 「발송 전」으로 돌아갑니다. 택배사·발송일도 함께 지워집니다.', okLabel: '지우기', danger: true });
    if (!ok) return;
    payload = { row_no: rowNo, expected_version: r.version, tracking_no: null };
  } else {
    _bsPullEditInputs();
    const e = _bsEdit;
    if (!e || e.rowNo !== rowNo) return;
    const errors = {};
    const track = String(e.tracking || '').trim();
    const other = String(e.other || '').trim();
    if (!e.carrier) errors.carrier = BRAND_SHIP_MSG.carrierRequired;
    else if (e.carrier === BRAND_SHIP_OTHER && !other) errors.other = BRAND_SHIP_MSG.otherRequired;
    if (!track) errors.tracking = BRAND_SHIP_MSG.trackingRequired;   // 빈 송장은 「저장」이 아니라 「송장 지우기」(D1)
    else if (!BRAND_SHIP_TRACKING_RE.test(track)) errors.tracking = BRAND_SHIP_MSG.trackingFormat;
    e.errors = errors;
    if (Object.keys(errors).length) { _bsRerenderIfShown(); return; }
    payload = {
      row_no: rowNo, expected_version: r.version,
      carrier_code: e.carrier === BRAND_SHIP_OTHER ? null : e.carrier,
      carrier_other: e.carrier === BRAND_SHIP_OTHER ? other : null,
      tracking_no: track
    };
  }
  _bsSaving = true;
  _bsRerenderIfShown();
  let res = null, failed = false;
  try {
    const { data, error } = await brandRpc('save_my_brand_shipping_rows', { p_campaign_id: id, p_rows: [payload] });
    if (error || !data) failed = true; else res = data;
  } catch (err) { failed = true; }
  _bsSaving = false;
  if (failed) { brandToast(BRAND_SHIP_MSG.saveFail, { error: true }); _bsRerenderIfShown(); return; }   // 입력한 값은 칸에 그대로
  if (res.success !== true) {
    if (res.reason === 'campaign_ended') brandToast(BRAND_SHIP_MSG.ended, { error: true });
    else brandToast(BRAND_SHIP_MSG.notFound, { error: true });
    _bsEdit = null;
    loadBrandShippingPage(id);
    return;
  }
  const skip = (res.skipped || [])[0];
  if (skip) {
    const f = BRAND_SHIP_SKIP_FIELD[skip.reason];
    if (f && _bsEdit && !clear) { _bsEdit.errors = { [f[0]]: BRAND_SHIP_MSG[f[1]] }; _bsRerenderIfShown(); return; }
    brandToast(skip.reason === 'cancelled' ? BRAND_SHIP_MSG.cancelled : skip.reason === 'version_conflict' ? BRAND_SHIP_MSG.conflict : BRAND_SHIP_MSG.notFound, { error: true });
    _bsEdit = null;
    loadBrandShippingPage(id);
    return;
  }
  const saved = (res.saved || [])[0];
  brandToast(saved && saved.cleared ? BRAND_SHIP_MSG.cleared : BRAND_SHIP_MSG.saved);
  _bsEdit = null;
  brandTouchActivity();   // 저장 성공 — 「마지막 접속」 기록(작업표 S0-4)
  loadBrandShippingPage(id);
}

// 브랜드가 바뀌면 옛 응답을 버린다(주소는 brand-campaigns.js 의 onBrandChanged 가 #campaigns 로 돌린다)
onBrandChanged(() => {
  if (_bcAutoSwitching) return;
  _bsSum = null; _bsSumSeq++;
  _bsList = null; _bsListSeq++; _bsEdit = null;
});

// 페이지 안 단추(위임)
document.addEventListener('click', (e) => {
  const el = e.target.closest('#brandPageHost [data-bs-act]');
  if (!el || el.disabled) return;
  const act = el.dataset.bsAct;
  if (act === 'retry-sum') { el.disabled = true; if (_bcDetail && _bcDetail.id) loadBrandShippingSummary(_bcDetail.id); return; }
  if (act === 'retry-list') { el.disabled = true; const id = _bsCurrentId(); if (id) loadBrandShippingPage(id); return; }
  if (act === 'tab') { _bsTab = el.dataset.tab || ''; _bsRerenderIfShown(); return; }
  if (act === 'edit') { _bsStartEdit(Number(el.dataset.row)); return; }
  if (act === 'cancel-edit') { _bsEdit = null; _bsRerenderIfShown(); return; }
  if (act === 'save') { _bsSave(Number(el.dataset.row), false); return; }
  if (act === 'clear') { _bsSave(Number(el.dataset.row), true); return; }
});
// 택배사를 바꾸면 「기타」 이름 칸을 열고 닫는다 · 입력하면 그 칸 오류를 지운다
document.addEventListener('change', (e) => {
  const el = e.target.closest && e.target.closest('#brandPageHost [data-bs-field="carrier"]');
  if (!el || !_bsEdit) return;
  _bsEdit.carrier = el.value;
  _bsEdit.errors = Object.assign({}, _bsEdit.errors, { carrier: null, other: null });
  _bsRerenderIfShown();
});
document.addEventListener('input', (e) => {
  const el = e.target.closest && e.target.closest('#brandPageHost [data-bs-field]');
  if (!el || !_bsEdit) return;
  const f = el.dataset.bsField;
  if (_bsEdit.errors && _bsEdit.errors[f]) { _bsEdit.errors[f] = null; el.classList.remove('is-error'); }
});
// 송장 칸에서 Enter = 저장 · Esc = 취소
document.addEventListener('keydown', (e) => {
  const el = e.target.closest && e.target.closest('#brandPageHost [data-bs-field]');
  if (!el || !_bsEdit) return;
  if (e.key === 'Enter' && el.tagName === 'INPUT') { e.preventDefault(); _bsSave(_bsEdit.rowNo, false); }
  else if (e.key === 'Escape') { e.preventDefault(); _bsEdit = null; _bsRerenderIfShown(); }
});
_bcMobileMq.addEventListener('change', () => _bsRerenderIfShown());
