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
// 정산 관리에 **들어갈 때 열 화면** — 'list'(정산 목록) / 'unregistered'(미등록) / null(기본=지급 준비).
//   ⚠️ 필터만 걸고 페인을 전환하면 안 된다. `loadSettlements()` 는 마지막에 **늘** 지급 준비를
//      켜므로, 걸어 둔 필터가 화면에 반영되지 않는다 — 사이드바 「정산대기」 배지가 실제로
//      그랬다(2026-08-18 「첫 화면=지급 준비」 변경 이후, 눌러도 지급 준비만 떴다).
//   ⚠️ **한 번 쓰고 버린다** — `loadSettlements()` 시작에서 꺼내 즉시 비운다. 안 비우면
//      다음에 그냥 들어올 때도 그 화면이 열린다.
let _settlementEntryView = null;
// 「정산대기」 탭에서 일괄 송금완료로 고른 정산 id 들.
//   ⚠️ 화면에 그려진 행만이 아니라 **필터를 통과한 정산대기 전부**가 선택 대상이다
//      (목록이 조금씩 그려지는 구조라, 보이는 것만 고르면 스크롤 위치에 따라 결과가 달라진다).
//   ⚠️ 필터·탭이 바뀌면 매 렌더에서 **보이지 않게 된 선택은 버린다** — 안 보이는 행에
//      돈 처리가 걸리는 것이 가장 나쁘다.
let _settlementSelected = new Set();

// 날짜 칸('YYYY-MM-DD') ↔ 시각 값 변환.
//   ⚠️ 시간대를 **일본 표준시로 못 박는다.** 브라우저 기본값에 맡기면 관리자 PC 설정에
//      따라 하루가 밀린다(한국·일본은 같은 시간대지만, 그 사실에 기대지 않는다).
function _settlementJstMidnight(dateStr) {
  return dateStr ? (String(dateStr).trim() + 'T00:00:00+09:00') : null;
}
function _settlementDateInputValue(ts) {
  if (!ts) return '';
  const t = Date.parse(ts);
  if (Number.isNaN(t)) return '';
  return new Date(t + 9 * 3600 * 1000).toISOString().slice(0, 10);
}

// ── 「송금완료일」이 실제 송금일이 아니라 **기록일**인 행을 가르는 날 ──────────
// 이 날 전에 등록된 정산은 **실제 송금일을 넣을 칸 자체가 없어서**, 등록한 날짜(`now()`)가
// 송금일 자리에 들어가 있다. 실제로는 그보다 앞서 보낸 돈이다.
//
// ⚠️ 이름을 「2026년 8월 5일」이 아니라 **「실제 송금일을 넣을 수 있게 된 날」**로 지었다.
//    날짜만 박아 두면 **왜 그 날인지가 코드에서 사라진다.**
// ⚠️ 이 날짜와 비교하는 것은 **행이 만들어진 날**(`created_at`)이다. 송금일이 아니다 —
//    아래 settlementPaidAtIsRecordDate 주석 참조.
// ⚠️ 이 값이 맞는 근거(2026-08-18 운영 실측): 정산 행은 **204건뿐이고 송금일이 7/30(1건)·
//    8/4(203건)에 몰려 있다. 8/5 이후는 0건.** 그리고 송금 기록 경로는 1단계부터 **잠겨
//    있어**, 이 기능이 나가는 순간(잠금 해제 = 작업 7)까지 새 행이 생길 수 없다.
//    즉 8/5 ~ 배포일 사이는 **비어 있을 수밖에 없어** 어느 날로 잡아도 결과가 같다.
// ⚠️ 그 전제가 깨지면(잠금을 먼저 풀고 나중에 배포한다면) 이 날짜를 **실제 배포일로
//    옮겨야 한다.** 안 옮기면 그 사이 기록된 건이 「정확한 날짜」로 잘못 취급된다.
const SETTLEMENT_ACTUAL_PAID_AT_SINCE = '2026-08-05';

function settlementPaidAtIsRecordDate(s) {
  if (!s || !s.paid_at) return false;
  // ★ 기준은 **행이 만들어진 날**(created_at)이지 송금일이 아니다.
  //   ⚠️ 송금일로 재면 앞으로 등록할 과거분이 전부 잘못 걸린다 — 6월에 보낸 돈을
  //      지금 6월 15일로 **정확히** 적어 넣어도 「기록일」이라고 표시된다. 그건 이 기능이
  //      하려는 일 자체(과거 날짜를 제대로 적기)를 부정하는 표시다.
  //      2026-08-18 개발서버에서 실제로 그렇게 떴다 — 화면을 열어 보기 전에는 안 보였다.
  //   ⚠️ 반대로 만들어진 날로 재면 정확히 「그 칸이 없던 때에 등록된 행」만 걸린다.
  //      운영 204건은 7/30~8/4 에 만들어졌고, 앞으로 만들어질 행은 전부 이 날 이후다.
  const d = _settlementDateInputValue(s.created_at);
  return !!d && d < SETTLEMENT_ACTUAL_PAID_AT_SINCE;
}

// 말풍선 문구 — 한 곳에 모아 둔다(목록·지급 준비 두 곳이 같은 말을 해야 한다).
const SETTLEMENT_RECORD_DATE_TIP = [
  '이 날짜는 시스템에 기록한 날입니다.',
  '실제로 송금한 날이 아닙니다 — 실제 송금일을 남기는 칸이 생기기 전에 등록된 건이라, 등록한 날짜가 대신 들어가 있습니다.',
  '실제 송금일은 지급대장을 확인해 주세요.'
].join('\n');
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
  // ★ 「미등록」 = 인증에 성공했으나 **정산 행이 아직 없는 응모**.
  //   ⚠️ 다른 탭과 달리 `settlements` 표에 행이 없어 `_settlements` 로는 못 센다.
  //      별도 조회(get_past_unregistered_settlements)의 결과를 쓴다.
  //   ⚠️ 화면에서 「과거」라는 말을 완전히 뺀다 — 도입일이 켜지면 「과거」가 아닌 건도
  //      여기 들어오므로, 그 이름을 남기면 그때 거짓말이 된다(사양서 §4-2).
  { code: 'unregistered', label: '미등록', virtual: true },
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
// 헬퍼는 전부 기존 공용(campThumbUrl·getRecruitTypeBadgeKoSm — ui.js / campPreviewBtn — lib/shared.js).
// 빌드 순서상 셋 다 이 파일보다 먼저 로드된다. 썸네일·모집타입은 fetchSettlements 가
// campaigns 임베드로 이미 가져오는 img1·recruit_type 사용(추가 조회 없음).
// 실제로 보낸 금액 칸.
//   ⚠️ 빈 값은 「계산 금액과 같음」이지 **0원이 아니다.** 그래서 0 이 아니라 말로 그린다.
//   계산값과 다를 때만 눈에 띄게 — 대부분은 같아서, 늘 강조하면 다른 건이 묻힌다.
function settlementActualAmountCell(s) {
  const actual = s.paid_amount_jpy;
  if (actual == null) {
    return s.status === 'paid'
      ? '<span style="font-size:11px;color:var(--muted)" title="시스템 계산 금액 그대로 보냈습니다">계산액 그대로</span>'
      : '<span style="font-size:11px;color:var(--muted)">—</span>';
  }
  if (Number(actual) === Number(s.amount_jpy)) {
    return `<div style="font-weight:600;white-space:nowrap">${settlementAmountYen(actual)}</div>`;
  }
  const less = Number(actual) < Number(s.amount_jpy);
  return `<div style="font-weight:700;color:#9A3412;white-space:nowrap">${settlementAmountYen(actual)}</div>`
    + `<div style="font-size:10px;color:#9A3412" title="시스템 계산 금액과 다릅니다">계산 ${settlementAmountYen(s.amount_jpy)}보다 ${less ? '적음' : '많음'}</div>`;
}

function settlementCampCell(camp) {
  camp = camp || {};
  const campNoBadge = camp.campaign_no
    ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted)">${esc(camp.campaign_no)}</span>`
    : '';
  const rtBadge = (typeof getRecruitTypeBadgeKoSm === 'function')
    ? getRecruitTypeBadgeKoSm(camp.recruit_type) : '';
  // 이미지 없으면 아이콘 폴백, 있으면 썸네일 + 원본 URL 폴백(campThumbUrl + data-orig)
  const thumb = camp.img1
    ? `<img src="${esc(storageThumbUrl(camp.img1))}" data-orig="${esc(camp.img1)}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">`
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
  // ★ 이번 진입에서 열 화면. **여기서 꺼내 즉시 비운다**(한 번 쓰고 버리는 값).
  const entryView = _settlementEntryView;
  _settlementEntryView = null;
  // 재진입 시 열려 있던 화면을 정리한다 — 안 닫으면 **옛 데이터가 그대로** 남는다.
  if ($('settlementPastView') && $('settlementPastView').style.display !== 'none') {
    closePastUnregView();
  }
  // 송금 내역을 보다 나갔다 들어오면 첫 화면(지급 준비)으로 — 옛 목록을 남기지 않는다.
  //   ⚠️ 여기서 송금 내역만 끄면 지급 준비가 켜질 때까지(백필·재조회 동안) **화면이 통째로 빈다.**
  //      그래서 지급 준비를 **먼저 켜 두고** 끈다(지급 준비 화면이 곧 「불러오는 중」을 그린다).
  if (entryView !== 'transfers' && $('settlementTransferView') && $('settlementTransferView').style.display !== 'none') {
    const pv = $('settlementPayoutView');
    if (pv && entryView !== 'list' && entryView !== 'unregistered') pv.style.display = 'flex';
    _hideTransferView();
  }
  // ⚠️ **지급 준비는 여기서 닫지 않는다.** 닫으면 정산 목록이 켜지고, 이 함수 끝에서
  //    다시 지급 준비로 돌아온다 — 그 사이가 **목록이 번쩍이는 구간**이다.
  //    (HTML 의 처음 표시가 지급 준비라, 첫 진입에도 이 조건이 참이 되어 매번 번쩍였다.)
  //    옛 데이터가 남을 걱정은 없다 — 아래 openPayoutPrepView() 가 처음부터 다시 그린다.
  //    다만 지난번에 보던 **회차·검색어·선택은 비운다**(안 비우면 남의 회차가 열린 채로 뜬다).
  _payoutDueFilter = null;
  _payoutPersonSearch = '';
  if (typeof _payoutSelected !== 'undefined' && _payoutSelected) _payoutSelected.clear();
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

  // ★ 정산 관리의 **첫 화면은 「지급 준비」**다(2026-08-18 사용자 결정).
  //   ⚠️ 그 전에는 정산 목록의 「정산대기」 탭으로 열렸는데, 자동 등록이 꺼져 있어
  //      **정산대기가 구조적으로 0건**이라 들어올 때마다 빈 화면이 보였다.
  //      지급 준비는 「이번 달에 누구에게 얼마 보내나」에 답하는 화면이고 실제 데이터가 있다.
  //   ⚠️ 다른 화면으로 가는 길은 페인 맨 위 탭 줄(settlementNavBar — openSettlementTab)이다.
  //   ⚠️ 조회 실패해도 화면 전환은 그대로 둔다 — 그 화면이 실패를 스스로 알린다.
  //   ⚠️ 다만 **부르는 쪽이 열 화면을 지정했으면 그쪽을 따른다**(`_settlementEntryView`).
  //      사이드바의 배지·경고 표시처럼 「이 목록을 보여 달라」고 들어오는 경로가 있는데,
  //      여기서 무조건 지급 준비를 켜면 그 요청이 조용히 덮인다.
  if (entryView === 'transfers') {
    openTransferHistoryView();   // 지급 준비·목록·미등록은 그 함수가 닫는다(네 화면 배타)
  } else if (entryView === 'unregistered') {
    // 지급 준비 화면은 showUnregisteredTab() 이 직접 닫는다(세 화면 배타).
    _settlementFilters.status = 'unregistered';
    showUnregisteredTab();
  } else if (entryView === 'list') {
    // ⚠️ 전제 — 이 값을 거는 곳(enterSettlementsWithView)이 상태 탭을 함께 목록 쪽으로
    //    맞춰 둔다. 안 맞춰 두면 아래 closePayoutPrepView() 가 「미등록」이라 판단해
    //    방금 감춘 미등록 화면을 다시 켠다.
    hideUnregisteredTab();
    closePayoutPrepView();
    renderSettlementsList();     // 걸어 둔 상태 탭·필터를 화면에 반영
  } else {
    openPayoutPrepView();        // await 안 함 — 목록 조회를 막지 않는다
  }
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
// ✅ 마이그레이션 337 로 **컷오프 조건이 빠져** 도입일과 무관하게 전 구간이 나온다.
//   (그 전에는 도입일 이후 건이 통째로 빠져 「미등록인데 목록에 없다」가 될 상태였다.)
//
// 진입 버튼 배지가 없어져(2단계) 이 함수가 하는 일이 바뀌었다:
//   ① 「미등록」 **탭 건수** 갱신  ② **사이드바 경고 표시**  ③ 금액 미확정 안내
async function refreshPastUnregEntryInfo() {
  const banner = $('settlementAmountIssueBanner');
  const text = $('settlementAmountIssueText');
  let rows = [];
  try {
    rows = await fetchPastUnregisteredSettlements();
  } catch (e) {
    return;  // 권한 없음·조회 실패는 무시(기존 목록 표시에 영향 주지 않는다)
  }
  // ⚠️ 조회 실패는 null 이다(빈 목록 아님). 0 으로 덮으면 배지가 사라져
  //    「미등록 건이 없다」로 보인다 — 실패했을 뿐인데. 그대로 두고 나간다.
  if (rows === null) return;
  _pastUnregRows = rows;
  _pastUnregLoaded = true;
  renderSettlementStatusTabs();      // 탭 건수 「…」 → 실제 숫자
  applySettlementUnregWarning();     // 사이드바 경고
  const issueCount = rows.filter(r => pastUnregHasIssue(r)).length;
  if (banner && text) {
    if (issueCount > 0) {
      // [B-8] 이 목록에 오는 「금액 미확정」은 **리뷰어형(가구매 포함)에 제품 가격이 없는 경우뿐**이다 —
      //   기프팅·방문형 무보수 캠페인은 후보에서 아예 빠져(마이그레이션 264) 여기 나오지 않는다.
      //   예전 문구는 일어날 수 없는 「리워드 금액(기프팅·방문형)」 안내를 함께 적고 있었다.
      text.textContent = `인증은 끝났지만 캠페인에 제품 가격이 없어 정산 금액을 정할 수 없는 리뷰어형 건이 ${issueCount}건 있습니다. 캠페인 편집에서 제품 가격을 입력하면 자동으로 등록됩니다.`;
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
    // ⚠️ 미등록은 정산 행이 없어 `counts` 에 안 잡힌다. 별도 조회 결과에서 센다.
    //    아직 안 받아왔으면 건수 자리를 비운다 — **0 으로 그리면 「없다」로 읽힌다.**
    const n = tab.code === ''            ? totalAll
            : tab.virtual                ? (_pastUnregLoaded ? _pastUnregRows.length : null)
            : (counts[tab.code] || 0);
    const isOn = tab.code === active;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    // 아직 안 받아온 미등록은 건수를 「…」로 — 0 과 구분한다
    const cnt = (n === null) ? '…' : n;
    return `<button type="button" class="${cls}" data-status="${tab.code}" onclick="setSettlementStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${cnt})</span></button>`;
  }).join('');
}

// 상태 탭 클릭 → 단일 상태 필터로 목록 재조회 (탭 활성 표시는 renderSettlementsList 내부 재렌더로 갱신)
function setSettlementStatusTab(btn) {
  const prev = _settlementFilters.status || '';
  const next = btn.dataset.status || '';
  // ★ **미등록을 오가는 전환에서만** 공용 필터를 비운다(2026-08-19 사용자 결정).
  //   ⚠️ 미등록(509건)과 정산 목록(204건)은 **대상 자료가 다르다.** 선택이 넘어가면 한쪽에만
  //      있는 캠페인은 말없이 사라지고, 양쪽에 있는 캠페인은 걸린 채 남는다 — 그 상태에서
  //      「전체 선택 → 송금완료 기록」을 누르면 되돌릴 수 없다.
  //   ⚠️ 상태 탭끼리(송금완료 ↔ 보류)는 **비우지 않는다** — 같은 자료라 유지가 맞고, 지금까지의
  //      동작이기도 하다. 이 비대칭은 의도된 것이다.
  if (prev !== next && (prev === 'unregistered' || next === 'unregistered')) {
    clearSettlementSharedFilters();
  }
  _settlementFilters.status = next;
  // ★ 「미등록」은 정산 행이 없어 같은 목록에 못 그린다 — 전용 화면으로 바꿔 그린다.
  //   ⚠️ 옛 「과거 미등록」 뷰의 함수·요소를 **옮기지 않고 그대로 재사용**한다.
  //      18개 함수·14개 요소를 옮기다 하나 빠뜨리면 **기능이 조용히 사라지는데**
  //      화면상 티가 안 난다(필터 하나가 없어져도 원래 있었는지 아무도 모른다).
  //      바뀌는 것은 **진입 경로뿐**이라 안쪽은 건드릴 이유가 없다.
  if (_settlementFilters.status === 'unregistered') { showUnregisteredTab(); return; }
  hideUnregisteredTab();
  renderSettlementsList();
}

// 「미등록」 탭 — 옛 뷰를 그 자리에서 보여준다(별도 화면이 아니라 탭의 내용물).
function showUnregisteredTab() {
  const main = $('settlementMainView'), past = $('settlementPastView');
  if (!past) return;
  // ⚠️ **지급 준비 화면을 여기서 반드시 닫는다.** 세 화면(정산 목록·미등록·지급 준비)은
  //    서로 배타여야 하는데, 지급 준비는 목록 화면의 **형제**라 이 함수가 메인 뷰를 켜는
  //    것만으로는 안 사라진다 — 지급 준비와 미등록이 **세로로 겹쳐 한 화면에 둘 다** 뜬다.
  //    실제 경로: 사이드바 「정산 관리」 옆 경고 표시 클릭 → 페인 진입이 첫 화면으로
  //    지급 준비를 켜고(loadSettlements), 그 직후 이 함수가 미등록을 켠다(2026-08-19 보고).
  //    openPayoutPrepView() 가 반대 방향으로 hideUnregisteredTab() 을 부르는 것과 짝이다.
  const payout = $('settlementPayoutView');
  if (payout) payout.style.display = 'none';
  _hideTransferView();                  // 넷째 화면(송금 내역)도 짝으로 닫는다
  applySettlementSharedFilterMode(true);
  // 상태 탭 바는 계속 보여야 하므로 메인 뷰의 **목록 부분만** 감춘다.
  const listCard = $('settlementListCard');
  if (listCard) listCard.style.display = 'none';
  past.style.display = 'flex';
  if (main) {
    main.style.display = 'flex';
    // ⚠️ **메인 뷰가 남은 높이를 다 먹지 않게 한다.** 이 페인은 세로 flex 이고 메인 뷰에
    //    `flex:1` 이 걸려 있어, 목록을 감춰도 **머리글만 남은 채 화면 절반을 차지**한다.
    //    그러면 그 아래 미등록 목록이 저 밑으로 밀려 **한참 스크롤해야 보인다**
    //    (2026-08-19 사용자 보고 — 겹침을 고친 뒤에도 남아 있던 두 번째 원인).
    //    목록을 도로 켤 때 `flex:1` 을 되돌리는 짝이 hideUnregisteredTab 에 있다.
    main.style.flex = '0 0 auto';
  }
  renderSettlementStatusTabs();
  refreshSettlementNav();
  loadPastUnregSettlements();
}

// 공용 줄의 미등록 전용 요소를 켜고 끈다 — 「모집 형식」·「초기화」는 미등록에서만,
// 「엑셀」은 미등록에서만 감춘다(그 버튼은 **정산 목록**을 내보낸다).
//   ⚠️ 끌 때 「모집 형식」 **값도 비운다.** 안 비우면 걸린 줄 모르는 필터가 남아, 다른 탭에서
//      돌아왔을 때 목록이 조용히 걸러진 채로 보인다 — 그 상태의 「전체 선택」이 가장 위험하다.
function applySettlementSharedFilterMode(isUnregistered) {
  const typeGroup = $('settlementTypeFilterGroup');
  if (typeGroup) typeGroup.style.display = isUnregistered ? '' : 'none';
  const resetBtn = $('settlementResetBtn');
  if (resetBtn) resetBtn.style.display = isUnregistered ? '' : 'none';
  // 「엑셀」 표시는 refreshSettlementNav() 가 정한다(탭 줄로 옮겨 목록 탭에서만 보인다).
  if (!isUnregistered) {
    const typeEl = $('settlementTypeFilter');
    if (typeEl) typeEl.value = '';
  }
}

function hideUnregisteredTab() {
  applySettlementSharedFilterMode(false);
  _hideTransferView();                  // 목록·지급 준비 쪽으로 돌아가는 모든 길이 여기를 지난다
  // 메인 뷰가 다시 목록을 담으므로 **남은 높이를 채우도록 되돌린다**(showUnregisteredTab 의 짝).
  //   안 되돌리면 목록이 머리글 높이에 갇혀 스크롤이 안 된다.
  const main = $('settlementMainView');
  if (main) main.style.flex = '1';
  const past = $('settlementPastView');
  if (past && past.style.display !== 'none') {
    if (pastUnregLazy) { pastUnregLazy.destroy(); pastUnregLazy = null; }
    past.style.display = 'none';
  }
  const listCard = $('settlementListCard');
  if (listCard) listCard.style.display = '';
  refreshSettlementNav();
}

// (미등록 탭 아래 안내 한 줄은 없앴다 — 2026-08-19 사용자 요청. 도입일 유무로 문구를 갈라
//  보여주던 applyUnregisteredNotice() 도 함께 제거했다.)

// 정산 관리로 **열 화면을 지정해서** 들어간다 — 사이드바의 숫자 배지·경고 표시 공용.
//   ⚠️ 필터만 걸고 들어가면 안 된다. 페인 진입이 **첫 화면으로 지급 준비를 켜면서 그 필터를
//      덮는다** — 배지를 눌러도 정산대기 목록이 아니라 지급 준비가 뜨던 원인이다.
//   ⚠️ 필터도 의도도 **실제로 이동이 일어나는 순간에만** 건다. 미리 걸면 캠페인 폼의
//      「저장 안 한 변경」 확인창에서 **취소**했을 때 이동은 없이 값만 남아, 한참 뒤 그냥
//      정산 관리에 들어올 때 엉뚱한 화면이 열린다(2026-08-19 리뷰 지적).
//   ⚠️ `navAdminPaneReload` 를 그대로 못 쓰는 이유가 이것뿐이다 — 그 함수는 값을 걸 자리를
//      내주지 않는다. 나머지 동작(히스토리 기록·사이드바 활성 표시)은 그 함수와 똑같이
//      `switchAdminPane(pane, null, true)` 로 맞춘다. 저장 확인 게이트도 그대로 탄다.
function enterSettlementsWithView(view) {
  const go = function() {
    _settlementFilters.status = (view === 'unregistered') ? 'unregistered' : 'pending';
    _settlementFilters.search = '';
    _settlementFilters.campaignIds = [];
    const s = document.getElementById('settlementSearch'); if (s) s.value = '';
    if (typeof clearMultiFilter === 'function') clearMultiFilter('settlementCampMulti', '전체 캠페인');
    if (typeof switchAdminPane === 'function') {
      _settlementEntryView = view;      // 진입 로더가 꺼내 쓰고 즉시 비운다
      switchAdminPane('settlements', null, true);
      return;
    }
    // 페인 전환 함수가 없으면(빌드 어긋남) 의도를 소비할 곳도 없다 — 제자리에서 직접 그린다.
    if (view === 'unregistered') { showUnregisteredTab(); return; }
    hideUnregisteredTab(); closePayoutPrepView(); reloadSettlementsData();
  };
  if (typeof campLeaveGuard === 'function') { campLeaveGuard(go); return; }
  go();
}

// 사이드바 「정산 관리」 배지 클릭 → 다른 필터 초기화 후 「정산대기」만 (기준: openDelivPendingReview)
function openSettlementsPending() {
  enterSettlementsWithView('list');
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
  // ⚠️ 미등록 탭에서는 손대지 않는다(위 syncPastUnregCampaignOptions 와 짝) — 두 탭은
  //    대상 자료가 달라 선택지 목록이 서로 다르다.
  if (_settlementFilters.status === 'unregistered') return;
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
  syncCampMultiFilter('settlementCampMulti', campOptionsSource, () => onSettlementFilterChange(), campCounts);
}

function renderSettlementsList() {
  const tbody = $('settlementsTableBody');
  if (!tbody) return;
  syncSettlementCampaignOptions();
  renderSettlementStatusTabs();           // 상태 탭 건수·활성 표시 갱신
  const rows = getFilteredSettlements();  // readSettlementFilters 내부 호출

  // ⚠️ 필터·탭이 바뀌어 **화면에서 사라진 선택은 버린다.** 안 보이는 행에 돈 처리가
  //    걸리는 것을 막는다(고른 뒤 탭을 옮기면 선택이 남아 있던 상태가 된다).
  const visiblePending = new Set(rows.filter(r => r.status === 'pending').map(r => r.id));
  _settlementSelected.forEach(id => { if (!visiblePending.has(id)) _settlementSelected.delete(id); });

  const cnt = $('settlementsTotalCount');
  if (cnt) cnt.textContent = `총 ${rows.length}건`;
  const sumEl = $('settlementsSumAmount');
  if (sumEl) {
    // ⚠️ 실제 송금액이 있으면 그것으로 센다(공용 헬퍼) — 계산값만 더하면 이 합계만 다르다.
    const sum = rows.reduce((acc, s) => acc + settlementEffectiveAmount(s), 0);
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
    emptyHtml: '<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 정산 건이 없습니다.</td></tr>',
  });
  updateSettlementBulkBar();
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 「정산대기」 일괄 선택 (마이그레이션 340)
// ════════════════════════════════════════════════════════════════════
//
// 「과거 미등록」 화면의 선택 방식을 그대로 옮겨 왔다 — 같은 화면 안에서 고르는 법이
// 두 가지면 헷갈린다.
//   · 전체 선택은 **필터를 통과한 정산대기 전부**(그려진 것만이 아니다)
//   · 개별 체크는 재렌더 없이 툴바만 갱신(스크롤 유지)

// 일괄 처리 대상이 될 수 있는 행 — 정산대기이면서 PayPal 이 등록된 건.
//   ⚠️ PayPal 미등록 건은 서버도 건너뛴다. 화면에서 미리 잠가, 처리 후 건수가 줄어
//      「왜 고른 수보다 적게 됐나」를 묻게 되는 일을 없앤다.
function settlementSelectableRows() {
  return getFilteredSettlements().filter(r => r.status === 'pending' && r.paypal_email);
}

function settlementToggleAll(cb) {
  if (cb && cb.checked) settlementSelectableRows().forEach(r => _settlementSelected.add(r.id));
  else _settlementSelected.clear();
  renderSettlementsList();
}

function settlementOnRowCheck(cb) {
  const id = cb && cb.dataset ? cb.dataset.settlementId : '';
  if (!id) return;
  if (cb.checked) _settlementSelected.add(id);
  else _settlementSelected.delete(id);
  updateSettlementBulkBar();
}

function settlementClearSelection() {
  _settlementSelected.clear();
  renderSettlementsList();
}

