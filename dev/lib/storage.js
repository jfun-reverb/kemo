// ══════════════════════════════════════
// STORAGE — localStorage ラッパー
// ══════════════════════════════════════
const DEMO_USERS_KEY = 'kemo_users';
const DEMO_SESSION_KEY = 'kemo_session';
const DEMO_APPS_KEY = 'kemo_applications';

function demoGetUsers() { return JSON.parse(localStorage.getItem(DEMO_USERS_KEY)||'[]'); }
function demoSaveUsers(u) { localStorage.setItem(DEMO_USERS_KEY, JSON.stringify(u)); }
function demoGetApps() { return JSON.parse(localStorage.getItem(DEMO_APPS_KEY)||'[]'); }
function demoSaveApps(a) { localStorage.setItem(DEMO_APPS_KEY, JSON.stringify(a)); }
function demoGetCampaigns() {
  const mem = window._memCamps || [];
  const custom = [...JSON.parse(localStorage.getItem('kemo_campaigns')||'[]'), ...mem];
  return [...DEMO_CAMPAIGNS, ...custom];
}
function demoSaveCampaign(camp) {
  try {
    const custom = JSON.parse(localStorage.getItem('kemo_campaigns')||'[]');
    const imgs = {img1:camp.img1,img2:camp.img2,img3:camp.img3,img4:camp.img4,
                  img5:camp.img5,img6:camp.img6,img7:camp.img7,img8:camp.img8};
    const campLight = {...camp, img1:'',img2:'',img3:'',img4:'',img5:'',img6:'',img7:'',img8:''};
    try { localStorage.setItem('kemo_img_'+camp.id, JSON.stringify(imgs)); } catch(e) {
      campLight.image_url = '';
    }
    custom.push(campLight);
    localStorage.setItem('kemo_campaigns', JSON.stringify(custom));
  } catch(e) {
    if (!window._memCamps) window._memCamps = [];
    window._memCamps.push(camp);
  }
}
