// ══════════════════════════════════════
// UI — 알림 팝업, 로딩, 모달, 슬라이더
// ══════════════════════════════════════

function toast(msg, type='') {
  const el = document.getElementById('toast');
  el.textContent = msg; el.className = 'show' + (type ? ' '+type : '');
  clearTimeout(el._t); el._t = setTimeout(()=>el.className='', 2800);
}
function loading(v) { document.getElementById('loadingOverlay').classList.toggle('show', v); }
function $(id) { return document.getElementById(id); }
function formatDate(d) { return d ? new Date(d).toLocaleDateString('ja-JP') : ''; }
function getChannelLabel(ch) {
  const m = {instagram:'Instagram',x:'X(Twitter)',qoo10:'Qoo10','instagram,x':'Instagram + X'};
  return m[ch] || ch;
}
function getStatusBadge(s) {
  const m = {pending:'<span class="badge badge-gold">審査中</span>',approved:'<span class="badge badge-green">承認</span>',rejected:'<span class="badge badge-gray">非承認</span>'};
  return m[s] || s;
}
function getChannelBadge(ch) {
  const m = {instagram:'<span class="badge badge-blue">Instagram</span>',x:'<span class="badge badge-gray">X</span>',qoo10:'<span class="badge badge-gold">Qoo10</span>'};
  return m[ch] || `<span class="badge badge-gray">${ch}</span>`;
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
  if (input.type === 'password') { input.type = 'text'; btn.textContent = '🙈'; }
  else { input.type = 'password'; btn.textContent = '👁'; }
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
  });
  const label = rb.closest('label');
  label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';label.style.fontWeight='700';
}
function toggleEditRT(rb) {
  document.querySelectorAll('[id^="edit-rt-"]').forEach(l=>{l.style.borderColor='var(--line)';l.style.background='';l.style.color='';l.style.fontWeight='600';});
  const label=rb.closest('label');
  label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';label.style.fontWeight='700';
}
function toggleEditCT(cb) {
  const label=cb.closest('label');
  if(cb.checked){label.style.borderColor='var(--pink)';label.style.background='var(--light-pink)';label.style.color='var(--pink)';}
  else{label.style.borderColor='var(--line)';label.style.background='';label.style.color='';}
}

// ── 이미지 업로드 (드래그앤드롭 + 순서변경 + 크롭 + 다운로드) ──
var campImgData = [];
window.campImgData = campImgData;
let _dragSrcIdx = null;
let _cropTarget = null;
let _cropperInstance = null;

// 드래그앤드롭 업로드 초기화
function initImgDropZone(zoneId, fileInputId) {
  const zone = $(zoneId);
  if (!zone) return;
  zone.addEventListener('dragover', e => { e.preventDefault(); zone.style.borderColor='var(--pink)'; zone.style.background='var(--light-pink)'; });
  zone.addEventListener('dragleave', e => { e.preventDefault(); zone.style.borderColor='var(--line)'; zone.style.background='var(--bg)'; });
  zone.addEventListener('drop', e => {
    e.preventDefault();
    zone.style.borderColor='var(--line)'; zone.style.background='var(--bg)';
    const files = Array.from(e.dataTransfer.files).filter(f=>f.type.startsWith('image/'));
    if (files.length) addImagesToList(files, campImgData, 'campImgPreviewWrap', 'campImgCounter');
  });
}

function handleCampImgSelect(input) {
  const files = Array.from(input.files);
  addImagesToList(files, campImgData, 'campImgPreviewWrap', 'campImgCounter');
  input.value = '';
}

function addImagesToList(files, imgList, wrapId, counterId) {
  const remaining = 8 - imgList.length;
  if (remaining <= 0) { toast('最大8枚まで追加できます','error'); return; }
  const toAdd = files.slice(0, remaining);
  let loaded = 0;
  toAdd.forEach(file => {
    if (!file.type.startsWith('image/')) return;
    if (file.size > 5*1024*1024) { toast(`${file.name} 5MB 초과`,'error'); return; }
    const reader = new FileReader();
    reader.onload = e => {
      imgList.push({data:e.target.result, name:file.name});
      loaded++;
      if (loaded === toAdd.length) renderImgPreview(imgList, wrapId, counterId);
    };
    reader.readAsDataURL(file);
  });
}

function removeCampImg(idx) { campImgData.splice(idx,1); renderImgPreview(campImgData,'campImgPreviewWrap','campImgCounter'); }

function _getImgListName(imgList) {
  if (imgList === window.campImgData) return 'campImgData';
  if (imgList === window.editCampImgData) return 'editCampImgData';
  return 'campImgData';
}