function updateSettlementBulkBar() {
  const bar = $('settlementBulkBar');
  const all = $('settlementSelectAll');
  const selectable = settlementSelectableRows();
  let count = 0, sum = 0;
  _settlementSelected.forEach(id => {
    const r = _settlements.find(x => x.id === id);
    if (r) { count++; sum += settlementEffectiveAmount(r); }
  });
  if (bar) bar.style.display = count ? 'flex' : 'none';
  const cnt = $('settlementBulkCount');
  if (cnt) cnt.textContent = `선택 ${count}건 · 합계 ${settlementAmountYen(sum)}`;
  if (all) {
    // 전체선택 체크박스는 **정산대기 탭에서만** 의미가 있다 — 다른 탭에서는 고를 것이 없다.
    all.disabled = selectable.length === 0;
    all.checked = selectable.length > 0 && count === selectable.length;
    all.indeterminate = count > 0 && count < selectable.length;
  }
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
  // ⚠️ 이 칸에는 **실제 송금일과 기록일이 섞여 있다.** 열 이름은 「송금완료일」 그대로 두고
  //    (「실제 송금일」로 바꾸면 옛 행에 대해 화면이 사실이 아닌 말을 하게 된다),
  //    섞인 쪽에만 표를 붙인다 — 늘 떠 있는 안내는 아무도 안 읽는다.
  const paidDate = s.paid_at
    ? `<span style="font-size:12px">${formatDate(s.paid_at)}</span>`
      + (settlementPaidAtIsRecordDate(s)
          ? `<div style="margin-top:2px"><span style="font-size:10px;background:#EEE;color:#666;padding:1px 5px;border-radius:3px;cursor:help" title="${esc(SETTLEMENT_RECORD_DATE_TIP)}">기록일</span></div>`
          : '')
    : '<span style="font-size:11px;color:var(--muted)">—</span>';

  // 신청 반려·취소로 자동 보류된 건(고정 메모 '신청 반려로 자동 보류')은 관리자가 구분하도록 앰버 배지.
  //   복원은 on_hold 의 「보류 해제」 버튼(mark_settlement_revert)으로 정산대기 복귀.
  const autoHoldBadge = (s.status === 'on_hold' && (s.memo || '').includes('자동 보류'))
    ? `<div style="margin-top:3px"><span style="font-size:10px;background:#FEF3C7;color:#92400E;font-weight:600;padding:1px 6px;border-radius:3px" title="신청이 반려·취소되어 자동 보류된 정산입니다. 신청을 다시 승인했다면 「보류 해제」로 정산대기로 되돌리세요.">자동 보류(신청 반려)</span></div>`
    : '';

  // 선택 칸 — 정산대기이고 PayPal 이 있는 건만 고를 수 있다.
  //   ⚠️ 미등록 건은 잠그되 **왜 잠겼는지**를 말풍선으로 남긴다(빈 칸이면 고장으로 읽힌다).
  const checkCell = (s.status !== 'pending')
    ? ''
    : (s.paypal_email
        ? `<input type="checkbox" class="settlement-check" data-settlement-id="${esc(s.id)}" onchange="settlementOnRowCheck(this)"${_settlementSelected.has(s.id) ? ' checked' : ''}>`
        : '<input type="checkbox" disabled title="PayPal 미등록 — 송금할 수 없어 선택 대상에서 제외됩니다">');

  return `<tr class="${inf.is_audit ? 'audit-row' : ''}">
    <td>${checkCell}</td>
    <td>${infCell}</td>
    <td>${campCell}</td>
    <td><div style="font-weight:700;color:var(--ink);white-space:nowrap">${settlementAmountYen(s.amount_jpy)}</div>${settlementAmountNote(s)}</td>
    <td>${settlementActualAmountCell(s)}</td>
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
    // [341] 실제 송금일·금액만 고친다 — 상태·계산 금액은 안 바뀌고 알림도 없다.
    //   확정된 금전 기록을 사후에 고치는 유일한 경로라 일반 버튼으로 둔다(숨기면 못 찾는다).
    btns.push(`<button class="btn btn-ghost btn-xs" onclick="openSettlementCorrectModal('${id}')">기록 정정</button>`);
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

// ★ [조각 12] 행 「송금완료」도 **송금 묶음 확인 창**으로 보낸다(묶음 1개 = 페이팔 송금 한 번).
//   ⚠️ 옛 단건 창(settlementPayModal · confirmSettlementPay → mark_settlement_paid)은 더 열지 않는다 —
//      묶음이 한 번이라도 기록되면 서버가 그 경로를 payout_bundle_required 로 거부한다(486).
//      아래 옛 함수 본문은 되돌릴 여지로 남겨 둔 것이고 어디서도 부르지 않는다.
function openSettlementPayModal(id) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  if (settlementBulkLocked()) return;
  _bulkPayCtx = {
    settlementIds: [s.id],
    applicationIds: [],
    items: [_bulkItemFromSettlementRow(s)],
    from: 'list',
    single: true,   // 행 하나만 — 성공해도 목록에서 체크해 둔 다른 행은 그대로 둔다
  };
  _openBulkPayModal();
}

function _openSettlementPayModalLegacy(id) {
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
  // [339] 실제 송금일·금액 — 비워 두면 「오늘 · 계산 금액 그대로」로 종전과 같이 동작한다.
  const dateEl = $('settlementPayDate');
  if (dateEl) { dateEl.value = ''; dateEl.max = jstTodayStr(); }
  const amtEl = $('settlementPayAmount');
  if (amtEl) amtEl.value = '';
  onSettlementPayInput();
  openModal('settlementPayModal');
}

// 송금일이 인증 성공일보다 이르면 알린다 — 승인 전에 돈을 보낼 수는 없다.
//   ⚠️ **막지 않고 알리기만 한다.** 이 검사가 기대는 `cert_at` 자체가 틀렸을 수 있고
//      (2026-08-18 백필로 되살린 값이다), 서버가 막아 버리면 **정당한 기록이 영영
//      안 들어가는** 상태가 된다. 반대로 화면 경고는 오타를 **입력하는 순간** —
//      아직 고치기 쉬운 시점에 — 보여준다. 앞날 날짜만 서버가 막는 것은 그쪽은
//      「어떤 경우에도 성립하지 않기」 때문이다.
//   ⚠️ `cert_at` 이 비어 있으면(324 이전 행) 검사하지 않는다 — 기준이 없다.
//   ⚠️ 날짜 문자열끼리 비교한다('YYYY-MM-DD' 는 사전순 = 시간순이라 시간대가 안 끼어든다).
function settlementPaidDateWarning(s, dateStr) {
  if (!s || !dateStr || !s.cert_at) return '';
  const certDay = _settlementDateInputValue(s.cert_at);
  if (!certDay || dateStr >= certDay) return '';
  return `입력한 송금일이 <b>인증 성공일(${esc(certDay)})보다 이릅니다.</b> 승인 전에 송금할 수는 없습니다 — 연도를 잘못 입력하지 않았는지 확인해 주세요.`;
}

// 입력이 바뀔 때마다 — 계산값과 다른 금액이면 그 사실을 **누르기 전에** 보여주고,
// 사유가 비었으면 버튼을 잠근다.
//   ⚠️ 사유를 필수로 둔 이유: 2026-08-18 조사에서 「왜 이 금액인가」를 되짚을 단서가
//      메모뿐이었다. 비워 둘 수 있게 두면 다음 조사도 같은 벽에 부딪힌다.
function onSettlementPayInput() {
  const ctx = _settlementModalCtx;
  const s = ctx ? _settlements.find(x => x.id === ctx.id) : null;
  const memo = ($('settlementPayMemo')?.value || '').trim();
  const rawAmt = ($('settlementPayAmount')?.value || '').trim();
  const amt = rawAmt === '' ? null : Number(rawAmt);
  const diffEl = $('settlementPayAmountDiff');
  const amtBad = amt !== null && (!Number.isFinite(amt) || amt <= 0);
  const dateWarn = settlementPaidDateWarning(s, ($('settlementPayDate')?.value || '').trim());
  if (diffEl) {
    const lines = [];
    if (amtBad) lines.push('송금액은 0보다 큰 숫자여야 합니다.');
    else if (s && amt !== null && amt !== Number(s.amount_jpy)) {
      lines.push(`시스템 계산 <b>${settlementAmountYen(s.amount_jpy)}</b> → 실제 <b>${settlementAmountYen(amt)}</b> 로 기록됩니다.`
        + '<br>시스템 계산 금액 자체는 바뀌지 않습니다(왜 그 금액인지 설명하는 근거라서). 두 값이 목록에 나란히 보입니다.');
    }
    if (dateWarn) lines.push(dateWarn);
    diffEl.style.display = lines.length ? 'block' : 'none';
    diffEl.innerHTML = lines.join('<hr style="border:0;border-top:1px solid #FDBA74;margin:6px 0">');
  }
  const btn = $('settlementPayConfirmBtn');
  if (btn) btn.disabled = !(s && s.paypal_email) || !memo || amtBad;
}

function closeSettlementPayModal() {
  closeModal('settlementPayModal');
  _settlementModalCtx = null;
}

async function confirmSettlementPay() {
  // ★ **세 번째 문.** 3단계 전에는 여기도 잠근다.
  //   ⚠️ 사양서 §8 은 「문이 둘」이라 적었지만 그건 **그때 센 것이 둘뿐**이었기 때문이고,
  //      근거로 든 논리(「3단계 전에 기록하면 오늘 날짜·계산 금액으로 확정되고 되돌릴 수
  //      없다」)가 **이 경로에 그대로 적용된다.** 논리가 같은데 결론이 다를 이유가 없다.
  //   ⚠️ **송금완료만** 잠근다 — 보류·취소·보류 해제는 날짜·금액을 안 다루므로 그대로 둔다.
  //      정산대기 건에 문제가 생겼을 때 **보류로 옮기는 길은 열려 있어야** 한다.
  //   ⚠️ 3단계에서 **세 문을 다 푼다.** 두 개만 풀면 화면이 반쪽으로 남는다.
  if (settlementBulkLocked()) return;
  const ctx = _settlementModalCtx;
  if (!ctx) return;
  const memo = ($('settlementPayMemo')?.value || '').trim();
  if (!memo) { toast('처리 사유를 입력해 주세요', 'warn'); return; }
  const paidAt = _settlementJstMidnight(($('settlementPayDate')?.value || '').trim());
  const rawAmt = ($('settlementPayAmount')?.value || '').trim();
  const paidAmount = rawAmt === '' ? null : Number(rawAmt);
  if (paidAmount !== null && (!Number.isFinite(paidAmount) || paidAmount <= 0)) {
    toast('송금액은 0보다 큰 숫자여야 합니다', 'warn'); return;
  }
  const btn = $('settlementPayConfirmBtn');
  if (btn) btn.disabled = true;
  try {
    const newV = await markSettlementPaid(ctx.id, ctx.version, memo, paidAt, paidAmount);
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
// SECTION: SETTLEMENTS — 송금 기록 정정 (correct_settlement_payment · 마이그레이션 341)
// ════════════════════════════════════════════════════════════════════
//
// 이미 송금완료된 건의 **실제 송금일·송금액만** 고친다.
//   · 상태(송금완료)·시스템 계산 금액(amount_jpy)은 안 바뀐다
//   · 인플루언서 알림 없음 — 이미 「보냈다」고 알린 건의 숫자를 고치는 것이라, 다시 알리면
//     두 번 받은 것처럼 읽힌다
//   · 무엇을 무엇으로 고쳤는지는 「이력」에 문장으로 남는다(서버가 만든다)
// ⚠️ **비운 칸은 안 고친다.** 그래서 여는 시점에 현재 값을 미리 채워 넣지 않는다 —
//    채워 두면 「비우면 안 고침」과 앞뒤가 안 맞는다. 현재 값은 위쪽 안내에 보여준다.

// from — 'list'(정산 목록) | 'payout'(회차별·사람별 상세). 저장 뒤 그 화면을 다시 그린다
function openSettlementCorrectModal(id, from) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  if (s.status !== 'paid') { toast('송금완료 건만 정정할 수 있습니다', 'warn'); return; }
  _settlementModalCtx = { id: s.id, version: s.version, mode: 'correct', from: from || 'list' };

  const inf = s.influencers || {};
  const camp = s.campaigns || {};
  const nowAmount = (s.paid_amount_jpy == null)
    ? `${settlementAmountYen(s.amount_jpy)} <span style="font-size:11px;color:var(--muted)">(계산 금액 그대로)</span>`
    : settlementAmountYen(s.paid_amount_jpy);
  const body = $('settlementCorrectBody');
  if (body) {
    body.innerHTML = `
      <div style="display:grid;grid-template-columns:auto 1fr;gap:8px 14px;font-size:13px;margin-bottom:16px">
        <div style="color:var(--muted)">인플루언서</div>
        <div style="font-weight:600">${esc(inf.name || '—')}</div>
        <div style="color:var(--muted)">캠페인</div>
        <div>${esc(camp.title || '—')}</div>
        <div style="color:var(--muted)">지금 기록된 송금일</div>
        <div style="font-weight:600">${s.paid_at ? formatDate(s.paid_at) : '<span style="color:var(--muted)">기록 없음</span>'}</div>
        <div style="color:var(--muted)">지금 기록된 송금액</div>
        <div style="font-weight:600">${nowAmount}</div>
        <div style="color:var(--muted)">시스템 계산 금액</div>
        <div>${settlementAmountYen(s.amount_jpy)}</div>
      </div>
      ${s.current_transfer_id ? `<div style="padding:8px 10px;background:#EFF6FF;border:1px solid #BFDBFE;border-radius:8px;font-size:12px;line-height:1.6;margin-bottom:12px">
        이 건은 <b>송금 묶음</b>으로 기록됐습니다. <b>송금일은 「송금 내역」에서 묶음 단위로</b> 고칩니다(같이 보낸 건이 함께 바뀝니다).
        여기서는 이 건의 <b>보낸 금액만</b> 고칠 수 있고, 고치면 묶음 합계와 자동 수수료가 함께 다시 계산됩니다.
      </div>` : ''}`;
  }
  // ★ [조각 12] 묶음에 속한 건은 송금일 칸을 잠근다 — 서버도 paid_at_owned_by_transfer 로 거부한다(486)
  const dateEl = $('settlementCorrectDate');
  if (dateEl) {
    dateEl.value = ''; dateEl.max = jstTodayStr();
    dateEl.disabled = !!s.current_transfer_id;
    dateEl.title = s.current_transfer_id ? '송금일은 「송금 내역」에서 묶음 단위로 고칩니다' : '';
  }
  const amtEl = $('settlementCorrectAmount');
  if (amtEl) amtEl.value = '';
  const memoEl = $('settlementCorrectMemo');
  if (memoEl) memoEl.value = '';
  onSettlementCorrectInput();
  openModal('settlementCorrectModal');
}

// 고칠 항목이 하나도 없거나 사유가 비면 잠근다 — 서버도 같은 두 가지를 거부한다.
function onSettlementCorrectInput() {
  const ctx = _settlementModalCtx;
  const s = ctx ? _settlements.find(x => x.id === ctx.id) : null;
  const date = ($('settlementCorrectDate')?.value || '').trim();
  const rawAmt = ($('settlementCorrectAmount')?.value || '').trim();
  const memo = ($('settlementCorrectMemo')?.value || '').trim();
  const amt = rawAmt === '' ? null : Number(rawAmt);
  const amtBad = amt !== null && (!Number.isFinite(amt) || amt <= 0);
  const warnEl = $('settlementCorrectWarn');
  if (warnEl) {
    const lines = [];
    if (amtBad) lines.push('송금액은 0보다 큰 숫자여야 합니다.');
    const dw = settlementPaidDateWarning(s, date);
    if (dw) lines.push(dw);
    warnEl.style.display = lines.length ? 'block' : 'none';
    warnEl.innerHTML = lines.join('<hr style="border:0;border-top:1px solid #FDBA74;margin:6px 0">');
  }
  const btn = $('settlementCorrectConfirmBtn');
  if (btn) btn.disabled = (!date && amt === null) || !memo || amtBad;
}

function closeSettlementCorrectModal() {
  closeModal('settlementCorrectModal');
  _settlementModalCtx = null;
}

async function confirmSettlementCorrect() {
  // ⚠️ 새로 만든 경로도 **같은 잠금**에 건다. 안 걸면 다른 문이 잠긴 동안 이 문으로
  //    금전 기록을 남길 수 있어 잠금 자체가 무의미해진다. 작업 7에서 한꺼번에 열린다.
  if (settlementBulkLocked()) return;
  const ctx = _settlementModalCtx;
  if (!ctx) return;
  const paidAt = _settlementJstMidnight(($('settlementCorrectDate')?.value || '').trim());
  const rawAmt = ($('settlementCorrectAmount')?.value || '').trim();
  const paidAmount = rawAmt === '' ? null : Number(rawAmt);
  const memo = ($('settlementCorrectMemo')?.value || '').trim();
  if (!paidAt && paidAmount === null) { toast('고칠 항목을 하나 이상 입력해 주세요', 'warn'); return; }
  if (!memo) { toast('정정 사유를 입력해 주세요', 'warn'); return; }
  if (paidAmount !== null && (!Number.isFinite(paidAmount) || paidAmount <= 0)) {
    toast('송금액은 0보다 큰 숫자여야 합니다', 'warn'); return;
  }
  const btn = $('settlementCorrectConfirmBtn');
  if (btn) btn.disabled = true;
  try {
    const newV = await correctSettlementPayment(ctx.id, ctx.version, paidAt, paidAmount, memo);
    if (newV === -1) toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    else toast('송금 기록을 정정했습니다.');
  } catch (e) {
    toast('정정 실패: ' + friendlyError(e.message || e), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  closeModal('settlementCorrectModal');
  _settlementModalCtx = null;
  // ⚠️ refreshPane 만으로는 회차 상세(_payoutRows)가 안 바뀐다 — 보던 화면을 다시 그린다
  await _settlementRefreshKeepingView(ctx.from || 'list');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 선택 건 일괄 송금완료 (mark_settlements_paid_bulk · 340)
// ════════════════════════════════════════════════════════════════════
//
// ⚠️ 금액 칸이 없다 — 일괄이라 건마다 다른 금액을 하나로 못 넣는다. 전부 시스템 계산
//    금액으로 기록되고, 다르게 보낸 건은 기록 후 그 행의 「기록 정정」으로 고친다.
// ⚠️ 서버는 **통째로 실패시키지 않고 건너뛴다.** 처리 후 몇 건이 왜 빠졌는지 반드시
//    보여줘야 한다 — 「N건 처리」만 띄우면 나머지가 어디로 갔는지 아무도 모른다.

// 일괄 송금완료의 **진입점이 둘**이다 — 목록의 선택, 그리고 지급 준비 화면의 「보냄」.
//   두 벌로 만들면 한쪽만 고치게 되므로 **처리는 한 함수**로 모으고, 진입점은 여기에
//   무엇을 처리할지만 담는다.
//   ⚠️ 두 종류가 섞인다: 정산 행이 있는 건(`settlementIds`)과 아직 없는 건(`applicationIds`).
//      서버 함수가 다르므로 아래 confirm 이 **둘 다** 부른다.
let _bulkPayCtx = null;   // {settlementIds:[], applicationIds:[], items:[], from:'list'|'payout'|'unreg', mode?, summaryHtml}

// ════════════════════════════════════════════════════════════════════
// 송금 묶음 확인 창 (조각 11 — 사양서 2026-09-30-settlement-transfer-fee-record.md D-1~D-3)
//
// ▶ 페이팔 송금 1건 = 묶음 1개. 기본은 **사람마다 묶음 1개**, 「따로 보내기」로 나누고 「합치기」로 되돌린다.
// ▶ 저장은 `recordSettlementTransfers` **한 번**. 서버가 전부 검사해 하나라도 걸리면 아무것도 안 쓰고
//   사유 목록을 돌려준다 → 창을 닫지 않고 사유를 보여 준다(사용자 결정 2026-09-30).
// ⚠️ 진입점이 다섯이다(목록 선택 · 과거 미등록 · 지급 준비 건별 · 사람·회차 묶음 · 선택한 건).
//    넘기는 행 모양이 달라 아래 `_bulkItemFrom*` 로 **공통 항목**으로 바꾼 뒤 이 창 하나로 처리한다.
// ⚠️ 수수료는 **서버에 묻는다**(`previewSettlementFees`, 마이그레이션 488). 화면에 계산식 사본을 두지 않는다.
// ⚠️ 「정산대기 추가」(mode='pending')는 **이 창을 쓰지 않는다** — 옛 창·옛 동작 그대로.
// ════════════════════════════════════════════════════════════════════

// 공통 항목: {kind:'settlement'|'unregistered', settlementId, applicationId, influencerId,
//            name, paypalText, paypalOk:true|false|null(확인 실패), amount, due, campaignLabel, blockReason}
function _bulkCampaignLabel(no, title) {
  return (no ? '[' + no + '] ' : '') + (title || '(캠페인 미상)');
}
// 정산 목록 행(_settlements) — 정산대기가 아니면 보낼 수 없다(서버도 거부한다)
function _bulkItemFromSettlementRow(r) {
  const inf = r.influencers || {};
  const paypal = inf.paypal_email || r.paypal_email || null;
  const c = r.campaigns || {};
  return {
    kind: 'settlement', settlementId: r.id, applicationId: r.application_id, influencerId: r.influencer_id,
    name: inf.name || null,
    paypalText: paypal,
    paypalOk: paypal ? true : (inf.has_paypal === true ? true : false),
    amount: settlementEffectiveAmount(r),
    due: payoutDueDate(r.cert_at),
    campaignLabel: _bulkCampaignLabel(c.campaign_no, c.title),
    blockReason: r.status !== 'pending' ? '정산대기 상태가 아님' : null,
  };
}
// 과거 미등록 행(_pastUnregById) — 페이팔 주소는 없고 등록 여부만 온다
function _bulkItemFromUnregRow(r) {
  return {
    kind: 'unregistered', settlementId: null, applicationId: r.application_id, influencerId: r.influencer_id,
    name: r.influencer_name || null,
    paypalText: r.has_paypal ? '페이팔 등록됨' : null,
    paypalOk: !!r.has_paypal,
    amount: Number(r.amount_jpy) || 0,
    due: payoutDueDate(r.cert_at),
    campaignLabel: _bulkCampaignLabel(r.campaign_no, r.campaign_title),
    blockReason: null,
  };
}
// 지급 준비 행(_payoutRows) — ⚠️ 금액은 행의 amount 그대로(settlementEffectiveAmount 를 다시 부르면 0원)
function _bulkItemFromPayoutRow(r) {
  const p = payoutPersonOf(r);
  return {
    kind: r.kind === 'settlement' ? 'settlement' : 'unregistered',
    settlementId: r.kind === 'settlement' ? r.settlementId : null,
    applicationId: r.applicationId, influencerId: r.influencerId,
    name: p.name,
    paypalText: p.paypal,
    paypalOk: p.paypal ? true : (p.paypalUnknown ? null : false),
    amount: Number(r.amount) || 0,
    due: r.due || null,
    campaignLabel: _bulkCampaignLabel(r.campaignNo, r.campaignTitle),
    blockReason: null,
  };
}

// 보낼 수 없는 건(정산대기 아님·페이팔 미등록)은 묶음에서 빼고 따로 보여 준다
function _bulkBuildBundles(items) {
  const bundles = [];
  const blocked = [];
  const today = jstTodayStr();
  const byPerson = {};
  items.forEach(function (it, idx) {
    if (it.blockReason) { blocked.push({ idx: idx, reason: it.blockReason }); return; }
    if (it.paypalOk === false) { blocked.push({ idx: idx, reason: '페이팔 미등록' }); return; }
    const key = it.influencerId || '(미상)';
    if (byPerson[key] === undefined) {
      byPerson[key] = bundles.length;
      bundles.push({ influencerId: it.influencerId, itemIdx: [], sentDate: today, txn: '', ruleOn: false, rate: '', fixed: '' });
    }
    bundles[byPerson[key]].itemIdx.push(idx);
  });
  return { bundles: bundles, blocked: blocked };
}

function _bulkItemAmount(idx) {
  const v = _bulkPayCtx.amounts[idx];
  return (v === undefined || v === null || v === '') ? _bulkPayCtx.items[idx].amount : Number(v);
}
function _bulkBundleTotal(b) {
  return b.itemIdx.reduce(function (a, idx) { const n = _bulkItemAmount(idx); return a + (Number.isFinite(n) ? n : 0); }, 0);
}
// 「이 송금 요율 직접 정하기」(사양서 2026-10-02-settlement-per-transfer-fee-rule 설계 ⓪ — 동작은 그 절이 정본)
//   켜져 있고 요율·고정액이 둘 다 숫자일 때만 서버에 보낸다. 덜 채웠으면 수수료는 「계산 중」으로 둔다(설정 규칙 값을 보이지 않는다)
function _bulkRuleReady(b) {
  if (!b || !b.ruleOn || b.rate === '' || b.fixed === '') return false;
  // 고정액은 정수만 — 서버 미리보기 배열이 integer[] 라 소수 하나가 전체 미리보기를 실패시킨다
  return Number.isFinite(Number(b.rate)) && Number.isInteger(Number(b.fixed));
}
function _bulkBundleFee(bi) {
  const b = _bulkPayCtx.bundles[bi];
  if (b.ruleOn && !_bulkRuleReady(b)) return null;
  const f = _bulkPayCtx.feePreview;
  return (f && Array.isArray(f.fees) && f.fees[bi] !== undefined) ? f.fees[bi] : null;   // null = 아직/계산 못 함
}

function _renderBulkBundles() {
  const ctx = _bulkPayCtx;
  const body = $('settlementBulkPayBody');
  if (!ctx || !body) return;
  const items = ctx.items;
  const personBundleCount = {};
  ctx.bundles.forEach(function (b) { personBundleCount[b.influencerId] = (personBundleCount[b.influencerId] || 0) + 1; });
  const firstOfPerson = {};

  const cards = ctx.bundles.map(function (b, bi) {
    const head = items[b.itemIdx[0]];
    const isFirst = firstOfPerson[b.influencerId] === undefined;
    if (isFirst) firstOfPerson[b.influencerId] = bi;
    // ★ 표 형식(2026-10-01 사용자 결정) — 묶음 정보는 「항목 | 값」 표, 건은 「캠페인 | 지급 예정일 | 보낸 금액」 표,
    //   합계 셋(보낸 금액·수수료·총지출)은 건 표의 아래 줄. ⚠️ bulkTotal_·bulkFee_·bulkSpend_ id 는 금액 입력 때
    //   그 자리만 고쳐 쓰는 데 쓴다 — 지우거나 이름을 바꾸면 합계가 안 따라온다.
    const TH = 'padding:6px 10px;font-size:11px;font-weight:600;color:var(--muted);background:#F1F1F3;text-align:left;white-space:nowrap';
    const TD = 'padding:6px 10px;font-size:12px;border-top:1px solid var(--line);vertical-align:middle';
    // 입력칸은 관리자 공통 「admin-input」(13px). ⚠️ 이 확인 창은 #page-admin **밖**이라 form-input 을 쓰면
    //   회원 앱 크기(16px)가 된다. 높이도 기본 admin-input 그대로 — 아래 「처리 사유」 칸과 같게(2026-10-08 사용자 요청).
    const INP = 'box-sizing:border-box';
    const canSplit = b.itemIdx.length > 1;
    const rows = b.itemIdx.map(function (idx) {
      const it = items[idx];
      const val = ctx.amounts[idx] !== undefined ? ctx.amounts[idx] : it.amount;
      return `<tr>
          <td style="${TD};max-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(it.campaignLabel)}">${esc(it.campaignLabel)}</td>
          <td style="${TD};white-space:nowrap;color:var(--muted)">${esc(it.due || '지급일 없음')}</td>
          <td style="${TD};text-align:right"><input type="number" class="admin-input" min="1" step="1" value="${esc(String(val))}" oninput="onBulkItemAmountInput(${idx}, this.value)"
                 style="width:110px;text-align:right;${INP}" aria-label="보낸 금액"></td>
          ${canSplit ? `<td style="${TD};white-space:nowrap"><button class="btn btn-ghost btn-xs" style="padding:2px 8px" onclick="splitBulkItem(${bi}, ${idx})" title="이 건만 따로 송금한 경우">따로 보내기</button></td>` : ''}
        </tr>`;
    }).join('');
    const fee = _bulkBundleFee(bi);
    const total = _bulkBundleTotal(b);
    // 수수료 값 칸 — 금액만(2026-10-08 사용자 결정: 확인 창에서 수수료 금액은 직접 고치지 않는다 — 요율·고정액만.
    //   금액이 다르면 기록 뒤 「송금 내역」→「정정」). ⚠️ id bulkFee_ 는 금액·요율 입력 때 숫자만 고쳐 쓰는 자리다
    const feeHtml = `<span id="bulkFee_${bi}">${fee === null ? `<span style="color:var(--muted)">${_bulkFeePendingText()}</span>` : esc(settlementAmountYen(fee))}</span>`;
    const span = canSplit ? 2 : 1;   // 합계 줄의 값 칸이 「보낸 금액」 열(+ 따로 보내기 열)을 덮는다
    // 합계 줄(보낸 금액 합계·총지출). ⚠️ 수수료 줄은 따로 그리지만 칸 나눔은 같다(제목·값 열을 맞춘다) — 왼쪽 칸에 「직접 지정」·요율이 더 들어간다
    const sumRow = function (label, valueHtml) {
      return `<tr><td colspan="2" style="${TD};text-align:right;color:var(--muted);background:#FAFAFA">${label}</td>
        <td colspan="${span}" style="${TD};text-align:right;background:#FAFAFA;white-space:nowrap">${valueHtml}</td></tr>`;
    };
    return `<div style="border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-bottom:10px">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:8px">
          <b style="font-size:13px">${esc(head.name || '(이름 미상)')}</b>
          ${personBundleCount[b.influencerId] > 1 ? `<span style="font-size:11px;color:#2563EB">같은 사람 묶음 ${personBundleCount[b.influencerId]}개 — 수수료가 묶음마다 붙습니다</span>` : ''}
          ${!isFirst ? `<button class="btn btn-ghost btn-xs" style="padding:2px 8px;margin-left:auto" onclick="mergeBulkBundle(${bi})" title="같은 사람의 첫 묶음과 합칩니다">합치기</button>` : ''}
        </div>
        <table style="width:100%;border-collapse:collapse;border:1px solid var(--line);margin-bottom:8px">
          <tr><th style="${TH};width:140px">페이팔</th>
            <td style="${TD};border-top:none">${head.paypalOk === null
              ? '<span style="font-size:11px;color:#B8741A">페이팔 확인 실패 — 서버가 다시 확인합니다</span>'
              : `<span style="font-size:11px;font-family:monospace">${esc(head.paypalText || '')}</span>`}</td></tr>
          <tr><th style="${TH};border-top:1px solid var(--line)">송금일</th>
            <td style="${TD}"><input type="date" class="admin-input" value="${esc(b.sentDate)}" max="${esc(jstTodayStr())}" onchange="onBulkBundleField(${bi}, 'sentDate', this.value)"
                   style="${INP}" aria-label="송금일"></td></tr>
          <tr><th style="${TH};border-top:1px solid var(--line)">페이팔 거래번호(선택)</th>
            <td style="${TD}"><input type="text" class="admin-input" value="${esc(b.txn)}" maxlength="100" oninput="onBulkBundleField(${bi}, 'txn', this.value)"
                   style="${INP};width:220px" aria-label="페이팔 거래번호"></td></tr>
        </table>
        <table style="width:100%;border-collapse:collapse;border:1px solid var(--line);table-layout:fixed">
          <thead><tr>
            <th style="${TH}">캠페인</th>
            <th style="${TH};width:110px">지급 예정(회차)</th>
            <th style="${TH};width:120px;text-align:right">보낸 금액</th>
            ${canSplit ? `<th style="${TH};width:96px"></th>` : ''}
          </tr></thead>
          <tbody>${rows}
          ${sumRow('보낸 금액 합계', `<b id="bulkTotal_${bi}">${esc(settlementAmountYen(total))}</b>`)}
          <tr><td colspan="2" style="${TD};background:#FAFAFA">${_bulkRuleCellHtml(b, bi, INP)}</td>
            <td colspan="${span}" style="${TD};text-align:right;background:#FAFAFA;white-space:nowrap${b.ruleOn ? ';vertical-align:top' : ''}">${b.ruleOn
              // 켜면 왼쪽 칸이 두 줄(입력 줄 + 안내)이 된다 — 금액을 「수수료」 제목이 있는 첫 줄(입력칸 높이)에 맞춘다
              ? `<div style="height:37px;display:flex;align-items:center;justify-content:flex-end">${feeHtml}</div>` : feeHtml}</td></tr>
          ${sumRow('총지출', `<b id="bulkSpend_${bi}">${fee === null ? '—' : esc(settlementAmountYen(total + fee))}</b>`)}
          </tbody>
        </table>
      </div>`;
  }).join('');

  const blockedHtml = ctx.blocked.length ? `<div style="padding:10px 12px;background:#FEF2F2;border:1px solid #FCA5A5;border-radius:10px;margin-bottom:10px;font-size:12px;line-height:1.7">
      <b style="color:#B91C1C">보낼 수 없어 뺀 건 ${ctx.blocked.length}건</b>
      ${ctx.blocked.map(function (x) { const it = items[x.idx];
        return `<div>${esc(it.name || '(이름 미상)')} · ${esc(it.campaignLabel)} — ${esc(x.reason)}</div>`; }).join('')}
    </div>` : '';

  body.innerHTML = `
    ${blockedHtml}
    <div id="settlementBulkPayErrors"></div>
    <div style="margin-bottom:14px">${cards || '<div style="padding:16px;color:var(--muted);font-size:13px">보낼 수 있는 건이 없습니다.</div>'}</div>`;
  // 묶음 전체 합계 줄은 두지 않는다(2026-10-01 사용자 결정) — 묶음마다 표 아래에 합계가 있다.
}

// 수수료 줄 왼쪽 칸 — 「직접 지정」 체크 칸 + (켜면) 요율·고정액 + 오른쪽 끝 「수수료」 제목(2026-10-08 사용자 요청 배치)
//   동작은 사양서 2026-10-02-settlement-per-transfer-fee-rule 설계 ⓪ — 단 확인 창의 수수료 금액 직접 입력은 없앴다(2026-10-08 사용자 결정)
function _bulkRuleCellHtml(b, bi, INP) {
  const inputs = b.ruleOn ? `
      <span>요율</span><input type="number" id="bulkRate_${bi}" class="admin-input" min="0" max="100" step="0.01" value="${esc(String(b.rate))}"
             oninput="onBulkRuleInput(${bi}, 'rate', this.value)" style="width:76px;text-align:right;${INP}" aria-label="이 송금 요율(%)"><span>%</span>
      <span>고정액</span><input type="number" id="bulkFixed_${bi}" class="admin-input" min="0" step="1" value="${esc(String(b.fixed))}"
             oninput="onBulkRuleInput(${bi}, 'fixed', this.value)" style="width:76px;text-align:right;${INP}" aria-label="이 송금 고정액(엔)"><span>엔</span>` : '';
  return `<div style="display:flex;align-items:center;justify-content:space-between;gap:8px">
      <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;font-size:12px">
        <label style="display:inline-flex;align-items:center;gap:4px;white-space:nowrap;cursor:pointer" title="이 송금만 요율·고정액을 직접 정합니다">
          <input type="checkbox" id="bulkRuleChk_${bi}" ${b.ruleOn ? 'checked' : ''}
                 onchange="onBulkRuleToggle(${bi}, this.checked)"> 직접 지정
        </label>${inputs}
      </div>
      <span style="color:var(--muted);white-space:nowrap">수수료</span>
    </div>
    ${b.ruleOn ? `<div style="font-size:11px;color:var(--muted);margin-top:4px">이 송금에만 적용됩니다. 앞으로의 모든 송금은 <a href="javascript:void(0)" onclick="openFeeRuleFromChild(_scheduleBulkFeePreview)" style="color:#2563EB">수수료 설정</a>에서 바꿉니다.</div>
    <div id="bulkRateWarn_${bi}" style="font-size:11px;color:#B8741A;margin-top:2px;${_ruleRateWarn(b.ruleOn, b.rate) ? '' : 'display:none'}">요율이 10%를 넘습니다. 맞는지 확인해 주세요</div>` : ''}`;
}
// 요율 10% 초과 경고 — 막지 않는다(사양서 경우의 수 8). 확인 창·정정 창이 같이 쓴다
function _ruleRateWarn(on, rate) { return !!on && rate !== '' && Number(rate) > 10; }

// 수수료 미리보기가 아직이면 「계산 중…」, 실패했으면 「계산 못 함」(세 자리가 같은 말을 한다)
function _bulkFeePendingText() {
  const f = _bulkPayCtx && _bulkPayCtx.feePreview;
  return (f && f.failed) ? '계산 못 함' : '계산 중…';
}

// 금액·묶음이 바뀌면 서버에 수수료를 다시 묻는다(300ms 모아서). ⚠️ 늦게 온 옛 응답은 버린다
let _bulkFeeTimer = null;
let _bulkFeeSeq = 0;
function _scheduleBulkFeePreview() {
  if (_bulkFeeTimer) clearTimeout(_bulkFeeTimer);
  // ⚠️ 예약하는 **순간** 번호를 올린다 — 날아가 있던 옛 요청의 응답(나누기·합치기 전 순서)을 무효로 한다
  const seq = ++_bulkFeeSeq;
  _bulkFeeTimer = setTimeout(async function () {
    const ctx = _bulkPayCtx;
    if (!ctx || !ctx.bundles || seq !== _bulkFeeSeq) return;
    const totals = ctx.bundles.map(_bulkBundleTotal);
    const anyRule = ctx.bundles.some(_bulkRuleReady);
    const res = await previewSettlementFees(totals, anyRule ? {
      rates:  ctx.bundles.map(function (b) { return _bulkRuleReady(b) ? b.rate : null; }),
      fixeds: ctx.bundles.map(function (b) { return _bulkRuleReady(b) ? b.fixed : null; }),
    } : undefined);
    if (ctx !== _bulkPayCtx || seq !== _bulkFeeSeq) return;
    const wasFailed = !!(ctx.feePreview && ctx.feePreview.failed);
    ctx.feePreview = res || { fees: totals.map(function () { return null; }), failed: true };
    ctx.bundles.forEach(function (b, bi) { _refreshBulkBundleNumbers(bi); });
    // 실패 안내는 **처음 한 번만**(입력할 때마다 반복하지 않는다)
    if (!res && !wasFailed) toast('수수료를 계산하지 못했습니다 — 저장하면 서버가 계산합니다', 'warn');
  }, 300);
}

function _refreshBulkBundleNumbers(bi) {
  const b = _bulkPayCtx.bundles[bi];
  const total = _bulkBundleTotal(b);
  const fee = _bulkBundleFee(bi);
  const t = $('bulkTotal_' + bi); if (t) t.textContent = settlementAmountYen(total);
  const f = $('bulkFee_' + bi);
  if (f) f.innerHTML = fee === null ? `<span style="color:var(--muted)">${_bulkFeePendingText()}</span>` : esc(settlementAmountYen(fee));
  const s = $('bulkSpend_' + bi); if (s) s.textContent = fee === null ? '—' : settlementAmountYen(total + fee);
}

function onBulkItemAmountInput(idx, v) {
  if (!_bulkPayCtx) return;
  _bulkPayCtx.amounts[idx] = v;
  const bi = _bulkPayCtx.bundles.findIndex(function (b) { return b.itemIdx.indexOf(idx) >= 0; });
  if (bi >= 0) _refreshBulkBundleNumbers(bi);
  _scheduleBulkFeePreview();
}
function onBulkBundleField(bi, field, v) {
  if (!_bulkPayCtx || !_bulkPayCtx.bundles[bi]) return;
  _bulkPayCtx.bundles[bi][field] = v;
}
// 체크 칸 — 켜면 처음 값 = 설정 규칙(R4). 끄면 요율 칸을 비우고 설정 규칙(자동 계산값)으로(R3)
function onBulkRuleToggle(bi, on) {
  const ctx = _bulkPayCtx;
  const b = ctx && ctx.bundles[bi];
  if (!b) return;
  b.ruleOn = !!on;
  const f = ctx.feePreview;
  // ⚠️ 미리보기를 못 받았으면 처음 값을 비워 둔다 — 0 으로 채우면(Number('') 함정) 수수료 0 이 기록된다
  const ruleKnown = f && !f.failed && f.rate_percent !== undefined && f.rate_percent !== null;
  b.rate  = on && ruleKnown ? String(f.rate_percent) : '';
  b.fixed = on && ruleKnown ? String(f.fixed_jpy) : '';
  _renderBulkBundles();
  _scheduleBulkFeePreview();
}
function onBulkRuleInput(bi, field, v) {
  const b = _bulkPayCtx && _bulkPayCtx.bundles[bi];
  if (!b || !b.ruleOn) return;
  b[field] = v;
  const w = $('bulkRateWarn_' + bi); if (w) w.style.display = _ruleRateWarn(b.ruleOn, b.rate) ? '' : 'none';
  _refreshBulkBundleNumbers(bi);
  _scheduleBulkFeePreview();
}
// 「따로 보내기」 — 그 건을 같은 사람의 새 묶음으로 뺀다(수수료가 한 번 더 붙는다)
function splitBulkItem(bi, idx) {
  const ctx = _bulkPayCtx;
  const b = ctx.bundles[bi];
  if (!b || b.itemIdx.length < 2) return;
  b.itemIdx = b.itemIdx.filter(function (x) { return x !== idx; });
  ctx.bundles.splice(bi + 1, 0, { influencerId: b.influencerId, itemIdx: [idx], sentDate: b.sentDate, txn: '', ruleOn: false, rate: '', fixed: '' });
  // ⚠️ 묶음 순서가 바뀌면 미리보기 배열 자리도 밀린다 — 다시 받을 때까지 「계산 중」으로 둔다
  ctx.feePreview = null;
  _renderBulkBundles();
  _scheduleBulkFeePreview();
}
// 「합치기」 — 같은 사람의 첫 묶음으로 옮긴다
function mergeBulkBundle(bi) {
  const ctx = _bulkPayCtx;
  const b = ctx.bundles[bi];
  if (!b) return;
  const target = ctx.bundles.findIndex(function (x) { return x.influencerId === b.influencerId; });
  if (target < 0 || target === bi) return;
  ctx.bundles[target].itemIdx = ctx.bundles[target].itemIdx.concat(b.itemIdx);
  ctx.bundles.splice(bi, 1);
  if (b.ruleOn) toast('합친 묶음에 정했던 요율은 버리고, 남는 묶음의 설정을 씁니다', 'warn');
  ctx.feePreview = null;
  _renderBulkBundles();
  _scheduleBulkFeePreview();
}

// 서버 사유 → 한국어 (조각 10 의 전역 문구와 같은 말)
const BULK_FAILURE_TEXT = {
  bundle_paypal_missing:   '페이팔 미등록',
  bundle_not_pending:      '이미 처리됐거나 정산대기가 아님',
  bundle_not_found:        '정산 건이 없어짐',
  bundle_not_candidate:    '정산 대상이 아님(인증 성공 전·조건 변경 등)',
  bundle_amount_issue:     '금액을 정할 수 없음',
  bundle_empty:            '빈 묶음',
  bundle_duplicate_item:   '같은 건이 두 번 들어감',
  bundle_amount_invalid:   '금액·수수료 값이 올바르지 않음',
  sent_at_in_future:       '송금일이 미래',
  bundle_mixed_influencer: '한 묶음에 여러 사람',
  bundle_txn_id_invalid:   '거래번호가 너무 김(100자 이하)',
  bundle_fee_rule_incomplete: '요율과 고정액을 함께 넣어야 함',
  bundle_fee_rule_invalid:    '이 송금 요율 값이 올바르지 않음(요율 0~100%, 고정액 0엔 이상 정수)',
  bundle_fee_conflict:        '수수료 금액과 요율을 함께 보냄',
};
function _renderBulkFailures(failures) {
  const box = $('settlementBulkPayErrors');
  if (!box) return;
  const ctx = _bulkPayCtx;
  const lines = (failures || []).map(function (f) {
    const b = ctx.bundles[f.bundle_index];
    const who = b ? (ctx.items[b.itemIdx[0]].name || '(이름 미상)') : '(묶음 ' + (Number(f.bundle_index) + 1) + ')';
    let what = '';
    const id = f.settlement_id || f.application_id;
    if (id) {
      const it = ctx.items.find(function (x) { return x.settlementId === id || x.applicationId === id; });
      if (it) what = ' · ' + it.campaignLabel;
    }
    return `<div>${esc(who)}${esc(what)} — ${esc(BULK_FAILURE_TEXT[f.reason] || f.reason)}</div>`;
  }).join('');
  box.innerHTML = `<div style="padding:10px 12px;background:#FEF2F2;border:1px solid #FCA5A5;border-radius:10px;margin-bottom:10px;font-size:12px;line-height:1.7">
      <b style="color:#B91C1C">아무것도 기록하지 않았습니다 — 아래를 고친 뒤 다시 누르세요</b>
      ${lines}
      <div style="margin-top:6px"><button class="btn btn-ghost btn-xs" onclick="closeBulkPayAndRefresh()">닫고 목록 새로 받기</button></div>
    </div>`;
  box.scrollIntoView({ block: 'nearest' });
}
async function closeBulkPayAndRefresh() {
  const from = _bulkPayCtx && _bulkPayCtx.from;
  closeSettlementBulkPayModal();
  await _settlementRefreshKeepingView(from);
}

// 저장 — 묶음 전부를 한 번에(서버가 전부 검사 → 하나라도 걸리면 아무것도 안 씀)
async function _confirmBulkTransfers(ctx, memo, btn) {
  const bad = [];
  const bundles = ctx.bundles.map(function (b, bi) {
    const settlementIds = [], applicationIds = [], itemAmounts = {};
    b.itemIdx.forEach(function (idx) {
      const it = ctx.items[idx];
      const n = _bulkItemAmount(idx);
      if (!Number.isInteger(n) || n <= 0) bad.push((it.name || '(이름 미상)') + ' · ' + it.campaignLabel);
      const key = it.kind === 'settlement' ? it.settlementId : it.applicationId;
      if (it.kind === 'settlement') settlementIds.push(key); else applicationIds.push(key);
      itemAmounts[key] = n;
    });
    const payload = {
      settlement_ids: settlementIds, application_ids: applicationIds, item_amounts: itemAmounts,
      sent_at: _settlementJstMidnight(b.sentDate || jstTodayStr()),
      paypal_txn_id: (b.txn || '').trim() || null,
      memo: memo, source: 'app',
    };
    if (b.ruleOn) {
      // R1 — 켜진 채 기록하면 값이 설정과 같아도 보낸다. 금액은 보내지 않는다(R2)
      const r = Number(b.rate), x = Number(b.fixed);
      if (!_bulkRuleReady(b) || r < 0 || r > 100 || !Number.isInteger(x) || x < 0) {
        bad.push((ctx.items[b.itemIdx[0]].name || '(이름 미상)') + ' 묶음 요율(0~100%)·고정액(0엔 이상 정수)');
      }
      payload.fee_rate_percent = r;
      payload.fee_fixed_jpy = x;
    }
    return payload;
  });
  if (bad.length) { toast('값을 확인해 주세요(금액은 1엔 이상 정수) — ' + bad.slice(0, 3).join(' / '), 'warn'); return false; }
  if (!bundles.length) { toast('보낼 수 있는 건이 없습니다', 'warn'); return false; }

  let r;
  try { r = await recordSettlementTransfers(bundles); }
  catch (e) { toast('기록 실패 — ' + friendlyError(e.message || e), 'error'); return false; }
  if (!r.ok) { _renderBulkFailures(r.failures); return false; }
  toast(`${r.settlementCount}건을 송금 ${r.transferIds.length}번으로 기록했습니다 · 수수료 ${settlementAmountYen(r.feeTotal)}`
    + (ctx.blocked.length ? ` (보낼 수 없는 ${ctx.blocked.length}건은 뺐습니다)` : ''), ctx.blocked.length ? 'warn' : 'success');
  return true;
}

function _openBulkPayModal() {
  const body = $('settlementBulkPayBody');
  // ★ 송금완료 모드는 새 묶음 창(조각 11). 「정산대기 추가」 모드는 옛 요약 그대로
  const pendingMode = !!(_bulkPayCtx && _bulkPayCtx.mode === 'pending');
  const modalBox = document.querySelector('#settlementBulkPayModal .modal');
  if (modalBox) modalBox.style.maxWidth = pendingMode ? '520px' : '820px';
  if (!pendingMode && _bulkPayCtx) {
    const built = _bulkBuildBundles(_bulkPayCtx.items || []);
    _bulkPayCtx.bundles = built.bundles;
    _bulkPayCtx.blocked = built.blocked;
    _bulkPayCtx.amounts = {};
    _bulkPayCtx.feePreview = null;
    _renderBulkBundles();
    _scheduleBulkFeePreview();
  } else if (body) body.innerHTML = (_bulkPayCtx && _bulkPayCtx.summaryHtml) || '';
  const dateEl = $('settlementBulkPayDate');
  if (dateEl) { dateEl.value = ''; dateEl.max = jstTodayStr(); }
  const memoEl = $('settlementBulkPayMemo');
  if (memoEl) memoEl.value = '';
  // ★ 「정산대기 추가」 모드 — 아직 보내지 않은 건이라 **송금일이 없다.**
  //   ⚠️ 송금일 칸을 남겨 두면 「지금 보낸 것」으로 오해해 날짜를 넣게 되고, 그 값은
  //      정산대기 등록에 쓰이지 않아 **입력한 것이 조용히 버려진다.**
  const pending = pendingMode;
  // 송금완료 모드는 송금일을 **묶음마다** 받는다(창 안 묶음 카드) — 공용 날짜 칸은 두 모드 모두 감춘다
  const dateGroup = $('settlementBulkPayDateGroup');
  if (dateGroup) dateGroup.style.display = 'none';
  const titleEl = $('settlementBulkPayTitle');
  if (titleEl) titleEl.textContent = pending ? '선택 건 정산대기 추가' : '선택 건 송금완료 기록';
  const btn = $('settlementBulkPayConfirmBtn');
  if (btn) btn.textContent = pending ? '정산대기 추가' : '송금완료 기록';
  const warn = $('settlementBulkPayWarn');
  if (warn) warn.innerHTML = pending
    ? '<b>아직 지급하지 않은 건만</b> 처리하세요. 정산대기로 올려 두면 나중에 「송금완료 기록」으로 마무리합니다.'
      + '<br>⚠️ 인플루언서에게는 알림이 가지 않습니다.'
    : '<b>묶음 하나 = 페이팔 송금 한 번</b>입니다. 한 사람에게 여러 건을 실제로 따로 보냈으면 「따로 보내기」로 나누세요(건이 둘 이상인 묶음에만 보입니다. 수수료는 묶음마다 붙습니다).'
      + '<br>금액은 <b>실제로 보낸 금액</b>으로, 수수료 요율이 다르면 「직접 지정」으로 정하세요(금액이 다르면 기록 뒤 「송금 내역」의 「정정」에서 고칩니다).'
      + '<br>⚠️ 하나라도 기록할 수 없으면 <b>아무것도 기록하지 않고</b> 이유를 보여 드립니다. 페이팔 미등록·정산대기가 아닌 건은 묶음에 넣지 않고 맨 위 빨간 상자에 따로 보여 드립니다.';
  onSettlementBulkPayInput();
  openModal('settlementBulkPayModal');
}

function openSettlementBulkPayModal() {
  const ids = Array.from(_settlementSelected);
  if (!ids.length) { toast('먼저 처리할 건을 선택해 주세요', 'warn'); return; }
  const rows = ids.map(id => _settlements.find(x => x.id === id)).filter(Boolean);
  const sum = rows.reduce((a, r) => a + settlementEffectiveAmount(r), 0);
  const people = new Set(rows.map(r => r.influencer_id)).size;
  _bulkPayCtx = {
    settlementIds: rows.map(r => r.id),
    applicationIds: [],
    items: rows.map(_bulkItemFromSettlementRow),
    from: 'list',
    summaryHtml: `
      <div style="padding:12px 14px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;margin-bottom:16px">
        <div style="font-size:13px;color:var(--muted);margin-bottom:6px">이번에 기록할 내용</div>
        <div style="font-size:15px;font-weight:700;color:var(--ink)">${rows.length}건 · ${people}명 · 합계 ${settlementAmountYen(sum)}</div>
      </div>`
  };
  _openBulkPayModal();
}

function onSettlementBulkPayInput() {
  const memo = ($('settlementBulkPayMemo')?.value || '').trim();
  const btn = $('settlementBulkPayConfirmBtn');
  // 송금완료 모드에서 보낼 수 있는 묶음이 0개면(전부 페이팔 미등록 등) 누를 일이 없다
  const noBundle = !!(_bulkPayCtx && _bulkPayCtx.mode !== 'pending'
                      && Array.isArray(_bulkPayCtx.bundles) && _bulkPayCtx.bundles.length === 0);
  if (btn) btn.disabled = !memo || noBundle;
}

function closeSettlementBulkPayModal() {
  closeModal('settlementBulkPayModal');
  _bulkPayCtx = null;
}

async function confirmSettlementBulkPay() {
  if (settlementBulkLocked()) return;
  const ctx = _bulkPayCtx;
  if (!ctx) return;
  const memo = ($('settlementBulkPayMemo')?.value || '').trim();
  if (!memo) { toast('처리 사유를 입력해 주세요', 'warn'); return; }
  const btn = $('settlementBulkPayConfirmBtn');
  if (btn) btn.disabled = true;

  let done = 0;
  const skipped = [];
  const failed = [];

  // ⚠️ 옛 일괄 송금완료(markSettlementsPaidBulk · registerPastSettlements 'paid')는 **이 창에서 더는 안 부른다.**
  //    묶음이 한 번이라도 기록되면 서버가 그 경로를 payout_bundle_required 로 거부한다(486).
  //    🔴 「정산대기 추가」 모드는 송금완료를 절대 먼저 찍지 않는다(전수조사 B-4) — 아래 분기가 먼저 끝난다.

  // ★ 「정산대기 추가」 모드 — 아직 안 보낸 건이라 송금일을 넘기지 않는다.
  //   ⚠️ 이 모드에는 페이팔 확인이 걸리지 않는다(돈을 보내는 것이 아니라 목록에 올리는 것뿐).
  //      마이그레이션 324 가 「일괄 송금완료」에만 페이팔 검사를 넣은 것과 같은 판단이다.
  if (ctx.mode === 'pending') {
    try {
      const r = await registerPastSettlements(ctx.applicationIds, 'pending', memo);
      done += r.registered;
      // ⚠️ 서버(339)는 후보에 없는 응모를 어느 건수에도 안 넣는다 — 고른 수와 대조해 알린다(B-5).
      const _gone = _payoutUnaccounted(ctx.applicationIds, r);
      if (_gone) skipped.push(`후보 아님(인증 성공 전·이미 등록·조건 변경 등) ${_gone}건`);
    } catch (e) { failed.push('정산대기 추가: ' + friendlyError(e.message || e)); }
    if (failed.length && !done) {
      toast('처리 실패 — ' + failed.join(' / '), 'error');
      if (btn) btn.disabled = false;
      return;
    }
    toast(`${done}건을 정산대기로 추가했습니다` + (skipped.length ? ' — 건너뜀: ' + skipped.join(' · ') : ''));
    closeModal('settlementBulkPayModal');
    _bulkPayCtx = null;
    await _settlementRefreshKeepingView(ctx.from);
    return;
  }

  // ② 송금완료 — 묶음 전부를 서버 한 번으로(record_settlement_transfers, 486).
  //    정산 행이 있는 건과 없는 건이 한 묶음에 함께 들어간다. 하나라도 걸리면 아무것도 안 쓴다.
  const ok = await _confirmBulkTransfers(ctx, memo, btn);
  if (!ok) { if (btn) btn.disabled = false; return; }

  closeModal('settlementBulkPayModal');
  // 처리한 선택은 비운다 — 남겨 두면 「선택 3묶음 · 0건 · ¥0」 처럼 뜻 없는 줄이 남는다.
  //   ⚠️ 회차 상세로 돌아가는 경로는 openPayoutPersonList() 가 어차피 비우지만, 전 기간
  //      화면에서 처리하면 그 경로를 안 타므로 여기서 직접 비운다.
  if (ctx.from === 'list' && ctx.single) ctx.settlementIds.forEach(function (id) { _settlementSelected.delete(id); });
  else if (ctx.from === 'list') _settlementSelected.clear();
  else if (typeof _payoutSelected !== 'undefined' && _payoutSelected) _payoutSelected.clear();
  _bulkPayCtx = null;
  await _settlementRefreshKeepingView(ctx.from);
}

// 처리 뒤 **보고 있던 화면을 실제로 다시 그린다.**
//   ⚠️ `refreshPane('settlements')` 는 `reloadSettlementsData()` 를 부를 뿐이고, 그것은
//      `_settlements` 재조회 + 목록 재렌더 + 사이드바 배지까지만 한다. **지급 준비 화면의
//      `_payoutRows` 는 건드리지 않는다** — 그 값을 다시 채우는 곳은 `openPayoutPrepView()`
//      하나뿐이다.
//   ⚠️ 그래서 「보냄」으로 방금 기록한 사람이 **계속 「안 보낸 것」으로 남는다.** 이 화면의
//      존재 이유(이번 회차에 누구에게 얼마를 보내야 하는가)를 정면으로 무너뜨리고,
//      관리자가 같은 사람을 또 누르게 만든다. 2026-08-18 리뷰 지적.
//   ⚠️ 사람 목록을 보던 중이었다면 **그 회차로 되돌아간다** — 요약으로 튕기면 방금 처리한
//      자리를 다시 찾아 들어가야 한다.
async function _settlementRefreshKeepingView(from) {
  const due = _payoutDueFilter;           // 지급 준비에서 보던 회차(없으면 요약 화면)
  const wasPersonTab = _payoutSubView === 'person' && !due;   // 「사람별」 탭(전 기간)에서 처리했나
  await refreshPane('settlements');
  // ★ 미등록 탭에서 처리한 경우 — **그 목록을 다시 불러온다.** 안 하면 방금 처리한 건이
  //   목록에 그대로 남아 「처리가 안 됐나」로 읽히고, 다시 골라 누르게 된다(중복 처리 시도).
  //   ⚠️ 탭 건수·사이드바 경고도 이 경로에서만 실제로 줄어든다.
  if (from === 'unreg') {
    await loadPastUnregSettlements();
    refreshPastUnregEntryInfo();          // await 안 함 — 목록 표시를 막지 않는다
    return;
  }
  if (from !== 'payout') return;          // 목록 경로는 목록만 다시 그리면 된다
  // ⚠️ 「사람별」 탭에서 처리했으면 **그 탭으로** 돌아온다 — 요약으로 튕기면 탭 표시까지 바뀌어
  //    「어디로 갔지」가 된다. 검색어는 openPayoutPrepView 가 비우지 않아 그대로 남는다.
  await openPayoutPrepView(wasPersonTab); // _payoutRows 재계산 + 요약(또는 사람별) 재렌더
  if (due) await openPayoutPersonList(due);
  // ⚠️ 지급 준비에서 **미등록 건을 송금완료로 기록**하면 미등록 건수가 실제로 준다(전수조사 F-2).
  //    위 미등록 경로만 갱신하던 때는 주 동선(지급 준비)에서 처리해도 「미등록」 탭 건수와
  //    사이드바 경고가 옛 숫자로 남았다. await 안 함 — 화면을 막지 않는다.
  refreshPastUnregEntryInfo();
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
// SECTION: SETTLEMENTS — 회차 상세 「지급 완료」 줄의 정정·이력 (2026-10-08 사용자 요청)
// ════════════════════════════════════════════════════════════════════
//
// ⚠️ 사람별 펼침(_payoutItemRowHtml)·캠페인별 펼침(_payoutCampDetailHtml) **두 곳이 이 함수 하나**를 부른다.
// ⚠️ 정산 행이 없는 줄(미등록)은 버튼이 없다. 송금 묶음 없이 옛 방식으로 기록된 건은 「송금 정정」을 회색으로.
// ⚠️ 줄 클릭(펼침)과 겹치지 않게 stopPropagation.
function _payoutPaidActionsHtml(r) {
  if (!r || !r.settlementId) return '';
  const s = _settlements.find(function (x) { return x.id === r.settlementId; });
  if (!s || s.status !== 'paid') return '';
  const id = esc(s.id);
  const btn = 'class="btn btn-ghost btn-xs" style="padding:1px 6px;font-size:11px;white-space:nowrap;margin-left:4px"';
  const out = [];
  if (canWrite('settlement.pay')) {
    out.push(`<button ${btn} onclick="event.stopPropagation();openSettlementCorrectModal('${id}', 'payout')" title="이 건의 보낸 금액을 고칩니다">금액 정정</button>`);
    out.push(s.current_transfer_id
      ? `<button ${btn} onclick="event.stopPropagation();openPayoutTransferCorrect('${id}')" title="이 건이 들어 있는 송금의 송금일·수수료·요율을 고칩니다">송금 정정</button>`
      : `<button ${btn} disabled title="송금 묶음 없이 옛 방식으로 기록된 건입니다 — 송금일은 「금액 정정」 창에서 고칩니다">송금 정정</button>`);
  }
  out.push((s.event_count || 0) > 0
    ? `<button ${btn} onclick="event.stopPropagation();openSettlementHistoryModal('${id}')">이력</button>`
    : `<button ${btn} disabled title="변경 이력이 없습니다">이력</button>`);
  return out.join('');
}

// 회차 상세에서 「송금 정정」 — 그 건의 현재 송금 묶음을 받아 정정 창을 연다.
//   송금일(일본 날짜)로 먼저 찾고, 없으면(화면 값이 낡았을 수 있다) 전 기간으로 한 번 더 찾는다.
async function openPayoutTransferCorrect(settlementId) {
  const s = _settlements.find(function (x) { return x.id === settlementId; });
  if (!s || !s.current_transfer_id) { toast('이 건의 송금 기록을 찾을 수 없습니다', 'warn'); return; }
  const tid = s.current_transfer_id;
  const day = _settlementDateInputValue(s.paid_at);
  let rows = day ? await fetchSettlementTransfers(day, day) : [];
  let t = Array.isArray(rows) ? rows.find(function (x) { return x.id === tid; }) : null;
  if (!t) {
    rows = await fetchSettlementTransfers(null, null);
    if (rows === null) { toast('송금 기록을 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요', 'error'); return; }
    t = rows.find(function (x) { return x.id === tid; });
  }
  if (!t) { toast('송금 기록을 찾을 수 없습니다. 화면을 새로고침해 주세요', 'warn'); return; }
  openTransferCorrectModal(t.id, t, 'payout');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: SETTLEMENTS — 송금 묶음 이력 모달 (settlement_transfer_events, 읽기 전용)
// ════════════════════════════════════════════════════════════════════
//
// ⚠️ 이력 줄의 칸 구성이 마이그레이션마다 다르다(486 다섯 칸 → 502 추정 표시 → 514·517 요율 칸).
//    없는 칸은 그리지 않고, 값이 NULL 이면 「—」 — 0·¥0 으로 그리지 않는다(Number(null) 함정).
const TRANSFER_EVENT_FIELDS = [
  ['sent_at', '송금일'], ['sent_total_jpy', '보낸 금액'], ['fee_jpy', '수수료'], ['fee_manual', '고친 값'],
  ['fee_rate_percent', '요율'], ['fee_fixed_jpy', '고정액'], ['fee_rounding', '끝수'], ['fee_rule_custom', '이 송금만'],
  ['sent_at_estimated', '송금일 추정'], ['fee_estimated', '수수료 추정'],
  ['paypal_txn_id', '페이팔 거래번호'], ['memo', '메모'], ['source', '출처'],
];
const TRANSFER_EVENT_SOURCE_LABELS = { app: '화면 기록', sheet_backfill: '지급 시트에서 채움' };

function _transferEventValue(key, v) {
  if (v === null || v === undefined) return '—';
  if (key === 'sent_at') return _settlementDateInputValue(v) || '—';
  if (key === 'sent_total_jpy' || key === 'fee_jpy' || key === 'fee_fixed_jpy') return settlementAmountYen(Number(v));
  if (key === 'fee_rate_percent') return String(Number(v)) + '%';
  if (key === 'fee_rounding') return FEE_ROUNDING_LABELS[v] || String(v);
  if (key === 'source') return TRANSFER_EVENT_SOURCE_LABELS[v] || String(v);
  if (typeof v === 'boolean') return v ? '예' : '아니오';
  return String(v) === '' ? '(비움)' : String(v);
}

function _transferEventLinesHtml(e) {
  const prev = e.prev || {}, next = e.next || {};
  const lines = [];
  TRANSFER_EVENT_FIELDS.forEach(function (f) {
    const key = f[0];
    if (!(key in next)) return;
    const nv = _transferEventValue(key, next[key]);
    if (e.action === 'create') {
      if (next[key] === null || next[key] === undefined) return;
      lines.push(`<div><span style="color:var(--muted)">${esc(f[1])}</span> ${esc(nv)}</div>`);
      return;
    }
    if (!(key in prev)) return;
    const pv = _transferEventValue(key, prev[key]);
    if (pv === nv) return;
    lines.push(`<div><span style="color:var(--muted)">${esc(f[1])}</span> ${esc(pv)}`
      + ` <span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px;color:var(--muted)">arrow_forward</span> <b>${esc(nv)}</b></div>`);
  });
  if (e.action === 'create' && Array.isArray(next.items)) lines.push(`<div><span style="color:var(--muted)">건수</span> ${next.items.length}건</div>`);
  if (!lines.length) lines.push('<div style="color:var(--muted)">(바뀐 칸 없음)</div>');
  return lines.join('');
}

