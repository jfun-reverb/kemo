# 인수인계 — @cosme 리뷰 인증샷 채널 코드 교정 (기획 → 개발)

**작성일:** 2026-07-30
**인계 세션:** 기획/설계 → 개발
**사양서(반드시 먼저 읽을 것):** `docs/specs/2026-07-30-review-image-channel-code-drift.md`
**시급도:** 높음 — 운영 인플루언서 응모 **55건**이 지금도 가려진 상태이고, 그중 일부는 이미 문의했다

---

## 1. 한 줄 요약

@cosme 채널 코드가 `channel-96r9y3`(구) → `cosme`(현)로 바뀔 때 **이미 제출된 리뷰 인증샷의 채널 값을 함께 옮기지 않아**, 인플루언서 화면·관리자 인증 상태·정산 후보 **3곳에서 동시에 누락**됐다. 대상 81행은 **전부 이미 승인(`approved`)** 됐다. 데이터는 살아 있고 **채널 값만 맞추면 3곳이 함께 회복**된다.

---

## 2. 지금 상태 (2026-07-30 · 실측)

| 대상 | 상태 |
|---|---|
| 운영 데이터베이스 — 옛 코드 `review_image` | **81행, 전부 `approved`** = A(옛 코드만) 응모 **55건** + B(옛+새 둘 다) 26건 |
| 기준 데이터 `lookup_values` | @cosme 는 `cosme` **1개만**. 옛 코드 `channel-96r9y3` 행은 **삭제됨**(조회 0행) |
| `campaigns.channel` | 새 코드로 정리 완료(`qoo10,cosme` / `cosme`) |
| **결과물 제출 마감 차단** | 코드·마이그레이션 **이미 `dev` 커밋됨**(커밋 `029e523`, 마이그레이션 274). **운영 데이터베이스 미적용**(조회로 확인). **개발 데이터베이스 적용 여부 미확인** |
| 작업 폴더 | 메인 폴더 `dev` 브랜치, `origin/dev` 와 동기 |

확인된 대상 캠페인(일부): `B0003-C001` · `B0003-C002` · `B0018-A002-C001` · `B0018-A002-C002` · `B0032-C003` · `B0035-C004` · `B0035-C005`

---

## 3. ⛔ 시작 전에 반드시 알아야 할 것 4가지

### (1) 조사·교정 SQL을 **어느 데이터베이스에서 실행하는지 매번 확정**한다
개발 데이터베이스에는 **운영 인플루언서 데이터 복제본**이 있어서, 실제 일본 이메일이 나와도 운영이라는 증거가 못 된다. 이번 조사에서 실제로 한 차례 개발 데이터를 운영으로 오인해 잘못된 결론을 냈다.
- 운영 = `nrwtujmlbktxjgdwlpjj` / 개발 = `qysmxtipobomefudyixw` (주소창으로 확인)
- 판별 신호: 한국어 캠페인명 · `@reverb.jp` 계정 · 관리자 화면엔 보이는데 조회는 0행

### (2) 기존 관리자 도구로는 못 고친다 — 시도하지 말 것
마이그레이션 162의 세 함수가 전부 거부한다: 채널 **지정**은 「이미 지정된 행」, 채널 **해제**는 「검수 완료된 행」, `delete_legacy_review_image` 는 「채널이 지정된 행」. 81건은 **채널 값이 있고 전부 승인 완료**라 세 조건에 모두 걸린다. **일회성 교정이 유일한 경로**다.

### (3) 마감 차단의 **운영 데이터베이스 적용을 먼저 하면 안 된다**
그 판정 함수도 `d.post_channel = p_post_channel` 로 비교하므로, 운영에 적용하는 순간 **A 그룹 55건은 반려 예외에도 걸리지 않아 재제출조차 막힌다**(화면에서도 안 보이고 서버에서도 막힌 상태). 코드는 이미 `dev` 에 있으니 게이트는 **「배포」가 아니라 「운영 데이터베이스에서 마이그레이션 실행」** 시점이다.

