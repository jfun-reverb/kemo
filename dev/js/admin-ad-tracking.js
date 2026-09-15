// ════════════════════════════════════════════════════════════════════
// SECTION: AD-TRACKING — 관리자 「광고 추적」(메타 픽셀 설정) 페인
// ════════════════════════════════════════════════════════════════════
// 사양서 docs/specs/2026-09-03-meta-pixel.md 「관리 화면」
// 작업표 docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 4」가 채운다.
//   지금은 빌드 등록만 된 빈 뼈대다(작업 3).
//
// ⚠️ 이 파일은 dev/admin/index.html 에 <script> 태그를 넣지 않는다 — ADMIN_JS_FILES 한 곳에만 등록한다.
// ⚠️ 로더 이름 loadAdTrackingPane 은 shared.js PANE_REFRESHERS['ad-tracking'] 와
//    admin-core.js switchAdminPane loaders 가 함께 부른다 — 한쪽만 바꾸면 오류 없이 빈 화면이 된다.
// 🔴 이 페인은 설정만 다룬다. 관리자 앱에 픽셀 전송 코드를 넣지 않는다(사양서 ⑥).
