// ════════════════════════════════════════════════════════════════════
// image-compress.js — 클라이언트 이미지 압축/HEIC 변환 공통 헬퍼
//   메시지 첨부(application-message-attachments) 업로드 전처리.
//   사양서 docs/specs/2026-05-15-application-messaging.md §3-2.
//   추후 영수증·캠페인 이미지 업로드에도 확산 적용 예정(§10).
//
//   - HEIC(iPhone 사진) 자동 감지 → JPEG 변환 (heic2any CDN lazy-load)
//   - Canvas 리사이즈: 긴 변 2048px, JPEG quality 0.85 에서 시작
//   - EXIF Orientation 자동 보정 (createImageBitmap imageOrientation)
//
//   🔴 **되도록 성공시키는 것이 이 함수의 일이다**(2026-08-31). 회원이 올리는 것은 대개
//      휴대폰으로 찍은 사진이라, 거부당하면 **크기를 줄일 수단도 고를 다른 사진도 없다.**
//      그래서 실패하기 전에 세 자리에서 한 번 더 시도한다:
//        · HEIC 변환 실패 → 원본 그대로 디코드(아이폰은 HEIC 를 스스로 연다)
//        · 디코드 실패    → `createImageBitmap` 2단 → `<img>` 폴백
//        · 용량 초과      → 품질을 0.7 → 0.55 → 0.4 로 낮춰 다시 굽는다
//      그래도 안 되면 그때 예외를 던진다.
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

// `<img>` 로 디코드한다 — `createImageBitmap` 이 못 여는 형식·브라우저의 마지막 수단.
//   ⚠️ 주소(objectURL)는 성공·실패 어느 쪽이든 반드시 되돌려준다(누수 방지).
function _decodeViaImgTag(blob) {
  return new Promise((resolve, reject) => {
    let url;
    try { url = URL.createObjectURL(blob); }
    catch (e) { reject(new Error('decode_failed')); return; }
    const im = new Image();
    im.onload = () => { URL.revokeObjectURL(url); resolve(im); };
    im.onerror = () => { URL.revokeObjectURL(url); reject(new Error('decode_failed')); };
    im.src = url;
  });
}

