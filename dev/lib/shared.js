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
