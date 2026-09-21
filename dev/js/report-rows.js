// ══════════════════════════════════════════════════════════════
// 리포트 표 행 만들기 — 관리자 화면과 브랜드 공유 화면이 **같은 원본**을 쓴다
//   · 관리자 번들: dev/build.sh 의 ADMIN_JS_FILES 에 이어 붙는다
//   · 공유 화면  : dev/build.sh 가 report.html 의 <!-- @@REPORT_ROWS_JS@@ --> 자리에 인라인한다
//   🔴 여기 판정을 고치면 두 화면이 함께 바뀐다 — 그게 이 파일이 따로 있는 이유다.
//   ⚠️ 이 파일은 esc()·toast() 같은 화면 헬퍼를 쓰지 않는다(공유 화면에는 그것들이 없다).
//   ⚠️ 인증 상태 판정 3함수는 admin-excel.js 에서 옮겨 온 것이다(2026-09-04). 이름 그대로.
//   ⚠️ 계정 주소 함수 `_excelSnsUrl` 도 같은 이유로 옮겨 왔다(2026-09-17). 이름·`function` 선언 형태 그대로 —
//      빌드가 한 덩어리로 이어 붙여 선언이 끌어올려지므로 앞 파일(admin-excel.js)에서 불러도 된다.
// ══════════════════════════════════════════════════════════════

// monitor 채널별 review_image 상태 집합 → 대표 상태 repr (admin-deliverables 와 동일 우선순위)
//   campChannels: 캠페인 채널 코드 배열, reviewByCh: { channelCode: deliv }
// 캠페인이 여러 채널을 모집할 때 **전부** 내야 하는지, **하나만** 내면 되는지.
//   🔴 **이 파일은 두 곳에서 돈다** — 관리자 번들(`shared.js` 가 함께 실림)과
//      **브랜드 공유 화면 `report.html`**(빌드가 이 파일만 인라인 — `shared.js` 는 **없다**).
//      그래서 공용 함수가 있으면 그것을 쓰고, 없으면 같은 기준을 그대로 쓴다.
//   ⚠️ **기본값은 `or`**(「`and` 가 아니면 `or`」). 반대로 적으면 지금 정상인 캠페인이 깨진다.
function _reportChannelKind(camp) {
  if (typeof campaignFollowerKind === 'function') return campaignFollowerKind(camp || {});
  var list = String((camp && camp.channel) || '').split(',').map(function(c){ return c.trim(); }).filter(Boolean);
  if (list.length <= 1) return 'single';
  return String((camp && camp.channel_match) || '').trim().toLowerCase() === 'and' ? 'and' : 'or';
}