// ⚠️ 아이디는 transferEvent* — `transferHistoryBody` 는 「송금 내역」 화면(admin/index.html)이 이미 쓴다(겹치면 이 창이 그 화면을 덮어쓴다)
function _ensureTransferHistoryModal() {
  let el = $('transferEventModal');
  if (el) return el;
  el = document.createElement('div');
  el.className = 'modal-overlay';
  el.id = 'transferEventModal';
  el.style.zIndex = '615';
  el.innerHTML = `
    <div class="modal" style="max-width:520px;border-radius:20px;margin:auto">
      <div class="modal-header" style="padding:18px 22px 12px;border-bottom:1px solid var(--line)">
        <div style="font-size:16px;font-weight:700;color:var(--ink)">송금 이력</div>
        <div id="transferEventHeader" style="font-size:12px;color:var(--muted);margin-top:4px"></div>
      </div>
      <div class="modal-body" id="transferEventBody" style="padding:6px 22px 14px;max-height:60vh;overflow-y:auto"></div>
      <div style="padding:14px 22px;border-top:1px solid var(--line);display:flex;justify-content:flex-end">
        <button class="btn btn-ghost" onclick="closeModal('transferEventModal')">닫기</button>
      </div>
    </div>`;
  document.body.appendChild(el);
  return el;
}

