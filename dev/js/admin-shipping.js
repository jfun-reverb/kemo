// ════════════════════════════════════════════════════════════════════
// 시딩형 「배송 리스트」 탭 — 캠페인 진행현황(관리자)
//   작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 「조각 S3」 · 사양서 ① §4-4·§4-5
//   피그마 Admin 1차 a05-09(전달 전) · a05-09a(전달 뒤) · a05-10(전달 확인) · a05-11(전달·열람 기록)
//   서버: 557 admin_get_campaign_shipping · admin_deliver_shipping_list · admin_save_shipping_rows
//         561 + 서버 함수 notify-brand-shipping-list(전달 알림 메일) · 552 기록 읽기 둘(최고 관리자만)
//
//   · 줄 상태·기한·「새로 추가」·탈퇴 표시는 서버가 정한다(_shipping_rows_payload) — 화면은 그대로 그린다
//   · 송장 형식(D6)은 화면에서도 검사하되 최종 판정은 서버(_shipping_check_row)
//   · 송장 지우기(D1) = tracking_no:null 로 저장 — 택배사·발송일도 함께 비워진다
//   · 관리자 엑셀은 주소·전화 없는 「송장 양식」 내려받기 + 올리기만(D10 의 이유 유지 — admin-shipping-excel.js, 전달 뒤에만)
//   · 「전달·열람 기록」 모달은 최고 관리자만(D26) — 초록 요약 줄은 배송 권한이 있는 모두
//   🔴 탭·단추·조회는 _brandAccountEnabled()(개발서버)일 때만 — 운영엔 554·557 이 없다. 판정은 campShippingTabOn() 한 곳
// ════════════════════════════════════════════════════════════════════

var _shipCtx = null;          // {campaignId, data(null = 조회 실패)}
var _shipStatusTab = '';      // '' | 'pending'(기한 지남 포함) | 'shipped' | 'cancelled'
var _shipEditRow = null;      // 송장 입력 모달이 다루는 줄
var _shipBusy = false;        // 저장·전달 두 번 누름 방지

// 송장번호 형식(D6) — 서버 _shipping_check_row 와 같은 식. 🔴 바꾸면 두 곳 함께
const SHIP_TRACKING_RE = /^[A-Za-z0-9 -]{4,40}$/;

// 저장에서 건너뛴 줄의 이유 → 문구(557 [L6])
const SHIP_SKIP_TEXT = {
  not_found:          '이 줄을 찾지 못했습니다. 목록을 새로 불러왔습니다.',
  duplicate:          '같은 줄이 두 번 들어와 한 번만 저장했습니다.',
  cancelled:          '선정이 취소된 분이라 저장하지 않았습니다.',
  version_conflict:   '그사이 다른 사람이 이 줄을 고쳤습니다. 목록을 새로 불러왔으니 확인한 뒤 다시 입력해 주세요.',
  invalid_tracking:   '송장번호는 영문·숫자·하이픈·띄어쓰기로 4~40자여야 합니다.',
  carrier_required:   '택배사를 골라 주세요.',
  invalid_carrier:    '택배사를 다시 골라 주세요. 목록에서 꺼진 택배사이거나 「기타」 이름이 50자를 넘습니다.',
  invalid_shipped_on: '발송일이 올바르지 않습니다.',
};

// 탭을 보일 캠페인인가 — 시딩형 + 개발서버 + 권한(숨김 아님)
function campShippingTabOn(camp) {
  if (!camp || camp.recruit_type !== 'gifting') return false;
  if (!((typeof _brandAccountEnabled === 'function') && _brandAccountEnabled())) return false;
  return !((typeof isHidden === 'function') && isHidden('shipping.manage'));
}

// 탭 숫자 — 조회 전·실패면 null(숫자를 그리지 않는다)
function campShippingTabCount() {
  if (!_shipCtx || _shipCtx.campaignId !== currentCampApplicantId) return null;
  const d = _shipCtx.data;
  return (d && d.success !== false && d.counts) ? (d.counts.total || 0) : null;
}

// 진행현황을 열 때마다 loadCampApplicants 가 부른다(기다리지 않는다)
async function loadCampShipping(campaignId) {
  const card = $('campShippingCard');
  if (!card || !campaignId) return;
  if (!_shipCtx || _shipCtx.campaignId !== campaignId) {
    _shipCtx = { campaignId: campaignId, data: undefined };
    _shipStatusTab = '';
    card.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  }
  const data = await fetchCampaignShipping(campaignId);
  if (campaignId !== currentCampApplicantId) return;   // 그사이 다른 캠페인을 열었다
  _shipCtx = { campaignId: campaignId, data: data };
  renderCampShipping();
  _shipUpdateTabCount();
  campShipFillSummaryBar();
}

// 탭 줄의 숫자만 고친다(탭 줄 전체를 다시 그리면 다른 탭 숫자를 다시 셀 재료가 없다)
function _shipUpdateTabCount() {
  const btn = document.querySelector('#campDetailTabBar .status-tab-btn[data-tab="shipping"]');
  if (!btn) return;
  const n = campShippingTabCount();
  const span = btn.querySelector('.tab-count');
  if (span) span.textContent = (n == null) ? '' : '(' + n + ')';
  btn.classList.toggle('zero-count', n === 0);
}

