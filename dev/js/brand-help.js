// 브랜드 페이지 — 좌측 아래 「도움말」(공지사항·약관·운영팀 문의) + 공지 모달
//   (Figma 「[1차] 03-3 공통 — 도움말 메뉴」 bw03-05 단추 · bw03-05a 펼친 메뉴 · bw03-06 공지 모달,
//    사양서 docs/specs/2026-07-15-brand-portal.md §16-8 표 3번)
//   데이터: get_my_brand_notice_summary() → {latest, unread_count} · get_my_brand_notices() → [{…, is_new}] · mark_my_brand_notices_seen()
//   🔴 공지는 브랜드와 무관(계정 단위) — 브랜드를 바꿔도 다시 부르지 않는다.
//   🔴 조회 실패(null)는 점·배지 없이 메뉴만 그린다(오류 안내는 공지 모달 안에서만). 0건은 [] — 섞지 않는다.

const BRAND_NOTICE_KIND = {
  terms: { label: '약관', cls: 'is-terms' },
  maintenance: { label: '점검', cls: 'is-maint' },
  outage: { label: '장애', cls: 'is-outage' },
  info: { label: '안내', cls: 'is-info' }
};
// 운영팀 문의 — 🔴 연락처는 사용자 보류(2026-10-23 「우선 보류 — 임의 텍스트」) — 정해지면 이 상수만 고친다.
//   lines = 연락처 줄들(지금은 자리 표시 한 줄). 피그마 bw03-05a 의 KakaoTalk·이메일 값은 일부러 뺐다
const BRAND_HELP_CONTACT = { lines: ['운영팀 연락처 (준비 중)'], corp: '주식회사 제이펀 · © JFUN Corp.' };

// 공지 요약 — undefined(아직 안 받음) · null(실패) · {latest, unread_count}
let _brandNoticeSummary;
let _brandNoticeSeq = 0;   // 늦게 온 응답이 다음 계정의 점을 켜지 않게(로그아웃·다시 받기 때 올린다)

function brandHelpHasUnread() {
  return !!(_brandNoticeSummary && Number(_brandNoticeSummary.unread_count) > 0);
}

// 로그인 직후·판정 다시 받기·읽음 처리 뒤에 부른다. 반환 없음 — 결과는 점·메뉴에만 쓴다
async function refreshBrandNoticeSummary() {
  const seq = ++_brandNoticeSeq;
  const { data, error } = await brandRpc('get_my_brand_notice_summary');
  if (seq !== _brandNoticeSeq || !brandSession) return;   // 그사이 로그아웃·다시 받기
  _brandNoticeSummary = (error || !data || typeof data !== 'object') ? null : {
    latest: data.latest && data.latest.id ? data.latest : null,
    unread_count: Number(data.unread_count) || 0
  };
  renderBrandHelp();
}

// 로그아웃·세션 끊김·틀 감춤 — 앞 계정의 점이 다음 계정에 보이지 않게
function resetBrandHelp() {
  _brandNoticeSeq++;
  _brandNoticeSummary = undefined;
  closeBrandHelpMenu(false);
  closeBrandNoticeModal(false);
  renderBrandHelp();
}

function _brandNoticeKindTag(kind) {
  const k = BRAND_NOTICE_KIND[kind];
  if (!k) return '';
  return '<span class="brand-notice-tag ' + k.cls + '">' + brandEsc(k.label) + '</span>';
}

// 펼친 메뉴 내용 — 좌측 메뉴 팝오버와 모바일 서랍이 같은 것을 쓴다(그래서 id 를 쓰지 않는다)
function _brandHelpMenuHtml() {
  const s = _brandNoticeSummary;
  const n = s ? s.unread_count : 0;
  const latest = s && s.latest;
  const kind = latest && BRAND_NOTICE_KIND[latest.brand_kind];
  return '' +
    '<button type="button" class="brand-help-item" data-brand-help-act="notices">' +
      '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">campaign</span>' +
      '<span class="brand-help-item-label">공지사항</span>' +
      (n > 0 ? '<span class="brand-help-new">새 공지 ' + n + '</span>' : '') +
    '</button>' +
    (latest ? '<p class="brand-help-latest">' + (kind ? '[' + brandEsc(kind.label) + '] ' : '') + brandEsc(latest.title || '') + '</p>' : '') +
    '<button type="button" class="brand-help-item" data-brand-help-act="terms">' +
      '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">description</span>' +
      '<span class="brand-help-item-label">이용약관</span>' +
    '</button>' +
    '<button type="button" class="brand-help-item" data-brand-help-act="privacy">' +
      '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">shield</span>' +
      '<span class="brand-help-item-label">개인정보처리방침</span>' +
    '</button>' +
    '<div class="brand-help-line" aria-hidden="true"></div>' +
    '<div class="brand-help-contact">' +
      '<p class="brand-help-contact-title">운영팀 문의</p>' +
      BRAND_HELP_CONTACT.lines.map(t => '<p>' + brandEsc(t) + '</p>').join('') +
      '<p class="brand-help-corp">' + brandEsc(BRAND_HELP_CONTACT.corp) + '</p>' +
    '</div>';
}

