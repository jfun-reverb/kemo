// ============================================================
// admin-orient.js — 브랜드 셀프 오리엔시트 관리자 발급·조회 (PR3)
// 신규 페인 #adminPane-orient-sheets: 목록 · 발급 모달 · 상세 모달 · 링크 복사
// 사양서 docs/specs/2026-06-18-brand-self-orient-sheet.md §7
// 발급 함수 create_orient_sheet (마이그레이션 190, is_admin 가드)
// ============================================================

let _orientSheets = [];

const OS_TYPE_LABEL = { reviewer: '리뷰어형', seeding: '시딩형' };
const OS_STATUS = {
  draft:     { label: '작성 중', color: '#8A8A90', bg: '#F0F0F0' },
  submitted: { label: '제출됨', color: '#16A34A', bg: '#E8F5E9' },
  consumed:  { label: '발행됨', color: '#5B4B9E', bg: '#ECEAF6' },
  expired:   { label: '만료',   color: '#8A8A90', bg: '#F0F0F0' },
};
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
function osStatusOf(s) {
  return (osIsExpired(s) && s.status !== 'consumed') ? OS_STATUS.expired : (OS_STATUS[s.status] || OS_STATUS.draft);
}
function osBrandName(s) { return s.brands ? (s.brands.name || s.brands.name_ja || '-') : '-'; }
function osBadge(st) {
  return `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:${st.color};background:${st.bg}">${st.label}</span>`;
}
function osTypeLabel(ft) { return ft ? OS_TYPE_LABEL[ft] : '<span style="color:var(--muted)">미선택</span>'; }
function osChLabel(c) { return OS_CH_LABEL[c] || (c || '채널'); }

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
}

function osMsgRow(msg) {
  return `<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">${esc(msg)}</td></tr>`;
}

function renderOrientSheets() {
  const tbody = document.getElementById('orientTableBody');
  if (!tbody) return;
  const q = (document.getElementById('orientSearch')?.value || '').trim().toLowerCase();
  const list = _orientSheets.filter(s => !q || osBrandName(s).toLowerCase().includes(q));

  const cnt = document.getElementById('orientTotalCount');
  if (cnt) cnt.textContent = list.length ? `${list.length}건` : '';

  if (!list.length) {
    tbody.innerHTML = osMsgRow(q ? '검색 결과가 없습니다.' : '발급된 오리엔시트가 없습니다. 「신규 발급」으로 링크를 만들어 주세요.');
    return;
  }
  tbody.innerHTML = list.map(osRowHtml).join('');
}

function osRowHtml(s) {
  const linkBadge = s.application_id
    ? ' <span style="display:inline-block;padding:1px 6px;border-radius:999px;font-size:10px;color:#8A8A90;background:#F0F0F0">신청연결</span>' : '';
  return `<tr>
    <td>${esc(osBrandName(s))}${linkBadge}</td>
    <td>${osTypeLabel(s.form_type)}</td>
    <td>${osBadge(osStatusOf(s))}</td>
    <td>${s.created_at ? formatDate(s.created_at) : '-'}</td>
    <td>${s.token_expires_at ? formatDate(s.token_expires_at) : '-'}</td>
    <td style="white-space:nowrap">
      <button type="button" class="btn btn-ghost btn-xs" onclick="osCopyLink('${s.id}')">링크 복사</button>
      <button type="button" class="btn btn-ghost btn-xs" onclick="osOpenDetail('${s.id}')">상세</button>
    </td>
  </tr>`;
}

function osCopyLink(id) {
  const s = _orientSheets.find(x => x.id === id);
  if (!s) return;
  copyTextToClipboard(osBuildLink(s.token), '작성 링크가 복사되었습니다.');
}

