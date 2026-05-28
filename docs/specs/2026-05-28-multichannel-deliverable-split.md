# 리뷰어 캠페인 결과물 모델 확장 — 영수증 + 채널별 리뷰 이미지

**작성일:** 2026-05-28 (초안) / **재작성:** 2026-05-28 (이미지 모델·Qoo10 패턴 통일·엑셀 채널별 컬럼 반영)
**작성 세션:** 기획/설계
**배경:** 리뷰어(monitor) 캠페인은 현재 영수증만 받음. Qoo10·@cosme·LIPS 같은 일본 마켓·리뷰 플랫폼 채널에서 인플이 리뷰를 등록하면 그 **리뷰 페이지의 스크린샷 이미지**를 결과물로 제출하는 모델이 필요. 「Qoo10 & @cosme」처럼 여러 채널에 모두 리뷰 등록을 요구하는 캠페인도 채널별로 분리 제출·검수·엑셀 컬럼 분리.

본 사양은 메모리 `project_monitor_deliverables_v2`(리뷰어 결과물 2단계화 — 영수증 + 리뷰 캡쳐)의 정식 구현 사양이기도 함. 「리뷰 캡쳐」를 「채널별 리뷰 이미지」로 구체화.

---

## 0. 정정 이력 (2026-05-28)

- 초안 v1: gifting/visit + `channel_match='and'` 한정 + 게시물 URL 다중 입력 — **폐기**
- 초안 v2: 리뷰어 캠페인 + 채널별 리뷰 URL — 사용자 정정으로 폐기 ("URL이 아니라 이미지")
- 본 v3: 리뷰어 캠페인 + **채널별 리뷰 이미지(스크린샷)** + 엑셀 채널별 컬럼 분리

### v3 작성 시점의 현황 인식 정정 (개발 세션 발견, 2026-05-28)

사양 §2 「현재 monitor = 영수증만」 가정은 **현 코드와 불일치**. 실제로는 이미 마이그레이션 093에서 **영수증(STEP 1) + 단일 리뷰 이미지(STEP 2) 2단계가 구현 완료** 상태. `deliverables.kind='review_image'` enum 활성, `dev/js/application.js`의 `renderActivityReviewImageList` 함수 + `dev/index.html`의 `#reviewImageList`/`#reviewImageForm`이 가동 중이며, 영수증 1건 이상 승인 후 STEP 2 해금 게이트도 이미 동작 중.

**즉 본 사양은 "신규 도입"이 아니라 "현행 단일 리뷰 카드(채널 무관 1장) → 캠페인 채널 수만큼 N장 카드(채널별 분리)로 확장"이다.**

기존 데이터: `kind='review_image'` 행은 `post_channel=NULL`로 저장돼 있음 → 본 사양 적용 후에도 NULL 행 그대로(레거시), 신규 신청부터 채널별 채움. UNIQUE 부분 인덱스(§3-2)는 `WHERE post_channel IS NOT NULL`이라 NULL 행 영향 없음.

### v3 사용자 결정 추가 (2026-05-28)
- 영수증 → STEP 2 게이트 **유지** (현행 패턴 그대로)
- 채널 없는 리뷰어 캠페인: **신규 등록 시 채널 1개+ 강제** (관리자 폼 검증), 기존은 grandfather (영수증만)
- 다중 캠페인 엑셀: **합집합 분리** (선택한 캠페인들의 모든 채널 컬럼으로 펼침)
- 검수 모달 「다른 채널 상태 안내 박스」: **모달 하단 회색 박스**
- 알림 일본어: **「「{채널}」のレビュー画像が承認されました」** (따옴표 강조, 정식 レビュー 표기)
- 운영 배포 묶음: 묶음 2번 — PR1+PR2 한 묶음 / PR3+PR4 한 묶음

### v3 작성 시점의 현황 인식 정정 (개발 세션 발견, 2026-05-28)

사양 §2 「현재 monitor = 영수증만」 가정은 **현 코드와 불일치**. 실제로는 이미 마이그레이션 093(2026년 작업)에서 **영수증(STEP 1) + 단일 리뷰 이미지(STEP 2) 2단계가 구현 완료** 상태. `deliverables.kind='review_image'` enum 활성, `dev/js/application.js`의 `renderActivityReviewImageList` 함수 + `dev/index.html`의 `#reviewImageList`/`#reviewImageForm`이 가동 중이며, 영수증 1건 이상 승인 후 STEP 2가 해금되는 게이트(`reviewImageGatedNote`/`reviewImageBody` 토글)도 이미 동작 중.

