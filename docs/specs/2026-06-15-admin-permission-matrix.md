# 관리자 등급별 권한 매트릭스 + 화면↔서버 불일치 점검

**작성일:** 2026-06-15
**작성 세션:** 기획/설계 (전수 감사)
**목적:** 코드 곳곳에 흩어진 관리자 등급별 권한을 한 표로 모으고, 「화면에선 막혔는데 서버는 안 막힌」(또는 반대) 불일치(갭)를 찾아 개선 백로그화. **이 문서는 현황 정리·감사이며, 코드 변경은 갭 확정 후 별도.**
**범위:** 관리자 3등급(super_admin > campaign_admin > campaign_manager) 중심. 인플루언서/비로그인(anon)은 비교용 보조.

---

## 현재 상태 (작성일 기준, 전수 조사 근거)

### 권한 판정 함수

**서버(행 단위 보안 정책·원격 함수에서 사용):**
| 함수 | 정의(최종) | 의미 | 비고 |
|---|---|---|---|
| `is_admin()` | `018_fix_is_admin.sql` | admins 테이블에 있는 **전 관리자**(3등급 모두) | `search_path=''` ✓ |
| `is_super_admin()` | `008_create_admins.sql` | role = `super_admin`만 | `search_path=''` ✓ |
| `is_campaign_admin()` | `024_create_lookup_values.sql` | role ∈ {`super_admin`,`campaign_admin`} (manager 제외) | ⚠️ `search_path='public, pg_temp'` — 다른 함수의 `''`와 불일치 |

**클라이언트:**
| 헬퍼 | 정의 | 의미 |
|---|---|---|
| `isCampaignAdminOrAbove()` | `dev/js/admin-accounts.js:182` | `currentAdminInfo.role` ∈ {super_admin, campaign_admin} |
| `currentAdminInfo.role` | `admin-core.js:612` 선언 / accounts에서 할당 | DB admins.role |
| 메시지용 `admMsgIsCampaignAdmin()` | `admin-messaging.js:1056` | 위와 동일 판정(중복 정의) |

---

## 등급별 매트릭스 (메뉴 노출 / 클라 게이트 / 서버 차단 3축)

범례: ✓=가능·노출 / ✗=불가·숨김 / 🔓=**서버는 열려 있음(데이터 접근 가능)**

### A. 사이드바 메뉴 노출
| 메뉴 | super_admin | campaign_admin | campaign_manager | 근거 |
|---|:--:|:--:|:--:|---|
| 공지·대시보드·운영현황·캠페인·신청·결과물·메시지·브랜드(현황/회사/브랜드/신청)·인플루언서·관리자계정·오류로그·내계정 | ✓ | ✓ | ✓ | 분기 없음 |
| **기준 데이터(lookups)** | ✓ | ✓ | ✗ 숨김 | `admin-accounts.js:186` |
| **자주 묻는 질문(FAQ)** | ✓ | ✓ | ✗ 숨김 | `admin-accounts.js:186` |

### B. 기능별 권한 (클라 게이트 + 서버 차단)
| 기능 | super | camp_admin | camp_manager | 서버 차단(RLS/RPC) | 일치? |
|---|:--:|:--:|:--:|---|:--:|
| 캠페인 생성·수정·삭제 | ✓ | ✓ | **✓** | `campaigns` CUD = `is_admin()`(전체) | 클·서 일치(둘 다 manager 허용) |
| 신청 승인·반려 | ✓ | ✓ | **✓** | `applications` UPDATE = `is_admin()` | 클·서 일치(manager 허용) |
| 신청 목록 정렬 버튼 | ✓ | ✓ | ✗ | (서버 무관) | 클라만 제한 |
| 결과물 영수증 수정 | ✓ | ✓ | ✗ | `update_receipt_admin` = `is_campaign_admin()` | 일치 |
| 결과물 대리 등록 | ✓ | ✓ | ✗ | (RPC 가드) | 일치 |
| 회사 등록·수정·삭제 | ✓ | ✓ | ✗ | `companies` CUD = `is_campaign_admin()` | 일치 |
| 회사 **열람** | ✓ | ✓ | **✓ 🔓** | `companies` SELECT = `is_admin()`(전체) | manager도 열람(민감도 낮음) |
| 브랜드 삭제·병합 | ✓ | ✓ | ✗ | `delete_brand`/`merge_brands` = `is_campaign_admin()` | 일치 |
| 기준데이터 CRUD | ✓ | ✓ | ✗ | `lookup_values` CUD = `is_campaign_admin()` | 일치 |
| FAQ CRUD | ✓ | ✓ | ✗ | `faq_nodes` CUD = `is_campaign_admin()` | 일치 |
| 인플루언서 인증·블랙리스트·위반 | ✓ | ✓ | ✗ | `set_influencer_*`/`update_influencer_violation` = `is_campaign_admin()` | 일치 |
| 인플루언서 **전체 데이터 열람**(민감정보 포함) | ✓ | ✓ | **✓ 🔓** | `influencers` SELECT = `is_admin()`(전체) + `fetchInfluencers`가 `select('*')` | ⚠️ **불일치(아래 갭1)** |
| 인플루언서 민감정보 엑셀 출력 | ✓ | ✓ | ✗(체크박스 숨김) | (서버 차단 없음) | ⚠️ 화면만 제한 |
| 일괄 메시지 발송·발송이력 | ✓ | ✓ | ✗(버튼/탭 숨김) | `send_application_message_bulk` 등 | 클라 숨김(서버 가드 확인 권장) |
| 메시지 강제 숨김 | ✓ | ✓ | ✗ | `hide_application_message` = campaign_admin | 일치 |
| 메시지 숨김 **복구** | ✓ | ✗ | ✗ | `unhide_application_message` = super_admin | 일치 |
| 공지 작성 | ✓ | ✓ | ✗ | `admin_notices` INSERT = `is_campaign_admin()` | 일치 |
| 공지 수정·게시·회수 | ✓(전체) | 본인 작성분만 | 본인 작성분만 | UPDATE = `is_campaign_admin() AND (is_super_admin() OR 작성자)` | 일치 |
| 캠페인 변경 이력(주의사항 audit) 열람 | ✓ | ✗ | ✗ | `campaign_caution_history` SELECT = `is_super_admin()` | 일치 |
| 관리자 추가·삭제 | ✓ | ✗ | ✗ | `invite_admin`/`delete_admin_completely` = `is_super_admin()` | 일치 |
| 다른 관리자 메일 구독 설정 | ✓ | ✗(본인만) | ✗(본인만) | `admin_email_subscriptions` CUD = 본인 or super | 일치 |

