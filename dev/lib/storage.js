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
// 동적 권한 접근수준 로드 (관리자 부팅 시). RLS SELECT is_admin() → 전 관리자 조회 가능.
// 실패해도 빈 배열 반환(fail-open) — 화면 숨김은 보안이 아니므로 로드 실패 시 전부 표시.
// default_level(마이그레이션 214) 포함 — 「기본값 복원」 버튼 활성 판정(access_level≠default_level)용.
async function fetchRolePermissions() {
  if (!db) return [];
  try {
    const {data, error} = await db.from('role_permissions').select('role, feature_key, access_level, default_level');
    if (error) { console.warn('role_permissions 로드 실패(fail-open):', error.message); return []; }
    return data || [];
  } catch (e) {
    console.warn('role_permissions 로드 예외(fail-open):', e?.message);
    return [];
  }
}

// 권한 설정 일괄 저장 (super_admin 전용, update_role_permissions RPC). PR2 조각 C.
//   changes = [{role, feature_key, prev_level, next_level}]. 반환 = 실제 변경 건수.
//   RPC 가 원자적 처리 + 이력 기록 + 권한상승/충돌 가드. 오류는 그대로 throw(화면에서 안내).
async function saveRolePermissions(changes) {
  if (!db) throw new Error('DB 미연결');
  let applied = 0;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('update_role_permissions', {p_changes: changes});
    if (error) throw error;
    applied = data || 0;
  });
  return applied;
}

// 권한 설정 「기본값 복원」 (super_admin 전용, restore_role_permissions_defaults RPC, 마이그레이션 215).
//   access_level ≠ default_level 인 모든 행(전체 일괄)을 default_level 로 되돌린다.
//   반환 = 실제로 되돌려진 건수. 오류는 그대로 throw(화면에서 안내).
async function restoreRolePermissionsDefaults() {
  if (!db) throw new Error('DB 미연결');
  let applied = 0;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('restore_role_permissions_defaults');
    if (error) throw error;
    applied = data || 0;
  });
  return applied;
}

async function fetchCampaigns() {
  if (!db) return DEMO_CAMPAIGNS.slice();
  try {
    // 마이그레이션 254 — 보관 삭제(soft delete)된 캠페인은 일반 조회에서 항상 제외.
    // fetchCampaigns() 는 인플루언서 앱(캠페인 목록·상세·마이페이지)과 관리자 여러
    // 페인이 공유하는 함수라, 여기서 제외하면 양쪽 모두 자동으로 안전해진다.
    // 「삭제됨」 탭(2단계) 전용 조회는 fetchDeletedCampaigns() 별도 함수 사용.
    const data = await fetchAllPaged(() =>
      db.from('campaigns').select('*').is('deleted_at', null).order('order_index', {ascending: true, nullsFirst: false})
    );
    if (data.length > 0) {
      await autoOpenCampaigns(data);   // scheduled → active (recruit_start 도래)
      await autoCloseCampaigns(data);  // active → closed (deadline 경과)
      await autoEndCampaigns(data);    // closed → ended (submission_end 경과)
      // expired 전이는 운영자 「캠페인 노출」 토글로 수동 처리 (자동 전이 제거 — migration 129)
      return data;
    }
    return DEMO_CAMPAIGNS.slice();
  } catch(e) {
    return DEMO_CAMPAIGNS.slice();
  }
}

// 관리자 캠페인 목록 전용 조회 — 목록 렌더·검색·필터·정렬에 필요한 컬럼만 select.
// participation_steps / caution_items / ng_items / description / appeal / guide 등
// 무거운 jsonb·리치텍스트 컬럼은 제외해 페이로드를 절약한다.
// ※ fetchCampaigns 는 인플루언서 앱·복제·편집 등 다른 곳에서도 공유하므로 건드리지 않는다.
// ※ autoOpenCampaigns / autoCloseCampaigns 는 status / recruit_start / deadline 만 참조하므로
//    목록 전용 컬럼셋에서도 문제없이 실행된다. 목록 진입 시 자동 전환을 유지하기 위해 여기서도 호출.
const ADMIN_LIST_COLUMNS = [
  'id', 'title', 'brand', 'brand_ko', 'brand_ja', 'brand_en', 'product', 'product_ko',
  'campaign_no', 'legacy_no',
  'recruit_type', 'channel', 'channel_match', 'status',
  'slots', 'view_count',
  'img1', 'img2', 'img3', 'img4', 'img5', 'img6', 'img7', 'img8',
  'image_url', 'image_crops', 'emoji',
  'recruit_start', 'deadline',
  'purchase_start', 'purchase_end',
  'visit_start', 'visit_end',
  'submission_end',
  'order_index', 'created_at', 'updated_at',
].join(',');

async function fetchCampaignsForAdminList() {
  if (!db) return DEMO_CAMPAIGNS.slice();
  try {
    // 마이그레이션 254 — 보관 삭제(soft delete)된 캠페인은 일반 관리자 목록·대시보드·
    // 운영현황 집계에서 제외(사양서 §설계 「일반 목록·집계 제외」). 「삭제됨」 탭
    // (2단계)만 fetchDeletedCampaigns() 로 별도 조회.
    const data = await fetchAllPaged(() =>
      db.from('campaigns')
        .select(ADMIN_LIST_COLUMNS)
        .is('deleted_at', null)
        .order('order_index', { ascending: true, nullsFirst: false })
    );
    if (data.length > 0) {
      await autoOpenCampaigns(data);   // scheduled → active (recruit_start 도래)
      await autoCloseCampaigns(data);  // active → closed (deadline 경과)
      await autoEndCampaigns(data);    // closed → ended (submission_end 경과)
      return data;
    }
    return DEMO_CAMPAIGNS.slice();
  } catch(e) {
    return DEMO_CAMPAIGNS.slice();
  }
}

// 관리자 캠페인 목록 전용 신청 집계 조회 — 서버 집계 함수(get_campaign_application_counts) 호출.
// 반환: { [campaign_id]: { total, approved, pending } } 맵.
//   total   = 취소(cancelled) 제외한 전체 신청 수 (PR 4 확정 동작 변경)
//   approved = 승인 수, pending = 대기 수
// 신청 전건(약 3,000건)을 클라이언트로 전송하던 방식에서 서버 집계 1회 호출로 전환.
// DEMO_MODE 또는 호출 실패 시 빈 맵({}) 반환 — 카운트 0으로 폴백.
async function fetchCampaignApplicationCounts() {
  if (!db) return {};
  try {
    const { data, error } = await db.rpc('get_campaign_application_counts');
    if (error) throw error;
    // 배열을 campaign_id 키 맵으로 변환
    return (data || []).reduce((map, row) => {
      map[row.campaign_id] = {
        total:    Number(row.total    || 0),
        approved: Number(row.approved || 0),
        pending:  Number(row.pending  || 0),
      };
      return map;
    }, {});
  } catch(e) {
    console.error('fetchCampaignApplicationCounts:', e);
    return {};
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
    // 로컬 객체의 version 도 함께 맞춘다 — 이 UPDATE 로 트리거(마이그레이션 275)가 DB 의
    //   version 을 올리는데 로컬이 옛 값이면, 그 캠페인을 편집할 때 아무것도 안 바꿔도
    //   낙관적 락이 「다른 관리자가 먼저 저장」으로 오판한다(가짜 충돌).
    return db.from('campaigns').update({ status: 'active' }).eq('id', c.id).select('version')
      .then(r => { const v = r?.data?.[0]?.version; if (v != null) c.version = v; return r; });
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
    // 로컬 객체의 version 도 함께 맞춘다 — 이 UPDATE 로 트리거(마이그레이션 275)가 DB 의
    //   version 을 올리는데 로컬이 옛 값이면, 그 캠페인을 편집할 때 아무것도 안 바꿔도
    //   낙관적 락이 「다른 관리자가 먼저 저장」으로 오판한다(가짜 충돌).
    return db.from('campaigns').update({ status: 'closed' }).eq('id', c.id).select('version')
      .then(r => { const v = r?.data?.[0]?.version; if (v != null) c.version = v; return r; });
  }));
  results.forEach((r, i) => {
    if (r.status === 'rejected') console.warn('autoCloseCampaigns 실패:', toClose[i]?.id, r.reason);
  });
  return camps;
}

// 결과물 제출 마감(submission_end) 경과한 closed(모집마감) 캠페인을 ended(종료)로 자동 전이.
//   autoCloseCampaigns 와 동일 방식(목록 조회 시 전이). status 만 변경 — 락 트리거(156)는 보호컬럼 미변경이라 통과.
async function autoEndCampaigns(camps) {
  if (!db) return camps;
  const now = new Date();
  now.setHours(0, 0, 0, 0);
  const toEnd = camps.filter(c => {
    if (c.status !== 'closed' || !c.submission_end) return false;
    const se = new Date(c.submission_end);
    se.setHours(23, 59, 59, 999);
    return now > se;
  });
  if (!toEnd.length) return camps;
  const results = await Promise.allSettled(toEnd.map(c => {
    c.status = 'ended';
    // 로컬 객체의 version 도 함께 맞춘다 — 이 UPDATE 로 트리거(마이그레이션 275)가 DB 의
    //   version 을 올리는데 로컬이 옛 값이면, 그 캠페인을 편집할 때 아무것도 안 바꿔도
    //   낙관적 락이 「다른 관리자가 먼저 저장」으로 오판한다(가짜 충돌).
    return db.from('campaigns').update({ status: 'ended' }).eq('id', c.id).select('version')
      .then(r => { const v = r?.data?.[0]?.version; if (v != null) c.version = v; return r; });
  }));
  results.forEach((r, i) => {
    if (r.status === 'rejected') console.warn('autoEndCampaigns 실패:', toEnd[i]?.id, r.reason);
  });
  return camps;
}

// 캠페인 「노출」 토글 — 사양서 2026-05-13-campaign-visibility-toggle.md
//   OFF 클릭 시: status = 'expired' (수동 노출마감, 인플 화면 완전 비노출)
//   ON  클릭 시: status 를 날짜 기준 자동 재계산 (scheduled/active/closed)
//   migration 129 로 post_deadline 컬럼이 사라졌으므로 expired 전이는 오직 본 함수만 수행.
async function toggleCampaignVisibility(campId, visible) {
  if (!db) return;
  if (visible === false) {
    await retryWithRefresh(async () => {
      const {error} = await db.from('campaigns').update({status: 'expired'}).eq('id', campId);
      if (error) throw error;
    });
    return 'expired';
  }
  // ON: 현재 row 조회 후 날짜 기반 상태 계산
  const {data: row, error: e1} = await db.from('campaigns').select('id, recruit_start, deadline, submission_end').eq('id', campId).maybeSingle();
  if (e1) throw e1;
  if (!row) return null;
  const newStatus = computeCampaignStatus(row);
  await retryWithRefresh(async () => {
    const {error} = await db.from('campaigns').update({status: newStatus}).eq('id', campId);
    if (error) throw error;
  });
  return newStatus;
}

// 날짜 기준 캠페인 상태 자동 계산
//   recruit_start 미도래=scheduled / 모집 마감(deadline 경과) → 제출 마감(submission_end)까지 경과면 ended(종료), 아니면 closed(모집마감) / 그 외=active
function computeCampaignStatus(camp) {
  const now = new Date();
  if (camp.recruit_start) {
    const rs = new Date(camp.recruit_start);
    rs.setHours(0, 0, 0, 0);
    if (rs > now) return 'scheduled';
  }
  if (camp.deadline) {
    const dl = new Date(camp.deadline);
    dl.setHours(23, 59, 59, 999);
    if (dl < now) {
      // 모집 마감 — 결과물 제출 마감까지 지났으면 종료(ended)
      if (camp.submission_end) {
        const se = new Date(camp.submission_end);
        se.setHours(23, 59, 59, 999);
        if (se < now) return 'ended';
      }
      return 'closed';
    }
  }
  return 'active';
}

// ── 캠페인 삭제 복구(soft delete) — 사양서 docs/specs/2026-07-22-campaign-soft-delete-restore.md ──
// PR 1(DB 기반)만 구현. UI(「삭제됨」 탭·확인 모달 교체)는 PR 2 범위.

// 보관 삭제 — RPC soft_delete_campaign(마이그레이션 255). campaign_admin 이상.
// 이 캠페인의 신청(applications)·결과물(deliverables, cascade)을 즉시 완전 삭제하고
// campaigns 행은 deleted_at 만 세팅해 30일간 보관한다(개인정보 즉시 파기 원칙).
// 정산(settlements) 이 걸린 신청이 있으면 251 트리거가 막아 예외로 반환(그대로 throw).
// 반환값 = 삭제된 신청 건수(정보용, 화면에서 안내 문구에 활용 가능).
async function softDeleteCampaign(campaignId) {
  if (!db) throw new Error('DB 미연결');
  let deletedApps = 0;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('soft_delete_campaign', {p_campaign_id: campaignId});
    if (error) throw error;
    deletedApps = data || 0;
  });
  return deletedApps;
}

// 복구 — RPC restore_campaign(마이그레이션 256). campaign_admin 이상.
// deleted_at/deleted_by 를 NULL 로 되돌린다. 신청·결과물은 이미 파기돼 되돌아오지 않음
// (사양서 §의심 1 — 삭제 확인 문구에 명시, PR 2). 이미 활성 캠페인이면 false(멱등).
async function restoreCampaign(campaignId) {
  if (!db) throw new Error('DB 미연결');
  let restored = false;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('restore_campaign', {p_campaign_id: campaignId});
    if (error) throw error;
    restored = !!data;
  });
  return restored;
}

// 완전 삭제 — RPC purge_campaign(마이그레이션 257). super_admin 전용.
// 보관(deleted_at NOT NULL) 상태의 캠페인만 대상 — 활성 캠페인을 실수로 완전삭제하는
// 것을 서버가 원천 차단(활성이면 예외 throw).
async function purgeCampaign(campaignId) {
  if (!db) throw new Error('DB 미연결');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('purge_campaign', {p_campaign_id: campaignId});
    if (error) throw error;
  });
  return true;
}

// 「삭제됨」 탭 전용 조회(PR 2에서 사용 예정) — deleted_at NOT NULL 인 캠페인만.
// fetchCampaigns() 는 반대로 이 캠페인들을 항상 제외하므로 별도 함수로 분리.
// auth_id 배열 → {auth_id: 표시이름} 맵. 캠페인 생성자·삭제자 등 감사 컬럼(auth_id)을 이름으로 표시.
//   admins RLS SELECT 는 is_admin() 이라 관리자만 조회 가능. 없는 id 는 맵에서 빠짐(호출측이 폴백 처리).
async function fetchAdminNamesByIds(authIds) {
  if (!db || !Array.isArray(authIds)) return {};
  const uniq = [...new Set(authIds.filter(Boolean))];
  if (!uniq.length) return {};
  try {
    const {data, error} = await db.from('admins').select('auth_id, name, email').in('auth_id', uniq);
    if (error) throw error;
    const map = {};
    (data||[]).forEach(a => { map[a.auth_id] = a.name || a.email || ''; });
    return map;
  } catch(e) { console.error('[fetchAdminNamesByIds]', e); return {}; }
}

// 캠페인 id 배열 → {id: {campaign_no, title, deleted_at, status}} 맵. 보관/완전삭제 판별 포함(deleted_at 필터 없음).
//   오리엔시트 상세에서 발행 카드의 연결 캠페인 번호·상태 표시용. 맵에 없는 id = 완전 삭제(행 없음).
async function fetchCampaignsByIds(ids) {
  if (!db || !Array.isArray(ids)) return {};
  const uniq = [...new Set(ids.filter(Boolean))];
  if (!uniq.length) return {};
  try {
    const {data, error} = await db.from('campaigns').select('id, campaign_no, title, deleted_at, status').in('id', uniq);
    if (error) throw error;
    const map = {};
    (data||[]).forEach(c => { map[c.id] = c; });
    return map;
  } catch (e) { console.error('[fetchCampaignsByIds]', e); return {}; }
}

async function fetchDeletedCampaigns() {
  if (!db) return [];
  try {
    const data = await fetchAllPaged(() =>
      db.from('campaigns').select('*').not('deleted_at', 'is', null).order('deleted_at', {ascending: false})
    );
    return data;
  } catch (e) {
    console.error('fetchDeletedCampaigns:', e);
    return [];
  }
}

async function insertCampaign(camp) {
  if (!db) return null;
  // 삽입된 캠페인 id 반환 (오리엔시트 발행 소비 등에서 사용 — 기존 호출부는 반환값 무시라 호환)
  return await retryWithRefresh(async () => {
    const {data, error} = await db.from('campaigns').insert(camp).select('id').maybeSingle();
    if (error) throw error;
    return data?.id || null;
  });
}

async function updateCampaign(campId, updates, expectedVersion) {
  if (!db) return {ok: true};
  // 관리자 편집 경로 전용 — 호출 시점에 수정일 자동 갱신
  // (조회수/자동 종료 등 시스템 UPDATE는 이 함수를 거치지 않아 수정일 오염 없음)
  //
  // expectedVersion 을 넘기면 **동시 저장 방어**(낙관적 락, 마이그레이션 275).
  //   편집 화면을 연 시점의 version 과 다르면(= 그 사이 누군가 저장했으면) 조건에 안 맞아
  //   0행 UPDATE 가 되고 {ok:false, conflict:true} 를 돌려준다. 안 넘기면 기존과 동일 동작이라
  //   상태 드롭다운·순서 변경 등 다른 호출부는 영향 없다.
  const payload = { ...updates, updated_at: new Date().toISOString() };
  return await retryWithRefresh(async () => {
    let q = db.from('campaigns').update(payload).eq('id', campId);
    if (expectedVersion !== undefined && expectedVersion !== null) q = q.eq('version', expectedVersion);
    // ⚠️ version 컬럼을 조회하는 건 낙관적 락을 쓸 때만. 안 그러면 마이그레이션 275 가 아직
    //    적용되지 않은 환경에서 상태 드롭다운·순서 변경까지 「column version does not exist」로
    //    죽는다(코드가 데이터베이스보다 먼저 배포되면 캠페인 쓰기 전체가 멈춘다).
    const useLock = (expectedVersion !== undefined && expectedVersion !== null);
    const {data, error} = await q.select(useLock ? 'id, version' : 'id');
    if (error) throw error;
    if (useLock && (!data || data.length === 0)) return {ok: false, conflict: true};
    return {ok: true, version: (useLock && data && data[0]) ? data[0].version : null};
  });
}

// 캠페인 상세 조회수 +1.
// ⚠️ campaigns 테이블을 직접 UPDATE 하면 안 된다 — UPDATE 정책이 관리자 한정(마이그레이션 001)
//    이라 인플루언서·비로그인 조회가 조용히 0행 처리되어 집계가 통째로 누락됐다(마이그레이션 263).
//    반드시 increment_campaign_view 함수 경유(원자적 증가 + 관리자·감사용 계정 제외).
// 같은 기기에서 같은 캠페인을 하루에 여러 번 열어도 1회만 센다(새로고침·뒤로가기·언어 전환으로
// 부풀지 않도록). 날짜 기준은 일본/한국 표준시(+09:00).
const VIEW_COUNT_SEEN_KEY = 'reverb.viewedCampaigns';

function _viewCountTodayKst() {
  const now = new Date();
  const kst = new Date(now.getTime() + (now.getTimezoneOffset() * 60000) + (9 * 3600000));
  return kst.getFullYear() + '-' + String(kst.getMonth() + 1).padStart(2, '0')
    + '-' + String(kst.getDate()).padStart(2, '0');
}

