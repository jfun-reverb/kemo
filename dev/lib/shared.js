// ══════════════════════════════════════
// SHARED — 클라이언트/관리자 공유 변수 및 유틸
// ══════════════════════════════════════
var currentUser = null;
var currentUserProfile = null;
var currentCampaignId = null;
var allCampaigns = [];
// DEMO_CAMPAIGNS — Client의 campaign.js에서 덮어씀, Admin에서는 빈 배열
var DEMO_CAMPAIGNS = [];

// ══════════════════════════════════════
// 리치 텍스트 sanitize / render
// ══════════════════════════════════════
// 허용 태그/속성 (에디터 지원 범위와 일치)
const RICH_ALLOWED_TAGS = ['p','br','strong','b','em','i','u','s','strike','ul','ol','li','a','h2','h3','h4','blockquote','code','pre','span','div'];
const RICH_ALLOWED_ATTR = ['href','target','rel','class'];

// Quill 2.x: bullet 리스트도 <ol><li data-list="bullet">로 저장 → <ul>/<ol> 적절히 분리
function normalizeQuillLists(wrapper) {
  wrapper.querySelectorAll('ol').forEach(ol => {
    const items = Array.from(ol.children).filter(el => el.tagName === 'LI');
    if (!items.length) return;

    // 각 li의 유형(bullet/ordered) 파악
    const segments = []; // [{type: 'bullet'|'ordered', items: []}]
    let current = null;
    items.forEach(li => {
      const type = li.getAttribute('data-list') === 'bullet' ? 'bullet' : 'ordered';
      if (!current || current.type !== type) {
        current = { type, items: [] };
        segments.push(current);
      }
      li.removeAttribute('data-list');
      current.items.push(li);
    });

    // 한 종류만 있으면 단순 교체
    if (segments.length === 1) {
      if (segments[0].type === 'bullet') {
        const ul = document.createElement('ul');
        segments[0].items.forEach(li => ul.appendChild(li));
        ol.replaceWith(ul);
      }
      return;
    }

    // 혼합: 원래 <ol> 위치에 여러 <ul>/<ol>를 순서대로 삽입
    const parent = ol.parentNode;
    const frag = document.createDocumentFragment();
    segments.forEach(seg => {
      const list = document.createElement(seg.type === 'bullet' ? 'ul' : 'ol');
      seg.items.forEach(li => list.appendChild(li));
      frag.appendChild(list);
    });
    parent.replaceChild(frag, ol);
  });

  // 2026-05-07 추가: Quill 2.x root.innerHTML이 인접 같은-type 리스트를 분리해
  // 출력하는 케이스 회복 (공지 모달 ol이 5개로 쪼개져 모두 "1."로 보였던 문제).
  // wrapper 직속·중첩 어디서든 인접 동일 list는 1개로 병합.
  mergeAdjacentLists(wrapper);
}

// 빈 블록 판정: <p></p>, <p><br></p>, <p>&nbsp;</p>, <div></div> 등
// (Quill clipboard가 list 사이에 자동 삽입하는 placeholder)
function isEmptyBlock(el) {
  if (!el) return false;
  if (!['P','DIV'].includes(el.tagName)) return false;
  const text = (el.textContent || '').replace(/ /g, '').trim();
  return !text;
}

// 형제 노드 중 같은 type의 list가 연속이면 1개로 병합 (재귀).
// 사이에 빈 paragraph/div가 끼어 있어도 통과해 합친다 — Quill 2.x가
// paste/save 과정에서 list 사이에 <p><br></p>를 자주 삽입하기 때문.
function mergeAdjacentLists(parent) {
  if (!parent) return;
  let node = parent.firstElementChild;
  while (node) {
    let next = node.nextElementSibling;

    // node 자체가 list일 때만 병합 시도
    const isListNode = node.tagName === 'OL' || node.tagName === 'UL';
    if (isListNode && next) {
      // 빈 블록을 건너뛰며 다음 list 후보 탐색 (실제 제거는 병합 확정 후)
      const skipped = [];
      let probe = next;
      while (probe && isEmptyBlock(probe)) {
        skipped.push(probe);
        probe = probe.nextElementSibling;
      }
      // 같은 type list 발견 → 빈 블록 제거 + 병합
      if (probe && probe.tagName === node.tagName) {
        skipped.forEach(el => el.remove());
        while (probe.firstChild) node.appendChild(probe.firstChild);
        probe.remove();
        continue; // node 그대로 두고 다음 형제 재검사 (3개 이상 연속 대비)
      }
      // 다른 형제 — 빈 블록은 손대지 않고 next 그대로 진행
    }

    // 컨테이너성 자식(li, blockquote 등) 내부에도 적용
    if (node.children && node.children.length) mergeAdjacentLists(node);
    node = next;
  }
}

