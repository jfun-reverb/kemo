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
let _inboxFilters = { unresolvedOnly: false, sinceMonths: 6 };
let _inboxSort = 'recent';              // 'recent'(최근 메시지순) | 'unresolved'(미응대 우선)
let _inboxSearch = '';                  // 받은편지함 검색어 (인플 이름·이메일·캠페인명·미리보기)

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
  const wrap = document.getElementById('inboxThreadView');
  if (wrap) wrap.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
  await refreshInboxData();
  updateInboxStage();
}

// 단계 진행형 너비 — 선택 진척에 따라 활성 단을 넓힘 (메신저 드릴다운)
//   캠페인 미선택 → 캠페인 목록 전체폭 / 캠페인 선택 → 대화 상대 목록 확대 / 대화 선택 → 대화 내용 확대
function updateInboxStage() {
  const pane = document.querySelector('.inbox-3pane');
  if (!pane) return;
  pane.classList.remove('stage-campaigns', 'stage-threads', 'stage-view');
  const threadOpen = _admMsgContext === 'inbox' && _admMsgAppId;
  if (!_inboxSelectedCampaign) pane.classList.add('stage-campaigns');
  else if (!threadOpen) pane.classList.add('stage-threads');
  else pane.classList.add('stage-view');
}

// 뷰 + 본인 미열람 맵을 다시 조회하고 좌/중 패널 재렌더
async function refreshInboxData() {
  try {
    const [threads, unreadMap] = await Promise.all([
      fetchAdminMessageThreads({ sinceMonths: _inboxFilters.sinceMonths }),
      fetchAdminMessageUnreadCounts(),
    ]);
    _inboxThreads = threads || [];
    _inboxUnreadMap = unreadMap || new Map();
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

// 중: 선택 캠페인의 대화 상대(인플루언서) 목록
function renderInboxThreadList() {
  const el = document.getElementById('inboxThreads');
  if (!el) return;
  if (!_inboxSelectedCampaign) {
    el.innerHTML = '<div class="inbox-empty">왼쪽에서 캠페인을 선택하세요.</div>';
    return;
  }
  let list = filteredInboxThreads().filter(t => t.campaign_id === _inboxSelectedCampaign);
  if (_inboxSort === 'unresolved') {
    list.sort((a, b) => (Number(b.unresolved_for_admin_team) - Number(a.unresolved_for_admin_team))
      || (b.last_message_at || '').localeCompare(a.last_message_at || ''));
  } else {
    list.sort((a, b) => (b.last_message_at || '').localeCompare(a.last_message_at || ''));
  }
  if (!list.length) {
    el.innerHTML = '<div class="inbox-empty">대화가 없습니다.</div>';
    return;
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
    return `<button type="button" class="inbox-thread-item ${active}" onclick="openInboxThread('${esc(t.application_id)}')">
      <span class="inbox-thread-main">
        <span class="inbox-thread-name">${kanji}${kana ? `<span class="inbox-thread-kana">${kana}</span>` : ''}</span>
        ${email ? `<span class="inbox-thread-email">${email}</span>` : ''}
        ${previewHtml}
      </span>
      <span class="inbox-thread-right">
        <span class="inbox-thread-time">${esc(formatDateTime(t.last_message_at))}</span>
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
function changeInboxSince(months) {
  _inboxFilters.sinceMonths = Number(months) || 6;
  refreshInboxData();
}
function changeInboxSort(v) {
  _inboxSort = (v === 'unresolved') ? 'unresolved' : 'recent';
  renderInboxCampaignList();
  renderInboxThreadList();
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
function influencerNameById(id) {
  if (!id) return '(인플루언서)';
  const inf = _inboxInflMap && _inboxInflMap[id];
  if (!inf) return '(인플루언서)';
  return inf.name || inf.name_kana || inf.email || '(이름 없음)';
}
