---
description: 이미지 썸네일 사본 — 유료 변환 금지·폭은 폴더마다·같은 목록 세 곳·파기 때 썸네일도(묶음 규칙)
paths:
  - "dev/js/ui.js"
  - "dev/lib/storage.js"
  - "dev/lib/shared.js"
  - "dev/js/admin.js"
  - "dev/js/admin-core.js"
  - "dev/js/application.js"
  - "dev/js/mypage.js"
  - "dev/js/messaging.js"
  - "dev/js/admin-outbound.js"
  - "dev/js/admin-deliverables.js"
  - "dev/js/admin-applications.js"
  - "dev/js/admin-settlements.js"
  - "dev/js/admin-brand-ops.js"
  - "dev/lib/image-compress.js"
  - "scripts/backfill-storage-thumbs.js"
  - "supabase/functions/purge-withdrawal-media/**"
  - "supabase/migrations/474_*"
---

# 이미지 썸네일 (CLAUDE.md Rules 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **이미지 썸네일 — 유료 변환을 쓰지 않는다**: `storageThumbUrl(url)`(ui.js) 로 **올릴 때 저장한 사본**(`{폴더}/thumb/{본체와 같은 파일 이름}`)을 가리킨다. 저장은 `uploadImage`·`uploadContentImage`·`uploadOutboundImage` 가 `_uploadThumbCopy` 로 하고 **데이터베이스 칸 없이 주소 규칙으로 찾는다**. `data-orig` + `onerror` 원본 폴백은 **여전히 필수**(썸네일 없는 옛 파일).
  - ⚠️ **설명 이미지 썸네일은 화면에 그릴 때만**(E-2) — `richHtml`·`miniRichHtml`·`renderCautionItemsHtml`·`renderNgItemsHtml` 이 `displayWidth` 를 줘서 `content/thumb/` 를 받고, **저장 경로는 인자 없이 불러 원본 주소가 저장된다.** 조건은 `typeof storageThumbUrl`(E-5)
  - 🔴 **`imgThumb`(유료 변환 `/render/image/`)은 아무도 안 부른다. 되살리지 말 것** — 포함량을 크게 넘겨 요금이 나갔다(캐시 `cacheControl:'86400'` 로도 못 막음). **죽은 코드인 줄 알고 지우지도 말 것**(되돌릴 여지)
  - **폭은 폴더마다 다르다** — `campaigns`·`content` **720** / `receipts`·`review-images`·아웃바운드 **480**. 🔴 720 은 캠페인 상세 첫 장 요구값(`application.js`), 480 은 영수증이 작게 뜨고 확대는 원본을 열며 **개인정보라 작을수록 낫기** 때문
  - ⚠️ **같은 목록이 세 곳 — 항상 같은 집합으로**: 화면 `THUMB_FOLDERS`(ui.js) · 저장 `THUMB_WIDTH_BY_PREFIX`(storage.js) · 소급 `FOLDERS`(`scripts/backfill-storage-thumbs.js`). **경로 규칙**(「{첫 칸}/thumb/{나머지}」)은 storage.js `_thumbPathOf`(E-4) + ui.js `storageThumbUrl` + Edge Function `purge-withdrawal-media` 의 `withThumbs` — 바꾸면 셋을 함께. 아웃바운드 폭은 `THUMB_WIDTH_OUTBOUND`. 어긋나면 **없는 썸네일을 요청**하거나 **안 쓰는 파일**이 쌓인다
  - ⚠️ **통마다 판정이 다르다** — `campaign-images` 는 첫 칸(용도 폴더)을 목록으로 거르고, `outbound-influencer-images` 는 첫 칸이 **회원 고유번호**라 **통 전체**(`THUMB_ALL_BUCKETS`)
  - 🔴 **원본은 절대 압축하지 않는다** — 「영수증에서 읽기」가 저장 파일 글자를 읽는데, 큰 영수증을 압축하자 주문번호 `1209389647` 이 **`120938964`** 로 빠졌다. 그래서 썸네일만 따로 둔다
  - 🔴 **개인정보 사본이라 파기하는 자리가 썸네일도 함께 지워야 한다** — 화면 4곳(`softDeleteCampaign`·`purgeAuditDataAll`·`purgeAuditDataForCampaign`·고아 정리 `deleteCampImages`[E-3])은 공용 `_withThumbPaths(paths)` 를, 예약 실행은 `purge-withdrawal-media` 안 `withThumbs` 를 거친다. **하나라도 빠지면 「지웠다」면서 남는다**(공개 통). 아웃바운드는 `deleteOutboundImage` 가 함께 지운다
  - ⚠️ **`remove()` 는 없는 파일에도 성공으로 답한다** — **응답만으로는 지워졌는지 모른다**
  - 🔴 **`campaign-images` 조회 정책은 「관리자 또는 본인이 올린 파일(`owner_id`)」**(474) — 회원 썸네일 저장이 `upsert: true` 라 **owner 조건을 빼면 회원 썸네일이 조용히 멈출 수 있다**. 아웃바운드 통 조회는 `outbound.view` 읽기 권한자만. 두 통 모두 공개 링크는 무관
  - ⚠️ **썸네일 실패는 삼킨다** — `onerror` 로 본체를 그린다. `keepIfSmall` 로 좁은 사진은 다시 굽지 않는다(**투명한 PNG 배경이 검게** 되는 함정)
  - 🔴 **기존 파일에 썸네일을 먼저 만든 뒤 표시를 바꾼다** — 뒤집으면 폴백이 **원본을 받아 더 나빠진다**. 도구 `scripts/backfill-storage-thumbs.js`(관리자 콘솔, 재실행 안전) — **개발·운영 각각**
  - 사양서 `docs/specs/2026-08-31-image-thumbnail-two-copies.md`
