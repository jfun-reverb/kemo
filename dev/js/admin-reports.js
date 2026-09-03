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
    const camp = campById.get(g.campaign_id) || g.campaign || {};
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

// ══════════════════════════════════════════════════════════════
// 만들기 창 — 작업 7
//
// 🔴 **모달 상자를 `dev/admin/index.html` 에 넣지 않는다.** 여기서 동적으로 만든다
//    (오리엔시트 모달 선례). 그래야 뒤 조각들이 그 핫스팟 파일을 다시 안 만진다.
// ══════════════════════════════════════════════════════════════

function _reportCloseCreateModal() {
  const m = document.getElementById('reportCreateModal');
  if (m) m.remove();
}

// 제목이 비면 「리포트 만들기」를 못 누르게 한다.
function _reportSyncCreateBtn() {
  const t = document.getElementById('reportCreateTitle');
  const b = document.getElementById('btnReportCreateSubmit');
  if (t && b) b.disabled = !t.value.trim();
}

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
    <div class="modal" style="max-width:560px">
      <div class="modal-header">
        <h3>리포트 만들기</h3>
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
        <p style="font-size:12px;color:var(--muted);margin:10px 0 0;line-height:1.7">
          외부 서비스(포인테일 등) 결과물 붙이기는 다음 단계에서 열립니다.
        </p>
      </div>
      <div class="modal-footer">
        <button class="btn btn-ghost" onclick="_reportCloseCreateModal()">취소</button>
        <button class="btn btn-primary" id="btnReportCreateSubmit" onclick="submitReportCreate()" disabled>리포트 만들기</button>
      </div>
    </div>`;
  document.body.appendChild(wrap);
  const t = document.getElementById('reportCreateTitle');
  if (t) t.focus();
}

async function submitReportCreate() {
  const t = document.getElementById('reportCreateTitle');
  const btn = document.getElementById('btnReportCreateSubmit');
  const title = t ? t.value.trim() : '';
  if (!title) return;
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
    _reportCloseCreateModal();
    if (typeof toast === 'function') toast('리포트를 만들었습니다');
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
    return `<tr>
      <td><strong>${esc(r.title || '(제목 없음)')}</strong></td>
      <td style="text-align:center">${nCamp}</td>
      <td style="text-align:center">${nExt}</td>
      <td>${esc(r.created_by_name || '-')}</td>
      <td>${fmtDate(r.created_at)}</td>
      <td>${fmtDate(r.updated_at)}</td>
    </tr>`;
  }).join('');
}
