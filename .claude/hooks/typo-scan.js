#!/usr/bin/env node
/**
 * 한국어 오탈자 스캐너 (CLI).
 *
 * 사용법:
 *   node .claude/hooks/typo-scan.js                 # staged 파일만 스캔 (commit 직전 검증용)
 *   node .claude/hooks/typo-scan.js --working       # working tree 변경 파일 (uncommitted)
 *   node .claude/hooks/typo-scan.js --branch main   # 현재 브랜치 vs main 변경 파일 전체
 *   node .claude/hooks/typo-scan.js path1 path2     # 명시 파일만 스캔
 *
 * 출력:
 *   파일별로 라인 + 오탈자 + 권장 수정안.
 *   발견 시 exit code 2 (CI/hook 호환), 깨끗하면 exit code 0.
 *
 * 패턴: typo-patterns.js (single source of truth).
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const { ALL, findTypos } = require('./typo-patterns.js');

const args = process.argv.slice(2);

function run(cmd) {
  try {
    return execSync(cmd, { encoding: 'utf8', cwd: process.cwd() });
  } catch {
    return '';
  }
}

function listStaged() {
  return run('git diff --cached --name-only --diff-filter=ACMR')
    .split('\n')
    .filter(Boolean);
}

function listWorking() {
  return run('git diff --name-only --diff-filter=ACMR')
    .split('\n')
    .filter(Boolean);
}

function listBranchDiff(base) {
  return run(`git diff ${base}...HEAD --name-only --diff-filter=ACMR`)
    .split('\n')
    .filter(Boolean);
}

// 검사 제외 경로 (패턴 정의 파일·메모리 등 false positive 발생 영역)
function shouldSkip(filePath) {
  if (filePath.includes('/.claude/hooks/')) return true;
  if (filePath.endsWith('feedback_korean_typos.md')) return true;
  if (filePath.includes('/memory/') && filePath.endsWith('.md')) return true;
  // 바이너리/이미지 등 텍스트 아닌 파일
  if (/\.(png|jpg|jpeg|gif|webp|pdf|zip|woff2?|ttf|otf|ico)$/i.test(filePath)) return true;
  return false;
}

function getFiles() {
  if (args.length === 0) return listStaged();
  if (args[0] === '--working') return listWorking();
  if (args[0] === '--branch') return listBranchDiff(args[1] || 'main');
  return args;
}

const files = getFiles();
if (files.length === 0) {
  console.log('[typo-scan] 검사할 파일이 없습니다.');
  process.exit(0);
}

let totalHits = 0;
const report = [];

for (const file of files) {
  if (shouldSkip(file)) continue;
  if (!fs.existsSync(file)) continue;

  let content;
  try {
    content = fs.readFileSync(file, 'utf8');
  } catch {
    continue;
  }

  const lines = content.split('\n');
  const lineHits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const hits = findTypos(line, ALL);
    if (hits.length > 0) {
      lineHits.push({ lineNum: i + 1, line: line.trim(), hits });
    }
  }

  if (lineHits.length > 0) {
    totalHits += lineHits.reduce((s, x) => s + x.hits.length, 0);
    report.push({ file, lineHits });
  }
}

if (report.length === 0) {
  console.log(`[typo-scan] ✅ ${files.length}개 파일 검사 완료 — 오탈자 없음`);
  process.exit(0);
}

console.error('');
console.error('🚨 [한국어 오탈자 감지]');
console.error('');
for (const { file, lineHits } of report) {
  console.error(`📄 ${file}`);
  for (const { lineNum, line, hits } of lineHits) {
    const fixes = hits.map((h) => `"${h.bad}" → "${h.good}"`).join(', ');
    console.error(`  L${lineNum}: ${fixes}`);
    console.error(`         ${line.slice(0, 120)}`);
  }
  console.error('');
}
console.error(`총 ${totalHits}건 오탈자 / ${report.length}개 파일`);
console.error('패턴 출처: .claude/hooks/typo-patterns.js');
console.error('');

process.exit(2);
