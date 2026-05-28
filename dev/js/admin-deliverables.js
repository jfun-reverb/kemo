// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-deliverables.js
// ═════════════════════════════════════════════════════════════════
//
// 결과물 검수 페인 (admin.js 파일 분리).
//   · 목록/필터/정렬/배지 (loadDeliverables/renderDeliverablesList/refreshDelivSidebarBadge 등)
//   · 상세/합본 검수 모달 + 승인/반려/되돌리기 (openDelivDetail/openDelivCombined/approveDeliv/submitDelivReject 등)
//   · 영수증 정보 인플레이스 수정 + 변경 이력 (renderReceiptInfoBlock/saveReceiptEdit/toggleReceiptHistory)
//   · 상태: _delivCache/_delivDetailCurrent/_delivSort/delivLazy/DELIV_PAGE_SIZE/_delivRejectCtx/_delivCombinedRefreshAppId
//
// ⚠ loadDeliverables 는 switchAdminPane(admin-core.js) loaders 가, refreshDelivSidebarBadge 는
//   대시보드 loadAdminData(admin.js)가 호출 → 전역 유지(이름 변경 금지). 빌드 순서상 admin.js 앞.
// ⚠ 이미지 라이트박스(openImageLightbox)는 admin-core.js 에 있음 — 여기선 호출만.
// ═════════════════════════════════════════════════════════════════

// ============================================================
// Stage 2: 결과물 관리 (Deliverables)
// ============================================================
let _delivCache = [];
let _delivDetailCurrent = null;  // 열려 있는 상세 {id, version}
let _delivSort = {col: null, dir: null};  // 수동 정렬 상태 (null이면 기본 정렬 사용)

// ════════════════════════════════════════════════════════════════════
// SECTION: DELIVERABLES — 결과물 검수 페인 + 라이트박스 + 통합 보기
// ════════════════════════════════════════════════════════════════════

function toggleDelivSort(col) {
  // 같은 컬럼: asc → desc → 해제
  if (_delivSort.col === col) {
    if (_delivSort.dir === 'asc') _delivSort.dir = 'desc';
    else if (_delivSort.dir === 'desc') { _delivSort.col = null; _delivSort.dir = null; }
    else _delivSort.dir = 'asc';
  } else {
    _delivSort.col = col;
    _delivSort.dir = 'asc';
  }
  renderDeliverablesList();
}

function resetDelivFiltersAndSort() {
  resetMultiFilter('delivRecruitTypeMulti', '전체 타입');
  resetMultiFilter('delivReceiptStatusMulti', '전체');
  resetMultiFilter('delivResultStatusMulti', '전체');
  resetMultiFilter('delivCampMulti', '전체 캠페인');
  const q = $('delivSearch'); if (q) q.value = '';
  const cb = $('delivIncludeMissing'); if (cb) cb.checked = false;
  _delivSort = {col: null, dir: null};
  renderDeliverablesList();
}

function applyDelivSortIndicators() {
  document.querySelectorAll('#adminPane-deliverables .sort-arrows').forEach(el => {
    const col = el.getAttribute('data-sort');
    if (_delivSort.col === col) {
      el.textContent = _delivSort.dir === 'asc' ? '▲' : '▼';
      el.style.color = 'var(--dark-pink)';
    } else {
      el.textContent = '▲▼';
      el.style.color = '';
    }
  });
}

async function loadDeliverables() {
  await renderDeliverablesList();  // 끝에서 refreshDelivSidebarBadge 호출됨
}

// 사이드바 "결과물 관리" 메뉴 옆 검수 대기(pending) 배지 갱신
async function refreshDelivSidebarBadge() {
  const el = $('adminDelivSi');
  if (!el) return;
  try {
    const n = await fetchPendingDeliverableCount();
    el.innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">fact_check</span><span class="si-text">결과물 관리</span>${n>0?`<span class="admin-si-badge">${n>999?'999+':n}</span>`:''}`;
  } catch(e) { /* 무시 */ }
}

// 신청 관리 사이드바 배지 — 대기(pending) 개수 (가벼운 count 쿼리, 전건 fetch 불필요)
async function refreshApplySidebarBadge() {
  const el = $('adminApplySi');
  if (!el) return;
  try {
    const n = await fetchPendingApplicationCount();
    el.innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">신청 관리</span>${n>0?`<span class="admin-si-badge">${n>999?'999+':n}</span>`:''}`;
  } catch(e) { /* 무시 */ }
}

var delivLazy = null;
const DELIV_PAGE_SIZE = 50;

