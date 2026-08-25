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
  // 생년월일·성별 읽기 전용 표시 (수정은 관리자만 — 연령 정책 PR4). 미등록은 안내 문구 유지
  renderProfileAgeReadonly();
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
  // ⚠️ 반드시 기다린다 — renderMyApplyList 안에서 결과물 캐시(_myDelivsByApp)를 채운다.
  //   안 기다리면 이 함수를 await 한 쪽은 캐시가 빈 채로 다음 화면을 그린다.
  //   실제 증상: 알림에서 바로 메시지 화면으로 들어가면 반려 사유가 안 보이고,
  //   응모이력을 거쳐 들어가면 보였다 — 같은 화면인데 경로에 따라 달랐다(전수조사 F-13).
  await renderMyApplyList();
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
        // 🔴 되돌리지 말 것 — 예전에는 여기서 임시저장(미제출)을 걸러 냈다.
        //   그러면 「올려는 뒀지만 제출은 안 한」 사람이 응모이력에서 아무 신호도 못 받고,
        //   활동관리에 다시 들어가야만 회색 배지 하나를 볼 수 있었다. 그 사람은 낸 줄 알고
        //   마감을 놓친다 — 운영에서 26건이 그렇게 4개월간 쌓였고(게시물 23·인증샷 2·
        //   영수증 1), 같은 일이 2026-04-27 에도 있었다(마이그레이션 073 머리말).
        //   이제 응모이력에서도 보이게 한다. 거르는 줄을 다시 넣으면 그 사람은 또 못 본다.
        const kindLabel = t('delivKind.' + (KIND_TO_KEY[kind] || kind));
        const statusLabel = t('delivStatus.' + d.status);
        let bg = '#FFF4E4', color = '#B8741A', extra = '';
        // 미제출은 눈에 띄되 반려(빨강)와는 구분되는 색 — 잘못한 게 아니라 아직 안 낸 것이다
        // ⚠️ 검수중(#FFF4E4/#B8741A)과 나란히 놓이는 자리다. 옅은 주황끼리는
        //   구분이 안 돼(2026-08-25 브라우저 확인) 테두리를 넣고 색을 진하게 한다.
        //   반려(빨강)와도 갈려야 한다 — 잘못한 게 아니라 아직 안 낸 것이다.
        if (d.status === 'draft') { bg = '#FFE0B2'; color = '#8A3B00'; extra = 'border:1px solid #E8912D;'; }
        else if (d.status === 'approved') { bg = '#E4F5E8'; color = '#2D7A3E'; }
        else if (d.status === 'rejected') { bg = '#FFE4E4'; color = '#C33'; }
        items.push(`<span style="display:inline-block;${extra}background:${bg};color:${color};font-size:11px;font-weight:700;padding:2px 8px;border-radius:3px">${esc(kindLabel)} ${esc(statusLabel)}</span>`);
      }
      delivItemsHtml = items.join('');
    }
    // 응모 상태 배지(당첨/심사중 등) + 결과물 상태 배지를 카드 본문 맨 아래 가로 한 줄로 모음
    const badgeRow = `<div class="apply-item-badges" style="display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-top:6px">${getStatusBadge(a.status, a.auto_reject_reason)}${delivItemsHtml}</div>`;
    const cautionLine = a.caution_agreed_at
      ? `<div class="apply-item-caution" style="font-size:11px;color:var(--green);margin-top:2px;display:inline-flex;align-items:center;gap:3px;flex-wrap:wrap"><span class="material-icons-round notranslate" translate="no" style="font-size:13px">check_circle</span>${t('appHistory.cautionAgreed')} ${formatDate(a.caution_agreed_at)}${cautionCompareButton(a, camp)}</div>`
      : '';
    // 메시지 버튼 + 미읽음 배지 (모든 응모 카드 — 응모건 단위 운영팀 문의)
    const msgUnread = _myMsgUnreadByApp[a.id] || 0;
    // 오프라인 행사 예약이면 「入場チケット」 버튼을 함께 둔다(진입 2곳 중 하나 — 사양서 §4-3).
    //   티켓 id 는 응모 이력에 없으므로 캠페인만 넘기고, 티켓 화면이 내 예약 중에서 찾는다.
    const ticketBtn = (typeof isEventCampaign === 'function' && isEventCampaign(camp)
                       && a.status !== 'cancelled')
      ? `<button type="button" class="apply-msg-btn" onclick="event.stopPropagation();openTicketForCampaign('${a.campaign_id}')" aria-label="${esc(t('event.ticketMenu'))}"><span class="material-icons-round notranslate" translate="no" style="font-size:22px">confirmation_number</span></button>`
      : '';
    const msgBtn = `<button type="button" class="apply-msg-btn" onclick="event.stopPropagation();openMessagesPage('${a.id}','mypage')" aria-label="${esc(t('messaging.btnLabel'))}"><span class="material-icons-round notranslate" translate="no" style="font-size:22px">chat_bubble_outline</span>${msgUnread>0?`<span class="apply-msg-badge">${msgUnread>9?'9+':msgUnread}</span>`:''}</button>`;
    return `<div class="apply-item" style="cursor:pointer;position:relative" ${clickAction}>
      <div class="apply-thumb">${thumb}</div>
      <div class="apply-item-info">
        ${camp.recruit_type ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:2px">${esc(getRecruitTypeLabelJa(camp.recruit_type))}</div>` : ''}
        <div class="apply-item-name" style="display:flex;align-items:center;gap:6px"><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:1">${esc(camp.title||a.campaign_id)}</span></div>
        <div class="apply-item-meta">${esc(brandLabelInflu(camp))} · ${t('appHistory.applyDate')} ${formatDate(a.created_at)}</div>
        ${cautionLine}
        ${cancelledLine}
        ${badgeRow}
      </div>
      <div class="apply-item-status" style="display:flex;flex-direction:column;align-items:flex-end;gap:4px"><div class="apply-item-actions" style="display:flex;align-items:center;gap:2px">${ticketBtn}${msgBtn}${menuHtml}</div></div>
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
  // 영문 서버 메시지 노출 금지 — 일반 안내로 통일.
  //   ⚠️ 그 대신 원문이 어디에도 안 남았다. 화면 문구는 그대로 두고 기록만 추가한다.
  if (error) { logAppError('changePassword', error); err.textContent=t('authError.genericError'); err.style.display='block'; return; }
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
  // ⚠️ 「報酬・精算」 화면은 없앴다(2026-08-19). 이 되돌림은 **지우면 안 된다** — 과거 북마크·
  //    브라우저 뒤로가기·해시 직접 입력(#mypage-settlements)으로 들어올 수 있는데, 화면이 없으면
  //    어느 것도 활성화되지 않아 **텅 빈 마이페이지**가 뜬다.
  if (sub === 'settlements') sub = 'applications';
  document.querySelectorAll('#page-mypage .mypage-view').forEach(v => v.classList.remove('active'));
  const target = $('mypage-sub-' + sub);
  if (target) target.classList.add('active');
  // 응모이력 진입(햄버거·알림·새로고침 등 모든 경로) 시 상태 드롭다운을 현재 _myAppsTab 기준으로
  // 즉시 채워 빈 박스/stale 선택 방지. 데이터 로드(loadMyApplications) 전이라도 항목은 보이고,
  // 로드 완료 후 renderMyApplyTabs 재호출로 건수까지 갱신된다.
  if (sub === 'applications' && typeof renderMyApplyTabs === 'function') renderMyApplyTabs();
  // 탈퇴 화면은 안이 비어 있어 **서버 판정을 받아야 그려진다**(§4-4).
  //   ⚠️ 이 줄이 없으면 해시로 직접 들어오거나(#mypage-withdraw) 뒤로가기로 돌아올 때
  //      **껍데기만 뜨고 안이 빈 채로 남는다** — 햄버거로 들어온 경우만 채워진다.
  if (sub === 'withdraw' && typeof loadWithdrawView === 'function') {
    const b = $('withdrawViewBody');
    if (b) b.innerHTML = `<div style="padding:24px 0;text-align:center;color:var(--muted);font-size:13px">${esc(wt('loading'))}</div>`;
    loadWithdrawView();
  }
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

