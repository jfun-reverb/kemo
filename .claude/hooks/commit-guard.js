#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — `git commit` 직전 에이전트 호출 누락 경고.
 *
 * 모드: 경고 (warn-only) — exit 0 유지, 차단 안 함.
 *       1~2주 관찰 후 잘못된 경고 사례 정리되면 차단(exit 2) 모드로 전환 예정.
 *
 * 검사:
 *  1. transcript_path에서 최근 200줄 읽기
 *  2. `subagent_type":"reverb-reviewer"` 토큰 존재 여부
 *  3. staged 변경이 3+파일이면 `reverb-planner` 토큰 존재 여부도 검사
 *  4. supabase 관련 파일 변경이면 `reverb-supabase-expert` 토큰 검사
 *  5. 누락된 항목이 있으면 stderr에 경고만 출력 (exit 0)
 *
 * 예외:
 *  - 단일 파일 + 변경 라인 ≤5: 단순 수정으로 보고 검사 스킵
 *  - .claude/, docs/, memory/ 만 변경: 메타 파일 수정 → 스킵
 *  - revert/hotfix 키워드 포함 commit: 긴급 대응 → 스킵
 */

const { execSync } = require('child_process');
const fs = require('fs');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}

const cmd = (payload.tool_input && payload.tool_input.command) || '';
if (!/\bgit\s+commit\b/.test(cmd)) process.exit(0);

// 긴급 대응 키워드면 스킵
if (/\b(revert|hotfix|rollback)\b/i.test(cmd)) process.exit(0);

const cwd = payload.cwd || process.cwd();

// staged stat 수집
let stat = '';
let diff = '';
try {
  stat = execSync('git diff --cached --stat', { encoding: 'utf8', cwd });
  diff = execSync('git diff --cached --numstat', { encoding: 'utf8', cwd });
} catch {
  process.exit(0);
}

if (!stat) process.exit(0);

// numstat 파싱: "added\tdeleted\tpath"
const fileRows = diff
  .split('\n')
  .filter((l) => l.trim())
  .map((l) => {
    const [add, del, ...rest] = l.split('\t');
    return { add: parseInt(add, 10) || 0, del: parseInt(del, 10) || 0, path: rest.join('\t') };
  });

if (fileRows.length === 0) process.exit(0);

const totalLines = fileRows.reduce((sum, r) => sum + r.add + r.del, 0);
const onlyMeta = fileRows.every((r) =>
  /^(\.claude\/|docs\/|memory\/|.+\/memory\/)/.test(r.path)
);
const isSingleSmall = fileRows.length === 1 && totalLines <= 5;

// 단순 수정·메타 파일만이면 스킵
if (isSingleSmall || onlyMeta) process.exit(0);

// transcript에서 에이전트 호출 흔적 검색
const transcriptPath = payload.transcript_path;
let transcript = '';
if (transcriptPath && fs.existsSync(transcriptPath)) {
  try {
    const content = fs.readFileSync(transcriptPath, 'utf8');
    // 최근 200KB만 (긴 세션 OOM 방지)
    transcript = content.length > 200_000 ? content.slice(-200_000) : content;
  } catch {
    // transcript 못 읽으면 검사 못 함 → 스킵 (잘못된 경고 방지)
    process.exit(0);
  }
}

if (!transcript) process.exit(0);

const hasReviewer = /reverb-reviewer/.test(transcript);
const hasPlanner = /reverb-planner/.test(transcript);
const hasSupabaseExpert = /reverb-supabase-expert/.test(transcript);

// 판정
const warnings = [];

if (!hasReviewer) {
  warnings.push({
    level: '🔴',
    msg: 'reverb-reviewer 호출 흔적 없음 — commit 직전 reviewer 호출 의무 (.claude/rules/git.md)',
  });
}

const needsPlanner = fileRows.length >= 3;
if (needsPlanner && !hasPlanner) {
  warnings.push({
    level: '🟡',
    msg: `${fileRows.length}개 파일 변경인데 reverb-planner 호출 흔적 없음 — 정량 트리거 위반 (.claude/agents/reverb-planner.md)`,
  });
}

const supabasePathRe = /(supabase\/migrations\/|dev\/lib\/storage\.js|dev\/lib\/supabase\.js)/;
const needsSupabase = fileRows.some((r) => supabasePathRe.test(r.path));
if (needsSupabase && !hasSupabaseExpert) {
  warnings.push({
    level: '🔴',
    msg: 'Supabase/storage/migrations 변경인데 reverb-supabase-expert 호출 흔적 없음',
  });
}

if (warnings.length === 0) process.exit(0);

// 경고 출력 (차단 X)
const out = [
  '',
  '⚠️  [commit-guard 경고] — 차단되지 않지만 호출 누락 의심:',
  '',
];
for (const w of warnings) out.push(`  ${w.level} ${w.msg}`);
out.push('');
out.push(`  변경 파일 ${fileRows.length}개, 총 ${totalLines}줄`);
out.push('  경고 모드 — 의도적 스킵이면 그대로 진행, 누락이면 지금 호출 후 다시 commit');
out.push('  모드 전환 일정: 2026-05-18 차단(exit 2) 검토');
out.push('');

process.stderr.write(out.join('\n'));
process.exit(0);
