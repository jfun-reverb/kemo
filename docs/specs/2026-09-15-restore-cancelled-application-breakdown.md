# 📋 작업 분해표 — 관리자 「취소 되돌리기」
**사양서:** docs/specs/2026-09-15-restore-cancelled-application.md
**분해일:** 2026-09-15
**총 작업 조각:** 11개 · **병렬 가능:** 4개 · **순차 필수:** 7개

> 대조 기준: `origin/dev`(마지막 마이그레이션 439). 이 문서의 줄 번호는 모두 그 시점 기준입니다.

---

## 🚦 착수 전 선결 조건

**없음 — 바로 착수할 수 있습니다.** 데이터베이스 조각(1~3)과 화면 조각(4·5·7)은 지금 시작해도 됩니다.

분해 중 코드 대조에서 나온 사용자 확인 2건은 **2026-09-15 결정 완료**이고 사양서 「확정된 결정」 8·9에 반영했습니다(S-9·S-10).

| # | 확인한 것 | 결정 | 영향 조각 |
|---|---|---|---|
| S0-1 | 종료된 캠페인에서 심사중으로 되돌린 신청은 자동 낙첨되지 않고 남는다 | **확인 창에 안내 한 줄 추가**(막지 않음) — 사양서 결정 8 | 6 |
| S0-2 | 승인으로 되돌리면 제출 마감 D-5·D-1 안내 메일이 다시 대상이 된다 | **그대로 받게 둔다**(메일 함수 무변경) — 사양서 결정 9 | 없음 |

---

## ⚠️ 사양서 stale 점검

### 결론이 뒤집히는 것 — 0건

사양서가 적은 원본 번호·트리거 동작은 모두 현재 코드와 일치합니다.

### 확인 완료 (사양서와 일치)

| # | 사양서가 적은 것 | 실제 (확인 방법) |
|---|---|---|
| S-1 | 알림 종류 검사 제약 원본 = 376, 12종 | `notifications_kind_check` 를 정의한 파일은 105·145·154·160·219·273·283·376. 가장 큰 정의가 **376**(111~124행, 12종)이고 이후 정의 파일 없음. 주석과 정의가 섞인 파일은 `ADD CONSTRAINT` 줄로만 셌다 |
| S-2 | 신청 이력 표 `action` 검사 = 3종 | 131(신청 이력 표 생성) 72행에 **열 안쪽 검사로 한 번만** 정의, 이후 바꾼 파일 0건. ⚠️ 열 안쪽 검사라 **제약 이름이 자동 생성**이다 — 사양서의 「실제 이름으로 조회해서 지운다」가 반드시 필요 |
| S-3 | `record_application_status_event` 원본 = 283 | 정의 파일 131·154·283, **283**(761~850행)이 최신. `cancelled →` 전이는 `v_action` 이 비어 805행에서 조기 반환 → **이력 행·당선 알림을 만들지 않는다**. 「함수가 넣는 1행·1건과 겹치지 않는다」 성립 |
| S-4 | 알림 insert 뒤 메일 없음 | 알림 insert 웹훅의 `notify-deliverable-decision` 이 종류 허용 목록(`MAIL_KINDS`, 603행)으로 거른다. `application_restored` 는 목록 밖 → **메일 안 나감**(결정 4와 일치) |
| S-5 | 신청 표 트리거 | 마이그레이션 기준 **12개**(아래 표). 되돌리기 UPDATE 에 반응 5 · 삽입 전용 6 · 삭제 전용 1. **막거나 부작용을 내는 것 없음** |
| S-6 | 권한 카탈로그 두 곳 | `ADMIN_PERMISSION_CATALOG`(`dev/lib/shared.js` 1944행)·`PERM_SUPER_SERVER_ENFORCED`(2039행). 선례 `withdrawal.proxy_request`·`ad_tracking.manage` 가 두 곳 모두 등록 |

**신청 표 트리거 12개 — 되돌리기 UPDATE(`cancelled → pending/approved`)에서의 동작**

