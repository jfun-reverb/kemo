# 관리자 일일 통합 다이제스트 — 모집 채널 기준 SNS + 팔로워 표시

**작성일:** 2026-05-27
**작성 세션:** 기획/설계
**대상 함수:** `supabase/functions/notify-admin-daily-digest/index.ts`
**관련 메일:** 관리자 일일 통합 다이제스트 (`notify-admin-daily-digest`, pg_cron 매일 KST 09:00, 4섹션 1통)

---

## 1. 배경 / 목적

관리자 일일 통합 다이제스트 메일의 각 신청자(인플루언서) 행에는 SNS 셀이 있다. 현재는 **인플루언서 본인이 지정한 대표 SNS**(`primary_sns`) 기준으로 아이디만 표시한다.

운영자 입장에서는 "이 사람이 **그 캠페인이 모집하는 SNS**에서 어느 정도 영향력이 있는가"가 더 중요하다. 따라서:

1. 인플루언서 대표 SNS가 아니라 **그 캠페인이 모집하는 SNS** 기준으로 아이디를 표시한다.
2. 해당 SNS의 **팔로워 수**를 함께 표시한다.

## 2. 사용자 결정 사항 (2026-05-27 확정)

| 항목 | 결정 |
|---|---|
| 캠페인이 여러 SNS를 동시 모집할 때 | **모집 채널 전부 표시** (인플루언서가 등록한 채널만, 각각 아이디 + 팔로워 수 한 줄씩) |
| 적용 범위 | **다이제스트 4개 섹션 모두 통일** (신청 접수 · 응모 취소 · 결과물 제출 · 재처리) |

## 3. 현재 동작 (변경 전)

### 3-1. SNS 셀 헬퍼
- `snsCellHtml(infl)` → `snsLink(infl)` 호출
- `snsLink`: `primary_sns` 우선, 없으면 등록된 첫 채널로 폴백. **단일 채널만** 반환, **팔로워 수 없음**
- 출력 예: `@handle · IG`

### 3-2. 데이터 조회 (변경 전 쿼리)
- 캠페인 (index.ts ~940행): `select("id, campaign_no, title, recruit_type")` — **모집 채널 `channel` 미포함**
- 인플루언서 (index.ts ~953행): `select("id, name, name_kanji, name_kana, primary_sns, ig, tiktok, x, youtube")` — **팔로워 컬럼 미포함**

### 3-3. 4개 섹션 모두 `snsCellHtml(i)` 호출 + 캠페인별 그룹화
- 섹션 1 신청 접수: `renderReceivedSection` — `camp = campaignMap.get(cid)` 접근 가능
- 섹션 2 응모 취소: `renderCancelledSection` — 동일
- 섹션 3 결과물 제출: `renderSubmittedSection` — 동일 (단 `cid = "__no_campaign__"` 가능)
- 섹션 4 재처리: `renderReprocessedSection` — 동일 (단 `cid = "__no_campaign__"` 가능)

## 4. 변경 사양

### 4-1. 데이터 모델 (코드 내 인터페이스/쿼리만, DB 스키마 변경 없음)

**`CampaignRow` 에 모집 채널 추가**
```
interface CampaignRow {
  id, campaign_no, title, recruit_type,
  channel: string | null,   // 신규: 콤마 구분 (예 "instagram,x")
}
```
- 캠페인 쿼리에 `channel` 컬럼 추가

**`InfluencerRow` 에 채널별 팔로워 추가**
```
interface InfluencerRow {
  ... 기존 ...,
  ig_followers: number | null,
  x_followers: number | null,
  tiktok_followers: number | null,
  youtube_followers: number | null,
}
```
- 인플루언서 쿼리에 `ig_followers, x_followers, tiktok_followers, youtube_followers` 추가
- (컬럼명은 `dev/js/mypage.js` 의 프로필 저장 필드와 동일하게 확인됨)