async function renderDeliverablesList() {
  const tbody = $('delivTableBody');
  if (!tbody) return;
  tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>';
  await loadApplicantMsgUnread();  // 응모건 메시지 본인 미열람 배지 맵

  // 캠페인 리스트 로드 + 모집타입↔캠페인 캐스케이드
  const campsForFilter = await fetchCampaigns().catch(() => []);
  const sortedCampsForFilter = campsForFilter.slice().sort((a,b) => new Date(b.created_at) - new Date(a.created_at));

  const recruitTypeVals = getMultiFilterValues('delivRecruitTypeMulti');
  const delivCampValsRaw = getMultiFilterValues('delivCampMulti');

  // 캠페인 옵션: 모집 타입 필터 있으면 해당 타입 캠페인만 노출
  const campOptionsSource = recruitTypeVals.length > 0
    ? sortedCampsForFilter.filter(c => recruitTypeVals.includes(c.recruit_type))
    : sortedCampsForFilter;

  const campStale = delivCampValsRaw.filter(v => !campOptionsSource.some(c => c.id === v));
  if (campStale.length > 0 && typeof toast === 'function') toast(`선택한 캠페인 ${campStale.length}건이 모집 타입 필터에 맞지 않아 해제되었습니다`, 'info');

  const receiptStatusVals = getMultiFilterValues('delivReceiptStatusMulti');
  const resultStatusVals = getMultiFilterValues('delivResultStatusMulti');
  const delivCampVals = getMultiFilterValues('delivCampMulti');
  const includeMissing = !!$('delivIncludeMissing')?.checked;
  const search = ($('delivSearch')?.value || '').trim().toLowerCase();

  // deliverables 전체 조회 (status·kind는 클라이언트에서 분기)
  const allDelivs = await fetchDeliverables({status: 'all', kind: 'all', campaign_id: 'all'});
  _delivCache = allDelivs;

  // 미제출 토글 ON 시 당첨된(approved) 신청도 fetch — deliverable 0건 행 노출
  let approvedApps = [];
  let infMissingMap = {};
  if (includeMissing) {
    approvedApps = await fetchApplications({status: 'approved'});
    const userIds = [...new Set(approvedApps.map(a => a.user_id).filter(Boolean))];
    infMissingMap = await fetchInfluencersByIds(userIds);
  }

  // 신청(application_id) 단위 group — 한 신청에 영수증·결과물 묶음
  //   result 슬롯 = post (gifting/visit) 단일
  //   reviewByChannel 슬롯 = monitor 캠페인의 채널별 review_image 최신 1개 매핑 ({channel_code: deliverable})
  //   사양 §5-1 정합: 채널별 별개 결과물을 셀 안에 N개 노출 (행 분리 대신 셀 내 미니 행)
  const groups = new Map();
  const upsertGroup = (appId, camp, inf) => {
    if (!groups.has(appId)) {
      groups.set(appId, {
        application_id: appId,
        campaign: camp || null,
        influencer: inf || null,
        receipt: null,             // kind === 'receipt' 최신
        result: null,              // kind === 'post' 최신 (gifting/visit 전용)
        reviewByChannel: {},       // monitor: {channel_code: review_image deliverable 최신}
        latest_submitted_at: null,
      });
    }
    return groups.get(appId);
  };
  const campMap = new Map(campsForFilter.map(c => [c.id, c]));
  for (const d of allDelivs) {
    if (!d.application_id) continue;
    const camp = d.campaigns || campMap.get(d.campaign_id) || null;
    const g = upsertGroup(d.application_id, camp, d.influencers);
    if (!g.influencer && d.influencers) g.influencer = d.influencers;
    const subAt = d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image') {
      // 채널별 최신 1개 (post_channel NULL 레거시는 무시 — grandfather)
      if (d.post_channel) {
        const prev = g.reviewByChannel[d.post_channel];
        if (!prev || subAt > (prev.submitted_at || '')) g.reviewByChannel[d.post_channel] = d;
      }
    } else if (d.kind === 'post') {
      if (!g.result || subAt > (g.result.submitted_at || '')) g.result = d;
    }
    if (!g.latest_submitted_at || subAt > g.latest_submitted_at) g.latest_submitted_at = subAt;
  }
  if (includeMissing) {
    for (const app of approvedApps) {
      if (groups.has(app.id)) continue;
      upsertGroup(app.id, campMap.get(app.campaign_id) || null, infMissingMap[app.user_id] || null);
    }
  }

  // monitor 신청의 「대표 결과물 상태」 계산 — 필터·정렬에서 사용
  //   우선순위: rejected > pending > approved > none. 채널 1개라도 비완료면 그 상태.
  //   gifting/visit 는 g.result(post) 그대로.
  for (const g of groups.values()) {
    const rt = g.campaign?.recruit_type;
    if (rt !== 'monitor') continue;
    const channels = (g.campaign?.channel || '').split(',').map(c => c.trim()).filter(Boolean);
    if (channels.length === 0) {
      g.result_status_repr = 'none';  // 채널 없는 레거시
      continue;
    }
    const states = channels.map(ch => (g.reviewByChannel[ch]?.status) || 'none');
    let repr = 'approved';
    if (states.includes('rejected')) repr = 'rejected';
    else if (states.includes('pending')) repr = 'pending';
    else if (states.includes('none')) repr = 'none';
    g.result_status_repr = repr;
  }

  // 옵션별 카운트 — 사용자가 「리스트에 해당하는 건수」를 미리 보고 선택할 수 있도록
  // 다른 필터는 무시하고 「전체 데이터에서 그 옵션 만족하는 group 수」 기준
  const allGroups = Array.from(groups.values());
  const campCounts = {};
  const recruitTypeCounts = {};
  const receiptStatusCounts = {pending:0, approved:0, rejected:0, none:0};
  const resultStatusCounts = {pending:0, approved:0, rejected:0, none:0};
  for (const g of allGroups) {
    const cid = g.campaign?.id;
    if (cid) campCounts[cid] = (campCounts[cid] || 0) + 1;
    const rt = g.campaign?.recruit_type;
    if (rt) recruitTypeCounts[rt] = (recruitTypeCounts[rt] || 0) + 1;
    const rs = g.receipt ? g.receipt.status : 'none';
    if (rs in receiptStatusCounts) receiptStatusCounts[rs]++;
    // monitor: 채널별 review_image 종합 대표 상태(result_status_repr) / gifting·visit: g.result(post)
    const xs = (rt === 'monitor')
      ? (g.result_status_repr || 'none')
      : (g.result ? g.result.status : 'none');
    if (xs in resultStatusCounts) resultStatusCounts[xs]++;
  }

  // 캠페인 드롭다운 sync — 카운트 + subLabel(캠페인 번호) 포함
  syncCampMultiFilter('delivCampMulti', campOptionsSource, () => renderDeliverablesList(), campCounts);
  // 모집 타입 드롭다운 — 옵션 자체는 고정이지만 카운트 갱신
  syncMultiFilter('delivRecruitTypeMulti', '전체 타입', [
    {value:'monitor', label:'리뷰어',  count: recruitTypeCounts.monitor || 0},
    {value:'gifting', label:'기프팅',  count: recruitTypeCounts.gifting || 0},
    {value:'visit',   label:'방문형',  count: recruitTypeCounts.visit || 0},
  ], () => renderDeliverablesList());
  // 영수증·결과물 상태 드롭다운 — 카운트 갱신
  syncMultiFilter('delivReceiptStatusMulti', '전체', [
    {value:'pending',  label:'검수대기', count: receiptStatusCounts.pending},
    {value:'approved', label:'승인',    count: receiptStatusCounts.approved},
    {value:'rejected', label:'비승인',  count: receiptStatusCounts.rejected},
    {value:'none',     label:'미제출',  count: receiptStatusCounts.none},
  ], () => renderDeliverablesList());
  syncMultiFilter('delivResultStatusMulti', '전체', [
    {value:'pending',  label:'검수대기', count: resultStatusCounts.pending},
    {value:'approved', label:'승인',    count: resultStatusCounts.approved},
    {value:'rejected', label:'비승인',  count: resultStatusCounts.rejected},
    {value:'none',     label:'미제출',  count: resultStatusCounts.none},
  ], () => renderDeliverablesList());

  // 필터 적용
  let filtered = Array.from(groups.values());
  if (recruitTypeVals.length > 0) filtered = filtered.filter(g => g.campaign && recruitTypeVals.includes(g.campaign.recruit_type));
  if (delivCampVals.length > 0) filtered = filtered.filter(g => g.campaign && delivCampVals.includes(g.campaign.id));
  if (receiptStatusVals.length > 0) filtered = filtered.filter(g => {
    const s = g.receipt ? g.receipt.status : 'none';
    return receiptStatusVals.includes(s);
  });
  if (resultStatusVals.length > 0) filtered = filtered.filter(g => {
    // monitor: reviewByChannel 종합 대표 상태(g.result_status_repr) / gifting·visit: g.result(post)
    const rt = g.campaign?.recruit_type;
    const s = (rt === 'monitor')
      ? (g.result_status_repr || 'none')
      : (g.result ? g.result.status : 'none');
    return resultStatusVals.includes(s);
  });
  // 검색 필터 — 단어 단위 AND 매칭 (matchSearchTokens, 전각/반각 공백 무관)
  if (search) filtered = filtered.filter(g => {
    const inf = g.influencer || {};
    const camp = g.campaign || {};
    return matchSearchTokens(search, [
      inf.name, inf.name_kana, inf.email,
      camp.title, camp.brand, camp.campaign_no,
    ]);
  });

  updateFilterResetBtn('btnDelivFilterReset', ['delivRecruitTypeMulti','delivReceiptStatusMulti','delivResultStatusMulti','delivCampMulti'], 'delivSearch');

  // 정렬: 수동 sort 있으면 그대로, 없으면 검수대기 우선 → 최근 제출일 내림차순
  if (_delivSort.col === 'submitted') {
    const dir = _delivSort.dir === 'desc' ? -1 : 1;
    filtered.sort((a, b) => (a.latest_submitted_at || '').localeCompare(b.latest_submitted_at || '') * dir);
  } else {
    filtered.sort((a, b) => {
      // 검수대기 우선: 영수증 pending 또는 결과물 pending(monitor=대표·gifting/visit=post)
      const resPending = (g) => {
        const rt = g.campaign?.recruit_type;
        return (rt === 'monitor') ? (g.result_status_repr === 'pending') : (g.result?.status === 'pending');
      };
      const aPending = (a.receipt?.status === 'pending') || resPending(a) ? 0 : 1;
      const bPending = (b.receipt?.status === 'pending') || resPending(b) ? 0 : 1;
      if (aPending !== bPending) return aPending - bPending;
      return (b.latest_submitted_at || '').localeCompare(a.latest_submitted_at || '');
    });
  }
  applyDelivSortIndicators();

  const cnt = $('delivTotalCount');
  if (cnt) cnt.textContent = `총 ${filtered.length}건`;

  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (delivLazy) delivLazy.destroy();
  delivLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows: filtered,
    renderRow: renderDelivAppRow,
    pageSize: DELIV_PAGE_SIZE,
    emptyHtml: '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:30px">해당 조건의 결과물이 없습니다.</td></tr>',
  });
  refreshDelivSidebarBadge();
}