| 트리거 | 정의 파일 | 발동 | 되돌리기에서 |
|---|---|---|---|
| `trg_guard_event_application_status_change` | 289(행사 신청 상태 직접 변경 차단) | 수정 전, 상태 칸 | 행사 캠페인이면 예외. 함수의 `event_campaign` 판정이 먼저 걸러 **도달 안 함**(백업 방어) |
| `trg_guard_reject_with_paid_settlement` | 247(송금완료 정산 반려 차단) | 수정 전, `WHEN OLD.status='approved'` | 이전 상태가 `cancelled` 라 **발동 안 함** |
| `trg_application_status_event` | 131 / 함수 283 | 수정 후, 상태 칸 | 조기 반환 → **행·알림 0** |
| `trg_auto_hold_settlement_on_app_reject` | 320(자동 보류 확대) | 수정 후, `WHEN NEW.status IN (rejected,cancelled)` | **발동 안 함** |
| `trg_sync_applied_count` | 058 / 계산 함수 179 | 수정 후, 상태 칸 | 모집 인원 **재계산**(의도대로) |
| `trg_monitor_slots_guard` | 179(감사용 계정 격리) | 삽입 전 | 발동 안 함 — 함수가 `slots_full` 로 대신 |
| `trg_monitor_auto_approve` | 049(리뷰어형 자동 승인) | 삽입 전 | 발동 안 함 |
| `trg_age_policy` | 180(연령 정책) | 삽입 전 | 발동 안 함 |
| `trg_application_deadline_guard` | 272 / 함수 326 | 삽입 전 | 발동 안 함 — 결정 3의 근거 |
| `trg_application_insert_status_guard` | 314(삽입 상태값 위조 차단) | 삽입 전 | 발동 안 함 |
| `trg_account_withdrawn_guard` | 359(탈퇴 계정 차단) | 삽입 전 | 발동 안 함 — 함수의 `withdrawal_related` 가 대신 |
| `trg_block_delete_with_settlements` | 251(정산 걸린 삭제 차단) | 삭제 전 | 무관 |

⚠️ 이 12개는 **마이그레이션 파일 기준**이다. 대시보드·패치로 직접 만든 트리거는 파일에 없을 수 있어 조각 3에서 개발 데이터베이스 실제 목록으로 대조한다.

### 실행 정보 (결론은 그대로, 구현할 때 알아야 할 것)

