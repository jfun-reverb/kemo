// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-lookups.js
// ═════════════════════════════════════════════════════════════════
//
// 기준 데이터(lookup_values) + 번들 3종 관리 페인 (admin.js 파일 분리, 마지막 단계).
//   · 기준데이터 페인 로드/탭/테이블 + 재정렬/추가/편집/삭제 (loadLookupsPane/switchLookupTab/renderLookupsTable/saveLookupEdit 등)
//   · 참여방법 번들 (renderPsetTable/savePsetEdit 등) — 변수 _psetCurrentSteps/MAX_PSET_STEPS/RECRUIT_TYPES_ALL
//   · 주의사항 번들 + 미니 에디터 17종 (renderCsetTable/saveCsetEdit/miniEditorHtml/openMiniEditorLinkPopover 등) — _csetCurrentItems/MAX_CSET_ITEMS
//   · NG 번들 (renderNgSetTable/saveNgSetEdit 등) — _nsetCurrentItems/MAX_NSET_ITEMS
//
// ⚠ loadLookupsPane 는 switchAdminPane(admin-core.js) loaders 가 호출 → 전역 유지(이름 변경 금지).
// ⚠ 캠페인폼(admin.js 잔류)이 MAX_*_STEPS·미니에디터(miniEditorHtml 등)를 함수 본문에서 참조,
//   이 파일 함수가 캠페인폼 변수(_psetState/isNgItemEmpty 등)를 함수 본문에서 참조 — 양방향 실행시점이라 안전.
//   빌드 순서상 이 파일은 admin.js 보다 앞.
// ⚠ 캠페인폼 소속(잔류): _formCfg / _psetState / _psetCache / _csetState / _nsetState / 폼가시성 함수.
// ═════════════════════════════════════════════════════════════════

// ══════════════════════════════════════
// 기준 데이터 (lookup_values) 관리
// ══════════════════════════════════════
const LOOKUP_KIND_LABEL_KO = {channel:'채널', category:'카테고리', content_type:'콘텐츠 종류', ng_set:'NG 사항', participation_set:'참여방법', reject_reason:'반려사유', caution:'주의사항', quote_settings:'견적 기준값'};
let _currentLookupKind = 'channel';

// ════════════════════════════════════════════════════════════════════
// SECTION: LOOKUPS — 기준 데이터 페인 로드 + 탭 + 테이블
// ════════════════════════════════════════════════════════════════════

async function loadLookupsPane() {
  applyLookupMenuVisibility();
  if (!isCampaignAdminOrAbove()) {
    const tbody = $('lookupsTableBody');
    if (tbody) tbody.innerHTML = '<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">권한이 없습니다 (campaign_admin 이상)</td></tr>';
    return;
  }
  await renderLookupsTable();
  // 채널 어긋남 경고 버튼 갱신 — 여기가 **원인을 만드는 자리**다(채널 코드를 지우거나
  //   바꾸는 화면). 결과물 관리와 같은 함수를 쓴다. 0건이면 버튼째 숨긴다.
  if (typeof refreshChannelDriftIndicators === 'function') {
    refreshChannelDriftIndicators();
  }
}

// ════════════════════════════════════════════════════════════════════

function switchLookupTab(kind, btn) {
  _currentLookupKind = kind;
  // 탭 전환 시 reorder 모드 자동 종료
  if (_lookupReorderMode) {
    _lookupReorderMode = false;
    const rb = $('btnLookupReorderMode');
    if (rb) { rb.textContent = '순서 변경'; rb.onclick = enterLookupReorderMode; rb.classList.remove('btn-primary'); rb.classList.add('btn-ghost'); }
  }
  document.querySelectorAll('.lookup-tab').forEach(b => {
    b.style.color = 'var(--muted)';
    b.style.borderBottomColor = 'transparent';
    b.style.fontWeight = '600';
  });
  if (btn) {
    btn.style.color = 'var(--accent-ink)';
    btn.style.borderBottomColor = 'var(--accent)';
    btn.style.fontWeight = '700';
  }
  renderLookupsTable();
}

