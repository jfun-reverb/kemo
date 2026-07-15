# 오리엔시트 — 시딩 채널 개편 + 레버브 요구사항 필드 + 리뷰어 엣코스메 제거

**작성일:** 2026-07-15
**작성 세션:** 기획
**관련 화면:** 브랜드 셀프 오리엔시트 작성 폼(시딩·리뷰어 카드) + 관리자 오리엔시트 상세·발행

> 브랜드가 작성하는 오리엔시트를 아래 3묶음으로 개편한다. 상위 사양서 `docs/specs/2026-06-18-brand-self-orient-sheet.md` §15 형식 재설계의 후속.
> - **(시딩)** 「채널별 게시 가이드」를 ① 채널 목록을 인스타그램-피드/릴스로 세분화하고 ② 드롭다운 단일 선택 → 체크박스 다중 선택으로 바꾸고 ③ 소구 키워드를 통합 1칸으로 단순화
> - **(공통)** 폼 마지막에 「레버브 측 요구사항(선택)」 필드 추가
> - **(리뷰어)** 「엣코스메(@cosme) 리뷰 희망」 체크박스·URL 요소를 완전히 제거하고 Qoo10 리뷰만 남긴다 (2026-07-15 사용자 정정)

---

## 현재 상태 (2026-07-15 기준)

### 관련 코드·UI 진입점
- **작성 폼**: `dev/sales/orient.html` (sales 정적 배포, 빌드 복사본 `sales/orient.html`)
  - 채널 정의: `SEEDING_CHANNELS = ['instagram','x','tiktok','youtube','random']` (606줄), `CHANNEL_LABEL`(611줄), `SEEDING_CHANNELS_BY_GRADE`(607줄 — 나노/미들메가 동일)
  - 채널 드롭다운 렌더: `channelOptionsHtml(grade, selected)`(788줄) — `<option>` 단일 선택
  - 채널별 가이드 행: `cgRowHtml(grade, channel, guide)`(794줄) — **채널 드롭다운 1개 + 소구 키워드 텍스트영역 1개**가 한 행. 「채널 추가」 버튼으로 행 반복(`addCgRow`, `cg-list`)
  - 시딩 카드 렌더: `cardHtml`(925줄), 시딩 상세 블록은 1003~1022줄(`.only-seeding`) — 등급·채널별 게시 가이드·촬영가이드·해시태그·계정태그·(미들메가)필수내용·증정품·배송안내
  - 브랜드 공통 섹션(1회): 520~533줄 — 브랜드명·소개·SNS 공식 계정
  - **리뷰어 엣코스메 요소**(제거 대상): 체크박스+URL HTML 971~976줄(`f-atcosme-wish`/`f-atcosme-url`, `onAtcosmeToggle`), 형식전환 초기화 1092·1098~1101줄, 토글 함수 1108~1116줄, 수집 1454~1455줄(`sale.atcosme_wish`/`atcosme_url`), 제출 검증 1574~1575줄, 프리뷰 1657~1658줄. 관리자 상세 표시 `admin-orient.js` 783~784줄
  - 폼 수집: `collectCard`(1418줄) — `seeding.channels`(각 행 채널만 모음, 1460줄)와 `seeding.guides`(`[{channel, guide}]`, 1467줄) **양쪽 저장**, `collectData`(1475줄) — `{ brand, cards }`
  - 폼 로드: `applyData`(769줄~), 프리뷰: 1661~1665줄
  - 등급 변경 시 채널 선택지 재계산: `onCgGradeChange`(1140줄)
- **관리자 렌더·발행**: `dev/js/admin-orient.js`
  - 채널 라벨: `OS_CH_LABEL`(42줄, instagram/x/tiktok/youtube/qoo10/lips/atcosme), `osChLabel`(93줄)
  - 상세 시딩 렌더: `osCardDetail` 787~800줄 — `sd.guides` 순회하며 채널별 「채널 소구 — {채널}」 표시
  - 발행 채널 매핑: `osPrefillChannels(card)`(1054줄) — 시딩이면 `card.seeding.channels`를 **그대로** 반환 → `renderChannelCheckboxes('new', recruitType, ...)`(1129줄)로 캠페인 채널 체크박스에 매핑
  - 가이드 초안: `osBuildGuideDraft`(1086줄) — `sd.guides` 채널별 블록을 이어붙여 캠페인 가이드 초안 생성
