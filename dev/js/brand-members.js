// 브랜드 페이지 — 멤버 관리(06): 목록·초대·다시 보내기 (작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 5)
//   + 조각 6 정리 동작: 대기 초대 취소·만료/거절 줄 삭제·대표 담당자 넘기기(bw06-02)·해제(bw06-03)
//   피그마 bw06-00(대표 화면)·bw06-00a(멤버 화면)·bw06-01(초대 모달)·bw06-01a(가득 참)·bw06-02·bw06-03·bw06-90(토스트)
//   🔴 단추를 숨기는 것은 보기일 뿐이다 — 서버가 「지금 그 브랜드의 대표인가」를 다시 판정한다. 동작 뒤에는 목록을 다시 받는다.
//   🔴 겹침 비노출 — 받는 이메일이 다른 브랜드 계정·인플루언서·관리자여도 대표 화면은 늘 같은 토스트·「초대 대기」.

const BRAND_MEMBERS_MSG = {
  loadFail: '멤버 목록을 불러오지 못했습니다.',
  sent: '초대를 보냈습니다.',                                              // bw06-90
  resent: '초대 메일을 다시 보냈습니다.',                                   // bw06-90
  mailFail: '초대는 만들었지만 메일을 보내지 못했습니다. 목록에서 「다시 보내기」를 눌러 주십시오.',
  full: '멤버가 가득 찼습니다.',
  notOwner: '대표 담당자만 할 수 있습니다. 목록을 새로 불러왔습니다.',
  failed: '초대를 보내지 못했습니다. 잠시 후 다시 시도해 주십시오.',          // bw06-90
  alreadyPending: '이미 초대한 이메일입니다. 목록에서 「다시 보내기」를 눌러 주십시오.',
  alreadyMember: '이미 이 브랜드의 멤버입니다.',
  selfEmail: '본인 이메일은 초대할 수 없습니다.',
  cancelled: '초대를 취소했습니다.',                                       // bw06-90
  transferred: '대표 담당자를 넘겼습니다.',                                 // bw06-90
  // 아래 셋은 피그마에 아직 문구가 없다(bw06-90 「아직 정하지 않은 것」) — 같은 문체로 임시
  actionFail: '처리하지 못했습니다. 잠시 후 다시 시도해 주십시오.',
  inviteEnded: '이미 끝난 초대입니다. 목록을 새로 불러왔습니다.',
  notMember: '이미 해제된 멤버입니다. 목록을 새로 불러왔습니다.'
};

// 지금 그린 목록 — { brandId, my_role, seat_used, member_limit, rows } · 실패면 null
let _brandMembersData;   // undefined = 불러오는 중 · null = 실패
let _brandMembersLoadSeq = 0;

function _brandMd(iso) {
  const d = new Date(iso);
  return isNaN(d.getTime()) ? '' : (d.getMonth() + 1) + '/' + d.getDate();
}

// 줄 순서(피그마 시안) — 대표 → 사용 중 멤버 → 초대 대기 → 초대 만료 → 거절함. 같은 묶음 안은 서버 순서(연결·발급순)
const _BRAND_MEMBER_ROW_ORDER = { owner: 0, active: 1, pending: 2, expired: 3, declined: 4 };
function _brandMemberRowRank(r) {
  if (r.kind === 'account') return r.role === 'owner' ? 0 : 1;
  return _BRAND_MEMBER_ROW_ORDER[r.status] != null ? _BRAND_MEMBER_ROW_ORDER[r.status] : 9;
}

function _brandPill(text, cls) { return '<span class="brand-pill ' + cls + '">' + brandEsc(text) + '</span>'; }

function _brandMemberStatusPill(r) {
  if (r.kind === 'account') return _brandPill('사용 중', 'is-active');
  if (r.status === 'pending') return _brandPill('초대 대기 · ' + _brandMd(r.issued_at) + ' 보냄', 'is-pending');
  if (r.status === 'expired') return _brandPill('초대 만료', 'is-muted');
  if (r.status === 'declined') return _brandPill('거절함 · ' + _brandMd(r.declined_at), 'is-muted');
  return '';
}

