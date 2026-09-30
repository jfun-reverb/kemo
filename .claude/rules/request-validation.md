# 수정 요청 구조 적합성 검토 규칙 (영구) — REVERB 세부

> **원칙 정의처는 전역 `~/.claude/rules/common-request-validation.md`** (세션별 역할 · 적용 대상 · 낱말 전파 점검 · 이름 전파 점검(세 형태) · 행동 순서 · 적용 제외 · 사고 경위). 여기는 이 저장소에서 **실제로 어디를 찾는지**만 적는다.
>
> 한 줄 요약: 개발 세션은 구조 영향 있는 요청을 **바로 코딩하지 않고** 현재 구조와 맞는지 먼저 보고, 안 맞거나 애매하면 `AskUserQuestion` 으로 되묻는다. 설계 분기가 크면 `reverb-planner` 또는 기획 세션으로.

## 낱말 전파 점검 — 옛 표현을 찾을 5곳

1. `dev/` — 인플루언서 화면·관리자 화면·번역 파일(`dev/lib/i18n/{ja,ko}.js`)
2. `supabase/functions/` — 메일 본문(일일 다이제스트·승인 안내·검수 결과·홍보 메일)
3. `docs/email-templates/` (+ `_templates/` 미러)
4. 자주 묻는 질문 자동응답 — `faq_nodes` 시드·마이그레이션 (`supabase/migrations/`·`supabase/seed/`)
5. 엑셀 내보내기 열 이름 (`dev/js/admin-excel.js`)

대상 예시(이 저장소 낱말): 「영수증 제출 마감일」·「모집 기간」·「선정 기간」 / 「인증 성공」·「검수 불필요」·「정산대기」 / 「최대 ¥N」·「페이백」 / 모집 형식·채널 이름.

## 이름 전파 점검 — 세 형태의 REVERB 실제 경로

| 형태 | REVERB 실제 사례 | 찾는 법 |
|---|---|---|
| ① 그대로 적힌 것 | `db.from('influencers')` | `grep -rn "from('이름')" dev/` |
| ② **인자·변수로 넘기는 것** | `_proxyFetchByIds('influencers', …)` (admin-deliverables.js) | `grep -rnE "\.from\(\s*[A-Za-z_$]" dev/` 로 **표 이름을 변수로 받는 헬퍼**를 먼저 찾고 그 호출부를 본다 |
| ③ **조회문 안쪽에 끼어 있는 것** | `.select('*, influencers:influencer_id (…)')` (storage.js·event-scan.html) | `grep -rnE "이름[a-z_]*\s*:\s*[a-z_]+\s*\(" dev/` |

**찾는 범위에 반드시 넣을 것**
- `dev/js/`·`dev/lib/` 뿐 아니라 **`dev/*.html` 자립형 단독 화면**(`event-scan.html`·`admin-setpw.html`) — `storage.js` 를 안 쓰고 **자체 조회**를 가져 공용 함수를 고쳐도 안 따라온다
- `supabase/functions/` (메일·웹훅) — 서비스 키라 허가 변경엔 안 걸리지만 같은 이름이면 함께 고칠 대상

⚠️ **리뷰어에게 맡겨도 면제되지 않는다** — 리뷰 요청 때 **「세 형태를 다 봤는지」를 지목해서** 시킨다(전역 규칙의 사고가 이 저장소에서 났다).

## 관련
- [`interaction.md`](interaction.md) 「변경 프로세스」 · 메모리 `feedback_change_request_routing` · `feedback_main_session_advisor_role`
- 낱말 전파 사고 실제 커밋: `04e2142a`·`8203d061`(영수증 마감 이름 — 메일이 2주 이른 날짜를 5일간 안내)
