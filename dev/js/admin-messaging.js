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
// ── 서비스 문의(일반 문의, 응모 없음 — 마이그레이션 475~482) ──
//   받은편지함 안 탭 「캠페인 문의 / 서비스 문의」. 서비스 문의는 왼쪽 캠페인 열 없이 **대화 한 줄씩** 2단
//   (여러 대화 — 마이그레이션 504~508, 사양서 docs/specs/2026-10-06-service-inquiry-threads.md 「설계 개정」).
//   🔴 대화 열쇠: 응모건은 _admMsgAppId, 서비스 문의는 _admMsgGeneralThreadId(대화 id) + _admMsgGeneralId(그 대화의
//      회원 id — 첨부 경로 `general/{회원id}/`·숨김 이력·조회 인자용, R-5). 둘은 늘 함께 차고 함께 빈다.
let _inboxKind = 'app';                  // 'app'(캠페인 문의) | 'general'(서비스 문의)
let _genThreads = [];                    // fetchAdminGeneralInquiryThreadRows 결과(대화 한 줄씩)
let _genLoadFailed = false;              // 실패(null)와 0건을 가른다 — 실패면 그 탭에 「불러오지 못했습니다」
let _genUnreadMap = new Map();           // thread_id → 본인 미열람 수
let _genSentAtMap = new Map();           // 'sent' 정렬용 — thread_id → 본인 최신 발신 시각
let _genNeedsReply = null;               // 미응대 대화 수(기간 창 없이 열린 대화 중 needs_reply) — 세 자리 공용. 실패 null
let _genIncludeClosed = false;           // 「닫힘 포함」 — 기본은 열린 대화만
let _genMemberFilter = null;             // 「이 회원 대화 N」 — 그 회원 대화 전부(닫힌 것 포함·기간 무관). null = 전체
let _admMsgGeneralId = null;             // 열린 서비스 문의 대화의 회원 id
let _admMsgGeneralThreadId = null;       // 열린 서비스 문의 대화 id
let _admGenSeenLastId = null;            // 화면이 본 마지막 글(숨김·회수 뺀) id — 닫기 때 서버에 넘긴다
let _inboxWithdrawMap = null;            // 탈퇴 신청 상태(fetchWithdrawalStatesByInfluencer) — 실패 null 이면 표시 안 함

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
  _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
  _genMemberFilter = null;          // 「이 회원 대화」 거름은 페인에 다시 들어오면 푼다
  switchInboxTab(_inboxKind);       // 페인 진입 시 받은편지함(보던 종류) — 이력 탭에 있었어도 받은편지함으로
  // 미응대만 체크박스를 현재 필터 상태와 동기화(배지 클릭 진입 시 시각 반영)
  const _ucb = document.getElementById('inboxUnresolvedCheckbox');
  if (_ucb) _ucb.checked = !!_inboxFilters.unresolvedOnly;
  const wrap = document.getElementById('inboxThreadView');
  if (wrap) wrap.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
  await refreshInboxData();
  updateInboxStage();
}

// 캠페인 영역 확장 — 헤더 클릭 시 캠페인·대화 선택 모두 해제 → updateInboxStage 가 stage-campaigns 로 전환.
//   (사용자: '캠페인 제목 영역 클릭하면 캠페인 영역이 넓어지게')
function setInboxStageCampaigns() {
  _inboxSelectedCampaign = null;
  _admMsgAppId = null; _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
  const v = document.getElementById('inboxThreadView');
  if (v) v.innerHTML = '';
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxStage();
}

// 대화 목록 영역 확장 — 대화 선택만 해제하고 캠페인 선택은 유지 → stage-threads (캠페인 선택 상태일 때만 의미).
function setInboxStageThreads() {
  _admMsgAppId = null; _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
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
  const flat = sentMode || _inboxKind === 'general';   // 서비스 문의는 캠페인이 없어 항상 평면
  pane.classList.toggle('inbox-flat', flat);   // 평면 모드 = 좌측 캠페인 영역 숨김(CSS)
  const threadOpen = _admMsgContext === 'inbox' && (_inboxKind === 'general' ? _admMsgGeneralThreadId : _admMsgAppId);
  if (flat) {
    // 「내가 보낸 순」: 좌측 숨김 → 대화 목록(중)을 넓게, 대화 열면 내용(우)
    pane.classList.add(threadOpen ? 'stage-view' : 'stage-threads');
  } else if (!_inboxSelectedCampaign) pane.classList.add('stage-campaigns');
  else if (!threadOpen) pane.classList.add('stage-threads');
  else pane.classList.add('stage-view');
}

// 뷰 + 본인 미열람 맵을 다시 조회하고 좌/중 패널 재렌더
async function refreshInboxData() {
  try {
    const range = { sinceMonths: _inboxFilters.sinceMonths, fromIso: _inboxFilters.fromIso, toIso: _inboxFilters.toIso };
    // 서비스 문의 목록 조건 — 「이 회원 대화 N」이면 그 회원 전부, 아니면 기간 + 열린 대화(「닫힘 포함」이면 닫힌 것도)
    const genOpts = _genMemberFilter ? { influencerId: _genMemberFilter } : { ...range, includeClosed: _genIncludeClosed };
    const [threads, unreadMap, sentMap, gThreads, gUnread, gSent, wMap, gNeeds] = await Promise.all([
      fetchAdminMessageThreads(range),
      fetchAdminMessageUnreadCounts(),
      (_inboxSort === 'sent') ? fetchAdminSentAtMap() : Promise.resolve(_inboxSentAtMap),
      fetchAdminGeneralInquiryThreadRows(genOpts),
      fetchGeneralInquiryAdminUnreadByThread(),
      (_inboxSort === 'sent') ? fetchAdminGeneralThreadSentAtMap() : Promise.resolve(_genSentAtMap),
      fetchWithdrawalStatesByInfluencer(),
      fetchGeneralInquiryNeedsReplyCount(),
    ]);
    _inboxThreads = threads || [];
    _inboxUnreadMap = unreadMap || new Map();
    _inboxSentAtMap = sentMap || new Map();
    // 서비스 문의 — 실패(null)는 그 탭만 「불러오지 못했습니다」, 캠페인 문의는 그대로 그린다
    _genLoadFailed = gThreads === null;
    _genThreads = gThreads || [];
    _genUnreadMap = gUnread || new Map();
    _genSentAtMap = gSent || new Map();
    if (gNeeds !== null) _genNeedsReply = gNeeds;   // 실패면 지난 값 유지
    _inboxWithdrawMap = wMap;   // null 이면 탈퇴 표시를 안 한다(목록은 막지 않는다)
    // 인플루언서 이름·최근 메시지 미리보기 보강 (병렬) — 두 탭의 회원을 함께
    const inflIds = [...new Set([..._inboxThreads, ..._genThreads].map(t => t.influencer_id).filter(Boolean))];
    const appIds = [...new Set(_inboxThreads.map(t => t.application_id).filter(Boolean))];
    // 서비스 문의 미리보기는 대화 뷰가 마지막 글을 같이 준다(별도 조회 없음)
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
    _genThreads = []; _genLoadFailed = true;
  }
  renderInboxKindTabs();
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxSidebarBadge();
}

// 사이드바 「메시지」 미응대 배지 = 우리 팀 미응대 응모건 수 (그룹 공통)
//   캠페인 문의 + 서비스 문의 합산. 🔴 서비스 문의 몫은 **세 자리**(여기 · 30초 refreshMsgBadgesLight · 탭 괄호
//   renderInboxKindTabs)가 모두 _genNeedsReply(= fetchGeneralInquiryNeedsReplyCount, 기간 창 없음)를 쓴다 —
//   기간·「닫힘 포함」 거름이 걸린 _genThreads 로 세면 30초 뒤 숫자가 되돌아간다(R-4). 사람 수가 아니라 대화 수다
function updateInboxSidebarBadge() {
  const n = _inboxThreads.filter(t => t.unresolved_for_admin_team).length + (_genNeedsReply || 0);
  applyMsgBadgeCount(n);
  renderInboxKindTabs();
}

// 사이드바 메시지 배지 + 브라우저 탭 배지를 동일 미응대 건수로 갱신 (공용 진입점)
function applyMsgBadgeCount(n) {
  const badge = document.getElementById('navMsgBadge');
  if (badge) {
    if (n > 0) { badge.textContent = n > 99 ? '99+' : String(n); badge.style.display = ''; }
    else { badge.style.display = 'none'; }
  }
  updateAdminTabBadge(n);
}

// ── 브라우저 탭 배지 (제목 prefix + favicon 빨간 원) — 받은편지함 안 보고 있을 때 새 문의 인지용 ──
let _tabBadgeBaseTitle = null;      // (N) prefix 를 뺀 원본 제목 ([DEV] 포함 가능)
let _tabBadgeBaseFavicon = null;    // 원본 favicon href

function updateAdminTabBadge(count) {
  const n = count > 0 ? (count > 99 ? '99+' : String(count)) : '';
  // 제목: 기존 (N) prefix 제거 후 재적용 (STAGING 의 [DEV] 등 원본 보존)
  if (_tabBadgeBaseTitle === null) _tabBadgeBaseTitle = document.title.replace(/^\(\d+\+?\)\s*/, '');
  document.title = n ? `(${n}) ${_tabBadgeBaseTitle}` : _tabBadgeBaseTitle;

  // favicon: 우상단 빨간 원 합성 / 0 이면 원본 복원
  const fav = document.getElementById('appFavicon');
  if (fav) {
    if (_tabBadgeBaseFavicon === null) _tabBadgeBaseFavicon = fav.href;
    if (count > 0) drawFaviconWithDot(_tabBadgeBaseFavicon, fav);
    else fav.href = _tabBadgeBaseFavicon;
  }

  // PWA 설치 시 OS 작업표시줄 배지 (미설치자에겐 무영향)
  try {
    if (count > 0 && navigator.setAppBadge) navigator.setAppBadge(count).catch(() => {});
    else if (count <= 0 && navigator.clearAppBadge) navigator.clearAppBadge().catch(() => {});
  } catch (e) { /* 미지원 브라우저 무시 */ }
}