// 점·메뉴 내용을 지금 요약으로 다시 그린다(서버를 부르지 않는다)
function renderBrandHelp() {
  const on = brandHelpHasUnread();
  document.querySelectorAll('.brand-help-dot, .brand-help-dot-sr').forEach(el => { el.hidden = !on; });
  document.querySelectorAll('[data-brand-help-menu]').forEach(el => { el.innerHTML = _brandHelpMenuHtml(); });
  if (typeof refreshInviteDot === 'function') refreshInviteDot();   // 모바일 ≡ 단추 점·이름은 거기서 초대와 함께 정한다
}

// ── 좌측 메뉴 팝오버(bw03-05a)
let _brandHelpReturnFocus = null;
function _brandOrientFormOpen() { return !!document.querySelector('.bof-modal'); }
function openBrandHelpMenu() {
  const pop = document.querySelector('[data-brand-help-pop]');
  const btn = document.querySelector('[data-brand-help-toggle]');
  if (!pop || !btn) return;
  // 오리엔시트 작성 창이 열려 있으면 그 창의 키 처리(Esc·Tab)가 앞서 메뉴를 키보드로 못 쓴다 — 닫은 뒤에 연다
  if (_brandOrientFormOpen()) { brandToast('작성 창을 닫은 뒤 열 수 있습니다.'); return; }
  if (typeof closeBrandPickerPop === 'function') closeBrandPickerPop(false);
  renderBrandHelp();
  _brandHelpReturnFocus = btn;
  pop.hidden = false;
  btn.setAttribute('aria-expanded', 'true');
  document.getElementById('brandSideMenu').classList.add('is-help-open');
  const first = pop.querySelector('button');
  if (first) first.focus();
}
function closeBrandHelpMenu(restoreFocus) {
  const pop = document.querySelector('[data-brand-help-pop]');
  if (!pop || pop.hidden) return;
  pop.hidden = true;
  const btn = document.querySelector('[data-brand-help-toggle]');
  if (btn) btn.setAttribute('aria-expanded', 'false');
  const side = document.getElementById('brandSideMenu');
  if (side) side.classList.remove('is-help-open');
  if (restoreFocus !== false && _brandHelpReturnFocus && _brandHelpReturnFocus.isConnected) _brandHelpReturnFocus.focus();
}

// ── 공지 모달(bw03-06) — brandConfirm 처럼 띄울 때 만들고 닫을 때 지운다(.brand-modal — 오리엔시트 작성 창의 키 처리가 물러선다)
let _brandNoticeModal = null;
let _brandNoticeModalReturn = null;
let _brandNoticeModalSeq = 0;

