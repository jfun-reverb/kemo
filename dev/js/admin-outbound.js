// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-outbound.js
// ═════════════════════════════════════════════════════════════════
//
// 인플루언서 추천 명단 페인 (아웃바운드 시딩·타이업 — 사양서 2026-07-08-influencer-recommendation.md,
//   인계서 2026-07-09-...-stage1-handoff.md §PR 1단계-b).
//   · 영업팀이 직접 컨택하는 명단(globalreverb 미가입, 별도 자산) CRUD 페인
//   · 목록/필터(계열·세분 다중 · 등급·가용상태·채널 · 검색) + IntersectionObserver lazy-load
//   · 등록·편집 모달(기본·분류·채널4·가격5·운영·콘텐츠) + 대표 이미지 업로드
//   · 저장·삭제 후 refreshPane('outbound') (quality.md 「관리자 모달 페인 갱신」)
//
// ⚠ 내부 전용 필드(nego_memo·가격 5종)는 5단계 브랜드 뷰에서 같은 컴포넌트를 재사용할 때
//   반드시 제외해야 한다(HANDOFF 「주의」). 1단계는 관리자 전용 페인이라 그대로 노출한다.
// ⚠ storage.js 명단 함수(fetchOutboundInfluencers/upsert.../delete.../uploadOutboundImage 등)는
//   호출만 — 재정의 금지. loadOutbound 는 switchAdminPane(admin-core.js) loaders 가 호출 →
//   전역 유지(이름 변경 금지). 빌드 순서상 admin.js 앞.
// ═════════════════════════════════════════════════════════════════

let _outbound = [];
let _outboundLoaded = false;
// 열려 있는 편집 모달 대상: { id, isNew, imagePath, pendingFile, removeImage }
let _outboundEditCtx = null;
var outboundLazy = null;
const OUTBOUND_PAGE_SIZE = 50;
const OUTBOUND_MAX_POSTS = 5;

// lookup code → name_ko 맵 + 옵션 배열 (부팅/페인 진입 시 로드)
let _obSeries = [];    // [{code, name_ko, ...}]
let _obCategory = [];
let _obTier = [];
const _obSeriesMap = {};
const _obCategoryMap = {};
const _obTierMap = {};

// 채널 4종 메타 (컬럼 키 매핑) — 주채널 표시·채널 필터 공용
const OUTBOUND_CHANNELS = [
  { key: 'ig',      label: 'Instagram', handleCol: 'ig_handle',      followCol: 'ig_followers' },
  { key: 'tiktok',  label: 'TikTok',    handleCol: 'tiktok_handle',  followCol: 'tiktok_followers' },
  { key: 'youtube', label: 'YouTube',   handleCol: 'youtube_handle', followCol: 'youtube_followers' },
  { key: 'x',       label: 'X',         handleCol: 'x_handle',       followCol: 'x_followers' },
];

const OUTBOUND_AVAIL_META = {
  available:   { ko: '진행가능', cls: 'badge-green' },
  adjusting:   { ko: '조율중',   cls: 'badge-gold'  },
  unavailable: { ko: '불가',     cls: 'badge-gray'  },
};

// ════════════════════════════════════════════════════════════════════
// SECTION: OUTBOUND — 로드 / 조회 / 렌더
// ════════════════════════════════════════════════════════════════════

// 페인 진입 로더 — ①lookup 3종 로드(맵·옵션) ②필터·선택 옵션 채움 ③전건 조회·렌더
async function loadOutbound() {
  await loadOutboundLookups();
  populateOutboundTierFilter();
  populateRecoFormOptions();   // 조건 추천 탭 계열·등급 select 옵션
  await reloadOutboundData();
}

// lookup 3종 로드 후 code→name_ko 맵과 옵션 배열 구성 (실패해도 코드값 폴백으로 동작)
async function loadOutboundLookups() {
  try {
    const [series, category, tier] = await Promise.all([
      fetchLookups('ob_series'), fetchLookups('ob_category'), fetchLookups('ob_tier'),
    ]);
    _obSeries = series || []; _obCategory = category || []; _obTier = tier || [];
  } catch (e) {
    console.warn('[loadOutboundLookups]', e);
    _obSeries = []; _obCategory = []; _obTier = [];
  }
  _obSeries.forEach(r => { _obSeriesMap[r.code] = r.name_ko; });
  _obCategory.forEach(r => { _obCategoryMap[r.code] = r.name_ko; });
  _obTier.forEach(r => { _obTierMap[r.code] = r.name_ko; });
}

// 데이터 재조회 — 저장·삭제 후 refreshPane('outbound') 가 호출
async function reloadOutboundData() {
  _outbound = await fetchOutboundInfluencers({});
  _outboundLoaded = true;
  renderOutboundList();
}

function outboundSeriesLabel(code) { return code ? (_obSeriesMap[code] || code) : '—'; }
function outboundCategoryLabel(code) { return code ? (_obCategoryMap[code] || code) : '—'; }
function outboundTierLabel(code) { return code ? (_obTierMap[code] || code) : '—'; }

function outboundAvailBadge(status) {
  const meta = OUTBOUND_AVAIL_META[status] || { ko: status || '—', cls: 'badge-gray' };
  return `<span class="badge ${meta.cls}" style="font-size:11px;white-space:nowrap">${esc(meta.ko)}</span>`;
}

