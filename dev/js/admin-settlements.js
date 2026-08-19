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
// 헬퍼는 전부 기존 공용(imgThumb·getRecruitTypeBadgeKoSm — ui.js / campPreviewBtn — lib/shared.js).
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
  // ★ 이번 진입에서 열 화면. **여기서 꺼내 즉시 비운다**(한 번 쓰고 버리는 값).
  const entryView = _settlementEntryView;
  _settlementEntryView = null;
  // 재진입 시 열려 있던 화면을 정리한다 — 안 닫으면 **옛 데이터가 그대로** 남는다.
  if ($('settlementPastView') && $('settlementPastView').style.display !== 'none') {
    closePastUnregView();
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
  //   ⚠️ 돌아가는 길은 그 화면 상단의 「← 정산 목록」 버튼이다(closePayoutPrepView).
  //   ⚠️ 조회 실패해도 화면 전환은 그대로 둔다 — 그 화면이 실패를 스스로 알린다.
  //   ⚠️ 다만 **부르는 쪽이 열 화면을 지정했으면 그쪽을 따른다**(`_settlementEntryView`).
  //      사이드바의 배지·경고 표시처럼 「이 목록을 보여 달라」고 들어오는 경로가 있는데,
  //      여기서 무조건 지급 준비를 켜면 그 요청이 조용히 덮인다.
  if (entryView === 'unregistered') {
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
  _settlementFilters.status = btn.dataset.status || '';
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
  // 상태 탭 바는 계속 보여야 하므로 메인 뷰의 **목록 부분만** 감춘다.
  const listCard = $('settlementListCard');
  if (listCard) listCard.style.display = 'none';
  past.style.display = 'flex';
  if (main) main.style.display = 'flex';
  const notice = $('unregisteredNotice');
  if (notice) notice.style.display = '';
  renderSettlementStatusTabs();
  applyUnregisteredNotice();
  loadPastUnregSettlements();
}

function hideUnregisteredTab() {
  const past = $('settlementPastView');
  if (past && past.style.display !== 'none') {
    if (pastUnregLazy) { pastUnregLazy.destroy(); pastUnregLazy = null; }
    past.style.display = 'none';
  }
  const listCard = $('settlementListCard');
  if (listCard) listCard.style.display = '';
  const notice = $('unregisteredNotice');
  if (notice) notice.style.display = 'none';
}

// 탭 아래 안내 한 줄. ⚠️ **도입일 설정 전후로 문구가 달라야 한다**(사양서 §4-2) —
//   도입일이 비어 있는 동안은 자동 등록이 **구조적으로 0건**이라, 「자동으로 만들어진다」고
//   쓰면 그 자체가 거짓말이 된다. 판정은 `cutoff_at` 유무 **한 곳에서만** 한다.
async function applyUnregisteredNotice() {
  const el = $('unregisteredNotice');
  if (!el) return;
  let cutoff;
  try { cutoff = await fetchSettlementCutoff(); } catch (e) { cutoff = undefined; }
  if (cutoff === undefined) {
    // ⚠️ 조회 실패를 「도입일 없음」으로 단정하지 않는다 — 문구가 반대가 된다.
    el.textContent = '인증에 성공했지만 아직 정산 행이 만들어지지 않은 건입니다.';
    return;
  }
  el.innerHTML = cutoff
    ? '인증에 성공했지만 아직 정산 행이 만들어지지 않은 건입니다. 이 화면에 들어오면 도입일 이후 건은 자동으로 만들어지며, <b>금액을 정할 수 없는 건</b>만 여기 남습니다.'
    : '인증에 성공했지만 아직 정산 행이 만들어지지 않은 건입니다. <b>지금은 자동 등록이 꺼져 있어 손으로 등록해야 합니다.</b>';
}

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

function openSettlementCorrectModal(id) {
  const s = _settlements.find(x => x.id === id);
  if (!s) { toast('정산 건을 찾을 수 없습니다', 'warn'); return; }
  if (s.status !== 'paid') { toast('송금완료 건만 정정할 수 있습니다', 'warn'); return; }
  _settlementModalCtx = { id: s.id, version: s.version, mode: 'correct' };

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
      </div>`;
  }
  const dateEl = $('settlementCorrectDate');
  if (dateEl) { dateEl.value = ''; dateEl.max = jstTodayStr(); }
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
  await refreshPane('settlements');
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
let _bulkPayCtx = null;   // {settlementIds:[], applicationIds:[], from:'list'|'payout', summaryHtml}

function _openBulkPayModal() {
  const body = $('settlementBulkPayBody');
  if (body) body.innerHTML = (_bulkPayCtx && _bulkPayCtx.summaryHtml) || '';
  const dateEl = $('settlementBulkPayDate');
  if (dateEl) { dateEl.value = ''; dateEl.max = jstTodayStr(); }
  const memoEl = $('settlementBulkPayMemo');
  if (memoEl) memoEl.value = '';
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
  if (btn) btn.disabled = !memo;
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
  const paidAt = _settlementJstMidnight(($('settlementBulkPayDate')?.value || '').trim());
  const btn = $('settlementBulkPayConfirmBtn');
  if (btn) btn.disabled = true;

  let done = 0;
  const skipped = [];
  const failed = [];

  // ① 정산 행이 이미 있는 건 — 상태만 송금완료로
  if (ctx.settlementIds.length) {
    try {
      const r = await markSettlementsPaidBulk(ctx.settlementIds, paidAt, memo);
      done += r.paid;
      if (r.skippedNoPaypal)   skipped.push(`PayPal 미등록 ${r.skippedNoPaypal}건`);
      if (r.skippedNotPending) skipped.push(`이미 처리됨·보류·취소 ${r.skippedNotPending}건`);
      if (r.notFound)          skipped.push(`사라진 건 ${r.notFound}건`);
    } catch (e) { failed.push('정산대기 건: ' + friendlyError(e.message || e)); }
  }

  // ② 아직 정산 행이 없는 건 — 송금완료 상태로 새로 만든다
  //    ⚠️ 한쪽이 실패해도 다른 쪽은 이미 처리됐을 수 있다. **되돌리지 않고 그대로 알린다** —
  //       조용히 삼키면 「눌렀는데 절반만 됐다」를 아무도 모른다.
  if (ctx.applicationIds.length) {
    try {
      const r = await registerPastSettlements(ctx.applicationIds, 'paid', memo, paidAt);
      done += r.registered;
      if (r.skippedNoPaypal) skipped.push(`PayPal 미등록 ${r.skippedNoPaypal}건(미등록분)`);
    } catch (e) { failed.push('미등록 건: ' + friendlyError(e.message || e)); }
  }

  if (failed.length && !done) {
    toast('기록 실패 — ' + failed.join(' / '), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  const tail = []
    .concat(skipped.length ? ['건너뜀 — ' + skipped.join(' · ')] : [])
    .concat(failed.length  ? ['실패 — ' + failed.join(' / ')] : []);
  toast(`${done}건을 송금완료로 기록했습니다.` + (tail.length ? ' ' + tail.join(' / ') : ''),
        tail.length ? 'warn' : 'success');

  closeModal('settlementBulkPayModal');
  // 처리한 선택은 비운다 — 남겨 두면 「선택 3묶음 · 0건 · ¥0」 처럼 뜻 없는 줄이 남는다.
  //   ⚠️ 회차 상세로 돌아가는 경로는 openPayoutPersonList() 가 어차피 비우지만, 전 기간
  //      화면에서 처리하면 그 경로를 안 타므로 여기서 직접 비운다.
  if (ctx.from === 'list') _settlementSelected.clear();
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
  await refreshPane('settlements');
  if (from !== 'payout') return;          // 목록 경로는 목록만 다시 그리면 된다
  await openPayoutPrepView();             // _payoutRows 재계산 + 요약 재렌더
  if (due) await openPayoutPersonList(due);
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
      // [338·339] 실제로 보낸 금액. ⚠️ 빈 칸은 「계산 금액과 같음」이지 0원이 아니다 —
      //   Number(null) 이 0 이라 그냥 넘기면 「0엔을 보냈다」로 읽힌다(299 때와 같은 함정).
      { header: '실제송금액(¥)', key: 'paidamt', width: 14 },
      { header: '계산액과다름', key: 'amtdiff',  width: 12 },
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
  _settlementFilters.status = 'unregistered';
  showUnregisteredTab();
}

function _legacyOpenPastUnregView_unused() {
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

async function pastUnregRegister(targetStatus) {
  if (settlementBulkLocked()) return;   // ★ 3단계 전 확정 기록 차단
  // 금액 미확정 건은 서버가 건너뛰므로 여기서도 제외(체크박스는 이미 잠겨 있지만 이중 방어)
  const rows = [..._pastUnregSelected]
    .map(id => _pastUnregById[id])
    .filter(r => r && !pastUnregHasIssue(r));
  const ids = rows.map(r => r.application_id);
  if (!ids.length) { toast('선택된 건이 없습니다', 'warn'); return; }
  const sum = rows.reduce((n, r) => n + settlementEffectiveAmount(r), 0);
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
      certAt: r.cert_at,          // 결과물 최종 승인(인증 성공) 시각
      amount: settlementEffectiveAmount(r),
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
      certAt: s.cert_at,          // 결과물 최종 승인(인증 성공) 시각
      // ★ 지급 준비 화면의 사람별 소계는 **실제 이체 금액을 정하는 숫자**다.
      //   계산값만 쓰면 이미 다르게 보낸 건이 섞였을 때 그 소계가 곧 틀린 송금액이 된다.
      amount: settlementEffectiveAmount(s),
      // 그 회차 합계가 「실제 송금일 기준」인지 「등록한 날 기준」인지 가르는 표시.
      recordDateOnly: settlementPaidAtIsRecordDate(s),
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
  // ⚠️ 「미등록」 화면은 목록 화면의 **형제**라, 목록만 감추면 그대로 남는다.
  //    안 감추면 지급 준비와 미등록이 **세로로 겹쳐 한 화면에 둘 다** 뜬다
  //    (2026-08-18 운영에서 실제로 그렇게 보였다). 세 화면은 서로 배타여야 한다.
  hideUnregisteredTab();
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
  renderPayoutSummary();
}

function closePayoutPrepView() {
  const main = $('settlementMainView'), view = $('settlementPayoutView');
  if (view) view.style.display = 'none';
  if (main) main.style.display = 'flex';
  // 지급 준비로 가기 전에 「미등록」 탭을 보고 있었다면 그 자리로 돌려준다 —
  // 돌아왔더니 다른 탭이면 방금 보던 목록을 다시 찾아 들어가야 한다.
  if (_settlementFilters && _settlementFilters.status === 'unregistered'
      && typeof showUnregisteredTab === 'function') {
    showUnregisteredTab();
  }
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
  return `<tr>
    <td style="font-weight:700;white-space:nowrap">${esc(due)}</td>
    <td style="text-align:right;white-space:nowrap">${cnt}건</td>
    <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(_payoutYen(sum))}</td>
    <td style="text-align:right;white-space:nowrap">${cell(sent.length, _payoutSum(sent), '#16A34A')}</td>
    <td style="text-align:right;white-space:nowrap">${cell(unsent.length, _payoutSum(unsent), '#C33')}</td>
    <td style="white-space:nowrap">${when}${notes.length ? `<div style="font-size:11px">${notes.join(' · ')}</div>` : ''}</td>
    <td style="text-align:right"><button class="btn btn-ghost btn-xs" style="padding:2px 10px"
        onclick="openPayoutPersonList('${esc(due)}')">상세</button></td>
  </tr>`;
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
  const head = `<tr><td colspan="7" style="background:${color}14;padding:7px 12px;border-bottom:1px solid var(--outline)">
      <span style="font-weight:700;font-size:13px;color:${color}">${esc(title)}</span>
      ${dues.length ? `<span style="font-size:12px;color:var(--muted);margin-left:8px">${cnt}건 · ${esc(_payoutYen(sum))}</span>` : ''}
    </td></tr>`;
  const body = dues.length
    ? dues.map(function(d) { return payoutDueRowHtml(d, byDue[d], todayStr); }).join('')
    : `<tr><td colspan="7" style="color:var(--muted);font-size:12px">${esc(emptyText)}</td></tr>`;
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
  const head = `<tr><td colspan="7" style="background:${color}14;padding:7px 12px;border-bottom:1px solid var(--outline)">
      <span style="font-weight:700;font-size:13px;color:${color}">지급일 기록 없음</span>
      <span style="font-size:12px;color:var(--muted);margin-left:8px">인증 성공일이 없어 지급 예정일을 계산할 수 없는 건</span>
    </td></tr>`;
  return head + `<tr>
    <td style="font-weight:700;white-space:nowrap;color:var(--muted)">기록 없음</td>
    <td style="text-align:right;white-space:nowrap">${rows.length}건</td>
    <td style="text-align:right;font-weight:700;white-space:nowrap">${esc(_payoutYen(_payoutSum(rows)))}</td>
    <td style="text-align:right;white-space:nowrap">${cell(sent.length, _payoutSum(sent), '#16A34A')}</td>
    <td style="text-align:right;white-space:nowrap">${cell(unsent.length, _payoutSum(unsent), '#C33')}</td>
    <td style="white-space:nowrap;color:var(--muted)">—</td>
    <td style="text-align:right"><button class="btn btn-ghost btn-xs" style="padding:2px 10px"
        onclick="openPayoutPersonList('${PAYOUT_NO_DUE}')">상세</button></td>
  </tr>`;
}

function renderPayoutSummary() {
  const body = $('payoutSummaryBody');
  if (!body) return;
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

  body.innerHTML =
    `<div class="admin-table-wrap"><table class="data-table" style="width:100%">
      <thead><tr>
        <th style="width:110px">지급 예정일</th>
        <th style="width:70px;text-align:right">건수</th>
        <th style="width:110px;text-align:right">금액</th>
        <th style="width:110px;text-align:right">송금완료</th>
        <th style="width:110px;text-align:right">미지급</th>
        <!-- ★ 「기한」은 **미지급 바로 옆**이다. 기한이 말하는 대상이 미지급이기 때문 —
             「미지급 22건인데 지급 기한이 4일 지났다」로 읽혀야 한다(2026-08-19 사용자 지적).
             금액 옆에 있을 때는 그 회차 전체 금액에 걸린 말처럼 읽혔다.
             ⚠️ 열을 옮길 때는 **머리글·회차 줄·「지급일 기록 없음」 줄 셋을 함께** 옮긴다. -->
        <th style="width:150px">기한</th>
        <th style="width:70px"></th>
      </tr></thead>
      <tbody>`
  + payoutSectionHtml(`이번 달 (${esc(thisMonth)})`, '#2563EB', thisM, byDue, todayStr, '이번 달 지급 예정이 없습니다.')
  // ⚠️ 색은 **여섯 자리로** 적는다. 제목 배경을 색+투명도로 만드는데, 세 자리(#C33)에
  //    붙이면 없는 값이 되어 **그 구역만 배경이 안 깔린다**(2026-08-18 운영에서 확인).
  + payoutSectionHtml('지난 달 이전 — 밀린 것', '#CC3333', before, byDue, todayStr, '밀린 것이 없습니다.')
  + payoutSectionHtml('정산 예정', '#6B7280', after, byDue, todayStr, '앞으로 예정된 정산이 없습니다.')
  + payoutNoDueSectionHtml(rows.filter(function(r) { return !r.due; }))
  + `</tbody></table></div>`
  + `<div style="border-top:1px solid var(--line);padding:14px 18px 16px">
      <!-- ⚠️ 달을 넘겨 보던 「지급 완료」 묶음은 없앴다(2026-08-18 사용자 결정) —
           회차 표의 **송금완료 열**이 같은 것을 회차별로 보여주므로 중복이다. -->
      <div>
      </div>
    </div>`;
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

// 건별 줄의 **열 제목**. ⚠️ 없으면 오른쪽 날짜가 무슨 날짜인지 알 수 없다 —
//   운영팀은 지급 예정일·송금일·승인일을 한 화면에서 함께 보므로, 제목 없는 날짜는
//   곧 오해가 된다(2026-08-18 지적). 건별 줄과 **같은 폭**으로 맞춰 그린다.
function payoutItemsHeadHtml() {
  return `<div style="display:flex;gap:10px;align-items:center;padding:2px 0 3px 26px;font-size:10px;color:var(--muted);
              letter-spacing:.03em;border-bottom:1px solid var(--line);margin-bottom:2px">
    <div style="flex:1">캠페인</div>
    <div style="width:96px;text-align:right">결과물 승인일</div>
    <div style="width:96px;text-align:right">송금 완료일</div>
    <div style="width:88px;text-align:right">금액</div>
    <div style="width:52px"></div>
  </div>`;
}

// 건별 줄만 (묶음 줄과 따로 쓸 수 있게 분리)
function payoutDueItemsHtml(list, sent) {
  return list.map(function(r) {
    // ⚠️ **이미 보낸 건은 버튼을 안 단다.** 안 보낸 줄과 똑같이 보이면 「이미 기록됨」이라는
    //    요약이 바로 위 줄들을 가리키는 것처럼 읽혀, 보낸 것에 또 「보냄」이 붙은 줄로 오해된다
    //    (2026-08-18 실제 지적). 흐리게 + 「기록됨」 표로 갈라 놓는다.
    if (sent) {
      return `<div style="display:flex;gap:10px;align-items:center;padding:3px 0 3px 26px;font-size:12px;color:var(--muted);opacity:.7">
        <div style="flex:1">${esc(r.campaignNo ? '[' + r.campaignNo + '] ' : '')}${esc(r.campaignTitle || '(캠페인 미상)')}</div>
        <div style="width:96px;text-align:right" title="결과물 최종 승인(인증 성공)일">${r.certAt ? esc(formatDate(r.certAt)) : '기록 없음'}</div>
        <div style="width:96px;text-align:right" title="실제로 송금한 날(기록된 값)">${r.paidAt ? esc(formatDate(r.paidAt)) : '—'}</div>
        <div style="width:88px;text-align:right">${esc(_payoutYen(r.amount))}</div>
        <div style="width:52px;text-align:right"><span style="font-size:10px;background:#E8F5E9;color:#16A34A;font-weight:700;padding:1px 6px;border-radius:3px">기록됨</span></div>
      </div>`;
    }
    // ⚠️ 건을 가리키는 열쇠는 **응모 id** 를 쓴다 — 정산 행이 아직 없는 건(미등록)에는
    //    정산 id 자체가 없다. 응모 id 는 두 갈래 모두에 있다.
    return `<div style="display:flex;gap:10px;align-items:center;padding:3px 0 3px 26px;font-size:12px;color:var(--muted)">
      <div style="flex:1">${esc(r.campaignNo ? '[' + r.campaignNo + '] ' : '')}${esc(r.campaignTitle || '(캠페인 미상)')}</div>
      <div style="width:96px;text-align:right" title="결과물 최종 승인(인증 성공)일">${r.certAt ? esc(formatDate(r.certAt)) : '기록 없음'}</div>
      <!-- 아직 안 보낸 줄이라 송금일은 비어 있다 — 열을 비워 두어야 아래 보낸 줄과 자리가 맞는다 -->
      <div style="width:96px;text-align:right;color:var(--muted);opacity:.5">—</div>
      <div style="width:88px;text-align:right">${esc(_payoutYen(r.amount))}</div>
      <div style="width:52px;text-align:right">${r.applicationId
        ? `<button class="btn btn-ghost btn-xs" style="padding:1px 8px;font-size:11px"
             onclick="openPayoutSendOneModal('${esc(r.applicationId)}')" title="이 건만 송금완료로 기록">보냄</button>`
        : ''}</div>
    </div>`;
  }).join('');
}

// 지급일 묶음 한 줄 (+ 펼치면 건별)
function payoutDueGroupHtml(personId, due, list) {
  const key = personId + '|' + due;
  const checked = _payoutSelected.has(key) ? 'checked' : '';
  const items = payoutDueItemsHtml(list);
  return `<div style="border-top:1px dashed var(--line);padding:6px 0">
    <div style="display:flex;align-items:center;gap:10px">
      <input type="checkbox" ${checked} onchange="togglePayoutSelect('${esc(key)}')" style="width:15px;height:15px">
      <div style="width:110px;font-size:12px;font-weight:600">${esc(due)}</div>
      <div style="width:50px;text-align:right;font-size:12px">${list.length}건</div>
      <div style="width:96px;text-align:right;font-weight:700;font-size:12px">${esc(_payoutSum(list) ? _payoutYen(_payoutSum(list)) : '—')}</div>
      <button class="btn btn-ghost btn-xs" onclick="openPayoutSendModal('${esc(key)}')" style="padding:2px 10px" title="이 사람의 이 회차를 송금완료로 기록합니다">보냄</button>
    </div>
    ${items}
  </div>`;
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

function payoutPersonCardHtml(entry) {
  const p = entry.person;
  const dues = Object.keys(entry.dues).sort();
  const allUnsent = dues.reduce(function(a, d) { return a.concat(entry.dues[d]); }, []);
  const paidSum = _payoutSum(entry.paid);
  // ⚠️ 회차가 **하나뿐이면** 그 회차 줄이 사람 머리와 같은 말을 두 번 한다(날짜·건수·금액).
  //    그때는 줄을 없애고 **체크박스는 이름 왼쪽, 「보냄」은 합계 오른쪽**으로 옮긴다.
  //    회차가 둘 이상이면 어느 회차인지 갈라야 하므로 종전대로 회차 줄을 남긴다.
  const single = dues.length === 1;
  return `<div style="border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:10px">
    <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
      ${single
        ? `<input type="checkbox" ${_payoutSelected.has(p.id + '|' + dues[0]) ? 'checked' : ''}
             onchange="togglePayoutSelect('${esc(p.id + '|' + dues[0])}')" style="width:15px;height:15px">`
        : ''}
      <div style="font-weight:700;font-size:13px">${esc(p.name || '(이름 미상)')}</div>
      ${p.kana ? `<div style="font-size:11px;color:var(--muted)">${esc(p.kana)}</div>` : ''}
      ${payoutPaypalHtml(p)}
      <div style="margin-left:auto;display:flex;align-items:center;gap:10px">
        <span style="font-size:12px">${allUnsent.length}건 · <b>${esc(_payoutYen(_payoutSum(allUnsent)))}</b></span>
        ${single
          ? `<button class="btn btn-ghost btn-xs" style="padding:2px 10px"
               onclick="openPayoutSendModal('${esc(p.id + '|' + dues[0])}')" title="이 사람의 이 회차를 송금완료로 기록">보냄</button>`
          : ''}
      </div>
    </div>
    ${payoutItemsHeadHtml()}
    ${single
      ? payoutDueItemsHtml(entry.dues[dues[0]])
      : dues.map(function(d) { return payoutDueGroupHtml(p.id, d, entry.dues[d]); }).join('')}
    ${entry.paid.length ? `<div style="border-top:1px dashed var(--line);margin-top:6px;padding-top:6px">
        <div style="font-size:12px;color:#16A34A;padding-left:26px">이미 기록됨 ${entry.paid.length}건 · ${esc(_payoutYen(paidSum))}</div>
        ${payoutDueItemsHtml(entry.paid, true)}
      </div>` : ''}
  </div>`;
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

function onPayoutPersonSearch(v) {
  _payoutPersonSearch = (v || '').trim().toLowerCase();
  _payoutSearchTokens = (v || '').trim().split(/[\s\u3000]+/).filter(Boolean).map(_payoutNorm);
  renderPayoutPersonBody();   // ⚠️ 껍데기를 다시 그리면 검색창 포커스가 날아간다
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
  const base = 'border:0;border-radius:6px;padding:2px 11px;font-size:11px;cursor:pointer;line-height:1.5;white-space:nowrap';
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

function payoutCampaignCardHtml(entry) {
  const rows = entry.rows.slice().sort(function (a, b) { return b.amount - a.amount; });
  const people = new Set(rows.map(function (r) { return r.influencerId; })).size;
  // ⚠️ 열 제목을 단다 — 회원별 화면과 **같은 항목·같은 순서**로. 제목 없는 날짜가 셋이면
  //    어느 것이 무엇인지 알 수 없고, 두 화면이 서로 다른 순서로 보여주면 더 헷갈린다.
  const head = `<div style="display:flex;gap:10px;align-items:baseline;padding:2px 0 3px;font-size:10px;color:var(--muted);
             letter-spacing:.03em;border-top:1px solid var(--line);margin-top:4px">
      <div style="min-width:150px">인플루언서</div>
      <div style="flex:1">가나</div>
      <div style="width:96px;text-align:right">지급 예정일</div>
      <div style="width:96px;text-align:right">결과물 승인일</div>
      <div style="width:96px;text-align:right">송금 완료일</div>
      <div style="width:88px;text-align:right">금액</div>
      <div style="width:52px;text-align:right">상태</div>
    </div>`;
  const items = rows.map(function (r) {
    const p = payoutPersonOf(r);
    const sent = r.status === 'paid';
    return `<div style="display:flex;gap:10px;align-items:baseline;padding:3px 0;font-size:12px;border-top:1px dashed var(--line)${sent ? ';opacity:.7' : ''}">
      <div style="min-width:150px;font-weight:600;color:var(--ink)">${esc(p.name || '(이름 미상)')}</div>
      <div style="flex:1;color:var(--muted)">${esc(p.kana || '')}</div>
      <div style="width:96px;text-align:right;color:var(--muted)">${esc(r.due || '(예정일 없음)')}</div>
      <div style="width:96px;text-align:right;color:var(--muted)">${r.certAt ? esc(formatDate(r.certAt)) : '기록 없음'}</div>
      <div style="width:96px;text-align:right;color:var(--muted)">${r.paidAt ? esc(formatDate(r.paidAt)) : '—'}</div>
      <div style="width:88px;text-align:right;font-weight:700">${esc(_payoutYen(r.amount))}</div>
      <div style="width:52px;text-align:right">${sent
        ? '<span style="font-size:10px;background:#E8F5E9;color:#16A34A;font-weight:700;padding:1px 6px;border-radius:3px">기록됨</span>'
        : '<span style="font-size:10px;color:#C33;font-weight:700">미지급</span>'}</div>
    </div>`;
  }).join('');
  return `<div style="border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin-bottom:10px">
    <div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin-bottom:4px">
      ${entry.no ? `<div style="font-size:11px;color:var(--muted)">${esc(entry.no)}</div>` : ''}
      <div style="font-weight:700;font-size:13px">${esc(entry.title || '(캠페인 미상)')}</div>
      <div style="margin-left:auto;font-size:12px">${rows.length}건 · ${people}명 · <b>${esc(_payoutYen(_payoutSum(rows)))}</b></div>
    </div>
    ${head}${items}
  </div>`;
}

function renderPayoutPersonList() {
  const body = $('payoutSummaryBody');
  if (!body) return;
  body.innerHTML = `
   <div style="padding:0 18px 16px">
    <!-- ⚠️ 머리(뒤로가기·제목·검색·스위치)와 요약·선택 정보를 **위에 붙여** 둔다.
         목록이 길어 스크롤하면 「지금 어느 회차를 보고 있고 얼마가 남았는지」가 화면 밖으로
         나가고, 고른 건수도 맨 아래에 있어 **고를 때마다 끝까지 내려가야** 했다.
         ⚠️ 좌우로 -18px 빼고 다시 채우는 것은 감싸개 여백을 덮어 배경이 끊기지 않게 하려는 것.
            안 그러면 스크롤할 때 옆으로 내용이 비쳐 보인다.
         ⚠️ **아래쪽 구분선은 꼭 있어야 한다.** 없으면 목록이 이 영역 바로 밑으로 파고들어
            잘린 줄이 붙은 채로 보이고, 어디까지가 고정 영역인지 알 수 없다(2026-08-19 지적).
            선은 이 감싸개에 준다 — 안쪽 요소에 주면 선택 줄이 생겼다 없어질 때 선도 함께
            사라진다(선택 줄은 있을 때만 그려진다). -->
    <div style="position:sticky;top:0;z-index:5;background:#fff;margin:0 -18px;padding:16px 18px 0;border-bottom:1px solid var(--line)">
    <div style="display:flex;align-items:center;gap:10px;margin-bottom:12px;flex-wrap:wrap">
      <button class="btn btn-ghost btn-sm" onclick="backToPayoutSummary()" style="padding:2px 8px">← 지급일 요약</button>
      <div style="font-weight:700;font-size:14px">${
        !_payoutDueFilter ? '전체 기간'
        : (_payoutDueFilter === PAYOUT_NO_DUE ? '지급일 기록 없음' : esc(_payoutDueFilter) + ' 지급 예정')}</div>
      <!-- 검색칸과 스위치를 **한 덩어리로 묶어 오른쪽 끝**에 붙인다.
           ⚠️ 「admin-filter-search」 는 돋보기 아이콘 자리로 왼쪽 28px 을 비워 두는 클래스다.
              아이콘을 같이 안 넣으면 그만큼이 그냥 빈 여백으로 보인다(다른 화면은 전부
              감싸개 + 아이콘 한 쌍으로 쓴다 — 같은 모양을 지킨다).
           ⚠️ 이 주석은 **문자열 안**이다. 여기에 backtick 을 쓰면 문자열이 그 자리에서
              끊겨 파일 전체가 깨진다(2026-08-18 실제로 그랬다). 「」 로 감쌀 것. -->
      <div style="display:flex;align-items:center;gap:8px;margin-left:auto">
        <div style="position:relative;width:260px">
          <span class="material-icons-round notranslate" translate="no"
                style="position:absolute;left:8px;top:50%;transform:translateY(-50%);font-size:16px;color:var(--muted)">search</span>
          <input id="payoutPersonSearchInput" type="search" class="admin-filter-search"
                 autocomplete="off" data-lpignore="true" data-1p-ignore="true"
                 placeholder="이름(한자·가나)·페이팔 이메일로 검색"
                 value="${esc(_payoutPersonSearch)}" oninput="onPayoutPersonSearch(this.value)">
        </div>
        ${payoutGroupSwitchHtml()}
      </div>
    </div>
      <div id="payoutStickyInfo"></div>
    </div>
    <!-- ⚠️ 여백은 **고정 영역이 아니라 목록 쪽**에 준다. 고정 영역 안에 넣으면 스크롤 중에도
         그만큼 흰 띠가 따라다녀 화면이 좁아진다. 목록에 주면 **맨 위에서만** 벌어지고,
         스크롤하면 자연스럽게 구분선 밑으로 들어간다(2026-08-19 사용자 지적). -->
    <div id="payoutPersonListBody" style="margin-top:14px"></div>
   </div>`;
  renderPayoutPersonBody();
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
  let rows = !_payoutDueFilter ? all
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
    body.innerHTML = `
      <div style="font-size:12px;color:var(--muted);margin-bottom:10px">
        캠페인 ${list.length}개 · ${cr.length}건 · 합계 <b style="color:var(--ink)">${esc(_payoutYen(_payoutSum(cr)))}</b>
      </div>
      <div style="padding:8px 10px;background:#F7F7F8;border:1px solid var(--line);border-radius:8px;font-size:12px;line-height:1.6;color:var(--muted);margin-bottom:12px">
        캠페인별은 <b>보기 전용</b>입니다. 송금은 사람에게 하므로 실제 처리는 「회원별」에서 하세요 —
        한 사람이 여러 캠페인에 걸쳐 있어, 캠페인 쪽에서 고르면 그 사람에게 보낼 금액이 갈라집니다.
      </div>
      ${list.length ? list.map(payoutCampaignCardHtml).join('')
        : '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">대상이 없습니다.</div>'}`;
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
    ? `<div style="font-size:12px;color:var(--muted);margin-bottom:10px">${total}명 · 미지급 <b style="color:#C33">${esc(_payoutYen(unsentSum))}</b>${
        paidCnt ? ` · 송금완료 <b style="color:#16A34A">${paidCnt}건 ${esc(_payoutYen(paidSum2))}</b>` : ''}</div>`
    : `<div style="font-size:12px;color:var(--muted);margin-bottom:10px">${total}명 중 <b style="color:var(--ink)">${doneCount}명</b> 처리 · ${total - doneCount}명 남음</div>`;

  const info = $('payoutStickyInfo');
  if (info) {
    info.innerHTML = progressHtml
      + (_payoutSelected.size ? `
      <div style="border-top:1px solid var(--line);padding:8px 0;font-size:13px;display:flex;align-items:center;gap:10px">
        <span>선택 <b>${_payoutSelected.size}</b>묶음 · <b>${selectedRows.length}</b>건 · 합계 <b>${esc(_payoutYen(_payoutSum(selectedRows)))}</b></span>
        <button class="btn btn-primary btn-xs" style="margin-left:auto;padding:3px 12px"
                onclick="openPayoutSendSelectedModal()" title="고른 묶음을 한 번에 송금완료로 기록합니다">선택한 건 보냄</button>
        <button class="btn btn-ghost btn-xs" style="padding:2px 10px"
                onclick="_payoutSelected.clear(); renderPayoutPersonBody();">선택 해제</button>
      </div>` : '<div style="height:8px"></div>');
  }
  body.innerHTML = `
    ${entries.length ? entries.map(payoutPersonCardHtml).join('')
      : `<div id="payoutEmptyBox" style="padding:24px;text-align:center;color:var(--muted);font-size:13px">${
          _payoutSearchTokens.length ? '찾는 중…' : '대상이 없습니다.'}</div>`}
    `;

  // 비었으면 **왜 없는지** 찾아본다(화면을 그린 뒤 비동기 — 목록 표시를 막지 않는다)
  if (!entries.length && _payoutSearchTokens.length) payoutExplainMissing(_payoutPersonSearch);
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