### (4) B 그룹 26건은 **건드리지 말 것**
같은 응모에 이미 `cosme` 행이 있어, 옛 코드를 바꾸면 중복 금지 제약 위반으로 **배치 전체가 중단**된다. 그리고 B 그룹의 처리 방침(유지/삭제)은 **아직 사용자 미결**이다(아래 6번).

---

## 4. 작업 순서

### 0단계 — 전수 조사 (읽기 전용, 필수 선행)

@cosme 만 고치면 다른 채널에서 같은 신고가 재발한다. **종류·채널 전체**를 본다.

```sql
-- (가) 기준 데이터에 없는 채널 코드가 남은 결과물 — 종류·채널별 집계
select d.kind                                as 종류,
       d.post_channel                        as 결과물채널,
       count(*)                              as 건수,
       count(*) filter (where d.status = 'approved') as 승인됨
  from deliverables d
 where d.post_channel is not null
   and d.post_channel <> ''
   and not exists (
     select 1 from lookup_values lv
      where lv.kind = 'channel' and lv.active and lv.code = d.post_channel
   )
 group by d.kind, d.post_channel
 order by 건수 desc;

-- (나) 같은 코드가 캠페인 쪽에도 남아 있는지 (남아 있으면 교정 방향이 반대)
select campaign_no, title, channel
  from campaigns
 where channel is not null
   and exists (
     select 1 from unnest(string_to_array(channel, ',')) ch
      where trim(ch) <> ''
        and not exists (select 1 from lookup_values lv
                         where lv.kind = 'channel' and lv.active and lv.code = trim(ch))
   );
```

```sql
-- (다) ★ A 그룹 명단 — 교정 대상 55건의 개별 행. **결과를 반드시 저장해 둘 것**
--      (교정 후에는 이 조회가 0행이 되어 다시 만들 수 없다). 세 용도로 쓴다:
--      ① 1단계 시험 교정에 넣을 결과물 id 를 여기서 고른다
--      ② 운영팀에 전달할 「가려진 인플루언서·캠페인」 명단 (3단계)
--      ③ 3단계 검증 ③에서 「교정한 행만」 골라 상태를 대조하는 기준 목록
select d.id                as 결과물id,
       i.email             as 인플루언서,
       c.campaign_no       as 캠페인번호,
       c.title             as 캠페인,
       d.status            as 상태,
       d.created_at::date  as 올린날
  from deliverables d
  join campaigns c on c.id = d.campaign_id
  left join influencers i on i.id = d.user_id
 where d.kind = 'review_image'
   and d.post_channel = 'channel-96r9y3'
   and not exists (                    -- B 그룹 제외 = A 그룹만
     select 1 from deliverables x
      where x.application_id = d.application_id
        and x.kind = 'review_image'
        and x.post_channel = 'cosme'
   )
 order by c.campaign_no, d.created_at;
-- 운영 기대: 55행
```

**(가)에서 `review_image` 이외의 종류가 나오면 1단계에 합치지 말 것.** 종류마다 중복 금지 제약과 재제출 구조가 달라 같은 SQL로 처리하면 안 된다 — 사양서 「경우의 수 1」. 되묻고 별도 판단한다.
**(나)에 행이 나오면 즉시 보고할 것.** 캠페인 쪽이 옛 코드면 교정 방향 자체가 달라진다.

### 1단계 — A 그룹 채널 코드 교정

**실행 환경 (2026-07-30 사용자 결정): 개발 데이터베이스에서 리허설 → 운영 데이터베이스에서 시행**