// 주채널 = 핸들이 있는 채널 중 팔로워가 가장 많은 채널(동률·미상은 정의 순서 우선)
function outboundPrimaryChannel(o) {
  let best = null;
  OUTBOUND_CHANNELS.forEach(ch => {
    const handle = o[ch.handleCol];
    if (!handle) return;
    const followers = o[ch.followCol];
    const fv = (followers == null) ? -1 : Number(followers);
    if (!best || fv > best.fv) best = { ch, handle, followers, fv };
  });
  return best;
}

function readOutboundFilters() {
  const seriesSel = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('outboundSeriesMulti') : [];
  const categorySel = (typeof getMultiFilterValues === 'function') ? getMultiFilterValues('outboundCategoryMulti') : [];
  return {
    series: seriesSel,
    category: categorySel,
    tier: ($('outboundTierFilter')?.value || ''),
    availability: ($('outboundAvailFilter')?.value || ''),
    channel: ($('outboundChannelFilter')?.value || ''),
    search: (($('outboundSearch')?.value) || '').trim().toLowerCase(),
  };
}

// 현재 필터 조건으로 _outbound 를 거른 배열 (목록·엑셀 공용)
function getFilteredOutbound() {
  const f = readOutboundFilters();
  let rows = _outbound.slice();
  if (f.series.length) rows = rows.filter(o => f.series.includes(o.series_code));
  if (f.category.length) rows = rows.filter(o => f.category.includes(o.category_code));
  if (f.tier) rows = rows.filter(o => o.tier_code === f.tier);
  if (f.availability) rows = rows.filter(o => o.availability === f.availability);
  if (f.channel) {
    const ch = OUTBOUND_CHANNELS.find(c => c.key === f.channel);
    if (ch) rows = rows.filter(o => !!o[ch.handleCol]);
  }
  if (f.search) rows = rows.filter(o =>
    matchSearchTokens(f.search, [o.name_ko, o.account_id, o.agency]));
  return rows;
}

// 계열·세분 다중필터 옵션 동기화 (syncMultiFilter — 선택값은 보존)
function syncOutboundFilterOptions() {
  if (typeof syncMultiFilter !== 'function') return;
  const seriesOpts = _obSeries.map(r => ({ value: r.code, label: r.name_ko }));
  const categoryOpts = _obCategory.map(r => ({ value: r.code, label: r.name_ko }));
  syncMultiFilter('outboundSeriesMulti', '전체 계열', seriesOpts, renderOutboundList);
  syncMultiFilter('outboundCategoryMulti', '전체 세분', categoryOpts, renderOutboundList);
}

// 등급 필터 select 옵션 채움 (loadOutbound 에서 1회)
function populateOutboundTierFilter() {
  const sel = $('outboundTierFilter');
  if (!sel) return;
  const cur = sel.value;
  sel.innerHTML = '<option value="">전체</option>'
    + _obTier.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
  sel.value = cur;
}

function renderOutboundList() {
  const tbody = $('outboundTableBody');
  if (!tbody) return;
  syncOutboundFilterOptions();
  const rows = getFilteredOutbound();

  const cnt = $('outboundTotalCount');
  if (cnt) cnt.textContent = `총 ${rows.length}명`;

  // 데이터 0건 — 이관 전이면 안내(PR 1단계-c), 필터 결과 0건이면 다른 문구
  const emptyMsg = (_outboundLoaded && _outbound.length === 0)
    ? '아직 등록된 명단이 없습니다. 「신규 등록」으로 추가하거나, 구글시트 명단을 먼저 이관하세요.'
    : '해당 조건의 인플루언서가 없습니다.';

  const scrollRoot = tbody.closest('.admin-table-wrap');
  if (outboundLazy) outboundLazy.destroy();
  outboundLazy = mountLazyList({
    tbody,
    scrollRoot,
    rows,
    renderRow: renderOutboundRow,
    pageSize: OUTBOUND_PAGE_SIZE,
    emptyHtml: `<tr><td colspan="12" style="text-align:center;color:var(--muted);padding:30px">${esc(emptyMsg)}</td></tr>`,
  });
}

function renderOutboundRow(o) {
  const id = esc(o.id);

  // 대표 이미지 썸네일 (공개 URL 조립 → imgThumb, 실패 시 원본 폴백)
  let thumbCell = '<span style="color:var(--muted);font-size:11px">—</span>';
  if (o.rep_image_path) {
    const url = (typeof outboundImagePublicUrl === 'function') ? outboundImagePublicUrl(o.rep_image_path) : '';
    if (url) {
      const t = (typeof imgThumb === 'function') ? imgThumb(url, 96, 70) : url;
      thumbCell = `<img src="${esc(t)}" data-orig="${esc(url)}" onerror="if(this.dataset.orig&&this.src!==this.dataset.orig){this.src=this.dataset.orig}" onclick="openImageLightbox('${esc(url)}')" style="width:40px;height:40px;object-fit:cover;border-radius:6px;border:1px solid var(--line);cursor:pointer">`;
    }
  }

  const nameCell = `<div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openOutboundEditModal('${id}')">${esc(o.name_ko || '—')}</div>`;

  const agencyCell = o.agency
    ? `<span style="font-size:12px">${esc(o.agency)}</span>`
    : '<span style="font-size:11px;color:var(--muted)">—</span>';

  return `<tr>
    <td>${thumbCell}</td>
    <td>${nameCell}</td>
    <td style="font-size:12px">${esc(outboundSeriesLabel(o.series_code))}</td>
    <td style="font-size:12px">${esc(outboundCategoryLabel(o.category_code))}</td>
    <td style="font-size:12px">${esc(outboundTierLabel(o.tier_code))}</td>
    ${outboundChannelCells(o)}
    <td>${outboundAvailBadge(o.availability)}</td>
    <td>${agencyCell}</td>
    <td><button class="btn btn-ghost btn-xs" onclick="openOutboundEditModal('${id}')">편집</button></td>
  </tr>`;
}