// 요약 카드 「배송(발송함)」 막대 — 발송함 ÷ 받는 사람(취소 제외). 받는 사람 0이면 「0 / 0」 + 빈 막대
//   카드(campOpsStatusCard)가 자리(#campOpsShipBar)를 먼저 그리고, 조회가 끝나면 여기서 채운다(둘 중 늦게 온 쪽이 그린다)
//   모양은 같은 카드의 다른 막대와 같은 campOpsCountBar(admin-applications.js — 보라 단색 · 굵은 x / y · 퍼센트 없음, 피그마 a05-06)
function campShipFillSummaryBar() {
  const el = $('campOpsShipBar');
  if (!el) return;
  if (!_shipCtx || _shipCtx.campaignId !== currentCampApplicantId || _shipCtx.data === undefined) { el.innerHTML = ''; return; }
  const d = _shipCtx.data;
  if (!d || d.success === false || !d.counts) { el.innerHTML = campOpsCountBar('배송(발송함) (불러오지 못함)', null, null); return; }
  const c = d.counts;
  const recv = (c.total || 0) - (c.cancelled || 0);
  el.innerHTML = campOpsCountBar('배송(발송함)', c.shipped || 0, recv);
}

function _shipStatusBadge(r) {
  const style = 'display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;white-space:nowrap;';
  if (r.status === 'shipped')   return '<span style="' + style + 'background:#ECFDF5;color:#047857">발송함</span>';
  if (r.status === 'overdue')   return '<span style="' + style + 'background:#FEF2F2;color:#B91C1C" title="기한 ' + esc(r.due_on ? formatDate(r.due_on) : '') + '">발송 전 · 기한 지남</span>';
  if (r.status === 'cancelled') return '<span style="' + style + 'background:#F4F4F5;color:#52525B">취소됨</span>';
  return '<span style="' + style + 'background:#FFF7ED;color:#C2410C"' + (r.due_on ? ' title="기한 ' + esc(formatDate(r.due_on)) + '"' : '') + '>발송 전</span>';
}

// 취소 줄의 이유 — 신청 상태 + 취소 사유(본인 취소일 때)
function _shipCancelText(r) {
  if (r.app_status === 'rejected') return '미승인으로 바뀜';
  if (r.app_status === 'pending')  return '심사중으로 되돌림';
  if (r.app_status === 'cancelled') {
    let label = '';
    if (r.cancel_reason_code && typeof cancelReasonLabelKo === 'function') {
      const l = cancelReasonLabelKo(r.cancel_reason_code);
      if (l && l !== r.cancel_reason_code) label = l;   // 캐시에 없으면 코드값이 오므로 그리지 않는다
    }
    return '본인 취소' + (label ? ' · ' + label : '');
  }
  return '선정 취소';
}

// SNS 계정 — 비어 있지 않은 것만(리포트·진행현황과 같은 판정 _reportAcctCell)
function _shipSnsText(sns) {
  if (!sns) return '';
  const out = [];
  [['instagram', sns.ig], ['tiktok', sns.tiktok], ['x', sns.x], ['youtube', sns.youtube]].forEach(function (p) {
    if (!p[1]) return;
    const t = (typeof _reportAcctCell === 'function') ? _reportAcctCell(p[0], p[1]).text : String(p[1]);
    if (t) out.push(t);
  });
  return out.join(' · ');
}