// 오늘 이미 센 캠페인이면 false. 아니면 기록하고 true.
// 저장소를 못 쓰는 환경(사생활 보호 모드 등)에서는 게이트 없이 통과시킨다(집계 누락 방지).
function _markCampaignViewed(campId) {
  const today = _viewCountTodayKst();
  try {
    const raw = localStorage.getItem(VIEW_COUNT_SEEN_KEY);
    const seen = raw ? JSON.parse(raw) : {};
    if (seen[campId] === today) return false;
    // 날짜가 바뀐 항목은 정리 (무한 증식 방지)
    const fresh = {};
    Object.keys(seen).forEach(k => { if (seen[k] === today) fresh[k] = today; });
    fresh[campId] = today;
    localStorage.setItem(VIEW_COUNT_SEEN_KEY, JSON.stringify(fresh));
    return true;
  } catch (e) {
    return true;
  }
}

async function incrementViewCount(campId) {
  if (!db || !campId) return;
  if (!_markCampaignViewed(campId)) return;
  await db.rpc('increment_campaign_view', { p_campaign_id: campId });
}

// ── Influencers ──
// includeAudit 기본 true = 기존 동작 보존(전건 반환).
// 통계·엑셀 등 실수 집계가 필요한 호출처만 { includeAudit: false } 를 명시 전달(PR D/F에서).
// 조회 경로는 influencers_admin_view(마이그레이션 212, security_invoker=true라 기존 RLS 그대로
// 적용) 경유 — 관리자 권한 등급에 따라 phone/line_id/paypal_email/zip/building/address 6종을
// 서버가 NULL 마스킹한다(PR3 조각 B, 2026-07-06). ⚠️ 이 함수는 읽기 전용 — 쓰기는 반드시
// base 테이블 influencers 를 쓰는 upsertInfluencer/updateInfluencer 로 (뷰는 읽기 전용).
async function fetchInfluencers(opts = {}) {
  if (!db) return [];
  const { includeAudit = true } = opts;
  try {
    return await fetchAllPaged(() => {
      let q = db.from('influencers_admin_view').select('*').order('created_at', {ascending: true});
      if (!includeAudit) q = q.eq('is_audit', false);
      return q;
    });
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

// 연령·성별 분포 집계 — 대시보드 카드용 (computePrefectureStats 패턴: 추가 쿼리 없이 배열만 집계).
// 연령대=마케팅 구간(18-24/25-29/30-34/35-39/40-49/50+) + 미등록 + 이상치(생년월일 있으나 18세 미만/비현실).
// 성별=male/female/other/undisclosed + unregistered(미등록). 연령×성별 교차표 cross 포함.
// 만 나이는 shared.js calcAgeFromBirthdate(KST) 재사용. 감사용 격리는 호출부(statsUsers)에서 선처리.
const AGE_GENDER_BUCKETS = ['18-24', '25-29', '30-34', '35-39', '40-49', '50+'];
function computeAgeGenderStats(users) {
  const rows = Array.isArray(users) ? users : [];
  const genders = ['male', 'female', 'other', 'undisclosed'];
  const bucketOf = (age) => {
    if (age == null || age < 18 || age > 120) return null; // 미등록/이상치
    if (age <= 24) return '18-24';
    if (age <= 29) return '25-29';
    if (age <= 34) return '30-34';
    if (age <= 39) return '35-39';
    if (age <= 49) return '40-49';
    return '50+';
  };

  const ageCounts = {}; AGE_GENDER_BUCKETS.forEach(l => { ageCounts[l] = 0; });
  let ageUnregistered = 0, ageInvalid = 0;
  const gender = { male: 0, female: 0, other: 0, undisclosed: 0, unregistered: 0 };
  const cross = {}; [...AGE_GENDER_BUCKETS, '미등록'].forEach(l => { cross[l] = { male: 0, female: 0, other: 0, undisclosed: 0, unregistered: 0 }; });

  let ageRegistered = 0, genderRegistered = 0;
  for (const row of rows) {
    const bd = row && row.birthdate ? String(row.birthdate) : '';
    const age = (typeof calcAgeFromBirthdate === 'function') ? calcAgeFromBirthdate(bd) : null;
    const bucket = bucketOf(age);
    const g = genders.includes(row && row.gender) ? row.gender : 'unregistered';

    if (bucket) { ageCounts[bucket]++; ageRegistered++; }
    else if (bd && age != null) { ageInvalid++; }   // 생년월일 있으나 18세 미만/비현실값 = 이상치
    else { ageUnregistered++; }                       // 생년월일 미입력/파싱 실패 = 미등록

    gender[g]++;
    if (g !== 'unregistered') genderRegistered++;

    cross[bucket || '미등록'][g]++;
  }

  const ageBuckets = AGE_GENDER_BUCKETS.map(l => ({ label: l, count: ageCounts[l] }));
  ageBuckets.push({ label: '미등록', count: ageUnregistered });
  if (ageInvalid > 0) ageBuckets.push({ label: '이상치', count: ageInvalid });

  return { total: rows.length, ageRegistered, genderRegistered, ageBuckets, gender, cross, ageInvalid };
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
  // cacheControl: '86400' — 증빙 파일도 동일 캐시 정책. signed URL 만료(1h)와 무관하게 브라우저 캐시 활용
  const {error} = await db.storage.from(BUCKET).upload(path, file, {contentType: file.type, upsert: false, cacheControl: '86400'});
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

// ── 대리 등록 증빙 파일 업로드 (campaign_admin 이상, 마이그레이션 163) ──
// file: File 객체
// ref: deliverable_id 또는 'tmp/{timestamp}' 등 임시값
// 반환: Storage 경로 문자열 (admin-proxy-evidence 버킷 기준)
async function uploadProxyEvidence(file, ref) {
  if (!db) throw new Error('DB 미연결');
  const BUCKET = 'admin-proxy-evidence';
  const ext = file.name ? file.name.split('.').pop().toLowerCase() : 'bin';
  const uuid = crypto.randomUUID ? crypto.randomUUID() : (Date.now().toString(36) + Math.random().toString(36).substring(2));
  const path = `${ref}/${uuid}.${ext}`;
  const {error} = await db.storage.from(BUCKET).upload(path, file, {contentType: file.type, upsert: false, cacheControl: '86400'});
  if (error) throw error;
  return path;
}

// ── 대리 등록 증빙 signed URL 조회 (campaign_admin 이상, 마이그레이션 163) ──
// path: uploadProxyEvidence() 반환값 (Storage 경로)
// expiresIn: 초 단위, 기본 3600 (1시간)
async function getProxyEvidenceSignedUrl(path, expiresIn = 3600) {
  if (!db || !path) return null;
  const BUCKET = 'admin-proxy-evidence';
  const {data, error} = await db.storage.from(BUCKET).createSignedUrl(path, expiresIn);
  if (error) throw error;
  return data?.signedUrl || null;
}

// ── 대리 등록 증빙 파일 삭제 (super_admin 전용, 마이그레이션 163) ──
// paths: Storage 경로 배열
async function deleteProxyEvidenceFiles(paths) {
  if (!db || !paths || paths.length === 0) return;
  const BUCKET = 'admin-proxy-evidence';
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
  // CUD 함수는 세션 만료 시 자동 갱신 후 1회 재시도 (다른 쓰기 함수와 동일 패턴)
  await retryWithRefresh(async () => {
    const {error} = await db.from('influencers').update(normalized).eq('id', userId);
    if (error) throw error;
  });
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
  // cancelled 행은 재응모 허용을 위해 중복으로 보지 않는다 (migration 104,
  // partial unique index `applications_user_camp_active_uidx` 와 일치).
  const {data} = await db.from('applications')
    .select('id')
    .eq('user_id', userId)
    .eq('campaign_id', campaignId)
    .neq('status', 'cancelled')
    .maybeSingle();
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
// 사이드바 배지용 — 검수대기 "신청" 개수 (마이그레이션 248 count_pending_review_applications RPC).
//   과거엔 deliverables 를 status='pending' 조건으로 행 단위 COUNT 했는데, 결과물은 재제출마다
//   새 행을 INSERT 하고 옛 행은 이력 보존을 위해 남겨두는 설계라 이미 대체된 옛 pending 행까지
//   중복으로 세어 배지가 과대 표시됐다(운영 관측치 31건 vs 실제 검수 필요 신청 수). RPC 는
//   신청(application) 단위 + 각 결과물의 (kind, post_channel) 조합별 최신 1건만 판정해 정확히 센다.
//   반려·취소(rejected/cancelled) 신청은 RPC 내부에서 이미 제외("검수 불필요").
async function fetchPendingDeliverableCount() {
  if (!db) return 0;
  try {
    const {data, error} = await db.rpc('count_pending_review_applications');
    if (error) throw error;
    return data || 0;
  } catch(e) { console.error('[fetchPendingDeliverableCount]', e); return 0; }
}

// 신청 관리 사이드바 배지용 — 대기(pending) 신청 개수만 가볍게 조회 (전건 fetch 대체)
async function fetchPendingApplicationCount() {
  if (!db) return 0;
  try {
    const {count, error} = await db?.from('applications')
      .select('id', {count: 'exact', head: true})
      .eq('status', 'pending');
    if (error) throw error;
    return count || 0;
  } catch(e) { console.error('[fetchPendingApplicationCount]', e); return 0; }
}

// 관리자용: 결과물 리스트 + 캠페인/인플루언서 정보 조인
async function fetchDeliverables(filters) {
  if (!db) return [];
  try {
    const data = await fetchAllPaged(() => {
      let q = db.from('deliverables').select(`
        id, kind, status, version,
        receipt_url, order_number, purchase_date, purchase_amount, memo,
        post_url, post_channel, post_submissions,
        reject_reason, reject_template_code,
        reviewed_by, reviewed_at, submitted_at, updated_at,
        application_id, user_id, campaign_id,
        submitted_by_admin, submitted_by_admin_reason_code, submitted_by_admin_reason, submitted_by_admin_at,
        submitted_by_admin_evidence,
        applications:application_id (status),
        campaigns:campaign_id (id, campaign_no, title, brand, recruit_type, channel, channel_match, purchase_start, purchase_end, visit_start, visit_end, submission_end)
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

// (2026-07-23) updateApplicationOrientedAt 제거 — 「오리엔시트 발송」 체크 기능 폐기.
//   applications.oriented_at 컬럼과 기존 기록은 그대로 보존한다(되살릴 때 이 함수만 복구하면 됨).

// Stage 6: 본인 알림 조회 (마이페이지 상단 알림 섹션용)
// 관리자는 RLS SELECT 정책으로 전체 알림 SEE 가능하므로 명시적 user_id 필터 필수
async function fetchMyNotifications(opts) {
  if (!db) return [];
  try {
    const {data: s} = await db.auth.getUser();
    const uid = s?.user?.id;
    if (!uid) return [];
    let q = db?.from('notifications').select('*').eq('user_id', uid).order('created_at', {ascending: false});
    // 정산 잠금(관리자만 기록) 중에는 정산 알림 2종을 목록·미읽음 배지 양쪽에서 제외.
    // 단일 지점에서 걸러야 「배지 숫자는 있는데 목록은 비어있음」 불일치가 안 생긴다
    // (refreshNotifBadge 가 이 함수 결과 개수를 그대로 배지에 쓰므로).
    if (typeof settlementPublic === 'function' && !settlementPublic()) {
      q = q.not('kind', 'in', '(settlement_paid,settlement_paypal_required)');
    }
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

// 특정 참조(ref_table+ref_id)의 미읽음 알림 일괄 읽음 처리.
//   같은 결과물(deliverables)·신청(applications)에 대해 trigger 가 여러 건 INSERT 한 경우
//   (예: 관리자가 검수대기 되돌리기 후 재처리 → deliverable_changed + deliverable_rejected)
//   사용자가 알림 1건 클릭만으로 해당 참조의 모든 미읽음을 일괄 정리.
async function markNotificationsReadByRef(refTable, refId) {
  if (!db || !refTable || !refId) return;
  const uid = (typeof currentUser !== 'undefined' && currentUser) ? currentUser.id : null;
  if (!uid) return;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('notifications')
        .update({read_at: new Date().toISOString()})
        .eq('user_id', uid)
        .eq('ref_table', refTable)
        .eq('ref_id', refId)
        .is('read_at', null);
      if (error) throw error;
    });
  } catch(e) { console.error('[markNotificationsReadByRef]', e); }
}

// 특정 응모건의 미읽음 message_received 알림 일괄 읽음 처리
// (응모이력에서 메시지 모달을 직접 열람한 경우 — 알림 모달을 거치지 않아도
//  해당 건 알림이 남지 않도록). RLS 는 markNotificationRead 와 동일 (본인 행 UPDATE).
async function markMessageNotificationsRead(applicationId) {
  if (!db || !applicationId) return;
  const uid = (typeof currentUser !== 'undefined' && currentUser) ? currentUser.id : null;
  if (!uid) return;
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('notifications')
        .update({read_at: new Date().toISOString()})
        .eq('user_id', uid)
        .eq('kind', 'message_received')
        .eq('ref_id', applicationId)
        .is('read_at', null);
      if (error) throw error;
    });
  } catch(e) { console.error('[markMessageNotificationsRead]', e); }
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

// 본인 응모 취소 완료 알림 (notifications kind='application_cancelled')
// 사양 §4-10. RPC 호출 성공 직후 클라이언트가 1건 INSERT.
// 헤더 햄버거 미읽음 배지에 즉시 반영 + 다른 디바이스 동기 확인 용도.
async function insertApplicationCancelledNotification(applicationId, campaignTitle) {
  if (!db) return;
  try {
    const {data: s} = await db.auth.getUser();
    const uid = s?.user?.id;
    if (!uid) return;
    // 사양 §4-10 라벨: 「応募を取り消しました — {キャンペーン名}」.
    // notifications.title 은 INSERT 시점 텍스트가 굳어지므로 일본어 고정
    // (인플루언서 기본 언어 ja). 다국어 토글은 알림 렌더 코드에서 kind
    // 기반으로 별도 처리.
    const titleText = campaignTitle
      ? `応募を取り消しました — ${campaignTitle}`
      : '応募を取り消しました';
    await retryWithRefresh(async () => {
      const {error} = await db.from('notifications').insert({
        user_id:   uid,
        kind:      'application_cancelled',
        ref_table: 'applications',
        ref_id:    applicationId,
        title:     titleText,
        body:      null
      });
      if (error) throw error;
    });
  } catch(e) {
    // 알림 INSERT 실패는 사용자 흐름 차단 안 함 (취소 자체는 RPC 로 이미 성공)
    console.warn('[insertApplicationCancelledNotification]', e);
  }
}

// 캠페인 단위로 결과물 전체 조회 (진행현황 탭 — 여러 신청자 일괄)
async function fetchDeliverablesByCampaign(campaignId) {
  if (!db) return [];
  try {
    const {data, error} = await db?.from('deliverables')
      .select('id, application_id, campaign_id, user_id, kind, status, reviewed_at, submitted_at, updated_at, version, post_url, post_channel, receipt_url, purchase_date, purchase_amount, reject_reason, submitted_by_admin, submitted_by_admin_reason_code, submitted_by_admin_reason, submitted_by_admin_at, submitted_by_admin_evidence, applications:application_id (status)')
      .eq('campaign_id', campaignId)
      .order('submitted_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchDeliverablesByCampaign]', e); return []; }
}

// 응모건(application) 1건의 기존 결과물 조회 — 관리자 대리 등록 모달 사전 안내용 (is_admin SELECT)
//   필요한 컬럼만 경량 조회. 인플 선택 시 1건만 부르므로 가벼움.
async function fetchDeliverablesByApplication(applicationId) {
  if (!db || !applicationId) return [];
  try {
    const {data, error} = await db?.from('deliverables')
      .select('id, kind, status, post_channel, post_url, reject_reason, submitted_at, created_at')
      .eq('application_id', applicationId)
      .order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchDeliverablesByApplication]', e); return []; }
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
    // review_image + post_channel 지정 시: 마이그레이션 158 UNIQUE 부분 인덱스 충돌 방지.
    //   DELETE+INSERT 패턴은 RLS DELETE 정책 부재 또는 트랜잭션 분리로 0행 삭제 시 UNIQUE 위반
    //   ('이미 등록된 데이터' 토스트) 발생 — 사양 §3-2 「재제출은 기존 행 UPDATE」 권고로 전환.
    //   기존 행 있으면 status='draft' 로 되돌리고 이미지·반려사유 비움. 없으면 아래 INSERT 진행.
    //   (deliverable_events 이력은 037 트리거가 status 전이 시 자동 INSERT)
    if (payload.kind === 'review_image' && payload.post_channel) {
      const {data: existing, error: selErr} = await db?.from('deliverables')
        .select('id')
        .eq('application_id', payload.application_id)
        .eq('kind', 'review_image')
        .eq('post_channel', payload.post_channel)
        .maybeSingle();
      if (selErr) throw selErr;
      if (existing?.id) {
        const {error: upErr} = await db?.from('deliverables')
          .update({
            status: 'draft',
            receipt_url: payload.receipt_url || null,
            reject_reason: null,
            reject_template_code: null,
            reviewed_by: null,
            reviewed_at: null
          })
          .eq('id', existing.id);
        if (upErr) throw upErr;
        id = existing.id;
        return;  // 기존 행 갱신 완료 — INSERT 스킵
      }
    }
    // post(게시물 URL) 제출: 채널마다 게시물 1건(교체). review_image 패턴과 동일하게 post_channel 기준 탐색.
    //   (2026-06-02 사용자 결정: 기프팅/방문형 게시물은 채널별 1건 — 같은 채널 재제출은 같은 URL/다른 URL 모두 교체)
    //   같은 채널의 기존 post 행이 있으면 그 행을 새 URL 로 교체(post_submissions 누적), 없으면 INSERT.
    //   기존 행이 approved(승인)면 되돌리지 않고 차단(승인 결과물 draft 추락 방지).
    //   ⚠️ 과거 버그(URL별 별도 행)로 같은 채널 post 가 여러 행일 수 있어 maybeSingle 대신 가장 오래된 1건 교체.
    //   사양서 docs/specs/2026-06-02-deliverable-post-url-duplicate-fix.md (채널별 1건으로 정정)
    if (payload.kind === 'post' && payload.post_channel) {
      const {data: existRows, error: selErr} = await db?.from('deliverables')
        .select('id, status, post_submissions')
        .eq('application_id', payload.application_id)
        .eq('kind', 'post')
        .eq('post_channel', payload.post_channel)
        .order('created_at', { ascending: true })
        .limit(1);
      if (selErr) throw selErr;
      const existing = existRows && existRows[0];
      if (existing?.id) {
        if (existing.status === 'approved') {
          // 승인된 게시물은 재제출로 덮어쓰지 않음
          const apErr = new Error('この投稿は既に承認済みです。');
          apErr.code = 'post_already_approved';
          throw apErr;
        }
        const prevSubs = Array.isArray(existing.post_submissions) ? existing.post_submissions : [];
        const {error: upErr} = await db?.from('deliverables')
          .update({
            status: 'draft',
            post_url: payload.post_url || null,   // 채널별 교체 — 새 URL 로 갱신
            reject_reason: null,
            reject_template_code: null,
            reviewed_by: null,
            reviewed_at: null,
            post_submissions: [...prevSubs, {url: payload.post_url, channel: payload.post_channel, submitted_at: new Date().toISOString()}]
          })
          .eq('id', existing.id);
        if (upErr) throw upErr;
        id = existing.id;
        return;  // 기존 행 갱신 완료 — INSERT 스킵
      }
    }
    const row = {
      application_id: payload.application_id,
      user_id: payload.user_id,
      campaign_id: payload.campaign_id,
      kind: payload.kind,            // 'post' | 'receipt' | 'review_image'
      status: 'draft',
      post_url: payload.post_url || null,
      post_channel: payload.post_channel || null,
      post_submissions: payload.kind === 'post'
        ? [{url: payload.post_url, channel: payload.post_channel, submitted_at: new Date().toISOString()}]
        : [],
      receipt_url: payload.receipt_url || null,
      memo: payload.memo || null,
      // 영수증(monitor) 전용 3종 필수 필드 — 마이그레이션 128
      order_number: payload.order_number || null,
      purchase_date: payload.purchase_date || null,
      purchase_amount: (payload.purchase_amount === undefined || payload.purchase_amount === null || payload.purchase_amount === '')
        ? null
        : Number(payload.purchase_amount)
    };
    const {data, error} = await db?.from('deliverables').insert(row).select('id').maybeSingle();
    if (error) throw error;
    id = data?.id || null;
  });
  return id;
}

// ─── 영수증 관리자 수정 (마이그레이션 128) ──────────────────
// campaign_admin 이상만 호출 가능. RPC가 권한·입력값을 이중 검증함.
async function updateReceiptAdmin(deliverableId, orderNumber, purchaseDate, purchaseAmount) {
  if (!db) throw new Error('DB 미연결');
  let ok = false;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('update_receipt_admin', {
      p_deliverable_id:  deliverableId,
      p_order_number:    orderNumber,
      p_purchase_date:   purchaseDate,
      p_purchase_amount: purchaseAmount
    });
    if (error) throw error;
    ok = true;
  });
  return ok;
}

// ─── 관리자 결과물 대리 등록·자동 승인 (마이그레이션 160) ──────────────────
// campaign_admin 이상만 호출 가능. RPC가 권한·신청 상태(approved)·필수 필드·UNIQUE 사전 체크함.
// payload 형태:
//   { applicationId, kind: 'receipt'|'post'|'review_image',
//     postChannel, imageUrl, postUrl,
//     orderNumber, purchaseDate, purchaseAmount,
//     reasonCode, reason }
// 반환: 신규 deliverable id (uuid)
async function adminCreateDeliverableProxy(payload) {
  if (!db) throw new Error('DB 미연결');
  if (!payload || !payload.applicationId || !payload.kind || !payload.reasonCode) {
    throw new Error('필수 입력 누락: applicationId / kind / reasonCode');
  }
  let newId = null;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('admin_create_deliverable_proxy', {
      p_application_id:  payload.applicationId,
      p_kind:            payload.kind,
      p_post_channel:    payload.postChannel || null,
      p_image_url:       payload.imageUrl    || null,
      p_post_url:        payload.postUrl     || null,
      p_order_number:    payload.orderNumber || null,
      p_purchase_date:   payload.purchaseDate || null,
      p_purchase_amount: payload.purchaseAmount ?? null,
      p_reason_code:     payload.reasonCode,
      p_reason:          payload.reason || null,
      p_evidence_paths:  payload.evidencePaths || []  // 마이그레이션 163: 증빙 경로 배열 (기본 빈 배열)
    });
    if (error) throw error;
    newId = data;
  });
  return newId;
}

// 대리 등록 회수 (super_admin 전용, 마이그레이션 160·163).
// 잘못 등록된 대리 등록 결과물을 삭제 + audit 1건 기록.
// 마이그레이션 163: RPC가 삭제된 증빙 파일 경로 배열을 반환 → 클라이언트에서 Storage 파일 별도 삭제.
// Storage 삭제 실패 시 회수 자체는 성공으로 처리 (경고 토스트만).
async function adminRevokeProxyDeliverable(deliverableId, reason) {
  if (!db) throw new Error('DB 미연결');
  if (!deliverableId) throw new Error('deliverableId 누락');
  let evidencePaths = [];
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('admin_revoke_proxy_deliverable', {
      p_deliverable_id: deliverableId,
      p_reason:         reason || null
    });
    if (error) throw error;
    // 마이그레이션 163: RPC 반환값 = text[] (증빙 경로 배열)
    evidencePaths = Array.isArray(data) ? data : [];
  });
  // Storage 증빙 파일 삭제 — 실패해도 회수 자체는 성공 처리 (고아 파일 경고만)
  if (evidencePaths.length > 0) {
    try {
      await deleteProxyEvidenceFiles(evidencePaths);
    } catch (storageErr) {
      console.warn('[admin-proxy] 증빙 파일 Storage 삭제 실패 (회수는 완료됨):', storageErr);
      // 호출부에서 toast로 경고 표시 가능하도록 에러 정보 반환
      return {ok: true, storageDeleteFailed: true};
    }
  }
  return {ok: true, storageDeleteFailed: false};
}

// 채널 미지정 review_image 행에 채널 지정 / 해제 (마이그레이션 162)
//   postChannel 있으면 지정, NULL/빈값이면 해제(검수 전 pending/draft만). campaign_admin 이상.
async function assignReviewImageChannel(deliverableId, postChannel) {
  if (!db) throw new Error('DB 미연결');
  if (!deliverableId) throw new Error('deliverableId 누락');
  let ok = false;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('assign_review_image_channel', {
      p_deliverable_id: deliverableId,
      p_post_channel:   postChannel || null
    });
    if (error) throw error;
    ok = true;
  });
  return ok;
}

// 지정 불가(빈 채널 0개) 레거시 review_image 삭제 (마이그레이션 162, super_admin 전용)
async function deleteLegacyReviewImage(deliverableId, reason) {
  if (!db) throw new Error('DB 미연결');
  if (!deliverableId) throw new Error('deliverableId 누락');
  let ok = false;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('delete_legacy_review_image', {
      p_deliverable_id: deliverableId,
      p_reason:         reason || null
    });
    if (error) throw error;
    ok = true;
  });
  return ok;
}

// 잘못된 채널 게시물(post) 결과물 삭제 (super_admin, 마이그레이션 183).
//   캠페인 요구 채널과 다른 채널로 잘못 저장된 post 행 정리. 서버에서 채널 불일치·승인 보호 재검증.
async function deleteMismatchedPostDeliverable(deliverableId, reason) {
  if (!db) throw new Error('DB 미연결');
  if (!deliverableId) throw new Error('deliverableId 누락');
  let ok = false;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('delete_mismatched_post_deliverable', {
      p_deliverable_id: deliverableId,
      p_reason:         reason || null
    });
    if (error) throw error;
    ok = true;
  });
  return ok;
}

// 영수증 변경 이력 조회 (모든 관리자 SELECT 가능)
// 마이그레이션 252/253 — 결과물이 하드 삭제되면 deliverable_id 가 NULL 로 비워지고
// (CASCADE→SET NULL) deliverable_id_snapshot 에 원래 id 가 영구 보존된다. 살아있는
// 결과물과 삭제된 결과물의 이력을 같은 함수로 조회할 수 있도록 둘 다 매칭한다.
async function fetchReceiptEditHistory(deliverableId) {
  if (!db || !deliverableId) return [];
  let rows = [];
  try {
    await retryWithRefresh(async () => {
      const {data, error} = await db.from('receipt_edit_history')
        .select('*')
        .or(`deliverable_id.eq.${deliverableId},deliverable_id_snapshot.eq.${deliverableId}`)
        .order('changed_at', {ascending: false});
      if (error) throw error;
      rows = Array.isArray(data) ? data : [];
    });
  } catch(e) { console.error('[fetchReceiptEditHistory]', e); }
  return rows;
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
  // 반환 {count, failed, error} — 부분 성공을 호출부가 구분할 수 있어야 한다.
  //   ⚠️ 예전에는 kind 단위로 **한 번의 UPDATE 문**으로 전부 pending 으로 올렸다. 그러면
  //      제출 마감 검사 장치(마이그레이션 274)가 한 행을 거부할 때 PostgreSQL 문장 원자성 때문에
  //      **정당한 다른 채널의 제출까지 함께 롤백**된다. 예: 인스타그램은 마감 전에 올려두고
  //      제출을 미뤄 자격이 없고(반려 이력 없음), 틱톡은 마감 후 반려→재제출로 정당한데,
  //      「提出」 한 번에 둘이 같이 올라가면서 틱톡까지 실패한다.
  //      그래서 **행별로 나눠** UPDATE 한다. 일부만 성공해도 그만큼은 제출된다.
  if (!db || !applicationId) return {count: 0, failed: 0, error: null};
  let count = 0, failed = 0, firstErr = null;
  await retryWithRefresh(async () => {
    count = 0; failed = 0; firstErr = null;   // 세션 갱신 후 재시도 시 누적 방지
    let q = db.from('deliverables').select('id')
      .eq('application_id', applicationId)
      .eq('status', 'draft');
    if (kind) q = q.eq('kind', kind);
    const {data: drafts, error: selErr} = await q;
    if (selErr) throw selErr;
    for (const row of (drafts || [])) {
      try {
        const {error} = await db.from('deliverables').update({status: 'pending'}).eq('id', row.id);
        if (error) throw error;
        count++;
        // 제출 이벤트 로그 (RPC submit_deliverable) — 실패해도 제출 자체는 유효하므로 무음
        try { await db.rpc('submit_deliverable', {p_deliverable_id: row.id}); }
        catch(e) { console.error('[submit_deliverable rpc]', e); }
      } catch(e) {
        failed++;
        if (!firstErr) firstErr = e;
        console.error('[submitDrafts row]', row.id, e);
      }
    }
  });
  // 한 건도 못 올렸고 사유가 있으면 호출부로 전파한다 (사양서 §설계 6 「2단계 필수」).
  //   삼키면 화면이 「提出するものがありません(제출할 것이 없습니다)」라는 틀린 안내를 띄운다.
  if (count === 0 && firstErr) throw firstErr;
  return {count, failed, error: firstErr};
}

// 결과물 제출 가부 배치 조회 (마이그레이션 276) — 사양서 2026-07-29 §설계 3-(1)
//   그 신청에 필요한 항목(영수증 / 캠페인 채널별 게시물 / 캠페인 채널별 리뷰 인증샷)마다
//   서버가 판정한 allowed/reason 을 한 번에 받아온다. **화면은 이 결과만 소비하고
//   같은 판정을 다시 구현하지 않는다**(판정 단일 소스).
//   실패하면 null — 호출부는 그때 폼을 열어 둔다(막지 않는다). 최종 방어선은 트리거라
//   마감 후 제출은 어차피 서버가 거부하고, 일시적 조회 실패로 정상 제출을 막는 게 더 나쁘다.
async function fetchDeliverableGate(applicationId) {
  if (!db || !applicationId) return null;
  try {
    const {data, error} = await db.rpc('get_deliverable_gate', {p_application_id: applicationId});
    if (error) throw error;
    return Array.isArray(data) ? data : null;
  } catch(e) {
    console.error('[fetchDeliverableGate]', e);
    return null;
  }
}

// 여러 user_id(auth.uid)에 대응하는 influencers 행을 map 형태로 반환
// influencers_admin_view 경유(PR3 조각 B) — line_id 는 권한에 따라 NULL 마스킹될 수 있어
// has_line(마스킹 무관 항상 정확한 존재 여부)도 함께 조회해 화면에서 구분 표시.
async function fetchInfluencersByIds(userIds) {
  if (!db || !userIds?.length) return {};
  try {
    const {data, error} = await db?.from('influencers_admin_view')
      .select('id, name, name_kana, email, primary_sns, line_id, has_line, is_verified, verified_at, is_blacklisted, blacklisted_at, blacklist_reason_code, blacklist_reason_note, is_audit')
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
  // cacheControl: '86400' — 응답 헤더에 cache-control: max-age=86400 부여 → 브라우저 24h 캐시
  //   재방문 시 transform/object API 재호출 차단, Storage Image Transformations 월 한도 보호
  var {error} = await db.storage.from('campaign-images').upload(path, blob, {contentType: mime, upsert: false, cacheControl: '86400'});
  if (error) throw error;
  // 공개 URL 반환
  var {data} = db.storage.from('campaign-images').getPublicUrl(path);
  return data.publicUrl;
}

// 미니 에디터(참여방법/주의사항/NG)용 콘텐츠 이미지 업로드.
//   - 파일 객체(File/Blob) 직접 업로드 (base64 변환 단계 생략 — 메모리 절약)
//   - 클라이언트 1차 검증: 5MB 이하 + image/jpeg|png|webp 만
//   - 저장 경로: campaign-images 버킷의 `content/` 폴더
//   - cacheControl 86400 (24시간) — 첫 캠페인 상세 진입 후 재진입 빠른 로드
//   - 반환: 공개 URL (https). DB에는 이 URL 을 jsonb 안 html 필드에 <img src> 로 삽입
async function uploadContentImage(file) {
  if (!db) throw new Error('storage_unavailable');
  if (!file || !file.size) throw new Error('file_required');

  var MAX_SIZE = 5 * 1024 * 1024;   // 5MB
  var ALLOWED  = ['image/jpeg', 'image/png', 'image/webp'];

  if (!ALLOWED.includes(file.type)) {
    throw new Error('file_type_not_allowed');   // 호출자가 i18n 토스트로 변환
  }
  if (file.size > MAX_SIZE) {
    throw new Error('file_too_large');
  }

  // 파일 경로: content/타임스탬프_랜덤.ext
  var ext = file.type.split('/')[1] === 'jpeg' ? 'jpg' : file.type.split('/')[1];
  var path = 'content/' + Date.now() + '_' + Math.random().toString(36).substring(2, 8) + '.' + ext;

  var {error} = await db.storage.from('campaign-images').upload(path, file, {
    contentType: file.type,
    upsert: false,
    cacheControl: '86400'
  });
  if (error) throw error;

  var {data} = db.storage.from('campaign-images').getPublicUrl(path);
  return data.publicUrl;
}

// 캠페인 저장 직전 현재 version 만 가볍게 조회 (동시 저장 방어 사전 확인용).
//   편집 저장에서 **이미지를 업로드하기 전에** 충돌을 먼저 걸러내는 데 쓴다 —
//   업로드부터 하면 충돌 시 참조 없는 파일이 저장소에 남는다(고아 파일).
//   행이 없거나 조회 실패면 null → 호출부는 그때 사전 확인을 건너뛴다
//   (최종 방어선은 updateCampaign 의 조건부 UPDATE 이므로 막지 않는다).
async function fetchCampaignVersion(id) {
  if (!db || !id) return null;
  try {
    const {data, error} = await db.from('campaigns').select('version').eq('id', id).maybeSingle();
    if (error) throw error;
    return data ? data.version : null;
  } catch(e) {
    console.warn('[fetchCampaignVersion]', e);
    return null;
  }
}

// 채널 코드 어긋남 감지 (마이그레이션 277·278).
//   A=결과물 채널이 그 캠페인 요구 채널에 없음(실제 피해) / B=캠페인 채널이 기준
//   데이터에 없음(조기 경보) / C=결과물 채널이 기준 데이터에 없는 값.
//   실패하면 null — 화면은 그때 배너를 안 그린다(감지 실패가 본 업무를 막지 않는다).
async function fetchChannelDriftAlerts() {
  if (!db) return null;
  try {
    const {data, error} = await db.rpc('detect_channel_code_drift');
    if (error) throw error;
    return Array.isArray(data) ? data : [];
  } catch(e) {
    console.warn('[fetchChannelDriftAlerts]', e);
    return null;
  }
}

// 그 캠페인에서 특정 채널들로 이미 제출된 결과물 건수.
//   캠페인에서 채널을 뺄 때 「이 채널로 낸 결과물이 화면·인증 성공·정산에서 빠진다」를
//   정확한 숫자로 경고하기 위한 조회. 임시저장(draft)은 아직 제출이 아니므로 제외한다.
//   ⚠️ 채널 비교가 문자열 일치라, 캠페인 요구 채널에서 코드가 빠지는 순간 그 채널로 낸
//      결과물은 인플루언서 활동관리·관리자 인증 상태·정산 후보 **세 곳에서 동시에** 빠진다
//      (2026-07-30 @cosme 사고의 구조). 그래서 저장 전에 사람에게 숫자를 보여준다.
//   ⚠️ 반려·취소된 신청의 결과물은 세지 않는다 — 그건 이미 인증 성공 판정·정산 후보에서
//      빠져 있어(isCertExcluded 규칙), 함께 세면 「빠집니다」라는 경고 숫자가 실제보다 커진다.
async function countDeliverablesByChannels(campaignId, channels) {
  if (!db || !campaignId || !Array.isArray(channels) || !channels.length) return 0;
  // 건수만 필요하지만 신청 상태로 걸러야 해서 행을 가져와 센다. 한 캠페인의 특정 채널
  // 결과물이라 규모가 작다(모집 인원 단위).
  const {data, error} = await db.from('deliverables')
    .select('id, applications:application_id (status)')
    .eq('campaign_id', campaignId)
    .in('post_channel', channels)
    .neq('status', 'draft');
  if (error) throw error;
  return (data || []).filter(function(d) {
    const st = d.applications && d.applications.status;
    return st !== 'rejected' && st !== 'cancelled';
  }).length;
}

// 캠페인 이미지 공개 URL 배열을 Storage 에서 삭제 (고아 파일 정리용).
//   저장이 충돌로 취소됐을 때 방금 올라간 파일을 되돌리는 용도라, 실패해도
//   사용자 흐름을 막지 않는다(참조 없는 파일이 남을 뿐 데이터 손상은 아니다).
//   URL → 버킷 상대 경로 변환은 campaign-images 공용 헬퍼를 재사용한다.
async function deleteCampImages(urls) {
  if (!db || !Array.isArray(urls) || !urls.length) return {ok: true, failedPaths: []};
  const paths = urls.map(_receiptUrlToStoragePath).filter(Boolean);
  if (!paths.length) return {ok: true, failedPaths: []};
  return await _deleteStorageFiles('campaign-images', paths);
}

// 이미지 배열(base64)을 Storage에 업로드하고 URL 배열 반환
//   uploadedOut: 배열을 넘기면 **이번에 실제로 새로 올라간 URL** 만 순서대로 담아 준다.
//     중간에 실패해 예외가 나가도 그때까지 담긴 것은 남으므로, 호출부가 그것만 지워
//     참조 없는 파일(고아)을 막을 수 있다. 기존 URL 재사용분은 담지 않는다.
//     ⚠️ 반환값에서 「새로 올린 것」을 인덱스로 역산하지 말 것 — 예외가 나면 반환값
//        자체가 없어 역산이 성립하지 않는다(그래서 이 누적 인자를 둔다).
async function uploadCampImages(imgList, uploadedOut) {
  var urls = [];
  for (var i = 0; i < Math.min(imgList.length, 8); i++) {
    var img = imgList[i];
    if (!img || !img.data) { urls.push(''); continue; }
    // 이미 URL이면 그대로 사용
    if (img.data.startsWith('http')) { urls.push(img.data); continue; }
    // base64면 업로드 — 실패 시 throw (silent-fail 방지: 빈 URL이 DB에 저장되는 사고 차단)
    var url = await uploadImage(img.data, img.name || 'img' + i);
    urls.push(url);
    if (Array.isArray(uploadedOut) && url) uploadedOut.push(url);
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
  // ng_item lookup은 비활성(active=false) 처리됨 — ng_sets 번들로 대체 (migration 107)
  // 사용 여부 추적 불가이므로 항상 false 반환 (비활성 처리로 hard delete 차단됨)
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
// NG SETS (NG 사항 번들 — migration 107)
//   caution_sets 패턴 완전 미러링.
//   캠페인 저장 시 items 스냅샷이 campaigns.ng_items 로 복사되므로
//   번들 수정 후에도 기존 캠페인 상세에는 영향 없음.
// ══════════════════════════════════════

// 캠페인 폼에서 recruit_type 필터로 active 번들만 조회
//   서버 filter(contains)가 recruit_types=[] 를 제외시키는 문제로 클라이언트 필터 사용.
//   빈 배열(= 전 타입 공통)은 항상 포함.
async function fetchNgSets(recruitType) {
  if (!db) return [];
  const {data, error} = await db?.from('ng_sets')
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
async function fetchNgSetsAll() {
  if (!db) return [];
  const {data, error} = await db?.from('ng_sets')
    .select('*')
    .order('sort_order', {ascending: true});
  if (error) throw error;
  return data || [];
}

async function insertNgSet(row) {
  let result;
  await retryWithRefresh(async () => {
    const existing = await fetchNgSetsAll();
    const maxOrder = existing.reduce((m, r) => Math.max(m, r.sort_order || 0), 0);
    const payload = {
      name_ko: row.name_ko,
      name_ja: row.name_ja,
      recruit_types: row.recruit_types || [],
      items: row.items || [],
      sort_order: row.sort_order != null ? row.sort_order : maxOrder + 10,
      active: row.active != null ? row.active : true
    };
    const {data, error} = await db?.from('ng_sets').insert(payload).select().maybeSingle();
    if (error) throw error;
    result = data;
  });
  return result;
}

async function updateNgSet(id, updates) {
  await retryWithRefresh(async () => {
    const {error} = await db?.from('ng_sets').update(updates).eq('id', id);
    if (error) throw error;
  });
}

async function deactivateNgSet(id) {
  await updateNgSet(id, {active: false});
}

async function activateNgSet(id) {
  await updateNgSet(id, {active: true});
}

// hard delete — campaigns.ng_set_id 는 ON DELETE SET NULL 이라 안전.
// 단, 사용 중인 번들(campaigns.ng_set_id 참조 있음)은 hard delete 차단 → soft delete만 허용.
async function deleteNgSet(id) {
  await retryWithRefresh(async () => {
    // 사용 중 여부 확인 (campaigns.ng_set_id 참조)
    const {count} = await db?.from('campaigns')
      .select('id', {count: 'exact', head: true})
      .eq('ng_set_id', id);
    if ((count || 0) > 0) {
      // 사용 중이면 hard delete 차단 — soft delete(비활성)만 허용
      const {error} = await db?.from('ng_sets').update({active: false}).eq('id', id);
      if (error) throw error;
      return;
    }
    // 미사용이면 hard delete
    const {error} = await db?.from('ng_sets').delete().eq('id', id);
    if (error) throw error;
  });
}

async function swapNgSetOrder(idA, idB) {
  if (!db) return;
  const {data: rows} = await db?.from('ng_sets').select('id, sort_order').in('id', [idA, idB]);
  if (!rows || rows.length !== 2) return;
  const [a, b] = rows;
  await retryWithRefresh(async () => {
    await db?.from('ng_sets').update({sort_order: b.sort_order}).eq('id', a.id);
    await db?.from('ng_sets').update({sort_order: a.sort_order}).eq('id', b.id);
  });
}

// ══════════════════════════════════════
// CAMPAIGN CAUTION HISTORY (주의사항/참여방법/NG 변경 audit — migration 077+109)
// ══════════════════════════════════════

// 변경 이력 INSERT — record_caution_history RPC (SECURITY DEFINER)
//   호출 위치: dev/js/admin.js:saveCampaignEdit() — caution/participation/ng 변경이 감지된 경우만
//   args: { campaign_id,
//           prev:{caution_set_id, caution_items, participation_set_id, participation_steps, ng_set_id, ng_items},
//           next:{caution_set_id, caution_items, participation_set_id, participation_steps, ng_set_id, ng_items},
//           app_count, bypass_ack }
//   bypass_ack: 신청자 ≥1 + 사용자가 경고 모달 「확인하고 저장」을 통과했으면 true.
//   DEMO_MODE(no db)에서는 no-op (audit 의미 없음).
//   migration 109: NG 파라미터 4개 추가 (기존 호출처는 DEFAULT NULL이라 호환 유지).
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
      // migration 109: NG 사항 파라미터 (미전달 시 RPC 기본값 NULL)
      p_prev_ng_set_id: prev?.ng_set_id || null,
      p_next_ng_set_id: next?.ng_set_id || null,
      p_prev_ng_items: prev?.ng_items ?? null,
      p_next_ng_items: next?.ng_items ?? null,
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

// super_admin 전용 — 캠페인 전체 항목(주의사항/참여방법/NG 3영역 제외 — 병존, fetchCautionHistory 로 별도 조회)
// 변경 이력 조회 (changed_at desc). migration 265·266, 캠페인 전체 항목 변경 이력 PR 1.
//   RLS 가 SELECT 를 super_admin 으로 제한하므로 그 외 역할은 빈 배열 수신.
async function fetchCampaignChangeHistory(campaignId) {
  if (!db || !campaignId) return [];
  try {
    const {data, error} = await db?.from('campaign_change_history')
      .select('*')
      .eq('campaign_id', campaignId)
      .order('changed_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchCampaignChangeHistory]', e); return []; }
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
// ── brands 마스터 (migration 082/083) ────────────────────────
async function fetchBrands(filters) {
  if (!db) return [];
  try {
    // 매 페이지마다 새 query builder 생성 (builder 재사용 시 order 누적·재실행 미정의 동작)
    return await fetchAllPaged(() => {
      var q = db.from('brands')
        .select('id, brand_no, brand_seq, name, name_ja, name_en, name_normalized, company_id, company_name, business_no, description, appeal_points, official_qoo10_url, official_instagram_url, official_x_url, primary_contact_name, primary_phone, primary_email, billing_email, memo, status, total_applications, first_applied_at, last_applied_at, created_at, updated_at');
      if (filters?.status) q = q.eq('status', filters.status);
      return q.order('last_applied_at', {ascending: false, nullsFirst: false}).order('created_at', {ascending: false});
    });
  } catch(e) { console.error('[fetchBrands]', e); return []; }
}
async function fetchBrandById(id) {
  if (!db) return null;
  try {
    const {data, error} = await db?.from('brands').select('*').eq('id', id).maybeSingle();
    if (error) throw error;
    return data;
  } catch(e) { console.error('[fetchBrandById]', e); return null; }
}
async function updateBrand(id, patch) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brands').update(patch).eq('id', id).select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[updateBrand]', e); return {ok:false, error: e?.message || 'unknown'}; }
}
async function insertBrand(payload) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brands').insert(payload).select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[insertBrand]', e); return {ok:false, error: e?.message || 'unknown'}; }
}
// ── companies 마스터 (migration 118) ────────────────────────

// 회사 목록 조회 (status 필터 + name_ko/name_ja/business_no 검색)
// 1000행 캡 대응 pagination loop 포함
async function fetchCompanies({ status = 'active', search } = {}) {
  if (!db) return [];
  try {
    // 매 페이지마다 새 query builder 생성 (builder 재사용 시 order 누적·재실행 미정의 동작)
    return await fetchAllPaged(() => {
      var q = db.from('companies')
        .select('id, name_ko, name_ja, name_en, name_normalized, business_no, address, homepage_url, billing_email, billing_address, memo, status, total_brands, created_at, updated_at, created_by, updated_by');
      // status 필터: 'all' 이면 전체, 그 외 값이면 해당 상태만
      if (status && status !== 'all') q = q.eq('status', status);
      // 검색: name_ko, name_ja, business_no 부분일치 (OR 조건)
      if (search && search.trim()) {
        const s = search.trim();
        q = q.or(`name_ko.ilike.%${s}%,name_ja.ilike.%${s}%,business_no.ilike.%${s}%`);
      }
      return q.order('name_ko', {ascending: true});
    });
  } catch(e) { console.error('[fetchCompanies]', e); return []; }
}

// 운영 현황 페인 — 브랜드 카드 그리드용 핵심 지표 집계
// companyId 지정 시 해당 회사 소속 브랜드만, null 이면 전체 브랜드
// 반환: 행 배열(19컬럼), 오류 시 [] 반환
// 서버 집계 함수(데이터베이스에 미리 만든 명령 — get_brand_ops_overview)를 호출
async function getBrandOpsOverview(companyId) {
  if (!db) return [];
  try {
    const {data, error} = await db.rpc('get_brand_ops_overview', {
      p_company_id: companyId || null
    });
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[getBrandOpsOverview]', e); return []; }
}

// 운영 현황 페인 — 브랜드 상세 페인용 신청·캠페인 통합 jsonb 반환
// 반환: { brand, company, applications, external_campaigns } 객체, 오류 시 null 반환
async function getBrandOpsDetail(brandId) {
  if (!db) return null;
  try {
    const {data, error} = await db.rpc('get_brand_ops_detail', {
      p_brand_id: brandId
    });
    if (error) throw error;
    return data || null;
  } catch(e) { console.error('[getBrandOpsDetail]', e); return null; }
}

// ── 캠페인↔신청 연결/해제 (마이그레이션 121) ──────────────────────────────
// 반환 성공: {ok:true, data:{campaign_id, old_no, new_no, application_id, unchanged}}
// 반환 실패: {ok:false, error:string, code:string}
//   에러 코드 42501 = 권한 부족 (campaign_admin 이상 필요)
//   에러 코드 22023 = 잘못된 인자 (캠페인/신청 없음, 다른 브랜드, brand_id NULL 등)

// 캠페인을 광고주 신청에 연결. 새 채번 B{4자리}-A{3자리}-C{3자리} 발급.
// unchanged=true 면 이미 같은 신청에 연결된 상태(no-op, 번호 변경 없음)
async function linkCampaignToApplication(campaignId, applicationId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const data = await retryWithRefresh(async () => {
      const {data, error} = await db.rpc('link_campaign_to_application', {
        p_campaign_id:    campaignId,
        p_application_id: applicationId
      });
      if (error) throw error;
      return data;
    });
    return {ok: true, data};
  } catch(e) {
    console.error('[linkCampaignToApplication]', e);
    return {ok: false, error: e?.message || 'unknown', code: e?.code || ''};
  }
}

// 캠페인을 신청에서 해제(직접 등록 캠페인으로 환원). 새 채번 B{4자리}-C{3자리} 발급.
// unchanged=true 면 이미 직접 등록 캠페인 상태(no-op, 번호 변경 없음)
async function unlinkCampaignFromApplication(campaignId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const data = await retryWithRefresh(async () => {
      const {data, error} = await db.rpc('unlink_campaign_from_application', {
        p_campaign_id: campaignId
      });
      if (error) throw error;
      return data;
    });
    return {ok: true, data};
  } catch(e) {
    console.error('[unlinkCampaignFromApplication]', e);
    return {ok: false, error: e?.message || 'unknown', code: e?.code || ''};
  }
}

// 회사 생성(id 없음) / 수정(id 있음) 통합
// name_normalized 는 DB 트리거가 자동 계산 (name_ko 저장만 하면 됨)
async function upsertCompany(payload) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      if (payload.id) {
        // 수정: id 를 조건으로 UPDATE
        const {id, ...patch} = payload;
        const {data, error} = await db?.from('companies').update(patch).eq('id', id).select('*').maybeSingle();
        if (error) throw error;
        return data;
      } else {
        // 신규 생성
        const {data, error} = await db?.from('companies').insert(payload).select('*').maybeSingle();
        if (error) throw error;
        return data;
      }
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[upsertCompany]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

// 브랜드 일괄 회사 할당
// companyId = null 이면 brands.company_id = NULL (미분류로 복귀)
// brandIds = [] 이면 아무 행도 건드리지 않음
async function assignBrandsToCompany(companyId, brandIds) {
  if (!db) return {ok:false, error:'no_db'};
  if (!brandIds || brandIds.length === 0) return {ok: true, data: []};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brands')
        .update({company_id: companyId || null})
        .in('id', brandIds)
        .select('id, name, company_id');
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[assignBrandsToCompany]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

// 회사 보관(archived) / 복원(active) 전환
async function archiveCompany(companyId, archive) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('companies')
        .update({status: archive ? 'archived' : 'active'})
        .eq('id', companyId)
        .select('id, status')
        .maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[archiveCompany]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

// 회사 완전 삭제 — 소속 브랜드가 0건일 때만 허용
// 소속 브랜드가 있으면 에러 throw (화면에서 friendlyError 로 안내)
async function deleteCompanyHard(companyId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      // 1) 소속 브랜드 수 확인
      const {count, error: cntErr} = await db?.from('brands')
        .select('id', {count: 'exact', head: true})
        .eq('company_id', companyId);
      if (cntErr) throw cntErr;
      if (count > 0) {
        const err = new Error('소속 브랜드가 있어 삭제할 수 없습니다. 브랜드를 다른 회사로 이동하거나 미분류로 해제한 뒤 다시 시도하세요.');
        err.code = 'HAS_BRANDS';
        throw err;
      }
      // 2) 삭제 실행
      const {error: delErr} = await db?.from('companies').delete().eq('id', companyId);
      if (delErr) throw delErr;
      return true;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[deleteCompanyHard]', e); return {ok:false, error: e?.message || 'unknown', code: e?.code}; }
}

// 브랜드 hard delete (연결 0건 한정). delete_brand RPC 경유 — brands 는 DELETE RLS 없어 직접 delete 불가.
async function deleteBrand(brandId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const data = await retryWithRefresh(async () => {
      const {data, error} = await db?.rpc('delete_brand', {p_brand_id: brandId});
      if (error) throw error;
      return data;
    });
    return {ok:true, data};
  } catch(e) { console.error('[deleteBrand]', e); return {ok:false, error: e?.message || 'unknown', code: e?.code}; }
}

// 브랜드 병합 — source 신청·캠페인을 target 으로 이동 + 채번 재발급, 원본 archived. merge_brands RPC.
async function mergeBrands(sourceId, targetId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const data = await retryWithRefresh(async () => {
      const {data, error} = await db?.rpc('merge_brands', {p_source: sourceId, p_target: targetId});
      if (error) throw error;
      return data;
    });
    return {ok:true, data};
  } catch(e) { console.error('[mergeBrands]', e); return {ok:false, error: e?.message || 'unknown', code: e?.code}; }
}

// 브랜드별 캠페인 수 일괄 집계 — 브랜드 목록 「캠페인 수」 컬럼용. {brand_id: count} 반환.
// 1000행 캡 대응 range loop (대시보드 집계 패턴).
async function fetchCampaignCountsByBrand() {
  if (!db) return {};
  try {
    var counts = {};
    var from = 0, size = 1000;
    while (true) {
      const {data, error} = await db?.from('campaigns').select('brand_id')
        .not('brand_id', 'is', null).range(from, from + size - 1);
      if (error) throw error;
      (data || []).forEach(function(r){ if (r.brand_id) counts[r.brand_id] = (counts[r.brand_id] || 0) + 1; });
      if (!data || data.length < size) break;
      from += size;
    }
    return counts;
  } catch(e) { console.error('[fetchCampaignCountsByBrand]', e); return {}; }
}

// 브랜드 연결 캠페인 수 — 삭제 버튼 사전 노출 판정용(신청 brand_applications 은 별도 조회).
// 실제 삭제 차단은 delete_brand RPC 가 캠페인+신청 양쪽을 재검증하므로, 이 값이 틀려도 데이터 안전.
async function countCampaignsByBrand(brandId) {
  if (!db) return 0;
  try {
    const {count, error} = await db?.from('campaigns').select('id', {count:'exact', head:true}).eq('brand_id', brandId);
    if (error) throw error;
    return count || 0;
  } catch(e) { console.error('[countCampaignsByBrand]', e); return 0; }
}

// 브랜드 할당 모달용 조회
// unassignedOnly=true → company_id IS NULL 인 미분류 브랜드만
// companyId 지정 시 → 현재 소속(= companyId) + 미분류 양쪽 모두 반환
// search → name 부분일치
// 1000행 캡 대응 pagination loop 포함
async function fetchBrandsForAssign({ companyId, unassignedOnly = false, search } = {}) {
  if (!db) return [];
  try {
    // 매 페이지마다 새 query builder 생성 (builder 재사용 시 order 누적·재실행 미정의 동작)
    return await fetchAllPaged(() => {
      var q = db.from('brands')
        .select('id, name, company_id, brand_seq');
      if (companyId) {
        // 현재 소속 브랜드 + 아직 미분류 브랜드 둘 다
        q = q.or(`company_id.eq.${companyId},company_id.is.null`);
      } else if (unassignedOnly) {
        q = q.is('company_id', null);
      }
      if (search && search.trim()) {
        q = q.ilike('name', `%${search.trim()}%`);
      }
      return q.order('name', {ascending: true});
    });
  } catch(e) { console.error('[fetchBrandsForAssign]', e); return []; }
}

async function fetchBrandApplicationsByBrand(brandId) {
  if (!db || !brandId) return [];
  try {
    // products: 제품 행 렌더 + 합산(수량·견적·이체수수료·모집비)에 필수
    const {data, error} = await db?.from('brand_applications')
      .select('id, application_no, form_type, status, created_at, products, total_qty, total_jpy, estimated_krw, applicant_contact_name, applicant_email, source')
      .eq('brand_id', brandId)
      .order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchBrandApplicationsByBrand]', e); return []; }
}

// 광고주 신청 메모 (multi-entry, migration 080 + 123 — 제품별 분리)
//   productIdx 옵션: undefined → 신청 전체 메모, 정수 → 그 제품 메모만
async function fetchBrandAppMemos(applicationId, productIdx) {
  if (!db || !applicationId) return [];
  try {
    let q = db?.from('brand_application_memos')
      .select('id, application_id, product_idx, author_id, author_name, text, created_at, updated_at')
      .eq('application_id', applicationId);
    if (typeof productIdx === 'number' && productIdx >= 0) {
      q = q.eq('product_idx', productIdx);
    }
    const {data, error} = await q.order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchBrandAppMemos]', e); return []; }
}
async function insertBrandAppMemo(applicationId, text, authorId, authorName, productIdx) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const payload = {
      application_id: applicationId,
      text: text,
      author_id: authorId || null,
      author_name: authorName || null,
      product_idx: (typeof productIdx === 'number' && productIdx >= 0) ? productIdx : 0
    };
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brand_application_memos')
        .insert(payload)
        .select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[insertBrandAppMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}
async function updateBrandAppMemo(memoId, text) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('brand_application_memos')
        .update({text: text, updated_at: new Date().toISOString()})
        .eq('id', memoId)
        .select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[updateBrandAppMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}
async function deleteBrandAppMemo(memoId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('brand_application_memos').delete().eq('id', memoId);
      if (error) throw error;
    });
    return {ok: true};
  } catch(e) { console.error('[deleteBrandAppMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}
// 신청별·제품별 메모 카운트 + latest 텍스트 + 미확인 메모 수 (목록 셀 표시용, migration 125 이후)
//   반환 키: `${application_id}_${product_idx}` (페어 키)
//   값: {count, unreadCount, latest} — 총 메모 개수 + 본인 미확인 개수 + 최신 메모 텍스트
async function fetchBrandAppMemoSummaries() {
  if (!db) return {};
  try {
    const {data, error} = await db?.rpc('get_brand_app_memo_summaries');
    if (error) throw error;
    const summary = {};
    (data || []).forEach(r => {
      const key = r.application_id + '_' + (r.product_idx || 0);
      summary[key] = {
        count: r.total_count || 0,
        unreadCount: r.unread_count || 0,
        latest: r.latest_text || null
      };
    });
    return summary;
  } catch(e) { console.error('[fetchBrandAppMemoSummaries]', e); return {}; }
}

// (application_id, product_idx) 페어의 메모를 본인 기준 일괄 읽음 처리 (migration 125)
async function markBrandAppMemosRead(applicationId, productIdx) {
  if (!db || !applicationId) return {ok: false, error: 'no_db_or_id'};
  try {
    const idx = (typeof productIdx === 'number' && productIdx >= 0) ? productIdx : 0;
    const {data, error} = await db?.rpc('mark_brand_app_memos_read', {
      p_application_id: applicationId,
      p_product_idx: idx
    });
    if (error) throw error;
    return {ok: true, marked: data || 0};
  } catch(e) { console.error('[markBrandAppMemosRead]', e); return {ok: false, error: e?.message || 'unknown'}; }
}

// ══════════════════════════════════════════════════════════════
// 오리엔시트 내부 메모 (모집 건 카드별, 관리자 전용 — 마이그레이션 297·298)
//   위 브랜드 서베이 메모와 구조가 같지만 두 가지가 다르다:
//     · 붙는 대상이 「순번」이 아니라 카드 고유 번호(card_uid) — 카드가 밀려도 안 어긋남
//     · 본문이 서식 있는 글(body_html) — 저장·표시 양쪽에서 sanitizeMemoHtml 을 거친다
//   읽음 처리는 **시트 단위**(카드 번호를 받지 않는다 — 사양서 §의심 11)
// ══════════════════════════════════════════════════════════════

// 시트 1건의 메모 전부 (카드에 붙은 것 + 카드가 지워진 고아 메모 포함)
//   화면이 card_uid 로 갈라 담는다 — 여기서 카드 목록과 대조해 거르지 않는다.
async function fetchOrientMemos(sheetId) {
  if (!db || !sheetId) return [];
  try {
    const {data, error} = await db?.from('orient_sheet_memos')
      .select('id, orient_sheet_id, card_uid, card_name_snapshot, body_html, author_id, author_name, created_at, updated_at')
      .eq('orient_sheet_id', sheetId)
      .order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchOrientMemos]', e); return []; }
}

// 메모 남기기. cardName 은 작성 시점 제품명 스냅샷 —
//   그 카드가 나중에 지워지면 「삭제된 모집 건의 메모」에서 이 이름으로 보여준다.
async function insertOrientMemo(sheetId, cardUid, cardName, bodyHtml, authorId, authorName) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const payload = {
      orient_sheet_id: sheetId,
      card_uid: cardUid,
      card_name_snapshot: cardName || null,
      body_html: bodyHtml,
      author_id: authorId || null,
      author_name: authorName || null
    };
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('orient_sheet_memos')
        .insert(payload)
        .select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[insertOrientMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

// 메모 고치기. 낙관적 잠금을 일부러 걸지 않는다(마지막 저장 승리 — 확정 결정).
async function updateOrientMemo(memoId, bodyHtml) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db?.from('orient_sheet_memos')
        .update({body_html: bodyHtml, updated_at: new Date().toISOString()})
        .eq('id', memoId)
        .select('*').maybeSingle();
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) { console.error('[updateOrientMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

async function deleteOrientMemo(memoId) {
  if (!db) return {ok:false, error:'no_db'};
  try {
    await retryWithRefresh(async () => {
      const {error} = await db?.from('orient_sheet_memos').delete().eq('id', memoId);
      if (error) throw error;
    });
    return {ok: true};
  } catch(e) { console.error('[deleteOrientMemo]', e); return {ok:false, error: e?.message || 'unknown'}; }
}

// 그 시트의 메모 전부를 본인 기준 읽음 처리 (고아 메모 포함, 카드 번호 안 받음)
//   ⚠️ 호출 시점 = 상세 모달을 **그린 뒤**. 먼저 부르면 안 읽은 수가 0이 되어
//      「안 읽은 메모가 있으면 자동 펼침」 판정이 죽는다 (사양서 §의심 11).
async function markOrientMemosRead(sheetId) {
  if (!db || !sheetId) return {ok: false, error: 'no_db_or_id'};
  try {
    const {data, error} = await db?.rpc('mark_orient_sheet_memos_read', {
      p_orient_sheet_id: sheetId
    });
    if (error) throw error;
    return {ok: true, marked: data || 0};
  } catch(e) { console.error('[markOrientMemosRead]', e); return {ok: false, error: e?.message || 'unknown'}; }
}

// (시트, 카드 번호) 짝 단위 집계 — 목록 배지·카드 머리줄에서 쓴다.
//   반환 키: `${orient_sheet_id}_${card_uid}`
//   값: {count, unreadCount, latest, latestAt}
//   ⚠️ 서버가 카드 목록과 대조하지 않고 메모 표 기준으로만 낸다 —
//      카드가 지워진 고아 메모도 여기 들어온다(화면이 따로 모아 그린다).
async function fetchOrientMemoSummaries() {
  if (!db) return {};
  try {
    const {data, error} = await db?.rpc('get_orient_sheet_memo_summaries');
    if (error) throw error;
    const summary = {};
    (data || []).forEach(r => {
      summary[r.orient_sheet_id + '_' + r.card_uid] = {
        count: r.total_count || 0,
        unreadCount: r.unread_count || 0,
        latest: r.latest_body_html || null,
        latestAt: r.latest_created_at || null
      };
    });
    return summary;
  } catch(e) { console.error('[fetchOrientMemoSummaries]', e); return {}; }
}

// 신청별 history 건수 조회 (작은 카운트 쿼리 — 1회 호출)
async function fetchBrandAppHistoryCounts() {
  if (!db) return {};
  try {
    const {data, error} = await db?.from('brand_application_history')
      .select('application_id', {count: 'exact', head: false})
      .limit(100000);
    if (error) throw error;
    const counts = {};
    (data || []).forEach(r => { counts[r.application_id] = (counts[r.application_id] || 0) + 1; });
    return counts;
  } catch(e) { console.error('[fetchBrandAppHistoryCounts]', e); return {}; }
}

// 광고주 공개 신청 폼이 열려 있는지 (brand_survey_settings 싱글톤, id=1).
//   브랜드 서베이 현황 화면의 「접수 잠금」 안내 줄 표시 여부에만 쓴다.
//   읽기 전용이며, 알 수 없으면 null 을 돌려 안내를 생략한다(화면을 막지 않음).
//   ※ 이 표는 관리자만 읽을 수 있는 접근 정책이라 별도 함수 없이 직접 조회한다.
async function fetchBrandSurveyOpen() {
  if (!db) return null;
  try {
    const { data, error } = await db?.from('brand_survey_settings').select('submissions_open').eq('id', 1).maybeSingle();
    if (error) throw error;
    return data ? !!data.submissions_open : null;
  } catch(e) { console.error('[fetchBrandSurveyOpen]', e); return null; }
}

async function fetchBrandApplications(filters) {
  if (!db) return [];
  try {
    return await fetchAllPaged(() => {
      let q = db.from('brand_applications').select(`
        id, application_no, form_type,
        brand_id, source, intake_admin_id,
        applicant_contact_name, applicant_phone, applicant_email,
        brand_name, contact_name, phone, email, billing_email,
        products, total_jpy, total_qty,
        estimated_krw, final_quote_krw, quote_sent_at, quote_sent_url,
        orient_sheet_sent_url, paid_at,
        status, request_note,
        reviewer_channels,
        reviewed_by, reviewed_at,
        version, created_at, updated_at,
        brand:brands(id, brand_no, name, company_name, contacts, billing_email, status)
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

// 관리자 직접 광고주 신청 등록 (migration 091 RPC)
// params:
//   formType      'reviewer' | 'seeding'
//   brandId       uuid | null  — null이면 신규 brand 생성
//   brandName     text         — 신규 시 필수, 기존 brand 선택 시 optional(brand 페인에서 직접 수정 권장)
//   contactName   text | null
//   phone         text | null
//   email         text | null
//   billingEmail  text | null
//   products      Array<{name, url, price_jpy, qty}>  — 1개 이상 필수
//   requestNote   text | null
//   brandSync     boolean (default true)  — true면 기존 brand의 primary_* + contacts 동기 갱신
// 반환: {ok: true, data: {id, application_no, brand_id, brand_no}} | {ok: false, error}
async function adminCreateBrandApplication({
  formType,
  brandId = null,
  companyName = null,
  brandName = null,
  brandNameJa = null,
  businessNo = null,
  contactName = null,
  phone = null,
  email = null,
  billingEmail = null,
  products,
  requestNote = null,
  brandSync = true,
  reviewerChannels = null
}) {
  if (!db) return {ok: false, error: 'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db.rpc('admin_create_brand_application', {
        p_form_type:         formType,
        p_brand_id:          brandId,
        p_company_name:      companyName,
        p_brand_name:        brandName,
        p_brand_name_ja:     brandNameJa,
        p_business_no:       businessNo,
        p_contact_name:      contactName,
        p_phone:             phone,
        p_email:             email,
        p_billing_email:     billingEmail,
        p_products:          products,
        p_request_note:      requestNote,
        p_brand_sync:        brandSync,
        p_reviewer_channels: reviewerChannels
      });
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) {
    console.error('[adminCreateBrandApplication]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

// 광고주 신청 상태 변경·견적 입력·제품 정보 수정 (낙관적 락)
// patch: {status?, final_quote_krw?, quote_sent_at?, products?, reviewed_by?, reviewed_at?}
// expectedVersion: UPDATE 시 버전 일치 확인. 불일치면 {ok:false, conflict:true}
async function updateBrandApplication(id, patch, expectedVersion) {
  if (!db) return {ok: false, error: 'no_db'};
  try {
    const result = await retryWithRefresh(async () => {
      // products 변경 시 052/111 트리거가 estimated_krw/total_jpy/total_qty 를
      // 서버에서 재계산한다. 갱신된 값을 함께 받아 호출처가 메모리 캐시를
      // 즉시 동기화할 수 있도록 select 에 포함.
      const {data, error} = await db?.from('brand_applications')
        .update(patch)
        .eq('id', id)
        .eq('version', expectedVersion)
        .select('id, version, status, products, total_jpy, total_qty, estimated_krw')
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

// 신청 1건 모든 제품 payment_flags 완전 초기화 — 새로고침 버튼 핸들러용.
//   migration 117 RPC refresh_brand_app_product_payment_flags(application_id).
//   4종(recruit/product/transfer/free) 모두 products 합계 기반 재설정.
//   반환: 갱신 후 products 배열.
async function refreshBrandAppProductPaymentFlags(applicationId) {
  if (!db || !applicationId) return {ok: false, error: 'no_db_or_id'};
  try {
    const {data, error} = await db.rpc('refresh_brand_app_product_payment_flags', {
      p_application_id: applicationId
    });
    if (error) throw error;
    return {ok: true, products: data || []};
  } catch(e) {
    console.error('[refreshBrandAppProductPaymentFlags]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

// ──────────────────────────────────────
// 관리자 메일 수신 구독 (admin_email_subscriptions)
// 사양: docs/specs/2026-05-11-admin-email-subscriptions.md
// ──────────────────────────────────────

// 여러 관리자의 구독 상태를 한 번에 가져온다 (admin_id → mail_kind 배열).
// 관리자 계정 페인 리스트 렌더 시 1회 호출로 모든 행에 칩 표시.
async function fetchAdminEmailSubscriptions(adminIds) {
  if (!db || !adminIds || adminIds.length === 0) return {};
  const {data, error} = await db.from('admin_email_subscriptions')
    .select('admin_id, mail_kind')
    .in('admin_id', adminIds)
    .eq('subscribed', true);
  if (error) { console.error('[fetchAdminEmailSubscriptions]', error); return {}; }
  const map = {};
  for (const row of data || []) {
    if (!map[row.admin_id]) map[row.admin_id] = [];
    map[row.admin_id].push(row.mail_kind);
  }
  return map;
}

// 메일 종류 카탈로그 (lookup_values kind='admin_email_kind')
// 모달의 체크박스 목록을 동적 렌더하기 위함.
async function fetchAdminEmailKinds() {
  if (!db) return [];
  const {data, error} = await db.from('lookup_values')
    .select('code, name_ko, name_ja, sort_order')
    .eq('kind', 'admin_email_kind')
    .eq('active', true)
    .order('sort_order');
  if (error) { console.error('[fetchAdminEmailKinds]', error); return []; }
  return data || [];
}

// ──────────────────────────────────────
// 캠페인 신청 본인 취소 (cancel_application RPC)
// 사양: docs/specs/2026-05-11-application-cancel.md
// ──────────────────────────────────────

// 취소 사유 카테고리 목록 (lookup_values kind='cancel_reason')
// 인플루언서 취소 모달의 select 옵션을 동적 렌더하기 위함.
async function fetchCancelReasons() {
  if (!db) return [];
  const {data, error} = await db?.from('lookup_values')
    .select('code, name_ko, name_ja, sort_order')
    .eq('kind', 'cancel_reason')
    .eq('active', true)
    .order('sort_order');
  if (error) { console.error('[fetchCancelReasons]', error); return []; }
  return data || [];
}

// 본인 취소 RPC 호출.
// 반환: { ok: true, data: { cancel_phase, cancelled_at, previous_status } }
//      | { ok: false, error: 'application_not_found' | 'not_owner'
//                          | 'invalid_status' | 'deliverable_already_approved'
//                          | 'acknowledgement_required' | 'reason_required'
//                          | (그 외 메시지) }
// 호출 측에서 error 코드로 분기해 사용자 친화 메시지 표시.
async function cancelApplication(applicationId, opts) {
  if (!db) return {ok: false, error: 'no_db'};
  const payload = {
    p_application_id: applicationId,
    p_reason_code:    opts?.reasonCode || null,
    p_reason_note:    opts?.reasonNote || null,
    p_acknowledged:   !!opts?.acknowledged
  };
  try {
    const result = await retryWithRefresh(async () => {
      const {data, error} = await db.rpc('cancel_application', payload);
      if (error) throw error;
      return data;
    });
    return {ok: true, data: result};
  } catch(e) {
    // PostgREST 가 RAISE EXCEPTION 메시지를 e.message 로 전달
    const msg = e?.message || 'unknown';
    console.error('[cancelApplication]', e);
    return {ok: false, error: msg};
  }
}

// 한 관리자의 메일 구독 일괄 저장 (UPSERT)
// allKinds 의 모든 종류에 대해 subscribed=subscribedKinds.has(code) 로 행을 보장.
// 모달에서 「저장」 클릭 시 호출. RLS 가 본인 또는 super_admin 만 허용.
async function saveAdminEmailSubscriptions(adminId, subscribedKinds, allKinds) {
  if (!db) return {ok: false, error: 'no_db'};
  // updated_by: 누가 변경했는지 추적 (super_admin 이 다른 관리자 설정을 바꿀 때 식별).
  // currentUser 는 dev/lib/shared.js 의 전역 — 미세션 상황에서는 NULL 로 들어감.
  const updatedBy = (typeof currentUser !== 'undefined' && currentUser?.id) || null;
  const rows = (allKinds || []).map(k => ({
    admin_id: adminId,
    mail_kind: k.code,
    subscribed: subscribedKinds.has(k.code),
    updated_at: new Date().toISOString(),
    updated_by: updatedBy
  }));
  if (rows.length === 0) return {ok: true};
  try {
    await retryWithRefresh(async () => {
      const {error} = await db.from('admin_email_subscriptions')
        .upsert(rows, {onConflict: 'admin_id,mail_kind'});
      if (error) throw error;
    });
    return {ok: true};
  } catch(e) {
    console.error('[saveAdminEmailSubscriptions]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

// ── 마케팅(캠페인 홍보) 메일 수신거부·재구독 ──
// 마이그레이션 140 의 함수 사용. 수신거부 토큰 인프라.

// [수신거부 라우트] 메일 1-click 익명 수신거부.
// 비로그인 상태에서 토큰만으로 호출되므로 세션 갱신(retryWithRefresh) 불필요.
// 반환: {ok:true, name} | {ok:false, error}
async function unsubscribeByToken(token) {
  if (!db) return {ok: false, error: 'no_db'};
  if (!token) return {ok: false, error: 'invalid_token'};
  try {
    const {data, error} = await db.rpc('unsubscribe_by_token', { p_token: token });
    if (error) throw error;
    // data: {success:bool, name?, reason?}
    if (data && data.success) return {ok: true, name: data.name || ''};
    return {ok: false, error: data?.reason || 'invalid_token'};
  } catch(e) {
    // 잘못된 UUID 형식 등은 무효 토큰으로 처리
    console.error('[unsubscribeByToken]', e);
    return {ok: false, error: 'invalid_token'};
  }
}

// [마이페이지 토글 ON] 마케팅 메일 재구독 — 로그인 본인.
// resubscribe_marketing() 이 marketing_agreed_at=now() 를 갱신해
// 특정전자메일법(특정전자메일의 송신 적정화법) 「동의 근거 기록」 의무를 충족하므로
// 직접 UPDATE 대신 반드시 이 RPC 사용.
async function resubscribeMarketing() {
  if (!db) return {ok: false, error: 'no_db'};
  try {
    await retryWithRefresh(async () => {
      const {error} = await db.rpc('resubscribe_marketing');
      if (error) throw error;
    });
    return {ok: true};
  } catch(e) {
    console.error('[resubscribeMarketing]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

// [마이페이지 토글] 마케팅 메일 수신 설정 — 로그인 본인.
// 동의 철회(OFF)는 동의 시각 기록 의무가 없으므로 본인 행을 직접 UPDATE.
// 동의(ON)는 동의 근거(marketing_agreed_at) 기록을 위해 resubscribeMarketing() 으로 위임 —
// 직접 UPDATE 로 ON 하면 동의 시각이 안 남아 특정전자메일법 위반 소지가 있어 차단.
async function updateMarketingOptIn(value) {
  if (!db || typeof currentUser === 'undefined' || !currentUser) return {ok: false, error: 'no_session'};
  // ON 은 동의 근거 기록 의무로 RPC 경로로 위임 (오용 차단)
  if (value) return await resubscribeMarketing();
  try {
    await retryWithRefresh(async () => {
      // 이미 OFF 인 경우는 갱신하지 않아 최초 수신거부 시각을 보존 (marketing_opt_in=true 일 때만)
      const {error} = await db.from('influencers')
        .update({ marketing_opt_in: false, marketing_unsubscribed_at: new Date().toISOString() })
        .eq('id', currentUser.id)
        .eq('marketing_opt_in', true);
      if (error) throw error;
    });
    return {ok: true};
  } catch(e) {
    console.error('[updateMarketingOptIn]', e);
    return {ok: false, error: e?.message || 'unknown'};
  }
}

// ════════════════════════════════════════════════════════════════════
// 응모건 단위 메시지 (인플루언서 ↔ 관리자) — PR 1
//   사양서 docs/specs/2026-05-15-application-messaging.md §4
//   마이그레이션 144. 본문/첨부 마스킹은 get_application_messages RPC 서버측 처리.
// ════════════════════════════════════════════════════════════════════
const MSG_ATTACH_BUCKET = 'application-message-attachments';

// 응모건의 메시지 목록 (마스킹 적용된 행) — 인플루언서·관리자 공용.
// get_application_messages RPC 가 호출자 역할(본인 인플 / is_admin)에 따라 마스킹.
async function fetchApplicationMessages(applicationId) {
  if (!db || !applicationId) return [];
  const {data, error} = await db.rpc('get_application_messages', { p_application_id: applicationId });
  if (error) throw error;
  return data || [];
}

// 메시지 발송 (인플루언서·관리자 공용, sender_kind 는 서버가 판별).
// attachments: [{path, name, size, mime}] — uploadMessageAttachment() 반환값 배열
async function sendApplicationMessage(applicationId, body, attachments = []) {
  if (!db) throw new Error('DB 미연결');
  return await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('send_application_message', {
      p_application_id: applicationId,
      p_body: body || '',
      p_attachments: attachments,
    });
    if (error) throw error;
    return data;
  });
}

// 본인 미열람 메시지를 읽음 처리 (관리자: 개인별 / 인플루언서: read_by_influencer_at).
async function markApplicationMessagesRead(applicationId) {
  if (!db || !applicationId) return;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('mark_application_messages_read', { p_application_id: applicationId });
    if (error) throw error;
  });
}

// 본인 메시지 회수 (25분 한도, RPC 가 시간/본인 검증). 성공 후 첨부 Storage 즉시 삭제 (§3-5 ②).
// attachmentPaths: 회수할 메시지의 attachments[].path 배열 (없으면 빈 배열)
async function withdrawOwnMessage(messageId, attachmentPaths = []) {
  if (!db || !messageId) return;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('withdraw_own_message', { p_message_id: messageId });
    if (error) throw error;
  });
  if (attachmentPaths && attachmentPaths.length) {
    // 본인 회수는 첨부 즉시 삭제 (개인정보 최소화). 실패해도 회수 자체는 성공이므로 경고만.
    try { await db.storage.from(MSG_ATTACH_BUCKET).remove(attachmentPaths); }
    catch (e) { console.warn('[withdrawOwnMessage] 첨부 삭제 실패', e); }
  }
}

// 첨부 이미지 업로드 — 압축/HEIC 변환(image-compress.js) 후 비공개 버킷에 저장.
// 반환: {path, name, size, mime} (send 의 attachments 배열에 그대로 push)
async function uploadMessageAttachment(file, applicationId) {
  if (!db) throw new Error('DB 미연결');
  const compressed = await compressImageFile(file);  // image-compress.js — too_large/decode_failed 등 예외 가능
  const uuid = crypto.randomUUID ? crypto.randomUUID()
    : (Date.now().toString(36) + Math.random().toString(36).substring(2));
  const path = `${applicationId}/${uuid}.jpg`;
  const {error} = await db.storage.from(MSG_ATTACH_BUCKET)
    .upload(path, compressed, { contentType: 'image/jpeg', upsert: false, cacheControl: '3600' });
  if (error) throw error;
  return { path, name: file.name || 'image.jpg', size: compressed.size, mime: 'image/jpeg' };
}

// 첨부 이미지 signed URL (5분 시한, §9). 라이트박스/썸네일 표시용
async function getMessageAttachmentSignedUrl(path, expiresIn = 300) {
  if (!db || !path) return null;
  const {data, error} = await db.storage.from(MSG_ATTACH_BUCKET).createSignedUrl(path, expiresIn);
  if (error) throw error;
  return data?.signedUrl || null;
}

// 인플루언서 GNB 미읽음 메시지 응모건 목록 (security_invoker 뷰 — 본인 행만 RLS 적용).
async function fetchInfluencerUnreadMessageThreads() {
  if (!db || typeof currentUser === 'undefined' || !currentUser) return [];
  const {data, error} = await db.from('application_message_summary')
    .select('application_id, campaign_id, unread_for_influencer, last_message_at')
    .gt('unread_for_influencer', 0)
    .order('last_message_at', { ascending: false });
  if (error) { console.warn('[fetchInfluencerUnreadMessageThreads]', error); return []; }
  return data || [];
}

// ════════════════════════════════════════════════════════════════════
// 응모건 메시지 — 관리자 발신/숨김/응대 (PR 2)
//   마이그레이션 145. 관리자 받은편지함·강제 숨김/복구·응대 완료.
// ════════════════════════════════════════════════════════════════════

// 응모건 수동 응대 완료 마킹 (모든 관리자 — 사양서 §3-4). RPC mark_application_resolved.
async function markApplicationResolved(applicationId) {
  if (!db || !applicationId) return;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('mark_application_resolved', { p_application_id: applicationId });
    if (error) throw error;
  });
}

// 메시지 강제 숨김 (campaign_admin 이상). reasonCode 는 lookup_values(kind='message_hide_reason').code.
async function hideApplicationMessage(messageId, reasonCode, reasonMemo = null) {
  if (!db || !messageId) throw new Error('잘못된 호출');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('hide_application_message', {
      p_message_id: messageId,
      p_reason_code: reasonCode,
      p_reason_memo: reasonMemo || null,
    });
    if (error) throw error;
  });
}

// 강제 숨김 복구 (super_admin 한정). reasonMemo 필수.
async function unhideApplicationMessage(messageId, reasonMemo) {
  if (!db || !messageId) throw new Error('잘못된 호출');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('unhide_application_message', {
      p_message_id: messageId,
      p_reason_memo: reasonMemo,
    });
    if (error) throw error;
  });
}

// 관리자 본인 미열람 메시지 수 (응모건별). RPC application_message_admin_unread_counts.
// 반환: Map<application_id, unread_count> (응모행 배지·받은편지함 개인 강조용)
async function fetchAdminMessageUnreadCounts() {
  if (!db) return new Map();
  const {data, error} = await db.rpc('application_message_admin_unread_counts', { p_admin_auth_id: null });
  if (error) { console.warn('[fetchAdminMessageUnreadCounts]', error); return new Map(); }
  const map = new Map();
  (data || []).forEach(r => map.set(r.application_id, Number(r.unread_count) || 0));
  return map;
}

// 관리자 받은편지함 대화 목록 — application_message_summary 뷰 조회.
//   security_invoker=true 라 관리자 호출 시 전체 응모건 RLS 통과.
//   message_count>0 (메시지 있는 건만) + last_message_at 최근순. 1000행 cap 대응 pagination.
//   opts: { sinceMonths(기본 6), campaignId(선택), fromIso/toIso(달력 절대 기간 — 있으면 sinceMonths 무시) }
//   기간 기준 컬럼 = last_message_at (모든 정렬 모드 공통)
async function fetchAdminMessageThreads(opts = {}) {
  if (!db) return [];
  const useRange = !!(opts.fromIso || opts.toIso);
  const sinceMonths = opts.sinceMonths || 6;
  const sinceIso = new Date(Date.now() - sinceMonths * 30 * 24 * 60 * 60 * 1000).toISOString();
  const cols = 'application_id, influencer_id, campaign_id, message_count, unread_for_influencer, unresolved_for_admin_team, last_message_at';
  const rows = [];
  let from = 0;
  const PAGE = 1000;
  while (true) {
    let q = db?.from('application_message_summary')
      .select(cols)
      .gt('message_count', 0)
      .order('last_message_at', { ascending: false })
      .range(from, from + PAGE - 1);
    // 달력 절대 기간 우선, 없으면 상대 기간(sinceMonths)
    if (useRange) {
      if (opts.fromIso) q = q.gte('last_message_at', opts.fromIso);
      if (opts.toIso) q = q.lte('last_message_at', opts.toIso);
    } else {
      q = q.gte('last_message_at', sinceIso);
    }
    if (opts.campaignId) q = q.eq('campaign_id', opts.campaignId);
    const {data, error} = await q;
    if (error) { console.warn('[fetchAdminMessageThreads]', error); break; }
    rows.push(...(data || []));
    if (!data || data.length < PAGE) break;
    from += PAGE;
  }
  return rows;
}

// 탭/사이드바 배지 폴링용 경량 미응대 count — 받은편지함 전체를 가져오지 않고 개수만.
//   application_message_summary 뷰의 message_count>0 + unresolved_for_admin_team=true 행 수.
//   head:true 라 행 본문 미전송(최경량). 기간은 받은편지함과 동일 6개월(last_message_at)로 맞춰
//   배지 수와 받은편지함 미응대 표시 수가 어긋나지 않게 한다.
//   fetchAdminMessageThreads 와 동일 뷰·동일 RLS(security_invoker). 실패 시 0.
async function fetchUnresolvedMessageCount() {
  if (!db) return 0;
  try {
    const sinceIso = new Date(Date.now() - 6 * 30 * 24 * 60 * 60 * 1000).toISOString();
    const {count, error} = await db?.from('application_message_summary')
      .select('application_id', { count: 'exact', head: true })
      .gt('message_count', 0)
      .eq('unresolved_for_admin_team', true)
      .gte('last_message_at', sinceIso);
    if (error) { console.warn('[fetchUnresolvedMessageCount]', error); return 0; }
    return count || 0;
  } catch (e) { console.warn('[fetchUnresolvedMessageCount]', e); return 0; }
}

// 「내가 보낸 순」 정렬용 — 로그인한 본인 관리자가 발신한 응모건별 최신 발신 시각.
//   application_messages 에서 sender_id=본인 + sender_kind='admin' 행을 created_at 내림차순 조회,
//   application_id 별 첫(최신) 행 시각만 Map 에 보존. DB 변경 없음(관리자 SELECT 권한 사용).
//   반환: Map<application_id, created_at(iso)>
async function fetchAdminSentAtMap() {
  if (!db) return new Map();
  const {data: udata} = await (db?.auth.getUser() || {data:{user:null}});
  const uid = udata?.user?.id;
  if (!uid) return new Map();
  const map = new Map();
  let from = 0;
  const PAGE = 1000;
  while (true) {
    const {data, error} = await db?.from('application_messages')
      .select('application_id, created_at')
      .eq('sender_id', uid)
      .eq('sender_kind', 'admin')
      .order('created_at', { ascending: false })
      .range(from, from + PAGE - 1);
    if (error) { console.warn('[fetchAdminSentAtMap]', error); break; }
    for (const r of (data || [])) {
      if (!map.has(r.application_id)) map.set(r.application_id, r.created_at);   // 내림차순 첫 행 = 최신
    }
    if (!data || data.length < PAGE) break;
    from += PAGE;
  }
  return map;
}

// 받은편지함 최근 메시지 미리보기 — 응모건별 마지막 「살아있는」 메시지 본문.
//   숨김/회수 메시지는 제외(미리보기 노출 부적절). created_at 내림차순 후 클라에서 첫 행=최신.
//   반환: Map<application_id, {body, sender_kind, created_at}>
//   ⚠️ PostgREST 1000행 cap: 청크당 application 100개 + limit 1000. 한 청크 내
//      메시지 밀도가 매우 높으면(application 평균 10건 초과) 뒤쪽 응모건 미리보기가
//      누락될 수 있음. 미리보기는 보조 정보라 치명적이지 않음. 정밀도 필요 시
//      차후 「응모건당 최신 1건」 전용 RPC 로 개선 권장.
async function fetchMessagePreviews(applicationIds) {
  if (!db || !applicationIds || !applicationIds.length) return new Map();
  const map = new Map();
  const CHUNK = 100;  // application_id 청크 (청크당 1000행 cap 내 평균 10건 커버)
  for (let i = 0; i < applicationIds.length; i += CHUNK) {
    const ids = applicationIds.slice(i, i + CHUNK);
    const {data, error} = await db?.from('application_messages')
      .select('application_id, body, body_translated, translate_status, sender_kind, created_at')
      .in('application_id', ids)
      .is('hidden_by_admin_at', null)
      .is('self_withdrawn_at', null)
      .order('created_at', { ascending: false })
      .limit(1000);
    if (error) { console.warn('[fetchMessagePreviews]', error); continue; }
    (data || []).forEach(m => { if (!map.has(m.application_id)) map.set(m.application_id, m); });
  }
  return map;
}

// 응모건 단위 숨김/복구 이력 (super_admin — append-only audit). 메시지 모달 하단 패널용.
//   hide_history 는 message_id 만 가지므로 application_messages inner join 으로 응모건 필터.
//   RLS SELECT 는 super_admin 한정 (144) — 매니저 호출 시 빈 배열.
async function fetchApplicationHideHistory(applicationId) {
  if (!db || !applicationId) return [];
  const {data, error} = await db.from('application_message_hide_history')
    .select('id, message_id, action, by_user_kind, by_name, reason_code, reason_memo, at, application_messages!inner(application_id)')
    .eq('application_messages.application_id', applicationId)
    .order('at', { ascending: false });
  if (error) { console.warn('[fetchApplicationHideHistory]', error); return []; }
  return data || [];
}

// ════════════════════════════════════════════════════════════════════
// 응모건 메시지 — 일괄 발송 (BCC, PR 3)
//   마이그레이션 167. campaign_admin 이상. send_bulk / withdraw_broadcast /
//   resolve_bulk_recipients / get_broadcast_detail RPC + 발송 이력 목록 조회.
// ════════════════════════════════════════════════════════════════════

// 일괄 발송 (관리자 → N명 BCC). applicationIds 는 이미 cancelled 제외된 배열.
//   contextKind: 'campaign'|'manual', contextCampaignId/contextFilter 는 감사·재현용 스냅샷.
//   반환: broadcast_id (uuid).
async function sendApplicationMessageBulk(applicationIds, body, attachments = [], contextKind = 'manual', contextCampaignId = null, contextFilter = null, title = null) {
  if (!db) throw new Error('DB 미연결');
  return await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('send_application_message_bulk', {
      p_application_ids: applicationIds,
      p_body: body || '',
      p_attachments: attachments,
      p_context_kind: contextKind,
      p_context_campaign_id: contextCampaignId,
      p_context_filter: contextFilter,
      p_title: title || null,   // 관리자 전용 제목 (인플 메시지 본문 미포함)
    });
    if (error) throw error;
    return data;
  });
}

// 일괄 발송 그룹 회수 (발신자 본인 또는 super_admin). 회수 시 각 메시지 강제 숨김 처리.
//   reasonCode: lookup_values(kind='message_hide_reason').code. 첨부 Storage 는 영구 보존(삭제 안 함).
async function withdrawBroadcast(broadcastId, reasonCode, reasonMemo = null) {
  if (!db || !broadcastId) throw new Error('잘못된 호출');
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('withdraw_broadcast', {
      p_broadcast_id: broadcastId,
      p_reason_code: reasonCode,
      p_reason_memo: reasonMemo || null,
    });
    if (error) throw error;
  });
}

// 캠페인 단위 발송 대상 응모 id 해결 (cancelled 항상 제외). 미리보기 카운트 = 배열 길이.
//   filters: { appStatuses[], receiptStatuses[], postStatuses[], channels[](인플 보유 SNS),
//              prefectures[](지역), followerMode('per_channel'|'sum'), followerChannel, minFollowers,
//              requireVerified, excludeViolation, excludeBlacklist }
//   - receiptStatuses: 영수증(kind='receipt') 결과물 상태 / postStatuses: 게시물·리뷰이미지 상태
//   - 팔로워: minFollowers 있을 때 followerMode 로 해석(채널별=followerChannel 기준 / 합산)
//   - excludeBlacklist 기본 true (명시적 false 일 때만 블랙리스트 포함)
//   반환: uuid[] (조건 만족 application id 배열, 빈 배열 가능)
async function resolveBulkRecipients(campaignId, filters = {}) {
  if (!db || !campaignId) return [];
  const hasFollower = (filters.minFollowers != null && filters.minFollowers !== '');
  const {data, error} = await db.rpc('resolve_bulk_recipients', {
    p_campaign_id: campaignId,
    p_app_statuses: filters.appStatuses && filters.appStatuses.length ? filters.appStatuses : null,
    p_receipt_statuses: filters.receiptStatuses && filters.receiptStatuses.length ? filters.receiptStatuses : null,
    p_post_statuses: filters.postStatuses && filters.postStatuses.length ? filters.postStatuses : null,
    p_channels: filters.channels && filters.channels.length ? filters.channels : null,
    p_prefectures: filters.prefectures && filters.prefectures.length ? filters.prefectures : null,
    p_follower_mode: hasFollower ? (filters.followerMode || 'per_channel') : null,
    p_follower_channel: filters.followerChannel || null,
    p_min_followers: hasFollower ? Number(filters.minFollowers) : null,
    p_require_verified: !!filters.requireVerified,
    p_exclude_violation: !!filters.excludeViolation,
    p_exclude_blacklist: filters.excludeBlacklist !== false,
    // 완전 승인만(부분 승인 제외) — 통합 토글 1개가 영수증·게시물 양쪽을 함께 true (마이그레이션 171)
    p_receipt_all_approved: !!filters.fullApproved,
    p_post_all_approved: !!filters.fullApproved,
  });
  if (error) throw error;
  return data || [];
}

// 응모 ID 배열의 distinct user_id 수 (일괄발송 「○건(○명)」 표시용 — 동일인 중복 응모 인지).
//   appIds 는 BULK_MAX(200) 이하라 in() 단일 쿼리로 안전(PostgREST 1000행 cap 미만).
async function countDistinctUsersForApps(appIds) {
  if (!db || !appIds || !appIds.length) return 0;
  const {data, error} = await db?.from('applications').select('user_id').in('id', appIds);
  if (error) throw error;
  return new Set((data || []).map(r => r.user_id).filter(Boolean)).size;
}

// 발송 이력 목록 (관리자). application_message_broadcasts 직접 조회.
//   RLS SELECT 는 is_admin() 전체. campaign_admin 본인분만 보려면 senderId 전달(클라 권한 분기).
//   opts: { senderId(있으면 sender_id 필터), limit(기본 100) }
async function fetchBroadcasts(opts = {}) {
  if (!db) return [];
  let q = db?.from('application_message_broadcasts')
    .select('id, sender_id, sender_name, title, body, attachments, recipient_count, created_at, context_kind, context_campaign_id, context_filter, withdrawn_at, withdrawn_by, withdrawn_reason_code')
    .order('created_at', { ascending: false })
    .limit(opts.limit || 100);
  if (opts.senderId) q = q.eq('sender_id', opts.senderId);
  const {data, error} = await q;
  if (error) { console.warn('[fetchBroadcasts]', error); return []; }
  return data || [];
}

// 발송 이력 상세 (그룹 메타 + 수신자별 읽음·답장 상태). 권한별 가시성은 RPC 가 검증.
//   반환: { broadcast: {...}, recipients: [{application_id, influencer_name, campaign_title, read, replied, hidden, message_id}] }
async function getBroadcastDetail(broadcastId) {
  if (!db || !broadcastId) return null;
  const {data, error} = await db.rpc('get_broadcast_detail', { p_broadcast_id: broadcastId });
  if (error) throw error;
  return data || null;
}

// ══════════════════════════════════════
// FAQ (자동응답) — 마이그레이션 146
// ══════════════════════════════════════

// 관리자용 전체 노드 (active 무관) — 트리 렌더용. sort_order → created_at 정렬
async function fetchFaqNodes() {
  if (!db) return [];
  const {data, error} = await db?.from('faq_nodes')
    .select('*')
    .order('sort_order', { ascending: true })
    .order('created_at', { ascending: true });
  if (error) { console.warn('[fetchFaqNodes]', error); return []; }
  return data || [];
}

// 노드별 측정 집계 — { faq_node_id: {viewed, handoff, resolved} } (1000행 cap 대응 페이지네이션)
async function fetchFaqInteractionStats() {
  if (!db) return {};
  const out = {};
  let from = 0;
  while (true) {
    const { data, error } = await db?.from('faq_interactions')
      .select('faq_node_id, action, view_count')
      .range(from, from + 999);
    if (error) { console.warn('[fetchFaqInteractionStats]', error); break; }
    (data || []).forEach(r => {
      if (!r.faq_node_id) return;
      const s = out[r.faq_node_id] || (out[r.faq_node_id] = { viewed: 0, handoff: 0, resolved: 0 });
      if (r.action === 'viewed') s.viewed += (r.view_count || 1);
      else if (r.action === 'handoff') s.handoff += 1;
      else if (r.action === 'resolved') s.resolved += 1;
    });
    if (!data || data.length < 1000) break;
    from += 1000;
  }
  return out;
}

// 노드 추가 (호출측에서 created_by/updated_by 채워 전달)
async function insertFaqNode(row) {
  if (!db) return { ok: false, error: 'no_db' };
  try {
    return await retryWithRefresh(async () => {
      const { data, error } = await db?.from('faq_nodes').insert(row).select().maybeSingle();
      if (error) throw error;
      return { ok: true, data };
    });
  } catch (e) { console.error('[insertFaqNode]', e); return { ok: false, error: e?.message }; }
}

// 노드 수정 (updated_at 은 트리거 자동 갱신)
async function updateFaqNode(id, updates) {
  if (!db) return { ok: false, error: 'no_db' };
  try {
    return await retryWithRefresh(async () => {
      const { error } = await db?.from('faq_nodes').update(updates).eq('id', id);
      if (error) throw error;
      return { ok: true };
    });
  } catch (e) { console.error('[updateFaqNode]', e); return { ok: false, error: e?.message }; }
}

async function setFaqNodeActive(id, active) {
  return await updateFaqNode(id, { active: !!active });
}

// 순서 교환 — 두 노드의 sort_order 를 맞바꿈 (호출측에서 현재 sort 값 전달)
async function swapFaqNodeOrder(idA, sortA, idB, sortB) {
  if (!db) return { ok: false, error: 'no_db' };
  try {
    return await retryWithRefresh(async () => {
      const e1 = (await db?.from('faq_nodes').update({ sort_order: sortB }).eq('id', idA)).error;
      const e2 = (await db?.from('faq_nodes').update({ sort_order: sortA }).eq('id', idB)).error;
      if (e1 || e2) throw (e1 || e2);
      return { ok: true };
    });
  } catch (e) { console.error('[swapFaqNodeOrder]', e); return { ok: false, error: e?.message }; }
}

// 노드 삭제 (카테고리 삭제 시 자식 ON DELETE CASCADE)
async function deleteFaqNode(id) {
  if (!db) return { ok: false, error: 'no_db' };
  try {
    return await retryWithRefresh(async () => {
      const { error } = await db?.from('faq_nodes').delete().eq('id', id);
      if (error) throw error;
      return { ok: true };
    });
  } catch (e) { console.error('[deleteFaqNode]', e); return { ok: false, error: e?.message }; }
}

// FAQ 상호작용 기록 (RPC record_faq_interaction) — PR B 인플 화면 + PR A 스모크
//   action: 'viewed' | 'resolved' | 'handoff'. viewed 는 서버에서 멱등 UPSERT.
async function recordFaqInteraction(applicationId, faqNodeId, action) {
  if (!db) return { ok: false, error: 'no_db' };
  try {
    return await retryWithRefresh(async () => {
      const { data, error } = await db.rpc('record_faq_interaction', {
        p_application_id: applicationId || null,
        p_faq_node_id: faqNodeId || null,
        p_action: action
      });
      if (error) throw error;
      return { ok: true, data };
    });
  } catch (e) { console.error('[recordFaqInteraction]', e); return { ok: false, error: e?.message }; }
}

// 관리자 응모건 상태 한 줄(§3-1)용 — 응모 1건의 status + 결과물 status 배열을 함께 조회.
//   §3-0 판정이 결과물 상태를 일정보다 먼저 보므로 status 와 결과물 집계가 모두 필요.
//   반환: { status, delivs:[{status}] } (없으면 null)
async function fetchApplicationStatusBundle(applicationId) {
  if (!db || !applicationId) return null;
  try {
    const [{ data: app }, { data: delivs }] = await Promise.all([
      db?.from('applications').select('id, status').eq('id', applicationId).maybeSingle(),
      db?.from('deliverables').select('status').eq('application_id', applicationId).neq('status', 'draft'),
    ]);
    if (!app) return null;
    return { status: app.status, delivs: (delivs || []).map(d => ({ status: d.status })) };
  } catch (e) { console.error('[fetchApplicationStatusBundle]', e); return null; }
}

// 관리자 FAQ 열람 이력 패널(§3-2)용 — 한 응모건의 faq_interactions 를 시간순 + faq_nodes 역참조.
//   RLS SELECT 는 is_admin() (마이그레이션 146). faq_node_id 가 SET NULL 된 행은 노드 제목 없이 표시.
//   반환: 시간순(created_at 오름차순) 배열 [{action, view_count, created_at, last_viewed_at,
//          faq_node_id, label_ko, body_ko}]
async function fetchFaqInteractionsForApp(applicationId) {
  if (!db || !applicationId) return [];
  try {
    const { data, error } = await db?.from('faq_interactions')
      .select('id, faq_node_id, action, view_count, created_at, last_viewed_at, faq_nodes:faq_node_id (label_ko, body_ko)')
      .eq('application_id', applicationId)
      .order('created_at', { ascending: true });
    if (error) { console.warn('[fetchFaqInteractionsForApp]', error); return []; }
    return (data || []).map(r => ({
      id: r.id,
      faq_node_id: r.faq_node_id,
      action: r.action,
      view_count: r.view_count,
      created_at: r.created_at,
      last_viewed_at: r.last_viewed_at,
      label_ko: r.faq_nodes?.label_ko || '',
      body_ko: r.faq_nodes?.body_ko || '',
    }));
  } catch (e) { console.error('[fetchFaqInteractionsForApp]', e); return []; }
}

// ── 사용자 앱 에러 수집 (마이그레이션 165) ──
// error-report.js 의 collectClientError 가 마스킹·디바운스 후 호출.
// 실패는 완전 무음 (보고 실패가 앱 동작을 막으면 안 됨).
async function reportClientError(payload) {
  if (!db) return;
  try { await db.rpc('report_client_error', payload); }
  catch (e) { /* 무음 — 에러 보고 실패는 삼킨다 */ }
}

// 관리자 오류 로그 조회 (RLS: is_admin() 만). 1000행 캡 대응 pagination.
async function fetchClientErrors(filters = {}) {
  if (!db) return [];
  try {
    return await fetchAllPaged(() => {
      let q = db.from('client_error_logs').select('*');
      if (filters.status) q = q.eq('status', filters.status);
      if (filters.source) q = q.eq('source', filters.source);
      if (filters.since)  q = q.gte('last_seen_at', filters.since);
      return q.order('last_seen_at', { ascending: false });
    });
  } catch (e) { console.error('[fetchClientErrors]', e); return []; }
}

// 미해결(open) 오류 건수 — 사이드바 배지용
async function fetchClientErrorOpenCount() {
  if (!db) return 0;
  try {
    const { count, error } = await db.from('client_error_logs')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'open');
    if (error) throw error;
    return count || 0;
  } catch (e) { console.error('[fetchClientErrorOpenCount]', e); return 0; }
}

// 관리자 상태 변경 (resolved / ignored / open 되돌리기). resolve_client_error RPC.
async function resolveClientError(id, status, note) {
  if (!db) return false;
  try {
    await retryWithRefresh(async () => {
      const { error } = await db.rpc('resolve_client_error', { p_id: id, p_status: status, p_note: note || null });
      if (error) throw error;
    });
    return true;
  } catch (e) { console.error('[resolveClientError]', e); return false; }
}

// ── 감사용 계정 흔적 제거 (super_admin 한정, 마이그레이션 179) ──
//
// ⚠️ Storage 삭제 메모
//   - 메시지 첨부(message_attachments): RPC가 반환하는 값이 이미 버킷 상대 경로({appId}/{uuid}.jpg)이므로
//     그대로 db.storage.from('application-message-attachments').remove([...paths]) 로 삭제.
//   - 영수증 이미지(receipt_images): receipt_url 컬럼에는 Supabase 공개 전체 URL이 저장됨
//     (https://{project}.supabase.co/storage/v1/object/public/campaign-images/receipts/...).
//     db.storage.remove()는 버킷 내 상대 경로를 요구하므로, URL에서
//     '/storage/v1/object/public/campaign-images/' 접두사를 제거해 상대 경로를 추출한다.
//     변환 실패 시(접두사 불일치 등) 그 파일만 건너뛰고 나머지는 계속 처리.

// Supabase 공개 URL → campaign-images 버킷 상대 경로 변환 헬퍼
// 예: 'https://xxx.supabase.co/storage/v1/object/public/campaign-images/receipts/abc.jpg'
//     → 'receipts/abc.jpg'
// 변환 불가(형식 불일치)면 null 반환.
function _receiptUrlToStoragePath(url) {
  if (!url || typeof url !== 'string') return null;
  const MARKER = '/storage/v1/object/public/campaign-images/';
  const idx = url.indexOf(MARKER);
  if (idx === -1) return null;
  const path = url.slice(idx + MARKER.length);
  return path || null;
}

// Storage 파일 삭제 공통 헬퍼.
// bucket: 버킷명, paths: 상대 경로 배열 (빈 배열이면 즉시 반환).
// 삭제 실패 시 에러를 throw 하지 않고 {ok, failedPaths} 형태로 반환
// (일부 경로 삭제 실패가 흔적 제거 전체를 막지 않도록).
async function _deleteStorageFiles(bucket, paths) {
  if (!db || !Array.isArray(paths) || paths.length === 0) return { ok: true, failedPaths: [] };
  try {
    const { error } = await db.storage.from(bucket).remove(paths);
    if (error) {
      console.warn(`[_deleteStorageFiles] ${bucket} 삭제 실패:`, error);
      return { ok: false, failedPaths: paths };
    }
    return { ok: true, failedPaths: [] };
  } catch (e) {
    console.warn(`[_deleteStorageFiles] ${bucket} 예외:`, e);
    return { ok: false, failedPaths: paths };
  }
}

// 모든 감사용 계정 흔적 제거.
// RPC 성공 후 Storage 파일(메시지 첨부 + 영수증 이미지)도 후속 삭제.
// 반환: { rpc, storageResult } — 호출처가 삭제 결과를 사용자에게 표시할 수 있도록.
async function purgeAuditDataAll() {
  if (!db) throw new Error('DB 미연결');
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('purge_audit_data_all');
    if (error) throw error;

    // RPC 결과가 'no_audit_account' 이면 삭제할 Storage 파일도 없음
    if (!data || data.status === 'no_audit_account') {
      return { rpc: data, storageResult: null };
    }

    const storagePaths = data.storage_paths_to_delete || {};

    // 메시지 첨부: 이미 버킷 상대 경로
    const msgPaths = Array.isArray(storagePaths.message_attachments)
      ? storagePaths.message_attachments.filter(Boolean)
      : [];

    // 영수증: 전체 URL → 버킷 상대 경로 변환 (변환 불가 항목 제외)
    const receiptPaths = Array.isArray(storagePaths.receipt_images)
      ? storagePaths.receipt_images.map(_receiptUrlToStoragePath).filter(Boolean)
      : [];

    const [msgResult, receiptResult] = await Promise.all([
      _deleteStorageFiles(MSG_ATTACH_BUCKET, msgPaths),
      _deleteStorageFiles('campaign-images', receiptPaths),
    ]);

    return {
      rpc: data,
      storageResult: { msgResult, receiptResult },
    };
  });
}

// 특정 캠페인의 감사용 계정 흔적 제거.
// 반환: { rpc, storageResult }
async function purgeAuditDataForCampaign(campaignId) {
  if (!db) throw new Error('DB 미연결');
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('purge_audit_data_for_campaign', {
      p_campaign_id: campaignId,
    });
    if (error) throw error;

    // 응모건 0건 케이스: storage_paths_to_delete 키 자체가 없을 수 있음
    if (!data || data.status === 'no_audit_account' || !data.storage_paths_to_delete) {
      return { rpc: data, storageResult: null };
    }

    const storagePaths = data.storage_paths_to_delete;

    const msgPaths = Array.isArray(storagePaths.message_attachments)
      ? storagePaths.message_attachments.filter(Boolean)
      : [];

    const receiptPaths = Array.isArray(storagePaths.receipt_images)
      ? storagePaths.receipt_images.map(_receiptUrlToStoragePath).filter(Boolean)
      : [];

    const [msgResult, receiptResult] = await Promise.all([
      _deleteStorageFiles(MSG_ATTACH_BUCKET, msgPaths),
      _deleteStorageFiles('campaign-images', receiptPaths),
    ]);

    return {
      rpc: data,
      storageResult: { msgResult, receiptResult },
    };
  });
}


// ════════════════════════════════════════════════════════════════════
// 브랜드 셀프 오리엔시트 — PR 1 (DB + 익명 토큰 함수)
//   사양서: docs/specs/2026-06-18-brand-self-orient-sheet.md §6, §7
//   마이그레이션: 186(테이블) → 187(함수 3종)
//
//   이 함수 3종은 비로그인 브랜드 담당자(sales 폼)에서 호출되는 익명 경로.
//   따라서 세션 갱신(retryWithRefresh) 없이 db.rpc 직접 호출한다 — 140 패턴과 동일.
//   (익명 호출에서 JWT 세션이 없으므로 갱신 시도 자체가 무의미)
// ════════════════════════════════════════════════════════════════════

// 오리엔시트 조회 — 토큰으로 현재 내용·상태를 가져온다.
// 연결된 신청이 있으면 initial_values(모집 희망값)도 함께 반환.
// 반환: {ok:true, id, form_type, data, status, version, submitted_at, initial_values}
//        | {ok:false, error, reason}
async function getOrientSheet(token) {
  if (!db) return { ok: false, error: 'no_db' };
  if (!token) return { ok: false, error: 'invalid_token' };
  try {
    const { data, error } = await db.rpc('get_orient_sheet', { p_token: token });
    if (error) throw error;
    // data: {success:bool, reason?, id?, form_type?, data?, status?, version?, submitted_at?, initial_values?}
    if (data && data.success) {
      return {
        ok:             true,
        id:             data.id,
        form_type:      data.form_type,
        data:           data.data,
        status:         data.status,
        version:        data.version,
        submitted_at:   data.submitted_at,
        initial_values: data.initial_values || null,
      };
    }
    return { ok: false, error: data?.reason || 'invalid_token', reason: data?.reason };
  } catch (e) {
    // 잘못된 UUID 형식 등은 무효 토큰으로 처리
    console.error('[getOrientSheet]', e);
    return { ok: false, error: 'invalid_token' };
  }
}

// 오리엔시트 임시저장 — 작성 중 중간 저장. status는 변경하지 않음(submitted→draft 역전환 없음).
// 반환: {ok:true, version} | {ok:false, error, reason, current_version?}
async function saveOrientDraft(token, data, version) {
  if (!db) return { ok: false, error: 'no_db' };
  if (!token) return { ok: false, error: 'invalid_token' };
  try {
    const { data: result, error } = await db.rpc('save_orient_draft', {
      p_token:   token,
      p_data:    data,
      p_version: version,
    });
    if (error) throw error;
    // result: {success:bool, reason?, version?, current_version?, ...}
    if (result && result.success) {
      return { ok: true, version: result.version };
    }
    return {
      ok:              false,
      error:           result?.reason || 'unknown',
      reason:          result?.reason,
      current_version: result?.current_version,
    };
  } catch (e) {
    console.error('[saveOrientDraft]', e);
    return { ok: false, error: e?.message || 'unknown' };
  }
}

// 오리엔시트 제출 — 브랜드 담당자의 최종 제출. draft/submitted → submitted.
// 발행 전까지 재제출 가능(사양서 결정⑨).
// 반환: {ok:true, version, submitted_at} | {ok:false, error, reason, current_version?}
async function submitOrientSheet(token, data, version) {
  if (!db) return { ok: false, error: 'no_db' };
  if (!token) return { ok: false, error: 'invalid_token' };
  try {
    const { data: result, error } = await db.rpc('submit_orient_sheet', {
      p_token:   token,
      p_data:    data,
      p_version: version,
    });
    if (error) throw error;
    // result: {success:bool, reason?, version?, submitted_at?, current_version?}
    if (result && result.success) {
      return {
        ok:           true,
        version:      result.version,
        submitted_at: result.submitted_at,
      };
    }
    return {
      ok:              false,
      error:           result?.reason || 'unknown',
      reason:          result?.reason,
      current_version: result?.current_version,
    };
  } catch (e) {
    console.error('[submitOrientSheet]', e);
    return { ok: false, error: e?.message || 'unknown' };
  }
}

// ── 오리엔시트 관리자 발급·조회 (PR3, 마이그레이션 190) ──
// 발급: create_orient_sheet RPC (is_admin 가드, SECURITY DEFINER)
// §15-11 재설계 — 2인자(brand_id, application_id). form_type·제품 prefill은 발급 시 미결정.
// data 초기값: {brand:{name,intro,official_accounts}, cards:[]}
// 반환: {success, id, token, token_expires_at} | {success:false, reason}
async function createOrientSheet(brandId, applicationId) {
  if (!db) return { success: false, reason: 'no_db' };
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('create_orient_sheet', {
      p_brand_id: brandId,
      p_application_id: applicationId || null,
    });
    if (error) throw error;
    return data;
  });
}

