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

// PostgREST 기본 1000행 제한 우회: range() 반복으로 전체 수집
// buildQuery: 매 반복마다 새 query builder 반환하는 함수 (filter/order 이미 적용)
async function fetchAllPaged(buildQuery, pageSize = 1000) {
  const all = [];
  let from = 0;
  while (true) {
    const {data, error} = await buildQuery().range(from, from + pageSize - 1);
    if (error) throw error;
    if (!data || data.length === 0) break;
    all.push(...data);
    if (data.length < pageSize) break;
    from += pageSize;
  }
  return all;
}

// ── Campaigns ──
async function fetchCampaigns() {
  if (!db) return DEMO_CAMPAIGNS.slice();
  try {
    const data = await fetchAllPaged(() =>
      db.from('campaigns').select('*').order('order_index', {ascending: true, nullsFirst: false})
    );
    if (data.length > 0) {
      await autoOpenCampaigns(data);   // scheduled → active (recruit_start 도래)
      await autoCloseCampaigns(data);  // active → closed (deadline 경과)
      return data;
    }
    return DEMO_CAMPAIGNS.slice();
  } catch(e) {
    return DEMO_CAMPAIGNS.slice();
  }
}

// 모집 시작일 도래 캠페인 자동 활성화 (scheduled → active)
//   recruit_start 가 오늘(JST 자정 기준) 이하이고 status='scheduled' 면 active 로 전환.
//   deadline 이 이미 경과한 경우는 autoCloseCampaigns 가 이어서 닫음.
async function autoOpenCampaigns(camps) {
  if (!db) return camps;
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  const toOpen = camps.filter(c => {
    if (c.status !== 'scheduled' || !c.recruit_start) return false;
    const rs = new Date(c.recruit_start);
    rs.setHours(0, 0, 0, 0);
    return now >= rs;
  });
  if (!toOpen.length) return camps;
  const results = await Promise.allSettled(toOpen.map(c => {
    c.status = 'active';
    return db.from('campaigns').update({ status: 'active' }).eq('id', c.id);
  }));
  results.forEach((r, i) => {
    if (r.status === 'rejected') console.warn('autoOpenCampaigns 실패:', toOpen[i]?.id, r.reason);
  });
  return camps;
}

// 마감일 경과 캠페인 자동 상태 변경 (병렬 UPDATE)
async function autoCloseCampaigns(camps) {
  if (!db) return camps;
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  const toClose = camps.filter(c => {
    if (c.status !== 'active' || !c.deadline) return false;
    const dl = new Date(c.deadline);
    dl.setHours(23, 59, 59, 999);
    return now > dl;
  });
  if (!toClose.length) return camps;
  const results = await Promise.allSettled(toClose.map(c => {
    c.status = 'closed';
    return db.from('campaigns').update({ status: 'closed' }).eq('id', c.id);
  }));
  results.forEach((r, i) => {
    if (r.status === 'rejected') console.warn('autoCloseCampaigns 실패:', toClose[i]?.id, r.reason);
  });
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
  // 관리자 편집 경로 전용 — 호출 시점에 수정일 자동 갱신
  // (조회수/자동 종료 등 시스템 UPDATE는 이 함수를 거치지 않아 수정일 오염 없음)
  const payload = { ...updates, updated_at: new Date().toISOString() };
  await retryWithRefresh(async () => {
    const {error} = await db.from('campaigns').update(payload).eq('id', campId);
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
    return await fetchAllPaged(() =>
      db.from('influencers').select('*').order('created_at', {ascending: true})
    );
  } catch(e) {
    return [];
  }
}

// 대시보드 전용: 인플루언서 배송지(도도부현) 분포 집계
// - Top N 일본 도도부현 + 未登録(NULL/빈값) + 海外(비일본) 분리
// - 도도부현 판별: 끝자가 都/道/府/県 으로 끝나면 일본으로 간주
// - 이미 fetchInfluencers()로 가져온 배열을 받아서 순수 집계만 수행 (중복 쿼리 방지)
const TOP_PREFECTURE_LIMIT = 10;
function computePrefectureStats(users, limit) {
  const rows = Array.isArray(users) ? users : [];
  const maxTop = Number.isFinite(limit) ? limit : TOP_PREFECTURE_LIMIT;
  const counts = {};
  let unregistered = 0;
  let overseas = 0;
  for (const row of rows) {
    const p = (row && row.prefecture ? String(row.prefecture) : '').trim();
    if (!p) { unregistered++; continue; }
    if (/(都|道|府|県)$/.test(p)) {
      counts[p] = (counts[p] || 0) + 1;
    } else {
      overseas++;
    }
  }
  const top = Object.entries(counts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, maxTop)
    .map(([name, count]) => ({ name, count }));
  return { top, unregistered, overseas, total: rows.length };
}

// ── 인플루언서 인증/블랙리스트 (관리자 전용, migration 059) ──
async function setInfluencerVerified(targetId, verify, note = null) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('set_influencer_verified', {
      p_target_id: targetId, p_verify: !!verify, p_note: note || null,
    });
    if (error) throw error;
  });
}

