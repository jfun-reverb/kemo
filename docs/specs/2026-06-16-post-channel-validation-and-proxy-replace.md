# 게시물(post) 채널 일치 검증 + 대리 등록 교체 (3건 묶음)

**작성일:** 2026-06-16
**작성:** 기획/설계 (reverb-planner 초안 + 사용자 결정 반영)

---

## 배경 — 운영 사고

- 캠페인: 기프팅(gifting) + 채널 인스타그램(instagram), 캠페인 번호 `B0019-C005`
- 인플루언서가 활동관리에서 게시물 URL 제출 시, 실수로 LIPS(lipscosme.com) 게시물 링크를 붙여넣음
- 시스템이 URL만 보고 채널을 'lips'로 자동 판별·저장 — **캠페인이 요구한 instagram과 다른데도 통과**
- 관리자가 "正しいURLを再登録願います"(올바른 URL 재등록 요청)로 반려
- 인플루언서가 재업로드를 못 한다고 연락 → 관리자가 대리 등록으로 처리하려다 "같은 게시물 URL이 이미 등록되어 있습니다" 차단에 막힘

원인은 **인플루언서 입력 실수 + 시스템의 채널 일치 검증 누락**의 결합. 후속으로 대리 등록 교체 기능 부재, 잘못된 채널 행 잔존 문제까지 드러남.

---

## 현재 상태 (2026-06-16 기준)

### 관련 코드·DB·UI 진입점

**인플루언서 제출 경로**
- `dev/js/application.js`
  - `detectChannelFromUrl(url)` (776줄): 호스트명 매칭으로 7채널 판별 (instagram/tiktok/youtube/x/qoo10/lips/cosme), 매칭 실패 시 `null`. **LIPS(lipscosme.com)와 @cosme(cosme.net)는 별개 채널**
  - `addDraftUrl()` (1316줄 근처): URL 형식 검증 → 마감/반려 이력 게이트 → `detectChannelFromUrl` → 실패 시 수동 드롭다운 `postChannelManual` → `insertDraftDeliverable({kind:'post', post_url, post_channel})`. **캠페인 channel 과의 일치 검증 없음** (사고 1 지점)
  - `_latestNonDraftIsRejected(allDelivs, kind)` (924줄): draft 제외 최신 1건이 rejected 인지 — 마감 후 재제출 허용·폼 활성 판정 기준. **kind 전체 기준(채널 무관)**
  - `applyFormGating(allDelivs)` (936줄): kind 별 폼 활성/비활성, 마감 후 반려 있으면 활성. `showPost = (rt==='gifting' || rt==='visit')`
- `dev/lib/storage.js`
  - `insertDraftDeliverable` post 분기 (880~919줄): `post_channel` 기준 **같은 채널** 기존 행 1건을 새 URL 로 UPDATE(반려→draft 복귀, `post_submissions` 누적), approved 면 차단, 없으면 INSERT. **다른 채널이면 무조건 새 INSERT** (사고 3 지점)

**관리자 대리 등록 경로**
- `dev/js/admin-deliverables.js`
  - `submitAdminProxyDelivProxy()` (2111줄): payload 수집 → `adminCreateDeliverableProxy(payload)`. 중복 에러(코드 23505)는 토스트에 「검수에서 처리」 안내만 (2188줄)
  - `_populateAdminProxyPostChannelOptions()` (2032줄): 게시물 채널 드롭다운을 **이미 캠페인 channel 로만** 채움 → 관리자 측은 인플보다 안전
  - `onAdminProxyPostUrlInput()` (2086줄): URL 자동 판별값이 캠페인 채널에 있으면 자동 선택
- `supabase/migrations/163_admin_proxy_evidence.sql`
  - `admin_create_deliverable_proxy(...)` post 분기 (205~225줄): `application_id+kind='post'+post_url` 존재 시 **무조건 차단**(23505). 교체 로직 없음 (사고 2 지점). **서버에 채널 일치 검증 없음** → 우회 가능
  - INSERT (250~296줄): `status='approved'` 즉시 승인 + `deliverable_events`(admin_proxy_submit) + `notifications`(deliverable_proxy_submitted) INSERT