async function renderLookupsTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  const title = $('lookupTableTitle');
  if (!tbody) return;
  if (title) title.textContent = LOOKUP_KIND_LABEL_KO[_currentLookupKind] + ' 목록';
  { const rb = $('btnLookupReorderMode'); if (rb) rb.style.display = ''; }   // 기본은 보임 — 견적 기준값 탭만 자기 함수 안에서 감춘다(조기 반환보다 앞에 둬야 참여방법·주의사항·NG 탭으로 돌아갈 때도 되살아난다)
  if (_currentLookupKind === 'participation_set') { await renderPsetTable(); return; }
  if (_currentLookupKind === 'caution') { await renderCsetTable(); return; }
  if (_currentLookupKind === 'ng_set') { await renderNgSetTable(); return; }
  if (_currentLookupKind === 'quote_settings') { await renderQuoteSettingsTable(); return; }
  const isChannel = _currentLookupKind === 'channel';
  const showRt = isChannel || _currentLookupKind === 'reject_reason';
  // 헤더 렌더
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>한국어 명칭</th>
      <th>일본어 명칭</th>
      ${showRt ? '<th style="width:140px">모집 타입</th>' : ''}
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = 5 + (showRt ? 1 : 0);
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try {
    rows = await fetchLookupsAll(_currentLookupKind);
  } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(friendlyError(e.message||String(e)))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 항목이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const rts = r.recruit_types || [];
    const rtCell = showRt
      ? `<td><div style="display:flex;gap:3px;flex-wrap:wrap">${
          rts.length
            ? rts.map(t => {
                const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
                return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
              }).join('')
            : `<span class="badge badge-gray" style="font-size:9px;padding:1px 6px">공통</span>`
        }</div></td>`
      : '';
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong></td>
      <td style="color:var(--ink);font-size:13px">${esc(r.name_ja)}</td>
      ${rtCell}
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openLookupEditModal(${esc(JSON.stringify(r))})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:var(--red-d)" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: 견적 기준값 탭 (마이그레이션 426 · 오리엔시트 단순화 2단계 사양서 §4-5)
//   같은 표(#lookupsTableBody)에 그린다 — 카드를 더 넣지 않는다(작업표 stale ⑥).
//   수정은 캠페인 관리자 이상(서버 가드 is_campaign_admin — 화면은 단추만 감춘다).
//   🔴 fetchQuoteSettings 는 실패 null / 0건 [] — 합치면 「환율 0」 화면이 된다.
// ════════════════════════════════════════════════════════════════════
function quoteAmountText(r) {
  const n = Number(r.amount);
  if (r.unit === 'rate') return (n * 100).toLocaleString('ko-KR', { maximumFractionDigits: 2 }) + ' %';
  if (r.unit === 'jpy') return '¥' + n.toLocaleString('ja-JP');
  // 🔴 구간 인원(reviewer_tier_slots_*·seeding_tier_slots_*)은 금액이 아니다 — 이 분기가 없으면 아래 기본으로 떨어져 「50 원」으로 그려진다
  if (r.unit === 'count') return n.toLocaleString('ko-KR') + ' 건';
  return n.toLocaleString('ko-KR') + ' 원';
}
// ── 견적 기준값 화면 — 형식별 구간표(2026-09-21 사용자 결정) ──
//   예전에는 45행을 한 줄 목록으로 그려 「스탠다드는 몇 명부터, 모집비 얼마」를 알려면 위아래 묶음을 오가야 했다.
//   이제 **공통 · 리뷰어 · 시딩** 카드 셋으로, 카드 안에서 구간이 줄이고 시작 인원·인원 범위·비용이 칸이다.
//   🔴 **값과 저장 경로는 그대로**다 — 입력칸(늘 보임)을 고치면 나오는 「저장」(또는 Enter) → quoteInputSave → saveQuoteSetting(update_quote_setting).
//   🔴 **어느 카드에도 안 들어간 행은 맨 아래 「그 밖의 기준값」에 그대로 그린다** — 새 기준값 행이 생겼는데
//      이 배치표에 안 넣으면 화면에서 조용히 사라진다(고칠 길이 없어진다).
const QUOTE_TIER_KEYS = ['tmin', 't50', 't100', 't300', 't500plus'];
const QUOTE_TIER_NAME = { tmin: '소량', t50: '라이트', t100: '스탠다드', t300: '프리미엄', t500plus: '실검작업' };
// 시딩 단가 시드는 가짜 값(99001~99025, 442·458) — 이 범위면 「미입력」으로 눈에 띄게 그린다.
//   ⚠️ 판정은 **시딩 단가 행에만** 건다(다른 행에 우연히 이 숫자가 들어가도 경고하지 않게).
const QUOTE_SEED_PLACEHOLDER = { min: 99000, max: 99999 };
function quoteIsPlaceholder(r) {
  if (!r || !/^seeding_fee_krw_/.test(r.key)) return false;
  const n = Number(r.amount);
  return n >= QUOTE_SEED_PLACEHOLDER.min && n <= QUOTE_SEED_PLACEHOLDER.max;
}
// 값 칸 하나 — 편집 권한이 있으면 **처음부터 입력칸**으로 그린다(2026-09-21 사용자 지시 — 눌러야 입력칸이
//   나오면 고칠 수 있는 자리인지 안 보인다). 값을 고치면 그 칸 옆에 「저장」·「취소」가 나타나고,
//   **저장 버튼(또는 Enter)을 눌러야 저장**된다(같은 날 사용자 지시 — 칸만 옮겨도 저장되면 의도치 않게 바뀐다).
//   권한이 없으면 글자만.
const QUOTE_INPUT_UNIT = { krw: '원', jpy: '엔', rate: '%', count: '명' };
function quoteInputValue(r) {
  const n = Number(r.amount);
  return r.unit === 'rate' ? String(Math.round(n * 10000) / 100) : String(n);
}
function quoteCell(byKey, key, opts) {
  const r = byKey[key];
  if (!r) return '<td class="q-cell q-missing" title="기준값 행이 없습니다">—</td>';
  byKey.__used.add(key);
  const ph = quoteIsPlaceholder(r);
  const tip = (r.label_ko || '') + (r.updated_at ? ' · 마지막 수정 ' + formatDateTime(r.updated_at) : '');
  const tag = ph ? '<span class="q-ph-tag">미입력</span>' : '';
  if (opts && opts.canEdit) {
    const v = quoteInputValue(r);
    const isRate = r.unit === 'rate';
    return `<td class="q-cell q-amount" data-qkey="${esc(r.key)}" title="${esc(tip)}"><div class="q-in-wrap${ph ? ' is-ph' : ''}">
      <input type="number" class="q-input" data-qkey="${esc(r.key)}" data-unit="${esc(r.unit)}" data-orig="${esc(v)}" value="${esc(v)}"
        step="${isRate ? '0.01' : '1'}" min="${r.unit === 'count' ? '1' : '0'}"${isRate ? ' max="100"' : ''}
        oninput="quoteInputDirty(this)" onkeydown="quoteInputKey(event, this)">
      <span class="q-unit">${esc(QUOTE_INPUT_UNIT[r.unit] || '')}</span>${tag}
      <span class="q-act" hidden><button type="button" class="btn btn-primary btn-xs" onclick="quoteInputSave(this)">저장</button><button type="button" class="btn btn-ghost btn-xs" onclick="quoteInputCancel(this)">취소</button></span></div></td>`;
  }
  const text = r.unit === 'count' ? Number(r.amount).toLocaleString('ko-KR') + '명' : quoteAmountText(r);
  return `<td class="q-cell q-amount" data-qkey="${esc(r.key)}" title="${esc(tip)}"><span class="q-val-ro${ph ? ' is-ph' : ''}">${esc(text)}${tag}</span></td>`;
}
// 값이 원래와 달라지면 그 칸의 「저장」·「취소」를 보인다(같아지면 다시 감춘다)
function quoteInputDirty(input) {
  const wrap = input && input.closest('.q-in-wrap'); if (!wrap) return;
  const dirty = input.value !== input.dataset.orig;
  wrap.classList.toggle('is-dirty', dirty);
  const act = wrap.querySelector('.q-act'); if (act) act.hidden = !dirty;
}
// Enter = 저장, Escape = 원래 값으로 되돌리기
function quoteInputKey(e, input) {
  if (e.key === 'Enter') { e.preventDefault(); quoteInputSave(input); }
  else if (e.key === 'Escape') { e.preventDefault(); input.value = input.dataset.orig; quoteInputDirty(input); }
}
function quoteInputOf(el) {
  if (el && el.classList && el.classList.contains('q-input')) return el;
  const wrap = el && el.closest('.q-in-wrap');
  return wrap ? wrap.querySelector('.q-input') : null;
}
function quoteInputCancel(el) {
  const input = quoteInputOf(el); if (!input) return;
  input.value = input.dataset.orig; quoteInputDirty(input);
}
// 저장 — 값이 바뀌었을 때만. 실패하면 **친 값을 그대로 둔다**(안내를 보고 고쳐 다시 저장할 수 있게).
//   저장되면 표를 다시 그리는데(범위 글이 따라 바뀐다), 다른 칸에 고치던 값은 그대로 남는다.
async function quoteInputSave(el) {
  const input = quoteInputOf(el); if (!input) return;
  if (input.value === input.dataset.orig) { quoteInputDirty(input); return; }
  const wrap = input.closest('.q-in-wrap');
  const btns = wrap ? wrap.querySelectorAll('.q-act button') : [];
  btns.forEach(b => { b.disabled = true; });   // 두 번 눌러 두 번 저장되지 않게
  const ok = await saveQuoteSetting(input.dataset.qkey, input, input.dataset.unit);
  if (!ok) btns.forEach(b => { b.disabled = false; });
}
// 인원 범위 글 — 「그 구간의 시작 인원 ~ 다음 구간 시작 - 1」. 기준값이 비면 「—」(기본값으로 채우지 않는다).
function quoteTierRanges(byKey, prefix) {
  const v = k => { const r = byKey[prefix + k]; const n = r ? Number(r.amount) : NaN; return isFinite(n) ? n : null; };
  const starts = { tmin: v('min_slots'), t50: v('slots_t50'), t100: v('slots_t100'), t300: v('slots_t300'), t500plus: v('slots_t500plus') };
  const out = {};
  QUOTE_TIER_KEYS.forEach((t, i) => {
    const a = starts[t];
    const next = QUOTE_TIER_KEYS[i + 1] ? starts[QUOTE_TIER_KEYS[i + 1]] : null;
    if (a === null) { out[t] = '—'; return; }
    if (!QUOTE_TIER_KEYS[i + 1]) { out[t] = a.toLocaleString('ko-KR') + '명 이상'; return; }
    if (next === null) { out[t] = '—'; return; }
    out[t] = next - 1 < a ? '쓰이지 않음' : a.toLocaleString('ko-KR') + '~' + (next - 1).toLocaleString('ko-KR') + '명';
  });
  return out;
}
function quoteCard(title, sub, inner) {
  return `<section class="q-card"><div class="q-card-head"><span class="q-card-title">${esc(title)}</span>${sub ? `<span class="q-card-sub">${esc(sub)}</span>` : ''}</div>${inner}</section>`;
}
function quoteCommonCard(byKey, o) {
  return quoteCard('공통', '리뷰어·시딩 견적 모두에 쓰입니다', `<table class="q-table q-kv"><tbody>
    <tr><th>엔→원 환율 (1엔당)</th>${quoteCell(byKey, 'exchange_rate_krw_per_jpy', o)}</tr>
    <tr><th>부가세율</th>${quoteCell(byKey, 'vat_rate', o)}</tr>
  </tbody></table>`);
}
function quoteReviewerCard(byKey, o) {
  const rg = quoteTierRanges(byKey, 'reviewer_tier_');
  const rows = QUOTE_TIER_KEYS.map(t => `<tr>
      <th>${QUOTE_TIER_NAME[t]}</th>
      ${t === 'tmin' ? quoteCell(byKey, 'reviewer_tier_min_slots', o) : quoteCell(byKey, 'reviewer_tier_slots_' + t, o)}
      <td class="q-range">${esc(rg[t])}</td>
      ${quoteCell(byKey, 'reviewer_recruit_fee_krw_' + t, o)}
    </tr>`).join('');
  return quoteCard('리뷰어', '구간은 모집 인원으로 정해집니다 — 시작 인원을 고치면 아래 범위가 함께 바뀝니다', `
    <table class="q-table q-tier"><thead><tr><th>구간</th><th>시작 인원</th><th>인원 범위</th><th>모집비 (1건당)</th></tr></thead><tbody>${rows}</tbody></table>
    <p class="q-note">「소량」의 시작 인원 = <strong>최소 모집 인원</strong>입니다. 이보다 적으면 접수하지 않습니다.</p>
    <table class="q-table q-kv"><tbody>
      <tr><th>해외 송금 수수료 (1건당)</th>${quoteCell(byKey, 'reviewer_transfer_fee_krw', o)}</tr>
      <tr><th>추가 옵션 — LIPS (1건당)</th>${quoteCell(byKey, 'reviewer_option_fee_krw_lips', o)}</tr>
      <tr><th>추가 옵션 — @cosme (1건당)</th>${quoteCell(byKey, 'reviewer_option_fee_krw_cosme', o)}</tr>
    </tbody></table>`);
}
function quoteSeedingCard(byKey, o) {
  const rg = quoteTierRanges(byKey, 'seeding_tier_');
  const chs = (typeof OS_SEEDING_CHANNELS !== 'undefined') ? OS_SEEDING_CHANNELS : ['instagram_feed', 'instagram_reels', 'x', 'tiktok', 'youtube'];
  const chName = c => (typeof osChLabel === 'function') ? osChLabel(c) : c;
  const head = `<tr><th>구간</th><th>시작 인원</th><th>인원 범위</th>${chs.map(c => `<th>${esc(chName(c))}</th>`).join('')}</tr>`;
  const rows = QUOTE_TIER_KEYS.map(t => `<tr>
      <th>${QUOTE_TIER_NAME[t]}</th>
      ${t === 'tmin' ? quoteCell(byKey, 'seeding_tier_min_slots', o) : quoteCell(byKey, 'seeding_tier_slots_' + t, o)}
      <td class="q-range">${esc(rg[t])}</td>
      ${chs.map(c => quoteCell(byKey, 'seeding_fee_krw_' + c + '_' + t, o)).join('')}
    </tr>`).join('');
  const phCount = Object.keys(byKey).filter(k => k !== '__used' && quoteIsPlaceholder(byKey[k])).length;
  const warn = phCount ? `<div class="q-warn"><span class="material-icons-round" translate="no">warning</span>진행비 ${phCount}칸이 아직 가짜 값(99,0xx원)입니다 — 실제 금액을 넣어야 시딩 견적이 맞게 나갑니다.</div>` : '';
  return quoteCard('시딩', '진행비는 채널 × 구간 1건당 금액입니다', `${warn}
    <div class="q-scroll"><table class="q-table q-tier q-wide"><thead>${head}</thead><tbody>${rows}</tbody></table></div>
    <p class="q-note">「소량」의 시작 인원 = <strong>최소 모집 인원</strong>입니다. 구간 인원을 바꾸면 그 구간 진행비가 가리키는 사람 수도 바뀌니 함께 확인해 주세요.</p>`);
}
function quoteRestCard(byKey, rows, o) {
  const rest = rows.filter(r => !byKey.__used.has(r.key));
  if (!rest.length) return '';
  return quoteCard('그 밖의 기준값', '위 표에 자리가 없는 항목입니다', `<table class="q-table q-kv"><tbody>${
    rest.map(r => `<tr><th>${esc(r.label_ko || r.key)}</th>${quoteCell(byKey, r.key, o)}</tr>`).join('')}</tbody></table>`);
}
async function renderQuoteSettingsTable() {
  const tbody = $('lookupsTableBody');
  const rb = $('btnLookupReorderMode'); if (rb) rb.style.display = 'none';   // 기준값은 순서가 고정
  const thead = $('lookupTableHead');
  const title = $('lookupTableTitle');
  if (title) title.textContent = '견적 기준값';
  const canEdit = typeof isCampaignAdminOrAbove === 'function' && isCampaignAdminOrAbove();
  if (thead) thead.innerHTML = '';   // 카드 배치라 표 머리가 없다 — 다른 탭은 저마다 머리를 다시 그린다
  const wrap = inner => `<tr class="q-wrap-row"><td colspan="6" style="padding:0">${inner}</td></tr>`;
  // 저장 뒤 다시 그릴 때 보던 자리를 지킨다 — 안 그러면 시딩 칸을 고칠 때마다 맨 위로 튄다
  const scroller = tbody.closest('.admin-table-wrap');
  const keepTop = scroller ? scroller.scrollTop : 0;
  // 이미 표가 떠 있으면(저장 뒤 다시 그리기) 스피너로 비우지 않는다 — 비우면 치던 칸의 초점이 끊기고 화면이 깜빡인다
  if (!tbody.querySelector('.q-board')) tbody.innerHTML = wrap(`<div style="text-align:center;padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></div>`);
  const rows = await fetchQuoteSettings();
  if (rows === null) {
    tbody.innerHTML = wrap('<div style="text-align:center;color:var(--red);padding:24px">견적 기준값을 불러오지 못했습니다. 새로고침해 주세요.</div>');
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = wrap('<div style="text-align:center;color:var(--muted);padding:24px">등록된 기준값이 없습니다 (마이그레이션 426 적용 필요)</div>');
    return;
  }
  const byKey = { __used: new Set() };
  rows.forEach(r => { byKey[r.key] = r; });
  const o = { canEdit };
  // ⚠️ 「그 밖의 기준값」(quoteRestCard)은 **반드시 마지막** — 앞 카드들이 그린 칸을 byKey.__used 에 적어 두고,
  //    남은 것만 그린다. 순서를 바꾸면 이미 그린 행이 한 번 더 나온다.
  const html = quoteCommonCard(byKey, o) + quoteReviewerCard(byKey, o) + quoteSeedingCard(byKey, o) + quoteRestCard(byKey, rows, o);
  // ⚠️ 아래 둘은 **조회가 끝난 뒤, 그리기 직전**에 잡는다 — 조회 중에도 사용자는 계속 칠 수 있다.
  // 저장 → 다시 그리기 사이에 사용자가 다음 칸으로 옮겨 가 있을 수 있다 — 그 칸에 초점을 돌려준다
  const focusKey = document.activeElement && document.activeElement.classList && document.activeElement.classList.contains('q-input')
    ? document.activeElement.dataset.qkey : null;
  // 🔴 아직 확정 안 한 입력을 지킨다 — 앞 칸 저장이 끝나 다시 그릴 때, 그사이 다른 칸에 치던 숫자가
  //    서버 값으로 덮여 조용히 사라진다(여러 칸을 연달아 채울 때 실제로 겪는다). 바뀐 칸만 모아 뒤에 되돌린다.
  const pending = {};
  tbody.querySelectorAll('.q-input').forEach(el => { if (el.value !== el.dataset.orig) pending[el.dataset.qkey] = el.value; });
  tbody.innerHTML = wrap(`<div class="q-board">${canEdit ? '' : '<p class="q-note">보기 전용입니다 — 수정은 캠페인 관리자 이상.</p>'}${html}</div>`);
  if (scroller) scroller.scrollTop = keepTop;
  Object.keys(pending).forEach(k => {
    const el = tbody.querySelector(`.q-input[data-qkey="${CSS.escape(k)}"]`);
    if (el) { el.value = pending[k]; quoteInputDirty(el); }   // data-orig 는 새 서버 값 — 「저장」을 누르면 그 차이로 저장된다
  });
  if (focusKey) {
    const el = tbody.querySelector(`.q-input[data-qkey="${CSS.escape(focusKey)}"]`);
    if (el) { el.focus({ preventScroll: true }); if (!(focusKey in pending)) el.select(); }
  }
}
async function saveQuoteSetting(key, input, unit) {
  const raw = Number(input && input.value);
  if (!Number.isFinite(raw) || raw < 0) { toast('0 이상의 숫자를 입력해 주세요.'); return false; }
  // 🔴 인원은 0·소수가 될 수 없다 — 0 이면 「0건 단추」가 생기고, 소수면 단추에 「50.5건」이 뜬다.
  //    금액(0 원이 정상인 행이 있다)과 다르므로 이 단위에서만 막는다. 서버(454)가 최종 방어선.
  if (unit === 'count' && (raw < 1 || !Number.isInteger(raw))) { toast('구간 인원은 1 이상의 정수여야 합니다.'); return false; }
  const amount = unit === 'rate' ? raw / 100 : raw;
  if (unit === 'rate' && amount > 1) { toast('비율은 100% 를 넘을 수 없습니다.'); return false; }
  try {
    const res = await updateQuoteSetting(key, amount);
    if (!res || res.success !== true) {
      // 🔴 tier_slots_not_ascending 은 서버가 돌려주는 코드와 **글자가 같아야** 한다 —
      //    검사에는 최소 인원(`reviewer_tier_min_slots`·`seeding_tier_min_slots`)이 들어간다.
      //    네 이름만 적으면 「최소 인원을 라이트보다 크게」 넣었을 때 왜 막혔는지 알 수 없다.
      //    구간 인원이 오름차순이 아니면 단추와 판정이 말없이 어긋나 틀린 금액이 견적서에 찍힌다.
      // ⚠️ 2026-09-21 부터 구간 인원이 리뷰어·시딩 따로라 서버가 어느 쪽인지(`form_type`)를 함께 준다.
      //    옛 서버라 없으면 앞머리 없이 종전 문구 그대로.
      const tierWho = ({ reviewer: '리뷰어 구간 ', seeding: '시딩 구간 ' })[res && res.form_type] || '';
      const why = ({ forbidden: '권한이 없습니다 (캠페인 관리자 이상)', invalid_amount: '값이 올바르지 않습니다', unknown_key: '없는 항목입니다',
                     tier_slots_not_ascending: tierWho + '인원은 최소 인원 ≤ 라이트 < 스탠다드 < 프리미엄 < 실검작업 구간 순이어야 합니다' })[res && res.reason] || (res && res.reason) || '저장 실패';
      toast('저장 실패: ' + why); return false;
    }
    toast('저장되었습니다. 이후 제출되는 오리엔시트 견적부터 적용됩니다.');
    await refreshPane('lookups');
    return true;
  } catch (e) {
    toast(typeof friendlyError === 'function' ? friendlyError(e) : '저장에 실패했습니다.');
    return false;
  }
}

