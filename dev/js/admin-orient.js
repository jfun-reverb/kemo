// ============================================================
// admin-orient.js — 브랜드 셀프 오리엔시트 관리자 발급·조회
// 신규 페인 #adminPane-orient-sheets: 목록 · 발급 모달 · 상세 모달 · 링크 복사
// 사양서 docs/specs/2026-06-18-brand-self-orient-sheet.md §7·§15
// 발급 함수 create_orient_sheet (마이그레이션 195, 2인자, is_admin 가드)
// §15 재설계: 1 링크 = 공통 브랜드 + 카드 N개(카드마다 form_type). data = cards 배열(§15-A)
// ============================================================

let _orientSheets = [];
let _orientBrands = [];      // 발급 모달 브랜드 검색 드롭다운 후보 (osOpenCreate 에서 적재)
let _osDetailSheet = null;   // 상세 모달에 열린 시트(카드별 발행에 사용)
let _osDetailCampMap = {};   // 발행 카드 campaign_id → {campaign_no, title, deleted_at, status} (osOpenDetail 로드, 맵에 없으면 완전삭제)
let _osDetailCatMap = {};    // 상세 모달 카테고리 라벨 맵(새창 열기에 재사용)
let _osLastIssuedId = null;  // 방금 발급한 오리엔시트 id(발급 결과 화면 수동 메일 발송용)
let _osLastIssuedBrandId = null;  // 방금 발급한 시트의 브랜드 id(수신자 담당자 로드·저장용)
let _osBrandContacts = [];        // 발급 브랜드의 담당자 배열(드롭다운 소스)
let _osPendingContact = null;     // 발송 성공 후 저장 대기 중인 신규 담당자 {email, name}
let _osMailSentTo = null;         // 이 시트에 이미 메일 발송한 수신 이메일(있으면 같은 수신자엔 버튼 비활성)
let _osPublishCardIdx = null;     // 「이 카드로 발행」 진입 시 대상 카드 인덱스(발행 방식 선택 모달에서 재사용)
// ── 내부 메모(모집 건 카드별, 마이그레이션 295·296) ─────────────────
let _osDetailMemos = [];     // 상세 모달에 열린 시트의 메모 전부(카드에 붙은 것 + 고아 메모)
let _osMemoSummary = {};     // `${시트id}_${카드고유번호}` → {count, unreadCount, latest, latestAt}
let _osMemoDraft = {};       // 작성 중인 새 메모 본문 — 카드 순번(또는 'orphan') 기준
let _osMemoEditDraft = {};   // 수정 중인 메모 본문 — 메모 id 기준

const OS_TYPE_LABEL = { proxy_purchase: '가구매', reviewer: '리뷰어', seeding: '시딩' };
const OS_TYPE_CHIP = {
  proxy_purchase: { color: '#B45309', bg: '#FEF3E2' },
  reviewer:       { color: '#C41E3A', bg: '#FFF0F2' },
  seeding:        { color: '#1D4ED8', bg: '#E7F1FE' },
};
const OS_GRADE_LABEL = { nano: '나노', middle_mega: '미들·메가' };
const OS_STATUS = {
  draft:     { label: '작성 중', color: '#8A8A90', bg: '#F0F0F0' },
  submitted: { label: '제출됨', color: 'var(--green)', bg: '#E8F5E9' },
  consumed:  { label: '발행됨', color: '#5B4B9E', bg: '#ECEAF6' },
  expired:   { label: '만료',   color: '#8A8A90', bg: '#F0F0F0' },
};
// 상태별 탭 (전체 + 4상태). code=null 은 전체
const OS_STATUS_TABS = [
  { code: null, label: '전체' },
  { code: 'draft', label: '작성 중' },
  { code: 'submitted', label: '제출됨' },
  { code: 'consumed', label: '발행됨' },
  { code: 'expired', label: '만료' },
];
let _orientActiveStatusTab = null;
// ⚠️ 이 표는 **시딩 폼의 게시 채널**(`sd.channels`) 라벨용이다 — 캠페인 채널 코드가 아니다.
//    입력 도메인은 sales/orient.html 의 SEEDING_CHANNELS 5종뿐이라 qoo10·lips·atcosme 키는
//    실제로 도달하지 않는다(그 값들은 리뷰어·가구매 폼의 sale.market 몫). 그래서 캠페인 채널
//    코드 정정(atcosme→cosme, osPrefillChannels)의 영향을 받지 않는다. 도달하지 않을 뿐
//    「안 쓰이는 표」는 아니므로, sd.channels 의 값 범위를 넓힐 땐 여기도 함께 봐야 한다.
const OS_CH_LABEL = { instagram_feed: '인스타그램-피드', instagram_reels: '인스타그램-릴스', instagram: '인스타그램', x: 'X', tiktok: '틱톡', youtube: '유튜브', qoo10: 'Qoo10', lips: 'LIPS', atcosme: '@cosme' };

// 운영/개발 sales 도메인 분기 (orient.html SUPABASE_ENV 규칙과 동일)
function osSalesBase() {
  return /^(www\.)?globalreverb\.com$/.test(location.hostname)
    ? 'https://sales.globalreverb.com'
    : 'https://sales-dev.globalreverb.com';
}
function osBuildLink(token) { return osSalesBase() + '/orient?token=' + token; }

// 만료 판정 (조회 함수는 status 미전환 — 클라에서 함께 판정)
function osIsExpired(s) {
  if (s.status === 'consumed') return false;
  if (s.status === 'expired') return true;
  return !!(s.token_expires_at && new Date(s.token_expires_at) < new Date());
}
// 카드 발행 수 — 부분 발행(카드 일부만 발행) 판정용. published = campaign_id 있는 "발행된 카드 수".
// 삭제 경고용 osPublishedCampaignCount(DISTINCT 캠페인 수)와는 목적이 다름(정상 플로우는 카드당 고유 캠페인이라 값 일치).
function osCardCounts(s) {
  const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  return { total: cards.length, published: cards.filter(c => c && c.campaign_id).length };
}
// 상태 배지 — 부분 발행(제출됨 + 카드 일부만 발행)은 「일부 발행 (n/m)」 앰버 배지로 구분
function osStatusOf(s) {
  if (s.status === 'consumed') return OS_STATUS.consumed;
  if (s.status === 'submitted') {
    const { total, published } = osCardCounts(s);
    if (published > 0 && published < total) return { label: `일부 발행 (${published}/${total})`, color: '#B45309', bg: '#FEF3C7' };
    if (published > 0) return OS_STATUS.consumed;  // 전 카드 발행(마이그196 트리거 지연으로 status 미전환 순간) 방어
  }
  if (osIsExpired(s)) return OS_STATUS.expired;
  return OS_STATUS[s.status] || OS_STATUS.draft;
}
// 시트가 특정 탭에 속하는지 — 카드 상태 기준 「다중 소속」. 부분 발행 시트는 미발행 카드(제출됨)와
// 발행된 카드(발행됨)를 동시에 가지므로 제출됨·발행됨 양쪽 탭에 노출된다. (탭 건수 합이 전체보다 클 수 있음)
function osMatchesTab(s, code) {
  if (!code) return true;  // 전체
  const expired = osIsExpired(s) && s.status !== 'consumed';
  const { total, published } = osCardCounts(s);
  switch (code) {
    case 'draft':     return s.status === 'draft' && !expired;
    case 'submitted': return s.status === 'submitted' && (total === 0 || published < total) && !expired;  // 미발행 카드 남음(카드 0개 시트도 제출됨으로)
    case 'consumed':  return published > 0;                                              // 발행된 카드 있음(부분·완전)
    case 'expired':   return expired && published === 0;
    default: return false;
  }
}
function osBrandName(s) { return s.brands ? (s.brands.name || s.brands.name_ja || '-') : '-'; }
function osBadge(st) {
  return `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:${st.color};background:${st.bg}">${st.label}</span>`;
}
function osChLabel(c) { return OS_CH_LABEL[c] || (c || '채널'); }
// 시딩 통합 소구 키워드 — 신규는 seeding.appeal, 없고 옛 seeding.guides 있으면 개행으로 합쳐 하위호환
function osSeedingAppeal(sd) {
  if (sd && sd.appeal != null && sd.appeal !== '') return sd.appeal;
  const guides = Array.isArray(sd && sd.guides) ? sd.guides : [];
  return guides.map(g => ((g && g.guide) || '').trim()).filter(Boolean).join('\n');
}

// 형식 칩 (상세 모달 카드 헤더)
function osTypeChip(ft) {
  if (!ft) return '<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:#8A8A90;background:#F0F0F0">형식 미선택</span>';
  const c = OS_TYPE_CHIP[ft] || OS_TYPE_CHIP.reviewer;
  return `<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:${c.color};background:${c.bg}">${OS_TYPE_LABEL[ft] || esc(ft)}</span>`;
}

// 목록 「형식」 컬럼 — form_type 컬럼은 NULL(카드별 형식)이라 data.cards 를 형식별로 집계
function osCardsSummary(data) {
  const cards = (data && Array.isArray(data.cards)) ? data.cards : [];
  if (!cards.length) return '<span style="color:var(--muted)">미작성</span>';
  const cnt = {};
  cards.forEach(c => { const ft = (c && c.form_type) || 'none'; cnt[ft] = (cnt[ft] || 0) + 1; });
  const parts = ['proxy_purchase', 'reviewer', 'seeding']
    .filter(ft => cnt[ft]).map(ft => `${OS_TYPE_LABEL[ft]} ${cnt[ft]}`);
  if (cnt.none) parts.push(`미선택 ${cnt.none}`);
  return esc(parts.join(' · '));
}

// ── 페인 진입 ──
async function loadOrientSheets() {
  ensureOrientModals();
  const tbody = document.getElementById('orientTableBody');
  if (tbody) tbody.innerHTML = osMsgRow('불러오는 중…');
  try {
    _orientSheets = await fetchOrientSheets();
  } catch (e) {
    console.error('[loadOrientSheets]', e);
    if (tbody) tbody.innerHTML = osMsgRow('목록을 불러오지 못했습니다.');
    return;
  }
  // 메모 집계 — 목록 「메모」 칸의 안 읽은 수. 실패해도 목록은 그린다(메모는 부가 정보).
  try { _osMemoSummary = await fetchOrientMemoSummaries(); } catch (_) { _osMemoSummary = {}; }
  renderOrientSheets();
  refreshOrientBadge(_orientSheets);   // 방금 조회한 목록 재사용 (이중 fetch 방지)
}

// 사이드바 「오리엔시트 현황」 제출 배지 — 미발행 카드가 남은 시트 수(제출됨 탭 기준, 부분 발행 시트도 포함)
// cached: 호출부가 이미 가진 목록(loadOrientSheets). 없으면(부팅 단독 호출) 직접 조회
async function refreshOrientBadge(cached) {
  const el = $('adminOrientSheetsSi');
  if (!el) return;
  let count = 0;
  try {
    const sheets = cached || await fetchOrientSheets();
    count = sheets.filter(s => osMatchesTab(s, 'submitted')).length;   // 미발행 카드 남은 시트(부분 발행 포함)
  } catch (e) { console.error('[refreshOrientBadge]', e); return; }
  const badge = count > 0 ? `<span class="admin-si-badge">${count > 999 ? '999+' : count}</span>` : '';
  el.innerHTML = '<span class="si-icon material-icons-round notranslate" translate="no">assignment_turned_in</span><span class="si-text">오리엔시트 현황</span>' + badge;
}

// ⚠️ colspan 은 목록 제목줄(dev/admin/index.html)의 칸 수와 **항상 같아야** 한다.
//   열을 더하거나 뺄 때 세 곳(제목줄 · osRowHtml 의 각 줄 · 이 안내줄)을 함께 고친다.
//   하나만 고치면 「불러오는 중」·「결과 없음」 줄만 어긋나 보인다.
function osMsgRow(msg) {
  return `<tr><td colspan="9" style="text-align:center;color:var(--muted);padding:24px">${esc(msg)}</td></tr>`;
}

function renderOrientSheets() {
  const tbody = document.getElementById('orientTableBody');
  if (!tbody) return;
  const q = (document.getElementById('orientSearch')?.value || '').trim().toLowerCase();
  // 검색 적용 후 base → 상태별 건수 계산 → 탭 렌더
  const base = _orientSheets.filter(s => !q || osBrandName(s).toLowerCase().includes(q));
  // 탭별 다중 소속 건수 — 부분 발행 시트는 제출됨·발행됨 양쪽에 카운트되므로 합이 전체보다 클 수 있음
  const counts = {};
  OS_STATUS_TABS.forEach(tab => { if (tab.code) counts[tab.code] = base.filter(s => osMatchesTab(s, tab.code)).length; });
  renderOrientStatusTabs(counts, base.length);

  // 선택된 상태 탭으로 필터 (다중 소속)
  const list = base.filter(s => osMatchesTab(s, _orientActiveStatusTab));

  const cnt = document.getElementById('orientTotalCount');
  if (cnt) cnt.textContent = list.length ? `${list.length}건` : '';

  if (!list.length) {
    const emptyMsg = (q && !base.length) ? '검색 결과가 없습니다.'
      : (_orientActiveStatusTab ? '해당 상태의 오리엔시트가 없습니다.'
        : '발급된 오리엔시트가 없습니다. 「신규 발급」으로 링크를 만들어 주세요.');
    tbody.innerHTML = osMsgRow(emptyMsg);
    return;
  }
  tbody.innerHTML = list.map(osRowHtml).join('');
}

// 상태 탭 바 렌더 (counts: 탭별 건수[다중 소속], totalAll: 전체 시트 수 — 탭별 합과 다를 수 있음)
function renderOrientStatusTabs(counts, totalAll) {
  const bar = document.getElementById('orientStatusTabBar');
  if (!bar) return;
  counts = counts || {};
  totalAll = totalAll || 0;
  bar.innerHTML = OS_STATUS_TABS.map(tab => {
    const n = tab.code === null ? totalAll : (counts[tab.code] || 0);
    const isOn = tab.code === _orientActiveStatusTab;
    const cls = 'status-tab-btn' + (isOn ? ' on' : '') + (n === 0 && tab.code !== null ? ' zero-count' : '');
    return `<button type="button" class="${cls}" data-status="${tab.code || ''}" onclick="setOrientStatusTab(this)">`
      + `${esc(tab.label)}<span class="tab-count">(${n})</span></button>`;
  }).join('');
}

