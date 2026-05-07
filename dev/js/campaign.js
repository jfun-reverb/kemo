// ══════════════════════════════════════
// CAMPAIGNS — 목록, 상세, 필터
// ══════════════════════════════════════

// currentUser, currentUserProfile, currentCampaignId, allCampaigns 는 shared.js에서 선언
var currentFilter = 'all';
let campPageTypeFilter = 'all';
let currentTypeFilter = 'all';

// ── 기본 캠페인 데이터 (DB가 비어있을 때 표시됨) ──
DEMO_CAMPAIGNS = [
  {id:'demo-1',recruit_type:'monitor',title:'グリーンティセラム ナノ体験団',brand:'INNISFREE · イニスフリー',product:'グリーンティセラム 80ml',type:'nano',channel:'instagram',category:'beauty',emoji:'🌿',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0016/A00000016477202.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0016/A00000016477202.jpg',product_price:3200,reward:0,slots:25,applied_count:18,deadline:'2026-05-30',post_days:7,content_types:'インスタ/フィード,インスタ/リール',description:'イニスフリーの人気スキンケアアイテム、グリーンティセラムを体験していただける方を募集します。',hashtags:'#innisfree #イニスフリー #グリーンティセラム #スキンケア',mentions:'@innisfree_official_jp',appeal:'グリーンティ由来の保湿成分が肌深部まで浸透。',guide:'明るい自然光で撮影してください。商品のテクスチャーがわかるようにアップで撮影。',ng:'競合ブランド商品との比較投稿はNG。ネガティブ表現はNG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-2',recruit_type:'monitor',title:'ラウンドラボ バーチュラ体験団',brand:'ROUND LAB · ラウンドラボ',product:'バーチュラトナー 200ml',type:'nano',channel:'instagram',category:'beauty',emoji:'🌿',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018208201.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018208201.jpg',product_price:4500,reward:0,slots:20,applied_count:12,deadline:'2026-05-25',post_days:10,content_types:'インスタ/フィード',description:'ROUND LABの大人気バーチュラトナーを体験していただける方を募集します。',hashtags:'#roundlab #ラウンドラボ #バーチュラトナー #韓国コスメ',mentions:'@roundlab_jp',appeal:'白樺水配合で肌を優しく整えるトナー。乾燥肌・敏感肌の方に特におすすめ。',guide:'清潔感のある明るい背景で撮影。使用前後の肌の変化を表現してください。',ng:'他ブランドとの比較NG。フィルター過剰使用NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-3',recruit_type:'monitor',title:'DR.G クッションファンデ体験団',brand:'DR.G · ドクタージー',product:'レッドブレミッシュクッション',type:'nano',channel:'instagram',category:'beauty',emoji:'💄',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',product_price:3800,reward:1000,slots:15,applied_count:9,deadline:'2026-06-01',post_days:14,content_types:'インスタ/フィード,インスタ/リール,インスタ/ストーリー',description:'DR.Gの人気クッションファンデーションを体験していただける方を募集！報酬¥1,000付き。',hashtags:'#drg #ドクタージー #クッションファンデ #韓国コスメ',mentions:'@drg_japan',appeal:'赤みをカバーしながら素肌感を演出。SPF50+PA+++で紫外線対策も。',guide:'使用前後のビフォーアフターが伝わる投稿。明るい自然光での撮影推奨。',ng:'過度なフィルター加工NG。競合製品との比較NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-4',recruit_type:'gifting',title:'MEDIHEAL マスクパック体験団',brand:'MEDIHEAL · メディヒール',product:'TEAトゥリーケアマスクパック 10枚',type:'nano',channel:'instagram',category:'beauty',emoji:'🩺',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',product_price:2000,reward:0,slots:30,applied_count:22,deadline:'2026-05-20',post_days:7,content_types:'インスタ/フィード,TikTok',description:'MEDIHEALのTEAトゥリーマスクパックを体験していただける方を募集します。',hashtags:'#mediheal #メディヒール #マスクパック #スキンケア',mentions:'@mediheal_japan',appeal:'ティーツリー成分が肌トラブルをケア。毛穴引き締め効果も。',guide:'着用中・着用後の自然な表情を撮影。朝・夜のスキンケアシーンに合わせてください。',ng:'加工しすぎた写真NG。マスク着用以外の用途での撮影NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-5',recruit_type:'gifting',title:'PERIPERA リップ体験団',brand:'PERIPERA · ペリペラ',product:'インクムードグロウティント',type:'nano',channel:'instagram',category:'beauty',emoji:'💋',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',product_price:1500,reward:500,slots:20,applied_count:15,deadline:'2026-05-31',post_days:7,content_types:'インスタ/リール,TikTok',description:'PERIPERAの人気リップを体験！報酬¥500付き。カラー発色が美しいグロウティントです。',hashtags:'#peripera #ペリペラ #リップ #韓国コスメ #Kビューティ',mentions:'@peripera_japan',appeal:'ウォータリーなテクスチャーで唇に密着。鮮やかな発色が長時間持続。',guide:'リップスウォッチや着用シーンを撮影。明るい照明で発色が伝わるように。',ng:'口元以外の過度なフィルターNG。競合リップとの比較NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-6',recruit_type:'gifting',title:'BIBIGO 餃子 Qoo10体験団',brand:'CJ BIBIGO · ビビゴ',product:'王餃子 420g',type:'qoo10',channel:'qoo10',category:'food',emoji:'🥟',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',product_price:1200,reward:2000,slots:10,applied_count:7,deadline:'2026-06-15',post_days:10,content_types:'インスタ/フィード,X投稿',description:'BIBIGOの人気王餃子をQoo10でレビュー！報酬¥2,000付き。',hashtags:'#bibigo #ビビゴ #王餃子 #韓国フード #Qoo10',mentions:'@bibigo_japan',appeal:'本場韓国の味をそのままに。もちもちの皮と旨味たっぷりの肉あん。',guide:'調理過程・完成品を美しく撮影。食欲をそそるシズル感を大切に。',ng:'他社冷凍食品との比較NG。料理以外での使用シーンNG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'}
];

async function loadCampaigns() {
  allCampaigns = await fetchCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);
}

