// ════════════════════════════════════════════════════════════════════
// SECTION: BRAND OPS — 운영 현황 페인 (브랜드 운영 재설계 PR 3)
//   브랜드별 진행 상황을 카드 그리드로. alert_level 4단계로 경고 강조.
//   데이터: get_brand_ops_overview RPC (마이그레이션 148, 22컬럼 — alert_reasons 사유 배너).
//   임계값 계산은 전부 서버(RPC)에서 끝나 클라이언트는 색·라벨만 매핑.
//   PR 4 의 브랜드 상세 페인(adminPane-brand-ops-detail)으로 진입.
// ════════════════════════════════════════════════════════════════════

var _brandOpsCache = [];      // get_brand_ops_overview 전체 행
var _brandOpsCompanies = [];  // 회사 드롭다운용

// 브랜드 상세 진입 (PR 4) — brand-ops-detail 서브 페인으로 전환
function openBrandOpsDetail(brandId) {
  _brandOpsDetailId = brandId;
  switchAdminPane('brand-ops-detail');
}

// alert_level → 색·라벨 매핑 (관리자 UI 한국어)
var BRAND_OPS_ALERT = {
  danger:  { color: 'var(--red)', bg: '#FDECEA', label: '긴급',     pulse: true },
  warning: { color: '#f97316', bg: '#FFF3E8', label: '대응 필요', pulse: false },
  caution: { color: '#f59e0b', bg: '#FEF9E7', label: '주의',     pulse: false },
  normal:  { color: '#cbd5e1', bg: '#fff',    label: '',         pulse: false }
};
// 정렬 시 경고 우선순위
var BRAND_OPS_ALERT_RANK = { danger: 0, warning: 1, caution: 2, normal: 3 };
// 사유 배너 표시 순서 (모집 → 마감 → 취소)
var BRAND_OPS_REASON_ORDER = ['recruit_low_deadline_near', 'recruit_low', 'd1_imminent', 'd3_imminent', 'cancel_7d_high'];

// 날짜(YYYY-MM-DD)까지 남은 일수 (오늘=0, 과거=음수)
function brandOpsDaysUntil(dateStr) {
  if (!dateStr) return null;
  var d = new Date(dateStr + 'T00:00:00');
  if (isNaN(d)) return null;
  var today = new Date(); today.setHours(0, 0, 0, 0);
  return Math.round((d - today) / 86400000);
}

// alert_reasons 코드 배열 → 한국어 배너 문구 배열 (서버가 준 수치로 조립)
function brandOpsAlertReasonLines(b) {
  var reasons = (b.alert_reasons || []).slice().sort(function(a, c) {
    return BRAND_OPS_REASON_ORDER.indexOf(a) - BRAND_OPS_REASON_ORDER.indexOf(c);
  });
  var rate = (b.recruit_rate != null) ? Number(b.recruit_rate).toFixed(0) : '—';
  var lines = [];
  reasons.forEach(function(code) {
    if (code === 'recruit_low_deadline_near') {
      var dleft = brandOpsDaysUntil(b.soonest_deadline);
      var dtxt = (dleft !== null) ? (' · 마감 ' + (dleft <= 0 ? '오늘' : dleft + '일 남음')) : '';
      lines.push('모집률 ' + rate + '%' + dtxt);
    } else if (code === 'recruit_low') {
      lines.push('모집률 ' + rate + '% (마감 여유)');
    } else if (code === 'd1_imminent') {
      lines.push('마감 하루 전 ' + (b.d1_count || 0) + '건');
    } else if (code === 'd3_imminent') {
      var n = (b.d3_count || 0) - (b.d1_count || 0);   // D-1 제외한 D-3 구간 건수
      if (n > 0) lines.push('마감 3일 이내 ' + n + '건');
    } else if (code === 'cancel_7d_high') {
      lines.push('최근 7일 취소 ' + (b.cancel_7d || 0) + '건');
    }
  });
  return lines;
}

// 운영현황은 두 뷰다 — 「일정」(캠페인 간트, 기본) / 「브랜드」(카드). 사양서
// docs/specs/2026-09-07-brand-ops-schedule-gantt-view.md. 두 뷰의 **공통 재료**를 여기서
// 한 번에 받고 현재 뷰를 그린다. 결과물 조회는 일정 뷰가 그려질 때 따로(loadScheduleDeliverables).
var _brandOpsCampaigns = [];     // fetchCampaigns() 전건 — 일정 뷰 + 「최근 신청」이 나눠 쓴다(두 번 부르지 않는다)
var _brandOpsApprCounts = null;  // get_campaign_application_counts (감사용 제외됨). 조회 실패면 null
var _brandOpsLoadToken = 0;      // 새로고침 연타·페인 들락거림 — 늦게 시작한 호출이 먼저 끝나 옛 값으로 덮는 것을 막는다
async function loadBrandOps() {
  var token = ++_brandOpsLoadToken;
  var grid = $('brandOpsGrid');
  var spin = '<div style="grid-column:1/-1;text-align:center;color:var(--muted);padding:40px"><span class="spinner" style="width:22px;height:22px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></div>';
  if (grid) grid.innerHTML = spin;
  var rowsEl = $('brandOpsScheduleRows');
  if (rowsEl) rowsEl.innerHTML = '<div class="gantt-empty">' + spin + '</div>';
  applyBrandOpsView();
  // 🔴 다시 들어올 때마다 결과물 캐시를 비운다 — 안 비우면 막대는 새 값인데 제출·인증 숫자만 옛 값으로 남는다.
  _brandOpsDelivCache = {};
  var results = await Promise.all([
    fetchCompanies({ status: 'all' }),            // 회사 드롭다운(전체/회사별/미분류)
    getBrandOpsOverview(null),                    // 브랜드 집계 — 회사/미분류 필터는 화면에서
    fetchCampaigns(),                             // 🔴 fetchCampaignsForAdminList 금지 — proxy_purchase·first_active_at·brand_id 가 없어 조용히 틀린다
    fetchCampaignApplicationCountsOrNull(),       // 승인 수(감사용 제외). 실패면 null → 「—」
    // 감사용 계정 id — 제출·인증 두 값에서 화면이 뺀다(승인 수는 서버가 이미 뺐다).
    //   ⚠️ 브랜드 상세(loadBrandOpsDetail)도 같은 조회로 같은 전역을 채운다 — 같은 집합이라 어느 쪽이 먼저 돌아도 같다.
    //   ⚠️ 원본 표가 아니라 **가림막 뷰**로 읽는다(마이그레이션 212).
    db ? db.from('influencers_admin_view').select('id').eq('is_audit', true) : Promise.resolve({data: []}),
  ]);
  if (token !== _brandOpsLoadToken) return;   // 그 사이 다시 들어왔다 — 이 회차 결과는 버린다
  _brandOpsCompanies = results[0];
  fillBrandOpsCompanyFilter();
  _brandOpsCache = results[1];
  _brandOpsCampaigns = results[2] || [];
  _brandOpsApprCounts = results[3];
  _brandOpsAuditIds = new Set((((results[4] && results[4].data) || [])).map(function(r){ return r.id; }));
  renderBrandOpsCurrentView();
  // 최근 신청 — 대시보드에서 이관 (renderRecentAppsTable 는 admin.js)
  loadBrandOpsRecentApps(_brandOpsCampaigns);
}

// 최근 신청 테이블 채우기 (대시보드 loadAdminData 에서 이관)
//   campaigns 를 받으면 그대로 쓴다(loadBrandOps 가 이미 받았다 — 같은 화면에서 전건 조회를 두 번 돌리지 않는다).
async function loadBrandOpsRecentApps(campaigns) {
  if (typeof renderRecentAppsTable !== 'function') return;
  // 취소 사유 이름 캐시 — 표에 사유 분류를 그리므로 **그리기 전에** 채운다(사양서 §3-4).
  //   ⚠️ renderRecentAppsTable 은 동기 함수라 그 안에서는 못 기다린다. 여기가 유일한 자리다.
  if (typeof ensureCancelReasonsCache === 'function') { try { await ensureCancelReasonsCache(); } catch(e) {} }
  var results = await Promise.all([campaigns ? Promise.resolve(campaigns) : fetchCampaigns(), fetchInfluencers(), fetchApplications()]);
  renderRecentAppsTable(results[2], results[0], results[1]);
}

