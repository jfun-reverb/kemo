Supabase 데이터베이스 상태 확인:

1. **연결 확인**: Supabase REST API로 각 테이블 쿼리
   - URL: https://twofagomeizrtkwlhsuv.supabase.co
   - anon key 사용
2. **테이블별 확인**:
   - `campaigns` — 행 수, status별 분포 (draft/scheduled/active/closed), 최근 생성일
   - `influencers` — 행 수, 최근 가입일
   - `applications` — 행 수, status별 분포 (pending/approved/rejected), 최근 신청일
   - `admins` — 행 수, role별 분포
3. **이상 감지**:
   - 연결 실패 시 에러 메시지 보고
   - HTTP 상태 코드 확인
   - 빈 테이블 경고
4. **결과 요약**: 테이블별 상태 표로 정리
