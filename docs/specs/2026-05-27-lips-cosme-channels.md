# LIPS·@cosme 모집 채널 추가 — 전체 구현 사양서

**작성일:** 2026-05-27 (초안) / **재작성:** 2026-05-28 (Qoo10 패턴 정정)
**작성 세션:** 기획/설계
**배경:** 챌린저스 벤치마크(`docs/research/2026-05-27-challengers-benchmark.md`) 권고 H. 일본 뷰티 핵심 리뷰 플랫폼 LIPS(lipscosme.com)·@cosme(cosme.net)를 인플루언서 캠페인 채널로 추가.

---

## 0. 정정 이력 (2026-05-28)

초안은 LIPS·@cosme를 SNS 채널(인플 핸들·팔로워 수집)로 잘못 가정. 사용자 정정으로 **둘 다 Qoo10 패턴(인플 계정 미수집, 리뷰어 캠페인 전용 마켓 채널)**으로 통일.

| 영역 | 초안 | 정정 후 |
|---|---|---|
| 채널 성격 | LIPS는 SNS 패턴(자격검증) / @cosme 자격 면제 | **둘 다 Qoo10 패턴, 인플 계정 미수집** |
| `influencers` 컬럼 추가 | 4개 추가(lips/lips_followers/cosme/cosme_followers) | **추가 없음** |
| `CHANNEL_META` 단일화 | 신설 | **불필요** (인플 식별 안 함) |
| 마이페이지 SNS 폼 | LIPS·@cosme 입력란 2세트 | **수정 없음** |
| 엑셀 SNS 컬럼 | 4→6 확장 | **수정 없음** |
| 다이제스트 메일 SNS 배열 | 확장 | **수정 없음** |
| 약관 | 수집 항목 추가(중대 변경 낮음) | **개정 불필요** |
| PR 분할 | 4개 | **단일 PR로 축소** |

---

## 1. 확정 사항 (사용자 결정 2026-05-28)

| 항목 | 결정 |
|---|---|
| 채널 성격 | **마켓·리뷰 플랫폼 채널** — Qoo10과 동일 패턴 |
| 인플 식별 수집 | **없음** (계정·팔로워 모두 받지 않음) |
| 적용 모집 유형 | **리뷰어(monitor) 전용** — `lookup_values.recruit_types=['monitor']` |
| 자격 검증 | 리뷰어 자체가 팔로워 체크 스킵 → 별도 면제 처리 불필요 |
| URL 자동 판별 | **불필요** — 결과물은 「리뷰 이미지(스크린샷)」로 받음. 도메인 인식 무용 |
| 마이그레이션 번호 | 작업 시점 `ls supabase/migrations/` 재확인 (본 사양 작성 시 156이 최신) |

## 2. 핵심 설계 (Qoo10 패턴 미러)

Qoo10이 현재 동작하는 방식 그대로:
- `lookup_values` channel 1행만 등록 (인플 테이블 컬럼 없음)
- 캠페인 등록 폼의 채널 옵션에 노출
- 인플루언서 마이페이지·SNS 입력 폼에는 **추가하지 않음**
- 인플 목록·엑셀의 SNS 컬럼 영역 손대지 않음
- 결과물(리뷰 이미지)은 「리뷰어 캠페인 결과물 모델 확장」 사양에서 채널별 카드로 처리 — 본 사양은 채널 등록만 담당

## 3. 데이터 모델 (마이그레이션 1개)

**lookup_values 2건 추가**:
```sql
INSERT INTO lookup_values (kind, code, name_ko, name_ja, sort_order, recruit_types) VALUES
  ('channel', 'lips',  'LIPS',  'LIPS',  60, ARRAY['monitor']),
  ('channel', 'cosme', '@cosme','@cosme', 70, ARRAY['monitor'])
ON CONFLICT (kind, code) DO NOTHING;
```

`influencers` 테이블 컬럼 추가 없음. 행 단위 보안 정책 변경 없음. 기존 1,398행 영향 없음.

## 4. URL 자동 판별 (결과물 리뷰 URL 한정)

`dev/js/application.js` `detectChannelFromUrl()`에 도메인 2개 추가:
- `host.includes('lipscosme.com')` → `'lips'`
- `host.endsWith('cosme.net')` → `'cosme'` (`my.cosme.net` 포함)

추적 파라미터(`?_gl=`, `_ga=`) 제거는 결과물 저장 시점에 처리(혹은 표시 시점에 trim).

(인플 프로필 URL 추출·핸들 추출 로직은 불필요 — 인플 식별 안 함.)

