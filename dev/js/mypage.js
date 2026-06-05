// ══════════════════════════════════════
// MY PAGE
// ══════════════════════════════════════

// 프로필 미등록 항목 계산 — 마이페이지 폼 필수 경고 + 햄버거 메뉴 未登録 배지 공용.
// 순수 함수로 분리해 renderNavMenu(햄버거 열 때)에서도 동일 기준으로 호출한다.
function computeProfileBadges(profile) {
  const p = profile || {};
  // 이름은 한자·가나 둘 다 채워져야 등록으로 간주 ("-"는 미등록)
  const nameKanji = ((p.name_kanji || p.name || '') + '').trim();
  const nameKana = ((p.name_kana || '') + '').trim();
  const hasName = !!(nameKanji && nameKanji !== '-' && nameKana && nameKana !== '-');
  const hasSns = !!(p.ig || p.x || p.tiktok || p.youtube);
  const hasAddress = !!(p.zip && p.prefecture && p.city && p.phone);
  const hasPaypal = !!p.paypal_email;
  return {hasName, hasSns, hasAddress, hasPaypal};
}

async function loadMyPage() {
  if (!currentUser) { navigate('login'); return; }
  // 진입 시마다 인플루언서 프로필 새로고침 — 관리자 화면이나 다른 탭에서 변경된
  // 이름·SNS·배송지·인증/위반 상태 등이 stale 상태로 남지 않도록.
  if (db && !currentUser._isAdmin) {
    try {
      const {data: freshProfile} = await db.from('influencers').select('*').eq('id', currentUser.id).maybeSingle();
      if (freshProfile) currentUserProfile = freshProfile;
    } catch(e) { /* 네트워크 실패 시 stale 그대로 사용 */ }
  }
  const p = currentUserProfile || {};
  // 계정정보(아바타·이름·핸들·이메일)와 메뉴 목차는 햄버거 메뉴(renderNavMenu)로 이전됨.
  // 마이페이지 랜딩 화면(#mypage-list)이 제거되어 여기서 직접 채우지 않는다.
  if (typeof refreshNotifBadge === 'function') refreshNotifBadge();
  // 햄버거 메뉴의 계정 카드·未登録 배지를 최신 프로필로 갱신
  if (typeof renderNavMenu === 'function') renderNavMenu();

  // 메일 수신 설정 토글 — 발송 로직(get_promo_digest_targets)이 marketing_opt_in=true 만 대상이므로
  // true 일 때만 ON 표시 (NULL/false 는 OFF)
  const mktToggle = $('emailMarketingToggle');
  if (mktToggle) mktToggle.checked = (p.marketing_opt_in === true);

  const setVal = (id, val) => { const el = $(id); if(el) el.value = val||''; };
  setVal('profileNameKanji', p.name_kanji||p.name);
  setVal('profileNameKana', p.name_kana);
  setVal('profileCategory', p.category);
  setVal('profileLine', p.line_id);
  setVal('profileBio', p.bio);
  setVal('profileIg', p.ig);
  setVal('profileIgFollowers', p.ig_followers||p.followers);
  setVal('profileX', p.x);
  setVal('profileXFollowers', p.x_followers);
  setVal('profileTiktok', p.tiktok);
  setVal('profileTiktokFollowers', p.tiktok_followers);
  setVal('profileYoutube', p.youtube);
  setVal('profileYoutubeFollowers', p.youtube_followers);

  // SNS 입력란: blur 시 핸들 자동 추출 (URL 붙여넣기 → 핸들로 정리)
  const bindSnsExtract = (id, channel) => {
    const el = $(id);
    if (!el || el.dataset.snsExtractBound === '1') return;
    el.dataset.snsExtractBound = '1';
    el.addEventListener('blur', () => {
      const next = extractSnsHandle(channel, el.value);
      if (next !== el.value) el.value = next;
    });
  };
  bindSnsExtract('profileIg', 'instagram');
  bindSnsExtract('profileX', 'x');
  bindSnsExtract('profileTiktok', 'tiktok');
  bindSnsExtract('profileYoutube', 'youtube');
  if(p.primary_sns && $('profilePrimarySns')) $('profilePrimarySns').value = p.primary_sns;
  setVal('profileZip', p.zip);
  if(p.prefecture && $('profilePrefecture')) $('profilePrefecture').value = p.prefecture;
  setVal('profileCity', p.city);
  setVal('profileBuilding', p.building);
  setVal('profilePhone', p.phone);
  setVal('paypalEmail', p.paypal_email);
  setVal('paypalEmailConfirm', p.paypal_email);

  // 미등록 여부 계산 — 햄버거 메뉴 未登録 배지(renderNavMenu)와 아래 필수 경고 공용
  const {hasSns, hasPaypal} = computeProfileBadges(p);

  // 필수 필드 경고 표시
  const reqMsg = t('profile.requiredHint');
  const snsFields = [{id:'profileIg',val:p.ig},{id:'profileX',val:p.x},{id:'profileTiktok',val:p.tiktok},{id:'profileYoutube',val:p.youtube}];
  const addrFields = [{id:'profileZip',val:p.zip},{id:'profilePrefecture',val:p.prefecture},{id:'profileCity',val:p.city},{id:'profilePhone',val:p.phone}];
  // SNS: 하나도 없으면 전부 경고
  if (!hasSns) snsFields.forEach(f => markRequired(f.id, reqMsg));
  else snsFields.forEach(f => clearRequired(f.id));
  // 배송지: 개별 체크
  addrFields.forEach(f => f.val ? clearRequired(f.id) : markRequired(f.id, reqMsg));
  // PayPal: 개별 체크
  if (hasPaypal) clearRequired('paypalEmail'); else markRequired('paypalEmail', reqMsg);

  loadMyApplications();
}

let _myApps = [];
// 응모이력 상태 필터 기본값 — 進行中(심사중+당첨) 묶음. 진입 시 진행 중인 응모만 노출
let _myAppsTab = 'active2';
// 드롭다운 선택값 → 매칭할 status 배열. active2=진행중 묶음, all=전체 4종
const APP_STATUS_GROUPS = {
  active2:   ['pending', 'approved'],
  all:       ['pending', 'approved', 'rejected', 'cancelled'],
  pending:   ['pending'],
  approved:  ['approved'],
  rejected:  ['rejected'],
  cancelled: ['cancelled'],
};

