// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-applications.js
// ═════════════════════════════════════════════════════════════════
//
// 신청 관리 + 캠페인별 신청자 페인 (admin.js 파일 분리).
//   · 신청 관리 목록/필터/정렬/승인·반려·되돌리기 (loadApplications/renderAppCampList 등)
//   · 캠페인별 신청자 페인 (OT 발송 체크 + 결과물 상태 셀, loadCampApplicants 등)
//   · 상태: currentCampApplicantId/campApplicantsLazy/CAMP_APPLICANTS_PAGE_SIZE/
//     currentAppTypeTab/currentAppCampId/appSortKey/appSortDir/appLazy/APP_PAGE_SIZE/_appListCache
//
// ⚠ loadApplications/loadCampApplicants 는 switchAdminPane(admin-core.js) loaders 가,
//   renderAppCampList 는 initMultiFilters(admin-core.js) onChange + 캠페인 목록(admin.js)이
//   호출 → 전역 유지(이름 변경 금지). 빌드 순서상 admin.js 앞.
// ═════════════════════════════════════════════════════════════════

// 캠페인별 신청자 표시
let currentCampApplicantId = null;
// 진입 출처 — 'campaigns'(캠페인 관리 목록) / 'brand-ops'(운영현황 브랜드 상세). 뒤로가기 분기용
var _campApplicantsFrom = 'campaigns';
// ════════════════════════════════════════════════════════════════════
// SECTION: CAMP-APPLICANTS — 캠페인별 신청자 페인 (OT + 결과물 셀)
// ════════════════════════════════════════════════════════════════════

async function openCampApplicants(campId, campTitle, from) {
  currentCampApplicantId = campId;
  // 다른 캠페인을 열 때 탭·인증 상태 필터를 초기화 (직전 캠페인의 필터가 남아 「0건」으로 보이는 혼란 방지)
  _campDetailTab = 'applicants';
  _campAppStatusTab = '';
  _campDelivCertTab = '';
  const _rf = $('campDelivReviewFilter'); if (_rf) _rf.value = '';
  _campDelivCertFrom = ''; _campDelivCertTo = '';
  if (_campDelivCertFp) _campDelivCertFp.clear(false);
  const _cr = $('campDelivCertRange'); if (_cr) _cr.classList.remove('filter-active');
  const _cb = $('btnCampDelivCertClear'); if (_cb) _cb.style.display = 'none';
  const _sq = $('campAppSearch'); if (_sq) _sq.value = '';
  applyCampDetailTabVisibility();
  _campApplicantsFrom = (from === 'brand-ops') ? 'brand-ops' : 'campaigns';
  // 제목: 인자로 받으면 즉시 표시, 없으면 loadCampApplicants 가 캠페인 조회 후 보강
  $('campApplicantsTitle').textContent = campTitle || '';
  const backBtn = $('campApplicantsBackBtn');
  if (backBtn) {
    if (_campApplicantsFrom === 'brand-ops') {
      backBtn.textContent = '← 운영 현황';
      backBtn.onclick = () => switchAdminPane('brand-ops-detail');
    } else {
      backBtn.textContent = '← 캠페인 목록으로';
      backBtn.onclick = () => switchAdminPane('campaigns', null);
    }
  }
  switchAdminPane('camp-applicants', null);
  loadCampApplicants();
}

var campApplicantsLazy = null;
const CAMP_APPLICANTS_PAGE_SIZE = 50;

