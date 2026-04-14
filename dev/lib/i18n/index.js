// ══════════════════════════════════════
// i18n — 런타임 엔진 (언어 감지/전환/DOM 적용)
// ══════════════════════════════════════
(function() {
  const STORAGE_KEY = 'reverb.lang';
  const DEFAULT_LANG = 'ja';
  const SUPPORTED = ['ja', 'ko'];

  // 최초 언어 결정: localStorage > ?lang=xx (staging only) > 기본값
  function resolveInitialLang() {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved && SUPPORTED.includes(saved)) return saved;
    } catch(e) {}
    // 개발서버에서만 ?lang=ko 쿼리 허용 (테스트 편의)
    if (typeof IS_STAGING !== 'undefined' && IS_STAGING) {
      const q = new URLSearchParams(location.search).get('lang');
      if (q && SUPPORTED.includes(q)) return q;
    }
    return DEFAULT_LANG;
  }

  let currentLang = resolveInitialLang();

  function getDict(lang) {
    return (lang === 'ko' ? window.I18N_KO : window.I18N_JA) || {};
  }

  // 키 경로로 값 조회 (예: 'mypage.menu.applications')
  function lookup(dict, key) {
    if (!dict || !key) return undefined;
    return key.split('.').reduce((obj, k) => (obj && typeof obj === 'object') ? obj[k] : undefined, dict);
  }

  // 번역 헬퍼 (전역)
  window.t = function(key, fallback) {
    const primary = lookup(getDict(currentLang), key);
    if (primary !== undefined) return primary;
    // 폴백: JA → 키 자체
    const ja = lookup(getDict('ja'), key);
    if (ja !== undefined) return ja;
    return fallback !== undefined ? fallback : key;
  };

  // 현재 언어 조회
  window.getLang = function() { return currentLang; };

  // DOM 스캔하여 data-i18n 속성 치환
  window.applyI18n = function(root) {
    root = root || document;
    // 텍스트 치환: <span data-i18n="key">
    root.querySelectorAll('[data-i18n]').forEach(el => {
      const key = el.getAttribute('data-i18n');
      if (!key) return;
      const text = window.t(key);
      if (text !== undefined) el.textContent = text;
    });
    // HTML 치환: <div data-i18n-html="key"> (<br> 등 허용, 자체 문구만 사용)
    root.querySelectorAll('[data-i18n-html]').forEach(el => {
      const key = el.getAttribute('data-i18n-html');
      if (!key) return;
      const text = window.t(key);
      if (text !== undefined) el.innerHTML = text;
    });
    // 속성 치환: <input data-i18n-attr="placeholder:key,title:key2">
    root.querySelectorAll('[data-i18n-attr]').forEach(el => {
      const spec = el.getAttribute('data-i18n-attr');
      if (!spec) return;
      spec.split(',').forEach(pair => {
        const [attr, key] = pair.split(':').map(s => s.trim());
        if (attr && key) el.setAttribute(attr, window.t(key));
      });
    });
  };

  // 언어 전환
  window.setLang = function(lang) {
    if (!SUPPORTED.includes(lang)) return;
    currentLang = lang;
    try { localStorage.setItem(STORAGE_KEY, lang); } catch(e) {}
    document.documentElement.lang = lang === 'ko' ? 'ko' : 'ja';
    window.applyI18n(document);
    window.dispatchEvent(new CustomEvent('langchange', { detail: { lang } }));
  };

  // 초기 적용
  document.documentElement.lang = currentLang === 'ko' ? 'ko' : 'ja';
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => window.applyI18n(document));
  } else {
    window.applyI18n(document);
  }
})();
