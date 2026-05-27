# 캠페인 상태 라벨 명확화 (모집마감 / 종료 / 노출종료) — 사양서

**작성일:** 2026-05-27
**작성 세션:** 기획/설계
**배경:** 관리자 캠페인 관리에서 `closed`의 라벨 "종료"가 **모집만 마감된 건지, 캠페인이 완전히 끝난 건지** 헷갈림. 실제 `closed`는 모집만 마감이고 승인자는 결과물 제출 중(인플 화면에 募集締切로 계속 노출). 사용자 지적.

## 1. 문제 — '끝' 시점 3개가 라벨 2개에 뭉쳐 있음

| 시점 | 의미 | 현재 status | 현재 라벨 |
|---|---|---|---|
| ① 모집 마감(`deadline` 경과) | 응모 마감, **승인자는 결과물 제출 중**, 노출 유지 | `closed` (자동) | 종료 |
| ② **결과물 제출 마감(`submission_end` 경과)** | **캠페인 활동 완전히 끝남**, 아직 노출 | **`closed`** (자동 전이 없음, ①과 동일) | 종료 |
| ③ 운영자 노출 내림 | 인플 화면에서 사라짐(비노출) | `expired` (수동) | 노출마감 |

→ ①과 ②가 같은 `closed`("종료")라, "종료"가 모집 마감인지 캠페인 완전 종료인지 구분 안 됨.

## 2. 결정 (사용자 2026-05-27) — 라벨 3종 자동 구분

**상태값(`status`)은 그대로 두고, 화면 라벨만 `submission_end` 경과 여부로 자동 분기.** DB 변경·신규 상태·자동 전이 트리거 **없음**(표시 로직만).

| 조건 | 라벨(한국어) | 색 | 노출 |
|---|---|---|---|
| `draft` | 준비 | 회색·점선 | 비노출 |
| `scheduled` | 모집예정 | 파랑 | 노출 |
| `active` | 모집중 | 초록 | 노출 |
| `closed` AND `submission_end` 미경과(또는 없음) | **모집마감** | 핑크 | 노출(진행 중) |
| `closed` AND `submission_end` 경과 | **종료** | 차분한 톤(제안: 진보라/남보라 — 핑크와 구분) | 노출(활동 끝) |
| `expired` | **노출종료** | 회색·점선 | 비노출 |

- 핵심: `closed` 한 상태가 `submission_end` 경과 여부로 「모집마감」 ↔ 「종료」 두 라벨로 갈림.
- 「모집」·「노출」·「마감」·「종료」 단어가 모두 달라 혼동 최소.

## 3. 구현 — 라벨 분기 헬퍼

`dev/lib/shared.js`에 공용 헬퍼 신설(관리자·인플 공용):
```
// status + submission_end → 표시 라벨 키
function campaignStatusLabelKey(camp) {
  const s = camp.status;
  if (s === 'closed') {
    const sub = camp.submission_end ? Date.parse(camp.submission_end) : null;
    if (sub && Date.now() > sub) return 'closed_done';   // 종료
    return 'closed_recruit';                              // 모집마감
  }
  return s; // draft/scheduled/active/expired
}
```
- 라벨 매핑: `{draft:'준비', scheduled:'모집예정', active:'모집중', closed_recruit:'모집마감', closed_done:'종료', expired:'노출종료'}`
- 색/배지 클래스도 `closed_recruit`(핑크) / `closed_done`(신규 톤) / `expired`(회색) 분리

## 4. 영향 지점 (관리자 — `dev/js/admin.js`)
- line 298 `statusLabel` 객체 → 헬퍼 호출로 교체
- line 238~242 상태 요약/필터 칩 라벨
- line 302 `statusBadgeClass` → `closed_done` 클래스 추가(CSS `dev/css/admin.css`)
- line 280 `statusOrder` 정렬 — closed 내 모집마감/종료 정렬 순서 결정(종료를 closed 뒤에 둘지)
- line 308 배지 렌더
- `dev/js/admin-core.js` line 264 상태 필터 드롭다운