// 회원 탈퇴 — 햄버거 「退会する」 진입점.
//   2026-08-19 까지는 「LINE 으로 연락해 주세요」 토스트 한 줄이었다(서버에 아무 일도
//   일어나지 않아, 묻는 것 자체가 거짓 전제였다). 2026-08-20 부터 **실제 화면**으로 간다.
//   사양서 `docs/specs/2026-08-18-member-withdrawal.md` §4-4 가 문구의 단일 소스.
function handleWithdraw() {
  openWithdrawScreen();
}

// ════════════════════════════════════════════════════════════════════
// 회원 탈퇴 화면 (사양서 §4-4 — 문구·판정 순서의 단일 소스)
// ════════════════════════════════════════════════════════════════════
//
// 🔴 **접수까지 실제로 동작한다.** 「탈퇴하기」를 누르면 2단 확인을 거쳐
//    `request_withdrawal` 이 불리고 **살아 있는 응모가 함께 철회된다 — 되돌릴 수 없다.**
// ✅ **「탈퇴 그만두기」(취소)도 동작한다** — `cancelWithdrawFromScreen()`. 【C. 대기】·
//    【D. 예정】 두 화면에 버튼이 있다.
//    ⚠️ 취소해도 **위에서 철회된 응모는 되살아나지 않는다.** 되돌릴 수 있는 것은
//       「탈퇴 절차」뿐이다 — 시험할 때 이 둘을 헷갈리지 말 것.
//    ⚠️ 이 주석은 **한때 「취소는 아직 비활성」이라고 사실과 반대로 적혀 있었다**
//       (취소를 구현한 커밋이 헤더를 같이 안 고쳤다, 2026-08-21 정정). 이 구역을
//       고칠 때 **아래 함수들과 이 머리말이 같은 말을 하는지** 확인할 것.
//
// 판정 순서 (§4-4-1) — **이 순서가 곧 설계다**:
//   ① active_request 가 있나?   ← mode 보다 먼저 (조회에 성공했을 때만)
//   ② 조회 실패·특수 계정인가?
//   ③ mode
//
// 🔴 **①을 ③보다 먼저 두는 이유** — `mode`(353)는 「지금 신청할 수 있나」만 답한다.
//    이미 신청한 회원의 상태가 그 뒤에 바뀌면(정산 행이 생기는 등) `locked_support` 가
//    되는데, `mode` 를 먼저 보면 **그 회원의 「탈퇴 그만두기」 버튼이 사라져 5일 유예를
//    화면이 빼앗는다.**
//
// 🔴 **`ok !== true` 면 `mode` 를 믿지 않는다** — `fetchWithdrawalPrecheck` 는 조회
//    실패·권한 오류를 **전부 `locked_support` 로 덮는다**(fail-closed, 의도된 설계).
//    그대로 그리면 통신이 끊긴 회원에게 **「운영팀이 확인해 처리합니다」라는 사실이 아닌
//    안내**가 뜬다 — 이 사양서가 고치려던 바로 그 유형이다.