**즉 본 사양은 "신규 도입"이 아니라 "현행 단일 리뷰 카드(채널 무관 1장) → 캠페인 채널 수만큼 N장 카드(채널별 분리)로 확장"이다.**

기존 데이터: `kind='review_image'` 행은 `post_channel=NULL`로 저장돼 있음 → 본 사양 적용 후에도 NULL 행은 그대로(레거시), 신규 신청부터 채널별로 채움. UNIQUE 부분 인덱스(§3-2)는 `WHERE post_channel IS NOT NULL`이라 NULL 행에 영향 없음.

### v3 사용자 결정 추가 (2026-05-28)
- 영수증 → STEP 2 게이트 **유지** (현행 패턴 그대로)
- 채널 없는 리뷰어 캠페인: **신규 등록 시 채널 1개+ 강제** (관리자 폼 검증), 기존은 grandfather (영수증만)
- 다중 캠페인 엑셀: **합집합 분리** (선택한 캠페인들의 모든 채널을 컬럼으로 펼침)
- 검수 모달 「다른 채널 상태 안내 박스」: **모달 하단 회색 박스**
- 알림 일본어: **「「{채널}」のレビュー画像が承認されました」** (따옴표 강조, 정식 レビュー 표기)
- 운영 배포 묶음: 묶음 2번 — PR1+PR2 한 묶음 / PR3+PR4 한 묶음

---

## 1. 확정 사항 (사용자 결정 2026-05-28)

| 항목 | 결정 |
|---|---|
| 적용 모집 유형 | **리뷰어(monitor) 전용** (기프팅·방문형 영향 없음) |
| 구매처 | **항상 Qoo10** — 별도 구매처 지정 필드 없음 |
| 채널 의미 | **「리뷰가 등록될 채널」 목록** (구매처 아님) |
| 결과물 구성 | **영수증 이미지 1장(현재 유지) + 캠페인 채널 수만큼 리뷰 이미지** |
| 인플 입력 | **이미지 업로드만** (URL 직접 입력 없음) |
| 「리뷰 링크」 의미 | 이미지의 Storage 자동 URL — 엑셀·관리자 모달에서 표시용 (영수증 패턴 동일) |
| 제출·검수 단위 | **채널별 분리** — 채널 A 이미지부터 검수 가능, B는 나중 |
| 엑셀 컬럼 | 캠페인 채널 수만큼 **「{채널} 리뷰 이미지 + {채널} 리뷰 URL」 쌍** 동적 추가 |
| 인플 마이페이지 SNS 폼 | **수정 없음** (LIPS·@cosme 계정 받지 않음) |
| 선행 의존 | LIPS·@cosme 채널 추가(`docs/specs/2026-05-27-lips-cosme-channels.md`) 운영 적용 완료 후 착수 |

## 2. 현재 동작과의 차이

| 영역 | 현재 monitor | 본 사양 후 |
|---|---|---|
| 결과물 종류 | 영수증만 | 영수증 + 채널별 리뷰 이미지 N장 |
| 게시물·리뷰 입력 UI | 없음 | 채널별 이미지 업로드 카드 N개 |
| `deliverables.kind` 사용 | `'receipt'`만 | `'receipt'` + `'review_image'` (이미 enum에 존재, 신규 활용) |
| 검수 단위 | 영수증 1행 | 영수증 1행 + 리뷰 이미지 N행 (각 독립) |
| 엑셀 결과물 컬럼 | 결과물 6컬럼 (타입·제출일·검수일·상태·이미지·URL) | 영수증 + 채널별 「{채널} 리뷰 이미지·URL」 쌍 추가 |
| `channel_match='and'/'or'` | 영향 없음(게시 없음) | `and`=모든 채널 강제, `or`=일부 채널만 등록 허용 |

기프팅(gifting)·방문형(visit) 캠페인은 본 사양 영향 **없음** — 현행 게시물 1건(post URL+자동 채널 판별) 모델 그대로.

## 3. 데이터 모델

