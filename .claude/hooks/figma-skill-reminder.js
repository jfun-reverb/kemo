#!/usr/bin/env node
/**
 * UserPromptSubmit hook — 피그마 작업 요청이면 reverb-figma 스킬을 먼저 부르게 상기시킨다.
 *
 * 트리거: 프롬프트에 「피그마」·「figma」(figma.com 주소 포함)가 있을 때
 * 출력: additionalContext 짧은 두 줄 — 매번 뜨므로 길게 쓰지 않는다
 * exit 0 유지 (막지 않음)
 *
 * 왜: 스킬 설명·planning.md 안내만으로는 세션이 스킬을 건너뛸 수 있다.
 *   특히 대화가 길어져 요약된 뒤 피그마 작업을 이어갈 때(2026-10-14 사용자 결정).
 *   규칙 정의처: ~/.claude/rules/common-planning.md 규칙 E · .claude/skills/reverb-figma/SKILL.md
 */

const input = require('fs').readFileSync(0, 'utf8');
let payload;
try { payload = JSON.parse(input); } catch { process.exit(0); }

// 다른 세션이 보낸 메시지는 사용자가 친 말이 아니다(reviewer-reminder.js 와 같은 판정)
const raw = String(payload.prompt || '');
if (raw.trimStart().startsWith('<cross-session-message')) process.exit(0);

const prompt = raw.toLowerCase();
if (!prompt.includes('피그마') && !prompt.includes('figma')) process.exit(0);

const reminder = [
  '🎨 [피그마 작업] 피그마를 그리거나 고치는 작업이면 이번 세션에서 아직 안 불렀을 때 `reverb-figma` 스킬을 먼저 부른다(그다음 `figma:figma-use`).',
  '   그리기 전 기준 보고(어느 화면 스타일·현재 동작) → 그리기 → 결정은 사양서로. 질문만 하는 경우는 해당 없음.'
].join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: reminder }
}));
process.exit(0);