async function setInfluencerBlacklist(targetId, blacklist, reasonCode = null, note = null) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('set_influencer_blacklist', {
      p_target_id: targetId, p_blacklist: !!blacklist,
      p_reason_code: reasonCode || null, p_note: note || null,
    });
    if (error) throw error;
  });
}

async function fetchInfluencerFlags(influencerId) {
  if (!db || !influencerId) return [];
  try {
    const {data, error} = await db.from('influencer_flags')
      .select('*').eq('influencer_id', influencerId).order('set_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { return []; }
}

async function fetchBlacklistReasons() {
  if (!db) return [];
  try {
    const {data, error} = await db.from('lookup_values')
      .select('code, name_ko, name_ja').eq('kind', 'blacklist_reason')
      .eq('active', true).order('sort_order');
    if (error) throw error;
    return data || [];
  } catch(e) { return []; }
}

// ── 인플루언서 위반 기록 (관리자 전용, migration 060/062) ──
// evidencePaths: Storage 경로 배열 (migration 062 추가). null이면 빈 배열로 저장.
async function recordInfluencerViolation(targetId, reasonCode, note = null, evidencePaths = null) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('record_influencer_violation', {
      p_target_id: targetId,
      p_reason_code: reasonCode,
      p_note: note || null,
      p_evidence_paths: evidencePaths || null,
    });
    if (error) throw error;
  });
}

// ── 위반 이력 수정 (관리자 전용, migration 061/062) ──
// violation 행의 reason_code / note / evidence_paths 사후 수정.
// evidencePaths: null=미변경, []=기존 첨부 전체 삭제, [path,...]=교체.
// verify/blacklist 등 비-violation 행에 호출하면 DB에서 EXCEPTION 발생.
async function updateInfluencerViolation(flagId, reasonCode, note = null, evidencePaths = undefined) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('update_influencer_violation', {
      p_flag_id: flagId,
      p_reason_code: reasonCode,
      p_note: note ?? null,
      // undefined이면 파라미터 자체를 생략해 DB DEFAULT(NULL=미변경) 적용
      ...(evidencePaths !== undefined ? {p_evidence_paths: evidencePaths} : {}),
    });
    if (error) throw error;
  });
}

// ── 증빙 파일 업로드 (관리자 전용, migration 062) ──
// 버킷: influencer-flag-evidence (비공개)
// 경로 규칙: {flagId}/{uuid}.{ext}
// flagId: 위반 등록 전이면 'tmp/{timestamp}' 등 임시값, 등록 후 실제 flag_id로 이동 불필요
//         (등록 전 업로드 → 경로 배열을 record RPC에 전달하면 DB가 flag_id와 연결)
// 반환: Storage 경로 문자열 (signed URL 아님)
async function uploadFlagEvidence(file, flagId) {
  if (!db) throw new Error('DB 미연결');
  const BUCKET = 'influencer-flag-evidence';
  const ext = file.name ? file.name.split('.').pop().toLowerCase() : 'bin';
  const uuid = crypto.randomUUID ? crypto.randomUUID() : (Date.now().toString(36) + Math.random().toString(36).substring(2));
  const path = `${flagId}/${uuid}.${ext}`;
  const {error} = await db.storage.from(BUCKET).upload(path, file, {contentType: file.type, upsert: false});
  if (error) throw error;
  return path;
}

// ── 증빙 파일 signed URL 조회 (관리자 전용, migration 062) ──
// path: uploadFlagEvidence() 반환값 (Storage 경로)
// expiresIn: 초 단위, 기본 3600 (1시간)
// 반환: signed URL 문자열
async function getFlagEvidenceSignedUrl(path, expiresIn = 3600) {
  if (!db || !path) return null;
  const BUCKET = 'influencer-flag-evidence';
  const {data, error} = await db.storage.from(BUCKET).createSignedUrl(path, expiresIn);
  if (error) throw error;
  return data?.signedUrl || null;
}

// ── 증빙 파일 삭제 (관리자 전용, migration 062) ──
// paths: Storage 경로 배열
async function deleteFlagEvidenceFiles(paths) {
  if (!db || !paths || paths.length === 0) return;
  const BUCKET = 'influencer-flag-evidence';
  const {error} = await db.storage.from(BUCKET).remove(paths);
  if (error) throw error;
}

