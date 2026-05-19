# HANDOFF — 인플루언서 ↔ 관리자 양방향 메시지 (응모건 단위)

> **작성일**: 2026-05-18
> **작성 세션**: 기획/설계 (메인 폴더, 코드 미수정)
> **인수인계 대상**: 개발 세션 (`/새세션 application-messaging` 권장)
> **관련 사양서**: `docs/specs/2026-05-15-application-messaging.md` (1,271줄, 기획 완성)
> **약관 영향**: 중대 변경 — **운영 배포 D-7 사전 통지 필수** (사양서 §8-1)
> **선행 운영 상태**: 마이그레이션 121 (link/unlink) 운영 적용 완료, 영수증 필수 입력 128 완료

---

## 0. 한 줄 요약

LINE 외부 채널 의존을 줄이고 응모건 단위 시스템 내 양방향 메시지 채널을 도입. PR 5단계 점진 배포 + 약관 사전 통지 7일 의무.

---

## 1. 산출물 (전체 5개 PR 누적)

| 종류 | 갯수 | 비고 |
|---|---|---|
| 마이그레이션 | 1개 (또는 PR 별 분리) | 테이블 5개 + 컬럼 1개 + 뷰 2개 + 원격 호출 함수(RPC) 9개 + Storage 버킷 + lookup_values 시드 2종 |
| Edge Function | 2개 신규 | `notify-message-influencer` + `notify-message-admin-digest` |
| 메일 템플릿 | 2개 + 미러 | `docs/email-templates/` 신규 |
| 인플루언서 코드 | 수정 다수 | 응모이력 / GNB / 알림 모달 + 신규 메시지 모달 + 첨부 업로드 + i18n |
| 관리자 코드 | 수정 다수 | 사이드바 「메시지」 페인 신규 + 응모 행 버튼 + 모달 |
| 정책 문서 | 4종 갱신 | PRIVACY_kr·ja + TERMS_kr·ja (사양서 §8-2 A~E 5건) |
| Storage 버킷 | 1개 | `application-message-attachments` (private) |
| 클라이언트 코드 변경 라인 | 다수 | 사양서 §6 「영향 범위」 표 참조 |

---

## 2. 작업 전제 (기획 완성)

### 2-1. 사양 확정 (§1~§10)

| 항목 | 상태 |
|---|---|
| §2 확정 요구사항 7건 | 모두 사용자 결정 완료 |
| §3 결정 사항 (837줄 분량) | 모든 정책·플로우·예외 정리 |
| §4 데이터 모델 | 테이블·트리거·뷰·원격 호출 함수(RPC) 명세 완성 |
| §5 UI 변경 | 인플·관리자 양쪽 모달·페인 정의 완성 |
| §6 영향 범위 | DB·Edge·코드·문서·약관 모두 식별 |
| §7 의존성·실행 순서 | PR 5단계 분할안 포함 |
| §8 약관·개인정보 영향 | **메인 세션 /약관확인 호출 완료 (2026-05-18)** — §8-2 확정 문구 5건 + §8-3 운영 배포 직전 체크리스트 포함 |
| §9 보안 고려 | 행 단위 보안 정책·마스킹·Rate limit 모두 정의 |
| §10 v2 후속 | 본 작업 범위 밖 명확히 분리 |

### 2-2. 기존 인프라 점검

- `notifications` 테이블 (기존) — 단방향 알림. 본 작업으로 양방향 추가
- `applications.message` 컬럼 (기존) — 응모 시 1회 메시지. 호환 유지
- `lookup_values(kind='admin_email_kind')` 시드 3건 (`brand_notify`, `application_cancel`, `application_received`) — 메일 통합 사양서 진행 중에 추가될 가능성 있음, 작업 시작 직전 재확인
- 다음 마이그레이션 번호: **132 이후** (현재 130 운영 + 131·132 메일 통합 작업 중). 작업 시작 직전 `ls supabase/migrations/ | tail -5` 필수

---

## 3. PR 분해 (사양서 §7 PR-1~5 그대로 미러링)