| # | 사양서 | 실제 | 조치할 조각 |
|---|---|---|---|
| S-7 | 목록 두 곳 「213·1049행」 | **213행 = 캠페인 진행현황 신청자 목록**(`renderCampApplicantRow`), **1049행 = 신청 관리 목록**(`renderAppCampList` 계열). 사양서가 이름을 적은 순서와 줄 번호 순서가 반대라 헷갈리기 쉽다 | 6 |
| S-8 | 되돌리기 함수가 비우는 칸 | 🔴 **`reviewed_at`·`reviewed_by` 는 건드리지 않는다.** 인플루언서 일일 메일이 「어제 `reviewed_at` + 승인」으로 당선 절을 뽑아(`notify-influencer-daily-digest/index.ts` 697~703행), 채우는 순간 **다음 날 당선 메일이 나가** 결정 4를 어긴다 | 1 |
| S-9 | 결정 3: 모집 끝난 캠페인도 허용 | 종료 시 심사중 자동 낙첨 트리거(176)는 **캠페인 상태가 바뀌는 순간에만** 돈다. 이미 종료된 캠페인에 심사중으로 되돌린 신청은 **계속 심사중으로 남는다** → 결정 8 | 6 |
| S-10 | 결정 4: 메일 없음 | 승인으로 되돌린 신청은 제출 마감 D-5·D-1 대상 조회(같은 파일 723~727행)에 다시 들어간다. 취소 전에 이미 보낸 D-N 은 `deadline_reminder_email_sent` 유일 제약이 막는다 → 결정 9 | — |
| S-11 | 알림 클릭 이동 분기 「필수」 | `onNotifItemClick`(`dev/js/notifications.js` 315~398행)에 `application_cancelled`·`application_approved` 전용 분기가 **없고** 둘 다 마지막 `else`(393~396행)로 응모이력에 간다. 새 종류도 **분기 없이 이미 도착**한다 — 명시 분기는 **방어용**. 아이콘 표(295행)에 항목이 없어 회색 종으로 보이므로 항목을 더한다 | 7 |
| S-12 | 거부 문구를 둘 자리 | `friendlyError`(`dev/js/admin-core.js` 131행, **핫스팟**)는 원문 문자열 매칭이라 코드 체계와 안 맞는다. 선례대로 **화면 파일 안에 코드→문구 표**(`AD_TRACKING_ERROR_TEXT`, `dev/js/admin-ad-tracking.js` 25행). `admin-core.js` 는 건드리지 않는다 | 6 |
| S-13 | 서버 거부 반환 키 이름 | 사양서는 저장소 함수의 `error_code` 만 적었다. 선례도 갈린다(357 `reason` / 438 `success`+`reason`). 이 작업표는 **서버도 `{ok:false, error_code}`** 로 고정한다. 바꾸면 조각 1·5를 함께 | 1·5 |
| S-14 | 마이그레이션 ①→② 순서 | `has_permission`(현재 원본 269)은 슈퍼관리자는 행이 없어도 통과, 캠페인관리자·매니저는 **행이 없으면 거부**. ①만 적용된 사이에는 캠페인관리자가 `forbidden` → ①② 함께 적용 뒤 스모크 호출(선례 439 헤더). 시드는 세 등급 모두 `default_level` 포함 | 2·3·10 |
| S-15 | 목록 갱신 | `refreshPane('applications')`·`refreshPane('camp-applicants')` 둘 다 `PANE_REFRESHERS`(`dev/lib/shared.js` 1388·1393행)에 있다. 심사중 건수가 바뀌어 **사이드바 배지**도 달라지므로 기존 `updateAppStatus`(1139~1141행)처럼 `loadAdminData()` 도 부른다 | 6 |
| S-16 | 권한 수 주석 | `shared.js` 1977~1981행 「주요 기능 24개」·`dev/js/admin-permissions.js` 3행 「36」이 숫자를 적고 있다. 항목을 더하면 함께 고친다 | 4 |
| S-17 | 실행 권한 | 모집 인원 계산 함수는 370 에서 로그인 사용자 실행 권한이 회수됐다. 새 함수가 **소유자 권한 실행(`SECURITY DEFINER`)** 이어야 058 트리거가 안 끊긴다 — 빼면 되돌리기가 통째로 실패 | 1 |
| S-18 | 빌드 | 새 파일 없음 → `dev/build.sh` 수정 없음 | — |
| S-19 | 세 번째 취소 행 표시 | 인플루언서 상세 모달 응모 목록(`dev/js/admin-influencers.js` 447행)의 취소 행은 조회 전용이고 사양서 범위(두 목록) 밖 | — |

---

## 한눈에 보는 의존 순서

```
[데이터베이스 갈래 — 한 세션 순차]
  1 마이그레이션 ① 작성 ─→ 2 마이그레이션 ② 작성 ─→ 3 개발 DB 적용·스모크 ─┐
                                                                              │
[화면 갈래]                                                                    │
  4 권한 카탈로그(shared.js) ─┐                                                 │
  5 저장소 함수(storage.js)  ─┴─→ 6 관리자 화면(admin-applications.js) ─┐      │
                                                                         │      │
[인플루언서 갈래 — 독립]                                                 │      │
  7 알림 아이콘·분기(notifications.js) ─────────────────────────────────┤      │
                                                                         ▼      ▼
                                          8 문서 한 세트 ─→ 9 개발서버 통합 검증·dev 병합
                                                                         │
                                                  (사용자 승인)          ▼
                                          10 운영 DB 적용·확인 ─→ 11 운영 코드 병합·확인·노션
```

🔴 **11은 10의 확인이 끝난 뒤에만** — 정산 3단계에서 버튼이 함수보다 15시간 먼저 운영에 나간 사고를 막기 위해서다.