// 인플루언서에게 보이는 캠페인: 모집중 + 모집예정 + 모집마감(게시기한 남음)
// expired(노출마감) 는 post_deadline 경과 후 서버가 자동 전환한 상태 — 완전 비노출
function visibleCamps(camps) {
  const now = new Date(); now.setHours(0,0,0,0);
  return camps.filter(c => {
    if (c.status === 'active' || c.status === 'scheduled') return true;
    if (c.status === 'closed' && c.post_deadline) {
      const pd = new Date(c.post_deadline); pd.setHours(23,59,59,999);
      return now <= pd;
    }
    // draft / expired / (closed without post_deadline) → 비노출
    return false;
  });
}

// 인플루언서 노출 캠페인의 정렬: 모집중(active) > 모집예정(scheduled) > 모집완료(closed)
// 같은 상태 안에서는 모집기간 시작~종료일 최신순.
//   1차: recruit_start (모집 시작일) 최신순 — "가장 최근에 시작한 캠페인"이 위로
//   2차: deadline (모집 종료일) 최신순 — recruit_start가 없을 때 fallback
//   3차: created_at 최신순 — 둘 다 없을 때 fallback
function sortByStatusAndDeadline(camps) {
  const order = {active: 0, scheduled: 1, closed: 2};
  const ts = (c) => new Date(c.recruit_start || c.deadline || c.created_at || 0).getTime();
  return camps.slice().sort((a, b) => {
    const sa = order[a.status] ?? 99;
    const sb = order[b.status] ?? 99;
    if (sa !== sb) return sa - sb;
    return ts(b) - ts(a);  // 최신순(내림차순)
  });
}