// 모든 인플루언서의 위반 건수 집계 — { [influencer_id]: count }
async function fetchViolationCountsByInfluencer() {
  if (!db) return {};
  try {
    const data = await fetchAllPaged(() =>
      db.from('influencer_flags').select('influencer_id').eq('action', 'violation')
    );
    const counts = {};
    data.forEach(r => { counts[r.influencer_id] = (counts[r.influencer_id] || 0) + 1; });
    return counts;
  } catch(e) { return {}; }
}

async function fetchViolationReasons() {
  if (!db) return [];
  try {
    const {data, error} = await db.from('lookup_values')
      .select('code, name_ko, name_ja').eq('kind', 'violation_reason')
      .eq('active', true).order('sort_order');
    if (error) throw error;
    return data || [];
  } catch(e) { return []; }
}

async function upsertInfluencer(profile) {
  if (!db) return;
  const normalized = (typeof normalizeSnsFields === 'function') ? normalizeSnsFields(profile) : profile;
  await retryWithRefresh(async () => {
    const {error} = await db.from('influencers').upsert(normalized);
    if (error) throw error;
  });
}

async function updateInfluencer(userId, updates) {
  if (!db) return;
  const normalized = (typeof normalizeSnsFields === 'function') ? normalizeSnsFields(updates) : updates;
  const {error} = await db.from('influencers').update(normalized).eq('id', userId);
  if (error) throw error;
}

// ── Applications ──
async function fetchApplications(filters) {
  if (!db) return [];
  try {
    return await fetchAllPaged(() => {
      let q = db.from('applications').select('*');
      if (filters?.campaign_id) q = q.eq('campaign_id', filters.campaign_id);
      if (filters?.user_id) q = q.eq('user_id', filters.user_id);
      if (filters?.status) q = q.eq('status', filters.status);
      return q.order('created_at', {ascending: false});
    });
  } catch(e) {
    return [];
  }
}

async function countActiveApplications(campaignId) {
  if (!db || !campaignId) return 0;
  try {
    const {count, error} = await db.from('applications')
      .select('*', {count: 'exact', head: true})
      .eq('campaign_id', campaignId)
      .in('status', ['pending', 'approved']);
    if (error) throw error;
    return count || 0;
  } catch(e) { return 0; }
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
    return await fetchAllPaged(() => {
      let q = db.from('receipts').select('*');
      if (filters?.application_id) q = q.eq('application_id', filters.application_id);
      if (filters?.user_id) q = q.eq('user_id', filters.user_id);
      if (filters?.campaign_id) q = q.eq('campaign_id', filters.campaign_id);
      return q.order('created_at', {ascending: false});
    });
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
// 사이드바 배지용 — pending(검수 대기) 결과물 개수만 빠르게 (head:true count, draft 자동 제외)
async function fetchPendingDeliverableCount() {
  if (!db) return 0;
  try {
    const {count, error} = await db.from('deliverables')
      .select('id', {count: 'exact', head: true})
      .eq('status', 'pending');
    if (error) throw error;
    return count || 0;
  } catch(e) { console.error('[fetchPendingDeliverableCount]', e); return 0; }
}

// 관리자용: 결과물 리스트 + 캠페인/인플루언서 정보 조인
async function fetchDeliverables(filters) {
  if (!db) return [];
  try {
    const data = await fetchAllPaged(() => {
      let q = db.from('deliverables').select(`
        id, kind, status, version,
        receipt_url, purchase_date, purchase_amount, memo,
        post_url, post_channel, post_submissions,
        reject_reason, reject_template_code,
        reviewed_by, reviewed_at, submitted_at, updated_at,
        application_id, user_id, campaign_id,
        campaigns:campaign_id (id, campaign_no, title, brand, recruit_type)
      `).neq('status', 'draft');
      if (filters?.status && filters.status !== 'all') q = q.eq('status', filters.status);
      if (filters?.kind && filters.kind !== 'all') q = q.eq('kind', filters.kind);
      if (filters?.campaign_id && filters.campaign_id !== 'all') q = q.eq('campaign_id', filters.campaign_id);
      // pending 기본: 오래된 순(방치 방지). 그 외 상태: 최근 처리 순
      if (filters?.status === 'pending') q = q.order('submitted_at', {ascending: true});
      else q = q.order('updated_at', {ascending: false});
      return q;
    });
    // influencers는 별도 조회 후 user_id로 매핑 (PostgREST가 auth.users 경유 조인 못 하므로)
    const userIds = [...new Set(data.map(d => d.user_id).filter(Boolean))];
    const infMap = await fetchInfluencersByIds(userIds);
    return data.map(d => ({...d, influencers: infMap[d.user_id] || null}));
  } catch(e) { console.error('[fetchDeliverables]', e); return []; }
}

async function fetchDeliverableById(id) {
  if (!db) return null;
  try {
    const {data, error} = await db?.from('deliverables').select(`
      *,
      campaigns:campaign_id (id, campaign_no, title, brand, recruit_type, channel, channel_match, img1)
    `).eq('id', id).maybeSingle();
    if (error) throw error;
    if (!data) return null;
    const infMap = await fetchInfluencersByIds([data.user_id]);
    return {...data, influencers: infMap[data.user_id] || null};
  } catch(e) { console.error('[fetchDeliverableById]', e); return null; }
}

// applications.oriented_at 토글 (Stage 4: OT 발송 체크박스)
async function updateApplicationOrientedAt(applicationId, isoOrNull) {
  if (!db) return false;
  let ok = false;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('applications')
        .update({oriented_at: isoOrNull})
        .eq('id', applicationId);
      if (error) throw error;
      ok = true;
    });
  } catch(e) { console.error('[updateApplicationOrientedAt]', e); }
  return ok;
}

