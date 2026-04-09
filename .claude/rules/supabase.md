---
description: Supabase DB/Storage 접근 패턴 규칙
globs: "dev/lib/*.js,dev/js/*.js"
---

# Supabase 규칙

## DB 접근 패턴
- DB 참조 시 항상 `db?.from()` 사용 (null-safe, DEMO_MODE 대응)
- `.single()` 절대 금지 → 반드시 `.maybeSingle()` 사용
- DB 함수는 반드시 `dev/lib/storage.js`에 집중 (다른 파일에서 직접 쿼리 금지)
- 새 DB 함수 추가 시 기존 패턴 따르기: `async function fetchXxx()`, `async function insertXxx()`, `async function updateXxx()`

## 테이블 참조
- `campaigns` — 캠페인 (status: draft/scheduled/active/closed)
- `influencers` — 인플루언서 프로필 (id = auth.users.id)
- `applications` — 신청 (status: pending/approved/rejected)
- `admins` — 관리자 (role: super_admin/campaign_admin/campaign_manager)

## RLS 주의사항
- campaigns: SELECT 공개, CUD는 관리자만
- influencers: 본인 데이터만 SELECT/UPDATE, 관리자는 전체 SELECT
- applications: 본인 INSERT/SELECT, 관리자는 전체 접근
- 새 테이블 추가 시 반드시 RLS 정책 포함

## Storage
- 이미지 업로드: Supabase Storage `campaign-images` 버킷 사용
- `uploadImage()` 함수 사용 (dev/lib/storage.js)
- localStorage에 base64 이미지 직접 저장 금지 (용량 초과 위험)

## localStorage 폴백 (DEMO_MODE)
- Supabase 미연결 시 자동으로 localStorage 동작
- DB 함수에서 `if (!db)` 체크 후 localStorage 폴백 처리
- localStorage 저장 시 이미지 데이터는 별도 키로 분리