function fillBrandOpsCompanyFilter() {
  var sel = $('brandOpsCompanyFilter');
  if (!sel) return;
  var prev = sel.value;
  var opts = '<option value="">전체 회사</option><option value="__unassigned__">미분류(회사 없음)</option>';
  opts += (_brandOpsCompanies || []).map(function(c){
    return '<option value="' + esc(c.id) + '">' + esc(c.name_ko || '') + '</option>';
  }).join('');
  sel.innerHTML = opts;
  if (prev) sel.value = prev;
}

function renderBrandOpsCards() {
  var grid = $('brandOpsGrid');
  if (!grid) return;
  var companyF = $('brandOpsCompanyFilter')?.value || '';
  var sortF = $('brandOpsSortFilter')?.value || 'alert';
  var q = (($('brandOpsSearch')?.value) || '').trim().toLowerCase();

  var list = (_brandOpsCache || []).filter(function(b){
    if (companyF === '__unassigned__') { if (b.company_id) return false; }
    else if (companyF) { if (b.company_id !== companyF) return false; }
    if (q) {
      var hay = ((b.brand_name_ko||'') + ' ' + (b.brand_name_ja||'') + ' ' + (b.company_name_ko||'') + ' ' + (b.brand_no||'')).toLowerCase();
      if (hay.indexOf(q) < 0) return false;
    }
    return true;
  });

  // 정렬
  list = list.slice().sort(function(a, b){
    if (sortF === 'campaigns') return (b.active_campaigns||0) - (a.active_campaigns||0);
    if (sortF === 'activity') return new Date(b.last_activity_at||0) - new Date(a.last_activity_at||0);
    // 기본: 경고 우선 → 진행 캠페인 수 → 최근 활동
    var ra = BRAND_OPS_ALERT_RANK[a.alert_level] ?? 9;
    var rb = BRAND_OPS_ALERT_RANK[b.alert_level] ?? 9;
    if (ra !== rb) return ra - rb;
    if ((b.active_campaigns||0) !== (a.active_campaigns||0)) return (b.active_campaigns||0) - (a.active_campaigns||0);
    return new Date(b.last_activity_at||0) - new Date(a.last_activity_at||0);
  });

  var count = $('brandOpsTotalCount');
  if (count) count.textContent = '(' + list.length + ' / 전체 ' + (_brandOpsCache||[]).length + ')';

  if (list.length === 0) {
    grid.innerHTML = '<div style="grid-column:1/-1;text-align:center;color:var(--muted);padding:48px">조건에 맞는 브랜드가 없습니다</div>';
    return;
  }
  // 브랜드 수가 많지 않아(회사당 N개) 전체 렌더. 수백 건 이상으로 늘면 페이지네이션 검토.
  grid.innerHTML = list.map(renderBrandOpsCard).join('');
}

function brandOpsRateBar(label, rate, approved, total) {
  // rate 가 NULL(분모 0)이면 "—"
  var hasData = rate !== null && rate !== undefined;
  var pct = hasData ? Math.min(100, Math.max(0, Number(rate))) : 0;
  var valText = hasData ? (Number(rate).toFixed(0) + '%') : '—';
  var sub = (total !== undefined && total !== null) ? ('(' + (approved||0) + '/' + (total||0) + ')') : '';
  return '<div style="margin-top:6px">'
    + '<div style="display:flex;justify-content:space-between;font-size:11px;color:var(--muted);margin-bottom:2px"><span>' + esc(label) + ' ' + sub + '</span><span style="font-weight:600;color:var(--ink)">' + valText + '</span></div>'
    + '<div style="height:6px;background:#eef0f3;border-radius:4px;overflow:hidden"><div style="height:100%;width:' + pct + '%;background:' + (pct >= 50 ? 'var(--green)' : pct >= 30 ? '#f59e0b' : 'var(--red)') + '"></div></div>'
    + '</div>';
}