function _shipRowHtml(r, d) {
  const cancelled = r.status === 'cancelled';
  const dim = cancelled ? 'color:var(--muted);' : '';
  const name = r.withdrawn ? '탈퇴한 회원' : (r.name || '—');   // D25
  const sns = _shipSnsText(r.sns);
  const nameHtml = (r.influencer_id && !r.withdrawn)
    ? '<span class="link-cell" onclick="openInfluencerModal(' + jsStr(r.influencer_id) + ')">' + esc(name) + '</span>'
    : esc(name);
  const isNew = r.is_new ? ' <span style="font-size:10px;font-weight:700;padding:1px 6px;border-radius:999px;background:#EEF2FF;color:#4338CA">새로 추가</span>' : '';
  // 주소·전화 — 취소 줄은 서버가 비운다 · 권한이 없으면 서버가 비운다(선결 Q2)
  const masked = d.pii_masked && !cancelled;
  const hidden = '<span style="font-size:11px;color:var(--muted)">' + (masked ? '열람 권한 없음' : '—') + '</span>';
  const zip = r.postal_code ? esc(r.postal_code) : (masked ? hidden : '—');
  const addr = r.address ? '<div style="max-width:240px;white-space:normal;word-break:break-all">' + esc(r.address) + '</div>' : (masked ? hidden : '—');
  const phone = r.phone ? esc((typeof formatPhoneDisplay === 'function') ? formatPhoneDisplay(r.phone) : r.phone) : (masked ? hidden : '—');
  const carrier = r.carrier_name
    ? esc(r.carrier_name) + (r.carrier_active === false ? ' <span style="font-size:10px;color:var(--muted)">(목록에서 끔)</span>' : '')
    : '—';
  const by = r.updated_by_kind
    ? '<div>' + (r.updated_by_kind === 'brand' ? '브랜드' : '운영팀') + '</div><div style="font-size:11px;color:var(--muted)">' + esc(r.updated_by_name || '') + '</div>'
    : '—';
  const statusCell = _shipStatusBadge(r)
    + (cancelled ? '<div style="font-size:10px;color:var(--muted);margin-top:3px;max-width:150px;white-space:normal">' + esc(_shipCancelText(r)) + '</div>'
        + (r.cancel_reason ? '<div title="' + esc(r.cancel_reason) + '" style="font-size:10px;color:var(--muted);max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">「' + esc(r.cancel_reason) + '」</div>' : '')
        + (d.delivered_at ? '<div style="font-size:10px;color:var(--muted)">브랜드에는 주소 가림</div>' : '')
      : (r.status !== 'shipped' && r.due_on ? '<div style="font-size:10px;color:var(--muted);margin-top:3px">기한 ' + esc(formatDate(r.due_on)) + '</div>' : ''));
  const canEdit = d.can_write && !d.deleted && !cancelled;
  // 피그마 a05-09 — 줄 끝은 파란 글자 링크 모양
  const act = canEdit
    ? '<button type="button" style="background:none;border:none;padding:4px 2px;font-size:12px;color:#2563EB;cursor:pointer" onclick="openShipEditModal(' + jsStr(r.application_id) + ')">' + (r.tracking_no ? '수정' : '입력') + '</button>'
    : '';
  return '<tr data-app="' + esc(r.application_id) + '" style="' + dim + '">'
    + '<td style="' + dim + '">' + (r.row_no != null ? esc(String(r.row_no)) : '—') + '</td>'
    + '<td><div>' + nameHtml + isNew + (sns ? ' <span style="font-size:11px;color:var(--muted)">(' + esc(sns) + ')</span>' : '') + '</div>'
      + (r.name_kana ? '<div style="font-size:11px;color:var(--muted)">' + esc(r.name_kana) + '</div>' : '') + '</td>'
    + '<td style="white-space:nowrap">' + zip + '</td>'
    + '<td>' + addr + '</td>'
    + '<td style="white-space:nowrap">' + phone + '</td>'
    + '<td style="white-space:nowrap">' + carrier + '</td>'
    + '<td style="white-space:nowrap;font-family:monospace">' + (r.tracking_no ? esc(r.tracking_no) : '—') + '</td>'
    + '<td style="white-space:nowrap">' + (r.shipped_on ? esc(formatDate(r.shipped_on)) : '—') + '</td>'
    + '<td>' + statusCell + '</td>'
    + '<td style="white-space:nowrap">' + by + '</td>'
    + '<td style="white-space:nowrap">' + act + '</td>'
    + '</tr>';
}

// 이름 뒤 주격 조사 — 끝 글자가 한글이면 받침으로 「이」/「가」, 아니면 「이(가)」
function _shipSubjectParticle(name) {
  const code = String(name || '').trim().slice(-1).charCodeAt(0);
  if (!(code >= 0xAC00 && code <= 0xD7A3)) return '이(가)';
  return ((code - 0xAC00) % 28) ? '이' : '가';
}

function _shipRowMatchesTab(r) {
  if (!_shipStatusTab) return true;
  if (_shipStatusTab === 'pending') return r.status === 'pending' || r.status === 'overdue';
  return r.status === _shipStatusTab;
}

function setShipStatusTab(code) {
  _shipStatusTab = code || '';
  renderCampShipping();
}