// 오리엔시트 발급 직후 브랜드 담당자에게 작성 링크 메일 발송 (Edge Function notify-orient-sheet).
// 발송 성공 시 연결 신청이 있으면 단계가 'orient_sheet_sent' 로 자동 전진(함수 198, 역행 방지).
// 반환: { sent:true, recipient, advanced } / { sent:false, reason:'no_recipient'|... } / { sent:false, error }
// 발송 실패가 발급 자체를 무효화하지 않도록 호출 측에서 결과만 표시(throw 안 함).
async function sendOrientInviteMail(orientSheetId, recipient) {
  if (!db) return { sent: false, reason: 'no_db' };
  // recipient(선택) 가 있으면 수신자 명시 — 없으면 Edge Function 이 자동 결정(서베이 연결 건 등)
  const body = { orient_sheet_id: orientSheetId };
  if (recipient && recipient.email) {
    body.to_email = recipient.email;
    if (recipient.name) body.to_name = recipient.name;
  }
  try {
    const { data, error } = await db.functions.invoke('notify-orient-sheet', { body });
    if (error) {
      // FunctionsHttpError 는 응답 본문(reason)을 error.context 에 담을 수 있음
      let detail = null;
      try { detail = await error.context?.json?.(); } catch (_e) { /* ignore */ }
      return { sent: false, error: error.message, ...(detail || {}) };
    }
    return data || { sent: false, reason: 'empty_response' };
  } catch (e) {
    return { sent: false, error: (e && e.message) || 'invoke_failed' };
  }
}

