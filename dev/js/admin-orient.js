// ============================================================
// admin-orient.js — 브랜드 셀프 오리엔시트 관리자 발급·조회
// 신규 페인 #adminPane-orient-sheets: 목록 · 발급 모달 · 상세 모달 · 링크 복사
// 사양서 docs/specs/2026-06-18-brand-self-orient-sheet.md §7·§15
// 발급 함수 create_orient_sheet (마이그레이션 195, 2인자, is_admin 가드)
// §15 재설계: 1 링크 = 공통 브랜드 + 카드 N개(카드마다 form_type). data = cards 배열(§15-A)
// ============================================================

let _orientSheets = [];
let _osDetailSheet = null;   // 상세 모달에 열린 시트(카드별 발행에 사용)
let _osDetailCatMap = {};    // 상세 모달 카테고리 라벨 맵(새창 열기에 재사용)
let _osLastIssuedId = null;  // 방금 발급한 오리엔시트 id(발급 결과 화면 수동 메일 발송용)
let _osLastIssuedBrandId = null;  // 방금 발급한 시트의 브랜드 id(수신자 담당자 로드·저장용)
let _osBrandContacts = [];        // 발급 브랜드의 담당자 배열(드롭다운 소스)
let _osPendingContact = null;     // 발송 성공 후 저장 대기 중인 신규 담당자 {email, name}

const OS_TYPE_LABEL = { proxy_purchase: '가구매', reviewer: '리뷰어', seeding: '시딩' };
const OS_TYPE_CHIP = {
  proxy_purchase: { color: '#B45309', bg: '#FEF3E2' },
  reviewer:       { color: '#C41E3A', bg: '#FFF0F2' },
  seeding:        { color: '#1D4ED8', bg: '#E7F1FE' },
};
const OS_GRADE_LABEL = { nano: '나노', middle_mega: '미들·메가' };
const OS_STATUS = {
  draft:     { label: '작성 중', color: '#8A8A90', bg: '#F0F0F0' },
  submitted: { label: '제출됨', color: '#16A34A', bg: '#E8F5E9' },
  consumed:  { label: '발행됨', color: '#5B4B9E', bg: '#ECEAF6' },
  expired:   { label: '만료',   color: '#8A8A90', bg: '#F0F0F0' },
};
// 상태별 탭 (전체 + 4상태). code=null 은 전체
const OS_STATUS_TABS = [
  { code: null, label: '전체' },
  { code: 'draft', label: '작성 중' },
  { code: 'submitted', label: '제출됨' },
  { code: 'consumed', label: '발행됨' },
  { code: 'expired', label: '만료' },
];
let _orientActiveStatusTab = null;
const OS_CH_LABEL = { instagram: '인스타그램', x: 'X', tiktok: '틱톡', youtube: '유튜브', qoo10: 'Qoo10', lips: 'LIPS', atcosme: '@cosme' };

// 운영/개발 sales 도메인 분기 (orient.html SUPABASE_ENV 규칙과 동일)
function osSalesBase() {
  return /^(www\.)?globalreverb\.com$/.test(location.hostname)
    ? 'https://sales.globalreverb.com'
    : 'https://sales-dev.globalreverb.com';
}
function osBuildLink(token) { return osSalesBase() + '/orient?token=' + token; }

// 만료 판정 (조회 함수는 status 미전환 — 클라에서 함께 판정)
function osIsExpired(s) {
  if (s.status === 'consumed') return false;
  if (s.status === 'expired') return true;
  return !!(s.token_expires_at && new Date(s.token_expires_at) < new Date());
}
// 카드 발행 수 — 부분 발행(카드 일부만 발행) 판정용. published = campaign_id 있는 "발행된 카드 수".
// 삭제 경고용 osPublishedCampaignCount(DISTINCT 캠페인 수)와는 목적이 다름(정상 플로우는 카드당 고유 캠페인이라 값 일치).
function osCardCounts(s) {
  const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  return { total: cards.length, published: cards.filter(c => c && c.campaign_id).length };
}
// 상태 배지 — 부분 발행(제출됨 + 카드 일부만 발행)은 「일부 발행 (n/m)」 앰버 배지로 구분
function osStatusOf(s) {
  if (s.status === 'consumed') return OS_STATUS.consumed;
  if (s.status === 'submitted') {
    const { total, published } = osCardCounts(s);
    if (published > 0 && published < total) return { label: `일부 발행 (${published}/${total})`, color: '#B45309', bg: '#FEF3C7' };
    if (published > 0) return OS_STATUS.consumed;  // 전 카드 발행(마이그196 트리거 지연으로 status 미전환 순간) 방어
  }
  if (osIsExpired(s)) return OS_STATUS.expired;
  return OS_STATUS[s.status] || OS_STATUS.draft;
}
// 시트가 특정 탭에 속하는지 — 카드 상태 기준 「다중 소속」. 부분 발행 시트는 미발행 카드(제출됨)와
// 발행된 카드(발행됨)를 동시에 가지므로 제출됨·발행됨 양쪽 탭에 노출된다. (탭 건수 합이 전체보다 클 수 있음)
function osMatchesTab(s, code) {
  if (!code) return true;  // 전체
  const expired = osIsExpired(s) && s.status !== 'consumed';
  const { total, published } = osCardCounts(s);
  switch (code) {
    case 'draft':     return s.status === 'draft' && !expired;
    case 'submitted': return s.status === 'submitted' && (total === 0 || published < total) && !expired;  // 미발행 카드 남음(카드 0개 시트도 제출됨으로)
    case 'consumed':  return published > 0;                                              // 발행된 카드 있음(부분·완전)
    case 'expired':   return expired && published === 0;
    default: return false;
  }
}
function osBrandName(s) { return s.brands ? (s.brands.name || s.brands.name_ja || '-') : '-'; }
function osBadge(st) {
  return `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:${st.color};background:${st.bg}">${st.label}</span>`;
}
function osChLabel(c) { return OS_CH_LABEL[c] || (c || '채널'); }

// 형식 칩 (상세 모달 카드 헤더)
function osTypeChip(ft) {
  if (!ft) return '<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:#8A8A90;background:#F0F0F0">형식 미선택</span>';
  const c = OS_TYPE_CHIP[ft] || OS_TYPE_CHIP.reviewer;
  return `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:${c.color};background:${c.bg}">${OS_TYPE_LABEL[ft] || esc(ft)}</span>`;
}

// 목록 「형식」 컬럼 — form_type 컬럼은 NULL(카드별 형식)이라 data.cards 를 형식별로 집계
function osCardsSummary(data) {
  const cards = (data && Array.isArray(data.cards)) ? data.cards : [];
  if (!cards.length) return '<span style="color:var(--muted)">미작성</span>';
  const cnt = {};
  cards.forEach(c => { const ft = (c && c.form_type) || 'none'; cnt[ft] = (cnt[ft] || 0) + 1; });
  const parts = ['proxy_purchase', 'reviewer', 'seeding']
    .filter(ft => cnt[ft]).map(ft => `${OS_TYPE_LABEL[ft]} ${cnt[ft]}`);
  if (cnt.none) parts.push(`미선택 ${cnt.none}`);
  return esc(parts.join(' · '));
}