- 개발에서 확인하는 것은 **①SQL 문법 ②알림 트리거가 발동하는가** 둘이다. 이 작업의 최대 위험이 알림 폭주이고, **발동 여부는 데이터 건수가 달라도 똑같이 드러난다**
- ⚠️ **개발 데이터베이스의 A/B 분류·건수는 운영과 다를 수 있다**(복제 시점 차이). **개발에서 나온 건수를 운영 기대값으로 쓰지 말 것** — 운영 기대값은 A 55건이다
- ⚠️ **개발 리허설은 반드시 되돌린다**(`rollback`). 교정 흔적을 개발에 남기면 다음 조사가 또 오염된다 — 이번 세션에서 개발/운영 데이터를 혼동한 사고가 이미 한 번 있었다
- 개발 리허설은 아래 (1-a)·(1-b)를 한 트랜잭션 안에서 돌려보고 `rollback` 하는 형태로 하면 된다. **운영 시행은 (1-a) → (1-b) → (1-c) 순서 그대로**

**(1-a) 트리거 발동 조건 확인 (교정 전 필수)**

`deliverables` 의 `trg_deliverable_notify`(인플루언서 알림)·`trg_deliverable_status_event`(상태 이력) 두 트리거가 **`status` 변경 시에만** 동작하는지 함수 본문에서 확인한다. 조건 없이 모든 UPDATE에 도는 구조라면 **5~6월 건에 대해 지금 알림 55건이 한꺼번에 나간다.**

참고: 마이그레이션 274 트리거(`trg_deliverable_deadline_guard`)는 `auth.uid() IS NULL` 이면 통과하므로, SQL Editor(서비스 키)에서 실행하는 교정은 막히지 않는다.

**(1-b) 1건 시험 교정**

0단계 (다)에서 고른 결과물 id 하나로 시험한다. 알림은 **그 행을 참조하는 알림만** 세면 노이즈 없이 정확히 판정된다(다른 사용자 활동이 만든 알림에 오염되지 않는다).

```sql
-- 개발 리허설: begin … rollback (아래 commit 을 rollback 으로 바꿔 실행)
-- 운영 시행:   begin … commit
begin;

update deliverables
   set post_channel = 'cosme'
 where id = '<0단계 (다)에서 고른 결과물id>'
   and kind = 'review_image'
   and post_channel = 'channel-96r9y3';
-- 기대: UPDATE 1

-- ★ 이 행을 참조하는 알림이 방금 생겼는지 (같은 트랜잭션 안에서 확인)
select count(*) as 방금_생긴_알림
  from notifications
 where ref_table = 'deliverables'
   and ref_id = '<위와 같은 결과물id>'
   and created_at > now() - interval '5 minutes';
-- 기대: 0 — 1 이상이면 즉시 rollback 하고 보고할 것 (일괄 교정 진행 금지)

commit;   -- 개발 리허설이면 rollback
```

**(1-c) 나머지 일괄 교정 — B 그룹 제외 조건을 SQL 안에 반드시 넣는다**

```sql
begin;
update deliverables d
   set post_channel = 'cosme'
 where d.kind = 'review_image'
   and d.post_channel = 'channel-96r9y3'
   and not exists (                    -- ★ B 그룹 제외 (없으면 제약 위반으로 전체 중단)
     select 1 from deliverables x
      where x.application_id = d.application_id
        and x.kind = 'review_image'
        and x.post_channel = 'cosme'
   );
-- 기대: 54행 (1건 시험분 제외)
commit;
```

- **`status` 는 절대 건드리지 않는다.** 목적은 상태 전이에 딸린 알림 트리거 미발동이다
- 중복 금지 제약(`deliverables_review_image_app_channel_uniq`)에 걸려 실패하는 것을 감지 수단으로 쓰지 않는다
- **교정 이력을 남긴다.** 위 항목이 막는 것은 「상태 전이 트리거의 자동 기록」이고, 교정 사실 자체는 근거로 남아야 한다. `deliverable_events` 에 쓸 수 있는 동작 종류(`channel_assign`)가 이미 있으니 그 형식을 참고하되, **기록 방식(직접 삽입 여부·트리거와의 관계)은 개발·데이터베이스 세션이 판단**한다
- **파일 형식(패치 SQL / 마이그레이션)과 번호는 개발 세션이 생성 시점에 확정**한다. 기획은 번호를 박지 않는다. 파일을 만들면 **절대경로를 사용자에게 먼저 명시**할 것

