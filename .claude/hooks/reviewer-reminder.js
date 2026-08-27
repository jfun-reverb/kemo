#!/usr/bin/env node
/**
 * UserPromptSubmit hook — reviewer/supabase-expert 호출 리마인더.
 *
 * 트리거 키워드가 프롬프트에 포함되면 메인 Claude에게 체크리스트 주입:
 *  - commit / push / merge / 배포 / deploy / 머지 / 커밋 / 푸시
 * (단순 질문 "X 어떻게 해?" 는 매칭 안 되도록 경계)
 *
 * 출력: stdout JSON { hookSpecificOutput: { additionalContext: "..." } }
 *       → Claude 시스템 컨텍스트에 주입
 * exit 0 유지 (블로킹 아님)
 */

const input = require('fs').readFileSync(0, 'utf8');
let payload;
try { payload = JSON.parse(input); } catch { process.exit(0); }

// 다른 세션이 보낸 메시지는 사용자가 친 말이 아니다 — 그 본문에 「커밋」·「개발 세션」 같은
//   낱말이 들어 있어도 이 알림을 띄우지 않는다. 띄우면 하루에 열 번 넘게 뜨고,
//   그러면 **정작 진짜로 걸릴 때 안 읽힌다**(2026-08-27 세 세션 중 둘이 지적).
//   판정 근거: UserPromptSubmit payload 실측 — 세션 간 메시지는 prompt 가
//   `<cross-session-message` 로 시작한다.
if (String(payload.prompt || '').trimStart().startsWith('<cross-session-message')) process.exit(0);

const prompt = (payload.prompt || '').toLowerCase();

// 트리거 키워드 (한/영)
const triggers = [
  'commit', 'push', 'merge', 'deploy',
  '커밋', '푸시', '머지', '배포', '머지해', '푸시해', '커밋해', '배포해'
];

const hit = triggers.find(kw => prompt.includes(kw));
if (!hit) process.exit(0);

// 리마인더 컨텍스트 주입
const reminder = [
  '',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  '🔔 [배포/머지 가드]',
  `사용자 프롬프트에 "${hit}" 키워드 감지됨. 아래 체크리스트를 반드시 거치세요.`,
  '',
  '□ reverb-reviewer 호출했는가? (예외 없음 — 단순 한 줄 오탈자 수정 제외)',
  '□ Supabase/Auth/RLS/마이그레이션 변경 있으면 → reverb-supabase-expert 호출했는가?',
  '□ dev 푸시 후 운영 배포 여부를 AskUserQuestion으로 확인했는가?',
  '□ dev/ 소스 변경 후 build.sh 실행 → 루트 index.html·admin/index.html 재빌드됐는가?',
  '□ 한국어 오탈자(캐페인·캐웩인·행버거·컨텐츠·메세지 등) 자체 점검했는가?',
  '',
  '미수행 항목 있으면 지금 수행. "작은 변경이니까" 핑계 금지.',
  '규칙 근거: .claude/rules/interaction.md, .claude/rules/git.md',
  '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━',
  ''
].join('\n');

const out = {
  hookSpecificOutput: {
    hookEventName: 'UserPromptSubmit',
    additionalContext: reminder
  }
};
process.stdout.write(JSON.stringify(out));
process.exit(0);
