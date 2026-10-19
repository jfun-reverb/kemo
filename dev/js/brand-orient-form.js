// 브랜드 페이지 — 오리엔시트 작성 모달(04) + 자동 저장·충돌·떠나기 전 확인
//   (작업표 docs/specs/2026-10-16-brand-orient-tab-breakdown.md 조각 6 · 결정 7·8·10·11·15 · 기본값 1·3·4·6·8)
//   피그마 bw04-01(리뷰어)·02(시딩)·bm04-01(모바일 전체 화면)·01e(충돌)·13(브랜드 바꿀 때 확인)·91(저장 상태)·92(칸 안내)
//
//   🔴 dev/sales/orient.html 의 「새 구조 폼」(cardHtmlNew·collectCardNew·자동 저장·구간·큐텐·업로드)을 옮겨 온 사본이다(기본값 1).
//      출시 확인 뒤 옛 폼을 정리할 때까지 **작성 부분을 고치면 두 곳을 함께** 고친다(의심 4). 사본이 는 목록:
//      긴 글 칸 1,000자(폼 LONG_TEXT_FIELDS·카운터·서버 = 넷) · 구간 기본 이름(서버·폼 TIER_OPTIONS·관리자 OS_TIER_DEFAULT_NAME·여기 = 넷)
//      · 옵션 기본값(폼·여기 = 둘) · 시딩 채널 이름 · 고정 안내 문안(NOTICE_LINES) · 이미지 압축(긴 변 2048).
//   🔴 서버 호출은 전부 로그인 계정 함수(540·541)다 — 토큰 함수를 부르지 않는다. 화면은 토큰을 모른다(기본값 5).
//   옛 구조(카드 여러 개) 시트는 이 모달로 열지 않는다(결정 4 — 조각 7 의 읽기 전용 안내).

const BOF_MSG = {
  subtitle: '담당자가 보내 드린 오리엔시트를 작성하고 내역을 확인할 수 있습니다.',
  openFail: '오리엔시트를 열지 못했습니다. 잠시 후 다시 시도해 주십시오.',
  cannotOpen: '이 오리엔시트를 볼 수 없습니다.',
  conflictToast: '새로고침 후 다시 시도해 주십시오.',            // bw04-90
  uploadBusy: '파일 업로드가 끝나면 진행할 수 있습니다.',
  conflictNote: '다른 곳에서 먼저 수정되었습니다. 새로고침하면 최신 내용을 불러오고, 이 기기에서 쓰던 내용도 다시 불러올 수 있습니다.',
  resubmitNote: '이미 제출하신 내용입니다. 여기서 고친 내용은 따로 저장되고, 다시 제출해야 담당자에게 전달됩니다. 캠페인 등록 전까지 고칠 수 있습니다.'
};

// 아래 바 저장 상태 여덟(bw04-91 ①~⑧) — data-save-state 값 = 키. 색은 brand.css [data-save-state]
//   ⚠️ bw04-91 은 여덟 모두 아이콘이 없고, 작성 모달 그림(bw04-01)의 「저장됨」에만 구름 아이콘이 있다 — 「저장됨」만 아이콘(기획 확인 필요)
const BOF_SAVE_STATE = {
  idle:      { icon: '',           text: '자동 저장' },
  saving:    { icon: '',           text: '저장 중…' },
  saved:     { icon: 'cloud_done', text: '저장됨' },              // 뒤에 시각을 붙인다
  failed:    { icon: '',           text: '저장하지 못했습니다', retry: true },   // 「· 다시 시도」는 누르면 바로 다시 저장(bw04-91 ④)
  restored:  { icon: '',           text: '이 기기에 남아 있던 내용을 불러왔습니다' },
  conflict:  { icon: '',           text: '다른 곳에서 수정됨' },
  locked:    { icon: '',           text: '저장할 수 없습니다' },
  too_large: { icon: '',           text: '내용이 너무 깁니다' }
};

const BOF_FORM_LABEL = { reviewer: '리뷰어', seeding: '시딩' };
const BOF_MAX_HASHTAGS = 5;
const BOF_MAX_IMAGES = 5;
const BOF_UPLOAD_BUCKET = 'orient-images';
const BOF_UPLOAD_MAX_BYTES = 10 * 1024 * 1024;
const BOF_UPLOAD_MIME = {   // orient.html ORIENT_UPLOAD_MIME 사본 — 버킷 허용 형식과 같게
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', webp: 'image/webp',
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation'
};
const BOF_AUTOSAVE_DELAY = 1500;
const BOF_SAVE_WAIT_LIMIT_MS = 15000;
const BOF_LOOKUP_TIMEOUT_MS = 10000;
const BOF_BACKUP_PREFIX = 'reverb.brandOrient.';   // + 계정 번호 + '.' + 시트 번호 (기본값 6)
const BOF_SAMPLE_IMG = '../sales/images/orient-product-sample.png';   // 예시 그림 — sales 폴더 그림을 같이 쓴다(빌드가 루트 sales/images 로 복사)

// 긴 글 칸 1,000자 — 🔴 orient.html LONG_TEXT_FIELDS 사본(칸을 더하면 그쪽·서버와 함께)
const BOF_LIMIT_LONG_TEXT = 1000;
const BOF_LONG_TEXT_FIELDS = {
  'f-review-guide': { label: '리뷰 가이드', field: 'review_guide' },
  'f-appeal':       { label: '리뷰 가이드', field: 'appeal' },
  'f-shooting':     { label: '촬영 가이드', field: 'shooting_guide' },
  'f-pg-options':   { label: '구매 가이드', field: 'purchase_guide_options' }
};
const BOF_LONG_TEXT_CLASSES = Object.keys(BOF_LONG_TEXT_FIELDS);

// 고정 안내 — 🔴 orient.html NOTICE_LINES 사본(문안 정의처는 사양서 2026-09-16 §4-8). 피그마 bw04-01·02 와 글자 그대로 같다
const BOF_NOTICE_LINES = {
  reviewer: [
    '리뷰어가 상품을 구매한 경우, 구매 후 <strong>3일 이내 배송 진행 및 송장번호 등록</strong>을 완료해 주셔야 합니다.',
    '배송 과정에서 제품이 누락되거나 파손되는 경우, 해당 리뷰어의 캠페인 진행을 위해 <strong>브랜드사에서 제품을 재발송</strong>해 주시는 방향으로 진행되는 점 참고 부탁드립니다.',
    '리뷰어 구매 현황은 구매 및 모집 완료 후, <strong>캠페인 종료 시 일괄 전달</strong>드립니다.',
    '<strong>스테마 규제로 인해 리뷰의 구체적인 내용이나 평점(★)을 지정하거나 강제할 수 없는</strong> 점 양해 부탁드립니다.'
  ],
  seeding: [
    '<strong>배송 리스트 전달 후 3일 이내</strong> 배송 및 송장번호 전달을 완료해 주셔야 합니다.',
    '<strong>스테마 규제로 인해 리뷰의 구체적인 내용이나 평점(★)을 지정하거나 강제할 수 없는</strong> 점 양해 부탁드립니다.',
    '체험단은 실제 상품을 사용한 후, 개인적인 경험을 바탕으로 자연스럽게 리뷰를 작성하게 됩니다.',
    '다만, 상품의 매력이나 브랜드에서 전달하고자 하는 주요 포인트는 리뷰 작성 시 참고할 수 있도록 안내하실 수 있습니다.'
  ]
};
// 자율구매 고정 문구 — orient.html PURCHASE_GUIDE_FREE_KO 는 「~주세요」, 피그마 브랜드 화면은 「~주십시오」.
//   🔴 화면에만 보이는 글이다(저장하지 않는다 — purchase_guide.mode 만 저장). 발행 자동 채움은 관리자 코드의 일본어 문장을 쓴다
const BOF_PURCHASE_GUIDE_FREE = '상품을 자유롭게 구매해 주십시오.';
const BOF_EXTRA_MARKETS = [
  { key: 'lips', label: 'LIPS 추가' },
  { key: 'cosme', label: '@cosme 추가' }
];
// 구간 기본값 — 🔴 orient.html TIER_OPTIONS 사본(이름 시드와 글자 그대로 같게). 열 때마다 복사해 쓴다(서버 값으로 덮으므로)
const BOF_TIER_DEFAULTS = [
  { key: 'tmin',     name: '소량',      option: '',          sub: '', slots: '', noButton: true },
  { key: 't50',      name: '라이트',    option: '',          sub: '', slots: '' },
  { key: 't100',     name: '스탠다드',  option: '',          sub: '', slots: '' },
  { key: 't300',     name: '프리미엄',  option: '',          sub: '', slots: '' },
  { key: 't500plus', name: '프리미엄+', option: '+실검작업', sub: '', slots: '' }
];
const BOF_RICH_ALLOWED_TAGS = ['b', 'strong', 'i', 'em', 'u', 's', 'strike', 'a', 'br', 'p'];

// 열린 모달 하나의 상태 — 닫히면 null. 비동기 응답은 자기가 시작한 상태 객체(st)가 아직 열려 있을 때만 화면을 고친다
let _bof = null;
let _bofOpening = false;

function _bofEl(sel) { return _bof && _bof.root ? _bof.root.querySelector(sel) : null; }
function _bofIsNew(st) { return !!(st.data && st.data.issued && typeof st.data.issued === 'object'); }
function _bofFormType(st) { return (st.data && st.data.issued && st.data.issued.form_type) || ''; }
function _bofChannel(st) { return (st.data && st.data.issued && st.data.issued.channel) || ''; }