// 관리자 초대·비밀번호 재설정 메일 발송 (Edge Function notify-admin-invite).
// Supabase Auth 기본 발송(resetPasswordForEmail)을 쓰지 않는 이유 2가지:
//   1) Auth 는 메일 종류별 템플릿이 1개라 "Reset password" 를 인플루언서 비밀번호 찾기와 공유한다.
//   2) flowType:'pkce' 라 resetPasswordForEmail 은 코드 교환 검증값을 "호출한 브라우저"에 저장하는데,
//      관리자 초대는 super_admin 브라우저에서 호출하고 링크는 초대받은 사람의 다른 브라우저에서 열린다
//      → 검증값이 없어 교환 실패. 서버 발급(generateLink)은 이 문제가 없다.
// mode: 'invite'(초대 최초 설정) | 'reset'(재발송·재설정) — 착지 화면 문구만 좌우.
// 사양서 docs/specs/2026-07-20-admin-invite-mail-and-setpw.md
async function sendAdminInviteMail(email, mode) {
  if (!db) return { sent: false, reason: 'no_db' };
  try {
    const { data, error } = await db.functions.invoke('notify-admin-invite', {
      body: { email, mode: mode || 'invite' }
    });
    if (error) {
      // FunctionsHttpError 는 응답 본문(reason)을 error.context 에 담을 수 있음
      let detail = null;
      try { detail = await error.context?.json?.(); } catch (_e) { /* ignore */ }
      return { sent: false, error: error.message, ...(detail || {}) };
    }
    return data || { sent: false, reason: 'empty_response' };
  } catch (e) {
    return { sent: false, error: (e && e.message) || 'invoke_failed' };
  }
}

