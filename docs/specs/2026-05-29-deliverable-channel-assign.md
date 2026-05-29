# 채널 미지정 리뷰 이미지 → 채널 지정 기능

**작성일:** 2026-05-29
**작성 주체:** reverb-planner (기획 세션) + 개발 세션 보정
**상태:** 기획 완료 (개발 미착수)
**관련 사양서:** `docs/specs/2026-05-28-multichannel-deliverable-split.md`(채널별 분리), `docs/specs/2026-05-28-admin-proxy-deliverable.md`(대리 등록 RPC 패턴)
**관련 패치:** `supabase/patches/2026-05-29-backfill-review-image-post-channel.sql`(단일채널 367건 백필 — 운영 적용 완료)

> **개발 세션 보정 (2026-05-29):** 채널별 분리(사양 1·2)는 **이미 운영 배포된 상태**임을 운영서버에서 직접 확인(검수 모달 STEP1/STEP2·채널별 셀 노출). planner가 메모리("운영 보류") 기반으로 단 §5 운영 배포 전제는 해소됨. 본 기능도 운영 배포 대상.

---

## 1. 현재 상태 (planning.md 규칙 A — 직접 검증 완료)

### 1-1. 관련 코드·DB·UI 진입점 (실제 읽고 확인)

| 영역 | 위치 | 현재 동작 (확인 결과) |
|---|---|---|
| 결과물 그룹화 | `dev/js/admin-deliverables.js` 156~208 | `kind='review_image'` 중 `d.post_channel`이 **있으면** `g.reviewByChannel[code]`에 매핑, **NULL이면** `g.hasLegacyReviewImage=true` 플래그만 세움(169~171). 실제 행은 어디에도 안 담김 |
| 대표 상태 계산 | 같은 파일 190~208 | 채널별 미제출이면서 레거시 NULL 행 있으면 `result_status_repr='legacy_no_channel'`(이미 존재) |
| 결과 상태 필터 카운트 | 239 | `resultStatusCounts`에 `legacy_no_channel:0` 키 이미 존재 — "채널 미분류" 필터 이미 가동 중 |
| monitor 결과물 셀 | `renderDelivResultCellMonitor` 429~467 | 캠페인 채널별 미니 행만 그림. NULL 레거시 행은 **셀에 표시 안 됨** |
| 검수 모달 본문 | `renderDelivCombinedBody` 742~916 | 802 `.filter(d => d.kind==='review_image' && d.post_channel)` — **NULL 행은 모달에서 완전 누락** |
| 패널 본문 | `renderDelivPanelContent` 1111~ | 이미지/메타/이력/액션. `d` 없으면 "아직 제출되지 않았습니다" |
| 검수 처리 | `approveDeliv`/`revertDeliv`/`submitDelivReject` 601~711 | `updateDeliverableStatus` 호출 → 끝에서 `renderDelivCombinedBody(_delivCombinedRefreshAppId)` 재렌더 |
| 대리 등록 RPC 패턴 | 마이그레이션 160 + `storage.js` 875~915 | `admin_create_deliverable_proxy`(is_campaign_admin 가드, FOR UPDATE 잠금, UNIQUE 사전 체크, audit + 알림), `admin_revoke_proxy_deliverable`(super_admin) |
| 영수증 인플레이스 수정 RPC | `update_receipt_admin` + `updateReceiptAdmin`(storage.js 851) | campaign_admin 가드, `receipt_edit_history` audit — **본 기능 RPC의 참고 모델** |
| 채널 코드 체계 | `lookup_values.kind='channel'`의 `code` | 예: `qoo10`, `channel-96r9y3`(@cosme). `getLookupLabel('channel', code, 'ko')`로 라벨 변환 |
| 부분 유니크 인덱스 | 마이그레이션 158 | `deliverables_review_image_app_channel_uniq ON (application_id, post_channel) WHERE kind='review_image' AND post_channel IS NOT NULL` — **채널 지정 시 충돌 핵심** |
| 알림 트리거 | 마이그레이션 159 `notify_deliverable_status()` | `status` 전이에만 발화(`IF OLD.status = NEW.status THEN RETURN`). **post_channel만 UPDATE하면 알림 안 나감**(상태 불변) — 본 기능에 유리 |

### 1-2. 이 제안과 충돌 가능성 있는 기존 동작