// 상태 탭 클릭
function setOrientStatusTab(btn) {
  _orientActiveStatusTab = btn.dataset.status || null;   // 빈 문자열(전체)이면 null
  renderOrientSheets();
}

function osRowHtml(s) {
  const linkBadge = s.application_id
    ? ' <span style="display:inline-block;padding:1px 6px;border-radius:999px;font-size:10px;color:#8A8A90;background:#F0F0F0">신청연결</span>' : '';
  return `<tr>
    <td style="font-weight:700;color:var(--ink);white-space:nowrap">${s.orient_no ? esc(s.orient_no) : '-'}</td>
    <td>${esc(osBrandName(s))}${linkBadge}</td>
    <td>${osCardsSummary(s.data)}</td>
    <td>${osBadge(osStatusOf(s))}</td>
    <td>${s.created_at ? formatDate(s.created_at) : '-'}</td>
    <td>${s.token_expires_at ? formatDate(s.token_expires_at) : '-'}</td>
    <td>${s.submitted_at ? formatDateTime(s.submitted_at) : '-'}</td>
    <td style="text-align:center">${osRowMemoCell(s)}</td>
    <td style="white-space:nowrap">
      ${(!osIsExpired(s) && s.status !== 'consumed') ? `<button type="button" class="btn btn-ghost btn-xs" onclick="osReopenSendMail('${s.id}')"><span class="material-icons-round notranslate" translate="no" style="font-size:13px;vertical-align:-2px">mail</span> 메일</button>` : ''}
      <button type="button" class="btn btn-ghost btn-xs" onclick="osCopyLink('${s.id}')">링크 복사</button>
      <button type="button" class="btn btn-ghost btn-xs" onclick="osOpenDetail('${s.id}')">상세</button>
      <button type="button" class="btn btn-ghost btn-xs" style="color:#C41E3A" onclick="osOpenDelete('${s.id}')">삭제</button>
    </td>
  </tr>`;
}

// 목록 「메모」 칸 — 시트 단위 안 읽은 수 배지.
//   0이면 아무것도 안 그린다(늘 떠 있는 숫자는 눈에 안 들어온다).
//   집계는 카드 단위로 오므로 이 시트에 속한 것만 합산한다 —
//   카드가 지워진 고아 메모도 그 시트 몫으로 잡힌다(집계가 카드 목록으로 안 거름).
function osRowMemoCell(s) {
  const total = osSheetMemoCount(s.id);
  const unread = osSheetUnreadCount(s.id);
  // 메모가 있으면 아이콘이 진해지고, 안 읽은 게 있으면 아이콘 우측 위에 수가 붙는다.
  //   숫자만 덩그러니 두면 그게 무엇의 수인지 알 수 없어 아이콘을 기준으로 삼는다.
  const tip = total
    ? `내부 메모 ${total}개${unread ? ` · 아직 열어보지 않음 ${unread}개` : ''}`
    : '내부 메모 없음';
  // ⚠️ 스타일을 인라인으로 둔다 — .os-memo-unread 클래스는 상세 모달 본문에 함께
  //    끼워 넣는 <style> 안에만 있어서 목록에는 적용되지 않는다.
  return `<span title="${esc(tip)}" style="position:relative;display:inline-flex;align-items:center;justify-content:center;width:24px;height:24px">`
    + `<span class="material-icons-round notranslate" translate="no" style="font-size:19px;color:${total ? '#161618' : '#dcdce0'}">sticky_note_2</span>`
    + (unread
        ? `<span style="position:absolute;top:-3px;right:-5px;min-width:15px;height:15px;padding:0 4px;`
          + `border-radius:999px;background:var(--pink,#E91E63);color:#fff;font-size:9.5px;font-weight:800;`
          + `line-height:15px;text-align:center;box-sizing:border-box;box-shadow:0 0 0 1.5px #fff">${unread > 99 ? '99+' : unread}</span>`
        : '')
    + '</span>';
}

// 그 시트에 달린 메모 총 개수(안 읽은 수가 아니라 전체 — 삭제 경고에 쓴다)
function osSheetMemoCount(sheetId) {
  const prefix = sheetId + '_';
  let n = 0;
  Object.keys(_osMemoSummary || {}).forEach(k => {
    if (k.indexOf(prefix) === 0) n += (_osMemoSummary[k].count || 0);
  });
  return n;
}

function osSheetUnreadCount(sheetId) {
  const prefix = sheetId + '_';
  let n = 0;
  Object.keys(_osMemoSummary || {}).forEach(k => {
    if (k.indexOf(prefix) === 0) n += (_osMemoSummary[k].unreadCount || 0);
  });
  return n;
}

// 시트에 연결된 발행 캠페인 수 (data.cards[].campaign_id DISTINCT)
function osPublishedCampaignCount(s) {
  const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const ids = new Set();
  cards.forEach(c => { if (c && c.campaign_id) ids.add(c.campaign_id); });
  return ids.size;
}

function osCopyLink(id) {
  const s = _orientSheets.find(x => x.id === id);
  if (!s) return;
  copyTextToClipboard(osBuildLink(s.token), '작성 링크가 복사되었습니다.');
}

// 이미 발급된 시트의 발급 결과(링크·수신자·메일 발송) 모달을 다시 연다 — 발급 직후 메일을 못 보내고 닫았을 때 재발송용.
async function osReopenSendMail(id) {
  const s = _orientSheets.find(x => x.id === id);
  if (!s) return;
  ensureOrientModals();
  // 발급 폼은 숨기고 결과 화면만 — 새 발급이 아니라 기존 시트 재발송
  document.getElementById('osCreateForm').style.display = 'none';
  document.getElementById('osCreateResult').style.display = '';
  const submitBtn = document.getElementById('osCreateSubmitBtn');
  if (submitBtn) submitBtn.style.display = 'none';
  document.getElementById('osCreateLink').value = osBuildLink(s.token);
  document.getElementById('osCreateExpire').textContent = s.token_expires_at ? formatDate(s.token_expires_at) : '';
  const box = document.getElementById('osCreateMailStatus'); if (box) box.innerHTML = '';
  _osLastIssuedId = s.id;
  _osLastIssuedBrandId = s.brand_id;
  _osPendingContact = null;
  // 이미 발송한 시트면 발송 일시 표시 + 같은 수신자엔 버튼 비활성
  _osMailSentTo = s.mail_sent_at ? (s.mail_sent_to || null) : null;
  if (s.mail_sent_at && box) {
    box.innerHTML = '<div style="color:var(--muted);font-size:13px">'
      + esc(s.mail_sent_to || '수신자') + '에게 ' + formatDateTime(s.mail_sent_at) + ' 발송함</div>';
  }
  // 브랜드만 선택 건만 수신자 선택 UI (신청 연결 건은 자동 결정)
  if (!s.application_id) { osLoadRecipients(s.brand_id); }   // 내부 osOnRecipientChange 가 버튼 상태 갱신
  else { const pick = document.getElementById('osRecipientPick'); if (pick) pick.style.display = 'none'; osUpdateSendBtnState(); }
  const title = document.getElementById('osCreateTitle'); if (title) title.textContent = '메일 재발송';
  document.getElementById('orientCreateModal').classList.add('open');
}

// ── 발급 모달 ──
// 발급 모달 열기. opts 로 진입점별 컨텍스트 주입:
//   {} (무인자)          — #orient-sheets "신규 발급": 브랜드·신청 자유 선택
//   {brandId, appId}     — 서베이 목록 더보기: 신청 연결 고정
//   {brandId, lockBrand} — 브랜드 관리: 브랜드 고정·신청 없음
// 형식·제품은 발급 시 정하지 않음 — 브랜드가 작성 폼에서 카드마다 직접 고름(§15-11).
async function osOpenCreate(opts) {
  opts = opts || {};
  ensureOrientModals();
  document.getElementById('osCreateApp').innerHTML = '<option value="">연결 안 함</option>';
  document.getElementById('osCreateResult').style.display = 'none';
  document.getElementById('osCreateForm').style.display = '';
  document.getElementById('osCreateSubmitBtn').style.display = '';
  const title = document.getElementById('osCreateTitle'); if (title) title.textContent = '오리엔시트 링크 발급';
  document.getElementById('orientCreateModal').classList.add('open');
  // 브랜드 검색 드롭다운 초기화 (검색형 combobox — hidden #osCreateBrand 가 선택 brand_id 보관)
  const brandInput = document.getElementById('osCreateBrandInput');
  document.getElementById('osCreateBrand').value = '';
  document.getElementById('osCreateBrandList').classList.remove('open');
  brandInput.value = '';
  brandInput.disabled = false;
  brandInput.placeholder = '불러오는 중…';
  try {
    _orientBrands = await fetchBrands() || [];
    brandInput.placeholder = '브랜드명 검색 후 선택';
  } catch (e) {
    _orientBrands = [];
    brandInput.placeholder = '브랜드 조회 실패';
  }
  // 진입점 ②③ 컨텍스트 주입: 브랜드 고정 + (있으면) 신청 연결 선택
  if (opts.brandId) {
    osSelectBrand(opts.brandId, { silent: true });   // silent: 신청 연결 로드는 아래에서 직접 제어
    if (opts.lockBrand) brandInput.disabled = true;
    if (opts.appId) {
      await osOnBrandChange();
      document.getElementById('osCreateApp').value = opts.appId;
    }
  }
}

// 진입점 ② — 브랜드 서베이(신청) 목록 더보기 「오리엔시트 링크생성」.
// admin-brand.js 의 _brandApps 캐시에서 신청을 찾아 브랜드·신청을 주입하며 발급 모달을 연다.
// (형식·제품은 발급 시 미지정 — 브랜드가 작성 폼에서 카드마다 선택)
function osIssueFromApplication(appId) {
  const apps = (typeof _brandApps !== 'undefined' && Array.isArray(_brandApps)) ? _brandApps : [];
  const a = apps.find(x => x.id === appId);
  if (!a) { toast('신청 정보를 찾을 수 없습니다. 목록을 새로고침해 주세요.'); return; }
  if (!a.brand_id) { toast('이 신청은 브랜드가 연결돼 있지 않아 오리엔시트를 발급할 수 없습니다.'); return; }
  osOpenCreate({ appId: appId, brandId: a.brand_id });
}

async function osOnBrandChange() {
  const brandId = document.getElementById('osCreateBrand').value;
  const appSel = document.getElementById('osCreateApp');
  appSel.innerHTML = '<option value="">연결 안 함</option>';
  if (!brandId) return;
  try {
    const apps = await fetchBrandApplicationsByBrand(brandId);
    appSel.innerHTML += (apps || []).map(a =>
      `<option value="${a.id}">${esc(osAppLabel(a))}</option>`).join('');
  } catch (e) { /* 연결 없이도 발급 가능 — 무시 */ }
}

function osAppLabel(a) {
  const t = a.form_type ? OS_TYPE_LABEL[a.form_type] : '';
  const d = a.created_at ? formatDate(a.created_at) : '';
  return [d, t].filter(Boolean).join(' · ') || '신청';
}

// ── 브랜드 검색 드롭다운 (combobox) — .admin-proxy-combobox 패턴 재사용 ──
function osBrandShowList() {
  const input = document.getElementById('osCreateBrandInput');
  if (!input || input.disabled) return;   // 진입점 ②③ 잠긴 브랜드면 열지 않음
  document.getElementById('osCreateBrandList').classList.add('open');
  _osRenderBrandList(input.value);
}

function osBrandInput() {
  // 검색어 입력 = 선택 확정 전 상태. 선택 brand_id 비우고 신청 연결도 초기화.
  document.getElementById('osCreateBrand').value = '';
  const appSel = document.getElementById('osCreateApp');
  if (appSel) appSel.innerHTML = '<option value="">연결 안 함</option>';
  _osRenderBrandList(document.getElementById('osCreateBrandInput').value);
  document.getElementById('osCreateBrandList').classList.add('open');
}

function _osRenderBrandList(query) {
  const list = document.getElementById('osCreateBrandList');
  if (!list) return;
  const q = (query || '').trim().toLowerCase();
  const matched = (_orientBrands || []).filter(b =>
    (typeof matchSearchTokens === 'function')
      ? matchSearchTokens(q, [b.name, b.name_ja, b.name_en])
      : (!q || (b.name || '').toLowerCase().includes(q)));
  if (!matched.length) {
    // 검색 결과 0건 → 바로 신규 등록으로 이어갈 수 있게 버튼 노출
    // (onmousedown + preventDefault: 입력칸이 blur 되기 전에 눌리도록)
    // 권한 가드 없음 — brands INSERT 정책이 is_admin() 이고, 기존 브랜드 등록 진입점
    // 3곳(캠페인 신규·편집 폼, 브랜드 관리 페인)도 관리자 전원에게 열려 있어 그와 맞춘다.
    list.innerHTML = '<div class="empty">일치하는 브랜드가 없습니다'
      + '<div style="margin-top:8px">'
      + '<button type="button" class="btn btn-ghost btn-sm" onmousedown="event.preventDefault();osOpenNewBrand()"'
      + ' style="display:inline-flex;align-items:center;gap:4px">'
      + '<span class="material-icons-round notranslate" translate="no" style="font-size:15px">add</span>신규 브랜드 추가</button>'
      + '</div></div>';
    return;
  }
  list.innerHTML = matched.slice(0, 100).map(b => {
    const name = esc(b.name || b.name_ja || b.name_en || '-');
    const sub = [(b.name_ja && b.name_ja !== b.name) ? b.name_ja : '', b.company_name || '']
      .filter(Boolean).join(' · ');
    return `<div class="item" onmousedown="osSelectBrand('${esc(b.id)}')">
      <div>${name}</div>${sub ? `<div class="item-meta">${esc(sub)}</div>` : ''}</div>`;
  }).join('');
}

// 항목 선택: hidden #osCreateBrand 에 id, 입력칸에 브랜드명 표기, 리스트 닫기.
// silent=true 면 신청 연결 로드(osOnBrandChange)를 호출부가 직접 제어(진입점 ②③).
function osSelectBrand(id, opts2) {
  opts2 = opts2 || {};
  const b = (_orientBrands || []).find(x => String(x.id) === String(id));
  document.getElementById('osCreateBrand').value = id || '';
  const input = document.getElementById('osCreateBrandInput');
  if (input) input.value = b ? (b.name || b.name_ja || b.name_en || '-') : '';
  const list = document.getElementById('osCreateBrandList');
  if (list) list.classList.remove('open');
  if (!opts2.silent) osOnBrandChange();
}