// ── 페인 진입 ──
async function loadOrientSheets() {
  ensureOrientModals();
  const tbody = document.getElementById('orientTableBody');
  if (tbody) tbody.innerHTML = osMsgRow('불러오는 중…');
  try {
    _orientSheets = await fetchOrientSheets();
  } catch (e) {
    console.error('[loadOrientSheets]', e);
    if (tbody) tbody.innerHTML = osMsgRow('목록을 불러오지 못했습니다.');
    return;
  }
  renderOrientSheets();
  refreshOrientBadge(_orientSheets);   // 방금 조회한 목록 재사용 (이중 fetch 방지)
}

// 사이드바 「오리엔시트 현황」 제출 배지 — 미발행 카드가 남은 시트 수(제출됨 탭 기준, 부분 발행 시트도 포함)
// cached: 호출부가 이미 가진 목록(loadOrientSheets). 없으면(부팅 단독 호출) 직접 조회
async function refreshOrientBadge(cached) {
  const el = $('adminOrientSheetsSi');
  if (!el) return;
  let count = 0;
  try {
    const sheets = cached || await fetchOrientSheets();
    count = sheets.filter(s => osMatchesTab(s, 'submitted')).length;   // 미발행 카드 남은 시트(부분 발행 포함)
  } catch (e) { console.error('[refreshOrientBadge]', e); return; }
  const badge = count > 0 ? `<span class="admin-si-badge">${count > 999 ? '999+' : count}</span>` : '';
  el.innerHTML = '<span class="si-icon material-icons-round notranslate" translate="no">assignment_turned_in</span><span class="si-text">오리엔시트 현황</span>' + badge;
}

function osMsgRow(msg) {
  return `<tr><td colspan="7" style="text-align:center;color:var(--muted);padding:24px">${esc(msg)}</td></tr>`;
}

function renderOrientSheets() {
  const tbody = document.getElementById('orientTableBody');
  if (!tbody) return;
  const q = (document.getElementById('orientSearch')?.value || '').trim().toLowerCase();
  // 검색 적용 후 base → 상태별 건수 계산 → 탭 렌더
  const base = _orientSheets.filter(s => !q || osBrandName(s).toLowerCase().includes(q));
  // 탭별 다중 소속 건수 — 부분 발행 시트는 제출됨·발행됨 양쪽에 카운트되므로 합이 전체보다 클 수 있음
  const counts = {};
  OS_STATUS_TABS.forEach(tab => { if (tab.code) counts[tab.code] = base.filter(s => osMatchesTab(s, tab.code)).length; });
  renderOrientStatusTabs(counts, base.length);

  // 선택된 상태 탭으로 필터 (다중 소속)
  const list = base.filter(s => osMatchesTab(s, _orientActiveStatusTab));

  const cnt = document.getElementById('orientTotalCount');
  if (cnt) cnt.textContent = list.length ? `${list.length}건` : '';

  if (!list.length) {
    const emptyMsg = (q && !base.length) ? '검색 결과가 없습니다.'
      : (_orientActiveStatusTab ? '해당 상태의 오리엔시트가 없습니다.'
        : '발급된 오리엔시트가 없습니다. 「신규 발급」으로 링크를 만들어 주세요.');
    tbody.innerHTML = osMsgRow(emptyMsg);
    return;
  }
  tbody.innerHTML = list.map(osRowHtml).join('');
}

