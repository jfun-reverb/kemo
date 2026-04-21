// ══════════════════════════════════════
// UI — 알림 팝업, 로딩, 모달, 슬라이더
// ══════════════════════════════════════

// Material Icons 번역 방지 (브라우저 번역 시 아이콘 깨짐 방지)
new MutationObserver(() => {
  document.querySelectorAll('.material-icons-round:not([translate])').forEach(el => {
    el.setAttribute('translate','no');
    el.classList.add('notranslate');
  });
}).observe(document.body || document.documentElement, {childList:true, subtree:true});

// HTML 이스케이프 (XSS 방지)
function esc(s) {
  if (!s) return '';
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

// 필수 필드 경고 표시/해제
function markRequired(id, msg) {
  const el = $(id);
  if (!el) return;
  el.style.borderColor = 'var(--red)';
  const warnId = id + '_reqWarn';
  if (!$(warnId)) {
    const warn = document.createElement('div');
    warn.id = warnId;
    warn.style.cssText = 'font-size:11px;color:var(--red);margin-top:4px';
    warn.textContent = msg;
    el.parentElement.appendChild(warn);
  }
}
function clearRequired(id) {
  const el = $(id);
  if (!el) return;
  el.style.borderColor = '';
  const warn = $(id + '_reqWarn');
  if (warn) warn.remove();
}

// 마크다운 링크 형식에서 URL 추출
function cleanUrl(s) {
  if (!s) return '';
  const md = s.match(/\[.*?\]\((.*?)\)/);
  if (md) return md[1].trim();
  return s.trim();
}

// 클라이언트(인플루언서) 전용: Supabase 영어 에러 → 현재 locale(ko/ja)에 맞게 변환
const _ERR_DICT = {
  ja: {
    unknown: 'エラーが発生しました',
    duplicate: 'すでに登録されています',
    permission: '権限がありません',
    fk: '関連データがあるため処理できません',
    notnull: '必須項目が不足しています',
    network: 'ネットワークエラーです。接続をご確認ください',
    rate: 'リクエストが多すぎます。しばらくしてから再試行してください',
    notfound: 'データが見つかりません',
    timeout: 'タイムアウトしました。再度お試しください',
    auth: 'セッションの有効期限が切れました。再ログインしてください',
    emailUnverified: 'メールアドレスの認証が完了していません',
    credentials: 'メールアドレスまたはパスワードが正しくありません',
    slotsFull: '募集定員に達したため、応募を受け付けておりません'
  },
  ko: {
    unknown: '오류가 발생했습니다',
    duplicate: '이미 등록된 데이터입니다',
    permission: '권한이 없습니다',
    fk: '연결된 데이터가 있어 처리할 수 없습니다',
    notnull: '필수 항목이 누락되었습니다',
    network: '네트워크 오류입니다. 인터넷 연결을 확인해주세요',
    rate: '요청이 너무 많습니다. 잠시 후 다시 시도해주세요',
    notfound: '데이터를 찾을 수 없습니다',
    timeout: '요청 시간이 초과되었습니다',
    auth: '인증이 만료되었습니다. 다시 로그인해주세요',
    emailUnverified: '이메일 인증이 완료되지 않았습니다',
    credentials: '이메일 또는 비밀번호가 올바르지 않습니다',
    slotsFull: '모집 정원에 도달하여 신청이 마감되었습니다'
  }
};

function friendlyErrorJa(e) {
  const lang = (typeof getLang === 'function' ? getLang() : 'ja') === 'ko' ? 'ko' : 'ja';
  const t = _ERR_DICT[lang];
  const s = String(e?.message || e || '');
  if (!s) return t.unknown;
  if (/duplicate key|unique constraint|already exists/.test(s)) return t.duplicate;
  if (/permission denied|Permission denied|violates row-level security/.test(s)) return t.permission;
  if (/violates foreign key/.test(s)) return t.fk;
  if (/violates not-null/.test(s)) return t.notnull;
  if (/Failed to fetch|NetworkError|network/.test(s)) return t.network;
  if (/rate limit|429/.test(s)) return t.rate;
  if (/not found|no rows/.test(s)) return t.notfound;
  if (/timeout|timed out/.test(s)) return t.timeout;
  if (/unauthorized|JWT/.test(s)) return t.auth;
  if (/email_not_confirmed/.test(s)) return t.emailUnverified;
  if (/Invalid login credentials/.test(s)) return t.credentials;
  if (/모집 정원|slots/.test(s)) return t.slotsFull;
  return t.unknown;
}

function toast(msg, type='') {
  const el = document.getElementById('toast');
  el.textContent = msg; el.className = 'show' + (type ? ' '+type : '');
  clearTimeout(el._t); el._t = setTimeout(()=>el.className='', 2800);
}
function loading(v) { document.getElementById('loadingOverlay').classList.toggle('show', v); }
function $(id) { return document.getElementById(id); }
function formatDate(d) { return d ? new Date(d).toLocaleDateString('ja-JP') : ''; }
function formatDateTime(d) { if(!d) return ''; const dt=new Date(d); return dt.toLocaleDateString('ja-JP')+' '+dt.toLocaleTimeString('ja-JP',{hour:'2-digit',minute:'2-digit'}); }
function dDayLabel(d) {
  if (!d) return '';
  const diff = Math.ceil((new Date(d).setHours(0,0,0,0) - new Date().setHours(0,0,0,0)) / (1000*60*60*24));
  const text = diff === 0 ? 'D-Day' : diff > 0 ? `D-${diff}` : `D+${Math.abs(diff)}`;
  const color = diff <= 0 ? '#B3261E' : diff <= 3 ? 'var(--gold)' : 'var(--muted)';
  return `<span style="font-size:9px;font-weight:600;color:${color};background:rgba(0,0,0,.06);padding:1px 5px;border-radius:4px;margin-left:4px">${text}</span>`;
}
// Supabase Storage 이미지 변환 URL (썸네일 최적화)
// /object/public/ → /render/image/public/?width=W&quality=Q
// 유료 플랜 전용 기능 — 실패 시 onerror에서 원본 URL로 폴백
function imgThumb(url, width, quality) {
  if (!url || typeof url !== 'string') return url;
  if (!url.includes('/storage/v1/object/public/')) return url;
  const q = quality || 70;
  const w = width || 400;
  // resize=contain: 비율 유지 (cover는 크롭됨)
  return url.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/') + `?width=${w}&quality=${q}&resize=contain`;
}

// 이미지 렌더 — 가로세로 비율 유지 (object-fit:contain, 레터박스)
// opts: {thumb, quality, lazy}. crop 인자는 하위호환으로 받지만 무시
function renderCroppedImg(url, _ignoredCrop, opts) {
  opts = opts || {};
  const thumb = opts.thumb ? imgThumb(url, opts.thumb, opts.quality||80) : url;
  const lazy = opts.lazy ? 'loading="lazy" decoding="async"' : '';
  return `<img src="${esc(thumb)}" data-orig="${esc(url)}" ${lazy} style="width:100%;height:100%;object-fit:contain;display:block;background:#f5f5f5" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}">`;
}

// lookup_values 캐시에서 라벨 우선 조회, 없으면 하드코딩 폴백
const CHANNEL_LABEL_FALLBACK = {instagram:'Instagram',x:'X(Twitter)',qoo10:'Qoo10',tiktok:'TikTok',youtube:'YouTube'};
function _currentLookupLang(lang) {
  if (lang) return lang;
  try { if (typeof getLang === 'function') return getLang(); } catch(e) {}
  return 'ja';
}
function getChannelLabel(ch, lang) {
  if (!ch) return '';
  const useLang = _currentLookupLang(lang) === 'ko' ? 'name_ko' : 'name_ja';
  const cache = (typeof _lookupCache !== 'undefined' && _lookupCache.channel) || null;
  return ch.split(',').map(s => s.trim()).filter(Boolean).map(code => {
    if (cache) {
      const row = cache.find(r => r.code === code);
      if (row) return row[useLang] || row.name_ja || code;
    }
    return CHANNEL_LABEL_FALLBACK[code] || code;
  }).join(' or ');
}

// lookup_values 공통: code 또는 name_ja를 현재 locale의 표시값으로
function getLookupLabel(kind, valueOrCode, lang) {
  if (!valueOrCode) return '';
  const useLang = _currentLookupLang(lang) === 'ko' ? 'name_ko' : 'name_ja';
  const cache = (typeof _lookupCache !== 'undefined' && _lookupCache[kind]) || null;
  if (!cache) return valueOrCode;
  const row = cache.find(r => r.code === valueOrCode || r.name_ja === valueOrCode || r.name_ko === valueOrCode);
  return row ? (row[useLang] || row.name_ja || valueOrCode) : valueOrCode;
}

// 콤마 구분 콘텐츠 타입 등 복수 값 처리
function getLookupLabelsJoined(kind, csv, sep, lang) {
  if (!csv) return '';
  return csv.split(',').map(s => s.trim()).filter(Boolean)
    .map(v => getLookupLabel(kind, v, lang)).join(sep || ', ');
}
// 모집 타입 라벨 (인플루언서 페이지: 일본어, 관리자: 한국어)
function getRecruitTypeLabelJa(t) {
  return t==='monitor'?'レビュアー':t==='gifting'?'ギフティング':t==='visit'?'訪問':'';
}
function getRecruitTypeBadgeKo(t) {
  if (t==='monitor') return '<span class="badge badge-blue">리뷰어</span>';
  if (t==='gifting') return '<span class="badge badge-gold">기프팅</span>';
  if (t==='visit')   return '<span class="badge badge-green">방문형</span>';
  return '';
}
function getRecruitTypeBadgeKoSm(t) {
  const cls = 'font-size:9px;padding:1px 6px';
  if (t==='monitor') return `<span class="badge badge-blue" style="${cls}">리뷰어</span>`;
  if (t==='gifting') return `<span class="badge badge-gold" style="${cls}">기프팅</span>`;
  if (t==='visit')   return `<span class="badge badge-green" style="${cls}">방문형</span>`;
  return '';
}

function getStatusBadge(s) {
  const labels = {
    pending: (typeof t === 'function' ? t('appHistory.pending') : '審査中'),
    approved: (typeof t === 'function' ? t('appHistory.approved') : '承認'),
    rejected: (typeof t === 'function' ? t('appHistory.rejected') : '非承認')
  };
  const m = {pending:`<span class="badge badge-gold">${labels.pending}</span>`,approved:`<span class="badge badge-green">${labels.approved}</span>`,rejected:`<span class="badge badge-gray">${labels.rejected}</span>`};
  return m[s] || s;
}
function getStatusBadgeKo(s) {
  const m = {pending:'<span class="badge badge-gold">심사중</span>',approved:'<span class="badge badge-green">승인</span>',rejected:'<span class="badge badge-gray">미승인</span>'};
  return m[s] || s;
}
function getChannelBadge(ch) {
  const m = {instagram:'<span class="badge badge-blue">Instagram</span>',x:'<span class="badge badge-gray">X</span>',qoo10:'<span class="badge badge-gold">Qoo10</span>'};
  return m[ch] || `<span class="badge badge-gray">${esc(ch)}</span>`;
}
function openModal(id) {
  $(id).classList.add('open');
}
function closeModal(id) {
  $(id).classList.remove('open');
}

// ── 이미지 슬라이더 ──
let _slideIdx = 0;
function slideMove(dir) {
  const slides = $('campSlides');
  if (!slides) return;
  const count = slides.children.length;
  _slideIdx = (_slideIdx + dir + count) % count;
  slideTo(_slideIdx);
}
function slideTo(idx) {
  const slides = $('campSlides');
  if (!slides) return;
  _slideIdx = idx;
  slides.style.transform = `translateX(-${idx*100}%)`;
  const num = $('slideCurrentNum');
  if (num) num.textContent = idx+1;
  document.querySelectorAll('[id^="dot"]').forEach((d,i)=>{
    d.style.background = i===idx?'#fff':'rgba(255,255,255,.5)';
    d.style.width = i===idx?'16px':'6px';
    d.style.borderRadius='3px';
  });
}

// ── 슬라이드 이미지 미리보기 (관리자용) ──
function previewSlideImgs() {
  const preview = $('slideImgPreview');
  if (!preview) return;
  preview.innerHTML = campImgData.map((img,i)=>`
    <div style="position:relative;width:68px;height:68px;border-radius:8px;overflow:hidden;border:2px solid ${i===0?'var(--pink)':'var(--line)'}">
      <img src="${img.data}" style="width:100%;height:100%;object-fit:contain;background:#f5f5f5">
      ${i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;padding:1px">MAIN</div>':''}
    </div>`).join('');
}

// ── 선택 항목 열기/닫기 ──
function toggleOptional() {
  const sec = $('optionalSection');
  const arrow = $('optionalArrow');
  if (!sec) return;
  const isOpen = sec.style.display !== 'none';
  sec.style.display = isOpen ? 'none' : 'block';
  if (arrow) arrow.textContent = isOpen ? '▶' : '▼';
}

// ── 비밀번호 보기/숨기기 ──
// 비밀번호 정책 검증
// 규칙: 8자 이상 + 영문 소문자 1개 이상 + 특수문자 1개 이상
// 유효하면 null, 위반 시 현지화된 에러 메시지 반환
function validatePasswordPolicy(pw) {
  const fallback = {
    short: 'パスワードは8文字以上で入力してください。',
    needLower: 'パスワードに英小文字を1つ以上含めてください。',
    needSpecial: 'パスワードに記号（!@#$%^&*など）を1つ以上含めてください。'
  };
  const T = (key, fb) => (typeof t === 'function') ? t(key, fb) : fb;
  if (!pw || pw.length < 8) return T('auth.pwTooShort', fallback.short);
  if (!/[a-z]/.test(pw)) return T('auth.pwNeedLower', fallback.needLower);
  if (!/[!@#$%^&*()_+\-=\[\]{};':"\\|,.<>\/?~`]/.test(pw)) return T('auth.pwNeedSpecial', fallback.needSpecial);
  return null;
}

function togglePw(inputId, btn) {
  const input = $(inputId);
  if (!input) return;
  const eyeOn = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>';
  const eyeOff = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19m-6.72-1.07a3 3 0 1 1-4.24-4.24"/><line x1="1" y1="1" x2="23" y2="23"/></svg>';
  if (input.type === 'password') { input.type = 'text'; btn.innerHTML = eyeOff; }
  else { input.type = 'password'; btn.innerHTML = eyeOn; }
}

// ── 우편번호로 주소 자동입력 ──
async function lookupZipProfile() {
  const zip = $('profileZip')?.value.replace(/[^0-9]/g,'');
  if (!zip || zip.length < 7) { toast('郵便番号を7桁で入力してください', 'error'); return; }
  try {
    const res = await fetch(`https://zipcloud.ibsnet.co.jp/api/search?zipcode=${zip}`);
    const data = await res.json();
    if (data.results && data.results.length > 0) {
      const r = data.results[0];
      const pref = $('profilePrefecture');
      if (pref) { const opts = Array.from(pref.options); const match = opts.find(o=>o.text===r.address1); if(match) pref.value=match.value||match.text; }
      const city = $('profileCity');
      if (city) city.value = (r.address2||'') + (r.address3||'');
      toast('住所を自動入力しました', 'success');
    } else { toast('該当する住所が見つかりませんでした', 'error'); }
  } catch(e) { toast('住所検索に失敗しました', 'error'); }
}

async function lookupZip() {
  const zip = $('signupZip')?.value.replace(/[^0-9]/g,'');
  if (!zip || zip.length < 7) { toast('郵便番号を7桁で入力してください', 'error'); return; }
  try {
    const res = await fetch(`https://zipcloud.ibsnet.co.jp/api/search?zipcode=${zip}`);
    const data = await res.json();
    if (data.results && data.results.length > 0) {
      const r = data.results[0];
      const pref = $('signupPrefecture');
      if (pref) { const opts = Array.from(pref.options); const match = opts.find(o => o.value === r.address1 || o.text === r.address1); if (match) pref.value = match.value || match.text; }
      const city = $('signupCity');
      if (city) city.value = (r.address2||'') + (r.address3||'');
      toast('住所を自動入力しました', 'success');
    } else { toast('該当する住所が見つかりませんでした', 'error'); }
  } catch(e) { toast('住所検索に失敗しました。手動で入力してください', 'error'); }
}

// ── 콘텐츠 타입 / 모집 타입 선택 토글 ──
function toggleCT(cb) {
  const label = cb.closest('label');
  if (cb.checked) { label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)'; }
  else { label.style.borderColor='var(--line)';label.style.background='';label.style.color=''; }
}
function toggleRT(rb) {
  document.querySelectorAll('[id^="rt-"]').forEach(label => {
    label.style.borderColor='var(--line)';label.style.background='';label.style.color='';label.style.fontWeight='600';
    const icon = label.querySelector('.material-icons-round');
    if (icon) { icon.textContent='radio_button_unchecked'; icon.style.color='var(--muted)'; }
  });
  const label = rb.closest('label');
  label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';label.style.fontWeight='700';
  const icon = label.querySelector('.material-icons-round');
  if (icon) { icon.textContent='radio_button_checked'; icon.style.color='var(--pink)'; }
}
function toggleEditRT(rb) {
  document.querySelectorAll('[id^="edit-rt-"]').forEach(l=>{
    l.style.borderColor='var(--line)';l.style.background='';l.style.color='';l.style.fontWeight='600';
    const icon = l.querySelector('.material-icons-round');
    if (icon) { icon.textContent='radio_button_unchecked'; icon.style.color='var(--muted)'; }
  });
  const label=rb.closest('label');
  label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';label.style.fontWeight='700';
  const icon = label.querySelector('.material-icons-round');
  if (icon) { icon.textContent='radio_button_checked'; icon.style.color='var(--pink)'; }
}
function toggleEditCT(cb) {
  const label=cb.closest('label');
  if(cb.checked){label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';}
  else{label.style.borderColor='var(--line)';label.style.background='';label.style.color='';}
}
function toggleCH(cb) {
  const label=cb.closest('label');
  if(cb.checked){label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';}
  else{label.style.borderColor='var(--line)';label.style.background='';label.style.color='';}
}
function toggleEditCH(cb) {
  const label=cb.closest('label');
  if(cb.checked){label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';}
  else{label.style.borderColor='var(--line)';label.style.background='';label.style.color='';}
}

// ══════════════════════════════════════
// 이미지 업로드 (드래그앤드롭 + 순서변경 + 크롭 + 다운로드)
// ══════════════════════════════════════
var campImgData = [];
var _dragSrcIdx = null;
var _cropTarget = null;
var _cropperInstance = null;

// 이미지 리스트 레지스트리 (window 참조 문제 해결)
var _imgLists = {};
function registerImgList(name, arr) { _imgLists[name] = arr; }
function getImgList(name) { return _imgLists[name]; }

// 드래그앤드롭 업로드 — 이벤트 위임 방식
document.addEventListener('dragover', function(e) {
  var zone = e.target.closest('[data-img-dropzone]');
  if (!zone) return;
  e.preventDefault();
  zone.style.borderColor='var(--pink)'; zone.style.background='var(--light-pink)';
});
document.addEventListener('dragleave', function(e) {
  var zone = e.target.closest('[data-img-dropzone]');
  if (!zone) return;
  zone.style.borderColor='var(--line)'; zone.style.background='var(--bg)';
});
document.addEventListener('drop', function(e) {
  var zone = e.target.closest('[data-img-dropzone]');
  if (!zone) return;
  e.preventDefault();
  zone.style.borderColor='var(--line)'; zone.style.background='var(--bg)';
  var listName = zone.dataset.imgDropzone;
  var list = getImgList(listName);
  if (!list) return;
  var files = Array.from(e.dataTransfer.files).filter(function(f){return f.type.startsWith('image/');});
  if (files.length) {
    var wrapId = listName === 'campImgData' ? 'campImgPreviewWrap' : 'editCampImgPreviewWrap';
    var counterId = listName === 'campImgData' ? 'campImgCounter' : 'editCampImgCounter';
    // editCampImgChanged 플래그 세팅 (편집 폼 저장 로직이 이 플래그로 업로드 판단)
    if (listName === 'editCampImgData' && typeof editCampImgChanged !== 'undefined') {
      editCampImgChanged = true;
    }
    addImagesToList(files, list, wrapId, counterId, listName);
  }
});

function handleCampImgSelect(input) {
  addImagesToList(Array.from(input.files), campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');
  input.value = '';
}

function addImagesToList(files, imgList, wrapId, counterId, listName) {
  var remaining = 8 - imgList.length;
  if (remaining <= 0) { toast('最大8枚まで追加できます','error'); return; }
  var toAdd = files.slice(0, remaining);
  var loaded = 0;
  toAdd.forEach(function(file) {
    if (!file.type.startsWith('image/')) return;
    if (file.size > 5*1024*1024) { toast(file.name + ' 5MB 초과','error'); return; }
    var reader = new FileReader();
    reader.onload = function(e) {
      imgList.push({data:e.target.result, name:file.name});
      loaded++;
      if (loaded === toAdd.length) renderImgPreview(imgList, wrapId, counterId, listName);
    };
    reader.readAsDataURL(file);
  });
}

function removeCampImg(idx) {
  campImgData.splice(idx,1);
  renderImgPreview(campImgData, 'campImgPreviewWrap', 'campImgCounter', 'campImgData');
}

function renderImgPreview(imgList, wrapId, counterId, listName) {
  var wrap = $(wrapId);
  var counter = $(counterId);
  if (!wrap) return;
  if (counter) counter.textContent = imgList.length + '/8';
  // 미리보기 패널 업데이트 트리거 (이미지 추가/삭제/크롭 반영)
  try { window.dispatchEvent(new CustomEvent('reverb:campFormChange')); } catch(e) {}
  var removeFn = listName === 'campImgData' ? 'removeCampImg' : 'removeEditCampImg';

  wrap.innerHTML = imgList.map(function(img,i) {
    return '<div data-idx="'+i+'" data-list="'+listName+'" data-wrap="'+wrapId+'" data-counter="'+counterId+'"' +
      ' draggable="true"' +
      ' ondragstart="imgDragStart(event,'+i+')"' +
      ' ondragover="event.preventDefault();this.style.outline=\'2px solid var(--pink)\'"' +
      ' ondragleave="this.style.outline=\'none\'"' +
      ' ondrop="imgDrop(event,'+i+',\''+listName+'\',\''+wrapId+'\',\''+counterId+'\')"' +
      ' style="position:relative;width:88px;height:88px;flex-shrink:0;cursor:grab">' +
      '<img src="'+img.data+'" draggable="false" style="width:88px;height:88px;object-fit:contain;border-radius:10px;border:2px solid '+(i===0?'var(--pink)':'var(--line)')+';background:#f5f5f5;pointer-events:none">' +
      (i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;border-radius:0 0 8px 8px;padding:2px">MAIN</div>':'') +
      '<button data-action="remove" data-i="'+i+'" data-remove-fn="'+removeFn+'" style="position:absolute;top:-4px;right:-4px;width:22px;height:22px;background:#333;color:#fff;border-radius:50%;font-size:12px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer;z-index:2" title="삭제"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">close</span></button>' +
      '<div style="position:absolute;bottom:'+(i===0?'20px':'2px')+';right:2px;display:flex;gap:3px;z-index:2">' +
        '<button data-action="download" data-i="'+i+'" data-list="'+listName+'" style="width:26px;height:26px;background:rgba(0,0,0,.7);color:#fff;border-radius:6px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="다운로드"><span class="material-icons-round" style="font-size:16px">download</span></button>' +
      '</div>' +
    '</div>';
  }).join('');
}

// 이미지 버튼 이벤트 위임 (크롭, 다운로드, 삭제)
document.addEventListener('click', function(e) {
  var btn = e.target.closest('button[data-action]');
  if (!btn) return;
  e.preventDefault();
  e.stopPropagation();
  var action = btn.getAttribute('data-action');
  var idx = parseInt(btn.getAttribute('data-i'));
  var listName = btn.getAttribute('data-list');

  if (action === 'crop') {
    openCropModal(idx, listName, btn.getAttribute('data-wrap'), btn.getAttribute('data-counter'));
  } else if (action === 'restore') {
    restoreOriginal(idx, listName, btn.getAttribute('data-wrap'), btn.getAttribute('data-counter'));
  } else if (action === 'download') {
    downloadImg(idx, listName);
  } else if (action === 'remove') {
    var fn = btn.getAttribute('data-remove-fn');
    if (fn === 'removeCampImg') removeCampImg(idx);
    else if (fn === 'removeEditCampImg') removeEditCampImg(idx);
  }
}, true);

// 드래그앤드롭 순서 변경
function imgDragStart(e, idx) {
  _dragSrcIdx = idx;
  e.dataTransfer.effectAllowed = 'move';
}

function imgDrop(e, targetIdx, listName, wrapId, counterId) {
  e.preventDefault();
  e.currentTarget.style.outline = 'none';
  if (_dragSrcIdx === null || _dragSrcIdx === targetIdx) return;
  var list = getImgList(listName);
  if (!list) return;
  var item = list.splice(_dragSrcIdx, 1)[0];
  list.splice(targetIdx, 0, item);
  _dragSrcIdx = null;
  // 편집 폼 저장 플래그 세팅 (순서만 바뀌어도 DB 재업로드 필요)
  if (listName === 'editCampImgData' && typeof editCampImgChanged !== 'undefined') {
    editCampImgChanged = true;
  }
  renderImgPreview(list, wrapId, counterId, listName);
}

// 이미지 다운로드 (원본이 있으면 원본 다운로드)
function downloadImg(idx, listName) {
  var list = getImgList(listName);
  if (!list || !list[idx]) return;
  var img = list[idx];
  var a = document.createElement('a');
  a.href = img.original || img.data;
  a.download = img.name || 'image-'+(idx+1)+'.jpg';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

// 원본 복원
function restoreOriginal(idx, listName, wrapId, counterId) {
  var list = getImgList(listName);
  if (!list || !list[idx]) return;
  // 비파괴 크롭 좌표 제거
  if (list[idx].crop) delete list[idx].crop;
  // 레거시 파괴적 크롭(original 백업) 복원
  if (list[idx].original) {
    list[idx].data = list[idx].original;
    delete list[idx].original;
  }
  renderImgPreview(list, wrapId, counterId, listName);
  toast('크롭 영역 해제','success');
}

// 1:1 크롭 모달
function openCropModal(idx, listName, wrapId, counterId) {
  var list = getImgList(listName);
  if (!list || !list[idx]) return;
  _cropTarget = {idx:idx, listName:listName, wrapId:wrapId, counterId:counterId};
  // 원본이 있으면 원본에서 다시 크롭, 없으면 현재 이미지 사용
  var imgData = list[idx].original || list[idx].data;
  var cropImg = $('cropImage');

  // 외부 URL이면 먼저 canvas로 변환
  function initCropper(src) {
    cropImg.src = src;
    var modal = $('cropModal');
    // 관리자 페이지(z-index:200, position:fixed) 위에 표시하기 위해 body 끝으로 이동
    document.body.appendChild(modal);
    modal.style.display = 'flex';
    setTimeout(function() {
      if (_cropperInstance) _cropperInstance.destroy();
      _cropperInstance = new Cropper(cropImg, {
        aspectRatio: 1,
        viewMode: 1,
        dragMode: 'move',
        autoCropArea: 1,
        responsive: true,
        background: false,
      });
    }, 200);
  }

  if (imgData.startsWith('data:')) {
    initCropper(imgData);
  } else {
    // 외부 URL → base64 변환 후 크롭
    var tempImg = new Image();
    tempImg.crossOrigin = 'anonymous';
    tempImg.onload = function() {
      var canvas = document.createElement('canvas');
      canvas.width = tempImg.naturalWidth;
      canvas.height = tempImg.naturalHeight;
      canvas.getContext('2d').drawImage(tempImg, 0, 0);
      try {
        var b64 = canvas.toDataURL('image/jpeg', 0.95);
        list[idx].data = b64;
        initCropper(b64);
      } catch(e) {
        toast('이미지를 로드할 수 없습니다. 다시 업로드해주세요.','error');
      }
    };
    tempImg.onerror = function() {
      toast('이미지를 로드할 수 없습니다. 다시 업로드해주세요.','error');
    };
    tempImg.src = imgData;
  }
}

function closeCropModal() {
  $('cropModal').style.display = 'none';
  if (_cropperInstance) { _cropperInstance.destroy(); _cropperInstance = null; }
  _cropTarget = null;
}

function applyCrop() {
  if (!_cropperInstance || !_cropTarget) return;
  // 비파괴 크롭: 좌표만 0~1로 정규화해서 저장 (원본 이미지 유지)
  var cropData = _cropperInstance.getData(true);  // {x,y,width,height,rotate,scaleX,scaleY}
  var imgData = _cropperInstance.getImageData();  // {naturalWidth,naturalHeight,...}
  var natW = imgData.naturalWidth;
  var natH = imgData.naturalHeight;
  var rect = natW && natH ? {
    x: Math.max(0, cropData.x / natW),
    y: Math.max(0, cropData.y / natH),
    w: Math.min(1, cropData.width / natW),
    h: Math.min(1, cropData.height / natH)
  } : null;
  var list = getImgList(_cropTarget.listName);
  if (list && rect) {
    var item = list[_cropTarget.idx];
    item.crop = rect;  // 좌표만 저장, item.data는 그대로
    renderImgPreview(list, _cropTarget.wrapId, _cropTarget.counterId, _cropTarget.listName);
  }
  closeCropModal();
  toast('크롭 영역 저장 (원본 유지)','success');
}

// ── 로그인 안내 팝업 ──
function closeLoginPrompt(e) {
  if (e && e.target !== $('loginPromptOverlay')) return;
  const o = $('loginPromptOverlay');
  if (o) o.style.display='none';
}

// ── 회사정보 / 이용약관 / 개인정보 모달 ──
function openLegalModal(kind) {
  const titles = {about:'会社紹介', terms:'利用規約', privacy:'個人情報処理方針'};
  const $t = document.getElementById('legalTitle');
  const $b = document.getElementById('legalBody');
  const $m = document.getElementById('legalModal');
  if (!$t || !$b || !$m) return;
  $t.textContent = titles[kind] || '';
  $b.innerHTML = buildLegalContent(kind);
  $m.classList.add('on');
  document.body.style.overflow = 'hidden';
}
function closeLegalModal() {
  const $m = document.getElementById('legalModal');
  if ($m) $m.classList.remove('on');
  document.body.style.overflow = '';
}
function buildLegalContent(kind) {
  if (kind === 'about') {
    return `
      <h3>会社情報</h3>
      <dl>
        <dt>会社名</dt><dd>株式会社ジェイファン（JFUN Corp.）</dd>
        <dt>所在地</dt><dd>ソウル市 衿川区 加山デジタル1路 128 STX V-Tower 1201号</dd>
        <dt>代表者</dt><dd>ジュ・ヒョンホ</dd>
        <dt>お問い合わせ</dt><dd>公式LINE <a href="https://line.me/R/ti/p/@reverb.jp" target="_blank" rel="noopener">@reverb.jp</a></dd>
      </dl>
      <p>REVERBは、日本で活動するインフルエンサーの皆さまと、韓国の人気Kブランドをつなぐ体験型プラットフォームです。</p>
    `;
  }
  if (kind === 'terms' || kind === 'privacy') {
    return `
      <p>${kind==='terms'?'利用規約':'個人情報処理方針'}の日本語版は現在準備中です。</p>
      <p>ご質問は公式LINE（<a href="https://line.me/R/ti/p/@reverb.jp" target="_blank" rel="noopener">@reverb.jp</a>）までお問い合わせください。</p>
      <p style="font-size:11px;color:var(--muted);margin-top:18px">施行予定日: 2026年5月1日</p>
    `;
  }
  return '';
}

// 회원가입 동의 체크박스 — 전체 동의 토글
function toggleAgreeAll(el) {
  const checked = el.checked;
  document.querySelectorAll('.signup-agree input[type="checkbox"]').forEach(cb => {
    if (cb.id !== 'agreeAll') cb.checked = checked;
  });
}
function syncAgreeAll() {
  const all = document.querySelectorAll('.signup-agree input[type="checkbox"]:not(#agreeAll)');
  const checkedCount = Array.from(all).filter(cb => cb.checked).length;
  const allEl = document.getElementById('agreeAll');
  if (allEl) allEl.checked = checkedCount === all.length;
}

// ══════════════════════════════════════
// Lazy List — 관리자 목록 페인 점진 렌더링
// ══════════════════════════════════════
// 전체 rows 배열을 받아 초기 pageSize만 DOM에 렌더하고,
// 스크롤 바닥 근처(sentinel 교차) 도달 시 다음 배치를 append.
// IntersectionObserver 미지원 환경에선 "더보기" 버튼 폴백.
//
// 사용 예:
//   const lazy = mountLazyList({
//     tbody: document.querySelector('#infTbody'),
//     scrollRoot: document.querySelector('#influencersScrollRoot'),
//     rows: filteredUsers,
//     renderRow: (u) => `<tr data-id="${u.id}"><td>${u.name}</td>...</tr>`,
//     pageSize: 80,
//     emptyHtml: '<tr><td colspan="5" class="empty">該当なし</td></tr>',
//   });
//   // 필터/정렬 변경 시
//   lazy.reset(newRows);
//   // 단일 row 업데이트
//   lazy.patchRow(id, '<tr data-id="...">...</tr>');
//   // 페인 전환 시
//   lazy.destroy();
function mountLazyList({ tbody, scrollRoot, rows, renderRow, pageSize = 50, emptyHtml = '' }) {
  if (!tbody) return { reset(){}, patchRow(){}, destroy(){} };
  const state = {
    rows: Array.isArray(rows) ? rows : [],
    cursor: 0,
    observer: null,
    sentinel: null,
    moreBtn: null,
    destroyed: false,
  };

  function clearSentinel() {
    if (state.observer) { state.observer.disconnect(); state.observer = null; }
    if (state.sentinel && state.sentinel.parentNode) state.sentinel.parentNode.removeChild(state.sentinel);
    state.sentinel = null;
    if (state.moreBtn && state.moreBtn.parentNode) state.moreBtn.parentNode.removeChild(state.moreBtn);
    state.moreBtn = null;
  }

  function appendBatch() {
    if (state.destroyed) return;
    const end = Math.min(state.cursor + pageSize, state.rows.length);
    if (end <= state.cursor) return;
    const frag = document.createDocumentFragment();
    const wrap = document.createElement('tbody');
    const html = [];
    for (let i = state.cursor; i < end; i++) html.push(renderRow(state.rows[i]));
    wrap.innerHTML = html.join('');
    while (wrap.firstChild) frag.appendChild(wrap.firstChild);
    // sentinel 바로 앞에 삽입
    if (state.sentinel && state.sentinel.parentNode === tbody) {
      tbody.insertBefore(frag, state.sentinel);
    } else {
      tbody.appendChild(frag);
    }
    state.cursor = end;
    if (state.cursor >= state.rows.length) clearSentinel();
  }

  function mountSentinel() {
    if (state.cursor >= state.rows.length) return;
    // 테이블의 컬럼 수 추정 (첫 행 기준, 없으면 100)
    const colCount = (tbody.querySelector('tr')?.children.length) || 100;
    state.sentinel = document.createElement('tr');
    state.sentinel.className = 'lazy-sentinel';
    state.sentinel.setAttribute('aria-hidden', 'true');
    state.sentinel.innerHTML = `<td colspan="${colCount}" style="padding:0;border:none;height:1px"></td>`;
    tbody.appendChild(state.sentinel);
    if (typeof IntersectionObserver === 'function') {
      state.observer = new IntersectionObserver((entries) => {
        for (const e of entries) if (e.isIntersecting) appendBatch();
      }, { root: scrollRoot || null, rootMargin: '200px 0px', threshold: 0 });
      state.observer.observe(state.sentinel);
    } else {
      // 폴백: 더보기 버튼
      state.moreBtn = document.createElement('tr');
      state.moreBtn.innerHTML = `<td colspan="${colCount}" style="text-align:center;padding:12px"><button type="button" class="btn-ghost" onclick="this.disabled=true">더보기 (${state.rows.length - state.cursor}건)</button></td>`;
      const btn = state.moreBtn.querySelector('button');
      btn?.addEventListener('click', () => {
        appendBatch();
        btn.disabled = false;
        const left = state.rows.length - state.cursor;
        if (left > 0) btn.textContent = `더보기 (${left}건)`;
      });
      tbody.appendChild(state.moreBtn);
    }
  }

  function initialRender() {
    clearSentinel();
    tbody.innerHTML = '';
    if (!state.rows.length) {
      if (emptyHtml) tbody.innerHTML = emptyHtml;
      return;
    }
    state.cursor = 0;
    appendBatch();
    mountSentinel();
  }

  initialRender();

  return {
    reset(newRows) {
      state.rows = Array.isArray(newRows) ? newRows : [];
      if (scrollRoot) scrollRoot.scrollTop = 0;
      initialRender();
    },
    patchRow(id, html) {
      const sel = `tr[data-id="${CSS && CSS.escape ? CSS.escape(String(id)) : String(id).replace(/"/g,'\\"')}"]`;
      const old = tbody.querySelector(sel);
      if (!old) return;
      const tmp = document.createElement('tbody');
      tmp.innerHTML = html;
      const next = tmp.firstElementChild;
      if (next) old.replaceWith(next);
    },
    destroy() {
      state.destroyed = true;
      clearSentinel();
    },
    get rendered() { return state.cursor; },
    get total() { return state.rows.length; },
  };
}