// 관리 칸 — 다시 보내기(조각 5) + 넘기기·해제·취소·삭제(조각 6, _brandMemberExtraActions).
function _brandMemberActions(r) {
  const btns = [];
  if (r.kind === 'invite' && (r.status === 'pending' || r.status === 'expired')) {
    // 가득 차도 단추는 잠그지 않는다 — 만료 줄을 누르면 서버가 seat_full 로 거부하고 「멤버가 가득 찼습니다.」 토스트(피그마 bw06-00·90)
    btns.push('<button type="button" class="brand-row-btn" data-mem-act="resend" data-invite="' + brandEsc(r.invite_id) + '">다시 보내기</button>');
  }
  btns.push(..._brandMemberExtraActions(r));
  return btns.length ? btns.join('') : '<span class="brand-dash">—</span>';
}

function _brandMembersHeadHtml(d) {
  const owner = d && d.my_role === 'owner';
  const full = d && d.seat_used >= d.member_limit;
  return '<div class="brand-page-head">' +
      '<div><h1>멤버 관리</h1>' +
      '<p>브랜드를 함께 관리할 동료를 초대합니다. 멤버도 오리엔시트·캠페인·브랜드 정보를 똑같이 쓸 수 있습니다.</p></div>' +
      (d ? '<div class="brand-page-tools">' +
        '<span class="brand-seat">' + d.seat_used + ' / ' + d.member_limit + '명</span>' +
        (owner ? '<button type="button" class="brand-tool-btn" data-mem-act="invite"' + (full ? ' data-full="1"' : '') + '>' +
          '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">add</span>멤버 초대</button>' : '') +
      '</div>' : '') +
    '</div>';
}

function renderBrandMembers(host) {
  const d = _brandMembersData;
  if (d === undefined || (d && d.brandId !== getCurrentBrandId())) {
    host.innerHTML = _brandMembersHeadHtml(null) + stateLoadingBrand();
    return;
  }
  if (d === null) {
    host.innerHTML = _brandMembersHeadHtml(null) +
      '<div class="brand-empty"><p class="brand-empty-title">' + brandEsc(BRAND_MEMBERS_MSG.loadFail) + '</p>' +
      '<button type="button" class="brand-btn brand-btn-line brand-btn-inline" data-mem-act="reload">다시 시도</button></div>';
    return;
  }
  const owner = d.my_role === 'owner';
  const rows = d.rows.slice().sort((a, b) => _brandMemberRowRank(a) - _brandMemberRowRank(b));
  const body = rows.map(r => {
    const isInvite = r.kind === 'invite';
    return '<tr' + (isInvite ? ' class="is-invite"' : '') + '>' +
      '<td class="c-name" data-label="이름">' + (isInvite || !r.name ? '<span class="brand-dash">—</span>' : brandEsc(r.name)) + '</td>' +
      '<td class="c-email" data-label="이메일">' + brandEsc(r.email || '') + '</td>' +
      '<td data-label="역할">' + (r.role === 'owner' ? _brandPill('대표', 'is-owner') : _brandPill('멤버', 'is-member')) + '</td>' +
      '<td data-label="상태">' + _brandMemberStatusPill(r) + '</td>' +
      '<td class="c-last" data-label="마지막 접속">' + (r.last_active_at ? brandEsc(brandFormatDate(r.last_active_at)) : '<span class="brand-dash">—</span>') + '</td>' +
      // 멤버 화면(bw06-00a)도 「관리」 열은 두고 비운다 — 대표 줄만 「—」
      '<td class="c-act" data-label="관리">' + (r.kind === 'account' && r.role === 'owner' ? '<span class="brand-dash">—</span>' : (owner ? _brandMemberActions(r) : '')) + '</td>' +
    '</tr>';
  }).join('');
  host.innerHTML = _brandMembersHeadHtml(d) +
    '<div class="brand-table-wrap"><table class="brand-table">' +
      '<thead><tr><th class="w-name">이름</th><th class="w-email">이메일</th><th class="w-role">역할</th><th class="w-status">상태</th><th class="w-last">마지막 접속</th><th class="c-act">관리</th></tr></thead>' +
      '<tbody>' + body + '</tbody></table></div>' +
    '<ul class="brand-note">' +
      '<li>' + d.member_limit + '명에는 대표 담당자와 초대 대기도 들어갑니다. 초대가 만료되거나 거절되면 ' + d.member_limit + '명에 들어가지 않습니다.</li>' +
      '<li>초대·다시 보내기·취소·해제·대표 담당자 넘기기는 대표 담당자만 할 수 있습니다. 멤버가 더 필요하면 운영팀에 요청해 주십시오.</li>' +
    '</ul>';
}