// 오리엔시트 삭제 (마이그레이션 199, delete_orient_sheet RPC).
// 발행 캠페인 없으면 시트만 삭제(is_admin) / 연결 있으면 신청 0건 캠페인까지 함께 삭제(is_campaign_admin),
// 신청 1건+ 있으면 차단(blocked_has_applications). 반환 jsonb 그대로 전달(호출 측이 reason 분기).
async function deleteOrientSheet(orientId) {
  if (!db) return { success: false, reason: 'no_db' };
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('delete_orient_sheet', { p_orient_id: orientId });
    if (error) throw error;
    return data;
  });
}

// 오리엔시트 카드 1개를 발행 캠페인과 연결(소비). 마이그레이션 196.
// 카드별 멱등(이미 발행 카드면 거부), 모든 카드 발행 시 시트 status='consumed'.
async function markOrientCardConsumed(orientId, cardIdx, campaignId) {
  if (!db) return { success: false, reason: 'no_db' };
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('mark_orient_card_consumed', {
      p_orient_id: orientId,
      p_card_idx: cardIdx,
      p_campaign_id: campaignId,
    });
    if (error) throw error;
    return data;
  });
}

// 오리엔시트 카드 1개를 "신규 캠페인 생성"이 아니라 관리자가 이미 만들어둔
// 기존 캠페인과 연결(발행 처리). 마이그레이션 237.
// 서버가 브랜드 일치·전역 중복(다른 시트/카드에서 이미 이 캠페인을 쓰는지) 검증.
// 반환 reason: not_found/permission_denied/invalid_status/invalid_card/
//   already_published/campaign_not_found/brand_mismatch/campaign_already_linked
async function linkOrientCardToCampaign(orientId, cardIdx, campaignId) {
  if (!db) return { success: false, reason: 'no_db' };
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('link_orient_card_to_campaign', {
      p_orient_id: orientId,
      p_card_idx: cardIdx,
      p_campaign_id: campaignId,
    });
    if (error) throw error;
    return data;
  });
}

