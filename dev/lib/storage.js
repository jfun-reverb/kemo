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
    return (data && data.length > 0) ? data : DEMO_CAMPAIGNS.slice();
  } catch(e) {
    return DEMO_CAMPAIGNS.slice();
  }
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
