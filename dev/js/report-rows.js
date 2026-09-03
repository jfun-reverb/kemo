// ══════════════════════════════════════════════════════════════
// 리포트 표 행 만들기 — 관리자 화면과 브랜드 공유 화면이 **같은 원본**을 쓴다
//   · 관리자 번들: dev/build.sh 의 ADMIN_JS_FILES 에 이어 붙는다
//   · 공유 화면  : dev/build.sh 가 report.html 의 <!-- @@REPORT_ROWS_JS@@ --> 자리에 인라인한다
//   🔴 여기 판정을 고치면 두 화면이 함께 바뀐다 — 그게 이 파일이 따로 있는 이유다.
//   ⚠️ 이 파일은 esc()·toast() 같은 화면 헬퍼를 쓰지 않는다(공유 화면에는 그것들이 없다).
//   ⚠️ 인증 상태 판정 3함수는 admin-excel.js 에서 옮겨 온 것이다(2026-09-04). 이름 그대로.
// ══════════════════════════════════════════════════════════════

// monitor 채널별 review_image 상태 집합 → 대표 상태 repr (admin-deliverables 와 동일 우선순위)
//   campChannels: 캠페인 채널 코드 배열, reviewByCh: { channelCode: deliv }
function _excelMonitorResultRepr(campChannels, reviewByCh) {
  reviewByCh = reviewByCh || {};
  var channels = (campChannels || []).filter(Boolean);
  if (channels.length === 0) {
    // 채널 미등록 monitor — review_image 행이 하나라도 있으면 제출중, 없으면 none
    return Object.keys(reviewByCh).length > 0 ? 'pending' : 'none';
  }
  var states = channels.map(function(ch) { return (reviewByCh[ch] && reviewByCh[ch].status) || 'none'; });
  if (states.indexOf('rejected') !== -1) return 'rejected';
  if (states.indexOf('pending') !== -1) return 'pending';
  if (states.indexOf('none') !== -1) return 'none';
  return 'approved';
}

// gifting/visit 또는 채널 없는 monitor(receipt + 단일 result) 구조용.
//   recruitType, receipt(receipt deliv), result(post/review_image deliv)
//   campChannels·postByCh 는 시딩·방문형 채널 완성 판정용(선택 — 없으면 옛 방식으로 떨어진다).
//   ⚠️ 시딩·방문형도 **요구한 채널 전부**가 승인돼야 인증 성공이다(2026-08-10 결정, 마이그레이션 331).
//   예전에는 result(채널 무관 최신 1건)만 봐서 **하나만 승인돼도 인증성공**으로 나갔다 —
//   엑셀은 관리자가 정산을 대조하는 자리라 화면·서버와 어긋나면 안 된다.
function _excelCertStatusKo(recruitType, receipt, result, proxyPurchase, campChannels, postByCh) {
  // 검수 불필요 — 신청이 승인 후 반려·취소되면 검수 대상이 아니다 (결과물에 임베드된 신청 status 참조)
  var _as = (receipt && receipt.applications && receipt.applications.status)
         || (result && result.applications && result.applications.status) || null;
  if (_as === 'rejected' || _as === 'cancelled') return '검수 불필요';
  if (recruitType === 'monitor') {
    var hasReceipt = !!receipt;
    // 가구매(proxy_purchase): 영수증만 — 리뷰 인증샷 미요구
    if (proxyPurchase) {
      if (!hasReceipt) return '미제출';
      return receipt.status === 'approved' ? '인증성공' : '인증샷 제출중';
    }
    var hasReview = !!result;
    if (!hasReceipt && !hasReview) return '미제출';
    // 여기 도달하는 monitor 는 「채널 없는 리뷰어(레거시)」뿐(채널 있는 리뷰어는 _excelCertStatusMonitorKo 로 우회).
    // 화면 computeCertStatus 는 채널 없는 리뷰어를 result_status_repr='legacy_no_channel' 로 둬 절대 인증성공이
    // 아니다. 엑셀도 정합시켜 인증성공 대신 최대 '인증샷 제출중' 으로 표기(과대표기 방지).
    return '인증샷 제출중';
  }
  // gifting / visit — 요구한 채널 전부 승인이어야 인증성공
  var _chs = (campChannels || []).filter(Boolean);
  if (_chs.length > 0) {
    // 채널 목록이 넘어온 경우 — 리뷰어형과 같은 대표 상태 계산을 재사용(같은 모양의 판정)
    var _repr = _excelMonitorResultRepr(_chs, postByCh || {});
    if (_repr === 'approved') return '인증성공';
    if (_repr !== 'none') return '인증샷 제출중';
    return result ? '인증샷 제출중' : '미제출';
  }
  // 채널 정보가 없는 호출(옛 경로) — 최소한 인증성공으로 과대표기하지 않는다.
  //   채널이 빈 캠페인은 서버 판정에서도 인증성공이 되지 않는다(마이그레이션 331).
  if (!result) return '미제출';
  return '인증샷 제출중';
}