// Stage 6: 본인 알림 조회 (마이페이지 상단 알림 섹션용)
// 관리자는 RLS SELECT 정책으로 전체 알림 SEE 가능하므로 명시적 user_id 필터 필수
async function fetchMyNotifications(opts) {
  if (!db) return [];
  try {
    const {data: s} = await db.auth.getUser();
    const uid = s?.user?.id;
    if (!uid) return [];
    let q = db?.from('notifications').select('*').eq('user_id', uid).order('created_at', {ascending: false});
    if (opts?.unreadOnly) q = q.is('read_at', null);
    if (opts?.limit) q = q.limit(opts.limit);
    const {data, error} = await q;
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchMyNotifications]', e); return []; }
}

// 알림 1건 읽음 처리
async function markNotificationRead(notificationId) {
  if (!db) return;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('notifications')
        .update({read_at: new Date().toISOString()})
        .eq('id', notificationId)
        .is('read_at', null);
      if (error) throw error;
    });
  } catch(e) { console.error('[markNotificationRead]', e); }
}

// 알림 1건 삭제 (본인만)
async function deleteNotification(id) {
  if (!db) return;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('notifications').delete().eq('id', id);
      if (error) throw error;
    });
  } catch(e) { console.error('[deleteNotification]', e); }
}

// 전체 알림 읽음 처리
async function markAllNotificationsRead() {
  if (!db) return;
  try {
    // 현재 유저 ID 조회 (explicit user_id 필터 — Supabase global-update 방지)
    const {data: s} = await db.auth.getUser();
    const uid = s?.user?.id;
    if (!uid) return;
    await retryWithRefresh(async () => {
      const {error} = await db?.from('notifications')
        .update({read_at: new Date().toISOString()})
        .eq('user_id', uid)
        .is('read_at', null);
      if (error) throw error;
    });
  } catch(e) { console.error('[markAllNotificationsRead]', e); }
}

// 캠페인 단위로 결과물 전체 조회 (진행현황 탭 — 여러 신청자 일괄)
async function fetchDeliverablesByCampaign(campaignId) {
  if (!db) return [];
  try {
    const {data, error} = await db?.from('deliverables')
      .select('id, application_id, user_id, kind, status, reviewed_at, submitted_at, updated_at, version, post_url, post_channel, receipt_url, purchase_date, purchase_amount, reject_reason')
      .eq('campaign_id', campaignId)
      .order('submitted_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchDeliverablesByCampaign]', e); return []; }
}

// 인플루언서 본인 결과물 조회 (활동관리 화면)
async function fetchDeliverablesForUser(filters) {
  if (!db) return [];
  try {
    let query = db?.from('deliverables').select('*');
    if (filters?.application_id) query = query.eq('application_id', filters.application_id);
    if (filters?.user_id) query = query.eq('user_id', filters.user_id);
    if (filters?.kind) query = query.eq('kind', filters.kind);
    query = query.order('submitted_at', {ascending: false});
    const {data, error} = await query;
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchDeliverablesForUser]', e); return []; }
}

// ── Draft 플로우 (Stage: draft 제출 플로우) ──
// 신규 draft(post URL 또는 image) 1건 저장
async function insertDraftDeliverable(payload) {
  if (!db) return null;
  let id = null;
  await retryWithRefresh(async () => {
    const row = {
      application_id: payload.application_id,
      user_id: payload.user_id,
      campaign_id: payload.campaign_id,
      kind: payload.kind,            // 'post' | 'receipt' (receipt = image evidence)
      status: 'draft',
      post_url: payload.post_url || null,
      post_channel: payload.post_channel || null,
      post_submissions: payload.kind === 'post'
        ? [{url: payload.post_url, channel: payload.post_channel, submitted_at: new Date().toISOString()}]
        : [],
      receipt_url: payload.receipt_url || null,
      memo: payload.memo || null
    };
    const {data, error} = await db?.from('deliverables').insert(row).select('id').maybeSingle();
    if (error) throw error;
    id = data?.id || null;
  });
  return id;
}

