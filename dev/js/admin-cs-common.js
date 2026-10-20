// ════════════════════════════════════════════════════════════════════
// admin-cs-common.js — CS 이력 관리 화면 공용 부품 (작업표 조각 2-0)
//   CS 이력 표(admin-cs-history.js · 건 상세 모달)와 메시지 화면 CS 패널(admin-cs-panel.js)이 같이 쓴다.
//   🔴 판정은 여기 한 곳 — 완료 양식 미리 채움 순서(D-17)·빈 칸 검사·항목 선택지(미분류 숨김)·시간 표기
//   데이터 함수는 storage.js 「CS 이력 관리」 절(개발서버만 — csHistoryEnabled)
// ════════════════════════════════════════════════════════════════════

const CS_STATUS_LABEL_KO = { in_progress: '진행중', needs_check: '확인필요', done: '완료' };
const CS_SOURCE_LABEL_KO = {
  campaign_inquiry: '캠페인 문의', service_inquiry: '서비스 문의', mail: '메일', line: 'LINE', other: '기타'
};
const CS_MANUAL_SOURCES = ['mail', 'line', 'other'];
const CS_LEGACY_CATEGORY = 'legacy_unclassified';   // 백필 전용 — 고르는 자리에서 숨긴다(D-7)
const CS_COMMENT_MAX_FILES = 5;                       // 562 cs_add_comment 상한

// 거부 코드(562·563 P0001 메시지) → 문구. 조회의 권한 거부는 42501
const CS_ERROR_TEXT_KO = {
  forbidden: '메시지 메뉴 권한이 없어 CS 이력을 다룰 수 없습니다.',
  case_not_found: 'CS 건을 찾을 수 없습니다. 화면을 새로 고쳐 주세요.',
  version_conflict: '다른 관리자가 먼저 이 건을 고쳤습니다. 최신 내용으로 다시 불러왔으니 확인 뒤 다시 저장해 주세요.',
  case_purged: '개인정보가 정리된 건이라 고칠 수 없습니다.',
  already_done: '이미 완료된 건입니다.',
  not_done: '완료된 건이 아닙니다.',
  category_required: '항목을 골라 주세요.',
  invalid_category: '고를 수 없는 항목입니다. 다른 항목을 골라 주세요.',
  response_required: '대응 안내 내용을 적어 주세요.',
  response_too_long: '대응 안내 내용이 너무 깁니다.',
  completed_at_required: '완료 일시를 넣어 주세요.',
  completed_at_future: '완료 일시가 미래입니다.',
  completed_before_received: '완료 일시가 접수 일시보다 빠릅니다.',
  invalid_status: '바꿀 수 없는 진행현황입니다.',
  messages_required: '회원 글을 하나 이상 골라 주세요.',
  invalid_messages: '고른 글 중에 이 대화의 회원 글이 아닌 것이 있습니다.',
  contains_case_start: '다른 CS 건을 시작한 글은 옮길 수 없습니다.',
  summary_required: '문의 요약을 적어 주세요.',
  summary_too_long: '문의 요약이 너무 깁니다.',
  invalid_source: '출처를 골라 주세요.',
  received_at_required: '접수 일시를 넣어 주세요.',
  received_at_future: '접수 일시가 미래입니다.',
  reply_before_received: '첫 답장 일시가 접수 일시보다 빠릅니다.',
  member_required: '회원을 고르거나 이름·이메일을 적어 주세요.',
  member_not_found: '고른 회원을 찾을 수 없습니다.',
  invalid_manual_category: '분류를 골라 주세요.',
  inquiry_required: '문의 내용을 적어 주세요.',
  text_too_long: '입력한 글이 너무 깁니다.',
  campaign_not_found: '고른 캠페인을 찾을 수 없습니다.',
  not_manual_case: '수기 등록 건만 편집할 수 있습니다.',
  invalid_attachments: '첨부 파일을 올리지 못했습니다. 이미지 5장까지 다시 골라 주세요.',
  comment_empty: '메모 내용을 적거나 이미지를 붙여 주세요.',
  comment_too_long: '메모가 너무 깁니다(5,000자까지).',
  invalid_parent: '댓글을 달 수 없는 메모입니다(지워졌거나 답글입니다).',
  comment_not_found: '메모를 찾을 수 없습니다.',
  sheet_comment_locked: '시트에서 옮겨 온 메모는 지울 수 없습니다.',
  not_own_comment: '내가 쓴 메모만 지울 수 있습니다.'
};