1. **마이그레이션 158 유니크 인덱스 충돌** — 이미 채워진 채널로 또 지정하면 23505. 드롭다운을 "그 신청에 아직 안 채워진 채널만"으로 제한 + RPC 사전 체크로 방어(§4-2).
2. **알림 트리거(159)와의 상호작용** — 본 기능은 NULL→채널 코드로 `post_channel`만 바꾸고 `status`는 안 건드림 → 트리거 미발화. status도 함께 바꾸면 알림 발화. 채널 지정은 "상태 변경 없음"으로 격리(§4-1).
3. **`renderDelivResultCellMonitor`/`renderDelivCombinedBody`의 post_channel 필터** — NULL 행을 현재 의도적으로 배제. 본 기능은 "별도 영역"으로 우회 노출(기존 채널 패널 로직 불변). 충돌이라기보다 누락 보완.

→ **결론: 기존 동작과 직접 충돌 없음.** 단 158 유니크·159 트리거 두 지점을 설계에서 반영.

### 1-3. 미해결 백로그·관련 작업

- `project_multichannel_deliverable.md`: 사양 1·2 dev 22 PR 머지. (개발 세션 확인: 운영 배포 완료 상태)
- `project_admin_proxy_deliverable.md`: 묶음 A(160·161) 운영 출시 완료. 운영 진단 "레거시 채널NULL 385" — 백필로 367(단일채널) 해결, **다채널 26건 + 중복 2건이 본 기능 대상**.
- 마이그레이션 최신: 160·161 운영 적용. 본 기능 신규 번호는 개발 세션이 `ls supabase/migrations/` 재확인 후 확정.

---

## 2. 의심·경우의 수 (planning.md 규칙 B — 반대론자 모드)

### 2-1. 깨질 수 있는 경우의 수

**[기술] ① 유니크 충돌 (158)** — 빈 채널 0개 신청에서 NULL 지정 시 23505. "안 채워진 채널만" 드롭다운 + RPC 재검증.

**[데이터] ② 둘 다 채워진 신청의 추가 NULL 행 (중복 2건)** — 지정 가능 채널 0개 → 삭제/방치 결정 필요(§4-4).

**[기술] ③ 동시성** — 두 관리자가 같은 NULL 행 동시 지정 → FOR UPDATE 직렬화, 후순위 친화적 에러.

**[권한] ④ campaign_manager 노출** — 채널 지정은 데이터 정정 → campaign_admin 이상. manager는 읽기 전용/숨김(§4-3).

**[기술] ⑤ 오지정 되돌리기** — NULL 복귀 + 재지정 경로 필요(§4-5). 검수 완료(approved/rejected) 행은 해제 차단.

**[UX — 필수] ⑥ 검수 모달에 "채널 미분류" 영역 위치** — 채널 패널과 섞으면 혼동. 별도 회색 박스 + 이미지 + 빈 채널 드롭다운 + 지정 버튼. 빈 상태면 영역 미표시.

**[UX] ⑦ 셀에서 존재를 모름** — "채널 미분류" 필터로 추려 검수 모달 진입. 셀에 "미분류 N" 칩 추가 검토(§4-6).

**[법률·약관] ⑧ 영향 없음** — 내부 데이터 정정. 수집·제3자·정산 변동 없음.

### 2-2. 현재 구현 충돌점

**확인 완료 — 직접 충돌 없음.** §1-2의 3개 지점(158 유니크 / 159 트리거 / post_channel 필터) 설계 반영. 기존 로직 불변, "채널 미분류" 영역만 추가하는 가산 설계.

### 2-3. 사용자 의도와 다르게 해석될 수 있는 부분

1. "채널 지정"의 범위 — 채널만 채움(검수 별도) vs 지정+검수 동시. 권장 전자(§6 Q1).
2. 상시 기능 vs 레거시 소진 후 제거(§6 Q3).
3. 빈 채널 0개 NULL 행 처리 — 방치/삭제/숨김(§6 Q2).
4. 권한 경계 — manager 읽기 전용 vs 숨김(§6 Q4).

### 2-4. 권고

신규 마이그레이션 1개(채널 지정 전용 RPC + audit)와 검수 모달 하단 "채널 미분류" 조건부 영역만 추가하는 **가산 설계**를 권한다. post_channel만 UPDATE(상태 불변)해 159 트리거를 안 건드리고, 158 유니크는 "빈 채널만 드롭다운 + RPC 재검증"으로 방어, NULL 행 0건이면 영역 자동 소멸이라 별도 제거 불필요.

---

## 3. 제안 / 설계

### 3-1. 전체 흐름

