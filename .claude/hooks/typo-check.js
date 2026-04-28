#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — git commit 직전 오탈자 검출.
 *
 * 로직:
 *  1. tool_input.command 에 `git commit` 포함 여부 확인
 *  2. `git diff --cached` 로 staged 내용 수집
 *  3. typo-patterns.js의 ALL 패턴으로 grep
 *  4. 발견 시 stderr에 경고 + exit 2 로 차단
 *
 * 패턴은 typo-patterns.js에서 import (memory/feedback_korean_typos.md와 동기화).
 */

const { execSync } = require('child_process');
const fs = require('fs');
const { ALL } = require('./typo-patterns.js');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}

const cmd = (payload.tool_input && payload.tool_input.command) || '';

// git commit 명령만 대상 (git log, git status 등은 제외)
if (!/\bgit\s+commit\b/.test(cmd)) process.exit(0);

let diff;
try {
  // .claude/hooks/* 와 memory/feedback_korean_typos.md 는 패턴 정의 파일이므로 제외
  diff = execSync(
    "git diff --cached -- . ':(exclude,top).claude/hooks/*.js' ':(exclude,top)*/memory/feedback_korean_typos.md'",
    { encoding: 'utf8', cwd: payload.cwd || process.cwd() }
  );
} catch {
  process.exit(0);
}

if (!diff) process.exit(0);

// staged 내용의 `+` 라인만 추출 (삭제 라인은 무시)
const addedLines = diff
  .split('\n')
  .filter((line) => line.startsWith('+') && !line.startsWith('+++'))
  .map((line) => line.slice(1))
  .join('\n');

const hits = [];
for (const { bad, good } of ALL) {
  let count = 0;
  let sample = '';
  let idx = 0;
  while ((idx = addedLines.indexOf(bad, idx)) !== -1) {
    count++;
    if (!sample) {
      const start = Math.max(0, idx - 30);
      const end = Math.min(addedLines.length, idx + bad.length + 30);
      sample = addedLines.slice(start, end).replace(/\n/g, ' ').slice(0, 120);
    }
    idx += bad.length;
  }
  if (count > 0) hits.push({ bad, good, count, sample });
}

if (hits.length === 0) process.exit(0);

const lines = [
  '',
  '🚨 [한국어 오탈자 감지 — commit 차단]',
  '',
  'staged 파일에서 확정 오탈자가 발견됐습니다:',
  ''
];
for (const h of hits) {
  lines.push(`  ❌ "${h.bad}" → "${h.good}"  (${h.count}건)`);
  lines.push(`     예시: ${h.sample}`);
}
lines.push('');
lines.push('수정 후 다시 커밋하세요.');
lines.push('패턴 출처: .claude/hooks/typo-patterns.js');
lines.push('');

process.stderr.write(lines.join('\n'));
process.exit(2);
