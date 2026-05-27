// ════════════════════════════════════════════════════════════════════
// messaging.js — 인플루언서 ↔ 관리자 메시지 모달 (PR 1, 인플루언서 화면)
//   사양서 docs/specs/2026-05-15-application-messaging.md §5-1 (게시판형)
//   DB 함수: storage.js (fetchApplicationMessages / sendApplicationMessage /
//            markApplicationMessagesRead / withdrawOwnMessage / uploadMessageAttachment)
//   본문/첨부 마스킹은 서버(get_application_messages RPC)에서 처리 — 클라는 mask_state 로 표시만.
// ════════════════════════════════════════════════════════════════════

const MSG_WITHDRAW_LIMIT_MS = 25 * 60 * 1000;  // 본인 회수 25분 (§3-5 ②)
const MSG_MAX_ATTACH = 5;                       // 메시지당 첨부 최대 5장 (§3-2)

let _msgCurrentAppId = null;
let _msgFrom = 'mypage';     // 메시지 페이지 진입 출처 (뒤로가기 목적지 결정)
let _msgPendingFiles = [];   // 업로드 대기 File 배열 (압축 전 원본)
let _msgSending = false;
let _msgPollTimer = null;    // 모달 열린 동안 새 메시지 도착 감지 타이머
let _msgLastCount = 0;       // 현재 표시 중인 메시지 수 (도착 감지 기준)

// FAQ (자동응답·문의 게이트) 상태 (PR B-rev)
let _faqNodes = [];          // active=true 노드 (이번 모달 캐시)
let _faqStage = null;        // 현재 응모건 단계 태그 (relevant_stages 매칭용)
let _faqCtx = {};            // 동적 치환 컨텍스트 ({required, current})
let _faqApp = null;          // 현재 응모건
let _faqCamp = null;         // 현재 캠페인
let _faqLoaded = false;      // 이번 모달에서 노드 로드 완료 여부
let _faqOverlayOpen = false; // 「よくある質問」 전체 보기 오버레이 열림 여부
let _faqNav = [];            // FAQ 오버레이 화면 히스토리 스택 [{view:'cats'|'category'|'item', id?}] — 뒤로가기 경로 추적

// 봇 안내 카드 추천 질문 최대 개수
const FAQ_SUGGEST_MAX = 4;

// 모달 열린 동안 30초마다 새 메시지 도착만 가볍게 확인 — 자동 표시 없이 안내 띠만
function _startMsgPoll() {
  _stopMsgPoll();
  _msgPollTimer = setInterval(_checkNewMessages, 30000);
}
function _stopMsgPoll() {
  if (_msgPollTimer) { clearInterval(_msgPollTimer); _msgPollTimer = null; }
}

async function _checkNewMessages() {
  if (!_msgCurrentAppId || document.hidden) return;
  try {
    const msgs = await fetchApplicationMessages(_msgCurrentAppId);
    // 메시지 수가 늘었으면(새 메시지 도착) 안내 띠만 표시 — 화면은 사용자가 새로고침할 때만 갱신
    if ((msgs?.length || 0) > _msgLastCount) _toggleMsgNewBanner(true);
  } catch (_e) { /* 폴링 실패는 무시 */ }
}
function _toggleMsgNewBanner(show) {
  const b = $('msgNewBanner');
  if (b) b.style.display = show ? 'flex' : 'none';
}

// 메시지 모달 수동 새로고침 (헤더 버튼 + 「새 메시지 도착」 띠 공용)
async function refreshMessageModal() {
  if (!_msgCurrentAppId) return;
  try {
    const msgs = await fetchApplicationMessages(_msgCurrentAppId);
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0;
    _toggleMsgNewBanner(false);
    await markApplicationMessagesRead(_msgCurrentAppId);
    if (typeof markMessageNotificationsRead === 'function') await markMessageNotificationsRead(_msgCurrentAppId);
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
  } catch (e) { console.error('[refreshMessageModal]', e); }
}