| PR | 범위 | 사양서 섹션 | 의존성 |
|---|---|---|---|
| **PR 1** — 기반 인프라 + 인플 메시지 | DB 마이그레이션 (테이블 5개 + RPC 핵심) + lookup_values 시드 + Storage 버킷 + 인플루언서 메시지 모달 + 본인 회수 25분 + 첨부 cleanup | §4 데이터 모델 + §3-1, §3-3, §3-5 + §5 인플 UI | 메일 통합 PR (131·132) 운영 안정화 후 |
| **PR 2** — 관리자 페인 + 강제 숨김 | 관리자 사이드바 「메시지」 페인 + 응모 행 버튼 + 받은편지함 + 응대 완료 + 강제 숨김 모달 + 복구 모달(super_admin) + audit | §5 관리자 UI + §3-4, §3-5 + §4-1-5 audit | PR 1 운영 배포 완료 |
| **PR 3** — 일괄 발송 (BCC) | 일괄 발송 모달 + 이력 페인 + 일괄 발송·회수 RPC + 메시지 카드 일괄 발송 배지 | §3-7 양방향 시작 + 일괄 발송 + §4 `application_message_broadcasts` | PR 1·2 운영 배포 후 **1주 안정화** |
| **PR 4** — 지연 큐·다이제스트 | 30분 미읽음 지연 발송 + 묶음 + 야간 보류 + 24h 리마인더 한도 + 일별 다이제스트 | §3-1 알림 방식 (인플 메일 지연·묶음·야간 보류 정책) + §4-6 + Edge Function 2종 | PR 3 운영 배포 완료 |
| **PR 5** — LINE 전환 + 약관 | LINE CTA 변경 1단계 + i18n + **PRIVACY/TERMS 4종 갱신 (사양서 §8-2 A~E)** + D-7 사전 통지 | §3-9 LINE 전환 + §8 약관 | PR 4 운영 배포 후 D-7 사전 통지 + 약관 시행일 명시 |

총 5개 PR. 큰 기능이라 1 PR 무리. 점진 배포 + 운영 안정화 버퍼 1주 ~ 1개월.

---

## 4. 정책 문서 갱신 절차 (PR 5 핵심)

### 4-1. D-7 사전 통지 (필수)

- 한국 PIPA + 일본 APPI **양쪽 트리거** — 수집 항목 신규 + 관리자 열람권 신설 = 중대 변경
- 운영 배포일 = D-day → **D-7** 일에 앱 내 공지 + 회원 메일 발송
- 사전 공지 본문 포함 사항:
  - 메시지 기능 출시 안내
  - 수집 항목 (메시지 본문·첨부 이미지)
  - 보유 기간 (응모 종료 후 1년 또는 탈퇴 시 파기)
  - 관리자 열람 범위 (super_admin / campaign_admin / campaign_manager 전체)
  - 시행일 (운영 배포 D-day)

### 4-2. 정책 문서 4종 갱신 (PR 5 운영 배포 시)

사양서 §8-2 의 확정 문구 5건 그대로 적용:

- **A**: PRIVACY_kr·ja §2.1 인플루언서 회원 수집 항목 행 추가
- **B**: PRIVACY_kr·ja §6.1 보유 기간 행 추가
- **C**: PRIVACY_kr·ja §9 기술적·관리적 조치 내부 접근 권한 항목 추가
- **D**: TERMS_kr·ja §제7조 항목 7번 신규 (기존 6번은 8번으로 이동)
- **E**: PRIVACY_kr·ja §5 국외 이전 행 추가

각 문서 상단 **「최종 갱신일」 + 「시행일」 동시 갱신**. 시행일 = D-day.

### 4-3. PR 5 운영 배포 직후

- 정책 변경 안내 푸시/공지 1회 추가 (사전 통지와 별개)
- 회원 메일 발송 (마케팅 동의 무관 — 법령 의무 통지)

---

## 5. 핵심 결정 사항 빠른 참조 (사양서 §2)

| Q | 결정 |
|---|---|
| Q1 메시지 단위 | 응모건 단위 (`application_id` FK) |
| Q2 발송 주체 | 인플루언서 ↔ 관리자 양방향 + 일괄 발송(BCC) |
| Q3 첨부 | 텍스트 + 이미지 (Storage 버킷 분리) |
| Q4 회수·숨김 | 본인 회수 25분 + 관리자 강제 숨김 (audit 보존) |
| Q5 메일 발송 | 30분 지연 큐 + 묶음 + 24h 리마인더 한도 |
| Q6 LINE 전환 | 1단계 (PR 5) 안내 + 2단계 검토 (운영 1개월 후) |
| Q7 보유 기간 | 응모 종료 후 1년 / 탈퇴 시 파기 |

세부는 사양서 §3 결정 사항 (837줄) 참조.

---

## 6. 핵심 데이터 모델 (사양서 §4 발췌)

| 테이블 | 용도 |
|---|---|
| `application_messages` | 메시지 본문 (텍스트 + 첨부 jsonb + 회수·숨김 메타) |
| `application_message_admin_reads` | 관리자 개인별 읽음 추적 |
| `application_message_resolutions` | 응대 완료 마킹 |
| `application_message_broadcasts` | 일괄 발송 묶음 (PR 3) |
| `application_message_hide_history` | 강제 숨김·복구 audit (super_admin SELECT) |