// 검색 결과 0건에서 「신규 브랜드 추가」 — 브랜드 등록 모달을 발급 모달 위에 띄운다
// (brandDetailModal z-index 612 > 발급 모달 500). 등록 완료 시 submitNewBrand 가
// osAfterNewBrand(id) 로 되돌려 목록 갱신·자동 선택까지 이어진다.
async function osOpenNewBrand() {
  const input = document.getElementById('osCreateBrandInput');
  const q = (input && input.value || '').trim();
  const list = document.getElementById('osCreateBrandList');
  if (list) list.classList.remove('open');
  if (typeof openNewBrandModal !== 'function') { toast('브랜드 등록 화면을 열 수 없습니다.'); return; }
  await openNewBrandModal('orient');
  const nameEl = document.getElementById('brandFormName');
  if (nameEl && q) nameEl.value = q;   // 입력한 검색어를 브랜드명 초안으로
}

// 브랜드 등록 완료 후 호출 (admin-brand.js submitNewBrand)
// 브랜드 목록을 다시 받아 방금 만든 브랜드를 발급 모달에 자동 선택.
async function osAfterNewBrand(brandId) {
  if (!document.getElementById('orientCreateModal')) return;
  try { _orientBrands = await fetchBrands() || []; } catch (e) { /* 갱신 실패해도 선택은 시도 */ }
  osSelectBrand(brandId);
  toast('브랜드가 선택되었습니다.');
}

async function osSubmitCreate() {
  const brandId = document.getElementById('osCreateBrand').value;
  if (!brandId) { toast('브랜드를 선택해 주세요.'); return; }
  const appId = document.getElementById('osCreateApp').value || null;
  const btn = document.getElementById('osCreateSubmitBtn');
  btn.disabled = true;
  try {
    const res = await createOrientSheet(brandId, appId);
    if (!res || res.success !== true) { toast('발급 실패: ' + osReasonText(res?.reason)); return; }
    document.getElementById('osCreateLink').value = osBuildLink(res.token);
    document.getElementById('osCreateExpire').textContent = res.token_expires_at ? formatDate(res.token_expires_at) : '';
    const onEl = document.getElementById('osCreateOrientNo'); if (onEl) onEl.textContent = res.orient_no || '-';
    document.getElementById('osCreateForm').style.display = 'none';
    document.getElementById('osCreateResult').style.display = '';
    btn.style.display = 'none';
    _osLastIssuedId = res.id;   // 발급 결과 화면의 「메일 발송」 버튼이 사용 (자동 발송 안 함 — 수동 선택)
    _osLastIssuedBrandId = brandId;
    _osPendingContact = null;
    _osMailSentTo = null;   // 방금 발급 — 아직 미발송
    // 브랜드만 선택한 건만 수신자 선택 UI 노출 (신청 연결 건은 신청 담당자 이메일 자동)
    if (!appId) { osLoadRecipients(brandId); }
    else { const pick = document.getElementById('osRecipientPick'); if (pick) pick.style.display = 'none'; osUpdateSendBtnState(); }
    await refreshPane('orient-sheets');
  } catch (e) {
    toast(typeof friendlyError === 'function' ? friendlyError(e) : '발급에 실패했습니다.');
  } finally {
    btn.disabled = false;
  }
}

function osReasonText(r) {
  return ({
    brand_not_found: '브랜드를 찾을 수 없습니다',
    brand_seq_missing: '브랜드 식별번호가 없습니다 (관리자에게 문의)',
    application_not_found: '신청을 찾을 수 없습니다',
    brand_mismatch: '신청과 브랜드가 일치하지 않습니다',
    no_db: '연결 오류',
  })[r] || (r || '알 수 없는 오류');
}

function osCopyResultLink() {
  copyTextToClipboard(document.getElementById('osCreateLink').value, '작성 링크가 복사되었습니다.');
}

// 발급 브랜드의 담당자 로드 → 수신자 드롭다운 채움 (브랜드만 선택 건). 대표 담당자 기본 선택.
async function osLoadRecipients(brandId) {
  const pick = document.getElementById('osRecipientPick');
  const sel = document.getElementById('osRecipientSelect');
  if (!pick || !sel) return;
  _osBrandContacts = [];
  let brand = null;
  try { brand = await fetchBrandById(brandId); } catch (_e) { /* 폴백: 직접 입력만 */ }
  let contacts = (brand && Array.isArray(brand.contacts)) ? brand.contacts.filter(c => c && c.email) : [];
  // contacts 비었는데 legacy primary_email 있으면 대표 1명으로 폴백
  if (!contacts.length && brand && brand.primary_email) {
    contacts = [{ name: brand.primary_contact_name || '', email: brand.primary_email, is_primary: true }];
  }
  _osBrandContacts = contacts;
  const primaryIdx = contacts.findIndex(c => c.is_primary);
  const defIdx = primaryIdx >= 0 ? primaryIdx : 0;
  let html = contacts.map((c, i) =>
    `<option value="${i}">${esc((c.name ? c.name + ' · ' : '') + c.email)}${c.is_primary ? ' (대표)' : ''}</option>`
  ).join('');
  html += '<option value="new">+ 직접 입력</option>';
  sel.innerHTML = html;
  sel.value = contacts.length ? String(defIdx) : 'new';
  pick.style.display = '';
  osOnRecipientChange();
}

// 현재 선택/입력된 수신자 이메일
function osCurrentRecipientEmail() {
  const sel = document.getElementById('osRecipientSelect');
  if (!sel) return '';
  if (sel.value === 'new') return (document.getElementById('osNewContactEmail')?.value || '').trim();
  const c = _osBrandContacts[Number(sel.value)];
  return c ? (c.email || '') : '';
}

// 드롭다운에서 「직접 입력」 선택 시 이름·이메일 입력칸 표시 + 발송 버튼 상태 갱신
function osOnRecipientChange() {
  const sel = document.getElementById('osRecipientSelect');
  const nw = document.getElementById('osRecipientNew');
  if (!sel || !nw) return;
  nw.style.display = (sel.value === 'new') ? 'flex' : 'none';
  osUpdateSendBtnState();
}

// 이미 발송한 시트: 현재 수신자가 발송 대상과 같으면 버튼 비활성, 다르면(수신자 변경) 재활성
function osUpdateSendBtnState() {
  const btn = document.getElementById('osSendMailBtn');
  if (!btn) return;
  const sel = document.getElementById('osRecipientSelect');
  const pick = document.getElementById('osRecipientPick');
  const pickShown = pick && pick.style.display !== 'none';
  // 직접 입력 모드: 이메일이 비었거나 형식이 올바르지 않으면 비활성 (발송 여부 무관)
  if (pickShown && sel && sel.value === 'new') {
    const email = (document.getElementById('osNewContactEmail')?.value || '').trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { btn.disabled = true; return; }
  }
  if (!_osMailSentTo) { btn.disabled = false; return; }
  if (pick && pick.style.display === 'none') { btn.disabled = true; return; }  // 자동 수신자(신청 연결)는 발송됨이면 비활성
  const cur = osCurrentRecipientEmail().trim().toLowerCase();
  btn.disabled = !!(cur && cur === _osMailSentTo.trim().toLowerCase());
}

// 발급 결과 화면 「메일 발송」 버튼 — 선택 발송(자동 발송 아님). 발송 중 버튼 비활성.
async function osSendInviteClick(btn) {
  if (!_osLastIssuedId) return;
  // 브랜드만 선택 건: 드롭다운/직접입력으로 수신자 명시. 신청 연결 건: recipient 없이 자동 결정.
  let recipient = null;
  let isNewContact = false;
  const pick = document.getElementById('osRecipientPick');
  if (pick && pick.style.display !== 'none') {
    const sel = document.getElementById('osRecipientSelect');
    if (sel && sel.value === 'new') {
      const email = (document.getElementById('osNewContactEmail').value || '').trim();
      const name = (document.getElementById('osNewContactName').value || '').trim();
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { toast('올바른 이메일 주소를 입력해 주세요.'); return; }
      // 기존 담당자와 중복이면 재사용(신규 저장 안 함)
      const dup = _osBrandContacts.find(c => (c.email || '').trim().toLowerCase() === email.toLowerCase());
      recipient = dup ? { email: dup.email, name: dup.name || name } : { email, name };
      isNewContact = !dup;
    } else if (sel) {
      const c = _osBrandContacts[Number(sel.value)];
      if (c) recipient = { email: c.email, name: c.name || '' };
    }
    if (!recipient) { toast('수신자를 선택해 주세요.'); return; }
  }
  btn.disabled = true;
  try { await osSendInviteAndShow(_osLastIssuedId, recipient, isNewContact); }
  finally { osUpdateSendBtnState(); }   // 발송 후 상태 재계산(발송됨+같은 수신자면 비활성 유지)
}

// 메일 발송 + 발급 결과 화면에 상태 인라인 표시. 발송은 발급과 별개라 실패해도 발급은 유효(링크 수동 복사).
// 신규 담당자(직접 입력·중복 아님)면 발송 성공 후 「브랜드에 저장 + 대표 설정?」 버튼 노출.
async function osSendInviteAndShow(orientSheetId, recipient, isNewContact) {
  const box = document.getElementById('osCreateMailStatus');
  if (!box) return;
  box.innerHTML = '<span style="color:var(--muted)">메일 발송 중…</span>';
  let r;
  try {
    r = await sendOrientInviteMail(orientSheetId, recipient);
  } catch (e) {
    r = { sent: false, error: (e && e.message) || 'unknown' };
  }
  if (r && r.sent) {
    // 발송 성공 — 일시·수신자 기록(같은 수신자엔 버튼 비활성) + 목록 캐시 즉시 반영
    const sentEmail = (recipient && recipient.email) || r.recipient || '';
    _osMailSentTo = sentEmail || _osMailSentTo;
    const sheet = _orientSheets.find(x => x.id === orientSheetId);
    if (sheet) { sheet.mail_sent_at = new Date().toISOString(); sheet.mail_sent_to = sentEmail; }
    const advNote = r.advanced ? '신청 단계를 「오리엔시트 발송됨」으로 이동했습니다.' : '';
    let html = '<div style="color:var(--green);font-weight:600">메일을 보냈습니다 — ' +
      esc(r.recipient || (recipient && recipient.email) || '') + '</div>' +
      (advNote ? '<div style="color:var(--muted);font-size:12px;margin-top:2px">' + advNote + '</div>' : '');
    if (isNewContact && recipient && recipient.email) {
      _osPendingContact = { email: recipient.email, name: recipient.name || '' };
      html += '<div style="margin-top:10px;padding:10px;background:#FAFAF7;border-radius:8px">'
        + '<div style="font-size:13px;margin-bottom:6px">이 담당자를 브랜드에 저장합니다. 대표 담당자로도 설정할까요?</div>'
        + '<div style="display:flex;gap:6px;flex-wrap:wrap">'
        + '<button type="button" class="btn btn-primary btn-xs" onclick="osSaveIssuedContact(true,this)">대표 담당자로 저장</button>'
        + '<button type="button" class="btn btn-ghost btn-xs" onclick="osSaveIssuedContact(false,this)">담당자로만 저장</button>'
        + '</div></div>';
    }
    box.innerHTML = html;
    osUpdateSendBtnState();
  } else if (r && r.reason === 'no_recipient') {
    box.innerHTML = '<div style="color:#B45309;font-weight:600">수신자 이메일이 없어 메일을 보내지 못했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 브랜드에게 직접 전달해 주세요.</div>';
  } else {
    // 실패 원인(함수가 돌려준 error/reason)을 작게 노출 — 디버깅·재시도 판단용(값 없으면 생략)
    const detail = (r && (r.error || r.reason)) ? '<div style="color:var(--muted);font-size:11px;margin-top:4px">사유: ' + esc(String(r.error || r.reason)) + '</div>' : '';
    box.innerHTML = '<div style="color:#C41E3A;font-weight:600">메일 발송에 실패했습니다.</div>' +
      '<div style="color:var(--muted);font-size:12px;margin-top:2px">위 링크를 복사해 직접 전달하거나, 잠시 후 다시 시도해 주세요.</div>' + detail;
  }
}

// 신규 담당자를 브랜드(brands.contacts)에 저장. asPrimary=true 면 대표로 설정 + legacy primary_* 동기화.
// admin-brand.js 「대표 1개 보장·빈 행 제외」 규칙과 정합. 중복 이메일이면 기존 행 재사용.
async function osSaveIssuedContact(asPrimary, btn) {
  if (!_osPendingContact || !_osLastIssuedBrandId) return;
  if (btn) btn.disabled = true;
  try {
    const brand = await fetchBrandById(_osLastIssuedBrandId);   // 최신 contacts (덮어쓰기 최소화)
    let contacts = (brand && Array.isArray(brand.contacts)) ? brand.contacts.slice() : [];
    const email = (_osPendingContact.email || '').trim();
    let row = contacts.find(c => (c.email || '').trim().toLowerCase() === email.toLowerCase());
    if (!row) {
      const cid = (typeof _genContactId === 'function') ? _genContactId() : ('c' + contacts.length + '_' + email);
      row = { id: cid, name: _osPendingContact.name || '', phone: '', email, is_primary: false };
      contacts.push(row);
    } else if (_osPendingContact.name && !row.name) {
      row.name = _osPendingContact.name;
    }
    if (asPrimary) contacts.forEach(c => { c.is_primary = (c === row); });
    else if (!contacts.some(c => c.is_primary) && contacts.length) contacts[0].is_primary = true;
    const patch = { contacts };
    const primary = contacts.find(c => c.is_primary);
    if (primary) {
      patch.primary_email = primary.email || '';
      patch.primary_contact_name = primary.name || '';
      patch.primary_phone = primary.phone || '';
    }
    await updateBrand(_osLastIssuedBrandId, patch);
    const box = document.getElementById('osCreateMailStatus');
    if (box) box.innerHTML += '<div style="color:var(--green);font-size:12px;margin-top:6px">담당자를 저장했습니다'
      + (asPrimary ? ' (대표 담당자로 설정)' : '') + '.</div>';
    _osPendingContact = null;
  } catch (e) {
    toast(typeof friendlyError === 'function' ? friendlyError(e) : '담당자 저장에 실패했습니다.');
    if (btn) btn.disabled = false;
  }
}

// ── 삭제 모달 (브랜드명 재입력 확인 — 캠페인 삭제 패턴 미러) ──
let _osDeleteId = null;
let _osDeleteBrandName = '';

