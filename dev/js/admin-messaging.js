// ════════════════════════════════════════════════════════════════════
// admin-messaging.js — 관리자 응모건 메시지 (PR 2)
//   사양서 docs/specs/2026-05-15-application-messaging.md §5-3, §5-4, §3-4, §3-5
//   - 받은편지함 3단 패널 (좌: 캠페인 / 중: 대화 상대 / 우: 대화 내용)
//   - 응모 행 「메시지」 버튼 → 메시지 모달 (신청관리·캠페인별 신청자·결과물 관리 공용)
//   - 답장 / 강제 숨김(campaign_admin+) / 복구(super_admin) / 수동 응대 완료(모든 관리자)
//   DB: storage.js (fetchApplicationMessages / sendApplicationMessage / markApplicationMessagesRead /
//        withdrawOwnMessage / markApplicationResolved / hideApplicationMessage /
//        unhideApplicationMessage / fetchAdminMessageThreads / fetchAdminMessageUnreadCounts /
//        fetchApplicationHideHistory / uploadMessageAttachment / getMessageAttachmentSignedUrl)
//   admin.js 핫스팟 회피용 분리 파일 (admin-brand.js 패턴). UI 텍스트는 한국어.
// ════════════════════════════════════════════════════════════════════

const ADM_MSG_WITHDRAW_LIMIT_MS = 25 * 60 * 1000;  // 본인(관리자) 회수 25분 (§3-5 ②)
const ADM_MSG_MAX_ATTACH = 5;                       // 메시지당 첨부 최대 5장 (§3-2)

// 받은편지함 상태
let _inboxThreads = [];                 // fetchAdminMessageThreads 결과 (뷰 행)
let _inboxUnreadMap = new Map();        // application_id → 본인 미열람 수
let _inboxSelectedCampaign = null;      // 좌 패널 선택 캠페인 id
let _inboxFilters = { unresolvedOnly: false, sinceMonths: 6, fromIso: null, toIso: null };  // fromIso/toIso = 달력 절대 기간
let _inboxSort = 'recent';              // 'recent'(최근 메시지순) | 'unresolved'(미응대 우선) | 'sent'(내가 보낸 순)
let _inboxSearch = '';                  // 받은편지함 검색어 (인플 이름·이메일·캠페인명·미리보기)
let _inboxSentAtMap = new Map();        // 'sent' 정렬용 — application_id → 본인 최신 발신 시각

// 메시지 모달/패널 공용 상태
let _admMsgAppId = null;                // 현재 열린 응모건
let _admMsgContext = 'modal';           // 'modal' | 'inbox' — 전송 후 재렌더 대상
let _admMsgPendingFiles = [];
let _admMsgSending = false;
let _admMsgCurrentMsgs = [];        // 현재 열린 대화 전체 메시지 (검색 필터 원본)
let _admMsgCurrentThreadId = null;  // 현재 렌더 중인 thread DOM id

// FAQ 응대 보조(PR B2·C) — 현재 열린 응모건의 FAQ 열람 이력. 직전 열람 칩에 재사용.
let _admMsgFaqInteractions = [];    // fetchFaqInteractionsForApp 결과 (시간순)

// 응모 행 메시지 버튼 셀에 표시할 본인 미열람 맵 (페인 로드 시 채움)
let _applicantMsgUnreadMap = new Map();

// 받은편지함 인플루언서 이름 맵 (influencer_id → 행). refreshInboxData 에서 채움
let _inboxInflMap = {};
// 받은편지함 최근 메시지 미리보기 맵 (application_id → {body, sender_kind, created_at})
let _inboxPreviewMap = new Map();

// 현재 super_admin 여부 (admin.js 의 currentAdminInfo 기준)
function admMsgIsSuper() {
  return (typeof currentAdminInfo !== 'undefined' && currentAdminInfo?.role === 'super_admin');
}

// 숨김 사유 카테고리 (message_hide_reason — fetchLookups 가 active 만 반환·캐시)
async function loadHideReasons() {
  try { return await fetchLookups('message_hide_reason'); }
  catch (e) { console.warn('[loadHideReasons]', e); return []; }
}

// ════════════════════════════════════════════════════════════════════
// 1. 받은편지함 3단 패널 (#adminPane-messages)
// ════════════════════════════════════════════════════════════════════
async function loadMessagesInbox() {
  _inboxSelectedCampaign = null;
  _inboxSearch = '';  // 페인 재진입 시 검색어 초기화 (정렬은 사용자 선택 유지)
  if (_admMsgContext === 'inbox') _admMsgAppId = null;
  applyBulkMsgButtonVisibility();   // 일괄 발송 버튼·발송이력 탭 권한 표시 (PR 3)
  switchInboxTab('inbox');          // 페인 진입 시 받은편지함 탭 기본
  const wrap = document.getElementById('inboxThreadView');
  if (wrap) wrap.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
  await refreshInboxData();
  updateInboxStage();
}

// 캠페인 영역 확장 — 헤더 클릭 시 캠페인·대화 선택 모두 해제 → updateInboxStage 가 stage-campaigns 로 전환.
//   (사용자: '캠페인 제목 영역 클릭하면 캠페인 영역이 넓어지게')
function setInboxStageCampaigns() {
  _inboxSelectedCampaign = null;
  _admMsgAppId = null;
  const v = document.getElementById('inboxThreadView');
  if (v) v.innerHTML = '';
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxStage();
}

// 대화 목록 영역 확장 — 대화 선택만 해제하고 캠페인 선택은 유지 → stage-threads (캠페인 선택 상태일 때만 의미).
function setInboxStageThreads() {
  _admMsgAppId = null;
  const v = document.getElementById('inboxThreadView');
  if (v) v.innerHTML = '';
  renderInboxThreadList();
  updateInboxStage();
}

// 단계 진행형 너비 — 선택 진척에 따라 활성 단을 넓힘 (메신저 드릴다운)
//   캠페인 미선택 → 캠페인 목록 전체폭 / 캠페인 선택 → 대화 상대 목록 확대 / 대화 선택 → 대화 내용 확대
function updateInboxStage() {
  const pane = document.querySelector('.inbox-3pane');
  if (!pane) return;
  pane.classList.remove('stage-campaigns', 'stage-threads', 'stage-view');
  const sentMode = _inboxSort === 'sent';
  pane.classList.toggle('inbox-flat', sentMode);   // 평면 모드 = 좌측 캠페인 영역 숨김(CSS)
  const threadOpen = _admMsgContext === 'inbox' && _admMsgAppId;
  if (sentMode) {
    // 「내가 보낸 순」: 좌측 숨김 → 대화 목록(중)을 넓게, 대화 열면 내용(우)
    pane.classList.add(threadOpen ? 'stage-view' : 'stage-threads');
  } else if (!_inboxSelectedCampaign) pane.classList.add('stage-campaigns');
  else if (!threadOpen) pane.classList.add('stage-threads');
  else pane.classList.add('stage-view');
}

// 뷰 + 본인 미열람 맵을 다시 조회하고 좌/중 패널 재렌더
async function refreshInboxData() {
  try {
    const [threads, unreadMap, sentMap] = await Promise.all([
      fetchAdminMessageThreads({ sinceMonths: _inboxFilters.sinceMonths, fromIso: _inboxFilters.fromIso, toIso: _inboxFilters.toIso }),
      fetchAdminMessageUnreadCounts(),
      (_inboxSort === 'sent') ? fetchAdminSentAtMap() : Promise.resolve(_inboxSentAtMap),
    ]);
    _inboxThreads = threads || [];
    _inboxUnreadMap = unreadMap || new Map();
    _inboxSentAtMap = sentMap || new Map();
    // 인플루언서 이름·최근 메시지 미리보기 보강 (병렬)
    const inflIds = [...new Set(_inboxThreads.map(t => t.influencer_id).filter(Boolean))];
    const appIds = [...new Set(_inboxThreads.map(t => t.application_id).filter(Boolean))];
    const [inflMap, prevMap] = await Promise.all([
      inflIds.length ? fetchInfluencersByIds(inflIds) : Promise.resolve({}),
      appIds.length ? fetchMessagePreviews(appIds) : Promise.resolve(new Map()),
    ]);
    _inboxInflMap = inflMap; _inboxPreviewMap = prevMap;
    // 캠페인 캐시 보강 — 메시지 탭 단독 진입·새로고침 시 전역 allCampaigns 가 비어
    // 캠페인명이 '(캠페인)'으로 떨어지는 문제 방지. 스레드의 campaign_id 중 캐시에
    // 없는 게 하나라도 있으면(빈 캐시·신규 캠페인 누락) 1회 재로드.
    const needCampaignCache = _inboxThreads.some(t => t.campaign_id && !inboxCampaignById(t.campaign_id));
    if (needCampaignCache) allCampaigns = await fetchCampaigns();
  } catch (e) {
    console.error('[refreshInboxData]', e);
    _inboxThreads = []; _inboxUnreadMap = new Map(); _inboxInflMap = {}; _inboxPreviewMap = new Map();
  }
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxSidebarBadge();
}

// 사이드바 「메시지」 미응대 배지 = 우리 팀 미응대 응모건 수 (그룹 공통)
function updateInboxSidebarBadge() {
  const badge = document.getElementById('navMsgBadge');
  if (!badge) return;
  const n = _inboxThreads.filter(t => t.unresolved_for_admin_team).length;
  if (n > 0) { badge.textContent = n > 99 ? '99+' : String(n); badge.style.display = ''; }
  else { badge.style.display = 'none'; }
}

