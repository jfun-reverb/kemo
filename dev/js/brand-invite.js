// 브랜드 페이지 — 받은 초대 수락·거절(w01-03 · w01-10 · w01-90 · w01-92 ⑥)
//   작업표 docs/specs/2026-10-15-brand-member-screen-breakdown.md 조각 3(로그인 경로) · 조각 4(메일 링크 경로가 같은 화면을 쓴다)
//   🔴 연결된 브랜드가 없고 받은 초대만 있는 계정은 로그아웃하지 않고 이 화면으로 온다(applyBrandLoginState).
//      이때 brandAuthed 는 null(틀 페이지에 못 들어간다) — 세션만 살아 있고 이 화면의 맥락은 _brandInviteCtx 가 갖는다.

const BRAND_INVITE_MSG = {
  invalid: '이 초대는 더 이상 쓸 수 없습니다.',                               // w01-90 토스트 2
  declined: '초대를 거절했습니다.',                                          // w01-90 토스트 1
  failed: '브랜드를 연결하지 못했습니다. 잠시 후 다시 시도해 주십시오.',        // w01-92 ⑥
  later: '초대는 기한까지 메일 링크로 다시 수락할 수 있습니다.'                // w01-03 「나중에」(대기 초대만 있는 계정)
};

// 지금 보고 있는 초대 — { source:'login'|'link', invite:{invite_id, brand_id, brand_name, inviter_name, expires_at}, linkId? }
let _brandInviteCtx = null;

// 수락·거절 — respond_brand_invite 감싸기. 반환 {result, brand_id} 또는 null(호출 실패).
//   result: ok · already_member · invalid · not_brand · setup_incomplete. 마이페이지 받은 초대(조각 7)도 이 함수를 쓴다.
async function respondBrandInvite(opts) {
  const o = opts || {};
  const { data, error } = await brandRpc('respond_brand_invite', {
    p_invite_id: o.inviteId || null, p_link_id: o.linkId || null, p_action: o.action
  });
  if (error || !data || typeof data !== 'object' || !data.result) return null;
  return data;
}

// 받은 초대 목록 — 배열 또는 null(호출 실패). 0건 [] 과 실패 null 을 가른다.
async function fetchMyBrandInvites() {
  const { data, error } = await brandRpc('get_my_brand_invites');
  if (error || !Array.isArray(data)) return null;
  return data;
}

function _brandInviteMd(iso) {
  const d = new Date(iso);
  return isNaN(d.getTime()) ? '' : (d.getMonth() + 1) + '/' + d.getDate();
}

// 초대 수락 화면을 채워 보인다. 「초대받은 계정」 칸 = 지금 로그인한 계정 이메일(작업표 S0-5).
function showInviteScreen(ctx, loginEmail) {
  _brandInviteCtx = ctx;
  const inv = ctx.invite || {};
  document.getElementById('inviteDesc').textContent =
    '「' + (inv.brand_name || '') + '」 브랜드의 대표 담당자 ' + (inv.inviter_name || '') + '님이 회원님을 멤버로 초대했습니다.';
  document.getElementById('inviteEmail').value = loginEmail || '';
  setNotice('inviteResult', '');
  _setInviteBusy(false);
  history.replaceState(null, '', location.pathname + location.search + '#invite');
  paintBrandScreen('invite');
}

function _setInviteBusy(busy, label) {
  const btn = document.getElementById('inviteSubmit');
  btn.disabled = busy;
  btn.textContent = busy ? (label || '수락하는 중…') : '초대 수락';
  document.querySelectorAll('#inviteLater, #inviteDecline').forEach(el => { el.disabled = busy; });
}

// 로그인 판정이 「연결 브랜드 없음 + 수락할 초대 있음」일 때 — 로그아웃하지 않고 첫 초대를 보인다.
//   반환 true(초대 화면을 띄움) / false(초대 목록을 못 받았거나 비어 있음 — 부르는 쪽이 원래 갈래로)
async function enterInviteOnly(state) {
  const list = await fetchMyBrandInvites();
  if (!list || !list.length) return false;
  showInviteScreen({ source: 'login', invite: list[0] }, state && state.email);
  return true;
}

// 수락·거절 뒤 갈래 — 연결 브랜드 있음 = 첫 페이지 / 남은 초대 있음 = 다음 초대 / 둘 다 없음 = 로그아웃 + 「연결된 브랜드 없음」
async function _brandAfterInvite(preferBrandId) {
  _brandInviteCtx = null;
  const state = await fetchBrandLoginState();
  if (state && state.state === 'ok') { enterBrandApp(state, { preferBrandId }); return; }
  if (!state) {
    // 판정을 못 받음 — 세션은 두고 「다시 시도」 화면(새로고침 실패와 같은 처리)
    _brandCheckPending = true;
    history.replaceState(null, '', location.pathname + location.search + '#check-fail');
    paintBrandScreen('check-fail');
    return;
  }
  await applyBrandLoginState(state);
}

