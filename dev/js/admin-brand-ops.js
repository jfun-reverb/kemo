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
var _brandOpsCampaigns = [];     // fetchCampaigns() 전건 — 일정 뷰가 쓴다
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
  // 「최근 신청」 표는 2026-09-07 사용자 결정으로 뺐다 — 인플 신청 관리 페인에 같은 내용이 있다.
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

// 캠페인 썸네일 (img1 없으면 placeholder). 브랜드 뷰 미니카드(56px)와 일정 뷰 캠페인 행(32px)이 같은 함수를 쓴다
function brandOpsCampThumb(c, size) {
  var px = size || 56;
  var radius = px >= 48 ? 8 : 6;
  var icon = px >= 48 ? 22 : 16;
  var box = 'width:' + px + 'px;height:' + px + 'px;border-radius:' + radius + 'px;flex-shrink:0;background:#f0f0f0';
  return c.img1
    ? '<img src="' + esc(storageThumbUrl(c.img1)) + '" data-orig="' + esc(c.img1) + '" onerror="this.onerror=null;this.src=this.dataset.orig" alt="" style="' + box + ';object-fit:cover">'
    : '<div style="' + box + ';display:flex;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="font-size:' + icon + 'px;color:#bbb">image</span></div>';
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
// 줌 단위(2026-09-07 편의 기능) — 하루 폭과 표시 범위를 함께 정한다. 세 단위 모두 약 840~850px.
//   ⚠️ GANTT_DAY_PX·GANTT_RANGE 는 setGanttZoom 이 갱신하는 값이다 — 상수처럼 읽되 직접 대입하지 말 것.
var GANTT_ZOOMS = {
  day:   { px: 10,  before: 14, after: 70,  shiftWeeks: 4,  label: '일' },   // 12주
  week:  { px: 5,   before: 28, after: 140, shiftWeeks: 8,  label: '주' },   // 24주
  month: { px: 2.5, before: 56, after: 280, shiftWeeks: 16, label: '월' },   // 48주
};
var GANTT_ZOOM_KEY = 'reverb.brandOps.ganttZoom';
var _ganttZoom = 'day';
try { var _z = localStorage.getItem(GANTT_ZOOM_KEY); if (GANTT_ZOOMS[_z]) _ganttZoom = _z; } catch(e) {}
var GANTT_DAY_PX = GANTT_ZOOMS[_ganttZoom].px;
var GANTT_RANGE = { before: GANTT_ZOOMS[_ganttZoom].before, after: GANTT_ZOOMS[_ganttZoom].after };
var _ganttBaseYmd = null;                // null 이면 오늘
// 가로 스크롤(2026-09-09 사용자 지시 「스크롤도 같이 되게」) — 그리는 범위를 보이는 창(GANTT_RANGE)보다 양쪽으로 넉넉히 넓혀 두고
//   (`_ganttExt`, 일 단위), 처음엔 「기준일 - before」가 왼쪽 끝에 오도록 스크롤해 둔다. 스크롤이 끝에 닿으면 그쪽을 한 이동폭(shiftWeeks)만큼
//   더 그리고 스크롤 위치를 보정해 화면이 안 튄다. ‹ › 는 이제 범위를 옮기는 게 아니라 **그 이동폭만큼 스크롤**한다.
//   ⚠️ 상한(GANTT_EXT_CAP_DAYS)이 없으면 끝까지 밀 때마다 DOM 이 계속 넓어진다.
var _ganttExt = null;                    // { before, after } — 그린 범위(일). null 이면 줌 기본값으로 초기화
var _ganttScrollTo = null;               // 다음 렌더 뒤 맞출 scrollLeft(오늘·줌 전환 때 기본 위치). null 이면 직전 위치 유지
var _ganttExtending = false;             // 가장자리 확장 재진입 막기
var GANTT_EXT_CAP_DAYS = 730;            // 한쪽 최대 2년
var _ganttCurrentRange = null;           // 마지막으로 그린 범위 — 마우스 날짜 안내선이 읽는다
// 왼쪽 열 접기(노트북에서 시간축이 좁을 때) — 캠페인명·상태만 남긴다. 브라우저 단위 기억
var GANTT_LEFT_KEY = 'reverb.brandOps.ganttLeft';
var _ganttLeftCollapsed = false;
try { _ganttLeftCollapsed = localStorage.getItem(GANTT_LEFT_KEY) === 'collapsed'; } catch(e) {}
// 빠른 필터 칩 — '' | 'deadline7'(마감 7일 이내) | 'submitShort'(제출 미달) | 'certShort'(인증 미달)
var _ganttQuick = '';
// 머리글 클릭 정렬(2026-09-07 사용자 요청) — 캠페인 관리 목록의 ▲▼ 방식. key 가 null 이면 기본(마감 가까운 순, 결정 8)
//   같은 머리글을 다시 누르면 오름 → 내림 → 기본 순으로 돈다. 브라우저 기억은 안 한다(정렬은 그때그때 보는 것)
var _ganttSort = { key: null, dir: 'asc' };
var GANTT_SORT_COLS = { title: '캠페인', status: '상태', dur: '남은 기간', recruit: '모집률', cert: '결과물 승인률' };
var GANTT_STATUS_RANK = { scheduled: 0, active: 1, closed: 2, ended: 3, expired: 4 };
function toggleGanttSort(key) {
  if (!GANTT_SORT_COLS[key]) return;
  if (_ganttSort.key !== key) _ganttSort = { key: key, dir: 'asc' };
  else if (_ganttSort.dir === 'asc') _ganttSort.dir = 'desc';
  else _ganttSort = { key: null, dir: 'asc' };
  renderBrandOpsSchedule();
}
function ganttSortArrows(key) {
  var on = _ganttSort.key === key;
  return '<span class="sort-arrows' + (on ? ' ' + _ganttSort.dir : '') + '" onclick="toggleGanttSort(\'' + key + '\')" title="' + esc(GANTT_SORT_COLS[key]) + ' 기준 정렬">' + (on ? (_ganttSort.dir === 'asc' ? '▲' : '▼') : '▲▼') + '</span>';
}
// 정렬값 — 왼쪽 열에 보이는 값과 같은 재료. 숫자 칸이 「—」(값 없음)인 행은 방향과 무관하게 뒤로
function ganttSortValue(key, c, stats) {
  if (key === 'title') return (c.title || '').toLowerCase();
  if (key === 'status') return GANTT_STATUS_RANK[c.status] ?? 9;
  if (key === 'dur') { var sp = ganttSpanOf(ganttSegmentsFor(c)); return sp ? ganttRemainDays(sp.end) : null; }   // 남은 일수(지났으면 음수). 무기한은 가장 뒤
  if (key === 'recruit' || key === 'cert') { var pr = key === 'recruit' ? ganttRecruitRate(c) : ganttCertRate(c, stats); return pr.den > 0 && pr.num !== null ? pr.num / pr.den : null; }
  return null;
}
function ganttSortList(list, statsMap) {
  var key = _ganttSort.key, dir = _ganttSort.dir === 'desc' ? -1 : 1;
  if (!key) return list;
  return list.slice().sort(function(a, b){
    var va = ganttSortValue(key, a, statsMap ? statsMap[a.id] : null), vb = ganttSortValue(key, b, statsMap ? statsMap[b.id] : null);
    var na = va === null || va === undefined, nb = vb === null || vb === undefined;
    if (na && nb) return 0;
    if (na) return 1;                 // 값 없는 행은 뒤로(방향 무관 — 인증 성공일 열과 같은 규약)
    if (nb) return -1;
    if (va < vb) return -dir;
    if (va > vb) return dir;
    return 0;
  });
}
// 캠페인 펼치기(2026-09-07 사용자 요청 — 참고 화면의 트리형): 펼치면 그 캠페인의 기간(모집·구매/방문·선정·제출)이 자식 행으로
//   나오고 행마다 기간 일수·진척률이 붙는다. 기본은 모두 접힘, 펼친 캠페인은 브라우저가 기억한다.
var GANTT_OPEN_KEY = 'reverb.brandOps.ganttOpen';
var _ganttOpen = {};
try { (JSON.parse(localStorage.getItem(GANTT_OPEN_KEY) || '[]') || []).forEach(function(id){ _ganttOpen[id] = true; }); } catch(e) {}
function _saveGanttOpen() { try { localStorage.setItem(GANTT_OPEN_KEY, JSON.stringify(Object.keys(_ganttOpen))); } catch(e) {} }
function toggleGanttRow(id) {
  if (_ganttOpen[id]) delete _ganttOpen[id]; else _ganttOpen[id] = true;
  _saveGanttOpen();
  renderBrandOpsSchedule();
}
function setGanttAllOpen(open) {
  _ganttOpen = {};
  if (open) brandOpsScheduleTargetCampaigns().forEach(function(c){ if (ganttSegmentsFor(c).length) _ganttOpen[c.id] = true; });   // 기간이 하나도 없는 캠페인은 펼칠 것이 없다
  _saveGanttOpen();
  renderBrandOpsSchedule();
}
function renderGanttOpenButton(list) {
  var btn = $('brandOpsOpenAll');
  if (!btn) return;
  var anyOpen = list.some(function(c){ return _ganttOpen[c.id]; });
  btn.innerHTML = '<span class="material-icons-round notranslate" translate="no">' + (anyOpen ? 'unfold_less' : 'unfold_more') + '</span> ' + (anyOpen ? '모두 접기' : '모두 펼치기');   // 아이콘 크기는 .gantt-nav 가 정한다
  btn.onclick = function(){ setGanttAllOpen(!anyOpen); };
}
// 기간 일수(양 끝 포함) · 전체 구간 · 진척률
function ganttDays(start, end) { var n = ganttDayOffset(start, end); return isNaN(n) ? null : n + 1; }
function ganttSpanOf(segs) {
  if (!segs.length) return null;
  var start = null, end = null, open = false;
  segs.forEach(function(s){
    if (start === null || s.start < start) start = s.start;
    if (s.end === null) open = true; else if (end === null || s.end > end) end = s.end;
  });
  return { start: start, end: open ? null : end };
}
// 캠페인 행(부모)에 그리는 막대 하나 — 설정된 기간 전부를 아우르는 구간(가장 이른 시작 ~ 가장 늦은 마감).
//   모집·제출·선정이 따로 보이는 것은 **펼친 자식 행의 몫**이다(2026-09-09 사용자 지시 — 접혀 있을 때 나눠 보이지 않게).
//   막대 안에 이름은 안 쓴다(같은 지시 — 왼쪽 열에 캠페인명이 이미 있다. `name` 이 빈 문자열이면 막대 글자·마커 문구에서 빠진다).
//   D-day 배지도 여기엔 안 붙인다 — 펼친 자식 행(모집·제출)에 각각 붙는다(같은 지시). 남은 기간 열이 이미 마감 D-day 를 보여준다.
//   툴팁에 포함된 기간 이름을 적어 무엇이 합쳐졌는지 알린다.
// 자식 행·툴팁의 구간 순서 — 실제 흐름대로 모집 → 구매·방문 → 선정 → 제출(2026-09-09 사용자 지시 「제출이 맨 밑으로」).
//   ganttSegmentsFor 는 그리기 편의상 모집·제출을 먼저 넣으므로 보여줄 때 여기서 다시 세운다. 원본 배열은 건드리지 않는다.
var GANTT_SEG_ORDER = { '모집': 1, '모집 마감': 1, '구매': 2, '방문': 2, '선정': 3, '제출': 4, '제출 마감': 4 };
function ganttSegsInFlowOrder(segs) {
  return segs.slice().sort(function(a, b){ return (GANTT_SEG_ORDER[a.name] || 9) - (GANTT_SEG_ORDER[b.name] || 9); });
}
function ganttMergedSegment(segs) {
  var span = ganttSpanOf(segs);
  if (!span) return null;
  var names = ganttSegsInFlowOrder(segs).map(function(s){ return s.name; }).join(' · ');
  return {
    name: '', start: span.start, end: span.end, lane: 'main', ink: 'strong',
    note: '포함: ' + names,
    openEnd: span.end === null,
    point: span.end !== null && span.end === span.start
  };
}
// 남은 기간 — 마감까지 D-day 배지(dDayLabel, 다른 화면과 같은 규약: D-Day / D-n / 지났으면 D+n). 마감 없음은 「무기한」
function ganttRemainHtml(end) {
  if (end === null) return '<span style="font-size:11px;color:var(--muted)">무기한</span>';
  if (!end) return '<span style="color:var(--muted)">—</span>';
  return dDayLabel(end);
}
function ganttRemainDays(end) {
  if (end === null) return Infinity;
  var n = ganttDayOffset(ganttTodayYmd(), end);
  return isNaN(n) ? null : n;
}
// 비율 재료 — { num, den, extra } (num null = 값 없음). 2026-09-09 에 「진척률」 한 열을 두 열로 나눴다(사용자 결정):
//   모집률 = 승인 인플 / 모집인원 · 결과물 승인률 = 인증 성공 인플 / 승인 인플(사람 단위 — 캠페인 진행현황 진행바와 같은 정의.
//   결과물 건수 단위가 아니다 — 리뷰어형은 한 사람이 영수증+인증샷 여러 건을 내므로 건수로 세면 숫자가 크게 다르다).
function _ganttApproved(c) {
  var ac = _brandOpsApprCounts ? _brandOpsApprCounts[c.id] : null;
  return _brandOpsApprCounts === null ? null : (ac ? ac.approved : 0);   // null = 승인 수 조회 실패
}
function ganttRecruitRate(c) {
  return { label: '승인', num: _ganttApproved(c), den: Number(c.slots || 0), extra: '' };
}
function ganttCertRate(c, stats) {
  var appr = _ganttApproved(c);
  // 승인 수 조회가 실패(appr === null)했으면 분자도 비운다 — 안 그러면 「5/0」처럼 승인 0명으로 읽힌다(툴팁 건수와 같은 규약, 리뷰 지적)
  return { label: '인증 성공', num: (appr === null || !stats) ? null : stats.cert, den: appr === null ? 0 : appr, extra: '' };
}
// 펼친 기간 행 — 두 열 중 그 단계에 맞는 쪽만 채운다(모집·선정 → 모집률 칸 / 구매·방문·제출 → 결과물 칸에 그 단계 진척). 나머지 칸은 빈칸.
var GANTT_EMPTY_RATE = { label: '', num: undefined, den: 0, extra: '' };
function ganttChildRecruitRate(seg, c) {
  var n = seg.name;
  return (n === '모집' || n === '모집 마감' || n === '선정') ? ganttRecruitRate(c) : GANTT_EMPTY_RATE;
}
function ganttChildCertRate(seg, c, stats) {
  var appr = _ganttApproved(c);
  var n = seg.name;
  if (n === '구매' || n === '방문') return { label: n === '구매' ? '영수증' : '현장 사진', num: (appr === null || !stats) ? null : stats.receiptInf, den: appr === null ? 0 : appr, extra: '' };
  if (n === '제출' || n === '제출 마감') return { label: '결과물 제출', num: (appr === null || !stats) ? null : stats.submittedInf, den: appr === null ? 0 : appr, extra: stats ? ('인증 ' + stats.cert) : '' };
  return GANTT_EMPTY_RATE;
}
function ganttProgHtml(pr, pending) {
  if (pr.num === undefined) return '';                                     // 그 단계에 해당 없는 칸(자식 행) — 「—」도 안 그린다
  if (pending) return '<span style="color:var(--faint)">…</span>';
  if (pr.num === null) return '<span style="color:var(--muted)">—</span>';
  var tip = (pr.label ? pr.label + ' ' : '') + pr.num + ' / ' + pr.den + (pr.extra ? ' · ' + pr.extra : '');
  if (!(pr.den > 0)) return '<span class="gantt-prog-frac" title="' + esc(tip) + '">' + pr.num + '/' + pr.den + '</span>';
  var pct = Math.min(100, Math.round(pr.num / pr.den * 100));
  // 참고 화면처럼 막대 + 퍼센트만 크게. 분수는 작게, 무엇을 센 것인지는 툴팁에(이름표를 앞에 붙이면 숫자가 안 보인다 — 2026-09-07 사용자 지적)
  return '<div class="gantt-prog" title="' + esc(tip) + '"><div class="gantt-prog-bar"><div class="gantt-prog-fill" style="width:' + pct + '%"></div></div>'
    + '<span class="gantt-prog-pct">' + pct + '%</span><span class="gantt-prog-frac">' + pr.num + '/' + pr.den + '</span></div>';
}
// ---- 캠페인 단위 경고(2026-09-09 사용자 지시 「캠페인 경고 표시를 간트차트에도」) ----
//   브랜드 카드의 경고(get_brand_ops_overview, 148)는 **브랜드 단위**라 캠페인 행에 그대로 못 쓴다 → 화면에서 캠페인마다 다시 판정한다.
//   ⚠️ 판정 사본이다 — 임계값은 148 과 같게 두되(모집률 30/50%, 마감 7일, D-1/D-3) **취소 5건 조건은 뺐다**(캠페인별 취소 건수를
//   이 화면이 받지 않는다). 브랜드 모집률은 캠페인 합산이라 브랜드 카드와 단계가 다를 수 있다 — 툴팁에 「캠페인 단위」라고 적는다.
//   모집 경고는 모집중(active)만 — 모집 전(scheduled)은 모집률이 뜻이 없다. 결과물 경고는 모집마감(closed)만 — 제출 창은 마감 다음 날 열린다.
//   결과물 경고(사용자 결정 2026-09-09, 같은 날 두 번째 결정으로 넓힘): ①제출 마감 3일 이내인데 인증 못 한 사람이 1명이라도 있으면
//   「미인증 N명 · 제출 마감 …」(하루 전·오늘 긴급, 2~3일 대응 필요) ②제출 마감 7일 이내인데 결과물 승인률 < 50% 면 「결과물 저조」(주의).
//   운영 실측에서 승인률 55~75% 인 D-Day 캠페인이 조용했다 — 마감 직전엔 「몇 명이 못 냈나」가 「비율이 낮나」보다 급하다.
//   stats 가 없으면(집계 중·실패) 결과물 경고는 판정하지 않는다 — 없는 것을 「정상」으로 그리지 않고 그냥 비운다.
//   정상이면 null — 아무것도 안 그린다(0건 원칙).
function ganttCampaignAlert(c, stats) {
  var today = ganttTodayYmd();
  var daysTo = function(ymd) { if (!ymd) return null; var n = ganttDayOffset(today, ymd); return (isNaN(n) || n < 0) ? null : n; };   // 남은 일(오늘 0). 지난 날짜는 null
  var ac = _brandOpsApprCounts ? _brandOpsApprCounts[c.id] : null;
  var appr = _brandOpsApprCounts === null ? null : (ac ? ac.approved : 0);
  var lines = [], level = null;
  var bump = function(lv) { var r = BRAND_OPS_ALERT_RANK; if (level === null || r[lv] < r[level]) level = lv; };
  if (c.status === 'active') {
    var slots = Number(c.slots || 0);
    var pct = (appr !== null && slots > 0) ? Math.round(appr / slots * 100) : null;
    var left = daysTo(c.deadline);
    if (left !== null && left <= 1)      { lines.push(left === 0 ? '마감 오늘' : '마감 하루 전'); bump('danger'); }
    else if (left !== null && left <= 3) { lines.push('마감 ' + left + '일 남음'); bump('warning'); }
    // 모집률 숫자는 안 적는다 — 오른쪽 「모집률」 열에 있다(2026-09-09 사용자 지시). 임계값(30/50%)만 문구로 갈린다
    if (pct !== null && pct < 30 && left !== null && left < 7) { lines.push('모집 저조' + (left > 1 ? ' · 마감 ' + left + '일 남음' : '')); bump('danger'); }
    else if (pct !== null && pct < 50 && (left === null || left >= 7)) { lines.push('모집 저조'); bump('caution'); }
  } else if (c.status === 'closed' && stats && appr !== null && appr > 0) {
    var leftS = daysTo(c.submission_end);
    var cert = Math.min(appr, stats.cert || 0), uncert = appr - cert;
    var certPct = Math.round(cert / appr * 100);
    var leftTxt = leftS === 0 ? '오늘' : leftS === 1 ? '하루 전' : leftS + '일 남음';
    if (leftS !== null && leftS <= 3 && uncert > 0) {
      lines.push('미인증 ' + uncert + '명 · 제출 마감 ' + leftTxt);
      bump(leftS <= 1 ? 'danger' : 'warning');
    } else if (leftS !== null && leftS <= 7 && certPct < 50) {
      lines.push('결과물 저조 · 제출 마감 ' + leftTxt);
      bump('caution');
    }
  }
  if (!level) return null;
  return { level: level, lines: lines };
}
// 경고 꼬리표 — 캠페인 행의 막대 오른쪽 옆에 붙인다(2026-09-09 사용자 지시 「우측 막대 옆에」. 처음엔 상태 배지 아래였다).
//   위치(left)는 renderGanttTrack 이 막대 끝을 알고 정한다. 막대가 화면 밖이면 가장자리 마커 반대편에.
//   pos = { left: px } 또는 { right: px } — 오른쪽 끝 근처면 right 로 붙여 꼬리표가 시간축 밖으로 넘치지 않게(리뷰 지적).
function ganttAlertTagHtml(a, pos) {
  if (!a) return '';
  var st = BRAND_OPS_ALERT[a.level];
  var tip = '캠페인 단위 경고(' + st.label + ') · ' + a.lines.join(' / ') + '\n브랜드 카드의 경고는 브랜드 합산 기준이라 단계가 다를 수 있습니다';
  pos = pos || { right: 4 };
  pos = (pos.left !== undefined) ? 'left:' + pos.left + 'px' : 'right:' + pos.right + 'px';
  return '<span class="gantt-alert-tag" style="color:' + st.color + ';' + pos + '" data-tip="' + esc(tip) + '">'
    + '<span class="material-icons-round notranslate" translate="no">warning</span>' + esc(a.lines.join(' · ')) + '</span>';
}

var GANTT_QUICK_CHIPS = [
  { code: 'alert',       label: '경고 있음',     needStats: false },
  { code: 'deadline7',   label: '마감 7일 이내', needStats: false },
  { code: 'submitShort', label: '제출 미달',     needStats: true },
  { code: 'certShort',   label: '인증 미달',     needStats: true },
];
function ganttQuickNeedsStats(code) { var d = GANTT_QUICK_CHIPS.find(function(x){ return x.code === code; }); return !!(d && d.needStats); }

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

// 보기 전환 드롭다운(#brandOpsViewSelect, 제목 줄 오른쪽 「새로고침」 옆) — 2026-09-09 에 상단 탭에서 바꿨다. 이름은 호출처 3곳이 그대로 부르므로 유지.
function renderBrandOpsViewTabs() {
  var sel = $('brandOpsViewSelect');
  if (!sel) return;
  // 항목 표기는 「보기: 간트」·「보기: 브랜드」(사용자 지시 형식). 건수는 안 붙인다 — 일정 뷰는 오른쪽 「(N / 대상 N)」 이 이미 센다
  var tabs = [
    { code: 'schedule', label: '간트' },
    { code: 'cards',    label: '브랜드' },
  ];
  sel.innerHTML = tabs.map(function(t){
    return '<option value="' + t.code + '"' + (t.code === _brandOpsView ? ' selected' : '') + '>보기: ' + t.label + '</option>';
  }).join('');
  sel.value = _brandOpsView;
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
// 빠른 필터 칩은 여기서 걸지 않는다 — 칩의 건수를 이 결과로 세야 하므로 본체(renderBrandOpsSchedule)가 그 뒤에 건다
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
function ganttShiftDays() { return GANTT_ZOOMS[_ganttZoom].shiftWeeks * 7; }
// 그린 범위 기본값 — 보이는 창 양쪽에 이동폭 두 번씩 여유(일 12주 창이면 8주 + 12주 + 8주 = 약 2,000px)
function ganttResetExt() {
  var pad = ganttShiftDays() * 2;
  _ganttExt = { before: GANTT_RANGE.before + pad, after: GANTT_RANGE.after + pad };
}
// 「기준일 - before」가 왼쪽 끝에 오는 scrollLeft(왼쪽 고정 열은 sticky 라 스크롤 폭에 포함되지만 화면에서는 늘 앞에 붙어 있다)
function ganttDefaultScrollLeft() { return (_ganttExt.before - GANTT_RANGE.before) * GANTT_DAY_PX; }
function ganttRange() {
  if (!_ganttExt) ganttResetExt();
  var base = _ganttBaseYmd || ganttTodayYmd();
  var start = ganttAddDays(base, -_ganttExt.before), end = ganttAddDays(base, _ganttExt.after);
  var days = _ganttExt.before + _ganttExt.after + 1;
  return { base: base, start: start, end: end, days: days, width: days * GANTT_DAY_PX };
}
function ganttX(range, ymd) { return ganttDayOffset(range.start, ymd) * GANTT_DAY_PX; }
// ‹ › — 이동폭만큼 스크롤. 그린 범위를 넘어가면 먼저 그쪽을 넓힌다(넓히면서 scrollLeft 를 보정하므로 화면이 안 튄다)
function ganttShift(dir) {
  var sc = $('brandOpsGanttScroll');
  if (!sc) return;
  var px = ganttShiftDays() * GANTT_DAY_PX;
  if (dir < 0 && sc.scrollLeft - px < 0) ganttExtend('before');
  if (dir > 0 && sc.scrollLeft + sc.clientWidth + px > sc.scrollWidth) ganttExtend('after');
  ganttAnimateScroll(sc, sc.scrollLeft + dir * px);
}
// 부드러운 가로 이동 — `scrollBy({behavior:'smooth'})` 는 브라우저·설정에 따라 아예 안 움직이는 경우가 있어(2026-09-09 크롬 실측: 값이 그대로)
//   requestAnimationFrame 으로 직접 240ms 굴린다. 새 호출이 오면 앞 것을 끊는다.
//   ⚠️ 움직이는 도중 왼쪽이 넓어지면(ganttExtend 'before') 같은 날짜의 scrollLeft 가 커진다 — ganttExtend 가 from·to 를 그만큼 밀어 준다.
var _ganttAnim = null;   // { raf, from, to }
function ganttAnimateScroll(sc, to) {
  if (_ganttAnim) cancelAnimationFrame(_ganttAnim.raf);
  if (document.hidden) { sc.scrollLeft = to; _ganttAnim = null; return; }   // 숨은 탭에선 프레임이 안 돌아 영영 안 움직인다(실측) — 바로 옮긴다
  var anim = { raf: 0, from: sc.scrollLeft, to: to };
  var t0 = performance.now(), dur = 240;
  var step = function(now) {
    var k = Math.min(1, (now - t0) / dur);
    var e = 1 - Math.pow(1 - k, 3);   // ease-out
    sc.scrollLeft = anim.from + (anim.to - anim.from) * e;
    if (k < 1) anim.raf = requestAnimationFrame(step); else _ganttAnim = null;
  };
  anim.raf = requestAnimationFrame(step);
  _ganttAnim = anim;
}
function ganttToday() { _ganttBaseYmd = null; ganttResetExt(); _ganttScrollTo = 'default'; renderBrandOpsSchedule(); }
// 가장자리 확장 — 한쪽을 이동폭만큼 더 그린다. 왼쪽을 넓히면 같은 날짜가 오른쪽으로 밀리므로 scrollLeft 를 그만큼 더한다
function ganttExtend(side) {
  if (!_ganttExt || _ganttExt[side] >= GANTT_EXT_CAP_DAYS) return false;
  var sc = $('brandOpsGanttScroll');
  var step = Math.min(ganttShiftDays(), GANTT_EXT_CAP_DAYS - _ganttExt[side]);
  _ganttExt[side] += step;
  _ganttExtending = true;
  var shiftPx = side === 'before' ? step * GANTT_DAY_PX : 0;
  _ganttScrollTo = (sc ? sc.scrollLeft : 0) + shiftPx;
  if (_ganttAnim && shiftPx) { _ganttAnim.from += shiftPx; _ganttAnim.to += shiftPx; }   // 진행 중인 ‹ › 애니메이션도 같은 날짜를 가리키게
  renderBrandOpsSchedule();
  requestAnimationFrame(function(){ _ganttExtending = false; });
  return true;
}
// 스크롤이 끝에 닿으면 그쪽을 넓힌다(1회 바인딩). 세로 스크롤 이벤트도 같이 오지만 가로 위치만 본다
var _ganttScrollBound = false;
function ensureGanttScrollExtend() {
  if (_ganttScrollBound) return;
  var sc = $('brandOpsGanttScroll');
  if (!sc) return;
  _ganttScrollBound = true;
  sc.addEventListener('scroll', function(){
    if (_ganttExtending || !_ganttExt) return;
    var edge = 7 * GANTT_DAY_PX;   // 일주일 안쪽까지 오면 미리 넓힌다
    if (sc.scrollLeft <= edge) ganttExtend('before');
    else if (sc.scrollLeft + sc.clientWidth >= sc.scrollWidth - edge) ganttExtend('after');
  }, { passive: true });
}
function setGanttZoom(zoom) {
  if (!GANTT_ZOOMS[zoom]) return;
  _ganttZoom = zoom;
  GANTT_DAY_PX = GANTT_ZOOMS[zoom].px;
  GANTT_RANGE = { before: GANTT_ZOOMS[zoom].before, after: GANTT_ZOOMS[zoom].after };
  try { localStorage.setItem(GANTT_ZOOM_KEY, zoom); } catch(e) {}
  ganttResetExt(); _ganttScrollTo = 'default';   // 하루 폭이 바뀌면 옛 scrollLeft 는 뜻이 없다 — 기본 위치로
  renderBrandOpsSchedule();
}
function renderGanttZoomButtons() {
  var box = $('brandOpsZoom');
  if (!box) return;
  box.innerHTML = Object.keys(GANTT_ZOOMS).map(function(k){
    var on = k === _ganttZoom;
    return '<button type="button" class="btn btn-xs ' + (on ? 'btn-primary' : 'btn-ghost') + '" onclick="setGanttZoom(\'' + k + '\')" title="' + esc(GANTT_ZOOMS[k].label) + ' 단위로 보기" aria-pressed="' + on + '">' + esc(GANTT_ZOOMS[k].label) + '</button>';
  }).join('');
}
function toggleGanttLeft() {
  _ganttLeftCollapsed = !_ganttLeftCollapsed;
  try { localStorage.setItem(GANTT_LEFT_KEY, _ganttLeftCollapsed ? 'collapsed' : 'open'); } catch(e) {}
  applyGanttLeftState();
  // 왼쪽 열 폭이 바뀌면 오늘 세로선 위치(왼쪽 열 폭 + 날짜 x)도 바뀐다 — 다시 그린다(리뷰 지적)
  var rowsEl = $('brandOpsScheduleRows');
  if (rowsEl && _ganttCurrentRange) renderGanttTodayLine(rowsEl, _ganttCurrentRange);
}
function applyGanttLeftState() {
  var sc = $('brandOpsGanttScroll'), btn = $('brandOpsLeftToggle');
  if (sc) sc.classList.toggle('left-collapsed', _ganttLeftCollapsed);
  if (btn) {
    btn.innerHTML = ganttLeftToggleIcon();
    btn.title = ganttLeftToggleTitle();
  }
}
// 왼쪽 열 접기 단추 — 시간축 머리글의 왼쪽 고정 열 오른쪽 가장자리(구분선 위)에 붙는다(2026-09-09 사용자 지시).
//   머리글은 다시 그릴 때마다 새로 만들어지므로 그릴 때 현재 상태로 그리고, 누르면 applyGanttLeftState 가 같은 id 로 아이콘만 바꾼다.
function ganttLeftToggleIcon() {
  return '<span class="material-icons-round notranslate" translate="no">' + (_ganttLeftCollapsed ? 'keyboard_double_arrow_right' : 'keyboard_double_arrow_left') + '</span>';
}
function ganttLeftToggleTitle() { return _ganttLeftCollapsed ? '왼쪽 열 펼치기' : '왼쪽 열 접기(캠페인명·상태만 남김)'; }
function ganttLeftToggleHtml() {
  return '<button type="button" class="gantt-left-toggle" id="brandOpsLeftToggle" onclick="toggleGanttLeft()" title="' + esc(ganttLeftToggleTitle()) + '">' + ganttLeftToggleIcon() + '</button>';
}
function setGanttQuick(code) {
  _ganttQuick = (_ganttQuick === code) ? '' : (code || '');
  renderBrandOpsSchedule();
}
// 빠른 필터 판정 — 왼쪽 열·툴팁과 같은 재료. stats 가 없으면(집계 중·실패) 제출·인증 칩은 판정 불가
function ganttQuickMatch(code, c, stats) {
  if (!code) return true;
  if (code === 'alert') return !!ganttCampaignAlert(c, stats);
  if (code === 'deadline7') {
    if (GANTT_ENDED_STATUSES.indexOf(c.status) >= 0 || !c.deadline) return false;
    var t = ganttTodayYmd();
    return c.deadline >= t && c.deadline <= ganttAddDays(t, 7);
  }
  var ac = _brandOpsApprCounts ? _brandOpsApprCounts[c.id] : null;
  var appr = ac ? ac.approved : 0;
  if (!stats || appr <= 0) return false;
  if (code === 'submitShort') return stats.submittedInf < appr;
  if (code === 'certShort') return stats.cert < appr;
  return true;
}
function renderGanttQuickChips(list, st) {
  var box = $('brandOpsQuickChips');
  if (!box) return;
  var defs = GANTT_QUICK_CHIPS;
  var statsReady = st && !st.pending && st.stats !== null;
  box.innerHTML = '<span class="gantt-chip-label">빠른 필터</span>' + defs.map(function(d){
    var disabled = d.needStats && !statsReady;
    var n = disabled ? null : list.filter(function(c){ return ganttQuickMatch(d.code, c, statsReady ? st.stats[c.id] : null); }).length;
    var on = _ganttQuick === d.code;
    return '<button type="button" class="gantt-chip' + (on ? ' on' : '') + '" ' + (disabled ? 'disabled title="결과물 집계가 끝나면 쓸 수 있습니다"' : '') + ' onclick="setGanttQuick(\'' + d.code + '\')" aria-pressed="' + on + '">'
      + esc(d.label) + '<span class="tab-count">(' + (n === null ? '…' : n) + ')</span></button>';
  }).join('');
}

// ---- 시간축 머리 ----
// 격자 주기(일) — 주 폭이 35px 미만(월 단위)이면 4주마다 선을 긋고 주 이름표는 생략한다(빽빽해서 못 읽는다)
function ganttGridDays() { return (7 * GANTT_DAY_PX >= 35) ? 7 : 28; }
function ganttTrackStyle(range) {
  return 'width:' + range.width + 'px;--gantt-day:' + GANTT_DAY_PX + 'px;--gantt-grid:' + (ganttGridDays() * GANTT_DAY_PX) + 'px;--gantt-off:' + (range.gridOffset || 0) + 'px';
}
function renderGanttAxis(range) {
  var html = '';
  var firstMonday = null, weekN = 0;
  var showWeeks = ganttGridDays() === 7;
  for (var i = 0; i < range.days; i++) {
    var d = ganttAddDays(range.start, i);
    var x = i * GANTT_DAY_PX;
    if (i === 0 || d.slice(8, 10) === '01') {
      html += '<span class="gm" style="left:' + x + 'px">' + (+d.slice(5, 7)) + '월</span>';
    }
    if (_ganttWeekday(d) === 1) {
      if (firstMonday === null) firstMonday = x;
      // 월 단위에서는 4주마다 하나만(격자와 같은 자리)
      if (showWeeks || weekN % 4 === 0) html += '<span class="gw" style="left:' + x + 'px">' + (+d.slice(5, 7)) + '/' + (+d.slice(8, 10)) + '</span>';
      weekN++;
    }
  }
  var today = ganttTodayYmd();
  var tx = ganttX(range, today);
  // 「오늘」 이름표는 월 이름표 줄에 있다 — 오늘이 그달 1일이면 「9월」과 같은 자리라 글자만 생략한다(세로선은 그대로).
  if (tx >= 0 && tx < range.width && today.slice(8, 10) !== '01') html += '<span class="gt" style="left:' + (tx + GANTT_DAY_PX / 2) + 'px">오늘</span>';
  range.gridOffset = firstMonday === null ? 0 : firstMonday;
  return '<div class="gantt-axis" id="brandOpsGanttAxisTrack" style="' + ganttTrackStyle(range) + '">' + html + '</div>';
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
  // 이름이 빈 구간(부모 행의 합친 막대)은 이름 자리를 비운다 — 「 마감 …」처럼 앞이 비지 않게 trim.
  if (s.point) return (s.name + ' ' + formatDate(s.start)).trim();
  return (side === 'l' ? (s.name + ' 마감 ' + formatDate(s.end)) : (s.name + ' 시작 ' + formatDate(s.start))).trim();
}

// 막대 툴팁에 붙는 건수 한 줄 — 「신청 5명 · 승인 2/20 · 심사중 1 · 제출 1/2 · 인증 성공 0/20」.
//   왼쪽 열과 같은 값(같은 재료 — 승인 수 서버 집계, 제출·인증은 결과물 캐시). 2026-09-07 사용자 요청.
//   stats: undefined = 결과물 집계 중 / null = 조회 실패 / {submittedInf, cert}
function ganttCountsText(c, stats) {
  var slots = Number(c.slots || 0);
  var parts = [];
  var ac = _brandOpsApprCounts ? _brandOpsApprCounts[c.id] : null;
  if (_brandOpsApprCounts === null) parts.push('승인 수 조회 실패');
  else {
    var total = ac ? ac.total : 0, appr = ac ? ac.approved : 0, pend = ac ? ac.pending : 0;
    parts.push('신청 ' + total + '명', '승인 ' + appr + '/' + slots);
    if (pend > 0) parts.push('심사중 ' + pend);
  }
  if (stats === undefined) parts.push('결과물 집계 중');
  else if (stats === null) parts.push('결과물 조회 실패');
  else {
    // 「제출」은 왼쪽 열과 같은 조건(승인 수를 알고 1 이상일 때)에서만 — 열은 「—」인데 툴팁만 숫자가 뜨면 안 된다(리뷰 지적)
    var apprN = ac ? ac.approved : 0;
    if (_brandOpsApprCounts !== null && apprN > 0) parts.push('제출 ' + stats.submittedInf + '/' + apprN);
    parts.push('인증 성공 ' + stats.cert + '/' + slots);
  }
  return parts.join(' · ');
}

// 시간축 칸(설계 4 「범위 밖 처리」 + 설계 5 막대). counts = 툴팁에 붙일 건수 문장
// only: 자식 행 — 그 구간 하나만(주 막대 높이로) 그린다
// alert — 캠페인 행의 경고(ganttCampaignAlert 결과). 막대 오른쪽 옆에 꼬리표로 붙인다. 자식 행은 안 넘긴다.
function renderGanttTrack(c, range, counts, only, alert) {
  var segs = (only === undefined) ? ganttSegmentsFor(c) : (only ? [Object.assign({}, only, { lane: 'main' })] : []);
  var style = ganttTrackStyle(range);
  var html = '';
  if (!segs.length) return '<div class="gantt-track" style="' + style + '">' + html + '<span class="gantt-nodate">날짜 없음</span>' + ganttAlertTagHtml(alert, { right: 4 }) + '</div>';
  var visible = segs.filter(function(s){ return _ganttSegOverlaps(s, range); });
  if (!visible.length) {
    var before = segs.filter(function(s){ return s.end !== null && s.end < range.start; }).sort(function(a, b){ return a.end < b.end ? 1 : -1; })[0];
    var after  = segs.filter(function(s){ return s.start > range.end; }).sort(function(a, b){ return a.start < b.start ? -1 : 1; })[0];
    var edgeTip = counts ? ' data-tip="' + esc(counts) + '"' : '';
    if (before) html += '<span class="gantt-edge l"' + edgeTip + '>◀ ' + esc(_ganttSegLabel(before, 'l')) + '</span>';
    if (after)  html += '<span class="gantt-edge r"' + edgeTip + '>' + esc(_ganttSegLabel(after, 'r')) + ' ▶</span>';
    // 막대가 화면 밖 — 마커 반대편(과거 마커면 오른쪽 끝, 미래 마커면 왼쪽 4px)
    html += ganttAlertTagHtml(alert, after ? { left: 4 } : { right: 4 });
    return '<div class="gantt-track" style="' + style + '">' + html + '</div>';
  }
  var subIdx = 0, lastRight = 0;
  visible.forEach(function(s){
    var x0 = ganttX(range, s.start);
    var x1 = s.end === null ? range.width : ganttX(range, s.end) + GANTT_DAY_PX;
    var clipL = x0 < 0, clipR = x1 > range.width;
    var left = Math.max(0, x0), right = Math.min(range.width, x1);
    var period = s.end === null ? (formatDate(s.start) + ' ~ (마감 없음)') : (formatDate(s.start) + ' ~ ' + formatDate(s.end));
    var tip = (s.name ? s.name + ' ' : '') + period + (s.note ? ' · ' + s.note : '') + (counts ? '\n' + counts : '');
    var isSub = s.lane === 'sub';
    var laneCls = isSub ? (' lane-sub' + (subIdx++ ? '2' : '')) : '';
    var width = Math.max(2, right - left);
    if (s.lane === 'main') lastRight = Math.max(lastRight, s.point ? left + 14 : right);
    if (s.point) {
      html += '<span class="gantt-point" role="img" aria-label="' + esc(tip) + '" data-tip="' + esc(tip) + '" style="left:' + left + 'px"></span>';
    } else {
      // 구간 이름을 막대 안에 쓴다 — 농도만으로는 무엇이 무엇인지 안 보인다(2026-09-07 사용자 지적).
      //   주 막대는 안에(폭이 글자보다 넓을 때만), 보조 막대는 얇아서 막대 오른쪽 끝 옆에 작은 글씨로.
      var inLabel = (!isSub && s.name && width >= 30) ? '<span class="gantt-bar-label">' + esc(s.name) + '</span>' : '';
      html += '<div class="gantt-bar ink-' + s.ink + laneCls + (clipL ? ' clip-l' : '') + (clipR ? ' clip-r' : '') + (s.openEnd ? ' open-end' : '')
        + '" role="img" aria-label="' + esc(tip) + '" data-tip="' + esc(tip) + '" style="left:' + left + 'px;width:' + width + 'px">' + inLabel + '</div>';
      if (isSub && !clipR) html += '<span class="gantt-sub-label' + (laneCls.indexOf('sub2') >= 0 ? ' sub2' : '') + '" style="left:' + (right + 3) + 'px">' + esc(s.name) + '</span>';
      if (s.openEnd && s.lane === 'main') html += '<span class="gantt-tag" style="right:4px">마감 없음</span>';
    }
    // D-day 배지 — 마감(deadline)·제출 마감에만, 그 날짜가 범위 안일 때. 막대 색은 안 바꾼다(결정 11).
    if ((!only || s.showDday) && s.dday && s.lane === 'main' && !clipR && ganttX(range, s.dday) >= 0 && ganttX(range, s.dday) < range.width) {   // 부모 행의 합친 막대에는 안 붙인다(dday 없음) — 펼친 자식 행에만(2026-09-09)
      html += '<span class="gantt-dday" style="left:' + Math.min(right + 2, range.width - 44) + 'px">' + dDayLabel(s.dday) + '</span>';
    }
  });
  // 경고 꼬리표 — 막대 끝 + 4px. 막대가 오른쪽 끝 가까이(잘렸거나 무기한)면 right 로 붙인다 — 폭을 모르는 글자가 시간축 밖으로 넘치지 않게.
  //   무기한 막대는 「마감 없음」 태그가 right:4px 를 차지하므로 그 왼쪽(right:72px)에.
  if (alert) {
    var openMain = visible.some(function(s){ return s.openEnd && s.lane === 'main'; });
    var nearEdge = openMain || lastRight + 4 > range.width - 180;
    html += ganttAlertTagHtml(alert, nearEdge ? { right: openMain ? 72 : 4 } : { left: lastRight + 4 });
  }
  return '<div class="gantt-track" style="' + style + '">' + html + '</div>';
}

// ---- 왼쪽 열 + 숫자 3종 ----
function _ganttNum(n) { return (n === null || n === undefined) ? '<span style="color:var(--muted)">—</span>' : String(n); }
function renderScheduleRow(c, range, stats) {
  var title = c.title || '(제목 없음)';
  var typeKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined' && RECRUIT_TYPE_LABEL_KO[c.recruit_type]) || BRAND_OPS_RECRUIT_TYPE_KO[c.recruit_type] || c.recruit_type || '';
  var st = BRAND_OPS_CAMP_STATUS_COLOR[c.status] || { bg: '#F5F5F5', color: '#757575' };
  var pending = stats === undefined;
  var idJs = esc(String(c.id));
  var segs = ganttSegmentsFor(c);
  var span = ganttSpanOf(segs);
  var open = !!_ganttOpen[c.id];
  var counts = ganttCountsText(c, stats);
  var subLine = [brandLabelAdmin(c), typeKo, brandOpsChannelText(c.channel, c.channel_match)].filter(Boolean).join(' · ');
  var html = '<div class="gantt-row parent' + (open ? ' open' : '') + '">'
    + '<div class="gantt-left">'
    +   '<div class="gantt-cell c-title">'
    +     '<div class="gantt-title-row">'   // 접기 단추 · 썸네일 · (이름 + 부제) 가로 배치. 자식 행 들여쓰기(.gantt-row.child .c-title)가 이 폭에 맞춰져 있다
    +       '<button type="button" class="gantt-chev" onclick="toggleGanttRow(\'' + idJs + '\')" title="' + (open ? '기간 접기' : '기간 펼치기') + '" aria-expanded="' + open + '"' + (segs.length ? '' : ' disabled') + '><span class="material-icons-round notranslate" translate="no">' + (open ? 'expand_more' : 'chevron_right') + '</span></button>'
    +       brandOpsCampThumb(c, 32)
    +       '<div class="gantt-title-text">'
    +         '<div class="gantt-title-line">'
    +           '<a href="#" class="camp-link ellip" title="' + esc(title) + '" data-camp-title="' + esc(title) + '" onclick="openCampApplicants(\'' + idJs + '\', this.dataset.campTitle, \'brand-ops-schedule\');return false">' + esc(title) + '</a>'
    +         '</div>'
    +         '<div class="sub ellip" title="' + esc(subLine) + '">' + esc(c.campaign_no || '') + (subLine ? ' · ' + esc(subLine) : '') + '</div>'
    +       '</div>'
    +     '</div>'
    +   '</div>'
    +   '<div class="gantt-cell c-status"><span style="display:inline-block;font-size:10px;font-weight:600;padding:2px 7px;border-radius:6px;background:' + st.bg + ';color:' + st.color + '">' + esc(BRAND_OPS_CAMP_STATUS_KO[c.status] || c.status || '') + '</span></div>'
    +   '<div class="gantt-cell c-dur">' + (span ? ganttRemainHtml(span.end) : '<span style="color:var(--muted)">—</span>') + '</div>'
    +   '<div class="gantt-cell c-rate">' + ganttProgHtml(ganttRecruitRate(c), false) + '</div>'
    +   '<div class="gantt-cell c-rate">' + ganttProgHtml(ganttCertRate(c, stats), pending) + '</div>'
    + '</div>'
    + renderGanttTrack(c, range, counts, ganttMergedSegment(segs), ganttCampaignAlert(c, stats))   // 부모 = 전체 일정 막대 하나(기간이 없으면 null → 「날짜 없음」) + 막대 옆 경고 꼬리표
    + '</div>';
  if (!open) return html;
  // 자식 행 — 캠페인에 설정된 기간마다 한 줄(흐름 순서: 모집 → 구매·방문 → 선정 → 제출). 이름·날짜·일수·진척률 + 그 구간 막대 하나
  ganttSegsInFlowOrder(segs).forEach(function(seg){
    var period = seg.end === null ? (formatDate(seg.start) + ' ~ 마감 없음') : (formatDate(seg.start) + ' ~ ' + formatDate(seg.end));
    html += '<div class="gantt-row child">'
      + '<div class="gantt-left">'
      +   '<div class="gantt-cell c-title"><div class="gantt-title-line"><span class="gantt-child-name">' + esc(seg.name) + '</span><span class="gantt-child-date">' + esc(period) + '</span></div></div>'
      +   '<div class="gantt-cell c-status"></div>'
      +   '<div class="gantt-cell c-dur">' + ganttRemainHtml(seg.end) + '</div>'
      +   '<div class="gantt-cell c-rate">' + ganttProgHtml(ganttChildRecruitRate(seg, c), false) + '</div>'
      +   '<div class="gantt-cell c-rate">' + ganttProgHtml(ganttChildCertRate(seg, c, stats), pending) + '</div>'
      + '</div>'
      + renderGanttTrack(c, range, counts, Object.assign({}, seg, { showDday: true }))   // D-day 배지는 자식 행에(모집·제출만 dday 를 가진다)
      + '</div>';
  });
  return html;
}

// 범례 — 막대 모양이 무엇을 뜻하는지. 시간축 머리 위 한 줄(일정 뷰에서만 보인다).
function renderGanttLegend() {
  return '<span class="gantt-legend-item"><i class="gantt-bar ink-strong lg"></i>모집</span>'
    + '<span class="gantt-legend-item"><i class="gantt-bar ink-weak lg"></i>제출(결과물)</span>'
    + '<span class="gantt-legend-item"><i class="gantt-bar ink-mid lg lg-sub"></i>구매 · 방문 · 선정(얇은 줄)</span>'
    + '<span class="gantt-legend-item"><i class="gantt-point lg"></i>날짜 하나(마감만 있는 경우)</span>'
    + '<span class="gantt-legend-item"><i class="gantt-today lg"></i>오늘</span>';
}

function renderScheduleHead(range) {
  return '<div class="gantt-left">'
    + '<div class="gantt-cell c-title">캠페인 ' + ganttSortArrows('title') + '</div><div class="gantt-cell c-status" title="막대 옆 경고 꼬리표 = 캠페인 단위. 모집중: 마감 하루 전·3일 이내, 모집률 30% 미만+마감 7일 이내, 모집률 50% 미만 / 모집마감: 제출 마감 3일 이내+인증 못 한 사람 있음(미인증 N명), 제출 마감 7일 이내+결과물 승인률 50% 미만. 브랜드 카드 경고와 단계가 다를 수 있다">상태 ' + ganttSortArrows('status') + '</div>'
    + '<div class="gantt-cell c-dur" title="캠페인 행 = 가장 늦은 마감까지 · 펼친 기간 행 = 그 기간의 마감까지">남은 기간 ' + ganttSortArrows('dur') + '</div>'
    + '<div class="gantt-cell c-rate" title="승인 인플루언서 / 모집인원. 기프팅·방문형은 초과 응모를 받아 100%를 넘을 수 있다">모집률 ' + ganttSortArrows('recruit') + '</div>'
    + '<div class="gantt-cell c-rate" title="캠페인 행 = 인증 성공 인플루언서 / 승인 인플루언서 · 펼친 기간 행 = 그 단계(구매·방문 = 영수증(현장 사진) 낸 인플루언서/승인, 제출 = 결과물 낸 인플루언서/승인)">결과물 승인률 ' + ganttSortArrows('cert') + '</div>'
    + ganttLeftToggleHtml()
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
    var infs = {}, rcpt = {};
    ds.forEach(function(d){ if (d.user_id) { infs[d.user_id] = 1; if (d.kind === 'receipt') rcpt[d.user_id] = 1; } });
    // countCertSuccess 는 검수 화면·미니카드와 같은 판정(buildDeliverableGroups → computeCertStatus).
    //   camp 는 fetchCampaigns() 가 준 실제 행이다(가구매·채널 판정 포함). 결과물 행에 임베드된
    //   campaigns 가 있으면 그쪽이 우선 쓰이는데, 판정에 필요한 값이 전부 있어 결과가 같다.
    // receiptInf = 영수증(방문형은 현장 사진, 같은 kind='receipt')을 낸 인플 — 구매·방문 기간 행의 진척률
    stats[c.id] = { submittedInf: Object.keys(infs).length, receiptInf: Object.keys(rcpt).length, cert: (typeof countCertSuccess === 'function') ? countCertSuccess(ds, c) : null };
  });
  return { pending: false, stats: stats };
}