const RECRUIT_TYPE_LABEL_KO = {monitor:'리뷰어', gifting:'기프팅', visit:'방문형'};
let _lookupReorderMode = false;
// ════════════════════════════════════════════════════════════════════
// SECTION: LOOKUPS — 재정렬 모드 + 추가/편집 모달 + 삭제/토글
// ════════════════════════════════════════════════════════════════════

function enterLookupReorderMode() {
  _lookupReorderMode = true;
  const btn = $('btnLookupReorderMode');
  if (btn) { btn.textContent = '순서 변경 완료'; btn.onclick = exitLookupReorderMode; btn.classList.add('btn-primary'); btn.classList.remove('btn-ghost'); }
  renderLookupsTable();
}
function exitLookupReorderMode() {
  _lookupReorderMode = false;
  const btn = $('btnLookupReorderMode');
  if (btn) { btn.textContent = '순서 변경'; btn.onclick = enterLookupReorderMode; btn.classList.remove('btn-primary'); btn.classList.add('btn-ghost'); }
  renderLookupsTable();
}

function applyLookupModalKindUI(kind, recruitTypes) {
  // 채널·반려사유 탭에서 모집 타입 선택 표시 (반려사유: 빈 배열=공통)
  const grp = $('lookupRecruitTypesGroup');
  if (grp) grp.style.display = (kind === 'channel' || kind === 'reject_reason') ? '' : 'none';
  // 체크박스 상태 초기화
  const set = new Set(recruitTypes || []);
  document.querySelectorAll('input[name="lookupRT"]').forEach(cb => {
    cb.checked = set.has(cb.value);
  });
}

