// ══════════════════════════════════════════════════════════════
// 리포트 관리 (캠페인 리포트 만들기) — 1-A 단계 뼈대
//   사양서 : docs/specs/2026-09-03-campaign-report-builder.md
//   작업표 : docs/specs/2026-09-03-campaign-report-builder-breakdown.md
//
// 이 조각(작업 4)은 **화면이 열리기까지의 등록만** 한다. 목록·표·모달은 뒤 조각.
//
// ⚠️ `loadReportsPane` 이름을 바꾸지 말 것 — 두 곳이 **이름으로** 참조한다:
//     ①`dev/js/admin-core.js` 의 `switchAdminPane` 안 `loaders`
//     ②`dev/lib/shared.js` 의 `PANE_REFRESHERS['reports']`
//    ①을 빠뜨리면 사이드바를 눌러도 **오류 없이 빈 화면**이 되고,
//    ②를 빠뜨리면 저장 뒤 목록이 안 갱신된다(`refreshPane` 이 조용히 끝난다).
//
// ⚠️ 이 파일은 빌드에서 `admin-core.js` **뒤**, `admin.js` **앞**에 이어 붙는다
//    (`dev/build.sh` 의 `ADMIN_JS_FILES`). 빌드는 단순 이어붙이기라 전역이 하나다.
//
// ⚠️ `dev/admin/index.html` 에 이 파일의 `<script>` 태그를 넣지 않는다 —
//    원본 HTML 은 페인 파일을 개별 태그로 부르지 않는다(빌드 목록에만 있다).
//    넣으면 빌드가 지우는 정규식에 안 걸려 **없는 경로를 부르는 죽은 태그**가 남는다.
//    (작업표는 「정규식이 자동으로 걸러 준다」고 적었으나 실제로는 안 걸린다 —
//     2026-09-03 실측: `admin-reports.js`·`admin-deliverables.js` 둘 다 안 걸림)
// ══════════════════════════════════════════════════════════════

async function loadReportsPane() {
  const pane = document.getElementById('adminPane-reports');
  if (!pane) return;

  // 권한 — 서버(행 단위 보안 정책·함수 가드)가 최종 방어선이고 여기는 표시 제어다.
  //   ⚠️ 화면 판정은 fail-open(못 읽으면 쓰기)이라 이것만으로 막혔다고 보면 안 된다.
  if (typeof isHidden === 'function' && isHidden('menu.reports')) {
    pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted);font-size:13px">이 화면에 접근할 권한이 없습니다.</div>';
    return;
  }

  pane.innerHTML = `
    <div class="admin-pane-head">
      <h2 class="admin-pane-title">리포트 관리</h2>
    </div>
    <div style="padding:40px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">
      캠페인을 골라 리포트를 만드는 화면입니다.<br>
      <span style="font-size:12px">아직 준비 중입니다 — 만들기·목록·표는 다음 단계에서 붙습니다.</span>
    </div>`;
}