**DB 제약·선례**
- `supabase/migrations/035_create_deliverables.sql` (96~100줄): `uidx_deliverables_post_url` 부분 유니크 = `(application_id, kind, post_url) WHERE kind='post' AND post_url IS NOT NULL`. **게시물 링크 단위 유니크 (채널 무관)**
- `supabase/migrations/158_review_image_channel_unique.sql`: review_image 는 `(application_id, post_channel)` 채널 유니크 — 교체 설계 참고 선례
- 캠페인 컬럼: `channel`(콤마 구분 `"instagram,x"`), `channel_match`(`'or'|'and'`), `primary_channel`(단일 기준)
- CLAUDE.md: LIPS·@cosme 는 **리뷰어(monitor)형 전용 채널**. post 는 gifting/visit → gifting 캠페인에 lips 게시물은 애초에 정책상 불가능한 조합

### 이 제안과 충돌 가능성 있는 기존 동작
- **정책 정정**: `insertDraftDeliverable` post 교체의 「같은 채널」 단일 기준은 사고 3의 직접 원인. 채널 일치 검증을 넣으면 다른 채널로의 재제출 자체가 차단되어 사고 3은 부분 자연 해소되나, **이미 잘못 저장된 운영 행은 검증 추가만으로 안 사라짐** → 별도 정리 필요
- **유니크 제약**: 채널 교체를 "행 재사용 UPDATE"로 풀면 post_url·post_channel 동시 변경이라 `uidx_deliverables_post_url` 위반 없음. 단 "잘못 행 삭제 vs 유지" 결정에 따라 삭제 시 행 단위 보안 정책(RLS) 부재 이슈 재발 가능(storage.js 853줄 주석이 같은 함정 경고)
- 신청 게이트·팔로워 검증(primary 단일)과는 **충돌 없음 — 확인 완료** (게시물 제출은 신청 후 활동관리 단계라 신청 게이트와 분리)

### 미해결 백로그·관련 작업
- 메모리 `project_deliverable_post_url_dup_bug` (2026-06-02): 「게시물은 채널별 1건, 재제출=같은 채널 교체」 정책 + 후속 백로그에 "채널별 유니크+중복 정리" 명시 → 이번 작업이 그 후속
- 메모리 `project_admin_proxy_deliverable`: 대리 등록 운영 출시 완료, "레거시 채널 NULL 385건" 존재
- 메모리 `project_admin_proxy_duplicate_guidance` (2026-06-09): 대리 등록 시 이미 제출된 결과물 사전 안내 박스 추가됨 (이번 교체 기능과 UX 연결점, 검수대기만 안내)

---

## 의심·경우의 수 (규칙 B)

### 1. 깨질 수 있는 경우의 수
1. **`detectChannelFromUrl` 이 null 반환하는 신규/미등록 채널·단축 URL**: lookup_values 신규 채널(`channel-XXXX`)이나 단축 URL(instagr.am, t.co)은 호스트 매칭 실패 → null → 수동 드롭다운. 채널 검증을 "detect 결과 == 캠페인 채널"로만 짜면 정상 게시물(단축 URL)도 막힐 수 있음 → **detect 우선, null 이면 수동 선택값을 캠페인 채널로 제한**해 신뢰
2. **이미 잘못 저장된 운영 반려 행(lips on gifting)**: 새 검증은 신규 제출만 막음. 기존 행은 검수 화면에 잔존 + 인플이 올바른 채널로 재제출하면 신규 INSERT → 결과물 2개 → **별도 정리(Q4)**
3. **낙관적 락·이력·audit**: 대리 등록을 INSERT→교체(UPDATE)로 바꾸면 기존 반려 행의 `version`·`post_submissions`·`deliverable_events` 이어붙이기. 자동 승인으로 덮어쓸 때 직전 반려 사유·reviewed_by 초기화 누락 시 stale 표시
4. **UX(인플 안내)**: 다른 채널 링크 시 「채널이 다릅니다」 개발자 문구면 초등학생 눈높이 위반. 「このキャンペーンはInstagramの投稿が必要です。Instagramのリンク（URL）を貼ってください」식 안내
5. **UX(관리자 식별)**: 결과물 2개(lips 반려 + instagram 정상) 가 나란히 보일 때 잘못된 행 시각 구분 필요 → 캠페인 채널과 다른 post_channel 행에 경고 배지
6. **UX(대리 등록 막다른 길)**: 현재 "검수에서 처리" 안내가 정작 인플이 재업로드 못 하는 상황에선 해결책이 안 됨 → 교체 기능이 있어야 실효