// ── 주소 보정 — orient.html normalizeUrl 사본(위험 스킴 차단 + https 보정)
function _bofNormalizeUrl(raw) {
  if (!raw) return '';
  let s = String(raw).trim();
  if (!s) return '';
  if (/^(javascript|data|vbscript|file|blob):/i.test(s)) return '';
  if (/^https?:\/\//i.test(s)) { /* 그대로 */ }
  else if (/^h?t{1,2}ps?:?\/{1,2}/i.test(s)) s = s.replace(/^h?t{1,2}ps?:?\/{1,2}/i, 'https://');
  else if (/^[a-z][a-z0-9+.\-]*:\/\//i.test(s)) return '';
  else s = 'https://' + s;
  try {
    const u = new URL(s);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return '';
    if (!u.hostname) return '';
  } catch (e) { return ''; }
  return s;
}

// ── 서식 칸 — 🔴 저장(richValue)·미리보기·관리자 세 곳에서 정화한다(저장형 XSS). DOMPurify 는 brand/index.html 이 싣는다
function _bofRichSanitize(html) {
  if (html == null) return '';
  if (typeof DOMPurify === 'undefined') return String(html).replace(/<[^>]*>/g, '');   // 못 실으면 태그를 걷는다(안전 쪽)
  const clean = DOMPurify.sanitize(String(html), {
    ALLOWED_TAGS: BOF_RICH_ALLOWED_TAGS,
    ALLOWED_ATTR: ['href', 'target', 'rel'],
    FORBID_TAGS: ['img', 'script', 'iframe', 'style', 'object', 'embed', 'svg'],
    FORBID_ATTR: ['style', 'onerror', 'onload', 'onclick'],
    ALLOWED_URI_REGEXP: /^(?:https?:|mailto:)/i
  });
  const w = document.createElement('div');
  w.innerHTML = clean;
  w.querySelectorAll('a[href]').forEach(a => { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer nofollow'); });
  return w.innerHTML;
}
function _bofRichInitial(val) {
  val = val || '';
  if (/<[a-z][\s\S]*>/i.test(val)) return _bofRichSanitize(val);
  return brandEsc(val).replace(/\n/g, '<br>');
}
function _bofRichValue(node) {
  if (!node) return '';
  if (!node.textContent.trim() && !/<a /i.test(node.innerHTML)) return '';
  return _bofRichSanitize(node.innerHTML);
}
function _bofRichEditorHtml(safeHtml, cls, placeholder, label) {
  const tool = (cmd, title, inner, extra) => '<button type="button" class="bof-rich-btn' + (extra || '') + '" title="' + title + '" aria-label="' + title + '" data-bof-act="rich" data-cmd="' + cmd + '">' + inner + '</button>';
  return '<div class="bof-rich">' +
    '<div class="bof-rich-tools">' +
      tool('bold', '굵게', '<b>B</b>') + tool('italic', '기울임', '<i>I</i>') +
      tool('underline', '밑줄', '<u>U</u>') + tool('strikeThrough', '취소선', '<s>S</s>') +
      tool('link', '링크 (글자를 먼저 고른 뒤)', '<span class="material-icons-round notranslate" translate="no" aria-hidden="true">link</span>') +
    '</div>' +
    '<div class="bof-rich-body ' + cls + '" contenteditable="true" role="textbox" aria-multiline="true" aria-label="' + brandEsc(label) + '" data-placeholder="' + brandEsc(placeholder) + '">' + safeHtml + '</div>' +
  '</div>';
}
function _bofCounter(cls) {
  return '<div class="bof-count" data-count-for="' + cls + '"><span class="bof-count-cur">0</span> / ' + BOF_LIMIT_LONG_TEXT + '</div>';
}

// ── 구간(모집 인원) — orient.html 의 판정 사본. 🔴 서버 _orient_compute_quote 와 같은 규칙(시작 인원 `<` 비교)
function _bofReadSlots(raw) {
  const digits = String(raw == null ? '' : raw).replace(/[^0-9]/g, '');
  if (!digits) return null;
  const n = parseInt(digits, 10);
  return isFinite(n) && n > 0 ? n : null;
}
function _bofTierOfSlots(st, n) {
  const f = st.tierFees;
  if (!n || !f || !f.slots) return null;
  const at = k => { const v = Number(f.slots[k]); return isFinite(v) && v > 0 ? v : null; };
  const t50 = at('t50'), t100 = at('t100'), t300 = at('t300'), t500 = at('t500plus');
  if (t50 === null || t100 === null || t300 === null || t500 === null) return null;
  if (n < t50) return 'tmin';
  if (n < t100) return 't50';
  if (n < t300) return 't100';
  if (n < t500) return 't300';
  return 't500plus';
}
function _bofMinSlots(st) {
  const v = st.tierFees ? Number(st.tierFees.minSlots) : NaN;
  return (isFinite(v) && v > 0) ? v : 1;
}
function _bofTierPriceText(st, key) {
  const f = st.tierFees;
  if (!f || f.override !== null) return '';
  const v = f.fees[key];
  if (v === null || v === undefined || !isFinite(Number(v))) return '';   // 🔴 Number(null) 은 0 — 빈 값 검사가 먼저
  const amount = Number(v).toLocaleString('ko-KR') + '원/건';
  return f.formType === 'reviewer' ? '모집비 ' + amount : amount;
}
function _bofTierNoteText(st) {
  const f = st.tierFees;
  if (!f) return '';
  if (f.override !== null) return '이 시트는 협의된 단가(1건당 ' + f.override.toLocaleString('ko-KR') + '원)가 모든 구간에 적용됩니다. (부가세 별도)';
  if (!Object.keys(f.fees).length) return '';
  return f.formType === 'reviewer'
    ? '표시 금액은 1건당 모집비입니다(부가세 별도). 상품 결제비용·해외 송금 수수료는 따로 더해지며, 전체 금액은 「견적 보기」에서 확인할 수 있습니다.'
    : '표시 금액은 1건당 진행비입니다(부가세 별도). 전체 금액은 「견적 보기」에서 확인할 수 있습니다.';
}
function _bofExtraFeeText(st, key) {
  const f = st.tierFees && st.tierFees.optionFees;
  let v = null;
  if (f && f[key] !== null && f[key] !== undefined) { const n = Number(f[key]); if (isFinite(n) && n >= 0) v = n; }
  return v === null ? '금액은 「견적 보기」에서 확인' : '+' + v.toLocaleString('ko-KR') + '원 / 1건';
}
function _bofApplyTierLabels(st, names, options) {
  st.tiers.forEach(t => {
    if (names && typeof names === 'object' && typeof names[t.key] === 'string' && names[t.key].trim()) t.name = names[t.key].trim();
    if (options && typeof options === 'object' && Object.prototype.hasOwnProperty.call(options, t.key)) t.option = String(options[t.key] == null ? '' : options[t.key]).trim();
  });
}
function _bofApplyTierSlots(st, slots) {
  st.tiers.forEach(t => {
    const v = Number(slots[t.key]);
    if (!isFinite(v) || v <= 0) return;
    t.slots = String(v);
    t.sub = v + '건';
  });
}

// 구간 단가·인원·이름(get_my_orient_tier_fees) — 기다리지 않는다. 못 받으면 단추 줄 없이 직접 입력만(bw04-01g)
async function _bofLoadTierFees(st) {
  const { data: res, error } = await brandRpc('get_my_orient_tier_fees', { p_sheet_id: st.sheetId });
  if (st !== _bof || error || !res || res.success !== true) return;
  st.tierFees = {
    fees: (res.fees && typeof res.fees === 'object') ? res.fees : {},
    override: (res.override_krw === null || res.override_krw === undefined) ? null : Number(res.override_krw),
    formType: res.form_type || _bofFormType(st),
    slots: (res.slots && typeof res.slots === 'object') ? res.slots : null,
    minSlots: (res.min_slots === null || res.min_slots === undefined) ? null : Number(res.min_slots),
    optionFees: (res.option_fees && typeof res.option_fees === 'object') ? res.option_fees : null
  };
  const allSlots = !!(res.slots && typeof res.slots === 'object') &&
    ['t50', 't100', 't300', 't500plus'].every(k => { const v = Number(res.slots[k]); return isFinite(v) && v > 0; });
  _bofApplyTierLabels(st, res.names, res.options);
  if (allSlots) { _bofApplyTierSlots(st, res.slots); st.tierSlotsReady = true; }
  _bofPaintTiers(st);
  st.root.querySelectorAll('[data-extra-fee]').forEach(el => { el.textContent = _bofExtraFeeText(st, el.dataset.extraFee); });
}

function _bofPaintTiers(st) {
  const card = st.root.querySelector('.bof-card');
  if (!card) return;
  const row = card.querySelector('.bof-tier');
  if (row) {
    row.hidden = !st.tierSlotsReady;
    row.querySelectorAll('.bof-tier-btn').forEach(b => {
      const o = st.tiers.find(t => t.key === b.dataset.tier); if (!o) return;
      b.querySelector('.bof-tier-name').textContent = o.name;
      b.querySelector('.bof-tier-sub').textContent = o.sub;
      b.querySelector('.bof-tier-opt').textContent = o.option || '';
      b.querySelector('.bof-tier-price').textContent = _bofTierPriceText(st, b.dataset.tier);
    });
  }
  const note = card.querySelector('.bof-tier-note');
  if (note) { const t = _bofTierNoteText(st); note.textContent = t; note.hidden = !t; }
  _bofSyncTierMode(st);
}
// 단추 하나 · 직접 입력 · 아무것도 아님 중 하나만 켠다(orient.html setTierMode 와 같은 규칙)
function _bofSetTierMode(card, mode) {
  card.querySelectorAll('.bof-tier-btn').forEach(b => {
    const on = !!mode && b.dataset.tier === mode;
    b.classList.toggle('is-on', on);
    b.setAttribute('aria-pressed', String(on));
  });
  const box = card.querySelector('.bof-tier-direct');
  if (box) box.classList.toggle('is-on', mode === 'direct');
}
function _bofSyncTierMode(st) {
  const card = st.root.querySelector('.bof-card'); if (!card) return;
  const direct = card.querySelector('.f-slots-direct');
  if (direct && document.activeElement === direct) { _bofApplyTierDirectInfo(st); return; }   // 적던 숫자를 지우지 않는다
  const n = _bofReadSlots(card.querySelector('.f-slots').value);
  const btnOpt = (n && st.tierSlotsReady) ? st.tiers.find(t => !t.noButton && t.slots && String(t.slots) === String(n)) : null;
  if (btnOpt) { if (direct) direct.value = ''; _bofSetTierMode(card, btnOpt.key); }
  else if (n) { if (direct) direct.value = String(n); _bofSetTierMode(card, 'direct'); }
  else _bofSetTierMode(card, null);
  _bofApplyTierDirectInfo(st);
}
function _bofApplyTierDirectInfo(st) {
  const card = st.root.querySelector('.bof-card'); if (!card) return;
  const el = card.querySelector('.bof-tier-direct-info');
  const input = card.querySelector('.f-slots-direct');
  const n = _bofReadSlots(input ? input.value : '');
  const min = _bofMinSlots(st);
  if (el) el.textContent = (n && n < min) ? '최소 ' + min.toLocaleString('ko-KR') + '명부터 신청할 수 있습니다 — 담당자와 협의해 주십시오.' : '';
  if (input) input.min = String(min);
}

// ── 이미지 행(파일 업로드 또는 URL 공유) — 상태 셋: ①고르기 ②URL 입력 ③칩(결과)
function _bofUploadName(name, value) {
  if (name) return name;
  try { return decodeURIComponent(new URL(value).pathname.split('/').pop() || '') || '올린 파일'; } catch (e) { return '올린 파일'; }
}
function _bofImageRowHtml(value, type, name) {
  const isUpload = type === 'upload';
  const has = !!value;
  const href = isUpload ? (/^https:\/\//i.test(value || '') ? value : '') : (/^https?:\/\//i.test(value || '') ? value : '');
  const label = isUpload ? _bofUploadName(name, value) : (value || '');
  return '<div class="bof-img" data-img data-img-type="' + (isUpload ? 'upload' : 'url') + '"' + (isUpload && name ? ' data-img-name="' + brandEsc(name) + '"' : '') + '>' +
    '<div class="bof-img-head"><span class="bof-img-title">파일 첨부 또는 공유 링크</span>' +
      '<button type="button" class="bof-img-del" data-bof-act="img-del"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">close</span>삭제</button></div>' +
    '<div class="bof-img-body">' +
      '<div class="bof-img-sample"><img src="' + BOF_SAMPLE_IMG + '" alt="제품 이미지 예시 — 배경 없는 누끼 이미지" width="85" height="85" loading="lazy"><span>예시 이미지 참고</span></div>' +
      '<div class="bof-img-main">' +
        '<input type="hidden" class="img-value" value="' + brandEsc(value || '') + '">' +
        '<div class="bof-img-chip"' + (has ? '' : ' hidden') + '>' +
          '<span class="material-icons-round notranslate bof-img-chip-icon" translate="no" aria-hidden="true">' + (isUpload ? 'attachment' : 'link') + '</span>' +
          '<a class="bof-img-name" href="' + brandEsc(href) + '" target="_blank" rel="noopener noreferrer">' + brandEsc(label) + '</a>' +
          '<button type="button" class="bof-img-clear" data-bof-act="img-clear"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">close</span>제거</button></div>' +
        '<div class="bof-img-choose"' + (has ? ' hidden' : '') + '>' +
          '<button type="button" class="bof-btn-line" data-bof-act="img-file"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">upload_file</span>파일 업로드</button>' +
          '<button type="button" class="bof-btn-line" data-bof-act="img-url"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">link</span>URL 공유</button>' +
          '<input type="file" class="bof-img-file" hidden accept=".jpg,.jpeg,.png,.webp,.pdf,.docx,.xlsx,.pptx,.heic,.heif,image/jpeg,image/png,image/webp,image/heic,image/heif,application/pdf">' +
          '<span class="bof-img-status" role="status"></span></div>' +
        '<div class="bof-img-url" hidden>' +
          '<input type="url" class="bof-input bof-img-url-input" placeholder="https://..." aria-label="공유 링크(URL)">' +
          '<button type="button" class="bof-btn-dark" data-bof-act="img-url-ok">확인</button>' +
          '<button type="button" class="bof-btn-line" data-bof-act="img-url-cancel">취소</button></div>' +
        '<p class="bof-hint bof-img-hint"' + (has ? ' hidden' : '') + '>이미지·PDF·문서(워드·엑셀·PPT)는 「파일 업로드」, 외부 링크는 「URL 공유」를 눌러 주십시오.<br>600×600px 이상의 누끼(배경 제거) 이미지 또는 텍스트·배경이 없는 제품 사진으로 올려 주십시오.</p>' +
      '</div>' +
    '</div>' +
  '</div>';
}

// ── 카드(시트 하나 = 형식 하나 + 제품 하나) — orient.html cardHtmlNew 의 칸·클래스 그대로(지우면 저장·검사가 빈다)
function _bofField(label, inner, opts) {
  const o = opts || {};
  return '<div class="bof-field' + (o.cls ? ' ' + o.cls : '') + '">' +
    '<label class="bof-label"' + (o.forId ? ' for="' + o.forId + '"' : '') + '>' + brandEsc(label) + (o.req ? '<span class="bof-req" aria-hidden="true">*</span>' : '') + (o.opt ? ' <span class="bof-opt">(선택)</span>' : '') + '</label>' +
    inner + '</div>';
}
function _bofCardHtml(st, card) {
  const ft = _bofFormType(st);
  const ch = _bofChannel(st);
  const p = card.product || {};
  const r = card.recruit || {};
  const sale = card.sale || {};
  const sd = card.seeding || {};
  const pg = card.purchase_guide || {};
  const id = 'bof' + (++st.seq);
  const attrs = (card.uid ? ' data-uid="' + brandEsc(card.uid) + '"' : '') +
    (card.campaign_id ? ' data-campaign-id="' + brandEsc(card.campaign_id) + '"' : '') +
    (card.linked_existing ? ' data-linked-existing="1"' : '') +
    ['goods_code', 'store_name', 'image_url', 'price_list']
      .map(k => (sale[k] != null && sale[k] !== '') ? ' data-sale-' + k.replace('_', '-') + '="' + brandEsc(String(sale[k])) + '"' : '').join('');
  const imgs = Array.isArray(card.images) && card.images.length ? card.images : [{ value: '' }];

  const saleRow =
    '<div class="bof-row bof-row-sale">' +
      _bofField('판매처', '<input type="text" class="bof-input f-market" value="Qoo10" readonly aria-readonly="true">', { cls: 'bof-w-market' }) +
      _bofField('Qoo10 상품 주소', '<input type="url" id="' + id + 'Url" class="bof-input f-sale-url" placeholder="www.qoo10.jp/g/..." value="' + brandEsc(sale.url) + '" inputmode="url" autocomplete="off">' +
        '<p class="bof-hint bof-caution f-saleurl-warn" hidden>Qoo10 상품 주소가 아닌 것 같습니다. 주소를 한 번 더 확인해 주십시오. (그대로 제출할 수 있습니다)</p>', { req: true, forId: id + 'Url', cls: 'bof-w-url' }) +
      _bofField('상품번호', '<input type="text" class="bof-input f-goods-code" value="' + brandEsc(sale.goods_code || '') + '" readonly aria-readonly="true" tabindex="-1">' +
        '<p class="bof-hint f-lookup-hint" hidden></p>', { cls: 'bof-w-goods' }) +
    '</div>';

  const priceHint = '캠페인 진행 기간 중 소비자가 실제로 구매하는 금액으로 작성해주십시오.' + (ft === 'seeding' ? '' : '<br>※ 메가와리 쿠폰 적용 불가');
  const priceRow = '<div class="bof-row' + (ft === 'reviewer' ? '' : ' is-single') + '">' +
    _bofField('판매가', '<input type="text" id="' + id + 'Price" class="bof-input f-price-regular" placeholder="예: 5300" value="' + brandEsc(sale.price_regular) + '" inputmode="numeric">' +
      '<p class="bof-hint">' + priceHint + '</p>', { req: true, forId: id + 'Price' }) +
    (ft === 'reviewer' ? _bofField('배송비', '<input type="text" id="' + id + 'Ship" class="bof-input f-shipping-fee" placeholder="예: 500 (없으면 비워 두십시오)" value="' + brandEsc(sale.shipping_fee) + '" inputmode="numeric">' +
      '<p class="bof-hint">배송비용이 별도로 부과되는 경우 필수로 작성 부탁드립니다.</p>', { forId: id + 'Ship' }) : '') +
  '</div>';

  const pgBlock = ft === 'reviewer' ? (
    '<div class="bof-field bof-pg" role="radiogroup" aria-labelledby="' + id + 'PgLabel">' +
      '<div class="bof-pg-head"><span class="bof-label" id="' + id + 'PgLabel">구매 가이드<span class="bof-req" aria-hidden="true">*</span></span>' +
        '<label class="bof-radio"><input type="radio" name="' + id + 'Pg" value="free"' + (pg.mode === 'free' ? ' checked' : '') + '>자율구매</label>' +
        '<label class="bof-radio"><input type="radio" name="' + id + 'Pg" value="fixed"' + (pg.mode === 'fixed' ? ' checked' : '') + '>지정구매</label></div>' +
      '<div class="bof-input is-readonly bof-pg-free"' + (pg.mode === 'free' ? '' : ' hidden') + '>' + brandEsc(BOF_PURCHASE_GUIDE_FREE) + '</div>' +
      '<div class="bof-pg-fixed"' + (pg.mode === 'fixed' ? '' : ' hidden') + '>' +
        _bofRichEditorHtml(_bofRichInitial(pg.options), 'f-pg-options', '구매할 옵션을 적어 주십시오. 예: 50ml / 핑크', '구매할 옵션') +
        _bofCounter('f-pg-options') + '</div>' +
    '</div>') : '';

  const tierBtns = st.tiers.filter(t => !t.noButton).map(t =>
    '<button type="button" class="bof-tier-btn" data-tier="' + t.key + '" data-bof-act="tier" aria-pressed="false">' +
      '<span class="bof-tier-name">' + brandEsc(t.name) + '</span><span class="bof-tier-sub">' + brandEsc(t.sub) + '</span>' +
      '<span class="bof-tier-opt">' + brandEsc(t.option) + '</span><span class="bof-tier-price"></span></button>').join('');
  const slotsBlock = _bofField('모집 인원',
    '<div class="bof-tier"' + (st.tierSlotsReady ? '' : ' hidden') + '>' + tierBtns + '</div>' +
    // 🔴 인원 숫자는 감춰진 칸 하나(.f-slots) — 단추와 직접 입력이 채운다. 지우면 저장·검사·요약이 빈다
    '<input type="hidden" class="f-slots" value="' + brandEsc(p.slots) + '">' +
    '<div class="bof-tier-direct"><label class="bof-tier-direct-label" for="' + id + 'Slots">또는 직접 입력</label>' +
      '<input type="number" id="' + id + 'Slots" class="bof-input f-slots-direct" min="1" step="1" placeholder="예: 30" value="' + brandEsc(p.slots) + '" inputmode="numeric">' +
      '<span class="bof-tier-direct-unit">명</span><span class="bof-tier-direct-info bof-warn" aria-live="polite"></span></div>' +
    '<p class="bof-hint bof-tier-note" hidden></p>' +
    '<p class="bof-hint">충전식 이용이 곧 가능해집니다. 준비되면 다시 안내드리겠습니다.</p>', { req: true, cls: 'bof-slots' });

  const extrasBlock = ft === 'reviewer' ? _bofField('추가 옵션',
    '<div class="bof-checks">' + BOF_EXTRA_MARKETS.map(o =>
      '<label class="bof-check"><input type="checkbox" class="f-extra-' + o.key + '"' + ((sale.extra_markets || []).includes(o.key) ? ' checked' : '') + '>' +
        brandEsc(o.label) + ' <span class="bof-fee" data-extra-fee="' + o.key + '">' + brandEsc(_bofExtraFeeText(st, o.key)) + '</span></label>').join('') + '</div>', { opt: true }) : '';

  const startBlock = _bofField('희망 모집 시작일',
    '<input type="date" id="' + id + 'Start" class="bof-input f-recruit-start" value="' + brandEsc(r.recruit_start) + '">' +
    (ft === 'seeding' ? '<p class="bof-hint bof-schedule" data-schedule-hint></p>' : ''), { forId: id + 'Start' });

  const reviewerGuide = ft === 'reviewer' ? _bofField('리뷰 가이드',
    _bofRichEditorHtml(_bofRichInitial(card.review_guide), 'f-review-guide', '일본 스텔스 마케팅(스테마) 규제로 리뷰 내용이나 별점(★)을 지정·강요할 수 없습니다. 제품의 매력 포인트, 꼭 전달하고 싶은 내용, 사진 촬영 시 참고할 점을 작성해 주십시오.', '리뷰 가이드') +
    _bofCounter('f-review-guide')) : '';

  const appeal = (sd.appeal != null && sd.appeal !== '') ? sd.appeal
    : (Array.isArray(sd.guides) ? sd.guides.map(g => ((g && g.guide) || '').trim()).filter(Boolean).join('\n') : '');
  const seedingBlock = ft === 'seeding' ? (
    _bofField('게시 채널', '<div><span class="bof-ch-chip">' + brandEsc(BRAND_ORIENT_CHANNEL[ch] || ch || '채널 미지정') + '</span></div>' +
      // ⚠️ 피그마 그림은 「한 장 더 만들어 주십시오」, 설명 패널은 「받아 진행해 주십시오」 — 브랜드는 시트를 만들 수 없어 패널 쪽(기획 확인 필요)
      '<p class="bof-hint">발급 때 정해진 채널입니다. 다른 채널도 진행하려면 오리엔시트를 한 장 더 받아 진행해 주십시오.</p>') +
    // 저장 열쇠말은 seeding.appeal 그대로(이름만 「리뷰 가이드」) — 바꾸면 저장된 값이 사라지고 서버 글자 수 검사와 어긋난다
    _bofField('리뷰 가이드', '<textarea id="' + id + 'Appeal" class="bof-input bof-textarea f-appeal" placeholder="인플루언서분들이 업로드 시 강조했으면 하는 소구 포인트, 어필 포인트, NG 사항 등을 작성해 주십시오.">' + brandEsc(appeal) + '</textarea>' + _bofCounter('f-appeal'), { forId: id + 'Appeal' }) +
    // ⚠️ 피그마 bw04-02 는 촬영 가이드에 글자 수 표시가 없다 — 서버는 1,000자로 막으므로 표시를 둔다(기획 확인 필요)
    _bofField('촬영 가이드', '<textarea id="' + id + 'Shoot" class="bof-input bof-textarea f-shooting" placeholder="촬영 구도·분위기·필수 컷 등을 적어 주십시오.">' + brandEsc(sd.shooting_guide) + '</textarea>' + _bofCounter('f-shooting'), { forId: id + 'Shoot' }) +
    _bofField('게시물에 꼭 넣을 해시태그 (최대 5개)', '<input type="text" id="' + id + 'Tags" class="bof-input f-hashtags" placeholder="#브랜드명 #캠페인 (공백 또는 쉼표로 구분)" value="' + brandEsc(Array.isArray(sd.hashtags) ? sd.hashtags.join(' ') : (sd.hashtags || '')) + '">' +
      '<p class="bof-hint bof-warn bof-hashtag-warn" hidden></p>', { forId: id + 'Tags' }) +
    _bofField('게시물에 태그할 계정', '<input type="text" id="' + id + 'Acc" class="bof-input f-account-tags" placeholder="@브랜드공식계정" value="' + brandEsc(sd.account_tags) + '">' +
      '<p class="bof-hint">인플루언서가 게시물에 멘션(@)할 계정입니다. 브랜드 공식 SNS 계정을 포함해 적어 주십시오.</p>', { req: true, forId: id + 'Acc' })
  ) : '';

  const imgBlock = _bofField('예시 이미지·자료',
    '<p class="bof-hint bof-hint-top">「파일 업로드」로 캠페인 대표이미지로 활용될 파일을 추가해주십시오. 참고 이미지가 여러개인 경우 「URL 공유」로 공유 부탁드립니다. (최대 5개)</p>' +
    '<div class="bof-img-list">' + imgs.map(x => _bofImageRowHtml(x.value, x.type, x.name)).join('') + '</div>' +
    '<button type="button" class="bof-add-btn" data-bof-act="img-add"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">add</span>이미지·파일 추가</button>');

  const badgeCls = ft === 'seeding' ? ' is-seeding' : ' is-reviewer';
  return '<section class="bof-card" id="' + id + '" data-ctype="' + brandEsc(ft) + '"' + attrs + '>' +
    '<div class="bof-card-title"><span class="bof-type' + badgeCls + '">' + brandEsc(BOF_FORM_LABEL[ft] || ft) + '</span>' +
      '<span class="bof-product-title is-empty">제품명이 출력됩니다.</span></div>' +
    saleRow +
    _bofField('제품명', '<input type="text" id="' + id + 'Name" class="bof-input f-product-name" placeholder="제품명" value="' + brandEsc(p.name) + '">', { req: true, forId: id + 'Name' }) +
    priceRow + pgBlock + slotsBlock + extrasBlock + startBlock + reviewerGuide + seedingBlock + imgBlock +
  '</section>';
}

// 브랜드 정보 네 칸(결정 8) — 견적서 「수신」·관리자 상세가 data.brand 를 읽는다. 피그마 bw04-01·02 에 아직 없다(기획에게 넘김 4)
function _bofBrandInfoHtml(b) {
  return '<section class="bof-card bof-brand-card" aria-labelledby="bofBrandTitle">' +
    '<h3 class="bof-card-h" id="bofBrandTitle">브랜드 정보</h3>' +
    '<p class="bof-hint bof-hint-top">견적서의 수신과 담당자 연락처로 쓰입니다. 로그인한 계정 정보로 미리 채웠으니 다르면 고쳐 주십시오.</p>' +
    _bofField('브랜드명', '<input type="text" id="bofBrandName" class="bof-input" placeholder="브랜드명" value="' + brandEsc(b.name) + '">', { forId: 'bofBrandName' }) +
    '<div class="bof-row">' +
      _bofField('담당자명', '<input type="text" id="bofBrandContact" class="bof-input" placeholder="담당자 이름" value="' + brandEsc(b.contact_name) + '" autocomplete="name">', { forId: 'bofBrandContact' }) +
      _bofField('연락처', '<input type="tel" id="bofBrandPhone" class="bof-input" placeholder="숫자만 입력" value="' + brandEsc(b.phone) + '" inputmode="numeric" autocomplete="tel">', { forId: 'bofBrandPhone' }) +
    '</div>' +
    _bofField('이메일', '<input type="email" id="bofBrandEmail" class="bof-input" placeholder="contact@yourbrand.com" value="' + brandEsc(b.email) + '" autocomplete="email">' +
      '<p class="bof-hint bof-warn bof-email-warn" hidden>이메일 형식이 올바르지 않습니다.</p>', { forId: 'bofBrandEmail' }) +
  '</section>';
}

function _bofNoticeHtml(st) {
  const ft = _bofFormType(st);
  const lines = Object.prototype.hasOwnProperty.call(BOF_NOTICE_LINES, ft) ? BOF_NOTICE_LINES[ft] : [];
  if (!lines.length) return '';   // 형식을 모르면 상자를 감춘다(누를 수 없는 체크를 요구하지 않게)
  const d = st.data || {};
  const checked = !!(d.notice_ack && typeof d.notice_ack === 'object') || d.notice_ack_checked === true;
  return '<section class="bof-card bof-notice" id="bofNoticeBox" aria-labelledby="bofNoticeTitle">' +
    '<h3 class="bof-card-h" id="bofNoticeTitle"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">fact_check</span>꼭 확인해 주십시오</h3>' +
    '<ol class="bof-notice-list">' + lines.map(l => '<li>' + l + '</li>').join('') + '</ol>' +
    '<label class="bof-notice-check" id="bofNoticeLabel"><input type="checkbox" id="bofNoticeAck"' + (checked ? ' checked' : '') + '>위 내용을 모두 확인했습니다.<span class="bof-req" aria-hidden="true">*</span></label>' +
  '</section>';
}

// ── 모달 그리기
function _bofStatusPill(st) {
  if (st.screen === 'registered') return { label: '캠페인 등록됨', cls: 'is-registered' };
  return st.status === 'submitted' ? { label: '제출됨', cls: 'is-submitted' } : { label: '작성 중', cls: 'is-editing' };
}
function _bofRelTime(iso) {
  const t = new Date(iso).getTime();
  if (isNaN(t)) return '';
  const m = Math.floor((Date.now() - t) / 60000);
  if (m < 1) return '방금';
  if (m < 60) return m + '분 전에';
  const h = Math.floor(m / 60);
  if (h < 24) return h + '시간 전에';
  return brandFormatDateTime(iso) + '에';
}
// 마지막 저장자(결정 7) — 다른 사람이 저장했을 때만 늘 보이고, 충돌 때는 누구든. 「3분 전」은 열 때·충돌 때만 계산
function _bofPaintLastEditor(st, force) {
  const el = _bofEl('#boLastEditor'); if (!el) return;
  const s = st.sheet || {};
  const show = !!s.last_edited_at && (force || !s.last_edited_by_me);
  el.hidden = !show;
  if (!show) return;
  const who = s.last_edited_by_me ? '내가' : (s.last_edited_by_name ? s.last_edited_by_name + '님이' : '다른 사람이');
  el.querySelector('.bof-last-text').textContent = who + ' ' + _bofRelTime(s.last_edited_at) + ' 수정했습니다';
}

function _bofModalHtml(st) {
  const s = st.sheet;
  const pill = _bofStatusPill(st);
  return '<div class="bof-box" role="dialog" aria-modal="true" aria-labelledby="bofTitle">' +
    '<div class="bof-scroll" id="bofScroll" tabindex="-1">' +
      '<header class="bof-head">' +
        '<div class="bof-head-text"><h2 id="bofTitle">오리엔시트 ' + brandEsc(s.orient_no || '') + '</h2>' +
          '<p class="bof-sub">' + brandEsc(BOF_MSG.subtitle) + '</p>' +
          '<p class="bof-last" id="boLastEditor" hidden><span class="material-icons-round notranslate" translate="no" aria-hidden="true">history</span><span class="bof-last-text"></span></p></div>' +
        '<button type="button" class="bof-close" data-bof-act="close" aria-label="닫기"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">close</span></button>' +
      '</header>' +
      '<div id="boFormNotes" class="bof-notes">' +
      '<div class="bof-note is-conflict" id="boConflictNote" role="alert" hidden><span class="material-icons-round notranslate" translate="no" aria-hidden="true">sync_problem</span>' +
        '<span>' + brandEsc(BOF_MSG.conflictNote) + '</span><button type="button" class="bof-note-btn" data-bof-act="reload">새로고침</button></div>' +
      '<div class="bof-note is-restore" id="boRestoreNote" hidden><span class="material-icons-round notranslate" translate="no" aria-hidden="true">history</span>' +
        '<span class="bof-restore-text"></span><span class="bof-note-actions"><button type="button" class="bof-note-btn is-ghost" data-bof-act="restore-discard">버리기</button>' +
        '<button type="button" class="bof-note-btn" data-bof-act="restore">불러오기</button></span></div>' +
      '<div class="bof-note is-info" id="boResubmitNote"' + (st.status === 'submitted' ? '' : ' hidden') + '><span class="material-icons-round notranslate" translate="no" aria-hidden="true">check_circle</span>' +
        '<span>' + brandEsc(BOF_MSG.resubmitNote) + '</span></div>' +
      '</div>' +
      '<div id="boForm" class="bof-form"></div>' +
      '<div id="boConfirm" class="bof-form" hidden></div>' +   // bw04-03 작성 내용 확인
      '<div id="boQuote" class="bof-form" hidden></div>' +     // bw04-04·04a 견적서 확인(제출 전)
      '<div id="boDone" class="bof-form" hidden></div>' +      // bw04-05·05a·05b 제출 완료 · bw04-01c 캠페인 등록됨
    '</div>' +
    '<footer class="bof-bar" id="boSaveBar" data-save-state="idle">' +
      '<span class="bof-pill ' + pill.cls + '" id="boPill">' + pill.label + '</span>' +
      '<span class="bof-save" role="status" aria-live="polite"><span class="material-icons-round notranslate bof-save-icon" translate="no" aria-hidden="true"></span><span class="bof-save-text"></span>' +
        '<button type="button" class="bof-save-retry" data-bof-act="retry" hidden>· 다시 시도</button></span>' +
      '<span class="bof-bar-btns" id="boBarBtns"></span>' +
    '</footer>' +
  '</div>';
}

// 폼 채우기 — 제출된 시트는 작성본(draft_data)이 있으면 그것으로(524)
function _bofFillForm(st, data) {
  const form = _bofEl('#boForm');
  const cards = Array.isArray(data.cards) && data.cards.length ? [data.cards[0]] : [{ form_type: _bofFormType(st) }];
  form.innerHTML = _bofCardHtml(st, cards[0]) + _bofBrandInfoHtml(data.brand || {}) + _bofNoticeHtml(st);
  const card = form.querySelector('.bof-card');
  _bofUpdateTitle(card);
  _bofRefreshCounts(card);
  _bofUpdateSchedule(card);
  _bofPaintTiers(st);
  _bofUpdateHashtagWarn(card);
  const url = card.querySelector('.f-sale-url');
  if (url) _bofToggleUrlWarn(url);
  // 큐텐에서 불러온 값이 이미 있으면 상품번호 칸에 보인다(빈 칸이면 그대로)
}

// 브랜드 정보가 비면 계정 값으로 미리 채운다(결정 8 — 고칠 수 있고, 계정과 자동으로 맞추지 않는다).
//   🔴 채우기만 하고 저장하지 않는다 — 열기만 해도 「작성 중」·「최근 수정」이 생기지 않게. 다음 저장 때 함께 실린다
async function _bofPrefillBrandInfo(st) {
  const set = (id, v) => { const el = _bofEl('#' + id); if (el && !el.value.trim() && v) el.value = v; };
  const cur = getCurrentBrand();
  set('bofBrandName', cur ? cur.name : '');
  set('bofBrandContact', brandSession ? brandSession.name : '');
  set('bofBrandEmail', brandSession ? brandSession.email : '');
  const phoneEl = _bofEl('#bofBrandPhone');
  if (!phoneEl || phoneEl.value.trim() || !st.uid || !brandDb) return;
  try {
    // 마이페이지와 같은 조회(본인 행만 — 브랜드 계정 표 읽기 정책)
    const { data } = await brandDb.from('brand_accounts').select('phone').eq('auth_id', st.uid).maybeSingle();
    if (st !== _bof) return;
    if (data && data.phone && !phoneEl.value.trim()) phoneEl.value = String(data.phone).replace(/[^0-9]/g, '');
  } catch (e) { /* 연락처만 비워 둔다 */ }
}

// ── 수집(DOM → data) — orient.html collectCardNew·collectData 와 같은 모양
function _bofCollectCard(st, el) {
  const ft = _bofFormType(st);
  const q = sel => el.querySelector(sel);
  const val = sel => { const n = q(sel); return n ? n.value.trim() : ''; };
  const images = Array.from(el.querySelectorAll('[data-img]')).map(row => {
    const type = row.dataset.imgType === 'upload' ? 'upload' : 'url';
    const o = { type, value: _bofNormalizeUrl(row.querySelector('.img-value').value) };
    if (type === 'upload' && row.dataset.imgName) o.name = row.dataset.imgName;
    return o;
  }).filter(x => x.value);
  const out = {
    form_type: ft,
    product: { name: val('.f-product-name'), slots: val('.f-slots') },
    recruit: { recruit_start: val('.f-recruit-start') },
    sale: { market: 'Qoo10', url: _bofNormalizeUrl(val('.f-sale-url')), price_regular: val('.f-price-regular') },
    images
  };
  const tierBtn = el.querySelector('.bof-tier-btn.is-on');
  if (tierBtn) out.product.slots_tier = tierBtn.dataset.tier;
  else { const k = _bofTierOfSlots(st, _bofReadSlots(out.product.slots)); if (k) out.product.slots_tier = k; }
  const extras = BOF_EXTRA_MARKETS.filter(o => { const n = q('.f-extra-' + o.key); return n && n.checked; }).map(o => o.key);
  if (extras.length) out.sale.extra_markets = extras;
  const ship = val('.f-shipping-fee');
  if (ship) out.sale.shipping_fee = ship;
  [['goods_code', 'saleGoodsCode'], ['store_name', 'saleStoreName'], ['image_url', 'saleImageUrl'], ['price_list', 'salePriceList']].forEach(([k, ds]) => {
    const v = el.dataset[ds];
    if (v) out.sale[k] = (k === 'price_list') ? Number(v) : v;
  });
  if (ft === 'reviewer') {
    out.review_guide = _bofRichValue(q('.f-review-guide'));
    const pick = el.querySelector('.bof-pg input[type="radio"]:checked');
    if (pick) {
      out.purchase_guide = { mode: pick.value };
      const opts = _bofRichValue(q('.f-pg-options'));
      if (pick.value === 'fixed' && opts) out.purchase_guide.options = opts;
    }
  }
  if (ft === 'seeding') {
    out.seeding = {
      channels: _bofChannel(st) ? [_bofChannel(st)] : [],
      appeal: val('.f-appeal'),
      hashtags: val('.f-hashtags').split(/[\s,]+/).map(x => x.trim()).filter(Boolean).slice(0, BOF_MAX_HASHTAGS),
      account_tags: val('.f-account-tags'),
      shooting_guide: val('.f-shooting')
    };
  }
  // 되돌려 보내는 값 셋 — 값이 있을 때만 키(빈 키면 관리자가 「발행됨」으로 오독, 안 실으면 발행 표시가 사라진다)
  const uid = el.getAttribute('data-uid'); if (uid) out.uid = uid;
  const cid = el.getAttribute('data-campaign-id'); if (cid) out.campaign_id = cid;
  if (el.getAttribute('data-linked-existing')) out.linked_existing = true;
  return out;
}
function _bofCollect(st) {
  st.lastCardEls = Array.from(st.root.querySelectorAll('#boForm > .bof-card[data-ctype]'));
  const v = id => { const el = st.root.querySelector('#' + id); return el ? el.value.trim() : ''; };
  const out = {
    brand: { name: v('bofBrandName'), contact_name: v('bofBrandContact'), email: v('bofBrandEmail'), phone: v('bofBrandPhone') },
    cards: st.lastCardEls.map(el => _bofCollectCard(st, el))
  };
  const ack = st.root.querySelector('#bofNoticeAck');
  if (ack && ack.checked) out.notice_ack_checked = true;   // 확인 기록·시각은 서버가 쓴다(445)
  return out;
}

// ── 이 기기 사본(기본값 6) — 저장되지 못한 글만 남는다(저장 성공 때 지운다)
function _bofBackupKey(st) { return BOF_BACKUP_PREFIX + st.uid + '.' + st.sheetId; }
function _bofReadBackup(st) {
  if (!st.uid) return null;
  try { return JSON.parse(localStorage.getItem(_bofBackupKey(st)) || 'null'); } catch (e) { return null; }
}
function _bofWriteBackup(st, data, extra) {
  if (!st.uid) return;
  try { localStorage.setItem(_bofBackupKey(st), JSON.stringify(Object.assign({ data, at: Date.now(), version: st.version }, extra || {}))); } catch (e) { /* 저장소 막힘 */ }
}
function _bofDropBackup(st) {
  if (!st.uid) return;
  try { localStorage.removeItem(_bofBackupKey(st)); } catch (e) { /* 저장소 막힘 */ }
}
// 열 때 — 서버와 다른 사본이 있으면 되살리기를 묻는다(자동으로 덮지 않는다 — 다른 기기에서 나중에 저장했을 수 있다)
function _bofDetectBackup(st) {
  st.pendingBackup = null;
  const bk = _bofReadBackup(st);
  const note = _bofEl('#boRestoreNote');
  if (note) note.hidden = true;
  if (!bk || !bk.data || typeof bk.data !== 'object') return;
  // 판 번호가 서버보다 옛것이면 다른 곳에서 나중에 저장한 것 — 버린다. 단 충돌을 겪은 글·저장 중에 남긴 글(inflight)은 제안한다
  //   (inflight: 탭을 닫을 때 저장이 서버에 가 있었다 — 그 저장이 성공해 판이 앞서도 사본이 더 새 글이다)
  if (typeof bk.version !== 'number' || (bk.version < st.version && !bk.conflict && !bk.inflight)) { _bofDropBackup(st); return; }
  let same = false;
  try { same = JSON.stringify(bk.data) === JSON.stringify(_bofCollect(st)); } catch (e) { same = false; }
  if (same) { _bofDropBackup(st); return; }
  st.pendingBackup = bk;
  const at = bk.at ? new Date(bk.at) : null;
  const when = at && !isNaN(at) ? ' (' + (at.getMonth() + 1) + '월 ' + at.getDate() + '일 ' + String(at.getHours()).padStart(2, '0') + ':' + String(at.getMinutes()).padStart(2, '0') + ')' : '';
  note.querySelector('.bof-restore-text').textContent = '이 기기에 저장되지 못한 작성 내용이 있습니다' + when + '. 불러오시겠습니까? 불러오면 지금 화면의 내용을 덮어씁니다.';
  note.hidden = false;
}
function _bofRestoreBackup(st) {
  if (!st.pendingBackup) return;
  // 서버가 지키는 값(발급 정보·견적·확인 기록)은 서버 판을 쓴다
  const keep = {};
  ['issued', 'quote', 'quote_history', 'quote_error', 'notice_ack'].forEach(k => { if (st.data && k in st.data) keep[k] = st.data[k]; });
  const merged = Object.assign({}, st.pendingBackup.data, keep);
  _bofFillForm(st, merged);
  const ack = st.root.querySelector('#bofNoticeAck');
  if (ack && !(st.data && st.data.notice_ack)) ack.checked = merged.notice_ack_checked === true;
  st.pendingBackup = null;
  _bofEl('#boRestoreNote').hidden = true;
  if (!st.conflicted) _bofOnInput(st, 'restored');
  else _bofSetSaveState(st, 'restored');
  brandToast('이 기기에 남아 있던 내용을 불러왔습니다.');
}

// ── 아래 바 저장 상태
function _bofSetSaveState(st, kind, timeText) {
  const bar = st.root.querySelector('#boSaveBar'); if (!bar) return;
  const def = BOF_SAVE_STATE[kind] || BOF_SAVE_STATE.idle;
  bar.dataset.saveState = kind;
  const icon = bar.querySelector('.bof-save-icon');
  icon.textContent = def.icon;
  icon.hidden = !def.icon;
  bar.querySelector('.bof-save-text').textContent = def.text + (timeText ? ' ' + timeText : '');
  bar.querySelector('.bof-save-retry').hidden = !def.retry;
}

// ── 자동 저장(한 번에 하나, 대기 하나 — orient.html saveInFlight·saveQueued 그대로)
function _bofOnInput(st, stateAfter) {
  if (!st || st.conflicted) return;
  st.dirty = true;
  _bofSetSaveState(st, stateAfter || 'saving');
  clearTimeout(st.saveTimer);
  st.saveTimer = setTimeout(() => _bofDoAutosave(st), BOF_AUTOSAVE_DELAY);
}
function _bofFlush(st) {
  if (st.conflicted || !st.dirty) return;
  clearTimeout(st.saveTimer);
  _bofDoAutosave(st);
}
async function _bofDoAutosave(st, preCollected) {
  if (st.conflicted) return;
  if (st.saveInFlight) { st.saveQueued = true; return; }
  st.saveInFlight = _bofRunAutosave(st, preCollected);
  try { await st.saveInFlight; } finally {
    st.saveInFlight = null;
    if (st.saveQueued && !st.conflicted && !st.closed) { st.saveQueued = false; _bofDoAutosave(st); }
  }
}
// preCollected = 모달을 닫으며 넘긴 값(그때는 DOM 이 없다). 응답 뒤 화면은 모달이 아직 열려 있을 때만 고친다
async function _bofRunAutosave(st, preCollected) {
  const data = preCollected || _bofCollect(st);
  const cardEls = preCollected ? [] : st.lastCardEls.slice();
  _bofWriteBackup(st, data);
  let res = null, error = null;
  try { ({ data: res, error } = await brandRpc('save_my_orient_draft', { p_sheet_id: st.sheetId, p_data: data, p_version: st.version })); }
  catch (e) { error = e; }
  if (!error && res && res.success === true) {
    st.version = res.version;
    // 서버가 붙인 카드 번호를 요청 때 훑은 카드에 담는다(응답 뒤 화면을 다시 훑으면 밀려 붙는다 — orient.html applyCardUids)
    if (Array.isArray(res.card_uids)) cardEls.forEach((el, i) => { if (res.card_uids[i]) el.setAttribute('data-uid', String(res.card_uids[i])); });
    st.dirty = st.saveQueued;
    if (!st.saveQueued) _bofDropBackup(st);
    if (st.sheet) { st.sheet.last_edited_at = new Date().toISOString(); st.sheet.last_edited_by_me = true; }
    st.savedOnce = true;
    // 활동 기록은 모달 한 번 열 때 첫 성공 한 번만(기본값 8)
    if (!st.touched) { st.touched = true; brandTouchActivity(); }
    if (!st.closed) {
      const now = new Date();
      _bofSetSaveState(st, st.saveQueued ? 'saving' : 'saved', st.saveQueued ? '' : String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0'));
      _bofPaintLastEditor(st, false);
    }
    return;
  }
  if (st.closed) return;   // 닫힌 뒤의 실패 — 사본이 남아 있어 다음에 열 때 되살리기를 묻는다
  const reason = res && res.reason;
  if (reason === 'conflict') return _bofEnterConflict(st);
  if (reason === 'not_found') return _bofHandleNotFound(st);
  if (reason === 'data_too_large') return _bofSetSaveState(st, 'too_large');
  if (reason === 'expired' || reason === 'consumed') return _bofSetSaveState(st, 'locked');   // 결정 없음 — 지금 폼처럼 글자만(기획에게 넘길 것 3)
  _bofSetSaveState(st, 'failed');
}
async function _bofWaitForSave(st, ms) {
  const deadline = Date.now() + (ms || BOF_SAVE_WAIT_LIMIT_MS);
  while (st.saveInFlight) {
    const left = deadline - Date.now();
    if (left <= 0) return false;
    let timer;
    try { await Promise.race([st.saveInFlight, new Promise(r => { timer = setTimeout(r, left); })]); } catch (e) { /* 아래에서 다시 본다 */ } finally { clearTimeout(timer); }
  }
  return true;
}

function _bofEnterConflict(st) {
  st.conflicted = true;
  if (st.screen !== 'form') _bofShowScreen(st, 'form');   // 충돌 안내는 작성 화면에 있다 — 확인·견적 화면에서 터지면 돌려보낸다
  clearTimeout(st.saveTimer);
  const bk = _bofReadBackup(st);
  if (bk && bk.data) _bofWriteBackup(st, bk.data, { conflict: true, version: bk.version, at: bk.at });   // 서버가 앞서 있어도 다시 열 때 제안
  _bofEl('#boConflictNote').hidden = false;
  _bofSetSaveState(st, 'conflict');
  const sc = _bofEl('#bofScroll'); if (sc) sc.scrollTop = 0;
  // 누가 먼저 저장했나 — 충돌 때는 누구든 보인다(결정 7). 실패하면 표시만 안 한다
  brandRpc('get_my_orient_sheet', { p_sheet_id: st.sheetId }).then(({ data }) => {
    if (st !== _bof || !data || data.success !== true) return;
    st.sheet.last_edited_at = data.last_edited_at;
    st.sheet.last_edited_by_name = data.last_edited_by_name;
    st.sheet.last_edited_by_me = data.last_edited_by_me;
    _bofPaintLastEditor(st, true);
  }).catch(() => {});
}

// 시트를 볼 수 없게 됨(연결 해제·남의 브랜드) — 모달을 닫고 판정을 다시 받는다(기본값 4)
async function _bofHandleNotFound(st) {
  _bofClose(st);
  brandToast(BOF_MSG.cannotOpen, { error: true });
  const state = await refreshBrandLoginState();
  if (state && state.state === 'ok' && typeof loadBrandOrientList === 'function') loadBrandOrientList();
}

// ── 큐텐 상품 정보 불러오기(서버 함수 계정 갈래 — 541) · 빈 칸만 채운다
function _bofIsQoo10(v) { try { return /(^|\.)qoo10\.jp$/i.test(new URL(v).hostname); } catch (e) { return false; } }
function _bofToggleUrlWarn(input) {
  const warn = input.closest('.bof-field').querySelector('.f-saleurl-warn');
  const v = (input.value || '').trim().toLowerCase();
  const off = !v || v.includes('qoo10');
  if (warn) warn.hidden = off;
  input.classList.toggle('is-caution', !off);   // bw04-01a — 주황 테두리(막지 않음)
}
function _bofSetLookupHint(card, html, kind) {
  const h = card.querySelector('.f-lookup-hint'); if (!h) return;
  h.innerHTML = html || '';
  h.hidden = !html;
  h.dataset.kind = kind || '';
}
function _bofClearQoo10Meta(card) {
  ['saleGoodsCode', 'saleStoreName', 'saleImageUrl', 'salePriceList'].forEach(k => { delete card.dataset[k]; });
  const g = card.querySelector('.f-goods-code'); if (g) g.value = '';
}
async function _bofLookup(st, input) {
  const card = input.closest('.bof-card');
  const url = (input.value || '').trim();
  if (!url || !_bofIsQoo10(url)) {
    const had = !!card.dataset.saleGoodsCode;
    _bofSetLookupHint(card, '');
    _bofClearQoo10Meta(card);
    if (had) _bofOnInput(st);
    return;
  }
  if (url === st.lookupUrl && st.lookupResult) { _bofApplyQoo10(st, card, st.lookupResult, false, false); return; }
  _bofSetLookupHint(card, '큐텐에서 상품 정보를 불러오는 중…', 'loading');
  let timer;
  const r = await Promise.race([
    brandCallFunction('qoo10-product-lookup', { sheet_id: st.sheetId, url }, { auth: true }),
    new Promise(res => { timer = setTimeout(() => res({ status: 0, body: null }), BOF_LOOKUP_TIMEOUT_MS); })
  ]);
  clearTimeout(timer);
  if (st !== _bof || !input.isConnected || (input.value || '').trim() !== url) return;   // 기다리는 사이 주소가 바뀌었으면 버린다
  const res = r && r.body;
  if (!res || res.ok !== true) {
    _bofSetLookupHint(card, '자동으로 못 불러왔습니다. 직접 입력해 주십시오.', 'fail');
    const had = !!card.dataset.saleGoodsCode;
    _bofClearQoo10Meta(card);
    if (had) _bofOnInput(st);
    return;
  }
  st.lookupUrl = url; st.lookupResult = res;
  _bofApplyQoo10(st, card, res, false, true);
}
// force = 「불러온 값으로 바꾸기」를 사람이 눌렀을 때만 · notify = 새로 불러온 때만 판매가 안내
function _bofApplyQoo10(st, card, res, force, notify) {
  const nameEl = card.querySelector('.f-product-name');
  const priceEl = card.querySelector('.f-price-regular');
  const priceText = res.price_sale_jpy != null ? String(res.price_sale_jpy) : '';
  let filled = 0, kept = 0;
  if (nameEl && res.product_name) { if (force || !nameEl.value.trim()) { nameEl.value = res.product_name; filled++; } else if (nameEl.value.trim() !== res.product_name) kept++; }
  if (priceEl && priceText) { if (force || !priceEl.value.trim()) { priceEl.value = priceText; filled++; } else if (priceEl.value.trim() !== priceText) kept++; }
  _bofClearQoo10Meta(card);
  if (res.goods_code) card.dataset.saleGoodsCode = String(res.goods_code);
  if (res.store_name) card.dataset.saleStoreName = String(res.store_name);
  if (res.image_url) card.dataset.saleImageUrl = String(res.image_url);
  if (res.price_list_jpy != null) card.dataset.salePriceList = String(res.price_list_jpy);
  const g = card.querySelector('.f-goods-code'); if (g) g.value = res.goods_code ? String(res.goods_code) : '';
  // 피그마 bw04-01 「큐텐에서 불러왔습니다 · 확인해 주십시오 불러온 값으로 바꾸기」 — 스토어·정가는 상품번호 칸 아래 줄에 함께
  const meta = [res.store_name ? '스토어 ' + brandEsc(res.store_name) : '', res.price_list_jpy != null ? '정가 ¥' + Number(res.price_list_jpy).toLocaleString('ja-JP') : ''].filter(Boolean).join(' · ');
  const swap = (!force && kept > 0) ? ' <button type="button" class="bof-link" data-bof-act="lookup-swap">불러온 값으로 바꾸기</button>' : '';
  _bofSetLookupHint(card, '큐텐에서 불러왔습니다 · 확인해 주십시오' + (meta ? ' — ' + meta : '') + swap, 'ok');
  if (filled) _bofUpdateTitle(card);
  _bofOnInput(st);
  if (notify && priceEl) _bofPriceNotice(st, priceEl);
}
// 판매가 확인(orient.html 판매가 안내 모달) — 확인을 누르면 판매가 칸으로 초점
async function _bofPriceNotice(st, priceEl) {
  await brandConfirm({
    title: '판매가 확인', single: true, card: true,
    body: '큐텐에서 상품 정보를 불러왔습니다. 판매가 칸의 금액이 캠페인 진행 기간 중 소비자가 실제로 구매하는 금액인지 확인하고, 다르면 고쳐 주십시오.' +
      (_bofFormType(st) === 'seeding' ? '' : '\n※ 메가와리 쿠폰 적용 불가')
  });
  if (st === _bof && priceEl.isConnected) { priceEl.focus(); try { priceEl.select(); } catch (e) { /* 날짜 칸 등 */ } }
}

// ── 업로드(로그인 계정 — 541 정책 orient_images_account_insert, 경로 s/{시트 번호}/{난수}.{확장자}, upsert:false)
function _bofExt(name) { const m = String(name || '').toLowerCase().match(/\.([a-z0-9]+)$/); return m ? m[1] : ''; }
function _bofRand() { return (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : 'f' + Date.now() + Math.random().toString(36).slice(2, 10); }
function _bofIsHeic(file) { const t = (file.type || '').toLowerCase(), n = (file.name || '').toLowerCase(); return /image\/(heic|heif)/.test(t) || /\.(heic|heif)$/.test(n); }
let _bofHeicLoading = null;
function _bofLoadHeic() {
  if (typeof window.heic2any === 'function') return Promise.resolve();
  if (_bofHeicLoading) return _bofHeicLoading;
  _bofHeicLoading = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js';   // orient.html 과 같은 판
    s.onload = resolve;
    s.onerror = () => { _bofHeicLoading = null; reject(new Error('heic_load_failed')); };
    document.head.appendChild(s);
  });
  return _bofHeicLoading;
}
// 이미지 → 긴 변 2048 JPEG(orient.html compressOrientImage 사본). 실패하면 throw → 원본으로
async function _bofCompress(file) {
  let work = file;
  if (_bofIsHeic(file)) {
    await _bofLoadHeic();
    const conv = await window.heic2any({ blob: file, toType: 'image/jpeg', quality: 0.85 });
    work = Array.isArray(conv) ? conv[0] : conv;
  }
  let bitmap;
  try { bitmap = await createImageBitmap(work, { imageOrientation: 'from-image' }); } catch (e) { bitmap = await createImageBitmap(work); }
  const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
  const w = Math.max(1, Math.round(bitmap.width * scale)), h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  canvas.getContext('2d').drawImage(bitmap, 0, 0, w, h);
  if (bitmap.close) bitmap.close();
  const blob = await new Promise(res => canvas.toBlob(res, 'image/jpeg', 0.85));
  if (!blob) throw new Error('compress_failed');
  return new File([blob], 'image.jpg', { type: 'image/jpeg' });
}
function _bofSetUploadStatus(row, kind, text) {
  const el = row.querySelector('.bof-img-status'); if (!el) return;
  el.className = 'bof-img-status' + (kind ? ' is-' + kind : '');
  el.textContent = text || '';
}
function _bofShowChip(row, icon, label, href) {
  row.querySelector('.bof-img-chip-icon').textContent = icon;
  const a = row.querySelector('.bof-img-name');
  a.textContent = label;
  a.setAttribute('href', href || '');
  row.querySelector('.bof-img-chip').hidden = false;
  row.querySelector('.bof-img-choose').hidden = true;
  row.querySelector('.bof-img-url').hidden = true;
  row.querySelector('.bof-img-hint').hidden = true;
}
function _bofShowChoose(row) {
  row.querySelector('.bof-img-chip').hidden = true;
  row.querySelector('.bof-img-url').hidden = true;
  row.querySelector('.bof-img-choose').hidden = false;
  row.querySelector('.bof-img-hint').hidden = false;
}
async function _bofOnFilePick(st, input) {
  const file = input.files && input.files[0];
  input.value = '';
  if (!file) return;
  const row = input.closest('[data-img]'); if (!row) return;
  if (st.conflicted) { brandToast(BOF_MSG.conflictToast); return; }
  const ext = _bofExt(file.name);
  const isImage = (file.type || '').startsWith('image/') || _bofIsHeic(file) || ['jpg', 'jpeg', 'png', 'webp'].includes(ext);
  if (!isImage && !BOF_UPLOAD_MIME[ext]) { brandToast('이미지·PDF·문서(워드·엑셀·PPT) 파일만 올릴 수 있습니다.', { error: true }); return; }
  _bofSetUploadStatus(row, 'busy', '업로드 중…');
  st.uploading++;
  _bofUpdateUploadBusy(st);
  try {
    let blob = file, upExt = ext, contentType = BOF_UPLOAD_MIME[ext] || file.type;
    if (isImage) {
      try { blob = await _bofCompress(file); upExt = 'jpg'; contentType = 'image/jpeg'; }
      catch (e) { blob = file; }
    }
    if (blob.size > BOF_UPLOAD_MAX_BYTES) throw new Error('too_large');
    if (!BOF_UPLOAD_MIME[upExt]) throw new Error('bad_type');
    const path = 's/' + st.sheetId + '/' + _bofRand() + '.' + upExt;
    // 🔴 upsert:false — true 면 조회 권한이 필요해 막힌다(472)
    const { error } = await brandDb.storage.from(BOF_UPLOAD_BUCKET).upload(path, blob, { contentType, upsert: false });
    if (error) throw error;
    const { data: pub } = brandDb.storage.from(BOF_UPLOAD_BUCKET).getPublicUrl(path);
    const url = (pub && pub.publicUrl) || '';
    if (!url) throw new Error('no_url');
    if (st !== _bof || !row.isConnected) return;
    row.querySelector('.img-value').value = url;
    row.dataset.imgType = 'upload';
    row.dataset.imgName = file.name;
    _bofSetUploadStatus(row, '', '');
    _bofShowChip(row, 'attachment', file.name, /^https:\/\//i.test(url) ? url : '');
    _bofOnInput(st);
  } catch (e) {
    // ⚠️ 피그마 bw04-92 ③ 은 「파일이 너무 커요」(~요체) — 브랜드 화면 문체 「~습니다」로 맞췄다(기획 확인 필요)
    const msg = (e && e.message === 'too_large') ? '파일이 너무 큽니다(최대 10MB).' : '업로드에 실패했습니다. 링크(URL)로 넣어 주십시오.';
    if (row.isConnected) _bofSetUploadStatus(row, 'error', msg);
    brandToast(msg, { error: true });
  } finally {
    st.uploading = Math.max(0, st.uploading - 1);
    _bofUpdateUploadBusy(st);
  }
}
// 올리는 동안 「작성 완료」를 누를 수 없다(bw04-92 ④)
function _bofUpdateUploadBusy(st) {
  const b = st.root && st.root.querySelector('#boDoneBtn');
  if (b) b.disabled = st.uploading > 0;
}

// ── 글자 수 1,000자(서식 뺀 본문 — 서버 _orient_text_length 와 같은 셈)
function _bofLongClass(node) { return (node && node.classList) ? (BOF_LONG_TEXT_CLASSES.find(c => node.classList.contains(c)) || '') : ''; }
function _bofTrimEditable(node, limit) {
  let excess = node.textContent.length - limit;
  if (excess <= 0) return false;
  const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
  const texts = [];
  while (walker.nextNode()) texts.push(walker.currentNode);
  for (let i = texts.length - 1; i >= 0 && excess > 0; i--) {
    const t = texts[i]; const cut = Math.min(excess, t.data.length);
    t.data = t.data.slice(0, t.data.length - cut); excess -= cut;
  }
  try { const sel = window.getSelection(); const range = document.createRange(); range.selectNodeContents(node); range.collapse(false); sel.removeAllRanges(); sel.addRange(range); } catch (e) { /* 커서 이동 실패는 무시 */ }
  return true;
}
function _bofEnforceLimit(node) {
  const cls = _bofLongClass(node);
  if (!cls) return;
  let trimmed = false;
  if (node.isContentEditable) trimmed = _bofTrimEditable(node, BOF_LIMIT_LONG_TEXT);
  else if (node.value.length > BOF_LIMIT_LONG_TEXT) { node.value = node.value.slice(0, BOF_LIMIT_LONG_TEXT); trimmed = true; }
  const cur = node.isContentEditable ? node.textContent.length : node.value.length;
  const card = node.closest('.bof-card');
  const counter = card && card.querySelector('.bof-count[data-count-for="' + cls + '"]');
  if (counter) { counter.querySelector('.bof-count-cur').textContent = String(cur); counter.classList.toggle('is-full', cur >= BOF_LIMIT_LONG_TEXT); }
  if (trimmed) brandToast(BOF_LIMIT_LONG_TEXT.toLocaleString('ko-KR') + '자까지 적을 수 있습니다.');
}
function _bofRefreshCounts(card) { card.querySelectorAll(BOF_LONG_TEXT_CLASSES.map(c => '.' + c).join(', ')).forEach(_bofEnforceLimit); }

// 시딩 예상 일정 — 저장하지 않는다(날짜는 문자열로만 — 시간대가 끼지 않게)
function _bofAddDays(ymd, days) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd || '')); if (!m) return '';
  const d = new Date(Date.UTC(+m[1], +m[2] - 1, +m[3]) + days * 86400000);
  return d.getUTCFullYear() + '-' + String(d.getUTCMonth() + 1).padStart(2, '0') + '-' + String(d.getUTCDate()).padStart(2, '0');
}
function _bofMd(ymd) { const m = /^\d{4}-(\d{2})-(\d{2})$/.exec(ymd || ''); return m ? (+m[1]) + '/' + (+m[2]) : ymd; }
function _bofUpdateSchedule(card) {
  const box = card && card.querySelector('[data-schedule-hint]'); if (!box) return;
  const start = (card.querySelector('.f-recruit-start') || {}).value || '';
  box.textContent = start
    ? '예상 일정 — 모집 마감 ' + _bofMd(_bofAddDays(start, 10)) + '~' + _bofMd(_bofAddDays(start, 14)) + ' · 배송 5~7일 · 최종 업로드 ' + _bofMd(_bofAddDays(start, 25)) + '~' + _bofMd(_bofAddDays(start, 35)) + ' (실제 일정은 담당자가 캠페인 등록 때 확정합니다)'
    : '시작일을 고르면 모집 · 선정 · 게시 예상 일정이 여기에 계산되어 보입니다.';   // 피그마 bw04-02
}
function _bofUpdateHashtagWarn(card) {
  const input = card.querySelector('.f-hashtags'); const warn = card.querySelector('.bof-hashtag-warn');
  if (!input || !warn) return;
  const n = input.value.split(/[\s,]+/).map(s => s.trim()).filter(Boolean).length;
  warn.hidden = n <= BOF_MAX_HASHTAGS;
  warn.textContent = n > BOF_MAX_HASHTAGS ? '해시태그는 ' + BOF_MAX_HASHTAGS + '개까지 저장됩니다. 지금 ' + n + '개 적으셨습니다.' : '';
}
function _bofUpdateTitle(card) {
  const t = card.querySelector('.bof-product-title'); const n = card.querySelector('.f-product-name');
  const name = n ? n.value.trim() : '';
  t.textContent = name || '제품명이 출력됩니다.';
  t.classList.toggle('is-empty', !name);
}

// ── 필수 칸 검사 — 「작성 완료」(preflight)·제출(submit). orient.html findInvalidField 새 구조 갈래와 같은 순서·문구
function _bofFindInvalid(st, mode) {
  const forSubmit = mode === 'submit';
  const el = st.root.querySelector('#boForm > .bof-card[data-ctype]');
  if (!el) return { message: '창을 닫았다가 다시 열어 주십시오.', target: null };
  const c = _bofCollectCard(st, el);
  if (!c.product.name) return { message: '제품명을 입력해 주십시오.', target: el.querySelector('.f-product-name') };
  if (!c.sale.url) return { message: 'Qoo10 상품 주소를 입력해 주십시오.', target: el.querySelector('.f-sale-url') };
  if (!c.sale.price_regular) return { message: '판매가를 입력해 주십시오.', target: el.querySelector('.f-price-regular') };
  if (!_bofReadSlots(c.product.slots)) return { message: '모집 인원을 골라 주십시오.', target: el.querySelector('.bof-slots') };
  if (forSubmit && c.form_type === 'reviewer') {
    const pg = c.purchase_guide || {};
    if (!pg.mode) return { message: '구매 가이드를 골라 주십시오.', target: el.querySelector('.bof-pg') };
    if (pg.mode === 'fixed' && !pg.options) return { message: '구매할 옵션을 적어 주십시오.', target: el.querySelector('.f-pg-options') };
  }
  if (forSubmit && c.form_type === 'seeding' && !(c.seeding && c.seeding.account_tags))
    return { message: '게시물에 태그할 계정을 입력해 주십시오.', target: el.querySelector('.f-account-tags') };
  const pendingUrl = Array.from(el.querySelectorAll('.bof-img-url:not([hidden]) .bof-img-url-input')).find(i => i.value.trim());
  if (pendingUrl) return { message: '공유 링크를 「확인」 단추로 확정해 주십시오.', target: pendingUrl };
  const ack = st.root.querySelector('#bofNoticeAck');
  if (forSubmit && ack && !ack.checked) return { message: '맨 아래 「꼭 확인해 주십시오」를 읽고 체크해 주십시오.', target: st.root.querySelector('#bofNoticeLabel') };
  return null;
}
function _bofClearFieldErrors(st) {
  st.root.querySelectorAll('.is-invalid').forEach(e => e.classList.remove('is-invalid'));
  st.root.querySelectorAll('.bof-field-msg').forEach(e => e.remove());
}
// 칸 아래 빨간 안내 한 줄 — 그 칸을 다시 만지면 사라진다
function _bofFieldMessage(target, msg) {
  if (!target || !msg) return;
  const field = target.closest('.bof-field, .bof-notice') || target.parentElement;
  if (!field) return;
  const old = field.querySelector(':scope > .bof-field-msg'); if (old) old.remove();
  const p = document.createElement('p');
  p.className = 'bof-hint bof-warn bof-field-msg';
  p.setAttribute('role', 'alert');
  p.textContent = msg;
  field.appendChild(p);
}
function _bofFocusInvalid(st, v) {
  _bofClearFieldErrors(st);
  const t = v.target; if (!t) return;
  _bofFieldMessage(t, v.fieldMessage || v.message);
  requestAnimationFrame(() => {
    t.scrollIntoView({ behavior: 'smooth', block: 'center' });
    t.classList.add('is-invalid');
    const f = (t.matches && t.matches('input,textarea,select,[contenteditable]')) ? t : t.querySelector('input,textarea,select,[contenteditable]');
    if (f) { try { f.focus({ preventScroll: true }); } catch (e) { /* 초점 못 줌 */ } }
    const off = () => {
      t.classList.remove('is-invalid');
      const field = t.closest('.bof-field, .bof-notice');
      const m = field && field.querySelector(':scope > .bof-field-msg'); if (m) m.remove();
    };
    t.addEventListener('input', off, { once: true });
    t.addEventListener('click', off, { once: true });
    t.addEventListener('change', off, { once: true });
  });
}
// 「작성 완료」 → 작성 내용 확인(bw04-03) — 정의는 아래 「조각 7」 묶음(_bofOpenConfirm)
function _bofReview(st) { _bofOpenConfirm(st); }

// ── 떠나기 전 확인(결정 10 · bw04-13) — 저장 대기·저장 중·충돌일 때만 묻는다
function _bofHasUnsaved(st) { return !!(st && (st.dirty || st.saveInFlight || st.conflicted)); }
function _bofLeaveCopy(kind) {
  const cur = getCurrentBrand();
  if (kind === 'brand') return { title: '브랜드를 바꾸시겠습니까?', ok: '바꾸기', what: '브랜드를 바꾸면' };   // 바꿀 브랜드 이름은 장치가 모른다(피그마 「아로마팜으로 …」 — 기획 확인 필요)
  if (kind === 'logout') return { title: '로그아웃하시겠습니까?', ok: '로그아웃', what: '로그아웃하면' };
  if (kind === 'nav') return { title: '다른 화면으로 가시겠습니까?', ok: '이동', what: '다른 화면으로 가면' };
  return { title: '작성 모달을 닫으시겠습니까?', ok: '닫기', what: '닫으면' };
}
async function _bofGuard(kind) {
  const st = _bof;
  if (!st) return true;
  if (_bofHasUnsaved(st)) {
    const c = _bofLeaveCopy(kind);
    const ok = await brandConfirm({
      title: c.title, sub: '작성 중인 오리엔시트에 저장되지 않은 내용이 있습니다.', card: true, wide: true,
      body: c.what + ' 작성 모달이 닫히고, 저장되지 않은 내용은 이 기기에만 남습니다.\n다음에 이 시트를 열면 「불러오시겠습니까?」로 다시 넣을 수 있습니다.',
      cancelLabel: '계속 작성', okLabel: c.ok
    });
    if (!ok || st !== _bof) return ok && st !== _bof;
    // 바꾸기 — 🔴 진행 중인 저장을 먼저 끝낸다(리뷰 지적 2026-10-19). 안 기다리면 사본이 옛 판 번호로 남고,
    //   진행 중 저장이 성공해 서버 판이 앞서면 다음에 열 때 사본이 「서버보다 옛것」으로 버려져 마지막 입력이 조용히 사라진다.
    clearTimeout(st.saveTimer);
    st.saveQueued = false;   // 끝난 뒤 DOM 으로 다시 저장하지 않게 — 마지막 저장은 아래에서 보낸다
    if (st.saveInFlight) await _bofWaitForSave(st);
    // 사본을 남기고 진행. 충돌이 아니면 마지막 저장도 한 번 보낸다(성공하면 사본이 지워진다)
    const data = _bofCollect(st);
    _bofWriteBackup(st, data, st.conflicted ? { conflict: true } : (st.saveInFlight ? { inflight: true } : null));
    if (!st.conflicted && st.dirty) { st.closed = true; _bofDoAutosave(st, data); }
  }
  _bofClose(st);
  return true;
}

// ── 열고 닫기
function _bofClose(st) {
  if (!st || (st.closed && st !== _bof)) return;   // 가드가 closed 를 먼저 세워도 아직 열린 모달이면 닫는다
  st.closed = true;
  clearTimeout(st.saveTimer);
  _bofDisposeQuoteFrame(st);
  if (st.printMsg) { window.removeEventListener('message', st.printMsg); st.printMsg = null; }
  if (st.unguard) st.unguard();
  if (st.root && st.root.isConnected) st.root.remove();
  document.removeEventListener('keydown', _bofOnKeydown, true);
  document.body.classList.remove('is-bof-open');
  if (_bof === st) _bof = null;
  if (st.returnFocus && st.returnFocus.isConnected) { try { st.returnFocus.focus(); } catch (e) { /* 무시 */ } }
  // 목록의 상태·최근 수정이 바뀌었을 수 있다
  if (st.savedOnce && typeof loadBrandOrientList === 'function' && location.hash === '#orient') loadBrandOrientList();
}

function _bofOnKeydown(e) {
  const st = _bof; if (!st) return;
  // 위에 뜬 확인 창이 먼저 — 🔴 보이는 것만 센다(약관 「보기」 창이 같은 클래스로 늘 숨은 채 있다 — 2026-10-19 로컬 확인)
  //   ⚠️ offsetParent 로 보면 안 된다 — .brand-modal 은 position:fixed 라 열려 있어도 늘 null(리뷰 지적)
  if (Array.from(document.querySelectorAll('.brand-modal')).some(m => !m.hidden && m.getClientRects().length > 0)) return;
  if (e.key === 'Escape') { e.preventDefault(); _bofGuard('close'); return; }
  if (e.key === 'Tab') {
    // 모달 안에서만 초점이 돌게
    const items = Array.from(st.root.querySelectorAll('button, input, textarea, select, a[href], [contenteditable="true"]'))
      .filter(el => !el.disabled && el.offsetParent !== null && el.tabIndex !== -1);
    if (!items.length) return;
    const i = items.indexOf(document.activeElement);
    if (i === -1) { e.preventDefault(); items[0].focus(); return; }
    if (e.shiftKey && i === 0) { e.preventDefault(); items[items.length - 1].focus(); }
    else if (!e.shiftKey && i === items.length - 1) { e.preventDefault(); items[0].focus(); }
  }
}

// 모달 안 입력 위임 — 모든 칸이 같은 길로 자동 저장에 들어간다
function _bofBindEvents(st) {
  const root = st.root;
  root.addEventListener('input', (e) => {
    const t = e.target;
    if (t.matches('.f-slots-direct')) {
      const card = t.closest('.bof-card');
      const n = _bofReadSlots(t.value);
      card.querySelector('.f-slots').value = n ? String(n) : '';
      _bofSetTierMode(card, n ? 'direct' : null);
      _bofApplyTierDirectInfo(st);
    }
    if (t.matches('#bofBrandPhone')) t.value = t.value.replace(/[^0-9]/g, '');
    if (t.matches('#bofBrandEmail')) { const v = t.value.trim(); _bofEl('.bof-email-warn').hidden = !v || brandIsEmailLike(v); }
    if (t.matches('.f-sale-url')) _bofToggleUrlWarn(t);
    if (t.matches('.f-product-name')) _bofUpdateTitle(t.closest('.bof-card'));
    if (t.matches('.f-hashtags')) _bofUpdateHashtagWarn(t.closest('.bof-card'));
    if (_bofLongClass(t)) _bofEnforceLimit(t);
    if (t.matches('.bof-img-url-input, .bof-img-file')) return;   // 확정 전 주소·파일 고르기는 저장 대상이 아니다
    _bofOnInput(st);
  });
  root.addEventListener('change', (e) => {
    const t = e.target;
    if (t.matches('.bof-img-file')) { _bofOnFilePick(st, t); return; }
    if (t.matches('.bof-pg input[type="radio"]')) {
      const card = t.closest('.bof-card');
      card.querySelector('.bof-pg-free').hidden = t.value !== 'free';
      card.querySelector('.bof-pg-fixed').hidden = t.value !== 'fixed';
      if (t.value === 'fixed') { const ed = card.querySelector('.f-pg-options'); if (ed) ed.focus(); }
    }
    if (t.matches('.f-recruit-start')) _bofUpdateSchedule(t.closest('.bof-card'));
    if (t.matches('input[type="checkbox"], input[type="radio"], input[type="date"]')) _bofOnInput(st);
  });
  // 주소 칸 — 들어올 때 값을 적어 두고, 나갈 때 값이 바뀌었을 때만 큐텐을 다시 부른다.
  //   (안 그러면 저장된 주소가 든 칸을 지나가기만 해도 불러오기·판매가 확인 창이 다시 뜬다 — 2026-10-19 로컬 확인)
  root.addEventListener('focusin', (e) => {
    if (e.target.matches('.f-sale-url')) e.target.dataset.focusVal = e.target.value;
  });
  root.addEventListener('focusout', (e) => {
    const t = e.target;
    if (t.matches('.f-sale-url')) {
      const v = (t.value || '').trim();
      if (v) { const n = _bofNormalizeUrl(v); if (n !== t.value) { t.value = n; _bofOnInput(st); } }
      _bofToggleUrlWarn(t);
      const changed = t.dataset.focusVal !== t.value;
      delete t.dataset.focusVal;
      if (changed) _bofLookup(st, t);
    }
    if (t.matches('#bofBrandEmail')) { const v = t.value.trim(); _bofEl('.bof-email-warn').hidden = !v || brandIsEmailLike(v); }
  });
  root.addEventListener('paste', (e) => {
    if (!e.target.closest || !e.target.closest('.bof-rich-body')) return;
    e.preventDefault();   // 서식 붙여넣기 금지 — 글자만
    const text = (e.clipboardData || window.clipboardData).getData('text/plain') || '';
    try { document.execCommand('insertText', false, text); } catch (err) { /* 무시 */ }
  });
  root.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && e.target.matches('.bof-img-url-input')) { e.preventDefault(); _bofConfirmUrl(st, e.target.closest('[data-img]')); }
  });
  // 숫자 칸 — 초점 중 마우스 휠로 값이 바뀌지 않게(orient.html 과 같은 처리)
  root.addEventListener('wheel', () => {
    const a = document.activeElement;
    if (a && root.contains(a) && a.tagName === 'INPUT' && a.type === 'number') a.blur();
  }, { passive: true });
  root.addEventListener('click', (e) => {
    if (e.target === root) { _bofGuard('close'); return; }   // 어두운 바깥
    const btn = e.target.closest('[data-bof-act]');
    if (!btn || btn.disabled) return;
    const act = btn.dataset.bofAct;
    const row = btn.closest('[data-img]');
    switch (act) {
      case 'close': _bofGuard('close'); break;
      case 'review': _bofReview(st); break;
      case 'to-form': _bofShowScreen(st, 'form'); break;
      case 'quote': _bofOpenQuote(st); break;
      case 'quote-retry': _bofOpenQuote(st); break;
      case 'to-confirm': _bofShowScreen(st, 'confirm'); break;
      case 'submit': _bofSubmit(st); break;
      case 'edit': _bofShowScreen(st, 'form'); break;
      case 'print': _bofPrintQuote(st); break;
      case 'campaigns': _bofGoCampaigns(st); break;
      case 'retry': st.dirty = true; _bofSetSaveState(st, 'saving'); _bofFlush(st); break;
      case 'reload': _bofReload(st); break;
      case 'restore': _bofRestoreBackup(st); break;
      case 'restore-discard': st.pendingBackup = null; _bofDropBackup(st); _bofEl('#boRestoreNote').hidden = true; break;
      case 'tier': _bofPickTier(st, btn); break;
      case 'lookup-swap': if (st.lookupResult) _bofApplyQoo10(st, btn.closest('.bof-card'), st.lookupResult, true, false); break;
      case 'rich': _bofRichCmd(st, btn); break;
      case 'img-add': {
        const list = btn.closest('.bof-field').querySelector('.bof-img-list');
        if (list.querySelectorAll('[data-img]').length >= BOF_MAX_IMAGES) { brandToast('이미지·파일은 최대 ' + BOF_MAX_IMAGES + '개까지 추가할 수 있습니다.'); break; }
        list.insertAdjacentHTML('beforeend', _bofImageRowHtml('', 'url'));
        _bofOnInput(st);
        break;
      }
      case 'img-del': if (row) { row.remove(); _bofOnInput(st); } break;
      case 'img-file':
        if (st.conflicted) { brandToast(BOF_MSG.conflictToast); break; }
        row.querySelector('.bof-img-file').click();
        break;
      case 'img-url':
        row.querySelector('.bof-img-choose').hidden = true;
        row.querySelector('.bof-img-hint').hidden = true;
        row.querySelector('.bof-img-url').hidden = false;
        row.querySelector('.bof-img-url-input').focus();
        break;
      case 'img-url-ok': _bofConfirmUrl(st, row); break;
      case 'img-url-cancel': row.querySelector('.bof-img-url-input').value = ''; _bofShowChoose(row); break;
      case 'img-clear':
        row.querySelector('.img-value').value = '';
        row.dataset.imgType = 'url';
        delete row.dataset.imgName;
        row.querySelector('.bof-img-url-input').value = '';
        _bofSetUploadStatus(row, '', '');
        _bofShowChoose(row);
        _bofOnInput(st);
        break;
    }
  });
}
function _bofConfirmUrl(st, row) {
  const url = _bofNormalizeUrl(row.querySelector('.bof-img-url-input').value);
  if (!url) { brandToast('공유 링크(URL)를 입력해 주십시오.', { error: true }); return; }
  row.querySelector('.img-value').value = url;
  row.dataset.imgType = 'url';
  delete row.dataset.imgName;
  _bofShowChip(row, 'link', url, /^https?:\/\//i.test(url) ? url : '');
  _bofOnInput(st);
}
function _bofPickTier(st, btn) {
  const card = btn.closest('.bof-card');
  const o = st.tiers.find(t => t.key === btn.dataset.tier); if (!o) return;
  const input = card.querySelector('.f-slots');
  // 이미 고른 구간을 다시 눌러도 값을 안 건드린다(직접 입력한 700 이 말없이 500 이 되지 않게)
  if (btn.classList.contains('is-on') && input.value) return;
  _bofSetTierMode(card, o.key);
  input.value = o.slots;
  const direct = card.querySelector('.f-slots-direct'); if (direct) direct.value = '';
  _bofApplyTierDirectInfo(st);
  _bofOnInput(st);
}
function _bofRichCmd(st, btn) {
  const ed = btn.closest('.bof-rich').querySelector('.bof-rich-body');
  ed.focus();
  const cmd = btn.dataset.cmd;
  if (cmd === 'link') {
    const sel = window.getSelection();
    if (!sel || !sel.toString().trim()) { brandToast('링크를 걸 글자를 먼저 골라 주십시오.'); return; }
    let url = window.prompt('링크 주소(URL)를 입력해 주십시오', 'https://');
    if (url == null) return;
    url = _bofNormalizeUrl(url);
    if (!url) { brandToast('올바른 링크 주소가 아닙니다.', { error: true }); return; }
    try { document.execCommand('createLink', false, url); } catch (e) { /* 무시 */ }
    ed.querySelectorAll('a[href]').forEach(a => { a.setAttribute('target', '_blank'); a.setAttribute('rel', 'noopener noreferrer nofollow'); });
  } else {
    try { document.execCommand(cmd, false, null); } catch (e) { /* 무시 */ }
  }
  _bofOnInput(st);
}

// 「새로고침」(충돌) — 모달만 다시 불러온다(결정 7). 이 기기 사본은 「충돌을 겪음」 표시가 있어 되살리기를 묻는다
async function _bofReload(st) {
  const btn = _bofEl('[data-bof-act="reload"]');
  if (btn) btn.disabled = true;
  const { data, error } = await brandRpc('get_my_orient_sheet', { p_sheet_id: st.sheetId });
  if (st !== _bof) return;
  if (btn) btn.disabled = false;
  if (error || !data) { brandToast(BOF_MSG.openFail, { error: true }); return; }
  if (data.success !== true) {
    if (data.reason === 'not_found') { _bofHandleNotFound(st); return; }
    _bofClose(st);
    openBrandOrientSheet(st.sheetId, { prefetched: data });   // 만료 등 — 상태별 갈래로
    return;
  }
  if (data.read_only || data.view_status === 'registered' || data.layout !== 'new') { _bofClose(st); openBrandOrientSheet(st.sheetId, { prefetched: data }); return; }
  _bofApplySheet(st, data);
  st.conflicted = false; st.dirty = false; st.saveQueued = false;
  _bofEl('#boConflictNote').hidden = true;
  _bofFillForm(st, st.formData);
  _bofShowScreen(st, 'form');
  _bofDetectBackup(st);
  _bofSetSaveState(st, 'idle');
  _bofPaintLastEditor(st, false);
}

function _bofApplySheet(st, res) {
  st.sheet = res;
  st.data = (res.data && typeof res.data === 'object') ? res.data : {};
  st.version = typeof res.version === 'number' ? res.version : 0;
  st.status = res.status || 'draft';
  const draft = (st.status === 'submitted' && res.draft_data && typeof res.draft_data === 'object') ? res.draft_data : null;
  st.formData = draft || st.data;   // 작성 화면만 작성본으로(524) — 완료·견적은 data
  st.hasDraft = !!draft;            // 고쳐 두고 다시 제출 안 함 — 완료 화면 안내(bw04-05b)
}

// ── 시트 열기 — 목록·「가려던 시트」가 부른다. opts.prefetched 가 있으면 다시 부르지 않는다(브랜드 확인용으로 이미 받음)
//   갈래 우선순위(작업표 조각 6): 거부 expired → 01b · 등록 → 01c · 옛 구조 → 읽기 전용 안내 · 제출됨 → 완료 화면 · 그 밖 → 작성 모달
//   ⚠️ 01b·01c·옛 구조 안내·완료 화면은 조각 7 — 그 전까지 제출된 시트는 작성 모달(이미 제출 안내 줄과 함께)로, 나머지는 「준비 중」 토스트
async function openBrandOrientSheet(sheetId, opts) {
  if (!sheetId || _bofOpening) return;
  if (_bof) { if (_bof.sheetId === sheetId) return; if (!(await _bofGuard('close'))) return; }
  _bofOpening = true;
  const returnFocus = document.activeElement;
  try {
    let res = opts && opts.prefetched;
    if (!res) {
      const r = await brandRpc('get_my_orient_sheet', { p_sheet_id: sheetId });
      if (r.error || !r.data) { brandToast(BOF_MSG.openFail, { error: true }); return; }
      res = r.data;
    }
    if (res.success !== true) {
      if (res.reason === 'not_found') {
        brandToast(BOF_MSG.cannotOpen, { error: true });
        const state = await refreshBrandLoginState();
        if (state && state.state === 'ok' && typeof loadBrandOrientList === 'function') loadBrandOrientList();
        return;
      }
      if (res.reason === 'expired') { _bofExpiredNotice(sheetId); return; }   // bw04-01b
      brandToast(BOF_MSG.openFail, { error: true });
      return;
    }
    if (!brandAuthed || location.hash !== '#orient') return;   // 기다리는 사이 다른 화면으로 갔다
    // 우선순위(작업표 조각 6): 등록 → 01c(layout 무관) · 옛 구조 → 읽기 전용 안내 · 제출됨 → 완료 화면 · 그 밖 → 작성 모달
    let first = 'form';
    if (res.view_status === 'registered') first = 'registered';
    else if (res.layout !== 'new' || res.read_only) { _bofOldLayoutNotice(res); return; }
    else if (res.status === 'submitted' && res.data && (res.data.quote || res.data.quote_error)) first = 'done';
    let uid = null;
    try { const { data } = await brandDb.auth.getSession(); uid = data && data.session ? data.session.user.id : null; } catch (e) { uid = null; }
    _bofMount(sheetId, res, uid, returnFocus, first);
  } finally {
    _bofOpening = false;
  }
}

function _bofMount(sheetId, res, uid, returnFocus, firstScreen) {
  const root = document.createElement('div');
  root.className = 'bof-modal';
  const st = {
    sheetId, uid, root, returnFocus,
    sheet: null, data: null, formData: null, version: 0, status: 'draft',
    conflicted: false, dirty: false, saveTimer: null, saveInFlight: null, saveQueued: false,
    uploading: 0, tierFees: null, tierSlotsReady: false, tiers: BOF_TIER_DEFAULTS.map(t => Object.assign({}, t)),
    lastCardEls: [], pendingBackup: null, touched: false, savedOnce: false, closed: false, seq: 0,
    lookupUrl: '', lookupResult: null, unguard: null,
    screen: 'form', previewQuote: null, previewData: null, quoteFrame: null, submitting: false
  };
  _bofApplySheet(st, res);
  _bof = st;
  root.innerHTML = _bofModalHtml(st);
  document.body.appendChild(root);
  document.body.classList.add('is-bof-open');
  _bofBindEvents(st);
  _bofFillForm(st, st.formData);
  _bofSetSaveState(st, 'idle');
  _bofPaintLastEditor(st, false);
  _bofDetectBackup(st);
  _bofPrefillBrandInfo(st);
  _bofLoadTierFees(st);
  st.unguard = registerBrandLeaveGuard(_bofGuard, { needsAsk: () => _bofHasUnsaved(_bof) });
  document.addEventListener('keydown', _bofOnKeydown, true);
  _bofShowScreen(st, firstScreen || 'form', { noScroll: true });
  // 「작성 시작」 — 신규 시트를 처음 연 것은 사람이 시작한 활동이다(기본값 8). 목록의 「작성 시작」 단추와 신규 줄 누르기가 같은 일이라 상태로 가른다
  if (res.view_status === 'new') { st.touched = true; brandTouchActivity(); }
  const first = (st.screen === 'form' && root.querySelector('.f-sale-url')) || root.querySelector('.bof-close');
  if (first) { try { first.focus({ preventScroll: true }); } catch (e) { /* 무시 */ } }
}


// ══════════════════════════════════════
// 조각 7 — 작성 내용 확인(bw04-03) · 견적서(04·04a) · 제출 · 완료(05·05a·05b) · 기한 지남(01b) · 캠페인 등록됨(01c)
//   🔴 견적서는 그리지 않고 끼워 넣는다 — 그리는 코드는 dev/sales/orient.html 한 벌(?embed=quote, bootEmbedQuote).
//      관리자(osOpenQuoteDoc)와 같은 순서: 창 → 준비 신호 'reverb-orient-quote-ready' → 출처를 고정해 {type, quote, data, note}
// ══════════════════════════════════════
// 견적 실패 이유 — orient.html QUOTE_ERROR_TEXT 의 브랜드 화면 문체(「~습니다」) 판(피그마 bw04-05a 설명 패널의 넷)
const BOF_QUOTE_ERROR_TEXT = {
  price_unreadable: '판매가를 숫자로 적으면 견적서를 받을 수 있습니다. (예: 5300)',
  slots_missing: '모집 인원을 숫자로 적으면 견적서를 받을 수 있습니다.',
  calc_error: '견적을 계산하지 못했습니다. 담당자가 확인한 뒤 견적을 안내해 드리겠습니다.',
  fee_missing: '요금 기준값이 아직 준비되지 않았습니다. 담당자가 확인한 뒤 견적을 안내해 드리겠습니다.'
};
const BOF_QUOTE_ERROR_FALLBACK = '견적서를 만들지 못했습니다. 내용을 확인해 주십시오.';
const BOF_QUOTE_READY_TIMEOUT_MS = 6000;
const BOF_STEPS = ['제출', '담당자 확인', '캠페인 발행', '모집'];   // ⚠️ 피그마 그대로 「캠페인 발행」(브랜드 말은 「캠페인 등록」 — 기획에게 넘길 것 10)

// 받침이 있으면 「이」, 없으면 「가」(리뷰 가이드가 / 촬영 가이드가)
function _bofJosaIga(word) {
  const c = String(word || '').slice(-1).charCodeAt(0);
  if (!(c >= 0xac00 && c <= 0xd7a3)) return '이(가)';
  return (c - 0xac00) % 28 ? '이' : '가';
}

// ── 화면 전환 — 작성 칸(#boForm)은 지우지 않고 감춘다(입력값·자동 저장을 그대로 둔다)
function _bofShowScreen(st, name, opts) {
  st.screen = name;
  const show = { form: name === 'form', confirm: name === 'confirm', quote: name === 'quote', done: name === 'done' || name === 'registered' };
  _bofEl('#boForm').hidden = !show.form;
  _bofEl('#boFormNotes').hidden = !show.form;
  _bofEl('#boConfirm').hidden = !show.confirm;
  _bofEl('#boQuote').hidden = !show.quote;
  _bofEl('#boDone').hidden = !show.done;
  if (!show.quote && !show.done) _bofDisposeQuoteFrame(st);
  if (show.form) { const rn = _bofEl('#boResubmitNote'); if (rn) rn.hidden = st.status !== 'submitted'; }
  if (name === 'done') _bofRenderDone(st);
  if (name === 'registered') _bofRenderRegistered(st);
  const pill = _bofStatusPill(st);
  const pillEl = _bofEl('#boPill'); pillEl.className = 'bof-pill ' + pill.cls; pillEl.textContent = pill.label;
  _bofEl('.bof-save').hidden = show.done;   // 완료·등록 화면에는 저장 상태가 없다(피그마 bw04-05·01c)
  _bofEl('#boBarBtns').innerHTML = _bofBarButtonsHtml(st);
  if (show.form) _bofUpdateUploadBusy(st);
  if (!(opts && opts.noScroll)) {
    const sc = _bofEl('#bofScroll');
    if (sc) { sc.scrollTop = 0; try { sc.focus({ preventScroll: true }); } catch (e) { /* 무시 */ } }   // 바뀐 단추와 함께 초점이 사라지지 않게
  }
}
function _bofBarButtonsHtml(st) {
  const sec = (act, label, dis) => '<button type="button" class="bof-btn-sec" data-bof-act="' + act + '"' + (dis ? ' disabled aria-disabled="true"' : '') + '>' + label + '</button>';
  const pri = (act, label, id) => '<button type="button" class="bof-done-btn"' + (id ? ' id="' + id + '"' : '') + ' data-bof-act="' + act + '">' + label + '</button>';
  switch (st.screen) {
    case 'confirm': return sec('to-form', '수정으로 돌아가기') + pri('quote', '견적 보기', 'boQuoteBtn');
    case 'quote': return sec('to-confirm', '작성 내용으로') + pri('submit', '제출하기', 'boSubmitBtn');
    case 'done': return sec('edit', '내용 수정하기');
    case 'registered': return sec('edit', '내용 수정하기', true);   // 흐린 단추(bw04-01c) — 등록되면 고칠 수 없다
    default: return pri('review', '작성 완료', 'boDoneBtn');
  }
}

// ── 작성 내용 확인(bw04-03) — 「작성 완료」 뒤 늘 거친다. 서식 칸은 여기서도 정화해 그린다
function _bofRow(k, v) {
  const val = (v == null || v === '') ? '<span class="bof-pv-v is-muted">—</span>' : '<span class="bof-pv-v">' + brandEsc(v) + '</span>';
  return '<div class="bof-pv-row"><span class="bof-pv-k">' + brandEsc(k) + '</span>' + val + '</div>';
}
function _bofRowHtml(k, html) {
  const safe = _bofRichSanitize(html || '');
  return '<div class="bof-pv-row"><span class="bof-pv-k">' + brandEsc(k) + '</span>' + (safe ? '<span class="bof-pv-v bof-pv-rich">' + safe + '</span>' : '<span class="bof-pv-v is-muted">—</span>') + '</div>';
}
function _bofYen(v) {
  const digits = String(v == null ? '' : v).replace(/[^0-9]/g, '');
  return digits ? '¥' + Number(digits).toLocaleString('ja-JP') : String(v || '');
}
function _bofTierText(st, product) {
  const p = product || {};
  if (!p.slots) return '';
  const t = st.tiers.find(x => x.key === p.slots_tier);
  return t ? p.slots + '건 (' + t.name + ')' : p.slots + '건';
}
function _bofConfirmHtml(st, data) {
  const c = data.cards[0] || {};
  const ft = c.form_type;
  const ch = _bofChannel(st);
  const sale = c.sale || {};
  const where = ft === 'seeding' ? (BRAND_ORIENT_CHANNEL[ch] || ch || '') : 'Qoo10';
  let rows = _bofRow('Qoo10 상품 주소', sale.url) + _bofRow('상품번호', sale.goods_code || '') + _bofRow('판매가', _bofYen(sale.price_regular));
  if (ft === 'reviewer') {
    rows += _bofRow('배송비', sale.shipping_fee ? _bofYen(sale.shipping_fee) : '없음');
    const pg = c.purchase_guide || {};
    if (pg.mode === 'free') rows += _bofRow('구매 가이드', '자율구매 — ' + BOF_PURCHASE_GUIDE_FREE);
    else if (pg.mode === 'fixed') rows += _bofRowHtml('구매 가이드', '지정구매 — ' + _bofRichInitial(pg.options));
    else rows += _bofRow('구매 가이드', '');
  }
  rows += _bofRow('모집 인원', _bofTierText(st, c.product));
  if (ft === 'reviewer') rows += _bofRow('추가 옵션', (sale.extra_markets || []).map(k => BRAND_ORIENT_MARKET[k] || k).join(' · '));
  rows += _bofRow('희망 모집 시작일', c.recruit && c.recruit.recruit_start ? c.recruit.recruit_start.replace(/-/g, '/') : '');
  if (ft === 'reviewer') rows += _bofRowHtml('리뷰 가이드', c.review_guide);
  if (ft === 'seeding') {
    const sd = c.seeding || {};
    rows += _bofRow('리뷰 가이드', sd.appeal) + _bofRow('촬영 가이드', sd.shooting_guide) +
      _bofRow('게시물에 꼭 넣을 해시태그', (sd.hashtags || []).join(' ')) + _bofRow('게시물에 태그할 계정', sd.account_tags);
  }
  // 예시 이미지는 개수만(bw04-03 화면 동작)
  rows += _bofRow('예시 이미지·자료', (c.images || []).length ? '이미지 ' + c.images.length + '개' : '');
  const b = data.brand || {};
  const title = '제품 1 · ' + ((c.product && c.product.name) || '제품명 없음') + '  —  ' + (BOF_FORM_LABEL[ft] || ft) + (where ? ' · ' + where : '');
  return '<div class="bof-band">아래 내용으로 제출됩니다. 틀린 부분이 있으면 「수정으로 돌아가기」를 눌러 고쳐 주십시오.</div>' +
    '<section class="bof-card bof-pv-card"><h3 class="bof-pv-title">' + brandEsc(title) + '</h3>' + rows + '</section>' +
    '<section class="bof-card bof-pv-card"><h3 class="bof-pv-title">브랜드 정보</h3>' +
      _bofRow('브랜드명', b.name) + _bofRow('담당자명', b.contact_name) + _bofRow('연락처', b.phone) + _bofRow('이메일', b.email) + '</section>';
}
function _bofOpenConfirm(st) {
  if (st.conflicted) { brandToast(BOF_MSG.conflictToast, { error: true }); return; }
  if (st.uploading > 0) { brandToast(BOF_MSG.uploadBusy); return; }
  _bofFlush(st);
  const bad = _bofFindInvalid(st, 'preflight');
  if (bad) { brandToast(bad.message, { error: true }); _bofFocusInvalid(st, bad); return; }
  _bofClearFieldErrors(st);
  _bofEl('#boConfirm').innerHTML = _bofConfirmHtml(st, _bofCollect(st));
  _bofShowScreen(st, 'confirm');
}

// ── 최소 인원 미만 — 「견적 보기」와 「제출」만 막는다(orient.html findSlotsBelowMin 과 같은 규칙. 「작성 완료」는 막지 않는다)
function _bofSlotsBelowMin(st) {
  const min = _bofMinSlots(st);
  if (min <= 1) return null;
  const card = st.root.querySelector('#boForm > .bof-card[data-ctype]');
  const n = card ? _bofReadSlots(card.querySelector('.f-slots').value) : null;
  if (n && n < min) return { min, card };
  return null;
}
function _bofSlotsMessage(min) {
  return min ? '모집 인원은 최소 ' + Number(min).toLocaleString('ko-KR') + '명부터 신청할 수 있습니다. 더 적은 인원을 원하시면 담당자와 협의해 주십시오.'
    : '신청 가능한 최소 모집 인원에 못 미칩니다. 담당자와 협의해 주십시오.';
}
// 작성 칸으로 돌아가 그 칸을 빨갛게 + 칸 아래 안내 + 토스트(bw04-01g·01f)
function _bofBackToField(st, target, toast, fieldMsg) {
  _bofShowScreen(st, 'form');
  brandToast(toast, { error: true });
  if (target) _bofFocusInvalid(st, { message: toast, fieldMessage: fieldMsg || toast, target });
}
function _bofSlotsTarget(card) {
  const direct = card && card.querySelector('.f-slots-direct');
  // 구간 단추를 고른 채면 단추 줄을, 직접 입력이면 그 칸을 표시한다
  return card && card.querySelector('.bof-tier-btn.is-on') ? card.querySelector('.bof-tier') : direct;
}

// ── 견적서 끼워 넣기
//   주소: 로컬은 같은 출처의 sales/ · 개발 sales-dev · 운영 sales. 🔴 출처 판정 사본 — 관리자 osQuoteEmbedUrl·osSalesBase 와 같은 규칙(바꾸면 함께)
function _bofQuoteUrl() {
  if (/^(localhost|127\.0\.0\.1)$/.test(location.hostname)) return location.origin + '/sales/orient.html?embed=quote';
  return (/^(www\.)?globalreverb\.com$/.test(location.hostname) ? 'https://sales.globalreverb.com' : 'https://sales-dev.globalreverb.com') + '/orient?embed=quote';
}
// 견적서가 실제로 읽는 값만 보낸다(관리자 osQuotePayload 와 같은 범위 — 전화번호·가이드 본문·기준값 표 전체는 안 보낸다)
function _bofQuotePayload(st, quote, data, note) {
  const d = data || {};
  const b = d.brand || {};
  const c = (Array.isArray(d.cards) && d.cards[0]) || {};
  const basis = quote.basis || {};
  return {
    type: 'reverb-orient-quote',
    quote: Object.assign({}, quote, { basis: { exchange_rate_krw_per_jpy: basis.exchange_rate_krw_per_jpy, vat_rate: basis.vat_rate } }),
    data: {
      brand: { name: b.name || '', contact_name: b.contact_name || '', email: b.email || '' },
      cards: [{ product: { name: (c.product && c.product.name) || '' }, sale: { url: (c.sale && c.sale.url) || '' } }],
      issued: { form_type: _bofFormType(st) || quote.form_type || '', channel: _bofChannel(st) || quote.channel || '' }
    },
    note: note || ''
  };
}
function _bofDisposeQuoteFrame(st) {
  const q = st && st.quoteFrame;
  if (!q) return;
  clearTimeout(q.timer);
  window.removeEventListener('message', q.onMsg);
  st.quoteFrame = null;
}
// host 안에 견적서 창을 그리고 내용을 넘긴다. 6초 안에 준비 신호가 없으면 「불러오지 못했습니다」
function _bofMountQuote(st, host, quote, data) {
  _bofDisposeQuoteFrame(st);
  const url = _bofQuoteUrl();
  const origin = new URL(url).origin;
  const payload = _bofQuotePayload(st, quote, data, '');
  host.innerHTML =
    '<div class="bof-quote-tools"><button type="button" class="bof-btn-line" data-bof-act="print"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">print</span>인쇄 · PDF</button></div>' +
    '<div class="bof-quote-box"><iframe class="bof-quote-frame" title="견적서" src="about:blank"></iframe>' +
      '<p class="bof-quote-fail" hidden>견적서를 불러오지 못했습니다. 잠시 후 다시 열어 주십시오.</p></div>';
  const frame = host.querySelector('iframe');
  const fail = host.querySelector('.bof-quote-fail');
  const q = st.quoteFrame = { payload, origin, timer: null, onMsg: null };
  q.onMsg = (ev) => {
    if (ev.origin !== origin || ev.source !== frame.contentWindow) return;
    if (!ev.data || ev.data.type !== 'reverb-orient-quote-ready') return;
    clearTimeout(q.timer);
    fail.hidden = true; frame.hidden = false;   // 늦게 온 준비 신호도 살린다
    frame.contentWindow.postMessage(payload, origin);
  };
  window.addEventListener('message', q.onMsg);
  q.timer = setTimeout(() => { frame.hidden = true; fail.hidden = false; }, BOF_QUOTE_READY_TIMEOUT_MS);
  frame.src = url;
}
// 인쇄는 새 탭에서(관리자 osPrintQuoteDoc 와 같은 방식 — 🔴 noopener 금지: 새 탭이 이 창에 준비 신호를 보낸다)
function _bofPrintQuote(st) {
  const q = st.quoteFrame; if (!q) return;
  const payload = q.payload, origin = q.origin;
  const w = window.open(_bofQuoteUrl(), '_blank');
  if (!w) { brandToast('인쇄 창을 열지 못했습니다. 브라우저 메뉴의 「인쇄」를 눌러 주십시오.', { error: true }); return; }
  if (st.printMsg) window.removeEventListener('message', st.printMsg);
  const onMsg = st.printMsg = (ev) => {
    if (ev.origin !== origin || ev.source !== w) return;
    if (!ev.data || ev.data.type !== 'reverb-orient-quote-ready') return;
    w.postMessage(payload, origin);
    window.removeEventListener('message', onMsg);
  };
  window.addEventListener('message', onMsg);
  setTimeout(() => window.removeEventListener('message', onMsg), 30000);
}

// ── 「견적 보기」(bw04-04) — 서버가 지금 화면 값으로 계산만 한다(저장 없음). 제출과 같은 계산식
async function _bofOpenQuote(st) {
  if (st.conflicted) { brandToast(BOF_MSG.conflictToast, { error: true }); return; }
  if (st.uploading > 0) { brandToast(BOF_MSG.uploadBusy); return; }
  const bad = _bofFindInvalid(st, 'preflight');
  if (bad) { _bofBackToField(st, bad.target, bad.message); return; }
  const few = _bofSlotsBelowMin(st);
  if (few) { _bofBackToField(st, _bofSlotsTarget(few.card), _bofSlotsMessage(few.min)); return; }
  const data = _bofCollect(st);
  const btn = _bofEl('#boQuoteBtn') || _bofEl('[data-bof-act="quote-retry"]');
  const label = btn ? btn.textContent : '';
  if (btn) { btn.disabled = true; btn.textContent = '견적 계산 중…'; }
  let res = null, error = null;
  try { ({ data: res, error } = await brandRpc('preview_my_orient_quote', { p_sheet_id: st.sheetId, p_data: data })); } catch (e) { error = e; }
  if (st !== _bof) return;
  if (btn && btn.isConnected) { btn.disabled = false; btn.textContent = label; }
  if (st.screen !== 'confirm' && st.screen !== 'quote') return;   // 계산하는 사이 「수정으로 돌아가기」 — 끌고 가지 않는다
  if (!error && res && res.success === false) {
    if (res.reason === 'not_found') { _bofHandleNotFound(st); return; }
    if (res.reason === 'expired' || res.reason === 'consumed') { _bofReopenAfterLock(st, res.reason); return; }
  }
  const host = _bofEl('#boQuote');
  const tail = '<div class="bof-band">입력한 내용을 바탕으로 한 예상 견적입니다. 수정이 필요한 경우 「작성 내용으로」로 돌아가십시오.</div>';
  if (error || !res || res.success !== true) {
    // bw04-04a — 연결·서버 오류(계산 전에 실패). 제출은 막지 않는다
    host.innerHTML = '<div class="bof-band is-warn">견적을 계산하지 못했습니다. 잠시 후 다시 시도해 주십시오. 제출은 할 수 있고, 견적은 담당자가 확인한 뒤 안내드립니다.</div>' +
      '<div class="bof-empty-card"><p>견적서를 표시할 수 없습니다</p><button type="button" class="bof-btn-sec" data-bof-act="quote-retry">다시 불러오기</button></div>';
    _bofShowScreen(st, 'quote');
    brandToast('견적을 계산하지 못했습니다. 잠시 후 다시 시도해 주십시오.', { error: true });
    return;
  }
  st.previewQuote = res.quote || null;
  st.previewData = data;
  if (!st.previewQuote) {
    // 계산은 됐지만 견적을 못 만듦(판매가 글자 등 — quote_error). 이유별 문구 + 그래도 제출할 수 있다
    const why = BOF_QUOTE_ERROR_TEXT[res.quote_error] || BOF_QUOTE_ERROR_FALLBACK;
    host.innerHTML = '<div class="bof-band is-warn">' + brandEsc(why) + ' 그대로 제출할 수도 있고, 「작성 내용으로」에서 고친 뒤 다시 볼 수도 있습니다.</div>' +
      '<div class="bof-empty-card"><p>견적서를 표시할 수 없습니다</p></div>';
    _bofShowScreen(st, 'quote');
    return;
  }
  host.innerHTML = '<div class="bof-quote-slot"></div>' + tail;
  _bofShowScreen(st, 'quote');
  _bofMountQuote(st, host.querySelector('.bof-quote-slot'), st.previewQuote, data);
}

// 저장·제출이 기한·등록으로 거부됐다 — 모달을 닫고 시트를 다시 열어 상태에 맞는 화면으로(01b·01c)
function _bofReopenAfterLock(st, reason) {
  const id = st.sheetId;
  brandToast('제출할 수 없는 상태입니다.', { error: true });
  // 잠긴 시트라 사본은 되살릴 곳이 없다 — 남은 입력이 있으면 사본만 남긴다(다시 열 때 기한 안이면 제안)
  try { if (st.dirty) _bofWriteBackup(st, _bofCollect(st)); } catch (e) { /* 무시 */ }
  st.dirty = false;
  _bofClose(st);
  if (reason === 'expired') { _bofExpiredNotice(id); return; }
  openBrandOrientSheet(id);
}

// ── 제출(bw04-04 「제출하기」)
async function _bofSubmit(st) {
  if (st.submitting) return;
  if (st.conflicted) { brandToast(BOF_MSG.conflictToast, { error: true }); return; }
  const bad = _bofFindInvalid(st, 'submit');
  if (bad) { _bofBackToField(st, bad.target, bad.message); return; }
  const few = _bofSlotsBelowMin(st);
  if (few) { _bofBackToField(st, _bofSlotsTarget(few.card), _bofSlotsMessage(few.min)); return; }
  const btn = _bofEl('#boSubmitBtn');
  st.submitting = true;
  if (btn) { btn.disabled = true; btn.textContent = '제출 중…'; }
  const release = () => { st.submitting = false; if (btn && btn.isConnected) { btn.disabled = false; btn.textContent = '제출하기'; } };
  clearTimeout(st.saveTimer);
  st.saveQueued = false;
  // 🔴 진행 중인 자동 저장이 끝난 뒤 제출한다 — 안 기다리면 옛 판 번호로 나가 충돌한다
  if (!(await _bofWaitForSave(st))) { release(); brandToast('저장이 늦어지고 있습니다. 잠시 뒤 다시 제출해 주십시오.', { error: true }); return; }
  if (st !== _bof) return;
  if (st.conflicted) { release(); brandToast(BOF_MSG.conflictToast, { error: true }); return; }
  const data = _bofCollect(st);
  const cardEls = st.lastCardEls.slice();
  let res = null, error = null;
  try { ({ data: res, error } = await brandRpc('submit_my_orient_sheet', { p_sheet_id: st.sheetId, p_data: data, p_version: st.version })); } catch (e) { error = e; }
  if (st !== _bof) return;
  release();
  if (!error && res && res.success === true) {
    st.version = res.version;
    if (Array.isArray(res.card_uids)) cardEls.forEach((el, i) => { if (res.card_uids[i]) el.setAttribute('data-uid', String(res.card_uids[i])); });
    st.status = 'submitted';
    st.hasDraft = false;   // 서버가 제출과 함께 작성본을 비웠다(524)
    st.dirty = false;
    st.savedOnce = true;
    _bofDropBackup(st);
    st.pendingBackup = null;
    const rn = _bofEl('#boRestoreNote'); if (rn) rn.hidden = true;
    // 서버 키(발급 정보·이력·확인 기록)는 그대로 두고 제출한 값으로 바꾼다 — 완료 화면이 같은 값을 본다(orient.html submitSheet 와 같은 규칙)
    const keep = { issued: st.data.issued, quote_history: st.data.quote_history };
    if (st.data.notice_ack) keep.notice_ack = st.data.notice_ack;
    else if (data.notice_ack_checked === true) keep.notice_ack = { version: 1 };
    st.data = Object.assign({}, data, keep);
    if (res.quote) { st.data.quote = res.quote; delete st.data.quote_error; }
    else { delete st.data.quote; st.data.quote_error = res.quote_error || 'price_unreadable'; }
    st.formData = st.data;
    st.previewQuote = null; st.previewData = null;   // 이제부터는 저장된 판이 원본
    if (st.sheet) { st.sheet.last_edited_at = new Date().toISOString(); st.sheet.last_edited_by_me = true; }
    if (!st.touched) st.touched = true;
    brandTouchActivity();   // 제출은 사람이 누른 활동(기본값 8)
    _bofShowScreen(st, 'done');
    _bofPaintLastEditor(st, false);   // 방금 내가 제출했다 — 「○○님이 … 수정했습니다」 줄을 걷는다(조각 8 확인에서 발견)
    brandToast('제출되었습니다. 발행 전까지 수정할 수 있습니다.');   // 피그마 bw04-90 1번(「발행」은 기획에게 넘길 것 10)
    return;
  }
  const r = res && res.reason;
  if (r === 'conflict') { _bofShowScreen(st, 'form'); _bofEnterConflict(st); return; }
  if (r === 'not_found') { _bofHandleNotFound(st); return; }
  if (r === 'expired' || r === 'consumed') { _bofReopenAfterLock(st, r); return; }
  if (r === 'notice_not_acknowledged') { _bofBackToField(st, st.root.querySelector('#bofNoticeLabel'), '맨 아래 「꼭 확인해 주십시오」를 읽고 체크해 주십시오.'); return; }
  if (r === 'slots_below_min') {
    const card = st.root.querySelector('#boForm > .bof-card[data-ctype]');
    _bofBackToField(st, _bofSlotsTarget(card), _bofSlotsMessage(res.min_slots)); return;
  }
  if (r === 'guide_too_long' || r === 'appeal_too_long' || r === 'text_too_long') {
    // 서버가 거부한 칸 — 피그마 bw04-01f(칸 빨간 테두리 · 칸 아래 안내 · 토스트)
    const fieldKey = r === 'guide_too_long' ? 'review_guide' : r === 'appeal_too_long' ? 'appeal' : res.field;
    const cls = Object.keys(BOF_LONG_TEXT_FIELDS).find(k => BOF_LONG_TEXT_FIELDS[k].field === fieldKey);
    const label = cls ? BOF_LONG_TEXT_FIELDS[cls].label : '내용';
    const el = cls ? st.root.querySelector('.' + cls) : null;
    const target = el ? (el.closest('.bof-rich') || el) : null;
    _bofBackToField(st, target, label + _bofJosaIga(label) + ' 1,000자를 넘었습니다. 줄여 주십시오.', '1,000자를 넘었습니다. 줄여 주십시오. (서식은 빼고 글자만 셉니다)');
    return;
  }
  if (r === 'cards_limit') { brandToast('이 시트에는 제품 하나만 제출할 수 있습니다. 창을 닫았다가 다시 열어 주십시오.', { error: true }); return; }
  if (r === 'data_too_large') { brandToast('내용이 너무 깁니다. 줄여 주십시오.', { error: true }); return; }
  if (r === 'data_required') { brandToast('내용을 입력해 주십시오.', { error: true }); return; }
  brandToast('제출에 실패했습니다. 잠시 후 다시 시도해 주십시오.', { error: true });
}

// ── 진행 단계 알약(bw04-05·01c) — 지금은 「제출」만 강조(피그마 그대로. 01c 도 같다 — 기획 확인 필요)
function _bofStepsHtml() {
  return '<ol class="bof-steps" aria-label="진행 단계">' + BOF_STEPS.map((t, i) =>
    (i ? '<li class="bof-step-sep" aria-hidden="true">›</li>' : '') +
    '<li class="bof-step' + (i === 0 ? ' is-now' : '') + '"' + (i === 0 ? ' aria-current="step"' : '') + '>' + brandEsc(t) + '</li>').join('') + '</ol>';
}
// 완료 화면(bw04-05·05a·05b) — 저장된 견적 스냅샷을 그린다(다시 계산 안 함)
function _bofRenderDone(st) {
  const host = _bofEl('#boDone');
  const q = st.data && st.data.quote;
  const err = st.data && st.data.quote_error;
  const draft = st.hasDraft
    ? '<div class="bof-box-warn"><p>제출하지 않은 수정 내용이 있습니다. 「내용 수정하기」로 이어서 고치고 다시 제출해 주십시오.</p><p class="is-sub">다시 제출하기 전까지 담당자에게는 아래 제출된 내용이 보입니다.</p></div>' : '';
  host.innerHTML = '<section class="bof-card bof-done-card"><h3 class="bof-done-title">제출되었습니다</h3>' +
      '<p class="bof-done-desc">제출된 내용은 담당자가 확인합니다. 발행 전까지는 「내용 수정하기」로 고쳐서 다시 제출할 수 있습니다.</p>' +
      draft + _bofStepsHtml() + '</section>' +
    (q ? '<div class="bof-quote-slot"></div>'
      : err ? '<div class="bof-box-warn"><p>' + brandEsc(BOF_QUOTE_ERROR_TEXT[err] || BOF_QUOTE_ERROR_FALLBACK) + '</p>' +
          // ⚠️ 둘째 줄은 이유와 관계없이 붙인다(피그마 bw04-05a 「아직 정하지 않은 것」 — 계산 오류·기준값 없음은 고쳐도 안 풀린다. 기획 확인 필요)
          '<p class="is-sub">「내용 수정하기」로 고쳐서 다시 제출하면 견적서가 만들어집니다.</p></div>' : '');
  if (q) _bofMountQuote(st, host.querySelector('.bof-quote-slot'), q, st.data);
}
// 캠페인 등록됨(bw04-01c) — 읽기 전용. 기한 지난 등록 시트는 서버가 견적을 빼서 준다(결정 3) — 그때는 견적서 없이
function _bofRenderRegistered(st) {
  const host = _bofEl('#boDone');
  const q = st.data && st.data.quote;
  const n = (st.sheet && Array.isArray(st.sheet.campaigns)) ? st.sheet.campaigns.length : 0;
  const cards = Array.isArray(st.data && st.data.cards) ? st.data.cards.length : 0;
  const partial = st.sheet && st.sheet.layout === 'old' && cards > 1 && n < cards ? ' (' + n + '/' + cards + ')' : '';   // 옛 구조 일부 등록(결정 4)
  host.innerHTML = '<div class="bof-band is-ok"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">check_box</span>' +
      '<span>이 오리엔시트로 캠페인이 등록되어 내용을 수정할 수 없습니다.' + brandEsc(partial) + '</span>' +
      // 캠페인 페이지(bw05-01)가 아직 「준비 중」이라 캠페인 메뉴로 보낸다(작업표 stale 8)
      '<button type="button" class="bof-band-link" data-bof-act="campaigns">캠페인 보기 ›</button></div>' +
    '<section class="bof-card bof-done-card"><h3 class="bof-done-title">캠페인이 등록되었습니다</h3>' +
      '<p class="bof-done-desc">담당자가 이 오리엔시트로 캠페인을 등록했습니다. 모집이 시작되면 「캠페인」 메뉴에서 현황을 볼 수 있습니다.</p>' +
      _bofStepsHtml() + '</section>' +
    (q ? '<div class="bof-quote-slot"></div>' : '');
  if (q) _bofMountQuote(st, host.querySelector('.bof-quote-slot'), q, st.data);
}
function _bofGoCampaigns(st) {
  _bofClose(st);
  location.hash = '#campaigns';
}

// ── 작은 안내 모달(bw04-01b · 옛 구조) — 아이콘 원 + 제목 + 설명 + 「닫기」
function _bofNoticeModal(o) {
  return new Promise(resolve => {
    const prev = document.activeElement;
    const wrap = document.createElement('div');
    wrap.className = 'brand-modal';
    wrap.setAttribute('role', 'dialog');
    wrap.setAttribute('aria-modal', 'true');
    wrap.setAttribute('aria-labelledby', 'bofNoticeModalTitle');
    wrap.innerHTML = '<div class="brand-modal-box bof-mini">' +
      '<span class="bof-mini-icon"><span class="material-icons-round notranslate" translate="no" aria-hidden="true">' + brandEsc(o.icon || 'info') + '</span></span>' +
      '<h2 id="bofNoticeModalTitle">' + brandEsc(o.title) + '</h2><p>' + brandEsc(o.body) + '</p>' +
      '<div class="bof-mini-actions"><button type="button" class="bof-btn-sec" data-act="close">닫기</button></div></div>';
    const close = () => { document.removeEventListener('keydown', onKey, true); wrap.remove(); if (prev && prev.isConnected) prev.focus(); resolve(); };
    const onKey = (e) => { if (e.key === 'Escape' || e.key === 'Tab') { e.preventDefault(); if (e.key === 'Escape') close(); } };
    wrap.addEventListener('click', (e) => { if (e.target === wrap || e.target.closest('[data-act="close"]')) close(); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(wrap);
    wrap.querySelector('[data-act="close"]').focus();
  });
}
// bw04-01b — 결정 9: 「담당자에게 문의」 단추는 빼고 안내 문장만. 번호·기한은 목록 값으로(만료 거부에는 시트 내용이 없다)
function _bofExpiredNotice(sheetId) {
  const row = (_brandOrientList && Array.isArray(_brandOrientList.sheets)) ? _brandOrientList.sheets.find(r => r.id === sheetId) : null;
  const no = row && row.orient_no ? '오리엔시트 ' + row.orient_no + '은(는)' : '이 오리엔시트는';
  const dl = row && row.deadline_at ? '작성 기한(' + brandFormatDate(row.deadline_at) + ')' : '작성 기한';
  return _bofNoticeModal({
    icon: 'event_busy', title: '작성 기한이 지났습니다',
    body: no + ' ' + dl + '이 지나 더 이상 작성할 수 없습니다. 기한을 늘리거나 새 시트가 필요하면 담당자에게 문의해 주십시오.'
  });
}
// 옛 구조(제품 여러 개) 시트 — 결정 4: 작성 모달을 열지 않고 읽기 전용 안내. 피그마 그림 없음(기획 확인 필요)
function _bofOldLayoutNotice(res) {
  return _bofNoticeModal({
    icon: 'description', title: '이전 양식 오리엔시트입니다',
    body: '오리엔시트 ' + (res.orient_no || '') + '은(는) 이전 양식으로 만들어져 브랜드 페이지에서 열 수 없습니다. 내용 확인이나 수정이 필요하면 담당자에게 문의해 주십시오.'
  });
}

// 이메일 모양 — brand-core.js isEmailFormat 이 있으면 그것을 쓴다(같은 판정 한 곳)
function brandIsEmailLike(v) { return typeof isEmailFormat === 'function' ? isEmailFormat(v) : /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v); }

// ── 바깥 사건
// 로그인이 풀림(결정 11) — 입력을 이 기기 사본에 남기고, 다시 로그인하면 이 시트로 바로(「가려던 시트」)
onBrandSessionLost(() => {
  const st = _bof; if (!st) return;
  try {
    _bofWriteBackup(st, _bofCollect(st), st.conflicted ? { conflict: true } : (st.saveInFlight ? { inflight: true } : null));
    sessionStorage.setItem(BRAND_ORIENT_TARGET_KEY, JSON.stringify({ kind: 'sheet', value: st.sheetId }));
  } catch (e) { /* 저장소 막힘 — 사본 없이 닫는다 */ }
});
// 틀이 감춰짐(로그아웃·세션 끝) — 묻지 않고 닫는다. 저장 안 된 입력이 있으면 사본만 남긴다
onBrandShellHidden(() => {
  const st = _bof; if (!st) return;
  if (_bofHasUnsaved(st)) { try { _bofWriteBackup(st, _bofCollect(st), st.conflicted ? { conflict: true } : (st.saveInFlight ? { inflight: true } : null)); } catch (e) { /* 무시 */ } }
  _bofClose(st);
});
// 브랜드가 바뀜 — 바꾸기 전 확인(switchBrand)이 이미 닫았다. 판정 갱신으로 바뀐 경우만 여기서 닫는다
onBrandChanged(() => {
  const st = _bof; if (!st) return;
  if (_bofHasUnsaved(st)) { try { _bofWriteBackup(st, _bofCollect(st), st.conflicted ? { conflict: true } : (st.saveInFlight ? { inflight: true } : null)); } catch (e) { /* 무시 */ } }
  _bofClose(st);
});
// 탭 닫기·새로고침 — 저장 대기·저장 중이면 브라우저 경고(충돌 상태는 사본이 이미 있다)
window.addEventListener('beforeunload', (e) => {
  const st = _bof;
  if (st && (st.dirty || st.saveInFlight) && !st.conflicted) {
    try { _bofWriteBackup(st, _bofCollect(st), st.saveInFlight ? { inflight: true } : null); } catch (err) { /* 무시 */ }
    e.preventDefault(); e.returnValue = '';
  }
});
