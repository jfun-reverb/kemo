// 브랜드 페이지 — 캠페인 목록(05) + 상세 (1단계: 모집 현황·진행 단계·일정)
//   피그마 「[1차] 05 캠페인」 bw05-00(리스트)·00a(카드)·bm05-00(모바일)·bw05-01(상세 — 결과물 공개 전)
//   서버 함수 get_my_brand_campaigns · get_my_brand_campaign(마이그레이션 543)
//   2026-10-19 사용자 결정 1~8: 보일 상태 넷 · 결과물 게시 「-」 · 선정 = 당선만 · 응모 = 취소 제외 · 진행 단계는 모집 형식별
//   (리뷰어형은 「선정」 없음 — 일정 「선정 발표」 줄도 없음, 숫자 카드는 「참여 / 정원」) · 날짜는 서버의 일본 날짜 · 최신순 한 페이지 · 보기 기억
//   🔴 상태는 서버가 날짜로 다시 판정한 값(543 설계 판단 [I])만 쓴다 — 화면에서 다시 판정하지 않는다.
//   🔴 조회 실패(null)와 0건([])을 구분한다 — 실패를 「캠페인 없음」으로 그리지 않는다.
//   2단계(작업표 2026-10-19 조각 14): 결과물 영역은 brand-campaign-results.js(brandResultSectionHtml) · 「결과물 게시」 칸은
//      서버 요약(550 — result_posted = 검수 완료 / approved_count 합계, S11) · 응모·참여는 「REVERB N + 외부 참가자 M」 나눠 적기(S25)

const BRAND_CAMP_MSG = {
  loadFailTitle: '캠페인 목록을 불러오지 못했습니다',
  loadFailDesc: '인터넷 연결을 확인한 뒤 다시 시도해 주십시오. 계속되면 담당자에게 문의해 주십시오.',
  emptyTitle: '아직 진행한 캠페인이 없습니다',
  emptyDesc: '운영팀이 캠페인을 등록하면 여기에 나타납니다.',
  detailFailTitle: '캠페인을 불러오지 못했습니다',
  notFoundTitle: '이 캠페인을 볼 수 없습니다',
  notFoundDesc: '주소가 잘못되었거나 지금 브랜드에서 볼 수 없는 캠페인입니다. 캠페인 목록에서 다시 골라 주십시오.',
  resultTitle: '아직 결과가 준비되지 않았습니다',
  resultDesc: '캠페인이 진행되면 담당자가 결과물을 공개해 드립니다. 공개되면 여기에서 결과물 목록을 보고 엑셀로 내려받을 수 있습니다.'
};

// 상태 이름표 한 곳 — 탭·리스트·카드·상세 머리가 모두 이것을 쓴다
const BRAND_CAMP_STATUS = {
  scheduled: { label: '모집 예정', cls: 'is-scheduled' },
  active:    { label: '모집 중',   cls: 'is-active' },
  closed:    { label: '모집 마감', cls: 'is-closed' },
  ended:     { label: '종료',      cls: 'is-ended' }
};
const BRAND_CAMP_TABS = [
  { key: 'all', label: '전체' },
  { key: 'scheduled', label: '모집 예정' },
  { key: 'active', label: '모집 중' },
  { key: 'closed', label: '모집 마감' },
  { key: 'ended', label: '종료' }
];
const BRAND_CAMP_TYPE = { monitor: '리뷰어', gifting: '시딩', visit: '방문' };
const BRAND_CAMP_VIEW_KEY = 'reverb.brandCampaigns.view';   // 결정 8 — 이 기기에 기억

let _bcList;              // undefined 불러오는 중 · null 실패 · { brandId, today, campaigns }
let _bcTab = 'all';
let _bcView = _bcReadView();
let _bcListSeq = 0;
let _bcDetail = null;     // { id, state:'loading'|'error'|'not_found'|'ok', camp, today }
let _bcDetailSeq = 0;
let _bcAutoSwitching = false;   // 상세가 다른 내 브랜드 캠페인이라 브랜드를 바꾸는 중 — 「브랜드가 바뀌면 목록으로」를 건너뛴다
const _bcMobileMq = window.matchMedia('(max-width: 600px)');

