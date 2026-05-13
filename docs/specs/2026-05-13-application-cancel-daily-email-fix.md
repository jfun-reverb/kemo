# 응모 취소 일일 요약 메일 버그 수정 + 시점별 그룹화 사양서

- **작성일**: 2026-05-13
- **작성**: 기획 세션
- **상태**: 개발 착수 전 (미구현)
- **관련 Edge Function**: `notify-application-cancelled-daily`
- **관련 파일**: `docs/email-templates/application-cancelled-daily.html`, `index.ts`

---

## 1. 배경 및 확인된 버그

2026-05-13 최초 발송된 응모 취소 일일 요약 메일에서 3개 버그 + 1개 개선 요청 확인.

---

## 2. 버그 목록

### 버그 A: 개발 메모 텍스트가 이메일 본문에 그대로 노출

**원인**: `docs/email-templates/application-cancelled-daily.html` 파일의 HTML 주석(`<!-- ... -->`) 안에 `{{rows_html}}`, `{{admin_pane_url}}` 플레이스홀더가 실수로 포함되어 있음.

Edge Function의 `render()` 함수는 템플릿 전체에서 `{{플레이스홀더}}`를 모두 치환하므로, **주석 안에 있는 플레이스홀더도 실제 데이터로 치환**됨. 애플 메일 등 일부 이메일 앱이 주석 안의 HTML 내용도 렌더링하면서 주석 텍스트가 그대로 노출됨.

**현재 문제가 있는 주석 부분 (line 18-19):**
```html
<!--
  ...
  {{rows_html}}           행별 카드 HTML을 Edge Function이 누적 합쳐 삽입...  ← ❌
  {{admin_pane_url}}      관리자 신청 관리 페인 딥링크...  ← ❌
  ...
-->
```

**수정**: 주석 안의 `{{rows_html}}`과 `{{admin_pane_url}}`을 플레이스홀더가 아닌 일반 텍스트로 교체:
```html
<!--
  ...
  [취소 건 카드 목록 — rows_html 플레이스홀더로 삽입됨]
  [관리자 딥링크 — admin_pane_url 플레이스홀더로 삽입됨]
  ...
-->
```

---

### 버그 B: 요약(대상일/총건수/시점별)이 카드 목록 아래에 표시됨

**원인**: 버그 A의 결과물. 주석 안의 카드 목록이 먼저 렌더링된 후, 본문의 요약 테이블이 그 아래에 배치되어 보임.

**수정**: 버그 A 수정만으로 해결됨. 요약 테이블이 다시 맨 위에 표시됨.

---

### 버그 C: 인플루언서 이름·이메일이 "- · -"로 표시됨

**원인**: Edge Function이 `influencers` 테이블에서 `email` 컬럼을 조회하는데, `influencers` 테이블에 `email` 컬럼이 존재하지 않음. 이로 인해 조회 자체가 실패하고, 에러를 조용히 넘겨 인플루언서 정보 전체가 빈값(`-`)으로 표시됨.

**현재 문제가 있는 코드 (index.ts line ~411):**
```ts
const { data: infls, error: infErr } = await sb
  .from("influencers")
  .select("auth_id, name, name_kanji, name_kana, email")  // ← email 컬럼 없음
  .in("auth_id", userIds);
if (infErr) {
  console.warn(...)  // 에러를 경고만 하고 넘어감 → influencerMap 비어있음
}
```

**수정**:
1. `influencers` 조회에서 `email` 제거
2. 이메일은 `sb.auth.admin.getUserById(userId)`로 각 사용자별 조회 (서비스 키 권한으로 가능)
3. 결과를 `emailMap: Map<string, string>`에 저장하여 행 렌더 시 주입

---

## 3. 개선 요청: 시점별 그룹 묶기

**현재**: 취소 시간 오름차순으로 25건 나열  
**변경 후**: 취소 시점별로 그룹 묶기 (구분 헤더 추가)

