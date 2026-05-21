// ════════════════════════════════════════════════════════════════════
// SECTION: BRAND OPS — 운영 현황 페인 (브랜드 운영 재설계 PR 3)
//   브랜드별 진행 상황을 카드 그리드로. alert_level 4단계로 경고 강조.
//   데이터: get_brand_ops_overview RPC (마이그레이션 120, 19컬럼).
//   임계값 계산은 전부 서버(RPC)에서 끝나 클라이언트는 색·라벨만 매핑.
//   PR 4 의 브랜드 상세 페인(adminPane-brand-ops-detail)으로 진입.
// ════════════════════════════════════════════════════════════════════

var _brandOpsCache = [];      // get_brand_ops_overview 전체 행
var _brandOpsCompanies = [];  // 회사 드롭다운용

// 브랜드 상세 진입 — PR 4 에서 brand-ops-detail 페인으로 교체 예정
function openBrandOpsDetail(brandId) {
  toast('브랜드 상세 화면은 준비 중입니다 (다음 단계)');
}

// alert_level → 색·라벨 매핑 (관리자 UI 한국어)
var BRAND_OPS_ALERT = {
  danger:  { color: '#dc2626', bg: '#FDECEA', label: '긴급',     pulse: true },
  warning: { color: '#f97316', bg: '#FFF3E8', label: '대응 필요', pulse: false },
  caution: { color: '#f59e0b', bg: '#FEF9E7', label: '주의',     pulse: false },
  normal:  { color: '#cbd5e1', bg: '#fff',    label: '',         pulse: false }
};
// 정렬 시 경고 우선순위
var BRAND_OPS_ALERT_RANK = { danger: 0, warning: 1, caution: 2, normal: 3 };

async function loadBrandOps() {
  var grid = $('brandOpsGrid');
  if (grid) grid.innerHTML = '<div style="grid-column:1/-1;text-align:center;color:var(--muted);padding:40px"><span class="spinner" style="width:22px;height:22px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></div>';
  // 회사 드롭다운(전체/회사별/미분류) — 최초 1회 또는 매 로드 시 갱신
  _brandOpsCompanies = await fetchCompanies({ status: 'all' });
  fillBrandOpsCompanyFilter();
  // 전체 브랜드 집계를 받아 클라이언트에서 회사/미분류 필터링
  _brandOpsCache = await getBrandOpsOverview(null);
  renderBrandOpsCards();
  // 최근 신청 — 대시보드에서 이관 (renderRecentAppsTable 는 admin.js)
  loadBrandOpsRecentApps();
}

// 최근 신청 테이블 채우기 (대시보드 loadAdminData 에서 이관)
async function loadBrandOpsRecentApps() {
  if (typeof renderRecentAppsTable !== 'function') return;
  var results = await Promise.all([fetchCampaigns(), fetchInfluencers(), fetchApplications()]);
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
    + '<div style="height:6px;background:#eef0f3;border-radius:4px;overflow:hidden"><div style="height:100%;width:' + pct + '%;background:' + (pct >= 50 ? '#16a34a' : pct >= 30 ? '#f59e0b' : '#dc2626') + '"></div></div>'
    + '</div>';
}

function renderBrandOpsCard(b) {
  var alert = BRAND_OPS_ALERT[b.alert_level] || BRAND_OPS_ALERT.normal;
  var badge = alert.label
    ? '<span style="background:' + alert.bg + ';color:' + alert.color + ';font-size:10px;font-weight:700;padding:2px 8px;border-radius:10px' + (alert.pulse ? ';animation:brandOpsPulse 1.2s ease-in-out infinite' : '') + '">' + esc(alert.label) + '</span>'
    : '';

  // 경고 라인 (D-3 임박 / 7일 취소)
  var warns = [];
  if ((b.d3_count||0) > 0) warns.push('마감 임박 ' + b.d3_count + '건');
  if ((b.cancel_7d||0) > 0) warns.push('7일 취소 ' + b.cancel_7d + '건');
  var warnLine = warns.length
    ? '<div style="margin-top:6px;font-size:11px;color:' + alert.color + ';display:flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">warning</span>' + esc(warns.join(' · ')) + '</div>'
    : '';

  return '<div class="brand-ops-card" style="border-left:4px solid ' + alert.color + '" onclick="openBrandOpsDetail(\'' + esc(b.brand_id) + '\')">'
    + '<div style="display:flex;justify-content:space-between;align-items:flex-start;gap:8px">'
      + '<div style="min-width:0">'
        + '<div style="font-size:11px;color:var(--muted)">' + esc(b.company_name_ko || '미분류') + ' · ' + esc(b.brand_no || '—') + '</div>'
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
    + warnLine
    + '<div style="display:flex;justify-content:space-between;align-items:center;margin-top:10px;padding-top:8px;border-top:1px solid var(--line)">'
      + '<span style="font-size:10px;color:var(--muted)">최근 활동 ' + (b.last_activity_at ? fmtDate(b.last_activity_at) : '—') + '</span>'
      + '<span style="font-size:11px;color:var(--pink);font-weight:600">상세 보기 →</span>'
    + '</div>'
    + '</div>';
}