// 좌: 캠페인 목록 (메시지 있는 응모건을 campaign_id 로 그룹 + 미응대 합계)
function renderInboxCampaignList() {
  const el = document.getElementById('inboxCampaigns');
  if (!el) return;
  // 「내가 보낸 순」은 캠페인 무관 전체 평면이라 좌측 캠페인 선택이 무의미 → 흐리게 + 안내
  if (_inboxSort === 'sent') {
    el.classList.add('inbox-camp-disabled');
    el.innerHTML = '<div class="inbox-empty">전체 대화에서 「내가 보낸 순」으로 표시 중입니다.<br>다른 정렬로 바꾸면 캠페인별 보기로 돌아갑니다.</div>';
    return;
  }
  el.classList.remove('inbox-camp-disabled');
  // campaign_id 별 집계 (미응대만·검색 필터 적용된 목록 기준)
  const byCamp = new Map();
  for (const t of filteredInboxThreads()) {
    let g = byCamp.get(t.campaign_id);
    if (!g) { g = { campaign_id: t.campaign_id, total: 0, unresolved: 0, lastAt: t.last_message_at }; byCamp.set(t.campaign_id, g); }
    g.total += 1;
    if (t.unresolved_for_admin_team) g.unresolved += 1;
    if (t.last_message_at > g.lastAt) g.lastAt = t.last_message_at;
  }
  const groups = Array.from(byCamp.values());
  if (_inboxSort === 'unresolved') {
    groups.sort((a, b) => (b.unresolved - a.unresolved) || (b.lastAt || '').localeCompare(a.lastAt || ''));
  } else {
    groups.sort((a, b) => (b.lastAt || '').localeCompare(a.lastAt || ''));
  }
  if (!groups.length) {
    el.innerHTML = '<div class="inbox-empty">표시할 대화가 없습니다.</div>';
    return;
  }
  el.innerHTML = groups.map(g => {
    const c = inboxCampaignById(g.campaign_id);
    const title = c ? (c.title || '(제목 없음)') : '(캠페인)';
    const active = g.campaign_id === _inboxSelectedCampaign ? 'active' : '';
    const badge = g.unresolved > 0 ? `<span class="inbox-camp-badge">미응대 ${g.unresolved}건</span>` : '';
    // 모집타입 배지(공통 헬퍼) + 캠페인 상태 배지(캠페인 전용 — 신청 상태와 라벨 다름)
    const typeBadge = (c && typeof getRecruitTypeBadgeKoSm === 'function') ? getRecruitTypeBadgeKoSm(c.recruit_type) : '';
    const statusBadge = c ? inboxCampStatusBadge(c.status) : '';
    // 브랜드 · 모집인원
    const brand = c ? esc(c.brand_ko || c.brand || '') : '';
    const slots = (c && c.slots) ? `모집 ${c.slots}명` : '';
    const sub = [brand, slots].filter(Boolean).join(' · ');
    return `<button type="button" class="inbox-camp-item ${active}" onclick="selectInboxCampaign('${esc(g.campaign_id)}')">
      <span class="inbox-camp-main">
        <span class="inbox-camp-badges">${typeBadge}${statusBadge}</span>
        <span class="inbox-camp-title">${esc(title)}</span>
        ${sub ? `<span class="inbox-camp-sub">${sub}</span>` : ''}
        <span class="inbox-camp-meta">대화 ${g.total}건</span>
      </span>
      <span class="inbox-camp-right">${badge}</span>
    </button>`;
  }).join('');
}

function selectInboxCampaign(campaignId) {
  _inboxSelectedCampaign = campaignId;
  // 캠페인 전환 시 우측 대화 초기화 (단계 = 대화 상대 선택)
  if (_admMsgContext === 'inbox') _admMsgAppId = null;
  const view = document.getElementById('inboxThreadView');
  if (view) view.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxStage();
}

// 중: 대화 상대 목록. 기본은 선택 캠페인의 대화 / 「내가 보낸 순」은 캠페인 무관 전체(본인 발신 대화만)
function renderInboxThreadList() {
  const el = document.getElementById('inboxThreads');
  if (!el) return;
  const sentMode = _inboxSort === 'sent';
  let list;
  if (sentMode) {
    // 캠페인 무관 전체에서 본인이 발신한 적 있는 대화만, 본인 마지막 발신 시각 내림차순
    list = filteredInboxThreads().filter(t => _inboxSentAtMap.has(t.application_id));
    list.sort((a, b) => (_inboxSentAtMap.get(b.application_id) || '').localeCompare(_inboxSentAtMap.get(a.application_id) || ''));
    if (!list.length) { el.innerHTML = '<div class="inbox-empty">아직 보낸 대화가 없습니다.</div>'; return; }
  } else {
    if (!_inboxSelectedCampaign) { el.innerHTML = '<div class="inbox-empty">왼쪽에서 캠페인을 선택하세요.</div>'; return; }
    list = filteredInboxThreads().filter(t => t.campaign_id === _inboxSelectedCampaign);
    if (_inboxSort === 'unresolved') {
      list.sort((a, b) => (Number(b.unresolved_for_admin_team) - Number(a.unresolved_for_admin_team))
        || (b.last_message_at || '').localeCompare(a.last_message_at || ''));
    } else {
      list.sort((a, b) => (b.last_message_at || '').localeCompare(a.last_message_at || ''));
    }
    if (!list.length) { el.innerHTML = '<div class="inbox-empty">대화가 없습니다.</div>'; return; }
  }
  el.innerHTML = list.map(t => {
    const inf = (_inboxInflMap && _inboxInflMap[t.influencer_id]) || {};
    const kanji = esc(inf.name || '(이름 없음)');           // 한자 이름
    const kana = inf.name_kana ? esc(inf.name_kana) : '';   // 가나 이름
    const email = inf.email ? esc(inf.email) : '';
    const unread = _inboxUnreadMap.get(t.application_id) || 0;
    const active = t.application_id === _admMsgAppId ? 'active' : '';
    const unresolved = t.unresolved_for_admin_team
      ? '<span class="inbox-thread-chip unresolved">미응대</span>' : '';
    const unreadChip = unread > 0
      ? `<span class="inbox-thread-chip unread">${unread > 99 ? '99+' : unread}</span>` : '';
    // 최근 메시지 미리보기 (한 줄)
    const prev = _inboxPreviewMap.get(t.application_id);
    let previewHtml = '';
    if (prev) {
      const who = prev.sender_kind === 'admin' ? '운영팀: ' : '';
      const body = (prev.body || '').replace(/\s+/g, ' ').trim();
      previewHtml = `<span class="inbox-thread-preview">${esc(who + (body || '(이미지)'))}</span>`;
    }
    // 「내가 보낸 순」은 캠페인 무관 평면이라 카드에 캠페인명·브랜드 라벨 + 시각=본인 발신 시각
    let campLabel = '';
    let timeVal = t.last_message_at;
    if (sentMode) {
      const c = inboxCampaignById(t.campaign_id);
      const ct = c ? (c.title || '(제목 없음)') : '(캠페인)';
      const cb = c ? (c.brand_ko || c.brand || '') : '';
      campLabel = `<span class="inbox-thread-camp">${esc(ct)}${cb ? ` · ${esc(cb)}` : ''}</span>`;
      timeVal = _inboxSentAtMap.get(t.application_id) || t.last_message_at;
    }
    return `<button type="button" class="inbox-thread-item ${active}" onclick="openInboxThread('${esc(t.application_id)}')">
      <span class="inbox-thread-main">
        ${campLabel}
        <span class="inbox-thread-name">${kanji}${kana ? `<span class="inbox-thread-kana">${kana}</span>` : ''}</span>
        ${email ? `<span class="inbox-thread-email">${email}</span>` : ''}
        ${previewHtml}
      </span>
      <span class="inbox-thread-right">
        <span class="inbox-thread-time">${esc(formatDateTime(timeVal))}</span>
        <span class="inbox-thread-chips">${unresolved}${unreadChip}</span>
      </span>
    </button>`;
  }).join('');
}

// 우: 선택 응모건 대화 내용 (인라인 패널)
async function openInboxThread(applicationId) {
  _admMsgAppId = applicationId;
  _admMsgContext = 'inbox';
  _admMsgPendingFiles = [];
  updateInboxStage();        // 대화 내용 단(우측) 펼침
  renderInboxThreadList();  // active 표시 갱신
  const view = document.getElementById('inboxThreadView');
  if (view) view.innerHTML = '<div class="inbox-empty">불러오는 중…</div>';
  try {
    const msgs = await fetchApplicationMessages(applicationId);
    // 진입 시 이미 응대 완료된 건이면 버튼을 「완료됨」으로 렌더
    const thread = _inboxThreads.find(t => t.application_id === applicationId);
    const isResolved = !!thread && !thread.unresolved_for_admin_team;
    if (view) view.innerHTML = adminThreadViewHtml('inbox', isResolved);
    await loadThreadFaqContext(applicationId, 'inbox', thread?.campaign_id);
    renderAdminMsgThread('inboxMsgThread', msgs);
    await markApplicationMessagesRead(applicationId);
    // 본인 미열람 맵 갱신 후 중 패널 재렌더
    _inboxUnreadMap = await fetchAdminMessageUnreadCounts();
    renderInboxThreadList();
  } catch (e) {
    console.error('[openInboxThread]', e);
    if (view) view.innerHTML = '<div class="inbox-empty">메시지를 불러오지 못했습니다.</div>';
  }
}

// 받은편지함 필터 토글
function toggleInboxUnresolved(checked) {
  _inboxFilters.unresolvedOnly = !!checked;
  renderInboxCampaignList();
  renderInboxThreadList();
}
function changeInboxSince(v) {
  const custom = document.getElementById('inboxCustomRange');
  if (v === 'custom') {
    // 「직접 선택」 → 날짜 입력칸 노출. 실제 적용은 날짜 입력 시 applyInboxCustomRange
    if (custom) custom.style.display = '';
    return;
  }
  if (custom) custom.style.display = 'none';
  _inboxFilters.sinceMonths = Number(v) || 6;
  _inboxFilters.fromIso = null; _inboxFilters.toIso = null;   // 상대 기간으로 복귀
  refreshInboxData();
}
// 「직접 선택」 날짜 입력 적용 — 시작 00:00 ~ 종료 23:59 (한쪽만 입력해도 단방향 적용)
function applyInboxCustomRange() {
  const f = document.getElementById('inboxDateFrom')?.value;
  const t = document.getElementById('inboxDateTo')?.value;
  _inboxFilters.fromIso = f ? new Date(f + 'T00:00:00').toISOString() : null;
  _inboxFilters.toIso = t ? new Date(t + 'T23:59:59').toISOString() : null;
  refreshInboxData();
}
function changeInboxSort(v) {
  _inboxSort = (v === 'unresolved') ? 'unresolved' : (v === 'sent') ? 'sent' : 'recent';
  // 「내가 보낸 순」 진입 시 본인 발신 시각 맵을 로드해야 하므로 재조회. 그 외는 재렌더만.
  if (_inboxSort === 'sent') {
    _inboxSelectedCampaign = null;          // 평면 모드 — 캠페인 선택 해제
    if (_admMsgContext === 'inbox') _admMsgAppId = null;
    const view = document.getElementById('inboxThreadView');
    if (view) view.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
    updateInboxStage();
    refreshInboxData();
  } else {
    renderInboxCampaignList();
    renderInboxThreadList();
    updateInboxStage();   // 평면 모드(inbox-flat) 해제 → 좌측 캠페인 영역 복귀
  }
}

