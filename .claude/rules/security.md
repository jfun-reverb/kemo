---
description: 프로젝트 보안 규칙
globs: "dev/**/*.js,dev/**/*.html"
---

# 프로젝트 보안 규칙

## 인증/인가
- Supabase Auth 사용; 자체 인증 로직 구현 금지
- 관리자 판별: admins 테이블의 role 컬럼 기반 (is_admin(), is_super_admin() 함수)
- 권한 체크는 RLS 정책에 의존; 클라이언트 단독 체크 금지
- 세션 만료 시 로그인 페이지로 리다이렉트

## Supabase 보안
- anon key는 공개용 (publishable key)
- RLS 정책 필수: campaigns SELECT 공개, 나머지는 본인/관리자만
- innerHTML에 DB 데이터 삽입 시 반드시 esc() 함수 사용