```
1. 운영자: 결과물 관리 페인 → 결과 상태 필터 「채널 미분류」 선택 (이미 가동 중)
2. 미분류 목록 → 각 행 「검수」 버튼 클릭
3. 검수 모달 하단 「채널 미지정 리뷰 이미지」 회색 영역 노출
   - NULL review_image 행마다: [이미지 썸네일] [빈 채널 드롭다운] [이 채널로 지정]
   - 이미지 클릭 → 라이트박스 확대(openImageLightbox 재사용)
4. 운영자: 이미지 육안 확인 → 채널 선택 → 「이 채널로 지정」
5. RPC assign_review_image_channel → post_channel UPDATE (status 불변)
6. 모달 재렌더 → 그 행이 미분류 영역에서 사라지고 정상 채널 패널로 이동
7. 정상 채널 패널에서 기존 승인/반려로 검수
```

### 3-2. UI 와이어프레임

```
┌─ [B0123-C045] 코스메 캠페인 · 田中花子 ──────────────────────┐
│  ┌─영수증 STEP1─┐ ┌─「Qoo10」리뷰 STEP2─┐ ┌─「@cosme」리뷰─┐  │
│  │ [영수증이미지] │ │ [이미지] 검수대기    │ │ 아직 제출 안됨 │  │
│  └──────────────┘ └────────────────────┘ └──────────────┘  │
│  ┌─ ⚠ 채널 미지정 리뷰 이미지 (2건) ───────────────────────┐  │
│  │ 이 이미지들은 채널 정보 없이 제출되었습니다.              │  │
│  │ 이미지를 확인하고 어느 채널의 리뷰인지 지정해 주세요.     │  │
│  │ [썸네일64] 제출일 2026-05-10  채널[▾ @cosme] [지정]      │  │
│  │ [썸네일64] 제출일 2026-05-10  지정 가능 채널 없음         │  │
│  │            (모든 채널 채워짐) [super_admin: 삭제] (옵션)  │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

드롭다운 옵션 = `campChannels` 중 `reviewByChannel`에 이미 매칭 안 된 코드만. 라벨 = `getLookupLabel('channel', code, 'ko')`.

### 3-3. 데이터 흐름 — post_channel만 UPDATE (상태 불변)

- 지정 = `UPDATE deliverables SET post_channel=:code WHERE id=:id AND kind='review_image' AND post_channel IS NULL`
- status·reviewed_* 미변경 → 159 트리거 미발화(알림 없음)
- 지정 후 `g.reviewByChannel[code]`에 정상 매칭 → 채널 패널 이동 → 기존 검수

---

## 4. 핵심 설계 결정

### 4-1. 채널 지정과 검수의 분리 (권장)
RPC는 post_channel만 채운다. 검수는 지정 후 채널 패널 기존 버튼으로. 이유: 159 트리거 격리, 2단계 명확성, RPC 단순화.

### 4-2. 유니크 충돌 방어 (158)
- UI: 드롭다운에 `campChannels` − `Object.keys(reviewByCh)`만
- RPC: 대상 행 NULL 여부 + p_channel 캠페인 채널 소속 + 같은 신청 채널 중복 사전 체크 → 친화적 23505. FOR UPDATE.

### 4-3. 권한
- RPC: `is_campaign_admin()` 이상. manager 차단.
- UI: manager는 읽기 전용 or 숨김(§6 Q4).

### 4-4. 빈 채널 0개 NULL 행 (중복 2건)
- A. 방치(안내만) / B. super_admin 삭제 RPC + audit / C. 교체(비권장)
- 권장: **A 기본 + B 옵션**(§6 Q2).

### 4-5. 오지정 되돌리기
- 채널 패널에 "해제" 버튼(campaign_admin) → post_channel NULL 복귀 RPC → 미분류 영역 재출현.
- **검수 완료(approved/rejected) 행은 해제 차단**. pending·draft만 허용.

### 4-6. 셀 표식 (옵션)
`renderDelivResultCellMonitor`에 `hasLegacyReviewImage`면 "⚠ 채널 미분류 N" 회색 칩(§6 Q5).

### 4-7. 신규 RPC 시그니처 제안

```sql
-- 마이그레이션 번호: 개발 세션이 ls supabase/migrations/ 재확인 후 확정 (160·161 운영 적용됨)