function _bcReadView() {
  try { return localStorage.getItem(BRAND_CAMP_VIEW_KEY) === 'card' ? 'card' : 'list'; } catch (e) { return 'list'; }
}
function _bcSaveView(v) {
  try { localStorage.setItem(BRAND_CAMP_VIEW_KEY, v); } catch (e) { /* 저장소 막힘 — 이번 화면만 */ }
}
function _bcEffectiveView() { return _bcMobileMq.matches ? 'card' : _bcView; }   // 모바일(bm05-00)은 카드만

// ── 날짜 — 서버가 'YYYY-MM-DD' 문자열로 준다(시각 없음). Date 로 바꾸지 않고 글자로 다룬다(기기 시간대 영향 없음)
function _bcYmd(v) { return v ? String(v).slice(0, 10) : ''; }
function _bcShort(v) { const s = _bcYmd(v); return s ? s.slice(5, 7) + '/' + s.slice(8, 10) : ''; }   // 10/13
function _bcFull(v) { const s = _bcYmd(v); return s ? s.replace(/-/g, '/') : ''; }                    // 2026/10/13
function _bcDayDiff(from, to) {   // to - from (일)
  const a = Date.parse(_bcYmd(from) + 'T00:00:00Z'), b = Date.parse(_bcYmd(to) + 'T00:00:00Z');
  return (isNaN(a) || isNaN(b)) ? null : Math.round((b - a) / 86400000);
}
function _bcRange(s, e, fmt) {
  const a = fmt(s), b = fmt(e);
  if (a && b) return a + ' ~ ' + b;
  if (b) return '~ ' + b;
  if (a) return a + ' ~';
  return '';
}
function _bcDash() { return '<span class="brand-dash">-</span>'; }

// ── 표시 조각
function _bcTypeText(c) { return BRAND_CAMP_TYPE[c.recruit_type] || ''; }
function _bcChannelText(c) { return (Array.isArray(c.channel_names) ? c.channel_names : []).join(' · '); }
function _bcStatus(c) { return BRAND_CAMP_STATUS[c.status] || BRAND_CAMP_STATUS.ended; }
function _bcBadge(c) { const s = _bcStatus(c); return '<span class="bo-badge ' + s.cls + '">' + brandEsc(s.label) + '</span>'; }
function _bcSlotsText(c) {
  const n = Number(c.approved_count) || 0;
  return n + ' / ' + (c.slots != null && c.slots !== '' ? c.slots : '-');
}
function _bcSlotsPct(c) {
  const slots = Number(c.slots);
  if (!slots || slots <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((Number(c.approved_count) || 0) / slots * 100)));
}
function brandCampaignInTab(c, tab) { return tab === 'all' || c.status === tab; }

// 선정 단계·「선정 발표」 줄을 그리는가 — 🔴 인플루언서 캠페인 상세(application.js 「선정 기간」 줄)의 조건 사본(여섯째 — 목록은 그 자리 주석).
//   시딩형, 그리고 행사가 아니거나 선정형 행사인 방문형. 리뷰어형은 응모가 곧 당선(049)이라 없다(2026-10-19 결정 5).
//   ⚠️ 원본과 달리 날짜 칸이 비어도 단계 자체는 그린다(진행 단계는 「어디까지 왔나」라 칸이 빠지면 단계 수가 캠페인마다 달라진다) — 일정 표 줄은 원본처럼 값이 있을 때만.
function _bcHasSelection(c) {
  if (c.recruit_type === 'gifting') return true;
  if (c.recruit_type !== 'visit') return false;
  const isEvent = c.event_mode === true;
  const isSelEvent = isEvent && c.event_selection_mode === 'selection';
  return !isEvent || isSelEvent;
}
// 종료 기준일 — campaignFinishDate(shared.js)와 같은 식: 제출 마감, 행사는 마지막 방문일
function _bcFinishDate(c) {
  if (c.submission_end) return c.submission_end;
  if (c.event_mode === true && c.visit_end) return c.visit_end;
  return null;
}

