// ══════════════════════════════════════
// REVERB JP — Admin Brand Survey 영역
// ══════════════════════════════════════
// admin.js에서 분리된 광고주(브랜드 서베이) 페인 전용 코드
// - 신청 목록(brand-applications)
// - 현황 대시보드(brand-dashboard)
// - 브랜드 마스터(brands)
// - 신청 등록·수정·이력·메모·인라인 셀 편집
//
// 잔존 가교(admin.js):
//   loadExcelJS / imgToJpegArrayBuffer / exportCampaignApplicationsExcel /
//   exportCampaignDeliverables / loadCampBrandSelect / onCampBrandChange /
//   loadCampSourceAppSelect / onCampSourceAppChange / lpad
//
// 빌드 순서: lib/* → js/ui.js → js/admin-brand.js → js/admin.js → admin/app.js
// 함수 호이스팅으로 양 파일 간 상호 호출 안전. var 선언은 단일 concat 스크립트 상단으로 호이스팅됨.
// ══════════════════════════════════════

// ══════════════════════════════════════
// BRAND APPLICATIONS (광고주 신청 관리 — PR-4)
// ══════════════════════════════════════

var _brandApps = [];          // 캐시된 전체 목록
var _orientByApp = {};        // {application_id: [orient_sheet,...]} — 셀프 오리엔시트 열용(목록 로드 시 1회 그룹)
var _brandAppSort = {field: 'created', dir: 'desc'};
var _brandAppCurrentId = null; // 상세 모달 열린 신청 ID

// 상태 탭 현재 활성값 — null = 전체, 문자열 = 특정 상태 코드
var _brandAppActiveStatusTab = null;

// 상태 탭 순서 및 라벨 정의 (상세 모달 상태 드롭다운 라벨과 통일)
var BRAND_APP_STATUS_TABS = [
  {code: null,                 label: '전체'},
  {code: 'new',                label: '신규'},
  {code: 'reviewing',          label: '검토중'},
  {code: 'quoted',             label: '견적 전달'},
  {code: 'paid',               label: '입금완료'},
  {code: 'kakao_room_created', label: '카톡방 생성'},
  {code: 'orient_sheet_sent',  label: '오리엔트 전달'},
  {code: 'schedule_sent',      label: '일정 전달'},
  {code: 'campaign_registered',label: '캠페인 등록'},
  {code: 'done',               label: '최종완료'},
  {code: 'rejected',           label: '반려'},
];

// URL 해시 쿼리에서 특정 파라미터 추출
// 예: #brand-applications?status=new → 'new'
function parseHashQuery(paramName) {
  var hash = location.hash || '';
  var qIdx = hash.indexOf('?');
  if (qIdx < 0) return null;
  var qs = hash.slice(qIdx + 1);
  var pairs = qs.split('&');
  for (var i = 0; i < pairs.length; i++) {
    var kv = pairs[i].split('=');
    if (decodeURIComponent(kv[0]) === paramName) {
      return kv[1] ? decodeURIComponent(kv[1]) : null;
    }
  }
  return null;
}

// URL 해시를 현재 탭 상태에 맞게 갱신 (history 스택 오염 없이 replace)
function syncBrandAppStatusTabHash() {
  var base = '#brand-applications';
  var next = _brandAppActiveStatusTab ? base + '?status=' + encodeURIComponent(_brandAppActiveStatusTab) : base;
  if (location.hash !== next) {
    history.replaceState(null, '', next);
  }
}

// 탭 바 렌더 + 건수 계산
// baseCounts: 현재 폼타입·기간·검색 필터 적용 후 상태별 건수 맵 {statusCode: n}
function renderBrandAppStatusTabs(baseCounts) {
  var bar = $('brandAppStatusTabBar');
  if (!bar) return;
  baseCounts = baseCounts || {}; // null/undefined 가드 (catch 경로에서 빈 객체로 호출됨)
  var totalAll = Object.values(baseCounts).reduce(function(sum, n){ return sum + n; }, 0);
  bar.innerHTML = BRAND_APP_STATUS_TABS.map(function(tab) {
    var n = tab.code === null ? totalAll : (baseCounts[tab.code] || 0);
    var isOn = (tab.code === null && _brandAppActiveStatusTab === null)
            || (tab.code !== null && tab.code === _brandAppActiveStatusTab);
    var zeroClass = n === 0 && tab.code !== null ? ' zero-count' : '';
    var onClass = isOn ? ' on' : '';
    // data-status 속성: 전체 탭은 빈 문자열
    var dataStatus = tab.code !== null ? esc(tab.code) : '';
    return '<button type="button" class="status-tab-btn' + onClass + zeroClass + '"'
      + ' data-status="' + dataStatus + '"'
      + ' onclick="setBrandAppStatusTab(this)">'
      + esc(tab.label)
      + '<span class="tab-count">(' + n + ')</span>'
      + '</button>';
  }).join('');
}

// 탭 클릭 핸들러
function setBrandAppStatusTab(btn) {
  var code = btn.dataset.status || null; // 빈 문자열이면 null(전체)
  if (code === '') code = null;
  _brandAppActiveStatusTab = code;
  syncBrandAppStatusTabHash();
  renderBrandApplicationsList();
}

// updateBrandApplication 응답을 메모리 cur 에 동기화.
// products 변경 시 052/111 트리거가 서버에서 재계산한 estimated_krw /
// total_jpy / total_qty 까지 즉시 반영해 새로고침 없이 「예상 견적」 등
// 의존 셀이 갱신되도록 한다.
function _syncBrandAppCur(cur, result, fallbackVersion) {
  if (!cur || !result || !result.data) return;
  cur.version = (result.data.version != null) ? result.data.version : (fallbackVersion + 1);
  if (result.data.estimated_krw != null) cur.estimated_krw = result.data.estimated_krw;
  if (result.data.total_jpy != null) cur.total_jpy = result.data.total_jpy;
  if (result.data.total_qty != null) cur.total_qty = result.data.total_qty;
  // products 변경 시 migration 117 트리거가 products[i].payment_flags 자동 재계산 — 응답 동기화 필수
  if (result.data.products != null) cur.products = result.data.products;
}

// 상태 라벨·컬러 (객체 키 순서가 드롭다운 옵션 순서)
var BRAND_APP_STATUS = {
  'new':                 {label:'신규',             color:'#C33',   bg:'#FEE'},
  'reviewing':           {label:'검토중',           color:'#B88',   bg:'#FFE'},
  'quoted':              {label:'견적 전달',        color:'#08A',   bg:'#DEF'},
  'paid':                {label:'입금완료',         color:'#6A2',   bg:'#EFE'},
  'kakao_room_created':  {label:'카톡방 생성',      color:'#A57',   bg:'#FBF2DE'},
  'orient_sheet_sent':   {label:'오리엔시트 전달',  color:'#735',   bg:'#F2E6F0'},
  'schedule_sent':       {label:'일정 전달',        color:'#A36',   bg:'#FDEEF4'},
  'campaign_registered': {label:'캠페인 등록',      color:'#274',   bg:'#E6F3E8'},
  'done':                {label:'최종완료',         color:'#555',   bg:'#EEE'},
  'rejected':            {label:'반려',             color:'#999',   bg:'#F5F5F5'}
};

function brandAppStatusBadge(status) {
  var s = BRAND_APP_STATUS[status] || {label: status, color:'#666', bg:'#EEE'};
  return '<span style="background:'+s.bg+';color:'+s.color+';font-size:11px;font-weight:700;padding:2px 8px;border-radius:4px">'+esc(s.label)+'</span>';
}

// 요청사항 셀: 2줄 말줄임 + 더보기 모달 (msgCell 패턴 재사용)
// openMsgModal 헬퍼 공유 — data-msg 안 HTML은 esc 후 주입
function brandAppNoteCell(text) {
  if (!text) return '<span style="color:var(--muted);font-size:12px">—</span>';
  var safe = esc(text);
  var short = '<div style="max-width:220px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;font-size:12px;color:var(--ink);line-height:1.4">' + safe + '</div>';
  // 40자 또는 개행 포함 시 "더보기" 노출 (2줄 미리보기에서 잘릴 가능성 있음)
  var hasMore = text.length > 40 || /\n/.test(text);
  var more = hasMore
    ? '<a href="javascript:void(0)" style="font-size:10px;color:var(--pink);text-decoration:underline;cursor:pointer;margin-top:2px;display:inline-block" onclick="event.stopPropagation();openMsgModal(this)" data-msg="' + safe + '">더보기</a>'
    : '';
  return short + more;
}

// 뱃지 스타일 상태 select 공통 렌더러
function brandAppStatusSelectStyled(opts) {
  var status = opts.status;
  var s = BRAND_APP_STATUS[status] || {color:'#666', bg:'#EEE'};
  var optionsHtml = Object.keys(BRAND_APP_STATUS).map(function(k) {
    return '<option value="'+k+'"'+(status===k?' selected':'')+'>'+esc(BRAND_APP_STATUS[k].label)+'</option>';
  }).join('');
  var sizeSm = opts.size === 'sm';
  var padding = sizeSm ? '3px 22px 3px 10px' : '7px 28px 7px 14px';
  var fontSize = sizeSm ? '11px' : '13px';
  var arrowPos1 = sizeSm ? 'calc(100% - 10px) 8px' : 'calc(100% - 12px) 50%';
  var arrowPos2 = sizeSm ? 'calc(100% - 6px) 8px' : 'calc(100% - 8px) 50%';
  var arrowSize = sizeSm ? '4px 4px' : '5px 5px';
  var extraAttrs = (opts.id ? ' id="'+esc(opts.id)+'"' : '')
    + (opts.disabled ? ' disabled' : '')
    + (opts.onchange ? ' onchange="'+opts.onchange+'"' : '')
    + (opts.onclick ? ' onclick="'+opts.onclick+'"' : '');
  return '<select class="brand-app-status-sel"' + extraAttrs
    + ' style="background:'+s.bg+';color:'+s.color+';font-size:'+fontSize+';font-weight:700;padding:'+padding+';border-radius:6px;'
    + 'border:0;cursor:pointer;appearance:none;-webkit-appearance:none;'
    + 'background-image:linear-gradient(45deg,transparent 50%,'+s.color+' 50%),linear-gradient(-45deg,transparent 50%,'+s.color+' 50%);'
    + 'background-position:'+arrowPos1+','+arrowPos2+';background-size:'+arrowSize+';background-repeat:no-repeat">'
    + optionsHtml + '</select>';
}

// 리스트용 shortcut (즉시 저장)
function brandAppStatusSelect(a) {
  return brandAppStatusSelectStyled({
    status: a.status,
    size: 'sm',
    onchange: 'quickChangeBrandAppStatus(\''+esc(a.id)+'\', this.value, '+a.version+')',
    onclick: 'event.stopPropagation()'
  });
}

// 제품 단위 상태 select — products[idx].status 우선, 없으면 신청 단위 a.status 폴백
// onchange에 version 인자를 박지 않음 — 같은 신청의 다른 셀들이 stale 문자열을 갖지 않도록 함수 내부에서 cur.version 동적 읽기
function brandAppStatusSelectForProduct(a, p, idx) {
  var effective = (p && p.status) || a.status;
  return brandAppStatusSelectStyled({
    status: effective,
    size: 'sm',
    onchange: 'quickChangeBrandAppProductStatus(\''+esc(a.id)+'\', '+idx+', this.value)',
    onclick: 'event.stopPropagation()'
  });
}

// 제품 단위 상태 변경 — products jsonb patch (낙관적 락) + 해당 셀만 재렌더 (다른 셀 편집 보존)
async function quickChangeBrandAppProductStatus(id, idx, newStatus) {
  var cur = _brandApps.find(function(a){ return a.id === id; });
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var p = cur.products[idx];
  var prevStatus = p.status || cur.status;
  if (prevStatus === newStatus) return;
  var nextProducts = cur.products.map(function(prod, i) {
    if (i !== idx) return prod;
    var copy = Object.assign({}, prod);
    copy.status = newStatus;
    return copy;
  });
  var expectedVersion = cur.version;
  var result = await updateBrandApplication(id, {products: nextProducts}, expectedVersion);
  if (result.conflict) {
    toast('다른 관리자가 먼저 처리했습니다. 목록을 새로고침합니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('상태 변경 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    await loadBrandApplications();
    return;
  }
  cur.products = nextProducts;
  _syncBrandAppCur(cur, result, expectedVersion);
  _refreshBrandAppHistoryButton(id);
  // 상태 변경은 필터 (NN)건 카운트와 매칭 행 노출에 즉시 영향 — 목록 전체 재렌더
  // 일정 인라인 편집과는 다른 흐름이라 의도적으로 셀-only 재렌더 미사용
  renderBrandApplicationsList();
  toast('상태가 ' + (BRAND_APP_STATUS[newStatus]?.label || newStatus) + '(으)로 변경됨');
}

// 리스트에서 즉시 상태 변경 (낙관적 락 체크)
async function quickChangeBrandAppStatus(id, newStatus, expectedVersion) {
  var cur = _brandApps.find(function(a){ return a.id === id; });
  if (!cur) return;
  if (cur.status === newStatus) return;
  var patch = {status: newStatus};
  // 최초 검수 진입 시 reviewed_by/at 기록
  if (cur.status === 'new' && newStatus !== 'new') {
    patch.reviewed_by = currentUser?.id || null;
    patch.reviewed_at = new Date().toISOString();
  }
  var result = await updateBrandApplication(id, patch, expectedVersion);
  if (result.conflict) {
    toast('다른 관리자가 먼저 처리했습니다. 목록을 새로고침합니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('상태 변경 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    await loadBrandApplications();
    return;
  }
  toast('상태가 ' + (BRAND_APP_STATUS[newStatus]?.label || newStatus) + '(으)로 변경됨');
  await loadBrandApplications();
}

function brandAppFormLabel(formType) {
  // 「리뷰어」 → 「리뷰어」로 단순화 — Qoo10/엣코스메 분기는 reviewer_channels 채널 배지로 분리
  return formType === 'reviewer' ? '리뷰어' : (formType === 'seeding' ? '나노 시딩' : formType);
}

// 가격체크 코드 → 한글 라벨 (엑셀 내보내기·툴팁용)
function priceCheckKo(val) {
  if (val === 'higher') return '가격높음';
  if (val === 'lower')  return '가격낮음';
  if (val === 'equal')  return '가격동일';
  return ''; // null/undefined/빈값 = 미선택
}

// 광고주가 입력한 URL을 http/https만 허용 (javascript:, data: 스킴 차단)
function safeBrandUrl(url) {
  if (!url) return null;
  try {
    var u = new URL(url);
    return (u.protocol === 'https:' || u.protocol === 'http:') ? url : null;
  } catch(e) { return null; }
}

// 인라인 URL 입력 정규화 — 사용자가 http://·https:// 없이 입력하면 https:// 자동 prefix.
// 빈 문자열은 null. 다른 스킴(javascript:, data: 등) 은 차단.
function normalizeBrandUrlInput(raw) {
  var t = (raw || '').trim();
  if (!t) return null;
  // 이미 http/https 로 시작하면 그대로 검증
  if (/^https?:\/\//i.test(t)) return safeBrandUrl(t);
  // protocol-relative (//example.com) 도 https 로 보정
  if (t.indexOf('//') === 0) return safeBrandUrl('https:' + t);
  // 다른 스킴(javascript: 등) 차단
  if (/^[a-z][a-z0-9+.\-]*:/i.test(t)) return safeBrandUrl(t);
  // 스킴 없음 → https:// 자동 prefix
  return safeBrandUrl('https://' + t);
}

function fmtKrw(n) {
  if (n === null || n === undefined || n === '') return '—';
  var v = Number(n);
  if (!isFinite(v) || v === 0) return '—';
  return '₩ ' + v.toLocaleString('ko-KR');
}

function fmtDate(iso) {
  if (!iso) return '—';
  try {
    var d = new Date(iso);
    return d.toLocaleDateString('ko-KR', {year:'numeric', month:'2-digit', day:'2-digit'}).replace(/\s+/g,'');
  } catch(e) { return '—'; }
}

// 브랜드 서베이 신청 목록 엑셀 다운로드 (현재 필터·정렬 결과)
async function exportBrandApplicationsExcel() {
  try {
    var res = getFilteredBrandApps();
    var list = res.list;
    if (!list || list.length === 0) { toast('내보낼 데이터가 없습니다', 'error'); return; }

    toast('엑셀 생성 중...');
    await loadExcelJS();

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var ws = wb.addWorksheet('브랜드 서베이');

    // 신청 1건 = 제품 N행으로 펼침. 화면(21컬럼)에서 제거한 합산 컬럼(상품 최종 금액·이체수수료(원)·최종 견적·VAT포함)은 엑셀에는 유지 — 데이터 추출은 풀 컬럼 정책. 화면 액션 컬럼(이력)은 엑셀에서 제외.
    ws.columns = [
      { header: '신청번호',         key: 'no',          width: 22 },
      { header: '폼 종류',          key: 'form',        width: 14 },
      { header: '브랜드',           key: 'brand',       width: 24 },
      { header: '상태',             key: 'status',      width: 12 },
      { header: '검수일',           key: 'reviewed',    width: 14 },
      { header: '신청일',           key: 'created',     width: 20 },
      { header: '회사명',           key: 'company',     width: 24 },
      { header: '담당자명',         key: 'contact',     width: 12 },
      { header: '담당자이메일',     key: 'email',       width: 28 },
      { header: '연락처',           key: 'phone',       width: 16 },
      { header: '세금계산서 주소',  key: 'billing',     width: 24 },
      { header: '요청사항',         key: 'requestNote', width: 36 },
      { header: '제품명',           key: 'productName', width: 26 },
      { header: '제품명(일본어)',   key: 'productNameJa', width: 26 },
      { header: 'URL',              key: 'productUrl',  width: 36 },
      { header: '내부 메모',        key: 'memo',        width: 36 },
      { header: '진행 수량',        key: 'qty',         width: 10 },
      { header: '가격체크',         key: 'priceCheck',  width: 12 },
      { header: '상품 가격(엔)',    key: 'priceJpy',    width: 14 },
      { header: '상품 가격(원)',    key: 'priceKrw',    width: 14 },
      { header: '상품 최종 금액',   key: 'lineTotal',   width: 16 },
      { header: '모집비(건)',       key: 'recruitFee',  width: 14 },
      { header: '모집비(원)',       key: 'recruitFeeTotal', width: 16 },
      { header: '이체수수료(건)',   key: 'transferFee', width: 14 },
      { header: '이체수수료(원)',   key: 'feeTotal',    width: 16 },
      { header: '최종 견적 금액',   key: 'finalKrw',    width: 16 },
      { header: 'VAT포함',          key: 'vatKrw',      width: 16 },
      { header: '예상 견적',        key: 'estimated',   width: 16 },
      { header: '견적서 전달일',    key: 'quoteSent',   width: 14 }
    ];

    // 헤더 스타일
    var header = ws.getRow(1);
    header.font = { bold: true, color: { argb: 'FF222222' } };
    header.alignment = { vertical: 'middle', horizontal: 'center' };
    header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    header.height = 22;

    var fmtDateTime = function(iso) {
      if (!iso) return '';
      try { return new Date(iso).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
      catch(e) { return String(iso); }
    };
    var fmtDateOnly = function(iso) {
      if (!iso) return '';
      try { return new Date(iso).toLocaleDateString('ko-KR', { timeZone: 'Asia/Seoul' }); }
      catch(e) { return String(iso); }
    };

    var totalProductRows = 0;
    list.forEach(function(a) {
      var createdStr  = fmtDateTime(a.created_at);
      var quoteSent   = fmtDateOnly(a.quote_sent_at);
      var reviewed    = fmtDateOnly(a.reviewed_at);
      var prods = (Array.isArray(a.products) && a.products.length > 0)
        ? a.products
        : [{ name: '', url: '', qty: 0, price: 0, transfer_fee_krw: null }];

      prods.forEach(function(p) {
        // Phase B: 상태는 제품 단위 — products[i].status 우선, 없으면 신청 단위 a.status 폴백
        var rowStatus = (p && p.status) || a.status;
        var statusLabel = (BRAND_APP_STATUS[rowStatus]?.label) || rowStatus || '';
        var qty = Number(p.qty) || 0;
        var priceJpy = Number(p.price) || 0;
        var priceKrw = priceJpy * BRAND_QUOTE_CONST.FX_JPY_KRW;
        var lineTotal = qty * priceKrw;
        var transferFeeKrw = (p.transfer_fee_krw == null || p.transfer_fee_krw === '') ? null : Number(p.transfer_fee_krw);
        var feeTotalKrw = transferFeeKrw == null ? 0 : qty * transferFeeKrw;
        var recruitFeeKrw = (p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? null : Number(p.recruit_fee_krw);
        var recruitFeeTotalKrw = recruitFeeKrw == null ? 0 : qty * recruitFeeKrw;
        var finalKrw = calcBrandAppFinalKrw(a.form_type, lineTotal, feeTotalKrw, recruitFeeTotalKrw);
        var vatKrw = Math.floor(finalKrw * (1 + BRAND_QUOTE_CONST.VAT_RATE));
        ws.addRow({
          // 신청 단위 — 모든 행 반복 (정렬·필터 친화적). 화면과 동일하게 brand?.* / applicant_* 우선
          no:          a.application_no || '',
          form:        brandAppFormLabel(a.form_type),
          brand:       (a.brand && a.brand.name) || a.brand_name || '',
          status:      statusLabel,
          reviewed:    reviewed,
          created:     createdStr,
          company:     (a.brand && a.brand.company_name) || '',
          contact:     a.applicant_contact_name || a.contact_name || '',
          email:       a.applicant_email || a.email || '',
          phone:       formatPhoneDisplay(a.applicant_phone || a.phone),
          billing:     (a.brand && a.brand.billing_email) || a.billing_email || '',
          requestNote: a.request_note || '',
          // 제품 단위
          productName:   p.name || '',
          productNameJa: p.name_ja || '',
          productUrl:    p.url || '',
          memo:          (function(){
            // migration 123 이후: brand_application_memos summary 의 (app_id, idx) 최신 메모
            var k = a.id + '_' + idx;
            var s = (_brandAppMemoSummaries && _brandAppMemoSummaries[k]) || null;
            return s && s.latest ? s.latest : '';
          })(),
          qty:           qty || '',
          priceCheck:    priceCheckKo(p.price_check),
          priceJpy:      priceJpy || '',
          priceKrw:      priceKrw || '',
          lineTotal:     lineTotal || '',
          recruitFee:    recruitFeeKrw == null ? '' : recruitFeeKrw,
          recruitFeeTotal: recruitFeeTotalKrw || '',
          transferFee:   transferFeeKrw == null ? '' : transferFeeKrw,
          feeTotal:      feeTotalKrw || '',
          finalKrw:      finalKrw || '',
          vatKrw:        vatKrw || '',
          // 신청 단위 (예상 견적/견적서 전달일)
          estimated:   (a.estimated_krw == null || a.estimated_krw === '') ? '' : Number(a.estimated_krw),
          quoteSent:   quoteSent
        });
        totalProductRows++;
      });
    });

    // 통화·수량 컬럼 포맷
    ['priceJpy','priceKrw','lineTotal','recruitFee','recruitFeeTotal','transferFee','feeTotal','finalKrw','vatKrw','estimated'].forEach(function(k){
      var col = ws.getColumn(k);
      col.numFmt = '#,##0';
      col.alignment = { horizontal: 'right', vertical: 'middle' };
    });
    ws.getColumn('qty').numFmt = '#,##0';
    ws.getColumn('qty').alignment = { horizontal: 'right', vertical: 'middle' };

    // 본문 행 정렬·줄바꿈
    ws.eachRow({ includeEmpty: false }, function(row, idx) {
      if (idx === 1) return;
      row.eachCell({ includeEmpty: true }, function(cell) {
        cell.alignment = Object.assign({ vertical: 'middle' }, cell.alignment || {});
      });
      var noteCell = row.getCell('requestNote'); if (noteCell) noteCell.alignment = { wrapText: true, vertical: 'top' };
      var memoCell = row.getCell('memo');        if (memoCell) memoCell.alignment = { wrapText: true, vertical: 'top' };
      var nameCell = row.getCell('productName'); if (nameCell) nameCell.alignment = { wrapText: true, vertical: 'middle' };
      var urlCell  = row.getCell('productUrl');  if (urlCell)  urlCell.alignment  = { wrapText: true, vertical: 'middle' };
    });

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    var ts = new Date();
    var yyyy = ts.getFullYear();
    var mm = String(ts.getMonth()+1).padStart(2,'0');
    var dd = String(ts.getDate()).padStart(2,'0');
    // 탭 필터 중이면 파일명에 상태 라벨 포함
    var tabSuffix = '';
    if (_brandAppActiveStatusTab) {
      var activeTab = BRAND_APP_STATUS_TABS.find(function(t){ return t.code === _brandAppActiveStatusTab; });
      if (activeTab) tabSuffix = '-' + activeTab.label;
    }
    a.download = `brand-survey${tabSuffix}-${yyyy}${mm}${dd}.xlsx`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (신청 ' + list.length + '건 / 제품 ' + totalProductRows + '행)');
  } catch (e) {
    console.error('[exportBrandApplicationsExcel]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  }
}

// 임의 텍스트를 클립보드에 복사 (execCommand fallback 포함)
function copyTextToClipboard(text, successMsg) {
  var msg = successMsg || '복사됨';
  try {
    navigator.clipboard.writeText(text);
    toast(msg);
  } catch (e) {
    var tmp = document.createElement('input');
    tmp.value = text;
    document.body.appendChild(tmp);
    tmp.select();
    try { document.execCommand('copy'); toast(msg); } catch(_) { toast('복사 실패', 'error'); }
    document.body.removeChild(tmp);
  }
}

// 광고주 신청 페이지 URL을 클립보드에 복사 (영업팀 공유용)
function copyBrandSalesUrl() {
  copyTextToClipboard('https://sales.globalreverb.com/', 'https://sales.globalreverb.com/ 복사됨');
}

// 제품 URL 복사 (상세 모달의 상품 테이블에서 사용)
function copyBrandProductUrl(url) {
  copyTextToClipboard(url, 'URL 복사됨');
}

// ══════════════════════════════════════
// 브랜드 서베이 현황 대시보드 (#brand-dashboard)
// - brand_applications 전체 조회 후 클라이언트 집계
// - 차트: Form 도넛 / Status 도넛 / 일별 추이 바 (기본 7일, 토글 가능)
// - KPI: 전체·폼별·월별·대기·완료·평균 처리일·견적 합계
// ══════════════════════════════════════
var _brandDashApps = null;
var _brandTrendChart = null;
var _brandFormDonut = null;
var _brandStatusDonut = null;
var _brandTrendDays = 7;

var BRAND_STATUS_LABEL_KO = {
  new: '신규', reviewing: '검토중', quoted: '견적 전달', paid: '입금완료',
  kakao_room_created: '카톡방 생성',
  orient_sheet_sent: '오리엔시트 전달', schedule_sent: '일정 전달',
  campaign_registered: '캠페인 등록', done: '최종완료', rejected: '반려'
};
// 색상은 단계의 의미에 따라 유지 (코드 ↔ 의미 매핑 불변)
var BRAND_STATUS_COLOR = {
  new:                 '#C878A3',   // 핑크 (대기)
  reviewing:           '#E8A355',   // 오렌지
  quoted:              '#5B8FD6',   // 블루 (견적)
  paid:                '#6BB38E',   // 그린 (입금)
  kakao_room_created:  '#F4C95D',   // 옐로우 (카톡)
  orient_sheet_sent:   '#8C6BC0',   // 퍼플 (오리엔시트)
  schedule_sent:       '#D97AA6',   // 진한 핑크 (일정)
  campaign_registered: '#4CA070',   // 연한 그린 (등록)
  done:                '#1F9D55',   // 짙은 그린 (최종완료)
  rejected:            '#B0B0B8'    // 회색 (종료)
};
var BRAND_FUNNEL_STAGES = [
  {key:'new',                 nameKo:'접수',          nameEn:'new'},
  {key:'reviewing',           nameKo:'검토',          nameEn:'reviewing'},
  {key:'quoted',              nameKo:'견적 전달',     nameEn:'quoted'},
  {key:'paid',                nameKo:'입금 완료',     nameEn:'paid'},
  {key:'kakao_room_created',  nameKo:'카톡방 생성',   nameEn:'kakao_room_created'},
  {key:'orient_sheet_sent',   nameKo:'오리엔시트 전달', nameEn:'orient_sheet_sent'},
  {key:'schedule_sent',       nameKo:'일정 전달',     nameEn:'schedule_sent'},
  {key:'campaign_registered', nameKo:'캠페인 등록',   nameEn:'campaign_registered'},
  {key:'done',                nameKo:'최종 완료',     nameEn:'done'}
];
// 전환 깔때기용: status가 이 단계 이상이면 도달한 것으로 간주 (rejected 제외)
var BRAND_STATUS_ORDER_FOR_FUNNEL = {new:0, reviewing:1, quoted:2, paid:3, kakao_room_created:4, orient_sheet_sent:5, schedule_sent:6, campaign_registered:7, done:8, rejected:-1};

async function loadBrandDashboard() {
  // 로딩 표시
  setBrandDashLoading(true);
  _brandDashApps = await fetchBrandApplications();
  setBrandDashLoading(false);
  renderBrandDashboard();
}

function setBrandDashLoading(loading) {
  var ids = ['brandKpiTotal','brandKpiReviewer','brandKpiSeeding','brandKpiThisMonth',
             'brandKpiPending','brandKpiQuoted','brandKpiDone','brandKpiLeadTime',
             'brandKpiEstimated','brandKpiFinal'];
  if (loading) {
    ids.forEach(function(id){
      var el = $(id);
      if (el) el.innerHTML = '<span class="spinner" style="width:16px;height:16px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span>';
    });
  }
}

function renderBrandDashboard() {
  var apps = _brandDashApps || [];
  renderBrandKPIs(apps);
  renderBrandFunnel(apps);
  renderBrandFormDonut(apps);
  renderBrandStatusDonut(apps);
  renderBrandTrendChart(apps, _brandTrendDays);
  renderBrandRecent(apps);
  renderBrandLongPending(apps);
}

// 신청 배열을 제품 단위로 평탄화 — Phase B 통계용
// 각 항목 = {app, product, idx, status} 형태. products 비어있으면 1행 placeholder
function _flattenAppsToProducts(apps) {
  var flat = [];
  (apps || []).forEach(function(a) {
    var prods = Array.isArray(a.products) ? a.products : [];
    if (prods.length === 0) {
      flat.push({app: a, product: null, idx: 0, status: a.status || null});
    } else {
      prods.forEach(function(p, idx) {
        var s = (p && p.status) || a.status || null;
        flat.push({app: a, product: p, idx: idx, status: s});
      });
    }
  });
  return flat;
}

function renderBrandKPIs(apps) {
  var now = new Date();
  var thisMonth = now.toISOString().slice(0,7); // 'YYYY-MM'
  var reviewerN = apps.filter(function(a){ return a.form_type === 'reviewer'; }).length;
  var seedingN  = apps.filter(function(a){ return a.form_type === 'seeding'; }).length;
  var thisMonthN = apps.filter(function(a){ return (a.created_at||'').slice(0,7) === thisMonth; }).length;
  // status 단위 카운트는 제품 단위로 (Phase B). 합계·avgLead·estimated/finalSum은 신청 단위 유지(평탄화 시 X배 부풀림 방지)
  var flat = _flattenAppsToProducts(apps);
  var pendingN = flat.filter(function(f){ return f.status === 'new' || f.status === 'reviewing'; }).length;
  var quotedN  = flat.filter(function(f){ return f.status === 'quoted'; }).length;
  var doneN    = flat.filter(function(f){ return f.status === 'done'; }).length;

  // 평균 처리일: done 건만 대상, created_at -> reviewed_at 차이(폴백 updated_at)
  var leadDays = [];
  apps.forEach(function(a){
    if (a.status !== 'done') return;
    var start = a.created_at ? new Date(a.created_at).getTime() : null;
    var endSrc = a.reviewed_at || a.quote_sent_at || a.updated_at;
    var end = endSrc ? new Date(endSrc).getTime() : null;
    if (start && end && end >= start) {
      leadDays.push((end - start) / (1000*60*60*24));
    }
  });
  var avgLead = leadDays.length
    ? (leadDays.reduce(function(s,v){return s+v;},0) / leadDays.length)
    : null;

  // 견적 합계
  var estimated = apps.reduce(function(s,a){ return s + (Number(a.estimated_krw) || 0); }, 0);
  var finalSum = apps
    .filter(function(a){ return ['quoted','paid','kakao_room_created','orient_sheet_sent','schedule_sent','campaign_registered','done'].indexOf(a.status) !== -1; })
    .reduce(function(s,a){ return s + (Number(a.estimated_krw) || 0); }, 0);

  var fmtKRW = function(n) { return '₩ ' + Math.round(n).toLocaleString('ko-KR'); };

  $('brandKpiTotal').textContent    = apps.length;
  $('brandKpiReviewer').textContent = reviewerN;
  $('brandKpiSeeding').textContent  = seedingN;
  $('brandKpiThisMonth').textContent = thisMonthN;
  $('brandKpiPending').textContent  = pendingN;
  $('brandKpiQuoted').textContent   = quotedN;
  $('brandKpiDone').textContent     = doneN;
  $('brandKpiLeadTime').textContent = avgLead !== null ? avgLead.toFixed(1) + '일' : '—';
  $('brandKpiEstimated').textContent = fmtKRW(estimated);
  $('brandKpiFinal').textContent     = fmtKRW(finalSum);
}

function renderBrandFunnel(apps) {
  var host = $('brandFunnel');
  if (!host) return;
  // Phase B: 제품 단위 카운트 — 같은 신청에 제품 N개면 N번 카운트
  var flat = _flattenAppsToProducts(apps);
  if (!flat.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);text-align:center;padding:20px">데이터 없음</div>';
    return;
  }
  // rejected 제외한 총 접수 제품 수 (깔때기 분모)
  var activeTotal = flat.filter(function(f){ return f.status !== 'rejected'; }).length;

  // 컬럼 폭: 라벨 200 / 진행률 1fr / 도달 70 / 전환 110
  var GRID = 'grid-template-columns:200px 1fr 70px 110px;gap:10px;align-items:center';

  // 헤더 행 (각 컬럼 제목)
  var header = '<div style="display:grid;' + GRID + ';padding:0 0 8px;border-bottom:1px solid var(--line);margin-bottom:8px">'
    + '<div style="font-size:10px;font-weight:700;color:var(--muted);letter-spacing:0.06em;text-transform:uppercase">단계</div>'
    + '<div style="font-size:10px;font-weight:700;color:var(--muted);letter-spacing:0.06em;text-transform:uppercase">진행률</div>'
    + '<div style="font-size:10px;font-weight:700;color:var(--muted);letter-spacing:0.06em;text-transform:uppercase;text-align:right">도달</div>'
    + '<div style="font-size:10px;font-weight:700;color:var(--muted);letter-spacing:0.06em;text-transform:uppercase;text-align:right">전체비 · 전환율</div>'
  + '</div>';

  var rows = BRAND_FUNNEL_STAGES.map(function(stage, idx) {
    var threshold = BRAND_STATUS_ORDER_FOR_FUNNEL[stage.key];
    var reached = flat.filter(function(f){
      var ord = BRAND_STATUS_ORDER_FOR_FUNNEL[f.status];
      return ord !== -1 && ord >= threshold;
    }).length;
    var ratio = activeTotal ? Math.round((reached / activeTotal) * 100) : 0;
    var prev = idx === 0 ? activeTotal : flat.filter(function(f){
      var ord = BRAND_STATUS_ORDER_FOR_FUNNEL[f.status];
      var prevThreshold = BRAND_STATUS_ORDER_FOR_FUNNEL[BRAND_FUNNEL_STAGES[idx-1].key];
      return ord !== -1 && ord >= prevThreshold;
    }).length;
    var stepConv = prev ? Math.round((reached / prev) * 100) : 0;
    var isLast = idx === BRAND_FUNNEL_STAGES.length - 1;
    return '<div style="display:grid;' + GRID + ';padding:8px 0' + (isLast ? '' : ';border-bottom:1px dashed rgba(0,0,0,0.06)') + '">'
      + '<div style="font-size:12px;font-weight:600;color:var(--ink);line-height:1.4">'
        + esc(stage.nameKo)
        + ' <span style="font-size:10px;font-weight:400;color:var(--muted);margin-left:4px">' + esc(stage.nameEn) + '</span>'
      + '</div>'
      + '<div style="height:22px;background:rgba(200,120,163,.08);border-radius:100px;overflow:hidden;position:relative">'
      + '  <div style="height:100%;width:' + ratio + '%;background:linear-gradient(90deg,var(--pink),#E8A355);transition:width 0.4s"></div>'
      + '</div>'
      + '<div style="font-size:12px;font-weight:700;color:var(--ink);text-align:right;font-variant-numeric:tabular-nums">' + reached + '개</div>'
      + '<div style="font-size:11px;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap">' + ratio + '% · ' + (idx === 0 ? '—' : ('→' + stepConv + '%')) + '</div>'
      + '</div>';
  }).join('');
  host.innerHTML = header + rows;
}

function renderBrandFormDonut(apps) {
  var canvas = $('brandFormDonut');
  var empty = $('brandFormEmpty');
  var totalLabel = $('brandFormTotal');
  if (!canvas) return;
  if (_brandFormDonut) { _brandFormDonut.destroy(); _brandFormDonut = null; }

  var reviewerN = apps.filter(function(a){ return a.form_type === 'reviewer'; }).length;
  var seedingN  = apps.filter(function(a){ return a.form_type === 'seeding'; }).length;
  var total = reviewerN + seedingN;
  if (totalLabel) totalLabel.textContent = total ? ('전체 ' + total + '건') : '';
  if (!total) {
    canvas.style.display = 'none';
    if (empty) empty.style.display = 'flex';
    return;
  }
  canvas.style.display = 'block';
  if (empty) empty.style.display = 'none';

  _brandFormDonut = new Chart(canvas.getContext('2d'), {
    type: 'doughnut',
    data: {
      labels: ['리뷰어', '나노 시딩'],
      datasets: [{
        data: [reviewerN, seedingN],
        backgroundColor: ['#C878A3', '#5B8FD6'],
        borderColor: '#fff',
        borderWidth: 2
      }]
    },
    options: {
      responsive: true, maintainAspectRatio: false, cutout: '62%',
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } },
        tooltip: {
          callbacks: {
            label: function(ctx) {
              var pct = total ? Math.round((ctx.parsed / total) * 100) : 0;
              return ctx.label + ': ' + ctx.parsed + '건 (' + pct + '%)';
            }
          }
        }
      }
    }
  });
}

function renderBrandStatusDonut(apps) {
  var canvas = $('brandStatusDonut');
  var empty = $('brandStatusEmpty');
  var totalLabel = $('brandStatusTotal');
  if (!canvas) return;
  if (_brandStatusDonut) { _brandStatusDonut.destroy(); _brandStatusDonut = null; }

  // Phase B: 제품 단위 카운트
  var flat = _flattenAppsToProducts(apps);
  var keys = ['new','reviewing','quoted','paid','kakao_room_created','orient_sheet_sent','schedule_sent','campaign_registered','done','rejected'];
  var counts = keys.map(function(k){ return flat.filter(function(f){ return f.status === k; }).length; });
  var total = counts.reduce(function(s,n){ return s+n; }, 0);
  if (totalLabel) totalLabel.textContent = total ? ('전체 ' + total + '개') : '';
  if (!total) {
    canvas.style.display = 'none';
    if (empty) empty.style.display = 'flex';
    return;
  }
  canvas.style.display = 'block';
  if (empty) empty.style.display = 'none';

  _brandStatusDonut = new Chart(canvas.getContext('2d'), {
    type: 'doughnut',
    data: {
      labels: keys.map(function(k){ return BRAND_STATUS_LABEL_KO[k]; }),
      datasets: [{
        data: counts,
        backgroundColor: keys.map(function(k){ return BRAND_STATUS_COLOR[k]; }),
        borderColor: '#fff',
        borderWidth: 2
      }]
    },
    options: {
      responsive: true, maintainAspectRatio: false, cutout: '62%',
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } },
        tooltip: {
          callbacks: {
            label: function(ctx) {
              var pct = total ? Math.round((ctx.parsed / total) * 100) : 0;
              return ctx.label + ': ' + ctx.parsed + '개 (' + pct + '%)';
            }
          }
        }
      }
    }
  });
}

