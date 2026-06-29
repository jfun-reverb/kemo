// ════════════════════════════════════════════════════════════════════
// admin-roadmap.js — 오픈 예정 기능 보드 (관리자 전용, D-day)
//   데이터는 dev/lib/shared.js 의 UPCOMING_FEATURES 코드 상수(개발 세션 등록).
//   읽기 전용 — CUD 없음. 관리자 전원 노출(권한 분기 불필요).
//   사양서 docs/specs/2026-06-15-admin-upcoming-features-board.md
// ════════════════════════════════════════════════════════════════════

// 페인 진입 함수 — switchAdminPane loaders['upcoming'] 가 호출
function renderUpcomingFeatures() {
  const wrap = document.getElementById('upcomingFeaturesBody');
  if (!wrap) return;

  const items = (typeof visibleUpcomingFeatures === 'function') ? visibleUpcomingFeatures() : [];

  // 빈 상태
  if (!items.length) {
    wrap.innerHTML =
      '<div class="upcoming-empty">' +
      '<span class="material-icons-round notranslate" translate="no">event_available</span>' +
      '<div>현재 예정된 기능이 없습니다.</div>' +
      '</div>';
    return;
  }

  wrap.innerHTML =
    '<div class="admin-card" style="overflow-x:auto">' +
      '<table class="data-table upcoming-table">' +
        '<thead><tr>' +
          '<th>기능</th>' +
          '<th>상세 설명</th>' +
          '<th>시행일</th>' +
          '<th style="text-align:center">상태</th>' +
        '</tr></thead>' +
        '<tbody>' + items.map(buildUpcomingRow).join('') + '</tbody>' +
      '</table>' +
    '</div>';
}

// 항목 행(tr) 1개 HTML
function buildUpcomingRow(item) {
  const dday = upcomingFeatureDday(item);              // 양수=예정, 0=당일, 음수=시행 경과
  const dateLabel = upcomingFeatureDateLabel(item);

  // 배지는 D-day 값 기준 (사양서 §3). expired 항목은 visibleUpcomingFeatures 단계에서 이미 제외됨.
  let badgeText, badgeClass;
  if (dday > 0) {
    badgeText = 'D-' + dday;
    badgeClass = 'upcoming-badge-soon';
  } else if (dday === 0) {
    badgeText = 'D-DAY';
    badgeClass = 'upcoming-badge-today';
  } else {
    badgeText = '시행 완료';
    badgeClass = 'upcoming-badge-done';
  }

  return (
    '<tr>' +
      '<td class="upcoming-td-title">' + esc(item.title || '') + '</td>' +
      '<td class="upcoming-td-desc">' + esc(item.desc || '') + '</td>' +
      '<td class="upcoming-td-date">' + esc(dateLabel) + '</td>' +
      '<td style="text-align:center">' +
        '<span class="upcoming-badge ' + badgeClass + '">' + esc(badgeText) + '</span>' +
      '</td>' +
    '</tr>'
  );
}