그룹 순서 (시간 흐름 순):
1. 구매기간 (`purchase`)
2. 방문기간 (`visit`)
3. 결과물 제출기간 (`post`)
4. 기타 (`other` + 나머지)

각 그룹 앞에 시점 소제목 + 건수 표시. 해당 시점 건수가 0이면 그룹 전체 생략.

---

## 4. 변경 파일 목록

| 파일 | 변경 내용 |
|---|---|
| `docs/email-templates/application-cancelled-daily.html` | 버그 A: 주석 안 플레이스홀더 제거 |
| `supabase/functions/notify-application-cancelled-daily/index.ts` | 버그 C + 그룹화 |
| (자동 생성) `supabase/functions/notify-application-cancelled-daily/_templates/*.html` | sync-email-templates.sh 실행 후 자동 갱신 |
| (자동 생성) `supabase/functions/notify-application-cancelled-daily/templates.ts` | sync 후 자동 갱신 |

---

## 5. 상세 변경 내용

### 5-1. `application-cancelled-daily.html` 주석 수정

line 18-19 변경:
```html
<!-- 변경 전 -->
    {{rows_html}}           행별 카드 HTML을 Edge Function이 누적 합쳐 삽입 (행 견본은 application-cancelled-daily.row.html 참조)
    {{admin_pane_url}}      관리자 신청 관리 페인 딥링크 (filter=cancelled&date=YYYY-MM-DD)

<!-- 변경 후 -->
    [취소 건 카드 HTML — Edge Function이 rows_html 플레이스홀더로 삽입. 행 견본: application-cancelled-daily.row.html]
    [관리자 딥링크 — admin_pane_url 플레이스홀더로 삽입 (filter=cancelled&date=YYYY-MM-DD)]
```

그 외 템플릿 본문 구조는 변경 없음.

---

### 5-2. `index.ts` 변경

#### (1) 이메일 조회 추가 (버그 C 수정)

`InfluencerRow` 인터페이스에서 `email` 제거:
```ts
interface InfluencerRow {
  auth_id: string;
  name: string | null;
  name_kanji: string | null;
  name_kana: string | null;
  // email 제거
}
```

인플루언서 조회 쿼리에서 `email` 제거:
```ts
.select("auth_id, name, name_kanji, name_kana")  // email 제거
```

이메일 별도 조회 추가 (배치):
```ts
const emailMap = new Map<string, string>();
if (userIds.length > 0) {
  const emailResults = await Promise.all(
    userIds.map(id => sb.auth.admin.getUserById(id))
  );
  emailResults.forEach((result, idx) => {
    if (!result.error && result.data?.user?.email) {
      emailMap.set(userIds[idx], result.data.user.email);
    }
  });
}
```

행 렌더 시 이메일 주입:
```ts
influencer_email: escapeHtml(emailMap.get(r.user_id) || "-"),
```

#### (2) 시점별 그룹화 (개선 요청)

기존 `rowsHtml` 단순 나열 코드를 그룹화 코드로 교체:

```ts
// 시점 순서 정의 (실제 캠페인 진행 순서)
const PHASE_ORDER = ["purchase", "visit", "post", "other"];

// 그룹별 rows 분류
const phaseGroups: Record<string, CancelledRow[]> = {};
PHASE_ORDER.forEach(p => { phaseGroups[p] = []; });
rows.forEach(r => {
  const key = PHASE_ORDER.includes(r.cancel_phase) ? r.cancel_phase : "other";
  phaseGroups[key].push(r);
});

// 그룹별 HTML 생성
const rowsHtml = PHASE_ORDER
  .filter(phase => phaseGroups[phase].length > 0)
  .map(phase => {
    const phaseRows = phaseGroups[phase];
    const c = phaseColors[phase] || phaseColors.other;

    // 그룹 헤더 (시점 소제목 + 건수)
    const groupHeader = `
      <div style="margin:20px 0 10px;padding:8px 12px;background:${c.bg};border-left:3px solid ${c.fg};border-radius:0 6px 6px 0">
        <span style="color:${c.fg};font-weight:700;font-size:13px">${phaseKo(phase)}</span>
        <span style="color:${c.fg};font-size:12px;margin-left:6px">${phaseRows.length}건</span>
      </div>`;

    const cardsHtml = phaseRows
      .map(r => {
        // 기존 행 렌더 로직 동일
        const camp = campaignMap.get(r.campaign_id) || null;
        const infl = influencerMap.get(r.user_id) || { ... };
        const email = emailMap.get(r.user_id) || "-";
        // ... render(rowTpl, {...})
      })
      .join("");

    return groupHeader + cardsHtml;
  })
  .join("");
```

