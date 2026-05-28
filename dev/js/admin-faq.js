// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-faq.js
// ═════════════════════════════════════════════════════════════════
//
// 자동응답(FAQ 가이드형) 관리자 페인 — 마이그레이션 146 (admin.js 파일 분리).
//   · 좌우 2단 마스터-디테일 (카테고리 | 질문 + 측정 배지)
//   · 편집 모달 한/일 2열 + 화면이동 드롭다운 + handoff 토글 + 미리보기
//   · 함수: loadFaqPane/renderFaqCategories/renderFaqItems/saveFaqNode 등 20종
//   · 상태/상수: _faqNodes/_faqStats/_faqSelectedCatId/_faqReorder/FAQ_ACTION_LABEL_KO/FAQ_STAGE_LABEL_KO
//
// ⚠ loadFaqPane 은 switchAdminPane(admin-core.js) loaders 가 참조 → 전역 유지(이름 변경 금지).
// ═════════════════════════════════════════════════════════════════

// SECTION: FAQ (자동응답) — 마이그레이션 146. 좌우 2단 마스터-디테일 페인
// ════════════════════════════════════════════════════════════════════

// 화면이동 드롭다운 라벨 (action_target → 한국어 라벨). 미리보기·렌더용
const FAQ_ACTION_LABEL_KO = {
  '#mypage-applications': '응모이력',
  '#activity': '활동관리(결과물 제출)',
  '#mypage-profile-sns': 'SNS 계정',
  '#mypage-profile-address': '배송지',
  '#mypage-paypal': 'PayPal',
  '#mypage-profile-basic': '기본정보',
  '#mypage-password': '비밀번호 변경',
  '#mypage-email-settings': '메일 수신 설정'
};
// 맞춤 노출 단계 라벨 (한국어)
const FAQ_STAGE_LABEL_KO = {
  pending: '심사중', approved_purchase: '승인-구매기간', approved_visit: '승인-방문기간',
  approved_post: '승인-제출단계', rejected: '비승인', done: '완료'
};

let _faqNodes = [];          // 전체 노드 캐시 (active 무관)
let _faqStats = {};          // 노드별 측정 집계
let _faqSelectedCatId = null;// 선택된 카테고리 id
let _faqReorder = { category: false, item: false };

// 페인 로드 — 노드 + 측정 조회 후 좌우 렌더
async function loadFaqPane() {
  applyLookupMenuVisibility();
  if (!isCampaignAdminOrAbove()) {
    const el = $('faqCatList');
    if (el) el.innerHTML = '<div style="text-align:center;color:var(--muted);padding:24px">권한이 없습니다 (campaign_admin 이상)</div>';
    return;
  }
  [_faqNodes, _faqStats] = await Promise.all([fetchFaqNodes(), fetchFaqInteractionStats()]);
  // 선택 카테고리 유효성 검증 (삭제됐으면 첫 카테고리로)
  const cats = _faqCategories();
  if (!_faqSelectedCatId || !cats.some(c => c.id === _faqSelectedCatId)) {
    _faqSelectedCatId = cats.length ? cats[0].id : null;
  }
  renderFaqCategories();
  renderFaqItems(_faqSelectedCatId);
}

// 카테고리 노드만 (sort_order 순 — fetch 가 이미 정렬)
function _faqCategories() {
  return _faqNodes.filter(n => n.kind === 'category');
}
// 특정 카테고리의 1차 질문 항목 (분기 노드의 자식 item 은 우측 목록에서 제외)
function _faqItemsOf(categoryId) {
  return _faqNodes.filter(n => n.kind === 'item' && n.parent_id === categoryId);
}

