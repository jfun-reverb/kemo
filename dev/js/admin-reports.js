// ══════════════════════════════════════════════════════════════
// 리포트 관리 (캠페인 리포트 만들기) — 1-A 단계 뼈대
//   사양서 : docs/specs/2026-09-03-campaign-report-builder.md
//   작업표 : docs/specs/2026-09-03-campaign-report-builder-breakdown.md
//
// 이 조각(작업 4)은 **화면이 열리기까지의 등록만** 한다. 목록·표·모달은 뒤 조각.
//
// ⚠️ `loadReportsPane` 이름을 바꾸지 말 것 — 두 곳이 **이름으로** 참조한다:
//     ①`dev/js/admin-core.js` 의 `switchAdminPane` 안 `loaders`
//     ②`dev/lib/shared.js` 의 `PANE_REFRESHERS['reports']`
//    ①을 빠뜨리면 사이드바를 눌러도 **오류 없이 빈 화면**이 되고,
//    ②를 빠뜨리면 저장 뒤 목록이 안 갱신된다(`refreshPane` 이 조용히 끝난다).
//
// ⚠️ 이 파일은 빌드에서 `admin-core.js` **뒤**, `admin.js` **앞**에 이어 붙는다
//    (`dev/build.sh` 의 `ADMIN_JS_FILES`). 빌드는 단순 이어붙이기라 전역이 하나다.
//
// ⚠️ `dev/admin/index.html` 에 이 파일의 `<script>` 태그를 넣지 않는다 —
//    원본 HTML 은 페인 파일을 개별 태그로 부르지 않는다(빌드 목록에만 있다).
//    넣으면 빌드가 지우는 정규식에 안 걸려 **없는 경로를 부르는 죽은 태그**가 남는다.
//    (작업표는 「정규식이 자동으로 걸러 준다」고 적었으나 실제로는 안 걸린다 —
//     2026-09-03 실측: `admin-reports.js`·`admin-deliverables.js` 둘 다 안 걸림)
// ══════════════════════════════════════════════════════════════

async function loadReportsPane() {
  const pane = document.getElementById('adminPane-reports');
  if (!pane) return;

  // 권한 — 서버(행 단위 보안 정책·함수 가드)가 최종 방어선이고 여기는 표시 제어다.
  //   ⚠️ 화면 판정은 fail-open(못 읽으면 쓰기)이라 이것만으로 막혔다고 보면 안 된다.
  if (typeof isHidden === 'function' && isHidden('menu.reports')) {
    pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted);font-size:13px">이 화면에 접근할 권한이 없습니다.</div>';
    return;
  }

  pane.innerHTML = `
    <div class="admin-card">
      <div class="admin-card-header">
        <span class="admin-card-title">리포트 관리</span>
      </div>
      <div class="admin-table-wrap">
        <table class="data-table">
          <thead><tr>
            <th>제목</th>
            <th style="width:90px;text-align:center">캠페인</th>
            <th style="width:90px;text-align:center">외부 첨부</th>
            <th style="width:130px">만든 사람</th>
            <th style="width:150px">만든 날</th>
            <th style="width:150px">마지막 고친 날</th>
          </tr></thead>
          <tbody id="reportListBody">
            <tr><td colspan="6" style="padding:40px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</td></tr>
          </tbody>
        </table>
      </div>
    </div>`;

  renderReportList(await fetchCampaignReports());
}

// ══════════════════════════════════════════════════════════════
// 16칸 표 만들기 — 작업 6
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
      account_id: u ? (u.email || '') : unknown,           // 2
      campaign_name: camp.title || '',                     // 3
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