function osOpenDelete(id) {
  ensureOrientModals();
  const s = _orientSheets.find(x => x.id === id);
  if (!s) { toast('시트 정보를 찾을 수 없습니다. 목록을 새로고침해 주세요.'); return; }
  _osDeleteId = id;
  _osDeleteBrandName = osBrandName(s);
  const campCount = osPublishedCampaignCount(s);

  document.getElementById('osDeleteBrand').textContent = _osDeleteBrandName;
  document.getElementById('osDeleteBrandEcho').textContent = _osDeleteBrandName;
  const warn = document.getElementById('osDeleteCampWarn');
  if (campCount > 0) {
    warn.innerHTML = '이 오리엔시트에 연결된 발행 캠페인 <b>' + campCount + '개</b>도 함께 삭제됩니다. ' +
      '단, 신청이 1건이라도 있는 캠페인이 포함되면 삭제할 수 없습니다.';
    warn.style.display = '';
  } else {
    warn.style.display = 'none';
  }
  // 내부 메모 경고 — 시트를 지우면 메모도 함께 사라진다(연쇄 삭제, 감사 기록 미보존).
  //   ⚠️ 발행 캠페인 경고를 덮어쓰지 않고 별도 요소에 그린다(둘 다 떠야 하는 경우가 있다).
  //   집계는 목록 로드 때 받아 둔 값을 쓴다 — 삭제 창을 여는 데 조회를 한 번 더 하지 않는다.
  const memoWarn = document.getElementById('osDeleteMemoWarn');
  if (memoWarn) {
    const memoCount = osSheetMemoCount(id);
    if (memoCount > 0) {
      memoWarn.innerHTML = '이 오리엔시트에 남긴 <b>내부 메모 ' + memoCount + '개</b>도 함께 삭제됩니다. 되돌릴 수 없습니다.';
      memoWarn.style.display = '';
    } else {
      memoWarn.style.display = 'none';
    }
  }
  const input = document.getElementById('osDeleteConfirmInput');
  input.value = '';
  document.getElementById('osDeleteError').style.display = 'none';
  osCheckDeleteConfirm();
  document.getElementById('orientDeleteModal').classList.add('open');
  input.focus();
}

function osCheckDeleteConfirm() {
  const v = (document.getElementById('osDeleteConfirmInput').value || '').trim();
  const btn = document.getElementById('osDeleteBtn');
  const ok = v === _osDeleteBrandName && !!_osDeleteBrandName;
  btn.disabled = !ok;
  btn.style.opacity = ok ? '1' : '.4';
  btn.style.cursor = ok ? 'pointer' : 'not-allowed';
}

async function osExecuteDelete() {
  const v = (document.getElementById('osDeleteConfirmInput').value || '').trim();
  const err = document.getElementById('osDeleteError');
  if (v !== _osDeleteBrandName) { err.textContent = '브랜드명이 일치하지 않습니다.'; err.style.display = 'block'; return; }
  const btn = document.getElementById('osDeleteBtn');
  btn.disabled = true;
  try {
    const res = await deleteOrientSheet(_osDeleteId);
    if (res && res.success) {
      osCloseModal('orientDeleteModal');
      const n = Array.isArray(res.deleted_campaign_ids) ? res.deleted_campaign_ids.length : 0;
      toast(n > 0 ? ('오리엔시트와 연결 캠페인 ' + n + '개를 삭제했습니다.') : '오리엔시트를 삭제했습니다.', 'success');
      await refreshPane('orient-sheets');
    } else if (res && res.reason === 'blocked_has_applications') {
      const n = Array.isArray(res.campaign_ids) ? res.campaign_ids.length : 0;
      err.textContent = '연결 캠페인 중 신청이 있는 캠페인(' + n + '개)이 있어 삭제할 수 없습니다. 신청을 먼저 정리해 주세요.';
      err.style.display = 'block';
    } else if (res && res.reason === 'permission_denied') {
      err.textContent = '삭제 권한이 없습니다.';
      err.style.display = 'block';
    } else {
      err.textContent = '삭제 실패: ' + ((res && res.reason) || '알 수 없는 오류');
      err.style.display = 'block';
    }
  } catch (e) {
    err.textContent = '삭제 오류: ' + (typeof friendlyError === 'function' ? friendlyError(e.message || e) : (e.message || '오류'));
    err.style.display = 'block';
  } finally {
    osCheckDeleteConfirm();
  }
}

// ── 상세 모달 ──
// 상세 모달 제목 — 브랜드명 + 오리엔 번호.
//   s 가 없으면 기본 문구로 되돌린다(직전에 연 시트의 브랜드명이 로딩 중 화면에 남지 않게).
function osSetDetailTitle(s) {
  const h = document.getElementById('osDetailTitle');
  if (!h) return;
  if (!s) { h.textContent = '오리엔시트 내용'; return; }
  // osBrandName 은 브랜드 정보가 없으면 '-' 를 돌려주므로, 그때는 기본 문구로 대체한다.
  const raw = (osBrandName(s) || '').trim();
  const name = (raw && raw !== '-') ? raw : '오리엔시트 내용';
  const no = s.orient_no
    ? `<span style="font-size:12px;font-weight:700;color:var(--muted);margin-left:8px">${esc(s.orient_no)}</span>`
    : '';
  h.innerHTML = esc(name) + no;
}

async function osOpenDetail(id) {
  ensureOrientModals();
  const body = document.getElementById('osDetailBody');
  body.innerHTML = '<p style="color:var(--muted);padding:20px;width:100%">불러오는 중…</p>';
  osSetDetailTitle(null);
  document.getElementById('orientDetailModal').classList.add('open');
  let s;
  try { s = await fetchOrientSheetById(id); }
  catch (e) { body.innerHTML = '<p style="padding:20px;width:100%">불러오지 못했습니다.</p>'; return; }
  if (!s) { body.innerHTML = '<p style="padding:20px;width:100%">데이터가 없습니다.</p>'; return; }
  _osDetailSheet = s;
  // 발행된 카드의 연결 캠페인 번호·상태 조회 (활성=번호 링크 / 보관삭제=삭제됨 / 맵에 없음=완전삭제)
  try {
    const campIds = ((s.data && s.data.cards) || []).map(c => c && c.campaign_id).filter(Boolean);
    _osDetailCampMap = await fetchCampaignsByIds(campIds);
  } catch (_) { _osDetailCampMap = {}; }
  // 카테고리는 code 로 저장되므로 한국어 라벨로 변환해 표시 (캠페인 폼과 동일 기준 데이터)
  let catMap = {};
  try { const cats = await fetchLookups('category'); catMap = Object.fromEntries((cats || []).map(c => [c.code, c.name_ko])); } catch (_) {}
  _osDetailCatMap = catMap;
  // 내부 메모 — 화면을 그리기 **전에** 받아 둔다.
  //   osCardDetail 은 글자열을 즉시 돌려주는 함수(기다림 없음)라 그 안에서 조회할 수 없다.
  _osMemoDraft = {};
  _osMemoEditDraft = {};
  try {
    _osDetailMemos = await fetchOrientMemos(id);
    _osMemoSummary = await fetchOrientMemoSummaries();
  } catch (_) { _osDetailMemos = []; _osMemoSummary = {}; }
  osSetDetailTitle(s);
  body.innerHTML = osDetailHtml(s, catMap);
  // ⚠️ 읽음 처리는 **화면을 그린 뒤**에 보낸다.
  //   먼저 보내면 안 읽은 수가 0이 되어 「안 읽은 메모가 있으면 자동 펼침」 판정이
  //   전부 거짓이 되고, 놓치지 않게 하는 장치가 죽는다(사양서 §의심 11).
  //   결과로 모달을 다시 그리지도 않는다 — 다시 그리면 펼쳐 둔 것이 접힌다.
  if (_osDetailMemos.length) {
    markOrientMemosRead(id).catch(() => {});
  }
}

// 상세 내용을 브라우저 새창에 읽기 전용으로 출력 (인쇄·나란히 보기 용)
function osOpenDetailNewWindow() {
  const s = _osDetailSheet;
  if (!s) return;
  const inner = osDetailHtml(s, _osDetailCatMap || {}, true);   // readonly=true → 발행 버튼 제외
  const w = window.open('', '_blank');
  if (!w) { toast('팝업이 차단되었습니다. 브라우저에서 팝업을 허용한 뒤 다시 시도해 주세요.'); return; }
  w.document.write('<!DOCTYPE html><html lang="ko"><head><meta charset="utf-8">'
    + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    + '<title>오리엔시트 — ' + esc(osBrandName(s)) + '</title>'
    + '<style>body{font-family:-apple-system,BlinkMacSystemFont,"Apple SD Gothic Neo","Malgun Gothic",sans-serif;'
    + 'margin:0;padding:24px;background:#f5f5f7;color:#161618;max-width:1000px}</style>'
    + '</head><body>' + inner + '</body></html>');
  w.document.close();
}

// 상세 모달 전용 스코프 스타일 (가독성: 항목 구분선 + 라벨/값 위계 + 카드 제목)
const OS_DETAIL_STYLE = `<style>
  .os-detail{container-type:inline-size}
  /* ── 좌우 2단(시트 내용 | 내부 메모) ── */
  /*  각 칸이 자기 스크롤을 갖는다. min-height:0 이 없으면 flex 자식이 안 줄어들어
      스크롤이 안 생기고 바깥이 대신 늘어난다. */
  .os-split{display:flex;flex:1;width:100%;min-height:0;align-items:stretch}
  .os-pane{min-height:0;overflow-y:auto;padding:20px}
  .os-pane-left{flex:1 1 58%;min-width:0;container-type:inline-size}
  .os-pane-right{flex:1 1 42%;min-width:0;border-left:1px solid #ececf0;background:#fbfbfc}
  /*  좁은 화면에서는 위아래로 쌓는다 — 두 칸을 억지로 붙이면 둘 다 못 읽는다.
      이때는 바깥 한 덩어리로 스크롤한다(칸별 스크롤이 겹치면 더 불편하다). */
  @media (max-width:900px){
    .os-split{flex-direction:column;overflow-y:auto}
    .os-pane{overflow:visible}
    .os-pane-right{border-left:0;border-top:1px solid #ececf0}
  }
  /*  메모가 길어져도 이 칸이 무슨 칸인지 보이게 머리줄을 붙여 둔다 */
  .os-memo-panel-title{font-weight:800;font-size:13px;color:#161618;margin-bottom:10px;
    display:flex;align-items:center;gap:6px;position:sticky;top:-20px;z-index:1;
    background:#fbfbfc;padding:20px 0 8px;margin-top:-20px}
  .os-memo-panel-empty{color:var(--muted,#8a8a90);font-size:12.5px;line-height:1.6}
  .os-card{border:1px solid #ececf0;border-radius:12px;padding:14px 16px;margin-bottom:14px;background:#fff}
  .os-card-title{font-weight:800;font-size:14px;color:#161618;margin-bottom:2px}
  .os-card-head{display:flex;align-items:center;gap:8px;margin-bottom:2px;padding-bottom:8px}
  .os-card-head .os-name{font-weight:800;font-size:14.5px;color:#161618;flex:1;min-width:0}
  /* 모달(컨테이너) 너비에 따라 2열/1열 — 브랜드 입력 폼과 동일 반응형 */
  .os-fields{display:grid;grid-template-columns:1fr;gap:0 20px}
  @container (min-width:480px){.os-fields{grid-template-columns:1fr 1fr}}
  .os-fields .os-field{padding:9px 0;border-top:1px solid #f2f2f2;min-width:0}
  .os-field-wide{grid-column:1/-1}
  .os-field-label{color:var(--muted,#8a8a90);font-size:11px;font-weight:700;letter-spacing:.02em;margin-bottom:3px}
  .os-field-val{font-size:13.5px;line-height:1.65;color:#161618;word-break:break-word}
  .os-field-val a{color:var(--pink,#1A1A1A);text-decoration:underline}
  .os-empty{color:#bbb;font-weight:400}
  /* ── 내부 메모 ── */
  .os-memo{border:1px solid #ececf0;border-radius:12px;background:#fff;margin-bottom:10px;padding:10px 12px}
  .os-memo-head{display:flex;align-items:center;gap:6px;width:100%;border:0;background:transparent;
    cursor:pointer;padding:4px 0;font-size:12.5px;font-weight:700;color:#161618;text-align:left}
  .os-memo-head .os-memo-caret{font-size:18px;color:var(--muted,#8a8a90);transition:transform .15s}
  .os-memo.open .os-memo-head .os-memo-caret{transform:rotate(180deg)}
  .os-memo-unread{display:inline-block;min-width:18px;padding:1px 6px;border-radius:999px;
    background:var(--pink,#E91E63);color:#fff;font-size:10.5px;font-weight:800;text-align:center}
  .os-memo-body{display:none;padding:6px 0 2px}
  .os-memo.open .os-memo-body{display:block}
  .os-memo-item{border:1px solid #ececf0;border-radius:10px;padding:8px 10px;margin-bottom:8px;background:#fcfcfd}
  .os-memo-meta{display:flex;align-items:center;gap:6px;font-size:11px;color:var(--muted,#8a8a90);margin-bottom:4px}
  .os-memo-meta .os-memo-author{font-weight:700;color:#161618}
  .os-memo-edited{color:#B45309;font-weight:600}
  .os-memo-text{font-size:13px;line-height:1.65;color:#161618;word-break:break-word}
  .os-memo-text p{margin:0 0 4px}
  .os-memo-text a{color:var(--pink,#1A1A1A);text-decoration:underline}
  .os-memo-acts{display:flex;gap:4px;margin-left:auto;flex-shrink:0}
  .os-memo-empty{color:var(--muted,#8a8a90);font-size:12px;padding:2px 0 8px}
  .os-memo-form{margin-top:6px}
  .os-memo-form-acts{display:flex;justify-content:flex-end;gap:6px;margin-top:6px}
  .os-memo-orphan{border:1px dashed #d9d9de;border-radius:12px;padding:12px 14px;margin-bottom:14px;background:#fafafa}
  .os-memo-orphan-title{font-weight:800;font-size:13px;color:#B45309;margin-bottom:2px}
  .os-memo-orphan-desc{font-size:11.5px;color:var(--muted,#8a8a90);margin-bottom:6px}
  .os-memo-card-name{font-size:11px;color:#B45309;font-weight:700}
</style>`;