function csErrorCode(err) {
  const msg = String((err && err.message) || err || '');
  return Object.keys(CS_ERROR_TEXT_KO).find(c => msg === c || msg.includes(c)) || null;
}
// 화면에 보일 문구 — 아는 코드는 우리 문구, 모르면 공용 오류 문구
function csErrorText(err) {
  if (err && err.code === '42501') return CS_ERROR_TEXT_KO.forbidden;
  const code = csErrorCode(err);
  if (code) return CS_ERROR_TEXT_KO[code] + ` [CS_${code.toUpperCase()}]`;
  return friendlyError((err && err.message) || String(err));
}

// 「3시간 20분」 · 「2일 3시간」 · 「45분」 · 1분 미만 「1분 미만」 · 값 없음 「—」
function csFormatDuration(sec) {
  if (sec == null || isNaN(sec) || sec < 0) return '—';
  const min = Math.floor(sec / 60);
  if (min < 1) return '1분 미만';
  const d = Math.floor(min / 1440), h = Math.floor((min % 1440) / 60), m = min % 60;
  if (d > 0) return h > 0 ? `${d}일 ${h}시간` : `${d}일`;
  if (h > 0) return m > 0 ? `${h}시간 ${m}분` : `${h}시간`;
  return `${m}분`;
}
// 두 시각 사이 — 「시간 미상」 건·빈 값은 「—」
function csDurationBetween(fromIso, toIso, timeUnknown) {
  if (timeUnknown || !fromIso || !toIso) return '—';
  return csFormatDuration((new Date(toIso) - new Date(fromIso)) / 1000);
}

function csIsManual(row) { return !!row && CS_MANUAL_SOURCES.includes(row.source); }

// ── 항목(기준 데이터 cs_category) ─────────────────────────────
let _csCategories = null;   // 전체(끈 것·미분류 포함) — 이름표용
// 실패 null(이전에 받은 목록이 있으면 그것) — 🔴 csCategoryOptionsHtml·csCategoryLabel 보다 먼저 불러 둔다
async function csLoadCategories(force) {
  if (_csCategories && !force) return _csCategories;
  try { _csCategories = await fetchLookupsAll('cs_category'); }
  catch (e) { console.error('[csLoadCategories]', e); return _csCategories || null; }
  return _csCategories;
}
function csCategoryLabel(code) {
  if (!code) return '';
  const r = (_csCategories || []).find(x => x.code === code);
  return r ? r.name_ko : code;
}
// 고르는 자리의 선택지 — 미분류(과거)는 늘 숨기고, 끈 항목은 이미 골라 둔 값일 때만 남긴다
function csCategoryOptionsHtml(selected) {
  const rows = (_csCategories || []).filter(r =>
    r.code !== CS_LEGACY_CATEGORY && (r.active || r.code === selected));
  const sel = (selected === CS_LEGACY_CATEGORY) ? '' : (selected || '');
  return `<option value="">항목 선택</option>` + rows.map(r =>
    `<option value="${esc(r.code)}"${r.code === sel ? ' selected' : ''}>${esc(r.name_ko)}${r.active ? '' : ' (끔)'}</option>`).join('');
}

// ── 완료 양식 미리 채움(D-17) — 순서 ①~④ 판정은 여기 한 곳 ──────────
//   ① 이미 저장된 대응 안내 ② 수기 건이면 등록 때 대응 내용(한국어 칸, 없으면 일본어 칸)
//   ③ 앱 건이면 접수 뒤 대화의 마지막 운영팀 글(lastStaffReply — fetchCsLastStaffReply 결과) ④ 빈칸
//   「시간 미상」 건은 접수 시각을 기준으로 쓰지 않으므로 ③ 을 건너뛴다
function csResponsePrefill(row, lastStaffReply) {
  if (!row) return '';
  if (row.response_body) return row.response_body;
  if (csIsManual(row)) return row.manual_response_ko || row.manual_response_ja || '';
  if (!row.time_unknown && lastStaffReply && lastStaffReply.body) return lastStaffReply.body;
  return '';
}
// ③ 이 필요한 건인가 — 부르는 쪽이 이것이 참일 때만 fetchCsLastStaffReply 를 부른다
function csNeedsStaffReplyPrefill(row) {
  return !!row && !row.response_body && !csIsManual(row) && !row.time_unknown;
}

