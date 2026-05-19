# HANDOFF — 응모 취소 + 관리자 메일 수신 분리

> **작성일**: 2026-05-12
> **작성 세션**: 기획/설계 (메인 폴더, 코드 미수정)
> **인수인계 대상**: 개발1 (완료)
> **범위**: 사양서 2종(이미 확정 완료) + 메일 1차안 + 작업 순서·충돌 점검
>
> ✅ **모든 작업 완료 (2026-05-14)** — 마이그레이션 103~116 운영 DB 전부 적용. `2026-05-12-PROD-DEPLOY-checklist.md` 참조

---

## 1. 한눈에 보기

| 일감 | 사양서 | 상태 |
|---|---|---|
| **A. 응모 취소 (인플루언서 본인)** | `docs/specs/2026-05-11-application-cancel.md` | 사양 확정. PR 5개 분할(A·B·C·D·E) |
| **B. 관리자 메일 수신 설정 분리** | `docs/specs/2026-05-11-admin-email-subscriptions.md` | 사양 확정. 단일 PR |
| **C. NG 사항 번들화** (후속) | `docs/specs/2026-05-12-ng-sets.md` | 사양 확정 (2026-05-12). PR 6개 분할(A·B·C·D·E·F). **A·B 머지 완료 후 시작** |
| **D. 브랜드 서베이 「모집비」 행별 입력** | `docs/specs/2026-05-12-brand-app-recruit-fee.md` | 사양 확정 (2026-05-12). 단일 PR. **개발1의 「관리자 브랜드 서베이 신규 등록 모달」 작업과 같은 PR에 합류** |
| **E. 브랜드 서베이 신청 목록 상태별 탭 UI** | `docs/specs/2026-05-12-brand-app-status-tabs.md` | 사양 확정 (2026-05-12). 단일 PR. **같은 페인 영역이라 D PR과 합류 권장** |
| **F. 참여방법·주의사항·NG 미니 에디터 이미지 첨부 강화** | `docs/specs/2026-05-12-rich-editor-image-upload.md` | 사양 확정 (2026-05-12). 단일 PR. **C(NG 번들화) PR-B에 합치거나 본 사양을 먼저 머지 후 C가 자동 적용** |

**핵심 제약**:
- **B → A** 순서로 머지. B가 먼저여야 A의 PR-D(일일 요약 메일) 수신자 로직이 올바른 함수(`get_subscribed_admin_emails`)를 참조한다.
- **A·B 모두 완료 후 C 시작**. C는 마이그레이션 번호·`dev/js/admin.js`·`dev/admin/index.html`에서 A·B와 영역이 다르지만 시퀀셜 권장 (사양서 §11 충돌 점검 참조).

---

## 2. 머지 순서 (필수)

```
PR #152 ✅ + PR #153 ✅ (둘 다 dev 머지 완료, 2026-05-11)
    ↓
B. admin-email-subs PR ← 즉시 진행 가능
    ↓
A-PR-A (DB 마이그레이션 + RPC + storage.js)
    ↓
A-PR-B (인플루언서 UI) + A-PR-C (관리자 UI)  ← 병렬 가능
    ↓
A-PR-D (알림 — admin_notices 즉시 + 메일 일일 요약)
    ↓
A-PR-E (약관·정책 — TERMS §N, PRIVACY 마이너)
    ↓
C-PR-A (NG ng_sets 마이그레이션 3개 + storage.js 함수 7종)
    ↓
C-PR-B (캠페인 폼 + 인플루언서 상세 + 미리보기) + C-PR-C (기준 데이터 NG 탭 번들 CRUD)  ← 병렬 가능
    ↓
C-PR-D (변경 이력 모달 NG 확장)
    ↓
C-PR-E (약관 점검 + 운영 공지)
    ↓ (1주 운영 후)
C-PR-F (선택, legacy campaigns.ng 컬럼 DROP)
```

---

## 3. ⚠️ 현재 작업 흔적 점검 (개발 세션 진입 시 첫 단계)