// 팔로워 표시 — NULL(미상)은 '미상', 숫자는 천단위 구분
function outboundFollowersDisplay(v) {
  if (v == null) return '(미상)';
  return Number(v).toLocaleString() + '명';
}

// 채널 key(ig) → snsProfileUrl 채널명(instagram) 매핑. 나머지는 동일.
const OUTBOUND_CH_SNS = { ig: 'instagram', tiktok: 'tiktok', youtube: 'youtube', x: 'x' };

// 채널별 팔로워 셀 — 핸들 있으면 팔로워 + @핸들(클릭 시 새 탭 SNS 이동), 없으면(미보유) —
function outboundChannelFollowersCell(o, ch) {
  const handle = o[ch.handleCol];
  if (!handle) return '<span style="color:var(--muted);font-size:11px">—</span>';
  const url = (typeof snsProfileUrl === 'function') ? snsProfileUrl(OUTBOUND_CH_SNS[ch.key], handle) : '';
  const handleHtml = url
    ? `<a href="${esc(url)}" target="_blank" rel="noopener noreferrer" style="font-size:10px;color:var(--pink);text-decoration:none">@${esc(handle)}</a>`
    : `<span style="font-size:10px;color:var(--muted)">@${esc(handle)}</span>`;
  return `<div style="font-size:12px">${esc(outboundFollowersDisplay(o[ch.followCol]))}</div>`
    + `<div>${handleHtml}</div>`;
}