// 응모건 메시지 페이지 열기 (모달→페이지 전환, 2026-05-22)
//   from: 'mypage' — 뒤로가기 시 응모이력으로 복귀. 해시 #messages-{id} 로 새로고침 복원.
async function openMessagesPage(applicationId, from, pushHistory) {
  if (!applicationId) return;
  // 알림·새로고침으로 직접 진입 시 _myApps/allCampaigns 캐시가 비어 제목·취소 판별이
  //   부정확할 수 있어 먼저 보장한다(응모이력 경유 진입이면 이미 로드돼 즉시 통과).
  if ((typeof _myApps === 'undefined' || !_myApps || !_myApps.length) && typeof loadMyApplications === 'function') {
    try { await loadMyApplications(); } catch (_e) {}
  }
  // 취소된 응모는 메시지 진입 차단 (사용자 결정 2026-05-22)
  if (typeof isApplicationCancelled === 'function' && isApplicationCancelled(applicationId)) {
    if (typeof toast === 'function') toast(t('messaging.cancelledBlocked'));
    return;
  }
  _msgCurrentAppId = applicationId;
  _msgFrom = from || 'mypage';
  _msgPendingFiles = [];
  _faqLoaded = false;
  _faqOverlayOpen = false;

  // 페이지 활성화 (navigate 가 #messages-{id} 해시 push → 새로고침 복원 가능).
  //   pushHistory=false 면 히스토리 미기록 (뒤로가기·새로고침 복원 시 중복 방지).
  //   같은 페이지(messages→messages 다른 응모건)면 navigate 가 cleanup 을 건너뛰므로
  //   위에서 상태를 명시 초기화하고 아래에서 폴링을 재시작한다.
  if (typeof navigate === 'function') navigate('messages-' + applicationId, pushHistory);

  const page = $('page-messages');
  if (!page) return;

  // 헤더 제목: 「{캠페인명}に関するお問い合わせ」
  const app = (typeof _myApps !== 'undefined' ? _myApps : []).find(a => a.id === applicationId);
  const camp = (typeof allCampaigns !== 'undefined' ? allCampaigns : []).find(c => c.id === app?.campaign_id) || {};
  const titleEl = $('msgModalTitle');
  if (titleEl) titleEl.textContent = t('messaging.titleFor').replace('{name}', camp.title || '');

  renderMsgAttachPreview();
  const inputEl = $('msgModalInput');
  if (inputEl) { inputEl.value = ''; inputEl.placeholder = t('messaging.placeholder'); }

  const thread = $('msgModalThread');
  if (thread) thread.innerHTML = `<div class="msg-empty">${esc(t('messaging.loading'))}</div>`;

  // 개인화 상태 한 줄 — 0건/1건+ 모두 상단 표시 (§3)
  renderAppStatusLine(app, camp);

  // 문의 게이트 셋업 (PR B-rev) — 입력란 옆 「よくある質問」 버튼·제안 영역 항상 노출.
  //   FAQ 트리는 0건/1건+ 무관하게 입력으로 동작하는 게이트로 전환(0건 한정 트리 메뉴 폐기).
  await setupFaqGate(app, camp);

  try {
    const msgs = await fetchApplicationMessages(applicationId);
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0;
    _toggleMsgNewBanner(false);
    // 스레드는 항상 표시(0건이면 안내 문구). 게이트 오버레이는 닫힌 상태로 시작.
    closeFaqOverlay();
    // 열람 시 본인 미열람 읽음 처리 후 응모이력 배지 갱신
    await markApplicationMessagesRead(applicationId);
    // 같은 응모건의 message_received 알림도 읽음 처리 (햄버거 알림 배지 잔존 방지)
    if (typeof markMessageNotificationsRead === 'function') await markMessageNotificationsRead(applicationId);
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
    _startMsgPoll(); // 페이지 열린 동안 새 메시지 도착 감지 시작
  } catch (e) {
    console.error('[openMessagesPage]', e);
    if (thread) thread.innerHTML = `<div class="msg-empty">${esc(t('messaging.loadError'))}</div>`;
  }
}

// 메시지 페이지 뒤로가기 — 응모이력으로 복귀 (헤더 戻る 버튼)
function navigateBackFromMessages() {
  navigate('mypage');
  if (typeof openMypageSub === 'function') openMypageSub('applications');
}

// 메시지 페이지를 떠날 때 정리 (navigate 의 페이지 전환 훅 + 직접 호출 공용).
//   모달이 아니라 페이지이므로 표시/숨김은 navigate 가 관리하고, 여기선 폴링·상태만 정리.
function cleanupMessagesPage() {
  _stopMsgPoll();
  _toggleMsgNewBanner(false);
  _msgCurrentAppId = null;
  _msgPendingFiles = [];
  // 상태 한 줄·전체 보기 오버레이 정리 (봇 카드는 스레드 일부라 thread 비우면 함께 사라짐)
  const sl = $('msgStatusLine'); if (sl) { sl.style.display = 'none'; sl.innerHTML = ''; }
  const ov = $('msgFaqTree'); if (ov) { ov.style.display = 'none'; ov.innerHTML = ''; }
  _faqNodes = []; _faqStage = null; _faqCtx = {}; _faqApp = null; _faqCamp = null;
  _faqLoaded = false; _faqOverlayOpen = false;
}

