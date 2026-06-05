#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Write|Edit) — 메인 폴더에서 코드 파일을 처음
 * 수정할 때 "worktree(별도 작업 폴더)로 분리하라"는 경고를 1회 띄운다.
 *
 * 동작:
 *  - 차단하지 않음(exit 0). stdout 의 systemMessage 로 사용자에게 경고만 전달.
 *  - 단독 시퀀셜 작업자는 경고를 무시하고 그대로 진행 가능(규칙상 메인 폴더 OK).
 *  - 세션당 1회만 — 마커 파일이 있으면 조용히 통과.
 *
 * 발동 조건(모두 충족 시):
 *  1. 현재 작업트리가 메인 폴더일 것
 *     - 메인 폴더는 `.git` 이 디렉토리, worktree 는 `.git` 이 파일(gitdir 포인터)
 *  2. 수정 대상이 코드성 파일일 것 — dev/ · supabase/ 또는 빌드 산출물
 *     (index.html / admin/index.html). 거버넌스 문서(.claude/ · docs/ · 메모리)는
 *     고문/기획이 메인 폴더에서 직접 수정하는 게 정상이므로 제외 → 자동으로 안 걸림.
 *
 * 왜 차단(exit 2)이 아니라 경고(exit 0)인가:
 *  - 단독 시퀀셜 작업도 막으면 기존 규칙(multi-session.md "혼자면 메인 OK")과 충돌.
 *  - 후크는 "다른 세션이 떠 있는지" 알 수 없으므로 강제할 수 없고, 경고만 한다.
 *
 * 규칙 근거: .claude/rules/session-roles.md §1
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync } = require('child_process');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}

const toolName = payload.tool_name || '';
if (toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

const filePath = (payload.tool_input && payload.tool_input.file_path) || '';
if (!filePath || !path.isAbsolute(filePath)) process.exit(0);

// 파일이 속한 작업트리 최상위 경로
let toplevel;
try {
  const dir = path.dirname(filePath);
  toplevel = execSync('git rev-parse --show-toplevel', {
    cwd: dir,
    stdio: ['ignore', 'pipe', 'ignore'],
  })
    .toString()
    .trim();
} catch {
  process.exit(0);
}
if (!toplevel) process.exit(0);

// 메인 폴더 판정: `.git` 이 디렉토리면 메인, 파일이면 worktree
let isMain = false;
try {
  const gitEntry = path.join(toplevel, '.git');
  isMain = fs.existsSync(gitEntry) && fs.statSync(gitEntry).isDirectory();
} catch {
  process.exit(0);
}
if (!isMain) process.exit(0);

// 코드성 파일만 — 거버넌스 문서(.claude/ · docs/)는 아래 조건에 안 걸려 자동 제외
const rel = filePath.startsWith(toplevel + path.sep)
  ? filePath.slice(toplevel.length + 1)
  : filePath;
const isCode =
  rel.startsWith('dev/') ||
  rel.startsWith('supabase/') ||
  rel === 'index.html' ||
  rel === 'admin/index.html';
if (!isCode) process.exit(0);

// 세션당 1회 마커 (session_id 없으면 날짜로 폴백)
const sessionId = payload.session_id || `date-${new Date().toISOString().slice(0, 10)}`;
const marker = path.join(os.tmpdir(), `reverb-mainfolder-guard-${sessionId}`);
if (fs.existsSync(marker)) process.exit(0);
try {
  fs.writeFileSync(marker, String(Date.now()));
} catch {
  // 마커를 못 쓰면 매번 뜨는 것보다 조용히 통과
  process.exit(0);
}

const msg = [
  '⚠️ 메인 폴더에서 코드 파일 수정이 감지됐습니다.',
  '   다른 세션과 동시 작업 중이면 /새세션 으로 worktree(별도 작업 폴더)를 분리하세요.',
  '   혼자 시퀀셜 작업이면 이 경고는 무시하고 진행해도 됩니다.',
  '   (규칙: .claude/rules/session-roles.md §1)',
].join('\n');

process.stdout.write(JSON.stringify({ systemMessage: msg }));
process.exit(0);