async function loadMyApplications() {
  if (!currentUser) return;
  if (db) {
    const {data} = await db.from('applications').select('*').eq('user_id', currentUser.id).order('created_at', {ascending:false});
    _myApps = data || [];
  }
  // 캠페인 데이터도 진입 시마다 새로고침 — 응모이력 행에 노출되는 캠페인 상태/제목 stale 방지
  allCampaigns = await fetchCampaigns();
  renderMyApplyTabs();
  renderMyApplyList();
}

// 상태 필터 드롭다운(제목 우측) 렌더 — 각 항목에 건수 병기. 進行中(기본) 우선 노출
function renderMyApplyTabs() {
  const sel = $('myApplyStatusSelect');
  if (!sel) return;
  const counts = {pending: 0, approved: 0, rejected: 0, cancelled: 0};
  _myApps.forEach(a => { if (counts[a.status] !== undefined) counts[a.status]++; });
  const opts = [
    {k: 'active2',   label: t('appHistory.inProgress'), n: counts.pending + counts.approved},
    {k: 'all',       label: t('appHistory.all'),        n: _myApps.length},
    {k: 'pending',   label: t('appHistory.pending'),    n: counts.pending},
    {k: 'approved',  label: t('appHistory.approved'),   n: counts.approved},
    {k: 'rejected',  label: t('appHistory.rejected'),   n: counts.rejected},
    {k: 'cancelled', label: t('appHistory.cancelled'),  n: counts.cancelled},
  ];
  sel.innerHTML = opts.map(o =>
    `<option value="${o.k}"${_myAppsTab===o.k?' selected':''}>${esc(o.label)} (${o.n})</option>`
  ).join('');
}

let _myDelivsByApp = {};
let _myMsgUnreadByApp = {};  // 응모건별 인플루언서 미읽음 메시지 수 (배지용)