---

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 마이그레이션 ① — 되돌리기 함수 + 검사 제약 2개 확장 | `supabase/migrations/{①}_*.sql` 신규 | `public.restore_cancelled_application(p_application_id uuid, p_memo text) RETURNS jsonb` · action `restore_cancelled` · kind `application_restored` · 반환 `{ok,restored_status,on_hold_settlement_count}` / `{ok:false,error_code}` | 없음 | ○ | 개발 A(DB) |
| 2 | 마이그레이션 ② — 권한 시드 3행 | `supabase/migrations/{②}_*.sql` 신규 | 열쇠말 `application.restore_cancelled` | 1 | ✗ | 개발 A(DB) |
| 3 | 개발 DB 적용 + 스모크 호출 | (개발 DB) | 조각 6·9가 부를 함수가 개발서버에 존재 | 1·2 | ✗ | 개발 A(DB) |
| 4 | 권한 카탈로그 등록 | `dev/lib/shared.js`, `dev/js/admin-permissions.js`(주석) | `canWrite('application.restore_cancelled')` 가 뜻을 가짐 | 없음 | ○(핫스팟 — 다른 세션이 `shared.js` 를 안 만질 때) | 개발 B(화면) |
| 5 | 저장소 함수 | `dev/lib/storage.js` | `restoreCancelledApplication(appId, memo)` | 없음(계약은 조각 1 기준) | ○(핫스팟 — 다른 세션이 `storage.js` 를 안 만질 때) | 개발 B(화면) |
| 6 | 관리자 화면 — 버튼 2곳 + 확인 창 + 결과 처리 | `dev/js/admin-applications.js` | `openRestoreCancelledModal(appId)` · 모달 `restoreCancelledModal` · 문구 표 `APP_RESTORE_ERROR_TEXT` | 4·5 | ✗ | 개발 B(화면) |
| 7 | 인플루언서 알림 아이콘 + 명시 분기 | `dev/js/notifications.js` | `iconMap.application_restored` · `kind === 'application_restored'` 분기 | 없음 | ○ | 개발 B |
| 8 | 문서 한 세트 | `CLAUDE.md`, `docs/FEATURE_SPEC.md`, 사양서 「구현 결과」 | 확정 마이그레이션 번호·이름 변경 기록 | 1~7 | ✗ | 개발 B |
| 9 | 개발서버 통합 검증 + dev 병합 | 빌드 산출물 | 사양서 「1-검증」 표 전부 통과 | 3·6·7·8 | ✗ | 개발 B |
| 10 | 운영 DB 적용 + 확인 | (운영 DB) | 운영에 함수·제약·권한 3행 존재 | 9 + 사용자 승인 | ✗ | 개발 A |
| 11 | 운영 코드 병합 + 확인 + 실무자 가이드 | `main` 병합, Notion 「신청 관리」 페이지 | 운영 화면에 버튼 노출 | 10 + 사용자 승인 | ✗ | 개발 B |

(표 11줄 = 총 조각 11 · 병렬 ○ 4줄[1·4·5·7] + 순차 ✗ 7줄[2·3·6·8·9·10·11])

---

## 조각별 상세

### 조각 1 — 마이그레이션 ①: 되돌리기 함수 + 검사 제약 2개 확장

- **하는 일**: 사양서 「설계 → 데이터베이스 ①」을 파일 하나로 작성. 개발 DB 적용은 조각 3.
- **담당 파일**: `supabase/migrations/{①}_restore_cancelled_application.sql`(번호는 생성 시점에 확정)
- **산출 계약** (조각 3·5·6·7이 그대로 쓴다)
  - 함수 `public.restore_cancelled_application(p_application_id uuid, p_memo text) RETURNS jsonb`, 소유자 권한 실행, `SET search_path = ''`
  - 권한 가드 `public.has_permission('application.restore_cancelled','write')`
  - 성공 `{"ok": true, "restored_status": "pending"|"approved", "on_hold_settlement_count": <정수>}`
  - 거부 `{"ok": false, "error_code": "<코드>"}` — 코드 10종과 판정 순서는 **사양서 거부 사유 표 그대로**
  - 이력 행 `application_events.action = 'restore_cancelled'`
  - 알림 행 `notifications.kind = 'application_restored'`, `ref_table = 'applications'`, `ref_id = 신청 id`
  - 실행 권한: `REVOKE … FROM PUBLIC` + `REVOKE … FROM anon` + `GRANT EXECUTE … TO authenticated`
