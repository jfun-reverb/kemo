# 📋 작업 분해표 — 응모 완료 모달 (c05-06)

**사양서:** `docs/specs/2026-10-15-client-figma-reviewer-apply-screens.md` §7(7-1~7-9)
**분해일:** 2026-10-16
**총 작업 조각:** 3 · 병렬 1쌍(조각 2와 조각 3) · 순차 1(조각 1이 먼저)
**상태:** 작업표 확정 · 사용자 결정 4건 반영(아래 「결정」) · ✅ **운영 반영 2026-10-16**(개발 #2102 → 운영 #2104, 마이그레이션 537 개발·운영 적용) — 결과는 사양서 `2026-10-15-client-figma-reviewer-apply-screens.md` 「구현 결과」

---

## 🚦 착수 전 선결 조건

| # | 선결 조건 | 근거 | 막는 조각 |
|---|---|---|---|
| P0 | 아래 「결정」 4건 | 질문 1은 조각 1의 범위, 질문 2~4는 조각 2의 동작을 바꾼다 | 1·2 |
| P1 | 마이그레이션 번호는 **다음 번호 1개** — 착수 순간 `ls supabase/migrations/ \| tail -3` 로 확인(다른 세션이 동시에 만드는지 확인) | `multi-session.md` | 1 |
| P2 | 개발서버 데이터베이스에 조각 1을 **먼저** 적용하고 그 뒤 조각 2 코드를 올린다 | 순서가 바뀌면 화면이 없는 함수를 부른다(저장 실패여도 모달은 닫히게 설계했으므로 보이는 고장은 없지만 오류 로그가 쌓인다) | 2 |
| P3 | 개발서버에 리뷰어형 캠페인 **2개**(하나는 c05-06 시험용 · 하나는 가구매 표시 시험용 — 검증 계획 2·3)와 시딩형 1개가 모집 중이어야 한다(방문형도 있으면 좋다). 행사(방문 예약) 캠페인 1개(검증 계획 2 「행사」) — 없으면 코드 대조 S9 로 갈음하고 「구현 결과」에 미검증으로 남긴다. 가구매 표시 캠페인은 개발서버에 없다(전제·근거는 사양서 결정 12) — **시험 캠페인 하나에 SQL 로 `proxy_purchase=true` 를 켜서** 중립 갈래(사양서 결정 7·12)를 본다 — 시험 뒤 되돌린다. 테스트 계정 sakura/yui/haruka | 검증 계획 | 검증 |

## ⚠️ 사양서 stale 점검 — 코드 대조 (S1~S12 · 위 선결 조건 P0~P3 과 다른 번호)

| # | 사양서가 말한 것 | 실제 코드 | 영향 |
|---|---|---|---|
| S1 | 「관리자 **신청 상세**(응모 정보)에 한 줄」(7-5, 결정 5) | 관리자 앱에는 신청 상세 모달이 없다. 같은 성격의 시각(주의사항 동의)은 `admin-core.js` `consentBadge(app)` 가 **신청 사유 칸 아래 작은 배지**로 그리고, `msgCell(text, app)` 을 거쳐 **표 두 곳**(캠페인 상세 신청자 표 · 신청 관리 목록)에 같이 뜬다 | 조각 3은 `consentBadge` 옆에 배지 하나를 더 두는 것으로. 화면 이름은 「신청자 표 신청 사유 칸」 |
| S2 | 「바깥 누름·뒤로가기·X 로는 닫히지 않는다」(결정 3) | `ui.js` 전역 Esc 처리기가 열려 있는 `.modal-overlay.open` 중 맨 위 것을 무조건 닫는다. `ui.js` 는 관리자와 공유라 고치지 않는다 | 모달 바깥 틀은 **`dialog-overlay` + `style.display`** 방식(`#ageGateOverlay` 와 같다) — Esc 처리기에 안 걸리고 바깥 누름 처리기도 없다 |
| S3 | 「닫은 뒤 상세에 남는다」(결정 4) | `popstate` 는 페이지만 바꾸고 모달을 닫지 않는다. 모달이 열린 채 뒤로가기(iOS 밀어서 뒤로가기 포함)를 하면 뒤 화면이 목록으로 바뀌고 모달은 남는다 | 결정 2 |
| S4 | 「상세를 먼저 다시 그린 뒤 모달」(7-4 ③) | 성공 분기는 `openCampaign(currentCampaignId)` 를 `await` 없이 부른다 | `await openCampaign(...)` 로 바꿔야 성립 |
| S5 | {구매 기간}(7-6 ①) | 기간 표기는 `campaignPeriodRowKind(camp)` 갈래를 따른다 — `merged`·`monitorNoPurchase` 는 모집 기간 날짜, `split` 만 구매 기간 날짜 | 모달도 같은 판정 함수·같은 날짜 규칙(새 판정을 만들지 않는다) |
| S6 | 「제출 마감 {날짜}」 | `submission_end` 는 NULL 일 수 있고 상세도 그때 줄을 안 그린다 | NULL 이면 마감 꼬리를 뺀다 — 「구현 결과」에 기록 |
| S7 | 「회원이 응모 행을 직접 UPDATE 하는 길은 열지 않는다」(7-5) | UPDATE 길은 없다. 그런데 INSERT 정책은 칸을 가리지 않아 응모를 넣을 때 새 칸을 미리 채워 보낼 수 있다. 상태 위조 차단 트리거(314)는 `status`·`reviewed_by`·`reviewed_at` 만 비운다 | 결정 1 |
| S8 | (초안 문장) 갈래 「`approved` + 가구매 아님 → c05-06」(7-4 ② 초안) | 저장 순간 `approved` 가 되는 것은 리뷰어형 트리거(049)뿐. 초안 문장은 모집 형식을 안 봤다 — 「심사중인데 리뷰어형」에는 형식별 안내 줄이 정해지지 않았다 | **해결됨** — 결정 3 으로 사양서 결정 10·7-4 ②(판정 순서)·7-4 ⑥(pending 갈래는 형식별 안내 줄만 형식을 본다)에 반영 |
| S9 | 충돌 없음 | 행사 분기는 `submitEventReservation` 뒤 `return` 해 성공 분기에 닿지 않는다(행사 토스트는 `event.applyDone` 별개 키) | 사양서 결정 1의 「행사 제외」가 코드에서도 성립 |
| S10 | 충돌 없음 | 049 는 BEFORE INSERT 라 저장된 행 자체가 `approved`. 본인 조회 정책도 있다 | 응모를 다시 읽는 방식 성립 |
| S11 | 충돌 없음 | `detail.applyComplete` 를 쓰는 자리는 `application.js` 한 곳뿐 | 토스트를 없애면 키를 ja·ko 두 벌에서 지운다 |
| S12 | 충돌 없음 | `applications` UPDATE 트리거는 전부 `UPDATE OF status` | 새 칸만 바꾸는 갱신에 신청 인원 재계산·이벤트·정산 보류가 딸려 오지 않는다 |

## 결정 (2026-10-16 사용자)

| # | 질문 | 결정 |
|---|---|---|
| 1 | 응모 저장 때 「안내 확인 시각」을 미리 채워 보내는 위조를 서버에서 막을까 | **막는다** — 314 삽입 가드에 `NEW.guide_acknowledged_at := NULL;` 한 줄(`CREATE OR REPLACE`, 트리거 이름 유지). 사양서 결정 8 |
| 2 | 모달이 열린 채 브라우저 뒤로가기 | **상세에 붙잡아 둔다** — `app.js` popstate 맨 앞에서 모달이 보이면 `#detail-{id}` 를 다시 넣고 멈춤. 사양서 결정 9 |
| 3 | 다시 읽은 상태가 예상 밖일 때 | **다시 읽은 상태로 판정하고 예상 밖은 중립** — 판정 순서는 사양서 결정 10(가구매 표시 갈래는 사양서 결정 12 로 뒤에 더해졌다) |
| 4 | 구매처가 둘 이상인 캠페인의 ① 줄 표기 | **상세 표와 같은 표기**(「Qoo10 or LIPS」, `and` 면 `&`). 사양서 결정 11 |

## 한눈에 보는 의존 순서

```
조각 1 (데이터베이스: 칸 + 기록 함수 + 실행 권한 + 314 재정의) ──개발서버 DB 적용──┬──> 조각 2 (회원 화면)
                                                                       └──> 조각 3 (관리자 배지)
배포: 1 → (2 · 3 같은 병합 가능) → 개발서버 검증 → 사용자 확인 → 운영(DB 1 먼저 → 코드)
```

## 작업 조각 표

| 번호 | 제목 | 담당 파일 | 산출 계약 | 선행 | 병렬? | 담당 |
|---|---|---|---|---|---|---|
| 1 | 안내 확인 시각 칸 + 기록 함수 + 314 삽입 가드 재정의 | `supabase/migrations/<다음 번호>_application_guide_acknowledged.sql` · `CLAUDE.md`(스키마 줄) | 칸 `applications.guide_acknowledged_at timestamptz NULL` · 함수 `public.acknowledge_application_guide(p_application_id uuid) RETURNS timestamptz` · 거부 코드 `not_authenticated`·`application_not_found` | 없음 | 아니오(맨 먼저) | 개발 + reverb-supabase-expert |
| 2 | 응모 완료 모달(회원 화면) | `dev/index.html` · `dev/js/application.js` · `dev/js/app.js`(뒤로가기, 결정 2) · `dev/css/campaign.css` · `dev/lib/i18n/ja.js` · `ko.js` · `dev/lib/storage.js`(🔴 핫스팟 — 함수 2개 추가만) | DOM `#applyResultOverlay` 등 · 함수 `openApplyResultModal`·`confirmApplyResult` · 저장소 함수 `fetchMyActiveApplication`·`acknowledgeApplicationGuide` · 번역 묶음 `applyResult.*` | 조각 1(개발서버 DB 적용) | 조각 3과 병렬 가능 | 개발 |
| 3 | 관리자 신청자 표 「안내 확인」 배지 | `dev/js/admin-core.js` | 함수 `guideAckBadge(app)` → `msgCell` 에서 `consentBadge` 다음에 출력 | 조각 1 | 조각 2와 병렬 가능 | 개발 |

## 조각별 상세

### 조각 1 — 데이터베이스
- **하는 일**: ① `ALTER TABLE public.applications ADD COLUMN IF NOT EXISTS guide_acknowledged_at timestamptz NULL;` + 칸 주석 ② 함수 `acknowledge_application_guide(p_application_id uuid) RETURNS timestamptz` — `LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''` · `auth.uid() IS NULL` 이면 `RAISE EXCEPTION 'not_authenticated'` · `UPDATE … SET guide_acknowledged_at = now() WHERE id = p AND user_id = auth.uid() AND guide_acknowledged_at IS NULL RETURNING …`(이미 있는 값은 덮지 않는다) · 0행이면 다시 읽어 행이 있으면 그 값(두 번 불러도 같은 결과), 없으면 `RAISE EXCEPTION 'application_not_found'`(남의 응모와 없는 응모를 구분하지 않는다) · 취소된 응모는 거부하지 않는다 ③ 권한 `REVOKE EXECUTE … FROM PUBLIC, anon; GRANT EXECUTE … TO authenticated;`(509 와 같은 방식, 두 방향 회수) ④ 314 `guard_application_insert_status` 를 `CREATE OR REPLACE` 로 다시 정의(베이스 314, 그 뒤 재정의 파일 없음)해 `NEW.guide_acknowledged_at := NULL;` 한 줄 추가. ⚠️ 트리거 이름은 바꾸지 않는다(이름 순서가 049 보다 앞서야 리뷰어형 자동 승인이 산다) ⑤ 롤백은 주석으로만(함수 → 칸)
- **완료 정의**: 개발서버 적용 후 `information_schema.columns` 에 칸 · `guide_acknowledged_at` 을 채워 응모를 INSERT(회원 역할로 — SQL 편집기에서는 `set local role authenticated` + 본인 토큰(`request.jwt.claims`) 설정, 또는 앱의 응모 삽입에 칸을 끼워 보내서)해도 저장된 행은 NULL(314 재정의 — 사양서 7-9 「서버가 지운다」 줄. ⚠️ 314 가드는 행사 예약 함수 경유·비로그인·관리자 삽입을 앞 단계에서 통과시키므로 「지운다」는 일반 회원 삽입에만 해당한다) · `p.proacl::text` 에 `anon` 없음 + 맨 앞 `=X/` 없음 · `has_function_privilege('authenticated', …)` 참 · 토큰 설정 없이(기본 역할로) SQL 편집기에서 부르면 `not_authenticated`(그 상태의 편집기는 로그인 회원이 아니다) · `CLAUDE.md` 「applications」 줄에 칸·함수 추가(같은 커밋)
- **필요 검문소**: reverb-supabase-expert(권한 두 방향 · 314 재정의 시 트리거 순서) → reverb-reviewer
- **편집기 경고(사용자 안내용)**: 안 뜸 — `DROP`·`DELETE` 없음. ⚠️ 314 를 다시 정의하면 경고 없이 동작이 바뀐다
- **주의·롤백**: NULL 허용 칸이라 기존 행 영향 없음. 되돌리기는 함수 → 칸 순

### 조각 2 — 회원 화면
1. **마크업** `dev/index.html`: `#ageGateOverlay` 와 같은 방식(`class="dialog-overlay"` · `style="display:none;z-index:610"`(기존 `dialog-overlay` 셋 — 마이페이지 떠나기·프로필 안내·연령 게이트 — 과 같은 값. 더 낮추면 `applyActionModal` 613 등 600대 모달 아래로 들어간다) · `role="alertdialog"` · `aria-modal="true"` · `aria-labelledby="applyResultTitle"`)으로 `#applyResultOverlay`. X 단추 없음(사양서 결정 3). 안쪽 `.dialog` > `.popup-head.center` > `#applyResultTitle` / `.popup-body` > `#applyResultIntro` · `#applyResultSteps` · `#applyResultNote` · `#applyResultAckRow` > `label.apply-check` > `input#applyResultAck` / `.popup-actions` > `button#applyResultConfirmBtn.btn.btn-primary`. Material Icons 에 `translate="no"`
2. **스타일** `dev/css/campaign.css`: 번호 동그라미 단계 목록 · 파란 안내 상자 · 비활성 단추 흐림 38%. 체크 줄은 기존 `.apply-check`(누르는 영역 44px 이상). ⚠️ `base.css`·`components.css`·`ui.js` 기존 값은 고치지 않는다
3. **저장소 함수 2개** `dev/lib/storage.js`(추가만): `fetchMyActiveApplication(userId, campaignId)` → `{id,status}` 또는 `null`(`select('id, status').eq(user_id).eq(campaign_id).neq('status','cancelled').maybeSingle()` · 오류·0건·시연 모드 모두 `null`, 오류는 `logAppError`) · `acknowledgeApplicationGuide(applicationId)` → `{ok:true, acknowledgedAt}` / `{ok:false, error}`(`retryWithRefresh` + `db.rpc`, `cancelApplication` 과 같은 꼴). ⚠️ `insertApplication` 에 `.select()` 를 붙이는 방식은 쓰지 않는다(결과 반환 실패 = 저장됐는데 실패 토스트)
4. **성공 분기** `_submitApplicationInner` 끝: `closeModal('applyModal'); const myApp = await fetchMyActiveApplication(currentUser?.id, currentCampaignId); await openCampaign(currentCampaignId); openApplyResultModal(camp, myApp);` — 성공 토스트 줄 삭제. 실패 토스트·마감·중복 다시 그리기·메타 픽셀·캐시 비우기는 그대로
5. **갈래 판정** `applyResultKind(camp, myApp)` → `'monitor'|'review'|'neutral'` — 사양서 결정 10 의 **판정 순서 그대로**: `null` → neutral / `camp.proxy_purchase` 참 → neutral(상태 무관 — 사양서 결정 12) / `approved`+리뷰어형 → monitor / `pending` → review / 그 밖 → neutral
6. **내용 조립** `buildApplyResultSteps(camp, kind)`: {구매처} = `campaignChannelTokens(camp)` 중 `qoo10`·`lips`·`cosme`(상수 `APPLY_RESULT_MALL_CODES`) 를 `getChannelLabel` 로(둘 이상은 결정 4) · {게시 채널} = 전체 채널을 상세 표와 같은 방식(`and` 면 `&`, 아니면 `or`) · {구매 기간} = `campaignPeriodRowKind` 가 `split` 이면 구매 기간, `merged`·`monitorNoPurchase` 면 `formatDate(recruit_start||오늘) 〜 formatDate(deadline)` · {날짜} = `formatDate(submission_end)`, NULL 이면 꼬리 생략 · 캠페인 값은 전부 `esc()`
7. **열기·닫기**: `openApplyResultModal(camp, myApp)` 은 열 때마다 체크를 끄고 단추 비활성, 문구 다시 채움. `neutral` 은 체크 줄 숨김·단추 활성·바깥 누름 닫힘(그 갈래만). `onApplyResultAckChange()` → 단추 활성
8. **확인** `confirmApplyResult()`: `neutral` 은 바로 닫음. 그 밖은 `withSubmitLock('applyAck:'+appId, 'applyResultConfirmBtn', t('applyResult.processing'), …)` 안에서 `acknowledgeApplicationGuide` 호출, 결과와 무관하게 닫음(7-4 ⑤). 닫기 = `style.display='none'`, 화면 이동 없음
9. **번역 키** `applyResult.*` 를 ja.js·ko.js 같은 자리에: `titleDone`·`titleReceived`·`introMonitor`·`introReview`·`stepPurchase`({mall})·`stepPurchaseNoMall`·`stepReceipt`·`stepReceiptSub`·`stepPost`({channels})·`stepPostNoChannel`·`deadlineSuffix`({date})·`paybackNote`·`noteGifting`·`noteVisit`·`neutral`·`ackLabel`·`confirm`·`processing`. 값은 사양서 7-6 표(ja = A열, ko = 한국어 열). `detail.applyComplete` 는 둘 다 지운다. 단계 제목 앞에 ①②③ 없음
10. **뒤로가기**: 결정 2 대로 — `app.js` popstate 처리기 맨 앞에서 `#applyResultOverlay` 가 보이면 `history.pushState` 로 `#detail-{id}` 를 다시 넣고 `return`
- **완료 정의**: 사양서 7-9 중 회원 화면 줄(셋째 줄은 「응모 행에 확인 시각이 남는다」까지만 — 「관리자 배지로 보인다」 부분은 조각 3 · 「서버가 지운다」 줄은 조각 1 · 둘째 줄의 방문형 부분은 방문형 캠페인이 있을 때 확인하고 없으면 「구현 결과」에 미검증으로 남긴다) + 아래 검증 계획 회원 항목 + `FEATURE_SPEC.md`(응모 흐름)·사양서 「구현 결과」 같은 커밋
- **필요 검문소**: reverb-reviewer(Esc·뒤로가기 · `esc()` 누락 · ja/ko 키 짝 · 지운 키를 부르는 곳) · 운영 배포 전 reverb-qa-tester 권장
- **주의·롤백**: 낱말 전파 점검(「当選」·「活動管理」·「レシート」·「ペイバック」·「提出締切」 — `dev/`·`supabase/functions/`·`docs/email-templates/`·FAQ 시드)을 「구현 결과」에 기록. 되돌리기는 성공 분기 세 줄 복원 + `detail.applyComplete` 복원

### 조각 3 — 관리자 「안내 확인」 배지
- `dev/js/admin-core.js` 에 `guideAckBadge(app)` — `app.guide_acknowledged_at` 이 있을 때만 「안내 확인 {formatDateTime}」, `consentBadge` 와 같은 크기·색, Material Icons `translate="no"`. `msgCell(text, app)` 에서 `consent` 옆에 붙인다 — ⚠️ 사유가 빈 행의 조기 반환 줄에도 넣는다. 조회는 `select('*')` 라 그대로 따라온다
- **완료 정의**: 두 표(캠페인 상세 신청자 · 신청 관리 목록) 모두 배지가 보이고, 값 없는 행에는 없다. 엑셀 열 없음
- **필요 검문소**: reverb-reviewer. 운영 반영 뒤 Notion 「관리자 가이드」 신청 관리 페이지에 한 줄

## ⚠️ 공유 지점 경고
- `dev/lib/storage.js` 핫스팟 — 함수 추가만 · `ui.js` 는 관리자 공유라 Esc 문제를 거기서 풀지 않는다 · `msgCell` 은 표 두 곳이 같이 쓴다(의도) · 기간 판정은 `campaignPeriodRowKind` 하나 · 314 재정의 시 트리거 이름 유지 · `applications` 를 칸 골라 읽는 자리는 배지를 안 그리므로 그대로

## 🧭 배분 제안
- 세션 하나로 순차: 조각 1(개발서버 DB 적용·권한 조회) → 조각 2 → 조각 3, 2·3 은 같은 병합 요청. 운영 반영: 운영 SQL 편집기에 조각 1 → 권한 조회 → `dev → main`(사용자 확인) → Notion

## 검증 계획
1. 데이터베이스: 칸 존재 · `proacl` 에 `anon` 없음·맨 앞 `=X/` 없음 · 같은 응모로 두 번 불러 시각 불변 · `guide_acknowledged_at` 을 채워 INSERT(회원 역할로 — SQL 편집기에서는 `set local role authenticated` + 본인 토큰(`request.jwt.claims`) 설정, 또는 앱의 응모 삽입에 칸을 끼워 보내서)한 응모 행이 NULL 로 저장됨
2. 회원 화면(개발서버 · 크롬으로 보이게): 리뷰어형(체크 전 비활성 → 체크 → 확인 → 닫힘 → 「活動管理」) · 시딩(「応募を受け付けました」 + 시딩 안내 줄, 「購入」 없음) · 방문형 안내 줄은 방문형 캠페인이 있을 때만 · Esc·바깥 누름 안 닫힘 · 뒤로가기(결정 2) · 재조회 실패(네트워크 차단 → 중립·체크 없음) · 가구매 표시(시험 캠페인에 SQL 로 `proxy_purchase=true` → 리뷰어형이어도 중립·체크 없음·`guide_acknowledged_at` NULL → 시험 뒤 되돌림 — 이 시험은 **다른 시험 캠페인**으로 해 아래 3 의 리뷰어형 행과 섞이지 않게) · 행사(옛 토스트 그대로) · 재응모(새 행에 시각) · 일본어·한국어 둘 다 · 중립 갈래 ③ 「그 밖」(리뷰어형이 아닌데 `approved` · 다른 상태)은 응모 직후 재조회에서 만들 수 없다 — 판정 함수의 그 갈래를 코드로 확인하고 「구현 결과」에 적는다(사양서 7-9)
3. SQL: 리뷰어형(가구매 시험 캠페인의 응모 행 제외)·시딩형 행의 `guide_acknowledged_at`, 중립 갈래(가구매 시험 행 포함)는 NULL
4. 관리자: 두 표에 배지, 값 없는 행엔 없음

## 구현 결과 (개발이 채울 것)
조각 1·2·3 완료(2026-10-16) — 마이그레이션 537 · 상세(초안 대비 변경·검증 표·낱말 전파 점검)는 사양서 「구현 결과」 한 자리에만 적는다