// ⚠️ 로딩 표시와 조회는 `openMypageSub` 안에서 한다 — 해시로 직접 들어오는 경로와
//    **같은 자리**에서 처리해야 두 벌이 되지 않는다.
//
// 🔴 **`navigate('mypage', false)` 를 반드시 먼저 부른다.** `openMypageSub` 는
//    `#page-mypage` **안의** 서브 화면만 바꿀 뿐, 그 페이지 자체를 켜지 않는다
//    (`.page{display:none}`). 이 저장소의 다른 진입 경로(햄버거 아코디언·뒤로가기·
//    해시 직접 진입)는 **예외 없이** navigate 를 먼저 부른다.
//    ⚠️ GNB 「退会する」는 **어느 화면에서나 눌리는 전역 링크**라, 이 줄이 없으면
//    홈·캠페인에서 눌렀을 때 **햄버거만 닫히고 아무 일도 안 일어난다**(주소만 바뀌고
//    화면은 그대로 — 뒤로가기를 눌러야 그제야 뜨는 기이한 경로까지 생긴다).
//    2026-05-22 응모건 메시지에서 겪은 「누르면 막다른 길」과 같은 유형이다.
function openWithdrawScreen() {
  navigate('mypage', false);
  openMypageSub('withdraw');
}

// 문구 헬퍼 — `mypage.withdrawView.*` 를 짧게 부른다.
function wt(key, vars) {
  let s = (typeof t === 'function') ? t('mypage.withdrawView.' + key) : '';
  if (!s || s === 'mypage.withdrawView.' + key) s = '';
  if (vars) Object.keys(vars).forEach(k => { s = s.split('{' + k + '}').join(vars[k]); });
  return s;
}

async function loadWithdrawView() {
  let info = null, reasons = [];
  try {
    info = await fetchWithdrawalPrecheck();
  } catch (e) {
    console.warn('[loadWithdrawView] precheck', e);
  }
  // ⚠️ 사유 목록 조회 실패가 화면을 막지 않게 한다 — `fetchLookups` 는 다른 storage
  //    함수와 달리 예외를 던진다. 사유는 **선택**이라, 실패하면 그 부분만 감추고
  //    나머지는 그대로 보여준다.
  try {
    if (typeof fetchLookups === 'function') reasons = await fetchLookups('withdraw_reason') || [];
  } catch (e) {
    console.warn('[loadWithdrawView] reasons', e);
  }
  renderWithdrawView(info, reasons);
}

function renderWithdrawView(info, reasons) {
  const body = $('withdrawViewBody');
  if (!body) return;

  // ① 신청이 이미 있나 — mode 보다 먼저 본다(조회에 성공했을 때만 값이 있다)
  const req = (info && info.ok === true) ? info.active_request : null;
  if (req && req.status === 'pending_payout') { body.innerHTML = withdrawPendingHtml(); return; }
  if (req && req.status === 'scheduled')      { body.innerHTML = withdrawScheduledHtml(req); return; }

  // ② 조회 실패·특수 계정 — mode 를 믿지 않는다
  if (!info || info.ok !== true) { body.innerHTML = withdrawExceptionHtml(info); return; }

  // ③ mode
  if (info.mode === 'locked_support') { body.innerHTML = withdrawLockedHtml(info.blockers); return; }
  body.innerHTML = withdrawNoticeHtml(info, reasons);
}

// ── 【A】 탈퇴 안내 — open · locked_auto ──
//   ⚠️ `open` 과 `locked_auto` 는 **화면이 같다**(§4-4-1). 굳이 나눈 것은 관리자·문의
//      응대용이라, 시행일이 와도 이 화면은 고칠 자리가 0이다.
function withdrawNoticeHtml(info, reasons) {
  const unpaid = Number(info?.blockers?.unpaid_count || 0);
  // ⚠️ 「5일」을 한 문구로 덮지 않는다 — 미지급이 있으면 「지급이 끝난 뒤」가 앞에 붙는다.
  //    한 문구로 둘 다 덮으면 한쪽이 거짓이 된다.
  const scheduleLine = unpaid > 0 ? wt('aScheduleUnpaid', {n: unpaid}) : wt('aSchedule');
  const li = (s) => `<li style="margin-bottom:10px">${esc(s)}</li>`;

  // ⚠️ 사유는 **선택**이다(마이그레이션 347). 안 골라도 눌린다.
  //    조회에 실패했으면 이 부분만 통째로 감춘다.
  let reasonHtml = '';
  if (Array.isArray(reasons) && reasons.length) {
    const opts = reasons.map(r => {
      const label = (typeof getLang === 'function' && getLang() === 'ko') ? (r.name_ko || r.name_ja) : (r.name_ja || r.name_ko);
      return `<label style="display:flex;align-items:center;gap:8px;padding:10px 0;font-size:14px">
        <input type="radio" name="withdrawReason" value="${esc(r.code)}" onchange="onWithdrawReasonChange()">
        <span>${esc(label)}</span></label>`;
    }).join('');
    reasonHtml = `<div style="margin-top:24px">
      <div style="font-size:13px;color:var(--muted);margin-bottom:6px">${esc(wt('aReasonLabel'))}</div>
      ${opts}
      <textarea id="withdrawReasonNote" rows="3" placeholder="${esc(wt('aReasonPlaceholder'))}"
        style="display:none;width:100%;margin-top:8px;padding:10px;border:1px solid var(--line);border-radius:8px;font-size:16px;font-family:inherit"></textarea>
    </div>`;
  }

  return `<ul style="padding-left:18px;margin:8px 0 0;font-size:14px;line-height:1.7;color:var(--ink)">
      ${li(wt('aCancelApps'))}
      <li style="margin:-6px 0 10px;font-size:12px;color:var(--muted);list-style:none;margin-left:-18px;padding-left:0">${esc(wt('aCancelAppsSub'))}</li>
      ${li(scheduleLine)}
      ${li(wt('aPaypal'))}
      ${li(wt('aIrreversible'))}
    </ul>
    ${reasonHtml}
    <div style="display:flex;gap:8px;margin:28px 0 40px">
      <button class="btn btn-ghost" style="flex:1" onclick="closeMypageSub()">${esc(wt('aCancelBtn'))}</button>
      <button class="btn btn-primary" style="flex:1" onclick="showWithdrawConfirm()">${esc(wt('aSubmitBtn'))}</button>
    </div>`;
}