CREATE OR REPLACE FUNCTION public.assign_review_image_channel(
  p_deliverable_id uuid,
  p_post_channel   text   -- NULL/'' = 해제로 동작
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_app_id uuid; v_camp_id uuid; v_kind text; v_status text; v_cur_channel text;
  v_camp_channels text[];
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다. campaign_admin 이상이 필요합니다.' USING ERRCODE='42501';
  END IF;
  SELECT application_id, campaign_id, kind, status, post_channel
    INTO v_app_id, v_camp_id, v_kind, v_status, v_cur_channel
    FROM public.deliverables WHERE id = p_deliverable_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION '결과물을 찾을 수 없습니다.' USING ERRCODE='P0002'; END IF;
  IF v_kind <> 'review_image' THEN
    RAISE EXCEPTION '리뷰 이미지 행만 채널 지정이 가능합니다.' USING ERRCODE='P0001'; END IF;

  IF p_post_channel IS NOT NULL AND trim(p_post_channel) <> '' THEN
    IF v_cur_channel IS NOT NULL THEN
      RAISE EXCEPTION '이미 채널이 지정된 행입니다. 먼저 해제하세요.' USING ERRCODE='P0001'; END IF;
    SELECT string_to_array(channel, ',') INTO v_camp_channels FROM public.campaigns WHERE id = v_camp_id;
    IF NOT (p_post_channel = ANY (v_camp_channels)) THEN
      RAISE EXCEPTION '이 캠페인의 채널이 아닙니다: %', p_post_channel USING ERRCODE='22023'; END IF;
    IF EXISTS (SELECT 1 FROM public.deliverables
                WHERE application_id = v_app_id AND kind='review_image' AND post_channel = p_post_channel) THEN
      RAISE EXCEPTION '해당 채널의 리뷰 이미지가 이미 있습니다: %', p_post_channel USING ERRCODE='23505'; END IF;
    UPDATE public.deliverables SET post_channel = p_post_channel WHERE id = p_deliverable_id;  -- status 불변
  ELSE
    IF v_status NOT IN ('pending','draft') THEN
      RAISE EXCEPTION '검수 완료된 행은 채널을 해제할 수 없습니다.' USING ERRCODE='P0001'; END IF;
    UPDATE public.deliverables SET post_channel = NULL WHERE id = p_deliverable_id;
  END IF;

  INSERT INTO public.deliverable_events (deliverable_id, actor_id, action, from_status, to_status, reason)
  VALUES (p_deliverable_id, auth.uid(),
          CASE WHEN p_post_channel IS NULL OR trim(p_post_channel)='' THEN 'channel_unassign' ELSE 'channel_assign' END,
          v_status, v_status,
          '채널: '||COALESCE(v_cur_channel,'(없음)')||' → '||COALESCE(NULLIF(trim(p_post_channel),''),'(해제)'));
END;
$$;
REVOKE ALL ON FUNCTION public.assign_review_image_channel(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assign_review_image_channel(uuid, text) TO authenticated;
```

추가:
- `deliverable_events` action CHECK에 `'channel_assign'`/`'channel_unassign'` 2종 추가(160의 7종 → 9종). DROP/ADD 멱등.
- `renderDeliverableEventsTimeline` labelMap에 `channel_assign:'채널 지정'`/`channel_unassign:'채널 해제'`.
- (옵션 B) `delete_legacy_review_image(p_deliverable_id, p_reason)` super_admin 삭제 RPC + audit.

### 4-8. storage.js 함수

```js
async function assignReviewImageChannel(deliverableId, postChannel) {
  if (!db) throw new Error('DB 미연결');
  let ok = false;
  await retryWithRefresh(async () => {
    const {error} = await db.rpc('assign_review_image_channel', {
      p_deliverable_id: deliverableId,
      p_post_channel: postChannel || null
    });
    if (error) throw error;
    ok = true;
  });
  return ok;
}
```

---

## 5. PR 분할

| PR | 제목 | 내용 | 의존 |
|---|---|---|---|
| PR 1 | 채널 지정 RPC + audit (신규 마이그레이션) | `assign_review_image_channel`, `deliverable_events` action CHECK 2종, (옵션) `delete_legacy_review_image`. 개발 DB 적용 + 스모크(NULL→채널/충돌/권한) | — |
| PR 2 | 검수 모달 "채널 미분류" 영역 + storage 함수 | `renderDelivCombinedBody` NULL 행 영역, 드롭다운(빈 채널만), 지정 버튼 → `assignReviewImageChannel` → 재렌더. labelMap 2종 | PR 1 |
| PR 3 (옵션) | 셀 "채널 미분류 N" 칩 + 해제 버튼 | `renderDelivResultCellMonitor` 칩, 채널 패널 pending/draft 해제 버튼 | PR 2 |

운영 배포: 채널별 분리 이미 운영 배포됨(개발 세션 확인) → 본 기능도 운영 배포 대상. 마이그레이션은 개발 먼저 → 검증 → 운영 SQL Editor 수동 적용.

---

## 6. 사용자 확인 필요 (AskUserQuestion 변환 대상)

- **Q1 지정·검수 분리**: 채널만 지정(검수 별도, 추천) vs 지정+검수 동시
- **Q2 중복 행 처리**: 방치+삭제옵션(추천) vs 그냥 방치 vs 최고관리자 삭제만
- **Q3 상시·임시**: 조건부 상시(추천) vs 정리 후 코드 제거
- **Q4 중간관리자 권한**: 읽기 전용 표시(추천) vs 영역 숨김
- **Q5 셀 표식**: 표식 추가(추천) vs 필터만 사용

---

## 7. QA 시나리오

| # | 시나리오 | 기대 |
|---|---|---|
| 1 | 다채널 2채널 신청, 둘 다 NULL | 미분류 영역 1행 + 드롭다운 2채널 |
| 2 | 채널 A 지정 | post_channel=A, status 불변, 알림 미생성, 채널 A 패널 이동·미분류 사라짐 |
| 3 | 이미 채워진 채널 재지정 시도 | 드롭다운에 없음. 강제 호출 시 23505 친화적 에러 |
| 4 | 빈 채널 0개 NULL 행 | "지정 가능 채널 없음" + (옵션) super_admin 삭제 |
| 5 | 동시 지정 | FOR UPDATE 직렬화, 후순위 "이미 처리됨" |
| 6 | campaign_manager 진입 | 읽기 전용(또는 숨김, Q4) |
| 7 | pending 지정 → 채널 패널 승인 | 159 트리거로 채널 라벨 포함 승인 알림 1건 |
| 8 | 오지정 → 해제(pending) | post_channel NULL 복귀, audit channel_unassign, 미분류 재출현 |
| 9 | approved 행 해제 시도 | 차단 |
| 10 | NULL 0건 신청 검수 | 미분류 영역 미표시 |
| 11 | audit 확인 | deliverable_events channel_assign/unassign 기록, 타임라인 한국어 라벨 |

---

## 8. 영향 범위

| 파일 | 변경 |
|---|---|
| `supabase/migrations/16N_*.sql`(신규) | RPC + deliverable_events CHECK 2종 + (옵션) 삭제 RPC |
| `dev/lib/storage.js` | `assignReviewImageChannel`, (옵션) `deleteLegacyReviewImage` |
| `dev/js/admin-deliverables.js` | `renderDelivCombinedBody`(미분류 영역), `renderDeliverableEventsTimeline`(labelMap), (옵션) 셀 칩·해제 버튼 |
| 약관·개인정보 | 영향 없음 |
| CLAUDE.md / FEATURE_SPEC.md | deliverable_events action 종류·채널 지정 기능 반영(개발 세션 의무) |

빌드: 기존 파일 수정만 → build.sh 등록 불필요, `bash dev/build.sh` 실행.

---

## 9. 구현 결과

**구현일:** 2026-05-29
**관련 커밋/PR:** dev PR #373(마이그 162 + storage + UI) → 운영 dev→main PR #374. 백필 패치는 운영 직접 적용.

### 초안 대비 변경 사항
- 추가된 것: 단일채널 백필 패치(`supabase/patches/2026-05-29-backfill-...sql`, 운영 340행 적용) — 다채널 채널지정 RPC와 별개로 단일채널 367건은 데이터 백필로 즉시 해결(NOT EXISTS + DISTINCT ON 충돌 회피). 사용자 결정으로 구버전 NULL 29건은 삭제 안 하고 보존(과거 제출·승인 이력).
- 빠진 것: PR 3(오지정 해제 버튼 + 셀 "채널 미분류 N" 칩) — 백로그.
- 달라진 것: 없음(설계 5종 추천안 전체 수용).

### 구현 중 기술 결정 사항
- **확정 마이그레이션 번호: 162** (admin-proxy PR 5는 163으로 밀림 — 메모리 정정).
- delete RPC의 audit INSERT 제거(CASCADE로 즉시 소멸하는 무의미 코드) + 한계 주석.
- assign RPC 해제 분기 `pending/draft` 허용(초안 pending만 → draft 추가, reviewer 지적).
- 운영 배포 완료. 운영자가 다채널 26건 검수 모달에서 채널 지정 완료. 남은 다채널 2건은 두 채널 다 신버전 채워진 중복.
