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
// 페이지 모드 — 'app'(응모건 메시지) / 'general'(일반 문의, 응모 없음 — 마이그레이션 475~482).
//   같은 #page-messages 를 재사용하므로 **진입 함수가 매번 정하고 정리 함수가 'app' 으로 되돌린다.**
//   ⚠️ 일반 문의에서는 _msgCurrentAppId 가 null 이다 — 「대화가 열려 있나」는 _msgActive() 로 본다.
let _msgMode = 'app';
// 자주 묻는 질문을 어느 문의에 보일지는 shared.js `faqNodeVisibleIn`(마이그레이션 510 노출 위치 칸) — 옛 카테고리 셋 상수도 그쪽으로 옮겼다

// 서비스 문의 여러 대화(마이그레이션 505) — 지금 연 대화 id. null = 새 문의 화면.
//   🔴 새 문의 화면에서는 조회·읽음을 부르지 않는다 — 대화 인자가 비면 서버가 회원 전체를 돌려주고
//      전부 읽음 처리해, 지난 대화가 다 보이고 배지가 통째로 꺼진다(코드 대조 R-2).
let _msgGeneralThreadId = null;
let _msgGeneralPast = false;   // 지난 문의(닫히고 24시간 지난 대화) — 읽기만
let _msgAppPast = false;       // 캠페인 지난 문의(응모 끝나고 90일 지남 — 서버 판정 509) — 읽기만
// 새 문의 중복 방지값(508) — 새 문의 화면에 들어올 때 하나 만들어 보낼 때마다 같은 값을 쓰고, 떠나면 버린다.
//   예외 하나: thread_closed 를 받으면 새로 만든다(같은 값이 24시간 지난 대화를 가리키게 됐다는 뜻)
let _msgGeneralToken = null;

// 새 문의 화면의 제목 칸(#msgSubjectWrap) — 보이기·숨기기·오류 한 줄
function _msgShowSubject(show, value) {
  const wrap = $('msgSubjectWrap');
  if (wrap) wrap.style.display = show ? '' : 'none';
  const input = $('msgSubjectInput');
  if (input && value !== undefined) input.value = value;
  _msgSubjectError('');
}
function _msgSubjectError(key) {
  const el = $('msgSubjectError');
  if (!el) return;
  el.textContent = key ? t(key) : '';
  el.style.display = key ? '' : 'none';
}
// 제목 칸 위 안내 — 열린 문의가 상한이면 상한 안내, 1건 이상이면 「같은 내용이면 거기에」 + 목록 링크
function _msgRenderOpenNote(info) {
  const el = $('msgOpenNote');
  if (!el) return;
  const text = !info ? '' : info.atLimit ? t('inquiry.openLimit')
    : info.openCount > 0 ? t('inquiry.openCountHint').replace('{n}', String(info.openCount)) : '';
  if (!text) { el.style.display = 'none'; el.innerHTML = ''; return; }
  el.innerHTML = `<p>${esc(text)}</p>
    <button type="button" class="inq-link-btn" onclick="backToInquiryList()">${esc(t('inquiry.seeList'))}</button>`;
  el.style.display = '';
}
// 대화 머리글 — 제목이 있으면 제목(한 줄 말줄임은 스타일), 없으면 「運営チームへのお問い合わせ」
function _msgSetGeneralHeader(title) {
  const titleEl = $('msgModalTitle');
  if (titleEl) titleEl.textContent = title || t('inquiry.generalTitle');
}

// 대화가 열려 있나 — 일반 문의는 응모 번호가 없으므로 모드로 판정한다.
function _msgActive() { return _msgMode === 'general' || !!_msgCurrentAppId; }
// 모드별 분기 넷 — 조회·읽음·발송·첨부. 일반 문의는 본인 회원 id 를 **항상** 넘긴다
//   (관리자를 겸한 회원도 회원 갈래로 판정되게 — 505 호출자 판정).
async function _msgLoad() {
  if (_msgMode === 'general') {
    if (!_msgGeneralThreadId) return [];   // 새 문의 화면(R-2)
    const rows = await fetchGeneralInquiryMessages(currentUser?.id || null, _msgGeneralThreadId);
    if (rows === null) throw new Error('general_inquiry_load_failed');   // 실패와 0건을 가른다
    return rows;
  }
  return await fetchApplicationMessages(_msgCurrentAppId);
}
async function _msgMarkRead() {
  if (_msgMode === 'general') {
    if (_msgGeneralThreadId) {
      await markGeneralInquiryMessagesRead(currentUser?.id || null, _msgGeneralThreadId);
      if (typeof markNotificationsReadByRef === 'function' && currentUser) {
        // 새 알림은 대화 id, 505 이전 알림은 회원 id 로 걸려 있다 — 둘 다 읽음으로(R-7, 안 하면 종 배지가 남는다)
        await markNotificationsReadByRef('general_inquiry', _msgGeneralThreadId, 'message_received');
        await markNotificationsReadByRef('general_inquiry', currentUser.id, 'message_received');
      }
    }
    if (typeof refreshNavInquiryBadge === 'function') refreshNavInquiryBadge();
    return;
  }
  await markApplicationMessagesRead(_msgCurrentAppId);
  // 같은 응모건의 message_received 알림도 읽음 처리 (햄버거 알림 배지 잔존 방지)
  if (typeof markMessageNotificationsRead === 'function') await markMessageNotificationsRead(_msgCurrentAppId);
}
function _msgUpload(f) {
  return _msgMode === 'general'
    ? uploadGeneralInquiryAttachment(f, currentUser?.id)
    : uploadMessageAttachment(f, _msgCurrentAppId);
}
// title: 새 문의일 때만(대화가 있으면 null). 새 문의는 중복 방지값을 함께 보낸다(508).
function _msgSend(body, attachments, title) {
  if (_msgMode !== 'general') return sendApplicationMessage(_msgCurrentAppId, body, attachments);
  const isNew = !_msgGeneralThreadId;
  return sendGeneralInquiryMessage(body, attachments, currentUser?.id || null, _msgGeneralThreadId,
    isNew ? title : null, isNew ? _msgGeneralToken : null);
}
let _msgPendingFiles = [];   // 업로드 대기 File 배열 (압축 전 원본)
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
  if (!_msgActive() || document.hidden) return;
  try {
    const msgs = await _msgLoad();
    // 메시지 수가 늘었으면(새 메시지 도착) 안내 띠만 표시 — 화면은 사용자가 새로고침할 때만 갱신
    if ((msgs?.length || 0) > _msgLastCount) _toggleMsgNewBanner(true);
  } catch (_e) { /* 폴링 실패는 무시 */ }
}
function _toggleMsgNewBanner(show) {
  const b = $('msgNewBanner');
  if (b) b.style.display = show ? 'flex' : 'none';
}

// 메시지 모달 수동 새로고침 (헤더 버튼 + 「새 메시지 도착」 띠 공용)
// 스레드를 처음 못 불러왔을 때의 「다시 불러오기」(상태 안내 단추) — 두 모드 공용.
//   ⚠️ refreshMessageModal 로 대신하지 않는다: 그건 불러오는 중을 안 보이고 실패를 조용히 삼키며,
//      첫 진입이 실패해 꺼져 있던 새 메시지 감지(폴링)를 다시 켜지 않는다.
async function retryMessageThread() {
  if (!_msgActive()) return;
  // 기다리는 사이 다른 응모건·모드로 옮겼으면 그 화면에 그리지 않는다
  const startMode = _msgMode, startApp = _msgCurrentAppId, startThread = _msgGeneralThreadId;
  const stillHere = () => _msgActive() && _msgMode === startMode && _msgCurrentAppId === startApp
    && _msgGeneralThreadId === startThread;
  const thread = $('msgModalThread');
  if (thread) thread.innerHTML = stateLoadingHtml(t('messaging.loading'));
  try {
    const msgs = await _msgLoad();
    if (!stillHere()) return;
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0;
    _toggleMsgNewBanner(false);
    await _msgMarkRead();
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
    _startMsgPoll();
  } catch (e) {
    logAppError('retryMessageThread', e);
    if (thread && stillHere()) thread.innerHTML = stateErrorHtml(t('messaging.loadError'), 'retryMessageThread');
  }
}

async function refreshMessageModal() {
  if (!_msgActive()) return;
  try {
    const msgs = await _msgLoad();
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0;
    _toggleMsgNewBanner(false);
    await _msgMarkRead();
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
  } catch (e) { console.error('[refreshMessageModal]', e); logAppError('refreshMessageModal', e); }
}

// 작성 줄 준비 — 응모건·일반 문의 진입이 같이 쓴다(페이지를 재사용하므로 매 진입마다 되돌린다).
//   past: 서비스 문의 지난 문의 — 작성 줄 대신 「문의 목록으로」 안내(#msgPastNote).
function _msgPrepareCompose(_msgReadOnly, past) {
  // 읽기 전용(취소된 응모) — 작성 줄을 감추고 안내 한 줄로 바꾼다.
  //   ⚠️ 모달이 아니라 페이지를 재사용하므로, 취소 아닌 응모로 들어올 때 **반드시 되돌린다.**
  {
    const inputRow = document.querySelector('#page-messages .msg-input-row');
    const note = $('msgReadOnlyNote');
    const pastNote = $('msgPastNote');
    if (inputRow) inputRow.style.display = (_msgReadOnly || past) ? 'none' : '';
    if (note) {
      note.style.display = _msgReadOnly ? '' : 'none';
      if (_msgReadOnly) note.textContent = t('messaging.cancelledReadOnly');
    }
    if (pastNote) pastNote.style.display = past ? '' : 'none';
    // 제목 칸·열린 문의 안내는 새 문의 화면만 — 그 진입이 다시 켠다
    _msgShowSubject(false);
    _msgRenderOpenNote(null);
    closeMsgPlusMenu();
    closeMsgFaqSheet();
  }

  renderMsgAttachPreview();
  const inputEl = $('msgModalInput');
  if (inputEl) {
    inputEl.value = ''; inputEl.placeholder = t('messaging.placeholder');
    inputEl.style.height = ''; // 1줄로 리셋
    if (!inputEl._autosizeBound) {
      // 카톡식 1줄 시작 + 입력 따라 자동 확장(최대 120px). 대화 영역 확보 (2026-05-27)
      // 전제: #msgModalInput DOM 은 페이지 생명주기 동안 재사용(cleanupMessagesPage 가 제거 안 함).
      //       향후 cleanup 이 입력창을 재생성하면 _autosizeBound 가 stale 이 되므로 그때 플래그 재설계 필요.
      // 입력란에 초점이 가면 아래 서랍을 닫는다 — 키보드와 서랍이 함께 화면을 덮지 않게
      inputEl.addEventListener('focus', closeMsgFaqSheet);
      inputEl.addEventListener('input', () => {
        inputEl.style.height = 'auto';
        inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + 'px';
      });
      inputEl._autosizeBound = true;
    }
  }

}