async function renderMyApplyList() {
  const container = $('myApplicationsList');
  const statuses = APP_STATUS_GROUPS[_myAppsTab] || APP_STATUS_GROUPS.all;
  let filtered = _myApps.filter(a => statuses.includes(a.status));
  // Phase 2: 비교 캐시는 매 렌더마다 초기화 — 필터 변경/언어 전환 시 stale 데이터 방지
  if (typeof _cautionCompareCache === 'object' && _cautionCompareCache) {
    Object.keys(_cautionCompareCache).forEach(k => delete _cautionCompareCache[k]);
  }

  // Stage 6: 결과물 상태 배지용 — 본인 결과물 전체를 application별 그룹핑
  if (currentUser) {
    try {
      const delivs = await fetchDeliverablesForUser({user_id: currentUser.id});
      _myDelivsByApp = {};
      delivs.forEach(d => { (_myDelivsByApp[d.application_id] ||= []).push(d); });
    } catch(e) { _myDelivsByApp = {}; }
    // 메시지 미읽음 배지 — application_message_summary 뷰 (security_invoker, 본인 행만)
    try {
      const threads = await fetchInfluencerUnreadMessageThreads();
      _myMsgUnreadByApp = {};
      threads.forEach(th => { _myMsgUnreadByApp[th.application_id] = th.unread_for_influencer; });
    } catch(e) { _myMsgUnreadByApp = {}; }
  }

  // 캠페인 상태 필터
  const campStatusFilter = $('myApplyCampStatus')?.value || '';
  if (campStatusFilter) {
    filtered = filtered.filter(a => {
      const camp = allCampaigns.find(c=>c.id===a.campaign_id);
      return camp?.status === campStatusFilter;
    });
  }

  // 채널 필터 (공용 populateMyApplyChannelOptions에서 드롭다운 채움)
  populateMyApplyChannelOptions();
  const channelFilter = $('myApplyChannel')?.value || '';
  if (channelFilter) {
    filtered = filtered.filter(a => {
      const camp = allCampaigns.find(c=>c.id===a.campaign_id);
      if (!camp?.channel) return false;
      return camp.channel.split(',').map(s=>s.trim()).includes(channelFilter);
    });
  }

  // 정렬
  const sortVal = $('myApplySort')?.value || 'newest';
  filtered.sort((a,b) => sortVal === 'oldest'
    ? new Date(a.created_at) - new Date(b.created_at)
    : new Date(b.created_at) - new Date(a.created_at));

  if (!filtered.length) {
    // 빈 상태 3분기:
    //   all      = 응모 자체 없음 → 홈으로 유도
    //   active2  = 진행중인 응모만 없음(과거 응모는 있을 수 있음) → 「전체 보기」로 유도
    //   그 외 단일 상태 = 해당 상태 응모 없음
    let emptyText, emptyExtra = '';
    if (_myAppsTab === 'all') {
      emptyText = t('appHistory.emptyAll');
      emptyExtra = `<div class="empty-sub">${t('appHistory.emptySub')}</div><button class="btn btn-primary" style="margin-top:16px" onclick="navigate('home')">${t('appHistory.emptyBtn')}</button>`;
    } else if (_myAppsTab === 'active2') {
      emptyText = t('appHistory.emptyInProgress');
      emptyExtra = `<button class="btn btn-primary" style="margin-top:16px" onclick="_myAppsTab='all';renderMyApplyTabs();renderMyApplyList()">${t('appHistory.showAll')}</button>`;
    } else {
      emptyText = t('appHistory.emptyFiltered');
    }
    container.innerHTML = `<div class="empty-state"><div class="empty-icon"><span class="material-icons-round notranslate" translate="no" style="font-size:48px;color:var(--muted)">assignment</span></div><div class="empty-text">${emptyText}</div>${emptyExtra}</div>`;
    return;
  }
  container.innerHTML = filtered.map(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id) || {};
    const imgs = [camp.img1,camp.img2,camp.image_url].filter(Boolean);
    const thumb = imgs[0]
      ? `<img src="${esc(imgThumb(imgs[0],120))}" data-orig="${esc(imgs[0])}" loading="lazy" decoding="async" alt="" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}">`
      : `<span class="material-icons-round notranslate" translate="no" style="font-size:22px;color:var(--muted)">inventory_2</span>`;
    // 카드 클릭 동선:
    //   - cancelled: 사유 확인 모달 (openCancelDetailModal)
    //   - approved: 활동관리 페이지 (단, cancelled 였다가 재진입이라면 사양 §4-8에 따라 차단)
    //   - 그 외: 캠페인 상세
    const clickAction = a.status==='cancelled'
      ? `onclick="openCancelDetailModal('${a.id}')"`
      : (a.status==='approved'
          ? `onclick="openActivityPage('${a.id}','${a.campaign_id}','mypage')"`
          : `onclick="_detailFrom='mypage';openCampaign('${a.campaign_id}')"`);
    // ⋮ 메뉴: pending/approved 카드에 표시.
    //   클릭 시 액션 모달(applyActionModal) — 「결과물 제출」/「응모 취소」 선택.
    //   결과물 제출 옵션: status=approved 일 때만 활성 (pending 은 안내문만).
    //   응모 취소 옵션: 결과물 1건이라도 approved 면 비활성 (모달 내부에서 비활성 처리).
    //   cancelled/rejected 카드는 메뉴 자체 비표시.
    //   모바일 터치 영역 보강: 버튼 최소 44×44px (애플 HIG / 머티리얼 권장).
    let menuHtml = '';
    if (a.status === 'pending' || a.status === 'approved') {
      menuHtml = `<button type="button" class="apply-card-menu-btn" onclick="event.stopPropagation();openApplyActionModal('${a.id}')" aria-label="${esc(t('appHistory.action.title'))}" style="min-width:44px;min-height:44px;display:inline-flex;align-items:center;justify-content:center;border:none;background:transparent;border-radius:22px;cursor:pointer;color:var(--muted)"><span class="material-icons-round notranslate" translate="no" style="font-size:24px">more_vert</span></button>`;
    }
    // cancelled 행: 취소일 표시
    const cancelledLine = a.status === 'cancelled' && a.cancelled_at
      ? `<div class="apply-item-cancelled-at" style="font-size:11px;color:var(--muted);margin-top:2px">${esc(t('appHistory.cancelDetail.datetime'))}: ${formatDate(a.cancelled_at)}</div>`
      : '';
    // Stage 6: 결과물 상태 배지 — 당첨(approved) 신청 행 카드 하단에 「{종류} {상태}」 라벨로 노출.
    // 단순 「승인」만으론 영수증 승인/결과물 승인 구분이 안 되므로 종류 prefix를 붙임.
    // monitor 캠페인은 영수증·리뷰 캡쳐 두 단계가 별도 진행 → 라벨도 두 줄로 표시.
    let delivItemsHtml = '';
    if (a.status === 'approved') {
      const ds = (_myDelivsByApp[a.id] || []);
      // kind별로 가장 최신 1건만 추출 (재제출 시 더 최근 행 우선)
      const byKind = {};
      ds.forEach(d => {
        const cur = byKind[d.kind];
        if (!cur || (d.submitted_at || '') > (cur.submitted_at || '')) byKind[d.kind] = d;
      });
      const KIND_TO_KEY = {receipt: 'receipt', review_image: 'reviewImage', post: 'post'};
      const order = ['receipt', 'review_image', 'post'];
      const items = [];
      for (const kind of order) {
        const d = byKind[kind];
        if (!d) continue;
        const kindLabel = t('delivKind.' + (KIND_TO_KEY[kind] || kind));
        const statusLabel = t('delivStatus.' + d.status);
        let bg = '#FFF4E4', color = '#B8741A';
        if (d.status === 'approved') { bg = '#E4F5E8'; color = '#2D7A3E'; }
        else if (d.status === 'rejected') { bg = '#FFE4E4'; color = '#C33'; }
        items.push(`<span style="display:inline-block;background:${bg};color:${color};font-size:11px;font-weight:700;padding:2px 8px;border-radius:3px">${esc(kindLabel)} ${esc(statusLabel)}</span>`);
      }
      delivItemsHtml = items.join('');
    }
    // 응모 상태 배지(당첨/심사중 등) + 결과물 상태 배지를 카드 본문 맨 아래 가로 한 줄로 모음
    const badgeRow = `<div class="apply-item-badges" style="display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:6px">${getStatusBadge(a.status)}${delivItemsHtml}</div>`;
    const cautionLine = a.caution_agreed_at
      ? `<div class="apply-item-caution" style="font-size:11px;color:var(--green);margin-top:2px;display:inline-flex;align-items:center;gap:3px;flex-wrap:wrap"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>${t('appHistory.cautionAgreed')} ${formatDate(a.caution_agreed_at)}${cautionCompareButton(a, camp)}</div>`
      : '';
    // 메시지 버튼 + 미읽음 배지 (모든 응모 카드 — 응모건 단위 운영팀 문의)
    const msgUnread = _myMsgUnreadByApp[a.id] || 0;
    const msgBtn = `<button type="button" class="apply-msg-btn" onclick="event.stopPropagation();openMessagesPage('${a.id}','mypage')" aria-label="${esc(t('messaging.btnLabel'))}"><span class="material-icons-round notranslate" translate="no" style="font-size:22px">chat_bubble_outline</span>${msgUnread>0?`<span class="apply-msg-badge">${msgUnread>9?'9+':msgUnread}</span>`:''}</button>`;
    return `<div class="apply-item" style="cursor:pointer;position:relative" ${clickAction}>
      <div class="apply-thumb">${thumb}</div>
      <div class="apply-item-info">
        ${camp.recruit_type ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:2px">${esc(getRecruitTypeLabelJa(camp.recruit_type))}</div>` : ''}
        <div class="apply-item-name" style="display:flex;align-items:center;gap:6px"><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1">${esc(camp.title||a.campaign_id)}</span></div>
        <div class="apply-item-meta">${esc(camp.brand||'')} · ${t('appHistory.applyDate')} ${formatDate(a.created_at)}</div>
        ${cautionLine}
        ${cancelledLine}
        ${badgeRow}
      </div>
      <div class="apply-item-status" style="display:flex;flex-direction:column;align-items:flex-end;gap:4px"><div class="apply-item-actions" style="display:flex;align-items:center;gap:2px">${msgBtn}${menuHtml}</div></div>
    </div>`;
  }).join('');
}

// 메시지 모달에서 읽음 처리/닫은 뒤 응모이력 미읽음 배지 갱신
async function refreshMyMsgUnread(opts) {
  if (typeof currentUser === 'undefined' || !currentUser) return;
  try {
    const threads = await fetchInfluencerUnreadMessageThreads();
    _myMsgUnreadByApp = {};
    threads.forEach(th => { _myMsgUnreadByApp[th.application_id] = th.unread_for_influencer; });
  } catch(e) { /* 무시 */ }
  // GNB 「メッセージ」 미읽음 배지 갱신 (햄버거 메뉴)
  if (typeof updateNavMsgBadge === 'function') updateNavMsgBadge();
  // 폴링·화면복귀 호출(skipRerender)은 햄버거 배지만 갱신 — 응모이력 재렌더로 인한
  // 30초마다 깜빡임·스크롤 튐 방지. 사용자가 응모이력 진입/메시지 모달 열 때만 카드 배지 재렌더.
  if (opts && opts.skipRerender) return;
  if ($('myApplicationsList') && typeof renderMyApplyList === 'function') {
    try { await renderMyApplyList(); } catch(e) { /* 무시 */ }
  }
}

// ── Phase 2: 주의사항 비교 (응모이력 셀 토글) ──
//   동의 시점 스냅샷(applications.caution_snapshot) vs 현재 캠페인 문구(campaigns.caution_items) 비교
//   동일하면 토글 자체 노출 X (변경 없을 때 노이즈 방지)
//   v1 스냅샷(lookup_labels 기반)은 비교 대상 아님 — 자동 숨김
const _cautionCompareCache = {};

function _normCautionItems(arr) {
  if (!Array.isArray(arr) || !arr.length) return [];
  return arr.map(it => ({
    html_ko: (it && it.html_ko) || '',
    html_ja: (it && it.html_ja) || '',
  }));
}

function cautionCompareButton(app, camp) {
  if (!app || !camp) return '';
  const snap = app.caution_snapshot;
  // v2 스냅샷만 비교 가능 (v1 lookup_labels 형태는 캠페인 items 와 구조가 달라 비교 의미 없음)
  if (!snap || snap.version !== 2 || !Array.isArray(snap.items)) return '';
  const snapItems = _normCautionItems(snap.items);
  const currItems = _normCautionItems(camp.caution_items);
  if (JSON.stringify(snapItems) === JSON.stringify(currItems)) return '';  // 동일 → 토글 미노출
  _cautionCompareCache[app.id] = { snap: snapItems, curr: currItems, agreedAt: app.caution_agreed_at };
  // event.stopPropagation 으로 카드 onclick 차단
  return ` <button type="button" onclick="event.stopPropagation();openCautionCompareModal('${esc(app.id)}')" style="background:#FFEFEF;color:#B3261E;border:1px solid #f5b1b1;border-radius:10px;font-size:10px;font-weight:600;padding:2px 8px;cursor:pointer;display:inline-flex;align-items:center;gap:3px"><span class="material-icons-round notranslate" translate="no" style="font-size:12px">compare_arrows</span>${t('mypage.caution.compareToggle')}</button>`;
}

function openCautionCompareModal(appId) {
  const cached = _cautionCompareCache[appId];
  const body = $('cautionCompareModalBody');
  if (!body) return;
  const safe = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml : (h => esc(String(h||'')));
  if (!cached) {
    body.innerHTML = `<div style="padding:24px 0;color:var(--muted);font-size:13px;text-align:center">${t('mypage.caution.empty')}</div>`;
    openModal('cautionCompareModal');
    return;
  }
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const pickHtml = (it) => lang === 'ko' ? (it.html_ko || it.html_ja) : (it.html_ja || it.html_ko);
  const agreedLabel = cached.agreedAt ? formatDate(cached.agreedAt) : '';
  const renderList = (arr) => {
    if (!Array.isArray(arr) || !arr.length) return `<li style="color:var(--muted)">—</li>`;
    return arr.map(it => `<li>${safe(pickHtml(it))}</li>`).join('');
  };
  body.innerHTML = `
    <div style="display:flex;flex-direction:column;gap:14px">
      <div style="border:1px solid #d1e7d3;border-radius:10px;background:#f3faf4;padding:12px 14px">
        <div style="font-size:11px;font-weight:700;color:#1f7a1f;margin-bottom:6px;display:flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>${t('mypage.caution.agreedAt')} ${esc(agreedLabel)}</div>
        <ul style="margin:0;padding-left:18px;font-size:13px;line-height:1.7;color:var(--ink);display:flex;flex-direction:column;gap:4px">${renderList(cached.snap)}</ul>
      </div>
      <div style="border:1px solid #f5b1b1;border-radius:10px;background:#fff5f5;padding:12px 14px">
        <div style="font-size:11px;font-weight:700;color:#B3261E;margin-bottom:6px;display:flex;align-items:center;gap:4px"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">campaign</span>${t('mypage.caution.currentNow')}</div>
        <ul style="margin:0;padding-left:18px;font-size:13px;line-height:1.7;color:var(--ink);display:flex;flex-direction:column;gap:4px">${renderList(cached.curr)}</ul>
      </div>
      <div style="font-size:11px;color:var(--muted);line-height:1.6;background:var(--surface-container-low);border-radius:8px;padding:10px 12px">${t('mypage.caution.diffNote')}</div>
    </div>
  `;
  openModal('cautionCompareModal');
}

async function saveProfile() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value||'';
  const zip = getVal('profileZip');
  const pref = getVal('profilePrefecture');
  const city = getVal('profileCity');
  const building = getVal('profileBuilding');
  const address = zip ? `〒${zip} ${pref}${city}${building?' '+building:''}` : '';
  const updated = {
    name: getVal('profileNameKanji'),
    name_kanji: getVal('profileNameKanji'),
    name_kana: getVal('profileNameKana'),
    category: getVal('profileCategory'),
    line_id: getVal('profileLine'),
    bio: getVal('profileBio'),
    ig: getVal('profileIg'), ig_followers: parseInt(getVal('profileIgFollowers'))||0,
    x: getVal('profileX'), x_followers: parseInt(getVal('profileXFollowers'))||0,
    tiktok: getVal('profileTiktok'), tiktok_followers: parseInt(getVal('profileTiktokFollowers'))||0,
    youtube: getVal('profileYoutube'), youtube_followers: parseInt(getVal('profileYoutubeFollowers'))||0,
    primary_sns: getVal('profilePrimarySns'),
    zip, prefecture: pref, city, building, address,
    phone: getVal('profilePhone'),
    followers: (parseInt(getVal('profileIgFollowers'))||0)+(parseInt(getVal('profileXFollowers'))||0)+(parseInt(getVal('profileTiktokFollowers'))||0)+(parseInt(getVal('profileYoutubeFollowers'))||0)
  };
  try {
    await updateInfluencer(currentUser.id, updated);
    currentUserProfile = Object.assign(currentUserProfile || {}, updated);
    toast(t('profile.saved'),'success'); loadMyPage();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}

async function savePaypalInfo() {
  if (!currentUser) return;
  const getVal = id => $(id)?.value?.trim()||'';
  const email = getVal('paypalEmail');
  const confirm = getVal('paypalEmailConfirm');
  const err = $('paypalError');
  const showErr = msg => { if (err) { err.textContent = msg; err.style.display = 'block'; } };
  if (err) err.style.display = 'none';
  const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!email) return showErr(t('profile.paypalRequired'));
  if (!emailRe.test(email)) return showErr(t('profile.paypalInvalid'));
  if (email !== confirm) return showErr(t('profile.paypalMismatch'));
  try {
    await updateInfluencer(currentUser.id, { paypal_email: email });
    currentUserProfile = Object.assign(currentUserProfile || {}, { paypal_email: email });
    toast(t('profile.paypalSaved'),'success');
    loadMyPage();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}

async function changePassword() {
  const cur = $('currentPw')?.value;
  const nw = $('newPw')?.value;
  const nw2 = $('newPw2')?.value;
  const err = $('pwChangeError');
  err.style.display='none';
  if (!cur || !nw) { err.textContent=t('profile.fillAll'); err.style.display='block'; return; }
  if (cur === nw) { err.textContent = (typeof t==='function') ? t('auth.pwSameAsCurrent', '現在のパスワードと同じパスワードは使用できません。') : '現在のパスワードと同じパスワードは使用できません。'; err.style.display='block'; return; }
  const pwErr = (typeof validatePasswordPolicy === 'function') ? validatePasswordPolicy(nw) : null;
  if (pwErr) { err.textContent = pwErr; err.style.display='block'; return; }
  if (nw !== nw2) { err.textContent = (typeof t==='function') ? t('auth.pwMismatch', 'パスワードが一致しません。') : 'パスワードが一致しません。'; err.style.display='block'; return; }
  if (!db) { err.textContent=t('authError.serverError'); err.style.display='block'; return; }
  const {error} = await db.auth.updateUser({password: nw});
  if (error) { err.textContent=error.message; err.style.display='block'; return; }
  toast(t('profile.pwChanged'),'success');
  $('currentPw').value=''; $('newPw').value=''; $('newPw2').value='';
}

// 메일 수신 설정 토글 (ON=재구독 / OFF=수신거부)
// ON 은 동의 시각 기록 의무로 resubscribe_marketing() RPC, OFF 는 동의 철회라 직접 UPDATE.
async function toggleMarketingEmail(checked) {
  if (!currentUser) { navigate('login'); return; }
  const toggle = $('emailMarketingToggle');
  try {
    const res = checked ? await resubscribeMarketing() : await updateMarketingOptIn(false);
    if (!res || !res.ok) throw new Error(res?.error || 'unknown');
    currentUserProfile = Object.assign(currentUserProfile || {}, {
      marketing_opt_in: checked,
      marketing_unsubscribed_at: checked ? null : new Date().toISOString()
    });
    toast(t(checked ? 'mypage.emailSettings.savedOn' : 'mypage.emailSettings.savedOff'), 'success');
  } catch(e) {
    // 실패 시 토글 원상복구
    if (toggle) toggle.checked = !checked;
    toast(friendlyErrorJa(e), 'error');
  }
}

function openMypageSub(sub, pushHistory) {
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  const target = $('mypage-sub-' + sub);
  if (target) target.classList.add('active');
  // 응모이력 진입(햄버거·알림·새로고침 등 모든 경로) 시 상태 드롭다운을 현재 _myAppsTab 기준으로
  // 즉시 채워 빈 박스/stale 선택 방지. 데이터 로드(loadMyApplications) 전이라도 항목은 보이고,
  // 로드 완료 후 renderMyApplyTabs 재호출로 건수까지 갱신된다.
  if (sub === 'applications' && typeof renderMyApplyTabs === 'function') renderMyApplyTabs();
  // 사용자 클릭 등 새 진입은 push (기본), popstate·새로고침 init·내부 폴백 등은 false 전달 → entry 누적 방지.
  if (pushHistory !== false) {
    history.pushState({page:'mypage', sub}, '', '#mypage-' + sub);
  }
}

// 마이페이지 랜딩(목차) 화면이 제거되어, 서브 화면을 닫으면 응모이력을 기본 화면으로 보여준다.
// 폼 화면의 뒤로가기 버튼·navigate('mypage')·popstate(#mypage) 진입 시 빈 화면 방지.
function closeMypageSub() {
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  const def = $('mypage-sub-applications');
  if (def) def.classList.add('active');
  history.replaceState({page:'mypage', sub:'applications'}, '', '#mypage-applications');
}

// 언어 토글 버튼 상태 업데이트
function updateLangToggleUI() {
  const current = typeof getLang === 'function' ? getLang() : 'ja';
  document.querySelectorAll('.lang-toggle .lang-btn').forEach(btn => {
    btn.classList.toggle('on', btn.getAttribute('data-lang') === current);
  });
}

// 회원 탈퇴 핸들러 (i18n 대응)
function handleWithdraw() {
  const confirmMsg = typeof t === 'function' ? t('mypage.withdrawConfirm') : '本当に退会しますか？';
  const toastMsg = typeof t === 'function' ? t('mypage.withdrawToast') : '退会申請を受け付けました。運営にLINEでご連絡ください。';
  if (confirm(confirmMsg)) toast(toastMsg);
}

// 초기 + langchange 이벤트에서 토글 상태 갱신
document.addEventListener('DOMContentLoaded', updateLangToggleUI);
window.addEventListener('langchange', updateLangToggleUI);

// 언어 전환 시 응모이력 상태 드롭다운 라벨(進行中 등) 갱신 — 동적 렌더라 applyI18n 미적용 대상
window.addEventListener('langchange', () => {
  if ($('myApplyStatusSelect') && typeof renderMyApplyTabs === 'function') renderMyApplyTabs();
});

// 응모이력: 내가 응모한 캠페인에 등장한 모든 채널을 드롭다운에 채움
function populateMyApplyChannelOptions() {
  const sel = $('myApplyChannel');
  if (!sel) return;
  const prev = sel.value;
  // 내 응모 캠페인의 채널 집합
  const chSet = new Set();
  _myApps.forEach(a => {
    const camp = allCampaigns.find(c=>c.id===a.campaign_id);
    if (!camp?.channel) return;
    camp.channel.split(',').map(s=>s.trim()).filter(Boolean).forEach(c => chSet.add(c));
  });
  const channels = Array.from(chSet).sort();
  const head = `<option value="" data-i18n="appHistory.allChannels">${t('appHistory.allChannels')}</option>`;
  const options = channels.map(c => `<option value="${esc(c)}">${esc(getChannelLabel(c))}</option>`).join('');
  sel.innerHTML = head + options;
  if (prev && channels.includes(prev)) sel.value = prev;
}
// Stage 6 알림 로직은 dev/js/notifications.js (햄버거 메뉴 모달)로 이전됨

// ════════════════════════════════════════════════════════════════════
// 신청 본인 취소 (migration 104, 사양 docs/specs/2026-05-11-application-cancel.md §4)
// ════════════════════════════════════════════════════════════════════

let _cancelTargetAppId = null;
let _cancelReasonsCache = null;

// 클라이언트측 cancel_phase 계산 — 서버 RPC 의 CASE 와 동일 우선순위.
// 모달 분기(단순 vs 사유 입력)와 phase 라벨 표시에 사용. 서버가 최종 검증.
function _computeCancelPhase(camp) {
  if (!camp) return 'other';
  const now = Date.now();
  const toMs = (d) => d ? Date.parse(d) : null;
  const recruitDeadline = toMs(camp.deadline);
  const purchaseStart = toMs(camp.purchase_start);
  const purchaseEnd   = toMs(camp.purchase_end);
  const visitStart    = toMs(camp.visit_start);
  const visitEnd      = toMs(camp.visit_end);
  const submissionEnd = toMs(camp.submission_end);
  if (purchaseStart && now >= purchaseStart && (!purchaseEnd || now <= purchaseEnd)) return 'purchase';
  if (visitStart    && now >= visitStart    && (!visitEnd    || now <= visitEnd))    return 'visit';
  if (submissionEnd && now > submissionEnd) return 'post';
  if (purchaseEnd   && now > purchaseEnd)   return 'post';
  if (visitEnd      && now > visitEnd)      return 'post';
  if (recruitDeadline && now <= recruitDeadline) return 'recruit';
  return 'other';
}

// ⋮ 메뉴 액션 모달: 「결과물 제출」 / 「응모 취소」 선택.
//   pending 상태:  결과물 제출 옵션 비활성(안내 텍스트만), 응모 취소 활성
//   approved 상태: 결과물 제출 옵션 활성 → 활동관리 페이지 이동
//                  응모 취소 옵션 — 결과물 1건이라도 approved 면 비활성 + tooltip
let _applyActionTargetAppId = null;

function openApplyActionModal(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  _applyActionTargetAppId = appId;
  const isApproved = app.status === 'approved';
  const ds = (_myDelivsByApp[appId] || []);
  const hasApprovedDeliv = ds.some(d => d.status === 'approved');
  // 결과물 제출 버튼: approved 만 활성. pending 은 비활성 + 안내 텍스트
  const submitBtn = $('applyActionSubmitBtn');
  const submitHint = $('applyActionSubmitHint');
  if (submitBtn && submitHint) {
    submitBtn.disabled = !isApproved;
    submitBtn.style.opacity = isApproved ? '1' : '.5';
    submitBtn.style.cursor = isApproved ? 'pointer' : 'not-allowed';
    submitBtn.onclick = isApproved
      ? () => { closeApplyActionModal(); if (typeof openActivityPage === 'function') openActivityPage(app.id, app.campaign_id, 'mypage'); }
      : null;
    submitHint.textContent = isApproved
      ? t('appHistory.action.submitHintApproved')
      : t('appHistory.action.submitHintPending');
  }
  // 응모 취소 버튼: 결과물 approved 있으면 비활성 + tooltip, 없으면 활성
  const cancelBtn = $('applyActionCancelBtn');
  const cancelHint = $('applyActionCancelHint');
  if (cancelBtn && cancelHint) {
    cancelBtn.disabled = hasApprovedDeliv;
    cancelBtn.style.opacity = hasApprovedDeliv ? '.5' : '1';
    cancelBtn.style.cursor = hasApprovedDeliv ? 'not-allowed' : 'pointer';
    cancelBtn.title = hasApprovedDeliv ? t('appHistory.cancelDisabledDeliv') : '';
    cancelBtn.onclick = hasApprovedDeliv
      ? null
      : () => { closeApplyActionModal(); openCancelModalFor(app.id); };
    cancelHint.textContent = hasApprovedDeliv
      ? t('appHistory.cancelDisabledDeliv')
      : t('appHistory.action.cancelHint');
  }
  openModal('applyActionModal');
}

function closeApplyActionModal() {
  closeModal('applyActionModal');
  _applyActionTargetAppId = null;
}

// ════════════════════════════════════════════════════════════════════
// 응모 취소 페이지 (#page-app-cancel) — 2026-05-11 모달→페이지 전환
// 이전 cancelModal 의 UI/로직을 그대로 페이지로 이전. 모바일에서 모달이
// 키보드 위로 잘리는 문제가 일반 페이지(.page.active 자연 스크롤)에선
// 자동 해결됨.
// ════════════════════════════════════════════════════════════════════

// 함수명 openCancelModalFor 는 응모이력 ⋮ 액션 모달과 활동관리 헤더 버튼
// 양쪽이 호출하므로 인터페이스 호환을 위해 이름 유지. 내부 동작만 페이지
// navigate 로 변경.
async function openCancelModalFor(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  const camp = allCampaigns.find(c => c.id === app.campaign_id) || {};
  _cancelTargetAppId = appId;
  const phase = _computeCancelPhase(camp);
  // 페이지 안 input/표시 영역에 state 채움
  const campNameEl = $('cancelPageCampaign');
  if (campNameEl) campNameEl.textContent = camp.title || app.campaign_id || '';
  const isSimple = phase === 'recruit';
  // 단계별 화면 분기 — recruit 는 간단 취소, 그 외는 사유 입력 모드.
  // 두 모드 전환 로직은 데드락 자동 복구에서도 재사용하도록 헬퍼로 분리.
  if (isSimple) {
    _showCancelSimpleMode();
  } else {
    await _revealCancelReasonFields(phase);
  }
  // phase + appId hidden
  const phaseEl = $('cancelPagePhase');
  if (phaseEl) phaseEl.value = phase;
  const appIdEl = $('cancelPageAppId');
  if (appIdEl) appIdEl.value = appId;
  // 에러 영역 초기화
  const errEl = $('cancelPageError');
  if (errEl) { errEl.textContent = ''; errEl.style.display = 'none'; }
  // 진입 출처 기록 (mypage 응모이력 vs 활동관리). 성공 시 응모이력으로 이동.
  const activeIsActivity = document.getElementById('page-activity')?.classList?.contains('active');
  _cancelPageFrom = activeIsActivity ? 'activity' : 'mypage';
  // 페이지 전환
  if (typeof navigate === 'function') navigate('app-cancel');
  if (typeof applyI18n === 'function') applyI18n();
  // 모바일 키보드 대응: input/select/textarea focus 시 명시적 scrollIntoView.
  // #appShell 이 position:fixed + overflow:hidden 이라 iOS Safari 의 자동
  // 스크롤이 .page.active 내부 컨테이너에서 작동하지 않으므로 직접 처리.
  _attachCancelPageFocusScroll();
}

// 간단 취소 모드 — 사유/동의/경고 박스 숨김, 간단 안내만 표시 (recruit 단계)
function _showCancelSimpleMode() {
  const boxes = ['cancelPageWarning','cancelPageReason','cancelPageNoteWrap','cancelPageAckWrap']
    .map(id => $(id));
  boxes.forEach(b => { if (b) b.style.display = 'none'; });
  const simpleBody = $('cancelPageSimpleBody');
  if (simpleBody) simpleBody.style.display = 'block';
}

// 사유 입력 모드로 전환 — 박스 표시 + 경고 카피 + 사유 카탈로그 로드 + 입력 초기화.
// 진입 시(비-recruit)와 데드락 자동 복구(서버가 사유를 요구)에서 공통 호출.
async function _revealCancelReasonFields(phase) {
  const boxes = ['cancelPageWarning','cancelPageReason','cancelPageNoteWrap','cancelPageAckWrap']
    .map(id => $(id));
  boxes.forEach(b => { if (b) b.style.display = 'block'; });
  const simpleBody = $('cancelPageSimpleBody');
  if (simpleBody) simpleBody.style.display = 'none';
  // 경고 카피 — 단계별 문구, recruit/미상이면 일반 문구(warningOther)
  const warnTextEl = $('cancelPageWarningText');
  if (warnTextEl) {
    const valid = ['purchase','visit','post'];
    const key = valid.includes(phase)
      ? `appHistory.cancel.warning${phase.charAt(0).toUpperCase()}${phase.slice(1)}`
      : 'appHistory.cancel.warningOther';
    warnTextEl.textContent = t(key);
  }
  // 사유 셀렉트 카탈로그 로드 + 입력 초기화
  if (!_cancelReasonsCache) _cancelReasonsCache = await fetchCancelReasons();
  const sel = $('cancelPageReasonSelect');
  if (sel) {
    const lang = (typeof getLang === 'function') ? getLang() : 'ja';
    const pickLabel = (r) => (lang === 'ko' ? (r.name_ko || r.name_ja) : (r.name_ja || r.name_ko));
    const placeholder = `<option value="">${esc(t('appHistory.cancel.reasonSelect'))}</option>`;
    const opts = _cancelReasonsCache.map(r => `<option value="${esc(r.code)}">${esc(pickLabel(r))}</option>`).join('');
    sel.innerHTML = placeholder + opts;
    sel.value = '';
    // 카테고리 선택 시 textarea placeholder 를 카테고리별 가이드로 갱신
    sel.onchange = () => _syncCancelNotePlaceholder(sel.value);
  }
  const note = $('cancelPageNote');
  if (note) {
    note.value = '';
    note.placeholder = t('appHistory.cancel.notePlaceholderDefault');
  }
  const ack = $('cancelPageAck');
  if (ack) ack.checked = false;
}

// 카테고리 코드별 textarea placeholder 동기화
function _syncCancelNotePlaceholder(reasonCode) {
  const note = $('cancelPageNote');
  if (!note) return;
  // i18n notePlaceholder.<code> 우선, 없으면 default
  let placeholder = '';
  if (reasonCode) {
    placeholder = t('appHistory.cancel.notePlaceholder.' + reasonCode);
    // t() 가 키를 그대로 반환하면 매핑 없는 코드 → default 사용
    if (placeholder === 'appHistory.cancel.notePlaceholder.' + reasonCode) placeholder = '';
  }
  if (!placeholder) placeholder = t('appHistory.cancel.notePlaceholderDefault');
  note.placeholder = placeholder;
}

// 이미 등록됐는지 플래그 — 페이지 재진입 시 listener 중복 부착 방지
let _cancelPageFocusScrollBound = false;
function _attachCancelPageFocusScroll() {
  if (_cancelPageFocusScrollBound) return;
  const page = document.getElementById('page-app-cancel');
  if (!page) return;
  const targets = page.querySelectorAll('select, textarea, input[type="text"], input[type="number"]');
  targets.forEach(el => {
    el.addEventListener('focus', () => {
      // 0.3s 후 — 키보드/picker 슬라이드-업이 끝나 visualViewport 가 안정된 뒤
      setTimeout(() => {
        try { el.scrollIntoView({block: 'center', behavior: 'smooth'}); } catch(_e) {}
      }, 300);
    });
  });
  _cancelPageFocusScrollBound = true;
}

// 페이지 진입 출처 — 뒤로가기 동선 결정.
let _cancelPageFrom = 'mypage';

function navigateBackFromCancelApp() {
  if (typeof navigate === 'function') {
    if (_cancelPageFrom === 'activity' && _cancelTargetAppId) {
      const app = _myApps.find(a => a.id === _cancelTargetAppId);
      if (app && typeof openActivityPage === 'function') {
        openActivityPage(app.id, app.campaign_id, 'mypage');
        return;
      }
    }
    navigate('mypage');
    if (typeof openMypageSub === 'function') openMypageSub('applications');
  }
}

async function submitCancelApplicationFromPage() {
  const appId = $('cancelPageAppId')?.value || _cancelTargetAppId;
  if (!appId) return;
  const phase = $('cancelPagePhase')?.value || 'other';
  const isSimple = phase === 'recruit';
  const errEl = $('cancelPageError');
  const showErr = (msg) => {
    if (!errEl) { toast(msg, 'error'); return; }
    errEl.textContent = msg;
    errEl.style.display = 'block';
  };
  let reasonCode = null, reasonNote = null, acknowledged = false;
  if (!isSimple) {
    reasonCode = $('cancelPageReasonSelect')?.value || '';
    reasonNote = ($('cancelPageNote')?.value || '').trim();
    acknowledged = !!$('cancelPageAck')?.checked;
    if (!reasonCode) { showErr(t('appHistory.cancel.errorReason')); return; }
    // 추가 설명 필수화 — 사용자 요청 (2026-05-11). 사양 §3-2 매트릭스도
    // 같이 갱신 권장 (지금은 코드만 필수, 서버 RPC 는 선택 — RPC 검증은
    // 후속 마이그레이션에서 강화 가능).
    if (!reasonNote) { showErr(t('appHistory.cancel.errorNoteRequired')); return; }
    if (!acknowledged) { showErr(t('appHistory.cancel.errorAck')); return; }
    if (reasonNote.length > 500) reasonNote = reasonNote.slice(0, 500);
  }
  const submitBtn = $('cancelPageSubmitBtn');
  if (submitBtn) submitBtn.disabled = true;
  const res = await cancelApplication(appId, {
    reasonCode: reasonCode || null,
    reasonNote: reasonNote || null,
    acknowledged
  });
  if (submitBtn) submitBtn.disabled = false;
  if (!res.ok) {
    // 데드락 자동 복구: 화면은 간단(recruit) 모드인데 서버가 사유·동의를 요구하면
    // 클라이언트/서버 단계 판정이 엇갈린 것. 사유 입력란을 펼쳐 재입력받는다.
    if (isSimple && (res.error === 'reason_required' || res.error === 'acknowledgement_required')) {
      const phaseEl = $('cancelPagePhase');
      if (phaseEl) phaseEl.value = 'other'; // 비-recruit 로 보정 → 재제출 시 사유 검증 경로 진입
      await _revealCancelReasonFields('other');
      showErr(t('appHistory.cancel.reasonNowRequired'));
      return;
    }
    const errKey = {
      'not_owner':                    'appHistory.cancel.errorOwner',
      'invalid_status':               'appHistory.cancel.errorStatus',
      'deliverable_already_approved': 'appHistory.cancel.errorDeliverable',
      'reason_required':              'appHistory.cancel.errorReason',
      'acknowledgement_required':     'appHistory.cancel.errorAck',
      'application_not_found':        'appHistory.cancel.errorNotFound'
    }[res.error] || 'appHistory.cancel.errorGeneric';
    showErr(t(errKey));
    return;
  }
  // 성공 — 알림 생성, 토스트, 응모이력 새로고침 후 응모이력 「取消」 탭으로
  const camp = allCampaigns.find(c => c.id === (_myApps.find(a => a.id === appId)?.campaign_id)) || {};
  try {
    if (typeof insertApplicationCancelledNotification === 'function') {
      await insertApplicationCancelledNotification(appId, camp.title || '');
    }
  } catch(_e) { /* 알림 실패는 사용자 흐름 차단 안 함 */ }
  toast(t('appHistory.cancel.success'));
  _cancelTargetAppId = null;
  await loadMyApplications();
  if (typeof navigate === 'function') {
    navigate('mypage');
    if (typeof openMypageSub === 'function') openMypageSub('applications');
  }
  // cancelled 탭으로 자동 이동해 사용자가 결과 즉시 확인
  _myAppsTab = 'cancelled';
  if (typeof renderMyApplyTabs === 'function') renderMyApplyTabs();
  if (typeof renderMyApplyList === 'function') renderMyApplyList();
}

async function openCancelDetailModal(appId) {
  const app = _myApps.find(a => a.id === appId);
  if (!app) return;
  if (!_cancelReasonsCache) _cancelReasonsCache = await fetchCancelReasons();
  const reason = _cancelReasonsCache.find(r => r.code === app.cancel_reason_code);
  const setText = (id, text) => { const el = $(id); if (el) el.textContent = text || ''; };
  setText('cancelDetailDatetime', app.cancelled_at ? formatDate(app.cancelled_at) : '—');
  // 현재 언어 토글에 맞춰 카테고리 라벨 표시
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const reasonLabel = reason ? (lang === 'ko' ? (reason.name_ko || reason.name_ja) : (reason.name_ja || reason.name_ko)) : '—';
  setText('cancelDetailCategory', reasonLabel);
  setText('cancelDetailPhase', t(`appHistory.cancelPhase.${app.cancel_phase || 'other'}`));
  // 보충 텍스트는 있을 때만 행 노출.
  // noteRow 는 display:contents 로 grid 가상 행이라 'none'↔'contents' 로 명시 복원.
  const noteRow = $('cancelDetailNoteRow');
  const noteEl  = $('cancelDetailNote');
  if (app.cancel_reason && app.cancel_reason.trim()) {
    if (noteEl) noteEl.textContent = app.cancel_reason;
    if (noteRow) noteRow.style.display = 'contents';
  } else {
    if (noteRow) noteRow.style.display = 'none';
  }
  openModal('cancelDetailModal');
}

function closeCancelDetailModal() {
  closeModal('cancelDetailModal');
}

// 활동관리 페이지 진입 시 호출 — cancelled 신청이면 회색 안내 화면으로 차단
// dev/js/application.js 의 openActivityPage / 활동관리 라우팅에서 사용
function isApplicationCancelled(appId) {
  const app = _myApps.find(a => a.id === appId);
  return !!(app && app.status === 'cancelled');
}
