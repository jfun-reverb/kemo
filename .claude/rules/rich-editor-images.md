---
description: 캠페인 리치 텍스트 편집기(Quill) 이미지 — 업로드·여러 장·축소·정화 세 곳 한 세트·빌드 목록(묶음 규칙)
paths:
  - "dev/js/admin.js"
  - "dev/js/admin-notices.js"
  - "dev/js/admin-lookups.js"
  - "dev/js/messaging.js"
  - "dev/js/admin-messaging.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "dev/lib/image-compress.js"
  - "dev/css/admin.css"
  - "dev/build.sh"
---

# 캠페인 리치 텍스트 편집기 이미지 (CLAUDE.md 캠페인 관리 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **콘텐츠 가이드 리치 텍스트** (Quill v2, 3개 필드 — 캠페인 설명·소구·가이드): Notion 복사·붙여넣기 서식 유지. XSS 방어 DOMPurify 저장+렌더 이중 sanitize. 헬퍼는 `dev/lib/shared.js`
  - **이미지 넣기**: 툴바 단추 + 붙여넣기. 미니 에디터와 **같은 함수**(`uploadContentImage` → `campaign-images/content/`, 5MB·jpg/png/webp), **같은 정책**(`_applyContentImagePolicy` — 우리 저장소 주소만). **가로 100% 고정**(Quill 이 `data-rich-size` 를 저장 때 버린다)
  - **여러 장 한 번에**: 최대 **20장**, **파일 이름 순**(`_richImagesInNameOrder` — `localeCompare` 의 `numeric:true` 필수, 없으면 `배너_1` 다음이 `배너_10`). **한 장씩 차례대로**(`_insertRichImages`), 자리는 처음 한 번 정하고 뒤로 민다. ⚠️ **붙여넣기도 같은 함수**, **이름순 정렬은 끈다**(전부 `image.png`). ⚠️ 형식·크기 위반은 **올리기 전에** 확인, 올리는 중 실패는 **되는 것만 넣고 파일 이름을 알린다**(올라간 파일은 지우면 안 된다 — 복제본이 가리킨다). ⚠️ **장수 검사를 확인 창보다 먼저**. ⚠️ `q.enable(false)` 는 **툴바 단추를 못 막는다** → `q.__richImgBusy` 로 두 번째 호출 차단(안 막으면 순서가 뒤섞인다)
  - **올릴 때 가로 폭만 줄인다**(`_shrinkRichImage` → `compressImageFile(file, {maxWidth:1600, keepIfSmall:true})`). ⚠️ **긴 변 기준이면 안 된다** — 세로로 긴 배너가 축소돼 글자가 뭉개진다. ⚠️ `keepIfSmall` 은 줄일 필요가 없으면 **원본을 그대로** 돌려준다 — 다시 그리면 JPEG 가 되어 **투명한 PNG 배경이 검게** 된다(메시지 첨부·영수증은 이 옵션 없음). 축소 실패는 **원본으로 올린다**
  - ⚠️ **`image-compress.js` 는 관리자 빌드에도 있어야 한다** — `storage.js` `uploadMessageAttachment` 가 불러, 없으면 관리자 메시지 이미지 첨부가 **반드시 실패**. ⚠️ `dev/build.sh` 는 목록(`ADMIN_JS_FILES`)과 **원본 `<script>` 태그를 지우는 정규식** 두 곳을 함께 — 정규식에 빠지면 죽은 태그가 남아 없는 경로를 부른다
  - ⚠️ **세 곳이 한 세트다** — ①`sanitizeRich` 이미지 허용 ②`getRichEditor` 의 `formats` 에 `image` ③`.quill-wrap .ql-editor img` CSS. ①만이면 넣는 순간, ②만이면 저장 때 사라지고, ③이 없으면 편집기 안에서 상자를 뚫는다
  - ⚠️ **외부 이미지는 못 가져온다**(교차 출처 차단). 캡처·파일 붙여넣기는 **자동 업로드**, 주소만 온 외부 이미지는 그 자리에서 지우고 안내한다(저장 때 조용히 사라지면 원인을 모른다)
  - ⚠️ **관리자 공지사항도 같은 `sanitizeRich` 를 쓰지만** 자기 편집기 `formats` 에 `image` 를 안 넣어 **동작이 그대로다**(캠페인 세 칸만 연다)
  - ⚠️ **저장소 파일은 본문에서 빼도 남는다.** `duplicateCampaign` 이 세 칸을 문자열째 복사해 **두 캠페인이 같은 파일을 가리키므로** 참조 세기 없이 지우면 복제본이 깨진다. 사양서 `docs/specs/2026-08-12-quill-image-upload.md`
  - **이어지는 이미지는 자동으로 붙는다**: `_markStackedImages` 가 **이미지만 든 블록이 연달아 있으면 앞 블록에** `rich-img-joined` 를 붙이고 CSS 가 여백·이음매 모서리를 없앤다(**글과 이미지 사이는 그대로**). ⚠️ 판정은 **허용 안 된 이미지를 지운 뒤** — 먼저 하면 낀 외부 이미지 때문에 「연속 아님」이 된다. ⚠️ 편집기 안은 CSS `:has(> img:only-child)` 로 **같은 기준**을 재현한다(어긋나면 편집기와 저장 결과가 갈린다)
