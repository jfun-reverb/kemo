#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — `git commit` 직전, 커밋에 담긴 마이그레이션이
 * 「조회 허가를 좁히는지」와 「그 표를 아직 읽는 자리가 남았는지」를 검사한다.
 *
 * 배경: 마이그레이션 312 가 인플루언서 표의 관리자 통로를 지우면서 고칠 자리를
 *       글자 검색으로만 모아 관리자 화면 4곳이 조용히 죽었다. 허가에 막히면
 *       오류가 아니라 빈 결과라 오류 로그에도 정적 리뷰에도 안 걸린다.
 *       사양서 docs/specs/2026-08-18-blocked-admin-screen-detection.md
 *
 * 모드: 경고만 (항상 exit 0). ⚠️ 차단 모드로 바꾸지 말 것 —
 *       막으면 급할 때 우회하는 습관이 생기고, 그러면 이 장치가 죽는다.
 *
 * 안전 원칙:
 *  - 검사 스크립트가 없거나(오래된 브랜치) 실패해도 커밋을 방해하지 않는다
 *  - 출력이 길면 잘라서 보여준다(137 처럼 25개 정책을 재작성한 파일은 107줄)
 *    — 화면을 덮으면 사람이 안 읽고, 안 읽히면 장치가 없는 것과 같다
 */

const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const MAX_LINES_PER_FILE = 30;   // 파일당 출력 상한

let payload;
try { payload = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { process.exit(0); }

const cmd = (payload.tool_input && payload.tool_input.command) || '';
if (!/\bgit\s+commit\b/.test(cmd)) process.exit(0);

const cwd = payload.cwd || process.cwd();
const script = path.join(cwd, 'scripts', 'check-table-readers.mjs');
if (!fs.existsSync(script)) process.exit(0);   // 스크립트 없는 브랜치 — 조용히 통과

// 커밋에 새로 담긴 마이그레이션만 본다 (삭제·이름변경 제외 — 검사할 본문이 없다)
let files = [];
try {
  files = execSync(
    "git diff --cached --name-only --diff-filter=ACM -- 'supabase/migrations/*.sql'",
    { encoding: 'utf8', cwd }
  ).split('\n').map(s => s.trim()).filter(Boolean);
} catch { process.exit(0); }

if (!files.length) process.exit(0);

const blocks = [];
for (const f of files) {
  let out = '';
  try {
    out = execSync(`node ${JSON.stringify(script)} --sql ${JSON.stringify(f)}`,
      { encoding: 'utf8', cwd, timeout: 20000, stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    // 종료값 3(자리 남음)도 여기로 온다 — 출력은 그대로 쓴다
    out = (e.stdout || '') + (e.stderr || '');
    if (!out.trim()) continue;   // 진짜 실행 실패 — 커밋을 방해하지 않는다
  }
  // 「검사할 것이 없습니다」·「파일을 찾지 못해」 는 평소 상태라 안 보여준다
  if (/검사할 것이 없습니다|파일을 찾지 못해/.test(out)) continue;
  const lines = out.split('\n').filter(l => l.trim());
  if (!lines.length) continue;
  const shown = lines.slice(0, MAX_LINES_PER_FILE);
  if (lines.length > MAX_LINES_PER_FILE) {
    shown.push(`   … 그 밖 ${lines.length - MAX_LINES_PER_FILE}줄. 전부 보려면:`);
    shown.push(`   node scripts/check-table-readers.mjs --sql ${f}`);
  }
  blocks.push(shown.join('\n'));
}

if (!blocks.length) process.exit(0);

console.error(
  '\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' +
  '🔎 [조회 허가 좁힘 점검] 커밋에 담긴 마이그레이션을 검사했습니다.\n' +
  '   막지 않습니다 — 아래를 확인하고 그대로 커밋하셔도 됩니다.\n' +
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' +
  blocks.join('\n\n') +
  '\n\n⚠️ 「아직 읽는 자리」가 있으면 그 화면들이 조용히 빈 결과가 됩니다.\n' +
  '   오류 로그에 안 남으므로 배포 후 실제 로그인 브라우저로 눈 확인이 필요합니다.\n' +
  '   (.claude/rules/supabase.md 「접근 허가를 좁히는 변경」)\n' +
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
);
process.exit(0);