function renderImgPreview(imgList, wrapId, counterId) {
  const wrap = $(wrapId);
  const counter = $(counterId);
  if (!wrap) return;
  if (counter) counter.textContent = `${imgList.length}/8`;
  const listName = _getImgListName(imgList);
  const removeFn = listName === 'campImgData' ? 'removeCampImg' : 'removeEditCampImg';

  wrap.innerHTML = imgList.map((img,i) => `
    <div class="img-thumb" draggable="true" data-idx="${i}"
      ondragstart="imgDragStart(event,${i},'${listName}','${wrapId}','${counterId}')"
      ondragover="event.preventDefault();this.style.outline='2px solid var(--pink)'"
      ondragleave="this.style.outline='none'"
      ondrop="imgDrop(event,${i},'${listName}','${wrapId}','${counterId}')"
      style="position:relative;width:88px;height:88px;flex-shrink:0;cursor:grab">
      <img src="${img.data}" style="width:88px;height:88px;object-fit:cover;border-radius:10px;border:2px solid ${i===0?'var(--pink)':'var(--line)'}" onerror="this.style.background='var(--bg)'">
      ${i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;border-radius:0 0 8px 8px;padding:2px">MAIN</div>':''}
      <div style="position:absolute;top:-4px;right:-4px;display:flex;gap:2px">
        <button onclick="event.stopPropagation();${removeFn}(${i})" style="width:20px;height:20px;background:#333;color:#fff;border-radius:50%;font-size:12px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="삭제">×</button>
      </div>
      <div style="position:absolute;bottom:${i===0?'18px':'2px'};right:2px;display:flex;gap:2px">
        <button onclick="event.stopPropagation();openCropModal(${i},'${listName}','${wrapId}','${counterId}')" style="width:22px;height:22px;background:rgba(0,0,0,.6);color:#fff;border-radius:4px;font-size:13px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="1:1 크롭"><span class="material-icons-round" style="font-size:14px">crop</span></button>
        <button onclick="event.stopPropagation();downloadImg(${i},'${listName}')" style="width:22px;height:22px;background:rgba(0,0,0,.6);color:#fff;border-radius:4px;font-size:13px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer" title="다운로드"><span class="material-icons-round" style="font-size:14px">download</span></button>
      </div>
    </div>`).join('');
}

// 드래그앤드롭 순서 변경
function imgDragStart(e, idx, listName) {
  _dragSrcIdx = idx;
  e.dataTransfer.effectAllowed = 'move';
}

function imgDrop(e, targetIdx, listName, wrapId, counterId) {
  e.preventDefault();
  e.currentTarget.style.outline = 'none';
  if (_dragSrcIdx === null || _dragSrcIdx === targetIdx) return;
  const list = window[listName];
  const item = list.splice(_dragSrcIdx, 1)[0];
  list.splice(targetIdx, 0, item);
  _dragSrcIdx = null;
  renderImgPreview(list, wrapId, counterId);
}

// 이미지 다운로드
function downloadImg(idx, listName) {
  const img = window[listName][idx];
  if (!img) return;
  const a = document.createElement('a');
  a.href = img.data;
  a.download = img.name || `image-${idx+1}.jpg`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}

// 1:1 크롭 모달
function openCropModal(idx, listName, wrapId, counterId) {
  _cropTarget = {idx, listName, wrapId, counterId};
  const img = window[listName][idx];
  if (!img) return;
  const cropImg = $('cropImage');
  cropImg.src = img.data;
  $('cropModal').style.display = 'flex';
  setTimeout(() => {
    if (_cropperInstance) _cropperInstance.destroy();
    _cropperInstance = new Cropper(cropImg, {
      aspectRatio: 1,
      viewMode: 1,
      dragMode: 'move',
      autoCropArea: 1,
      responsive: true,
      background: false,
    });
  }, 100);
}

function closeCropModal() {
  $('cropModal').style.display = 'none';
  if (_cropperInstance) { _cropperInstance.destroy(); _cropperInstance = null; }
  _cropTarget = null;
}

function applyCrop() {
  if (!_cropperInstance || !_cropTarget) return;
  const canvas = _cropperInstance.getCroppedCanvas({width:1080, height:1080, imageSmoothingQuality:'high'});
  const croppedData = canvas.toDataURL('image/jpeg', 0.92);
  const list = window[_cropTarget.listName];
  list[_cropTarget.idx].data = croppedData;
  renderImgPreview(list, _cropTarget.wrapId, _cropTarget.counterId);
  closeCropModal();
  toast('크롭 완료 ✓','success');
}

// ── 로그인 안내 팝업 ──
function closeLoginPrompt(e) {
  if (e && e.target !== $('loginPromptOverlay')) return;
  const o = $('loginPromptOverlay');
  if (o) o.style.display='none';
}