// 진행 단계 — [{label, date}] + 지금 위치(cur). cur 앞은 지난 단계, cur 는 지금 단계, 뒤는 남은 단계.
//   모집 예정 = 아무 단계도 시작 전(-1) · 모집 중 = 모집 · 종료 = 종료 · 모집 마감 = 모집 뒤 단계 중 끝 날짜가 오늘 이상인 첫 단계
//   (날짜 없는 단계 — 시딩 「배송」 — 는 고르지 않는다. 모두 지났으면 「결과물 게시」).
function brandCampaignStages(c, today) {
  const st = [{ label: '모집', date: _bcRange(c.recruit_start, c.deadline, _bcShort), end: c.deadline }];
  if (_bcHasSelection(c)) st.push({ label: '선정', date: c.selection_end ? '~ ' + _bcShort(c.selection_end) : _bcRange(c.selection_start, null, _bcShort), end: c.selection_end || null });
  if (c.recruit_type === 'monitor') st.push({ label: '구매', date: _bcRange(c.purchase_start, c.purchase_end, _bcShort), end: c.purchase_end || null });
  else if (c.recruit_type === 'gifting') st.push({ label: '배송', date: '', end: null });
  else if (c.recruit_type === 'visit') st.push({ label: '방문', date: _bcRange(c.visit_start, c.visit_end, _bcShort), end: c.visit_end || null });
  st.push({ label: '결과물 게시', date: c.submission_end ? '~ ' + _bcShort(c.submission_end) : '', end: c.submission_end || null });
  const fin = _bcFinishDate(c);
  st.push({ label: '종료', date: _bcShort(fin), end: null });

  let cur = -1;
  if (c.status === 'active') cur = 0;
  else if (c.status === 'ended') cur = st.length - 1;
  else if (c.status === 'closed') {
    cur = st.length - 2;
    for (let i = 1; i < st.length - 1; i++) {
      if (st[i].end && _bcYmd(st[i].end) >= _bcYmd(today)) { cur = i; break; }
    }
  }
  return { stages: st, cur };
}

