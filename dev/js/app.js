// ══════════════════════════════════════
// NAVIGATION + INIT
// ══════════════════════════════════════

function navigate(page) {
  // 管理者ページはappShell外 — 別処理
  const appShell = $('appShell');
  const adminPage = $('page-admin');

  if (page === 'admin') {
    if (appShell) appShell.style.display = 'none';
    if (adminPage) { adminPage.classList.add('active'); adminPage.style.display = 'block'; }
    document.body.style.background = '#F8F5F8';
    loadAdminData();
    return;
  }

  // インフルエンサーページ: appShell表示、admin非表示
  if (appShell) appShell.style.display = '';
  if (adminPage) { adminPage.classList.remove('active'); adminPage.style.display = 'none'; }
  document.body.style.background = '#E8E0EC';

  document.querySelectorAll('#appShell .page').forEach(p => p.classList.remove('active'));
  const el = $('page-'+page);
  if (el) el.classList.add('active');
  var _sh = $('appShell'); if(_sh) _sh.scrollTo(0,0); else window.scrollTo(0,0);

  // フロートバー: detail以外では非表示
  const fb = $('detailFloatBar');
  if (fb && page !== 'detail') fb.style.display = 'none';

  // ボトムタブバー: login/signupでは非表示
  const tabBar = $('bottomTabBar');
  if (tabBar) {
    tabBar.style.display = ['login','signup'].includes(page) ? 'none' : 'flex';
  }
  updateTabBar(page);

  if (page === 'home') loadCampaigns();
  if (page === 'campaigns') loadCampaignsPage();
  if (page === 'mypage') {
    if (!currentUser) { navigate('login'); return; }
    loadMyPage();
  }
}

function navigateTab(page, el) {
  if (page === 'mypage' && !currentUser) { navigate('login'); return; }
  navigate(page);
}

function updateTabBar(page) {
  const map = {home:'tab-home',detail:'tab-home',mypage:'tab-mypage',campaigns:'tab-camp'};
  document.querySelectorAll('.tab-item').forEach(t=>t.classList.remove('on'));
  const activeEl = $(map[page]||'tab-home');
  if (activeEl) activeEl.classList.add('on');
}

// ══════════════════════════════════════
// INIT
// ══════════════════════════════════════
async function init() {
  // キャンペーン先にロード (demo data)
  allCampaigns = demoGetCampaigns();
  renderCampaigns(allCampaigns);
  updateStats(allCampaigns);
  // Restore session
  if (DEMO_MODE) {
    const sess = localStorage.getItem(DEMO_SESSION_KEY);
    if (sess) {
      const {id,email} = JSON.parse(sess);
      currentUser = {id,email};
      if (email===ADMIN_EMAIL) {
        currentUserProfile = {name:'管理者',email};
      } else {
        const users = demoGetUsers();
        currentUserProfile = users.find(u=>u.id===id)||null;
      }
    }
  } else {
    const {data:{session}} = await (db?.auth.getSession() || {data:{session:null}});
    if (session) {
      currentUser = session.user;
      const {data:profile} = await db?.from('influencers').select('*').eq('id',currentUser.id).maybeSingle();
      currentUserProfile = profile;
    }
  }
  updateGnb();
  await loadCampaigns();
}

document.addEventListener('DOMContentLoaded', function() {
  allCampaigns = DEMO_CAMPAIGNS.slice();
  var active = allCampaigns.filter(function(c){ return c.status !== 'closed'; });
  renderCampaigns(active);
  updateStats(allCampaigns);
  init();
  // scroll to top
  var _sh=$('appShell');if(_sh)_sh.scrollTop=0;else window.scrollTo(0,0);
});