// 외부(포인테일) 참가자 행 → 표준 16칸 행. 작업 16.
//   ⚠️ 이름 2칸·구매일은 **비운다** — 원본에 없다. 없는 것을 지어내지 않는다.
//   ⚠️ 캠페인명은 **관리자가 모달에 적은 이름**(사양서 표 3번 칸).
//   구분: 'A-1' = 텍스트 리뷰 · 'A-2' = 포토 리뷰 · 리뷰 없이 구매만이면 'A'
function _reportExtToRow(r, src) {
  const kind = r.review_kind === 'photo' ? 'A-2' : (r.review_kind === 'text' ? 'A-1' : 'A');
  return {
    src: kind,
    no: 0,
    account_id: r.account_id || '',
    campaign_name: src ? (src.ext_campaign_name || '') : '',
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

// ══════════════════════════════════════════════════════════════
// 만들기 창 — 작업 7
//
// 🔴 **모달 안쪽 상자의 인라인 스타일(`margin:auto;border-radius:16px;width:94vw`)은 빼면 안 된다.**
//    `.modal-overlay` 기본값은 **인플루언서(모바일) 아래에서 올라오는 시트**라, 이 스타일이
//    없으면 관리자 화면에서도 **모달이 화면 아래에 붙는다**(2026-09-03 사용자 지적 「모달 위치들이
//    다 밑에 있어」). 관리자 모달은 전부 이 인라인 스타일로 가운데를 잡는다(오리엔시트 모달 참조).
// 🔴 **모달 상자를 `dev/admin/index.html` 에 넣지 않는다.** 여기서 동적으로 만든다
//    (오리엔시트 모달 선례). 그래야 뒤 조각들이 그 핫스팟 파일을 다시 안 만진다.
// ══════════════════════════════════════════════════════════════

function _reportCloseCreateModal() {
  const m = document.getElementById('reportCreateModal');
  if (m) m.remove();
  _reportSrcBlocks = [];
}

// 제목이 비면 「리포트 만들기」를 못 누르게 한다.
function _reportSyncCreateBtn() { _reportSrcSyncSubmit(); }   // 제목 + 외부 블록 상태를 함께 본다

async function openReportCreateModal() {
  const ids = (typeof _selectedCampIds !== 'undefined' && _selectedCampIds) ? [..._selectedCampIds] : [];
  if (!ids.length) { if (typeof toast === 'function') toast('캠페인을 1개 이상 선택하세요'); return; }

  const camps = (Array.isArray(allCampaigns) ? allCampaigns : []).filter(function(c){ return ids.indexOf(c.id) !== -1; });
  // 목록에 없는 캠페인이 섞이면(고른 뒤 필터가 바뀐 경우) 이름을 못 적는다 — 개수로만 알린다.
  const missing = ids.length - camps.length;

  _reportCloseCreateModal();
  const wrap = document.createElement('div');
  wrap.id = 'reportCreateModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:560px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header">
        <h2>리포트 만들기</h2>
        <button class="modal-close" onclick="_reportCloseCreateModal()"><span class="material-icons-round notranslate" translate="no">close</span></button>
      </div>
      <div class="modal-body">
        <div class="form-group">
          <label class="form-label">리포트 제목 <span style="color:var(--pink)">*</span></label>
          <input type="text" class="form-input" id="reportCreateTitle" maxlength="200"
                 placeholder="예) 2026년 8월 큐텐 리뷰 리포트" oninput="_reportSyncCreateBtn()">
        </div>
        <div class="form-group">
          <label class="form-label">담긴 캠페인 ${ids.length}개</label>
          <div style="max-height:180px;overflow-y:auto;border:1px solid var(--line);border-radius:6px;padding:8px 10px;font-size:12px;line-height:1.9">
            ${camps.map(function(c){ return '<div>' + esc(c.campaign_no || '') + ' · ' + esc(c.title || '') + '</div>'; }).join('')}
            ${missing > 0 ? '<div style="color:var(--muted)">그 밖에 ' + missing + '개 (지금 목록에 없어 이름을 못 보여줍니다)</div>' : ''}
          </div>
        </div>
        <div class="form-group" style="margin-top:12px">
          <label class="form-label">외부 서비스 결과물 <span style="font-weight:400;color:var(--muted)">(선택 · 몇 개든 · 안 붙여도 됩니다)</span></label>
          <div id="reportSrcBlocks"></div>
          <button type="button" class="btn btn-ghost btn-xs" onclick="addSourceBlock()"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">add</span> 추가</button>
        </div>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseCreateModal()">취소</button>
        <button class="btn btn-primary" id="btnReportCreateSubmit" onclick="submitReportCreate()" disabled>리포트 만들기</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  _reportSrcBlocks = [];
  _reportSrcRender();
  const t = document.getElementById('reportCreateTitle');
  if (t) t.focus();
}

async function submitReportCreate() {
  const t = document.getElementById('reportCreateTitle');
  const btn = document.getElementById('btnReportCreateSubmit');
  const title = t ? t.value.trim() : '';
  if (!title) return;
  if (!_reportSrcAllValid()) { toast('외부 블록의 빈 칸을 채우거나 삭제해 주세요'); return; }
  const ids = (typeof _selectedCampIds !== 'undefined' && _selectedCampIds) ? [..._selectedCampIds] : [];
  if (!ids.length) { if (typeof toast === 'function') toast('캠페인을 1개 이상 선택하세요'); return; }

  // 감사용 계정 — 기존 확인 창(confirmAuditExport)을 그대로 쓴다.
  // ⚠️ **만들 때 한 번만 묻고 그 선택을 저장한다.** 저장하지 않으면 공유 화면이
  //    관리자가 본 것과 **다른 숫자**를 보여준다(사양서 ⑯).
  let includeAudit = false;
  try {
    const delivs = await fetchDeliverablesForReport(ids);
    const uids = [...new Set((delivs || []).map(function(d){ return d.user_id; }).filter(Boolean))];
    const users = await fetchInfluencersForReport(uids);
    // ⚠️ 회원 조회에 실패하면(null) 감사용 수를 셀 수 없다 — 0으로 보지 않고 묻지도 않는다.
    //    「없다」와 「못 물어봤다」를 같게 두면 감사용이 조용히 섞인다.
    if (users) {
      const auditCount = Object.values(users).filter(function(u){ return u && u.is_audit; }).length;
      const choice = await confirmAuditExport(auditCount);
      if (choice === 'cancel') return;
      includeAudit = (choice === 'include');
    }
  } catch (e) { console.warn('[submitReportCreate] 감사용 확인 건너뜀', e); }

  if (btn) { btn.disabled = true; btn.textContent = '만드는 중…'; }
  try {
    const id = await createCampaignReport(title, ids, includeAudit);
    // 외부 블록 저장 — 리포트가 생긴 뒤에. 실패해도 리포트는 남는다(다시 붙일 수 있다).
    const failed = await _reportSrcSaveAll(id);
    _reportCloseCreateModal();
    if (typeof toast === 'function') toast(failed.length ? '리포트는 만들었지만 첨부 일부 실패 — ' + failed.join(', ') : '리포트를 만들었습니다');
    // 목록을 새로고침 없이 갱신 — PANE_REFRESHERS 에 'reports' 가 등록돼 있어야 동작한다.
    //   ⚠️ 등록이 빠지면 오류가 아니라 console.warn 한 줄만 남고 목록이 그대로다.
    if (typeof refreshPane === 'function') await refreshPane('reports');
    return id;
  } catch (e) {
    // 🔴 서버가 거부한 사유를 그대로 보여준다. 「알 수 없는 오류」로 덮지 않는다 —
    //    이 저장소는 오류를 일반 문구로 덮어 3개월간 죽은 기능을 못 본 적이 있다.
    if (btn) { btn.disabled = false; btn.textContent = '리포트 만들기'; }
    if (typeof toast === 'function') toast('만들지 못했습니다 — ' + ((e && e.message) || e));
    console.error('[submitReportCreate]', e);
  }
}

// ══════════════════════════════════════════════════════════════
// 목록 그리기 — 작업 8
// ══════════════════════════════════════════════════════════════

function renderReportList(list) {
  const body = document.getElementById('reportListBody');
  if (!body) return;

  // ⚠️ 조회 실패(null)와 0건([])을 **다르게** 그린다.
  //    합치면 「아직 안 만든 것」과 「못 물어본 것」이 화면에서 같아진다.
  if (list === null || list === undefined) {
    body.innerHTML = '<tr><td colspan="6" style="padding:40px;text-align:center;color:var(--pink);font-size:13px">목록을 불러오지 못했습니다. 잠시 뒤 다시 시도해 주세요.</td></tr>';
    return;
  }
  if (!list.length) {
    body.innerHTML = '<tr><td colspan="6" style="padding:40px;text-align:center;color:var(--muted);font-size:13px">아직 만든 리포트가 없습니다.<br><span style="font-size:12px">「캠페인 관리」에서 캠페인을 고른 뒤 「리포트 만들기」를 누르세요.</span></td></tr>';
    return;
  }
  body.innerHTML = list.map(function(r) {
    // ⚠️ 캠페인 수·외부 첨부 수는 목록 조회에 아직 없다(작업 12에서 외부 표가 생긴다).
    //    없는 값을 0 으로 그리면 「담긴 캠페인이 없다」로 읽히므로 '-' 로 둔다.
    const nCamp = (r.campaign_count === null || r.campaign_count === undefined) ? '-' : r.campaign_count;
    const nExt  = (r.ext_count === null || r.ext_count === undefined) ? '-' : r.ext_count;
    // ⚠️ 인라인 처리기에 넣는 값은 고유번호(따옴표가 못 들어가는 형태)만 쓴다 —
    //    제목은 사람이 적은 글이라 따옴표가 들어오면 깨진다.
    return `<tr style="cursor:pointer" onclick="openReport('${r.id}')">
      <td><strong>${esc(r.title || '(제목 없음)')}</strong></td>
      <td style="text-align:center">${nCamp}</td>
      <td style="text-align:center">${nExt}</td>
      <td>${esc(r.created_by_name || '-')}</td>
      <!-- ⚠️ 날짜 표기는 공용 헬퍼 formatDate(ui.js) — 관리자 목록 화면들이 쓰는 것과 같다.
           admin-brand.js 의 fmtDate 는 그 화면 전용 감싸개라 여기서는 안 쓴다. -->
      <td>${formatDate(r.created_at)}</td>
      <td>${formatDate(r.updated_at)}</td>
    </tr>`;
  }).join('');
}

// ══════════════════════════════════════════════════════════════
// 리포트 화면 — 작업 9
//
// 🔴 **시각을 한 값으로 합치지 않는다**(사양서 ⑥).
//    REVERB 결과물은 **열 때마다 방금 조회**한 것이고, 외부(포인테일 등) 결과물은
//    **붙인 시각의 스냅샷**이다. 합쳐 놓으면 브랜드가 외부 데이터도 방금 것으로 읽는다.
//    「구성이 바뀐 시각」은 또 다른 **세 번째** 값이라 여기에도 안 섞는다.
// ══════════════════════════════════════════════════════════════

// 지금 열려 있는 리포트 — 엑셀 내려받기가 다시 조회하지 않도록 담아 둔다.
let _openReport = null;

// 시각 표기 — 🔴 **공용 헬퍼를 쓴다. 여기서 새로 만들지 않는다**(2026-09-03 사용자 지적).
//   `formatDateTime`(ui.js) = `2026/09/03 22:11` — 관리자 화면 전체가 쓰는 표기다.
//   처음엔 여기서 `toLocaleString` 을 직접 불러 **초까지 나오고 다른 화면과도 달랐다.**
//   ⚠️ 표기를 바꿀 일이 생기면 `ui.js` 의 그 함수를 고친다 — 여기에 사본을 만들면
//      화면마다 날짜 모양이 갈린다(이 저장소가 같은 판정을 여러 벌 둬서 겪은 문제와 같다).

// 16칸 머리글 — 사양서 「표 양식 (구글시트 16칸 그대로)」
const REPORT_COLS = [
  {key:'no',                  label:'No.',              w:'46px'},
  {key:'account_id',          label:'ID',               w:'190px'},
  {key:'campaign_name',       label:'캠페인명',          w:'200px'},
  {key:'purchase_period',     label:'구매기간',          w:'170px'},
  {key:'status',              label:'상태',             w:'110px'},
  {key:'order_no',            label:'주문 번호',         w:'120px'},
  {key:'purchase_date',       label:'구매일',            w:'100px'},
  {key:'amount',              label:'구매금액',          w:'100px'},
  {key:'receipt_url',         label:'구매 영수증 (URL)',  w:'150px'},
  {key:'receipt_uploaded_at', label:'업로드 날짜',        w:'150px'},
  {key:'name_kanji',          label:'이름 (한자)',        w:'110px'},
  {key:'name_kana',           label:'이름 (일본어)',      w:'110px'},
  {key:'ch_qoo10_url',        label:'큐텐 결과물 (URL)',  w:'150px'},
  {key:'ch_qoo10_at',         label:'업로드 날짜',        w:'150px'},
  {key:'ch_cosme_url',        label:'엣코스메 결과물 (URL)', w:'150px'},
  {key:'ch_cosme_at',         label:'업로드 날짜',        w:'150px'},
];

// 13·15번 칸을 그린다 — 주소와 함께 **무엇인지**(사진/게시물)를 작게 적는다.
//   ⚠️ 한 칸에 두 가지가 섞이므로 표시가 없으면 브랜드가 읽는 표에서 사고가 된다.
// 🔴 **사진과 게시물은 여는 방법이 다르다.**
//   사진(`review_image`)  = 우리 저장소의 이미지 → **모달**(관리자 이미지 확대 창)로 연다.
//   게시물(`post`)        = 인스타·큐텐 같은 **바깥 사이트 주소** → 새 탭으로 연다.
//   ⚠️ 바깥 사이트는 모달(액자) 안에 못 넣는다 — 그 사이트들이 액자 삽입을 막는다
//      (X-Frame-Options). 억지로 넣으면 **빈 흰 상자**가 뜨고 원인도 안 보인다.
//   그래서 게시물에는 ↗ 를 붙여 **새 탭으로 나간다는 것을 미리** 알린다.
function _reportChannelCellHtml(url, kind) {
  if (!url) return '';
  // 외부(포인테일) 증빙은 여러 장이 줄바꿈으로 온다 — 한 장씩 「사진 1·2·3」으로 각각 연다.
  const list = String(url).split(/\r?\n/).map(function(u){ return u.trim(); }).filter(Boolean);
  if (list.length > 1) {
    return list.map(function(u, i){ return `<a href="javascript:void(0)" onclick="openImageLightbox('${esc(u)}')">사진 ${i+1}</a>`; }).join(' · ');
  }
  url = list[0] || url;
  const tag = kind === 'photo' ? '사진' : (kind === 'post' ? '게시물' : '');
  const tagHtml = tag ? `<span style="display:inline-block;margin-left:4px;padding:0 4px;border-radius:3px;background:var(--line);color:var(--muted);font-size:10px">${tag}</span>` : '';
  if (kind === 'photo') {
    return `<a href="javascript:void(0)" onclick="openImageLightbox('${esc(url)}')">열기</a>${tagHtml}`;
  }
  return `<a href="${esc(url)}" target="_blank" rel="noopener">열기 ↗</a>${tagHtml}`;
}

function _reportRowHtml(r) {
  const cells = REPORT_COLS.map(function(c) {
    if (c.key === 'receipt_url') {
      // 영수증은 우리 저장소의 이미지라 모달로 연다(검수 화면과 같은 확대 창).
      if (!r.receipt_url) return '<td></td>';
      const rl = String(r.receipt_url).split(/\r?\n/).map(function(u){ return u.trim(); }).filter(Boolean);
      return '<td>' + (rl.length > 1
        ? rl.map(function(u, i){ return `<a href="javascript:void(0)" onclick="openImageLightbox('${esc(u)}')">사진 ${i+1}</a>`; }).join(' · ')
        : `<a href="javascript:void(0)" onclick="openImageLightbox('${esc(rl[0])}')">열기</a>`) + '</td>';
    }
    if (c.key === 'ch_qoo10_url') return `<td>${_reportChannelCellHtml(r.ch_qoo10_url, r.ch_qoo10_kind)}</td>`;
    if (c.key === 'ch_cosme_url') return `<td>${_reportChannelCellHtml(r.ch_cosme_url, r.ch_cosme_kind)}</td>`;
    if (c.key === 'amount') {
      // ⚠️ Number(null) 이 0 이라 빈 값을 먼저 거른다 — 안 하면 「¥0」으로 그려진다.
      return `<td style="text-align:right">${r.amount === '' || r.amount === null || r.amount === undefined ? '' : '¥' + Number(r.amount).toLocaleString('ja-JP')}</td>`;
    }
    if (c.key === 'receipt_uploaded_at' || c.key === 'ch_qoo10_at' || c.key === 'ch_cosme_at') {
      return `<td style="font-size:11px">${esc(formatDateTime(r[c.key]))}</td>`;
    }
    return `<td>${esc(String(r[c.key] === null || r[c.key] === undefined ? '' : r[c.key]))}</td>`;
  }).join('');
  // 맨 앞 「구분」 열 — 🔴 **관리자 화면에만** 있다. 공유 화면·엑셀에는 넣지 않는다.
  return `<tr><td style="text-align:center;font-weight:600">${esc(r.src || '')}</td>${cells}</tr>`;
}

async function openReport(reportId) {
  const pane = document.getElementById('adminPane-reports');
  if (!pane) return;
  pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';

  const rep = await fetchCampaignReport(reportId);
  if (!rep) {
    pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--pink);font-size:13px">리포트를 찾지 못했습니다.<br><button class="btn btn-ghost btn-xs" style="margin-top:12px" onclick="loadReportsPane()">목록으로</button></div>';
    return;
  }

  const camps = (rep.campaigns || []).map(function(c) {
    return {id: c.campaign_id, campaign_no: c.campaign_no, title: c.campaign_title, _exists: c.campaign_exists};
  });
  const liveIds = camps.filter(function(c){ return c.id; }).map(function(c){ return c.id; });

  // 🔴 REVERB 결과물은 **여기서 방금** 조회한다 — 이 시각이 화면의 첫 줄이 된다.
  const reverbQueriedAt = new Date().toISOString();
  const delivs = liveIds.length ? await fetchDeliverablesForReport(liveIds) : [];
  const uids = [...new Set((delivs || []).map(function(d){ return d.user_id; }).filter(Boolean))];
  const users = await fetchInfluencersForReport(uids);

  // ⚠️ 감사용 계정은 만들 때 정한 대로 뺀다 — 그 선택을 저장해 둔 이유가 이것이다.
  let rows = buildReportRows(delivs, camps, users);
  if (!rep.include_audit && users) {
    rows = rows.filter(function(r){ const u = users[r._user_id]; return !(u && u.is_audit); });
    rows.forEach(function(r, i){ r.no = i + 1; });   // 뺀 뒤 번호를 다시 매긴다
  }

  // 외부(포인테일 등) — 첨부 목록과 참가자 행. 「붙인 시각」은 가장 늦게 붙인 것.
  const sources = rep.sources || [];
  const extAttachedAt = sources.length ? sources.map(function(s){ return s.attached_at; }).sort().slice(-1)[0] : null;
  const extRows = sources.length ? await fetchReportExtRows(sources.map(function(s){ return s.id; })) : [];
  const extFailed = (extRows === null);
  const srcById = {}; sources.forEach(function(s){ srcById[s.id] = s; });
  const extStd = (extRows || []).map(function(r) { return _reportExtToRow(r, srcById[r.source_id]); });
  // 🔴 REVERB 행 뒤에 외부 행을 잇고 번호를 다시 매긴다 — 한 표에서 「구분」 열로만 갈린다.
  rows = rows.concat(extStd);
  rows.forEach(function(r, i){ r.no = i + 1; });
  const maskedN = extStd.filter(function(r){ return /\*\*/.test(r.account_id || ''); }).length;
  const deletedCount = camps.filter(function(c){ return !c._exists; }).length;
  const purchaseN = rows.filter(function(r){ return r.receipt_url; }).length;
  const reviewN   = rows.filter(function(r){ return r.ch_qoo10_url || r.ch_cosme_url; }).length;

  _openReport = {id: reportId, title: rep.title, rows: rows, reverbQueriedAt: reverbQueriedAt};

  pane.innerHTML = `
    <div class="admin-card">
      <div class="admin-card-header" style="align-items:flex-start">
        <div>
          <div style="display:flex;align-items:center;gap:8px">
            <button class="btn btn-ghost btn-xs" onclick="loadReportsPane()"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">arrow_back</span> 목록</button>
            <span class="admin-card-title">${esc(rep.title || '(제목 없음)')}</span>
          </div>
          <div style="margin-top:8px;font-size:12px;color:var(--muted);line-height:1.9">
            <div>만든 사람 ${esc(rep.created_by_name || '-')} · 만든 날 ${esc(formatDateTime(rep.created_at))}</div>
            <!-- 🔴 두 시각은 반드시 서로 다른 줄이다. 합치면 브랜드가 외부 데이터도 방금 것으로 읽는다. -->
            <div><strong>REVERB</strong> — 방금 조회 (${esc(formatDateTime(reverbQueriedAt))})</div>
            <div><strong>외부</strong> — ${extAttachedAt ? esc(formatDateTime(extAttachedAt)) + ' 기준' : '붙인 파일 없음'}</div>
          </div>
        </div>
        <div style="display:flex;gap:6px">
          <button class="btn btn-ghost btn-xs" onclick="exportReportExcel('${esc(reportId)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">download</span> 엑셀 내려받기</button>
          <button class="btn btn-ghost btn-xs" onclick="openReportRenameModal('${esc(reportId)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">edit</span> 제목 수정</button>
          <button class="btn btn-ghost btn-xs" onclick="openAddCampaignsToReport('${esc(reportId)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">add</span> 캠페인 추가</button>
          <button class="btn btn-ghost btn-xs" onclick="openAddSourceToReport('${esc(reportId)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">attach_file</span> 파일 붙이기</button>
          <button class="btn btn-ghost btn-xs" style="color:var(--pink)" onclick="openReportDeleteModal('${esc(reportId)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">delete</span> 삭제</button>
        </div>
      </div>

      <div style="padding:12px 16px;border-bottom:1px solid var(--line);font-size:13px;line-height:2">
        <strong>요약</strong> · 캠페인 ${camps.length}개 · 인원 ${rows.length}명 (REVERB ${rows.length - extStd.length} · 외부 ${extStd.length}) · 구매 ${purchaseN} · 리뷰 ${reviewN}
        <div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px">
          ${(rep.campaigns || []).map(function(c) {
            // ⚠️ 원본이 지워진 줄은 회색으로, 이름은 그대로(스냅샷). 뺄 수는 있다.
            const dead = !c.campaign_exists;
            // 칩 모양은 관리자 계정 「메일받기」 셀과 같은 badge badge-gray (admin-accounts.js).
            return `<span class="badge badge-gray" style="display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:2px 8px;border-radius:8px;${dead ? 'opacity:.55;text-decoration:line-through' : ''}" title="${dead ? '원본 캠페인이 지워졌습니다' : ''}">
              ${esc(c.campaign_no || '')} ${esc(c.campaign_title || '')}
              <button type="button" onclick="removeCampaignFromReport('${esc(reportId)}','${esc(c.row_id)}')" title="이 캠페인을 리포트에서 뺍니다" style="border:0;background:none;padding:0;cursor:pointer;line-height:1"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--muted)">close</span></button>
            </span>`;
          }).join('')}
        </div>
        ${deletedCount > 0 ? `<div style="color:var(--pink);font-size:12px">⚠️ 담긴 캠페인 중 ${deletedCount}개는 원본이 지워져 이름만 남아 있습니다 — 그 캠페인의 결과물은 표에 없습니다.</div>` : ''}
        ${rep.include_audit ? '<div style="color:var(--muted);font-size:12px">감사용 계정을 포함해 만든 리포트입니다.</div>' : ''}
        ${users === null ? '<div style="color:var(--pink);font-size:12px">⚠️ 회원 정보를 불러오지 못해 이름·계정 칸이 「?」로 표시됩니다.</div>' : ''}
        ${extFailed ? '<div style="color:var(--pink);font-size:12px">⚠️ 외부 참가자 행을 불러오지 못했습니다 — 표에 외부 행이 빠져 있습니다.</div>' : ''}
        ${sources.length ? `<div style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;align-items:center"><span style="font-size:12px;color:var(--muted)">외부 첨부</span>
          ${sources.map(function(s){ return `<span class="badge badge-gray" style="display:inline-flex;align-items:center;gap:4px;font-size:11px;padding:2px 8px;border-radius:8px" title="${esc(s.file_name || '')} · ${esc(formatDateTime(s.attached_at))} · ${esc(s.attached_by_name || '')}">
              ${esc(s.ext_campaign_no)} ${esc(s.ext_campaign_name)} · ${s.row_count}명
              <button type="button" onclick="removeSourceFromReport('${esc(reportId)}','${esc(s.id)}','${esc(s.ext_campaign_no)}')" title="이 첨부를 뗍니다" style="border:0;background:none;padding:0;cursor:pointer;line-height:1"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:var(--muted)">close</span></button>
            </span>`; }).join('')}</div>` : ''}
        ${maskedN ? '<div style="color:var(--muted);font-size:12px">포인테일이 이미 가려서 보낸 계정이 ' + maskedN + '건 있습니다(원본부터 ** 로 가려져 있음).</div>' : ''}
      </div>

      <div class="admin-table-wrap" style="overflow-x:auto">
        <table class="data-table" style="min-width:2100px">
          <thead><tr>
            <th style="width:50px;text-align:center">구분</th>
            ${REPORT_COLS.map(function(c){ return `<th style="width:${c.w}">${esc(c.label)}</th>`; }).join('')}
          </tr></thead>
          <tbody>
            ${rows.length ? rows.map(_reportRowHtml).join('')
              : `<tr><td colspan="17" style="padding:40px;text-align:center;color:var(--muted);font-size:13px">담긴 캠페인에 제출된 결과물이 없습니다.</td></tr>`}
          </tbody>
        </table>
      </div>
    </div>`;
}