// ---- 즉시 툴팁 ----
// 브라우저 기본 title 은 1초쯤 지나야 뜬다(바꿀 수 없다) → 마우스를 올리는 즉시 보이는 자체 툴팁(2026-09-07 사용자 요청).
//   막대·점·가장자리 마커에 data-tip 을 두고, 행 컨테이너 하나에 위임해 듣는다(행이 다시 그려져도 처리기는 그대로).
var _ganttTipBound = false;
function ensureGanttTipHandlers() {
  if (_ganttTipBound) return;
  var rows = $('brandOpsScheduleRows');
  if (!rows) return;
  _ganttTipBound = true;
  var tipEl = document.createElement('div');
  tipEl.className = 'gantt-tip';
  tipEl.hidden = true;
  document.body.appendChild(tipEl);
  var place = function(e) {
    var pad = 14, w = tipEl.offsetWidth, h = tipEl.offsetHeight;
    var x = e.clientX + pad, y = e.clientY + pad;
    if (x + w > window.innerWidth - 8) x = e.clientX - w - pad;    // 오른쪽 끝에서는 왼쪽으로
    if (y + h > window.innerHeight - 8) y = e.clientY - h - pad;   // 아래 끝에서는 위로
    tipEl.style.left = Math.max(4, x) + 'px';
    tipEl.style.top = Math.max(4, y) + 'px';
  };
  rows.addEventListener('mouseover', function(e) {
    var t = e.target.closest ? e.target.closest('[data-tip]') : null;
    if (!t || !rows.contains(t)) return;
    tipEl.textContent = t.getAttribute('data-tip') || '';
    tipEl.hidden = false;
    place(e);
  });
  rows.addEventListener('mousemove', function(e) { if (!tipEl.hidden) place(e); });
  rows.addEventListener('mouseout', function(e) {
    var t = e.target.closest ? e.target.closest('[data-tip]') : null;
    if (!t) return;
    var to = e.relatedTarget;
    if (to && t.contains(to)) return;                              // 같은 요소 안에서 움직인 것
    tipEl.hidden = true;
  });
  // 세로 스크롤·페인 전환으로 요소가 사라지면 남지 않게
  document.addEventListener('scroll', function(){ tipEl.hidden = true; }, true);
}

