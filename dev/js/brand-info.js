// 브랜드 페이지 — 브랜드 관리(03): 회사 정보 · 브랜드 정보 · SNS 정보 보기(조각 4) — 수정은 조각 5(브랜드)·6(회사)
//   작업표 docs/specs/2026-10-16-brand-info-page-breakdown.md · 피그마 bw03-00(대표)·bw03-00c(멤버)
//   🔴 서버 함수 get_my_brand_profile(536)이 역할·회사·같은 회사 브랜드 목록을 정한다 — 화면은 받은 값만 그린다.
//      회사 「수정」을 숨기는 것은 모양일 뿐이고 막는 것은 서버다(멤버에게는 company_brands 도 [] 로 온다).
//   🔴 브랜드명(일본어)은 브랜드 화면에서 늘 잠긴 칸이다(결정 D1 — 저장 함수도 받지 않는다).

const BRAND_INFO_MSG = {
  loadFail: '브랜드 정보를 불러오지 못했습니다.',
  noCompany: '등록된 회사 정보가 없습니다 — 운영팀에 등록을 요청해 주십시오',
  ownerNote: '회사 정보는 대표 담당자만 고칠 수 있습니다.',
  ownerNoteShared: ' 고치면 이 회사의 브랜드 모두에 함께 바뀝니다.',
  memberNote: '회사 정보는 대표 담당자만 고칠 수 있습니다. 바꿔야 하면 대표 담당자에게 요청해 주십시오.',
  empty: '미입력'
};
const BRAND_INFO_NAME_LIMIT = 6;   // 같은 회사 브랜드 이름을 몇 개까지 적나(기본값 7) — 넘으면 「외 N개」

// 응답 — undefined = 불러오는 중 · null = 실패 · { brandId, ...get_my_brand_profile 응답 }
let _brandInfoData;
// 수정 중인 카드 — null · 'brand' · 'company' (조각 5·6)
let _brandInfoEditing = null;
let _brandInfoBusy = false;
let _brandInfoLoadSeq = 0;
let _brandInfoNotLinkedFor = null;   // 방금 not_linked 를 받은 브랜드 — 반복 호출 막기

// ── 서버
async function loadBrandInfo() {
  const brandId = getCurrentBrandId();
  const seq = ++_brandInfoLoadSeq;
  // 같은 브랜드의 옛 값은 새 응답이 올 때까지 둔다(깜빡임 방지). 다른 브랜드 것이거나 실패 상태면 불러오는 중으로
  if (!_brandInfoData || _brandInfoData.brandId !== brandId) { _brandInfoData = undefined; _rerenderBrandInfoIfShown(); }
  const { data, error } = await brandRpc('get_my_brand_profile', { p_brand_id: brandId });
  if (seq !== _brandInfoLoadSeq) return;   // 그사이 브랜드가 바뀌거나 다시 불렀다
  if (!error && data && data.result === 'not_linked') {
    // 실패 화면을 먼저 깔아 둔다 — 판정 새로고침이 실패하면 handleBrandNotLinked 가 다시 그리지 않아 「불러오는 중」에 멈춘다.
    // 같은 브랜드에서 두 번째로 not_linked 면(로그인 판정과 어긋남) 판정을 다시 부르지 않는다 — render → load 반복을 끊는다
    _brandInfoData = null;
    _rerenderBrandInfoIfShown();
    if (_brandInfoNotLinkedFor === brandId) return;
    _brandInfoNotLinkedFor = brandId;
    await handleBrandNotLinked();
    return;
  }
  _brandInfoNotLinkedFor = null;
  _brandInfoData = (!error && data && data.result === 'ok') ? Object.assign({ brandId }, data) : null;
  _rerenderBrandInfoIfShown();
}