// 좌측 카테고리 목록 렌더
function renderFaqCategories() {
  const wrap = $('faqCatList');
  if (!wrap) return;
  const cats = _faqCategories();
  if (!cats.length) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:24px">등록된 카테고리가 없습니다</div>';
    return;
  }
  const reorder = _faqReorder.category;
  wrap.innerHTML = cats.map((c, i) => {
    const cnt = _faqItemsOf(c.id).length;
    const sel = c.id === _faqSelectedCatId ? ' faq-item-sel' : '';
    const upId = i === 0 ? '' : cats[i-1].id;
    const downId = i === cats.length-1 ? '' : cats[i+1].id;
    return `<div class="faq-item${sel}${c.active?'':' faq-item-off'}" onclick="selectFaqCategory('${esc(c.id)}')">
      <div class="faq-item-main">
        <div class="faq-item-label">${esc(c.label_ko)} <span class="faq-item-count">질문 ${cnt}개</span></div>
        <div class="faq-item-sub">${esc(c.label_ja)}</div>
      </div>
      <div class="faq-item-actions" onclick="event.stopPropagation()">
        ${reorder
          ? `<button class="btn btn-ghost btn-xs" ${upId?'':'disabled'} onclick="moveFaqNode('${esc(c.id)}','${esc(upId)}')">↑</button>
             <button class="btn btn-ghost btn-xs" ${downId?'':'disabled'} onclick="moveFaqNode('${esc(c.id)}','${esc(downId)}')">↓</button>`
          : `<label class="lookup-toggle" title="${c.active?'활성':'비활성'}"><input type="checkbox" ${c.active?'checked':''} onchange="toggleFaqNodeActive('${esc(c.id)}',this.checked)"><span class="lookup-toggle-slider"></span></label>
             <button class="btn btn-ghost btn-xs" onclick="openFaqEditModal('${esc(c.id)}',null,'category')">편집</button>
             <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick="deleteFaqCategory('${esc(c.id)}')">삭제</button>`}
      </div>
    </div>`;
  }).join('');
}

// 우측 질문 항목 목록 렌더 (측정 배지 포함)
function renderFaqItems(categoryId) {
  const wrap = $('faqItemList');
  const title = $('faqItemsTitle');
  const footer = $('faqItemFooter');
  const reorderBtn = $('btnFaqItemReorder');
  if (!wrap) return;
  const cat = _faqNodes.find(n => n.id === categoryId);
  if (!cat) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:32px">좌측에서 카테고리를 선택하세요</div>';
    if (title) title.textContent = '질문';
    if (footer) footer.style.display = 'none';
    if (reorderBtn) reorderBtn.style.display = 'none';
    return;
  }
  if (title) title.textContent = '「' + cat.label_ko + '」 질문';
  if (footer) footer.style.display = '';
  if (reorderBtn) reorderBtn.style.display = '';
  const items = _faqItemsOf(categoryId);
  if (!items.length) {
    wrap.innerHTML = '<div style="text-align:center;color:var(--muted);padding:32px">등록된 질문이 없습니다</div>';
    return;
  }
  const reorder = _faqReorder.item;
  wrap.innerHTML = items.map((q, i) => {
    const upId = i === 0 ? '' : items[i-1].id;
    const downId = i === items.length-1 ? '' : items[i+1].id;
    return `<div class="faq-item${q.active?'':' faq-item-off'}">
      <div class="faq-item-main">
        <div class="faq-item-label">${esc(q.label_ko)}${faqItemBadges(q)}</div>
        <div class="faq-item-sub">${esc(q.label_ja)}</div>
        ${faqStatBadges(q.id)}
      </div>
      <div class="faq-item-actions">
        ${reorder
          ? `<button class="btn btn-ghost btn-xs" ${upId?'':'disabled'} onclick="moveFaqNode('${esc(q.id)}','${esc(upId)}')">↑</button>
             <button class="btn btn-ghost btn-xs" ${downId?'':'disabled'} onclick="moveFaqNode('${esc(q.id)}','${esc(downId)}')">↓</button>`
          : `<label class="lookup-toggle" title="${q.active?'활성':'비활성'}"><input type="checkbox" ${q.active?'checked':''} onchange="toggleFaqNodeActive('${esc(q.id)}',this.checked)"><span class="lookup-toggle-slider"></span></label>
             <button class="btn btn-ghost btn-xs" onclick="openFaqEditModal('${esc(q.id)}','${esc(categoryId)}','item')">편집</button>
             <button class="btn btn-ghost btn-xs" style="color:#B3261E" onclick="deleteFaqItem('${esc(q.id)}')">삭제</button>`}
      </div>
    </div>`;
  }).join('');
}