// ── 2단 확인 (§4-4-2) ──
//   ⚠️ **브라우저 확인창(`confirm`)을 쓰지 않는다** — 모바일에서 문구가 잘리고
//      스타일을 못 맞추며, 이 저장소는 그 대화상자가 뜨면 자동화가 멈추는 문제도 있다.
//      같은 화면 안에서 확인 단계로 **전환**한다.
//   ⚠️ 고른 사유를 여기서 기억해 둔다 — 화면을 다시 그리면 입력칸이 사라진다.
let _withdrawPending = null;

function showWithdrawConfirm() {
  const sel = document.querySelector('input[name="withdrawReason"]:checked');
  const note = $('withdrawReasonNote');
  _withdrawPending = {
    code: sel ? sel.value : null,
    // ⚠️ 「기타」가 아니면 자유 입력을 안 보낸다 — 다른 사유를 고르고 입력칸에
    //    남아 있던 옛 글이 함께 저장되는 것을 막는다.
    note: (sel && sel.value === 'other' && note) ? (note.value || '').trim() : '',
  };
  const body = $('withdrawViewBody');
  if (!body) return;
  body.innerHTML = `<div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:12px">${esc(wt('confirmTitle'))}</div>
    <div style="background:#FFF5F5;border:1px solid #F5C2C2;border-radius:8px;padding:14px;font-size:14px;line-height:1.7;color:#C33">
      ${esc(wt('aConfirm'))}
    </div>
    <div style="display:flex;gap:8px;margin:28px 0 40px">
      <button class="btn btn-ghost" style="flex:1" onclick="leaveWithdrawConfirm()">${esc(wt('confirmBackBtn'))}</button>
      <button id="withdrawSubmitBtn" class="btn btn-primary" style="flex:1" onclick="submitWithdraw()">${esc(wt('aSubmitBtn'))}</button>
    </div>`;
  window.scrollTo({top: 0, behavior: 'smooth'});
}

// 확인 단계에서 나올 때는 **반드시 이 함수로** 나온다.
//   🔴 `loadWithdrawView()` 를 직접 부르면 `_withdrawPending` 이 남는다. 그러면
//      언어 전환 재렌더가 `if (_withdrawPending) return;` 에 걸려 **조용히 죽는다** —
//      확인 단계만 보호하려던 가드가 그 경계를 벗어나 스스로를 무력화한다.
//      (재현: 탈퇴 화면 → 「탈퇴하기」 → 「돌아가기」 → 언어 변경 → 아무 반응 없음)
function leaveWithdrawConfirm() {
  _withdrawPending = null;
  loadWithdrawView();
}

// ── 접수 (§4-4-7) ──
//   🔴 **되돌릴 수 없는 동작이다** — 살아 있는 응모가 함께 철회된다.
//   ⚠️ 연타를 막는다 — 두 번 눌러도 서버가 멱등으로 받지만, 화면이 두 번 그려지면
//      회원은 무엇이 일어났는지 모른다.
async function submitWithdraw() {
  const btn = $('withdrawSubmitBtn');
  if (btn) { btn.disabled = true; btn.textContent = wt('submitting'); }

  let res = null;
  try {
    res = await requestWithdrawal(_withdrawPending?.code || null, _withdrawPending?.note || null);
  } catch (e) {
    console.warn('[submitWithdraw]', e);
  }

  if (!res || res.ok !== true) {
    // ⚠️ 실패 사유를 하나도 「알 수 없는 오류」로 뭉뚱그리지 않는다 — 화면이 원래
    //    안 그렸어야 하는 상황이 오면 그게 최종 방어선이 걸린 것이라, 무엇이
    //    막았는지 알려 줘야 원인을 찾을 수 있다.
    toast(withdrawErrorText(res), 'error');
    if (btn) { btn.disabled = false; btn.textContent = wt('aSubmitBtn'); }
    // 잠금·중복이면 화면 자체가 낡은 것이므로 다시 판정받는다.
    if (res && (res.reason === 'locked_needs_support' || res.reason === 'already_requested')) loadWithdrawView();
    return;
  }

  _withdrawPending = null;
  const body = $('withdrawViewBody');
  if (body) body.innerHTML = withdrawResultHtml(res);
  window.scrollTo({top: 0, behavior: 'smooth'});
}