// 원본 favicon(SVG data URI) 위에 우상단 빨간 원을 그려 favicon href 교체
function drawFaviconWithDot(baseHref, favEl) {
  try {
    const img = new Image();
    img.onload = function () {
      try {
        const SZ = 64;
        const cv = document.createElement('canvas');
        cv.width = SZ; cv.height = SZ;
        const ctx = cv.getContext('2d');
        ctx.drawImage(img, 0, 0, SZ, SZ);
        const r = 18;
        ctx.beginPath();
        ctx.arc(SZ - r, r, r, 0, Math.PI * 2);
        ctx.fillStyle = '#e02424';
        ctx.fill();
        ctx.lineWidth = 4; ctx.strokeStyle = '#fff'; ctx.stroke();
        favEl.href = cv.toDataURL('image/png');
      } catch (e) {
        // canvas 오염(SVG tainted) 등으로 toDataURL 실패 시 원본 favicon 명시 복원
        try { favEl.href = baseHref; } catch (_) {}
      }
    };
    img.onerror = function () { /* 로드 실패 시 원본 유지 */ };
    img.src = baseHref;
  } catch (e) { /* 무시 */ }
}

// 30초 폴링 — 받은편지함을 안 보고 있어도 탭/사이드바 배지를 최신 미응대 건수로 갱신
async function refreshMsgBadgesLight() {
  try {
    if (!db) return;
    const [n, g] = await Promise.all([fetchUnresolvedMessageCount(), fetchGeneralInquiryNeedsReplyCount()]);
    if (g !== null) _genNeedsReply = g;   // 실패(null)면 지난 값 — 탭 괄호 숫자와 같은 값을 쓴다
    applyMsgBadgeCount((n || 0) + (_genNeedsReply || 0));
  } catch (e) { /* 무시 */ }
}
let _msgBadgePollingTimer = null;
setTimeout(function () { refreshMsgBadgesLight(); }, 3000);   // 부팅 직후 1회 (DB 준비 후)
if (!_msgBadgePollingTimer) {
  _msgBadgePollingTimer = setInterval(function () { refreshMsgBadgesLight(); }, 30000); // 이후 30초 주기
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
  if (_inboxKind === 'general') { el.innerHTML = ''; return; }   // 평면 모드라 이 열은 숨겨진다
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
    const brand = c ? esc(brandLabelAdmin(c)) : '';
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
  if (_inboxKind === 'general') { renderGeneralThreadList(el); return; }
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
      // 인플 발신 미리보기는 한국어 번역본 우선 (마이그레이션 235 자동 번역)
      const prevSrc = (prev.sender_kind !== 'admin' && prev.translate_status === 'done' && prev.body_translated)
        ? prev.body_translated : prev.body;
      const body = (prevSrc || '').replace(/\s+/g, ' ').trim();
      previewHtml = `<span class="inbox-thread-preview">${esc(who + (body || '(이미지)'))}</span>`;
    }
    // 「내가 보낸 순」은 캠페인 무관 평면이라 카드에 캠페인명·브랜드 라벨 + 시각=본인 발신 시각
    let campLabel = '';
    let timeVal = t.last_message_at;
    if (sentMode) {
      const c = inboxCampaignById(t.campaign_id);
      const ct = c ? (c.title || '(제목 없음)') : '(캠페인)';
      const cb = c ? brandLabelAdmin(c) : '';
      campLabel = `<span class="inbox-thread-camp">${esc(ct)}${cb ? ` · ${esc(cb)}` : ''}</span>`;
      timeVal = _inboxSentAtMap.get(t.application_id) || t.last_message_at;
    }
    return `<button type="button" class="inbox-thread-item ${active}" onclick="openInboxThread('${esc(t.application_id)}')">
      <span class="inbox-thread-main">
        ${campLabel}
        <span class="inbox-thread-name">${kanji}${auditBadgeHtml(inf)}${kana ? `<span class="inbox-thread-kana">${kana}</span>` : ''}</span>
        ${email ? `<span class="inbox-thread-email">${email}</span>` : ''}
        ${previewHtml}
      </span>
      <span class="inbox-thread-right">
        <span class="inbox-thread-time">${esc(formatDateTime(timeVal))}</span>
        <span class="inbox-thread-chips">${inboxWithdrawChip(t.influencer_id)}${unresolved}${unreadChip}</span>
      </span>
    </button>`;
  }).join('');
}

// 탈퇴 표시 — 예정일이 잡힌 회원은 남은 날수, 미지급 대기면 「탈퇴 대기 중」(사양서 §12 ②).
//   확정되면 로그인이 막혀 답을 못 본다 — 그 전에 답하라는 신호. 조회 실패(null)면 아무것도 안 그린다.
function inboxWithdrawChip(influencerId) {
  const w = _inboxWithdrawMap && _inboxWithdrawMap[influencerId];
  if (!w) return '';
  if (w.status === 'scheduled' && w.scheduled_date) {
    const today = new Date(new Date().toLocaleString('en-US', { timeZone: 'Asia/Tokyo' }));
    today.setHours(0, 0, 0, 0);
    const d = Math.round((new Date(w.scheduled_date + 'T00:00:00') - today) / 86400000);
    return `<span class="inbox-thread-chip withdraw" title="탈퇴 예정일 ${esc(w.scheduled_date)}">탈퇴 D-${Math.max(d, 0)}</span>`;
  }
  if (w.status === 'pending_payout') return '<span class="inbox-thread-chip withdraw" title="미지급 보수 정리 뒤 탈퇴 예정">탈퇴 대기 중</span>';
  return '';
}

// ── 서비스 문의 탭 ──
function renderInboxKindTabs() {
  const bar = document.getElementById('inboxKindTabBar');
  if (!bar) return;
  const nApp = _inboxThreads.filter(t => t.unresolved_for_admin_team).length;
  const nGen = _genNeedsReply || 0;   // 세 자리 공용 값(updateInboxSidebarBadge 주석)
  const tab = (key, label, cnt) => {
    const on = _inboxTab === key ? ' on' : '';
    return `<button type="button" class="status-tab-btn${on}" onclick="switchInboxTab('${key}')">${esc(label)}${cnt}</button>`;
  };
  const cnt = (n, failed) => failed ? '<span class="tab-count">(—)</span>' : `<span class="tab-count">(미응대 ${n})</span>`;
  bar.innerHTML = tab('app', '캠페인 문의', cnt(nApp, false))
    + tab('general', '서비스 문의', cnt(nGen, _genNeedsReply === null))
    + (admMsgIsCampaignAdmin() ? tab('broadcasts', '일괄발송 이력', '') : '');
}
// 받은편지함 종류 전환(캠페인 문의 ↔ 서비스 문의) — switchInboxTab 이 부른다
function switchInboxKind(kind) {
  _inboxKind = kind === 'general' ? 'general' : 'app';
  _admMsgAppId = null; _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
  const v = document.getElementById('inboxThreadView');
  if (v) v.innerHTML = '<div class="inbox-empty">대화를 선택하세요.</div>';
  renderInboxKindTabs();
  renderInboxCampaignList();
  renderInboxThreadList();
  updateInboxStage();
}
function filteredGeneralThreads() {
  let list = _genThreads;
  if (_inboxFilters.unresolvedOnly) list = list.filter(t => t.needs_reply);
  if (_inboxSearch) {
    list = list.filter(t => {
      const inf = (_inboxInflMap && _inboxInflMap[t.influencer_id]) || {};
      return [inf.name, inf.name_kana, inf.email, t.title, t.title_translated]
        .filter(Boolean).join(' ').toLowerCase().includes(_inboxSearch);
    });
  }
  return list;
}

// 대화 제목 — 한국어 번역 우선 + 원문 작게. 없으면 「(제목 없음)」(옮겨 온 대화·옛 화면이 만든 대화)
function _admGenTitleHtml(t, cls) {
  const ko = (t.title_translated || '').trim();
  const orig = (t.title || '').trim();
  if (!orig) return `<span class="${cls} adm-gen-title-empty">(제목 없음)</span>`;
  const main = ko || orig;
  const sub = (ko && ko !== orig) ? `<span class="adm-gen-title-orig">${esc(orig)}</span>` : '';
  return `<span class="${cls}">${esc(main)}</span>${sub}`;
}

// 상태 칩 — 「미응대」(운영팀이 답할 차례) / 「회원 답 대기」(열림이고 미응대 아님) / 「닫힘」
function _admGenStatusChip(t) {
  if (t.status !== 'open') return '<span class="inbox-thread-chip closed">닫힘</span>';
  return t.needs_reply ? '<span class="inbox-thread-chip unresolved">미응대</span>'
    : '<span class="inbox-thread-chip waiting">회원 답 대기</span>';
}

// 「닫힘 포함」 토글 · 「이 회원 대화」 거름 해제 — 목록이 바뀌므로 다시 조회한다
function toggleGenIncludeClosed(checked) { _genIncludeClosed = !!checked; refreshInboxData(); }
function filterGenByMember(influencerId) { _genMemberFilter = influencerId || null; refreshInboxData(); }

