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
 *  2. 실제 호출 형태 존재 여부 — 이름만 언급된 것으로는 안 된다.
 *     ⚠️ 그 형태를 여기에 글자 그대로 적지 않는다. 적으면 이 파일을 읽는 것만으로
 *        기록에 그 글자가 들어가 「불렀다」로 오판된다(2026-08-20 리뷰 지적).
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

// --- 내용이 없는 병합 커밋은 건너뛴다 (2026-08-25) ---
// dev → main 병합처럼 「구성 커밋은 이미 다 검토받았고 병합 자체엔 새 내용이
// 0줄」인 경우, 스테이징에는 상대 브랜치 내용이 통째로 올라와 가드가 걸린다.
// 실제로 2026-08-25 에 정당한 운영 배포 병합이 막혀 사람이 [guard-skip:] 으로
// 넘겼다 — 그 우회가 습관이 되면 이 가드가 죽으므로 자동 판정으로 바꾼다.
// ⚠️ 충돌을 해소하며 코드를 고친 병합은 결과 트리가 어느 부모와도 달라져
//    그대로 걸린다. 「검토 없이 새 코드가 들어오는」 경우는 놓치지 않는다.
// ⚠️ 리뷰에서 실측으로 확인한 두 가지(막지는 않는다):
//  - 소스 브랜치의 그 커밋이 애초에 [guard-skip:] 으로 개별 검토를 건너뛴
//    것이었다면 이 분기가 그 미검토 상태를 그대로 통과시킨다. 기존 탈출구의
//    신뢰 사슬 문제이지 이 분기가 새로 만든 구멍은 아니다.
//  - 부모가 셋 이상인 병합에서 MERGE_HEAD 가 여러 줄이면 rev-parse 는 첫 줄만
//    돌려준다. git 이 그런 상태를 남기지 않아 실제로는 도달 불가.
let mergeHead = '';
try {
  mergeHead = execSync('git rev-parse -q --verify MERGE_HEAD', {
    encoding: 'utf8', cwd, stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
} catch {
  mergeHead = '';
}
if (mergeHead) {
  const sameAs = (ref) => {
    try {
      execSync(`git diff --cached --quiet ${ref}`, { cwd, stdio: 'ignore' });
      return true;
    } catch {
      return false;   // 차이가 있으면 exit 1 → 여기로 온다
    }
  };
  if (sameAs('HEAD') || sameAs(mergeHead)) {
    process.stderr.write(
      '\n✅ [commit-guard] 내용이 없는 병합 커밋입니다 — 검사를 건너뜁니다.\n' +
      '   (병합 결과가 한쪽 부모와 글자 단위로 같습니다. 구성 커밋은 각자 검토를 거쳤습니다.)\n\n'
    );
    process.exit(0);
  }
}

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

// 신규 마이그레이션이 있는가 — 예외 게이트보다 **먼저** 본다.
// ⚠️ 뒤에 두면 한 줄짜리 신규 마이그레이션이 「단순 수정」으로 걸러져 검사가 통째로
//    스킵된다. 마이그레이션은 짧을수록 안전한 것이 아니다 — 정책 삭제·권한 부여는
//    한 줄이다(2026-08-20 리뷰 지적).
let addsNewMigration = false;
try {
  const st = execSync('git diff --cached --name-status', { encoding: 'utf8', cwd });
  addsNewMigration = st.split('\n').some((l) => /^A\s+supabase\/migrations\//.test(l));
} catch { /* 못 읽으면 차단하지 않는다 — 조회 실패로 작업을 막지 않는다 */ }

// 단순 수정·메타 파일만이면 스킵 (신규 마이그레이션이 있으면 스킵하지 않는다)
if (!addsNewMigration && (isSingleSmall || onlyMeta)) process.exit(0);

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
//    두 형태를 모두 받는다 — 그 열쇠말 뒤에 콜론과 따옴표가 바로 이어지는 형태,
//    그리고 따옴표마다 앞에 백슬래시가 하나씩 붙는 중첩 기록 형태.
function calledAgent(name) {
  // ⚠️ 찾을 글자를 소스에 그대로 두지 않고 조립한다.
  //    그대로 두면 이 파일을 읽는 것만으로 기록에 그 글자가 들어가 오판된다.
  const KEY = 'subagent_' + 'type';
  const re = new RegExp(KEY + '\\\\?"\\s*:\\s*\\\\?"' + name);
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