function renderCampShipping() {
  const card = $('campShippingCard');
  if (!card || !_shipCtx) return;
  const d = _shipCtx.data;
  if (d === undefined) return;
  if (d === null) {
    card.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">배송 리스트를 불러오지 못했습니다. 잠시 뒤 새로고침해 주세요.</div>';
    return;
  }
  if (d.success === false) {
    const msg = d.reason === 'not_gifting' ? '배송 리스트는 시딩형 캠페인에만 있습니다.' : '캠페인을 찾지 못했습니다.';
    card.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">' + msg + '</div>';
    return;
  }
  const c = d.counts || {};
  const rows = Array.isArray(d.rows) ? d.rows : [];
  const tabs = [
    { code: '',          label: '전체',   n: c.total || 0 },
    { code: 'pending',   label: '발송 전', n: (c.pending || 0) + (c.overdue || 0) },
    { code: 'shipped',   label: '발송함', n: c.shipped || 0 },
    { code: 'cancelled', label: '취소됨', n: c.cancelled || 0 },
  ];
  const tabHtml = tabs.map(function (t) {
    const cls = 'status-tab-btn' + (t.code === _shipStatusTab ? ' on' : '') + (t.n === 0 && t.code !== '' ? ' zero-count' : '');
    return '<button type="button" class="' + cls + '" onclick="setShipStatusTab(' + jsStr(t.code) + ')">' + esc(t.label) + '<span class="tab-count">(' + t.n + ')</span></button>';
  }).join('');

  const isSuper = (typeof currentAdminInfo !== 'undefined' && currentAdminInfo && currentAdminInfo.role === 'super_admin');
  const delivered = !!d.delivered_at;
  const noAccount = (d.account_count || 0) === 0;
  let actions = '';
  if (!delivered && d.can_write && !d.deleted) {
    actions = '<button type="button" class="btn btn-primary btn-sm" style="flex-shrink:0" ' + (noAccount ? 'disabled title="비밀번호를 정한 브랜드 계정이 없습니다"' : 'onclick="openShipDeliverModal()"') + '>'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">send</span> 배송 리스트 전달</button>';
  }
  if (typeof shipXlAdminButtonsHtml === 'function') actions += shipXlAdminButtonsHtml(d);   // 전달 뒤 송장 양식·엑셀 올리기(admin-shipping-excel.js)

  let banner = '';
  if (d.deleted) {
    banner = '<div style="margin:0 16px 10px;padding:10px 14px;border-radius:10px;background:#F4F4F5;color:#52525B;font-size:12px">삭제된(보관 중인) 캠페인입니다. 전달·송장 입력은 할 수 없습니다.</div>';
  } else if (!delivered) {
    banner = '<div style="margin:0 16px 10px;padding:10px 14px;border-radius:10px;background:#FFF7ED;border:1px solid #FED7AA;color:#C2410C;font-size:12px;display:flex;gap:8px;align-items:center">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:18px">schedule</span>'
      + '<span>아직 브랜드에 전달하지 않았습니다. 선정을 마친 뒤 「배송 리스트 전달」을 누르면 브랜드 페이지에 열립니다. 전달 뒤 승인하는 분은 자동으로 추가됩니다.</span></div>';
    // D11 — 계정이 없으면 단추를 흐리게 하고 바로 옆에 이유 + 브랜드 상세 바로가기
    if (noAccount && d.can_write) {
      banner += '<div style="margin:0 16px 10px;padding:10px 14px;border-radius:10px;background:#FEF2F2;border:1px solid #FECACA;color:#B91C1C;font-size:12px;display:flex;gap:8px;align-items:center;flex-wrap:wrap">'
        + '<span class="material-icons-round notranslate" translate="no" style="font-size:18px">person_off</span>'
        + '<span>이 브랜드에 비밀번호를 정한 계정이 없어 전달할 수 없습니다.</span>'
        + (d.brand_id ? '<button type="button" class="btn btn-ghost btn-xs" style="margin-left:auto" onclick="openBrandDetail(' + jsStr(d.brand_id) + ')">브랜드 상세 열기</button>' : '')
        + '</div>';
    }
  } else {
    const ps = d.provision_summary || {};
    // 피그마 a05-09a — 「2026/10/13 15:20 박매니저가 브랜드에 전달했습니다 · 브랜드 열람 4회 · 엑셀 내려받기 1회(…)」
    const byName = d.delivered_by_name || '운영팀';
    const parts = [esc(formatDateTime(d.delivered_at)) + ' ' + esc(byName) + _shipSubjectParticle(byName) + ' 브랜드에 전달했습니다'];
    parts.push('브랜드 열람 ' + (ps.view_count || 0) + '회');
    parts.push('엑셀 내려받기 ' + (ps.excel_count || 0) + '회' + (ps.last_excel_at ? '(' + esc(formatDateTime(ps.last_excel_at)) + (ps.last_excel_by ? ' ' + esc(ps.last_excel_by) : '') + ')' : ''));
    // D26 — 기록 모달(사람 목록)은 최고 관리자만
    const logLink = isSuper
      ? '<button type="button" class="btn btn-ghost btn-xs" style="margin-left:auto;color:#047857;font-weight:700;flex-shrink:0" onclick="openShipLogModal()">전달·열람 기록</button>'
      : '<span style="margin-left:auto;font-size:11px;color:#047857;opacity:.8;flex-shrink:0">기록 보기는 최고 관리자만</span>';
    banner = '<div style="margin:0 16px 10px;padding:10px 14px;border-radius:10px;background:#ECFDF5;border:1px solid #A7F3D0;color:#047857;font-size:12px;display:flex;gap:8px;align-items:center">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:18px">check_circle</span>'
      + '<span>' + parts.join(' · ') + '</span>' + logLink + '</div>';
  }
  if (d.pii_masked) {
    banner += '<div style="margin:0 16px 10px;font-size:11px;color:var(--muted)">우편번호·주소·전화번호는 민감정보 열람 권한이 있는 등급에만 보입니다.</div>';
  }

  const shown = rows.filter(_shipRowMatchesTab);
  const body = shown.length
    ? shown.map(function (r) { return _shipRowHtml(r, d); }).join('')
    : '<tr><td colspan="11" style="text-align:center;color:var(--muted);padding:32px">'
        + (rows.length ? '이 상태의 줄이 없습니다' : (delivered ? '리스트에 든 분이 없습니다' : '아직 승인된 분이 없습니다')) + '</td></tr>';
  const foot = delivered
    ? '관리자 표에는 SNS 계정과 취소 이유가 함께 보이지만 브랜드 화면에는 이름·우편번호·주소·전화번호만 보입니다. 운영팀이 넣은 송장도 브랜드 화면에 바로 보입니다.'
    : '전달 전에는 이 표가 관리자에게만 보입니다. 배송지는 응모할 때 확인한 주소입니다(그 뒤 마이페이지에서 바꾼 주소가 아닙니다).';

  card.innerHTML =
    '<div style="display:flex;align-items:center;gap:8px;margin:12px 16px 8px;border-bottom:1px solid var(--surface-dim)">'
    + '<div class="status-tab-bar" style="flex:1;margin-bottom:0;border-bottom:none">' + tabHtml + '</div>' + actions + '</div>'
    + banner
    + '<div class="admin-table-wrap"><table class="data-table"><thead><tr>'
    + '<th style="width:44px">No</th><th>인플루언서</th><th>우편번호</th><th>주소</th><th>전화번호</th><th>택배사</th><th>송장번호</th><th>발송일</th><th>상태</th><th>입력한 사람</th><th></th>'
    + '</tr></thead><tbody>' + body + '</tbody></table></div>'
    + '<div style="padding:8px 16px 12px;font-size:11px;color:var(--muted)">' + foot + '</div>';
}

