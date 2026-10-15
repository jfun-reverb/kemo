---
description: 일별 방문자수 — 표·기록 함수·대시보드 차트(일본 표준시 날짜·실패와 0건 구분)
paths:
  - "dev/js/admin-dashboard.js"
  - "supabase/migrations/*site_daily_visits*"
---

# 일별 방문자수 (CLAUDE.md 에서 옮겨 옴 — 2026-10-15)

#### 일별 방문자수 (마이그레이션 332)
> 화면 = 관리자 대시보드 「일별 방문자수」 카드(회원가입 추이와 2열), 기간 7일/30일/전체. ⚠️ 세는 기준 문구는 **차트 아래 정적 줄**이다 — 헤더에 넣으면 옆 카드와 높이가 어긋나고 조회 실패 시에도 남아야 해서 `visitChartNote`(동적)와 분리.
- `site_daily_visits` — `(visit_date, app)` 유일. `visitor_count`(브라우저 단위 하루 1회) + `page_view_count`(보조, 화면 미사용). **개인 식별 값 없음**. 조회 `is_admin()`, **쓰기 정책 없음**(함수만 — `client_error_logs` 와 같은 형태)
- `record_site_visit(p_app, p_is_new_visitor)` — anon·authenticated 호출. 263(`increment_campaign_view`)을 본떠 관리자·감사용 계정을 서버가 제외. ⚠️ **날짜는 서버가 만든다**(과거 날짜 부풀리기 방지). 앱 구분이 화이트리스트 밖이면 **조용히 종료**
- ⚠️ **저장소를 못 쓰면 세지 않는다 — 조회수(263)와 정반대이고 의도한 것이다.** 하루 한 행이라 한 사람의 새로고침이 그대로 그날 수가 된다. 「일관성 없다」며 맞추지 말 것 (`_markSiteVisited`·`recordSiteVisit`)
- ⚠️ 호출은 **부팅 1회**, **세션 복원 뒤**(`dev/js/app.js` `init()` 의 `updateGnb()` 직후) — 아니면 **운영자 접속이 방문자로 세어진다**
- ⚠️ **관리자·감사용 제외는 SQL 편집기로 검증 못 한다**(서비스 키라 그 분기가 안 돈다 — 마이그레이션 272 와 같은 함정). 로그인 브라우저로만 확인
- 봇 방어는 `navigator.webdriver` + 미리 불러오기 제외뿐 — **헤드리스 봇은 못 거른다.** 「참고 지표」임을 밝힐 것
- 도입 이전 구간은 **백필 없음** — 0으로 그리지 말 것(「방문자 0명」으로 오독)
- **화면**(`dev/js/admin-dashboard.js` `_computeVisitSeries`/`renderVisitChart`/`loadVisitChart`/`switchVisitPeriod`, 조회 `fetchSiteDailyVisits`): ⚠️ **날짜 기준이 옆 회원가입 차트와 다르다** — 가입 차트는 `toISOString()`(세계시), 방문 집계는 **일본 표준시** 날짜라 세계시로 자르면 어제 숫자가 오늘 칸에 간다(`_visitDateTodayKst`·`_visitDateShift` — 문자열 연산이라 시간대 무관)
- ⚠️ **조회 실패(`null`)와 기록 0건(`[]`)을 구분**해 다른 안내를 띄운다 — 어느 쪽도 0을 그리지 않는다(마이그레이션 276 원칙). ⚠️ **도입 이전은 자르되 도입 이후의 빈 날은 0이 맞다**
- ⚠️ 차트 오른쪽 끝은 **`max(오늘, 마지막 기록일)`** — 자정 직후 PC 시계가 조금만 느려도 **그릴 칸이 0개가 된다**
- 열람 권한은 **관리자 전원**(`is_admin()`)
