// ════════════════════════════════════════════════════════════════════
// 메타 픽셀 — 인플루언서 앱 공용 전송 함수 (사양서 docs/specs/2026-09-03-meta-pixel.md)
// ════════════════════════════════════════════════════════════════════
// 이 파일은 작업표 docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 5」가 채운다.
//   지금은 빌드 등록만 된 빈 뼈대다(작업 3) — 전송 코드가 없어 동작 변화 0.
//
// 🔴 인플루언서 앱 전용. 관리자 앱(dev/admin/index.html · ADMIN_JS_FILES)에는 넣지 않는다(사양서 ⑥).
// 🔴 이벤트 이름·상태 값은 여기 문자열로 쓰지 말고 dev/lib/shared.js 의
//    META_PIXEL_EVENTS · META_PIXEL_REG_STATUS 를 쓴다(이름 고정 — 결정 5).
// 🔴 아이디는 dev/lib/storage.js fetchPublicMetaPixelId() 로만 받는다 — '' = 보내지 않음, null = 조회 실패.