### 3-1. 기존 구조 활용
`deliverables` 테이블 그대로. 컬럼 추가 없음.
- `kind='receipt'` 1행 (Qoo10 영수증 + 주문번호·구매일·구매금액) — **현재 그대로**
- `kind='review_image'` 채널별 1행 (캠페인 채널 수만큼 신규 INSERT)
  - `post_channel` — 어느 채널 리뷰인지 (`'qoo10'`/`'cosme'`/`'lips'`/...)
  - `receipt_url` — **이미지 Storage URL** (컬럼명은 영수증용이지만 의미 확장: kind에 따라 영수증 이미지 또는 리뷰 이미지)
  - `status` / `reject_reason` / `reviewed_by` / `reviewed_at` / `version` — 행별 독립
- 영수증 보조 컬럼(`order_number`·`purchase_date`·`purchase_amount`)은 `kind='review_image'` 행에서 NULL

### 3-2. 마이그레이션 (번호는 작업 시점 `ls supabase/migrations/` 재확인)

```sql
-- 같은 신청 + 같은 채널 + review_image kind 는 1행만
CREATE UNIQUE INDEX IF NOT EXISTS deliverables_review_image_app_channel_uniq
  ON public.deliverables (application_id, post_channel)
  WHERE kind = 'review_image' AND post_channel IS NOT NULL;
```
- 재제출은 기존 행 UPDATE(`receipt_url` 교체)로 처리. UNIQUE 충돌 없음
- 신규 컬럼·테이블·보안 정책 변경 없음

### 3-3. 컬럼명 정비 (선택)
`receipt_url`이 「영수증 또는 리뷰 이미지 URL」을 담는 의미 확장 → 코드 주석 + `dev/lib/storage.js` 헬퍼 변수명만 정리(예: `imageUrl`). 컬럼 이름 변경은 영향 범위 크니 본 사양에서는 보류.

### 3-4. 기존 데이터
기존 monitor 캠페인 결과물은 영수증 1행만 있음 → 본 사양 머지 후에도 그대로. 새 신청부터 자연스럽게 채널별 리뷰 이미지 행 누적.

## 4. 인플루언서 활동관리 폼 (`dev/js/application.js`)

monitor 캠페인 결과물 화면 구성:

```
┌─ 영수증 (Qoo10) ───────────┐  ← 현행 그대로
│ 이미지 업로드               │
│ 주문번호 [____]            │
│ 구매일 [____]              │
│ 구매금액 [____]            │
│ 상태: 검수중                │
└────────────────────────────┘

┌─ Qoo10 리뷰 ───────────────┐  ← 캠페인 채널 첫번째 (신규)
│ 이미지 업로드               │
│ 상태: 미제출                │
└────────────────────────────┘

┌─ @cosme 리뷰 ──────────────┐  ← 캠페인 채널 두번째 (신규)
│ 이미지 업로드               │
│ 상태: 검수중                │
│ (반려 시: 사유 + 재업로드)   │
└────────────────────────────┘
```

- **영수증 카드 1개**(현재 그대로) + **채널별 리뷰 카드 N개**(캠페인 채널 수만큼) 세로 배치
- 카드 순서: 영수증 → 캠페인 `channel`(콤마 등록 순서)대로 리뷰 카드
- 입력은 **이미지 1장 업로드만** — URL 입력란·자동 판별 없음
- 카드 상태: 미제출 / 검사중 / 승인 / 반려
- **부분 제출 허용**: 영수증만, 또는 영수증 + 리뷰 1개만 등 자유 시점
- 반려 시 사유 박스 + 재업로드 (현행 영수증 반려 패턴 그대로)
- 채널 1개 monitor 캠페인(예: 채널=`'qoo10'`만)도 같은 UI — 영수증 + Qoo10 리뷰 카드 1개
- 채널 미지정 monitor 캠페인은 영수증만(현행 유지) — 회귀 없음

이미지 압축·HEIC 변환은 기존 `dev/lib/image-compress.js` 재사용.

## 5. 관리자 검수 (`dev/js/admin-deliverables.js`)

### 5-1. 결과물 관리 목록
- 같은 신청의 영수증 행 + 리뷰 이미지 행(채널별)을 **모두 별개 행**으로 노출
- 결과물 컬럼에 종류 라벨: 「영수증」·「리뷰 · Qoo10」·「리뷰 · @cosme」
- 필터 「채널」 드롭다운에서 채널 선택 시 그 채널 리뷰 행만 표시

