// ══════════════════════════════════════
// 관리자 — 브랜드 이용 제한·결과물 열람 정지 (개발서버만 · 마이그레이션 581~584)
//   사양서 docs/specs/2026-10-21-brand-account-restriction.md 4-7 · 작업표 …-breakdown.md 제한 9~11
//   서버 호출은 storage.js 감싸개 일곱(restrictBrandAccount … sendBrandSanctionMail)만 쓴다.
//   🔴 사유 이름표는 notify-brand-restriction 메일 함수와 사본 두 벌 — 한쪽을 바꾸면 함께.
//   제한 10 = 계정 이용 제한(걸기·기간 바꾸기·해제) · 제한 11 = 결과물 열람 정지(이 파일 아래에 더한다)
// ══════════════════════════════════════

// 계정 이용 제한 사유 — 584 검사 제약(terms_8·account_sharing·other)과 같은 열쇠
var BD_RESTRICT_REASONS = [
  { code: 'terms_8',         label: '이용약관 제8조 위반(인플루언서 정보)' },
  { code: 'account_sharing', label: '계정 공유' },
  { code: 'other',           label: '기타' }
];
var BD_RESTRICT_NOTE_MAX = 1000;   // 584 note_too_long 기준과 같다
function bdRestrictReasonLabel(code) {
  var r = BD_RESTRICT_REASONS.find(function(x){ return x.code === code; });
  return r ? r.label : (code || '');
}
// 「YYYY/MM/DD까지」 또는 「해제할 때까지」 — 날짜 칸은 일본 날짜 문자열(YYYY-MM-DD)
function bdRestrictUntilText(until) {
  return until ? String(until).replace(/-/g, '/') + '까지' : '해제할 때까지';
}

// 서버 거부 코드 → 안내(584 결과 코드)
var BD_SANCTION_REFUSALS = {
  forbidden:          '브랜드 이용 제한 권한이 없습니다.',
  invalid_reason:     '사유를 골라 주십시오.',
  note_required:      '설명을 적어 주십시오.',
  note_too_long:      '설명은 1,000자까지 쓸 수 있습니다.',
  invalid_until:      '기간은 오늘 이후 날짜로 골라 주십시오.',
  not_found:          '계정을 찾지 못했습니다 — 목록을 다시 불러왔습니다.',
  not_active_account: '사용 중인 계정만 제한할 수 있습니다.',
  already_restricted: '이미 이용 제한 중인 계정입니다.',
  not_restricted:     '이미 해제된 제한입니다 — 목록을 다시 불러왔습니다.',
  same_period:        '지금과 같은 기간입니다.'
};
// 창을 닫고 표를 다시 읽어야 하는 거부(그대로 두면 낡은 상태로 다시 누르게 된다)
var BD_SANCTION_STALE = { already_restricted: 1, not_found: 1, not_active_account: 1, not_restricted: 1, forbidden: 1 };

// ── 계정 줄 그리기 도우미 (admin-brand-detail.js _bdPeopleRowHtml 이 부른다) ──
// 제한 중 칩 + 설명 한 줄. 제한이 없으면 빈 문자열
function bdRestrictionBadgeHtml(rx) {
  if (!rx || typeof rx !== 'object') return '';
  var bits = [bdRestrictUntilText(rx.until_date), bdRestrictReasonLabel(rx.reason_code)];
  if (rx.created_by_name) bits.push(rx.created_by_name + ' 등록');
  return '<div class="bd-restrict-badge">'
    + '<span class="bd-chip is-error">이용 제한 중</span>'
    + '<div class="bd-sub">' + esc(bits.join(' · ')) + '</div>'
  + '</div>';
}
// 줄 오른쪽 동작 — 제한 중이면 「기간 바꾸기」·「제한 해제」, 아니면 「…」 → 「이용 제한」(사용 중 계정만 — 부르는 쪽이 판정)
//   🔴 단추 표시는 상태 조회의 can_restrict 하나(카탈로그를 보지 않는다 — 서버가 같은 열쇠로 거부한다)
function bdRestrictionActionsHtml(m, st) {
  if (!m || !m.auth_id || !st || st.can_restrict !== true) return '';
  var aid = jsStr(m.auth_id);
  if (m.restriction) {
    return '<button type="button" class="btn btn-ghost btn-sm" onclick="bdOpenRestrictModal(' + aid + ',\'period\')">기간 바꾸기</button>'
      + '<button type="button" class="btn btn-ghost btn-sm bd-danger" onclick="bdOpenRestrictLiftModal(' + aid + ')">제한 해제</button>';
  }
  var menuId = 'bdRowMore_' + String(m.auth_id).replace(/[^a-zA-Z0-9]/g, '');
  return '<div class="bd-more-wrap bd-row-more">'
    + '<button type="button" class="btn btn-ghost btn-sm bd-more-btn" aria-label="더 보기" aria-haspopup="menu" aria-expanded="false" onclick="bdRowMoreToggle(event,\'' + menuId + '\')">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">more_horiz</span></button>'
    + '<div class="camp-more-menu bd-more-menu" id="' + menuId + '" role="menu" style="display:none">'
      + '<div class="camp-more-item" style="color:#c0392b" onclick="bdRowMoreClose();bdOpenRestrictModal(' + aid + ',\'restrict\')">'
        + '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">block</span>이용 제한</div>'
    + '</div></div>';
}
// 줄 「…」 열고 닫기 — 머리 「…」(brandDetailToggleMoreMenu)와 같은 동작. 한 번에 하나만 연다
var _bdRowMoreOpenId = null;
function bdRowMoreToggle(e, menuId) {
  if (e) e.stopPropagation();
  var menu = $(menuId);
  if (!menu) return;
  var open = menu.style.display === 'none';
  bdRowMoreClose();
  if (!open) return;
  menu.style.display = '';
  var btn = menu.previousElementSibling;
  if (btn) btn.setAttribute('aria-expanded', 'true');
  _bdRowMoreOpenId = menuId;
  setTimeout(function() {
    document.addEventListener('click', function _close(ev) {
      var m = $(menuId);
      if (m && m.contains(ev.target)) return;
      if (_bdRowMoreOpenId === menuId) bdRowMoreClose();
      document.removeEventListener('click', _close);
    });
  }, 0);
}
function bdRowMoreClose() {
  if (!_bdRowMoreOpenId) return;
  var menu = $(_bdRowMoreOpenId);
  if (menu) {
    menu.style.display = 'none';
    var btn = menu.previousElementSibling;
    if (btn) btn.setAttribute('aria-expanded', 'false');
  }
  _bdRowMoreOpenId = null;
}