function stateLoadingBrand() {
  return '<div class="brand-empty" aria-busy="true"><p class="brand-empty-desc">불러오는 중…</p></div>';
}

// 목록 받기 — 실패 null 과 not_linked 를 가른다. 다 받으면 그 페이지에 있을 때만 다시 그린다
async function loadBrandMembers() {
  const brandId = getCurrentBrandId();
  const seq = ++_brandMembersLoadSeq;
  // 같은 브랜드의 옛 목록은 새 응답이 올 때까지 둔다(깜빡임 방지). 다른 브랜드 것이거나 실패 상태면 불러오는 중으로
  if (!_brandMembersData || _brandMembersData.brandId !== brandId) { _brandMembersData = undefined; _rerenderMembersIfShown(); }
  const { data, error } = await brandRpc('get_brand_members', { p_brand_id: brandId });
  if (seq !== _brandMembersLoadSeq) return;   // 그사이 브랜드가 바뀌거나 다시 불렀다
  if (!error && data && data.result === 'not_linked') {
    _brandMembersData = null;
    await handleBrandNotLinked();
    _rerenderMembersIfShown();   // 판정 재조회가 실패해 틀이 남으면 오류 카드라도 보이게
    return;
  }
  if (error || !data || !Array.isArray(data.rows)) { _brandMembersData = null; _rerenderMembersIfShown(); return; }
  _brandMembersData = { brandId, my_role: data.my_role, seat_used: data.seat_used, member_limit: data.member_limit, rows: data.rows };
  _rerenderMembersIfShown();
}