function openLookupAddModal() {
  if (_currentLookupKind === 'quote_settings') { toast('견적 기준값은 항목을 추가하지 않습니다. 값만 수정할 수 있어요.'); return; }
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  if (_currentLookupKind === 'participation_set') { openPsetAddModal(); return; }
  if (_currentLookupKind === 'caution') { openCsetAddModal(); return; }
  if (_currentLookupKind === 'ng_set') { openNgSetAddModal(); return; }
  $('lookupModalTitle').textContent = LOOKUP_KIND_LABEL_KO[_currentLookupKind] + ' 추가';
  $('lookupEditId').value = '';
  $('lookupEditKind').value = _currentLookupKind;
  $('lookupNameKo').value = '';
  $('lookupNameJa').value = '';
  $('lookupCode').value = '';
  $('lookupEditError').style.display = 'none';
  // 신규 추가 시 채널이면 기본값으로 3개 모두 체크
  applyLookupModalKindUI(_currentLookupKind, ['monitor','gifting','visit']);
  openModal('lookupEditModal');
}

function openLookupEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  if (_currentLookupKind === 'participation_set') { openPsetEditModal(row); return; }
  if (_currentLookupKind === 'caution') { openCsetEditModal(row); return; }
  if (_currentLookupKind === 'ng_set') { openNgSetEditModal(row); return; }
  $('lookupModalTitle').textContent = LOOKUP_KIND_LABEL_KO[row.kind] + ' 편집';
  $('lookupEditId').value = row.id;
  $('lookupEditKind').value = row.kind;
  $('lookupNameKo').value = row.name_ko || '';
  $('lookupNameJa').value = row.name_ja || '';
  $('lookupCode').value = row.code || '';
  $('lookupEditError').style.display = 'none';
  applyLookupModalKindUI(row.kind, row.recruit_types || []);
  openModal('lookupEditModal');
}

async function saveLookupEdit() {
  const id = $('lookupEditId').value;
  const kind = $('lookupEditKind').value;
  const name_ko = $('lookupNameKo').value.trim();
  const name_ja = $('lookupNameJa').value.trim();
  const code = $('lookupCode').value.trim();
  const err = $('lookupEditError');
  if (!name_ko || !name_ja) {
    err.textContent = '한국어/일본어 명칭은 필수입니다';
    err.style.display = 'block';
    return;
  }
  // 채널이면 모집 조건 1개 이상 필수. 반려사유는 선택(빈 배열=공통)
  let recruitTypes = null;
  if (kind === 'channel' || kind === 'reject_reason') {
    recruitTypes = Array.from(document.querySelectorAll('input[name="lookupRT"]:checked')).map(cb => cb.value);
    if (kind === 'channel' && recruitTypes.length === 0) {
      err.textContent = '모집 타입을 1개 이상 선택해주세요';
      err.style.display = 'block';
      return;
    }
  }
  try {
    if (id) {
      const updates = {name_ko, name_ja};
      if (code) updates.code = code;
      if (recruitTypes) updates.recruit_types = recruitTypes;
      await updateLookup(id, updates);
      toast('수정했습니다','success');
    } else {
      const payload = {kind, name_ko, name_ja, code};
      if (recruitTypes) payload.recruit_types = recruitTypes;
      await insertLookup(payload);
      toast('추가했습니다','success');
    }
    closeModal('lookupEditModal');
    renderLookupsTable();
  } catch(e) {
    err.textContent = '저장 실패: ' + (e.message || String(e));
    err.style.display = 'block';
  }
}

async function moveLookup(idA, idB) {
  if (!idA || !idB) return;
  try {
    if (_currentLookupKind === 'participation_set') await swapParticipationSetOrder(idA, idB);
    else if (_currentLookupKind === 'caution') await swapCautionSetOrder(idA, idB);
    else if (_currentLookupKind === 'ng_set') await swapNgSetOrder(idA, idB);
    else await swapLookupOrder(idA, idB);
    renderLookupsTable();
  } catch(e) {
    toast('정렬 변경 실패: ' + friendlyError(e.message||String(e)),'error');
  }
}

async function toggleLookupActive(id, nextActive) {
  try {
    if (_currentLookupKind === 'participation_set') {
      if (nextActive) await activateParticipationSet(id); else await deactivateParticipationSet(id);
    } else if (_currentLookupKind === 'caution') {
      if (nextActive) await activateCautionSet(id); else await deactivateCautionSet(id);
    } else if (_currentLookupKind === 'ng_set') {
      if (nextActive) await activateNgSet(id); else await deactivateNgSet(id);
    } else {
      if (nextActive) await activateLookup(id); else await deactivateLookup(id);
    }
    renderLookupsTable();
  } catch(e) {
    toast('상태 변경 실패: ' + friendlyError(e.message||String(e)),'error');
  }
}

async function handleLookupDelete(row) {
  // 번들(ng_sets / caution_sets / participation_sets) 여부 판별: row.kind 미존재 또는 현재 kind가 번들 탭
  if (_currentLookupKind === 'ng_set' || _currentLookupKind === 'caution' || (_currentLookupKind === 'participation_set') || row.kind === undefined) {
    const ok = await showConfirm(`'${row.name_ko}' 번들을 영구 삭제하시겠습니까?\n이미 해당 번들을 쓴 캠페인은 스냅샷이 저장돼 영향 없습니다.`);
    if (!ok) return;
    try {
      if (_currentLookupKind === 'ng_set') await deleteNgSet(row.id);
      else if (_currentLookupKind === 'caution') await deleteCautionSet(row.id);
      else await deleteParticipationSet(row.id);
      toast('삭제했습니다','success');
      renderLookupsTable();
    } catch(e) {
      toast('삭제 실패: ' + friendlyError(e.message||String(e)),'error');
    }
    return;
  }
  let inUse = false;
  try { inUse = await isLookupInUse(row); } catch(e) {}
  if (inUse) {
    toast('이미 캠페인에서 사용 중입니다. 비활성으로 변경해주세요.','error');
    return;
  }
  const ok = await showConfirm(`'${row.name_ko}' 항목을 영구 삭제하시겠습니까?\n삭제 후에는 복구할 수 없습니다.`);
  if (!ok) return;
  try {
    await deleteLookup(row.id);
    toast('삭제했습니다','success');
    renderLookupsTable();
  } catch(e) {
    toast('삭제 실패: ' + friendlyError(e.message||String(e)),'error');
  }
}

// ══════════════════════════════════════
// 참여방법 번들 (participation_sets) — 관리자 UI
// ══════════════════════════════════════
const RECRUIT_TYPES_ALL = ['monitor','gifting','visit'];
const RECRUIT_TYPE_LABEL_JA = {monitor:'モニター', gifting:'ギフティング', visit:'訪問'};
let _psetCurrentSteps = []; // 편집 중 steps 상태
const MAX_PSET_STEPS = 6;

// ════════════════════════════════════════════════════════════════════
// SECTION: PARTICIPATION-SETS — 참여방법 번들 (테이블 + 편집 모달)
// ════════════════════════════════════════════════════════════════════

async function renderPsetTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  if (!tbody) return;
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>번들 이름 (한국어 / 일본어)</th>
      <th style="width:140px">모집 타입</th>
      <th style="width:80px">단계</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 6;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try { rows = await fetchParticipationSetsAll(); } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(friendlyError(e.message||String(e)))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 번들이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const rtBadges = (r.recruit_types||[]).map(t => {
      const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
      return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
    }).join(' ');
    const stepCount = Array.isArray(r.steps) ? r.steps.length : 0;
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong><div style="color:var(--muted);font-size:11px;margin-top:2px">${esc(r.name_ja)}</div></td>
      <td><div style="display:flex;gap:3px;flex-wrap:wrap">${rtBadges}</div></td>
      <td style="font-size:12px;color:var(--ink)">${stepCount}개</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openPsetEditModal(${esc(JSON.stringify(r))})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:var(--red-d)" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openPsetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('psetModalTitle').textContent = '참여방법 번들 추가';
  $('psetEditId').value = '';
  $('psetNameKo').value = '';
  $('psetNameJa').value = '';
  document.querySelectorAll('input[name="psetRT"]').forEach(cb => cb.checked = false);
  _psetCurrentSteps = [{title_ko:'', title_ja:'', desc_ko:'', desc_ja:''}];
  renderPsetSteps();
  $('psetEditError').style.display = 'none';
  openModal('psetEditModal');
}

function openPsetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('psetModalTitle').textContent = '참여방법 번들 편집';
  $('psetEditId').value = row.id;
  $('psetNameKo').value = row.name_ko || '';
  $('psetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="psetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _psetCurrentSteps = Array.isArray(row.steps) && row.steps.length
    ? row.steps.map(s => ({title_ko:s.title_ko||'', title_ja:s.title_ja||'', desc_ko:s.desc_ko||'', desc_ja:s.desc_ja||''}))
    : [{title_ko:'', title_ja:'', desc_ko:'', desc_ja:''}];
  renderPsetSteps();
  $('psetEditError').style.display = 'none';
  openModal('psetEditModal');
}