async function loadCampApplicants() {
  const filter = _campAppStatusTab || '';   // 신청 상태 탭(단일, ''=전체) — 구 드롭다운 대체
  const searchQ = ($('campAppSearch')?.value || '').trim().toLowerCase();
  await loadApplicantMsgUnread();  // 응모건 메시지 본인 미열람 배지 맵
  let apps = await fetchApplications({campaign_id: currentCampApplicantId});
  const _users = await fetchInfluencers();            // 행 렌더 + 감사용 격리 공용 (1회 로드)
  const _auditIds = buildAuditIdSet(_users);          // 감사용 응모는 빈자리·모집현황 집계에서 제외
  const allApps = apps.slice();  // 필터 적용 전 전체 — 상단 요약 카드 집계용
  const total = apps.length;
  const allApproved = countNonAuditApproved(apps, null, _auditIds);  // 감사용 제외 승인 수(빈자리·진행바용)
  const allPending = apps.filter(a => a.status === 'pending' && !_auditIds.has(a.user_id)).length;
  if (filter) apps = apps.filter(a=>a.status===filter);
  if (searchQ) {
    // 단어 단위 AND 매칭 (matchSearchTokens, 전각/반각 공백 무관)
    apps = apps.filter(a => {
      const u = _users.find(x => x.email === a.user_email) || {};
      return matchSearchTokens(searchQ, [
        a.user_name, a.user_email,
        u.name_kanji, u.name, u.name_kana,
        a.ig_id, a.user_ig,
        u.ig, u.x, u.tiktok, u.youtube,
      ]);
    });
  }
  // 신청 상태 탭 건수 — 자기 필터(상태)는 빼고 검색만 반영해야 탭을 눌러도 숫자가 안 흔들린다
  const searchedApps = searchQ
    ? allApps.filter(a => {
        const u = _users.find(x => x.email === a.user_email) || {};
        return matchSearchTokens(searchQ, [
          a.user_name, a.user_email,
          u.name_kanji, u.name, u.name_kana,
          a.ig_id, a.user_ig,
          u.ig, u.x, u.tiktok, u.youtube,
        ]);
      })
    : allApps;
  const appStatusCounts = { pending: 0, approved: 0, rejected: 0, cancelled: 0 };
  searchedApps.forEach(a => { if (appStatusCounts[a.status] != null) appStatusCounts[a.status]++; });
  renderCampAppStatusTabs(appStatusCounts);

  let camp = allCampaigns.find(c=>c.id===currentCampApplicantId);
  if (!camp) {
    // 운영현황 등에서 직접 진입해 캠페인 목록(allCampaigns)이 아직 안 채워진 경우 보장
    const all = await fetchCampaigns();
    camp = all.find(c=>c.id===currentCampApplicantId);
  }
  // 제목이 비어 있으면(운영현황 진입) 캠페인명으로 보강
  if (camp && !($('campApplicantsTitle')?.textContent || '').trim()) $('campApplicantsTitle').textContent = camp.title || '';
  // ★ 행사 판정은 **신청자 행을 그리기 전에** 정해야 한다. 행 안의 「미승인」 버튼이 이 값을
  //   문자열로 구워 넣는데, 목록은 그 뒤로 다시 그려지지 않는다. 아래쪽에서 정하면 직전
  //   캠페인의 값(또는 초기값 false)이 구워져 **행사인데 안전 확인창이 안 뜬다**
  //   — 가장 흔한 경로(다른 캠페인 → 행사 캠페인)에서 정확히 안 뜬다(2026-08-04 리뷰 지적).
  _campDetailIsEvent = (typeof isEventCampaign === 'function') && isEventCampaign(camp);

  const slots = camp?.slots || 0;
  const remaining = Math.max(slots - allApproved, 0);
  $('campApplicantsSlots').innerHTML = `모집 인원: <strong>${slots}명</strong> · 빈자리: <strong style="color:${remaining>0?'var(--green)':'var(--red)'}">${remaining>0?remaining+'건':'없음'}</strong>`;

  // (2026-07-23) 카드 제목·건수 줄 제거 — 상태 탭이 이름과 건수를 함께 보여준다

  // Stage 4: 이 캠페인의 모든 결과물을 한 번에 받아 application_id로 그룹핑
  const allDelivs = await fetchDeliverablesByCampaign(currentCampApplicantId);
  // 상단 요약 카드 (개요 + 모집/결과물 현황 + 비용)
  renderCampOpsSummary(camp, allApps, allDelivs, { total, approved: allApproved, pending: allPending, slots });
  const delivByApp = {};
  allDelivs.forEach(d => {
    const arr = (delivByApp[d.application_id] ||= []);
    arr.push(d);
  });
  const isPostType = (camp?.recruit_type === 'gifting' || camp?.recruit_type === 'visit');
  const selectedChannels = (camp?.channel || '').split(',').map(s=>s.trim()).filter(Boolean);
  const channelMatch = camp?.channel_match || 'or';
  const body = $('campApplicantsBody');
  if (!body) return;
  // 계정을 등록한 채널만 팔로워 줄을 함께 보여준다 — 미등록 칸에 「팔로워 0명」이 남으면
  // 등록을 안 한 건지 진짜 0명인지 구분이 안 된다.
  const snsCell = (channel, raw, followers) => {
    const handle = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, raw) : (raw || '').replace(/^@/,'').trim();
    if (!handle) return '—';
    const safe = esc(handle);
    const url = (typeof snsProfileUrl === 'function') ? snsProfileUrl(channel, handle) : '';
    const inner = url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${safe}</a>` : `@${safe}`;
    return `<div style="max-width:140px;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${safe}">${inner}</div>`
      + `<div style="font-size:10px;color:var(--muted)">팔로워 ${followers}명</div>`;
  };
  const renderCampApplicantRow = (a) => {
    const _u = _users.find(u=>u.email===a.user_email)||{};
    const igF = (_u.ig_followers||0).toLocaleString();
    const xF  = (_u.x_followers||0).toLocaleString();
    const ttF = (_u.tiktok_followers||0).toLocaleString();
    const ytF = (_u.youtube_followers||0).toLocaleString();
    const totalF = ((_u.ig_followers||0)+(_u.x_followers||0)+(_u.tiktok_followers||0)+(_u.youtube_followers||0)).toLocaleString();
    // 마스킹된 관리자 등급에겐 line_id 가 NULL 로 오므로 has_line 로 존재 여부만 정확히 판정(PR3 조각 B)
    const _lineDisp = maskedFieldByFlag(_u.line_id, _u.has_line);
    return `<tr data-id="${esc(a.id)}" class="${_u.is_audit?'audit-row':''}">
    <td>
      <div class="applicant-name-cell">
        <div class="applicant-name-info">
          <div class="link-cell" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${auditBadgeHtml(_u)}${adminBadge(a.user_email)}${influencerStatusBadges(_u)}</div>
          <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${_lineDisp?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(_lineDisp)}</div>`:''}
        </div>
        ${renderApplicantMsgBtn(a)}
      </div>
    </td>
    <td>${snsCell('instagram', _u.ig || a.ig_id || a.user_ig, igF)}</td>
    <td>${snsCell('x', _u.x, xF)}</td>
    <td>${snsCell('tiktok', _u.tiktok, ttF)}</td>
    <td>${snsCell('youtube', _u.youtube, ytF)}</td>
    <td style="font-weight:700;color:var(--pink)">${totalF}</td>
    <td>${msgCell(a.message, a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadgeKo(a.status, a.auto_reject_reason)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
    <td style="white-space:nowrap">
      ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${(remaining<=0 && !_u.is_audit)?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="rejectApplication('${a.id}', ${_campDetailIsEvent ? 'true' : 'false'})">미승인</button></div>`
      :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
      :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="revertApplication('${a.id}', ${_campDetailIsEvent ? 'true' : 'false'})">되돌리기</button></div>`}
    </td>
  </tr>`;
  };
  // 열 제목 정렬 — 없으면 기본(신청일 최신순, `fetchApplications` 의 조회 순서)을 그대로 둔다.
  if (_campAppSort.col) {
    const _d = _campAppSort.dir === 'desc' ? -1 : 1;
    if (_campAppSort.col === 'name') {
      // ⚠️ 비교 안에서 `_users.find` 를 부르면 **비교할 때마다 회원 목록을 처음부터 훑는다**.
      //    신청자가 많은 캠페인에서 눈에 띄게 느려지므로 지도를 한 번만 만들어 쓴다.
      const _byEmail = new Map();
      _users.forEach(u => { if (u.email) _byEmail.set(u.email, u); });
      const _nameOf = (a) => influencerSortName(_byEmail.get(a.user_email), a.user_name);
      apps.sort((a, b) => compareInfluencerName(_nameOf(a), _nameOf(b), _d));
    } else if (_campAppSort.col === 'status') {
      // 신청 관리(`toggleAppSort`)와 **같은 차례** — 심사중 → 승인 → 미승인 → 취소.
      const order = {pending: 0, approved: 1, rejected: 2, cancelled: 3};
      apps.sort((a, b) => (((order[a.status] ?? 9) - (order[b.status] ?? 9))) * _d);
    } else {
      apps.sort((a, b) => (new Date(a.created_at) - new Date(b.created_at)) * _d);
    }
  }
  _applySortArrows('campApplicantsHead', _campAppSort);

  if (campApplicantsLazy) campApplicantsLazy.destroy();
  campApplicantsLazy = mountLazyList({
    tbody: body,
    scrollRoot: body.closest('.admin-table-wrap'),
    rows: apps,
    renderRow: renderCampApplicantRow,
    pageSize: CAMP_APPLICANTS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>',
  });

  // 「올려두고 미제출」 표시용 집합 — 결과물 관리 화면과 **같은 함수**를 쓴다.
  //   ⚠️ 여기서 안 채우면 같은 응모가 두 화면에서 다르게 보인다(한쪽만 「올려두고 미제출」).
  //      조회 실패는 `null` 이 들어가고, 그러면 양쪽 다 그 표시를 안 그린다.
  if (typeof fetchStalledDraftApplications === 'function') {
    _delivStalledDraftApps = await fetchStalledDraftApplications();
  }
  // 결과물 탭 렌더 + 상단 탭 건수 갱신 (같은 데이터로 한 번에 — 추가 조회 없음)
  const delivTotal = renderCampDelivTab(camp, allDelivs, allApps, _users);

  // 행사 캠페인은 예약 표를 함께 그린다. 조회는 예약 화면이 쓰던 것 그대로 재사용한다
  //   — 화면을 옮겼을 뿐 판정을 새로 만들지 않는다.
  let ticketTotal = 0;
  if (_campDetailIsEvent && typeof renderEventTicketsPane === 'function') {
    // 캠페인 객체를 함께 넘긴다 — 예약 표가 「선정형인가」를 이 값으로 판정한다.
    //   목록 캐시(allCampaigns)에서 다시 찾게 두면, 운영현황에서 곧바로 들어온 경로처럼
    //   캐시가 비어 있을 때 **조용히 선착순형으로 읽혀** 뽑기 버튼이 안 뜬다.
    await renderEventTicketsPane(camp.id, camp);
    ticketTotal = (typeof _eventTicketsCache !== 'undefined' && Array.isArray(_eventTicketsCache))
      ? _eventTicketsCache.filter(t => t.status !== 'cancelled').length : 0;
    // 요약 카드는 위(110행)에서 이미 그려졌는데, 그때는 예약을 아직 안 읽어 0 으로 나온다.
    //   읽고 나서 다시 그린다. 그 사이 다른 캠페인으로 옮겼으면 덮지 않는다(낡은 카드 방지).
    if (currentCampApplicantId === camp.id) {
      renderCampOpsSummary(camp, allApps, allDelivs, { total, approved: allApproved, pending: allPending, slots });
    }
  } else if (_campDetailTab === 'tickets') {
    _campDetailTab = 'applicants';   // 행사가 아닌 캠페인에 예약 탭이 남아 있으면 빈 화면이 된다
  }
  renderCampDetailTabs(total, delivTotal, ticketTotal);
}

// 「되돌리기」 — 「미승인」과 같은 이유로 행사에서는 서버가 막는다. 눌러서 실패해 보고
//   아는 것보다 미리 알려 주는 편이 낫다(두 버튼의 안내 방식을 맞춘다).
async function revertApplication(appId, isEvent) {
  if (isEvent) { showEventStatusBlockedNotice('되돌리기'); return; }
  await updateAppStatus(appId, 'pending');
}

// 행사 캠페인에서 신청 상태를 직접 바꾸려 할 때의 안내 — 두 버튼이 같은 문구를 쓴다.
//   문구를 두 벌로 두면 한쪽만 고쳐진다.
function showEventStatusBlockedNotice(what) {
  const el = $('alertModalMessage');
  if (el) el.innerHTML = `<div style="font-size:13px;line-height:1.8;text-align:left">
    <div style="text-align:center;margin-bottom:14px">오프라인 행사는 여기서 「${esc(what)}」 할 수 없습니다.</div>
    신청 상태만 바꾸면 <b>예약(입장 티켓)은 그대로 남아</b> 서로 어긋납니다.
    입장 확인은 신청 상태를 보지 않으므로, 반려한 사람이 현장에서 입장 처리됩니다.
    <div style="margin-top:12px;padding-top:12px;border-top:1px solid var(--line);color:var(--muted)">
      캠페인 진행현황의 <b>「예약 현황」 탭</b>에서 <b>「취소」</b>를 눌러 주세요.
      예약과 신청이 함께 취소되고, 대기 1번이 자동으로 올라갑니다.
    </div>
  </div>`;
  openModal('alertModal');
}

// 「미승인」 — 행사 캠페인에서는 이 버튼을 쓰지 않는다.
//   신청만 반려되고 예약(티켓)은 확정으로 남는데, 입장 확인은 신청 상태를 보지 않아
//   **반려한 사람이 그대로 입장 처리된다**(2026-08-04 발견). 마이그레이션 289 가
//   서버에서 아예 막으므로, 화면에서는 **어디로 가야 하는지**를 알려 준다.
//   ⚠️ 같은 버튼이 **세 화면**에 있다 — 진행현황·신청 관리·대시보드의 「최근 신청」.
//      한 곳만 고치면 구멍이 남는다(실제로 처음엔 두 곳만 고쳐 하나를 빠뜨렸다).
async function rejectApplication(appId, isEvent) {
  if (isEvent) { showEventStatusBlockedNotice('미승인'); return; }
  await updateAppStatus(appId, 'rejected');
}