// headerText — 송금 내역에서 열면 비워 두고 그 줄 정보로 채운다
async function openTransferHistoryModal(transferId, headerText) {
  _ensureTransferHistoryModal();
  const t = (_transferRows || []).find(function (x) { return x.id === transferId; });
  const head = headerText || (t ? `${t.influencer_name || '(탈퇴한 회원)'} · ${_settlementDateInputValue(t.sent_at)} · 보낸 금액 ${settlementAmountYen(t.sent_total_jpy)}` : '');
  $('transferEventHeader').textContent = head;
  const body = $('transferEventBody');
  body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:22px;font-size:12px">이력을 불러오는 중…</div>';
  openModal('transferEventModal');
  const events = await fetchSettlementTransferEvents(transferId);
  if (events === null) { body.innerHTML = '<div style="text-align:center;color:#C33;padding:26px;font-size:13px">이력을 불러오지 못했습니다. 잠시 뒤 다시 열어 주세요.</div>'; return; }
  // 정상 송금은 기록 이력이 최소 1건 있다 — 0건이면 정산 열람 권한이 없는 경우가 대부분이다(정책이 오류 대신 0건을 준다)
  if (!events.length) { body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:26px;font-size:13px">이력이 없거나 볼 권한이 없습니다.</div>'; return; }
  body.innerHTML = events.slice().reverse().map(function (e) {
    const label = e.action === 'create' ? '송금 기록' : '정정';
    return `<div style="padding:11px 0;border-bottom:1px dashed var(--line)">
      <div style="display:flex;justify-content:space-between;gap:10px;align-items:center">
        <span style="font-size:13px;font-weight:700;color:var(--ink)">${label}</span>
        <span style="font-size:11px;color:var(--muted);white-space:nowrap">처리자: ${esc(e.actor_name || '시스템')} · ${e.at ? esc(formatDateTime(e.at)) : ''}</span>
      </div>
      <div style="margin-top:6px;font-size:12px;line-height:1.7">${_transferEventLinesHtml(e)}</div>
      <div style="margin-top:4px;display:flex;gap:8px;font-size:12px"><span style="color:var(--muted);flex-shrink:0">메모</span>${e.memo ? `<span style="white-space:pre-wrap">${esc(e.memo)}</span>` : '<span style="color:var(--muted)">—</span>'}</div>
    </div>`;
  }).join('');
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
      + `<span>·</span>${settlementStatusBadge(s.status)}</div>`
      // 이 건이 들어 있는 송금의 이력(송금일·수수료·요율 정정은 건 이력이 아니라 송금 이력에 남는다)
      + (s.current_transfer_id
        ? `<div style="margin-top:6px"><a href="javascript:void(0)" style="font-size:12px;color:#2563EB" onclick="closeSettlementHistoryModal();openTransferHistoryModal(${jsStr(s.current_transfer_id)}, ${jsStr((inf.name || '') + ' · ' + (camp.title || ''))})">이 건이 들어 있는 송금의 이력 보기 (송금일·수수료·요율 정정)</a></div>`
        : '');
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
  // 줄마다 제목(상태 변경·메모)을 붙이고 처리자는 날짜 왼쪽에 둔다(2026-10-08 사용자 요청 — 송금 이력 창과 같은 모양)
  const memoLine = `<div style="margin-top:6px;display:flex;gap:8px;font-size:12px;line-height:1.55">`
    + `<span style="color:var(--muted);flex-shrink:0;width:52px">메모</span>`
    + (e.memo ? `<span style="color:var(--ink);white-space:pre-wrap">${esc(e.memo)}</span>` : '<span style="color:var(--muted)">—</span>')
    + `</div>`;
  return `<div style="padding:11px 0;border-bottom:1px dashed var(--line)">`
    + `<div style="display:flex;justify-content:space-between;gap:10px;align-items:center">`
    + `<span style="font-size:13px;font-weight:700;color:var(--ink)">${esc(label)}</span>`
    + `<span style="font-size:11px;color:var(--muted);white-space:nowrap">처리자: ${actor} · ${at}</span>`
    + `</div>`
    + (transition ? `<div style="margin-top:6px;display:flex;align-items:center;gap:8px;font-size:12px">`
      + `<span style="color:var(--muted);flex-shrink:0;width:52px">상태 변경</span>`
      + `<span style="display:inline-flex;align-items:center;gap:4px;font-size:11px">${transition}</span></div>` : '')
    + `${memoLine}</div>`;
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
      // 열 이름은 화면 열 제목과 같게 맞춘다(2026-10-01 사용자 결정) — 이름(한자)·후리가나·페이팔·금액·보낸 금액·인증 성공일·송금일
      { header: '이름(한자)', key: 'kanji',    width: 14 },
      { header: '후리가나',   key: 'kana',     width: 16 },
      { header: '이메일',     key: 'email',    width: 24 },
      { header: '캠페인 번호', key: 'campno',  width: 16 },
      { header: '캠페인',     key: 'title',    width: 28 },
      { header: '브랜드',     key: 'brand',    width: 18 },
      { header: '금액',       key: 'amount',   width: 12 },
      { header: '금액구분',   key: 'amtsrc',   width: 12 },
      // 299 추가 — 영수증 기준 건에서 「왜 이 금액인가」를 엑셀에서도 대조할 수 있게.
      // 옛 행(상시가·현금 리워드 기준)은 빈 칸으로 남는다.
      { header: '영수증 금액', key: 'receipt', width: 14 },
      { header: '상한',       key: 'cap',      width: 12 },
      { header: '상한적용',   key: 'capped',   width: 10 },
      // [338·339] 실제로 보낸 금액. ⚠️ 빈 칸은 「계산 금액과 같음」이지 0원이 아니다 —
      //   Number(null) 이 0 이라 그냥 넘기면 「0엔을 보냈다」로 읽힌다(299 때와 같은 함정).
      { header: '보낸 금액',  key: 'paidamt',  width: 14 },
      { header: '계산액과다름', key: 'amtdiff',  width: 12 },
      { header: '페이팔',     key: 'paypal',   width: 26 },
      { header: '상태',       key: 'status',   width: 10 },
      { header: '인증 성공일', key: 'certdate', width: 14 },
      { header: '송금일',     key: 'paiddate', width: 14 },
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
        brand:    brandLabelAdmin(camp),
        amount:   Number(s.amount_jpy) || 0,
        amtsrc:   settlementAmountSourceLabel(s.amount_source),
        // ⚠️ Number(null) 은 0 이므로 null 검사를 먼저 — 안 그러면 299 이전 행이
        // 「영수증 0엔」으로 찍혀 실제로 0원에 샀다는 오해를 준다.
        receipt:  (s.receipt_amount_jpy != null) ? Number(s.receipt_amount_jpy) : '',
        cap:      (s.amount_cap_jpy != null) ? Number(s.amount_cap_jpy) : '',
        capped:   settlementCapApplied(s) ? 'O' : '',
        paidamt:  (s.paid_amount_jpy != null) ? Number(s.paid_amount_jpy) : '',
        amtdiff:  (s.paid_amount_jpy != null && Number(s.paid_amount_jpy) !== Number(s.amount_jpy)) ? 'O' : '',
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

let _pastUnregLoaded = false;            // 미등록 조회를 한 번이라도 받았나 (0건과 미조회 구분)
let _pastUnregRows = [];                 // 서버 조회 원본(필터 전)
let _pastUnregFiltered = [];             // 필터 통과분 — 렌더·전체선택·툴바의 기준
let _pastUnregById = {};                 // application_id → 행
let _pastUnregSelected = new Set();      // 선택된 application_id
var pastUnregLazy = null;
const PAST_UNREG_PAGE_SIZE = 50;
const PAST_UNREG_TYPE_LABELS = { monitor: '리뷰어형', gifting: '기프팅', visit: '방문형' };

// ⚠️ 옛 진입 함수 — `index.html` 의 onclick 이 아직 부른다(「확인하러 가기」 등).
//   지우지 않고 **탭으로 위임**한다. 지우면 그 버튼들이 조용히 죽는다.
function openPastUnregView() {
  // ⚠️ **공용 필터를 먼저 비운다.** 이 버튼(「확인하러 가기」)은 정산 목록 화면 상단 안내에서
  //    눌리는데, 그 화면에 걸어 둔 캠페인·검색이 그대로 미등록 탭으로 따라온다. 그러면
  //    「금액을 확인해야 하는 건 전부」를 보러 왔는데 **일부가 조용히 빠진 목록**이 열린다.
  //    사이드바 배지·경고 표시 경로(enterSettlementsWithView)는 이미 비우고 들어간다.
  clearSettlementSharedFilters();
  _settlementFilters.status = 'unregistered';
  showUnregisteredTab();
}

// (옛 진입 함수 `_legacyOpenPastUnregView_unused` 는 없앴다 — 부르는 곳이 0곳인데
//  없어진 화면 요소를 가리키고 있었다. 2026-08-19)

// 옛 이탈 함수 — 「전체」 탭으로 돌아간다.
function closePastUnregView() {
  _settlementFilters.status = '';
  hideUnregisteredTab();
  renderSettlementsList();
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
  _pastUnregLoaded = true;          // 탭 건수를 「…」에서 실제 숫자로
  renderSettlementStatusTabs();
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
  // ⚠️ 미등록 탭이 아닐 때는 손대지 않는다 — 안 막으면 처리 직후 목록 갱신이 정산 행 기준으로
  //    선택지를 덮어써, 미등록 화면에서 방금 고른 캠페인이 사라진다.
  if (_settlementFilters.status !== 'unregistered') return;
  if (!$('settlementCampMulti') || typeof syncCampMultiFilter !== 'function') return;
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
  syncCampMultiFilter('settlementCampMulti', [...seen.values()], () => onSettlementFilterChange(), campCounts);
}

// 미등록 탭 필터 — **위쪽 공용 줄**을 읽는다(2026-08-19 통합). 전용 필터 줄은 없앴다.
//   ⚠️ 검색어를 소문자로 만들지 않아도 된다 — `matchSearchTokens` 가 찾는 말을 스스로 낮춘다.
function readPastUnregFilters() {
  return {
    campaignIds: (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('settlementCampMulti') : [],
    type: $('settlementTypeFilter')?.value || '',
    search: ($('settlementSearch')?.value || '').trim(),
  };
}

// ★ 공용 필터(캠페인·검색·모집 형식)가 바뀌었을 때의 **단일 분배기**.
//   ⚠️ 화면마다 다른 함수를 직접 매달지 않는다 — 캠페인 드롭다운은 선택지가 같으면 다시
//      만들어지지 않아 **옛 탭의 동작이 그대로 남는 일**이 생긴다(그러면 미등록에서 눌렀는데
//      정산 목록이 그려지고, 선택 초기화도 안 돈다). 분배기 하나면 그 구멍이 없다.
function onSettlementFilterChange() {
  if (_settlementFilters.status === 'unregistered') { onPastUnregFilterChange(); return; }
  renderSettlementsList();
}

// 캠페인 필터를 제외한 조건(캠페인별 건수 집계 기준과 목록 필터가 같은 함수를 쓰도록 분리)
function passesPastUnregNonCamp(r, type, search) {
  if (type && r.recruit_type !== type) return false;
  // 이름·가나·이메일 — 다른 탭(정산 목록)과 **같은 세 가지**로 찾는다(2026-08-19 사용자 결정).
  //   ⚠️ 이메일은 마이그레이션 344 로 서버 함수가 내려주기 시작한 값이다. 적용 전에는 그 칸이
  //      비어 있는데, matchSearchTokens 가 빈 값을 그냥 건너뛰므로 **이름·가나 검색은 그대로**
  //      동작한다(화면이 데이터베이스보다 먼저 배포돼도 안 깨진다).
  if (search && !matchSearchTokens(search, [r.influencer_name, r.influencer_name_kana, r.influencer_email])) return false;
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
  clearSettlementSharedFilters();
  onPastUnregFilterChange();
}

// 공용 줄(캠페인·검색·모집 형식)을 비운다 — 초기화 버튼과 탭 전환이 함께 쓴다.
function clearSettlementSharedFilters() {
  if (typeof clearMultiFilter === 'function') clearMultiFilter('settlementCampMulti', '전체 캠페인');
  const typeEl = $('settlementTypeFilter'); if (typeEl) typeEl.value = '';
  const searchEl = $('settlementSearch');   if (searchEl) searchEl.value = '';
  _settlementFilters.campaignIds = [];
  _settlementFilters.search = '';
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
      _pastUnregRows.length ? '조건에 맞는 건이 없습니다. 필터를 확인해 주세요.' : '미등록 건이 없습니다.'
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
    if (r && !pastUnregHasIssue(r)) { count++; sum += settlementEffectiveAmount(r); }
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
    cur.sum += settlementEffectiveAmount(r);
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
// ★ 3단계 전에는 이 경로를 **잠근다.**
//   ⚠️ 지금 기록하면 **오늘 날짜·계산 금액으로 확정**되고 되돌릴 수 없다(사양서 §1-7).
//      실제 보낸 날짜·금액을 넣을 수 있게 되는 것은 3단계(마이그레이션 C·E)다.
//   ⚠️ **잠그는 문은 셋이다** — ①1단계 지급 준비의 「보냄」 ②미등록 탭의 일괄 처리
//      ③**개별 송금완료 모달**(confirmSettlementPay). 사양서 §8 은 둘이라 적었으나
//      그건 그때 센 것이 둘뿐이었기 때문이고, 같은 논리가 ③에도 적용된다(2026-08-18 확인).
//      하나라도 열어 두면 「3단계 전 처리 금지」가 그 문으로 뚫린다.
//   ⚠️ 3단계에서 **세 문을 다 푸는 것**이 그 단계의 완료 조건이다. 안 풀면 화면이 영영 반쪽이다.
//   ⚠️ 보류·취소·보류 해제는 **잠그지 않는다** — 날짜·금액을 안 다루고, 잠그면 정산대기 건에
//      문제가 생겼을 때 옮길 곳이 없어지는 진짜 기능 축소가 된다.
// ★ 2026-08-18 열림. 이제 **실제로 보낸 날짜·금액을 입력할 수 있으므로**(마이그레이션
//   338·339·340·341) 잠가 둘 이유가 사라졌다. 잠금의 근거는 「오늘 날짜·계산 금액으로
//   확정되고 되돌릴 수 없다」였고, 그 두 가지가 모두 해소됐다 —
//   날짜·금액은 입력받고, 틀리면 `correct_settlement_payment` 로 고친다.
// ⚠️ 이 하나로 **네 경로가 함께 열린다**(단건 송금완료·과거 미등록 일괄·기록 정정·
//    정산대기 일괄). 다시 잠글 일이 생기면 여기만 false 로 되돌리면 된다.
const SETTLEMENT_BULK_UNLOCKED = true;

function settlementBulkLocked() {
  if (SETTLEMENT_BULK_UNLOCKED) return false;
  if (typeof toast === 'function') {
    toast('아직 기록할 수 없습니다 — 실제 보낸 날짜와 금액을 입력할 수 있게 된 뒤에 열립니다', 'info');
  }
  return true;
}

// 미등록 선택 건 처리 — **확인 모달에서 사유를 함께 받는다**(2026-08-19 사용자 요청).
//   ⚠️ 예전에는 목록 위 메모칸에 먼저 적고 버튼을 눌렀다. 그러면 확인 창에 「무엇을 기록하는지」는
//      있는데 **어떤 사유로 기록하는지는 안 보였다.** 되돌릴 수 없는 기록이라 한 화면에서 본다.
//   ⚠️ 처리는 일괄 송금완료와 **같은 함수**(confirmSettlementBulkPay)를 쓴다 — 두 벌로 만들면
//      한쪽만 고치게 된다(이 파일 위쪽 `_bulkPayCtx` 주석의 원칙).
function pastUnregRegister(targetStatus) {
  if (settlementBulkLocked()) return;   // ★ 3단계 전 확정 기록 차단
  // 금액 미확정 건은 서버가 건너뛰므로 여기서도 제외(체크박스는 이미 잠겨 있지만 이중 방어)
  const rows = [..._pastUnregSelected]
    .map(id => _pastUnregById[id])
    .filter(r => r && !pastUnregHasIssue(r));
  const ids = rows.map(r => r.application_id);
  if (!ids.length) { toast('선택된 건이 없습니다', 'warn'); return; }
  const sum = rows.reduce((n, r) => n + settlementEffectiveAmount(r), 0);
  const summary = pastUnregCampaignSummary(rows);
  const people = new Set(rows.map(r => r.influencer_id)).size;

  _bulkPayCtx = {
    settlementIds: [],                 // 미등록 건은 정산 행이 아직 없다
    applicationIds: ids,
    items: rows.map(_bulkItemFromUnregRow),
    mode: targetStatus === 'pending' ? 'pending' : 'paid',
    from: 'unreg',
    summaryHtml: `
      <div style="padding:12px 14px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;margin-bottom:16px">
        <div style="font-size:13px;color:var(--muted);margin-bottom:6px">${summary.campaignCount}개 캠페인 · ${people}명</div>
        <div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:8px">${ids.length}건 · 합계 ${settlementAmountYen(sum)}</div>
        <div style="border-top:1px solid var(--line);padding-top:6px;max-height:200px;overflow:auto;font-size:12px;line-height:1.7">
          ${summary.lines.map(t => `<div>${esc(t)}</div>`).join('')}
        </div>
      </div>`
  };
  _openBulkPayModal();
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

// 지급 흐름에서 벗어난 상태 — 네 묶음 어디에도 넣지 않는다(사양서 §4-1).
const PAYOUT_EXCLUDED_STATUS = new Set(['on_hold', 'cancelled']);

// 'YYYY-MM-DD' → 'YYYY-MM'
function _payoutMonthOf(dueStr) { return dueStr ? String(dueStr).slice(0, 7) : null; }

// 금액 칸 — 🔴 금액을 정할 수 없는 건(amount_issue)은 「¥0」이 아니라 **「금액 미확정」**으로 그린다
//   (전수조사 F-3). `settlementEffectiveAmount` 가 그 행에 0 을 주므로 그냥 그리면 「¥0」이 되고,
//   합계에서는 조용히 빠져 지급대장 대조 금액이 낮게 나온다. 같은 행이 미등록 탭에서는 빨간
//   배지로 정상 표시되던 것과 맞춘다.
// 데이터가 **빠진** 칸 — 표에서는 「—」로 쓰되 주황색으로 칠하고 마우스를 올리면 이유가 뜬다(2026-09-30 사용자 결정).
//   ⚠️ 그냥 「—」(아직 안 보냄 등 정상적인 빈칸)와 **색으로 반드시 갈린다** — 빠진 인증 성공일을 다른 날짜로 채우지 않는 규칙의 표시.
//   확인 창의 문장·엑셀처럼 글로 읽는 자리는 「기록 없음」 글자를 그대로 쓴다.
const _MISSING_CERT_TIP = '인증 성공일 기록 없음 — 이 날짜가 없어 지급 회차를 계산할 수 없습니다';
function _missingDash(why) {
  return `<span style="color:#D97706;font-weight:700;cursor:help" title="${esc(why)}">—</span>`;
}

function _payoutAmountCell(r) {
  if (r && r.amountUnknown) {
    return '<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:2px 6px;border-radius:3px" title="금액을 정할 수 없어 합계에서 뺐습니다 — 미등록 탭에서 사유를 확인하세요">금액 미확정</span>';
  }
  return esc(_payoutYen(r.amount));
}
// 합계 옆에 붙이는 「미확정 N건 제외」 — 0이면 아무것도 안 붙인다(늘 떠 있으면 아무도 안 본다).
function _payoutUnknownNote(list) {
  const n = (list || []).filter(function (r) { return r.amountUnknown; }).length;
  return n ? ` <span style="color:#C33;font-size:11px" title="금액을 정할 수 없는 건은 합계에 안 들어갑니다">· 미확정 ${n}건 제외</span>` : '';
}

// 미등록 + 정산 행을 한 목록으로. 지급 예정일은 payoutDueDate 하나로만 계산한다.
//   ⚠️ 카드·목록·엑셀이 각자 계산하면 어긋난다(사양서 §4-1).
function buildPayoutRows(unregRows, settlementRows) {
  const out = [];
  (unregRows || []).forEach(function(r) {
    out.push({
      kind: 'unregistered',
      status: 'unregistered',           // 아직 정산 행이 없다
      due: payoutDueDate(r.cert_at),
      certAt: r.cert_at,          // 결과물 최종 승인(인증 성공) 시각
      amount: settlementEffectiveAmount(r),
      amountUnknown: !r.amount_jpy,     // 금액을 정할 수 없는 건(amount_issue)
      influencerId: r.influencer_id,
      name: r.influencer_name, nameKana: r.influencer_name_kana,
      // 회차 엑셀용(2026-09-29 사양서). 화면 목록은 안 쓴다.
      email: r.influencer_email || null, recruitType: r.recruit_type || null,
      // 브랜드는 미등록 조회가 주지 않는다 — 회차 엑셀이 캠페인 목록에서 채운다(_payoutFillBrands)
      campaignId: r.campaign_id || null, brand: null,
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
      certAt: s.cert_at,          // 결과물 최종 승인(인증 성공) 시각
      // ★ 지급 준비 화면의 사람별 소계는 **실제 이체 금액을 정하는 숫자**다.
      //   계산값만 쓰면 이미 다르게 보낸 건이 섞였을 때 그 소계가 곧 틀린 송금액이 된다.
      amount: settlementEffectiveAmount(s),
      // 그 회차 합계가 「실제 송금일 기준」인지 「등록한 날 기준」인지 가르는 표시.
      recordDateOnly: settlementPaidAtIsRecordDate(s),
      amountUnknown: false,
      influencerId: s.influencer_id,
      name: null, nameKana: null,       // 이름은 작업 3에서 통로로 채운다
      // 회차 엑셀용. 이메일은 가림막 뷰를 거친 값(fetchSettlements → fetchInfluencersByIds)
      email: (s.influencers && s.influencers.email) || null, recruitType: camp.recruit_type || null,
      campaignId: s.campaign_id || null, brand: brandLabelAdmin(camp) || null,
      campaignNo: camp.campaign_no, campaignTitle: camp.title,
      applicationId: s.application_id,
      settlementId: s.id, paypalEmail: s.paypal_email, paidAt: s.paid_at,
    });
  });
  return out;
}

// 아직 안 보낸 것 = 미등록 + 정산대기. 「기한 초과」와 「다가오는」의 공통 조건이다.
function _payoutUnsent(r) { return r.status === 'unregistered' || r.status === 'pending'; }

// ─── 화면 탭 줄(settlementNavBar) — 네 화면이 같은 줄을 쓴다(2026-09-30 사용자 결정) ───
//   ★ 「지금 어느 탭인가」는 **화면 상태에서 계산한다**(따로 변수로 들고 다니지 않는다).
//     화면을 켜고 끄는 길이 많아(페인 진입·배지 진입·저장 뒤 재조회) 변수로 들면 한 곳만 빠져도 탭이 거짓말을 한다.
//   ⚠️ 「사람별」은 지급 준비 화면 **안의** 사람 목록이다(별도 화면 아님). 회차 「상세」로 들어간 사람 목록은
//      그 회차의 일부라 「지급 준비」 탭으로 표시한다 — 「사람별」 탭은 **전 기간 사람 목록**(_payoutDueFilter=null)일 때만.
let _payoutSubView = 'summary';   // 지급 준비 화면 안: 'summary'(회차 요약) | 'person'(사람 목록)

function _settlementActiveTab() {
  const shown = function (id) { const e = $(id); return !!e && e.style.display !== 'none'; };
  if (shown('settlementTransferView')) return 'transfer';
  if (shown('settlementPayoutView')) return (_payoutSubView === 'person' && !_payoutDueFilter) ? 'person' : 'prep';
  return 'list';
}

function refreshSettlementNav() {
  const active = _settlementActiveTab();
  document.querySelectorAll('#settlementNavBar [data-settle-tab]').forEach(function (b) {
    b.classList.toggle('on', b.getAttribute('data-settle-tab') === active);
  });
  // 탭 줄 오른쪽 도구는 회차별(요약·회차 상세)에서만 — 요약은 renderPayoutSummary, 회차 상세는
  // renderPayoutPersonList 가 채운다. 다른 화면이면 비운다.
  const tools = $('settlementNavTools');
  if (tools && active !== 'prep') tools.innerHTML = '';
  // 엑셀은 **정산 목록**을 내보내므로 목록 탭(미등록 제외)에서만 보인다.
  const excelBtn = $('settlementExcelBtn');
  if (excelBtn) {
    const isUnreg = !!(_settlementFilters && _settlementFilters.status === 'unregistered');
    excelBtn.style.display = (active === 'list' && !isUnreg) ? '' : 'none';
  }
}

// 지급 준비 안에서 보던 회차·검색어·선택을 비운다 — 다른 탭에서 돌아올 때 남의 회차가 열린 채 뜨지 않게.
function _resetPayoutSubState() {
  _payoutDueFilter = null;
  _payoutPersonSearch = '';
  _payoutSearchTokens = [];
  _payoutPeriodFrom = ''; _payoutPeriodTo = '';
  _payoutSelected.clear();
}

async function openSettlementTab(key) {
  const payoutShown = (function () { const e = $('settlementPayoutView'); return !!e && e.style.display !== 'none'; })();
  if (key === 'transfer') { openTransferHistoryView(); return; }
  if (key === 'list') {
    const pv = $('settlementPayoutView');
    if (pv) pv.style.display = 'none';
    closeTransferHistoryView(true);   // 목록을 켜고, 미등록 탭을 보던 중이면 그 자리로
    return;
  }
  _resetPayoutSubState();
  // 지급 준비가 이미 떠 있고 자료가 있으면 다시 받지 않는다(탭만 바꾼다).
  //   ⚠️ 다른 탭에서 들어오면 다시 받는다 — 그 사이 송금 기록이 바뀌었을 수 있다(기존 동작과 같다).
  if (payoutShown && Array.isArray(_payoutRows)) {
    if (key === 'person') await openPayoutPersonList(null);
    else renderPayoutSummary();
    return;
  }
  await openPayoutPrepView(key === 'person');
}

async function openPayoutPrepView(thenPerson) {
  const main = $('settlementMainView'), view = $('settlementPayoutView');
  if (!main || !view) return;
  // ⚠️ 「미등록」 화면은 목록 화면의 **형제**라, 목록만 감추면 그대로 남는다.
  //    안 감추면 지급 준비와 미등록이 **세로로 겹쳐 한 화면에 둘 다** 뜬다
  //    (2026-08-18 운영에서 실제로 그렇게 보였다). 세 화면은 서로 배타여야 한다.
  hideUnregisteredTab();                // 송금 내역도 여기서 닫힌다(_hideTransferView)
  main.style.display = 'none';
  view.style.display = 'flex';
  _payoutSubView = thenPerson ? 'person' : 'summary';   // 불러오는 동안에도 누른 탭이 켜져 있게
  refreshSettlementNav();
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
  _payoutExportIncludePaid = false;   // 회차 엑셀 「송금완료 포함」은 들어올 때마다 꺼진 상태로
  _payoutRoundPick.clear();           // 고른 회차도 들어올 때마다 비운다
  _payoutExportIncludeEarlier = true; // 「이전 회차 미지급 포함」은 들어올 때마다 켜진 상태로(사양서 D-6 기본 켬)
  // ⚠️ 사람 정보 캐시를 비운다 — 안 비우면 그 사이 새로 생긴 정산 행의 인플루언서가
  //    「(이름 미상)·페이팔 미등록」으로 보인다(조회를 안 하니 값이 없을 뿐인데).
  _payoutPersonInfo = null;
  if (thenPerson) { await openPayoutPersonList(null); return; }   // 「사람별」 탭 — 요약을 거치지 않는다(번쩍임 방지)
  renderPayoutSummary();
}

function closePayoutPrepView() {
  const main = $('settlementMainView'), view = $('settlementPayoutView');
  if (view) view.style.display = 'none';
  _hideTransferView();
  if (main) main.style.display = 'flex';
  // 지급 준비로 가기 전에 「미등록」 탭을 보고 있었다면 그 자리로 돌려준다 —
  // 돌아왔더니 다른 탭이면 방금 보던 목록을 다시 찾아 들어가야 한다.
  if (_settlementFilters && _settlementFilters.status === 'unregistered'
      && typeof showUnregisteredTab === 'function') {
    showUnregisteredTab();
  }
  refreshSettlementNav();
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
  // ★ 그 회차 안에서 보낸 것 / 아직 안 보낸 것을 가른다.
  //   왼쪽 숫자는 **그 날 전체**, 오른쪽 두 열이 그 내역이다 — 셋을 함께 봐야
  //   「얼마나 남았나」와 「원래 얼마였나」를 같이 알 수 있다.
  const sent   = rows.filter(function(r) { return r.status === 'paid'; });
  const unsent = rows.filter(_payoutUnsent);
  const unknown = rows.filter(function(r) { return r.amountUnknown; }).length;
  // ⚠️ 「기록일 N건」은 여기 안 그린다(2026-08-18 사용자 결정). 지금은 그 값이 송금완료
  //    건수와 **똑같아** 같은 정보가 두 번 나온다 — 옛 행은 전부 송금완료이기 때문이다.
  //    ⚠️ 앞으로 새로 송금완료가 쌓이면 두 값은 갈라진다. 그때도 「그 날짜가 실제 송금일이
  //       아니다」는 표시는 **정산 목록의 행별 「기록일」 표**에 그대로 남아 있으니
  //       정보가 사라지는 것은 아니다. 여기서만 안 보일 뿐이다.
  const overdue = due < todayStr;
  const days = Math.round((Date.parse(due + 'T00:00:00+09:00') - Date.parse(todayStr + 'T00:00:00+09:00')) / 86400000);
  const when = overdue
    ? `<span style="color:#C33;font-weight:700">지남 ${-days}일</span>`
    : (days === 0 ? '<span style="color:#B8741A;font-weight:700">오늘</span>' : `<span style="color:var(--muted)">D-${days}</span>`);
  // 0건인 쪽은 흐리게 — 「없다」가 한눈에 보이게.
  const cell = (n, amt, color) => n
    ? `<div style="font-weight:600;color:${color}">${n}건</div><div style="font-size:11px;color:${color}">${esc(_payoutYen(amt))}</div>`
    : '<span style="color:var(--muted);opacity:.5">—</span>';
  const notes = [];
  if (unknown) notes.push(`<span style="color:#C33">금액 미확정 ${unknown}건</span>`);
  const picked = _payoutRoundPick.has(due);
  return `<tr>
    <td style="width:36px;text-align:center"><input type="checkbox" ${picked ? 'checked' : ''}
        onchange="togglePayoutRoundPick('${esc(due)}', this.checked)" title="이 회차를 엑셀 다운로드에 담습니다" style="margin:0;cursor:pointer"></td>
    <td style="font-weight:700;white-space:nowrap">${esc(due)}</td>
    <td style="text-align:right;white-space:nowrap">${cnt}건</td>
    <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(_payoutYen(sum))}</td>
    <td style="text-align:right;white-space:nowrap">${cell(sent.length, _payoutSum(sent), '#16A34A')}</td>
    <td style="text-align:right;white-space:nowrap">${cell(unsent.length, _payoutSum(unsent), '#C33')}</td>
    <td style="white-space:nowrap">${when}${notes.length ? `<div style="font-size:11px">${notes.join(' · ')}</div>` : ''}</td>
    <td style="white-space:nowrap"><button class="btn btn-ghost btn-xs" style="padding:2px 10px"
        onclick="openPayoutPersonList('${esc(due)}')">상세</button></td>
  </tr>`;
}

// ─── 검색칸·기간 칸 모양 — 「사람별」과 「송금 내역」이 같은 모양을 쓴다(2026-10-01 사용자 결정) ───
//   ⚠️ 「admin-filter-search」 는 돋보기 자리로 왼쪽 28px 을 비우는 클래스다 — 아이콘과 한 쌍으로만 쓴다.
//   ⚠️ 이 함수가 돌려주는 문자열은 템플릿 안에 끼워 넣는다 — 주석에 backtick 을 쓰지 말 것.
function settleSearchInputHtml(id, value, oninput, opts) {
  const o = opts || {};
  return `<div style="position:relative;width:300px">
      <span class="material-icons-round notranslate" translate="no"
            style="position:absolute;left:8px;top:50%;transform:translateY(-50%);font-size:16px;color:var(--muted)">search</span>
      <input id="${id}" type="search" class="admin-filter-search"
             autocomplete="off" data-lpignore="true" data-1p-ignore="true"
             placeholder="이름(한자·후리가나)·페이팔 이메일로 검색"
             value="${esc(value || '')}" oninput="${oninput}"${o.disabled ? ' disabled' : ''}
             ${o.title ? `title="${esc(o.title)}"` : ''}>
    </div>`;
}
// 기간 칸 + 칸 안쪽 오른쪽 끝의 × 지우기(기간이 있을 때만 보인다). 달력(flatpickr)은 부르는 쪽이 붙인다.
//   ⚠️ × 아이콘을 1px 내린 것은 날짜 글자(12px)가 글꼴 특성상 칸 가운데보다 살짝 아래에 그려져서다.
function settleRangeInputHtml(inputId, clearId, clearFn, title, placeholder) {
  return `<div style="position:relative">
      <input type="text" id="${inputId}" class="admin-filter-search" readonly placeholder="${esc(placeholder || '시작일~종료일 선택')}"
             title="${esc(title)}"
             style="min-width:200px;cursor:pointer;background:#fff;padding:6px 28px 6px 10px">
      <button type="button" id="${clearId}" onclick="${clearFn}()" title="기간 지우기(전체 기간)" aria-label="기간 지우기"
              style="display:none;position:absolute;right:4px;top:0;bottom:0;margin:auto 0;width:22px;height:22px;padding:0;border:none;border-radius:50%;background:transparent;color:var(--muted);cursor:pointer;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="font-size:15px;line-height:1;display:block;position:relative;top:1px">close</span></button>
    </div>`;
}
function _settleFpDate(d) {
  return d ? `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}` : '';
}

// ─── 회차 골라 엑셀 받기(요약) ───────────────────────────────────────
//   줄 앞 체크박스로 회차를 고르고 표 위 「다운로드」로 받는다. **여러 회차면 한 파일**에 담는다(2026-09-30 사용자 결정).
const _payoutRoundPick = new Set();   // 고른 회차('YYYY-MM-DD')
// 내려받기 단추 글자 — 정산 관리의 내려받기 단추는 모두 「↓ 다운로드(xlsx)」로 맞춘다(2026-09-30 사용자 결정).
const _DOWNLOAD_XLSX_HTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:middle">download</span> 다운로드(xlsx)';
function payoutRoundPickDownloadBtnHtml() {
  const n = _payoutRoundPick.size;
  return `<button class="btn btn-ghost btn-sm" id="payoutRoundPickDownloadBtn" ${n ? '' : 'disabled'}
      title="${n ? '고른 회차의 송금 명단을 한 파일로 내려받습니다(검색어·보기와 상관없이 회차 전체)' : '표에서 회차를 먼저 고르세요'}"
      onclick="exportPickedPayoutRounds()">${_DOWNLOAD_XLSX_HTML}${n
        ? ` <span style="display:inline-block;min-width:16px;padding:0 5px;border-radius:8px;background:var(--ink);color:#fff;font-size:10px;line-height:16px;text-align:center">${n}</span>` : ''}</button>`;
}
function togglePayoutRoundPick(due, on) {
  if (on) _payoutRoundPick.add(due); else _payoutRoundPick.delete(due);
  renderPayoutSummary();   // 머리의 「전체 선택」 표시와 단추 숫자를 함께 맞춘다
}
function togglePayoutRoundPickAll(on) {
  const rows = _payoutRows || [];
  _payoutRoundPick.clear();
  if (on) rows.forEach(function (r) { if (r.due) _payoutRoundPick.add(r.due); });
  renderPayoutSummary();
}
function exportPickedPayoutRounds() {
  const dues = Array.from(_payoutRoundPick).sort();
  if (!dues.length) { toast('표에서 회차를 먼저 고르세요', 'warn'); return; }
  exportPayoutRoundExcel(dues, { includePaid: _payoutExportIncludePaid, includeEarlier: _payoutExportIncludeEarlier });
}

// 「이 회차 송금 명단 엑셀」 단추 — 사람별 화면(회차 상세) 머리가 쓴다.
function payoutRoundExcelBtnHtml(due) {
  return `<button class="btn btn-ghost btn-sm"
      title="이 회차의 송금 명단을 내려받습니다. 검색어·회원별/캠페인별 보기와 상관없이 회차 전체가 대상입니다"
      onclick="exportPayoutRoundExcel('${esc(due)}', {includePaid:_payoutExportIncludePaid, includeEarlier:_payoutExportIncludeEarlier})">${_DOWNLOAD_XLSX_HTML}</button>`;
}

// 「송금완료 포함」 체크박스 — id 만 다르고 두 화면이 같은 변수를 본다.
function payoutExportIncludePaidHtml(id) {
  return `<label style="font-size:11px;font-weight:400;color:var(--muted);white-space:nowrap;cursor:pointer"
      title="체크하면 이미 송금완료한 건도 엑셀에 함께 담습니다"><input type="checkbox" id="${id}"
      ${_payoutExportIncludePaid ? 'checked' : ''} onchange="setPayoutExportIncludePaid(this.checked)"
      style="vertical-align:-2px"> 송금완료 포함</label>`;
}

// 「이전 회차 미지급 포함」 체크박스 — 「송금완료 포함」과 같은 방식(두 화면이 한 변수를 본다).
function payoutExportIncludeEarlierHtml(id) {
  return `<label style="font-size:11px;font-weight:400;color:var(--muted);white-space:nowrap;cursor:pointer;margin-left:8px"
      title="밀린 이전 회차의 미지급 건을 함께 담아, 사람별 합계가 한 번에 보낼 금액이 되게 합니다. ${PAYOUT_CARRYOVER_FROM} 회차부터만 합칩니다(그 전 회차는 지급대장 대조 전이라 이중 송금 위험)"><input type="checkbox" id="${id}"
      ${_payoutExportIncludeEarlier ? 'checked' : ''} onchange="setPayoutExportIncludeEarlier(this.checked)"
      style="vertical-align:-2px"> 이전 회차 미지급 포함</label>`;
}

// 구역 머리 + 그 구역의 회차들. ⚠️ **표 하나 안**에 넣는다 — 구역마다 표를 따로 만들면
//    열 너비가 제각각이라 좌우가 안 맞는다(그게 표로 바꾼 이유다).
function payoutSectionHtml(title, color, dues, byDue, todayStr, emptyText) {
  const cnt = dues.reduce(function(a, d) { return a + byDue[d].length; }, 0);
  const sum = dues.reduce(function(a, d) {
    return a + byDue[d].reduce(function(b, r) { return b + r.amount; }, 0);
  }, 0);
  // 구역 머리 — 배경을 깔아 회차 줄과 확실히 구분한다.
  //   ⚠️ 색은 구역 색을 **아주 옅게** 깐다(원색을 깔면 회차 줄의 빨강·초록 숫자가 묻힌다).
  //   ⚠️ 왼쪽 색 막대는 뺐다(2026-08-18) — 배경만으로 충분히 구분되고, 막대가 있으면
  //      표의 첫 열 세로선과 겹쳐 줄이 어긋나 보였다.
  //   ⚠️ `background` 는 `td` 에 준다 — `tr` 에 주면 셀 배경(.data-table td 의 흰 배경)이
  //      위에 덮여 아무것도 안 보인다.
  const head = `<tr><td colspan="8" style="background:${color}14;padding:7px 12px;border-bottom:1px solid var(--outline)">
      <span style="font-weight:700;font-size:13px;color:${color}">${esc(title)}</span>
      ${dues.length ? `<span style="font-size:12px;color:var(--muted);margin-left:8px">${cnt}건 · ${esc(_payoutYen(sum))}</span>` : ''}
    </td></tr>`;
  const body = dues.length
    ? dues.map(function(d) { return payoutDueRowHtml(d, byDue[d], todayStr); }).join('')
    : `<tr><td colspan="8" style="color:var(--muted);font-size:12px">${esc(emptyText)}</td></tr>`;
  return head + body;
}

// 지급 예정일을 계산할 수 없는 건 — 인증 성공일이 없어서다.
//   ⚠️ 날짜가 없으니 회차로 못 나눈다. **한 줄로 묶어** 다른 구역과 같은 표 안에 둔다 —
//      표 밖에 두면 그것만 다른 물건처럼 보이고, 아예 안 두면 **어디에도 안 보인다.**
//   ⚠️ **내역이 있을 때만 그린다**(2026-08-18 사용자 결정). 늘 「0건」이 떠 있으면
//      「원래 있는 줄」로 학습돼, 정작 생겼을 때 눈에 안 들어온다.
function payoutNoDueSectionHtml(rows) {
  if (!rows.length) return '';
  const color = '#B8741A';
  const sent   = rows.filter(function(r) { return r.status === 'paid'; });
  const unsent = rows.filter(_payoutUnsent);
  const cell = (n, amt, c) => n
    ? `<div style="font-weight:600;color:${c}">${n}건</div><div style="font-size:11px;color:${c}">${esc(_payoutYen(amt))}</div>`
    : '<span style="color:var(--muted);opacity:.5">—</span>';
  const head = `<tr><td colspan="8" style="background:${color}14;padding:7px 12px;border-bottom:1px solid var(--outline)">
      <span style="font-weight:700;font-size:13px;color:${color}">지급일 기록 없음</span>
      <span style="font-size:12px;color:var(--muted);margin-left:8px">인증 성공일이 없어 지급 예정일을 계산할 수 없는 건</span>
    </td></tr>`;
  return head + `<tr>
    <td></td>
    <td style="font-weight:700;white-space:nowrap;color:var(--muted)">기록 없음</td>
    <td style="text-align:right;white-space:nowrap">${rows.length}건</td>
    <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(_payoutYen(_payoutSum(rows)))}</td>
    <td style="text-align:right;white-space:nowrap">${cell(sent.length, _payoutSum(sent), '#16A34A')}</td>
    <td style="text-align:right;white-space:nowrap">${cell(unsent.length, _payoutSum(unsent), '#C33')}</td>
    <td style="white-space:nowrap;color:var(--muted)">—</td>
    <td><button class="btn btn-ghost btn-xs" style="padding:2px 10px"
        onclick="openPayoutPersonList('${PAYOUT_NO_DUE}')">상세</button></td>
  </tr>`;
}

function renderPayoutSummary() {
  const body = $('payoutSummaryBody');
  if (!body) return;
  _payoutSubView = 'summary';
  refreshSettlementNav();
  const rows = _payoutRows || [];
  const todayStr = jstTodayStr();
  const thisMonth = todayStr.slice(0, 7);

  // 지급 예정일로 묶는다 — ★ **보낸 것까지 전부** 넣는다.
  //   ⚠️ 예전에는 안 보낸 것만 넣어, 회차 옆 숫자가 「그 날 보내야 할 전체」가 아니라
  //      「아직 안 보낸 것」이었다. 절반을 보내면 숫자가 줄어들어, **그 회차가 원래 몇 건이었는지**
  //      화면 어디에서도 알 수 없었다. 이제 전체를 보여주고 그 안에서 보냄·미지급을 가른다.
  const byDue = {};
  rows.filter(function(r) { return r.due; })
      .forEach(function(r) { (byDue[r.due] = byDue[r.due] || []).push(r); });
  const dues = Object.keys(byDue).sort();

  const thisM = dues.filter(function(d) { return _payoutMonthOf(d) === thisMonth; });
  // ⚠️ 밀린 것은 **최근 회차가 위**로 온다(내림차순). 다른 두 구역은 「곧 올 것」을 먼저
  //    보는 게 맞아 오름차순이지만, 밀린 것은 **가장 최근에 놓친 회차**부터 처리하게 된다.
  //    ('YYYY-MM-DD' 는 사전순 = 시간순이라 문자열 그대로 뒤집으면 된다)
  const before = dues.filter(function(d) { return _payoutMonthOf(d) < thisMonth; }).slice().reverse();
  const after  = dues.filter(function(d) { return _payoutMonthOf(d) > thisMonth; });

  // 「지급 완료」 — ⚠️ 예정일 조건을 걸지 않는다. 걸면 미리 보낸 건·당일 보낸 건·
  //   예정일이 미래인 건이 화면에서 사라진다(사양서 §4-1).
  // ⚠️ 「지급일 기록 없음」 표시는 뺐다(2026-08-18 사용자 결정. 그 시점 운영 0건).
  //    그 건들은 **어느 구역에도 안 들어간다** — 인증 성공일이 없어 지급 예정일을 계산할 수
  //    없기 때문이다. 즉 지금은 생기면 **화면 어디에도 안 보인다.** 다시 보이게 하려면
  //    `rows.filter(r => !r.due)` 를 세어 **0건이 아닐 때만** 한 줄 띄우면 된다.

  // 표 상자 = admin-card > admin-table-wrap (다른 목록 페인과 같은 구조 — 스크롤은 표 안에서만).
  //   ★ 엑셀 옵션·다운로드는 표 **위 한 줄**에 둔다(2026-09-30 사용자 결정). 회차는 줄 앞 체크박스로 고른다.
  const pickable = dues.slice();   // 체크박스가 있는 회차(「지급일 기록 없음」 제외)
  _payoutRoundPick.forEach(function (d) { if (pickable.indexOf(d) < 0) _payoutRoundPick.delete(d); });
  const allPicked = pickable.length > 0 && pickable.every(function (d) { return _payoutRoundPick.has(d); });
  // 엑셀 옵션·다운로드는 **탭 줄 오른쪽**(settlementNavTools)에 둔다(2026-09-30 사용자 결정).
  const tools = $('settlementNavTools');
  if (tools) tools.innerHTML = payoutExportIncludePaidHtml('payoutExportIncludePaidSummary')
    + payoutExportIncludeEarlierHtml('payoutExportIncludeEarlierSummary')
    + payoutRoundPickDownloadBtnHtml();
  body.innerHTML =
    `<div class="admin-card" style="flex:1;min-height:0"><div class="admin-table-wrap"><table class="data-table" style="width:100%">
      <thead><tr>
        <th style="width:36px;text-align:center"><input type="checkbox" ${allPicked ? 'checked' : ''} ${pickable.length ? '' : 'disabled'}
            onchange="togglePayoutRoundPickAll(this.checked)" title="모든 회차 선택" style="margin:0;cursor:pointer"></th>
        <th style="width:120px">지급 예정(회차)</th>
        <th style="width:70px;text-align:right">건수</th>
        <th style="width:110px;text-align:right">금액</th>
        <th style="width:110px;text-align:right">지급 금액</th>
        <th style="width:110px;text-align:right">미지급</th>
        <!-- ★ 「기한」은 **미지급 바로 옆**이다. 기한이 말하는 대상이 미지급이기 때문 —
             「미지급 22건인데 지급 기한이 4일 지났다」로 읽혀야 한다(2026-08-19 사용자 지적).
             금액 옆에 있을 때는 그 회차 전체 금액에 걸린 말처럼 읽혔다.
             ⚠️ 열을 옮길 때는 **머리글·회차 줄·「지급일 기록 없음」 줄 셋을 함께** 옮긴다. -->
        <th style="width:150px">기한</th>
        <th style="width:90px"></th>
      </tr></thead>
      <tbody>`
  // 순서: 이번 달 → 정산 예정(다음 달 이후) → 지난 달 이전 — 시간 흐름대로 앞으로 볼 것을 먼저(2026-10-08 사용자 요청)
  + payoutSectionHtml(`이번 달 (${esc(thisMonth)})`, '#2563EB', thisM, byDue, todayStr, '이번 달 지급 예정이 없습니다.')
  + payoutSectionHtml('정산 예정', '#6B7280', after, byDue, todayStr, '앞으로 예정된 정산이 없습니다.')
  // ⚠️ 색은 **여섯 자리로** 적는다. 제목 배경을 색+투명도로 만드는데, 세 자리(#C33)에
  //    붙이면 없는 값이 되어 **그 구역만 배경이 안 깔린다**(2026-08-18 운영에서 확인).
  + payoutSectionHtml('지난 달 이전 — 밀린 것', '#CC3333', before, byDue, todayStr, '밀린 것이 없습니다.')
  + payoutNoDueSectionHtml(rows.filter(function(r) { return !r.due; }))
  // ⚠️ 달을 넘겨 보던 「지급 완료」 묶음은 없앴다(2026-08-18 사용자 결정) —
  //    회차 표의 **송금완료 열**이 같은 것을 회차별로 보여주므로 중복이다.
  + `</tbody></table></div></div>`;
}

// 「지급 완료」가 보여줄 달을 옮긴다. ⚠️ **과거·미래 양방향** — 과거만 되면
//   예정일이 미래인 지급 완료 건(4단계에서 등록할 115건)에 영영 못 닿는다.

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
// 「지급일 기록 없음」 묶음을 가리키는 표시자. 날짜가 아니라 **날짜가 없는 것**을 고른다.
const PAYOUT_NO_DUE = '__nodue__';
let _payoutSearchTokens = [];   // 검색어를 낱말로 쪼갠 것(순서·공백 무관 비교용)
let _payoutPersonSearch = '';
// 「사람별」(전 기간 사람 목록) 기간 — **지급 예정일(회차 날짜)** 로 거른다(2026-10-01 사용자 결정).
//   '' = 전체 기간. ⚠️ 기간을 넣으면 지급일 기록이 없는 건(r.due 없음)은 빠진다.
let _payoutPeriodFrom = '';
let _payoutPeriodTo = '';
let _payoutPeriodFp = null;
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

// ══════════════════════════════════════════════════════════════════
// 지급 준비 — 회차 송금 명단 엑셀 (사양서 2026-09-29-payback-period-excel.md §3-A)
//
// ▶ 대상은 **그 회차 전체**다. 사람별 화면의 검색어·「회원별/캠페인별」 보기와 상관없다.
// ⚠️ 금액은 행의 `amount` 를 그대로 더한다. 지급 행에는 amount_jpy·paid_amount_jpy 칸이 없어서
//    `settlementEffectiveAmount` 를 다시 부르면 **0원**이 된다(그 함수 결과가 이미 `amount` 다).
// ⚠️ 회차는 행의 `due` 를 그대로 쓴다. payoutDueDate 를 다시 부르지 않는다(계산처는 하나).
// ══════════════════════════════════════════════════════════════════

// 이 날짜까지의 회차는 지급대장 대조 전이라 「이미 보낸 건이 미지급으로 보일 수 있다」.
const PAYOUT_LEDGER_WARN_UNTIL = '2026-09-30';
// 「송금완료 포함」 체크 상태 — 요약·사람별 두 체크박스가 함께 쓴다. 지급 준비에 들어올 때 끈다.
let _payoutExportIncludePaid = false;
// 「이전 회차 미지급 포함」 — 밀린 건을 다음 회차 송금에 합칠 때 사람별 합계가 실제 송금액이 되게.
//   🔴 합치는 범위의 아래 끝(사양서 D-6, 사용자 결정 2026-09-30). 그 전 회차 미지급(6~9월 약 486건)은
//      대부분 운영 시트로 이미 보냈는데 기록이 없는 건이라, 넣으면 **이중 송금**이 된다.
//      정산 3단계(시트 반영) 뒤 「송금 기록 없는 건」이 정리되기 전에는 이 값을 앞당기지 않는다.
const PAYOUT_CARRYOVER_FROM = '2026-10-15';
let _payoutExportIncludeEarlier = true;
const PAYOUT_EXCEL_STATUS_KO = { unregistered: '미등록', pending: '정산대기', paid: '송금완료' };

function setPayoutExportIncludePaid(checked) { _payoutExportIncludePaid = !!checked; }
function setPayoutExportIncludeEarlier(checked) { _payoutExportIncludeEarlier = !!checked; }

// 한 사람 묶음의 이름·이메일·페이팔 칸. 조회 실패(_payoutPersonInfo === null)는 「확인 실패」로.
function _payoutExcelPersonCells(list) {
  const first = list[0] || {};
  const failed = _payoutPersonInfo === null;
  const info = (!failed && _payoutPersonInfo[first.influencerId]) || null;
  const pick = function(key) { const r = list.find(function(x) { return x[key]; }); return r ? r[key] : null; };
  const name = pick('name') || (info && info.name) || (failed ? '확인 실패' : '(이름 미상)');
  const kana = pick('nameKana') || (info && info.name_kana) || '';
  // ⚠️ 정산 행 스냅샷을 먼저 쓴다(그 주소로 송금 기록이 남는다). 현재 값과 다르면 「확인 필요」.
  //    groupSettlementsByPerson 의 person.paypal 은 첫 행 기준이라 여기선 묶음을 직접 훑는다.
  const snap = pick('paypalEmail');
  const cur = info && info.paypal_email;
  let paypal;
  if (snap) paypal = (cur && cur !== snap) ? snap + ' (확인 필요)' : snap;
  else if (cur) paypal = cur;
  else paypal = failed ? '확인 실패' : '미등록';
  return { name: name, kana: kana, email: pick('email') || '', paypal: paypal };
}

// 브랜드가 빈 행(미등록 건)을 캠페인 목록에서 채운다. 캠페인 목록을 못 받으면 「확인 실패」.
//   ⚠️ 행 객체에 직접 쓰지 않고 캠페인 id → 브랜드 표를 돌려준다(지급 준비 화면 행을 건드리지 않게).
async function _payoutBrandMap(rows) {
  const need = rows.some(function(r) { return !r.brand && r.campaignId; });
  if (!need) return {};
  let camps = (typeof allCampaigns !== 'undefined' && allCampaigns && allCampaigns.length) ? allCampaigns : null;
  if (!camps) { try { camps = await fetchCampaigns(); } catch (e) { camps = null; } }
  // 빈 배열·배열 아닌 값도 「못 받음」 — 조용히 전부 빈칸이 되지 않게
  if (!Array.isArray(camps) || !camps.length) return null;
  const map = {};
  camps.forEach(function(c) { map[c.id] = brandLabelAdmin(c); });
  return map;
}
function _payoutBrandOf(r, brandMap) {
  if (r.brand) return r.brand;
  if (brandMap === null) return '확인 실패';
  if (!r.campaignId) return '';
  // 목록에 없는 캠페인(보관 삭제 등)은 「브랜드 없음」과 가르려고 따로 적는다
  if (!(r.campaignId in brandMap)) return '(캠페인 목록에 없음)';
  return brandMap[r.campaignId] || '';
}

function _payoutExcelSaveWorkbook(wb, fileName) {
  return wb.xlsx.writeBuffer().then(function(buf) {
    const blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    const url = URL.createObjectURL(blob);
    const aEl = document.createElement('a');
    aEl.href = url;
    aEl.download = fileName;
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
  });
}

// 시트 1 「회차 합계」 — 머리 줄 → 빈 줄 → 표. ⚠️ columns 에 header 를 주면 1행이 머리글로
//   박혀 머리 줄을 위에 둘 수 없다. 그래서 너비만 columns 로 정하고 머리글 행은 직접 넣는다.
function _payoutExcelSummarySheet(wb, due, roundAll, rows, opts) {
  const ws = wb.addWorksheet('회차 합계');
  ws.columns = [14, 16, 26, 30, 8, 12, 8, 10, 12].map(function(w) { return { width: w }; });
  ws.addRow(['지급 예정(회차) ' + (opts.dueLabel || due) + ' · 회차 전체 ' + roundAll.length + '건 / 담은 것 ' + rows.length + '건('
    + (opts.includePaid ? '송금완료 포함' : '미지급만') + ') · 내려받은 시각 ' + formatDateTime(new Date())]).font = { bold: true };
  if (opts.includeEarlier) {
    ws.addRow([opts.carryCount
      ? '이전 회차 미지급 ' + opts.carryCount + '건 포함(' + PAYOUT_CARRYOVER_FROM + ' 회차부터) — 사람별 「미지급」 합계가 한 번에 보낼 금액'
      : '이전 회차 미지급 없음(합치는 범위: ' + PAYOUT_CARRYOVER_FROM + ' 회차부터)']);
  }
  if ((opts.firstDue || due) <= PAYOUT_LEDGER_WARN_UNTIL) {   // 여러 회차면 가장 이른 회차로 판정
    ws.addRow(['⚠️ 지급대장 대조 전 — 이미 보낸 건이 미지급으로 보일 수 있습니다']).font = { color: { argb: 'FFCC3333' } };
  }
  ws.addRow([]);
  ws.addRow(['이름(한자)', '후리가나', '이메일', '페이팔', '건수', '합계', '미확정', '상태', '이전 회차 포함']).font = { bold: true };
  const byPerson = groupSettlementsByPerson(rows);
  Object.keys(byPerson).forEach(function(id) {
    const entry = byPerson[id];
    // 미지급은 **여러 회차(이 회차 + 합친 이전 회차)를 한 줄로** — 한 번에 보낼 금액이다.
    //   포함 모드면 송금완료가 따로 한 줄 더 생긴다 — 합치지 않는다.
    const unpaid = Object.keys(entry.dues).reduce(function(a, d) { return a.concat(entry.dues[d]); }, []);
    const groups = [];
    if (unpaid.length) groups.push({ list: unpaid, label: '미지급' });
    if (entry.paid.length) groups.push({ list: entry.paid, label: '송금완료' });
    groups.forEach(function(g) {
      const p = _payoutExcelPersonCells(g.list);
      const unknown = g.list.filter(function(r) { return r.amountUnknown; }).length;
      const known = g.list.filter(function(r) { return !r.amountUnknown; });
      const earlier = g.list.filter(function(r) { return r.due && r.due < due; }).length;
      ws.addRow([p.name, p.kana, p.email, p.paypal, g.list.length, _payoutSum(known), unknown || '', g.label, earlier || '']);
    });
  });
}

// 시트 2 「건별」
function _payoutExcelItemSheet(wb, rows, brandMap) {
  const ws = wb.addWorksheet('건별');
  ws.columns = [
    { header: '이름(한자)', width: 14 }, { header: '후리가나', width: 16 },
    { header: '캠페인 번호', width: 16 }, { header: '캠페인', width: 28 }, { header: '브랜드', width: 18 },
    { header: '모집 형식', width: 10 }, { header: '인증 성공일', width: 12 },
    { header: '지급 예정(회차)', width: 14 }, { header: '금액', width: 10 },
    { header: '미확정', width: 8 }, { header: '상태', width: 10 },
    { header: '송금일', width: 18 }, { header: '페이팔', width: 30 },
  ];
  ws.getRow(1).font = { bold: true };
  rows.forEach(function(r) {
    const p = _payoutExcelPersonCells([r]);
    const paid = r.paidAt ? formatDate(r.paidAt) + (r.recordDateOnly ? ' (기록일)' : '') : '';
    ws.addRow([p.name, p.kana, r.campaignNo || '', r.campaignTitle || '', _payoutBrandOf(r, brandMap),
      PAST_UNREG_TYPE_LABELS[r.recruitType] || r.recruitType || '',
      r.certAt ? formatDate(r.certAt) : '', r.due || '',
      // ⚠️ 미확정은 빈칸 — 「¥0」으로 적으면 0원을 보내라는 뜻이 된다
      r.amountUnknown ? '' : r.amount, r.amountUnknown ? 'O' : '',
      PAYOUT_EXCEL_STATUS_KO[r.status] || r.status || '', paid, p.paypal]);
  });
}

// dueArg = 회차 하나('YYYY-MM-DD') 또는 여럿(배열). 여럿이면 **한 파일**에 담는다.
//   ⚠️ 「이전 회차 미지급」은 **고른 회차 중 가장 늦은 것**보다 앞선, 고르지 않은 회차의 미지급만 — 고른 회차를 두 번 담지 않는다.
async function exportPayoutRoundExcel(dueArg, opts) {
  const includePaid = !!(opts && opts.includePaid);
  const includeEarlier = !!(opts && opts.includeEarlier);
  // 미등록 조회 실패면 회차 자체를 믿을 수 없다 — 「보낼 게 없음」으로 내보내지 않는다.
  if (_payoutRows === null) { toast('미등록 건을 불러오지 못해 내보낼 수 없습니다', 'error'); return; }
  const dues = (Array.isArray(dueArg) ? dueArg : [dueArg]).filter(function (d) { return d && d !== PAYOUT_NO_DUE; }).sort();
  if (!dues.length) return;
  const due = dues[dues.length - 1];   // 가장 늦은 회차 — 「이전 회차」 판정의 기준
  const dueLabel = dues.join(', ');
  if (typeof _checkExportAllowed === 'function' && !_checkExportAllowed()) return;
  const roundAll = _payoutRows.filter(function(r) { return dues.indexOf(r.due) >= 0; });
  // 밀린 이전 회차 미지급 — 범위의 아래 끝(PAYOUT_CARRYOVER_FROM)을 반드시 지킨다. 문자열 비교('YYYY-MM-DD').
  const carry = includeEarlier
    ? _payoutRows.filter(function(r) { return _payoutUnsent(r) && r.due && r.due >= PAYOUT_CARRYOVER_FROM && r.due < due && dues.indexOf(r.due) < 0; })
    : [];
  const rows = carry.concat(includePaid ? roundAll : roundAll.filter(_payoutUnsent));
  if (!rows.length) { toast('내보낼 건이 없습니다', 'warn'); return; }
  if (typeof _markExportStart === 'function') _markExportStart();
  try {
    // 요약에서 바로 누르면 사람 정보가 아직 없다(정산 행 이름·미등록 행 페이팔이 빈다).
    if (_payoutPersonInfo === undefined || _payoutPersonInfo === null) await ensurePayoutPersonInfo();
    await loadExcelJS();
    const wb = new ExcelJS.Workbook();
    _payoutExcelSummarySheet(wb, due, roundAll, rows, { includePaid: includePaid, includeEarlier: includeEarlier, carryCount: carry.length, dueLabel: dueLabel, firstDue: dues[0] });
    _payoutExcelItemSheet(wb, rows, await _payoutBrandMap(rows));
    const ts = new Date();
    const ymd = ts.getFullYear() + String(ts.getMonth() + 1).padStart(2, '0') + String(ts.getDate()).padStart(2, '0');
    await _payoutExcelSaveWorkbook(wb, 'payout-' + (dues.length > 1 ? dues[0] + '_to_' + due + '-' + dues.length + 'rounds' : due) + '-' + (includePaid ? 'all' : 'unpaid') + (carry.length ? '-prev' + carry.length : '') + '-' + rows.length + '-' + ymd + '.xlsx');
    toast('엑셀 다운로드 완료 (' + rows.length + '건)');
  } catch (e) {
    toast('엑셀 생성 실패: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || e)), 'error');
  } finally {
    if (typeof _markExportEnd === 'function') _markExportEnd();
  }
}

function payoutPaypalHtml(p) {
  if (p.paypal) return `<span style="font-size:11px;color:var(--muted);font-family:monospace">${esc(p.paypal)}</span>`;
  if (p.paypalUnknown) return '<span style="font-size:11px;color:#B8741A">페이팔 확인 실패</span>';
  return '<span style="font-size:11px;color:#C33">페이팔 미등록</span>';
}

// ─── 사람별 — 표(사람 1명 = 1줄, 펼치면 세부 내역) ─────────────────────────
//   송금 내역 「전체」와 같은 보기 방식(2026-09-30 사용자 결정 — 카드를 다 펼쳐 두면 사람이 많을 때 훑기 어렵다).
//   ★ 줄 체크박스 = **그 사람의 미지급 전부**(지금 보이는 범위 — 회차 상세면 그 회차만). 선택 열쇠말은 종전대로
//      `사람id|회차` 라서 「선택한 건 보냄」·합계는 그대로 동작한다. 회차를 나눠 보낼 때는 펼친 내역의 「회차 보냄」.
//   ⚠️ 날짜 칸 제목이 없으면 무슨 날짜인지 모른다(2026-08-18 지적) — 펼친 격자에도 칸 제목을 단다.
const _payoutPersonOpen = new Set();   // 펼친 사람 id
let _payoutPersonKeyMap = {};          // 사람 id → 그 사람의 선택 열쇠말(사람id|회차) 목록
// 열 순서는 캠페인별 펼침(_PAYOUT_CAMP_ITEM_COLS)과 같다 — … · 인증 성공일 · 지급 예정(회차) · 송금일 · 금액 · 상태(2026-10-01 사용자 결정)
const _PAYOUT_ITEM_COLS = 'display:grid;grid-template-columns:minmax(0,1fr) 100px 100px 100px 90px 250px;column-gap:12px;align-items:center;padding:6px 12px';

function _payoutPersonKeys(entry) {
  return Object.keys(entry.dues).map(function (d) { return entry.person.id + '|' + d; });
}

function togglePayoutPersonOpen(id) {
  if (_payoutPersonOpen.has(id)) _payoutPersonOpen.delete(id); else _payoutPersonOpen.add(id);
  renderPayoutPersonBody();
}
// 줄 체크박스 — 그 사람의 (보이는 범위) 미지급 회차를 전부 고르거나 전부 푼다.
function togglePayoutPersonSelect(id, on) {
  (_payoutPersonKeyMap[id] || []).forEach(function (k) { if (on) _payoutSelected.add(k); else _payoutSelected.delete(k); });
  renderPayoutPersonBody();
}

// 펼친 세부 격자 한 줄
function _payoutItemRowHtml(r, sent, showDue) {
  const camp = esc(r.campaignNo ? '[' + r.campaignNo + '] ' : '') + esc(r.campaignTitle || '(캠페인 미상)');
  const state = sent
    ? '<span style="font-size:10px;background:#E8F5E9;color:#16A34A;font-weight:700;padding:1px 6px;border-radius:3px;white-space:nowrap">지급 완료</span>' + _payoutPaidActionsHtml(r)
    : (r.applicationId
        ? `<button class="btn btn-ghost btn-xs" style="padding:1px 8px;font-size:11px;white-space:nowrap"
             onclick="openPayoutSendOneModal('${esc(r.applicationId)}')" title="이 건만 송금완료로 기록">보냄</button>`
        : '');
  return `<div style="${_PAYOUT_ITEM_COLS};font-size:12px;border-top:1px solid var(--line)${sent ? ';color:var(--muted)' : ''}">
    <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${camp}">${camp}</div>
    <div style="white-space:nowrap" title="결과물 최종 승인(인증 성공)일">${r.certAt ? esc(formatDate(r.certAt)) : _missingDash(_MISSING_CERT_TIP)}</div>
    <div style="white-space:nowrap">${showDue ? (r.due ? esc(r.due) : _missingDash(_MISSING_CERT_TIP)) : ''}</div>
    <div style="white-space:nowrap" title="실제로 송금한 날(기록된 값)">${sent && r.paidAt ? esc(formatDate(r.paidAt)) : '—'}</div>
    <div style="text-align:right;white-space:nowrap">${sent ? esc(_payoutYen(r.amount)) : _payoutAmountCell(r)}</div>
    <div style="white-space:nowrap">${state}</div>
  </div>`;
}

// 펼친 내용 — 미지급 → 이미 기록됨.
//   회차 머리 줄(「이 회차 N건 · 회차 보냄」)은 **회차가 둘 이상이고 그 회차에 2건 이상**일 때만 단다.
//   1건뿐인 회차에 달면 머리 줄과 건 줄이 같은 금액·같은 「보냄」을 두 번 말한다(2026-09-30). 그때는 건 줄에 회차를 적는다.
function _payoutPersonDetailHtml(entry) {
  const p = entry.person;
  const dues = Object.keys(entry.dues).sort();
  let html = `<div style="${_PAYOUT_ITEM_COLS};font-size:11px;font-weight:600;color:var(--muted);background:#F1F1F3">
      <div>캠페인</div><div>인증 성공일</div><div>지급 예정(회차)</div><div>송금일</div><div style="text-align:right">금액</div><div>상태</div>
    </div>`;
  dues.forEach(function (d) {
    const list = entry.dues[d];
    const groupHead = dues.length > 1 && list.length > 1;
    if (groupHead) {
      html += `<div style="${_PAYOUT_ITEM_COLS};font-size:12px;border-top:1px solid var(--line);background:#FAFAFA">
        <div style="color:var(--muted)">이 회차 ${list.length}건</div><div></div>
        <div style="font-weight:700;white-space:nowrap">${esc(d)}</div><div></div>
        <div style="text-align:right;font-weight:700;white-space:nowrap">${esc(_payoutYen(_payoutSum(list)))}</div>
        <div><button class="btn btn-ghost btn-xs" style="padding:1px 8px;font-size:11px;white-space:nowrap"
             onclick="openPayoutSendModal('${esc(p.id + '|' + d)}')" title="이 사람의 이 회차를 송금완료로 기록">회차 보냄</button></div>
      </div>`;
    }
    list.forEach(function (r) { html += _payoutItemRowHtml(r, false, !groupHead); });
  });
  // 이미 기록된 건 — 건수·합계 머리 줄은 두지 않는다(사람 줄의 「지급 금액」 칸과 같은 말이라, 2026-09-30 사용자 결정).
  //   건 줄의 「기록됨」 표시와 흐린 글자로 갈린다.
  if (entry.paid.length) {
    entry.paid.slice().sort(function (a, b) { return String(a.due || '').localeCompare(String(b.due || '')); })
      .forEach(function (r) { html += _payoutItemRowHtml(r, true, true); });
  }
  return `<div style="background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden">${html}</div>`;
}

function _payoutPersonTableHtml(entries) {
  _payoutPersonKeyMap = {};
  entries.forEach(function (e) { _payoutPersonKeyMap[e.person.id] = _payoutPersonKeys(e); });
  const N = 'text-align:right;white-space:nowrap';
  const dash = '<span style="color:var(--muted);opacity:.5">—</span>';
  const rows = entries.map(function (e) {
    const p = e.person;
    const keys = _payoutPersonKeys(e);
    const picked = keys.filter(function (k) { return _payoutSelected.has(k); }).length;
    const unsent = Object.keys(e.dues).reduce(function (a, d) { return a.concat(e.dues[d]); }, []);
    const open = _payoutPersonOpen.has(p.id);
    return `<tr style="cursor:pointer" onclick="togglePayoutPersonOpen('${esc(p.id)}')">
        <td style="width:36px;text-align:center" onclick="event.stopPropagation()">${keys.length
          ? `<input type="checkbox" ${picked === keys.length ? 'checked' : ''}
               onchange="togglePayoutPersonSelect('${esc(p.id)}', this.checked)" title="이 사람의 미지급을 모두 고릅니다" style="margin:0;cursor:pointer">`
          // 지급이 다 끝난 사람 — 칸을 비우지 않고 **비활성 체크박스**로 둔다(줄마다 같은 자리에 같은 것이 보이게, 2026-09-30 사용자 결정)
          : `<input type="checkbox" disabled title="지급이 끝나 고를 미지급이 없습니다" style="margin:0;cursor:not-allowed">`}</td>
        <td style="width:28px"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">${open ? 'expand_less' : 'expand_more'}</span></td>
        <td style="font-weight:600;white-space:nowrap">${esc(p.name || '(이름 미상)')}</td>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${esc(p.kana || '')}</td>
        <td style="white-space:nowrap">${payoutPaypalHtml(p)}</td>
        <td style="${N}">${unsent.length ? unsent.length + '건' : dash}</td>
        <td style="${N};font-weight:700;color:#C33">${unsent.length ? esc(_payoutYen(_payoutSum(unsent))) + _payoutUnknownNote(unsent) : dash}</td>
        <td style="${N};color:#16A34A">${e.paid.length ? e.paid.length + '건 · ' + esc(_payoutYen(_payoutSum(e.paid))) : dash}</td>
        <td style="white-space:nowrap" onclick="event.stopPropagation()">${keys.length
          ? `<button class="btn btn-ghost btn-xs" style="padding:2px 10px" onclick="openPayoutSendPersonModal('${esc(p.id)}')"
               title="${keys.length === 1 ? '이 사람의 미지급을 송금완료로 기록합니다' : '이 사람의 모든 회차 미지급을 한 번에 송금완료로 기록합니다'}">보냄</button>`
          : ''}</td>
      </tr>${open ? `<tr><td colspan="9" style="background:#FAFAFA;padding:10px 16px 12px 16px">${_payoutPersonDetailHtml(e)}</td></tr>` : ''}`;
  }).join('');
  return `<table class="data-table" style="width:100%">
      <thead><tr>
        <th style="width:36px"></th><th style="width:28px"></th>
        <th style="width:140px">이름(한자)</th><th style="width:140px">후리가나</th><th>페이팔</th>
        <th style="width:70px;text-align:right">미지급</th><th style="width:120px;text-align:right">미지급 금액</th>
        <th style="width:150px;text-align:right" title="송금완료로 기록된 건수·금액">지급 금액</th><th style="width:70px"></th>
      </tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
}

// 건별 「보냄」 — 그 한 건만 송금완료로 기록한다.
//   ⚠️ 묶음 「보냄」과 **같은 창·같은 처리**를 쓴다(_bulkPayCtx). 처리 경로가 갈리면
//      한쪽만 고치게 된다 — 실제로 그 형태의 사고를 이 저장소가 여러 번 겪었다.
function openPayoutSendOneModal(appId) {
  const r = (_payoutRows || []).find(function (x) { return x.applicationId === appId && _payoutUnsent(x); });
  if (!r) { toast('이미 처리됐거나 대상을 찾을 수 없습니다', 'warn'); return; }
  if (r.amountUnknown) { toast('금액을 정할 수 없어 기록할 수 없습니다', 'warn'); return; }
  const person = payoutPersonOf(r);
  _bulkPayCtx = {
    settlementIds:  r.kind === 'settlement'   ? [r.settlementId]  : [],
    applicationIds: r.kind === 'unregistered' ? [r.applicationId] : [],
    items: [_bulkItemFromPayoutRow(r)],
    from: 'payout',
    summaryHtml: `
      <div style="padding:12px 14px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;margin-bottom:16px">
        <div style="font-size:13px;color:var(--muted);margin-bottom:6px">${esc(person.name || '(이름 미상)')} · ${esc(r.due || '(예정일 없음)')} 회차 · 1건</div>
        <div style="font-size:13px;margin-bottom:4px">${esc(r.campaignNo ? '[' + r.campaignNo + '] ' : '')}${esc(r.campaignTitle || '(캠페인 미상)')}</div>
        <div style="font-size:15px;font-weight:700;color:var(--ink)">${settlementAmountYen(r.amount)}</div>
        ${payoutPaypalHtml(person)}
      </div>`
  };
  _openBulkPayModal();
}

function togglePayoutSelect(key) {
  if (_payoutSelected.has(key)) _payoutSelected.delete(key); else _payoutSelected.add(key);
  renderPayoutPersonBody();   // 검색창·검색어를 유지한 채 목록만 갱신
}

// 「보냄」 — 한 사람의 한 회차를 통째로 송금완료로 기록한다.
//   ⚠️ **그 묶음에는 두 종류가 섞여 있다.** 정산 행이 이미 있는 건(정산대기)과, 아직
//      정산 행조차 없는 건(미등록)이다. 서버 함수가 서로 다르므로 둘로 나눠 부른다.
//      한쪽만 부르면 **보냈다고 눌렀는데 절반만 기록되고** 나머지는 조용히 남는다.
//   ⚠️ 금액을 정할 수 없는 건(amount_issue)은 **빼고 건수를 알린다.** 서버도 건너뛰므로
//      안 빼면 「고른 수보다 적게 처리됐다」가 된다.
function openPayoutSendModal(key) {
  const cut = String(key).indexOf('|');
  const personId = String(key).slice(0, cut);
  const due = String(key).slice(cut + 1);
  const rows = (_payoutRows || []).filter(function (r) {
    return r.influencerId === personId
        && (r.due || '(지급일 기록 없음)') === due
        && _payoutUnsent(r);
  });
  if (!rows.length) { toast('보낼 건이 없습니다', 'warn'); return; }

  const usable = rows.filter(function (r) { return !r.amountUnknown; });
  const unknown = rows.length - usable.length;
  if (!usable.length) { toast('금액을 정할 수 없는 건뿐이라 기록할 수 없습니다', 'warn'); return; }

  const person = payoutPersonOf(rows[0]);
  _bulkPayCtx = {
    settlementIds:  usable.filter(function (r) { return r.kind === 'settlement';   }).map(function (r) { return r.settlementId; }),
    applicationIds: usable.filter(function (r) { return r.kind === 'unregistered'; }).map(function (r) { return r.applicationId; }),
    items: usable.map(_bulkItemFromPayoutRow),
    from: 'payout',
    summaryHtml: `
      <div style="padding:12px 14px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;margin-bottom:16px">
        <div style="font-size:13px;color:var(--muted);margin-bottom:6px">${esc(person.name || '(이름 미상)')} · ${esc(due)} 회차</div>
        <div style="font-size:15px;font-weight:700;color:var(--ink)">${usable.length}건 · 합계 ${settlementAmountYen(_payoutSum(usable))}</div>
        ${unknown ? `<div style="font-size:12px;color:#C33;margin-top:6px">금액을 정할 수 없는 ${unknown}건은 빠집니다.</div>` : ''}
        ${payoutPaypalHtml(person)}
      </div>`
  };
  _openBulkPayModal();
}

// 사람 줄 「보냄」 — 그 사람의 (보이는 범위) 미지급 회차 전부를 한 번에. 선택 열쇠말을 잠시 그 사람 것만으로 바꿔
//   「선택한 건 보냄」과 **같은 창·같은 처리**를 태운다(처리 경로를 새로 만들지 않는다). 창을 연 뒤 원래 선택으로 되돌린다.
//   ⚠️ 창은 열 때 대상을 _bulkPayCtx 에 복사해 두므로, 선택을 되돌려도 창의 대상은 바뀌지 않는다.
function openPayoutSendPersonModal(id) {
  const keys = _payoutPersonKeyMap[id] || [];
  if (!keys.length) { toast('보낼 건이 없습니다', 'warn'); return; }
  if (keys.length === 1) { openPayoutSendModal(keys[0]); return; }
  const saved = new Set(_payoutSelected);
  _payoutSelected.clear();
  keys.forEach(function (k) { _payoutSelected.add(k); });
  try { openPayoutSendSelectedModal(); }
  finally { _payoutSelected.clear(); saved.forEach(function (k) { _payoutSelected.add(k); }); }
}

// 「선택한 건 보냄」 — 체크한 묶음 전부를 한 번에 송금완료로 기록한다.
//   ★ 왜 필요한가 — 실제 송금이 **여러 건을 합해 한 번에** 나간다(이체 수수료 때문).
//      선택 합계로 지급대장 한 줄과 금액을 맞춰 놓고도, 기록은 다시 하나씩 눌러야 했다.
//   ⚠️ 처리는 묶음 「보냄」과 **같은 창·같은 함수**를 쓴다(`_bulkPayCtx`). 경로가 갈리면
//      한쪽만 고치게 된다 — 이 저장소가 여러 번 겪은 사고 형태다.
//   ⚠️ **여러 사람이 섞일 수 있다.** 페이팔은 사람마다 다르므로 요약에 사람 수를 밝히고,
//      페이팔이 없는 사람은 **서버가 건너뛰므로**(마이그레이션 324) 미리 이름으로 알린다.
//   ⚠️ 선택 열쇠말은 `사람id|회차` 이고, 회차가 없는 건은 `(지급일 기록 없음)` 이다 —
//      `groupSettlementsByPerson` 이 그렇게 묶는다. **그 규칙과 어긋나면 고른 것과 다른
//      건이 처리된다.** 묶음 「보냄」(openPayoutSendModal)과 같은 식을 쓴다.
//   ⚠️ 체크박스는 **회원별 보기에만** 있다. 캠페인별 보기로 바꿔도 선택은 그대로 남으므로
//      이 버튼도 선택이 있는 한 그대로 동작한다(고른 것을 잃지 않는다).
function openPayoutSendSelectedModal() {
  if (!_payoutSelected.size) { toast('먼저 보낼 묶음을 선택해 주세요', 'warn'); return; }
  const rows = (_payoutRows || []).filter(function (r) {
    // ⚠️ 사람 쪽은 **폴백을 두지 않는다.** 체크박스가 심는 열쇠말은 `payoutPersonOf(r).id`
    //    = `r.influencerId` 그대로다. 여기서만 '(미상)' 으로 바꾸면 두 열쇠말이 어긋난다.
    return _payoutUnsent(r)
        && _payoutSelected.has(r.influencerId + '|' + (r.due || '(지급일 기록 없음)'));
  });
  if (!rows.length) { toast('보낼 건이 없습니다 — 고른 것이 이미 처리됐을 수 있습니다', 'warn'); return; }

  const usable = rows.filter(function (r) { return !r.amountUnknown; });
  const unknown = rows.length - usable.length;
  if (!usable.length) { toast('금액을 정할 수 없는 건뿐이라 기록할 수 없습니다', 'warn'); return; }

  // 사람별로 묶어 보여 준다 — 대장과 맞추는 자리라 「누구에게 얼마」가 보여야 한다.
  const byPerson = {};
  usable.forEach(function (r) {
    const id = r.influencerId || '(미상)';
    if (!byPerson[id]) byPerson[id] = { person: payoutPersonOf(r), rows: [] };
    if (!byPerson[id].person.name) byPerson[id].person = payoutPersonOf(r);
    byPerson[id].rows.push(r);
  });
  const people = Object.keys(byPerson).map(function (id) { return byPerson[id]; });
  const noPaypal = people.filter(function (e) { return !e.person.paypal && !e.person.paypalUnknown; });
  const unsurePaypal = people.filter(function (e) { return e.person.paypalUnknown; });

  const lines = people.map(function (e) {
    return `<div style="display:flex;align-items:center;gap:8px;font-size:12px;padding:3px 0">
        <span style="font-weight:600">${esc(e.person.name || '(이름 미상)')}</span>
        ${payoutPaypalHtml(e.person)}
        <span style="margin-left:auto">${e.rows.length}건 · <b>${esc(_payoutYen(_payoutSum(e.rows)))}</b></span>
      </div>`;
  }).join('');

  _bulkPayCtx = {
    settlementIds:  usable.filter(function (r) { return r.kind === 'settlement';   }).map(function (r) { return r.settlementId; }),
    applicationIds: usable.filter(function (r) { return r.kind === 'unregistered'; }).map(function (r) { return r.applicationId; }),
    items: usable.map(_bulkItemFromPayoutRow),
    from: 'payout',
    summaryHtml: `
      <div style="padding:12px 14px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;margin-bottom:16px">
        <div style="font-size:13px;color:var(--muted);margin-bottom:6px">선택한 ${_payoutSelected.size}묶음</div>
        <div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:8px">${people.length}명 · ${usable.length}건 · 합계 ${settlementAmountYen(_payoutSum(usable))}</div>
        <div style="border-top:1px solid var(--line);padding-top:6px;max-height:220px;overflow:auto">${lines}</div>
        ${unknown ? `<div style="font-size:12px;color:#C33;margin-top:8px">금액을 정할 수 없는 ${unknown}건은 빠집니다.</div>` : ''}
        ${noPaypal.length ? `<div style="font-size:12px;color:#C33;margin-top:6px">페이팔이 없는 ${noPaypal.length}명(${esc(noPaypal.map(function(e){return e.person.name || '(이름 미상)';}).join(' · '))})은 <b>기록되지 않고 건너뜁니다</b>.</div>` : ''}
        ${unsurePaypal.length ? `<div style="font-size:12px;color:#B8741A;margin-top:6px">페이팔을 확인하지 못한 ${unsurePaypal.length}명이 있습니다 — 그 사람은 건너뛸 수 있습니다.</div>` : ''}
      </div>`
  };
  _openBulkPayModal();
}

async function openPayoutPersonList(dueStr) {
  _payoutDueFilter = dueStr || null;
  _payoutSubView = 'person';
  refreshSettlementNav();
  _payoutSelected.clear();
  const body = $('payoutSummaryBody');
  if (body) body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';
  if (_payoutPersonInfo === undefined || _payoutPersonInfo === null) await ensurePayoutPersonInfo();
  renderPayoutPersonList();
}

function backToPayoutSummary() {
  _payoutDueFilter = null;
  _payoutPersonSearch = '';
  _payoutSearchTokens = [];   // [B-10] 검색어 낱말도 비운다 — 안 비우면 빈 화면이 「찾는 중…」으로 남는다
  _payoutSelected.clear();
  renderPayoutSummary();
}

// 검색어를 **낱말로 쪼갠다.** 이름은 저장 방식이 제각각이라 글자를 그대로 이어 찾으면
//   놓치는 경우가 많다 — 실제 데이터에 「田中　敬子」처럼 **전각 공백**으로 저장된 이름이 있고,
//   사람은 「敬子 田中」처럼 순서를 바꿔 치기도 한다. 둘 다 지금 방식으로는 못 찾는다.
//   ⚠️ 그래서 ①공백(전각·반각 모두)을 없애 견주고 ②낱말이 여럿이면 **전부 들어 있는지**를
//      본다(순서 무관). 낱말 하나짜리 검색은 종전과 똑같이 동작한다.
function _payoutNorm(v) {
  return String(v || '').toLowerCase().replace(/[\s\u3000]+/g, '');
}
function payoutSearchHit(fields, tokens) {
  if (!tokens.length) return true;
  const hay = fields.filter(Boolean).map(_payoutNorm).join(' ');
  return tokens.every(function (t) { return hay.includes(t); });
}

// 일괄 등록(register_past_settlements, 339)이 **어느 건수에도 안 넣은** 응모 수.
//   서버는 후보(인증 성공 + 정산 행 없음)에 있는 것만 세므로, 고른 응모 중 후보 밖은 조용히 빠진다.
//   ⚠️ 같은 응모를 두 번 고른 경우를 대비해 고유 개수로 센다.
function _payoutUnaccounted(applicationIds, r) {
  const asked = new Set((applicationIds || []).filter(Boolean)).size;
  const seen = (Number(r && r.registered) || 0) + (Number(r && r.skippedNoPaypal) || 0);
  return Math.max(asked - seen, 0);
}

function onPayoutPersonSearch(v) {
  _payoutPersonSearch = (v || '').trim().toLowerCase();
  _payoutSearchTokens = (v || '').trim().split(/[\s\u3000]+/).filter(Boolean).map(_payoutNorm);
  // ⚠️ 검색으로 **화면에서 사라진 선택은 버린다**(전수조사 B-2) — 정산 목록(527행 근처)·미등록
  //    화면이 이미 그렇게 한다. 안 보이는 사람의 묶음이 「선택한 건 보냄」에 그대로 실려
  //    확인창에는 걸러진 요약만 뜨고 실제 처리는 전체에서 고르던 어긋남을 막는다.
  _payoutPruneHiddenSelection();
  renderPayoutPersonBody();   // ⚠️ 껍데기를 다시 그리면 검색창 포커스가 날아간다
}
// 검색·기간으로 화면에서 사라진 선택을 버린다 — 둘 다 같은 이유(위 B-2)라 한 곳에서 한다.
function _payoutPruneHiddenSelection() {
  const periodOn = !_payoutDueFilter && _payoutPeriodFrom && _payoutPeriodTo;
  if (!_payoutSelected.size || !(_payoutSearchTokens.length || periodOn)) return;
  const byPerson = groupSettlementsByPerson((_payoutRows || []).filter(_payoutInPeriod));
  const visible = new Set();
  Object.keys(byPerson).forEach(function (k) {
    const e = byPerson[k];
    if (!payoutSearchHit([e.person.name, e.person.kana, e.person.paypal], _payoutSearchTokens)) return;
    Object.keys(e.dues).forEach(function (d) { visible.add(e.person.id + '|' + d); });
  });
  _payoutSelected.forEach(function (key) { if (!visible.has(key)) _payoutSelected.delete(key); });
}

// 껍데기(뒤로가기·제목·검색창)는 **한 번만** 그린다.
//   ⚠️ 검색창을 목록과 함께 다시 그리면 **한 글자 칠 때마다 포커스를 잃는다** —
//      입력칸이 통째로 새 노드로 바뀌기 때문이다. 「사람으로 빨리 찾기」가 이 작업의
//      존재 이유(487번 → 121번)인데 그러면 한 글자마다 다시 클릭해야 한다.
//      관리자 메시지 화면(admin-messaging.js)이 같은 이유로 검색창을 바깥에 둔다.
// 지급 상세를 **회원별 / 캠페인별** 어느 쪽으로 묶어 볼지.
//   ⚠️ 실제 송금은 **사람에게** 하므로 「보냄」과 선택은 회원별에서만 뜻이 있다.
//      캠페인별은 **보기 전용**이다 — 한 사람이 여러 캠페인에 걸쳐 있어, 캠페인 쪽에서
//      고르면 「이 사람에게 얼마를 보내나」가 갈라져 오히려 금액을 틀리게 만든다.
let _payoutGroupBy = 'person';   // 'person' | 'campaign'

// 회원별 / 캠페인별 전환 스위치.
//   ⚠️ 화면 공용 탭 클래스(`status-tab`)를 쓰면 이 자리에서는 **스타일이 안 먹어 글자만**
//      보인다(그 클래스는 페인 머리글의 탭 바 안에서만 모양이 잡힌다). 여기서는 주변
//      CSS 에 기대지 않고 **눌리는 스위치 모양을 직접** 그린다 — 안 그러면 누를 수 있는
//      것인지조차 안 보인다.
function payoutGroupSwitchHtml() {
  const on  = 'background:var(--pink);color:#fff;font-weight:700';
  const off = 'background:transparent;color:var(--muted);font-weight:600';
  const base = 'border:0;border-radius:6px;height:28px;padding:0 12px;font-size:12px;cursor:pointer;white-space:nowrap';
  return `<div style="display:inline-flex;gap:2px;padding:1px;background:#F1F1F3;border:1px solid var(--line);border-radius:8px">
    <button type="button" style="${base};${_payoutGroupBy === 'person' ? on : off}"
            onclick="setPayoutGroupBy('person')" title="사람별로 묶어 봅니다(송금 처리는 여기서)">회원별</button>
    <button type="button" style="${base};${_payoutGroupBy === 'campaign' ? on : off}"
            onclick="setPayoutGroupBy('campaign')" title="캠페인별로 묶어 봅니다(보기 전용)">캠페인별</button>
  </div>`;
}

function setPayoutGroupBy(v) {
  if (_payoutGroupBy === v) return;
  _payoutGroupBy = v;
  renderPayoutPersonList();
}

function groupPayoutRowsByCampaign(rows) {
  const by = {};
  rows.forEach(function (r) {
    const key = (r.campaignNo || '') + '|' + (r.campaignTitle || '(캠페인 미상)');
    if (!by[key]) by[key] = { no: r.campaignNo, title: r.campaignTitle, rows: [] };
    by[key].rows.push(r);
  });
  return by;
}

// ─── 캠페인별 보기 — 회원별 표와 같은 모양(2026-10-01 사용자 결정) ───
//   줄을 누르면 펼치고, 펼친 안쪽은 회원별 펼침(_payoutPersonDetailHtml)과 같은 회색 머리 격자.
//   ⚠️ **보기 전용**이라 체크박스·「보냄」 열이 없다(위 안내 상자 참조).
//   ⚠️ 펼침은 캠페인 열쇠(번호|제목)로 기억한다 — onclick 에는 **목록 순번만** 넘긴다(제목에 따옴표가 들어올 수 있다).
const _payoutCampOpen = new Set();
let _payoutCampList = [];
const _PAYOUT_CAMP_ITEM_COLS = 'display:grid;grid-template-columns:140px minmax(0,1fr) 100px 100px 100px 90px 250px;column-gap:12px;align-items:center;padding:6px 12px';
function _payoutCampKey(entry) { return (entry.no || '') + '|' + (entry.title || ''); }
function togglePayoutCampOpen(i) {
  const e = _payoutCampList[i];
  if (!e) return;
  const k = _payoutCampKey(e);
  if (_payoutCampOpen.has(k)) _payoutCampOpen.delete(k); else _payoutCampOpen.add(k);
  renderPayoutPersonBody();
}
function _payoutCampDetailHtml(entry) {
  const rows = entry.rows.slice().sort(function (a, b) { return b.amount - a.amount; });
  let html = `<div style="${_PAYOUT_CAMP_ITEM_COLS};font-size:11px;font-weight:600;color:var(--muted);background:#F1F1F3">
      <div>이름(한자)</div><div>후리가나</div><div>인증 성공일</div><div>지급 예정(회차)</div><div>송금일</div><div style="text-align:right">금액</div><div>상태</div>
    </div>`;
  rows.forEach(function (r) {
    const p = payoutPersonOf(r);
    const sent = r.status === 'paid';
    html += `<div style="${_PAYOUT_CAMP_ITEM_COLS};font-size:12px;border-top:1px solid var(--line)${sent ? ';color:var(--muted)' : ''}">
      <div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(p.name || '(이름 미상)')}</div>
      <div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(p.kana || '')}</div>
      <div style="white-space:nowrap" title="결과물 최종 승인(인증 성공)일">${r.certAt ? esc(formatDate(r.certAt)) : _missingDash(_MISSING_CERT_TIP)}</div>
      <div style="white-space:nowrap">${r.due ? esc(r.due) : _missingDash(_MISSING_CERT_TIP)}</div>
      <div style="white-space:nowrap" title="실제로 송금한 날(기록된 값)">${sent && r.paidAt ? esc(formatDate(r.paidAt)) : '—'}</div>
      <div style="text-align:right;white-space:nowrap">${sent ? esc(_payoutYen(r.amount)) : _payoutAmountCell(r)}</div>
      <div style="white-space:nowrap">${sent
        ? '<span style="font-size:10px;background:#E8F5E9;color:#16A34A;font-weight:700;padding:1px 6px;border-radius:3px;white-space:nowrap">지급 완료</span>' + _payoutPaidActionsHtml(r)
        : '<span style="font-size:10px;color:#C33;font-weight:700;white-space:nowrap">미지급</span>'}</div>
    </div>`;
  });
  return `<div style="background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden">${html}</div>`;
}
function _payoutCampTableHtml(list) {
  _payoutCampList = list;
  const N = 'text-align:right;white-space:nowrap';
  const dash = '<span style="color:var(--muted);opacity:.5">—</span>';
  const rows = list.map(function (e, i) {
    const unsent = e.rows.filter(_payoutUnsent);
    const paid = e.rows.filter(function (r) { return r.status === 'paid'; });
    const people = new Set(e.rows.map(function (r) { return r.influencerId; })).size;
    const open = _payoutCampOpen.has(_payoutCampKey(e));
    return `<tr style="cursor:pointer" onclick="togglePayoutCampOpen(${i})">
        <td style="padding-left:0;padding-right:0;text-align:center"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted);vertical-align:middle">${open ? 'expand_less' : 'expand_more'}</span></td>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${esc(e.no || '')}</td>
        <td style="font-weight:600;max-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(e.title || '(캠페인 미상)')}">${esc(e.title || '(캠페인 미상)')}</td>
        <td style="${N}">${people}명</td>
        <td style="${N}">${unsent.length ? unsent.length + '건' : dash}</td>
        <td style="${N};font-weight:700;color:#C33">${unsent.length ? esc(_payoutYen(_payoutSum(unsent))) + _payoutUnknownNote(unsent) : dash}</td>
        <td style="${N};color:#16A34A">${paid.length ? paid.length + '건 · ' + esc(_payoutYen(_payoutSum(paid))) : dash}</td>
      </tr>${open ? `<tr><td colspan="7" style="background:#FAFAFA;padding:10px 16px 12px 16px">${_payoutCampDetailHtml(e)}</td></tr>` : ''}`;
  }).join('');
  return `<table class="data-table" style="width:100%;table-layout:fixed">
      <thead><tr>
        <!-- ⚠️ 너비 고정 표라 칸 너비가 그대로 지켜진다 — 28px 에 여백 12px 씩이면 아이콘(18px)이 칸 밖으로 삐져나온다 -->
        <th style="width:44px"></th>
        <th style="width:140px">캠페인 번호</th><th>캠페인</th>
        <th style="width:70px;text-align:right">인원</th>
        <th style="width:70px;text-align:right">미지급</th><th style="width:120px;text-align:right">미지급 금액</th>
        <th style="width:150px;text-align:right" title="송금완료로 기록된 건수·금액">지급 금액</th>
      </tr></thead>
      <tbody>${rows}</tbody>
    </table>`;
}

function renderPayoutPersonList() {
  const body = $('payoutSummaryBody');
  if (!body) return;
  _payoutSubView = 'person';
  refreshSettlementNav();
  // 회차 상세의 엑셀 옵션·다운로드는 요약과 같은 **탭 줄 오른쪽**(settlementNavTools)에 둔다(2026-10-01 사용자 결정).
  //   ⚠️ 「지급일 기록 없음」은 엑셀이 없으므로 비운다 — 안 비우면 요약에서 남은 단추가 그대로 보인다.
  const navTools = $('settlementNavTools');
  if (navTools && _payoutDueFilter) {
    navTools.innerHTML = _payoutDueFilter !== PAYOUT_NO_DUE
      ? payoutExportIncludePaidHtml('payoutExportIncludePaidPerson') + payoutExportIncludeEarlierHtml('payoutExportIncludeEarlierPerson')
        + payoutRoundExcelBtnHtml(_payoutDueFilter)
      : '';
  }
  body.innerHTML = `
   <div style="display:flex;flex-direction:column;flex:1;min-height:0">
    <!-- ⚠️ 바깥 상자 없이 **머리는 고정, 목록만 스크롤**한다(2026-09-30 사용자 지적 — 상자가 두 겹이었다).
         ⚠️ 머리(뒤로가기·제목·검색·스위치)와 요약·선택 정보를 **위에 붙여** 둔다.
         목록이 길어 스크롤하면 「지금 어느 회차를 보고 있고 얼마가 남았는지」가 화면 밖으로
         나가고, 고른 건수도 맨 아래에 있어 **고를 때마다 끝까지 내려가야** 했다.
         ⚠️ **아래쪽 구분선은 꼭 있어야 한다.** 없으면 목록이 이 영역 바로 밑으로 파고들어
            잘린 줄이 붙은 채로 보이고, 어디까지가 고정 영역인지 알 수 없다(2026-08-19 지적).
            선은 이 감싸개에 준다 — 안쪽 요소에 주면 선택 줄이 생겼다 없어질 때 선도 함께
            사라진다(선택 줄은 있을 때만 그려진다). -->
    <div style="flex-shrink:0;border-bottom:1px solid var(--line)">
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;flex-wrap:wrap">
      ${_payoutDueFilter ? '<button class="btn btn-ghost btn-sm" onclick="backToPayoutSummary()" title="지급일 요약으로"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;vertical-align:-4px;margin-left:-4px">chevron_left</span>뒤로</button>' : ''}
      <div id="payoutPersonTitle" style="font-weight:700;font-size:14px">${
        !_payoutDueFilter ? _payoutPeriodTitle()
        : (_payoutDueFilter === PAYOUT_NO_DUE ? '지급일 기록 없음' : esc(_payoutDueFilter) + ' 지급 예정')}</div>
      <!-- 검색칸과 스위치를 **한 덩어리로 묶어 오른쪽 끝**에 붙인다.
           ⚠️ 「admin-filter-search」 는 돋보기 아이콘 자리로 왼쪽 28px 을 비워 두는 클래스다.
              아이콘을 같이 안 넣으면 그만큼이 그냥 빈 여백으로 보인다(다른 화면은 전부
              감싸개 + 아이콘 한 쌍으로 쓴다 — 같은 모양을 지킨다).
           ⚠️ 이 주석은 **문자열 안**이다. 여기에 backtick 을 쓰면 문자열이 그 자리에서
              끊겨 파일 전체가 깨진다(2026-08-18 실제로 그랬다). 「」 로 감쌀 것. -->
      <div style="display:flex;align-items:center;gap:8px;margin-left:auto">
        ${settleSearchInputHtml('payoutPersonSearchInput', _payoutPersonSearch, 'onPayoutPersonSearch(this.value)')}
        ${!_payoutDueFilter ? settleRangeInputHtml('payoutPeriodRange', 'btnPayoutPeriodClear', 'clearPayoutPeriod',
            '이 기간에 지급 예정인 건만 봅니다(지급 예정일 = 회차 날짜). 비우면 전체 기간', '지급 예정 시작일~종료일') : ''}
        ${payoutGroupSwitchHtml()}
      </div>
    </div>
      <div id="payoutStickyInfo"></div>
    </div>
    <!-- ⚠️ 여백은 **고정 영역이 아니라 목록 쪽**에 준다. 고정 영역 안에 넣으면 스크롤 중에도
         그만큼 흰 띠가 따라다녀 화면이 좁아진다. 목록에 주면 **맨 위에서만** 벌어지고,
         스크롤하면 자연스럽게 구분선 밑으로 들어간다(2026-08-19 사용자 지적). -->
    <div id="payoutPersonListBody" style="flex:1;min-height:0;overflow-y:auto"></div>
   </div>`;
  _setupPayoutPeriodRange();
  renderPayoutPersonBody();
}

// 「사람별」 기간 칸 — 송금 내역 기간 칸과 같은 동작(양끝을 다 골랐을 때만 거른다).
//   ⚠️ 머리를 다시 그릴 때마다(renderPayoutPersonList) 칸이 새 노드라 달력도 새로 붙인다.
function _payoutPeriodTitle() {
  return (_payoutPeriodFrom && _payoutPeriodTo)
    ? esc(_payoutPeriodFrom) + ' ~ ' + esc(_payoutPeriodTo) + ' 지급 예정'
    : '전체 기간';
}
function _syncPayoutPeriodUi() {
  const on = !!(_payoutPeriodFrom && _payoutPeriodTo);
  const el = $('payoutPeriodRange');
  if (el) el.classList.toggle('filter-active', on);
  const x = $('btnPayoutPeriodClear');
  if (x) x.style.display = on ? 'inline-flex' : 'none';
  const t = $('payoutPersonTitle');
  if (t && !_payoutDueFilter) t.innerHTML = _payoutPeriodTitle();
}
function _setupPayoutPeriodRange() {
  if (_payoutPeriodFp) { try { _payoutPeriodFp.destroy(); } catch (e) {} _payoutPeriodFp = null; }
  const el = $('payoutPeriodRange');
  if (!el || typeof flatpickr === 'undefined') return;
  _payoutPeriodFp = flatpickr(el, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    showMonths: 1,
    defaultDate: (_payoutPeriodFrom && _payoutPeriodTo) ? [_payoutPeriodFrom, _payoutPeriodTo] : undefined,
    onChange: function (d) {
      if (d.length !== 2) return;
      _payoutPeriodFrom = _settleFpDate(d[0]); _payoutPeriodTo = _settleFpDate(d[1]);
      _syncPayoutPeriodUi();
      _payoutPruneHiddenSelection();
      renderPayoutPersonBody();
    },
  });
  _syncPayoutPeriodUi();
}
function clearPayoutPeriod() {
  _payoutPeriodFrom = ''; _payoutPeriodTo = '';
  // ⚠️ clear(false) — 변경 이벤트를 안 일으킨다(인증 성공일 필터와 같은 함정)
  if (_payoutPeriodFp) _payoutPeriodFp.clear(false);
  _syncPayoutPeriodUi();
  renderPayoutPersonBody();
}
// 사람별 기간 안의 건인가 — 기간이 없으면 전부, 있으면 지급 예정일이 그 안인 것만(문자열 비교 — 시간대 무관).
function _payoutInPeriod(r) {
  if (!(_payoutPeriodFrom && _payoutPeriodTo) || _payoutDueFilter) return true;
  return !!r.due && r.due >= _payoutPeriodFrom && r.due <= _payoutPeriodTo;
}

// 목록만 다시 그린다(검색창은 건드리지 않는다).
function renderPayoutPersonBody() {
  const body = $('payoutPersonListBody');
  if (!body) return;
  const all = _payoutRows || [];
  // 지급일 필터가 있으면 그 회차만(화면 ㄴ), 없으면 전 기간(화면 ㄷ).
  // ★ 그 회차의 **보낸 것까지 함께** 보여준다(2026-08-18 사용자 요청).
  //   ⚠️ 예전에는 안 보낸 것만 넘겼다. 그러면 절반을 보낸 회차에서 **이미 보낸 사람이
  //      목록에서 사라져**, 「이 사람 보냈던가」를 확인할 데가 없었다.
  //   보낸 것은 사람 카드 안에서 「이미 기록됨」 줄로 따로 묶인다(groupSettlementsByPerson).
  let rows = !_payoutDueFilter ? all.filter(_payoutInPeriod)
    : (_payoutDueFilter === PAYOUT_NO_DUE
        ? all.filter(function(r) { return !r.due; })
        : all.filter(function(r) { return r.due === _payoutDueFilter; }));
  // ── 캠페인별 보기 (보기 전용) ────────────────────────────────
  if (_payoutGroupBy === 'campaign') {
    let cr = rows;
    if (_payoutPersonSearch) {
      // 검색은 사람뿐 아니라 **캠페인 이름·번호**에서도 찾는다 — 캠페인별로 보는 중이니
      // 캠페인 이름으로 못 찾으면 이 화면에서 검색이 반쪽이 된다.
      cr = cr.filter(function (r) {
        const p = payoutPersonOf(r);
        return payoutSearchHit([p.name, p.kana, p.paypal, r.campaignTitle, r.campaignNo], _payoutSearchTokens);
      });
    }
    const byCamp = groupPayoutRowsByCampaign(cr);
    const list = Object.keys(byCamp).map(function (k) { return byCamp[k]; })
      .sort(function (a, b) { return _payoutSum(b.rows) - _payoutSum(a.rows); });
    // 요약 줄은 회원별과 같은 자리(고정 영역 payoutStickyInfo)에 둔다 — 선택 줄은 없다(보기 전용).
    const info = $('payoutStickyInfo');
    if (info) info.innerHTML = `<div style="font-size:12px;color:var(--muted);margin-bottom:10px">
        캠페인 ${list.length}개 · ${cr.length}건 · 합계 <b style="color:var(--ink)">${esc(_payoutYen(_payoutSum(cr)))}</b>
        <span style="margin-left:8px">· 캠페인별은 <b>보기 전용</b>입니다. 송금은 사람에게 하므로 실제 처리는 「회원별」에서 하세요
          (한 사람이 여러 캠페인에 걸쳐 있어, 캠페인 쪽에서 고르면 그 사람에게 보낼 금액이 갈라집니다).</span>
      </div><div style="height:8px"></div>`;
    body.innerHTML = list.length ? _payoutCampTableHtml(list)
      : '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">대상이 없습니다.</div>';
    return;
  }

  const byPerson = groupSettlementsByPerson(rows);
  let entries = Object.keys(byPerson).map(function(k) { return byPerson[k]; });

  // 사람 검색 — 한자·가나·페이팔 이메일 셋 다에서 찾는다(대장이 어느 쪽으로 적혀 있는지 모른다)
  if (_payoutPersonSearch) {
    entries = entries.filter(function(e) {
      const p = e.person;
      return payoutSearchHit([p.name, p.kana, p.paypal], _payoutSearchTokens);
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
  const unsentSum = entries.reduce(function(a, e) {
    return a + Object.keys(e.dues).reduce(function(b, d) { return b + _payoutSum(e.dues[d]); }, 0); }, 0);
  const paidCnt = entries.reduce(function(a, e) { return a + e.paid.length; }, 0);
  const paidSum2 = entries.reduce(function(a, e) { return a + _payoutSum(e.paid); }, 0);
  const progressHtml = _payoutDueFilter
    ? `<div style="font-size:12px;color:var(--muted);margin-bottom:10px;display:flex;align-items:center;gap:8px"><span>${total}명 · 미지급 <b style="color:#C33">${esc(_payoutYen(unsentSum))}</b>${
        paidCnt ? ` · 송금완료 <b style="color:#16A34A">${paidCnt}건 ${esc(_payoutYen(paidSum2))}</b>` : ''}</span></div>`
    : `<div style="font-size:12px;color:var(--muted);margin-bottom:10px;display:flex;align-items:center;gap:8px"><span>${total}명 중 <b style="color:var(--ink)">${doneCount}명</b> 처리 · ${total - doneCount}명 남음</span></div>`;

  const info = $('payoutStickyInfo');
  if (info) {
    info.innerHTML = progressHtml
      + (_payoutSelected.size ? `
      <div style="border-top:1px solid var(--line);padding:8px 0;font-size:13px;display:flex;align-items:center;gap:10px">
        <span>선택 <b>${_payoutSelected.size}</b>묶음 · <b>${selectedRows.length}</b>건 · 합계 <b>${esc(_payoutYen(_payoutSum(selectedRows)))}</b>${_payoutUnknownNote(selectedRows)}</span>
        <button class="btn btn-primary btn-sm" style="margin-left:auto"
                onclick="openPayoutSendSelectedModal()" title="고른 묶음을 한 번에 송금완료로 기록합니다">선택한 건 보냄</button>
        <button class="btn btn-ghost btn-sm"
                onclick="_payoutSelected.clear(); renderPayoutPersonBody();">선택 해제</button>
      </div>` : '<div style="height:8px"></div>');
  }
  body.innerHTML = `
    ${entries.length ? _payoutPersonTableHtml(entries)
      : `<div id="payoutEmptyBox" style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">${
          _payoutSearchTokens.length ? '찾는 중…'
          : (!_payoutDueFilter && _payoutPeriodFrom && _payoutPeriodTo)
            ? '이 기간(지급 예정일 기준)에 해당하는 건이 없습니다.<br>지급일 기록이 없는 건은 기간을 비워야 보입니다.'
            : '대상이 없습니다.'}</div>`}
    `;

  // 비었으면 **왜 없는지** 찾아본다(화면을 그린 뒤 비동기 — 목록 표시를 막지 않는다)
  // ⚠️ 기간을 넣은 채면 「왜 없는지」 조회가 기간 밖 건을 「이 화면에 없다」로 잘못 말한다 — 기간이 없을 때만.
  if (!entries.length && _payoutSearchTokens.length && !(_payoutPeriodFrom && _payoutPeriodTo)) payoutExplainMissing(_payoutPersonSearch);
  else if (!entries.length && _payoutSearchTokens.length) {
    const box = $('payoutEmptyBox');
    if (box) box.innerHTML = '이 기간(지급 예정일 기준)에 찾는 사람이 없습니다.<br>기간을 비우고 다시 찾아보세요.';
  }
}

// 검색 결과가 비었을 때 왜 없는지 알려준다.
//   ⚠️ 「대상이 없습니다」만 띄우면 **이 화면에 없는 것**인지 **아예 정산 대상이 아닌 것**인지
//      구분이 안 된다. 지급대장과 맞추는 자리라 그 차이가 곧 「내가 빠뜨렸나」를 가른다.
//   ⚠️ 이 조회는 **화면이 빈 경우에만** 돈다 — 검색할 때마다 사람 표를 뒤지면 느려진다.
//   ⚠️ 보류·취소 건은 이 화면 목록에서 애초에 빠져 있다(지급 대상이 아니라서). 그래서
//      「이름은 있는데 목록에 없다」가 생기고, 그 이유를 여기서 말해 준다.
async function payoutExplainMissing(query) {
  const box = document.getElementById('payoutEmptyBox');
  if (!box) return;
  const q = String(query || '').trim();
  if (!q) { box.textContent = '대상이 없습니다.'; return; }
  let people = [];
  try {
    const words = q.split(/[\s\u3000]+/).filter(Boolean);
    const key = words[0];   // 첫 낱말로 넓게 훑고 나머지는 아래에서 걸러낸다
    const r = await db.from('influencers_admin_view')
      .select('id,name,name_kana,email')
      .or('name.ilike.%' + key + '%,name_kana.ilike.%' + key + '%').limit(50);
    if (r.error) throw r.error;
    people = (r.data || []).filter(function (x) {
      return payoutSearchHit([x.name, x.name_kana, x.email], _payoutSearchTokens);
    });
  } catch (e) {
    box.innerHTML = '이 이름으로 더 찾아보지 못했습니다. 잠시 뒤 다시 시도해 주세요.';
    return;
  }
  if (!people.length) {
    box.innerHTML = '「' + esc(q) + '」 로 찾은 인플루언서가 없습니다. 이름 표기를 확인해 주세요.';
    return;
  }
  const ids = people.map(function (x) { return x.id; });
  const byInf = {};
  try {
    const st = await db.from('settlements').select('influencer_id,status').in('influencer_id', ids);
    (st.data || []).forEach(function (x) {
      byInf[x.influencer_id] = byInf[x.influencer_id] || {};
      byInf[x.influencer_id][x.status] = (byInf[x.influencer_id][x.status] || 0) + 1;
    });
  } catch (e) { /* 상태를 못 읽어도 이름은 보여준다 */ }
  const LABEL = { pending: '정산대기', paid: '송금완료', on_hold: '보류', cancelled: '취소' };
  box.style.textAlign = 'left';
  box.innerHTML = '<div style="font-size:13px;color:var(--ink);margin-bottom:8px">이 화면에는 없지만, 같은 이름의 인플루언서를 '
    + people.length + '명 찾았습니다.</div>'
    + people.map(function (x) {
        const st = byInf[x.id] || {};
        const parts = Object.keys(st).map(function (k) { return (LABEL[k] || k) + ' ' + st[k] + '건'; });
        return '<div style="padding:8px 10px;border:1px solid var(--line);border-radius:8px;margin-bottom:6px">'
          + '<div style="font-weight:700;font-size:13px">' + esc(x.name || '(이름 없음)')
          + ' <span style="font-size:11px;color:var(--muted);font-weight:400">' + esc(x.name_kana || '') + '</span></div>'
          + '<div style="font-size:12px;color:var(--muted);margin-top:2px">'
          + (parts.length
              ? '정산 ' + esc(parts.join(' · ')) + ' — 보류·취소는 이 화면에 안 나옵니다.'
              : '<b>정산 건이 없습니다.</b> 인증에 성공한 응모가 없어 지급 대상이 아닙니다.')
          + '</div></div>';
      }).join('');
}

// 사이드바 「정산 관리」 옆 작은 경고 — **미등록이 있을 때만**.
//   ⚠️ 배지 숫자 자체는 「정산대기」 건수 그대로 둔다(뜻이 흔들리지 않게, 사양서 §4-2).
//      경고는 그 옆에 따로 붙인다.
//   ⚠️ **0건이면 아무것도 안 그린다.** 늘 떠 있는 표시는 학습되어 무시된다 —
//      채널 어긋남 감지 장치에서 이미 세운 원칙이다.
//   ⚠️ 탭 건수와 혼동하지 말 것 — 탭 건수는 「몇 건 있나」라는 **사실 표시**라 0이어도
//      그대로 두고, 이 경고는 **경보**라 0이면 사라진다.
function applySettlementUnregWarning() {
  const item = document.getElementById('adminSettlementsSi');
  if (!item) return;
  let mark = item.querySelector('.unreg-warn');
  const n = _pastUnregLoaded ? _pastUnregRows.length : 0;
  if (!n) { if (mark) mark.remove(); return; }
  if (!mark) {
    mark = document.createElement('span');
    mark.className = 'unreg-warn material-icons-round notranslate';
    mark.setAttribute('translate', 'no');
    mark.style.cssText = 'font-size:14px;color:#B8741A;margin-left:4px;cursor:pointer';
    mark.textContent = 'report_problem';
    // ⚠️ 열 화면을 **지정해서** 들어간다(배지와 같은 헬퍼). 지정 없이 필터만 걸면 페인
    //    진입이 첫 화면으로 지급 준비를 켜고, 뒤늦게 미등록을 켜면 두 화면이 **세로로 겹쳐
    //    둘 다** 보인다(2026-08-19 사용자 보고).
    //  ⚠️ 미등록 조회는 여전히 두 번 돈다(진입 로더의 건수 갱신 + 미등록 화면의 목록).
    //     같은 조회라 결과가 같아 화면은 어긋나지 않지만, 줄이려면 진입 로더 쪽을 손봐야 한다.
    mark.onclick = function(e) {
      e.stopPropagation();
      enterSettlementsWithView('unregistered');
    };
    item.appendChild(mark);
  }
  mark.title = `아직 정산 행이 만들어지지 않은 건 ${n}건 — 「미등록」 탭에서 볼 수 있습니다`;
}

// ════════════════════════════════════════════════════════════════════
// SECTION: 「수수료 설정」 창 (조각 13 — 마이그레이션 484)
//   비율(%) · 고정액(엔) · 끝수 처리(반올림/버림/올림) + 최근 변경 이력.
//   ⚠️ 이 값은 **앞으로 기록할 송금**의 자동 수수료에만 쓰인다 — 이미 기록한 묶음은 그때 규칙을
//      스냅샷으로 들고 있어 바뀌지 않는다(485 fee_rate_percent·fee_fixed_jpy·fee_rounding).
//   ⚠️ 쓰기 권한(settlement.pay)이 없으면 **숨기지 않고 비활성** + 「변경 권한이 없습니다」(quality.md 권한 행).
//   창은 **동적으로 만든다**(오리엔시트 모달 선례) — 핫스팟 index.html 을 덜 건드린다.
// ════════════════════════════════════════════════════════════════════
const FEE_ROUNDING_LABELS = { round: '반올림', floor: '버림', ceil: '올림' };

function _ensureSettlementFeeRuleModal() {
  let el = $('settlementFeeRuleModal');
  if (el) return el;
  el = document.createElement('div');
  el.className = 'modal-overlay';
  el.id = 'settlementFeeRuleModal';
  el.style.zIndex = '615';
  el.innerHTML = `
    <div class="modal" style="max-width:520px;border-radius:20px;margin:auto;max-height:86vh;display:flex;flex-direction:column">
      <div class="modal-header" style="padding:18px 22px 12px;border-bottom:1px solid var(--line)">
        <div style="font-size:16px;font-weight:700;color:var(--ink)">송금 수수료 설정</div>
      </div>
      <div class="modal-body" id="settlementFeeRuleBody" style="padding:18px 22px;overflow-y:auto;flex:1"></div>
      <div style="padding:14px 22px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end">
        <button class="btn btn-ghost" onclick="closeSettlementFeeRuleModal()">닫기</button>
        <button class="btn btn-primary" id="settlementFeeRuleSaveBtn" onclick="saveSettlementFeeRule()">저장</button>
      </div>
    </div>`;
  document.body.appendChild(el);
  return el;
}

async function openSettlementFeeRuleModal() {
  _ensureSettlementFeeRuleModal();
  const body = $('settlementFeeRuleBody');
  if (body) body.innerHTML = '<div style="padding:20px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';
  openModal('settlementFeeRuleModal');
  const rule = await fetchSettlementFeeRule();
  if (!body) return;
  if (!rule) {
    body.innerHTML = '<div style="padding:16px;color:#B91C1C;font-size:13px">수수료 규칙을 불러오지 못했습니다. 잠시 후 다시 열어 주세요.</div>';
    const b = $('settlementFeeRuleSaveBtn'); if (b) b.disabled = true;
    return;
  }
  const canEdit = canWrite('settlement.pay');
  const dis = canEdit ? '' : 'disabled';
  const hist = Array.isArray(rule.history) ? rule.history : [];
  const histHtml = hist.length
    ? hist.map(function (h) {
        return `<div style="display:flex;gap:8px;font-size:12px;padding:4px 0;border-bottom:1px solid var(--line)">
            <div style="width:120px;color:var(--muted)">${esc(formatDateTime(h.at))}</div>
            <div style="flex:1">${esc(String(h.prev_rate_percent))}% + ¥${esc(String(h.prev_fixed_jpy))} · ${esc(FEE_ROUNDING_LABELS[h.prev_rounding] || h.prev_rounding || '')}
              → <b>${esc(String(h.next_rate_percent))}% + ¥${esc(String(h.next_fixed_jpy))} · ${esc(FEE_ROUNDING_LABELS[h.next_rounding] || h.next_rounding || '')}</b></div>
            <div style="width:80px;text-align:right;color:var(--muted)">${esc(h.actor_name || '(시스템)')}</div>
          </div>`;
      }).join('')
    : '<div style="font-size:12px;color:var(--muted)">바꾼 기록이 없습니다.</div>';
  body.innerHTML = `
    <div style="padding:10px 12px;background:#EFF6FF;border:1px solid #BFDBFE;border-radius:8px;font-size:12px;line-height:1.6;margin-bottom:14px">
      수수료 = <b>보낸 금액 × 비율 + 고정액</b>을 끝수 처리한 값입니다(묶음 하나 = 페이팔 송금 한 번마다).
      <br>바꾼 값은 <b>앞으로 기록할 송금에만</b> 쓰입니다. 이미 기록한 송금은 바뀌지 않습니다.
    </div>
    ${canEdit ? '' : '<div style="font-size:12px;color:#B8741A;margin-bottom:10px">변경 권한이 없습니다 — 보기만 할 수 있습니다.</div>'}
    <div style="display:flex;gap:12px;flex-wrap:wrap;margin-bottom:14px">
      <div class="form-group" style="flex:1;min-width:120px">
        <label class="form-label">비율(%)</label>
        <input type="number" id="feeRuleRate" class="form-input" min="0" max="100" step="0.01" value="${esc(String(rule.rate_percent))}" ${dis}>
      </div>
      <div class="form-group" style="flex:1;min-width:120px">
        <label class="form-label">고정액(엔)</label>
        <input type="number" id="feeRuleFixed" class="form-input" min="0" step="1" value="${esc(String(rule.fixed_jpy))}" ${dis}>
      </div>
      <div class="form-group" style="flex:1;min-width:120px">
        <label class="form-label">끝수 처리</label>
        <select id="feeRuleRounding" class="form-input" ${dis}>
          ${['round', 'floor', 'ceil'].map(function (k) {
            return `<option value="${k}" ${rule.rounding === k ? 'selected' : ''}>${FEE_ROUNDING_LABELS[k]}</option>`;
          }).join('')}
        </select>
      </div>
    </div>
    <div style="font-size:12px;color:var(--muted);margin-bottom:6px">마지막 변경: ${rule.updated_by_name ? esc(rule.updated_by_name) + ' · ' : ''}${esc(formatDateTime(rule.updated_at))}</div>
    <div style="font-size:13px;font-weight:700;margin:12px 0 6px">최근 변경 이력</div>
    ${histHtml}`;
  const btn = $('settlementFeeRuleSaveBtn');
  if (btn) { btn.disabled = !canEdit; btn.title = canEdit ? '' : '변경 권한이 없습니다'; }
}

// 확인 창·정정 창의 「수수료 설정」 글 링크 — 두 창과 설정 창의 쌓임 순서가 같아(615) 만든 순서에 따라
//   설정 창이 뒤에 깔릴 수 있다 → 열 때 위로 올린다. 닫히면 부른 쪽 미리보기를 다시 묻는다(설정이 바뀌었을 수 있다)
let _feeRuleOnClose = null;
// 정산 화면에서 직접 열 때 — 자식 창에서 열었다가 「닫기」 아닌 길로 닫혀 남은 콜백·쌓임 순서를 비운다
async function openSettlementFeeRuleFromPane() {
  _feeRuleOnClose = null;
  const el = _ensureSettlementFeeRuleModal(); el.style.zIndex = '615';
  await openSettlementFeeRuleModal();
}
async function openFeeRuleFromChild(onClose) {
  const el = _ensureSettlementFeeRuleModal();
  el.style.zIndex = '640';
  _feeRuleOnClose = (typeof onClose === 'function') ? onClose : null;
  await openSettlementFeeRuleModal();
}
function closeSettlementFeeRuleModal() {
  closeModal('settlementFeeRuleModal');
  const el = $('settlementFeeRuleModal'); if (el) el.style.zIndex = '615';
  const cb = _feeRuleOnClose; _feeRuleOnClose = null;
  if (cb) cb();
}

async function saveSettlementFeeRule() {
  if (!canWrite('settlement.pay')) { toast('변경 권한이 없습니다', 'warn'); return; }
  const rateRaw = ($('feeRuleRate')?.value || '').trim();
  const fixedRaw = ($('feeRuleFixed')?.value || '').trim();
  // ⚠️ 빈 칸을 먼저 거부한다 — Number('') 가 0 이라, 실수로 비우면 앞으로의 자동 수수료가 전부 0 이 된다
  if (rateRaw === '' || fixedRaw === '') { toast('비율과 고정액을 모두 넣어 주세요(0 도 숫자로 넣습니다)', 'warn'); return; }
  const rate = Number(rateRaw);
  const fixed = Number(fixedRaw);
  const rounding = $('feeRuleRounding')?.value || '';
  if (!Number.isFinite(rate) || rate < 0 || rate > 100) { toast('비율은 0~100 사이 숫자로 넣어 주세요', 'warn'); return; }
  if (!Number.isInteger(fixed) || fixed < 0) { toast('고정액은 0엔 이상 정수로 넣어 주세요', 'warn'); return; }
  if (!FEE_ROUNDING_LABELS[rounding]) { toast('끝수 처리를 골라 주세요', 'warn'); return; }
  const btn = $('settlementFeeRuleSaveBtn');
  if (btn) btn.disabled = true;
  try {
    const r = await updateSettlementFeeRule(rate, fixed, rounding);
    toast(r && r.unchanged ? '바뀐 값이 없습니다' : '수수료 규칙을 저장했습니다 — 앞으로 기록하는 송금부터 쓰입니다');
  } catch (e) {
    toast('저장 실패 — ' + friendlyError(e.message || e), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  await openSettlementFeeRuleModal();     // 이력 한 줄이 바로 보이게 다시 그린다
  await refreshPane('settlements');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: 「송금 내역」 화면 (조각 14·15 — 마이그레이션 487)
//
// ▶ 페이팔 송금 한 번 = 한 줄(묶음). 펼치면 포함된 건. 기간 필터, 보기 셋(목록/월별/회차별), 엑셀, 묶음 정정.
// 🔴 네 화면(정산 목록·미등록·지급 준비·송금 내역)은 **서로 배타**다. 이 화면을 켜는 함수가 나머지를
//    닫고, 나머지를 켜는 길(openPayoutPrepView·closePayoutPrepView·showUnregisteredTab·
//    hideUnregisteredTab·loadSettlements)은 전부 `_hideTransferView()` 를 부른다. 짝이 하나라도
//    빠지면 두 화면이 겹친다(2026-08-18·19 실제 사고).
// ⚠️ 합계는 **서버 저장값만** 더한다(보낸 금액·수수료) — 화면에서 다시 계산하지 않는다.
// ⚠️ 조회 실패(null)와 0건([])을 가른다 — 실패를 「보낸 것 없음」으로 그리지 않는다.
// ⚠️ 회차 판정은 서버 `_settlement_payout_due`(487)와 화면 `payoutDueDate`(shared.js) **두 벌**이다.
// ════════════════════════════════════════════════════════════════════
let _transferMode = 'list';          // 'list' | 'monthly' | 'round'
let _transferFrom = null;            // 'YYYY-MM-DD' | null
let _transferTo = null;
let _transferRows = undefined;       // undefined 안 받음 / null 실패 / 배열
let _transferMonthly = undefined;
let _transferRound = undefined;
let _transferUnrecorded = undefined; // undefined 안 받음 / null 실패 / 객체
const _transferOpen = new Set();     // 펼친 묶음 id
// 월별·회차별 「상세」 — 표 안에서 펼치지 않고 **같은 자리에서 상세 화면으로 넘어간다**(회차별 탭의 「상세」와 같은 방식, 2026-09-30 사용자 결정).
//   null = 요약 표 / { mode:'monthly'|'round', key:'YYYY-MM' | 'YYYY-MM-DD' | 'none' }
let _transferDetail = null;
let _transferAllRows = undefined;    // 회차별 상세용 **전 기간** 묶음(기간을 넣었을 때만 따로 받는다). undefined 안 받음 / null 실패 / 배열
let _transferLoadSeq = 0;
// 송금 내역 검색(받는 사람 이름 한자·가나·페이팔) — 「전체」 목록만 거른다(2026-10-01).
//   ⚠️ 월별·회차별은 **서버 집계값**이라 사람으로 다시 거를 수 없다(합계는 서버 저장값만 — 위 규칙). 그 보기에선 칸을 잠근다.
let _transferSearch = '';
let _transferSearchTokens = [];

function _hideTransferView() {
  const v = $('settlementTransferView');
  if (v) v.style.display = 'none';
}

async function openTransferHistoryView() {
  const main = $('settlementMainView'), payout = $('settlementPayoutView'), view = $('settlementTransferView');
  if (!view) return;
  // 들어올 때마다 요약에서 시작한다 — 보던 상세를 남겨 두면, 아래 재조회가 전 기간 묶음(_transferAllRows)을 비워
  //   회차별 상세가 「불러오는 중…」에 영영 멈춘다(그 자료는 openTransferSumDetail 만 받는다. 2026-09-30 리뷰).
  _transferDetail = null;
  closeTransferHelp();
  hideUnregisteredTab();               // 미등록 닫기(안에서 _hideTransferView 도 부르므로 아래에서 켠다)
  if (main) main.style.display = 'none';
  if (payout) payout.style.display = 'none';
  view.style.display = 'flex';
  refreshSettlementNav();
  if (_transferFrom === null && _transferTo === null) {
    // 기본 기간 = 지난달 1일 ~ 오늘(일본 날짜). 문자열 연산이라 시간대가 끼어들 자리가 없다
    const today = jstTodayStr();
    _transferFrom = _payoutShiftMonth(today.slice(0, 7), -1) + '-01';
    _transferTo = today;
  }
  _renderTransferToolbar();
  await _loadTransferHistory();
}

// 정산 목록으로 이동(toList) — 탭 줄의 「정산 목록」 탭이 부른다(openSettlementTab). 다른 화면을 켜는 함수는 각자 이 화면을 닫는다.
function closeTransferHistoryView(toList) {
  _hideTransferView();
  if (!toList) { refreshSettlementNav(); return; }
  const main = $('settlementMainView');
  if (main) main.style.display = 'flex';
  if (_settlementFilters && _settlementFilters.status === 'unregistered') { showUnregisteredTab(); return; }
  renderSettlementsList();
  refreshSettlementNav();
}

// 도구 줄 — **왼쪽 보기 탭 · 오른쪽 기간(달력 한 칸)·엑셀**(2026-09-30 사용자 결정).
//   ⚠️ 줄 전체는 **한 번만** 만든다 — 기간 칸에 달력(flatpickr)이 붙어 있어 innerHTML 로 다시 그리면 떨어진다.
//      보기를 바꿀 때는 탭 칸(transferModeTabs)만 다시 그린다.
//   기간 칸은 결과물 관리 「인증 성공일」과 같은 모양·같은 동작(양끝을 다 골랐을 때만 조회).
let _transferFp = null;
// 보기별 도움말 — 표 위에 늘 띄우지 않고 탭 옆 「?」를 눌러 본다(2026-09-30 사용자 결정).
const _TRANSFER_HELP = {
  list: '페이팔 송금 <b>한 번 = 한 줄</b>입니다. 줄을 누르면 그 송금에 들어간 건(캠페인·회차·금액)이 펼쳐집니다.<br>'
      + '기간은 <b>송금일(일본 날짜)</b>로 거릅니다. 「정정」으로 송금일·수수료·거래번호·메모를 고칠 수 있습니다.',
  monthly: '송금일(일본 날짜) 기준입니다. 건수는 연결 건 기준(보류 해제로 끊긴 옛 송금도 실제로 나간 돈이라 포함).' + '<br>「상세」를 누르면 그 달에 보낸 송금이 한 줄씩 나옵니다.',
  round: '보낸 금액은 <b>각 건의 원래 회차</b>에, 수수료는 <b>묶음 안 가장 늦은 회차에 통째로</b> 들어갑니다. 송금일 기준 합계는 「월별」에서 보세요.<br>⚠️ 기간은 <b>회차 날짜</b>로 거르므로 기간을 넣으면 「월별」·「전체」 합계와 다를 수 있습니다 — <b>「전체 기간」에서는 셋이 같습니다.</b> 「지급일 기록 없음」 줄은 전체 기간에서만 보입니다.' + '<br>「상세」를 누르면 그 회차 건이 든 송금이 나옵니다. 다른 회차로 간 수수료는 「—」로 표시됩니다.',
};
// 말풍선 — 탭마다 붙은 「?」를 누르면 그 아래에 뜬다. 바깥을 누르거나 같은 「?」를 다시 누르면 닫힌다.
//   ⚠️ 말풍선은 body 에 붙인 고정 위치 요소 하나다 — 표 카드 안에 두면 overflow 에 잘린다.
//   ⚠️ 「?」는 탭 버튼 **안**에 있어, 누를 때 탭 전환이 같이 일어나지 않게 전파를 막는다.
let _transferHelpFor = null;
function _transferHelpPop() {
  let el = document.getElementById('transferHelpPop');
  if (!el) {
    el = document.createElement('div');
    el.id = 'transferHelpPop';
    el.setAttribute('role', 'tooltip');
    // 오른쪽 아래 모서리로 크기를 바꿀 수 있다(resize:both — 넘치는 글은 안에서 스크롤).
    //   열 때마다 폭은 처음 값(380px)으로, 높이는 글이 다 보이게(자동, 최대 70vh) 되돌린다 — toggleTransferHelp.
    el.style.cssText = 'display:none;position:fixed;z-index:700;width:380px;min-width:240px;min-height:60px;max-height:70vh;'
      + 'resize:both;overflow:auto;padding:12px 14px;background:#fff;'
      + 'border:1px solid var(--line);border-radius:8px;box-shadow:0 6px 20px rgba(0,0,0,.14);font-size:12px;line-height:1.7;color:var(--ink)';
    document.body.appendChild(el);
    // ⚠️ 크기 조절을 말풍선 안에서 시작해 **바깥에서 손을 떼면** 클릭이 바깥으로 잡혀 닫혀 버린다.
    //    누르기 시작한 자리가 말풍선 안이었으면 그 클릭은 닫기로 치지 않는다.
    let pressInside = false;
    document.addEventListener('mousedown', function (e) { pressInside = el.contains(e.target); }, true);
    document.addEventListener('click', function (e) {
      if (!_transferHelpFor) return;
      if (pressInside) { pressInside = false; return; }
      if (el.contains(e.target) || (e.target.closest && e.target.closest('[data-transfer-help]'))) return;
      closeTransferHelp();
    });
  }
  return el;
}
function closeTransferHelp() {
  _transferHelpFor = null;
  const el = document.getElementById('transferHelpPop');
  if (el) el.style.display = 'none';
}
function toggleTransferHelp(mode, ev) {
  if (ev) { ev.stopPropagation(); ev.preventDefault(); }
  const el = _transferHelpPop();
  if (_transferHelpFor === mode) { closeTransferHelp(); return; }
  _transferHelpFor = mode;
  // 고정 문구(사용자 입력 아님). 줄바꿈(<br>)마다 문단으로 나눠 문단 사이를 띄운다.
  el.innerHTML = String(_TRANSFER_HELP[mode] || '').split('<br>').map(function (t, i) {
    return `<p style="margin:${i ? '10px' : '0'} 0 0">${t}</p>`;
  }).join('');
  // 지난번에 끌어 바꾼 크기를 버린다(끌기는 style.width·height 를 직접 적는다). 높이 최대는 max-height(70vh).
  el.style.width = '380px';
  el.style.height = '';
  el.style.display = 'block';
  const r = ev && ev.currentTarget ? ev.currentTarget.getBoundingClientRect() : { left: 0, bottom: 0 };
  const w = el.offsetWidth;
  el.style.left = Math.max(8, Math.min(r.left - 12, window.innerWidth - w - 8)) + 'px';
  el.style.top = (r.bottom + 6) + 'px';
}

function _renderTransferToolbar() {
  const bar = $('transferHistoryToolbar');
  if (!bar) return;
  if (!$('transferModeTabs')) {
    bar.innerHTML = `
      <div style="display:flex;align-items:flex-end;justify-content:space-between;gap:12px;flex-wrap:wrap">
        <div id="transferModeTabs" class="status-tab-bar" style="margin:0;border-bottom:none"></div>
        <!-- 필터 줄 모양은 진행현황 「인증 성공일」과 같다 — 달력 칸 + 옆의 × 지우기(기간이 있을 때만).
             admin-filter-bar 안이라 버튼 높이가 입력 칸과 같은 32px 로 맞춰진다(admin.css). -->
        <div class="admin-filter-bar">
          <!-- 검색칸·기간 칸은 「사람별」과 같은 모양(settleSearchInputHtml·settleRangeInputHtml). × 는 칸 안쪽 오른쪽 끝. -->
          <div class="admin-filter-group" id="transferSearchWrap">
            ${settleSearchInputHtml('transferSearchInput', _transferSearch, 'onTransferSearch(this.value)')}
          </div>
          <div class="admin-filter-group">
            ${settleRangeInputHtml('transferRange', 'btnTransferRangeClear', 'clearTransferPeriod',
              '이 기간에 보낸 송금만 봅니다(회차별은 회차 날짜로 거릅니다). 비우면 전체 기간', _transferRangePlaceholder())}
          </div>
          <button class="btn btn-ghost btn-sm" onclick="exportTransferHistoryExcel()" title="지금 기간의 송금 내역과 포함 건을 엑셀로 내려받습니다">
            ${_DOWNLOAD_XLSX_HTML}
          </button>
        </div>
      </div>
      <div id="transferUnrecordedLine" style="margin-top:10px"></div>`;
    _transferFp = null;
    _setupTransferRange();
  }
  const modes = [['list', '전체'], ['monthly', '월별'], ['round', '회차별']];
  $('transferModeTabs').innerHTML = modes.map(function (m) {
    return `<button type="button" class="status-tab-btn${_transferMode === m[0] ? ' on' : ''}" onclick="setTransferMode('${m[0]}')"
        style="display:inline-flex;align-items:center;gap:3px">${m[1]}<span data-transfer-help="${m[0]}" role="button" tabindex="0"
        onclick="toggleTransferHelp('${m[0]}', event)"
        onkeydown="if(event.key==='Enter'||event.key===' '){toggleTransferHelp('${m[0]}', event);}" title="「${m[1]}」 도움말" aria-label="「${m[1]}」 도움말"
        style="display:inline-flex;color:#D4D4D8;cursor:pointer"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">help</span></span></button>`;
  }).join('');
  closeTransferHelp();
  _syncTransferSearchUi();
}

// 기간 칸 안내 문구 — 무엇의 시작·종료일인지 적는다. ⚠️ 회차별은 송금일이 아니라 **회차 날짜**로 거른다.
function _transferRangePlaceholder() {
  return _transferMode === 'round' ? '회차 시작일~종료일' : '송금 시작일~종료일';
}
// 검색칸은 「전체」 목록에서만 쓴다 — 월별·회차별(상세 포함)에서는 잠그고 이유를 말한다(숨기지 않는다).
function _syncTransferSearchUi() {
  const rg = $('transferRange');
  if (rg) rg.placeholder = _transferRangePlaceholder();   // 도구 줄은 한 번만 그리므로 보기를 바꿀 때 여기서 맞춘다
  const el = $('transferSearchInput');
  if (!el) return;
  const on = _transferMode === 'list';
  el.disabled = !on;
  el.title = on ? '받는 사람 이름(한자·후리가나)·페이팔 이메일로 찾습니다'
    : '월별·회차별 합계는 서버가 낸 값이라 사람으로 거를 수 없습니다. 「전체」에서 검색하세요';
  el.style.opacity = on ? '' : '0.5';
  // ⚠️ 잠긴 칸에 검색어가 남아 보이면 월별·회차별 합계가 걸러진 것으로 읽힌다 — 잠긴 동안은 비워 보이고 「전체」에서 되살린다.
  el.value = on ? _transferSearch : '';
}
function onTransferSearch(v) {
  _transferSearch = (v || '').trim();
  _transferSearchTokens = _transferSearch.split(/[\s\u3000]+/).filter(Boolean).map(_payoutNorm);
  if (_transferMode === 'list' && !_transferDetail) _renderTransferBody();   // ⚠️ 도구 줄은 다시 그리지 않는다(포커스 유지)
}
// 묶음의 받는 사람 가나 — 묶음 조회에는 없어 정산 행(_settlements)의 회원 정보에서 찾는다.
function _transferKanaOf(t) {
  const items = Array.isArray(t.items) ? t.items : [];
  for (let i = 0; i < items.length; i++) {
    const s = (_settlements || []).find(function (x) { return x.id === items[i].settlement_id; });
    const k = s && s.influencers && s.influencers.name_kana;
    if (k) return k;
  }
  return null;
}

// 기간 칸의 「걸림」 표시와 × 버튼을 함께 맞춘다(기간이 있을 때만 × 가 보인다).
function _syncTransferRangeUi() {
  const on = !!(_transferFrom || _transferTo);
  const el = $('transferRange');
  if (el) el.classList.toggle('filter-active', on);
  const x = $('btnTransferRangeClear');
  if (x) x.style.display = on ? 'inline-flex' : 'none';
}

function _setupTransferRange() {
  const el = $('transferRange');
  if (!el || typeof flatpickr === 'undefined') return;
  const fmt = _settleFpDate;
  _transferFp = flatpickr(el, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    showMonths: 1,
    defaultDate: (_transferFrom && _transferTo) ? [_transferFrom, _transferTo] : undefined,
    onChange: function (d) {
      // 양끝을 다 골랐을 때만 조회한다(한쪽만 고른 중간 상태에서 조회하면 결과가 번쩍인다)
      if (d.length !== 2) return;
      _transferFrom = fmt(d[0]); _transferTo = fmt(d[1]);
      _syncTransferRangeUi();
      _transferDetail = null;
      _loadTransferHistory();
    },
  });
  _syncTransferRangeUi();
}