- **데이터**: `orient_sheets.data jsonb` — 익명 함수 `save_orient_draft`/`submit_orient_sheet`가 **투명 전달**(스키마 무관 저장). 캠페인 채널 기준 데이터는 `lookup_values(kind='channel')` = instagram/x/qoo10/tiktok/youtube/lips/@cosme

### 이 제안과 충돌 가능성 있는 기존 동작
- **발행 채널 자동 매핑**: `osPrefillChannels`가 시딩 채널 코드를 캠페인 채널 체크박스에 직결. 새 코드 `instagram_feed`/`instagram_reels`는 캠페인 채널 체계에 없어 **변환(→`instagram`) 없이 넘기면 자동 선택 안 됨** → 발행 매핑에 변환 로직 필수.
- **기존 저장분**: 이미 저장된 draft/submitted의 `seeding.channels`엔 옛 코드(`instagram`, `random`)와 `seeding.guides`(채널별)가 들어 있음. 목록·구조를 바꿔도 **기존 데이터는 파괴하지 않고**(투명 저장) 로드·표시가 자연스러워야 함.
- **DB·마이그레이션**: 없음. `data` jsonb 투명 전달이라 익명 함수·RLS·트리거 무변경. 캠페인 채널 lookup_values도 무변경(피드/릴스는 오리엔시트 내부 코드일 뿐 캠페인 채널로는 `instagram` 매핑).

### 미해결 백로그·관련 작업
- 상위: `docs/specs/2026-06-18-brand-self-orient-sheet.md` §15 (형식 3종 카드형)
- 발행·자동채움: 메모리 `project_orient_sheet.md`, 관리자 여정 재설계 `project_admin_brand_journey_redesign.md`

---

## 의심·경우의 수 (규칙 B)

1. **(데이터·발행 충돌)** 피드/릴스를 별도 채널 코드로 저장하면 캠페인 발행 시 채널이 자동 선택 안 됨.
   → **해소**: 사용자 확정 = "인스타그램 채널 + 게시 형식"으로 취급. 발행 매핑에서 `instagram_feed`/`instagram_reels` → `instagram` 변환 + 중복 제거. 피드/릴스 구분은 가이드 초안에 텍스트로 남김.
2. **(기존 데이터 마이그레이션)** 옛 `instagram`·`random` 코드가 저장된 작성분.
   → **해소책**: 로드 시 옛 `instagram`을 신규 `instagram_feed`/`instagram_reels` 중 어느 것으로 볼지 알 수 없으므로 **자동 변환하지 않고**, 매핑 안 되는 옛 코드는 체크박스 미체크로 두되 **원본 data는 보존**(브랜드가 재선택). 관리자 상세는 옛 코드도 라벨 폴백 유지(`osChLabel`). `random`은 목록에서 빠지므로 미체크(데이터는 보존).
3. **(UX)** 체크박스 다중선택 ↔ 채널별 가이드 충돌.
   → **해소**: 사용자 확정 = 채널 체크박스 한 세트(다중) + 소구 키워드 **통합 1칸**. 채널 1개=가이드 1개 반복 구조 폐기 → 입력 단순화, 브랜드 인지 부하 감소.
4. **(UX·의도)** "브랜드 정보·제품 정보"는 이미 폼에 존재 → 신규는 「레버브 측 요구사항(선택)」 1개.
   → **해소**: 사용자 확정 = 폼 전체 마지막 1칸, **브랜드가 레버브 운영팀에 전하는 요청**, 선택 입력. 발행 자동채움 대상 아님(관리자 참고용).
5. **(추가 UX 점검)** 통합 소구 키워드로 바꾸면, 채널별로 다른 어필을 적고 싶던 브랜드는 한 칸에 "인스타는 …, X는 …"처럼 직접 구분해 써야 함. 플레이스홀더·힌트로 안내.

---

## 제안 / 설계

### 1) 시딩 채널 목록·코드