---

## 화면↔서버 불일치 / 갭 (개선 백로그)

### 갭1 — 인플루언서 민감정보가 campaign_manager에게도 서버 노출 (P1, 개인정보)
- **현상**: `influencers` SELECT 정책 = `is_admin()`(전 관리자) + `fetchInfluencers`가 `select('*')`로 전화·주소·PayPal 등 **민감정보 전부**를 받아옴. 화면에선 민감정보 엑셀 체크박스를 campaign_admin 이상만 보이게 막지만, **데이터 자체는 campaign_manager 브라우저 메모리에 이미 존재**.
- **위험**: 개인정보 최소노출 원칙 위배 소지. campaign_manager가 개발자도구·네트워크 탭으로 민감정보 직접 확인 가능. 한국 개인정보보호법·일본 개인정보보호법 접근권한 최소화 관점 취약.
- **개선 방향(후보)**: ① 민감 컬럼 마스킹 뷰 + 등급별 RLS ② `fetchInfluencers`를 등급별 컬럼 분리 fetch ③ 민감정보 조회 전용 RPC(campaign_admin 가드). **DB·코드 변경 큰 작업 → 별도 사양 필요.**
- 기존 메모리에도 "실차단은 RLS/뷰 컬럼 마스킹 별도 과제"로 기록됨.

### 갭2 — campaign_manager의 캠페인 CUD·신청 승인 권한 (✅ 정책 확정: 현행 유지)
- **현상**: `campaigns` CUD·`applications` 상태변경이 서버·클라 양쪽에서 `is_admin()`(전체) → campaign_manager도 캠페인을 만들고/수정/삭제하고 신청을 승인·반려할 수 있음.
- **결정(2026-06-15 사용자 확정)**: **현행 유지 — 의도된 설계.** campaign_manager는 실무 운영자라 캠페인·신청 운영은 다룬다. 클·서 일치라 불일치 아님. 더 이상 갭 아님(정책 명문화 완료).

### 갭3 — `is_campaign_admin()` search_path 불일치 (P3, 보안 일관성)
- **현상**: `is_campaign_admin()`만 `SET search_path='public, pg_temp'`, 나머지 권한 함수는 `''`(권장).
- **위험**: 보안 규칙(`.claude/rules/security.md` "SECURITY DEFINER는 search_path='' 필수")과 어긋남. 탈취 방어 약화 소지. **마이그레이션 1개로 정정 가능(작은 작업).**

### 갭4 — 회사/감사이력 열람 범위 (P4, 정보·의도 추정)
- `companies` SELECT = 전 관리자(manager 열람 가능). 민감도 낮아 의도로 보이나 명문화 안 됨.
- `campaign_caution_history` SELECT = super_admin만 → campaign_admin은 자기 변경 이력도 못 봄. 현재 클라도 super 한정이라 일치하나, campaign_admin에게 열어줄지 정책 확인 여지.

---

## 정책 확인 (사용자 결정)
1. ✅ **campaign_manager의 범위**: 캠페인 CUD·신청 승인 **현행 유지로 확정**(2026-06-15) — 의도된 설계. 갭2 종결.
2. ✅ **갭1(인플 민감정보)**: **동적 권한 관리 사양(`2026-06-15-admin-permission-management.md`) 2단계로 흡수** — 서버 차단 최우선 대상. 단독 처리 대신 권한 체계 전환에 통합.
3. **갭3(search_path) 정정**: 위 권한 관리 사양 PR 1(DB 마이그레이션)에 함께 끼워넣기 권고(작은 정정).

> ※ 이 매트릭스는 동적 권한 관리(`2026-06-15-admin-permission-management.md`)의 **1단계 기본값 시드**로 사용된다 — 설정 테이블 초기값이 현행 매트릭스와 동일하면 도입 즉시 동작 변화 없음.

---

## 제안 — 산출물 활용
- 이 문서를 관리자 권한 **단일 레퍼런스**로 유지. 권한 변경 시 이 표를 갱신(개발 세션 의무화 권고).
- 위 갭1~4 중 착수할 것은 **개별 사양서로 분리**(특히 갭1은 DB 설계가 커서 단독 사양 필요).

---

## 구현 결과
(이 문서는 감사·정리 산출물 — 코드 변경 없음. 갭 개선은 각각 별도 사양서에서 추적)
