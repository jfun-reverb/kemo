#!/usr/bin/env node
/**
 * 세션 현황 표 — 지금 어느 세션이 어느 폴더에서 무슨 일감을 하고 있나.
 *
 * 정보 출처는 두 갈래이고, 신뢰도가 다르다:
 *   ① 자동 칸(폴더·상태·마지막 활동·생존 여부) — Claude Code 가 스스로 기록한다. 낡지 않는다.
 *   ② 사람이 쓰는 칸(일감 이름·진행률) — 세션 이름에 실린다. 안 바꾸면 낡는다.
 *      그래서 이름을 붙인 시각을 함께 보여줘, 낡은 이름이 낡아 보이게 한다.
 *
 * 쓰는 법: node .claude/scripts/session-status.js [--all]
 *   기본은 reverb-jp 관련 폴더만. --all 은 다른 프로젝트 세션까지.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const SESS_DIR = path.join(process.env.HOME, '.claude', 'sessions');
const showAll = process.argv.includes('--all');

// 프로세스가 실제로 살아 있나 — 목록에만 남은 유령 세션을 걸러낸다.
// ⚠ pid 만 보면 안 된다. 죽은 세션의 pid 를 다른 프로그램이 물려받으면 살아난 척한다.
//    그래서 그 pid 가 정말 claude/node 프로세스인지까지 확인한다.
function alive(pid) {
  // pid 는 남이 쓴 JSON 에서 온 값이라, 숫자인지부터 확인하고 셸에 넘긴다
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); } catch { return false; }
  try {
    const comm = execSync(`ps -p ${pid} -o comm=`, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return /claude|node/i.test(comm);
  } catch { return false; }
}

function branchOf(cwd) {
  try {
    return execSync('git branch --show-current', { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || '(분리됨)';
  } catch { return '-'; }
}

function dirtyOf(cwd) {
  try {
    const out = execSync('git status --porcelain', { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    return out ? out.split('\n').length : 0;
  } catch { return 0; }
}

function ago(ms) {
  if (!ms) return '?';
  const m = Math.floor((Date.now() - ms) / 60000);
  if (m < 1) return '방금';
  if (m < 60) return `${m}분 전`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}시간 전`;
  return `${Math.floor(h / 24)}일 전`;
}

const STATUS_KO = {
  busy: '작업 중',
  waiting: '내 답 기다림',
  idle: '대기',
};

let files = [];
try { files = fs.readdirSync(SESS_DIR).filter(f => f.endsWith('.json')); }
catch { console.log('세션 기록 폴더를 찾을 수 없습니다: ' + SESS_DIR); process.exit(0); }

const rows = [];
for (const f of files) {
  let d;
  try { d = JSON.parse(fs.readFileSync(path.join(SESS_DIR, f), 'utf8')); } catch { continue; }
  if (!d.pid || !d.cwd) continue;
  if (!showAll && !/reverb-jp/.test(d.cwd)) continue;
  if (!alive(d.pid)) continue;   // 죽은 세션은 아예 안 보여준다 (있는 척이 제일 나쁘다)
  rows.push({
    name: d.name || '(이름없음)',
    nameSource: d.nameSource,
    nameSince: d.nameSince,
    kind: d.kind === 'bg' ? '배경' : '대화',
    status: STATUS_KO[d.status] || d.status || '?',
    updatedAt: d.updatedAt,
    cwd: d.cwd,
    folder: path.basename(d.cwd),
    pid: d.pid,
  });
}

if (!rows.length) {
  console.log('지금 살아 있는 세션이 없습니다.');
  process.exit(0);
}

rows.sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));

// 6시간 넘게 아무 활동이 없으면 「방치」로 본다.
// 터미널만 열어둔 세션까지 「지금 도는 중」에 섞으면 목록이 거짓말이 되고,
// 같은 폴더 경고도 과장돼 아무도 안 믿게 된다.
const IDLE_MS = 6 * 60 * 60 * 1000;
const live = rows.filter(r => Date.now() - (r.updatedAt || 0) < IDLE_MS);
const stale = rows.filter(r => Date.now() - (r.updatedAt || 0) >= IDLE_MS);

console.log('');
console.log('■ 지금 도는 세션');
console.log('');
for (const r of live) {
  const br = branchOf(r.cwd);
  const dirty = dirtyOf(r.cwd);
  const derived = r.nameSource === 'derived';
  const nameShow = derived ? `${r.name}  ← 일감 이름 안 붙음` : r.name;
  console.log(`● ${nameShow}`);
  console.log(`   상태   ${r.status}  (마지막 활동 ${ago(r.updatedAt)})`);
  console.log(`   폴더   ${r.folder}   가지 ${br}${dirty ? `   ⚠ 커밋 안 된 파일 ${dirty}개` : ''}`);
  if (!derived && r.nameSince) console.log(`   일감표시 갱신  ${ago(r.nameSince)}`);
  console.log('');
}

if (stale.length) {
  console.log('■ 열려만 있는 세션 (6시간 넘게 조용함 — 터미널만 떠 있는 상태)');
  for (const r of stale) console.log(`   · ${r.name}   ${r.folder}   마지막 활동 ${ago(r.updatedAt)}`);
  console.log('');
}

// 같은 폴더를 두 세션 이상이 「실제로 움직이며」 쓰고 있으면 경고 — 조용히 갈리는 사고의 원인
const byFolder = {};
for (const r of live) (byFolder[r.cwd] = byFolder[r.cwd] || []).push(r);
for (const [cwd, list] of Object.entries(byFolder)) {
  if (list.length < 2) continue;
  const dirty = dirtyOf(cwd);
  console.log(`🔴 ${path.basename(cwd)} 폴더를 세션 ${list.length}개가 함께 쓰고 있습니다: ${list.map(r => r.name).join(', ')}`);
  console.log('   한쪽이 가지를 바꾸거나 되돌리면 다른 쪽 작업이 경고 없이 사라집니다.');
  if (dirty) console.log(`   지금 그 폴더에 커밋 안 된 파일이 ${dirty}개 있습니다.`);
  console.log('');
}