// monitor 다채널 구조용 (receipt + reviewByCh).
function _excelCertStatusMonitorKo(campChannels, receipt, reviewByCh, proxyPurchase) {
  // 검수 불필요 — 신청이 승인 후 반려·취소되면 검수 대상이 아니다 (결과물에 임베드된 신청 status 참조)
  var _as = (receipt && receipt.applications && receipt.applications.status) || null;
  if (!_as && reviewByCh) { for (var _k in reviewByCh) { if (reviewByCh[_k] && reviewByCh[_k].applications) { _as = reviewByCh[_k].applications.status; break; } } }
  if (_as === 'rejected' || _as === 'cancelled') return '검수 불필요';
  var hasReceipt = !!receipt;
  // 가구매(proxy_purchase): 영수증만 — 리뷰 인증샷 미요구
  if (proxyPurchase) {
    if (!hasReceipt) return '미제출';
    return receipt.status === 'approved' ? '인증성공' : '인증샷 제출중';
  }
  var hasReview = reviewByCh && Object.keys(reviewByCh).length > 0;
  if (!hasReceipt && !hasReview) return '미제출';
  var repr = _excelMonitorResultRepr(campChannels, reviewByCh);
  if (receipt && receipt.status === 'approved' && repr === 'approved') return '인증성공';
  return '인증샷 제출중';
}

// 17칸 머리글 — 사양서 16칸에 「캠페인 번호」를 더했다(2026-09-04 사용자 결정: 「ID」 자리는 캠페인 번호, 계정 ID 는 업로드 날짜 옆)
const REPORT_COLS = [
  // w = 열 너비, wrap = 줄바꿈 허용(캠페인명만). 나머지는 nowrap — 날짜·번호·상태가 두 줄로 접히면 표가 읽기 어렵다(2026-09-04 사용자 요청).
  {key:'no',                  label:'No.',              w:'46px'},
  {key:'campaign_no',         label:'캠페인 번호',       w:'110px'},
  {key:'campaign_name',       label:'캠페인명',          w:'260px', wrap:true},
  {key:'purchase_period',     label:'구매기간',          w:'185px'},
  {key:'status',              label:'상태',             w:'100px'},
  {key:'order_no',            label:'주문 번호',         w:'130px'},
  {key:'purchase_date',       label:'구매일',            w:'96px'},
  {key:'amount',              label:'구매금액',          w:'100px'},
  {key:'receipt_url',         label:'구매 영수증 (URL)',  w:'120px'},
  {key:'receipt_uploaded_at', label:'업로드 날짜',        w:'130px'},
  {key:'account_id',          label:'계정 ID',           w:'210px'},
  {key:'name_kanji',          label:'이름 (한자)',        w:'120px'},
  {key:'name_kana',           label:'이름 (일본어)',      w:'130px'},
  {key:'ch_qoo10_url',        label:'큐텐 결과물 (URL)',  w:'150px'},
  {key:'ch_qoo10_at',         label:'업로드 날짜',        w:'130px'},
  {key:'ch_cosme_url',        label:'엣코스메 결과물 (URL)', w:'150px'},
  {key:'ch_cosme_at',         label:'업로드 날짜',        w:'130px'},
];