// 날짜 입력 칸 값(로컬 시각) ↔ ISO
function csToLocalInput(iso) {
  const d = iso ? new Date(iso) : new Date();
  if (isNaN(d.getTime())) return '';
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}
function csFromLocalInput(v) {
  if (!v) return null;
  const d = new Date(v);
  return isNaN(d.getTime()) ? null : d.toISOString();
}

// 완료 양식 — 항목 + 대응 안내(+ 수기 건 완료 일시). prefix 로 같은 화면에 둘이 있어도 칸 id 가 겹치지 않게
//   「완료 저장」은 늘 누를 수 있다 — 빈 칸은 csReadCompleteForm 이 빨갛게 표시하고 막는다(D-17·a10-07a)
function csCompleteFormHtml(row, prefillText, prefix) {
  const manual = csIsManual(row);
  return `<div class="cs-complete-form" data-cs-form="${esc(prefix)}">
    <label class="cs-field-label" for="${esc(prefix)}Category">항목</label>
    <select id="${esc(prefix)}Category" class="form-input cs-field">${csCategoryOptionsHtml(row && row.category_code)}</select>
    <label class="cs-field-label" for="${esc(prefix)}Response">대응 안내 내용</label>
    <textarea id="${esc(prefix)}Response" class="form-input cs-field" rows="4" placeholder="회원에게 안내한 내용">${esc(prefillText || '')}</textarea>
    ${manual ? `<label class="cs-field-label" for="${esc(prefix)}CompletedAt">완료 일시</label>
    <input type="datetime-local" id="${esc(prefix)}CompletedAt" class="form-input cs-field" value="${esc(csToLocalInput(null))}">` : ''}
  </div>`;
}
// 읽고 검사 — {ok, category, response, completedAt} · 빈 칸은 .cs-field-error(빨간 테두리)
function csReadCompleteForm(row, prefix) {
  const cat = $(prefix + 'Category'), resp = $(prefix + 'Response'), at = $(prefix + 'CompletedAt');
  const out = {
    category: cat ? cat.value : '',
    response: resp ? resp.value.trim() : '',
    completedAt: (csIsManual(row) && at) ? csFromLocalInput(at.value) : null
  };
  const missing = [];
  if (!out.category) missing.push(cat);
  if (!out.response) missing.push(resp);
  if (csIsManual(row) && !out.completedAt) missing.push(at);
  [cat, resp, at].forEach(el => { if (el) el.classList.toggle('cs-field-error', missing.includes(el)); });
  out.ok = missing.length === 0;
  return out;
}

// 상태 배지 — 완료(보라 강조)·확인필요(주황)·진행중(회색)
function csStatusBadgeHtml(status) {
  const cls = status === 'done' ? 'cs-badge-done' : status === 'needs_check' ? 'cs-badge-check' : 'cs-badge-progress';
  return `<span class="cs-badge ${cls}">${esc(CS_STATUS_LABEL_KO[status] || status || '')}</span>`;
}

// ════════════════════════════════════════════════════════════════════
// 메모(담당자 댓글 — D-11·D-16) — 건마다 목록 + 입력란 + 답글 한 단계
//   csMountComments(caseId, el, opts) 가 조회 → 그리기 → (opts.markRead 면) 읽음 순서로 돈다.
//   읽음 결과로 다시 그리지 않는다(2-2 주의 — 오리엔시트 메모 선례). 「새」 표시는 연 순간의 상태다
//   🔴 비운 건(personal_purged_at)·지운 메모는 첨부 이름·서명 주소를 만들지 않는다(파일은 아직 안 지워졌다 — 563)
// ════════════════════════════════════════════════════════════════════
const _csCommentState = {};   // caseId → {el, opts, comments, reads, replyTo, replyName, draft, files, busy}

function _csCs(caseId) { return _csCommentState[caseId] || (_csCommentState[caseId] = { draft: '', files: [] }); }

