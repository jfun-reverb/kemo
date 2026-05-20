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
let _msgPendingFiles = [];   // 업로드 대기 File 배열 (압축 전 원본)
let _msgSending = false;

// 응모건 메시지 모달 열기
async function openMessageModal(applicationId) {
  if (!applicationId) return;
  _msgCurrentAppId = applicationId;
  _msgPendingFiles = [];
  const m = $('msgModal');
  if (!m) return;

  // 헤더 제목: 「{캠페인명}に関するお問い合わせ」
  const app = (typeof _myApps !== 'undefined' ? _myApps : []).find(a => a.id === applicationId);
  const camp = (typeof allCampaigns !== 'undefined' ? allCampaigns : []).find(c => c.id === app?.campaign_id) || {};
  const titleEl = $('msgModalTitle');
  if (titleEl) titleEl.textContent = t('messaging.titleFor').replace('{name}', camp.title || '');

  m.classList.add('on');
  m.setAttribute('aria-hidden', 'false');  // 모달 열림 — 내부 포커스 가능 (WAI-ARIA)
  document.body.style.overflow = 'hidden';
  renderMsgAttachPreview();
  const inputEl = $('msgModalInput');
  if (inputEl) { inputEl.value = ''; inputEl.placeholder = t('messaging.placeholder'); }

  const thread = $('msgModalThread');
  if (thread) thread.innerHTML = `<div class="msg-empty">${esc(t('messaging.loading'))}</div>`;

  try {
    const msgs = await fetchApplicationMessages(applicationId);
    renderMessageThread(msgs);
    // 열람 시 본인 미열람 읽음 처리 후 응모이력 배지 갱신
    await markApplicationMessagesRead(applicationId);
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
  } catch (e) {
    console.error('[openMessageModal]', e);
    if (thread) thread.innerHTML = `<div class="msg-empty">${esc(t('messaging.loadError'))}</div>`;
  }
}

function closeMessageModal() {
  const m = $('msgModal');
  if (m) { m.classList.remove('on'); m.setAttribute('aria-hidden', 'true'); }
  document.body.style.overflow = '';
  _msgCurrentAppId = null;
  _msgPendingFiles = [];
}

// 메시지 스레드 렌더 (게시판형 — 위→아래 누적 카드)
function renderMessageThread(messages) {
  const thread = $('msgModalThread');
  if (!thread) return;
  if (!messages || !messages.length) {
    thread.innerHTML = `<div class="msg-empty">${esc(t('messaging.emptyThread'))}</div>`;
    return;
  }
  const now = Date.now();
  thread.innerHTML = messages.map(msg => {
    const mine = msg.sender_kind === 'influencer';
    const senderLabel = mine ? t('messaging.you') : t('messaging.adminTeam');
    const timeStr = formatDate(msg.created_at);

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
