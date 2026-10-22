// ══════════════════════════════════════
// 관리자 — 브랜드 이용 제한·결과물 열람 정지 (개발서버만 · 마이그레이션 581~584)
//   사양서 docs/specs/2026-10-21-brand-account-restriction.md 4-7 · 작업표 …-breakdown.md 제한 9~11
//   서버 호출은 storage.js 감싸개 일곱(restrictBrandAccount … sendBrandSanctionMail)만 쓴다.
//   🔴 사유 이름표는 notify-brand-restriction 메일 함수와 사본 두 벌 — 한쪽을 바꾸면 함께.
//   모달·동작은 제한 10(계정 이용 제한)·제한 11(열람 정지)에서 채운다.
// ══════════════════════════════════════