function renderPsetSteps() {
  const wrap = $('psetStepsWrap');
  if (!wrap) return;
  wrap.innerHTML = _psetCurrentSteps.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">STEP ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="psetMoveStep(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_psetCurrentSteps.length-1?'disabled':''} onclick="psetMoveStep(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_psetCurrentSteps.length<=1?'disabled':''} onclick="psetRemoveStep(${idx})" style="padding:2px 8px;color:var(--red-d)">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <input type="text" class="form-input" placeholder="제목 (한국어)" value="${esc(s.title_ko)}" style="font-size:13px;padding:8px 10px" oninput="_psetCurrentSteps[${idx}].title_ko=this.value">
        <input type="text" class="form-input" placeholder="제목 (일본어)" value="${esc(s.title_ja)}" style="font-size:13px;padding:8px 10px" oninput="_psetCurrentSteps[${idx}].title_ja=this.value">
        ${miniEditorHtml(s.desc_ko, `_psetCurrentSteps[${idx}].desc_ko=this.innerHTML`, '설명 (한국어)')}
        ${miniEditorHtml(s.desc_ja, `_psetCurrentSteps[${idx}].desc_ja=this.innerHTML`, '설명 (일본어)')}
      </div>
    </div>
  `).join('');
  const addBtn = $('psetAddStepBtn');
  if (addBtn) addBtn.disabled = _psetCurrentSteps.length >= MAX_PSET_STEPS;
}

function psetAddStep() {
  if (_psetCurrentSteps.length >= MAX_PSET_STEPS) { toast(`단계는 최대 ${MAX_PSET_STEPS}개까지 입니다`,'error'); return; }
  _psetCurrentSteps.push({title_ko:'', title_ja:'', desc_ko:'', desc_ja:''});
  renderPsetSteps();
}

function psetRemoveStep(idx) {
  if (_psetCurrentSteps.length <= 1) return;
  _psetCurrentSteps.splice(idx, 1);
  renderPsetSteps();
}

function psetMoveStep(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _psetCurrentSteps.length) return;
  const [s] = _psetCurrentSteps.splice(idx, 1);
  _psetCurrentSteps.splice(j, 0, s);
  renderPsetSteps();
}

async function savePsetEdit() {
  const errEl = $('psetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('psetEditId').value;
  const name_ko = $('psetNameKo').value.trim();
  const name_ja = $('psetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="psetRT"]:checked')).map(cb => cb.value);
  if (!recruit_types.length) { show('사용 가능한 모집 타입을 1개 이상 선택해주세요'); return; }
  const steps = _sanitizePsetStepsForSave(
    _psetCurrentSteps.filter(s => (s.title_ja||s.title_ko||'').trim())
  );
  if (!steps.length) { show('단계를 1개 이상 입력해주세요 (제목 필수)'); return; }
  if (steps.length > MAX_PSET_STEPS) { show(`단계는 최대 ${MAX_PSET_STEPS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, steps};
  try {
    if (id) await updateParticipationSet(id, payload);
    else await insertParticipationSet(payload);
    closeModal('psetEditModal');
    toast('저장했습니다','success');
    renderLookupsTable();
  } catch(e) {
    show('저장 실패: ' + friendlyError(e.message||String(e)));
  }
}

// ══════════════════════════════════════
// 주의사항 번들 (caution_sets) — 관리자 UI (migration 069)
//   참여방법 번들 패턴 완전 미러링. 캠페인 저장 시 items 스냅샷이
//   campaigns.caution_items 로 복사된다.
// ══════════════════════════════════════
let _csetCurrentItems = []; // 편집 중 items 상태
const MAX_CSET_ITEMS = 15;

// ════════════════════════════════════════════════════════════════════
// SECTION: CAUTION-SETS — 주의사항 번들 (미니 에디터 + 링크 팝오버)
// ════════════════════════════════════════════════════════════════════

async function renderCsetTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  if (!tbody) return;
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>번들 이름 (한국어 / 일본어)</th>
      <th style="width:140px">모집 타입</th>
      <th style="width:80px">항목 수</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 6;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try { rows = await fetchCautionSetsAll(); } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(friendlyError(e.message||String(e)))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 번들이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const rtBadges = (r.recruit_types||[]).length
      ? (r.recruit_types||[]).map(t => {
          const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
          return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
        }).join(' ')
      : '<span style="font-size:10px;color:var(--muted)">공통</span>';
    const itemCount = Array.isArray(r.items) ? r.items.length : 0;
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong><div style="color:var(--muted);font-size:11px;margin-top:2px">${esc(r.name_ja)}</div></td>
      <td><div style="display:flex;gap:3px;flex-wrap:wrap">${rtBadges}</div></td>
      <td style="font-size:12px;color:var(--ink)">${itemCount}개</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openCsetEditModal(${esc(JSON.stringify(r))})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:var(--red-d)" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openCsetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('csetModalTitle').textContent = '주의사항 번들 추가';
  $('csetEditId').value = '';
  $('csetNameKo').value = '';
  $('csetNameJa').value = '';
  document.querySelectorAll('input[name="csetRT"]').forEach(cb => cb.checked = false);
  _csetCurrentItems = [makeBlankCsetItem()];
  renderCsetItems();
  $('csetEditError').style.display = 'none';
  openModal('csetEditModal');
}

function openCsetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('csetModalTitle').textContent = '주의사항 번들 편집';
  $('csetEditId').value = row.id;
  $('csetNameKo').value = row.name_ko || '';
  $('csetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="csetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _csetCurrentItems = Array.isArray(row.items) && row.items.length
    ? row.items.map(normalizeCsetItem)
    : [makeBlankCsetItem()];
  renderCsetItems();
  $('csetEditError').style.display = 'none';
  openModal('csetEditModal');
}

function makeBlankCsetItem() {
  return {html_ko:'', html_ja:''};
}
// 레거시/신규 item 모두 {html_ko, html_ja} 정규화 (migration 069 전환 완료 후 v1 키 제거 예정)
function normalizeCsetItem(s) {
  if (!s) return makeBlankCsetItem();
  // v2 (신규): html_ko / html_ja
  if (s.html_ko != null || s.html_ja != null) {
    return {html_ko: s.html_ko || '', html_ja: s.html_ja || ''};
  }
  // v1 레거시 호환 (초안 069에 남아있을 수 있는 캐시 데이터용 - 즉시 html 로 합치기)
  const esc = v => (v == null ? '' : String(v))
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const buildLang = (lang) => {
    const body = s['text_'+lang] || '';
    const url = (s.link_url || '').trim();
    if (!url) return esc(body);
    const label = s['link_label_'+lang] || url;
    const after = s['text_after_'+lang] || '';
    const safeUrl = /^https?:\/\/|^mailto:/i.test(url) ? url : '';
    if (!safeUrl) return esc(body) + esc(after);
    return `${esc(body)}<a href="${esc(safeUrl)}" target="_blank" rel="noopener noreferrer">${esc(label)}</a>${esc(after)}`;
  };
  return {html_ko: buildLang('ko'), html_ja: buildLang('ja')};
}

// 미니 에디터 (contenteditable + execCommand) — B/I/U/S/Link/Image 6버튼
//   이미지 버튼: 파일 선택 다이얼로그 → uploadContentImage → 커서 위치 <img> 삽입
//   외부 URL 직접 삽입 차단 (sanitize 단계 src 화이트리스트로 후방 차단)
//
// 4번째 인자 opts (선택) — 넘기지 않으면 기존과 완전히 같게 동작한다.
//   { allowImage:false }  이미지 버튼을 감춘다 (오리엔시트 내부 메모용)
//   { sanitize: fn }      초기값 정화 함수를 바꾼다 (기본 sanitizeCautionHtml)
// ⚠️ 이미지를 감출 땐 sanitize 도 함께 바꿔야 한다. 버튼만 감추면 붙여넣기로
//    들어온 이미지는 그대로 통과한다(sanitizeCautionHtml 이 <img> 를 허용).
function miniEditorHtml(initialHtml, onChangeAttr, placeholder, opts) {
  const o = opts || {};
  const allowImage = o.allowImage !== false;   // 기본 true = 기존 호출부 동작 보존
  const sanitizeFn = typeof o.sanitize === 'function'
    ? o.sanitize
    : (typeof sanitizeCautionHtml === 'function' ? sanitizeCautionHtml : null);
  const safe = sanitizeFn
    ? sanitizeFn(initialHtml || '')
    : String(initialHtml || '').replace(/<script/gi, '&lt;script');
  const ph = esc(placeholder || '');
  return `
    <div class="mini-editor-wrap" style="border:1px solid var(--line);border-radius:8px;overflow:hidden;background:#fff">
      <div class="mini-editor-toolbar" style="display:flex;gap:2px;padding:4px 6px;border-bottom:1px solid var(--line);background:#fafafa">
        <button type="button" onclick="miniEditorCmd(this,'bold')" title="굵게"        style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-weight:700;font-size:12px">B</button>
        <button type="button" onclick="miniEditorCmd(this,'italic')" title="기울임"    style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-style:italic;font-size:12px">I</button>
        <button type="button" onclick="miniEditorCmd(this,'underline')" title="밑줄"   style="border:0;background:transparent;cursor:pointer;padding:4px 8px;text-decoration:underline;font-size:12px">U</button>
        <button type="button" onclick="miniEditorCmd(this,'strikeThrough')" title="취소선" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;text-decoration:line-through;font-size:12px">S</button>
        <span style="width:1px;background:var(--line);margin:2px 4px"></span>
        <button type="button" onclick="miniEditorCmd(this,'link')" title="링크 추가 (텍스트 선택 후 클릭)" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-size:12px;color:var(--pink);display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">link</span>링크</button>
        ${allowImage ? '<button type="button" onclick="miniEditorInsertImageClick(this)" title="이미지 삽입 (5MB 이하 jpg/png/webp)" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-size:12px;color:var(--pink);display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">image</span>이미지</button>' : ''}
      </div>
      <div class="mini-editor-content" contenteditable="true" data-placeholder="${ph}" style="padding:8px 10px;font-size:13px;min-height:48px;line-height:1.6;outline:none" oninput="${onChangeAttr}" onpaste="miniEditorPaste(event)">${safe}</div>
    </div>`;
}

