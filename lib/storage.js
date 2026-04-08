// ══════════════════════════════════════
// STORAGE — Supabase API 호출 함수 모음
// localStorage는 세션 캐시에만 사용
// ══════════════════════════════════════
const DEMO_SESSION_KEY = 'kemo_session';

// ── Campaigns ──
async function fetchCampaigns() {
  if (!db) return DEMO_CAMPAIGNS.slice();
  try {
    const {data, error} = await db.from('campaigns').select('*').order('order_index', {ascending: true, nullsFirst: false});
    if (error) throw error;
    if (data && data.length > 0) { await autoCloseCampaigns(data); return data; }
    return DEMO_CAMPAIGNS.slice();
  } catch(e) {
    return DEMO_CAMPAIGNS.slice();
  }
}

// 마감일 경과 캠페인 자동 상태 변경
async function autoCloseCampaigns(camps) {
  if (!db) return camps;
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  for (const c of camps) {
    if (c.status === 'active' && c.deadline) {
      const dl = new Date(c.deadline);
      dl.setHours(23, 59, 59, 999);
      if (now > dl) {
        c.status = 'closed';
        await db.from('campaigns').update({ status: 'closed' }).eq('id', c.id).then(() => {});
      }
    }
  }
  return camps;
}

async function insertCampaign(camp) {
  if (!db) return;
  const {error} = await db.from('campaigns').insert(camp);
  if (error) throw error;
}

async function updateCampaign(campId, updates) {
  if (!db) return;
  const {error} = await db.from('campaigns').update(updates).eq('id', campId);
  if (error) throw error;
}

async function incrementViewCount(campId) {
  if (!db) return;
  const {data} = await db.from('campaigns').select('view_count').eq('id', campId).maybeSingle();
  const current = (data?.view_count) || 0;
  await db.from('campaigns').update({ view_count: current + 1 }).eq('id', campId);
}

// ── Influencers ──
async function fetchInfluencers() {
  if (!db) return [];
  try {
    const {data, error} = await db.from('influencers').select('*');
    if (error) throw error;
    return data || [];
  } catch(e) {
    return [];
  }
}

async function upsertInfluencer(profile) {
  if (!db) return;
  const {error} = await db.from('influencers').upsert(profile);
  if (error) throw error;
}

async function updateInfluencer(userId, updates) {
  if (!db) return;
  const {error} = await db.from('influencers').update(updates).eq('id', userId);
  if (error) throw error;
}

// ── Applications ──
async function fetchApplications(filters) {
  if (!db) return [];
  try {
    let query = db.from('applications').select('*');
    if (filters?.campaign_id) query = query.eq('campaign_id', filters.campaign_id);
    if (filters?.user_id) query = query.eq('user_id', filters.user_id);
    if (filters?.status) query = query.eq('status', filters.status);
    query = query.order('created_at', {ascending: false});
    const {data, error} = await query;
    if (error) throw error;
    return data || [];
  } catch(e) {
    return [];
  }
}

async function insertApplication(app) {
  if (!db) return;
  const {error} = await db.from('applications').insert(app);
  if (error) throw error;
}

async function updateApplication(appId, updates) {
  if (!db) return;
  const {error} = await db.from('applications').update(updates).eq('id', appId);
  if (error) throw error;
}

async function checkDuplicateApplication(userId, campaignId) {
  if (!db) return false;
  const {data} = await db.from('applications').select('id').eq('user_id', userId).eq('campaign_id', campaignId).maybeSingle();
  return !!data;
}

// ── Image Storage ──
// base64를 Supabase Storage에 업로드하고 공개 URL 반환
async function uploadImage(base64Data, fileName) {
  if (!db) return base64Data;
  // base64 → Blob 변환
  var parts = base64Data.split(',');
  var mime = parts[0].match(/:(.*?);/)[1];
  var binary = atob(parts[1]);
  var arr = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
  var blob = new Blob([arr], {type: mime});
  // 파일 경로: campaigns/타임스탬프_파일명
  var ext = mime.split('/')[1] === 'jpeg' ? 'jpg' : mime.split('/')[1];
  var path = 'campaigns/' + Date.now() + '_' + Math.random().toString(36).substring(2, 8) + '.' + ext;
  var {error} = await db.storage.from('campaign-images').upload(path, blob, {contentType: mime, upsert: false});
  if (error) throw error;
  // 공개 URL 반환
  var {data} = db.storage.from('campaign-images').getPublicUrl(path);
  return data.publicUrl;
}

// 이미지 배열(base64)을 Storage에 업로드하고 URL 배열 반환
async function uploadCampImages(imgList) {
  var urls = [];
  for (var i = 0; i < Math.min(imgList.length, 8); i++) {
    var img = imgList[i];
    if (!img || !img.data) { urls.push(''); continue; }
    // 이미 URL이면 그대로 사용
    if (img.data.startsWith('http')) { urls.push(img.data); continue; }
    // base64면 업로드
    try {
      var url = await uploadImage(img.data, img.name || 'img' + i);
      urls.push(url);
    } catch(e) {
      urls.push('');
    }
  }
  // 8개 슬롯 채우기
  while (urls.length < 8) urls.push('');
  return urls;
}
