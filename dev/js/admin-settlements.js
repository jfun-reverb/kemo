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
let _settlementFilters = { status: 'pending', campaignIds: [], search: '' };
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

// 상태별 탭 (기존 select 대체) — 캠페인 관리 페인 status-tab 패턴 미러(단일 선택).
//   전체 탭은 code '' (취소 포함 전 상태), getFilteredSettlements 의 `if (status)` 로 필터 skip.
const SETTLEMENT_STATUS_TABS = [
  { code: '',          label: '전체' },
  { code: 'pending',   label: '정산대기' },
  { code: 'paid',      label: '송금완료' },
  { code: 'on_hold',   label: '보류' },
  { code: 'cancelled', label: '취소' },
];

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

// 금액 출처(마이그레이션 261 amount_source) — 같은 목록에 두 기준(제품 가격/현금 리워드)이
// 섞이므로 관리자가 「이 금액이 어디서 나왔는지」 한눈에 보게 한다.
//   product_price = 리뷰어형(가구매 포함) 캠페인 제품 가격을 페이백
//   reward        = 시딩·방문형 캠페인 현금 리워드
//   NULL          = 261 이전 행(백필로 대부분 'reward') 또는 미상 → 배지 생략
const SETTLEMENT_AMOUNT_SOURCE_LABELS = {
  product_price: '제품 가격',
  product_plus_reward: '제품＋보수',
  reward: '현금 리워드',
};
function settlementAmountSourceLabel(source) {
  return SETTLEMENT_AMOUNT_SOURCE_LABELS[source] || '';
}
function settlementAmountSourceBadge(source) {
  const label = settlementAmountSourceLabel(source);
  return label
    ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(label)}</div>`
    : '';
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 로드 / 조회 / 렌더
// ════════════════════════════════════════════════════════════════════

// 페인 진입 로더 — ①인증성공 응모 백필(멱등, best-effort) ②전건 조회 ③렌더 + 배지
async function loadSettlements() {
  // 과거 미등록 뷰를 열어둔 채 페인을 떠났다가 재진입해도 항상 메인 목록으로 복귀
  if ($('settlementPastView') && $('settlementPastView').style.display !== 'none') {
    closePastUnregView();
  }
  try {
    const r = await backfillSettlements();
    if (r && r.created_count > 0 && typeof toast === 'function') {
      toast(`인증 성공 ${r.created_count}건을 정산 대기로 추가했습니다`, 'info');
    }
  } catch (e) {
    // 권한 없음(campaign_manager)·RPC 실패 등은 무시 — 기존 정산행은 그대로 조회한다.
  }
  await reloadSettlementsData();
  // 과거 미등록 건수 배지 + 금액 확인 필요 안내.
  // ⚠️ 페인 **진입 시에만** 호출한다(reloadSettlementsData 에 넣지 않음) — 이 조회는 승인 응모
  //   전건을 스캔하므로, 정산 1건 처리할 때마다(refreshPane 경유) 큰 쿼리가 따라붙으면 안 된다.
  //   정산 처리(송금완료·보류·취소)는 과거 미등록 건수를 바꾸지 않으므로 갱신할 이유도 없다.
  //   과거 미등록 화면에서 실제로 건수가 줄어드는 경로(pastUnregRegister)에서만 따로 호출한다.
  refreshPastUnregEntryInfo();   // await 안 함 — 목록 표시를 막지 않는다
}

// 데이터 재조회(백필 없음) — 처리 모달 저장 후 refreshPane('settlements') 가 호출
async function reloadSettlementsData() {
  _settlements = await fetchSettlements({});
  _settlementsLoaded = true;
  renderSettlementsList();
  refreshSettlementSidebarBadge();
}

// 「과거 미등록」 진입 버튼 배지 + 「금액 확인 필요」 안내 갱신.
//   · 총 과거 미등록 건수 → 버튼 옆 배지
//   · 그중 금액을 정할 수 없는 건(amount_issue) → 상단 빨간 안내. 0건이면 숨김(평소 상태)
// ⚠️ 한계: 이 조회는 **정산 도입일 이전** 건만 반환한다(get_past_unregistered_settlements 의
//   컷오프 필터). 도입일을 세팅한 뒤 새로 생기는 「인증 성공했는데 캠페인에 금액이 없는」 건은
//   여기에도 자동 등록에도 잡히지 않아 조용히 누락된다(사양서 §2-1 ①). 도입일 세팅 시
//   전용 조회를 추가할 것. 현재는 도입일이 비어 있어 전 구간이 이 조회에 들어온다.
async function refreshPastUnregEntryInfo() {
  const badge = $('pastUnregEntryBadge');
  const banner = $('settlementAmountIssueBanner');
  const text = $('settlementAmountIssueText');
  if (!badge && !banner) return;
  let rows = [];
  try {
    rows = await fetchPastUnregisteredSettlements();
  } catch (e) {
    return;  // 권한 없음·조회 실패는 무시(기존 목록 표시에 영향 주지 않는다)
  }
  const issueCount = rows.filter(r => pastUnregHasIssue(r)).length;
  if (badge) {
    badge.textContent = rows.length ? String(rows.length) : '';
    badge.style.display = rows.length ? '' : 'none';
  }
  if (banner && text) {
    if (issueCount > 0) {
      text.textContent = `인증은 끝났지만 캠페인에 금액이 없어 정산을 만들 수 없는 건이 ${issueCount}건 있습니다. 캠페인의 제품 가격(리뷰어형) 또는 리워드 금액(기프팅·방문형)을 입력하면 자동으로 등록됩니다.`;
      banner.style.display = '';
    } else {
      banner.style.display = 'none';
    }
  }
}

function readSettlementFilters() {
  // status 는 이제 상태 탭(_settlementFilters.status)이 소스 — select 없음, 여기선 건드리지 않는다.
  // 캠페인은 검색형 다중필터(settlementCampMulti) → 선택된 campaign_id 배열 (전체=빈 배열).
  _settlementFilters.campaignIds = getMultiFilterValues('settlementCampMulti');
  const q = $('settlementSearch');
  _settlementFilters.search = q ? (q.value || '').trim().toLowerCase() : '';
}

// 상태 탭 바 렌더 — 건수는 _settlements(필터 전 전체) 기준, 전체 탭 = 취소 포함 총건수.
//   renderSettlementsList 가 매번 호출 → 처리 후 재조회 시 건수가 즉시 반영된다.
function renderSettlementStatusTabs() {
  const bar = $('settlementStatusTabBar');
  if (!bar) return;
  const counts = {};
  _settlements.forEach(s => { counts[s.status] = (counts[s.status] || 0) + 1; });
  const totalAll = _settlements.length;
  const active = _settlementFilters.status || '';
  bar.innerHTML = SETTLEMENT_STATUS_TABS.map(tab => {
    const n = tab.code === '' ? totalAll : (counts[tab.code] || 0);
    const isOn = tab.code === active;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code}" onclick="setSettlementStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

// 상태 탭 클릭 → 단일 상태 필터로 목록 재조회 (탭 활성 표시는 renderSettlementsList 내부 재렌더로 갱신)
function setSettlementStatusTab(btn) {
  _settlementFilters.status = btn.dataset.status || '';
  renderSettlementsList();
}

// 사이드바 「정산 관리」 배지 클릭 → 다른 필터 초기화 후 「정산대기」만 (기준: openDelivPendingReview)
function openSettlementsPending() {
  _settlementFilters.status = 'pending';
  _settlementFilters.search = '';
  _settlementFilters.campaignIds = [];
  const s = document.getElementById('settlementSearch'); if (s) s.value = '';
  if (typeof clearMultiFilter === 'function') clearMultiFilter('settlementCampMulti', '전체 캠페인');
  if (typeof navAdminPaneReload === 'function') navAdminPaneReload('settlements');
  else reloadSettlementsData();
}

// 현재 필터 조건으로 _settlements 를 거른 배열 반환 (목록·합계·엑셀 공용)
function getFilteredSettlements() {
  readSettlementFilters();
  const { status, campaignIds, search } = _settlementFilters;
  let rows = _settlements.slice();
  if (status) rows = rows.filter(s => s.status === status);
  if (campaignIds.length) rows = rows.filter(s => campaignIds.includes(s.campaign_id));
  if (search) rows = rows.filter(s => {
    const inf = s.influencers || {};
    return matchSearchTokens(search, [inf.name, inf.name_kana, inf.email]);
  });
  return rows;
}

// 캠페인 검색형 다중필터 옵션 동기화 — 결과물 관리 페인(delivCampMulti)과 동일 패턴.
//   · campOptionsSource: 현재 로드된 정산행의 distinct 캠페인 (선택값은 syncMultiFilter 가 보존)
//   · campCounts: 캠페인별 정산 건수. 캠페인 필터는 제외하고 상태 탭·검색은 반영(자기 자신 필터 제외
//     — 결과물 페인 campCounts 규칙 미러). 카운트 = 그 캠페인만 선택했을 때 실제 결과와 일치.
function syncSettlementCampaignOptions() {
  if (!$('settlementCampMulti')) return;
  readSettlementFilters();  // campCounts 가 최신 검색어·상태를 반영하도록 먼저 갱신
  const { status, search } = _settlementFilters;
  // 상태 탭·검색만 통과(캠페인 필터 제외) — 캠페인별 건수 집계 기준
  const passesNonCamp = (s) => {
    if (status && s.status !== status) return false;
    if (search) {
      const inf = s.influencers || {};
      if (!matchSearchTokens(search, [inf.name, inf.name_kana, inf.email])) return false;
    }
    return true;
  };
  const seen = new Map();
  const campCounts = {};
  _settlements.forEach(s => {
    const c = s.campaigns;
    if (c && c.id && !seen.has(c.id)) seen.set(c.id, c);
    if (s.campaign_id && passesNonCamp(s)) {
      campCounts[s.campaign_id] = (campCounts[s.campaign_id] || 0) + 1;
    }
  });
  const campOptionsSource = [...seen.values()];
  syncCampMultiFilter('settlementCampMulti', campOptionsSource, () => renderSettlementsList(), campCounts);
}

function renderSettlementsList() {
  const tbody = $('settlementsTableBody');
  if (!tbody) return;
  syncSettlementCampaignOptions();
  renderSettlementStatusTabs();           // 상태 탭 건수·활성 표시 갱신
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
  const infCell = `<div class="link-cell" onclick="openInfluencerModal('${esc(inf.id || '')}')">${infName}${auditB}</div>${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}`;

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

  // 신청 반려·취소로 자동 보류된 건(고정 메모 '신청 반려로 자동 보류')은 관리자가 구분하도록 앰버 배지.
  //   복원은 on_hold 의 「보류 해제」 버튼(mark_settlement_revert)으로 정산대기 복귀.
  const autoHoldBadge = (s.status === 'on_hold' && (s.memo || '').includes('자동 보류'))
    ? `<div style="margin-top:3px"><span style="font-size:10px;background:#FEF3C7;color:#92400E;font-weight:600;padding:1px 6px;border-radius:3px" title="신청이 반려·취소되어 자동 보류된 정산입니다. 신청을 다시 승인했다면 「보류 해제」로 정산대기로 되돌리세요.">자동 보류(신청 반려)</span></div>`
    : '';

  return `<tr class="${inf.is_audit ? 'audit-row' : ''}">
    <td>${infCell}</td>
    <td>${campCell}</td>
    <td><div style="font-weight:700;color:var(--ink);white-space:nowrap">${settlementAmountYen(s.amount_jpy)}</div>${settlementAmountSourceBadge(s.amount_source)}</td>
    <td>${paypalCell}</td>
    <td>${settlementStatusBadge(s.status)}${autoHoldBadge}</td>
    <td>${certDate}</td>
    <td>${paidDate}</td>
    <td>${settlementActionCell(s)}</td>
  </tr>`;
}

// 상태 전이 규칙에 따른 처리 버튼:
//   pending  → 송금 완료 / 보류 / 취소
//   paid     → 보류 (환수·인증깨짐 대응)
//   on_hold  → 보류 해제(정산대기 복귀) / 취소
//   cancelled→ 처리 버튼 없음(종료)
// 「이력」 버튼은 상태 무관 항상 노출 — 취소(cancelled) 건도 상태 변경 이력은 열람 가능.
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
    btns.push(`<button class="btn btn-primary btn-xs" onclick="openSettlementRevertModal('${id}')">보류 해제</button>`);
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementCancelModal('${id}')" style="color:#C33">취소</button>`);
  }
  // 이력 버튼은 모든 상태에 노출(맨 뒤) — 처리 버튼이 없는 취소 건도 이력만은 볼 수 있게.
  //   단 변경 이력(settlement_events)이 0건인 행은 비활성(더미·이벤트 없는 행 방어).
  const hasHistory = (s.event_count || 0) > 0;
  btns.push(hasHistory
    ? `<button class="btn btn-ghost btn-xs" onclick="openSettlementHistoryModal('${id}')">이력</button>`
    : `<button class="btn btn-ghost btn-xs" disabled title="변경 이력이 없습니다">이력</button>`);
  return `<div style="display:flex;gap:4px;flex-wrap:wrap">${btns.join('')}</div>`;
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
function openSettlementRevertModal(id) { _openSettlementReasonModal(id, 'revert'); }

