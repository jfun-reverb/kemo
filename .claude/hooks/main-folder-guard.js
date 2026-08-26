#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Write|Edit|Bash) — 메인 폴더에서 코드 파일을 처음
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
 * ⚠️ 2026-08-25 추가 — Bash 경로:
 *   이 저장소 세션들은 시스템 지시상 파일을 Bash(heredoc·python)로 쓰는 일이 많다.
 *   그러면 matcher 가 Write|Edit 뿐이라 **이 후크가 구조적으로 안 돈다.**
 *   실제로 개발 세션이 메인 폴더에서 브랜치를 세 번 갈아타며 작업하는 동안
 *   경고를 한 번도 못 봤다. 그래서 Bash 도 본다 — 두 신호:
 *     (1) 브랜치 전환 명령(git checkout/switch)의 대상이 dev·main 이 아닐 때
 *         → 「메인 폴더인데 기능 브랜치」의 진입 지점. ⚠️ 다만 `--` 가 붙은
 *           파일 복원(git checkout <ref> -- <경로>)은 전환이 아니라 제외한다.
 *     (2) 명령문이 dev/·supabase/ 경로에 쓰기를 하려 할 때(오탐 감수 — 경고 1회)
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
const isBash = toolName === 'Bash';
if (!isBash && toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

// --- Bash 경로: 명령문에서 판정한다(파일 경로 인자가 없다) ---
let bashReason = '';
if (isBash) {
  const cmd = (payload.tool_input && payload.tool_input.command) || '';
  if (!cmd) process.exit(0);

  // (1) 브랜치 전환 — 대상이 dev·main 이 아니면
  // ⚠️ `git checkout <ref> -- <경로>` 는 브랜치 전환이 아니라 파일 복원이다.
  //    `--` 가 있으면 통째로 제외한다(리뷰에서 오탐으로 잡힘).
  if (!/\s--(\s|$)/.test(cmd)) {
    const sw = cmd.match(/\bgit\s+(?:checkout|switch)\s+(?:-[bBc]\s+)?([^\s;&|]+)/);
    if (sw && !sw[1].startsWith('-')) {
      const target = sw[1].replace(/^origin\//, '');
      if (target !== 'dev' && target !== 'main') bashReason = `브랜치 전환: ${sw[1]}`;
    }
  }
  // (2) 코드 경로에 쓰기 — 「쓰기 동작의 대상이 코드 경로인가」를 본다.
  //     명령 아무 데나 `>` 가 있으면 잡던 옛 방식은 `grep dev/x > /tmp/out` 을 오탐했다.
  if (!bashReason) {
    const C = '(?:\\./)?(?:dev|supabase)/';
    const w = [
      new RegExp('>>?\\s*["\']?' + C),                          // cat > dev/…
      new RegExp('\\b(?:sed\\s+-i|tee)\\b[^;&|]*' + C),           // sed -i … dev/…
      new RegExp('\\b(?:cp|mv|rsync)\\b[^;&|]*\\s["\']?' + C),    // cp … dev/…
    ].some((re) => re.test(cmd));
    // 스크립트 안에서 쓰는 경우 — writeFileSync( 는 .write( 로 안 잡힌다(리뷰 지적)
    const progWrite =
      /writeFileSync\(|\.write\(|write_text\(|open\([^)]*["']w["']/.test(cmd) &&
      new RegExp(C).test(cmd);
    if (w || progWrite) bashReason = '코드 경로 쓰기';
  }
  if (!bashReason) process.exit(0);
}

const filePath = isBash ? '' : ((payload.tool_input && payload.tool_input.file_path) || '');
if (!isBash && (!filePath || !path.isAbsolute(filePath))) process.exit(0);

// 파일이 속한 작업트리 최상위 경로
let toplevel;
try {
  const dir = isBash ? (payload.cwd || process.cwd()) : path.dirname(filePath);
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
if (!isBash && !isCode) process.exit(0);

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
  isBash
    ? `⚠️ 메인 폴더에서 코드 작업이 감지됐습니다 (${bashReason}).`
    : '⚠️ 메인 폴더에서 코드 파일 수정이 감지됐습니다.',
  '   다른 세션과 동시 작업 중이면 /새세션 으로 worktree(별도 작업 폴더)를 분리하세요.',
  '   혼자 시퀀셜 작업이면 이 경고는 무시하고 진행해도 됩니다.',
  '   (규칙: .claude/rules/session-roles.md §1)',
].join('\n');

process.stdout.write(JSON.stringify({ systemMessage: msg }));
process.exit(0);