// 마우스를 따라오는 날짜 안내선 — 막대가 없는 빈칸에서도 「이 자리가 며칠인가」를 바로 안다(Linear 방식). 툴팁과 별개로 1회 바인딩
var _ganttGuideBound = false;
function ensureGanttGuideHandlers() {
  if (_ganttGuideBound) return;
  var sc = $('brandOpsGanttScroll');
  if (!sc) return;
  _ganttGuideBound = true;
  var guide = document.createElement('div');
  guide.className = 'gantt-guide';
  guide.hidden = true;
  guide.innerHTML = '<span class="gantt-guide-date"></span>';
  document.body.appendChild(guide);
  var WD = ['일', '월', '화', '수', '목', '금', '토'];
  var moveGuide = function(e) {
    var range = _ganttCurrentRange, axis = $('brandOpsGanttAxisTrack');
    if (!range || !axis || !sc) { guide.hidden = true; return; }
    var ar = axis.getBoundingClientRect(), sr = sc.getBoundingClientRect();
    // 왼쪽 고정 열은 sticky 라 가로 스크롤하면 시간축이 그 **뒤로** 들어간다 — 시간축 좌표(idx)만 보면 왼쪽 열 위에서도 날짜가 잡힌다
    //   (운영 실측 2026-09-09: 캠페인 이름 위에 「6/24(수)」). 고정 열의 오른쪽 가장자리 왼쪽이면 숨긴다.
    var leftCol = sc.querySelector('.gantt-head .gantt-left');
    var leftEdge = leftCol ? leftCol.getBoundingClientRect().right : ar.left;
    var idx = Math.floor((e.clientX - ar.left) / GANTT_DAY_PX);
    if (idx < 0 || idx >= range.days || e.clientX < leftEdge || e.clientX > sr.right - 12) { guide.hidden = true; return; }   // 왼쪽 열·스크롤바 위에서는 숨김
    var d = ganttAddDays(range.start, idx);
    guide.style.left = (ar.left + idx * GANTT_DAY_PX) + 'px';
    guide.style.width = GANTT_DAY_PX + 'px';
    guide.style.top = sr.top + 'px';
    guide.style.height = Math.min(sr.height, window.innerHeight - sr.top) + 'px';
    guide.firstChild.textContent = (+d.slice(5, 7)) + '/' + (+d.slice(8, 10)) + '(' + WD[_ganttWeekday(d)] + ')';
    guide.hidden = false;
  };
  sc.addEventListener('mousemove', moveGuide);
  sc.addEventListener('mouseleave', function(){ guide.hidden = true; });
  document.addEventListener('scroll', function(){ guide.hidden = true; }, true);
}