// 질문 속성 배지 (handoff / 화면이동 / 단계 태그)
function faqItemBadges(q) {
  const out = [];
  if (q.is_human_handoff) out.push('<span class="badge badge-gold" style="font-size:9px;padding:1px 6px;margin-left:4px">직접문의</span>');
  if (q.action_type === 'navigate' && q.action_target) {
    out.push(`<span class="badge badge-blue" style="font-size:9px;padding:1px 6px;margin-left:4px">→ ${esc(FAQ_ACTION_LABEL_KO[q.action_target] || q.action_target)}</span>`);
  }
  (q.relevant_stages || []).forEach(s => {
    out.push(`<span class="badge badge-gray" style="font-size:9px;padding:1px 6px;margin-left:4px">${esc(FAQ_STAGE_LABEL_KO[s] || s)}</span>`);
  });
  return out.join('');
}

// 측정 배지 (조회수 · 직접문의 전환수 + 전환율 높으면 경고)
function faqStatBadges(nodeId) {
  const s = _faqStats[nodeId];
  if (!s || (!s.viewed && !s.handoff)) return '';
  // 직접문의 전환율 = handoff / (viewed + handoff). 50% 이상이면 부실 답변 경고
  const denom = s.viewed + s.handoff;
  const rate = denom ? Math.round((s.handoff / denom) * 100) : 0;
  const warn = denom >= 5 && rate >= 50;
  return `<div class="faq-stats">
    <span class="faq-stat">조회 ${s.viewed}</span>
    <span class="faq-stat">직접문의 ${s.handoff}</span>
    ${warn ? `<span class="faq-stat faq-stat-warn" title="직접문의 전환율이 높습니다 — 답변 보강 검토">전환율 ${rate}%</span>` : ''}
  </div>`;
}

// 카테고리 선택 → 우측 갱신
function selectFaqCategory(id) {
  _faqSelectedCatId = id;
  _faqReorder.item = false;
  const rb = $('btnFaqItemReorder');
  if (rb) rb.textContent = '순서 변경';
  renderFaqCategories();
  renderFaqItems(id);
}

// 순서변경 모드 토글 (category | item)
function toggleFaqReorder(kind) {
  _faqReorder[kind] = !_faqReorder[kind];
  const btn = $(kind === 'category' ? 'btnFaqCatReorder' : 'btnFaqItemReorder');
  if (btn) {
    btn.textContent = _faqReorder[kind] ? '완료' : '순서 변경';
    btn.classList.toggle('btn-primary', _faqReorder[kind]);
    btn.classList.toggle('btn-ghost', !_faqReorder[kind]);
  }
  if (kind === 'category') renderFaqCategories();
  else renderFaqItems(_faqSelectedCatId);
}

// 순서 위/아래 이동 — 인접 노드와 sort_order 교환
async function moveFaqNode(id, otherId) {
  if (!otherId) return;
  const a = _faqNodes.find(n => n.id === id);
  const b = _faqNodes.find(n => n.id === otherId);
  if (!a || !b) return;
  const r = await swapFaqNodeOrder(a.id, a.sort_order, b.id, b.sort_order);
  if (!r.ok) { toast('순서 변경 실패: ' + (r.error || ''), 'error'); return; }
  await refreshPane('faq');
}

// 활성 토글
async function toggleFaqNodeActive(id, active) {
  const r = await setFaqNodeActive(id, active);
  if (!r.ok) { toast('상태 변경 실패: ' + (r.error || ''), 'error'); await refreshPane('faq'); return; }
  const n = _faqNodes.find(x => x.id === id);
  if (n) n.active = !!active;
  toast('변경되었습니다');
}

// 카테고리 삭제 (자식 질문 cascade 경고)
async function deleteFaqCategory(id) {
  const cat = _faqNodes.find(n => n.id === id);
  if (!cat) return;
  const cnt = _faqItemsOf(id).length;
  const msg = cnt
    ? `카테고리 「${cat.label_ko}」 와 그 안의 질문 ${cnt}개가 모두 삭제됩니다. 계속할까요?`
    : `카테고리 「${cat.label_ko}」 를 삭제할까요?`;
  if (!confirm(msg)) return;
  const r = await deleteFaqNode(id);
  if (!r.ok) { toast('삭제 실패: ' + (r.error || ''), 'error'); return; }
  if (_faqSelectedCatId === id) _faqSelectedCatId = null;
  toast('삭제되었습니다');
  await refreshPane('faq');
}