| 표시 라벨 | 코드(오리엔시트 내부) | 캠페인 발행 매핑 |
|---|---|---|
| 인스타그램-피드 | `instagram_feed` | `instagram` |
| 인스타그램-릴스 | `instagram_reels` | `instagram` |
| X (트위터) | `x` | `x` |
| 틱톡 | `tiktok` | `tiktok` |
| 유튜브 | `youtube` | `youtube` |

- `random`(랜덤·채널 무관) **제거**. 등급 구분 없이 나노·미들메가 동일 목록(현행 유지).
- 신규 상수(작성 폼): `SEEDING_CHANNELS = ['instagram_feed','instagram_reels','x','tiktok','youtube']`, `CHANNEL_LABEL`에 피드/릴스 라벨 추가(옛 `instagram`·`random` 라벨은 **하위호환용으로 남겨** 기존 데이터 표시 보존).
- 발행 매핑 상수(관리자): `instagram_feed`·`instagram_reels` → `instagram`.

### 2) 채널 선택 방식 — 드롭다운 → 체크박스 다중선택

- 「채널별 게시 가이드」 → **「게시 채널」 체크박스 그룹**(1개 이상 선택, 인스타그램-피드 + X 혼합 등)으로 교체.
- 기존 「채널 추가」 행 반복(`cgRowHtml`/`addCgRow`/`removeRepRow`) 폐기.
- 미선택(0개)은 허용하되, 소구 키워드만 있고 채널 0개면 프리뷰·수집에서 빈 채널로 처리(제출 자체는 막지 않음 — 현행 시딩은 채널 필수 아님).

### 3) 소구 키워드 — 통합 1칸

- 채널 체크박스 그룹 **아래에 소구 키워드(어필 포인트) 텍스트영역 1개**.
- 플레이스홀더: "각 채널에서 강조했으면 하는 소구 포인트를 적어 주세요. (채널별로 다르면 함께 적어 주세요.)"

### 4) 레버브 측 요구사항(선택)

- **폼 전체 마지막**(모든 카드 뒤, 「미리보기·제출」 앞)에 독립 섹션 1개.
- 라벨: **「레버브 측에 전달할 요청·요구사항 (선택)」**, 힌트: "레버브 운영팀에 요청하고 싶은 사항이 있으면 자유롭게 적어 주세요."
- 선택 입력(빈칸 허용). 일반 textarea(리치 텍스트 아님).

### 5) data 스키마 (jsonb — 마이그레이션 없음)

```
{
  brand: { name, intro, official_accounts },
  reverb_request: "…",              // 신규(top-level, 선택) — 폼 마지막 요청 필드
  cards: [
    {
      form_type: 'seeding',
      …,
      seeding: {
        grade,
        channels: ['instagram_feed','x', …],   // 다중, 신규 코드
        appeal: "통합 소구 키워드",              // 신규 단일 필드(기존 채널별 guide 통합)
        hashtags, account_tags, shooting_guide, required_content, gift, shipping_note
        // guides 배열: 신규 저장 시 미생성. 기존 저장분 로드 시 첫 guide.guide를 appeal로 흡수
      }
    }
  ]
}
```

- **기존 데이터 로드 규칙**: `seeding.appeal`이 없고 옛 `seeding.guides`가 있으면, 로드 시 `guides[].guide`를 개행으로 합쳐 `appeal` 초기값으로 채움(브랜드가 확인·수정). 옛 `channels`의 매핑 안 되는 코드(`instagram`,`random`)는 미체크로 두되 원본은 저장 유지.

### 6) 관리자 상세·발행 반영 (`admin-orient.js`)

- `OS_CH_LABEL`에 `instagram_feed`(인스타그램-피드)·`instagram_reels`(인스타그램-릴스) 추가.
- `osCardDetail` 시딩 렌더(787~800줄): 채널별 「채널 소구」 순회 → **「게시 채널」(라벨 목록) + 「소구 키워드」(통합 1칸)** 로 변경. `sd.appeal` 우선, 없으면 옛 `sd.guides` 폴백 표시.
- 카드 아래(또는 상세 상단 공통)에 **「레버브 측 요청」** 표시(값 있을 때만).
- `osPrefillChannels`(1054줄): `channels`를 캠페인 채널로 **변환**(`instagram_feed`/`instagram_reels`→`instagram`, `x`/`tiktok`/`youtube` 그대로, 미매칭 제외) + 중복 제거 후 반환.
- `osBuildGuideDraft`(1086줄): 채널별 블록 → **「[게시 채널] 인스타그램-피드, X」 + 「[소구 키워드] {appeal}」** 블록으로. 피드/릴스가 캠페인 콘텐츠 종류 판단에 참고되도록 채널 라벨을 초안에 남김.