// 응모건 메시지 페이지 열기 (모달→페이지 전환, 2026-05-22)
//   from: 'mypage' — 뒤로가기 시 응모이력으로 복귀. 해시 #messages-{id} 로 새로고침 복원.
async function openMessagesPage(applicationId, from, pushHistory) {
  if (!applicationId) return;
  // 세션이 없으면 로그인으로 — 이 화면에는 로그인 확인이 없었다(2026-08-31).
  //   증상: 아이폰 사파리에서 8/25~28 에 5회. `permission denied for function
  //   get_application_messages` 가 오류 로그에 쌓였고 회원은 「読み込みに失敗しました」만 봤다.
  //   ⚠️ 원인은 토큰 만료가 아니라 **세션이 통째로 없는 것**이다(사파리가 저장소를 비운다).
  //      세션이 없으면 비로그인 권한으로 호출돼 그 함수가 거부한다.
  //   🔴 그래서 `retryWithRefresh` 로 감싸는 것만으로는 안 고쳐진다 — 그 함수는
  //      'row-level security'·'JWT expired' 일 때만 재시도하는데 이 메시지는 둘 다 아니고,
  //      갱신 토큰도 없어 `refreshSession()` 자체가 실패한다. 막는 것은 이 줄이다.
  //   ⚠️ 반드시 아래 `loadMyApplications()` **앞**에 둔다 — 그것도 로그인이 필요해
  //      뒤에 두면 튕기기 전에 실패가 한 번 더 난다.
  //   ⚠️ 부팅 복원(`app.js` 의 `#messages-` 분기)은 세션 복원 뒤에 도므로
  //      로그인한 회원이 여기서 튕기지 않는다.
  if (!currentUser) { navigate('login'); return; }
  // 알림·새로고침으로 직접 진입 시 _myApps/allCampaigns 캐시가 비어 제목·취소 판별이
  //   부정확할 수 있어 먼저 보장한다(응모이력 경유 진입이면 이미 로드돼 즉시 통과).
  if ((typeof _myApps === 'undefined' || !_myApps || !_myApps.length) && typeof loadMyApplications === 'function') {
    try { await loadMyApplications(); } catch (_e) {}
  }
  // 취소된 응모는 **읽기만** 허용한다(F-11, 2026-08-10 사용자 결정).
  //   2026-05-22 에는 진입 자체를 막았는데, 관리자가 보낸 메시지는 그대로 도착하고
  //   알림도 가서 **눌러도 못 들어가는 막다른 길**이 됐다. 안 읽음 배지가 영영 안 지워지고,
  //   관리자 쪽에는 「안 읽음」으로 남아 무시한 것처럼 보였다.
  //   → 들어가서 읽을 수는 있게 하고(배지도 지워진다), **새로 쓰지는 못하게** 한다.
  //   차단 의도(취소된 건으로 새 문의를 시작하지 않는다)는 그대로 지켜진다.
  const _msgReadOnly = (typeof isApplicationCancelled === 'function') && isApplicationCancelled(applicationId);
  _msgAppPast = false;   // 아래에서 서버 판정으로 정한다(화면을 먼저 옮긴 뒤)
  _msgMode = 'app';
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

  const thread = $('msgModalThread');
  if (thread) thread.innerHTML = stateLoadingHtml(t('messaging.loading'));
  // 응모 끝나고 90일 지난 대화도 읽기만(서버 509 판정 — 응모이력 말풍선·알림·새로고침 어디로 들어와도 같게).
  //   화면을 먼저 옮기고 기다린다(눌러도 반응 없는 구간 방지). 기다리는 사이 다른 대화로 옮겼으면 멈춘다.
  //   조회 실패면 쓸 수 있게 둔다 — 서버 발신 함수가 마지막 방어선(같은 판정)이고 그때 안내 문구가 뜬다
  if (!_msgReadOnly) {
    const st = await fetchMyApplicationMessageStatus();
    if (_msgMode !== 'app' || _msgCurrentAppId !== applicationId) return;
    _msgAppPast = !!(st && st.get(applicationId) && st.get(applicationId).writable === false);
  }
  _msgPrepareCompose(_msgReadOnly, _msgAppPast);

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
    // 열람 시 본인 미열람 읽음 처리(+ 같은 응모건 알림) 후 응모이력 배지 갱신
    await _msgMarkRead();
    if (typeof refreshMyMsgUnread === 'function') await refreshMyMsgUnread();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
    _startMsgPoll(); // 페이지 열린 동안 새 메시지 도착 감지 시작
  } catch (e) {
    console.error('[openMessagesPage]', e);
    logAppError('openMessagesPage', e);
    if (thread) thread.innerHTML = stateErrorHtml(t('messaging.loadError'), 'retryMessageThread');
  }
}

// 메시지 페이지 뒤로가기 — 응모이력으로 복귀 (헤더 戻る 버튼)
//   들어온 길을 따른다(사양서 §3) — 일반 문의: 갈래 화면 / 탈퇴 화면 / 홈(메뉴·알림).
//   응모건 메시지: 갈래 화면에서 왔으면 갈래 화면, 그 밖은 종전대로 응모이력.
function navigateBackFromMessages() {
  if (_msgFrom === 'inquiry') {
    if (typeof openInquiryPage === 'function') { openInquiryPage('back'); return; }
  }
  if (_msgMode === 'general') {
    // 서비스 문의 대화 → 서비스 탭 목록(사양서 2026-10-06). 탈퇴 지름길로 왔으면 탈퇴 화면
    if (_msgFrom === 'withdraw' && typeof handleWithdraw === 'function') { handleWithdraw(); return; }
    // 질문 페이지의 「直接お問い合わせ」로 왔으면 그 페이지로
    if (_msgFrom === 'faq') { openFaqPage('service'); return; }
    backToInquiryList();
    return;
  }
  navigate('mypage');
  if (typeof openMypageSub === 'function') openMypageSub('applications');
}

// ════════════════════════════════════════════════════════════════════
// 일반 문의 창구 — 햄버거 「お問い合わせ」 단일 입구 (사양서 docs/specs/2026-05-21-general-inquiry-desk.md §3)
//   문의 화면 #inquiry → 탭 「캠페인 문의」(대화가 시작된 응모건) / 「서비스 문의」(#inquiry-general)
// ════════════════════════════════════════════════════════════════════
let _inqApps = null;        // 문의 화면용 응모 목록 — null=조회 실패, []=0건
let _inqTab = 'app';        // 문의 화면 탭 — 'app'(캠페인 문의) / 'other'(서비스 문의)
let _inqAllApps = null;     // 본인 응모 전체(취소 포함) — 「새 문의」 고르기 재료
let _inqPicking = false;    // 「새 문의」 응모 고르기 보기(문의하기 화면 안의 하위 보기)
let _inqThreads = null;     // 서비스 문의 대화 목록(506 뷰) — null=조회 실패, []=0건
let _inqAppStatus = null;   // 캠페인 문의 쓸 수 있나(서버 509) — Map<응모id,{writable}>, null=조회 실패
let _inqNoApps = false;     // 응모 0건 회원 — 캠페인 문의 탭을 감추고 서비스 문의만(코드 대조 R-3)
const INQ_PAST_PAGE = 20;   // 지난 문의 한 번에 보이는 수 — 나머지는 「もっと見る」(경우의 수 #9)
let _inqPastShown = INQ_PAST_PAGE;
// 닫힌 대화가 「対応中」(진행 중) 목록에 남는 시간 — 서버(505)가 같은 대화를 다시 여는 기준과 같다
const INQ_REOPEN_WINDOW_MS = 24 * 60 * 60 * 1000;
// ── 대화 화면 「＋」 메뉴(画像を添付 / よくある質問)·아래 서랍 (2026-10-07 사용자 지시) ──
//   메뉴는 바깥을 누르거나 Esc·항목 선택으로 닫는다. 서랍은 X·입력란에 초점·보내기·전체 목록 열기·화면 떠남에 닫는다
function toggleMsgPlusMenu() {
  const m = $('msgPlusMenu');
  if (!m) return;
  if (m.style.display === 'none') {
    // 키보드가 열린 채면 먼저 내린다(메뉴·서랍이 키보드에 가리지 않게)
    try { $('msgModalInput')?.blur(); } catch (_e) {}
    m.style.display = '';
    $('msgPlusBtn')?.setAttribute('aria-expanded', 'true');
    setTimeout(() => document.addEventListener('click', _msgPlusOutside, true), 0);
    document.addEventListener('keydown', _msgPlusEsc);
  } else closeMsgPlusMenu();
}
function closeMsgPlusMenu() {
  const m = $('msgPlusMenu');
  if (m) m.style.display = 'none';
  $('msgPlusBtn')?.setAttribute('aria-expanded', 'false');
  document.removeEventListener('click', _msgPlusOutside, true);
  document.removeEventListener('keydown', _msgPlusEsc);
}
function _msgPlusOutside(e) { if (!e.target.closest || !e.target.closest('.msg-plus-wrap')) closeMsgPlusMenu(); }
function _msgPlusEsc(e) { if (e.key === 'Escape') { closeMsgPlusMenu(); $('msgPlusBtn')?.focus(); } }

function openMsgFaqSheet() {
  closeMsgPlusMenu();
  const sh = $('msgFaqSheet');
  if (!sh) return;
  sh.innerHTML = _faqLoaded ? _faqBotCardHtml() : stateLoadingHtml(t('messaging.loading'));
  sh.style.display = '';
  // 아직 질문을 못 받았으면(서비스 대화가 막 열린 참 등) 받는 대로 다시 그린다
  if (!_faqLoaded) {
    const tick = setInterval(() => {
      if (sh.style.display === 'none') { clearInterval(tick); return; }
      if (_faqLoaded) { clearInterval(tick); sh.innerHTML = _faqBotCardHtml(); }
    }, 300);
    setTimeout(() => clearInterval(tick), 10000);
  }
}
function closeMsgFaqSheet() {
  const sh = $('msgFaqSheet');
  if (sh) { sh.style.display = 'none'; sh.innerHTML = ''; }
}

