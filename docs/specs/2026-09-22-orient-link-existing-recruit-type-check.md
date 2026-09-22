# 오리엔시트 「기존 캠페인 연결」 — 모집 형식 일치 검사

**작성일:** 2026-09-22 · **작성:** 기획 세션
**계기:** 사용자 요청 — "오리엔시트 관리·캠페인 생성 및 관리·브랜드 관리 상관관계 면밀히 검토" 중 발견한 항목을 사양서로 넘김(2026-09-22 사용자 결정).

---

## 0. 한 줄 요약

오리엔시트 카드를 **이미 있는 캠페인**에 연결할 때(발행 방식 ②), 지금은 **브랜드만** 맞으면 목록에 뜨고 연결도 된다. 카드가 말하는 모집 형식(리뷰어·시딩·가구매)과 그 캠페인의 실제 모집 형식(`recruit_type`·`proxy_purchase`)이 다른지는 화면도 서버도 안 본다. 이 검사를 **목록 필터 + 서버 최종 방어선** 두 겹으로 추가한다.

---

## 1. 현재 상태 (2026-09-22, `origin/dev` 기준 — 규칙 A)

### 1-1. 지금 하는 검증 — 브랜드만

- 목록 필터 `osRenderLinkList`(`dev/js/admin-orient.js:1777`): `all.filter(c => c && c.brand_id === brandId && !linked.has(c.id))` — **브랜드 일치 + 미연결**만 본다.
- 연결 실행 서버 함수 `link_orient_card_to_campaign`(현재 원본 **237**, `supabase/migrations/237_link_orient_card_to_existing_campaign.sql:119-289`): 검증 순서 = 권한 → 시트 상태(submitted) → 카드 범위 → 카드별 멱등(이미 연결됨) → 캠페인 존재 → **브랜드 일치**(`campaigns.brand_id = orient_sheets.brand_id`, 234-241줄) → **전역 중복**(이 캠페인이 어느 시트 어느 카드에도 이미 안 물려 있는지, 244-256줄) → 기록. **모집 형식은 검사 항목에 없다**(파일 전체에 `recruit_type`·`form_type` 비교 0건).
- 캠페인 조회 `SELECT id, brand_id, campaign_no INTO v_campaign FROM campaigns …`(213-217줄) — **`recruit_type`·`proxy_purchase`를 아예 안 읽는다.**

### 1-2. 카드의 "형식"과 캠페인의 "형식"은 이름도 값도 다르다

| 카드 `form_type`(오리엔시트) | 캠페인 `recruit_type` | 캠페인 `proxy_purchase` |
|---|---|---|
| `reviewer` | `monitor` | `false` |
| `proxy_purchase` | `monitor` | `true` |
| `seeding` | `gifting` | `false`(무관) |
| (해당 없음) | `visit` | `false`(무관) |

- 매핑 근거: `addCampaign`(`dev/js/admin.js:4536`) `const recruitType = (ft === 'seeding') ? 'gifting' : 'monitor';` + `proxy_purchase: _opc ? !!_opc.isProxy : false`(`admin.js:4633` 부근, `_opc.isProxy`는 `applyOrientCardPrefill` 가 `card.form_type === 'proxy_purchase'` 로 세팅).
- 🔴 **`reviewer`와 `proxy_purchase`는 `recruit_type` 값이 같다**(`monitor`) — `recruit_type`만 비교하면 이 둘을 못 가른다. `proxy_purchase`도 함께 봐야 한다.
- 🔴 **`visit`(방문형)은 카드 형식 어디에도 대응하지 않는다** — 오리엔시트 카드가 만들 수 있는 형식은 리뷰어·시딩·가구매 셋뿐이다(`osOpenCreate` 라디오 2종 + 가구매는 관리자가 미리 만든 시트에만 존재). ⚠️ **지금은 이 대응 없음이 아무것도 막지 않는다** — §1-1 대로 형식 검사 자체가 없어 `recruit_type='visit'`인 캠페인도 브랜드만 맞으면 지금 그대로 연결된다. §3 의 검사를 붙이면 그때부터 **어떤 카드로도 연결되지 않게** 된다(대응하는 형식이 없으므로).