function clearTransferPeriod() {
  _transferFrom = ''; _transferTo = '';   // 빈 문자열 = 사용자가 일부러 비움(null 은 「기본 기간 아직 안 정함」)
  // ⚠️ clear(false) — 변경 이벤트를 안 일으킨다(인증 성공일 필터와 같은 함정)
  if (_transferFp) _transferFp.clear(false);
  _syncTransferRangeUi();
  _transferDetail = null;
  _loadTransferHistory();
}
function setTransferMode(m) {
  _transferMode = m;
  _transferDetail = null;   // 보기를 바꾸면 보던 상세에서 나온다
  _renderTransferToolbar();
  _renderTransferUnrecorded();
  _renderTransferBody();
}

async function _loadTransferHistory() {
  const seq = ++_transferLoadSeq;
  // 불러오는 동안 엑셀이 **옛 기간 데이터를 새 기간 이름으로** 내려받지 않게 비워 둔다
  _transferRows = undefined; _transferMonthly = undefined; _transferRound = undefined;
  _transferAllRows = undefined;   // 기간·기록이 바뀌었을 수 있다 — 회차별 상세는 다시 받는다
  const body = $('transferHistoryBody');
  if (body) body.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';
  const from = _transferFrom || null, to = _transferTo || null;
  const res = await Promise.all([
    fetchSettlementTransfers(from, to),
    fetchSettlementTransferMonthly(from, to),
    fetchSettlementTransferByRound(from, to),
    fetchSettlementTransferUnrecorded(),
    fetchSettlementFeeRule(),
    fetchSettlementFeeRuleHistoryAll(),
  ]);
  if (seq !== _transferLoadSeq) return;   // 그 사이 기간을 또 바꿨다 — 옛 응답은 버린다
  _transferRows = res[0]; _transferMonthly = res[1]; _transferRound = res[2]; _transferUnrecorded = res[3];
  _feeRuleTimeline = (res[4] && Array.isArray(res[5])) ? { current: res[4], history: res[5] } : null;
  // 받는 사람 페이팔은 **정산 행 스냅샷**에서 찾는다(묶음 표에는 페이팔 주소를 두지 않는다 — 363 파기)
  if (!_settlementsLoaded) { try { await reloadSettlementsData(); } catch (e) {} }
  _renderTransferUnrecorded();
  _renderTransferBody();
}