// ── 모달 공용 ────────────────────────────────────────────────────
function _shipEnsureModal(id, title, maxWidth) {
  let m = document.getElementById(id);
  if (m) { m.querySelector('.ship-modal-title').textContent = title; return m; }
  const wrap = document.createElement('div');
  wrap.innerHTML = `
  <div class="modal-overlay" id="${id}">
    <div class="modal" style="max-width:${maxWidth}px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2 class="ship-modal-title"></h2>
        <button type="button" class="modal-close-btn" onclick="closeModal('${id}')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body ship-modal-body" style="padding:20px;overflow-y:auto;flex:1"></div>
      <div class="modal-footer ship-modal-foot" style="padding:14px 20px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end;align-items:center"></div>
    </div>
  </div>`;
  m = wrap.firstElementChild;
  document.body.appendChild(m);
  m.querySelector('.ship-modal-title').textContent = title;
  return m;
}

// ── 송장 입력·수정·지우기 ─────────────────────────────────────────
function openShipEditModal(appId) {
  const d = _shipCtx && _shipCtx.data;
  if (!d || !Array.isArray(d.rows)) return;
  const r = d.rows.find(function (x) { return x.application_id === appId; });
  if (!r) return;
  _shipEditRow = r;
  const name = r.withdrawn ? '탈퇴한 회원' : (r.name || '');
  const m = _shipEnsureModal('shipEditModal', (r.tracking_no ? '송장 수정' : '송장 입력') + (name ? ' — ' + name : ''), 480);
  const carriers = Array.isArray(d.carriers) ? d.carriers.slice() : [];
  // 목록에서 꺼진 택배사로 저장된 줄 — 이름은 보이되 다시 고를 수는 없다(서버가 거부한다)
  let opts = '<option value="">택배사 고르기</option>';
  carriers.forEach(function (cr) { opts += '<option value="' + esc(cr.code) + '"' + (cr.code === r.carrier_code ? ' selected' : '') + '>' + esc(cr.name) + '</option>'; });
  if (r.carrier_code && !carriers.some(function (cr) { return cr.code === r.carrier_code; })) {
    opts += '<option value="' + esc(r.carrier_code) + '" selected disabled>' + esc(r.carrier_name || r.carrier_code) + ' (목록에서 끔 — 다시 골라 주세요)</option>';
  }
  opts += '<option value="__other"' + (!r.carrier_code && r.carrier_other ? ' selected' : '') + '>기타(직접 입력)</option>';
  const isOther = !r.carrier_code && !!r.carrier_other;
  m.querySelector('.ship-modal-body').innerHTML = `
    <div style="display:flex;flex-direction:column;gap:14px">
      <label style="font-size:13px;font-weight:600">택배사
        <select id="shipEditCarrier" class="form-input" style="margin-top:6px" onchange="_shipToggleOther()">${opts}</select></label>
      <label id="shipEditOtherWrap" style="font-size:13px;font-weight:600;display:${isOther ? '' : 'none'}">택배사 이름
        <input id="shipEditOther" class="form-input" style="margin-top:6px" maxlength="50" value="${esc(r.carrier_other || '')}" placeholder="예: ○○ 국제특송"></label>
      <label style="font-size:13px;font-weight:600">송장번호
        <input id="shipEditTracking" class="form-input" style="margin-top:6px;font-family:monospace" maxlength="40" value="${esc(r.tracking_no || '')}" placeholder="영문·숫자·하이픈·띄어쓰기 4~40자"></label>
      <label style="font-size:13px;font-weight:600">발송일
        <input id="shipEditDate" type="date" class="form-input" style="margin-top:6px" value="${esc(r.shipped_on || d.today || '')}"></label>
      <div id="shipEditError" style="display:none;font-size:12px;color:var(--red)"></div>
      <div style="font-size:11px;color:var(--muted)">${d.delivered_at ? '저장하면 브랜드 화면에 바로 보이고' : '전달한 뒤에는 브랜드 화면에도 보이고'}, 「입력한 사람」에 운영팀으로 남습니다.</div>
    </div>`;
  m.querySelector('.ship-modal-foot').innerHTML =
    (r.tracking_no ? '<button type="button" class="btn btn-ghost" id="shipEditClearBtn" style="margin-right:auto;color:var(--red);border-color:var(--red)" onclick="_shipAskClear()">송장 지우기</button>' : '')
    + '<button type="button" class="btn btn-ghost" onclick="closeModal(\'shipEditModal\')">취소</button>'
    + '<button type="button" class="btn btn-primary" id="shipEditSaveBtn" onclick="saveShipEdit()">저장</button>';
  openModal('shipEditModal');
}

function _shipToggleOther() {
  const sel = $('shipEditCarrier');
  const wrap = $('shipEditOtherWrap');
  if (sel && wrap) wrap.style.display = sel.value === '__other' ? '' : 'none';
}

function _shipEditError(msg) {
  const el = $('shipEditError');
  if (!el) return;
  el.textContent = msg || '';
  el.style.display = msg ? '' : 'none';
}