// 본인 draft 삭제
async function deleteDraftDeliverable(id) {
  if (!db) return false;
  let ok = false;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('deliverables').delete().eq('id', id).eq('status', 'draft');
      if (error) throw error;
      ok = true;
    });
  } catch(e) { console.error('[deleteDraftDeliverable]', e); }
  return ok;
}

// 특정 application의 draft 전체를 pending으로 제출 (본인만)
async function submitDrafts(applicationId, kind) {
  if (!db || !applicationId) return 0;
  let count = 0;
  try {
    await retryWithRefresh(async () => {
      let q = db.from('deliverables').update({status: 'pending'})
        .eq('application_id', applicationId)
        .eq('status', 'draft');
      if (kind) q = q.eq('kind', kind);
      const {data, error} = await q.select('id');
      if (error) throw error;
      count = (data || []).length;
      // 제출 이벤트 로그 (RPC submit_deliverable) — 각 제출된 draft마다
      for (const row of (data || [])) {
        try { await db.rpc('submit_deliverable', {p_deliverable_id: row.id}); }
        catch(e) { console.error('[submit_deliverable rpc]', e); }
      }
    });
  } catch(e) { console.error('[submitDrafts]', e); }
  return count;
}

// 게시물 결과물 신규 INSERT (인플루언서)
async function insertPostDeliverable(payload) {
  if (!db) return null;
  let id = null;
  await retryWithRefresh(async () => {
    const row = {
      application_id: payload.application_id,
      user_id: payload.user_id,
      campaign_id: payload.campaign_id,
      kind: 'post',
      status: 'pending',
      post_url: payload.post_url,
      post_channel: payload.post_channel,
      post_submissions: [{url: payload.post_url, channel: payload.post_channel, submitted_at: new Date().toISOString()}]
    };
    const {data, error} = await db?.from('deliverables').insert(row).select('id').maybeSingle();
    if (error) throw error;
    id = data?.id || null;
  });
  // 최초 제출 이벤트 기록 (SECURITY DEFINER)
  if (id) {
    try { await db?.rpc('submit_deliverable', {p_deliverable_id: id}); }
    catch(e) { console.error('[submit_deliverable RPC]', e); }
  }
  return id;
}

// 기존 게시물 deliverable에 재제출 반영 (동일 URL: 날짜만 누적, 반려건은 pending 복귀)
// 낙관적 락: 관리자가 동시에 상태를 바꾸면 충돌 에러
async function appendPostSubmission(deliverableId, url, channel) {
  if (!db) return;
  await retryWithRefresh(async () => {
    const {data: cur, error: e1} = await db?.from('deliverables')
      .select('post_submissions, status, version').eq('id', deliverableId).maybeSingle();
    if (e1) throw e1;
    if (!cur) return;
    const arr = Array.isArray(cur.post_submissions) ? cur.post_submissions.slice() : [];
    arr.push({url, channel, submitted_at: new Date().toISOString()});
    const patch = {post_submissions: arr, version: (cur.version || 1) + 1};
    if (cur.status === 'rejected') { patch.status = 'pending'; patch.reject_reason = null; patch.reject_template_code = null; }
    const {data: upd, error: e2} = await db?.from('deliverables')
      .update(patch).eq('id', deliverableId).eq('version', cur.version).select('id');
    if (e2) throw e2;
    if (!upd || !upd.length) throw new Error('conflict');
  });
}