// 질문 삭제
async function deleteFaqItem(id) {
  const q = _faqNodes.find(n => n.id === id);
  if (!q) return;
  if (!confirm(`질문 「${q.label_ko}」 를 삭제할까요?`)) return;
  const r = await deleteFaqNode(id);
  if (!r.ok) { toast('삭제 실패: ' + (r.error || ''), 'error'); return; }
  toast('삭제되었습니다');
  await refreshPane('faq');
}

// 선택 카테고리에 질문 추가
function openFaqAddItem() {
  if (!_faqSelectedCatId) { toast('먼저 카테고리를 선택하세요', 'error'); return; }
  openFaqEditModal(null, _faqSelectedCatId, 'item');
}

// 편집 모달 열기 (nodeId=null 이면 신규)
function openFaqEditModal(nodeId, parentId, kind) {
  const node = nodeId ? _faqNodes.find(n => n.id === nodeId) : null;
  const isCategory = kind === 'category';
  $('faqEditId').value = nodeId || '';
  $('faqEditParentId').value = parentId || (node ? node.parent_id || '' : '');
  $('faqEditKind').value = kind;
  $('faqModalTitle').textContent = (isCategory ? '카테고리 ' : '질문 ') + (nodeId ? '편집' : '추가');
  // 라벨 텍스트 (카테고리명 vs 질문 제목)
  const koLbl = isCategory ? '카테고리명 (한국어)' : '질문 제목 (한국어)';
  const jaLbl = isCategory ? '카테고리명 (일본어)' : '질문 제목 (일본어)';
  $('faqLabelKoLabel').innerHTML = koLbl + ' <span style="color:var(--red)">*</span>';
  $('faqLabelJaLabel').innerHTML = jaLbl + ' <span style="color:var(--red)">*</span>';
  $('faqLabelKo').value = node ? node.label_ko || '' : '';
  $('faqLabelJa').value = node ? node.label_ja || '' : '';
  // 카테고리는 답변·화면이동·단계·미리보기 숨김
  $('faqBodyGroup').style.display = isCategory ? 'none' : '';
  $('faqPreviewWrap').style.display = isCategory ? 'none' : '';
  $('faqBodyKo').value = node ? node.body_ko || '' : '';
  $('faqBodyJa').value = node ? node.body_ja || '' : '';
  $('faqActionTarget').value = node && node.action_type === 'navigate' ? (node.action_target || '') : '';
  $('faqActionLabelKo').value = node ? node.action_label_ko || '' : '';
  $('faqActionLabelJa').value = node ? node.action_label_ja || '' : '';
  $('faqHandoff').checked = node ? !!node.is_human_handoff : false;
  $('faqActive').checked = node ? !!node.active : true;
  const stages = (node && node.relevant_stages) || [];
  document.querySelectorAll('input[name="faqStage"]').forEach(cb => { cb.checked = stages.includes(cb.value); });
  onFaqActionTargetChange();
  onFaqHandoffChange();
  // 미리보기 초기화 (접힘)
  const pb = $('faqPreviewBox');
  if (pb) pb.style.display = 'none';
  $('faqPreviewToggleLabel').textContent = '미리보기 (일본어 화면)';
  const err = $('faqEditError');
  if (err) err.style.display = 'none';
  openModal('faqEditModal');
}

// 화면이동 선택 시 버튼 라벨 입력 노출
function onFaqActionTargetChange() {
  const has = !!$('faqActionTarget').value;
  $('faqActionLabelGroup').style.display = has ? '' : 'none';
}

// handoff 켜면 답변·화면이동은 무의미 → 안내 위해 비활성 처리하지 않고 그대로 둠(저장 시 정리)
function onFaqHandoffChange() { /* UI 토글만 — 저장 로직에서 일관 처리 */ }