// ── 발급 모달 ──
async function osOpenCreate() {
  ensureOrientModals();
  document.getElementById('osCreateApp').innerHTML = '<option value="">연결 안 함</option>';
  document.getElementById('osCreateType').value = '';
  document.getElementById('osCreateResult').style.display = 'none';
  document.getElementById('osCreateForm').style.display = '';
  document.getElementById('osCreateSubmitBtn').style.display = '';
  document.getElementById('orientCreateModal').classList.add('open');
  const sel = document.getElementById('osCreateBrand');
  sel.innerHTML = '<option value="">불러오는 중…</option>';
  try {
    const brands = await fetchBrands();
    sel.innerHTML = '<option value="">브랜드 선택</option>' +
      (brands || []).map(b => `<option value="${b.id}">${esc(b.name || b.name_ja || '-')}</option>`).join('');
  } catch (e) {
    sel.innerHTML = '<option value="">브랜드 조회 실패</option>';
  }
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
  const formType = document.getElementById('osCreateType').value || null;
  const btn = document.getElementById('osCreateSubmitBtn');
  btn.disabled = true;
  try {
    const res = await createOrientSheet(brandId, appId, formType);
    if (!res || res.success !== true) { toast('발급 실패: ' + osReasonText(res?.reason)); return; }
    document.getElementById('osCreateLink').value = osBuildLink(res.token);
    document.getElementById('osCreateExpire').textContent = res.token_expires_at ? formatDate(res.token_expires_at) : '';
    document.getElementById('osCreateForm').style.display = 'none';
    document.getElementById('osCreateResult').style.display = '';
    btn.style.display = 'none';
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
    invalid_form_type: '타입 값이 올바르지 않습니다',
    no_db: '연결 오류',
  })[r] || (r || '알 수 없는 오류');
}

function osCopyResultLink() {
  copyTextToClipboard(document.getElementById('osCreateLink').value, '작성 링크가 복사되었습니다.');
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
  // 카테고리는 code 로 저장되므로 한국어 라벨로 변환해 표시 (캠페인 폼과 동일 기준 데이터)
  let catMap = {};
  try { const cats = await fetchLookups('category'); catMap = Object.fromEntries((cats || []).map(c => [c.code, c.name_ko])); } catch (_) {}
  body.innerHTML = osDetailHtml(s, catMap);
}

function osDetailHtml(s, catMap) {
  const d = s.data || {};
  const header = `<div style="margin-bottom:14px">
    <div style="font-size:15px;font-weight:700">${esc(osBrandName(s))}</div>
    <div style="margin-top:6px">${osBadge(osStatusOf(s))}
      <span style="margin-left:6px">${osTypeLabel(s.form_type)}</span></div>
  </div>`;
  if (s.status === 'draft' && (!d || !Object.keys(d).length)) {
    return header + '<p style="color:var(--muted)">아직 작성 전입니다. 브랜드가 작성하면 여기에 표시됩니다.</p>';
  }
  return header + osSecRecruit(d) + osSecBrand(d) + osSecProduct(d, s.form_type, catMap)
    + osSecChannels(d) + osSecEtc(d) + osSecImages(d);
}

function osField(label, val) {
  const v = (val == null || val === '') ? '<span style="color:var(--muted)">미입력</span>' : esc(String(val));
  return `<div style="margin-bottom:6px"><span style="color:var(--muted);font-size:12px">${label}</span><br>${v}</div>`;
}
function osCard(title, inner) {
  return `<div style="border:1px solid #eee;border-radius:10px;padding:12px;margin-bottom:10px">
    <div style="font-weight:700;font-size:13px;margin-bottom:8px">${title}</div>${inner}</div>`;
}
function osRange(a, b) { return (a || b) ? `${a || '?'} ~ ${b || '?'}` : ''; }
function osPairs(arr) {
  if (!Array.isArray(arr) || !arr.length) return '';
  return arr.map(x => [x.label, x.value].filter(Boolean).join(': ')).filter(Boolean).join(' / ');
}

