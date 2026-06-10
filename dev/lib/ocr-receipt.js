// ══════════════════════════════════════════════════════════════
// 영수증 글자인식(OCR) 공통 부품 — 기기 안 처리 (외부 전송 0)
//   엔진: Tesseract.js v5 (jpn+eng), CDN lazy-load
//   용도: 영수증 이미지에서 주문번호·구매일·구매금액을 읽어 입력칸에 미리 채움
//   인플루언서 활동관리(application.js) + 관리자 검수 모달(admin-deliverables.js) 공용
//   ⚠️ 읽은 값은 "보조 입력"일 뿐 — 항상 사용자/관리자가 확인·수정 후 제출.
//      라이브러리 로드 실패·인식 실패가 제출을 막지 않도록 호출측에서 try/catch.
// ══════════════════════════════════════════════════════════════

// Tesseract.js lazy-load (영수증 화면에서 OCR 실행할 때만 1회 로드, 이후 캐시)
let _tesseractPromise = null;
function _loadTesseract() {
  if (typeof window !== 'undefined' && window.Tesseract) return Promise.resolve(window.Tesseract);
  if (_tesseractPromise) return _tesseractPromise;
  _tesseractPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js';
    s.async = true;
    s.onload = () => (window.Tesseract ? resolve(window.Tesseract) : reject(new Error('Tesseract 로드 실패')));
    s.onerror = () => { _tesseractPromise = null; reject(new Error('Tesseract 스크립트를 불러오지 못했습니다')); };
    document.head.appendChild(s);
  });
  return _tesseractPromise;
}

// 이미지 전처리: 확대/축소 + 그레이스케일 + 대비 강화 (업로드 이미지와 무관한 임시 캔버스)
function preprocessReceiptImage(fileOrBlob) {
  return new Promise((resolve) => {
    const img = new Image();
    const url = URL.createObjectURL(fileOrBlob);
    img.onload = () => {
      URL.revokeObjectURL(url);
      // 작은 모바일 스크린샷은 확대해야 글자가 읽힌다(업스케일 필수, 0.5~3배).
      // 단 너무 커지면 모바일(iOS Safari) canvas 면적 한도에 걸려 잘리므로 MAX_AREA 로 cap.
      const target = 2000;
      const MAX_AREA = 4096 * 4096; // 모바일(iOS Safari) canvas 안전 면적
      let scale = Math.max(0.5, Math.min(target / img.naturalWidth, 3));
      let w = Math.round(img.naturalWidth * scale), h = Math.round(img.naturalHeight * scale);
      if (w * h > MAX_AREA) { const f = Math.sqrt(MAX_AREA / (w * h)); w = Math.floor(w * f); h = Math.floor(h * f); }
      const c = document.createElement('canvas');
      c.width = w; c.height = h;
      const ctx = c.getContext('2d');
      ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(img, 0, 0, w, h);
      try {
        const d = ctx.getImageData(0, 0, w, h), p = d.data;
        for (let i = 0; i < p.length; i += 4) {
          let g = p[i] * 0.299 + p[i + 1] * 0.587 + p[i + 2] * 0.114;
          g = (g - 128) * 1.35 + 128;
          g = Math.max(0, Math.min(255, g));
          p[i] = p[i + 1] = p[i + 2] = g;
        }
        ctx.putImageData(d, 0, 0);
      } catch (_e) { /* getImageData 실패 시 원본 캔버스 그대로 */ }
      c.toBlob(b => resolve(b || fileOrBlob), 'image/png');
    };
    img.onerror = () => { URL.revokeObjectURL(url); resolve(fileOrBlob); }; // HEIC 등 브라우저가 못 그리면 원본
    img.src = url;
  });
}

