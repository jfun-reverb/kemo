// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-influencers.js
// ═════════════════════════════════════════════════════════════════
//
// 인플루언서 관리 페인 (admin.js 파일 분리).
//   · 목록/필터/정렬/행 빌더 (loadAdminInfluencers/renderInfTable/sortInfUsers 등)
//   · 상세 모달 + 파일 업로드 + 인증/위반/블랙리스트 패널
//     (openInfluencerDetail/renderInfluencerStatusPanel/renderInfluencerFlagsPanel/
//      onInfluencerVerify/onInfluencerRecordViolation/onInfluencerBlacklist 등)
//   · 상태: currentInfTab/infUsersCache/_infViolationCounts/infSort*/infLazy/_currentDetailInfluencer/
//     _blacklistReasonsCache/_violationReasonsCache/_cancelReasonsCache/_currentFlagsCache/_editingFlagId 등
//
// ⚠ loadAdminInfluencers 는 switchAdminPane(admin-core.js) loaders 가 참조 → 전역 유지(이름 변경 금지).
// ⚠ _infViolationCounts 는 대시보드 loadAdminData(admin.js 잔류)도 prefetch 로 할당하는 공유 변수.
//   빌드 순서상 이 파일이 admin.js 보다 앞이라 var 선언이 먼저 → 안전.
// ═════════════════════════════════════════════════════════════════

// ── 인플루언서 목록 ──
let currentInfTab = 'all';

var infUsersCache = null;
var _infViolationCounts = {};

// ════════════════════════════════════════════════════════════════════
// SECTION: INFLUENCERS — 목록 + 필터 + 정렬 + 행 빌더
// ════════════════════════════════════════════════════════════════════

async function loadAdminInfluencers() {
  const [users, violations] = await Promise.all([
    fetchInfluencers(),
    fetchViolationCountsByInfluencer(),
  ]);
  infUsersCache = users;
  _infViolationCounts = violations;
  initInfPrefectureMulti();
  applyInfExcelSensitiveVisibility();
  renderInfluencersPane();
}

// 「민감정보 포함」 체크박스는 엑셀 민감정보 포함 권한(influencer.excel_sensitive read 이상)이 있는
//   등급에게만 노출 (그 외 숨김). PR3-D 동적 권한 일원화(구 isCampaignAdminOrAbove 하드코딩 제거).
//   화면 열람 권한(influencer.sensitive_pii)과는 별개 항목 — 엑셀 대량 유출을 화면 열람과 따로 통제 가능.
//   미로드 시 canRead=fail-open(표시) — 실제 차단은 서버 가림막 뷰가 담당.
function applyInfExcelSensitiveVisibility() {
  const wrap = $('infExcelSensitiveWrap');
  if (!wrap) return;
  const allow = (typeof canRead === 'function') && canRead('influencer.excel_sensitive');
  wrap.style.display = allow ? 'inline-flex' : 'none';
  if (!allow) { const cb = $('infExcelSensitive'); if (cb) cb.checked = false; }
}

// 주소지(도도부현) 다중필터 옵션 초기화 — PREFECTURE_KO(일본어 키→한국어 라벨) + 미등록 + 해외.
// syncMultiFilter 는 옵션 변화 시에만 재생성하므로 반복 호출해도 선택 상태 보존.
function initInfPrefectureMulti() {
  if (typeof syncMultiFilter !== 'function') return;
  const map = (typeof PREFECTURE_KO !== 'undefined') ? PREFECTURE_KO : {};
  const options = Object.keys(map).map(ja => ({ value: ja, label: map[ja] }));
  options.push({ value: '未登録', label: '미등록' });
  options.push({ value: '海外', label: '해외' });
  syncMultiFilter('infPrefectureMulti', '전체 지역', options, rerenderInfluencersFromCache, { searchable: true, searchPlaceholder: '지역 검색' });
}

function rerenderInfluencersFromCache() {
  if (!infUsersCache) { loadAdminInfluencers(); return; }
  renderInfluencersPane();
}

// 현재 필터(인증/위반/검색/주소지/팔로워/채널)가 적용된 인플 목록 — 화면 표시·엑셀 내보내기 공용.
// 채널 선택 시 그 채널 등록자(팔로워>0) 행 필터까지 포함 → 카운트·표시 행·엑셀이 모두 일치.
function getFilteredInfluencersForView() {
  const users = infUsersCache || [];
  const verifiedSel = $('infFilterVerifiedSelect')?.value || 'all';
  const violationSel = $('infFilterViolationSelect')?.value || 'all';
  const searchQ = ($('infSearch')?.value || '').trim().toLowerCase();
  // 주소지(다중) — 미선택이면 빈 배열(=전체). classifyPrefecture 로 정식/未登録/海外 분류 후 매칭
  const prefSel = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('infPrefectureMulti') : [];
  // 팔로워 범위 — 비우면 하한/상한 무제한
  const minRaw = $('infFollowersMin')?.value;
  const maxRaw = $('infFollowersMax')?.value;
  const minF = (minRaw !== '' && minRaw != null) ? Number(minRaw) : null;
  const maxF = (maxRaw !== '' && maxRaw != null) ? Number(maxRaw) : null;
  // 채널 선택 시 그 채널 등록자만 (팔로워>0)
  const chKey = (currentInfTab && currentInfTab !== 'all')
    ? { instagram: 'ig_followers', x: 'x_followers', tiktok: 'tiktok_followers', youtube: 'youtube_followers' }[currentInfTab]
    : null;
  // 단어 단위 AND 매칭 (matchSearchTokens, 전각/반각 공백 무관)
  const matchSearch = (u) => matchSearchTokens(searchQ, [
    u.name_kanji, u.name, u.name_kana, u.email,
    u.ig, u.x, u.tiktok, u.youtube,
  ]);
  return users.filter(u => {
    if (verifiedSel === 'verified' && !u.is_verified) return false;
    if (verifiedSel === 'unverified' && u.is_verified) return false;
    const vc = (_infViolationCounts && _infViolationCounts[u.id]) || 0;
    if (violationSel === 'clean' && (vc > 0 || u.is_blacklisted)) return false;
    if (violationSel === 'has' && vc === 0 && !u.is_blacklisted) return false;
    if (violationSel === 'blacklist' && !u.is_blacklisted) return false;
    if (!matchSearch(u)) return false;
    if (prefSel.length && !prefSel.includes(classifyPrefecture(u.prefecture))) return false;
    if (minF != null || maxF != null) {
      const fv = followerValueByChannel(u, currentInfTab);
      if (minF != null && fv < minF) return false;
      if (maxF != null && fv > maxF) return false;
    }
    if (chKey && !(u[chKey] > 0)) return false;
    return true;
  });
}

function renderInfluencersPane() {
  const filtered = getFilteredInfluencersForView();
  const total = (infUsersCache || []).length;
  const totalEl = $('infTotalCount');
  if (totalEl) totalEl.textContent = `${filtered.length}명 표시 (전체 ${total}명)`;
  const resetBtn = $('btnInfViewReset');
  if (resetBtn) {
    const verifiedSel = $('infFilterVerifiedSelect')?.value || 'all';
    const violationSel = $('infFilterViolationSelect')?.value || 'all';
    const searchQ = ($('infSearch')?.value || '').trim();
    const prefSel = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('infPrefectureMulti') : [];
    const hasFollower = !!($('infFollowersMin')?.value || $('infFollowersMax')?.value);
    const hasSort = !(infSortKey === 'created' && infSortDir === 'desc');
    const anyActive = (verifiedSel !== 'all' || violationSel !== 'all' || currentInfTab !== 'all' || !!searchQ || prefSel.length > 0 || hasFollower || hasSort);
    resetBtn.style.display = anyActive ? '' : 'none';
  }
  renderInfTable(filtered);
}

// 보기 초기화 — 필터·검색·정렬을 한 번에 기본값으로
function resetInfView() {
  const v = $('infFilterVerifiedSelect'); if (v) v.value = 'all';
  const w = $('infFilterViolationSelect'); if (w) w.value = 'all';
  const c = $('infChannelFilter'); if (c) c.value = 'all';
  const s = $('infSearch'); if (s) s.value = '';
  if (typeof resetMultiFilter === 'function') resetMultiFilter('infPrefectureMulti', '전체 지역');
  const mn = $('infFollowersMin'); if (mn) mn.value = '';
  const mx = $('infFollowersMax'); if (mx) mx.value = '';
  currentInfTab = 'all';
  infSortKey = 'created'; infSortDir = 'desc';
  updateInfSortUI();
  rerenderInfluencersFromCache();
}

function switchInfTabFromSelect(ch) {
  currentInfTab = ch || 'all';
  rerenderInfluencersFromCache();
}

var infSortKey = 'created';
var infSortDir = 'desc';

function toggleInfSort(key) {
  if (infSortKey === key) {
    infSortDir = infSortDir === 'desc' ? 'asc' : 'desc';
  } else {
    infSortKey = key;
    infSortDir = 'desc';
  }
  updateInfSortUI();
  rerenderInfluencersFromCache();
}