function osSecRecruit(d) {
  const r = d.recruit || {};
  // 브랜드는 희망 모집 기간만 입력. 구매·게시·결과 발표 일정은 관리자가 캠페인 등록 시 채움.
  const inner = osField('모집 인원', r.slots) + osField('희망 모집 기간', osRange(r.recruit_start, r.recruit_end));
  return osCard('모집 정보', inner);
}
function osSecBrand(d) {
  const b = d.brand || {};
  return osCard('브랜드 정보', osField('브랜드명', b.name) + osField('소개·어필', b.intro));
}
function osSecProduct(d, ft, catMap) {
  const p = d.product || {};
  const catLabel = (catMap && catMap[p.category]) || p.category;   // code → 한국어 라벨(없으면 원값)
  let inner = osField('제품명', p.name) + osField('카테고리', catLabel) + osField('소개·소구', p.appeal);
  if (ft === 'seeding') inner += osField('제품 제공 안내', p.provide_note) + osField('배송 안내', p.shipping_note);
  else inner += osField('판매 가격', osPairs(p.prices)) + osField('판매 URL', osPairs(p.urls));
  return osCard('제품 정보', inner);
}
function osSecChannels(d) {
  const ch = Array.isArray(d.channels) ? d.channels : [];
  if (!ch.length) return osCard('채널별 게시 가이드', '<span style="color:var(--muted)">미입력</span>');
  return osCard('채널별 게시 가이드', ch.map(c => osField(osChLabel(c.channel), c.guide)).join(''));
}
function osSecEtc(d) {
  const tags = Array.isArray(d.hashtags) ? d.hashtags.join(' ') : '';
  return osCard('해시태그·금지·안내',
    osField('필수 해시태그', tags) + osField('계정 태그', d.account_tags)
    + osField('금지 표현(NG)', d.ng) + osField('추가 안내', d.cautions));
}
// 브랜드 입력 URL은 서버 검증이 없으므로(직접 RPC 호출 우회 가능) http/https만 링크 허용
function osImgSafe(u) {
  try { const p = new URL(u).protocol; return p === 'https:' || p === 'http:'; }
  catch (e) { return false; }
}
function osSecImages(d) {
  const imgs = Array.isArray(d.images) ? d.images.filter(x => x && x.value) : [];
  if (!imgs.length) return '';
  const inner = imgs.map(x => {
    const disp = esc(x.value);
    return osImgSafe(x.value)
      ? `<div style="margin-bottom:4px"><a href="${disp}" target="_blank" rel="noopener">${disp}</a></div>`
      : `<div style="margin-bottom:4px;color:var(--muted)">${disp} <span style="font-size:10px">(링크 차단)</span></div>`;
  }).join('');
  return osCard('예시 이미지 링크', inner);
}

function osCloseModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.remove('open');
}

// ── 모달 DOM 1회 생성 (기존 .modal-overlay/.modal-body 클래스 재사용) ──
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
            <div style="font-size:11px;color:var(--muted);margin-top:4px">신청을 연결하면 그 신청의 타입을 자동 승계합니다.</div></div>
          <div class="form-group"><label class="form-label">모집 타입 (선택)</label>
            <select id="osCreateType" class="form-input">
              <option value="">브랜드가 작성 시 선택</option>
              <option value="reviewer">리뷰어형</option>
              <option value="seeding">시딩형</option></select>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">비워두면 브랜드가 작성 첫 화면에서 직접 고릅니다.</div></div>
        </div>
        <div id="osCreateResult" style="display:none">
          <p style="font-weight:700;margin-bottom:8px">발급되었습니다. 아래 링크를 브랜드에게 전달하세요.</p>
          <input type="text" id="osCreateLink" class="form-input" readonly onclick="this.select()">
          <div style="font-size:12px;color:var(--muted);margin-top:6px">작성 기한: <span id="osCreateExpire"></span></div>
          <button type="button" class="btn btn-primary btn-sm" style="margin-top:10px" onclick="osCopyResultLink()">링크 복사</button>
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
      <div class="modal-footer"><button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDetailModal')">닫기</button></div>
    </div>
  </div>`;
  document.body.insertAdjacentHTML('beforeend', html);
}