function renderBrandOpsCard(b) {
  var alert = BRAND_OPS_ALERT[b.alert_level] || BRAND_OPS_ALERT.normal;
  var badge = alert.label
    ? '<span style="background:' + alert.bg + ';color:' + alert.color + ';font-size:10px;font-weight:700;padding:2px 8px;border-radius:10px' + (alert.pulse ? ';animation:brandOpsPulse 1.2s ease-in-out infinite' : '') + '">' + esc(alert.label) + '</span>'
    : '';

  // 사유 배너: alert_reasons(서버 코드 배열) → 한국어 문구. 정상 카드는 빈 배열 → 미표시
  var reasonLines = brandOpsAlertReasonLines(b);
  var banner = reasonLines.length
    ? '<div style="margin-top:8px;background:' + alert.bg + ';border:1px solid ' + alert.color + '33;border-radius:6px;padding:6px 8px;display:flex;gap:6px;align-items:flex-start">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;color:' + alert.color + ';flex-shrink:0;margin-top:1px">warning</span>'
      + '<div style="font-size:11px;color:' + alert.color + ';line-height:1.55;font-weight:600">' + reasonLines.map(esc).join('<br>') + '</div>'
      + '</div>'
    : '';

  return '<div class="brand-ops-card" style="border-left:4px solid ' + alert.color + '" onclick="openBrandOpsDetail(\'' + esc(b.brand_id) + '\')">'
    + '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px">'
      + '<div style="min-width:0">'
        + '<div style="font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-bottom:6px">' + esc(b.company_name_ko || '미분류') + '</div>'
        + (b.brand_no ? '<div style="font-size:11px;font-weight:400;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(b.brand_no) + '</div>' : '')
        + '<div style="font-weight:700;color:var(--ink);font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(b.brand_name_ko || '—') + '</div>'
        + (b.brand_name_ja ? '<div style="font-size:11px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(b.brand_name_ja) + '</div>' : '')
      + '</div>'
      + badge
    + '</div>'
    + '<div style="display:flex;gap:14px;margin-top:8px;font-size:12px">'
      + '<div><span style="color:var(--muted)">진행 신청</span> <b style="color:var(--ink)">' + (b.open_applications||0) + '</b></div>'
      + '<div><span style="color:var(--muted)">진행 캠페인</span> <b style="color:var(--ink)">' + (b.active_campaigns||0) + '</b></div>'
    + '</div>'
    + brandOpsRateBar('모집률', b.recruit_rate, b.approved_total, b.slots_total)
    + brandOpsRateBar('결과물 승인률', b.deliverable_rate, b.deliverable_approved, b.deliverable_total)
    + banner
    + '<div style="display:flex;justify-content:space-between;align-items:center;margin-top:10px;padding-top:8px;border-top:1px solid var(--line)">'
      + '<span style="font-size:10px;color:var(--muted)">최근 활동 ' + (b.last_activity_at ? fmtDate(b.last_activity_at) : '—') + '</span>'
      + '<span style="font-size:11px;color:var(--pink);font-weight:600">상세 보기 →</span>'
    + '</div>'
    + '</div>';
}

// ════════════════════════════════════════════════════════════════════
// SECTION: BRAND OPS DETAIL — 브랜드 상세 페인 (PR 4)
//   get_brand_ops_detail RPC(jsonb) + 캠페인별 승인 수는 화면에서 추가 집계.
//   신청 연결 캠페인 ↔ 직접 등록 캠페인 연결/해제 (link/unlink RPC).
// ════════════════════════════════════════════════════════════════════

var _brandOpsDetailId = null;
var _brandOpsDetailData = null;
var _brandOpsApprByCamp = {};   // campaign_id → 승인 신청 수 (인플루언서 응모)
var _brandOpsAuditIds = new Set();  // 감사용 계정 id — 인증성공 막대에서 격리(모집·제출 막대와 정합)

async function loadBrandOpsDetail() {
  var body = $('brandOpsDetailBody');
  if (!_brandOpsDetailId) {
    if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px">운영 현황에서 브랜드를 선택하세요</div>';
    return;
  }
  if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px"><span class="spinner" style="width:22px;height:22px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></div>';

  // 감사용 계정 id 집합(소수) — 폴백 승인 집계에서 격리. 전체 회원 로드 없이 가볍게 조회.
  var results = await Promise.all([
    getBrandOpsDetail(_brandOpsDetailId),
    fetchApplications(),
    // ⚠️ 원본 표가 아니라 **가림막 뷰**로 읽는다(마이그레이션 212, 조치 계획 묶음 E-1).
    db ? db.from('influencers_admin_view').select('id').eq('is_audit', true) : Promise.resolve({data: []}),
  ]);
  var detail = results[0];
  var apps = results[1] || [];
  var _auditIds = new Set((((results[2] && results[2].data) || [])).map(function(r){ return r.id; }));
  _brandOpsAuditIds = _auditIds;   // 비동기 채움되는 인증성공 막대(hydrateCampCertBars)에서 재사용
  _brandOpsDetailData = detail;
  if (!detail || !detail.brand) {
    if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px">브랜드 정보를 불러올 수 없습니다</div>';
    return;
  }
  // 캠페인별 승인 수 집계 (인플루언서 응모 = applications, status approved). 감사용 제외(격리).
  _brandOpsApprByCamp = {};
  apps.forEach(function(a){
    if (a.status === 'approved' && !_auditIds.has(a.user_id)) _brandOpsApprByCamp[a.campaign_id] = (_brandOpsApprByCamp[a.campaign_id] || 0) + 1;
  });
  renderBrandOpsDetail(detail);
}

function renderBrandOpsDetail(d) {
  var body = $('brandOpsDetailBody');
  if (!body) return;
  var b = d.brand || {};
  var company = d.company;
  var apps = d.applications || [];
  var external = d.external_campaigns || [];

  // 요약 KPI 집계
  var allCamps = [];
  apps.forEach(function(a){ (a.campaigns||[]).forEach(function(c){ allCamps.push(c); }); });
  external.forEach(function(c){ allCamps.push(c); });
  var openApps = apps.filter(function(a){ return a.status !== 'done' && a.status !== 'rejected'; }).length;
  var activeCamps = allCamps.filter(function(c){ return c.status === 'active' || c.status === 'scheduled'; }).length;

  // 헤더 (빵부스러기 + 액션)
  var crumb = (company ? esc(company.name_ko || '') + ' › ' : '미분류 › ') + esc(b.name || '');
  var html = ''
    + '<div style="display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap;margin-bottom:14px">'
      + '<div>'
        + '<button class="btn btn-ghost btn-xs" onclick="switchAdminPane(\'brand-ops\')" style="margin-bottom:6px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">arrow_back</span> 운영 현황</button>'
        + '<div style="font-size:11px;color:var(--muted)">' + crumb + '</div>'
        + '<div style="font-size:18px;font-weight:700;color:var(--ink)">' + esc(b.name || '—') + ' <span style="font-size:12px;font-weight:500;color:var(--muted)">' + esc(b.brand_no || '') + '</span></div>'
      + '</div>'
      + '<button class="btn btn-ghost btn-sm" onclick="openBrandDetailModal(\'' + esc(b.id) + '\')"><span class="material-icons-round notranslate" translate="no" style="font-size:15px;vertical-align:middle">edit</span> 브랜드 정보</button>'
    + '</div>';

  // 요약 KPI 바
  html += '<div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px">'
    + brandOpsKpi('진행 신청', openApps)
    + brandOpsKpi('전체 신청', apps.length)
    + brandOpsKpi('진행 캠페인', activeCamps)
    + brandOpsKpi('전체 캠페인', allCamps.length)
    + '</div>';

  // 신청 아코디언
  html += '<div style="font-size:14px;font-weight:700;color:var(--ink);margin:8px 0">광고주 신청 (' + apps.length + ')</div>';
  if (apps.length === 0) {
    html += '<div style="color:var(--muted);font-size:13px;padding:12px 0">연결된 광고주 신청이 없습니다</div>';
  } else {
    html += apps.map(function(a){ return renderBrandOpsAppBlock(a); }).join('');
  }

  // 직접 등록 캠페인 (신청 미연결)
  html += '<div style="font-size:14px;font-weight:700;color:var(--ink);margin:18px 0 8px">직접 등록 캠페인 (' + external.length + ')</div>';
  if (external.length === 0) {
    html += '<div style="color:var(--muted);font-size:13px;padding:12px 0">직접 등록 캠페인이 없습니다</div>';
  } else {
    html += '<div class="brand-ops-mini-grid">' + external.map(function(c){ return renderCampMiniCard(c, true); }).join('') + '</div>';
  }

  body.innerHTML = html;
  hydrateCampCertBars();
}

// 미니카드 3번째 진행바(인증 성공/모집인원) 비동기 채움 — 캠페인별 결과물 조회 후 computeCertStatus 카운트.
// 인증성공 정의는 결과물 관리 화면과 동일(buildDeliverableGroups + computeCertStatus 단일 소스).
var _campCertHydrateToken = 0;
async function hydrateCampCertBars() {
  var token = ++_campCertHydrateToken;
  var slotEls = Array.prototype.slice.call(document.querySelectorAll('[data-camp-cert]'));
  if (!slotEls.length) return;
  await Promise.all(slotEls.map(async function(el) {
    var campId = el.getAttribute('data-camp-cert');
    var slotsN = parseInt(el.getAttribute('data-slots') || '0', 10);
    // 화면 속성으로 흉내 낸 캠페인 — 조회가 실제 캠페인 행을 물어오면 그걸로 갈아탄다(아래).
    //   흉내 객체에는 가구매(proxy_purchase) 여부가 없어, 그대로 두면 가구매 캠페인의
    //   인증 성공 막대가 0에서 굳는다(결과물 관리·정산은 성공으로 세는데 이 화면만 다름).
    var camp = { id: campId, recruit_type: el.getAttribute('data-rt') || '', channel: el.getAttribute('data-ch') || '' };
    var delivs = await fetchDeliverablesByCampaign(campId);
    if (token !== _campCertHydrateToken) return;       // 그 사이 다른 브랜드 상세로 전환 — 폐기
    if (!document.body.contains(el)) return;
    // 결과물이 0건이면 갈아탈 대상이 없지만, 그때는 인증 성공도 0이라 판정에 쓰이지 않는다.
    if (delivs.length && delivs[0].campaigns) camp = delivs[0].campaigns;
    // 감사용 계정 격리 — 모집·제출 막대(get_brand_ops_detail, 마이그181)는 서버에서 is_audit 제외되는데
    // 인증성공 분자만 감사용이 포함돼 「인증성공>제출」 역전이 가능하던 문제 수정.
    var scoped = delivs.filter(function(d){ return !_brandOpsAuditIds.has(d.user_id); });
    var success = countCertSuccess(scoped, camp);
    var pct = slotsN > 0 ? Math.round(success / slotsN * 100) : null;
    el.innerHTML = brandOpsRateBar('인증 성공', pct, success, slotsN);
  }));
}

function brandOpsKpi(label, val) {
  return '<div style="flex:1;min-width:110px;background:#fff;border:1px solid var(--line);border-radius:10px;padding:10px 12px">'
    + '<div style="font-size:11px;color:var(--muted)">' + esc(label) + '</div>'
    + '<div style="font-size:20px;font-weight:700;color:var(--ink);font-variant-numeric:tabular-nums">' + (val||0) + '</div>'
    + '</div>';
}

function renderBrandOpsAppBlock(a) {
  var open = (a.status !== 'done' && a.status !== 'rejected');
  var camps = a.campaigns || [];
  var quote = a.final_quote_krw || a.estimated_krw;
  return '<details class="brand-ops-app"' + (open ? ' open' : '') + ' style="border:1px solid var(--line);border-radius:10px;margin-bottom:10px;padding:0 12px">'
    + '<summary style="display:flex;align-items:center;gap:10px;padding:10px 0;cursor:pointer;list-style:none">'
      + '<span style="font-weight:600;color:var(--ink);font-size:13px">' + esc(a.application_no || '신청') + '</span>'
      + '<span style="font-size:11px;color:var(--muted)">' + esc(brandOpsFormTypeLabel(a.form_type)) + '</span>'
      + '<span style="font-size:11px;background:#F0F0F0;color:#555;padding:2px 8px;border-radius:10px">' + esc(a.status || '') + '</span>'
      + (quote ? '<span style="font-size:11px;color:var(--muted)">견적 ' + Number(quote).toLocaleString() + '원</span>' : '')
      + '<span style="margin-left:auto;font-size:11px;color:var(--muted)">캠페인 ' + camps.length + '</span>'
    + '</summary>'
    + '<div style="padding:0 0 12px">'
      + (camps.length ? '<div class="brand-ops-mini-grid">' + camps.map(function(c){ return renderCampMiniCard(c, false, a.id); }).join('') + '</div>'
                      : '<div style="color:var(--muted);font-size:12px;padding:6px 0">연결된 캠페인 없음</div>')
    + '</div>'
    + '</details>';
}

function brandOpsFormTypeLabel(ft) {
  return ft === 'reviewer' ? '리뷰어' : ft === 'seeding' ? '시딩' : (ft || '');
}

// 캠페인 상태 한글 라벨·색 (운영 현황 미니카드 전용)
var BRAND_OPS_CAMP_STATUS_KO = { draft: '준비', scheduled: '모집예정', active: '모집중', closed: '모집마감', ended: '종료', expired: '노출종료' };
var BRAND_OPS_CAMP_STATUS_COLOR = {
  active:    { bg: '#E8F5E9', color: '#2E7D32' },
  scheduled: { bg: '#E3F2FD', color: '#1565C0' },
  closed:    { bg: '#F5F5F5', color: '#757575' },
  draft:     { bg: '#FFF8E1', color: '#F9A825' },
  ended:     { bg: '#EDE7F6', color: '#5E35B1' },   // 캠페인 목록의 badge-done(남보라)과 같은 뜻 — 일정 뷰 「종료 포함」에서 쓴다
  expired:   { bg: '#FAFAFA', color: '#9E9E9E' }
};
// 캠페인 모집 타입 한글 (admin.js 의 RECRUIT_TYPE_LABEL_KO 폴백)
var BRAND_OPS_RECRUIT_TYPE_KO = { monitor: '리뷰어', gifting: '기프팅', visit: '방문형' };

// 기간 표시용 날짜 — 사이트 공통 표기 YYYY/MM/DD 로 통일 (2026-07-23, 구 M/D 축약 폐지)
function brandOpsShortDate(d) {
  return formatDate(d);
}

// 채널 문자열(콤마구분) → 한글 라벨, 복수면 channel_match 구분자
function brandOpsChannelText(channel, match) {
  if (!channel) return '';
  var sep = match === 'and' ? ' & ' : ' · ';
  return channel.split(',').map(function(ch) {
    ch = ch.trim();
    return (typeof getChannelLabel === 'function') ? getChannelLabel(ch) : ch;
  }).filter(Boolean).join(sep);
}

// 미니카드 썸네일 (img1 없으면 placeholder)
function brandOpsCampThumb(c) {
  return c.img1
    ? '<img src="' + esc(storageThumbUrl(c.img1)) + '" data-orig="' + esc(c.img1) + '" onerror="this.onerror=null;this.src=this.dataset.orig" alt="" style="width:56px;height:56px;border-radius:8px;object-fit:cover;flex-shrink:0;background:#f0f0f0">'
    : '<div style="width:56px;height:56px;border-radius:8px;flex-shrink:0;background:#f0f0f0;display:flex;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:#bbb">image</span></div>';
}

// 미니카드 상단: 모집 타입 + 채널
function brandOpsCampTypeChannel(c) {
  var typeKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined' && RECRUIT_TYPE_LABEL_KO[c.recruit_type]) || BRAND_OPS_RECRUIT_TYPE_KO[c.recruit_type] || c.recruit_type || '';
  var chText = brandOpsChannelText(c.channel, c.channel_match);
  return '<div style="display:flex;align-items:center;gap:6px;font-size:10px;color:var(--muted);margin-bottom:3px">'
    + (typeKo ? '<span style="background:var(--surface-dim);color:var(--ink);font-weight:600;padding:1px 6px;border-radius:6px;flex-shrink:0">' + esc(typeKo) + '</span>' : '')
    + (chText ? '<span style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(chText) + '</span>' : '')
    + '</div>';
}

// M/D~M/D 기간 범위 (한쪽만 있으면 그쪽만)
function brandOpsDateRange(s, e) {
  var ss = brandOpsShortDate(s), ee = brandOpsShortDate(e);
  if (ss && ee) return ss + '~' + ee;
  if (ee) return '~' + ee;
  if (ss) return ss + '~';
  return '';
}

// 진행바 하단 날짜 줄 (작은 글씨)
function brandOpsMiniDateLine(text) {
  return text ? '<div style="font-size:10px;color:var(--muted);margin-top:2px;margin-bottom:4px">' + esc(text) + '</div>' : '';
}

// 제출 진행바 하단 텍스트: 리뷰어=구매기간 / 방문형=방문기간 + 제출마감
//   ⚠️ 리뷰어형은 구매 기간이 모집 기간과 **글자 그대로 같게** 저장된다. 그 날짜는 바로 위
//      모집 진행바 아래에 이미 있으므로, 같으면 여기서는 그리지 않는다(2026-08-11). 판정은
//      공용 헬퍼 하나만 쓴다 — 캠페인 목록·진행현황 카드와 같은 소스.
//   ⚠️ 시딩형 선정 기간은 여기 넣지 않는다. 이 줄은 **제출** 진행바에 딸린 설명이고 선정은
//      모집 단계의 일이라, 넣으면 진행바가 말하는 것과 다른 이야기가 붙는다.
function brandOpsSubmitDateText(c) {
  var parts = [];
  var kind = (typeof campaignPeriodRowKind === 'function') ? campaignPeriodRowKind(c) : 'none';
  if (kind === 'split') {
    var pr = brandOpsDateRange(c.purchase_start, c.purchase_end);
    if (pr) parts.push('구매 ' + pr);
  } else if (kind === 'visit') {
    var vr = brandOpsDateRange(c.visit_start, c.visit_end);
    if (vr) parts.push('방문 ' + vr);
  }
  if (c.submission_end) parts.push('제출마감 ' + brandOpsShortDate(c.submission_end));
  return parts.join(' · ');
}

function renderCampMiniCard(c, isExternal, applicationId) {
  // 모집: 승인 인플 / slots (RPC approved_app_count 우선, 없으면 화면 집계 폴백)
  var approved = (c.approved_app_count != null) ? c.approved_app_count : (_brandOpsApprByCamp[c.id] || 0);
  var slots = c.slots || 0;
  var recruitPct = slots > 0 ? Math.min(100, Math.round(approved / slots * 100)) : null;
  // 제출률: 결과물 제출 인플 / 승인 인플   ·   승인률: 승인 결과물 / 제출 결과물
  var submittedInf = c.deliv_submitted_inf || 0;
  var submitPct = approved > 0 ? Math.min(100, Math.round(submittedInf / approved * 100)) : null;
  // 3번째 진행바는 「인증 성공 / 모집인원」 — 인증성공 수는 RPC 집계에 없어 hydrateCampCertBars 가 비동기로 채움

  var stKo = BRAND_OPS_CAMP_STATUS_KO[c.status] || c.status || '';
  var stColor = BRAND_OPS_CAMP_STATUS_COLOR[c.status] || { bg: '#F5F5F5', color: '#757575' };
  var statusBadge = '<span style="font-size:10px;background:' + stColor.bg + ';color:' + stColor.color + ';padding:1px 7px;border-radius:8px;white-space:nowrap;flex-shrink:0">' + esc(stKo) + '</span>';

  // 연결/해제 버튼: 직접 등록(external)이면 「신청에 연결」, 신청 연결됨이면 「연결 해제」
  var linkBtn = isExternal
    ? '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openLinkCampaignModal(\'' + esc(c.id) + '\')">신청에 연결</button>'
    : '<button class="btn btn-ghost btn-xs" style="color:#c0392b" onclick="event.stopPropagation();confirmUnlinkCampaign(\'' + esc(c.id) + '\')">연결 해제</button>';

  return '<div class="brand-ops-mini-card">'
    + '<div style="display:flex;gap:10px;align-items:flex-start">'
      + brandOpsCampThumb(c)
      + '<div style="min-width:0;flex:1">'
        + '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:6px">'
          + '<div style="min-width:0">'
            + brandOpsCampTypeChannel(c)
            + '<div style="font-weight:600;font-size:12px;color:var(--ink);white-space:nowrap;overflow:hidden;text-overflow:ellipsis">' + esc(c.title || c.product_ko || '—') + '</div>'
          + '</div>'
          + statusBadge
        + '</div>'
      + '</div>'
    + '</div>'
    + brandOpsRateBar('모집', recruitPct, approved, slots)
    + brandOpsMiniDateLine((function(){ var r = brandOpsDateRange(c.recruit_start, c.deadline); return r ? '모집 ' + r : ''; })())
    + brandOpsRateBar('제출', submitPct, submittedInf, approved)
    + brandOpsMiniDateLine(brandOpsSubmitDateText(c))
    + '<div class="cert-bar-slot" data-camp-cert="' + esc(c.id) + '" data-slots="' + slots + '" data-rt="' + esc(c.recruit_type || '') + '" data-ch="' + esc(c.channel || '') + '">' + brandOpsRateBar('인증 성공', null, 0, slots) + '</div>'
    + '<div style="display:flex;justify-content:flex-end;align-items:center;margin-top:8px;gap:4px">'
      + '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openCampApplicants(\'' + esc(c.id) + '\', null, \'brand-ops\')">상세</button>'
      + linkBtn
    + '</div>'
    + '</div>';
}

// ── 연결 모달 ──
var _linkCampaignId = null;

function openLinkCampaignModal(campaignId) {
  if (!_brandOpsDetailData) return;
  _linkCampaignId = campaignId;
  var apps = _brandOpsDetailData.applications || [];
  var body = $('linkCampaignModalBody');
  if (body) {
    if (apps.length === 0) {
      body.innerHTML = '<div style="color:var(--muted);font-size:13px;padding:12px 0">이 브랜드에 연결할 광고주 신청이 없습니다. 먼저 신청을 등록하세요.</div>';
    } else {
      body.innerHTML = '<div style="font-size:12px;color:var(--muted);margin-bottom:10px">이 캠페인을 연결할 광고주 신청을 선택하세요. 연결 시 캠페인 번호가 신청 기준으로 재발급됩니다.</div>'
        + apps.map(function(a){
            return '<label style="display:flex;align-items:center;gap:8px;padding:8px 10px;border-bottom:1px solid var(--line);cursor:pointer">'
              + '<input type="radio" name="linkAppChoice" value="' + esc(a.id) + '">'
              + '<span style="flex:1;font-size:13px;color:var(--ink)">' + esc(a.application_no || '신청') + ' <span style="font-size:11px;color:var(--muted)">· ' + esc(brandOpsFormTypeLabel(a.form_type)) + ' · ' + esc(a.status||'') + '</span></span>'
              + '</label>';
          }).join('');
    }
  }
  openModal('linkCampaignModal');
}

function closeLinkCampaignModal() { closeModal('linkCampaignModal'); _linkCampaignId = null; }

async function saveLinkCampaign() {
  if (!_linkCampaignId) { toast('연결할 캠페인이 없습니다'); return; }
  var sel = document.querySelector('input[name="linkAppChoice"]:checked');
  if (!sel) { toast('연결할 신청을 선택하세요'); return; }
  var appId = sel.value;
  var btn = $('linkCampaignSaveBtn');
  if (btn) { btn.disabled = true; btn.textContent = '연결 중…'; }
  var res = await linkCampaignToApplication(_linkCampaignId, appId);
  if (btn) { btn.disabled = false; btn.textContent = '연결'; }
  if (!res.ok) { toast('연결 실패: ' + friendlyError({ message: res.error })); return; }
  if (res.data && res.data.unchanged) toast('이미 해당 신청에 연결돼 있습니다');
  else toast('연결 완료 · 번호 ' + (res.data ? res.data.new_no : '재발급'));
  closeLinkCampaignModal();
  await loadBrandOpsDetail();
}

async function confirmUnlinkCampaign(campaignId) {
  var ok = await showConfirm('이 캠페인의 신청 연결을 해제할까요? 캠페인 번호가 직접 등록 기준으로 재발급됩니다.');
  if (!ok) return;
  var res = await unlinkCampaignFromApplication(campaignId);
  if (!res.ok) { toast('해제 실패: ' + friendlyError({ message: res.error })); return; }
  if (res.data && res.data.unchanged) toast('이미 직접 등록 상태입니다');
  else toast('연결 해제 · 번호 ' + (res.data ? res.data.new_no : '재발급'));
  await loadBrandOpsDetail();
}

// ============================================================================
// 「일정」 뷰 — 캠페인 간트차트 (2026-09-07)
//   사양서 docs/specs/2026-09-07-brand-ops-schedule-gantt-view.md · 작업표 …-breakdown.md
//   데이터베이스 변경 0. 캠페인 1건 = 1행. 보기 전용(캠페인명 → 진행현황, 「편집」 → 기존 편집 폼).
// ============================================================================
var BRAND_OPS_VIEW_KEY = 'reverb.brandOps.view';
var _brandOpsView = 'schedule';          // 'schedule' | 'cards'
var _brandOpsIncludeEnded = false;       // 「종료 포함」 — ended·expired 를 대상에 더한다
var _brandOpsDelivCache = {};            // 대상 집합 열쇠('base'|'all') → 결과물 배열 | null(실패). undefined = 아직 안 받음
var _brandOpsDelivToken = 0;
var GANTT_BASE_STATUSES = ['scheduled', 'active', 'closed'];   // 결정 4 — draft·삭제된 캠페인은 어느 쪽에도 없다
var GANTT_ENDED_STATUSES = ['ended', 'expired'];
var GANTT_DAY_PX = 10;                   // 하루 폭. 85일 = 850px (S1)
var GANTT_RANGE = { before: 14, after: 70 };   // 기준일 -14일 ~ +70일(12주)
var _ganttBaseYmd = null;                // null 이면 오늘

try { var _v = localStorage.getItem(BRAND_OPS_VIEW_KEY); if (_v === 'cards' || _v === 'schedule') _brandOpsView = _v; } catch(e) {}

// ---- 뷰 전환(정산 페인처럼 켜는 함수가 나머지를 끄는 짝) ----
function showBrandOpsSchedule() { _brandOpsView = 'schedule'; _saveBrandOpsView(); applyBrandOpsView(); renderBrandOpsCurrentView(); }
function showBrandOpsCards()    { _brandOpsView = 'cards';    _saveBrandOpsView(); applyBrandOpsView(); renderBrandOpsCurrentView(); }
function _saveBrandOpsView() { try { localStorage.setItem(BRAND_OPS_VIEW_KEY, _brandOpsView); } catch(e) {} }

// 현재 뷰에 맞춰 컨테이너·필터 요소를 켜고 끈다 — 렌더와 분리(스피너를 띄운 채로도 부른다).
function applyBrandOpsView() {
  var sched = _brandOpsView === 'schedule';
  var grid = $('brandOpsGrid'), wrap = $('brandOpsScheduleWrap');
  if (grid) grid.hidden = sched;
  if (wrap) wrap.hidden = !sched;
  var sortG = $('brandOpsSortGroup'), tools = $('brandOpsScheduleTools');
  if (sortG) sortG.hidden = sched;          // 정렬 드롭다운은 브랜드 뷰 전용(결정 8)
  if (tools) tools.hidden = !sched;         // 「종료 포함」·‹ 오늘 › 는 일정 뷰 전용(결정 9)
  var search = $('brandOpsSearch');
  if (search) search.placeholder = sched ? '캠페인명 · 캠페인 번호 · 브랜드명' : '브랜드명 · 회사명 · 브랜드번호';
  var sub = $('brandOpsSubtitle');
  if (sub) sub.textContent = sched ? '캠페인을 시간축 위에 놓고 일정과 진행 숫자를 한눈에. 캠페인명을 누르면 진행현황으로 갑니다' : '브랜드별 진행 상황을 한눈에. 경고 단계가 높은 브랜드부터 표시됩니다';
  renderBrandOpsViewTabs();
}

function renderBrandOpsViewTabs() {
  var bar = $('brandOpsViewTabBar');
  if (!bar) return;
  var tabs = [
    { code: 'schedule', label: '일정', n: brandOpsScheduleTargetCampaigns().length, fn: 'showBrandOpsSchedule' },
    { code: 'cards',    label: '브랜드', n: (_brandOpsCache || []).length, fn: 'showBrandOpsCards' },
  ];
  bar.innerHTML = tabs.map(function(t){
    var cls = 'status-tab-btn' + (t.code === _brandOpsView ? ' on' : '');
    return '<button type="button" class="' + cls + '" data-tab="' + t.code + '" onclick="' + t.fn + '()">' + t.label + '<span class="tab-count">(' + t.n + ')</span></button>';
  }).join('');
}

// 필터 4개의 인라인 핸들러가 부르는 단일 진입점 — 현재 뷰로 갈라 그린다.
function renderBrandOpsCurrentView() {
  if (_brandOpsView === 'schedule') renderBrandOpsSchedule();
  else renderBrandOpsCards();
  renderBrandOpsViewTabs();
}

function setBrandOpsIncludeEnded(on) {
  _brandOpsIncludeEnded = !!on;
  renderBrandOpsCurrentView();
}

// ---- 대상 집합·필터·정렬 ----
// 대상 집합(결정 4) — 회사·검색 필터 **전**. 결과물 조회는 이 집합 단위로 묶어 받는다.
function brandOpsScheduleTargetCampaigns() {
  var statuses = _brandOpsIncludeEnded ? GANTT_BASE_STATUSES.concat(GANTT_ENDED_STATUSES) : GANTT_BASE_STATUSES;
  return (_brandOpsCampaigns || []).filter(function(c){ return statuses.indexOf(c.status) >= 0; });
}

// 회사 필터 + 검색 + 정렬(결정 8·9, 선결 조건 S2·S3 채택안).
//   회사: 캠페인 표에는 회사 값이 없어 브랜드 집계 행(_brandOpsCache)의 brand_id→company_id 로 잇는다.
//         브랜드가 빈 캠페인은 「전체」에서만 보이고, 회사를 고르면 빠진다. 「미분류」는 브랜드는 있는데 회사가 없는 것.
//   검색: 캠페인명 · 캠페인 번호 · 브랜드명(브랜드 뷰의 브랜드명·회사명·브랜드번호와 다르다 — 행이 캠페인이라).
//   정렬: 모집 마감일 가까운 순(마감 없음은 뒤). 「종료 포함」이면 종료 건은 제출 마감 최근 순으로 뒤에.
function brandOpsScheduleCampaigns() {
  var companyF = $('brandOpsCompanyFilter')?.value || '';
  var q = (($('brandOpsSearch')?.value) || '').trim().toLowerCase();
  var brandCompany = {};
  (_brandOpsCache || []).forEach(function(b){ if (b.brand_id) brandCompany[b.brand_id] = b.company_id || null; });
  var list = brandOpsScheduleTargetCampaigns().filter(function(c){
    if (companyF === '__unassigned__') { if (!c.brand_id || brandCompany[c.brand_id]) return false; }
    else if (companyF) { if (!c.brand_id || brandCompany[c.brand_id] !== companyF) return false; }
    if (q) {
      var hay = ((c.title || '') + ' ' + (c.campaign_no || '') + ' ' + brandLabelAdmin(c)).toLowerCase();
      if (hay.indexOf(q) < 0) return false;
    }
    return true;
  });
  var isEnded = function(c){ return GANTT_ENDED_STATUSES.indexOf(c.status) >= 0; };
  return list.slice().sort(function(a, b){
    var ea = isEnded(a), eb = isEnded(b);
    if (ea !== eb) return ea ? 1 : -1;                       // 진행 중 먼저, 종료 건은 뒤
    if (ea) {                                                // 종료끼리: 제출 마감 최근 순(문자열 비교 — 시간대 개입 없음)
      var sa = a.submission_end || '', sb = b.submission_end || '';
      if (sa !== sb) return sa < sb ? 1 : -1;
      return (a.title || '').localeCompare(b.title || '');
    }
    var da = a.deadline || '', dbb = b.deadline || '';       // 진행 중: 마감 가까운 순, 마감 없음은 뒤
    if (!da && dbb) return 1;
    if (da && !dbb) return -1;
    if (da !== dbb) return da < dbb ? -1 : 1;
    return (a.title || '').localeCompare(b.title || '');
  });
}

// ---- 날짜 ↔ 위치 ----
// 🔴 날짜→일수 변환은 이 함수 하나. 두 `연-월-일` 문자열을 정수로 잘라 Date.UTC 차이로 센다.
//    `new Date('2026-09-07')` 파싱은 브라우저마다 협정 세계시/로컬 해석이 갈려 쓰지 않는다.
function _ganttUtc(ymd) {
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(ymd || ''));
  if (!m) return NaN;
  return Date.UTC(+m[1], +m[2] - 1, +m[3]);
}
function ganttDayOffset(baseYmd, ymd) {
  var a = _ganttUtc(baseYmd), b = _ganttUtc(ymd);
  if (isNaN(a) || isNaN(b)) return NaN;
  return Math.round((b - a) / 86400000);
}
function ganttAddDays(ymd, n) {
  var t = _ganttUtc(ymd);
  if (isNaN(t)) return '';
  return new Date(t + n * 86400000).toISOString().slice(0, 10);
}
// 「오늘」 = 기기 로컬 연·월·일(캠페인 날짜 칸이 시간대 없는 문자열이라 같은 방식). 한국·일본은 같은 날.
function ganttTodayYmd() {
  var d = new Date();
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
}
// 시각 값(first_active_at)은 **일본 표준시**로 잘라 날짜로 — 캠페인 날짜 칸이 일본 기준으로 입력되기 때문.
function ganttYmdFromTimestamp(ts) {
  if (!ts) return '';
  var t = new Date(ts).getTime();
  if (isNaN(t)) return '';
  return new Date(t + 9 * 3600000).toISOString().slice(0, 10);
}
function _ganttWeekday(ymd) { var t = _ganttUtc(ymd); return isNaN(t) ? NaN : new Date(t).getUTCDay(); }   // 0=일 … 1=월
function ganttRange() {
  var base = _ganttBaseYmd || ganttTodayYmd();
  var start = ganttAddDays(base, -GANTT_RANGE.before), end = ganttAddDays(base, GANTT_RANGE.after);
  return { base: base, start: start, end: end, days: GANTT_RANGE.before + GANTT_RANGE.after + 1, width: (GANTT_RANGE.before + GANTT_RANGE.after + 1) * GANTT_DAY_PX };
}
function ganttX(range, ymd) { return ganttDayOffset(range.start, ymd) * GANTT_DAY_PX; }
function ganttShift(weeks) { var r = ganttRange(); _ganttBaseYmd = ganttAddDays(r.base, weeks * 7); renderBrandOpsSchedule(); }
function ganttToday() { _ganttBaseYmd = null; renderBrandOpsSchedule(); }

// ---- 시간축 머리 ----
function renderGanttAxis(range) {
  var html = '';
  var firstMonday = null;
  for (var i = 0; i < range.days; i++) {
    var d = ganttAddDays(range.start, i);
    var x = i * GANTT_DAY_PX;
    if (i === 0 || d.slice(8, 10) === '01') {
      html += '<span class="gm" style="left:' + x + 'px">' + (+d.slice(5, 7)) + '월</span>';
    }
    if (_ganttWeekday(d) === 1) {
      if (firstMonday === null) firstMonday = x;
      html += '<span class="gw" style="left:' + x + 'px">' + (+d.slice(5, 7)) + '/' + (+d.slice(8, 10)) + '</span>';
    }
  }
  var today = ganttTodayYmd();
  var tx = ganttX(range, today);
  if (tx >= 0 && tx < range.width) html += '<span class="gt" style="left:' + (tx + GANTT_DAY_PX / 2) + 'px">오늘</span>';
  range.gridOffset = firstMonday === null ? 0 : firstMonday;
  return '<div class="gantt-axis" style="width:' + range.width + 'px">' + html + '</div>';
}

// ---- 그릴 것 목록(설계 5) ----
// 요소 = { name, start, end(null=끝일 없음), lane('main'|'sub'), ink, point, note, dday }
//   갈래는 campaignPeriodRowKind 의 이름으로 지목한다(부정 조건 금지).
function ganttSegmentsFor(c) {
  var segs = [];
  var kind = (typeof campaignPeriodRowKind === 'function') ? campaignPeriodRowKind(c) : 'none';
  // 예외 ㄱ — 모집 시작이 비면 first_active_at(처음 모집중이 된 시각) 으로. 인플루언서 화면의 「오늘」 폴백은 쓰지 않는다(일정표가 움직인다).
  var rs = c.recruit_start || ganttYmdFromTimestamp(c.first_active_at);
  var dl = c.deadline || '';
  if (rs && dl)       segs.push({ name: '모집', start: rs, end: dl, lane: 'main', ink: 'strong', dday: dl });
  else if (!rs && dl) segs.push({ name: '모집 마감', start: dl, end: dl, lane: 'main', ink: 'strong', point: true, note: '모집 시작일 없음', dday: dl });
  else if (rs && !dl) segs.push({ name: '모집', start: rs, end: null, lane: 'main', ink: 'strong', openEnd: true });   // 예외 ㄴ — 무기한 모집
  // 제출 — 시작점은 언제나 deadline 다음 날. ①이 마커여도 단독으로 그린다. deadline 이 없으면 시작점이 없어 마커.
  if (c.submission_end) {
    if (dl) segs.push({ name: '제출', start: ganttAddDays(dl, 1), end: c.submission_end, lane: 'main', ink: 'weak', dday: c.submission_end });
    else    segs.push({ name: '제출 마감', start: c.submission_end, end: c.submission_end, lane: 'main', ink: 'weak', point: true, dday: c.submission_end });
  }
  // 보조 — 구매(split 만)·방문(visit 만). merged·visitMerged 는 모집과 같아 안 그린다.
  if (kind === 'split' && c.purchase_start && c.purchase_end) segs.push({ name: '구매', start: c.purchase_start, end: c.purchase_end, lane: 'sub', ink: 'mid' });
  if (kind === 'visit' && c.visit_start && c.visit_end)       segs.push({ name: '방문', start: c.visit_start, end: c.visit_end, lane: 'sub', ink: 'mid' });
  // 선정 — 🔴 갈래로 가를 수 없다(방문형 선정형 행사는 갈래가 visit). 아래 조건은 다른 네 곳과 **글자 그대로** 같아야
  //   한다 — 목록과 근거는 인플루언서 상세(application.js)의 같은 자리 주석(이 자리가 다섯째).
  var isEvent = (typeof isEventCampaign === 'function') && isEventCampaign(c);
  var isSelEvent = (typeof isSelectionEvent === 'function') && isSelectionEvent(c);
  if ((c.recruit_type === 'gifting' || (c.recruit_type === 'visit' && (!isEvent || isSelEvent)))
      && (c.selection_start || c.selection_end)) {
    segs.push({ name: '선정', start: c.selection_start || c.selection_end, end: c.selection_end || c.selection_start, lane: 'sub', ink: 'mid' });
  }
  // 끝이 시작보다 앞이면(입력 오류) 점으로 — 음수 폭 막대를 만들지 않는다
  segs.forEach(function(s){ if (s.end !== null && s.end < s.start) { s.end = s.start; s.point = true; } });
  return segs;
}

function _ganttSegOverlaps(s, range) {
  if (s.start > range.end) return false;
  if (s.end === null) return true;          // 끝일 없음 — 시작이 범위 안이거나 그 앞이면 겹친다
  return s.end >= range.start;
}
function _ganttSegLabel(s, side) {
  // 마커 문구 = 구간 이름 + 「시작/마감」 + 날짜. 점 요소는 이름에 이미 성격이 있다.
  if (s.point) return s.name + ' ' + formatDate(s.start);
  return side === 'l' ? (s.name + ' 마감 ' + formatDate(s.end)) : (s.name + ' 시작 ' + formatDate(s.start));
}

// 시간축 칸(설계 4 「범위 밖 처리」 + 설계 5 막대)
function renderGanttTrack(c, range) {
  var segs = ganttSegmentsFor(c);
  var style = 'width:' + range.width + 'px;--gantt-week:' + (7 * GANTT_DAY_PX) + 'px;background-position-x:' + (range.gridOffset || 0) + 'px';
  var html = '';
  var today = ganttTodayYmd(), tx = ganttX(range, today);
  if (tx >= 0 && tx < range.width) html += '<div class="gantt-today" style="left:' + (tx + GANTT_DAY_PX / 2) + 'px"></div>';
  if (!segs.length) return '<div class="gantt-track" style="' + style + '">' + html + '<span class="gantt-nodate">날짜 없음</span></div>';
  var visible = segs.filter(function(s){ return _ganttSegOverlaps(s, range); });
  if (!visible.length) {
    var before = segs.filter(function(s){ return s.end !== null && s.end < range.start; }).sort(function(a, b){ return a.end < b.end ? 1 : -1; })[0];
    var after  = segs.filter(function(s){ return s.start > range.end; }).sort(function(a, b){ return a.start < b.start ? -1 : 1; })[0];
    if (before) html += '<span class="gantt-edge l">◀ ' + esc(_ganttSegLabel(before, 'l')) + '</span>';
    if (after)  html += '<span class="gantt-edge r">' + esc(_ganttSegLabel(after, 'r')) + ' ▶</span>';
    return '<div class="gantt-track" style="' + style + '">' + html + '</div>';
  }
  var subIdx = 0;
  visible.forEach(function(s){
    var x0 = ganttX(range, s.start);
    var x1 = s.end === null ? range.width : ganttX(range, s.end) + GANTT_DAY_PX;
    var clipL = x0 < 0, clipR = x1 > range.width;
    var left = Math.max(0, x0), right = Math.min(range.width, x1);
    var period = s.end === null ? (formatDate(s.start) + ' ~ (마감 없음)') : (formatDate(s.start) + ' ~ ' + formatDate(s.end));
    var tip = s.name + ' ' + period + (s.note ? ' · ' + s.note : '');
    var laneCls = s.lane === 'sub' ? (' lane-sub' + (subIdx++ ? '2' : '')) : '';
    if (s.point) {
      html += '<span class="gantt-point" role="img" aria-label="' + esc(tip) + '" title="' + esc(tip) + '" style="left:' + left + 'px"></span>';
    } else {
      html += '<div class="gantt-bar ink-' + s.ink + laneCls + (clipL ? ' clip-l' : '') + (clipR ? ' clip-r' : '') + (s.openEnd ? ' open-end' : '')
        + '" role="img" aria-label="' + esc(tip) + '" title="' + esc(tip) + '" style="left:' + left + 'px;width:' + Math.max(2, right - left) + 'px"></div>';
      if (s.openEnd && s.lane === 'main') html += '<span class="gantt-tag" style="right:4px">마감 없음</span>';
    }
    // D-day 배지 — 마감(deadline)·제출 마감에만, 그 날짜가 범위 안일 때. 막대 색은 안 바꾼다(결정 11).
    if (s.dday && s.lane === 'main' && !clipR && ganttX(range, s.dday) >= 0 && ganttX(range, s.dday) < range.width) {
      html += '<span class="gantt-dday" style="left:' + Math.min(right + 2, range.width - 44) + 'px">' + dDayLabel(s.dday) + '</span>';
    }
  });
  return '<div class="gantt-track" style="' + style + '">' + html + '</div>';
}

// ---- 왼쪽 열 + 숫자 3종 ----
function _ganttNum(n) { return (n === null || n === undefined) ? '<span style="color:var(--muted)">—</span>' : String(n); }
function renderScheduleRow(c, range, stats) {
  var title = c.title || '(제목 없음)';
  var typeKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined' && RECRUIT_TYPE_LABEL_KO[c.recruit_type]) || BRAND_OPS_RECRUIT_TYPE_KO[c.recruit_type] || c.recruit_type || '';
  var st = BRAND_OPS_CAMP_STATUS_COLOR[c.status] || { bg: '#F5F5F5', color: '#757575' };
  var slots = Number(c.slots || 0);
  var appr = (_brandOpsApprCounts && _brandOpsApprCounts[c.id]) ? _brandOpsApprCounts[c.id].approved : (_brandOpsApprCounts ? 0 : null);
  // stats: undefined = 아직 조회 중 / null = 조회 실패 / {submittedInf, cert}
  var submitted = (stats && appr !== null && appr > 0) ? stats.submittedInf : null;
  var cert = stats ? stats.cert : null;
  var pending = stats === undefined;
  var canEdit = (typeof isCampaignAdminOrAbove === 'function') && isCampaignAdminOrAbove();
  var idJs = esc(String(c.id));
  return '<div class="gantt-row">'
    + '<div class="gantt-left">'
    +   '<div class="gantt-cell c-title"><a href="#" class="camp-link ellip" title="' + esc(title) + '" data-camp-title="' + esc(title) + '" onclick="openCampApplicants(\'' + idJs + '\', this.dataset.campTitle, \'brand-ops\');return false">' + esc(title) + '</a><div class="sub ellip">' + esc(c.campaign_no || '') + '</div></div>'
    +   '<div class="gantt-cell c-brand"><span class="ellip" title="' + esc(brandLabelAdmin(c)) + '">' + (esc(brandLabelAdmin(c)) || '<span style="color:var(--muted)">—</span>') + '</span></div>'
    +   '<div class="gantt-cell c-type"><div class="sub" style="margin:0 0 2px">' + esc(typeKo) + '</div>' + channelChipsHtml(c.channel, c.channel_match) + '</div>'
    +   '<div class="gantt-cell c-status"><span style="display:inline-block;font-size:10px;font-weight:600;padding:2px 7px;border-radius:6px;background:' + st.bg + ';color:' + st.color + '">' + esc(BRAND_OPS_CAMP_STATUS_KO[c.status] || c.status || '') + '</span></div>'
    +   '<div class="gantt-cell c-num">' + (appr === null ? _ganttNum(null) : (appr + '/' + slots)) + '</div>'
    +   '<div class="gantt-cell c-num">' + (pending ? '<span style="color:var(--faint)">…</span>' : (submitted === null ? _ganttNum(null) : (submitted + '/' + appr))) + '</div>'
    +   '<div class="gantt-cell c-num">' + (pending ? '<span style="color:var(--faint)">…</span>' : (cert === null ? _ganttNum(null) : (cert + '/' + slots))) + '</div>'
    +   '<div class="gantt-cell c-edit">' + (canEdit ? '<button type="button" class="btn btn-ghost btn-xs" onclick="openEditCampaign(\'' + idJs + '\')">편집</button>' : '') + '</div>'
    + '</div>'
    + renderGanttTrack(c, range)
    + '</div>';
}

function renderScheduleHead(range) {
  return '<div class="gantt-left">'
    + '<div class="gantt-cell c-title">캠페인</div><div class="gantt-cell c-brand">브랜드</div><div class="gantt-cell c-type">형식 · 채널</div><div class="gantt-cell c-status">상태</div>'
    + '<div class="gantt-cell c-num" title="승인된 인플루언서 / 모집인원">승인/모집</div><div class="gantt-cell c-num" title="결과물을 1건 이상 낸 인플루언서 / 승인">제출/승인</div><div class="gantt-cell c-num" title="인증 성공 인플루언서 / 모집인원">인증</div><div class="gantt-cell c-edit"></div>'
    + '</div>' + renderGanttAxis(range);
}

// ---- 결과물 묶음 조회(설계 6) → 캠페인별 { submittedInf, cert } ----
function _brandOpsDelivKey() { return _brandOpsIncludeEnded ? 'all' : 'base'; }
async function loadScheduleDeliverables() {
  var key = _brandOpsDelivKey();
  if (_brandOpsDelivCache[key] !== undefined) return;
  var token = ++_brandOpsDelivToken;
  var ids = brandOpsScheduleTargetCampaigns().map(function(c){ return c.id; });
  var rows = await fetchDeliverablesByCampaignIds(ids);   // 실패 null / 0건 []
  if (token !== _brandOpsDelivToken) return;               // 그 사이 다시 들어왔거나 집합이 바뀜 — 폐기
  _brandOpsDelivCache[key] = rows;
  if (_brandOpsView === 'schedule') renderBrandOpsSchedule();
}
function _scheduleStatsFor(list) {
  var rows = _brandOpsDelivCache[_brandOpsDelivKey()];
  if (rows === undefined) return { pending: true, stats: {} };
  if (rows === null) return { pending: false, stats: null };
  var byCamp = {};
  rows.forEach(function(d){
    if (_brandOpsAuditIds.has(d.user_id)) return;     // 감사용 계정 격리 — 승인 수(서버 제외)와 정합
    (byCamp[d.campaign_id] = byCamp[d.campaign_id] || []).push(d);
  });
  var stats = {};
  list.forEach(function(c){
    var ds = byCamp[c.id] || [];
    var infs = {}; ds.forEach(function(d){ if (d.user_id) infs[d.user_id] = 1; });
    // countCertSuccess 는 검수 화면·미니카드와 같은 판정(buildDeliverableGroups → computeCertStatus).
    //   camp 는 fetchCampaigns() 가 준 실제 행이다(가구매·채널 판정 포함). 결과물 행에 임베드된
    //   campaigns 가 있으면 그쪽이 우선 쓰이는데, 판정에 필요한 값이 전부 있어 결과가 같다.
    stats[c.id] = { submittedInf: Object.keys(infs).length, cert: (typeof countCertSuccess === 'function') ? countCertSuccess(ds, c) : null };
  });
  return { pending: false, stats: stats };
}

// ---- 일정 뷰 본체 ----
function renderBrandOpsSchedule() {
  var rowsEl = $('brandOpsScheduleRows'), axisEl = $('brandOpsAxis'), note = $('brandOpsScheduleNote');
  if (!rowsEl || !axisEl) return;
  var count = $('brandOpsTotalCount');
  var target = brandOpsScheduleTargetCampaigns();
  var list = brandOpsScheduleCampaigns();
  if (count) count.textContent = '(' + list.length + ' / 대상 ' + target.length + ')';
  var range = ganttRange();
  axisEl.innerHTML = renderScheduleHead(range);
  if (typeof _campaignsLoadFailed !== 'undefined' && _campaignsLoadFailed) {
    rowsEl.innerHTML = '<div class="gantt-empty">캠페인을 불러오지 못했습니다 · 새로고침을 눌러 다시 시도해 주세요</div>';
    if (note) note.hidden = true;
    return;
  }
  if (!list.length) {
    rowsEl.innerHTML = '<div class="gantt-empty">조건에 맞는 캠페인이 없습니다' + (_brandOpsIncludeEnded ? '' : '<div style="font-size:11px;margin-top:6px">종료된 캠페인은 「종료 포함」을 켜면 보입니다</div>') + '</div>';
    if (note) note.hidden = true;
    return;
  }
  var st = _scheduleStatsFor(list);
  if (note) {
    if (st.stats === null) { note.textContent = '결과물을 불러오지 못해 제출·인증 칸을 비웠습니다. 새로고침을 눌러 다시 시도해 주세요'; note.hidden = false; }
    else note.hidden = true;
  }
  rowsEl.innerHTML = list.map(function(c){
    var s = st.pending ? undefined : (st.stats === null ? null : st.stats[c.id]);
    return renderScheduleRow(c, range, s);
  }).join('');
  if (st.pending) loadScheduleDeliverables();
}