### 1-3. 카드 형식은 "기존 연결" 진입 시점에 항상 정해져 있다

`osPublishCard`(`admin-orient.js:1687`)가 발행 방식 모달을 열기 **전에** `if (!card.form_type) { toast('형식이 선택되지 않은 카드는 발행할 수 없습니다.'); return; }`(1695줄)로 이미 막는다. 즉 "기존 캠페인 연결" 화면(`osRenderLinkList`)에 도달하는 시점엔 `card.form_type`이 `reviewer`·`seeding`·`proxy_purchase` 셋 중 하나로 **항상 정해져 있다.** 옛 구조(카드 여러 개)든 새 구조(카드 1개, `issued.form_type`)든 카드 하나하나의 `form_type` 필드 자체는 같은 값 체계다.

### 1-4. 관련 값에 접근하는 경로

- `osRenderLinkList` 안에서 `_osDetailSheet`·`_osPublishCardIdx`(모듈 전역)로 카드에 바로 접근 가능 — `_osDetailSheet.data.cards[_osPublishCardIdx]`.
- `osConfirmLink(campaignId)`(`admin-orient.js:1811`)도 같은 전역을 쓴다.
- 후보 캠페인 목록은 `allCampaigns`(전역 캐시)에서 온다 — 이미 `recruit_type`·`proxy_purchase`를 포함해 로드돼 있다(캠페인 관리 페인이 채워 둠).

### 1-5. 충돌 가능 동작

- 없음 — 확인한 영역 3개: ①`unlink_orient_card`(238)는 연결을 지우기만 해서 이 검사와 무관 ②`link_campaign_to_application`(121, 광고주 신청↔캠페인 연결)은 별개 함수로 이 흐름을 안 건드림 ③변경 이력(캠페인 변경 이력 265·266)에 이 연결 자체가 안 들어가 있어(원래도 `campaign_id`·`linked_existing`은 `orient_sheets.data`에만 기록) 영향 없음.

---

## 2. 의심·경우의 수 (규칙 B)

### 2-1. 깨질 수 있는 경우

1. **(UX) 너무 세게 막으면 정당한 연결까지 막힌다** — 예를 들어 관리자가 캠페인을 먼저 손으로 만들면서 실수로 `proxy_purchase`를 안 켰는데, 오리엔시트 카드는 `proxy_purchase`로 제출된 경우. 이때 "형식이 안 맞는다"고 막으면 관리자는 캠페인 편집 화면에서 `proxy_purchase`를 먼저 켜고 와야 한다 — 그 유도가 명확해야 한다.
2. **(UX) 목록에서 아예 안 보이면 "왜 안 보이는지" 알 길이 없다** — 브랜드가 같은 캠페인인데 목록에 없으면 관리자는 "발급을 다시 해야 하나"로 오해할 수 있다.
3. **(동시성) 캠페인 형식은 연결 시도 중간에 바뀔 수 있다** — 다른 관리자가 같은 순간 그 캠페인의 `recruit_type`을 편집 중일 수 있다. → 서버 쪽 캠페인 행 잠금(`FOR UPDATE`, 216줄)이 이미 있으므로 검사를 그 잠금 **뒤에** 두면 최신 값을 본다(추가 동시성 문제 없음).
4. **(권한) 없음** — 이 함수는 이미 `is_admin()` 하나로 열려 있고, 이번 검사는 그 안에서 도는 추가 조건일 뿐이라 권한 체계는 안 바뀐다.
5. **(데이터) `recruit_type`·`proxy_purchase`가 NULL인 캠페인이 있을 수 있는가** — `recruit_type`은 `NOT NULL`(스키마 확인 필요, 통상 CHECK 제약), `proxy_purchase`는 `NOT NULL DEFAULT false`(CLAUDE.md 명시). NULL을 걱정할 필요는 낮지만, 방어적으로 `IS DISTINCT FROM`으로 비교해 NULL도 "불일치"로 자연스럽게 처리되게 한다.

