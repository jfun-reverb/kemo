// ══════════════════════════════════════
// CAMPAIGNS — 목록, 상세, 필터
// ══════════════════════════════════════

let currentUser = null;
let currentUserProfile = null;
let currentCampaignId = null;
let allCampaigns = [];
let currentFilter = 'all';
let campPageTypeFilter = 'all';
let currentTypeFilter = 'all';

// ── 기본 캠페인 데이터 (DB가 비어있을 때 표시됨) ──
const DEMO_CAMPAIGNS = [
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

function updateStats(camps) {
  const active = camps.filter(c=>c.status==='active');
  $('statCampaigns').textContent = active.length;
  $('campCount').textContent = active.length;
  $('statBrands').textContent = [...new Set(camps.map(c=>c.brand))].length;
}

async function loadCampaignsPage() {
  if (!allCampaigns || allCampaigns.length === 0) await loadCampaigns();
  campPageTypeFilter = 'all';
  ['all','monitor','gifting'].forEach(t => {
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
  let camps = allCampaigns.filter(c => c.status === 'active');
  if (campPageTypeFilter === 'monitor') camps = camps.filter(c => c.recruit_type === 'monitor');
  else if (campPageTypeFilter === 'gifting') camps = camps.filter(c => c.recruit_type === 'gifting');
  camps = camps.sort((a,b) => {
    if (a.order_index != null && b.order_index != null) return a.order_index - b.order_index;
    return new Date(b.created_at) - new Date(a.created_at);
  });
  if (!camps.length) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1"><div class="empty-icon">📋</div><div class="empty-text">現在開催中のキャンペーンはありません</div><div class="empty-sub">近日中に新しいKブランド体験団が登録されます</div></div>`;
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
  let camps = allCampaigns.filter(c=>c.status==='active');
  camps = camps.sort((a,b) => {
    if (a.order_index != null && b.order_index != null) return a.order_index - b.order_index;
    return new Date(b.created_at) - new Date(a.created_at);
  });
  if (currentTypeFilter !== 'all') camps = camps.filter(c=>c.recruit_type===currentTypeFilter);
  if (currentFilter !== 'all') camps = camps.filter(c=>c.channel===currentFilter||c.category===currentFilter);
  renderCampaigns(camps);
}

function getCampBg(cat) {
  const m={beauty:'#FFF5F5',food:'#FFFBEB',fashion:'#F5F0FF',health:'#F0FBF5',other:'#F6F6FA'};
  return m[cat]||'#F6F6FA';
}
function getCampGrad(cat) {
  const m={
    beauty:'linear-gradient(135deg,#F7D0E8 0%,#C878A3 100%)',
    food:'linear-gradient(135deg,#FFE4B5 0%,#E8A87C 100%)',
    fashion:'linear-gradient(135deg,#D4C5F9 0%,#8B5CF6 100%)',
    health:'linear-gradient(135deg,#B7F3D8 0%,#059669 100%)',
    other:'linear-gradient(135deg,#E0B8CA 0%,#56475D 100%)'
  };
  return m[cat]||m.other;
}

function buildCampCards(camps) {
  return camps.map(c => {
    const isFull = (c.applied_count||0) >= c.slots;
    const reward = c.reward > 0 ? `製品 + <strong>¥${c.reward.toLocaleString()}</strong>` : c.product_price > 0 ? `<strong>製品無償提供</strong>` : '<strong>無償提供</strong>';
    const isNew = (Date.now()-new Date(c.created_at).getTime()) < 7*24*3600*1000;
    const bgGrad = getCampGrad(c.category);
    const typeLabel = c.recruit_type==='monitor'?'Reviewer':c.recruit_type==='gifting'?'Gifting':'';
    return `<div class="camp-card" onclick="openCampaign('${c.id}')">
      <div class="camp-img" style="background:${c.image_url?'#f0f0f0':bgGrad};position:relative">
        ${c.image_url?`<img src="${c.image_url}" style="width:100%;height:100%;object-fit:cover;position:absolute;inset:0;${isFull?'filter:brightness(.4)':''}" onerror="this.style.display='none'">`:''}
        <div class="camp-img-overlay"></div>
        ${isFull?`<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;z-index:4"><span style="background:rgba(0,0,0,.7);color:#fff;font-size:12px;font-weight:700;padding:7px 18px;border-radius:20px;letter-spacing:.04em">募集終了</span></div>`:''}
        <div class="camp-badges" style="z-index:5;position:absolute;top:8px;left:8px;display:flex;gap:4px">
          ${isNew&&!isFull?'<span style="background:var(--pink);color:#fff;font-size:9px;font-weight:700;padding:2px 8px;border-radius:20px">NEW</span>':''}
          ${typeLabel&&!isFull?`<span style="background:rgba(255,255,255,.9);color:var(--pink);font-size:9px;font-weight:700;padding:2px 8px;border-radius:20px">${typeLabel}</span>`:''}
        </div>
        ${!isFull?`<div style="position:absolute;bottom:8px;left:8px;display:flex;gap:3px;flex-wrap:wrap;z-index:3;max-width:calc(100% - 16px)">${(c.content_types||getChannelLabel(c.channel)).split(',').map(t=>`<span style="background:rgba(0,0,0,.55);color:#fff;font-size:9px;font-weight:700;padding:2px 7px;border-radius:20px;backdrop-filter:blur(4px);white-space:nowrap">${t.trim()}</span>`).join('')}</div>`:''}
        <div class="camp-ch-badge" style="z-index:3">${getChannelLabel(c.channel)}</div>
      </div>
      <div class="camp-body">
        <div class="camp-brand">${c.brand}</div>
        <div class="camp-title">${c.title}</div>
        ${c.content_types ? `<div style="display:flex;gap:4px;flex-wrap:wrap;margin-top:4px">${c.content_types.split(',').map(t=>`<span style="font-size:10px;background:var(--light-pink);color:var(--dark-pink);padding:2px 8px;border-radius:20px;font-weight:600">${t.trim()}</span>`).join('')}</div>` : ''}
      </div>
      <div class="camp-footer"><div class="camp-reward">🎁 ${reward}</div></div>
    </div>`;
  }).join('');
}

function renderCampaigns(camps) {
  const grid = $('campGrid');
  if (!grid) return;
  const active = camps.filter(c=>c.status==='active').sort((a,b)=>{
    if (a.order_index!=null&&b.order_index!=null) return a.order_index-b.order_index;
    return new Date(b.created_at)-new Date(a.created_at);
  });
  if (!active.length) {
    grid.innerHTML = `<div class="empty-state" style="grid-column:1/-1"><div class="empty-icon">📋</div><div class="empty-text">現在開催中のキャンペーンはありません</div><div class="empty-sub">近日中に新しいKブランド体験団が登録されます</div></div>`;
    return;
  }
  grid.innerHTML = buildCampCards(active);
}