// 「수수료 기록 없음」 — 도입 전 송금(옛 경로)이라 묶음이 없는 송금완료 건. **0엔으로 더하지 않는다**
//   ⚠️ 서버(487)는 **기간 인자가 없다** — 전체 기간·상태 무관(송금완료·보류·취소)으로 센다. 문구가 그 사실을 말해야 한다(2026-10-01)
function _renderTransferUnrecorded() {
  const el = $('transferUnrecordedLine');
  if (!el) return;
  const u = _transferUnrecorded;
  if (u === undefined) { el.innerHTML = ''; return; }
  if (u === null) { el.innerHTML = '<div style="font-size:12px;color:#B8741A">「수수료 기록 없는 송금」 건수를 불러오지 못했습니다.</div>'; return; }
  const n = Number(u.unrecorded_count) || 0;
  if (!n) { el.innerHTML = ''; return; }
  el.innerHTML = `<div style="padding:8px 12px;background:#FFF7ED;border:1px solid #FDBA74;border-radius:8px;font-size:12px;line-height:1.6;color:#9A3412">
      <b>수수료 기록 없는 송금 ${n.toLocaleString('ja-JP')}건 · 보낸 금액 ${esc(settlementAmountYen(u.sent_total_jpy))} (전체 기간)</b>
      — 송금 묶음 기능이 생기기 전 방식으로 송금완료를 기록해 수수료가 없는 건입니다(그 뒤 보류·취소된 건 포함).
      위 기간 선택과 상관없이 전체 기간을 세며, 아래 합계에는 들어가지 않습니다. 과거 지급 시트를 옮겨 넣는 작업(예정) 때 채웁니다.
    </div>`;
}