// 여러 user_id(auth.uid)에 대응하는 influencers 행을 map 형태로 반환
async function fetchInfluencersByIds(userIds) {
  if (!db || !userIds?.length) return {};
  try {
    const {data, error} = await db?.from('influencers')
      .select('id, name, name_kana, email, primary_sns, line_id, is_verified, verified_at, is_blacklisted, blacklisted_at, blacklist_reason_code, blacklist_reason_note')
      .in('id', userIds);
    if (error) throw error;
    const map = {};
    (data || []).forEach(i => { map[i.id] = i; });
    return map;
  } catch(e) { return {}; }
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
    const {data, error} = await db?.rpc('update_deliverable_status', {
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
async function uploadImage(base64Data, fileName, pathPrefix) {
  if (!db) return base64Data;
  // base64 → Blob 변환
  var parts = base64Data.split(',');
  var mime = parts[0].match(/:(.*?);/)[1];
  var binary = atob(parts[1]);
  var arr = new Uint8Array(binary.length);
  for (var i = 0; i < binary.length; i++) arr[i] = binary.charCodeAt(i);
  var blob = new Blob([arr], {type: mime});
  // 파일 경로: {prefix}/타임스탬프_랜덤.ext (prefix 기본 'campaigns', 영수증은 'receipts')
  var prefix = pathPrefix || 'campaigns';
  var ext = mime.split('/')[1] === 'jpeg' ? 'jpg' : mime.split('/')[1];
  var path = prefix + '/' + Date.now() + '_' + Math.random().toString(36).substring(2, 8) + '.' + ext;
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
      active: row.active != null ? row.active : true,
      recruit_types: Array.isArray(row.recruit_types) ? row.recruit_types : []
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

// ══════════════════════════════════════
// CAUTION SETS (주의사항 번들 — migration 069)
//   participation_sets 패턴과 동일. 캠페인 저장 시 items 스냅샷이
//   campaigns.caution_items 로 복사되므로, 번들 수정 후에도 기존
//   캠페인 상세/신청 모달에는 영향 없음.
// ══════════════════════════════════════

// 캠페인 폼에서 recruit_type 필터로 active 번들만 조회
//   서버 filter (contains) 가 recruit_types=[] 를 제외시키는 문제 때문에
//   active 전체를 받아 클라이언트에서 필터 — 빈 배열(=전 타입 공통) 은 항상 포함
async function fetchCautionSets(recruitType) {
  if (!db) return [];
  const {data, error} = await db?.from('caution_sets')
    .select('*')
    .eq('active', true)
    .order('sort_order', {ascending: true});
  if (error) throw error;
  const all = data || [];
  if (!recruitType) return all;
  return all.filter(s => {
    const rts = Array.isArray(s.recruit_types) ? s.recruit_types : [];
    return rts.length === 0 || rts.includes(recruitType);
  });
}

// 관리자 기준 데이터 페인 — 비활성 포함 전체
async function fetchCautionSetsAll() {
  if (!db) return [];
  const {data, error} = await db?.from('caution_sets')
    .select('*')
    .order('sort_order', {ascending: true});
  if (error) throw error;
  return data || [];
}

async function insertCautionSet(row) {
  let result;
  await retryWithRefresh(async () => {
    const existing = await fetchCautionSetsAll();
    const maxOrder = existing.reduce((m, r) => Math.max(m, r.sort_order || 0), 0);
    const payload = {
      name_ko: row.name_ko,
      name_ja: row.name_ja,
      recruit_types: row.recruit_types || [],
      items: row.items || [],
      sort_order: row.sort_order != null ? row.sort_order : maxOrder + 10,
      active: row.active != null ? row.active : true
    };
    const {data, error} = await db?.from('caution_sets').insert(payload).select().maybeSingle();
    if (error) throw error;
    result = data;
  });
  return result;
}

async function updateCautionSet(id, updates) {
  await retryWithRefresh(async () => {
    const {error} = await db?.from('caution_sets').update(updates).eq('id', id);
    if (error) throw error;
  });
}

async function deactivateCautionSet(id) {
  await updateCautionSet(id, {active: false});
}

async function activateCautionSet(id) {
  await updateCautionSet(id, {active: true});
}

// hard delete — campaigns.caution_set_id 는 ON DELETE SET NULL 이라 안전
async function deleteCautionSet(id) {
  await retryWithRefresh(async () => {
    const {error} = await db?.from('caution_sets').delete().eq('id', id);
    if (error) throw error;
  });
}

async function swapCautionSetOrder(idA, idB) {
  if (!db) return;
  const {data: rows} = await db?.from('caution_sets').select('id, sort_order').in('id', [idA, idB]);
  if (!rows || rows.length !== 2) return;
  const [a, b] = rows;
  await retryWithRefresh(async () => {
    await db?.from('caution_sets').update({sort_order: b.sort_order}).eq('id', a.id);
    await db?.from('caution_sets').update({sort_order: a.sort_order}).eq('id', b.id);
  });
}

// ══════════════════════════════════════
// CAMPAIGN CAUTION HISTORY (주의사항/참여방법 변경 audit — migration 077, Phase 2)
// ══════════════════════════════════════

// 변경 이력 INSERT — record_caution_history RPC (SECURITY DEFINER)
//   호출 위치: dev/js/admin.js:saveCampaignEdit() — caution/participation 변경이 감지된 경우만
//   args: { campaign_id, prev:{caution_set_id, caution_items, participation_set_id, participation_steps},
//           next:{caution_set_id, caution_items, participation_set_id, participation_steps},
//           app_count, bypass_ack }
//   bypass_ack: 신청자 ≥1 + 사용자가 경고 모달 「확인하고 저장」을 통과했으면 true.
//   DEMO_MODE(no db)에서는 no-op (audit 의미 없음).
async function recordCautionHistory({campaign_id, prev, next, app_count, bypass_ack}) {
  if (!db || !campaign_id) return null;
  let result = null;
  await retryWithRefresh(async () => {
    const {data, error} = await db?.rpc('record_caution_history', {
      p_campaign_id: campaign_id,
      p_prev_caution_set_id: prev?.caution_set_id || null,
      p_next_caution_set_id: next?.caution_set_id || null,
      p_prev_caution_items: prev?.caution_items ?? null,
      p_next_caution_items: next?.caution_items ?? null,
      p_prev_participation_set_id: prev?.participation_set_id || null,
      p_next_participation_set_id: next?.participation_set_id || null,
      p_prev_participation_steps: prev?.participation_steps ?? null,
      p_next_participation_steps: next?.participation_steps ?? null,
      p_app_count: Number.isFinite(app_count) ? app_count : 0,
      p_bypass_ack: !!bypass_ack,
    });
    if (error) throw error;
    result = data || null;
  });
  return result;
}

// super_admin 전용 — 캠페인 단위 변경 이력 조회 (changed_at desc)
//   RLS 가 SELECT 를 super_admin 으로 제한하므로 그 외 역할은 빈 배열 수신.
async function fetchCautionHistory(campaignId) {
  if (!db || !campaignId) return [];
  try {
    const {data, error} = await db?.from('campaign_caution_history')
      .select('*')
      .eq('campaign_id', campaignId)
      .order('changed_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchCautionHistory]', e); return []; }
}

// ══════════════════════════════════════
// ADMIN NOTICES (관리자 전용 공지 — migration 063)
// ══════════════════════════════════════

// 공지 목록 + 본인 읽음 여부 (migration 071: status·published_at 추가)
//   filters.category : 'all' | 'system_update' | 'release' | 'warning' | 'general'
//   filters.status   : 'all' | 'draft' | 'published'
//   정렬: 핀 우선 → 핀일자 → published_at(없으면 created_at)
async function fetchAdminNotices(filters) {
  if (!db) return [];
  try {
    const uid = (await db.auth.getUser()).data?.user?.id;
    let q = db.from('admin_notices').select('*, admin_notice_reads!left(read_at,auth_id)');
    if (filters?.category && filters.category !== 'all') q = q.eq('category', filters.category);
    if (filters?.status && filters.status !== 'all') q = q.eq('status', filters.status);
    q = q.order('is_pinned', {ascending: false})
         .order('pinned_at', {ascending: false, nullsFirst: false})
         .order('published_at', {ascending: false, nullsFirst: false})
         .order('created_at', {ascending: false});
    const {data, error} = await q;
    if (error) throw error;
    return (data || []).map(n => {
      const mine = (n.admin_notice_reads || []).find(r => r.auth_id === uid);
      return {...n, is_read: !!mine, read_at: mine?.read_at || null, admin_notice_reads: undefined};
    });
  } catch(e) { console.error('[fetchAdminNotices]', e); return []; }
}

// published 미읽음만 — 사이드바 배지·로그인 팝업·대시보드 카드 공용
async function fetchUnreadAdminNotices() {
  const all = await fetchAdminNotices();
  return all.filter(n => n.status === 'published' && !n.is_read);
}

// 신규 생성 — status는 'draft'(기본) 또는 'published'(즉시 게시)
async function insertAdminNotice(data) {
  if (!db) throw new Error('DB 미연결');
  const uid = (await db.auth.getUser()).data?.user?.id;
  const status = data.status === 'published' ? 'published' : 'draft';
  const nowIso = new Date().toISOString();
  const payload = {
    title: data.title,
    body_html: data.body_html,
    category: data.category,
    is_pinned: !!data.is_pinned,
    pinned_at: data.is_pinned ? nowIso : null,
    status,
    published_at: status === 'published' ? nowIso : null,
    published_by: status === 'published' ? (uid || null) : null,
    published_by_name: status === 'published' ? (data.created_by_name || null) : null,
    created_by: uid || null,
    created_by_name: data.created_by_name || null,
    updated_by: uid || null,
    updated_by_name: data.created_by_name || null,
  };
  await retryWithRefresh(async () => {
    const {error} = await db.from('admin_notices').insert(payload);
    if (error) throw error;
  });
}

// 부분 갱신.
//   patch.status === 'published' 가 들어오고 기존 published_at이 NULL이면
//   published_at/published_by 를 자동 세팅 (최초 게시).
//   재게시 시(이미 published_at 존재) 시각 갱신 안 함 — 미읽음 리셋 방지 정책.
async function updateAdminNotice(id, patch) {
  if (!db) throw new Error('DB 미연결');
  const uid = (await db.auth.getUser()).data?.user?.id;
  const p = {...patch, updated_by: uid || null};
  if (Object.prototype.hasOwnProperty.call(patch, 'is_pinned')) {
    p.pinned_at = patch.is_pinned ? new Date().toISOString() : null;
  }
  if (patch.status === 'published') {
    const {data: cur} = await db.from('admin_notices').select('published_at').eq('id', id).maybeSingle();
    if (!cur?.published_at) {
      const nowIso = new Date().toISOString();
      p.published_at = nowIso;
      p.published_by = uid || null;
      if (patch.updated_by_name) p.published_by_name = patch.updated_by_name;
    }
  }
  await retryWithRefresh(async () => {
    const {error} = await db.from('admin_notices').update(p).eq('id', id);
    if (error) throw error;
  });
}

// 게시 (draft → published). updateAdminNotice 와 동일 효과의 편의 함수
async function publishAdminNotice(id, byName) {
  return updateAdminNotice(id, {status: 'published', updated_by_name: byName || null});
}

// 회수 (published → draft). published_at은 유지하여 재게시 시 미읽음 리셋 안 함
async function unpublishAdminNotice(id, byName) {
  return updateAdminNotice(id, {status: 'draft', updated_by_name: byName || null});
}

async function deleteAdminNotice(id) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.from('admin_notices').delete().eq('id', id);
    if (error) throw error;
  });
}

async function markAdminNoticeRead(noticeId) {
  if (!db || !noticeId) return;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('upsert_admin_notice_read', {p_notice_id: noticeId});
    if (error) throw error;
  });
}