- **선행 의존**: 없음
- **완료 정의**
  - 알림 종류 제약 베이스가 **376의 12종 그대로 + 1**(376 목록과 한 줄씩 대조)
  - 두 제약 모두 `pg_constraint` 조회로 **실제 이름을 얻어** 지운다(S-2)
  - 함수가 `reviewed_at`·`reviewed_by` 를 **쓰지 않는다**(S-8)
  - 파일 하단에 검증 조회와 롤백 주석(선례 439 형식)
- **필요 검문소**: `reverb-supabase-expert` → `reverb-reviewer`
- **주의·롤백**
  - 🔴 소유자 권한 실행을 빼면 058 트리거가 부르는 모집 인원 계산 함수가 권한 부족으로 실패(S-17)
  - 🔴 잠금 순서(신청 행 → 리뷰어형이면 캠페인 행)를 바꾸지 않는다
  - 롤백: 함수 `DROP` + 두 제약을 원래 목록으로 재생성. ⚠️ 이미 `restore_cancelled`·`application_restored` 행이 생긴 뒤에는 옛 목록으로 못 되돌린다(검사 위반) — 그 행을 먼저 처리

### 조각 2 — 마이그레이션 ②: 권한 시드

- **하는 일**: 세 등급의 권한 행. 형식은 439 를 따른다(`default_level` 포함, `ON CONFLICT DO NOTHING`)
- **담당 파일**: `supabase/migrations/{②}_restore_cancelled_permission_seed.sql`
- **산출 계약**: 열쇠말 `application.restore_cancelled` — 슈퍼·캠페인관리자 `write/write`, 캠페인매니저 `hidden/hidden`
- **선행 의존**: 1
- **완료 정의**: 파일 헤더에 「①다음에 적용」과 「①만 있으면 캠페인관리자가 거부된다」가 적혀 있다(S-14)
- **필요 검문소**: `reverb-supabase-expert` → `reverb-reviewer`
- **주의·롤백**: 열쇠말 철자가 **네 곳**(이 시드 · 조각 1 가드 · 조각 4 두 곳)에서 같아야 한다. 한 글자만 달라도 조용히 거부된다

### 조각 3 — 개발 DB 적용 + 스모크 호출

- **하는 일**: 개발 DB에 ①→② 순서로 적용하고 콘솔에서 직접 부를 수 있는 판정을 확인
- **담당 파일**: 없음(개발 Supabase — 크롬으로 **서버를 화면에서 확인한 뒤** 실행)
- **산출 계약**: 조각 6·9가 부를 함수가 개발서버에 존재
- **선행 의존**: 1·2
- **완료 정의**
  - 제약 조회에서 `restore_cancelled`·`application_restored` 가 보인다
  - `role_permissions` 3행, `access_level` = `default_level`
  - 개발 DB 신청 표 실제 트리거 목록이 위 12개와 일치(다르면 멈추고 기획에 알린다)
  - **사양서 「1-검증 — 거부 10종 재현 방법」 표 중 콘솔 호출 행** 통과: `forbidden` · `memo_required` · `not_found` · `not_cancelled` · `withdrawal_related` ①·①-b
  - 성공 1건(심사중 되돌리기): 이력 행 **정확히 1행**(283 트리거가 추가 행을 안 만듦) + `memo` 에 원래 취소 기록 / 알림 1건 / `applied_count` 재계산 / `reviewed_at` **전과 같음**
- **필요 검문소**: `reverb-supabase-expert`
- **주의·롤백**
  - 🔴 권한 가드·로그인 사용자 분기는 **SQL 편집기에서 재현되지 않는다**(서비스 키). 스모크는 **로그인한 브라우저 콘솔**에서
  - 편집기를 썼으면 `force` 이동 후 탭을 닫는다(`.claude/rules/browser-qa.md`)

### 조각 4 — 권한 카탈로그 등록

