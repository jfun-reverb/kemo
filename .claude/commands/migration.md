---
description: Supabase 마이그레이션 파일을 만든다 (인자: 바꿀 내용)
---

Supabase 마이그레이션 생성:

1. **이해**: 필요한 스키마 변경 — $ARGUMENTS
2. **기존 스키마 확인**:
   - supabase/migrations/ 폴더의 기존 마이그레이션 읽기
   - 현재 테이블 구조 파악 (campaigns, influencers, applications, admins)
3. **번호 결정**: 만들기 직전 `git pull origin dev` 뒤 기존 최대 번호 + 1 (`two-developers.md` 2조)
4. **SQL 작성**:
   - 테이블/컬럼 추가: `IF NOT EXISTS` 사용
   - 테이블/컬럼 삭제: `IF EXISTS` 사용
   - 새 테이블 시 RLS 정책 필수 포함:
     - `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;`
     - SELECT/INSERT/UPDATE/DELETE 정책
   - 적절한 인덱스 추가
   - 트리거 필요 시 함수 + 트리거 생성
5. **리뷰**: 마이그레이션 SQL을 사용자에게 제시하고 확인 대기
6. **파일 생성**: `supabase/migrations/3자리 숫자_설명.sql` — 🔴 **새 파일 양식**(`.claude/rules/supabase.md` 「새 파일 양식」): 주석을 뺀 본문이 `BEGIN;` 으로 시작해 `COMMIT;` 으로 끝나고, `COMMIT;` 바로 앞에 자기 기록 줄 `INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '<번호>', '<파일 이름>');`. 안 맞으면 병합 요청 검사가 막는다(`node scripts/check-migrations.js --base dev` 로 미리 확인)