// 4채널 팔로워 <td> 4칸 (명단·추천 결과 공용, OUTBOUND_CHANNELS 순서 = ig·tiktok·youtube·x)
function outboundChannelCells(o) {
  return OUTBOUND_CHANNELS.map(ch => `<td>${outboundChannelFollowersCell(o, ch)}</td>`).join('');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: OUTBOUND — 등록·편집 모달
// ════════════════════════════════════════════════════════════════════

// id=null → 신규 등록, id 있으면 편집. 신규는 crypto.randomUUID() 로 id 를 미리 확정해
//   대표 이미지 경로 {id}/... 를 저장 전에 만든다(upsert 시 그 id 로 INSERT).
function openOutboundEditModal(id) {
  const isNew = !id;
  const o = isNew ? null : _outbound.find(x => x.id === id);
  if (!isNew && !o) { toast('명단을 찾을 수 없습니다', 'warn'); return; }

  const newId = isNew ? outboundGenId() : o.id;
  _outboundEditCtx = { id: newId, isNew, imagePath: isNew ? null : (o.rep_image_path || null), pendingFile: null, removeImage: false };

  // 분류 select 옵션 채움 (세분·등급)
  populateOutboundSelectOptions();

  const set = (elId, val) => { const el = $(elId); if (el) el.value = (val == null ? '' : val); };
  set('obName', isNew ? '' : o.name_ko);
  set('obAccountId', isNew ? '' : o.account_id);
  set('obCategory', isNew ? '' : o.category_code);
  set('obTier', isNew ? '' : o.tier_code);
  set('obAvailability', isNew ? 'available' : (o.availability || 'available'));
  onOutboundCategoryChange();  // 계열 라벨 자동 채움

  set('obIgHandle', isNew ? '' : o.ig_handle);
  set('obIgFollowers', isNew ? '' : outboundNumToInput(o.ig_followers));
  set('obTiktokHandle', isNew ? '' : o.tiktok_handle);
  set('obTiktokFollowers', isNew ? '' : outboundNumToInput(o.tiktok_followers));
  set('obYoutubeHandle', isNew ? '' : o.youtube_handle);
  set('obYoutubeFollowers', isNew ? '' : outboundNumToInput(o.youtube_followers));
  set('obXHandle', isNew ? '' : o.x_handle);
  set('obXFollowers', isNew ? '' : outboundNumToInput(o.x_followers));

  set('obPriceFeed', isNew ? '' : outboundNumToInput(o.price_feed));
  set('obPriceReels', isNew ? '' : outboundNumToInput(o.price_reels));
  set('obPriceStory', isNew ? '' : outboundNumToInput(o.price_story));
  set('obPriceTiktok', isNew ? '' : outboundNumToInput(o.price_tiktok));
  set('obPriceSecondary', isNew ? '' : outboundNumToInput(o.price_secondary));

  set('obContactChannel', isNew ? '' : o.contact_channel);
  set('obAgency', isNew ? '' : o.agency);
  set('obNegoMemo', isNew ? '' : o.nego_memo);

  const consent = $('obContentConsent');
  if (consent) consent.checked = isNew ? false : !!o.content_consent;

  // 대표 이미지 미리보기
  outboundRenderImagePreview(_outboundEditCtx.imagePath);
  const fileInput = $('obImageFile');
  if (fileInput) fileInput.value = '';

  // 대표 게시물 링크
  const posts = (!isNew && Array.isArray(o.rep_posts)) ? o.rep_posts : [];
  outboundRenderRepPosts(posts);

  const titleEl = $('outboundModalTitle');
  if (titleEl) titleEl.textContent = isNew ? '인플루언서 등록' : '인플루언서 편집';
  const delBtn = $('obDeleteBtn');
  if (delBtn) delBtn.style.display = isNew ? 'none' : '';
  const saveBtn = $('obSaveBtn');
  if (saveBtn) saveBtn.disabled = false;

  openModal('outboundEditModal');
}

function outboundGenId() {
  return (window.crypto && crypto.randomUUID)
    ? crypto.randomUUID()
    : (Date.now().toString(36) + Math.random().toString(36).substring(2));
}

function closeOutboundEditModal() {
  closeModal('outboundEditModal');
  _outboundEditCtx = null;
}

// 세분·등급 select 옵션 채움 (모달 열 때)
function populateOutboundSelectOptions() {
  const catSel = $('obCategory');
  if (catSel) {
    catSel.innerHTML = '<option value="">선택 안 함</option>'
      + _obCategory.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
  }
  const tierSel = $('obTier');
  if (tierSel) {
    tierSel.innerHTML = '<option value="">선택 안 함</option>'
      + _obTier.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
  }
}

// 세분 선택 → 계열 자동 채움 (OB_CATEGORY_SERIES 매핑, shared.js)
function onOutboundCategoryChange() {
  const cat = $('obCategory')?.value || '';
  const seriesCode = cat && (typeof OB_CATEGORY_SERIES !== 'undefined') ? OB_CATEGORY_SERIES[cat] : '';
  const labelEl = $('obSeriesLabel');
  if (labelEl) labelEl.value = seriesCode ? outboundSeriesLabel(seriesCode) : '';
}

// 대표 게시물 링크 입력 행 렌더 (최대 5개, 최소 1개 빈 행 노출)
function outboundRenderRepPosts(posts) {
  const wrap = $('obRepPosts');
  if (!wrap) return;
  let urls = (posts || []).map(p => (p && p.url) ? p.url : (typeof p === 'string' ? p : '')).filter(Boolean);
  if (urls.length === 0) urls = [''];
  wrap.innerHTML = urls.map((u, i) => outboundRepPostRowHtml(u, i)).join('');
  outboundUpdateAddPostBtn();
}

function outboundRepPostRowHtml(url, idx) {
  return `<div class="ob-post-row" data-idx="${idx}">
    <input type="text" class="form-input ob-post-url" value="${esc(url || '')}" placeholder="게시물 링크(URL)">
    <button type="button" class="btn btn-ghost btn-xs" onclick="removeOutboundRepPost(${idx})" style="color:#C33" title="이 링크 제거">✕</button>
  </div>`;
}

// "링크 추가" 버튼은 마지막 행 아래에 동적으로 (5개 미만일 때만)
function outboundUpdateAddPostBtn() {
  const wrap = $('obRepPosts');
  if (!wrap) return;
  const old = $('obAddPostBtn');
  if (old) old.remove();
  const count = wrap.querySelectorAll('.ob-post-row').length;
  if (count < OUTBOUND_MAX_POSTS) {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.id = 'obAddPostBtn';
    btn.className = 'btn btn-ghost btn-xs';
    btn.textContent = '+ 링크 추가';
    btn.onclick = addOutboundRepPost;
    wrap.appendChild(btn);
  }
}

function addOutboundRepPost() {
  const urls = outboundCollectRepPostUrls(true);  // 빈 값 포함해 현재 입력 보존
  if (urls.length >= OUTBOUND_MAX_POSTS) { toast('링크는 최대 5개까지 입력할 수 있습니다', 'warn'); return; }
  urls.push('');
  outboundRenderRepPosts(urls.map(u => ({ url: u })));
}

function removeOutboundRepPost(idx) {
  const urls = outboundCollectRepPostUrls(true);
  urls.splice(idx, 1);
  if (urls.length === 0) urls.push('');
  outboundRenderRepPosts(urls.map(u => ({ url: u })));
}

// 현재 입력 중인 링크 URL 수집 — keepEmpty=true 면 빈 값도 포함(재렌더용)
function outboundCollectRepPostUrls(keepEmpty) {
  const wrap = $('obRepPosts');
  if (!wrap) return [];
  const inputs = [...wrap.querySelectorAll('.ob-post-url')];
  const urls = inputs.map(i => (i.value || '').trim());
  return keepEmpty ? urls : urls.filter(Boolean);
}

// ── 대표 이미지 ──
function onOutboundImagePicked(input) {
  const file = input.files && input.files[0];
  if (!file) return;
  const ALLOWED = ['image/jpeg', 'image/jpg', 'image/png', 'image/webp'];
  if (!ALLOWED.includes(file.type)) { toast('JPG · PNG · WEBP 이미지만 업로드할 수 있습니다', 'warn'); input.value = ''; return; }
  if (file.size > 5 * 1024 * 1024) { toast('이미지는 5MB 이하만 업로드할 수 있습니다', 'warn'); input.value = ''; return; }
  if (_outboundEditCtx) { _outboundEditCtx.pendingFile = file; _outboundEditCtx.removeImage = false; }
  const reader = new FileReader();
  reader.onload = (e) => outboundRenderImagePreview(null, e.target.result);
  reader.readAsDataURL(file);
}

// path(기존 저장분) 또는 dataUrl(방금 선택) 로 미리보기 표시
function outboundRenderImagePreview(path, dataUrl) {
  const img = $('obImagePreview');
  const rmBtn = $('obImageRemoveBtn');
  let src = dataUrl || '';
  if (!src && path && typeof outboundImagePublicUrl === 'function') src = outboundImagePublicUrl(path);
  if (img) {
    if (src) { img.src = src; img.style.display = ''; }
    else { img.src = ''; img.style.display = 'none'; }
  }
  if (rmBtn) rmBtn.style.display = src ? '' : 'none';
}

function clearOutboundImage() {
  if (_outboundEditCtx) { _outboundEditCtx.pendingFile = null; _outboundEditCtx.removeImage = true; }
  const fileInput = $('obImageFile');
  if (fileInput) fileInput.value = '';
  outboundRenderImagePreview(null);
}

// ── 저장 ──
async function saveOutboundInfluencer() {
  const ctx = _outboundEditCtx;
  if (!ctx) return;
  const name = ($('obName')?.value || '').trim();
  if (!name) { toast('한글 이름을 입력하세요', 'warn'); return; }

  const saveBtn = $('obSaveBtn');
  if (saveBtn) saveBtn.disabled = true;

  try {
    // 1) 대표 이미지 업로드(새로 선택된 경우만) — 성공 후 경로 확정
    let repImagePath = ctx.imagePath;
    if (ctx.removeImage) repImagePath = null;
    if (ctx.pendingFile) {
      repImagePath = await uploadOutboundImage(ctx.pendingFile, ctx.id);
    }

    // 2) 분류 — 세분 선택 시 계열 자동(OB_CATEGORY_SERIES)
    const categoryCode = $('obCategory')?.value || null;
    const seriesCode = categoryCode && (typeof OB_CATEGORY_SERIES !== 'undefined')
      ? (OB_CATEGORY_SERIES[categoryCode] || null) : null;

    // 3) 대표 게시물 링크 — 정규화 후 {url} 배열 (최대 5)
    const rawUrls = outboundCollectRepPostUrls(false).slice(0, OUTBOUND_MAX_POSTS);
    const repPosts = [];
    rawUrls.forEach(u => {
      const norm = (typeof normalizeUrlInput === 'function') ? normalizeUrlInput(u) : { url: u };
      if (norm && norm.url) repPosts.push({ url: norm.url, thumb_path: '' });
    });

    // 4) 채널 핸들은 extractSnsHandle 로 정규화(@·URL → 핸들만)
    const handleOf = (ch, elId) => {
      const raw = ($(elId)?.value || '').trim();
      if (!raw) return null;
      return (typeof extractSnsHandle === 'function') ? extractSnsHandle(ch, raw) : raw;
    };

    const row = {
      id: ctx.id,
      name_ko: name,
      account_id: ($('obAccountId')?.value || '').trim() || null,
      series_code: seriesCode,
      category_code: categoryCode,
      tier_code: $('obTier')?.value || null,
      ig_handle: handleOf('instagram', 'obIgHandle'),
      ig_followers: outboundParseNum('obIgFollowers'),
      tiktok_handle: handleOf('tiktok', 'obTiktokHandle'),
      tiktok_followers: outboundParseNum('obTiktokFollowers'),
      youtube_handle: handleOf('youtube', 'obYoutubeHandle'),
      youtube_followers: outboundParseNum('obYoutubeFollowers'),
      x_handle: handleOf('x', 'obXHandle'),
      x_followers: outboundParseNum('obXFollowers'),
      price_feed: outboundParseNum('obPriceFeed'),
      price_reels: outboundParseNum('obPriceReels'),
      price_story: outboundParseNum('obPriceStory'),
      price_tiktok: outboundParseNum('obPriceTiktok'),
      price_secondary: outboundParseNum('obPriceSecondary'),
      contact_channel: ($('obContactChannel')?.value || '').trim() || null,
      agency: ($('obAgency')?.value || '').trim() || null,
      nego_memo: ($('obNegoMemo')?.value || '').trim() || null,
      availability: $('obAvailability')?.value || 'available',
      rep_image_path: repImagePath || null,
      rep_posts: repPosts,
      content_consent: !!$('obContentConsent')?.checked,
    };

    await upsertOutboundInfluencer(row);

    // 5) 교체·제거로 버려진 기존 이미지는 best-effort 정리
    if (ctx.imagePath && ctx.imagePath !== repImagePath && typeof deleteOutboundImage === 'function') {
      deleteOutboundImage(ctx.imagePath);
    }

    toast(ctx.isNew ? '인플루언서를 등록했습니다' : '변경 사항을 저장했습니다');
  } catch (e) {
    toast('저장 실패: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || e)), 'error');
    if (saveBtn) saveBtn.disabled = false;
    return;
  }
  closeModal('outboundEditModal');
  _outboundEditCtx = null;
  await refreshPane('outbound');  // 재조회 + 목록 갱신 (quality.md)
}

// input 값 → 정수 or null (빈값=NULL, 0과 구분). 콤마·공백 제거, 음수·NaN 은 null
function outboundParseNum(elId) {
  const raw = ($(elId)?.value || '').replace(/[,\s]/g, '').trim();
  if (raw === '') return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.floor(n);
}

// 저장값(number|null) → input 문자열 (null=빈칸)
function outboundNumToInput(v) {
  return (v == null) ? '' : String(v);
}

// ── 삭제 ──
async function confirmDeleteOutbound() {
  const ctx = _outboundEditCtx;
  if (!ctx || ctx.isNew) return;
  const o = _outbound.find(x => x.id === ctx.id);
  const nm = o ? o.name_ko : '';
  // 편집 모달(#outboundEditModal, z-index 615)이 열린 채 삭제를 확인하므로 커스텀
  // showConfirm(confirmModal, z-index 610)을 쓰면 확인창이 뒤에 가려진다. 브랜드 삭제
  // (deleteBrandConfirm)와 동일하게 항상 최상단인 네이티브 confirm 사용.
  const ok = confirm(`'${nm}' 인플루언서를 명단에서 삭제하시겠습니까?\n삭제 후에는 복구할 수 없습니다.`);
  if (!ok) return;
  try {
    await deleteOutboundInfluencer(ctx.id);
    if (ctx.imagePath && typeof deleteOutboundImage === 'function') deleteOutboundImage(ctx.imagePath);
    toast('명단에서 삭제했습니다');
  } catch (e) {
    toast('삭제 실패: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || e)), 'error');
    return;
  }
  closeModal('outboundEditModal');
  _outboundEditCtx = null;
  await refreshPane('outbound');
}

// ════════════════════════════════════════════════════════════════════
// SECTION: OUTBOUND — 엑셀 내보내기 (현재 필터 결과)
// ════════════════════════════════════════════════════════════════════

async function exportOutboundExcel() {
  if (typeof _checkExportAllowed === 'function' && !_checkExportAllowed()) return;
  const rows = getFilteredOutbound();
  if (!rows.length) { toast('내보낼 명단이 없습니다', 'warn'); return; }
  if (typeof _markExportStart === 'function') _markExportStart();
  try {
    await loadExcelJS();
    const wb = new ExcelJS.Workbook();
    const ws = wb.addWorksheet('추천명단');
    ws.columns = [
      { header: '이름',      key: 'name',    width: 14 },
      { header: '계정',      key: 'account', width: 16 },
      { header: '계열',      key: 'series',  width: 10 },
      { header: '세분',      key: 'category',width: 10 },
      { header: '등급',      key: 'tier',    width: 16 },
      { header: 'IG핸들',    key: 'ig',      width: 16 },
      { header: 'IG팔로워',  key: 'igf',     width: 12 },
      { header: 'TikTok핸들',key: 'tt',      width: 16 },
      { header: 'TikTok팔로워',key: 'ttf',   width: 12 },
      { header: 'YouTube핸들',key: 'yt',     width: 16 },
      { header: 'YouTube구독',key: 'ytf',    width: 12 },
      { header: 'X핸들',     key: 'x',       width: 16 },
      { header: 'X팔로워',   key: 'xf',      width: 12 },
      { header: '피드(¥)',   key: 'pfeed',   width: 12 },
      { header: '릴스(¥)',   key: 'preels',  width: 12 },
      { header: '스토리(¥)', key: 'pstory',  width: 12 },
      { header: '틱톡(¥)',   key: 'ptiktok', width: 12 },
      { header: '2차(¥)',    key: 'psec',    width: 12 },
      { header: '가용상태',  key: 'avail',   width: 10 },
      { header: '컨택창구',  key: 'contact', width: 16 },
      { header: '소속사',    key: 'agency',  width: 14 },
      { header: '협상메모',  key: 'memo',    width: 28 },
    ];
    ws.getRow(1).font = { bold: true };

    const availKo = (s) => (OUTBOUND_AVAIL_META[s] || {}).ko || s || '';
    rows.forEach(o => {
      ws.addRow({
        name: o.name_ko || '', account: o.account_id || '',
        series: outboundSeriesLabel(o.series_code), category: outboundCategoryLabel(o.category_code),
        tier: outboundTierLabel(o.tier_code),
        ig: o.ig_handle || '', igf: o.ig_followers == null ? '' : o.ig_followers,
        tt: o.tiktok_handle || '', ttf: o.tiktok_followers == null ? '' : o.tiktok_followers,
        yt: o.youtube_handle || '', ytf: o.youtube_followers == null ? '' : o.youtube_followers,
        x: o.x_handle || '', xf: o.x_followers == null ? '' : o.x_followers,
        pfeed: o.price_feed == null ? '' : o.price_feed,
        preels: o.price_reels == null ? '' : o.price_reels,
        pstory: o.price_story == null ? '' : o.price_story,
        ptiktok: o.price_tiktok == null ? '' : o.price_tiktok,
        psec: o.price_secondary == null ? '' : o.price_secondary,
        avail: availKo(o.availability), contact: o.contact_channel || '',
        agency: o.agency || '', memo: o.nego_memo || '',
      });
    });

    const buf = await wb.xlsx.writeBuffer();
    const blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    const url = URL.createObjectURL(blob);
    const aEl = document.createElement('a');
    aEl.href = url;
    const ts = new Date();
    const ymd = ts.getFullYear() + String(ts.getMonth() + 1).padStart(2, '0') + String(ts.getDate()).padStart(2, '0');
    aEl.download = 'outbound-influencers-' + rows.length + '-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + rows.length + '명)');
  } catch (e) {
    toast('엑셀 생성 실패: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || e)), 'error');
  } finally {
    if (typeof _markExportEnd === 'function') _markExportEnd();
  }
}

// ════════════════════════════════════════════════════════════════════
// SECTION: OUTBOUND — 조건 추천 (2단계, 사양서 2026-07-08 §PR 2단계)
//   계열 필수 필터 → 등급·채널·예산 가점 정렬. DB 변경 없음(전건 조회 + 클라 계산).
//   성과 축(3단계)은 아직 없어 조건 적합도만으로 정렬한다(콜드스타트).
// ════════════════════════════════════════════════════════════════════

// 모집형식 → outbound_influencers 가격 컬럼 매핑 (예산 판정 기준)
const OUTBOUND_FORMAT_PRICE = {
  feed:   'price_feed',
  reels:  'price_reels',
  story:  'price_story',
  tiktok: 'price_tiktok',
};

// 가점 상수 (한 곳에 모아 매직넘버 제거)
const RECO_SCORE = {
  tierExact:   30,   // 등급 정확 일치
  tierAdjacent: 10,  // 등급 한 칸 차이
  channelHave: 20,   // 요구 채널 보유
  budgetIn:    20,   // 예산 내
  budgetOver: -20,   // 예산 초과
};

// 명단 / 조건 추천 탭 전환
function outboundTab(which) {
  const isList = (which !== 'recommend');
  $('outboundTabList')?.classList.toggle('is-active', isList);
  $('outboundTabReco')?.classList.toggle('is-active', !isList);
  const setShow = (id, show) => { const el = $(id); if (el) el.style.display = show ? '' : 'none'; };
  setShow('outboundListControls', isList);
  setShow('outboundListCard', isList);
  setShow('outboundRecoControls', !isList);
  setShow('outboundRecoCard', !isList);
  if (!isList) populateRecoFormOptions();
}

// 추천 조건 폼의 계열·등급 select 옵션 채움 (lookup 로드 후·탭 진입 시)
function populateRecoFormOptions() {
  const s = $('recoSeries');
  if (s) {
    const cur = s.value;
    s.innerHTML = '<option value="">선택하세요</option>'
      + _obSeries.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
    s.value = cur;
  }
  const t = $('recoTier');
  if (t) {
    const cur = t.value;
    t.innerHTML = '<option value="">전체</option>'
      + _obTier.map(r => `<option value="${esc(r.code)}">${esc(r.name_ko)}</option>`).join('');
    t.value = cur;
  }
}

// 등급 code → 순서값(sort_order). 인접 판정용. 미상이면 null.
function obTierOrder(code) {
  const r = _obTier.find(x => x.code === code);
  if (!r || r.sort_order == null) return null;
  return Number(r.sort_order);
}

// available=상위(0), 그 외(조율중·불가)=하위(1). is_active=false 는 후보에서 이미 제외.
function outboundRecoAvailGroup(o) {
  return (o.availability === 'available') ? 0 : 1;
}

// 한 인플루언서의 조건 적합도 점수·근거. 계열은 호출 전 필수 필터돼 여기선 항상 「계열 일치」.
function outboundRecoScore(o, cond) {
  const reasons = [{ t: '계열 일치', cls: 'ok' }];
  let score = 0;

  // 등급: 정확 일치 +30 / 한 칸 차이 +10 (sort_order 기준)
  if (cond.tier) {
    if (o.tier_code === cond.tier) {
      score += RECO_SCORE.tierExact;
      reasons.push({ t: '등급 일치', cls: 'ok' });
    } else {
      const oOrd = obTierOrder(o.tier_code), cOrd = obTierOrder(cond.tier);
      if (oOrd != null && cOrd != null && Math.abs(oOrd - cOrd) === 1) {
        score += RECO_SCORE.tierAdjacent;
        reasons.push({ t: '등급 인접', cls: 'soft' });
      }
    }
  }

  // 채널: 요구 채널 핸들 보유 +20 (팔로워 규모는 동점 정렬에서만 반영)
  if (cond.channel) {
    const ch = OUTBOUND_CHANNELS.find(c => c.key === cond.channel);
    if (ch && o[ch.handleCol]) {
      score += RECO_SCORE.channelHave;
      reasons.push({ t: ch.label + ' 보유', cls: 'ok' });
    }
  }

  // 예산: 모집형식 선택 + 예산 입력 시만. 미상은 0(중립). 초과는 감점(제외 아님).
  if (cond.format && cond.budget != null) {
    const price = o[OUTBOUND_FORMAT_PRICE[cond.format]];
    if (price == null) {
      reasons.push({ t: '가격 미상', cls: 'muted' });
    } else if (Number(price) <= cond.budget) {
      score += RECO_SCORE.budgetIn;
      reasons.push({ t: '예산 내', cls: 'ok' });
    } else {
      score += RECO_SCORE.budgetOver;
      reasons.push({ t: '예산 초과', cls: 'over' });
    }
  }

  return { score, reasons };
}

// 정렬: ①가용 그룹(available 먼저) ②점수 내림 ③주채널 팔로워 내림 ④등록 최신순
function compareOutboundReco(a, b) {
  const ga = outboundRecoAvailGroup(a.o), gb = outboundRecoAvailGroup(b.o);
  if (ga !== gb) return ga - gb;
  if (b.score !== a.score) return b.score - a.score;
  const pa = outboundPrimaryChannel(a.o), pb = outboundPrimaryChannel(b.o);
  const fva = pa ? pa.fv : -1, fvb = pb ? pb.fv : -1;
  if (fvb !== fva) return fvb - fva;
  return String(b.o.created_at || '').localeCompare(String(a.o.created_at || ''));
}

// 추천 실행 — 계열 필수 필터 + is_active + 점수 정렬 → 결과 렌더
function runOutboundRecommend() {
  const series = $('recoSeries')?.value || '';
  if (!series) { toast('계열을 선택하세요', 'warn'); return; }
  const cond = {
    series,
    format:  ($('recoFormat')?.value || ''),
    tier:    ($('recoTier')?.value || ''),
    channel: ($('recoChannel')?.value || ''),
    budget:  outboundParseNum('recoBudget'),
    headcount: outboundParseNum('recoHeadcount'),
    purpose: ($('recoPurpose')?.value || ''),   // 2단계는 기록만(정렬 미반영)
  };
  // 계열 필수 필터 + 비활성(is_active=false) 제외
  const cands = _outbound.filter(o => o.is_active !== false && o.series_code === series);
  const scored = cands.map(o => {
    const s = outboundRecoScore(o, cond);
    return { o, score: s.score, reasons: s.reasons };
  });
  scored.sort(compareOutboundReco);
  renderOutboundReco(scored, cond);
}

// 결과 렌더 — 전체 정렬 노출 + 요청 인원 N번째 뒤 구분선
function renderOutboundReco(scored, cond) {
  const tbody = $('recoTableBody');
  if (!tbody) return;
  const cnt = $('recoResultCount');
  const N = cond.headcount;
  if (cnt) cnt.textContent = N ? `요청 ${N}명 / 매칭 ${scored.length}명` : `매칭 ${scored.length}명`;

  if (!scored.length) {
    tbody.innerHTML = '<tr><td colspan="12" style="text-align:center;color:var(--muted);padding:30px">해당 계열에 진행 가능한 인플루언서가 없습니다.</td></tr>';
    return;
  }

  const priceCol = cond.format ? OUTBOUND_FORMAT_PRICE[cond.format] : null;
  let html = '';
  scored.forEach((row, i) => {
    if (N && i === N) {
      html += `<tr class="reco-divider"><td colspan="12">요청 인원 ${N}명 경계 — 아래는 차선 후보</td></tr>`;
    }
    html += renderOutboundRecoRow(row, i + 1, priceCol);
  });
  tbody.innerHTML = html;
}

function renderOutboundRecoRow(row, rank, priceCol) {
  const o = row.o;
  const id = esc(o.id);
  const nameCell = `<div style="font-weight:600;color:var(--pink);cursor:pointer" onclick="openOutboundEditModal('${id}')">${esc(o.name_ko || '—')}</div>`;

  // 선택형식 단가
  let priceCell = '<span style="color:var(--muted);font-size:11px">—</span>';
  if (priceCol) {
    const v = o[priceCol];
    priceCell = (v == null)
      ? '<span style="color:var(--muted);font-size:11px">미상</span>'
      : `<span style="font-size:12px">¥${Number(v).toLocaleString()}</span>`;
  }

  const badges = row.reasons.map(r =>
    `<span class="reco-badge reco-badge-${esc(r.cls)}">${esc(r.t)}</span>`).join(' ');

  return `<tr>
    <td style="text-align:center;font-weight:700;color:var(--muted)">${rank}</td>
    <td style="text-align:center;font-weight:700">${row.score}</td>
    <td>${nameCell}</td>
    <td style="font-size:12px">${esc(outboundSeriesLabel(o.series_code))}</td>
    <td style="font-size:12px">${esc(outboundTierLabel(o.tier_code))}</td>
    ${outboundChannelCells(o)}
    <td>${priceCell}</td>
    <td>${outboundAvailBadge(o.availability)}</td>
    <td style="white-space:normal">${badges}</td>
  </tr>`;
}