// 메시지 스레드 렌더 (게시판형 — 위→아래 누적 카드)
function renderMessageThread(messages) {
  const thread = $('msgModalThread');
  if (!thread) return;
  updateMsgPendingNotice(messages);  // 관리자 미응답 안내 토글
  // 스레드 맨 위 봇 안내 카드 (게이트→봇 카드 전환 2026-05-22) — 0건/N건 공통 prepend
  const botCard = _faqBotCardHtml();
  if (!messages || !messages.length) {
    thread.innerHTML = botCard + `<div class="msg-empty">${esc(t('messaging.emptyThread'))}</div>`;
    return;
  }
  const now = Date.now();
  thread.innerHTML = botCard + messages.map(msg => {
    const mine = msg.sender_kind === 'influencer';
    const senderLabel = mine ? t('messaging.you') : t('messaging.adminTeam');
    const timeStr = formatDateTime(msg.created_at);

    // 마스킹 상태별 placeholder (§3-5)
    if (msg.mask_state && msg.mask_state !== 'visible') {
      const phKey = {
        hidden_by_admin: 'messaging.maskHiddenByAdmin',
        self_withdrawn_influencer: 'messaging.maskSelfWithdrawn',
        self_withdrawn_admin: 'messaging.maskAdminWithdrawn',
      }[msg.mask_state] || 'messaging.maskHiddenByAdmin';
      return `<div class="msg-card msg-card-masked ${mine ? 'mine' : ''}">
        <div class="msg-card-head"><span class="msg-sender">${esc(senderLabel)}</span><span class="msg-time">${esc(timeStr)}</span></div>
        <div class="msg-masked-body">${esc(t(phKey))}</div>
      </div>`;
    }

    // 본문: esc() 선적용 후 줄바꿈만 <br> 치환 — 다른 HTML 태그는 이스케이프되어 XSS 안전
    const bodyHtml = esc(msg.body || '').replace(/\n/g, '<br>');

    // 첨부 썸네일 (signed URL 비동기 로드)
    let attachHtml = '';
    const atts = Array.isArray(msg.attachments) ? msg.attachments : [];
    if (atts.length) {
      attachHtml = `<div class="msg-attachments">${atts.map((a, i) => {
        const elId = `msgatt-${msg.id}-${i}`;
        loadMsgAttachThumb(elId, a.path);
        return `<div class="msg-attach-thumb" id="${elId}" onclick="openMsgLightbox('${esc(a.path)}')"><span class="material-icons-round notranslate" translate="no">image</span></div>`;
      }).join('')}</div>`;
    }

    // 본인 메시지 + 25분 이내 → 회수 버튼
    let withdrawBtn = '';
    if (mine) {
      const elapsed = now - new Date(msg.created_at).getTime();
      if (elapsed < MSG_WITHDRAW_LIMIT_MS) {
        const pathsJson = esc(JSON.stringify(atts.map(a => a.path)));
        withdrawBtn = `<button type="button" class="msg-withdraw-btn" onclick='confirmWithdrawMessage("${esc(msg.id)}", ${pathsJson})'>${esc(t('messaging.withdraw'))}</button>`;
      }
    }

    return `<div class="msg-card ${mine ? 'mine' : ''}">
      <div class="msg-card-head"><span class="msg-sender">${esc(senderLabel)}</span><span class="msg-time">${esc(timeStr)}</span>${withdrawBtn}</div>
      <div class="msg-card-body">${bodyHtml}</div>
      ${attachHtml}
    </div>`;
  }).join('');
  // 최신 메시지로 스크롤
  thread.scrollTop = thread.scrollHeight;
}

// 관리자 미응답 안내 배너 — 마지막 살아있는 메시지가 인플루언서 발신이면 표시,
//   관리자가 답하면(마지막이 admin) 자동으로 사라짐
function updateMsgPendingNotice(messages) {
  const notice = $('msgPendingNotice');
  if (!notice) return;
  const visible = (messages || []).filter(m => !m.mask_state || m.mask_state === 'visible');
  const last = visible[visible.length - 1];
  if (last && last.sender_kind === 'influencer') {
    notice.textContent = t('messaging.pendingNotice');
    notice.style.display = '';
  } else {
    notice.style.display = 'none';
  }
}

// 첨부 썸네일 signed URL 비동기 로드 (5분 시한)
async function loadMsgAttachThumb(elId, path) {
  try {
    const url = await getMessageAttachmentSignedUrl(path);
    const el = $(elId);
    if (el && url) {
      el.innerHTML = `<img src="${esc(url)}" loading="lazy" decoding="async" alt="">`;
    }
  } catch (e) { /* 썸네일 실패 시 아이콘 유지 */ }
}

// 첨부 라이트박스 (원본 보기) — 같은 화면 모달 (메시지 모달 위에 표시)
async function openMsgLightbox(path) {
  const lb = $('msgLightbox');
  const img = $('msgLightboxImg');
  if (!lb || !img) return;
  img.src = '';
  lb.classList.add('on');
  lb.setAttribute('aria-hidden', 'false');
  try {
    const url = await getMessageAttachmentSignedUrl(path);
    if (url) { img.src = url; }
    else { closeMsgLightbox(); toast(t('messaging.attachError')); }
  } catch (e) {
    closeMsgLightbox();
    toast(t('messaging.attachError'));
  }
}

function closeMsgLightbox() {
  const lb = $('msgLightbox');
  if (lb) { lb.classList.remove('on'); lb.setAttribute('aria-hidden', 'true'); }
  const img = $('msgLightboxImg');
  if (img) img.src = '';  // signed URL 해제
}

