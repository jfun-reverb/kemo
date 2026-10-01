---
description: 채널 코드 이관·채널 변경 가드·채널 코드 어긋남 감지 장치(묶음 규칙)
paths:
  - "dev/js/admin.js"
  - "dev/js/admin-core.js"
  - "dev/js/admin-orient.js"
  - "dev/js/admin-lookups.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/application.js"
  - "dev/admin/app.js"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "supabase/migrations/*channel*"
  - "supabase/migrations/*drift*"
  - "supabase/migrations/*settle*"
  - "supabase/migrations/*pending_review*"
  - "supabase/patches/*channel*"
---

# 채널 코드 이관·감지 (CLAUDE.md Rules 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **채널 코드 이관은 3곳 동시가 한 세트**: 채널 `code`(`lookup_values`)를 바꾸거나 지울 때 **①기준 데이터 ②캠페인(`campaigns.channel`) ③결과물(`deliverables.post_channel`)** 을 **함께** 옮긴다. 아니면 채널 비교가 **인플루언서 활동관리 · 관리자 인증 상태(`computeCertStatus`) · 정산 후보(`_settlement_cert_candidates()`)** 3곳에서 함께 깨진다(@cosme 때 인증샷 55건 소실 — 패치 `supabase/patches/2026-07-30-fix-cosme-review-image-channel-code.sql`, 보고서 `docs/specs/2026-07-30-cosme-channel-affected-report.md`). 🔴 **기존 관리자 도구로 못 고친다** — 162 의 채널 지정·해제·삭제 3함수는 거부하고, 구제 장치(`hasLegacyReviewImage`)는 **빈 값일 때만** 작동해 **「값이 틀린」 경우가 사각지대**다. ⚠️ 교정 시 `status` 를 건드리면 알림이 몰리고, 옛·새 코드 **공존 행**은 중복 금지 제약(`deliverables_review_image_app_channel_uniq`)에 걸린다 — 미리 배제할 것. **공존 26건은 「그대로 유지」**(보고서 §4 「26건 유지 결정 근거」).
  - **재발 방지 — 캠페인 채널 변경 가드**: ①편집에서 **결과물이 제출된 채널을 빼면 확인창**(영향 건수 표시, 막지 않고 묻는다). 건수 `countDeliverablesByChannels` ②**모집 형식 라디오를 눌러도 저장된 채널이 증발하지 않는다** — `renderChannelCheckboxes` 의 보존 기준은 화면 체크값이 아니라 **`opts.savedCodes`(저장된 값)**. ⚠️ **비활성 처리도 같은 위험** — `fetchLookups` 가 `active=true` 만 반환한다. ⚠️ 확인창은 `_editCampOriginal.channel` **스냅샷에 의존**하므로 그 키가 비면 죽은 코드(브라우저 1회 발동 확인 필수)
  - **감지 장치**(마이그레이션 277·278·319, `detect_channel_code_drift()`): 조회 전용·`is_admin()` 가드. 3층 = **A**(결과물 채널이 요구 채널에 없음 — 실제 피해) · **B**(캠페인 채널이 기준 데이터에 없음 — 조기 경보) · **C**(결과물 채널이 기준 데이터에 없음, `other` 등). ★ **제외 규칙 = 「같은 응모·같은 종류에 캠페인 채널과 정확히 일치하는 행이 있으면 뺀다」(상태 불문)** — 공존 26건이 자동 통과. ⚠️ **`covered` 는 A층·C층 양쪽에 적용**(옛 코드는 C에도 걸린다). ⚠️ **승인 상태를 요구하지 않는다**: 판정 세 곳(`_finalizeMonitorReprs`·`count_pending_review_applications`·`_settlement_cert_candidates()`)이 행 존재만 본다. ⚠️ **반려된 결과물은 경보하지 않는다**(278). 단 그 조건은 **`mismatched`·C층에만**, `deliv` 에는 넣지 않는다 — `covered` 는 **상태 불문**이어야 해서, 빼면 반려 행만 있는 경우 A층에 잘못 뜬다.
  - **화면 3단**: ①사이드바 경고 아이콘(결과물 관리·기준 데이터 — **부팅 시 1회 조회**) ②페인 제목 옆 경고 버튼 ③모달(종류별 조치 + 「캠페인 편집 열기」). `refreshChannelDriftIndicators` 계열(admin-core.js). ⚠️ **조치 안내는 결과물 종류로 분기** — 「검수 창의 채널 불일치 표시에서 지운다」는 **게시물 전용**이고 **리뷰 인증샷에는 없다**. 🔴 **0건이면 아무것도 안 그린다**(조회 실패 때도) — 늘 떠 있으면 무시하게 된다. ⚠️ **비교 규칙이 층마다 다르다**(319): A층은 **실제 판정과 글자 그대로**(캠페인 토큰=`btrim` 만 / 결과물 채널=원본) — `lower` 면 **대소문자만 다른 값을 통과**시킨다. **B·C층은 일부러 `lower` 유지**. `covered` 는 `(응모, 결과물 종류)` 로만 결합
  - 운영 경보는 0에서 시작(C층의 `other` 2건은 반려 → 278 로 제외)
  - **아직 안 한 재발 방지 1종**: 채널이 빈 캠페인에서 게시물 채널로 **「その他」를 고를 수 있는 구멍**(원천은 시딩·방문형 채널 0개 저장 허용. ⚠️순서 = 편집 필수화 → 정리 → 「その他」 제거. 먼저 지우면 고를 값이 0개)
