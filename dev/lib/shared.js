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

// Quill 2.x: bullet 리스트도 <ol><li data-list="bullet">로 저장 → <ul>로 정규화
function normalizeQuillLists(wrapper) {
  wrapper.querySelectorAll('ol').forEach(ol => {
    const items = Array.from(ol.children);
    if (!items.length) return;
    const bulletItems = items.filter(li => li.getAttribute && li.getAttribute('data-list') === 'bullet');
    const orderedItems = items.filter(li => li.getAttribute && li.getAttribute('data-list') === 'ordered');
    // 모두 bullet이면 전체를 <ul>로 변환
    if (bulletItems.length === items.length) {
      const ul = document.createElement('ul');
      items.forEach(li => {
        li.removeAttribute('data-list');
        ul.appendChild(li);
      });
      ol.replaceWith(ul);
      return;
    }
    // 혼합이면 연속된 bullet 묶음을 별도 <ul>로 분리 (간단 버전: 전체 data-list 제거)
    items.forEach(li => li.removeAttribute('data-list'));
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
    const tmp = document.createElement('div');
    tmp.textContent = String(html);
    return tmp.innerHTML;
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
