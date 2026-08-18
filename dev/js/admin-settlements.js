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
//   receipt_amount = 리뷰어형(가구매 포함) 영수증 실결제액 — 상시가를 상한으로 자름(300~)
//   product_price  = 리뷰어형 캠페인 제품 가격을 페이백 (300 이전에 만들어진 행)
//   reward         = 시딩·방문형 캠페인 현금 리워드
//   NULL           = 261 이전 행(백필로 대부분 'reward') 또는 미상 → 배지 생략
const SETTLEMENT_AMOUNT_SOURCE_LABELS = {
  receipt_amount: '영수증 금액',
  product_price: '제품 가격',
  product_plus_reward: '제품＋보수',
  reward: '현금 리워드',
};
function settlementAmountSourceLabel(source) {
  return SETTLEMENT_AMOUNT_SOURCE_LABELS[source] || '';
}

// 상한 적용 여부(마이그레이션 299 receipt_amount_jpy/amount_cap_jpy).
// 영수증이 캠페인 상시가보다 커서 상한에서 잘린 건인지 판정한다 — 관리자가
// 「영수증에는 3,500엔인데 왜 3,200엔만 지급되나」를 화면에서 바로 알 수 있어야 한다
// (2026-08-05 사용자 명시 요구). 두 값이 다 있어야 판정 가능(옛 행은 비어 있음).
function settlementCapApplied(s) {
  s = s || {};
  // ⚠️ Number(null) 은 0 이라 isFinite 를 통과한다 — null 검사를 먼저 해야
  // 「두 값이 다 있을 때만 판정」이 실제로 성립한다(299 적용 이전 행은 둘 다 비어 있음).
  if (s.receipt_amount_jpy == null || s.amount_cap_jpy == null) return false;
  const receipt = Number(s.receipt_amount_jpy);
  const cap = Number(s.amount_cap_jpy);
  if (!Number.isFinite(receipt) || !Number.isFinite(cap)) return false;
  return receipt > cap;
}
// 금액 셀 아래 보조 줄 — 출처 배지 + (상한이 걸렸으면) 그 근거.
function settlementAmountNote(s) {
  s = s || {};
  const label = settlementAmountSourceLabel(s.amount_source);
  const capped = settlementCapApplied(s);
  const parts = [];
  if (label) parts.push(esc(label));
  if (capped) {
    parts.push(`영수증 ${settlementAmountYen(s.receipt_amount_jpy)} → <span style="color:var(--pink);font-weight:600">상한 적용</span>`);
  }
  return parts.length
    ? `<div style="font-size:10px;color:var(--muted);margin-top:2px;line-height:1.4">${parts.join('<br>')}</div>`
    : '';
}
// (settlementAmountSourceBadge 는 settlementAmountNote 로 흡수돼 삭제 — 2026-08-05)