// 회수 확인 → 실행
async function confirmWithdrawMessage(messageId, attachmentPaths) {
  if (!confirm(t('messaging.withdrawConfirm'))) return;
  try {
    await withdrawOwnMessage(messageId, attachmentPaths || []);
    // 스레드 재로드
    const msgs = await fetchApplicationMessages(_msgCurrentAppId);
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0; // 도착 감지 기준 동기화 (회수로 인한 변동 반영)
  } catch (e) {
    console.error('[confirmWithdrawMessage]', e);
    toast(t('messaging.withdrawFailed'));
  }
}

// ── 첨부 선택/미리보기 ──
function onMsgAttachSelected(input) {
  const files = Array.from(input.files || []);
  input.value = '';  // 같은 파일 재선택 허용
  for (const f of files) {
    if (_msgPendingFiles.length >= MSG_MAX_ATTACH) { toast(t('messaging.attachMax').replace('{n}', MSG_MAX_ATTACH)); break; }
    _msgPendingFiles.push(f);
  }
  renderMsgAttachPreview();
}

function removeMsgAttach(idx) {
  _msgPendingFiles.splice(idx, 1);
  renderMsgAttachPreview();
}

function renderMsgAttachPreview() {
  const wrap = $('msgModalAttachPreview');
  if (!wrap) return;
  if (!_msgPendingFiles.length) { wrap.innerHTML = ''; return; }
  wrap.innerHTML = _msgPendingFiles.map((f, i) => {
    const url = URL.createObjectURL(f);
    return `<div class="msg-attach-pending"><img src="${url}" alt=""><button type="button" class="msg-attach-remove" onclick="removeMsgAttach(${i})" aria-label="remove"><span class="material-icons-round notranslate" translate="no">close</span></button></div>`;
  }).join('');
}

// ── 전송 ──
async function sendMessageFromModal() {
  if (_msgSending || !_msgCurrentAppId) return;
  const inputEl = $('msgModalInput');
  const body = (inputEl?.value || '').trim();
  if (!body && !_msgPendingFiles.length) { toast(t('messaging.emptyInput')); return; }

  // 봇 안내 카드 방식(2026-05-22): 발송을 가로채는 게이트 폐기 — 발송은 항상 바로 진행.
  //   FAQ 추천은 스레드 맨 위 봇 카드(_faqBotCardHtml)로 상시 노출.
  _msgSending = true;
  const sendBtn = $('msgModalSendBtn');
  if (sendBtn) sendBtn.disabled = true;

  try {
    // 첨부 압축·업로드 (순차 — 실패 시 즉시 중단)
    const attachments = [];
    for (const f of _msgPendingFiles) {
      try {
        attachments.push(await uploadMessageAttachment(f, _msgCurrentAppId));
      } catch (e) {
        console.error('[sendMessageFromModal] 첨부 업로드', e);
        toast(e?.message === 'too_large' ? t('messaging.attachTooLarge') : t('messaging.attachUploadFailed'));
        _msgSending = false;
        if (sendBtn) sendBtn.disabled = false;
        return;
      }
    }
    await sendApplicationMessage(_msgCurrentAppId, body, attachments);
    // 입력 초기화 + 재로드
    if (inputEl) inputEl.value = '';
    _msgPendingFiles = [];
    renderMsgAttachPreview();
    const msgs = await fetchApplicationMessages(_msgCurrentAppId);
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0; // 내가 보낸 메시지로 「새 메시지 도착」 띠가 오인 표시되지 않도록
    _toggleMsgNewBanner(false);
    // 전체 보기 오버레이는 닫고 스레드만 (봇 카드는 renderMessageThread 가 다시 그림)
    closeFaqOverlay();
  } catch (e) {
    console.error('[sendMessageFromModal]', e);
    // 의도된 RPC 예외(RAISE EXCEPTION = SQLSTATE P0001, 일본어 안내문)만 그대로 노출.
    // 그 외 DB 내부 에러(42702 등)는 일반 메시지로 — 원문 노출 방지
    toast(e?.code === 'P0001' && e?.message ? e.message : t('messaging.sendFailed'));
  } finally {
    _msgSending = false;
    if (sendBtn) sendBtn.disabled = false;
  }
}

// ════════════════════════════════════════════════════════════════════
// FAQ (자동응답 가이드) — PR B
//   사양서 docs/specs/2026-05-21-message-faq.md §3·§3-0·§5·§5-1
//   인플 UI = 일본어(ja 기본) / KO·JA 토글. 데이터는 클라이언트 보유분으로 계산(신규 서버 호출 최소).
// ════════════════════════════════════════════════════════════════════

// 현재 언어 (없으면 ja)
function _faqLang() { return (typeof getLang === 'function') ? getLang() : 'ja'; }
// 노드/문구 양국어 선택 헬퍼 (값 없으면 반대 언어로 폴백)
function _faqPick(row, base) {
  const lang = _faqLang();
  return (lang === 'ko' ? row[base + '_ko'] : row[base + '_ja']) || row[base + '_ja'] || row[base + '_ko'] || '';
}