// ── 3단계: 탈퇴 그만두기 (§4-4-5) ──
//
// 🔴 **5일 유예의 존재 이유가 이 버튼이다.** 화면·방침·상태표 세 곳이 「취소할 수 있다」고
//    약속하는데 누를 자리가 없으면 **지키지 못할 약속이 하나 더 느는 것**이다.
//
// ⚠️ **확인창을 띄우지 않는다** — 취소는 회원에게 **유리한 방향**이고 되돌릴 수 있다
//    (다시 신청하면 된다). 접수 때와 달리 막을 이유가 없다.
//
// ⚠️ **철회된 응모는 안 되살아난다** — 취소 성공 문구가 그 사실을 반드시 말한다.
//    응모 취소는 별개 사건이고 캠페인이 이미 마감됐을 수 있다.
async function cancelWithdrawFromScreen() {
  const btn = $('withdrawCancelBtn');
  if (btn) { btn.disabled = true; btn.textContent = wt('submitting'); }

  let res = null;
  try {
    res = await cancelWithdrawal();
  } catch (e) {
    console.warn('[cancelWithdrawFromScreen]', e);
  }

  if (!res || res.ok !== true) {
    toast(withdrawCancelErrorText(res), 'error');
    if (btn) { btn.disabled = false; btn.textContent = wt('dCancelBtn'); }
    // 이미 확정·이미 취소면 화면이 낡은 것 — 다시 판정받는다.
    if (res && (res.reason === 'already_done' || res.reason === 'already_cancelled')) loadWithdrawView();
    return;
  }

  toast(wt('dCancelled'), 'success');
  // 취소했으니 처음 상태(【A】 또는 【B】)로 돌아간다 — 서버에 다시 물어본다.
  loadWithdrawView();
}

// ⚠️ `admin_requested`(자격 상실 강제 탈퇴)만 본인이 못 되돌린다. 관리자 **대행**은
//    회원이 요청해서 대신 눌러 준 것이라 본인이 취소할 수 있다(마이그레이션 356).
function withdrawCancelErrorText(res) {
  const map = {
    admin_requested:       'dCancelAdminOnly',
    already_done:          'errAlready',
    already_cancelled:     'errAlready',
    not_authenticated:     'errAuth',
    not_found:             'errAuth',
    // ⚠️ 감사용 계정은 사전 조회(【E】)가 이미 막아 여기까지 오지 않는다.
    //    그래도 채워 둔다 — 접수 쪽(`withdrawErrorText`)이 같은 사유를 챙기고 있어
    //    한쪽만 비면 나중에 「왜 여기만 일반 문구지」가 된다.
    audit_account_blocked: 'eAudit',
  };
  return wt(map[res?.reason] || 'errUnknown');
}

function withdrawErrorText(res) {
  const map = {
    locked_needs_support:   'errLocked',
    // ⚠️ `already_requested` 는 **이 화면에서는 안 온다** — 본인 신청 함수(357)의
    //    멱등 분기는 `ok:false` 가 아니라 **`ok:true` 로 기존 상태를 그대로** 돌려준다.
    //    이 사유는 관리자 대행 함수(`request_withdrawal_for_member`) 전용이다.
    //    방어용으로만 남긴다 — 서버가 바뀌어 이 값이 오게 되면 문구가 없어 곤란해진다.
    already_requested:      'errAlready',
    invalid_reason:         'errReason',
    not_authenticated:      'errAuth',
    not_found:              'errAuth',
    audit_account_blocked:  'eAudit',
    admin_account_excluded: 'eAdmin',
  };
  return wt(map[res?.reason] || 'errUnknown');
}

// ── 신청 결과 (§4-4-7) — 숫자는 여기서만 말한다 ──
//   ⚠️ **0건인 줄은 안 그린다.**
//   ⚠️ **「새로 접수」와 「이미 있던 것」을 구분하지 않는다** — 357 의 멱등 분기는
//      `cancelled_count:0` 을 돌려주는데, **응모가 원래 없던 회원의 정상 접수도
//      똑같은 모양**이라 화면이 갈라낼 방법이 없다. 억지로 나누면 정상 접수를
//      「이미 진행 중」으로 잘못 말한다. 0건 줄을 안 그리는 것으로 충분하다 —
//      예정일과 상태가 뜨므로 접수됐다는 것은 전해진다.
function withdrawResultHtml(res) {
  const n = (v) => Number(v || 0);
  const lines = [];
  if (n(res.cancelled_count) > 0)   lines.push(`<li>${esc(wt('rCancelled', {n: n(res.cancelled_count)}))}</li>`);
  if (n(res.uncancelled_count) > 0) {
    lines.push(`<li>${esc(wt('rUncancelled', {n: n(res.uncancelled_count)}))}
      <div style="font-size:12px;color:var(--muted);margin-top:2px">${esc(wt('rUncancelledSub'))}</div></li>`);
  }
  const listHtml = lines.length
    ? `<ul style="padding-left:18px;margin:14px 0;font-size:14px;line-height:1.8">${lines.join('')}</ul>` : '';

  // 상태에 따라 아래 안내가 갈린다 — 예정일이 있으면 그 날짜, 없으면 「대기」 안내.
  let statusHtml = '';
  if (res.status === 'scheduled' && res.scheduled_date) {
    statusHtml = `<div style="margin-top:18px;font-size:15px;font-weight:700;color:var(--ink)">${esc(wt('dScheduled', {date: withdrawDateLabel(res.scheduled_date)}))}</div>
      <div style="font-size:14px;line-height:1.7;color:var(--ink);margin-top:6px">${esc(wt('dCanCancel'))}</div>`;
  } else {
    statusHtml = `<div style="margin-top:18px;font-size:14px;line-height:1.7;color:var(--ink)">${esc(wt('cBody'))}</div>`;
  }

  // 철회 못 한 응모가 있으면 문의 안내 — 그 응모가 어떻게 되는지 달리 알 길이 없다.
  const contactHtml = n(res.uncancelled_count) > 0
    ? `<div style="margin-top:18px;background:var(--bg);border-radius:8px;padding:14px;font-size:13px;line-height:1.7">${esc(wt('rContact'))}</div>` : '';

  return `<div style="font-size:15px;font-weight:700;color:var(--ink)">${esc(wt('rTitle'))}</div>
    ${listHtml}${statusHtml}${contactHtml}
    <div style="margin:28px 0 40px">
      <button class="btn btn-ghost" style="width:100%" onclick="closeMypageSub()">${esc(wt('rDoneBtn'))}</button>
    </div>`;
}