// 오리엔시트 카드 1개의 캠페인 연결 해제(되돌리기). 마이그레이션 238.
// 196·237 어느 경로로 연결됐든 대칭 동작. 캠페인 행 자체는 삭제·수정하지 않음.
// 반환 reason: not_found/permission_denied/invalid_card/not_linked
async function unlinkOrientCard(orientId, cardIdx) {
  if (!db) return { success: false, reason: 'no_db' };
  return await retryWithRefresh(async () => {
    const { data, error } = await db.rpc('unlink_orient_card', {
      p_orient_id: orientId,
      p_card_idx: cardIdx,
    });
    if (error) throw error;
    return data;
  });
}

// 목록: 관리자만 SELECT (RLS is_admin). 브랜드명 조인. PostgREST 1000행 cap 대비 페이지네이션.
async function fetchOrientSheets() {
  if (!db) return [];
  return await retryWithRefresh(async () =>
    fetchAllPaged(() => db.from('orient_sheets')
      .select('id, brand_id, application_id, orient_no, form_type, data, status, token, token_expires_at, submitted_at, created_at, campaign_id, mail_sent_at, mail_sent_to, brands(name, name_ja)')
      .order('created_at', { ascending: false }))
  );
}

// 상세: data 포함 단건
async function fetchOrientSheetById(id) {
  if (!db) return null;
  return await retryWithRefresh(async () => {
    const { data, error } = await db.from('orient_sheets')
      .select('*, brands(name, name_ja)')
      .eq('id', id)
      .maybeSingle();
    if (error) throw error;
    return data;
  });
}

