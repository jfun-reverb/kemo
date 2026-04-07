// ══════════════════════════════════════
// UI — トースト・ローディング・モーダル・スライダー
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

// ── IMAGE SLIDER ──
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

// ── SLIDE IMG PREVIEW (admin) ──
function previewSlideImgs() {
  const preview = $('slideImgPreview');
  if (!preview) return;
  preview.innerHTML = campImgData.map((img,i)=>`
    <div style="position:relative;width:68px;height:68px;border-radius:8px;overflow:hidden;border:2px solid ${i===0?'var(--pink)':'var(--line)'}">
      <img src="${img.data}" style="width:100%;height:100%;object-fit:cover">
      ${i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;padding:1px">MAIN</div>':''}
    </div>`).join('');
}

// ── OPTIONAL SECTION TOGGLE ──
function toggleOptional() {
  const sec = $('optionalSection');
  const arrow = $('optionalArrow');
  if (!sec) return;
  const isOpen = sec.style.display !== 'none';
  sec.style.display = isOpen ? 'none' : 'block';
  if (arrow) arrow.textContent = isOpen ? '▶' : '▼';
}

// ── PASSWORD TOGGLE ──
function togglePw(inputId, btn) {
  const input = $(inputId);
  if (!input) return;
  if (input.type === 'password') { input.type = 'text'; btn.textContent = '🙈'; }
  else { input.type = 'password'; btn.textContent = '👁'; }
}

// ── ZIP CODE LOOKUP ──
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

// ── CONTENT TYPE / RECRUIT TYPE TOGGLE ──
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

// ── IMAGE UPLOAD ──
const campImgData = [];
function handleCampImgSelect(input) {
  const files = Array.from(input.files);
  const remaining = 8 - campImgData.length;
  if (remaining <= 0) { toast('最大8枚まで追加できます', 'error'); return; }
  const toAdd = files.slice(0, remaining);
  let loaded = 0;
  toAdd.forEach(file => {
    if (!file.type.startsWith('image/')) { toast('画像ファイルのみ追加できます', 'error'); return; }
    if (file.size > 5 * 1024 * 1024) { toast(`${file.name} はサイズが大きすぎます（最大5MB）`, 'error'); return; }
    const reader = new FileReader();
    reader.onload = e => {
      campImgData.push({data: e.target.result, name: file.name, type: file.type});
      loaded++;
      if (loaded === toAdd.length) renderCampImgPreview();
    };
    reader.readAsDataURL(file);
  });
  input.value = '';
}
function removeCampImg(idx) { campImgData.splice(idx, 1); renderCampImgPreview(); }
function renderCampImgPreview() {
  const wrap = $('campImgPreviewWrap');
  const counter = $('campImgCounter');
  if (!wrap) return;
  if (counter) counter.textContent = `${campImgData.length}/8`;
  wrap.innerHTML = campImgData.map((img,i) => `
    <div style="position:relative;width:80px;height:80px;flex-shrink:0">
      <img src="${img.data}" style="width:80px;height:80px;object-fit:cover;border-radius:8px;border:2px solid ${i===0?'var(--pink)':'var(--line)'}">
      ${i===0?'<div style="position:absolute;bottom:0;left:0;right:0;background:var(--pink);color:#fff;font-size:9px;font-weight:700;text-align:center;border-radius:0 0 6px 6px;padding:1px">MAIN</div>':''}
      <button onclick="removeCampImg(${i})" style="position:absolute;top:-6px;right:-6px;width:18px;height:18px;background:#333;color:#fff;border-radius:50%;font-size:11px;display:flex;align-items:center;justify-content:center;border:none;cursor:pointer;line-height:1">×</button>
    </div>`).join('') +
    (campImgData.length < 8 ? `
    <label style="width:80px;height:80px;flex-shrink:0;border:2px dashed var(--line);border-radius:8px;display:flex;flex-direction:column;align-items:center;justify-content:center;cursor:pointer;gap:4px;background:var(--bg)">
      <span style="font-size:22px;color:var(--muted)">+</span>
      <span style="font-size:10px;color:var(--muted)">追加</span>
      <input type="file" accept="image/*" multiple style="display:none" onchange="handleCampImgSelect(this)">
    </label>` : '');
}
function handleFileSelect(input) {
  const preview = $('filePreview');
  if (!preview) return;
  preview.innerHTML = '';
  Array.from(input.files).slice(0,5).forEach(f => {
    const item = document.createElement('div');
    item.style.cssText = 'display:flex;align-items:center;gap:6px;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:6px 12px;font-size:12px;color:var(--ink)';
    item.innerHTML = `🖼 ${f.name} <span style="color:var(--muted)">(${(f.size/1024).toFixed(0)}KB)</span>`;
    preview.appendChild(item);
  });
}

// ── LOGIN PROMPT ──
function closeLoginPrompt(e) {
  if (e && e.target !== $('loginPromptOverlay')) return;
  const o = $('loginPromptOverlay');
  if (o) o.style.display='none';
}