function _rerenderMembersIfShown() {
  if (location.hash !== '#members' || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (host) renderBrandMembers(host);
}

// ── 초대 메일 발송 — notify-brand-invite. 반환 'sent' | 'failed' | 'stale'(목록 새로 받기)
async function sendBrandInviteMail(inviteId) {
  const r = await brandCallFunction('notify-brand-invite', { invite_id: inviteId }, { auth: true });
  const b = r.body || {};
  if (r.status === 200 && b.sent === true) {
    if (b.dev_mail && typeof IS_STAGING !== 'undefined' && IS_STAGING) showBrandDevMail(b.dev_mail);
    return 'sent';
  }
  if (r.status === 200 && b.reason === 'already_sent') return 'sent';   // 같은 링크로 이미 보냄 — 성공과 같게
  if ((r.status === 200 && b.reason === 'not_pending') || r.status === 403) return 'stale';
  return 'failed';
}

// 개발서버 전용 — 메일 대신 받은 제목·본문(링크 포함)을 보여 준다(운영에서는 서버가 dev_mail 을 싣지 않는다)
function showBrandDevMail(mail) {
  let box = document.getElementById('brandDevMail');
  if (!box) {
    box = document.createElement('div');
    box.id = 'brandDevMail';
    box.className = 'brand-dev-mail';
    document.body.appendChild(box);
  }
  box.innerHTML = '<div class="brand-dev-mail-head"><b>개발서버 — 메일 대신 보기</b>' +
    '<button type="button" class="brand-text-btn" data-dev-mail-close>닫기</button></div>' +
    '<p class="brand-dev-mail-subj">' + brandEsc(mail.subject || '') + '</p>' +
    '<pre class="brand-dev-mail-body">' + brandEsc(mail.text || '') + '</pre>';
  box.hidden = false;
  box.querySelector('[data-dev-mail-close]').addEventListener('click', () => { box.hidden = true; });
}

async function _brandMembersAfterAction(touch) {
  if (touch) brandTouchActivity();   // 저장 성공 = 활동(S0-4)
  await loadBrandMembers();
}

async function resendBrandInviteRow(inviteId, btn) {
  btn.disabled = true;
  const { data, error } = await brandRpc('resend_brand_invite', { p_invite_id: inviteId });
  if (error || !data || !data.result) { btn.disabled = false; brandToast(BRAND_MEMBERS_MSG.failed, { error: true }); return; }
  // 만료 줄 다시 보내기가 가득 참 — 피그마 bw06-90 은 토스트(새 초대만 bw06-01a 모달). 숫자가 바뀌었을 수 있어 목록도 다시 받는다
  if (data.result === 'seat_full') { brandToast(BRAND_MEMBERS_MSG.full, { error: true }); await loadBrandMembers(); return; }
  if (data.result !== 'ok') { await _brandMembersAfterAction(false); return; }   // not_resendable·not_found·not_owner — 목록 새로 받기
  const mail = await sendBrandInviteMail(data.invite_id || inviteId);
  if (mail === 'failed') brandToast(BRAND_MEMBERS_MSG.mailFail, { error: true });
  else if (mail === 'stale') brandToast(BRAND_MEMBERS_MSG.notOwner, { error: true });   // 그사이 대표가 바뀌었거나 초대가 끝남
  else brandToast(BRAND_MEMBERS_MSG.resent);
  await _brandMembersAfterAction(true);
}

// ── 초대 모달(bw06-01) · 가득 참(bw06-01a)
function openBrandInviteModal(full) {
  if (full) { openBrandSeatFullModal(); return; }
  closeBrandInviteModal();
  const prevFocus = document.activeElement;
  const wrap = document.createElement('div');
  wrap.className = 'brand-modal';
  wrap.id = 'brandInviteModal';
  wrap.setAttribute('role', 'dialog');
  wrap.setAttribute('aria-modal', 'true');
  wrap.setAttribute('aria-labelledby', 'brandInviteTitle');
  const d0 = _brandMembersData || {};
  wrap.innerHTML =
    '<form class="brand-modal-box brand-modal-form" novalidate>' +
      '<h2 id="brandInviteTitle">멤버 초대</h2>' +
      '<p>동료의 이메일로 초대 메일을 보냅니다.</p>' +
      '<div class="brand-modal-card">' +
        '<div class="brand-field">' +
          '<label for="brandInviteEmail">이메일</label>' +
          '<input type="email" id="brandInviteEmail" class="brand-input" autocomplete="off" inputmode="email">' +
          '<p class="brand-field-error" id="brandInviteEmailError" hidden></p>' +
        '</div>' +
        '<p class="brand-modal-hint">초대받은 사람이 메일에서 수락하면 멤버가 됩니다. 수락 전까지는 「초대 대기」로 보이고 ' +
          (d0.member_limit || '') + '명 안에 들어갑니다. (지금 ' + (d0.seat_used != null ? d0.seat_used : '') + ' / ' + (d0.member_limit || '') + '명)</p>' +
      '</div>' +
      // 피그마 bw06-01 — 오른쪽 정렬 「취소 · 초대 보내기」
      '<div class="brand-modal-actions is-right">' +
        '<button type="button" class="brand-btn brand-btn-line" data-inv="cancel">취소</button>' +
        '<button type="submit" class="brand-btn" data-inv="send">초대 보내기</button>' +
      '</div>' +
    '</form>';
  const close = () => { wrap.remove(); document.removeEventListener('keydown', onKey, true); if (prevFocus && prevFocus.isConnected) prevFocus.focus(); };
  const onKey = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(); } };
  wrap._close = close;
  wrap.addEventListener('click', (e) => { if (e.target === wrap || e.target.closest('[data-inv="cancel"]')) close(); });
  const form = wrap.querySelector('form');
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const input = form.querySelector('#brandInviteEmail');
    const email = input.value.trim();
    if (!email) { setFieldError('brandInviteEmail', BRAND_MSG.emailEmpty); input.focus(); return; }
    if (!isEmailFormat(email)) { setFieldError('brandInviteEmail', BRAND_MSG.emailFormat); input.focus(); return; }
    setFieldError('brandInviteEmail', '');
    const btns = form.querySelectorAll('button, input');
    btns.forEach(b => { b.disabled = true; });
    const sendBtn = form.querySelector('[data-inv="send"]');
    sendBtn.textContent = '보내는 중…';
    const res = await createBrandInvite(email);
    if (res.keepOpen) {
      btns.forEach(b => { b.disabled = false; });
      sendBtn.textContent = '초대 보내기';
      // 연결·서버 오류는 토스트(bw06-90 — 모달 유지), 입력 문제는 칸 아래 안내
      if (res.toastError) brandToast(res.message, { error: true }); else setFieldError('brandInviteEmail', res.message);
      input.focus();
      return;
    }
    close();
    if (res.seatFull) { openBrandSeatFullModal(); return; }
    if (res.message) brandToast(res.message, { error: !!res.toastError });
  });
  document.addEventListener('keydown', onKey, true);
  document.body.appendChild(wrap);
  wrap.querySelector('#brandInviteEmail').addEventListener('input', () => setFieldError('brandInviteEmail', ''));
  wrap.querySelector('#brandInviteEmail').focus();
}
function closeBrandInviteModal() {
  const m = document.getElementById('brandInviteModal');
  if (m && m._close) m._close(); else if (m) m.remove();
}