function renderBrandTrendChart(apps, days) {
  var canvas = $('brandTrendChart');
  if (!canvas) return;
  if (_brandTrendChart) { _brandTrendChart.destroy(); _brandTrendChart = null; }

  var now = new Date();
  var labels = [];
  var reviewerData = [];
  var seedingData = [];
  for (var i = days - 1; i >= 0; i--) {
    var d = new Date(now);
    d.setDate(d.getDate() - i);
    var dateStr = d.toISOString().slice(0, 10);
    labels.push((d.getMonth()+1) + '/' + d.getDate());
    reviewerData.push(apps.filter(function(a){ return a.form_type === 'reviewer' && (a.created_at||'').slice(0,10) === dateStr; }).length);
    seedingData.push(apps.filter(function(a){ return a.form_type === 'seeding' && (a.created_at||'').slice(0,10) === dateStr; }).length);
  }

  _brandTrendChart = new Chart(canvas, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        { label: '리뷰어', data: reviewerData, backgroundColor: '#C878A3', borderRadius: 3, stack: 'applications' },
        { label: '나노 시딩',    data: seedingData,  backgroundColor: '#5B8FD6', borderRadius: 3, stack: 'applications' }
      ]
    },
    options: {
      responsive: true, maintainAspectRatio: false,
      plugins: {
        legend: { position: 'bottom', labels: { font: { size: 11 }, boxWidth: 12 } }
      },
      scales: {
        x: { stacked: true, ticks: { font: { size: 10 } }, grid: { display: false } },
        y: { stacked: true, beginAtZero: true, ticks: { stepSize: 1, font: { size: 10 } }, grid: { color: 'rgba(0,0,0,.05)' } }
      }
    }
  });
}

function switchBrandTrendPeriod(days, btn) {
  _brandTrendDays = days;
  document.querySelectorAll('.brand-trend-btn').forEach(function(b){ b.classList.remove('on'); });
  if (btn) btn.classList.add('on');
  renderBrandTrendChart(_brandDashApps || [], days);
}

function renderBrandRecent(apps) {
  var host = $('brandRecentList');
  if (!host) return;
  var top5 = apps.slice().sort(function(a,b){
    return (b.created_at || '').localeCompare(a.created_at || '');
  }).slice(0, 5);
  if (!top5.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);padding:20px;text-align:center">데이터 없음</div>';
    return;
  }
  host.innerHTML = top5.map(function(a){
    var formLabel = a.form_type === 'reviewer' ? '리뷰어' : (a.form_type === 'seeding' ? '나노 시딩' : a.form_type);
    var dateStr = (a.created_at || '').slice(0,10);
    var statusColor = BRAND_STATUS_COLOR[a.status] || '#888';
    var statusLabel = BRAND_STATUS_LABEL_KO[a.status] || a.status;
    return '<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid var(--line);border-radius:8px;cursor:pointer;transition:background 0.15s" onmouseover="this.style.background=\'rgba(200,120,163,.04)\'" onmouseout="this.style.background=\'transparent\'" onclick=\"openBrandAppFromDashboard(\'' + esc(a.id) + '\')">'
      + '<div style="flex:1;min-width:0">'
      +   '<div style="font-size:12px;font-weight:700;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(a.brand_name || '(브랜드명 없음)') + '</div>'
      +   '<div style="font-size:10px;color:var(--muted);margin-top:2px">' + esc(formLabel) + ' · ' + esc(a.application_no || '') + ' · ' + esc(dateStr) + '</div>'
      + '</div>'
      + '<span style="flex-shrink:0;font-size:10px;font-weight:700;padding:3px 8px;border-radius:10px;background:' + statusColor + '20;color:' + statusColor + '">' + esc(statusLabel) + '</span>'
      + '</div>';
  }).join('');
}

function renderBrandLongPending(apps) {
  var host = $('brandLongPendingList');
  var countLabel = $('brandLongPendingCount');
  if (!host) return;
  var threeDaysAgo = Date.now() - 3 * 24 * 60 * 60 * 1000;
  var longPending = apps.filter(function(a){
    if (a.status !== 'new') return false;
    var ts = a.created_at ? new Date(a.created_at).getTime() : 0;
    return ts > 0 && ts < threeDaysAgo;
  }).sort(function(a,b){
    return (a.created_at || '').localeCompare(b.created_at || '');
  });
  if (countLabel) countLabel.textContent = longPending.length ? (longPending.length + '건') : '';
  if (!longPending.length) {
    host.innerHTML = '<div style="font-size:12px;color:var(--muted);padding:20px;text-align:center">3일 이상 대기 중인 신청 없음</div>';
    return;
  }
  host.innerHTML = longPending.slice(0,5).map(function(a){
    var formLabel = a.form_type === 'reviewer' ? '리뷰어' : '나노 시딩';
    var dateStr = (a.created_at || '').slice(0,10);
    var waitDays = Math.floor((Date.now() - new Date(a.created_at).getTime()) / (1000*60*60*24));
    return '<div style="display:flex;align-items:center;gap:10px;padding:8px 10px;border:1px solid #E8A355;border-radius:8px;cursor:pointer;transition:background 0.15s;background:rgba(232,163,85,.04)" onmouseover="this.style.background=\'rgba(232,163,85,.1)\'" onmouseout="this.style.background=\'rgba(232,163,85,.04)\'" onclick=\"openBrandAppFromDashboard(\'' + esc(a.id) + '\')">'
      + '<div style="flex:1;min-width:0">'
      +   '<div style="font-size:12px;font-weight:700;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap">' + esc(a.brand_name || '(브랜드명 없음)') + '</div>'
      +   '<div style="font-size:10px;color:var(--muted);margin-top:2px">' + esc(formLabel) + ' · ' + esc(dateStr) + '</div>'
      + '</div>'
      + '<span style="flex-shrink:0;font-size:10px;font-weight:700;padding:3px 8px;border-radius:10px;background:#E8A35520;color:#E8A355">' + waitDays + '일 대기</span>'
      + '</div>';
  }).join('');
}

var _brandAppHistoryCounts = {};
var _brandAppMemoSummaries = {};      // {`${appId}_${productIdx}`: {count, latest}} — migration 123 이후 페어 키
var _brandAppMemoModalCurrentId = null;
var _brandAppMemoModalCurrentProductIdx = 0;  // 현재 열린 모달의 제품 인덱스
var _brandAppMemoModalCache = [];     // open된 신청·제품의 메모 배열 (memory)

// 인라인 편집 성공 후 카운트 캐시만 +1 (배지 미표시. 다음 더보기 메뉴 열 때 새 카운트 반영)
function _refreshBrandAppHistoryButton(id) {
  _brandAppHistoryCounts[id] = (_brandAppHistoryCounts[id] || 0) + 1;
}

// 신청 행 더보기 메뉴 — 캠페인 더보기 패턴(camp-more-menu) 재사용
function toggleBrandAppRowMenu(e, btnEl, appId) {
  e.stopPropagation();
  document.querySelectorAll('.camp-more-menu').forEach(function(d){ d.remove(); });

  var rect = btnEl.getBoundingClientRect();
  var menu = document.createElement('div');
  menu.className = 'camp-more-menu';
  var hcnt = (typeof _brandAppHistoryCounts !== 'undefined' && _brandAppHistoryCounts) ? (_brandAppHistoryCounts[appId] || 0) : 0;
  var historyItem = hcnt > 0
    ? '<div class="camp-more-item" onclick="openBrandAppHistoryModal(\'' + esc(appId) + '\')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">history</span>이력 (' + hcnt + ')</div>'
    : '<div class="camp-more-item" style="opacity:.4;cursor:not-allowed" title="변경 이력 없음"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">history</span>이력 (0)</div>';
  menu.innerHTML = ''
    + '<div class="camp-more-item" onclick="openBrandAppEditModal(\'' + esc(appId) + '\')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">edit</span>수정</div>'
    + '<div class="camp-more-item" onclick="osIssueFromApplication(\'' + esc(appId) + '\')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">assignment_turned_in</span>시스템 오리엔시트 발급</div>'
    + '<div class="camp-more-item" onclick="osOpenGoogleSheetUrlModal(\'' + esc(appId) + '\')"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">link</span>구글시트 URL 등록</div>'
    + historyItem;
  document.body.appendChild(menu);
  _positionMenuInViewport(menu, rect, {placement: 'left-of'});

  setTimeout(function() {
    document.addEventListener('click', function _close(ev) {
      if (!menu.contains(ev.target)) {
        menu.remove();
        document.removeEventListener('click', _close);
      }
    });
  }, 0);
}

// 셀프 오리엔시트 열 셀 — 신청에 연결된 orient_sheets 요약(최근 상태 + 추가 건수). 없으면 —.
// 만료는 클라 판정(조회 함수가 status 미전환 — consumed 아닌데 기한 지나면 만료 표시).
// 시스템 오리엔시트 셀 = 「보기(N)」 버튼(0건 포함). 클릭 시 그 신청의 오리엔시트 목록 모달.
//   상태·링크·상세는 모달(현황 표 형식)에서 확인 — 셀은 건수만 간결히.
function renderSelfOrientCell(appId) {
  var count = (_orientByApp && _orientByApp[appId] && _orientByApp[appId].length) || 0;
  return '<button type="button" class="btn btn-ghost btn-xs" style="display:inline-flex;align-items:center;gap:3px" '
    + 'onclick="event.stopPropagation();openBrandAppOrientListModal(\'' + esc(appId) + '\')" title="발급된 오리엔시트 목록 보기">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:14px">visibility</span>보기(' + count + ')</button>';
}

// 오리엔시트 셀 미니 버튼(아이콘 + 라벨). href 가 'javascript:void(0)' 이면 onclick 동작 버튼.
function orientMiniBtn(icon, text, href, onclick) {
  // href·icon 은 raw 로 받아 여기서 한 번만 esc (호출부 이중 이스케이프 방지)
  var style = 'display:inline-flex;align-items:center;gap:2px;padding:1px 7px;border:1px solid var(--pink);border-radius:6px;color:var(--pink);font-size:11px;font-weight:600;text-decoration:none;line-height:1.6;vertical-align:middle';
  var oc = onclick ? (' onclick="' + onclick + '"') : ' onclick="event.stopPropagation()"';
  var tgt = (href && href !== 'javascript:void(0)') ? ' target="_blank" rel="noopener noreferrer"' : '';
  return '<a href="' + esc(href) + '"' + tgt + oc + ' title="' + esc(text) + '" style="' + style + '">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:13px">' + esc(icon) + '</span>' + esc(text) + '</a>';
}

// 신청 목록 「오리엔시트」 통합 셀 — 시스템(orient_sheets) + 구글시트(orient_sheet_sent_url) 두 줄.
// 시스템=상태+작성링크, 구글시트=열기 링크만(등록·수정은 더보기 「구글시트 URL 등록」 모달).
function renderOrientCombinedCell(a) {
  // 시스템 = orient_sheets(상태+작성링크), 구글시트 = 외부 URL 열기만.
  // 등록된 줄만 표시 — 시스템 발급분이 있으면 시스템 줄, 구글시트 URL이 있으면 구글시트 줄.
  // 둘 다 없으면 「—」 한 줄(등록·수정은 행 더보기 「시스템 오리엔시트 발급」/「구글시트 URL 등록」).
  var hasGs = !!safeBrandUrl(a.orient_sheet_sent_url);
  // 시스템 줄은 항상 「보기(N)」 버튼 표시(0건 포함). 구글시트 줄은 외부 URL 있을 때만.
  var lines = '<div style="display:flex;align-items:center;gap:5px">'
    + '<span style="color:var(--muted);font-size:12px;font-weight:600;flex-shrink:0;width:48px">시스템</span>'
    + '<span style="min-width:0">' + renderSelfOrientCell(a.id) + '</span>'
  + '</div>';
  if (hasGs) {
    lines += '<div style="display:flex;align-items:center;gap:5px;min-height:18px">'
      + '<span style="color:var(--muted);font-size:12px;font-weight:600;flex-shrink:0;width:48px">구글시트</span>'
      + '<span style="min-width:0;flex:1">' + renderGoogleSheetLinkOnly(a.orient_sheet_sent_url) + '</span>'
    + '</div>';
  }
  return '<div style="display:flex;flex-direction:column;gap:3px;min-height:36px;justify-content:center">' + lines + '</div>';
}

// 신청의 시스템 오리엔시트 목록 모달 (오리엔시트 현황 표 형식). 「보기(N)」 클릭 진입.
function ensureBrandAppOrientListModal() {
  if (document.getElementById('brandAppOrientListModal')) return;
  var html = '<div class="modal-overlay" id="brandAppOrientListModal">'
    + '<div class="modal" style="max-width:640px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">'
    + '<div class="modal-header"><h2>오리엔시트 목록</h2>'
    + '<button type="button" class="modal-close-btn" onclick="osCloseModal(\'brandAppOrientListModal\')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>'
    + '<div class="modal-body" style="padding:18px;overflow-y:auto;flex:1" id="brandAppOrientListBody"></div>'
    + '<div class="modal-footer"><button type="button" class="btn btn-ghost" onclick="osCloseModal(\'brandAppOrientListModal\')">닫기</button></div>'
    + '</div></div>';
  document.body.insertAdjacentHTML('beforeend', html);
  // 동적 생성 모달이라 부팅 시 옵저버(정적 모달 대상)에 안 잡힘 — 여기서 드래그·리사이즈 옵저버 부착
  if (typeof initDraggableModals === 'function') initDraggableModals();
}

function brandAppOrientListRow(s) {
  var stBadge = (typeof osBadge === 'function' && typeof osStatusOf === 'function') ? osBadge(osStatusOf(s)) : esc(s.status || '');
  var summary = (typeof osCardsSummary === 'function') ? osCardsSummary(s.data) : '';
  var link = (typeof osBuildLink === 'function') ? osBuildLink(s.token) : '';
  var copyBtn = link ? '<button type="button" class="btn btn-ghost btn-xs" onclick="event.stopPropagation();copyTextToClipboard(\'' + esc(link) + '\',\'작성 링크가 복사되었습니다.\')">링크 복사</button> ' : '';
  return '<tr style="border-top:1px solid var(--line,#eee)">'
    + '<td style="padding:8px 6px">' + summary + '</td>'
    + '<td style="padding:8px 6px">' + stBadge + '</td>'
    + '<td style="padding:8px 6px;font-size:12px;color:var(--muted)">' + (s.created_at ? formatDate(s.created_at) : '-') + '</td>'
    + '<td style="padding:8px 6px;font-size:12px;color:var(--muted)">' + (s.token_expires_at ? formatDate(s.token_expires_at) : '-') + '</td>'
    + '<td style="padding:8px 6px;white-space:nowrap">' + copyBtn
    + '<button type="button" class="btn btn-primary btn-xs" onclick="event.stopPropagation();osCloseModal(\'brandAppOrientListModal\');osOpenDetail(\'' + esc(s.id) + '\')">상세</button></td>'
  + '</tr>';
}

function openBrandAppOrientListModal(appId) {
  ensureBrandAppOrientListModal();
  var a = (_brandApps || []).find(function (x) { return x.id === appId; }) || {};
  var sheets = (_orientByApp && _orientByApp[appId]) || [];
  var body = document.getElementById('brandAppOrientListBody');
  var titleStyle = 'font-size:13px;font-weight:800;color:var(--ink);margin:0 0 8px;display:flex;align-items:center;gap:6px';

  // 시스템 오리엔시트 섹션
  var sysInner;
  if (!sheets.length) {
    sysInner = '<div style="color:var(--muted);font-size:13px;padding:4px 0 10px">아직 발급된 오리엔시트가 없습니다.</div>'
      + '<button type="button" class="btn btn-primary btn-sm" onclick="osCloseModal(\'brandAppOrientListModal\');osIssueFromApplication(\'' + esc(appId) + '\')">오리엔시트 발급</button>';
  } else {
    sysInner = '<table style="width:100%;border-collapse:collapse;font-size:13px">'
      + '<thead><tr style="background:var(--surface-dim)">'
      + '<th style="text-align:left;padding:8px 6px;font-weight:700">모집 형식</th>'
      + '<th style="text-align:left;padding:8px 6px;font-weight:700">상태</th>'
      + '<th style="text-align:left;padding:8px 6px;font-weight:700">발급일</th>'
      + '<th style="text-align:left;padding:8px 6px;font-weight:700">작성 기한</th>'
      + '<th style="text-align:left;padding:8px 6px;font-weight:700">관리</th></tr></thead>'
      + '<tbody>' + sheets.map(brandAppOrientListRow).join('') + '</tbody></table>';
  }

  // 구글시트 섹션 (외부 URL — orient_sheet_sent_url)
  var gsUrl = (typeof safeBrandUrl === 'function') ? safeBrandUrl(a.orient_sheet_sent_url) : '';
  var gsInner = '<div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">';
  if (gsUrl) {
    gsInner += (typeof renderGoogleSheetLinkOnly === 'function' ? renderGoogleSheetLinkOnly(a.orient_sheet_sent_url) : esc(gsUrl))
      + '<button type="button" class="btn btn-ghost btn-xs" onclick="osCloseModal(\'brandAppOrientListModal\');osOpenGoogleSheetUrlModal(\'' + esc(appId) + '\')">URL 수정</button>';
  } else {
    gsInner += '<span style="color:var(--muted);font-size:13px">등록된 구글시트 URL이 없습니다.</span>'
      + '<button type="button" class="btn btn-ghost btn-xs" onclick="osCloseModal(\'brandAppOrientListModal\');osOpenGoogleSheetUrlModal(\'' + esc(appId) + '\')">URL 등록</button>';
  }
  gsInner += '</div>';

  body.innerHTML =
    '<div><div style="' + titleStyle + '"><span class="material-icons-round notranslate" translate="no" style="font-size:17px;color:var(--pink)">assignment</span>시스템 오리엔시트</div>' + sysInner + '</div>'
    + '<div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--line,#eee)"><div style="' + titleStyle + '"><span class="material-icons-round notranslate" translate="no" style="font-size:17px;color:var(--pink)">description</span>구글시트</div>' + gsInner + '</div>';
  var overlay = document.getElementById('brandAppOrientListModal');
  overlay.classList.add('open');
  // 첫 열림에도 즉시 드래그·리사이즈 적용(옵저버는 비동기라 한 틱 지연)
  if (typeof _applyDraggableIfOpen === 'function') _applyDraggableIfOpen(overlay);
}