// 신청 1건 = 1행. 영수증 셀 / 결과물 셀 각각 상태 배지·미리보기 노출.
// 양쪽 모두 「승인」(또는 gifting의 경우 결과물 단독 「승인」)이면 좌측 초록 보더 = 「완료」
function renderDelivAppRow(g) {
  const camp = g.campaign || {};
  const inf = g.influencer || {};
  const rt = camp.recruit_type;
  const rtBadge = (typeof getRecruitTypeBadgeKoSm === 'function') ? getRecruitTypeBadgeKoSm(rt) : esc(rt || '—');
  const infName = esc(inf.name || '—');
  const infEmail = esc(inf.email || '');
  const infLine = inf.line_id ? `LINE: ${esc(inf.line_id)}` : '';
  const infSub = infEmail + (infLine ? `<br>${infLine}` : '');

  const receiptCell = renderDelivStatusCell(g.receipt, 'receipt', rt);
  // monitor: 채널별 review_image N개 미니 행 / gifting·visit: 기존 g.result(post) 단일 셀
  const resultCell = (rt === 'monitor')
    ? renderDelivResultCellMonitor(g)
    : renderDelivStatusCell(g.result, 'result', rt);

  // 영수증은 monitor(리뷰어) 캠페인에서만 사용. gifting/visit은 영수증 단계 없음.
  const useReceipt = rt === 'monitor';
  // monitor 완료 = 영수증 승인 + 채널별 review_image 모두 승인 (대표 상태 = approved)
  const completed = useReceipt
    ? (g.receipt?.status === 'approved' && g.result_status_repr === 'approved')
    : (g.result?.status === 'approved');
  const rowStyle = completed ? 'border-left:4px solid #2D7A3E' : '';

  const submittedCell = g.latest_submitted_at
    ? `<span style="font-size:12px">${formatDate(g.latest_submitted_at)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">미제출</span>';

  const campNoBadge = camp.campaign_no
    ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted);margin-right:6px">${esc(camp.campaign_no)}</span>`
    : '';

  return `<tr data-app-id="${esc(g.application_id)}" style="${rowStyle}">
    <td>${rtBadge}</td>
    <td>${campNoBadge}<div>${esc(camp.title || '—')}</div><div style="font-size:10px;color:var(--muted)">${esc(camp.brand || '')}</div></td>
    <td><div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${esc(inf.id||'')}')">${infName}${(typeof influencerStatusBadges === 'function') ? influencerStatusBadges(inf) : ''}</div>${infSub ? `<div style="font-size:10px;color:var(--muted)">${infSub}</div>` : ''}<div style="margin-top:4px">${renderApplicantMsgBtn({id: g.application_id, campaign_id: (camp && camp.id) || ''})}</div></td>
    <td>${receiptCell}</td>
    <td>${resultCell}</td>
    <td>${submittedCell}</td>
    <td><button class="btn btn-ghost btn-xs" onclick="openDelivCombined('${esc(g.application_id)}')">검수</button></td>
  </tr>`;
}

// monitor 캠페인 결과물 셀 — 채널별 review_image N개 미니 행 (사양 §5-1)
//   채널 라벨 + 상태 배지 + 썸네일(있을 때). 검수는 행 우측 「검수」 버튼으로 일괄 모달.
//   채널 없는 레거시 monitor 캠페인은 「—」 단일 표시.
function renderDelivResultCellMonitor(g) {
  const camp = g.campaign || {};
  const channels = (camp.channel || '').split(',').map(c => c.trim()).filter(Boolean);
  if (channels.length === 0) {
    return '<span style="font-size:11px;color:var(--muted)">—</span>';
  }
  const byCh = g.reviewByChannel || {};
  const chLabel = function(code) {
    return (typeof getLookupLabel === 'function')
      ? (getLookupLabel('channel', code, 'ko') || code)
      : code;
  };
  return channels.map(function(ch) {
    const d = byCh[ch];
    const label = '<span style="font-size:10px;font-weight:600;color:var(--ink)">' + esc(chLabel(ch)) + '</span>';
    if (!d) {
      return '<div style="display:flex;align-items:center;gap:6px;padding:2px 0">'
        + label
        + '<span style="font-size:10px;color:var(--muted);background:#f5f5f5;padding:1px 6px;border-radius:3px">미제출</span>'
        + '</div>';
    }
    let thumb = '';
    if (d.receipt_url) {
      const thumbUrl = (typeof imgThumb === 'function') ? imgThumb(d.receipt_url, 48, 80) : d.receipt_url;
      thumb = '<img src="' + esc(thumbUrl) + '" data-orig="' + esc(d.receipt_url) + '" loading="lazy" decoding="async" '
        + 'style="width:22px;height:22px;border-radius:3px;object-fit:cover;cursor:pointer;background:#f5f5f5" '
        + 'onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" '
        + 'onclick="event.stopPropagation();openImageLightbox(\'' + esc(d.receipt_url) + '\')">';
    }
    let badge;
    if (d.status === 'approved')      badge = '<span style="font-size:10px;background:#E4F5E8;color:#2D7A3E;font-weight:600;padding:1px 6px;border-radius:3px">승인</span>';
    else if (d.status === 'rejected') badge = '<span style="font-size:10px;background:#FFE4E4;color:#C33;font-weight:600;padding:1px 6px;border-radius:3px">비승인</span>';
    else if (d.status === 'draft')    badge = '<span style="font-size:10px;background:#e5e7eb;color:#555;font-weight:600;padding:1px 6px;border-radius:3px">임시</span>';
    else                              badge = '<span style="font-size:10px;background:#FFF4E4;color:#B8741A;font-weight:600;padding:1px 6px;border-radius:3px">검수대기</span>';
    return '<div style="display:flex;align-items:center;gap:6px;padding:2px 0">'
      + thumb + label + badge
      + '</div>';
  }).join('');
}