// 「その他」(기타)를 골랐을 때만 자유 입력칸을 보인다(§4-3).
function onWithdrawReasonChange() {
  const sel = document.querySelector('input[name="withdrawReason"]:checked');
  const note = $('withdrawReasonNote');
  if (!note) return;
  const show = sel && sel.value === 'other';
  note.style.display = show ? '' : 'none';
  // 입력칸이 나타날 때 키보드에 가리지 않게 시야로 끌어온다.
  if (show) setTimeout(() => note.scrollIntoView({block: 'center', behavior: 'smooth'}), 80);
}

// ── 【B】 운영팀 처리 — locked_support ──
//   ⚠️ **0건인 줄은 그리지 않는다.**
//   🔴 **「정산 기록 ◯건」은 쓰지 않는다** — 정산은 회원에게서 통째로 없앤 화면이라
//      (마이그레이션 343) 건수만 던지면 **볼 데가 없는 것을 가리킨다.**
//      그 항목만 걸린 회원에게는 「응모나 보수 절차가 남아 있어서」 한 줄로 대신한다.
function withdrawLockedHtml(b) {
  const n = (v) => Number(v || 0);
  const lines = [];
  if (n(b?.approved_deliverable_apps) > 0) lines.push(wt('bApproved', {n: n(b.approved_deliverable_apps)}));
  if (n(b?.event_apps) > 0)                lines.push(wt('bEvent',    {n: n(b.event_apps)}));
  if (n(b?.unpaid_count) > 0)              lines.push(wt('bUnpaid',   {n: n(b.unpaid_count)}));
  // 세 줄이 다 비면(= 정산 기록만 걸림) 뭉뚱그린 한 줄
  const detail = lines.length
    ? `<ul style="padding-left:18px;margin:14px 0;font-size:14px;line-height:1.8">${lines.map(s => `<li>${esc(s)}</li>`).join('')}</ul>`
    : `<div style="margin:14px 0;font-size:14px;color:var(--muted)">${esc(wt('bOther'))}</div>`;

  return `<div style="font-size:14px;line-height:1.7;color:var(--ink)">${esc(wt('bIntro'))}</div>
    ${detail}
    <div style="background:var(--bg);border-radius:8px;padding:14px;font-size:13px;line-height:1.7;color:var(--ink)">
      ${esc(wt('bContact'))}
    </div>
    <div style="margin:28px 0 40px">
      <button class="btn btn-ghost" style="width:100%" onclick="closeMypageSub()">${esc(wt('bBackBtn'))}</button>
    </div>`;
}

// ── 【C】 대기 중 — pending_payout ──
//   ⚠️ **「メールで」(메일로)라고 명시한다** — 정산 알림을 없앤 뒤로 예정일 안내 메일이
//      회원에게 닿는 **유일한 통지**다(351). 「앱에서 알려드립니다」로 쓰면 안 온다.
//   ⚠️ **예정일 칸 자체를 그리지 않는다** — 이 상태에는 예정일이 아직 없다.
function withdrawPendingHtml() {
  return `<div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:10px">${esc(wt('cTitle'))}</div>
    <div style="font-size:14px;line-height:1.7;color:var(--ink)">${esc(wt('cBody'))}</div>
    <div style="margin:28px 0 40px">
      <button id="withdrawCancelBtn" class="btn btn-ghost" style="width:100%" onclick="cancelWithdrawFromScreen()">${esc(wt('dCancelBtn'))}</button>
    </div>`;
}

// ── 【D】 예정 — scheduled ──
//   ⚠️ **날짜는 서버가 준 값을 그대로 쓴다.** 화면이 「오늘 + 5일」을 계산하면 기기
//      시계로 갈린다(서버는 일본 시각 기준). 「あと◯日」도 같은 이유로 안 쓴다.
//   🔴 **예정일이 지났는데 아직 확정 전인 구간에도 이 화면이 그대로 떠야 한다** —
//      358 이 로그아웃과 쓰기 차단을 **일부러 다른 값으로 나눈 이유**가 그 구간이고,
//      거기서 「탈퇴 그만두기」에 닿는 자리는 이 화면 하나뿐이다.
function withdrawScheduledHtml(req) {
  const d = req?.scheduled_date ? withdrawDateLabel(req.scheduled_date) : '';
  return `<div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:10px">${esc(wt('dScheduled', {date: d}))}</div>
    <div style="font-size:14px;line-height:1.7;color:var(--ink)">${esc(wt('dCanCancel'))}</div>
    <div style="margin:28px 0 40px">
      <button id="withdrawCancelBtn" class="btn btn-ghost" style="width:100%" onclick="cancelWithdrawFromScreen()">${esc(wt('dCancelBtn'))}</button>
    </div>`;
}