// ══════════════════════════════════════
// BRAND APPLICATIONS (광고주 신청 폼 — 052)
// ══════════════════════════════════════

// 광고주 신청 목록 조회 (관리자 RLS로 전체 조회)
async function fetchBrandApplications(filters) {
  if (!db) return [];
  try {
    return await fetchAllPaged(() => {
      let q = db.from('brand_applications').select(`
        id, application_no, form_type,
        brand_name, contact_name, phone, email, billing_email,
        products, total_jpy, total_qty,
        estimated_krw, final_quote_krw, quote_sent_at,
        status, admin_memo, request_note,
        reviewed_by, reviewed_at,
        version, created_at, updated_at
      `);
      if (filters?.form_type && filters.form_type !== 'all') q = q.eq('form_type', filters.form_type);
      if (filters?.status && filters.status !== 'all') q = q.eq('status', filters.status);
      if (filters?.from) q = q.gte('created_at', filters.from);
      if (filters?.to) q = q.lte('created_at', filters.to);
      return q.order('created_at', {ascending: false});
    });
  } catch(e) { console.error('[fetchBrandApplications]', e); return []; }
}

// pending(new) 건수 — 사이드바 배지용
async function fetchBrandAppPendingCount() {
  if (!db) return 0;
  try {
    const {count, error} = await db?.from('brand_applications')
      .select('id', {count: 'exact', head: true})
      .eq('status', 'new');
    if (error) throw error;
    return count || 0;
  } catch(e) { console.error('[fetchBrandAppPendingCount]', e); return 0; }
}