// 피그마 bw06-01a — 숫자는 서버에서 받은 값(6 / 5 처럼 상한보다 많을 수도 있다). 단추는 「확인」 하나
function openBrandSeatFullModal() {
  const d = _brandMembersData || {};
  brandConfirm({
    title: '멤버가 가득 찼습니다',
    sub: '지금 ' + (d.seat_used != null ? d.seat_used : '') + ' / ' + (d.member_limit || '') + '명입니다. 운영팀에 늘려 달라고 요청해 주십시오.',
    body: '또는 「초대 대기」를 취소하거나 멤버를 해제해 자리를 비울 수 있습니다.',
    okLabel: '확인', single: true, card: true, wide: true   // 회색 상자 + 흰 카드, 폭 480
  });
}

// 초대 만들기 + 메일. 반환 { keepOpen, message, seatFull }
async function createBrandInvite(email) {
  const brandId = getCurrentBrandId();
  const { data, error } = await brandRpc('create_brand_invite', { p_brand_id: brandId, p_email: email });
  if (error || !data || !data.result) return { keepOpen: true, toastError: true, message: BRAND_MEMBERS_MSG.failed };
  switch (data.result) {
    case 'ok': {
      const mail = await sendBrandInviteMail(data.invite_id);
      await _brandMembersAfterAction(true);
      if (mail === 'failed') return { message: BRAND_MEMBERS_MSG.mailFail, toastError: true };
      if (mail === 'stale') return { message: BRAND_MEMBERS_MSG.notOwner, toastError: true };
      return { message: BRAND_MEMBERS_MSG.sent };
    }
    case 'invalid_email': return { keepOpen: true, message: BRAND_MSG.emailFormat };
    case 'self_email': return { keepOpen: true, message: BRAND_MEMBERS_MSG.selfEmail };
    case 'already_member': return { keepOpen: true, message: BRAND_MEMBERS_MSG.alreadyMember };
    case 'already_pending': return { keepOpen: true, message: BRAND_MEMBERS_MSG.alreadyPending };
    case 'seat_full': await loadBrandMembers(); return { seatFull: true };
    default:   // not_owner · brand_inactive — 그사이 대표가 바뀜
      await loadBrandMembers();
      return { message: BRAND_MEMBERS_MSG.notOwner, toastError: true };
  }
}

registerBrandPage('members', {
  title: '멤버 관리',
  render(host) {
    renderBrandMembers(host);
    // 페이지에 들어올 때마다 새로 받는다(다른 사람·운영팀이 바꿨을 수 있다)
    loadBrandMembers();
  }
});