기획 세션이 메인 폴더 `git status` 확인했을 때 **이번 세션이 안 만진 파일**이 modified/untracked로 잡혀 있음. 다른 개발 세션이 **이미 일부 작업을 진행 중일** 가능성:

```
?? supabase/migrations/103_admin_email_subscriptions.sql  (또는 추적 중)
?? supabase/migrations/104_application_cancellation.sql  (또는 추적 중)
 M dev/lib/i18n/ja.js
 M supabase/seed/test_influencers_staging.sql
```

**개발 세션 진입 직후 점검 의무**:
1. `git log --oneline -10` 으로 추가 커밋 여부 확인
2. `git diff supabase/migrations/103_admin_email_subscriptions.sql` 내용이 본 사양서 §2와 일치하는지 검증
3. `git diff supabase/migrations/104_application_cancellation.sql` 내용이 응모 취소 사양서 §2와 일치하는지 검증
4. 일치하지 않으면 사용자에게 보고 — 「이전 세션 작업물입니까, 다른 개발 세션이 동시 진행 중입니까」 확인 후 진행
5. `dev/lib/i18n/ja.js`·`test_influencers_staging.sql` 변경 출처도 사용자에게 확인

**중복 작업 방지**: 본 HANDOFF의 PR-A·PR-D 마이그레이션을 새로 만들기 전에 위 파일들의 내용을 우선 검토. 기존 파일이 사양과 일치하면 그대로 활용, 어긋나면 사용자와 의논 후 갱신.

---

## 4. B (admin-email-subs) — 즉시 진행 가능

### 4-1. 영역
- 마이그레이션 1개 (`supabase/migrations/103_admin_email_subscriptions.sql` — 이미 존재 가능. 사양서 §2와 대조 후 결정)
- `dev/lib/storage.js` — 함수 3종 추가 (`fetchAdminEmailSubscriptions` / `fetchAdminEmailKinds` / `saveAdminEmailSubscriptions`)
- `dev/js/admin.js` — 관리자 계정 페인(약 line 3990 부근) 행 렌더 + 「메일받기」 칩 + 「설정」 버튼
- `dev/admin/app.js` 또는 `dev/js/admin.js` — 「메일 받기 설정」 모달 HTML + open/save
- `dev/index.html` — admin 모달 영역 마크업
- `supabase/functions/notify-brand-application/index.ts` — 수신자 쿼리를 `get_subscribed_admin_emails('brand_notify')`로 교체
- 기존 `toggleAdminBrandNotify` / `admins.receive_brand_notify` 직접 토글 코드 제거 (컬럼 자체는 DROP 안 함, deprecated 코멘트만)

### 4-2. 작업 순서
1. 마이그레이션 검증·실행 (개발 서버 Supabase SQL Editor)
2. 데이터 이관 확인 — 기존 `receive_brand_notify=true` 관리자가 `admin_email_subscriptions(mail_kind='brand_notify')` 로 자동 이관됐는지 SELECT
3. `dev/lib/storage.js` 함수 3종 추가
4. 「메일 받기 설정」 모달 + 관리자 계정 페인 칩 렌더
5. 기존 토글 코드 제거
6. `notify-brand-application` Edge Function 수신자 쿼리 교체 + 양 서버 배포
7. `cd dev && bash build.sh` → 빌드
8. **reverb-reviewer 호출** (commit 직전 필수)
9. dev 브랜치 커밋 + 푸시 → 개발서버 자동 배포
10. **reverb-qa-tester light** — 관리자 계정 페인 + 모달 + 「메일받기」 칩 노출 시나리오
11. 운영 배포 여부 사용자에게 `AskUserQuestion`

### 4-3. 사용자에게 확인할 것 (사용자 명시 지시 시)
- 운영 배포 시 운영 Supabase 마이그레이션 실행 + `notify-brand-application` Edge Function 운영 재배포 필요

---

## 5. A-PR-A (응모 취소 DB + RPC) — B 머지 후

### 5-1. 영역
- 마이그레이션 1개 (`supabase/migrations/104_application_cancellation.sql` — 이미 존재 가능. 사양서 §2와 대조 후 결정)
- `dev/lib/storage.js` — `cancelApplication(applicationId, {reasonCode, reasonNote, acknowledged})` / `fetchCancelReasons()` 추가