### 3단계 — 회복 확인

**(3-a) 데이터로 먼저 확인 (운영, 읽기 전용)**

```sql
-- ① A 그룹 잔여가 0이어야 한다 (교정이 전부 걸렸는지)
select count(*) as 남은_A그룹
  from deliverables d
 where d.kind = 'review_image' and d.post_channel = 'channel-96r9y3'
   and not exists (select 1 from deliverables x
                    where x.application_id = d.application_id
                      and x.kind = 'review_image' and x.post_channel = 'cosme');
-- 기대: 0

-- ② 옛 코드 전체 잔여 = B 그룹만 남아야 한다
select count(*) as 옛코드_잔여
  from deliverables where kind = 'review_image' and post_channel = 'channel-96r9y3';
-- 기대: 26 (1단계 직후 시점)
--   ⚠️ 이 26이 「알려진 예외」 목록의 크기가 되는 것은 **B 그룹을 「유지」로 결정한 경우**다.
--      「삭제」로 결정하면 2단계 실행 후 이 값이 0 이 되고 예외 목록 자체가 없어진다
--      (사양서 「사용자 확인 필요」 2 · 4-나 · 5단계의 분기와 같다)

-- ③ 상태가 안 바뀌었는지 — **교정한 행만** 대상으로 본다
--    ⚠️ `post_channel='cosme'` 전체로 세지 말 것: 그 안에는 B 그룹의 새 코드 행과
--       C 그룹(원래 정상) 행이 섞여 있고, 그 행들의 상태는 이 사양서가 approved 라고
--       확정한 범위가 아니다(확정된 것은 옛 코드 81행뿐) → 판정이 성립하지 않는다
select status, count(*) as 건수
  from deliverables
 where id in ( /* 0단계 (다)에서 저장해 둔 결과물id 55개 */ )
 group by status;
-- 기대: approved 55. draft·pending 이 섞이면 status 를 건드린 것 → 보고
```

**(3-b) 화면으로 확인**

- 관리자 결과물 화면에서 대상 캠페인의 **인증 상태가 「인증성공」으로 바뀌었는지** 확인(집계는 화면 진입 시 계산되므로 별도 배치 불필요)
- 인플루언서 화면 확인은 테스트 계정으로는 재현이 어렵다(본인 데이터만 보임) — 관리자 화면 회복으로 갈음하고, 필요하면 감사용 계정 동선을 검토
- **정산**: 관리자가 정산 화면에 진입하면 후보가 새로 생성된다. **먼저 생성 건수·금액 합계를 확인**하고 도입일(컷오프) 설정과의 관계를 점검한 뒤 보고. 금액이 작지 않다(리뷰어형은 제품 가격 페이백)
- 회복된 캠페인·인플루언서 목록은 **0단계 (다) 조회 결과를 교정 전에 저장해 둔 것**을 쓴다(교정 후에는 그 조회가 0행이 된다 — 반드시 교정 전에 뽑아 둘 것). 광고주 재보고 판단은 운영·영업 몫

### 4단계 — 재발 방지 (1단계와 병행 가능한 조각만)

- **(가) 원인 차단** — 기준 데이터에서 채널 코드를 완전 삭제·변경할 때 **결과물(`deliverables.post_channel`)과 캠페인(`campaigns.channel`)에 그 코드가 남아 있으면 막는다.** 현재 「사용 중이면 완전 삭제 차단」이 어디까지 보는지 확인해 범위를 넓히는 방식이 1순위. **0단계만 있으면 착수 가능**
- (나) 감지 장치와 (다) 절차 문서화는 사양서 참조 — **(나)는 2단계를 「실행」한 뒤**여야 한다. 방침을 정한 것만으로는 부족하다: 유지로 정했으면 「알려진 예외」 목록이 실제로 만들어져야 하고, 삭제로 정했으면 그 26건이 실제로 지워진 뒤여야 조회가 깨끗해진다

---

## 5. 개발 세션이 **하지 말 것**