### 5-2. 검수 모달
- 행 단위 현 모달 재사용 — 이미지 미리보기 + 승인/반려 (현 영수증 검수 패턴과 동일)
- 같은 신청의 다른 행 상태를 모달 하단 안내 박스로 표시:
  - 「영수증 ✓ / Qoo10 리뷰 검사중 / @cosme 리뷰 미제출」

### 5-3. 캠페인 진행 현황 (`#camp-applicants`)
신청자 행의 「결과물 상태 요약」 컬럼을 채널별 칩으로 분리:
- 「영수증 ✓ · Qoo10 ✓ · @cosme 검」

## 6. 엑셀 다운로드 (`dev/js/admin-excel.js`) — 채널별 컬럼 분리

### 6-1. 현행 컬럼 구조 (참고)
- 영수증: 9컬럼 — 타입 | 제출일 | 검수일 | 상태 | 주문번호 | 구매일 | 구매금액 | 이미지 | URL
- 결과물: 6컬럼 — 타입 | 제출일 | 검수일 | 상태 | 이미지 | URL (한 행 한 게시물)

### 6-2. 본 사양 후 변경
**단일 캠페인 결과물 엑셀** (`exportCampaignDeliverables`):
- 영수증 9컬럼 그대로
- **결과물 6컬럼 → 캠페인 채널 수만큼 6컬럼 쌍이 가로로 확장**:
  - 「Qoo10 리뷰 — 타입 | 제출일 | 검수일 | 상태 | 이미지 | URL」 6컬럼
  - 「@cosme 리뷰 — 타입 | 제출일 | 검수일 | 상태 | 이미지 | URL」 6컬럼
  - 채널 수만큼 반복
- 그룹 헤더(3행) 라벨: 「{채널 라벨} 리뷰」
- 신청자 한 행에 영수증 + 모든 채널 리뷰가 한 줄로 정리됨 (현행 한 행 한 신청 패턴 유지)

**다중 캠페인 결과물 엑셀** (`exportSelectedCampaignsDeliverables`):
선택한 캠페인들의 채널 구성이 다를 수 있으므로 결정 필요 — 권고:
- **선택 캠페인 전체에 등장한 채널의 합집합을 컬럼으로 펼침** (등장 안 한 채널은 그 캠페인 행에서 공란)
- 또는 단순화: 다중 캠페인은 현행 6컬럼 유지 + 채널은 「타입」 셀에 라벨로 노출 (예: 「리뷰 · Qoo10」)

→ 단일 캠페인은 (분리), 다중 캠페인은 (단순) — 사용자 검수 시 확인 권장

### 6-3. 이미지 임베드 로직 확장
현재 `imgBuffers[d.id]`로 영수증 이미지만 사전 다운로드 + 임베드 → `kind='review_image'` 행도 동일 처리(이미 코드에 `(d.kind === 'receipt' || d.kind === 'review_image')` 필터 존재 — 그대로 활용)

### 6-4. `_excel*` 헬퍼 보강
- 신규 `_excelReviewImageCells(d)` 헬퍼 — 채널별 6컬럼 셀 계산 (영수증 패턴 미러)
- 채널 라벨 매핑(`Qoo10`·`@cosme`·`LIPS`)은 i18n 또는 `CHANNEL_LABELS` 재사용

## 7. 캠페인 완료 판정

- 신청 1건 완료 = 영수증 `approved` + 캠페인 채널 모두 리뷰 이미지 `approved`
- 헬퍼 SQL 함수 신설 권장: `application_monitor_complete(application_id)` returns boolean
- 단일채널·기프팅·방문형은 기존 판정 로직 유지

## 8. 알림·메일

- `notifications` 행 단위 트리거 그대로 동작 → 채널별 개별 알림
- 알림·메일 본문에 종류·채널 라벨 포함:
  - 「영수증が承認されました」
  - 「「@cosme」リビューが承認されました」
- i18n 키 신설 + 메일 템플릿 `{{result_label}}` placeholder 추가

## 9. 약관·개인정보 영향

- 수집 항목 변경 없음 (이미지·DB 동일 패턴)
- 처리 흐름 변경 없음
- 외부 제공 변경 없음
- → 약관·개인정보처리방침 **개정 불필요**

## 10. 의존·선행

| 선행 | 사양서 | 이유 |
|---|---|---|
| LIPS·@cosme 채널 추가 | `docs/specs/2026-05-27-lips-cosme-channels.md` (2026-05-28 정정판) | @cosme·LIPS가 lookup_values 에 존재해야 캠페인 채널로 선택 가능 |
| monitor 결과물 2단계화 메모 | `memory/project_monitor_deliverables_v2.md` | **본 사양이 그 정식 구현 사양** — 메모리에 "통합 완료" 표시 후 종결 |