// 링크 href에 프로토콜 없으면 https:// 자동 추가 + 보안 속성
function normalizeLinks(wrapper) {
  wrapper.querySelectorAll('a[href]').forEach(a => {
    let href = (a.getAttribute('href') || '').trim();
    if (!href) { a.removeAttribute('href'); return; }
    // 내부 앵커 링크 (#으로 시작) / mailto / tel 은 그대로
    if (/^(#|mailto:|tel:)/i.test(href)) return;
    // http(s) 없으면 https:// 자동 부여
    if (!/^https?:\/\//i.test(href)) {
      href = 'https://' + href.replace(/^\/+/, '');
      a.setAttribute('href', href);
    }
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer nofollow');
  });
}

// HTML 문자열을 sanitize 해서 안전한 HTML 반환
function sanitizeRich(html) {
  if (html == null) return '';
  if (typeof DOMPurify === 'undefined') {
    console.warn('[sanitizeRich] DOMPurify not loaded — refusing to process rich content');
    return '';
  }
  const clean = DOMPurify.sanitize(String(html), {
    ALLOWED_TAGS: RICH_ALLOWED_TAGS,
    ALLOWED_ATTR: RICH_ALLOWED_ATTR,
    FORBID_TAGS: ['img','script','iframe','style','object','embed','svg'],
    FORBID_ATTR: ['style','onerror','onload','onclick']
  });
  const wrapper = document.createElement('div');
  wrapper.innerHTML = clean;
  normalizeQuillLists(wrapper);
  normalizeLinks(wrapper);
  return wrapper.innerHTML;
}

// 미니 에디터(주의사항·참여방법·NG) 전용 sanitize.
// 허용:
//   inline 서식: B/I/U/S 계열 + 링크
//   콘텐츠 블록: <p>, <br> (단락 + 줄바꿈)
//   이미지: <img src=https://*.supabase.co/...> 만 허용 (외부 도메인 차단)
// 차단:
//   <script>/<iframe>/<style>/<object>/<embed>/<svg>/<div>/<span>/<ul>/<ol>/<li>/<h1~h4>/<blockquote>/<code>/<pre>
//   onerror/onload/onclick/style/class 속성
// 이미지 후처리: 화이트리스트 통과 시 .rich-img 클래스·lazy 로딩 부여, 미통과는 제거.
//
// 관리자 미니 에디터(contenteditable) 의 paste·툴바 결과를 모두 본 함수로 통과시켜
// 저장 + 렌더 양쪽 모두 동일 정책 적용. 외부 URL 직접 입력은 src 화이트리스트로 차단.
function sanitizeCautionHtml(html) {
  if (html == null) return '';
  if (typeof DOMPurify === 'undefined') {
    console.warn('[sanitizeCautionHtml] DOMPurify not loaded');
    return '';
  }
  // 사전 정규화: Chrome contenteditable 이 Enter 시 줄을 <div> 로 감싼다.
  // sanitize 가 <div> 를 FORBID 으로 제거하면 줄바꿈이 모두 사라지므로,
  // 먼저 <div> 를 허용 태그 <p> 로 치환해 단락 구조 보존.
  // (Firefox 의 <br> 은 그대로 통과 — 양 브라우저 모두 안정.)
  let normalized = String(html);
  if (/<div\b/i.test(normalized)) {
    const tmp = document.createElement('div');
    tmp.innerHTML = normalized;
    tmp.querySelectorAll('div').forEach(d => {
      const p = document.createElement('p');
      while (d.firstChild) p.appendChild(d.firstChild);
      if (d.parentNode) d.parentNode.replaceChild(p, d);
    });
    normalized = tmp.innerHTML;
  }
  const clean = DOMPurify.sanitize(normalized, {
    ALLOWED_TAGS: ['b','strong','i','em','u','s','strike','a','br','p','img'],
    // data-rich-size: 이미지 사이즈 프리셋(sm/md/lg/원본). class 자체는 후처리에서 부여.
    ALLOWED_ATTR: ['href','target','rel','src','alt','data-rich-size'],
    FORBID_TAGS: ['script','iframe','style','object','embed','svg','div','span','ul','ol','li','h1','h2','h3','h4','blockquote','code','pre'],
    FORBID_ATTR: ['style','onerror','onload','onclick','onmouseover','onfocus','class','id']
  });
  const wrapper = document.createElement('div');
  wrapper.innerHTML = clean;
  // 링크 정규화: http/https/mailto 만 허용, target=_blank + rel=noopener 자동 부여
  wrapper.querySelectorAll('a[href]').forEach(a => {
    const href = (a.getAttribute('href') || '').trim();
    if (!/^https?:\/\/|^mailto:/i.test(href)) {
      // 프로토콜 없으면 https:// 자동 부여 시도
      if (/^[\w.-]+\.[a-z]{2,}/i.test(href)) {
        a.setAttribute('href', 'https://' + href.replace(/^\/+/, ''));
      } else {
        a.removeAttribute('href');
      }
    }
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer');
  });
  // 이미지 src 화이트리스트: https + Supabase Storage 도메인만.
  //   외부 URL 직접 입력 (예: evil.com) 차단 — 추적·서버 공격 가능성 0.
  //   소유 자산이 아닌 임시 URL(blob:, data:, http:) 도 차단.
  wrapper.querySelectorAll('img').forEach(img => {
    const src = (img.getAttribute('src') || '').trim();
    if (!_isAllowedContentImageSrc(src)) {
      img.remove();
      return;
    }
    // 표시 일관화: 가로 100% / 가운데 정렬 / 지연 로딩
    img.classList.add('rich-img');
    img.setAttribute('loading', 'lazy');
    img.setAttribute('decoding', 'async');
    // alt 누락 시 빈 문자열 (장식용으로 처리)
    if (!img.hasAttribute('alt')) img.setAttribute('alt', '');
    // 사이즈 프리셋: data-rich-size sm/md/lg/원본. 미지정 또는 'orig' 은 기본 가로 100%.
    const size = (img.getAttribute('data-rich-size') || '').toLowerCase();
    if (size === 'sm' || size === 'md' || size === 'lg') {
      img.classList.add('rich-img-' + size);
    } else if (size && size !== 'orig') {
      // 알 수 없는 값은 정리 (직접 편집·복사 사고 방어)
      img.removeAttribute('data-rich-size');
    }
  });
  return wrapper.innerHTML;
}

// 미니 에디터 콘텐츠 이미지 src 화이트리스트.
//   - https 만 허용 (http/data:/blob:/javascript: 모두 거부)
//   - 호스트는 *.supabase.co (운영·개발 Supabase Storage 모두 포함)
//   - 외부 이미지 hotlink 는 차단 — 운영자 업로드 자산만 정상 표시
function _isAllowedContentImageSrc(src) {
  if (!src || typeof src !== 'string') return false;
  try {
    const u = new URL(src);
    if (u.protocol !== 'https:') return false;
    // Supabase Storage 도메인 — 본 프로젝트는 모든 Storage 가 *.supabase.co
    if (!/\.supabase\.co$/i.test(u.hostname)) return false;
    return true;
  } catch (_e) {
    return false;
  }
}

// 미니 에디터(참여방법·주의사항·NG) 출력 렌더용 — sanitizeCautionHtml 경유.
//   - HTML 있으면 sanitizeCautionHtml (img/p/br + inline 서식 허용)
//   - 평문이면 esc + 줄바꿈→<br> (마이그레이션 110 백필 데이터 호환)
function miniRichHtml(raw) {
  const value = raw == null ? '' : String(raw);
  const looksLikeHtml = /<[a-z][\s\S]*>/i.test(value);
  if (!looksLikeHtml) {
    return value
      .replace(/&/g,'&amp;')
      .replace(/</g,'&lt;')
      .replace(/>/g,'&gt;')
      .replace(/\n/g,'<br>');
  }
  return (typeof sanitizeCautionHtml === 'function')
    ? sanitizeCautionHtml(value)
    : value.replace(/<script/gi, '&lt;script');
}

// 문자열 입력 → 안전한 HTML 문자열 반환 (템플릿 리터럴에서 바로 삽입용)
function richHtml(raw) {
  const value = raw == null ? '' : String(raw);
  const looksLikeHtml = /<[a-z][\s\S]*>/i.test(value);
  if (!looksLikeHtml) {
    return value
      .replace(/&/g,'&amp;')
      .replace(/</g,'&lt;')
      .replace(/>/g,'&gt;')
      .replace(/\n/g,'<br>');
  }
  return sanitizeRich(value);
}

// 평문(legacy) 감지 → HTML로 변환. 이미 HTML이면 sanitize만.
function renderRich(el, raw) {
  if (!el) return;
  const value = raw == null ? '' : String(raw);
  // HTML 태그가 없으면 기존 평문 데이터로 간주 → 이스케이프 + 줄바꿈
  const looksLikeHtml = /<[a-z][\s\S]*>/i.test(value);
  if (!looksLikeHtml) {
    const escaped = value
      .replace(/&/g,'&amp;')
      .replace(/</g,'&lt;')
      .replace(/>/g,'&gt;')
      .replace(/\n/g,'<br>');
    el.innerHTML = escaped;
    el.classList.add('rich-content');
    return;
  }
  el.innerHTML = sanitizeRich(value);
  el.classList.add('rich-content');
}

// ══════════════════════════════════════
// SNS 핸들 추출 / URL 생성
// ══════════════════════════════════════
// raw 입력값(URL 또는 핸들)에서 핸들만 뽑아 반환. 실패 시 trim된 원본 반환.
// 저장 정책: 핸들만(@ 없이) 저장. 표시 시 UI에서 @ prefix 부여.
// 관리자 목록 검색 공통 매칭 — 검색어를 공백(반각·전각 U+3000·연속)으로 나눈 각 단어가
// 검색 대상 필드들에 모두 포함되면 true. 단어 순서·공백 종류 무관.
// 일본어 제목의 전각 공백과 붙여넣은 반각 공백이 달라도 검색되도록 한다.
// searchVal 은 호출 측에서 trim().toLowerCase() 한 값을 넘긴다.
function matchSearchTokens(searchVal, fields) {
  const tokens = (searchVal || '').split(/[\s　]+/).filter(Boolean);
  if (!tokens.length) return true;
  const haystack = fields.map(v => (v || '').toLowerCase()).join(' ');
  return tokens.every(tok => haystack.includes(tok));
}

function extractSnsHandle(channel, raw) {
  if (!raw) return '';
  let s = String(raw).trim();
  if (!s) return '';
  // 입력값이 "@https://..." 형태일 수 있으므로 leading @ 임시 제거
  const withoutAt = s.replace(/^@+/, '');
  if (/^https?:\/\//i.test(withoutAt)) {
    try {
      const url = new URL(withoutAt);
      let path = url.pathname.replace(/^\/+|\/+$/g, '');
      if (!path) return s.replace(/^@+/, '');
      const segs = path.split('/');
      // 채널별 경로 매핑
      if (channel === 'youtube') {
        // /@handle, /c/name, /channel/UC...
        if (segs[0].startsWith('@')) return segs[0].slice(1);
        if (segs[0] === 'c' && segs[1]) return segs[1];
        if (segs[0] === 'channel' && segs[1]) return segs[1]; // UC...
        if (segs[0] === 'user' && segs[1]) return segs[1];
        return segs[0].replace(/^@+/, '');
      }
      if (channel === 'tiktok') {
        // /@handle 형식
        return (segs[0] || '').replace(/^@+/, '');
      }
      // instagram / x / twitter — 첫 segment가 핸들
      // IG는 p/ reel/ stories/ 같은 비-프로필 경로 제외
      if (channel === 'instagram' && /^(p|reel|reels|stories|explore|tv)$/i.test(segs[0])) {
        return s.replace(/^@+/, '');
      }
      if (channel === 'x' && /^(i|home|intent|search|messages|notifications|explore)$/i.test(segs[0])) {
        return s.replace(/^@+/, '');
      }
      return segs[0].replace(/^@+/, '');
    } catch (_) {
      return s.replace(/^@+/, '');
    }
  }
  // URL 아님: leading @ 와 공백만 정리
  return withoutAt.replace(/\s+/g, '');
}

// 핸들로 프로필 URL 생성. 빈 핸들이면 빈 문자열 반환.
function snsProfileUrl(channel, handle) {
  if (!handle) return '';
  const h = String(handle).replace(/^@+/, '');
  if (!h) return '';
  switch (channel) {
    case 'instagram': return `https://instagram.com/${encodeURIComponent(h)}`;
    case 'x':         return `https://x.com/${encodeURIComponent(h)}`;
    case 'tiktok':    return `https://tiktok.com/@${encodeURIComponent(h)}`;
    case 'youtube':
      // UCxxxxx 형태면 채널 ID 경로
      if (/^UC[A-Za-z0-9_-]{20,}$/.test(h)) return `https://youtube.com/channel/${encodeURIComponent(h)}`;
      return `https://youtube.com/@${encodeURIComponent(h)}`;
    default: return '';
  }
}

// ──────────────────────────────────────
// 응모건 상태 한 줄 판정 (FAQ §3-0) — 인플(messaging.js)·관리자(admin-messaging.js) 공용
// ──────────────────────────────────────
// 순수 함수로 추출해 양쪽이 동일 결과를 내도록 보장한다(사양서 §3-1 "동일 결과 대조").
// 인플 측은 _myDelivsByApp 전역과 _computeCancelPhase 를 쓰지만, 이 함수는
// 결과물 배열·캠페인 객체를 인자로 받아 전역 의존 없이 동작한다.

// 캠페인 일정 → 현재 단계(recruit/purchase/visit/post/other). mypage.js _computeCancelPhase 와 동일 로직.
function faqComputeCancelPhase(camp) {
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

// 응모 상태 + 결과물 배열 + 캠페인 → {key, stage} (§3-0 판정 순서)
//   status: applications.status (pending/approved/rejected/cancelled)
//   delivs: 해당 응모건의 deliverables 배열([{status}, ...]) — 없으면 []
//   camp:   캠페인 객체(recruit_type·일정 필드)
//   key:   상태 한 줄 문구 케이스, stage: relevant_stages 매칭 태그(null=태그 없음)
function faqComputeStatus(status, delivs, camp) {
  if (status === 'cancelled') return { key: 'cancelled', stage: null };
  if (status === 'rejected')  return { key: 'rejected',  stage: 'rejected' };
  if (status === 'pending')   return { key: 'pending',   stage: 'pending' };

  if (status === 'approved') {
    const ds = Array.isArray(delivs) ? delivs : [];
    // ① 결과물 상태를 일정보다 먼저 본다 (§3-0)
    if (ds.length) {
      const allApproved = ds.every(d => d.status === 'approved');
      const anyRejected = ds.some(d => d.status === 'rejected');
      if (allApproved) return { key: 'done', stage: 'done' };
      if (anyRejected) {
        const allRejected = ds.every(d => d.status === 'rejected');
        return { key: allRejected ? 'all_reject' : 'partial_reject', stage: 'approved_post' };
      }
      // pending(검수 대기) 포함, rejected 없음
      return { key: 'reviewing', stage: 'approved_post' };
    }
    // ② 결과물이 없으면 캠페인 일정으로
    const phase = faqComputeCancelPhase(camp);
    const isVisit = camp?.recruit_type === 'visit';
    if (phase === 'recruit') return { key: 'approved_purchase_before', stage: isVisit ? 'approved_visit' : 'approved_purchase' };
    if (phase === 'purchase') return { key: 'receipt', stage: 'approved_purchase' };
    if (phase === 'visit')    return { key: 'visit',   stage: 'approved_visit' };
    if (phase === 'post') {
      // 제출 마감(submission_end)이 없거나 이미 지났으면 'post_overdue'(기한 경과),
      // 마감이 아직 미래면(구매/방문 기간만 종료) 기존 'post_deadline'(날짜 안내).
      // stage 는 둘 다 approved_post 로 유지해 FAQ 트리 노드 매칭에 영향 없게 한다.
      const subEnd = camp?.submission_end ? Date.parse(camp.submission_end) : NaN;
      if (isNaN(subEnd) || Date.now() > subEnd) return { key: 'post_overdue', stage: 'approved_post' };
      return { key: 'post_deadline', stage: 'approved_post' };
    }
    return { key: 'approved_fallback', stage: null };
  }
  return { key: 'fallback', stage: null };
}

// ──────────────────────────────────────
// 관리자 페인 자동 갱신 헬퍼
// ──────────────────────────────────────
// 모달에서 저장한 직후 해당 페인의 목록·집계 영역이 stale 상태로 남는 패턴을
// 일관되게 차단한다. 모달 저장 함수 끝에서 「await refreshPane(paneId)」 한 줄만
// 호출하면 등록된 갱신 함수가 실행된다. 새 페인 추가 시 PANE_REFRESHERS 에만
// 한 행을 더한다 (.claude/rules/quality.md 「관리자 모달 페인 갱신」 룰 참조).
const PANE_REFRESHERS = {
  'influencers': async () => {
    if (typeof rerenderInfluencersFromCache === 'function') rerenderInfluencersFromCache();
    else if (typeof loadAdminInfluencers === 'function') await loadAdminInfluencers();
  },
  'brand-applications': async () => {
    if (typeof loadBrandApplications === 'function') await loadBrandApplications();
  },
  'admin-notices': async () => {
    if (typeof loadAdminNotices === 'function') await loadAdminNotices();
    if (typeof renderDashboardNotices === 'function') renderDashboardNotices();
  },
  'lookups': async () => {
    if (typeof renderLookupsTable === 'function') await renderLookupsTable();
  },
  'faq': async () => {
    if (typeof loadFaqPane === 'function') await loadFaqPane();
  },
  'admin-accounts': async () => {
    if (typeof loadAdminAccounts === 'function') await loadAdminAccounts();
  },
  'camp-applicants': async () => {
    if (typeof loadCampApplicants === 'function') await loadCampApplicants();
  },
  'deliverables': async () => {
    if (typeof renderDeliverablesList === 'function') await renderDeliverablesList();
  },
  'campaigns': async () => {
    // 관리자 캠페인 목록 갱신 — `loadCampaigns`(인플루언서 함수) 오참조 버그 수정
    if (typeof loadAdminCampaigns === 'function') await loadAdminCampaigns();
  },
  'messages': async () => {
    if (typeof refreshInboxData === 'function') await refreshInboxData();
  },
  'companies': async () => {
    if (typeof loadCompanies === 'function') await loadCompanies();
  },
  'brand-ops': async () => {
    if (typeof loadBrandOps === 'function') await loadBrandOps();
  },
  'brand-ops-detail': async () => {
    if (typeof loadBrandOpsDetail === 'function') await loadBrandOpsDetail();
  }
};
async function refreshPane(paneId) {
  const fn = PANE_REFRESHERS[paneId];
  if (!fn) { console.warn('[refreshPane] unknown paneId:', paneId); return; }
  try { await fn(); } catch(e) { console.warn('[refreshPane]', paneId, e); }
}

// SNS 4필드를 한 번에 정규화 (저장 직전 호출용)
function normalizeSnsFields(profile) {
  if (!profile || typeof profile !== 'object') return profile;
  const out = Object.assign({}, profile);
  if ('ig'      in out) out.ig      = extractSnsHandle('instagram', out.ig);
  if ('x'       in out) out.x       = extractSnsHandle('x',         out.x);
  if ('tiktok'  in out) out.tiktok  = extractSnsHandle('tiktok',    out.tiktok);
  if ('youtube' in out) out.youtube = extractSnsHandle('youtube',   out.youtube);
  return out;
}

// ══════════════════════════════════════
// 정책 변경 통지 (문의하기 기능 추가·약관 개정, 2026-05-27 즉시 시행·출시 안내)
//   - 로그인 1회 팝업 + 홈 상단 배너(노출 종료일까지). 관리자 등록 UI 없이 하드코딩 1건, DB 미사용.
//   - 노출 종료일(noticeUntil) 경과 시 팝업·배너 모두 자동 비노출 → 코드 즉시 제거 불필요(차기 정기 배포 때 정리).
//   - 관리자 페이지에는 해당 마크업이 없어 함수가 곧바로 return 됨(공유 파일이라 양쪽 로드).
// ══════════════════════════════════════
const POLICY_NOTICE = {
  id: 'inquiry2026',            // localStorage 키 식별자. 이전 'message2026'에서 변경 → 이미 본 사람도 새 안내 재노출
  effectiveDate: '2026-05-27',  // 시행일(완료형 표기용). ※ 운영 출시일로 1줄 수정
  noticeUntil: '2026-06-10',    // 노출 종료일 = 시행일 + 14일. 이 날 0시(KST)부터 자동 비노출. ※ 운영 출시 시 함께 조정
};
var _policyBannerDismissed = false;  // 배너 "이번 방문만 숨김" — 새로고침/재진입 시 초기화(부활)

// 출시 안내: 노출 종료일(noticeUntil) 전까지만 노출. 시행일은 완료형 표기용이라 판정에 안 씀
function _policyNoticeActive() {
  try { return Date.now() < new Date(POLICY_NOTICE.noticeUntil + 'T00:00:00+09:00').getTime(); }
  catch (e) { return false; }
}
function _policyNoticeSeenKey() { return 'reverb.policyNotice.' + POLICY_NOTICE.id; }

// 시행일을 현재 언어(ja/ko)에 맞게 표기 (운영은 ja 고정)
function _policyEffectiveLabel() {
  const d = new Date(POLICY_NOTICE.effectiveDate + 'T00:00:00+09:00');
  if (isNaN(d.getTime())) return POLICY_NOTICE.effectiveDate;
  const y = d.getFullYear(), m = d.getMonth() + 1, day = d.getDate();
  const lang = (typeof getLang === 'function' ? getLang() : 'ja');
  return lang === 'ko' ? `${y}년 ${m}월 ${day}일` : `${y}年${m}月${day}日`;
}

// 로그인 직후 1회 팝업 (init 말미 + SIGNED_IN 훅에서 공통 호출 — 내부 가드로 중복 방지)
function maybeShowPolicyNotice() {
  const modal = document.getElementById('policyNoticeModal');
  if (!modal) return;                                  // 관리자 페이지 등 마크업 없으면 무시
  if (!currentUser || currentUser._isAdmin) return;    // 로그인 회원만 (관리자 제외)
  if (!_policyNoticeActive()) return;                  // 노출 종료일 경과 시 침묵
  let seen = false;
  try { seen = localStorage.getItem(_policyNoticeSeenKey()) === '1'; } catch (e) {}
  if (seen) return;                                    // 이미 본 사람 (1회 제한)
  openPolicyNoticeModal();
}

function openPolicyNoticeModal() {
  const modal = document.getElementById('policyNoticeModal');
  if (!modal) return;
  const titleEl = document.getElementById('policyNoticeTitle');
  const bodyEl  = document.getElementById('policyNoticeBody');
  if (titleEl) titleEl.textContent = t('policyNotice.title');
  if (bodyEl) {
    // 본문은 자사 고정 문자열(i18n) + 시행일 상수만 주입 — 외부 입력 없음. 시행일은 esc 처리.
    bodyEl.innerHTML = t('policyNotice.body').replace('{date}', esc(_policyEffectiveLabel()));
  }
  modal.classList.add('on');
}

// 닫으면 다시 안 뜨도록 기록 (1회 제한)
function closePolicyNotice() {
  const modal = document.getElementById('policyNoticeModal');
  if (modal) modal.classList.remove('on');
  try { localStorage.setItem(_policyNoticeSeenKey(), '1'); } catch (e) {}
}

// 팝업 「자세히 보기」 → 팝업 닫고(본 것으로 기록) 개인정보처리방침 전문 페이지로
function openPolicyNoticeLegal() {
  closePolicyNotice();
  if (typeof openLegalPage === 'function') openLegalPage('privacy');
}

// 홈 상단 배너 — 홈 진입 시(navigate 'home') 호출. 닫기는 이번 방문만 숨김(부활).
function renderPolicyNoticeBanner() {
  const wrap = document.getElementById('policyNoticeBannerWrap');
  if (!wrap) return;
  const show = currentUser && !currentUser._isAdmin && _policyNoticeActive() && !_policyBannerDismissed;
  if (!show) { wrap.style.display = 'none'; return; }
  const textEl = document.getElementById('policyNoticeBannerText');
  if (textEl) textEl.textContent = t('policyNotice.banner');
  wrap.style.display = '';
}

function dismissPolicyNoticeBanner() {
  _policyBannerDismissed = true;
  const wrap = document.getElementById('policyNoticeBannerWrap');
  if (wrap) wrap.style.display = 'none';
}

// 배너 「자세히 보기」 → 요약 배너에서 전체 내용(팝업) 재오픈.
//   seen 플래그 무관(의도): 자동 1회 팝업만 제한하고, 배너 수동 재오픈은 시행일까지 몇 번이든 허용.
function openPolicyNoticeFromBanner() { openPolicyNoticeModal(); }
