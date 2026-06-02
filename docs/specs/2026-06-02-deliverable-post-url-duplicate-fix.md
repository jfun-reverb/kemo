# [P0·최우선] 게시물 URL 재제출 시 유니크 제약 위반 버그 수정

**작성일:** 2026-06-02
**우선순위:** 🔴 **P0 (최우선)** — 운영 중 인플루언서가 결과물 제출에 막히는 실사용 차단 버그
**상태:** 기획 초안 (개발 세션 즉시 착수 권장)
**작성 세션:** 기획/설계 세션 (코드 직접 검증 완료)
**제보:** 운영 오류 로그 — `duplicate key value violates unique constraint "uidx_deliverables_post_url"`, 화면 `#activity`, 2026-06-02 16:18, iPhone Safari

---

## 1. 증상

인플루언서가 기프팅/방문형 캠페인 활동관리(`#activity`)에서 SNS 게시물 링크(URL)를 제출할 때, **같은 신청건에 같은 링크가 이미 있으면** 데이터베이스 유니크 제약 위반으로 제출이 실패한다. 친화적 일본어 에러로 변환되지 않아 날것의 제약 위반 메시지가 노출됐을 가능성이 크다.

## 2. 현재 상태 (planning.md 규칙 A — 2026-06-02 코드 직접 검증)

### 유니크 제약 정의
`supabase/migrations/035_create_deliverables.sql:98`
```sql
CREATE UNIQUE INDEX uidx_deliverables_post_url
  ON deliverables(application_id, kind, post_url)
  WHERE kind = 'post' AND post_url IS NOT NULL;
```
→ **같은 신청(application_id) 안에서 kind='post'인 같은 post_url은 1건만.**

### 근본 원인 — 결과물 저장 함수의 비대칭 누락
`dev/lib/storage.js` `insertDraftDeliverable(payload)` (828행~):

| 결과물 종류 | 기존 행 탐색 → UPDATE 분기 | 결과 |
|---|---|---|
| `review_image` (리뷰어 채널별 사진) | ✅ **있음** — 마이그레이션 158(리뷰어 채널 유니크 인덱스) 충돌 방지로 명시 추가. 같은 `application_id`+`kind='review_image'`+`post_channel` 행 있으면 `status='draft'`로 UPDATE 후 return(INSERT 스킵) | 재제출 안전 |
| `post` (기프팅/방문형 게시물 URL) | ❌ **없음** — 무조건 `db.from('deliverables').insert(row)` | **같은 URL 재제출 시 유니크 위반** |

게시물 URL 제출 진입점: `dev/js/application.js` `addDraftUrl()` (1164행~) → `insertDraftDeliverable({kind:'post', post_url, post_channel})`. 주석에 "마감 후라도 반려 이력 있으면 재제출 허용"이라 동일 URL 재제출 경로가 열려 있음.

### 문서 불일치 (부가)
`CLAUDE.md` "활동관리" 항목: **"동일 URL은 `post_submissions` 배열에 날짜 누적"** 이라 기재돼 있으나, 실제 클라이언트 코드엔 그 누적 분기가 **없다**. 문서가 의도한 동작이 미구현 상태.

### 충돌 가능성 있는 기존 동작
- `review_image` 분기는 이미 UPDATE 패턴을 쓰므로, `post`도 같은 패턴을 미러링하면 구조적으로 일관. 충돌 없음.

## 3. 의심·경우의 수 (planning.md 규칙 B — 수정 시 반드시 고려)