### 5-2. 핵심 검증 포인트
- `applications` 컬럼 5종 (`cancelled_at`, `cancel_reason`, `cancel_reason_code`, `cancel_phase`, `previous_status`)
- partial unique index `applications_user_camp_active_uidx WHERE status != 'cancelled'` 정확히 적용 — 재신청 허용
- `cancel_application` RPC SECURITY DEFINER + `SET search_path = ''` + 본인 검증·결과물 승인 차단·단계 도출·동의 필수 분기
- `lookup_values` 시드 6종 (cancel_reason) + 1종 (violation_reason: `cancel_after_purchase_start`)
- 058 트리거(`applied_count`)가 cancelled 제외하는지 슬롯 카운트 검증

---

## 6. A-PR-B + A-PR-C (UI) — 병렬 가능

### 6-1. PR-B 영역 (인플루언서 UI)
- `dev/js/mypage.js` — 응모이력 ⋮ 메뉴 / 취소 모달 단순형·사유 입력형 / 「取消」 탭 / 사유 확인 모달
- `dev/js/ui.js` — `getStatusBadge` 에 cancelled 상태 추가
- `dev/index.html` — 모달 HTML
- `dev/css/mypage.css` — 모달 스타일
- `dev/lib/i18n/ja.js` + `dev/lib/i18n/ko.js` — 키 30여 개 추가 (사양서 §4-6 표)
- `dev/js/campaign.js` (또는 application.js) — 캠페인 상세 「再応募する」 라벨·안내 박스 + 활동관리 진입 차단 분기 + 본인 취소 알림 생성

### 6-2. PR-C 영역 (관리자 UI)
- `dev/js/admin.js` — 신청 관리 페인 상태 필터 「취소」 항목 + 「취소」 배지·cancel_phase 라벨 + 검색 확장 + URL 쿼리 자동 필터 (§5-1-a)
- `dev/js/admin.js` — 인플루언서 상세 모달 「취소 사유」 카드 + 「위반 등록」 버튼 (기존 모달 reuse, `cancel_after_purchase_start` 기본 선택)
- `dev/js/admin.js` — 캠페인별 신청자 페인 「취소」 배지 + cancel_phase 라벨
- `dev/js/admin.js` 또는 별도 — 「신청자 엑셀」 4컬럼 추가 (취소일/취소 사유/취소 카테고리/취소 시점)

### 6-3. PR-B와 PR-C 동시 작업 시 충돌 점검
- 둘 다 `dev/index.html` 일부 영역 만짐 — 인플루언서 부분(PR-B) vs 관리자 부분(PR-C). 같은 파일 다른 영역 → rebase로 처리
- 둘 다 `dev/js/ui.js`의 `getStatusBadge` 만질 가능성 — 함수 한 곳만 손대므로 후순위 PR이 rebase

---

## 7. A-PR-D (알림) — A-PR-A + B 둘 다 머지 후

### 7-1. 영역
- 마이그레이션 1개 (`supabase/migrations/{다음번호}_application_cancel_digest_notify.sql`)
  - `admin_notices` 자동 등록 DB 트리거 (취소 즉시)
  - `application_cancel_digest_runs` 발송 로그 테이블 + RLS (super_admin SELECT만)
- 신규 Edge Function `supabase/functions/notify-application-cancelled-daily/index.ts`
  - 매일 한국시간 오전 9시 호출됨 (cron이 호출)
  - 윈도우: 전일 한국시간 0~24시 + `cancel_phase != 'recruit'`
  - 수신자: `get_subscribed_admin_emails('application_cancel')` + env `NOTIFY_ADMIN_EMAILS`
  - 0건이면 발송 skip + 로그
  - 발송 로그 UNIQUE 충돌로 중복 호출 차단
- 메일 템플릿 (이미 1차안 작성 완료 — 검토 후 그대로 사용 가능)
  - `docs/email-templates/application-cancelled-daily.html` (메인)
  - `docs/email-templates/application-cancelled-daily.row.html` (행 부분)
  - `docs/email-templates/application-cancelled-daily.preview.html` (미리보기, 샘플 3건)
  - `_templates/` 미러 동기화 (`scripts/sync-email-templates.sh`)