- 마감 차단 마이그레이션을 **운영 데이터베이스에 적용** — **1단계 교정과 2단계(B 그룹 처리 실행)가 모두 끝나기 전까지 금지.** 「1단계만 끝나면 된다」가 아니다(사양서 5단계 선행 = 1 · 2). 2단계는 **결정이 아니라 실행**이며 아직 미결이라, 실질적으로 마감 차단의 운영 적용은 **미결 1번이 정해지고 실행된 뒤**에 가능하다
- B 그룹 26건 교정·삭제 (미결 사항)
- 마이그레이션 162의 채널 지정·해제·삭제 함수로 우회 시도 (전부 거부됨)
- 판정 로직(화면·인증 상태·정산 후보) 수정 — **데이터를 맞추면 함께 회복된다.** 로직을 고치면 세 곳이 서로 어긋난다
- 인플루언서 안내·연락 (운영팀 결정 사항)

---

## 6. 사용자에게 되물어야 할 미결 4건

**0단계 조사 · 1단계 교정 · 3단계 확인 · 4-가(원인 차단)는 이 결정 없이 진행할 수 있다.** 결정이 필요한 것은 **2단계(B 그룹 처리) · 4-나(감지 장치) · 5단계(마감 차단 운영 적용)** 셋뿐이다 — 이 셋이 미결 1번에 걸려 있다.

1. **B 그룹 26건 잔재** — 유지(사양서 권고) / 삭제 / 별도 보관. ⚠️ 삭제하면 `deliverable_events` 가 `ON DELETE CASCADE` 라 **승인 이력이 함께 사라진다**(대리 회수로 감사 기록을 잃은 선례가 이미 있다)
2. **광고주 재보고** — 인증성공률이 올라가는 캠페인의 이전 보고 정정 여부
3. **정산 처리** — 회복된 55건을 정산 대기로 둘지, 도입일 기준 과거분으로 다룰지
4. **인플루언서 안내** — 운영팀 결정으로 이관됨. 전달 시 **「교정 후 재업로드를 시도하면 중복 오류 화면을 보게 된다」**는 점을 함께 알려야 한다(한 인플루언서는 이미 재업로드를 예고했다)

---

## 7. 완료 후 기록 의무

- 사양서 `docs/specs/2026-07-30-review-image-channel-code-drift.md` 의 **「구현 결과」 섹션**을 채운다 — 구현일 · 관련 커밋 · 실제 교정 건수 · **확정된 마이그레이션·패치 번호** · 초안 대비 달라진 점
- 채널 코드 이관 절차를 문서화하면 `CLAUDE.md` 관련 섹션에도 반영(코드 변경은 **기준 데이터·캠페인·결과물 3곳 동시 이관**이 한 세트)
- 트리거 발동 조건 확인 결과(알림이 나가는 구조였는지)는 다음 세션이 반드시 알아야 하므로 구현 결과에 남긴다

---

## 8. 관련 파일·커밋

| 구분 | 위치 |
|---|---|
| 사양서(본체) | `docs/specs/2026-07-30-review-image-channel-code-drift.md` (커밋 `24fece0` → `f18bb43`) |
| 마감 차단 사양서 | `docs/specs/2026-07-29-deadline-server-enforcement.md` |
| 마감 차단 구현 | 커밋 `029e523`, `supabase/migrations/274_deliverable_deadline_guard.sql` |
| 인플루언서 화면 | `dev/js/application.js` — `loadDeliverablesForActivity` · `renderActivityReviewImageList` |
| 관리자 인증 상태 | `dev/js/admin-deliverables.js` — `buildDeliverableGroups` · `_finalizeMonitorReprs` · `computeCertStatus` |
| 정산 후보 | `supabase/migrations/262_settlement_amount_by_recruit_type.sql` → `264_…` — `_settlement_cert_candidates()` |
| 기존 채널 지정 도구(사용 불가) | `supabase/migrations/162_review_image_channel_assign.sql` |
| 중복 금지 제약 | `deliverables_review_image_app_channel_uniq` |
