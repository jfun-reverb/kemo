// ══════════════════════════════════════
// STORAGE — Supabase API 호출 함수 모음
// localStorage는 세션 캐시에만 사용
// ══════════════════════════════════════
const DEMO_SESSION_KEY = 'kemo_session';

// 세션 만료 시 자동 갱신 후 재시도
async function retryWithRefresh(fn) {
  try {
    return await fn();
  } catch(e) {
    if ((e.message?.includes('row-level security') || e.message?.includes('JWT expired')) && db) {
      const {error} = await db.auth.refreshSession();
      if (!error) return await fn();
    }
    throw e;
  }
}

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
  await retryWithRefresh(async () => {
    const {error} = await db.from('campaigns').insert(camp);
    if (error) throw error;
  });
}

async function updateCampaign(campId, updates) {
  if (!db) return;
  await retryWithRefresh(async () => {
    const {error} = await db.from('campaigns').update(updates).eq('id', campId);
    if (error) throw error;
  });
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
  await retryWithRefresh(async () => {
    const {error} = await db.from('influencers').upsert(profile);
    if (error) throw error;
  });
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
  await retryWithRefresh(async () => {
    const {error} = await db.from('applications').insert(app);
    if (error) throw error;
  });
}

async function updateApplication(appId, updates) {
  if (!db) return;
  await retryWithRefresh(async () => {
    const {error} = await db.from('applications').update(updates).eq('id', appId);
    if (error) throw error;
  });
}

async function checkDuplicateApplication(userId, campaignId) {
  if (!db) return false;
  const {data} = await db.from('applications').select('id').eq('user_id', userId).eq('campaign_id', campaignId).maybeSingle();
  return !!data;
}

// ── Receipts ──
async function fetchReceipts(filters) {
  if (!db) return [];
  try {
    let query = db.from('receipts').select('*');
    if (filters?.application_id) query = query.eq('application_id', filters.application_id);
    if (filters?.user_id) query = query.eq('user_id', filters.user_id);
    if (filters?.campaign_id) query = query.eq('campaign_id', filters.campaign_id);
    query = query.order('created_at', {ascending: false});
    const {data, error} = await query;
    if (error) throw error;
    return data || [];
  } catch(e) { return []; }
}

async function insertReceipt(receipt) {
  if (!db) return;
  await retryWithRefresh(async () => {
    const {error} = await db.from('receipts').insert(receipt);
    if (error) throw error;
  });
}

// ── Deliverables (Stage 2) ──
// 관리자용: 결과물 리스트 + 캠페인/인플루언서 정보 조인
async function fetchDeliverables(filters) {
  if (!db) return [];
  try {
    let query = db?.from('deliverables').select(`
      id, kind, status, version,
      receipt_url, purchase_date, purchase_amount, memo,
      post_url, post_channel, post_submissions,
      reject_reason, reject_template_code,
      reviewed_by, reviewed_at, submitted_at, updated_at,
      application_id, user_id, campaign_id,
      campaigns:campaign_id (id, title, brand, recruit_type),
      influencers:user_id (id, name, name_kana, email)
    `);
    if (filters?.status && filters.status !== 'all') query = query.eq('status', filters.status);
    if (filters?.kind && filters.kind !== 'all') query = query.eq('kind', filters.kind);
    if (filters?.campaign_id && filters.campaign_id !== 'all') query = query.eq('campaign_id', filters.campaign_id);
    query = query.order('submitted_at', {ascending: true});
    const {data, error} = await query;
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchDeliverables]', e); return []; }
}

async function fetchDeliverableById(id) {
  if (!db) return null;
  try {
    const {data, error} = await db?.from('deliverables').select(`
      *,
      campaigns:campaign_id (id, title, brand, recruit_type, channel, channel_match, img1),
      influencers:user_id (id, name, name_kana, email, primary_sns)
    `).eq('id', id).maybeSingle();
    if (error) throw error;
    return data || null;
  } catch(e) { console.error('[fetchDeliverableById]', e); return null; }
}