// 영수증·결과물 셀 — slot: 'receipt' | 'result', rt: campaign.recruit_type
function renderDelivStatusCell(d, slot, rt) {
  // 영수증은 monitor에서만 사용. gifting/visit은 영수증 단계 없음 → 「-」 표시
  if (slot === 'receipt' && rt !== 'monitor') {
    return '<span style="font-size:11px;color:var(--muted)">—</span>';
  }
  if (!d) {
    return '<span style="display:inline-block;background:#f5f5f5;color:var(--muted);font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">미제출</span>';
  }
  let preview = '';
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    if (d.receipt_url) {
      const thumb = (typeof imgThumb === 'function') ? imgThumb(d.receipt_url, 64, 80) : d.receipt_url;
      preview = `<img src="${esc(thumb)}" data-orig="${esc(d.receipt_url)}" loading="lazy" decoding="async" style="width:32px;height:32px;border-radius:4px;object-fit:cover;cursor:pointer;background:#f5f5f5" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" onclick="event.stopPropagation();openImageLightbox('${esc(d.receipt_url)}')">`;
    }
  } else if (d.kind === 'post') {
    if (d.post_url) {
      let host = '';
      try { host = new URL(d.post_url).hostname.replace(/^www\./, ''); } catch(e) { host = d.post_url; }
      preview = `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" onclick="event.stopPropagation()" style="font-size:10px;color:var(--dark-pink);text-decoration:none;display:inline-block;max-width:100px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;vertical-align:middle">${esc(host)}</a>`;
    }
  }
  return `<div style="display:flex;align-items:center;gap:6px">${preview}${delivStatusBadge(d.status)}</div>`;
}

function statusLabelKo(status) {
  return {pending: '검수대기', approved: '승인', rejected: '반려'}[status] || status;
}

function delivStatusBadge(status) {
  const map = {
    pending: '<span style="background:#FFF4E4;color:#B8741A;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">검수대기</span>',
    approved: '<span style="background:#E4F5E8;color:#2D7A3E;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">승인</span>',
    rejected: '<span style="background:#FFE4E4;color:#C33;font-size:11px;font-weight:600;padding:2px 8px;border-radius:3px">반려</span>'
  };
  return map[status] || status;
}