// opts = {purged:boolean, markRead:boolean, onChanged:function}
async function csMountComments(caseId, el, opts) {
  if (!el || !caseId) return;
  const st = _csCs(caseId);
  st.el = el; st.opts = opts || {};
  el.innerHTML = '<div class="cs-memo-loading">메모를 불러오는 중…</div>';
  const list = await fetchCsComments(caseId);
  if (list === null) { el.innerHTML = '<div class="cs-memo-error">메모를 불러오지 못했습니다. 다시 열어 주세요.</div>'; return; }
  st.comments = list;
  st.reads = await fetchCsMyCommentReads(list.map(c => c.id));
  _csRenderComments(caseId);
  _csHydrateCommentImages(caseId);
  if (st.opts.markRead && list.length) await csMarkCaseCommentsRead(caseId);
}

function _csRenderComments(caseId) {
  const st = _csCs(caseId);
  if (!st.el) return;
  const tops = (st.comments || []).filter(c => !c.parent_id);
  const items = tops.length
    ? tops.map(c => _csCommentItemHtml(caseId, c, false) +
        (st.comments || []).filter(r => r.parent_id === c.id).map(r => _csCommentItemHtml(caseId, r, true)).join('')).join('')
    : '<div class="cs-memo-empty">아직 메모가 없습니다.</div>';
  st.el.innerHTML = `<div class="cs-memo-list">${items}</div>${st.opts.purged ? '' : _csCommentFormHtml(caseId)}`;
}

function _csCommentItemHtml(caseId, c, isReply) {
  const st = _csCs(caseId);
  const me = (typeof currentUser !== 'undefined' && currentUser) ? currentUser.id : null;
  const mine = !!me && c.author_id === me;
  const isNew = !!st.reads && !mine && !c.deleted_at && !st.reads.has(c.id);
  const who = c.origin === 'sheet' ? '시트 이관' : (c.author_name || '이름 없음');
  const acts = (c.deleted_at || st.opts.purged) ? '' : [
    (!isReply) ? `<button type="button" class="btn btn-ghost btn-xs" onclick="csCommentReply(${jsStr(caseId)},${jsStr(c.id)})">댓글</button>` : '',
    (mine && c.origin !== 'sheet') ? `<button type="button" class="btn btn-ghost btn-xs" onclick="csCommentDelete(${jsStr(caseId)},${jsStr(c.id)})">삭제</button>` : ''
  ].join('');
  const body = c.deleted_at
    ? '<div class="cs-memo-deleted">지운 메모입니다.</div>'
    : `${c.body ? `<div class="cs-memo-text">${esc(c.body)}</div>` : ''}
       ${(c.translate_status === 'done' && c.translated) ? `<div class="cs-memo-trans"><span class="cs-memo-trans-tag">${c.translated_lang === 'ja' ? '일본어 번역' : '한국어 번역'}</span>${esc(c.translated)}</div>` : ''}
       ${st.opts.purged ? '' : _csCommentAttachHtml(c)}`;
  return `<div class="cs-memo-item${isReply ? ' cs-memo-reply' : ''}" data-cs-comment="${esc(c.id)}">
    <div class="cs-memo-meta"><span class="cs-memo-author">${esc(who)}</span>
      <span>${esc(formatDateTime(c.created_at))}</span>${isNew ? '<span class="cs-memo-new">새</span>' : ''}
      <span class="cs-memo-acts">${acts}</span></div>${body}</div>`;
}

function _csCommentAttachHtml(c) {
  const atts = Array.isArray(c.attachments) ? c.attachments : [];
  if (!atts.length) return '';
  return `<div class="cs-memo-atts">${atts.map(a => a && a.path
    ? `<button type="button" class="cs-memo-att" data-cs-att="${esc(a.path)}" aria-label="${esc(a.name || '첨부 이미지')} 크게 보기"></button>` : '').join('')}</div>`;
}

// 서명 주소는 5분 — 그린 뒤 한 번에 받아 칸마다 붙인다
async function _csHydrateCommentImages(caseId) {
  const st = _csCs(caseId);
  if (!st.el || st.opts.purged) return;
  const btns = Array.from(st.el.querySelectorAll('[data-cs-att]'));
  if (!btns.length) return;
  const urls = await signCsCommentAttachments(btns.map(b => b.getAttribute('data-cs-att')));
  btns.forEach(b => {
    const u = urls[b.getAttribute('data-cs-att')];
    if (!u) { b.textContent = '이미지를 열 수 없음'; return; }
    b.innerHTML = `<img src="${esc(u)}" alt="">`;
    b.onclick = () => openImageLightbox(u);
  });
}