async function fetchDeliverableEvents(deliverableId) {
  if (!db) return [];
  try {
    const {data, error} = await db?.from('deliverable_events').select('*')
      .eq('deliverable_id', deliverableId)
      .order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { return []; }
}

// 낙관적 락: update_deliverable_status RPC 호출. 반환 -1=충돌, >0=새 version
async function updateDeliverableStatus(id, newStatus, expectedVersion, reason, templateCode) {
  if (!db) return -1;
  let ret = -1;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('update_deliverable_status', {
      p_id: id,
      p_new_status: newStatus,
      p_expected_version: expectedVersion,
      p_reason: reason || null,
      p_template_code: templateCode || null
    });
    if (error) throw error;
    ret = typeof data === 'number' ? data : -1;
  });
  return ret;
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
    // base64면 업로드 — 실패 시 throw (silent-fail 방지: 빈 URL이 DB에 저장되는 사고 차단)
    var url = await uploadImage(img.data, img.name || 'img' + i);
    urls.push(url);
  }
  // 8개 슬롯 채우기
  while (urls.length < 8) urls.push('');
  return urls;
}

// ══════════════════════════════════════
// LOOKUP VALUES — 채널/카테고리/콘텐츠/NG 프리셋 통합
// ══════════════════════════════════════

// 메모리 캐시 (kind별 분리). 변경 시 invalidate 필요
const _lookupCache = {};

function invalidateLookupCache(kind) {
  if (kind) delete _lookupCache[kind]; else for (const k in _lookupCache) delete _lookupCache[k];
}

// 활성 항목만 (캠페인 등록/인플루언서 페이지용)
async function fetchLookups(kind) {
  if (!db) return [];
  if (_lookupCache[kind]) return _lookupCache[kind];
  const {data, error} = await db.from('lookup_values')
    .select('*')
    .eq('kind', kind)
    .eq('active', true)
    .order('sort_order', {ascending: true});
  if (error) throw error;
  _lookupCache[kind] = data || [];
  return _lookupCache[kind];
}

// 전체 (관리자 페이지 — 비활성도 포함)
async function fetchLookupsAll(kind) {
  if (!db) return [];
  const {data, error} = await db.from('lookup_values')
    .select('*')
    .eq('kind', kind)
    .order('sort_order', {ascending: true});
  if (error) throw error;
  return data || [];
}

// 한국어/일본어 명칭에서 영문 슬러그 자동 생성
function generateLookupCode(name_ko, name_ja, kind) {
  const base = (name_ko || name_ja || '').toString().trim().toLowerCase();
  // 영문/숫자만 추출
  const ascii = base.replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  if (ascii && ascii.length > 1) return ascii.slice(0, 40);
  // 한글/일본어만 있는 경우 랜덤 슬러그
  return (kind || 'item') + '-' + Math.random().toString(36).slice(2, 8);
}

async function insertLookup(row) {
  let result;
  await retryWithRefresh(async () => {
    const code = row.code || generateLookupCode(row.name_ko, row.name_ja, row.kind);
    // 다음 sort_order 결정 (현재 max + 10)
    const existing = await fetchLookupsAll(row.kind);
    const maxOrder = existing.reduce((m, r) => Math.max(m, r.sort_order || 0), 0);
    const payload = {
      kind: row.kind,
      code,
      name_ko: row.name_ko,
      name_ja: row.name_ja,
      sort_order: row.sort_order != null ? row.sort_order : maxOrder + 10,
      active: row.active != null ? row.active : true
    };
    const {data, error} = await db.from('lookup_values').insert(payload).select().maybeSingle();
    if (error) throw error;
    result = data;
  });
  invalidateLookupCache(row.kind);
  return result;
}

async function updateLookup(id, updates) {
  let kind;
  await retryWithRefresh(async () => {
    const {data, error} = await db.from('lookup_values').update(updates).eq('id', id).select('kind').maybeSingle();
    if (error) throw error;
    kind = data?.kind;
  });
  invalidateLookupCache(kind);
}

// soft delete (active=false) — 사용 중 여부와 무관하게 안전
async function deactivateLookup(id) {
  await updateLookup(id, {active: false});
}

async function activateLookup(id) {
  await updateLookup(id, {active: true});
}