onBrandChanged(() => { _brandMembersData = undefined; _brandMembersLoadSeq++; });   // 옛 브랜드 응답은 버린다

// 페이지 안 단추(위임) — 틀 안 페이지 영역 한 곳에 건다
document.addEventListener('click', async (e) => {
  const btn = e.target.closest('#brandPageHost [data-mem-act]');
  if (!btn || btn.disabled) return;
  const act = btn.dataset.memAct;
  if (act === 'reload') { loadBrandMembers(); return; }
  if (act === 'invite') { openBrandInviteModal(btn.dataset.full === '1'); return; }
  if (act === 'resend') { await resendBrandInviteRow(btn.dataset.invite, btn); return; }
  await _brandMemberExtraClick(act, btn);
});

// ── 조각 6 — 정리 동작(대표만 보이는 단추. 최종 판정은 서버)
//   피그마 bw06-00 단추: 멤버 줄 「대표 담당자 넘기기」(기본)·「해제」(빨강) / 대기 줄 「취소」(빨강, 확인 없이 바로)
//   / 만료·거절 줄 「삭제」(기본, 확인·토스트 없음 — 줄이 사라지는 것으로 충분)
function _brandMemberExtraActions(r) {
  const btn = (act, label, attrs, danger) =>
    '<button type="button" class="brand-row-btn' + (danger ? ' is-danger' : '') + '" data-mem-act="' + act + '" ' + attrs + '>' + label + '</button>';
  if (r.kind === 'account' && r.role === 'member' && r.auth_id) {
    const a = 'data-auth="' + brandEsc(r.auth_id) + '" data-name="' + brandEsc(_brandMemberDisplayName(r)) + '"';
    return [btn('transfer', '대표 담당자 넘기기', a, false), btn('release', '해제', a, true)];
  }
  if (r.kind !== 'invite') return [];
  const inv = 'data-invite="' + brandEsc(r.invite_id) + '"';
  if (r.status === 'pending') return [btn('cancel', '취소', inv, true)];
  if (r.status === 'expired' || r.status === 'declined') return [btn('hide', '삭제', inv, false)];
  return [];
}

function _brandMemberDisplayName(r) { return (r.name && String(r.name).trim()) || r.email || ''; }

async function _brandMemberExtraClick(act, btn) {
  if (act === 'cancel') return cancelBrandInviteRow(btn.dataset.invite, btn);
  if (act === 'hide') return hideBrandInviteRow(btn.dataset.invite, btn);
  if (act === 'transfer') return transferBrandOwnerRow(btn.dataset.auth, btn.dataset.name, btn);
  if (act === 'release') return releaseBrandMemberRow(btn.dataset.auth, btn.dataset.name, btn);
}

// 서버 결과(글자 하나) — 실패·모르는 값은 null
async function _brandMemberRpcText(name, args) {
  const { data, error } = await brandRpc(name, args);
  return (!error && typeof data === 'string') ? data : null;
}

// 대기 초대 취소 — 피그마: 확인 모달 없이 바로 취소 + 토스트
async function cancelBrandInviteRow(inviteId, btn) {
  btn.disabled = true;
  const res = await _brandMemberRpcText('cancel_brand_invite', { p_invite_id: inviteId });
  if (res === null) { btn.disabled = false; brandToast(BRAND_MEMBERS_MSG.actionFail, { error: true }); return; }
  if (res === 'ok') { brandToast(BRAND_MEMBERS_MSG.cancelled); await _brandMembersAfterAction(true); return; }
  // not_pending(그사이 만료·수락·거절·다른 쪽에서 취소) · not_owner(그사이 대표가 바뀜) — 목록 새로 받기
  brandToast(res === 'not_pending' ? BRAND_MEMBERS_MSG.inviteEnded : res === 'not_owner' ? BRAND_MEMBERS_MSG.notOwner : BRAND_MEMBERS_MSG.actionFail, { error: true });
  await loadBrandMembers();
}