function renderGeneralThreadList(el) {
  // 머리 줄 — 회원 거름 중이면 그 안내 + 해제, 아니면 「닫힘 포함」
  let head;
  if (_genMemberFilter) {
    const inf = (_inboxInflMap && _inboxInflMap[_genMemberFilter]) || {};
    head = `<div class="adm-gen-listhead"><span>${esc(inf.name || '회원')}님의 대화 전체(닫힌 대화 포함)</span>
      <button type="button" class="adm-gen-link" onclick="filterGenByMember(null)">전체 목록으로</button></div>`;
  } else {
    head = `<div class="adm-gen-listhead"><label><input type="checkbox" ${_genIncludeClosed ? 'checked' : ''}
      onchange="toggleGenIncludeClosed(this.checked)"> 닫힌 대화 포함</label></div>`;
  }
  if (_genLoadFailed) { el.innerHTML = head + '<div class="inbox-empty">서비스 문의를 불러오지 못했습니다.</div>'; return; }
  let list = filteredGeneralThreads();
  const byLast = (a, b) => (b.last_message_at || b.opened_at || '').localeCompare(a.last_message_at || a.opened_at || '');
  if (_inboxSort === 'sent') {
    list = list.filter(t => _genSentAtMap.has(t.thread_id));
    list.sort((a, b) => (_genSentAtMap.get(b.thread_id) || '').localeCompare(_genSentAtMap.get(a.thread_id) || ''));
  } else if (_inboxSort === 'unresolved') {
    list = list.slice().sort((a, b) => (Number(!!b.needs_reply) - Number(!!a.needs_reply)) || byLast(a, b));
  } else {
    list = list.slice().sort(byLast);
  }
  if (!list.length) { el.innerHTML = head + '<div class="inbox-empty">서비스 문의가 없습니다.</div>'; return; }
  el.innerHTML = head + list.map(t => {
    const inf = (_inboxInflMap && _inboxInflMap[t.influencer_id]) || {};
    const kanji = esc(inf.name || '(이름 없음)');
    const unread = _genUnreadMap.get(t.thread_id) || 0;
    const active = t.thread_id === _admMsgGeneralThreadId ? 'active' : '';
    const unreadChip = unread > 0 ? `<span class="inbox-thread-chip unread">${unread > 99 ? '99+' : unread}</span>` : '';
    // 마지막 글 미리보기 — 회원 글은 한국어 번역 우선(번역이 끝났을 때만)
    const lastSrc = (t.last_sender_kind !== 'admin' && t.last_translate_status === 'done' && t.last_message_preview_translated)
      ? t.last_message_preview_translated : t.last_message_preview;
    const who = t.last_sender_kind === 'admin' ? '운영팀: ' : '';
    const previewHtml = t.last_message_at
      ? `<span class="inbox-thread-preview">${esc(who + ((lastSrc || '').trim() || '(이미지)'))}</span>`
      : '<span class="inbox-thread-preview">(표시할 메시지 없음)</span>';
    // 제목이 없으면 첫 글 미리보기를 제목 자리 아래에
    const firstHtml = (!t.title && t.first_message_preview)
      ? `<span class="inbox-thread-preview">${esc(t.first_message_preview)}</span>` : '';
    const nAll = Number(t.influencer_thread_count) || 0;
    const nOpen = Number(t.influencer_open_thread_count) || 0;
    // 「이 회원 대화 N · 열림 M」 — 누르면 그 회원 대화 전부. 줄 열기와 겹치지 않게 전파를 끊는다
    const memberLink = _genMemberFilter ? '' : `<span class="adm-gen-link adm-gen-member" role="button" tabindex="0"
      onclick="event.stopPropagation();filterGenByMember(${jsStr(t.influencer_id)})"
      onkeydown="if(event.key==='Enter'){event.stopPropagation();filterGenByMember(${jsStr(t.influencer_id)})}">이 회원 대화 ${nAll} · 열림 ${nOpen}</span>`;
    const timeVal = (_inboxSort === 'sent' && _genSentAtMap.get(t.thread_id)) || t.last_message_at || t.opened_at;
    return `<button type="button" class="inbox-thread-item ${active}" onclick="openGeneralInboxThread(${jsStr(t.thread_id)})">
      <span class="inbox-thread-main">
        ${_admGenTitleHtml(t, 'adm-gen-title')}
        ${firstHtml}
        <span class="inbox-thread-name">${kanji}${auditBadgeHtml(inf)}</span>
        ${previewHtml}
        ${memberLink}
      </span>
      <span class="inbox-thread-right">
        <span class="inbox-thread-time">${esc(formatDateTime(timeVal))}</span>
        <span class="inbox-thread-chips">${inboxWithdrawChip(t.influencer_id)}${_admGenStatusChip(t)}${unreadChip}</span>
      </span>
    </button>`;
  }).join('');
}

// 서비스 문의 대화 열기(대화 id) — 응모 상태 한 줄·FAQ 열람 이력은 없다(특정 응모가 아니므로).
//   대화 줄은 그 회원의 대화 전부를 다시 받아 찾는다 — 목록 거름(열린 대화만·기간)에 없는 대화(닫은 직후·
//   다른 열린 문의 줄에서 옮겨 감)도 열리고, 「다른 열린 문의」 줄도 같은 조회로 그린다
async function openGeneralInboxThread(threadId) {
  const listRow = _genThreads.find(t => t.thread_id === threadId);
  _admMsgAppId = null;
  _admMsgGeneralThreadId = threadId;
  // 목록에 없는 대화(닫은 직후·「다른 열린 문의」 줄)는 같은 회원에서만 온다 — 회원 id 를 그대로 쓴다.
  //   다른 회원의 대화를 목록 밖에서 열 길을 만들면 회원 id 를 인자로 넘길 것
  _admMsgGeneralId = listRow ? listRow.influencer_id : _admMsgGeneralId;
  _admMsgContext = 'inbox';
  _admMsgPendingFiles = [];
  _admGenSeenLastId = null;
  updateInboxStage();
  renderInboxThreadList();
  const view = document.getElementById('inboxThreadView');
  if (view) view.innerHTML = '<div class="inbox-empty">불러오는 중…</div>';
  const stillHere = () => _admMsgGeneralThreadId === threadId;
  try {
    if (!_admMsgGeneralId) throw new Error('general_inquiry_owner_unknown');
    const memberRows = await fetchAdminGeneralInquiryThreadRows({ influencerId: _admMsgGeneralId });
    if (!stillHere()) return;
    if (memberRows === null) throw new Error('general_inquiry_threads_load_failed');
    const row = memberRows.find(t => t.thread_id === threadId);
    if (!row) { if (view) view.innerHTML = '<div class="inbox-empty">이 문의를 찾을 수 없습니다.</div>'; return; }
    const msgs = await _admFetchCurrent();
    if (!stillHere()) return;
    const closed = row.status !== 'open';
    if (view) view.innerHTML = adminThreadViewHtml('inbox', false, { general: true, closed });
    _admRenderGenHead(row, memberRows);
    renderAdminMsgThread('inboxMsgThread', msgs);
    // 읽음 처리 실패는 대화를 덮지 않는다(이미 그린 대화는 그대로 두고 기록만)
    try {
      await markGeneralInquiryMessagesRead(_admMsgGeneralId, threadId);
      const m = await fetchGeneralInquiryAdminUnreadByThread();
      if (m) _genUnreadMap = m;
      renderInboxThreadList();
    } catch (e2) { console.warn('[openGeneralInboxThread] read', e2); if (typeof logAppError === 'function') logAppError('openGeneralInboxThread.read', e2); }
  } catch (e) {
    console.error('[openGeneralInboxThread]', e);
    if (typeof logAppError === 'function') logAppError('openGeneralInboxThread', e);
    if (view && stillHere()) view.innerHTML = '<div class="inbox-empty">메시지를 불러오지 못했습니다.</div>';
  }
}

// 대화 머리 — 제목(번역 + 원문) · 「제목 수정」 · 같은 회원의 **다른 열린** 문의 줄(같은 질문에 두 번 답하지 않게)
function _admRenderGenHead(row, memberRows) {
  const el = document.getElementById('inboxGenHead');
  if (!el) return;
  const others = (memberRows || []).filter(t => t.status === 'open' && t.thread_id !== row.thread_id);
  const otherHtml = others.length
    ? `<div class="adm-gen-others">이 회원의 다른 열린 문의 ${others.length}건: ${others.map(t =>
        `<button type="button" class="adm-gen-link" onclick="openGeneralInboxThread(${jsStr(t.thread_id)})">${esc((t.title_translated || t.title || t.first_message_preview || '(제목 없음)').trim())}</button>`
      ).join(' ')}</div>` : '';
  el.innerHTML = `<div class="adm-gen-headrow">
      <span class="adm-gen-headtitle">${_admGenTitleHtml(row, 'adm-gen-title')}</span>
      ${_admGenStatusChip(row)}
      <button type="button" class="adm-msg-bar-btn" onclick="editGeneralThreadTitle()">제목 수정</button>
    </div>${otherHtml}`;
  el.style.display = '';
  el.dataset.title = row.title || '';
}

// 서비스 문의 거부 코드(508·505) → 관리자 화면 문구. 모르는 코드면 서버 문구(P0001) 또는 fallback
function _admGenErrorText(e, fallback) {
  const code = String(e?.message || '');
  if (e?.code === 'P0001') {
    if (/new_message_since_view/.test(code)) return '확인한 뒤 회원의 새 글이 도착했습니다. 대화를 다시 불러왔으니 확인 후 다시 눌러 주세요.';
    if (/thread_closed/.test(code)) return '이미 닫힌 문의입니다. 「다시 열기」를 누른 뒤 답장하세요.';
    if (/thread_not_found/.test(code)) return '이 문의를 찾을 수 없습니다.';
    if (/thread_required|no_open_thread/.test(code)) return '답장할 문의를 다시 골라 주세요.';
    if (/title_too_long/.test(code)) return '제목은 40자 이내로 입력하세요.';
    if (e?.message) return e.message;
  }
  return fallback;
}

// 제목 수정(운영팀만, 508) — 빈 값이면 제목·번역을 비운다. 한국어로 고치면 회원 화면에도 한국어로 보인다
async function editGeneralThreadTitle() {
  if (!_admMsgGeneralThreadId) return;
  const threadId = _admMsgGeneralThreadId;
  const cur = document.getElementById('inboxGenHead')?.dataset.title || '';
  const next = prompt('문의 제목(40자 이내, 비우면 제목 없음). 회원 화면에도 이 제목이 그대로 보입니다 — 일본어로 쓰세요.', cur);
  if (next === null) return;
  try {
    await updateGeneralInquiryThreadTitle(threadId, next);
    toast('제목을 저장했습니다. 한국어 번역은 잠시 뒤 채워집니다.');
    await refreshInboxData();
    if (_admMsgGeneralThreadId === threadId) await openGeneralInboxThread(threadId);
  } catch (e) {
    console.error('[editGeneralThreadTitle]', e);
    toast(_admGenErrorText(e, '제목 저장에 실패했습니다.'));
  }
}

// 닫힌 대화 다시 열기(Q-1) — 다른 열린 대화가 있어도 된다(508)
async function reopenCurrentGeneralThread() {
  if (!_admMsgGeneralThreadId) return;
  const threadId = _admMsgGeneralThreadId;
  try {
    await reopenGeneralInquiryThread(threadId);
    toast('문의를 다시 열었습니다.');
    await refreshInboxData();
    if (_admMsgGeneralThreadId === threadId) await openGeneralInboxThread(threadId);
  } catch (e) {
    console.error('[reopenCurrentGeneralThread]', e);
    toast(_admGenErrorText(e, '다시 열기에 실패했습니다.'));
  }
}

// 현재 열린 대화 — 두 종류를 한 자리에서 가른다(답장·회수·숨김·복구·응대완료 공용)
function _admHasThread() { return !!(_admMsgAppId || _admMsgGeneralThreadId); }
async function _admFetchCurrent() {
  if (_admMsgGeneralThreadId) {
    const rows = await fetchGeneralInquiryMessages(_admMsgGeneralId, _admMsgGeneralThreadId);
    if (rows === null) throw new Error('general_inquiry_load_failed');
    // 닫기 때 넘길 「화면이 본 마지막 글」 — 숨김·회수 뺀 것(서버 비교 기준과 같다). 다시 그릴 때마다 갱신
    const visible = rows.filter(m => m.mask_state === 'visible');
    _admGenSeenLastId = visible.length ? visible[visible.length - 1].id : null;
    return rows;
  }
  return await fetchApplicationMessages(_admMsgAppId);
}
function _admThreadElId() { return _admMsgContext === 'inbox' ? 'inboxMsgThread' : 'admMsgThread'; }