// ── 목록 그리기
function _bcHeadHtml() {
  return '<div class="brand-page-head"><div><h1>캠페인</h1>' +
    '<p>진행 중인 캠페인의 모집 현황과 일정을 확인할 수 있습니다.</p></div></div>';
}
function _bcTabsHtml(list) {
  const has = Array.isArray(list);
  return '<div class="bo-tabs" role="tablist" aria-label="캠페인 상태">' +
    BRAND_CAMP_TABS.map(t => {
      const on = t.key === _bcTab;
      const n = has ? list.filter(c => brandCampaignInTab(c, t.key)).length : null;
      return '<button type="button" role="tab" class="bo-tab' + (on ? ' is-on' : '') + '" aria-selected="' + on + '" data-bc-act="tab" data-tab="' + t.key + '">' +
        '<span class="bo-tab-name">' + brandEsc(t.label) + '</span>' +
        (n != null ? '<span class="bo-tab-count">' + n + '</span>' : '') + '</button>';
    }).join('') + '</div>';
}
function _bcViewToggleHtml() {
  const v = _bcView;
  const b = (key, label, icon) => '<button type="button" class="bo-view-btn' + (v === key ? ' is-on' : '') + '" aria-pressed="' + (v === key) + '" data-bc-act="view-' + key + '">' +
    '<span class="bo-view-icon ' + icon + '" aria-hidden="true"><i></i><i></i><i></i><i></i></span>' + label + '</button>';
  return '<div class="bo-view" role="group" aria-label="보기 방식">' + b('list', '리스트', 'is-list') + b('card', '카드', 'is-card') + '</div>';
}
function _bcStateHtml(kind, title, desc, btn) {
  return '<div class="bo-state" ' + (kind === 'error' ? 'role="alert"' : '') + '>' +
    '<span class="bo-state-icon is-' + kind + '" aria-hidden="true">' +
      (kind === 'error' ? '!' : '<span class="material-icons-round notranslate" translate="no">campaign</span>') + '</span>' +
    '<p class="bo-state-title">' + brandEsc(title) + '</p>' +
    (desc ? '<p class="bo-state-desc">' + brandEsc(desc) + '</p>' : '') +
    (btn || '') +
  '</div>';
}
function _bcRowsHtml(rows) {
  const body = rows.map(c => {
    const id = brandEsc(c.id);
    return '<tr class="bo-row" data-bc-act="open" data-camp-id="' + id + '" tabindex="0" aria-label="' + brandEsc((c.product || '') + ' 상세 보기') + '">' +
      '<td>' + (brandEsc(c.campaign_no || '') || _bcDash()) + '</td>' +
      '<td>' + (brandEsc(c.product || '') || _bcDash()) + '</td>' +
      '<td>' + (brandEsc(_bcTypeText(c)) || _bcDash()) + '</td>' +
      '<td>' + (brandEsc(_bcChannelText(c)) || _bcDash()) + '</td>' +
      '<td>' + (brandEsc(_bcRange(c.recruit_start, c.deadline, _bcShort)) || _bcDash()) + '</td>' +
      '<td>' + brandEsc(_bcSlotsText(c)) + '</td>' +
      '<td class="c-center">' + (brandEsc(brandResultPostedText(c) || '') || _bcDash()) + '</td>' +   // 결과물 게시 — 공개 켜짐이면 검수 완료 / 참여(S11), 아니면 「-」
      '<td class="c-center">' + _bcBadge(c) + '</td>' +
      '<td class="c-act"><button type="button" class="bo-detail-btn" data-bc-act="open" data-camp-id="' + id + '">상세</button></td>' +
    '</tr>';
  }).join('');
  return '<div class="bo-table-scroll"><table class="bo-table bc-table">' +
    '<thead><tr><th class="w-no">캠페인 번호</th><th class="w-prod">제품</th><th class="w-type">모집 형식</th><th class="w-ch">채널</th>' +
    '<th class="w-period">모집 기간</th><th class="w-slots">선정 / 정원</th><th class="w-res">결과물 게시</th><th class="w-st">상태</th><th class="w-act">관리</th></tr></thead>' +
    '<tbody>' + body + '</tbody></table></div>' +
    '<p class="bc-note">결과물 게시 = 검수까지 끝난 결과물 수 / 참여 인원입니다. 담당자가 결과물을 공개한 캠페인만 보입니다. 게시물 목록은 캠페인 상세의 「결과물」에서 봅니다.</p>';
}
function _bcBarRow(label, valueHtml, pct) {
  return '<div class="bc-bar-row"><div class="bo-card-info-row"><span class="bo-card-info-label">' + brandEsc(label) + '</span>' +
    '<span class="bo-card-info-val bc-bar-val">' + valueHtml + '</span></div>' +
    '<div class="bc-bar" aria-hidden="true"><i style="width:' + pct + '%"></i></div></div>';
}
function _bcCardsHtml(rows) {
  return '<div class="bo-cards">' + rows.map(c => {
    const sub = [_bcTypeText(c), _bcChannelText(c)].filter(Boolean).join(' · ');
    return '<article class="bo-card">' +
      '<button type="button" class="bo-card-hit" data-bc-act="open" data-camp-id="' + brandEsc(c.id) + '" aria-label="' + brandEsc((c.product || '') + ' ' + _bcStatus(c).label + ' 상세 보기') + '"></button>' +
      '<div class="bo-card-top"><span class="bo-card-no">' + brandEsc(c.campaign_no || '') + '</span>' + _bcBadge(c) + '</div>' +
      '<div class="bo-card-title"><div><p class="bo-card-name">' + brandEsc(c.product || '') + '</p>' +
        (sub ? '<p class="bo-card-sub">' + brandEsc(sub) + '</p>' : '') + '</div>' +
        '<span class="bo-card-chev" aria-hidden="true">›</span></div>' +
      '<div class="bo-card-info">' +
        '<div class="bo-card-info-row"><span class="bo-card-info-label">모집 기간</span><span class="bo-card-info-val">' +
          (brandEsc(_bcRange(c.recruit_start, c.deadline, _bcShort)) || _bcDash()) + '</span></div>' +
        _bcBarRow('선정 / 정원', '<b>' + brandEsc(_bcSlotsText(c)) + '</b>', _bcSlotsPct(c)) +
        _bcBarRow('결과물 게시', brandResultPostedText(c) ? '<b>' + brandEsc(brandResultPostedText(c)) + '</b>' : _bcDash(), brandResultPostedPct(c)) +
      '</div>' +
    '</article>';
  }).join('') + '</div>';
}
function _bcTabEmpty(tab) {
  const t = BRAND_CAMP_TABS.find(x => x.key === tab);
  return { title: (t ? t.label : '') + '인 캠페인이 없습니다', desc: '「전체」 탭에서 모든 캠페인을 볼 수 있습니다.' };
}

