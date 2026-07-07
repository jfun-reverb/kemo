// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-settlements.js
// ═════════════════════════════════════════════════════════════════
//
// 정산 관리 페인 (인플루언서 리워드 송금 — 사양서 2026-06-22-influencer-settlement.md §7-1).
//   · 인증 성공 응모 → 정산행 자동 생성(백필 RPC, B안) 후 목록/필터/검색
//   · 상태 4종: pending(정산대기)/paid(송금완료)/on_hold(보류)/cancelled(취소). 통화 = 엔화(¥)
//   · 송금 완료 / 보류 / 취소 처리 모달 (낙관적 락 — 버전 충돌 시 "이미 처리됨" 후 재조회)
//   · 엑셀 내보내기 (현재 필터 결과)
//
// ⚠ storage.js 정산 함수(fetchSettlements/backfillSettlements/markSettlement*)는 호출만 — 재정의 금지.
// ⚠ loadSettlements 는 switchAdminPane(admin-core.js) loaders 가, refreshSettlementSidebarBadge 는
//   부팅(admin/app.js) + 대시보드 loadAdminData 가 호출 → 전역 유지(이름 변경 금지). 빌드 순서상 admin.js 앞.
// ═════════════════════════════════════════════════════════════════

let _settlements = [];
let _settlementsLoaded = false;
let _settlementFilters = { status: 'pending', campaignId: '', search: '' };
let _settlementModalCtx = null;  // 열려 있는 처리 모달 대상 {id, version, mode?}
var settlementsLazy = null;
const SETTLEMENTS_PAGE_SIZE = 50;

// 상태 → 한국어 라벨 + 배지 클래스 (components.css 공용 badge-*)
const SETTLEMENT_STATUS_META = {
  pending:   { ko: '정산대기', cls: 'badge-gold'  },
  paid:      { ko: '송금완료', cls: 'badge-green' },
  on_hold:   { ko: '보류',     cls: 'badge-gray'  },
  cancelled: { ko: '취소',     cls: 'badge-gray'  },
};

function settlementStatusKo(status) {
  return (SETTLEMENT_STATUS_META[status] || {}).ko || status || '';
}
function settlementStatusBadge(status) {
  const meta = SETTLEMENT_STATUS_META[status] || { ko: status, cls: 'badge-gray' };
  return `<span class="badge ${meta.cls}" style="font-size:11px;white-space:nowrap">${esc(meta.ko)}</span>`;
}
function settlementAmountYen(v) {
  return '¥' + (Number(v) || 0).toLocaleString();
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 로드 / 조회 / 렌더
// ════════════════════════════════════════════════════════════════════

// 페인 진입 로더 — ①인증성공 응모 백필(멱등, best-effort) ②전건 조회 ③렌더 + 배지
async function loadSettlements() {
  try {
    const r = await backfillSettlements();
    if (r && r.created_count > 0 && typeof toast === 'function') {
      toast(`인증 성공 ${r.created_count}건을 정산 대기로 추가했습니다`, 'info');
    }
  } catch (e) {
    // 권한 없음(campaign_manager)·RPC 실패 등은 무시 — 기존 정산행은 그대로 조회한다.
  }
  await reloadSettlementsData();
}

// 데이터 재조회(백필 없음) — 처리 모달 저장 후 refreshPane('settlements') 가 호출
async function reloadSettlementsData() {
  _settlements = await fetchSettlements({});
  _settlementsLoaded = true;
  renderSettlementsList();
  refreshSettlementSidebarBadge();
}

function readSettlementFilters() {
  const st = $('settlementFilterStatus');
  _settlementFilters.status = st ? st.value : 'pending';
  const camp = $('settlementFilterCampaign');
  _settlementFilters.campaignId = camp ? (camp.value || '') : '';
  const q = $('settlementSearch');
  _settlementFilters.search = q ? (q.value || '').trim().toLowerCase() : '';
}

// 현재 필터 조건으로 _settlements 를 거른 배열 반환 (목록·합계·엑셀 공용)
function getFilteredSettlements() {
  readSettlementFilters();
  const { status, campaignId, search } = _settlementFilters;
  let rows = _settlements.slice();
  if (status) rows = rows.filter(s => s.status === status);
  if (campaignId) rows = rows.filter(s => s.campaign_id === campaignId);
  if (search) rows = rows.filter(s => {
    const inf = s.influencers || {};
    return matchSearchTokens(search, [inf.name, inf.name_kana, inf.email]);
  });
  return rows;
}

// 캠페인 필터 select 옵션 동기화 — 현재 로드된 정산행의 distinct 캠페인 (선택값 보존)
function syncSettlementCampaignOptions() {
  const sel = $('settlementFilterCampaign');
  if (!sel) return;
  const prev = sel.value;
  const seen = new Map();
  _settlements.forEach(s => {
    const c = s.campaigns;
    if (c && c.id && !seen.has(c.id)) seen.set(c.id, c);
  });
  const opts = ['<option value="">전체 캠페인</option>'];
  [...seen.values()].forEach(c => {
    const label = (c.campaign_no ? c.campaign_no + ' · ' : '') + (c.title || '캠페인');
    opts.push(`<option value="${esc(c.id)}">${esc(label)}</option>`);
  });
  sel.innerHTML = opts.join('');
  sel.value = (prev && seen.has(prev)) ? prev : '';
}

function renderSettlementsList() {
  const tbody = $('settlementsTableBody');
  if (!tbody) return;
  syncSettlementCampaignOptions();
  const rows = getFilteredSettlements();  // readSettlementFilters 내부 호출

  const cnt = $('settlementsTotalCount');
  if (cnt) cnt.textContent = `총 ${rows.length}건`;
  const sumEl = $('settlementsSumAmount');
  if (sumEl) {
    const sum = rows.reduce((acc, s) => acc + (Number(s.amount_jpy) || 0), 0);
    sumEl.textContent = rows.length ? `합계 ${settlementAmountYen(sum)}` : '';
  }

  // 정렬은 fetchSettlements 가 created_at 오름차순(오래된 순)으로 이미 반환 — filter 는 순서 보존
  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (settlementsLazy) settlementsLazy.destroy();
  settlementsLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows,
    renderRow: renderSettlementRow,
    pageSize: SETTLEMENTS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 정산 건이 없습니다.</td></tr>',
  });
}