// 캠페인 셀 — 결과물 관리·신청 관리 페인과 같은 형태로 통일(2026-07-23 사용자 요청):
//   [썸네일 40px] [모집타입 배지][캠페인번호] / [제목] [미리보기 돋보기]
// 헬퍼는 전부 기존 공용(imgThumb·getRecruitTypeBadgeKoSm — ui.js / campPreviewBtn — lib/shared.js).
// 빌드 순서상 셋 다 이 파일보다 먼저 로드된다. 썸네일·모집타입은 fetchSettlements 가
// campaigns 임베드로 이미 가져오는 img1·recruit_type 사용(추가 조회 없음).
function settlementCampCell(camp) {
  camp = camp || {};
  const campNoBadge = camp.campaign_no
    ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted)">${esc(camp.campaign_no)}</span>`
    : '';
  const rtBadge = (typeof getRecruitTypeBadgeKoSm === 'function')
    ? getRecruitTypeBadgeKoSm(camp.recruit_type) : '';
  // 이미지 없으면 아이콘 폴백, 있으면 썸네일 + 원본 URL 폴백(프로젝트 규칙 imgThumb + data-orig)
  const thumb = camp.img1
    ? `<img src="${esc(imgThumb(camp.img1, 96, 70))}" data-orig="${esc(camp.img1)}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">`
    : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span></span>`;
  const badgeRow = (rtBadge || campNoBadge)
    ? `<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;margin-bottom:2px">${rtBadge}${campNoBadge}</div>`
    : '';
  const previewBtn = (typeof campPreviewBtn === 'function' && camp.id) ? campPreviewBtn(camp.id) : '';
  return `<div style="display:flex;align-items:center;gap:10px">
      <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">${thumb}</div>
      <div style="min-width:0;flex:1">
        ${badgeRow}
        <div style="display:flex;align-items:flex-start;gap:4px"><span style="font-size:13px;word-break:break-word;line-height:1.4;flex:1">${esc(camp.title || '—')}</span>${previewBtn}</div>
      </div>
    </div>`;
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
  // 지급 준비 뷰도 같이 닫는다 — 안 닫으면 다른 페인에 갔다 오면 **옛 데이터가 그대로**
  // 남고(다시 그리지도 않는다) 메인 목록은 계속 숨겨져 있다.
  if ($('settlementPayoutView') && $('settlementPayoutView').style.display !== 'none') {
    closePayoutPrepView();
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
  // ⚠️ 조회 실패는 null 이다(빈 목록 아님). 0 으로 덮으면 배지가 사라져
  //    「미등록 건이 없다」로 보인다 — 실패했을 뿐인데. 그대로 두고 나간다.
  if (rows === null) return;
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

  const campCell = settlementCampCell(camp);

  // PayPal — 정산행 스냅샷(직접 컬럼). 미등록이면 빨간 경고 배지(송금 불가).
  const paypalCell = s.paypal_email
    ? `<span style="font-size:12px;word-break:break-all">${esc(s.paypal_email)}</span>`
    : `<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:1px 6px;border-radius:3px;border:1px solid #C33" title="PayPal 미등록 — 송금 불가">미등록</span>`;

  // 인증 성공 시점(마이그레이션 324) — 그 전에는 **등록일**을 인증성공일이라 보여줬다.
  //   과거분을 오늘 등록하면 오늘로 찍혀, 실제로 언제 인증에 성공했는지가 어디에도 안 남았다.
  //   ⚠️ 324 이전에 만들어진 행은 그 시점을 되살릴 방법이 없어 비어 있다 —
  //   등록일로 슬쩍 대신하지 않는다. 틀린 날짜를 맞는 척 보여주는 게 더 나쁘다.
  const certDate = s.cert_at
    ? `<span style="font-size:12px">${formatDate(s.cert_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)" title="이 값을 저장하기 전에 등록된 건이라 시점을 알 수 없습니다">기록 없음</span>';
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
    <td><div style="font-weight:700;color:var(--ink);white-space:nowrap">${settlementAmountYen(s.amount_jpy)}</div>${settlementAmountNote(s)}</td>
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
        <div><div style="font-weight:700;font-size:18px;color:var(--ink)">${settlementAmountYen(s.amount_jpy)}</div>${
          // 상한이 걸린 건은 송금 직전에 근거를 보여준다 — 「영수증에는 더 큰 금액이
          // 적혀 있는데 왜 이 금액인가」를 여기서 확인하지 못하면 관리자가 목록으로
          // 되돌아가 대조해야 한다(2026-08-05 사용자 요구).
          settlementCapApplied(s)
            ? `<div style="font-size:11px;color:var(--muted);margin-top:3px">영수증 ${settlementAmountYen(s.receipt_amount_jpy)} · 상한 ${settlementAmountYen(s.amount_cap_jpy)} <span style="color:var(--pink);font-weight:600">적용됨</span></div>`
            : ''
        }</div>
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
//   ⚠️ 서버가 쓰는 동작 코드가 늘면 여기에도 한 줄 추가할 것 — 빠지면 한국어 화면에
//   영어 코드가 그대로 뜬다(`recalc` 가 실제로 그랬다. 마이그레이션 302 가 추가한 값).
const SETTLEMENT_EVENT_LABELS = {
  create: '생성(자동 등록)',
  pay:    '송금 완료',
  hold:   '보류',
  cancel: '취소',
  revert: '보류 해제',
  recalc: '금액 재계산(영수증 수정)',
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
      // 299 추가 — 영수증 기준 건에서 「왜 이 금액인가」를 엑셀에서도 대조할 수 있게.
      // 옛 행(상시가·현금 리워드 기준)은 빈 칸으로 남는다.
      { header: '영수증금액(¥)', key: 'receipt', width: 14 },
      { header: '상한(¥)',    key: 'cap',      width: 12 },
      { header: '상한적용',   key: 'capped',   width: 10 },
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
        // ⚠️ Number(null) 은 0 이므로 null 검사를 먼저 — 안 그러면 299 이전 행이
        // 「영수증 0엔」으로 찍혀 실제로 0원에 샀다는 오해를 준다.
        receipt:  (s.receipt_amount_jpy != null) ? Number(s.receipt_amount_jpy) : '',
        cap:      (s.amount_cap_jpy != null) ? Number(s.amount_cap_jpy) : '',
        capped:   settlementCapApplied(s) ? 'O' : '',
        paypal:   s.paypal_email || '',
        status:   settlementStatusKo(s.status),
        // 인증 성공 시점(324). 옛 행은 비어 있다 — 등록일로 대신 채우지 않는다(화면과 같은 이유)
        certdate: s.cert_at ? formatDate(s.cert_at) : '',
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
  // 이 화면은 종전대로 빈 목록으로 다룬다(실패 구분은 지급 준비 화면에서만 쓴다).
  if (_pastUnregRows === null) _pastUnregRows = [];
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
      + settlementAmountNote(r);  // 출처 배지 + 상한이 걸렸으면 그 근거(299·300)
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
    const { registered, skippedNoPaypal } = await registerPastSettlements(ids, targetStatus, memo);
    const doneWord = targetStatus === 'paid' ? '송금완료로 기록' : '정산대기로 추가';
    // 페이팔이 없어 빠진 건은 반드시 알린다 — 안 알리면 고른 수보다 적게 처리된 이유를 알 수 없다.
    //   (단건 「송금완료 기록」은 원래 막던 조건인데 일괄만 통과하던 것을 마이그레이션 324 가 맞췄다)
    if (skippedNoPaypal > 0) {
      toast(`${registered}건을 ${doneWord}했습니다. ${skippedNoPaypal}건은 PayPal 미등록이라 제외했습니다`, 'warn');
    } else {
      toast(`${registered}건을 ${doneWord}했습니다`);
    }
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

// ══════════════════════════════════════════════════════════════════
// SECTION: 지급 준비 화면 (사양서 2026-08-18-settlement-list-unification… §4-1 화면 ㄱ)
//
// ▶ 왜 필요한가
//   시스템이 **지급 기한을 몰랐다.** 캠페인 참여방법에는 「다음 달 15일 / 말일」이
//   한·일 양쪽으로 박혀 있는데 화면 어디에도 그 날짜가 없어, 운영팀이 「이번 달에
//   누구에게 얼마를 보내야 하는지」를 시스템 밖에서 세고 있었다.
//
// ▶ 무엇을 모으나
//   **미등록 건**(아직 정산 행이 없는 인증 성공분)과 **정산 행**을 한데 놓고
//   지급 예정일(payoutDueDate)로 묶는다. 두 곳에 흩어져 있으면 합계가 안 나온다.
// ══════════════════════════════════════════════════════════════════

let _payoutRows = null;        // null = 아직 조회 안 함 / [] = 대상 없음
let _payoutPaidMonth = null;   // 「지급 완료」 묶음이 보여줄 달 'YYYY-MM'

// 지급 흐름에서 벗어난 상태 — 네 묶음 어디에도 넣지 않는다(사양서 §4-1).
const PAYOUT_EXCLUDED_STATUS = new Set(['on_hold', 'cancelled']);

// 'YYYY-MM-DD' → 'YYYY-MM'
function _payoutMonthOf(dueStr) { return dueStr ? String(dueStr).slice(0, 7) : null; }

// 미등록 + 정산 행을 한 목록으로. 지급 예정일은 payoutDueDate 하나로만 계산한다.
//   ⚠️ 카드·목록·엑셀이 각자 계산하면 어긋난다(사양서 §4-1).
function buildPayoutRows(unregRows, settlementRows) {
  const out = [];
  (unregRows || []).forEach(function(r) {
    out.push({
      kind: 'unregistered',
      status: 'unregistered',           // 아직 정산 행이 없다
      due: payoutDueDate(r.cert_at),
      amount: Number(r.amount_jpy || 0),
      amountUnknown: !r.amount_jpy,     // 금액을 정할 수 없는 건(amount_issue)
      influencerId: r.influencer_id,
      name: r.influencer_name, nameKana: r.influencer_name_kana,
      campaignNo: r.campaign_no, campaignTitle: r.campaign_title,
      applicationId: r.application_id,
    });
  });
  (settlementRows || []).forEach(function(s) {
    if (PAYOUT_EXCLUDED_STATUS.has(s.status)) return;   // 보류·취소 제외
    const camp = s.campaigns || {};
    out.push({
      kind: 'settlement',
      status: s.status,                 // pending | paid
      due: payoutDueDate(s.cert_at),
      amount: Number(s.amount_jpy || 0),
      amountUnknown: false,
      influencerId: s.influencer_id,
      name: null, nameKana: null,       // 이름은 작업 3에서 통로로 채운다
      campaignNo: camp.campaign_no, campaignTitle: camp.title,
      applicationId: s.application_id,
      settlementId: s.id, paypalEmail: s.paypal_email, paidAt: s.paid_at,
    });
  });
  return out;
}

// 아직 안 보낸 것 = 미등록 + 정산대기. 「기한 초과」와 「다가오는」의 공통 조건이다.
function _payoutUnsent(r) { return r.status === 'unregistered' || r.status === 'pending'; }

async function openPayoutPrepView() {
  const main = $('settlementMainView'), view = $('settlementPayoutView');
  if (!main || !view) return;
  main.style.display = 'none';
  view.style.display = 'flex';
  const body = $('payoutSummaryBody');
  if (body) body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';

  // 미등록 건은 별도 조회(정산 행이 아직 없어 _settlements 에 안 들어 있다).
  let unreg = null;
  try { unreg = await fetchPastUnregisteredSettlements(); } catch (e) { unreg = null; }
  // ⚠️ **한계** — 정산 행 쪽은 실패를 구분하지 못한다. fetchSettlements() 가 실패해도
  //    빈 목록을 돌려주는데, 그 함수는 관리자 화면 전반이 쓰고 있어 이번 범위에서
  //    바꾸지 않았다. 즉 아래가 조용히 비면 「정산 행이 없다」와 「못 불러왔다」가 같아 보인다.
  //    미등록 쪽(위)은 구분되므로, 화면이 통째로 비는 최악은 막힌다.
  if (!_settlementsLoaded) { try { await reloadSettlementsData(); } catch (e) {} }

  // ⚠️ 조회 실패(null)와 0건([])을 구분한다 — 실패를 「보낼 게 없음」으로 그리면
  //    운영팀이 이번 달 지급을 통째로 건너뛴다.
  if (unreg === null) {
    _payoutRows = null;
    if (body) body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">'
      + '<b style="color:var(--ink)">미등록 건을 불러오지 못했습니다.</b><br>'
      + '조회가 실패한 것이라 <b>보낼 것이 없다는 뜻이 아닙니다</b>.<br>잠시 뒤 다시 열어 보세요.</div>';
    return;
  }
  _payoutRows = buildPayoutRows(unreg, _settlements);
  // ⚠️ 사람 정보 캐시를 비운다 — 안 비우면 그 사이 새로 생긴 정산 행의 인플루언서가
  //    「(이름 미상)·페이팔 미등록」으로 보인다(조회를 안 하니 값이 없을 뿐인데).
  _payoutPersonInfo = null;
  if (!_payoutPaidMonth) _payoutPaidMonth = jstTodayStr().slice(0, 7);
  renderPayoutSummary();
}

function closePayoutPrepView() {
  const main = $('settlementMainView'), view = $('settlementPayoutView');
  if (view) view.style.display = 'none';
  if (main) main.style.display = 'flex';
}

// 'YYYY-MM' 을 n달 옮긴다(문자열 연산 — 시간대가 끼어들 자리가 없다)
function _payoutShiftMonth(ym, delta) {
  const y = Number(ym.slice(0, 4)), m = Number(ym.slice(5, 7));
  const d = new Date(Date.UTC(y, m - 1 + delta, 1));
  return d.toISOString().slice(0, 7);
}

function _payoutYen(n) { return '¥' + Number(n || 0).toLocaleString('ja-JP'); }

// 지급 예정일 한 줄
function payoutDueRowHtml(due, rows, todayStr) {
  const cnt = rows.length;
  const sum = rows.reduce(function(a, r) { return a + r.amount; }, 0);
  const unknown = rows.filter(function(r) { return r.amountUnknown; }).length;
  const overdue = due < todayStr;
  // ⚠️ 「이번 달」 구역 안에도 이미 지난 회차가 있다 — 이번 달이라고 안심시키면 안 된다.
  const days = Math.round((Date.parse(due + 'T00:00:00+09:00') - Date.parse(todayStr + 'T00:00:00+09:00')) / 86400000);
  const when = overdue
    ? `<span style="color:#C33;font-weight:700">지남 ${-days}일</span>`
    : (days === 0 ? '<span style="color:#B8741A;font-weight:700">오늘</span>' : `<span style="color:var(--muted)">D-${days}</span>`);
  return `<div style="display:flex;align-items:center;gap:14px;padding:9px 12px;border-bottom:1px solid var(--line)">
    <div style="width:96px;font-weight:700;font-size:13px">${esc(due)}</div>
    <div style="width:64px;text-align:right;font-size:13px">${cnt}건</div>
    <div style="width:110px;text-align:right;font-weight:700;font-size:13px">${esc(_payoutYen(sum))}</div>
    <div style="width:84px">${when}</div>
    ${unknown ? `<div style="font-size:11px;color:#C33">금액 미확정 ${unknown}건</div>` : ''}
    <button class="btn btn-ghost btn-xs" style="margin-left:auto;padding:2px 10px"
            onclick="openPayoutPersonList('${esc(due)}')">상세</button>
  </div>`;
}

function payoutSectionHtml(title, color, dues, byDue, todayStr, emptyText) {
  const rows = dues.map(function(d) { return payoutDueRowHtml(d, byDue[d], todayStr); }).join('');
  const cnt = dues.reduce(function(a, d) { return a + byDue[d].length; }, 0);
  const sum = dues.reduce(function(a, d) {
    return a + byDue[d].reduce(function(b, r) { return b + r.amount; }, 0);
  }, 0);
  return `<div style="margin-bottom:18px">
    <div style="display:flex;align-items:baseline;gap:10px;margin-bottom:6px">
      <div style="font-weight:700;font-size:13px;color:${color}">${esc(title)}</div>
      ${dues.length ? `<div style="font-size:12px;color:var(--muted)">${cnt}건 · ${esc(_payoutYen(sum))}</div>` : ''}
    </div>
    ${dues.length ? rows : `<div style="padding:10px 12px;color:var(--muted);font-size:12px">${esc(emptyText)}</div>`}
  </div>`;
}

function renderPayoutSummary() {
  const body = $('payoutSummaryBody');
  if (!body) return;
  const rows = _payoutRows || [];
  const todayStr = jstTodayStr();
  const thisMonth = todayStr.slice(0, 7);

  // 아직 안 보낸 것을 지급 예정일로 묶는다
  const byDue = {};
  rows.filter(function(r) { return _payoutUnsent(r) && r.due; })
      .forEach(function(r) { (byDue[r.due] = byDue[r.due] || []).push(r); });
  const dues = Object.keys(byDue).sort();

  const thisM = dues.filter(function(d) { return _payoutMonthOf(d) === thisMonth; });
  const before = dues.filter(function(d) { return _payoutMonthOf(d) < thisMonth; });
  const after  = dues.filter(function(d) { return _payoutMonthOf(d) > thisMonth; });

  // 「지급 완료」 — ⚠️ 예정일 조건을 걸지 않는다. 걸면 미리 보낸 건·당일 보낸 건·
  //   예정일이 미래인 건이 화면에서 사라진다(사양서 §4-1).
  const paidAll = rows.filter(function(r) { return r.status === 'paid' && r.due; });
  const paidThis = paidAll.filter(function(r) { return _payoutMonthOf(r.due) === _payoutPaidMonth; });
  const paidSum = paidThis.reduce(function(a, r) { return a + r.amount; }, 0);

  // 「지급일 기록 없음」 — cert_at 이 비어 예정일을 계산할 수 없는 것. 건수만.
  //   ⚠️ 보류·취소는 여기도 안 넣는다(이미 buildPayoutRows 에서 빠졌다).
  const noDate = rows.filter(function(r) { return !r.due; });

  body.innerHTML =
    payoutSectionHtml(`이번 달 (${esc(thisMonth)})`, '#2563EB', thisM, byDue, todayStr, '이번 달 지급 예정이 없습니다.')
  + payoutSectionHtml('지난 달 이전 — 밀린 것', '#C33', before, byDue, todayStr, '밀린 것이 없습니다.')
  + payoutSectionHtml('다음 달 이후', '#6B7280', after, byDue, todayStr, '다음 달 이후 예정이 없습니다.')
  + `<div style="border-top:1px solid var(--line);padding-top:14px;margin-top:4px">
      <div style="display:flex;align-items:center;gap:12px;margin-bottom:8px">
        <div style="font-weight:700;font-size:13px">지급 완료</div>
        <button class="btn btn-ghost btn-xs" onclick="shiftPayoutPaidMonth(-1)" style="padding:2px 8px">‹</button>
        <div style="font-size:13px;font-weight:700;min-width:74px;text-align:center">${esc(_payoutPaidMonth || '')}</div>
        <button class="btn btn-ghost btn-xs" onclick="shiftPayoutPaidMonth(1)" style="padding:2px 8px">›</button>
        <div style="font-size:13px;color:var(--muted)">${paidThis.length}건 · ${esc(_payoutYen(paidSum))}</div>
      </div>
      <div style="font-size:11px;color:var(--muted);line-height:1.7">
        지급 예정일이 그 달인 건 중 <b>이미 보낸 것</b>입니다. 실제 보낸 날짜가 아니라 <b>예정일</b>로 나눕니다
        — 6월 15일 예정분을 7월에 보냈어도 「6월」에 들어갑니다.
      </div>
      <div style="margin-top:14px;padding-top:12px;border-top:1px solid var(--line)">
        <button class="btn btn-ghost btn-sm" onclick="openPayoutPersonList(null)">
          <span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:middle">person_search</span>
          사람으로 찾기 (전 기간)
        </button>
        <span style="font-size:11px;color:var(--muted);margin-left:8px">지급대장이 사람 순이라 한 명씩 맞추는 편이 빠릅니다</span>
      </div>
      <div style="margin-top:12px;display:flex;align-items:center;gap:12px">
        <div style="font-weight:700;font-size:13px">지급일 기록 없음</div>
        <div style="font-size:13px;color:var(--muted)">${noDate.length}건</div>
      </div>
      <div style="font-size:11px;color:var(--muted);line-height:1.7;margin-top:2px">
        인증 성공일이 남아 있지 않아 지급 예정일을 계산할 수 없는 건입니다. 위 묶음 어디에도 안 들어갑니다.
      </div>
    </div>`;
}

// 「지급 완료」가 보여줄 달을 옮긴다. ⚠️ **과거·미래 양방향** — 과거만 되면
//   예정일이 미래인 지급 완료 건(4단계에서 등록할 115건)에 영영 못 닿는다.
function shiftPayoutPaidMonth(delta) {
  _payoutPaidMonth = _payoutShiftMonth(_payoutPaidMonth || jstTodayStr().slice(0, 7), delta);
  renderPayoutSummary();
}

// ══════════════════════════════════════════════════════════════════
// 지급 준비 — 사람별 묶음(화면 ㄴ) · 사람 검색(화면 ㄷ)
//
// ⚠️ **둘은 같은 화면이다.** 지급일 필터가 걸렸느냐만 다르다(사양서 §4-1).
//    별도 화면으로 만들면 한쪽만 고쳐지는 자리가 생긴다.
//
// ▶ 왜 사람으로 묶나
//   운영팀이 **이체 수수료를 아끼려 한 사람의 여러 건을 합해 한 번에** 보낸다.
//   그래서 「이 사람에게 얼마」가 한 줄로 나와야 페이팔에서 바로 칠 수 있다.
// ══════════════════════════════════════════════════════════════════

let _payoutPersonInfo = null;   // influencer_id → {name, name_kana, paypal_email} / null = 조회 실패
let _payoutDueFilter = null;    // 'YYYY-MM-DD' = 그 회차만 / null = 전 기간(사람 검색)
let _payoutPersonSearch = '';
let _payoutSelected = new Set();  // 선택한 열쇠말(influencerId|due)

// 이름·이메일을 통로에서 채운다. ⚠️ 원본 표를 직접 부르지 않는다(storage.js 주석 참조).
async function ensurePayoutPersonInfo() {
  const ids = [...new Set((_payoutRows || []).map(function(r) { return r.influencerId; }).filter(Boolean))];
  if (!ids.length) { _payoutPersonInfo = {}; return; }
  _payoutPersonInfo = await fetchPayoutInfluencerInfo(ids);   // 실패하면 null
}

// 한 사람의 표시 이름 — 미등록 건은 조회가 이름을 주고, 정산 행은 통로에서 채운다.
function payoutPersonOf(r) {
  const info = (_payoutPersonInfo && _payoutPersonInfo[r.influencerId]) || null;
  return {
    id: r.influencerId,
    name: r.name || (info && info.name) || null,
    kana: r.nameKana || (info && info.name_kana) || null,
    // ⚠️ 세 상태를 구분한다: 값 있음 / 등록 안 함 / **확인 실패**.
    //    셋을 같은 빈칸으로 그리면 돈을 보내는 사람이 무엇을 해야 할지 모른다.
    paypal: r.paypalEmail || (info && info.paypal_email) || null,
    paypalUnknown: _payoutPersonInfo === null && !r.paypalEmail,
  };
}

// 사람 → 지급일 → 건 으로 묶는다.
function groupSettlementsByPerson(rows) {
  const byPerson = {};
  rows.forEach(function(r) {
    const key = r.influencerId || '(미상)';
    if (!byPerson[key]) byPerson[key] = { person: payoutPersonOf(r), dues: {}, paid: [] };
    // 이름이 뒤 행에서 채워질 수 있으므로 비어 있으면 갱신
    const p = payoutPersonOf(r);
    if (!byPerson[key].person.name && p.name) byPerson[key].person = p;
    if (r.status === 'paid') { byPerson[key].paid.push(r); return; }
    const d = r.due || '(지급일 기록 없음)';
    (byPerson[key].dues[d] = byPerson[key].dues[d] || []).push(r);
  });
  return byPerson;
}

function _payoutSum(list) { return list.reduce(function(a, r) { return a + r.amount; }, 0); }

function payoutPaypalHtml(p) {
  if (p.paypal) return `<span style="font-size:11px;color:var(--muted);font-family:monospace">${esc(p.paypal)}</span>`;
  if (p.paypalUnknown) return '<span style="font-size:11px;color:#B8741A">페이팔 확인 실패</span>';
  return '<span style="font-size:11px;color:#C33">페이팔 미등록</span>';
}

// 지급일 묶음 한 줄 (+ 펼치면 건별)
function payoutDueGroupHtml(personId, due, list) {
  const key = personId + '|' + due;
  const checked = _payoutSelected.has(key) ? 'checked' : '';
  const items = list.map(function(r) {
    return `<div style="display:flex;gap:10px;padding:3px 0 3px 26px;font-size:12px;color:var(--muted)">
      <div style="flex:1">${esc(r.campaignNo ? '[' + r.campaignNo + '] ' : '')}${esc(r.campaignTitle || '(캠페인 미상)')}</div>
      <div style="width:88px;text-align:right">${esc(_payoutYen(r.amount))}</div>
    </div>`;
  }).join('');
  return `<div style="border-top:1px dashed var(--line);padding:6px 0">
    <div style="display:flex;align-items:center;gap:10px">
      <input type="checkbox" ${checked} onchange="togglePayoutSelect('${esc(key)}')" style="width:15px;height:15px">
      <div style="width:110px;font-size:12px;font-weight:600">${esc(due)}</div>
      <div style="width:50px;text-align:right;font-size:12px">${list.length}건</div>
      <div style="width:96px;text-align:right;font-weight:700;font-size:12px">${esc(_payoutSum(list) ? _payoutYen(_payoutSum(list)) : '—')}</div>
      <button class="btn btn-ghost btn-xs" onclick="payoutSendLocked()" style="padding:2px 10px;opacity:.55" title="3단계 이후 사용 가능합니다">보냄</button>
    </div>
    ${items}
  </div>`;
}

function payoutPersonCardHtml(entry) {
  const p = entry.person;
  const dues = Object.keys(entry.dues).sort();
  const allUnsent = dues.reduce(function(a, d) { return a.concat(entry.dues[d]); }, []);
  const paidSum = _payoutSum(entry.paid);
  return `<div style="border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:10px">
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      <div style="font-weight:700;font-size:13px">${esc(p.name || '(이름 미상)')}</div>
      ${p.kana ? `<div style="font-size:11px;color:var(--muted)">${esc(p.kana)}</div>` : ''}
      ${payoutPaypalHtml(p)}
      <div style="margin-left:auto;font-size:12px">
        ${allUnsent.length}건 · <b>${esc(_payoutYen(_payoutSum(allUnsent)))}</b>
      </div>
    </div>
    ${dues.map(function(d) { return payoutDueGroupHtml(p.id, d, entry.dues[d]); }).join('')}
    ${entry.paid.length ? `<div style="border-top:1px dashed var(--line);margin-top:6px;padding-top:6px;font-size:12px;color:#16A34A">
        이미 기록됨 ${entry.paid.length}건 · ${esc(_payoutYen(paidSum))}
      </div>` : ''}
  </div>`;
}

function togglePayoutSelect(key) {
  if (_payoutSelected.has(key)) _payoutSelected.delete(key); else _payoutSelected.add(key);
  renderPayoutPersonBody();   // 검색창·검색어를 유지한 채 목록만 갱신
}

// 잠긴 「보냄」 — ⚠️ 3단계 전에 기록하면 **오늘 날짜·계산 금액으로 확정**되고
//   되돌릴 수 없다(사양서 §1-7). 이 잠금이 그것을 막는 유일한 장치다.
function payoutSendLocked() {
  if (typeof toast === 'function') {
    toast('아직 기록할 수 없습니다 — 실제 보낸 날짜와 금액을 입력할 수 있게 된 뒤에 열립니다', 'info');
  }
}

async function openPayoutPersonList(dueStr) {
  _payoutDueFilter = dueStr || null;
  _payoutSelected.clear();
  const body = $('payoutSummaryBody');
  if (body) body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';
  if (_payoutPersonInfo === undefined || _payoutPersonInfo === null) await ensurePayoutPersonInfo();
  renderPayoutPersonList();
}

function backToPayoutSummary() {
  _payoutDueFilter = null;
  _payoutPersonSearch = '';
  _payoutSelected.clear();
  renderPayoutSummary();
}

function onPayoutPersonSearch(v) {
  _payoutPersonSearch = (v || '').trim().toLowerCase();
  renderPayoutPersonBody();   // ⚠️ 껍데기를 다시 그리면 검색창 포커스가 날아간다
}

// 껍데기(뒤로가기·제목·검색창)는 **한 번만** 그린다.
//   ⚠️ 검색창을 목록과 함께 다시 그리면 **한 글자 칠 때마다 포커스를 잃는다** —
//      입력칸이 통째로 새 노드로 바뀌기 때문이다. 「사람으로 빨리 찾기」가 이 작업의
//      존재 이유(487번 → 121번)인데 그러면 한 글자마다 다시 클릭해야 한다.
//      관리자 메시지 화면(admin-messaging.js)이 같은 이유로 검색창을 바깥에 둔다.
function renderPayoutPersonList() {
  const body = $('payoutSummaryBody');
  if (!body) return;
  body.innerHTML = `
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;flex-wrap:wrap">
      <button class="btn btn-ghost btn-sm" onclick="backToPayoutSummary()" style="padding:2px 8px">← 지급일 요약</button>
      <div style="font-weight:700;font-size:14px">${_payoutDueFilter ? esc(_payoutDueFilter) + ' 지급 예정' : '전체 기간'}</div>
      <input id="payoutPersonSearchInput" class="admin-filter-search"
             placeholder="이름(한자·가나)·페이팔 이메일로 검색"
             value="${esc(_payoutPersonSearch)}" oninput="onPayoutPersonSearch(this.value)"
             style="min-width:260px;margin-left:auto">
    </div>
    <div id="payoutPersonListBody"></div>`;
  renderPayoutPersonBody();
}

// 목록만 다시 그린다(검색창은 건드리지 않는다).
function renderPayoutPersonBody() {
  const body = $('payoutPersonListBody');
  if (!body) return;
  const all = _payoutRows || [];
  // 지급일 필터가 있으면 그 회차만(화면 ㄴ), 없으면 전 기간(화면 ㄷ).
  let rows = _payoutDueFilter
    ? all.filter(function(r) { return r.due === _payoutDueFilter && _payoutUnsent(r); })
    : all;
  const byPerson = groupSettlementsByPerson(rows);
  let entries = Object.keys(byPerson).map(function(k) { return byPerson[k]; });

  // 사람 검색 — 한자·가나·페이팔 이메일 셋 다에서 찾는다(대장이 어느 쪽으로 적혀 있는지 모른다)
  if (_payoutPersonSearch) {
    entries = entries.filter(function(e) {
      const p = e.person;
      return [p.name, p.kana, p.paypal].some(function(v) {
        return v && String(v).toLowerCase().includes(_payoutPersonSearch);
      });
    });
  }
  entries.sort(function(a, b) { return String(a.person.name || '').localeCompare(String(b.person.name || '')); });

  const selectedRows = [];
  entries.forEach(function(e) {
    Object.keys(e.dues).forEach(function(d) {
      if (_payoutSelected.has(e.person.id + '|' + d)) selectedRows.push.apply(selectedRows, e.dues[d]);
    });
  });

  const total = entries.length;
  const doneCount = entries.filter(function(e) { return e.paid.length > 0; }).length;

  // 진행 표시 — ⚠️ 이게 없으면 어디까지 했는지 안 보여 중간에 놓는다(8월에 실제로 그랬다).
  //   ⚠️ **회차 상세(화면 ㄴ)에서는 쓰지 않는다.** 그 화면은 「아직 안 보낸 것」만 넘겨받아
  //      이미 보낸 사람이 애초에 목록에 없다 — 「N명 중 0명 처리」가 **구조적으로 항상 0**이라
  //      진행이 멈춘 것처럼 보인다. 전 기간(화면 ㄷ)에서만 뜻이 있다.
  const progressHtml = _payoutDueFilter
    ? `<div style="font-size:12px;color:var(--muted);margin-bottom:10px">${total}명 · 합계 <b style="color:var(--ink)">${esc(_payoutYen(entries.reduce(function(a, e) {
        return a + Object.keys(e.dues).reduce(function(b, d) { return b + _payoutSum(e.dues[d]); }, 0); }, 0)))}</b></div>`
    : `<div style="font-size:12px;color:var(--muted);margin-bottom:10px">${total}명 중 <b style="color:var(--ink)">${doneCount}명</b> 처리 · ${total - doneCount}명 남음</div>`;

  body.innerHTML = `
    ${progressHtml}
    ${entries.length ? entries.map(payoutPersonCardHtml).join('')
      : '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">대상이 없습니다.</div>'}
    <div style="position:sticky;bottom:0;background:var(--bg,#fff);border-top:1px solid var(--line);padding:10px 2px;font-size:13px">
      선택 ${_payoutSelected.size}묶음 · ${selectedRows.length}건 · 합계 <b>${esc(_payoutYen(_payoutSum(selectedRows)))}</b>
    </div>`;
}