// ── 창 틀 — 계정 동작 창(_bdAcctModalRender)과 같은 모양, 창 아이디만 다르다 ──
var _bds = null;          // {mode:'restrict'|'period'|'lift', brandId, authId, name, email, rx, reason, note, untilMode, until, mail}
var _bdsBusy = false;
var _bdsReturnFocus = null;
function _bdsModalEl(id) {
  var ov = $(id);
  if (!ov) {
    ov = document.createElement('div');
    ov.id = id;
    ov.className = 'modal-overlay';
    ov.style.zIndex = '800';
    ov.setAttribute('role', 'dialog');
    ov.setAttribute('aria-modal', 'true');
    ov.setAttribute('aria-labelledby', id + 'Title');
    ov.addEventListener('keydown', function(e) { _bdModalKeydown(ov, e, function(){ if (!_bdsBusy) bdSanctionModalClose(); }); });
    document.body.appendChild(ov);
  }
  return ov;
}
function _bdsModalRender(id, parts) {
  var ov = _bdsModalEl(id);
  if (!ov.classList.contains('open')) _bdsReturnFocus = document.activeElement;
  var btns = (parts.buttons || []).map(function(b) {
    var style = b.kind === 'danger' ? ' style="background:#c0392b;border-color:#c0392b"' : '';
    return '<button type="button" class="btn ' + (b.kind === 'ghost' ? 'btn-ghost' : 'btn-primary') + '"' + style
      + (b.id ? ' id="' + b.id + '"' : '') + ' onclick="' + b.onclick + '">' + esc(b.label) + '</button>';
  }).join('');
  ov.innerHTML = '<div class="modal" style="max-width:520px;border-radius:16px;margin:auto">'
    + '<div class="modal-body" style="padding:24px 24px 20px">'
      + '<div id="' + id + 'Title" class="bd-acct-title">' + esc(parts.title || '') + '</div>'
      + (parts.error ? '<div class="bd-acct-error" role="alert"><span class="material-icons-round notranslate" translate="no">error</span><span>' + esc(parts.error) + '</span></div>' : '')
      + (parts.body || '')
      + '<div class="bd-acct-btns">' + btns + '</div>'
    + '</div></div>';
  ov.classList.add('open');
  var focus = ov.querySelector('[data-autofocus]') || ov.querySelector('.bd-acct-btns .btn:not([disabled])');
  if (focus) setTimeout(function(){ focus.focus(); }, 30);
}
function bdSanctionModalClose() {
  if (_bdsBusy) return;
  _bds = null;
  ['bdRestrictModal', 'bdRestrictLiftModal', 'bdSuspendModal', 'bdSuspendLiftModal'].forEach(function(id){ var ov = $(id); if (ov) ov.classList.remove('open'); });
  var back = _bdsReturnFocus; _bdsReturnFocus = null;
  if (back && document.contains(back) && typeof back.focus === 'function') back.focus();
}
function _bdsSetBusy(on, btnId, busyLabel) {
  _bdsBusy = !!on;
  var b = btnId ? $(btnId) : null;
  if (b) { b.disabled = !!on; if (on && busyLabel) b.textContent = busyLabel; }
}
// 이 브랜드 상태에서 계정 줄 찾기
function _bdsFindMember(authId) {
  var st = _brandDetailAccountStatus;
  var list = (st && Array.isArray(st.members)) ? st.members : [];
  return list.find(function(m){ return m && m.auth_id === authId; }) || null;
}
function _bdsCanRestrict() {
  var st = _brandDetailAccountStatus;
  return !!(st && typeof st === 'object' && st.can_restrict === true);
}
// 연결된 브랜드 문구 — 「연결된 브랜드 N개(가, 나)」 · 모르면 빈 문자열
function _bdsLinkedText(brands) {
  if (!Array.isArray(brands) || !brands.length) return '';
  return '연결된 브랜드 ' + brands.length + '개(' + brands.map(function(b){ return b && b.name ? b.name : ''; }).filter(Boolean).join(', ') + ')';
}