// 받은편지함 검색 — 인플 이름·이메일·캠페인명으로 대화 목록 필터
//   (대화 내용 검색은 대화창 상단 검색창에서 — 여기는 목록 찾기 전용)
function searchInbox(query) {
  _inboxSearch = (query || '').trim().toLowerCase();
  renderInboxCampaignList();
  renderInboxThreadList();
}
// 미응대만·검색어를 적용한 대화 목록 (캠페인/대화 렌더 공통)
function filteredInboxThreads() {
  let list = _inboxThreads;
  if (_inboxFilters.unresolvedOnly) list = list.filter(t => t.unresolved_for_admin_team);
  if (_inboxSearch) {
    list = list.filter(t => {
      const inf = (_inboxInflMap && _inboxInflMap[t.influencer_id]) || {};
      const camp = inboxCampaignById(t.campaign_id);
      const bag = [inf.name, inf.name_kana, inf.email, camp && camp.title, camp && (camp.brand_ko || camp.brand)]
        .filter(Boolean).join(' ').toLowerCase();
      return bag.includes(_inboxSearch);
    });
  }
  return list;
}

// ════════════════════════════════════════════════════════════════════
// 2. 메시지 모달 (응모 행 버튼 진입)
// ════════════════════════════════════════════════════════════════════
async function openAdminMessageModal(applicationId, campaignId) {
  if (!applicationId) return;
  _admMsgAppId = applicationId;
  _admMsgContext = 'modal';
  _admMsgPendingFiles = [];
  const m = document.getElementById('admMsgModal');
  if (!m) return;
  const titleEl = document.getElementById('admMsgModalTitle');
  if (titleEl) titleEl.textContent = `${campaignTitleById(campaignId)} — 메시지`;
  const body = document.getElementById('admMsgModalBody');
  // 받은편지함을 거쳐 로드된 thread 가 있으면 응대 상태로 버튼 초기화 (없으면 활성, 클릭 시 전환)
  const modalThread = _inboxThreads.find(t => t.application_id === applicationId);
  const modalResolved = !!modalThread && !modalThread.unresolved_for_admin_team;
  if (body) body.innerHTML = adminThreadViewHtml('modal', modalResolved);
  openModal('admMsgModal');
  const thread = document.getElementById('admMsgThread');
  if (thread) thread.innerHTML = '<div class="msg-empty">불러오는 중…</div>';
  try {
    await loadThreadFaqContext(applicationId, 'modal', campaignId);
    const msgs = await fetchApplicationMessages(applicationId);
    renderAdminMsgThread('admMsgThread', msgs);
    await markApplicationMessagesRead(applicationId);
    _applicantMsgUnreadMap.set(applicationId, 0);
    updateApplicantMsgBadge(applicationId);
  } catch (e) {
    console.error('[openAdminMessageModal]', e);
    if (thread) thread.innerHTML = '<div class="msg-empty">메시지를 불러오지 못했습니다.</div>';
  }
}

function closeAdminMessageModal() {
  closeModal('admMsgModal');
  _admMsgPendingFiles = [];
  if (_admMsgContext === 'modal') _admMsgAppId = null;
}

// 대화 내용 컨테이너 HTML (받은편지함 우측 / 모달 본문 공용)
//   ctx: 'inbox' | 'modal' — thread/composer DOM id 접두사 결정
function adminThreadViewHtml(ctx, isResolved = false) {
  const threadId = ctx === 'inbox' ? 'inboxMsgThread' : 'admMsgThread';
  const composerId = ctx === 'inbox' ? 'inboxComposer' : 'admComposer';
  const histId = ctx === 'inbox' ? 'inboxHideHist' : 'admHideHist';
  const statusId = ctx === 'inbox' ? 'inboxStatusLine' : 'admStatusLine';
  const faqHistId = ctx === 'inbox' ? 'inboxFaqHist' : 'admFaqHist';
  const histBtn = admMsgIsSuper()
    ? `<button type="button" class="adm-msg-bar-btn" onclick="toggleHideHistory('${ctx}')">숨김 이력</button>` : '';
  const faqBtn = `<button type="button" class="adm-msg-bar-btn" onclick="toggleFaqHistory('${ctx}')">FAQ 열람 이력</button>`;
  // 응대 완료 상태면 버튼을 「완료됨」 비활성으로 렌더 (진입 시 + 클릭 후 즉시 반영 공용)
  const resolveBtn = isResolved
    ? `<button type="button" id="${ctx}ResolveBtn" class="adm-msg-bar-btn done" disabled>응대 완료됨</button>`
    : `<button type="button" id="${ctx}ResolveBtn" class="adm-msg-bar-btn primary" onclick="markCurrentResolved()">응대 완료</button>`;
  return `
    <div class="adm-msg-statusline" id="${statusId}" style="display:none"></div>
    <div class="adm-msg-faq-history" id="${faqHistId}" style="display:none"></div>
    <div class="adm-msg-actionbar">
      <input type="search" class="adm-msg-search" placeholder="대화 내용 검색" oninput="searchAdminMsg(this.value)">
      <span class="adm-msg-bar-spacer"></span>
      ${faqBtn}
      ${resolveBtn}
      ${histBtn}
    </div>
    <div class="adm-msg-thread" id="${threadId}"></div>
    <div class="adm-msg-hide-history" id="${histId}" style="display:none"></div>
    <div class="adm-msg-composer" id="${composerId}">
      <div class="adm-msg-attach-preview" id="${composerId}Preview"></div>
      <div class="adm-msg-composer-row">
        <label class="adm-msg-attach-btn" title="이미지 첨부">
          <span class="material-icons-round notranslate" translate="no">image</span>
          <input type="file" accept="image/*" multiple style="display:none" onchange="onAdmMsgAttachSelected(this)">
        </label>
        <textarea class="adm-msg-input" id="${composerId}Input" rows="2" placeholder="답장 입력…"></textarea>
        <button type="button" class="btn btn-primary adm-msg-send" onclick="sendAdminMessage()">전송</button>
      </div>
    </div>`;
}

// 숨김 이력 패널 토글 (super_admin) — 응모건 단위 audit
async function toggleHideHistory(ctx) {
  const histId = ctx === 'inbox' ? 'inboxHideHist' : 'admHideHist';
  const el = document.getElementById(histId);
  if (!el || !_admMsgAppId) return;
  if (el.style.display !== 'none') { el.style.display = 'none'; return; }
  el.style.display = '';
  el.innerHTML = '<div class="msg-empty">불러오는 중…</div>';
  try {
    const rows = await fetchApplicationHideHistory(_admMsgAppId);
    if (!rows.length) { el.innerHTML = '<div class="adm-hide-hist-empty">숨김/복구 이력이 없습니다.</div>'; return; }
    el.innerHTML = '<div class="adm-hide-hist-title">숨김/복구 이력</div>' + rows.map(r => {
      const act = r.action === 'hide' ? '숨김' : '복구';
      const reason = r.reason_code ? ` · ${esc(r.reason_code)}` : '';
      const memo = r.reason_memo ? ` · ${esc(r.reason_memo)}` : '';
      return `<div class="adm-hide-hist-row"><b>${act}</b> ${esc(r.by_name || '')} · ${esc(formatDate(r.at))}${reason}${memo}</div>`;
    }).join('');
  } catch (e) {
    console.error('[toggleHideHistory]', e);
    el.innerHTML = '<div class="adm-hide-hist-empty">이력을 불러오지 못했습니다.</div>';
  }
}

// ════════════════════════════════════════════════════════════════════
// 2-1. FAQ 응대 보조 (PR B2 응모건 상태 한 줄 §3-1 / PR C FAQ 열람 이력 §3-2)
// ════════════════════════════════════════════════════════════════════

// 스레드 진입 시 상태 한 줄 + FAQ 열람 이력 데이터를 함께 로드.
//   상태 한 줄은 즉시 렌더, FAQ 열람 이력은 데이터만 보관(패널 펼칠 때·직전 열람 칩에 사용).
async function loadThreadFaqContext(applicationId, ctx, campaignId) {
  _admMsgFaqInteractions = [];
  // 직전 응모건의 상태/이력 컨테이너 초기화 (잔상 방지)
  const statusEl = document.getElementById(ctx === 'inbox' ? 'inboxStatusLine' : 'admStatusLine');
  const histEl = document.getElementById(ctx === 'inbox' ? 'inboxFaqHist' : 'admFaqHist');
  if (statusEl) { statusEl.style.display = 'none'; statusEl.innerHTML = ''; }
  if (histEl) { histEl.style.display = 'none'; histEl.innerHTML = ''; }
  try {
    const [bundle, interactions] = await Promise.all([
      fetchApplicationStatusBundle(applicationId),
      fetchFaqInteractionsForApp(applicationId),
    ]);
    _admMsgFaqInteractions = interactions || [];
    renderAdmStatusLine(ctx, bundle, campaignId);
  } catch (e) {
    console.error('[loadThreadFaqContext]', e);
  }
}

// 응모건 상태 한 줄(§3-1) — 인플 측 faqComputeStatus 와 동일 판정 → 한국어 문구.
//   캠페인 타입(리뷰어=영수증 / 무료제공·방문형=게시물 URL) + 현재 단계 + 결과물 제출 여부.
function renderAdmStatusLine(ctx, bundle, campaignId) {
  const el = document.getElementById(ctx === 'inbox' ? 'inboxStatusLine' : 'admStatusLine');
  if (!el) return;
  if (!bundle) { el.style.display = 'none'; el.innerHTML = ''; return; }
  const camp = inboxCampaignById(campaignId);
  const delivs = bundle.delivs || [];
  // 인플 측과 동일 순수 판정 (shared.js)
  const { key } = faqComputeStatus(bundle.status, delivs, camp);

  // 한국어 상태 문구 (i18n statusLine.* ko). t() 는 현재 인플 로케일 기준이라
  // 관리자 화면은 항상 한국어가 필요 → ko 사전을 직접 조회.
  const text = admStatusLineKo(key, camp);

  // 캠페인 모집 타입 라벨 (리뷰어=영수증 / 무료제공·방문형=게시물 URL)
  const rt = camp?.recruit_type;
  let typeText = '';
  if (rt === 'monitor') typeText = '리뷰어 · 영수증 제출형';
  else if (rt === 'gifting') typeText = '기프팅 · 게시물 URL 제출형';
  else if (rt === 'visit') typeText = '방문형 · 게시물 URL 제출형';
  const typeBadge = (typeof getRecruitTypeBadgeKoSm === 'function') ? getRecruitTypeBadgeKoSm(rt) : '';

  // 결과물 제출 여부
  const submitted = delivs.length > 0;
  const submitText = submitted ? `결과물 제출됨 (${delivs.length}건)` : '결과물 미제출';

  el.innerHTML = `
    <div class="adm-msg-status-head">${typeBadge}<span class="adm-msg-status-type">${esc(typeText)}</span></div>
    <div class="adm-msg-status-main">${esc(text)}</div>
    <div class="adm-msg-status-sub">${esc(submitText)}</div>`;
  el.style.display = '';
}