function renderBrandCampaignList(host) {
  const d = _bcList;
  const loading = d === undefined || (d && d.brandId !== getCurrentBrandId());
  const list = (!loading && d) ? d.campaigns : null;
  const view = _bcEffectiveView();
  let body, shown = null;
  if (loading) body = '<div class="bo-state" aria-busy="true"><p class="bo-state-desc">불러오는 중…</p></div>';
  else if (d === null) body = _bcStateHtml('error', BRAND_CAMP_MSG.loadFailTitle, BRAND_CAMP_MSG.loadFailDesc,
    '<button type="button" class="brand-btn bo-state-btn" data-bc-act="retry-list">다시 시도</button>');
  else if (!list.length) body = _bcStateHtml('empty', BRAND_CAMP_MSG.emptyTitle, BRAND_CAMP_MSG.emptyDesc, '');
  else {
    const rows = list.filter(c => brandCampaignInTab(c, _bcTab));
    shown = rows.length;
    if (!rows.length) { const e = _bcTabEmpty(_bcTab); body = _bcStateHtml('empty', e.title, e.desc, ''); }
    else body = view === 'card' ? _bcCardsHtml(rows) : _bcRowsHtml(rows);
  }
  host.innerHTML = '<div class="bo-page bc-page">' + _bcHeadHtml() + _bcTabsHtml(list) +
    '<section class="bo-panel" aria-label="캠페인 목록">' +
      '<div class="bo-panel-head"><h2>캠페인 목록' + (shown != null ? '<span class="bo-tab-count">' + shown + '</span>' : '') + '</h2>' +
        _bcViewToggleHtml() + '</div>' +
      '<div class="bo-list is-' + view + '">' + body + '</div>' +
    '</section></div>';
}

async function loadBrandCampaignList() {
  const brandId = getCurrentBrandId();
  if (!brandId) return;
  const seq = ++_bcListSeq;
  if (!_bcList || _bcList.brandId !== brandId) { _bcList = undefined; _bcRerenderIfShown(); }
  const { data, error } = await brandRpc('get_my_brand_campaigns', { p_brand_id: brandId });
  if (seq !== _bcListSeq) return;   // 그사이 브랜드가 바뀌거나 다시 불렀다
  if (!error && data && data.success === false && data.reason === 'not_found') {
    _bcList = null;
    const state = await refreshBrandLoginState();   // 연결이 풀렸으면 판정이 다른 브랜드·안내로 보낸다(오리엔시트 목록과 같다)
    if (state && state.state === 'ok' && getCurrentBrandId() !== brandId) return;
    _bcRerenderIfShown();
    return;
  }
  if (error || !data || data.success !== true || !Array.isArray(data.campaigns)) { _bcList = null; _bcRerenderIfShown(); return; }
  _bcList = { brandId, today: data.today || null, campaigns: data.campaigns };
  _bcRerenderIfShown();
}