// 홈 화면에 노출할 카드 수 — 초과분은 「더보기」 버튼으로 캠페인 페이지로 이동
const HOME_CAMP_LIMIT = 10;

function updateStats(camps) {
  const visible = visibleCamps(camps);
  $('statCampaigns').textContent = visible.length;
  $('campCount').textContent = visible.length;
  $('statBrands').textContent = [...new Set(camps.map(c=>c.brand))].length;
  buildChannelFilters(visible);
}

// 채널 필터 탭 동적 생성
function buildChannelFilters(camps) {
  const row = $('filterRow');
  if (!row) return;
  const channels = [...new Set(camps.flatMap(c=>(c.channel||'').split(',').map(s=>s.trim())).filter(Boolean))];
  // lookup_values에서 라벨 가져오기 (없으면 코드 그대로)
  row.innerHTML = `<button class="chip on" onclick="filterCamps('all',this)">${t('campaign.channelAll')}</button>` +
    channels.map(ch => `<button class="chip" onclick="filterCamps('${ch}',this)">${esc(getChannelLabel(ch))}</button>`).join('');
}

// 캠페인 페이지 — 모집 유형 + 상태 + 검색 필터
let campPageStatusFilter = 'all';   // all | active | scheduled | closed
let campPageSearch = '';

async function loadCampaignsPage() {
  // 진입할 때마다 캠페인 데이터 새로고침 — 캐시(allCampaigns)에 의존하지 않음.
  // 사용자가 로고 클릭/화면 전환 시 새 데이터를 보고 싶다고 해서 도입.
  await loadCampaigns();
  campPageTypeFilter = 'all';
  campPageStatusFilter = 'all';
  campPageSearch = '';
  const searchEl = $('campPageSearch'); if (searchEl) searchEl.value = '';
  // 검색 폼 초기 상태: 닫힘 (제목 + 아이콘 노출)
  const searchWrap = $('campPageSearchWrap');
  const searchToggleBtn = $('campPageSearchToggle');
  const searchTitle = $('campPageTitle');
  if (searchWrap) searchWrap.style.display = 'none';
  if (searchToggleBtn) searchToggleBtn.style.display = 'inline-flex';
  if (searchTitle) searchTitle.style.display = '';
  // sticky 헤더 자동 숨김/노출 — 진입 시 노출 상태로 초기화 + 스크롤 리스너 1회 바인딩
  setupCampPageHeaderAutoHide();
  ['all','monitor','gifting','visit'].forEach(t => {
    const btn = $('campPageType-'+t);
    if (!btn) return;
    btn.style.color = t==='all'?'var(--pink)':'var(--muted)';
    btn.style.borderBottomColor = t==='all'?'var(--pink)':'transparent';
    btn.style.fontWeight = t==='all'?'700':'600';
  });
  // 상태 필터 칩 초기화
  document.querySelectorAll('[id^="campPageStatus-"]').forEach(c => c.classList.remove('on'));
  const allChip = $('campPageStatus-all'); if (allChip) allChip.classList.add('on');
  renderCampaignGrid();
}

function setCampPageType(type, el) {
  campPageTypeFilter = type;
  document.querySelectorAll('[id^="campPageType-"]').forEach(b => {
    b.style.color = 'var(--muted)'; b.style.borderBottomColor = 'transparent'; b.style.fontWeight = '600';
  });
  el.style.color = 'var(--pink)'; el.style.borderBottomColor = 'var(--pink)'; el.style.fontWeight = '700';
  renderCampaignGrid();
}

// 상태 칩 (전체 / 모집중 / 모집예정 / 모집완료)
function setCampPageStatus(status, el) {
  campPageStatusFilter = status;
  document.querySelectorAll('[id^="campPageStatus-"]').forEach(c => c.classList.remove('on'));
  if (el) el.classList.add('on');
  renderCampaignGrid();
}