신규 컬럼: `application_messages.broadcast_id` (FK)
신규 뷰: `application_message_summary` (집계) + `application_message_safe` (마스킹) — 마스킹 RPC 패턴 채택 시 후자는 RPC 로 대체 가능 (사양서 §9 결정)

신규 원격 호출 함수(RPC) 9개:
- `send_application_message`
- `send_application_message_bulk` (PR 3)
- `mark_application_messages_read`
- `hide_application_message` (시그니처 변경 — 카테고리 + 자유 메모)
- `unhide_application_message` (신설, super_admin)
- `withdraw_own_message` (신설, 25분 한도)
- `withdraw_broadcast` (신설, PR 3)
- `mark_application_resolved` (응대 완료)
- `application_message_admin_unread_counts` (사이드바 배지)

행 단위 보안 정책: 인플루언서는 본인 응모건만, 관리자는 전체. INSERT/UPDATE 는 모두 SECURITY DEFINER RPC 경유 (sender_kind 변조 차단).

---

## 7. 검증 시나리오 (PR 별 핵심)

### PR 1
- [ ] 인플루언서가 메시지 발송 → 행 INSERT + 첨부 Storage 업로드
- [ ] 관리자가 동일 응모건 메시지 SELECT 가능 (다른 응모건은 차단)
- [ ] 25분 안 본인 회수 → `self_withdrawn_at` UPDATE + 첨부 파일 Storage 삭제
- [ ] 26분 후 회수 시도 → RPC 차단 (시간 초과)
- [ ] 비인증 anon SELECT → 0건

### PR 2
- [ ] 관리자가 메시지 발송 → 행 INSERT + 메일 큐 등록
- [ ] 강제 숨김 모달 (카테고리 + 자유 메모) → `hidden_*` 컬럼 UPDATE + audit INSERT
- [ ] 인플루언서 화면에서 숨김 메시지 본문·첨부 마스킹 확인
- [ ] super_admin 복구 모달 → `hidden_*` 컬럼 NULL + audit INSERT
- [ ] 응대 완료 마킹 → `application_message_resolutions` INSERT

### PR 3
- [ ] 일괄 발송 (BCC) → `broadcasts` 행 1개 + 응모별 `application_messages` 행 N개
- [ ] 일괄 회수 → `broadcasts.withdrawn_at` UPDATE + 모든 묶음 메시지 마스킹

### PR 4
- [ ] 30분 안 읽음 → `email_skip_reason='read_in_time'` 메일 미발송
- [ ] 30분 후 미읽음 → 메일 1통 발송 + 24h 한도 안 추가 메시지 묶음
- [ ] 야간(22~07시) 발송 보류 + 다음 09:00 발송
- [ ] 일별 다이제스트 (관리자) 미응대 건수 정리

### PR 5
- [ ] LINE CTA 1단계 안내 표시
- [ ] PRIVACY/TERMS 4종에 §8-2 A~E 5건 적용 + 시행일 명시
- [ ] D-7 사전 통지 본문에 수집·열람·보유 모두 명시
- [ ] 시행일 = 운영 배포일 정확히 일치

---

## 8. 운영 배포 절차 (PR 별)

각 PR 공통:
1. 개발 DB 마이그레이션 적용 → 검증 SQL 통과
2. `reverb-supabase-expert` 호출 (DB 변경 시)
3. `reverb-reviewer` 호출 (commit 직전 의무)
4. `reverb-qa-tester` 호출 (인증·신청·관리자 플로우 영향 — light 또는 full)
5. dev push → 개발서버 검증
6. `AskUserQuestion` 으로 운영 배포 여부 사용자 명시 승인
7. 운영 DB 마이그레이션 적용
8. main merge → 운영 자동 배포
9. (PR 5만) D-day 시점에 정책 4종 동시 갱신 + 안내 푸시

PR 5 만 추가 단계:
- D-7 일 사전 통지 발송 (앱 내 공지 + 회원 메일)
- D-day = 운영 배포일 + 정책 4종 시행일

---

## 9. 롤백 절차

### 9-1. PR 1 롤백 (DB)