function renderSettlementRow(s) {
  const inf = s.influencers || {};
  const camp = s.campaigns || {};

  const infName = esc(inf.name || '—');
  const auditB = (typeof auditBadgeHtml === 'function') ? auditBadgeHtml(inf) : '';
  const infSub = [inf.name_kana ? esc(inf.name_kana) : '', inf.email ? esc(inf.email) : '']
    .filter(Boolean).join(' · ');
  const infCell = `<div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${esc(inf.id || '')}')">${infName}${auditB}</div>${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}`;

  const campNo = camp.campaign_no
    ? `<div><span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted)">${esc(camp.campaign_no)}</span></div>`
    : '';
  const campCell = `${campNo}<div style="font-size:13px">${esc(camp.title || '—')}</div>`;

  // PayPal — 정산행 스냅샷(직접 컬럼). 미등록이면 빨간 경고 배지(송금 불가).
  const paypalCell = s.paypal_email
    ? `<span style="font-size:12px;word-break:break-all">${esc(s.paypal_email)}</span>`
    : `<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:1px 6px;border-radius:3px;border:1px solid #C33" title="PayPal 미등록 — 송금 불가">미등록</span>`;

  const certDate = s.created_at
    ? `<span style="font-size:12px">${formatDate(s.created_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">—</span>';
  const paidDate = s.paid_at
    ? `<span style="font-size:12px">${formatDate(s.paid_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">—</span>';

  return `<tr class="${inf.is_audit ? 'audit-row' : ''}">
    <td>${infCell}</td>
    <td>${campCell}</td>
    <td style="font-weight:700;color:var(--ink);white-space:nowrap">${settlementAmountYen(s.amount_jpy)}</td>
    <td>${paypalCell}</td>
    <td>${settlementStatusBadge(s.status)}</td>
    <td>${certDate}</td>
    <td>${paidDate}</td>
    <td>${settlementActionCell(s)}</td>
  </tr>`;
}

// 상태 전이 규칙에 따른 처리 버튼:
//   pending  → 송금 완료 / 보류 / 취소
//   paid     → 보류 (환수·인증깨짐 대응)
//   on_hold  → 취소
//   cancelled→ 없음(종료)
function settlementActionCell(s) {
  const id = esc(s.id);
  const btns = [];
  if (s.status === 'pending') {
    btns.push(`<button class="btn btn-primary btn-xs" onclick="openSettlementPayModal('${id}')">송금 완료</button>`);
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementHoldModal('${id}')">보류</button>`);
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementCancelModal('${id}')" style="color:#C33">취소</button>`);
  } else if (s.status === 'paid') {
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementHoldModal('${id}')">보류</button>`);
  } else if (s.status === 'on_hold') {
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementCancelModal('${id}')" style="color:#C33">취소</button>`);
  }
  return btns.length
    ? `<div style="display:flex;gap:4px;flex-wrap:wrap">${btns.join('')}</div>`
    : '<span style="font-size:11px;color:var(--muted)">—</span>';
}

// 사이드바 "정산 관리" 메뉴 옆 정산대기(pending) 건수 배지
async function refreshSettlementSidebarBadge() {
  const badge = $('adminSettlementsBadge');
  if (!badge) return;
  try {
    let n;
    if (_settlementsLoaded && Array.isArray(_settlements)) {
      n = _settlements.filter(s => s.status === 'pending').length;
    } else {
      const rows = await fetchSettlements({ status: 'pending' });
      n = rows.length;
    }
    if (n > 0) { badge.textContent = n > 999 ? '999+' : String(n); badge.style.display = ''; }
    else { badge.style.display = 'none'; }
  } catch (e) { /* 무시 */ }
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 송금 완료 처리 (낙관적 락)
// ════════════════════════════════════════════════════════════════════

function openSettlementPayModal(id) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  _settlementModalCtx = { id: s.id, version: s.version };
  const inf = s.influencers || {};
  const camp = s.campaigns || {};
  const hasPaypal = !!s.paypal_email;

  const body = $('settlementPayBody');
  if (body) {
    body.innerHTML = `
      <div style="display:grid;grid-template-columns:auto 1fr;gap:8px 14px;font-size:13px;margin-bottom:16px">
        <div style="color:var(--muted)">인플루언서</div>
        <div style="font-weight:600">${esc(inf.name || '—')}${inf.name_kana ? ` <span style="font-size:11px;color:var(--muted)">${esc(inf.name_kana)}</span>` : ''}</div>
        <div style="color:var(--muted)">캠페인</div>
        <div>${esc(camp.title || '—')}</div>
        <div style="color:var(--muted)">송금 금액</div>
        <div style="font-weight:700;font-size:18px;color:var(--ink)">${settlementAmountYen(s.amount_jpy)}</div>
        <div style="color:var(--muted)">PayPal</div>
        <div style="font-weight:600;word-break:break-all">${hasPaypal ? esc(s.paypal_email) : '<span style="color:#C33">미등록 — 송금 불가</span>'}</div>
      </div>`;
  }
  const warn = $('settlementPayWarn');
  if (warn) warn.style.display = hasPaypal ? 'none' : 'block';
  const memo = $('settlementPayMemo');
  if (memo) memo.value = '';
  const btn = $('settlementPayConfirmBtn');
  if (btn) btn.disabled = !hasPaypal;
  openModal('settlementPayModal');
}

function closeSettlementPayModal() {
  closeModal('settlementPayModal');
  _settlementModalCtx = null;
}

async function confirmSettlementPay() {
  const ctx = _settlementModalCtx;
  if (!ctx) return;
  const memo = ($('settlementPayMemo')?.value || '').trim();
  const btn = $('settlementPayConfirmBtn');
  if (btn) btn.disabled = true;
  try {
    const newV = await markSettlementPaid(ctx.id, ctx.version, memo);
    if (newV === -1) {
      toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    } else {
      toast('송금 완료로 처리되었습니다.');
    }
  } catch (e) {
    toast('송금 처리 실패: ' + friendlyError(e.message || e), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  closeModal('settlementPayModal');
  _settlementModalCtx = null;
  await refreshPane('settlements');  // 재조회 + 목록·배지 갱신 (quality.md)
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 보류 / 취소 (사유 입력, 낙관적 락, 사유 모달 공용)
// ════════════════════════════════════════════════════════════════════

function openSettlementHoldModal(id) { _openSettlementReasonModal(id, 'hold'); }
function openSettlementCancelModal(id) { _openSettlementReasonModal(id, 'cancel'); }

function _openSettlementReasonModal(id, mode) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  _settlementModalCtx = { id: s.id, version: s.version, mode };
  const inf = s.influencers || {};
  const camp = s.campaigns || {};
  const isCancel = mode === 'cancel';

  const titleEl = $('settlementReasonTitle');
  if (titleEl) titleEl.textContent = isCancel ? '정산 취소' : '정산 보류';
  const descEl = $('settlementReasonDesc');
  if (descEl) descEl.innerHTML = isCancel
    ? '이 정산 건을 <b style="color:#C33">취소</b>합니다. 취소된 정산은 되돌릴 수 없습니다.'
    : '이 정산 건을 <b>보류</b>로 전환합니다. (환수 필요·인증 재검토 등)';
  const infoEl = $('settlementReasonInfo');
  if (infoEl) infoEl.innerHTML = `${esc(inf.name || '—')} · ${esc(camp.title || '—')} · ${settlementAmountYen(s.amount_jpy)}`;
  const memo = $('settlementReasonMemo');
  if (memo) memo.value = '';
  const btn = $('settlementReasonConfirmBtn');
  if (btn) {
    btn.disabled = false;
    btn.textContent = isCancel ? '취소 처리' : '보류 처리';
    btn.style.background = isCancel ? '#C33' : '';
    btn.style.borderColor = isCancel ? '#C33' : '';
  }
  openModal('settlementReasonModal');
}

function closeSettlementReasonModal() {
  closeModal('settlementReasonModal');
  _settlementModalCtx = null;
}

async function confirmSettlementReason() {
  const ctx = _settlementModalCtx;
  if (!ctx) return;
  const memo = ($('settlementReasonMemo')?.value || '').trim();
  const btn = $('settlementReasonConfirmBtn');
  if (btn) btn.disabled = true;
  try {
    const fn = ctx.mode === 'cancel' ? markSettlementCancel : markSettlementHold;
    const newV = await fn(ctx.id, ctx.version, memo);
    if (newV === -1) {
      toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    } else {
      toast(ctx.mode === 'cancel' ? '정산을 취소했습니다.' : '정산을 보류로 전환했습니다.');
    }
  } catch (e) {
    toast('처리 실패: ' + friendlyError(e.message || e), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  closeModal('settlementReasonModal');
  _settlementModalCtx = null;
  await refreshPane('settlements');  // 재조회 + 목록·배지 갱신 (quality.md)
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 엑셀 내보내기 (현재 필터 결과)
// ════════════════════════════════════════════════════════════════════

async function exportSettlementsExcel() {
  if (typeof _checkExportAllowed === 'function' && !_checkExportAllowed()) return;
  const rows = getFilteredSettlements();
  if (!rows.length) { toast('내보낼 정산 건이 없습니다', 'warn'); return; }
  if (typeof _markExportStart === 'function') _markExportStart();
  try {
    await loadExcelJS();
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('정산');
    ws.columns = [
      { header: '이름(한자)', key: 'kanji',    width: 14 },
      { header: '이름(가나)', key: 'kana',     width: 16 },
      { header: '이메일',     key: 'email',    width: 24 },
      { header: '캠페인번호', key: 'campno',   width: 16 },
      { header: '캠페인',     key: 'title',    width: 28 },
      { header: '금액(¥)',    key: 'amount',   width: 12 },
      { header: 'PayPal',     key: 'paypal',   width: 26 },
      { header: '상태',       key: 'status',   width: 10 },
      { header: '인증성공일', key: 'certdate', width: 14 },
      { header: '송금완료일', key: 'paiddate', width: 14 },
    ];
    ws.getRow(1).font = { bold: true };

    rows.forEach(s => {
      const inf = s.influencers || {};
      const camp = s.campaigns || {};
      // influencers_admin_view 는 name(한자)·name_kana(가나) — _excelInfluencerNameParts 는 name_kanji 를
      // 기대하므로 여기선 직접 매핑(한자 누락 방지).
      ws.addRow({
        kanji:    (inf.name || '').trim(),
        kana:     (inf.name_kana || '').trim(),
        email:    inf.email || '',
        campno:   camp.campaign_no || '',
        title:    camp.title || '',
        amount:   Number(s.amount_jpy) || 0,
        paypal:   s.paypal_email || '',
        status:   settlementStatusKo(s.status),
        certdate: s.created_at ? formatDate(s.created_at) : '',
        paiddate: s.paid_at ? formatDate(s.paid_at) : '',
      });
    });

    const buf = await wb.xlsx.writeBuffer();
    const blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    const url = URL.createObjectURL(blob);
    const aEl = document.createElement('a');
    aEl.href = url;
    const ts = new Date();
    const ymd = ts.getFullYear() + String(ts.getMonth() + 1).padStart(2, '0') + String(ts.getDate()).padStart(2, '0');
    aEl.download = 'settlements-' + rows.length + '-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + rows.length + '건)');
  } catch (e) {
    toast('엑셀 생성 실패: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || e)), 'error');
  } finally {
    if (typeof _markExportEnd === 'function') _markExportEnd();
  }
}