---

### 5-3. 인플루언서 표시 형식

행 템플릿(`row.html`)의 인플루언서 행은 변경 없음:
```html
<tr>
  <td style="...">인플루언서</td>
  <td style="...">{{influencer_name}} · {{influencer_email}}</td>
</tr>
```

단, `{{influencer_name}}`이 올바르게 조회되고, `{{influencer_email}}`이 실제 이메일(`auth.users.email`)로 채워짐.

표시 예: `야마다 하나코 (山田 花子) · hanako@example.com`

---

## 6. 배포 절차 (개발 세션용)

1. `docs/email-templates/application-cancelled-daily.html` 수정 (주석 내 플레이스홀더 제거)
2. `index.ts` 수정 (이메일 조회 추가 + 시점별 그룹화)
3. 템플릿 동기화: `bash scripts/sync-email-templates.sh`
4. Edge Function 개발서버 재배포:
   ```bash
   supabase functions deploy notify-application-cancelled-daily --project-ref qysmxtipobomefudyixw
   ```
5. 개발서버에서 수동 테스트 실행 (Edge Function POST 직접 호출로 메일 발송 확인)
6. reverb-reviewer 호출
7. dev 커밋 + 푸시
8. 사용자 확인 후 운영서버 재배포:
   ```bash
   supabase functions deploy notify-application-cancelled-daily --project-ref twofagomeizrtkwlhsuv
   ```

> ⚠ Edge Function 배포는 코드 머지와 별개로 `supabase functions deploy` 명령이 필요합니다. GitHub 자동 배포만으로는 적용 안 됩니다.

---

## 7. 검증 시나리오

**수동 테스트 (개발서버 Edge Function 직접 호출):**
```bash
curl -X POST \
  https://qysmxtipobomefudyixw.functions.supabase.co/notify-application-cancelled-daily \
  -H "Authorization: Bearer <service_role_key>" \
  -H "Content-Type: application/json" \
  -d '{}'
```

단, 같은 날짜에 이미 로그가 있으면 중복 차단됨. 개발 DB의 `application_cancel_digest_runs` 테이블에서 해당 날짜 행을 먼저 삭제 후 재실행.

**확인 체크리스트:**
- [ ] 개발 메모 텍스트가 이메일 본문에 보이지 않음
- [ ] 요약 테이블(대상일/총건수/시점별)이 맨 상단에 표시됨
- [ ] 카드 목록이 1회만 출력됨 (이전: 2회)
- [ ] 인플루언서 이름 + 이메일이 실제 값으로 표시됨
- [ ] 시점별 그룹 헤더(구매기간/결과물 제출기간/기타)가 표시됨
- [ ] 건수가 0인 시점 그룹은 표시되지 않음
- [ ] 각 그룹 내 행은 취소 시간 오름차순 정렬

---

## 8. 제외 항목 (이번 작업 범위 밖)

- 방문기간(`visit`) 그룹: 현재 방문형 캠페인 없어 실데이터 검증 불가. 코드는 포함하되 화면 검증은 추후
- 이메일 미존재 인플루언서 처리: `auth.users`에도 이메일이 없으면 `-` 표시 (기존 동일)
