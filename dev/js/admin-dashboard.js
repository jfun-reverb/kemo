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
  const approved = apps.filter(a=>a.status==='approved');
  const pending = apps.filter(a=>a.status==='pending');

  $('kpiCampaigns').textContent = camps.length;
  $('kpiInfluencers').textContent = users.length;
  $('kpiApplications').textContent = apps.length;
  $('kpiApproved').textContent = approved.length;
  renderCampaignBreakdown(camps);
  // 목록 페인(loadAdminCampaigns/loadAdminInfluencers)은 해당 pane 진입 시에만 로드

  // 회원가입 차트 + KPI
  _allUsers = users;
  renderSignupKPIs(users);
  renderSignupChart(users, 30);
  renderProfileCompletion(users);
  // 배송지 분포(도도부현 Top N) — 이미 fetch한 users 재사용 (중복 쿼리 방지)
  renderAddressDistribution(users);
  // 대시보드는 apps 전건을 KPI용으로 이미 보유 → 추가 count 쿼리 없이 인라인 계산.
  // 그 외 경로(부트의 대시보드 외 페인)는 refreshApplySidebarBadge() 가 가벼운 count 로 갱신.
  if ($('adminApplySi')) $('adminApplySi').innerHTML = `<span class="si-icon material-icons-round notranslate" translate="no">assignment</span><span class="si-text">신청 관리</span>${pending.length>0?`<span class="admin-si-badge">${pending.length>999?'999+':pending.length}</span>`:''}`;
  refreshDelivSidebarBadge();
}