- **하는 일**: 권한 설정 화면과 `canWrite` 가 새 열쇠말을 알게 한다
- **담당 파일**: `dev/lib/shared.js`(1944행 카탈로그, 2039행 서버 강제 목록), `dev/js/admin-permissions.js`(3행 주석)
- **산출 계약**
  - `ADMIN_PERMISSION_CATALOG` 에 `{ key: 'application.restore_cancelled', label_ko: …, category: …, server_enforced: true }`
  - `PERM_SUPER_SERVER_ENFORCED` 에 같은 열쇠말
- **선행 의존**: 없음
- **완료 정의**: 권한 관리 화면에 새 줄이 보이고 효과 배지가 「서버 차단」. 주석 숫자 두 곳(S-16) 수정
- **필요 검문소**: `reverb-reviewer`
- **주의·롤백**: `shared.js` 는 **핫스팟**. 병합 전 다른 열린 기능 브랜치(메타 픽셀 후속 등)가 같은 카탈로그를 고치는지 확인

### 조각 5 — 저장소 함수

- **하는 일**: 원격 호출 함수를 감싸 거부와 통신 실패를 구분해 돌려준다
- **담당 파일**: `dev/lib/storage.js`(선례 `requestWithdrawalForMember` 3988행 · `updateMetaPixelSettings` 5157행 부근)
- **산출 계약**: `async function restoreCancelledApplication(appId, memo)` — 성공 `{ok:true, restored_status, on_hold_settlement_count}` / 서버 거부 `{ok:false, error_code}` / 통신 실패·예외 `null`. `retryWithRefresh` 로 감싸고 실패 시 `logAppError('restoreCancelledApplication', e)`
- **선행 의존**: 없음(반환 모양은 조각 1 계약에 고정)
- **완료 정의**: 조각 3 이후 콘솔에서 `restoreCancelledApplication('없는id','x')` → `{ok:false, error_code:'not_found'}`, 네트워크 끊으면 `null`
- **필요 검문소**: `reverb-reviewer`, `reverb-supabase-expert`
- **주의·롤백**: `storage.js` 는 **핫스팟**. 조각 4와 같은 세션에서 연달아 하는 것을 권한다

### 조각 6 — 관리자 화면: 버튼 2곳 + 확인 창 + 결과 처리

- **하는 일**: 사양서 「관리자 화면」 절 구현
- **담당 파일**: `dev/js/admin-applications.js` 만. 모달은 **동적 생성**(오리엔시트 모달 선례), `dev/admin/index.html` 은 건드리지 않는다
- **산출 계약** (이름은 제안 — 바꾸면 조각 8에 기록)
  - 진입 함수 `openRestoreCancelledModal(appId)`
  - 모달 id `restoreCancelledModal`, 사유 입력 id `restoreCancelledMemo`, 실행 버튼 id `restoreCancelledSubmit`. ESC 전역 처리기(`dev/js/ui.js` 486행)가 id 로 닫으므로 **id 필수**
  - 거부 코드 → 문구 표 `APP_RESTORE_ERROR_TEXT`: 10종 + 통신 실패(`null`) 1종
- **선행 의존**: 4·5 (확인 창 문구는 사양서 결정 8 반영)
- **완료 정의**
  - 버튼이 **213행(캠페인 진행현황)과 1049행(신청 관리)** 두 곳 취소 분기에 모두 있다(S-7)
  - 캠페인매니저 로그인 시 두 곳 모두 버튼 **없음**, 사유 코드 `withdrawal` 행에도 없음
  - 사유가 비면 실행 버튼 비활성
  - 제출 마감 안내는 사양서 ⑦의 문자열 비교(`new Date('연-월-일')` 파싱 없음)
  - 성공 시 알림 + 신청 관리 `refreshPane('applications')` / 진행현황 `refreshPane('camp-applicants')` + `loadAdminData()`(S-15). `on_hold_settlement_count > 0` 이면 정산 안내
  - 거부 10종이 **각자 다른 문구**, 「알 수 없는 오류」로 떨어지는 코드 0개
- **필요 검문소**: `reverb-reviewer` / 확인 창 문구는 `reverb-ui-copy` 스킬(관리자 한국어)
- **주의·롤백**
  - 새 코드는 `friendlyError`(`admin-core.js`, 핫스팟)에 넣지 않는다(S-12)
  - 원래 취소 정보는 `cancelDetailLinesHtml`(74행) 재사용. 두 로더가 이미 `ensureCancelReasonsCache()` 를 기다리므로 추가 조회 불필요