### 2. 현재 구현 충돌점
- `insertDraftDeliverable` post 교체의 "같은 채널" 기준이 사고 3 원인. 채널 검증 추가로 정합되지만 "잘못 행 처리"는 교체 로직 밖이라 별도 결정(Q4)
- 데이터베이스 함수의 무조건 게시물 링크 차단(163, 222줄)을 교체로 바꾸면 사전 체크만 채널 기준 교체 분기로 (인덱스는 유지)

### 3. 의도 모호점 → 사용자 결정으로 해소 (아래 §확정)

---

## 제안·설계

### 사용자 확정 결정 (2026-06-16)
1. **채널 일치 기준**: 캠페인 channel 리스트에 게시물 채널이 포함되면 통과 (요구 채널 중 하나, =or 기준)
2. **어긋난 채널**: 완전 차단 + 안내. detect 실패 시 수동 선택칸은 캠페인 채널만 노출
3. **모두 요구(and) 캠페인의 전 채널 제출 의무**: 이번 범위 제외 (별도 백로그)
4. **잘못된 잔존 행**: 검수 화면 수동 삭제 + 경고 배지 (관리자 통제)
5. **묶음 분할**: 검증+교체 한 묶음 / 잔존 정리 별도 (총 2개)

### 묶음 1 — 채널 일치 검증 + 대리 등록 교체

**판정 헬퍼 (공통)**: `postChannelMatchesCampaign(camp, postChannel)` — `camp.channel.split(',').map(trim)` 에 `postChannel` 포함이면 true. `dev/lib/shared.js` 에 두어 인플·관리자 공유.

- **인플 (`addDraftUrl`)**: `insertDraftDeliverable` 호출 전 판정 실패면 toast 차단 + 일본어 안내(초등학생 눈높이). detect null → 수동 드롭다운 옵션을 캠페인 채널로만 제한
- **관리자 대리 (`submitAdminProxyDelivProxy`)**: 드롭다운이 이미 캠페인 채널만이지만, 제출 직전 동일 판정(방어)
- **서버 함수 (`admin_create_deliverable_proxy`)**: post 분기에 캠페인 channel 조회 후 post_channel 불일치 시 예외 발생 (최종 방어선)
- **대리 등록 교체**: 무조건 게시물 링크 차단(163, 215~225줄)을 교체 분기로 변경
  - 같은 `application_id+kind='post'+post_channel` 행이 있고 status ≠ approved → 그 행을 새 URL·status='approved'·post_submissions 누적·reviewed_by/at 갱신·반려사유 초기화로 UPDATE (INSERT 스킵)
  - approved 행이면 차단(승인 결과물 보호)
  - UPDATE 시 `deliverable_events` audit 기록, notifications(deliverable_proxy_submitted) 발송 유지
  - 클라(`submitAdminProxyDelivProxy`)는 "교체됨" 토스트로 분기

### 묶음 2 — 잘못된 채널 잔존 행 정리
- 검수 화면(결과물 관리)에서 캠페인 channel 에 없는 post_channel 반려 행에 **경고 배지** 표시
- 관리자가 그 행을 **삭제**(신규 데이터베이스 함수 또는 기존 회수 함수 확장 — 행 단위 보안 정책 부재 고려해 SECURITY DEFINER 함수 경유)
- **운영 백필 선행**: 기존 lips-on-gifting 류 잘못된 행 실태 조사 SQL → 건수 확인 후 정리 방침 확정