### 상태 필터 처리 (주의)
- 필터·토글·정렬은 **`status`(closed/expired) 기준**이라 closed는 DB상 하나. 필터 드롭다운에서 closed 항목 라벨을 어떻게 표기할지 결정 필요:
  - **추천**: 필터는 「모집마감/종료」 한 항목(`closed`)으로 묶되 라벨을 "모집마감·종료"로 표기. 목록 배지만 동적 구분.
  - 또는 필터에서도 submission_end 기준으로 클라이언트 분리(복잡 — 비추천).

## 5. 인플루언서 화면 (일본어) — 별도 검토
- 인플 응모이력/캠페인 카드 일본어 라벨(`募集締切` 등)도 같은 구분이 필요한지 검토. 단 인플은 자기 결과물 제출 상태(활동관리)로 보므로 우선순위 낮음. **1차는 관리자 화면만**, 인플 일본어 라벨은 현행 유지 후 별도 판단.

## 6. PR / 주의
- 단일 PR로 충분(라벨·색 분기). DB·상태 전이 변경 없음.
- ⚠️ **`dev/js/admin.js` 핫스팟**(캠페인 목록·폼 잔류 파일) 수정 → worktree 병렬 금지, 시퀀셜 진행.
- `reverb-reviewer` 호출. 캠페인 목록 UI 변경이라 `reverb-qa-tester` light 권장.
- 빌드 후 관리자 목록에서 closed 캠페인 2종(제출 마감 전/후) 배지 확인.

## 7. 약관/개인정보 영향
- 표시 라벨 변경뿐 → 영향 없음.

---

## 구현 결과

**구현일:** 2026-05-27
**관련 커밋:** PR #(이번 PR) — feature/campaign-status-label

### 구현 범위
- `dev/lib/shared.js`: `campaignStatusLabelKey(camp)` 헬퍼(closed → submission_end 경과 시 `closed_done` 아니면 `closed_recruit`) + `CAMPAIGN_STATUS_LABEL`·`CAMPAIGN_STATUS_BADGE_CLASS` 매핑(공용)
- `dev/js/admin.js`: 목록 배지 `statusBadge(camp)` 헬퍼 사용(동적 구분), 요약/필터칩·stLabels·빠른토글 라벨 변경
- `dev/js/admin-core.js`: 캠페인 상태 필터 드롭다운 라벨
- `dev/css/components.css`: `.badge-done`(남보라 #5E35B1, 핑크와 구분) 신규

### 초안 대비 변경 사항
- **추가**: `expired` 라벨 "노출마감"→**"노출종료"** 통일(사양서 §2 — 모집마감/종료/노출종료 단어 구분).
- **방법**: 필터·요약·빠른토글은 §4-1 추천안대로 `status='closed'` 한 항목을 **"모집마감·종료"** 묶음 표기(DB status 하나라 분리 안 함). **목록 배지만** `campaignStatusLabelKey`로 동적 구분.
- **정렬(§4 line 280)**: `statusOrder`는 status 기준 그대로(closed 묶음). 모집마감/종료 세분 정렬은 미적용(closed 내 순서 무관).
- **빠짐(follow-up)**: 노출 토글 영역(`dev/js/admin.js` `_renderCampVisibilityToggle`, 구 line 688·3520·3522)의 `closed:'종료'`는 **status 문자열만 받고 camp 객체(submission_end)가 없어** 동적 구분 구조상 불가 → 현행 유지. 노출 토글 옆 상태 텍스트에서는 「종료」가 그대로 보임. 필요 시 호출부에서 camp 전달하도록 별도 리팩토링.
- **인플루언서 화면(§5)**: 1차 관리자만, 인플 일본어 라벨(`募集締切`)은 현행 유지(미착수).

### 구현 중 기술 결정
- DB·신규 status·전이 트리거 없음. 화면 라벨·배지 클래스만 분기.
- `campaignStatusLabelKey`는 `submission_end` 없으면(null) `closed_recruit`(모집마감) 폴백 — 제출 마감일 미설정 캠페인은 모집마감으로 표시.