// 구글시트 외부 URL — 열기 링크만(✎ 편집 없음. 등록은 더보기 「구글시트 URL 등록」 모달).
function renderGoogleSheetLinkOnly(urlOrNull) {
  var safeUrl = safeBrandUrl(urlOrNull);
  return safeUrl
    ? orientMiniBtn('open_in_new', '열기', safeUrl, null)
    : '<span style="color:var(--muted);font-size:11px">—</span>';
}

// ══════════════════════════════════════
// BRANDS MASTER (브랜드 관리 페인 — migration 082/083)
// ══════════════════════════════════════
var _brandsCache = [];
var _brandCampCounts = {};  // {brand_id: 캠페인 수} — 브랜드 목록 「캠페인 수」 컬럼용
var _brandCompanyMap = {};  // {company_id: 회사명} — 목록 회사명을 company_id 기준 표시(company_name 보조컬럼 미동기화 대비)
var _brandsCurrentId = null;
var brandsLazy;
var BRANDS_PAGE_SIZE = 50;

async function loadBrandsPane() {
  var tbody = $('brandsTableBody');
  if (tbody) tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  _brandsCache = await fetchBrands();
  _brandCampCounts = (typeof fetchCampaignCountsByBrand === 'function') ? await fetchCampaignCountsByBrand() : {};
  // 회사명 맵 — company_id 기준 표시(brands.company_name 보조컬럼이 미동기화일 수 있어 마스터 우선)
  var _companies = (typeof fetchCompanies === 'function') ? (await fetchCompanies({ status: 'all' }) || []) : [];
  _brandCompanyMap = {};
  _companies.forEach(function(c){ _brandCompanyMap[c.id] = c.name_ko || c.name_ja || c.name_en || ''; });
  renderBrandsList();
}

function renderBrandsList() {
  var tbody = $('brandsTableBody');
  if (!tbody) return;
  var statusF = $('brandsStatusFilter')?.value || '';
  var q = (($('brandsSearch')?.value) || '').trim().toLowerCase();
  var list = (_brandsCache || []).filter(function(b){
    if (statusF && b.status !== statusF) return false;
    if (q) {
      var hay = ((b.name||'') + ' ' + (b.name_ja||'') + ' ' + (b.name_en||'') + ' ' + (b.company_name||'') + ' ' + ((b.company_id && _brandCompanyMap[b.company_id])||'') + ' ' + (b.brand_no||'') + ' ' + (b.primary_email||'') + ' ' + (b.billing_email||'')).toLowerCase();
      if (hay.indexOf(q) < 0) return false;
    }
    return true;
  });
  var count = $('brandsTotalCount');
  if (count) count.textContent = '(' + list.length + ' / 전체 ' + (_brandsCache||[]).length + ')';
  if (list.length === 0) {
    tbody.innerHTML = '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:40px">브랜드가 없습니다</td></tr>';
    return;
  }
  var renderRow = function(b) {
    var memoText = (b.memo || '').trim();
    var memoCell = memoText
      ? '<div style="font-size:11px;color:var(--ink);display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;line-height:1.4" title="' + esc(memoText) + '">' + esc(memoText) + '</div>'
      : '<span style="color:var(--muted)">—</span>';
    var statusBadge = b.status === 'archived'
      ? '<span style="background:#F0F0F0;color:#888;font-size:10px;font-weight:600;padding:2px 8px;border-radius:10px">비활성</span>'
      : '<span style="background:#E8F5E9;color:#16a34a;font-size:10px;font-weight:600;padding:2px 8px;border-radius:10px">활성</span>';
    return '<tr data-id="' + esc(b.id) + '" style="cursor:pointer" onclick="openBrandDetailModal(\'' + esc(b.id) + '\')">'
      + '<td style="font-size:12px;color:var(--ink)">' + esc((b.company_id && _brandCompanyMap[b.company_id]) || b.company_name || '—') + '</td>'
      + '<td>'
        + '<div style="font-size:10px;color:var(--muted);font-weight:600;margin-bottom:2px;font-variant-numeric:tabular-nums">' + esc(b.brand_no || '—') + '</div>'
        + '<div style="font-weight:600;color:var(--ink)">' + esc(b.name || '—') + '</div>'
        + (b.name_ja ? '<div style="font-size:11px;color:var(--muted);margin-top:2px">' + esc(b.name_ja) + '</div>' : '')
      + '</td>'
      + '<td>' + esc(b.primary_contact_name || '—') + (b.primary_phone ? '<div style="font-size:11px;color:var(--muted);margin-top:2px">' + esc(formatPhoneDisplay(b.primary_phone)) + '</div>' : '') + '</td>'
      + '<td style="font-size:12px;word-break:break-all">' + esc(b.primary_email || '—') + '</td>'
      + '<td style="text-align:center;font-variant-numeric:tabular-nums;font-weight:600">' + (b.total_applications || 0) + '</td>'
      + '<td style="text-align:center;font-variant-numeric:tabular-nums;font-weight:600">' + ((_brandCampCounts && _brandCampCounts[b.id]) || 0) + '</td>'
      + '<td style="font-size:11px;color:var(--muted)">' + (b.last_applied_at ? fmtDate(b.last_applied_at) : '—') + '</td>'
      + '<td>' + statusBadge + '</td>'
      + '<td>' + memoCell + '</td>'
      + '</tr>';
  };
  if (brandsLazy) brandsLazy.destroy();
  brandsLazy = mountLazyList({
    tbody: tbody,
    scrollRoot: tbody.closest('.admin-table-wrap'),
    rows: list,
    renderRow: renderRow,
    pageSize: BRANDS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:40px">브랜드가 없습니다</td></tr>'
  });
}

async function openBrandDetailModal(id) {
  _brandsCurrentId = id;
  var modal = $('brandDetailModal');
  var titleEl = $('brandDetailTitle');
  var bodyEl = $('brandDetailBody');
  var footerEl = $('brandDetailFooter');
  if (!modal || !bodyEl) return;
  bodyEl.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)"><span class="spinner" style="width:18px;height:18px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink);display:inline-block;vertical-align:middle;margin-right:6px"></span>불러오는 중…</div>';
  if (footerEl) footerEl.innerHTML = '';
  modal.classList.add('open');
  var [b, apps, companies, campCount] = await Promise.all([
    fetchBrandById(id),
    fetchBrandApplicationsByBrand(id),
    (typeof fetchCompanies === 'function' ? fetchCompanies({ status: 'all' }) : Promise.resolve([])),
    (typeof countCampaignsByBrand === 'function' ? countCampaignsByBrand(id) : Promise.resolve(0))
  ]);
  if (!b) { bodyEl.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">데이터를 불러올 수 없습니다</div>'; return; }
  _brandFormCompanies = companies || [];
  if (titleEl) titleEl.innerHTML = renderBrandDetailHeaderHtml(b);
  bodyEl.innerHTML = renderBrandDetailFormHtml(b, apps);
  renderBrandContactsRows();
  // 삭제(연결 0건만)·병합(연결 유무 무관) 버튼 — campaign_admin 이상만.
  var isAdm = (typeof isCampaignAdminOrAbove === 'function' && isCampaignAdminOrAbove());
  var canDeleteBrand = (apps.length === 0) && (campCount === 0) && isAdm;
  if (footerEl) footerEl.innerHTML = ''
    + (canDeleteBrand
        ? '<button class="btn btn-ghost btn-sm" onclick="deleteBrandConfirm()" style="display:inline-flex;align-items:center;gap:4px;color:#c0392b"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete_outline</span>삭제</button>'
        : '')
    + (isAdm
        ? '<button class="btn btn-ghost btn-sm" onclick="openBrandMergeModal(\'' + esc(id) + '\')" style="display:inline-flex;align-items:center;gap:4px;color:#c0392b"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">merge</span>병합</button>'
        : '')
    + '<button class="btn btn-ghost btn-sm" onclick="closeBrandDetailModal();osOpenCreate({brandId:\'' + esc(id) + '\',lockBrand:true})" style="display:inline-flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">assignment_turned_in</span>오리엔시트 발급</button>'
    + '<button class="btn btn-ghost btn-sm" onclick="closeBrandDetailModal();openNewBrandAppModal(\'' + esc(id) + '\')" style="display:inline-flex;align-items:center;gap:4px;margin-right:auto"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">add</span>이 브랜드로 신규 신청</button>'
    + '<button class="btn btn-ghost btn-sm" onclick="closeBrandDetailModal()">닫기</button>'
    + '<button class="btn btn-primary btn-sm" onclick="saveBrandDetail()">저장</button>';
}

function closeBrandDetailModal() {
  var modal = $('brandDetailModal');
  if (modal) modal.classList.remove('open');
  _brandsCurrentId = null;
}

// 브랜드 삭제 — 연결 0건 빈 브랜드만(서버 delete_brand RPC 가 재검증). 되돌릴 수 없음.
async function deleteBrandConfirm() {
  var id = _brandsCurrentId;
  if (!id) return;
  if (!confirm('이 브랜드를 삭제할까요?\n연결된 캠페인·신청이 없는 빈 브랜드만 삭제됩니다. 되돌릴 수 없습니다.')) return;
  var result = await deleteBrand(id);
  if (!result.ok) { toast('삭제 실패: ' + (result.error || '알 수 없는 오류'), 'error'); return; }
  toast('브랜드를 삭제했습니다');
  closeBrandDetailModal();
  if (typeof refreshPane === 'function') { await refreshPane('brands'); }
  else if (typeof loadBrandsPane === 'function') { await loadBrandsPane(); }
}

// 브랜드 병합 모달 — 같은 회사 다른 활성 브랜드로 source 의 캠페인·신청 이동(채번 재발급). 원본 보관.
async function openBrandMergeModal(sourceId) {
  var src = (_brandsCache || []).find(function(b){ return b.id === sourceId; });
  if (!src) return;
  // 회사 무관 병합 허용(2026-06-09 — 회사 등록→연결→병합 단계 과다 해소). 오병합 방지는 모달 정보·확인으로.
  var campCount = (typeof countCampaignsByBrand === 'function') ? await countCampaignsByBrand(sourceId) : 0;
  var apps = (typeof fetchBrandApplicationsByBrand === 'function') ? (await fetchBrandApplicationsByBrand(sourceId) || []) : [];
  var srcCo = (src.company_id && _brandCompanyMap[src.company_id]) || src.company_name || '회사 미등록';
  var targets = (_brandsCache || []).filter(function(b){
    return b.id !== sourceId && b.status === 'active';
  });
  if (!targets.length) { toast('병합할 다른 활성 브랜드가 없습니다', 'warn'); return; }
  var opts = targets.map(function(b){
    var co = (b.company_id && _brandCompanyMap[b.company_id]) || b.company_name || '회사 미등록';
    return '<option value="' + esc(b.id) + '">' + esc(b.name || b.brand_no || '브랜드') + (b.name_ja ? ' (' + esc(b.name_ja) + ')' : '') + ' · ' + esc(b.brand_no || '') + ' · ' + esc(co) + '</option>';
  }).join('');
  var ov = document.createElement('div');
  ov.id = 'brandMergeOverlay';
  ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:700;display:flex;align-items:center;justify-content:center';
  ov.innerHTML = '<div style="background:#fff;border-radius:12px;width:480px;max-width:92vw;padding:24px;box-shadow:0 12px 48px rgba(0,0,0,.25)">'
    + '<h3 style="margin:0 0 8px;font-size:16px;font-weight:700;color:var(--ink)">브랜드 병합</h3>'
    + '<p style="margin:0 0 16px;font-size:12px;color:var(--muted);line-height:1.6">원본 「' + esc(src.name || src.brand_no || '') + '」(' + esc(srcCo) + ')의 <b>캠페인 ' + campCount + '건·신청 ' + apps.length + '건</b>을 아래 브랜드로 옮기고, 원본은 보관 처리합니다.<br>캠페인·신청 번호는 재발급되며(옛 번호는 보존) <b style="color:#c0392b">되돌릴 수 없습니다.</b></p>'
    + '<label style="font-size:12px;font-weight:600;color:var(--ink);display:block;margin-bottom:6px">병합 대상 브랜드 <span style="color:var(--muted);font-weight:400">(회사가 달라도 선택 가능 — 대상을 정확히 확인하세요)</span></label>'
    + '<select id="brandMergeTarget" style="width:100%;padding:9px;border:1px solid var(--line);border-radius:8px;font-size:14px;margin-bottom:20px">' + opts + '</select>'
    + '<div style="display:flex;justify-content:flex-end;gap:8px">'
      + '<button class="btn btn-ghost btn-sm" onclick="closeBrandMergeModal()">취소</button>'
      + '<button class="btn btn-primary btn-sm" style="background:#c0392b" onclick="doBrandMerge(\'' + esc(sourceId) + '\')">병합 실행</button>'
    + '</div></div>';
  document.body.appendChild(ov);
}
function closeBrandMergeModal() {
  var ov = $('brandMergeOverlay');
  if (ov) ov.remove();
}
async function doBrandMerge(sourceId) {
  var sel = $('brandMergeTarget');
  var targetId = sel ? sel.value : '';
  if (!targetId) { toast('대상 브랜드를 선택하세요', 'warn'); return; }
  if (!confirm('정말 병합할까요?\n캠페인·신청 번호가 재발급되며 되돌릴 수 없습니다.')) return;
  var result = await mergeBrands(sourceId, targetId);
  if (!result.ok) { toast('병합 실패: ' + (result.error || '알 수 없는 오류'), 'error'); return; }
  var d = result.data || {};
  toast('병합 완료 — 캠페인 ' + (d.moved_campaigns || 0) + '건·신청 ' + (d.moved_apps || 0) + '건 이동');
  closeBrandMergeModal();
  closeBrandDetailModal();
  if (typeof refreshPane === 'function') { await refreshPane('brands'); }
  else if (typeof loadBrandsPane === 'function') { await loadBrandsPane(); }
}

// 헤더 — brand_no | name | status select (드롭다운, 활성/비활성 명확히 선택)
//   신청 등록 모달과 동일하게 제목 + 부제(설명/상태) 2단 구조
function renderBrandDetailHeaderHtml(b) {
  var status = b.status || 'active';
  var subtitle = b.company_name
    ? '회사명: ' + esc(b.company_name)
    : '브랜드 마스터 정보 · 담당자 · 콘텐츠 · 영업 메모를 한 곳에서 관리';
  return ''
    + '<div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">'
      + '<span style="background:#F0F0F0;color:#555;font-size:11px;font-weight:600;padding:3px 10px;border-radius:4px;font-variant-numeric:tabular-nums">' + esc(b.brand_no || '신규') + '</span>'
      + '<span style="font-weight:700;color:var(--ink);font-size:14px">' + esc(b.name || '새 브랜드') + '</span>'
      + '<select id="brandFormStatus" onchange="syncBrandStatusVisual(this)" style="font-size:11px;font-weight:600;padding:4px 22px 4px 10px;border-radius:6px;border:1px solid var(--line);cursor:pointer;background-color:' + (status === 'archived' ? '#F0F0F0' : '#E8F5E9') + ';color:' + (status === 'archived' ? '#666' : '#16a34a') + '">'
        + '<option value="active"' + (status === 'active' ? ' selected' : '') + '>● 활성</option>'
        + '<option value="archived"' + (status === 'archived' ? ' selected' : '') + '>● 비활성</option>'
      + '</select>'
    + '</div>'
    + '<div style="font-size:11px;color:var(--muted);margin-top:4px">' + subtitle + '</div>';
}

function syncBrandStatusVisual(sel) {
  if (!sel) return;
  if (sel.value === 'archived') {
    sel.style.backgroundColor = '#F0F0F0';
    sel.style.color = '#666';
  } else {
    sel.style.backgroundColor = '#E8F5E9';
    sel.style.color = '#16a34a';
  }
}

// brands.contacts jsonb 작업용 메모리 캐시 (모달 한 인스턴스만 동시 가능)
var _brandFormContacts = [];
// 브랜드 폼 회사 드롭다운용 회사 목록 캐시 (브랜드 상세/신규 모달 열 때 로드)
var _brandFormCompanies = [];
function _genContactId() {
  if (window.crypto?.randomUUID) return window.crypto.randomUUID();
  return 'c-' + Date.now() + '-' + Math.random().toString(36).slice(2, 9);
}

// 브랜드 상세 모달 「이 브랜드의 신청 내역」 전용 — 신청별 펼침 카드 (조회 전용)
//   카드 헤더: 신청번호·폼·상태·신청일 + 합산(제품수·총수량·최종 견적·VAT·예상 견적)
//   카드 본문(펼치면): 제품 N행 표(제품명·URL·수량·단가엔/원·모집비·이체수수료·소계)
function renderBrandAppsBundledView(apps) {
  if (!apps || apps.length === 0) {
    return '<div style="padding:14px;text-align:center;color:var(--muted);font-size:12px;background:var(--surface-dim);border-radius:6px">신청 내역 없음</div>';
  }
  return '<div style="display:flex;flex-direction:column;gap:8px">'
    + apps.map(renderBrandAppBundleCard).join('')
    + '</div>';
}