// 신청(brand_applications)에 연결된 오리엔시트 (brand-app 상세 연결 링크용)
async function fetchOrientSheetsByApplication(applicationId) {
  if (!db) return [];
  return await retryWithRefresh(async () => {
    const { data, error } = await db.from('orient_sheets')
      .select('id, token, form_type, status, token_expires_at, created_at')
      .eq('application_id', applicationId)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return data || [];
  });
}

// ─── 정산 관리 (인플루언서 정산 관리 PR1, 마이그레이션 217~220) ──────────────────
// 화면(PR2)은 아직 없음 — storage.js 함수만 미리 정의. RLS는 has_permission('settlement.view','read')
// 게이트(server_enforced) — campaign_manager 는 이 기능이 hidden 이라 조회 자체가 서버에서 막힘.

// 관리자 조회 — campaign_admin 이상만 실제로 행을 받는다(그 외는 RLS로 빈 배열).
// PostgREST 1000행 cap 대비 fetchAllPaged 사용. opts: {status, campaignId, influencerId}
async function fetchSettlements(opts) {
  if (!db) return [];
  opts = opts || {};
  try {
    const data = await fetchAllPaged(() => {
      // amount_source/reward_part_jpy 는 마이그레이션 261 추가 — 금액이 캠페인 제품 가격에서
      // 나왔는지(리뷰어형) 현금 리워드에서 나왔는지(시딩·방문형) 목록에서 구분해 보여주기 위함.
      // 261 이전에 만들어진 기존 행은 'reward' 로 백필됨(NULL 이면 화면이 배지를 생략).
      let q = db.from('settlements').select(`
        id, influencer_id, application_id, campaign_id, amount_jpy, status,
        amount_source, reward_part_jpy,
        paypal_email, paid_at, paid_by, memo, version, created_at, updated_at,
        campaigns:campaign_id (id, campaign_no, title, brand, img1, recruit_type),
        settlement_events(count)
      `);
      if (opts.status && opts.status !== 'all') q = q.eq('status', opts.status);
      if (opts.campaignId) q = q.eq('campaign_id', opts.campaignId);
      if (opts.influencerId) q = q.eq('influencer_id', opts.influencerId);
      // pending 방치 방지: 오래된 순 (deliverables pending 정렬 컨벤션과 동일)
      q = q.order('created_at', {ascending: true});
      return q;
    });
    const infIds = [...new Set(data.map(s => s.influencer_id).filter(Boolean))];
    const infMap = await fetchInfluencersByIds(infIds);
    return data.map(s => ({
      ...s,
      influencers: infMap[s.influencer_id] || null,
      event_count: Array.isArray(s.settlement_events) ? (s.settlement_events[0]?.count ?? 0) : 0,
    }));
  } catch(e) { console.error('[fetchSettlements]', e); return []; }
}

