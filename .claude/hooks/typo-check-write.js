#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Write|Edit) — 파일 작성 직전 한국어 오탈자 차단.
 *
 * 차단 대상:
 *  - Write: tool_input.content
 *  - Edit:  tool_input.new_string
 *
 * 한글 포함 라인만 검사하므로 영어/일본어 코드는 무관. 자기 자신 (.claude/hooks/*) 은
 * 패턴 문자열을 정의 목적으로 가지고 있으므로 검사 제외.
 */

const fs = require('fs');
const path = require('path');
const { findTypos, ALL } = require('./typo-patterns.js');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}

const toolName = payload.tool_name || '';
const input = payload.tool_input || {};
const filePath = input.file_path || '';

// .claude/hooks/ 자체는 검사 제외 (패턴 정의 파일이므로 false positive)
if (filePath.includes('/.claude/hooks/')) process.exit(0);

// memory/feedback_korean_typos.md 도 패턴 사례를 본문에 포함하므로 제외
if (filePath.endsWith('feedback_korean_typos.md')) process.exit(0);

// 검사할 텍스트 추출
let text = '';
if (toolName === 'Write') {
  text = input.content || '';
} else if (toolName === 'Edit') {
  text = input.new_string || '';
} else {
  process.exit(0);
}

const hits = findTypos(text, ALL);
if (hits.length === 0) process.exit(0);

const lines = [
  '',
  '🚨 [한국어 오탈자 감지 — Write/Edit 차단]',
  '',
  `대상 파일: ${filePath || '(unknown)'}`,
  '',
  '확정 오탈자가 발견됐습니다. 수정 후 다시 시도하세요:',
  ''
];
for (const h of hits) {
  lines.push(`  ❌ "${h.bad}" → "${h.good}"  (${h.count}건)`);
  lines.push(`     주변: ...${h.sample}...`);
}
lines.push('');
lines.push('패턴 출처: .claude/hooks/typo-patterns.js (memory/feedback_korean_typos.md 동기화)');
lines.push('');

process.stderr.write(lines.join('\n'));
process.exit(2);