// 우: 선택 응모건 대화 내용 (인라인 패널)
async function openInboxThread(applicationId) {
  _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
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

// 사이드바 메시지 배지 클릭 → 「미응대만」 (기준: openDelivPendingReview)
function openMessagesUnresolved() {
  _inboxFilters.unresolvedOnly = true;
  const cb = document.getElementById('inboxUnresolvedCheckbox'); if (cb) cb.checked = true;
  if (typeof navAdminPaneReload === 'function') navAdminPaneReload('messages');
  else { renderInboxCampaignList(); renderInboxThreadList(); }
}
function changeInboxSince(v) {
  const custom = document.getElementById('inboxCustomRange');
  if (v === 'custom') {
    // 「직접 선택」 → 범위 달력 노출. 실제 적용은 시작·끝을 모두 고른 뒤 applyInboxCustomRange
    if (custom) custom.style.display = '';
    setupInboxDateRange();
    return;
  }
  if (custom) custom.style.display = 'none';
  // 다른 기간으로 돌아가면 달력도 비운다 — clear(false) 로 변경 이벤트(재조회)는 일으키지 않는다
  if (_inboxRangeFp) { _inboxRangeFp.clear(false); document.getElementById('inboxDateRange')?.classList.remove('filter-active'); }
  _inboxFilters.sinceMonths = Number(v) || 6;
  _inboxFilters.fromIso = null; _inboxFilters.toIso = null;   // 상대 기간으로 복귀
  refreshInboxData();
}
// 「직접 선택」 범위 달력 mount (1회) — 결과물 관리 setupDelivCertRange 와 같은 옵션
let _inboxRangeFp = null;
function setupInboxDateRange() {
  if (typeof flatpickr === 'undefined') return;
  const el = document.getElementById('inboxDateRange');
  if (!el || _inboxRangeFp) return;
  const fmt = d => d ? `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}` : '';
  _inboxRangeFp = flatpickr(el, {
    mode: 'range',
    dateFormat: 'Y-m-d',
    locale: (flatpickr.l10ns && flatpickr.l10ns.ko) ? 'ko' : 'default',
    showMonths: 1,
    onChange: function(selectedDates) {
      el.classList.toggle('filter-active', selectedDates.length > 0);
      // 시작만 고른 중간 상태에서는 조회하지 않는다(끝까지 고르거나 비웠을 때만)
      if (selectedDates.length === 0 || selectedDates.length === 2) {
        applyInboxCustomRange(fmt(selectedDates[0]), fmt(selectedDates[1]));
      }
    }
  });
}
// 「직접 선택」 적용 — 시작 00:00 ~ 종료 23:59. 둘 다 비면 상대 기간(sinceMonths)으로 돌아간다
function applyInboxCustomRange(f, t) {
  _inboxFilters.fromIso = f ? new Date(f + 'T00:00:00').toISOString() : null;
  _inboxFilters.toIso = t ? new Date(t + 'T23:59:59').toISOString() : null;
  refreshInboxData();
}
function changeInboxSort(v) {
  _inboxSort = (v === 'unresolved') ? 'unresolved' : (v === 'sent') ? 'sent' : 'recent';
  // 「내가 보낸 순」 진입 시 본인 발신 시각 맵을 로드해야 하므로 재조회. 그 외는 재렌더만.
  if (_inboxSort === 'sent') {
    _inboxSelectedCampaign = null;          // 평면 모드 — 캠페인 선택 해제
    if (_admMsgContext === 'inbox') { _admMsgAppId = null; _admMsgGeneralId = null; _admMsgGeneralThreadId = null; }
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
      const bag = [inf.name, inf.name_kana, inf.email, camp && camp.title, camp && (camp.brand_ko || camp.brand), camp && camp.brand_ja, camp && camp.brand_en]
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
  _admMsgGeneralId = null; _admMsgGeneralThreadId = null;
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
//   opts.general: 서비스 문의(받은편지함만) — 머리(제목·다른 열린 문의)는 _admRenderGenHead 가 채운다.
//   opts.closed: 닫힌 서비스 문의 — 「응대 완료」 대신 아무것도, 입력란 대신 「다시 열기」(Q-1)
function adminThreadViewHtml(ctx, isResolved = false, opts) {
  const isGeneral = !!(opts && opts.general);
  const isClosed = isGeneral && !!(opts && opts.closed);
  const threadId = ctx === 'inbox' ? 'inboxMsgThread' : 'admMsgThread';
  const composerId = ctx === 'inbox' ? 'inboxComposer' : 'admComposer';
  const histId = ctx === 'inbox' ? 'inboxHideHist' : 'admHideHist';
  const statusId = ctx === 'inbox' ? 'inboxStatusLine' : 'admStatusLine';
  const faqHistId = ctx === 'inbox' ? 'inboxFaqHist' : 'admFaqHist';
  const histBtn = admMsgIsSuper()
    ? `<button type="button" class="adm-msg-bar-btn" onclick="toggleHideHistory('${ctx}')">숨김 이력</button>` : '';
  // FAQ 열람 이력은 응모 번호로 조회한다 — 서비스 문의에서는 그리지 않는다(작업표 stale 9)
  const faqBtn = isGeneral ? '' : `<button type="button" class="adm-msg-bar-btn" onclick="toggleFaqHistory('${ctx}')">FAQ 열람 이력</button>`;
  // 응대 완료 상태면 버튼을 「완료됨」 비활성으로 렌더 (진입 시 + 클릭 후 즉시 반영 공용)
  //   서비스 문의는 「응대 완료」 = 대화 닫기(확인 창 없음 — 회원이 24시간 안에 쓰면 다시 열린다). 닫힌 대화엔 없다
  const resolveBtn = isClosed ? ''
    : (isResolved && !isGeneral)
    ? `<button type="button" id="${ctx}ResolveBtn" class="adm-msg-bar-btn done" disabled>응대 완료됨</button>`
    : `<button type="button" id="${ctx}ResolveBtn" class="adm-msg-bar-btn primary" onclick="markCurrentResolved()">응대 완료</button>`;
  const genHead = isGeneral ? `<div class="adm-gen-head" id="${ctx}GenHead" style="display:none"></div>` : '';
  const composer = isClosed
    ? `<div class="adm-msg-composer adm-gen-reopen" id="${composerId}">
        <span>닫힌 문의입니다. 답장하려면 다시 여세요.</span>
        <button type="button" class="btn btn-primary" onclick="reopenCurrentGeneralThread()">다시 열기</button>
      </div>`
    : `<div class="adm-msg-composer" id="${composerId}">
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
  return `
    ${genHead}
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
    ${composer}`;
}

// 숨김 이력 패널 토글 (super_admin) — 응모건 단위 audit
async function toggleHideHistory(ctx) {
  const histId = ctx === 'inbox' ? 'inboxHideHist' : 'admHideHist';
  const el = document.getElementById(histId);
  if (!el || !_admHasThread()) return;
  if (el.style.display !== 'none') { el.style.display = 'none'; return; }
  el.style.display = '';
  el.innerHTML = '<div class="msg-empty">불러오는 중…</div>';
  try {
    const rows = _admMsgGeneralId ? await fetchGeneralInquiryHideHistory(_admMsgGeneralId) : await fetchApplicationHideHistory(_admMsgAppId);
    if (rows === null) throw new Error('hide_history_load_failed');
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
  // 🔴 이 줄을 지우면 상태 한 줄이 **빈칸**으로 뜬다 — 표에 없는 열쇠말은 빈 문자열이 되고
  //   화면은 그걸 그대로 그린다. shared.js 의 faqComputeStatus 에 분기를 더할 때는
  //   **반드시 이 표도 함께** 채운다(인플 쪽은 번역 파일, 관리자 쪽은 여기 — 두 벌이다).
  draft_pending: '인플루언서가 올리기만 하고 아직 제출하지 않았습니다.',
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
//   {date} 치환은 인플 측과 동일(영수증·제출기한 모두 제출 마감일).
//   ⚠️ 영수증도 **결과물 제출 마감일**이다(2026-08-11) — 구매 종료일이 아니다.
//      인플루언서 화면(messaging.js)과 반드시 같은 순서를 써야 한다. 어긋나면 관리자와
//      인플루언서가 서로 다른 날짜를 보며 대화하게 된다.
function admStatusLineKo(key, camp) {
  const text = ADM_STATUS_LINE_KO[key] || '';
  if (!text) return '';
  let mmdd = '';
  if (key === 'receipt') mmdd = _admMMDD(camp?.submission_end || camp?.purchase_end);
  else if (key === 'post_deadline') mmdd = _admMMDD(camp?.submission_end);
  return text.replace('{date}', mmdd);
}

// 사이트 공통 표기 YYYY/MM/DD 로 통일 (2026-07-23, 구 MM/DD 축약 폐지)
function _admMMDD(d) {
  return formatDate(d);
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

    // 자동 번역 병기 (마이그레이션 235): 번역본도 esc() 필수(XSS).
    //  - 회원 글·운영팀 글 모두 **원문이 위(본문), 번역이 아래**(2026-10-06 인수인계).
    //  - 라벨은 translated_lang 으로 — ko 「번역」(2026-10-06 사용자 지시 — 짧게) · ja 「일본어 번역(자동)」.
    //    운영팀이 일본어로 쓰면 번역 함수가 한국어 번역을 만든다(그때 회원은 원문을 본다).
    //  - 운영팀 글의 일본어 번역은 회원 화면에 본문으로 나간다 — 그때만 그 안내를 붙인다(실제 전달 문구 검수용)
    let bodyHtml;
    const hasTrans = msg.body_translated && msg.translate_status === 'done';
    if (hasTrans) {
      const origHtml = esc(msg.body || '').replace(/\n/g, '<br>');
      const transHtml = esc(msg.body_translated).replace(/\n/g, '<br>');
      const transLabel = msg.translated_lang === 'ja' ? '일본어 번역(자동)' : '번역';
      const caption = (fromAdmin && msg.translated_lang === 'ja')
        ? '<div class="msg-trans-caption">인플루언서 화면에는 이 일본어 번역이 본문으로 표시됩니다</div>' : '';
      bodyHtml = `${origHtml}
        <div class="msg-trans-orig"><span class="msg-trans-label">${transLabel}</span>${transHtml}</div>${caption}`;
    } else {
      bodyHtml = esc(msg.body || '').replace(/\n/g, '<br>');
    }
    const atts = Array.isArray(msg.attachments) ? msg.attachments : [];
    let attachHtml = '';
    if (atts.length) {
      attachHtml = `<div class="msg-attachments">${atts.map((a, i) => {
        // 파기된 첨부(작업 12-B) — 주소가 없다.
        //   ⚠️ **썸네일을 부르지도, 클릭을 붙이지도 않는다.** 예전에는 주소가 비면
        //      빈 문자열로 확대를 열어 「이미지를 불러오지 못했습니다」가 떴는데,
        //      그건 통신 장애·권한 문제일 때와 **글자 하나 다르지 않다.** 담당자가
        //      6개월 지난 대화를 열어 보고 고장으로 오해하게 된다.
        if (msgAttachmentPurged(a)) {
          return `<div class="msg-attach-thumb purged" title="보관기간이 지나 파기됨"><span class="material-icons-round notranslate" translate="no">delete_forever</span><span>보관기간이 지나<br>파기됨</span></div>`;
        }
        const elId = `admatt-${msg.id}-${i}`;
        loadAdmMsgAttachThumb(elId, a.path);
        return `<div class="msg-attach-thumb" id="${elId}" onclick="openAdmMsgLightbox(${jsStr(a.path)})"><span class="material-icons-round notranslate" translate="no">image</span></div>`;
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
        // 운영팀 발신 + **내가 보낸 것** + 25분 이내 → 회수
        //   ⚠️ 예전에는 「운영팀 발신」만 봤다. 그래서 **다른 관리자 메시지에도 버튼이 뜨고,
        //   누르면 서버가 본인이 아니라며 거부**했다(일본어 오류가 한국어 화면에 노출).
        //   판정 값 `sender_id` 는 마이그레이션 326 이 조회에 추가했다(관리자에게만 채워진다).
        //   ⚠️ 일괄 발송 회수(아래 `canWithdraw`)에는 최고 관리자 예외가 있지만 **여기엔 넣지 마라** —
        //   개별 회수 함수(`withdraw_own_message`)에는 그 예외가 없어, 버튼만 뜨고 또 실패한다.
        //   ⚠️ `sender_id` 가 비어 있으면(마이그레이션 326 적용 전) 버튼을 안 그린다 —
        //   누구 것인지 모르는 채 그리면 예전 상태로 돌아간다.
        const isMine = !!msg.sender_id && msg.sender_id === currentAdminInfo?.auth_id;
        const elapsed = now - new Date(msg.created_at).getTime();
        if (isMine && elapsed < ADM_MSG_WITHDRAW_LIMIT_MS) {
          const pathsJson = esc(JSON.stringify(atts.map(a => a.path)));
          actions += `<button type="button" class="adm-msg-act withdraw" onclick='confirmAdmWithdraw("${esc(msg.id)}", ${pathsJson})'>회수</button>`;
        }
      } else if (admMsgIsCampaignAdmin()) {
        // 인플루언서 메시지 → campaign_admin+ 강제 숨김. 매니저에게는 안 그린다(누르면 서버가 거절만 한다)
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
    ? _admMsgCurrentMsgs.filter(m =>
        (m.body || '').toLowerCase().includes(q) ||
        (m.body_translated || '').toLowerCase().includes(q))  // 한국어 번역본으로도 검색 (235)
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
  if (_admMsgSending || !_admHasThread()) return;
  const inputEl = document.getElementById(curComposerId() + 'Input');
  const body = (inputEl?.value || '').trim();
  if (!body && !_admMsgPendingFiles.length) { toast('메시지를 입력하세요.'); return; }
  _admMsgSending = true;
  try {
    const attachments = [];
    for (const f of _admMsgPendingFiles) {
      try {
        // 서비스 문의 첨부는 그 회원의 폴더(general/{회원id}/) — 서버가 경로 접두를 검사한다
        attachments.push(_admMsgGeneralId
          ? await uploadGeneralInquiryAttachment(f, _admMsgGeneralId)
          : await uploadMessageAttachment(f, _admMsgAppId));
      }
      catch (e) {
        console.error('[sendAdminMessage] 첨부', e);
        toast(e?.message === 'too_large' ? '이미지 용량이 큽니다.' : '첨부 업로드에 실패했습니다.');
        _admMsgSending = false; return;
      }
    }
    // 서비스 문의 답장은 **항상 대화 id** 를 넘긴다(508 — 없으면 열린 대화가 둘 이상인 회원에서 thread_required)
    if (_admMsgGeneralThreadId) await sendGeneralInquiryMessage(body, attachments, _admMsgGeneralId, _admMsgGeneralThreadId);
    else await sendApplicationMessage(_admMsgAppId, body, attachments);
    if (inputEl) inputEl.value = '';
    _admMsgPendingFiles = [];
    renderAdmMsgAttachPreview();
    const msgs = await _admFetchCurrent();
    renderAdminMsgThread(_admThreadElId(), msgs);
    // 관리자 답장 = 자동 응대 완료 → 받은편지함 집계 갱신
    if (_admMsgContext === 'inbox') await refreshInboxData();
    else updateInboxSidebarBadge();
  } catch (e) {
    console.error('[sendAdminMessage]', e);
    toast(_admMsgGeneralThreadId ? _admGenErrorText(e, '전송에 실패했습니다.')
      : (e?.code === 'P0001' && e?.message ? e.message : '전송에 실패했습니다.'));
  } finally {
    _admMsgSending = false;
  }
}

// ── 본인(관리자) 회수 ──
async function confirmAdmWithdraw(messageId, attachmentPaths) {
  if (!confirm('이 메시지를 회수하시겠습니까?')) return;
  try {
    await withdrawOwnMessage(messageId, attachmentPaths || []);
    const msgs = await _admFetchCurrent();
    renderAdminMsgThread(_admThreadElId(), msgs);
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
    const msgs = await _admFetchCurrent();
    renderAdminMsgThread(_admThreadElId(), msgs);
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
    const msgs = await _admFetchCurrent();
    renderAdminMsgThread(_admThreadElId(), msgs);
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
  if (!_admHasThread()) return;
  if (_admMsgGeneralThreadId) { await closeCurrentGeneralThread(); return; }
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

// 서비스 문의 「응대 완료」 = 대화 닫기(505). 화면이 본 마지막 글 id 를 넘겨, 그 뒤 회원 글이 왔으면 서버가 거부한다
//   (new_message_since_view → 대화를 다시 불러와 보여 준다). 닫힌 뒤에는 입력란 대신 「다시 열기」로 다시 그린다
async function closeCurrentGeneralThread() {
  const threadId = _admMsgGeneralThreadId;
  try {
    await closeGeneralInquiryThread(threadId, _admGenSeenLastId);
    toast('응대 완료(문의 닫힘)로 표시했습니다.');
  } catch (e) {
    console.error('[closeCurrentGeneralThread]', e);
    toast(_admGenErrorText(e, '처리에 실패했습니다.'));
  }
  // 성공·거부 모두 목록과 대화를 다시 그린다(거부면 새 글을 보여 주고, 이미 닫혔으면 닫힌 화면으로)
  await refreshInboxData();
  if (_admMsgGeneralThreadId === threadId) await openGeneralInboxThread(threadId);
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
  // 아이콘 전용 — 이름 칸 오른쪽 끝에 놓이므로 글자 없이 아이콘 하나(뜻은 title·aria-label 로)
  const label = unread > 0 ? `메시지 (읽지 않음 ${unread}건)` : '메시지';
  return `<button type="button" class="applicant-msg-btn" title="${esc(label)}" aria-label="${esc(label)}" data-msgbtn="${esc(app.id)}"
    onclick="openAdminMessageModal('${esc(app.id)}','${esc(app.campaign_id || '')}')">
    <span class="material-icons-round notranslate" translate="no">forum</span>${badge}</button>`;
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
  const label = {draft:'준비', scheduled:'모집예정', active:'모집중', closed:'모집마감', ended:'종료', expired:'노출종료'}[s];
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
let _inboxTab = 'app';   // 탭 한 줄의 상태 — 'app'(캠페인 문의) | 'general'(서비스 문의) | 'broadcasts'(일괄발송 이력)
// ⚠️ 이력을 단추로 옮겼다가 탭으로 되돌렸다(2026-09-29 사용자 결정 — 탭이 더 낫다)

// campaign_admin 이상만 일괄 발송 버튼·발송이력 탭 노출
function admMsgIsCampaignAdmin() {
  return typeof currentAdminInfo !== 'undefined'
    && (currentAdminInfo?.role === 'super_admin' || currentAdminInfo?.role === 'campaign_admin');
}
// 「일괄 발송」 — 캠페인 한 건의 응모건이 대상(resolve_bulk_recipients)이라 캠페인 문의 탭에서만(조각 6-B)
function applyBulkMsgButtonVisibility() {
  const btn = document.getElementById('bulkMsgOpenBtn');
  if (btn) btn.style.display = (admMsgIsCampaignAdmin() && _inboxTab === 'app') ? 'inline-flex' : 'none';
}

// 탭 전환 — 캠페인 문의 / 서비스 문의 / 일괄발송 이력
function switchInboxTab(tab) {
  if (tab === 'broadcasts' && !admMsgIsCampaignAdmin()) tab = 'app';
  _inboxTab = (tab === 'general' || tab === 'broadcasts') ? tab : 'app';
  const isList = _inboxTab !== 'broadcasts';
  const main = document.getElementById('inboxMainView');
  const bc = document.getElementById('inboxBroadcastsView');
  const filters = document.getElementById('inboxFilterRow');
  if (main) main.style.display = isList ? '' : 'none';
  if (bc) bc.style.display = isList ? 'none' : '';
  if (filters) filters.style.display = isList ? 'flex' : 'none';   // 이력 탭에서는 거르기가 없다
  // 「날짜 직접 선택」 칸은 기간에서 「직접 선택」을 골랐을 때만(changeInboxSince 와 같은 기준)
  const custom = document.getElementById('inboxCustomRange');
  if (custom) custom.style.display = (document.getElementById('inboxSinceSelect')?.value === 'custom') ? '' : 'none';
  const search = document.getElementById('inboxSearchInput');
  if (search) search.placeholder = _inboxTab === 'general' ? '인플루언서명 · 문의 제목 검색' : '인플루언서명 · 캠페인명 검색';
  applyBulkMsgButtonVisibility();
  if (isList) switchInboxKind(_inboxTab);
  else { renderInboxKindTabs(); loadBroadcasts(); }
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
    _bulkState.hasNonMonitor = false;
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
    // 완전 승인 토글·타입혼합 배너 초기화 (모달 재오픈 시 이전 상태 잔존 방지)
    const fa = document.getElementById('bulkFullApproved'); if (fa) fa.checked = false;
    const mix = document.getElementById('bulkTypeMixNote'); if (mix) mix.style.display = 'none';
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
  // 리뷰어(monitor)와 기프팅·방문형이 섞였는지 — 영수증 필터 타입혼합 안내 배너 노출 판정
  _bulkState.hasNonMonitor = campaignIds.some(cid => {
    const c = camps.find(x => x.id === cid);
    return c && c.recruit_type !== 'monitor';
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

// 조건 스냅샷의 판(version).
//   🔴 **아래 `collectBulkFilters` 의 열쇠말 목록을 고치면 이 숫자를 올릴 것.**
//      자동으로 안 된다. 안 올리면 옛 이력의 조건이 **조용히 잘못 재현된다** —
//      오류가 아니라 「조건이 다른데 같다고 우기는 발송」이 나간다.
//   ⚠️ 이 표시가 없는 옛 이력은 **판 0** 으로 본다. 판 0 은 막지 않기로 했지만
//      (2026-08-27 결정), **모르는 판이면 막는다**는 장치는 반드시 살아 있어야 한다 —
//      그것마저 풀면 판 표시가 아무 일도 안 하게 된다.
const BULK_FILTER_VERSION = 1;

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
    v: BULK_FILTER_VERSION,   // [1단계] 이 스냅샷이 어느 판의 열쇠말로 만들어졌나
    appStatuses, receiptStatuses, postStatuses, channels, prefectures,
    followerMode, followerChannel, minFollowers: mf,
    requireVerified: document.getElementById('bulkInflVerified')?.checked || false,
    excludeViolation: document.getElementById('bulkInflNoViolation')?.checked || false,
    excludeBlacklist: document.getElementById('bulkInflNoBlacklist')?.checked !== false,
    // 완전 승인만(부분 승인 제외) — 승인 응모 포함 시에만 의미. 통합 토글 1개가 영수증·게시물 함께 적용
    fullApproved: approved ? (document.getElementById('bulkFullApproved')?.checked || false) : false,
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
  // 타입혼합 안내 배너 — 리뷰어 + 기프팅·방문형이 섞였을 때(영수증 조건이 일부 신청건에만 적용됨)
  const mixNote = document.getElementById('bulkTypeMixNote');
  if (mixNote) mixNote.style.display = (approved && _bulkState && _bulkState.hasMonitor && _bulkState.hasNonMonitor) ? '' : 'none';
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
    // 사람 수(distinct user) — 동일인이 여러 신청건으로 중복되므로 「건」과 별도 표기.
    // 실패해도 발송엔 지장 없으므로 건수로 폴백.
    let people = ids.length;
    try { people = await countDistinctUsersForApps(ids); } catch (_e) { people = ids.length; }
    if (JSON.stringify(_bulkState.campaignIds) !== JSON.stringify(campaignIds)) return;
    _bulkState.recipientPeople = people;
    updateBulkCount(ids.length, people);
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

// n = 신청건 수(발송 통 수 — 동일인 여러 건이면 각 건마다 1통), people = 도달 인원(distinct user).
function updateBulkCount(n, people) {
  const ppl = (people != null) ? people : n;
  const el = document.getElementById('bulkCount'); if (el) el.textContent = n;            // 건수
  const elp = document.getElementById('bulkCountPeople'); if (elp) elp.textContent = ppl;  // 사람 수
  // STEP 2: 실제 발송 통 수 = 신청건 수(n). 사람 수(ppl)는 괄호로 병기.
  const el2 = document.getElementById('bulkCount2'); if (el2) el2.textContent = n;
  const el2p = document.getElementById('bulkCount2People'); if (el2p) el2p.textContent = ppl;
}

function bulkStepNext() {
  if (!_bulkState || !_bulkState.recipientIds.length) { toast('대상이 없습니다.'); return; }
  if (_bulkState.recipientIds.length > BULK_MAX) {
    toast(`1회 최대 ${BULK_MAX}건까지 발송할 수 있습니다. 필터로 범위를 좁혀주세요.`); return;
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
    toast(`${ids.length}건 발송했습니다.`);
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
// ── 발송 조건을 사람 말로 (2단계) ──────────────────────────
//   저장은 예전부터 되고 있었는데 **어느 화면도 안 그렸다**(목록은 캠페인 개수만 센다).
//   「같은 조건으로 다시」를 누르라면서 그 조건이 뭔지 안 보여주면
//   **무엇을 보내는지 모르고 누른다.** 추가 발송과 무관하게 그 자체로 쓸모가 있다.
//
//   ⚠️ 이름표는 **위에서 쓰는 상수를 그대로 쓴다**(`BULK_APP_STATUSES` 등).
//      두 벌이 되면 고르는 화면과 보여 주는 화면이 다른 말을 한다.

// 🔴 이 문구는 3단계의 버튼 안내(㉮)와 **같은 자리에서 온다.** 두 곳에 따로 쓰지 않는다.
const BULK_NO_FILTER_NOTE = '직접 고른 발송이라 저장된 조건이 없습니다';

function _bulkLabels(codes, table) {
  const list = Array.isArray(codes) ? codes : [];
  return list.map(c => (table.find(x => x.code === c) || {}).label || c);
}

function broadcastFilterSummaryHtml(b) {
  const 상자 = (내용) => `<div style="background:var(--bg);border-radius:10px;padding:10px 12px;font-size:12px;line-height:1.8;color:var(--ink)">${내용}</div>`;
  const 안내 = (문구) => 상자(`<span style="color:var(--muted)">${esc(문구)}</span>`);

  // 조건을 모을 수 없는 두 갈래 — 빈 자리로 두면 「고장났나」로 읽힌다.
  if (b.context_kind !== 'campaign') return 안내(BULK_NO_FILTER_NOTE);
  const f = b.context_filter;
  if (!f || typeof f !== 'object') return 안내('저장된 조건이 없습니다');

  const 줄 = [];
  const 더하기 = (이름, 값) => { if (값) 줄.push(`<div><span style="color:var(--muted)">${esc(이름)}</span> ${값}</div>`); };

  const 캠수 = Array.isArray(f.campaign_ids) ? f.campaign_ids.length : (b.context_campaign_id ? 1 : 0);
  더하기('캠페인', 캠수 ? `${캠수}개` : '');

  더하기('응모 상태', esc(_bulkLabels(f.appStatuses, BULK_APP_STATUSES).join(' · ')));
  더하기('영수증 상태', esc(_bulkLabels(f.receiptStatuses, BULK_DELIV_STATUSES).join(' · ')));
  더하기('결과물 상태', esc(_bulkLabels(f.postStatuses, BULK_DELIV_STATUSES).join(' · ')));
  if (f.fullApproved) 더하기('승인 범위', '완전 승인만(부분 승인 제외)');

  // ⚠️ **고르는 화면의 네 채널이 전부가 아니다** — 옛 이력에 `qoo10` 같은 코드가 실제로 들어
  //    있다(개발서버 실측). 못 찾으면 공용 이름표로 받치고, 그것도 없을 때만 코드를 보여준다.
  //    받침이 없으면 운영자에게 「qoo10」 같은 날코드가 그대로 보인다.
  const 채널이름 = (c) => {
    const 표 = BULK_SNS_CHANNELS.find(([code]) => code === c);
    if (표) return 표[1];
    if (typeof getChannelLabel === 'function') return getChannelLabel(c, 'ko') || c;
    return c;
  };
  const 채널 = (Array.isArray(f.channels) ? f.channels : []).map(채널이름);
  더하기('SNS 채널', esc(채널.join(' · ')));

  // 도도부현은 많으면 줄이 길어진다 — 앞 몇 개만 적고 **나머지 개수를 반드시 말한다**
  //   (「…」로만 끝내면 몇 개인지 모른다).
  const 지역맵 = (typeof PREFECTURE_KO !== 'undefined') ? PREFECTURE_KO : {};
  const 지역 = (Array.isArray(f.prefectures) ? f.prefectures : []).map(p => 지역맵[p] || p);
  if (지역.length) {
    더하기('지역', 지역.length <= 5
      ? esc(지역.join(' · '))
      : `${esc(지역.slice(0, 5).join(' · '))} <span style="color:var(--muted)">외 ${지역.length - 5}곳</span>`);
  }

  // ⚠️ `minFollowers` 는 빈 문자열로 저장된다(실측) — `Number('')` 이 0 이라 걸러진다.
  const 하한 = Number(f.minFollowers);
  if (하한 > 0) {
    더하기('팔로워', f.followerMode === 'sum'
      ? `4개 채널 합산 ${하한.toLocaleString()}명 이상`
      : `${esc(채널이름(f.followerChannel))} ${하한.toLocaleString()}명 이상`);
  }

  const 제외 = [];
  if (f.requireVerified) 제외.push('인증 회원만');
  if (f.excludeViolation) 제외.push('위반 이력 제외');
  if (f.excludeBlacklist !== false) 제외.push('블랙리스트 제외');
  더하기('회원 조건', esc(제외.join(' · ')));

  // 아무 조건도 안 건 발송 — 빈 상자로 두지 않는다.
  if (!줄.length) return 안내('따로 건 조건 없이 그 캠페인 전체에 보냈습니다');
  return 상자(줄.join(''));
}

// ── 추가 발송 (3단계) ──────────────────────────────────────
//   「같은 조건으로, 아직 안 받은 사람에게만」. 사양서 설계 5-2·5-3·5-4.

// 판(version) — 이 판까지만 조건을 그대로 재현할 수 있다.
//   ⚠️ 판 0(표시가 없는 옛 이력)은 **막지 않는다**(2026-08-27 결정) — 그때 열쇠말이
//      지금과 같았다는 가정 위에 있다. 🔴 **「모르는 판이면 막는다」는 반드시 살아 있어야 한다**
//      — 그것마저 풀면 판 표시가 아무 일도 안 하게 된다.
const BULK_FILTER_VERSION_MAX = BULK_FILTER_VERSION;

// 버튼을 누를 수 있나 — **안 되면 감추지 않고 회색으로 두고 이유를 말한다.**
//   감추면 「왜 어떤 발송엔 있고 어떤 발송엔 없나」를 아무도 모른다.
//   🔴 네 조건을 하나로 뭉치지 않는다 — 이유를 말할 수 없게 된다.
function bulkFollowupState(b) {
  // ㉮ 조건 발송인가 — 조건이 아예 없으면 보낼 인자를 만들 수 없다(서버까지 못 간다)
  if (!b || b.context_kind !== 'campaign') return { ok: false, why: BULK_NO_FILTER_NOTE };
  if (!b.context_filter || typeof b.context_filter !== 'object') {
    return { ok: false, why: '저장된 조건이 없어 같은 조건으로 다시 보낼 수 없습니다' };
  }
  // ㉯ 회수되지 않았나 — 회수된 발송에 이어 보내는 것은 **가린 내용을 새로 퍼뜨리는** 일이다
  if (b.withdrawn_at) return { ok: false, why: '회수된 발송입니다' };

  // ㉱ 판을 아는 판인가 — 판 0(표시 없음)은 통과, **모르는 판만** 막는다
  const v = Number(b.context_filter.v) || 0;
  if (v > BULK_FILTER_VERSION_MAX) {
    return { ok: false, why: '그때와 조건 저장 방식이 달라져 그대로 재현할 수 없습니다' };
  }

  // ㉰ 그 사슬의 마지막인가 (회수된 것은 건너뛰고 셈 — 서버 거부 ②와 같은 사실)
  const c = b.chain || {};
  if (c.has_live_descendant) {
    // 🔴 링크는 **따라가면 반드시 누를 수 있을 때만** 준다.
    //    최고 관리자가 남의 사슬에 이어 보내면 그 관리자는 영영 못 잇는다 —
    //    그때 링크를 주면 **못 여는 링크**가 된다. 할 수 있는 일을 말한다.
    return c.last_live_visible
      ? { ok: false, why: '이미 추가 발송이 있습니다 — 가장 마지막 것에서 이어 보내세요', gotoId: c.last_live_id }
      : { ok: false, why: '다른 관리자가 이어 보냈습니다 — 그 관리자에게 요청하세요' };
  }
  return { ok: true };
}

function broadcastFollowupRowHtml(b) {
  const s = bulkFollowupState(b);
  // ⚠️ **`btn` 단독은 이 저장소에서 아무 모습도 없다**(배경·테두리 0) — 종류를 반드시 붙인다.
  //    안 붙이면 글씨만 떠 있어 **버튼인 줄 모른다**(개발서버 화면에서 실제로 그랬다).
  //    본문 안 동작이라 `btn-ghost`(테두리형). 이 창의 주 동작은 아래쪽 「전체 회수」다.
  const 클래스 = 'btn btn-ghost btn-sm';
  if (s.ok) {
    return `<div style="margin-top:4px"><button class="${클래스}" onclick="openBulkFollowup()">아직 안 받은 대상에게 추가 발송</button></div>`;
  }
  // 못 눌러도 **감추지 않는다** — 회색 + 이유. 링크는 따라가면 반드시 열리는 경우에만.
  const 링크 = s.gotoId
    ? ` <a href="javascript:void(0)" onclick="openBroadcastDetail('${esc(s.gotoId)}')" style="color:var(--pink)">그 발송 열기</a>` : '';
  return `<div style="margin-top:4px">
    <button class="${클래스}" disabled style="opacity:.45;cursor:not-allowed">아직 안 받은 대상에게 추가 발송</button>
    <div style="font-size:11px;color:var(--muted);margin-top:4px">${esc(s.why)}${링크}</div>
  </div>`;
}

// ── 관리자 전용 제목 고치기 (마이그레이션 393) ──────────────────────────────
//   ⚠️ 제목이 없을 때도 줄을 그린다 — 안 그리면 **이름을 처음 붙일 자리가 없다**
//      (제목은 보낼 때 비워 둘 수 있으므로 「없음」이 흔한 정상 상태다).
//   ⚠️ 권한은 일괄 발송과 같은 조건. 없으면 단추를 아예 안 그린다 —
//      눌러 보고 나서 권한 오류를 보는 것이 이 저장소가 피하려는 패턴이다.
function broadcastTitleRowHtml(id, title) {
  const 고칠수있나 = (typeof isCampaignAdminOrAbove === 'function') && isCampaignAdminOrAbove();
  const 이름 = title
    ? `<span style="font-weight:700;font-size:14px;color:var(--ink)">${esc(title)}</span>
       <span style="font-weight:400;font-size:11px;color:var(--muted)">(관리자 전용 제목)</span>`
    : `<span style="font-size:13px;color:var(--muted)">관리자 전용 제목 없음</span>`;
  const 단추 = 고칠수있나
    ? `<button class="btn btn-ghost btn-xs" style="padding:2px 8px;font-size:11px"
         onclick="startBroadcastTitleEdit('${esc(id)}')">${title ? '이름 바꾸기' : '이름 붙이기'}</button>`
    : '';
  return `<div id="bcastTitleRow" style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">${이름}${단추}</div>`;
}

function startBroadcastTitleEdit(id) {
  const 줄 = document.getElementById('bcastTitleRow');
  if (!줄) return;
  const 지금 = (_broadcastRows.find(x => x.id === id) || {}).title || '';
  줄.innerHTML = `
    <input type="text" id="bcastTitleInput" class="admin-filter" maxlength="100"
      style="flex:1;min-width:180px" placeholder="예: 5월 결과물 미제출자 리마인드"
      onkeydown="if(event.key==='Enter'){saveBroadcastTitle('${esc(id)}')}if(event.key==='Escape'){cancelBroadcastTitleEdit('${esc(id)}')}">
    <button class="btn btn-primary btn-xs" style="padding:3px 10px;font-size:11px"
      onclick="saveBroadcastTitle('${esc(id)}')">저장</button>
    <button class="btn btn-ghost btn-xs" style="padding:3px 10px;font-size:11px"
      onclick="cancelBroadcastTitleEdit('${esc(id)}')">취소</button>`;
  const 칸 = document.getElementById('bcastTitleInput');
  // ⚠️ 값은 esc() 로 넣지 않는다 — 입력칸 value 는 HTML 이 아니라 글자 그대로다.
  //    esc() 를 쓰면 따옴표가 든 제목이 &quot; 로 보인다.
  칸.value = 지금;
  칸.focus();
  칸.select();
}

function cancelBroadcastTitleEdit(id) {
  const 줄 = document.getElementById('bcastTitleRow');
  if (!줄) return;
  const 지금 = (_broadcastRows.find(x => x.id === id) || {}).title;
  줄.outerHTML = broadcastTitleRowHtml(id, 지금);
}

async function saveBroadcastTitle(id) {
  const 칸 = document.getElementById('bcastTitleInput');
  if (!칸) return;
  const 값 = 칸.value;
  칸.disabled = true;
  try {
    const 저장된 = await updateBroadcastTitle(id, 값);
    // 🔴 목록 캐시를 함께 갱신한다 — 상세 모달이 제목을 **이 캐시에서** 읽으므로,
    //    안 고치면 창을 다시 열었을 때 옛 이름이 돌아온다.
    const 행 = _broadcastRows.find(x => x.id === id);
    if (행) 행.title = 저장된;
    const 줄 = document.getElementById('bcastTitleRow');
    if (줄) 줄.outerHTML = broadcastTitleRowHtml(id, 저장된);
    toast(저장된 ? '제목을 바꿨습니다' : '제목을 지웠습니다');
    await loadBroadcasts();     // 뒤의 목록도 새 이름으로
  } catch (e) {
    console.error('[saveBroadcastTitle]', e);
    칸.disabled = false;
    // ⚠️ 오류 **객체**를 넘기면 앞에 「PostgrestError: 」 가 붙는다.
    //    서버가 한글로 던지는 거부 문구(「제목은 100자까지입니다」)를 그대로 보이게 메시지만 넘긴다.
    toast(friendlyError(e?.message || e));
  }
}

// ── 발송 목록 — 캠페인별로 골라 보기 ────────────────────────────────────────
//   ⚠️ 묶는 기준은 **캠페인 고유번호**(마이그레이션 391). 제목으로 묶으면 복제 캠페인처럼
//      제목이 같은 두 캠페인이 한 덩어리가 된다.
let _bcastRecipCamp = '';   // '' = 전체

// 그 발송에 실제로 들어 있는 캠페인을, 목록에 나온 차례대로 센다.
function broadcastRecipCampaigns(recips) {
  const 본것 = {}; const 순서 = [];
  (recips || []).forEach(r => {
    const id = r.campaign_id || '';
    if (!본것[id]) { 본것[id] = { id, 제목: r.campaign_title || '(캠페인 없음)', 수: 0 }; 순서.push(본것[id]); }
    본것[id].수++;
  });
  return 순서;
}

function broadcastRecipCampSelectHtml(recips) {
  const 캠 = broadcastRecipCampaigns(recips);
  // 캠페인이 하나뿐이면 고를 것이 없다 — 안 그린다(0이면 안 그린다 원칙)
  if (캠.length < 2) return '';
  const 옵션 = [`<option value="">전체 (${recips.length}명)</option>`]
    .concat(캠.map(c => `<option value="${esc(c.id)}">${esc(c.제목)} (${c.수}명)</option>`));
  return `<select class="admin-filter" id="bcastRecipCampSel" style="width:100%"
    onchange="filterBroadcastRecips(this.value)">${옵션.join('')}</select>`;
}

function filterBroadcastRecips(campId) {
  _bcastRecipCamp = campId || '';
  renderBroadcastRecipList();
}

function renderBroadcastRecipList() {
  const 칸 = document.getElementById('bcastRecipList');
  const 머리 = document.getElementById('bcastRecipHead');
  if (!칸) return;
  const 전부 = (_curBroadcastDetail && _curBroadcastDetail.recipients) || [];
  const 보일것 = _bcastRecipCamp ? 전부.filter(r => (r.campaign_id || '') === _bcastRecipCamp) : 전부;
  if (머리) {
    // 걸러 보고 있으면 전체 수도 함께 — 안 그러면 「9명 발송인데 4명뿐」으로 읽힌다
    const 꼬리 = _bcastRecipCamp
      ? `· ${보일것.length}명 <span style="font-weight:400;color:var(--muted)">/ 전체 ${전부.length}명</span>`
      : `· ${전부.length}명`;
    머리.innerHTML = `발송 목록 <span style="font-weight:400">${꼬리}</span>`;
  }
  칸.innerHTML = 보일것.length
    ? 보일것.map(r => `<div class="broadcast-recip" onclick="gotoBroadcastRecipMessage('${esc(r.application_id)}')">
        <span class="broadcast-recip-name">${esc(r.influencer_name || '(인플루언서)')}</span>
        <span class="broadcast-recip-camp">${esc(r.campaign_title || '')}</span>
        <span class="broadcast-recip-status">${r.read ? '읽음' : '미읽음'}${r.replied ? ' · 답장' : ''}</span>
      </div>`).join('')
    : `<div style="padding:10px;font-size:12px;color:var(--muted)">${_bcastRecipCamp ? '이 캠페인으로 받은 사람이 없습니다' : '받은 사람이 없습니다'}</div>`;
  칸.scrollTop = 0;
}

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
  const titleHtml = broadcastTitleRowHtml(id, cachedTitle);
  // 2단 — 왼쪽 「발송 정보」 / 오른쪽 「발송 목록」.
  //   ⚠️ 회수 배너와 제목은 칸 밖(위)에 둔다. 한쪽 칸에 넣으면 스크롤에 딸려 사라지는데,
  //      「회수됨」은 그 발송을 볼 때 늘 보여야 하는 사실이다.
  _bcastRecipCamp = '';   // 창을 새로 열 때마다 「전체」로 되돌린다
  body.innerHTML = `
    ${withdrawnBanner}
    ${titleHtml}
    <div class="bcast-2col">
      <div class="bcast-col">
        <div class="bcast-col-head">발송 정보</div>
        <div style="font-size:12px;color:var(--muted)">${dt} · ${esc(b.sender_name || '')}</div>
        <div style="background:var(--bg);border-radius:10px;padding:12px;font-size:14px;color:var(--ink);white-space:pre-wrap">${esc(b.body || '')}</div>
        <div style="font-size:13px;color:var(--ink)">수신 ${b.recipient_count}명 · 읽음 ${readN} · 답장 ${repliedN}</div>
        <div style="font-size:12px;color:var(--muted);margin-top:2px">보낸 조건</div>
        ${broadcastFilterSummaryHtml(b)}
        ${broadcastFollowupRowHtml(b)}
      </div>
      <div class="bcast-col bcast-col-list">
        <div class="bcast-col-head" id="bcastRecipHead"></div>
        ${broadcastRecipCampSelectHtml(recips)}
        <div class="broadcast-recips in-col" id="bcastRecipList"></div>
      </div>
    </div>`;
  renderBroadcastRecipList();
  const canWithdraw = !b.withdrawn_at && (b.sender_id === currentAdminInfo?.auth_id || currentAdminInfo?.role === 'super_admin');
  document.getElementById('broadcastWithdrawBtn').style.display = canWithdraw ? '' : 'none';
}
function closeBroadcastDetail() { closeModal('broadcastDetailModal'); _curBroadcastDetail = null; }

function gotoBroadcastRecipMessage(appId) {
  if (!appId) return;
  closeBroadcastDetail();
  if (typeof openAdminMessageModal === 'function') openAdminMessageModal(appId, null);
}

// ── 추가 발송 창 ───────────────────────────────────────────
let _followup = null;   // { parent, campaignIds, filters, allIds, restIds }

function _followupCampaignIds(b) {
  const f = b.context_filter || {};
  if (Array.isArray(f.campaign_ids) && f.campaign_ids.length) return f.campaign_ids.slice();
  return b.context_campaign_id ? [b.context_campaign_id] : [];
}

async function openBulkFollowup() {
  const b = _curBroadcastDetail && _curBroadcastDetail.broadcast;
  if (!b) return;
  // 화면이 막아야 할 것을 서버가 막기 전에 한 번 더 — 버튼이 회색인데 눌린 경우 대비
  const s = bulkFollowupState(b);
  if (!s.ok) { toast(s.why); return; }

  _followup = { parent: b, campaignIds: _followupCampaignIds(b), filters: b.context_filter, allIds: [], restIds: [] };
  document.getElementById('bulkFollowupFilter').innerHTML = broadcastFilterSummaryHtml(b);
  document.getElementById('bulkFollowupBody').value = b.body || '';
  document.getElementById('bulkFollowupNote').style.display = 'none';
  document.getElementById('bulkFollowupCount').textContent = '대상을 세는 중…';
  document.getElementById('bulkFollowupSendBtn').disabled = true;
  openModal('bulkFollowupModal');

  try {
    // 두 번 센다 — 「지금 조건에 맞는 N건」과 「아직 안 받은 M건」.
    //   🔴 M 만 보여주면 왜 그 수인지 모른다. 조건이 같아도 그 사이 응모가 취소되거나
    //      결과물 상태가 바뀌면 대상이 달라진다 — 그게 정상이고 오히려 원하는 바다.
    const [전체, 나머지] = await Promise.all([
      Promise.all(_followup.campaignIds.map(cid => resolveBulkRecipients(cid, _followup.filters))),
      Promise.all(_followup.campaignIds.map(cid => resolveBulkRecipients(cid, _followup.filters, b.id))),
    ]);
    const 합 = (arrs) => Array.from(new Set([].concat(...arrs.map(a => a || []))));
    _followup.allIds = 합(전체);
    _followup.restIds = 합(나머지);
  } catch (e) {
    console.error('[openBulkFollowup]', e);
    document.getElementById('bulkFollowupCount').textContent = '대상을 세지 못했습니다. 창을 닫고 다시 시도해 주세요.';
    return;
  }

  const N = _followup.allIds.length, M = _followup.restIds.length;
  // ⚠️ 「명」이 아니라 「건」이다 — 캠페인이 여럿이면 한 사람이 여러 건일 수 있다.
  document.getElementById('bulkFollowupCount').innerHTML =
    `지금 조건에 맞는 <b>${N}건</b> 중 <b style="color:var(--pink)">아직 안 받은 ${M}건</b>`;

  const note = document.getElementById('bulkFollowupNote');
  if (M === 0) {
    note.style.display = '';
    note.textContent = '추가로 보낼 대상이 없습니다.';
    document.getElementById('bulkFollowupSendBtn').disabled = true;   // 0건 발송은 헛일이다
    return;
  }
  if (M > BULK_MAX) {
    // 🔴 막지 않는다 — 막으면 조건에 맞는데 아무에게도 못 보내는 상태가 된다.
    //    대신 **나머지가 몇 건인지 숫자로** 말한다(안 말하면 다 보냈다고 믿는다).
    //    ⚠️ 이어 보낼 자리는 **지금 만들어질 발송**이다. 「이 발송에서 다시」가 아니다 —
    //       보내는 순간 이 발송은 그 사슬의 마지막이 아니게 되어 버튼이 회색이 된다.
    note.style.display = '';
    note.textContent = `한 번에 ${BULK_MAX}건까지 보낼 수 있습니다. 지금 ${BULK_MAX}건에게 보내고, 나머지 ${M - BULK_MAX}건은 「지금 만들어질 발송」에서 이어 보내세요.`;
  }
  document.getElementById('bulkFollowupSendBtn').disabled = false;
}

function closeBulkFollowup() { closeModal('bulkFollowupModal'); _followup = null; }

let _followupSending = false;
async function confirmBulkFollowup() {
  if (_followupSending || !_followup) return;
  const 본문 = document.getElementById('bulkFollowupBody').value.trim();
  if (!본문) { toast('보낼 내용을 입력해 주세요.'); return; }
  const 대상 = _followup.restIds.slice(0, BULK_MAX);
  if (!대상.length) { toast('추가로 보낼 대상이 없습니다.'); return; }
  const 남은 = _followup.restIds.length - 대상.length;

  _followupSending = true;
  const btn = document.getElementById('bulkFollowupSendBtn');
  btn.disabled = true; btn.textContent = '보내는 중…';
  try {
    const p = _followup.parent;
    // 🔴 조건 스냅샷을 **손대지 않고 그대로** 넘긴다 — 그래야 부모의 판을 물려받는다.
    //    판 0 이력에서 이어 보낸 발송에 「지금 판」을 찍으면 그 사슬에서만 판 표시가 눈이 먼다.
    const 새발송 = await sendApplicationMessageBulk(
      대상, 본문, [], 'campaign',
      (_followup.campaignIds.length === 1 ? _followup.campaignIds[0] : null),
      p.context_filter, null, p.id);
    closeBulkFollowup();
    toast(남은 > 0 ? `${대상.length}건 발송했습니다. 남은 ${남은}건은 새 발송에서 이어 보내세요.` : `${대상.length}건 발송했습니다.`);
    if (typeof loadBroadcasts === 'function') await loadBroadcasts();
    // ⚠️ 받은편지함도 함께 갱신한다 — 추가 발송도 알림·응대 기록을 **1차와 똑같이** 만든다.
    //    안 부르면 사이드바 「메시지」 미응대 배지가 옛 숫자로 남는다(`confirmBulkSend` 와 같은 이유).
    if (typeof refreshInboxData === 'function') await refreshInboxData();
    // 남은 것이 있으면 **방금 만들어진 발송**을 열어 준다 — 거기서 이어 보낸다.
    if (새발송) await openBroadcastDetail(새발송);
  } catch (e) {
    console.error('[confirmBulkFollowup]', e);
    toast(friendlyError ? friendlyError(e) : (e.message || '발송에 실패했습니다.'));
  } finally {
    _followupSending = false;
    btn.disabled = false; btn.textContent = '보내기';
  }
}

// ── 일괄 회수 ──
async function openBroadcastWithdraw() {
  if (!_curBroadcastDetail) return;
  // 🔴 안내문은 사실대로 — 회수(withdraw_broadcast, 167)는 **이 발송 1건**의 수신자만 가린다.
  //    추가 발송(388~391)으로 사슬이 생긴 뒤에도 함수는 단건 그대로라, 예전 문구
  //    「받은 사람 모두의 화면에서」는 사슬이 있을 때 거짓이었다(전수조사 D-3).
  //    되돌릴 수 없는 조치라 무엇이 가려지고 무엇이 남는지를 누르기 전에 말한다.
  //    ⚠️ 사슬 전체를 한 번에 회수하는 선택지는 일부러 안 뒀다 — 추가 발송은 본문을 따로
  //       쓸 수 있어 「같은 메시지」라는 보장이 없다(2026-09-07 사용자 결정).
  const _b = _curBroadcastDetail.broadcast || {};
  const _c = _b.chain || {};
  const _cnt = Number(_b.recipient_count) || 0;
  const _inChain = !!_b.parent_broadcast_id || Number(_c.followup_count) > 0;
  const _noteEl = document.getElementById('broadcastWithdrawNote');
  if (_noteEl) {
    let _html = `회수하면 <b>이 발송의 수신자 ${_cnt}건</b>의 화면에서만 이 메시지가 가려집니다. 되돌릴 수 없습니다.`;
    if (_inChain) {
      // ⚠️ 건수를 안 적는다 — followup_count 는 사슬 전체의 추가 발송 수라, 보고 있는 것이 그 유일한
      //    추가 발송이면 「추가 발송 1건」이 자기 자신을 가리켜 「또 확인할 것이 있나」로 오독된다.
      _html += `<div style="margin-top:8px;padding:8px 10px;background:#FFF7ED;border:1px solid #FDBA74;border-radius:6px;color:#9A3412;display:flex;gap:6px;align-items:flex-start">`
        + `<span class="material-icons-round notranslate" translate="no" style="font-size:16px;flex-shrink:0">warning</span>`
        + `<span>이 발송은 추가 발송으로 이어진 사슬의 일부입니다. 사슬의 다른 발송(원래 발송·다른 추가 발송)의 수신자는 <b>그대로 봅니다</b> — 그 발송을 각각 열어 회수해야 합니다.</span></div>`;
    }
    _noteEl.innerHTML = _html;
  }
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