### DB 변경
- **마이그레이션 (번호는 개발 세션이 생성 시 확정, 플레이스홀더)**:
  - ① `admin_create_deliverable_proxy` 재정의 — post 채널 일치 검증 + 게시물 링크 무조건 차단을 채널 기준 교체로 변경 (CREATE OR REPLACE, 시그니처 동일). **묶음 1**
  - ② 잘못된 채널 post 행 삭제용 신규 함수 또는 기존 회수 확장. **묶음 2**
  - ①이 ②보다 먼저. 게시물 링크 유니크 인덱스(035) 변경 없음

---

## PR 분할

| 묶음 | 제목 | 내용 | 의존성 |
|---|---|---|---|
| **묶음 1 — 게시물 채널 검증 + 대리 등록 교체** | 채널 일치 검증(인플·관리자·서버 3중) + 반려 게시물 교체(서버 함수) + 클라 안내·토스트 | 마이그레이션 ① | 없음 (먼저) |
| **묶음 2 — 잘못된 채널 잔존 행 정리** | 검수 화면 경고 배지 + 삭제 + 운영 백필 SQL | 마이그레이션 ② | 묶음 1 운영 배포 후 (신규 유입 차단된 뒤 기존 정리) |

---

## 이 인플루언서 건(B0019-C005)의 처리

기능 배포 전까지의 임시 처리는 아래 중 택일(개발 착수 시 사용자와 재확인):
- 인플루언서에게 **올바른 인스타그램 게시물 링크로 재제출** 요청 (반려 상태라 마감 후에도 재제출 허용됨 — 단 채널이 lips→instagram 으로 바뀌어 새 행이 추가되고 lips 반려 행은 잔존 → 묶음 2 배포 후 정리)
- 또는 묶음 1 배포 후 관리자가 **대리 등록 교체**로 올바른 인스타 링크 등록

---

## 구현 결과

**구현일:** 2026-06-16
**브랜치:** feature/post-channel-validation
**마이그레이션:** 182 (`182_admin_proxy_post_channel_and_replace.sql`) — 묶음 1

### 묶음 1 구현 (채널 검증 + 대리 등록 교체)
- `dev/lib/shared.js`: `postChannelMatchesCampaign(camp, postChannel)` 헬퍼 신규 (or 기준, channel 빈값 우회)
- `dev/js/application.js`:
  - `addDraftUrl` — 채널 일치 검증 추가, 불일치 시 `t('activity.channelMismatch')` toast 차단 + 요구 채널 라벨 표시
  - `populatePostChannelManualOptions()` 신규 — 수동 채널 드롭다운을 캠페인 채널로 제한, `loadDeliverablesForActivity` showPost 분기에서 호출
- `dev/js/admin-deliverables.js`: `submitAdminProxyDelivProxy` post 분기에 채널 일치 방어 가드 (proxyApp 미탐지 시 서버 가드 위임)
- `dev/lib/i18n/ja.js`·`ko.js`: `activity.channelMismatch` 키 추가 (`{channels}` 플레이스홀더)
- `supabase/migrations/182`: `admin_create_deliverable_proxy` 재정의 — post 분기에 ①캠페인 채널 검증(channel 빈값 우회) ②같은 채널 반려·검수대기 게시물 교체(UPDATE, status='approved', post_submissions 누적, version+1, 반려사유 초기화) ③승인 게시물 교체 차단 ④uidx_deliverables_post_url 엣지(교체·신규 양쪽 EXISTS 사전 체크). receipt/review_image 분기 불변. 신규 INSERT 경로에 post_submissions 첫 이력 포함(163은 빈 배열이었음 — 미세 동작 개선)
- `CLAUDE.md`: 활동관리·deliverables 스키마 항목에 채널 검증·교체 동작 반영

### 초안 대비 변경 사항
- 추가된 것: 신규 INSERT 경로의 post_submissions 첫 이력 기록(163 누락분 보정)
- 빠진 것: 없음
- 달라진 것: 없음 (사양 그대로)

### 검증 메모
- reverb-reviewer GO (경고 2건 반영 완료: CLAUDE.md 동기화 + proxyApp 미탐지 주석)
- reverb-supabase-expert 작성·자체 검토 통과
- qa-tester 권장: light (관리자 대리 등록 post 채널 불일치·교체 + 인플 게시물 채널 불일치 toast)