### 2-2. 현재 구현과 어긋나는 지점

- `link_orient_card_to_campaign`의 캠페인 조회 SELECT 절에 `recruit_type`·`proxy_purchase`가 없다 — 추가해야 한다.
- `osRenderLinkList`의 필터 조건과 빈 목록 안내문(`admin-orient.js:1789-1792`)에 형식 조건이 없다 — 추가해야 한다.

### 2-3. 의도 모호점

- **"형식이 안 맞으면 목록에서 뺄지, 목록엔 보이되 경고만 할지"** — §2-1 ①·②가 정확히 반대 방향으로 당긴다(너무 막으면 정당한 케이스가 막히고, 안 막으면 실수를 못 막는다). → §3-2에서 **"목록엔 안 보이지만 검색으로 우회하지 않는다 + 안내문에 이유를 적는다"**로 절충한다.
- **차단 강도(서버가 거부 vs 확인 후 허용)** — 브랜드 불일치·전역 중복은 **거부**(구조적 제약: 한 캠페인은 한 브랜드에만, 한 카드에만 물린다). 형식 불일치는 그 카드·그 캠페인 둘 다 유효한 데이터라 "틀렸다"기보다 "이례적이다"에 가깝다. → §3-1에서 **거부**로 정하되, 근거를 규칙 B ①에 대한 완화책(§3-4 안내문)으로 보완한다.

---

## 3. 설계

### 3-1. 서버 — `link_orient_card_to_campaign` 재정의 (베이스 237)

- 캠페인 조회 SELECT 에 `recruit_type`·`proxy_purchase` 추가: `SELECT id, brand_id, campaign_no, recruit_type, proxy_purchase INTO v_campaign FROM public.campaigns WHERE id = p_campaign_id FOR UPDATE;`
- 브랜드 일치 검사(234-241줄) **바로 뒤**에 새 검사를 넣는다(캠페인 잠금 뒤, 전역 중복 검사 앞 — 캠페인 자체가 이 카드에 맞는 데이터인지부터 본 다음 "이미 다른 데 쓰였는지"를 본다):

```sql
DECLARE
  v_card_ft   text;      -- 카드의 form_type
  v_exp_rt    text;      -- 기대하는 recruit_type
  v_exp_proxy boolean;   -- 기대하는 proxy_purchase
BEGIN
  ...
  v_card_ft := v_card_entry ->> 'form_type';
  IF v_card_ft IN ('reviewer', 'seeding', 'proxy_purchase') THEN
    v_exp_rt    := CASE WHEN v_card_ft = 'seeding' THEN 'gifting' ELSE 'monitor' END;
    v_exp_proxy := (v_card_ft = 'proxy_purchase');
    IF v_campaign.recruit_type IS DISTINCT FROM v_exp_rt
       OR (v_exp_rt = 'monitor' AND v_campaign.proxy_purchase IS DISTINCT FROM v_exp_proxy) THEN
      RETURN jsonb_build_object(
        'success', false, 'reason', 'recruit_type_mismatch',
        'card_form_type', v_card_ft,
        'campaign_recruit_type', v_campaign.recruit_type,
        'campaign_proxy_purchase', v_campaign.proxy_purchase
      );
    END IF;
  END IF;
  -- v_card_ft 가 위 셋이 아니면(옛 데이터·직접 호출 등 예외) 검사를 건너뛴다 — 판단 근거가 없을 때 막지 않는다
```

- 🔴 **`reviewer`와 `proxy_purchase`를 가르는 것은 `proxy_purchase` 비교뿐**이다 — `recruit_type`만 보면 이 둘이 같은 값이라 못 가른다(§1-2).
- 거부 사유는 기존 목록(`invalid_status`·`invalid_card`·`already_published`·`campaign_not_found`·`brand_mismatch`·`campaign_already_linked`)에 **`recruit_type_mismatch`** 하나를 추가한다.
- 인자 목록(`uuid, int, uuid`) 불변 → `CREATE OR REPLACE`. 저장소 관례대로 `REVOKE`·`GRANT`도 다시 건다.