// 「송장 지우기」 — 한 번 더 누르게 해 실수를 막는다(D1: 「발송 전」으로 돌아간다)
function _shipAskClear() {
  const btn = $('shipEditClearBtn');
  if (!btn) return;
  if (btn.dataset.armed === '1') { saveShipEdit(true); return; }
  btn.dataset.armed = '1';
  btn.textContent = '정말 지울까요? 한 번 더 누르면 지웁니다';
  btn.style.background = 'var(--red)';
  btn.style.color = '#fff';
}

async function saveShipEdit(clear) {
  const r = _shipEditRow;
  const campId = _shipCtx && _shipCtx.campaignId;
  if (!r || !campId || _shipBusy) return;
  let row;
  if (clear) {
    row = { application_id: r.application_id, expected_version: r.version == null ? null : r.version, tracking_no: null };
  } else {
    const sel = ($('shipEditCarrier') || {}).value || '';
    const other = (($('shipEditOther') || {}).value || '').trim();
    const track = (($('shipEditTracking') || {}).value || '').trim();
    const date = ($('shipEditDate') || {}).value || '';
    if (!sel) { _shipEditError('택배사를 골라 주세요.'); return; }
    if (sel === '__other' && !other) { _shipEditError('「기타」를 골랐으면 택배사 이름을 적어 주세요.'); return; }
    if (!track) { _shipEditError('송장번호를 적어 주세요. 송장을 없애려면 「송장 지우기」를 누릅니다.'); return; }
    if (!SHIP_TRACKING_RE.test(track)) { _shipEditError(SHIP_SKIP_TEXT.invalid_tracking); return; }
    row = {
      application_id: r.application_id,
      expected_version: r.version == null ? null : r.version,
      carrier_code: sel === '__other' ? null : sel,
      carrier_other: sel === '__other' ? other : null,
      tracking_no: track,
      shipped_on: date || null,
    };
  }
  _shipEditError('');
  _shipBusy = true;
  const saveBtn = $('shipEditSaveBtn'); if (saveBtn) saveBtn.disabled = true;
  try {
    const res = await saveShippingRows(campId, [row]);
    if (!res || res.ok === false) {
      _shipEditError(res && res.reason === 'not_gifting' ? '시딩형 캠페인이 아닙니다.' : '캠페인을 찾지 못했습니다.');
      return;
    }
    const skipped = Array.isArray(res.skipped) ? res.skipped : [];
    if (skipped.length) {
      const reason = skipped[0].reason;
      // 형식 문제는 모달에 남겨 고치게 하고, 충돌·취소·없음은 닫고 다시 불러온다
      if (reason === 'invalid_tracking' || reason === 'carrier_required' || reason === 'invalid_carrier' || reason === 'invalid_shipped_on') {
        _shipEditError(SHIP_SKIP_TEXT[reason]);
        return;
      }
      closeModal('shipEditModal');
      toast(SHIP_SKIP_TEXT[reason] || '저장하지 못했습니다.', 'error');
    } else {
      closeModal('shipEditModal');
      const saved = (res.saved || [])[0];
      toast(saved && saved.cleared ? '송장을 지웠습니다. 「발송 전」으로 돌아갔습니다.' : '송장번호를 저장했습니다.');
    }
    await refreshPane('camp-applicants');
  } catch (e) {
    _shipEditError(friendlyError(e && e.message));
  } finally {
    _shipBusy = false;
    const b = $('shipEditSaveBtn'); if (b) b.disabled = false;
  }
}

// ── 배송 리스트 전달(a05-10) ─────────────────────────────────────
function openShipDeliverModal() {
  const d = _shipCtx && _shipCtx.data;
  if (!d || d.success === false || d.delivered_at || !d.can_write) return;
  if ((d.account_count || 0) === 0) { toast('브랜드 페이지 계정이 없어 전달할 수 없습니다.', 'error'); return; }
  const camp = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns.find(function (c) { return c.id === _shipCtx.campaignId; }) : null;
  const brand = (camp && (camp.brand_ko || camp.brand)) || '';
  const n = ((d.counts && d.counts.total) || 0) - ((d.counts && d.counts.cancelled) || 0);
  // 선정 0명이면 전달하지 않는다(전달은 되돌릴 수 없고 「0명」 알림 메일이 나간다 — 화면에서만 막음)
  if (n <= 0) { toast('선정된 분이 없어 전달할 수 없습니다. 선정을 마친 뒤 전달해 주세요.', 'error'); return; }
  // 메일 제품명은 서버(561)가 product_ko → product → title 순으로 고른다 — 한국어 제품명이 비면 일본어가 나간다
  const mailProduct = camp ? (String(camp.product_ko || '').trim() || String(camp.product || '').trim() || String(camp.title || '').trim()) : '';
  const productNote = (camp && !String(camp.product_ko || '').trim() && mailProduct)
    ? `<br>· 한국어 제품명이 비어 있어 알림 메일에 「${esc(mailProduct)}」(일본어)가 들어갑니다. 바꾸려면 캠페인 편집에서 한국어 제품명을 먼저 넣어 주세요.`
    : '';
  const m = _shipEnsureModal('shipDeliverModal', '배송 리스트를 브랜드에 전달하시겠습니까?', 520);
  m.querySelector('.ship-modal-body').innerHTML = `
    <div style="font-size:13px;line-height:1.7;color:var(--ink)">${brand ? '「' + esc(brand) + '」 브랜드' : '이 브랜드'} 페이지 계정 <b>${d.account_count}명</b>에게 선정된 <b>${n}명</b>의 이름·우편번호·주소·전화번호가 보이고, 엑셀로 내려받을 수 있게 됩니다.</div>
    <div style="margin-top:12px;padding:12px 14px;border-radius:10px;background:var(--surface-container-low, #F7F7F8);font-size:12px;line-height:1.8;color:var(--muted)">
      · 전달한 뒤 승인하는 분은 자동으로 추가됩니다.<br>
      · 선정이 취소된 분은 「취소됨」으로 남고 주소·전화번호는 가려집니다.<br>
      · 누가 언제 전달했는지, 브랜드가 언제 열고 내려받았는지 기록이 남습니다.<br>
      · ${brand ? '「' + esc(brand) + '」 ' : ''}계정 ${d.account_count}명에게 알림 메일이 갑니다. <b style="color:var(--ink)">전달은 되돌릴 수 없습니다.</b>${productNote}
    </div>`;
  m.querySelector('.ship-modal-foot').innerHTML =
    '<button type="button" class="btn btn-ghost" onclick="closeModal(\'shipDeliverModal\')">취소</button>'
    + '<button type="button" class="btn btn-primary" id="shipDeliverBtn" onclick="runShipDeliver()">전달하기</button>';
  openModal('shipDeliverModal');
}