// 정산 인플루언서 공개 여부 조회 (is_settlement_public, 마이그레이션 240).
// 불리언만 반환하는 SECURITY DEFINER 함수 — 로그인 사용자면 누구나 호출 가능.
// 실패 시 false(잠금) 로 폴백해 안전측으로 동작.
async function isSettlementPublic() {
  if (!db) return false;
  try {
    const {data, error} = await db.rpc('is_settlement_public');
    if (error) throw error;
    return data === true;
  } catch(e) { console.error('[isSettlementPublic]', e); return false; }
}

// 인플루언서 본인 정산 내역 (마이페이지 「報酬・精算」, PR3 예정). RLS SELECT 본인행만이라
// 필터 없이 그대로 조회해도 안전.
// ⚠️ 마이그레이션 240 이후 본인 조회 정책에 공개 스위치가 함께 걸려 있어, 잠금 상태에서는
//    서버가 0건을 반환한다(화면 가림과 이중 방어).
async function fetchMySettlements() {
  if (!db) return [];
  try {
    const {data, error} = await db.from('settlements').select(`
      id, application_id, campaign_id, amount_jpy, status, paid_at, created_at,
      campaigns:campaign_id (id, title, brand, img1)
    `).order('created_at', {ascending: false});
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchMySettlements]', e); return []; }
}

// 인증 성공 응모 → 정산행 백필(UPSERT, 멱등). 서버가 has_permission('settlement.view','read') 로
// 재검증하므로 campaign_manager 가 호출하면 42501(permission_denied) 에러.
// 반환: { created_count, paypal_missing_count }
async function backfillSettlements() {
  if (!db) throw new Error('DB 미연결');
  let result = { created_count: 0, paypal_missing_count: 0 };
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('backfill_settlements');
    if (error) throw error;
    result = Array.isArray(data) ? (data[0] || result) : (data || result);
  });
  return result;
}

// 송금 완료 처리(낙관적 락) — RPC mark_settlement_paid(마이그레이션 222). pending → paid 전이,
// paypal_email 재조회·미등록 시 차단, settlement_paid 알림 발행, settlement_events 이력 기록.
// 버전 충돌 시 -1 반환("이미 처리됨" 토스트). 정산 관리 페인(admin-settlements.js)에서 호출.
async function markSettlementPaid(id, version, memo) {
  if (!db) throw new Error('DB 미연결');
  let newVersion = -1;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('mark_settlement_paid', {
      p_settlement_id: id,
      p_version: version,
      p_memo: memo || null
    });
    if (error) throw error;
    newVersion = data;
  });
  return newVersion;
}

// 보류 처리(낙관적 락) — RPC mark_settlement_hold (마이그레이션 223).
// pending 또는 paid → on_hold. 반환값 -1 = 다른 관리자가 이미 처리(버전 충돌, 재조회 필요).
async function markSettlementHold(id, version, memo) {
  if (!db) throw new Error('DB 미연결');
  let newVersion = -1;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('mark_settlement_hold', {
      p_settlement_id: id,
      p_version: version,
      p_memo: memo || null
    });
    if (error) throw error;
    newVersion = data;
  });
  return newVersion;
}

// 취소 처리(낙관적 락) — RPC mark_settlement_cancel (마이그레이션 223).
// pending 또는 on_hold → cancelled (paid 는 서버가 거부 — 먼저 markSettlementHold 필요).
// 반환값 -1 = 다른 관리자가 이미 처리(버전 충돌, 재조회 필요).
async function markSettlementCancel(id, version, memo) {
  if (!db) throw new Error('DB 미연결');
  let newVersion = -1;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('mark_settlement_cancel', {
      p_settlement_id: id,
      p_version: version,
      p_memo: memo || null
    });
    if (error) throw error;
    newVersion = data;
  });
  return newVersion;
}

// 보류 해제(낙관적 락) — RPC mark_settlement_revert (마이그레이션 224).
// on_hold → pending 만 허용(보류를 다시 정산 대기로 복귀). 반환값 -1 = 다른 관리자가
// 이미 처리(버전 충돌, 재조회 필요).
async function markSettlementRevert(id, version, memo) {
  if (!db) throw new Error('DB 미연결');
  let newVersion = -1;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('mark_settlement_revert', {
      p_settlement_id: id,
      p_version: version,
      p_memo: memo || null
    });
    if (error) throw error;
    newVersion = data;
  });
  return newVersion;
}

// 정산 이력 조회 — RPC get_settlement_events (마이그레이션 225).
// settlement_events 를 관리자 이름(actor_name)으로 변환해 시간순(오래된 것부터) 반환.
// 조회 전용이라 retryWithRefresh 없이 db.rpc 직접 호출(다른 fetch* 함수와 동일 패턴).
// 실패 시 빈 배열 반환(fetchSettlements 패턴 — 화면이 "이력 없음"으로 처리).
async function fetchSettlementEvents(settlementId) {
  if (!db) return [];
  try {
    const {data, error} = await db.rpc('get_settlement_events', {
      p_settlement_id: settlementId
    });
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchSettlementEvents]', e); return []; }
}

// 신청(application) 1건에 송금완료(paid) 정산이 있는지 조회 — 관리자 화면(admin-applications.js)이
// 반려(미승인)·되돌리기 버튼을 누르기 전 경고 모달을 띄우기 위한 1차(UI) 가드 용도.
// 최종 방어선은 데이터베이스 서버 트리거(마이그레이션 247 guard_reject_with_paid_settlement) —
// 이 함수가 false 를 반환해도(=조회가 막혀도) 실제 반려 시도는 서버 트리거가 다시 막는다.
// ⚠️ settlements SELECT 행 단위 보안 정책(RLS)은 has_permission('settlement.view','read') 게이트라,
// 정산 화면 열람 권한이 hidden 인 등급(campaign_manager, 마이그레이션 220/221 시드)은 이 조회 자체가
// 0건으로 보일 수 있다. 그래도 서버 트리거가 실제 UPDATE 를 최종적으로 막으므로 데이터 안전성엔
// 문제 없음 — 다만 그 등급에서는 UI 경고 모달이 안 뜨고 서버 예외로만 막힐 수 있다(campaign_admin
// 이상은 정상적으로 이 조회가 통과돼 UI 경고가 정상 동작).
async function hasPaidSettlementForApplication(applicationId) {
  if (!db || !applicationId) return false;
  try {
    const {count, error} = await db?.from('settlements')
      .select('id', {count: 'exact', head: true})
      .eq('application_id', applicationId)
      .eq('status', 'paid');
    if (error) throw error;
    return (count || 0) > 0;
  } catch(e) { console.error('[hasPaidSettlementForApplication]', e); return false; }
}

// ══════════════════════════════════════
// OUTBOUND INFLUENCERS — 인플루언서 추천 명단(아웃바운드 시딩·타이업)
//   마이그레이션 226(테이블·RLS)·227(lookup)·228(권한)·229(Storage 버킷).
//   기존 influencers(auth 계정 1:1)와 분리된 별도 자산 — 관리자 전용 내부 명단.
//   RLS 는 has_permission('outbound.view', ...) (campaign_manager 차단). 페인 = admin-outbound.js.
//   ⚠ 내부 전용 필드(nego_memo·가격)는 브랜드 뷰(5단계)에서 반드시 제외 — 여기선 관리자만이라 그대로 조회.
// ══════════════════════════════════════
const OUTBOUND_IMAGE_BUCKET = 'outbound-influencer-images';

// 전건 조회(PostgREST 1000행 제한 우회) — 필터·검색은 클라이언트(admin-outbound.js)에서.
async function fetchOutboundInfluencers(opts) {
  if (!db) return [];
  opts = opts || {};
  try {
    return await fetchAllPaged(() => {
      let q = db.from('outbound_influencers').select('*');
      if (opts.availability) q = q.eq('availability', opts.availability);
      if (opts.seriesCode) q = q.eq('series_code', opts.seriesCode);
      // 등록순 역순(최근 추가가 위로). 명단 관리 성격이라 이름순보다 최근 반영이 유용.
      return q.order('created_at', {ascending: false});
    });
  } catch(e) { console.error('[fetchOutboundInfluencers]', e); return []; }
}

// INSERT/UPDATE 통합 — row.id 유무로 분기. RLS 직접 정책(has_permission write)이 방어선.
//   반환: 저장된 행(id 포함). 신규는 호출자가 미리 crypto.randomUUID() 로 id 를 채워 넘긴다
//   (이미지 경로 {id}/... 를 저장 전에 만들 수 있게 — admin-outbound.js).
async function upsertOutboundInfluencer(row) {
  if (!db) return null;
  let saved = null;
  await retryWithRefresh(async () => {
    const {data, error} = await db.from('outbound_influencers')
      .upsert(row).select().maybeSingle();
    if (error) throw error;
    saved = data;
  });
  return saved;
}

async function deleteOutboundInfluencer(id) {
  if (!db || !id) return;
  await retryWithRefresh(async () => {
    const {error} = await db.from('outbound_influencers').delete().eq('id', id);
    if (error) throw error;
  });
}

// 대표 이미지 업로드 — outbound-influencer-images 버킷, 경로 {obId}/{난수}.{ext}.
//   저장은 경로(rep_image_path 컬럼)만 — 표시 시 outboundImagePublicUrl()로 공개 URL 조립.
//   File/Blob 직접 업로드(base64 변환 생략). 5MB·jpg/png/webp 는 버킷 정책이 최종 강제.
async function uploadOutboundImage(file, obId) {
  if (!db) throw new Error('storage_unavailable');
  if (!file || !file.size) throw new Error('file_required');
  const ALLOWED = ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];
  if (!ALLOWED.includes(file.type)) throw new Error('file_type_not_allowed');
  if (file.size > 5 * 1024 * 1024) throw new Error('file_too_large');
  const ext = file.type.split('/')[1] === 'jpeg' ? 'jpg' : file.type.split('/')[1];
  const rand = Math.random().toString(36).substring(2, 10);
  const path = obId + '/' + Date.now() + '_' + rand + '.' + ext;
  const {error} = await db.storage.from(OUTBOUND_IMAGE_BUCKET)
    .upload(path, file, {contentType: file.type, upsert: false, cacheControl: '86400'});
  if (error) throw error;
  return path;
}

// 경로 → 공개 URL. 공개 버킷이라 imgThumb() 로 썸네일 변환 가능.
function outboundImagePublicUrl(path) {
  if (!db || !path) return '';
  const {data} = db.storage.from(OUTBOUND_IMAGE_BUCKET).getPublicUrl(path);
  return (data && data.publicUrl) || '';
}

// 대표 이미지 삭제(교체·행 삭제 시 정리). best-effort — 실패해도 throw 하지 않는다.
async function deleteOutboundImage(path) {
  if (!db || !path) return;
  try { await db.storage.from(OUTBOUND_IMAGE_BUCKET).remove([path]); }
  catch(e) { console.warn('[deleteOutboundImage]', e); }
}

// ─── 정산 과거분 컷오프 — 과거 미등록 인증성공 조회/처리 (사양서 2026-07-09) ──────────
// 도입일(cutoff) 이전에 인증 성공했지만 정산행이 없는 응모 목록. 자동 백필은 컷오프 이후만
// 대상이라, 컷오프 이전 과거분은 이 목록에서 관리자가 건별/일괄로 직접 처리한다.
// RLS/서버 게이트 has_permission('settlement.view','read') → campaign_manager 는 빈 배열.
// 각 행: {application_id, influencer_id, influencer_name, influencer_name_kana, has_paypal(bool),
//   campaign_id, campaign_title, campaign_no, recruit_type, amount_jpy, cert_at(nullable),
//   amount_source('reward'|'product_price'|'product_plus_reward'), amount_issue(nullable)}
// ⚠️ campaign_no·amount_source·amount_issue 3종은 마이그레이션 262에서 추가. amount_issue 가
//   있는 행(금액 NULL·0 이하)은 서버가 등록에서 조용히 건너뛰므로 화면이 미리 선택을 잠근다.
async function fetchPastUnregisteredSettlements() {
  if (!db) return [];
  try {
    const {data, error} = await db.rpc('get_past_unregistered_settlements');
    if (error) throw error;
    return data || [];
  } catch(e) { console.error('[fetchPastUnregisteredSettlements]', e); return []; }
}

// 과거 미등록 인증성공 건을 정산행으로 일괄 등록(멱등 — application_id UNIQUE). 무알림.
//   p_target_status: 'paid'(이미 외부 PayPal 지급 완료) | 'pending'(아직 미지급, 정산 대기)
//   서버가 has_permission('settlement.pay','write') 게이트 + settlement_events 이력 기록.
// 반환: registered_count(정수 — 실제 등록된 건수. 이미 정산행 있는 건은 skip 되어 제외).
async function registerPastSettlements(applicationIds, targetStatus, memo) {
  if (!db) throw new Error('DB 미연결');
  let registered = 0;
  await retryWithRefresh(async () => {
    const {data, error} = await db.rpc('register_past_settlements', {
      p_application_ids: applicationIds,
      p_target_status: targetStatus,
      p_memo: memo || null
    });
    if (error) throw error;
    // 스칼라(정수) 또는 {registered_count} 단일 행 양쪽 대응
    registered = Array.isArray(data)
      ? (data[0]?.registered_count ?? data[0] ?? 0)
      : (data?.registered_count ?? data ?? 0);
  });
  return Number(registered) || 0;
}