// 캠페인 페이지 필터 영역만 자동 숨김/노출
//   제목/검색 행은 sticky로 항상 노출, 모집 유형 탭+상태 칩 영역만 collapse.
//   스크롤 컨테이너(.page.active = #page-campaigns) 방향 감지:
//     - 아래로 스크롤 → 필터 영역 max-height:0 + opacity:0 으로 접힘
//     - 위로 스크롤 → max-height:200px + opacity:1 로 복귀
//   loadCampaignsPage 진입 시 매번 호출되지만 데이터셋 가드로 리스너는 1회만 등록.
function setupCampPageHeaderAutoHide() {
  const page = $('page-campaigns');
  const filterArea = $('campPageFilterArea');
  if (!page || !filterArea) return;
  // 필터 영역 노출 상태로 초기화
  filterArea.style.maxHeight = '80px';
  filterArea.style.opacity = '1';
  if (page.dataset.scrollHideBound === '1') return;
  page.dataset.scrollHideBound = '1';
  let lastY = 0;
  let ticking = false;
  page.addEventListener('scroll', () => {
    if (ticking) return;
    ticking = true;
    requestAnimationFrame(() => {
      const y = page.scrollTop || 0;
      const diff = y - lastY;
      const HIDE_THRESHOLD = 80;
      if (y > HIDE_THRESHOLD && diff > 4) {
        // 아래로 스크롤 — 필터 접기
        filterArea.style.maxHeight = '0px';
        filterArea.style.opacity = '0';
      } else if (diff < -4 || y <= HIDE_THRESHOLD) {
        // 위로 스크롤 — 필터 펼침
        filterArea.style.maxHeight = '80px';
        filterArea.style.opacity = '1';
      }
      lastY = y;
      ticking = false;
    });
  }, { passive: true });
}

// 검색 — 검색 버튼 또는 엔터키 트리거 (실시간 검색 아님)
function onCampPageSearchSubmit() {
  const input = $('campPageSearch');
  campPageSearch = ((input?.value) || '').trim().toLowerCase();
  renderCampaignGrid();
}
// 하위호환: 외부에서 onCampPageSearchInput 호출되는 경로(혹시 모를)에 대비
function onCampPageSearchInput(value) {
  campPageSearch = (value || '').trim().toLowerCase();
  renderCampaignGrid();
}

// 검색 폼 토글 — 제목 행 자리에서 제목+🔍 ↔ 검색 input+✕ 모드 전환
//   force=undefined: 토글, force=true/false: 명시적 열림/닫힘
//   열림 모드: 제목/검색 아이콘 숨김, 검색 input + 닫기(✕) 노출
//   닫힘 모드: 검색 input/닫기 숨김, 제목 + 검색 아이콘 노출 (검색어 초기화)
function toggleCampPageSearch(force) {
  const wrap = $('campPageSearchWrap');
  const toggleBtn = $('campPageSearchToggle');
  const titleEl = $('campPageTitle');
  if (!wrap) return;
  const isOpen = wrap.style.display !== 'none' && wrap.style.display !== '';
  const next = (typeof force === 'boolean') ? force : !isOpen;
  wrap.style.display = next ? 'flex' : 'none';
  if (toggleBtn) toggleBtn.style.display = next ? 'none' : 'inline-flex';
  if (titleEl) titleEl.style.display = next ? 'none' : '';
  if (next) {
    const input = $('campPageSearch');
    if (input) setTimeout(() => input.focus(), 50);  // transition 후 포커스
  } else {
    // 닫기 시 검색어·결과 초기화
    const input = $('campPageSearch');
    if (input) input.value = '';
    if (campPageSearch) {
      campPageSearch = '';
      renderCampaignGrid();
    }
  }
}