function _csCommentFormHtml(caseId) {
  const st = _csCs(caseId);
  const replying = !!st.replyTo;
  const files = st.files || [];
  return `<div class="cs-memo-form">
    ${replying ? `<div class="cs-memo-replyline">${esc(st.replyName || '')}님 메모에 댓글 · <button type="button" class="btn btn-ghost btn-xs" onclick="csCommentCancelReply(${jsStr(caseId)})">취소</button></div>` : ''}
    <textarea class="form-input cs-memo-input" rows="2" placeholder="${replying ? '댓글 입력…' : '메모 입력…'}"
      oninput="_csCs(${jsStr(caseId)}).draft=this.value">${esc(st.draft || '')}</textarea>
    <div class="cs-memo-form-acts">
      <label class="btn btn-ghost btn-xs cs-memo-file"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">image</span>
        이미지${files.length ? ` ${files.length}` : ''}
        <input type="file" accept="image/*" multiple hidden onchange="csCommentPickFiles(${jsStr(caseId)},this)"></label>
      <button type="button" class="btn btn-primary btn-sm" onclick="csCommentSubmit(${jsStr(caseId)})"${st.busy ? ' disabled' : ''}>남기기</button>
    </div></div>`;
}

function csCommentReply(caseId, parentId) {
  const st = _csCs(caseId);
  const p = (st.comments || []).find(c => c.id === parentId);
  st.replyTo = parentId;
  st.replyName = p ? (p.origin === 'sheet' ? '시트 이관' : (p.author_name || '이름 없음')) : '';
  _csRenderComments(caseId);
  _csHydrateCommentImages(caseId);
  const inp = st.el && st.el.querySelector('.cs-memo-input');
  if (inp) inp.focus();
}
// 취소하면 쓰던 글도 지운다(D-11)
function csCommentCancelReply(caseId) {
  const st = _csCs(caseId);
  st.replyTo = null; st.replyName = ''; st.draft = ''; st.files = [];
  _csRenderComments(caseId);
  _csHydrateCommentImages(caseId);
}

function csCommentPickFiles(caseId, input) {
  const st = _csCs(caseId);
  const picked = Array.from((input && input.files) || []);
  const all = (st.files || []).concat(picked);
  if (all.length > CS_COMMENT_MAX_FILES) toast(`이미지는 ${CS_COMMENT_MAX_FILES}장까지 붙일 수 있습니다`, 'error');
  st.files = all.slice(0, CS_COMMENT_MAX_FILES);
  _csRenderComments(caseId);
  _csHydrateCommentImages(caseId);
}

// 파일을 먼저 올리고(실패하면 멈춤) 메모를 쓴다. ⚠️ 메모 쓰기가 실패하면 올린 파일은 통에 남는다(지우기 정책 없음 — 파기 함수 몫)
async function csCommentSubmit(caseId) {
  const st = _csCs(caseId);
  if (st.busy) return;
  const body = (st.draft || '').trim();
  if (!body && !(st.files || []).length) { toast(CS_ERROR_TEXT_KO.comment_empty, 'error'); return; }
  st.busy = true; _csRenderComments(caseId);
  try {
    const atts = [];
    for (const f of (st.files || [])) atts.push(await uploadCsCommentAttachment(f, caseId));
    await csAddComment(caseId, body, st.replyTo || null, atts);
    st.draft = ''; st.files = []; st.replyTo = null; st.replyName = '';
    st.busy = false;
    await csMountComments(caseId, st.el, { ...st.opts, markRead: false });
    if (typeof st.opts.onChanged === 'function') st.opts.onChanged();
  } catch (e) {
    st.busy = false; _csRenderComments(caseId); _csHydrateCommentImages(caseId);
    toast(csErrorText(e), 'error');
  }
}

async function csCommentDelete(caseId, commentId) {
  const ok = await showConfirm('이 메모를 지울까요? 지운 메모는 「지운 메모입니다」로 남습니다.');
  if (!ok) return;
  const st = _csCs(caseId);
  try {
    await csDeleteComment(commentId);
    await csMountComments(caseId, st.el, { ...st.opts, markRead: false });
    if (typeof st.opts.onChanged === 'function') st.opts.onChanged();
  } catch (e) { toast(csErrorText(e), 'error'); }
}