function _transferFailHtml() {
  return '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">'
    + '<b style="color:var(--ink)">송금 내역을 불러오지 못했습니다.</b><br>조회가 실패한 것이라 <b>보낸 것이 없다는 뜻이 아닙니다</b>.<br>잠시 뒤 다시 열어 보세요.</div>';
}
function _transferEmptyHtml() {
  return '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">이 기간에 기록한 송금이 없습니다.</div>';
}

function _renderTransferBody() {
  const body = $('transferHistoryBody');
  if (!body) return;
  if (_transferDetail && _transferDetail.mode === _transferMode) { body.innerHTML = _transferDetailPageHtml(); return; }
  if (_transferMode === 'monthly') { body.innerHTML = _transferMonthlyHtml(); return; }
  if (_transferMode === 'round')   { body.innerHTML = _transferRoundHtml(); return; }
  body.innerHTML = _transferListHtml();
}

// 받는 사람은 송금 내역의 모든 표에서 **이름 · 페이팔 두 칸**으로 같게 보인다(2026-09-30 사용자 결정 — 표마다 달랐다).
//   ⚠️ 줄바꿈하지 않는다(nowrap). 페이팔은 정산 행 스냅샷에서 찾는다(_transferPaypalOf).
const _TRANSFER_PAYEE_HEAD = '<th style="width:130px">이름(한자)</th><th style="width:220px">페이팔</th>';
function _transferPayeeCells(name, paypal) {
  return `<td style="font-weight:600;white-space:nowrap">${esc(name || '(탈퇴한 회원)')}</td>
    <td style="font-size:11px;font-family:monospace;white-space:nowrap;color:var(--muted)">${paypal ? esc(paypal) : '—'}</td>`;
}

function _transferPaypalOf(t) {
  const items = Array.isArray(t.items) ? t.items : [];
  for (let i = 0; i < items.length; i++) {
    const s = (_settlements || []).find(function (x) { return x.id === items[i].settlement_id; });
    if (s && s.paypal_email) return s.paypal_email;
  }
  return null;
}

// 「추정」 배지 — 시트 소급(501)이 회차 지급일·수수료 규칙으로 채운 값(사양서 2026-10-01 결정 3·2).
//   ⚠️ 「추정」이라는 말은 배지·엑셀 열·툴팁에서 같게 쓴다.
const _TRANSFER_EST_TIP = '지급 시트에 값이 없어 회차 지급일·수수료 규칙으로 채운 값입니다. 「정정」에서 실제 값을 넣거나 「값이 맞음」을 체크하면 사라집니다';
function _transferEstBadge(on) {
  return on
    ? `<span title="${esc(_TRANSFER_EST_TIP)}" style="display:inline-block;margin-left:4px;font-size:10px;font-weight:600;line-height:1.4;padding:0 5px;border-radius:4px;background:#FFF4E5;color:#B45309;border:1px solid #F5C98A;white-space:nowrap;vertical-align:1px">추정</span>`
    : '';
}
// 수수료 칸 아래 줄 — 🔴 화면에 계산식을 두지 않는다(규칙 계산은 서버).
//   스냅샷이 없는 묶음(시트 합산 탭의 실제 수수료 — 결정 6)은 비교할 규칙이 없어 「지급 시트 실제값」으로 적는다.
// 그 송금의 요율 사본 → 「4.4% + ¥50」(화면·엑셀 공용). 사본이 비면 ''. 요율 끝의 0 은 뺀다(4.40 → 4.4)
function _transferRuleText(t) {
  if (!t || t.fee_rate_percent === null || t.fee_rate_percent === undefined || t.fee_fixed_jpy === null || t.fee_fixed_jpy === undefined) return '';
  return String(Number(t.fee_rate_percent)) + '% + ' + settlementAmountYen(Number(t.fee_fixed_jpy));
}
// 수수료 설정 시간표 — { current: 지금 설정, history: 변경 이력(오래된 순) }. 송금 내역을 받을 때 함께 받는다. 못 받으면 null
let _feeRuleTimeline = null;
// 그 시각에 적용되던 수수료 설정 { rate, fixed } — 그 시각 이전 마지막 변경의 「바뀐 값」, 변경 전이면 첫 변경의 「이전 값」,
//   변경 이력이 없으면 지금 설정. 시간표가 없으면 null(비교하지 않는다)
function _feeRuleAt(ts) {
  const tl = _feeRuleTimeline;
  if (!tl || !tl.current) return null;
  const h = tl.history || [];
  const at = ts ? Date.parse(ts) : NaN;
  if (!h.length || Number.isNaN(at)) return { rate: Number(tl.current.rate_percent), fixed: Number(tl.current.fixed_jpy) };
  let pick = null;
  h.forEach(function (e) { if (Date.parse(e.at) <= at) pick = e; });
  return pick ? { rate: Number(pick.next_rate_percent), fixed: Number(pick.next_fixed_jpy) }
              : { rate: Number(h[0].prev_rate_percent), fixed: Number(h[0].prev_fixed_jpy) };
}
// 기준보다 크면 파랑, 작으면 빨강, 같거나 기준을 모르면 그대로(회색) — 수수료 열 보조 줄의 색 규칙(2026-10-08 사용자 요청)
const TRANSFER_UP_COLOR = '#2563EB', TRANSFER_DOWN_COLOR = '#DC2626';
function _transferCmpSpan(text, v, base) {
  const c = (base === null || base === undefined || !Number.isFinite(base) || !Number.isFinite(v) || v === base) ? ''
    : (v > base ? TRANSFER_UP_COLOR : TRANSFER_DOWN_COLOR);
  return c ? `<span style="color:${c}">${esc(text)}</span>` : esc(text);
}
// 「4.4% + ¥50」 — 요율·고정액을 각각 그 송금 당시 수수료 설정과 비교해 색을 입힌다
function _transferRuleColoredHtml(t) {
  if (!_transferRuleText(t)) return '';
  const base = _feeRuleAt(t.recorded_at || t.sent_at);
  const r = Number(t.fee_rate_percent), x = Number(t.fee_fixed_jpy);
  return _transferCmpSpan(String(r) + '%', r, base ? base.rate : null) + ' + ' + _transferCmpSpan(settlementAmountYen(x), x, base ? base.fixed : null);
}
// ⚠️ 이 함수는 세 자리(목록·월별 상세·회차 상세)가 같이 부른다 — 여기만 고치면 셋이 함께 바뀐다.
//   보조 줄은 기본 회색이고, 색은 이 송금 요율·고정액(당시 설정보다 높으면 파랑 · 낮으면 빨강)에만.
//   「고친 값」(fee_manual)·「금액이 바뀐 뒤 손으로 고친 값」·「규칙 계산 · 차이」 줄은 없앴다(2026-10-08 사용자 결정 — 수수료 금액을
//   손으로 넣는 입력칸을 없앴고 운영 「고친 값」 송금 0건 확인). 칸(fee_manual·fee_stale·fee_rule_jpy)은 서버 응답에 그대로 있다.
//   「이 송금만」을 보일지는 서버 저장값(fee_rule_custom, 513)만 본다 — 화면의 비교는 **색**에만 쓴다(설정을 나중에 바꿔도
//   옛 송금 표시가 흔들리지 않게 — 비교 기준도 「지금 설정」이 아니라 그 송금 당시 설정이다. 사양서 2026-10-02-settlement-per-transfer-fee-rule 완료 기준 6).
function _transferFeeNoteHtml(t) {
  const lines = [];   // HTML 조각(글자는 이미 esc)
  const ruleHtml = t.fee_rule_custom ? _transferRuleColoredHtml(t) : '';
  if (ruleHtml) lines.push('요율 ' + ruleHtml + esc('(이 송금만)'));
  if (!t.fee_estimated && t.source === 'sheet_backfill' && (t.fee_rule_jpy === null || t.fee_rule_jpy === undefined)) {
    lines.push(esc('지급 시트 실제값'));
  }
  return lines.map(function (l) { return `<div style="font-size:10px;color:var(--muted);white-space:nowrap">${l}</div>`; }).join('');
}
// 엑셀 「수수료 요율」·「수수료 고정액」 두 칸 — 판정 순서(사양서 ②, 낱말은 작업표 결정 P3 「화면과 통일」):
//   ①사본이 빔 → 두 칸 「지급 시트 실제값」  ②그 밖 → 사본 값(이 송금 요율이면 끝에 「(이 송금만)」). 「고친 값」 갈래는 없앴다(2026-10-08)
function _transferRuleExcelCells(t) {
  const ruleTxt = _transferRuleText(t);
  if (!ruleTxt) return ['지급 시트 실제값', '지급 시트 실제값'];
  const tail = t.fee_rule_custom ? '(이 송금만)' : '';
  return [String(Number(t.fee_rate_percent)) + '%' + tail, settlementAmountYen(Number(t.fee_fixed_jpy)) + tail];
}