// 전달 알림 메일 결과 → 안내(전달 성공은 무르지 않는다 — 작업표 S3)
function _shipMailToast(res) {
  if (!res) return;
  if (res.sent) { const cnt = (res.recipients || []).length; toast(cnt ? '브랜드 계정 ' + cnt + '명에게 알림 메일을 보냈습니다.' : '브랜드 계정에 알림 메일을 보냈습니다.'); return; }
  if (res.reason === 'not_claimed') return;   // 이미 보냈거나 다른 실행이 보내는 중
  if (res.reason === 'disabled' || res.reason === 'brand_account_disabled') { toast('알림 메일은 이 서버에서 꺼져 있어 보내지 않았습니다. 전달은 완료되었습니다.'); return; }
  if (res.reason === 'no_account') { toast('알림 메일을 받을 계정이 없어 메일은 보내지 않았습니다. 전달은 완료되었습니다.', 'error'); return; }
  toast('알림 메일을 보내지 못했습니다. 전달은 완료되었습니다.', 'error');
}

async function runShipDeliver() {
  const campId = _shipCtx && _shipCtx.campaignId;
  if (!campId || _shipBusy) return;
  _shipBusy = true;
  const btn = $('shipDeliverBtn'); if (btn) btn.disabled = true;
  // 피그마 a05-90a — 연결·서버 오류는 모달을 닫지 않고 다시 누르게 한다
  const RETRY_MSG = '전달하지 못했습니다. 잠시 뒤 다시 시도해 주십시오.';
  try {
    const res = await deliverShippingList(campId);
    const reason = res && res.ok === false ? res.reason : null;
    const known = reason === 'not_found' || reason === 'no_account' || reason === 'campaign_deleted' || reason === 'not_gifting' || reason === 'results_suspended';
    if (!res || (res.ok === false && !known)) {
      toast(RETRY_MSG, 'error');
      return;
    }
    closeModal('shipDeliverModal');
    if (res.ok === false) {
      toast(reason === 'no_account' ? '브랜드 페이지 계정이 없어 전달할 수 없습니다.'
          : reason === 'campaign_deleted' ? '삭제된 캠페인이라 전달할 수 없습니다.'
          : reason === 'not_gifting' ? '시딩형 캠페인만 전달할 수 있습니다.'
          : reason === 'not_found' ? '캠페인을 찾지 못했습니다.'
          // 「배송 리스트 포함」 결과물 열람 정지 중 — 서버가 전달·메일·제공 기록을 모두 막는다(이용 제한 사양서 R7 · 작업표 제한 13-a)
          : '이 브랜드는 배송 리스트까지 열람이 정지되어 전달할 수 없습니다. 정지를 풀거나 배송 미포함으로 다시 걸어 주십시오.', 'error');
    } else if (res.delivered_now) {
      toast('배송 리스트를 브랜드에 전달했습니다.');
      // 두 관리자가 동시에 눌러도 delivered_now:true 는 서버가 한 번만 준다 — 메일도 한 번
      sendShippingDeliveredMail(campId).then(_shipMailToast);
    } else {
      toast('이미 전달된 리스트입니다.');
    }
    await refreshPane('camp-applicants');
  } catch (e) {
    // 권한 거부는 다시 눌러도 같으니 그 이유를 그대로 보인다
    toast(e && e.code === '42501' ? friendlyError(e.message) : RETRY_MSG, 'error');
  } finally {
    _shipBusy = false;
    const b = $('shipDeliverBtn'); if (b) b.disabled = false;
  }
}

// ── 전달·열람 기록(a05-11 — 최고 관리자만, D5·D26) ─────────────────
const SHIP_LOG_ACTION_TEXT = {
  shipping_deliver:  '배송 리스트 전달',
  shipping_auto_add: '새로 승인된 분 추가',
  shipping_view:     '배송 리스트 열람',
  shipping_excel:    '엑셀 내려받기',
};