### 묶음 1 운영 배포
hotfix rebuild 패턴(main 기준 재적용+재빌드)으로 운영 배포 완료 — 핫픽스 PR #502, main `67c2e14`, 운영 DB 마이그레이션 182 적용, globalreverb.com 반영 확인.

### 묶음 3 (URL 오타 자동 보정) — 구현 완료 (사용자 추가 요청 2026-06-16)
인플·관리자가 게시물 URL 등록 시 `ttp://`·스킴 누락 등 흔한 오타를 자동 보정. 사용자 결정: "명백한 오타만 보정 + 결과 표시".
- `dev/lib/shared.js`: `normalizeUrlInput(raw)` — 공백제거·`ttp(s)//`·`htp(s)//`·콜론 누락 → `https://`, 스킴 없으면 https 추가, 위험 스킴(javascript/data/vbscript/file/blob) → null 차단, 최종 new URL http/https 검증. 반환 `{url, changed}|null`
- `application.js` `addDraftUrl`(보정 시 `activity.urlFixed` toast)·`onPostUrlInputChange`(보정 주소로 채널 판별)
- `admin-deliverables.js` `submitAdminProxyDelivProxy`·`onAdminProxyPostUrlInput`
- i18n `activity.urlFixed`(ja/ko)

### 묶음 2 (잘못된 채널 잔존 행 정리) — 구현 완료
사용자 결정: ①삭제 권한 super_admin만 ②반려·검수중만 삭제(승인 보호) ③기존 audit 방식 감수.
- **경고 배지**: `renderDelivStatusCell`(목록 셀)·`renderDelivPanelContent`(검수 패널)에 캠페인 채널과 다른 post_channel 행 「채널 불일치」 빨강 배지(`postChannelMatchesCampaign` 재사용, `d.campaigns`/`allCampaigns` 폴백)
- **삭제 RPC**: 마이그레이션 183 `delete_mismatched_post_deliverable(uuid, text)` — super_admin·kind=post·승인 보호·**post_channel NULL 거부**·채널 불일치 서버 재검증·audit(admin_proxy_revoke, from_status는 draft면 NULL 처리—CHECK 보호)·DELETE. 162 `delete_legacy_review_image` 미러링
- **삭제 UI**: 검수 패널 super_admin 전용 「채널 불일치 게시물 삭제」 버튼 + 확인 모달(`deleteMismatchedPostRow`) + `deleteMismatchedPostDeliverable` 클라(storage.js) + refreshPane
- reviewer GO(경고 2건: CLAUDE.md 동기화 반영 / URL toast 하드코딩은 관리자 한국어 패턴 유지) + supabase-expert 마이그183 수정 2건 GO

### 묶음 2 빌더 보완 — 가려진 행 노출 (구현 완료)
운영 백필 결과 게시물 2건+ 신청이 20개(2건 13·3건 6·4건 1) 확인 → 가려진 잘못된 행 위험 실재. `renderDelivCombinedBody`에 `mismatchedHiddenPosts` 수집(`allDelivs`에서 `d !== result` 인 채널 불일치 post)해 검수 모달에 별도 「채널 불일치 게시물」 박스로 노출 + super_admin 삭제 버튼(승인 행은 "보호" 표시). result 자체 불일치는 패널에 이미 노출되므로 `d !== result`로 중복 제외. DB 무변경. reviewer GO.

### 운영 잘못된 채널 분포 (백필 조사 결과 2026-06-16)
총 13건(모두 instagram 캠페인): 반려 8(lips 4·other 3·x 1) + 검수중 3(x·tiktok·other) + **승인 2(x→instagram, 삭제 보호 — 잘못 승인 의심, 운영 수동 판단 필요)**. 반려·검수중 11건은 super_admin이 검수 화면 「채널 불일치 게시물 삭제」로 정리(가려진 행은 빌더 보완으로 노출됨).

### 운영 백필 조사 SQL (운영 배포 후 분포 파악용)
캠페인 channel에 없는 post_channel 행 건수·채널 분포·신청당 행 수 조사. 운영 SQL Editor에서 실행해 정리 규모 파악.