// 메인 압축 함수. file(File/Blob) → 압축된 JPEG File 반환.
// 실패 코드: 'heic_convert_failed' | 'decode_failed' | 'compress_failed' | 'too_large'
async function compressImageFile(file, opts = {}) {
  const cfg = Object.assign({}, IMG_COMPRESS_DEFAULTS, opts);
  let workBlob = file;
  let _heicFallback = false;   // HEIC 변환이 실패해 원본으로 디코드를 시도하는 중인가

  // 1) HEIC → JPEG 선변환
  if (isHeicFile(file)) {
    try {
      await loadHeic2any();
      const converted = await window.heic2any({ blob: file, toType: 'image/jpeg', quality: cfg.quality });
      workBlob = Array.isArray(converted) ? converted[0] : converted;
    } catch (e) {
      // 🔴 여기서 곧바로 포기하지 않는다 — **아이폰 사파리는 HEIC 를 스스로 디코드한다.**
      //    변환 라이브러리는 CDN 에서 받아 오는 것이라 통신 한 번 어긋나면 못 쓰는데,
      //    그때 원본을 그대로 넘기면 아이폰에서는 대개 그냥 열린다.
      //    ⚠️ 아래 디코드까지 실패하면 그때 `heic_convert_failed` 로 되돌린다 —
      //       원인 구분을 잃지 않기 위함이다(그냥 두면 `decode_failed` 로 뭉개진다).
      console.warn('[compressImageFile] HEIC 변환 실패 — 원본으로 디코드를 시도한다', e);
      _heicFallback = true;
      workBlob = file;
    }
  }

  // 2) 디코드 (EXIF Orientation 보정 — imageOrientation:'from-image')
  //   🔴 **세 단계로 버틴다.** 회원이 올리는 것은 대개 휴대폰으로 찍은 사진이라,
  //      여기서 포기하면 **회원에게 대안이 없다** — 크기를 줄일 수단도, 고를 다른 사진도 없다.
  //      그래서 같은 사진으로 계속 다시 시도하게 된다(2026-08-31 사용자 지적).
  let bitmap;
  try {
    bitmap = await createImageBitmap(workBlob, { imageOrientation: 'from-image' });
  } catch (e) {
    try {
      // 일부 브라우저는 옵션 미지원 → 옵션 없이
      bitmap = await createImageBitmap(workBlob);
    } catch (e2) {
      // ⚠️ 마지막 폴백 — `<img>` 로 디코드한다. `createImageBitmap` 이 못 여는 형식·브라우저가
      //    실제로 있다(특히 구형 사파리). `drawImage` 는 `<img>` 도 그대로 받는다.
      //    ⚠️ EXIF 회전은 요즘 브라우저가 `<img>` 에도 알아서 적용한다. 혹 안 되는 기기에서는
      //       **사진이 돌아가 보일 수 있는데, 아예 못 올리는 것보다 낫다**는 판단이다.
      try {
        bitmap = await _decodeViaImgTag(workBlob);
      } catch (e3) {
        console.error('[compressImageFile] 디코드 실패 (3단계 모두)', e3);
        // HEIC 변환이 실패해 원본으로 시도한 경우라면 원래 원인을 돌려준다
        throw new Error(_heicFallback ? 'heic_convert_failed' : 'decode_failed');
      }
    }
  }
  // `<img>` 는 `width` 가 배치 폭이라 `naturalWidth` 를 먼저 본다
  const srcW = bitmap.naturalWidth || bitmap.width;
  const srcH = bitmap.naturalHeight || bitmap.height;

  // 3) Canvas 리사이즈
  //   기본은 **긴 변** 기준(영수증·메시지 첨부 — 가로세로 어느 쪽도 너무 크면 안 된다).
  //   ⚠️ `maxWidth` 를 주면 **가로 폭만** 본다. 세로로 자른 긴 배너(캠페인 설명용)를
  //      긴 변 기준으로 줄이면 세로 길이 때문에 통째로 축소돼 **글자가 뭉개진다**.
  //      그런 이미지는 가로가 좁아 사실상 줄어들지 않는 것이 맞다.
  const scale = cfg.maxWidth
    ? Math.min(1, cfg.maxWidth / srcW)
    : Math.min(1, cfg.maxEdge / Math.max(srcW, srcH));
  // 3-1) 줄일 필요가 없으면 **원본 그대로** 돌려준다 (`keepIfSmall` 을 준 경우만).
  //   ⚠️ 다시 그리면 JPEG 로 바뀌어 **투명한 PNG 의 배경이 검게** 되고, 줄이지도 않으면서
  //      품질만 깎인다. 캠페인 설명 이미지는 대부분 이 경우다(가로가 화면 폭보다 좁다).
  //   ⚠️ 기존 호출부(메시지 첨부·영수증)는 **항상 JPEG 로 저장하는 전제**라 이 옵션을 주지
  //      않는다 — 반환 형식이 바뀌면 저장 경로의 확장자·형식과 어긋난다.
  if (cfg.keepIfSmall && scale === 1 && !isHeicFile(file)) {
    if (bitmap.close) bitmap.close();
    if (file.size > cfg.maxBytes) throw new Error('too_large');
    return file;
  }

  const w = Math.max(1, Math.round(srcW * scale));
  const h = Math.max(1, Math.round(srcH * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  ctx.drawImage(bitmap, 0, 0, w, h);
  if (bitmap.close) bitmap.close();

  // 4) JPEG 인코딩
  //   🔴 **한도를 넘으면 곧바로 포기하지 않고 품질을 낮춰 다시 굽는다.**
  //      휴대폰 사진은 회원이 스스로 줄일 수단이 없어, 여기서 거부하면 그 사진은 영영 못 올린다.
  //      ⚠️ 품질만 낮춘다 — 크기(픽셀)는 그대로 둔다. 영수증 작은 글씨가 읽혀야 하기 때문이다.
  //      ⚠️ 마지막 단계에서도 넘치면 그때 `too_large` 다(그 문구는 종전 그대로 쓰인다).
  let blob = null;
  for (const q of [cfg.quality, 0.7, 0.55, 0.4]) {
    blob = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', q));
    if (!blob) continue;                    // 이 품질에서 실패하면 다음 품질로
    if (blob.size <= cfg.maxBytes) break;   // 들어왔다
    blob = null;                            // 아직 크다 — 더 낮춰 본다
  }
  if (!blob) {
    // 마지막 품질에서도 못 만들었으면 무엇이 문제였는지 한 번 더 갈라 본다
    const last = await new Promise((res) => canvas.toBlob(res, 'image/jpeg', 0.4));
    if (!last) throw new Error('compress_failed');
    throw new Error('too_large');
  }

  const baseName = (file.name || 'image').replace(/\.[^.]+$/, '');
  return new File([blob], baseName + '.jpg', { type: 'image/jpeg' });
}