function osDetailHtml(s, catMap, readonly) {
  const d = s.data || {};
  const cards = Array.isArray(d.cards) ? d.cards : [];
  // 브랜드명·오리엔 번호는 모달에선 헤더 제목(osSetDetailTitle)이 맡으므로 본문에서 생략하고,
  // 헤더가 없는 새창(readonly)에서만 본문 맨 위에 표시한다.
  const headerHtml = readonly ? `<div style="margin-bottom:14px">
    ${s.orient_no ? `<div style="font-size:12px;font-weight:700;color:var(--muted);margin-bottom:2px">${esc(s.orient_no)}</div>` : ''}
    <div style="font-size:16px;font-weight:800;color:#161618">${esc(osBrandName(s))}</div>
  </div>` : '';
  // 상태 배지 + 모집 건수 줄 — 브랜드 정보 카드와 제품(모집 건) 카드 사이에 배치
  const statusLine = `<div style="margin:16px 0 10px">${osBadge(osStatusOf(s))}`
    + `<span style="margin-left:6px;color:var(--muted);font-size:12px">${cards.length ? cards.length + '개 모집 건' : ''}</span></div>`;
  const brandCard = osBrandCard(d.brand, osBrandName(s));
  // 브랜드가 레버브 운영팀에 전한 요청 — 값 있을 때만 카드로 1회 표시(발행 자동채움 대상 아님)
  const reqCard = d.reverb_request
    ? `<div class="os-card"><div class="os-card-title">레버브 측 요청</div><div class="os-fields">${osField('요청·요구사항', d.reverb_request, true)}</div></div>`
    : '';
  let bodyHtml;
  if (!cards.length) {
    const msg = (s.status === 'draft')
      ? '아직 작성 전입니다. 브랜드가 작성하면 여기에 표시됩니다.'
      : '작성된 모집 건이 없습니다.';
    bodyHtml = brandCard + statusLine + `<p style="color:var(--muted)">${msg}</p>` + reqCard;
  } else {
    bodyHtml = brandCard + statusLine + cards.map((c, i) => osCardDetail(c, i, catMap, readonly)).join('') + reqCard;
  }
  // 새창 출력(readonly)은 한 덩어리 그대로 — 메모를 아예 그리지 않으므로 나눌 것이 없다.
  //   그 출력물은 인쇄·브랜드 화면 공유 대상이라 내부 대화가 들어가면 안 된다.
  if (readonly) return OS_DETAIL_STYLE + `<div class="os-detail">${headerHtml}${bodyHtml}</div>`;
  // 모달은 좌우 2단 — 시트 내용을 보면서 메모를 읽고 쓸 수 있게. 각 칸이 따로 스크롤된다.
  return OS_DETAIL_STYLE + `<div class="os-detail os-split">
    <div class="os-pane os-pane-left">${bodyHtml}</div>
    <div class="os-pane os-pane-right">${osMemoPanelHtml(cards)}</div>
  </div>`;
}

function osFieldRow(label, valHtml, wide) {
  return `<div class="os-field${wide ? ' os-field-wide' : ''}"><div class="os-field-label">${label}</div><div class="os-field-val">${valHtml}</div></div>`;
}
function osField(label, val, wide) {
  const v = (val == null || val === '') ? '<span class="os-empty">미입력</span>' : esc(String(val));
  return osFieldRow(label, v, wide);
}
// 값이 이미 안전한 HTML(링크 등 — 호출부가 esc·화이트리스트 보장)일 때. esc 미적용.
function osFieldHtml(label, htmlVal, wide) {
  const v = htmlVal ? htmlVal : '<span class="os-empty">미입력</span>';
  return osFieldRow(label, v, wide);
}
function osRange(a, b) { return (a || b) ? `${a || '?'} ~ ${b || '?'}` : ''; }

// 공통 브랜드 카드 (1회). headerName: 모달 헤더의 발급 브랜드 마스터명 — 작성 브랜드명과 같으면 중복이라 생략
function osBrandCard(brand, headerName) {
  const b = brand || {};
  // 작성된 브랜드명이 헤더와 동일하면 생략(중복), 다르거나 미입력이면 표시
  const nameField = (b.name && b.name.trim() === String(headerName || '').trim()) ? '' : osField('브랜드명', b.name);
  const contactFields = (b.contact_name || b.email || b.phone)
    ? osField('담당자명', b.contact_name) + osField('이메일', b.email) + osField('연락처', b.phone)
    : '';
  const inner = nameField + contactFields + osField('소개·어필', b.intro, true) + osField('공식 계정', b.official_accounts, true);
  return `<div class="os-card">
    <div class="os-card-title">브랜드 정보</div>
    <div class="os-fields">${inner}</div></div>`;
}

// 카드(모집 건) 1개 상세 — 형식별 항목 분기(§15-12)
function osCardDetail(c, idx, catMap, readonly) {
  const ft = (c && c.form_type) || '';
  const p = c.product || {};
  const r = c.recruit || {};
  const sale = c.sale || {};
  const sd = c.seeding || {};
  const catLabel = (catMap && catMap[p.category]) || p.category;

  let inner = osField('카테고리', catLabel) + osField('모집 인원', p.slots)
    + osField('희망 모집 기간', osRange(r.recruit_start, r.recruit_end))
    + osField('희망 업로드 기간', osRange(r.upload_start, r.upload_end));

  if (ft === 'proxy_purchase' || ft === 'reviewer' || ft === 'seeding') {
    inner += osField('판매처', sale.market || 'Qoo10') + osFieldHtml('판매 URL', osLinkOrText(sale.url), true)
      + osField('상시가', sale.price_regular);
  }
  if (ft === 'reviewer') {
    inner += osFieldHtml('리뷰 가이드', sanitizeCautionHtml(c.review_guide), true);
  }
  if (ft === 'seeding') {
    inner += osField('등급', OS_GRADE_LABEL[sd.grade] || sd.grade);
    const chNames = (Array.isArray(sd.channels) ? sd.channels : []).map(osChLabel).filter(Boolean);
    inner += osField('게시 채널', chNames.join(', '));
    inner += osField('소구 키워드', osSeedingAppeal(sd), true);
    inner += osField('촬영 가이드', sd.shooting_guide, true)
      + osField('해시태그', Array.isArray(sd.hashtags) ? sd.hashtags.join(' ') : (sd.hashtags || ''))
      + osField('계정 태그', sd.account_tags);
    if (sd.grade === 'middle_mega') {
      inner += osField('필수 내용', sd.required_content, true) + osField('증정품', sd.gift);
    }
    inner += osField('배송 안내', sd.shipping_note, true);
  }
  inner += osFieldHtml('금지 표현(NG)', sanitizeCautionHtml(c.ng), true) + osFieldHtml('추가 안내', sanitizeCautionHtml(c.cautions), true) + osImagesInline(c.images);
  if (!ft) inner = '<div style="color:var(--muted);font-size:12px;margin-bottom:8px">브랜드가 아직 형식을 고르지 않았습니다.</div>' + inner;

  // ⚠️ 제목은 osCardTitle 로만 만든다 — 오른쪽 메모 묶음 머리줄도 같은 함수를 쓴다.
  //    여기서 따로 계산하면 왼쪽 카드 제목과 오른쪽 메모 이름이 어긋난다.
  const head = `<div class="os-card-head">
    ${osTypeChip(ft)}<span class="os-name">${esc(osCardTitle(c, idx))}</span>${osCardPublishControl(c, idx, readonly)}</div>`;
  // 메모는 이 카드 안이 아니라 **오른쪽 칸**에 모아 그린다(osMemoPanelHtml).
  //   시트 내용을 읽으면서 동시에 메모를 쓸 수 있어야 해서 좌우로 나눴다.
  return `<div class="os-card">${head}<div class="os-fields">${inner}</div></div>`;
}

// 카드 헤더 우측 — 발행 버튼(제출됨·미발행·형식 선택) / 발행됨 배지 / 형식 미선택 안내
function osCardPublishControl(c, idx, readonly) {
  if (readonly) return '';   // 새창(읽기 전용)에서는 발행 버튼 숨김
  const s = _osDetailSheet;
  if (c && c.campaign_id) {
    // 발행됨 배지 + 연결 캠페인 번호(활성=클릭 이동 / 보관삭제·완전삭제=상태 표시) + 「연결 해제」
    const cm = (_osDetailCampMap || {})[c.campaign_id];
    let campInfo;
    if (!cm) {
      // campaigns 에 행 없음 = 과거 완전 삭제됨(오리엔에 연결 기록만 남음)
      campInfo = '<span style="font-size:11px;color:#C62828;font-weight:600">삭제된 캠페인 (연결만 남음)</span>';
    } else if (cm.deleted_at) {
      // 보관 삭제됨 — 「삭제됨」 탭에 있음
      campInfo = `<span style="font-size:11px;color:#B45309;font-weight:600">${esc(cm.campaign_no || '번호 없음')} · 삭제됨(보관)</span>`;
    } else {
      // 활성 캠페인 — 번호 클릭 시 진행현황(신청자·요약)으로 이동
      campInfo = `<a href="#" onclick="osGotoPublishedCampaign('${c.campaign_id}');return false" style="font-size:11px;font-weight:700;color:var(--dark-pink);text-decoration:underline" title="캠페인 진행현황 보기">${esc(cm.campaign_no || '번호 없음')}</a>`;
    }
    return '<span style="flex-shrink:0;display:inline-flex;align-items:center;gap:6px;flex-wrap:wrap">'
      + '<span style="display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;color:var(--green);background:#E8F5E9">발행됨</span>'
      + campInfo
      + `<button type="button" class="btn btn-ghost btn-xs" style="flex-shrink:0" onclick="osUnlinkCard(${idx})">연결 해제</button>`
      + '</span>';
  }
  if (s && s.status === 'submitted') {
    if (!c || !c.form_type) return '<span style="flex-shrink:0;color:var(--muted);font-size:11px">형식 미선택</span>';
    return `<button type="button" class="btn btn-primary btn-xs" style="flex-shrink:0" onclick="osPublishCard(${idx})">이 카드로 발행</button>`;
  }
  return '';   // draft(미제출)·expired 는 발행 버튼 없음
}

// ══════════════════════════════════════════════════════════════
// 내부 메모 (모집 건 카드별 — 관리자 전용, 마이그레이션 295·296)
//   ⚠️ 새창 출력(readonly)에는 그리지 않는다. 그 출력물은 인쇄하거나 브랜드사에
//      화면 공유할 수 있는 성격이라, 내부 대화가 노출되면 안 된다.
//   ⚠️ 카드 지목은 순번이 아니라 카드 고유 번호(uid)로 한다. 다만 화면 조작
//      함수에는 **순번**을 넘긴다 — uid 는 브랜드가 보낸 값이 그대로 남을 수 있어
//      따옴표가 든 값이 오면 인라인 핸들러가 깨진다. 순번은 항상 숫자다.
// ══════════════════════════════════════════════════════════════

// 이 시트에서 그 카드 번호에 붙은 메모들 (최신순 — 서버 정렬 그대로)
function osMemosOfCard(uid) {
  if (!uid) return [];
  return (_osDetailMemos || []).filter(m => m && m.card_uid === uid);
}

// 시트의 현재 카드 목록에 없는 번호를 가진 메모 = 브랜드가 그 카드를 지운 것
function osOrphanMemos() {
  const s = _osDetailSheet;
  const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const live = new Set(cards.map(c => c && c.uid).filter(Boolean));
  return (_osDetailMemos || []).filter(m => m && !live.has(m.card_uid));
}

function osMemoUnread(list) {
  // 안 읽은 수는 서버 집계를 쓰되, 집계에 없는 조합(방금 남긴 메모 등)은 0으로 본다.
  const s = _osDetailSheet;
  if (!s) return 0;
  let n = 0;
  const seen = new Set();
  list.forEach(m => {
    if (seen.has(m.card_uid)) return;
    seen.add(m.card_uid);
    const row = (_osMemoSummary || {})[s.id + '_' + m.card_uid];
    n += (row && row.unreadCount) || 0;
  });
  return n;
}

function osMemoItemHtml(m) {
  const editing = Object.prototype.hasOwnProperty.call(_osMemoEditDraft, m.id);
  const when = formatDateTime(m.created_at);
  const edited = (m.updated_at && m.created_at && m.updated_at !== m.created_at)
    ? '<span class="os-memo-edited">수정됨</span>' : '';
  const meta = `<div class="os-memo-meta">
      <span class="os-memo-author">${esc(m.author_name || '이름 없음')}</span>
      <span>${esc(when)}</span>${edited}
      ${editing ? '' : `<span class="os-memo-acts">
        <button type="button" class="btn btn-ghost btn-xs" onclick="osMemoEdit('${esc(m.id)}')">고침</button>
        <button type="button" class="btn btn-ghost btn-xs" onclick="osMemoDelete('${esc(m.id)}')">지움</button>
      </span>`}
    </div>`;
  if (!editing) {
    return `<div class="os-memo-item" data-memo-id="${esc(m.id)}">${meta}
      <div class="os-memo-text">${sanitizeMemoHtml(m.body_html)}</div></div>`;
  }
  // 초기값은 저장된 본문이 아니라 **고치던 내용**(_osMemoEditDraft) — 위 입력칸과 같은 이유
  return `<div class="os-memo-item" data-memo-id="${esc(m.id)}">${meta}
    ${miniEditorHtml(_osMemoEditDraft[m.id] || '', `_osMemoEditDraft['${esc(m.id)}']=this.innerHTML`, '메모를 고치세요',
                     { allowImage: false, sanitize: sanitizeMemoHtml })}
    <div class="os-memo-form-acts">
      <button type="button" class="btn btn-ghost btn-sm" onclick="osMemoEditCancel('${esc(m.id)}')">취소</button>
      <button type="button" class="btn btn-primary btn-sm" onclick="osMemoEditSave('${esc(m.id)}')">저장</button>
    </div></div>`;
}