// 「対応中のお問い合わせ」 칸 머리 — 제목 + 오른쪽 「よくある質問」 단추(2026-10-07). 진행 중이 비면 제목 없이 단추만
//   kind: 'campaign' | 'service' — 질문 페이지가 그 탭의 질문만 보인다
function _inqSectionHeadHtml(kind, hasActive) {
  const title = hasActive ? `<div class="inq-section-title">${esc(t('inquiry.currentTitle'))}</div>` : '';
  return `<div class="inq-section-head">${title}
    <button type="button" class="inq-faq-btn" onclick="openFaqPage('${kind}')">
      <span class="material-icons-round notranslate" translate="no" aria-hidden="true">help_outline</span>${esc(t('inquiry.faqBtn'))}
    </button>
  </div>`;
}

// 「新しくお問い合わせ」 단추 아이콘 — 응모이력 메시지 단추와 같은 빈 말풍선(Material chat_bubble_outline 모양) 안에 +.
//   불러오는 아이콘 글꼴(Material Icons Round)에 이 모양이 없어 같은 도형을 그림으로 넣는다(2026-10-07 사용자 지시)
const INQ_NEW_ICON = '<svg class="inq-new-icon" viewBox="0 0 24 24" width="20" height="20" aria-hidden="true" focusable="false">'
  + '<path fill="currentColor" d="M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm0 14H6l-2 2V4h16v12z"/>'
  + '<path fill="currentColor" d="M11 6h2v3h3v2h-3v3h-2v-3H8V9h3z"/></svg>';
// 문의 제목 최대 글자 수 — 서버 검사 제약(507)·입력란 maxlength 와 같은 값
const INQ_TITLE_MAX = 40;

// 문의 입구 — from: 'nav'(햄버거) / 'back'(대화에서 뒤로 — 보던 탭 유지) / 'notif'(옛 알림 — 서비스 탭) / 'withdraw' 등.
//   응모 0건 회원도 이 화면으로 온다 — 캠페인 문의 탭만 감춘다(R-3. 예전엔 대화로 바로 갔다).
async function openInquiryPage(from, pushHistory) {
  if (!currentUser) { navigate('login'); return; }
  // 서비스 문의 새 답장 수·대화 목록을 응모 목록과 함께 새로 받는다(2026-10-06 인수인계) — 대화를 읽고 돌아왔을 때
  //   옛 숫자로 탭이 열리지 않게. 줄 세우면 체감이 느려져 함께 받는다. 실패면 지난 값 유지(refreshNavInquiryBadge 규칙)
  //   캠페인 문의 안 읽은 수(_myMsgUnreadByApp)도 함께 — 캠페인 탭 점·목록 줄 숫자(2026-10-07)
  //   캠페인 지난 문의 판정(응모 끝나고 90일 — 서버 509)도 함께. 🔴 화면은 규칙을 계산하지 않고 서버 값만 쓴다
  const [apps, genThreads, , , appStatus] = await Promise.all([fetchMyApplicationsForInquiry(), fetchMyGeneralInquiryThreads(), refreshNavInquiryBadge(),
    (typeof refreshMyMsgUnread === 'function') ? refreshMyMsgUnread({ skipRerender: true }) : null,
    fetchMyApplicationMessageStatus()]);
  _inqAppStatus = appStatus;
  _inqThreads = genThreads;
  _inqPastShown = INQ_PAST_PAGE;
  _inqNoApps = Array.isArray(apps) && apps.length === 0;
  // 「캠페인 문의」 탭은 대화가 시작된 응모건만 보인다(2026-09-29 사용자 지시). 새 문의는 응모이력의 말풍선 버튼에서.
  const threads = (Array.isArray(apps) && !_inqNoApps) ? await fetchMyApplicationThreads() : (_inqNoApps ? [] : null);
  _inqAllApps = Array.isArray(apps) ? apps : null;
  _inqPicking = false;
  if (Array.isArray(apps) && Array.isArray(threads)) {
    const byId = new Map(apps.map(a => [a.id, a]));
    _inqApps = threads.map(th => byId.get(th.application_id)).filter(Boolean);
  } else {
    _inqApps = null;         // 둘 중 하나라도 실패 — 「불러오지 못했습니다」
  }
  // 새 답장이 있으면 서비스 문의 탭을 먼저 연다 — 햄버거 배지가 가리키는 곳이 화면에 보이게(2026-10-06 사용자 결정).
  //   뒤로가기로 돌아온 경우는 보던 탭 유지, 옛 알림(회원 id)으로 왔으면 서비스 탭
  if (_inqNoApps || from === 'notif') _inqTab = 'other';
  else if (from !== 'back') _inqTab = _navInquiryUnread > 0 ? 'other' : 'app';
  if (navigate('inquiry', pushHistory) === false) return;
  if (!Array.isArray(allCampaigns) || !allCampaigns.length) {
    try { allCampaigns = await getCampaignsCached(); } catch (_e) {}
  }
  renderInquiryBranch();
}

// 탭 둘(2026-09-29 사용자 결정) — 아래에는 목록/안내만, 대화는 눌러서 들어간다.
function renderInquiryBranch() {
  const box = $('inquiryBranchBody');
  if (!box) return;
  const tabSlot = $('inquiryTabSlot');   // 머리 오른쪽 탭 자리 — 고르기 보기·응모 0건이면 비운다
  if (_inqPicking) { if (tabSlot) tabSlot.innerHTML = ''; renderInquiryPick(box); return; }
  // 모양은 햄버거 메뉴 언어 전환 토글(.lang-toggle)과 같게 — 2026-09-29 사용자 지시.
  //   🔴 클래스를 같이 쓰지 않는다 — updateLangToggleUI(mypage.js)가 `.lang-toggle .lang-btn` 을
  //      전역으로 잡아 data-lang 으로 on 을 다시 매겨, 언어를 바꾸면 이 탭의 선택 표시가 사라진다.
  // 서비스 문의 새 답장 수 — 햄버거 배지와 같은 값(_navInquiryUnread)을 쓴다. 따로 세면 두 숫자가 어긋난다.
  //   ⚠️ 햄버거용 data-role 을 재사용하지 않는다(그쪽 위치 스타일이 딸려 온다) — 탭 전용 클래스
  //   탭에는 숫자 대신 **빨간 점**(2026-10-07 사용자 지시) — 점은 탭 모서리에 떠 있어 탭 너비가 바뀌지 않는다(.inq-tab-dot)
  //   캠페인 탭도 같은 점 — 응모건 메시지 안 읽은 수(_myMsgUnreadByApp, 응모이력 카드 배지와 같은 값)
  const dot = `<span class="inq-tab-dot" role="img" aria-label="${esc(t('inquiry.hasNewReply'))}"></span>`;
  const badge = _navInquiryUnread > 0 ? dot : '';
  const appBadge = _inqCampaignUnreadTotal() > 0 ? dot : '';
  const tab = (key, label, extra) => `<button type="button" role="tab" class="inq-tab${_inqTab === key ? ' on' : ''}"
      aria-selected="${_inqTab === key}" onclick="switchInquiryTab('${key}')">${esc(label)}${extra || ''}</button>`;
  let body = '';
  if (_inqTab === 'other') {
    body = _inqServiceHtml();
  } else if (_inqApps === null || (_inqApps.length && _inqAppStatus === null)) {
    // 판정 조회 실패면 전부 「진행 중」으로 그리지 않는다 — 쓰는 칸이 보였다가 서버에 거부당한다
    body = stateErrorHtml(t('inquiry.loadError'), 'retryInquiryApps');
  } else if (!_inqApps.length) {
    // 대화가 아직 없다 — 새 캠페인 문의는 응모이력 카드의 말풍선 버튼에서 시작하므로 그 화면으로 보낸다
    body = _inqSectionHeadHtml('campaign', false) + `<div class="inq-other">
      <p class="inq-other-lead">${esc(t('inquiry.appEmpty'))}</p>
      ${_inqNewThreadBtnHtml()}
    </div>`;
  } else {
    // 서비스 탭처럼 「対応中」 / 「過去」 두 칸(2026-10-07 사용자 결정). 지난 칸 = 취소 응모 + 서버가 「쓸 수 없음」이라 한 응모
    const row = a => {
      const camp = (allCampaigns || []).find(c => c.id === a.campaign_id) || {};
      const title = camp.title || t('inquiry.unknownCampaign');
      // 안 읽은 운영팀 답장 수 — 서비스 문의 줄과 같은 숫자 배지(지난 칸에도 — 운영팀은 계속 쓸 수 있다)
      const n = Number((typeof _myMsgUnreadByApp === 'object' && _myMsgUnreadByApp) ? _myMsgUnreadByApp[a.id] : 0) || 0;
      const unreadBadge = n > 0 ? `<span class="inq-tab-badge inq-row-badge">${esc(n > 9 ? '9+' : String(n))}</span>` : '';
      return `<button type="button" class="inq-app-item" onclick="openMessagesPage(${jsStr(a.id)},'inquiry')">
        <span class="inq-app-title">${esc(title)}</span>${unreadBadge}
        <span class="material-icons-round notranslate" translate="no">chevron_right</span>
      </button>`;
    };
    const active = _inqApps.filter(a => !_inqAppIsPast(a));
    const past = _inqApps.filter(_inqAppIsPast);
    body = _inqSectionHeadHtml('campaign', active.length > 0) + (active.length
      ? `<div class="inq-app-list">${active.map(row).join('')}</div>${_inqNewThreadBtnHtml()}`
      : `<div class="inq-other"><p class="inq-other-lead">${esc(t('inquiry.appEmpty'))}</p>${_inqNewThreadBtnHtml()}</div>`);
    if (past.length) {
      body += `<div class="inq-section-title inq-past-title">${esc(t('inquiry.pastTitle'))}</div>
        <div class="inq-app-list">${past.map(row).join('')}</div>`;
    }
  }
  // 응모 0건 회원은 탭 없이 서비스 문의만(R-3)
  const tabs = _inqNoApps ? '' : `<div class="inq-tabs" role="tablist">${tab('app', t('inquiry.branchApp'), appBadge)}${tab('other', t('inquiry.branchOther'), badge)}</div>`;
  if (tabSlot) tabSlot.innerHTML = tabs;
  box.innerHTML = body;
}