function renderCampaignGrid() {
  const grid = $('campListGrid');
  if (!grid) return;
  let camps = visibleCamps(allCampaigns);
  if (campPageTypeFilter !== 'all') camps = camps.filter(c => c.recruit_type === campPageTypeFilter);
  if (campPageStatusFilter !== 'all') camps = camps.filter(c => c.status === campPageStatusFilter);
  if (campPageSearch) {
    camps = camps.filter(c => {
      const haystack = ((c.title||'') + ' ' + (c.brand||'') + ' ' + (c.brand_ko||'') + ' ' + (c.product||'') + ' ' + (c.product_ko||'') + ' ' + (c.campaign_no||'')).toLowerCase();
      return haystack.includes(campPageSearch);
    });
  }
  camps = sortByStatusAndDeadline(camps);
  if (!camps.length) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${t('campaign.emptyState')}</div><div class="empty-sub">${t('campaign.emptyStateSub')}</div></div>`;
    return;
  }
  grid.innerHTML = buildCampCards(camps);
}

function filterCampType(type, el) {
  currentTypeFilter = type;
  if (el) { document.querySelectorAll('#filterTypeRow .chip').forEach(c=>c.classList.remove('on')); el.classList.add('on'); }
  applyHomeFilter();
}

function filterCamps(filter, el) {
  currentFilter = filter;
  document.querySelectorAll('#filterRow .chip').forEach(c=>c.classList.remove('on'));
  el.classList.add('on');
  applyHomeFilter();
}

function applyHomeFilter() {
  let camps = visibleCamps(allCampaigns);
  if (currentTypeFilter !== 'all') camps = camps.filter(c=>c.recruit_type===currentTypeFilter);
  if (currentFilter !== 'all') camps = camps.filter(c=>{
    const chs = (c.channel||'').split(',').map(s=>s.trim());
    return chs.includes(currentFilter) || c.category===currentFilter;
  });
  // 정렬: 모집중 > 모집예정 > 모집완료, 같은 상태 안에서는 모집기간 종료일 최신순
  camps = sortByStatusAndDeadline(camps);
  renderCampaigns(camps);
}

function getCampBg(cat) {
  return '#E5E5E5';
}
function getCampGrad(cat) {
  return '#E5E5E5';
}

function buildCampCards(camps) {
  return camps.map(c => {
    const isFull = c.recruit_type === 'monitor' && (c.applied_count||0) >= c.slots;
    const isScheduled = c.status === 'scheduled';
    const isClosed = c.status === 'closed';
    const isActive = !isFull && !isScheduled && !isClosed;
    const isClickable = !isScheduled;
    const reward = c.reward > 0 ? t('campaign.rewardProduct').replace('{reward}',c.reward.toLocaleString()) : c.product_price > 0 ? t('campaign.rewardFreeStrong') : t('campaign.rewardFreeSimple');
    const isNew = !isScheduled && !isClosed && (Date.now()-new Date(c.created_at).getTime()) < 7*24*3600*1000;
    const bgGrad = getCampGrad(c.category);
    const typeLabel = getRecruitTypeLabelJa(c.recruit_type);
    const dimImage = isFull || isScheduled || isClosed;
    return `<div class="camp-card" onclick="${isClickable?'openCampaign(\''+c.id+'\')':''}" style="${!isClickable?'opacity:.85;cursor:default':''}">
      <div class="camp-img" style="background:${c.image_url?'#f0f0f0':bgGrad};position:relative">
        ${c.image_url?`<div style="position:absolute;inset:0;${dimImage?'filter:brightness(.5)':''}">${renderCroppedImg(c.image_url, (c.image_crops||{}).img1, {thumb:480, lazy:true})}</div>`:''}
        <div class="camp-img-overlay"></div>
        ${isScheduled?`<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:4"><span style="background:rgba(200,120,163,.9);color:#fff;font-size:12px;font-weight:700;padding:7px 18px;border-radius:20px;letter-spacing:.04em">${t('detail.scheduledOverlay')}</span></div>`:''}
        ${isClosed?`<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:4"><span style="background:rgba(0,0,0,.7);color:#fff;font-size:12px;font-weight:700;padding:7px 18px;border-radius:20px;letter-spacing:.04em">${t('detail.closedOverlay')}</span></div>`:''}
        ${isFull&&!isScheduled&&!isClosed?`<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:4"><span style="background:rgba(0,0,0,.7);color:#fff;font-size:12px;font-weight:700;padding:7px 18px;border-radius:20px;letter-spacing:.04em">${t('detail.fullOverlay')}</span></div>`:''}
        <div class="camp-badges" style="z-index:5;position:absolute;top:8px;left:8px;right:8px;display:flex;justify-content:space-between;align-items:center;gap:4px">
          <span style="${isActive?'background:#E2F0E9;color:#0E7E4A;font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px':'visibility:hidden'}">${isActive?t('campaign.badgeRecruiting'):''}</span>
          ${isNew&&!isFull?`<span style="background:var(--pink);color:#fff;font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px">${t('campaign.badgeNew')}</span>`:''}
        </div>
        <div class="camp-ch-badge" style="z-index:3;top:auto;bottom:8px;right:auto;left:8px">${esc(getChannelLabel((c.channel||'').split(',')[0].trim()))}${(c.channel||'').split(',').filter(Boolean).length>1?` <span style="opacity:.7">+${(c.channel||'').split(',').filter(Boolean).length-1}</span>`:''}</div>
      </div>
      <div class="camp-body">
        <div class="camp-brand">${esc(c.brand)}</div>
        ${typeLabel ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin:2px 0">${esc(typeLabel)}</div>` : ''}
        <div class="camp-title">${esc(c.title)}</div>
        ${c.content_types ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:4px">${c.content_types.split(',').map(t=>`<span style="font-size:10px;background:var(--light-pink);color:var(--dark-pink);padding:2px 8px;border-radius:20px;font-weight:600">${esc(getLookupLabel('content_type', t.trim()))}</span>`).join('')}</div>` : ''}
        ${(() => {
          // 締切間近 + {applied}/{slots}名 — 콘텐츠 종류 아래 (진행중 캠페인만)
          if (!isActive) return '';
          const flags = [];
          let urgent = false;
          if (c.deadline) {
            const diffDays = Math.ceil((new Date(c.deadline) - new Date()) / (1000*60*60*24));
            if (diffDays >= 0 && diffDays < 5) urgent = true;
          }
          const slots = c.slots || 0;
          const applied = c.applied_count || 0;
          const remaining = slots - applied;
          if (slots > 0 && remaining > 0 && remaining / slots <= 0.3) urgent = true;
          if (urgent) flags.push(`<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px">${t('campaign.badgeUrgent')}</span>`);
          if (slots > 0) flags.push(`<span style="background:#F5F5F5;color:#555;font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px">${t('campaign.slotFormat').replace('{applied}',applied).replace('{slots}',slots)}</span>`);
          return flags.length ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:6px">${flags.join('')}</div>` : '';
        })()}
      </div>
      <div class="camp-footer"><div class="camp-reward"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">redeem</span> ${reward}</div></div>
    </div>`;
  }).join('');
}

function renderCampaigns(camps) {
  const grid = $('campGrid');
  if (!grid) return;
  // 호출처에서 이미 visibleCamps + sortByStatusAndDeadline 한 결과를 넘기지만,
  // applyHomeFilter 외 경로(예: 초기 home 진입)에서도 안전하도록 한 번 더 정렬한다
  const visible = sortByStatusAndDeadline(visibleCamps(camps));
  const moreBtnWrap = $('campMoreBtnWrap');
  if (!visible.length) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${t('campaign.emptyState')}</div><div class="empty-sub">${t('campaign.emptyStateSub')}</div></div>`;
    if (moreBtnWrap) moreBtnWrap.style.display = 'none';
    return;
  }
  // 홈 화면은 최대 HOME_CAMP_LIMIT(10건)만 노출 — 초과분은 「더보기」 버튼으로 캠페인 페이지 이동
  const sliced = visible.slice(0, HOME_CAMP_LIMIT);
  grid.innerHTML = buildCampCards(sliced);
  if (moreBtnWrap) moreBtnWrap.style.display = visible.length > HOME_CAMP_LIMIT ? '' : 'none';
}
