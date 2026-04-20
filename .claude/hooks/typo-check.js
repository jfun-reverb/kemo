#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — git commit 직전 오탈자 검출.
 *
 * 로직:
 *  1. tool_input.command 에 `git commit` 포함 여부 확인
 *  2. `git diff --cached` 로 staged 내용 수집
 *  3. 알려진 오탈자 패턴 grep
 *  4. 발견 시 stderr에 경고 + exit 2 로 차단 (사용자가 승인 시 통과)
 *
 * 오탈자 리스트는 memory/feedback_korean_typos.md 와 동기화 필요.
 */

const { execSync } = require('child_process');
const fs = require('fs');

const input = fs.readFileSync(0, 'utf8');
let payload;
try { payload = JSON.parse(input); } catch { process.exit(0); }

const cmd = (payload.tool_input && payload.tool_input.command) || '';

// git commit 명령만 대상 (git log, git status 등은 제외)
if (!/\bgit\s+commit\b/.test(cmd)) process.exit(0);

// 오탈자 패턴 — memory/feedback_korean_typos.md 참조
// (확정된 오탈자만. 회색지대 단어는 false-positive 유발하므로 제외)
const patterns = [
  { bad: '캐페인', good: '캠페인' },
  { bad: '캐웩인', good: '캠페인' },
  { bad: '캠패인', good: '캠페인' },
  { bad: '켐페인', good: '캠페인' },
  { bad: '행버거', good: '햄버거' },
  { bad: '재생각', good: '다시 생각' },
  { bad: '돿습', good: '됐습' },
  { bad: '바뀍니다', good: '바뀝니다' },
  { bad: '뗴다가', good: '떼다가' },
  { bad: '컨텐츠', good: '콘텐츠' },
  { bad: '메세지', good: '메시지' }
];

let diff;
try {
  // typo-check.js 자체가 오탈자 패턴 문자열을 포함하므로 자기 자신은 검사에서 제외.
  // 필요 시 다른 hook 파일도 같이 제외할 수 있도록 .claude/hooks/*.js 전체 pathspec 사용.
  diff = execSync(
    "git diff --cached -- . ':(exclude,top).claude/hooks/*.js'",
    { encoding: 'utf8', cwd: payload.cwd || process.cwd() }
  );
} catch {
  process.exit(0); // git 명령 실패 시 조용히 통과
}

if (!diff) process.exit(0);

const hits = [];
for (const { bad, good } of patterns) {
  // staged 내용의 `+` 라인만 체크 (삭제 라인은 무시)
  const re = new RegExp('^\\+[^+].*' + bad, 'gm');
  const matches = diff.match(re);
  if (matches && matches.length > 0) {
    hits.push({ bad, good, count: matches.length, sample: matches[0].slice(0, 120) });
  }
}

if (hits.length === 0) process.exit(0);

// 오탈자 발견 → stderr에 경고 + exit 2로 차단
const lines = [
  '',
  '🚨 [한국어 오탈자 감지 — commit 차단]',
  '',
  'staged 파일에서 확정 오탈자가 발견됐습니다:',
  ''
];
for (const h of hits) {
  lines.push(`  ❌ "${h.bad}" → "${h.good}" (${h.count}건)`);
  lines.push(`     예시: ${h.sample}`);
}
lines.push('');
lines.push('수정 후 다시 커밋하세요.');
lines.push('정말 이대로 커밋해야 하면 이 hook을 임시로 무시하는 방법은 .claude/hooks/typo-check.js 수정');
lines.push('');

process.stderr.write(lines.join('\n'));
process.exit(2); // Claude가 이 결과를 보고 수정 후 재시도
