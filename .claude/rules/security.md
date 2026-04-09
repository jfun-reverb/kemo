---
description: 보안 가드레일
globs: "*"
---

# 보안 규칙

## 인증/인가
- Supabase Auth 사용; 자체 인증 로직 구현 금지
- 관리자 판별: admins 테이블의 role 컬럼 기반 (is_admin(), is_super_admin() 함수)
- 권한 체크는 RLS 정책에 의존; 클라이언트 단독 체크 금지
- 세션 만료 시 로그인 페이지로 리다이렉트

## 시크릿/자격증명
- .env, API 키, 시크릿 커밋 금지
- 소스 코드에 비밀번호/토큰 하드코딩 금지
- Supabase anon key는 공개용이므로 예외 (publishable key)
- 민감 데이터 (비밀번호, 토큰, 은행정보) 로그 기록 금지

## 입력값 처리
- 사용자 입력값은 처리 전 반드시 검증
- HTML 출력 시 XSS 방지: textContent 사용, innerHTML 최소화
- innerHTML 사용 시 사용자 입력값은 반드시 이스케이프
- Supabase 쿼리는 파라미터화 (.eq(), .match() 등) 사용; 문자열 연결 금지

## 데이터 보호
- influencers 테이블의 개인정보 (주소, 전화, 은행정보)는 본인/관리자만 접근
- 캠페인 삭제 시 관련 applications도 함께 삭제 (데이터 고아 방지)
- 비밀번호 변경은 Supabase Auth API 사용