// ── 상세 그리기
function _bcStatCard(label, value, sub) {
  return '<div class="bc-stat"><p class="bc-stat-label">' + brandEsc(label) + '</p>' +
    '<p class="bc-stat-value">' + value + '</p>' +
    '<p class="bc-stat-sub">' + (sub ? brandEsc(sub) : '&nbsp;') + '</p></div>';
}
function _bcStatsHtml(c, today) {
  const isMonitor = c.recruit_type === 'monitor';
  const applied = Number(c.applied_count) || 0;
  const approved = Number(c.approved_count) || 0;
  const slots = c.slots != null && c.slots !== '' ? Number(c.slots) : null;

  let appliedSub = '';
  if (c.status === 'active' && c.deadline) {
    const n = _bcDayDiff(today, c.deadline);
    appliedSub = n == null ? '' : n <= 0 ? '오늘 모집 마감' : '모집 마감까지 D-' + n;
  } else if (c.status === 'scheduled' && c.recruit_start) appliedSub = '모집 시작 ' + _bcShort(c.recruit_start);
  else if (c.deadline) appliedSub = '모집 마감 ' + _bcShort(c.deadline);

  let slotSub = '';
  if (slots && approved >= slots) slotSub = isMonitor ? '정원 모두 참여' : '정원 모두 선정';
  else if (!isMonitor && (c.status === 'scheduled' || c.status === 'active')) slotSub = '선정은 모집 마감 뒤 진행';

  // S25 — 외부 참가자가 있으면 숫자를 나눠 적는다(기록용이면 「외부 참가자만」)
  const ext = Number(c.ext_participants) || 0;
  if (brandCampaignIsRecordOnly(c)) appliedSub = '외부 참가자만 (REVERB 모집 없음)';
  else if (ext > 0) {
    appliedSub = 'REVERB ' + (Number(c.applied_reverb) || 0) + ' + 외부 참가자 ' + ext;
    slotSub = 'REVERB ' + (Number(c.approved_reverb) || 0) + ' + 외부 참가자 ' + ext;
  }
  const posted = brandResultPostedText(c);
  const postedSub = brandResultsSuspended(c) ? '열람이 정지되었습니다' : posted ? '검수 완료 기준' : '결과가 공개되면 보입니다';

  const year = _bcYmd(c.deadline || c.recruit_start).slice(0, 4);
  const periodSub = (year ? year + '년' : '') + (c.status === 'ended' ? (year ? ' · ' : '') + '종료' : '');

  return '<div class="bc-stats">' +
    _bcStatCard('응모', brandEsc(applied + '명'), appliedSub) +
    _bcStatCard(isMonitor ? '참여 / 정원' : '선정 / 정원', brandEsc(approved + ' / ' + (slots != null ? slots + '명' : '-')), slotSub) +
    _bcStatCard('결과물 게시', brandEsc(posted || '-'), postedSub) +   // S11 — 공개 켜짐이면 검수 완료 / 참여 합계, 아니면 「-」
    _bcStatCard('모집 기간', brandEsc(_bcRange(c.recruit_start, c.deadline, _bcShort) || '-'), periodSub) +
  '</div>';
}
function _bcStagesHtml(c, today) {
  const { stages, cur } = brandCampaignStages(c, today);
  return '<section class="bc-card"><h2 class="bc-card-title">진행 단계</h2>' +
    '<ol class="bc-steps" style="--bc-steps:' + stages.length + '">' + stages.map((s, i) => {
      const cls = i < cur ? 'is-done' : i === cur ? 'is-current' : 'is-todo';
      return '<li class="bc-step ' + cls + '"' + (i === cur ? ' aria-current="step"' : '') + '>' +
        '<span class="bc-step-dot" aria-hidden="true"></span>' +
        '<span class="bc-step-name">' + brandEsc(s.label) + '</span>' +
        '<span class="bc-step-date">' + (s.date ? brandEsc(s.date) : '&nbsp;') + '</span></li>';
    }).join('') + '</ol></section>';
}
function _bcScheduleHtml(c) {
  const rows = [];
  const row = (k, v) => rows.push('<div class="bc-sched-row"><dt>' + brandEsc(k) + '</dt><dd>' + (v ? brandEsc(v) : _bcDash()) + '</dd></div>');
  row('모집 기간', _bcRange(c.recruit_start, c.deadline, _bcFull));
  // 선정 발표 — 인플루언서 상세와 같은 조건(_bcHasSelection) + 값이 있을 때만
  if (_bcHasSelection(c) && (c.selection_start || c.selection_end)) {
    row('선정 발표', c.selection_end ? _bcFull(c.selection_end) + ' 까지' : _bcFull(c.selection_start) + ' ~');
  }
  if (c.recruit_type === 'monitor' && (c.purchase_start || c.purchase_end)) {
    const onQoo10 = String(c.channel || '').split(',').map(s => s.trim()).includes('qoo10');
    row('구매 기간', _bcRange(c.purchase_start, c.purchase_end, _bcFull) + (onQoo10 ? ' (인플루언서가 Qoo10에서 구매)' : ''));
  }
  if (c.recruit_type === 'visit' && (c.visit_start || c.visit_end)) row('방문 기간', _bcRange(c.visit_start, c.visit_end, _bcFull));
  row('결과물 제출 마감', _bcFull(c.submission_end));
  return '<section class="bc-card"><h2 class="bc-card-title">일정</h2><dl class="bc-sched">' + rows.join('') + '</dl></section>';
}
// 숫자 카드만 다시 그린다 — 결과물 조회가 「정지」를 알려 왔을 때(4c 뒤)
function _bcRerenderStatsIfShown() {
  const el = document.querySelector('#brandPageHost .bc-stats');
  if (el && _bcDetail && _bcDetail.state === 'ok') el.outerHTML = _bcStatsHtml(_bcDetail.camp, _bcDetail.today);
}
function _bcBackHtml() {
  return '<a class="bc-back" href="#campaigns"><span aria-hidden="true">‹</span> 캠페인 목록</a>';
}