- `docs/email-templates/index.html` 카탈로그 카드 (이미 임시 등록 완료 — 「PR-D 작업 대기」 배지 제거만 하면 됨)
- 이전 세션의 즉시발송용 파일 폐기:
  - `docs/email-templates/application-cancelled.html`
  - `docs/email-templates/application-cancelled.preview.html`
- HANDOFF 별도 작성: `HANDOFF-application-cancel-pr-d-cron-setup.md` — 양 서버 `pg_cron` 등록 SQL (운영자가 수동 실행)

### 7-2. pg_cron 등록 SQL (양 서버 수동 실행)
```sql
-- 개발/운영 양 서버 SQL Editor에서 각각 실행
SELECT cron.schedule(
  'application-cancel-daily-digest',
  '0 0 * * *',                          -- 매일 UTC 00:00 = 한국시간 09:00
  $$
  SELECT net.http_post(
    url := current_setting('app.functions_url') || '/notify-application-cancelled-daily',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || current_setting('app.functions_jwt')
    ),
    body := '{}'::jsonb
  );
  $$
);
```
- `app.functions_url` / `app.functions_jwt`는 환경별로 다른 값 — 마이그레이션에 하드코딩 금지

---

## 8. A-PR-E (약관·정책)

### 8-1. 영역
- `docs/TERMS_kr.md` + `docs/TERMS_ja.md` — 「§N 캠페인 신청 취소 정책」 신규 섹션 (사양서 §7-1 골자)
- `docs/PRIVACY_kr.md` + `docs/PRIVACY_ja.md` — 신규 수집 항목 4종 + 처리 목적 추가 (사양서 §7-2)
- `/약관확인` 슬래시 커맨드 실행 → 누락 항목 점검
- `docs/OPERATOR_GUIDE.md` 영향 시 Notion 동기화 블록 안내 (`.claude/rules/notion-sync.md` 규칙 참조)

---

## 9. 운영 배포 시 외부 시스템 동기화 (필수)

각 PR 운영 배포 직전 `.claude/rules/git.md` 「외부 시스템 설정 양 서버 동기화」 체크리스트:

- B 머지 후: 운영 Supabase 마이그레이션 + `notify-brand-application` Edge Function 운영 재배포
- A-PR-A 머지 후: 운영 Supabase 마이그레이션 실행 + 운영 DB `applications` 백업 (partial unique 변경)
- A-PR-D 머지 후: 운영 Supabase 마이그레이션 + 신규 Edge Function 운영 배포 + 운영 `pg_cron` 등록 SQL 실행
- A-PR-E 머지 후: Notion 「운영자 가이드」 페이지 수동 동기화 (영향 있을 시)

---

## 10. 에이전트 호출 의무 (모든 PR)

`.claude/rules/git.md` + `.claude/rules/interaction.md` 동일 규칙:

- **모든 commit 직전**: `reverb-reviewer` 1회 (예외: 단순 한 줄 오탈자만)
- **Auth/RLS/마이그레이션/Edge Function/storage.js 변경 시**: `reverb-supabase-expert` (코드 쓰기 전)
- **운영 배포 직전 / 인증·신청·관리자 플로우 변경**: `reverb-qa-tester` (light 또는 full)
- 마지막 보고 줄에 `qa-tester 권장: light/full/skip` 명시

---

## 11. 작업 시작 절차 (개발 세션)

```bash
cd ~/Documents/projects/reverb-jp
git checkout dev
git pull origin dev

# 다른 세션 작업 흔적 점검 (필수, §3 참조)
git status
git log --oneline -10
git diff supabase/migrations/103_admin_email_subscriptions.sql | head -40
git diff supabase/migrations/104_application_cancellation.sql | head -40

# 마이그레이션 다음 번호 확인
ls supabase/migrations/ | tail -5
```

