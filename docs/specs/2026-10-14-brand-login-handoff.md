# 인수인계 — 브랜드 페이지 로그인 기능 (2026-10-14)

> 이전 세션의 맥락이 커져 새 세션으로 넘긴다. **이 문서 + 사양서 `docs/specs/2026-07-15-brand-portal.md` §16-6(착수 전 결정)** 만 읽으면 이어갈 수 있게 썼다.
> 작업 폴더 `/Users/choiwooyoung/kemo-브랜드포털` · 브랜치 `feature/브랜드-로그인화면` · Figma 파일 `XG4hXdgySeN45Ele3EnN8H` 「[1차] 01 로그인」 섹션(노드 34:1153)

## 1. 지금까지 한 것 (브랜치 `feature/브랜드-로그인화면` 에 커밋됨 — 원격에는 아직 안 올림)

| 파일 | 내용 |
|---|---|
| `dev/brand/index.html` | 로그인 전 화면 8개(w01-00·01·01a·02(+02b)·03·04·05 + 운영용 「준비 중」). 미리보기 막대에 「계정 종류」 선택 추가 |
| `dev/css/brand.css` | Figma 값 그대로(색 변수 `--b-*`). 좁은 화면(600px 이하)은 m01-00 — 입력 글자만 16px(아이폰 확대 방지) |
| `dev/js/brand-core.js` | 화면 전환·칸 오류 표시·이메일 형식·비밀번호 규칙(`brandPasswordIssue` — ⚠️ `ui.js`·`admin-setpw.html` 과 같은 규칙의 셋째 사본)·보기 단추·`BRAND_AUTH_STORAGE_KEY='reverb.brandAuth'` |
| `dev/js/brand-login.js` | 화면별 동작. 서버 결과는 `brandFakeRequest`(미리보기 막대 값)로 흉내 — **이 자리를 실제 호출로 바꾸는 것이 3단계** |
| `dev/js/brand-app.js` | 부팅·`#해시` 전환·개발서버 미리보기 막대. 운영 주소(`IS_STAGING=false`)면 「준비 중」만 |
| `docs/specs/2026-07-15-brand-portal.md` | §16-6 「착수 전 결정」 추가 |

- 로컬 확인: `cd dev && python3 -m http.server 8765 --bind 127.0.0.1` → `http://127.0.0.1:8765/brand/index.html` (w01-00·m01-00·③④⑤·w01-02·w01-01a 를 Figma 와 대조 완료, 콘솔 오류 0)
- 확인 안 한 상태: ②·⑥·⑦ 화면 상태, w01-01·03·04·05 화면
- Figma 와 일부러 다른 곳: 눈 아이콘(Figma 는 외곽선 그림 → Material Icons `visibility` 사용, 프로젝트 규칙) · 모바일 입력 16px
- 🔴 `dev/brand/` 는 `.vercelignore` 의 `dev` 제외 때문에 **개발서버에서도 안 열린다** → 3단계에서 루트 `brand/index.html` 산출물로 빌드

## 2. 결정 — 사양서 §16-6 이 정본

요지: 대표 담당자 이메일을 **새로 넣거나 고쳐 저장할 때만** 자동 발송(캠페인 관리자 이상) · 범위는 대표 계정~로그인~비밀번호 찾기~관리자 계정 상태 줄 · 별도 회원 표 · **운영 반영 보류**(브랜드 약관 문서 + §16-3 9번 판단 뒤).

## 3. 계획 (reverb-planner 결과 요약 — 번호는 박지 않았다)

순서 원칙: **데이터베이스 → 서버 함수 → 화면**. 마이그레이션은 한 세션에서만.

**1단계 — 데이터베이스**
- 새 표: 브랜드 계정(`auth_id` 기본 키·소문자 이메일·이름·전화·`password_set_at`·약관/방침 동의 시각·약관 판 문자열·최신 링크 식별자 `setup_link_id`·발송 시각/주소) · 계정↔브랜드 연결(`role owner|member`·`status`·브랜드 참조 `ON DELETE RESTRICT`·브랜드당 활성 대표 1명 부분 유일) · 브랜드 비밀번호 찾기 요청 기록(243 복제 — 이메일 해시만). 모두 **쓰기 정책 없음**(함수만), 읽기는 본인 또는 `is_admin()`
- 가입 트리거 `handle_new_user` — **420 원본 그대로 `CREATE OR REPLACE`** + 맨 앞 `NEW.raw_app_meta_data->>'account_kind'='brand'` 면 `RETURN NEW`. 🔴 **사용자 메타데이터가 아니라 앱 메타데이터**(사용자 메타데이터면 비로그인 가입으로 누구나 우회). 🔴 브랜드 계정 표 행 유무로 판정 금지(트리거 시점엔 아직 없다)
- 인플루언서 행 삽입 거부 트리거(브랜드 계정이면 거부) — 🔴 인플루언서 앱 로그인 `auth.js` 594행 부근이 프로필이 없으면 `upsertInfluencer` 로 **새로 만든다** + 삽입 정책(137)이 로그인한 누구에게나 열려 있다 → 서버 두 겹 필요
- 함수: 계정 생성(관리자 세션 · 안쪽에서 캠페인 관리자 이상 재확인 · 브랜드 단위 잠금 · `lower(btrim())` 비교 · 결과 `created`/`noop`/`email_replaced`/`conflict_*`/`password_already_set`/`primary_moved` 등 + `needs_mail`) — 계정은 **invite_admin(417) 방식으로 `auth.users`·`auth.identities` 직접 삽입**, `email_confirmed_at=now()` · 링크 상태 확인 · 설정 완료(서버 시각으로 동의 기록) · 로그인 판정(`not_brand`/`setup_incomplete`/`no_active_brand`) · 비밀번호 찾기 요청 제한(서비스 키 전용)
  - ✅ 확인됨: 위 방식이면 가입 인증번호 관문(497 — `current_user<>'supabase_auth_admin'` 통과)·재발송 관문(497)·미인증 정리(498 — `email_confirmed_at IS NULL` 만) 모두 통과. 🔴 `auth.admin.createUser` 로 만들면 497 에 걸린다