function renderBrandCampaignDetail(host, id) {
  const d = _bcDetail && _bcDetail.id === id ? _bcDetail : null;
  let inner;
  if (!d || d.state === 'loading') {
    inner = _bcBackHtml() + '<div class="bo-state" aria-busy="true"><p class="bo-state-desc">불러오는 중…</p></div>';
  } else if (d.state === 'error') {
    inner = _bcBackHtml() + _bcStateHtml('error', BRAND_CAMP_MSG.detailFailTitle, BRAND_CAMP_MSG.loadFailDesc,
      '<button type="button" class="brand-btn bo-state-btn" data-bc-act="retry-detail">다시 시도</button>');
  } else if (d.state === 'not_found') {
    inner = _bcBackHtml() + _bcStateHtml('empty', BRAND_CAMP_MSG.notFoundTitle, BRAND_CAMP_MSG.notFoundDesc,
      '<a class="brand-btn bo-state-btn" href="#campaigns">캠페인 목록</a>');
  } else {
    const c = d.camp;
    const sub = [c.campaign_no, _bcTypeText(c), _bcChannelText(c)].filter(Boolean).join(' · ');
    inner = '<div class="bc-detail-head">' + _bcBackHtml() +
        '<div class="bc-detail-title"><h1>' + brandEsc(c.product || '') + '</h1>' + _bcBadge(c) + '</div>' +
        (sub ? '<p class="bc-detail-sub">' + brandEsc(sub) + '</p>' : '') + '</div>' +
      _bcStatsHtml(c, d.today) + _bcStagesHtml(c, d.today) + _bcScheduleHtml(c) + brandResultSectionHtml(c);
  }
  host.innerHTML = '<div class="bc-page bc-detail">' + inner + '</div>';
}

async function loadBrandCampaignDetail(id) {
  const seq = ++_bcDetailSeq;
  if (!_bcDetail || _bcDetail.id !== id || _bcDetail.state !== 'ok') { _bcDetail = { id, state: 'loading' }; _bcRerenderIfShown(); }
  const { data, error } = await brandRpc('get_my_brand_campaign', { p_campaign_id: id });
  if (seq !== _bcDetailSeq) return;
  if (!error && data && data.success === false) { _bcDetail = { id, state: 'not_found' }; _bcRerenderIfShown(); return; }
  if (error || !data || data.success !== true || !data.campaign) { _bcDetail = { id, state: 'error' }; _bcRerenderIfShown(); return; }
  const camp = data.campaign;
  // 다른 내 브랜드의 캠페인이면 그 브랜드로 바꾼 뒤 보여 준다(메일·즐겨찾기 주소로 들어온 경우)
  if (camp.brand_id && camp.brand_id !== getCurrentBrandId()) {
    _bcAutoSwitching = true;
    let r;
    try { r = await switchBrand(camp.brand_id); } finally { _bcAutoSwitching = false; }
    if (seq !== _bcDetailSeq && r === 'ok') return;   // 바꾼 뒤 다시 그리며 새로 받았다
    if (r !== 'ok') { _bcDetail = { id, state: r === 'not_linked' ? 'not_found' : 'error' }; _bcRerenderIfShown(); return; }   // 전환 실패·진행 중은 「다시 시도」
  }
  _bcDetail = { id, state: 'ok', camp, today: data.today || null };
  _bcRerenderIfShown();
  loadBrandCampaignResults(id);   // 결과물 영역(brand-campaign-results.js) — 상세가 그려진 뒤
}