function renderBrandAppBundleCard(a) {
  var prods = Array.isArray(a.products) ? a.products : [];
  var totalQty = prods.reduce(function(s, p){ return s + (Number(p.qty) || 0); }, 0);
  var totalLine = prods.reduce(function(s, p){ return s + (Number(p.qty) || 0) * (Number(p.price) || 0) * BRAND_QUOTE_CONST.FX_JPY_KRW; }, 0);
  var totalFee = prods.reduce(function(s, p){
    var fee = (p.transfer_fee_krw == null || p.transfer_fee_krw === '') ? 0 : Number(p.transfer_fee_krw);
    return s + (Number(p.qty) || 0) * fee;
  }, 0);
  var totalRecruitFee = prods.reduce(function(s, p){
    var rf = (p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? 0 : Number(p.recruit_fee_krw);
    return s + (Number(p.qty) || 0) * rf;
  }, 0);
  var totalFinal = calcBrandAppFinalKrw(a.form_type, totalLine, totalFee, totalRecruitFee);
  var totalVat = Math.floor(totalFinal * (1 + BRAND_QUOTE_CONST.VAT_RATE));

  var statusInfo = BRAND_APP_STATUS[a.status] || {label: a.status || '—', color:'#666', bg:'#EEE'};

  var headerHtml = '<div onclick="toggleBrandAppBundleCard(this)" style="cursor:pointer;background:var(--surface-dim);padding:10px 12px;display:flex;align-items:center;gap:10px;flex-wrap:wrap">'
    + '<span class="material-icons-round notranslate" translate="no" data-bundle-arrow style="font-size:18px;color:var(--muted)">chevron_right</span>'
    + '<span style="font-size:12px;font-weight:700;color:var(--ink);font-variant-numeric:tabular-nums">' + esc(a.application_no || '—') + '</span>'
    + '<span style="background:#F0F0F0;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">' + esc(brandAppFormLabel(a.form_type)) + '</span>'
    + '<span style="background:' + esc(statusInfo.bg) + ';color:' + esc(statusInfo.color) + ';font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">' + esc(statusInfo.label) + '</span>'
    + '<span style="font-size:11px;color:var(--muted);margin-left:auto">' + esc(fmtDate(a.created_at)) + '</span>'
  + '</div>'
  + '<div style="background:#fff;padding:8px 12px;display:flex;align-items:center;gap:14px;flex-wrap:wrap;font-size:11px">'
    + '<span style="color:var(--muted)">제품 <strong style="color:var(--ink)">' + prods.length + '개</strong></span>'
    + '<span style="color:var(--muted)">총 수량 <strong style="color:var(--ink);font-variant-numeric:tabular-nums">' + (totalQty > 0 ? totalQty.toLocaleString('ja-JP') : '—') + '</strong></span>'
    + (totalFinal > 0 ? '<span style="color:var(--muted)">최종 견적 <strong style="color:var(--ink);font-variant-numeric:tabular-nums">' + fmtKrw(totalFinal) + '</strong></span>' : '')
    + (totalVat > 0 ? '<span style="color:var(--muted)">VAT포함 <strong style="color:#16a34a;font-variant-numeric:tabular-nums">' + fmtKrw(totalVat) + '</strong></span>' : '')
    + '<span style="color:var(--muted);margin-left:auto">예상 견적 <strong style="color:var(--ink);font-variant-numeric:tabular-nums">' + fmtKrw(a.estimated_krw) + '</strong></span>'
  + '</div>';

  var dash = '<span style="color:var(--muted)">—</span>';
  var bodyRows = prods.map(function(p){
    var qty = Number(p.qty) || 0;
    var priceJpy = Number(p.price) || 0;
    var priceKrw = priceJpy * BRAND_QUOTE_CONST.FX_JPY_KRW;
    var lineTotal = qty * priceKrw;
    var rfee = (p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? null : Number(p.recruit_fee_krw);
    var tfee = (p.transfer_fee_krw == null || p.transfer_fee_krw === '') ? null : Number(p.transfer_fee_krw);
    var urlSafe = (typeof safeBrandUrl === 'function') ? safeBrandUrl(p.url) : null;
    // 표 안에서 인코딩된 긴 URL 이 10줄 이상으로 늘어지는 회귀 — 두 줄 제한 + 마우스 호버 시 전체 URL 노출 (title 속성).
    var urlClamp = 'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;word-break:break-all';
    var urlCell = p.url
      ? (urlSafe
          ? '<a href="' + esc(urlSafe) + '" target="_blank" rel="noopener" title="' + esc(p.url) + '" style="' + urlClamp + ';color:var(--pink);text-decoration:none">' + esc(p.url) + '</a>'
          : '<span title="' + esc(p.url) + '" style="' + urlClamp + ';color:var(--muted)">' + esc(p.url) + '</span>')
      : dash;
    // 숫자 컬럼들은 nowrap 으로 한 줄 보장 (¥ / ₩ + 쉼표 표기가 두 줄로 잘리지 않게).
    var numCellBase = 'text-align:right;font-variant-numeric:tabular-nums;font-size:11px;padding:6px 8px;white-space:nowrap';
    return '<tr>'
      + '<td style="font-weight:600;font-size:11px;padding:6px 8px;word-break:break-word">' + (p.name ? esc(p.name) : dash)
        + (p.name_ja ? '<div style="font-size:10px;font-weight:400;color:var(--muted);margin-top:2px">' + esc(p.name_ja) + '</div>' : '')
      + '</td>'
      + '<td style="font-size:10px;padding:6px 8px;line-height:1.4">' + urlCell + '</td>'
      + '<td style="' + numCellBase + '">' + (qty > 0 ? qty.toLocaleString('ja-JP') : dash) + '</td>'
      + '<td style="' + numCellBase + '">' + (priceJpy > 0 ? '¥ ' + priceJpy.toLocaleString('ja-JP') : dash) + '</td>'
      + '<td style="' + numCellBase + '">' + (priceKrw > 0 ? fmtKrw(priceKrw) : dash) + '</td>'
      + '<td style="' + numCellBase + '">' + (rfee != null ? fmtKrw(rfee) : dash) + '</td>'
      + '<td style="' + numCellBase + '">' + (tfee != null ? fmtKrw(tfee) : dash) + '</td>'
      + '<td style="' + numCellBase + ';font-weight:600">' + (lineTotal > 0 ? fmtKrw(lineTotal) : dash) + '</td>'
    + '</tr>';
  }).join('');

  // 수량 ~ 소계 컬럼은 숫자 ¥/₩ 표기로 줄바꿈이 생기지 않도록 최소 폭 지정.
  // 모달 폭(1280px) 확대 + 컬럼별 nowrap + colgroup 으로 안정 레이아웃.
  var bodyHtml = '<div data-bundle-body style="display:none;background:#fff;border-top:1px solid var(--line)">'
    + '<table class="data-table" style="width:100%;font-size:11px;margin:0;table-layout:fixed">'
      + '<colgroup>'
        + '<col style="width:18%">'      // 제품명
        + '<col style="width:24%">'      // URL
        + '<col style="width:58px">'     // 수량
        + '<col style="width:90px">'     // 가격(엔)
        + '<col style="width:100px">'    // 가격(원)
        + '<col style="width:90px">'     // 모집비
        + '<col style="width:100px">'    // 이체수수료
        + '<col style="width:110px">'    // 소계
      + '</colgroup>'
      + '<thead><tr style="background:var(--surface-dim)">'
        + '<th style="padding:6px 8px;text-align:left">제품명</th>'
        + '<th style="padding:6px 8px;text-align:left">URL</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">수량</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">가격(엔)</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">가격(원)</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">모집비</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">이체수수료</th>'
        + '<th style="text-align:right;padding:6px 8px;white-space:nowrap">소계</th>'
      + '</tr></thead>'
      + '<tbody>' + (bodyRows || '<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:14px">제품 정보 없음</td></tr>') + '</tbody>'
    + '</table>'
  + '</div>';

  return '<div data-bundle-card="' + esc(a.id) + '" style="border:1px solid var(--line);border-radius:6px;overflow:hidden">'
    + headerHtml
    + bodyHtml
  + '</div>';
}

// 카드 헤더 클릭 시 본문 펼침/접힘 토글
function toggleBrandAppBundleCard(headerEl) {
  var card = headerEl.closest('[data-bundle-card]');
  if (!card) return;
  var body = card.querySelector('[data-bundle-body]');
  var arrow = headerEl.querySelector('[data-bundle-arrow]');
  if (!body) return;
  var isOpen = body.style.display !== 'none';
  body.style.display = isOpen ? 'none' : '';
  if (arrow) arrow.textContent = isOpen ? 'chevron_right' : 'expand_more';
}

// 회사 연결 블록 — 회사 드롭다운 + 신규 회사 등록 버튼 + 읽기전용 회사정보 카드
//   회사 단위 정보(사업자등록번호·청구 이메일)는 「회사 관리」로 일원화.
//   브랜드 폼에서는 회사를 드롭다운으로 연결만 하고, 부가정보는 읽기전용 표시.
function renderBrandCompanyBlock(b) {
  var curId = b.company_id || '';
  var labelStyle = 'color:var(--ink);font-size:12px;font-weight:600;display:block;margin-bottom:5px';
  var canEdit = (typeof canEditCompanies === 'function') ? canEditCompanies() : false;
  var companies = _brandFormCompanies || [];

  var optHtml = '<option value="">(미지정)</option>'
    + companies
        .filter(function(c){ return c.status !== 'archived'; })
        .map(function(c){
          return '<option value="' + esc(c.id) + '"' + (c.id === curId ? ' selected' : '') + '>' + esc(c.name_ko || '(이름없음)') + '</option>';
        }).join('');
  // 현재 연결 회사가 보관(archived) 상태면 별도 옵션으로 노출(선택 유지)
  var curCompany = companies.find(function(c){ return c.id === curId; });
  if (curCompany && curCompany.status === 'archived') {
    optHtml += '<option value="' + esc(curCompany.id) + '" selected>' + esc(curCompany.name_ko || '(이름없음)') + ' (보관됨)</option>';
  }

  var newBtn = canEdit
    ? '<button type="button" class="btn btn-ghost btn-xs" onclick="openCompanyModalForBrand()" style="display:inline-flex;align-items:center;gap:3px;white-space:nowrap"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">add</span> 신규 회사 등록</button>'
    : '';

  return '<div style="margin-bottom:2px">'
    + '<div style="display:flex;align-items:flex-end;gap:8px;margin-bottom:10px">'
      + '<div style="flex:1">'
        + '<label style="' + labelStyle + '">회사 <span style="font-weight:400;color:var(--muted)">(회사 관리 명부에서 선택)</span></label>'
        + '<select id="brandFormCompanyId" class="admin-filter" onchange="onBrandCompanyChange()" style="width:100%;box-sizing:border-box">' + optHtml + '</select>'
      + '</div>'
      + (newBtn ? '<div style="padding-bottom:1px">' + newBtn + '</div>' : '')
    + '</div>'
    + '<div id="brandCompanyInfoCard">' + renderBrandCompanyInfoCardInner(curId) + '</div>'
  + '</div>';
}

// 읽기전용 회사정보 카드 내부 (사업자등록번호·청구 이메일 + 회사 관리 안내)
function renderBrandCompanyInfoCardInner(companyId) {
  if (!companyId) {
    return '<div style="background:var(--surface-dim);border:1px dashed var(--line);border-radius:8px;padding:10px 12px;font-size:12px;color:var(--muted)">회사를 연결하면 사업자등록번호·청구 이메일이 여기에 표시됩니다. 회사 정보는 「회사 관리」에서 수정합니다.</div>';
  }
  var c = (_brandFormCompanies || []).find(function(x){ return x.id === companyId; });
  if (!c) {
    return '<div style="background:var(--surface-dim);border:1px solid var(--line);border-radius:8px;padding:10px 12px;font-size:12px;color:var(--muted)">연결된 회사 정보를 불러올 수 없습니다.</div>';
  }
  var row = function(label, val){
    return '<div style="display:flex;gap:8px;font-size:12px;line-height:1.7">'
      + '<span style="color:var(--muted);min-width:96px">' + esc(label) + '</span>'
      + '<span style="color:var(--ink);font-weight:500">' + (val ? esc(val) : '<span style="color:var(--muted);font-weight:400">미입력</span>') + '</span>'
    + '</div>';
  };
  return '<div style="background:var(--surface-dim);border:1px solid var(--line);border-radius:8px;padding:10px 12px">'
    + row('사업자등록번호', c.business_no)
    + row('청구 이메일', c.billing_email)
    + '<div style="margin-top:6px;font-size:11px;color:var(--muted)">이 정보는 「회사 관리」에서 수정합니다.</div>'
  + '</div>';
}

function onBrandCompanyChange() {
  var sel = $('brandFormCompanyId');
  var id = sel ? sel.value : '';
  var card = $('brandCompanyInfoCard');
  if (card) card.innerHTML = renderBrandCompanyInfoCardInner(id);
}

// 브랜드 폼 회사 드롭다운 옵션 재생성 (신규 회사 등록 후 호출)
function _rebuildBrandCompanySelect(selectedId) {
  var sel = $('brandFormCompanyId');
  if (!sel) return;
  sel.innerHTML = '<option value="">(미지정)</option>'
    + (_brandFormCompanies || [])
        .filter(function(c){ return c.status !== 'archived'; })
        .map(function(c){ return '<option value="' + esc(c.id) + '"' + (c.id === selectedId ? ' selected' : '') + '>' + esc(c.name_ko || '(이름없음)') + '</option>'; })
        .join('');
  sel.value = selectedId || '';
}

// 브랜드 폼에서 신규 회사 인라인 등록 — 회사 모달을 브랜드 상세 위에 띄움
function openCompanyModalForBrand() {
  if (typeof openCompanyModal !== 'function') return;
  openCompanyModal(null, { onSaved: function(company){
    if (!company || !company.id) return;
    if (!(_brandFormCompanies || []).some(function(c){ return c.id === company.id; })) {
      _brandFormCompanies.push(company);
    }
    _rebuildBrandCompanySelect(company.id);
    onBrandCompanyChange();
  }});
}

function renderBrandDetailFormHtml(b, apps) {
  // contacts 초기화
  _brandFormContacts = Array.isArray(b.contacts) ? b.contacts.map(function(c){
    return {
      id: c.id || _genContactId(),
      name: c.name || '',
      phone: c.phone || '',
      email: c.email || '',
      is_primary: !!c.is_primary
    };
  }) : [];
  if (_brandFormContacts.length === 0 && (b.primary_contact_name || b.primary_phone || b.primary_email)) {
    _brandFormContacts.push({
      id: _genContactId(),
      name: b.primary_contact_name || '',
      phone: b.primary_phone || '',
      email: b.primary_email || '',
      is_primary: true
    });
  }

  // 공통 헬퍼 — 신청 등록 모달과 동일한 섹션 패턴(border-bottom:2px solid pink)
  var section = function(title, rightHtml, contentHtml) {
    return '<section style="margin-bottom:18px">'
      + '<div style="display:flex;align-items:center;justify-content:space-between;padding-bottom:6px;margin-bottom:12px;border-bottom:2px solid var(--pink)">'
        + '<span style="font-size:13px;font-weight:700;color:var(--ink)">' + esc(title) + '</span>'
        + (rightHtml || '')
      + '</div>'
      + contentHtml
    + '</section>';
  };
  var labelStyle = 'color:var(--ink);font-size:12px;font-weight:600;display:block;margin-bottom:5px';
  var input = function(id, label, val, placeholder) {
    return '<div><label style="' + labelStyle + '">' + esc(label) + '</label><input type="text" id="' + id + '" class="admin-filter" autocomplete="off" data-lpignore="true" value="' + esc(val || '') + '" placeholder="' + esc(placeholder || '') + '" style="width:100%;box-sizing:border-box"></div>';
  };
  var ta = function(id, label, val, placeholder, rows) {
    return '<div><label style="' + labelStyle + '">' + esc(label) + '</label><textarea id="' + id + '" class="admin-filter" rows="' + (rows || 3) + '" style="resize:vertical;font-family:inherit;width:100%" placeholder="' + esc(placeholder || '') + '">' + esc(val || '') + '</textarea></div>';
  };

  // 신청 내역 — 신청별 펼침 카드 (헤더에 합산, 펼치면 제품 N행 표)
  var appsHtml = renderBrandAppsBundledView(apps);

  return ''
    // § 기본 정보 — 회사 연결(드롭다운+읽기전용 카드) / 브랜드명 3열
    + section('기본 정보', '',
        renderBrandCompanyBlock(b)
        + '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;margin-top:12px">'
          + input('brandFormName', '브랜드명 (한국어) *', b.name)
          + input('brandFormNameJa', '브랜드명 (일본어)', b.name_ja)
          + input('brandFormNameEn', '브랜드명 (영문)', b.name_en)
        + '</div>'
      )
    // § 담당자
    + section('담당자', '<button type="button" class="btn btn-ghost btn-xs" onclick="addBrandContact()" style="display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">add</span> 담당자 추가</button>',
        '<div id="brandContactsHeader" style="display:grid;grid-template-columns:1.3fr 1.3fr 2fr 110px 32px;gap:8px;margin-bottom:6px;padding:0 4px">'
          + '<div style="' + labelStyle + ';margin:0">담당자명</div>'
          + '<div style="' + labelStyle + ';margin:0">연락처</div>'
          + '<div style="' + labelStyle + ';margin:0">메일주소</div>'
          + '<div style="' + labelStyle + ';margin:0;text-align:center">대표</div>'
          + '<div></div>'
        + '</div>'
        + '<div id="brandContactsWrap"></div>'
      )
    // § 브랜드 콘텐츠
    + section('브랜드 콘텐츠 (오리엔시트용)', '',
        '<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px">'
          + ta('brandFormDescription', '브랜드 소개', b.description, '브랜드 한줄 소개·수상 이력 등', 3)
          + ta('brandFormAppealPoints', '어필 포인트', b.appeal_points, '제품·시장에서의 강점', 3)
        + '</div>'
        + '<div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px">'
          + input('brandFormQoo10Url', '공식 Qoo10 URL', b.official_qoo10_url, 'https://www.qoo10.jp/...')
          + input('brandFormInstagramUrl', '공식 Instagram URL', b.official_instagram_url, 'https://www.instagram.com/...')
          + input('brandFormXUrl', '공식 X URL', b.official_x_url, 'https://x.com/...')
        + '</div>'
      )
    // § 영업 메모
    + section('영업 메모', '',
        '<textarea id="brandFormMemo" class="admin-filter" rows="3" style="resize:vertical;font-family:inherit;width:100%" placeholder="브랜드 단위 영업 메모">' + esc(b.memo || '') + '</textarea>'
      )
    // § 신청 내역
    + section('이 브랜드의 신청 내역 (' + (apps ? apps.length : 0) + '건)', '', appsHtml);
}

// 담당자 행 렌더링 (헤더와 동일한 grid: 이름/연락처/메일/대표/삭제)
function renderBrandContactsRows() {
  var wrap = $('brandContactsWrap');
  if (!wrap) return;
  if (_brandFormContacts.length === 0) {
    wrap.innerHTML = '<div style="padding:14px;text-align:center;color:var(--muted);font-size:12px;border:1px dashed var(--line);border-radius:6px">담당자가 없습니다. "담당자 추가" 버튼을 눌러 등록하세요.</div>';
    return;
  }
  wrap.innerHTML = _brandFormContacts.map(function(c){
    var isPrimary = !!c.is_primary;
    // 라디오 형태의 별 토글 — 클릭 가능 명확
    var primaryBtn = '<button type="button" onclick="setBrandPrimaryContact(\'' + esc(c.id) + '\')" title="' + (isPrimary ? '대표 담당자' : '대표로 설정') + '" style="background:' + (isPrimary ? '#FFF8E1' : '#fff') + ';color:' + (isPrimary ? '#F57F17' : 'var(--muted)') + ';border:1px solid ' + (isPrimary ? '#FFE082' : 'var(--line)') + ';border-radius:6px;padding:6px;cursor:pointer;display:inline-flex;align-items:center;justify-content:center;width:100%;height:34px"><span class="material-icons-round notranslate" translate="no" style="font-size:18px">' + (isPrimary ? 'star' : 'star_outline') + '</span></button>';
    var delBtn = '<button type="button" onclick="removeBrandContact(\'' + esc(c.id) + '\')" title="삭제" style="background:#fff;border:1px solid var(--line);border-radius:6px;padding:6px;cursor:pointer;color:#c0392b;display:inline-flex;align-items:center;justify-content:center;width:32px;height:34px"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">delete_outline</span></button>';
    return '<div class="brand-contact-row" data-cid="' + esc(c.id) + '" style="display:grid;grid-template-columns:1.3fr 1.3fr 2fr 110px 32px;gap:8px;align-items:center;margin-bottom:6px">'
      + '<input type="text" class="admin-filter" autocomplete="off" data-lpignore="true" value="' + esc(c.name) + '" placeholder="담당자명" oninput="updateBrandContactField(\'' + esc(c.id) + '\',\'name\',this.value)">'
      + '<input type="text" class="admin-filter" autocomplete="off" data-lpignore="true" value="' + esc(c.phone) + '" placeholder="010-0000-0000" oninput="updateBrandContactField(\'' + esc(c.id) + '\',\'phone\',this.value)">'
      + '<input type="text" class="admin-filter" autocomplete="off" data-lpignore="true" value="' + esc(c.email) + '" placeholder="example@brand.com" oninput="updateBrandContactField(\'' + esc(c.id) + '\',\'email\',this.value)">'
      + primaryBtn
      + delBtn
    + '</div>';
  }).join('');
}

function addBrandContact() {
  _brandFormContacts.push({id: _genContactId(), name: '', phone: '', email: '', is_primary: _brandFormContacts.length === 0});
  renderBrandContactsRows();
}

function removeBrandContact(cid) {
  var wasPrimary = _brandFormContacts.find(function(c){ return c.id === cid; })?.is_primary;
  _brandFormContacts = _brandFormContacts.filter(function(c){ return c.id !== cid; });
  // 대표를 지웠으면 첫 번째를 대표로
  if (wasPrimary && _brandFormContacts.length > 0 && !_brandFormContacts.some(function(c){return c.is_primary;})) {
    _brandFormContacts[0].is_primary = true;
  }
  renderBrandContactsRows();
}

function setBrandPrimaryContact(cid) {
  _brandFormContacts.forEach(function(c){ c.is_primary = (c.id === cid); });
  renderBrandContactsRows();
}

function updateBrandContactField(cid, field, value) {
  var c = _brandFormContacts.find(function(x){ return x.id === cid; });
  if (!c) return;
  c[field] = value;
}

function _collectBrandFormPatch() {
  // contacts 정리 — 빈 행(이름/연락처/이메일 모두 빈 값) 제외
  var contacts = (_brandFormContacts || [])
    .map(function(c){
      return {
        id: c.id, name: (c.name || '').trim(), phone: (c.phone || '').trim(),
        email: (c.email || '').trim(), is_primary: !!c.is_primary
      };
    })
    .filter(function(c){ return c.name || c.phone || c.email; });
  // 대표 1개 보장 (없으면 첫 번째)
  if (contacts.length > 0 && !contacts.some(function(c){return c.is_primary;})) {
    contacts[0].is_primary = true;
  }
  // legacy primary_* 컬럼 동기화 (대표 contact)
  var primary = contacts.find(function(c){return c.is_primary;}) || {};
  // 회사 연결: 드롭다운 선택값(company_id) + 표시용 company_name 동기화.
  //   사업자등록번호·청구 이메일은 「회사 관리」로 일원화 → 브랜드 폼에서 입력 안 함.
  //   company_name 은 기존 표시처(목록·신청) 호환을 위해 선택 회사명으로 동기화(미지정이면 null).
  var _selCompanyId = ($('brandFormCompanyId')?.value || '').trim() || null;
  var _selCompany = _selCompanyId ? (_brandFormCompanies || []).find(function(c){ return c.id === _selCompanyId; }) : null;
  return {
    name: ($('brandFormName')?.value || '').trim(),
    name_ja: ($('brandFormNameJa')?.value || '').trim() || null,
    name_en: ($('brandFormNameEn')?.value || '').trim() || null,
    company_id: _selCompanyId,
    company_name: _selCompany ? (_selCompany.name_ko || null) : null,
    status: $('brandFormStatus')?.value || 'active',
    contacts: contacts,
    // legacy 컬럼도 동기화 (PR6 cleanup 전까지 양쪽 유지)
    primary_contact_name: primary.name || null,
    primary_phone: primary.phone || null,
    primary_email: primary.email || null,
    description: ($('brandFormDescription')?.value || '').trim() || null,
    appeal_points: ($('brandFormAppealPoints')?.value || '').trim() || null,
    official_qoo10_url: ($('brandFormQoo10Url')?.value || '').trim() || null,
    official_instagram_url: ($('brandFormInstagramUrl')?.value || '').trim() || null,
    official_x_url: ($('brandFormXUrl')?.value || '').trim() || null,
    memo: ($('brandFormMemo')?.value || '').trim() || null
  };
}

async function saveBrandDetail() {
  if (!_brandsCurrentId) return;
  var patch = _collectBrandFormPatch();
  if (!patch.name) { toast('브랜드명을 입력하세요.', 'warn'); return; }
  var result = await updateBrand(_brandsCurrentId, patch);
  if (!result.ok) {
    var em = result.error || '';
    if (em.indexOf('duplicate') >= 0 || em.indexOf('unique') >= 0 || em.indexOf('name_normalized') >= 0) {
      toast('이미 같은 이름의 브랜드가 등록돼 있습니다. (띄어쓰기·대소문자는 같은 것으로 봅니다)', 'error');
    } else {
      toast('저장 실패: ' + (em || '알 수 없는 오류'), 'error');
    }
    return;
  }
  toast('저장되었습니다.');
  closeBrandDetailModal();
  await refreshPane('brands');
}

// 캠페인 폼에서 호출 시 callbackPrefix='new'|'edit' 전달 → 등록 후 해당 select 자동 갱신·선택
var _newBrandCallbackPrefix = null;

async function openNewBrandModal(callbackPrefix) {
  _newBrandCallbackPrefix = (callbackPrefix === 'new' || callbackPrefix === 'edit') ? callbackPrefix : null;
  // 빈 brand 객체로 모달 열기
  _brandsCurrentId = null;
  var modal = $('brandDetailModal');
  var titleEl = $('brandDetailTitle');
  var bodyEl = $('brandDetailBody');
  var footerEl = $('brandDetailFooter');
  if (!modal || !bodyEl) return;
  // 회사 드롭다운용 회사 목록 로드 (archived 포함 — 보관 회사 연결 유지)
  _brandFormCompanies = (typeof fetchCompanies === 'function') ? (await fetchCompanies({ status: 'all' }) || []) : [];
  if (titleEl) titleEl.innerHTML = renderBrandDetailHeaderHtml({status: 'active', name: '새 브랜드'});
  bodyEl.innerHTML = renderBrandDetailFormHtml({}, []);
  renderBrandContactsRows();
  if (footerEl) footerEl.innerHTML = '<button class="btn btn-ghost btn-sm" onclick="closeBrandDetailModal()">취소</button>'
    + '<button class="btn btn-primary btn-sm" onclick="submitNewBrand()">등록</button>';
  modal.classList.add('open');
  setTimeout(function(){ $('brandFormName')?.focus(); }, 100);
}

async function submitNewBrand() {
  var patch = _collectBrandFormPatch();
  if (!patch.name) { toast('브랜드명을 입력하세요.', 'warn'); return; }
  patch.created_by = currentUser?.id || null;
  var result = await insertBrand(patch);
  if (!result.ok) {
    var em = result.error || '';
    if (em.indexOf('duplicate') >= 0 || em.indexOf('unique') >= 0 || em.indexOf('name_normalized') >= 0) {
      toast('이미 같은 이름의 브랜드가 등록돼 있습니다. (띄어쓰기·대소문자는 같은 것으로 봅니다)', 'error');
    } else {
      toast('등록 실패: ' + (em || '알 수 없는 오류'), 'error');
    }
    return;
  }
  toast('브랜드가 등록되었습니다.');
  closeBrandDetailModal();
  // 캠페인 폼에서 호출됐으면 해당 폼의 brand select 갱신 + 신규 brand 자동 선택
  if (_newBrandCallbackPrefix && result.data?.id) {
    var prefix = _newBrandCallbackPrefix;
    _newBrandCallbackPrefix = null;
    _campBrandsCache = null;  // 신규 brand 포함하기 위해 캐시 무효화
    await loadCampBrandSelect(prefix, result.data.id);
    await onCampBrandChange(prefix);
  } else {
    await refreshPane('brands');
  }
}

// [perf 2026-05-15] 동시 진행 중 중복 호출 차단 — 페인 진입 시 fetch 가 2번 발생하는 회귀 방어.
// 같은 시점 호출은 같은 promise 반환. 완료 후엔 새 호출 가능 (정상 동작 유지).
// 원인 추적: docs/specs/2026-05-15-admin-perf-diagnosis.md §6-2 참조.
var _loadBrandApplicationsPromise = null;

async function loadBrandApplications() {
  // 이미 진행 중이면 같은 promise 반환 (중복 fetch 차단)
  if (_loadBrandApplicationsPromise) return _loadBrandApplicationsPromise;
  _loadBrandApplicationsPromise = (async function() { try {
  var tbody = $('brandAppTableBody');
  if (tbody) tbody.innerHTML = '<tr><td colspan="30" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';

  try {
    // URL 해시 쿼리에서 status 파라미터 파싱
    //   화이트리스트 통과: 해당 탭 활성
    //   미통과(옛 status 값이 hash에 남은 사용자): _brandAppActiveStatusTab=null + #brand-applications로 강제 정리
    var hashStatus = parseHashQuery('status');
    if (hashStatus) {
      if (BRAND_APP_STATUS_TABS.some(function(t){ return t.code === hashStatus; })) {
        _brandAppActiveStatusTab = hashStatus;
      } else {
        _brandAppActiveStatusTab = null;
        try { history.replaceState(null, '', '#brand-applications'); } catch (_e) {}
      }
    }

    // 신청 본문 + history 카운트 + 메모 요약 동시 fetch
    var [apps, counts, memoSummaries, orientSheets] = await Promise.all([
      fetchBrandApplications(),
      fetchBrandAppHistoryCounts(),
      fetchBrandAppMemoSummaries(),
      fetchOrientSheets().catch(function(){ return []; })   // 셀프 오리엔시트 열(실패해도 목록은 표시)
    ]);
    _brandApps = apps || [];
    _brandAppHistoryCounts = counts || {};
    _brandAppMemoSummaries = memoSummaries || {};
    // 셀프 오리엔시트 열: 신청별 그룹 맵(N+1 회피 — 전체 1회 조회 후 application_id 로 그룹)
    _orientByApp = {};
    (orientSheets || []).forEach(function(s){
      if (!s.application_id) return;
      (_orientByApp[s.application_id] = _orientByApp[s.application_id] || []).push(s);
    });
    renderBrandApplicationsList();
    refreshBrandAppBadge();
  } catch (err) {
    console.error('[brand-applications] load failed:', err);
    if (tbody) {
      tbody.innerHTML = '<tr><td colspan="30" style="text-align:center;color:#c33;padding:24px">'
        + '신청 목록을 불러오지 못했습니다. 새로고침 또는 재로그인 후 다시 시도해 주세요.'
        + '<br><button type="button" onclick="location.reload()" class="btn btn-primary" style="margin-top:8px">새로고침</button>'
        + '</td></tr>';
    }
    // 탭 바는 카운트 0으로 안전 렌더 (탭 자체는 노출 유지)
    try { renderBrandAppStatusTabs({}); } catch (_e) {}
  }
  } finally { _loadBrandApplicationsPromise = null; }})();
  return _loadBrandApplicationsPromise;
}

async function refreshBrandAppBadge() {
  var el = $('adminBrandAppSi');
  if (!el) return;
  var count = await fetchBrandAppPendingCount();
  var badge = count > 0 ? '<span class="admin-si-badge">'+(count > 999 ? '999+' : count)+'</span>' : '';
  el.innerHTML = '<span class="si-icon material-icons-round notranslate" translate="no">storefront</span><span class="si-text">광고주 신청</span>' + badge;
}

var brandAppLazy = null;
var BRAND_APP_PAGE_SIZE = 50;

// 현재 UI 필터/정렬 기준으로 브랜드 서베이 리스트를 추출 (렌더·엑셀 export 공용)
// 상태 필터: 탭 변수(_brandAppActiveStatusTab)를 사용하며 폼타입·기간·검색과 AND 결합
function getFilteredBrandApps() {
  var formVals = getMultiFilterValues('brandAppFormMulti');
  var from = ($('brandAppFromDate')?.value) || '';
  var to = ($('brandAppToDate')?.value) || '';
  var q = ((($('brandAppSearch')?.value) || '').trim().toLowerCase());

  var list = (_brandApps || []).slice();
  if (formVals.length > 0) list = list.filter(function(a){ return formVals.indexOf(a.form_type) >= 0; });
  // 상태 탭 필터 — null이면 전체, 값이 있으면 해당 상태인 신청만 통과
  if (_brandAppActiveStatusTab) {
    var tabStatus = _brandAppActiveStatusTab;
    list = list.filter(function(a) {
      var prods = Array.isArray(a.products) ? a.products : [];
      if (prods.length === 0) return a.status === tabStatus;
      return prods.some(function(p) {
        return ((p && p.status) || a.status) === tabStatus;
      });
    });
  }
  if (from) list = list.filter(function(a){ return (a.created_at || '') >= from; });
  if (to) list = list.filter(a => (a.created_at || '') <= to + 'T23:59:59');
  if (q) list = list.filter(a =>
    (a.brand?.name || a.brand_name || '').toLowerCase().includes(q) ||
    (a.brand?.brand_no || '').toLowerCase().includes(q) ||
    (a.applicant_contact_name || a.contact_name || '').toLowerCase().includes(q) ||
    (a.applicant_email || a.email || '').toLowerCase().includes(q) ||
    (a.application_no || '').toLowerCase().includes(q) ||
    (a.request_note || '').toLowerCase().includes(q)
  );

  list.sort(function(a, b) {
    var av, bv;
    if (_brandAppSort.field === 'estimated') {
      av = Number(a.estimated_krw || 0); bv = Number(b.estimated_krw || 0);
    } else if (_brandAppSort.field === 'status') {
      var BRAND_APP_STATUS_ORDER = {new:0, reviewing:1, quoted:2, paid:3, kakao_room_created:4, orient_sheet_sent:5, schedule_sent:6, campaign_registered:7, done:8, rejected:9};
      av = BRAND_APP_STATUS_ORDER[a.status] ?? 99;
      bv = BRAND_APP_STATUS_ORDER[b.status] ?? 99;
    } else if (_brandAppSort.field === 'brand') {
      av = (a.brand_name || '').toLowerCase();
      bv = (b.brand_name || '').toLowerCase();
    } else if (_brandAppSort.field === 'quoteSent') {
      // NULL은 항상 가장 뒤(asc/desc 무관)
      var ax = a.quote_sent_at || ''; var bx = b.quote_sent_at || '';
      if (!ax && !bx) return 0;
      if (!ax) return 1;
      if (!bx) return -1;
      av = ax; bv = bx;
    } else if (_brandAppSort.field === 'reviewed') {
      var ay = a.reviewed_at || ''; var by = b.reviewed_at || '';
      if (!ay && !by) return 0;
      if (!ay) return 1;
      if (!by) return -1;
      av = ay; bv = by;
    } else {
      av = a.created_at || ''; bv = b.created_at || '';
    }
    if (av < bv) return _brandAppSort.dir === 'asc' ? -1 : 1;
    if (av > bv) return _brandAppSort.dir === 'asc' ? 1 : -1;
    return 0;
  });

  var filterActive = !!(formVals.length > 0 || _brandAppActiveStatusTab || from || to || q);
  return { list: list, filterActive: filterActive };
}

function renderBrandApplicationsList() {
  var tbody = $('brandAppTableBody');
  if (!tbody) return;

  // 폼 종류 다중 선택 드롭다운 옵션 갱신 (신청 단위 카운트)
  var formCounts = {reviewer:0, seeding:0};
  (_brandApps || []).forEach(function(a) {
    if (a.form_type) formCounts[a.form_type] = (formCounts[a.form_type] || 0) + 1;
  });
  syncMultiFilter('brandAppFormMulti', '전체 폼', [
    {value:'reviewer', label:'리뷰어', count: formCounts.reviewer || 0},
    {value:'seeding',  label:'나노 시딩',   count: formCounts.seeding  || 0},
  ], renderBrandApplicationsList);

  // 탭 건수: 폼타입·기간·검색 필터만 적용한 모집단에서 상태별 카운트 계산
  // (탭 자체는 상태 필터 제외하고 계산해야 전체 분포 보임)
  var tabBase = (_brandApps || []).slice();
  var formValsForTab = getMultiFilterValues('brandAppFormMulti');
  var fromForTab = ($('brandAppFromDate')?.value) || '';
  var toForTab   = ($('brandAppToDate')?.value) || '';
  var qForTab    = ((($('brandAppSearch')?.value) || '').trim().toLowerCase());
  if (formValsForTab.length > 0) tabBase = tabBase.filter(function(a){ return formValsForTab.indexOf(a.form_type) >= 0; });
  if (fromForTab) tabBase = tabBase.filter(function(a){ return (a.created_at || '') >= fromForTab; });
  if (toForTab)   tabBase = tabBase.filter(function(a){ return (a.created_at || '') <= toForTab + 'T23:59:59'; });
  if (qForTab)    tabBase = tabBase.filter(function(a){
    return (a.brand?.name || a.brand_name || '').toLowerCase().includes(qForTab) ||
           (a.brand?.brand_no || '').toLowerCase().includes(qForTab) ||
           (a.applicant_contact_name || a.contact_name || '').toLowerCase().includes(qForTab) ||
           (a.applicant_email || a.email || '').toLowerCase().includes(qForTab) ||
           (a.application_no || '').toLowerCase().includes(qForTab) ||
           (a.request_note || '').toLowerCase().includes(qForTab);
  });
  // 상태별 건수는 화면 리스트 행 수 단위로 카운트 (제품 단위 — _flattenAppsToProducts).
  //   상태 드롭다운이 제품 단위 변경(quickChangeBrandAppProductStatus)이라 같은 단위여야
  //   변경 즉시 탭 카운트가 갱신됨. 카드 헤더 카운트와도 단위 통일 (행 수).
  var tabStatusCounts = {};
  _flattenAppsToProducts(tabBase).forEach(function(f) {
    if (f.status) tabStatusCounts[f.status] = (tabStatusCounts[f.status] || 0) + 1;
  });
  renderBrandAppStatusTabs(tabStatusCounts);

  var res = getFilteredBrandApps();
  var list = res.list;
  var filterActive = res.filterActive;
  // 보기 초기화 — 필터·검색·정렬 중 하나라도 비기본이면 표시
  var viewResetBtn = $('btnBrandAppViewReset');
  if (viewResetBtn) viewResetBtn.style.display = (filterActive || !_brandAppSortIsDefault()) ? 'inline-block' : 'none';

  var count = $('brandAppTotalCount');
  if (count) {
    // 화면 리스트 행 수 기준 (제품 단위) — 탭 옆 카운트와 단위 통일.
    //   탭 활성 시 매칭 status 제품만 행으로 노출되므로 그 필터까지 적용한 행 수로 계산.
    //   리뷰어/시딩 분포도 행 단위 (각 행이 속한 신청의 form_type).
    var flatRows = _flattenAppsToProducts(list);
    if (_brandAppActiveStatusTab) {
      flatRows = flatRows.filter(function(f) {
        return ((f.product && f.product.status) || f.app.status) === _brandAppActiveStatusTab;
      });
    }
    var totalRows = flatRows.length;
    var resultReviewer = flatRows.filter(function(f){ return f.app && f.app.form_type === 'reviewer'; }).length;
    var resultSeeding  = flatRows.filter(function(f){ return f.app && f.app.form_type === 'seeding';  }).length;
    var leadLabel = filterActive ? '신청 결과 ' : '전체 ';
    count.textContent = '(' + leadLabel + totalRows + '건 · 리뷰어 ' + resultReviewer + ' · 시딩 ' + resultSeeding + ')';
  }

  // 상태 탭이 켜진 경우 매칭 제품 행만 노출 (행 단위 필터)
  // 「제품 N개」 라벨은 원본 전체 개수, idx는 원본 인덱스 유지(cur.products[idx] 매핑 정확성)
  // 신청 단위 좌측 색 띠 stripe map — 같은 신청의 모든 행에 동일 색.
  //   list 정렬·필터 적용 후 인접 신청끼리 색이 교대(짝/홀) 되도록 인덱스 부여.
  var stripeMap = {};
  list.forEach(function(a, i) {
    stripeMap[a.id] = (i % 2 === 0) ? 'app-stripe-even' : 'app-stripe-odd';
  });
  var renderBrandAppRow = function(a) {
    var allProds = Array.isArray(a.products) ? a.products : [];
    var totalCount = allProds.length;
    var pairs = allProds.map(function(p, originalIdx) { return {p: p, idx: originalIdx}; });
    if (_brandAppActiveStatusTab) {
      var ts = _brandAppActiveStatusTab;
      pairs = pairs.filter(function(pair) {
        return ((pair.p && pair.p.status) || a.status) === ts;
      });
      if (pairs.length === 0) return ''; // 매칭 제품 없으면 신청 자체 미노출
    }
    var stripeCls = stripeMap[a.id] || '';
    if (pairs.length === 0) {
      return renderBrandAppFlatRow(a, {}, 0, 0, true, stripeCls);
    }
    return pairs.map(function(pair, displayIdx) {
      return renderBrandAppFlatRow(a, pair.p, pair.idx, totalCount, displayIdx === 0, stripeCls);
    }).join('');
  };
  if (brandAppLazy) brandAppLazy.destroy();
  brandAppLazy = mountLazyList({
    tbody: tbody,
    scrollRoot: tbody.closest('.admin-table-wrap'),
    rows: list,
    renderRow: renderBrandAppRow,
    pageSize: BRAND_APP_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="30" style="text-align:center;color:var(--muted);padding:40px">신청 내역이 없습니다</td></tr>',
  });
}

// 보기 초기화 — 필터·검색·정렬을 한 번에 기본값으로
function resetBrandAppView() {
  resetMultiFilter('brandAppFormMulti', '전체 폼');
  // 상태 탭 초기화 (전체 탭으로)
  _brandAppActiveStatusTab = null;
  syncBrandAppStatusTabHash();
  if ($('brandAppFromDate')) $('brandAppFromDate').value = '';
  if ($('brandAppToDate')) $('brandAppToDate').value = '';
  if ($('brandAppSearch')) $('brandAppSearch').value = '';
  if (window._brandAppDateFp) {
    window._brandAppDateFp.clear();
  } else if ($('brandAppDateRange')) {
    $('brandAppDateRange').value = '';
  }
  ['brandAppFromDate','brandAppToDate','brandAppDateRange'].forEach(function(id){
    var el = $(id); if (el) el.classList.remove('filter-active');
  });
  _brandAppSort = {field: 'created', dir: 'desc'};
  updateBrandAppSortIndicators();
  renderBrandApplicationsList();
}

// 브랜드 서베이 신청 기간 range picker mount (캠페인 폼과 동일한 flatpickr 패턴)
function setupBrandAppDateRange() {
  if (typeof flatpickr === 'undefined') return;
  var el = document.getElementById('brandAppDateRange');
  if (!el || window._brandAppDateFp) return;
  var fromHidden = document.getElementById('brandAppFromDate');
  var toHidden = document.getElementById('brandAppToDate');
  var displayEl = el;
  window._brandAppDateFp = flatpickr(el, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    showMonths: 2,
    onChange: function(selectedDates) {
      var from = selectedDates[0] ? selectedDates[0].toISOString().slice(0,10) : '';
      var to = selectedDates[1] ? selectedDates[1].toISOString().slice(0,10) : '';
      if (fromHidden) fromHidden.value = from;
      if (toHidden) toHidden.value = to;
      if (displayEl) {
        displayEl.classList.toggle('filter-active', !!(from || to));
      }
      // 종료일까지 선택됐을 때만 필터 즉시 반영(시작일만 있으면 사용자가 종료 클릭 중)
      if (selectedDates.length === 0 || selectedDates.length === 2) {
        renderBrandApplicationsList();
      }
    }
  });
}

function toggleBrandAppSort(field) {
  if (_brandAppSort.field === field) {
    _brandAppSort.dir = _brandAppSort.dir === 'asc' ? 'desc' : 'asc';
  } else {
    _brandAppSort = {field: field, dir: 'desc'};
  }
  updateBrandAppSortIndicators();
  renderBrandApplicationsList();
}

function _brandAppSortIsDefault() {
  return _brandAppSort.field === 'created' && _brandAppSort.dir === 'desc';
}

// 정렬 화살표 활성 상태 시각화 (▲ asc / ▼ desc / ▲▼ inactive)
function updateBrandAppSortIndicators() {
  document.querySelectorAll('#adminPane-brand-applications .sort-arrows').forEach(function(el) {
    var field = el.getAttribute('data-sort');
    if (field === _brandAppSort.field) {
      el.textContent = _brandAppSort.dir === 'asc' ? '▲' : '▼';
      el.style.color = 'var(--pink)';
    } else {
      el.textContent = '▲▼';
      el.style.color = '';
    }
  });
}


function _findBrandApp(id) {
  var idx = (_brandApps || []).findIndex(function(a){ return a.id === id; });
  return idx < 0 ? null : _brandApps[idx];
}

// 환율·VAT 상수 (FX_JPY_KRW=10, VAT_RATE=10% — migration 052 트리거와 일치)
var BRAND_QUOTE_CONST = { FX_JPY_KRW: 10, VAT_RATE: 0.1 };

// 최종 견적 금액(화면·엑셀 공용 계산):
//   reviewer: 상품 최종 금액(lineTotal) + 모집비(recruitFeeTotal) + 이체수수료(feeTotal)
//   seeding : 모집비(recruitFeeTotal) + 이체수수료(feeTotal)만 합산 — 상품 가격은 참고용
//   그 외(미정) : reviewer와 동일하게 합산 (안전 폴백)
//   모집비는 관리자 수동 입력 단가(products[i].recruit_fee_krw). 미입력은 0으로 처리.
function calcBrandAppFinalKrw(formType, lineTotal, feeTotal, recruitFeeTotal) {
  var fee = Number(feeTotal) || 0;
  var rfee = Number(recruitFeeTotal) || 0;
  if (formType === 'seeding') return fee + rfee;
  return (Number(lineTotal) || 0) + fee + rfee;
}

// 제품 URL 셀 — 안전 URL이면 클릭 링크 + 복사 버튼, 아니면 평문 표시
function renderProductUrlCell(url) {
  if (!url) return '<span style="color:var(--muted);font-size:11px">—</span>';
  var safe = (typeof safeBrandUrl === 'function') ? safeBrandUrl(url) : null;
  if (!safe) {
    return '<span style="color:var(--muted);word-break:break-all;font-size:11px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;line-height:1.4">' + esc(url) + '</span>';
  }
  var jsSafe = safe.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  return '<div style="display:flex;align-items:flex-start;gap:4px;min-width:0">'
    + '<a href="' + esc(safe) + '" target="_blank" rel="noopener" title="' + esc(url) + '"'
      + ' style="flex:1;min-width:0;color:var(--pink);word-break:break-all;font-size:11px;'
      + 'display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;line-height:1.4;max-height:2.8em">'
      + esc(url) + '</a>'
    + '<button type="button" class="btn btn-ghost btn-xs" onclick="copyBrandProductUrl(\'' + jsSafe + '\')" '
      + 'title="URL 복사" style="padding:2px 6px;flex-shrink:0">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:middle">content_copy</span>'
    + '</button>'
  + '</div>';
}

// 신청별 이력 캐시 (id → array) — 모달 재오픈 시 fresh load이지만 cache로 보존
var _brandAppHistoryCache = new Map();

var BRAND_APP_HISTORY_FIELD_LABELS = {
  status: '상태',
  admin_memo: '내부 메모',
  quote_sent_at: '견적서 전달일',
  quote_sent_url: '견적서 URL',
  orient_sheet_sent_at: '오리엔시트 전달일',
  orient_sheet_sent_url: '오리엔시트 URL',
  paid_at: '입금 날짜',
  final_quote_krw: '확정 견적',
  products: '제품 정보',
  memo_added: '메모 추가',
  memo_edited: '메모 수정',
  memo_deleted: '메모 삭제'
};
function _brandAppHistoryFieldLabel(f) { return BRAND_APP_HISTORY_FIELD_LABELS[f] || f; }
function _brandAppHistoryFormatValue(field, val) {
  if (val == null) return '<span style="color:var(--muted)">—</span>';
  if (field === 'status') {
    var lbl = (BRAND_APP_STATUS[val]?.label) || val;
    return esc(String(lbl));
  }
  if (field === 'admin_memo') {
    var s = String(val);
    if (s.length > 60) s = s.slice(0, 60) + '…';
    return esc(s);
  }
  if (field === 'quote_sent_at') {
    return esc(fmtDate(val));
  }
  if (field === 'final_quote_krw') {
    return esc(fmtKrw(val));
  }
  if (field === 'products') {
    var prods = Array.isArray(val) ? val : [];
    var totalQty = prods.reduce(function(s, p){ return s + (Number(p.qty) || 0); }, 0);
    return esc(prods.length + '종 · ' + totalQty + '개');
  }
  // 메모 추가/수정/삭제 (val은 jsonb 객체 또는 문자열)
  if (field === 'memo_added' || field === 'memo_edited' || field === 'memo_deleted') {
    var memoText = '';
    if (typeof val === 'object' && val !== null) {
      memoText = val.text || '';
    } else {
      memoText = String(val);
    }
    if (memoText.length > 80) memoText = memoText.slice(0, 80) + '…';
    return esc(memoText);
  }
  return esc(String(val));
}

// 모든 제품에서 동일한 값이면 그 값, 다르면 null
// 모든 제품에서 동일하면 {uniform:true, value} / 다르면 {uniform:false, value:null}
// null/undefined도 "동일한 빈 값"으로 인식 (이전엔 null 반환이 다양함과 구분 불가했음)
function _uniformProductValue(prods, key) {
  if (!Array.isArray(prods) || prods.length === 0) return {uniform: true, value: null};
  var first = (prods[0] && prods[0][key] !== undefined) ? prods[0][key] : null;
  for (var i = 1; i < prods.length; i++) {
    var v = (prods[i] && prods[i][key] !== undefined) ? prods[i][key] : null;
    if (v !== first) return {uniform: false, value: null};
  }
  return {uniform: true, value: first};
}

// 신청 1건 = 제품 N행 평탄화 (21컬럼). 같은 신청의 제품 행은 인접 배치.
//   idx: 원본 a.products 배열 내 인덱스 (cur.products[idx] 매핑용)
//   count: 신청 전체 제품 수 (필터 무관 — 「제품 N개」 라벨에 사용)
//   isFirst: 화면 첫 행 여부 (status 필터로 일부만 노출 시 displayIdx===0 행이 isFirst).
//            액션 셀(상태/메모/견적서/이력)·폼 배지·제품 N개 라벨·신청 경계 보더는 isFirst에만 표시
// ════════════════════════════════════════════════════════════════════
// 신청 행 아코디언 + 진행바 (admin-brand-journey PR B)
//   6단계 묶음(검토→견적→입금→발급→취합→발행)을 신청 단위 status로 읽기 전용 표시.
//   제품별 status가 갈리면 「혼합」 배지. status 자동 전이 없음(수동 드롭다운 유지).
//   발급·발행 행동 바로가기는 PR C 에서 연결.
// ════════════════════════════════════════════════════════════════════
var BRAND_JOURNEY_STEPS = [
  { label: '검토', order: 1 },   // reviewing
  { label: '견적', order: 2 },   // quoted
  { label: '입금', order: 3 },   // paid
  { label: '발급', order: 5 },   // orient_sheet_sent
  { label: '취합', order: 6 },   // schedule_sent (취합 = 오리엔 제출 — PR C에서 정밀화)
  { label: '발행', order: 7 },   // campaign_registered
];

// 신청의 대표 진행 단계: 제품별 status 중 가장 덜 진행된 것(보수적) + 혼합/반려 여부
function brandAppJourneyState(a) {
  var prods = Array.isArray(a.products) ? a.products : [];
  var statuses = (prods.length ? prods.map(function (p) { return (p && p.status) || a.status; }) : [a.status]).filter(Boolean);
  if (!statuses.length) statuses = ['new'];
  var uniq = statuses.filter(function (s, i) { return statuses.indexOf(s) === i; });
  var orders = statuses.map(function (s) { return BRAND_STATUS_ORDER_FOR_FUNNEL[s]; }).filter(function (o) { return typeof o === 'number' && o >= 0; });
  var minOrder = orders.length ? Math.min.apply(null, orders) : -1;   // -1 = 전부 반려
  return { order: minOrder, mixed: uniq.length > 1, rejected: statuses.indexOf('rejected') >= 0 };
}

function renderBrandAppJourney(a) {
  var st = brandAppJourneyState(a);
  // 다음 행동 단계 = 아직 도달 못 한 첫 단계
  var nextOrder = null;
  for (var i = 0; i < BRAND_JOURNEY_STEPS.length; i++) {
    if (st.order < BRAND_JOURNEY_STEPS[i].order) { nextOrder = BRAND_JOURNEY_STEPS[i].order; break; }
  }
  var steps = BRAND_JOURNEY_STEPS.map(function (step, i) {
    var done = st.order >= step.order;
    var current = (step.order === nextOrder);
    var circleBg = done ? '#274' : (current ? 'var(--pink)' : '#E5E5E5');
    var circleColor = (done || current) ? '#fff' : '#999';
    var inner = done ? '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">check</span>' : (i + 1);
    var labelColor = done ? '#274' : (current ? 'var(--pink)' : '#999');
    var line = (i < BRAND_JOURNEY_STEPS.length - 1)
      ? '<div style="flex:1;height:2px;background:' + (st.order >= BRAND_JOURNEY_STEPS[i + 1].order ? '#274' : '#E5E5E5') + ';min-width:18px"></div>' : '';
    return '<div style="display:flex;flex-direction:column;align-items:center;gap:4px">'
      + '<div style="width:24px;height:24px;border-radius:50%;background:' + circleBg + ';color:' + circleColor + ';display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700">' + inner + '</div>'
      + '<span style="font-size:11px;font-weight:700;color:' + labelColor + '">' + step.label + '</span></div>'
      + line;
  }).join('');
  var badges = '';
  if (st.mixed) badges += '<span style="background:#FDEEF4;color:#A36;font-size:11px;font-weight:700;padding:2px 8px;border-radius:4px;margin-left:8px">제품별 단계 혼합</span>';
  if (st.rejected) badges += '<span style="background:#F5F5F5;color:#999;font-size:11px;font-weight:700;padding:2px 8px;border-radius:4px;margin-left:8px">반려 포함</span>';
  return '<div style="padding:6px 4px 2px"><div style="display:flex;align-items:center;font-size:13px;font-weight:800;color:var(--ink);margin-bottom:10px">진행 단계' + badges + '</div>'
    + '<div style="display:flex;align-items:flex-start;max-width:560px">' + steps + '</div></div>';
}

// 오리엔시트 발급·취합·발행 섹션 (아코디언 — admin-brand-journey PR C)
//   _orientByApp(목록 로드 시 그룹, data 포함) 재사용. 발급=osIssueFromApplication, 내용·발행=osOpenDetail(PR⑦ 카드별 발행 버튼 포함).
//   비-서베이(신청 없는) 건은 브랜드 관리에서 발급 — 여기는 신청 연결 건만.
function renderBrandAppOrientSection(a) {
  var sheets = (_orientByApp && _orientByApp[a.id]) || [];
  var rows;
  if (!sheets.length) {
    rows = '<div style="color:var(--muted);font-size:12px;margin-bottom:4px">아직 발급된 오리엔시트가 없습니다. 발급하면 브랜드가 작성할 링크가 생성됩니다.</div>';
  } else {
    rows = sheets.map(function (s) {
      var stBadge = (typeof osBadge === 'function' && typeof osStatusOf === 'function') ? osBadge(osStatusOf(s)) : esc(s.status || '');
      var summary = (typeof osCardsSummary === 'function') ? osCardsSummary(s.data) : '';
      var link = (typeof osBuildLink === 'function') ? osBuildLink(s.token) : '';
      return '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;padding:6px 0;border-top:1px solid var(--line,#eee)">'
        + stBadge + '<span style="font-size:12px;color:var(--ink)">' + summary + '</span>'
        + '<div style="margin-left:auto;display:flex;gap:6px">'
        + (link ? '<button type="button" class="btn btn-ghost btn-xs" onclick="event.stopPropagation();copyTextToClipboard(\'' + esc(link) + '\',\'작성 링크가 복사되었습니다.\')">링크 복사</button>' : '')
        + '<button type="button" class="btn btn-primary btn-xs" onclick="event.stopPropagation();osOpenDetail(\'' + esc(s.id) + '\')">내용·발행</button>'
        + '</div></div>';
    }).join('');
  }
  var issueBtn = '<button type="button" class="btn btn-ghost btn-sm" style="margin-top:8px" onclick="event.stopPropagation();osIssueFromApplication(\'' + esc(a.id) + '\')">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:15px;vertical-align:middle">add</span> 오리엔시트 ' + (sheets.length ? '추가 ' : '') + '발급</button>';
  return '<div style="margin-top:14px;padding-top:12px;border-top:1px dashed var(--border-strong,#D4D4CC)">'
    + '<div style="font-size:13px;font-weight:800;color:var(--ink);margin-bottom:6px">오리엔시트 발급 · 취합 · 발행</div>'
    + rows + issueBtn + '</div>';
}

// 신청 행 펼침/접힘 — 마지막 제품 행 뒤에 전체폭 상세 행(진행바 + 오리엔 섹션) 삽입/제거
function toggleBrandAppExpand(appId) {
  var existing = document.querySelector('#brandAppTableBody tr[data-detail-for="' + appId + '"]');
  var caret = document.querySelector('#brandAppTableBody .brand-app-expand-caret[data-id="' + appId + '"]');
  if (existing) {
    existing.remove();
    if (caret) caret.textContent = 'expand_more';
    return;
  }
  var rows = document.querySelectorAll('#brandAppTableBody tr[data-id="' + appId + '"]');
  if (!rows.length) return;
  var lastRow = rows[rows.length - 1];
  var a = (_brandApps || []).find(function (x) { return x.id === appId; });
  if (!a) return;
  var tr = document.createElement('tr');
  tr.setAttribute('data-detail-for', appId);
  tr.className = 'brand-app-detail-row';
  tr.innerHTML = '<td colspan="30" style="background:var(--surface-dim);padding:8px 16px 14px">' + renderBrandAppJourney(a) + renderBrandAppOrientSection(a) + '</td>';
  lastRow.parentNode.insertBefore(tr, lastRow.nextSibling);
  if (caret) caret.textContent = 'expand_less';
}

//   isFirst: 화면 첫 행 여부 (status 필터로 일부만 노출 시 displayIdx===0 행이 isFirst).
//            액션 셀(상태/메모/견적서/이력)·폼 배지·제품 N개 라벨·신청 경계 보더는 isFirst에만 표시
function renderBrandAppFlatRow(a, p, idx, count, isFirst, stripeClass) {
  if (typeof isFirst === 'undefined') isFirst = (idx === 0);
  // stripeClass: 신청 단위 좌측 색 띠 (app-stripe-even / app-stripe-odd). 호출처에서 stripeMap 으로 결정
  var clsAttr = stripeClass ? ' class="' + esc(stripeClass) + '"' : '';
  var qty = Number(p && p.qty) || 0;
  var priceJpy = Number(p && p.price) || 0;
  var priceKrw = priceJpy * BRAND_QUOTE_CONST.FX_JPY_KRW;
  var transferFeeKrw = (!p || p.transfer_fee_krw == null || p.transfer_fee_krw === '') ? null : Number(p.transfer_fee_krw);
  var recruitFeeKrw = (!p || p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? null : Number(p.recruit_fee_krw);
  // 제품 단위 최종견적·VAT 계산 (엑셀 내보내기와 동일 로직)
  var _lineTotal        = qty * priceKrw;
  var _feeTotalKrw      = transferFeeKrw == null ? 0 : qty * transferFeeKrw;
  var _recruitFeeTotKrw = recruitFeeKrw  == null ? 0 : qty * recruitFeeKrw;
  var _finalKrw         = calcBrandAppFinalKrw(a.form_type, _lineTotal, _feeTotalKrw, _recruitFeeTotKrw);
  var _vatKrw           = Math.floor(_finalKrw * (1 + BRAND_QUOTE_CONST.VAT_RATE));

  var dash = '<span style="color:var(--muted)">—</span>';
  var emptyAction = '<td></td>';

  // 같은 신청 첫 행에만 위쪽 핑크 보더로 신청 경계 표시 (행 차등 색상은 모두 제거 — 모든 행에 동일하게 표시)
  var rowStyle = isFirst ? 'border-top:2px solid rgba(200,120,163,.35)' : '';

  // 「직접등록」은 신청번호 옆 작은 칩으로 표시 (사용자 요청 2026-05-12).
  // 폼·채널 배지 줄에서는 제거 — 한 신청에 한 번만 노출되어 시각 잡음 감소.
  var manualBadgeInline = (a.source === 'manual_admin')
    ? '<span style="background:#FFF4E5;color:#B46A1A;font-size:9px;font-weight:600;padding:1px 5px;border-radius:3px;margin-left:6px;vertical-align:middle" title="관리자가 직접 등록한 신청">직접등록</span>'
    : '';

  var html = '<tr' + clsAttr + ' data-id="' + esc(a.id) + '" data-product-idx="' + idx + '"' + (isFirst ? ' data-first="1"' : '') + (rowStyle ? ' style="' + rowStyle + '"' : '') + '>';

  // 1. 신청번호(-N) + 폼 종류(리뷰어/시딩 색 구분) + 리뷰어 채널(큐텐/엣코스메 회색) — 모든 행 동일 표시
  // 신청번호 끝에 -1·-2 인덱스 부착(원본 idx+1)으로 행 식별. 「제품 N개」 별도 라벨 불필요
  // reviewer_channels는 form_type='reviewer'일 때만 의미 (시딩은 항상 NULL — DB CHECK 제약)
  var channelBadges = '';
  if (a.form_type === 'reviewer' && Array.isArray(a.reviewer_channels) && a.reviewer_channels.length > 0) {
    var CH_LABEL = {qoo10: '큐텐', atcosme: '엣코스메'};
    channelBadges = a.reviewer_channels.map(function(c){
      var label = CH_LABEL[c] || c;
      return '<span style="background:#F0F0F0;color:#666;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">' + esc(label) + '</span>';
    }).join('');
  }
  // 폼 라벨 컬러 분기: 리뷰어=핑크, 시딩=파랑. 한눈에 구분되도록 라이트 배경 + 톤 진한 글자.
  var formBg = a.form_type === 'reviewer' ? '#FCE4EC' : '#E3F2FD';
  var formFg = a.form_type === 'reviewer' ? '#B91D5F' : '#1565C0';
  var rowNo = (a.application_no || '—') + (count > 0 ? '-' + (idx + 1) : '');
  html += '<td>'
    + '<div style="font-size:11px;font-weight:600;color:var(--ink)">' + esc(rowNo) + manualBadgeInline + '</div>'
    + '<div style="margin-top:3px;display:flex;flex-wrap:wrap;align-items:center;gap:3px"><span style="background:' + formBg + ';color:' + formFg + ';font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">' + esc(brandAppFormLabel(a.form_type)) + '</span>' + channelBadges + '</div>'
    + '</td>';

  // 2. 브랜드 (모든 행에 동일 색상)
  html += (function(){
    var brandName = a.brand?.name || a.brand_name || '—';
    var brandNo = a.brand?.brand_no || '';
    if (a.brand_id) {
      return '<td><div style="font-weight:600;cursor:pointer;color:var(--pink)" onclick="event.stopPropagation();openBrandDetailModal(\'' + esc(a.brand_id) + '\')" title="브랜드 상세">' + esc(brandName) + '</div>'
        + (brandNo ? '<div style="font-size:10px;color:var(--muted);margin-top:2px;font-variant-numeric:tabular-nums">' + esc(brandNo) + '</div>' : '')
      + '</td>';
    }
    return '<td style="font-weight:600">' + esc(brandName) + '</td>';
  })();

  // 3. 상태 (제품 단위 — products[idx].status 우선, 미설정 시 신청 단위 a.status 폴백. 변경 시 그 셀만 갱신)
  html += '<td>' + brandAppStatusSelectForProduct(a, p, idx) + '</td>';

  // 4. 검수일
  html += '<td style="font-size:11px;color:var(--muted)">' + fmtDate(a.reviewed_at) + '</td>';

  // 5. 신청일
  html += '<td style="font-size:11px;color:var(--muted)">' + fmtDate(a.created_at) + '</td>';

  // 6. 회사명
  html += '<td style="font-size:12px;color:var(--ink)">' + esc(a.brand?.company_name || '—') + '</td>';

  // 7. 담당자
  html += (function(){
    var name = a.applicant_contact_name || a.contact_name || '—';
    var email = a.applicant_email || a.email || '';
    return '<td>'
      + '<div>' + esc(name) + '</div>'
      + (email ? '<div style="font-size:11px;color:var(--muted);margin-top:2px;word-break:break-all">' + esc(email) + '</div>' : '')
    + '</td>';
  })();

  // 8. 연락처
  html += '<td style="font-size:12px">' + esc(formatPhoneDisplay(a.applicant_phone || a.phone) || '—') + '</td>';

  // 9. 계산서 이메일
  html += (function(){
    var be = a.brand?.billing_email || a.billing_email || '';
    return '<td style="font-size:12px;color:' + (be ? 'var(--ink)' : 'var(--muted)') + ';word-break:break-all">' + esc(be || '—') + '</td>';
  })();

  // 10. 요청사항
  html += '<td>' + brandAppNoteCell(a.request_note) + '</td>';

  // 11. 제품명 (제품 단위)
  html += '<td style="font-weight:600;color:var(--ink);font-size:11px;word-break:break-word;line-height:1.4">'
    + (p && p.name ? esc(p.name) : dash)
    + (p && p.name_ja ? '<div style="font-size:10px;font-weight:400;color:var(--muted);margin-top:2px">' + esc(p.name_ja) + '</div>' : '')
    + '</td>';

  // 12. URL (제품 단위)
  html += '<td>' + renderProductUrlCell(p && p.url) + '</td>';

  // 13~16. 신규 4 일정 컬럼 (제품 단위 — 인라인 날짜 편집)
  // 모집기간 (range): products[i].recruit_start ~ products[i].recruit_end
  html += '<td><div class="brand-app-rperiod-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" style="position:relative;min-height:24px">' + renderDateRangeDisplay(p && p.recruit_start, p && p.recruit_end) + '</div></td>';
  // 선정날짜 (single, 시딩만)
  html += '<td><div class="brand-app-seldate-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" data-form-type="' + esc(a.form_type || '') + '" style="position:relative;min-height:24px">' + (a.form_type === 'seeding' ? renderDateSingleDisplay(p && p.selection_date) : '<span style="color:var(--muted);font-size:10px">—</span>') + '</div></td>';
  // 배송기간 (range, 시딩만)
  html += '<td><div class="brand-app-dperiod-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" data-form-type="' + esc(a.form_type || '') + '" style="position:relative;min-height:24px">' + (a.form_type === 'seeding' ? renderDateRangeDisplay(p && p.delivery_start, p && p.delivery_end) : '<span style="color:var(--muted);font-size:10px">—</span>') + '</div></td>';
  // 결과물 제출 마감일 (single)
  html += '<td><div class="brand-app-subdeadline-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" style="position:relative;min-height:24px">' + renderDateSingleDisplay(p && p.submission_deadline) + '</div></td>';

  // 17. 내부 메모 (제품 단위 — 모든 행)
  html += '<td><div class="brand-app-memo-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" style="position:relative;min-height:36px;display:flex;align-items:center">' + renderMemoCellInner(a, idx, p) + '</div></td>';

  // 14. 진행 수량 (제품 단위)
  html += '<td style="text-align:right;font-variant-numeric:tabular-nums;font-size:12px">' + (qty > 0 ? qty.toLocaleString('ja-JP') : dash) + '</td>';

  // 14.5. 가격체크 (제품 단위, 신규) — 마켓 가격 vs 신청 가격 비교
  html += '<td><div class="brand-app-pricecheck-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '">'
        + renderBrandAppPriceCheckCell(a, idx, p)
        + '</div></td>';

  // 15. 상품 가격(엔) (제품 단위)
  html += '<td style="text-align:right;font-variant-numeric:tabular-nums;font-size:12px">' + (priceJpy > 0 ? '¥ ' + priceJpy.toLocaleString('ja-JP') : dash) + '</td>';

  // 16. 상품 가격(원) (제품 단위)
  html += '<td style="text-align:right;font-variant-numeric:tabular-nums;font-size:12px">' + (priceKrw > 0 ? fmtKrw(priceKrw) : dash) + '</td>';

  // 17. 모집비 (제품 단가 — 인라인 편집 가능)
  html += '<td><div class="brand-app-rfee-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" style="position:relative;min-height:24px">' + renderRecruitFeeDisplay(recruitFeeKrw) + '</div></td>';

  // 18. 이체수수료(건) (제품 단가 — 인라인 편집 가능)
  html += '<td><div class="brand-app-tfee-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '" style="position:relative;min-height:24px">' + renderTransferFeeDisplay(transferFeeKrw) + '</div></td>';

  // 19. 최종견적금액 (제품 단위 — VAT 미포함)
  html += '<td style="text-align:right;font-variant-numeric:tabular-nums">' + (_finalKrw ? fmtKrw(_finalKrw) : '') + '</td>';

  // 20. VAT 포함 (제품 단위)
  html += '<td style="text-align:right;font-variant-numeric:tabular-nums">' + (_vatKrw ? fmtKrw(_vatKrw) : '') + '</td>';

  // 20. 견적서 전달 (액션 — 첫 행만)
  html += isFirst
    ? '<td><div class="brand-app-qsent-cell" data-id="' + esc(a.id) + '" style="position:relative;min-height:36px">' + renderQuoteSentDisplay(a.quote_sent_at, a.quote_sent_url, false) + '</div></td>'
    : emptyAction;

  // 21. 오리엔시트 (시스템 + 구글시트 통합 셀 — 첫 행만)
  html += isFirst
    ? '<td title="시스템 발급은 행 더보기 「오리엔시트 링크생성」 / 구글시트는 ✎ 로 외부 URL 입력">' + renderOrientCombinedCell(a) + '</td>'
    : emptyAction;

  // 22. 입금 정보 — 제품 행마다 해당 제품의 플래그만 표시
  html += '<td><div class="brand-app-pay-cell" data-id="' + esc(a.id) + '" data-product-idx="' + idx + '">' + renderBrandAppPaymentFlagsCell(a, idx) + '</div></td>';

  // 23. 입금 날짜 (액션 — 첫 행만, migration 126)
  html += isFirst
    ? '<td><div class="brand-app-paid-at-cell" data-id="' + esc(a.id) + '" style="position:relative;min-height:36px;display:flex;align-items:center">' + renderPaidAtDisplay(a.paid_at, false) + '</div></td>'
    : emptyAction;

  // 24. 관리 — 더보기 메뉴(수정/이력) (액션 — 첫 행만). 이력 카운트는 메뉴 안에 표시
  html += isFirst
    ? '<td style="white-space:nowrap"><span class="material-icons-round notranslate brand-app-expand-caret" translate="no" data-id="' + esc(a.id) + '" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;vertical-align:middle" title="진행 단계 펼치기" onclick="event.stopPropagation();toggleBrandAppExpand(\'' + esc(a.id) + '\')">expand_more</span>'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:var(--muted);cursor:pointer;padding:4px;border-radius:50%;transition:background .15s;vertical-align:middle" onclick="event.stopPropagation();toggleBrandAppRowMenu(event,this,\'' + esc(a.id) + '\')">more_vert</span></td>'
    : emptyAction;

  html += '</tr>';
  return html;
}

// "이력" 버튼: 변경 이력 모달 띄우기
async function openBrandAppHistoryModal(id) {
  var cur = _findBrandApp(id);
  var modal = document.getElementById('brandAppHistoryModal');
  var titleEl = document.getElementById('brandAppHistoryTitle');
  var bodyEl  = document.getElementById('brandAppHistoryBody');
  if (!modal || !titleEl || !bodyEl) return;
  titleEl.textContent = (cur ? (cur.application_no || '') + ' · ' + (cur.brand_name || '') : '신청 이력') + ' — 변경 이력';
  bodyEl.innerHTML = '<div style="padding:32px;text-align:center;color:var(--muted);font-size:13px"><span class="spinner" style="width:18px;height:18px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink);display:inline-block;vertical-align:middle;margin-right:6px"></span>이력 불러오는 중…</div>';
  modal.classList.add('open');
  var rows = await fetchBrandApplicationHistory(id);
  _brandAppHistoryCache.set(id, rows || []);
  bodyEl.innerHTML = renderBrandAppHistoryTableHtml(rows || []);
}

function closeBrandAppHistoryModal() {
  var modal = document.getElementById('brandAppHistoryModal');
  if (modal) modal.classList.remove('open');
}

// ─── 관리자 직접 신청 등록·수정 모달 (091) ───────────────────────
var _nbaBrandMode = 'select';  // 'select' (기존 brand) | 'new' (신규 brand)
var _nbaBrandsCache = null;
// edit 모드 시 신청 ID. null이면 신규 등록 모드. 저장 시 분기 + 낙관적 락 expectedVersion 추출
var _editingBrandAppId = null;

// 더보기 메뉴 「수정」 진입점 — 캐시된 신청 데이터로 prefill
async function openBrandAppEditModal(applicationId) {
  var cur = _findBrandApp(applicationId);
  if (!cur) { toast('신청 데이터를 찾을 수 없습니다', 'error'); return; }
  _editingBrandAppId = applicationId;
  await openNewBrandAppModal(cur.brand_id || null);
  // 모달 헤더·버튼 라벨 변경
  var titleEl = document.getElementById('nbaModalTitle');
  var subtitleEl = document.getElementById('nbaModalSubtitle');
  var submitBtn = document.getElementById('nbaSubmitBtn');
  if (titleEl) titleEl.textContent = '브랜드 서베이 신청 수정';
  if (subtitleEl) subtitleEl.textContent = (cur.application_no || '') + ' · 직접 등록 신청 수정';
  if (submitBtn) submitBtn.textContent = '저장';
  // 폼 prefill
  document.querySelector('input[name="nbaFormType"][value="' + cur.form_type + '"]').checked = true;
  onNbaFormTypeChange();
  // 수정 모드에서 폼 종류 변경 불가 — 라디오 잠금 (제출 가드 + 시각적 lock)
  document.querySelectorAll('input[name="nbaFormType"]').forEach(function(r){ r.disabled = true; });
  document.querySelectorAll('[id^="nbaFt-"]').forEach(function(l){ l.style.opacity = '.6'; l.style.cursor = 'not-allowed'; l.title = '수정 모드에서는 폼 종류를 변경할 수 없습니다'; });
  if (cur.form_type === 'reviewer' && Array.isArray(cur.reviewer_channels)) {
    cur.reviewer_channels.forEach(function(ch){
      var cb = document.querySelector('input[name="nbaReviewerChannels"][value="' + ch + '"]');
      if (cb) cb.checked = true;
    });
  }
  var setVal = function(id, val) { var el = document.getElementById(id); if (el) el.value = val || ''; };
  setVal('nbaCompanyName',  cur.brand?.company_name || '');
  setVal('nbaBrandName',    cur.brand?.name || cur.brand_name || '');
  setVal('nbaBrandNameJa',  cur.brand?.name_ja || '');
  setVal('nbaBusinessNo',   cur.brand?.business_no || '');
  setVal('nbaContactName',  cur.applicant_contact_name || cur.contact_name || '');
  setVal('nbaPhone',        cur.applicant_phone || cur.phone || '');
  setVal('nbaEmail',        cur.applicant_email || cur.email || '');
  setVal('nbaBillingEmail', cur.billing_email || cur.brand?.billing_email || '');
  setVal('nbaRequestNote',  cur.request_note || '');
  // products 행 재구성
  var wrap = document.getElementById('nbaProductRows');
  if (wrap) wrap.innerHTML = '';
  var prods = Array.isArray(cur.products) ? cur.products : [];
  if (prods.length === 0) prods = [{}];
  prods.forEach(function(p) {
    addNbaProductRow();
    var lastRow = wrap.lastElementChild;
    if (!lastRow) return;
    var setRowVal = function(cls, v) { var el = lastRow.querySelector('.' + cls); if (el) el.value = (v == null ? '' : String(v)); };
    setRowVal('nba-prod-name',         p.name);
    setRowVal('nba-prod-name-ja',      p.name_ja);
    setRowVal('nba-prod-price',        p.price);
    setRowVal('nba-prod-qty',          p.qty);
    setRowVal('nba-prod-recruit-fee',  p.recruit_fee_krw);
    setRowVal('nba-prod-transfer-fee', p.transfer_fee_krw);
    setRowVal('nba-prod-url',          p.url);
  });
}

async function openNewBrandAppModal(prefilledBrandId) {
  var modal = document.getElementById('newBrandAppModal');
  if (!modal) return;
  // 헤더·버튼을 신규 등록 기본값으로 원복 (edit 진입자가 후속 갱신)
  var titleEl = document.getElementById('nbaModalTitle');
  var subtitleEl = document.getElementById('nbaModalSubtitle');
  var submitBtnReset = document.getElementById('nbaSubmitBtn');
  if (titleEl) titleEl.textContent = '브랜드 서베이 신청 등록';
  if (subtitleEl) subtitleEl.textContent = '영업팀이 전화·메일·미팅으로 받은 신청을 관리자가 직접 등록';
  if (submitBtnReset) submitBtnReset.textContent = '등록';
  // 폼 reset
  document.querySelectorAll('input[name="nbaFormType"]').forEach(function(r){ r.checked = false; });
  document.querySelectorAll('[id^="nbaFt-"]').forEach(function(l){ l.style.borderColor = 'var(--line)'; l.style.background = ''; l.style.color = ''; var ic = l.querySelector('.material-icons-round'); if (ic) { ic.textContent = 'radio_button_unchecked'; ic.style.color = 'var(--muted)'; } });
  // 리뷰어 채널 체크박스 + 그룹 hide reset
  document.querySelectorAll('input[name="nbaReviewerChannels"]').forEach(function(cb){ cb.checked = false; });
  var nbaChGrp = document.getElementById('nbaReviewerChannelsGroup');
  if (nbaChGrp) nbaChGrp.style.display = 'none';
  ['nbaCompanyName','nbaBrandName','nbaBrandNameJa','nbaBusinessNo','nbaContactName','nbaPhone','nbaEmail','nbaBillingEmail','nbaRequestNote'].forEach(function(id){ var el = document.getElementById(id); if (el) el.value = ''; });
  // 담당자 빠른 선택 드롭다운 초기화
  var contactSelReset = document.getElementById('nbaContactSelect');
  if (contactSelReset) { contactSelReset.style.display = 'none'; contactSelReset.innerHTML = '<option value="">-- 등록된 담당자 빠른 선택 --</option>'; contactSelReset.value = ''; }
  var sendCheck = document.getElementById('nbaSendNotification'); if (sendCheck) sendCheck.checked = false;
  var syncCheck = document.getElementById('nbaBrandSync'); if (syncCheck) syncCheck.checked = true;
  // 제품 entries 초기화 — 기본 1개 행
  document.getElementById('nbaProductRows').innerHTML = '';
  addNbaProductRow();
  // brand 드롭다운 로드 + prefill
  setNbaBrandMode('select');
  await loadNbaBrandSelect(prefilledBrandId || '');
  if (prefilledBrandId) {
    var sel = document.getElementById('nbaBrandSelect');
    if (sel) { sel.value = prefilledBrandId; onNbaBrandChange(); }
  }
  modal.classList.add('open');
}

function closeNewBrandAppModal() {
  var modal = document.getElementById('newBrandAppModal');
  if (modal) modal.classList.remove('open');
  _editingBrandAppId = null;  // edit 모드 종료
  // 폼 종류 라디오 잠금 해제 (다음 신규 등록 시 정상 동작 위해)
  document.querySelectorAll('input[name="nbaFormType"]').forEach(function(r){ r.disabled = false; });
  document.querySelectorAll('[id^="nbaFt-"]').forEach(function(l){ l.style.opacity = ''; l.style.cursor = ''; l.title = ''; });
}

function onNbaFormTypeChange() {
  var picked = document.querySelector('input[name="nbaFormType"]:checked');
  document.querySelectorAll('[id^="nbaFt-"]').forEach(function(l){
    var v = l.querySelector('input')?.value;
    var on = picked && v === picked.value;
    l.style.borderColor = on ? 'var(--pink)' : 'var(--line)';
    l.style.background = on ? 'var(--light-pink)' : '';
    l.style.color = on ? 'var(--pink)' : '';
    var ic = l.querySelector('.material-icons-round');
    if (ic) { ic.textContent = on ? 'radio_button_checked' : 'radio_button_unchecked'; ic.style.color = on ? 'var(--pink)' : 'var(--muted)'; }
  });
  // 리뷰어 채널 영역(큐텐/엣코스메 다중 선택)은 reviewer 폼일 때만 노출. seeding이면 hide + 값 reset
  var ch = document.getElementById('nbaReviewerChannelsGroup');
  if (ch) {
    var isReviewer = picked && picked.value === 'reviewer';
    ch.style.display = isReviewer ? '' : 'none';
    if (!isReviewer) {
      document.querySelectorAll('input[name="nbaReviewerChannels"]').forEach(function(cb){ cb.checked = false; });
    }
  }
}

async function loadNbaBrandSelect(currentBrandId) {
  var sel = document.getElementById('nbaBrandSelect');
  if (!sel) return;
  if (!_nbaBrandsCache) {
    _nbaBrandsCache = await fetchBrands({status: 'active'}) || [];
  }
  var html = '<option value="">-- 브랜드 선택 --</option>';
  for (var i = 0; i < _nbaBrandsCache.length; i++) {
    var b = _nbaBrandsCache[i];
    var label = esc(b.name) + (b.brand_no ? ' [' + esc(b.brand_no) + ']' : '');
    html += '<option value="' + esc(b.id) + '"' + (currentBrandId === b.id ? ' selected' : '') + '>' + label + '</option>';
  }
  // 리스트 끝에 신규 등록 옵션 (구분선 후 표시)
  html += '<option disabled>──────────</option>';
  html += '<option value="__new__">+ 신규 브랜드 등록</option>';
  sel.innerHTML = html;
}

function setNbaBrandMode(mode) {
  _nbaBrandMode = (mode === 'new') ? 'new' : 'select';
  var sel = document.getElementById('nbaBrandSelect');
  var hint = document.getElementById('nbaBrandModeHint');
  var nameInput = document.getElementById('nbaBrandName');
  if (_nbaBrandMode === 'new') {
    // 드롭다운에 「+ 신규 브랜드 등록」 옵션이 선택된 상태로 유지 — 시각적 피드백
    if (sel) sel.value = '__new__';
    if (nameInput) { nameInput.value = ''; nameInput.readOnly = false; nameInput.focus(); }
    if (hint) hint.innerHTML = '<strong style="color:var(--pink)">신규 브랜드 입력</strong> — 브랜드명·회사명·담당자 모두 새로 입력. 저장 시 brands 마스터에 자동 등록됩니다.';
    // 브랜드 정보 영역 초기화 (회사명·일본어명·사업자번호 + 담당자 4종)
    ['nbaCompanyName','nbaBrandNameJa','nbaBusinessNo','nbaContactName','nbaPhone','nbaEmail','nbaBillingEmail'].forEach(function(id){ var el = document.getElementById(id); if (el) el.value = ''; });
  } else {
    // 기존 brand 모드: 브랜드명은 드롭다운 선택으로만 갱신 (직접 편집 차단 — 마스터 동기화 혼선 방지)
    if (nameInput) nameInput.readOnly = true;
    if (hint) hint.textContent = '리스트에서 기존 브랜드를 선택하거나 「+ 신규 브랜드 등록」으로 새 브랜드를 등록하세요.';
  }
}

function onNbaBrandChange() {
  var sel = document.getElementById('nbaBrandSelect');
  if (!sel) return;
  var brandId = sel.value || '';
  // 담당자 드롭다운 항상 초기화
  var contactSel = document.getElementById('nbaContactSelect');
  if (contactSel) { contactSel.style.display = 'none'; contactSel.innerHTML = '<option value="">-- 등록된 담당자 빠른 선택 --</option>'; contactSel.value = ''; }
  // 「+ 신규 브랜드 등록」 옵션 선택 → 신규 모드로 전환
  if (brandId === '__new__') {
    setNbaBrandMode('new');
    return;
  }
  if (!brandId) {
    // 미선택 상태 (-- 브랜드 선택 -- 옵션) → select 모드 + 입력 영역 초기화
    _nbaBrandMode = 'select';
    var hintInit = document.getElementById('nbaBrandModeHint');
    if (hintInit) hintInit.textContent = '리스트에서 기존 브랜드를 선택하거나 「+ 신규 브랜드 등록」으로 새 브랜드를 등록하세요.';
    return;
  }
  _nbaBrandMode = 'select';
  var picked = (_nbaBrandsCache || []).find(function(b){ return b.id === brandId; });
  if (!picked) return;
  // contacts 배열 정리: is_primary=true 우선, 그 외 순서 유지
  var contacts = Array.isArray(picked.contacts) ? picked.contacts.slice() : [];
  var primaryContact = contacts.find(function(c){ return c.is_primary; }) || contacts[0] || null;
  var setVal = function(id, v){ var el = document.getElementById(id); if (el) el.value = (v == null) ? '' : String(v); };
  setVal('nbaCompanyName', picked.company_name);
  setVal('nbaBrandName', picked.name);
  setVal('nbaBrandNameJa', picked.name_ja);
  setVal('nbaBusinessNo', picked.business_no);
  setVal('nbaContactName', primaryContact?.name || picked.primary_contact_name);
  setVal('nbaPhone', primaryContact?.phone || picked.primary_phone);
  setVal('nbaEmail', primaryContact?.email || picked.primary_email);
  setVal('nbaBillingEmail', picked.billing_email);
  // 담당자가 2명 이상이면 빠른 선택 드롭다운 노출
  if (contactSel && contacts.length >= 2) {
    var html = '<option value="">-- 등록된 담당자 빠른 선택 --</option>';
    for (var i = 0; i < contacts.length; i++) {
      var c = contacts[i];
      var label = (c.name || '(이름 없음)') + (c.is_primary ? ' (대표)' : '') + (c.email ? ' · ' + c.email : '');
      html += '<option value="' + i + '"' + (c === primaryContact ? ' selected' : '') + '>' + esc(label) + '</option>';
    }
    contactSel.innerHTML = html;
    contactSel.style.display = '';
    // 캐시: 변경 시 인덱스로 재참조하기 위해 dataset에 brandId 저장
    contactSel.dataset.brandId = brandId;
  }
  var hint = document.getElementById('nbaBrandModeHint');
  if (hint) hint.innerHTML = '<strong>' + esc(picked.brand_no || '') + '</strong> 정보가 채워졌습니다. 수정 시 「브랜드 마스터 갱신」 체크 상태에 따라 brands 테이블에도 동기 반영됩니다.';
}

function onNbaContactSelectChange() {
  var contactSel = document.getElementById('nbaContactSelect');
  if (!contactSel) return;
  var brandId = contactSel.dataset.brandId || document.getElementById('nbaBrandSelect')?.value || '';
  var picked = (_nbaBrandsCache || []).find(function(b){ return b.id === brandId; });
  var idx = parseInt(contactSel.value, 10);
  if (!picked || isNaN(idx) || !Array.isArray(picked.contacts) || !picked.contacts[idx]) return;
  var c = picked.contacts[idx];
  var setVal = function(id, v){ var el = document.getElementById(id); if (el) el.value = (v == null) ? '' : String(v); };
  setVal('nbaContactName', c.name);
  setVal('nbaPhone', c.phone);
  setVal('nbaEmail', c.email);
}

function addNbaProductRow() {
  var wrap = document.getElementById('nbaProductRows');
  if (!wrap) return;
  var rowIdx = wrap.children.length;
  var row = document.createElement('div');
  row.className = 'nba-product-row';
  row.dataset.idx = rowIdx;
  row.style.cssText = 'display:grid;grid-template-columns:1.4fr 1.4fr 100px 90px 120px 120px 1fr 32px;gap:8px;align-items:stretch;padding:8px 10px;background:var(--bg);border-radius:8px';
  row.innerHTML =
    '<input type="text" class="form-input nba-prod-name" placeholder="제품 이름" style="font-size:14px">' +
    '<input type="text" class="form-input nba-prod-name-ja" placeholder="상품명 (일본어)" style="font-size:14px">' +
    '<input type="number" class="form-input nba-prod-price" placeholder="0" min="0" value="0" style="font-size:14px">' +
    '<input type="number" class="form-input nba-prod-qty" placeholder="0" min="0" value="0" style="font-size:14px">' +
    '<input type="number" class="form-input nba-prod-recruit-fee" placeholder="0" min="0" style="font-size:14px" title="제품 1건당 모집비(원). 비워두면 0 — 견적 합산에서 제외">' +
    '<input type="number" class="form-input nba-prod-transfer-fee" placeholder="리뷰어 자동 2500 / 시딩 자동 0" min="0" style="font-size:14px" title="비워두면 리뷰어는 ₩2,500, 시딩은 ₩0 자동 등록 (098 트리거)">' +
    '<input type="url" class="form-input nba-prod-url" placeholder="https://..." style="font-size:14px">' +
    '<button type="button" class="btn btn-ghost btn-xs" onclick="removeNbaProductRow(this)" title="제품 제거" style="padding:0;display:flex;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">close</span></button>';
  wrap.appendChild(row);
}

function removeNbaProductRow(btn) {
  var wrap = document.getElementById('nbaProductRows');
  if (!wrap) return;
  var row = btn.closest('.nba-product-row');
  if (!row) return;
  if (wrap.children.length <= 1) {
    toast('최소 1개 제품이 필요합니다', 'warn');
    return;
  }
  row.remove();
}

function _collectNbaProducts() {
  var rows = document.querySelectorAll('#nbaProductRows .nba-product-row');
  var products = [];
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    var name = (r.querySelector('.nba-prod-name')?.value || '').trim();
    var nameJa = (r.querySelector('.nba-prod-name-ja')?.value || '').trim();
    var price = parseInt(r.querySelector('.nba-prod-price')?.value) || 0;
    var qty = parseInt(r.querySelector('.nba-prod-qty')?.value) || 0;
    var recruitFeeRaw = (r.querySelector('.nba-prod-recruit-fee')?.value || '').trim();
    var feeRaw = (r.querySelector('.nba-prod-transfer-fee')?.value || '').trim();
    var url = (r.querySelector('.nba-prod-url')?.value || '').trim();
    if (!name && !nameJa && !price && !qty && !recruitFeeRaw && !feeRaw && !url) continue;  // 빈 행 스킵
    if (!name) { toast('제품 ' + (i + 1) + ': 이름이 비었습니다', 'error'); return null; }
    if (qty <= 0) { toast('제품 ' + (i + 1) + ': 수량은 1 이상', 'error'); return null; }
    // 트리거 trg_brand_app_recalc(052·111)는 price·qty·recruit_fee_krw·transfer_fee_krw 모두 읽음
    var item = { name: name, price: price, qty: qty, url: url || null };
    if (nameJa) item.name_ja = nameJa;  // 선택 입력 시에만 저장 (sales 폼 데이터 호환)
    // recruit_fee_krw: 명시 입력하면 그 값. 비우면 키 미저장 → 트리거가 COALESCE(0)
    if (recruitFeeRaw !== '') {
      var rFeeNum = parseInt(recruitFeeRaw);
      if (!isNaN(rFeeNum) && rFeeNum >= 0) item.recruit_fee_krw = rFeeNum;
    }
    // transfer_fee_krw: 명시 입력하면 그 값. 비우면 098 트리거가 reviewer는 2500, seeding은 0 자동 채움
    if (feeRaw !== '') {
      var feeNum = parseInt(feeRaw);
      if (!isNaN(feeNum) && feeNum >= 0) item.transfer_fee_krw = feeNum;
    }
    products.push(item);
  }
  return products;
}

async function submitNewBrandApp() {
  var formType = document.querySelector('input[name="nbaFormType"]:checked')?.value;
  if (!formType) { toast('폼 종류를 선택해주세요', 'error'); return; }
  var rawSel = document.getElementById('nbaBrandSelect')?.value || '';
  // __new__는 신규 모드 — brandId는 null 전달
  var brandId = (_nbaBrandMode === 'select' && rawSel && rawSel !== '__new__') ? rawSel : '';
  // 미선택 + 신규 모드도 아님 → 차단
  if (_nbaBrandMode === 'select' && !brandId) {
    toast('드롭다운에서 기존 브랜드를 선택하거나 「+ 신규 브랜드 등록」을 선택하세요', 'error');
    return;
  }
  var companyName = (document.getElementById('nbaCompanyName')?.value || '').trim();
  var brandName = (document.getElementById('nbaBrandName')?.value || '').trim();
  var brandNameJa = (document.getElementById('nbaBrandNameJa')?.value || '').trim();
  var businessNo = (document.getElementById('nbaBusinessNo')?.value || '').trim();
  var contactName = (document.getElementById('nbaContactName')?.value || '').trim();
  var phone = (document.getElementById('nbaPhone')?.value || '').trim();
  var email = (document.getElementById('nbaEmail')?.value || '').trim();
  var billingEmail = (document.getElementById('nbaBillingEmail')?.value || '').trim();
  var requestNote = (document.getElementById('nbaRequestNote')?.value || '').trim();
  var brandSync = !!document.getElementById('nbaBrandSync')?.checked;
  if (!brandName) { toast('브랜드명을 입력해주세요', 'error'); return; }
  // 담당자·연락처·이메일은 선택 항목 — 빈 값 허용. 단 이메일 입력했으면 형식 검증.
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { toast('이메일 형식이 올바르지 않습니다', 'error'); return; }
  var products = _collectNbaProducts();
  if (!products) return;
  if (products.length === 0) { toast('제품을 1개 이상 입력해주세요', 'error'); return; }
  // 신규 모드면 brandId NULL 전달
  if (_nbaBrandMode === 'new') brandId = null;
  // 리뷰어 채널 수집 — reviewer 폼일 때만 의미. 시딩이면 NULL (RPC에서 자동 NULL 강제됨)
  var reviewerChannels = null;
  if (formType === 'reviewer') {
    var checkedChannels = Array.from(document.querySelectorAll('input[name="nbaReviewerChannels"]:checked')).map(function(cb){ return cb.value; });
    reviewerChannels = checkedChannels.length > 0 ? checkedChannels : null;
  }
  var btn = document.getElementById('nbaSubmitBtn');
  if (btn) { btn.disabled = true; btn.textContent = '저장 중...'; }
  var isEdit = !!_editingBrandAppId;
  var result;
  if (isEdit) {
    // 수정 모드 — 신청 본체 컬럼 patch + 낙관적 락
    var cur = _findBrandApp(_editingBrandAppId);
    if (!cur) {
      if (btn) { btn.disabled = false; btn.textContent = '저장'; }
      toast('신청 데이터를 찾을 수 없습니다 — 새로고침 후 다시 시도해주세요', 'error');
      return;
    }
    // 폼 종류 변경은 채번·트리거 영향이 있어 막음 (편집 모달 라디오는 그대로 두지만 제출 시 검증)
    if (formType !== cur.form_type) {
      if (btn) { btn.disabled = false; btn.textContent = '저장'; }
      toast('폼 종류는 수정할 수 없습니다 (신청번호 채번 영향)', 'warn');
      return;
    }
    var patch = {
      contact_name:             contactName || null,
      phone:                    phone || null,
      email:                    email || null,
      billing_email:            billingEmail || null,
      products:                 products,
      request_note:             requestNote || null,
      reviewer_channels:        reviewerChannels,
      // brand_name은 brand 마스터에서 보통 표시되지만 신청 시점 스냅샷도 갱신
      brand_name:               brandName || null
    };
    result = await updateBrandApplication(_editingBrandAppId, patch, cur.version);
    if (btn) { btn.disabled = false; btn.textContent = '저장'; }
    if (result.conflict) {
      toast('다른 관리자가 먼저 변경했습니다. 새로고침 후 다시 시도해주세요', 'warn');
      await loadBrandApplications();
      return;
    }
    if (!result.ok) {
      toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
      return;
    }
    toast('수정 완료');
    closeNewBrandAppModal();
    await loadBrandApplications();
    return;
  }
  // 신규 등록 모드 (기존 흐름)
  result = await adminCreateBrandApplication({
    formType: formType,
    brandId: brandId || null,
    companyName: companyName || null,
    brandName: brandName,
    brandNameJa: brandNameJa || null,
    businessNo: businessNo || null,
    contactName: contactName,
    phone: phone,
    email: email,
    billingEmail: billingEmail || null,
    products: products,
    requestNote: requestNote || null,
    brandSync: brandSync,
    reviewerChannels: reviewerChannels
  });
  if (btn) { btn.disabled = false; btn.textContent = '등록'; }
  if (!result.ok) {
    toast('등록 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  var no = result.data?.application_no || '';
  toast('신청이 등록되었습니다 (' + no + ')', 'success');
  closeNewBrandAppModal();
  // brand 캐시 무효화 (신규 brand면 리스트에 추가됨)
  _nbaBrandsCache = null;
  if (typeof _campBrandsCache !== 'undefined') _campBrandsCache = null;
  // 페인 리로드
  if (typeof loadBrandApplications === 'function') {
    await loadBrandApplications();
  }
}

// ─── 내부 메모 (multi-entry, 제품별) 모달 ────────────────────────────
// migration 123 이후: (application_id, product_idx) 페어 단위 메모.
// 메모 셀 ✎ 클릭 또는 코드에서 직접 호출. productIdx 미지정 시 0.
async function openBrandAppMemoModal(id, productIdx) {
  _brandAppMemoModalCurrentId = id;
  _brandAppMemoModalCurrentProductIdx = (typeof productIdx === 'number' && productIdx >= 0) ? productIdx : 0;
  var cur = _findBrandApp(id);
  var prods = (cur && Array.isArray(cur.products)) ? cur.products : [];
  var product = prods[_brandAppMemoModalCurrentProductIdx] || {};
  var productName = product.name || ('제품 ' + (_brandAppMemoModalCurrentProductIdx + 1));
  var modal = document.getElementById('brandAppMemoModal');
  var titleEl = document.getElementById('brandAppMemoTitle');
  var bodyEl  = document.getElementById('brandAppMemoBody');
  var newInput = document.getElementById('brandAppMemoNewInput');
  if (!modal || !titleEl || !bodyEl) return;
  titleEl.textContent = (cur ? (cur.application_no || '') + ' · ' + productName : ('제품 ' + (_brandAppMemoModalCurrentProductIdx + 1))) + ' — 내부 메모';
  bodyEl.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px"><span class="spinner" style="width:16px;height:16px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink);display:inline-block;vertical-align:middle;margin-right:6px"></span>불러오는 중…</div>';
  if (newInput) newInput.value = '';
  modal.classList.add('open');
  await loadBrandAppMemoList();
  if (newInput) newInput.focus();
}

function closeBrandAppMemoModal() {
  var modal = document.getElementById('brandAppMemoModal');
  if (modal) modal.classList.remove('open');
  _brandAppMemoModalCurrentId = null;
  _brandAppMemoModalCurrentProductIdx = 0;
}

async function loadBrandAppMemoList() {
  if (!_brandAppMemoModalCurrentId) return;
  var appId = _brandAppMemoModalCurrentId;
  var productIdx = _brandAppMemoModalCurrentProductIdx;
  var rows = await fetchBrandAppMemos(appId, productIdx);
  _brandAppMemoModalCache = rows || [];
  renderBrandAppMemoList();
  // migration 125: 모달이 메모를 표시 = 본인이 봤다는 의도 → 일괄 read 처리
  if (_brandAppMemoModalCache.length > 0) {
    await markBrandAppMemosRead(appId, productIdx);
  }
  // 목록 셀 카운트 동기화 — 페어 키 (본인 기준 unreadCount=0, 다른 관리자 영향 없음)
  var key = appId + '_' + productIdx;
  _brandAppMemoSummaries[key] = {
    count: _brandAppMemoModalCache.length,
    unreadCount: 0,
    latest: _brandAppMemoModalCache.length > 0 ? _brandAppMemoModalCache[0].text : null
  };
  _refreshBrandAppMemoCell(appId, productIdx);
}

function renderBrandAppMemoList() {
  var bodyEl = document.getElementById('brandAppMemoBody');
  if (!bodyEl) return;
  if (_brandAppMemoModalCache.length === 0) {
    bodyEl.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted);font-size:13px">메모가 없습니다. 아래에 새 메모를 입력하세요.</div>';
    return;
  }
  bodyEl.innerHTML = _brandAppMemoModalCache.map(function(m){
    var when = m.created_at ? new Date(m.created_at).toLocaleString('ko-KR', {timeZone:'Asia/Seoul'}) : '';
    var edited = (m.updated_at && m.created_at && m.updated_at !== m.created_at)
      ? '<span style="color:var(--muted);font-size:10px;margin-left:6px">(수정됨 ' + esc(new Date(m.updated_at).toLocaleString('ko-KR', {timeZone:'Asia/Seoul'})) + ')</span>'
      : '';
    return '<div class="bam-row" data-memo-id="' + esc(m.id) + '" style="padding:10px 12px;margin-bottom:8px;border:1px solid var(--line);border-radius:8px;background:#fff">'
      + '<div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px;font-size:11px;color:var(--muted)">'
        + '<div><span style="font-weight:600;color:var(--ink)">' + esc(formatBrandAppMemoAuthor(m.author_name)) + '</span> · ' + esc(when) + edited + '</div>'
        + '<div style="display:flex;gap:4px">'
          + '<button class="btn btn-ghost btn-xs" onclick="enterBrandAppMemoEdit(\'' + esc(m.id) + '\')" style="padding:2px 8px" title="수정"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">edit</span></button>'
          + '<button class="btn btn-ghost btn-xs" onclick="deleteBrandAppMemoConfirm(\'' + esc(m.id) + '\')" style="padding:2px 8px;color:#c0392b" title="삭제"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete_outline</span></button>'
        + '</div>'
      + '</div>'
      + '<div class="bam-text" style="font-size:13px;color:var(--ink);white-space:pre-wrap;word-break:break-word;line-height:1.5">' + esc(m.text) + '</div>'
    + '</div>';
  }).join('');
}

function enterBrandAppMemoEdit(memoId) {
  var row = document.querySelector('.bam-row[data-memo-id="' + (CSS.escape ? CSS.escape(memoId) : memoId) + '"]');
  if (!row) return;
  var memo = _brandAppMemoModalCache.find(function(m){ return m.id === memoId; });
  if (!memo) return;
  var textDiv = row.querySelector('.bam-text');
  if (!textDiv) return;
  textDiv.outerHTML = '<div style="display:flex;flex-direction:column;gap:6px">'
    + '<textarea class="bam-edit-input" style="width:100%;min-height:60px;padding:6px 8px;border:1px solid var(--pink);border-radius:6px;font-size:13px;font-family:inherit;resize:vertical">' + esc(memo.text) + '</textarea>'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button class="btn btn-ghost btn-xs" onclick="cancelBrandAppMemoEdit(\'' + esc(memoId) + '\')" style="padding:3px 10px">취소</button>'
      + '<button class="btn btn-primary btn-xs" onclick="confirmBrandAppMemoEdit(\'' + esc(memoId) + '\')" style="padding:3px 12px">저장</button>'
    + '</div>'
  + '</div>';
  var input = row.querySelector('.bam-edit-input');
  if (input) { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }
}

function cancelBrandAppMemoEdit(memoId) {
  // 단순히 다시 렌더 (캐시에서)
  renderBrandAppMemoList();
}

async function confirmBrandAppMemoEdit(memoId) {
  var row = document.querySelector('.bam-row[data-memo-id="' + (CSS.escape ? CSS.escape(memoId) : memoId) + '"]');
  if (!row) return;
  var input = row.querySelector('.bam-edit-input');
  if (!input) return;
  var newText = (input.value || '').trim();
  if (!newText) { toast('메모 내용을 입력하세요.', 'warn'); return; }
  input.disabled = true;
  var result = await updateBrandAppMemo(memoId, newText);
  if (!result.ok) { toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error'); input.disabled = false; return; }
  toast('메모가 저장되었습니다.');
  if (_brandAppMemoModalCurrentId) _refreshBrandAppHistoryButton(_brandAppMemoModalCurrentId);
  await loadBrandAppMemoList();
}

async function deleteBrandAppMemoConfirm(memoId) {
  if (!confirm('이 메모를 삭제할까요?')) return;
  var result = await deleteBrandAppMemo(memoId);
  if (!result.ok) { toast('삭제 실패: ' + (result.error || '알 수 없는 오류'), 'error'); return; }
  toast('메모가 삭제되었습니다.');
  if (_brandAppMemoModalCurrentId) _refreshBrandAppHistoryButton(_brandAppMemoModalCurrentId);
  await loadBrandAppMemoList();
}

async function submitNewBrandAppMemo() {
  if (!_brandAppMemoModalCurrentId) return;
  var input = document.getElementById('brandAppMemoNewInput');
  if (!input) return;
  var text = (input.value || '').trim();
  if (!text) { toast('메모 내용을 입력하세요.', 'warn'); return; }
  input.disabled = true;
  var name = currentAdminInfo?.name || currentUser?.email || '관리자';
  var authorId = currentUser?.id || null;
  var result = await insertBrandAppMemo(_brandAppMemoModalCurrentId, text, authorId, name, _brandAppMemoModalCurrentProductIdx);
  input.disabled = false;
  if (!result.ok) { toast('추가 실패: ' + (result.error || '알 수 없는 오류'), 'error'); return; }
  input.value = '';
  toast('메모가 추가되었습니다.');
  _refreshBrandAppHistoryButton(_brandAppMemoModalCurrentId);
  await loadBrandAppMemoList();
}

// 메모 셀(목록의 내부 메모 컬럼)에서 latest 메모 + 카운트 표시 갱신 (인라인)
// 제품별 메모 셀 갱신 — 특정 제품 idx 또는 신청의 전체 제품 셀
function _refreshBrandAppMemoCell(applicationId, productIdx) {
  var cur = _findBrandApp(applicationId);
  if (!cur) return;
  var prods = Array.isArray(cur.products) ? cur.products : [];
  var cells = document.querySelectorAll('#brandAppTableBody td .brand-app-memo-cell[data-id="' + applicationId + '"]');
  cells.forEach(function(cell) {
    var cidx = parseInt(cell.dataset.productIdx, 10);
    if (productIdx !== undefined && cidx !== productIdx) return;
    cell.innerHTML = renderMemoCellInner(cur, cidx, prods[cidx] || {});
  });
}

// 메모 셀 inner HTML — brand_application_memos 의 (app_id, product_idx) 최신 메모 + 미확인 배지 + 모달 진입 버튼
// (migration 123: products[i].admin_memo 폐기, migration 125: 분홍 배지 = 미확인 메모 수)
function renderMemoCellInner(a, idx, p) {
  var locked = a.status === 'done' || a.status === 'rejected';
  var summaryKey = a.id + '_' + idx;
  var summary = (_brandAppMemoSummaries && _brandAppMemoSummaries[summaryKey]) || null;
  var latestText = summary && summary.latest ? String(summary.latest) : '';
  var totalCount = summary && summary.count ? summary.count : 0;
  var unreadCount = summary && summary.unreadCount ? summary.unreadCount : 0;
  return renderProductMemoDisplay(latestText, totalCount, unreadCount, !!locked);
}

// 셀 표시: 최신 메모 1줄 + 미확인 배지(>0 일 때만) + ✎ (모달 진입)
function renderProductMemoDisplay(latestText, totalCount, unreadCount, locked) {
  var preview = '';
  if (latestText) {
    var t = String(latestText).trim();
    if (t.length > 40) t = t.slice(0, 40) + '…';
    preview = '<span style="color:var(--ink);font-size:11px;line-height:1.35">' + esc(t) + '</span>';
  } else {
    preview = '<span style="color:var(--muted);font-size:11px">—</span>';
  }
  // 미확인 메모가 있을 때만 분홍 배지
  var badge = unreadCount > 0
    ? '<span title="안 읽은 메모 ' + unreadCount + '건" style="display:inline-block;margin-left:4px;padding:0 6px;background:var(--pink);color:#fff;border-radius:8px;font-size:10px;font-weight:600;line-height:14px;vertical-align:middle">' + unreadCount + '</span>'
    : '';
  var btnTitle = locked
    ? '완료/거절 신청 — 모달 열람만 가능'
    : (totalCount > 0 ? '메모 ' + totalCount + '건' + (unreadCount > 0 ? ' · 안 읽음 ' + unreadCount : '') : '메모 추가');
  var btn = '<button type="button" class="brand-app-memo-open-btn" onclick="openBrandAppMemoModalFromCell(this)" title="' + esc(btnTitle) + '" style="position:absolute;top:50%;right:0;transform:translateY(-50%);background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px" onmouseover="this.style.background=\'rgba(0,0,0,.05)\'" onmouseout="this.style.background=\'none\'"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">edit</span></button>';
  return '<div style="padding-right:22px;line-height:1.4;display:flex;align-items:center;flex-wrap:wrap;gap:2px;width:100%">' + preview + badge + '</div>' + btn;
}

// (legacy) 라벨을 한국어 친화적 표기로 변환 — backfill 데이터 식별
function formatBrandAppMemoAuthor(name) {
  if (!name) return '시스템';
  if (name === '(legacy)') return '(자동 이전)';
  return name;
}

// 메모 셀 ✎ 버튼 클릭 → 모달 진입 (제품별)
function openBrandAppMemoModalFromCell(btnEl) {
  var cell = btnEl.closest('.brand-app-memo-cell');
  if (!cell) return;
  var appId = cell.dataset.id;
  var productIdx = parseInt(cell.dataset.productIdx, 10);
  if (!appId || isNaN(productIdx)) return;
  openBrandAppMemoModal(appId, productIdx);
}

// 제품 jsonb 변경을 sub-field 단위로 풀어서 가상 history rows 반환
// [migration 123] admin_memo 항목 제외 — 제품별 메모는 brand_application_memos 로 이전됨.
// 메모 변경은 별도 memo_added/edited/deleted 행으로 history 에 기록됨.
// sub-field 차이가 0건이면 (마이그레이션 자동 키 추가/제거 같은 노이즈) "메타 변경" 행을 숨김 — _expandBrandAppProductsHistoryRow 호출처 처리
var BRAND_APP_PRODUCT_SUBFIELDS = [
  {key: 'recruit_fee_krw',  label: '모집비(건)',    fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(fmtKrw(Number(v))); }},
  {key: 'transfer_fee_krw', label: '이체수수료(건)', fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(fmtKrw(Number(v))); }},
  {key: 'qty',              label: '수량',          fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(Number(v).toLocaleString('ja-JP')); }},
  {key: 'price',            label: '상품 가격(엔)', fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc('¥ ' + Number(v).toLocaleString('ja-JP')); }},
  {key: 'price_check',      label: '가격체크',      fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(priceCheckKo(String(v))); }},
  {key: 'name',             label: '제품명',        fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(String(v)); }},
  {key: 'name_ja',          label: '제품명(일본어)', fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(String(v)); }},
  {key: 'url',              label: 'URL',          fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(String(v)); }},
  {key: 'category',         label: '카테고리',      fmt: function(v){ return v == null || v === '' ? '<span style="color:var(--muted)">—</span>' : esc(String(v)); }}
];