| # | 시나리오 | 위험 | 대응 |
|---|---|---|---|
| ① | **기존 post 행이 `approved`(승인) 상태인데 같은 URL 재제출** | `review_image`처럼 무조건 `status='draft'`로 되돌리면 **승인된 결과물이 draft로 떨어지는 사고** | 기존 행이 `approved`면 되돌리지 말고 **차단**(친화 안내). `rejected`/`pending`/`draft`일 때만 재제출 허용 |
| ② | 같은 URL인데 **다른 채널**로 제출 | post는 URL별 1행(채널 무관 유니크)이라 같은 URL은 무조건 1건 | UPDATE 시 channel도 갱신, 혹은 안내 |
| ③ | 한 신청에 **여러 다른 게시물(다른 URL)** 제출 | post는 URL별 1행이라 정상 — 탐색을 반드시 `post_url`까지 일치로 해야 함. `application_id`만으로 탐색하면 다른 URL 게시물을 덮어쓰는 사고 | 탐색 조건 = `application_id` + `kind='post'` + `post_url` 3개 모두 일치 |
| ④ | `post_submissions` 누적 시 중복 날짜 | 같은 URL 여러 번이면 배열이 비대해짐 | 누적은 의도된 동작(이력). 무한 증가 아님 |
| ⑤ | 친화 에러 미변환 | 사용자가 날것 제약명을 봄 | `friendlyErrorJa`에 매핑 병행 |

### 의도 모호점
- "재제출 허용"의 범위 — `rejected`만인지 `pending`도인지. **승인(`approved`)은 절대 재제출로 덮어쓰면 안 됨**(경우의 수 ①). 구현 시 status 가드 필수.

## 4. 제안 — 수정 설계

### 4-1. 근본 수정 (필수)
`insertDraftDeliverable`의 `kind === 'post'` 경우에도 `review_image`와 동일한 "기존 행 탐색 → 분기" 추가:

1. `application_id` + `kind='post'` + `post_url` **3개 모두 일치**하는 기존 행 조회(`.maybeSingle()`)
2. 기존 행이 있으면:
   - `status === 'approved'` → **차단**, 친화 안내("이미 승인된 게시물입니다") — 경우의 수 ①
   - 그 외(`rejected`/`pending`/`draft`) → `status='draft'`로 되돌리고 `reject_reason` 등 초기화 + `post_submissions`에 `{url, channel, submitted_at}` **append**(CLAUDE.md 의도대로) + `post_channel` 갱신 → return(INSERT 스킵)
3. 기존 행 없으면 → 현행 INSERT 진행

`review_image` 분기(840~858행)를 패턴 참조하되 **status 가드(경우의 수 ①)와 post_url 일치 탐색(경우의 수 ③)을 반드시 포함**.

### 4-2. 친화 에러 매핑 (병행 권장)
`friendlyErrorJa`(또는 `friendlyError`)에 `uidx_deliverables_post_url` / `duplicate key` → "同じURLは既に提出済みです" 류 안내 추가. 근본 수정 후에도 만일의 동시성(다중 탭 동시 제출) 대비 안전망.

### 4-3. 문서 정합
- `CLAUDE.md` "활동관리"의 "동일 URL은 post_submissions 누적"이 실제 구현과 일치하게 됨 — 수정 후 한 줄 확인.

## 5. 검증 (개발 세션)
- 개발서버에서 기프팅/방문형 캠페인 결과물:
  1. 같은 URL 두 번 제출 → 두 번째가 에러 없이 기존 행 갱신 + `post_submissions` 누적되는지
  2. 승인된 게시물 같은 URL 재제출 → 차단되고 draft로 안 떨어지는지 (경우의 수 ①)
  3. 다른 URL 게시물 추가 제출 → 별도 행으로 정상 생성(기존 게시물 안 덮어쓰는지, 경우의 수 ③)
- `reverb-reviewer` + `reverb-qa-tester`(응모/결과물 플로우 변경이라 Full 또는 활동관리 시나리오)

## 6. 배포
- DB 변경 없음(클라이언트 로직 수정만) → `bash dev/build.sh` 재빌드 필요
- 운영 핫픽스 성격(실사용 차단). dev 검증 후 운영 배포 여부는 사용자 확인. 보류 기능과 얽히면 메모리 `project_prod_hotfix_rebuild` 패턴(소스 diff apply + 재빌드)

## 7. 구현 결과 (개발 세션이 채울 것)
