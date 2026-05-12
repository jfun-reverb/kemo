# 사양서: 참여방법·주의사항·NG 미니 에디터 이미지 첨부 강화

> **작성일**: 2026-05-12
> **작성 세션**: 기획/설계
> **상태**: 사양 확정
> **연관 사양**: `docs/specs/2026-05-12-ng-sets.md` (C. NG 사항 번들화) — NG 항목 스키마가 본 사양으로 강화됨. C PR 안에 포함하거나 본 사양을 C 머지 후 별도 PR로 진행
> **예상 PR 분할**: 1개 (단일)

---

## 1. 결정 요약 (2026-05-12)

| 항목 | 결정 |
|---|---|
| 적용 범위 | **참여방법(`participation_steps`) + 주의사항(`caution_items`) + NG(`ng_items`) 모두** |
| 적용 필드 | desc(설명) + 항목 본문(html) 양언어(한·일). 단계·항목 제목(title)은 평문 유지 (짧은 텍스트라 서식 불요) |
| 미니 에디터 기능 | **굵게·기울이기·밑줄·취소선·링크 + 이미지 삽입** (주의사항 현재 5종에 이미지 1종 추가) |
| 이미지 첨부 방식 | **파일 업로드만** — Supabase Storage 업로드 후 URL 자동 삽입. 외부 URL 직접 입력 금지 |
| 저장 버킷 | **기존 `campaign-images` 버킷 공용** + 폴더 분리 (`/content/{campaign_id}/`) |
| 이미지 기능 범위 | **기본만** — 삽입 + 삭제. 캡션·정렬·크기 옵션 없음. 자동 가로 100% + 가운데 정렬 |
| 파일 크기·형식 | 최대 5MB / jpg·png·webp 허용 (gif 제외) |
| 데이터 호환 | jsonb 안 desc/html 필드는 이미 텍스트 — 미니 에디터 적용 후 HTML 저장. 기존 평문 데이터는 HTML 렌더에서 그대로 텍스트로 표시 (서식 미적용 폴백) |
| XSS 방어 | **저장 + 렌더 이중 DOMPurify sanitize**. allowed tags: `b/strong/i/em/u/s/a/img/br/p`. allowed attrs: `href/src/alt/class`. `src`는 https URL + Supabase Storage 도메인만 허용 |
| 작업 시작 | NG 사양(C) 미적용 상태라 C PR에 합류하거나 본 사양을 C 머지 후 단독 PR로 진행 |

---

## 2. DB 영향 (없음)

- 모든 변경은 jsonb 안 HTML 문자열 저장 — 마이그레이션 없음
- `campaigns.participation_steps`, `campaigns.caution_items`, `campaigns.ng_items` (C 사양 머지 후) 모두 영향
- 번들 테이블(`participation_sets.steps`, `caution_sets.items`, `ng_sets.items`)도 동일 — jsonb 키 그대로
- RLS 변경 없음
- 단 마이그레이션 110이 백필한 기존 평문 desc는 그대로 유지 — HTML escape 없이 평문이 화면에 텍스트로 보임 (안전)

---

## 3. Supabase Storage 영향

### 3-1. 버킷 정책 (`campaign-images`)

- 기존 정책 그대로 (`campaign_admin` 이상 INSERT, public SELECT)
- 폴더 구분: 신규 콘텐츠 이미지는 `content/{campaign_id}/{uuid}.{ext}` 경로
- 기존 대표 이미지(`img1`~`img8`)와 폴더 분리 — 파일명 충돌 없음

### 3-2. 파일 크기·형식 가드

- 클라이언트: `dev/lib/storage.js`에 신규 함수 `uploadContentImage(file, campaignId)`
  - `file.size > 5_000_000`이면 알럿 후 차단
  - `file.type` 화이트리스트: `image/jpeg`, `image/png`, `image/webp`
- 서버: Supabase Storage 버킷 정책의 MIME type / size 제한은 기존 그대로 유지 (선택)

### 3-3. URL 검증

- DOMPurify 안 `<img src>` URL 검증:
  - https 스킴만 허용
  - 호스트가 `*.supabase.co` 또는 환경별 Supabase URL (개발/운영)에 한정
  - 그 외 외부 URL은 sanitize 단계에서 차단

---

## 4. 미니 에디터 컴포넌트 확장

### 4-1. 현재 (주의사항)

- 인라인 미니 에디터 — `contenteditable` div + 툴바 5종 (굵게·기울이기·밑줄·취소선·링크)
- DOMPurify allowed: `b/strong/i/em/u/s/a/br`. `a[href]` https 화이트리스트

### 4-2. 확장 후 (참여방법·주의사항·NG 공통)

- 툴바에 「이미지 삽입」 버튼 1개 추가
  - 클릭 시 숨김 `<input type="file" accept="image/jpeg,image/png,image/webp">` 트리거
  - 파일 선택 → `uploadContentImage()` 호출 → 받은 URL을 `<img src="..." alt="" class="rich-img">`로 현재 커서 위치에 삽입