// 최근 신청 렌더 — 대시보드에서 운영 현황 페인으로 이관 (브랜드 운영 재설계 PR 3)
// 운영 현황 페인(loadBrandOps)에서 apps/camps/users 를 넘겨 호출한다.
function renderRecentAppsTable(apps, camps, users) {
  if (!$('recentAppsBody')) return;
  const recent = apps.slice().sort((a,b)=>new Date(b.created_at)-new Date(a.created_at)).slice(0,8);
  $('recentAppsBody').innerHTML = recent.length ? recent.map(a=>{
    const camp = camps.find(c=>c.id===a.campaign_id)||{};
    const _dRem = Math.max((camp.slots||0)-apps.filter(x=>x.campaign_id===camp.id&&x.status==='approved').length,0);
    const imgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url].filter(Boolean).filter((v,i,arr)=>arr.indexOf(v)===i);
    const thumbUrl = imgs[0] || '';
    const typeLabel = getRecruitTypeBadgeKoSm(camp.recruit_type);
    return `<tr>
      <td>
        <div style="display:flex;align-items:center;gap:10px">
          <div style="position:relative;width:40px;height:40px;flex-shrink:0;border-radius:6px;overflow:hidden;background:var(--surface-dim)">
            ${thumbUrl ? `<img src="${esc(imgThumb(thumbUrl,96,70))}" data-orig="${esc(thumbUrl)}" loading="lazy" decoding="async" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" style="width:100%;height:100%;object-fit:cover">` : `<span style="display:flex;align-items:center;justify-content:center;width:100%;height:100%;font-size:18px">${esc(camp.emoji)||'<span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted)">inventory_2</span>'}</span>`}
          </div>
          <div style="min-width:0">
            <div>${typeLabel}</div>
            <strong style="font-size:13px;cursor:pointer" onclick="openCampPreviewModal('${camp.id}')">${esc(camp.title)||'—'}</strong>
            <div style="font-size:11px;color:var(--muted)">${esc(camp.brand)||''}</div>
            ${camp.slots?`<div style="font-size:10px;color:var(--muted);margin-top:2px">모집 ${camp.slots}명 · 빈자리 <span style="color:${_dRem>0?'var(--green)':'var(--red)'};font-weight:600">${_dRem>0?_dRem+'건':'없음'}</span></div>`:''}
          </div>
        </div>
      </td>
      <td>
        <div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openInfluencerModal('${users.find(u=>u.email===a.user_email)?.id||''}')">${esc(a.user_name)||'—'}${influencerStatusBadges(users.find(u=>u.email===a.user_email)||{})}</div>
        <div style="font-size:11px;color:var(--muted)">${esc(a.user_email)}</div>
      </td>
      <td>${msgCell(a.message, a)}</td>
      <td style="font-size:12px;color:var(--muted);white-space:nowrap">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status)}</td>
      <td style="white-space:nowrap">
        ${a.status==='pending'?`<div style="display:flex;gap:4px"><button class="btn btn-green btn-xs" ${_dRem<=0?'disabled style="background:var(--muted);opacity:.5;cursor:not-allowed"':''}onclick="updateAppStatus('${a.id}','approved')">승인</button><button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="updateAppStatus('${a.id}','rejected')">미승인</button></div>`
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
    {key:'draft',     label:'준비',     color:'#9aa0a6', bg:'#F1F3F4'},
    {key:'scheduled', label:'모집예정', color:'#5B7CFF', bg:'#EEF2FF'},
    {key:'active',    label:'모집중',   color:'#0E7E4A', bg:'#E8F7EF'},
    {key:'closed',    label:'종료',     color:'#B91C5C', bg:'#FFE4EC'},
    {key:'expired',   label:'노출마감', color:'#666666', bg:'#EEEEEE'},
  ];
  const statusCount = {};
  camps.forEach(c => { const s=c.status||'draft'; statusCount[s]=(statusCount[s]||0)+1; });
  statusEl.innerHTML = statusDef.map(s => `
    <div style="flex:1;min-width:90px;background:${s.bg};border-radius:10px;padding:10px 12px">
      <div style="font-size:20px;font-weight:800;color:${s.color}">${statusCount[s.key]||0}</div>
      <div style="font-size:11px;color:var(--muted);margin-top:2px">${s.label}</div>
    </div>`).join('');

  const chDef = [
    {key:'instagram', label:'Instagram', color:'#C13584', bg:'#FCE8F3'},
    {key:'x', label:'X(Twitter)', color:'#0F1419', bg:'#EEEEEE'},
    {key:'qoo10', label:'Qoo10', color:'#B26A00', bg:'#FFF4E5'},
    {key:'tiktok', label:'TikTok', color:'#010101', bg:'#E8F7F9'},
    {key:'youtube', label:'YouTube', color:'#C4302B', bg:'#FDECEC'},
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
      <div style="font-size:11px;color:var(--muted);margin-top:2px">${c.label}</div>
    </div>`).join('');
}


// ══════════════════════════════════════
// 회원가입 차트 / KPI / 프로필 완성률
// ══════════════════════════════════════
var _allUsers = [];
var _signupChart = null;
var _addressDistChart = null;

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

// 파이 차트용 컬러 팔레트 (Top 10 + 미등록/해외)
var ADDRESS_DIST_COLORS = [
  '#E8344E','#5B7CFF','#4ECDC4','#F4A43A','#9B59B6',
  '#5BA86E','#E87A96','#3E79B8','#D49158','#7CA565'
];

// Chart.js 옵션 빌더 — legend/tooltip 퍼센티지 포맷 (렌더 함수 길이 축소 목적 분리)
// ════════════════════════════════════════════════════════════════════
// SECTION: DASHBOARD — 주소 도넛 + 가입 추이 + 프로필 완성률
// ════════════════════════════════════════════════════════════════════

function buildAddressChartOptions(stats) {
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
          generateLabels(chart) {
            const data = chart.data;
            return data.labels.map((label, i) => {
              const value = data.datasets[0].data[i];
              return {
                text: `${label}  ${value}명 (${pctOf(value)}%)`,
                fillStyle: data.datasets[0].backgroundColor[i],
                strokeStyle: '#fff',
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
    const colors = stats.top.map((_, i) => ADDRESS_DIST_COLORS[i % ADDRESS_DIST_COLORS.length]);

    if (stats.unregistered > 0) { labels.push('미등록'); values.push(stats.unregistered); colors.push('#BDBDC4'); }
    if (stats.overseas > 0) { labels.push('해외'); values.push(stats.overseas); colors.push('#8A8A90'); }

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
        backgroundColor: 'rgba(200,120,163,.6)',
        borderColor: 'rgba(200,120,163,1)',
        borderWidth: 1,
        borderRadius: 4
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
  const hasAddr = users.filter(u => u.zip || u.address).length;
  const hasPaypal = users.filter(u => u.paypal_email).length;

  const pct = v => Math.round(v / total * 100);
  const bar = (label, val, color, sub) => `
    <div style="margin-bottom:${sub ? 4 : 8}px;${sub ? 'padding-left:12px' : ''}">
      <div style="display:flex;justify-content:space-between;font-size:${sub ? 10 : 11}px;margin-bottom:3px">
        <span style="color:${sub ? 'var(--muted)' : 'var(--ink)'}">${label}</span><span style="color:var(--muted);font-weight:600">${val}%</span>
      </div>
      <div style="height:${sub ? 4 : 6}px;background:var(--bg);border-radius:3px;overflow:hidden">
        <div style="height:100%;width:${val}%;background:${color};border-radius:3px;transition:width .4s;opacity:${sub ? '.6' : '1'}"></div>
      </div>
    </div>`;

  $('profileCompletionBars').innerHTML =
    bar('SNS', pct(hasSns), '#5B7CFF', false) +
    bar('Instagram', pct(hasIg), '#5B7CFF', true) +
    bar('X (Twitter)', pct(hasX), '#5B7CFF', true) +
    bar('TikTok', pct(hasTiktok), '#5B7CFF', true) +
    bar('YouTube', pct(hasYt), '#5B7CFF', true) +
    '<div style="margin-top:4px"></div>' +
    bar('배송지', pct(hasAddr), '#FF9F43', false) +
    bar('PayPal', pct(hasPaypal), '#28C76F', false);
}