// 이미지 버튼 클릭 — 숨김 file input 생성 → 파일 선택 → 업로드 → <img> 삽입
//   캡션·크기 옵션 없음 (사양 §1: 기본만, .rich-img 가로 100% 자동 적용)
function miniEditorInsertImageClick(btn) {
  const wrap = btn.closest('.mini-editor-wrap');
  const content = wrap?.querySelector('.mini-editor-content');
  if (!content) return;
  // 임시 file input — DOM 에 부착해야 일부 브라우저에서 click() 동작
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = 'image/jpeg,image/png,image/webp';
  input.style.display = 'none';
  document.body.appendChild(input);
  input.addEventListener('change', async () => {
    try {
      const file = input.files && input.files[0];
      if (!file) return;
      if (!['image/jpeg','image/png','image/webp'].includes(file.type)) {
        toast('JPG/PNG/WebP 형식만 업로드할 수 있습니다','error');
        return;
      }
      if (file.size > 5 * 1024 * 1024) {
        toast('이미지는 5MB 이하만 업로드할 수 있습니다','error');
        return;
      }
      content.focus();
      toast('이미지 업로드 중…','info');
      const url = await uploadContentImage(file);
      // sanitize 가 src 화이트리스트 + .rich-img 클래스를 후처리에서 부여하므로
      // 여기서는 단순히 <img src="..."> 만 삽입. oninput 트리거로 sanitize 가 다시 통과.
      const html = '<img src="' + url + '" alt="">';
      // execCommand insertHTML 폴백: contenteditable 에서 selection 위치 보존
      const ok = document.execCommand('insertHTML', false, html);
      if (!ok) {
        // 폴백: 끝에 append
        content.insertAdjacentHTML('beforeend', html);
      }
      content.dispatchEvent(new Event('input', {bubbles:true}));
      toast('이미지를 추가했습니다','success');
    } catch (e) {
      const msg = (e && e.message) || String(e);
      if (msg === 'file_too_large') toast('이미지는 5MB 이하만 업로드할 수 있습니다','error');
      else if (msg === 'file_type_not_allowed') toast('JPG/PNG/WebP 형식만 업로드할 수 있습니다','error');
      else toast('이미지 업로드 실패: ' + msg,'error');
    } finally {
      input.remove();
    }
  }, {once: true});
  input.click();
}

// 툴바 버튼 클릭 핸들러 — 현재 셀렉션에 cmd 적용
function miniEditorCmd(btn, cmd) {
  const wrap = btn.closest('.mini-editor-wrap');
  const content = wrap?.querySelector('.mini-editor-content');
  if (!content) return;
  content.focus();
  if (cmd === 'link') {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed) { toast('링크로 만들 텍스트를 먼저 선택하세요','error'); return; }
    const url = prompt('링크 URL (https:// 또는 mailto:)', 'https://');
    if (!url) return;
    const clean = url.trim();
    if (!/^https?:\/\/|^mailto:/i.test(clean)) { toast('http/https/mailto URL 만 허용됩니다','error'); return; }
    document.execCommand('createLink', false, clean);
    // target=_blank + rel 추가 (execCommand 는 이 속성을 설정하지 않음)
    content.querySelectorAll('a[href]').forEach(a => {
      if (a.getAttribute('href') === clean) {
        a.setAttribute('target', '_blank');
        a.setAttribute('rel', 'noopener noreferrer');
      }
    });
  } else {
    document.execCommand(cmd, false, null);
  }
  // oninput 수동 트리거 (execCommand 는 input 이벤트 생성 안 하는 브라우저 대응)
  content.dispatchEvent(new Event('input', {bubbles:true}));
}

// paste 시 서식 제거 — plain text 로만 삽입해 외부 block 태그 유입 차단
function miniEditorPaste(e) {
  e.preventDefault();
  const text = (e.clipboardData || window.clipboardData)?.getData('text/plain') || '';
  document.execCommand('insertText', false, text);
}

// ══════════════════════════════════════
// 미니 에디터 — 링크 팝오버 (클릭 시 URL 편집/복사/삭제)
//   .mini-editor-content 내부 <a> 를 클릭하면 말풍선 팝오버 노출.
//   - URL 인풋으로 href 실시간 수정 (http/https/mailto 화이트리스트)
//   - 복사 버튼 → 현재 href 를 clipboard 로 복사
//   - 삭제 버튼 → <a> 언래핑(텍스트만 남김) + oninput 트리거
//   - 외부 클릭 또는 ESC 로 닫기
// ══════════════════════════════════════
var _miniEditorLinkPopover = null;

function closeMiniEditorLinkPopover() {
  if (_miniEditorLinkPopover) {
    _miniEditorLinkPopover.remove();
    _miniEditorLinkPopover = null;
    document.removeEventListener('mousedown', _miniEditorLinkPopoverOutside, true);
    document.removeEventListener('keydown', _miniEditorLinkPopoverKey, true);
  }
}

function _miniEditorLinkPopoverOutside(e) {
  if (!_miniEditorLinkPopover) return;
  if (_miniEditorLinkPopover.contains(e.target)) return;
  // 다른 링크 클릭이면 팝오버 교체 (위임 핸들러에서 다시 openMiniEditorLinkPopover 호출)
  if (e.target.closest && e.target.closest('.mini-editor-content a[href], .ql-editor a[href]')) return;
  closeMiniEditorLinkPopover();
}

function _miniEditorLinkPopoverKey(e) {
  if (e.key === 'Escape') closeMiniEditorLinkPopover();
}

function openMiniEditorLinkPopover(aEl, contentDiv) {
  closeMiniEditorLinkPopover();
  const rect = aEl.getBoundingClientRect();
  const pop = document.createElement('div');
  pop.className = 'mini-editor-link-popover';
  const href = aEl.getAttribute('href') || '';
  pop.innerHTML = `
    <input type="url" class="melp-url" value="${esc(href)}" placeholder="https:// 또는 mailto:" spellcheck="false">
    <button type="button" class="melp-btn melp-copy" title="링크 URL 복사"><span class="material-icons-round notranslate" translate="no">content_copy</span></button>
    <button type="button" class="melp-btn melp-open" title="새 탭으로 열기"><span class="material-icons-round notranslate" translate="no">open_in_new</span></button>
    <button type="button" class="melp-btn melp-delete" title="링크 제거"><span class="material-icons-round notranslate" translate="no">link_off</span></button>
  `;
  document.body.appendChild(pop);
  // CSS 에서 position:fixed 지정. viewport 경계 자동 보정 (하단 넘치면 위로 폴백)
  _positionMenuInViewport(pop, rect, {placement: 'below', gap: 6});
  _miniEditorLinkPopover = pop;

  _bindMiniEditorLinkPopoverEvents(pop, aEl, contentDiv, href);
}