function updateInfSortUI() {
  document.querySelectorAll('.inf-sort-arrows').forEach(el => {
    el.classList.remove('asc','desc');
    el.textContent = '▲▼';
    if (el.dataset.sort === infSortKey) {
      el.classList.add(infSortDir);
      el.textContent = infSortDir === 'asc' ? '▲' : '▼';
    }
  });
}

function sortInfUsers(users) {
  if (!infSortKey) return users;
  const dir = infSortDir === 'asc' ? 1 : -1;
  const getVal = {
    name: u => (u.name_kanji||u.name||'').toLowerCase(),
    ig: u => u.ig_followers||0,
    x: u => u.x_followers||0,
    tiktok: u => u.tiktok_followers||0,
    youtube: u => u.youtube_followers||0,
    total: u => (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0),
    line: u => u.has_line ? 1 : 0,
    addr: u => u.prefecture ? 1 : 0,
    paypal: u => u.has_paypal ? 1 : 0,
    created: u => new Date(u.created_at).getTime()
  };
  const fn = getVal[infSortKey];
  if (!fn) return users;
  return users.slice().sort((a,b) => {
    const va = fn(a), vb = fn(b);
    if (typeof va === 'string') return va.localeCompare(vb) * dir;
    return (va - vb) * dir;
  });
}

function infSortTh(label, key) {
  return `${label} <span class="sort-arrows inf-sort-arrows" data-sort="${key}" onclick="toggleInfSort('${key}')">${infSortKey===key?(infSortDir==='asc'?'▲':'▼'):'▲▼'}</span>`;
}

var infLazy = null;
const INF_PAGE_SIZE = 80;

// 인증/위반/블랙 상태 배지 (목록용)
// - 블랙리스트: 블랙 배지만 표시 (위반·인증 숨김)
// - 외: 인증(있을 때) + 위반 N건 (항상)
function influencerStatusBadges(u) {
  if (u.is_blacklisted) {
    return `<span title="블랙리스트" style="display:inline-flex;align-items:center;gap:2px;background:#FFEBEE;color:#C62828;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">block</span>블랙리스트</span>`;
  }
  const parts = [];
  if (u.is_verified) {
    parts.push(`<span title="인증됨" style="display:inline-flex;align-items:center;gap:2px;background:#E3F2FD;color:#1565C0;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">verified</span>인증</span>`);
  }
  const vc = (_infViolationCounts && _infViolationCounts[u.id]) || 0;
  if (vc > 0) {
    parts.push(`<span title="위반 기록 ${vc}건" style="display:inline-flex;align-items:center;gap:2px;background:#F5F5F5;color:#616161;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:11px">report</span>위반 ${vc}</span>`);
  }
  return parts.join('');
}

function buildInfRowAll(u) {
  const igF = (u.ig_followers||0).toLocaleString();
  const xF = (u.x_followers||0).toLocaleString();
  const ttF = (u.tiktok_followers||0).toLocaleString();
  const ytF = (u.youtube_followers||0).toLocaleString();
  const total = ((u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0)).toLocaleString();
  // 도도부현은 마스킹 대상 아님(항상 정확) — prefecture 없을 때만 마스킹 가능한 address 폴백,
  // 그 경우도 canRead 기준으로 "미등록"과 "열람 권한 없음"을 구분(PR3 조각 B).
  const addr = u.prefecture ? `${u.prefecture}${u.city||''}` : (maskedFieldByPermission(u.address) || '—');
  // PayPal 배지는 has_paypal(마스킹 무관 항상 정확한 존재 여부) 기준 — 값 자체가 아니라
  // "등록 여부"만 표시하므로 마스킹된 관리자 등급도 정확하게 본다.
  const paypalBadge = u.has_paypal ? `<span style="background:var(--green-l);color:var(--green);font-size:10px;font-weight:700;padding:2px 7px;border-radius:10px">등록완료</span>` : `<span style="background:var(--bg);color:var(--muted);font-size:10px;padding:2px 7px;border-radius:10px;border:1px solid var(--line)">미등록</span>`;
  // 계정을 등록한 채널만 팔로워 줄을 함께 보여준다 — 미등록 칸에 「팔로워 0명」이 남으면
  // 등록을 안 한 건지 진짜 0명인지 구분이 안 된다.
  const snsCell = (channel, raw, followers) => {
    const handle = extractSnsHandle(channel, raw);
    if (!handle) return '—';
    const safe = esc(handle);
    const url = snsProfileUrl(channel, handle);
    const inner = url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--pink)">@${safe}</a>` : `@${safe}`;
    return `<div style="max-width:140px;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${safe}">${inner}</div>`
      + `<div style="font-size:10px;color:var(--muted)">팔로워 ${followers}명</div>`;
  };
  const ellip = (s, w=140) => `<div style="max-width:${w}px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(s||'')}">${esc(s)||'—'}</div>`;
  return `<tr data-id="${esc(u.id)}" class="${u.is_audit?'audit-row':''}"${u.is_blacklisted?' style="opacity:.55"':''}>
    <td><div class="link-cell" onclick="openInfluencerDetail('${u.id}')">${esc(u.name_kanji||u.name)||'—'}${auditBadgeHtml(u)}${adminBadge(u.email)}${influencerStatusBadges(u)}</div><div style="font-size:11px;color:var(--muted)">${esc(u.email)}</div></td>
    <td>${snsCell('instagram', u.ig, igF)}</td>
    <td>${snsCell('x', u.x, xF)}</td>
    <td>${snsCell('tiktok', u.tiktok, ttF)}</td>
    <td>${snsCell('youtube', u.youtube, ytF)}</td>
    <td style="font-weight:700;color:var(--pink)">${total}</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(maskedFieldByFlag(u.line_id, u.has_line), 120)}</td>
    <td style="font-size:12px;color:var(--muted)">${ellip(addr, 160)}</td>
    <td>${paypalBadge}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(u.created_at)}</td>
  </tr>`;
}