// 상태 한 줄 한국어 문구 (관리자 화면 전용 — i18n 사전은 인플 빌드에만 있으므로 로컬 정의).
//   인플 측 i18n ko.js messaging.statusLine 값과 동일하게 유지(동일 결과 §3-1).
const ADM_STATUS_LINE_KO = {
  pending: '현재 심사 중입니다. 결과는 별도로 안내드립니다.',
  approved_purchase_before: '당첨되셨습니다. 곧 구매 안내가 시작됩니다.',
  receipt: '상품 구매 후 영수증을 제출해 주세요 (제출 기한 {date}).',
  visit: '방문 후 게시물을 제출해 주세요.',
  post_deadline: '결과물 제출 기한: {date}',
  post_overdue: '제출 기한이 지났습니다.',
  reviewing: '제출하신 결과물을 확인 중입니다.',
  partial_reject: '일부 결과물이 반려되었습니다. 반려된 항목을 확인 후 재제출해 주세요.',
  all_reject: '결과물이 반려되었습니다. 사유를 확인 후 재제출해 주세요.',
  done: '모든 미션이 완료되었습니다. 감사합니다.',
  rejected: '이번에는 인연이 없었습니다.',
  cancelled: '취소된 응모입니다.',
  approved_fallback: '당첨 후 각 단계는 응모이력에서 확인할 수 있습니다.',
  fallback: '응모 상태는 응모이력에서 확인할 수 있습니다.',
};

// statusLine 한국어 문구 — 관리자 화면은 항상 한국어.
//   {date} 치환은 인플 측과 동일(영수증=구매/제출 마감, 제출기한=제출 마감).
function admStatusLineKo(key, camp) {
  const text = ADM_STATUS_LINE_KO[key] || '';
  if (!text) return '';
  let mmdd = '';
  if (key === 'receipt') mmdd = _admMMDD(camp?.purchase_end || camp?.submission_end);
  else if (key === 'post_deadline') mmdd = _admMMDD(camp?.submission_end);
  return text.replace('{date}', mmdd);
}

function _admMMDD(d) {
  const ms = Date.parse(d || '');
  if (isNaN(ms)) return '';
  const dt = new Date(ms);
  return `${String(dt.getMonth() + 1).padStart(2, '0')}/${String(dt.getDate()).padStart(2, '0')}`;
}

// FAQ 열람 이력 패널 토글(§3-2) — 시간순 「언제 / 질문 제목 / 받은 답변 요약 / 결과」.
//   viewed 는 질문당 1줄(횟수·마지막 시각), handoff 는 발생마다 표시.
function toggleFaqHistory(ctx) {
  const el = document.getElementById(ctx === 'inbox' ? 'inboxFaqHist' : 'admFaqHist');
  if (!el) return;
  if (el.style.display !== 'none') { el.style.display = 'none'; return; }
  el.style.display = '';
  renderAdmFaqHistory(el);
}

// FAQ 열람 이력 렌더 (관리자 화면 — 한국어 label_ko/body_ko)
function renderAdmFaqHistory(el) {
  const rows = _admMsgFaqInteractions || [];
  if (!rows.length) {
    el.innerHTML = '<div class="adm-faq-hist-empty">FAQ 열람 이력이 없습니다.</div>';
    return;
  }
  const ACTION = {
    viewed:   { label: '봤음',     cls: 'viewed' },
    resolved: { label: '해결됨',   cls: 'resolved' },
    handoff:  { label: '직접 문의', cls: 'handoff' },
  };
  const body = rows.map(r => {
    const a = ACTION[r.action] || { label: esc(r.action), cls: '' };
    const when = formatDateTime(r.last_viewed_at || r.created_at);
    const title = r.label_ko ? esc(r.label_ko) : '(삭제된 질문)';
    // 답변 요약 — 첫 줄 또는 60자 컷
    let summary = '';
    if (r.body_ko) {
      const firstLine = String(r.body_ko).split('\n').find(s => s.trim()) || '';
      summary = firstLine.length > 60 ? firstLine.slice(0, 60) + '…' : firstLine;
    }
    const cnt = (r.action === 'viewed' && r.view_count > 1) ? ` <span class="adm-faq-hist-cnt">×${r.view_count}</span>` : '';
    return `<div class="adm-faq-hist-row">
      <div class="adm-faq-hist-line1"><span class="adm-faq-hist-when">${esc(when)}</span><span class="adm-faq-hist-act ${a.cls}">${esc(a.label)}</span></div>
      <div class="adm-faq-hist-q">${title}${cnt}</div>
      ${summary ? `<div class="adm-faq-hist-a">${esc(summary)}</div>` : ''}
    </div>`;
  }).join('');
  el.innerHTML = `<div class="adm-faq-hist-title">FAQ 열람 이력 <span class="adm-faq-hist-note">(현재 등록된 답변 기준)</span></div>${body}`;
}

// 직전 열람 컨텍스트 칩(§3-2) — 직접 문의로 넘어오기 전 마지막 handoff 의 질문 제목.
//   인플루언서 첫 메시지 말풍선 위에 1회만 노출. 질문 제목 없는 handoff(노드 삭제) 는 칩 생략.
function admLastViewedChipHtml() {
  const rows = _admMsgFaqInteractions || [];
  // handoff 중 질문 제목이 있는 가장 마지막 건
  const handoffs = rows.filter(r => r.action === 'handoff' && r.label_ko);
  if (!handoffs.length) return '';
  const last = handoffs[handoffs.length - 1];
  return `<div class="adm-faq-chip"><span class="material-icons-round notranslate" translate="no">history</span>직전 열람: ${esc(last.label_ko)}</div>`;
}

// ════════════════════════════════════════════════════════════════════
// 3. 스레드 렌더 (공용 — 받은편지함 우측·모달 모두)
// ════════════════════════════════════════════════════════════════════
function renderAdminMsgThread(threadElId, messages, _isSearchResult) {
  // 검색 결과 렌더가 아니면 전체 메시지를 보관(검색 필터 원본) + 현재 thread 추적
  if (!_isSearchResult) {
    _admMsgCurrentMsgs = messages || [];
    _admMsgCurrentThreadId = threadElId;
  }
  const thread = document.getElementById(threadElId);
  if (!thread) return;
  if (!messages || !messages.length) {
    thread.innerHTML = `<div class="msg-empty">${_isSearchResult ? '검색 결과가 없습니다.' : '아직 메시지가 없습니다.'}</div>`;
    return;
  }
  const now = Date.now();
  const isSuper = admMsgIsSuper();
  // 직전 열람 칩(§3-2)은 검색 결과가 아닐 때 첫 인플루언서 메시지 위에 1회만.
  const chipHtml = _isSearchResult ? '' : admLastViewedChipHtml();
  const firstInflIdx = chipHtml ? messages.findIndex(m => m.sender_kind === 'influencer') : -1;
  thread.innerHTML = messages.map((msg, idx) => {
    const lastViewedChip = (chipHtml && idx === firstInflIdx) ? chipHtml : '';
    const fromAdmin = msg.sender_kind === 'admin';
    const senderLabel = fromAdmin ? `운영팀 (${esc(msg.sender_name || '')})` : esc(msg.sender_name || '인플루언서');
    const timeStr = formatDateTime(msg.created_at);
    const sideCls = fromAdmin ? 'mine' : '';

    // 인플루언서 본인 회수 → 관리자도 못 봄 (placeholder)
    if (msg.mask_state === 'self_withdrawn_influencer') {
      return lastViewedChip + msgCardMasked(senderLabel, timeStr, sideCls, '인플루언서가 회수한 메시지입니다.');
    }

    const bodyHtml = esc(msg.body || '').replace(/\n/g, '<br>');
    const atts = Array.isArray(msg.attachments) ? msg.attachments : [];
    let attachHtml = '';
    if (atts.length) {
      attachHtml = `<div class="msg-attachments">${atts.map((a, i) => {
        const elId = `admatt-${msg.id}-${i}`;
        loadAdmMsgAttachThumb(elId, a.path);
        return `<div class="msg-attach-thumb" id="${elId}" onclick="openAdmMsgLightbox('${esc(a.path)}')"><span class="material-icons-round notranslate" translate="no">image</span></div>`;
      }).join('')}</div>`;
    }

    // 상태 뱃지 + 액션 버튼
    let statusBadge = '';
    let actions = '';
    if (msg.mask_state === 'hidden_by_admin') {
      statusBadge = '<span class="adm-msg-status hidden">숨김 처리됨</span>';
      if (isSuper) actions += `<button type="button" class="adm-msg-act unhide" onclick="promptUnhideMessage('${esc(msg.id)}')">복구</button>`;
    } else if (msg.mask_state === 'self_withdrawn_admin') {
      statusBadge = '<span class="adm-msg-status withdrawn">회수됨</span>';
    } else {
      // visible
      if (fromAdmin) {
        // 운영팀 발신 + 25분 이내 → 회수 (회수는 withdraw_own_message RPC 가 본인 검증)
        const elapsed = now - new Date(msg.created_at).getTime();
        if (elapsed < ADM_MSG_WITHDRAW_LIMIT_MS) {
          const pathsJson = esc(JSON.stringify(atts.map(a => a.path)));
          actions += `<button type="button" class="adm-msg-act withdraw" onclick='confirmAdmWithdraw("${esc(msg.id)}", ${pathsJson})'>회수</button>`;
        }
      } else {
        // 인플루언서 메시지 → campaign_admin+ 강제 숨김 (RPC 가 권한 가드)
        actions += `<button type="button" class="adm-msg-act hide" onclick="promptHideMessage('${esc(msg.id)}')">숨김</button>`;
      }
    }

    // 읽음 표시 (관리자 발신 + 정상 메시지 — 인플루언서가 내 메시지를 읽었는지)
    let readMark = '';
    if (fromAdmin && msg.mask_state === 'visible') {
      readMark = msg.read_by_influencer_at
        ? '<span class="msg-read read">읽음</span>'
        : '<span class="msg-read unread">안읽음</span>';
    }
    // 말풍선 옆 메타: 읽음 / 시간 / 액션(숨김·회수·복구) — mine 은 풍선 왼쪽, 상대는 오른쪽
    return lastViewedChip + `<div class="msg-row ${sideCls}">
      <div class="msg-meta-side">${readMark}<span class="msg-time">${esc(timeStr)}</span>${actions}</div>
      <div class="msg-bubble">
        <div class="msg-sender">${senderLabel}</div>
        <div class="msg-card-body">${bodyHtml}</div>
        ${attachHtml}
        ${statusBadge ? `<div class="msg-status-line">${statusBadge}</div>` : ''}
      </div>
    </div>`;
  }).join('');
  thread.scrollTop = thread.scrollHeight;
}

