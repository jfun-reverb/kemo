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

// 메시지 모달/패널 공용 상태
let _admMsgAppId = null;                // 현재 열린 응모건
let _admMsgContext = 'modal';           // 'modal' | 'inbox' — 전송 후 재렌더 대상
let _admMsgPendingFiles = [];
let _admMsgSending = false;

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
  // campaign_id 별 집계
  const byCamp = new Map();
  for (const t of _inboxThreads) {
    if (_inboxFilters.unresolvedOnly && !t.unresolved_for_admin_team) continue;
    let g = byCamp.get(t.campaign_id);
    if (!g) { g = { campaign_id: t.campaign_id, total: 0, unresolved: 0, lastAt: t.last_message_at }; byCamp.set(t.campaign_id, g); }
    g.total += 1;
    if (t.unresolved_for_admin_team) g.unresolved += 1;
    if (t.last_message_at > g.lastAt) g.lastAt = t.last_message_at;
  }
  const groups = Array.from(byCamp.values()).sort((a, b) => (b.lastAt || '').localeCompare(a.lastAt || ''));
  if (!groups.length) {
    el.innerHTML = '<div class="inbox-empty">표시할 대화가 없습니다.</div>';
    return;
  }
  el.innerHTML = groups.map(g => {
    const c = inboxCampaignById(g.campaign_id);
    const title = c ? (c.title || '(제목 없음)') : '(캠페인)';
    const active = g.campaign_id === _inboxSelectedCampaign ? 'active' : '';
    const badge = g.unresolved > 0 ? `<span class="inbox-camp-badge">${g.unresolved}</span>` : '';
    // 모집타입 배지(공통 헬퍼) + 캠페인 상태 배지(캠페인 전용 — 신청 상태와 라벨 다름)
    const typeBadge = (c && typeof getRecruitTypeBadgeKoSm === 'function') ? getRecruitTypeBadgeKoSm(c.recruit_type) : '';
    const statusBadge = c ? inboxCampStatusBadge(c.status) : '';
    // 브랜드 · 모집인원
    const brand = c ? esc(c.brand_ko || c.brand || '') : '';
    const slots = (c && c.slots) ? `모집 ${c.slots}명` : '';
    const sub = [brand, slots].filter(Boolean).join(' · ');
    return `<button type="button" class="inbox-camp-item ${active}" onclick="selectInboxCampaign('${esc(g.campaign_id)}')">
      <span class="inbox-camp-badges">${typeBadge}${statusBadge}</span>
      <span class="inbox-camp-title">${esc(title)}</span>
      ${sub ? `<span class="inbox-camp-sub">${sub}</span>` : ''}
      <span class="inbox-camp-meta">대화 ${g.total}건${badge}</span>
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
  let list = _inboxThreads.filter(t => t.campaign_id === _inboxSelectedCampaign);
  if (_inboxFilters.unresolvedOnly) list = list.filter(t => t.unresolved_for_admin_team);
  list.sort((a, b) => (b.last_message_at || '').localeCompare(a.last_message_at || ''));
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
      <span class="inbox-thread-top">
        <span class="inbox-thread-name">${kanji}${kana ? `<span class="inbox-thread-kana">${kana}</span>` : ''}</span>
        <span class="inbox-thread-meta">${unresolved}${unreadChip}</span>
      </span>
      ${email ? `<span class="inbox-thread-email">${email}</span>` : ''}
      ${previewHtml}
      <span class="inbox-thread-time">${esc(formatDateTime(t.last_message_at))}</span>
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
    if (view) view.innerHTML = adminThreadViewHtml('inbox');
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
  if (body) body.innerHTML = adminThreadViewHtml('modal');
  openModal('admMsgModal');
  const thread = document.getElementById('admMsgThread');
  if (thread) thread.innerHTML = '<div class="msg-empty">불러오는 중…</div>';
  try {
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
function adminThreadViewHtml(ctx) {
  const threadId = ctx === 'inbox' ? 'inboxMsgThread' : 'admMsgThread';
  const composerId = ctx === 'inbox' ? 'inboxComposer' : 'admComposer';
  const histId = ctx === 'inbox' ? 'inboxHideHist' : 'admHideHist';
  const histBtn = admMsgIsSuper()
    ? `<button type="button" class="adm-msg-bar-btn" onclick="toggleHideHistory('${ctx}')">숨김 이력</button>` : '';
  return `
    <div class="adm-msg-actionbar">
      <button type="button" class="adm-msg-bar-btn primary" onclick="markCurrentResolved()">응대 완료</button>
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
// 3. 스레드 렌더 (공용 — 받은편지함 우측·모달 모두)
// ════════════════════════════════════════════════════════════════════
function renderAdminMsgThread(threadElId, messages) {
  const thread = document.getElementById(threadElId);
  if (!thread) return;
  if (!messages || !messages.length) {
    thread.innerHTML = '<div class="msg-empty">아직 메시지가 없습니다.</div>';
    return;
  }
  const now = Date.now();
  const isSuper = admMsgIsSuper();
  thread.innerHTML = messages.map(msg => {
    const fromAdmin = msg.sender_kind === 'admin';
    const senderLabel = fromAdmin ? `운영팀 (${esc(msg.sender_name || '')})` : esc(msg.sender_name || '인플루언서');
    const timeStr = formatDateTime(msg.created_at);
    const sideCls = fromAdmin ? 'mine' : '';

    // 인플루언서 본인 회수 → 관리자도 못 봄 (placeholder)
    if (msg.mask_state === 'self_withdrawn_influencer') {
      return msgCardMasked(senderLabel, timeStr, sideCls, '인플루언서가 회수한 메시지입니다.');
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

    return `<div class="msg-card ${sideCls}">
      <div class="msg-card-head"><span class="msg-sender">${senderLabel}</span><span class="msg-time">${esc(timeStr)}</span>${statusBadge}${actions}</div>
      <div class="msg-card-body">${bodyHtml}</div>
      ${attachHtml}
    </div>`;
  }).join('');
  thread.scrollTop = thread.scrollHeight;
}

function msgCardMasked(senderLabel, timeStr, sideCls, text) {
  return `<div class="msg-card msg-card-masked ${sideCls}">
    <div class="msg-card-head"><span class="msg-sender">${senderLabel}</span><span class="msg-time">${esc(timeStr)}</span></div>
    <div class="msg-masked-body">${esc(text)}</div>
  </div>`;
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

// ── 수동 응대 완료 ──
async function markCurrentResolved() {
  if (!_admMsgAppId) return;
  try {
    await markApplicationResolved(_admMsgAppId);
    toast('응대 완료로 표시했습니다.');
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