// ── 페이지 등록 · 다시 그리기
function _bcCurrentArg() {
  const parts = splitBrandHash(location.hash.replace(/^#/, ''));
  return parts.page === 'campaigns' ? parts.arg : null;
}
function _bcRender(host, arg) {
  if (arg) renderBrandCampaignDetail(host, arg);
  else renderBrandCampaignList(host);
}
function _bcRerenderIfShown() {
  const arg = _bcCurrentArg();
  if (arg == null || !brandAuthed) return;
  const host = document.getElementById('brandPageHost');
  if (!host) return;
  const a = document.activeElement;
  const keep = a && host.contains(a) && a.dataset ? (a.dataset.bcAct + '|' + (a.dataset.tab || '')) : null;
  _bcRender(host, arg);
  if (keep) {
    const [act, tab] = keep.split('|');
    const el = host.querySelector('[data-bc-act="' + act + '"]' + (tab ? '[data-tab="' + tab + '"]' : ''));
    if (el) el.focus();
  }
}

registerBrandPage('campaigns', {
  title: '캠페인',
  render(host, arg) {
    // 주소의 캠페인 번호 형식을 먼저 거른다 — 형식이 틀리면 서버가 형 변환 오류를 내 「없음」과 모양이 달라진다
    if (arg && !BRAND_UUID_RE.test(arg)) { _bcDetail = { id: arg, state: 'not_found' }; renderBrandCampaignDetail(host, arg); return; }
    _bcRender(host, arg);
    // 들어올 때마다 새로 받는다(운영팀이 캠페인을 등록·변경했을 수 있다)
    if (arg) loadBrandCampaignDetail(arg);
    else loadBrandCampaignList();
  }
});

// 브랜드가 바뀌면 옛 응답을 버리고, 상세를 보던 중이면 목록으로(상세 캠페인은 옛 브랜드 것이다).
//   rerenderCurrentBrandPage 가 이 알림 바로 뒤에 지금 주소로 다시 그리므로 주소만 바꿔 둔다.
//   상세가 스스로 브랜드를 바꾸는 중(_bcAutoSwitching)이면 그대로 둔다.
onBrandChanged(() => {
  _bcList = undefined; _bcListSeq++;
  if (_bcAutoSwitching) return;
  _bcDetail = null; _bcDetailSeq++;
  _brRes = null; _brResSeq++;   // 결과물 영역도 옛 브랜드 것이다
  if (_bcCurrentArg()) history.replaceState(null, '', location.pathname + location.search + '#campaigns');
});
_bcMobileMq.addEventListener('change', () => _bcRerenderIfShown());

// 페이지 안 단추(위임)
document.addEventListener('click', (e) => {
  const el = e.target.closest('#brandPageHost [data-bc-act]');
  if (!el || el.disabled) return;
  const act = el.dataset.bcAct;
  if (act === 'tab') { _bcTab = el.dataset.tab; _bcRerenderIfShown(); return; }
  if (act === 'view-list' || act === 'view-card') {
    _bcView = act === 'view-card' ? 'card' : 'list';
    _bcSaveView(_bcView);
    _bcRerenderIfShown();
    return;
  }
  if (act === 'retry-list') { el.disabled = true; loadBrandCampaignList(); return; }
  if (act === 'retry-detail') { el.disabled = true; const id = _bcCurrentArg(); if (id) loadBrandCampaignDetail(id); return; }
  if (act === 'open') {
    e.stopPropagation();
    const id = el.dataset.campId;
    if (id) location.hash = '#campaigns/' + id;
  }
});
// 리스트 줄은 키보드로도 연다(줄에 초점 — Enter·Space)
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Enter' && e.key !== ' ') return;
  const row = e.target.closest && e.target.closest('#brandPageHost tr.bo-row[data-bc-act="open"]');
  if (!row || e.target !== row) return;
  e.preventDefault();
  if (row.dataset.campId) location.hash = '#campaigns/' + row.dataset.campId;
});
