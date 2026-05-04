#!/usr/bin/env node
/**
 * SessionStart hook — 매 세션 시작 시 에이전트 호출 체크리스트 컨텍스트 주입.
 *
 * 메인 Claude가 컨텍스트 상단에서 항상 호출 의무를 인지하도록 강제.
 * (planner 정량 트리거, qa-tester light/full 분기, reviewer 매 commit 의무)
 *
 * 출력: stdout JSON { hookSpecificOutput: { hookEventName, additionalContext } }
 * exit 0 유지.
 */

const fs = require('fs');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  // payload 없어도 그냥 체크리스트 주입
  payload = {};
}

const checklist = [
  '',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  '🛡️  [REVERB 에이전트 호출 의무 — 이번 세션]',
  '',
  '🟢 reverb-planner — 다음 중 하나라도 해당되면 코드 작성 전 반드시 호출:',
  '   □ 3개 이상 파일 동시 수정 예상',
  '   □ 신규 DB 컬럼/테이블/RPC/RLS 추가',
  '   □ UI 재설계(폼 구조 변경·신규 모달·새 페인)',
  '   □ 동일 영역 3커밋 이상 연쇄 예상',
  '',
  '🟢 reverb-reviewer — 모든 commit 직전 1회 (예외: 단순 한 줄 오탈자만)',
  '   □ 보고 마지막 줄에 "qa-tester 권장: light/full/skip" 명시',
  '',
  '🟢 reverb-supabase-expert — 다음 변경 시 코드 쓰기 전 호출:',
  '   □ Auth/PKCE/세션/identities 변경',
  '   □ supabase/migrations/ 신규 파일',
  '   □ dev/lib/storage.js, dev/lib/supabase.js 수정',
  '   □ RLS 정책 추가/변경',
  '',
  '🟢 reverb-qa-tester — 모드 분기:',
  '   □ Light(S5+S6): 관리자 페인 변경 — 컬럼·필터·모달 UI',
  '   □ Full(S1~S7): 인증/응모 플로우 변경 또는 main merge 직전',
  '   □ Skip: 문서/주석/CSS 미세 조정 단독',
  '',
  '⚠️  자체 판단 스킵 금지. "작은 변경이니까" 핑계 반복 위반 사례 누적 중',
  '   (memory/feedback_agent_invocation_gaps.md 참조)',
  '',
  '📝 [약어·전문용어 자제 — 사용자는 비개발자]',
  '   □ FK/RPC/RLS/RBAC/DDL/DML/R-S 등 단독 사용 금지 → 한글 풀이 (또는 "한글(약어)" 병기)',
  '   □ 자릿수 표시 NNNN/### → "4자리 숫자" / "3자리 숫자"',
  '   □ 서브 에이전트 답변 약어도 메인 Claude가 한글로 재가공 후 전달',
  '   □ AskUserQuestion 옵션 label·description 모두 한글 풀이',
  '   (.claude/rules/interaction.md "약어·전문용어 자제" 섹션 참조)',
  '',
  '🔔 commit-guard hook이 git commit 직전 누락 감지 시 경고 출력',
  '   (2026-05-18 차단 모드 전환 검토 예정)',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  '',
];

const out = {
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: checklist.join('\n'),
  },
};

process.stdout.write(JSON.stringify(out));
process.exit(0);