function _rerenderBrandInfoIfShown() {
  if (location.hash !== '#brand' || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (host) renderBrandInfo(host);
}

// ── 그리기
// 같은 회사 브랜드 이름 — 이름순, 6개까지 · 넘으면 「외 N개」(보기 안내·수정 주황 안내가 같이 쓴다 — 기본값 7)
function brandInfoCompanyNames(list) {
  const names = (list || []).map(b => b.name || '').sort(compareBrandNames);
  const shown = names.slice(0, BRAND_INFO_NAME_LIMIT).join(' · ');
  const rest = names.length - BRAND_INFO_NAME_LIMIT;
  return rest > 0 ? shown + ' · … · 외 ' + rest + '개' : shown;
}

function _brandInfoBtn(label, act, opts) {
  const o = opts || {};
  return '<button type="button" class="brand-my-btn' + (o.fill ? ' is-fill' : '') + '" data-bi-act="' + act + '"' +
    (_brandInfoBusy ? ' disabled' : '') + '>' + brandEsc(label) + '</button>';
}

function _brandInfoHead(id, title, toolsHtml) {
  return '<div class="brand-my-head"><h2 id="' + id + '">' + brandEsc(title) + '</h2>' +
    (toolsHtml ? '<div class="brand-my-tools">' + toolsHtml + '</div>' : '') + '</div>';
}

// 보기 칸 — 빈 값은 흐린 「미입력」. locked = 브랜드 화면에서 바꿀 수 없는 칸(회색)
function _brandInfoValue(v, opts) {
  const o = opts || {};
  const inner = (v == null || String(v).trim() === '')
    ? '<span class="brand-info-empty">' + brandEsc(BRAND_INFO_MSG.empty) + '</span>'
    : brandEsc(v);
  return '<div class="brand-my-value' + (o.locked ? ' is-locked' : '') + '">' + inner + '</div>';
}

function _brandInfoField(label, valueHtml, opts) {
  const o = opts || {};
  return '<div class="brand-my-field' + (o.wide ? ' brand-info-wide' : '') + '">' +
    '<span class="brand-my-label">' + brandEsc(label) + (o.required ? '<span class="brand-info-req" aria-hidden="true"> *</span>' : '') + '</span>' +
    valueHtml + '</div>';
}

function _brandInfoCompanyHtml(d) {
  const c = d.company;
  const isOwner = d.role === 'owner';
  let tools = '';
  let body;
  if (!c) {
    // 회사 미연결 — 브랜드가 회사를 만들지 않는다(운영팀이 연결)
    body = '<p class="brand-my-small">' + brandEsc(BRAND_INFO_MSG.noCompany) + '</p>';
  } else {
    if (d.can_edit_company && !_brandInfoEditing) tools = _brandInfoBtn('수정', 'edit-company');
    const addr = '<div class="brand-info-stack">' + _brandInfoValue(c.address) + _brandInfoValue(c.address_detail) + '</div>';
    let note;
    if (isOwner) {
      const list = d.company_brands || [];
      note = '이 회사의 브랜드: ' + brandInfoCompanyNames(list) + ' — ' + BRAND_INFO_MSG.ownerNote +
        (list.length >= 2 ? BRAND_INFO_MSG.ownerNoteShared : '');
    } else {
      note = BRAND_INFO_MSG.memberNote;
    }
    body = '<div class="brand-my-fields">' +
        _brandInfoField('회사명', _brandInfoValue(c.name_ko), { required: true }) +
        _brandInfoField('사업자등록번호', _brandInfoValue(c.business_no), { required: true }) +
        _brandInfoField('홈페이지 URL', _brandInfoValue(c.homepage_url)) +
        _brandInfoField('주소', addr, { wide: true }) +
      '</div>' +
      '<p class="brand-my-small">' + brandEsc(note) + '</p>';
  }
  return '<section class="brand-my-section" id="brandCompanyCard" aria-labelledby="brandCompanyTitle">' +
    _brandInfoHead('brandCompanyTitle', '회사 정보', tools) + body + '</section>';
}

function _brandInfoBrandHtml(d) {
  const b = d.brand || {};
  const tools = _brandInfoEditing ? '' : _brandInfoBtn('수정', 'edit-brand');
  return '<section class="brand-my-section" id="brandInfoCard" aria-labelledby="brandInfoTitle">' +
      _brandInfoHead('brandInfoTitle', '브랜드 정보', tools) +
      '<div class="brand-my-fields">' +
        _brandInfoField('브랜드명(한글)', _brandInfoValue(b.name), { required: true }) +
        _brandInfoField('브랜드명(일본어)', _brandInfoValue(b.name_ja, { locked: true })) +
        _brandInfoField('브랜드명(영문)', _brandInfoValue(b.name_en)) +
      '</div>' +
    '</section>' +
    // SNS 정보는 브랜드 정보의 한 절 — 따로 「수정」이 없고 브랜드 정보 「수정」을 따라간다(피그마 bw03-00)
    '<section class="brand-my-section" aria-labelledby="brandSnsTitle">' +
      _brandInfoHead('brandSnsTitle', 'SNS 정보', '') +
      '<div class="brand-my-fields is-two">' +
        _brandInfoField('공식 Instagram URL', _brandInfoValue(b.official_instagram_url)) +
        _brandInfoField('공식 X URL', _brandInfoValue(b.official_x_url)) +
      '</div>' +
    '</section>';
}

function renderBrandInfo(host) {
  const d = _brandInfoData;
  let body;
  if (d === undefined) body = stateLoadingBrand();
  else if (d === null) {
    body = '<div class="brand-empty"><p class="brand-empty-title">' + brandEsc(BRAND_INFO_MSG.loadFail) + '</p>' +
      '<button type="button" class="brand-btn brand-btn-line brand-btn-inline" data-bi-act="reload">다시 시도</button></div>';
  } else {
    body = _brandInfoCompanyHtml(d) + _brandInfoBrandHtml(d);
  }
  host.innerHTML =
    '<div id="brandInfoPage" class="brand-info-page">' +
      '<div class="brand-page-head"><div><h1>브랜드 관리</h1><p>브랜드 정보를 관리합니다.</p></div></div>' +
      body +
    '</div>';
}

registerBrandPage('brand', {
  title: '브랜드 관리',
  render(host) {
    renderBrandInfo(host);
    // 들어올 때마다 새로 받는다(다른 담당자가 고쳤을 수 있다). 브랜드를 바꿔 다시 그려질 때도 같다
    loadBrandInfo();
  }
});

// 브랜드를 바꾸면 수정 상태를 버린다(옛 브랜드 응답도 버린다 — 다시 그리기는 틀이 render 를 부른다)
onBrandChanged(() => { _brandInfoEditing = null; _brandInfoData = undefined; _brandInfoLoadSeq++; });

// 다른 페이지로 나가면 수정 상태를 버린다(확인 없이 — 기본값 4, 마이페이지와 같다)
window.addEventListener('hashchange', () => {
  if (location.hash !== '#brand') { _brandInfoEditing = null; _brandInfoData = undefined; _brandInfoLoadSeq++; }
});

document.addEventListener('click', (e) => {
  const btn = e.target.closest('#brandPageHost [data-bi-act]');
  if (!btn || btn.disabled) return;
  const act = btn.dataset.biAct;
  if (act === 'reload') { _brandInfoData = undefined; _rerenderBrandInfoIfShown(); loadBrandInfo(); return; }
  // edit-brand(조각 5) · edit-company(조각 6)
});