// users 는 getFilteredInfluencersForView() 결과(채널 행 필터 포함). 열은 항상 전체 뷰(10컬럼)로 통일.
function renderInfTable(users) {
  const titleEl = $('infTableTitle');
  const headEl = $('infTableHead');
  const bodyEl = $('adminInfluencersBody');
  if (!bodyEl) return;

  const chLabel = { instagram: 'Instagram', x: 'X(Twitter)', tiktok: 'TikTok', youtube: 'YouTube' }[currentInfTab];
  if (titleEl) titleEl.textContent = chLabel ? `${chLabel} 등록자` : '인플루언서 전체';
  if (headEl) headEl.innerHTML = `<tr><th>${infSortTh('이름','name')}</th><th>${infSortTh('Instagram','ig')}</th><th>${infSortTh('X(Twitter)','x')}</th><th>${infSortTh('TikTok','tiktok')}</th><th>${infSortTh('YouTube','youtube')}</th><th>${infSortTh('합계','total')}</th><th>${infSortTh('LINE','line')}</th><th>${infSortTh('배송지','addr')}</th><th>${infSortTh('PayPal','paypal')}</th><th>${infSortTh('등록일','created')}</th></tr>`;
  const filtered = sortInfUsers(users);
  const renderRow = buildInfRowAll;
  const colspan = 10;

  const scrollRoot = bodyEl.closest('.admin-table-wrap');
  const emptyHtml = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>`;
  if (infLazy) infLazy.destroy();
  infLazy = mountLazyList({
    tbody: bodyEl,
    scrollRoot,
    rows: filtered,
    renderRow,
    pageSize: INF_PAGE_SIZE,
    emptyHtml,
  });
}

// ── 인플루언서 상세 ──
// ════════════════════════════════════════════════════════════════════
// SECTION: INFLUENCERS — 상세 모달 + 파일 업로드 + 인증/위반/블랙 패널
// ════════════════════════════════════════════════════════════════════

async function openInfluencerDetail(userId) {
  const users = await fetchInfluencers();
  const u = users.find(x => x.id === userId);
  if (!u) { toast('인플루언서를 찾을 수 없습니다','error'); return; }

  $('infDetailTitle').innerHTML = esc(u.name_kanji || u.name || u.email) + adminBadge(u.email) + influencerStatusBadges(u);

  // 기본 정보
  const row = (label, val) => `<div style="display:flex;padding:8px 0;border-bottom:1px solid var(--surface-dim,var(--bg))"><div style="width:100px;font-size:12px;font-weight:600;color:var(--muted);flex-shrink:0">${label}</div><div style="font-size:13px;color:var(--ink);flex:1">${esc(val)||'—'}</div></div>`;

  // 생년월일 + 만 나이 / 성별 (연령 정책 PR4 — 관리자 한국어 고정)
  const _genderKo = { male: '남성', female: '여성', other: '기타', undisclosed: '응답하지 않음' };
  const _age = (typeof calcAgeFromBirthdate === 'function') ? calcAgeFromBirthdate(u.birthdate) : null;
  const _bdLabel = u.birthdate ? (u.birthdate + (_age != null ? ` (만 ${_age}세)` : '')) : '';

  $('infDetailBasic').innerHTML =
    row('이름 (한자)', u.name_kanji || u.name) +
    row('이름 (카나)', u.name_kana) +
    row('생년월일', _bdLabel) +
    row('성별', _genderKo[u.gender] || '') +
    row('이메일', u.email) +
    row('카테고리', u.category) +
    row('자기소개', u.bio) +
    row('가입일', formatDate(u.created_at));

  // SNS
  const snsRow = (label, channel, raw, followers) => {
    const handle = extractSnsHandle(channel, raw);
    const url = snsProfileUrl(channel, handle);
    const idHtml = handle
      ? (url ? `<a href="${url}" target="_blank" rel="noopener noreferrer" style="color:var(--ink)">@${esc(handle)}</a>` : `@${esc(handle)}`)
      : '—';
    return `<div style="display:flex;align-items:center;padding:10px 0;border-bottom:1px solid var(--surface-dim,var(--bg));gap:12px">
      <div style="font-size:12px;font-weight:600;color:var(--muted);width:80px;flex-shrink:0">${label}</div>
      <div style="flex:1;font-size:13px;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(handle||'')}">${idHtml}</div>
      <div style="font-size:13px;font-weight:700;color:var(--pink)">${(followers||0).toLocaleString()}명</div>
    </div>`;
  };
  const totalF = (u.ig_followers||0)+(u.x_followers||0)+(u.tiktok_followers||0)+(u.youtube_followers||0);
  $('infDetailSns').innerHTML =
    snsRow('Instagram', 'instagram', u.ig, u.ig_followers) +
    snsRow('X (Twitter)', 'x', u.x, u.x_followers) +
    snsRow('TikTok', 'tiktok', u.tiktok, u.tiktok_followers) +
    snsRow('YouTube', 'youtube', u.youtube, u.youtube_followers) +
    `<div style="display:flex;align-items:center;padding:12px 0;gap:12px"><div style="font-size:12px;font-weight:700;color:var(--ink);width:80px">총 팔로워</div><div style="font-size:18px;font-weight:800;color:var(--pink)">${totalF.toLocaleString()}명</div></div>`;

  // 연락처 (PR3 조각 B — 마스킹된 관리자 등급엔 NULL 대신 "열람 권한 없음" 표시)
  $('infDetailContact').innerHTML =
    row('LINE ID', maskedFieldByFlag(u.line_id, u.has_line)) +
    row('전화번호', u.phone ? formatPhoneDisplay(u.phone) : maskedFieldByPermission(u.phone));

  // 배송지 (zip/building/address 는 대응 존재 불리언이 없어 canRead 기준 근사 판정)
  const fullAddr = u.zip ? `〒${u.zip} ${u.prefecture||''}${u.city||''}${u.building?' '+u.building:''}` : maskedFieldByPermission(u.address);
  $('infDetailAddress').innerHTML =
    row('우편번호', maskedFieldByPermission(u.zip)) +
    row('도도부현', u.prefecture) +
    row('시구정촌', u.city) +
    row('건물명', maskedFieldByPermission(u.building)) +
    row('전체 주소', fullAddr);

  // PayPal — row() 내에서 esc() 처리됨
  // has_paypal(마스킹 무관 항상 정확) 로 등록 여부 먼저 판정 → 값이 마스킹돼 NULL이면
  // "열람 권한 없음", 값이 있으면 그대로 표시 (PR3 조각 B).
  $('infDetailPaypal').innerHTML = u.has_paypal
    ? (u.paypal_email
        ? row('PayPal 이메일', u.paypal_email)
        : '<div style="text-align:center;color:var(--muted);padding:16px;font-size:13px">열람 권한 없음</div>')
    : '<div style="text-align:center;color:var(--muted);padding:16px;font-size:13px">PayPal 미등록</div>';

  // 상태 관리 (인증 / 위반 관리 · 관리자 이력 포함)
  await renderInfluencerStatusPanel(u);
  renderInfluencerFlagsPanel(u.id);

  // 탈퇴 신청 (작업 19) — 상태 관리 뒤. 조회가 늦어도 다른 칸을 막지 않게 기다리지 않는다.
  renderInfluencerWithdrawalPanel(u);

  // 신청 이력
  const apps = await fetchApplications({user_id: userId});
  const camps = await fetchCampaigns();
  await ensureCancelReasonsCache();
  $('infDetailAppCount').textContent = `${apps.length}건`;
  $('infDetailAppsBody').innerHTML = apps.length ? apps.map(a => {
    const camp = camps.find(c=>c.id===a.campaign_id) || {};
    const typeLabel = getRecruitTypeBadgeKo(camp.recruit_type);
    const mainRow = `<tr>
      <td style="font-weight:600">${esc(camp.title)||esc(a.campaign_id)}</td>
      <td>${typeLabel}</td>
      <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
      <td>${getStatusBadgeKo(a.status, a.auto_reject_reason)}${a.status==='cancelled' && a.cancel_phase ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">${esc(cancelPhaseLabelKo(a.cancel_phase))}</div>` : ''}</td>
    </tr>`;
    if (a.status !== 'cancelled') return mainRow;
    // 취소 사유 보조 행
    const catLabel = a.cancel_reason_code ? esc(cancelReasonLabelKo(a.cancel_reason_code)) : '—';
    const noteHtml = a.cancel_reason ? `<div style="font-size:12px;color:var(--ink);margin-top:4px;white-space:pre-wrap"><strong style="font-weight:700">보충</strong> · ${esc(a.cancel_reason)}</div>` : '';
    const phaseLabel = esc(cancelPhaseLabelKo(a.cancel_phase));
    const whenStr = a.cancelled_at ? formatDateTime(a.cancelled_at) : '—';
    const appPayload = esc(JSON.stringify({
      id: a.id,
      cancel_reason: a.cancel_reason || '',
      cancel_reason_code: a.cancel_reason_code || '',
      cancel_phase: a.cancel_phase || '',
      cancel_category_ko: a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : ''
    }));
    return mainRow + `<tr><td colspan="4" style="padding:0">
      <div style="background:#FFF5F5;border-left:3px solid #C62828;padding:10px 14px;margin:0 0 4px;border-radius:0 6px 6px 0">
        <div style="font-size:11px;font-weight:700;color:#C62828;margin-bottom:6px">취소 사유</div>
        <div style="font-size:12px;color:var(--ink)"><strong style="font-weight:700">카테고리</strong> · ${catLabel}</div>
        ${noteHtml}
        <div style="font-size:11px;color:var(--muted);margin-top:6px"><strong style="font-weight:700">시점</strong> · ${phaseLabel} <span style="margin:0 4px;color:var(--line)">|</span> <strong style="font-weight:700">일시</strong> · ${whenStr}</div>
        <div style="margin-top:8px"><button class="btn btn-xs status-btn-orange" onclick='prefillViolationFromCancel(${appPayload})'>이 취소 건으로 위반 등록</button></div>
      </div>
    </td></tr>`;
  }).join('') : '<tr><td colspan="4" style="text-align:center;color:var(--muted);padding:24px">신청 이력 없음</td></tr>';

  // 감사용 흔적 청소 — super_admin + 감사용 계정(is_audit=true)일 때만 노출.
  // 일반 인플 상세에는 절대 렌더하지 않음(매번 innerHTML 초기화로 stale 방지).
  const auditBox = $('infDetailAuditPurge');
  if (auditBox) {
    const isSuper = currentAdminInfo?.role === 'super_admin';
    if (isSuper && u.is_audit === true) {
      auditBox.innerHTML = `
        <div class="admin-card" style="border:1px solid var(--line)">
          <div class="admin-card-header"><span class="admin-card-title">감사용 흔적 청소</span></div>
          <div style="padding:16px">
            <p style="font-size:13px;color:var(--muted);margin:0 0 12px">모든 감사용 계정의 응모·결과물·메시지·알림을 한 번에 삭제합니다. 감사용 계정 자체는 유지됩니다.</p>
            <button class="btn btn-sm" style="background:#C62828;color:#fff;border:none" onclick="purgeAllAuditData()"><span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:middle;margin-right:4px">cleaning_services</span>전체 흔적 청소</button>
          </div>
        </div>`;
    } else {
      auditBox.innerHTML = '';
    }
  }

  openModal('influencerFullDetailModal');
}

// 전체 감사용 흔적 청소 — super_admin 전용.
// 모든 감사용 계정(is_audit=true)의 응모·결과물·메시지·알림을 삭제(계정 자체는 유지).
async function purgeAllAuditData() {
  if (currentAdminInfo?.role !== 'super_admin') return;
  const ok = await showConfirm('모든 감사용 계정의 응모·결과물·메시지·알림을 삭제합니다. 감사용 계정 자체는 유지됩니다. 되돌릴 수 없습니다. 진행할까요?');
  if (!ok) return;
  try {
    const res = await purgeAuditDataAll();
    const rpc = res?.rpc;
    if (!rpc || rpc.status === 'no_audit_account' || !rpc.deleted || (rpc.deleted.applications || 0) === 0) {
      toast('삭제할 감사용 데이터 없음', '');
    } else {
      const n = rpc.deleted.applications || 0;
      toast(`감사용 응모 ${n}건·결과물 등 삭제됨`, 'success');
    }
    closeModal('influencerFullDetailModal');
    await refreshPane('influencers');
  } catch (e) {
    console.error('[purgeAllAuditData]', e);
    toast('감사용 흔적 청소 실패: ' + (e?.message || e), 'error');
  }
}

// 상태 관리 패널 — 인증 토글 + 블랙리스트 등록/해제 + 사유 입력
var _currentDetailInfluencer = null;
var _blacklistReasonsCache = null;
var _violationReasonsCache = null;
var _cancelReasonsCache = null;

// 취소 시점(cancel_phase) → 한국어 라벨
const CANCEL_PHASE_LABEL_KO = {
  recruit: '모집기간',
  purchase: '구매기간',
  visit: '방문기간',
  post: '결과물 제출기간',
  other: '기타'
};
function cancelPhaseLabelKo(phase) {
  return CANCEL_PHASE_LABEL_KO[phase] || phase || '—';
}

// cancel_reason 카테고리 캐시 lazy load
//   ⚠️ **비활성 사유까지 받아 온다.** 이 캐시는 「고르게 하려고」가 아니라 「지난 기록의
//      이름을 찾으려고」 쓰는 것이라, 나중에 비활성으로 돌린 사유가 붙은 옛 응모가
//      **코드값 그대로** 보이면 안 된다. 고르는 화면(인플루언서)은 활성만 받는다.
async function ensureCancelReasonsCache() {
  if (_cancelReasonsCache == null) _cancelReasonsCache = await fetchCancelReasons({includeInactive: true});
  return _cancelReasonsCache;
}
function cancelReasonLabelKo(code) {
  if (!code) return '';
  const r = (_cancelReasonsCache || []).find(x => x.code === code);
  return r?.name_ko || code;
}

// 증빙 파일: 등록 폼 ({file, previewUrl}[]) / 편집 모달 ({file, previewUrl}[] + keptPaths[])
var _pendingFlagFiles = [];
var _editingKeptPaths = [];
var _editingNewFiles = [];

function onFlagFileInput(input, targetList) {
  const arr = targetList === 'editing' ? _editingNewFiles : _pendingFlagFiles;
  [...input.files].forEach(f => {
    const url = f.type && f.type.startsWith('image/') ? URL.createObjectURL(f) : null;
    arr.push({file: f, previewUrl: url});
  });
  input.value = '';
  if (targetList === 'editing') renderEditingFilePreview();
  else renderFlagFilePreview();
}

function fileChipHtml(item, idx, targetList) {
  const thumb = item.previewUrl
    ? `<img src="${esc(item.previewUrl)}" style="width:48px;height:48px;object-fit:cover;border-radius:4px" onclick="openImageLightbox('${esc(item.previewUrl)}')">`
    : `<div style="width:48px;height:48px;background:#F0F0F0;display:flex;align-items:center;justify-content:center;border-radius:4px;font-size:10px;color:#666">${esc((item.file.name||'').split('.').pop().toUpperCase())}</div>`;
  return `<div style="position:relative;display:inline-block">${thumb}<button onclick="removePendingFile(${idx},'${targetList}')" style="position:absolute;top:-6px;right:-6px;width:18px;height:18px;border-radius:50%;background:#C62828;color:#fff;border:none;cursor:pointer;font-size:11px;line-height:1;padding:0" aria-label="삭제">×</button></div>`;
}

function renderFlagFilePreview() {
  const el = $('flagFilePreview');
  if (!el) return;
  el.innerHTML = _pendingFlagFiles.map((it, i) => fileChipHtml(it, i, 'pending')).join('');
}

function renderEditingFilePreview() {
  const el = $('editFilePreview');
  if (!el) return;
  const kept = _editingKeptPaths.map((p, i) => {
    const url = _editingKeptUrlMap[p];
    const thumb = url
      ? `<img src="${esc(url)}" style="width:48px;height:48px;object-fit:cover;border-radius:4px" onclick="openImageLightbox('${esc(url)}')">`
      : `<div style="width:48px;height:48px;background:#F0F0F0;display:flex;align-items:center;justify-content:center;border-radius:4px;font-size:10px;color:#666">파일</div>`;
    return `<div style="position:relative;display:inline-block" data-kept="${esc(p)}">${thumb}<button onclick="removeKeptPath(${i})" style="position:absolute;top:-6px;right:-6px;width:18px;height:18px;border-radius:50%;background:#C62828;color:#fff;border:none;cursor:pointer;font-size:11px;line-height:1;padding:0" aria-label="삭제">×</button></div>`;
  }).join('');
  const added = _editingNewFiles.map((it, i) => fileChipHtml(it, i, 'editing')).join('');
  el.innerHTML = kept + added;
}

function removePendingFile(idx, targetList) {
  const arr = targetList === 'editing' ? _editingNewFiles : _pendingFlagFiles;
  arr.splice(idx, 1);
  if (targetList === 'editing') renderEditingFilePreview();
  else renderFlagFilePreview();
}

function removeKeptPath(idx) {
  _editingKeptPaths.splice(idx, 1);
  renderEditingFilePreview();
}

async function uploadAllFiles(items, flagIdOrPrefix) {
  const paths = [];
  for (const it of items) {
    const p = await uploadFlagEvidence(it.file, flagIdOrPrefix);
    paths.push(p);
  }
  return paths;
}

var _editingKeptUrlMap = {};

async function renderInfluencerStatusPanel(u) {
  _currentDetailInfluencer = u;
  // 모달 다시 열릴 때 이전 세션의 펜딩 파일 초기화
  _pendingFlagFiles = [];
  const body = $('infDetailStatusBody');
  const summary = $('infDetailStatusSummary');
  if (!body) return;
  if (_blacklistReasonsCache == null) _blacklistReasonsCache = await fetchBlacklistReasons();
  if (_violationReasonsCache == null) _violationReasonsCache = await fetchViolationReasons();
  if (summary) summary.textContent = (u.is_verified?'인증됨':'미인증') + ' · ' + (u.is_blacklisted?'블랙 등록':'정상');
  // 위반/블랙 공유 사유 풀 — 합집합 (code dedupe)
  const reasonChecks = mergedReasonList().map(r =>
    `<label class="status-chip"><input type="checkbox" class="bl-reason-cb" value="${esc(r.code)}"><span>${esc(r.name_ko)}</span></label>`
  ).join('');
  const pillOk = `background:#F1F3F5;color:#868E96`;
  const pillVerified = `background:#E3F2FD;color:#1565C0`;
  const pillBlack = `background:#FFEBEE;color:#C62828`;
  body.innerHTML = `
    <style>
      .status-card{padding:16px 18px;background:#FAFAFA;border:1px solid var(--line);border-radius:10px;display:flex;flex-direction:column;gap:10px}
      .status-card-head{display:flex;align-items:center;justify-content:space-between}
      .status-card .title{display:flex;align-items:center;gap:6px;font-size:13px;font-weight:700;color:var(--ink);line-height:1}
      .status-card .title .material-icons-round{line-height:1}
      .status-pill{font-size:11px;font-weight:700;padding:3px 10px;border-radius:20px;letter-spacing:.02em}
      .status-meta{font-size:11px;color:var(--muted)}
      .status-actions{display:flex;gap:6px;justify-content:flex-end}
      .status-banner{padding:10px 12px;background:#FFF5F5;border-left:3px solid #C62828;border-radius:4px;display:flex;flex-direction:column;gap:4px}
      .status-chip{display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:4px 10px;border:1px solid var(--line);border-radius:20px;cursor:pointer;background:#fff;transition:all .12s}
      .status-chip:hover{border-color:#BDBDBD}
      .status-chip input{margin:0}
      .status-chip input:checked + span{color:#C62828;font-weight:600}
      .status-note{width:100%;font-size:12px;padding:8px 10px;border:1px solid var(--line);border-radius:6px;resize:vertical;font-family:inherit}
      .status-btn-orange{background:#FB8C00;color:#fff;border:none}
      .status-btn-red{background:#C62828;color:#fff;border:none}
    </style>
    <div style="display:flex;flex-direction:column;gap:14px">
      <!-- 인증 -->
      <div class="status-card">
        <div style="display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap">
          <div class="title">
            <span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:${u.is_verified?'#1565C0':'#9E9E9E'}">verified</span>
            ${u.is_verified?'인증':'미인증'}
          </div>
          <div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap">
            ${u.is_verified ? `
              <span class="status-meta">${u.verified_at?formatDateTime(u.verified_at):''}</span>
              <button class="btn btn-ghost btn-xs" onclick="onInfluencerUnverify()">인증 해제</button>
            ` : `
              <button class="btn btn-primary btn-xs" onclick="onInfluencerVerify()">인증 처리</button>
            `}
          </div>
        </div>
      </div>
      <!-- 위반 / 블랙 -->
      <div class="status-card">
        <div class="status-card-head">
          <div class="title"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:${(((_infViolationCounts||{})[u.id]||0)>0 || u.is_blacklisted)?'#C62828':'#9E9E9E'}">report</span>위반 관리</div>
          ${u.is_blacklisted
            ? `<button class="btn btn-ghost btn-xs" onclick="onInfluencerUnblacklist()">블랙 해제</button>`
            : `<button class="btn btn-xs status-btn-red" onclick="onInfluencerBlacklist()">블랙리스트 등록</button>`}
        </div>
        ${u.is_blacklisted ? `
          <div class="status-banner">
            <div class="status-meta">${u.blacklisted_at?formatDateTime(u.blacklisted_at):''}</div>
            ${u.blacklist_reason_code?`<div style="font-size:12px;color:var(--ink)"><strong style="font-weight:700">사유</strong> · ${esc(blacklistReasonLabel(u.blacklist_reason_code))}</div>`:''}
            ${u.blacklist_reason_note?`<div style="font-size:11px;color:var(--muted);white-space:pre-wrap">${esc(u.blacklist_reason_note)}</div>`:''}
          </div>
        ` : ''}
        <div>
          <div class="status-meta" style="margin-bottom:6px">사유 (1개 이상 선택)</div>
          <div style="display:flex;flex-wrap:wrap;gap:6px">${reasonChecks}</div>
        </div>
        <textarea id="blNoteInput" class="status-note" rows="2" placeholder="자유 메모 (선택)"></textarea>
        <div>
          <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;color:var(--pink);cursor:pointer">
            <input type="file" accept="image/*,application/pdf" multiple onchange="onFlagFileInput(this,'pending')" style="display:none">
            <span class="material-icons-round notranslate" translate="no" style="font-size:14px">attach_file</span>
            <span>파일 첨부</span>
          </label>
          <div id="flagFilePreview" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px"></div>
        </div>
        <div class="status-actions">
          <button class="btn btn-xs status-btn-orange" onclick="onInfluencerRecordViolation()">위반 등록</button>
        </div>
        <!-- 관리자 이력 (상태 관리 섹션 안으로 통합) -->
        <div style="margin-top:6px;padding-top:14px;border-top:1px solid var(--line)">
          <div style="display:flex;align-items:center;gap:6px;margin-bottom:8px">
            <div style="font-size:12px;font-weight:700;color:var(--ink);line-height:1">관리자 이력</div>
            <span id="infDetailFlagsCount" style="font-size:11px;color:var(--muted)"></span>
          </div>
          <div id="infDetailFlagsBody" style="border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff"><div style="padding:14px;text-align:center;color:var(--muted);font-size:12px">이력 없음</div></div>
        </div>
      </div>
    </div>
  `;
}

// ══════════════════════════════════════
// 탈퇴 신청 패널 (마이그레이션 355·356·357 — 작업 19)
//
//   ⚠️ 화면은 **서버가 준 mode 만 보고** 그린다. 「시행일 전인데 조건이…」를 화면이
//      스스로 계산하면 시행 후에 지워야 할 자리가 화면마다 생긴다.
//   ⚠️ 사전 조회(precheck)와 신청 이력(requests)은 **역할이 다르다** — 앞은 「지금
//      무엇을 그릴까」, 뒤는 주체·처리자·되돌린 기록이 담긴 원본 행이다.
// ══════════════════════════════════════
var _withdrawPanel = {influencerId: null, precheck: null, requests: [], reasons: null};

const WITHDRAW_STATUS_LABEL_KO = {
  pending_payout: '지급 대기',
  scheduled:      '탈퇴 예정',
  done:           '탈퇴 완료',
  cancelled:      '취소됨'
};
const WITHDRAW_KIND_LABEL_KO = {
  self:         '본인 신청',
  admin_proxy:  '관리자 대행',
  admin_forced: '관리자 강제(자격 상실)'
};
function withdrawStatusLabelKo(s) { return WITHDRAW_STATUS_LABEL_KO[s] || s || '—'; }
function withdrawKindLabelKo(k)   { return WITHDRAW_KIND_LABEL_KO[k]   || k || '—'; }

// 걸린 것 → 사람이 읽는 한 줄. 0건은 아예 안 그린다(늘 떠 있는 숫자는 아무도 안 본다).
function withdrawBlockerLines(b) {
  if (!b) return [];
  const out = [];
  if (b.approved_deliverable_apps > 0)
    out.push({text: `승인된 결과물이 있는 응모 ${b.approved_deliverable_apps}건 — <strong>철회되지 않습니다</strong>`});
  if (b.event_apps > 0)
    out.push({text: `행사(팝업) 예약 ${b.event_apps}건 — <strong>다음 날 새벽에 취소되고 자리가 대기자에게 넘어갑니다</strong>`, warn: true});
  if (b.settlement_rows > 0)
    out.push({text: `정산 기록 ${b.settlement_rows}건 — 개인정보를 지워도 거래 기록은 남습니다`});
  if (b.unpaid_count > 0)
    out.push({text: `받지 못한 보수 ${b.unpaid_count}건 — <strong>지급이 끝난 뒤에야 탈퇴가 확정됩니다</strong>(몇 달 걸릴 수 있습니다)`, warn: true});
  return out;
}

async function renderInfluencerWithdrawalPanel(u) {
  const body = $('infDetailWithdrawBody');
  const summary = $('infDetailWithdrawSummary');
  if (!body) return;
  _withdrawPanel = {influencerId: u.id, precheck: null, requests: [], reasons: _withdrawPanel.reasons};

  const [pre, reqs] = await Promise.all([
    fetchWithdrawalPrecheck(u.id),
    fetchWithdrawalRequests(u.id)
  ]);
  // 화면을 그리는 사이 관리자가 다른 회원을 열었으면 버린다(늦게 온 응답이 남의
  // 카드를 덮어쓰지 않게).
  if (_withdrawPanel.influencerId !== u.id) return;
  _withdrawPanel.precheck = pre;
  _withdrawPanel.requests = reqs;

  const active = (reqs || []).find(r => r.status === 'pending_payout' || r.status === 'scheduled');
  const past   = (reqs || []).filter(r => r !== active);
  if (summary) summary.textContent = reqs.length ? `${reqs.length}건` : '';

  // ① 아예 대상이 아닌 계정 — 버튼을 그렸다가 눌러서 거부당하는 일이 없게 미리 막는다
  if (pre && pre.ok === false && (pre.reason === 'admin_account_excluded' || pre.reason === 'audit_account_blocked')) {
    const msg = pre.reason === 'admin_account_excluded'
      ? '이 회원은 <strong>관리자 계정을 겸하고 있어</strong> 탈퇴 처리를 할 수 없습니다.<br><span style="color:var(--muted)">로그인 계정을 관리자와 같이 쓰기 때문에, 그대로 처리하면 이 사람의 관리자 로그인이 끊깁니다. 관리자 권한을 먼저 해제해야 합니다.</span>'
      : '감사용 계정이라 탈퇴 대상이 아닙니다.';
    body.innerHTML = `<div style="padding:10px 12px;background:#FFF5F5;border-left:3px solid #C62828;border-radius:4px;font-size:13px;line-height:1.7">${msg}</div>`;
    return;
  }

  // ★ 조회에 실패했으면 **버튼을 그리지 않는다.**
  //   서버 함수가 아직 없거나(마이그레이션 미적용) 통신이 끊긴 상황인데, 여기서
  //   버튼을 그리면 눌렀을 때 데이터베이스 원문 오류가 그대로 뜬다. 정산 3단계에서
  //   「버튼은 열렸는데 함수가 없던」 사고가 실제로 있었다.
  //   ⚠️ 실패는 storage.js 가 mode:'locked_support' 로 폴백해 오므로, ok 여부로만
  //     판정한다(mode 만 보면 「정상인데 걸린 회원」과 구분이 안 된다).
  const preOk = !!(pre && pre.ok === true);
  const canProxy = preOk && canWrite('withdrawal.proxy_request');
  let html = '';

  if (!preOk) {
    html += `<div style="padding:10px 12px;background:#FFF8E1;border-left:3px solid #F9A825;border-radius:4px;font-size:12px;color:var(--ink);line-height:1.7;margin-bottom:12px">
      탈퇴 처리 상태를 불러오지 못했습니다 — <strong>대신 신청 기능을 열지 않았습니다.</strong><br>
      <span style="color:var(--muted)">서버 준비가 끝나지 않았거나 통신이 끊겼을 수 있습니다. 새로고침해도 같으면 개발팀에 알려 주세요.</span>
    </div>`;
  }

  if (active) {
    const isAdminMade = active.requested_by_kind !== 'self';
    html += `
      <div style="padding:10px 12px;background:#FFF5F5;border-left:3px solid #C62828;border-radius:4px;display:flex;flex-direction:column;gap:4px;margin-bottom:12px">
        <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-bottom:6px">
          <span class="badge" style="background:#FFF3E0;color:#E65100">${esc(withdrawStatusLabelKo(active.status))}</span>
          <span style="font-size:12px;color:var(--muted)">${esc(withdrawKindLabelKo(active.requested_by_kind))}</span>
        </div>
        <div style="font-size:12px;color:var(--ink);line-height:1.8">
          <div><strong style="font-weight:700">신청</strong> · ${formatDateTime(active.requested_at)}</div>
          ${active.scheduled_date ? `<div><strong style="font-weight:700">예정일</strong> · ${esc(active.scheduled_date)}</div>`
                                  : `<div style="color:var(--muted)">받지 못한 보수가 있어 예정일이 아직 정해지지 않았습니다</div>`}
          ${active.reason_code ? `<div><strong style="font-weight:700">사유</strong> · ${esc(withdrawReasonLabel(active.reason_code))}</div>` : ''}
          ${active.reason_note ? `<div style="color:var(--muted);white-space:pre-wrap">${esc(active.reason_note)}</div>` : ''}
          ${active.uncancelled_count > 0 ? `<div style="color:#C62828"><strong style="font-weight:700">철회 못 한 응모 ${active.uncancelled_count}건</strong> — 손으로 확인이 필요합니다</div>` : ''}
          ${active.event_tickets_blocked_count > 0 ? `<div style="color:#C62828"><strong style="font-weight:700">정리 못 한 행사 예약 ${active.event_tickets_blocked_count}건</strong></div>` : ''}
        </div>
      </div>`;
    if (canProxy && isAdminMade) {
      html += `<button class="btn btn-ghost btn-xs" onclick="openWithdrawUndoModal()">되돌리기</button>
        <div style="font-size:11px;color:var(--muted);margin-top:6px">관리자가 넣은 신청만 되돌릴 수 있습니다. 본인이 신청한 건은 회원이 직접 취소합니다.</div>`;
    } else if (canProxy) {
      html += `<div style="font-size:11px;color:var(--muted)">회원이 직접 신청한 건입니다 — 취소도 회원이 앱에서 합니다.</div>`;
    }
  } else {
    const lines = withdrawBlockerLines(pre && pre.blockers);
    html += `<div style="font-size:13px;color:var(--muted);margin-bottom:${canProxy ? '12px' : '0'}">진행 중인 탈퇴 신청이 없습니다.</div>`;
    if (canProxy) {
      html += `<button class="btn btn-xs" style="background:#FB8C00;color:#fff;border:none" onclick="openWithdrawProxyModal()">회원 대신 탈퇴 신청</button>
        <div style="font-size:11px;color:var(--muted);margin-top:6px">회원이 직접 요청한 경우에만 사용하세요.</div>`;
      if (lines.length) {
        html += `<div style="margin-top:10px;font-size:11px;color:var(--muted)">이 회원은 처리 시 확인할 것이 ${lines.length}가지 있습니다 — 버튼을 누르면 자세히 보여드립니다.</div>`;
      }
    }
  }

  if (past.length) {
    html += `<div style="margin-top:14px;padding-top:12px;border-top:1px solid var(--line)">
      <div style="font-size:12px;font-weight:700;color:var(--ink);margin-bottom:8px">지난 기록 ${past.length}건</div>
      ${past.map(r => `<div style="font-size:11px;color:var(--muted);line-height:1.8">
        ${formatDateTime(r.requested_at)} · ${esc(withdrawStatusLabelKo(r.status))} · ${esc(withdrawKindLabelKo(r.requested_by_kind))}
        ${r.admin_cancel_note ? `<br><span style="color:var(--ink)">되돌림 사유</span> · ${esc(r.admin_cancel_note)}` : ''}
      </div>`).join('')}
    </div>`;
  }

  body.innerHTML = html;
}

// 탈퇴 사유 코드 → 한국어 라벨. 목록을 아직 안 받았으면 코드값 그대로 보여준다
// (없는 이름을 지어내지 않는다).
function withdrawReasonLabel(code) {
  const found = (_withdrawPanel.reasons || []).find(r => r.code === code);
  return found ? (found.name_ko || found.code) : code;
}

async function ensureWithdrawReasons() {
  if (_withdrawPanel.reasons) return _withdrawPanel.reasons;
  try {
    _withdrawPanel.reasons = await fetchLookups('withdraw_reason') || [];
  } catch (e) {
    console.error('[ensureWithdrawReasons]', e);
    _withdrawPanel.reasons = [];
  }
  return _withdrawPanel.reasons;
}

async function openWithdrawProxyModal() {
  const u = _currentDetailInfluencer;
  const pre = _withdrawPanel.precheck;
  if (!u || _withdrawPanel.influencerId !== u.id) { toast('회원 정보를 다시 불러와 주세요', 'error'); return; }

  $('wpTarget').textContent = `${u.name || '(이름 없음)'} · ${u.email || ''}`;
  $('wpNote').value = '';
  $('wpAck').checked = false;
  wpSyncSubmit();

  // 무슨 일이 일어나는지 — 서버가 준 숫자를 그대로 보여준다(화면이 다시 세지 않는다)
  const lines = withdrawBlockerLines(pre && pre.blockers);
  $('wpEffects').innerHTML = `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px 14px;background:#FAFAFA">
      <div style="font-size:12px;font-weight:700;color:var(--ink);margin-bottom:8px">접수하면 이렇게 됩니다</div>
      <div style="font-size:12px;color:var(--ink);line-height:1.8">
        <div>· 취소할 수 있는 응모가 <strong>모두 철회</strong>됩니다</div>
        <div>· 받을 보수가 없으면 <strong>5일 뒤 탈퇴가 확정</strong>됩니다</div>
        <div>· 회원은 그 전까지 앱에서 <strong>스스로 취소</strong>할 수 있습니다</div>
      </div>
      ${lines.length ? `<div style="margin-top:10px;padding-top:10px;border-top:1px dashed var(--line);font-size:12px;line-height:1.8">
        ${lines.map(l => `<div style="color:${l.warn ? '#C62828' : 'var(--ink)'}">· ${l.text}</div>`).join('')}
      </div>` : ''}
    </div>`;

  // 시행일 전 경고 — 서버가 준 is_open 만 본다
  //   ⚠️ `is_open === false` 만 보면 **조회 실패 폴백에는 그 칸이 없어** 경고가
  //     조용히 안 뜬다. 못 물어본 경우도 잠금 쪽으로 본다(fail-closed).
  $('wpLockWarn').innerHTML = (pre && (pre.is_open === false || pre.ok !== true))
    ? `<div style="border:1px solid #FFCDD2;background:#FFEBEE;border-radius:10px;padding:12px 14px;font-size:12px;color:#C62828;line-height:1.8">
         <strong style="font-weight:700">아직 약관 개정 시행 전입니다.</strong><br>
         회원이 직접 요청한 경우에만 처리하고, 무엇이 어떻게 되는지 먼저 안내해 주세요.
       </div>`
    : '';

  const reasons = await ensureWithdrawReasons();
  const sel = $('wpReasonCode');
  sel.innerHTML = '<option value="">선택 안 함</option>' +
    reasons.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko || r.code)}</option>`).join('');

  openModal('withdrawProxyModal');
}

// 근거 메모와 확인 체크가 둘 다 있어야 실행 버튼이 켜진다
function wpSyncSubmit() {
  const btn = $('wpSubmitBtn');
  if (!btn) return;
  const noteOk = ($('wpNote').value || '').trim().length > 0;
  const ackOk  = $('wpAck').checked;
  btn.disabled = !(noteOk && ackOk);
}

async function submitWithdrawProxy() {
  const u = _currentDetailInfluencer;
  if (!u) return;
  const btn = $('wpSubmitBtn');
  btn.disabled = true;

  // ⚠️ 이번에 여는 것은 대행뿐이다 — 강제(admin_forced)는 값만 있고 화면이 안 보낸다
  //    (되돌릴 수단이 없는 처리를 약관 개정 전에 열지 않는다, 2026-08-19 결정).
  const res = await requestWithdrawalForMember(
    u.id, 'admin_proxy', $('wpReasonCode').value || null, ($('wpNote').value || '').trim());

  if (!res || res.ok !== true) {
    btn.disabled = false;
    toast(withdrawProxyErrorKo(res), 'error');
    return;
  }

  closeModal('withdrawProxyModal');
  const parts = [`탈퇴 신청 접수 (${withdrawStatusLabelKo(res.status)})`];
  if (res.cancelled_count   > 0) parts.push(`응모 ${res.cancelled_count}건 철회`);
  if (res.uncancelled_count > 0) parts.push(`${res.uncancelled_count}건은 철회 못 함`);
  toast(parts.join(' · '), 'success');

  // 상세 모달은 닫지 않는다 — 방금 무슨 일이 일어났는지 카드에서 바로 보여준다
  await renderInfluencerWithdrawalPanel(u);
  await refreshPane('influencers');
}

// 실패 사유를 하나도 「알 수 없는 오류」로 뭉뚱그리지 않는다 — 화면이 원래 안 그렸어야
// 하는 상황(권한 없음·중복·겸직)이 여기 오면 그게 최종 방어선이 걸린 것이라, 무엇이
// 막았는지 그대로 알려 줘야 원인을 찾을 수 있다.
function withdrawProxyErrorKo(res) {
  const map = {
    not_authenticated:         '로그인이 풀렸습니다. 새로고침 후 다시 시도해 주세요',
    forbidden:                 '이 작업을 할 권한이 없습니다',
    invalid_kind:              '신청 종류가 잘못 전달됐습니다',
    reason_note_required:      '요청 근거를 적어 주세요',
    not_found:                 '회원을 찾을 수 없습니다',
    audit_account_blocked:     '감사용 계정은 탈퇴 대상이 아닙니다',
    admin_account_excluded:    '관리자 계정을 겸한 회원입니다 — 관리자 권한을 먼저 해제해야 합니다',
    already_requested:         '이미 진행 중인 탈퇴 신청이 있습니다',
    invalid_reason:            '선택한 사유가 더 이상 쓰이지 않습니다. 목록을 새로고침해 주세요',
    cancel_applications_failed:'응모 철회 중 문제가 생겨 접수하지 않았습니다',
    self_requested:            '회원이 직접 신청한 건은 관리자가 되돌릴 수 없습니다',
    note_required:             '되돌리는 이유를 적어 주세요'
  };
  if (res && res.reason && map[res.reason]) return map[res.reason];
  if (res && res.reason) return '처리하지 못했습니다 (' + res.reason + ')';
  return '처리하지 못했습니다: ' + ((res && res.error) || '알 수 없는 오류');
}

function openWithdrawUndoModal() {
  const u = _currentDetailInfluencer;
  if (!u) return;
  $('wuTarget').textContent = `${u.name || '(이름 없음)'} · ${u.email || ''}`;
  $('wuNote').value = '';
  wuSyncSubmit();
  openModal('withdrawUndoModal');
}

function wuSyncSubmit() {
  const btn = $('wuSubmitBtn');
  if (!btn) return;
  btn.disabled = ($('wuNote').value || '').trim().length === 0;
}

async function submitWithdrawUndo() {
  const u = _currentDetailInfluencer;
  if (!u) return;
  const btn = $('wuSubmitBtn');
  btn.disabled = true;

  const res = await cancelWithdrawalAdmin(u.id, ($('wuNote').value || '').trim());
  if (!res || res.ok !== true) {
    btn.disabled = false;
    toast(withdrawProxyErrorKo(res), 'error');
    return;
  }

  closeModal('withdrawUndoModal');
  toast('탈퇴 신청을 되돌렸습니다 · 철회된 응모는 되살아나지 않습니다', 'success');
  await renderInfluencerWithdrawalPanel(u);
  await refreshPane('influencers');
}

// 사유 코드 단건 조회 — blacklist/violation 양쪽 lookup 에서 검색
function findReasonByCode(code) {
  return (_blacklistReasonsCache||[]).find(x => x.code === code)
      || (_violationReasonsCache||[]).find(x => x.code === code)
      || null;
}

// 체크박스 옵션 — blacklist_reason 한 가지 세트만 사용 (violation_reason 은 과거 기록 호환용 폴백)
// 'other'(기타) 코드는 항상 맨 마지막에 배치
function mergedReasonList() {
  const list = (_blacklistReasonsCache || []);
  const nonOthers = list.filter(r => r.code !== 'other');
  const others = list.filter(r => r.code === 'other');
  return [...nonOthers, ...others];
}

// 콤마 구분 코드 문자열을 한국어 라벨로 변환 (복수 사유 지원)
function blacklistReasonLabel(codeStr) {
  if (!codeStr) return '';
  return codeStr.split(',').map(c => {
    const code = c.trim();
    const r = findReasonByCode(code);
    return r ? r.name_ko : code;
  }).filter(Boolean).join(', ');
}

var _currentFlagsCache = [];

async function renderInfluencerFlagsPanel(influencerId) {
  const body = $('infDetailFlagsBody');
  const count = $('infDetailFlagsCount');
  if (!body) return;
  const flags = await fetchInfluencerFlags(influencerId);
  _currentFlagsCache = flags;
  // evidence signed URL 일괄 생성
  const allPaths = [...new Set(flags.flatMap(f => f.evidence_paths || []))];
  const signedMap = {};
  await Promise.all(allPaths.map(async p => {
    try { signedMap[p] = await getFlagEvidenceSignedUrl(p); } catch {}
  }));
  if (count) count.textContent = `${flags.length}건`;
  if (!flags.length) {
    body.innerHTML = '<div style="padding:16px;text-align:center;color:var(--muted);font-size:12px">이력 없음</div>';
    return;
  }
  // 사유별 누적 건수 집계 (violation + blacklist 통합, 콤마 구분 코드 각각 카운트)
  const reasonCounts = {};
  flags.forEach(f => {
    if (!f.reason_code) return;
    f.reason_code.split(',').forEach(c => {
      const code = c.trim();
      if (!code) return;
      reasonCounts[code] = (reasonCounts[code] || 0) + 1;
    });
  });
  const pillEntries = Object.entries(reasonCounts).sort((a, b) => b[1] - a[1]);
  const pills = pillEntries.map(([code, n]) =>
    `<span style="display:inline-flex;align-items:center;gap:4px;background:#F5F5F5;color:#616161;font-size:11px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(blacklistReasonLabel(code))}<strong style="color:#424242;font-weight:700">${n}</strong></span>`
  ).join('');
  const summaryHtml = pills
    ? `<div style="padding:10px 16px;background:var(--bg);border-bottom:1px solid var(--line);display:flex;flex-wrap:wrap;gap:6px;align-items:center"><strong style="font-size:11px;color:var(--muted);font-weight:600;margin-right:4px">사유 누적</strong>${pills}</div>`
    : '';
  const actionLabel = {verify:'인증', unverify:'인증 해제', violation:'위반 기록', blacklist:'블랙 등록', unblacklist:'블랙 해제'};
  const actionColor = {verify:'#1565C0', unverify:'var(--muted)', violation:'#FB8C00', blacklist:'#C62828', unblacklist:'var(--green)'};
  body.innerHTML = summaryHtml + '<div style="padding:0">' + flags.map(f => {
    const editBtn = f.action === 'violation'
      ? `<button class="btn btn-ghost btn-xs" onclick="openEditViolationById('${esc(f.id)}')" title="수정" style="padding:2px 6px;margin-left:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">edit</span></button>`
      : '';
    const updatedLine = f.updated_at
      ? `<div style="font-size:10px;color:var(--muted);margin-top:2px">수정 ${esc(f.updated_by_name||'—')} · ${formatDateTime(f.updated_at)}</div>`
      : '';
    const thumbs = (f.evidence_paths || []).map(p => {
      const url = signedMap[p];
      if (!url) return '';
      return `<img src="${esc(url)}" alt="증빙" onclick="openImageLightbox('${esc(url)}')" style="width:40px;height:40px;object-fit:cover;border-radius:4px;cursor:pointer;border:1px solid var(--line)">`;
    }).filter(Boolean).join('');
    return `
    <div style="padding:10px 16px;border-bottom:1px solid var(--line);display:flex;gap:12px;align-items:flex-start">
      <div style="font-size:11px;font-weight:700;color:${actionColor[f.action]||'var(--muted)'};min-width:70px;padding-top:2px">${actionLabel[f.action]||esc(f.action)}</div>
      <div style="flex:1;min-width:0">
        ${f.reason_code?`<div style="font-size:12px;color:var(--ink)">${esc(blacklistReasonLabel(f.reason_code))}</div>`:''}
        ${f.note?`<div style="font-size:11px;color:var(--muted);white-space:pre-wrap;margin-top:2px">${esc(f.note)}</div>`:''}
        ${thumbs?`<div style="display:flex;flex-wrap:wrap;gap:4px;margin-top:6px">${thumbs}</div>`:''}
      </div>
      <div style="text-align:right;flex-shrink:0">
        <div style="font-size:11px;color:var(--muted)">${esc(f.set_by_name||'—')}</div>
        <div style="font-size:10px;color:var(--muted)">${f.set_at?formatDateTime(f.set_at):''}</div>
        ${updatedLine}
        ${editBtn}
      </div>
    </div>
    `;
  }).join('') + '</div>';
}