```sql
-- 1. RPC 제거 (역순)
DROP FUNCTION IF EXISTS send_application_message;
DROP FUNCTION IF EXISTS mark_application_messages_read;
DROP FUNCTION IF EXISTS withdraw_own_message;
-- ... 기타 RPC

-- 2. 테이블 DROP (CASCADE 주의 — application_messages 참조하는 테이블도 함께)
DROP TABLE IF EXISTS application_message_admin_reads CASCADE;
DROP TABLE IF EXISTS application_message_resolutions CASCADE;
DROP TABLE IF EXISTS application_message_broadcasts CASCADE;
DROP TABLE IF EXISTS application_message_hide_history CASCADE;
DROP TABLE IF EXISTS application_messages CASCADE;

-- 3. Storage 버킷 정리
-- Supabase Dashboard 에서 application-message-attachments 버킷 삭제 (또는 보존)

-- 4. lookup_values 시드 정리
DELETE FROM lookup_values WHERE kind = 'message_hide_reason';
```

### 9-2. PR 5 약관 롤백

- PRIVACY/TERMS 4종에서 §8-2 A~E 5건 행 제거
- 시행일 → 이전 갱신일로 복귀
- 정책 롤백 안내 푸시 추가 발송 (회원 혼란 방지)

---

## 10. 의존성 / 충돌 점검

### 10-1. 동시 진행 불가 작업

- 메일 통합 사양서 PR 진행 중 (`notify-admin-daily-digest`) — `lookup_values(kind='admin_email_kind')` 시드 변경 작업 충돌 가능. **메일 통합 PR 운영 안정화 후 PR 1 시작 권장**
- `applications` 테이블 트리거 (마이그레이션 131 `application_events`) — 본 작업도 트리거 추가 가능성 있어 응모 단위 트리거 충돌 점검 필수

### 10-2. 마이그레이션 번호

작업 시작 직전 `ls supabase/migrations/ | tail -5` 로 확인. 메일 통합 PR 1·2 가 131·132 사용 예정이므로 본 작업 PR 1 은 **133 이후** 사용.

### 10-3. admin.js 핫스팟

관리자 UI 추가가 PR 2·3 에 집중. `admin.js` 9,464줄 핫스팟 회피 위해 **신규 `dev/js/admin-messaging.js` 파일 분리 권장** (admin-company.js 패턴 동일).

---

## 11. 에이전트 호출 의무 (배포 전 필수)

각 PR commit 직전 모두 적용:

- [ ] **reverb-supabase-expert** — DB 변경(테이블·트리거·뷰·원격 호출 함수(RPC)·행 단위 보안 정책) 모두 검증 (PR 1·2·3·4)
- [ ] **reverb-reviewer** — 모든 commit 직전 예외 없이
- [ ] **reverb-qa-tester** —
  - PR 1·2·5 → **full 모드** (인증·신청·관리자 플로우 영향)
  - PR 3·4 → light 모드 (관리자 페인·발송 정책만)
- [ ] **reverb-planner** — PR 마다 진입 시 1회 (사양서 §7 PR-1~5 분할이 이미 있으므로 변경점 확인만)

---

## 12. PR description 권장 형식

### PR 1 예시
```
## 변경 요약
- 응모건 단위 양방향 메시지 채널 — PR 1 (기반 인프라 + 인플 메시지)
- 마이그레이션 — 테이블 5개 + RPC 핵심 + lookup_values 시드 + Storage 버킷
- 인플루언서 메시지 모달 + 본인 회수 25분 + 첨부 cleanup

## 요청 외 추가 변경
- 없음

## 약관 영향
- 본 PR 자체는 약관 갱신 없음. PR 5 운영 배포 시 PRIVACY/TERMS 4종 동시 갱신 (사양서 §8-2)

## 관련 사양서
- docs/specs/2026-05-15-application-messaging.md (전체)
- docs/specs/2026-05-18-HANDOFF-application-messaging.md §3 PR 1

## DB 변경
- 마이그레이션 — 테이블 5개 + RPC 9개 + Storage 버킷 + lookup_values 시드 2종

## 검증
- HANDOFF §7 PR 1 시나리오 모두 통과 (개발서버)
```

---

## 13. 작업 완료 후 (각 PR)

- 사양서 §「구현 결과」 PR 별 단계 채우기 (`.claude/rules/docs-tracking.md` 의무)
- `CLAUDE.md` Features · Database Schema · Email/SMTP 섹션 갱신
- `FEATURE_SPEC.md` 메시지 기능 항목 추가
- PR 5 완료 후 사양서 §10 v2 후속 항목 별도 사양서로 분리 검토

---

## 14. 메인 세션 (고문/검증) 후속

- 본 HANDOFF + 사양서 untracked → docs commit + dev push (다음 단계)
- 각 PR 운영 배포 완료 후 사양서 §「구현 결과」 갱신 상태 점검
- PR 5 D-7 사전 통지 시점에 안내 본문 검토 지원 (정책 변경 안내문 초안 작성)