// 링크 팝오버 이벤트 바인딩 (openMiniEditorLinkPopover 길이 축소 목적 분리)
function _bindMiniEditorLinkPopoverEvents(pop, aEl, contentDiv, href) {
  const input = pop.querySelector('.melp-url');
  const btnCopy = pop.querySelector('.melp-copy');
  const btnOpen = pop.querySelector('.melp-open');
  const btnDelete = pop.querySelector('.melp-delete');

  // 초기 URL 이 화이트리스트 미매치면 빨간색 피드백 (javascript:/data: 등 비정상 스킴 가시화)
  if (href && !/^https?:\/\/|^mailto:/i.test(href)) {
    input.style.color = 'var(--red)';
  }

  // URL 편집: http/https/mailto 면 즉시 href 반영, 아니면 href 미변경(입력창만 유지)
  input.addEventListener('input', () => {
    const val = input.value.trim();
    if (val && /^https?:\/\/|^mailto:/i.test(val)) {
      aEl.setAttribute('href', val);
      input.style.color = '';
      contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    } else if (val) {
      input.style.color = 'var(--red)';
    } else {
      input.style.color = '';
    }
  });

  // 복사
  btnCopy.addEventListener('click', async () => {
    const v = aEl.getAttribute('href') || '';
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(v);
      } else {
        // 구형 브라우저 폴백
        const ta = document.createElement('textarea');
        ta.value = v; document.body.appendChild(ta);
        ta.select(); document.execCommand('copy'); document.body.removeChild(ta);
      }
      toast('링크를 복사했습니다','success');
    } catch(e) { toast('복사 실패: ' + friendlyError(e.message||String(e)),'error'); }
  });

  // 새 탭으로 열기 (편집 중에도 실제 링크 확인 가능)
  btnOpen.addEventListener('click', () => {
    const v = aEl.getAttribute('href') || '';
    if (/^https?:\/\/|^mailto:/i.test(v)) window.open(v, '_blank', 'noopener,noreferrer');
  });

  // 링크 제거: <a> 를 자식 텍스트로 언래핑
  btnDelete.addEventListener('click', () => {
    const parent = aEl.parentNode;
    if (!parent) return;
    while (aEl.firstChild) parent.insertBefore(aEl.firstChild, aEl);
    parent.removeChild(aEl);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    closeMiniEditorLinkPopover();
  });

  // 팝오버 밖 클릭·ESC 로 닫기
  setTimeout(() => {
    document.addEventListener('mousedown', _miniEditorLinkPopoverOutside, true);
    document.addEventListener('keydown', _miniEditorLinkPopoverKey, true);
  }, 0);

  input.focus();
  input.select();
}

// 위임 핸들러 — 미니 에디터 + Quill 에디터 내부 <a> 클릭 → 팝오버 (새 탭 이동 차단)
document.addEventListener('click', function(e) {
  const a = e.target.closest && e.target.closest('.mini-editor-content a[href], .ql-editor a[href]');
  if (!a) return;
  const contentDiv = a.closest('.mini-editor-content, .ql-editor');
  if (!contentDiv) return;
  e.preventDefault();
  openMiniEditorLinkPopover(a, contentDiv);
});

// 위임 핸들러 — 미니 에디터 내부 <img> 클릭 → 사이즈 팝오버 (작게/중간/크게/원본·삭제)
// 신규 삽입 직후(sanitize 전)는 .rich-img 클래스가 없으므로 img 전체 매칭.
document.addEventListener('click', function(e) {
  const img = e.target.closest && e.target.closest('.mini-editor-content img');
  if (!img) return;
  const contentDiv = img.closest('.mini-editor-content');
  if (!contentDiv) return;
  e.preventDefault();
  openMiniEditorImagePopover(img, contentDiv);
});

// ══════════════════════════════════════
// 미니 에디터 — 이미지 사이즈 팝오버 (작게/중간/크게/원본·삭제)
//   .mini-editor-content 내부 <img.rich-img> 클릭 시 말풍선 팝오버 노출.
//   - 4개 사이즈 버튼: 작게(sm 25%) / 중간(md 50%) / 크게(lg 75%) / 원본(100%)
//   - 현재 적용 사이즈 버튼 활성 표시
//   - 삭제 버튼 → <img> 제거 + oninput 트리거
//   - 외부 클릭 또는 ESC 로 닫기
//   - data-rich-size 속성으로 저장, sanitize 후처리에서 class 부여
// ══════════════════════════════════════
var _miniEditorImagePopover = null;

function closeMiniEditorImagePopover() {
  if (_miniEditorImagePopover) {
    // 선택 outline 정리 (.rich-img 가 아직 없는 신규 이미지도 포함)
    document.querySelectorAll('.mini-editor-content img.is-selected')
      .forEach(el => el.classList.remove('is-selected'));
    _miniEditorImagePopover.remove();
    _miniEditorImagePopover = null;
    document.removeEventListener('mousedown', _miniEditorImagePopoverOutside, true);
    document.removeEventListener('keydown', _miniEditorImagePopoverKey, true);
  }
}

function _miniEditorImagePopoverOutside(e) {
  if (!_miniEditorImagePopover) return;
  if (_miniEditorImagePopover.contains(e.target)) return;
  // 다른 이미지 클릭이면 팝오버 교체 (위임 핸들러가 새 openMiniEditorImagePopover 호출)
  if (e.target.closest && e.target.closest('.mini-editor-content img')) return;
  closeMiniEditorImagePopover();
}

function _miniEditorImagePopoverKey(e) {
  if (e.key === 'Escape') closeMiniEditorImagePopover();
}

function openMiniEditorImagePopover(imgEl, contentDiv) {
  closeMiniEditorImagePopover();
  imgEl.classList.add('is-selected');
  const rect = imgEl.getBoundingClientRect();
  const pop = document.createElement('div');
  pop.className = 'mini-editor-img-popover';
  const currentSize = (imgEl.getAttribute('data-rich-size') || 'orig').toLowerCase();
  const btn = (val, label) =>
    `<button type="button" class="meip-size ${currentSize===val?'is-active':''}" data-size="${val}" title="${label}">${label}</button>`;
  pop.innerHTML = `
    ${btn('sm','작게')}
    ${btn('md','중간')}
    ${btn('lg','크게')}
    ${btn('orig','원본')}
    <span class="meip-sep"></span>
    <button type="button" class="meip-delete" title="이미지 제거"><span class="material-icons-round notranslate" translate="no">delete</span></button>
  `;
  document.body.appendChild(pop);
  // 위치 계산 — 기존 링크 팝오버와 동일한 viewport-aware 헬퍼 사용
  _positionMenuInViewport(pop, rect, {placement: 'below', gap: 6});
  _miniEditorImagePopover = pop;

  const apply = (size) => {
    if (size === 'orig') imgEl.removeAttribute('data-rich-size');
    else imgEl.setAttribute('data-rich-size', size);
    // 즉시 시각 반영 — sanitize 가 다시 통과하기 전 미리보기 일치
    imgEl.classList.remove('rich-img-sm','rich-img-md','rich-img-lg');
    if (size === 'sm' || size === 'md' || size === 'lg') imgEl.classList.add('rich-img-' + size);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    // 활성 상태 갱신
    pop.querySelectorAll('.meip-size').forEach(b => {
      b.classList.toggle('is-active', b.dataset.size === size);
    });
  };

  pop.querySelectorAll('.meip-size').forEach(b => {
    b.addEventListener('click', () => apply(b.dataset.size));
  });

  pop.querySelector('.meip-delete').addEventListener('click', () => {
    const parent = imgEl.parentNode;
    if (!parent) return;
    parent.removeChild(imgEl);
    contentDiv.dispatchEvent(new Event('input', {bubbles:true}));
    closeMiniEditorImagePopover();
  });

  // 팝오버 밖 클릭·ESC 로 닫기
  setTimeout(() => {
    document.addEventListener('mousedown', _miniEditorImagePopoverOutside, true);
    document.addEventListener('keydown', _miniEditorImagePopoverKey, true);
  }, 0);
}

function renderCsetItems() {
  const wrap = $('csetItemsWrap');
  if (!wrap) return;
  wrap.innerHTML = _csetCurrentItems.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--pink)">항목 ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="csetMoveItem(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_csetCurrentItems.length-1?'disabled':''} onclick="csetMoveItem(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_csetCurrentItems.length<=1?'disabled':''} onclick="csetRemoveItem(${idx})" style="padding:2px 8px;color:var(--red-d)">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_csetCurrentItems[${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_csetCurrentItems[${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
        </div>
      </div>
    </div>
  `).join('');
  const addBtn = $('csetAddItemBtn');
  if (addBtn) addBtn.disabled = _csetCurrentItems.length >= MAX_CSET_ITEMS;
}

function csetAddItem() {
  if (_csetCurrentItems.length >= MAX_CSET_ITEMS) { toast(`항목은 최대 ${MAX_CSET_ITEMS}개까지 입니다`,'error'); return; }
  _csetCurrentItems.push(makeBlankCsetItem());
  renderCsetItems();
}

function csetRemoveItem(idx) {
  if (_csetCurrentItems.length <= 1) return;
  _csetCurrentItems.splice(idx, 1);
  renderCsetItems();
}

function csetMoveItem(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _csetCurrentItems.length) return;
  const [s] = _csetCurrentItems.splice(idx, 1);
  _csetCurrentItems.splice(j, 0, s);
  renderCsetItems();
}

// caution item html 이 실질적으로 비어있는지 (미니 에디터는 빈 상태에서도 <br> 같은 것을 남길 수 있음)
function isCsetItemEmpty(htmlKo, htmlJa) {
  const plain = String((htmlKo || '') + ' ' + (htmlJa || ''))
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .trim();
  return plain.length === 0;
}

async function saveCsetEdit() {
  const errEl = $('csetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('csetEditId').value;
  const name_ko = $('csetNameKo').value.trim();
  const name_ja = $('csetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 번들 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="csetRT"]:checked')).map(cb => cb.value);
  // 저장 직전 DOMPurify sanitize — DB에 안전한 HTML만 저장 (렌더 단도 2중 sanitize)
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _csetCurrentItems
    .filter(s => !isCsetItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  if (!items.length) { show('항목을 1개 이상 입력해주세요 (본문 한국어 또는 일본어 필수)'); return; }
  if (items.length > MAX_CSET_ITEMS) { show(`항목은 최대 ${MAX_CSET_ITEMS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, items};
  try {
    if (id) await updateCautionSet(id, payload);
    else await insertCautionSet(payload);
    closeModal('csetEditModal');
    toast('저장했습니다','success');
    renderLookupsTable();
  } catch(e) {
    show('저장 실패: ' + friendlyError(e.message||String(e)));
  }
}