async function openDelivDetail(id) {
  const modal = $('delivDetailModal');
  if (!modal) return;
  openModal('delivDetailModal');
  const body = $('delivDetailBody');
  const footer = $('delivDetailFooter');
  if (body) body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  if (footer) footer.innerHTML = '';
  const [d, events] = await Promise.all([
    fetchDeliverableById(id),
    fetchDeliverableEvents(id)
  ]);
  if (!d) {
    if (body) body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">결과물을 찾을 수 없습니다.</div>';
    return;
  }
  _delivDetailCurrent = {id: d.id, version: d.version, recruit_type: d.campaigns?.recruit_type || null};
  const camp = d.campaigns || {};
  const inf = d.influencers || {};
  const titleEl = $('delivDetailTitle');
  if (titleEl) titleEl.innerHTML = `${esc(camp.title || '캠페인')} <span style="font-size:12px;color:var(--muted);font-weight:400">· ${esc(inf.name || '—')}</span>`;

  // 본문
  let contentHtml = '';
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    // receipt(영수증) + review_image(monitor 2단계 리뷰 캡처) 모두 receipt_url 컬럼을 재사용 (093 마이그레이션)
    // receipt kind 는 주문번호·구매일·구매금액 마스킹 해제 + 수정 폼 + 변경 이력 (마이그레이션 128)
    const altText = d.kind === 'receipt' ? '영수증' : '리뷰 이미지';
    const receiptInfoBlock = (d.kind === 'receipt') ? renderReceiptInfoBlock(d) : '';
    contentHtml = `
      <div style="display:grid;grid-template-columns:240px 1fr;gap:16px">
        <div>
          ${d.receipt_url
            ? `<img src="${esc(d.receipt_url)}" alt="${esc(altText)}" style="width:100%;border:1px solid var(--line);border-radius:8px;cursor:zoom-in" onclick="openImageLightbox('${esc(d.receipt_url)}')">`
            : '<div style="width:100%;height:180px;background:#f5f5f5;border-radius:8px;display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:12px">이미지 없음</div>'}
        </div>
        <div style="font-size:13px">
          <div style="margin-bottom:8px"><span style="color:var(--muted)">결과물 종류</span> · <strong>${esc(altText)}</strong></div>
          ${receiptInfoBlock}
          ${d.memo ? `<div style="margin-bottom:8px"><span style="color:var(--muted)">메모</span> · ${esc(d.memo)}</div>` : ''}
          <div style="margin-top:14px;padding-top:10px;border-top:1px dashed var(--line);font-size:11px;color:var(--muted)">
            제출일 · ${formatDate(d.submitted_at)}<br>
            최종 수정 · ${formatDate(d.updated_at)}<br>
            version · ${d.version}
          </div>
        </div>
      </div>`;
  } else {
    // post (gifting/visit 게시물 URL)
    const subs = Array.isArray(d.post_submissions) ? d.post_submissions : [];
    contentHtml = `
      <div style="font-size:13px">
        <div style="margin-bottom:10px"><span style="color:var(--muted)">채널</span> · <strong>${esc(d.post_channel || '—')}</strong></div>
        <div style="margin-bottom:10px"><span style="color:var(--muted)">URL</span> · ${d.post_url ? `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" style="color:var(--dark-pink);word-break:break-all">${esc(d.post_url)}</a>` : '—'}</div>
        ${subs.length ? `<div style="margin-top:12px"><span style="color:var(--muted);font-size:11px">제출 이력 (${subs.length}건)</span><ul style="margin:6px 0 0;padding-left:18px;font-size:11px">${subs.map(s => `<li>${esc(s.submitted_at || '')} · ${esc(s.channel || '')}</li>`).join('')}</ul></div>` : ''}
      </div>`;
  }

  // 변경 이력 — 최근 2건 + 「더보기」 토글 (2026-05-15 사용자 요청)
  if (events.length) {
    contentHtml += '<div style="margin-top:18px;padding-top:14px;border-top:1px solid var(--line)"><div style="font-size:12px;font-weight:600;color:var(--ink);margin-bottom:8px">변경 이력</div>';
    contentHtml += renderDeliverableEventsTimeline(events, 'detail-' + d.id);
    contentHtml += '</div>';
  }

  if (body) body.innerHTML = contentHtml;

  // 푸터 액션
  let footerHtml = '';
  if (d.status === 'pending') {
    footerHtml = `
      <button class="btn btn-ghost" onclick="closeDelivDetail()">닫기</button>
      <button class="btn btn-ghost" onclick="openDelivRejectModal('${d.id}', ${d.version})" style="color:#C33;border-color:#C33">반려</button>
      <button class="btn btn-primary" onclick="approveDeliv('${d.id}', ${d.version})">승인</button>
    `;
  } else {
    footerHtml = `
      <button class="btn btn-ghost" onclick="closeDelivDetail()">닫기</button>
      <button class="btn btn-ghost" onclick="revertDeliv('${d.id}', ${d.version})">되돌리기 (검수대기로)</button>
    `;
  }
  if (footer) footer.innerHTML = footerHtml;
}

function closeDelivDetail() {
  closeModal('delivDetailModal');
  _delivDetailCurrent = null;
}

async function approveDeliv(id, version) {
  const ret = await updateDeliverableStatus(id, 'approved', version);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다. 목록을 새로고침합니다.', 'warn');
    closeDelivDetail();
    await renderDeliverablesList();
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('승인 처리되었습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
}

async function revertDeliv(id, version) {
  const ok = await showConfirm('검수 결과를 되돌리시겠습니까?\n상태가 검수대기로 변경됩니다.\n\n인플루언서가 이미 결과를 확인했을 수 있습니다.');
  if (!ok) return;
  const ret = await updateDeliverableStatus(id, 'pending', version);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다.', 'warn');
    closeDelivDetail();
    await renderDeliverablesList();
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('검수대기로 되돌렸습니다.');
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
}

// 반려 모달 상태
let _delivRejectCtx = null;  // {id, version}

async function openDelivRejectModal(id, version) {
  _delivRejectCtx = {id, version};
  const tpl = $('delivRejectTemplate');
  const reason = $('delivRejectReason');
  // 현재 열려 있는 deliverable의 캠페인 recruit_type 추출
  const campRt = _delivDetailCurrent?.recruit_type
    || (_delivCache.find(d => d.id === id)?.campaigns?.recruit_type)
    || null;
  if (tpl) {
    tpl.innerHTML = '<option value="">— 직접 입력 —</option>';
    try {
      const items = await fetchLookupsAll('reject_reason');
      items.filter(v => v.active).filter(v => {
        const rts = Array.isArray(v.recruit_types) ? v.recruit_types : [];
        // 빈 배열 = 공통, 아니면 캠페인 타입과 매칭
        return !rts.length || !campRt || rts.includes(campRt);
      }).forEach(v => {
        const opt = document.createElement('option');
        opt.value = v.code;
        opt.textContent = v.name_ko;
        opt.dataset.desc = v.name_ja || '';
        tpl.appendChild(opt);
      });
    } catch(e) {}
    const otherOpt = document.createElement('option');
    otherOpt.value = 'other';
    otherOpt.textContent = '기타';
    tpl.appendChild(otherOpt);
    tpl.value = '';
  }
  if (reason) reason.value = '';
  openModal('delivRejectModal');
}

function closeDelivRejectModal() {
  closeModal('delivRejectModal');
  _delivRejectCtx = null;
}

function onDelivRejectTemplateChange() {
  const tpl = $('delivRejectTemplate');
  const reason = $('delivRejectReason');
  if (!tpl || !reason) return;
  const selected = tpl.options[tpl.selectedIndex];
  const desc = selected?.dataset?.desc || '';
  if (tpl.value && tpl.value !== 'other' && desc) {
    reason.value = desc;
  } else if (tpl.value === 'other') {
    reason.value = '';
  }
}

async function submitDelivReject() {
  if (!_delivRejectCtx) return;
  const reason = ($('delivRejectReason')?.value || '').trim();
  const templateCode = $('delivRejectTemplate')?.value || null;
  if (!reason) {
    toast('반려 사유를 입력해주세요.', 'warn');
    return;
  }
  const {id, version} = _delivRejectCtx;
  const ret = await updateDeliverableStatus(id, 'rejected', version, reason, templateCode);
  if (ret === -1) {
    toast('다른 관리자가 이미 처리했습니다.', 'warn');
    closeDelivRejectModal();
    closeDelivDetail();
    await renderDeliverablesList();
    if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    return;
  }
  toast('반려 처리되었습니다.');
  closeDelivRejectModal();
  closeDelivDetail();
  await renderDeliverablesList();
  if (_delivCombinedRefreshAppId) await renderDelivCombinedBody(_delivCombinedRefreshAppId);
}


// ──────────────────────────────────────
// 결과물 관리 페인 합본 검수 모달 (Phase 2)
// 한 신청(application) 안의 영수증·결과물 양쪽을 한 화면에서 검수.
// 액션 버튼은 기존 approveDeliv/revertDeliv/openDelivRejectModal을 재사용하고,
// 처리 후 _delivCombinedRefreshAppId가 가리키는 application의 패널을 다시 렌더링.
// ──────────────────────────────────────
let _delivCombinedRefreshAppId = null;

async function openDelivCombined(applicationId) {
  const modal = $('delivCombinedModal');
  if (!modal) return;
  _delivCombinedRefreshAppId = applicationId;
  openModal('delivCombinedModal');
  await renderDelivCombinedBody(applicationId);
}

function closeDelivCombined() {
  closeModal('delivCombinedModal');
  _delivCombinedRefreshAppId = null;
}

async function renderDelivCombinedBody(applicationId) {
  const body = $('delivCombinedBody');
  const titleEl = $('delivCombinedTitle');
  if (!body) return;
  body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';

  // 1차: deliverables를 캠페인 join 포함해서 fetch (가장 안정적인 정보 출처)
  let allDelivs = [];
  let camp = null;
  let userId = null;
  if (db) {
    const delivRes = await db?.from('deliverables').select(`
      id, kind, status, version, application_id, user_id, campaign_id,
      receipt_url, post_url, post_channel, post_submissions, memo,
      order_number, purchase_date, purchase_amount,
      reject_reason, reject_template_code,
      submitted_at, reviewed_at, updated_at, reviewed_by,
      campaigns:campaign_id (id, campaign_no, title, brand, recruit_type, channel)
    `).eq('application_id', applicationId).neq('status', 'draft').order('submitted_at', {ascending: false});
    if (delivRes?.error) console.error('[deliv-combined deliv]', delivRes.error);
    allDelivs = delivRes?.data || [];
    if (allDelivs[0]) {
      camp = allDelivs[0].campaigns || null;
      userId = allDelivs[0].user_id || null;
    }
  }

  // 2차 fallback: deliverable이 0건(미제출 토글 ON으로 진입한 케이스)이면 applications에서 직접 fetch
  if (!camp && db) {
    const appRes = await db?.from('applications').select('user_id, campaign_id, campaigns:campaign_id (id, campaign_no, title, brand, recruit_type, channel)').eq('id', applicationId).maybeSingle();
    if (appRes?.error) console.error('[deliv-combined app]', appRes.error);
    const app = appRes?.data || null;
    if (app) {
      camp = app.campaigns || null;
      userId = app.user_id || null;
    }
  }

  if (!camp) {
    body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--muted)">캠페인 정보를 찾을 수 없습니다.</div>';
    return;
  }

  const rt = camp.recruit_type;
  const infMap = userId ? await fetchInfluencersByIds([userId]) : {};
  const inf = infMap[userId] || null;

  if (titleEl) {
    const campLabel = camp.campaign_no ? `[${esc(camp.campaign_no)}] ${esc(camp.title || '')}` : esc(camp.title || '캠페인');
    const infLabel = inf?.name || '—';
    titleEl.innerHTML = `${campLabel} <span style="font-size:12px;color:var(--muted);font-weight:400">· ${esc(infLabel)}</span>`;
  }

  // submitted_at 내림차순으로 정렬되어 있으므로 find = 최신 1건
  const receipt = allDelivs.find(d => d.kind === 'receipt') || null;
  // monitor 채널 추출 + 채널별 review_image 최신 1개 매핑 (사양 2 PR 3d — 패널 N개 펼침)
  const campChannels = (rt === 'monitor') ? (camp.channel || '').split(',').map(c => c.trim()).filter(Boolean) : [];
  const reviewByCh = {};
  if (rt === 'monitor') {
    allDelivs.filter(d => d.kind === 'review_image' && d.post_channel).forEach(d => {
      const prev = reviewByCh[d.post_channel];
      if (!prev || new Date(d.created_at) > new Date(prev.created_at)) reviewByCh[d.post_channel] = d;
    });
  }
  const isMonitorMulti = rt === 'monitor' && campChannels.length > 0;
  // 그 외(gifting/visit + 채널 없는 monitor 레거시)는 결과물 단일 (review_image OR post 최신)
  const result = isMonitorMulti ? null : (allDelivs.find(d => d.kind === 'review_image' || d.kind === 'post') || null);

  // 변경 이력 fetch — monitor + 채널 N개면 채널별 병렬, 그 외는 result 단일
  let receiptEvents = [];
  let resultEvents = [];
  const reviewEventsByCh = {};
  if (isMonitorMulti) {
    const reviewIds = campChannels.map(ch => reviewByCh[ch]?.id || null);
    const fetched = await Promise.all([
      receipt ? fetchDeliverableEvents(receipt.id) : Promise.resolve([]),
      ...reviewIds.map(id => id ? fetchDeliverableEvents(id) : Promise.resolve([])),
    ]);
    receiptEvents = fetched[0];
    reviewIds.forEach((id, i) => { if (id) reviewEventsByCh[id] = fetched[1 + i]; });
  } else {
    const fetched = await Promise.all([
      receipt ? fetchDeliverableEvents(receipt.id) : Promise.resolve([]),
      result ? fetchDeliverableEvents(result.id) : Promise.resolve([]),
    ]);
    receiptEvents = fetched[0];
    resultEvents = fetched[1];
  }

  // 영수증 패널은 monitor에서만 노출. gifting/visit은 영수증 단계 없음.
  const showReceipt = rt === 'monitor';
  const resultLabel = rt === 'monitor' ? '결과물 (리뷰 캡쳐)' : '결과물 (게시 URL)';
  const stepLabel = rt === 'monitor' ? '<span style="font-size:10px;color:var(--muted);font-weight:400">· STEP 1</span>' : '';
  const stepLabel2 = rt === 'monitor' ? '<span style="font-size:10px;color:var(--muted);font-weight:400">· STEP 2</span>' : '';

  // 패널 헤더 우측에 상태 배지 노출 (deliverable 있을 때만)
  const receiptStatusBadge = receipt ? delivStatusBadge(receipt.status) : '';
  const resultStatusBadge = result ? delivStatusBadge(result.status) : '';

  // 같은 신청의 「채널별 리뷰 이미지 상태 요약」 박스 (모달 하단)
  //   사용자 Q6 결정 — 모달 하단 회색 박스. monitor + 채널 N개 캠페인에서만 노출.
  //   각 채널의 최신 행 상태를 한 줄로 보여줘 검수자가 다른 채널 검수 누락을 인지하도록.
  //   채널별 개별 검수는 각 행 클릭으로 별도 모달.
  // campChannels·reviewByCh 는 위(결과물 패널 분기)에서 이미 계산됨 — 재사용
  let channelSummaryBox = '';
  if (isMonitorMulti) {
    const stLabel = function(r) {
      if (!r) return '<span style="color:var(--muted)">미제출</span>';
      if (r.status === 'approved') return '<span style="color:#2D7A3E">✓ 승인</span>';
      if (r.status === 'rejected') return '<span style="color:#C33">✗ 반려</span>';
      if (r.status === 'draft') return '<span style="color:var(--muted)">임시저장</span>';
      return '<span style="color:#B8741A">검수중</span>';
    };
    const chLabel = function(code) {
      return (typeof getLookupLabel === 'function')
        ? (getLookupLabel('channel', code, 'ko') || code)
        : code;
    };
    const items = campChannels.map(function(ch) {
      return '<span><strong>' + esc(chLabel(ch)) + '</strong> ' + stLabel(reviewByCh[ch] || null) + '</span>';
    });
    const receiptItem = '<span><strong>영수증</strong> ' + stLabel(receipt) + '</span>';
    channelSummaryBox = `
      <div style="margin-top:16px;padding:12px 14px;background:#f7f7f7;border-radius:8px;font-size:12px;line-height:1.8">
        <div style="font-weight:600;color:var(--muted);font-size:11px;margin-bottom:4px">같은 신청의 채널별 결과물 상태</div>
        ${receiptItem} · ${items.join(' · ')}
      </div>`;
  }

  // 결과물 패널 렌더 — monitor + 채널 N개면 채널별 패널 N개, 그 외는 단일 result 패널
  let resultPanelsHtml = '';
  if (isMonitorMulti) {
    const chLabelFn = function(code) {
      return (typeof getLookupLabel === 'function')
        ? (getLookupLabel('channel', code, 'ko') || code)
        : code;
    };
    resultPanelsHtml = campChannels.map(function(ch) {
      const d = reviewByCh[ch] || null;
      const statusBadge = d ? delivStatusBadge(d.status) : '';
      const events = (d && reviewEventsByCh[d.id]) ? reviewEventsByCh[d.id] : [];
      const chLabelStr = chLabelFn(ch);
      return '<div class="deliv-combined-panel">'
        + '<div class="deliv-combined-panel-header"><span>「' + esc(chLabelStr) + '」 리뷰 ' + stepLabel2 + '</span>' + statusBadge + '</div>'
        + '<div class="deliv-combined-panel-body">' + renderDelivPanelContent(d, events) + '</div>'
        + '</div>';
    }).join('');
  } else {
    resultPanelsHtml = '<div class="deliv-combined-panel">'
      + '<div class="deliv-combined-panel-header"><span>' + esc(resultLabel) + ' ' + stepLabel2 + '</span>' + resultStatusBadge + '</div>'
      + '<div class="deliv-combined-panel-body">' + renderDelivPanelContent(result, resultEvents) + '</div>'
      + '</div>';
  }

  // 패널 총수가 3+개면 multi 클래스로 그리드 wrap (auto-fit minmax)
  const totalPanels = (showReceipt ? 1 : 1) + (isMonitorMulti ? campChannels.length : 1);
  const gridClass = totalPanels >= 3 ? 'deliv-combined-grid deliv-combined-grid-multi' : 'deliv-combined-grid';

  body.innerHTML = `
    <div class="${gridClass}">
      ${showReceipt
        ? `<div class="deliv-combined-panel">
            <div class="deliv-combined-panel-header"><span>영수증 ${stepLabel}</span>${receiptStatusBadge}</div>
            <div class="deliv-combined-panel-body">${renderDelivPanelContent(receipt, receiptEvents)}</div>
          </div>`
        : `<div class="deliv-combined-panel" style="opacity:.6">
            <div class="deliv-combined-panel-header" style="color:var(--muted)"><span>영수증 (해당 없음)</span></div>
            <div class="deliv-combined-panel-body" style="color:var(--muted);text-align:center;padding:40px;font-size:13px">이 모집 타입은 영수증 단계가 없습니다.</div>
          </div>`}
      ${resultPanelsHtml}
    </div>
    ${channelSummaryBox}
  `;
}

// ─── 영수증 정보 블록 (마이그레이션 128) ─────────────────────
// kind='receipt' 결과물의 주문번호·구매일·구매금액을 노출.
// campaign_admin 이상은 인플레이스 수정 폼 + 변경 이력 토글 사용.
// (review_image kind는 이 블록 대상이 아니다 — 영수증과 별개 단계)
function renderReceiptInfoBlock(d) {
  if (!d || d.kind !== 'receipt') return '';
  const canEdit = isCampaignAdminOrAbove();
  const id = String(d.id);
  const orderNo = d.order_number || '';
  const purchaseDate = d.purchase_date || '';
  const amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
    ? null
    : Number(d.purchase_amount);
  const fmtMissing = '<span style="color:#C33">미입력</span>';
  const amtView = (amt === null || !Number.isFinite(amt)) ? fmtMissing : `¥${amt.toLocaleString()}`;
  const viewHtml = `
    <div id="receiptInfoView-${esc(id)}" style="font-size:12px;line-height:1.7;margin-bottom:10px;padding:10px 12px;background:#FAFAFA;border:1px solid var(--line);border-radius:8px">
      <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:10px;margin-bottom:4px">
        <strong style="font-size:12px;color:var(--ink)">영수증 정보</strong>
        ${canEdit ? `<button class="btn btn-ghost btn-xs" style="font-size:10px;padding:2px 8px" onclick="enterReceiptEditMode('${esc(id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">edit</span> 수정</button>` : ''}
      </div>
      <div><span style="color:var(--muted)">주문번호</span> · ${orderNo ? `<strong>${esc(orderNo)}</strong>` : fmtMissing}</div>
      <div><span style="color:var(--muted)">구매일</span> · ${purchaseDate ? esc(purchaseDate) : fmtMissing}</div>
      <div><span style="color:var(--muted)">구매금액</span> · ${amtView}</div>
      <div style="margin-top:6px"><button class="btn btn-ghost btn-xs" style="font-size:10px;padding:2px 8px" onclick="toggleReceiptHistory('${esc(id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">history</span> 변경 이력 보기</button></div>
      <div id="receiptHistoryBox-${esc(id)}" style="display:none;margin-top:8px;padding-top:8px;border-top:1px dashed var(--line)"></div>
    </div>`;
  const editHtml = canEdit ? `
    <div id="receiptInfoEdit-${esc(id)}" style="display:none;font-size:12px;margin-bottom:10px;padding:10px 12px;background:#FFF9E6;border:1px solid #F5C518;border-radius:8px">
      <div style="font-weight:600;margin-bottom:8px">영수증 정보 수정</div>
      <div style="margin-bottom:6px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">주문번호 *</label>
        <input id="receiptEditOrder-${esc(id)}" type="text" maxlength="200" value="${esc(orderNo)}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="margin-bottom:6px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">구매일 *</label>
        <input id="receiptEditDate-${esc(id)}" type="date" value="${esc(purchaseDate)}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="margin-bottom:8px">
        <label style="display:block;color:var(--muted);margin-bottom:2px">구매금액 (엔) *</label>
        <input id="receiptEditAmount-${esc(id)}" type="number" min="0" step="1" value="${(amt === null || !Number.isFinite(amt)) ? '' : amt}" style="width:100%;padding:5px 8px;border:1px solid var(--line);border-radius:4px;font-size:12px">
      </div>
      <div style="display:flex;gap:6px;justify-content:flex-end">
        <button class="btn btn-ghost btn-xs" style="font-size:11px;padding:4px 10px" onclick="cancelReceiptEdit('${esc(id)}')">취소</button>
        <button class="btn btn-primary btn-xs" style="font-size:11px;padding:4px 10px" onclick="saveReceiptEdit('${esc(id)}')">저장</button>
      </div>
    </div>` : '';
  return viewHtml + editHtml;
}

function enterReceiptEditMode(id) {
  const v = document.getElementById('receiptInfoView-' + id);
  const e = document.getElementById('receiptInfoEdit-' + id);
  if (v) v.style.display = 'none';
  if (e) e.style.display = '';
}

function cancelReceiptEdit(id) {
  const v = document.getElementById('receiptInfoView-' + id);
  const e = document.getElementById('receiptInfoEdit-' + id);
  if (v) v.style.display = '';
  if (e) e.style.display = 'none';
}

async function saveReceiptEdit(id) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  const orderNo = (document.getElementById('receiptEditOrder-' + id)?.value || '').trim();
  const purchaseDate = document.getElementById('receiptEditDate-' + id)?.value || '';
  const rawAmount = document.getElementById('receiptEditAmount-' + id)?.value || '';
  if (!orderNo) { toast('주문번호를 입력해주세요','error'); return; }
  if (orderNo.length > 200) { toast('주문번호는 200자 이내로 입력해주세요','error'); return; }
  if (!purchaseDate) { toast('구매일을 입력해주세요','error'); return; }
  if (rawAmount === '' || rawAmount === null || rawAmount === undefined) {
    toast('구매금액을 입력해주세요','error'); return;
  }
  const amount = Number(rawAmount);
  if (!Number.isFinite(amount) || amount < 0) {
    toast('구매금액은 0 이상의 숫자를 입력해주세요','error'); return;
  }
  try {
    await updateReceiptAdmin(id, orderNo, purchaseDate, amount);
    toast('영수증 정보를 수정했습니다','success');
    // 현재 열린 모달 재로딩 (통합 검수 모달 우선, 단일 상세 모달 후순)
    if (typeof _delivCombinedRefreshAppId !== 'undefined' && _delivCombinedRefreshAppId) {
      await renderDelivCombinedBody(_delivCombinedRefreshAppId);
    } else if (typeof _delivDetailCurrent !== 'undefined' && _delivDetailCurrent?.id) {
      await openDelivDetail(_delivDetailCurrent.id);
    }
    if (typeof refreshPane === 'function') await refreshPane('deliverables');
  } catch(e) {
    const msg = (e && e.message) ? e.message : String(e);
    toast(friendlyError(msg), 'error');
  }
}

async function toggleReceiptHistory(id) {
  const box = document.getElementById('receiptHistoryBox-' + id);
  if (!box) return;
  if (box.style.display !== 'none') { box.style.display = 'none'; return; }
  box.style.display = '';
  box.innerHTML = '<div style="font-size:11px;color:var(--muted)">불러오는 중...</div>';
  const rows = await fetchReceiptEditHistory(id);
  if (!rows.length) {
    box.innerHTML = '<div style="font-size:11px;color:var(--muted)">변경 이력이 없습니다.</div>';
    return;
  }
  const fmtAmt = v => (v === null || v === undefined || v === '')
    ? '(빈값)'
    : '¥' + Number(v).toLocaleString();
  const html = rows.map(r => {
    const lines = [];
    if ((r.order_number_prev || '') !== (r.order_number_next || '')) {
      lines.push(`<div>주문번호 · ${esc(r.order_number_prev || '(빈값)')} → <strong>${esc(r.order_number_next || '(빈값)')}</strong></div>`);
    }
    if (String(r.purchase_date_prev || '') !== String(r.purchase_date_next || '')) {
      lines.push(`<div>구매일 · ${esc(r.purchase_date_prev || '(빈값)')} → <strong>${esc(r.purchase_date_next || '(빈값)')}</strong></div>`);
    }
    if (String(r.purchase_amount_prev ?? '') !== String(r.purchase_amount_next ?? '')) {
      lines.push(`<div>구매금액 · ${fmtAmt(r.purchase_amount_prev)} → <strong>${fmtAmt(r.purchase_amount_next)}</strong></div>`);
    }
    return `<div style="padding:5px 0;border-bottom:1px dashed var(--line);font-size:11px">
      <div style="display:flex;justify-content:space-between;gap:10px;margin-bottom:3px">
        <span><strong>${esc(r.changed_by_name || '(이름미상)')}</strong></span>
        <span style="color:var(--muted);white-space:nowrap">${formatDate(r.changed_at)}</span>
      </div>
      ${lines.join('') || '<div style="color:var(--muted)">변경 사항 없음</div>'}
    </div>`;
  }).join('');
  box.innerHTML = `<div style="font-size:11px;font-weight:600;color:var(--ink);margin-bottom:4px">변경 이력 (${rows.length}건)</div>${html}`;
}

// ─── 결과물 변경 이력 타임라인 (최근 2건 + 더보기 토글, 2026-05-15 사용자 요청) ─
// 영수증 패널·결과물 패널·단일 결과물 모달 모두 동일 패턴으로 사용
// events: created_at DESC 정렬된 deliverable_events 배열
// scopeId: deliverable.id (각 패널마다 unique element id 생성용)
function renderDeliverableEventsTimeline(events, scopeId) {
  if (!Array.isArray(events) || !events.length) return '';
  var VISIBLE = 2;
  var total = events.length;
  var recent = events.slice(0, VISIBLE);
  var rest = events.slice(VISIBLE);
  var renderItem = function(e) {
    var labelMap = {submit:'제출', resubmit:'재제출', approve:'승인', reject:'반려', revert:'되돌리기'};
    var label = labelMap[e.action] || e.action;
    var transition = e.from_status
      ? ' · ' + esc(statusLabelKo(e.from_status)) + ' → ' + esc(statusLabelKo(e.to_status))
      : '';
    var reasonLine = e.reason
      ? '<div style="margin-top:4px;color:#C33;white-space:pre-wrap;line-height:1.5">' + esc(e.reason) + '</div>'
      : '';
    return '<div style="padding:5px 0;border-bottom:1px dashed var(--line)">'
      + '<div style="display:flex;justify-content:space-between;gap:10px">'
      + '<span><strong>' + esc(label) + '</strong>' + transition + '</span>'
      + '<span style="color:var(--muted);white-space:nowrap">' + formatDate(e.created_at) + '</span>'
      + '</div>' + reasonLine + '</div>';
  };
  var html = '<div style="font-size:11px">' + recent.map(renderItem).join('');
  if (rest.length > 0) {
    var sid = esc(String(scopeId));
    html += '<div id="delivEventsRest-' + sid + '" style="display:none">' + rest.map(renderItem).join('') + '</div>';
    html += '<div style="text-align:center;padding:6px 0">'
      + '<button id="delivEventsToggleBtn-' + sid + '" class="btn btn-ghost btn-xs" style="font-size:10px;padding:3px 10px" '
      + 'onclick="toggleDelivEventsRest(\'' + sid + '\', ' + rest.length + ')">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_more</span>'
      + ' 더보기 (' + rest.length + '건)'
      + '</button></div>';
  }
  html += '</div>';
  return html;
}

function toggleDelivEventsRest(scopeId, hiddenCount) {
  var box = document.getElementById('delivEventsRest-' + scopeId);
  var btn = document.getElementById('delivEventsToggleBtn-' + scopeId);
  if (!box || !btn) return;
  var isHidden = box.style.display === 'none';
  box.style.display = isHidden ? '' : 'none';
  btn.innerHTML = isHidden
    ? '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_less</span> 접기'
    : '<span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">expand_more</span> 더보기 (' + hiddenCount + '건)';
}

// 합본 모달 안 한 패널의 본문 — 이미지/URL/메타/반려사유/이력 타임라인/액션버튼
// events: deliverable_events 배열 (제출/재제출/승인/반려/되돌리기 타임라인)
function renderDelivPanelContent(d, events) {
  if (!d) {
    return '<div style="text-align:center;color:var(--muted);padding:40px;font-size:13px">아직 제출되지 않았습니다.</div>';
  }
  let html = '';
  if (d.kind === 'receipt' || d.kind === 'review_image') {
    html += `<div style="text-align:center;margin-bottom:12px">
      ${d.receipt_url
        ? `<img src="${esc(d.receipt_url)}" style="max-width:100%;max-height:280px;border:1px solid var(--line);border-radius:8px;cursor:zoom-in" onclick="openImageLightbox('${esc(d.receipt_url)}')">`
        : '<div style="height:140px;background:#f5f5f5;border-radius:8px;display:flex;align-items:center;justify-content:center;color:var(--muted)">이미지 없음</div>'}
    </div>`;
    // 영수증(receipt)만 주문번호·구매일·구매금액 정보 + 수정 + 이력 표시 (마이그레이션 128)
    // review_image kind는 해당 없음
    if (d.kind === 'receipt') {
      html += renderReceiptInfoBlock(d);
    }
  } else {
    html += `<div style="font-size:13px;line-height:1.7;margin-bottom:10px">
      <div><span style="color:var(--muted)">채널</span> · <strong>${esc(d.post_channel || '—')}</strong></div>
      <div style="margin-top:6px"><span style="color:var(--muted)">URL</span> · ${d.post_url ? `<a href="${esc(d.post_url)}" target="_blank" rel="noopener" style="color:var(--dark-pink);word-break:break-all">${esc(d.post_url)}</a>` : '—'}</div>
      ${(Array.isArray(d.post_submissions) && d.post_submissions.length) ? `<div style="margin-top:8px;font-size:11px;color:var(--muted)">제출 이력 ${d.post_submissions.length}건</div>` : ''}
    </div>`;
  }
  // 상태는 패널 헤더 우측에 노출되므로 여기에선 제거. 제출일·검수일만 한 줄로 압축.
  html += `<div style="margin-bottom:10px;font-size:11px;color:var(--muted)">제출일 ${formatDate(d.submitted_at)}${d.reviewed_at ? ` · 검수일 ${formatDate(d.reviewed_at)}` : ''}</div>`;
  // 변경 이력 타임라인 — 최근 2건 + 「더보기」 토글 (2026-05-15 사용자 요청)
  if (Array.isArray(events) && events.length) {
    html += '<div style="margin-bottom:10px;padding-top:10px;border-top:1px solid var(--line)"><div style="font-size:12px;font-weight:600;color:var(--ink);margin-bottom:6px">변경 이력</div>';
    html += renderDeliverableEventsTimeline(events, 'panel-' + d.id);
    html += '</div>';
  }
  if (d.status === 'pending') {
    html += `<div style="display:flex;gap:6px;margin-top:12px;justify-content:flex-end">
      <button class="btn btn-ghost btn-sm" style="color:#C33;border-color:#C33;font-size:12px;padding:6px 12px" onclick="openDelivRejectModal('${esc(d.id)}', ${d.version})">반려</button>
      <button class="btn btn-primary btn-sm" style="font-size:12px;padding:6px 12px" onclick="approveDeliv('${esc(d.id)}', ${d.version})">승인</button>
    </div>`;
  } else {
    html += `<div style="display:flex;gap:6px;margin-top:12px;justify-content:flex-end">
      <button class="btn btn-ghost btn-sm" style="font-size:12px;padding:6px 12px" onclick="revertDeliv('${esc(d.id)}', ${d.version})">검수대기로 되돌리기</button>
    </div>`;
  }
  return html;
}