// 캠페인 문의가 「過去」(읽기만)인가 — 취소 응모(지금처럼 바로) 또는 서버가 「쓸 수 없음」(509 — 응모 끝나고 90일).
//   🔴 90일 규칙을 화면에서 계산하지 않는다 — 서버 값(_inqAppStatus)만 본다. 값이 없으면(새 응모 등) 쓸 수 있음
function _inqAppIsPast(app) {
  if (!app) return false;
  if (app.status === 'cancelled') return true;
  const st = _inqAppStatus && _inqAppStatus.get(app.id);
  return !!(st && st.writable === false);
}

// 「対応中」(진행 중) 목록에 들어가나 — 열린 대화 전부 + 닫힌 지 24시간 안인 대화(개정 R2-5).
//   🔴 목록·대화 진입(쓸 수 있나 / 지난 문의인가)이 **이 함수 하나**를 쓴다 — 판정 사본을 만들지 않는다.
//   24시간은 **서버가 준 닫힌 시각**으로 잰다. 기기 시계 때문에 경계에서 어긋나면 서버가 thread_closed 로
//   거부하고 화면이 안내한다(sendMessageFromModal).
function _inqIsActiveThread(th) {
  if (!th) return false;
  if (th.status === 'open') return true;
  return th.status === 'closed' && !!th.closed_at
    && Date.now() - new Date(th.closed_at).getTime() < INQ_REOPEN_WINDOW_MS;
}

// 열린 문의 상한 — 서버 뷰 값(508, 열린 대화만 센다 — 「対応中」 목록 범위와 다르다). 대화가 없으면 상한 아님
function _inqOpenInfo(threads) {
  const row = (threads || [])[0];
  return {
    atLimit: !!(row && row.influencer_at_open_limit),
    openCount: row ? (Number(row.influencer_open_thread_count) || 0) : 0,
  };
}

// 대화 줄 정렬 — 최근 글 순(글이 없으면 연 시각)
function _inqByRecent(a, b) {
  return new Date(b.last_message_at || b.opened_at || 0) - new Date(a.last_message_at || a.opened_at || 0);
}

// 「新しくお問い合わせ」(새로 문의하기) 버튼 — 열린 문의가 상한이면 회색 + 안내 한 줄(감추지 않는다)
function _inqServiceNewBtnHtml(atLimit) {
  if (atLimit) {
    return `<button type="button" class="inq-start-btn" disabled aria-disabled="true">
        ${INQ_NEW_ICON}${esc(t('inquiry.newThread'))}
      </button>
      <p class="inq-limit-note">${esc(t('inquiry.openLimit'))}</p>`;
  }
  return `<button type="button" class="inq-start-btn" onclick="openGeneralInquiryNew('branch')">
      ${INQ_NEW_ICON}${esc(t('inquiry.newThread'))}
    </button>`;
}

// 서비스 문의 탭 본문 — 새로 문의하기 버튼 + 「対応中」 목록 + 지난 문의 목록
//   「新しい返信があります」 줄은 뺐다(2026-10-07 사용자 지시) — 새 답장은 탭 배지·줄마다 배지로 보인다
function _inqServiceHtml() {
  if (_inqThreads === null) {
    return `<div class="inq-other"><p class="inq-other-lead">${esc(t('inquiry.otherLead'))}</p>${stateErrorHtml(t('inquiry.threadsLoadError'), 'retryInquiryApps')}</div>`;
  }
  const active = _inqThreads.filter(_inqIsActiveThread).sort(_inqByRecent);
  // 지난 문의 = 「対応中」에 들지 않는 닫힌 대화 전부, 최근에 닫힌 순
  const past = _inqThreads
    .filter(th => th.status === 'closed' && !_inqIsActiveThread(th))
    .sort((a, b) => new Date(b.closed_at || 0) - new Date(a.closed_at || 0));
  // 「対応中」이 비면 칸 제목도 숨긴다
  const activeHtml = _inqSectionHeadHtml('service', active.length > 0) + (active.length
    ? `<div class="inq-app-list">${active.map(th => _inqThreadRowHtml(th, true)).join('')}</div>` : '');
  // 상자(테두리·배경) 없이 — 「対応中」도 「過去」처럼 칸 제목 + 목록만(2026-10-07 사용자 지시)
  //   새로 문의하기 단추(+상한 안내)는 「対応中」 목록 아래(2026-10-07 사용자 지시) — 목록이 비면 안내 바로 아래
  let html = `<div class="inq-service">
    <p class="inq-other-lead inq-lead-center">${esc(t('inquiry.otherLead'))}</p>
  </div>
  ${activeHtml}
  <div class="inq-service">${_inqServiceNewBtnHtml(_inqOpenInfo(_inqThreads).atLimit)}</div>`;
  if (past.length) {
    const more = past.length > _inqPastShown
      ? `<button type="button" class="inq-more-btn" onclick="showMorePastInquiries()">${esc(t('inquiry.more'))}</button>` : '';
    html += `<div class="inq-section-title inq-past-title">${esc(t('inquiry.pastTitle'))}</div>
      <div class="inq-app-list">${past.slice(0, _inqPastShown).map(th => _inqThreadRowHtml(th, false)).join('')}</div>${more}`;
  }
  return html;
}

// 대화 한 줄 — 날짜 · 제목(없으면 첫 글 미리보기) · (「対応中」의 닫힌 대화면 「対応済み」) · 안 읽은 답장 배지.
//   🔴 지난 문의 줄에도 배지를 단다 — 안 달면 햄버거 배지(합계)만 남고 화면 어디에도 안 보인다
function _inqThreadRowHtml(th, isCurrent) {
  const date = formatDate(th.last_message_at || th.opened_at);
  const first = th.title || th.first_message_preview || t('inquiry.noVisibleMessage');
  const n = Number(th.unread_for_influencer) || 0;
  const badge = n > 0 ? `<span class="inq-tab-badge">${esc(n > 9 ? '9+' : String(n))}</span>` : '';
  const done = (isCurrent && th.status === 'closed') ? `<span class="inq-app-readonly">${esc(t('inquiry.resolved'))}</span>` : '';
  return `<button type="button" class="inq-app-item inq-thread-item" onclick="openGeneralInquiryPage('branch', undefined, ${jsStr(th.thread_id)})">
    <span class="inq-thread-main"><span class="inq-thread-date">${esc(date)}</span><span class="inq-app-title">${esc(first)}</span></span>${done}${badge}
    <span class="material-icons-round notranslate" translate="no">chevron_right</span>
  </button>`;
}

function showMorePastInquiries() { _inqPastShown += INQ_PAST_PAGE; renderInquiryBranch(); }

// 서비스 문의 대화 → 서비스 탭 목록(뒤로가기 · 지난 문의의 「お問い合わせ一覧に戻る」 공용)
function backToInquiryList() { _inqTab = _msgMode === 'app' ? 'app' : 'other'; if (typeof openInquiryPage === 'function') openInquiryPage('back'); }

// 새 문의 화면으로(목록 버튼 · 탈퇴 지름길). presetTitle 은 제목 칸에 미리 채울 값(회원이 고칠 수 있다).
function openGeneralInquiryNew(from, presetTitle) {
  openGeneralInquiryPage(from, undefined, null, { title: presetTitle || '' });
}