### 3-2. 클라이언트 — `osRenderLinkList` 필터 확장

- `admin-orient.js:1777` 근처에 헬퍼를 하나 둔다:

```js
// 카드 형식이 기대하는 recruit_type·proxy_purchase — 서버(237)와 같은 매핑
function osExpectedRecruitType(cardFt) {
  if (cardFt === 'seeding') return { recruit_type: 'gifting', proxy: null };
  if (cardFt === 'reviewer') return { recruit_type: 'monitor', proxy: false };
  if (cardFt === 'proxy_purchase') return { recruit_type: 'monitor', proxy: true };
  return null;
}
function osCampaignMatchesCardType(c, cardFt) {
  const exp = osExpectedRecruitType(cardFt);
  if (!exp) return true;   // 카드 형식을 모르면 막지 않는다(서버와 같은 원칙)
  if (c.recruit_type !== exp.recruit_type) return false;
  if (exp.proxy !== null && !!c.proxy_purchase !== exp.proxy) return false;
  return true;
}
```

- 🔴 **두 단계로 나눠 계산한다** — `list`를 한 번에 만들지 않는다. 지금 있는 「브랜드 일치 + 미연결」 필터 결과를 먼저 `brandOnly`라는 이름으로 그대로 보존하고(`const brandOnly = all.filter(c => c && c.brand_id === brandId && !linked.has(c.id));`), 그 `brandOnly` 위에 형식 조건을 한 번 더 걸어 `list`를 만든다(`let list = brandOnly.filter(c => osCampaignMatchesCardType(c, (s.data.cards[_osPublishCardIdx] || {}).form_type));`). 검색어(`q`)는 지금처럼 `list`에만 적용한다.
- 빈 목록 안내문(1789-1792줄)에 형식 조건도 반영: **`brandOnly.length === 0`**이면 지금 문구("이 브랜드에 연결 가능한 캠페인이 없습니다…") 그대로, **`brandOnly.length > 0`인데 `list.length === 0`**이면(브랜드는 맞는데 형식이 다 안 맞음) "이 브랜드에 [카드 형식] 캠페인이 없습니다. 신규 발행을 이용하거나, 연결하려는 캠페인의 모집 형식을 먼저 맞춰 주세요."로 가른다.
- 검색창(`q`)으로 형식이 안 맞는 캠페인을 찾아 우회할 수 없게 한다 — 검색도 **형식까지 맞춘 목록 안에서만** 돈다(지금 코드가 이미 `list`를 필터링한 뒤 검색을 적용하는 순서라 자동으로 그렇게 된다).

### 3-3. 확인 창 문구

`osConfirmLink`(`admin-orient.js:1811`)가 서버에서 `recruit_type_mismatch`를 받으면(클라 필터를 우회한 경우 — 목록이 새로고침 전이거나 직접 호출) 사유 안내에 한 줄 추가: "이 캠페인의 모집 형식이 이 카드와 다릅니다. 캠페인을 편집해 형식을 맞추거나, 다른 캠페인을 골라 주세요."

### 3-4. §2-1 ①(정당한 불일치)에 대한 완화책

막되, **캠페인 관리 화면으로 바로 갈 수 있게** 안내한다 — 목록 안내문·확인 창 문구 모두 "캠페인을 편집해 형식을 맞추거나"를 포함시킨다(§3-2·§3-3). 강제로 우회시키는 별도 버튼(예: "그래도 연결")은 만들지 않는다 — 이례적인 경우는 캠페인 쪽 값을 바로잡는 게 정상 경로이고, 우회 버튼을 만들면 이 검사 자체가 쉽게 무력화된다.

---

## 4. 검증 (개발서버)

