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
    // ⚠️ img 를 허용하되 **주소는 아래 _applyContentImagePolicy 가 다시 거른다** —
    //    우리 저장소(https + *.supabase.co)만 남고 나머지는 지워진다. 특히 `data:` 가
    //    막히는 것이 중요하다. 이 칸이 원래 이미지를 통째로 막았던 이유가 붙여넣기로
    //    딸려오는 **base64 덩어리가 데이터베이스 글자 칸을 수 MB로 부풀리는 것**이었다
    //    (2026-08-12 에 허용으로 바꾸며 그 우려를 주소 화이트리스트로 대체).
    ALLOWED_TAGS: RICH_ALLOWED_TAGS.concat(['img']),
    ALLOWED_ATTR: RICH_ALLOWED_ATTR.concat(['src','alt','loading','decoding','data-rich-size']),
    FORBID_TAGS: ['script','iframe','style','object','embed','svg'],
    FORBID_ATTR: ['style','onerror','onload','onclick']
  });
  const wrapper = document.createElement('div');
  wrapper.innerHTML = clean;
  normalizeQuillLists(wrapper);
  normalizeLinks(wrapper);
  // 미니 에디터와 **같은 이미지 정책**을 쓴다(공용 함수) — 규칙이 갈리지 않게.
  _applyContentImagePolicy(wrapper);
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
  _applyContentImagePolicy(wrapper);
  return wrapper.innerHTML;
}

// 본문 이미지 정책 — **미니 에디터(주의사항·참여방법·NG)와 캠페인 리치 텍스트가 함께 쓴다.**
//   ⚠️ 두 곳에 복사하지 말 것. 규칙이 갈리면 「참여방법에서는 되는데 캠페인 설명에서는
//      안 되는」 식으로 어긋나고, 한쪽만 고친 채 배포되기 쉽다(2026-08-12 공용화).
//   허용 주소가 아니면 **지운다** — 외부 URL 직접 입력(추적·서버 공격)과 임시 주소
//   (blob:, data:, http:) 를 함께 막는다. data: 차단이 곧 **base64 폭증 방지**다
//   (캠페인 리치 텍스트가 원래 이미지를 통째로 막았던 이유 — FEATURE_SPEC §리치 텍스트).
function _applyContentImagePolicy(wrapper) {
  if (!wrapper) return;
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
    //   ⚠️ 캠페인 리치 텍스트(Quill)는 이 값을 **저장하지 못한다** — Quill 이미지 조각이
    //      alt·width·height 외 속성을 버리기 때문. 그래서 그쪽은 가로 100% 고정이다
    //      (2026-08-12 결정). 미니 에디터에서 넘어온 값만 여기서 살아난다.
    const size = (img.getAttribute('data-rich-size') || '').toLowerCase();
    if (size === 'sm' || size === 'md' || size === 'lg') {
      img.classList.add('rich-img-' + size);
    } else if (size && size !== 'orig') {
      // 알 수 없는 값은 정리 (직접 편집·복사 사고 방어)
      img.removeAttribute('data-rich-size');
    }
  });
}

// 오리엔시트 내부 메모 전용 sanitize.
// 허용: 굵게·기울임·밑줄·취소선 + 링크 + 단락(<p>)·줄바꿈(<br>)
// 차단: **이미지 포함** 그 외 전부
//
// ⚠️ sanitizeCautionHtml 을 재사용하지 않는 이유 —
//   그 함수는 허용 목록에 <img> 가 들어 있다(캠페인 안내문·오리엔 리뷰 가이드가
//   이미지를 정상적으로 쓴다). 메모는 「사진 붙이기 없음」이 확정 결정이라
//   붙여넣기로 들어온 이미지까지 지워야 하는데, 그렇다고 sanitizeCautionHtml 에서
//   이미지를 빼면 이미지를 쓰는 기존 화면이 전부 깨진다. 그래서 정책을 분리한다.
//   (사양서 docs/specs/2026-08-05-orient-sheet-internal-memo.md 확정 결정 ③)
//
// 저장할 때와 화면에 그릴 때 **양쪽에서** 부른다. 관리자가 다른 화면에서 복사해
// 붙인 내용이 저장된 뒤 다른 관리자 화면에 그려지므로 저장형 위험이 성립한다.
function sanitizeMemoHtml(html) {
  if (html == null) return '';
  if (typeof DOMPurify === 'undefined') {
    console.warn('[sanitizeMemoHtml] DOMPurify not loaded');
    return '';
  }
  // 사전 정규화: Chrome contenteditable 이 Enter 시 줄을 <div> 로 감싼다.
  // <div> 를 제거하면 줄바꿈이 사라지므로 허용 태그 <p> 로 먼저 치환.
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
    ALLOWED_TAGS: ['b','strong','i','em','u','s','strike','a','br','p'],
    ALLOWED_ATTR: ['href','target','rel'],
    FORBID_TAGS: ['img','script','iframe','style','object','embed','svg','div','span','ul','ol','li','h1','h2','h3','h4','blockquote','code','pre'],
    FORBID_ATTR: ['src','srcset','style','onerror','onload','onclick','onmouseover','onfocus','class','id']
  });
  const wrapper = document.createElement('div');
  wrapper.innerHTML = clean;
  // 링크 정규화: http/https/mailto 만 허용, target=_blank + rel=noopener 자동 부여
  wrapper.querySelectorAll('a[href]').forEach(a => {
    const href = (a.getAttribute('href') || '').trim();
    if (!/^https?:\/\/|^mailto:/i.test(href)) {
      if (/^[\w.-]+\.[a-z]{2,}/i.test(href)) {
        a.setAttribute('href', 'https://' + href.replace(/^\/+/, ''));
      } else {
        a.removeAttribute('href');
      }
    }
    a.setAttribute('target', '_blank');
    a.setAttribute('rel', 'noopener noreferrer');
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

// ══════════════════════════════════════════════════════════════════════════
// 캠페인 변경 이력 — 항목 이름·값을 사람이 읽는 말로 (마이그레이션 265·266)
//   기록은 컬럼 이름(min_followers)과 코드값(monitor)으로 남으므로, 화면에 그대로
//   내보내면 비개발자가 읽을 수 없다. 아래 표·헬퍼로 한국어 라벨을 붙인다.
//   ⚠️ 키 목록은 265 의 field_name 허용 목록(48개)과 같은 집합이어야 한다.
// ══════════════════════════════════════════════════════════════════════════
const CAMPAIGN_FIELD_LABELS = {
  title: '캠페인명', brand_id: '연결 브랜드', brand: '브랜드명', brand_ko: '브랜드명(한국어)',
  brand_ja: '브랜드명(일본어)', brand_en: '브랜드명(영문)', product: '제품명',
  product_ko: '제품명(한국어)', product_url: '제품 링크',
  recruit_type: '모집 형식', channel: '채널', channel_match: '채널 조건', primary_channel: '대표 채널',
  slots: '모집 인원', min_followers: '최소 팔로워 수', category: '카테고리', content_types: '콘텐츠 종류',
  product_price: '제품 가격', reward: '리워드 금액', reward_note: '리워드 안내',
  recruit_start: '모집 시작일', deadline: '모집 마감일', purchase_start: '구매 시작일',
  purchase_end: '구매 종료일', visit_start: '방문 시작일', visit_end: '방문 종료일',
  submission_end: '결과물 제출 마감일', winner_announce: '당첨 발표 안내',
  description: '캠페인 설명', appeal: '소구 포인트', guide: '촬영 가이드',
  hashtags: '필수 해시태그', mentions: '필수 멘션',
  img1: '이미지 1', img2: '이미지 2', img3: '이미지 3', img4: '이미지 4',
  img5: '이미지 5', img6: '이미지 6', img7: '이미지 7', img8: '이미지 8',
  image_url: '대표 이미지', image_crops: '이미지 자르기',
  status: '상태', proxy_purchase: '가구매 캠페인', source_application_id: '연결된 서베이 신청',
  deleted_at: '보관 삭제', deleted_by: '삭제한 사람'
};

// 값 종류별 표시 규칙 — 이미지·긴 글은 화면에서 따로 다루므로 여기선 종류만 알려준다
const CAMPAIGN_FIELD_KINDS = {
  image: ['img1','img2','img3','img4','img5','img6','img7','img8','image_url'],
  date: ['recruit_start','deadline','purchase_start','purchase_end','visit_start','visit_end','submission_end'],
  money: ['product_price','reward'],
  count: ['slots','min_followers'],
  rich: ['description','appeal','guide','reward_note','winner_announce'],
  lookupChannel: ['channel','primary_channel'],
  lookupContent: ['content_types'],
  lookupCategory: ['category']
};

function campaignFieldLabel(field) {
  return CAMPAIGN_FIELD_LABELS[field] || field;
}

function campaignFieldKind(field) {
  for (const kind in CAMPAIGN_FIELD_KINDS) {
    if (CAMPAIGN_FIELD_KINDS[kind].indexOf(field) >= 0) return kind;
  }
  return 'text';
}

// 이력에 저장된 값(jsonb) → 사람이 읽는 문자열. 이미지·긴 글은 화면 쪽에서 별도 처리.
function campaignFieldValueText(field, value) {
  if (value === null || value === undefined || value === '') return '';
  const kind = campaignFieldKind(field);
  const raw = String(value);
  if (kind === 'money') return Number(value).toLocaleString('ko-KR') + '엔';
  if (kind === 'count') return Number(value).toLocaleString('ko-KR') + (field === 'slots' ? '명' : '명 이상');
  if (kind === 'date') return raw.slice(0, 10).replace(/-/g, '/');
  if (kind === 'rich') return (typeof richToPlainText === 'function') ? richToPlainText(raw) : raw;
  // 이미지 자르기 좌표는 객체라 그대로 찍으면 [object Object] 가 된다 — 사람이 읽는 한 마디로
  if (field === 'image_crops') {
    try { return Object.keys(value || {}).length ? '이미지 자르기 위치 지정' : '지정 없음'; }
    catch (_e) { return ''; }
  }
  // 상태 코드 → 한국어. closed/ended 는 CAMPAIGN_STATUS_LABEL 의 키와 이름이 달라 따로 매핑.
  if (field === 'status') {
    return ({ draft: '준비', scheduled: '모집예정', active: '모집중',
              closed: '모집마감', ended: '종료', expired: '노출종료' })[raw] || raw;
  }
  if (field === 'recruit_type') return ({ monitor: '리뷰어형', gifting: '시딩(기프팅)형', visit: '방문형' })[raw] || raw;
  if (field === 'channel_match') return raw === 'and' ? '모든 채널(and)' : '채널 중 하나(or)';
  if (field === 'proxy_purchase') return (raw === 'true') ? '예' : '아니오';
  if (typeof getLookupLabelsJoined === 'function') {
    if (kind === 'lookupChannel') return getLookupLabelsJoined('channel', raw, ', ', 'ko');
    if (kind === 'lookupContent') return getLookupLabelsJoined('content_type', raw, ', ', 'ko');
    if (kind === 'lookupCategory') return getLookupLabelsJoined('category', raw, ', ', 'ko');
  }
  if (kind === 'image') return raw;   // 화면이 썸네일로 그림
  return raw;
}

// 해시태그 칸에 태그와 안내문이 함께 저장된 옛 데이터를 둘로 나눈다.
//   예) "#ピュアリカ #肌鎮静 ※ ハッシュタグは必ずフィードの本文にご記載ください。…"
//        → tags: "#ピュアリカ #肌鎮静" / note: "※ ハッシュタグは…"
//   ※(전각) 부터 뒤는 태그가 아니라 인플루언서 안내문이다. 태그로 쪼개면
//   낱말마다 태그가 생겨 인플루언서 화면이 망가지므로 반드시 분리해 보존한다.
//   (2026-07-27 운영 25건 확인)
function splitTagsAndNote(value) {
  const raw = String(value == null ? '' : value);
  const idx = raw.indexOf('※');
  if (idx < 0) return { tags: raw.trim(), note: '' };
  return { tags: raw.slice(0, idx).trim(), note: raw.slice(idx).trim() };
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

// ══════════════════════════════════════════════════════════════════════════
// 민감 항목(주의사항·참여방법·NG 사항) 변경 비교 — 캠페인 변경 이력 화면용
//
// 항목 본문은 리치 HTML(굵게·링크·이미지) 이라, HTML 문자열에 강조 태그를
// 그대로 끼워 넣으면 태그가 쪼개져 화면이 깨지고 보안 구멍이 된다. 그래서 항상
//   ① sanitize → ② 순수 텍스트 추출 → ③ 글자 단위 비교 → ④ 이스케이프 후 강조 조립
// 순서로만 다룬다. 원본 서식이 필요한 곳은 sanitizeCautionHtml 결과를 따로 보여준다.
// ══════════════════════════════════════════════════════════════════════════

// 글자 단위 비교 상한 — 넘으면 비교를 포기하고 호출부가 전문 비교로 폴백한다.
// (비교 비용이 두 글자 수의 곱이라, 긴 공지문 한 쌍이 화면을 수 초 멈출 수 있음)
const DIFF_CHAR_LIMIT = 1200;
// 삭제·추가 항목을 「수정」 한 쌍으로 볼 최소 닮은 정도
const DIFF_PAIR_THRESHOLD = 0.35;
// 이만큼 넘게 바뀌면 글자 강조를 포기하고 「전문 교체」로 표시 (전체가 노랑이 되는 것 방지)
const DIFF_FULL_REPLACE_RATIO = 0.6;

function _diffEsc(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 이미지 주소에서 파일명 꼬리만 — 이미지 교체를 글자 차이로 드러내되 주소 전체는 감춘다
function _diffFileTail(url) {
  const tail = String(url || '').split('?')[0].split('/').pop() || '';
  return tail ? (tail.length > 24 ? '…' + tail.slice(-24) : tail) : '없음';
}

// 리치 HTML → 순수 텍스트. 줄바꿈은 살리고 링크 주소·이미지 파일명은 자리표시자로 남겨
// 「이미지만 교체」·「링크 주소만 변경」도 글자 차이로 보이게 한다.
function richToPlainText(raw) {
  const value = raw == null ? '' : String(raw);
  if (!value) return '';
  if (!/<[a-z][\s\S]*>/i.test(value)) return value.trim();
  const host = document.createElement('div');
  host.innerHTML = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml(value) : '';
  host.querySelectorAll('img').forEach(img => {
    img.replaceWith(document.createTextNode('［이미지:' + _diffFileTail(img.getAttribute('src')) + '］'));
  });
  host.querySelectorAll('a[href]').forEach(a => {
    a.appendChild(document.createTextNode('（링크:' + (a.getAttribute('href') || '') + '）'));
  });
  host.querySelectorAll('br').forEach(br => br.replaceWith(document.createTextNode('\n')));
  host.querySelectorAll('p').forEach(p => p.appendChild(document.createTextNode('\n')));
  return (host.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n{2,}/g, '\n').trim();
}

// 글자 단위 비교 → [{type:'same'|'add'|'del', text}] 조각 배열. 상한 초과면 null.
// 일본어는 띄어쓰기가 없어 단어가 아닌 글자 단위가 맞다.
// Array.from 으로 코드포인트 단위 분해 — 이모지가 반 글자로 쪼개지지 않게.
function diffChars(a, b) {
  const A = Array.from(a == null ? '' : String(a));
  const B = Array.from(b == null ? '' : String(b));
  if (A.length > DIFF_CHAR_LIMIT || B.length > DIFF_CHAR_LIMIT) return null;
  const n = A.length, m = B.length, w = m + 1;
  // dp[i][j] = A[i..] 와 B[j..] 의 최장 공통 길이 (역추적을 위해 표 전체 보관)
  const dp = new Int32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * w + j] = (A[i] === B[j])
        ? dp[(i + 1) * w + (j + 1)] + 1
        : Math.max(dp[(i + 1) * w + j], dp[i * w + (j + 1)]);
    }
  }
  const out = [];
  const push = (type, ch) => {
    const last = out[out.length - 1];
    if (last && last.type === type) last.text += ch; else out.push({ type, text: ch });
  };
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { push('same', A[i]); i++; j++; }
    else if (dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]) { push('del', A[i]); i++; }
    else { push('add', B[j]); j++; }
  }
  while (i < n) { push('del', A[i]); i++; }
  while (j < m) { push('add', B[j]); j++; }
  return out;
}