function _expandBrandAppProductsHistoryRow(h) {
  var oldArr = Array.isArray(h.old_value) ? h.old_value : [];
  var newArr = Array.isArray(h.new_value) ? h.new_value : [];
  var maxLen = Math.max(oldArr.length, newArr.length);
  var virtualRows = [];
  for (var i = 0; i < maxLen; i++) {
    var oldP = oldArr[i] || {};
    var newP = newArr[i] || {};
    var pname = newP.name || oldP.name || ('제품 ' + (i + 1));
    BRAND_APP_PRODUCT_SUBFIELDS.forEach(function(sf){
      var ov = oldP[sf.key];
      var nv = newP[sf.key];
      // null/undefined 동등 처리
      var ovNorm = (ov === undefined ? null : ov);
      var nvNorm = (nv === undefined ? null : nv);
      if (JSON.stringify(ovNorm) !== JSON.stringify(nvNorm)) {
        virtualRows.push({
          changed_at: h.changed_at,
          changed_by_name: h.changed_by_name,
          _productLabel: pname,
          _fieldLabel: sf.label,
          _oldHtml: sf.fmt(ovNorm),
          _newHtml: sf.fmt(nvNorm)
        });
      }
    });
    // 모든 sub-field 동일하면 (메타만 다른 경우) 가상 row 생성 안 함
  }
  return virtualRows;
}