function msgCardMasked(senderLabel, timeStr, sideCls, text) {
  return `<div class="msg-row msg-row-masked ${sideCls}">
    <div class="msg-meta-side"><span class="msg-time">${esc(timeStr)}</span></div>
    <div class="msg-bubble">
      <div class="msg-sender">${senderLabel}</div>
      <div class="msg-masked-body">${esc(text)}</div>
    </div>
  </div>`;
}

// 대화창 내 메시지 검색 — 현재 열린 대화의 본문에서 매칭 (검색 결과만 표시)
function searchAdminMsg(query) {
  if (!_admMsgCurrentThreadId) return;
  const q = (query || '').trim().toLowerCase();
  const filtered = q
    ? _admMsgCurrentMsgs.filter(m => (m.body || '').toLowerCase().includes(q))
    : _admMsgCurrentMsgs;
  renderAdminMsgThread(_admMsgCurrentThreadId, filtered, true);
}

async function loadAdmMsgAttachThumb(elId, path) {
  try {
    const url = await getMessageAttachmentSignedUrl(path);
    const el = document.getElementById(elId);
    if (el && url) el.innerHTML = `<img src="${esc(url)}" loading="lazy" decoding="async" alt="">`;
  } catch (e) { /* 아이콘 유지 */ }
}

// ── 라이트박스 ──
async function openAdmMsgLightbox(path) {
  const lb = document.getElementById('admMsgLightbox');
  const img = document.getElementById('admMsgLightboxImg');
  if (!lb || !img) return;
  img.src = '';
  openModal('admMsgLightbox');
  try {
    const url = await getMessageAttachmentSignedUrl(path);
    if (url) img.src = url; else { closeAdmMsgLightbox(); toast('이미지를 불러오지 못했습니다.'); }
  } catch (e) { closeAdmMsgLightbox(); toast('이미지를 불러오지 못했습니다.'); }
}
function closeAdmMsgLightbox() {
  closeModal('admMsgLightbox');
  const img = document.getElementById('admMsgLightboxImg');
  if (img) img.src = '';
}

// ════════════════════════════════════════════════════════════════════
// 4. 첨부 선택/전송
// ════════════════════════════════════════════════════════════════════
function curComposerId() { return _admMsgContext === 'inbox' ? 'inboxComposer' : 'admComposer'; }

function onAdmMsgAttachSelected(input) {
  const files = Array.from(input.files || []);
  input.value = '';
  for (const f of files) {
    if (_admMsgPendingFiles.length >= ADM_MSG_MAX_ATTACH) { toast(`첨부는 최대 ${ADM_MSG_MAX_ATTACH}장까지 가능합니다.`); break; }
    _admMsgPendingFiles.push(f);
  }
  renderAdmMsgAttachPreview();
}
function removeAdmMsgAttach(idx) { _admMsgPendingFiles.splice(idx, 1); renderAdmMsgAttachPreview(); }
function renderAdmMsgAttachPreview() {
  const wrap = document.getElementById(curComposerId() + 'Preview');
  if (!wrap) return;
  if (!_admMsgPendingFiles.length) { wrap.innerHTML = ''; return; }
  wrap.innerHTML = _admMsgPendingFiles.map((f, i) => {
    const url = URL.createObjectURL(f);
    return `<div class="msg-attach-pending"><img src="${url}" alt=""><button type="button" class="msg-attach-remove" onclick="removeAdmMsgAttach(${i})" aria-label="삭제"><span class="material-icons-round notranslate" translate="no">close</span></button></div>`;
  }).join('');
}

