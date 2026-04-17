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
  {id:'demo-3',recruit_type:'monitor',title:'DR.G クッションファンデ体験団',brand:'DR.G · ドクタージー',product:'レッドブレミッシュクッション',type:'nano',channel:'instagram',category:'beauty',emoji:'💄',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018580206.jpg',product_price:3800,reward:1000,slots:15,applied_count:9,deadline:'2026-06-01',post_days:14,content_types:'インスタ/フィード,インスタ/リール,インスタ/ストーリー',description:'DR.Gの人気クッションファンデーションを体験していただける方を募集！リワード¥1,000付き。',hashtags:'#drg #ドクタージー #クッションファンデ #韓国コスメ',mentions:'@drg_japan',appeal:'赤みをカバーしながら素肌感を演出。SPF50+PA+++で紫外線対策も。',guide:'使用前後のビフォーアフターが伝わる投稿。明るい自然光での撮影推奨。',ng:'過度なフィルター加工NG。競合製品との比較NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-4',recruit_type:'gifting',title:'MEDIHEAL マスクパック体験団',brand:'MEDIHEAL · メディヒール',product:'TEAトゥリーケアマスクパック 10枚',type:'nano',channel:'instagram',category:'beauty',emoji:'🩺',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0014/A00000014060204.jpg',product_price:2000,reward:0,slots:30,applied_count:22,deadline:'2026-05-20',post_days:7,content_types:'インスタ/フィード,TikTok',description:'MEDIHEALのTEAトゥリーマスクパックを体験していただける方を募集します。',hashtags:'#mediheal #メディヒール #マスクパック #スキンケア',mentions:'@mediheal_japan',appeal:'ティーツリー成分が肌トラブルをケア。毛穴引き締め効果も。',guide:'着用中・着用後の自然な表情を撮影。朝・夜のスキンケアシーンに合わせてください。',ng:'加工しすぎた写真NG。マスク着用以外の用途での撮影NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-5',recruit_type:'gifting',title:'PERIPERA リップ体験団',brand:'PERIPERA · ペリペラ',product:'インクムードグロウティント',type:'nano',channel:'instagram',category:'beauty',emoji:'💋',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0018/A00000018133201.jpg',product_price:1500,reward:500,slots:20,applied_count:15,deadline:'2026-05-31',post_days:7,content_types:'インスタ/リール,TikTok',description:'PERIPERAの人気リップを体験！リワード¥500付き。カラー発色が美しいグロウティントです。',hashtags:'#peripera #ペリペラ #リップ #韓国コスメ #Kビューティ',mentions:'@peripera_japan',appeal:'ウォータリーなテクスチャーで唇に密着。鮮やかな発色が長時間持続。',guide:'リップスウォッチや着用シーンを撮影。明るい照明で発色が伝わるように。',ng:'口元以外の過度なフィルターNG。競合リップとの比較NG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'},
  {id:'demo-6',recruit_type:'gifting',title:'BIBIGO 餃子 Qoo10体験団',brand:'CJ BIBIGO · ビビゴ',product:'王餃子 420g',type:'qoo10',channel:'qoo10',category:'food',emoji:'🥟',image_url:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',img1:'https://image.oliveyoung.co.kr/cfimages/cf-goods/uploads/images/thumbnails/10/0000/0020/A00000020087901.jpg',product_price:1200,reward:2000,slots:10,applied_count:7,deadline:'2026-06-15',post_days:10,content_types:'インスタ/フィード,X投稿',description:'BIBIGOの人気王餃子をQoo10でレビュー！リワード¥2,000付き。',hashtags:'#bibigo #ビビゴ #王餃子 #韓国フード #Qoo10',mentions:'@bibigo_japan',appeal:'本場韓国の味をそのままに。もちもちの皮と旨味たっぷりの肉あん。',guide:'調理過程・完成品を美しく撮影。食欲をそそるシズル感を大切に。',ng:'他社冷凍食品との比較NG。料理以外での使用シーンNG。',status:'active',created_at:'2026-04-01T00:00:00.000Z'}
];

async function loadCampaigns() {
  allCampaigns = await fetchCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);
}

// 인플루언서에게 보이는 캠페인: 모집중 + 모집예정 + 모집마감(게시기한 남음)
function visibleCamps(camps) {
  const now = new Date(); now.setHours(0,0,0,0);
  return camps.filter(c => {
    if (c.status === 'active' || c.status === 'scheduled') return true;
    if (c.status === 'closed' && c.post_deadline) {
      const pd = new Date(c.post_deadline); pd.setHours(23,59,59,999);
      return now <= pd;
    }
    return false;
  });
}

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

