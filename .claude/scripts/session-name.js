#!/usr/bin/env node
/**
 * 이 세션의 이름을 「일감이름 완료/전체」로 바꾼다.
 *
 * 세션 이름은 상태 표시줄과 `/현황` 양쪽에 그대로 뜨므로,
 * 여기에 일감과 진행률을 실으면 별도 장부를 만들 필요가 없다.
 * 이름을 바꾼 시각(nameSince)도 함께 기록돼, 표시가 낡았는지 드러난다.
 *
 * 쓰는 법: node .claude/scripts/session-name.js "회원탈퇴 화면 2/5"
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const name = process.argv.slice(2).join(' ').trim();
if (!name) {
  console.error('이름을 주세요. 예: node .claude/scripts/session-name.js "회원탈퇴 화면 2/5"');
  process.exit(1);
}

const SESS_DIR = path.join(process.env.HOME, '.claude', 'sessions');

// 「나」를 어떻게 찾나 — 이 스크립트를 실행한 셸의 조상 중에 세션 pid 가 있다.
// 그래서 조상 pid 를 거슬러 올라가며 세션 기록과 대조한다.
// (같은 폴더에 세션이 여럿일 수 있어, 폴더나 「가장 최근 활동」으로 추측하면 남의 이름을 바꾼다.)
function ancestors() {
  const out = [];
  let pid = process.pid;
  for (let i = 0; i < 12 && pid > 1; i++) {
    out.push(pid);
    try {
      pid = Number(execSync(`ps -o ppid= -p ${pid}`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim());
    } catch { break; }
    if (!pid || Number.isNaN(pid)) break;
  }
  return out;
}

const chain = ancestors();
let files;
try { files = fs.readdirSync(SESS_DIR).filter(f => f.endsWith('.json')); }
catch { console.error('세션 기록 폴더를 찾을 수 없습니다: ' + SESS_DIR); process.exit(2); }

let target = null;
for (const f of files) {
  const p = path.join(SESS_DIR, f);
  let d;
  try { d = JSON.parse(fs.readFileSync(p, 'utf8')); } catch { continue; }
  if (chain.includes(d.pid)) { target = { p, d }; break; }
}

if (!target) {
  console.error('이 세션의 기록을 찾지 못했습니다. 이름을 바꾸지 않았습니다.');
  console.error('(조상 프로세스: ' + chain.join(' → ') + ')');
  process.exit(2);
}

const before = target.d.name;
target.d.name = name;
target.d.nameSource = 'explicit';   // 자동 꼬리표로 되돌아가지 않게
target.d.nameSince = Date.now();
try {
  fs.writeFileSync(target.p, JSON.stringify(target.d));
} catch (e) {
  console.error('세션 기록을 저장하지 못했습니다: ' + e.message);
  process.exit(3);
}
console.log(`세션 이름: ${before}  →  ${name}`);
