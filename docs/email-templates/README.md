# REVERB JP — 메일 템플릿 카탈로그

> 서비스에서 발송되는 모든 메일의 source of truth. 시각적 미리보기는 [`index.html`](./index.html)을 브라우저로 열어 확인.

## 폴더 구조

```
docs/email-templates/
├── index.html                       # 카탈로그 (브라우저로 열어 미리보기)
├── README.md                        # 이 문서
│
├── confirm-signup.html              # ① Auth · 회원가입 확인 (운영서버만)
├── confirm-signup.preview.html
│
├── reset-password.html              # ② Auth · 비밀번호 재설정
├── reset-password.preview.html
│
├── brand-admin-notify.html          # ③ Brand · 관리자 알림
├── brand-admin-notify.preview.html
│
├── brand-ack-reviewer.html          # ④ Brand · 신청 확인 (Qoo10 리뷰어)
├── brand-ack-reviewer.preview.html
│
├── brand-ack-seeding.html           # ⑤ Brand · 신청 확인 (나노 시딩)
└── brand-ack-seeding.preview.html
```

## 파일 명명 규칙

| 파일 | 역할 |
|---|---|
| `{name}.html` | 발송용 템플릿. `{{placeholder}}` 포함. **source of truth** |
| `{name}.preview.html` | 메일 클라이언트 frame + 샘플 데이터로 렌더된 미리보기 |

## 메일 카테고리

### Auth (Supabase 자동 발송)
| 메일 | 트리거 | 수신자 | 관리 위치 |
|---|---|---|---|
| `confirm-signup.html` | 인플루언서 회원가입 (운영서버만) | 본인 | Supabase 대시보드 → Email Templates → Confirm signup |
| `reset-password.html` | 비밀번호 찾기 / 관리자 초대 | 본인 / 신규 관리자 | Supabase 대시보드 → Email Templates → Reset password |

이 두 메일은 Supabase가 직접 SMTP(Brevo)로 발송. **HTML 수정 후 Supabase 대시보드에 수동 복사·붙여넣기** 필요. 환경별로 양 프로젝트(운영/개발) 모두 적용.

Placeholder는 Supabase가 자동 치환하는 Go template 문법 (`{{ .ConfirmationURL }}` 등). 우리 시스템이 치환하지 않음.

### Brand (Edge Function `notify-brand-application` 발송)
| 메일 | 트리거 | 수신자 |
|---|---|---|
| `brand-admin-notify.html` | `brand_applications` INSERT | `admins.receive_brand_notify=true` ∪ `NOTIFY_ADMIN_EMAILS` |
| `brand-ack-reviewer.html` | `brand_applications` INSERT (form_type='reviewer') | 신청자 본인 |
| `brand-ack-seeding.html` | `brand_applications` INSERT (form_type='seeding') | 신청자 본인 |

이 3개 메일은 Edge Function이 `_templates/` 디렉토리의 미러본을 읽어서 placeholder 치환 후 Brevo API로 발송. **HTML 수정 후 sync 스크립트 실행 필수** (아래 참고).

## Placeholder 문법 (Edge Function 메일)

이중 중괄호 `{{key}}` (공백 없음). 단순 문자열 치환만 지원. 조건부 섹션·반복은 Edge Function 측에서 미리 빌드된 HTML 문자열로 치환.

| Placeholder | 예시 값 | 용도 |
|---|---|---|
| `{{application_no}}` | `JFUN-Q-20260420-001` | 신청번호 |
| `{{form_label}}` | `Qoo10 리뷰어 모집` | 폼 종류 라벨 |
| `{{brand_name}}` | `테스트브랜드` | 브랜드명 |
| `{{contact_name}}` | `홍길동` | 담당자 이름 |
| `{{phone}}` | `010-1234-5678` | 연락처 |
| `{{email}}` | `hong@test.com` | 담당자 이메일 |
| `{{billing_email_row}}` | `<tr>...</tr>` | 계산서 행 (없으면 빈 문자열) |
| `{{estimated_krw}}` | `₩ 41,250` | 예상 견적 (포맷팅 적용) |
| `{{products_html}}` | `<table>...</table>` | 제품 테이블 (없으면 빈 문자열) |
| `{{request_note_html}}` | `<div>...</div>` | 요청사항 박스 (없으면 빈 문자열) |
| `{{deep_link}}` | `https://globalreverb.com/admin/#brand-applications?id=...` | 관리자 페이지 딥링크 |

각 템플릿이 사용하는 placeholder 목록은 파일 상단 주석에 명시.

## Edge Function 동기화

`docs/email-templates/`가 source of truth. Edge Function 배포 시점에 `_templates/` 미러로 복사 필요.

```bash
# 광고주 메일 3종 → Edge Function 디렉토리로 복사
bash scripts/sync-email-templates.sh
```

이후 `git add` + commit. CI에서 두 디렉토리 diff 검증 (TODO).

### 왜 미러가 필요한가
Supabase Edge Function은 함수 디렉토리(`supabase/functions/{name}/`)만 번들 배포. 외부 파일(`docs/`)은 자동 포함되지 않음. Edge Function이 `Deno.readTextFile()`로 같은 디렉토리의 `_templates/*.html`을 읽어 placeholder 치환 후 발송.

## 미리보기 갱신

### Auth 메일 (`confirm-signup.preview.html`, `reset-password.preview.html`)
`<iframe src="{name}.html">`로 본문 직접 임베드. 템플릿 수정 시 미리보기 자동 반영.

### Brand 메일 (`brand-*.preview.html`)
샘플 데이터로 placeholder를 치환한 결과를 inline으로 보유. **템플릿 수정 시 미리보기도 같이 수동 갱신** 필요. 수정 후 동기화는 reviewer 호출 시 검증 항목.

> 향후 sync 스크립트가 미리보기까지 자동 생성하도록 확장 예정.

## 미구현 (TODO)

인플루언서 비즈니스 로직 메일 — 트리거 지점은 정해져 있으나 발송 코드 부재. 자세한 목록은 `index.html` 하단 카드 참고.

추가 시 작업 순서:
1. `docs/email-templates/{name}.html` 작성 (placeholder 포함)
2. `docs/email-templates/{name}.preview.html` 작성 (샘플 데이터)
3. `index.html`에 카드 등록 (disabled → enabled로)
4. Edge Function 추가 또는 기존 Edge Function 확장
5. sync 스크립트 갱신
6. README.md "메일 카테고리" 표 갱신

## 관련 문서

- 양 환경 SMTP/Auth 설정: [`/.claude/rules/supabase.md`](../../.claude/rules/supabase.md) §SMTP / 이메일
- Brevo 플랜·발신 도메인 인증: 같은 문서
- 약관·개인정보처리방침 영향: 새 메일 추가 시 [`/.claude/rules/policy.md`](../../.claude/rules/policy.md) 점검