async function loadCampaignsPage() {
  if (!allCampaigns || allCampaigns.length === 0) await loadCampaigns();
  campPageTypeFilter = 'all';
  ['all','monitor','gifting','visit'].forEach(t => {
    const btn = $('campPageType-'+t);
    if (!btn) return;
    btn.style.color = t==='all'?'var(--pink)':'var(--muted)';
    btn.style.borderBottomColor = t==='all'?'var(--pink)':'transparent';
    btn.style.fontWeight = t==='all'?'700':'600';
  });
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

function renderCampaignGrid() {
  const grid = $('campListGrid');
  if (!grid) return;
  let camps = visibleCamps(allCampaigns);
  if (campPageTypeFilter !== 'all') camps = camps.filter(c => c.recruit_type === campPageTypeFilter);
  camps = camps.sort((a,b) => {
    if (a.order_index != null && b.order_index != null) return a.order_index - b.order_index;
    return new Date(b.created_at) - new Date(a.created_at);
  });
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
  camps = camps.sort((a,b) => {
    if (a.order_index != null && b.order_index != null) return a.order_index - b.order_index;
    return new Date(b.created_at) - new Date(a.created_at);
  });
  if (currentTypeFilter !== 'all') camps = camps.filter(c=>c.recruit_type===currentTypeFilter);
  if (currentFilter !== 'all') camps = camps.filter(c=>{
    const chs = (c.channel||'').split(',').map(s=>s.trim());
    return chs.includes(currentFilter) || c.category===currentFilter;
  });
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
        <div class="camp-badges" style="z-index:5;position:absolute;top:8px;left:8px;display:flex;gap:4px">
          ${isNew&&!isFull?`<span style="background:var(--pink);color:#fff;font-size:9px;font-weight:700;padding:2px 8px;border-radius:20px">${t('campaign.badgeNew')}</span>`:''}
        </div>
        <div class="camp-ch-badge" style="z-index:3;top:auto;bottom:8px;right:auto;left:8px">${esc(getChannelLabel((c.channel||'').split(',')[0].trim()))}${(c.channel||'').split(',').filter(Boolean).length>1?` <span style="opacity:.7">+${(c.channel||'').split(',').filter(Boolean).length-1}</span>`:''}</div>
      </div>
      <div class="camp-body">
        ${(() => {
          // 마감임박 배지 + 응모 진행 (제목 위, 진행중 캠페인만)
          if (isFull || isScheduled || isClosed) return '';
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
          return flags.length ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-bottom:4px">${flags.join('')}</div>` : '';
        })()}
        <div class="camp-brand">${esc(c.brand)}</div>
        ${typeLabel ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin:2px 0">${esc(typeLabel)}</div>` : ''}
        <div class="camp-title">${esc(c.title)}</div>
        ${c.content_types ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:4px">${c.content_types.split(',').map(t=>`<span style="font-size:10px;background:var(--light-pink);color:var(--dark-pink);padding:2px 8px;border-radius:20px;font-weight:600">${esc(getLookupLabel('content_type', t.trim()))}</span>`).join('')}</div>` : ''}
        ${(() => {
          // 모집중 상태 배지 — 콘텐츠 종류 아래 (모집타입은 제목 위 라벨로 이동)
          if (isFull || isScheduled || isClosed) return '';
          return `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:6px"><span style="background:rgba(14,126,74,.12);color:#0E7E4A;font-size:10px;font-weight:700;padding:2px 8px;border-radius:20px">${t('campaign.badgeRecruiting')}</span></div>`;
        })()}
      </div>
      <div class="camp-footer"><div class="camp-reward"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">redeem</span> ${reward}</div></div>
    </div>`;
  }).join('');
}

function renderCampaigns(camps) {
  const grid = $('campGrid');
  if (!grid) return;
  const visible = visibleCamps(camps).sort((a,b)=>{
    if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
    return new Date(b.created_at)-new Date(a.created_at);
  });
  if (!visible.length) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${t('campaign.emptyState')}</div><div class="empty-sub">${t('campaign.emptyStateSub')}</div></div>`;
    return;
  }
  grid.innerHTML = buildCampCards(visible);
}