async function sendAdminMessage() {
  if (_admMsgSending || !_admMsgAppId) return;
  const inputEl = document.getElementById(curComposerId() + 'Input');
  const body = (inputEl?.value || '').trim();
  if (!body && !_admMsgPendingFiles.length) { toast('메시지를 입력하세요.'); return; }
  _admMsgSending = true;
  try {
    const attachments = [];
    for (const f of _admMsgPendingFiles) {
      try { attachments.push(await uploadMessageAttachment(f, _admMsgAppId)); }
      catch (e) {
        console.error('[sendAdminMessage] 첨부', e);
        toast(e?.message === 'too_large' ? '이미지 용량이 큽니다.' : '첨부 업로드에 실패했습니다.');
        _admMsgSending = false; return;
      }
    }
    await sendApplicationMessage(_admMsgAppId, body, attachments);
    if (inputEl) inputEl.value = '';
    _admMsgPendingFiles = [];
    renderAdmMsgAttachPreview();
    const msgs = await fetchApplicationMessages(_admMsgAppId);
    renderAdminMsgThread(_admMsgContext === 'inbox' ? 'inboxMsgThread' : 'admMsgThread', msgs);
    // 관리자 답장 = 자동 응대 완료 → 받은편지함 집계 갱신
    if (_admMsgContext === 'inbox') await refreshInboxData();
    else updateInboxSidebarBadge();
  } catch (e) {
    console.error('[sendAdminMessage]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '전송에 실패했습니다.');
  } finally {
    _admMsgSending = false;
  }
}

// ── 본인(관리자) 회수 ──
async function confirmAdmWithdraw(messageId, attachmentPaths) {
  if (!confirm('이 메시지를 회수하시겠습니까?')) return;
  try {
    await withdrawOwnMessage(messageId, attachmentPaths || []);
    const msgs = await fetchApplicationMessages(_admMsgAppId);
    renderAdminMsgThread(_admMsgContext === 'inbox' ? 'inboxMsgThread' : 'admMsgThread', msgs);
  } catch (e) {
    console.error('[confirmAdmWithdraw]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '회수에 실패했습니다.');
  }
}

// ════════════════════════════════════════════════════════════════════
// 5. 강제 숨김 / 복구
// ════════════════════════════════════════════════════════════════════
let _hideTargetMsgId = null;
async function promptHideMessage(messageId) {
  _hideTargetMsgId = messageId;
  const reasons = await loadHideReasons();
  const sel = document.getElementById('admHideReasonSelect');
  if (sel) sel.innerHTML = reasons.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
  const memo = document.getElementById('admHideMemo');
  if (memo) memo.value = '';
  openModal('admHideModal');
}
function closeHideModal() {
  closeModal('admHideModal');
  _hideTargetMsgId = null;
}
async function confirmHideMessage() {
  if (!_hideTargetMsgId) return;
  const code = document.getElementById('admHideReasonSelect')?.value;
  const memo = document.getElementById('admHideMemo')?.value || '';
  if (!code) { toast('숨김 사유를 선택하세요.'); return; }
  try {
    await hideApplicationMessage(_hideTargetMsgId, code, memo);
    closeHideModal();
    const msgs = await fetchApplicationMessages(_admMsgAppId);
    renderAdminMsgThread(_admMsgContext === 'inbox' ? 'inboxMsgThread' : 'admMsgThread', msgs);
    toast('메시지를 숨김 처리했습니다.');
  } catch (e) {
    console.error('[confirmHideMessage]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '숨김 처리에 실패했습니다.');
  }
}

async function promptUnhideMessage(messageId) {
  const memo = prompt('복구 사유를 입력하세요 (필수):');
  if (memo === null) return;
  if (!memo.trim()) { toast('복구 사유는 필수입니다.'); return; }
  try {
    await unhideApplicationMessage(messageId, memo.trim());
    const msgs = await fetchApplicationMessages(_admMsgAppId);
    renderAdminMsgThread(_admMsgContext === 'inbox' ? 'inboxMsgThread' : 'admMsgThread', msgs);
    toast('메시지를 복구했습니다.');
  } catch (e) {
    console.error('[promptUnhideMessage]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '복구에 실패했습니다.');
  }
}

// 현재 대화창의 「응대 완료」 버튼을 「완료됨」 비활성으로 전환 (즉시 피드백)
function _setResolveBtnDone(ctx) {
  const btn = document.getElementById(`${ctx}ResolveBtn`);
  if (!btn) return;
  btn.textContent = '응대 완료됨';
  btn.disabled = true;
  btn.onclick = null;
  btn.classList.remove('primary');
  btn.classList.add('done');
}

// ── 수동 응대 완료 ──
async function markCurrentResolved() {
  if (!_admMsgAppId) return;
  try {
    await markApplicationResolved(_admMsgAppId);
    toast('응대 완료로 표시했습니다.');
    _setResolveBtnDone(_admMsgContext); // 현재 대화창 버튼 즉시 「완료됨」 비활성
    if (_admMsgContext === 'inbox') await refreshInboxData();
    else updateInboxSidebarBadge();
  } catch (e) {
    console.error('[markCurrentResolved]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '처리에 실패했습니다.');
  }
}

// ════════════════════════════════════════════════════════════════════
// 6. 응모 행 「메시지」 버튼 셀 (신청관리·캠페인별 신청자·결과물 관리 공용)
// ════════════════════════════════════════════════════════════════════
// 페인 로드 시 미열람 맵을 채워두고 호출 (renderApplicantMsgBtn 가 이 맵 참조)
async function loadApplicantMsgUnread() {
  _applicantMsgUnreadMap = await fetchAdminMessageUnreadCounts();
}

// 응모 행에 넣을 메시지 버튼 HTML (app: {id, campaign_id})
function renderApplicantMsgBtn(app) {
  if (!app || !app.id) return '';
  const unread = _applicantMsgUnreadMap.get(app.id) || 0;
  const badge = unread > 0 ? `<span class="applicant-msg-badge">${unread > 99 ? '99+' : unread}</span>` : '';
  return `<button type="button" class="applicant-msg-btn" title="메시지" data-msgbtn="${esc(app.id)}"
    onclick="openAdminMessageModal('${esc(app.id)}','${esc(app.campaign_id || '')}')">
    <span class="material-icons-round notranslate" translate="no">forum</span><span>메시지</span>${badge}</button>`;
}

// 모달 열어 읽음 처리 후 특정 응모 행 배지 갱신 (DOM 직접 — 행 전체 재렌더 회피)
function updateApplicantMsgBadge(applicationId) {
  document.querySelectorAll(`[data-msgbtn="${applicationId}"]`).forEach(el => {
    const b = el.querySelector('.applicant-msg-badge');
    if (b) b.remove();
  });
}

// 캠페인 상태 배지 (draft/scheduled/active/closed/expired — 신청 상태와 별개)
function inboxCampStatusBadge(s) {
  const label = {draft:'준비', scheduled:'모집예정', active:'모집중', closed:'종료', expired:'노출마감'}[s];
  if (!label) return '';
  const cls = {draft:'badge-gray', scheduled:'badge-blue', active:'badge-green', closed:'badge-gold', expired:'badge-gray'}[s] || 'badge-gray';
  return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${label}</span>`;
}

// ── 헬퍼: 캠페인 / 인플 이름 ──
function inboxCampaignById(id) {
  if (!id) return null;
  const list = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns : [];
  return list.find(x => x.id === id) || null;
}
function campaignTitleById(id) {
  const c = inboxCampaignById(id);
  return c ? (c.title || '(제목 없음)') : '(캠페인)';
}

// ════════════════════════════════════════════════════════════════════
// 일괄 발송 (BCC) — PR 3, 마이그레이션 167
//   campaign_admin 이상. 캠페인 단위(필터) 또는 임의 다중선택(presetIds).
//   1차는 텍스트 전용 (첨부는 RLS 경로 설계 후 후속).
// ════════════════════════════════════════════════════════════════════

const BULK_OVER_THRESHOLD = 50;   // 초과 시 2단계 확인
const BULK_MAX = 200;             // RPC 1회 한도와 동일
const BULK_APP_STATUSES = [
  { code: 'pending',  label: '심사중' },
  { code: 'approved', label: '승인' },
  { code: 'rejected', label: '반려' },
];
const BULK_DELIV_STATUSES = [
  { code: 'none',     label: '미제출' },
  { code: 'pending',  label: '검수중' },
  { code: 'approved', label: '승인' },
  { code: 'rejected', label: '반려' },
];
// 일괄발송 ① 단계 — 먼저 고르는 캠페인 상태 (응모자가 존재하는 상태만)
const BULK_CAMPAIGN_STATUSES = [
  { code: 'active', label: '모집중' },
  { code: 'closed', label: '모집마감' },
  { code: 'ended',  label: '종료' },
];

let _bulkState = null;            // { presetIds, campaignId, recipientIds, filterSnapshot }
let _bulkRecountTimer = null;
let _bulkSending = false;
let _inboxTab = 'inbox';

// campaign_admin 이상만 일괄 발송 버튼·발송이력 탭 노출
function admMsgIsCampaignAdmin() {
  return typeof currentAdminInfo !== 'undefined'
    && (currentAdminInfo?.role === 'super_admin' || currentAdminInfo?.role === 'campaign_admin');
}
function applyBulkMsgButtonVisibility() {
  const btn = document.getElementById('bulkMsgOpenBtn');
  if (btn) btn.style.display = admMsgIsCampaignAdmin() ? 'inline-flex' : 'none';
  const tab = document.getElementById('inboxTabBroadcasts');
  if (tab) tab.style.display = admMsgIsCampaignAdmin() ? '' : 'none';
}

// 받은편지함 / 발송 이력 탭 전환
function switchInboxTab(tab) {
  _inboxTab = tab;
  const ti = document.getElementById('inboxTabInbox');
  const tb = document.getElementById('inboxTabBroadcasts');
  if (ti) ti.classList.toggle('is-active', tab === 'inbox');
  if (tb) tb.classList.toggle('is-active', tab === 'broadcasts');
  const main = document.getElementById('inboxMainView');
  const bc = document.getElementById('inboxBroadcastsView');
  if (main) main.style.display = tab === 'inbox' ? '' : 'none';
  if (bc) bc.style.display = tab === 'broadcasts' ? '' : 'none';
  if (tab === 'broadcasts') loadBroadcasts();
}

// ── 일괄 발송 모달 ──
function openBulkMessageModal(presetAppIds) {
  if (!admMsgIsCampaignAdmin()) { toast('일괄 발송 권한이 없습니다.'); return; }
  _bulkState = {
    presetIds: (presetAppIds && presetAppIds.length) ? presetAppIds.slice() : null,
    campaignIds: [], recipientIds: [], filterSnapshot: null,
  };
  document.getElementById('bulkStep1').style.display = 'flex';
  document.getElementById('bulkStep2').style.display = 'none';
  document.getElementById('bulkBackBtn').style.display = 'none';
  document.getElementById('bulkNextBtn').style.display = '';
  document.getElementById('bulkSendBtn').style.display = 'none';
  document.getElementById('bulkBody').value = '';
  document.getElementById('bulkConfirmOver').style.display = 'none';
  const chk = document.getElementById('bulkConfirmCheck'); if (chk) chk.checked = false;
  document.getElementById('bulkMsgTitle').textContent = '일괄 발송 · 대상 선택';

  if (_bulkState.presetIds) {
    // 임의 다중선택 모드 (3c 후속 진입) — 사전 선택된 응모건
    document.getElementById('bulkCampaignPick').style.display = 'none';
    document.getElementById('bulkFilters').style.display = 'none';
    const info = document.getElementById('bulkPresetInfo');
    info.style.display = 'block';
    info.textContent = `선택된 응모건 ${_bulkState.presetIds.length}건에 발송합니다.`;
    _bulkState.recipientIds = _bulkState.presetIds.slice();
    updateBulkCount(_bulkState.recipientIds.length);
    document.getElementById('bulkCountBox').style.display = 'block';
    document.getElementById('bulkNextBtn').disabled = _bulkState.recipientIds.length === 0;
  } else {
    // 캠페인 단위 모드 — ① 상태 칩 먼저 → ② 캠페인 선택 → ③ 참여 조건 → ④ 인플 상태
    document.getElementById('bulkCampaignPick').style.display = '';
    document.getElementById('bulkPresetInfo').style.display = 'none';
    document.getElementById('bulkFilters').style.display = 'none';
    document.getElementById('bulkCountBox').style.display = 'none';
    document.getElementById('bulkNextBtn').disabled = true;
    _bulkState.statuses = [];
    _bulkState.recruitTypes = [];
    _bulkState.availableCampaignIds = [];
    _bulkState.hasMonitor = false;
    renderBulkStatusChips();        // ① 캠페인 상태 칩 (미선택 상태)
    renderBulkRecruitTypeChips();   // 모집 타입 칩 (미선택 = 전체)
    document.getElementById('bulkCampaignSelectWrap').style.display = 'none';
    renderBulkStatusFilters();    // 응모·영수증·결과물 status 체크박스 (기본값)
    renderBulkSnsChannels();      // ④ 인플 보유 SNS 채널 4종 체크박스
    renderBulkPrefectureMulti();  // ④ 지역(도도부현) 다중선택
    if (typeof resetMultiFilter === 'function') resetMultiFilter('bulkPrefectureMulti', '전체 지역');   // 디폴트 = 전체 지역 선택
    // 인플 상태 토글 기본값 복원 (블랙리스트 제외만 기본 켜짐)
    const v = document.getElementById('bulkInflVerified'); if (v) v.checked = false;
    const nv = document.getElementById('bulkInflNoViolation'); if (nv) nv.checked = false;
    const nb = document.getElementById('bulkInflNoBlacklist'); if (nb) nb.checked = true;
    // 팔로워 필터 기본값: 채널별·Instagram·빈값
    const fmPer = document.querySelector('input[name="bulkFollowerMode"][value="per_channel"]'); if (fmPer) fmPer.checked = true;
    const fc = document.getElementById('bulkFollowerChannel'); if (fc) { fc.value = 'instagram'; fc.style.display = ''; }
    document.getElementById('bulkMinFollowers').value = '';
    const t = document.getElementById('bulkTitle'); if (t) t.value = '';
  }
  openModal('bulkMessageModal');
}
function closeBulkMessageModal() { closeModal('bulkMessageModal'); _bulkState = null; }

// ① 캠페인 상태 칩 (다중선택). 변경 → 캠페인 목록 갱신
function renderBulkStatusChips() {
  document.getElementById('bulkStatusChips').innerHTML = BULK_CAMPAIGN_STATUSES.map(s =>
    `<label class="bulk-chk"><input type="checkbox" value="${s.code}" onchange="onBulkStatusChipChange()">${s.label}</label>`).join('');
}

// 모집 타입 칩 (다중선택, 선택적 — 미선택 시 전체 타입). 변경 → 캠페인 목록 갱신
function renderBulkRecruitTypeChips() {
  const _rtKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined') ? RECRUIT_TYPE_LABEL_KO : { monitor:'리뷰어', gifting:'기프팅', visit:'방문형' };
  const types = [['monitor', _rtKo.monitor], ['gifting', _rtKo.gifting], ['visit', _rtKo.visit]];
  document.getElementById('bulkRecruitTypeChips').innerHTML = types.map(([code, label]) =>
    `<label class="bulk-chk"><input type="checkbox" value="${code}" onchange="onBulkRecruitChipChange()">${label}</label>`).join('');
}

function onBulkStatusChipChange() { refreshBulkCampaignList(); }
function onBulkRecruitChipChange() { refreshBulkCampaignList(); }

// 상태·모집타입 칩 변경 시 ② 캠페인 목록 갱신. 상태는 필수 게이트(미선택 시 ② 숨김), 타입은 선택적.
function refreshBulkCampaignList() {
  const statuses = Array.from(document.querySelectorAll('#bulkStatusChips input:checked')).map(i => i.value);
  const types = Array.from(document.querySelectorAll('#bulkRecruitTypeChips input:checked')).map(i => i.value);
  _bulkState.statuses = statuses;
  _bulkState.recruitTypes = types;
  _bulkState.campaignIds = [];
  const selWrap = document.getElementById('bulkCampaignSelectWrap');
  document.getElementById('bulkFilters').style.display = 'none';
  document.getElementById('bulkCountBox').style.display = 'none';
  document.getElementById('bulkNextBtn').disabled = true;
  if (!statuses.length) {
    // 상태 미선택 → ② 캠페인 선택 숨김 (모집 타입만으론 목록 안 띄움)
    if (selWrap) selWrap.style.display = 'none';
    return;
  }
  if (selWrap) selWrap.style.display = '';
  populateBulkCampaigns(statuses, types);   // 상태 AND 타입 조건 캠페인만
  if (typeof clearMultiFilter === 'function') clearMultiFilter('bulkCampaignMulti', '캠페인을 선택하세요');
}

function populateBulkCampaigns(statuses, recruitTypes) {
  const allow = (statuses && statuses.length) ? statuses : ['active', 'closed', 'ended'];
  const typeAllow = (recruitTypes && recruitTypes.length) ? recruitTypes : null;   // null = 전체 타입
  const camps = (typeof allCampaigns !== 'undefined' ? allCampaigns : [])
    .filter(c => allow.includes(c.status) && (!typeAllow || typeAllow.includes(c.recruit_type)))
    .sort((a, b) => (b.created_at || '').localeCompare(a.created_at || ''));
  _bulkState.availableCampaignIds = camps.map(c => c.id);   // 「전체 선택」용 현재 목록 전체 id
  // 드롭다운 부가설명: 캠페인 번호 · 모집타입 · 상태 · 채널 (대상 캠페인 식별 보조)
  const _rtKo = (typeof RECRUIT_TYPE_LABEL_KO !== 'undefined') ? RECRUIT_TYPE_LABEL_KO : { monitor:'리뷰어', gifting:'기프팅', visit:'방문형' };
  const _stKo = { active:'모집중', closed:'모집마감', ended:'종료' };
  const options = camps.map(c => {
    const meta = [
      c.campaign_no,
      _rtKo[c.recruit_type],
      _stKo[c.status],
      (typeof getChannelLabel === 'function' ? getChannelLabel(c.channel, 'ko') : c.channel)
    ].filter(Boolean).join(' · ');
    return { value: c.id, label: c.title || '(제목 없음)', subLabel: meta, count: null };
  });
  // 결과물 관리와 동일한 검색형 다중필터 (캠페인명·번호 검색). 선택 변경 → onBulkCampaignChange
  if (typeof syncMultiFilter === 'function') {
    syncMultiFilter('bulkCampaignMulti', '전체 선택', options, onBulkCampaignChange, { searchable: true, searchPlaceholder: '캠페인명 · 번호 검색', placeholder: '캠페인을 선택하세요', countLabel: true });
  }
  // 빈 상태 안내 (선택 조건에 캠페인 0건)
  const empty = document.getElementById('bulkCampaignEmpty');
  if (empty) empty.style.display = camps.length ? 'none' : 'block';
}

function onBulkCampaignChange() {
  let ids = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('bulkCampaignMulti') : [];
  // mf-wrap 「전체 체크」(모두 선택)는 빈배열을 반환(필터 없음 시맨틱) → 현재 필터된 전체 캠페인을 명시 대상으로 치환
  if (!ids.length) {
    const wrap = document.getElementById('bulkCampaignMulti');
    const allCb = wrap && wrap.querySelector('input[value="all"]');
    if (allCb && allCb.checked && !allCb.indeterminate) {
      ids = (_bulkState.availableCampaignIds || []).slice();
    }
  }
  _bulkState.campaignIds = ids;
  // [] = 모두 해제(선택 없음) → 일괄발송은 대상 0 (명시 선택 강제)
  if (!ids.length) {
    document.getElementById('bulkFilters').style.display = 'none';
    document.getElementById('bulkCountBox').style.display = 'none';
    document.getElementById('bulkNextBtn').disabled = true;
    return;
  }
  renderBulkReceiptVisibility(ids);    // 리뷰어(monitor) 포함 시에만 영수증 필터 노출
  document.getElementById('bulkFilters').style.display = 'flex';
  document.getElementById('bulkCountBox').style.display = 'block';
  scheduleBulkRecount();
}

// 선택 캠페인에 리뷰어(monitor) 캠페인이 있는지 판정 → 영수증 필터 노출 여부 결정 (실제 토글은 scheduleBulkRecount)
function renderBulkReceiptVisibility(campaignIds) {
  const camps = (typeof allCampaigns !== 'undefined' ? allCampaigns : []);
  _bulkState.hasMonitor = campaignIds.some(cid => {
    const c = camps.find(x => x.id === cid);
    return c && c.recruit_type === 'monitor';
  });
}

// 응모·영수증·결과물 상태 체크박스 — 모달 열 때 1회 렌더(선택 보존). 영수증·결과물 동일 status 코드.
function renderBulkStatusFilters() {
  document.getElementById('bulkAppStatus').innerHTML = BULK_APP_STATUSES.map(s =>
    `<label class="bulk-chk"><input type="checkbox" value="${s.code}" ${s.code === 'approved' ? 'checked' : ''} onchange="scheduleBulkRecount()">${s.label}</label>`).join('');
  const delivChk = (s) => `<label class="bulk-chk"><input type="checkbox" value="${s.code}" ${s.code !== 'approved' ? 'checked' : ''} onchange="scheduleBulkRecount()">${s.label}</label>`;
  document.getElementById('bulkReceiptStatus').innerHTML = BULK_DELIV_STATUSES.map(delivChk).join('');
  document.getElementById('bulkPostStatus').innerHTML = BULK_DELIV_STATUSES.map(delivChk).join('');
}

// ④ 인플 보유 SNS 채널 — 핸들 컬럼 있는 4종만 정확 판정(Qoo10·LIPS·@cosme는 보유 데이터 없음). 모달 열 때 1회 렌더.
const BULK_SNS_CHANNELS = [['instagram', 'Instagram'], ['x', 'X(Twitter)'], ['tiktok', 'TikTok'], ['youtube', 'YouTube']];
function renderBulkSnsChannels() {
  document.getElementById('bulkSnsChannels').innerHTML = BULK_SNS_CHANNELS.map(([code, label]) =>
    `<label class="bulk-chk"><input type="checkbox" value="${code}" onchange="scheduleBulkRecount()">${label}</label>`).join('');
}

// ④ 지역(도도부현) 다중선택 — PREFECTURE_KO(일본어 키 → 한국어 라벨) 재사용. 선택 변경 → recount.
function renderBulkPrefectureMulti() {
  const map = (typeof PREFECTURE_KO !== 'undefined') ? PREFECTURE_KO : {};
  const options = Object.keys(map).map(ja => ({ value: ja, label: map[ja], subLabel: '', count: null }));
  if (typeof syncMultiFilter === 'function') {
    syncMultiFilter('bulkPrefectureMulti', '전체 지역', options, scheduleBulkRecount, { searchable: true, searchPlaceholder: '지역 검색' });
  }
}

// 팔로워 모드 전환 — 채널별이면 기준 채널 select 노출, 합산이면 숨김. 변경 시 recount.
function onBulkFollowerModeChange() {
  const mode = document.querySelector('input[name="bulkFollowerMode"]:checked')?.value;
  const sel = document.getElementById('bulkFollowerChannel');
  if (sel) sel.style.display = (mode === 'per_channel') ? '' : 'none';
  scheduleBulkRecount();
}

function collectBulkFilters() {
  const pick = (id) => Array.from(document.querySelectorAll(`#${id} input:checked`)).map(i => i.value);
  const appStatuses = pick('bulkAppStatus');
  const approved = appStatuses.includes('approved');
  // 결과물·영수증 상태 필터는 응모상태 승인 포함 시만 의미. 영수증은 추가로 리뷰어 캠페인 포함 시만.
  const postStatuses = approved ? pick('bulkPostStatus') : [];
  const receiptStatuses = (approved && _bulkState && _bulkState.hasMonitor) ? pick('bulkReceiptStatus') : [];
  const channels = pick('bulkSnsChannels');   // ④ 인플 보유 SNS 채널 (4종)
  const prefectures = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('bulkPrefectureMulti') : [];
  const followerMode = document.querySelector('input[name="bulkFollowerMode"]:checked')?.value || 'per_channel';
  const followerChannel = document.getElementById('bulkFollowerChannel')?.value || 'instagram';
  const mf = document.getElementById('bulkMinFollowers').value;
  return {
    appStatuses, receiptStatuses, postStatuses, channels, prefectures,
    followerMode, followerChannel, minFollowers: mf,
    requireVerified: document.getElementById('bulkInflVerified')?.checked || false,
    excludeViolation: document.getElementById('bulkInflNoViolation')?.checked || false,
    excludeBlacklist: document.getElementById('bulkInflNoBlacklist')?.checked !== false,
  };
}

function scheduleBulkRecount() {
  const appChecked = Array.from(document.querySelectorAll('#bulkAppStatus input:checked')).map(i => i.value);
  const approved = appChecked.includes('approved');
  // 결과물 블록은 승인 포함 시만 노출
  const delivWrap = document.getElementById('bulkDelivWrap');
  if (delivWrap) delivWrap.style.display = approved ? '' : 'none';
  // 영수증 필터는 승인 + 리뷰어(monitor) 캠페인 포함 시만 노출
  const receiptWrap = document.getElementById('bulkReceiptWrap');
  if (receiptWrap) receiptWrap.style.display = (approved && _bulkState && _bulkState.hasMonitor) ? '' : 'none';
  clearTimeout(_bulkRecountTimer);
  _bulkRecountTimer = setTimeout(recountBulk, 350);
}

const BULK_RECOUNT_TIMEOUT_MS = 15000;   // 대상 계산 시간 제한 — 네트워크 지연·장애 시 「계산 중」 고착 방지

async function recountBulk() {
  if (!_bulkState || !_bulkState.campaignIds || !_bulkState.campaignIds.length) return;
  const filters = collectBulkFilters();
  const campaignIds = _bulkState.campaignIds.slice();
  const loading = document.getElementById('bulkCountLoading');
  if (loading) loading.style.display = 'inline';
  try {
    // 캠페인별 대상 해결 후 application_id 합집합 (캠페인마다 자기 채널·팔로워 기준 정확 적용).
    // 네트워크 hang 대비 시간 제한 — 초과 시 reject 되어 catch 로 떨어지고 loading 해제됨.
    const results = await Promise.race([
      Promise.all(campaignIds.map(cid => resolveBulkRecipients(cid, filters))),
      new Promise((_, reject) => setTimeout(() => reject(new Error('bulk_recount_timeout')), BULK_RECOUNT_TIMEOUT_MS)),
    ]);
    // 계산 도중 선택이 바뀌었으면 폐기 (오래된 결과 반영 방지)
    if (JSON.stringify(_bulkState.campaignIds) !== JSON.stringify(campaignIds)) return;
    const idSet = new Set();
    results.forEach(arr => (arr || []).forEach(id => idSet.add(id)));
    const ids = Array.from(idSet);
    _bulkState.recipientIds = ids;
    _bulkState.filterSnapshot = filters;
    updateBulkCount(ids.length);
    document.getElementById('bulkNextBtn').disabled = ids.length === 0;
  } catch (e) {
    if (e && e.message === 'bulk_recount_timeout') {
      toast('대상 계산이 지연됩니다. 네트워크 확인 후 필터를 다시 조정해 주세요.');
    } else {
      console.error('[recountBulk]', e);
      toast('대상 계산에 실패했습니다.');
    }
    updateBulkCount(0);
    document.getElementById('bulkNextBtn').disabled = true;
  } finally {
    if (loading) loading.style.display = 'none';
  }
}

function updateBulkCount(n) {
  const el = document.getElementById('bulkCount'); if (el) el.textContent = n;
  const el2 = document.getElementById('bulkCount2'); if (el2) el2.textContent = n;
}

function bulkStepNext() {
  if (!_bulkState || !_bulkState.recipientIds.length) { toast('대상이 없습니다.'); return; }
  if (_bulkState.recipientIds.length > BULK_MAX) {
    toast(`1회 최대 ${BULK_MAX}명까지 발송할 수 있습니다. 필터로 범위를 좁혀주세요.`); return;
  }
  document.getElementById('bulkStep1').style.display = 'none';
  document.getElementById('bulkStep2').style.display = 'flex';
  document.getElementById('bulkBackBtn').style.display = '';
  document.getElementById('bulkNextBtn').style.display = 'none';
  document.getElementById('bulkSendBtn').style.display = '';
  document.getElementById('bulkMsgTitle').textContent = '일괄 발송 · 본문 작성';
  const over = _bulkState.recipientIds.length > BULK_OVER_THRESHOLD;
  document.getElementById('bulkConfirmOver').style.display = over ? 'block' : 'none';
  document.getElementById('bulkOverCount').textContent = _bulkState.recipientIds.length;
  document.getElementById('bulkSendBtn').disabled = over;  // 초과면 확인 체크 후 활성
  const chk = document.getElementById('bulkConfirmCheck'); if (chk) chk.checked = false;
}
function bulkStepBack() {
  document.getElementById('bulkStep1').style.display = 'flex';
  document.getElementById('bulkStep2').style.display = 'none';
  document.getElementById('bulkBackBtn').style.display = 'none';
  document.getElementById('bulkNextBtn').style.display = '';
  document.getElementById('bulkSendBtn').style.display = 'none';
  document.getElementById('bulkMsgTitle').textContent = '일괄 발송 · 대상 선택';
}
function onBulkConfirmCheck() {
  document.getElementById('bulkSendBtn').disabled = !document.getElementById('bulkConfirmCheck').checked;
}

async function confirmBulkSend() {
  if (_bulkSending || !_bulkState) return;
  const ids = _bulkState.recipientIds;
  if (!ids.length) { toast('대상이 없습니다.'); return; }
  const body = document.getElementById('bulkBody').value.trim();
  if (!body) { toast('메시지를 입력하세요.'); return; }
  _bulkSending = true;
  document.getElementById('bulkSendBtn').disabled = true;
  try {
    const contextKind = _bulkState.presetIds ? 'manual' : 'campaign';
    const campIds = _bulkState.campaignIds || [];
    // 캠페인 1개면 context_campaign_id 단일 컬럼(하위호환), 2개+면 NULL + context_filter.campaign_ids 배열
    const contextCampaignId = (!_bulkState.presetIds && campIds.length === 1) ? campIds[0] : null;
    const contextFilter = _bulkState.presetIds ? null : { ...(_bulkState.filterSnapshot || {}), campaign_ids: campIds };
    const title = document.getElementById('bulkTitle')?.value.trim() || null;   // 관리자 전용 제목 (선택)
    await sendApplicationMessageBulk(ids, body, [], contextKind, contextCampaignId, contextFilter, title);
    toast(`${ids.length}명에게 발송했습니다.`);
    closeBulkMessageModal();
    if (_inboxTab === 'broadcasts') loadBroadcasts();
    // 받은편지함 탭의 미읽음·응대 배지 stale 방지 (발송 = 자동 응대 완료) — 비동기 갱신
    if (typeof refreshInboxData === 'function') refreshInboxData();
  } catch (e) {
    console.error('[confirmBulkSend]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '발송에 실패했습니다.');
    document.getElementById('bulkSendBtn').disabled = false;
  } finally {
    _bulkSending = false;
  }
}

// ── 발송 이력 ──
async function loadBroadcasts() {
  const wrap = document.getElementById('broadcastsList');
  if (!wrap) return;
  wrap.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">불러오는 중…</div>';
  const opts = {};
  // campaign_admin 은 본인 발송분만, super_admin 은 전체
  if (currentAdminInfo?.role === 'campaign_admin') opts.senderId = currentAdminInfo.auth_id;
  let rows = [];
  try { rows = await fetchBroadcasts(opts); }
  catch (e) { console.error('[loadBroadcasts]', e); wrap.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">불러오기 실패</div>'; return; }
  if (!rows.length) { wrap.innerHTML = '<div style="padding:24px;text-align:center;color:var(--muted)">발송 이력이 없습니다.</div>'; return; }
  _broadcastRows = rows;   // 상세 모달에서 제목(관리자 전용) 재사용용 캐시
  wrap.innerHTML = rows.map(renderBroadcastRow).join('');
}

let _broadcastRows = [];

function renderBroadcastRow(r) {
  const dt = r.created_at ? new Date(r.created_at).toLocaleString('ja-JP') : '';
  const text = (r.body || '');
  const preview = esc(text.slice(0, 60)) + (text.length > 60 ? '…' : '');
  const campCnt = (r.context_filter && Array.isArray(r.context_filter.campaign_ids)) ? r.context_filter.campaign_ids.length : (r.context_campaign_id ? 1 : 0);
  const ctx = r.context_kind === 'campaign'
    ? (campCnt > 1 ? `캠페인 ${campCnt}개 대상` : '캠페인 대상')
    : '임의 선택';
  const withdrawn = r.withdrawn_at ? '<span class="broadcast-badge broadcast-badge-withdrawn">회수됨</span>' : '';
  const titleHtml = r.title ? `<div class="broadcast-row-title" style="font-weight:600;font-size:13px;color:var(--ink);margin-bottom:2px">${esc(r.title)}</div>` : '';
  return `<div class="broadcast-row" onclick="openBroadcastDetail('${esc(r.id)}')">
    <div class="broadcast-row-main">
      ${titleHtml}
      <div class="broadcast-row-preview">${preview || '(본문 없음)'}</div>
      <div class="broadcast-row-meta">${dt} · ${ctx} · 수신 ${r.recipient_count}명 ${withdrawn}</div>
    </div>
    <span class="material-icons-round notranslate" translate="no" style="color:var(--muted)">chevron_right</span>
  </div>`;
}

let _curBroadcastDetail = null;
async function openBroadcastDetail(id) {
  const body = document.getElementById('broadcastDetailBody');
  body.innerHTML = '<div style="padding:16px;text-align:center;color:var(--muted)">불러오는 중…</div>';
  document.getElementById('broadcastWithdrawBtn').style.display = 'none';
  openModal('broadcastDetailModal');
  let detail = null;
  try { detail = await getBroadcastDetail(id); }
  catch (e) { console.error('[openBroadcastDetail]', e); body.innerHTML = '<div style="padding:16px;color:var(--muted)">불러오기 실패</div>'; return; }
  if (!detail || !detail.broadcast) { body.innerHTML = '<div style="padding:16px;color:var(--muted)">정보 없음</div>'; return; }
  _curBroadcastDetail = detail;
  const b = detail.broadcast;
  const recips = detail.recipients || [];
  const dt = b.created_at ? new Date(b.created_at).toLocaleString('ja-JP') : '';
  const readN = recips.filter(r => r.read).length;
  const repliedN = recips.filter(r => r.replied).length;
  const withdrawnBanner = b.withdrawn_at
    ? `<div style="background:#FEF2F2;border:1px solid #FECACA;border-radius:8px;padding:8px 12px;font-size:12px;color:#991B1B">${new Date(b.withdrawn_at).toLocaleString('ja-JP')} 회수됨</div>` : '';
  // 제목(관리자 전용) — get_broadcast_detail 미반환이라 목록 캐시에서 조회
  const cachedTitle = (_broadcastRows.find(x => x.id === id) || {}).title;
  const titleHtml = cachedTitle
    ? `<div style="font-weight:700;font-size:14px;color:var(--ink)">${esc(cachedTitle)} <span style="font-weight:400;font-size:11px;color:var(--muted)">(관리자 전용 제목)</span></div>` : '';
  body.innerHTML = `
    ${withdrawnBanner}
    ${titleHtml}
    <div style="font-size:12px;color:var(--muted)">${dt} · ${esc(b.sender_name || '')}</div>
    <div style="background:var(--bg);border-radius:10px;padding:12px;font-size:14px;color:var(--ink);white-space:pre-wrap">${esc(b.body || '')}</div>
    <div style="font-size:13px;color:var(--ink)">수신 ${b.recipient_count}명 · 읽음 ${readN} · 답장 ${repliedN}</div>
    <div class="broadcast-recips">
      ${recips.map(r => `<div class="broadcast-recip" onclick="gotoBroadcastRecipMessage('${esc(r.application_id)}')">
        <span class="broadcast-recip-name">${esc(r.influencer_name || '(인플루언서)')}</span>
        <span class="broadcast-recip-camp">${esc(r.campaign_title || '')}</span>
        <span class="broadcast-recip-status">${r.read ? '읽음' : '미읽음'}${r.replied ? ' · 답장' : ''}</span>
      </div>`).join('')}
    </div>`;
  const canWithdraw = !b.withdrawn_at && (b.sender_id === currentAdminInfo?.auth_id || currentAdminInfo?.role === 'super_admin');
  document.getElementById('broadcastWithdrawBtn').style.display = canWithdraw ? '' : 'none';
}
function closeBroadcastDetail() { closeModal('broadcastDetailModal'); _curBroadcastDetail = null; }

function gotoBroadcastRecipMessage(appId) {
  if (!appId) return;
  closeBroadcastDetail();
  if (typeof openAdminMessageModal === 'function') openAdminMessageModal(appId, null);
}

// ── 일괄 회수 ──
async function openBroadcastWithdraw() {
  if (!_curBroadcastDetail) return;
  const sel = document.getElementById('broadcastWithdrawReason');
  const reasons = await loadHideReasons();
  sel.innerHTML = reasons.map(r => `<option value="${r.code}">${esc(r.name_ko || r.name_ja || r.code)}</option>`).join('');
  document.getElementById('broadcastWithdrawMemo').value = '';
  openModal('broadcastWithdrawModal');
}
function closeBroadcastWithdraw() { closeModal('broadcastWithdrawModal'); }

let _bcWithdrawing = false;
async function confirmBroadcastWithdraw() {
  if (_bcWithdrawing || !_curBroadcastDetail) return;
  const id = _curBroadcastDetail.broadcast.id;
  const code = document.getElementById('broadcastWithdrawReason').value;
  const memo = document.getElementById('broadcastWithdrawMemo').value.trim() || null;
  if (!code) { toast('회수 사유를 선택하세요.'); return; }
  _bcWithdrawing = true;
  try {
    await withdrawBroadcast(id, code, memo);
    toast('회수했습니다.');
    closeBroadcastWithdraw();
    closeBroadcastDetail();
    loadBroadcasts();
  } catch (e) {
    console.error('[confirmBroadcastWithdraw]', e);
    toast(e?.code === 'P0001' && e?.message ? e.message : '회수에 실패했습니다.');
  } finally {
    _bcWithdrawing = false;
  }
}
