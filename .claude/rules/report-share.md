---
description: 캠페인 리포트·브랜드 공유 — 열 계산·공유 열 끄기·서버 응답 비우기·채널 계정 열(묶음 규칙)
paths:
  - "dev/js/admin-reports.js"
  - "dev/js/report-rows.js"
  - "dev/report.html"
  - "dev/js/admin-excel.js"
  - "dev/lib/storage.js"
  - "supabase/migrations/*report*"
---

# 캠페인 리포트·브랜드 공유 (CLAUDE.md 신청·결과물 관리 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **캠페인 리포트의 채널 열**(`/admin#reports` · 공유 화면 `report.html` — 마이그레이션 449, 사양서 `docs/specs/2026-09-17-report-sns-channel-columns.md`): 열은 **행에서 계산**(`reportColumnsFor(rows)`, `dev/js/report-rows.js` — 두 화면이 **같은 원본**). 17칸(큐텐·엣코스메 포함)은 늘, LIPS·인스타그램·틱톡·X·유튜브는 **쓰일 때만**, SNS 네 채널엔 계정 열. 정의처 `REPORT_CHANNELS`. 🔴 **계정 열 채널 추가 시 고칠 자리 넷**: ①`REPORT_CHANNELS` ②서버 함수의 코드 ↔ 회원 표 칸 짝 ③`_excelSnsUrl` 주소 줄 ④`fetchInfluencersForReport`(storage.js) 조회 칸. ⚠️ **①②만 고치면 계정이 안 오는데 오류도 없다**. 짝은 `get_report_share_data`(현재 원본 **491**, 414 → 449 → 457 → 469 → 491 — 🔴 **`CREATE OR REPLACE` 로만.** `DROP` 하면 413 이 비로그인에 준 권한이 풀려 공유 링크가 전부 죽는다)에도 있다. 계정 값은 **그 줄이 그 채널과 관계있을 때만**(아니면 큐텐 리뷰만 한 사람의 인스타 계정이 브랜드에게 간다) — 서버도 같은 조건, 끈 계정 열(`-ch_{코드}_acct`)은 응답에서 뺀다. ⚠️ **`share_columns` 는 옛·새 열쇠 뜻이 반대** — 옛 16개(`REPORT_SHARE_LEGACY_KEYS`, 🔴 더하지 않는다)는 「없으면 끈 것」, 새 열쇠는 「`-열쇠` 면 끈 것」. 판정: 「꺼져 있는가」(`reportShareColOff`, 고르기 창 + 공유 화면) / 「그릴 것인가」(`reportShareColDraw` = 안 꺼짐 + 값 있음, 공유 화면 + 브랜드 엑셀). 🔴 창 체크에 뒤쪽을 쓰면 값 없는 옛 열이 꺼진 채 굳는다. `reportShareColsToSave` 는 창에 없는 `-열쇠` 보존. ⚠️ 공유 화면은 **값이 전부 빈 열은 안 그린다**. 🔴 **끈 열의 값은 서버가 비운다**(469 — 주문번호·구매일·금액·영수증·채널 주소·「기타」·이름, 외부 첨부 같은 칸). 🔴 **반려·취소 신청과 탈퇴 확정 회원의 결과물은 공유 응답에 없다**(491 — 관리자 표엔 「검수 불필요」로 남아 **두 표의 줄 수가 다르다**. 판정 `_report_share_row_included` 한 곳을 결과물·회원·채널 집합 셋이 부른다). 게시물 주소는 `reportIsLinkable`(http(s)만) 일 때만 링크 — 두 화면 공용. 「업데이트」 시각 트리거 `touch_campaign_report_updated_at`(현재 원본 **491**)은 바뀐 칸이 `share_last_viewed_at` 뿐이면 `updated_at` 을 안 바꾼다. `_report_share_col_off`·`_report_share_chan_col` 은 **`reportShareColOff` 의 사본** — 두 벌 함께. 날짜·상태 칸은 안 비운다. 「기타 결과물」 = 채널이 비었거나 대장에 없는 코드(최신 1건 + 「외 N건」) — 🔴 **요구 채널을 다 채운 줄이면 비운다**. ⚠️ `_excelSnsUrl` 은 `report-rows.js` 에 있고 관리자 엑셀 약 28곳이 쓴다 — `admin-excel.js` 에 같은 이름을 만들면 **뒤의 것이 오류 없이 이긴다**. ⚠️ **주소 판정은 `_reportLooksLikeAddress`(빗금 앞에 점) 한 곳** — 점만 보면 `sy_beauty.com` 같은 **실제 아이디**가 주소로, 빗금만 보면 `myhandle/` 이 `https://myhandle/` 이 된다