async function openShipLogModal() {
  const campId = _shipCtx && _shipCtx.campaignId;
  if (!campId) return;
  if (!(typeof currentAdminInfo !== 'undefined' && currentAdminInfo && currentAdminInfo.role === 'super_admin')) {
    toast('기록 보기는 최고 관리자만 할 수 있습니다.', 'error');
    return;
  }
  const camp = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns.find(function (c) { return c.id === campId; }) : null;
  const m = _shipEnsureModal('shipLogModal', '전달·열람 기록' + (camp && camp.title ? ' — ' + camp.title : ''), 640);
  const body = m.querySelector('.ship-modal-body');
  body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  m.querySelector('.ship-modal-foot').innerHTML = '<button type="button" class="btn btn-primary btn-sm" onclick="closeModal(\'shipLogModal\')">닫기</button>';
  openModal('shipLogModal');
  // 같은 캠페인의 결과물 열람 기록도 같은 표에 있다 — 종류마다 서버에서 걸러 받아(결과물 기록에 밀려 잘리지 않게) 합친 뒤 최근 50줄
  const parts = await Promise.all(Object.keys(SHIP_LOG_ACTION_TEXT).map(function (a) {
    return fetchBrandProvisionLogs({ campaign_id: campId, action: a, limit: 50 });
  }));
  if (!document.getElementById('shipLogModal')?.classList.contains('open')) return;
  if (parts.some(function (p) { return !p; })) { body.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">기록을 불러오지 못했습니다. 잠시 뒤 다시 열어 주세요.</div>'; return; }
  const rows = [].concat.apply([], parts.map(function (p) { return p.rows; }))
    .sort(function (a, b) { return a.at < b.at ? 1 : a.at > b.at ? -1 : 0; }).slice(0, 50);
  const who = function (l) {
    if (l.actor_kind === 'system') return '자동';
    return (l.actor_kind === 'brand' ? '브랜드 ' : '운영팀 ') + (l.actor_name || '');
  };
  const tr = rows.map(function (l) {
    // 자동 추가는 「새로 승인된 N명 추가」(피그마 a05-11) — 나머지는 「무엇 (N명)」
    const what = (l.action === 'shipping_auto_add' && l.person_count)
      ? '새로 승인된 ' + l.person_count + '명 추가'
      : SHIP_LOG_ACTION_TEXT[l.action] + (l.person_count ? ' (' + l.person_count + '명)' : '');
    const btn = l.person_count ? '<button type="button" class="btn btn-ghost btn-xs" onclick="toggleShipLogPersons(this, ' + jsStr(l.id) + ')">사람 보기</button>' : '';
    return '<tr><td style="white-space:nowrap">' + esc(formatDateTime(l.at)) + '</td><td>' + esc(who(l)) + '</td><td>' + esc(what) + '</td><td style="text-align:right">' + btn + '</td></tr>'
      + '<tr class="ship-log-persons" data-log="' + esc(l.id) + '" style="display:none"><td colspan="4" style="background:var(--surface-container-low, #F7F7F8);font-size:12px;color:var(--muted)"></td></tr>';
  }).join('');
  body.innerHTML = '<div style="font-size:12px;color:var(--muted);margin-bottom:12px;line-height:1.6">브랜드에 인플루언서 정보(이름·주소·전화번호)를 준 기록입니다. 일본 개인정보보호법의 제3자 제공 기록으로 3년 보관합니다.</div>'
    + '<div class="admin-table-wrap"><table class="data-table"><thead><tr><th>일시</th><th>누가</th><th>무엇을</th><th></th></tr></thead><tbody>'
    + (tr || '<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:24px">아직 기록이 없습니다</td></tr>')
    + '</tbody></table></div>'
    // D5 — 최근 50줄 너머는 개인정보 기록 화면에서(이 캠페인의 브랜드로 걸러 연다 · 조각 R3)
    + ((typeof openPrivacyLogs === 'function' && camp && camp.brand_id)
        ? '<div style="margin-top:10px;text-align:right"><button type="button" class="btn btn-ghost btn-xs" onclick="closeModal(\'shipLogModal\');openPrivacyLogs({brandId:' + jsStr(camp.brand_id) + ',brandName:' + jsStr(camp.brand || '') + '})">개인정보 기록 화면에서 더 보기 →</button></div>'
        : '');
}

async function toggleShipLogPersons(btn, logId) {
  const row = document.querySelector('#shipLogModal tr.ship-log-persons[data-log="' + CSS.escape(String(logId)) + '"]');
  if (!row) return;
  if (row.style.display !== 'none') { row.style.display = 'none'; btn.textContent = '사람 보기'; return; }
  row.style.display = '';
  btn.textContent = '접기';
  const cell = row.firstElementChild;
  if (cell.dataset.loaded === '1') return;
  cell.textContent = '불러오는 중…';
  const persons = await fetchBrandProvisionPersons(logId);
  if (!persons) { cell.textContent = '사람 목록을 불러오지 못했습니다.'; return; }
  cell.dataset.loaded = '1';
  cell.textContent = persons.length ? persons.map(function (p) { return p.name || '(이름 없음)'; }).join(' · ') : '사람 목록이 비어 있습니다.';
}
