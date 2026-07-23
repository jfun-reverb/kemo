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
  _campDelivCertTab = '';
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
  const filter = $('campAppFilterStatus')?.value || '';
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
  const approved = apps.filter(a=>a.status==='approved').length;
  const pending = apps.filter(a=>a.status==='pending').length;

  let camp = allCampaigns.find(c=>c.id===currentCampApplicantId);
  if (!camp) {
    // 운영현황 등에서 직접 진입해 캠페인 목록(allCampaigns)이 아직 안 채워진 경우 보장
    const all = await fetchCampaigns();
    camp = all.find(c=>c.id===currentCampApplicantId);
  }
  // 제목이 비어 있으면(운영현황 진입) 캠페인명으로 보강
  if (camp && !($('campApplicantsTitle')?.textContent || '').trim()) $('campApplicantsTitle').textContent = camp.title || '';
  const slots = camp?.slots || 0;
  const remaining = Math.max(slots - allApproved, 0);
  $('campApplicantsSlots').innerHTML = `모집 인원: <strong>${slots}명</strong> · 빈자리: <strong style="color:${remaining>0?'var(--green)':'var(--red)'}">${remaining>0?remaining+'건':'없음'}</strong>`;

  $('campApplicantsSubtitle').textContent = `신청자 목록`;
  $('campApplicantsStats').innerHTML = `
    <span style="color:var(--ink);font-weight:600">${total}명 신청</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--green)">승인 ${approved}명</span>
    <span style="margin:0 6px;color:var(--line)">|</span>
    <span style="color:var(--gold)">심사중 ${pending}명</span>
  `;

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
  const snsCell = (channel, raw) => {
    const handle = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, raw) : (raw || '').replace(/^@/,'').trim();
    if (!handle) return '—';
    const safe = esc(handle);
    const url = (typeof snsProfileUrl === 'function') ? snsProfileUrl(channel, handle) : '';
    const inner = url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${safe}</a>` : `@${safe}`;
    return `<div style="max-width:140px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${safe}">${inner}</div>`;
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
      <div class="link-cell" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${auditBadgeHtml(_u)}${adminBadge(a.user_email)}${influencerStatusBadges(_u)}</div>
      <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${_lineDisp?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(_lineDisp)}</div>`:''}
      <div style="margin-top:4px">${renderApplicantMsgBtn(a)}</div>
    </td>
    <td>${snsCell('instagram', _u.ig || a.ig_id || a.user_ig)}<div style="font-size:11px;color:var(--muted)">${igF}명</div></td>
    <td>${snsCell('x', _u.x)}<div style="font-size:11px;color:var(--muted)">${xF}명</div></td>
    <td>${snsCell('tiktok', _u.tiktok)}<div style="font-size:11px;color:var(--muted)">${ttF}명</div></td>
    <td>${snsCell('youtube', _u.youtube)}<div style="font-size:11px;color:var(--muted)">${ytF}명</div></td>
    <td style="font-weight:700;color:var(--pink)">${totalF}</td>
    <td>${msgCell(a.message, a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td>${getStatusBadgeKo(a.status, a.auto_reject_reason)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
    <td style="white-space:nowrap">
      ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${(remaining<=0 && !_u.is_audit)?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
      :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
      :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
    </td>
  </tr>`;
  };
  if (campApplicantsLazy) campApplicantsLazy.destroy();
  campApplicantsLazy = mountLazyList({
    tbody: body,
    scrollRoot: body.closest('.admin-table-wrap'),
    rows: apps,
    renderRow: renderCampApplicantRow,
    pageSize: CAMP_APPLICANTS_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="10" style="text-align:center;color:var(--muted);padding:32px">아직 신청이 없습니다</td></tr>',
  });

  // 결과물 탭 렌더 + 상단 탭 건수 갱신 (같은 데이터로 한 번에 — 추가 조회 없음)
  renderCampDelivTab(camp, allDelivs, allApps, _users);
  renderCampDetailTabs(total, allDelivs);
}

// ── 캠페인 진행현황: 신청자 목록 / 결과물 목록 탭 ─────────────────────
//   결과물 표는 결과물 관리 페인과 같은 행 빌더(renderDelivAppRow)를 compact 로 재사용한다.
//   두 화면이 따로 놀지 않게 판정·렌더를 단일 소스로 유지하는 게 목적.
var _campDetailTab = 'applicants';   // 'applicants' | 'deliverables'
var _campDelivCertTab = '';          // 결과물 탭 안의 인증 상태 필터('' = 전체)

function renderCampDetailTabs(appCount, allDelivs) {
  const bar = $('campDetailTabBar');
  if (!bar) return;
  const delivCount = new Set((allDelivs || []).map(d => d.application_id).filter(Boolean)).size;
  const tabs = [
    { code: 'applicants',   label: '신청자 목록', n: appCount || 0 },
    { code: 'deliverables', label: '결과물 목록', n: delivCount },
  ];
  bar.innerHTML = tabs.map(t => {
    const cls = 'status-tab-btn' + (t.code === _campDetailTab ? ' on' : '') + (t.n === 0 ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-tab="${t.code}" onclick="setCampDetailTab(this)">`
      + `${t.label}<span class="tab-count">(${t.n})</span></button>`;
  }).join('');
  applyCampDetailTabVisibility();
}

function setCampDetailTab(btn) {
  _campDetailTab = btn.dataset.tab || 'applicants';
  const bar = $('campDetailTabBar');
  if (bar) bar.querySelectorAll('.status-tab-btn').forEach(b => b.classList.toggle('on', b.dataset.tab === _campDetailTab));
  applyCampDetailTabVisibility();
}

// 탭에 따라 카드·필터 노출 전환. 상태·검색 필터는 신청자 목록 전용이라 결과물 탭에선 감춘다.
function applyCampDetailTabVisibility() {
  const isDeliv = _campDetailTab === 'deliverables';
  const appCard = $('campApplicantsCard');
  const delivCard = $('campDelivCard');
  const filterBar = $('campAppFilterBar');
  if (appCard) appCard.style.display = isDeliv ? 'none' : '';
  if (delivCard) delivCard.style.display = isDeliv ? '' : 'none';
  if (filterBar) filterBar.style.display = isDeliv ? 'none' : 'flex';
}

// 결과물 탭 본문 — 인증 상태 탭 + 표.
//   미제출 승인 신청도 빈 행으로 포함해야 「미제출」 집계가 결과물 관리 페인과 같아진다(includeApps).
function renderCampDelivTab(camp, allDelivs, allApps, users) {
  const tbody = $('campDelivBody');
  if (!tbody) return;
  if (!camp) { tbody.innerHTML = ''; return; }
  const campMap = new Map([[camp.id, camp]]);
  const infMap = {};
  (users || []).forEach(u => { if (u.id) infMap[u.id] = u; });
  const approvedApps = (allApps || []).filter(a => a.status === 'approved');
  const groups = buildDeliverableGroups(allDelivs || [], campMap, { includeApps: approvedApps, infMap });
  let list = Array.from(groups.values());
  // 신청 status 를 그룹에 채워 「검수 불필요」(반려·취소된 신청) 판정이 결과물 관리와 같아지게 한다
  const appStatusById = {};
  (allApps || []).forEach(a => { appStatusById[a.id] = a.status; });
  list.forEach(g => { if (!g.application_status) g.application_status = appStatusById[g.application_id] || null; });

  const counts = { success: 0, submitting: 0, none: 0, excluded: 0 };
  list.forEach(g => { const s = computeCertStatus(g); if (counts[s] != null) counts[s]++; });
  renderCampDelivCertTabs(counts);

  if (_campDelivCertTab) list = list.filter(g => computeCertStatus(g) === _campDelivCertTab);
  // 최근 제출 순(미제출은 뒤로)
  list.sort((a, b) => (b.latest_submitted_at || '').localeCompare(a.latest_submitted_at || ''));

  const stats = $('campDelivStats');
  if (stats) stats.textContent = `${list.length}건`;
  tbody.innerHTML = list.length
    ? list.map(g => renderDelivAppRow(g, { compact: true })).join('')
    : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:32px">해당하는 결과물이 없습니다</td></tr>';
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
  const priceTxt = (camp.product_price != null && camp.product_price !== '') ? Number(camp.product_price).toLocaleString('ja-JP') + '円' : '';
  const recruitRange = brandOpsDateRange(camp.recruit_start, camp.deadline);
  let buyRange = '', buyLabel = '';
  if (camp.recruit_type === 'monitor') { buyRange = brandOpsDateRange(camp.purchase_start, camp.purchase_end); buyLabel = '구매'; }
  else if (camp.recruit_type === 'visit') { buyRange = brandOpsDateRange(camp.visit_start, camp.visit_end); buyLabel = '방문'; }
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
          ${channelTxt?`<span style="color:var(--muted)">${channelTxt}</span>`:''}
          ${priceTxt?`<span style="color:var(--ink);font-weight:600">${priceTxt}</span>`:''}
        </div>
      </div>
    </div>
    <div style="margin-top:10px;border-top:1px solid var(--surface-dim);padding-top:8px">
      ${recruitRange?`<div class="camp-ops-row"><span class="k">모집</span><span class="v">${esc(recruitRange)}</span></div>`:''}
      ${buyRange?`<div class="camp-ops-row"><span class="k">${buyLabel}</span><span class="v">${esc(buyRange)}</span></div>`:''}
      ${submitTxt?`<div class="camp-ops-row"><span class="k">제출마감</span><span class="v">${esc(submitTxt)}</span></div>`:''}
    </div>
  </div>`;
}

// 모집·결과물 현황 카드 — 진행바 3종(모집/제출/승인) + 보조 수치
function campOpsStatusCard(camp, allApps, allDelivs, stats) {
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
  if (box) box.insertAdjacentHTML('beforeend', campOpsCostCard(app));
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
  return `<div class="camp-ops-card">
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
        <div class="link-cell" onclick="openInfluencerModal('${u.id||''}')">${esc(a.user_name)||'—'}${auditBadgeHtml(u)}${influencerStatusBadges(u)}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)||''}</div>${_lineDisp?`<div style="font-size:11px;color:var(--muted)">LINE: ${esc(_lineDisp)}</div>`:''}
        <div style="margin-top:4px">${renderApplicantMsgBtn(a)}</div>
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td style="white-space:nowrap">${getStatusBadgeKo(a.status, a.auto_reject_reason)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${(_campRemaining<=0 && !u.is_audit)?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :a.status==='cancelled'?`<div style="font-size:10px;color:var(--muted)">${a.cancelled_at?formatDateTime(a.cancelled_at):'—'}</div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
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
        const {data: applicant} = await db?.from('influencers').select('is_audit').eq('id', app.user_id).maybeSingle();
        if (!applicant?.is_audit) {
          const {data: camp} = await db?.from('campaigns').select('slots').eq('id', app.campaign_id).maybeSingle();
          const slots = camp?.slots || 0;
          if (slots > 0) {
            const approvedApps = await fetchApplications({campaign_id: app.campaign_id, status: 'approved'});
            // 승인된 감사용 응모는 정원 카운트에서 제외
            const ids = approvedApps.map(a => a.user_id).filter(Boolean);
            let auditSet = new Set();
            if (ids.length) {
              const {data: auditRows} = await db?.from('influencers').select('id').eq('is_audit', true).in('id', ids) || {};
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