// ══════════════════════════════════════════════════════════════════════
// SECTION: NG-SETS — NG 사항 번들 기준 데이터 페인 (migration 107)
//   caution_sets(cset) 패턴 완전 미러링. 캠페인 폼의 editModal 과
//   동일 nset 헬퍼를 재활용. 번들 자체 편집이므로 "번들 다시 불러오기" 없음.
// ══════════════════════════════════════════════════════════════════════
let _nsetCurrentItems = []; // 기준 데이터 페인 편집 중 items 상태
const MAX_NSET_ITEMS = 20;

async function renderNgSetTable() {
  const tbody = $('lookupsTableBody');
  const thead = $('lookupTableHead');
  if (!tbody) return;
  if (thead) {
    thead.innerHTML = `<tr>
      <th style="width:40px"></th>
      ${_lookupReorderMode ? '<th style="width:80px">순서</th>' : ''}
      <th>번들 이름 (한국어 / 일본어)</th>
      <th style="width:140px">모집 타입</th>
      <th style="width:80px">항목 수</th>
      <th style="width:80px">상태</th>
      ${_lookupReorderMode ? '' : '<th style="width:160px"></th>'}
    </tr>`;
  }
  const colspan = _lookupReorderMode ? 5 : 6;
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(24,24,27,.2);border-top-color:var(--pink)"></span></td></tr>`;
  let rows = [];
  try { rows = await fetchNgSetsAll(); } catch(e) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--red);padding:24px">조회 실패: ${esc(friendlyError(e.message||String(e)))}</td></tr>`;
    return;
  }
  if (!rows.length) {
    tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px">등록된 번들이 없습니다</td></tr>`;
    return;
  }
  tbody.innerHTML = rows.map((r, i) => {
    const isFirst = i === 0;
    const isLast = i === rows.length - 1;
    const upId = isFirst ? '' : rows[i-1].id;
    const downId = isLast ? '' : rows[i+1].id;
    const activeToggle = `<label class="lookup-toggle" title="${r.active?'활성':'비활성'}" onclick="event.stopPropagation()">
      <input type="checkbox" ${r.active?'checked':''} onchange="toggleLookupActive('${r.id}',this.checked)">
      <span class="lookup-toggle-slider"></span>
    </label>`;
    const rtBadges = (r.recruit_types||[]).length
      ? (r.recruit_types||[]).map(t => {
          const cls = t==='monitor'?'badge-blue':t==='gifting'?'badge-gold':'badge-green';
          return `<span class="badge ${cls}" style="font-size:9px;padding:1px 6px">${RECRUIT_TYPE_LABEL_KO[t]||t}</span>`;
        }).join(' ')
      : '<span style="font-size:10px;color:var(--muted)">공통</span>';
    const itemCount = Array.isArray(r.items) ? r.items.length : 0;
    return `<tr>
      <td style="color:var(--muted);font-size:11px">${i+1}</td>
      ${_lookupReorderMode ? `<td><div style="display:flex;gap:3px">
        <button class="btn btn-ghost btn-xs" ${isFirst?'disabled':''} onclick="moveLookup('${r.id}','${upId}')" style="padding:2px 6px;font-size:13px">↑</button>
        <button class="btn btn-ghost btn-xs" ${isLast?'disabled':''} onclick="moveLookup('${r.id}','${downId}')" style="padding:2px 6px;font-size:13px">↓</button>
      </div></td>` : ''}
      <td><strong style="font-size:13px">${esc(r.name_ko)}</strong><div style="color:var(--muted);font-size:11px;margin-top:2px">${esc(r.name_ja)}</div></td>
      <td><div style="display:flex;gap:3px;flex-wrap:wrap">${rtBadges}</div></td>
      <td style="font-size:12px;color:var(--ink)">${itemCount}개</td>
      <td>${activeToggle}</td>
      ${_lookupReorderMode ? '' : `<td style="white-space:nowrap">
        <button class="btn btn-ghost btn-xs" onclick='openNgSetEditModal(${esc(JSON.stringify(r))})'>편집</button>
        <button class="btn btn-ghost btn-xs" style="color:var(--red-d)" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
}

function openNgSetAddModal() {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('nsetModalTitle').textContent = 'NG 사항 번들 추가';
  $('nsetEditId').value = '';
  $('nsetNameKo').value = '';
  $('nsetNameJa').value = '';
  document.querySelectorAll('input[name="nsetRT"]').forEach(cb => cb.checked = false);
  _nsetCurrentItems = [{html_ko:'', html_ja:''}];
  renderNgSetItems();
  $('nsetEditError').style.display = 'none';
  openModal('nsetEditModal');
}

function openNgSetEditModal(row) {
  if (!isCampaignAdminOrAbove()) { toast('권한이 없습니다','error'); return; }
  $('nsetModalTitle').textContent = 'NG 사항 번들 편집';
  $('nsetEditId').value = row.id;
  $('nsetNameKo').value = row.name_ko || '';
  $('nsetNameJa').value = row.name_ja || '';
  const rtSet = new Set(row.recruit_types || []);
  document.querySelectorAll('input[name="nsetRT"]').forEach(cb => cb.checked = rtSet.has(cb.value));
  _nsetCurrentItems = Array.isArray(row.items) && row.items.length
    ? row.items.map(normalizeNgItem)
    : [{html_ko:'', html_ja:''}];
  renderNgSetItems();
  $('nsetEditError').style.display = 'none';
  openModal('nsetEditModal');
}

function renderNgSetItems() {
  const wrap = $('nsetItemsWrap');
  if (!wrap) return;
  wrap.innerHTML = _nsetCurrentItems.map((s, idx) => `
    <div style="border:1px solid var(--line);border-radius:10px;padding:12px;background:var(--surface-container-low)">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
        <span style="font-size:12px;font-weight:700;color:var(--red-d)">NG ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="nsetMoveItem(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_nsetCurrentItems.length-1?'disabled':''} onclick="nsetMoveItem(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_nsetCurrentItems.length<=1?'disabled':''} onclick="nsetRemoveItem(${idx})" style="padding:2px 8px;color:var(--red-d)">삭제</button>
        </div>
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px">
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (한국어)</div>
          ${miniEditorHtml(s.html_ko, `_nsetCurrentItems[${idx}].html_ko=this.innerHTML`, '본문 (한국어)')}
        </div>
        <div>
          <div style="font-size:11px;color:var(--muted);margin-bottom:3px">본문 (일본어)</div>
          ${miniEditorHtml(s.html_ja, `_nsetCurrentItems[${idx}].html_ja=this.innerHTML`, '본문 (일본어)')}
        </div>
      </div>
    </div>
  `).join('');
  const addBtn = $('nsetAddItemBtn');
  if (addBtn) addBtn.disabled = _nsetCurrentItems.length >= MAX_NSET_ITEMS;
}

function nsetAddItem() {
  if (_nsetCurrentItems.length >= MAX_NSET_ITEMS) { toast(`NG 항목은 최대 ${MAX_NSET_ITEMS}개까지`,'error'); return; }
  _nsetCurrentItems.push({html_ko:'', html_ja:''});
  renderNgSetItems();
}

function nsetRemoveItem(idx) {
  if (_nsetCurrentItems.length <= 1) return;
  _nsetCurrentItems.splice(idx, 1);
  renderNgSetItems();
}

function nsetMoveItem(idx, dir) {
  const j = idx + dir;
  if (j < 0 || j >= _nsetCurrentItems.length) return;
  const [s] = _nsetCurrentItems.splice(idx, 1);
  _nsetCurrentItems.splice(j, 0, s);
  renderNgSetItems();
}

async function saveNgSetEdit() {
  const errEl = $('nsetEditError');
  const show = m => { errEl.textContent = m; errEl.style.display = 'block'; };
  errEl.style.display = 'none';
  const id = $('nsetEditId').value;
  const name_ko = $('nsetNameKo').value.trim();
  const name_ja = $('nsetNameJa').value.trim();
  if (!name_ko || !name_ja) { show('한국어/일본어 번들 이름을 모두 입력해주세요'); return; }
  const recruit_types = Array.from(document.querySelectorAll('input[name="nsetRT"]:checked')).map(cb => cb.value);
  const sanitize = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (x => String(x||''));
  const items = _nsetCurrentItems
    .filter(s => !isNgItemEmpty(s.html_ko, s.html_ja))
    .map(s => ({
      html_ko: sanitize(s.html_ko || ''),
      html_ja: sanitize(s.html_ja || '')
    }));
  if (!items.length) { show('항목을 1개 이상 입력해주세요 (본문 한국어 또는 일본어 필수)'); return; }
  if (items.length > MAX_NSET_ITEMS) { show(`NG 항목은 최대 ${MAX_NSET_ITEMS}개까지`); return; }
  const payload = {name_ko, name_ja, recruit_types, items};
  try {
    if (id) await updateNgSet(id, payload);
    else await insertNgSet(payload);
    closeModal('nsetEditModal');
    toast('저장했습니다','success');
    renderLookupsTable();
  } catch(e) {
    show('저장 실패: ' + friendlyError(e.message||String(e)));
  }
}