// 오른쪽 메모 칸 전체 — 모집 건마다 묶음 하나 + 맨 아래 「삭제된 모집 건의 메모」
function osMemoPanelHtml(cards) {
  const list = Array.isArray(cards) ? cards : [];
  const groups = list.map((c, i) => (c && c.uid) ? osMemoSectionHtml(c.uid, i, osCardTitle(c, i)) : '').join('');
  const orphan = osOrphanMemoHtml();
  // 붙일 자리가 없어 메모를 못 남기는 두 경우의 안내 — 문구를 한 곳에만 둔다
  const noSlotMsg = list.length
    ? '이 시트의 모집 건에는 아직 고유 번호가 없어 메모를 남길 수 없습니다.'
    : '브랜드가 모집 건을 작성하면 여기에 메모를 남길 수 있습니다.';
  // groups 가 비면 남길 자리가 없다는 뜻 — 고아 메모가 있으면 그 아래 함께 보여준다
  const body = groups
    ? groups + orphan
    : `<div class="os-memo-panel-empty">${noSlotMsg}</div>` + orphan;
  return `<div class="os-memo-panel">
    <div class="os-memo-panel-title">
      <span class="material-icons-round notranslate" translate="no" style="font-size:16px;color:var(--muted,#8a8a90)">sticky_note_2</span>
      내부 메모 <span style="font-weight:600;color:var(--muted,#8a8a90);font-size:11.5px">· 관리자만 보입니다</span>
    </div>${body}</div>`;
}

// 메모 묶음 머리줄에 쓰는 모집 건 이름 (상세 왼쪽 카드 제목과 같은 규칙)
function osCardTitle(c, idx) {
  const p = (c && c.product) || {};
  return p.name || ('제품 ' + (idx + 1));
}

// 모집 건 1개의 메모 묶음. slotKey = 카드 순번(숫자) — 새 메모 입력칸 식별용
//   「삭제된 모집 건의 메모」는 카드별로 묶어 제품명을 얹어야 해서 이 함수를 쓰지 않고
//   osOrphanMemoHtml 이 같은 모양의 마크업을 따로 만든다.
function osMemoSectionHtml(uid, slotKey, cardName) {
  const list = osMemosOfCard(uid);
  const unread = osMemoUnread(list);
  const open = unread > 0;   // 안 읽은 메모가 있으면 자동 펼침 (놓치지 않게 하는 장치)
  const items = list.length
    ? list.map(osMemoItemHtml).join('')
    : '<div class="os-memo-empty">아직 메모가 없습니다. 아래에 남겨 주세요.</div>';
  // ⚠️ 입력칸 초기값은 빈 문자열이 아니라 **작성 중이던 내용**을 넣는다.
  //   메모 영역은 다른 카드에 메모를 남길 때도 함께 다시 그려지는데, 빈 값으로
  //   그리면 화면에서만 글이 사라지고 _osMemoDraft 에는 남아, 나중에 「남기기」를
  //   누르면 보이지도 않던 글이 등록된다.
  const form = `<div class="os-memo-form">
      ${miniEditorHtml(_osMemoDraft[slotKey] || '', `_osMemoDraft['${slotKey}']=this.innerHTML`, '이 모집 건에 대한 내부 메모',
                       { allowImage: false, sanitize: sanitizeMemoHtml })}
      <div class="os-memo-form-acts">
        <button type="button" class="btn btn-primary btn-sm" onclick="osMemoSubmit(${slotKey})">남기기</button>
      </div>
    </div>`;
  return `<div class="os-memo${open ? ' open' : ''}" data-memo-slot="${slotKey}">
    <button type="button" class="os-memo-head" onclick="osMemoToggle(this)">
      <span class="material-icons-round notranslate os-memo-caret" translate="no">expand_more</span>
      <span style="flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${esc(cardName || '모집 건')}</span>
      <span style="color:var(--muted,#8a8a90);font-weight:600;font-size:11.5px;flex-shrink:0">${list.length}</span>
      ${unread ? `<span class="os-memo-unread">${unread}</span>` : ''}
    </button>
    <div class="os-memo-body">${items}${form}</div>
  </div>`;
}

// 「삭제된 모집 건의 메모」 — 붙일 카드가 없어 새 메모는 남길 수 없다(수정·삭제는 동일)
function osOrphanMemoHtml() {
  const list = osOrphanMemos();
  if (!list.length) return '';
  const byCard = {};
  list.forEach(m => { (byCard[m.card_uid] = byCard[m.card_uid] || []).push(m); });
  const groups = Object.keys(byCard).map(uid => {
    const name = (byCard[uid].find(m => m.card_name_snapshot) || {}).card_name_snapshot;
    return `<div class="os-memo-card-name">${esc(name || '이름 없는 모집 건')}</div>`
      + byCard[uid].map(osMemoItemHtml).join('');
  }).join('');
  const unread = osMemoUnread(list);
  return `<div class="os-memo-orphan">
    <div class="os-memo-orphan-title">삭제된 모집 건의 메모</div>
    <div class="os-memo-orphan-desc">브랜드가 지운 모집 건에 달려 있던 메모입니다. 제품명은 메모를 남긴 시점 기준입니다.</div>
    <div class="os-memo${unread > 0 ? ' open' : ''}" data-memo-slot="orphan">
      <button type="button" class="os-memo-head" onclick="osMemoToggle(this)">
        <span class="material-icons-round notranslate os-memo-caret" translate="no">expand_more</span>
        <span style="flex:1;min-width:0">지워진 모집 건</span>
        <span style="color:var(--muted,#8a8a90);font-weight:600;font-size:11.5px;flex-shrink:0">${list.length}</span>
        ${unread ? `<span class="os-memo-unread">${unread}</span>` : ''}
      </button>
      <div class="os-memo-body">${groups}</div>
    </div>
  </div>`;
}

function osMemoToggle(btn) {
  const wrap = btn.closest('.os-memo');
  if (wrap) wrap.classList.toggle('open');
}

