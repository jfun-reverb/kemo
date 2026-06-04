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
  danger:  { color: '#dc2626', bg: '#FDECEA', label: '긴급',     pulse: true },
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

async function loadBrandOpsDetail() {
  var body = $('brandOpsDetailBody');
  if (!_brandOpsDetailId) {
    if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px">운영 현황에서 브랜드를 선택하세요</div>';
    return;
  }
  if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px"><span class="spinner" style="width:22px;height:22px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></div>';

  var results = await Promise.all([getBrandOpsDetail(_brandOpsDetailId), fetchApplications()]);
  var detail = results[0];
  var apps = results[1] || [];
  _brandOpsDetailData = detail;
  if (!detail || !detail.brand) {
    if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:48px">브랜드 정보를 불러올 수 없습니다</div>';
    return;
  }
  // 캠페인별 승인 수 집계 (인플루언서 응모 = applications, status approved)
  _brandOpsApprByCamp = {};
  apps.forEach(function(a){
    if (a.status === 'approved') _brandOpsApprByCamp[a.campaign_id] = (_brandOpsApprByCamp[a.campaign_id] || 0) + 1;
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
  expired:   { bg: '#FAFAFA', color: '#9E9E9E' }
};
// 캠페인 모집 타입 한글 (admin.js 의 RECRUIT_TYPE_LABEL_KO 폴백)
var BRAND_OPS_RECRUIT_TYPE_KO = { monitor: '리뷰어', gifting: '기프팅', visit: '방문형' };

// M/D 짧은 날짜
function brandOpsShortDate(d) {
  if (!d) return '';
  var dt = new Date(d);
  if (isNaN(dt)) return '';
  return (dt.getMonth() + 1) + '/' + dt.getDate();
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
    ? '<img src="' + esc(imgThumb(c.img1, 128)) + '" data-orig="' + esc(c.img1) + '" onerror="this.onerror=null;this.src=this.dataset.orig" alt="" style="width:56px;height:56px;border-radius:8px;object-fit:cover;flex-shrink:0;background:#f0f0f0">'
    : '<div style="width:56px;height:56px;border-radius:8px;flex-shrink:0;background:#f0f0f0;display:flex;align-items:center;justify-content:center"><span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:#bbb">image</span></div>';
}

// 미니카드 상단: 모집 타입 + 채널
function brandOpsCampTypeChannel(c) {
  var typeKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined' && RECRUIT_TYPE_LABEL_KO[c.recruit_type]) || BRAND_OPS_RECRUIT_TYPE_KO[c.recruit_type] || c.recruit_type || '';
  var chText = brandOpsChannelText(c.channel, c.channel_match);
  return '<div style="display:flex;align-items:center;gap:6px;font-size:10px;color:var(--muted);margin-bottom:3px">'
    + (typeKo ? '<span style="background:#F3E9F0;color:var(--pink);font-weight:600;padding:1px 6px;border-radius:6px;flex-shrink:0">' + esc(typeKo) + '</span>' : '')
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
function brandOpsSubmitDateText(c) {
  var parts = [];
  if (c.recruit_type === 'monitor') {
    var pr = brandOpsDateRange(c.purchase_start, c.purchase_end);
    if (pr) parts.push('구매 ' + pr);
  } else if (c.recruit_type === 'visit') {
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
  var delivTotal = c.deliv_total || 0, delivApproved = c.deliv_approved || 0;
  var approvePct = delivTotal > 0 ? Math.min(100, Math.round(delivApproved / delivTotal * 100)) : null;

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
    + brandOpsRateBar('결과물 승인', approvePct, delivApproved, delivTotal)
    + '<div style="display:flex;justify-content:flex-end;align-items:center;margin-top:8px;gap:4px">'
      + '<button class="btn btn-ghost btn-xs" onclick="event.stopPropagation();openCampPreviewModal(\'' + esc(c.id) + '\')">상세</button>'
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