// ── ① 이용 제한 걸기 · ② 기간 바꾸기 (같은 창 #bdRestrictModal) ──
function bdOpenRestrictModal(authId, mode) {
  if (!_bdsCanRestrict()) { toast('브랜드 이용 제한 권한이 없습니다.', 'warn'); return; }
  var m = _bdsFindMember(authId);
  if (!m) { toast('계정을 찾지 못했습니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  var rx = m.restriction || null;
  if (mode === 'period' && !rx) { toast('이미 해제된 제한입니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  if (mode !== 'period' && rx) { toast('이미 이용 제한 중인 계정입니다.', 'warn'); bdReloadPeopleTab(); return; }
  _bds = {
    mode: mode === 'period' ? 'period' : 'restrict',
    brandId: _brandsCurrentId, authId: authId, name: _bdMemberName(m) || m.email || '', email: m.email || '', rx: rx,
    reason: rx ? rx.reason_code : '', note: rx ? (rx.reason_note || '') : '',
    untilMode: (rx && !rx.until_date) ? 'open' : 'date', until: rx && rx.until_date ? rx.until_date : '',
    mail: true
  };
  _bdsRenderRestrictModal(null);
}
// 칸 값을 상태로 옮긴다(오류로 다시 그려도 쓴 내용이 남게)
function _bdsReadRestrictForm() {
  var a = _bds; if (!a) return;
  if (a.mode === 'restrict') {
    var r = document.querySelector('input[name="bdRestrictReason"]:checked');
    a.reason = r ? r.value : '';
    var n = $('bdRestrictNote'); if (n) a.note = n.value;
  } else {
    var mc = $('bdRestrictMailChk'); if (mc) a.mail = !!mc.checked;
  }
  var um = $('bdRestrictUntilMode'); if (um) a.untilMode = um.value;
  var u = $('bdRestrictUntil'); if (u) a.until = u.value;
}
function bdRestrictUntilModeChanged() {
  _bdsReadRestrictForm();
  var u = $('bdRestrictUntil');
  if (u) u.disabled = (_bds && _bds.untilMode === 'open');
}
function _bdsRenderRestrictModal(error) {
  var a = _bds; if (!a) return;
  var period = a.mode === 'period';
  var today = jstTodayStr();
  var reasonHtml = period
    ? '<div class="bd-acct-label">사유</div><div class="bd-acct-text">' + esc(bdRestrictReasonLabel(a.reason)) + '</div>'
      + '<div class="bd-acct-label">설명</div><div class="bd-acct-text" style="white-space:pre-wrap">' + esc(a.note || '') + '</div>'
    : '<div class="bd-acct-label">사유</div><div class="bd-acct-radios">'
        + BD_RESTRICT_REASONS.map(function(r) {
            return '<label class="bd-acct-radio"><input type="radio" name="bdRestrictReason" value="' + esc(r.code) + '"' + (a.reason === r.code ? ' checked' : '') + '>' + esc(r.label) + '</label>';
          }).join('')
      + '</div>'
      + '<label class="bd-acct-label" for="bdRestrictNote">설명 — 이 내용이 메일에 그대로 들어갑니다</label>'
      + '<textarea id="bdRestrictNote" class="form-input" rows="4" maxlength="' + BD_RESTRICT_NOTE_MAX + '" style="width:100%;margin-bottom:10px">' + esc(a.note || '') + '</textarea>';
  var untilHtml = '<label class="bd-acct-label" for="bdRestrictUntilMode">기간</label>'
    + '<div style="display:flex;gap:8px;align-items:center;margin-bottom:10px">'
      + '<select id="bdRestrictUntilMode" class="admin-filter" onchange="bdRestrictUntilModeChanged()">'
        + '<option value="date"' + (a.untilMode !== 'open' ? ' selected' : '') + '>날짜까지</option>'
        + '<option value="open"' + (a.untilMode === 'open' ? ' selected' : '') + '>해제할 때까지</option>'
      + '</select>'
      + '<input id="bdRestrictUntil" type="date" class="admin-filter" min="' + esc(today) + '" max="9999-12-31" value="' + esc(a.until || '') + '"' + (a.untilMode === 'open' ? ' disabled' : '') + '>'
    + '</div>';
  var mailHtml = period
    ? '<label class="bd-acct-radio" style="margin-bottom:10px"><input type="checkbox" id="bdRestrictMailChk"' + (a.mail ? ' checked' : '') + '>바뀐 기간을 이메일로 알립니다</label>'
    : '';
  var linked = _bdsLinkedText(a.rx && a.rx.linked_brands);
  var who = '<div class="bd-acct-mailbox"><div class="bd-acct-mailbox-label">계정 이메일</div>'
    + '<div class="bd-acct-mailbox-email" style="font-size:16px">' + esc(a.email) + '</div>'
    + (linked ? '<div class="bd-sub" style="margin-top:4px">' + esc(linked) + '</div>' : '') + '</div>';
  var notes = period
    ? (a.rx ? '<div class="bd-acct-text is-muted">지금 기간: ' + esc(bdRestrictUntilText(a.rx.until_date)) + '</div>' : '')
    : _bdBullets([
        '제한하면 그 계정은 다음 동작부터 로그아웃되고, 연결된 모든 브랜드에서 브랜드 페이지를 쓸 수 없습니다.',
        '같은 브랜드의 다른 담당자 계정은 그대로 쓸 수 있습니다. 계정 이메일로 사유와 기간을 알립니다.'
      ]);
  _bdsModalRender('bdRestrictModal', {
    title: period ? (a.name || '이 계정') + ' 계정의 이용 제한 기간을 바꾸시겠습니까?'
                  : (a.name || '이 계정') + ' 계정의 브랜드 페이지 이용을 제한하시겠습니까?',
    error: error,
    body: who + reasonHtml + untilHtml + mailHtml + notes,
    buttons: [
      { label: '취소', kind: 'ghost', onclick: 'bdSanctionModalClose()' },
      period ? { label: '기간 바꾸기', kind: 'primary', id: 'bdRestrictSubmit', onclick: 'bdRestrictSubmit()' }
             : { label: '이용 제한', kind: 'danger', id: 'bdRestrictSubmit', onclick: 'bdRestrictSubmit()' }
    ]
  });
}
// 화면 검사 — 서버도 같은 것을 거부한다(화면은 먼저 알려 줄 뿐)
function _bdsRestrictIssue(a) {
  if (a.mode === 'restrict') {
    if (!a.reason) return '사유를 골라 주십시오.';
    if (!String(a.note || '').trim()) return '설명을 적어 주십시오.';
    if (String(a.note).length > BD_RESTRICT_NOTE_MAX) return '설명은 1,000자까지 쓸 수 있습니다.';
  }
  if (a.untilMode !== 'open') {
    if (!a.until) return '날짜를 골라 주십시오. 날짜 없이 걸려면 「해제할 때까지」를 고르십시오.';
    // 날짜 칸에 숫자를 이어 치면 연도가 여섯 자리로 들어간다 — 서버는 먼 미래 날짜도 받으므로 화면에서 형식을 막는다
    if (!/^\d{4}-\d{2}-\d{2}$/.test(a.until)) return '날짜를 다시 골라 주십시오(연도는 네 자리).';
    if (a.until < jstTodayStr()) return '기간은 오늘 이후 날짜로 골라 주십시오.';
  }
  return null;
}
async function bdRestrictSubmit() {
  var a = _bds;
  if (!a || (a.mode !== 'restrict' && a.mode !== 'period') || _bdsBusy) return;
  _bdsReadRestrictForm();
  var issue = _bdsRestrictIssue(a);
  if (issue) { _bdsRenderRestrictModal(issue); return; }
  var until = a.untilMode === 'open' ? null : a.until;
  if (a.mode === 'period' && a.rx && (a.rx.until_date || null) === until) { _bdsRenderRestrictModal('지금과 같은 기간입니다.'); return; }
  _bdsSetBusy(true, 'bdRestrictSubmit', a.mode === 'period' ? '바꾸는 중…' : '거는 중…');
  var res;
  try {
    res = a.mode === 'period'
      ? await changeBrandRestrictionPeriod(a.rx.id, until)
      : await restrictBrandAccount(a.authId, a.reason, String(a.note).trim(), until);
  } catch (e) { console.error('[bdRestrictSubmit]', e); res = { ok: false, error: 'invoke_failed' }; }
  _bdsBusy = false;
  if (!res || !res.ok) { _bdsRenderRestrictModal(BD_TOAST_FAIL); return; }
  var d = res.data || {};
  if (d.result !== 'ok') {
    var msg = BD_SANCTION_REFUSALS[d.result] || (BD_TOAST_FAIL + ' [' + String(d.result || 'empty') + ']');
    if (BD_SANCTION_STALE[d.result]) { bdSanctionModalClose(); toast(msg, 'warn'); await _bdsAfterAction(); return; }
    _bdsRenderRestrictModal(msg);
    return;
  }
  var who = a.name || '계정';
  var done = a.mode === 'period' ? who + ' 계정의 이용 제한 기간을 바꿨습니다.' : who + ' 계정의 브랜드 페이지 이용을 제한했습니다.';
  var sendMail = a.mode === 'restrict' || a.mail;
  bdSanctionModalClose();
  // 🔴 기간 바꾸기는 서버가 새 줄을 만든다 — 메일은 응답의 새 번호로(옛 번호면 not_eligible)
  if (sendMail && d.restriction_id) await _bdsSendMail(a.mode === 'period' ? 'account_period' : 'account_restrict', d.restriction_id, done);
  else toast(done);
  await _bdsAfterAction();
}

// ── ③ 제한 해제 (#bdRestrictLiftModal) ──
function bdOpenRestrictLiftModal(authId) {
  if (!_bdsCanRestrict()) { toast('브랜드 이용 제한 권한이 없습니다.', 'warn'); return; }
  var m = _bdsFindMember(authId);
  if (!m || !m.restriction) { toast('이미 해제된 제한입니다 — 목록을 다시 불러왔습니다.', 'warn'); bdReloadPeopleTab(); return; }
  _bds = { mode: 'lift', brandId: _brandsCurrentId, authId: authId, name: _bdMemberName(m) || m.email || '', email: m.email || '', rx: m.restriction, mail: true };
  _bdsRenderLiftModal(null);
}
function _bdsRenderLiftModal(error) {
  var a = _bds; if (!a) return;
  var linked = _bdsLinkedText(a.rx && a.rx.linked_brands);
  _bdsModalRender('bdRestrictLiftModal', {
    title: (a.name || '이 계정') + ' 계정의 이용 제한을 해제하시겠습니까?',
    error: error,
    body: '<div class="bd-acct-text">바로 로그인할 수 있게 됩니다.' + (linked ? ' ' + esc(linked) + ' 모두에서 풀립니다.' : '') + '</div>'
      // 겹침 확인에서 연 창은 사유·기간을 모른다(조회가 번호·연결 브랜드만 준다) — 그때는 이 줄을 뺀다
      + (a.rx && a.rx.reason_code ? '<div class="bd-acct-text is-muted">지금 제한: ' + esc(bdRestrictUntilText(a.rx.until_date)) + ' · ' + esc(bdRestrictReasonLabel(a.rx.reason_code)) + '</div>' : '')
      + '<label class="bd-acct-radio" style="margin-bottom:4px"><input type="checkbox" id="bdRestrictLiftMailChk"' + (a.mail ? ' checked' : '') + '>해제를 이메일로 알립니다</label>',
    buttons: [
      { label: '취소', kind: 'ghost', onclick: 'bdSanctionModalClose()' },
      { label: '제한 해제', kind: 'primary', id: 'bdRestrictLiftSubmit', onclick: 'bdRestrictLiftSubmit()' }
    ]
  });
}
async function bdRestrictLiftSubmit() {
  var a = _bds;
  if (!a || a.mode !== 'lift' || _bdsBusy) return;
  var mc = $('bdRestrictLiftMailChk'); if (mc) a.mail = !!mc.checked;
  _bdsSetBusy(true, 'bdRestrictLiftSubmit', '해제하는 중…');
  var res;
  try { res = await liftBrandAccountRestriction(a.rx.id); }
  catch (e) { console.error('[bdRestrictLiftSubmit]', e); res = { ok: false, error: 'invoke_failed' }; }
  _bdsBusy = false;
  if (!res || !res.ok) { _bdsRenderLiftModal(BD_TOAST_FAIL); return; }
  var d = res.data || {};
  if (d.result !== 'ok') {
    var msg = BD_SANCTION_REFUSALS[d.result] || (BD_TOAST_FAIL + ' [' + String(d.result || 'empty') + ']');
    bdSanctionModalClose(); toast(msg, 'warn'); await _bdsAfterAction();
    return;
  }
  var done = (a.name || '계정') + ' 계정의 이용 제한을 해제했습니다.';
  var rxId = a.rx.id, sendMail = a.mail;
  bdSanctionModalClose();
  if (sendMail) await _bdsSendMail('account_lift', rxId, done);
  else toast(done);
  await _bdsAfterAction();
}

// ── 공통 — 메일·다시 그리기 ──
// 메일은 동작이 끝난 뒤 따로 — 실패해도 제한·해제는 그대로다(sent:false 는 사유와 무관하게 한 문구)
async function _bdsSendMail(kind, refId, doneMsg) {
  var mail = null;
  try { mail = await sendBrandSanctionMail(kind, refId); } catch (e) { console.error('[_bdsSendMail]', e); }
  if (mail && mail.sent) {
    toast(doneMsg + (mail.dev_mail ? ' (개발서버 — 메일 대신 내용만 만들었습니다)' : ' 알림 메일을 보냈습니다.'));
    if (mail.dev_mail) console.info('[notify-brand-restriction dev_mail]', kind, mail.dev_mail);
    return;
  }
  toast(doneMsg + ' 알림 메일을 보내지 못했습니다.', 'warn');
}
async function _bdsAfterAction() {
  // 캠페인 목록 「열람 정지」 배지(이용 제한 12)가 다음 그리기에서 새로 받게
  if (typeof _campListSuspendedMap !== 'undefined') _campListSuspendedMap = undefined;
  if (typeof refreshPane === 'function') await refreshPane('brand-detail');
  await bdReloadPeopleTab();   // 계정 상태를 다시 받고 머리 정지 배지·「…」 항목도 다시 그린다(bdSanctionSyncHead)
}

// ══════════════════════════════════════
// 제한 11 — 결과물 열람 정지(브랜드 단위) · 겹침 확인에서 만난 제한 계정
//   정지 여부·권한은 계정 상태 조회(results_suspension · can_restrict)가 준다 — 머리는 그 조회보다 먼저 그려지므로
//   조회가 끝날 때마다 bdSanctionSyncHead 가 머리 배지 자리·「…」 항목만 다시 그린다.
// ══════════════════════════════════════
// 열람 정지 사유 — 584 검사(terms_8·other)와 같은 열쇠. 이름표는 계정 제한과 같은 글자(메일 함수 사본)
var BD_SUSPEND_REASONS = BD_RESTRICT_REASONS.filter(function(r){ return r.code !== 'account_sharing'; });
var BD_SUSPEND_REFUSALS = {
  forbidden:         '브랜드 이용 제한 권한이 없습니다.',
  invalid_reason:    '사유를 골라 주십시오.',
  note_required:     '설명을 적어 주십시오.',
  note_too_long:     '설명은 1,000자까지 쓸 수 있습니다.',
  brand_not_found:   '브랜드를 찾지 못했습니다(비활성 브랜드는 정지할 수 없습니다) — 다시 불러왔습니다.',
  already_suspended: '이미 결과물 열람이 정지된 브랜드입니다.',
  not_suspended:     '이미 풀린 정지입니다 — 다시 불러왔습니다.'
};

// 머리 — 상태 배지 옆 정지 배지 + 「…」 의 「결과물 열람 정지」 항목. 조회 전(undefined)·실패(null)면 둘 다 그리지 않는다
function bdSanctionSyncHead() {
  var st = _brandDetailAccountStatus;
  var known = !!(st && typeof st === 'object');
  var sus = known ? (st.results_suspension || null) : null;
  var can = known && st.can_restrict === true;
  var slot = $('brandDetailSuspendBadge');
  if (slot) {
    if (!sus) slot.innerHTML = '';
    else {
      var bits = [formatDate(sus.created_at) + '부터', sus.include_shipping ? '배송 리스트 포함' : '배송 리스트 제외'];
      if (sus.created_by_name) bits.push(sus.created_by_name + ' 등록');
      slot.innerHTML = '<span class="bd-suspend-head">'
        + '<span class="bd-chip is-error">결과물 열람 정지 중</span>'
        + '<span class="bd-sub">' + esc(bits.join(' · ')) + '</span>'
        + (can ? '<button type="button" class="btn btn-ghost btn-sm" onclick="bdOpenSuspendLiftModal()">정지 해제</button>' : '')
      + '</span>';
    }
  }
  // 「…」 항목 — 권한 있고 정지 중이 아닐 때만. 「…」 가 없으면 만들고, 항목이 0개가 되면 지운다(brandDetailSyncMoreMenu)
  var want = known && can && !sus;
  var item = $('brandDetailSuspendItem');
  if (!want) {
    if (item) item.remove();
    if (typeof brandDetailSyncMoreMenu === 'function') brandDetailSyncMoreMenu();
    return;
  }
  if (item) return;
  var menu = $('brandDetailMoreMenu');
  if (!menu) {
    var acts = document.querySelector('.bd-head .bd-head-actions');
    if (!acts) return;
    var wrap = document.createElement('div');
    wrap.className = 'bd-more-wrap';
    wrap.id = 'brandDetailMoreWrap';
    wrap.innerHTML = '<button type="button" class="btn btn-ghost btn-sm bd-more-btn" id="brandDetailMoreBtn" aria-label="더 보기" aria-haspopup="menu" aria-expanded="false" onclick="brandDetailToggleMoreMenu(event)">'
        + '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">more_horiz</span></button>'
      + '<div class="camp-more-menu bd-more-menu" id="brandDetailMoreMenu" role="menu" style="display:none"></div>';
    acts.appendChild(wrap);
    menu = $('brandDetailMoreMenu');
  }
  var el = document.createElement('div');
  el.className = 'camp-more-item';
  el.id = 'brandDetailSuspendItem';
  el.style.color = '#c0392b';
  el.setAttribute('onclick', 'brandDetailCloseMoreMenu();bdOpenSuspendModal()');
  el.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">visibility_off</span>결과물 열람 정지';
  menu.insertBefore(el, menu.firstChild);
}

// ── ④ 결과물 열람 정지 (#bdSuspendModal) ──
function bdOpenSuspendModal() {
  var st = _brandDetailAccountStatus;
  if (!_bdsCanRestrict()) { toast('브랜드 이용 제한 권한이 없습니다.', 'warn'); return; }
  if (st.results_suspension) { toast('이미 결과물 열람이 정지된 브랜드입니다.', 'warn'); return; }
  _bds = { mode: 'suspend', brandId: _brandsCurrentId, reason: '', note: '', shipping: false };
  _bdsRenderSuspendModal(null);
}
function _bdsReadSuspendForm() {
  var a = _bds; if (!a) return;
  var r = document.querySelector('input[name="bdSuspendReason"]:checked');
  a.reason = r ? r.value : '';
  var n = $('bdSuspendNote'); if (n) a.note = n.value;
  var s = $('bdSuspendShipping'); if (s) a.shipping = !!s.checked;
}
function _bdsRenderSuspendModal(error) {
  var a = _bds; if (!a || a.mode !== 'suspend') return;
  var brandName = (_brandDetailBrand && _brandDetailBrand.name) || '이 브랜드';
  _bdsModalRender('bdSuspendModal', {
    title: brandName + '의 결과물 열람을 정지하시겠습니까?',
    error: error,
    body: '<div class="bd-acct-label">사유</div><div class="bd-acct-radios">'
        + BD_SUSPEND_REASONS.map(function(r) {
            return '<label class="bd-acct-radio"><input type="radio" name="bdSuspendReason" value="' + esc(r.code) + '"' + (a.reason === r.code ? ' checked' : '') + '>' + esc(r.label) + '</label>';
          }).join('')
      + '</div>'
      + '<label class="bd-acct-label" for="bdSuspendNote">설명 — 이 내용이 메일에 그대로 들어갑니다</label>'
      + '<textarea id="bdSuspendNote" class="form-input" rows="4" maxlength="' + BD_RESTRICT_NOTE_MAX + '" style="width:100%;margin-bottom:10px">' + esc(a.note || '') + '</textarea>'
      + '<div class="bd-acct-label">막을 것</div>'
      + '<div class="bd-acct-text">결과물 표 · 엑셀 내려받기 · 영수증 사진</div>'
      + '<label class="bd-acct-radio"><input type="checkbox" id="bdSuspendShipping"' + (a.shipping ? ' checked' : '') + '>시딩형 배송 리스트도</label>'
      + '<div class="bd-acct-text is-muted" style="margin-top:4px">켜면 브랜드가 배송 정보를 볼 수 없어 발송이 멈출 수 있습니다.</div>'
      + _bdBullets(['모집 현황·일정은 그대로 볼 수 있습니다.', '대표 담당자·멤버에게 이메일로 알립니다.']),
    buttons: [
      { label: '취소', kind: 'ghost', onclick: 'bdSanctionModalClose()' },
      { label: '결과물 열람 정지', kind: 'danger', id: 'bdSuspendSubmit', onclick: 'bdSuspendSubmit()' }
    ]
  });
}
async function bdSuspendSubmit() {
  var a = _bds;
  if (!a || a.mode !== 'suspend' || _bdsBusy) return;
  _bdsReadSuspendForm();
  var issue = !a.reason ? '사유를 골라 주십시오.'
    : !String(a.note || '').trim() ? '설명을 적어 주십시오.'
    : String(a.note).length > BD_RESTRICT_NOTE_MAX ? '설명은 1,000자까지 쓸 수 있습니다.' : null;
  if (issue) { _bdsRenderSuspendModal(issue); return; }
  _bdsSetBusy(true, 'bdSuspendSubmit', '정지하는 중…');
  var res;
  try { res = await suspendBrandResults(a.brandId, a.reason, String(a.note).trim(), a.shipping); }
  catch (e) { console.error('[bdSuspendSubmit]', e); res = { ok: false, error: 'invoke_failed' }; }
  _bdsBusy = false;
  if (!res || !res.ok) { _bdsRenderSuspendModal(BD_TOAST_FAIL); return; }
  var d = res.data || {};
  if (d.result !== 'ok') {
    var msg = BD_SUSPEND_REFUSALS[d.result] || (BD_TOAST_FAIL + ' [' + String(d.result || 'empty') + ']');
    if (d.result === 'invalid_reason' || d.result === 'note_required' || d.result === 'note_too_long') { _bdsRenderSuspendModal(msg); return; }
    bdSanctionModalClose(); toast(msg, 'warn'); await _bdsAfterAction();
    return;
  }
  bdSanctionModalClose();
  // ④ 는 걸 때 항상 보낸다(받는 사람 = 대표·멤버 중 제한 아닌 계정 — 서버가 정한다)
  if (d.suspension_id) await _bdsSendMail('results_suspend', d.suspension_id, '결과물 열람을 정지했습니다.');
  else toast('결과물 열람을 정지했습니다.');
  await _bdsAfterAction();
}

// ── ⑤ 열람 정지 해제 (#bdSuspendLiftModal) ──
function bdOpenSuspendLiftModal() {
  var st = _brandDetailAccountStatus;
  if (!_bdsCanRestrict()) { toast('브랜드 이용 제한 권한이 없습니다.', 'warn'); return; }
  var sus = st.results_suspension;
  if (!sus) { toast('이미 풀린 정지입니다 — 다시 불러왔습니다.', 'warn'); _bdsAfterAction(); return; }
  _bds = { mode: 'suspend_lift', brandId: _brandsCurrentId, sus: sus, mail: true };
  _bdsRenderSuspendLiftModal(null);
}
function _bdsRenderSuspendLiftModal(error) {
  var a = _bds; if (!a || a.mode !== 'suspend_lift') return;
  var brandName = (_brandDetailBrand && _brandDetailBrand.name) || '이 브랜드';
  _bdsModalRender('bdSuspendLiftModal', {
    title: brandName + '의 결과물 열람 정지를 해제하시겠습니까?',
    error: error,
    body: '<div class="bd-acct-text">대표 담당자·멤버가 결과물 표·엑셀·영수증 사진' + (a.sus.include_shipping ? '·배송 리스트' : '') + '를 다시 볼 수 있게 됩니다.</div>'
      + '<label class="bd-acct-radio" style="margin-bottom:4px"><input type="checkbox" id="bdSuspendLiftMailChk"' + (a.mail ? ' checked' : '') + '>해제를 이메일로 알립니다</label>',
    buttons: [
      { label: '취소', kind: 'ghost', onclick: 'bdSanctionModalClose()' },
      { label: '정지 해제', kind: 'primary', id: 'bdSuspendLiftSubmit', onclick: 'bdSuspendLiftSubmit()' }
    ]
  });
}
async function bdSuspendLiftSubmit() {
  var a = _bds;
  if (!a || a.mode !== 'suspend_lift' || _bdsBusy) return;
  var mc = $('bdSuspendLiftMailChk'); if (mc) a.mail = !!mc.checked;
  _bdsSetBusy(true, 'bdSuspendLiftSubmit', '해제하는 중…');
  var res;
  try { res = await liftBrandResultsSuspension(a.brandId); }
  catch (e) { console.error('[bdSuspendLiftSubmit]', e); res = { ok: false, error: 'invoke_failed' }; }
  _bdsBusy = false;
  if (!res || !res.ok) { _bdsRenderSuspendLiftModal(BD_TOAST_FAIL); return; }
  var d = res.data || {};
  if (d.result !== 'ok') {
    bdSanctionModalClose();
    toast(BD_SUSPEND_REFUSALS[d.result] || (BD_TOAST_FAIL + ' [' + String(d.result || 'empty') + ']'), 'warn');
    await _bdsAfterAction();
    return;
  }
  var sid = d.suspension_id || a.sus.id, sendMail = a.mail;
  bdSanctionModalClose();
  if (sendMail && sid) await _bdsSendMail('results_lift', sid, '결과물 열람 정지를 해제했습니다.');
  else toast('결과물 열람 정지를 해제했습니다.');
  await _bdsAfterAction();
}

// ── 겹침 확인에서 만난 제한 계정 (A12) — 「계정 만들기」·「브랜드 연결 추가」 ──
//   chk = admin_check_brand_account_email 결과(restricted·restriction_id·linked_brands). 연결 요청 결과 account_restricted 는
//   번호를 주지 않으므로 겹침 확인을 한 번 더 불러 받는다.
async function bdShowRestrictedAccount(email, chk) {
  var cd = chk || null;
  if (!cd || !cd.restriction_id) {
    try { var r = await checkBrandAccountEmail(_brandsCurrentId, email); cd = (r && r.ok) ? (r.data || null) : null; }
    catch (e) { console.error('[bdShowRestrictedAccount]', e); cd = null; }
  }
  var rid = cd && cd.restricted ? cd.restriction_id : null;
  var can = _bdsCanRestrict() && !!rid;
  _bdAcct = null;
  if (typeof bdAccountModalClose === 'function') bdAccountModalClose();
  _bds = { mode: 'restricted_notice', brandId: _brandsCurrentId, email: email, name: (cd && cd.name) || email,
           rx: rid ? { id: rid, linked_brands: Array.isArray(cd.linked_brands) ? cd.linked_brands : [] } : null, mail: true };
  _bdsModalRender('bdRestrictLiftModal', {
    title: '이용이 제한된 계정이라 연결할 수 없습니다',
    body: '<div class="bd-acct-text">' + esc(email) + ' 계정은 지금 브랜드 페이지 이용이 제한되어 있습니다.</div>'
      + '<div class="bd-acct-text is-muted">' + (can ? '연결하려면 먼저 제한을 해제하십시오. 해제한 뒤 다시 시도하면 연결 요청을 보낼 수 있습니다.' : '제한을 해제할 권한이 있는 관리자에게 요청하십시오.') + '</div>',
    buttons: can
      ? [{ label: '닫기', kind: 'ghost', onclick: 'bdSanctionModalClose()' }, { label: '제한 해제', kind: 'primary', onclick: 'bdRestrictedNoticeLift()' }]
      : [{ label: '확인', kind: 'primary', onclick: 'bdSanctionModalClose()' }]
  });
}
// 안내 창 → 해제 확인 창(같은 자리에서 다시 그린다). 연결 0개면 확인 문구의 둘째 문장이 빠진다(_bdsLinkedText 가 빈 값)
function bdRestrictedNoticeLift() {
  var a = _bds; if (!a || a.mode !== 'restricted_notice' || !a.rx) return;
  a.mode = 'lift';
  _bdsRenderLiftModal(null);
}