// ══════════════════════════════════════════════════════════════
// 표 행 만들기 — 작업 6 (사양서 16칸 + 캠페인 번호 = 17칸, 2026-09-04)
//   사양서 「표 양식 (구글시트 16칸 그대로)」
//
// 한 사람 = 한 줄. 큐텐과 엣코스메가 **한 줄 안에서** 칸을 나눠 가진다.
// 맨 앞에 「구분」 열이 하나 더 붙어 화면에는 17칸이 보인다(구분 + 16).
//   구분 값: 'B' = REVERB / 'A-1'·'A-2' = 외부(작업 16에서 채운다)
// ══════════════════════════════════════════════════════════════

// 13·15번 칸이 쓰는 채널 코드.
//   ⚠️ 기준 데이터(lookup_values)의 code 를 그대로 쓴다 — 마이그레이션 157 이 심은 값.
//   🔴 이 값을 바꾸면 기준 데이터·캠페인(`campaigns.channel`)·이미 낸 결과물
//      (`deliverables.post_channel`) **세 곳을 함께** 옮겨야 한다. 하나만 바꾸면
//      문자열 비교가 깨져 결과물이 화면·인증·정산 세 곳에서 동시에 사라진다
//      (2026-07-30 @cosme 사고 — 승인된 인증샷 55건이 두 달간 안 보였다).
const REPORT_CH_QOO10 = 'qoo10';
const REPORT_CH_COSME = 'cosme';

// 결과물을 (캠페인 + 응모) 단위로 묶는다.
//
// 🔴 **그룹핑·최신 판정을 새로 쓰지 않는다.**
//    묶는 열쇠는 `campaign_id + application_id`, 최신은 **`submitted_at`** 기준 —
//    `admin-excel.js` 의 `_buildMonitorGroupSheet()` 와 **글자 그대로 같다**.
//    수정 시각(`updated_at`)을 먼저 보면 관리자가 영수증을 고친 건이 다른 행으로
//    뽑혀 **정산과 숫자가 어긋난다**(운영 실측 2026-08-07: 영수증이 여러 행 쌓인
//    응모 65건 중 36건에서 기준이 갈렸다).
function _reportGroupDeliverables(delivs) {
  const groups = new Map();
  for (const d of (delivs || [])) {
    const key = d.campaign_id + '|' + (d.application_id || ('user-' + d.user_id));
    if (!groups.has(key)) {
      groups.set(key, {
        key: key, campaign_id: d.campaign_id, application_id: d.application_id,
        user_id: d.user_id, campaign: d.campaigns || null,
        receipt: null, result: null, reviewByCh: {}, postByCh: {},
      });
    }
    const g = groups.get(key);
    if (!g.campaign && d.campaigns) g.campaign = d.campaigns;
    const subAt = d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image') {
      // ⚠️ 채널 없는 옛 인증샷은 칸에 넣을 자리가 없어 건너뛴다(엑셀도 같다).
      if (d.post_channel) {
        const prev = g.reviewByCh[d.post_channel];
        if (!prev || subAt > (prev.submitted_at || '')) g.reviewByCh[d.post_channel] = d;
      }
    } else if (d.kind === 'post') {
      if (!g.result || subAt > (g.result.submitted_at || '')) g.result = d;
      if (d.post_channel) {
        const prevP = g.postByCh[d.post_channel];
        if (!prevP || subAt > (prevP.submitted_at || '')) g.postByCh[d.post_channel] = d;
      }
    }
  }
  return [...groups.values()];
}

// 13·15번 칸 — **있는 것을 넣는다.**
//   그 채널에 리뷰 화면 사진(`review_image`)이 있으면 그 주소,
//   없고 게시물 주소(`post`)가 있으면 그것.
// ⚠️ 둘 다 있으면 **사진을 먼저** 쓴다 — 리뷰어형이 이 리포트의 주 대상이고,
//    외부(포인테일) 쪽도 전부 사진이라 형태가 맞는다.
// 🔴 그래서 `_buildMonitorGroupSheet()` 의 판정을 그대로 못 쓴다(그쪽은 `post` 를 안 본다).
// ⚠️ 무엇인지(`kind`)를 함께 돌려준다 — 한 칸에 사진과 게시물이 섞이므로,
//    화면이 「사진」·「게시물」을 작게 적지 않으면 브랜드가 읽는 표에서 그게 그대로 사고가 된다.
function _reportChannelCell(g, channel) {
  const rv = g.reviewByCh[channel];
  if (rv && rv.receipt_url) return {url: rv.receipt_url, at: rv.submitted_at || '', kind: 'photo'};
  const po = g.postByCh[channel];
  if (po && po.post_url) return {url: po.post_url, at: po.submitted_at || '', kind: 'post'};
  // 주소는 없는데 행은 있는 경우 — 날짜만이라도 남긴다(빈 줄로 보이면 안 낸 것과 구분이 안 된다)
  const any = rv || po;
  return {url: '', at: any ? (any.submitted_at || '') : '', kind: rv ? 'photo' : (po ? 'post' : '')};
}