- 업로드 중 토스트/스피너 (간단히)
- 업로드 실패 시 에러 메시지
- DOMPurify allowed 확장: `img[src,alt,class]` + `p/br`
- CSS: `.rich-img { max-width: 100%; display: block; margin: 8px auto; }` — 가로 100%·가운데 정렬

### 4-3. 컴포넌트 위치

- 공통 헬퍼: `dev/lib/shared.js`의 `sanitizeRich/richHtml/renderRich` 확장 또는 별도 `richEditor.js` 분리 — 작업자 판단
- 사용처:
  - 참여방법 편집 모달 (`dev/js/admin.js`의 `openCampParticipationModal` 또는 유사)
  - 주의사항 편집 모달 (`dev/js/admin.js`의 `openCampCautionModal` 또는 유사)
  - NG 편집 모달 (C 사양 머지 후 동일 패턴)
  - 번들 자체 편집 모달(`participation_sets`, `caution_sets`, `ng_sets` 관리자 페인)

---

## 5. 참여방법 적용 세부 (현재 textarea → 미니 에디터)

### 5-1. 현재
- 참여방법 편집 모달의 단계별 desc_ko/desc_ja는 textarea 평문 입력으로 추정
- jsonb 저장 시 평문 그대로

### 5-2. 변경 후
- textarea → 미니 에디터(div contenteditable)로 교체
- 저장 시 DOMPurify sanitize 후 HTML 저장
- 기존 평문 데이터(예: 마이그레이션 110 백필 데이터)는 그대로 렌더 — `<div>평문</div>` 형태로 보임. 줄바꿈은 `\n` → `<br>` 자동 변환 (미니 에디터 진입 시)
- title_ko/title_ja는 단계 헤더라 짧은 텍스트로 유지 (평문 input)

### 5-3. 인플루언서 화면 (`dev/js/application.js`)

- 참여방법 단계 desc 렌더 — `richHtml(step.desc_ja)` 또는 `renderRich(step.desc_ja)`로 변경 (현재 단순 텍스트 표시일 가능성)
- 모바일 폭에서도 이미지 가로 100% 자연 반응형 (`.rich-img max-width: 100%`)

---

## 6. 주의사항 적용 세부 (이미지 기능만 추가)

### 6-1. 현재
- 미니 에디터 5종 + DOMPurify 5태그
- jsonb `caution_items[i].html_ko/html_ja`

### 6-2. 변경 후
- 미니 에디터 툴바에 이미지 삽입 1개 추가
- DOMPurify allowed에 `img` 태그·`src/alt/class` 속성 + `p/br`
- 인플루언서 화면 캠페인 상세 + 신청 모달 양쪽 — 기존 `richHtml(item.html_ja)` 그대로 사용. 이미지 자동 렌더

---

## 7. NG 적용 세부 (C 사양 머지 후)

### 7-1. NG 사양(C)과의 관계
- C 사양은 «항목 스키마: 주의사항과 동일 (`html_ko`, `html_ja`)»로 확정됨
- 본 사양으로 «주의사항 미니 에디터 + 이미지»가 확장 → NG도 자동으로 동일 패턴 적용 (코드 재사용)
- C 사양서 §2-4 「아이템 스키마」에 본 사양 의존 추가 메모

### 7-2. 합류 방식
- 옵션 A: C PR-B(캠페인 폼 + 인플루언서 상세 + 미리보기) 안에 본 사양의 «참여방법·주의사항 미니 에디터 확장»도 함께 포함 — 한 PR
- 옵션 B: 본 사양을 별도 PR로 먼저 적용 후 C PR-B에서 NG는 자동으로 같은 패턴 사용

운영 영향 같음 → 작업자 판단

---

## 8. 영향 파일

| 영역 | 파일 |
|---|---|
| 공통 헬퍼 | `dev/lib/shared.js` (sanitize/render 확장) |
| 업로드 함수 | `dev/lib/storage.js` (`uploadContentImage` 신규) |
| 관리자 캠페인 폼 | `dev/js/admin.js` (참여방법·주의사항 편집 모달) |
| 관리자 번들 페인 | `dev/js/admin.js` (기준 데이터 페인의 참여방법·주의사항 번들 편집 모달) |
| 인플루언서 화면 | `dev/js/application.js` (참여방법 desc 렌더 — `richHtml` 적용) |
| 인플루언서 신청 모달 | `dev/js/application.js` (주의사항 박스 — 이미 `richHtml`이라면 그대로) |
| 관리자 HTML | `dev/admin/index.html` (필요한 마크업 변경 — 모달 host 그대로) |
| CSS | `dev/css/admin.css`, `dev/css/components.css` — `.rich-img`, `.rich-content` 보강 |

---

## 9. QA 시나리오 (개발서버 → reverb-qa-tester light)

