#!/usr/bin/env node
/**
 * UserPromptSubmit hook — "개발세션" 지정 시 걸려있는 일감(백로그) 확인 지시 주입.
 *
 * 트리거: 프롬프트에 "개발세션" / "개발 세션" 포함 시
 *   (예: "넌 개발세션이야", "개발 세션 시작", "개발세션으로 진행해줘")
 *
 * 동작: 코드 작업 시작 전에 백로그부터 확인하도록 메인 Claude에게 지시 주입.
 * 출력: stdout JSON { hookSpecificOutput: { additionalContext: "..." } }
 * exit 0 유지 (블로킹 아님)
 */

const input = require('fs').readFileSync(0, 'utf8');
let payload;
try { payload = JSON.parse(input); } catch { process.exit(0); }

const prompt = (payload.prompt || '');

// 트리거: "개발세션" 또는 "개발 세션" (공백 0~1개 허용)
if (!/개발\s?세션/.test(prompt)) process.exit(0);

const reminder = [
  '',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  '🛠️  [개발 세션 지정 감지] — 코드 작업 시작 전, 걸려있는 일감(백로그)부터 확인하세요.',
  '',
  '아래 3곳을 점검하고 사용자에게 한국어로 요약 보고 후, 무엇부터 할지 물어볼 것:',
  '',
  '1) 메모리 백로그 — MEMORY.md에서 "백로그 / 보류 / 남음 / 미착수 / 다음 세션 / 운영 보류" 항목 스캔',
  '   (특히 ⚠️·★ 표시, "운영 보류"·"PR N 백로그"·"다음 세션" 키워드)',
  '2) 미완 사양서 — docs/specs/ 에서 "구현 결과" 섹션이 비어있거나 "(개발 세션이 채울 것)" 인 것,',
  '   또는 "운영 보류" 상태인 사양서',
  '3) git 상태 — 현재 브랜치 / origin/dev 대비 stale(뒤처짐) 여부 / 미머지 PR(gh pr list)',
  '',
  '주의:',
  '- 한 번에 다 나열하지 말고, 우선순위가 높아 보이는 것부터 추려 보고할 것',
  '- 참조 번호(§N·PR N·마이그레이션 N)는 반드시 한글 제목과 함께 (.claude/rules/interaction.md)',
  '- 멀티세션: 동시 작업이면 worktree 분리 (.claude/rules/multi-session.md)',
  '- 구조 영향 요청은 무조건 실행 말고 현재 구조 적합성 먼저 검토 (.claude/rules/request-validation.md)',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  ''
].join('\n');

const out = {
  hookSpecificOutput: {
    hookEventName: 'UserPromptSubmit',
    additionalContext: reminder
  }
};
process.stdout.write(JSON.stringify(out));
process.exit(0);