### 조각 7 — 인플루언서 알림 아이콘 + 명시 분기

- **하는 일**: 알림 목록 아이콘 지정 + 클릭 시 응모이력으로 가는 `kind` 한정 분기
- **담당 파일**: `dev/js/notifications.js`(295행 `iconMap`, 315~398행 `onNotifItemClick`)
- **산출 계약**
  - `iconMap.application_restored = {icon: …, color: …}`(Material Icons)
  - `if (kind === 'application_restored' && currentUser) { navigate('mypage', false); openMypageSub('applications'); refreshNotifBadge(); return; }` 형태
- **선행 의존**: 없음
- **완료 정의**: 조각 3에서 만든 알림이 개발서버 인플루언서 앱에 제목과 함께 보이고, 누르면 응모이력이 열리며 배지가 줄어든다
- **필요 검문소**: `reverb-reviewer`
- **주의·롤백**
  - 분기가 없어도 이미 응모이력으로 간다(S-11) — 목적은 **방어와 아이콘**
  - 알림 조회(`fetchMyNotifications`, `storage.js` 1225행)는 정산 두 종류만 걸러 **고칠 필요 없음**
  - iOS 하이브리드 앱 반영은 이번 범위 밖

### 조각 8 — 문서 한 세트

- **하는 일**: 기능 커밋과 **같은 병합 요청**에 문서(`.claude/rules/docs-tracking.md`)
- **담당 파일**: `CLAUDE.md`, `docs/FEATURE_SPEC.md`, 사양서 「구현 결과」
- **산출 계약**: 확정 마이그레이션 번호 2개 · 바꾼 이름 · 알림 종류 제약의 **다음 베이스 = 조각 1 파일** 한 줄 · `application_events` action 4종
- **선행 의존**: 1~7
- **완료 정의**: `CLAUDE.md` 의 `application_events`·`notifications` 서술이 새 값과 맞고, 옛 서술(「action 3종」)은 **덧붙이지 않고 고쳐 썼다**
- **필요 검문소**: `reverb-reviewer`
- **주의·롤백**: `CLAUDE.md` 는 동시 수정이 잦다 — 병합 직전 원격 dev 를 받아 충돌 해소

### 조각 9 — 개발서버 통합 검증 + dev 병합

- **하는 일**: 빌드 → 리뷰 → dev 병합 → 개발서버 화면 확인
- **담당 파일**: `bash dev/build.sh` 산출물
- **산출 계약**: 검증 결과를 사양서 「구현 결과」에 기록
- **선행 의존**: 3·6·7·8
- **완료 정의**
  - **사양서 「1-검증」 표의 나머지 행**(화면에서 누르는 것) 통과: `withdrawal_related` ②③ · `previous_status_not_restorable` · `campaign_deleted` · `event_campaign` · `active_application_exists` · `slots_full`. 표의 「확인 뒤 되돌림」까지
  - 승인·심사중 되돌리기 성공 **각 1건**
  - 인플루언서 앱 알림 클릭 이동 확인
  - 브라우저 확인은 좌표로 누르고 스크롤(사용자가 보이게)
- **필요 검문소**: `reverb-reviewer` GO / `reverb-qa-tester` **권장**(다른 세션이 브라우저 자동화를 안 쓸 때만)
- **주의·롤백**: dev 병합은 위임 범위. 운영 여부는 선택형 질문으로 사용자에게

### 조각 10 — 운영 DB 적용 + 확인

- **하는 일**: 운영 DB에 ①→② 순서로 적용. 🔴 **데이터베이스 먼저, 코드는 나중**
- **담당 파일**: 없음(운영 Supabase — 크롬 화면에서 **운영 서버인지 먼저 확인**)
- **산출 계약**: 「운영에 함수·제약·권한 3행이 있음」 확인 결과
- **선행 의존**: 9 + 사용자 승인
- **완료 정의**
  - 운영에서 두 제약과 권한 3행 조회 확인
  - 실제 로그인 브라우저에서 `has_permission('application.restore_cancelled','write')` 캠페인관리자 `true` / 캠페인매니저 `false`
  - 되돌리기 함수 자체는 **운영 실데이터로 부르지 않는다**(실제 요청이 있을 때만)
