#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Bash) — `git commit` 직전 에이전트 호출 누락 경고.
 *
 * 모드(2026-08-20 부터):
 *   - **신규 마이그레이션이 있는데 데이터베이스 전문가 실제 호출이 없으면 차단(exit 2)**
 *   - 그 외 누락은 경고만(exit 0)
 *   차단을 하나로 좁힌 이유 = 그 조항이 예외가 가장 적고, 실측에서 2주간 5건이 빠졌다.
 *
 * ⚠️ 2026-08-20 에 고친 결함 셋 (셋 다 「조용히 통과」 유형이었다):
 *   1. 판정이 이름 문자열만 봐서 **대화에서 언급만 해도 통과**했다 → 실제 호출 형태로
 *   2. 기록을 최근 200KB 만 봤다. 긴 세션은 6MB 를 넘어 **실제 호출이 창 밖으로 밀려** 오판
 *   3. 경고만 하고 안 막았다
 *
 * 검사:
 *  1. transcript_path 에서 최근 구간 읽기
 *  2. 실제 호출 형태(`subagent_type":"reverb-reviewer"`) 존재 여부 — 이름만으론 안 됨
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
    // ⚠️ 창이 좁으면 실제 호출이 밀려나 「안 불렀다」로 오판한다.
    //    이 프로젝트의 긴 세션은 6MB 를 넘는다 — 200KB 는 최근 3% 밖에 못 본다.
    const WINDOW = 1_500_000;
    transcript = content.length > WINDOW ? content.slice(-WINDOW) : content;
  } catch {
    // transcript 못 읽으면 검사 못 함 → 스킵 (잘못된 경고 방지)
    process.exit(0);
  }
}

if (!transcript) process.exit(0);

// ⚠️ 이름만 찾으면 안 된다 — 규칙 문서를 읽기만 해도 그 이름이 기록에 남아 통과한다.
//    실제 호출은 subagent_type 파라미터로 남고, 중첩 기록에서는 따옴표가 이스케이프된다.
//    두 형태를 모두 받는다: subagent_type":"이름   /   subagent_type\":\"이름
function calledAgent(name) {
  const re = new RegExp('subagent_type\\\\?"\\s*:\\s*\\\\?"' + name);
  return re.test(transcript);
}
const hasReviewer = calledAgent('reverb-reviewer');
const hasPlanner = calledAgent('reverb-planner');
const hasSupabaseExpert = calledAgent('reverb-supabase-expert');

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

// 신규 마이그레이션 파일이 있는가 — 차단 대상은 이것 하나뿐이다
let addsNewMigration = false;
try {
  const st = execSync('git diff --cached --name-status', { encoding: 'utf8', cwd });
  addsNewMigration = st.split('\n').some((l) => /^A\s+supabase\/migrations\//.test(l));
} catch { /* 못 읽으면 차단하지 않는다 — 조회 실패로 작업을 막지 않는다 */ }

let blocking = false;
if (needsSupabase && !hasSupabaseExpert) {
  if (addsNewMigration) {
    blocking = true;
    warnings.push({
      level: '🛑',
      msg: '신규 마이그레이션이 있는데 reverb-supabase-expert 를 실제로 호출한 흔적이 없음 — 차단',
    });
  } else {
    warnings.push({
      level: '🔴',
      msg: 'Supabase/storage 변경인데 reverb-supabase-expert 호출 흔적 없음',
    });
  }
}

if (warnings.length === 0) process.exit(0);

// 탈출구 — 정당한 예외를 막아 작업이 멈추는 쪽이 더 나쁘다.
// 쓴 사실은 경고로 남겨 사후에 보이게 한다.
const skipMatch = cmd.match(/\[guard-skip:([^\]]*)\]/);
if (blocking && skipMatch) {
  process.stderr.write(`\n⚠️  [commit-guard] 차단을 건너뜁니다 — 사유: ${skipMatch[1].trim() || '(안 적음)'}\n\n`);
  blocking = false;
}

const out = [
  '',
  blocking
    ? '🛑 [commit-guard] 커밋을 막았습니다:'
    : '⚠️  [commit-guard 경고] — 차단되지 않지만 호출 누락 의심:',
  '',
];
for (const w of warnings) out.push(`  ${w.level} ${w.msg}`);
out.push('');
out.push(`  변경 파일 ${fileRows.length}개, 총 ${totalLines}줄`);
if (blocking) {
  out.push('  → reverb-supabase-expert 를 호출해 마이그레이션을 검토받은 뒤 다시 커밋하세요.');
  out.push('  → 정당한 예외라면 커밋 메시지에 [guard-skip: 사유] 를 넣으면 통과합니다(사유가 기록에 남습니다).');
} else {
  out.push('  경고 모드 — 의도적 스킵이면 그대로 진행, 누락이면 지금 호출 후 다시 commit');
}
out.push('');

process.stderr.write(out.join('\n'));
process.exit(blocking ? 2 : 0);