> **DB 변경 없음** — 모두 기존 컬럼이다. 신규 테이블·컬럼·원격 호출 함수(RPC)·행 단위 보안 정책(RLS) 없음. service_role 키로 동작하는 Edge Function 의 조회 컬럼만 늘린다.

### 4-2. 신규 헬퍼 `recruitSnsCellHtml(infl, channelCsv)`

기존 `snsLink` 의 채널 정의 배열(코드·핸들·라벨·URL)을 재사용한다. 추가로 채널별 팔로워 키 매핑을 둔다.

```
채널 정의:
  instagram → { handle: ig,      followers: ig_followers,      label: "IG", url: instagram.com/{h}/ }
  tiktok    → { handle: tiktok,  followers: tiktok_followers,  label: "TT", url: tiktok.com/@{h} }
  x         → { handle: x,       followers: x_followers,       label: "X",  url: x.com/{h} }
  youtube   → { handle: youtube, followers: youtube_followers, label: "YT", url: youtube.com/@{h} }
```

**로직:**
1. `channelCsv` 를 `split(',')` → trim → 빈값 제거 → 모집 채널 코드 배열
2. 모집 채널 배열을 순회하며, 인플루언서가 **그 채널 핸들을 등록한 경우만** 한 줄 생성:
   - `@handle · LABEL N,NNN`
   - 팔로워가 0 또는 null 이면 숫자 생략 → `@handle · LABEL`
3. 생성된 줄이 1개 이상이면 줄들을 `<br>` 로 이어 반환
4. **폴백** — 아래 경우 기존 `snsCellHtml(infl)`(대표 SNS) 으로 폴백:
   - `channelCsv` 가 비었거나 null (레거시·외부 캠페인·`__no_campaign__`)
   - 모집 채널 중 인플루언서가 등록한 핸들이 하나도 없음

### 4-3. 각 섹션 호출부 변경

4개 섹션의 행 생성에서 `snsCellHtml(i)` → `recruitSnsCellHtml(i, camp?.channel ?? null)` 로 교체.
- `camp` 가 undefined(`__no_campaign__`)이면 `channelCsv = null` → 폴백 동작

## 5. 표기 형식 (확정안)

- 단일 모집 채널:
  ```
  @sakura_beauty · IG 12,300
  ```
- 멀티 모집 채널(인스타그램 & X 둘 다 등록):
  ```
  @sakura_beauty · IG 12,300
  @sakura_x · X 3,400
  ```
- 팔로워 미입력(0/null): `@sakura_beauty · IG`
- 폴백(모집 채널 미등록/캠페인 없음): 기존과 동일 `@handle · IG` (대표 기준, 팔로워 없음)

- 팔로워 숫자: 천단위 콤마 (`toLocaleString` 또는 정규식). "명" 단위 텍스트는 붙이지 않음(셀 폭 절약).
- 스타일: 기존 셀과 동일 (`a` 태그 `#5B6BBF`, 라벨·숫자는 `#888` 11px).

## 6. 경우의 수 정리

| # | 캠페인 모집 채널 | 인플루언서 등록 상태 | 표시 결과 |
|---|---|---|---|
| 1 | instagram | ig 등록(팔로워 1.2만) | `@id · IG 12,300` |
| 2 | instagram,x (둘 다) | ig·x 둘 다 등록 | 2줄 (IG, X 각각 팔로워) |
| 3 | instagram,x | ig만 등록 | `@id · IG ...` 1줄 (x 줄 생략) |
| 4 | instagram | 팔로워 미입력 | `@id · IG` (숫자 생략) |
| 5 | instagram,x | 둘 다 미등록(이론상 드묾) | 폴백 → 대표 SNS |
| 6 | (빈값/레거시/외부) | — | 폴백 → 대표 SNS |
| 7 | `__no_campaign__` (결과물·재처리) | — | 폴백 → 대표 SNS |

## 7. 영향 범위 / 리스크