// 공지 본문 정화 — 🔴 관리자 sanitizeRich(shared.js) 허용 목록의 사본(브랜드 빌드엔 shared.js 가 없다). 관리자 공지 편집기는 이미지를 안 넣어 img 는 뺐다.
//   허용 목록을 바꾸면 shared.js RICH_ALLOWED_TAGS·RICH_ALLOWED_ATTR 와 함께 본다
const BRAND_NOTICE_ALLOWED_TAGS = ['p', 'br', 'strong', 'b', 'em', 'i', 'u', 's', 'strike', 'ul', 'ol', 'li', 'a', 'h2', 'h3', 'h4', 'blockquote', 'code', 'pre', 'span', 'div'];
const BRAND_NOTICE_ALLOWED_ATTR = ['href', 'target', 'rel', 'class'];
function brandNoticeSanitize(html) {
  if (html == null) return '';
  if (typeof DOMPurify === 'undefined') return '';   // 못 실으면 본문을 그리지 않는다(안전 쪽)
  const clean = DOMPurify.sanitize(String(html), {
    ALLOWED_TAGS: BRAND_NOTICE_ALLOWED_TAGS,
    ALLOWED_ATTR: BRAND_NOTICE_ALLOWED_ATTR,
    FORBID_TAGS: ['script', 'iframe', 'style', 'object', 'embed', 'svg', 'img'],
    FORBID_ATTR: ['style', 'onerror', 'onload', 'onclick'],
    ALLOWED_URI_REGEXP: /^(?:https?:|mailto:)/i
  });
  const w = document.createElement('div');
  w.innerHTML = clean;
  w.querySelectorAll('a[href]').forEach(a => { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer nofollow'); });
  return w.innerHTML;
}

function _brandNoticeRowsHtml(list) {
  return list.map((n, i) =>
    '<div class="brand-notice-row">' +
      '<button type="button" class="brand-notice-head" data-notice-idx="' + i + '" aria-expanded="false">' +
        _brandNoticeKindTag(n.brand_kind) +
        '<span class="brand-notice-title' + (n.is_new ? ' is-new' : '') + '">' + brandEsc(n.title || '') + '</span>' +
        (n.is_new ? '<span class="brand-notice-new">새 공지</span>' : '') +
        '<span class="brand-notice-date">' + brandEsc(brandFormatDate(n.published_at)) + '</span>' +
      '</button>' +
      '<div class="brand-notice-body rich" data-notice-body="' + i + '" hidden></div>' +
    '</div>'
  ).join('');
}

async function _loadBrandNoticeModal() {
  const m = _brandNoticeModal;
  if (!m) return;
  const host = m.querySelector('[data-notice-list]');
  const seq = ++_brandNoticeModalSeq;
  host.innerHTML = '<p class="brand-notice-state">불러오는 중…</p>';
  const { data, error } = await brandRpc('get_my_brand_notices');
  if (seq !== _brandNoticeModalSeq || _brandNoticeModal !== m) return;
  if (error || !Array.isArray(data)) {
    host.innerHTML = '<div class="brand-notice-state"><p>공지를 불러오지 못했습니다.</p>' +
      '<button type="button" class="brand-btn brand-btn-line" data-notice-retry>다시 시도</button></div>';
    return;
  }
  m._notices = data;
  host.innerHTML = data.length
    ? _brandNoticeRowsHtml(data)
    : '<p class="brand-notice-state">아직 공지가 없습니다</p>';
  // 읽음 처리는 목록을 받은 뒤에만 — 실패한 채 점이 사라지지 않게. 점은 먼저 끄고 서버는 뒤에서
  if (data.some(n => n.is_new) || brandHelpHasUnread()) {
    _brandNoticeSeq++;   // 앞서 보낸 요약 응답이 늦게 와서 꺼 둔 점을 다시 켜지 않게
    if (_brandNoticeSummary) _brandNoticeSummary.unread_count = 0;
    renderBrandHelp();
    brandRpc('mark_my_brand_notices_seen').then(r => { if (r && r.error) refreshBrandNoticeSummary(); }).catch(() => refreshBrandNoticeSummary());
  }
}

function openBrandNoticeModal() {
  if (_brandNoticeModal) return;
  _brandNoticeModalReturn = document.activeElement;
  const wrap = document.createElement('div');
  wrap.className = 'brand-modal';
  wrap.setAttribute('role', 'dialog');
  wrap.setAttribute('aria-modal', 'true');
  wrap.setAttribute('aria-labelledby', 'brandNoticeTitle');
  wrap.innerHTML =
    '<div class="brand-modal-box brand-notice-box">' +
      '<div class="brand-notice-top">' +
        '<h2 id="brandNoticeTitle">공지사항</h2>' +
        '<button type="button" class="brand-notice-close" data-notice-close aria-label="닫기">' +
          '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">close</span>' +
        '</button>' +
      '</div>' +
      '<div class="brand-notice-list" data-notice-list></div>' +
      '<p class="brand-notice-foot">게시 기간이 끝난 공지도 여기에서 다시 볼 수 있습니다.</p>' +
    '</div>';
  wrap.addEventListener('click', (e) => {
    if (e.target === wrap || e.target.closest('[data-notice-close]')) { closeBrandNoticeModal(); return; }
    if (e.target.closest('[data-notice-retry]')) { _loadBrandNoticeModal(); return; }
    const head = e.target.closest('[data-notice-idx]');
    if (!head) return;
    const i = Number(head.dataset.noticeIdx);
    const body = wrap.querySelector('[data-notice-body="' + i + '"]');
    const n = (wrap._notices || [])[i];
    if (!body || !n) return;
    const open = body.hidden;
    if (open && !body.dataset.ready) {
      body.innerHTML = brandNoticeSanitize(n.body_html || '') || '<p class="brand-notice-empty-body">본문이 없습니다.</p>';
      body.dataset.ready = '1';
    }
    body.hidden = !open;
    head.setAttribute('aria-expanded', String(open));
  });
  document.addEventListener('keydown', _brandNoticeOnKey, true);
  document.body.appendChild(wrap);
  _brandNoticeModal = wrap;
  wrap.querySelector('[data-notice-close]').focus();
  _loadBrandNoticeModal();
}
function closeBrandNoticeModal(restoreFocus) {
  const m = _brandNoticeModal;
  if (!m) return;
  _brandNoticeModal = null;
  _brandNoticeModalSeq++;
  document.removeEventListener('keydown', _brandNoticeOnKey, true);
  m.remove();
  const back = _brandNoticeModalReturn;
  _brandNoticeModalReturn = null;
  if (restoreFocus !== false && back && back.isConnected && typeof back.focus === 'function') back.focus();
}
// 캡처 단계 — 뒤의 서랍·오리엔시트 작성 창이 같은 키를 받지 않게
function _brandNoticeOnKey(e) {
  const m = _brandNoticeModal;
  if (!m) return;
  if (e.key === 'Escape') { e.stopPropagation(); e.preventDefault(); closeBrandNoticeModal(); return; }
  if (e.key === 'Tab') {
    const items = Array.from(m.querySelectorAll('button, a[href]')).filter(el => el.offsetParent !== null);
    if (!items.length) return;
    const i = items.indexOf(document.activeElement);
    if (i === -1) { e.preventDefault(); items[0].focus(); return; }
    if (e.shiftKey && i <= 0) { e.preventDefault(); items[items.length - 1].focus(); }
    else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
  }
}

// 메뉴 줄 누름 — 팝오버·서랍 공통. 서랍·팝오버를 먼저 닫아 Esc 한 번에 두 창이 함께 닫히지 않게 한다
function _brandHelpAct(act, fromBtn) {
  const inDrawer = !!fromBtn.closest('#brandDrawer');
  const back = inDrawer ? document.getElementById('brandTopbarMenuBtn') : document.querySelector('[data-brand-help-toggle]');
  if (inDrawer) closeBrandDrawer(false); else closeBrandHelpMenu(false);
  if (back) back.focus();   // 새 창이 닫히면 초점이 돌아올 자리
  if (act === 'notices') openBrandNoticeModal();
  else if (act === 'terms' || act === 'privacy') openLegalModal(act);
}

function initBrandHelp() {
  renderBrandHelp();
  document.addEventListener('click', (e) => {
    const toggle = e.target.closest('[data-brand-help-toggle]');
    if (toggle) {
      const pop = document.querySelector('[data-brand-help-pop]');
      if (pop && !pop.hidden) closeBrandHelpMenu(); else openBrandHelpMenu();
      return;
    }
    const act = e.target.closest('[data-brand-help-act]');
    if (act) { _brandHelpAct(act.dataset.brandHelpAct, act); return; }
    // 메뉴 바깥 누름 — 닫는다(초점은 옮기지 않는다)
    const pop = document.querySelector('[data-brand-help-pop]');
    if (pop && !pop.hidden && !e.target.closest('[data-brand-help-pop]')) closeBrandHelpMenu(false);
  });
  document.addEventListener('keydown', (e) => {
    const pop = document.querySelector('[data-brand-help-pop]');
    if (!pop || pop.hidden) return;
    if (e.key === 'Escape') { e.stopPropagation(); closeBrandHelpMenu(); return; }
    if (e.key === 'Tab') {
      // 메뉴 안에서만 돌게 — 밖으로 나가면 닫는다
      const items = Array.from(pop.querySelectorAll('button'));
      const i = items.indexOf(document.activeElement);
      if (i === -1) return;
      if (e.shiftKey && i === 0) { e.preventDefault(); items[items.length - 1].focus(); }
      else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
    }
  });
  // 틀이 감춰질 때는 열린 메뉴·모달만 닫는다 — 요약 비우기는 로그아웃(setBrandSessionFromState(null))·세션 끊김에서
  onBrandShellHidden(() => { closeBrandHelpMenu(false); closeBrandNoticeModal(false); });
  onBrandSessionLost(resetBrandHelp);
}