async function acceptCurrentInvite() {
  const ctx = _brandInviteCtx;
  if (!ctx) return;
  _setInviteBusy(true, '수락하는 중…');
  setNotice('inviteResult', '');
  const r = await respondBrandInvite({ inviteId: ctx.linkId ? null : ctx.invite.invite_id, linkId: ctx.linkId || null, action: 'accept' });
  if (!r) { _setInviteBusy(false); setNotice('inviteResult', BRAND_INVITE_MSG.failed); return; }
  if (r.result === 'ok' || r.result === 'already_member') {
    // 초대 수락 화면에서 수락하면 그 브랜드로 연다(사양서 예외 — 마지막으로 본 브랜드도 그 브랜드)
    if (r.brand_id) await brandRpc('set_my_brand_last_viewed', { p_brand_id: r.brand_id });
    await _brandAfterInvite(r.brand_id);
    return;
  }
  if (r.result === 'invalid') { brandToast(BRAND_INVITE_MSG.invalid); await _brandAfterInvite(null); return; }
  // not_brand · setup_incomplete — 계정 상태가 바뀜. 판정 갈래를 그대로 따른다
  await _brandAfterInvite(null);
}

async function declineCurrentInvite() {
  const ctx = _brandInviteCtx;
  if (!ctx) return;
  const inv = ctx.invite || {};
  const brand = inv.brand_name || '';
  const until = _brandInviteMd(inv.expires_at);
  const ok = await brandConfirm({
    title: brand + ' 브랜드 초대를 거절하시겠습니까?',
    body: '초대한 사람 ' + (inv.inviter_name || '') + '(대표 담당자)' + (until ? ' · ' + until + '까지 수락할 수 있는 초대입니다.' : '') +
      '\n거절하면 이 초대로는 ' + brand + ' 브랜드 페이지에 들어갈 수 없습니다. 다시 함께하려면 대표 담당자에게 새로 초대해 달라고 요청해 주십시오.',
    okLabel: '거절', cancelLabel: '취소', danger: true
  });
  if (!ok || _brandInviteCtx !== ctx) return;
  _setInviteBusy(true, '처리하는 중…');
  setNotice('inviteResult', '');
  const r = await respondBrandInvite({ inviteId: ctx.linkId ? null : inv.invite_id, linkId: ctx.linkId || null, action: 'decline' });
  if (!r) { _setInviteBusy(false); setNotice('inviteResult', BRAND_INVITE_MSG.failed); return; }
  if (r.result === 'ok') brandToast(BRAND_INVITE_MSG.declined);
  else if (r.result === 'invalid') brandToast(BRAND_INVITE_MSG.invalid);
  await _brandAfterInvite(null);
}

// 「나중에」 — 연결 브랜드가 있으면 첫 페이지, 대기 초대만 있는 계정이면 로그아웃 + 안내
async function laterCurrentInvite() {
  _brandInviteCtx = null;
  const state = await fetchBrandLoginState();
  if (state && state.state === 'ok') { enterBrandApp(state); return; }
  await brandSignOutLocal();
  setBrandAuthed(null);
  goBrandScreen('login');
  setNotice('loginExpiredNotice', BRAND_INVITE_MSG.later);
}

function initInvite() {
  const btn = document.getElementById('inviteSubmit');
  btn.addEventListener('click', async () => {
    if (btn.disabled) return;
    if (!_brandInviteCtx) {
      // 미리보기 막대에서 연 화면 — 서버를 부르지 않는다
      btn.disabled = true; btn.textContent = '수락하는 중…';
      await brandFakeRequest('ok');
      btn.textContent = '수락했습니다';
      setNotice('inviteResult', '미리보기: 「하루담」 브랜드가 계정에 연결됐다고 가정합니다.');
      return;
    }
    await acceptCurrentInvite();
  });
  document.getElementById('inviteDecline').addEventListener('click', async (e) => {
    if (e.currentTarget.disabled) return;
    if (!_brandInviteCtx) return;
    await declineCurrentInvite();
  });
  document.getElementById('inviteLater').addEventListener('click', async (e) => {
    if (e.currentTarget.disabled) return;
    if (!_brandInviteCtx) { goBrandScreen('login'); return; }
    await laterCurrentInvite();
  });
}