// 캠페인의 구매 기간(4번 칸).
//   ⚠️ 리뷰어형은 `purchase_*`, 방문형은 `visit_*` 를 같은 칸에 넣는다
//      (`admin-excel.js` 의 매핑과 같다). 시딩형은 그 개념이 없어 빈다.
//   ⚠️ 날짜는 **저장된 문자열 그대로** 이어 붙인다 — `new Date()` 를 태우면
//      시간대가 끼어들어 하루가 밀린다.
function _reportPurchasePeriod(camp) {
  if (!camp) return '';
  const rt = camp.recruit_type;
  let a = '', b = '';
  if (rt === 'monitor') { a = camp.purchase_start || ''; b = camp.purchase_end || ''; }
  else if (rt === 'visit') { a = camp.visit_start || ''; b = camp.visit_end || ''; }
  if (!a && !b) return '';
  return a + ' ~ ' + b;
}

// 인증 상태(5번 칸) — 🔴 **엑셀과 같은 함수를 부른다.**
//   판정을 여기서 새로 쓰면 리포트와 「결과물 엑셀」이 서로 다른 상태를 말하게 된다.
//   (같은 판정이 이 저장소에 다섯 벌 있고, 그 때문에 이미 사고가 났다)
function _reportCertStatus(g) {
  const camp = g.campaign || {};
  const chs = (camp.channel || '').split(',').map(function(c){ return c.trim(); }).filter(Boolean);
  if (camp.recruit_type === 'monitor' && chs.length > 0) {
    return _excelCertStatusMonitorKo(chs, g.receipt, g.reviewByCh, !!camp.proxy_purchase);
  }
  return _excelCertStatusKo(camp.recruit_type, g.receipt, g.result, !!camp.proxy_purchase, chs, g.postByCh);
}

