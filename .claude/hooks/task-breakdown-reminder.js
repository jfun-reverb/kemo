#!/usr/bin/env node
/**
 * UserPromptSubmit hook — 사양서 기반 개발 착수 시 「작업분해 판정」 상기 주입.
 *
 * 트리거(둘 중 하나):
 *   ① 프롬프트에 사양서 경로(docs/specs/*.md) 포함
 *   ② "사양서/스펙/spec" + 개발 동사(개발·구현·만들·추가·작업·착수) 동시 포함
 *
 * 동작: 코딩 전에 정량 기준을 보고, 하나라도 넘으면 /작업분해부터(문서까지만 자동)
 *       돌리도록 메인 Claude에게 지시 주입. 미달이면 스킵하고 바로 진행.
 *       ⚠️ 자동은 「작업표 문서」까지만 — 실제 코딩 착수는 사용자 승인 (2026-07-22 사용자 확정).
 * 출력: stdout JSON { hookSpecificOutput: { additionalContext: "..." } }, exit 0 (블로킹 아님)
 */

const input = require('fs').readFileSync(0, 'utf8');
let payload;
try { payload = JSON.parse(input); } catch { process.exit(0); }

const prompt = (payload.prompt || '');

// 트리거 판정
const hasSpecPath = /docs\/specs\/[^\s]+\.md/.test(prompt);
const hasSpecWord = /(사양서|스펙|spec)/i.test(prompt) && /(개발|구현|만들|추가|작업|착수)/.test(prompt);
if (!hasSpecPath && !hasSpecWord) process.exit(0);

const reminder = [
  '',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  '📐 [작업분해 자동 판정] — 사양서 기반 개발 착수로 감지됨.',
  '',
  '코딩을 시작하기 전에, 아래 정량 기준을 확인하세요.',
  '하나라도 넘으면 → 먼저 `/작업분해`로 작업표를 만든 뒤 착수 (자의적 스킵 금지):',
  '',
  '  □ 수정 예상 파일 3개 이상',
  '  □ 데이터베이스 변경 있음 (테이블·컬럼·함수·정책·트리거)',
  '  □ 단계(PR)가 2개 이상으로 나뉨',
  '  □ 병렬로 나눠 할 수 있는 조각이 있음',
  '',
  '기준 미달(파일 1~2개·데이터베이스 변경 없음·버그 한 줄)이면 → 작업분해 스킵, 바로 진행.',
  '',
  '⚠️ 자동은 「작업표 문서 생성」까지만. 실제 코딩 착수는 사용자 승인 후.',
  '   (구조 영향 요청 무조건 실행 금지 — .claude/rules/request-validation.md)',
  '판정 근거·양식: .claude/commands/작업분해.md',
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
