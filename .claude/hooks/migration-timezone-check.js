#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — `git commit` 직전, 커밋에 담긴 마이그레이션이
 * 「시간대 없는 날짜·시각 문자열」을 시각 칸에 쓰고 있는지 검사한다.
 *
 * 배경(2026-08-25): 회원가입 동의 소급 마이그레이션에서 `'2026-04-13'` 처럼
 *   시간대 없는 문자열이 협정 세계시 자정(일본 시각 09:00)으로 해석돼,
 *   실제 배포 시각(16:32)과 7시간 30분 어긋났다. 그대로 갔으면 그 사이
 *   가입한 회원에게 「받은 적 없는 동의 기록」이 생길 뻔했다.
 *   규칙 `.claude/rules/release-timing.md` 「타임존 명시 의무」가 이미 있었지만
 *   사람 눈으로만 지키던 자리라, 검토가 실행 직전에 겨우 잡았다.
 *
 * 왜 커밋 시점인가:
 *   파일을 만드는 시점(Write/Edit)에 걸면 **Bash 로 파일을 쓰는 세션에서 안 돈다.**
 *   이 저장소 세션들은 시스템 지시상 Bash(heredoc·python)로 파일을 쓰는 일이 많아,
 *   `matcher: Write|Edit` 후크는 그 경로를 구조적으로 못 본다.
 *   커밋 시점은 **파일을 어떻게 만들었든** 스테이징된 내용을 보므로 확실히 걸린다.
 *   개발서버 적용보다는 늦지만 **운영 적용 전에는** 걸린다.
 *
 * 모드: 경고만 (항상 exit 0). ⚠️ 차단으로 바꾸지 말 것 —
 *   막으면 급할 때 우회하는 습관이 생기고, 그러면 이 장치가 죽는다
 *   (기존 migration-narrowing-check.js 와 같은 판단).
 */

const { execSync } = require('child_process');

let payload;
try { payload = JSON.parse(require('fs').readFileSync(0, 'utf8')); } catch { process.exit(0); }
if ((payload.tool_name || '') !== 'Bash') process.exit(0);

const cmd = (payload.tool_input && payload.tool_input.command) || '';
if (!/\bgit\s+commit\b/.test(cmd)) process.exit(0);

const cwd = payload.cwd || process.cwd();

// 날짜/시각 문자열 리터럴 — '2026-04-13' · '2026-04-13 16:32' · '2026-04-13T16:32:00'
const DATE_LITERAL = /'(\d{4})-(\d{2})-(\d{2})([ T][\d:.]+)?'/;
// 시간대를 밝힌 흔적 — 이게 같은 줄에 있으면 통과
const TZ_MARK = /\+09|AT\s+TIME\s+ZONE|Asia\/Tokyo|::date\b|timezone\s*\(/i;
// 시각 칸을 다루는 줄인가 — 이 저장소는 시각 칸이 관례적으로 _at 으로 끝난다
const TIME_CTX = /_at\b|timestamptz/i;

let files = [];
try {
  files = execSync(
    "git diff --cached --name-only --diff-filter=ACM -- 'supabase/migrations/*.sql'",
    { encoding: 'utf8', cwd }
  ).split('\n').map(s => s.trim()).filter(Boolean);
} catch { process.exit(0); }
if (!files.length) process.exit(0);

const hits = [];
for (const f of files) {
  let body = '';
  try { body = execSync(`git show :${JSON.stringify(f)}`, { encoding: 'utf8', cwd }); }
  catch { continue; }               // 읽지 못하면 커밋을 방해하지 않는다
  body.split('\n').forEach((line, i) => {
    const t = line.trim();
    if (!t || t.startsWith('--')) return;          // 빈 줄·주석 제외
    if (!DATE_LITERAL.test(line)) return;
    if (!TIME_CTX.test(line)) return;
    if (TZ_MARK.test(line)) return;
    hits.push(`   ${f}:${i + 1}  ${t.slice(0, 100)}`);
  });
}
if (!hits.length) process.exit(0);

const MAX = 12;
const shown = hits.slice(0, MAX);
if (hits.length > MAX) shown.push(`   … 그 밖 ${hits.length - MAX}줄`);

const msg = [
  '⏰ [시간대 확인] 마이그레이션에 시간대 없는 날짜·시각 문자열이 있습니다',
  '',
  ...shown,
  '',
  '   시간대 없는 문자열은 협정 세계시로 읽혀 일본 시각과 9시간 어긋납니다.',
  "   의도한 게 일본 시각이면 `'2026-04-13 00:00+09'` 처럼 밝혀 적으십시오.",
  '   날짜만 다루는 칸(date)이라 시간대가 무관하면 그대로 두면 됩니다.',
  '   (규칙: .claude/rules/release-timing.md 「자동 시행 ON — 시각 판정 위치」)',
].join('\n');

process.stdout.write(JSON.stringify({ systemMessage: msg }));
process.exit(0);