// 'YYYY-MM-DD' → 「YYYY年MM月DD日」 / 「YYYY년 MM월 DD일」
// ⚠️ Date 객체를 거치지 않는다 — 서버가 일본 시각으로 만든 날짜라, 기기 시간대로
//    다시 해석하면 하루가 밀린다.
function withdrawDateLabel(ymd) {
  const m = String(ymd).match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (!m) return String(ymd || '');
  const [, y, mo, d] = m;
  const ko = (typeof getLang === 'function' && getLang() === 'ko');
  return ko ? `${y}년 ${Number(mo)}월 ${Number(d)}일` : `${y}年${Number(mo)}月${Number(d)}日`;
}

// ── 【E】 예외 — 조회 실패·감사용·관리자 겸직 ──
//   ⚠️ **어떤 실패도 「알 수 없는 오류」로 뭉뚱그리지 않는다.**
function withdrawExceptionHtml(info) {
  let msg = wt('eError');
  if (info?.reason === 'audit_account_blocked')  msg = wt('eAudit');
  if (info?.reason === 'admin_account_excluded') msg = wt('eAdmin');
  return `<div style="font-size:14px;line-height:1.7;color:var(--ink)">${esc(msg)}</div>
    <div style="margin:28px 0 40px">
      <button class="btn btn-ghost" style="width:100%" onclick="closeMypageSub()">${esc(wt('bBackBtn'))}</button>
    </div>`;
}

// 초기 + langchange 이벤트에서 토글 상태 갱신
document.addEventListener('DOMContentLoaded', updateLangToggleUI);
window.addEventListener('langchange', updateLangToggleUI);

// 언어 전환 시 응모이력 상태 드롭다운 라벨(進行中 등) 갱신 — 동적 렌더라 applyI18n 미적용 대상
window.addEventListener('langchange', () => {
  if ($('myApplyStatusSelect') && typeof renderMyApplyTabs === 'function') renderMyApplyTabs();
});

// 생년월일·성별 읽기 전용 표시 갱신 (loadMyPage + 언어 전환 공용 — 동적 텍스트라 applyI18n 미적용)
function renderProfileAgeReadonly() {
  const p = currentUserProfile || {};
  const bdEl = $('profileBirthdateDisplay');
  if (bdEl) {
    const label = (typeof formatBirthdateLabel === 'function') ? formatBirthdateLabel(p.birthdate) : '';
    if (label) { bdEl.textContent = label; bdEl.removeAttribute('data-i18n'); }
    else { bdEl.setAttribute('data-i18n', 'profile.notRegistered'); bdEl.textContent = t('profile.notRegistered'); }
  }
  const gEl = $('profileGenderDisplay');
  if (gEl) {
    const gl = (typeof genderLabel === 'function') ? genderLabel(p.gender) : '';
    if (gl) { gEl.textContent = gl; gEl.removeAttribute('data-i18n'); }
    else { gEl.setAttribute('data-i18n', 'profile.notRegistered'); gEl.textContent = t('profile.notRegistered'); }
  }
}
window.addEventListener('langchange', renderProfileAgeReadonly);