// 바뀐 글자 비율 — 너무 크면 강조 대신 전문 교체로 보여준다
function diffChangeRatio(parts) {
  if (!Array.isArray(parts) || !parts.length) return 0;
  let same = 0, changed = 0;
  parts.forEach(p => { if (p.type === 'same') same += p.text.length; else changed += p.text.length; });
  const total = same + changed;
  return total ? changed / total : 0;
}

// 비교 조각 → 강조 HTML. 한 줄 안에 지워진 글자(취소선)와 새로 들어온 글자(밑줄)를
// 나란히 둔다 — 한글 문서 「변경 내용 추적」과 같은 방식. 안 바뀐 글자엔 아무 표시도 안 한다.
// (변경이 너무 많아 이 방식이 오히려 읽기 어려운 경우엔 호출부가 전문 비교로 폴백한다)
function diffCharsHtml(parts) {
  if (!Array.isArray(parts)) return '';
  return parts
    .map(p => {
      const html = _diffEsc(p.text).replace(/\n/g, '<br>');
      return p.type === 'same' ? html : '<span class="diff-mark diff-mark-' + p.type + '">' + html + '</span>';
    })
    .join('');
}

// 두 글의 닮은 정도(0~1) — 두 글자 묶음이 얼마나 겹치는지로 잰다.
// 「삭제 1개 + 추가 1개」가 사실은 「수정 1개」인지 판정하는 데 쓴다.
function textSimilarity(a, b) {
  const s1 = String(a == null ? '' : a), s2 = String(b == null ? '' : b);
  if (s1 === s2) return 1;
  if (!s1 || !s2) return 0;
  const grams = s => {
    const map = new Map();
    for (let i = 0; i < s.length - 1; i++) {
      const g = s.slice(i, i + 2);
      map.set(g, (map.get(g) || 0) + 1);
    }
    return map;
  };
  const g1 = grams(s1), g2 = grams(s2);
  let inter = 0, t1 = 0, t2 = 0;
  g1.forEach((c, g) => { t1 += c; if (g2.has(g)) inter += Math.min(c, g2.get(g)); });
  g2.forEach(c => { t2 += c; });
  if (!t1 || !t2) return 0;   // 한 글자짜리 항목 — 완전 일치는 위에서 이미 걸러짐
  return (2 * inter) / (t1 + t2);
}

// 비교에서 무시할 표시 보조 속성 — sanitize·렌더 단계가 자동으로 붙이는 값이라 내용 차이가 아니다
const DIFF_IGNORED_ATTRS = new Set(['class', 'loading', 'decoding']);
const _richCompareCache = new Map();
const RICH_COMPARE_CACHE_MAX = 400;

// 비교용 표준형 직렬화 — 태그명 + 속성을 이름순으로 정렬해 다시 조립한다.
// 속성 순서·여분 공백·빈 서식 태그처럼 「저장할 때마다 달라질 수 있는」 차이를 없앤다.
function _serializeRichForCompare(el) {
  let out = '';
  el.childNodes.forEach(node => {
    if (node.nodeType === 3) { out += String(node.nodeValue || '').replace(/\s+/g, ' '); return; }
    if (node.nodeType !== 1) return;
    const tag = node.tagName.toLowerCase();
    const attrs = Array.from(node.attributes || [])
      .filter(a => !DIFF_IGNORED_ATTRS.has(a.name))
      // 값 안의 큰따옴표는 치환 — 서로 다른 속성이 우연히 같은 비교 키로 겹치는 것 방지
      .map(a => a.name + '="' + String(a.value).replace(/"/g, '&quot;') + '"')
      .sort()
      .join(' ');
    const inner = _serializeRichForCompare(node);
    // 내용도 속성도 없는 빈 서식 태그(<p></p>, <b></b> 등)는 버린다 — 편집기가 남기는 흔적
    if (!inner && !attrs && tag !== 'br' && tag !== 'img') return;
    out += '<' + tag + (attrs ? ' ' + attrs : '') + '>' + inner + '</' + tag + '>';
  });
  return out;
}

// 리치 HTML → 비교용 표준형 문자열.
// ⚠️ 이걸 거치지 않고 원본 문자열을 그대로 비교하면, 이미지 태그의 속성 순서가 바뀐 것만으로도
//    「서식·링크·이미지만 변경」으로 잡힌다 (2026-07-27 운영 확인 사례).
function normalizeRichForCompare(html) {
  const value = String(html == null ? '' : html);
  if (!value) return '';
  const cached = _richCompareCache.get(value);
  if (cached !== undefined) return cached;
  let result;
  if (!/<[a-z][\s\S]*>/i.test(value)) {
    result = value.replace(/\s+/g, ' ').trim();
  } else {
    const host = document.createElement('div');
    host.innerHTML = (typeof sanitizeCautionHtml === 'function') ? sanitizeCautionHtml(value) : '';
    result = _serializeRichForCompare(host).replace(/\s+/g, ' ').trim();
    // sanitize 가 통째로 비워버린 경우(DOMPurify 미로드 등)엔 원문을 비교 기준으로 —
    // 모든 항목이 빈 값이 되어 「변경 없음」으로 잘못 판정되는 것을 막는다
    if (!result && value.trim()) result = value.replace(/\s+/g, ' ').trim();
  }
  if (_richCompareCache.size >= RICH_COMPARE_CACHE_MAX) _richCompareCache.clear();
  _richCompareCache.set(value, result);
  return result;
}

// 주의사항 항목의 언어별 본문. v1 옛 스냅샷(text_ko + 링크 + 뒷문구)도 합성해 되살린다.
// (합성 결과는 뒤에서 sanitizeCautionHtml 을 거치므로 위험한 주소는 걸러진다)
function _sensitiveCautionHtml(it, lang) {
  const direct = lang === 'ko' ? it.html_ko : it.html_ja;
  if (direct) return String(direct);
  const body = lang === 'ko' ? it.text_ko : it.text_ja;
  if (body == null && !it.link_url) return '';
  const label = (lang === 'ko' ? it.link_label_ko : it.link_label_ja) || it.link_url || '';
  const after = (lang === 'ko' ? it.text_after_ko : it.text_after_ja) || '';
  const link = it.link_url ? '<a href="' + _diffEsc(it.link_url) + '">' + _diffEsc(label) + '</a>' : '';
  return [body || '', link, after].filter(Boolean).join(' ');
}

// 항목 1개 → 비교용 표준형 {rawKey, textKey, ko:{html,text}, ja:{html,text}}
//   kind: 'caution' | 'ng' | 'participation'
function normalizeSensitiveItem(kind, item) {
  const it = item || {};
  let koHtml, jaHtml, koText, jaText;
  if (kind === 'participation') {
    const koTitle = String(it.title_ko || ''), jaTitle = String(it.title_ja || '');
    koHtml = String(it.desc_ko || ''); jaHtml = String(it.desc_ja || '');
    koText = [koTitle, richToPlainText(koHtml)].filter(Boolean).join('\n');
    jaText = [jaTitle, richToPlainText(jaHtml)].filter(Boolean).join('\n');
    return {
      rawKey: JSON.stringify([
        koTitle.replace(/\s+/g, ' ').trim(), jaTitle.replace(/\s+/g, ' ').trim(),
        normalizeRichForCompare(koHtml), normalizeRichForCompare(jaHtml)
      ]),
      textKey: koText + '\u0001' + jaText,
      title: { ko: koTitle, ja: jaTitle },
      ko: { html: koHtml, text: koText }, ja: { html: jaHtml, text: jaText }
    };
  }
  koHtml = kind === 'caution' ? _sensitiveCautionHtml(it, 'ko') : String(it.html_ko || '');
  jaHtml = kind === 'caution' ? _sensitiveCautionHtml(it, 'ja') : String(it.html_ja || '');
  koText = richToPlainText(koHtml);
  jaText = richToPlainText(jaHtml);
  return {
    rawKey: JSON.stringify([normalizeRichForCompare(koHtml), normalizeRichForCompare(jaHtml)]),
    textKey: koText + '\u0001' + jaText,
    title: null,
    ko: { html: koHtml, text: koText }, ja: { html: jaHtml, text: jaText }
  };
}

function normalizeSensitiveItems(kind, arr) {
  if (!Array.isArray(arr)) return null;              // null = 기록 없음 (빈 배열과 구분)
  return arr.map(it => normalizeSensitiveItem(kind, it));
}

// 전·후 목록의 내용이 완전히 같은지(순서 포함 X, 구성만) — 「번들만 교체」 판정용 경량 검사
function sensitiveListsIdentical(kind, prevArr, nextArr) {
  const p = normalizeSensitiveItems(kind, prevArr) || [];
  const n = normalizeSensitiveItems(kind, nextArr) || [];
  if (p.length !== n.length) return false;
  const bag = new Map();
  p.forEach(x => bag.set(x.rawKey, (bag.get(x.rawKey) || 0) + 1));
  for (const x of n) {
    const c = bag.get(x.rawKey) || 0;
    if (!c) return false;
    bag.set(x.rawKey, c - 1);
  }
  return true;
}

// 항목 단위 최장 공통 부분수열 → same/del/ins 연산 목록
function _sensitiveLcsOps(prev, next) {
  const n = prev.length, m = next.length, w = m + 1;
  const dp = new Int32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * w + j] = (prev[i].rawKey === next[j].rawKey)
        ? dp[(i + 1) * w + (j + 1)] + 1
        : Math.max(dp[(i + 1) * w + j], dp[i * w + (j + 1)]);
    }
  }
  const ops = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (prev[i].rawKey === next[j].rawKey) { ops.push({ op: 'same', p: i, n: j }); i++; j++; }
    else if (dp[(i + 1) * w + j] >= dp[i * w + (j + 1)]) { ops.push({ op: 'del', p: i }); i++; }
    else { ops.push({ op: 'ins', n: j }); j++; }
  }
  while (i < n) { ops.push({ op: 'del', p: i }); i++; }
  while (j < m) { ops.push({ op: 'ins', n: j }); j++; }
  return ops;
}