// 인식 텍스트에서 주문번호·구매일·구매금액 추출
//   일본어 OCR이 글자 사이에 공백을 끼우므로(예: "注文 番号") 줄별 공백을 제거한 뒤 매칭
//   반환: { order:string, date:'YYYY-MM-DD'|'', amount:number|null }
function extractReceiptFields(text) {
  const out = { order: '', date: '', amount: null };
  if (!text) return out;
  const compact = text.replace(/[ \t　]+/g, '');
  const cLines = compact.split(/\n/);

  // 구매일: YYYY年MM月DD日 / YYYY/MM/DD / YYYY-MM-DD / YYYY.MM.DD
  const m = compact.match(/(20\d{2})[年\/\-\.](\d{1,2})[月\/\-\.](\d{1,2})日?/);
  if (m) out.date = `${m[1]}-${String(m[2]).padStart(2, '0')}-${String(m[3]).padStart(2, '0')}`;

  // 주문번호: 注文番号/受注番号/オーダー番号/order 키워드 뒤 영숫자 (カート番号=카트번호는 제외)
  const om = compact.match(/(?:ご注文番号|注文番号|受注番号|オーダー(?:番号|ID)|order(?:no|number|id)?)[:：#＃]?([A-Za-z0-9\-]{6,})/i);
  if (om) {
    out.order = om[1];
  } else {
    const noCart = cLines.filter(l => !/カート番号|cart/i.test(l)).join('\n');
    const fm = noCart.match(/([0-9]{8,}|[A-Z0-9]{4,}-[A-Z0-9-]{4,})/);
    if (fm) out.order = fm[1];
  }

  // 구매금액: 円 또는 ¥ 붙은 숫자만 (천단위 점·콤마 혼동 허용). 合計/総額 줄 우선, 없으면 최대값.
  // ★금액은 compact(공백제거)가 아닌 '원본 줄'에서 추출한다 — 일본어 OCR 이 슬래시 "/"를 "7"로
  //   오독해 "数量:1 / 1,950円" → "数量 : 17 1.950 円" 이 될 때, 공백을 제거하면 "171.950円" 으로
  //   붙어 171950 으로 잘못 합쳐진다. 공백을 유지하면 "17" 과 "1.950 円" 이 분리돼 1,950 만 잡힌다.
  const amtKeys = /(合計|総額|総合計|お支払い?金額?|ご請求|請求金額)/;
  const rawLines = text.split(/\n/);
  function pick(line) {
    const tokens = [
      ...(line.match(/[¥￥]\s?[\d][\d.,]*/g) || []),
      ...(line.match(/[\d][\d.,]*\s*円/g) || [])
    ];
    return tokens.map(s => parseInt(s.replace(/[^\d]/g, ''), 10)).filter(n => n >= 10);
  }
  let keyA = [], allA = [];
  rawLines.forEach(l => { const n = pick(l); allA.push(...n); if (amtKeys.test(l.replace(/[ \t　]/g, ''))) keyA.push(...n); });
  const pool = keyA.length ? keyA : allA;
  if (pool.length) out.amount = Math.max(...pool);

  return out;
}

// 영수증 OCR 실행 — src: File | Blob | imageUrl(string)
//   opts.onProgress(stage, progress0to1) 콜백으로 단계 보고
//   반환: { text, fields, confidence }
async function runReceiptOcr(src, opts) {
  opts = opts || {};
  const onProgress = typeof opts.onProgress === 'function' ? opts.onProgress : function () {};
  let blob = src;
  if (typeof src === 'string') {
    onProgress('fetch', 0);
    const res = await fetch(src);
    if (!res.ok) throw new Error('이미지를 불러오지 못했습니다 (' + res.status + ')');
    blob = await res.blob();
  }
  onProgress('prepare', 0);
  const pre = await preprocessReceiptImage(blob);
  onProgress('load', 0);
  const T = await _loadTesseract();
  onProgress('recognize', 0);
  const { data } = await T.recognize(pre, 'jpn+eng', {
    logger: msg => { if (msg && msg.status === 'recognizing text') onProgress('recognize', msg.progress || 0); }
  });
  const text = (data && data.text) || '';
  return { text, fields: extractReceiptFields(text), confidence: (data && data.confidence) || 0 };
}

// 전역 노출 (빌드는 concat 전역 스코프지만 명시적으로도 등록)
if (typeof window !== 'undefined') {
  window.runReceiptOcr = runReceiptOcr;
  window.extractReceiptFields = extractReceiptFields;
}