## 11. PR 분할

- **PR 1 — DB + 인플루언서 폼 (리뷰 카드 분리)**:
  - 마이그레이션 (UNIQUE 인덱스 1개)
  - `dev/js/application.js` 채널별 리뷰 카드 분리 + 이미지 업로드
  - `dev/lib/storage.js` `kind='review_image'` INSERT/UPDATE 경로
  - 게이트: 개발서버 동작 확인 + 기존 monitor(영수증만) 회귀 없음 + 기프팅·방문형 회귀 없음
- **PR 2 — 관리자 검수 + 진행 현황 칩 + 알림 라벨**:
  - 결과물 관리 목록 채널 칩 노출
  - 검수 모달 다른 행 상태 안내
  - 캠페인 진행 현황 칩 분리
  - 알림 메일 라벨 추가 (i18n + 메일 템플릿)
- **PR 3 — 엑셀 채널별 컬럼 분리**:
  - 단일 캠페인 결과물 엑셀 컬럼 채널 수만큼 확장
  - 다중 캠페인 엑셀 정책(합집합 분리 vs 단순 라벨) 사용자 확정
  - 신청자 엑셀에는 결과물 컬럼 없으므로 영향 X

## 12. 게이트·QA

- **에이전트 호출 의무**:
  - `reverb-planner` — PR 1 착수 직전 (DB·UI 양쪽 변경)
  - `reverb-supabase-expert` — 마이그레이션 작성 시
  - `reverb-reviewer` — 모든 commit 직전 (예외 없음)
  - `reverb-qa-tester` Full — 인플 결과물 제출 플로우 변경 → 운영 배포 전 필수
- **회귀 시나리오**:
  - 채널 미지정 monitor — 영수증만 (기존 그대로)
  - 채널 1개 monitor — 영수증 + 리뷰 카드 1개
  - 채널 N개 monitor (`and`/`or`) — 영수증 + 리뷰 카드 N개, 부분 제출 가능
  - 같은 채널 재제출 → 그 카드 이미지 교체, 다른 카드 영향 X
  - 반려된 채널 카드만 재제출 → 그 카드만 `pending` 복귀
  - 기프팅·방문형 캠페인 — 게시물 1건 모델 유지(회귀 없음)
  - 엑셀 다운로드 — 단일/다중 캠페인 모두 컬럼 정합

## 13. 운영 배포 직전 점검 SQL

```sql
-- monitor 캠페인의 채널 구성과 기존 결과물 분포
SELECT
  c.id, c.title, c.channel,
  COUNT(DISTINCT a.id) AS approved_apps,
  COUNT(d.id) FILTER (WHERE d.kind='receipt') AS receipt_rows,
  COUNT(d.id) FILTER (WHERE d.kind='review_image') AS review_image_rows
FROM campaigns c
JOIN applications a ON a.campaign_id = c.id AND a.status = 'approved'
LEFT JOIN deliverables d ON d.application_id = a.id
WHERE c.recruit_type = 'monitor'
GROUP BY c.id, c.title, c.channel;
```
- review_image_rows = 0 이 정상 (현재까지는 안 받음)
- 운영자에게 "기존 monitor 결과물은 영수증 그대로, 신규 신청부터 채널별 리뷰 이미지 카드 등장"으로 안내

## 14. 추후 확인 디테일 (개발 세션 진입 시점)

다음 디테일은 본 사양에서 권고로만 적고, 개발 착수 직전에 사용자에게 확인 권장:
- 다중 캠페인 엑셀 정책 (§6-2 합집합 분리 vs 단순 라벨)
- 검수 모달 「다른 채널 상태 안내 박스」 위치·디자인
- 알림 라벨 일본어 문안 (예: 「「@cosme」リビュー」 표기)
- 「리뷰 캡쳐」를 인플에게 어떻게 안내할지(UI 문구 — 비개발자 친화 쉬운 일본어)

---

## 구현 결과 — PR 1 (DB + 인플 폼 채널별 카드 분리)