// 상태 탭 바 렌더 (counts: 탭별 건수[다중 소속], totalAll: 전체 시트 수 — 탭별 합과 다를 수 있음)
function renderOrientStatusTabs(counts, totalAll) {
  const bar = document.getElementById('orientStatusTabBar');
  if (!bar) return;
  counts = counts || {};
  totalAll = totalAll || 0;
  bar.innerHTML = OS_STATUS_TABS.map(tab => {
    const n = tab.code === null ? totalAll : (counts[tab.code] || 0);
    const isOn = tab.code === _orientActiveStatusTab;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== null ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code || ''}" onclick="setOrientStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

// 상태 탭 클릭
function setOrientStatusTab(btn) {
  _orientActiveStatusTab = btn.dataset.status || null;   // 빈 문자열(전체)이면 null
  renderOrientSheets();
}

function osRowHtml(s) {
  const linkBadge = s.application_id
    ? ' <span style="display:inline-block;padding:1px 6px;border-radius:999px;font-size:10px;color:#8A8A90;background:#F0F0F0">신청연결</span>' : '';
  return `<tr>
    <td>${esc(osBrandName(s))}${linkBadge}</td>
    <td>${osCardsSummary(s.data)}</td>
    <td>${osBadge(osStatusOf(s))}</td>
    <td>${s.created_at ? formatDate(s.created_at) : '-'}</td>
    <td>${s.token_expires_at ? formatDate(s.token_expires_at) : '-'}</td>
    <td>${s.submitted_at ? formatDateTime(s.submitted_at) : '-'}</td>
    <td style="white-space:nowrap">
      <button type="button" class="btn btn-ghost btn-xs" onclick="osCopyLink('${s.id}')">링크 복사</button>
      <button type="button" class="btn btn-ghost btn-xs" onclick="osOpenDetail('${s.id}')">상세</button>
      <button type="button" class="btn btn-ghost btn-xs" style="color:#C41E3A" onclick="osOpenDelete('${s.id}')">삭제</button>
    </td>
  </tr>`;
}

// 시트에 연결된 발행 캠페인 수 (data.cards[].campaign_id DISTINCT)
function osPublishedCampaignCount(s) {
  const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const ids = new Set();
  cards.forEach(c => { if (c && c.campaign_id) ids.add(c.campaign_id); });
  return ids.size;
}

function osCopyLink(id) {
  const s = _orientSheets.find(x => x.id === id);
  if (!s) return;
  copyTextToClipboard(osBuildLink(s.token), '작성 링크가 복사되었습니다.');
}

// ── 발급 모달 ──
// 발급 모달 열기. opts 로 진입점별 컨텍스트 주입:
//   {} (무인자)          — #orient-sheets "신규 발급": 브랜드·신청 자유 선택
//   {brandId, appId}     — 서베이 목록 더보기: 신청 연결 고정
//   {brandId, lockBrand} — 브랜드 관리: 브랜드 고정·신청 없음
// 형식·제품은 발급 시 정하지 않음 — 브랜드가 작성 폼에서 카드마다 직접 고름(§15-11).
async function osOpenCreate(opts) {
  opts = opts || {};
  ensureOrientModals();
  document.getElementById('osCreateApp').innerHTML = '<option value="">연결 안 함</option>';
  document.getElementById('osCreateResult').style.display = 'none';
  document.getElementById('osCreateForm').style.display = '';
  document.getElementById('osCreateSubmitBtn').style.display = '';
  document.getElementById('orientCreateModal').classList.add('open');
  const sel = document.getElementById('osCreateBrand');
  sel.disabled = false;
  sel.innerHTML = '<option value="">불러오는 중…</option>';
  try {
    const brands = await fetchBrands();
    sel.innerHTML = '<option value="">브랜드 선택</option>' +
      (brands || []).map(b => `<option value="${b.id}">${esc(b.name || b.name_ja || '-')}</option>`).join('');
  } catch (e) {
    sel.innerHTML = '<option value="">브랜드 조회 실패</option>';
  }
  // 진입점 ②③ 컨텍스트 주입: 브랜드 고정 + (있으면) 신청 연결 선택
  if (opts.brandId) {
    sel.value = opts.brandId;
    if (opts.lockBrand) sel.disabled = true;
    if (opts.appId) {
      await osOnBrandChange();
      document.getElementById('osCreateApp').value = opts.appId;
    }
  }
}

// 진입점 ② — 브랜드 서베이(신청) 목록 더보기 「오리엔시트 링크생성」.
// admin-brand.js 의 _brandApps 캐시에서 신청을 찾아 브랜드·신청을 주입하며 발급 모달을 연다.
// (형식·제품은 발급 시 미지정 — 브랜드가 작성 폼에서 카드마다 선택)
function osIssueFromApplication(appId) {
  const apps = (typeof _brandApps !== 'undefined' && Array.isArray(_brandApps)) ? _brandApps : [];
  const a = apps.find(x => x.id === appId);
  if (!a) { toast('신청 정보를 찾을 수 없습니다. 목록을 새로고침해 주세요.'); return; }
  if (!a.brand_id) { toast('이 신청은 브랜드가 연결돼 있지 않아 오리엔시트를 발급할 수 없습니다.'); return; }
  osOpenCreate({ appId: appId, brandId: a.brand_id });
}

async function osOnBrandChange() {
  const brandId = document.getElementById('osCreateBrand').value;
  const appSel = document.getElementById('osCreateApp');
  appSel.innerHTML = '<option value="">연결 안 함</option>';
  if (!brandId) return;
  try {
    const apps = await fetchBrandApplicationsByBrand(brandId);
    appSel.innerHTML += (apps || []).map(a =>
      `<option value="${a.id}">${esc(osAppLabel(a))}</option>`).join('');
  } catch (e) { /* 연결 없이도 발급 가능 — 무시 */ }
}

function osAppLabel(a) {
  const t = a.form_type ? OS_TYPE_LABEL[a.form_type] : '';
  const d = a.created_at ? formatDate(a.created_at) : '';
  return [d, t].filter(Boolean).join(' · ') || '신청';
}

async function osSubmitCreate() {
  const brandId = document.getElementById('osCreateBrand').value;
  if (!brandId) { toast('브랜드를 선택해 주세요.'); return; }
  const appId = document.getElementById('osCreateApp').value || null;
  const btn = document.getElementById('osCreateSubmitBtn');
  btn.disabled = true;
  try {
    const res = await createOrientSheet(brandId, appId);
    if (!res || res.success !== true) { toast('발급 실패: ' + osReasonText(res?.reason)); return; }
    document.getElementById('osCreateLink').value = osBuildLink(res.token);
    document.getElementById('osCreateExpire').textContent = res.token_expires_at ? formatDate(res.token_expires_at) : '';
    document.getElementById('osCreateForm').style.display = 'none';
    document.getElementById('osCreateResult').style.display = '';
    btn.style.display = 'none';
    _osLastIssuedId = res.id;   // 발급 결과 화면의 「메일 발송」 버튼이 사용 (자동 발송 안 함 — 수동 선택)
    _osLastIssuedBrandId = brandId;
    _osPendingContact = null;
    // 브랜드만 선택한 건만 수신자 선택 UI 노출 (신청 연결 건은 신청 담당자 이메일 자동)
    if (!appId) { osLoadRecipients(brandId); }
    else { const pick = document.getElementById('osRecipientPick'); if (pick) pick.style.display = 'none'; }
    await refreshPane('orient-sheets');
  } catch (e) {
    toast(typeof friendlyError === 'function' ? friendlyError(e) : '발급에 실패했습니다.');
  } finally {
    btn.disabled = false;
  }
}

function osReasonText(r) {
  return ({
    brand_not_found: '브랜드를 찾을 수 없습니다',
    application_not_found: '신청을 찾을 수 없습니다',
    brand_mismatch: '신청과 브랜드가 일치하지 않습니다',
    no_db: '연결 오류',
  })[r] || (r || '알 수 없는 오류');
}

function osCopyResultLink() {
  copyTextToClipboard(document.getElementById('osCreateLink').value, '작성 링크가 복사되었습니다.');
}

// 발급 브랜드의 담당자 로드 → 수신자 드롭다운 채움 (브랜드만 선택 건). 대표 담당자 기본 선택.
async function osLoadRecipients(brandId) {
  const pick = document.getElementById('osRecipientPick');
  const sel = document.getElementById('osRecipientSelect');
  if (!pick || !sel) return;
  _osBrandContacts = [];
  let brand = null;
  try { brand = await fetchBrandById(brandId); } catch (_e) { /* 폴백: 직접 입력만 */ }
  let contacts = (brand && Array.isArray(brand.contacts)) ? brand.contacts.filter(c => c && c.email) : [];
  // contacts 비었는데 legacy primary_email 있으면 대표 1명으로 폴백
  if (!contacts.length && brand && brand.primary_email) {
    contacts = [{ name: brand.primary_contact_name || '', email: brand.primary_email, is_primary: true }];
  }
  _osBrandContacts = contacts;
  const primaryIdx = contacts.findIndex(c => c.is_primary);
  const defIdx = primaryIdx >= 0 ? primaryIdx : 0;
  let html = contacts.map((c, i) =>
    `<option value="${i}">${esc((c.name ? c.name + ' · ' : '') + c.email)}${c.is_primary ? ' (대표)' : ''}</option>`
  ).join('');
  html += '<option value="new">+ 직접 입력</option>';
  sel.innerHTML = html;
  sel.value = contacts.length ? String(defIdx) : 'new';
  pick.style.display = '';
  osOnRecipientChange();
}

// 드롭다운에서 「직접 입력」 선택 시 이름·이메일 입력칸 표시
function osOnRecipientChange() {
  const sel = document.getElementById('osRecipientSelect');
  const nw = document.getElementById('osRecipientNew');
  if (!sel || !nw) return;
  nw.style.display = (sel.value === 'new') ? '' : 'none';
}

// 발급 결과 화면 「메일 발송」 버튼 — 선택 발송(자동 발송 아님). 발송 중 버튼 비활성.
async function osSendInviteClick(btn) {
  if (!_osLastIssuedId) return;
  // 브랜드만 선택 건: 드롭다운/직접입력으로 수신자 명시. 신청 연결 건: recipient 없이 자동 결정.
  let recipient = null;
  let isNewContact = false;
  const pick = document.getElementById('osRecipientPick');
  if (pick && pick.style.display !== 'none') {
    const sel = document.getElementById('osRecipientSelect');
    if (sel && sel.value === 'new') {
      const email = (document.getElementById('osNewContactEmail').value || '').trim();
      const name = (document.getElementById('osNewContactName').value || '').trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { toast('올바른 이메일 주소를 입력해 주세요.'); return; }
      // 기존 담당자와 중복이면 재사용(신규 저장 안 함)
      const dup = _osBrandContacts.find(c => (c.email || '').trim().toLowerCase() === email.toLowerCase());
      recipient = dup ? { email: dup.email, name: dup.name || name } : { email, name };
      isNewContact = !dup;
    } else if (sel) {
      const c = _osBrandContacts[Number(sel.value)];
      if (c) recipient = { email: c.email, name: c.name || '' };
    }
    if (!recipient) { toast('수신자를 선택해 주세요.'); return; }
  }
  btn.disabled = true;
  try { await osSendInviteAndShow(_osLastIssuedId, recipient, isNewContact); }
  finally { btn.disabled = false; }
}

// 메일 발송 + 발급 결과 화면에 상태 인라인 표시. 발송은 발급과 별개라 실패해도 발급은 유효(링크 수동 복사).
// 신규 담당자(직접 입력·중복 아님)면 발송 성공 후 「브랜드에 저장 + 대표 설정?」 버튼 노출.
async function osSendInviteAndShow(orientSheetId, recipient, isNewContact) {
  const box = document.getElementById('osCreateMailStatus');
  if (!box) return;
  box.innerHTML = '<span style="color:var(--muted)">메일 발송 중…</span>';
  let r;
  try {
    r = await sendOrientInviteMail(orientSheetId, recipient);
  } catch (e) {
    r = { sent: false, error: (e && e.message) || 'unknown' };
  }
  if (r && r.sent) {
    const advNote = r.advanced ? '신청 단계를 「오리엔시트 발송됨」으로 이동했습니다.' : '';
    let html = '<div style="color:#16A34A;font-weight:600">메일을 보냈습니다 — ' +
      esc(r.recipient || (recipient && recipient.email) || '') + '</div>' +
      (advNote ? '<div style="color:var(--muted);font-size:12px;margin-top:2px">' + advNote + '</div>' : '');
    if (isNewContact && recipient && recipient.email) {
      _osPendingContact = { email: recipient.email, name: recipient.name || '' };
      html += '<div style="margin-top:10px;padding:10px;background:#FAFAF7;border-radius:8px">'
        + '<div style="font-size:13px;margin-bottom:6px">이 담당자를 브랜드에 저장합니다. 대표 담당자로도 설정할까요?</div>'
        + '<div style="display:flex;gap:6px;flex-wrap:wrap">'
        + '<button type="button" class="btn btn-primary btn-xs" onclick="osSaveIssuedContact(true,this)">대표 담당자로 저장</button>'
        + '<button type="button" class="btn btn-ghost btn-xs" onclick="osSaveIssuedContact(false,this)">담당자로만 저장</button>'
        + '</div></div>';
    }
    box.innerHTML = html;
  } else if (r && r.reason === 'no_recipient') {
    box.innerHTML = '<div style="color:#B45309;font-weight:600">수신자 이메일이 없어 메일을 보내지 못했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 브랜드에게 직접 전달해 주세요.</div>';
  } else {
    box.innerHTML = '<div style="color:#C41E3A;font-weight:600">메일 발송에 실패했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 직접 전달하거나, 잠시 후 다시 시도해 주세요.</div>';
  }
}

// 신규 담당자를 브랜드(brands.contacts)에 저장. asPrimary=true 면 대표로 설정 + legacy primary_* 동기화.
// admin-brand.js 「대표 1개 보장·빈 행 제외」 규칙과 정합. 중복 이메일이면 기존 행 재사용.
async function osSaveIssuedContact(asPrimary, btn) {
  if (!_osPendingContact || !_osLastIssuedBrandId) return;
  if (btn) btn.disabled = true;
  try {
    const brand = await fetchBrandById(_osLastIssuedBrandId);   // 최신 contacts (덮어쓰기 최소화)
    let contacts = (brand && Array.isArray(brand.contacts)) ? brand.contacts.slice() : [];
    const email = (_osPendingContact.email || '').trim();
    let row = contacts.find(c => (c.email || '').trim().toLowerCase() === email.toLowerCase());
    if (!row) {
      const cid = (typeof _genContactId === 'function') ? _genContactId() : ('c' + contacts.length + '_' + email);
      row = { id: cid, name: _osPendingContact.name || '', phone: '', email, is_primary: false };
      contacts.push(row);
    } else if (_osPendingContact.name && !row.name) {
      row.name = _osPendingContact.name;
    }
    if (asPrimary) contacts.forEach(c => { c.is_primary = (c === row); });
    else if (!contacts.some(c => c.is_primary) && contacts.length) contacts[0].is_primary = true;
    const patch = { contacts };
    const primary = contacts.find(c => c.is_primary);
    if (primary) {
      patch.primary_email = primary.email || '';
      patch.primary_contact_name = primary.name || '';
      patch.primary_phone = primary.phone || '';
    }
    await updateBrand(_osLastIssuedBrandId, patch);
    const box = document.getElementById('osCreateMailStatus');
    if (box) box.innerHTML += '<div style="color:#16A34A;font-size:12px;margin-top:6px">담당자를 저장했습니다'
      + (asPrimary ? ' (대표 담당자로 설정)' : '') + '.</div>';
    _osPendingContact = null;
  } catch (e) {
    toast(typeof friendlyError === 'function' ? friendlyError(e) : '담당자 저장에 실패했습니다.');
    if (btn) btn.disabled = false;
  }
}

// ── 삭제 모달 (브랜드명 재입력 확인 — 캠페인 삭제 패턴 미러) ──
let _osDeleteId = null;
let _osDeleteBrandName = '';

function osOpenDelete(id) {
  ensureOrientModals();
  const s = _orientSheets.find(x => x.id === id);
  if (!s) { toast('시트 정보를 찾을 수 없습니다. 목록을 새로고침해 주세요.'); return; }
  _osDeleteId = id;
  _osDeleteBrandName = osBrandName(s);
  const campCount = osPublishedCampaignCount(s);

  document.getElementById('osDeleteBrand').textContent = _osDeleteBrandName;
  document.getElementById('osDeleteBrandEcho').textContent = _osDeleteBrandName;
  const warn = document.getElementById('osDeleteCampWarn');
  if (campCount > 0) {
    warn.innerHTML = '이 오리엔시트에 연결된 발행 캠페인 <b>' + campCount + '개</b>도 함께 삭제됩니다. ' +
      '단, 신청이 1건이라도 있는 캠페인이 포함되면 삭제할 수 없습니다.';
    warn.style.display = '';
  } else {
    warn.style.display = 'none';
  }
  const input = document.getElementById('osDeleteConfirmInput');
  input.value = '';
  document.getElementById('osDeleteError').style.display = 'none';
  osCheckDeleteConfirm();
  document.getElementById('orientDeleteModal').classList.add('open');
  input.focus();
}

function osCheckDeleteConfirm() {
  const v = (document.getElementById('osDeleteConfirmInput').value || '').trim();
  const btn = document.getElementById('osDeleteBtn');
  const ok = v === _osDeleteBrandName && !!_osDeleteBrandName;
  btn.disabled = !ok;
  btn.style.opacity = ok ? '1' : '.4';
  btn.style.cursor = ok ? 'pointer' : 'not-allowed';
}

async function osExecuteDelete() {
  const v = (document.getElementById('osDeleteConfirmInput').value || '').trim();
  const err = document.getElementById('osDeleteError');
  if (v !== _osDeleteBrandName) { err.textContent = '브랜드명이 일치하지 않습니다.'; err.style.display = 'block'; return; }
  const btn = document.getElementById('osDeleteBtn');
  btn.disabled = true;
  try {
    const res = await deleteOrientSheet(_osDeleteId);
    if (res && res.success) {
      osCloseModal('orientDeleteModal');
      const n = Array.isArray(res.deleted_campaign_ids) ? res.deleted_campaign_ids.length : 0;
      toast(n > 0 ? ('오리엔시트와 연결 캠페인 ' + n + '개를 삭제했습니다.') : '오리엔시트를 삭제했습니다.', 'success');
      await refreshPane('orient-sheets');
    } else if (res && res.reason === 'blocked_has_applications') {
      const n = Array.isArray(res.campaign_ids) ? res.campaign_ids.length : 0;
      err.textContent = '연결 캠페인 중 신청이 있는 캠페인(' + n + '개)이 있어 삭제할 수 없습니다. 신청을 먼저 정리해 주세요.';
      err.style.display = 'block';
    } else if (res && res.reason === 'permission_denied') {
      err.textContent = '삭제 권한이 없습니다.';
      err.style.display = 'block';
    } else {
      err.textContent = '삭제 실패: ' + ((res && res.reason) || '알 수 없는 오류');
      err.style.display = 'block';
    }
  } catch (e) {
    err.textContent = '삭제 오류: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || '오류'));
    err.style.display = 'block';
  } finally {
    osCheckDeleteConfirm();
  }
}

// ── 상세 모달 ──
async function osOpenDetail(id) {
  ensureOrientModals();
  const body = document.getElementById('osDetailBody');
  body.innerHTML = '<p style="color:var(--muted);padding:8px">불러오는 중…</p>';
  document.getElementById('orientDetailModal').classList.add('open');
  let s;
  try { s = await fetchOrientSheetById(id); }
  catch (e) { body.innerHTML = '<p style="padding:8px">불러오지 못했습니다.</p>'; return; }
  if (!s) { body.innerHTML = '<p style="padding:8px">데이터가 없습니다.</p>'; return; }
  _osDetailSheet = s;
  // 카테고리는 code 로 저장되므로 한국어 라벨로 변환해 표시 (캠페인 폼과 동일 기준 데이터)
  let catMap = {};
  try { const cats = await fetchLookups('category'); catMap = Object.fromEntries((cats || []).map(c => [c.code, c.name_ko])); } catch (_) {}
  _osDetailCatMap = catMap;
  body.innerHTML = osDetailHtml(s, catMap);
}

// 상세 내용을 브라우저 새창에 읽기 전용으로 출력 (인쇄·나란히 보기 용)
function osOpenDetailNewWindow() {
  const s = _osDetailSheet;
  if (!s) return;
  const inner = osDetailHtml(s, _osDetailCatMap || {}, true);   // readonly=true → 발행 버튼 제외
  const w = window.open('', '_blank');
  if (!w) { toast('팝업이 차단되었습니다. 브라우저에서 팝업을 허용한 뒤 다시 시도해 주세요.'); return; }
  w.document.write('<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">'
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>오리엔시트 — ' + esc(osBrandName(s)) + '</title>'
    + '<style>body{font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;'
    + 'margin:0;padding:24px;background:#f5f5f7;color:#161618;max-width:1000px}</style>'
    + '</head><body>' + inner + '</body></html>');
  w.document.close();
}

// 상세 모달 전용 스코프 스타일 (가독성: 항목 구분선 + 라벨/값 위계 + 카드 제목)
const OS_DETAIL_STYLE = `<style>
  .os-detail{container-type:inline-size}
  .os-card{border:1px solid #ececf0;border-radius:12px;padding:14px 16px;margin-bottom:14px;background:#fff}
  .os-card-title{font-weight:800;font-size:14px;color:#161618;margin-bottom:2px}
  .os-card-head{display:flex;align-items:center;gap:8px;margin-bottom:2px;padding-bottom:8px}
  .os-card-head .os-name{font-weight:800;font-size:14.5px;color:#161618;flex:1;min-width:0}
  /* 모달(컨테이너) 너비에 따라 2열/1열 — 브랜드 입력 폼과 동일 반응형 */
  .os-fields{display:grid;grid-template-columns:1fr;gap:0 20px}
  @container (min-width:480px){.os-fields{grid-template-columns:1fr 1fr}}
  .os-fields .os-field{padding:9px 0;border-top:1px solid #f2f2f2;min-width:0}
  .os-field-wide{grid-column:1/-1}
  .os-field-label{color:var(--muted,#8a8a90);font-size:11px;font-weight:700;letter-spacing:.02em;margin-bottom:3px}
  .os-field-val{font-size:13.5px;line-height:1.65;color:#161618;word-break:break-word}
  .os-field-val a{color:var(--pink,#E8344E);text-decoration:underline}
  .os-empty{color:#bbb;font-weight:400}
</style>`;

function osDetailHtml(s, catMap, readonly) {
  const d = s.data || {};
  const cards = Array.isArray(d.cards) ? d.cards : [];
  const headerHtml = `<div style="margin-bottom:14px">
    <div style="font-size:16px;font-weight:800;color:#161618">${esc(osBrandName(s))}</div>
  </div>`;
  // 상태 배지 + 모집 건수 줄 — 브랜드 정보 카드와 제품(모집 건) 카드 사이에 배치
  const statusLine = `<div style="margin:16px 0 10px">${osBadge(osStatusOf(s))}`
    + `<span style="margin-left:6px;color:var(--muted);font-size:12px">${cards.length ? cards.length + '개 모집 건' : ''}</span></div>`;
  const brandCard = osBrandCard(d.brand, osBrandName(s));
  let bodyHtml;
  if (!cards.length) {
    const msg = (s.status === 'draft')
      ? '아직 작성 전입니다. 브랜드가 작성하면 여기에 표시됩니다.'
      : '작성된 모집 건이 없습니다.';
    bodyHtml = brandCard + statusLine + `<p style="color:var(--muted)">${msg}</p>`;
  } else {
    bodyHtml = brandCard + statusLine + cards.map((c, i) => osCardDetail(c, i, catMap, readonly)).join('');
  }
  return OS_DETAIL_STYLE + `<div class="os-detail">${headerHtml}${bodyHtml}</div>`;
}

function osFieldRow(label, valHtml, wide) {
  return `<div class="os-field${wide ? ' os-field-wide' : ''}"><div class="os-field-label">${label}</div><div class="os-field-val">${valHtml}</div></div>`;
}
function osField(label, val, wide) {
  const v = (val == null || val === '') ? '<span class="os-empty">미입력</span>' : esc(String(val));
  return osFieldRow(label, v, wide);
}
// 값이 이미 안전한 HTML(링크 등 — 호출부가 esc·화이트리스트 보장)일 때. esc 미적용.
function osFieldHtml(label, htmlVal, wide) {
  const v = htmlVal ? htmlVal : '<span class="os-empty">미입력</span>';
  return osFieldRow(label, v, wide);
}
function osRange(a, b) { return (a || b) ? `${a || '?'} ~ ${b || '?'}` : ''; }

// 공통 브랜드 카드 (1회). headerName: 모달 헤더의 발급 브랜드 마스터명 — 작성 브랜드명과 같으면 중복이라 생략
function osBrandCard(brand, headerName) {
  const b = brand || {};
  // 작성된 브랜드명이 헤더와 동일하면 생략(중복), 다르거나 미입력이면 표시
  const nameField = (b.name && b.name.trim() === String(headerName || '').trim()) ? '' : osField('브랜드명', b.name);
  const inner = nameField + osField('소개·어필', b.intro, true) + osField('공식 계정', b.official_accounts, true);
  return `<div class="os-card">
    <div class="os-card-title">브랜드 정보</div>
    <div class="os-fields">${inner}</div></div>`;
}

// 카드(모집 건) 1개 상세 — 형식별 항목 분기(§15-12)
function osCardDetail(c, idx, catMap, readonly) {
  const ft = (c && c.form_type) || '';
  const p = c.product || {};
  const r = c.recruit || {};
  const sale = c.sale || {};
  const sd = c.seeding || {};
  const catLabel = (catMap && catMap[p.category]) || p.category;

  let inner = osField('카테고리', catLabel) + osField('모집 인원', p.slots)
    + osField('희망 모집 기간', osRange(r.recruit_start, r.recruit_end));

  if (ft === 'proxy_purchase' || ft === 'reviewer' || ft === 'seeding') {
    inner += osField('판매처', sale.market || 'Qoo10') + osFieldHtml('판매 URL', osLinkOrText(sale.url), true)
      + osField('상시가', sale.price_regular);
  }
  if (ft === 'reviewer') {
    inner += osField('엣코스메 희망', sale.atcosme_wish ? '희망' : '비희망');
    if (sale.atcosme_wish) inner += osFieldHtml('엣코스메 링크', osLinkOrText(sale.atcosme_url), true);
    inner += osFieldHtml('리뷰 가이드', sanitizeCautionHtml(c.review_guide), true);
  }
  if (ft === 'seeding') {
    inner += osField('등급', OS_GRADE_LABEL[sd.grade] || sd.grade);
    const guides = Array.isArray(sd.guides) ? sd.guides.filter(g => g && (g.channel || g.guide)) : [];
    inner += guides.length
      ? guides.map(g => osField('채널 소구 — ' + osChLabel(g.channel), g.guide, true)).join('')
      : osField('채널별 소구 키워드', '', true);
    inner += osField('촬영 가이드', sd.shooting_guide, true)
      + osField('해시태그', Array.isArray(sd.hashtags) ? sd.hashtags.join(' ') : (sd.hashtags || ''))
      + osField('계정 태그', sd.account_tags);
    if (sd.grade === 'middle_mega') {
      inner += osField('필수 내용', sd.required_content, true) + osField('증정품', sd.gift);
    }
    inner += osField('배송 안내', sd.shipping_note, true);
  }
  inner += osFieldHtml('금지 표현(NG)', sanitizeCautionHtml(c.ng), true) + osFieldHtml('추가 안내', sanitizeCautionHtml(c.cautions), true) + osImagesInline(c.images);
  if (!ft) inner = '<div style="color:var(--muted);font-size:12px;margin-bottom:8px">브랜드가 아직 형식을 고르지 않았습니다.</div>' + inner;

  const head = `<div class="os-card-head">
    ${osTypeChip(ft)}<span class="os-name">${esc(p.name || ('제품 ' + (idx + 1)))}</span>${osCardPublishControl(c, idx, readonly)}</div>`;
  return `<div class="os-card">${head}<div class="os-fields">${inner}</div></div>`;
}

// 카드 헤더 우측 — 발행 버튼(제출됨·미발행·형식 선택) / 발행됨 배지 / 형식 미선택 안내
function osCardPublishControl(c, idx, readonly) {
  if (readonly) return '';   // 새창(읽기 전용)에서는 발행 버튼 숨김
  const s = _osDetailSheet;
  if (c && c.campaign_id) {
    return '<span style="flex-shrink:0;display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:#16A34A;background:#E8F5E9">발행됨</span>';
  }
  if (s && s.status === 'submitted') {
    if (!c || !c.form_type) return '<span style="flex-shrink:0;color:var(--muted);font-size:11px">형식 미선택</span>';
    return `<button type="button" class="btn btn-primary btn-xs" style="flex-shrink:0" onclick="osPublishCard(${idx})">이 카드로 발행</button>`;
  }
  return '';   // draft(미제출)·expired 는 발행 버튼 없음
}

// 브랜드 입력 URL은 서버 검증이 없으므로(직접 RPC 호출 우회 가능) http/https만 링크 허용
function osImgSafe(u) {
  try { const p = new URL(u).protocol; return p === 'https:' || p === 'http:'; }
  catch (e) { return false; }
}
function osLinkOrText(u) {
  if (!u) return '';
  const disp = esc(u);
  return osImgSafe(u) ? `<a href="${disp}" target="_blank" rel="noopener">${disp}</a>` : disp;
}
function osImagesInline(images) {
  const imgs = Array.isArray(images) ? images.filter(x => x && x.value) : [];
  if (!imgs.length) return '';
  const inner = imgs.map(x => {
    const disp = esc(x.value);
    return osImgSafe(x.value)
      ? `<div style="margin-bottom:4px"><a href="${disp}" target="_blank" rel="noopener">${disp}</a></div>`
      : `<div style="margin-bottom:4px;color:var(--muted)">${disp} <span style="font-size:10px">(링크 차단)</span></div>`;
  }).join('');
  return osFieldRow('예시 이미지·자료', inner, true);
}

// ── 카드 → 캠페인 발행 (자동 채움) ──
// 상세 모달 카드 「이 카드로 발행」 → 캠페인 등록 폼에 prefill + 발행 컨텍스트 주입.
// 일본어 게이트·발행 소비(markOrientCardConsumed)는 addCampaign 이 컨텍스트를 보고 처리.
async function osPublishCard(cardIdx) {
  const s = _osDetailSheet;
  if (!s) return;
  if (s.status !== 'submitted') { toast('제출된 오리엔시트만 발행할 수 있습니다.'); return; }
  const cards = (s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const card = cards[cardIdx];
  if (!card) return;
  if (card.campaign_id) { toast('이미 발행된 카드입니다.'); return; }
  if (!card.form_type) { toast('형식이 선택되지 않은 카드는 발행할 수 없습니다.'); return; }
  osCloseModal('orientDetailModal');
  try {
    await applyOrientCardPrefill(card, s.data.brand || {}, s.brand_id, s.application_id, s.id, cardIdx);
  } catch (e) {
    console.error('[osPublishCard]', e);
    toast('자동 채움 중 오류가 발생했습니다. 폼을 직접 확인해 주세요.');
  }
}

function osSetVal(id, val) { const el = document.getElementById(id); if (el) el.value = (val == null ? '' : String(val)); }
function osPriceNum(v) { const n = parseInt(String(v == null ? '' : v).replace(/[^0-9]/g, ''), 10); return isNaN(n) ? '' : n; }

// 시딩=게시 채널 / 리뷰어·가구매=판매처(마켓)를 채널 코드로
function osPrefillChannels(card) {
  if (card.form_type === 'seeding') {
    return (card.seeding && Array.isArray(card.seeding.channels)) ? card.seeding.channels.filter(Boolean) : [];
  }
  const map = { 'Qoo10': 'qoo10', '@cosme': 'atcosme', 'LIPS': 'lips' };
  const m = (card.sale && card.sale.market) || '';
  return map[m] ? [map[m]] : [];
}

// 가격·행사를 리워드 안내 텍스트로 보존 (캠페인 reward_note)
function osBuildRewardNote(card) {
  const s = card.sale || {};
  const parts = [];
  if (card.form_type === 'proxy_purchase') parts.push('[가구매] 영수증만 제출 (리뷰·게시 없음)');
  if (s.price_regular) parts.push('상시가 ' + s.price_regular);
  return parts.join(' / ');
}

// 평문 → 리치 텍스트 HTML (이스케이프 + 줄바꿈)
function osPlainToRich(t) {
  if (!t) return '';
  return esc(String(t)).replace(/\n/g, '<br>');
}
// 리치 텍스트(HTML) → 평문 (가이드 초안용 — 줄바꿈 보존, 태그 제거)
function osStripHtml(html) {
  if (!html) return '';
  const d = document.createElement('div');
  d.innerHTML = String(html).replace(/<br\s*\/?>/gi, '\n').replace(/<\/p>/gi, '\n');
  return (d.textContent || '').trim();
}

// 카드 한국어 콘텐츠를 가이드 초안으로 합침 (관리자가 일본어로 번역)
function osBuildGuideDraft(card) {
  const blocks = [];
  if (card.form_type === 'reviewer' && card.review_guide) blocks.push('[리뷰 가이드]\n' + osStripHtml(card.review_guide));
  if (card.form_type === 'seeding') {
    const sd = card.seeding || {};
    (Array.isArray(sd.guides) ? sd.guides : []).forEach(g => {
      if (g && g.guide) blocks.push('[' + osChLabel(g.channel) + ']\n' + g.guide);
    });
    if (sd.shooting_guide) blocks.push('[촬영 가이드]\n' + sd.shooting_guide);
    if (sd.required_content) blocks.push('[필수 내용]\n' + sd.required_content);
    if (sd.gift) blocks.push('[증정품] ' + sd.gift);
    if (sd.shipping_note) blocks.push('[배송 안내] ' + sd.shipping_note);
    if (sd.account_tags) blocks.push('[태그 계정] ' + sd.account_tags);
  }
  if (card.cautions) blocks.push('[추가 안내]\n' + osStripHtml(card.cautions));
  if (card.ng) blocks.push('[NG]\n' + osStripHtml(card.ng));
  return blocks.map(osPlainToRich).join('<br><br>');
}

// 캠페인 등록 폼에 카드 내용 자동 채움. 한국어는 _ko 칸·가이드 초안에, 일본어 표시칸(제목·제품명)은 비워 관리자 보완.
async function applyOrientCardPrefill(card, brand, brandId, appId, orientId, cardIdx) {
  if (typeof switchAdminPane === 'function') switchAdminPane('add-campaign', null);
  // 발행 컨텍스트 — switchAdminPane 이 add-campaign 진입 시 초기화하므로 그 직후 세팅.
  // addCampaign 이 일본어 게이트·발행 소비·가구매 플래그에 사용.
  window._orientPublishCtx = { orientId: orientId, cardIdx: cardIdx, isProxy: card.form_type === 'proxy_purchase' };
  const ft = card.form_type;
  const recruitType = (ft === 'seeding') ? 'gifting' : 'monitor';   // 가구매·리뷰어→리뷰어(monitor), 시딩→기프팅

  // 브랜드 선택 + cascade (native select)
  if (typeof loadCampBrandSelect === 'function') await loadCampBrandSelect('new', brandId);
  osSetVal('newCampBrandId', brandId || '');
  if (typeof onCampBrandChange === 'function') await onCampBrandChange('new');
  if (appId) {
    osSetVal('newCampSourceAppId', appId);
    if (typeof _srcAppSyncTrigger === 'function') _srcAppSyncTrigger('new');
  }

  // recruitType 라디오 (인라인 onchange 로 채널·팔로워 영역 갱신)
  const rt = document.querySelector(`input[name="recruitType"][value="${recruitType}"]`);
  if (rt) { rt.checked = true; rt.dispatchEvent(new Event('change')); }

  // 채널·카테고리 렌더
  if (typeof renderChannelCheckboxes === 'function') await renderChannelCheckboxes('new', recruitType, osPrefillChannels(card));
  if (typeof renderCategorySelect === 'function') await renderCategorySelect('new', (card.product && card.product.category) || '');

  // 텍스트 (한국어→_ko, 일본어 표시칸은 비움 → 일본어 게이트가 보완 유도)
  const p = card.product || {};
  osSetVal('newCampProductKo', p.name || '');
  osSetVal('newCampProduct', '');
  osSetVal('newCampTitle', '');
  osSetVal('newCampSlots', p.slots || '');
  osSetVal('newCampProductUrl', (card.sale && card.sale.url) || '');
  osSetVal('newCampProductPrice', osPriceNum(card.sale && card.sale.price_regular));
  osSetVal('newCampRewardNote', osBuildRewardNote(card));
  if (card.form_type === 'seeding') osSetVal('newCampHashtags', Array.isArray(card.seeding && card.seeding.hashtags) ? card.seeding.hashtags.join(' ') : '');

  // 날짜 (희망 모집 기간) — flatpickr range + deadline
  const r = card.recruit || {};
  if (typeof applyCampRangeValues === 'function') {
    applyCampRangeValues('newCamp', { recruit: [r.recruit_start || null, r.recruit_end || null], purchase: [null, null], visit: [null, null] });
  }
  osSetVal('newCampRecruitStart', r.recruit_start || '');
  osSetVal('newCampDeadline', r.recruit_end || '');

  // 리치 텍스트 (한국어 초안 — 관리자 일본어 번역)
  if (typeof setRichValue === 'function') {
    setRichValue('newCampGuide', osBuildGuideDraft(card));
    const osSdGuides = (card.seeding && Array.isArray(card.seeding.guides)) ? card.seeding.guides : [];
    const osSeedingAppeal = osSdGuides.filter(g => g && g.guide).map(g => g.guide).join('\n');
    setRichValue('newCampAppeal', osPlainToRich(osSeedingAppeal));
    setRichValue('newCampDesc', osPlainToRich(brand.intro || ''));
  }

  toast('오리엔시트 내용을 채웠습니다. 일본어(제목·제품명·가이드)를 보완한 뒤 발행해 주세요.');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function osCloseModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.remove('open');
}

// ── 모달 DOM 1회 생성 (기존 .modal-overlay/.modal/.modal-body 클래스 재사용) ──
function ensureOrientModals() {
  if (document.getElementById('orientCreateModal')) return;
  const html = `
  <div class="modal-overlay" id="orientCreateModal">
    <div class="modal" style="max-width:480px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>오리엔시트 링크 발급</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientCreateModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px;overflow-y:auto;flex:1">
        <div id="osCreateForm">
          <div class="form-group"><label class="form-label">브랜드 <span style="color:var(--pink,#E8344E)">*</span></label>
            <select id="osCreateBrand" class="form-input" onchange="osOnBrandChange()"></select></div>
          <div class="form-group"><label class="form-label">광고주 신청 연결 (선택)</label>
            <select id="osCreateApp" class="form-input"><option value="">연결 안 함</option></select>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">신청을 연결하면 그 신청의 모집 희망값을 작성 폼 첫 카드에 미리 채웁니다.</div></div>
          <div style="font-size:12px;color:var(--muted);background:#FAFAF7;border-radius:8px;padding:10px;margin-top:4px">
            모집 형식(가구매·리뷰어·시딩)과 제품은 브랜드가 작성 폼에서 카드마다 직접 추가·선택합니다.</div>
        </div>
        <div id="osCreateResult" style="display:none">
          <p style="font-weight:700;margin-bottom:8px">발급되었습니다. 아래 링크를 브랜드에게 전달하세요.</p>
          <div style="display:flex;gap:6px;align-items:center">
            <input type="text" id="osCreateLink" class="form-input" readonly onclick="this.select()" style="flex:1;min-width:0">
            <button type="button" class="btn btn-ghost btn-sm" onclick="osCopyResultLink()" title="링크 복사" style="flex-shrink:0;padding:8px"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;vertical-align:middle">content_copy</span></button>
          </div>
          <div style="font-size:12px;color:var(--muted);margin-top:6px">작성 기한: <span id="osCreateExpire"></span></div>
          <div id="osRecipientPick" style="display:none;margin-top:12px">
            <label style="display:block;font-size:12px;font-weight:600;color:var(--muted);margin-bottom:4px">메일 받을 담당자</label>
            <select id="osRecipientSelect" class="form-input" onchange="osOnRecipientChange()"></select>
            <div id="osRecipientNew" style="display:none;margin-top:6px">
              <input id="osNewContactName" class="form-input" placeholder="담당자 이름" style="margin-bottom:6px">
              <input id="osNewContactEmail" class="form-input" type="email" placeholder="이메일 주소" autocomplete="off">
            </div>
          </div>
          <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap">
            <button type="button" class="btn btn-primary btn-sm" onclick="osSendInviteClick(this)"><span class="material-icons-round notranslate" translate="no" style="font-size:15px;vertical-align:-3px">mail</span> 메일 발송</button>
          </div>
          <div style="font-size:12px;color:var(--muted);margin-top:6px">메일은 자동 발송되지 않습니다. 필요하면 「메일 발송」을 눌러 브랜드 담당자에게 작성 링크를 보내세요.</div>
          <div id="osCreateMailStatus" style="margin-top:12px;font-size:13px;line-height:1.6"></div>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientCreateModal')">닫기</button>
        <button type="button" class="btn btn-primary" id="osCreateSubmitBtn" onclick="osSubmitCreate()">발급</button>
      </div>
    </div>
  </div>
  <div class="modal-overlay" id="orientDetailModal">
    <div class="modal" style="max-width:560px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>오리엔시트 내용</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientDetailModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px;overflow-y:auto;flex:1" id="osDetailBody"></div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osOpenDetailNewWindow()"><span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">open_in_new</span> 새창으로 열기</button>
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDetailModal')">닫기</button></div>
    </div>
  </div>
  <div class="modal-overlay" id="orientDeleteModal">
    <div class="modal" style="max-width:440px;width:94vw;border-radius:16px;margin:auto;display:flex;flex-direction:column">
      <div class="modal-header"><h2>오리엔시트 삭제</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientDeleteModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px">
        <p style="margin-bottom:10px">브랜드 <b id="osDeleteBrand"></b> 의 오리엔시트를 삭제합니다. 이 작업은 되돌릴 수 없습니다.</p>
        <div id="osDeleteCampWarn" style="display:none;margin-bottom:12px;padding:10px 12px;background:#FFF0F2;border:1px solid #F3C2CA;border-radius:8px;font-size:13px;color:#A11221"></div>
        <p style="font-size:13px;color:var(--muted);margin-bottom:6px">삭제하려면 브랜드명 「<span id="osDeleteBrandEcho" style="font-weight:700;color:var(--text,#161618)"></span>」 을 그대로 입력하세요.</p>
        <input type="text" id="osDeleteConfirmInput" class="form-input" oninput="osCheckDeleteConfirm()" autocomplete="off">
        <div id="osDeleteError" style="display:none;margin-top:8px;font-size:13px;color:#C41E3A"></div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDeleteModal')">취소</button>
        <button type="button" class="btn" id="osDeleteBtn" style="background:#C41E3A;color:#fff" onclick="osExecuteDelete()" disabled>삭제</button>
      </div>
    </div>
  </div>`;
  document.body.insertAdjacentHTML('beforeend', html);
  // 동적 생성된 오리엔 모달에 드래그·리사이즈 옵저버 부착(부트 시점엔 없던 overlay라 재등록 필요. 멱등)
  if (typeof initDraggableModals === 'function') initDraggableModals();
}