function renderBrandAppHistoryTableHtml(historyArr) {
  if (!historyArr || historyArr.length === 0) {
    return '<div style="padding:32px;text-align:center;color:var(--muted);font-size:13px">변경 이력이 없습니다</div>';
  }
  // products 변경 row는 제품별 sub-field 가상 row로 펼치기
  var rows = [];
  historyArr.forEach(function(h){
    if (h.field_name === 'products') {
      var expanded = _expandBrandAppProductsHistoryRow(h);
      // sub-field 화이트리스트 기준 차이가 0건이면 — 마이그레이션 자동 키 추가/제거 또는
      // 추적 안 하는 필드 변경 (예: admin_memo 키, jsonb 키 순서). 노이즈라 행 자체 숨김
      if (expanded.length > 0) {
        rows = rows.concat(expanded);
      }
    } else if (h.field_name === 'memo_added' || h.field_name === 'memo_edited' || h.field_name === 'memo_deleted') {
      // 메모 변경 — product_idx 가 있으면 [제품 N] productName 표시 (migration 123 이후)
      var memoVal = h.new_value || h.old_value || {};
      var pIdx = (memoVal && typeof memoVal.product_idx === 'number') ? memoVal.product_idx : null;
      var labelHtml;
      if (pIdx === null) {
        labelHtml = '<span style="color:var(--muted)">공통</span>';
      } else {
        var cur = _findBrandApp(h.application_id);
        var prods = cur && Array.isArray(cur.products) ? cur.products : [];
        var pname = (prods[pIdx] && prods[pIdx].name) ? prods[pIdx].name : '';
        labelHtml = '<span style="font-weight:500">[제품 ' + (pIdx + 1) + ']</span>' + (pname ? ' <span style="color:var(--muted);font-size:11px">' + esc(pname) + '</span>' : '');
      }
      rows.push({
        changed_at: h.changed_at,
        changed_by_name: h.changed_by_name,
        _productLabel: labelHtml,
        _fieldLabel: _brandAppHistoryFieldLabel(h.field_name),
        _oldHtml: _brandAppHistoryFormatValue(h.field_name, h.old_value),
        _newHtml: _brandAppHistoryFormatValue(h.field_name, h.new_value)
      });
    } else {
      rows.push({
        changed_at: h.changed_at,
        changed_by_name: h.changed_by_name,
        _productLabel: '<span style="color:var(--muted)">공통</span>',
        _fieldLabel: _brandAppHistoryFieldLabel(h.field_name),
        _oldHtml: _brandAppHistoryFormatValue(h.field_name, h.old_value),
        _newHtml: _brandAppHistoryFormatValue(h.field_name, h.new_value)
      });
    }
  });

  return '<table style="width:100%;font-size:12px;border-collapse:collapse">'
    + '<thead><tr style="background:var(--surface-dim);color:var(--muted);font-weight:600">'
      + '<th style="text-align:left;padding:8px 10px;width:140px">시간</th>'
      + '<th style="text-align:left;padding:8px 10px;width:80px">담당</th>'
      + '<th style="text-align:left;padding:8px 10px;width:130px">제품</th>'
      + '<th style="text-align:left;padding:8px 10px;width:110px">필드</th>'
      + '<th style="text-align:left;padding:8px 10px;min-width:240px">변경 전</th>'
      + '<th style="text-align:left;padding:8px 10px;min-width:240px">변경 후</th>'
    + '</tr></thead>'
    + '<tbody>'
    + rows.map(function(r){
      var when = r.changed_at ? new Date(r.changed_at).toLocaleString('ko-KR', {timeZone:'Asia/Seoul'}) : '—';
      var who  = esc(r.changed_by_name || '시스템');
      // _productLabel 은 esc 처리된 텍스트 또는 raw HTML(공통 wrap). 단순 텍스트면 esc, "공통" wrap 은 그대로
      var prodCell = (typeof r._productLabel === 'string' && r._productLabel.indexOf('<') === 0) ? r._productLabel : esc(r._productLabel || '—');
      return '<tr style="border-top:1px solid var(--surface-dim)">'
        + '<td style="padding:8px 10px;color:var(--muted);white-space:nowrap">' + esc(when) + '</td>'
        + '<td style="padding:8px 10px">' + who + '</td>'
        + '<td style="padding:8px 10px;font-weight:500;word-break:break-word">' + prodCell + '</td>'
        + '<td style="padding:8px 10px;font-weight:600">' + esc(r._fieldLabel) + '</td>'
        + '<td style="padding:8px 10px;color:var(--muted);vertical-align:top;word-break:break-word">' + r._oldHtml + '</td>'
        + '<td style="padding:8px 10px;color:var(--ink);font-weight:600;vertical-align:top;word-break:break-word">' + r._newHtml + '</td>'
      + '</tr>';
    }).join('')
    + '</tbody></table>';
}

