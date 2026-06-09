# 영수증 이미지 글자인식(OCR) 자동입력

**작성일:** 2026-06-10
**상태:** 개발 완료 (개발서버 배포 대상). 운영 배포는 사용자 확인 후.

## 배경·목적
인플루언서/관리자가 영수증의 3개 값(주문번호 `order_number`·구매일 `purchase_date`·구매금액 `purchase_amount`)을 손으로 타이핑하는 수고를 줄이도록, 이미지에서 자동으로 읽어 **입력칸에 미리 채워주는 보조 기능**.

## 방식 확정 (사용자 합의)
- **Tesseract.js (기기 안 처리, 외부 전송 0)**. 영수증 이미지는 어떤 서버로도 전송하지 않음. (모델·언어데이터 다운로드만 허용 — 개인정보 아님)
- PaddleOCR/클라우드/시각AI 등 외부 엔진은 사용자가 명시적으로 배제("외부는 절대 사용하지 않을 것").
- **한계 인정**: 모니터 화면을 카메라로 재촬영한 흐린 사진은 Tesseract로 못 읽음 → 빈칸 직접입력 폴백 + "스크린샷으로 올려달라" 안내. (PaddleOCR 같은 강한 엔진은 읽지만 외부 전송이 따라와 채택 안 함.)

## 사용자 결정 (2026-06-10 AskUserQuestion)
| 항목 | 결정 |
|---|---|
| 실행 방식 | **버튼 눌러 실행** (이미지 업로드 직후 자동 아님 — 무거운 로딩을 원할 때만) |
| 덮어쓰기 | **빈 칸만 채우기** (사용자가 직접 입력한 값 보존) |
| 인식 언어 | **일본어+영어** (`jpn+eng`) |
| 적용 범위 | **인플루언서·관리자 둘 다 한 번에** |
| 이미지 압축·HEIC | 이번 범위에서 **분리** (글자인식만 먼저) |

## 설계
- **DB 변경 없음** — 결과를 기존 입력칸에 채우기만 하고 제출은 기존 경로(`addDraftImage`→`deliverables` INSERT / `update_receipt_admin` RPC) 그대로. 새 컬럼·RPC·RLS·마이그레이션 없음.
- **OCR은 완전 선택적·비차단** — 라이브러리 로드/인식 실패가 제출을 절대 막지 않음(`typeof` 가드 + try/catch/finally).
- 추출 규칙은 PoC(`docs/poc/ocr-receipt-test.html`)에서 Qoo10 영수증 2건으로 검증된 정규식:
  - 줄별 공백 제거(compact) 후 매칭 (일본어 OCR이 글자 사이 공백을 끼움)
  - 구매일 `YYYY/MM/DD`·`YYYY年MM月DD日`
  - 주문번호 `注文番号/受注番号/オーダー番号/order` 키워드 뒤 영숫자 (`カート番号`=카트번호 제외)
  - 구매금액 `円`·`¥` 붙은 숫자만, 천단위 점·콤마 혼동 허용, `合計/総額` 줄 우선·없으면 최대값

## 구현 결과
**구현일:** 2026-06-10
**브랜치:** feature/receipt-ocr

### 변경 파일
- `dev/lib/ocr-receipt.js` (신규) — `_loadTesseract`(CDN lazy-load 1회 캐시), `preprocessReceiptImage`(임시 캔버스 2000px 리사이즈+그레이/대비, 업로드 이미지와 무관), `extractReceiptFields(text)`→`{order,date,amount}`, `runReceiptOcr(src,opts)`(src=File|Blob|url). `window` 전역 노출.
- `dev/index.html` — `#monitorReceiptFields` 안에 「画像から自動入力」 버튼(`#receiptOcrBtn`) + `#receiptOcrStatus` + 스크립트 태그.
- `dev/js/application.js` — 전역 `_receiptOcrFile`, `previewReceipt`에서 파일 보관, `runReceiptAutofill()`·`markOcrFilled()` 신규, 폼초기화·제출후 정리.
- `dev/js/admin-deliverables.js` — `renderReceiptInfoBlock` 수정모드에 `receipt_url` 있을 때 「영수증에서 읽기」 버튼 + `runReceiptOcrAdmin(id,url)` 신규.
- `dev/lib/i18n/{ja,ko}.js` — `activity.ocrBtn/ocrNoImage/ocrLoading/ocrRunning/ocrDone/ocrFailed` 6종(양 언어).
- `dev/build.sh` — CLIENT/ADMIN JS 목록에 `lib/ocr-receipt.js` 등록 + 관리자 빌드 script 제거 정규식에 `ocr-receipt` 추가.
- `dev/admin/index.html` — 스크립트 태그.
- `CLAUDE.md` — 활동관리·영수증 필수 필드 섹션에 OCR 한 줄씩.

### 초안 대비 변경
- 추가: 없음(전제·결정대로 구현).
- 빠진 것: 이미지 압축·HEIC(사용자 결정으로 분리).
- 마이그레이션: 없음(DB 무변경 확정).

### 검증
- reverb-reviewer GO (Warning 1건=CLAUDE.md 갱신 → 같은 커밋에 반영). qa 권장: light.
- PoC에서 Qoo10 2건 추출 정확 확인. 흐린 재촬영은 못 읽음→안내 폴백 동작 확인.

### 후속 백로그
- 비-Qoo10 영수증(라쿠텐·아마존재팬 등) 추출 규칙은 운영 실데이터로 추가 검증·보강.
- 영수증 업로드 압축/HEIC 정식 적용(`image-compress.js` 확산) — 별도 작업.
