#!/usr/bin/env node
/**
 * PreToolUse hook (matcher: Write|Edit|Bash) — 프론트 화면 파일을 처음 만질 때
 * 디자인 스킬 사용을 상기시킨다.
 *
 * 동작:
 *  - dev/ 폴더 아래 .html / .css 파일을 Write 또는 Edit 하려 할 때 발동
 *  - 세션당 1회만: 처음 발동 시 마커 파일을 만들고 exit 2 로 잠깐 멈춰
 *    메인 Claude 에게 알림을 전달 (Claude 는 스킬 호출 후, 혹은 그대로 다시
 *    편집을 재실행하면 통과)
 *  - 마커가 이미 있으면 조용히 통과 (exit 0) → 같은 세션에서 다시는 안 멈춤
 *
 * 왜 exit 2(잠깐 멈춤)인가:
 *  - PreToolUse 에서 exit 0 + stderr 는 사용자에게만 보이고 Claude 의 판단에는
 *    확실히 닿지 않는다(commit-guard 가 warn-only 인 이유). 스킬을 "확실히"
 *    쓰게 하려면 한 번은 Claude 컨텍스트에 들어가야 하므로 첫 1회만 멈춘다.
 *
 * 안내하는 스킬(상황별):
 *  - 새 화면을 처음 만들 때 → example-skills:frontend-design
 *    (⚠️ document-skills:frontend-design 은 실재하지 않는 이름 — 2026-09-02 정정)
 *  - 기존 화면을 고치거나 다듬을 때 → ui-ux-pro-max
 *
 * 제외:
 *  - dev/ 밖 파일(루트 빌드 산출물 index.html / admin/index.html 등)
 *  - .html / .css 가 아닌 파일(.js 로직, .md 문서 등)
 *
 * ⚠️ 2026-08-25 추가 — Bash 경로:
 *   이 저장소 세션들은 파일을 Bash(heredoc·python)로 쓰는 일이 많아, matcher 가
 *   Write|Edit 뿐이면 **이 후크가 구조적으로 안 돈다.** 그래서 Bash 명령문에서
 *   dev/ 화면 파일(.html/.css)에 쓰기를 하려는지 본다.
 *   🔴 단 Bash 경로는 **멈추지 않는다(exit 0 + systemMessage).**
 *      명령문 판정은 오탐이 날 수 있는데, exit 2 로 막으면 애먼 Bash 명령이
 *      멈춘다 — 알림 하나 때문에 작업을 막는 것은 대가가 너무 크다.
 *   마커는 Write/Edit 경로와 **공유**한다(세션당 1회는 그대로).
 */

const fs = require('fs');
const os = require('os');
const path = require('path');

let payload;
try {
  payload = JSON.parse(fs.readFileSync(0, 'utf8'));
} catch {
  process.exit(0);
}

const toolName = payload.tool_name || '';
const isBash = toolName === 'Bash';
if (!isBash && toolName !== 'Write' && toolName !== 'Edit') process.exit(0);

let filePath = '';
if (isBash) {
  const cmd = (payload.tool_input && payload.tool_input.command) || '';
  if (!cmd) process.exit(0);
  const m = cmd.match(/(?:^|[\s"'`(=])\.?\/?dev\/[^\s"'`;|&)]*\.(?:html|css)\b/);
  if (!m) process.exit(0);
  // 읽기만 하는 명령(grep·cat·less)은 대상이 아니다 — 쓰기 신호가 있어야 한다.
  // ⚠️ 「명령 아무 데나 >」 가 아니라 「쓰기 대상이 그 화면 파일인가」를 본다
  //    (`grep foo dev/index.html > /tmp/out` 오탐을 막는다 — 리뷰 지적).
  const D = '(?:\\./)?dev/[^\\s"\'`;|&)]*\\.(?:html|css)';
  const writeSignal =
    [
      new RegExp('>>?\\s*["\']?' + D),
      new RegExp('\\b(?:sed\\s+-i|tee)\\b[^;&|]*' + D),
      new RegExp('\\b(?:cp|mv|rsync)\\b[^;&|]*\\s["\']?' + D),
    ].some((re) => re.test(cmd)) ||
    /writeFileSync\(|\.write\(|write_text\(|open\([^)]*["']w["']/.test(cmd);
  if (!writeSignal) process.exit(0);
  // 매치에 앞 구분자(따옴표 등)가 섞여 들어오면 표시가 깨진다 — 한 글자 정리
  filePath = m[0].trim().replace(/^[\s"'`(=]/, '');
} else {
  filePath = (payload.tool_input && payload.tool_input.file_path) || '';
  if (!filePath) process.exit(0);
  // dev/ 폴더 아래 화면 파일(.html/.css)만 대상
  const isDevFrontend = /\/dev\/.*\.(html|css)$/.test(filePath);
  if (!isDevFrontend) process.exit(0);
}

// 세션당 1회 마커 (session_id 없으면 날짜로 폴백)
const sessionId = payload.session_id || `date-${new Date().toISOString().slice(0, 10)}`;
const marker = path.join(os.tmpdir(), `reverb-frontend-skill-${sessionId}`);

if (fs.existsSync(marker)) process.exit(0);

// 마커 먼저 생성 → Claude 가 같은 편집을 재실행하면 통과
try {
  fs.writeFileSync(marker, String(Date.now()));
} catch {
  // 마커 못 쓰면 무한 차단 위험 → 그냥 통과
  process.exit(0);
}

const out = [
  '',
  '🎨 [프론트 화면 변경 감지 — 디자인 스킬 사용 안내] (이 세션 1회)',
  '',
  `대상 파일: ${filePath}`,
  '',
  '화면을 추가/수정하기 전에 디자인 스킬을 활용하세요:',
  '  • 새 화면을 처음 만드는 경우  → Skill("example-skills:frontend-design")',
  '  • 기존 화면을 고치거나 다듬는 경우 → Skill("ui-ux-pro-max")',
  '',
  '🔴 인플루언서 화면은 Apple 디자인 지침이 위 스킬보다 앞섭니다.',
  '   세부 기준·하드 제약은 .claude/rules/ui.md 「Apple 디자인 지침(HIG) 우선」 절,',
  '   모호하면 Skill("apple-design"). 관리자 화면은 이 제약 없음.',
  '',
  'REVERB 는 이미 스타일이 잡혀 있으니, 기존 화면 수정은 ui-ux-pro-max 의',
  'review/improve 관점을 우선하고 기존 컨벤션(모바일 480px·Material Icons·',
  'i18n·CSS 변수)을 깨지 마세요.',
  '',
  '※ 이 알림은 세션당 한 번만 뜹니다. 스킬을 호출했거나 단순 로직/문구 변경이라',
  '   불필요하면 같은 편집을 그대로 다시 실행하면 통과됩니다.',
  '',
];

// Bash 경로는 멈추지 않는다 — 명령문 판정은 오탐이 날 수 있다(머리말 참조)
if (isBash) {
  process.stdout.write(JSON.stringify({ systemMessage: out.join('\n').trim() }));
  process.exit(0);
}

process.stderr.write(out.join('\n'));
process.exit(2);