// 메모 변경 뒤 — 모달 전체를 다시 그리지 않고 메모 영역만 갈아 끼운다.
//   전체 재렌더는 펼쳐 둔 카드가 접히고 스크롤 위치도 튄다.
async function osRefreshMemos() {
  const s = _osDetailSheet;
  if (!s) return;
  try {
    _osDetailMemos = await fetchOrientMemos(s.id);
    _osMemoSummary = await fetchOrientMemoSummaries();
  } catch (_) { return; }
  const cards = (s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  document.querySelectorAll('#osDetailBody .os-memo').forEach(el => {
    const slot = el.getAttribute('data-memo-slot');
    const wasOpen = el.classList.contains('open');
    if (slot === 'orphan') {
      const box = el.closest('.os-memo-orphan');
      if (box) { box.outerHTML = osOrphanMemoHtml(); return; }
      return;
    }
    const idx = parseInt(slot, 10);
    if (isNaN(idx) || !cards[idx]) return;
    el.outerHTML = osMemoSectionHtml(cards[idx].uid, idx, osCardTitle(cards[idx], idx));
    // 펼쳐 둔 상태 유지 — 자동 펼침(안 읽은 메모)과 별개로 사용자가 연 것도 지킨다
    if (wasOpen) {
      const next = document.querySelector(`#osDetailBody .os-memo[data-memo-slot="${idx}"]`);
      if (next) next.classList.add('open');
    }
  });
}

async function osMemoSubmit(slotKey) {
  const s = _osDetailSheet;
  if (!s) return;
  const cards = (s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const card = cards[slotKey];
  if (!card || !card.uid) { toast('이 모집 건에는 아직 고유 번호가 없어 메모를 남길 수 없습니다', 'error'); return; }
  const raw = _osMemoDraft[slotKey] || '';
  const body = sanitizeMemoHtml(raw);
  if (!osStripHtml(body).trim()) { toast('메모 내용을 입력해 주세요', 'error'); return; }
  // 작성자 스냅샷 — 기존 브랜드 서베이 메모(admin-brand.js)와 같은 방식.
  //   이름은 관리자 계정이 지워져도 남는다.
  const authorName = (typeof currentAdminInfo !== 'undefined' && currentAdminInfo && currentAdminInfo.name)
    || (typeof currentUser !== 'undefined' && currentUser && currentUser.email) || '관리자';
  const authorId = (typeof currentUser !== 'undefined' && currentUser && currentUser.id) || null;
  const res = await insertOrientMemo(
    s.id, card.uid, (card.product && card.product.name) || null, body, authorId, authorName
  );
  if (!res.ok) { toast('메모를 남기지 못했습니다', 'error'); return; }
  _osMemoDraft[slotKey] = '';
  await osRefreshMemos();
  toast('메모를 남겼습니다');
}

function osMemoEdit(memoId) {
  const m = (_osDetailMemos || []).find(x => x.id === memoId);
  if (!m) return;
  _osMemoEditDraft[memoId] = m.body_html || '';
  osRepaintMemoItem(memoId);
}

function osMemoEditCancel(memoId) {
  delete _osMemoEditDraft[memoId];
  osRepaintMemoItem(memoId);
}

// 메모 1건만 다시 그린다(펼침 상태·다른 입력칸을 건드리지 않기 위해)
function osRepaintMemoItem(memoId) {
  const m = (_osDetailMemos || []).find(x => x.id === memoId);
  const el = document.querySelector(`#osDetailBody .os-memo-item[data-memo-id="${CSS.escape(memoId)}"]`);
  if (!m || !el) return;
  el.outerHTML = osMemoItemHtml(m);
}

async function osMemoEditSave(memoId) {
  const raw = _osMemoEditDraft[memoId] || '';
  const body = sanitizeMemoHtml(raw);
  if (!osStripHtml(body).trim()) { toast('메모 내용을 입력해 주세요', 'error'); return; }
  const res = await updateOrientMemo(memoId, body);
  if (!res.ok) { toast('메모를 고치지 못했습니다', 'error'); return; }
  delete _osMemoEditDraft[memoId];
  await osRefreshMemos();
  toast('메모를 고쳤습니다');
}

async function osMemoDelete(memoId) {
  // 되돌릴 수 없는 동작 — 확인 한 단계 (브랜드 서베이 메모와 같은 수준)
  if (!confirm('이 메모를 지웁니다. 되돌릴 수 없습니다.')) return;
  const res = await deleteOrientMemo(memoId);
  if (!res.ok) { toast('메모를 지우지 못했습니다', 'error'); return; }
  delete _osMemoEditDraft[memoId];
  await osRefreshMemos();
  toast('메모를 지웠습니다');
}

// 브랜드 입력 URL은 서버 검증이 없으므로(직접 RPC 호출 우회 가능) http/https만 링크 허용
function osImgSafe(u) {
  try { const p = new URL(u).protocol; return p === 'https:' || p === 'http:'; }
  catch (e) { return false; }
}
function osLinkOrText(u) {
  if (!u) return '';
  const disp = esc(u);
  return osImgSafe(u) ? `<a href="${disp}" target="_blank" rel="noopener">${disp}</a>` : disp;
}
function osImagesInline(images) {
  const imgs = Array.isArray(images) ? images.filter(x => x && x.value) : [];
  if (!imgs.length) return '';
  const inner = imgs.map(x => {
    const disp = esc(x.value);
    return osImgSafe(x.value)
      ? `<div style="margin-bottom:4px"><a href="${disp}" target="_blank" rel="noopener">${disp}</a></div>`
      : `<div style="margin-bottom:4px;color:var(--muted)">${disp} <span style="font-size:10px">(링크 차단)</span></div>`;
  }).join('');
  return osFieldRow('예시 이미지·자료', inner, true);
}

// ── 카드 → 캠페인 발행 방식 선택 ──
// 상세 모달 카드 「이 카드로 발행」 → 발행 방식 선택 모달(신규 발행 / 기존 캠페인 연결)을 연다.
// 검증(제출됨·형식 선택·미발행)은 여기서 1차, 실제 발행/연결 서버 RPC 가 최종 검증.
function osPublishCard(cardIdx) {
  const s = _osDetailSheet;
  if (!s) return;
  if (s.status !== 'submitted') { toast('제출된 오리엔시트만 발행할 수 있습니다.'); return; }
  const cards = (s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const card = cards[cardIdx];
  if (!card) return;
  if (card.campaign_id) { toast('이미 발행된 카드입니다.'); return; }
  if (!card.form_type) { toast('형식이 선택되지 않은 카드는 발행할 수 없습니다.'); return; }
  _osPublishCardIdx = cardIdx;
  // 선택 화면을 기본으로(목록 화면은 숨김) 리셋 후 모달 오픈. 상세 모달은 뒤에 그대로 둔다.
  ensureOrientModals();
  const choice = document.getElementById('osPublishChoice');
  const listView = document.getElementById('osLinkListView');
  if (choice) choice.style.display = '';
  if (listView) listView.style.display = 'none';
  document.getElementById('orientPublishModal').classList.add('open');
}

// 발행 방식 ① 신규 캠페인 발행 — 기존 자동 채움 흐름(applyOrientCardPrefill)
async function osChooseNewPublish() {
  const s = _osDetailSheet;
  if (!s || _osPublishCardIdx == null) return;
  const cards = (s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
  const card = cards[_osPublishCardIdx];
  if (!card) return;
  osCloseModal('orientPublishModal');
  osCloseModal('orientDetailModal');
  try {
    await applyOrientCardPrefill(card, s.data.brand || {}, s.brand_id, s.application_id, s.id, _osPublishCardIdx);
  } catch (e) {
    console.error('[osChooseNewPublish]', e);
    toast('자동 채움 중 오류가 발생했습니다. 폼을 직접 확인해 주세요.');
  }
}

// 발행 방식 ② 기존 캠페인 연결 — 같은 모달 안에서 캠페인 목록 화면으로 전환
async function osChooseLinkExisting() {
  const choice = document.getElementById('osPublishChoice');
  const listView = document.getElementById('osLinkListView');
  if (choice) choice.style.display = 'none';
  if (listView) listView.style.display = '';
  const search = document.getElementById('osLinkSearch');
  if (search) search.value = '';
  const body = document.getElementById('osLinkListBody');
  if (body) body.innerHTML = '<div style="text-align:center;color:var(--muted);padding:24px 8px;font-size:13px">불러오는 중…</div>';
  // 열 때마다 캠페인을 항상 새로 불러온다. allCampaigns 캐시가 오래되면 — 방금 직접 만든 캠페인이거나
  // 브랜드를 나중에 연결한 캠페인 — "같은 브랜드" 필터에서 빠져, 실제로는 연결 가능한데도
  // 관리자에게 "검색 결과 없음"으로 보여 중복 캠페인을 만들 소지가 있어서다.
  // 실패 시 기존 캐시 유지(폴백).
  try { allCampaigns = await fetchCampaigns(); }
  catch (e) { console.error('[osChooseLinkExisting]', e); }
  osRenderLinkList('');
  if (search) search.focus();
}

// 목록 화면 → 선택 화면 복귀
function osBackToPublishChoice() {
  const choice = document.getElementById('osPublishChoice');
  const listView = document.getElementById('osLinkListView');
  if (choice) choice.style.display = '';
  if (listView) listView.style.display = 'none';
}

// 검색 입력 → 목록 재렌더
function osLinkListSearch() {
  const q = (document.getElementById('osLinkSearch')?.value || '').trim().toLowerCase();
  osRenderLinkList(q);
}

// 캠페인 상태 배지 — shared.js 공용 헬퍼 재사용(closed→submission_end 경과 시 종료 자동 반영).
function osCampStatusBadge(c) {
  const key = (typeof campaignStatusLabelKey === 'function') ? campaignStatusLabelKey(c) : (c && c.status);
  const cls = (typeof CAMPAIGN_STATUS_BADGE_CLASS !== 'undefined' && CAMPAIGN_STATUS_BADGE_CLASS[key]) || 'badge-gray';
  const label = (typeof CAMPAIGN_STATUS_LABEL !== 'undefined' && CAMPAIGN_STATUS_LABEL[key]) || (c && c.status) || '-';
  return `<span class="badge ${cls}">${esc(label)}</span>`;
}

// 이미 어떤 시트/카드에 연결된 캠페인 id 집합 (전 시트의 카드 campaign_id + 시트 컬럼 campaign_id)
function osLinkedCampaignIds() {
  const set = new Set();
  (_orientSheets || []).forEach(s => {
    if (s && s.campaign_id) set.add(s.campaign_id);
    const cards = (s && s.data && Array.isArray(s.data.cards)) ? s.data.cards : [];
    cards.forEach(c => { if (c && c.campaign_id) set.add(c.campaign_id); });
  });
  return set;
}

// 기존 캠페인 목록 렌더 — 같은 브랜드 + 미연결 캠페인만. q 로 캠페인명·번호 부분일치 필터.
function osRenderLinkList(q) {
  const body = document.getElementById('osLinkListBody');
  if (!body) return;
  const s = _osDetailSheet;
  const brandId = s && s.brand_id;
  const all = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns : [];
  const linked = osLinkedCampaignIds();
  let list = all.filter(c => c && c.brand_id === brandId && !linked.has(c.id));
  if (q) {
    list = list.filter(c => {
      const hay = [c.title, c.product_ko, c.product, c.campaign_no].filter(Boolean).join(' ').toLowerCase();
      return hay.includes(q);
    });
  }
  if (!list.length) {
    body.innerHTML = q
      ? '<div style="text-align:center;color:var(--muted);padding:24px 8px;font-size:13px">검색 결과가 없습니다.</div>'
      : '<div style="text-align:center;color:var(--muted);padding:24px 8px;font-size:13px">이 브랜드에 연결 가능한 캠페인이 없습니다. 신규 발행을 이용하세요.</div>';
    return;
  }
  body.innerHTML = list.map(c => {
    const name = esc(c.product_ko || c.product || c.title || '(제목 없음)');
    const no = c.campaign_no ? `<span style="font-family:monospace;font-size:10px;font-weight:600;color:var(--muted)">${esc(c.campaign_no)}</span>` : '';
    const period = osRange(c.recruit_start, c.deadline);
    const periodHtml = period ? `<span style="font-size:11px;color:var(--muted)">${esc(period)}</span>` : '';
    return `<button type="button" class="os-link-camp-row" onclick="osConfirmLink('${c.id}')"
      style="display:flex;flex-direction:column;gap:4px;width:100%;text-align:left;padding:10px 12px;border:1px solid var(--line);border-radius:10px;background:#fff;cursor:pointer;margin-bottom:8px">
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap"><strong style="color:var(--ink);font-size:13px">${name}</strong>${osCampStatusBadge(c)}</div>
      <div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap">${no}${periodHtml}</div>
    </button>`;
  }).join('');
}

// 연결 실행 — 확인 후 link_orient_card_to_campaign RPC 호출, reason 분기 안내.
async function osConfirmLink(campaignId) {
  const s = _osDetailSheet;
  if (!s || _osPublishCardIdx == null || !campaignId) return;
  const ok = (typeof showConfirm === 'function')
    ? await showConfirm('이 캠페인을 카드에 연결(발행 처리)할까요? 되돌리려면 연결 해제를 쓰세요.')
    : confirm('이 캠페인을 카드에 연결(발행 처리)할까요? 되돌리려면 연결 해제를 쓰세요.');
  if (!ok) return;
  let res;
  try {
    res = await linkOrientCardToCampaign(s.id, _osPublishCardIdx, campaignId);
  } catch (e) {
    console.error('[osConfirmLink]', e);
    toast('연결 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.');
    return;
  }
  if (!res || !res.success) {
    toast(osLinkFailMsg(res && res.reason));
    return;
  }
  toast('연결(발행)되었습니다.');
  osCloseModal('orientPublishModal');
  osCloseModal('orientDetailModal');
  await refreshPane('orient-sheets');
}

// 발행 카드의 연결 캠페인 번호 클릭 → 그 캠페인 진행현황(신청자·요약)으로 이동. 오리엔 상세 모달은 닫는다.
//   (활성 캠페인만 이 함수로 이동 — 보관·완전삭제는 osCardPublishControl 에서 링크 없이 상태만 표시)
function osGotoPublishedCampaign(campId) {
  if (typeof osCloseModal === 'function') osCloseModal('orientDetailModal');
  if (typeof openCampApplicants === 'function') openCampApplicants(campId, null);
}

// 연결 해제 — 발행됨 카드의 캠페인 연결을 되돌림(캠페인 행은 삭제 안 함).
async function osUnlinkCard(cardIdx) {
  const s = _osDetailSheet;
  if (!s) return;
  const ok = (typeof showConfirm === 'function')
    ? await showConfirm('이 카드의 캠페인 연결을 해제할까요? (캠페인 자체는 삭제되지 않습니다)')
    : confirm('이 카드의 캠페인 연결을 해제할까요? (캠페인 자체는 삭제되지 않습니다)');
  if (!ok) return;
  let res;
  try {
    res = await unlinkOrientCard(s.id, cardIdx);
  } catch (e) {
    console.error('[osUnlinkCard]', e);
    toast('연결 해제 중 오류가 발생했습니다. 잠시 후 다시 시도해 주세요.');
    return;
  }
  if (!res || !res.success) {
    toast(osUnlinkFailMsg(res && res.reason));
    return;
  }
  toast('연결을 해제했습니다.');
  osCloseModal('orientDetailModal');
  await refreshPane('orient-sheets');
}

// 연결/해제 실패 reason → 사용자 안내 문구
function osLinkFailMsg(reason) {
  switch (reason) {
    case 'brand_mismatch':           return '브랜드가 일치하지 않습니다.';
    case 'campaign_already_linked':  return '이미 다른 카드/시트에 연결된 캠페인입니다.';
    case 'already_published':        return '이미 발행된 카드입니다.';
    case 'invalid_status':           return '제출된 오리엔시트만 발행할 수 있습니다.';
    case 'invalid_card':             return '카드를 찾을 수 없습니다.';
    case 'campaign_not_found':       return '캠페인을 찾을 수 없습니다.';
    case 'permission_denied':        return '권한이 없습니다.';
    case 'not_found':                return '오리엔시트를 찾을 수 없습니다.';
    default:                         return '연결하지 못했습니다.';
  }
}
function osUnlinkFailMsg(reason) {
  switch (reason) {
    case 'not_linked':        return '이미 연결이 해제된 카드입니다.';
    case 'invalid_card':      return '카드를 찾을 수 없습니다.';
    case 'permission_denied': return '권한이 없습니다.';
    case 'not_found':         return '오리엔시트를 찾을 수 없습니다.';
    default:                  return '연결을 해제하지 못했습니다.';
  }
}

function osSetVal(id, val) { const el = document.getElementById(id); if (el) el.value = (val == null ? '' : String(val)); }
function osPriceNum(v) { const n = parseInt(String(v == null ? '' : v).replace(/[^0-9]/g, ''), 10); return isNaN(n) ? '' : n; }

// 시딩=게시 채널 / 리뷰어·가구매=판매처(마켓)를 채널 코드로
function osPrefillChannels(card) {
  if (card.form_type === 'seeding') {
    // 오리엔시트 내부 코드(피드/릴스)를 캠페인 채널 체계로 변환 + 중복 제거. 미매칭(random 등) 제외.
    const raw = (card.seeding && Array.isArray(card.seeding.channels)) ? card.seeding.channels : [];
    const chMap = { instagram_feed: 'instagram', instagram_reels: 'instagram', instagram: 'instagram', x: 'x', tiktok: 'tiktok', youtube: 'youtube' };
    const out = [];
    raw.forEach(c => { const m = chMap[c]; if (m && out.indexOf(m) === -1) out.push(m); });
    return out;
  }
  // ⚠️ 값은 lookup_values(kind='channel')의 **실제 code** 여야 한다. 여기 없는 코드를
  //    넣으면 채널 체크박스가 아예 안 그려져 「채널을 1개 이상 선택」으로 발행이 막힌다.
  //    실제 코드: qoo10 / cosme / lips (마이그레이션 157 + 시드 lookup_values.sql)
  //    2026-07-31 정정 — '@cosme' 가 존재하지 않는 'atcosme' 로 매핑돼 있었다.
  const map = { 'Qoo10': 'qoo10', '@cosme': 'cosme', 'LIPS': 'lips' };
  const m = (card.sale && card.sale.market) || '';
  return map[m] ? [map[m]] : [];
}

// 가격·행사를 리워드 안내 텍스트로 보존 (캠페인 reward_note)
function osBuildRewardNote(card) {
  const s = card.sale || {};
  const parts = [];
  if (card.form_type === 'proxy_purchase') parts.push('[가구매] 영수증만 제출 (리뷰·게시 없음)');
  if (s.price_regular) parts.push('상시가 ' + s.price_regular);
  return parts.join(' / ');
}

// 평문 → 리치 텍스트 HTML (이스케이프 + 줄바꿈)
function osPlainToRich(t) {
  if (!t) return '';
  return esc(String(t)).replace(/\n/g, '<br>');
}
// 리치 텍스트(HTML) → 평문 (가이드 초안용 — 줄바꿈 보존, 태그 제거)
function osStripHtml(html) {
  if (!html) return '';
  const d = document.createElement('div');
  d.innerHTML = String(html).replace(/<br\s*\/?>/gi, '\n').replace(/<\/p>/gi, '\n');
  return (d.textContent || '').trim();
}

// 카드 한국어 콘텐츠를 가이드 초안으로 합침 (관리자가 일본어로 번역)
function osBuildGuideDraft(card) {
  const blocks = [];
  if (card.form_type === 'reviewer' && card.review_guide) blocks.push('[리뷰 가이드]\n' + osStripHtml(card.review_guide));
  if (card.form_type === 'seeding') {
    const sd = card.seeding || {};
    const chNames = (Array.isArray(sd.channels) ? sd.channels : []).map(osChLabel).filter(Boolean);
    if (chNames.length) blocks.push('[게시 채널] ' + chNames.join(', '));
    const appeal = osSeedingAppeal(sd);
    if (appeal) blocks.push('[소구 키워드]\n' + appeal);
    if (sd.shooting_guide) blocks.push('[촬영 가이드]\n' + sd.shooting_guide);
    if (sd.required_content) blocks.push('[필수 내용]\n' + sd.required_content);
    if (sd.gift) blocks.push('[증정품] ' + sd.gift);
    if (sd.shipping_note) blocks.push('[배송 안내] ' + sd.shipping_note);
    if (sd.account_tags) blocks.push('[태그 계정] ' + sd.account_tags);
  }
  if (card.cautions) blocks.push('[추가 안내]\n' + osStripHtml(card.cautions));
  if (card.ng) blocks.push('[NG]\n' + osStripHtml(card.ng));
  return blocks.map(osPlainToRich).join('<br><br>');
}

// 캠페인 등록 폼에 카드 내용 자동 채움. 한국어는 _ko 칸·가이드 초안에, 일본어 표시칸(제목·제품명)은 비워 관리자 보완.
async function applyOrientCardPrefill(card, brand, brandId, appId, orientId, cardIdx) {
  if (typeof switchAdminPane === 'function') switchAdminPane('add-campaign', null);
  // 발행 컨텍스트 — switchAdminPane 이 add-campaign 진입 시 초기화하므로 그 직후 세팅.
  // addCampaign 이 일본어 게이트·발행 소비·가구매 플래그에 사용.
  window._orientPublishCtx = { orientId: orientId, cardIdx: cardIdx, isProxy: card.form_type === 'proxy_purchase' };
  const ft = card.form_type;
  const recruitType = (ft === 'seeding') ? 'gifting' : 'monitor';   // 가구매·리뷰어→리뷰어(monitor), 시딩→기프팅

  // 브랜드 선택 + cascade (native select)
  if (typeof loadCampBrandSelect === 'function') await loadCampBrandSelect('new', brandId);
  osSetVal('newCampBrandId', brandId || '');
  if (typeof onCampBrandChange === 'function') await onCampBrandChange('new');
  if (appId) {
    osSetVal('newCampSourceAppId', appId);
    // 선택 UI 는 숨김이라 커스텀 트리거 대신 읽기전용 라벨로 승계된 신청을 표시
    if (typeof renderSurveyLinkReadonly === 'function') renderSurveyLinkReadonly('new');
  }

  // recruitType 라디오 (인라인 onchange 로 채널·팔로워 영역 갱신)
  const rt = document.querySelector(`input[name="recruitType"][value="${recruitType}"]`);
  if (rt) { rt.checked = true; rt.dispatchEvent(new Event('change')); }

  // 채널·카테고리 렌더
  if (typeof renderChannelCheckboxes === 'function') await renderChannelCheckboxes('new', recruitType, osPrefillChannels(card));
  if (typeof renderCategorySelect === 'function') await renderCategorySelect('new', (card.product && card.product.category) || '');

  // 텍스트 (한국어→_ko, 일본어 표시칸은 비움 → 일본어 게이트가 보완 유도)
  const p = card.product || {};
  osSetVal('newCampProductKo', p.name || '');
  osSetVal('newCampProduct', '');
  osSetVal('newCampTitle', '');
  osSetVal('newCampSlots', p.slots || '');
  osSetVal('newCampProductUrl', (card.sale && card.sale.url) || '');
  osSetVal('newCampProductPrice', osPriceNum(card.sale && card.sale.price_regular));
  osSetVal('newCampRewardNote', osBuildRewardNote(card));
  // 해시태그는 히든 입력칸에 직접 넣지 않고 태그 칩 위젯을 거친다.
  //   값을 공백으로 이어 붙여 넣으면 ①칩이 안 그려져 관리자 화면에서 안 보이고
  //   ②저장 포맷(쉼표 구분)과 달라 「#A #B」가 한 덩어리로 저장된다 (2026-07-27 운영 확인).
  if (card.form_type === 'seeding') {
    const tags = Array.isArray(card.seeding && card.seeding.hashtags) ? card.seeding.hashtags : [];
    if (typeof loadTagsFromValue === 'function') {
      loadTagsFromValue('tagWrap_newCampHashtags', 'newCampHashtags', '#', tags.join(','));
    } else {
      osSetVal('newCampHashtags', tags.map(t => String(t).replace(/[#\s]/g, '')).filter(Boolean).map(t => '#' + t).join(','));
    }
  }

  // 날짜 (희망 모집·업로드 기간) — flatpickr range + deadline + 결과물 제출 마감일
  const r = card.recruit || {};
  const uploadEnd = r.upload_end || null;
  // 업로드 기간 → 가구매·리뷰어(monitor)는 구매 기간에, 시딩(gifting)은 구매 행이 없어 결과물 마감일에만 반영
  // ⚠️ 이 monitor 분기는 applyDeadlineFieldsVisibility 의 구매 필드 노출 조건(monitor 만 유지)과 맞물려 있음.
  //    오리엔 카드에 visit(방문형) 형식이 추가되면 이 가정이 깨지므로 그때 매핑 재검토 필요.
  const purchasePair = (recruitType === 'monitor') ? [r.upload_start || null, uploadEnd] : [null, null];
  if (typeof applyCampRangeValues === 'function') {
    applyCampRangeValues('newCamp', { recruit: [r.recruit_start || null, r.recruit_end || null], purchase: purchasePair, visit: [null, null] });
  }
  osSetVal('newCampRecruitStart', r.recruit_start || '');
  osSetVal('newCampDeadline', r.recruit_end || '');
  // 결과물 제출 마감일 = 업로드 마감일 그대로 (3형식 공통)
  osSetVal('newCampSubmissionEnd', uploadEnd || '');
  // 단일 picker(결과물 제출 마감일) + 구매 range picker 경계·표시 동기화
  if (typeof syncCampDateMinMax === 'function') syncCampDateMinMax('newCamp');

  // 리치 텍스트 (한국어 초안 — 관리자 일본어 번역)
  if (typeof setRichValue === 'function') {
    setRichValue('newCampGuide', osBuildGuideDraft(card));
    // 통합 소구 키워드 — 신규 seeding.appeal / 옛 seeding.guides 양쪽 하위호환(모듈 헬퍼 재사용)
    setRichValue('newCampAppeal', osPlainToRich(osSeedingAppeal(card.seeding)));
    setRichValue('newCampDesc', osPlainToRich(brand.intro || ''));
  }

  toast('오리엔시트 내용을 채웠습니다. 일본어(제목·제품명·가이드)를 보완한 뒤 발행해 주세요.');
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function osCloseModal(id) {
  const m = document.getElementById(id);
  if (m) m.classList.remove('open');
  // 상세 모달을 닫을 때만 목록의 메모 배지를 다시 계산한다.
  //   상세를 열면 그 시트 메모가 전부 읽음 처리되므로 배지가 0이 돼야 한다.
  //   ⚠️ 닫는 지점이 5곳(머리 X·바닥 닫기·발행 확정·연결·해제)이라 각각에 붙이면
  //      반드시 하나를 빠뜨린다 — 여기 한 자리에서만 분기한다.
  //   ⚠️ 모달이 열려 있는 동안 뒤 목록 숫자가 그대로인 것은 정상이다(갱신은 닫을 때).
  if (id === 'orientDetailModal') osRefreshListMemoBadges();
}

async function osRefreshListMemoBadges() {
  try { _osMemoSummary = await fetchOrientMemoSummaries(); } catch (_) { return; }
  if (document.getElementById('orientTableBody')) renderOrientSheets();
}

// ── 모달 DOM 1회 생성 (기존 .modal-overlay/.modal/.modal-body 클래스 재사용) ──
function ensureOrientModals() {
  if (document.getElementById('orientCreateModal')) return;
  const html = `
  <div class="modal-overlay" id="orientCreateModal">
    <div class="modal" style="max-width:600px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2 id="osCreateTitle">오리엔시트 링크 발급</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientCreateModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px;overflow-y:auto;flex:1">
        <div id="osCreateForm">
          <div class="form-group"><label class="form-label">브랜드 <span style="color:var(--pink,#1A1A1A)">*</span></label>
            <div class="admin-proxy-combobox" id="osCreateBrandCombobox">
              <input type="text" id="osCreateBrandInput" class="admin-proxy-combobox-input" placeholder="브랜드명 검색 후 선택" autocomplete="off" oninput="osBrandInput()" onfocus="osBrandShowList()">
              <input type="hidden" id="osCreateBrand">
              <div class="admin-proxy-combobox-list" id="osCreateBrandList"></div>
            </div></div>
          <div class="form-group"><label class="form-label">광고주 신청 연결 (선택)</label>
            <select id="osCreateApp" class="form-input" disabled><option value="">연결 안 함</option></select>
            <div style="font-size:11px;color:var(--muted);margin-top:4px">신청 연결은 현재 사용하지 않습니다. 발급은 브랜드만 선택하면 됩니다.</div></div>
          <div style="font-size:12px;color:var(--muted);background:#FAFAF7;border-radius:8px;padding:10px;margin-top:4px">
            모집 형식(가구매·리뷰어·시딩)과 제품은 브랜드가 작성 폼에서 카드마다 직접 추가·선택합니다.</div>
        </div>
        <div id="osCreateResult" style="display:none">
          <p style="font-weight:700;margin-bottom:6px">발급되었습니다. 아래 링크를 브랜드에게 전달하세요.</p>
          <p style="margin:0 0 10px;font-size:13px;color:var(--muted)">오리엔시트 번호 <span id="osCreateOrientNo" style="font-weight:800;color:var(--ink)"></span></p>
          <div style="position:relative">
            <input type="text" id="osCreateLink" class="form-input" readonly onclick="this.select()" style="padding-right:48px">
            <button type="button" class="os-copy-btn" onclick="osCopyResultLink()" title="링크 복사" style="position:absolute;right:1px;top:1px;bottom:1px;background:none;border:none;border-left:1px solid var(--line);cursor:pointer;padding:0 10px;display:flex;align-items:center"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--muted);transition:transform .1s">content_copy</span></button>
          </div>
          <div style="font-size:15px;color:var(--ink);margin-top:8px;font-weight:700">작성 기한: <span id="osCreateExpire" style="color:var(--pink)"></span></div>
          <hr style="border:none;border-top:1px solid var(--line);margin:16px 0">
          <div id="osRecipientPick" style="display:none;margin-top:12px">
            <label style="display:block;font-size:12px;font-weight:600;color:var(--muted);margin-bottom:4px">메일 받을 담당자</label>
            <select id="osRecipientSelect" class="form-input" onchange="osOnRecipientChange()"></select>
            <div id="osRecipientNew" style="display:none;margin-top:6px;gap:6px">
              <input id="osNewContactName" class="form-input" placeholder="담당자 이름" style="width:120px;flex-shrink:0">
              <input id="osNewContactEmail" class="form-input" type="email" placeholder="이메일 주소" autocomplete="off" oninput="osOnRecipientChange()" style="flex:1;min-width:0">
            </div>
          </div>
          <div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap">
            <button type="button" id="osSendMailBtn" class="btn btn-primary btn-sm" onclick="osSendInviteClick(this)"><span class="material-icons-round notranslate" translate="no" style="font-size:15px;vertical-align:-3px">mail</span> 메일 발송</button>
          </div>
          <div style="font-size:12px;color:var(--muted);margin-top:6px">메일은 자동 발송되지 않습니다. 필요하면 「메일 발송」을 눌러 브랜드 담당자에게 작성 링크를 보내세요.</div>
          <div id="osCreateMailStatus" style="margin-top:12px;font-size:13px;line-height:1.6"></div>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientCreateModal')">닫기</button>
        <button type="button" class="btn btn-primary" id="osCreateSubmitBtn" onclick="osSubmitCreate()">발급</button>
      </div>
    </div>
  </div>
  <div class="modal-overlay" id="orientDetailModal">
    <div class="modal" style="max-width:1040px;width:96vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2 id="osDetailTitle">오리엔시트 내용</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientDetailModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <!-- 좌우 2단(시트 내용 | 내부 메모)이라 스크롤은 각 칸이 따로 갖는다.
           여기서 overflow-y:auto 를 주면 바깥이 함께 스크롤돼 「따로 스크롤」이 깨진다. -->
      <div class="modal-body" style="padding:0;overflow:hidden;flex:1;min-height:0;display:flex" id="osDetailBody"></div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osOpenDetailNewWindow()"><span class="material-icons-round notranslate" translate="no" style="font-size:16px;vertical-align:-3px">open_in_new</span> 새창으로 열기</button>
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDetailModal')">닫기</button></div>
    </div>
  </div>
  <div class="modal-overlay" id="orientDeleteModal">
    <div class="modal" style="max-width:440px;width:94vw;border-radius:16px;margin:auto;display:flex;flex-direction:column">
      <div class="modal-header"><h2>오리엔시트 삭제</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientDeleteModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px">
        <p style="margin-bottom:10px">브랜드 <b id="osDeleteBrand"></b> 의 오리엔시트를 삭제합니다. 이 작업은 되돌릴 수 없습니다.</p>
        <div id="osDeleteCampWarn" style="display:none;margin-bottom:12px;padding:10px 12px;background:#FFF0F2;border:1px solid #F3C2CA;border-radius:8px;font-size:13px;color:#A11221"></div>
        <!-- 메모 경고는 발행 캠페인 경고와 별개 요소 — 둘이 동시에 떠야 하는 경우가 있다 -->
        <div id="osDeleteMemoWarn" style="display:none;margin-bottom:12px;padding:10px 12px;background:#FFF7E6;border:1px solid #F0D9A8;border-radius:8px;font-size:13px;color:#8A5A00"></div>
        <p style="font-size:13px;color:var(--muted);margin-bottom:6px">삭제하려면 브랜드명 「<span id="osDeleteBrandEcho" style="font-weight:700;color:var(--text,#161618)"></span>」 을 그대로 입력하세요.</p>
        <input type="text" id="osDeleteConfirmInput" class="form-input" oninput="osCheckDeleteConfirm()" autocomplete="off">
        <div id="osDeleteError" style="display:none;margin-top:8px;font-size:13px;color:#C41E3A"></div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientDeleteModal')">취소</button>
        <button type="button" class="btn" id="osDeleteBtn" style="background:#C41E3A;color:#fff" onclick="osExecuteDelete()" disabled>삭제</button>
      </div>
    </div>
  </div>
  <div class="modal-overlay" id="orientPublishModal">
    <div class="modal" style="max-width:520px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>발행 방식</h2>
        <button type="button" class="modal-close-btn" onclick="osCloseModal('orientPublishModal')"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" style="padding:20px;overflow-y:auto;flex:1">
        <div id="osPublishChoice">
          <p style="margin:0 0 14px;font-size:13px;color:var(--muted)">이 카드를 어떻게 발행할까요?</p>
          <button type="button" onclick="osChooseNewPublish()" style="display:block;width:100%;text-align:left;padding:14px;border:1px solid var(--line);border-radius:12px;background:#fff;cursor:pointer;margin-bottom:10px">
            <div style="display:flex;align-items:center;gap:8px;font-weight:700;color:var(--ink)"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--pink,#1A1A1A)">add_circle</span>신규 캠페인 발행</div>
            <div style="font-size:12px;color:var(--muted);margin-top:4px;padding-left:26px">오리엔시트 내용으로 캠페인 등록 폼을 자동 채워 새 캠페인을 만듭니다.</div>
          </button>
          <button type="button" onclick="osChooseLinkExisting()" style="display:block;width:100%;text-align:left;padding:14px;border:1px solid var(--line);border-radius:12px;background:#fff;cursor:pointer">
            <div style="display:flex;align-items:center;gap:8px;font-weight:700;color:var(--ink)"><span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:#1D4ED8">link</span>기존 캠페인 연결</div>
            <div style="font-size:12px;color:var(--muted);margin-top:4px;padding-left:26px">이미 등록된 같은 브랜드의 캠페인을 이 카드에 연결(발행 처리)합니다.</div>
          </button>
        </div>
        <div id="osLinkListView" style="display:none">
          <button type="button" class="btn btn-ghost btn-xs" onclick="osBackToPublishChoice()" style="margin-bottom:10px"><span class="material-icons-round notranslate" translate="no" style="font-size:15px;vertical-align:-3px">arrow_back</span> 선택으로 돌아가기</button>
          <input type="text" id="osLinkSearch" class="form-input" placeholder="캠페인명·번호 검색" autocomplete="off" oninput="osLinkListSearch()" style="margin-bottom:12px">
          <div id="osLinkListBody"></div>
        </div>
      </div>
      <div class="modal-footer">
        <button type="button" class="btn btn-ghost" onclick="osCloseModal('orientPublishModal')">닫기</button>
      </div>
    </div>
  </div>`;
  // #page-admin 안에 넣는다 — 이 요소가 z-index:200 으로 자체 쌓임 맥락을 만들어서,
  // body 직속에 붙이면 안쪽 관리자 모달(brandDetailModal z-index:612 등)이 이 모달보다
  // 아래로 깔린다(200 < 500). 같은 부모에 두면 z-index 숫자대로 겹친다.
  const host = document.getElementById('page-admin') || document.body;
  host.insertAdjacentHTML('beforeend', html);
  // 동적 생성된 오리엔 모달에 드래그·리사이즈 옵저버 부착(부트 시점엔 없던 overlay라 재등록 필요. 멱등)
  if (typeof initDraggableModals === 'function') initDraggableModals();
}

// 발급 모달 브랜드 검색 드롭다운 — 바깥 클릭 시 리스트 닫기 (combobox 표준 동작)
document.addEventListener('click', function(e) {
  const combo = document.getElementById('osCreateBrandCombobox');
  if (combo && !combo.contains(e.target)) {
    const list = document.getElementById('osCreateBrandList');
    if (list) list.classList.remove('open');
  }
});
