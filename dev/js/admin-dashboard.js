// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-dashboard.js
// ═════════════════════════════════════════════════════════════════
//
// 대시보드 페인 (admin.js 파일 분리).
//   · 메인 로드 + KPI + 캠페인 분포 + 최근 신청 (loadAdminData/renderCampaignBreakdown/renderRecentAppsTable)
//   · 회원가입 추이 차트 + 프로필 완성률 + 배송지 도도부현 도넛 (Chart.js)
//   · 상태/상수: _allUsers/_signupChart/_addressDistChart/PREFECTURE_KO/ADDRESS_DIST_COLORS
//
// ⚠ loadAdminData 는 switchAdminPane(admin-core.js) loaders + 부트(app.js)가 호출 → 전역 유지(이름 변경 금지).
// ⚠ loadAdminData 가 refreshAdminNoticeBadge/renderDashboardNotices/showAdminUnreadNoticesIfAny(admin-notices.js),
//   refreshDelivSidebarBadge/refreshApplySidebarBadge(admin-deliverables.js),
//   fetchViolationCountsByInfluencer→_infViolationCounts(admin-influencers.js)를 호출 — 모두 전역, 빌드 순서상 앞.
// ═════════════════════════════════════════════════════════════════

// ════════════════════════════════════════════════════════════════════
// SECTION: DASHBOARD — 메인 로드 + 캠페인 분포
//   refreshAdminNoticeBadge / renderDashboardNotices /
//   showAdminUnreadNoticesIfAny / refreshDelivSidebarBadge /
//   fetchViolationCountsByInfluencer 를 직접 호출 — 빌드 순서 확인
// ════════════════════════════════════════════════════════════════════

async function loadAdminData(preloaded) {
  initMultiFilters();
  updateSidebarProfile();

  // 병렬 fetch — preloaded 있으면 재사용 (init에서 이미 가져온 경우)
  const fetches = preloaded
    ? Promise.resolve(preloaded)
    : Promise.all([fetchCampaigns(), fetchInfluencers(), fetchApplications()]);
  const adminEmailsPromise = (_adminEmails && _adminEmails.length) ? null : loadAdminEmails();
  const [camps, users, apps] = await fetches;
  if (adminEmailsPromise) await adminEmailsPromise;

  allCampaigns = camps.slice();
  // 관리자 초기 진입 시 위반 카운트도 미리 로드 — 배지 전역 노출용
  fetchViolationCountsByInfluencer().then(vc => { _infViolationCounts = vc; }).catch(()=>{});
  // 관리자 공지 — 사이드바 배지·대시보드 최근·로그인 팝업
  fetchAdminNotices().then(list => {
    _adminNoticesCache = list;
    refreshAdminNoticeBadge();
    renderDashboardNotices();
    if (!window._adminNoticeUnreadShown) {
      window._adminNoticeUnreadShown = true;
      showAdminUnreadNoticesIfAny();
    }
  }).catch(()=>{});
  // 감사용 계정(is_audit) 격리 — KPI·통계·차트에서 제외 (광고주 보고용 수치 오염 방지).
  // users 는 전건으로 받아 통계용 statsUsers / statsApps 만 따로 거른다.
  // applications.user_id = influencers.id 이므로 user_id 단일 기준으로 격리 (user_email 컬럼 없음).
  const _auditIds = new Set(users.filter(u=>u.is_audit).map(u=>u.id));
  const statsUsers = users.filter(u=>!u.is_audit);
  const statsApps = apps.filter(a=>!_auditIds.has(a.user_id));

  const approved = statsApps.filter(a=>a.status==='approved');
  // pending 은 사이드바 신청 배지에도 쓰임 — 감사용 제외(처리 대상 아님).
  // 신청 관리 페인은 감사용을 표시하므로 배지<페인 카운트 불일치가 생길 수 있으나 의도된 격리.
  const pending = statsApps.filter(a=>a.status==='pending');

  $('kpiCampaigns').textContent = camps.length;
  $('kpiInfluencers').textContent = statsUsers.length;
  $('kpiApplications').textContent = statsApps.length;
  $('kpiApproved').textContent = approved.length;
  renderCampaignBreakdown(camps);
  // 목록 페인(loadAdminCampaigns/loadAdminInfluencers)은 해당 pane 진입 시에만 로드

  // 회원가입 차트 + KPI (감사용 제외)
  _allUsers = statsUsers;
  renderSignupKPIs(statsUsers);
  renderSignupChart(statsUsers, 30);
  renderProfileCompletion(statsUsers);
  // 배송지 분포(도도부현 Top N) — 통계용 statsUsers 재사용 (중복 쿼리 방지)
  renderAddressDistribution(statsUsers);
  // 회원 연령·성별 분포(연령대 막대 + 성별 도넛 + 교차표) — statsUsers 재사용(감사용 제외)
  renderAgeGenderDistribution(statsUsers);
  // 대시보드는 apps 전건을 KPI용으로 이미 보유 → 추가 count 쿼리 없이 인라인 계산.
  // 그 외 경로(부트의 대시보드 외 페인)는 refreshApplySidebarBadge() 가 가벼운 count 로 갱신.
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">인플 신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length>999?'999+':pending.length}</span>`:''}`;
  refreshDelivSidebarBadge();
  // 정산 대기 배지도 결과물 배지와 같은 주기로 갱신(대시보드 방문 시마다) — 백필로 새 정산 건이
  // 생겨도 관리자가 정산 페인을 직접 열지 않는 동안 배지가 stale 하지 않도록.
  if (typeof refreshSettlementSidebarBadge === 'function') refreshSettlementSidebarBadge();
}