| # | 무엇 | 기대 |
|---|---|---|
| V1 | 리뷰어 카드로 "기존 연결" → 목록 | `recruit_type='monitor' AND proxy_purchase=false`인 그 브랜드 캠페인만 보임 |
| V2 | 가구매 카드로 "기존 연결" → 목록 | `recruit_type='monitor' AND proxy_purchase=true`인 캠페인만 보임(리뷰어 캠페인은 안 보임) |
| V3 | 시딩 카드로 "기존 연결" → 목록 | `recruit_type='gifting'`인 캠페인만 보임 |
| V4 | 방문형(`recruit_type='visit'`) 캠페인이 있는 브랜드에서 어느 형식 카드로든 "기존 연결" | 그 캠페인은 어떤 카드로도 목록에 안 뜸 |
| V5 | 브랜드는 같지만 형식이 하나도 안 맞아 0건 | "이 브랜드에 [형식] 캠페인이 없습니다…" 안내 + 캠페인 편집 유도 문구 |
| V6 | 클라이언트 필터를 우회해(개발자 도구로) `link_orient_card_to_campaign` 직접 호출, 형식 불일치 조합 | `recruit_type_mismatch` 거부 |
| V7 | 형식이 맞는 정상 케이스 | 종전과 같이 연결 성공, `linked_existing:true` 기록 |
| V8 | 옛 구조 시트(카드 여러 개)에서 같은 검사 | 새 구조와 동일하게 동작(카드 하나하나의 `form_type` 값 체계는 같음) |

---

## 5. 운영 배포 전제

이 검사는 오리엔시트 개편(424~463)과 **무관하게 독립적으로 배포 가능**하다 — 옛 구조·새 구조 모두 카드의 `form_type` 값 체계가 같고, "기존 캠페인 연결" 기능 자체가 마이그레이션 237부터 있던 것이라 이미 운영에 있다. 🔴 **운영에도 바로 적용할 수 있다** — 오리엔시트 묶음 배포를 기다릴 이유가 없다.

---

## 6. 작업 조각

| # | 조각 | 파일 | 선행 |
|---|---|---|---|
| 1 | `link_orient_card_to_campaign` 재정의(마이그레이션) | `supabase/migrations/NNN_…` | — |
| 2 | `osRenderLinkList` 필터 + 안내문 + 확인 창 문구 | `dev/js/admin-orient.js` | 1 |

⚠️ 데이터베이스 함수 변경이라 `reverb-supabase-expert` 호출 대상.

---

## 7. 사용자 확인 필요

없음 — 검사를 추가하기로 한 것, 거부(우회 버튼 없음)로 하기로 한 것 모두 이 사양서 안에서 근거를 들어 정했습니다. 이견 있으시면 §2-3·§3-4 방향을 다시 봐 주세요.

---

## 구현 결과

**구현일:** 2026-09-22 · **마이그레이션:** 464 (`link_orient_card_to_campaign` 재정의, 베이스 237 — 그 뒤 재정의 없음 확인)

### 초안 대비 변경 사항
- 추가된 것: 목록 필터가 `proxy_purchase` 칸이 없는 캐시(캠페인 관리 페인의 목록 전용 조회 `ADMIN_LIST_COLUMNS`)를 만나면 **가구매 여부 비교만 건너뛴다**. `osChooseLinkExisting` 이 매번 전체 칸으로 다시 받아 정상 경로에선 해당 없고, 그 조회가 실패해 캐시로 폴백할 때만 해당 — 서버가 최종 방어선
- 추가된 것: 권한 재설정에 `REVOKE … FROM anon` 한 줄(237 에는 없었다 — 함수 안 `is_admin()` 가드가 있어 동작 변화 없음)
- 달라진 것: 매핑을 헬퍼 함수 대신 상수 `OS_CARD_CAMPAIGN_TYPE`(형식 이름표 포함)로 두었다 — 빈 목록 문구의 「리뷰어/가구매/시딩」을 같은 자리에서 꺼내려고
- 빠진 것: 없음

### 규칙 D 대조
- 어긋난 것 없음. §1-4 의 「`allCampaigns` 는 캠페인 관리 페인이 채워 둔다」는 실제로는 연결 화면을 열 때마다 `fetchCampaigns()`(전체 칸)로 새로 받는다 — 위 폴백 처리로 반영