worktree 권유 기준:
- 평소: 메인 폴더에서 시퀀셜 작업 (개발1)
- B와 A-PR-A·B·C·D·E를 동시에 다른 세션이 진행할 만한 영역 분리가 가능하면 `/새세션 application-cancel` 로 worktree 분리 (개발2)
- 단 같은 파일(`dev/js/admin.js`·`dev/lib/storage.js`·마이그레이션 번호)을 양쪽이 만지면 worktree 분리해도 충돌 — 시퀀셜 권장

---

## 12. 사양서 본문 참조 인덱스

| 정보 | 위치 |
|---|---|
| A 결정 사항 표 | `docs/specs/2026-05-11-application-cancel.md` §1 |
| A DB 스키마 변경 (마이그레이션 SQL 본문) | 같은 사양서 §2 |
| A 비즈니스 룰 매트릭스 | §3 |
| A 인플루언서 UI 모달·탭·i18n 키 | §4 |
| A 관리자 UI + URL 자동 필터 | §5 |
| A 알림 (사이드바 즉시 + 메일 일일 요약) | §6 ← 2026-05-12 재작성 |
| A 약관·개인정보 영향 | §7 |
| A PR 분할 표 | §8 |
| A QA 시나리오 15종 | §9 |
| A 롤백 절차 | §10 |
| A 충돌 점검 | §11 |
| B 결정 사항 표 | `docs/specs/2026-05-11-admin-email-subscriptions.md` §1 |
| B DB 스키마 + RLS + 이관 SQL | 같은 사양서 §2 |
| B 관리자 UI 모달 미리보기 + 발송 빈도 안내 | §3 ← 2026-05-12 갱신 |
| B Edge Function 영향 (양쪽 메일 모두) | §4 |
| B 신청 취소 사양과의 의존성 | §5 |
| B PR 분할 + QA + 롤백 | §6·§7·§9 |

---

## 13. 한 번에 묶어 개발 세션에 던질 메시지 (붙여넣기용)

```
「응모 취소 + 관리자 메일 수신 분리 + NG 사항 번들화 + 브랜드 서베이 모집비」 일감 인수.

본 HANDOFF: docs/specs/2026-05-12-HANDOFF-application-cancel-and-admin-email-subs.md
사양 본문 여섯 개:
  - docs/specs/2026-05-11-application-cancel.md     (A. 응모 취소)
  - docs/specs/2026-05-11-admin-email-subscriptions.md (B. 관리자 메일 수신 분리)
  - docs/specs/2026-05-12-ng-sets.md                  (C. NG 사항 번들화 — A·B 머지 후 시작)
  - docs/specs/2026-05-12-brand-app-recruit-fee.md    (D. 브랜드 서베이 모집비 — 개발1 신규 등록 모달과 합류)
  - docs/specs/2026-05-12-brand-app-status-tabs.md    (E. 브랜드 서베이 신청 목록 상태별 탭 — D와 같은 페인, 합류 권장)
  - docs/specs/2026-05-12-rich-editor-image-upload.md (F. 참여방법·주의사항·NG 미니 에디터 이미지 첨부 강화 — C와 합류 또는 먼저 머지)
메일 1차안 (검토 후 그대로 사용 가능):
  - docs/email-templates/application-cancelled-daily.{html,row.html,preview.html}
  - docs/email-templates/index.html 카탈로그 카드 임시 등록 완료

진행 순서:
  B(admin-email-subs) → A-PR-A → A-PR-B/C 병렬 → A-PR-D → A-PR-E
  → C-PR-A → C-PR-B/C 병렬 → C-PR-D → C-PR-E → (1주 후) C-PR-F

진입 시 첫 단계: HANDOFF §3 「현재 작업 흔적 점검」.
다른 세션이 마이그레이션 103·104를 이미 만들어둔 흔적 있음 — 사양서와 대조 후 진행 여부 사용자에게 확인.

각 커밋 전 reverb-reviewer 호출 필수.
Auth/RLS/마이그레이션/Edge Function/storage.js 변경 시 reverb-supabase-expert 추가 호출.
배포 전 reverb-qa-tester light/full 권장.
운영 배포는 사용자 명시 지시 후에만.
```