// 삭제·추가 묶음을 닮은 정도로 짝지어 「수정(mod)」·「서식만 변경(format)」으로 합친다.
// 짝을 못 찾은 것만 진짜 삭제·추가로 남는다.
function _pairDelInsRows(dels, inss, prev, next) {
  const rows = [];
  const usedIns = new Set();
  const bestMatch = (pi) => {
    let best = -1, bestScore = 0;
    inss.forEach(ni => {
      if (usedIns.has(ni)) return;
      const score = textSimilarity(prev[pi].textKey, next[ni].textKey);
      if (score > bestScore) { bestScore = score; best = ni; }
    });
    return { best, bestScore };
  };
  dels.forEach(pi => {
    const { best, bestScore } = bestMatch(pi);
    const paired = best >= 0
      && (bestScore >= DIFF_PAIR_THRESHOLD || prev[pi].textKey === next[best].textKey);
    if (!paired) { rows.push({ type: 'del', prev: prev[pi], prevIndex: pi }); return; }
    usedIns.add(best);
    rows.push({
      type: prev[pi].textKey === next[best].textKey ? 'format' : 'mod',
      prev: prev[pi], next: next[best], prevIndex: pi, nextIndex: best
    });
  });
  inss.forEach(ni => {
    if (!usedIns.has(ni)) rows.push({ type: 'add', next: next[ni], nextIndex: ni });
  });
  return rows;
}

// 전·후 항목 배열 비교 → 화면이 그대로 그릴 수 있는 줄 목록
// 반환 {status, rows, counts, orderOnly}
//   status: 'empty'(양쪽 다 없음) | 'no_prev'(이전 기록 없음) | 'no_next' | 'ok'
//   rows[].type: 'same' | 'add' | 'del' | 'mod'(글자 수정) | 'format'(서식·링크·이미지만 변경)
function diffSensitiveItemLists(kind, prevArr, nextArr) {
  const prev = normalizeSensitiveItems(kind, prevArr);
  const next = normalizeSensitiveItems(kind, nextArr);
  const empty = { status: 'empty', rows: [], counts: { add: 0, del: 0, mod: 0, format: 0, same: 0 }, orderOnly: false };
  if (prev === null && next === null) return empty;
  if (prev === null) {
    return {
      status: 'no_prev', orderOnly: false,
      rows: (next || []).map((it, idx) => ({ type: 'add', next: it, nextIndex: idx })),
      counts: { add: (next || []).length, del: 0, mod: 0, format: 0, same: 0 }
    };
  }
  if (next === null) {
    return {
      status: 'no_next', orderOnly: false,
      rows: prev.map((it, idx) => ({ type: 'del', prev: it, prevIndex: idx })),
      counts: { add: 0, del: prev.length, mod: 0, format: 0, same: 0 }
    };
  }
  if (!prev.length && !next.length) return empty;

  // 구성이 같고 순서만 다른 경우 — 삭제+추가 더미로 보이지 않게 별도 처리
  const orderOnly = sensitiveListsIdentical(kind, prevArr, nextArr)
    && prev.map(x => x.rawKey).join('') !== next.map(x => x.rawKey).join('');

  // 순서만 바뀐 경우는 항목별 비교를 건너뛴다 — 그대로 두면 「삭제 N + 추가 N」으로 부풀려 보인다
  if (orderOnly) {
    const bag = new Map();
    prev.forEach((x, i) => {
      if (!bag.has(x.rawKey)) bag.set(x.rawKey, []);
      bag.get(x.rawKey).push(i);
    });
    const rows0 = next.map((it, idx) => {
      const pool = bag.get(it.rawKey) || [];
      const pi = pool.length ? pool.shift() : null;
      return { type: 'same', prev: pi != null ? prev[pi] : it, next: it, prevIndex: pi, nextIndex: idx };
    });
    return {
      status: 'ok', rows: rows0, orderOnly: true,
      counts: { add: 0, del: 0, mod: 0, format: 0, same: rows0.length }
    };
  }

  const ops = _sensitiveLcsOps(prev, next);
  const rows = [];
  let k = 0;
  while (k < ops.length) {
    if (ops[k].op === 'same') {
      const p = prev[ops[k].p], n = next[ops[k].n];
      rows.push({ type: 'same', prev: p, next: n, prevIndex: ops[k].p, nextIndex: ops[k].n });
      k++;
      continue;
    }
    // 연속된 삭제·추가 묶음은 따로 모아 「수정」 쌍으로 재결합
    const dels = [], inss = [];
    while (k < ops.length && ops[k].op !== 'same') {
      if (ops[k].op === 'del') dels.push(ops[k].p); else inss.push(ops[k].n);
      k++;
    }
    _pairDelInsRows(dels, inss, prev, next).forEach(r => rows.push(r));
  }
  // 화면 순서는 「변경 후」 기준으로 — 삭제 줄은 원래 자리에 남긴다
  rows.sort((a, b) => {
    const av = (a.nextIndex != null) ? a.nextIndex : (a.prevIndex != null ? a.prevIndex - 0.5 : 0);
    const bv = (b.nextIndex != null) ? b.nextIndex : (b.prevIndex != null ? b.prevIndex - 0.5 : 0);
    return av - bv;
  });
  const counts = { add: 0, del: 0, mod: 0, format: 0, same: 0 };
  rows.forEach(r => { counts[r.type] = (counts[r.type] || 0) + 1; });
  return { status: 'ok', rows, counts, orderOnly };
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

// 감사용 계정 「감사용」 배지 HTML.
// inf: influencers 행(is_audit) 또는 is_audit 불리언을 가진 객체.
// 감사용이 아니면 빈 문자열 — 일반 인플루언서 행에는 아무것도 출력 안 함.
// 통계·산출물에서 격리된 계정임을 운영자가 한눈에 구분하도록 모든 인플·응모·결과물 행에 호출.
function auditBadgeHtml(inf) {
  if (!inf || !inf.is_audit) return '';
  return '<span class="audit-badge" title="감사용 계정 — 통계·산출물에서 격리됨" translate="no">감사용</span>';
}

// 감사용 계정(is_audit) 회원번호(influencers.id) 집합 생성.
// 관리자 화면에서 클라가 직접 응모 건수를 셀 때(빈자리·승인 차단) 감사용을 격리하기 위한 헬퍼.
// applications 행에는 is_audit 가 없으므로 users(fetchInfluencers, is_audit 포함)에서 만든 집합을
// user_id 로 대조한다(이메일 매칭보다 NULL·불일치·성능 위험이 없음).
function buildAuditIdSet(users) {
  return new Set((users || []).filter(u => u && u.is_audit).map(u => u.id));
}

// 특정 캠페인의 승인(approved) 응모 수를 감사용 제외로 계산.
//   apps: applications 배열, campId: 캠페인 id(null 이면 전체), auditIds: buildAuditIdSet 결과.
// 감사용 응모는 모집 슬롯·빈자리 집계에서 빠져야 한다(설계 격리, 마이그레이션 179·181).
function countNonAuditApproved(apps, campId, auditIds) {
  return (apps || []).filter(a =>
    a.status === 'approved'
    && (campId == null || a.campaign_id === campId)
    && !(auditIds && auditIds.has(a.user_id))
  ).length;
}

// 게시물(post) 채널이 캠페인이 요구하는 채널(channel 리스트)에 포함되는지 판정.
//   - 요구 채널 중 하나만 맞으면 통과(or 기준, 2026-06-16 사용자 결정).
//   - 캠페인 channel 이 비어 있으면(레거시·채널 미설정) 막지 않음(true) — 정상 제출 차단 방지.
//   - 인플 제출(addDraftUrl)·관리자 대리 등록(submitAdminProxyDelivProxy) 양쪽에서 공유.
//   - 최종 방어선은 서버 함수(admin_create_deliverable_proxy)이며 클라 검증은 즉시 안내용.
// 사양서: docs/specs/2026-06-16-post-channel-validation-and-proxy-replace.md
function postChannelMatchesCampaign(camp, postChannel) {
  if (!camp || !postChannel) return false;
  const list = String(camp.channel || '')
    .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
  if (list.length === 0) return true; // 채널 미설정 캠페인은 검증 우회(레거시 보호)
  return list.includes(String(postChannel).trim().toLowerCase());
}

// 결과물 게시물 URL 입력 오타 자동 보정 (2026-06-16). 인플 제출·관리자 대리 등록 공통.
//   명백한 오타만 고치고, 위험 스킴은 차단, 나머지는 그대로 검증.
//   - 앞뒤 공백 제거
//   - 흔한 스킴 오타(ttp:// · ttps:// · htp:// · htps:// · http// · http:/ 등) → https://
//     (SNS 게시물은 https 가 표준이라 https 로 통일)
//   - 스킴 없으면(instagram.com/...) https:// 자동 추가
//   - 위험 스킴(javascript: · data: · vbscript: · file: · blob:) → null 차단(XSS 방지)
//   - 최종 new URL 로 검증, http/https + 호스트 있는 것만 통과
//   반환: {url, changed} | null(빈값·위험 스킴·형식 오류). changed=보정 발생 여부(화면 안내용)
// 사양서: docs/specs/2026-06-16-post-channel-validation-and-proxy-replace.md
function normalizeUrlInput(raw) {
  let s = String(raw || '').trim();
  if (!s) return null;
  const orig = s;
  if (/^(javascript|data|vbscript|file|blob):/i.test(s)) return null; // 위험 스킴 차단
  if (/^https?:\/\//i.test(s)) {
    // 이미 정상 스킴 — 그대로
  } else if (/^h?t{1,2}ps?:?\/{1,2}/i.test(s)) {
    s = s.replace(/^h?t{1,2}ps?:?\/{1,2}/i, 'https://'); // 흔한 스킴 오타 → https://
  } else if (/^[a-z][a-z0-9+.\-]*:\/\//i.test(s)) {
    return null; // 알 수 없는 스킴 차단
  } else {
    s = 'https://' + s; // 스킴 없음 → https:// 추가
  }
  try {
    const u = new URL(s);
    if (u.protocol !== 'https:' && u.protocol !== 'http:') return null;
    if (!u.hostname) return null;
  } catch (e) { return null; }
  return { url: s, changed: s !== orig };
}

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
    // 임시저장(draft)은 「아직 안 낸 것」이라 판정에서 뺀다.
    //   ⚠️ 거르는 자리가 여기여야 한다 — 호출하는 쪽에서 걸러 오게 하면 한쪽이 빠뜨렸을 때
    //   두 화면이 다른 답을 낸다. 실제로 그랬다: 관리자 쪽 조회는 임시저장을 빼는데
    //   인플루언서 쪽은 안 빼서, 사진만 올려 두고 제출을 안 한 사람에게
    //   「제출하신 결과물을 확인 중입니다」가 떴다. 그 사람은 끝난 줄 알고 마감을 놓친다.
    const ds = (Array.isArray(delivs) ? delivs : []).filter(d => d && d.status !== 'draft');
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
  'errors': async () => {
    if (typeof loadClientErrors === 'function') await loadClientErrors();
  },
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
  'applications': async () => {
    if (typeof loadApplications === 'function') await loadApplications();
  },
  // 오프라인 행사 예약 현황은 이 페인의 **탭**이라 별도 항목이 없다 — 여기를 다시
  //   그리면 예약 표도 함께 갱신된다(loadCampApplicants 안에서 호출).
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
  'brands': async () => {
    if (typeof loadBrandsPane === 'function') await loadBrandsPane();
  },
  'brand-ops': async () => {
    if (typeof loadBrandOps === 'function') await loadBrandOps();
  },
  'brand-ops-detail': async () => {
    if (typeof loadBrandOpsDetail === 'function') await loadBrandOpsDetail();
  },
  'upcoming': async () => {
    // 읽기 전용 페인(CUD 없음) — 규칙 일관성 차원에서 등록(quality.md)
    if (typeof renderUpcomingFeatures === 'function') renderUpcomingFeatures();
  },
  'orient-sheets': async () => {
    if (typeof loadOrientSheets === 'function') await loadOrientSheets();
  },
  'permissions': async () => {
    if (typeof loadPermissionsPane === 'function') await loadPermissionsPane();
  },
  'settlements': async () => {
    // 처리(송금/보류/취소) 후 호출 — 상태가 바뀐 행을 정확히 반영해야 하므로 캐시 재렌더가 아니라
    // 재조회(reloadSettlementsData: fetchSettlements + renderSettlementsList + 배지)로 갱신한다.
    if (typeof reloadSettlementsData === 'function') await reloadSettlementsData();
    else if (typeof renderSettlementsList === 'function') await renderSettlementsList();
  },
  'outbound': async () => {
    // 명단 저장·삭제 모달 후 호출 — 재조회(fetchOutboundInfluencers + 목록 재렌더)로 갱신.
    if (typeof reloadOutboundData === 'function') await reloadOutboundData();
    else if (typeof renderOutboundList === 'function') renderOutboundList();
  },
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
// 연령 정책 — 클라이언트 만 나이 계산 (표시·UX용. 최종 차단 판정은 서버 트리거 check_age_policy)
//   가입 폼(PR 2)·응모 시점(PR 3) 공용. 'YYYY-MM-DD' 문자열 → 만 나이(정수) 또는 null.
//   서버와 동일하게 일본/한국 표준시(KST=JST) 기준.
// ══════════════════════════════════════
const AGE_POLICY_MIN_AGE = 18; // 가입·응모 최소 연령

function calcAgeFromBirthdate(birthdateStr) {
  if (!birthdateStr) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(birthdateStr);
  if (!m) return null;
  const by = +m[1], bm = +m[2], bd = +m[3];
  // 오늘(KST) 연·월·일
  const nowKst = new Date(Date.now() + (new Date().getTimezoneOffset() * 60000) + (9 * 3600000));
  const ty = nowKst.getFullYear(), tm = nowKst.getMonth() + 1, td = nowKst.getDate();
  let age = ty - by;
  // 올해 생일이 아직 안 지났으면 한 살 빼기
  if (tm < bm || (tm === bm && td < bd)) age--;
  return age;
}

// 생년월일 표시 라벨 (마이페이지·관리자 공용). lang 미지정 시 현재 언어.
function formatBirthdateLabel(birthdateStr, lang) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(birthdateStr || '');
  if (!m) return '';
  const y = +m[1], mo = +m[2], d = +m[3];
  const l = lang || (typeof getLang === 'function' ? getLang() : 'ja');
  return l === 'ko' ? `${y}년 ${mo}월 ${d}일` : `${y}年${mo}月${d}日`;
}

