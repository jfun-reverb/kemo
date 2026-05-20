// ════════════════════════════════════════════════════════════════════
// image-compress.js — 클라이언트 이미지 압축/HEIC 변환 공통 헬퍼
//   메시지 첨부(application-message-attachments) 업로드 전처리.
//   사양서 docs/specs/2026-05-15-application-messaging.md §3-2.
//   추후 영수증·캠페인 이미지 업로드에도 확산 적용 예정(§10).
//
//   - HEIC(iPhone 사진) 자동 감지 → JPEG 변환 (heic2any CDN lazy-load)
//   - Canvas 리사이즈: 긴 변 2048px, JPEG quality 0.85
//   - EXIF Orientation 자동 보정 (createImageBitmap imageOrientation)
//   - 압축 후 2MB 초과 시 예외
// ════════════════════════════════════════════════════════════════════

const IMG_COMPRESS_DEFAULTS = {
  maxEdge: 2048,        // 긴 변 최대 픽셀 (영수증 작은 글씨 가독)
  quality: 0.85,        // JPEG 품질
  maxBytes: 2 * 1024 * 1024,  // 압축 후 한도 2MB
};

const HEIC2ANY_CDN = 'https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js';
let _heic2anyLoading = null;

// heic2any 라이브러리 lazy-load (한 번만)
function loadHeic2any() {
  if (typeof window.heic2any === 'function') return Promise.resolve();
  if (_heic2anyLoading) return _heic2anyLoading;
  _heic2anyLoading = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = HEIC2ANY_CDN;
    s.onload = () => resolve();
    s.onerror = () => { _heic2anyLoading = null; reject(new Error('heic2any_load_failed')); };
    document.head.appendChild(s);
  });
  return _heic2anyLoading;
}

// HEIC/HEIF 여부 판별 (MIME 또는 확장자)
function isHeicFile(file) {
  const type = (file.type || '').toLowerCase();
  const name = (file.name || '').toLowerCase();
  return /image\/(heic|heif)/.test(type) || /\.(heic|heif)$/.test(name);
}

// 메인 압축 함수. file(File/Blob) → 압축된 JPEG File 반환.
// 실패 코드: 'heic_convert_failed' | 'decode_failed' | 'compress_failed' | 'too_large'
async function compressImageFile(file, opts = {}) {
  const cfg = Object.assign({}, IMG_COMPRESS_DEFAULTS, opts);
  let workBlob = file;

  // 1) HEIC → JPEG 선변환
  if (isHeicFile(file)) {
    try {
      await loadHeic2any();
      const converted = await window.heic2any({ blob: file, toType: 'image/jpeg', quality: cfg.quality });
      workBlob = Array.isArray(converted) ? converted[0] : converted;
    } catch (e) {
      console.error('[compressImageFile] HEIC 변환 실패', e);
      throw new Error('heic_convert_failed');
    }
  }

  // 2) 디코드 (EXIF Orientation 보정 — imageOrientation:'from-image')
  let bitmap;
  try {
    bitmap = await createImageBitmap(workBlob, { imageOrientation: 'from-image' });
  } catch (e) {
    // 일부 브라우저는 옵션 미지원 → 폴백
    try { bitmap = await createImageBitmap(workBlob); }
    catch (e2) { console.error('[compressImageFile] 디코드 실패', e2); throw new Error('decode_failed'); }
  }

  // 3) Canvas 리사이즈 (긴 변 maxEdge)
  const scale = Math.min(1, cfg.maxEdge / Math.max(bitmap.width, bitmap.height));
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  ctx.drawImage(bitmap, 0, 0, w, h);
  if (bitmap.close) bitmap.close();

  // 4) JPEG 인코딩
  const blob = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', cfg.quality));
  if (!blob) throw new Error('compress_failed');
  if (blob.size > cfg.maxBytes) throw new Error('too_large');

  const baseName = (file.name || 'image').replace(/\.[^.]+$/, '');
  return new File([blob], baseName + '.jpg', { type: 'image/jpeg' });
}