- **필요 검문소**: `reverb-supabase-expert`
- **주의·롤백**: 운영 선례 1건(`from_status='cancelled'` 인 `approve` 행)은 기존 값이라 제약 확장에 영향 없음. 편집기 탭은 `force` 이동 후 닫는다

### 조각 11 — 운영 코드 병합 + 확인 + 실무자 가이드

- **하는 일**: dev → main 병합 요청 → 운영 배포 → 확인 → Notion 갱신
- **담당 파일**: `main` 병합, Notion 「관리자 가이드」의 「신청 관리」 페이지(없으면 「캠페인 진행현황」)
- **산출 계약**: 운영 화면에 버튼, 실무자 가이드에 사용법·되돌릴 수 없음 경고
- **선행 의존**: **10의 확인 완료** + 사용자 승인
- **완료 정의**
  - `curl -sL` md5 를 `git show origin/main:admin/index.html` 과 대조(관리자·인플루언서 해시가 같으면 경보)
  - 운영 관리자 화면 취소 행에 버튼이 보이는 것까지 확인(**누르지 않음**)
  - Notion 정확성 게이트(운영 존재 확인·버튼 이름 「」 인용) 통과
- **필요 검문소**: `reverb-reviewer`
- **주의·롤백**: 코드만 되돌리려면 `git revert`. 함수는 남겨도 버튼이 없으면 안 쓰이므로 DB 롤백은 따로 판단

---

## ⚠️ 공유 지점 경고

1. **핫스팟 두 파일** — `dev/lib/shared.js`(조각 4), `dev/lib/storage.js`(조각 5). 다른 세션과 병렬로 나누지 않는다. 착수 전 이 두 파일을 고치는 열린 기능 브랜치가 있는지 확인
2. **`dev/admin/index.html`·`dev/js/admin-core.js` 는 이번에 건드리지 않는다** — 모달은 동적 생성, 문구 표는 화면 파일 안
3. **같은 열쇠말이 네 곳**(시드 · 함수 가드 · 카탈로그 · 서버 강제 목록), **같은 종류 이름이 세 곳**(제약 · 알림 insert · `notifications.js`) — 조각 9에서 철자를 나란히 대조
4. **행 그리기가 두 벌** — `admin-applications.js` 213행과 1049행. 한쪽만 고치면 화면마다 다르게 보인다
5. **알림 종류 제약의 다음 베이스가 바뀐다** — 이후 알림 종류를 추가하는 사람은 376 이 아니라 조각 1 파일을 베이스로(조각 8에 기록)
6. **인플루언서 일일 메일이 신청 표를 직접 읽는다** — 되돌리기 함수가 `reviewed_at` 을 건드리면 메일 동작이 바뀐다(S-8). 메일 함수는 고치지 않는다
7. **`CLAUDE.md`** — 동시 수정이 잦다(조각 8)

---

## 🧭 배분 제안

| 세션 | 조각 | 이유 |
|---|---|---|
| **개발 A (데이터베이스)** | 1 → 2 → 3, 이후 10 | 마이그레이션 번호는 한 세션에서만. 운영 적용도 파일을 만든 쪽이 |
| **개발 B (화면)** | 4 → 5 → 7 → (조각 3 완료 대기) → 6 → 8 → 9, 이후 11 | 핫스팟 두 파일을 한 세션이 연달아. 조각 6은 조각 3이 끝나야 실제 호출로 확인 가능 |

- 조각 7은 작고 독립적이라 B가 조각 3을 기다리는 동안 처리하면 된다
- **세션 2개로 충분하다** — 화면 쪽을 더 쪼개면 핫스팟 충돌만 는다
- 한 세션 순차로도 가능하다(총량이 크지 않다). 그 경우 순서는 1 → 2 → 3 → 4 → 5 → 7 → 6 → 8 → 9 → 10 → 11