// 응모건 단계 태그 판정 (§3-3) — 상태 한 줄 케이스와 1:1
//   반환: {key, stage} key=문구용 케이스, stage=relevant_stages 매칭 태그(null=태그 없음)
//   판정 로직은 shared.js faqComputeStatus 에 추출(관리자 측과 동일 결과 보장, §3-1).
function _computeFaqStatus(app, camp) {
  const delivs = (typeof _myDelivsByApp !== 'undefined' ? _myDelivsByApp[app?.id] : null) || [];
  return faqComputeStatus(app?.status, delivs, camp);
}

// 상태 케이스 → 관련 화면 바로가기 (없으면 null)
const FAQ_STATUS_NAV = {
  pending: '#mypage-applications',
  approved_purchase_before: '#mypage-applications',
  receipt: '#activity',
  visit: '#activity',
  post_deadline: '#activity',
  post_overdue: '#activity',
  reviewing: '#activity',
  partial_reject: '#activity',
  all_reject: '#activity',
  rejected: '#mypage-applications',
  cancelled: '#mypage-applications',
  done: null,
  approved_fallback: '#mypage-applications',
  fallback: '#mypage-applications',
};

// 반려 사유 — reject_reason 이 lookup 코드면 일본어 라벨로, 자유텍스트면 그대로 (§3-4 ②)
function _faqRejectReason(app) {
  const delivs = (typeof _myDelivsByApp !== 'undefined' ? _myDelivsByApp[app.id] : null) || [];
  const reasons = delivs.filter(d => d.status === 'rejected' && d.reject_reason)
    .map(d => {
      const raw = d.reject_reason;
      if (typeof getLookupLabel === 'function') {
        const label = getLookupLabel('reject_reason', raw, _faqLang());
        if (label) return label;
      }
      return raw;
    });
  return reasons.length ? reasons.join(' / ') : '';
}

// 개인화 상태 한 줄 렌더 (§3) — 0건/1건+ 공통
function renderAppStatusLine(app, camp) {
  const el = $('msgStatusLine');
  if (!el) return;
  if (!app) { el.style.display = 'none'; el.innerHTML = ''; return; }
  const { key, stage } = _computeFaqStatus(app, camp);
  _faqStage = stage;

  // 마감일 치환용 (영수증/제출 기한 케이스)
  const deadlineMs = (key === 'receipt')
    ? Date.parse(camp?.purchase_end || camp?.submission_end || '')
    : (key === 'post_deadline' ? Date.parse(camp?.submission_end || '') : NaN);
  const mmdd = isNaN(deadlineMs) ? '' : formatMMDD(deadlineMs);

  let text = (t(`messaging.statusLine.${key}`) || '').replace('{date}', mmdd);

  // 반려 케이스는 실제 사유를 덧붙임 (esc 필수)
  let extra = '';
  if (key === 'partial_reject' || key === 'all_reject') {
    const reason = _faqRejectReason(app);
    if (reason) extra = `<div class="msg-status-reason">${esc(t('messaging.statusLine.reasonLabel'))}: ${esc(reason)}</div>`;
  }

  const navTarget = FAQ_STATUS_NAV[key];
  let navBtn = '';
  if (navTarget) {
    navBtn = `<button type="button" class="msg-status-nav" onclick="faqNavigate('${esc(navTarget)}')">${esc(t('messaging.statusLine.goBtn'))}</button>`;
  }

  el.innerHTML = `<div class="msg-status-row"><span class="msg-status-text">${esc(text)}</span>${navBtn}</div>${extra}`;
  el.style.display = text ? '' : 'none';
}

// MM/DD 포맷 (ja-JP)
function formatMMDD(ms) {
  if (isNaN(ms)) return '';
  const d = new Date(ms);
  return `${String(d.getMonth() + 1).padStart(2, '0')}/${String(d.getDate()).padStart(2, '0')}`;
}

// ── FAQ 트리 ──

// 동적 치환 컨텍스트 계산 (§5-1) — {required}=캠페인 min_followers, {current}=본인 대표 SNS 팔로워
function _buildFaqCtx(camp) {
  const ctx = {};
  const minF = camp?.min_followers || 0;
  if (minF > 0) ctx.required = minF;
  const p = (typeof currentUserProfile !== 'undefined' ? currentUserProfile : null) || {};
  // qoo10 은 자체 팔로워 개념이 없어 신청 시 Instagram ID·팔로워를 필수로 받고 그 값으로
  // 최소 팔로워를 검증한다(application.js 와 동일). 따라서 여기서도 ig_followers 를 폴백으로 쓴다.
  const followerMap = {
    instagram: p.ig_followers || 0, x: p.x_followers || 0,
    tiktok: p.tiktok_followers || 0, youtube: p.youtube_followers || 0, qoo10: p.ig_followers || 0,
  };
  const primary = (p.primary_sns || (camp?.channel || '').split(',')[0] || '').trim();
  const cur = followerMap[primary];
  if (cur && cur > 0) ctx.current = cur;
  return ctx;
}