async function onInfluencerVerify() {
  if (!_currentDetailInfluencer) return;
  try {
    await setInfluencerVerified(_currentDetailInfluencer.id, true, null);
    toast('인증 처리되었습니다', 'success');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

async function onInfluencerUnverify() {
  if (!_currentDetailInfluencer) return;
  if (!confirm('인증을 해제할까요?')) return;
  try {
    await setInfluencerVerified(_currentDetailInfluencer.id, false, null);
    toast('인증이 해제되었습니다');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

// 위반 기록 편집 — _currentFlagsCache 에서 id로 찾아 모달 오픈
var _editingFlagId = null;

async function openEditViolationById(flagId) {
  const flag = (_currentFlagsCache || []).find(f => f.id === flagId);
  if (!flag) { toast('이력을 찾을 수 없습니다', 'error'); return; }
  if (flag.action !== 'violation') { toast('위반 기록만 수정 가능합니다', 'error'); return; }
  _editingFlagId = flagId;
  _editingKeptPaths = [...(flag.evidence_paths || [])];
  _editingNewFiles = [];
  _editingKeptUrlMap = {};
  // 기존 파일의 signed URL 미리 로드
  for (const p of _editingKeptPaths) {
    try { _editingKeptUrlMap[p] = await getFlagEvidenceSignedUrl(p); } catch {}
  }
  const selectedCodes = (flag.reason_code || '').split(',').map(c => c.trim()).filter(Boolean);
  const reasons = mergedReasonList();
  const checks = reasons.map(r =>
    `<label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;padding:3px 8px;border:1px solid var(--line);border-radius:4px;cursor:pointer"><input type="checkbox" class="fe-reason-cb" value="${esc(r.code)}"${selectedCodes.includes(r.code)?' checked':''}>${esc(r.name_ko)}</label>`
  ).join('');
  const body = $('flagEditBody');
  if (body) {
    body.innerHTML = `
      <div style="font-size:11px;color:var(--muted);margin-bottom:6px">사유 (1개 이상 선택)</div>
      <div style="display:flex;flex-wrap:wrap;gap:6px;margin-bottom:10px">${checks}</div>
      <textarea id="feNoteInput" class="form-input" rows="3" placeholder="자유 메모 (선택)" style="width:100%;font-size:12px;padding:8px;resize:vertical">${esc(flag.note||'')}</textarea>
      <div style="margin-top:10px">
        <label style="display:inline-flex;align-items:center;gap:4px;font-size:12px;color:var(--pink);cursor:pointer">
          <input type="file" accept="image/*,application/pdf" multiple onchange="onFlagFileInput(this,'editing')" style="display:none">
          <span class="material-icons-round notranslate" translate="no" style="font-size:14px">attach_file</span>
          <span>파일 첨부</span>
        </label>
        <div id="editFilePreview" style="display:flex;flex-wrap:wrap;gap:6px;margin-top:6px"></div>
      </div>
      <div style="display:flex;gap:8px;margin-top:14px;justify-content:flex-end">
        <button class="btn btn-ghost btn-xs" onclick="closeModal('influencerFlagEditModal')">취소</button>
        <button class="btn btn-primary btn-xs" onclick="onSaveEditViolation()">저장</button>
      </div>
    `;
  }
  openModal('influencerFlagEditModal');
  renderEditingFilePreview();
}

async function onSaveEditViolation() {
  if (!_editingFlagId) return;
  const modal = $('influencerFlagEditModal');
  const codes = [...(modal || document).querySelectorAll('.fe-reason-cb:checked')].map(cb => cb.value);
  const note = $('feNoteInput')?.value || '';
  if (codes.length === 0) { toast('사유를 1개 이상 선택해주세요', 'error'); return; }
  try {
    let finalPaths;
    if (_editingNewFiles.length > 0) {
      toast('첨부 파일 업로드 중...', 'info');
      const newPaths = await uploadAllFiles(_editingNewFiles, _editingFlagId);
      finalPaths = [..._editingKeptPaths, ...newPaths];
    } else {
      // 기존 수만 유지/감소. 원본 개수보다 줄었으면 교체, 같으면 미변경 처리
      const orig = ((_currentFlagsCache || []).find(f => f.id === _editingFlagId)?.evidence_paths) || [];
      if (_editingKeptPaths.length !== orig.length) finalPaths = _editingKeptPaths;
      else finalPaths = undefined; // 미변경
    }
    await updateInfluencerViolation(_editingFlagId, codes.join(','), note || null, finalPaths);
    toast('수정되었습니다', 'success');
    closeModal('influencerFlagEditModal');
    _editingFlagId = null;
    _editingKeptPaths = [];
    _editingNewFiles = [];
    _editingKeptUrlMap = {};
    if (_currentDetailInfluencer) await openInfluencerDetail(_currentDetailInfluencer.id);
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

// 신청 이력의 cancelled 보조 행에서 호출 — 위반 등록 폼에 자동 prefill
// payload = {id, cancel_reason, cancel_reason_code, cancel_phase, cancel_category_ko}
function prefillViolationFromCancel(payload) {
  if (!payload) return;
  const modal = $('influencerFullDetailModal');
  if (!modal) return;
  const cancelCode = 'cancel_after_purchase_start';
  const cancelLookup = (_violationReasonsCache || []).find(r => r.code === cancelCode);

  // 사유 체크박스 컨테이너 — reasonChecks 영역
  const cbContainer = modal.querySelector('.status-chip')?.parentElement;
  if (cbContainer) {
    // 모든 체크 해제
    cbContainer.querySelectorAll('input.bl-reason-cb').forEach(cb => { cb.checked = false; });
    // cancel_after_purchase_start 체크박스가 이미 있는지
    let cancelCb = cbContainer.querySelector('input.bl-reason-cb[value="' + cancelCode + '"]');
    if (!cancelCb && cancelLookup) {
      // 동적으로 맨 앞에 추가
      const wrapper = document.createElement('label');
      wrapper.className = 'status-chip';
      wrapper.innerHTML = `<input type="checkbox" class="bl-reason-cb" value="${esc(cancelLookup.code)}"><span>${esc(cancelLookup.name_ko)}</span>`;
      cbContainer.insertBefore(wrapper, cbContainer.firstChild);
      cancelCb = wrapper.querySelector('input.bl-reason-cb');
    }
    if (cancelCb) cancelCb.checked = true;
  }

  // 메모 prefill — 기존 값 비어 있을 때만 (사용자 입력 덮어쓰기 방지)
  const noteInput = $('blNoteInput');
  if (noteInput && !(noteInput.value || '').trim()) {
    const lines = ['[취소 사유]'];
    if (payload.cancel_category_ko) lines.push(`카테고리: ${payload.cancel_category_ko}`);
    if (payload.cancel_reason) lines.push(`보충: ${payload.cancel_reason}`);
    if (payload.cancel_phase) lines.push(`시점: ${cancelPhaseLabelKo(payload.cancel_phase)}`);
    noteInput.value = lines.join('\n');
  }

  // 상태 관리 영역으로 스크롤 + 메모 포커스
  const targetCard = $('infDetailStatusBody');
  if (targetCard) targetCard.scrollIntoView({behavior:'smooth', block:'start'});
  setTimeout(() => { noteInput?.focus(); }, 400);
  if (typeof toast === 'function') toast('위반 등록 폼에 사유·메모 prefill 됨', 'info');
}

async function onInfluencerRecordViolation() {
  if (!_currentDetailInfluencer) return;
  const modal = $('influencerFullDetailModal');
  const codes = [...(modal || document).querySelectorAll('.bl-reason-cb:checked')].map(cb => cb.value);
  const note = $('blNoteInput')?.value || '';
  if (codes.length === 0) { toast('위반 사유를 1개 이상 선택해주세요', 'error'); return; }
  try {
    let evidencePaths = null;
    if (_pendingFlagFiles.length > 0) {
      toast('첨부 파일 업로드 중...', 'info');
      const prefix = 'tmp/' + Date.now();
      evidencePaths = await uploadAllFiles(_pendingFlagFiles, prefix);
    }
    await recordInfluencerViolation(_currentDetailInfluencer.id, codes.join(','), note || null, evidencePaths);
    toast('위반 기록이 등록되었습니다', 'success');
    _pendingFlagFiles = [];
    _infViolationCounts[_currentDetailInfluencer.id] = (_infViolationCounts[_currentDetailInfluencer.id] || 0) + 1;
    rerenderInfluencersFromCache();
    await openInfluencerDetail(_currentDetailInfluencer.id);
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

async function onInfluencerBlacklist() {
  if (!_currentDetailInfluencer) return;
  const modal = $('influencerFullDetailModal');
  const codes = [...(modal || document).querySelectorAll('.bl-reason-cb:checked')].map(cb => cb.value);
  const note = $('blNoteInput')?.value || '';
  if (codes.length === 0) { toast('블랙리스트 사유를 1개 이상 선택해주세요', 'error'); return; }
  if (!confirm('블랙리스트에 등록할까요?')) return;
  try {
    await setInfluencerBlacklist(_currentDetailInfluencer.id, true, codes.join(','), note || null);
    toast('블랙리스트에 등록되었습니다', 'success');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

async function onInfluencerUnblacklist() {
  if (!_currentDetailInfluencer) return;
  if (!confirm('블랙리스트를 해제할까요?')) return;
  try {
    await setInfluencerBlacklist(_currentDetailInfluencer.id, false, null, null);
    toast('블랙리스트가 해제되었습니다');
    infUsersCache = null;
    _infViolationCounts = {};
    await openInfluencerDetail(_currentDetailInfluencer.id);
    await refreshPane('influencers');
  } catch(e) { toast('오류: ' + friendlyError(e.message || e), 'error'); }
}

// 인플루언서 이름 클릭 = 어디서든 풀 상세 모달(상태 관리·이력 포함)로 통일
async function openInfluencerModal(userId) {
  if (!userId) return;
  return openInfluencerDetail(userId);
}