// ══════════════════════════════════════════════════════════════
// 엑셀 내려받기 — 작업 10 (관리자용 = 전부 보이는 판)
//
// 🔴 **「구분」 열은 엑셀에 넣지 않는다**(확정된 결정 12).
//    관리자용·브랜드용 엑셀은 **값만 다르고 열 구성은 같아야** 어느 파일이 무엇인지
//    알아본다. 화면에만 있는 열이다.
// ══════════════════════════════════════════════════════════════

async function exportReportExcel(reportId) {
  // 화면에서 이미 조회한 것을 그대로 쓴다 — 다시 조회하면 화면과 다른 숫자가 나올 수 있다.
  let rows, title;
  if (_openReport && _openReport.id === reportId) {
    rows = _openReport.rows; title = _openReport.title;
  } else {
    if (typeof toast === 'function') toast('리포트를 먼저 열어 주세요');
    return;
  }
  try {
    await loadExcelJS();
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('리포트');
    ws.columns = REPORT_COLS.map(function(c) {
      return {header: c.label, key: c.key, width: Math.max(10, Math.round(parseInt(c.w, 10) / 8))};
    });
    ws.getRow(1).font = {bold: true};
    rows.forEach(function(r) {
      const o = {};
      REPORT_COLS.forEach(function(c) {
        // ⚠️ 구매금액은 숫자로 넣는다(엑셀에서 합계를 낼 수 있게). 빈 값은 빈칸.
        if (c.key === 'amount') { o[c.key] = (r.amount === '' || r.amount === null || r.amount === undefined) ? '' : Number(r.amount); }
        else { o[c.key] = (r[c.key] === null || r[c.key] === undefined) ? '' : r[c.key]; }
      });
      ws.addRow(o);
    });

    const buf = await wb.xlsx.writeBuffer();
    const blob = new Blob([buf], {type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    const t = new Date();
    const ymd = t.getFullYear() + String(t.getMonth()+1).padStart(2,'0') + String(t.getDate()).padStart(2,'0');
    // ⚠️ 파일 이름에 「_관리자용」을 붙여 브랜드용과 구분한다(사양서). 파일 이름에 못 쓰는 글자는 뺀다.
    a.download = String(title || '리포트').replace(/[\\/:*?"<>|]/g, '') + '_' + ymd + '_관리자용.xlsx';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    URL.revokeObjectURL(url);
    if (typeof toast === 'function') toast('엑셀 다운로드 완료 (' + rows.length + '행)');
  } catch (e) {
    console.error('[exportReportExcel]', e);
    if (typeof toast === 'function') toast('엑셀을 만들지 못했습니다 — ' + ((e && e.message) || e));
  }
}

// ══════════════════════════════════════════════════════════════
// 삭제 — 서버 함수(`delete_campaign_report`)는 403 에 이미 있었는데
//        화면 진입점이 없어 개발자 도구로만 지울 수 있었다.
//
// ⚠️ 되돌릴 수 없는 동작이라 **확인 창을 거친다.** 다만 캠페인 삭제처럼
//    제목을 다시 적게 하지는 않는다 — 리포트는 **다시 만들 수 있고**
//    원본(캠페인·결과물)은 하나도 안 지워진다. 확인 강도는 잃는 것에 맞춘다.
// ══════════════════════════════════════════════════════════════

function _reportCloseDeleteModal() {
  const m = document.getElementById('reportDeleteModal');
  if (m) m.remove();
}

async function openReportDeleteModal(reportId) {
  const rep = await fetchCampaignReport(reportId);
  if (!rep) { if (typeof toast === 'function') toast('리포트를 찾지 못했습니다'); return; }
  _reportCloseDeleteModal();
  const wrap = document.createElement('div');
  wrap.id = 'reportDeleteModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:460px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header">
        <h2>리포트 삭제</h2>
        <button class="modal-close" onclick="_reportCloseDeleteModal()"><span class="material-icons-round notranslate" translate="no">close</span></button>
      </div>
      <div class="modal-body">
        <p style="font-size:13px;line-height:1.8;margin:0">
          <strong>${esc(rep.title || '(제목 없음)')}</strong> 리포트를 지웁니다.
        </p>
        <p style="font-size:12px;color:var(--muted);line-height:1.8;margin:10px 0 0">
          담긴 캠페인 ${(rep.campaigns || []).length}개의 <strong>연결만</strong> 사라집니다.
          캠페인·결과물·인플루언서 데이터는 <strong>하나도 지워지지 않습니다.</strong><br>
          같은 캠페인으로 리포트를 다시 만들 수 있습니다.
        </p>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseDeleteModal()">취소</button>
        <button class="btn btn-danger" id="btnReportDeleteSubmit" onclick="submitReportDelete('${esc(reportId)}')">삭제</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
}

async function submitReportDelete(reportId) {
  const btn = document.getElementById('btnReportDeleteSubmit');
  if (btn) { btn.disabled = true; btn.textContent = '지우는 중…'; }
  const ok = await deleteCampaignReport(reportId);
  _reportCloseDeleteModal();
  if (ok === null) {
    // ⚠️ 실패(null)와 「이미 없음」(false)을 구분해 다르게 알린다.
    if (typeof toast === 'function') toast('지우지 못했습니다 — 잠시 뒤 다시 시도해 주세요');
    return;
  }
  if (typeof toast === 'function') toast(ok ? '리포트를 지웠습니다' : '이미 지워진 리포트입니다');
  await loadReportsPane();   // 목록으로 돌아간다(지운 리포트 화면에 머물면 안 된다)
}

// ══════════════════════════════════════════════════════════════
// 구성 바꾸기 — 작업 18 (캠페인 추가·빼기 · 제목 수정)
//   서버 함수는 407, 읽기의 row_id 는 408.
//   ⚠️ 작업표 순서(외부 첨부 뒤)보다 먼저 만들었다 — 사용자가 먼저 물었다(2026-09-03).
//      외부 첨부 갈아 끼우기(openReplaceSourceFile)는 그 표가 생길 때 더한다.
// ══════════════════════════════════════════════════════════════

// ── 제목 수정 ──
function _reportCloseRenameModal() { const m = document.getElementById('reportRenameModal'); if (m) m.remove(); }

async function openReportRenameModal(reportId) {
  const rep = await fetchCampaignReport(reportId);
  if (!rep) { toast('리포트를 찾지 못했습니다'); return; }
  _reportCloseRenameModal();
  const wrap = document.createElement('div');
  wrap.id = 'reportRenameModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:480px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>제목 수정</h2>
        <button class="modal-close" onclick="_reportCloseRenameModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body">
        <div class="form-group">
          <label class="form-label">리포트 제목 <span style="color:var(--pink)">*</span></label>
          <input type="text" class="form-input" id="reportRenameInput" maxlength="200" value="${esc(rep.title || '')}"
                 oninput="document.getElementById('btnReportRenameSubmit').disabled = !this.value.trim()">
        </div>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseRenameModal()">취소</button>
        <button class="btn btn-primary" id="btnReportRenameSubmit" onclick="submitReportRename('${esc(reportId)}')">저장</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  const i = document.getElementById('reportRenameInput'); if (i) { i.focus(); i.select(); }
}

async function submitReportRename(reportId) {
  const i = document.getElementById('reportRenameInput');
  const title = i ? i.value.trim() : '';
  if (!title) return;
  try {
    await updateReportTitle(reportId, title);
    _reportCloseRenameModal();
    toast('제목을 바꿨습니다');
    await openReport(reportId);      // 머리말을 다시 그린다(목록은 돌아갈 때 새로 읽는다)
  } catch (e) { toast('바꾸지 못했습니다 — ' + ((e && e.message) || e)); }
}

// ── 캠페인 빼기 ──
//   ⚠️ 확인 창을 거친다 — 되돌리려면 다시 추가해야 하고, 인원이 줄어드는 변경이다.
//      다만 원본은 하나도 안 지워지므로 이름 재입력까지는 요구하지 않는다.
async function removeCampaignFromReport(reportId, rowId) {
  const rep = await fetchCampaignReport(reportId);
  const c = rep && (rep.campaigns || []).find(function(x){ return x.row_id === rowId; });
  if (!c) { toast('이미 빠진 캠페인입니다'); await openReport(reportId); return; }
  if ((rep.campaigns || []).length <= 1) {
    toast('마지막 캠페인은 뺄 수 없습니다. 리포트를 지워 주세요');
    return;
  }
  if (!window.confirm('「' + (c.campaign_no || '') + ' ' + (c.campaign_title || '') + '」을(를) 리포트에서 뺍니다.\n그 캠페인의 결과물이 표에서 사라집니다. 계속할까요?')) return;
  try {
    await removeReportCampaign(reportId, rowId);
    toast('뺐습니다');
    await openReport(reportId);
  } catch (e) { toast('빼지 못했습니다 — ' + ((e && e.message) || e)); }
}

// ── 캠페인 추가 ──
//   일괄발송 모달(admin-messaging.js)과 같은 검색형 다중 선택기(syncCampMultiFilter)를 쓴다.
//   ⚠️ 그 선택기는 「전체 체크 = 빈 배열」이라는 **필터 뜻**을 갖는다 — 여기서는 명시 선택만
//      받아야 하므로, 전체가 체크된 경우를 「보이는 것 전부」로 바꿔 읽는다(일괄발송과 같은 처리).
let _reportAddCandidates = [];

function _reportCloseAddModal() { const m = document.getElementById('reportAddCampModal'); if (m) m.remove(); }

async function openAddCampaignsToReport(reportId) {
  const rep = await fetchCampaignReport(reportId);
  if (!rep) { toast('리포트를 찾지 못했습니다'); return; }
  // 딥링크로 들어와 목록이 안 실려 있을 수 있다 → 폴백 조회(운영현황 진입과 같은 함정)
  let camps = Array.isArray(allCampaigns) && allCampaigns.length ? allCampaigns : null;
  if (!camps) { camps = await fetchCampaigns(); }
  const have = new Set((rep.campaigns || []).map(function(c){ return c.campaign_id; }).filter(Boolean));
  _reportAddCandidates = (camps || []).filter(function(c){ return !have.has(c.id) && !c.deleted_at; });

  _reportCloseAddModal();
  const wrap = document.createElement('div');
  wrap.id = 'reportAddCampModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:560px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>캠페인 추가</h2>
        <button class="modal-close" onclick="_reportCloseAddModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body">
        <p style="font-size:12px;color:var(--muted);margin:0 0 8px">이미 담긴 캠페인 ${have.size}개는 목록에서 뺐습니다.</p>
        <div id="reportAddCampMulti" class="mf-wrap" style="max-width:100%"><button type="button" class="mf-btn" style="width:100%;overflow:hidden;text-overflow:ellipsis">캠페인을 선택하세요</button><div class="mf-drop" style="min-width:100%"></div></div>
        <div id="reportAddCampCount" style="font-size:12px;color:var(--muted);margin-top:8px"></div>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseAddModal()">취소</button>
        <button class="btn btn-primary" id="btnReportAddSubmit" onclick="submitAddCampaignsToReport('${esc(reportId)}')" disabled>추가</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  syncCampMultiFilter('reportAddCampMulti', _reportAddCandidates, _onReportAddCampChange, null);
  // ⚠️ 선택기는 처음에 「전체 체크」로 시작한다 — 그대로 두면 「전부 추가」로 읽힌다. 전부 풀고 시작.
  if (typeof clearMultiFilter === 'function') clearMultiFilter('reportAddCampMulti', '캠페인을 선택하세요');
  _onReportAddCampChange();
}

function _reportSelectedAddIds() {
  let ids = getMultiFilterValues('reportAddCampMulti');
  if (!ids.length) {
    const wrap = document.getElementById('reportAddCampMulti');
    const allCb = wrap && wrap.querySelector('input[value="all"]');
    if (allCb && allCb.checked && !allCb.indeterminate) ids = _reportAddCandidates.map(function(c){ return c.id; });
  }
  return ids;
}

function _onReportAddCampChange() {
  const ids = _reportSelectedAddIds();
  const cnt = document.getElementById('reportAddCampCount');
  const btn = document.getElementById('btnReportAddSubmit');
  if (cnt) cnt.textContent = ids.length ? ids.length + '개 선택' : '';
  if (btn) btn.disabled = !ids.length;
}

async function submitAddCampaignsToReport(reportId) {
  const ids = _reportSelectedAddIds();
  if (!ids.length) return;
  const btn = document.getElementById('btnReportAddSubmit');
  if (btn) { btn.disabled = true; btn.textContent = '추가하는 중…'; }
  try {
    const n = await addReportCampaigns(reportId, ids);
    _reportCloseAddModal();
    toast(n + '개를 더했습니다' + (n < ids.length ? ' (이미 담긴 ' + (ids.length - n) + '개는 건너뜀)' : ''));
    await openReport(reportId);
  } catch (e) {
    if (btn) { btn.disabled = false; btn.textContent = '추가'; }
    toast('더하지 못했습니다 — ' + ((e && e.message) || e));
  }
}

// ══════════════════════════════════════════════════════════════
// 외부 서비스 블록 — 작업 15 (만들기 모달 · 기존 리포트 「파일 붙이기」 공용)
//   파일은 브라우저에서 읽어 **파싱 결과만** 서버에 보낸다. 원본 파일은 저장하지 않는다.
//   파일 고르기는 인플루언서 증빙 첨부와 같은 「라벨 안에 숨긴 <input type=file>」 패턴.
// ══════════════════════════════════════════════════════════════

// 블록 상태 — 모달이 열려 있는 동안만 산다. { idx, service, extNo, extName, fileName, parsed, busy, error }
let _reportSrcBlocks = [];
let _reportSrcSeq = 0;

function _reportSrcContainer() { return document.getElementById('reportSrcBlocks'); }

function _reportSrcBlockHtml(b) {
  const opts = REPORT_SERVICES.map(function(s){ return `<option value="${s.code}" ${b.service===s.code?'selected':''}>${esc(s.label)}</option>`; }).join('');
  let fileLine;
  if (b.busy) fileLine = '<span style="color:var(--muted)">읽는 중…</span>';
  else if (b.error) fileLine = `<span style="color:var(--pink)">${esc(b.error)}</span>`;
  else if (b.parsed) {
    const s = b.parsed.summary;
    fileLine = `<span style="color:var(--ink)">✓ ${s.people}명 · 구매 ${s.buyers} / 리뷰 텍스트 ${s.reviewText} · 포토 ${s.reviewPhoto}${s.hasCosme ? ' · @cosme ' + s.cosme : ''} / 완료 ${s.completed}</span>`
             + (s.maskedAccounts ? `<div style="font-size:11px;color:var(--muted)">포인테일이 이미 가려서 보낸 계정 ${s.maskedAccounts}건</div>` : '');
  } else fileLine = '<span style="color:var(--muted)">파일을 고르세요 (.xlsx)</span>';
  const bad = b.touched && (!b.extNo.trim() || !b.extName.trim() || !b.parsed);
  return `
    <div id="reportSrcBlock-${b.idx}" style="border:1px solid ${bad ? 'var(--pink)' : 'var(--line)'};border-radius:8px;padding:10px 12px;margin-bottom:8px">
      <div style="display:flex;gap:8px;align-items:center;margin-bottom:8px">
        <select class="form-input" style="flex:0 0 180px" onchange="_reportSrcSet(${b.idx},'service',this.value)">${opts}</select>
        <button type="button" class="btn btn-ghost btn-xs" style="margin-left:auto;color:var(--pink)" onclick="removeSourceBlock(${b.idx})">삭제</button>
      </div>
      <div style="display:grid;grid-template-columns:1fr 2fr;gap:8px;margin-bottom:8px">
        <input type="text" class="form-input" placeholder="캠페인 번호 (예: 102905)" value="${esc(b.extNo)}" oninput="_reportSrcSet(${b.idx},'extNo',this.value)">
        <input type="text" class="form-input" placeholder="캠페인명 (표에 이대로 실립니다)" value="${esc(b.extName)}" oninput="_reportSrcSet(${b.idx},'extName',this.value)">
      </div>
      <div style="display:flex;align-items:center;gap:10px;font-size:12px">
        <label style="display:inline-flex;align-items:center;gap:4px;color:var(--pink);cursor:pointer;flex-shrink:0">
          <input type="file" accept=".xlsx" style="display:none" onchange="_reportSrcFile(${b.idx}, this)">
          <span class="material-icons-round notranslate" translate="no" style="font-size:14px">attach_file</span><span>엑셀 파일</span>
        </label>
        <span style="flex:1;min-width:0">${b.fileName ? '<span style="color:var(--muted)">' + esc(b.fileName) + ' · </span>' : ''}${fileLine}</span>
      </div>
    </div>`;
}

function _reportSrcRender() {
  const c = _reportSrcContainer();
  if (!c) return;
  c.innerHTML = _reportSrcBlocks.map(_reportSrcBlockHtml).join('')
    || '<div style="font-size:12px;color:var(--muted);padding:6px 0">붙인 파일이 없습니다. 없어도 만들 수 있습니다.</div>';
  _reportSrcSyncSubmit();
}

// 만들기/붙이기 버튼 — 읽는 중이거나 한 칸이라도 비면 못 누른다
function _reportSrcAllValid() {
  return _reportSrcBlocks.every(function(b){ return !b.busy && b.extNo.trim() && b.extName.trim() && b.parsed; });
}
function _reportSrcSyncSubmit() {
  const btn = document.getElementById('btnReportCreateSubmit') || document.getElementById('btnReportAttachSubmit');
  if (!btn) return;
  const title = document.getElementById('reportCreateTitle');
  const titleOk = title ? !!title.value.trim() : true;
  btn.disabled = !(titleOk && _reportSrcAllValid() && (btn.id !== 'btnReportAttachSubmit' || _reportSrcBlocks.length > 0));
}

function addSourceBlock() {
  _reportSrcBlocks.push({ idx: ++_reportSrcSeq, service: 'pointail', extNo: '', extName: '', fileName: '', parsed: null, busy: false, error: '', touched: false });
  _reportSrcRender();
}
function removeSourceBlock(idx) {
  _reportSrcBlocks = _reportSrcBlocks.filter(function(b){ return b.idx !== idx; });
  _reportSrcRender();
}
function _reportSrcSet(idx, key, val) {
  const b = _reportSrcBlocks.find(function(x){ return x.idx === idx; });
  if (!b) return;
  b[key] = val; b.touched = true;
  // 값만 바뀌면 다시 그리지 않는다(입력 초점을 잃는다) — 버튼 상태·테두리만 갱신
  const el = document.getElementById('reportSrcBlock-' + idx);
  if (el) el.style.borderColor = (!b.extNo.trim() || !b.extName.trim() || !b.parsed) ? 'var(--pink)' : 'var(--line)';
  _reportSrcSyncSubmit();
}

async function _reportSrcFile(idx, input) {
  const b = _reportSrcBlocks.find(function(x){ return x.idx === idx; });
  const f = input && input.files && input.files[0];
  if (!b || !f) return;
  b.fileName = f.name; b.busy = true; b.error = ''; b.parsed = null; b.touched = true;
  _reportSrcRender();
  try {
    const buf = await f.arrayBuffer();
    const parser = REPORT_PARSERS[b.service];
    const res = parser ? await parser(buf) : { ok:false, reason:'모르는 서비스입니다' };
    if (!res.ok) { b.error = res.reason || '읽지 못했습니다'; }
    else {
      b.parsed = res;
      // 파일 이름에 번호가 있으면 비어 있는 번호 칸을 채워 준다 — (260903)캠페인 리포트_102905.xlsx
      if (!b.extNo.trim()) { const m = f.name.match(/_(\d{4,})/); if (m) b.extNo = m[1]; }
    }
  } catch (e) { b.error = '읽는 중 오류 — ' + ((e && e.message) || e); }
  b.busy = false;
  _reportSrcRender();
}

// 블록들을 서버에 저장한다(만들기 직후 · 붙이기 모달 공용). 실패한 블록 이름을 돌려준다.
async function _reportSrcSaveAll(reportId) {
  const failed = [];
  for (const b of _reportSrcBlocks) {
    if (!b.parsed) continue;
    try { await addReportSource(reportId, b.service, b.extNo.trim(), b.extName.trim(), b.fileName, b.parsed.rows); }
    catch (e) { failed.push(b.extName || b.extNo); console.error('[reportSrcSave]', e); }
  }
  return failed;
}

// ── 기존 리포트에 「파일 붙이기」 ──
function _reportCloseAttachModal() { const m = document.getElementById('reportAttachModal'); if (m) m.remove(); _reportSrcBlocks = []; }

async function openAddSourceToReport(reportId) {
  const rep = await fetchCampaignReport(reportId);
  if (!rep) { toast('리포트를 찾지 못했습니다'); return; }
  _reportCloseAttachModal();
  _reportSrcBlocks = [];
  const have = (rep.sources || []);
  const wrap = document.createElement('div');
  wrap.id = 'reportAttachModal';
  wrap.className = 'modal-overlay open';
  wrap.innerHTML = `
    <div class="modal" style="max-width:640px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>외부 결과물 붙이기</h2>
        <button class="modal-close" onclick="_reportCloseAttachModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="overflow-y:auto">
        ${have.length ? '<p style="font-size:12px;color:var(--muted);margin:0 0 8px">이미 붙은 것: ' + have.map(function(s){ return esc(s.ext_campaign_no + ' ' + s.ext_campaign_name); }).join(' · ') + '<br>같은 번호를 다시 붙이면 <strong>그 파일이 갱신</strong>됩니다.</p>' : ''}
        <div id="reportSrcBlocks"></div>
        <button type="button" class="btn btn-ghost btn-xs" onclick="addSourceBlock()"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">add</span> 추가</button>
        <p style="font-size:11px;color:var(--muted);margin:10px 0 0;line-height:1.7">파일은 이 브라우저에서 읽어 <strong>참가자 행만</strong> 저장합니다. 원본 파일은 저장하지 않습니다.</p>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseAttachModal()">취소</button>
        <button class="btn btn-primary" id="btnReportAttachSubmit" onclick="submitAttachSources('${esc(reportId)}')" disabled>붙이기</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  addSourceBlock();
}

async function submitAttachSources(reportId) {
  if (!_reportSrcAllValid() || !_reportSrcBlocks.length) return;
  // 같은 번호가 이미 있으면 갱신임을 되묻는다(사양서 ⑩ — 추가가 아니라 갱신)
  const rep = await fetchCampaignReport(reportId);
  const dup = _reportSrcBlocks.filter(function(b){ return (rep.sources||[]).some(function(s){ return s.service_code===b.service && s.ext_campaign_no===b.extNo.trim(); }); });
  if (dup.length && !window.confirm('「' + dup.map(function(b){ return b.extNo; }).join('」·「') + '」은(는) 이미 붙어 있습니다.\n새 파일로 갱신할까요? (이전 행은 전부 교체됩니다)')) return;
  const btn = document.getElementById('btnReportAttachSubmit');
  if (btn) { btn.disabled = true; btn.textContent = '저장 중…'; }
  const failed = await _reportSrcSaveAll(reportId);
  _reportCloseAttachModal();
  toast(failed.length ? '일부 실패 — ' + failed.join(', ') : '붙였습니다');
  await openReport(reportId);
}

async function removeSourceFromReport(reportId, sourceId, label) {
  if (!window.confirm('「' + label + '」 첨부를 뗍니다. 그 참가자 행이 표에서 사라집니다. 계속할까요?')) return;
  try { await removeReportSource(sourceId); toast('뗐습니다'); await openReport(reportId); }
  catch (e) { toast('떼지 못했습니다 — ' + ((e && e.message) || e)); }
}