// 본문 동적 치환 (§5-1) — 화이트리스트 토큰만, 값 없으면 그 토큰이 든 줄 통째 생략, 치환값 esc
const FAQ_TOKEN_WHITELIST = ['required', 'current'];
function renderFaqBody(text, ctx) {
  if (!text) return '';
  ctx = ctx || {};
  const lines = String(text).split('\n');
  const kept = [];
  for (const line of lines) {
    const tokens = (line.match(/\{([a-z]+)\}/g) || []).map(s => s.slice(1, -1));
    // 화이트리스트 토큰 중 값이 없는 게 있으면 그 줄 통째 생략
    const hasMissing = tokens.some(tok => FAQ_TOKEN_WHITELIST.includes(tok) && (ctx[tok] === undefined || ctx[tok] === null || ctx[tok] === ''));
    if (hasMissing) continue;
    kept.push(line);
  }
  // esc 먼저 → 화이트리스트 토큰만 치환(치환값도 esc) → 줄바꿈 <br>
  let html = esc(kept.join('\n'));
  html = html.replace(/\{([a-z]+)\}/g, (m, tok) => {
    if (FAQ_TOKEN_WHITELIST.includes(tok) && ctx[tok] !== undefined && ctx[tok] !== null && ctx[tok] !== '') {
      return esc(String(ctx[tok]));
    }
    return m; // 화이트리스트 외 토큰은 원문 유지 (사용자 답변에 우연히 들어간 중괄호 보호)
  });
  return html.replace(/\n/g, '<br>');
}

// ── FAQ 노드 로드 (게이트→봇 카드 전환 2026-05-22) ──
//   진입 시 1회 active 노드 로드만. 추천 안내는 renderMessageThread 가 스레드 맨 위
//   봇 카드(_faqBotCardHtml)로 그린다. 입력란 위 고정 게이트는 폐기.
async function setupFaqGate(app, camp) {
  _faqApp = app; _faqCamp = camp;
  _faqCtx = _buildFaqCtx(camp);
  try {
    const all = await fetchFaqNodes();
    _faqNodes = (all || []).filter(n => n.active);
    _faqLoaded = true;
  } catch (e) {
    console.error('[setupFaqGate]', e);
    _faqNodes = [];
    _faqLoaded = true;
  }
}

// 추천 후보 — 현재 단계(relevant_stages) 우선, 답변 노드(handoff 아닌 item, body 보유)만 상위 N개.
//   입력어 실시간 매칭은 봇 카드형 전환(2026-05-22)으로 폐기 — 단계 기반만.
function _faqFindCandidates() {
  if (!_faqLoaded || !_faqNodes.length) return [];
  const items = _faqNodes.filter(n =>
    n.kind === 'item' && !n.is_human_handoff && (n.body_ja || n.body_ko)
  );
  return _faqSortNodes(items).slice(0, FAQ_SUGGEST_MAX);
}

// 스레드 맨 위 봇 안내 카드 HTML (게이트→봇 카드 전환 2026-05-22).
//   "먼저 확인해보세요" + 단계 기반 추천 질문 + 「よくある質問」 전체 보기 진입.
//   클라이언트 전용 가상 카드(application_messages 에 저장 안 함). 노드 로드 전엔 빈 문자열.
function _faqBotCardHtml() {
  if (!_faqLoaded) return '';
  const cards = _faqFindCandidates().map(n =>
    `<button type="button" class="msg-faq-suggest-item" onclick="openFaqItemById('${esc(n.id)}')">
      <span class="material-icons-round notranslate" translate="no">help_outline</span>
      <span class="msg-faq-suggest-q">${esc(_faqPick(n, 'label'))}</span>
      <span class="material-icons-round notranslate msg-faq-suggest-chev" translate="no">chevron_right</span>
    </button>`
  ).join('');
  return `<div class="msg-card msg-card-bot">
    <div class="msg-card-bot-head"><span class="material-icons-round notranslate" translate="no">support_agent</span>${esc(t('messaging.faq.suggestHead'))}</div>
    ${cards ? `<div class="msg-faq-botcard-list">${cards}</div>` : ''}
    <button type="button" class="msg-faq-botcard-all" onclick="toggleFaqOverlay()">
      <span class="material-icons-round notranslate" translate="no">quiz</span>
      <span>${esc(t('messaging.faq.openBtn'))}</span>
    </button>
  </div>`;
}

// 제안 카드 클릭 → 전체 보기 오버레이를 열고 그 답변을 바로 표시
function openFaqItemById(itemId) {
  if (!_faqOverlayOpen) openFaqOverlay(/*skipRender*/ true);
  _faqNav = []; // 게이트(봇 카드) 추천에서 직접 진입 → 스택 초기화 (뒤로 = 오버레이 닫고 메시지 화면으로)
  openFaqItem(itemId);
}

// ── 「よくある質問」 전체 보기 오버레이 (대화 중 상시 진입, §2 결정 4) ──
function openFaqOverlay(skipRender) {
  const ov = $('msgFaqTree');
  if (!ov) return;
  _faqOverlayOpen = true;
  ov.style.display = '';
  if (!skipRender) renderFaqCategories();
}

function closeFaqOverlay() {
  const ov = $('msgFaqTree');
  if (ov) { ov.style.display = 'none'; ov.innerHTML = ''; }
  _faqOverlayOpen = false;
  _faqNav = [];
}