## 5. 영향 파일

- `dev/js/application.js` — `detectChannelFromUrl()` 도메인 2개 + `CHANNEL_LABELS` 라벨 2개
- `dev/index.html` — 결과물 제출 수동 채널 드롭다운에 LIPS·@cosme 옵션 추가
- `dev/lib/i18n/{ja,ko}.js` — LIPS·@cosme 라벨
- `supabase/migrations/[작업 시점 확인]_lips_cosme_channels.sql`
- `docs/FEATURE_SPEC.md` + `CLAUDE.md` — 채널 추가 한 줄

**수정 불필요(초안과 달리):**
- 인플 마이페이지 SNS 폼
- 인플 목록 컬럼·정렬·검색
- 관리자 엑셀 SNS 컬럼
- 다이제스트 메일 SNS 표시
- `dev/lib/shared.js` `CHANNEL_META` 객체

## 6. PR 분할

**단일 PR로 충분.** 마이그레이션 1개 + 코드 변경 매우 작음.

게이트:
- reverb-supabase-expert (마이그레이션)
- reverb-reviewer (commit 직전)
- reverb-qa-tester Light (관리자 캠페인 등록 채널 옵션 + 결과물 URL 판별 회귀)

## 7. 검증

- 캠페인 등록 폼 채널 옵션에 「LIPS」·「@cosme」 노출 (recruit_type=monitor 선택 시)
- 채널 = `'qoo10,cosme'`인 monitor 캠페인 저장 정상
- 결과물 제출에서 LIPS·@cosme URL을 입력 시 자동 채널 인식
- 인플 마이페이지·관리자 인플 목록·엑셀에서 **회귀 없음** (SNS 영역 미변경)
- 기존 1,398행 영향 없음

## 8. 약관·개인정보 영향

**없음.** 신규 수집 항목 없음. 약관·개인정보처리방침 개정 불필요.

## 9. 의존·후속

본 사양 완료 후 → 「리뷰어 캠페인 결과물 모델 확장」(`docs/specs/2026-05-28-multichannel-deliverable-split.md`) 착수 가능.
이유: 「Qoo10 & @cosme」 같은 캠페인을 만들려면 @cosme·LIPS 채널이 lookup에 먼저 존재해야 함.

---

## 구현 결과

**구현일:** 2026-05-28
**관련 커밋:** feature/lips-cosme-channels (PR 머지 후 갱신)
**브랜치:** feature/lips-cosme-channels (메인 폴더 분기)

### 초안 대비 변경 사항
- 변경 없음 — 사양서 §0 정정판(2026-05-28) 그대로 구현
- 인플 마이페이지 SNS 폼·관리자 인플 목록·엑셀 SNS 컬럼·다이제스트 메일 SNS 표시 전부 미수정 (Qoo10 패턴)

### 구현 중 기술 결정 사항
- **마이그레이션 번호 157 점유** — 다른 세션 동시 작성 없음 확인(2026-05-28 운영 일괄 출시 직후)
- **i18n 라벨 추가 생략** — 현행 `dev/lib/i18n/{ja,ko}.js`의 `channelLabel` 객체는 `other`만 있고 그 외 채널은 `CHANNEL_LABELS` (application.js) 객체에서 직접 처리. 사양 §5의 "i18n 라벨" 항목은 코드측 `CHANNEL_LABELS`에 lips/cosme 추가로 충족
- **cosme 도메인 매칭 강화** — 사양서 `host.endsWith('cosme.net')` 권고를 `host === 'cosme.net' || host.endsWith('.cosme.net')`로 확장. `cosme.net` 정확 매칭 + 서브도메인(my.cosme.net 등) 양쪽 커버
- **인플 마이페이지 `profilePrimarySns` 셀렉트 미수정** (사양 §5 명시 — SNS 계정 미수집)
- **PostgREST 자동 동기** — 캠페인 등록 폼의 채널 체크박스는 `lookup_values(kind='channel', recruit_types && ARRAY['monitor'])`을 동적 쿼리하므로 코드 변경 없이 LIPS·@cosme가 자동 노출됨

### 변경 파일
- `supabase/migrations/157_lips_cosme_channels.sql` (신규)
- `dev/js/application.js` (`detectChannelFromUrl` 도메인 2개 + `CHANNEL_LABELS` 라벨 2개)
- `dev/index.html` (`#postChannelManual` 셀렉트 옵션 2개)
- 빌드 산출물 `index.html` · `admin/index.html`