// 성별 코드 → 표시 라벨 (i18n 키 재사용). 빈 값이면 ''
function genderLabel(code) {
  const map = { male: 'auth.signup.genderMale', female: 'auth.signup.genderFemale',
    other: 'auth.signup.genderOther', undisclosed: 'auth.signup.genderUndisclosed' };
  if (!code || !map[code]) return '';
  return (typeof t === 'function') ? t(map[code]) : code;
}

// ══════════════════════════════════════
// 정책 변경 통지 (문의하기 기능 추가·약관 개정, 2026-05-27 즉시 시행·출시 안내)
//   - 로그인 1회 팝업 + 홈 상단 배너(노출 종료일까지). 관리자 등록 UI 없이 하드코딩 1건, DB 미사용.
//   - 노출 종료일(noticeUntil) 경과 시 팝업·배너 모두 자동 비노출 → 코드 즉시 제거 불필요(차기 정기 배포 때 정리).
//   - 관리자 페이지에는 해당 마크업이 없어 함수가 곧바로 return 됨(공유 파일이라 양쪽 로드).
// ══════════════════════════════════════
const POLICY_NOTICE = {
  // 연령 정책(만 18세 이상) 시행 예고. 공고일 2026-06-22 → 시행일 2026-07-22(공고+30일).
  id: 'agePolicy2026',          // localStorage 키 식별자
  effectiveDate: '2026-07-22',  // 시행일(본문 {date}·예고 표기용) = 공고일+30일
  noticeUntil: '2026-08-05',    // 노출 종료일 = 시행일+14일. 이 날 0시(KST)부터 자동 비노출
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

// 닫으면 자동 팝업이 다시 안 뜨도록 기록 (헤더 ×·배경 클릭 — 이번 닫기. 배너는 노출 종료일까지 유지)
function closePolicyNotice() {
  const modal = document.getElementById('policyNoticeModal');
  if (modal) modal.classList.remove('on');
  try { localStorage.setItem(_policyNoticeSeenKey(), '1'); } catch (e) {}
}

// 「다시 보지 않기」 — 팝업 + 헤더 배너(토스트) 모두 영구 종료(이 공지 한정).
//   seen(자동 팝업 차단) + dismissed(배너 영구 비노출) 둘 다 기록.
function _policyNoticeDismissedKey() { return _policyNoticeSeenKey() + '.dismissed'; }
function _isPolicyNoticeDismissed() {
  try { return localStorage.getItem(_policyNoticeDismissedKey()) === '1'; } catch (e) { return false; }
}
function neverShowPolicyNotice() {
  try {
    localStorage.setItem(_policyNoticeSeenKey(), '1');
    localStorage.setItem(_policyNoticeDismissedKey(), '1');
  } catch (e) {}
  const modal = document.getElementById('policyNoticeModal');
  if (modal) modal.classList.remove('on');
  const wrap = document.getElementById('policyNoticeBannerWrap');
  if (wrap) wrap.style.display = 'none';
}

// 팝업 「자세히 보기」 → 팝업 닫고(본 것으로 기록) 개인정보처리방침 전문 페이지로
function openPolicyNoticeLegal() {
  closePolicyNotice();
  if (typeof openLegalPage === 'function') openLegalPage('privacy');
}

// 홈 상단 배너 — fixed 오버레이라 홈에서만 노출. 닫기는 이번 방문만 숨김(부활).
//   홈 여부를 함수 자체에서 판정 → 로그인 직후·초기 로드 등 navigate 미경유 호출에서도 타 페이지 노출 방지.
function renderPolicyNoticeBanner() {
  const wrap = document.getElementById('policyNoticeBannerWrap');
  if (!wrap) return;
  const h = location.hash;
  const isHome = (h === '' || h === '#' || h === '#home');
  const show = isHome && currentUser && !currentUser._isAdmin && _policyNoticeActive() && !_policyBannerDismissed && !_isPolicyNoticeDismissed();
  if (!show) { wrap.style.display = 'none'; return; }
  // 배너 텍스트는 data-i18n="policyNotice.banner" 가 담당 → 언어 토글 시 applyI18n 이 자동 갱신
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

// ══════════════════════════════════════
// 오픈 예정 기능 보드 (관리자 전용, D-day) — DB 미사용·코드 상수
//   개발 세션이 시행일 걸린 기능을 운영 배포(또는 시행일 확정)할 때 항목 1줄 추가.
//   "개발 완료된 것만 노출" = 코드에 등록된 것만 뜨므로 구조적으로 보장.
//   effectiveDate 는 그 기능의 실제 시행일 상수와 동일값이어야 함(단일 소스 — 사양서 §7).
//   ※ 예고판일 뿐 기능 스위치가 아님. 실제 활성은 별도(시행일 머지 또는 서버 시각 판정).
//   공유 파일이라 인플루언서 앱에도 로드되나, 호출(렌더)은 관리자 페인에서만.
//   사양서 docs/specs/2026-06-15-admin-upcoming-features-board.md
// ══════════════════════════════════════
const UPCOMING_FEATURE_RETENTION_DAYS = 14; // 시행 후 며칠까지 「시행 완료」로 유지 노출
const UPCOMING_FEATURES = [
  // 실제 등록 형태(주석): 시행일 걸린 기능 배포 시 아래 형태로 1줄 추가
  // {
  //   key: 'age-policy-2026',                            // 식별자(중복 금지)
  //   title: '연령 정책(만 18세 이상)',                   // 기능명(관리자 화면 — 한국어)
  //   desc: '가입·응모 시 생년월일·성별 입력. 18세 미만 응모 불가.', // 상세 설명(한국어)
  //   effectiveDate: '2026-07-15',                       // 시행일(KST). 해당 기능 시행일 상수와 동일값
  // },
  {
    key: 'age-policy-2026',
    title: '연령 정책 (만 18세 이상)',
    desc: '가입·응모 시 생년월일·성별을 입력받습니다. 만 18세 미만은 캠페인 응모가 제한됩니다.',
    effectiveDate: '2026-07-22',  // 공고 2026-06-22 + 30일. 약관 부칙·age_policy_settings·POLICY_NOTICE 와 동일 시행일
  },
  {
    key: 'message-translation-2026',
    title: '메시지 자동 번역',
    desc: '응모건 메시지를 주고받을 때 상대 언어로 자동 번역해 함께 보여줍니다. (관리자↔인플루언서)',
    effectiveDate: '2026-07-22',  // 번역 기능 운영 활성화 예정일(개인정보처리방침 개정 시행일과 동일)
  },
];

// 시행일 자정(KST) 타임스탬프 — POLICY_NOTICE 선례와 동일 기준
function _upcomingEffectiveTs(item) {
  return new Date((item.effectiveDate || '') + 'T00:00:00+09:00').getTime();
}
// 오늘 0시(KST) 타임스탬프 — 날짜 단위 비교용(자정 경계 혼동 방지)
function _todayKstTs() {
  const now = new Date();
  const kst = new Date(now.getTime() + (now.getTimezoneOffset() * 60000) + (9 * 3600000));
  return new Date(kst.getFullYear() + '-' + String(kst.getMonth() + 1).padStart(2, '0')
    + '-' + String(kst.getDate()).padStart(2, '0') + 'T00:00:00+09:00').getTime();
}
// 항목 상태: 'upcoming'(D-n) | 'done'(시행 완료, 유지기간 내) | 'expired'(목록 제외)
function upcomingFeatureStatus(item, todayTs) {
  const eff = _upcomingEffectiveTs(item);
  if (isNaN(eff)) return 'expired';
  const today = (typeof todayTs === 'number') ? todayTs : _todayKstTs();
  if (today < eff) return 'upcoming';
  const expireTs = eff + UPCOMING_FEATURE_RETENTION_DAYS * 86400000;
  return (today < expireTs) ? 'done' : 'expired';
}
// 시행일까지 남은 일수(양수=예정, 0=당일, 음수=시행 경과)
function upcomingFeatureDday(item, todayTs) {
  const eff = _upcomingEffectiveTs(item);
  if (isNaN(eff)) return null;
  const today = (typeof todayTs === 'number') ? todayTs : _todayKstTs();
  return Math.round((eff - today) / 86400000);
}
// 시행일 라벨(한국어, 관리자 화면)
function upcomingFeatureDateLabel(item) {
  const d = new Date((item.effectiveDate || '') + 'T00:00:00+09:00');
  if (isNaN(d.getTime())) return item.effectiveDate || '';
  return `${d.getFullYear()}년 ${d.getMonth() + 1}월 ${d.getDate()}일`;
}
// 노출 대상(expired 제외) + 시행일 가까운 순 정렬
function visibleUpcomingFeatures() {
  const today = _todayKstTs();
  return UPCOMING_FEATURES
    .filter(it => upcomingFeatureStatus(it, today) !== 'expired')
    .sort((a, b) => _upcomingEffectiveTs(a) - _upcomingEffectiveTs(b));
}

// ══════════════════════════════════════
// 관리자 동적 권한 관리 — 권한 카탈로그 (코드 상수 단일 소스, PR1)
//   등급(campaign_admin/campaign_manager)별 접근 수준(write/read/hidden)은 DB
//   role_permissions 테이블(마이그레이션 207)에 저장 — 이 배열은 "기능이 무엇이
//   있는지"만 정의하는 카탈로그다. 새 페인·기능 추가 시 이 배열에 한 줄 + 시드
//   마이그레이션에 대응 행 추가(누락 시 has_permission() 이 안전측 거부=false).
//   ⚠️ PR1 시점에는 이 배열을 참조하는 코드가 아직 없다(순수 카탈로그). 메뉴 숨김·
//   버튼 비활성 등 실제 화면 분기는 PR2(설정 화면 + permLevel 헬퍼)부터 연결된다.
//   key 는 role_permissions.feature_key 와 1:1 대응(마이그레이션 207 시드 참조).
//   server_enforced=true 는 2단계(PR3+)에서 서버(has_permission RPC)로 실차단할
//   후보 — PR1 시점에는 서버 차단 여부와 무관하게 표시용 플래그일 뿐이다.
//   사양서 docs/specs/2026-06-15-admin-permission-management.md §3
//         docs/specs/2026-06-15-admin-permission-matrix.md §B(카탈로그 근거)
// ══════════════════════════════════════
// ══════════════════════════════════════
// 모집 마감 판정 — 화면과 서버가 같은 기준을 쓰게 한다 (사양서 2026-07-29 §설계 5)
//   서버 검사 장치(마이그레이션 272)는 (now() AT TIME ZONE 'Asia/Tokyo')::date <= deadline 으로
//   판정한다. 화면이 기기 로컬 시간을 쓰면 해외·시각 오설정 기기에서 하루 어긋나므로 여기서도
//   일본 시각으로 고정한다.
//   ⚠️ 단방향 규칙 — 화면은 서버보다 「더 닫는」 방향으로만 판정을 얹는다. 「더 여는」 판정 금지.
//      (화면 허용 + 서버 거부 = 인플루언서가 버튼을 눌렀는데 실패 = 혼선. 반대는 안전측)
// ══════════════════════════════════════
// 일본 시각(UTC+9) 기준 오늘 날짜 'YYYY-MM-DD'
function jstTodayStr() {
  return new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
}
// 모집 마감일이 지났는가 (마감일 당일 24시까지는 아직 안 지난 것으로 본다 = 서버와 동일)
//   마감일이 없으면 false(무기한) — 서버도 NULL 은 통과시킨다
function recruitDeadlinePassed(camp) {
  const dl = camp && camp.deadline;
  if (!dl) return false;
  return String(dl).slice(0, 10) < jstTodayStr();   // 'YYYY-MM-DD' 는 사전순 = 날짜순
}
// 결과물 제출 마감일이 지났는가 — 같은 기준(2단계 서버 차단과 정합)
function submissionDeadlinePassed(camp) {
  const se = camp && camp.submission_end;
  if (!se) return false;
  return String(se).slice(0, 10) < jstTodayStr();
}

// ══════════════════════════════════════
// 오프라인 행사 예약(티켓팅) — 마이그레이션 280~283
//   사양서: docs/specs/2026-07-30-offline-popup-ticketing.md
// ══════════════════════════════════════
// 행사(티켓) 캠페인인가.
//   ⚠️ 이 판정을 여러 곳에서 각자 만들지 않는다. 신청 게이트·활동관리 대체·타임
//      선택표·관리자 폼이 전부 이 함수 하나를 쓴다 — 판정이 두 벌이 되면 「어떤
//      화면에서는 행사인데 다른 화면에서는 아닌」 어긋남이 생긴다.
//   ⚠️ 모집 형식(recruit_type)으로 판정하지 않는다. 행사 캠페인도 형식은 방문형(visit)
//      그대로이고, 형식에 새 값을 만들지 않는 것이 이 기능의 설계 전제다(사양서 §3).
function isEventCampaign(camp) {
  return !!(camp && camp.event_mode === true);
}

// 비공개(초대 전용) 캠페인인가 — 목록 제외·상세 게이트 판정용.
//   화면 단계 필터라 이것만으로는 막히지 않는다. 실효 방어선은 예약 함수의
//   초대 번호 재검증이다(마이그레이션 283 reserve_event_ticket).
function isInviteOnlyCampaign(camp) {
  return !!(camp && camp.is_invite_only === true);
}

// 예약 타임 시작까지 남은 시간이 취소 마감(2시간)을 넘겼는가.
//   ⚠️ 화면 표시(취소 버튼 비활성)용 **안내**일 뿐이다. 실제 판정은 서버가 일본 시각
//      기준으로 한다(283 cancel_event_ticket) — 기기 시각은 믿지 않는다.
//      화면이 허용해도 서버가 cancel_window_passed 로 거부할 수 있고, 그 경우
//      호출부는 서버 답을 그대로 안내해야 한다.
const EVENT_CANCEL_WINDOW_HOURS = 2;
function eventCancelWindowPassed(slotDate, startTime) {
  if (!slotDate || !startTime) return false;
  // 'YYYY-MM-DD' + 'HH:MM' 또는 'HH:MM:SS' 를 일본 시각(+09:00)으로 명시해 해석한다.
  // 시간대를 안 붙이면 보는 사람 기기의 시간대로 해석돼 해외 접속 시 어긋난다.
  const ts = Date.parse(`${String(slotDate).slice(0, 10)}T${String(startTime).slice(0, 8)}+09:00`);
  if (!Number.isFinite(ts)) return false;
  return Date.now() > (ts - EVENT_CANCEL_WINDOW_HOURS * 3600 * 1000);
}

// ══════════════════════════════════════
// 캠페인 기간 표기 — 리뷰어형의 「모집 기간」과 「구매 기간」을
// 한 줄로 합칠지 판정한다(사양서 2026-08-06 결정 5).
//   ⚠️ 「구매 기간」의 옛 이름은 「구매 및 영수증 제출 기간」이었다. 2026-08-11 에
//      「영수증은 결과물 제출 마감일까지」로 확정하면서 그 이름이 사실과 달라져 바꿨다.
//   ⚠️ 판정을 화면마다 따로 만들지 않는다. 인플루언서 상세·관리자 미리보기가
//      이 함수 하나를 쓴다 — 두 벌이 되면 미리보기와 실제 화면이 어긋난다.
//   ⚠️ **번역문을 돌려주지 않는다.** 관리자 빌드(dev/build.sh ADMIN_JS_FILES)에는
//      i18n 파일이 없어 t() 가 존재하지 않는다. 코드값만 주고 문구는 각 앱이 고른다.
//
//   'merged'           = 리뷰어형 + 구매 두 칸 모두 값 있음 + 둘 다 모집 기간과 일치
//                        → 「모집 및 구매 기간」 한 줄, 날짜 한 줄
//   'split'            = 리뷰어형 + 구매 칸 중 하나라도 값 있으나 위 조건 불충족
//                        → 「모집 및 구매 기간」 한 줄, **날짜 두 줄에 각각 이름표**
//   'monitorNoPurchase'= 리뷰어형인데 구매 두 칸이 다 빔(운영 10건, 옛 캠페인)
//                        → merged 와 같게 그린다(2026-08-11 결정)
//   'visitMerged'      = 방문형 + 방문 기간이 모집 기간과 일치 → 「모집·방문」 한 줄
//   'visit'            = 방문형 + 방문 기간이 따로 있음 → 모집·방문 **두 줄**
//   'gifting'          = 시딩형 + 선정 기간에 값이 있음 → 모집·선정 **두 줄**
//   'none'             = 위 어디에도 안 드는 나머지 — 「모집 기간」 한 줄만.
//                        (선정 기간이 빈 시딩형, 방문 기간이 빈 방문형이 여기 온다)
//
// ⚠️ 2026-08-11 에 갈래를 넷으로 넓혔다. 그 전에는 `none` 이 「구매 칸 빈 리뷰어형」과
//    「시딩·방문형」 **두 뜻을 겸했다.** 「구매 칸이 비어도 합쳐 그린다」로 바뀌면서
//    그 겸용이 위험해졌다 — `none` 을 합치는 쪽에 넣으면 **구매라는 개념이 없는
//    시딩·방문형에까지 「구매 기간」이 붙는다.** 뜻을 갈라 두면 그 실수가 안 난다.
// ⚠️ 같은 날 `visit`·`gifting` 을 더해 여섯이 됐다. 관리자 캠페인 목록이 모집·구매·방문·
//    선정 네 기간을 **한 열**에 넣으면서, 그 열의 행마다 「(방문)」·「(선정)」 이름표를
//    붙여야 했기 때문이다. 그 전에는 방문형과 시딩형이 함께 `none` 이라 **두 번째 줄을
//    가진 행을 가려낼 수 없었다.** 두 번째 기간이 빈 캠페인은 그릴 줄이 없으므로 `none`.
// ⚠️ 새 호출부는 `!== 'split'` 같은 **부정 조건을 쓰지 말 것.** 갈래가 또 늘면
//    조용히 잘못된 쪽으로 빨려 들어간다. 원하는 갈래를 이름으로 지목한다.
function campaignPeriodRowKind(camp) {
  if (!camp) return 'none';
  // 리뷰어형이 아닌 갈래를 먼저 걸러낸다 — 아래 구매 기간 검사는 monitor 전용이다.
  if (camp.recruit_type === 'visit') {
    const vs = camp.visit_start || '', ve = camp.visit_end || '';
    if (!vs && !ve) return 'none';
    // 리뷰어형의 merged 와 같은 판정 — 날짜 문자열 그대로 비교한다(new Date() 금지).
    //   ⚠️ 방문형은 리뷰어형과 달리 **사람이 손으로 넣어 우연히 같아진 것**이다(리뷰어형은
    //      저장 규칙이 강제로 같게 만든다). 그래도 화면에 같은 날짜가 두 줄 나오는 모습은
    //      똑같아, 보는 사람에게는 구분할 이유가 없다(2026-08-12 결정).
    const rs = camp.recruit_start || '', dl = camp.deadline || '';
    if (vs && ve && rs && dl && vs === rs && ve === dl) return 'visitMerged';
    return 'visit';
  }
  if (camp.recruit_type === 'gifting') {
    return (camp.selection_start || camp.selection_end) ? 'gifting' : 'none';
  }
  if (camp.recruit_type !== 'monitor') return 'none';
  const ps = camp.purchase_start || '';
  const pe = camp.purchase_end || '';
  if (!ps && !pe) return 'monitorNoPurchase';
  const rs = camp.recruit_start || '';
  const dl = camp.deadline || '';
  // ⚠️ 비교는 날짜 문자열 그대로 한다. new Date() 로 바꾸면 시각·시간대가 끼어들어
  //    같은 날짜가 다르게 판정된다. recruit_start 가 비어 있으면(화면이 「오늘」로
  //    폴백하는 캠페인) 기준이 없으므로 merged 가 아니다.
  if (ps && pe && rs && dl && ps === rs && pe === dl) return 'merged';
  return 'split';
}

// 결과물 제출 마감 줄의 이름을 무엇으로 부를지(사양서 결정 7).
//   'receiptOnly'    = 가구매 리뷰어형 — 영수증만 낸다. 인증샷을 이름에 넣으면 사실과 다르다
//   'receiptAndPost' = 일반 리뷰어형 — 영수증 + 채널별 게시물 인증샷
//   'default'        = 시딩·방문형 — 이름을 바꾸지 않는다
function campaignSubmissionLabelCode(camp) {
  if (!camp || camp.recruit_type !== 'monitor') return 'default';
  return camp.proxy_purchase === true ? 'receiptOnly' : 'receiptAndPost';
}

// ══════════════════════════════════════
// 인플루언서 추천 명단(아웃바운드) — 세분(category)→계열(series) 매핑
//   lookup_values(ob_category/ob_series)에 부모 컬럼을 두지 않으므로(마이그레이션 227 주석)
//   이 코드 상수로 매핑한다. outbound_influencers.category_code 저장 시 series_code 자동 채움
//   (admin-outbound.js). HANDOFF §계열 매핑 확정표(2026-07-09)와 1:1.
//     뷰티 = 색조·기초 / 패션 = 패션 / 라이프 = 브이로그·키즈맘·헬스 / 푸드 = 푸드(독립) / 미분류 = 기타·테크
// ══════════════════════════════════════
const OB_CATEGORY_SERIES = {
  color:   'beauty',
  base:    'beauty',
  fashion: 'fashion',
  vlog:    'life',
  kidsmom: 'life',
  health:  'life',    // 헬스/다이어트 (마이그레이션 236, 2026-07-14)
  food:    'food',
  other:   'other',
  tech:    'other',   // 테크/기타 (마이그레이션 236, 2026-07-14)
};

const ADMIN_PERMISSION_CATALOG = [
  // ── 메뉴(페인) 21개 — dev/admin/index.html 사이드바 data-pane 과 1:1 ──
  //    (2026-07-29 menu.permissions 제거로 22 → 21)
  { key: 'menu.admin-notices',      label_ko: '공지사항',                     category: '공지',        server_enforced: false },
  { key: 'menu.upcoming',           label_ko: '오픈 예정 기능',               category: '공지',        server_enforced: false },
  { key: 'menu.dashboard',          label_ko: '전체 현황',                    category: '대시보드',    server_enforced: false },
  { key: 'menu.brand-ops',          label_ko: '운영 현황',                    category: '캠페인',      server_enforced: false },
  { key: 'menu.campaigns',          label_ko: '캠페인 관리',                  category: '캠페인',      server_enforced: false },
  { key: 'menu.applications',       label_ko: '인플 신청 관리',               category: '캠페인',      server_enforced: false },
  { key: 'menu.deliverables',       label_ko: '결과물 관리',                  category: '캠페인',      server_enforced: false },
  { key: 'menu.messages',           label_ko: '메시지',                       category: '캠페인',      server_enforced: false },
  { key: 'menu.brand-dashboard',    label_ko: '현황 대시보드',                category: '브랜드',      server_enforced: false },
  { key: 'menu.companies',          label_ko: '회사 관리',                    category: '브랜드',      server_enforced: false },
  { key: 'menu.brands',             label_ko: '브랜드 관리',                  category: '브랜드',      server_enforced: false },
  { key: 'menu.orient-sheets',      label_ko: '오리엔시트 현황',              category: '브랜드',      server_enforced: false },
  { key: 'menu.brand-applications', label_ko: '서베이 신청 목록',             category: '브랜드',      server_enforced: false },
  { key: 'menu.influencers',        label_ko: '인플루언서 목록',              category: '회원 관리',   server_enforced: false },
  { key: 'menu.settlements',        label_ko: '정산 관리',                    category: '회원 관리',   server_enforced: false },
  { key: 'menu.outbound',           label_ko: '인플루언서 추천 명단',         category: '회원 관리',   server_enforced: false },
  { key: 'menu.lookups',            label_ko: '기준 데이터',                  category: '관리자 설정', server_enforced: false },
  { key: 'menu.faq',                label_ko: '자주 묻는 질문',               category: '관리자 설정', server_enforced: false },
  // ⚠️ 관리자 계정 — 권한 관리 화면의 유일한 진입점(그 화면 안 「권한 관리」 버튼)이라
  //    슈퍼관리자는 이 메뉴를 숨길 수 없다(PERM_SUPER_LOCKED + 서버 271). 등급 2종은 자유.
  { key: 'menu.admin-accounts',     label_ko: '관리자 계정',                  category: '관리자 설정', server_enforced: false },
  { key: 'menu.errors',             label_ko: '오류 로그',                    category: '관리자 설정', server_enforced: false },
  { key: 'menu.my-account',         label_ko: '내 계정',                      category: '관리자 설정', server_enforced: false },
  // menu.permissions 는 2026-07-29 카탈로그에서 제거됨 — 사이드바 「권한 관리」 상설 항목을
  //   없애고 「관리자 계정」 화면 안 버튼으로 일원화해, 이 키가 제어할 대상이 사라졌다(죽은 설정).
  //   서버 잠금(270·271 의 write 고정)과 클라 PERM_DENYLIST·PERM_SUPER_LOCKED 항목은 방어로 남겨 둔다.

  // ── 주요 기능 20개 — server_enforced=true (2단계 서버 차단 후보, 매트릭스 §B) ──
  { key: 'influencer.sensitive_pii',      label_ko: '인플루언서 민감정보 열람(전화·주소·PayPal 등)', category: '인플루언서',   server_enforced: true },
  { key: 'influencer.excel_sensitive',    label_ko: '인플루언서 엑셀에 민감정보 포함',               category: '인플루언서',   server_enforced: true },
  { key: 'influencer.flag',               label_ko: '인플루언서 인증·블랙리스트·위반 등록',          category: '인플루언서',   server_enforced: true },
  { key: 'deliverable.receipt_edit',      label_ko: '영수증 정보 수정',                              category: '결과물',       server_enforced: true },
  { key: 'deliverable.proxy_create',      label_ko: '결과물 대리 등록',                              category: '결과물',       server_enforced: true },
  { key: 'company.cud',                   label_ko: '회사 등록·수정·삭제',                           category: '브랜드',       server_enforced: true },
  { key: 'brand.delete_merge',            label_ko: '브랜드 삭제·병합',                              category: '브랜드',       server_enforced: true },
  { key: 'lookup.cud',                    label_ko: '기준 데이터 등록·수정·삭제',                    category: '기준 데이터',  server_enforced: true },
  { key: 'faq.cud',                       label_ko: '자주 묻는 질문 등록·수정·삭제',                 category: 'FAQ',          server_enforced: true },
  { key: 'message.bulk_send',             label_ko: '메시지 일괄 발송·발송 이력 열람',               category: '메시지',       server_enforced: true },
  { key: 'message.hide',                  label_ko: '메시지 강제 숨김',                              category: '메시지',       server_enforced: true },
  { key: 'message.unhide',                label_ko: '메시지 숨김 복구',                              category: '메시지',       server_enforced: true },
  { key: 'notice.create',                 label_ko: '공지 작성',                                     category: '공지',         server_enforced: true },
  { key: 'notice.manage_others',          label_ko: '다른 관리자가 작성한 공지 수정·게시·회수',      category: '공지',         server_enforced: true },
  { key: 'campaign.caution_history_view', label_ko: '캠페인 변경 이력 열람',                       category: '캠페인',       server_enforced: true },
  { key: 'admin.manage',                  label_ko: '관리자 계정 추가·삭제',                         category: '관리자 설정',  server_enforced: true },
  { key: 'permissions.manage',            label_ko: '권한 관리 화면 접근',                           category: '관리자 설정',  server_enforced: true },
  // ── 정산(인플루언서 리워드) 2개 — 마이그레이션 220 role_permissions 시드와 1:1 (화면 menu.settlements 는 PR2) ──
  { key: 'settlement.view',               label_ko: '정산 조회',                                     category: '정산',         server_enforced: true },
  { key: 'settlement.pay',                label_ko: '정산 송금 처리',                                category: '정산',         server_enforced: true },
  // ── 인플루언서 추천 명단(아웃바운드) 1개 — 마이그레이션 228 role_permissions 시드와 1:1 ──
  //    RLS(마이그레이션 226)·Storage(229)가 has_permission('outbound.view', ...)로 서버 강제 → server_enforced=true.
  { key: 'outbound.view',                 label_ko: '인플루언서 추천 명단 조회·편집',                category: '회원 관리',    server_enforced: true },
];

// ══════════════════════════════════════
// 동적 권한 — 런타임 접근수준 맵 (부팅 시 role_permissions 로드). PR2 조각 B.
//   ⚠️ 이건 "화면 표시 제어"용이다. 실제 데이터 접근 차단이 아니다(서버 RLS·has_permission 이 방어선).
//   그래서 미로드·미등록·역할 미확정 시 fail-open('write' = 표시)한다 — 로드 실패로 관리자가 아무것도 못 보는 사고 방지.
//   (서버 has_permission 은 반대로 fail-closed = 미등록 거부. 표시는 관대·차단은 엄격.)
// ══════════════════════════════════════
let _rolePermMap = {};  // 'role|feature_key' → 'write'|'read'|'hidden'
function setRolePermMap(rows) {
  const m = {};
  (rows || []).forEach(r => { if (r && r.role && r.feature_key) m[r.role + '|' + r.feature_key] = r.access_level; });
  _rolePermMap = m;
}
const _PERM_RANK = { write: 2, read: 1, hidden: 0 };

// 이 설정이 「어디까지 실제로 먹히는지」 — ⚠️ **모든 등급에 해당한다**(슈퍼관리자 전용 판정 아님).
//   server = 서버가 데이터까지 막음  ·  client = 화면에서만 사라짐  ·  none = 아무 일도 안 일어남
//   ⚠️ none 인 항목들은 서버 가드가 is_campaign_admin() 하드코딩이고 화면 가드도 등급 직접 비교라
//      권한 설정을 무시한다 — **캠페인관리자·캠페인매니저 칸도 똑같이 무효다.**
//      2026-08-10(I-15) 에 화면 배지 이름을 「슈퍼 적용 안 됨」→「설정 미적용」으로 바꾸고
//      문구를 등급 중립으로 정정했다. 그 전에는 운영자가 그 칸을 「숨김」으로 두고 막혔다고 믿을 수 있었다.
//      그 12개를 진짜로 막으려면 서버 가드를 갈아끼우는 별도 작업이 필요하다
//      (사양서 docs/specs/2026-07-29-super-admin-self-restriction.md §1-5·§2-4).
const PERM_SUPER_SERVER_ENFORCED = [
  'influencer.sensitive_pii', 'settlement.view', 'settlement.pay',
  'outbound.view', 'campaign.caution_history_view'
];
function permSuperEffect(featureKey) {
  if (PERM_SUPER_SERVER_ENFORCED.indexOf(featureKey) >= 0) return 'server';
  if (featureKey.indexOf('menu.') === 0 || featureKey === 'influencer.excel_sensitive') return 'client';
  return 'none';
}
// 현재 관리자의 feature 접근수준. 역할 미확정·미로드·미등록=write(fail-open).
//   super_admin 도 이제 설정을 따른다(마이그레이션 268~270 — 스스로를 제한할 수 있음).
//   단 「행이 없으면 전권」은 서버 판정과 동일한 계약이라, 미등록 기본값 write 가 그대로 맞다.
//   ⚠️ 권한 관리 화면 진입만은 이 값을 보지 않는다(admin-core.js switchAdminPane) — 잠금 방지.
function permLevel(featureKey) {
  const role = (typeof currentAdminInfo !== 'undefined' && currentAdminInfo) ? currentAdminInfo.role : null;
  if (!role) return 'write';
  return _rolePermMap[role + '|' + featureKey] || 'write';
}
function canWrite(featureKey) { return (_PERM_RANK[permLevel(featureKey)] || 0) >= 2; }
function canRead(featureKey)  { return (_PERM_RANK[permLevel(featureKey)] || 0) >= 1; }
function isHidden(featureKey) { return permLevel(featureKey) === 'hidden'; }

// ══════════════════════════════════════
// 정산 인플루언서 공개 스위치 캐시 (2026-07-20)
//   settlement_settings.influencer_visible 를 is_settlement_public() 함수로 1회 조회해 캐싱.
//   현재는 「관리자만 기록」 단계라 기본 잠금(false) — 인플루언서에게 정산 메뉴·화면·알림을
//   일절 노출하지 않는다. 나중에 공개할 때는 DB 값만 true 로 바꾸면 되고 코드 수정은 없다.
//   미로드·조회 실패는 false(fail-closed) — 표시 쪽도 안전측으로 잠근다.
//   (관리자 메뉴 권한 캐시가 fail-open 인 것과 반대. 여기선 새어나가는 쪽이 더 위험하므로 엄격.)
//   ⚠️ 서버(행 단위 보안 정책·알림 발행 함수)도 같은 함수로 잠겨 있어 이 캐시는 표시용 보조다.
// ══════════════════════════════════════
let _settlementPublic = false;
function setSettlementPublic(v) { _settlementPublic = (v === true); }
function settlementPublic() { return _settlementPublic === true; }

// ══════════════════════════════════════
// 인플루언서 민감정보 마스킹 표시 헬퍼 (PR3 조각 B, 2026-07-06)
//   influencers_admin_view(마이그레이션 212)가 has_permission('influencer.sensitive_pii','read')
//   가 false인 관리자 등급에게 phone/line_id/paypal_email/zip/building/address 6종을
//   NULL로 내려줄 때, 화면에서 "진짜 미등록"과 "권한이 없어서 안 보임"을 구분해 표시한다.
//   반환값은 esc() 미적용 원문(호출부가 기존 row()/ellip() 패턴대로 esc() 적용) — 라벨
//   문자열 자체엔 특수문자가 없어 이중 escape 걱정 없음.
//
//   1) has_line/has_paypal 처럼 대응 존재 불리언이 있는 필드 — hasFlag 로 정확히 판정
//      (마스킹 여부와 무관하게 뷰가 항상 실제 존재 여부를 내려주므로 100% 정확).
function maskedFieldByFlag(val, hasFlag, registeredLabel) {
  if (val) return val;
  return hasFlag ? (registeredLabel || '등록됨(열람 권한 없음)') : '';
}
//   2) phone/zip/building/address 처럼 대응 불리언이 없는 필드 — 현재 로그인한 관리자의
//      클라 권한 레벨(canRead)로 근사 판정. canRead 가 false 면 서버가 무조건 NULL 을
//      주므로(진짜 값 유무와 무관) "열람 권한 없음"이 항상 정확. true 면 NULL 은 진짜
//      미등록이므로 emptyLabel(기본 빈 문자열, 호출부가 '—' 등으로 폴백 처리)을 반환.
//      ⚠️ 이건 UX 라벨용 근사치이며 보안 경계가 아니다 — 실제 차단은 서버 뷰가 이미 함.
function maskedFieldByPermission(val, emptyLabel) {
  if (val) return val;
  if (typeof canRead === 'function' && !canRead('influencer.sensitive_pii')) return '열람 권한 없음';
  return emptyLabel != null ? emptyLabel : '';
}

// ══════════════════════════════════════
// 캠페인 상태 표시 라벨 — closed(모집마감)/ended(종료)는 실제 DB 상태(마이그레이션 156).
//   ended = 결과물 제출 마감 경과(autoEndCampaigns 자동 전이). closed = 모집만 마감·제출 진행 중.
//   안전망: 자동 전이 전 closed + submission_end 경과분도 「종료」로 표시.
//   사양서 docs/specs/2026-05-27-campaign-status-label.md (B안 — 상태 분리)
// ══════════════════════════════════════
// 이 캠페인이 「다 끝난 날」 — 종료(ended) 판정의 기준.
//   보통은 결과물 제출 마감일이다. 그런데 **오프라인 행사 캠페인은 결과물이 없어**
//   그 날짜를 비워 두므로(EVENT_MODE_CLEARED_FIELDS), 기준이 없어서 「모집마감」에서
//   영영 안 넘어갔다. 행사는 마지막 방문일이 끝나는 날이다(방문 기간은 행사 시간에서 계산).
function campaignFinishDate(camp) {
  if (!camp) return null;
  if (camp.submission_end) return camp.submission_end;
  if (typeof isEventCampaign === 'function' && isEventCampaign(camp) && camp.visit_end) return camp.visit_end;
  return null;
}

function campaignStatusLabelKey(camp) {
  const s = camp && camp.status;
  if (s === 'ended') return 'closed_done';                 // 종료 (실제 상태)
  if (s === 'closed') {
    const _fin = campaignFinishDate(camp);
    const sub = _fin ? Date.parse(_fin) : null;
    if (sub && Date.now() > sub) return 'closed_done';     // 자동 전이 전 안전망 — 제출 마감 경과 = 종료
    return 'closed_recruit';                               // 모집마감(제출 진행 중)
  }
  return s; // draft / scheduled / active / expired
}
const CAMPAIGN_STATUS_LABEL = {
  draft: '준비', scheduled: '모집예정', active: '모집중',
  closed_recruit: '모집마감', closed_done: '종료', expired: '노출종료'
};
const CAMPAIGN_STATUS_BADGE_CLASS = {
  draft: 'badge-gray', scheduled: 'badge-blue', active: 'badge-green',
  closed_recruit: 'badge-pink', closed_done: 'badge-done', expired: 'badge-expired'
};

// 브랜드명 다국어 표시 헬퍼 (2026-06-08, 사양서 docs/specs/2026-06-08-brand-name-i18n.md)
//   캠페인 객체의 brand(한국어)/brand_ja/brand_en 비정규화 컬럼에서 화면별 우선순위로 선택.
//   관리자: 한국어 > 영어 > 일본어 / 인플루언서: 일본어 > 영어 > 한국어 (빈칸 방지 폴백).
//   brand 값은 brand_id 연결 캠페인의 경우 brands 마스터 동기화 복사본(트리거 173).
function brandLabelAdmin(c) {
  if (!c) return '';
  return (c.brand || c.brand_en || c.brand_ja || '').trim();
}
// 캠페인 미리보기 돋보기 버튼 — 관리자 목록 캠페인 열 공통. 이름 옆에 배치, 클릭 시 미리보기 모달.
//   (기존엔 캠페인명 자체 클릭으로 열렸으나, 명시적 버튼으로 통일 — 2026-06-17)
function campPreviewBtn(campId) {
  if (!campId) return '';
  return `<button type="button" onclick="event.stopPropagation();openCampPreviewModal('${esc(String(campId))}')" title="미리보기" style="flex-shrink:0;background:none;border:none;cursor:pointer;padding:0;margin:0;color:var(--muted);display:inline-flex;align-items:center;line-height:1"><span class="material-icons-round notranslate" translate="no" style="font-size:16px">search</span></button>`;
}
function brandLabelInflu(c) {
  if (!c) return '';
  return (c.brand_ja || c.brand_en || c.brand || '').trim();
}

// 숫자 입력칸(type=number): 포커스 중 마우스 휠로 값이 바뀌는 기본 동작 차단 (오입력 방지).
// 전역 1회 등록 → 관리자·인플 양쪽 빌드의 모든 숫자 입력칸에 일괄 적용. 휠은 페이지 스크롤만.
document.addEventListener('wheel', function (e) {
  const el = e.target;
  if (el && el.tagName === 'INPUT' && el.type === 'number' && document.activeElement === el) {
    e.preventDefault();
  }
}, { passive: false });

// ══════════════════════════════════════
// 제출 연타 잠금 (사양서 2026-07-31-duplicate-submit-guard-and-error-log-noise §3 단계 1)
// ══════════════════════════════════════
//
// 왜 필요한가 — 응모·결과물 제출 버튼을 빠르게 두 번 누르면 두 요청이 **둘 다** 중복 검사를
//   통과한다(검사와 저장 사이에 서버 왕복이 2~3번 있어 시간 창이 열려 있다). 첫 요청은
//   성공하는데 두 번째 요청의 실패 메시지가 뜨고 모달이 닫혀, **인플루언서는 응모에
//   실패한 줄 안다.** 실제로는 완료돼 있다(운영 오류 로그 실측 3회).
//
// ⚠️ **잠금은 「오류를 줄이는」 장치이지 「중복을 막는」 장치가 아니다.** 두 탭·두 기기·
//    뒤로가기 후 재제출은 이걸로 못 막는다. 중복의 최종 방어선은 데이터베이스 제약이고
//    그건 이미 있다. 이 헬퍼를 「중복 방지」로 이해하고 제약을 빼면 안 된다.
//
// ⚠️ **해제는 반드시 finally 에서 한 번만.** 적용 대상 함수들은 중간에 빠져나가는 지점이
//    3~6곳이라 개별 해제를 쓰면 반드시 하나가 빠지고, 그러면 **버튼이 영구히 잠긴다** —
//    중복 오류보다 나쁜 사고다(중복은 첫 요청이 성공이라도 하지만 영구 잠김은 제출 자체가
//    불가능해진다). 그래서 호출부가 해제를 못 하도록 헬퍼가 통째로 감싼다.
const _submitLocks = new Set();

// key       : 잠금 단위. 같은 키가 실행 중이면 두 번째 호출은 **조용히** 무시된다
//             (토스트도 안 띄운다 — 연타 2회째에 경고가 뜨면 그것대로 「실패했나」 오해가 된다).
//             채널별로 따로 눌러야 하는 리뷰 인증샷처럼 대상이 나뉘면 키에 그 값을 붙인다.
// btn       : 버튼 요소 또는 그 id. 없으면(null) 잠금만 걸고 화면은 안 건드린다.
// busyLabel : 진행 중 버튼에 표시할 문구. 비우면 문구는 그대로 두고 비활성만 한다.
//             ⚠️ 잠금만 하고 아무 표시가 없으면 「눌렀는데 반응이 없다」고 느껴 **오히려 더
//                누른다.** 진행 표시는 선택이 아니라 짝이다.
// fn        : 실제 작업. 반환값은 그대로 전달된다.
async function withSubmitLock(key, btn, busyLabel, fn) {
  if (_submitLocks.has(key)) return;
  _submitLocks.add(key);
  const el = (typeof btn === 'string') ? document.getElementById(btn) : btn;
  const prevHtml = el ? el.innerHTML : null;
  const prevDisabled = el ? el.disabled : null;
  if (el) {
    el.disabled = true;
    if (busyLabel) el.innerHTML = `<span class="btn-spinner"></span>${esc(busyLabel)}`;
  }
  try {
    return await fn();
  } finally {
    _submitLocks.delete(key);
    if (el) {
      el.disabled = (prevDisabled === true);
      if (busyLabel && prevHtml !== null) el.innerHTML = prevHtml;
    }
  }
}

// 화면 이탈 시 잠금 전체 비우기.
//   ⚠️ 이게 없으면 업로드 도중 화면을 나갔다 다시 들어왔을 때 키가 남아 **다음 제출이
//      조용히 막힌다**(아무 반응이 없어 원인을 알 수 없는 형태로). navigate 훅에서 부른다.
function clearSubmitLocks() {
  _submitLocks.clear();
}

// =============================================================================
// 앱 오류 기록 헬퍼 — 「사용자에게 문구만 보여주고 흔적은 안 남기는」 자리를 막는다
//   사양: docs/specs/2026-08-07-app-error-visibility.md
//
// 배경(실제 사고): 본인 응모 취소 함수가 2026-05-12 부터 약 3개월간 **모든 호출이 실패**
//   했는데 관리자 오류 로그에 흔적이 0건이었다. 원인은 두 겹 —
//     ① 데이터 접근 계층이 오류를 예외로 던지지 않고 `{ok:false, error}` 로 **반환**해
//        전역 미처리 예외 수집기에 안 걸렸고,
//     ② 화면이 그 값을 자체 문구 사전으로 매핑하며 `friendlyErrorJa()` 를 안 거쳐
//        「처리된 오류」 수집 훅(ui.js)도 안 돌았다.
//   그래서 인플루언서에게는 「취소하지 못했습니다」만 보이고 아무 데도 안 남았다.
//
// 이 헬퍼는 **화면 문구도 반환값도 바꾸지 않고 기록만 얹는다.** 오류를 예외로 승격하지
//   않는 이유: 승격하면 인플루언서 화면이 「아무 반응 없음」이 되어 지금보다 나빠진다.
//
// ⚠️ 인플루언서 앱 전용으로 동작한다. `collectClientError` 가 인플루언서 빌드에만
//    들어 있어(build.sh), 관리자 앱에서 부르면 조용히 아무 일도 하지 않는다.
//    관리자 앱 수집은 별도 작업.
// =============================================================================

// =============================================================================
// 알림 「한 번에 읽음 처리할 묶음」 (전수조사 F-3)
// =============================================================================
// 알림 하나를 누르면 같은 대상(ref_table + ref_id)의 안 읽은 알림을 함께 읽음 처리한다.
// 원래 의도는 **같은 사건이 여러 줄로 쌓인 경우**를 한 번에 정리하는 것이었다
//   (예: 관리자가 검수를 되돌렸다가 다시 처리 → 「변경됨」+「반려됨」 2건).
//
// ⚠️ 그런데 대상만 보고 종류를 안 봐서, **서로 다른 사건까지 함께 지워졌다.**
//    응모(applications)에는 성격이 전혀 다른 알림 4종이 같은 대상으로 달린다 —
//    「캠페인에 당첨되셨습니다」·「응모가 취소되었습니다」·「메시지가 도착했습니다」·
//    「제출 기한이 바뀌었습니다」. 메시지 알림 하나를 누르면 **당첨 알림이 소리 없이 사라졌다.**
//
// 그래서 「같은 것을 말하는 종류끼리만」 묶는다. 목록에 없는 종류는 자기 자신만 읽음 처리한다.
// ⚠️ 알림 종류를 새로 만들 때 여기 묶을지 판단할 것. **판단이 서지 않으면 넣지 마라** —
//    안 묶으면 알림이 하나 더 남을 뿐이지만, 잘못 묶으면 못 본 알림이 사라진다.
const NOTIF_READ_GROUPS = [
  // 결과물 한 건의 검수 상태가 오가며 쌓인 줄들 — 같은 것을 말한다
  ['deliverable_rejected', 'deliverable_changed', 'deliverable_approved', 'deliverable_proxy_submitted'],
];

// 이 종류와 함께 읽음 처리해도 되는 종류 목록. 묶음에 없으면 자기 자신만.
function notifReadKinds(kind) {
  if (!kind) return [];
  const group = NOTIF_READ_GROUPS.find(g => g.indexOf(kind) >= 0);
  return group ? group.slice() : [kind];
}

// 「미리 정의된 업무 거부」로 볼 패턴 — 결함이 아니라 정상 동작이다.
//   여기에 걸리면 기록은 하되 `is_expected=true` 로 표시해, 관리자 오류 로그에서
//   진짜 결함과 갈라 볼 수 있게 한다(전부 안 남기면 「거부가 늘었다」는 신호까지 잃는다).
//   ⚠️ 새 서버 거부 코드를 만들 때 여기에도 추가할 것 — 빠뜨리면 정상 거부가
//      「예상 못 한 오류」로 쌓여 진짜 결함이 묻힌다.
const APP_ERROR_EXPECTED_PATTERNS = [
  // 세션 만료 — 다시 로그인하면 되는 정상 상황
  /JWT expired|token is expired|invalid claim|refresh_token_not_found/i,
  // 비밀번호 재설정 링크가 만료됐거나 이미 쓰였을 때 — 화면이 「메일 다시 보내기」 안내로
  //   받아 주므로 결함이 아니다. 안 넣으면 사람이 오래된 링크를 열 때마다 배지가 오른다.
  /Auth session missing/i,
  // 새 비밀번호가 예전 것과 같을 때 — 다른 비밀번호를 넣으면 되는 정상 거부.
  //   ⚠️ 안 넣으면 사람이 같은 비밀번호를 넣을 때마다 「미해결」 배지가 오른다. 실제로
  //      운영에서 한 사람이 5번 반복해 그대로 쌓였다(2026-08-11~12). 화면이 이유를
  //      알려주도록 고친 것과 **한 세트**다 — 안내만 고치고 이 줄을 빠뜨리면 배지는 그대로다.
  /different from the old password|same_password/i,
  // 로그인·가입 거부 — 비밀번호 오입력·기가입·메일 미확인은 결함이 아니다.
  //   ⚠️ 메일 미확인은 서버가 주는 문구가 자리마다 다르다 — 코드값 `email_not_confirmed`
  //      와 사람이 읽는 `Email not confirmed`(공백) 둘 다 잡아야 한다. 하나만 넣으면
  //      운영에서 가장 흔한 거절이 「예상 못 한 오류」로 쌓인다(운영은 메일 확인 필수).
  /Invalid login credentials|already registered|already exists|email.?not.?confirmed/i,
  // 마감·정원·연령 등 서버가 코드 접두어로 거부하는 것들
  /recruit_deadline_passed|submission_deadline_passed|settlement_locked_receipt/,
  /campaign_deleted|recruit_not_open/,
  // 행사 응모는 이 화면에서 상태를 못 바꾼다(마이그레이션 289) — 서버의 의도적 거부.
  //   ⚠️ 2026-08-07 개발서버 검증에서 실제로 나온 값이다. 넣지 않으면 행사 캠페인
  //      취소 시도가 전부 「예상 못 한 오류」로 쌓여 배지가 부푼다.
  /event_status_change_blocked/,
  /모집 정원|slots_full|under_age|age_policy/,
  // 중복 — 첫 요청은 성공한 상태다(실패가 아니라 「이미 되어 있다」)
  /uidx_applications_user_campaign|applications_user_camp_active_uidx/,
  /deliverables_review_image_app_channel_uniq|uidx_deliverables_post_url/,
  /post_already_approved/,
];

// 오류 1건을 관리자 오류 로그로 보낸다. 절대 throw 하지 않는다.
//   context       : 어느 기능인지 나타내는 **고정 문자열**(함수 이름 권장).
//                   ⚠️ 사용자 입력값·식별자를 넣지 말 것 — 그대로 저장된다.
//   err           : Error 객체 · 문자열 · 서버가 준 거부 코드 아무거나
//   expectedCodes : 이 자리에서 「정상 거부」로 볼 코드 목록(배열). 화면이 이미 사전으로
//                   매핑하고 있는 코드들을 그대로 넘기면 된다.
function logAppError(context, err, expectedCodes) {
  if (typeof collectClientError !== 'function') return;   // 관리자 앱 등 — 무음
  try {
    const s = String((err && err.message) || err || '');
    if (!s) return;
    let expected = APP_ERROR_EXPECTED_PATTERNS.some(re => re.test(s));
    if (!expected && expectedCodes && expectedCodes.length) {
      expected = expectedCodes.some(c => c && (s === c || s.indexOf(c) >= 0));
    }
    collectClientError(err, 'handled', { context: context, expected: expected });
  } catch (_) { /* 기록 실패가 앱을 막지 않는다 */ }
}