// 캠페인에서 사용 중인지 확인 (channel/category만 의미. content_type은 콤마 문자열 검사)
async function isLookupInUse(row) {
  if (!db || !row) return false;
  if (row.kind === 'channel') {
    const {count} = await db.from('campaigns').select('id', {count: 'exact', head: true}).ilike('channel', `%${row.code}%`);
    return (count || 0) > 0;
  }
  if (row.kind === 'category') {
    const {count} = await db.from('campaigns').select('id', {count: 'exact', head: true}).eq('category', row.code);
    return (count || 0) > 0;
  }
  if (row.kind === 'content_type') {
    const {count} = await db.from('campaigns').select('id', {count: 'exact', head: true}).ilike('content_types', `%${row.name_ja}%`);
    return (count || 0) > 0;
  }
  // ng_item은 textarea 자유 입력이라 사용 여부 추적 불가 → 항상 false
  return false;
}

// hard delete — 미사용 시에만 호출
async function deleteLookup(id) {
  let kind;
  await retryWithRefresh(async () => {
    const {data: row} = await db.from('lookup_values').select('kind').eq('id', id).maybeSingle();
    kind = row?.kind;
    const {error} = await db.from('lookup_values').delete().eq('id', id);
    if (error) throw error;
  });
  invalidateLookupCache(kind);
}

// 정렬 순서 swap (↑↓ 버튼)
async function swapLookupOrder(idA, idB) {
  if (!db) return;
  const {data: rows} = await db.from('lookup_values').select('id, kind, sort_order').in('id', [idA, idB]);
  if (!rows || rows.length !== 2) return;
  const [a, b] = rows;
  await retryWithRefresh(async () => {
    await db.from('lookup_values').update({sort_order: b.sort_order}).eq('id', a.id);
    await db.from('lookup_values').update({sort_order: a.sort_order}).eq('id', b.id);
  });
  invalidateLookupCache(a.kind);
}

// ══════════════════════════════════════
// 참여방법 번들 (participation_sets)
// ══════════════════════════════════════

// recruit_type 지정하면 해당 타입 포함 번들만, 없으면 전체(활성) — 캠페인 폼용
async function fetchParticipationSets(recruitType) {
  if (!db) return [];
  let q = db?.from('participation_sets')
    .select('*')
    .eq('active', true)
    .order('sort_order', {ascending: true});
  if (recruitType) q = q.contains('recruit_types', [recruitType]);
  const {data, error} = await q;
  if (error) throw error;
  return data || [];
}

// 관리자 페이지 — 비활성 포함 전체
async function fetchParticipationSetsAll() {
  if (!db) return [];
  const {data, error} = await db?.from('participation_sets')
    .select('*')
    .order('sort_order', {ascending: true});
  if (error) throw error;
  return data || [];
}

async function insertParticipationSet(row) {
  let result;
  await retryWithRefresh(async () => {
    const existing = await fetchParticipationSetsAll();
    const maxOrder = existing.reduce((m, r) => Math.max(m, r.sort_order || 0), 0);
    const payload = {
      name_ko: row.name_ko,
      name_ja: row.name_ja,
      recruit_types: row.recruit_types || [],
      steps: row.steps || [],
      sort_order: row.sort_order != null ? row.sort_order : maxOrder + 10,
      active: row.active != null ? row.active : true
    };
    const {data, error} = await db?.from('participation_sets').insert(payload).select().maybeSingle();
    if (error) throw error;
    result = data;
  });
  return result;
}

async function updateParticipationSet(id, updates) {
  await retryWithRefresh(async () => {
    const {error} = await db?.from('participation_sets').update(updates).eq('id', id);
    if (error) throw error;
  });
}

async function deactivateParticipationSet(id) {
  await updateParticipationSet(id, {active: false});
}

async function activateParticipationSet(id) {
  await updateParticipationSet(id, {active: true});
}

// hard delete — campaigns.participation_set_id는 ON DELETE SET NULL이라 안전
async function deleteParticipationSet(id) {
  await retryWithRefresh(async () => {
    const {error} = await db?.from('participation_sets').delete().eq('id', id);
    if (error) throw error;
  });
}

async function swapParticipationSetOrder(idA, idB) {
  if (!db) return;
  const {data: rows} = await db?.from('participation_sets').select('id, sort_order').in('id', [idA, idB]);
  if (!rows || rows.length !== 2) return;
  const [a, b] = rows;
  await retryWithRefresh(async () => {
    await db?.from('participation_sets').update({sort_order: b.sort_order}).eq('id', a.id);
    await db?.from('participation_sets').update({sort_order: a.sort_order}).eq('id', b.id);
  });
}