// FAQ 오버레이 뒤로가기 — 히스토리 스택 기준 "직전에 본 화면"으로.
//   스택이 비면(게이트에서 바로 진입한 경우) 오버레이를 닫아 메시지 화면으로 복귀.
function faqBack() {
  _faqNav.pop(); // 현재 화면 제거
  const prev = _faqNav[_faqNav.length - 1];
  if (!prev) { closeFaqOverlay(); return; }
  if (prev.view === 'cats') renderFaqCategories({ noPush: true });
  else if (prev.view === 'category') openFaqCategory(prev.id, { noPush: true });
  else if (prev.view === 'item') openFaqItem(prev.id, { noPush: true });
}

// HTML 「よくある質問」 버튼 onclick — 토글
function toggleFaqOverlay() {
  if (_faqOverlayOpen) { closeFaqOverlay(); return; }
  if (!_faqLoaded) return;
  openFaqOverlay(false);
}

// 단계 일치 우선 정렬 (§3 맞춤 노출) — relevant_stages 에 현재 단계가 있으면 위로
function _faqStageWeight(node) {
  if (!_faqStage) return 1;
  const stages = Array.isArray(node.relevant_stages) ? node.relevant_stages : [];
  return stages.includes(_faqStage) ? 0 : 1;
}
function _faqSortNodes(arr) {
  return arr.slice().sort((a, b) => {
    const w = _faqStageWeight(a) - _faqStageWeight(b);
    if (w !== 0) return w;
    return (a.sort_order || 0) - (b.sort_order || 0);
  });
}

// 카테고리 칩 목록 렌더 (1단)
function renderFaqCategories(opts) {
  const tree = $('msgFaqTree');
  if (!tree) return;
  if (!opts || !opts.noPush) _faqNav = [{ view: 'cats' }];
  const cats = _faqSortNodes(_faqNodes.filter(n => n.kind === 'category' && !n.parent_id));
  if (!cats.length) {
    tree.innerHTML = `<div class="msg-empty">${esc(t('messaging.faq.unavailable'))}</div>`;
    return;
  }
  const chips = cats.map(c =>
    `<button type="button" class="msg-faq-chip" onclick="openFaqCategory('${esc(c.id)}')">${esc(_faqPick(c, 'label'))}</button>`
  ).join('');
  tree.innerHTML = `
    ${_faqOverlayHeaderHtml(t('messaging.faq.allTitle'))}
    <div class="msg-faq-intro">${esc(t('messaging.faq.intro'))}</div>
    <div class="msg-faq-chips">${chips}</div>
    <button type="button" class="msg-faq-contact-link" onclick="faqStartDirectContact(null)">${esc(t('messaging.faq.contactBtn'))}</button>
  `;
  tree.scrollTop = 0;
}

// 전체 보기 오버레이 상단 헤더(제목 + 닫기) — 카테고리 1단에서만 닫기 노출
function _faqOverlayHeaderHtml(title) {
  return `<div class="msg-faq-overlay-head">
    <span class="msg-faq-overlay-title">${esc(title || '')}</span>
    <button type="button" class="msg-faq-overlay-close" onclick="closeFaqOverlay()" aria-label="close">
      <span class="material-icons-round notranslate" translate="no">close</span>
    </button>
  </div>`;
}

// 카테고리 선택 → 질문 목록 (2단)
function openFaqCategory(catId, opts) {
  const tree = $('msgFaqTree');
  const cat = _faqNodes.find(n => n.id === catId);
  if (!tree || !cat) return;
  if (!opts || !opts.noPush) _faqNav.push({ view: 'category', id: catId });
  const items = _faqSortNodes(_faqNodes.filter(n => n.kind === 'item' && n.parent_id === catId));
  const list = items.map(q =>
    `<button type="button" class="msg-faq-q" onclick="openFaqItem('${esc(q.id)}')">${esc(_faqPick(q, 'label'))}<span class="material-icons-round notranslate" translate="no">chevron_right</span></button>`
  ).join('');
  tree.innerHTML = `
    <button type="button" class="msg-faq-back" onclick="faqBack()"><span class="material-icons-round notranslate" translate="no">arrow_back</span>${esc(t('messaging.faq.backToCategories'))}</button>
    <div class="msg-faq-cat-title">${esc(_faqPick(cat, 'label'))}</div>
    <div class="msg-faq-qlist">${list || `<div class="msg-empty">${esc(t('messaging.faq.unavailable'))}</div>`}</div>
    <button type="button" class="msg-faq-contact-link" onclick="faqStartDirectContact(null)">${esc(t('messaging.faq.contactBtn'))}</button>
  `;
  tree.scrollTop = 0;
}

