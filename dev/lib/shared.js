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