// 저장
async function saveFaqNode() {
  const err = $('faqEditError');
  const setErr = (m) => { if (err) { err.textContent = m; err.style.display = ''; } };
  const id = $('faqEditId').value || null;
  const kind = $('faqEditKind').value;
  const labelKo = $('faqLabelKo').value.trim();
  const labelJa = $('faqLabelJa').value.trim();
  if (!labelKo || !labelJa) { setErr('한국어·일본어 제목을 모두 입력하세요.'); return; }
  const uid = currentUser?.id || null;
  const row = { label_ko: labelKo, label_ja: labelJa, active: $('faqActive').checked, updated_by: uid };
  if (kind === 'category') {
    row.kind = 'category'; row.parent_id = null;
  } else {
    row.kind = 'item';
    row.parent_id = $('faqEditParentId').value || null;
    if (!row.parent_id) { setErr('카테고리 정보가 없습니다.'); return; }
    row.body_ko = $('faqBodyKo').value.trim() || null;
    row.body_ja = $('faqBodyJa').value.trim() || null;
    const target = $('faqActionTarget').value;
    row.action_type = target ? 'navigate' : 'none';
    row.action_target = target || null;
    row.action_label_ko = target ? ($('faqActionLabelKo').value.trim() || null) : null;
    row.action_label_ja = target ? ($('faqActionLabelJa').value.trim() || null) : null;
    row.is_human_handoff = $('faqHandoff').checked;
    const stages = Array.from(document.querySelectorAll('input[name="faqStage"]:checked')).map(cb => cb.value);
    row.relevant_stages = stages.length ? stages : null;
  }
  // 신규는 sort_order 를 형제 노드 최대값 + 10 으로
  if (!id) {
    const siblings = kind === 'category' ? _faqCategories() : _faqItemsOf(row.parent_id);
    const maxSort = siblings.reduce((m, s) => Math.max(m, s.sort_order || 0), 0);
    row.sort_order = maxSort + 10;
    row.created_by = uid;
  }
  const r = id ? await updateFaqNode(id, row) : await insertFaqNode(row);
  if (!r.ok) { setErr('저장 실패: ' + (r.error || '')); return; }
  // 신규 카테고리면 자동 선택
  if (!id && kind === 'category' && r.data?.id) _faqSelectedCatId = r.data.id;
  closeModal('faqEditModal');
  toast('저장되었습니다');
  await refreshPane('faq');
}

// 미리보기 토글 — 일본어 본문을 인플루언서 화면처럼 렌더 (번호 단계 + 화면이동 버튼)
function toggleFaqPreview() {
  const box = $('faqPreviewBox');
  if (!box) return;
  const show = box.style.display === 'none';
  $('faqPreviewToggleLabel').textContent = show ? '미리보기 닫기' : '미리보기 (일본어 화면)';
  if (!show) { box.style.display = 'none'; return; }
  box.innerHTML = renderFaqPreviewHtml();
  box.style.display = '';
}

// 미리보기 HTML 생성 — 인플루언서 일본어 화면 흉내
function renderFaqPreviewHtml() {
  const handoff = $('faqHandoff').checked;
  const labelJa = $('faqLabelJa').value.trim();
  if (handoff) {
    return `<div class="faq-pv-title">${esc(labelJa || '(質問タイトル未入力)')}</div>
      <div class="faq-pv-body" style="color:var(--muted)">この質問は「直接お問い合わせ」につながります。</div>`;
  }
  const bodyJa = $('faqBodyJa').value;
  const target = $('faqActionTarget').value;
  const btnJa = $('faqActionLabelJa').value.trim() || (target ? '画面を開く' : '');
  // 본문을 줄 단위로 — 번호로 시작하는 줄은 단계로 강조
  const lines = (bodyJa || '').split('\n').map(l => l.trim()).filter(Boolean);
  const bodyHtml = lines.length
    ? lines.map(l => /^[0-9０-９]+[.\．、)]/.test(l)
        ? `<div class="faq-pv-step">${esc(l)}</div>`
        : `<div class="faq-pv-line">${esc(l)}</div>`).join('')
    : '<div class="faq-pv-line" style="color:var(--muted)">(回答本文未入力)</div>';
  const btnHtml = (target && btnJa)
    ? `<div class="faq-pv-btn"><span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">open_in_new</span> ${esc(btnJa)}</div>`
    : '';
  return `<div class="faq-pv-title">${esc(labelJa || '(質問タイトル未入力)')}</div>
    <div class="faq-pv-body">${bodyHtml}</div>${btnHtml}`;
}
