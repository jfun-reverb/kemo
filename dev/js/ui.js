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
  return url.replace('/storage/v1/object/public/', '/storage/v1/render/image/public/') + `?width=${w}&quality=${q}&resize=cover`;
}

// lookup_values 캐시에서 라벨 우선 조회, 없으면 하드코딩 폴백
const CHANNEL_LABEL_FALLBACK = {instagram:'Instagram',x:'X(Twitter)',qoo10:'Qoo10',tiktok:'TikTok',youtube:'YouTube'};
function getChannelLabel(ch, lang) {
  if (!ch) return '';
  const useLang = lang === 'ko' ? 'name_ko' : 'name_ja';
  const cache = (typeof _lookupCache !== 'undefined' && _lookupCache.channel) || null;
  return ch.split(',').map(s => s.trim()).filter(Boolean).map(code => {
    if (cache) {
      const row = cache.find(r => r.code === code);
      if (row) return row[useLang] || row.name_ja || code;
    }
    return CHANNEL_LABEL_FALLBACK[code] || code;
  }).join(' + ');
}
// 모집 타입 라벨 (인플루언서 페이지: 일본어, 관리자: 한국어)
function getRecruitTypeLabelJa(t) {
  return t==='monitor'?'Reviewer':t==='gifting'?'Gifting':t==='visit'?'Visit':'';
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
  const m = {pending:'<span class="badge badge-gold">審査中</span>',approved:'<span class="badge badge-green">承認</span>',rejected:'<span class="badge badge-gray">非承認</span>'};
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
      <img src="${img.data}" style="width:100%;height:100%;object-fit:cover">
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
  var removeFn = listName === 'campImgData' ? 'removeCampImg' : 'removeEditCampImg';

  wrap.innerHTML = imgList.map(function(img,i) {
    return '<div data-idx="'+i+'" data-list="'+listName+'" data-wrap="'+wrapId+'" data-counter="'+counterId+'"' +
      ' style="position:relative;width:88px;height:88px;flex-shrink:0">' +
      '<img src="'+img.data+'" style="width:88px;height:88px;object-fit:cover;border-radius:10px;border:2px solid '+(i===0?'var(--pink)':'var(--line)')+'">' +
      (i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;border-radius:0 0 8px 8px;padding:2px">MAIN</div>':'') +
      (img.original?'<div style="position:absolute;top:2px;left:2px;background:var(--pink);color:#fff;font-size:8px;font-weight:700;padding:1px 5px;border-radius:4px;z-index:2">CROP</div>':'') +
      '<button data-action="remove" data-i="'+i+'" data-remove-fn="'+removeFn+'" style="position:absolute;top:-4px;right:-4px;width:22px;height:22px;background:#333;color:#fff;border-radius:50%;font-size:12px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer;z-index:2" title="삭제"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">close</span></button>' +
      '<div style="position:absolute;bottom:'+(i===0?'20px':'2px')+';right:2px;display:flex;gap:3px;z-index:2">' +
        (img.original?'<button data-action="restore" data-i="'+i+'" data-list="'+listName+'" data-wrap="'+wrapId+'" data-counter="'+counterId+'" style="width:26px;height:26px;background:rgba(0,0,0,.7);color:#fff;border-radius:6px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="원본 복원"><span class="material-icons-round" style="font-size:16px">undo</span></button>':'') +
        '<button data-action="crop" data-i="'+i+'" data-list="'+listName+'" data-wrap="'+wrapId+'" data-counter="'+counterId+'" style="width:26px;height:26px;background:rgba(0,0,0,.7);color:#fff;border-radius:6px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="1:1 크롭"><span class="material-icons-round" style="font-size:16px">crop</span></button>' +
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
  if (!list || !list[idx] || !list[idx].original) return;
  list[idx].data = list[idx].original;
  delete list[idx].original;
  renderImgPreview(list, wrapId, counterId, listName);
  toast('원본으로 복원됨','success');
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
  var canvas = _cropperInstance.getCroppedCanvas({width:1080, height:1080, imageSmoothingQuality:'high'});
  var croppedData = canvas.toDataURL('image/jpeg', 0.92);
  var list = getImgList(_cropTarget.listName);
  if (list) {
    var item = list[_cropTarget.idx];
    // 원본 보존 — 처음 크롭할 때만 원본 저장
    if (!item.original) item.original = item.data;
    item.data = croppedData;
    renderImgPreview(list, _cropTarget.wrapId, _cropTarget.counterId, _cropTarget.listName);
  }
  closeCropModal();
  toast('크롭 완료 (원본 유지됨)','success');
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
        <dt>お問い合わせ</dt><dd>公式LINE <a href="https://line.me/R/ti/p/@586mnjoc" target="_blank" rel="noopener">@586mnjoc</a></dd>
      </dl>
      <p>REVERBは、日本で活動するインフルエンサーの皆さまと、韓国の人気Kブランドをつなぐ体験型プラットフォームです。</p>
    `;
  }
  if (kind === 'terms' || kind === 'privacy') {
    return `
      <p>${kind==='terms'?'利用規約':'個人情報処理方針'}の日本語版は現在準備中です。</p>
      <p>ご質問は公式LINE（<a href="https://line.me/R/ti/p/@586mnjoc" target="_blank" rel="noopener">@586mnjoc</a>）までお問い合わせください。</p>
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