// ── 캠페인 진행현황: 신청자 목록 / 결과물 목록 탭 ─────────────────────
//   결과물 표는 결과물 관리 페인과 같은 행 빌더(renderDelivAppRow)를 compact 로 재사용한다.
//   두 화면이 따로 놀지 않게 판정·렌더를 단일 소스로 유지하는 게 목적.
var _campDetailTab = 'applicants';   // 'applicants' | 'deliverables' | 'tickets'
var _campDetailIsEvent = false;      // 지금 보고 있는 캠페인이 오프라인 행사인가
var _campAppStatusTab = '';          // 신청자 탭 안의 신청 상태 필터('' = 전체)
var _campDelivCertTab = '';          // 결과물 탭 안의 인증 상태 필터('' = 전체)
// 인증 성공일 기간 필터 (결과물 탭 전용). 결과물 관리 페인과 같은 규칙 —
//   브라우저 로컬 날짜(YYYY-MM-DD) 비교, 인증 성공 전인 건은 날짜가 없어 제외.
var _campDelivCertFrom = '';
var _campDelivCertTo = '';
var _campDelivCertFp = null;

// 신청 상태 탭 — 신청 관리 페인과 같은 5종(APP_STATUS_TABS) 재사용. 건수는 검색만 반영한 집계.
function renderCampAppStatusTabs(countsMap) {
  const bar = $('campAppStatusTabBar');
  if (!bar) return;
  const c = countsMap || {};
  const totalAll = (c.pending||0) + (c.approved||0) + (c.rejected||0) + (c.cancelled||0);
  bar.innerHTML = APP_STATUS_TABS.map(tab => {
    const n = tab.code === '' ? totalAll : (c[tab.code] || 0);
    const cls = 'status-tab-btn' + (tab.code === _campAppStatusTab ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code}" onclick="setCampAppStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

function setCampAppStatusTab(btn) {
  _campAppStatusTab = btn.dataset.status || '';
  loadCampApplicants();
}

// delivCount 는 결과물 탭이 실제로 그리는 행 수(미제출 승인 신청 포함) — 탭 숫자와 목록 길이를 일치시킨다.
function renderCampDetailTabs(appCount, delivCount, ticketCount) {
  const bar = $('campDetailTabBar');
  if (!bar) return;
  // 행사 캠페인은 결과물이 없다 — 그 탭의 숫자는 「미제출 빈 행」이라 밀린 것처럼 보인다.
  //   대신 예약 현황을 앞에 둔다(별도 화면에서 옮겨 왔다, 2026-08-04).
  const tabs = _campDetailIsEvent
    ? [
        { code: 'tickets',    label: '예약 현황',   n: ticketCount || 0 },
        { code: 'applicants', label: '신청자 목록', n: appCount || 0 },
      ]
    : [
        { code: 'applicants',   label: '신청자 목록', n: appCount || 0 },
        { code: 'deliverables', label: '결과물 목록', n: delivCount || 0 },
      ];
  bar.innerHTML = tabs.map(t => {
    const cls = 'status-tab-btn' + (t.code === _campDetailTab ? ' on' : '') + (t.n === 0 ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-tab="${t.code}" onclick="setCampDetailTab(this)">`
      + `${t.label}<span class="tab-count">(${t.n})</span></button>`;
  }).join('');
  applyCampDetailTabVisibility();
}

function setCampDetailTab(btn) {
  setCampDetailTabByCode(btn.dataset.tab || 'applicants');
}

function setCampDetailTabByCode(code) {
  _campDetailTab = code || 'applicants';
  const bar = $('campDetailTabBar');
  if (bar) bar.querySelectorAll('.status-tab-btn').forEach(b => b.classList.toggle('on', b.dataset.tab === _campDetailTab));
  applyCampDetailTabVisibility();
}

// 탭에 따라 카드·필터 노출 전환. 상태·검색 필터는 신청자 목록 전용이라 결과물 탭에선 감춘다.
function applyCampDetailTabVisibility() {
  const isDeliv = _campDetailTab === 'deliverables';
  const isTicket = _campDetailTab === 'tickets';
  const appCard = $('campApplicantsCard');
  const delivCard = $('campDelivCard');
  const ticketCard = $('campTicketsCard');
  const filterBar = $('campAppFilterBar');
  if (appCard) appCard.style.display = (isDeliv || isTicket) ? 'none' : '';
  if (delivCard) delivCard.style.display = isDeliv ? '' : 'none';
  if (ticketCard) ticketCard.style.display = isTicket ? '' : 'none';
  // 검색은 신청자·결과물 탭 전용 — 예약 표는 자체 필터(타임·상태)를 쓴다.
  if (filterBar) filterBar.style.display = isTicket ? 'none' : 'flex';
  // 검수 상태 드롭다운은 결과물 탭 전용
  const reviewGroup = $('campDelivReviewFilterGroup');
  if (reviewGroup) reviewGroup.style.display = isDeliv ? '' : 'none';
  // 인증 성공일 기간도 결과물 탭 전용 (신청자 탭엔 그 열이 없다)
  const certRangeGroup = $('campDelivCertRangeGroup');
  if (certRangeGroup) certRangeGroup.style.display = isDeliv ? '' : 'none';
}

// (2026-07-23) 헤더 엑셀 버튼(exportCampDetailExcel)은 각 탭의 상태 탭 줄 우측 버튼으로 이동.
//   신청자 탭 → exportCampaignApplicationsExcel / 결과물 탭 → exportCampaignDeliverables 를 직접 호출한다.

// 헤더 더보기 버튼 — 캠페인 목록 행의 더보기 메뉴를 그대로 재사용(편집·복제·엑셀·이력·삭제)
function openCampDetailMoreMenu(e, btn) {
  if (!currentCampApplicantId) return;
  const title = ($('campApplicantsTitle')?.textContent || '').trim();
  toggleCampMoreMenu(e, btn, currentCampApplicantId, title);
}

// 인증 성공일 range picker mount (1회). 결과물 관리 페인의 setupDelivCertRange 와 같은 형태.
function setupCampDelivCertRange() {
  if (typeof flatpickr === 'undefined') return;
  const el = $('campDelivCertRange');
  if (!el || _campDelivCertFp) return;
  const fmt = d => d ? `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}` : '';
  _campDelivCertFp = flatpickr(el, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    showMonths: 1,
    onChange: function(selectedDates) {
      _campDelivCertFrom = fmt(selectedDates[0]);
      _campDelivCertTo = fmt(selectedDates[1]);
      el.classList.toggle('filter-active', !!(_campDelivCertFrom || _campDelivCertTo));
      const btn = $('btnCampDelivCertClear');
      if (btn) btn.style.display = (_campDelivCertFrom || _campDelivCertTo) ? '' : 'none';
      if (selectedDates.length === 0 || selectedDates.length === 2) loadCampApplicants();
    }
  });
}

// 인증 성공일 기간 지우기 — 이 화면에는 「보기 초기화」가 없어 이 단추가 유일한 해제 수단이다.
//   ⚠️ clear(false) 로 flatpickr 의 change 이벤트를 끈다 — 켜 두면 위 onChange 가 다시 돌아
//      loadCampApplicants() 가 두 번 불린다(낡은 응답이 뒤늦게 덮을 수 있음).
function clearCampDelivCertRange() {
  _campDelivCertFrom = ''; _campDelivCertTo = '';
  if (_campDelivCertFp) _campDelivCertFp.clear(false);
  const el = $('campDelivCertRange'); if (el) el.classList.remove('filter-active');
  const btn = $('btnCampDelivCertClear'); if (btn) btn.style.display = 'none';
  loadCampApplicants();
}

// 결과물 탭 본문 — 인증 상태 탭 + 표.
//   미제출 승인 신청도 빈 행으로 포함해야 「미제출」 집계가 결과물 관리 페인과 같아진다(includeApps).
// ── 캠페인 진행현황 — 두 탭의 열 제목 정렬 ─────────────────────────
//   신청 관리·결과물 관리에 있던 정렬을 이 화면에도 둔다(2026-09-01 요청).
//   ⚠️ **뜻이 있는 열만 넣었다.** 모집기간·구매기간·제출 마감은 **캠페인 단위 값**이라
//      한 캠페인 안에서는 모든 행이 같은 값이다 — 그대로 옮기면 눌러도 아무 일도
//      안 일어나는 단추가 셋 생긴다.
//   ⚠️ **세 단계(오름 → 내림 → 해제)** 로 돈다. 결과물 관리(`toggleDelivSort`)와 같은 방식이고,
//      신청 관리(`toggleAppSort`, 두 단계)와는 다르다. 이 화면은 **기본 순서 자체가 뜻을 갖기
//      때문**이다 — 신청자는 신청일 최신순, 결과물은 최근 제출순이라 되돌아갈 수 있어야 한다.
//   ⚠️ 화살표 갱신은 **각자의 thead 안으로 범위를 좁힌다**. `.sort-arrows` 는 이 화면 밖
//      여러 표가 함께 쓰는 이름이라, 범위를 안 좁히면 다른 표의 화살표까지 지운다.
let _campAppSort = {col: null, dir: null};
let _campDelivSort = {col: null, dir: null};

// 세 단계 토글 — 같은 열을 누르면 오름 → 내림 → 해제
function _cycleSort(state, col) {
  if (state.col === col) {
    if (state.dir === 'asc') state.dir = 'desc';
    else { state.col = null; state.dir = null; }
  } else {
    state.col = col; state.dir = 'asc';
  }
}

function _applySortArrows(headId, state) {
  const head = $(headId);
  if (!head) return;
  head.querySelectorAll('.sort-arrows').forEach(el => {
    const col = el.getAttribute('data-sort');
    if (state.col === col) {
      el.textContent = state.dir === 'asc' ? '▲' : '▼';
      el.style.color = 'var(--dark-pink)';
    } else {
      el.textContent = '▲▼';
      el.style.color = '';
    }
  });
}

function toggleCampAppSort(col) { _cycleSort(_campAppSort, col); loadCampApplicants(); }
function toggleCampDelivSort(col) { _cycleSort(_campDelivSort, col); loadCampApplicants(); }

function renderCampDelivTab(camp, allDelivs, allApps, users) {
  const tbody = $('campDelivBody');
  if (!tbody) return 0;
  if (!camp) { tbody.innerHTML = ''; return 0; }
  const campMap = new Map([[camp.id, camp]]);
  const infMap = {};
  (users || []).forEach(u => { if (u.id) infMap[u.id] = u; });
  const approvedApps = (allApps || []).filter(a => a.status === 'approved');
  const groups = buildDeliverableGroups(allDelivs || [], campMap, { includeApps: approvedApps, infMap });
  let list = Array.from(groups.values());
  // 신청 status 를 그룹에 채워 「검수 불필요」(반려·취소된 신청) 판정이 결과물 관리와 같아지게 한다
  const appStatusById = {};
  const userIdByApp = {};
  (allApps || []).forEach(a => { appStatusById[a.id] = a.status; userIdByApp[a.id] = a.user_id; });
  list.forEach(g => {
    if (!g.application_status) g.application_status = appStatusById[g.application_id] || null;
    // fetchDeliverablesByCampaign 은 influencers 를 조인하지 않으므로(경량 조회) 이름이 비어 보인다.
    // 이미 로드해 둔 인플루언서 목록으로 신청→회원을 이어 채운다. 추가 조회 없음.
    if (!g.influencer) g.influencer = infMap[userIdByApp[g.application_id]] || null;
  });

  const totalAllGroups = list.length;   // 어떤 필터도 적용 전 — 상단 「결과물 목록」 탭 숫자와 일치시킨다

  // 검색(인플루언서 이름·메일·SNS)과 검수 상태는 인증 상태 탭보다 먼저 적용해,
  // 탭 건수가 「지금 검색한 결과 안에서의 분포」를 보여주게 한다(신청자 탭과 같은 규칙).
  const searchQ = ($('campAppSearch')?.value || '').trim().toLowerCase();
  if (searchQ) {
    list = list.filter(g => {
      const u = g.influencer || {};
      return matchSearchTokens(searchQ, [u.name, u.name_kanji, u.name_kana, u.email, u.ig, u.x, u.tiktok, u.youtube]);
    });
  }
  const reviewFilter = $('campDelivReviewFilter')?.value || '';
  if (reviewFilter) list = list.filter(g => campDelivReviewState(g) === reviewFilter);
  // 인증 성공일 기간 — 인증 상태 탭 건수를 세기 **전에** 적용해, 탭 숫자와 목록이 안 어긋나게 한다
  setupCampDelivCertRange();
  if (_campDelivCertFrom || _campDelivCertTo) {
    list = list.filter(g => {
      const c = delivLocalDate(certSuccessAt(g));
      if (!c) return false;  // 아직 인증 성공이 아닌 건은 날짜가 없어 기간 지정 시 제외
      if (_campDelivCertFrom && c < _campDelivCertFrom) return false;
      if (_campDelivCertTo && c > _campDelivCertTo) return false;
      return true;
    });
  }

  const counts = { success: 0, submitting: 0, none: 0, excluded: 0 };
  list.forEach(g => { const s = computeCertStatus(g); if (counts[s] != null) counts[s]++; });
  renderCampDelivCertTabs(counts);

  if (_campDelivCertTab) list = list.filter(g => computeCertStatus(g) === _campDelivCertTab);
  // 열 제목 정렬 — 없으면 기본(최근 제출 순, 미제출은 뒤로)
  if (_campDelivSort.col === 'name') {
    const _d = _campDelivSort.dir === 'desc' ? -1 : 1;
    list.sort((a, b) => {
      return compareInfluencerName(influencerSortName(a.influencer), influencerSortName(b.influencer), _d);
    });
  } else if (_campDelivSort.col === 'cert_at') {
    // ⚠️ 인증 성공 전인 건은 날짜가 없다. **방향과 무관하게 뒤로** — 결과물 관리와 같은 규약이고,
    //    이 열은 빈 칸이 절반을 넘어 오름차순에서 앞을 다 채우면 아무것도 못 보게 된다.
    const _d = _campDelivSort.dir === 'desc' ? -1 : 1;
    list.sort((a, b) => {
      const av = certSuccessAt(a) || '', bv = certSuccessAt(b) || '';
      if (!av && !bv) return 0;
      if (!av) return 1;
      if (!bv) return -1;
      return av.localeCompare(bv) * _d;
    });
  } else if (_campDelivSort.col === 'submitted') {
    const _d = _campDelivSort.dir === 'desc' ? -1 : 1;
    list.sort((a, b) => (a.latest_submitted_at || '').localeCompare(b.latest_submitted_at || '') * _d);
  } else {
    // 최근 제출 순(미제출은 뒤로)
    list.sort((a, b) => (b.latest_submitted_at || '').localeCompare(a.latest_submitted_at || ''));
  }
  _applySortArrows('campDelivHead', _campDelivSort);

  tbody.innerHTML = list.length
    ? list.map(g => renderDelivAppRow(g, { compact: true })).join('')
    : `<tr><td colspan="8" style="text-align:center;color:var(--muted);padding:32px">${
        (_campDelivCertFrom || _campDelivCertTo)
          ? '이 기간에 인증 성공한 건이 없습니다.<br><span style="font-size:12px">인증 성공일은 인증이 끝난 건에만 있어, 진행 중인 건은 기간을 지정하면 빠집니다.</span>'
          : '해당하는 결과물이 없습니다'
      }</td></tr>`;
  return totalAllGroups;
}

// 신청 1건의 검수 진행 상태 — 「검수 상태」 드롭다운 판정용.
//   제출된 결과물(영수증·게시물·채널별 인증샷)을 한 묶음으로 보고 가장 급한 상태를 대표값으로 삼는다.
//   검수대기 > 반려 > 모두 승인 순 (미제출은 어디에도 안 걸림 → 'none')
function campDelivReviewState(g) {
  const items = [g.receipt, g.result].concat(Object.values(g.reviewByChannel || {})).filter(Boolean);
  if (!items.length) return 'none';
  if (items.some(d => d.status === 'pending')) return 'pending';
  if (items.some(d => d.status === 'rejected')) return 'rejected';
  if (items.every(d => d.status === 'approved')) return 'approved';
  return 'none';
}

function renderCampDelivCertTabs(counts) {
  const bar = $('campDelivCertTabBar');
  if (!bar) return;
  const c = counts || {};
  const totalAll = (c.success||0) + (c.submitting||0) + (c.none||0) + (c.excluded||0);
  bar.innerHTML = DELIV_CERT_STATUS_TABS.map(tab => {
    const n = tab.code === '' ? totalAll : (c[tab.code] || 0);
    const cls = 'status-tab-btn' + (tab.code === _campDelivCertTab ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code}" onclick="setCampDelivCertTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

function setCampDelivCertTab(btn) {
  _campDelivCertTab = btn.dataset.status || '';
  loadCampApplicants();
}

// ── 캠페인 진행현황 상단 요약 카드 ───────────────────────────────────
// 개요(좌) + 모집·결과물 현황(우) 즉시 렌더. 비용 카드는 권한·연결 조건부 비동기.
function renderCampOpsSummary(camp, allApps, allDelivs, stats) {
  const box = $('campApplicantsSummary');
  if (!box) return;
  if (!camp) { box.innerHTML = ''; return; }
  box.innerHTML = campOpsOverviewCard(camp) + campOpsStatusCard(camp, allApps, allDelivs, stats);
  appendCampOpsCostCard(camp);
}

// 개요 카드 — 썸네일·제품·캠페인번호·타입/채널/판매가 + 기간 3종
function campOpsOverviewCard(camp) {
  const thumb = camp.img1
    ? `<img src="${esc(imgThumb(camp.img1,128,70))}" data-orig="${esc(camp.img1)}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:64px;height:64px;border-radius:8px;object-fit:cover;flex-shrink:0">`
    : `<div style="width:64px;height:64px;border-radius:8px;background:var(--surface-dim);flex-shrink:0;display:flex;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="color:var(--muted)">inventory_2</span></div>`;
  const product = esc(camp.product_ko || camp.product || '—');
  const typeKo = (typeof BRAND_OPS_RECRUIT_TYPE_KO !== 'undefined' && BRAND_OPS_RECRUIT_TYPE_KO[camp.recruit_type]) || camp.recruit_type || '—';
  const channels = (camp.channel || '').split(',').map(s=>s.trim()).filter(Boolean);
  const chSep = camp.channel_match === 'and' ? ' & ' : ' / ';
  const channelTxt = channels.map(ch => esc(getChannelLabel(ch))).join(chSep);
  const isEvent = (typeof isEventCampaign === 'function') && isEventCampaign(camp);
  // 선정형 행사인가 — 아래 「선정」 줄을 가르는 판정(2026-08-24 선정형 사양서 설계 7).
  const isSelEvent = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);
  // 행사는 제품 금액을 0으로 저장한다 — 그대로 두면 「0円」이 값처럼 보인다.
  const priceTxt = (!isEvent && camp.product_price != null && camp.product_price !== '' && Number(camp.product_price) > 0)
    ? Number(camp.product_price).toLocaleString('ja-JP') + '円' : '';
  const recruitRange = brandOpsDateRange(camp.recruit_start, camp.deadline);
  // 기간 줄 — 판정은 공용 헬퍼 하나만 쓴다(캠페인 목록과 같은 소스).
  //   ⚠️ 리뷰어형은 구매 기간이 모집 기간과 **글자 그대로 같게** 저장되므로, 그대로 두면
  //      같은 날짜가 두 줄로 반복된다. 그럴 때는 구매 줄을 없애고 모집 줄 이름에 합친다.
  //   ⚠️ 갈래를 이름으로 지목한다 — 부정 조건을 쓰면 갈래가 늘 때 조용히 잘못 걸린다.
  const periodKind = (typeof campaignPeriodRowKind === 'function') ? campaignPeriodRowKind(camp) : 'none';
  const recruitLabel = (periodKind === 'merged' || periodKind === 'monitorNoPurchase') ? '모집·구매'
                     : (periodKind === 'visitMerged') ? '모집·방문' : '모집';
  let buyRange = '', buyLabel = '';
  if (periodKind === 'split')        { buyRange = brandOpsDateRange(camp.purchase_start, camp.purchase_end); buyLabel = '구매'; }
  else if (periodKind === 'visit')   { buyRange = brandOpsDateRange(camp.visit_start, camp.visit_end);       buyLabel = '방문'; }
  // 선정 기간은 위 갈래 판정과 **무관한 독립 줄**이다(2026-08-24). 방문형은 「방문 기간」과
  //   「선정 기간」을 둘 다 가질 수 있는데, 위 buyRange 는 두 번째 기간을 **한 줄만** 그리는
  //   구조라 한쪽이 밀려난다. 신청자를 실제로 뽑는 화면이라 둘 다 보여야 한다(결정 2).
  //   ⚠️ 갈래(campaignPeriodRowKind)를 늘려 풀지 않는다 — 그 헬퍼는 호출부가 14곳이다.
  //   ⚠️ 시딩형은 예전에 이 갈래('gifting')로 그려졌다. 그 갈래의 뜻이 「시딩형 + 값 있음」과
  //      정확히 같고 시딩형은 행사가 될 수 없어(데이터베이스 제약), 아래 조건으로 옮겨도
  //      **시딩형 동작은 그대로**다.
  //   ⚠️ 이 조건을 쓰는 자리는 **네 곳**이고 글자 그대로 같아야 한다 — 목록과 근거는
  //      인플루언서 상세(application.js)의 같은 자리 주석에 있다.
  //   ⚠️ 행사는 **선정형만** 그린다(2026-08-24 선정형 사양서 설계 7). 선착순형 비공개
  //      행사에는 뽑는 기간이 없어 뜨면 안 된다.
  //   ⚠️ 값이 비면 종전처럼 줄 자체를 안 그린다 — 「무조건 세 줄」이라는 뜻이 아니다.
  const selRange = ((camp.recruit_type === 'gifting' || (camp.recruit_type === 'visit' && (!isEvent || isSelEvent)))
      && (camp.selection_start || camp.selection_end))
    ? brandOpsDateRange(camp.selection_start, camp.selection_end) : '';
  const submitTxt = camp.submission_end ? formatDate(camp.submission_end) : '';
  return `<div class="camp-ops-card">
    <div class="camp-ops-card-title">캠페인 개요</div>
    <div style="display:flex;gap:12px">
      ${thumb}
      <div style="min-width:0;flex:1">
        <div style="font-weight:700;font-size:13px;color:var(--ink);word-break:break-word">${product}</div>
        ${camp.campaign_no?`<div style="font-size:11px;color:var(--muted);margin-top:2px">${esc(camp.campaign_no)}</div>`:''}
        <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-top:6px;font-size:11px">
          <span style="background:var(--surface-dim);padding:1px 8px;border-radius:8px">${esc(typeKo)}</span>
          ${isEvent?`<span style="background:#E8F7EF;color:#0E7E4A;font-weight:700;padding:1px 8px;border-radius:8px">행사</span>`:''}
          ${isEvent && camp.is_invite_only?`<span style="background:var(--surface-container-low);color:var(--muted);font-weight:700;padding:1px 8px;border-radius:8px">비공개</span>`:''}
          ${channelTxt?`<span style="color:var(--muted)">${channelTxt}</span>`:''}
          ${priceTxt?`<span style="color:var(--ink);font-weight:600">${priceTxt}</span>`:''}
        </div>
      </div>
    </div>
    <div style="margin-top:10px;border-top:1px solid var(--surface-dim);padding-top:8px">
      ${recruitRange?`<div class="camp-ops-row"><span class="k">${esc(recruitLabel)}</span><span class="v">${esc(recruitRange)}</span></div>`:''}
      ${selRange?`<div class="camp-ops-row"><span class="k">선정</span><span class="v">${esc(selRange)}</span></div>`:''}
      ${buyRange?`<div class="camp-ops-row"><span class="k">${buyLabel}</span><span class="v">${esc(buyRange)}</span></div>`:''}
      ${(!isEvent && submitTxt)?`<div class="camp-ops-row"><span class="k">제출마감</span><span class="v">${esc(submitTxt)}</span></div>`:''}
      ${(isEvent && camp.event_place)?`<div class="camp-ops-row"><span class="k">행사장</span><span class="v">${esc(camp.event_place)}</span></div>`:''}
    </div>
  </div>`;
}

// 모집·결과물 현황 카드 — 진행바 3종(모집/제출/승인) + 보조 수치.
//   행사 캠페인은 결과물이 없어 「제출·인증」이 영원히 0이라 오해를 부른다 → 예약·입장으로 바꾼다.
function campOpsStatusCard(camp, allApps, allDelivs, stats) {
  // ⚠️ 캠페인 객체를 그대로 넘긴다 — 카드가 「선정형인가」를 판정해야 하는데
  //    id 만 넘기면 그 판정 재료가 없다(선정형이면 「대기」가 아니라 「심사중」이다).
  if ((typeof isEventCampaign === 'function') && isEventCampaign(camp)) return campOpsEventStatusCard(camp);
  const slots = stats.slots || 0;
  const approved = stats.approved || 0;
  const recruitPct = slots > 0 ? Math.round(approved / slots * 100) : null;
  // 제출 인플 = 승인 신청 중 결과물 제출한 distinct 신청 (미니카드 정의와 동일)
  const approvedIdSet = new Set(allApps.filter(a => a.status === 'approved').map(a => a.id));
  const submittedInf = new Set(allDelivs.filter(d => approvedIdSet.has(d.application_id)).map(d => d.application_id)).size;
  const submitPct = approved > 0 ? Math.round(submittedInf / approved * 100) : null;
  // 3번째 진행바: 인증 성공(결과물 관리 화면과 동일 판정 — countCertSuccess) / 모집인원
  const certSuccess = (typeof countCertSuccess === 'function') ? countCertSuccess(allDelivs, camp) : 0;
  const certPct = slots > 0 ? Math.round(certSuccess / slots * 100) : null;
  return `<div class="camp-ops-card">
    <div class="camp-ops-card-title">모집 · 결과물 현황</div>
    ${brandOpsRateBar('모집현황', recruitPct, approved, slots)}
    ${brandOpsRateBar('결과물 제출', submitPct, submittedInf, approved)}
    ${brandOpsRateBar('인증 성공', certPct, certSuccess, slots)}
    <div style="display:flex;gap:12px;margin-top:10px;font-size:11px;color:var(--muted);flex-wrap:wrap">
      <span>신청 <strong style="color:var(--ink)">${stats.total}</strong>명</span>
      <span>승인 <strong style="color:var(--green)">${approved}</strong>명</span>
      <span>심사중 <strong style="color:#f59e0b">${stats.pending}</strong>명</span>
    </div>
  </div>`;
}

// 행사 캠페인의 현황 카드 — 예약 확정 / 입장 완료.
//   ⚠️ 분모 정원은 `campaigns.slots`(저장 시점 스냅샷)가 아니라 **시간대 정원 합계**를 쓴다.
//      시간대를 고치고 캠페인을 저장하지 않으면 스냅샷이 낡아, 브랜드 보고에 틀린 수를 낸다.
//   ⚠️ 숫자는 예약 화면과 **같은 함수**(eventTicketCounts)로 센다 — 따로 세면 두 곳이 갈린다.
//   ⚠️ 인자는 캠페인 **객체**다(2026-08-25, 선정형 추가). 선정형이면 같은 값(waitlist)이
//      「캔슬 대기」가 아니라 「심사중」을 뜻해 이름표가 달라지므로 id 만으로는 부족하다.
function campOpsEventStatusCard(camp) {
  const campId = camp?.id || camp;   // 옛 호출부가 id 만 넘겨도 숫자는 그대로 나오게
  const isSel = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);
  // ⚠️ 아래 캐시는 예약 화면이 채운다. 이 카드는 예약을 읽기 **전에도** 한 번 그려지는데,
  //    그때 캐시에는 **직전에 보던 다른 행사 캠페인의 숫자**가 남아 있다(0 이 아니다).
  //    그 값을 그대로 보여 주면 잘못된 수가 잠깐 진짜처럼 보인다 — 이 캠페인 것이 아니면
  //    수 대신 「—」 를 낸다(읽고 나서 다시 그린다).
  const ready = (typeof _eventPaneCampId !== 'undefined') && campId && _eventPaneCampId === campId;
  if (!ready) {
    return `<div class="camp-ops-card">
      <div class="camp-ops-card-title">예약 · 입장 현황</div>
      <div style="font-size:12px;color:var(--muted);padding:12px 0">불러오는 중…</div>
    </div>`;
  }
  const c = (typeof eventTicketCounts === 'function') ? eventTicketCounts('') : null;
  if (!c) return '';
  const cap = (typeof _eventSlotsCache !== 'undefined' && Array.isArray(_eventSlotsCache))
    ? _eventSlotsCache.filter(r => r && r.is_active !== false).reduce((n, r) => n + Number(r.capacity || 0), 0) : 0;
  const bookPct  = cap > 0 ? Math.round(c.confirmed / cap * 100) : null;
  const enterPct = c.confirmed > 0 ? Math.round(c.entered / c.confirmed * 100) : null;
  return `<div class="camp-ops-card">
    <div class="camp-ops-card-title">예약 · 입장 현황</div>
    ${brandOpsRateBar(isSel ? '선정 완료' : '예약 확정', bookPct, c.confirmed, cap)}
    ${brandOpsRateBar('입장 완료', enterPct, c.entered, c.confirmed)}
    <div style="display:flex;gap:12px;margin-top:10px;font-size:11px;color:var(--muted);flex-wrap:wrap">
      <span>${isSel ? '심사중' : '대기'} <strong style="color:#f59e0b">${c.waitlist}</strong>명</span>
      <span>미입장 <strong style="color:var(--ink)">${c.noshow}</strong>명</span>
      <span>취소 <strong>${c.cancelled}</strong>명</span>
    </div>
  </div>`;
}

// 비용 카드 — 권한(campaign_admin 이상) + 연결 신청 있을 때만. 비동기로 뒤에 붙임.
async function appendCampOpsCostCard(camp) {
  if (typeof isCampaignAdminOrAbove === 'function' && !isCampaignAdminOrAbove()) return;
  if (!camp || !camp.source_application_id) return;
  let app = null;
  try { app = await fetchBrandApplicationById(camp.source_application_id); } catch (e) { app = null; }
  // 비동기 사이 다른 캠페인으로 전환됐으면 중단 (stale 카드 방지)
  if (currentCampApplicantId !== camp.id) return;
  if (!app) return;
  const box = $('campApplicantsSummary');
  if (!box) return;
  // ⚠️ 행사 캠페인은 요약을 두 번 그린다(예약을 읽기 전·후). 이 함수는 기다리지 않고
  //    떠나므로 두 번의 조회가 각각 카드를 붙여 **비용 카드가 두 장 겹칠** 수 있다.
  //    이미 붙어 있으면 지우고 다시 붙인다.
  box.querySelectorAll('[data-cost-card]').forEach(el => el.remove());
  box.insertAdjacentHTML('beforeend', campOpsCostCard(app));
}

function campOpsCostCard(app) {
  const quote = app.final_quote_krw || app.estimated_krw;
  const quoteLabel = app.final_quote_krw ? '확정 견적' : '예상 견적';
  const quoteTxt = quote ? Number(quote).toLocaleString('ko-KR') + '원' : '미산정';
  // 모집비(운영비) 총액 = Σ(수량 × 모집비 단가) — 브랜드 신청 상세의 totalRecruitFee 와 동일 산식
  const prods = Array.isArray(app.products) ? app.products : [];
  const recruitFee = prods.reduce((s, p) => {
    const rf = (p.recruit_fee_krw == null || p.recruit_fee_krw === '') ? 0 : Number(p.recruit_fee_krw);
    return s + (Number(p.qty) || 0) * rf;
  }, 0);
  const recruitFeeTxt = recruitFee > 0 ? recruitFee.toLocaleString('ko-KR') + '원' : '—';
  const url = app.quote_sent_url || '';
  const safeUrl = (typeof safeBrandUrl === 'function') ? safeBrandUrl(url) : url;
  return `<div class="camp-ops-card" data-cost-card>
    <div class="camp-ops-card-title">비용</div>
    <div style="font-size:11px;color:var(--muted);margin-bottom:8px">연결 신청 ${esc(app.application_no||'')} 기준</div>
    <div class="camp-ops-row"><span class="k">${quoteLabel}</span><span class="v">${esc(quoteTxt)}</span></div>
    <div class="camp-ops-row"><span class="k">운영비</span><span class="v">${esc(recruitFeeTxt)}</span></div>
    ${(url && safeUrl)?`<div class="camp-ops-row"><span class="k">견적서</span><span class="v"><a href="${esc(safeUrl)}" target="_blank" rel="noopener" style="color:var(--pink)">견적서 보기</a></span></div>`:''}
  </div>`;
}

// (2026-07-23) 「오리엔시트 발송」 체크 셀(renderOtCell/onOtToggle)과 「결과물」 요약 셀
// (renderDelivCell/isApplicationComplete)은 열 제거와 함께 삭제됨.
//   - 오리엔시트 발송 체크: 사용자 결정으로 기능 폐기(applications.oriented_at 컬럼·기존 값은 보존)
//   - 결과물 요약: 같은 페인의 「결과물 목록」 탭이 결과물 관리와 동일한 표로 대체


// ── 신청 관리 (캠페인별) ──
let currentAppTypeTab = 'all';
let currentAppCampId = null;

// ════════════════════════════════════════════════════════════════════
// SECTION: APPLICATIONS — 신청 관리 (renderAppCampList 캐시 공유)
// ════════════════════════════════════════════════════════════════════

async function loadApplications() {
  invalidateAppListCache();
  renderAppCampList();
}

var appSortKey = 'created';
var appSortDir = 'desc';

// 신청 상태 탭 (단일 선택, ''=전체). 다중 필터 appStatusMulti 를 대체.
//   신청 1건 = status 4종(pending/approved/rejected/cancelled) 중 하나로 상호 배타라 탭(단일)이 개념에 맞음.
var _appStatusTab = '';

// 신청 상태 탭 정의 — 처리 흐름 순서(심사중 → 승인/미승인 → 취소) + 전체
const APP_STATUS_TABS = [
  { code: '',          label: '전체' },
  { code: 'pending',   label: '심사중' },
  { code: 'approved',  label: '승인' },
  { code: 'rejected',  label: '미승인' },
  { code: 'cancelled', label: '취소' },
];

// 신청 상태 탭 바 렌더 — 건수는 renderAppCampList 가 넘겨준 appStatusCountsMap(자기 필터 제외 집계).
//   전체 탭 = 4종 합(모든 신청은 4종 중 하나). renderAppCampList 가 매번 호출 → 필터 변경 즉시 반영.
function renderAppStatusTabs(countsMap) {
  const bar = $('appStatusTabBar');
  if (!bar) return;
  const c = countsMap || {};
  const totalAll = (c.pending||0) + (c.approved||0) + (c.rejected||0) + (c.cancelled||0);
  const active = _appStatusTab || '';
  bar.innerHTML = APP_STATUS_TABS.map(tab => {
    const n = tab.code === '' ? totalAll : (c[tab.code] || 0);
    const isOn = tab.code === active;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== '' ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code}" onclick="setAppStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

// 신청 상태 탭 클릭 → 단일 상태 필터로 목록 재조회 (활성 표시는 renderAppCampList 내부 재렌더로 갱신)
function setAppStatusTab(btn) {
  _appStatusTab = btn.dataset.status || '';
  renderAppCampList();
}

function toggleAppSort(key) {
  if (appSortKey === key) {
    appSortDir = appSortDir === 'desc' ? 'asc' : 'desc';
  } else {
    appSortKey = key;
    appSortDir = 'desc';
  }
  document.querySelectorAll('.app-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === appSortKey) {
      el.classList.add(appSortDir);
      el.textContent = appSortDir === 'asc' ? '▲' : '▼';
    }
  });
  renderAppCampList();
}

var appLazy = null;
const APP_PAGE_SIZE = 50;
var _appListCache = null;

function invalidateAppListCache() { _appListCache = null; }

async function renderAppCampList() {
  const bodyEl = $('appTableBody');
  const countEl = $('appTotalCount');
  if (!bodyEl) return;

  if (!_appListCache) {
    const [cs, as, us] = await Promise.all([fetchCampaigns(), fetchApplications(), fetchInfluencers()]);
    _appListCache = { camps: cs, allAppsRaw: as, users: us };
  }
  // 응모건 메시지 본인 미열람 배지 맵 (응모 행 메시지 버튼용)
  await loadApplicantMsgUnread();
  let camps = _appListCache.camps.slice();
  const allAppsRaw = _appListCache.allAppsRaw;
  let apps = allAppsRaw.slice();
  const users = _appListCache.users;
  const _auditIds = buildAuditIdSet(users);  // 감사용 응모는 빈자리 집계에서 제외

  // 캠페인 ↔ 타입 쌍별 연동: 현재 선택값 스냅샷
  const typeValsRaw = getMultiFilterValues('appTypeMulti');
  const campValsRaw = getMultiFilterValues('appCampMulti');

  // 캠페인 옵션: 타입 제약 있으면 해당 타입 캠페인만 노출
  const sortedCampsAll = camps.slice().sort((a,b) => new Date(b.created_at) - new Date(a.created_at));
  const campOptionsSource = typeValsRaw.length > 0
    ? sortedCampsAll.filter(c => typeValsRaw.includes(c.recruit_type))
    : sortedCampsAll;

  // 타입 옵션: 캠페인 제약 있으면 해당 캠페인들의 타입 합집합만 노출
  const ALL_RECRUIT_TYPES = ['monitor','gifting','visit'];
  const availableTypes = campValsRaw.length > 0
    ? ALL_RECRUIT_TYPES.filter(t => camps.some(c => campValsRaw.includes(c.id) && c.recruit_type === t))
    : ALL_RECRUIT_TYPES;

  // stale 선택 감지 → 경고 토스트 (자동 해제는 syncMultiFilter 복원 단계에서 자연 탈락)
  const campStale = campValsRaw.filter(v => !campOptionsSource.some(c => c.id === v));
  const typeStale = typeValsRaw.filter(v => !availableTypes.includes(v));
  if (campStale.length > 0 && typeof toast === 'function') toast(`선택한 캠페인 ${campStale.length}건이 타입 필터에 맞지 않아 해제되었습니다`, 'info');
  if (typeStale.length > 0 && typeof toast === 'function') toast(`선택한 타입 ${typeStale.length}건이 캠페인 필터에 맞지 않아 해제되었습니다`, 'info');

  // 필터 값 추출 (카운트·필터 적용 공용) — 동적 카운트를 위해 미리 확보
  const campRtLookup = new Map(camps.map(c => [c.id, c.recruit_type]));
  const campStatusLookup = new Map(camps.map(c => [c.id, c.status]));  // 신청의 캠페인 상태 조회용
  const appTypeVals = getMultiFilterValues('appTypeMulti');
  const appCampStatusVals = getMultiFilterValues('appCampStatusMulti');
  const appStatusTab = _appStatusTab || '';  // 신청 상태 탭(단일, ''=전체)
  const campFilterVals = getMultiFilterValues('appCampMulti');
  const searchVal = ($('appSearch')?.value || '').trim().toLowerCase();
  // 단일 신청이 필터를 통과하는지 — skip 지정 시 그 필터만 무시(옵션별 동적 카운트용)
  const passesAppFilters = (a, skip) => {
    if (skip !== 'type'       && appTypeVals.length       && !appTypeVals.includes(campRtLookup.get(a.campaign_id))) return false;
    if (skip !== 'campStatus' && appCampStatusVals.length && !appCampStatusVals.includes(campStatusLookup.get(a.campaign_id))) return false;
    if (skip !== 'status'     && appStatusTab            && a.status !== appStatusTab) return false;
    if (skip !== 'camp'       && campFilterVals.length    && !campFilterVals.includes(a.campaign_id)) return false;
    if (searchVal && !matchSearchTokens(searchVal, [a.user_name, a.user_email, a.cancel_reason, a.cancel_reason_code])) return false;
    return true;
  };
  // 옵션별 카운트 — 「자기 자신 필터 제외 + 다른 모든 필터 적용」 후 집계 (동적, 결과물 관리 페인과 동일 방식)
  const appCampCounts = {};
  const appTypeCounts = {};
  const appStatusCountsMap = {};
  const appCampStatusCounts = {};
  for (const a of allAppsRaw) {
    if (a.campaign_id && passesAppFilters(a, 'camp')) appCampCounts[a.campaign_id] = (appCampCounts[a.campaign_id] || 0) + 1;
    const rt = campRtLookup.get(a.campaign_id);
    if (rt && passesAppFilters(a, 'type')) appTypeCounts[rt] = (appTypeCounts[rt] || 0) + 1;
    const cst = campStatusLookup.get(a.campaign_id);
    if (cst && passesAppFilters(a, 'campStatus')) appCampStatusCounts[cst] = (appCampStatusCounts[cst] || 0) + 1;
    if (a.status && passesAppFilters(a, 'status')) appStatusCountsMap[a.status] = (appStatusCountsMap[a.status] || 0) + 1;
  }

  // 드롭다운 동기화 — count 포함
  syncCampMultiFilter('appCampMulti', campOptionsSource, () => renderAppCampList(), appCampCounts);
  syncMultiFilter('appTypeMulti', '전체 타입',
    availableTypes.map(t => ({value:t, label:RECRUIT_TYPE_LABEL_KO[t] || t, count: appTypeCounts[t] || 0})),
    () => renderAppCampList());
  // 캠페인 상태 필터 — 캠페인 관리 페인과 동일 6단계 (admin.js CAMP_STATUS_TABS 와 라벨·순서 통일)
  syncMultiFilter('appCampStatusMulti', '전체 상태', [
    {value:'draft',     label:'준비',     count: appCampStatusCounts.draft     || 0},
    {value:'scheduled', label:'모집예정', count: appCampStatusCounts.scheduled || 0},
    {value:'active',    label:'모집중',   count: appCampStatusCounts.active    || 0},
    {value:'closed',    label:'모집마감', count: appCampStatusCounts.closed    || 0},
    {value:'ended',     label:'종료',     count: appCampStatusCounts.ended     || 0},
    {value:'expired',   label:'노출종료', count: appCampStatusCounts.expired   || 0},
  ], () => renderAppCampList());
  // 신청 상태 탭 바 — 다중 필터 대체(전체 + 4종). 건수는 자기 필터 제외 집계.
  renderAppStatusTabs(appStatusCountsMap);

  // 필터 적용 — 위에서 정의한 passesAppFilters 로 일괄 (타입·캠페인상태·신청상태·캠페인·검색 모두 포함)
  //   검색은 인플루언서 전용 (캠페인은 검색형 캠페인 드롭다운으로 분리)
  apps = apps.filter(a => passesAppFilters(a));

  // 보기 초기화 버튼 — 필터·검색·정렬 중 하나라도 비기본이면 노출 (필터+정렬+검색 통합)
  const _appViewActive = ['appTypeMulti','appCampStatusMulti','appCampMulti'].some(id => getMultiFilterValues(id).length > 0)
    || !!_appStatusTab
    || !!(($('appSearch')?.value || '').trim())
    || !(appSortKey === 'created' && appSortDir === 'desc');
  const _appViewBtn = $('btnAppViewReset'); if (_appViewBtn) _appViewBtn.style.display = _appViewActive ? '' : 'none';

  const appDir = appSortDir === 'asc' ? 1 : -1;
  if (appSortKey === 'status') {
    const statusOrder = {pending:0, approved:1, rejected:2, cancelled:3};
    apps.sort((a,b) => ((statusOrder[a.status]??9) - (statusOrder[b.status]??9)) * appDir);
  } else if (appSortKey === 'name') {
    apps.sort((a,b) => (a.user_name||'').localeCompare(b.user_name||'', 'ja') * appDir);
  } else if (appSortKey === 'deadline') {
    // 모집기간 정렬 — 캠페인 마감일(deadline) 기준. 마감일 없는 건 항상 뒤로
    const campMap = new Map(camps.map(c => [c.id, c]));
    apps.sort((a,b) => {
      const da = campMap.get(a.campaign_id)?.deadline;
      const dbl = campMap.get(b.campaign_id)?.deadline;
      const ta = da ? new Date(da).getTime() : Infinity;
      const tb = dbl ? new Date(dbl).getTime() : Infinity;
      if (ta === tb) return 0;
      return (ta - tb) * appDir;
    });
  } else {
    apps.sort((a,b) => (new Date(a.created_at) - new Date(b.created_at)) * appDir);
  }

  if (countEl) countEl.textContent = `총 ${apps.length}건`;

  const renderAppRow = (a) => {
    const camp = camps.find(c => c.id === a.campaign_id) || {};
    const u = users.find(u => u.email === a.user_email) || {};
    const _campRemaining = Math.max((camp.slots||0)-countNonAuditApproved(allAppsRaw, camp.id, _auditIds),0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    const brandPrimary = brandLabelAdmin(camp);
    const brandSub     = '';
    const productPrimary = camp.product_ko || camp.product || '';
    const productSub     = (camp.product_ko && camp.product && camp.product_ko !== camp.product) ? camp.product : '';
    const recruitStart   = camp.recruit_start ? formatDate(camp.recruit_start) : '';
    const recruitEnd     = camp.deadline ? formatDate(camp.deadline) : '';
    // 마스킹된 관리자 등급에겐 line_id 가 NULL 로 오므로 has_line 로 존재 여부만 정확히 판정(PR3 조각 B)
    const _lineDisp = maskedFieldByFlag(u.line_id, u.has_line);
    return `<tr data-id="${esc(a.id)}" class="${u.is_audit?'audit-row':''}">
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${imgThumb(thumbUrl,96,70)}" data-orig="${thumbUrl}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0;flex:1">
            <div>${typeLabel}</div>
            <div style="display:flex;align-items:flex-start;gap:4px"><strong style="font-size:13px;display:block;word-break:break-word;line-height:1.4;flex:1">${esc(camp.title)||'—'}</strong>${campPreviewBtn(camp.id)}</div>
            ${camp.slots?(()=>{const _r=Math.max(camp.slots-countNonAuditApproved(allAppsRaw, camp.id, _auditIds),0);return `<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_r>0?'var(--green)':'var(--red)'};font-weight:600">${_r>0?_r+'건':'없음'}</span></div>`;})():''}
          </div>
        </div>
      </td>
      <td>${channelChipsHtml(camp.channel, camp.channel_match)}</td>
      <td style="font-size:12px;color:var(--ink);min-width:100px;max-width:160px;word-break:break-word">
        ${brandPrimary?esc(brandPrimary):'—'}
        ${brandSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(brandSub)}</div>`:''}
      </td>
      <td style="font-size:12px;color:var(--ink);min-width:200px;max-width:260px;word-break:break-word">
        ${productPrimary?esc(productPrimary):'—'}
        ${productSub?`<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(productSub)}</div>`:''}
      </td>
      <td style="font-size:11px;color:var(--ink);white-space:nowrap">
        ${(recruitStart||recruitEnd) ? `${recruitStart||'—'} ~ ${recruitEnd||'—'}` : '<span style="color:var(--muted)">—</span>'}
      </td>
      <td>
        <div class="applicant-name-cell">
          <div class="applicant-name-info">
            <div class="link-cell" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}${auditBadgeHtml(u)}${influencerStatusBadges(u)}</div>
            <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${_lineDisp?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(_lineDisp)}</div>`:''}
          </div>
          ${renderApplicantMsgBtn(a)}
        </div>
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td style="white-space:nowrap">${getStatusBadgeKo(a.status, a.auto_reject_reason)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${(_campRemaining<=0 && !u.is_audit)?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="rejectApplication('${a.id}', ${((typeof isEventCampaign === 'function') && isEventCampaign(camp)) ? 'true' : 'false'})">미승인</button></div>`
        :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="revertApplication('${a.id}', ${((typeof isEventCampaign === 'function') && isEventCampaign(camp)) ? 'true' : 'false'})">되돌리기</button></div>`}
      </td>
    </tr>`;
  };
  const scrollRoot = bodyEl.closest('.admin-table-wrap');
  if (appLazy) appLazy.destroy();
  appLazy = mountLazyList({
    tbody: bodyEl,
    scrollRoot,
    rows: apps,
    renderRow: renderAppRow,
    pageSize: APP_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>',
  });
  // cancel_reason 캐시 미리 채움 — 상세 모달에서 카테고리 라벨 즉시 표시
  ensureCancelReasonsCache();
}

// 미승인(rejected)·되돌리기(pending) 전 가드 — 진행 가능하면 true, 차단/사용자 취소면 false.
//   (A) 송금완료(paid) 정산이 있으면 완전 차단(서버 트리거 마이그레이션 247 이 최종 방어선이나,
//       여기서 관리자에게 친절한 안내로 먼저 막는다. campaign_manager 는 정산 조회 권한이 없어
//       이 헬퍼가 0을 반환할 수 있으나, 그 경우에도 서버 트리거가 차단하므로 안전)
//   (B) 제출된 결과물(draft 제외)이 있으면 확인 후 진행 — 확인 시 결과물은 검수 불필요로 빠지고
//       정산은 자동 보류(마이그레이션 246)된다
async function guardRejectOrRevert(appId, status) {
  if (typeof hasPaidSettlementForApplication === 'function' && await hasPaidSettlementForApplication(appId)) {
    $('alertModalMessage').innerHTML = '이미 <strong>송금 완료된 정산</strong>이 있어<br>이 신청은 미승인·되돌리기 할 수 없습니다.';
    openModal('alertModal');
    return false;
  }
  if (typeof fetchDeliverablesByApplication === 'function') {
    const dels = await fetchDeliverablesByApplication(appId);
    const submitted = (dels || []).filter(d => d && d.status !== 'draft');
    if (submitted.length > 0) {
      const latest = submitted.map(d => d.submitted_at || d.created_at).filter(Boolean).sort().slice(-1)[0];
      const dateStr = latest ? formatDate(latest) : '';
      const actLabel = status === 'rejected' ? '미승인' : '되돌리기';
      const ok = await showConfirm(`${dateStr ? dateStr + '에 ' : ''}제출된 결과물이 있습니다. 그래도 ${actLabel} 하시겠습니까?`);
      if (!ok) return false;
    }
  }
  return true;
}

async function updateAppStatus(appId, status) {
  try {
    // 승인 시 모집인원 초과 체크
    if (status === 'approved') {
      const {data: app} = await db?.from('applications').select('campaign_id, user_id').eq('id', appId).maybeSingle();
      if (app) {
        // 감사용 응모는 정원과 무관하게 승인 허용 (격리 — 마이그레이션 179·181)
        //   ⚠️ 원본 표가 아니라 **가림막 뷰**로 읽는다(마이그레이션 212). 원본을 직접
        //      부르면 민감정보 가림이 적용되지 않고, 그 통로를 열어 두면 정책을 좁혀도
        //      우회로가 남는다(전수조사 1-3 / 조치 계획 묶음 E-1).
        const {data: applicant} = await db?.from('influencers_admin_view').select('is_audit').eq('id', app.user_id).maybeSingle();
        if (!applicant?.is_audit) {
          const {data: camp} = await db?.from('campaigns').select('slots').eq('id', app.campaign_id).maybeSingle();
          const slots = camp?.slots || 0;
          if (slots > 0) {
            const approvedApps = await fetchApplications({campaign_id: app.campaign_id, status: 'approved'});
            // 승인된 감사용 응모는 정원 카운트에서 제외
            const ids = approvedApps.map(a => a.user_id).filter(Boolean);
            let auditSet = new Set();
            if (ids.length) {
              const {data: auditRows} = await db?.from('influencers_admin_view').select('id').eq('is_audit', true).in('id', ids) || {};
              auditSet = new Set((auditRows || []).map(r => r.id));
            }
            const nonAuditApproved = approvedApps.filter(a => !auditSet.has(a.user_id)).length;
            if (nonAuditApproved >= slots) {
              $('alertModalMessage').innerHTML = `이 캠페인의 모집 정원은 <strong>${esc(String(slots))}명</strong>으로<br>이미 모두 찼습니다.`;
              openModal('alertModal');
              return;
            }
          }
        }
      }
    }
    // 미승인(rejected)·되돌리기(pending) 가드 — 승인 후 결과물/정산이 붙은 신청 보호
    if ((status === 'rejected' || status === 'pending') && !(await guardRejectOrRevert(appId, status))) return;
    const reviewerName = currentAdminInfo?.name || currentUserProfile?.name || '관리자';
    await updateApplication(appId, {
      status,
      reviewed_by: reviewerName,
      reviewed_at: new Date().toISOString()
    });
    const msgs = {approved:'승인했습니다', rejected:'미승인 처리했습니다', pending:'심사중으로 되돌렸습니다'};
    toast(msgs[status]||'상태가 변경되었습니다', status==='approved'?'success':'');
    invalidateAppListCache();
    renderAppCampList();
    loadAdminData();
    if (typeof loadCampApplicants === 'function' && currentCampApplicantId) loadCampApplicants();
  } catch(e) {
    const _m = (e && e.message) || '';
    // 서버 트리거(마이그레이션 247)가 송금완료 정산 때문에 막은 경우 — UI 가드를 우회한 등급
    // (정산 조회 권한 없는 campaign_manager)에도 친절한 안내로 전환
    if (_m.includes('settlement_already_paid')) {
      $('alertModalMessage').innerHTML = '이미 <strong>송금 완료된 정산</strong>이 있어<br>이 신청은 미승인·되돌리기 할 수 없습니다.';
      openModal('alertModal');
      return;
    }
    toast('상태 변경 오류: '+friendlyError(e.message),'error');
  }
}
