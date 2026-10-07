---
description: 결과물 제출(활동관리) — 미제출 방지·채널 단위 제출 버튼·제출 마감 판정(get_deliverable_gate)·주소 보정(묶음 규칙)
paths:
  - "dev/js/application.js"
  - "dev/js/app.js"
  - "dev/js/mypage.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "dev/lib/ocr-receipt.js"
  - "dev/js/messaging.js"
  - "dev/js/admin-deliverables.js"
  - "dev/index.html"
  - "supabase/migrations/*deliverable*"
  - "supabase/migrations/*admin_proxy*"
  - "supabase/migrations/275_*"
---

# 결과물 제출(활동관리) (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **활동관리**: 승인된 캠페인에서 결과물 제출. monitor=영수증(이미지 + 주문번호·구매일·구매금액 필수. 「画像から自動入力」(이미지에서 자동 입력)이 기기 안 글자인식(Tesseract.js jpn+eng)으로 **빈 칸만 채운다 — 외부 전송 0·최종 확인 필수**, 실패해도 제출 가능. `dev/lib/ocr-receipt.js`) / gifting·visit=SNS 게시물 주소(자동 채널 판별, 실패 시 드롭다운 — **캠페인 채널로 제한**, **불일치면 toast 차단**. `postChannelMatchesCampaign`(shared.js), 서버는 182). **주소 오타 자동 보정**(`normalizeUrlInput`, shared.js — `ttp://`·스킴 누락 → `https://`, 위험 스킴 차단. **대리 등록 공통**). `deliverables` 직접 INSERT + `submit_deliverable` RPC. 반려 사유는 빨간 배너, 재제출 시 pending(동일 URL 은 `post_submissions` 에 날짜 누적). `submission_end` 경과 시 폼 비활성
- **「올려두고 제출 안 함」 재발 방지**(데이터베이스 변경 없음 — 작업표 `docs/specs/2026-08-25-deliverable-draft-stall-breakdown.md`): **①리스트에 추가 ②제출하기** 중 ①만 하고 끝난 줄 아는 미제출이 쌓인다(세 종류 전부).
  - **관리자 안내 창**(`openStalledDraftModal`, admin-core.js — 결과물 관리 「인증 상태」 열 제목 옆 경고 단추): 건수 + **「해당 응모」 목록**(2026-10-06 사용자 지적으로 추가 — 응모 1건=1줄, 인플루언서·캠페인·올려둔 것·마지막 저장·「메시지」 단추). 조회 `fetchStalledDraftDetails`(storage.js, **실패 `null` → 「불러오지 못함」**). 🔴 **건수·목록은 「안내가 필요한 응모」만** — 승인된 응모 + 인증 상태 「미제출」·「인증샷 제출중」(= 목록 딱지 `certStatusBadge` 가 붙는 조건, 2026-10-06 사용자 결정). 반려·취소 응모와 이미 「인증성공」인데 쓰지 않은 임시저장만 남은 응모는 뺀다(운영에서 3건 중 2건이 그랬다). 판정 `fetchActionableStalledDrafts`(admin-core.js) — 인증 상태는 목록과 **같은 함수**(`buildDeliverableGroups`·`computeCertStatus`)로 센다. 딱지용 집합(`fetchStalledDraftApplications`)은 그대로다(딱지 자체가 두 상태에서만 붙으므로). ⚠️ **대리 등록 기간(기준일 + 1개월)이 지난 캠페인은 딱지·건수 둘 다에서 빠진다**(511 사양서 D-5 — storage.js 두 조회가 `isProxyWindowOpen` 으로 거른다. 임시저장 행은 안 지운다) 「메시지」는 안내 창을 **먼저 닫고** 메시지 창을 연다(안내 창 z-index 626)
  - **인플루언서가 보는 자리 네 곳** — 추가 직후 알림(`activity.draftAddedNeedSubmit`) · 활동관리 안내 줄(`renderDraftPendingBar`, 세 화면 공용) · 응모이력 「미제출」 배지(진한 주황+테두리) · 문의 게이트 한 줄(`faqComputeStatus` → `draft_pending`)
  - ⚠️ **안내 줄은 주황(행동 유도)이다. 빨강이 아니다** — 정상 흐름에서도 「추가」와 「제출」 사이는 미제출이라 빨강이면 「원래 빨간 화면」으로 학습된다. 같은 이유로 **0건이면 아무것도 안 그린다**
  - ⚠️ 응모이력 배지는 **테두리가 핵심** — 검수중(옅은 주황)과 눈으로 안 갈린다
  - **게시물 제출 버튼이 채널 단위로**(작업 3) — 종류 단위면 한 채널만 서버가 거부할 때 **버튼이 켜진 채 절반만 나간다.** `gateAllows` 를 채널마다 보고 **버튼과 안내 줄이 같은 수**를 센다. 부분 실패 시 **못 나간 채널을 이름으로**(`submitDrafts` 가 `failedChannels` 반환). ⚠️ `gateAllows` 는 행이 **0건이면 `true`** — 채널 빈 캠페인·조회 실패에서는 **버튼이 뜬다**(막지 않는 방향)
  - **미제출을 남긴 채 떠나면 확인**(작업 4) — `navigate()` 안. 🔴 **`return` 만으로는 부족하다** — 부르는 쪽이 다음 줄을 계속 실행한다(`navigateBackFromActivity` 가 `navigate('mypage')` 뒤 `openMypageSub` 를 불러 **화면은 활동관리, 주소는 응모이력**). `navigate` 뒤에 더 하는 자리가 **스무 곳 가까워** **두 겹**으로: ①막을 때 **`false` 반환**(뒤로 버튼·popstate 가 멈춤) ②`restoreActivityHash()` 가 **다음 차례에** 주소를 되돌린다(⚠️ **화면이 실제로 활동관리일 때만**, `pushState` 아닌 `replaceState`)
  - **주소 형태 경고**(작업 10, `looksLikeBarePostUrl` in shared.js) — 경로 없는 주소(채널 첫 화면)면 경고만. 🔴 **막지 않는다**(채널 주소 모양이 바뀌어 단정하면 멀쩡한 제출이 막힌다). ⚠️ `normalizeUrlInput` 은 **안 건드렸다** — 인플·관리자 대리 등록 공용이라 두 화면이 같이 바뀐다. 판정은 옆 새 함수, **양쪽이 같은 함수를 부른다**
  - ⚠️ **아직 안 한 것** — 관리자 대신 제출 기록(작업 9)·일일 메일 안내(작업 11)는 범위 밖. 자주 묻는 질문 노드(작업 12)는 **작업 2·5 운영 배포 뒤**에만(화면에 없는 안내를 찾게 만들지 않게)
- **결과물 제출 마감 차단(274)·동시 저장 방어(275)·화면 판정 서버 일원화(276)**: `get_deliverable_gate(신청id)` 가 항목별(영수증 / 채널별 게시물 / 채널별 인증샷) 제출 가부를 주고 **화면은 소비만**(`gateAllows`/`gateAllowsAny`). 게시물 반려 예외는 **채널 단위**. ⚠️ **조회 실패(`null`)와 「0건」(`[]`)을 반드시 구분** — 못 물어보면 폼·안내문 **둘 다 안 막는다**(최종 방어선은 트리거). ⚠️ 방문형은 **현장 사진(`receipt`)도 포함**(인증 성공 판정과는 다른 축). 사양서 `docs/specs/2026-07-29-deadline-server-enforcement.md`