1. 캠페인 편집 → 참여방법 모달 → 1단계 desc에 굵게·기울이기 적용 → 저장 → 인플루언서 캠페인 상세에 서식 정상 노출
2. 같은 모달에서 이미지 삽입 → 파일 선택(jpg 2MB) → 업로드 후 미니 에디터에 자동 삽입 → 저장 → 인플루언서 상세에 가로 100% 가운데 정렬 렌더
3. 6MB 이미지 선택 → 크기 제한 알럿 + 차단
4. gif 이미지 선택 → 형식 제한 알럿 + 차단
5. 주의사항 모달 → 이미지 삽입 → 저장 → 캠페인 상세 + 신청 모달 양쪽에서 이미지 노출
6. NG 모달(C 머지 후) → 이미지 삽입 → 저장 → 캠페인 상세 NG 박스에 이미지 노출
7. 기존 평문 desc 데이터(마이그레이션 110 백필) → 편집 모달 진입 → 평문이 줄바꿈 보존하며 표시 → 저장 후에도 평문 그대로 (서식 미적용)
8. DOMPurify 우회 시도 — `<script>` 직접 입력 → 저장 시 제거 확인
9. 외부 URL 이미지 (`<img src="https://evil.com/x.png">`) 직접 입력 → 저장 시 src 화이트리스트로 차단
10. 인플루언서 모바일 폭(480px) → 이미지가 화면 폭 안에서 자연스럽게 축소
11. 번들 자체 편집(`participation_sets`, `caution_sets` 관리자 페인) → 이미지 삽입 정상 작동
12. 이미지 삽입 후 미니 에디터에서 이미지 요소 클릭·삭제(`Backspace`) → 정상 제거. Supabase Storage의 실제 파일은 그대로 남음 (고아 파일 정리는 후속 사양 — 운영 영향 미미)

---

## 10. 보안 영향

- DOMPurify allowed 태그 확장(img·p·br) → XSS 위험 증가
  - `src` 화이트리스트(Supabase 도메인 + https)로 위험 차단
  - `onerror`·`onload` 등 모든 이벤트 핸들러 속성은 DOMPurify 기본 차단
- 운영자(campaign_admin 이상)만 입력 가능 → 신뢰 경계 안
- 외부 URL 입력 차단 → 외부 서버에서의 이미지 트래픽 추적·서버 공격 가능성 0
- Supabase Storage 버킷 SELECT public — 캠페인 콘텐츠 이미지는 인플루언서·검색엔진에 노출되어도 무방 (광고성 자료)

---

## 11. 충돌 점검

- **NG 사양(C)**: 본 사양과 같은 미니 에디터를 공유 → C PR-B에 합치거나 본 사양을 먼저 머지 후 C에서 자동 적용
- **응모 취소 (A)·관리자 메일 수신 (B)·브랜드 서베이 (D·E)**: 영역 다름. 충돌 없음
- **마이그레이션**: 본 사양은 마이그레이션 없음 — 번호 점유 무관
- **Storage 버킷**: 기존 정책 그대로 — 충돌 없음

---

## 12. 약관·정책 영향

- 운영자가 캠페인 콘텐츠 가이드에 이미지를 첨부할 수 있게 됨 — 인플루언서 표시 정보 풍부화. 개인정보 수집·처리 변동 없음
- 약관·개인정보처리방침 영향 없음
- 배포 후 `/약관확인` 1회 실행 권장 (점검만)

---

## 13. 롤백 절차

1. 미니 에디터 툴바에서 이미지 버튼 제거
2. DOMPurify allowed에서 `img/p/br` 제거 — 기존 5종 복원
3. `uploadContentImage` 함수 제거 (Storage에 남은 이미지 파일은 그대로 둬도 무방 — 운영 영향 없음)
4. 기존 평문 textarea로 참여방법 desc 복원 (선택 — 미니 에디터 자체는 유지하고 이미지만 빼도 충분)
5. `git revert` 본 PR

---

## 14. 시작 절차

```bash
cd ~/Documents/projects/reverb-jp
git checkout dev
git pull origin dev

# NG 사양(C)이 머지됐는지 확인
git log --oneline -10

# 합류 방식 결정 (C에 포함 vs 별도 PR)
# 별도 PR이라면:
git checkout -b feature/rich-editor-image
```

---

## 15. 미해결 / 후속

### 15-1. 확정 (2026-05-12)
- 적용 범위: 참여방법 + 주의사항 + NG 모두
- 이미지 방식: 파일 업로드만 (외부 URL 입력 금지)
- 저장 버킷: 기존 `campaign-images` + 폴더 분리
- 이미지 기능: 기본만 (삽입·삭제, 가로 100%·가운데 정렬, 캡션 없음)
- 파일 크기·형식: 5MB / jpg·png·webp
- XSS 방어: DOMPurify 저장+렌더 이중 sanitize, src 화이트리스트

### 15-2. 별도 후속
- Storage 고아 이미지 정리 — 미니 에디터에서 이미지 삭제해도 Storage 파일은 남음. 운영 1~2개월 후 사용량 검토하고 별도 정리 작업 가능
- 캡션·정렬·크기 옵션 — 운영팀 요청 시 별도 사양
- 「번들 다시 불러오기」 시 번들 안 이미지 URL이 캠페인 jsonb에 그대로 복사 — Storage 파일 공유 (같은 URL 참조). 번들 삭제 시 파일은 보존