// 만료·거절 줄 삭제 — 목록에서만 지운다(초대 이력은 서버에 남는다)
async function hideBrandInviteRow(inviteId, btn) {
  btn.disabled = true;
  const res = await _brandMemberRpcText('hide_brand_invite', { p_invite_id: inviteId });
  if (res === null) { btn.disabled = false; brandToast(BRAND_MEMBERS_MSG.actionFail, { error: true }); return; }
  if (res === 'ok') { await _brandMembersAfterAction(true); return; }
  // not_hideable(그사이 다시 보내 대기가 됨) — 조용히 새로 받기 · not_owner — 안내 + 새로 받기
  if (res === 'not_owner') brandToast(BRAND_MEMBERS_MSG.notOwner, { error: true });
  await loadBrandMembers();
}

// 대표 담당자 넘기기 — 피그마 bw06-02 「취소 · 대표 담당자 넘기기」(검정). 메일 없음.
//   🔴 서버가 brands.contacts 의 대표 표시도 옮긴다 — 묶음 ③ 전에는 관리자 브랜드 상세 편집 폼을 연 채 저장하면 되돌아간다
async function transferBrandOwnerRow(authId, name, btn) {
  const ok = await brandConfirm({
    title: name + '님에게 대표 담당자를 넘기시겠습니까?',
    body: '· ' + name + '님이 대표 담당자가 됩니다.\n' +
      '· 회원님은 멤버가 되고, 초대·해제·대표 담당자 넘기기를 더 할 수 없습니다.\n' +
      '· 오리엔시트·캠페인·브랜드 정보는 지금처럼 쓸 수 있습니다.',
    card: true, wide: true, okLabel: '대표 담당자 넘기기'
  });
  if (!ok) return;
  btn.disabled = true;
  const res = await _brandMemberRpcText('transfer_brand_ownership', { p_brand_id: getCurrentBrandId(), p_new_owner_auth_id: authId });
  if (res === null) { btn.disabled = false; brandToast(BRAND_MEMBERS_MSG.actionFail, { error: true }); return; }
  if (res === 'ok') {
    brandToast(BRAND_MEMBERS_MSG.transferred);
    brandTouchActivity();
    // 내 역할이 바뀌었다 — 로그인 판정(브랜드 목록의 역할)을 새로 받고, 목록을 멤버 화면(bw06-00a)으로 다시 그린다
    await refreshBrandLoginState();
    await loadBrandMembers();
    return;
  }
  brandToast(res === 'not_member' ? BRAND_MEMBERS_MSG.notMember : res === 'not_owner' ? BRAND_MEMBERS_MSG.notOwner : BRAND_MEMBERS_MSG.actionFail, { error: true });
  await loadBrandMembers();
}

// 해제 — 피그마 bw06-03 「취소 · 해제」(빨강). 연결 이력은 서버에 남는다
async function releaseBrandMemberRow(authId, name, btn) {
  const ok = await brandConfirm({
    title: name + '님을 해제하시겠습니까?',
    body: '· 이 브랜드에 바로 로그인할 수 없게 됩니다. (다른 브랜드에 연결돼 있으면 그 브랜드는 그대로)\n' +
      '· ' + name + '님이 만든 오리엔시트는 브랜드에 남습니다.\n' +
      '· 다시 함께하려면 새로 초대해야 합니다.',
    card: true, wide: true, okLabel: '해제', danger: true
  });
  if (!ok) return;
  btn.disabled = true;
  const res = await _brandMemberRpcText('release_brand_member', { p_brand_id: getCurrentBrandId(), p_auth_id: authId });
  if (res === null) { btn.disabled = false; brandToast(BRAND_MEMBERS_MSG.actionFail, { error: true }); return; }
  if (res === 'ok') { brandToast(name + '님을 해제했습니다.'); await _brandMembersAfterAction(true); return; }   // bw06-90
  brandToast(res === 'not_member' ? BRAND_MEMBERS_MSG.notMember : res === 'not_owner' ? BRAND_MEMBERS_MSG.notOwner : BRAND_MEMBERS_MSG.actionFail, { error: true });
  await loadBrandMembers();
}
