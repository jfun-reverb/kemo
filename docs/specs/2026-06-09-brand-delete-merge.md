# 브랜드 삭제 + 병합 기능

**작성일:** 2026-06-09

> 브랜드 관리(#brands)에 브랜드 삭제(연결 0건) + 다른 브랜드로 병합 기능 추가. 중복 등록 브랜드 정리용. (계기: BR-2026-0024 BENTON / BR-2026-0042 벤튼 중복)

## 현재 상태 (검증 완료)
- `dev/js/admin-brand.js` — 브랜드 자체 삭제/병합 **없음**(메모·담당자 삭제만). 참고: `admin-company.js` `deleteCompanyHard`(연결 0건 시 직접 delete — companies는 DELETE RLS 있음).
- **brands는 DELETE RLS 정책 없음**(082 의도적 — soft delete=archived 방침) → 직접 `db.from('brands').delete()`는 **무음 실패**. 삭제·병합은 **SECURITY DEFINER RPC 필수**.
- FK: `brand_applications.brand_id`→brands ON DELETE **RESTRICT** / `campaigns.brand_id`→brands ON DELETE **SET NULL** / 채번 카운터 2종 PK→brands ON DELETE **CASCADE**.
- 채번 `B{brand_seq}-A{app}-C{camp}`. 채번 트리거는 BEFORE INSERT 전용(`campaign_no IS NOT NULL` 가드) → 브랜드 바뀌면 RPC가 직접 재채번. 기존 `link_campaign_to_application`/`unlink`(advisory_xact_lock 2단·legacy_no 누적·numbering_legacy_map) 패턴 재사용.
- 173 트리거 `sync_campaign_brand_names()`는 brands name 변경에만 발화 — **brand_id 이동(병합)엔 미발화** → 병합 RPC가 campaigns.brand/brand_ja/brand_en 수동 동기화 필요.
- `sync_brand_application_stats`(082): brand_applications.brand_id 변경 시 양쪽 total_applications 자동 재집계(병합 시 추가 처리 불필요).
- brands RLS: SELECT/CUD `is_campaign_admin()` 이상. 마지막 마이그레이션 173.

## 의심·경우의 수 (요약)
1. [데이터] 신청 파생 캠페인은 신청을 먼저 옮겨야 A세그먼트 채번 정합 → **부분 병합 불가, 브랜드 통째 병합만**.
2. [데이터] A-seq/C-seq >999 오버플로 가드(121 패턴 보유).
3. [동시성] 병합 중 신규 INSERT → advisory_xact_lock 양쪽(uuid 작은쪽 먼저).
4. [UX] 되돌릴 수 없는 병합 — 확인 모달에 방향(원본→대상)·옮길 캠페인 N·신청 M·번호 재발급·옛 번호 보존·복구불가 명시 의무.
5. [권한] campaign_manager에 버튼 노출 시 권한 에러 → 버튼 `isCampaignAdminOrAbove` 숨김 + RPC 가드 이중.

## 사용자 확정 결정 (2026-06-09)
- 병합 범위: **브랜드 통째**(신청+캠페인 전부 이동·재채번)
- 병합 후 원본: **보관 처리(archived)** — 완전 삭제 아님
- 회사 일치: **같은 company_id만 허용** (다르면 차단)
- 삭제 조건: **연결 0건만 hard delete**, 연결 있으면 병합 유도
- 진행 순서: **PR 1 삭제 먼저 → PR 2 병합 나중**

## 설계

### PR 1 — 브랜드 삭제 (연결 0건)
- 신규 마이그레이션 1개: `delete_brand(p_brand_id uuid)` RPC — `is_campaign_admin()` 가드 + 연결(campaigns·brand_applications) 0건 검증 후 hard delete. 0건 아니면 22023 에러(병합 안내). SECURITY DEFINER + search_path=''. 카운터 CASCADE 자동 정리.
- `dev/lib/storage.js`: `deleteBrand(brandId)` 래퍼(RPC 호출).
- `dev/js/admin-brand.js`: 브랜드 상세 모달에 삭제 버튼(연결 0건일 때만 노출 — 모달 열 때 campaigns count 조회 + total_applications) + 확인 모달. `isCampaignAdminOrAbove` 분기. 저장 후 `refreshPane('brands')`.

### PR 2 — 브랜드 병합 (PR 1 운영 배포 후)
- 신규 마이그레이션 1개: `merge_brands(p_source uuid, p_target uuid)` RPC — 같은 company_id 검증, advisory_xact_lock 2단, 신청→캠페인 순 brand_id 이동 + 재채번(legacy_no 누적·numbering_legacy_map) + campaigns brand/brand_ja/brand_en 동기화 + 원본 archived. jsonb 반환(moved_apps/moved_campaigns). 121 패턴 재사용.
- 병합 모달(대상 드롭다운 + 영향 요약 N·M + 되돌리기 불가 경고). storage 래퍼.

## 약관 영향
- 브랜드명=사업자 상호(개인정보 아님). brand_applications 담당자 연락처는 이동일 뿐 수집항목·목적 무변화 → 약관 변경 불요. 운영 배포 후 /약관확인 권고.

## 구현 결과 — PR 1 (브랜드 삭제, 연결 0건)

**구현일:** 2026-06-09
**브랜치:** feature/brand-delete

- 마이그레이션 **174** `delete_brand_rpc.sql` — `delete_brand(p_brand_id uuid)` RPC. is_campaign_admin 가드 + 연결(campaigns·brand_applications) 0건 검증 후 hard delete. 0건 아니면 22023(병합 안내). SECURITY DEFINER + search_path=''. 카운터 CASCADE 자동.
- `dev/lib/storage.js` — `deleteBrand(brandId)`(delete_brand RPC 래퍼, retryWithRefresh) + `countCampaignsByBrand(brandId)`(삭제 버튼 사전 판정용, 실제 차단은 RPC 재검증).
- `dev/js/admin-brand.js` — 상세 모달 footer에 삭제 버튼(`apps.length===0 && campCount===0 && isCampaignAdminOrAbove()` 일 때만 노출) + `deleteBrandConfirm()`(confirm → deleteBrand → toast → refreshPane('brands')).
- `shared.js` PANE_REFRESHERS 'brands'는 **이미 등록돼 있어** 추가 불필요(reviewer가 중복 지적 → 회수).

### 초안 대비
- confirm() 유지(프로젝트에 확인 모달 헬퍼 없음, 회사·메모 삭제도 confirm 패턴).
- 권한 분기 폴백을 안전 방향(함수 미존재=false)으로 수정(reviewer Critical).

### 검증
- reverb-supabase-expert: 174 블로커 없음(search_path·가드·멱등성 통과, campaigns SET NULL race는 0건 가드로 차단).
- reverb-reviewer GO(Critical 2건 수정 후 재GO). qa 권장 light.

### PR 2 (병합) — 미착수
- merge_brands RPC + 병합 모달. PR 1 운영 배포 후.

## 구현 결과 — PR 2 (개발 세션이 채울 것)
