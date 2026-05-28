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
**관련 커밋:** PR #317 (A안 — 라벨 분기, 선행) → 그 위 **B안(실제 상태 분리) 재설계** feature/campaign-status-split

> ⚠️ **A안 → B안 재설계**: PR #317로 "라벨만 분기"(A안)를 먼저 구현했으나, 사용자가 "종료가 진짜 close이고 모집마감이 별도 상태로 추가되는 게 맞다"며 **실제 DB 상태 분리(B안)**를 선택. reverb-planner 비교 후 **방식 ㄱ(closed=모집마감 식별자 유지 + 신규 `ended`=종료)** 채택(기존 closed 참조 영향 최소).

### 구현 범위 (B안)
- **마이그레이션 156**(`156_campaign_status_ended.sql`): campaigns.status CHECK 에 `ended` 추가 + 백필(closed + submission_end 경과 → ended) + 락 트리거(075·108) 재정의(closed/ended/expired 3종 보호컬럼 변경 차단 — 108이 expired 빠뜨린 회귀도 정상화)
- **자동 전이**(`dev/lib/storage.js`): `autoEndCampaigns`(closed + submission_end 경과 → ended, fetchCampaigns/fetchCampaignsForAdminList 호출) + `computeCampaignStatus` ended 분기 + 노출토글 select submission_end
- **관리자**(`dev/lib/shared.js`·`admin.js`·`admin-core.js`): `campaignStatusLabelKey` ended→종료 + closed 안전망, 요약/필터칩·stLabels·빠른토글·필터·statusOrder·편집폼 락(`isLocked`/origStatus)·노출토글 labels 모두 **closed=모집마감/ended=종료 분리**. `.badge-done`(남보라) 
- **인플루언서**(`dev/js/campaign.js`·`application.js`·i18n): `visibleCamps` ended 노출, 카드 `isClosedLike`(closed+ended 마감동작) + ended 오버레이(終了), 응모버튼 ended 비활성(endedBtn), 상태 필터 탭 「終了」 추가, i18n `status.campaign.ended`/`detail.endedBtn`/`detail.endedOverlay`/`campaigns.statusEnded`(終了/종료)

### 초안(A안) 대비 변경 사항
- **A안 폐기**: "라벨만 분기"(submission_end로 화면만 갈음) → **실제 상태 ended 분리**. `campaignStatusLabelKey`는 ended 직접 반환 + closed의 submission_end 경과분은 자동 전이 전 **안전망**으로 종료 표시.
- **필터·요약·빠른토글**: A안 "모집마감·종료 묶음" → B안 **모집마감/종료 분리**(DB 상태가 둘이라).
- **인플 화면**: A안 "현행 유지" → B안 **종료 별도 표시**(終了 오버레이·탭·응모차단). 사용자 결정.
- **expired**: "노출마감"→"노출종료" 통일은 A안에서 이어받음.

### 구현 중 기술 결정
- 신규 트리거 대신 클라이언트 `autoEndCampaigns`(autoClose와 동일 방식 — submission_end는 표시·정렬용이라 실시간성 불필요).
- 백필 KST 판정(`submission_end < KST today`)과 `autoEndCampaigns`(submission_end 23:59:59 < now 자정) 경계 일치.
- closed→ended UPDATE 는 status 만 변경(보호컬럼 미변경)이라 락 트리거 통과.
- 운영 미배포(FAQ·메시지·이 작업 모두 보류) — 개발 DB 156 적용만, 운영은 본체 출시 시.