// REVERB 결과물 → 표준 행 배열.
//   delivs    : fetchDeliverablesForReport() 결과
//   camps     : 리포트에 담긴 캠페인 배열(제목·번호를 여기서 얻는다)
//   usersById : fetchInfluencersForReport() 결과 (id → 회원)
//
// ⚠️ `usersById` 가 `null`(조회 실패)이면 이름·계정 칸을 **빈칸이 아니라 '?'** 로 둔다.
//    빈칸으로 두면 「이름을 안 적은 사람」과 「못 물어본 것」이 같아 보인다.
function buildReportRows(delivs, camps, usersById) {
  const campById = new Map((camps || []).map(function(c){ return [c.id, c]; }));
  const lookupFailed = (usersById === null || usersById === undefined);
  const users = usersById || {};
  const groups = _reportGroupDeliverables(delivs);

  // 정렬 — 캠페인 번호 → 이름. 엑셀(`_buildMonitorGroupSheet`)과 같은 차례.
  groups.sort(function(a, b) {
    const ca = ((campById.get(a.campaign_id) || a.campaign || {}).campaign_no || '').toString();
    const cb = ((campById.get(b.campaign_id) || b.campaign || {}).campaign_no || '').toString();
    if (ca !== cb) return ca.localeCompare(cb, 'ja');
    const ua = users[a.user_id] || {}, ub = users[b.user_id] || {};
    return (ua.name_kana || ua.name || '').localeCompare(ub.name_kana || ub.name || '', 'ja');
  });

  return groups.map(function(g, i) {
    // 🔴 **두 곳에서 나눠 가져온다 — 하나로 합치면 한쪽이 빈다.**
    //   campMeta(리포트에 저장된 스냅샷) = 캠페인 번호·제목. **원본이 지워져도 남는다.**
    //   campLive(결과물에 딸려 온 실물)   = 모집 형식·구매 기간 등 나머지.
    //   ⚠️ 예전엔 `campById.get(...) || g.campaign` 로 **스냅샷을 통째로 우선**했는데,
    //      스냅샷에는 번호·제목뿐이라 **구매기간 칸이 전부 비었다**(2026-09-03 브라우저에서 발견).
    const campMeta = campById.get(g.campaign_id) || {};
    const campLive = g.campaign || {};
    const camp = Object.assign({}, campLive, {
      campaign_no: campMeta.campaign_no || campLive.campaign_no,
      title:       campMeta.title       || campLive.title,
    });
    const u = users[g.user_id] || null;
    const r = g.receipt;
    const q = _reportChannelCell(g, REPORT_CH_QOO10);
    const c = _reportChannelCell(g, REPORT_CH_COSME);
    const unknown = lookupFailed ? '?' : '';
    return {
      src: 'B',                                            // 구분 — REVERB
      no: i + 1,                                           // 1
      campaign_no: camp.campaign_no || '',                 // 2 (2026-09-04)
      campaign_name: camp.title || '',                     // 3
      account_id: u ? (u.email || '') : unknown,           // 11 (영수증 업로드 날짜 옆)
      purchase_period: _reportPurchasePeriod(camp),        // 4
      status: _reportCertStatus(g),                        // 5
      order_no: r ? (r.order_number || '') : '',           // 6
      purchase_date: r ? (r.purchase_date || '') : '',     // 7
      amount: (r && r.purchase_amount !== null && r.purchase_amount !== undefined)
                ? r.purchase_amount : '',                  // 8 — ⚠️ Number(null) 이 0 이라 빈 값을 먼저 거른다
      receipt_url: r ? (r.receipt_url || '') : '',         // 9
      receipt_uploaded_at: r ? (r.submitted_at || '') : '',// 10
      name_kanji: u ? (u.name_kanji || u.name || '') : unknown, // 11
      name_kana: u ? (u.name_kana || '') : unknown,        // 12
      ch_qoo10_url: q.url, ch_qoo10_kind: q.kind, ch_qoo10_at: q.at,   // 13·14
      ch_cosme_url: c.url, ch_cosme_kind: c.kind, ch_cosme_at: c.at,   // 15·16
      // 화면이 되짚어 볼 때 쓰는 값(표에는 안 그린다)
      _campaign_id: g.campaign_id, _application_id: g.application_id, _user_id: g.user_id,
    };
  });
}

// 외부(포인테일) 참가자 행 → 표준 행. 작업 16.
//   ⚠️ 이름 2칸·구매일은 **비운다** — 원본에 없다. 없는 것을 지어내지 않는다.
//   ⚠️ 캠페인명은 **관리자가 모달에 적은 이름**(사양서 표 3번 칸).
//   구분: 'A-1' = 텍스트 리뷰 · 'A-2' = 포토 리뷰 · 리뷰 없이 구매만이면 'A'
function _reportExtToRow(r, src) {
  const kind = r.review_kind === 'photo' ? 'A-2' : (r.review_kind === 'text' ? 'A-1' : 'A');
  return {
    src: kind,
    no: 0,
    campaign_no: src ? (src.ext_campaign_no || '') : '',
    campaign_name: src ? (src.ext_campaign_name || '') : '',
    account_id: r.account_id || '',
    purchase_period: '',
    status: r.mission_status || '',
    order_no: r.order_no || '',
    purchase_date: '',
    amount: (r.purchase_amount === null || r.purchase_amount === undefined) ? '' : r.purchase_amount,
    receipt_url: r.receipt_url || '',
    receipt_uploaded_at: r.receipt_at || '',
    name_kanji: '', name_kana: '',
    ch_qoo10_url: r.qoo10_urls || '', ch_qoo10_kind: r.qoo10_urls ? 'photo' : '', ch_qoo10_at: r.qoo10_at || '',
    ch_cosme_url: r.cosme_urls || '', ch_cosme_kind: r.cosme_urls ? 'photo' : '', ch_cosme_at: r.cosme_at || '',
    _ext: true, _source_id: r.source_id, _member_no: r.member_no,
  };
}

