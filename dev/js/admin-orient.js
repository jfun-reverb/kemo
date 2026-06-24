// ============================================================
// admin-orient.js — 브랜드 셀프 오리엔시트 관리자 발급·조회
// 신규 페인 #adminPane-orient-sheets: 목록 · 발급 모달 · 상세 모달 · 링크 복사
// 사양서 docs/specs/2026-06-18-brand-self-orient-sheet.md §7·§15
// 발급 함수 create_orient_sheet (마이그레이션 195, 2인자, is_admin 가드)
// §15 재설계: 1 링크 = 공통 브랜드 + 카드 N개(카드마다 form_type). data = cards 배열(§15-A)
// ============================================================

let _orientSheets = [];
let _osDetailSheet = null;   // 상세 모달에 열린 시트(카드별 발행에 사용)

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
    <td>${osCardsSummary(s.data)}</td>
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
    await refreshPane('orient-sheets');
    // 발급 직후 브랜드 담당자에게 작성 링크 메일 자동 발송 (실패해도 발급은 유효 — 결과만 표시)
    osSendInviteAndShow(res.id);
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

// 발급 직후 메일 발송 + 발급 결과 화면에 발송 상태 인라인 표시.
// 발송은 발급과 별개라 실패해도 발급 자체는 유효(링크 수동 복사 안내).
async function osSendInviteAndShow(orientSheetId) {
  const box = document.getElementById('osCreateMailStatus');
  if (!box) return;
  box.innerHTML = '<span style="color:var(--muted)">메일 발송 중…</span>';
  let r;
  try {
    r = await sendOrientInviteMail(orientSheetId);
  } catch (e) {
    r = { sent: false, error: (e && e.message) || 'unknown' };
  }
  if (r && r.sent) {
    const advNote = r.advanced
      ? ' · 신청 단계를 「오리엔시트 발송됨」으로 이동했습니다.'
      : '';
    box.innerHTML = '<div style="color:#16A34A;font-weight:600">메일을 보냈습니다 — ' +
      esc(r.recipient || '') + '</div>' +
      (advNote ? '<div style="color:var(--muted);font-size:12px;margin-top:2px">' + advNote.replace(/^ · /, '') + '</div>' : '');
  } else if (r && r.reason === 'no_recipient') {
    box.innerHTML = '<div style="color:#B45309;font-weight:600">수신자 이메일이 없어 메일을 보내지 못했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 브랜드에게 직접 전달해 주세요.</div>';
  } else {
    box.innerHTML = '<div style="color:#C41E3A;font-weight:600">메일 발송에 실패했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 직접 전달하거나, 잠시 후 다시 시도해 주세요.</div>';
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
  body.innerHTML = osDetailHtml(s, catMap);
}

function osDetailHtml(s, catMap) {
  const d = s.data || {};
  const cards = Array.isArray(d.cards) ? d.cards : [];
  const header = `<div style="margin-bottom:14px">
    <div style="font-size:15px;font-weight:700">${esc(osBrandName(s))}</div>
    <div style="margin-top:6px">${osBadge(osStatusOf(s))}
      <span style="margin-left:6px;color:var(--muted);font-size:12px">${cards.length ? cards.length + '개 모집 건' : ''}</span></div>
  </div>`;
  const brandCard = osBrandCard(d.brand);
  if (!cards.length) {
    const msg = (s.status === 'draft')
      ? '아직 작성 전입니다. 브랜드가 작성하면 여기에 표시됩니다.'
      : '작성된 모집 건이 없습니다.';
    return header + brandCard + `<p style="color:var(--muted)">${msg}</p>`;
  }
  return header + brandCard + cards.map((c, i) => osCardDetail(c, i, catMap)).join('');
}

function osField(label, val) {
  const v = (val == null || val === '') ? '<span style="color:var(--muted)">미입력</span>' : esc(String(val));
  return `<div style="margin-bottom:6px"><span style="color:var(--muted);font-size:12px">${label}</span><br>${v}</div>`;
}
// 값이 이미 안전한 HTML(링크 등 — 호출부가 esc·화이트리스트 보장)일 때. esc 미적용.
function osFieldHtml(label, htmlVal) {
  const v = htmlVal ? htmlVal : '<span style="color:var(--muted)">미입력</span>';
  return `<div style="margin-bottom:6px"><span style="color:var(--muted);font-size:12px">${label}</span><br>${v}</div>`;
}
function osRange(a, b) { return (a || b) ? `${a || '?'} ~ ${b || '?'}` : ''; }

// 공통 브랜드 카드 (1회)
function osBrandCard(brand) {
  const b = brand || {};
  const inner = osField('브랜드명', b.name) + osField('소개·어필', b.intro) + osField('공식 계정', b.official_accounts);
  return `<div style="border:1px solid #eee;border-radius:10px;padding:12px;margin-bottom:10px">
    <div style="font-weight:700;font-size:13px;margin-bottom:8px">브랜드 정보</div>${inner}</div>`;
}

// 카드(모집 건) 1개 상세 — 형식별 항목 분기(§15-12)
function osCardDetail(c, idx, catMap) {
  const ft = (c && c.form_type) || '';
  const p = c.product || {};
  const r = c.recruit || {};
  const sale = c.sale || {};
  const sd = c.seeding || {};
  const catLabel = (catMap && catMap[p.category]) || p.category;

  let inner = osField('카테고리', catLabel) + osField('모집 인원', p.slots)
    + osField('희망 모집 기간', osRange(r.recruit_start, r.recruit_end));

  if (ft === 'proxy_purchase' || ft === 'reviewer') {
    inner += osField('판매처', sale.market) + osFieldHtml('판매 URL', osLinkOrText(sale.url))
      + osField('상시가', sale.price_regular) + osField('세일가', sale.price_sale)
      + osField('대형할인', [sale.event, sale.price_event].filter(Boolean).join(' '));
  }
  if (ft === 'reviewer') inner += osField('리뷰 가이드', c.review_guide);
  if (ft === 'seeding') {
    inner += osField('등급', OS_GRADE_LABEL[sd.grade] || sd.grade);
    const guides = Array.isArray(sd.guides) ? sd.guides.filter(g => g && (g.channel || g.guide)) : [];
    inner += guides.length
      ? guides.map(g => osField('채널 — ' + osChLabel(g.channel), g.guide)).join('')
      : osField('채널별 가이드', '');
    inner += osField('소구 키워드', sd.appeal)
      + osField('해시태그', Array.isArray(sd.hashtags) ? sd.hashtags.join(' ') : (sd.hashtags || ''))
      + osField('계정 태그', sd.account_tags);
    if (sd.grade === 'middle_mega') {
      inner += osField('촬영 가이드', sd.shooting_guide) + osField('필수 내용', sd.required_content) + osField('증정품', sd.gift);
    }
    inner += osField('배송 안내', sd.shipping_note);
  }
  inner += osField('금지 표현(NG)', c.ng) + osField('추가 안내', c.cautions) + osImagesInline(c.images);
  if (!ft) inner = '<div style="color:var(--muted);font-size:12px;margin-bottom:8px">브랜드가 아직 형식을 고르지 않았습니다.</div>' + inner;

  const head = `<div style="display:flex;align-items:center;gap:8px;margin-bottom:10px">
    ${osTypeChip(ft)}<span style="font-weight:700;font-size:14px;flex:1;min-width:0">${esc(p.name || ('제품 ' + (idx + 1)))}</span>${osCardPublishControl(c, idx)}</div>`;
  return `<div style="border:1px solid #eee;border-radius:10px;padding:12px;margin-bottom:10px">${head}${inner}</div>`;
}

// 카드 헤더 우측 — 발행 버튼(제출됨·미발행·형식 선택) / 발행됨 배지 / 형식 미선택 안내
function osCardPublishControl(c, idx) {
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
  return `<div style="margin-bottom:6px"><span style="color:var(--muted);font-size:12px">예시 이미지 링크</span><br>${inner}</div>`;
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
  if (s.price_sale) parts.push('세일가 ' + s.price_sale);
  if (s.event) parts.push(s.event + ' ' + (s.price_event || ''));
  return parts.join(' / ');
}

// 평문 → 리치 텍스트 HTML (이스케이프 + 줄바꿈)
function osPlainToRich(t) {
  if (!t) return '';
  return esc(String(t)).replace(/\n/g, '<br>');
}

// 카드 한국어 콘텐츠를 가이드 초안으로 합침 (관리자가 일본어로 번역)
function osBuildGuideDraft(card) {
  const blocks = [];
  if (card.form_type === 'reviewer' && card.review_guide) blocks.push('[리뷰 가이드]\n' + card.review_guide);
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
  if (card.cautions) blocks.push('[추가 안내]\n' + card.cautions);
  if (card.ng) blocks.push('[NG]\n' + card.ng);
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
    setRichValue('newCampAppeal', osPlainToRich((card.seeding && card.seeding.appeal) || ''));
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
          <input type="text" id="osCreateLink" class="form-input" readonly onclick="this.select()">
          <div style="font-size:12px;color:var(--muted);margin-top:6px">작성 기한: <span id="osCreateExpire"></span></div>
          <button type="button" class="btn btn-primary btn-sm" style="margin-top:10px" onclick="osCopyResultLink()">링크 복사</button>
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
      <div class="modal-footer"><button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDetailModal')">닫기</button></div>
    </div>
  </div>`;
  document.body.insertAdjacentHTML('beforeend', html);
}