// 대시보드 최근 신청 카드 — 신청 페인으로 이동 (이력은 별도 "이력" 버튼으로)
function openBrandAppFromDashboard(id) {
  if (typeof switchAdminPane === 'function') switchAdminPane('brand-applications', null);
}

// 일정 셀용 짧은 날짜 포맷 ("2026/5/1") — 표 폭 절약
function fmtDateShort(d) {
  if (!d) return '';
  var dt = (d instanceof Date) ? d : new Date(d);
  if (isNaN(dt.getTime())) return String(d);
  return dt.getFullYear() + '/' + (dt.getMonth() + 1) + '/' + dt.getDate();
}

// 모집기간·배송기간 셀 (range) — display + ✎ 인라인 편집
function renderDateRangeDisplay(start, end) {
  if (!start && !end) {
    return '<div class="dr-display" style="font-size:11px;color:var(--muted);padding-right:22px">—</div>'
      + '<button type="button" class="dr-edit-btn" onclick="enterDateRangeEdit(this)" title="기간 입력" style="position:absolute;top:0;right:0;background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit_calendar</span></button>';
  }
  var s = start ? fmtDateShort(start) : '?';
  var e = end ? fmtDateShort(end) : '?';
  return '<div class="dr-display" style="font-size:11px;color:var(--ink);font-variant-numeric:tabular-nums;padding-right:22px;line-height:1.4">' + esc(s) + ' ~ ' + esc(e) + '</div>'
    + '<button type="button" class="dr-edit-btn" onclick="enterDateRangeEdit(this)" title="기간 수정" style="position:absolute;top:0;right:0;background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit_calendar</span></button>';
}

// 선정날짜·결과물 제출 마감일 셀 (single) — display + ✎ 인라인 편집
function renderDateSingleDisplay(date) {
  var hasValue = !!date;
  var display = hasValue
    ? '<div class="ds-display" style="font-size:11px;color:var(--ink);font-variant-numeric:tabular-nums;padding-right:22px;line-height:1.4">' + esc(fmtDateShort(date)) + '</div>'
    : '<div class="ds-display" style="font-size:11px;color:var(--muted);padding-right:22px">—</div>';
  return display
    + '<button type="button" class="ds-edit-btn" onclick="enterDateSingleEdit(this)" title="' + (hasValue ? '날짜 수정' : '날짜 입력') + '" style="position:absolute;top:0;right:0;background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit_calendar</span></button>';
}

// 일정 인라인 편집 — 4종 셀 통합 매핑
var DATE_CELL_CONFIG = {
  'brand-app-rperiod-cell':    {kind: 'range',  startKey: 'recruit_start',  endKey: 'recruit_end',   label: '모집기간'},
  'brand-app-dperiod-cell':    {kind: 'range',  startKey: 'delivery_start', endKey: 'delivery_end',  label: '배송 기간'},
  'brand-app-seldate-cell':    {kind: 'single', dateKey: 'selection_date',                            label: '선정날짜'},
  'brand-app-subdeadline-cell':{kind: 'single', dateKey: 'submission_deadline',                       label: '결과물 제출 마감일'}
};

function _findDateCell(anyChildEl) {
  for (var cls in DATE_CELL_CONFIG) {
    var cell = anyChildEl.closest('.' + cls);
    if (cell) return {cell: cell, cfg: DATE_CELL_CONFIG[cls]};
  }
  return null;
}

function _restoreDateDisplay(cell, cfg, p) {
  if (cfg.kind === 'range') {
    cell.innerHTML = renderDateRangeDisplay(p && p[cfg.startKey], p && p[cfg.endKey]);
  } else {
    cell.innerHTML = renderDateSingleDisplay(p && p[cfg.dateKey]);
  }
}

function enterDateRangeEdit(btnEl) {
  if (typeof flatpickr === 'undefined') { toast('flatpickr 라이브러리 로드 실패', 'error'); return; }
  var found = _findDateCell(btnEl);
  if (!found) return;
  var cell = found.cell, cfg = found.cfg;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var p = cur.products[idx];
  var startVal = p[cfg.startKey] || '';
  var endVal = p[cfg.endKey] || '';

  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<input type="text" class="dr-edit-input" placeholder="시작 ~ 종료" readonly style="width:100%;font-size:11px;padding:3px 6px;border:1px solid var(--pink);border-radius:4px;background:#fff;cursor:pointer">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelDateEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmDateRangeEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
  var input = cell.querySelector('.dr-edit-input');
  if (!input) return;
  var defaults = (startVal && endVal) ? [startVal, endVal] : (startVal ? [startVal] : []);
  cell._fp = flatpickr(input, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    defaultDate: defaults,
    allowInput: false,
    disableMobile: true,
  });
  setTimeout(function(){ if (cell._fp) cell._fp.open(); }, 50);
}

function enterDateSingleEdit(btnEl) {
  if (typeof flatpickr === 'undefined') { toast('flatpickr 라이브러리 로드 실패', 'error'); return; }
  var found = _findDateCell(btnEl);
  if (!found) return;
  var cell = found.cell, cfg = found.cfg;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var p = cur.products[idx];
  var val = p[cfg.dateKey] || '';

  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<input type="text" class="ds-edit-input" placeholder="날짜 선택" readonly style="width:100%;font-size:11px;padding:3px 6px;border:1px solid var(--pink);border-radius:4px;background:#fff;cursor:pointer">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelDateEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmDateSingleEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
  var input = cell.querySelector('.ds-edit-input');
  if (!input) return;
  cell._fp = flatpickr(input, {
    mode: 'single',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    defaultDate: val || null,
    allowInput: false,
    disableMobile: true,
  });
  setTimeout(function(){ if (cell._fp) cell._fp.open(); }, 50);
}

function cancelDateEdit(anyChildEl) {
  var found = _findDateCell(anyChildEl);
  if (!found) return;
  var cell = found.cell, cfg = found.cfg;
  if (cell._fp) { cell._fp.destroy(); cell._fp = null; }
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !cur.products || !cur.products[idx]) return;
  _restoreDateDisplay(cell, cfg, cur.products[idx]);
}

async function confirmDateRangeEdit(anyChildEl) {
  var found = _findDateCell(anyChildEl);
  if (!found) return;
  var cell = found.cell;
  var picked = cell._fp ? cell._fp.selectedDates : [];
  if (picked.length === 0) {
    // 둘 다 비우기로 간주
    await _saveDateEdit(anyChildEl, null, null);
    return;
  }
  if (picked.length === 1) {
    toast('시작일과 종료일을 모두 선택해주세요. (또는 종료일을 시작일과 같이 선택)', 'warn');
    return;
  }
  var fmt = function(d) {
    var y = d.getFullYear();
    var m = String(d.getMonth() + 1).padStart(2, '0');
    var dd = String(d.getDate()).padStart(2, '0');
    return y + '-' + m + '-' + dd;
  };
  await _saveDateEdit(anyChildEl, fmt(picked[0]), fmt(picked[1]));
}

async function confirmDateSingleEdit(anyChildEl) {
  var found = _findDateCell(anyChildEl);
  if (!found) return;
  var cell = found.cell;
  var picked = cell._fp ? cell._fp.selectedDates : [];
  if (picked.length === 0) {
    await _saveDateEdit(anyChildEl, null, null);
    return;
  }
  var d = picked[0];
  var y = d.getFullYear();
  var m = String(d.getMonth() + 1).padStart(2, '0');
  var dd = String(d.getDate()).padStart(2, '0');
  await _saveDateEdit(anyChildEl, y + '-' + m + '-' + dd, null);
}

async function _saveDateEdit(anyChildEl, primaryVal, endVal) {
  var found = _findDateCell(anyChildEl);
  if (!found) return;
  var cell = found.cell, cfg = found.cfg;
  if (cell._fp) { cell._fp.destroy(); cell._fp = null; }
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;

  var nextProducts = cur.products.map(function(prod, i) {
    if (i !== idx) return prod;
    var copy = Object.assign({}, prod);
    if (cfg.kind === 'range') {
      if (primaryVal == null) { delete copy[cfg.startKey]; delete copy[cfg.endKey]; }
      else { copy[cfg.startKey] = primaryVal; copy[cfg.endKey] = endVal; }
    } else {
      if (primaryVal == null) delete copy[cfg.dateKey];
      else copy[cfg.dateKey] = primaryVal;
    }
    return copy;
  });
  var prevVersion = cur.version;
  var saveBtn = cell.querySelector('button[onclick^="confirm"]');
  if (saveBtn) saveBtn.disabled = true;
  var result = await updateBrandApplication(id, {products: nextProducts}, prevVersion);
  if (result.conflict) {
    if (saveBtn) saveBtn.disabled = false;
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    if (saveBtn) saveBtn.disabled = false;
    return;
  }
  cur.products = nextProducts;
  _syncBrandAppCur(cur, result, prevVersion);
  _refreshBrandAppHistoryButton(id);
  // 해당 셀만 재렌더 — 같은 페이지에서 편집 중인 다른 셀들의 입력 상태가 사라지지 않도록 전체 재렌더 회피
  _restoreDateDisplay(cell, cfg, nextProducts[idx]);
  toast(cfg.label + ' 저장 완료');
}

// 이체수수료(건) 셀 — display + ✎ 인라인 편집
function renderTransferFeeDisplay(value) {
  var hasValue = value != null && isFinite(value);
  var display = hasValue ? fmtKrw(value) : '<span style="color:var(--muted)">—</span>';
  return '<div class="tfee-display" style="text-align:right;font-variant-numeric:tabular-nums;font-size:12px;padding-right:22px">' + display + '</div>'
    + '<button type="button" class="tfee-edit-btn" onclick="enterTransferFeeEdit(this)" title="이체수수료(건) 수정" style="position:absolute;top:0;right:0;background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px" onmouseover="this.style.background=\'rgba(0,0,0,.05)\'" onmouseout="this.style.background=\'none\'"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit</span></button>';
}

function _restoreTransferFeeDisplay(cell, value) {
  cell.innerHTML = renderTransferFeeDisplay(value);
}

function enterTransferFeeEdit(btnEl) {
  var cell = btnEl.closest('.brand-app-tfee-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var p = cur.products[idx];
  var original = (p.transfer_fee_krw == null || p.transfer_fee_krw === '') ? '' : String(p.transfer_fee_krw);
  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<input type="number" class="tfee-edit-input" value="' + esc(original) + '" placeholder="0" min="0" step="1" onkeydown="handleTransferFeeEditKey(event, this)" style="width:100%;font-size:11px;padding:3px 6px;border:1px solid var(--pink);border-radius:4px;text-align:right;font-variant-numeric:tabular-nums">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelTransferFeeEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmTransferFeeEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
  var input = cell.querySelector('.tfee-edit-input');
  if (input) { input.focus(); input.select(); }
}

function handleTransferFeeEditKey(ev, inputEl) {
  if (ev.key === 'Escape') { ev.preventDefault(); cancelTransferFeeEdit(inputEl); }
  else if (ev.key === 'Enter') { ev.preventDefault(); confirmTransferFeeEdit(inputEl); }
}

function cancelTransferFeeEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-tfee-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !cur.products || !cur.products[idx]) return;
  _restoreTransferFeeDisplay(cell, cur.products[idx].transfer_fee_krw);
}

async function confirmTransferFeeEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-tfee-cell');
  if (!cell) return;
  var input = cell.querySelector('.tfee-edit-input');
  if (!input) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var raw = (input.value || '').trim();
  var nextValue = raw === '' ? null : Number(raw);
  if (nextValue !== null && (!isFinite(nextValue) || nextValue < 0)) {
    toast('0 이상의 숫자만 입력하세요.', 'warn');
    return;
  }
  var prevValue = cur.products[idx].transfer_fee_krw == null ? null : Number(cur.products[idx].transfer_fee_krw);
  if (prevValue === nextValue) {
    _restoreTransferFeeDisplay(cell, prevValue);
    return;
  }
  // 새 products 배열 생성 (immutable patch)
  var nextProducts = cur.products.map(function(prod, i) {
    if (i !== idx) return prod;
    var copy = Object.assign({}, prod);
    if (nextValue == null) delete copy.transfer_fee_krw; else copy.transfer_fee_krw = nextValue;
    return copy;
  });
  var prevVersion = cur.version;
  input.disabled = true;
  var result = await updateBrandApplication(id, {products: nextProducts}, prevVersion);
  input.disabled = false;
  if (result.conflict) {
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  cur.products = nextProducts;
  _syncBrandAppCur(cur, result, prevVersion);
  _refreshBrandAppHistoryButton(id);
  // 같은 신청의 모든 행 재렌더(이체수수료(원)/최종 견적/VAT포함 컬럼이 동기화됨)
  renderBrandApplicationsList();
  toast('이체수수료가 저장되었습니다.');
}