// 렌더 뒤 가로 스크롤 위치 — 'default'(오늘·줌 전환·첫 그리기)면 기본 위치, 숫자면 그 값(가장자리 확장 보정), null 이면 그대로 둔다.
//   첫 그리기는 scrollLeft 가 0 이라 가장자리 확장이 바로 걸리므로 반드시 기본 위치로 옮긴다. 시간축 머리글(axis)만 그려져도 폭이 확정된다.
var _ganttFirstRender = true;
function ganttApplyScrollLeft() {
  var sc = $('brandOpsGanttScroll');
  if (!sc) return;
  var to = _ganttScrollTo;
  if (_ganttFirstRender) { to = 'default'; _ganttFirstRender = false; }
  _ganttScrollTo = null;
  if (to === null) return;
  sc.scrollLeft = (to === 'default') ? ganttDefaultScrollLeft() : to;
}

// 간트 상자 높이를 화면에 맞춘다 — 시간축 머리글이 세로 스크롤 때도 붙어 있으려면 세로 스크롤을 이 상자가 맡아야 한다.
//   (그 전에는 바깥 페인이 스크롤해 10행쯤 내려가면 월·주 눈금이 사라졌다 — 2026-09-07 조사 지적)
function fitGanttHeight() {
  var sc = $('brandOpsGanttScroll');
  if (!sc || sc.offsetParent === null) return;
  var top = sc.getBoundingClientRect().top;
  sc.style.maxHeight = Math.max(240, window.innerHeight - top - 28) + 'px';
}
window.addEventListener('resize', function(){ if (_brandOpsView === 'schedule') fitGanttHeight(); });

