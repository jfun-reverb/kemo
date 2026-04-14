---
description: 프로젝트 보안 규칙
globs: "dev/**/*.js,dev/**/*.html,supabase/**/*.sql"
---

# 프로젝트 보안 규칙

## 인증/인가
- Supabase Auth 사용; 자체 인증 로직 구현 금지
- 관리자 판별: admins 테이블의 role 컬럼 기반 (is_admin(), is_super_admin() 함수)
- 권한 체크는 RLS 정책에 의존; 클라이언트 단독 체크 금지
- 세션 만료 시 로그인 페이지로 리다이렉트
- SECURITY DEFINER 함수는 `SET search_path = ''` 필수 (search_path 탈취 방어)

## 관리자 생성/삭제
- 관리자 추가는 **초대 방식만** 사용 (`invite_admin` RPC + `resetPasswordForEmail`)
- super_admin이 비밀번호 직접 지정 금지 (이메일 유효성 미검증 + 비번 누출 위험)
- 관리자 삭제는 2택 모달로 실수 방지 (권한 해제 vs 완전 삭제)
- 자기 자신 삭제는 DB 함수에서 차단

## Supabase / RLS
- anon key는 공개 전제 (클라이언트 노출 OK) → **RLS가 유일한 방어선**
- service_role key는 절대 클라이언트 코드/repo에 노출 금지
- RLS 정책 필수: campaigns SELECT 공개, 나머지는 본인/관리자만
- 새 테이블 추가 시 RLS 정책 필수
- innerHTML에 DB 데이터 삽입 시 반드시 `esc()` 함수 사용

## 계정 열거 방지 (Account Enumeration)
- 비밀번호 찾기 응답은 조건부 메시지: "등록된 계정이라면 메일을 보냈습니다"
- 로그인 실패 시 "이메일 또는 비밀번호가 올바르지 않습니다" (둘 중 어느 것인지 구분 금지)
- 회원가입 시 기존 이메일 충돌을 사용자에게 구체적으로 노출 금지

## 비밀번호 정책
- Supabase의 HIBP (유출된 비번) 검사 활성 유지
- 관리자 비밀번호: 개발/운영 서로 다르게 설정
- SQL로 직접 해시 업데이트 시 bcrypt round 10 (`gen_salt('bf', 10)`)

## 크로스 탭 세션
- 비밀번호 재설정 진행 중 다른 탭에서 자동 로그인되는 혼선 방지
- `sessionStorage.setItem('reverb.recovery', '1')` 플래그로 reset-pw 강제 유도
- 재설정 완료 후 `signOut()` + 플래그 제거로 상태 정리

## 시크릿 / 비밀 관리
- `.env`, API Key, SMTP Password는 repo 커밋 금지 (.gitignore 반영)
- 대화 중 키가 노출되면 즉시 폐기(rotate) 권고
- Brevo SMTP Key는 서비스별로 분리 (`reverb-jp-v2` 등 이름으로 관리)

## URL/Redirect 검증
- Site URL, Redirect URLs는 `https://` 프로토콜 포함 전체 URL
- 슬래시 누락 등 오타는 치명적 (`https:/` → 모든 리다이렉트가 project URL로 폴백됨 사고 사례)
- Redirect URLs에는 와일드카드 사용 가능 (`https://globalreverb.com/**`)

## 마이그레이션 / DB 조작
- 운영 DB 수정은 항상 개발서버 먼저 → 검증 → 운영 적용
- 직접 `auth.users` UPDATE는 최후 수단 (메타데이터 누락 주의)
- 관리자 삭제는 반드시 RPC 통해서 (고아 데이터 방지)