// 상세 1건 조회 (낙관적 락 version 확인용)
async function fetchBrandApplicationById(id) {
  if (!db) return null;
  try {
    const {data, error} = await db?.from('brand_applications')
      .select('*').eq('id', id).maybeSingle();
    if (error) throw error;
    return data;
  } catch(e) { console.error('[fetchBrandApplicationById]', e); return null; }
}

// 광고주 신청 변경 이력 (migration 079 brand_application_history 트리거가 자동 기록)
async function fetchBrandApplicationHistory(applicationId, limit) {
  if (!db || !applicationId) return [];
  try {
    const {data, error} = await db?.from('brand_application_history')
      .select('id, application_id, changed_by, changed_by_name, changed_at, field_name, old_value, new_value')
      .eq('application_id', applicationId)
      .order('changed_at', {ascending: false})
      .limit(limit || 200);
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchBrandApplicationHistory]', e); return []; }
}

// 광고주 신청 상태 변경·견적 입력·메모 수정 (낙관적 락)
// patch: {status?, final_quote_krw?, quote_sent_at?, admin_memo?, reviewed_by?, reviewed_at?}
// expectedVersion: UPDATE 시 버전 일치 확인. 불일치면 {ok:false, conflict:true}
async function updateBrandApplication(id, patch, expectedVersion) {
  if (!db) return {ok: false, error: 'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brand_applications')
        .update(patch)
        .eq('id', id)
        .eq('version', expectedVersion)
        .select('id, version, status')
        .maybeSingle();
      if (error) throw error;
      return data;
    });
    if (!result) return {ok: false, conflict: true};
    return {ok: true, data: result};
  } catch(e) {
    console.error('[updateBrandApplication]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