// 질문 선택 → 답변 카드 또는 분기(자식 item) 또는 바로 직접 문의(handoff)
function openFaqItem(itemId, opts) {
  const tree = $('msgFaqTree');
  const node = _faqNodes.find(n => n.id === itemId);
  if (!tree || !node) return;

  // handoff=true → 바로 직접 문의 모드 ('handoff' 기록)
  if (node.is_human_handoff) {
    faqStartDirectContact(itemId);
    return;
  }

  // 화면 히스토리 스택에 기록 (뒤로가기 경로 추적)
  if (!opts || !opts.noPush) _faqNav.push({ view: 'item', id: itemId });

  // 자식 item 을 가진 분기 노드(예: Q1-1)는 하위 펼침
  const children = _faqSortNodes(_faqNodes.filter(n => n.kind === 'item' && n.parent_id === itemId));
  if (children.length) {
    const list = children.map(q =>
      `<button type="button" class="msg-faq-q" onclick="openFaqItem('${esc(q.id)}')">${esc(_faqPick(q, 'label'))}<span class="material-icons-round notranslate" translate="no">chevron_right</span></button>`
    ).join('');
    const parentCatId = node.parent_id;
    tree.innerHTML = `
      <button type="button" class="msg-faq-back" onclick="faqBack()"><span class="material-icons-round notranslate" translate="no">arrow_back</span>${esc(t('messaging.faq.back'))}</button>
      <div class="msg-faq-cat-title">${esc(_faqPick(node, 'label'))}</div>
      <div class="msg-faq-qlist">${list}</div>
      <button type="button" class="msg-faq-contact-link" onclick="faqStartDirectContact(null)">${esc(t('messaging.faq.contactBtn'))}</button>
    `;
    tree.scrollTop = 0;
    return;
  }

  // 답변 카드 — 'viewed' 기록(서버 멱등)
  recordFaqInteraction(_msgCurrentAppId, itemId, 'viewed');

  const bodyHtml = renderFaqBody(_faqPick(node, 'body'), _faqCtx);
  // 화면 이동 버튼 (action_type='navigate' + action_target)
  let actionBtn = '';
  if (node.action_type === 'navigate' && node.action_target) {
    const actLabel = _faqPick(node, 'action_label') || t('messaging.statusLine.goBtn');
    actionBtn = `<button type="button" class="msg-faq-action-btn" onclick="faqNavigate('${esc(node.action_target)}')"><span class="material-icons-round notranslate" translate="no">open_in_new</span>${esc(actLabel)}</button>`;
  }
  tree.innerHTML = `
    <button type="button" class="msg-faq-back" onclick="faqBack()"><span class="material-icons-round notranslate" translate="no">arrow_back</span>${esc(t('messaging.faq.back'))}</button>
    <div class="msg-faq-answer">
      <div class="msg-faq-answer-q">${esc(_faqPick(node, 'label'))}</div>
      <div class="msg-faq-answer-body">${bodyHtml}</div>
      ${actionBtn}
    </div>
    <div class="msg-faq-answer-actions">
      <button type="button" class="msg-faq-resolved-btn" onclick="faqMarkResolved('${esc(itemId)}')">${esc(t('messaging.faq.resolvedBtn'))}</button>
      <button type="button" class="msg-faq-contact-link" onclick="faqStartDirectContact('${esc(itemId)}')">${esc(t('messaging.faq.contactBtn'))}</button>
    </div>
  `;
  tree.scrollTop = 0;
}

// [解決しました] → 'resolved' 기록 + 안내
async function faqMarkResolved(itemId) {
  await recordFaqInteraction(_msgCurrentAppId, itemId, 'resolved');
  toast(t('messaging.faq.resolvedToast'));
  navigateBackFromMessages();
}

// [直接お問い合わせ] → 전체 보기 오버레이 닫고 입력란 포커스 + 'handoff' 기록
async function faqStartDirectContact(itemId) {
  await recordFaqInteraction(_msgCurrentAppId, itemId || null, 'handoff');
  closeFaqOverlay();
  const inputEl = $('msgModalInput');
  if (inputEl) { try { inputEl.focus(); } catch (_e) {} }
}

// FAQ 화면 이동 — 모달 닫고 해시 경로로 라우팅 (§8-2 고정값)
function faqNavigate(target) {
  if (!target) return;
  const app = _faqApp;
  // 페이지 떠남 — 아래 navigate/openActivityPage 호출이 cleanup 훅을 부른다(별도 닫기 불필요)
  // #activity 는 appId/campId 필요 → openActivityPage 직접 호출
  if (target === '#activity') {
    if (app && typeof openActivityPage === 'function') {
      openActivityPage(app.id, app.campaign_id, 'mypage');
      return;
    }
    if (typeof navigate === 'function') navigate('mypage');
    if (typeof openMypageSub === 'function') openMypageSub('applications');
    return;
  }
  // #mypage-* → 마이페이지 서브 (sub = 'profile-sns' 등)
  if (target.startsWith('#mypage-')) {
    const sub = target.replace('#mypage-', '');
    if (typeof navigate === 'function') navigate('mypage');
    if (typeof openMypageSub === 'function') openMypageSub(sub);
    return;
  }
  // 기타 해시 — 일반 라우팅
  const page = target.replace('#', '');
  if (typeof navigate === 'function') navigate(page);
}