- **수정 파일 1개**: `supabase/functions/notify-admin-daily-digest/index.ts` (인터페이스 2개 + 쿼리 2곳 + 헬퍼 1개 신규 + 호출부 4곳). 메일 템플릿(`templates.ts`)은 변경 없음 — 셀 안 HTML만 바뀜.
- **DB·RLS·Auth 영향 없음**.
- **deprecated 함수 `notify-application-received-admin-daily`** 는 이번 요청 범위 밖(cron 해제됨). 통일 일관성 차원에서 추후 동일 패턴 적용 가능하나 이번엔 제외.
- 리스크: 인플루언서 쿼리 컬럼 증가 → 조회 부하 미미(다이제스트는 어제 신청 건 한정, 행 수 적음).
- 폴백 안전망이 있어 데이터 누락 시에도 "-" 또는 대표 SNS 로 graceful degrade.

## 8. 배포 / 검증 절차 (메모리 `feedback_dev_no_mail_test` 정책)

1. dev 브랜치 코드 수정 + `reverb-reviewer` GO + 빌드 영향 없음(Edge Function 은 build.sh 대상 아님)
2. 개발 Edge Function 배포 (`supabase functions deploy notify-admin-daily-digest --project-ref qysmxtipobomefudyixw`) — **환경 동기화 목적, 수동 발송 테스트는 건너뜀**
3. 운영 dev→main 머지 후 운영 Edge Function 배포 + 운영에서 수동 호출 1회로 인박스 확인
4. 검증 포인트: 멀티 채널 캠페인 신청 건에서 2줄 표시 + 팔로워 수 정확, 폴백 케이스(외부 캠페인) 깨지지 않음

## 9. 약관/개인정보 영향

- 팔로워 수는 이미 보유·관리자 화면에서 노출 중인 정보(인플루언서 본인이 입력). 신규 수집·제3자 제공·국외 이전 변경 없음 → **약관·개인정보처리방침 영향 없음**.

---

## 구현 결과

**구현일:** 2026-05-27
**관련 커밋:** feature/digest-recruit-sns (dev PR #297)
**배포 상태:** 개발 Edge Function 배포 완료 + **운영 Edge Function 배포 완료**(twofagomeizrtkwlhsuv, 2026-05-27). DB 변경 없어 마이그레이션 불필요. 운영 main 코드 미머지(Edge Function deploy 로만 반영 — 보류 기능 회피). **검증 대기**: 다음 관리자 일일 다이제스트 자동 발송(KST 매일 09:00, 첫 적용 2026-05-28 목)에서 신청자 SNS 칸의 모집채널 기준 아이디+팔로워 표시 확인.

### 초안 대비 변경 사항
- 추가된 것: 없음 (초안대로 구현 — 인터페이스 2개 확장 + 헬퍼 1개 + 쿼리 2곳 + 호출부 4곳)
- 빠진 것: 없음
- 달라진 것: 폴백 placeholder 객체(취소·제출·재처리 섹션의 미발견 인플 대체) 3곳에 팔로워 4개 필드를 `null` 로 추가 — `InfluencerRow` 인터페이스에 팔로워 컬럼을 넣으면서 타입 정합을 위해 필요. 초안엔 명시 안 됐으나 동작 영향 없는 타입 보강.

### 구현 중 기술 결정 사항
- `recruitSnsCellHtml` 의 파라미터 타입을 `InfluencerRow` 전체가 아닌 **인라인 타입(팔로워 4개는 optional)** 으로 정의 → 폴백 placeholder 객체도 그대로 통과. 기존 `snsCellHtml` 패턴과 동일.
- 팔로워 0/null 은 숫자 생략 (`def.followers && def.followers > 0`). 천단위 콤마는 `toLocaleString("en-US")`.
- `deno check` 의 타입 에러 5개는 모두 `resolveAdminEmails`(274~285) + 호출부(1135)의 기존 `supabase-js` 제네릭 추론 문제 — 본 변경 영역과 무관(이 함수는 운영 배포되어 정상 작동 중). 본 변경 라인 에러 0.
- DB 스키마 변경 없음 — 모두 기존 컬럼. service_role Edge Function 조회 컬럼만 증가.