// 모집비 셀 — display + ✎ 인라인 편집 (이체수수료 패턴 미러링)
function renderRecruitFeeDisplay(value) {
  var hasValue = value != null && isFinite(value);
  var display = hasValue ? fmtKrw(value) : '<span style="color:var(--muted)">—</span>';
  return '<div class="rfee-display" style="text-align:right;font-variant-numeric:tabular-nums;font-size:12px;padding-right:22px">' + display + '</div>'
    + '<button type="button" class="rfee-edit-btn" onclick="enterRecruitFeeEdit(this)" title="모집비(단가) 수정" style="position:absolute;top:0;right:0;background:none;border:none;cursor:pointer;padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px" onmouseover="this.style.background=\'rgba(0,0,0,.05)\'" onmouseout="this.style.background=\'none\'"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit</span></button>';
}

function _restoreRecruitFeeDisplay(cell, value) {
  cell.innerHTML = renderRecruitFeeDisplay(value);
}

function enterRecruitFeeEdit(btnEl) {
  var cell = btnEl.closest('.brand-app-rfee-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var p = cur.products[idx];
  var original = (p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? '' : String(p.recruit_fee_krw);
  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<input type="number" class="rfee-edit-input" value="' + esc(original) + '" placeholder="0" min="0" step="1" onkeydown="handleRecruitFeeEditKey(event, this)" style="width:100%;font-size:11px;padding:3px 6px;border:1px solid var(--pink);border-radius:4px;text-align:right;font-variant-numeric:tabular-nums">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelRecruitFeeEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmRecruitFeeEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
  var input = cell.querySelector('.rfee-edit-input');
  if (input) { input.focus(); input.select(); }
}

function handleRecruitFeeEditKey(ev, inputEl) {
  if (ev.key === 'Escape') { ev.preventDefault(); cancelRecruitFeeEdit(inputEl); }
  else if (ev.key === 'Enter') { ev.preventDefault(); confirmRecruitFeeEdit(inputEl); }
}

function cancelRecruitFeeEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-rfee-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !cur.products || !cur.products[idx]) return;
  _restoreRecruitFeeDisplay(cell, cur.products[idx].recruit_fee_krw);
}

async function confirmRecruitFeeEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-rfee-cell');
  if (!cell) return;
  var input = cell.querySelector('.rfee-edit-input');
  if (!input) return;
  var id = cell.dataset.id;
  var idx = Number(cell.dataset.productIdx);
  var cur = _findBrandApp(id);
  if (!cur || !Array.isArray(cur.products) || !cur.products[idx]) return;
  var raw = (input.value || '').trim();
  var nextValue = raw === '' ? null : Number(raw);
  if (nextValue !== null && (!isFinite(nextValue) || nextValue < 0)) {
    toast('0 이상의 숫자만 입력하세요.', 'warn');
    return;
  }
  var prevValue = cur.products[idx].recruit_fee_krw == null ? null : Number(cur.products[idx].recruit_fee_krw);
  if (prevValue === nextValue) {
    _restoreRecruitFeeDisplay(cell, prevValue);
    return;
  }
  // 새 products 배열 생성 (immutable patch)
  var nextProducts = cur.products.map(function(prod, i) {
    if (i !== idx) return prod;
    var copy = Object.assign({}, prod);
    if (nextValue == null) delete copy.recruit_fee_krw; else copy.recruit_fee_krw = nextValue;
    return copy;
  });
  var prevVersion = cur.version;
  input.disabled = true;
  var result = await updateBrandApplication(id, {products: nextProducts}, prevVersion);
  input.disabled = false;
  if (result.conflict) {
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  cur.products = nextProducts;
  _syncBrandAppCur(cur, result, prevVersion);
  _refreshBrandAppHistoryButton(id);
  // 같은 신청의 모든 행 재렌더(모집비/최종 견적/VAT포함 컬럼이 동기화됨)
  renderBrandApplicationsList();
  toast('모집비가 저장되었습니다.');
}

function renderQuoteSentDisplay(isoOrNull, urlOrNull, locked) {
  var hasValue = !!isoOrNull;
  var safeUrl = safeBrandUrl(urlOrNull);
  var urlIcon = safeUrl
    ? ' <a href="' + esc(safeUrl) + '" target="_blank" rel="noopener noreferrer" onclick="event.stopPropagation()" title="견적서 열기" style="color:var(--pink);vertical-align:middle;display:inline-flex;align-items:center">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:13px">open_in_new</span></a>'
    : '';
  var content = hasValue
    ? '<span style="display:inline-flex;align-items:center;gap:4px;color:#16a34a;font-size:11px;font-weight:600"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>전달' + urlIcon + '</span>'
      + '<div style="font-size:10px;color:var(--muted);margin-top:2px">' + fmtDate(isoOrNull) + '</div>'
    : '<span style="color:var(--muted);font-size:11px">미전달</span>';
  return content
    + '<button type="button" class="qsent-edit-btn" ' + (locked ? 'disabled' : '') + ' onclick="enterQuoteSentEdit(this)" title="' + (locked ? '완료/거절 신청은 수정 불가' : '견적서 전달 수정') + '" style="position:absolute;top:0;right:0;background:none;border:none;cursor:' + (locked ? 'not-allowed' : 'pointer') + ';padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px" onmouseover="if(!this.disabled)this.style.background=\'rgba(0,0,0,.05)\'" onmouseout="this.style.background=\'none\'"><span class="material-icons-round notranslate" translate="no" style="font-size:15px">edit</span></button>';
}

function _restoreQuoteSentDisplay(cell, isoOrNull, urlOrNull, locked) {
  cell.innerHTML = renderQuoteSentDisplay(isoOrNull, urlOrNull, locked);
}

function enterQuoteSentEdit(btnEl) {
  var cell = btnEl.closest('.brand-app-qsent-cell');
  if (!cell) return;
  var cur = _findBrandApp(cell.dataset.id);
  if (!cur) return;
  var hasValue = !!cur.quote_sent_at;
  var dateValue = hasValue ? new Date(cur.quote_sent_at).toISOString().slice(0,10) : new Date().toISOString().slice(0,10);
  var urlValue = esc(cur.quote_sent_url || '');
  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<label style="display:inline-flex;align-items:center;gap:5px;font-size:11px;cursor:pointer">'
      + '<input type="checkbox" class="qsent-edit-cb" ' + (hasValue ? 'checked' : '') + ' onchange="syncQsentEditDate(this)">'
      + '<span>전달 완료</span>'
    + '</label>'
    + '<input type="date" class="qsent-edit-date" value="' + dateValue + '" ' + (hasValue ? '' : 'disabled') + ' style="font-size:11px;padding:2px 4px;border:1px solid var(--line);border-radius:4px;width:100%;background:' + (hasValue ? '#fff' : '#F5F5F5') + '">'
    + '<input type="url" class="qsent-edit-url" value="' + urlValue + '" placeholder="https://" style="font-size:11px;padding:2px 4px;border:1px solid var(--line);border-radius:4px;width:100%">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelQuoteSentEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmQuoteSentEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
}

function syncQsentEditDate(cb) {
  var cell = cb.closest('.brand-app-qsent-cell');
  if (!cell) return;
  var dateInput = cell.querySelector('.qsent-edit-date');
  if (!dateInput) return;
  dateInput.disabled = !cb.checked;
  dateInput.style.background = cb.checked ? '#fff' : '#F5F5F5';
  if (cb.checked && !dateInput.value) {
    dateInput.value = new Date().toISOString().slice(0,10);
  }
}

function cancelQuoteSentEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-qsent-cell');
  if (!cell) return;
  var cur = _findBrandApp(cell.dataset.id);
  var locked = cur && (cur.status === 'done' || cur.status === 'rejected');
  _restoreQuoteSentDisplay(cell, cur?.quote_sent_at || null, cur?.quote_sent_url || null, !!locked);
}

async function confirmQuoteSentEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-qsent-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var cur = _findBrandApp(id);
  if (!cur) return;
  var cb = cell.querySelector('.qsent-edit-cb');
  var dateInput = cell.querySelector('.qsent-edit-date');
  var urlInput = cell.querySelector('.qsent-edit-url');
  if (!cb || !dateInput) return;
  var nextDate = null;
  if (cb.checked) {
    var raw = dateInput.value;
    if (!raw) { toast('날짜를 선택하세요.', 'warn'); return; }
    nextDate = new Date(raw + 'T12:00:00+09:00').toISOString();
  }
  var rawUrl = urlInput ? urlInput.value.trim() : '';
  var nextUrl = normalizeBrandUrlInput(rawUrl);
  if (rawUrl && !nextUrl) { toast('URL 형식이 올바르지 않습니다.', 'warn'); return; }
  var prevDate = cur.quote_sent_at;
  var prevUrl = cur.quote_sent_url || null;
  var prevDateStr = prevDate ? new Date(prevDate).toISOString().slice(0,10) : null;
  var nextDateStr = nextDate ? new Date(nextDate).toISOString().slice(0,10) : null;
  if (prevDateStr === nextDateStr && prevUrl === nextUrl) {
    _restoreQuoteSentDisplay(cell, prevDate, prevUrl, false);
    return;
  }
  var prevVersion = cur.version;
  cb.disabled = true; dateInput.disabled = true; if (urlInput) urlInput.disabled = true;
  var result = await updateBrandApplication(id, {quote_sent_at: nextDate, quote_sent_url: nextUrl}, prevVersion);
  cb.disabled = false; dateInput.disabled = false; if (urlInput) urlInput.disabled = false;
  if (result.conflict) {
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  cur.quote_sent_at = nextDate;
  cur.quote_sent_url = nextUrl;
  _syncBrandAppCur(cur, result, prevVersion);
  _restoreQuoteSentDisplay(cell, nextDate, nextUrl, false);
  _refreshBrandAppHistoryButton(id);
  toast(nextDate ? '견적서 전달 정보가 저장되었습니다.' : '견적서 미전달로 변경했습니다.');
}

// (구글시트 오리엔시트 URL 인라인 표시·편집 함수 제거 — 2026-06-22 더보기 「구글시트 URL 등록」 모달로 대체.
//  표시는 renderGoogleSheetLinkOnly(열기 링크만), 입력은 osOpenGoogleSheetUrlModal)

// ─── 입금 날짜 셀 (migration 126) ────────────────────────────────────────────
function renderPaidAtDisplay(isoOrNull, locked) {
  var hasValue = !!isoOrNull;
  var content = hasValue
    ? '<span style="font-size:11px;color:var(--ink);font-variant-numeric:tabular-nums">' + esc(fmtDate(isoOrNull)) + '</span>'
    : '<span style="color:var(--muted);font-size:11px">—</span>';
  return content
    + '<button type="button" class="paid-at-edit-btn" ' + (locked ? 'disabled' : '') + ' onclick="enterPaidAtEdit(this)" title="' + (locked ? '완료/거절 신청은 수정 불가' : '입금 날짜 수정') + '" style="position:absolute;top:50%;right:0;transform:translateY(-50%);background:none;border:none;cursor:' + (locked ? 'not-allowed' : 'pointer') + ';padding:2px;color:var(--muted);display:flex;align-items:center;justify-content:center;border-radius:3px" onmouseover="if(!this.disabled)this.style.background=\'rgba(0,0,0,.05)\'" onmouseout="this.style.background=\'none\'"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">edit</span></button>';
}

function _restorePaidAtDisplay(cell, isoOrNull, locked) {
  cell.innerHTML = renderPaidAtDisplay(isoOrNull, locked);
}

// ─── 입금 정보 셀 (해당 제품의 4종 체크 + 새로고침) ────────────────────────────
//   migration 117: products[i].payment_flags 구조.
//   테이블은 제품 행 단위로 렌더되므로 셀 1개 = 해당 제품 1개의 플래그만 표시.
//   - 무료모집 OFF: 4종 모두 표시
//   - 무료모집 ON : 무료모집만 표시 (다른 3종 숨김 — DB 값 보존)
//   - 새로고침: 해당 신청의 모든 제품 4종 완전 초기화 (free=false 포함)
function renderBrandAppPaymentFlagsCell(a, productIdx) {
  var products = (a && a.products) || [];
  var p = products[productIdx];

  if (!p) return '<span style="color:#bbb;font-size:10px">—</span>';

  var flags  = (p.payment_flags) || {};
  var isFree = !!flags.free;

  var ROWS = [
    {key: 'recruit',  label: '모집비용'},
    {key: 'product',  label: '상품비용'},
    {key: 'transfer', label: '이체수수료'},
    {key: 'free',     label: '무료모집'}
  ];

  var rowsHtml = ROWS.map(function(r) {
    if (isFree && r.key !== 'free') return '';
    var checked = !!flags[r.key];
    var cls = 'pay-row' + (checked ? ' is-checked' : '') + ' pay-' + r.key;
    return '<div class="' + cls + '" onclick="event.stopPropagation();toggleBrandAppProductPaymentFlag(\'' + esc(a.id) + '\',' + productIdx + ',\'' + r.key + '\')" title="클릭하여 ' + (checked ? '체크 해제' : '체크') + '">'
      + '<span class="pay-row-label">' + r.label + '</span>'
      + (checked ? '<span class="material-icons-round notranslate pay-row-check" translate="no">check</span>' : '')
    + '</div>';
  }).join('');

  return '<div class="pay-cell-inner">'
    + '<div class="pay-rows-wrap">' + rowsHtml + '</div>'
    + '<button type="button" class="pay-refresh-btn" onclick="event.stopPropagation();refreshBrandAppPaymentFlags(\'' + esc(a.id) + '\',this)" title="전체 제품 자동 체크 초기화"><span class="material-icons-round notranslate" translate="no">refresh</span></button>'
  + '</div>';
}

// 제품별 칩 클릭 시 해당 제품·key 토글 + DB 갱신. 낙관적 락 충돌 시 토스트.
async function toggleBrandAppProductPaymentFlag(applicationId, productIndex, flagKey) {
  var cur = _findBrandApp(applicationId);
  if (!cur || !Array.isArray(cur.products)) return;

  var oldProducts = cur.products;
  var newProducts = oldProducts.map(function(p, i) {
    if (i !== productIndex) return p;
    var pFlags = Object.assign({}, p.payment_flags || {});
    pFlags[flagKey] = !pFlags[flagKey];
    return Object.assign({}, p, {payment_flags: pFlags});
  });

  // 낙관적 UI 갱신
  cur.products = newProducts;
  _rerenderBrandAppPaymentCell(applicationId);

  var res = await updateBrandApplication(applicationId, {products: newProducts}, cur.version);
  if (res && res.conflict) {
    cur.products = oldProducts;
    _rerenderBrandAppPaymentCell(applicationId);
    toast('이미 다른 곳에서 변경됐습니다. 새로고침 후 다시 시도하세요', 'error');
    return;
  }
  if (!res || !res.ok) {
    cur.products = oldProducts;
    _rerenderBrandAppPaymentCell(applicationId);
    toast('입금 정보 저장 실패: ' + ((res && res.error) || 'unknown'), 'error');
    return;
  }
  // 서버 반환값으로 version·products 동기화 (트리거로 recruit/product/transfer 재계산)
  if (res.data) {
    if (typeof res.data.version === 'number') cur.version = res.data.version;
    if (res.data.products != null) cur.products = res.data.products;
  }
  _rerenderBrandAppPaymentCell(applicationId);
}

// 새로고침 아이콘 클릭 — RPC refresh_brand_app_product_payment_flags 호출.
// 모든 제품 4종(recruit/product/transfer/free) 완전 초기화.
async function refreshBrandAppPaymentFlags(applicationId, btnEl) {
  if (btnEl && btnEl.disabled) return;
  if (btnEl) btnEl.disabled = true;
  try {
    var res = await refreshBrandAppProductPaymentFlags(applicationId);
    if (!res || !res.ok) {
      toast('자동 체크 실패: ' + ((res && res.error) || 'unknown'), 'error');
      return;
    }
    var cur = _findBrandApp(applicationId);
    if (cur) {
      cur.products = res.products;
      _rerenderBrandAppPaymentCell(applicationId);
    }
    toast('입금 정보를 자동 갱신했습니다', 'success');
  } finally {
    if (btnEl) btnEl.disabled = false;
  }
}

// 메모리 캐시(_brandApps) 갱신 후 해당 신청의 모든 입금 정보 셀 다시 렌더
// 제품별 행이 여러 개이므로 querySelectorAll로 전체 업데이트
function _rerenderBrandAppPaymentCell(applicationId) {
  var cur = _findBrandApp(applicationId);
  if (!cur) return;
  var cells = document.querySelectorAll('.brand-app-pay-cell[data-id="' + applicationId + '"]');
  cells.forEach(function(cell) {
    var idx = parseInt(cell.getAttribute('data-product-idx'), 10) || 0;
    cell.innerHTML = renderBrandAppPaymentFlagsCell(cur, idx);
  });
}

// ─── 가격체크 셀 (제품별 4상태 드롭다운) ────────────────────────────
//   products[i].price_check : 'higher' | 'lower' | 'equal' | null/undefined
//   마켓 등록 가격 vs 신청 금액 비교용. 관리자가 행별로 직접 선택.
//   DB 마이그레이션 없이 jsonb 키 추가만으로 동작.
var BRAND_APP_PRICECHECK_OPTS = [
  { val: '',       label: '확인 필요', cls: 'pc-empty'  },
  { val: 'higher', label: '가격높음',  cls: 'pc-higher' },
  { val: 'lower',  label: '가격낮음',  cls: 'pc-lower'  },
  { val: 'equal',  label: '가격동일',  cls: 'pc-equal'  }
];

function renderBrandAppPriceCheckCell(a, productIndex, p) {
  var val = (p && p.price_check) || '';
  var cur = BRAND_APP_PRICECHECK_OPTS.find(function(o){ return o.val === val; }) || BRAND_APP_PRICECHECK_OPTS[0];
  var optionsHtml = BRAND_APP_PRICECHECK_OPTS.map(function(o){
    return '<option value="' + o.val + '"' + (o.val === val ? ' selected' : '') + '>' + o.label + '</option>';
  }).join('');
  return '<select class="brand-app-pricecheck-select ' + cur.cls + '"'
       + ' onchange="onBrandAppPriceCheckChange(\'' + esc(a.id) + '\',' + productIndex + ',this.value)"'
       + ' onclick="event.stopPropagation()">'
       + optionsHtml
       + '</select>';
}

// 가격체크 드롭다운 변경 → products jsonb 패치 (낙관적 락)
async function onBrandAppPriceCheckChange(applicationId, productIndex, newVal) {
  var cur = _findBrandApp(applicationId);
  if (!cur || !Array.isArray(cur.products)) return;
  var oldProducts = cur.products;
  var oldVal = (oldProducts[productIndex] && oldProducts[productIndex].price_check) || null;

  var newProducts = oldProducts.slice();
  newProducts[productIndex] = Object.assign({}, newProducts[productIndex]);
  if (newVal === '') {
    delete newProducts[productIndex].price_check; // 빈 값은 키 제거 (jsonb 깔끔)
  } else {
    newProducts[productIndex].price_check = newVal;
  }

  // 낙관적 UI 갱신
  cur.products = newProducts;
  _rerenderBrandAppPriceCheckCell(applicationId, productIndex);

  var res = await updateBrandApplication(applicationId, { products: newProducts }, cur.version);
  if (res && res.conflict) {
    cur.products = oldProducts;
    _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
    toast('이미 다른 곳에서 변경됐습니다. 새로고침 후 다시 시도하세요', 'error');
    return;
  }
  if (!res || !res.ok) {
    cur.products = oldProducts;
    _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
    toast('가격체크 저장 실패: ' + ((res && res.error) || 'unknown'), 'error');
    return;
  }
  // 서버 응답으로 version·products 동기화 (트리거가 다른 키도 갱신할 수 있음)
  if (res.data) {
    if (typeof res.data.version === 'number') cur.version = res.data.version;
    if (res.data.products != null) cur.products = res.data.products;
  }
  _rerenderBrandAppPriceCheckCell(applicationId, productIndex);
  // 가격체크 변경은 입금 정보 트리거에 의해 products 전체가 갱신되므로 입금 정보 셀도 재렌더
  _rerenderBrandAppPaymentCell(applicationId);
}

function _rerenderBrandAppPriceCheckCell(applicationId, productIndex) {
  var cell = document.querySelector(
    '.brand-app-pricecheck-cell[data-id="' + applicationId + '"][data-product-idx="' + productIndex + '"]'
  );
  if (!cell) return;
  var cur = _findBrandApp(applicationId);
  if (!cur || !cur.products) return;
  cell.innerHTML = renderBrandAppPriceCheckCell(cur, productIndex, cur.products[productIndex]);
}

// ─── 구글시트 URL 등록 모달 (더보기 「구글시트 URL 등록」 — 셀 인라인 ✎ 대체) ───
function osOpenGoogleSheetUrlModal(appId) {
  var cur = _findBrandApp(appId);
  if (!cur) { toast('신청 정보를 찾을 수 없습니다. 목록을 새로고침해 주세요.'); return; }
  var existing = document.getElementById('gsUrlModal');
  if (existing) existing.remove();
  var urlVal = esc(cur.orient_sheet_sent_url || '');
  var brandLabel = esc(cur.brand_name || '');
  var html = '<div class="modal-overlay open" id="gsUrlModal" style="z-index:620">'
    + '<div class="modal" style="max-width:460px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">'
      + '<div class="modal-header"><h2 style="font-size:16px">구글시트 URL 등록</h2>'
        + '<button type="button" class="modal-close-btn" onclick="closeGsUrlModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>'
      + '<div class="modal-body" style="padding:20px;overflow-y:auto;flex:1">'
        + '<div style="font-size:12px;color:var(--muted);margin-bottom:10px">' + brandLabel + ' — 외부(구글) 시트 오리엔시트 링크를 입력하세요.</div>'
        + '<input type="url" id="gsUrlInput" value="' + urlVal + '" placeholder="https://docs.google.com/..." style="width:100%;font-size:14px;padding:9px 11px;border:1px solid var(--line);border-radius:8px;box-sizing:border-box">'
        + '<div style="font-size:11px;color:var(--muted);margin-top:6px">비우고 저장하면 등록된 URL이 제거됩니다.</div>'
      + '</div>'
      + '<div class="modal-footer"><button type="button" class="btn btn-ghost" onclick="closeGsUrlModal()">취소</button>'
        + '<button type="button" class="btn btn-primary" id="gsUrlSaveBtn" onclick="saveGoogleSheetUrl(\'' + esc(appId) + '\')">저장</button></div>'
    + '</div></div>';
  document.body.insertAdjacentHTML('beforeend', html);
  setTimeout(function(){
    var i = document.getElementById('gsUrlInput');
    if (!i) return;
    i.focus(); i.setSelectionRange(i.value.length, i.value.length);
    i.addEventListener('keydown', function(e){
      if (e.key === 'Escape') { e.preventDefault(); closeGsUrlModal(); }
      else if (e.key === 'Enter') { e.preventDefault(); saveGoogleSheetUrl(appId); }
    });
  }, 50);
}

function closeGsUrlModal() {
  var m = document.getElementById('gsUrlModal');
  if (m) m.remove();
}

async function saveGoogleSheetUrl(appId) {
  var cur = _findBrandApp(appId);
  if (!cur) return;
  var input = document.getElementById('gsUrlInput');
  if (!input) return;
  var rawUrl = input.value.trim();
  var nextUrl = normalizeBrandUrlInput(rawUrl);
  if (rawUrl && !nextUrl) { toast('URL 형식이 올바르지 않습니다.', 'warn'); return; }
  var prevUrl = cur.orient_sheet_sent_url || null;
  if (prevUrl === nextUrl) { closeGsUrlModal(); return; }
  var prevVersion = cur.version;
  var btn = document.getElementById('gsUrlSaveBtn');
  if (btn) btn.disabled = true;
  var result = await updateBrandApplication(appId, {orient_sheet_sent_url: nextUrl}, prevVersion);
  if (result.conflict) {
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    closeGsUrlModal();
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    if (btn) btn.disabled = false;
    return;
  }
  cur.orient_sheet_sent_url = nextUrl;
  _syncBrandAppCur(cur, result, prevVersion);
  _refreshBrandAppHistoryButton(appId);
  closeGsUrlModal();
  await loadBrandApplications();   // 목록 재렌더(셀 갱신) — brand-applications 는 refreshPane 미등록
  toast(nextUrl ? '구글시트 URL이 저장되었습니다.' : '구글시트 URL을 제거했습니다.');
}

// ─── 입금 날짜 셀 편집 (migration 126) ────────────────────────────────────────
function enterPaidAtEdit(btnEl) {
  var cell = btnEl.closest('.brand-app-paid-at-cell');
  if (!cell) return;
  var cur = _findBrandApp(cell.dataset.id);
  if (!cur) return;
  var hasValue = !!cur.paid_at;
  var dateValue = hasValue ? new Date(cur.paid_at).toISOString().slice(0,10) : new Date().toISOString().slice(0,10);
  cell.innerHTML = '<div style="display:flex;flex-direction:column;gap:4px">'
    + '<label style="display:inline-flex;align-items:center;gap:5px;font-size:11px;cursor:pointer">'
      + '<input type="checkbox" class="paid-at-edit-cb" ' + (hasValue ? 'checked' : '') + ' onchange="syncPaidAtEditDate(this)">'
      + '<span>입금 완료</span>'
    + '</label>'
    + '<input type="date" class="paid-at-edit-date" value="' + dateValue + '" ' + (hasValue ? '' : 'disabled') + ' style="font-size:11px;padding:2px 4px;border:1px solid var(--line);border-radius:4px;width:100%;background:' + (hasValue ? '#fff' : '#F5F5F5') + '">'
    + '<div style="display:flex;gap:4px;justify-content:flex-end">'
      + '<button type="button" onclick="cancelPaidAtEdit(this)" style="background:#fff;border:1px solid var(--line);border-radius:4px;padding:3px 8px;cursor:pointer;font-size:11px;color:var(--muted)">취소</button>'
      + '<button type="button" onclick="confirmPaidAtEdit(this)" style="background:var(--pink);color:#fff;border:none;border-radius:4px;padding:3px 10px;cursor:pointer;font-size:11px;font-weight:600">저장</button>'
    + '</div>'
  + '</div>';
}

function syncPaidAtEditDate(cb) {
  var cell = cb.closest('.brand-app-paid-at-cell');
  if (!cell) return;
  var dateInput = cell.querySelector('.paid-at-edit-date');
  if (!dateInput) return;
  dateInput.disabled = !cb.checked;
  dateInput.style.background = cb.checked ? '#fff' : '#F5F5F5';
  if (cb.checked && !dateInput.value) {
    dateInput.value = new Date().toISOString().slice(0,10);
  }
}

function cancelPaidAtEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-paid-at-cell');
  if (!cell) return;
  var cur = _findBrandApp(cell.dataset.id);
  var locked = cur && (cur.status === 'done' || cur.status === 'rejected');
  _restorePaidAtDisplay(cell, cur?.paid_at || null, !!locked);
}

async function confirmPaidAtEdit(anyChildEl) {
  var cell = anyChildEl.closest('.brand-app-paid-at-cell');
  if (!cell) return;
  var id = cell.dataset.id;
  var cur = _findBrandApp(id);
  if (!cur) return;
  var cb = cell.querySelector('.paid-at-edit-cb');
  var dateInput = cell.querySelector('.paid-at-edit-date');
  if (!cb || !dateInput) return;
  var nextDate = null;
  if (cb.checked) {
    var raw = dateInput.value;
    if (!raw) { toast('날짜를 선택하세요.', 'warn'); return; }
    nextDate = new Date(raw + 'T12:00:00+09:00').toISOString();
  }
  var prevDate = cur.paid_at;
  var prevDateStr = prevDate ? new Date(prevDate).toISOString().slice(0,10) : null;
  var nextDateStr = nextDate ? new Date(nextDate).toISOString().slice(0,10) : null;
  if (prevDateStr === nextDateStr) {
    _restorePaidAtDisplay(cell, prevDate, false);
    return;
  }
  var prevVersion = cur.version;
  cb.disabled = true; dateInput.disabled = true;
  var result = await updateBrandApplication(id, {paid_at: nextDate}, prevVersion);
  cb.disabled = false; dateInput.disabled = false;
  if (result.conflict) {
    toast('다른 관리자가 먼저 저장했습니다. 다시 불러옵니다.', 'warn');
    await loadBrandApplications();
    return;
  }
  if (!result.ok) {
    toast('저장 실패: ' + (result.error || '알 수 없는 오류'), 'error');
    return;
  }
  cur.paid_at = nextDate;
  _syncBrandAppCur(cur, result, prevVersion);
  _restorePaidAtDisplay(cell, nextDate, false);
  _refreshBrandAppHistoryButton(id);
  toast(nextDate ? '입금 날짜가 저장되었습니다.' : '입금 미완료로 변경했습니다.');
}

// [migration 123] 인라인 메모 편집 함수 6종(renderMemoDisplay/_restoreMemoDisplay/enterMemoEdit/
// handleMemoEditKey/cancelMemoEdit/confirmMemoEdit) 제거.
// 제품별 메모는 brand_application_memos 테이블 + brandAppMemoModal 모달로 통일됨.
// 셀 표시는 renderMemoCellInner → renderProductMemoDisplay → openBrandAppMemoModalFromCell 흐름.