// 새 문의 중복 방지값 — 서버 칸이 uuid 형식이라 그 모양으로 만든다(다른 모양이면 형식 오류)
function _inqNewToken() {
  if (window.crypto && typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = Array.from(b, x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

// 「새 문의」 — 캠페인 문의 탭 맨 아래(빈 상태에도). 누르면 응모 고르기 보기(조각 5-B)
function _inqNewThreadBtnHtml() {
  return `<button type="button" class="inq-start-btn" onclick="openInquiryPick()">
    ${INQ_NEW_ICON}${esc(t('inquiry.newThread'))}
  </button>`;
}
function openInquiryPick() { _inqPicking = true; renderInquiryBranch(); const pg = $('page-inquiry'); if (pg) pg.scrollTop = 0; }
// 고르기 보기의 「← お問い合わせ」 — 탭 보기로. (머리글 뒤로 화살표는 조각 5-C 에서 없앴다 — 탭 보기에선 홈으로)
function inquiryBack() {
  if (_inqPicking) { _inqPicking = false; renderInquiryBranch(); return; }
  navigate('home');
}
// 고르기 보기 — 아직 대화가 없는 응모만, 취소된 응모 제외(새로 못 쓰는 막다른 길), 최근 응모순
function renderInquiryPick(box) {
  const started = new Set((_inqApps || []).map(a => a.id));
  const unstarted = (_inqAllApps || []).filter(a => !started.has(a.id));
  const list = unstarted.filter(a => a.status !== 'cancelled');
  const rows = list.map(a => {
    // 응모 표와 캠페인 표 사이에 외래 키가 없어 조회에 붙일 수 없다 — 캠페인 문의 탭처럼 받아 둔 목록에서 찾는다
    const c = (allCampaigns || []).find(x => x.id === a.campaign_id) || {};
    const title = c.title || t('inquiry.unknownCampaign');
    const thumb = c.img1
      ? `<img src="${esc(storageThumbUrl(c.img1))}" data-orig="${esc(c.img1)}" loading="lazy" decoding="async" alt="" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}">`
      : `<span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:var(--muted)">inventory_2</span>`;
    return `<button type="button" class="inq-pick-item" onclick="openMessagesPage(${jsStr(a.id)},'inquiry')">
      <span class="apply-thumb">${thumb}</span>
      <span class="inq-pick-main"><span class="inq-app-title">${esc(title)}</span><span class="inq-pick-status">${getStatusBadge(a.status)}</span></span>
      <span class="material-icons-round notranslate" translate="no">chevron_right</span>
    </button>`;
  }).join('');
  box.innerHTML = `<button type="button" class="back-link detail-back inq-pick-back" onclick="inquiryBack()"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">arrow_back</span>${esc(t('inquiry.title'))}</button>`
    + `<div class="inq-pick-title">${esc(t('inquiry.pickTitle'))}</div>`
    + (rows ? `<div class="inq-app-list">${rows}</div>`
       // 빈 이유가 둘이다 — 전부 이미 대화 중(pickEmpty) / 남은 응모가 전부 취소됨(pickNone). 취소만 있는 회원에게 「모두 시작했다」는 사실이 아니다
       : stateEmptyHtml('', '', t(unstarted.length ? 'inquiry.pickNone' : 'inquiry.pickEmpty')));
}

function switchInquiryTab(key) { _inqTab = key === 'other' ? 'other' : 'app'; renderInquiryBranch(); }

async function retryInquiryApps() { openInquiryPage('back', false); }

// 서비스 문의 주소 판정 — 새 문의 `inquiry-general` · 대화 `inquiry-general-{대화id}`.
//   🔴 주소를 보는 자리(app.js 다섯 곳)는 이 둘을 쓴다 — `=== 'inquiry-general'` 로 비교하면 대화 주소를 놓친다
const INQ_GENERAL_HASH_PREFIX = 'inquiry-general-';
function isInquiryGeneralHash(h) {
  return h === 'inquiry-general' || (typeof h === 'string' && h.startsWith(INQ_GENERAL_HASH_PREFIX));
}
function inquiryThreadIdFromHash(h) {
  return (typeof h === 'string' && h.startsWith(INQ_GENERAL_HASH_PREFIX)) ? (h.slice(INQ_GENERAL_HASH_PREFIX.length) || null) : null;
}

// 서비스 문의 대화 — #page-messages 를 재사용한다.
//   주소: 대화 #inquiry-general-{대화id} · 새 문의 #inquiry-general(사양서 2026-10-06 회원 화면)
//   from: 'nav' / 'branch' / 'withdraw' / 'notif' — 뒤로가기 목적지(navigateBackFromMessages).
//   threadId 없음 = 새 문의 — 제목 칸 + 자주 묻는 질문. 메시지 조회·읽음을 부르지 않는다(R-2).
//     첫 글을 보내는 순간 서버가 대화를 만든다(빈 대화를 미리 만들지 않는다). opts.title = 제목 칸 미리 채움.
//   threadId 있음 = 「対応中」 대화면 쓸 수 있고, 지난 문의면 읽기만.
async function openGeneralInquiryPage(from, pushHistory, threadId = null, opts = {}) {
  if (!currentUser) { navigate('login'); return; }
  _stopMsgPoll();   // 같은 페이지 안에서 다른 대화로 옮길 때 — navigate 가 정리 함수를 건너뛴다
  _toggleMsgNewBanner(false);
  _msgMode = 'general';
  _msgCurrentAppId = null;
  _msgGeneralThreadId = threadId || null;
  _msgGeneralPast = false;
  _msgGeneralToken = threadId ? null : _inqNewToken();
  _msgFrom = from || 'nav';
  _msgPendingFiles = [];
  _faqLoaded = false;
  _faqOverlayOpen = false;
  const hash = _msgGeneralThreadId ? INQ_GENERAL_HASH_PREFIX + _msgGeneralThreadId : 'inquiry-general';
  if (navigate(hash, pushHistory) === false) { _msgMode = 'app'; _msgGeneralThreadId = null; return; }
  // 기록을 안 남기고 들어왔으면(뒤로가기·새로고침) 주소만 맞춘다 — 새로고침이 이 화면으로 돌아오게.
  if (pushHistory === false && location.hash !== '#' + hash) {
    try { history.replaceState({page: hash}, '', '#' + hash); } catch (_e) {}
  }
  _msgSetGeneralHeader('');
  // 일반 문의에는 응모 상태 한 줄이 없다(특정 응모가 아니므로)
  const sl = $('msgStatusLine'); if (sl) { sl.style.display = 'none'; sl.innerHTML = ''; }
  const myThread = _msgGeneralThreadId;
  // 기다리는 사이 화면을 떠났거나 다른 대화로 옮겼으면 여기서 멈춘다 —
  //   안 멈추면 응모 번호 없이 응모건 조회를 부르거나 남의 화면에 그린다.
  const stillHere = () => _msgMode === 'general' && _msgGeneralThreadId === myThread;
  const thread = $('msgModalThread');
  if (thread) thread.innerHTML = stateLoadingHtml(t('messaging.loading'));

  if (!myThread) {
    _msgPrepareCompose(false, false);
    _msgShowSubject(true, opts.title || '');
    const myToken = _msgGeneralToken;
    // 자주 묻는 질문 안내는 새 문의에서만(개발 기본값 — 이미 있는 대화를 열 때는 띄우지 않는다).
    //   대화 목록은 열린 문의 안내(N건·상한)용 — 실패면 안내만 생략한다(보내면 서버가 상한을 다시 본다)
    const [, threads] = await Promise.all([setupFaqGate(null, {}, { general: true }), fetchMyGeneralInquiryThreads()]);
    if (!stillHere() || _msgGeneralToken !== myToken) return;
    _msgRenderOpenNote(threads ? _inqOpenInfo(threads) : null);
    renderMessageThread([]);
    _msgLastCount = 0;
    closeFaqOverlay();
    return;   // 새 글 감지(폴링) 없음 — 아직 대화가 없다
  }

  try {
    // 이 대화가 「対応中」(진행 중)인지 지난 문의인지는 서버 값(대화 목록)으로 정한다
    const threads = await fetchMyGeneralInquiryThreads();
    if (!stillHere()) return;
    if (threads === null) throw new Error('general_inquiry_threads_load_failed');
    const th = threads.find(x => x.thread_id === myThread);
    if (!th) {
      // 남의 대화·없는 대화 주소 — 안내만 하고 쓰지 못하게(뒤로가기는 서비스 탭 목록)
      _msgPrepareCompose(false, false);
      const inputRow = document.querySelector('#page-messages .msg-input-row');
      if (inputRow) inputRow.style.display = 'none';
      if (thread) thread.innerHTML = stateEmptyHtml('error_outline', '', t('inquiry.threadNotFound'));
      return;
    }
    _msgGeneralPast = !_inqIsActiveThread(th);
    _msgSetGeneralHeader(th.title || '');
    _msgPrepareCompose(false, _msgGeneralPast);
    // 「＋」 → 「よくある質問」 서랍용 질문 목록(서비스 갈래) — 기다리지 않고 함께 받는다(지난 문의는 입력줄이 없어 안 받는다)
    if (!_msgGeneralPast) setupFaqGate(null, {}, { general: true });
    const msgs = await _msgLoad();
    if (!stillHere()) return;
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0;
    _toggleMsgNewBanner(false);
    closeFaqOverlay();
    await _msgMarkRead();
    if (typeof refreshNotifBadge === 'function') refreshNotifBadge({force: true});
    if (!_msgGeneralPast) _startMsgPoll();   // 지난 문의는 운영팀도 못 쓴다 — 감지할 새 글이 없다
  } catch (e) {
    console.error('[openGeneralInquiryPage]', e);
    logAppError('openGeneralInquiryPage', e);
    closeFaqOverlay();   // 응모건 화면에서 바로 넘어온 경우 그쪽 덮개가 남지 않게
    if (thread) thread.innerHTML = stateErrorHtml(t('messaging.loadError'), 'retryMessageThread');
  }
}

// 햄버거 「お問い合わせ」 배지 — 일반 문의 안 읽은 답장 수. 실패(null)면 지난 값을 유지한다.
let _navInquiryUnread = 0;
async function refreshNavInquiryBadge() {
  if (!currentUser) return;
  const n = await fetchMyGeneralInquiryUnread();
  if (n !== null) _navInquiryUnread = n;
  applyNavInquiryBadge();
}
// 캠페인 문의(응모건 메시지) 안 읽은 수 합계 — 응모이력 카드 배지와 같은 값(_myMsgUnreadByApp, mypage.js)
function _inqCampaignUnreadTotal() {
  const map = (typeof _myMsgUnreadByApp === 'object' && _myMsgUnreadByApp) ? _myMsgUnreadByApp : {};
  return Object.values(map).reduce((s, n) => s + (Number(n) || 0), 0);
}
// 햄버거 「お問い合わせ」 숫자 = 서비스 문의 + 캠페인 문의 안 읽은 답장(2026-10-07 사용자 결정).
//   🔴 두 값이 따로 갱신된다 — 서비스는 refreshNavInquiryBadge, 캠페인은 refreshMyMsgUnread → updateNavMsgBadge.
//      둘 다 이 함수를 부른다(한쪽만 부르면 다른 쪽 갱신 때 숫자가 되돌아간다)
function applyNavInquiryBadge() {
  const total = (_navInquiryUnread || 0) + _inqCampaignUnreadTotal();
  document.querySelectorAll('[data-role="nav-inquiry-badge"]').forEach(b => {
    if (total > 0) { b.textContent = total > 9 ? '9+' : String(total); b.classList.remove('hidden'); }
    else b.classList.add('hidden');
  });
}

// 메시지 페이지를 떠날 때 정리 (navigate 의 페이지 전환 훅 + 직접 호출 공용).
//   모달이 아니라 페이지이므로 표시/숨김은 navigate 가 관리하고, 여기선 폴링·상태만 정리.
function cleanupMessagesPage() {
  _stopMsgPoll();
  _toggleMsgNewBanner(false);
  _msgCurrentAppId = null;
  _msgMode = 'app';   // 일반 문의로 바꿔 둔 것을 되돌린다 — 다음 응모건 진입이 옛 모드를 물려받지 않게
  _msgGeneralThreadId = null;
  _msgGeneralPast = false;
  _msgAppPast = false;
  closeMsgPlusMenu();
  closeMsgFaqSheet();
  _msgGeneralToken = null;   // 떠나면 버린다 — 다시 들어오면 새 문의는 새 값
  _msgShowSubject(false, '');
  _msgRenderOpenNote(null);
  const pastNote = $('msgPastNote'); if (pastNote) pastNote.style.display = 'none';
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
  // 대화 맨 위 봇 안내 카드는 뺐다(2026-10-07) — 「＋」 → 「よくある質問」 아래 서랍(openMsgFaqSheet)에서 연다
  const botCard = '';
  if (!messages || !messages.length) {
    // 빈 대화의 기본 안내는 「아래 입력란에서…」다 — 입력란이 없는 대화(90일 지난 · 취소)에는 맞지 않아 그 사정을 쓴다
    const emptyKey = (_msgMode === 'app' && _msgAppPast) ? 'inquiry.campaignPastReadOnly'
      : (_msgMode === 'app' && typeof isApplicationCancelled === 'function' && isApplicationCancelled(_msgCurrentAppId)) ? 'messaging.cancelledReadOnly'
      : 'messaging.emptyThread';
    const plusHint = emptyKey === 'messaging.emptyThread' ? ' ' + t('messaging.emptyThreadPlusHint') : '';
    thread.innerHTML = botCard + stateEmptyHtml('chat_bubble_outline', '', t(emptyKey) + plusHint);
    return;
  }
  const now = Date.now();
  const cardsHtml = messages.map(msg => {
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
    // 자동 번역 병기 (마이그레이션 235): 받은 메시지(운영팀 발신)에 번역본이 있으면
    // 번역문을 본문 위치에, 원문(한국어)을 아래 작은 글씨로 병기 — 오역 시 원문 확인 경로 확보.
    // 번역본도 외부 API 반환값이므로 esc() 필수. 번역 없으면(NULL/실패/과거 메시지) 원문만.
    // 🔴 **일본어 번역일 때만**(translated_lang === 'ja') — 운영팀이 일본어로 쓴 글엔 번역 함수가 관리자용 한국어
    //    번역을 만든다(2026-10-06). 조건이 없으면 회원에게 한국어가 본문으로 보인다. 아니면 원문만
    //    🔴 배포 순서: 이 화면이 운영(main)에 먼저 나가고, 번역 서버 함수는 그 뒤에(옛 앱은 이 조건이 없다)
    let bodyHtml;
    if (!mine && msg.body_translated && msg.translate_status === 'done' && msg.translated_lang === 'ja') {
      const transHtml = esc(msg.body_translated).replace(/\n/g, '<br>');
      const origHtml = esc(msg.body || '').replace(/\n/g, '<br>');
      bodyHtml = `${transHtml}
        <div class="msg-trans-orig"><span class="msg-trans-label">${esc(t('messaging.originalLabel'))}</span>${origHtml}</div>
        <div class="msg-trans-caption">${esc(t('messaging.translatedLabel'))}</div>`;
    } else {
      bodyHtml = esc(msg.body || '').replace(/\n/g, '<br>');
    }

    // 첨부 썸네일 (signed URL 비동기 로드)
    let attachHtml = '';
    const atts = Array.isArray(msg.attachments) ? msg.attachments : [];
    // 파기된 첨부(작업 12-B)는 **그리지 않는다.**
    //   ⚠️ 관리자 화면과 달리 「파기됨」 상자를 두지 않는 이유 — 탈퇴가 확정된 회원은
    //      로그인 자체가 막히므로(작업 8) 이 화면에 도달할 수 없다. **도달할 수 없는
    //      자리에 새 일본어 문구와 번역 열쇠말을 만들면 검증할 수 없는 문구가 는다.**
    //   ⚠️ 그래도 걸러는 낸다 — 안 걸러면 어떤 이유로든 주소가 빈 첨부가 들어왔을 때
    //      「이미지를 불러오지 못했습니다」가 그대로 뜬다.
    const visibleAtts = atts.filter(a => !msgAttachmentPurged(a));
    if (visibleAtts.length) {
      attachHtml = `<div class="msg-attachments">${visibleAtts.map((a, i) => {
        const elId = `msgatt-${msg.id}-${i}`;
        loadMsgAttachThumb(elId, a.path);
        return `<div class="msg-attach-thumb" id="${elId}" onclick="openMsgLightbox(${jsStr(a.path)})"><span class="material-icons-round notranslate" translate="no">image</span></div>`;
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
  // 운영팀 미응답 안내 — 마지막 살아있는 메시지가 인플 발신이면 대화 맨 아래 인라인 표시.
  //   (기존 입력창 위 고정 배너 #msgPendingNotice → 대화 영역 안으로 이동, 대화 공간 확보 2026-05-27)
  const visibleMsgs = messages.filter(m => !m.mask_state || m.mask_state === 'visible');
  const lastVisible = visibleMsgs[visibleMsgs.length - 1];
  //   지난 문의(서비스 문의, 닫히고 24시간 지남)는 답장이 오지 않으니 그 자리에 「끝난 문의」 안내를 둔다(2026-10-06 사용자 지시)
  const pendingHtml = (_msgMode === 'general' && _msgGeneralPast)
    ? `<div class="msg-pending-inline">${esc(t('inquiry.pastReadOnly'))}</div>`
    : (_msgMode === 'app' && _msgAppPast)
    ? `<div class="msg-pending-inline">${esc(t('inquiry.campaignPastReadOnly'))}</div>`
    : (lastVisible && lastVisible.sender_kind === 'influencer')
      ? `<div class="msg-pending-inline">${esc(t('messaging.pendingNotice'))}</div>` : '';
  thread.innerHTML = botCard + cardsHtml + pendingHtml;
  // 최신 메시지로 스크롤
  thread.scrollTop = thread.scrollHeight;
}

// (updateMsgPendingNotice 폐기 2026-05-27 — 운영팀 미응답 안내를 renderMessageThread 의
//  대화 맨 아래 인라인(.msg-pending-inline)으로 이동. 입력창 위 고정 배너 제거로 대화 공간 확보)

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
    logAppError('openMsgLightbox', e);
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
    const msgs = await _msgLoad();
    renderMessageThread(msgs);
    _msgLastCount = msgs?.length || 0; // 도착 감지 기준 동기화 (회수로 인한 변동 반영)
  } catch (e) {
    console.error('[confirmWithdrawMessage]', e);
    logAppError('confirmWithdrawMessage', e);
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
  if (!_msgActive()) return;
  closeMsgFaqSheet();
  // 취소된 응모는 읽기만 가능하다(F-11). 작성 줄은 감춰 두지만, 화면 상태가 어긋난 채로
  //   이 함수에 닿는 경로(캐시가 늦게 채워져 취소 판정이 나중에 바뀌는 등)가 있어 여기서도 막는다.
  if (typeof isApplicationCancelled === 'function' && isApplicationCancelled(_msgCurrentAppId)) {
    if (typeof toast === 'function') toast(t('messaging.cancelledReadOnly'));
    return;
  }
  // 지난 문의도 읽기만 — 작성 줄은 감춰 두지만 같은 이유로 여기서도 막는다
  if (_msgMode === 'general' && _msgGeneralPast) {
    if (typeof toast === 'function') toast(t('inquiry.pastReadOnly'));
    return;
  }
  if (_msgMode === 'app' && _msgAppPast) {
    if (typeof toast === 'function') toast(t('inquiry.campaignPastReadOnly'));
    return;
  }
  const inputEl = $('msgModalInput');
  const body = (inputEl?.value || '').trim();
  // 새 문의는 제목이 필수(1~40자) — 첨부를 올리기 전에 막는다. 서버도 같은 규칙으로 거부한다
  const isNewInquiry = _msgMode === 'general' && !_msgGeneralThreadId;
  const subject = isNewInquiry ? ($('msgSubjectInput')?.value || '').trim() : null;
  if (isNewInquiry) {
    if (!subject) { _msgSubjectError('inquiry.subjectRequired'); $('msgSubjectInput')?.focus(); return; }
    if (Array.from(subject).length > INQ_TITLE_MAX) { _msgSubjectError('inquiry.subjectTooLong'); $('msgSubjectInput')?.focus(); return; }
    _msgSubjectError('');
  }
  if (!body && !_msgPendingFiles.length) { toast(t('messaging.emptyInput')); return; }

  // 봇 안내 카드 방식(2026-05-22): 발송을 가로채는 게이트 폐기 — 발송은 항상 바로 진행.
  //   FAQ 추천은 스레드 맨 위 봇 카드(_faqBotCardHtml)로 상시 노출.
  // 잠금·버튼 복원은 공통 헬퍼가 맡는다(사양서 2026-07-31 §3 1-3). 예전 _msgSending 플래그를
  //   대체 — 동작은 같고, 첨부 업로드가 오래 걸릴 때 진행 표시가 뜨는 것이 추가됐다.
  //   ⚠️ 진행 문구는 넣지 않는다(빈 문자열) — 보내기 버튼은 40px 원형 아이콘 버튼이라
  //      스피너+문구가 안 들어가고 넘친다. 잠금만으로 연타는 이미 막힌다.
  return withSubmitLock('sendMsg:' + (_msgMode === 'general' ? 'general' : _msgCurrentAppId), 'msgModalSendBtn', '', async function() {
    try {
      // 첨부 압축·업로드 (순차 — 실패 시 즉시 중단)
      const attachments = [];
      for (const f of _msgPendingFiles) {
        try {
          attachments.push(await _msgUpload(f));
        } catch (e) {
          console.error('[sendMessageFromModal] 첨부 업로드', e);
          // too_large 는 정상 거부(용량 초과 안내) — 그 외는 예상 못 한 오류로 기록된다.
          logAppError('uploadMessageAttachment', e, ['too_large']);
          toast(e?.message === 'too_large' ? t('messaging.attachTooLarge') : t('messaging.attachUploadFailed'));
          return;   // 잠금 해제는 헬퍼 finally 가 한다
        }
      }
      const sent = await _msgSend(body, attachments, subject);
      // 서비스 문의 — 새 문의면 서버가 만든 대화로 화면을 옮긴다. 제목 칸을 닫고 머리글에 제목.
      //   주소도 그 대화로 바꿔 새로고침·뒤로가기가 같은 대화로 돌아오게. 새 글 감지도 이때 켠다
      if (_msgMode === 'general' && sent?.thread_id && sent.thread_id !== _msgGeneralThreadId) {
        _msgGeneralThreadId = sent.thread_id;
        _msgGeneralPast = false;
        _msgGeneralToken = null;
        _msgShowSubject(false, '');
        _msgRenderOpenNote(null);
        if (isNewInquiry) _msgSetGeneralHeader(subject);
        const h = INQ_GENERAL_HASH_PREFIX + sent.thread_id;
        try { history.replaceState({page: h}, '', '#' + h); } catch (_e) {}
        _startMsgPoll();
      }
      // 입력 초기화 + 재로드
      if (inputEl) { inputEl.value = ''; inputEl.style.height = ''; } // 전송 후 1줄로 리셋
      _msgPendingFiles = [];
      renderMsgAttachPreview();
      const msgs = await _msgLoad();
      renderMessageThread(msgs);
      _msgLastCount = msgs?.length || 0; // 내가 보낸 메시지로 「새 메시지 도착」 띠가 오인 표시되지 않도록
      _toggleMsgNewBanner(false);
      // 전체 보기 오버레이는 닫고 스레드만 (봇 카드는 renderMessageThread 가 다시 그림)
      closeFaqOverlay();
    } catch (e) {
      console.error('[sendMessageFromModal]', e);
      // 의도된 RPC 예외(RAISE EXCEPTION = SQLSTATE P0001, 일본어 안내문)만 그대로 노출.
      // 그 외 DB 내부 에러(42702 등)는 일반 메시지로 — 원문 노출 방지
      //   ⚠️ 바로 그 「일반 메시지로 덮는」 경로가 취소 사고와 같은 모양이다.
      //      P0001(서버가 의도적으로 거부)은 정상 거부, 나머지는 예상 못 한 오류로 기록.
      logAppError(_msgMode === 'general' ? 'sendGeneralInquiryMessage' : 'sendApplicationMessage', e, e?.code === 'P0001' ? [String(e.message || '')] : null);
      // 508 거부 코드(영문)는 화면에 그대로 내지 않는다. 🔴 어느 거부에서도 쓴 글·제목·첨부는 지우지 않는다
      //   (지우는 곳은 성공 뒤 한 곳뿐)
      const key = (_msgMode === 'general' && e?.code === 'P0001') ? _msgGeneralRejectKey(String(e?.message || ''), isNewInquiry) : null;
      if (key === 'inquiry.subjectRequired' || key === 'inquiry.subjectTooLong') {
        _msgSubjectError(key);
      } else if (key) {
        toast(t(key));
      } else {
        toast(e?.code === 'P0001' && e?.message ? e.message : t('messaging.sendFailed'));
      }
    }
  });
}

// 서비스 문의 거부 코드 → 안내 문구 키(508). 모르는 코드면 null(호출부가 서버 문구·일반 실패로).
//   isNew: 새 문의 화면에서 보냈나 — 같은 코드라도 화면마다 안내가 다르다(사양서 개정 「거부 안내」).
function _msgGeneralRejectKey(code, isNew) {
  if (/title_required/.test(code)) return 'inquiry.subjectRequired';
  if (/title_too_long/.test(code)) return 'inquiry.subjectTooLong';
  if (/too_many_open_threads/.test(code)) return isNew ? 'inquiry.openLimit' : 'inquiry.openLimitReopen';
  if (/thread_closed/.test(code)) {
    // 새 문의 화면: 같은 중복 방지값이 24시간 지난 대화에 닿았다 — 값을 새로 만들어 다음 보내기는 새 대화로
    if (isNew) _msgGeneralToken = _inqNewToken();
    return 'inquiry.threadClosedNew';
  }
  if (/thread_not_found|no_open_thread|thread_required|new_message_since_view/.test(code)) return 'inquiry.threadNotFound';
  return null;
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

// (FAQ_STATUS_NAV 제거 2026-05-27 — 상태줄 '화면 열기' 버튼 삭제로 미사용)

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
  // ⚠️ 영수증 마감은 **결과물 제출 마감일**이다(2026-08-11). 구매 종료일이 아니다 —
  //   08-06 부터 신규 리뷰어형은 구매 기간을 모집 기간과 같게 저장하므로, 구매 종료일을
  //   쓰면 실제보다 2주 이른 날짜를 말하게 된다. 캠페인 상세 화면과 같은 날짜여야 한다.
  //   제출 마감일이 비어 있는 옛 캠페인만 구매 종료일로 물러선다(운영 1건).
  const deadlineMs = (key === 'receipt')
    ? Date.parse(camp?.submission_end || camp?.purchase_end || '')
    : (key === 'post_deadline' ? Date.parse(camp?.submission_end || '') : NaN);
  const mmdd = isNaN(deadlineMs) ? '' : formatMMDD(deadlineMs);

  let text = (t(`messaging.statusLine.${key}`) || '').replace('{date}', mmdd);

  // 반려 케이스는 실제 사유를 덧붙임 (esc 필수)
  let extra = '';
  if (key === 'partial_reject' || key === 'all_reject') {
    const reason = _faqRejectReason(app);
    if (reason) extra = `<div class="msg-status-reason">${esc(t('messaging.statusLine.reasonLabel'))}: ${esc(reason)}</div>`;
  }

  // '화면 열기' 버튼 제거 (2026-05-27 사용자 요청) — 상태 한 줄만 표시해 영역 더 슬림하게
  el.innerHTML = `<div class="msg-status-row"><span class="msg-status-text">${esc(text)}</span></div>${extra}`;
  el.style.display = text ? '' : 'none';
}

// MM/DD 포맷 (ja-JP)
// 안내 문장 안의 마감일 — 사이트 공통 표기 YYYY/MM/DD 로 통일 (2026-07-23, 구 MM/DD 축약 폐지)
function formatMMDD(ms) {
  if (isNaN(ms)) return '';
  return formatDate(new Date(ms));
}

// ── FAQ 트리 ──

// 동적 치환 컨텍스트 계산 (§5-1) — {required}=이 캠페인의 필요 팔로워, {current}=내 팔로워
//   ⚠️ 최소 팔로워 조건은 채널 조건에 따라 갈래가 셋이다(채널 하나 / 또는 / 그리고).
//      예전에는 `camp.min_followers` 숫자 하나와 **본인 대표 SNS** 만 봐서 두 곳이 틀렸다 —
//      ①「그리고」 캠페인은 그 칸이 0 이라 **필요 수치 줄이 통째로 사라졌고**
//      ②캠페인에 들어 있지도 않은 채널(대표 SNS)의 팔로워 수를 「현재」로 보여줬다.
//      이제 무엇을 보여줄지는 공용 함수(`minFollowersDisplay`, shared.js)가 정하고
//      여기서는 **문구만** 만든다 — 캠페인 상세와 같은 재료를 써야 두 화면이 안 갈린다.
//   ⚠️ 값은 `renderFaqBody` 가 esc() 하므로 **태그 없는 평문**이어야 한다
//      (캠페인 상세용 `minFollowersDetailLines` 는 <span> 을 섞어 그대로 못 쓴다).
function _buildFaqCtx(camp) {
  const ctx = {};
  const label = ch => (typeof getChannelLabelLocal === 'function' ? getChannelLabelLocal(ch) : '') || ch;
  // 리뷰어형은 `minFollowersDisplay` 가 null 을 주고, **행사는 여기서 따로 뺀다** —
  //   그 함수는 행사를 모른다. 실제 응모 게이트(application.js)도 행사면 팔로워 검사
  //   자체를 안 타므로 화면도 같은 기준으로 맞춘 것이다.
  const isEvent = (typeof isEventCampaign === 'function') && isEventCampaign(camp);
  const d = (!isEvent && typeof minFollowersDisplay === 'function') ? minFollowersDisplay(camp) : null;

  const all = (typeof campaignChannelTokens === 'function') ? campaignChannelTokens(camp) : [];
  let need = '';
  let needChannels = [];
  if (d && d.kind === 'and') {
    // 값을 안 넣은 채널은 검사하지 않으므로 「필요」에서도 「현재」에서도 뺀다.
    const rows = (d.rows || []).filter(r => Number(r.required) > 0);
    need = rows.map(r => `${label(r.channel)} ${Number(r.required).toLocaleString()}${t('detail.minFollowersSuffix')}`).join(' / ');
    needChannels = rows.map(r => r.channel);
  } else if (d && d.kind === 'or') {
    need = t('detail.minFollowersAnyChannel').replace('{n}', Number(d.required).toLocaleString());
    needChannels = all;
  } else if (d) {
    const only = all[0];
    need = `${only ? label(only) + ' ' : ''}${Number(d.required).toLocaleString()}${t('detail.minFollowersSuffix')}`;
    needChannels = only ? [only] : [];
  }

  // 첫 줄({intro})은 조건 유무로 갈린다 — 예전에는 본문에 「조건이 있습니다」가 박혀 있어
  //   **조건이 없는 캠페인(리뷰어형·행사)에도 그대로 떴다**(바로 아래 두 줄은 값이 없어
  //   빠지므로, 있다고 해 놓고 아무것도 안 보여 주는 답변이 됐다).
  //   ⚠️ 이 한 줄의 문구만 본문이 아니라 번역 파일에 있다 — 갈래를 화면이 정하기 때문.
  ctx.intro = need ? t('messaging.faqFollowerIntroHas') : t('messaging.faqFollowerIntroNone');
  if (!need) return ctx;
  ctx.required = need;

  // 「현재」는 **위 「필요」에 나온 채널만** 센다 — 조건이 없는 채널 숫자를 함께 보여주면
  //   무엇을 고쳐야 하는지 오히려 흐려진다.
  const p = (typeof currentUserProfile !== 'undefined' ? currentUserProfile : null) || {};
  const seen = {};
  const mine = [];
  needChannels.forEach(ch => {
    // Qoo10 은 자체 팔로워 개념이 없어 Instagram 값을 빌려 쓴다(판정도 같다).
    //   같은 숫자를 두 줄로 보여주지 않게 한 번만 센다.
    const key = (ch === 'qoo10') ? 'instagram' : ch;
    if (seen[key]) return;
    seen[key] = true;
    const n = (typeof followerCountForChannel === 'function') ? followerCountForChannel(p, ch) : 0;
    mine.push(t('detail.minFollowersCurrent').replace('{channel}', label(ch)).replace('{n}', Number(n || 0).toLocaleString()));
  });
  if (mine.length) ctx.current = mine.join(' / ');
  return ctx;
}

// 본문 동적 치환 (§5-1) — 화이트리스트 토큰만, 값 없으면 그 토큰이 든 줄 통째 생략, 치환값 esc
//   ⚠️ 여기에 없는 이름은 치환도 안 되고 **줄이 빠지지도 않는다**(본문에 글자 그대로 남는다).
//      본문에 새 자리를 만들면 이 배열에 반드시 함께 넣을 것.
const FAQ_TOKEN_WHITELIST = ['intro', 'required', 'current'];
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
// faqNodeChainActive — shared.js 로 옮겼다(관리자 메시지 화면 「자주 묻는 질문」 창도 쓴다, 2026-10-08)

//   opts.general — 일반 문의 「그 외」 갈래(사양서 §7): 카테고리 셋 안의 단계 무관 항목만.
let _faqLoadSeq = 0;   // 불러오기 차례 — 늦게 끝난 옛 불러오기가 새 화면의 질문 목록을 덮지 않게(질문 페이지 ↔ 대화 화면)
async function setupFaqGate(app, camp, opts) {
  const mySeq = ++_faqLoadSeq;
  _faqApp = app; _faqCamp = camp;
  // 가리킬 캠페인이 없는 자리(질문 페이지·서비스 문의)는 「이 캠페인에는 조건이 없다」가 틀린 말이라 일반 문구로
  _faqCtx = (camp && camp.id) ? _buildFaqCtx(camp) : { intro: t('messaging.faqFollowerIntroGeneric') };
  try {
    const all = await fetchFaqNodes();
    if (mySeq !== _faqLoadSeq) return;   // 그사이 다른 화면이 새로 불렀다
    // 자기 자신뿐 아니라 **위쪽(카테고리)이 살아 있는지도** 본다.
    //   예전에는 `n.active` 만 봐서, 관리자가 카테고리를 비활성해도 그 안의 질문이
    //   추천 카드에 계속 떴다 — 「안 보이게 했다」고 생각한 내용이 인플루언서에게 그대로 갔다.
    //   위로 거슬러 올라가며 하나라도 꺼져 있으면 뺀다(도중에 부모가 없으면 거기서 멈춘다).
    const _byId = {};
    (all || []).forEach(n => { if (n && n.id) _byId[n.id] = n; });
    _faqNodes = (all || []).filter(n => faqNodeChainActive(n, _byId));
    // 노출 위치(510) — 서비스 문의는 「서비스」, 그 외(캠페인 대화·캠페인 질문 페이지)는 「캠페인」 칸
    const scope = (opts && opts.general) ? 'service' : 'campaign';
    _faqNodes = _faqNodes.filter(n => faqNodeVisibleIn(n, _byId, scope));
    _faqLoaded = true;
  } catch (e) {
    if (mySeq !== _faqLoadSeq) return;
    console.error('[setupFaqGate]', e);
    // ⚠️ 실패하면 자주 묻는 질문이 통째로 사라진 채 문의 창구가 열린다(사용자는 이유를 모름).
    logAppError('setupFaqGate', e);
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
    <div class="msg-card-bot-head"><span class="material-icons-round notranslate" translate="no">support_agent</span>${esc(t('messaging.faq.suggestHead'))}
      <button type="button" class="msg-faq-sheet-close" onclick="closeMsgFaqSheet()" data-i18n-attr="aria-label:common.close" aria-label="${esc(t('common.close'))}">
        <span class="material-icons-round notranslate" translate="no" aria-hidden="true">close</span>
      </button>
    </div>
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

// 질문 목록을 그릴 자리 — 대화 화면 오버레이(#msgFaqTree) 또는 따로 떨어진 질문 페이지(#faqPageBody, 2026-10-07).
//   🔴 그리는 함수(renderFaqCategories·openFaqCategory·openFaqItem)는 이 자리에만 쓴다 — 사본을 만들지 않는다.
//      페이지에 들어갈 때 'faqPageBody' 로 바꾸고, 떠날 때(cleanupFaqPage) 반드시 되돌린다
let _faqHostId = 'msgFaqTree';
function _faqHostEl() { return $(_faqHostId); }
function _faqOnPage() { return _faqHostId === 'faqPageBody'; }

// ── 「よくある質問」 전체 보기 오버레이 (대화 중 상시 진입, §2 결정 4) ──
function openFaqOverlay(skipRender) {
  const ov = $('msgFaqTree');
  if (!ov) return;
  closeMsgFaqSheet();
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
  if (!prev) { if (_faqOnPage()) { leaveFaqPage(); return; } closeFaqOverlay(); return; }
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
  const tree = _faqHostEl();
  if (!tree) return;
  if (!opts || !opts.noPush) _faqNav = [{ view: 'cats' }];
  const cats = _faqSortNodes(_faqNodes.filter(n => n.kind === 'category' && !n.parent_id));
  if (!cats.length) {
    tree.innerHTML = stateEmptyHtml('help_outline', '', t('messaging.faq.unavailable'));
    return;
  }
  const chips = cats.map(c =>
    `<button type="button" class="msg-faq-chip" onclick="openFaqCategory('${esc(c.id)}')">${esc(_faqPick(c, 'label'))}</button>`
  ).join('');
  tree.innerHTML = `
    ${_faqOnPage() ? '' : _faqOverlayHeaderHtml(t('messaging.faq.allTitle'))}
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

// 하위 단계 머리 — 제목 왼쪽에 아이콘만 있는 뒤로 단추(2026-10-07 사용자 지시 — 「目録へ」 글자 단추 대신)
function _faqSubHeadHtml(title) {
  return `<div class="msg-faq-subhead">
    <button type="button" class="msg-faq-back-icon" onclick="faqBack()" aria-label="${esc(t('messaging.faq.back'))}">
      <span class="material-icons-round notranslate" translate="no" aria-hidden="true">arrow_back</span>
    </button>
    <div class="msg-faq-cat-title">${esc(title || '')}</div>
  </div>`;
}

// 카테고리 선택 → 질문 목록 (2단)
function openFaqCategory(catId, opts) {
  const tree = _faqHostEl();
  const cat = _faqNodes.find(n => n.id === catId);
  if (!tree || !cat) return;
  if (!opts || !opts.noPush) _faqNav.push({ view: 'category', id: catId });
  const items = _faqSortNodes(_faqNodes.filter(n => n.kind === 'item' && n.parent_id === catId));
  const list = items.map(q =>
    `<button type="button" class="msg-faq-q" onclick="openFaqItem('${esc(q.id)}')">${esc(_faqPick(q, 'label'))}<span class="material-icons-round notranslate" translate="no">chevron_right</span></button>`
  ).join('');
  tree.innerHTML = `
    ${_faqSubHeadHtml(_faqPick(cat, 'label'))}
    <div class="msg-faq-qlist">${list || stateEmptyHtml('help_outline', '', t('messaging.faq.unavailable'))}</div>
    <button type="button" class="msg-faq-contact-link" onclick="faqStartDirectContact(null)">${esc(t('messaging.faq.contactBtn'))}</button>
  `;
  tree.scrollTop = 0;
}

// 질문 선택 → 답변 카드 또는 분기(자식 item) 또는 바로 직접 문의(handoff)
function openFaqItem(itemId, opts) {
  const tree = _faqHostEl();
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
      ${_faqSubHeadHtml(_faqPick(node, 'label'))}
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
    actionBtn = `<button type="button" class="msg-faq-action-btn" onclick="faqNavigate(${jsStr(node.action_target)})"><span class="material-icons-round notranslate" translate="no">open_in_new</span>${esc(actLabel)}</button>`;
  }
  tree.innerHTML = `
    ${_faqSubHeadHtml(_faqPick(node, 'label'))}
    <div class="msg-faq-answer">
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
  if (_faqOnPage()) { renderFaqCategories(); return; }   // 질문 페이지 — 첫 단계(카테고리)로
  navigateBackFromMessages();
}

// [直接お問い合わせ] → 전체 보기 오버레이 닫고 입력란 포커스 + 'handoff' 기록
async function faqStartDirectContact(itemId) {
  // 따로 떨어진 질문 페이지 — 서비스는 새 문의 화면, 캠페인은 캠페인 문의 목록(2026-10-07 사용자 결정).
  //   「직접문의 전환」 기록은 남기지 않는다 — 옮긴 뒤 실제로 보냈는지 모른다(아래 F-11 과 같은 이유)
  if (_faqOnPage()) {
    if (_faqPageKind === 'service') openGeneralInquiryNew('faq');
    else { _inqTab = 'app'; openInquiryPage('back'); }
    return;
  }
  // 읽기 전용(취소된 응모)에서는 보낼 곳이 없다 — 이 버튼은 입력창으로 데려가는 게 전부라
  //   그대로 두면 눌러도 아무 일이 안 일어나는 또 다른 막다른 길이 된다(F-11 리뷰 지적).
  //   기록도 남기지 않는다 — 실제로 문의로 이어지지 않은 클릭이 관리자 화면의
  //   「직접문의 전환수」에 섞이면 그 숫자가 사실과 달라진다.
  if (typeof isApplicationCancelled === 'function' && isApplicationCancelled(_msgCurrentAppId)) {
    closeFaqOverlay();
    if (typeof toast === 'function') toast(t('messaging.cancelledReadOnly'));
    return;
  }
  // 응모 끝나고 90일 지난 대화도 같은 이유로(509)
  if (_msgAppPast) {
    closeFaqOverlay();
    if (typeof toast === 'function') toast(t('inquiry.campaignPastReadOnly'));
    return;
  }
  await recordFaqInteraction(_msgCurrentAppId, itemId || null, 'handoff');
  closeFaqOverlay();
  const inputEl = $('msgModalInput');
  if (inputEl) { try { inputEl.focus(); } catch (_e) {} }
}

// ── 따로 떨어진 「よくある質問」 페이지 (#faq-campaign / #faq-service, 2026-10-07 사용자 지시) ──
//   문의 목록 「対応中のお問い合わせ」 옆 단추로 연다. 보던 탭에 맞는 질문만(캠페인 = 대화 화면과 같은 전체,
//   서비스 = 서비스 문의 갈래). 그리는 함수는 대화 화면 오버레이와 같다(_faqHostId 만 바꾼다)
let _faqPageKind = 'campaign';
async function openFaqPage(kind, pushHistory) {
  if (!currentUser) { navigate('login'); return; }
  _faqPageKind = kind === 'service' ? 'service' : 'campaign';
  if (navigate('faq-' + _faqPageKind, pushHistory) === false) return;
  _faqHostId = 'faqPageBody';
  _faqStage = null; _faqNav = [];
  const titleEl = $('faqPageTitle');
  if (titleEl) titleEl.textContent = t(_faqPageKind === 'service' ? 'inquiry.faqPageTitleService' : 'inquiry.faqPageTitleCampaign');
  const host = _faqHostEl();
  if (host) host.innerHTML = stateLoadingHtml(t('messaging.loading'));
  const myKind = _faqPageKind;
  await setupFaqGate(null, {}, { general: myKind === 'service' });
  if (!_faqOnPage() || _faqPageKind !== myKind) return;   // 기다리는 사이 떠났다(늦은 결과는 setupFaqGate 가 버린다)
  renderFaqCategories();
}
// 머리의 뒤로 — 페이지 안에서 들어간 단계가 있으면 한 단계, 아니면 문의 목록의 같은 탭
function faqPageBack() {
  if (_faqNav.length > 1) { faqBack(); return; }
  leaveFaqPage();
}
function leaveFaqPage() {
  _inqTab = _faqPageKind === 'service' ? 'other' : 'app';
  if (typeof openInquiryPage === 'function') openInquiryPage('back');
}
// 페이지를 떠날 때(navigate 훅) — 그릴 자리를 대화 화면 오버레이로 되돌리고 질문 상태를 비운다
function cleanupFaqPage() {
  _faqHostId = 'msgFaqTree';
  _faqLoadSeq++;   // 이 페이지가 기다리던 불러오기 결과를 버린다
  const host = $('faqPageBody'); if (host) host.innerHTML = '';
  _faqNodes = []; _faqNav = []; _faqStage = null; _faqCtx = {}; _faqApp = null; _faqCamp = null; _faqLoaded = false;
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