- 실행 권한: 회수 방향 둘 다(PUBLIC · anon/authenticated) — CLAUDE.md 「RLS·인증·세션」
- 기존 함수: `delete_brand`(191)가 연결 표를 세게 · `merge_brands`(현재 원본 **467**)는 원본 브랜드에 활성 연결이 있으면 거부(1차 최소안)

**2단계 — 서버 메일 함수**
- `notify-brand-account-setup`(`notify-admin-invite` 복제): 대상은 요청 본문이 아니라 `brand_id` 로 서버가 다시 읽음 · `generateLink(recovery)` · 링크 `…/brand/?link=<식별자>#confirm=<원래 링크>`(열기만으로는 소진 안 되는 방식 재사용 — `admin-setpw.html` 의 「계속하기」) · 비밀값 `PUBLIC_BRAND_URL` · 개발서버만 링크를 응답에 싣는 **두 겹 잠금**(가입 인증번호 `SIGNUP_CODE_DEV_ECHO` 방식)
- `brand-password-reset-request`(`admin-password-reset-request` 복제): 비로그인 · 늘 `{ok:true}` · 설정 완료면 재설정 링크, 설정 전이면 설정 메일 재발송 · 공개 키 거부 걸지 말 것
- 메일 양식 `docs/email-templates/brand-account-setup.html`·`brand-password-reset.html` → `bash scripts/sync-email-templates.sh`. §16-3 2번 문장(누가·왜·모르면 무시) + §16-3 9번 용도 안내 자리

**3단계 — 브랜드 화면 연결 + 빌드**
- `dev/build.sh` 에 브랜드 산출물(`../brand/index.html`) — 🔴 목록과 원본 태그 지우는 정규식 **두 곳**
- supabase 라이브러리 `@2.116.0/dist/umd/supabase.js` 싣기 → CLAUDE.md 「8개 HTML」이 9개
- 🔴 `dev/lib/supabase.js` 는 라이브러리가 있으면 **기본 저장 칸 + `detectSessionInUrl:true`** 로 전역 `db` 를 만든다 → 브랜드 화면이 먼저 「건너뛰기 표시」를 두면 만들지 않게 그 파일에 조건 한 줄(사용자 결정 위임 — 이전 세션이 이 방식으로 정함)
- 전용 연결: `storageKey:'reverb.brandAuth'`·`flowType:'pkce'` · 설정 화면은 `persistSession:false` + 끝나면 `signOut()`(admin-setpw 방식)
- `brandFakeRequest` 자리 교체 · 로그인 뒤 임시 첫 화면

**4단계 — 인플루언서 앱 차단**: `auth.js` `handleLogin`(관리자 확인 다음, 프로필 조회 **전**) · `app.js` 부팅·로그인 이벤트 두 자리. 🔴 판정 **조회 실패**면 프로필 자동 생성으로 떨어지지 않게(실패 `null` ≠ 「아님」). 문구는 일반 실패 문구

**5단계 — 관리자 화면**: `admin-brand.js` `saveBrandDetail`(2227행 부근)·`submitNewBrand` → 저장 성공 뒤 계정 생성 함수 → 필요하면 메일 함수 → 결과별 안내. 🔴 **브랜드 저장 성공과 계정 생성 실패를 따로 알린다**. 계정 줄만 다시 그린다(편집 폼이라 본문 재그리기 금지 — `brand-admin.md`). `storage.js`(핫스팟)에 함수 3개

**6단계 — 문서**: 기능 커밋마다 `FEATURE_SPEC.md`·`CLAUDE.md`·사양서 「구현 결과」 같은 커밋

**회귀 확인(개발서버)**: 인플루언서 신규 가입 1회 · 관리자 초대 1회 · 인플루언서 비밀번호 찾기 1회 · 같은 브라우저 인플루언서 탭·브랜드 탭이 서로 로그아웃 안 시킴

## 4. 다음 세션이 할 일 (순서)

1. 이 문서 + 사양서 §16-6 읽기
2. **`/작업분해`** — 위 단계로 작업표(데이터베이스 변경·단계 다섯이라 규칙상 필수)
3. **`reverb-supabase-expert`** 로 1단계 설계 검토 → 마이그레이션 작성(번호는 그때 `ls supabase/migrations | tail -5` 로 확정 — 다른 세션의 마이그레이션 작업 여부를 사용자에게 한 번 묻기)
4. 개발서버 데이터베이스 적용 → 위 회귀 확인
5. 커밋 전 매번 `reverb-reviewer`

## 5. 아직 아무도 안 한 것 / 열린 질문
- 대시보드 「Email OTP Expiration」(링크 유효 시간) 현재값 확인 — 사용자 결정은 「확인 후 유지」
- Figma w01-02 에 「계속하기」 한 단계(링크만 열어서는 소진 안 되게)가 그려져 있는지 — 없으면 화면 상태 하나 추가
- 비밀번호 찾기 링크를 열면 갈 화면(w01-02 를 약관 칸 없이 재사용 예정) — Figma 에 별도 재설정 화면 없음
- 사양서 §16 본문 다시 쓰기(§16-6 반영)·§15 a03-01 정리 — 기획 몫, 규칙 C 대상
- 운영 반영 전 관문: 브랜드용 이용약관·개인정보처리방침 문서 + `/약관확인`(§16-3 9번)