// 최근 신청 렌더 — 대시보드에서 운영 현황 페인으로 이관 (브랜드 운영 재설계 PR 3)
// 운영 현황 페인(loadBrandOps)에서 apps/camps/users 를 넘겨 호출한다.
function renderRecentAppsTable(apps, camps, users) {
  if (!$('recentAppsBody')) return;
  const recent = apps.slice().sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
  const _auditIds = buildAuditIdSet(users);  // 감사용 응모는 빈자리 집계에서 제외
  $('recentAppsBody').innerHTML = recent.length ? recent.map(a=>{
    const camp = camps.find(c=>c.id===a.campaign_id)||{};
    const _dRem = Math.max((camp.slots||0)-countNonAuditApproved(apps, camp.id, _auditIds),0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    const _u = users.find(u=>u.email===a.user_email) || {};
    return `<tr class="${_u.is_audit?'audit-row':''}">
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${esc(imgThumb(thumbUrl,96,70))}" data-orig="${esc(thumbUrl)}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div>${typeLabel}</div>
            <div style="display:flex;align-items:flex-start;gap:4px"><strong style="font-size:13px;flex:1">${esc(camp.title)||'—'}</strong>${campPreviewBtn(camp.id)}</div>
            <div style="font-size:11px;color:var(--muted)">${esc(brandLabelAdmin(camp))}</div>
            ${camp.slots?`<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_dRem>0?'var(--green)':'var(--red)'};font-weight:600">${_dRem>0?_dRem+'건':'없음'}</span></div>`:''}
          </div>
        </div>
      </td>
      <td>
        <div class="link-cell" onclick="openInfluencerModal('${_u.id||''}')">${esc(a.user_name)||'—'}${auditBadgeHtml(_u)}${influencerStatusBadges(_u)}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)}</div>
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status, a.auto_reject_reason)}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${(_dRem<=0 && !_u.is_audit)?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
        :`<div><div style="font-size:10px;color:var(--muted)">${esc(formatReviewer(a.reviewed_by))} ${a.reviewed_at?formatDateTime(a.reviewed_at):''}</div><button class="btn btn-ghost btn-xs" style="margin-top:4px;font-size:10px" onclick="updateAppStatus('${a.id}','pending')">되돌리기</button></div>`}
      </td>
    </tr>`;
  }).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">신청 없음</td></tr>';
}

function renderCampaignBreakdown(camps) {
  const statusEl = $('campStatusBreakdown');
  const chEl = $('campChannelBreakdown');
  if (!statusEl || !chEl) return;

  const statusDef = [
    // 색은 목록 화면 상태 배지(components.css .badge-*)와 같은 값을 쓴다.
    // 두 화면이 다르면 같은 「모집중」이 화면마다 다른 초록으로 보인다.
    // 전체 현황은 전부 무채색 — 칩에는 「준비」「모집중」처럼 이름이 이미 쓰여 있어
    // 색으로 구분할 필요가 없다(색 단독으로 정보를 전달하지 않는다는 원칙과도 맞음).
    // 배경은 메인 컬러, 글자는 흰색. 라벨까지 대비 기준을 넘는 건 흰색뿐이라
    // (연보라 4.33:1 미달) 숫자·라벨 모두 흰색이고 위계는 글자 크기로 준다.
    {key:'draft',     label:'준비',     color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'scheduled', label:'모집예정', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'active',    label:'모집중',   color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'closed',    label:'모집마감', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'ended',     label:'종료',     color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'expired',   label:'노출종료', color:'#fff', bg:'rgba(255,255,255,.16)'},
  ];
  const statusCount = {};
  camps.forEach(c => { const s=c.status||'draft'; statusCount[s]=(statusCount[s]||0)+1; });
  statusEl.innerHTML = statusDef.map(s => `
    <div style="flex:1;min-width:90px;background:${s.bg};border-radius:10px;padding:10px 12px">
      <div style="font-size:20px;font-weight:800;color:${s.color}">${statusCount[s.key]||0}</div>
      <div style="font-size:11px;color:${s.color};opacity:.9;margin-top:2px">${s.label}</div>
    </div>`).join('');

  const chDef = [
    // 채널은 상태가 아니라 분류다. 이름이 이미 무엇인지 말해주므로 색을 쓰지 않는다.
    // (목록 화면의 채널 칩도 회색이라 그쪽과 통일)
    {key:'instagram', label:'Instagram', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'x', label:'X(Twitter)', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'qoo10', label:'Qoo10', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'tiktok', label:'TikTok', color:'#fff', bg:'rgba(255,255,255,.16)'},
    {key:'youtube', label:'YouTube', color:'#fff', bg:'rgba(255,255,255,.16)'},
  ];
  const chCount = {};
  camps.forEach(c => {
    (c.channel||'').split(',').map(s=>s.trim()).filter(Boolean).forEach(ch => {
      chCount[ch]=(chCount[ch]||0)+1;
    });
  });
  chEl.innerHTML = chDef.map(c => `
    <div style="flex:1;min-width:90px;background:${c.bg};border-radius:10px;padding:10px 12px">
      <div style="font-size:20px;font-weight:800;color:${c.color}">${chCount[c.key]||0}</div>
      <div style="font-size:11px;color:${c.color};opacity:.9;margin-top:2px">${c.label}</div>
    </div>`).join('');
}


// ══════════════════════════════════════
// 회원가입 차트 / KPI / 프로필 완성률
// ══════════════════════════════════════
var _allUsers = [];
var _signupChart = null;
var _addressDistChart = null;
var _ageDistChart = null;
var _genderDistChart = null;

// 일본 도도부현 한국어 표기 매핑 (47개 전체)
var PREFECTURE_KO = {
  '北海道':'홋카이도','青森県':'아오모리현','岩手県':'이와테현','宮城県':'미야기현',
  '秋田県':'아키타현','山形県':'야마가타현','福島県':'후쿠시마현','茨城県':'이바라키현',
  '栃木県':'도치기현','群馬県':'군마현','埼玉県':'사이타마현','千葉県':'지바현',
  '東京都':'도쿄도','神奈川県':'가나가와현','新潟県':'니가타현','富山県':'도야마현',
  '石川県':'이시카와현','福井県':'후쿠이현','山梨県':'야마나시현','長野県':'나가노현',
  '岐阜県':'기후현','静岡県':'시즈오카현','愛知県':'아이치현','三重県':'미에현',
  '滋賀県':'시가현','京都府':'교토부','大阪府':'오사카부','兵庫県':'효고현',
  '奈良県':'나라현','和歌山県':'와카야마현','鳥取県':'돗토리현','島根県':'시마네현',
  '岡山県':'오카야마현','広島県':'히로시마현','山口県':'야마구치현','徳島県':'도쿠시마현',
  '香川県':'가가와현','愛媛県':'에히메현','高知県':'고치현','福岡県':'후쿠오카현',
  '佐賀県':'사가현','長崎県':'나가사키현','熊本県':'구마모토현','大分県':'오이타현',
  '宮崎県':'미야자키현','鹿児島県':'가고시마현','沖縄県':'오키나와현'
};

// 차트용 포인트 컬러 램프 (2026-07-20 — 메인 컬러 #625EBD 계열)
//   가장 큰 조각이 메인 컬러가 되도록 메인에서 시작해 점점 옅어진다.
//   ⚠️ 밝은 쪽만 쓰므로 구분 폭이 좁다 — 검증상 3조각까지가 안전하고(인접차 19.8),
//      4조각 12.8 · 5조각 9.5 로 기준(15) 미달이다. 조각이 많은 차트는
//      가운데 단계들이 서로 비슷해 보이므로 범례·툴팁으로 읽어야 한다.
function accentRamp(n) {
  const H = 243 / 360, S = 0.419, LO = 0.555, HI = 0.93;   // LO = 메인 컬러의 명도
  if (n <= 0) return [];
  if (n === 1) return ['#625EBD'];
  const out = [];
  for (let i = 0; i < n; i++) {
    const t = LO + (HI - LO) * i / (n - 1);
    const sat = S * (1 - 0.30 * (t - LO) / (HI - LO));   // 옅어질수록 채도도 낮춰 탁하지 않게
    out.push(_hslHex(H, sat, t));
  }
  return out;
}

// HSL → #RRGGBB
function _hslHex(h, s, l) {
  const f = n => {
    const k = (n + h * 12) % 12;
    const a = s * Math.min(l, 1 - l);
    const v = l - a * Math.max(-1, Math.min(k - 3, Math.min(9 - k, 1)));
    return Math.round(v * 255).toString(16).padStart(2, '0');
  };
  return '#' + f(0) + f(8) + f(4);
}
// 막대용 세로 그라데이션 — 위는 진하게, 아래로 갈수록 살짝 옅게
function accentBarGradient(ctx, area, from, to) {
  if (!area) return from;
  const g = ctx.createLinearGradient(0, area.top, 0, area.bottom);
  g.addColorStop(0, from);
  g.addColorStop(1, to);
  return g;
}


// Chart.js 옵션 빌더 — legend/tooltip 퍼센티지 포맷 (렌더 함수 길이 축소 목적 분리)
// ════════════════════════════════════════════════════════════════════
// SECTION: DASHBOARD — 주소 도넛 + 가입 추이 + 프로필 완성률
// ════════════════════════════════════════════════════════════════════

// onPanel = 메인 컬러 패널 위에 놓이는 차트인지. 배송지 도넛은 흰 카드 위라 false.
function buildAddressChartOptions(stats, onPanel) {
  const totalForPct = stats && stats.total ? stats.total : 0;
  const pctOf = (value) => totalForPct ? ((value / totalForPct) * 100).toFixed(1) : '0.0';
  return {
    responsive: true,
    maintainAspectRatio: false,
    cutout: '55%',
    plugins: {
      legend: {
        position: 'right',
        labels: {
          boxWidth: 12,
          padding: 10,
          font: { size: 12 },
          color: onPanel ? '#fff' : undefined,   // 메인 컬러 패널 위에서는 기본 회색이 안 읽힘
          generateLabels(chart) {
            const data = chart.data;
            return data.labels.map((label, i) => {
              const value = data.datasets[0].data[i];
              return {
                text: `${label}  ${value}명 (${pctOf(value)}%)`,
                fillStyle: data.datasets[0].backgroundColor[i],
                strokeStyle: onPanel ? '#625EBD' : '#fff',
                lineWidth: 1,
                index: i
              };
            });
          }
        }
      },
      tooltip: {
        callbacks: {
          label: ctx => `${ctx.label}: ${ctx.parsed}명 (${pctOf(ctx.parsed)}%)`
        }
      }
    }
  };
}

// 배송지(도도부현) 분포 파이 차트 렌더 — Top N + 미등록 + 해외
// - loadAdminData가 이미 가져온 users 배열을 받아 중복 쿼리 없이 집계
function renderAddressDistribution(users) {
  const canvas = $('addressDistChart');
  const totalLabel = $('addressDistTotal');
  const emptyLabel = $('addressDistEmpty');
  const loading = $('addressDistLoading');
  if (!canvas) return;

  try {
    const stats = computePrefectureStats(users || []);
    if (loading) loading.style.display = 'none';
    if (totalLabel) totalLabel.textContent = `전체 ${stats.total}명`;

    // 라벨을 한국어로 변환 (매핑 없으면 원문 유지)
    const labels = stats.top.map(r => PREFECTURE_KO[r.name] || r.name);
    const values = stats.top.map(r => r.count);
    // 미등록·해외까지 포함한 전체 조각 수로 램프를 만들어 명도를 최대한 벌린다
    const sliceCount = stats.top.length + (stats.unregistered > 0 ? 1 : 0) + (stats.overseas > 0 ? 1 : 0);
    const ramp = accentRamp(sliceCount);
    const colors = stats.top.map((_, i) => ramp[i]);

    if (stats.unregistered > 0) { labels.push('미등록'); values.push(stats.unregistered); colors.push(ramp[colors.length]); }
    if (stats.overseas > 0) { labels.push('해외'); values.push(stats.overseas); colors.push(ramp[colors.length]); }

    if (_addressDistChart) { _addressDistChart.destroy(); _addressDistChart = null; }

    if (labels.length === 0) {
      canvas.style.display = 'none';
      if (emptyLabel) emptyLabel.style.display = 'block';
      return;
    }

    canvas.style.display = 'block';
    if (emptyLabel) emptyLabel.style.display = 'none';

    _addressDistChart = new Chart(canvas.getContext('2d'), {
      type: 'doughnut',
      data: {
        labels,
        datasets: [{
          data: values,
          backgroundColor: colors,
          borderColor: '#fff',
          borderWidth: 2
        }]
      },
      options: buildAddressChartOptions(stats)
    });
  } catch (e) {
    if (loading) loading.style.display = 'none';
    console.error('[addressDist] render failed:', e);
  }
}

// 회원 연령·성별 분포 — 수집률 막대 + 연령대 막대 + 성별 도넛 + 연령×성별 교차표.
// loadAdminData가 넘긴 statsUsers(감사용 제외) 재사용(추가 쿼리 0). 집계는 storage.js computeAgeGenderStats.
// 데이터 0건이면 빈 상태 안내, 소표본(생년월일 등록 30명 미만)이면 참고용 캡션.
function renderAgeGenderDistribution(users) {
  const totalLabel = $('ageGenderTotal');
  const collectBars = $('ageGenderCollectBars');
  const body = $('ageGenderBody');
  const empty = $('ageGenderEmpty');
  const caption = $('ageGenderCaption');
  const ageCanvas = $('ageDistChart');
  const genderCanvas = $('genderDistChart');
  const crossEl = $('ageGenderCrossTable');
  if (!ageCanvas || !genderCanvas) return;

  try {
    const stats = computeAgeGenderStats(users || []);
    const total = stats.total;
    if (totalLabel) totalLabel.textContent = `생년월일 ${stats.ageRegistered}·성별 ${stats.genderRegistered} / 전체 ${total}명`;

    // 수집률 막대(생년월일·성별)는 「프로필 완성률」로 옮겼다 — 같은 성격(등록률)이라
    // 한곳에서 보는 편이 낫다. renderProfileCompletion 참조.
    if (collectBars) collectBars.innerHTML = '';

    if (_ageDistChart) { _ageDistChart.destroy(); _ageDistChart = null; }
    if (_genderDistChart) { _genderDistChart.destroy(); _genderDistChart = null; }

    // 수집 0건 → 차트·표 숨기고 안내 (현재 운영 상태)
    const hasData = (stats.ageRegistered + stats.genderRegistered) > 0;
    if (!hasData) {
      if (body) body.style.display = 'none';
      if (empty) empty.style.display = 'block';
      if (caption) caption.style.display = 'none';
      return;
    }
    if (body) body.style.display = '';
    if (empty) empty.style.display = 'none';

    // 소표본 참고용 캡션
    if (caption) {
      if (stats.ageRegistered > 0 && stats.ageRegistered < 30) {
        caption.style.display = 'block';
        caption.textContent = `표본이 적어 참고용입니다 (생년월일 등록 ${stats.ageRegistered}명). 비율보다 실제 인원수로 보세요.`;
      } else { caption.style.display = 'none'; }
    }

    // 연령대 막대 (이상치는 0이면 제외, 미등록·이상치는 회색)
    const ageRows = stats.ageBuckets.filter(b => b.label !== '이상치' || b.count > 0);
    _ageDistChart = new Chart(ageCanvas.getContext('2d'), {
      type: 'bar',
      data: {
        labels: ageRows.map(b => b.label),
        datasets: [{
          data: ageRows.map(b => b.count),
          backgroundColor: (c) => ageRows.map(b => (b.label === '미등록' || b.label === '이상치')
            ? '#D4D4DA'
            : accentBarGradient(c.chart.ctx, c.chart.chartArea, '#625EBD', '#8F8CD2')),
          borderRadius: 4
        }]
      },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false }, tooltip: { callbacks: { label: ctx => `${ctx.parsed.y}명` } } },
        scales: {
          y: { beginAtZero: true, ticks: { precision: 0 }, grid: { color: 'rgba(0,0,0,.06)' } },
          x: { grid: { display: false } }
        }
      }
    });

    // 성별 도넛 (남/여/그 외/응답 안 함/미등록) — 분모=전체 회원
    _genderDistChart = new Chart(genderCanvas.getContext('2d'), {
      type: 'doughnut',
      data: {
        labels: ['남성', '여성', '그 외', '응답 안 함', '미등록'],
        datasets: [{
          data: [stats.gender.male, stats.gender.female, stats.gender.other, stats.gender.undisclosed, stats.gender.unregistered],
          backgroundColor: accentRamp(5),   // 인접 차이 15.2 — 구분 한계치
          borderColor: '#fff', borderWidth: 2
        }]
      },
      options: buildAddressChartOptions({ total })
    });

    // 연령×성별 교차표 (실수 명 중심, 0은 '-')
    if (crossEl) {
      const gKeys = ['male', 'female', 'other', 'undisclosed', 'unregistered'];
      const gHead = ['남성', '여성', '그 외', '응답 안 함', '미등록'];
      const crossRows = [...AGE_GENDER_BUCKETS, '미등록'];
      const cell = v => v > 0 ? v : '<span style="color:var(--muted)">-</span>';
      crossEl.innerHTML =
        '<table style="width:100%;border-collapse:collapse;font-size:11px;table-layout:fixed">' +
        '<thead><tr><th style="text-align:left;padding:8px;color:var(--muted);font-weight:600">연령대</th>' +
        gHead.map(h => `<th style="text-align:right;padding:8px;color:var(--muted);font-weight:600">${h}</th>`).join('') +
        '</tr></thead><tbody>' +
        crossRows.map(rk => {
          const r = stats.cross[rk] || {};
          return `<tr style="border-top:1px solid var(--line)"><td style="padding:11px 8px;color:var(--ink)">${rk}</td>` +
            gKeys.map(gk => `<td style="text-align:right;padding:11px 8px">${cell(r[gk] || 0)}</td>`).join('') + '</tr>';
        }).join('') +
        '</tbody></table>';
    }
  } catch (e) {
    console.error('[ageGenderDist] render failed:', e);
  }
}

function renderSignupKPIs(users) {
  const now = new Date();
  const todayStr = now.toISOString().slice(0, 10);
  const weekAgo = new Date(now); weekAgo.setDate(weekAgo.getDate() - 7);

  const today = users.filter(u => (u.created_at || '').slice(0, 10) === todayStr).length;
  const week = users.filter(u => new Date(u.created_at) >= weekAgo).length;

  $('kpiSignupToday').textContent = today;
  $('kpiSignupWeek').textContent = week;

  const fmt = d => `${d.getMonth()+1}/${d.getDate()}`;
  $('kpiWeekRange').textContent = `${fmt(weekAgo)} ~ ${fmt(now)}`;
}

// 가입 추이 시리즈 집계 (전체=월별 / 그 외=최근 days 일별) — 렌더 함수 길이 축소 목적 분리
function _computeSignupSeries(users, days) {
  const now = new Date();
  const labels = [];
  const counts = [];

  if (days === 0) {
    // 전체: 월별 집계
    const monthMap = {};
    users.forEach(u => {
      const m = (u.created_at || '').slice(0, 7);
      if (m) monthMap[m] = (monthMap[m] || 0) + 1;
    });
    const months = Object.keys(monthMap).sort();
    months.forEach(m => {
      labels.push(m);
      counts.push(monthMap[m]);
    });
  } else {
    // 일별 집계
    for (let i = days - 1; i >= 0; i--) {
      const d = new Date(now);
      d.setDate(d.getDate() - i);
      const dateStr = d.toISOString().slice(0, 10);
      const label = `${d.getMonth() + 1}/${d.getDate()}`;
      const count = users.filter(u => (u.created_at || '').slice(0, 10) === dateStr).length;
      labels.push(label);
      counts.push(count);
    }
  }
  return { labels, counts };
}

function renderSignupChart(users, days) {
  const { labels, counts } = _computeSignupSeries(users, days);

  const canvas = $('signupChart');
  if (!canvas) return;
  if (_signupChart) _signupChart.destroy();

  _signupChart = new Chart(canvas, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [{
        label: '신규 가입',
        data: counts,
        backgroundColor: (c) => accentBarGradient(c.chart.ctx, c.chart.chartArea, '#625EBD', '#8F8CD2'),
        borderColor: '#625EBD',
        borderWidth: 0,
        borderRadius: 4,
        categoryPercentage: 1,   // 칸 사이 여백 없음
        barPercentage: 1         // 칸을 막대가 가득 채움
      }]
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false }
      },
      scales: {
        y: { beginAtZero: true, ticks: { stepSize: 1, font: { size: 11 } }, grid: { color: 'rgba(0,0,0,.05)' } },
        x: { ticks: { font: { size: 10 } }, grid: { display: false } }
      }
    }
  });
}

function switchSignupPeriod(days, btn) {
  document.querySelectorAll('.signup-period-btn').forEach(b => b.classList.remove('on'));
  btn.classList.add('on');
  renderSignupChart(_allUsers, days);
}

function renderProfileCompletion(users) {
  if (!users.length) { $('profileCompletionBars').innerHTML = '<div style="font-size:11px;color:var(--muted)">데이터 없음</div>'; return; }
  const total = users.length;
  const hasSns = users.filter(u => u.ig || u.x || u.tiktok || u.youtube).length;
  const hasIg = users.filter(u => u.ig).length;
  const hasX = users.filter(u => u.x).length;
  const hasTiktok = users.filter(u => u.tiktok).length;
  const hasYt = users.filter(u => u.youtube).length;
  // zip/address 는 influencers_admin_view 마스킹 대상이라 낮은 권한 등급엔 항상 NULL —
  // 대신 마스킹 안 되는 prefecture 로 판정(배송지 입력 시 zip/prefecture/city/phone 이 대체로
  // 함께 채워지므로 근사 지표. zip 기반과 완전히 동일하진 않을 수 있으나 KPI 성격상 허용,
  // PR3 조각 B, 2026-07-06).
  const hasAddr = users.filter(u => u.prefecture).length;
  // has_paypal(마스킹 무관 항상 정확한 존재 여부) 기준 — 값 자체가 아니라 등록 여부만 필요
  const hasPaypal = users.filter(u => u.has_paypal).length;
  // 생년월일·성별 등록률 — 「회원 연령·성별 분포」에 있던 것을 여기로 옮김.
  // 판정 기준은 그쪽 집계(storage.js computeAgeGenderStats)와 동일하게 맞춘다:
  //   생년월일 = 나이 계산이 되는 유효한 값 / 성별 = 미등록이 아닌 값(응답 안 함 포함)
  const GENDERS = ['male','female','other','undisclosed'];
  const hasBirthdate = users.filter(u => {
    const age = (typeof calcAgeFromBirthdate === 'function') ? calcAgeFromBirthdate(u.birthdate || '') : null;
    return age != null && age >= 18;
  }).length;
  const hasGender = users.filter(u => GENDERS.includes(u.gender)).length;

  const pct = v => Math.round(v / total * 100);
  // 막대 굵기 — 한 곳에서 조절 (큰 항목 / 하위 채널)
  const BAR_H = 10, BAR_H_SUB = 7;
  const bar = (label, val, color, sub) => `
    <div style="margin-bottom:${sub ? 3 : 5}px;${sub ? 'padding-left:12px' : ''}">
      <div style="display:flex;justify-content:space-between;font-size:${sub ? 10 : 11}px;margin-bottom:2px">
        <span style="color:${sub ? 'var(--muted)' : 'var(--ink)'}">${label}</span><span style="color:var(--muted);font-weight:600">${val}%</span>
      </div>
      <div style="height:${sub ? BAR_H_SUB : BAR_H}px;background:var(--bg);border-radius:4px;overflow:hidden;display:block">
        <div style="height:100%;width:${val}%;background:${color === 'accent' ? 'linear-gradient(90deg,#625EBD 0%,#8F8CD2 100%)' : (color === 'accent-sub' ? 'linear-gradient(90deg,#A8A6D5 0%,#C9C8E3 100%)' : color)};border-radius:4px;transition:width .4s"></div>
      </div>
    </div>`;

  // 큰 항목(SNS·배송지·PayPal) 사이 간격 — 한 곳에서 조절
  const GROUP_GAP = '<div style="height:9px"></div>';
  $('profileCompletionBars').innerHTML =
    bar('SNS', pct(hasSns), 'accent', false) +
    bar('Instagram', pct(hasIg), 'accent-sub', true) +
    bar('X (Twitter)', pct(hasX), 'accent-sub', true) +
    bar('TikTok', pct(hasTiktok), 'accent-sub', true) +
    bar('YouTube', pct(hasYt), 'accent-sub', true) +
    GROUP_GAP +
    bar('배송지', pct(hasAddr), 'accent', false) +
    GROUP_GAP +
    bar('PayPal', pct(hasPaypal), 'accent', false) +
    GROUP_GAP +
    bar('생년월일', pct(hasBirthdate), 'accent', false) +
    GROUP_GAP +
    bar('성별', pct(hasGender), 'accent', false);
}