function _transferListHtml() {
  const all = _transferRows;
  if (all === undefined) return '';
  if (all === null) return _transferFailHtml();
  if (!all.length) return _transferEmptyHtml();
  const rows = _transferSearchTokens.length
    ? all.filter(function (t) {
        return payoutSearchHit([t.influencer_name, _transferKanaOf(t), _transferPaypalOf(t)], _transferSearchTokens);
      })
    : all;
  if (!rows.length) {
    return '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">'
      + '이 기간 송금 중 「' + esc(_transferSearch) + '」 로 찾은 받는 사람이 없습니다.<br>기간을 넓히거나 이름 표기를 확인해 주세요.</div>';
  }
  let sent = 0, fee = 0, cnt = 0, est = 0;
  rows.forEach(function (t) {
    sent += Number(t.sent_total_jpy) || 0; fee += Number(t.fee_jpy) || 0; cnt += (t.items || []).length;
    if (t.sent_at_estimated || t.fee_estimated) est += 1;
  });
  const canEdit = canWrite('settlement.pay');
  const body = rows.map(function (t) {
    const open = _transferOpen.has(t.id);
    const items = Array.isArray(t.items) ? t.items : [];
    const paypal = _transferPaypalOf(t);
    const feeNote = _transferFeeNoteHtml(t);
    // 펼친 내용 = 칸이 고정된 작은 표(2026-09-30 사용자 지적 — 줄바꿈·칸 어긋남·구분선 없음).
    //   ⚠️ 「보류 해제로 끊김」은 **상태 칸 하나**에만 적는다. 줄마다 칸 수가 달라지면 금액이 옆으로 밀린다.
    //   ⚠️ 날짜·금액 칸은 줄바꿈하지 않는다(nowrap) — 「지급 예정 2026-09-30」이 두 줄로 꺾였다.
    //   ⚠️ <table> 이 아니라 격자(grid)다 — 바깥 목록이 data-table 이라 안쪽 표가 그 머리글 색(흰 글자)·칸 세로줄을 물려받는다.
    const cols = 'display:grid;grid-template-columns:minmax(0,1fr) 120px 100px 130px;column-gap:12px;align-items:center;padding:7px 12px';
    const detail = open ? `<tr><td colspan="10" style="background:#FAFAFA;padding:10px 16px 12px 16px">
        <div style="background:#fff;border:1px solid var(--line);border-radius:8px;overflow:hidden">
          <div style="${cols};font-size:11px;font-weight:600;color:var(--muted);background:#F1F1F3;border-bottom:1px solid var(--line)">
            <div>캠페인</div><div style="white-space:nowrap">지급 예정(회차)</div><div style="text-align:right">금액</div><div>상태</div>
          </div>
          ${items.map(function (it, idx) {
            const line = idx === items.length - 1 ? '' : ';border-bottom:1px solid var(--line)';
            const off = it.is_current ? '' : ';color:var(--muted)';
            const strike = it.is_current ? '' : ';text-decoration:line-through';
            return `<div style="${cols};font-size:12px${line}${off}">
              <div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap${strike}" title="${esc(_bulkCampaignLabel(it.campaign_no, it.campaign_title))}">${esc(_bulkCampaignLabel(it.campaign_no, it.campaign_title))}</div>
              <div style="white-space:nowrap">${it.due_date ? esc(it.due_date) : _missingDash(_MISSING_CERT_TIP)}</div>
              <div style="text-align:right;white-space:nowrap${strike}">${esc(settlementAmountYen(it.amount_jpy))}</div>
              <div>${it.is_current ? '' : '<span style="font-size:11px;padding:2px 6px;border-radius:4px;background:#F4F4F5;white-space:nowrap">보류 해제로 끊김</span>'}</div>
            </div>`;
          }).join('')}
        </div>
        <div style="display:flex;gap:16px;flex-wrap:wrap;font-size:11px;color:var(--muted);margin-top:8px">
          ${t.memo ? `<span>메모: ${esc(t.memo)}</span>` : ''}
          <span>기록: ${esc(t.recorded_by_name || '(이름 미상)')} · ${esc(formatDateTime(t.recorded_at))}${t.source === 'sheet_backfill' ? ' · 지급 시트에서 채움' : ''}</span>
        </div>
      </td></tr>` : '';
    return `<tr style="cursor:pointer" onclick="toggleTransferRow('${esc(t.id)}')">
        <td style="width:28px"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">${open ? 'expand_less' : 'expand_more'}</span></td>
        <td style="white-space:nowrap">${esc(_settlementDateInputValue(t.sent_at))}${_transferEstBadge(t.sent_at_estimated)}</td>
        ${_transferPayeeCells(t.influencer_name, paypal)}
        <td style="text-align:right;white-space:nowrap">${items.length}건</td>
        <td style="text-align:right;font-weight:600;white-space:nowrap">${esc(settlementAmountYen(t.sent_total_jpy))}</td>
        <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(t.fee_jpy))}${_transferEstBadge(t.fee_estimated)}${feeNote}</td>
        <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(settlementAmountYen(t.total_spend_jpy))}</td>
        <td style="font-size:11px;font-family:monospace;white-space:nowrap">${esc(t.paypal_txn_id || '')}</td>
        <td onclick="event.stopPropagation()" style="white-space:nowrap">${canEdit
          ? `<button class="btn btn-ghost btn-xs" onclick="openTransferCorrectModal('${esc(t.id)}')">정정</button>`
          : ''}
          <button class="btn btn-ghost btn-xs" onclick="openTransferHistoryModal('${esc(t.id)}')" title="이 송금의 기록·정정 이력">이력</button></td>
      </tr>${detail}`;
  }).join('');
  return `<div class="admin-table-wrap"><table class="data-table">
      <thead><tr><th style="width:28px"></th><th style="width:130px">송금일</th>${_TRANSFER_PAYEE_HEAD}<th style="width:60px;text-align:right">건수</th>
        <th style="width:100px;text-align:right">보낸 금액</th><th style="width:210px;text-align:right">수수료</th><th style="width:100px;text-align:right">총지출</th>
        <th>페이팔 거래번호</th><th style="width:124px"></th></tr></thead>
      <tbody>${body}</tbody>
      <tfoot><tr class="transfer-foot"><td></td><td colspan="3" style="white-space:nowrap">합계 · 송금 ${rows.length}번${est ? ` <span style="font-weight:400;color:#B45309" title="${esc(_TRANSFER_EST_TIP)}">· 추정 포함 송금 ${est}번</span>` : ''}</td>
        <td style="text-align:right;white-space:nowrap">${cnt}건</td><td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(sent))}</td>
        <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(fee))}</td><td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(sent + fee))}</td>
        <td colspan="2"></td></tr></tfoot>
    </table></div>`;
}

function toggleTransferRow(id) {
  if (_transferOpen.has(id)) _transferOpen.delete(id); else _transferOpen.add(id);
  _renderTransferBody();
}

// opts.mode / opts.keyOf(r) — 줄마다 「상세」를 달고, 누르면 그 줄의 상세 화면으로 넘어간다(_transferDetailPageHtml).
function _transferSummaryTableHtml(rows, firstHead, firstCell, note, opts) {
  if (rows === undefined) return '';
  if (rows === null) return _transferFailHtml();
  if (!rows.length) return _transferEmptyHtml();
  let sent = 0, fee = 0, cnt = 0;
  rows.forEach(function (r) { sent += Number(r.sent_total_jpy) || 0; fee += Number(r.fee_jpy) || 0; cnt += Number(r.settlement_count) || 0; });
  return `${note ? `<div style="padding:8px 14px;font-size:12px;color:var(--muted)">${note}</div>` : ''}
    <div class="admin-table-wrap"><table class="data-table">
      <thead><tr><th>${firstHead}</th><th style="text-align:right">건수</th><th style="text-align:right">보낸 금액</th>
        <th style="text-align:right">수수료</th><th style="text-align:right">총지출</th><th style="width:80px"></th></tr></thead>
      <tbody>${rows.map(function (r) {
        const key = opts.keyOf(r);
        // estimated_count = 추정 표시가 있는 **송금(묶음) 수**(502) — 건수와 단위가 달라 「송금 N번」으로 적는다
        const estN = Number(r.estimated_count) || 0;
        const estHtml = estN ? ` <span style="font-size:11px;color:#B45309" title="${esc(_TRANSFER_EST_TIP)}">· 추정 포함 송금 ${estN}번</span>` : '';
        return `<tr><td style="white-space:nowrap">${firstCell(r)}${estHtml}</td><td style="text-align:right;white-space:nowrap">${Number(r.settlement_count) || 0}건</td>
          <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(r.sent_total_jpy))}</td>
          <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(r.fee_jpy))}</td>
          <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(settlementAmountYen(r.total_spend_jpy))}</td>
          <td><button class="btn btn-ghost btn-xs" style="white-space:nowrap" onclick="openTransferSumDetail('${opts.mode}','${esc(key)}')">상세</button></td></tr>`;
      }).join('')}</tbody>
      <tfoot><tr class="transfer-foot"><td>합계</td><td style="text-align:right;white-space:nowrap">${cnt}건</td>
        <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(sent))}</td><td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(fee))}</td>
        <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(sent + fee))}</td><td></td></tr></tfoot>
    </table></div>`;
}
function _transferMonthlyHtml() {
  return _transferSummaryTableHtml(_transferMonthly, '송금한 달', function (r) {
    const m = String(r.month || '').slice(0, 7);
    return m ? esc(m.replace('-', '년 ') + '월') : '—';
  }, '', {
    mode: 'monthly',
    keyOf: function (r) { return String(r.month || '').slice(0, 7); },
  });
}
function _transferRoundHtml() {
  // ⚠️ 기간을 넣으면 「지급일 기록 없음」(인증 성공일 없는 건) 줄이 빠진다 — 0건이어도 「보낸 것 없음」이 아니다
  if (Array.isArray(_transferRound) && !_transferRound.length && (_transferFrom || _transferTo)) {
    return '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">'
      + '이 기간(회차 날짜 기준)에 해당하는 송금이 없습니다.<br>'
      + '인증 성공일이 없는 건은 「지급일 기록 없음」으로 따로 모이는데, 그 줄은 <b>「전체 기간」에서만</b> 보입니다.</div>';
  }
  return _transferSummaryTableHtml(_transferRound, '지급 예정(회차)', function (r) {
    return r.due_date ? esc(r.due_date) : '<span style="color:var(--muted)">지급일 기록 없음</span>';
  }, '', {
    mode: 'round',
    keyOf: function (r) { return r.due_date ? String(r.due_date) : 'none'; },
  });
}

// ─── 월별·회차별 「상세」 화면 ──────────────────────────────────────────
function openTransferSumDetail(mode, key) {
  _transferDetail = { mode: mode, key: key };
  _renderTransferBody();
  // 회차별은 **회차 날짜**로 거르고 목록은 **송금일**로 거른다 — 기간을 넣었으면 그 회차 몫이 기간 밖 송금에 있을 수 있어
  //   전 기간 묶음을 따로 받는다(한 번 받아 두고, 기간이 바뀌면 _loadTransferHistory 가 비운다).
  if (mode === 'round' && (_transferFrom || _transferTo) && _transferAllRows === undefined) {
    const seq = _transferLoadSeq;
    fetchSettlementTransfers(null, null).then(function (rows) {
      if (seq !== _transferLoadSeq) return;
      _transferAllRows = rows;
      _renderTransferBody();
    });
  }
}
function backTransferSumDetail() {
  _transferDetail = null;
  _renderTransferBody();
}

// 상세 화면 — 머리(뒤로 · 제목 · 합계)는 고정, 표만 스크롤.
function _transferDetailPageHtml() {
  const d = _transferDetail;
  const isRound = d.mode === 'round';
  const title = isRound
    ? (d.key === 'none' ? '지급일 기록 없음' : esc(d.key) + ' 회차')
    : esc(d.key.replace('-', '년 ') + '월') + ' 송금';
  const src = isRound ? _transferRound : _transferMonthly;
  const row = Array.isArray(src) ? src.find(function (r) {
    return isRound ? ((r.due_date ? String(r.due_date) : 'none') === d.key) : (String(r.month || '').slice(0, 7) === d.key);
  }) : null;
  const sum = row
    ? `${Number(row.settlement_count) || 0}건 · 보낸 금액 <b>${esc(settlementAmountYen(row.sent_total_jpy))}</b> · 수수료 ${esc(settlementAmountYen(row.fee_jpy))} · 총지출 <b>${esc(settlementAmountYen(row.total_spend_jpy))}</b>`
    : '';
  return `<div style="display:flex;flex-direction:column;flex:1;min-height:0">
      <div style="flex-shrink:0;padding:14px 16px 12px;border-bottom:1px solid var(--line)">
        <div style="display:flex;align-items:center;gap:10px">
          <button class="btn btn-ghost btn-sm" onclick="backTransferSumDetail()" title="${isRound ? '회차별' : '월별'} 요약으로"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;vertical-align:-4px;margin-left:-4px">chevron_left</span>뒤로</button>
          <div style="font-weight:700;font-size:14px">${title}</div>
        </div>
        ${sum ? `<div style="font-size:12px;color:var(--muted);margin-top:8px">${sum}</div>` : ''}
      </div>
      <!-- 목록은 좌우 여백 없이 카드 폭을 다 쓴다. 머리글(th)은 이 스크롤 칸 기준으로 위에 붙는다(data-table 기본 sticky). -->
      <div style="flex:1;min-height:0;overflow-y:auto;background:#FAFAFA">
        ${isRound ? _transferRoundDetailHtml(d.key) : _transferMonthDetailHtml(d.key)}
      </div>
    </div>`;
}

// 상세 안의 작은 표 — 송금 한 번 = 한 줄. extra(t) 가 그 줄의 건수·금액·수수료 칸을 정한다.
function _transferDetailTableHtml(list, extra, note) {
  if (!list.length) return '<div style="padding:16px;font-size:12px;color:var(--muted)">이 줄에 해당하는 송금을 찾지 못했습니다.</div>';
  // ⚠️ 머리글 고정은 .admin-pane-list .data-table th 의 sticky 에 기댄다 — th 에 position:static 을 주면 풀린다.
  return `${note ? `<div style="padding:8px 16px;font-size:11px;color:var(--muted);background:#fff;border-bottom:1px solid var(--line)">${note}</div>` : ''}
    <table class="data-table" style="width:100%">
      <thead><tr><th style="width:130px">송금일</th>${_TRANSFER_PAYEE_HEAD}<th>캠페인</th>
        <th style="width:70px;text-align:right">건수</th><th style="width:110px;text-align:right">보낸 금액</th>
        <th style="width:150px;text-align:right">수수료</th><th style="width:150px">페이팔 거래번호</th></tr></thead>
      <tbody>${list.map(function (t) {
        const x = extra(t);
        return `<tr><td style="white-space:nowrap">${esc(_settlementDateInputValue(t.sent_at))}${_transferEstBadge(t.sent_at_estimated)}</td>
          ${_transferPayeeCells(t.influencer_name, _transferPaypalOf(t))}
          <td style="font-size:12px;line-height:1.7">${x.campaigns}</td>
          <td style="text-align:right;white-space:nowrap">${x.count}건</td>
          <td style="text-align:right;white-space:nowrap">${esc(settlementAmountYen(x.sent))}</td>
          <td style="text-align:right">${x.feeHtml}</td>
          <td style="font-size:11px;font-family:monospace;white-space:nowrap">${esc(t.paypal_txn_id || '')}</td></tr>`;
      }).join('')}</tbody>
    </table>`;
}
function _transferItemCampaigns(items) {
  return items.map(function (it) {
    const label = esc(_bulkCampaignLabel(it.campaign_no, it.campaign_title));
    return `<div style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:420px" title="${label}">${label}</div>`;
  }).join('');
}

// 월별 상세 — 그 달(송금일, 일본 날짜)에 보낸 묶음. 월별 합계와 같은 기간으로 받은 목록에서 고른다.
function _transferMonthDetailHtml(ym) {
  const rows = _transferRows;
  if (rows === undefined) return '<div style="padding:16px;font-size:12px;color:var(--muted)">불러오는 중…</div>';
  if (rows === null) return '<div style="padding:16px;font-size:12px;color:#B8741A">송금 목록을 불러오지 못했습니다.</div>';
  const list = rows.filter(function (t) { return _settlementDateInputValue(t.sent_at).slice(0, 7) === ym; });
  return _transferDetailTableHtml(list, function (t) {
    const items = Array.isArray(t.items) ? t.items : [];
    return { campaigns: _transferItemCampaigns(items), count: items.length, sent: t.sent_total_jpy,
             feeHtml: esc(settlementAmountYen(t.fee_jpy)) + _transferEstBadge(t.fee_estimated) + _transferFeeNoteHtml(t) };
  });
}

// 회차별 상세 — 그 회차 건이 든 묶음. 금액·건수는 **그 회차 건만**, 수수료는 서버 규칙(487 [4])대로
//   **묶음 안 가장 늦은 회차**에만 붙는다 — 다른 회차로 간 수수료는 「—」로 두고 어느 회차인지 알린다.
//   ⚠️ 연결 행은 보류 해제로 끊긴 옛 건까지 전부 센다(회차 합계와 같은 기준).
function _transferRoundDetailHtml(key) {
  const rows = (_transferFrom || _transferTo) ? _transferAllRows : _transferRows;
  if (rows === undefined) return '<div style="padding:16px;font-size:12px;color:var(--muted)">불러오는 중…</div>';
  if (rows === null) return '<div style="padding:16px;font-size:12px;color:#B8741A">송금 목록을 불러오지 못했습니다.</div>';
  const due = key === 'none' ? null : key;
  const list = [];
  rows.forEach(function (t) {
    const items = Array.isArray(t.items) ? t.items : [];
    const mine = items.filter(function (it) { return (it.due_date || null) === due; });
    if (mine.length) list.push({ t: t, mine: mine, items: items });
  });
  const byId = {};
  list.forEach(function (x) { byId[x.t.id] = x; });
  return _transferDetailTableHtml(list.map(function (x) { return x.t; }), function (t) {
    const x = byId[t.id];
    const dues = x.items.map(function (it) { return it.due_date; }).filter(Boolean).sort();
    const feeRound = dues.length ? dues[dues.length - 1] : null;
    const sent = x.mine.reduce(function (a, it) { return a + (Number(it.amount_jpy) || 0); }, 0);
    const feeHtml = feeRound === due
      ? esc(settlementAmountYen(t.fee_jpy)) + _transferEstBadge(t.fee_estimated) + _transferFeeNoteHtml(t)
      : `<span style="color:var(--muted)" title="이 묶음의 수수료는 가장 늦은 회차(${esc(feeRound || '지급일 기록 없음')})에 들어갑니다">— <span style="font-size:10px">(${esc(feeRound || '기록 없음')} 회차에)</span></span>`;
    return { campaigns: _transferItemCampaigns(x.mine), count: x.mine.length, sent: sent, feeHtml: feeHtml };
  }, '보낸 금액·건수는 <b>이 회차 건만</b> 셉니다. 여러 회차를 합쳐 보낸 묶음의 수수료는 가장 늦은 회차에만 들어갑니다.');
}

// 엑셀 — 시트 둘(송금 내역 한 줄 = 송금 한 번 / 포함 건). 수수료 합 = 화면 합(같은 저장값)
async function exportTransferHistoryExcel() {
  const rows = _transferRows;
  if (rows === null) { toast('송금 내역을 불러오지 못해 내려받을 수 없습니다', 'warn'); return; }
  if (rows === undefined) { toast('아직 불러오는 중입니다 — 잠시 뒤 다시 눌러 주세요', 'warn'); return; }
  if (!Array.isArray(rows) || !rows.length) { toast('내려받을 송금 내역이 없습니다', 'warn'); return; }
  try {
    await loadExcelJS();
    const wb = new ExcelJS.Workbook();
    const ws1 = wb.addWorksheet('송금 내역');
    // ⚠️ 열 위치가 넷(폭·머리글·합계 줄·숫자 형식 열 번호)에 묶여 있다 — 열을 끼우면 넷을 함께 고친다
    ws1.columns = [12, 18, 30, 8, 12, 10, 22, 22, 10, 10, 12, 22, 30].map(function (w) { return { width: w }; });
    ws1.addRow(['송금 내역 · 송금일 ' + (_transferFrom || '처음') + ' ~ ' + (_transferTo || '지금') + ' · 내려받은 시각 ' + formatDateTime(new Date())]).font = { bold: true };
    ws1.addRow([]);
    ws1.addRow(['송금일', '이름(한자)', '페이팔', '건수', '보낸 금액', '수수료', '수수료 요율', '수수료 고정액', '송금일 추정', '수수료 추정', '총지출', '페이팔 거래번호', '메모']).font = { bold: true };
    const ws2 = wb.addWorksheet('포함 건');
    ws2.columns = [12, 18, 14, 34, 12, 12, 10].map(function (w) { return { width: w }; });
    ws2.addRow(['송금일', '이름(한자)', '캠페인 번호', '캠페인', '지급 예정(회차)', '보낸 금액', '현재 연결']).font = { bold: true };
    let sent = 0, fee = 0;
    rows.forEach(function (t) {
      const day = _settlementDateInputValue(t.sent_at);
      const items = Array.isArray(t.items) ? t.items : [];
      sent += Number(t.sent_total_jpy) || 0; fee += Number(t.fee_jpy) || 0;
      ws1.addRow([day, t.influencer_name || '(탈퇴한 회원)', _transferPaypalOf(t) || '', items.length,
        Number(t.sent_total_jpy) || 0, Number(t.fee_jpy) || 0].concat(_transferRuleExcelCells(t), [
        t.sent_at_estimated ? '예' : '', t.fee_estimated ? '예' : '', Number(t.total_spend_jpy) || 0,
        t.paypal_txn_id || '', t.memo || '']));
      items.forEach(function (it) {
        ws2.addRow([day, t.influencer_name || '(탈퇴한 회원)', it.campaign_no || '', it.campaign_title || '',
          it.due_date || '기록 없음', Number(it.amount_jpy) || 0, it.is_current ? '예' : '보류 해제로 끊김']);
      });
    });
    ws1.addRow(['합계', '', '', '', sent, fee, '', '', '', '', sent + fee, '', '']).font = { bold: true };
    [5, 6, 11].forEach(function (c) { ws1.getColumn(c).numFmt = '#,##0'; });
    ws2.getColumn(6).numFmt = '#,##0';
    await _payoutExcelSaveWorkbook(wb, 'transfers-' + (_transferFrom || 'all') + '-' + (_transferTo || 'now') + '-' + rows.length + '.xlsx');
  } catch (e) {
    toast('엑셀을 만들지 못했습니다 — ' + friendlyError(e.message || e), 'error');
  }
}

// ── 묶음 정정 (correct_settlement_transfer · 486) ──────────────────────
//   송금일·수수료(요율·고정액으로만 — 금액 직접 입력은 2026-10-08 없앴다)·거래번호·메모. **바꾼 칸만** 보낸다(서버: NULL = 안 고침, '' = 비움).
//   ⚠️ 송금일을 고치면 이 묶음에 현재 연결된 건들의 송금일도 함께 바뀐다(서버가 한다).
//   ⚠️ 「추정」 칸에는 「값이 맞음(추정 해제)」 체크가 붙는다 — 체크하면 **같은 값이라도** 그 칸을 보내 추정 표시만 지운다
//      (서버 502: 같은 수수료면 fee_manual 을 안 건드린다 — 사양서 결정 7).
let _transferCorrectCtx = null;

function _ensureTransferCorrectModal() {
  let el = $('transferCorrectModal');
  if (el) return el;
  el = document.createElement('div');
  el.className = 'modal-overlay';
  el.id = 'transferCorrectModal';
  el.style.zIndex = '615';
  el.innerHTML = `
    <div class="modal" style="max-width:480px;border-radius:20px;margin:auto">
      <div class="modal-header" style="padding:18px 22px 12px;border-bottom:1px solid var(--line)">
        <div style="font-size:16px;font-weight:700;color:var(--ink)">송금 묶음 정정</div>
      </div>
      <div class="modal-body" id="transferCorrectBody" style="padding:18px 22px"></div>
      <div style="padding:14px 22px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end">
        <button class="btn btn-ghost" onclick="closeTransferCorrectModal()">취소</button>
        <button class="btn btn-primary" id="transferCorrectSaveBtn" onclick="saveTransferCorrect()">정정 저장</button>
      </div>
    </div>`;
  document.body.appendChild(el);
  return el;
}

// row — 회차 상세에서 열 때 따로 받아 온 묶음 행(송금 내역 캐시 _transferRows 에 넣지 않는다 — 엑셀이 그 값을 쓴다)
// from — 'transfer'(송금 내역) | 'payout'(회차별·사람별 상세)
// 수수료 칸은 확인 창과 같은 배치(2026-10-08 사용자 결정) — 「직접 지정」 옆에 요율·고정액, 수수료 금액은 직접 고치지 않는다
function openTransferCorrectModal(id, row, from) {
  if (!canWrite('settlement.pay')) { toast('변경 권한이 없습니다', 'warn'); return; }
  const t = row || (_transferRows || []).find(function (x) { return x.id === id; });
  if (!t) { toast('송금 묶음을 찾을 수 없습니다', 'warn'); return; }
  _ensureTransferCorrectModal();
  const day = _settlementDateInputValue(t.sent_at);
  _transferCorrectCtx = { id: t.id, version: t.version, day: day, fee: Number(t.fee_jpy), txn: t.paypal_txn_id || '', memo: t.memo || '',
                          from: from || 'transfer',
                          dayEst: !!t.sent_at_estimated, feeEst: !!t.fee_estimated,
                          // 「이 송금 요율 직접 정하기」(사양서 2026-10-02-settlement-per-transfer-fee-rule 설계 ⓪ — 정본)
                          total: Number(t.sent_total_jpy), rate0: t.fee_rate_percent, fixed0: t.fee_fixed_jpy,
                          rounding: t.fee_rounding || null, ruleOn: false, rate: '', fixed: '', ruleSeq: 0 };
  const estChk = function (id, on) {
    return on ? `<label style="display:flex;align-items:center;gap:6px;font-size:12px;margin-top:6px;cursor:pointer">
        <input type="checkbox" id="${id}"> 값이 맞음(추정 해제) ${_transferEstBadge(true)}</label>` : '';
  };
  const current = (Array.isArray(t.items) ? t.items : []).filter(function (it) { return it.is_current; }).length;
  $('transferCorrectBody').innerHTML = `
    <div style="font-size:13px;margin-bottom:12px"><b>${esc(t.influencer_name || '(탈퇴한 회원)')}</b> · 보낸 금액 ${esc(settlementAmountYen(t.sent_total_jpy))}</div>
    <div class="form-group"><label class="form-label">송금일</label>
      <input type="date" id="transferCorrectDate" class="form-input" value="${esc(day)}" max="${esc(jstTodayStr())}">
      <div style="font-size:11px;color:var(--muted);margin-top:4px">바꾸면 이 송금에 들어 있는 ${current}건의 송금일도 함께 바뀝니다.</div>
      ${estChk('transferCorrectDateOk', t.sent_at_estimated)}</div>
    <div class="form-group"><label class="form-label">수수료</label>
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;padding:8px 10px;background:#FAFAFA;border:1px solid var(--line);border-radius:8px;font-size:12px">
        <div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
          <label style="display:inline-flex;align-items:center;gap:4px;cursor:pointer;white-space:nowrap" title="이 송금만 요율·고정액을 직접 정합니다">
            <input type="checkbox" id="transferCorrectRuleChk" onchange="onTransferRuleToggle(this.checked)"> 직접 지정
          </label>
          <span id="transferCorrectRuleInputs" style="display:none;align-items:center;gap:6px">
            <span>요율</span><input type="number" id="transferCorrectRate" class="admin-input" min="0" max="100" step="0.01" oninput="onTransferRuleInput('rate', this.value)" style="width:76px;text-align:right;box-sizing:border-box" aria-label="이 송금 요율(%)"><span>%</span>
            <span>고정액</span><input type="number" id="transferCorrectFixed" class="admin-input" min="0" step="1" oninput="onTransferRuleInput('fixed', this.value)" style="width:76px;text-align:right;box-sizing:border-box" aria-label="이 송금 고정액(엔)"><span>엔</span>
          </span>
        </div>
        <span id="transferCorrectFeeShow" style="font-size:14px;font-weight:700;white-space:nowrap">${esc(settlementAmountYen(t.fee_jpy))}</span>
      </div>
      <div style="font-size:11px;color:var(--muted);margin-top:4px">지금 ${(t.source === 'sheet_backfill' && !t.fee_estimated && (t.fee_rule_jpy === null || t.fee_rule_jpy === undefined) ? '지급 시트 실제값' : (t.fee_rule_custom ? '이 송금 요율로 계산한 값' : '자동 계산값'))}입니다.</div>
      <div id="transferCorrectRuleNote" style="font-size:11px;color:var(--muted);margin-top:2px;display:none">저장하면 이 요율로 수수료를 다시 계산합니다. 이 송금에만 적용됩니다 — 앞으로의 모든 송금은 <a href="javascript:void(0)" onclick="openFeeRuleFromChild(_scheduleTransferRulePreview)" style="color:#2563EB">수수료 설정</a>에서 바꿉니다.</div>
      <div id="transferCorrectRateWarn" style="font-size:11px;color:#B8741A;margin-top:2px;display:none">요율이 10%를 넘습니다. 맞는지 확인해 주세요</div>
      ${estChk('transferCorrectFeeOk', t.fee_estimated)}</div>
    <div class="form-group"><label class="form-label">페이팔 거래번호</label>
      <input type="text" id="transferCorrectTxn" class="form-input" maxlength="100" value="${esc(t.paypal_txn_id || '')}"></div>
    <div class="form-group"><label class="form-label">메모</label>
      <input type="text" id="transferCorrectMemo" class="form-input" value="${esc(t.memo || '')}"></div>`;
  const b = $('transferCorrectSaveBtn'); if (b) b.disabled = false;
  openModal('transferCorrectModal');
}

function closeTransferCorrectModal() { closeModal('transferCorrectModal'); _transferCorrectCtx = null; }

// 체크 칸 — 켜면 처음 값 = 그 송금 사본(비었으면 설정 규칙, R4), 「값이 맞음」은 끄고 흐리게(작업표 결정 P1).
//   끄면 요율 칸을 비우고 수수료 표시를 창을 열 때 값으로 되돌린다(R3)
async function onTransferRuleToggle(on) {
  const ctx = _transferCorrectCtx; if (!ctx) return;
  const fee = $('transferCorrectFeeShow'), rate = $('transferCorrectRate'), fixed = $('transferCorrectFixed');
  const feeOk = $('transferCorrectFeeOk');
  ctx.ruleOn = !!on;
  ctx.ruleSeq++;
  if (on) {
    let r = ctx.rate0, x = ctx.fixed0;
    if (r === null || r === undefined || x === null || x === undefined) {
      const seq = ctx.ruleSeq;
      const rule = await fetchSettlementFeeRule();
      if (ctx !== _transferCorrectCtx || seq !== ctx.ruleSeq) return;
      // ⚠️ 못 받았으면 비워 둔다 — 0 으로 채우면(Number('') 함정) 수수료 0 으로 저장된다
      r = rule ? rule.rate_percent : ''; x = rule ? rule.fixed_jpy : '';
    }
    ctx.rate = (r === null || r === undefined) ? '' : String(r);
    ctx.fixed = (x === null || x === undefined) ? '' : String(x);
    if (fee) fee.textContent = '계산 중…';
    if (feeOk) { feeOk.checked = false; feeOk.disabled = true; if (feeOk.parentElement) feeOk.parentElement.style.opacity = '.45'; }
  } else {
    ctx.rate = ''; ctx.fixed = '';
    if (fee) fee.textContent = settlementAmountYen(ctx.fee);
    if (feeOk) { feeOk.disabled = false; if (feeOk.parentElement) feeOk.parentElement.style.opacity = ''; }
  }
  if (rate)  rate.value = ctx.rate;
  if (fixed) fixed.value = ctx.fixed;
  const box = $('transferCorrectRuleInputs'); if (box) box.style.display = on ? 'inline-flex' : 'none';
  const note = $('transferCorrectRuleNote'); if (note) note.style.display = on ? '' : 'none';
  const w = $('transferCorrectRateWarn'); if (w) w.style.display = _ruleRateWarn(ctx.ruleOn, ctx.rate) ? '' : 'none';
  if (on) _scheduleTransferRulePreview();
}
function onTransferRuleInput(field, v) {
  const ctx = _transferCorrectCtx; if (!ctx || !ctx.ruleOn) return;
  ctx[field] = v;
  const w = $('transferCorrectRateWarn'); if (w) w.style.display = _ruleRateWarn(ctx.ruleOn, ctx.rate) ? '' : 'none';
  _scheduleTransferRulePreview();
}
// 정정 창 미리보기 — 그 묶음 사본 끝수를 함께 보내 저장 값과 같게 한다(사양서 ② 정정 창). 늦게 온 응답은 순번으로 버린다
let _transferRuleTimer = null;
function _scheduleTransferRulePreview() {
  const ctx = _transferCorrectCtx; if (!ctx || !ctx.ruleOn) return;
  if (_transferRuleTimer) clearTimeout(_transferRuleTimer);
  const seq = ++ctx.ruleSeq;
  _transferRuleTimer = setTimeout(async function () {
    if (ctx !== _transferCorrectCtx || seq !== ctx.ruleSeq) return;
    const fee = $('transferCorrectFeeShow');
    if (ctx.rate === '' || ctx.fixed === '') { if (fee) fee.textContent = '요율·고정액을 넣어 주세요'; return; }
    const res = await previewSettlementFees([ctx.total], { rates: [ctx.rate], fixeds: [ctx.fixed], roundings: [ctx.rounding] });
    if (ctx !== _transferCorrectCtx || seq !== ctx.ruleSeq || !fee) return;
    const v = res && Array.isArray(res.fees) ? res.fees[0] : null;
    fee.textContent = (v === null || v === undefined) ? '계산 못 함' : settlementAmountYen(v);
  }, 300);
}

async function saveTransferCorrect() {
  const ctx = _transferCorrectCtx;
  if (!ctx) return;
  const day = ($('transferCorrectDate')?.value || '').trim();
  const txn = ($('transferCorrectTxn')?.value || '').trim();
  const memo = ($('transferCorrectMemo')?.value || '').trim();
  if (!day) { toast('송금일을 넣어 주세요', 'warn'); return; }
  const ruleOn = !!ctx.ruleOn;
  const rate = ruleOn ? Number(ctx.rate) : null;
  const fixed = ruleOn ? Number(ctx.fixed) : null;
  if (ruleOn && (ctx.rate === '' || ctx.fixed === '' || !Number.isFinite(rate) || rate < 0 || rate > 100 || !Number.isInteger(fixed) || fixed < 0)) {
    toast('요율은 0~100%, 고정액은 0엔 이상 정수로 넣어 주세요', 'warn'); return;
  }
  // 바꾼 칸만 보낸다 — NULL 은 「안 고침」, 빈 문자열은 「비움」(거래번호·메모)
  // 「값이 맞음」을 체크한 추정 칸은 같은 값이라도 보낸다 — 서버가 그 칸의 추정 표시만 지운다
  const dayOk = ctx.dayEst && !!$('transferCorrectDateOk')?.checked;
  const feeOk = ctx.feeEst && !!$('transferCorrectFeeOk')?.checked;
  const sentAt = (day !== ctx.day || dayOk) ? _settlementJstMidnight(day) : null;
  // 수수료 금액은 직접 고치지 않는다(2026-10-08 사용자 결정) — 체크 칸이 켜져 있으면 요율·고정액만(R1 — 값이 같아도 보낸다).
  //   꺼져 있을 때 금액을 보내는 것은 「값이 맞음(추정 해제)」뿐(같은 값 — 서버가 추정 표시만 지운다). 켜면 그 칸은 못 쓴다(P1)
  const feeArg = (!ruleOn && feeOk) ? ctx.fee : null;
  const txnArg = txn !== ctx.txn ? txn : null;
  const memoArg = memo !== ctx.memo ? memo : null;
  if (!ruleOn && sentAt === null && feeArg === null && txnArg === null && memoArg === null) { toast('바꾼 칸이 없습니다', 'warn'); return; }
  const btn = $('transferCorrectSaveBtn'); if (btn) btn.disabled = true;
  try {
    const v = await correctSettlementTransfer(ctx.id, ctx.version, sentAt, feeArg, txnArg, memoArg, rate, fixed);
    if (v === -1) toast('다른 관리자가 먼저 고쳤습니다. 목록을 새로 받습니다.', 'warn');
    else toast('송금 묶음을 정정했습니다.');
  } catch (e) {
    toast('정정 실패 — ' + friendlyError(e.message || e), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  closeTransferCorrectModal();
  if (ctx.from === 'payout') {            // 회차 상세에서 열었으면 그 화면만 다시 그린다(송금 내역은 안 보인다)
    await _settlementRefreshKeepingView('payout');
    return;
  }
  await refreshPane('settlements');       // 정산 행의 송금일이 바뀌었을 수 있다
  await _loadTransferHistory();
}