// 오늘 세로선 — 행마다 그리면 행 구분선 자리에서 끊겨 보인다(사용자 지적) → 행 컨테이너 위에 하나만 겹쳐 그린다.
//   왼쪽 고정 열 뒤로는 안 보이게 z-index 를 왼쪽 열(2)보다 낮춘다. 왼쪽 열 폭은 그려진 첫 행에서 잰다(접기 상태 반영).
function renderGanttTodayLine(rowsEl, range) {
  rowsEl.querySelectorAll(':scope > .gantt-today').forEach(function(el){ el.remove(); });   // 다시 그릴 때 옛 선을 지운다
  var tx = ganttX(range, ganttTodayYmd());
  if (!(tx >= 0 && tx < range.width)) return;
  var left = rowsEl.querySelector('.gantt-left');
  var leftW = left ? left.offsetWidth : 0;
  rowsEl.insertAdjacentHTML('beforeend', '<div class="gantt-today" style="left:' + (leftW + tx + GANTT_DAY_PX / 2) + 'px"></div>');
}

// ---- 일정 뷰 본체 ----
function renderBrandOpsSchedule() {
  var rowsEl = $('brandOpsScheduleRows'), axisEl = $('brandOpsAxis'), note = $('brandOpsScheduleNote');
  if (!rowsEl || !axisEl) return;
  var count = $('brandOpsTotalCount');
  var target = brandOpsScheduleTargetCampaigns();
  // 빠른 필터는 결과물 통계가 있어야 판정된다 — 통계를 먼저 만들고(대상 집합 전체) 그다음 필터를 건다
  var preList = brandOpsScheduleCampaigns();
  var stPre = _scheduleStatsFor(target);
  var quickStats = (!stPre.pending && stPre.stats !== null) ? stPre.stats : null;
  // 통계가 없어졌으면(새로고침·종료 포함 전환) 통계에 기대는 칩만 내린다 — 「마감 7일 이내」는 그대로(리뷰 지적)
  if (_ganttQuick && ganttQuickNeedsStats(_ganttQuick) && !quickStats) _ganttQuick = '';
  renderGanttQuickChips(preList, stPre);
  var list = _ganttQuick ? preList.filter(function(c){ return ganttQuickMatch(_ganttQuick, c, quickStats ? quickStats[c.id] : null); }) : preList;   // quickStats 는 집계 전·실패면 null — 통계 없이도 되는 칩(경고 있음·마감 7일)이 켜진 채 새로고침하면 여기서 죽었다(리뷰 지적)
  list = ganttSortList(list, quickStats);   // 머리글 정렬(없으면 기본 마감 순 그대로)
  if (count) count.textContent = '(' + list.length + ' / 대상 ' + target.length + ')';
  ensureGanttTipHandlers();
  ensureGanttGuideHandlers();
  ensureGanttScrollExtend();
  renderGanttZoomButtons();
  renderGanttOpenButton(list);
  applyGanttLeftState();
  var range = ganttRange();
  var legend = $('brandOpsGanttLegend');
  if (legend) legend.innerHTML = renderGanttLegend();
  axisEl.innerHTML = renderScheduleHead(range);
  _ganttCurrentRange = range;
  fitGanttHeight();
  ganttApplyScrollLeft();
  if (typeof _campaignsLoadFailed !== 'undefined' && _campaignsLoadFailed) {
    rowsEl.innerHTML = '<div class="gantt-empty">캠페인을 불러오지 못했습니다 · 새로고침을 눌러 다시 시도해 주세요</div>';
    if (note) note.hidden = true;
    return;
  }
  if (!list.length) {
    rowsEl.innerHTML = '<div class="gantt-empty">조건에 맞는 캠페인이 없습니다' + (_ganttQuick ? '<div style="font-size:11px;margin-top:6px">빠른 필터를 다시 눌러 끄면 전체가 보입니다</div>' : (_brandOpsIncludeEnded ? '' : '<div style="font-size:11px;margin-top:6px">종료된 캠페인은 「종료 포함」을 켜면 보입니다</div>')) + '</div>';
    if (note) note.hidden = true;
    return;
  }
  var st = stPre;
  if (note) {
    if (st.stats === null) { note.textContent = '결과물을 불러오지 못해 제출·인증 칸을 비웠습니다. 새로고침을 눌러 다시 시도해 주세요'; note.hidden = false; }
    else note.hidden = true;
  }
  rowsEl.innerHTML = list.map(function(c){
    var s = st.pending ? undefined : (st.stats === null ? null : st.stats[c.id]);
    return renderScheduleRow(c, range, s);
  }).join('');
  renderGanttTodayLine(rowsEl, range);
  if (st.pending) loadScheduleDeliverables();
}