### 8) 리뷰어 — 엣코스메 요소 완전 제거 (2026-07-15 사용자 정정)

- 리뷰어 카드에서 **「엣코스메(@cosme) 리뷰 희망」 체크박스와 엣코스메 제품 링크 URL 입력을 전부 제거**. Qoo10 판매(판매처 Qoo10 readonly + 판매 URL* + 상시가*)만 남긴다.
- ⚠️ **경로 단절**: 이 체크박스가 브랜드가 오리엔시트에서 엣코스메 리뷰를 요청하는 **유일한 진입점**. 제거하면 그 경로가 완전히 사라진다(대체 경로 없음 — 사용자 명시 요청).
- 제거 대상(작성 폼 `dev/sales/orient.html`): 971~976줄 HTML, 1092줄 필드 목록의 `.f-atcosme-url`, 1098~1101줄 초기화, 1108~1116줄 `onAtcosmeToggle`, 1454~1455줄 수집, 1574~1575줄 제출 검증, 1657~1658줄 프리뷰.
- 제거 대상(관리자 `dev/js/admin-orient.js`): 783~784줄 「엣코스메 희망/링크」 표시.
- **발행 매핑(`osPrefillChannels` 1058줄 map의 `'@cosme':'atcosme'`)은 그대로 둔다** — 리뷰어 판매처는 항상 `Qoo10`이라 `atcosme`가 나올 일이 없고, 다른 경로 영향도 없음(무해).
- **기존 데이터 호환**: 이미 저장된 리뷰어 카드에 `sale.atcosme_wish=true`/`atcosme_url`이 있어도 UI·상세에서 표시하지 않는다(무시). 원본 `data`는 파괴하지 않고 보존(투명 저장), 발행 시에도 무시.

### 7) 영향 없는 것 (명시)

- DB·마이그레이션·익명 함수(`save_orient_draft`/`submit_orient_sheet`/`get_orient_sheet`)·RLS·트리거 **무변경**.
- 캠페인 채널 기준 데이터(`lookup_values`) **무변경**.
- 가구매·리뷰어 형식 카드 **무변경**(시딩 카드만 대상).
- `orient-images` 업로드·자동저장·낙관적 락 **무변경**.

---

## PR 분할

단일 PR 권장(순수 프론트 + 관리자 렌더, DB 무변경). 규모가 작아 나눌 이득 없음.
- 작성 폼(`dev/sales/orient.html`) 채널 목록·체크박스·통합 소구·레버브 요청 + 로드 하위호환
- 관리자(`dev/js/admin-orient.js`) 라벨·상세 렌더·발행 매핑·가이드 초안
- 빌드(`bash dev/build.sh`)로 `sales/orient.html` 복사본 갱신 확인

---

## 사용자 확인 완료 (2026-07-15)

1. 피드/릴스 = **인스타그램 채널 + 게시 형식** (발행 시 `instagram` 매핑)
2. 채널 목록 = **인스타그램-피드 / 인스타그램-릴스 / X / 틱톡 / 유튜브** (랜덤 제거)
3. 채널 체크박스 다중선택 + 소구 키워드 **통합 1칸**
4. 레버브 측 요구사항 = **폼 마지막 1칸, 브랜드→레버브 요청, 선택 입력**
5. (리뷰어 정정) 「Qoo10 기본 + 엣코스메 추가」로 물었으나 사용자가 **「엣코스메 요소도 빼고 Qoo10 리뷰만」**으로 정정 → §8대로 엣코스메 UI 완전 제거

---

## 구현 결과 (개발 세션이 채울 것)

**구현일:**
**관련 커밋:**

### 초안 대비 변경 사항
-

### 구현 중 기술 결정 사항
-