**구현일:** 2026-05-28
**관련 커밋:** feature/multichannel-deliverable-pr1 (PR 머지 후 갱신)
**선행:** PR 1 (LIPS·@cosme 채널 추가, PR #321 dev 머지 완료)

### 초안 대비 변경 사항
- **§2 「현황 오기」 발견** — 사양은 "현재 monitor = 영수증만"을 가정했으나 실제로는 이미 영수증 + 단일 리뷰 이미지 2단계가 가동 중. 즉 본 PR은 "단일 리뷰 카드 → 캠페인 채널 수만큼 N장 카드"로의 확장(§0 정정 이력에 명시)
- **§4 인플 폼 구조** — `#reviewImageForm` 정적 단일 폼·`#reviewImageMaxNote`·`#addReviewImageBtn`·`#reviewImageFileLabel`을 제거하고, `#reviewImageList`를 카드 N개의 동적 컨테이너로 의미 전환. 각 카드 안에 채널 라벨 + 행 표시(또는 업로드 폼)
- **§6-1 채널 미지정 monitor 캠페인** — 사용자 결정 「채널 지정 강제」 적용. 신규 등록은 `dev/js/admin.js:2430`(이미 존재), 편집은 신규 검증 추가(`saveCampaignEdit`). 기존 0개 캠페인은 인플 화면에서 STEP 2 영역 자체 숨김(grandfather)
- **§4 1장 제약** — 「전체 1장」(현행) → 「채널당 1장」으로 의미 전환. UNIQUE 부분 인덱스(마이그레이션 158)와 정합

### 구현 중 기술 결정 사항
- **`_reviewImgData`(단일) → `_reviewImgDataByChannel = {}`(채널별 객체)** — 채널별 미리보기 격리. `previewReviewImage(input, channel)`/`addDraftReviewImage(channel)` 시그니처에 채널 추가
- **카드 내부 입력 요소 ID 규칙** `reviewImagePreview-{channel}` — 정적 단일 ID를 채널별로 격리. 파일 input은 ID 없이 채널은 onchange/onclick 인자로 전달
- **`applyFormGating`의 reviewImage 분기 제거** — 카드별 폼 disabled 처리는 `renderActivityReviewImageList` 내부에서 카드 단위로 (마감 후 + 채널별 반려 없음 = 카드 폼 비활성). 통합 제출 버튼은 draft 존재 여부로 자동 토글
- **레거시 `post_channel=NULL` 행 처리** — 카드 매핑 시 NULL 행은 무시(`latestByChannel` 그룹핑에서 `if (!d.post_channel) return;`). 기존 신청은 화면에서 안 보이지만 DB 보존
- **`insertDraftDeliverable` 시그니처 변경 없음** — payload에 `post_channel: channel` 추가만으로 충족 (기존 `payload.post_channel || null` 분기 활용)
- **재제출(반려 후 같은 채널 재업로드)** — UNIQUE 인덱스(`application_id, post_channel`)가 부분 인덱스라 같은 채널 재INSERT 시도 시 충돌. 향후 PR 3에서 채널별 UPDATE 경로 정비 권장(현재는 draft 생성 후 submitAllDrafts로 처리 가능)
- **마이그레이션 158 점유** — 다른 세션 동시 작성 없음 확인. PR 1(157) 직후 분기

### 변경 파일
- `supabase/migrations/158_review_image_channel_unique.sql` (신규, supabase-expert 작성)
- `dev/js/application.js` (`renderActivityReviewImageList`/`previewReviewImage`/`addDraftReviewImage`/`loadDeliverablesForActivity`/`applyFormGating`)
- `dev/index.html` (`#reviewImageBody` 정적 폼 제거)
- `dev/js/admin.js` (`saveCampaignEdit` 리뷰어형 채널 강제 검증)
- `dev/lib/i18n/{ja,ko}.js` (`reviewImageHint` 문구 갱신, `reviewImageOfChannelLabel` 신규 키)
- `docs/specs/2026-05-28-multichannel-deliverable-split.md` (§0 정정 이력 + 구현 결과)
- 빌드 산출물 `index.html`·`admin/index.html`

### 후속 PR
- **PR 3 (사양 2 PR 2)** — 관리자 검수 모달 「다른 채널 상태 안내 박스」(모달 하단 회색) + 진행현황 채널별 칩 + 알림 본문 채널 라벨 + i18n
- **PR 4 (사양 2 PR 3)** — 엑셀 채널별 컬럼 분리. 단일 캠페인은 6컬럼×채널 수 펼침, 다중 캠페인은 합집합 분리 (사용자 결정)