// 채널별 상태 목록에서 대표 상태 하나.
//   ⚠️ `channelKind` 를 **안 넘기면 `and`(전부 요구)** 로 떨어진다 — 종전 동작이라 안전한 방향이다.
//   🔴 `or` 에서 「하나 승인 + 하나 반려」는 **완료**다(반려된 채널은 낼 의무가 없던 채널).
function _excelMonitorResultRepr(campChannels, reviewByCh, channelKind) {
  reviewByCh = reviewByCh || {};
  var channels = (campChannels || []).filter(Boolean);
  if (channels.length === 0) {
    // 채널 미등록 monitor — review_image 행이 하나라도 있으면 제출중, 없으면 none
    return Object.keys(reviewByCh).length > 0 ? 'pending' : 'none';
  }
  var states = channels.map(function(ch) { return (reviewByCh[ch] && reviewByCh[ch].status) || 'none'; });
  if (channelKind === 'or' && states.indexOf('approved') !== -1) return 'approved';
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
function _excelCertStatusKo(recruitType, receipt, result, proxyPurchase, campChannels, postByCh, channelKind) {
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
    var _repr = _excelMonitorResultRepr(_chs, postByCh || {}, channelKind);
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
function _excelCertStatusMonitorKo(campChannels, receipt, reviewByCh, proxyPurchase, channelKind) {
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
  var repr = _excelMonitorResultRepr(campChannels, reviewByCh, channelKind);
  if (receipt && receipt.status === 'approved' && repr === 'approved') return '인증성공';
  return '인증샷 제출중';
}

// 17칸 머리글 — 사양서 16칸에 「캠페인 번호」를 더했다(2026-09-04 사용자 결정: 「ID」 자리는 캠페인 번호, 계정 ID 는 업로드 날짜 옆)
const REPORT_COLS = [
  // w = 열 너비, wrap = 줄바꿈 허용(캠페인명만). 나머지는 nowrap — 날짜·번호·상태가 두 줄로 접히면 표가 읽기 어렵다(2026-09-04 사용자 요청).
  // grp  = 열 고르기 창에서 묶는 이름. pick = 그 창에서만 쓰는 이름(「업로드 날짜」가 여럿이라 앞말을 붙인다).
  //   ⚠️ 표 머리글·엑셀 머리글은 label 그대로다 — pick 은 창 전용.
  {key:'no',                  label:'No.',              w:'46px',  grp:'기본'},
  {key:'campaign_no',         label:'캠페인 번호',       w:'110px', grp:'기본'},
  {key:'campaign_name',       label:'캠페인명',          w:'260px', grp:'기본', wrap:true},
  {key:'purchase_period',     label:'구매기간',          w:'185px', grp:'기본'},
  {key:'status',              label:'상태',             w:'100px', grp:'기본'},
  {key:'order_no',            label:'주문 번호',         w:'130px', grp:'구매·영수증'},
  {key:'purchase_date',       label:'구매일',            w:'96px',  grp:'구매·영수증'},
  {key:'amount',              label:'구매금액',          w:'100px', grp:'구매·영수증'},
  {key:'receipt_url',         label:'구매 영수증 (URL)',  w:'120px', grp:'구매·영수증'},
  {key:'receipt_uploaded_at', label:'업로드 날짜',        w:'130px', grp:'구매·영수증', pick:'영수증 업로드 날짜'},
  {key:'account_id',          label:'계정 ID',           w:'210px', grp:'기본'},
  {key:'name_kanji',          label:'이름 (한자)',        w:'120px', grp:'기본'},
  {key:'name_kana',           label:'이름 (일본어)',      w:'130px', grp:'기본'},
  {key:'ch_qoo10_url',        label:'큐텐 결과물 (URL)',  w:'150px', grp:'큐텐',     ch:'qoo10'},
  {key:'ch_qoo10_at',         label:'업로드 날짜',        w:'130px', grp:'큐텐',     ch:'qoo10', pick:'큐텐 업로드 날짜'},
  {key:'ch_cosme_url',        label:'엣코스메 결과물 (URL)', w:'150px', grp:'엣코스메', ch:'cosme'},
  {key:'ch_cosme_at',         label:'업로드 날짜',        w:'130px', grp:'엣코스메', ch:'cosme', pick:'엣코스메 업로드 날짜'},
];

// ══════════════════════════════════════════════════════════════
// 표 행 만들기 — 작업 6 (사양서 16칸 + 캠페인 번호 = 17칸, 2026-09-04)
//   사양서 「표 양식 (구글시트 16칸 그대로)」
//
// 한 사람 = 한 줄. 큐텐과 엣코스메가 **한 줄 안에서** 칸을 나눠 가진다.
// 맨 앞에 「구분」 열이 하나 더 붙어 화면에는 17칸이 보인다(구분 + 16).
//   구분 값: 'B' = REVERB / 'A-1'·'A-2' = 외부(작업 16에서 채운다)
// ══════════════════════════════════════════════════════════════

// ── 채널 대장 — 리포트가 아는 채널은 **여기 한 곳**이다 (2026-09-17) ──
//   열 만들기·칸 채우기·열 고르기 창·두 엑셀이 전부 이것만 본다.
//   always = 늘 있는 열(지금의 17칸에 든 큐텐·엣코스메) / false = 「쓰일 때만」 생기는 열
//   acct   = 계정 열이 있으면 회원 표(`influencers`)의 칸 이름, 없으면 null
//   ⚠️ code 는 기준 데이터(lookup_values)의 code 와 **글자 그대로** 같아야 한다 — 마이그레이션 157 이 심은 값.
//   🔴 이 값을 바꾸면 기준 데이터·캠페인(`campaigns.channel`)·이미 낸 결과물
//      (`deliverables.post_channel`) **세 곳을 함께** 옮겨야 한다. 하나만 바꾸면
//      문자열 비교가 깨져 결과물이 화면·인증·정산 세 곳에서 동시에 사라진다
//      (2026-07-30 @cosme 사고 — 승인된 인증샷 55건이 두 달간 안 보였다).
//   🔴 **사본이 하나 더 있다** — acct 가 있는 네 채널의 「코드 ↔ 회원 표의 칸」 짝은 공유용 서버 함수
//      `get_report_share_data`(마이그레이션 449) 안에도 적혀 있다. 계정 열이 있는 채널을 더하는 날은 **두 곳을 함께**.
//   ⚠️ 기준 데이터에 채널을 더하면 여기도 한 줄 더한다. 빠뜨려도 결과물은 「기타 결과물」 칸으로 가므로 사라지지는 않는다.
//   ⚠️ 상수로 두는 이유 — 공유 화면은 로그인이 없고 기준 데이터를 읽지 않는다.
const REPORT_CHANNELS = [
  {code:'qoo10',     label:'큐텐',       always:true,  acct:null},
  {code:'cosme',     label:'엣코스메',    always:true,  acct:null},
  {code:'lips',      label:'LIPS',      always:false, acct:null},
  {code:'instagram', label:'인스타그램',  always:false, acct:'ig'},
  {code:'tiktok',    label:'틱톡',       always:false, acct:'tiktok'},
  {code:'x',         label:'X',         always:false, acct:'x'},
  {code:'youtube',   label:'유튜브',      always:false, acct:'youtube'},
];

// 옛 열쇠 — 2026-09-17 이전부터 열 고르기 창에 있던 16개(17칸에서 계정 ID 제외).
//   저장된 열 목록(`share_columns`)에서 이 열쇠들은 「목록에 **없으면** 관리자가 끈 것」이다.
//   🔴 **이 목록에는 앞으로 아무것도 더하지 않는다.** 그 뜻은 「그 열이 창에 늘 나와 있을 때」만 성립한다 —
//      나중에 생긴 열을 여기 넣으면, 그 열이 없던 시절에 저장된 목록에서 전부 「끈 열」로 읽힌다.
//   ⚠️ REPORT_COLS 에서 계산하지 않고 글자로 적어 둔 이유도 같다(REPORT_COLS 가 늘어도 이 목록은 안 늘어야 한다).
const REPORT_SHARE_LEGACY_KEYS = [
  'no', 'campaign_no', 'campaign_name', 'purchase_period', 'status',
  'order_no', 'purchase_date', 'amount', 'receipt_url', 'receipt_uploaded_at',
  'name_kanji', 'name_kana',
  'ch_qoo10_url', 'ch_qoo10_at', 'ch_cosme_url', 'ch_cosme_at',
];

// 값이 있는가 — 빈 문자열·null·undefined 만 「없음」이다(0 은 값이다).
function _reportHasVal(v) { return v !== '' && v !== null && v !== undefined; }

// 열 목록 — **행을 받아 계산한다.** 관리자 화면·공유 화면·두 엑셀·열 고르기 창이 같은 함수를 부른다.
//   · 지금의 17칸(REPORT_COLS)은 그대로, 늘 있다.
//   · 「쓰일 때만」 채널은 둘 중 하나면 열이 생긴다 —
//       「요구」 어느 줄이든 그 줄의 모집 건이 그 채널을 요구한다(`_channels`)
//       「값」   어느 줄이든 그 채널 칸에 주소나 날짜가 있다
//   · 계정 열은 그 채널 열이 생겼고 대장에 acct 가 있을 때 함께. 한 채널의 차례는 계정 → 결과물 → 날짜.
//   · 「기타 결과물」 두 칸은 「값」일 때만, 맨 끝.
//   ⚠️ 판정 재료는 **행뿐**이다 — 그래서 두 화면이 같은 입력으로 같은 열을 만든다.
function reportColumnsFor(rows) {
  rows = rows || [];
  const cols = REPORT_COLS.slice();
  REPORT_CHANNELS.forEach(function(ch) {
    if (ch.always) return;
    const k = 'ch_' + ch.code;
    const used = rows.some(function(r) {
      return (r._channels && r._channels.indexOf(ch.code) !== -1) || _reportHasVal(r[k + '_url']) || _reportHasVal(r[k + '_at']);
    });
    if (!used) return;
    if (ch.acct) cols.push({key: k + '_acct', label: ch.label + ' 계정', w:'150px', grp: ch.label, ch: ch.code, acct: true});
    cols.push({key: k + '_url', label: ch.label + ' 결과물 (URL)', w:'150px', grp: ch.label, ch: ch.code});
    cols.push({key: k + '_at',  label: '업로드 날짜', w:'130px', grp: ch.label, ch: ch.code, pick: ch.label + ' 업로드 날짜'});
  });
  if (rows.some(function(r){ return _reportHasVal(r.ch_etc_url) || _reportHasVal(r.ch_etc_at); })) {
    cols.push({key:'ch_etc_url', label:'기타 결과물 (URL)', w:'170px', grp:'기타', ch:'etc'});
    cols.push({key:'ch_etc_at',  label:'업로드 날짜',       w:'130px', grp:'기타', ch:'etc', pick:'기타 업로드 날짜'});
  }
  return cols;
}

// 결과물 칸(대장의 모든 채널 + 기타) 중 하나라도 주소가 있는 줄인가 — 요약의 「결과물 N」이 센다.
//   ⚠️ 관리자 요약과 공유 화면 요약이 **같은 함수**를 쓴다(두 화면의 N 이 갈리지 않게).
function reportRowHasResult(r) {
  if (!r) return false;
  if (_reportHasVal(r.ch_etc_url)) return true;
  return REPORT_CHANNELS.some(function(ch){ return _reportHasVal(r['ch_' + ch.code + '_url']); });
}

// ── 공유 화면 열 고르기 — 판정은 이 **둘**이다 ──
//   saved = 저장된 열 목록(`campaign_reports.share_columns`). 배열이 아니면(null) 「꺼진 것 없음」.
//
// ① 「꺼져 있는가」 — **열 고르기 창(체크 상태)과 공유 화면이 같이** 쓴다.
//    두 벌이 되면 창에서 끈 것과 브랜드 화면에서 빠지는 것이 갈린다.
//      옛 열쇠 : 배열이 있는데 `열쇠` 가 **없으면** 꺼짐 (종전 그대로)
//      새 열쇠 : 배열에 `-열쇠` 가 **있으면** 꺼짐     (없으면 「아직 안 고른 것」 = 켜짐)
//    🔴 뜻이 옛·새가 반대인 것이 핵심이다 — 하나로 합치면 「새 열이 브랜드에게 안 보인다」 또는
//       「관리자가 끈 영수증 열이 되살아난다」 둘 중 하나가 난다.
//    계정 ID(로그인 이메일)는 어떤 값이 저장돼 있어도 꺼짐이다.
function reportShareColOff(key, saved) {
  if (key === 'account_id') return true;
  if (!Array.isArray(saved)) return false;
  if (REPORT_SHARE_LEGACY_KEYS.indexOf(key) !== -1) return saved.indexOf(key) === -1;
  return saved.indexOf('-' + key) !== -1;
}

// ② 「그릴 것인가」 = 꺼져 있지 않다 + 그 열에 값이 하나라도 있다 — **공유 화면과 브랜드용 엑셀이 같이** 쓴다.
//    열마다 따로 본다(아무도 안 낸 채널은 결과물·날짜 없이 계정 열만 그려질 수 있다 — 의도).
//    🔴 **열 고르기 창의 체크 상태에 이것을 쓰면 안 된다.** 값 없는 옛 열이 꺼진 것으로 그려지고,
//       그대로 저장하면 그 열쇠가 배열에서 빠져 「끈 적 없는데 꺼진 열」로 굳는다.
function reportShareColDraw(col, saved, rows) {
  if (!col || reportShareColOff(col.key, saved)) return false;
  return (rows || []).some(function(r){ return _reportHasVal(r[col.key]); });
}

// 저장할 배열 만들기 — 열 고르기 창이 부른다(형식이 ①과 한 세트라 여기 둔다).
//   shownKeys   : 창에 나온 열쇠 전부(계정 ID 제외)
//   checkedKeys : 그중 체크된 것
//   prevSaved   : 지금 저장돼 있는 배열(없으면 null)
//   · 옛 열쇠는 켠 것을 `열쇠` 로(종전 그대로) · 새 열쇠는 **끈 것만** `-열쇠` 로. 켠 새 열쇠는 적지 않는다.
//   🔴 **창에 안 나온 새 열쇠의 `-열쇠` 는 그대로 보존한다.** 틱톡 계정을 꺼 둔 리포트에서 틱톡 모집 건을
//      뺐다가 다시 넣어도 꺼진 채여야 한다. 창에 나온 것만으로 새로 만들면 그 기록이 사라진다.
function reportShareColsToSave(shownKeys, checkedKeys, prevSaved) {
  shownKeys = shownKeys || []; checkedKeys = checkedKeys || [];
  const out = [];
  REPORT_SHARE_LEGACY_KEYS.forEach(function(k){ if (checkedKeys.indexOf(k) !== -1) out.push(k); });
  shownKeys.forEach(function(k) {
    if (k === 'account_id' || REPORT_SHARE_LEGACY_KEYS.indexOf(k) !== -1) return;
    if (checkedKeys.indexOf(k) === -1) out.push('-' + k);
  });
  (Array.isArray(prevSaved) ? prevSaved : []).forEach(function(v) {
    if (typeof v !== 'string' || v.charAt(0) !== '-') return;
    const k = v.slice(1);
    if (REPORT_SHARE_LEGACY_KEYS.indexOf(k) !== -1) return;      // 옛 열쇠에 `-` 는 뜻이 없다
    if (shownKeys.indexOf(k) !== -1) return;                     // 창에 나온 것은 위에서 정했다
    if (out.indexOf(v) === -1) out.push(v);
  });
  return out;
}

// 스킴(`https://`)이 없는 **주소**인가 — 첫 빗금 앞이 도메인 모양(점이 있다)일 때만.
//   🔴 **빗금과 점이 둘 다** 있어야 한다. 하나만으로는 안 되는 이유가 각각 있다:
//      · 점만 보면 — `sy_beauty.com` 같은 **실제 틱톡 아이디**(운영에 있다)를 주소로 오인해
//        멀쩡하던 계정 링크가 깨진다. SNS 아이디에는 점을 쓸 수 있다.
//      · 빗금만 보면 — `myhandle/` 처럼 **도메인이 없는** 값이 `https://myhandle/` 이 되어,
//        적어도 채널 도메인은 맞던 종전(`tiktok.com/@myhandle/`)보다 나빠진다.
//   ⚠️ 그래서 `gmail.com`·`a@gmail.com` 처럼 아이디 칸에 잘못 적힌 값은 **종전대로** 아이디로 다룬다.
//      틀린 값을 우리가 고쳐 주지는 않되, 없는 주소를 조립하지도 않는 선이다.
function _reportLooksLikeAddress(v) {
  if (typeof v !== 'string') return false;
  var slash = v.indexOf('/');
  return slash > 0 && v.slice(0, slash).indexOf('.') !== -1;
}

// SNS 계정 → 전체 주소 (각 SNS 공식 주소 형식). TikTok/YouTube 는 @ 필수.
//   ⚠️ admin-excel.js 에서 옮겨 왔다(2026-09-17) — 공유 화면에는 admin-excel.js 가 없다. 이름 그대로.
//   🔴 **틀린 주소를 조립하지 않는다.**
//      · `extractSnsHandle`(shared.js)이 있는 자리(관리자)는 그것으로 아이디를 뽑아 공식 주소를 만든다.
//      · 없는 자리(공유 화면)에서 저장된 값이 주소 모양(`http` 로 시작, 앞의 `@` 는 떼고 본다)이면
//        **그 주소 그대로** 돌려준다. 예전처럼 「@ 떼기」만 하면 `instagram.com/https://…` 가 된다.
//      · 유튜브 아이디가 채널 아이디(`UC…`) 모양이면 `/channel/` 주소다(아래 `case 'youtube'`).
//        `/@UC…` 는 없는 주소다 — 관리자 엑셀에도 있던 결함이라 함께 고쳐진다.
//        ⚠️ 이 줄은 2026-09-21 까지 없어진 `snsProfileUrl` 을 근거로 들고 있었다 — 그 함수는 지웠다.
function _excelSnsUrl(channel, raw) {
  if (!raw) return '';
  var hasEx = (typeof extractSnsHandle === 'function');
  var bare = String(raw).replace(/^@+/, '').trim();
  if (/^https?:\/\//i.test(bare)) { if (!hasEx) return bare; }
  else if (_reportLooksLikeAddress(bare)) return 'https://' + bare;   // 스킴 없는 주소 — 앞에 https:// 만 붙인다
  var handle = hasEx ? extractSnsHandle(channel, raw) : bare;
  if (!handle) return '';
  if (/^https?:\/\//i.test(handle)) return handle;   // 아이디를 못 뽑은 주소(게시물 주소 등) — 조립하지 않는다
  if (_reportLooksLikeAddress(handle)) return 'https://' + handle;
  switch (channel) {
    case 'instagram': return 'https://www.instagram.com/' + handle + '/';
    case 'tiktok':    return 'https://www.tiktok.com/@' + handle;
    case 'x':         return 'https://x.com/' + handle;
    case 'youtube':   return /^UC[A-Za-z0-9_-]{20,}$/.test(handle) ? 'https://www.youtube.com/channel/' + handle
                                                                   : 'https://www.youtube.com/@' + handle;
    default: return handle;
  }
}

// 계정 칸 — 주소(url)와 화면에 보이는 글자(text).
//   text: 아이디 모양이면 「@아이디」. 주소 모양이면 아이디를 뽑을 수 있는 자리(관리자)는 「@아이디」,
//         못 뽑는 자리(공유 화면)는 **주소 그대로**.
function _reportAcctCell(channel, raw) {
  var s = String(raw === null || raw === undefined ? '' : raw).trim();
  if (!s) return {url: '', text: ''};
  var bare = s.replace(/^@+/, '').trim();
  // 스킴 없는 주소는 **먼저 스킴을 붙여** 아래 주소 갈래로 보낸다 — 안 그러면 글자가 「@www.tiktok.com/@아이디」가 된다.
  //   ⚠️ 이렇게 해야 아이디를 뽑을 수 있는 자리(관리자)가 「@아이디」로 줄여 보여 준다.
  if (!/^https?:\/\//i.test(bare) && _reportLooksLikeAddress(bare)) { s = 'https://' + bare; bare = s; }
  var url = _excelSnsUrl(channel, s);
  if (/^https?:\/\//i.test(bare)) {
    var h = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, s) : '';
    return (h && !/^https?:\/\//i.test(h)) ? {url: url, text: '@' + h} : {url: url || bare, text: bare};
  }
  return {url: url, text: '@' + bare};
}

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
        // 채널이 **빈** 게시물·인증샷을 담는 바구니(2026-09-17). 「기타 결과물」 칸이 쓴다.
        //   🔴 인증 상태 판정이 보는 `result`·`reviewByCh`·`postByCh` 는 **내용을 바꾸지 않는다** —
        //      이 바구니는 그 옆에 **더하는** 것이다. 판정이 바뀌면 안 된다.
        etcNoCh: [],
      });
    }
    const g = groups.get(key);
    if (!g.campaign && d.campaigns) g.campaign = d.campaigns;
    const subAt = d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image') {
      // ⚠️ 채널 없는 옛 인증샷은 채널 칸에 넣을 자리가 없다(엑셀도 같다) — 「기타 결과물」 바구니로 간다.
      if (d.post_channel) {
        const prev = g.reviewByCh[d.post_channel];
        if (!prev || subAt > (prev.submitted_at || '')) g.reviewByCh[d.post_channel] = d;
      } else { g.etcNoCh.push(d); }
    } else if (d.kind === 'post') {
      if (!g.result || subAt > (g.result.submitted_at || '')) g.result = d;
      if (d.post_channel) {
        const prevP = g.postByCh[d.post_channel];
        if (!prevP || subAt > (prevP.submitted_at || '')) g.postByCh[d.post_channel] = d;
      } else { g.etcNoCh.push(d); }
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

// 그 줄의 모집 건이 요구하는 채널 목록 — `campaigns.channel` 을 쉼표로 나눠 **앞뒤 공백만** 뗀다.
//   ⚠️ 대소문자 변환 없음 — 서버 함수(449)·인증 판정과 같은 비교다.
function _reportCampChannels(camp) {
  return String((camp && camp.channel) || '').split(',').map(function(c){ return c.trim(); }).filter(Boolean);
}

// 「기타 결과물」 칸 — 게시물·인증샷 가운데 **채널이 비었거나 대장에 없는 코드**인 것(「other」 포함).
//   · 채널이 빈 것은 묶는 단계의 바구니(`etcNoCh`)에, 대장에 없는 코드는 `reviewByCh`·`postByCh` 에
//     그 코드 이름으로 들어 있다 — 둘을 합쳐 본다.
//   · 여러 건이면 **제출 시각이 가장 늦은 1건**, 나머지 건수는 `more`(화면이 「외 N건」으로 적는다).
//   🔴 **요구 채널을 다 채운 줄은 비운다**(2026-09-17 사용자 결정) — 그 줄의 모집 건이 요구하는 채널이
//      하나 이상 있고 그 채널의 결과물 칸이 **전부 주소를 갖고 있으면** 후보가 있어도 넣지 않는다(「외 N건」도).
//      채널 코드를 옮기다 남은 옛 코드 행(같은 응모에 새 코드 행이 따로 있다)이 브랜드 표에 두 번 나오는 것을 막는다.
//      `detect_channel_code_drift` 의 「올바른 채널에 행이 있으면 덮인 것」과 같은 생각 — 검수 상태는 안 본다.
//      · 요구 채널 가운데 대장에 없는 코드가 있으면 그 채널은 **안 채워진 것**이다(→ 넣는다).
//      · 요구 채널이 하나도 없는 모집 건은 늘 넣는다(그 결과물은 기타 칸이 유일한 자리다).
//   filledByCode = 이 줄에서 방금 채운 채널 칸 {코드: 주소}
function _reportEtcCell(g, campChannels, filledByCode) {
  const known = {};
  REPORT_CHANNELS.forEach(function(ch){ known[ch.code] = 1; });
  const cand = (g.etcNoCh || []).slice();
  [g.reviewByCh || {}, g.postByCh || {}].forEach(function(byCh) {
    Object.keys(byCh).forEach(function(code){ if (!known[code] && byCh[code]) cand.push(byCh[code]); });
  });
  const empty = {url: '', at: '', kind: '', more: 0};
  if (!cand.length) return empty;
  const chs = campChannels || [];
  if (chs.length > 0 && chs.every(function(code){ return known[code] && _reportHasVal((filledByCode || {})[code]); })) return empty;
  cand.sort(function(a, b){ return (b.submitted_at || '').localeCompare(a.submitted_at || ''); });
  const d = cand[0];
  const isPhoto = d.kind === 'review_image';
  return {url: (isPhoto ? d.receipt_url : d.post_url) || '', at: d.submitted_at || '', kind: isPhoto ? 'photo' : 'post', more: cand.length - 1};
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
  // 🔴 갈래를 넘긴다 — 안 넘기면 「또는」 캠페인이 여기서만 「전부 요구」로 판정돼
  //   관리자 화면·서버와 다른 상태를 브랜드에게 보여주게 된다(2026-09-21, 2단계).
  const kind = _reportChannelKind(camp);
  if (camp.recruit_type === 'monitor' && chs.length > 0) {
    return _excelCertStatusMonitorKo(chs, g.receipt, g.reviewByCh, !!camp.proxy_purchase, kind);
  }
  return _excelCertStatusKo(camp.recruit_type, g.receipt, g.result, !!camp.proxy_purchase, chs, g.postByCh, kind);
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
    const unknown = lookupFailed ? '?' : '';
    // 채널 칸 — 대장의 채널마다 `_reportChannelCell` 을 그대로 부른다(사진 우선, 없으면 게시물).
    //   계정 칸은 **그 줄이 그 채널과 관계있을 때만** 채운다 — 모집 건이 그 채널을 요구하거나, 그 줄의 그 채널 칸에 값이 있을 때.
    //   🔴 회원 단위로 채우면 큐텐 리뷰만 한 사람의 인스타그램 계정까지 브랜드에게 간다(혼합 리포트).
    //   회원이 그 계정을 등록하지 않았으면 조건에 맞아도 빈칸. 회원 조회가 실패했으면 조건에 맞는 칸에 「?」(이름 칸과 같은 규칙).
    const campChannels = _reportCampChannels(camp);
    const chVals = {}, filled = {};
    REPORT_CHANNELS.forEach(function(ch) {
      const k = 'ch_' + ch.code;
      const cell = _reportChannelCell(g, ch.code);
      chVals[k + '_url'] = cell.url; chVals[k + '_kind'] = cell.kind; chVals[k + '_at'] = cell.at;
      filled[ch.code] = cell.url;
      if (!ch.acct) return;
      const related = campChannels.indexOf(ch.code) !== -1 || _reportHasVal(cell.url) || _reportHasVal(cell.at);
      let acct = {url: '', text: ''};
      if (related) acct = u ? _reportAcctCell(ch.code, u[ch.acct]) : {url: unknown, text: unknown};
      chVals[k + '_acct'] = acct.url;            // 엑셀에는 전체 주소(결과물 칸이 주소를 넣는 것과 같다)
      chVals[k + '_acct_text'] = acct.text;      // 화면에 보이는 글자(표에 안 그리는 값 — 계정 칸이 쓴다)
    });
    const etc = _reportEtcCell(g, campChannels, filled);
    return Object.assign({
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
      // 13~16(큐텐·엣코스메)과 그 밖의 채널 칸은 아래 chVals 가 채운다 — 열쇠 이름은 종전 그대로(`ch_qoo10_url` 등)
      ch_etc_url: etc.url, ch_etc_kind: etc.kind, ch_etc_at: etc.at, ch_etc_more: etc.more,
      // 화면이 되짚어 볼 때 쓰는 값(표에는 안 그린다)
      _campaign_id: g.campaign_id, _application_id: g.application_id, _user_id: g.user_id,
      _channels: campChannels,                             // 열 만들기(reportColumnsFor)의 「요구」 판정 재료
    }, chVals);
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