function _openSettlementReasonModal(id, mode) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  _settlementModalCtx = { id: s.id, version: s.version, mode };
  const inf = s.influencers || {};
  const camp = s.campaigns || {};
  const isCancel = mode === 'cancel';

  const titleEl = $('settlementReasonTitle');
  if (titleEl) titleEl.textContent = isCancel ? '정산 취소' : mode === 'revert' ? '보류 해제' : '정산 보류';
  const descEl = $('settlementReasonDesc');
  if (descEl) descEl.innerHTML = isCancel
    ? '이 정산 건을 <b style="color:#C33">취소</b>합니다. 취소된 정산은 되돌릴 수 없습니다.'
    : mode === 'revert'
      ? '이 정산 건을 <b>정산 대기</b>로 되돌립니다. 이후 다시 송금 완료·취소할 수 있습니다.'
      : '이 정산 건을 <b>보류</b>로 전환합니다. (환수 필요·인증 재검토 등)';
  const infoEl = $('settlementReasonInfo');
  if (infoEl) infoEl.innerHTML = `${esc(inf.name || '—')} · ${esc(camp.title || '—')} · ${settlementAmountYen(s.amount_jpy)}`;
  const memo = $('settlementReasonMemo');
  if (memo) memo.value = '';
  const btn = $('settlementReasonConfirmBtn');
  if (btn) {
    btn.disabled = false;
    btn.textContent = isCancel ? '취소 처리' : mode === 'revert' ? '보류 해제' : '보류 처리';
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
    const fn = ctx.mode === 'cancel' ? markSettlementCancel
             : ctx.mode === 'revert' ? markSettlementRevert
             : markSettlementHold;
    const newV = await fn(ctx.id, ctx.version, memo);
    if (newV === -1) {
      toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    } else {
      toast(ctx.mode === 'cancel' ? '정산을 취소했습니다.'
          : ctx.mode === 'revert' ? '정산 대기로 되돌렸습니다.'
          : '정산을 보류로 전환했습니다.');
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
// SECTION: SETTLEMENTS — 정산 이력 모달 (settlement_events 타임라인, 읽기 전용)
// ════════════════════════════════════════════════════════════════════
//
// settlement_events 는 정산 건별 상태 변경 이력(생성/송금/보류/취소/보류해제).
//   · fetchSettlementEvents(id) 는 at 오름차순 배열 반환 → 최신이 위로 오게 역순 렌더
//   · 처리 버튼과 달리 읽기 전용(낙관적 락 없음). 취소 건도 열람 가능.

// action 코드 → 한국어 라벨 (결과물 이력 타임라인 라벨 매핑 패턴 미러)
const SETTLEMENT_EVENT_LABELS = {
  create: '생성(자동 등록)',
  pay:    '송금 완료',
  hold:   '보류',
  cancel: '취소',
  revert: '보류 해제',
};

async function openSettlementHistoryModal(id) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  const inf = s.influencers || {};
  const camp = s.campaigns || {};

  // 헤더 요약(인플명·가나·캠페인·금액·현재 상태)
  const headEl = $('settlementHistoryHeader');
  if (headEl) {
    const kana = inf.name_kana ? ` <span style="font-size:11px;color:var(--muted)">${esc(inf.name_kana)}</span>` : '';
    headEl.innerHTML = `<div style="font-weight:600">${esc(inf.name || '—')}${kana}</div>`
      + `<div style="font-size:12px;color:var(--muted);margin-top:3px;display:flex;align-items:center;gap:6px;flex-wrap:wrap">`
      + `<span>${esc(camp.title || '—')}</span><span>·</span><span>${settlementAmountYen(s.amount_jpy)}</span>`
      + `<span>·</span>${settlementStatusBadge(s.status)}</div>`;
  }

  const bodyEl = $('settlementHistoryBody');
  if (bodyEl) bodyEl.innerHTML = '<div style="text-align:center;color:var(--muted);padding:22px;font-size:12px">이력을 불러오는 중…</div>';
  openModal('settlementHistoryModal');

  let events = [];
  try { events = await fetchSettlementEvents(id); } catch (e) { events = []; }
  if (!bodyEl) return;
  if (!Array.isArray(events) || !events.length) {
    bodyEl.innerHTML = '<div style="text-align:center;color:var(--muted);padding:26px;font-size:13px">이력이 없습니다.</div>';
    return;
  }
  // at 오름차순 반환 → 최신이 위로 오게 역순으로 렌더
  bodyEl.innerHTML = events.slice().reverse().map(renderSettlementEventItem).join('');
}

// 이력 항목 1건 렌더 — 시각 / 액션 라벨 / 상태 전이 배지 / 처리자 / 사유
function renderSettlementEventItem(e) {
  const label = SETTLEMENT_EVENT_LABELS[e.action] || e.action || '';
  let transition = '';
  if (e.prev_status && e.next_status) {
    transition = `${settlementStatusBadge(e.prev_status)}`
      + `<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-3px;color:var(--muted)">arrow_forward</span>`
      + `${settlementStatusBadge(e.next_status)}`;
  } else if (e.next_status) {
    transition = settlementStatusBadge(e.next_status);  // 생성 등 prev 없는 경우
  }
  const actor = e.actor_name ? esc(e.actor_name) : '자동';
  const at = e.at ? esc(formatDate(e.at)) : '';
  const memoLine = e.memo
    ? `<div style="margin-top:6px;font-size:12px;color:var(--ink);white-space:pre-wrap;line-height:1.55">${esc(e.memo)}</div>`
    : '<div style="margin-top:6px;font-size:12px;color:var(--muted)">사유: —</div>';
  return `<div style="padding:11px 0;border-bottom:1px dashed var(--line)">`
    + `<div style="display:flex;justify-content:space-between;gap:10px;align-items:center">`
    + `<span style="font-size:13px;font-weight:700;color:var(--ink)">${esc(label)}</span>`
    + `<span style="font-size:11px;color:var(--muted);white-space:nowrap">${at}</span>`
    + `</div>`
    + `<div style="margin-top:5px;display:flex;align-items:center;gap:10px;flex-wrap:wrap;font-size:11px">`
    + `<span style="display:inline-flex;align-items:center;gap:4px">${transition}</span>`
    + `<span style="color:var(--muted)">처리자: ${actor}</span>`
    + `</div>${memoLine}</div>`;
}

function closeSettlementHistoryModal() {
  closeModal('settlementHistoryModal');
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
      { header: '금액구분',   key: 'amtsrc',   width: 12 },
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
        amtsrc:   settlementAmountSourceLabel(s.amount_source),
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

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 과거 미등록 인증성공 처리 (사양서 2026-07-09)
// ════════════════════════════════════════════════════════════════════
//
// 정산 도입일(cutoff) 이전에 인증 성공했지만 정산행이 없는 과거 건을 관리자가 직접
// 정산행으로 등록하는 화면. 자동 백필은 컷오프 이후만 대상이라 과거분은 여기서 처리.
//   · 진입: 정산 메인 뷰 헤더 「과거 미등록」 → 같은 페인 안에서 뷰 토글(모달 아님 —
//     대량 수백 건 목록 + 필터 툴바 + IntersectionObserver lazy-load 를 위해)
//   · 다중선택(체크박스 + 전체선택) → 일괄 「송금완료 기록」(paid) / 「정산대기 추가」(pending)
//   · 무알림은 서버(register_past_settlements)가 보장 — 화면은 안내 문구만
//   · 송금완료 기록은 되돌릴 수 없어 확인 모달(showConfirm) — 건수·합계·캠페인별 요약 표시
//
// 선택 상태는 application_id 기준 Set(_pastUnregSelected)이 단일 소스 —
//   lazy-load 로 행이 나눠 렌더돼도 체크 상태가 유지된다.
//
// ── 대량 오조작 방지 장치 (사양서 2026-07-23 §3-3 (다)) ──
// 리뷰어형 금액 규칙(마이그레이션 261·262)이 켜지면 이 목록이 수십 건 → 수백 건으로
// 불어난다. 그런데 바로 옆이 되돌릴 수 없는 「송금완료 기록」 버튼이라 아래 4가지를 둔다:
//   ① 캠페인·모집형식·인플루언서 필터 — 캠페인 하나씩 띄워 놓고 처리하는 흐름이 기본
//   ② 전체 선택은 **현재 필터 결과만** 대상. 필터를 바꾸면 선택을 초기화한다
//      (화면에 안 보이는 건이 선택된 채 확정되는 사고가 가장 위험 — onPastUnregFilterChange
//       가 필터 3종·초기화 버튼 모든 경로에서 _pastUnregSelected 를 비운다)
//   ③ 금액 미확정(amount_issue) 행은 체크박스 비활성 + 사유 배지. 서버도 조용히 건너뛰므로
//      화면에서 미리 잠가 「처리했는데 건수가 줄어 있는」 혼란을 막는다
//   ④ 확인 모달에 캠페인별 건수·합계 요약 — 무엇을 확정하는지 눈으로 보고 누르게

let _pastUnregRows = [];                 // 서버 조회 원본(필터 전)
let _pastUnregFiltered = [];             // 필터 통과분 — 렌더·전체선택·툴바의 기준
let _pastUnregById = {};                 // application_id → 행
let _pastUnregSelected = new Set();      // 선택된 application_id
var pastUnregLazy = null;
const PAST_UNREG_PAGE_SIZE = 50;
const PAST_UNREG_TYPE_LABELS = { monitor: '리뷰어형', gifting: '기프팅', visit: '방문형' };

function openPastUnregView() {
  const main = $('settlementMainView');
  const past = $('settlementPastView');
  if (main) main.style.display = 'none';
  if (past) past.style.display = 'flex';
  // 재진입 시 이전 필터가 남아 「목록이 비어 보이는」 오해를 만들지 않도록 값만 리셋
  // (resetPastUnregFilters 를 쓰면 데이터 로드 전에 빈 목록이 한 번 렌더돼 깜빡인다)
  if (typeof clearMultiFilter === 'function') clearMultiFilter('pastUnregCampMulti', '전체 캠페인');
  const typeEl = $('pastUnregTypeFilter'); if (typeEl) typeEl.value = '';
  const searchEl = $('pastUnregSearch');   if (searchEl) searchEl.value = '';
  loadPastUnregSettlements();
}

function closePastUnregView() {
  const main = $('settlementMainView');
  const past = $('settlementPastView');
  if (pastUnregLazy) { pastUnregLazy.destroy(); pastUnregLazy = null; }
  if (past) past.style.display = 'none';
  if (main) main.style.display = 'flex';
}

// 과거 미등록 목록 조회 → 맵 구성 + 선택 초기화 + 렌더
async function loadPastUnregSettlements() {
  const tbody = $('pastUnregTableBody');
  if (tbody) tbody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></td></tr>';
  try {
    _pastUnregRows = await fetchPastUnregisteredSettlements();
  } catch (e) {
    _pastUnregRows = [];
  }
  _pastUnregById = {};
  _pastUnregRows.forEach(r => { if (r.application_id) _pastUnregById[r.application_id] = r; });
  _pastUnregSelected.clear();
  syncPastUnregCampaignOptions();
  applyPastUnregFilters();
}

// ── 필터 ─────────────────────────────────────────────────────────────
// 캠페인 옵션은 조회 결과의 distinct 캠페인 + 캠페인별 건수(캠페인 필터 자신은 제외 —
// 정산 메인·결과물 페인 campCounts 규칙 미러).
function syncPastUnregCampaignOptions() {
  if (!$('pastUnregCampMulti') || typeof syncCampMultiFilter !== 'function') return;
  const { type, search } = readPastUnregFilters();
  const seen = new Map();
  const campCounts = {};
  _pastUnregRows.forEach(r => {
    if (r.campaign_id && !seen.has(r.campaign_id)) {
      seen.set(r.campaign_id, { id: r.campaign_id, title: r.campaign_title, campaign_no: r.campaign_no });
    }
    if (r.campaign_id && passesPastUnregNonCamp(r, type, search)) {
      campCounts[r.campaign_id] = (campCounts[r.campaign_id] || 0) + 1;
    }
  });
  syncCampMultiFilter('pastUnregCampMulti', [...seen.values()], () => onPastUnregFilterChange(), campCounts);
}

function readPastUnregFilters() {
  return {
    campaignIds: (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('pastUnregCampMulti') : [],
    type: $('pastUnregTypeFilter')?.value || '',
    search: ($('pastUnregSearch')?.value || '').trim(),
  };
}

// 캠페인 필터를 제외한 조건(캠페인별 건수 집계 기준과 목록 필터가 같은 함수를 쓰도록 분리)
function passesPastUnregNonCamp(r, type, search) {
  if (type && r.recruit_type !== type) return false;
  if (search && !matchSearchTokens(search, [r.influencer_name, r.influencer_name_kana])) return false;
  return true;
}

// 필터 변경 — ⚠️ 선택을 반드시 초기화한다. 화면에 안 보이는 건이 선택된 채
// 「송금완료 기록」(되돌릴 수 없음)으로 확정되는 것이 이 화면 최대 위험.
function onPastUnregFilterChange() {
  _pastUnregSelected.clear();
  syncPastUnregCampaignOptions();
  applyPastUnregFilters();
}

function resetPastUnregFilters() {
  if (typeof clearMultiFilter === 'function') clearMultiFilter('pastUnregCampMulti', '전체 캠페인');
  const typeEl = $('pastUnregTypeFilter'); if (typeEl) typeEl.value = '';
  const searchEl = $('pastUnregSearch');   if (searchEl) searchEl.value = '';
  onPastUnregFilterChange();
}

function applyPastUnregFilters() {
  const { campaignIds, type, search } = readPastUnregFilters();
  _pastUnregFiltered = _pastUnregRows.filter(r => {
    if (campaignIds.length && !campaignIds.includes(r.campaign_id)) return false;
    return passesPastUnregNonCamp(r, type, search);
  });
  renderPastUnregList();
}

function renderPastUnregList() {
  const tbody = $('pastUnregTableBody');
  if (!tbody) return;
  const cnt = $('pastUnregTotalCount');
  if (cnt) {
    const total = _pastUnregRows.length;
    const shown = _pastUnregFiltered.length;
    cnt.textContent = shown === total ? `총 ${total}건` : `${shown}건 / 전체 ${total}건`;
  }

  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (pastUnregLazy) pastUnregLazy.destroy();
  pastUnregLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows: _pastUnregFiltered,
    renderRow: renderPastUnregRow,
    pageSize: PAST_UNREG_PAGE_SIZE,
    emptyHtml: `<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:30px">${
      _pastUnregRows.length ? '조건에 맞는 건이 없습니다. 필터를 확인해 주세요.' : '과거 미등록 인증성공 건이 없습니다.'
    }</td></tr>`,
  });
  updatePastUnregToolbar();
}

// 금액을 정할 수 없는 행 — 서버(register_past_settlements)도 조용히 건너뛰므로
// 화면에서 미리 선택을 잠가, 처리 후 건수가 줄어 있는 혼란을 막는다.
function pastUnregHasIssue(r) { return !!(r && r.amount_issue); }

function pastUnregSelectableRows() {
  return _pastUnregFiltered.filter(r => r.application_id && !pastUnregHasIssue(r));
}

function renderPastUnregRow(r) {
  const issue = pastUnregHasIssue(r);
  const checked = _pastUnregSelected.has(r.application_id) ? ' checked' : '';
  const name = esc(r.influencer_name || '—');
  const kana = r.influencer_name_kana
    ? `<div style="font-size:10px;color:var(--muted)">${esc(r.influencer_name_kana)}</div>` : '';
  const campNo = r.campaign_no
    ? `<div style="font-size:10px;color:var(--muted)">${esc(r.campaign_no)}</div>` : '';
  const typeLabel = PAST_UNREG_TYPE_LABELS[r.recruit_type] || r.recruit_type || '';
  const campCell = `${campNo}<div style="font-size:13px">${esc(r.campaign_title || '—')}</div>`
    + (typeLabel ? `<div style="font-size:10px;color:var(--muted)">${esc(typeLabel)}</div>` : '');
  // 금액 — 미확정이면 사유 배지, 정상이면 금액 + 출처 배지(정산 목록과 같은 헬퍼)
  const amountCell = issue
    ? `<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px" title="${esc(r.amount_issue)}">금액 미확정</span>`
      + `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(r.amount_issue)}</div>`
    : `<div style="font-weight:700;color:var(--ink);white-space:nowrap">${settlementAmountYen(r.amount_jpy)}</div>`
      + settlementAmountSourceBadge(r.amount_source);
  const certCell = r.cert_at
    ? `<span style="font-size:12px">${formatDate(r.cert_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">불명</span>';
  const paypalCell = r.has_paypal
    ? '<span style="background:#E8F5E9;color:var(--green);font-size:10px;font-weight:700;padding:1px 6px;border-radius:3px">등록</span>'
    : '<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:1px 6px;border-radius:3px" title="PayPal 미등록">미등록</span>';
  const checkCell = issue
    ? '<input type="checkbox" disabled title="금액을 정할 수 없어 처리 대상에서 제외됩니다">'
    : `<input type="checkbox" class="past-unreg-check" data-app-id="${esc(r.application_id)}" onchange="pastUnregOnRowCheck(this)"${checked}>`;
  return `<tr${issue ? ' style="opacity:.6"' : ''}>
    <td>${checkCell}</td>
    <td><div style="font-weight:600">${name}</div>${kana}</td>
    <td>${campCell}</td>
    <td>${amountCell}</td>
    <td>${certCell}</td>
    <td>${paypalCell}</td>
  </tr>`;
}

// 전체 선택/해제 — ⚠️ 대상은 **현재 필터 결과 중 처리 가능한 행**만(전체 조회분 아님).
// 금액 미확정 행은 애초에 선택되지 않는다.
function pastUnregToggleAll(cb) {
  if (cb && cb.checked) {
    pastUnregSelectableRows().forEach(r => _pastUnregSelected.add(r.application_id));
  } else {
    _pastUnregSelected.clear();
  }
  renderPastUnregList();
}

// 개별 행 체크 — Set 갱신 후 툴바만 갱신(재렌더 없이 스크롤 유지)
function pastUnregOnRowCheck(cb) {
  const id = cb && cb.dataset ? cb.dataset.appId : '';
  if (!id) return;
  if (cb.checked) _pastUnregSelected.add(id);
  else _pastUnregSelected.delete(id);
  updatePastUnregToolbar();
}

// 선택 건수·합계, 처리 버튼 활성/비활성, 전체선택 체크박스 상태 갱신
function updatePastUnregToolbar() {
  let count = 0, sum = 0;
  _pastUnregSelected.forEach(id => {
    const r = _pastUnregById[id];
    if (r && !pastUnregHasIssue(r)) { count++; sum += Number(r.amount_jpy) || 0; }
  });
  const info = $('pastUnregSelectedInfo');
  if (info) info.textContent = count ? `선택 ${count}건 · 합계 ${settlementAmountYen(sum)}` : '';
  const payBtn = $('pastUnregPayBtn');
  const pendingBtn = $('pastUnregPendingBtn');
  if (payBtn) payBtn.disabled = count === 0;
  if (pendingBtn) pendingBtn.disabled = count === 0;
  const all = $('pastUnregSelectAll');
  if (all) {
    const total = pastUnregSelectableRows().length;
    all.checked = total > 0 && count === total;
    all.indeterminate = count > 0 && count < total;
  }
}

// 확인 모달용 캠페인별 요약 — 「무엇을 확정하는지」를 눈으로 보고 누르게 한다.
// 캠페인이 많으면 상위 5개만 보이고 나머지는 묶어서 표시(모달이 길어져 버튼이
// 화면 밖으로 밀리는 것 방지).
function pastUnregCampaignSummary(rows) {
  const byCamp = new Map();
  rows.forEach(r => {
    const key = r.campaign_id || '—';
    const cur = byCamp.get(key) || { label: r.campaign_no ? `[${r.campaign_no}] ${r.campaign_title || ''}` : (r.campaign_title || '(캠페인 없음)'), count: 0, sum: 0 };
    cur.count++;
    cur.sum += Number(r.amount_jpy) || 0;
    byCamp.set(key, cur);
  });
  const list = [...byCamp.values()].sort((a, b) => b.count - a.count);
  const MAX = 5;
  const lines = list.slice(0, MAX).map(c => `· ${c.label} — ${c.count}건 / ${settlementAmountYen(c.sum)}`);
  if (list.length > MAX) {
    const rest = list.slice(MAX);
    const restCount = rest.reduce((n, c) => n + c.count, 0);
    const restSum = rest.reduce((n, c) => n + c.sum, 0);
    lines.push(`· 그 외 ${rest.length}개 캠페인 — ${restCount}건 / ${settlementAmountYen(restSum)}`);
  }
  return { campaignCount: list.length, lines };
}

// 선택 건 일괄 처리 — targetStatus: 'paid'(송금완료 기록) | 'pending'(정산대기 추가)
async function pastUnregRegister(targetStatus) {
  // 금액 미확정 건은 서버가 건너뛰므로 여기서도 제외(체크박스는 이미 잠겨 있지만 이중 방어)
  const rows = [..._pastUnregSelected]
    .map(id => _pastUnregById[id])
    .filter(r => r && !pastUnregHasIssue(r));
  const ids = rows.map(r => r.application_id);
  if (!ids.length) { toast('선택된 건이 없습니다', 'warn'); return; }
  const sum = rows.reduce((n, r) => n + (Number(r.amount_jpy) || 0), 0);
  const summary = pastUnregCampaignSummary(rows);

  if (targetStatus === 'paid') {
    const ok = await showConfirm(
      `${summary.campaignCount}개 캠페인 · ${ids.length}건 · 합계 ${settlementAmountYen(sum)}\n\n`
      + `${summary.lines.join('\n')}\n\n`
      + `위 건을 송금완료로 기록합니다.\n`
      + `이미 외부에서 지급을 마친 건만 처리하세요. 송금완료 기록은 되돌릴 수 없습니다.\n계속하시겠습니까?`);
    if (!ok) return;
  } else {
    const ok = await showConfirm(
      `${summary.campaignCount}개 캠페인 · ${ids.length}건 · 합계 ${settlementAmountYen(sum)}\n\n`
      + `${summary.lines.join('\n')}\n\n`
      + `위 건을 정산대기로 추가합니다. 아직 지급하지 않은 건만 처리하세요.\n계속하시겠습니까?`);
    if (!ok) return;
  }

  const memo = ($('pastUnregMemo')?.value || '').trim();
  const payBtn = $('pastUnregPayBtn');
  const pendingBtn = $('pastUnregPendingBtn');
  if (payBtn) payBtn.disabled = true;
  if (pendingBtn) pendingBtn.disabled = true;
  try {
    const n = await registerPastSettlements(ids, targetStatus, memo);
    toast(`${n}건을 ${targetStatus === 'paid' ? '송금완료로 기록' : '정산대기로 추가'}했습니다`);
  } catch (e) {
    toast('처리 실패: ' + friendlyError(e.message || e), 'error');
    updatePastUnregToolbar();  // 버튼 재활성
    return;
  }
  const memoEl = $('pastUnregMemo');
  if (memoEl) memoEl.value = '';
  await loadPastUnregSettlements();   // 과거 목록 재조회(처리된 건은 목록에서 사라짐)
  await refreshPane('settlements');   // 정산 메인 목록·정산대기 배지 갱신 (quality.md)
  // 처리한 만큼 과거 미등록 건수가 실제로 줄어드는 유일한 경로 — 진입 버튼 배지·안내를 여기서 갱신
  // (reloadSettlementsData 에는 넣지 않는다 — 정산 처리마다 전건 스캔이 붙는 것을 피하려고)
  refreshPastUnregEntryInfo();
}
