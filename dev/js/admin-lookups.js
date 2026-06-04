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
const LOOKUP_KIND_LABEL_KO = {channel:'채널', category:'카테고리', content_type:'콘텐츠 종류', ng_set:'NG 사항', participation_set:'참여방법', reject_reason:'반려사유', caution:'주의사항'};
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
    btn.style.color = 'var(--pink)';
    btn.style.borderBottomColor = 'var(--pink)';
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
  if (_currentLookupKind === 'participation_set') { await renderPsetTable(); return; }
  if (_currentLookupKind === 'caution') { await renderCsetTable(); return; }
  if (_currentLookupKind === 'ng_set') { await renderNgSetTable(); return; }
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
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
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
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
      </td>`}
    </tr>`;
  }).join('');
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
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
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
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
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
          <button type="button" class="btn btn-ghost btn-xs" ${_psetCurrentSteps.length<=1?'disabled':''} onclick="psetRemoveStep(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
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
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
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
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
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
function miniEditorHtml(initialHtml, onChangeAttr, placeholder) {
  const safe = (typeof sanitizeCautionHtml === 'function')
    ? sanitizeCautionHtml(initialHtml || '')
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
        <button type="button" onclick="miniEditorInsertImageClick(this)" title="이미지 삽입 (5MB 이하 jpg/png/webp)" style="border:0;background:transparent;cursor:pointer;padding:4px 8px;font-size:12px;color:var(--pink);display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">image</span>이미지</button>
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
          <button type="button" class="btn btn-ghost btn-xs" ${_csetCurrentItems.length<=1?'disabled':''} onclick="csetRemoveItem(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
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
  tbody.innerHTML = `<tr><td colspan="${colspan}" style="text-align:center;color:var(--muted);padding:24px"><span class="spinner" style="width:20px;height:20px;border-width:2px;border-color:rgba(200,120,163,.2);border-top-color:var(--pink)"></span></td></tr>`;
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
        <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick='handleLookupDelete(${esc(JSON.stringify(r))})'>삭제</button>
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
        <span style="font-size:12px;font-weight:700;color:#B3261E">NG ${idx+1}</span>
        <div style="display:flex;gap:4px">
          <button type="button" class="btn btn-ghost btn-xs" ${idx===0?'disabled':''} onclick="nsetMoveItem(${idx},-1)" style="padding:2px 6px">↑</button>
          <button type="button" class="btn btn-ghost btn-xs" ${idx===_nsetCurrentItems.length-1?'disabled':''} onclick="nsetMoveItem(${idx},1)" style="padding:2px 6px">↓</button>
          <button type="button" class="btn btn-ghost btn-xs" ${_nsetCurrentItems.length<=1?'disabled':''} onclick="nsetRemoveItem(${idx})" style="padding:2px 8px;color:#B3261E">삭제</button>
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