// 탈퇴 화면은 **동적 렌더**라 `data-i18n` 이 안 걸린다 — 언어를 바꾸면 다시 그려야 한다.
//   ⚠️ 이 리스너가 없으면 화면을 보다가 언어를 바꾼 회원이 **다음 재진입까지 옛 언어**를 본다
//      (다른 동적 화면들과 같은 처리 — 위 renderMyApplyTabs·renderProfileAgeReadonly).
//   ⚠️ **확인 단계·결과 화면에서는 다시 그리지 않는다** — `loadWithdrawView()` 는 서버에
//      다시 물어 【A】부터 그리므로, 확인 중이던 사람이 언어를 바꾸면 **고른 사유가 사라지고
//      처음으로 돌아간다.** 그 두 상태는 잠깐 머무는 자리라 옛 언어로 두는 편이 낫다.
window.addEventListener('langchange', () => {
  const view = $('mypage-sub-withdraw');
  if (!view || !view.classList.contains('active')) return;
  if (_withdrawPending) return;          // 확인 단계·접수 중 — 건드리지 않는다
  if (typeof loadWithdrawView === 'function') loadWithdrawView();
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
// 지난 기록의 사유 라벨 조회용 — 목록에서 감춘 사유(회원 탈퇴·운영진 취소)도 포함해야
// 이미 그 사유로 취소된 응모의 상세가 빈 칸으로 보이지 않는다.
// ⚠️ 고르는 드롭다운(_cancelReasonsCache)과 절대 합치지 말 것 — 합치면 회원이
//    「회원 탈퇴」·「운영진 취소」를 자기 취소 사유로 고를 수 있게 된다.
let _cancelReasonsAllCache = null;

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
  // 이 응모가 오프라인 행사(방문 예약)인지 — 아래 두 버튼이 모두 이 값으로 갈린다.
  //   판정은 isEventCampaign 하나만 쓴다(화면마다 다른 판정을 만들지 않는다).
  const _campForAction = allCampaigns.find(c => c.id === app.campaign_id) || {};
  const isEventAction = (typeof isEventCampaign === 'function') && isEventCampaign(_campForAction);
  // 결과물 제출 버튼: approved 만 활성. pending 은 비활성 + 안내 텍스트
  //   ⚠️ 행사 캠페인은 결과물을 내지 않으므로 이 줄 자체를 그리지 않는다. 눌러도 티켓
  //      화면으로 돌아가긴 하지만(openActivityPage 의 행사 분기), 「영수증·게시 URL을
  //      제출합니다」가 활성으로 보이는 것만으로 방문객은 무엇을 내야 하는지 헷갈린다.
  //   ⚠️ 모달을 재사용하므로 일반 캠페인에서는 반드시 다시 보이게 되돌린다.
  const submitBtn = $('applyActionSubmitBtn');
  const submitHint = $('applyActionSubmitHint');
  if (submitBtn) submitBtn.style.display = isEventAction ? 'none' : 'flex';
  if (submitBtn && submitHint && !isEventAction) {
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
  // 오프라인 행사는 이 버튼으로 곧장 취소할 수 없다 — 신청만 취소되면 예약(입장 티켓)이
  //   확정으로 남아 어긋난다. 서버(마이그레이션 289)가 아예 막는다.
  //   그래서 회색으로 죽이지 않고 **누를 수 있게 두되 입장 티켓 화면으로 보낸다**.
  //   행사 캠페인은 이 줄이 더보기 메뉴의 유일한 항목이라, 죽여 두면 메뉴 전체가
  //   아무것도 못 하는 껍데기가 된다(2026-08-06 사용자 확인).
  if (cancelBtn && cancelHint) {
    const blocked = hasApprovedDeliv && !isEventAction;
    const reason = isEventAction ? t('event.cancelViaTicket') : t('appHistory.cancelDisabledDeliv');
    cancelBtn.disabled = blocked;
    cancelBtn.style.opacity = blocked ? '.5' : '1';
    cancelBtn.style.cursor = blocked ? 'not-allowed' : 'pointer';
    cancelBtn.title = blocked ? reason : '';
    if (blocked) {
      cancelBtn.onclick = null;
    } else if (isEventAction) {
      cancelBtn.onclick = () => {
        closeApplyActionModal();
        if (typeof openTicketForCampaign === 'function') openTicketForCampaign(app.campaign_id);
      };
    } else {
      cancelBtn.onclick = () => { closeApplyActionModal(); openCancelModalFor(app.id); };
    }
    cancelHint.textContent = (blocked || isEventAction) ? reason : t('appHistory.action.cancelHint');
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
  // 잠금·버튼 복원을 헬퍼에 맡긴다(사양서 2026-07-31 §3 1-3).
  //   예전에는 호출 전후로 직접 풀어, 그 사이에서 예외가 나면 버튼이 잠긴 채 남았다.
  const res = await withSubmitLock('cancelApp:' + appId, 'cancelPageSubmitBtn', t('common.submitting'),
    function() {
      return cancelApplication(appId, {
        reasonCode: reasonCode || null,
        reasonNote: reasonNote || null,
        acknowledged
      });
    });
  if (!res) return;   // 이미 실행 중이라 무시됨
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
    // ⚠️ 이 사전이 「3개월 침묵」의 정확한 지점이었다. 취소 함수가 서버에서 죽어 있었는데
    //    그 오류가 사전에 없어 errorGeneric(「취소하지 못했습니다」)으로 덮였고,
    //    friendlyErrorJa 를 안 거쳐 관리자 오류 로그에도 안 남았다.
    //    문구·동작은 그대로 두고, 사전에 없는 값일 때만 「예상 못 한 오류」로 기록한다.
    const CANCEL_EXPECTED = [
      'not_owner', 'invalid_status', 'deliverable_already_approved',
      'reason_required', 'acknowledgement_required', 'application_not_found'
    ];
    const errKey = {
      'not_owner':                    'appHistory.cancel.errorOwner',
      'invalid_status':               'appHistory.cancel.errorStatus',
      'deliverable_already_approved': 'appHistory.cancel.errorDeliverable',
      'reason_required':              'appHistory.cancel.errorReason',
      'acknowledgement_required':     'appHistory.cancel.errorAck',
      'application_not_found':        'appHistory.cancel.errorNotFound'
    }[res.error] || 'appHistory.cancel.errorGeneric';
    logAppError('submitCancelApplication', res.error, CANCEL_EXPECTED);
    showErr(t(errKey));
    return;
  }
  // 성공 — 토스트, 응모이력 새로고침 후 응모이력 「取消」 탭으로
  //   ⚠️ 취소 알림은 **서버가 만든다**(마이그레이션 309). 예전에는 여기서 브라우저가
  //      `notifications` 에 직접 넣었는데, 그 표는 서버 함수·트리거만 쓸 수 있어
  //      **도입 이래 한 번도 성공한 적이 없었다**(운영 실측 취소 30건 / 알림 0건).
  //      실패가 `catch(_e) {}` 로 삼켜져 아무도 몰랐다. 여기서 다시 부르면 알림이
  //      두 개가 되므로 되살리지 말 것.
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
  if (!_cancelReasonsAllCache) _cancelReasonsAllCache = await fetchCancelReasons({ includeInactive: true });
  const reason = _cancelReasonsAllCache.find(r => r.code === app.cancel_reason_code);
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
