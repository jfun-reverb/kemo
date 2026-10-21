#!/usr/bin/env node
// 마이그레이션·패치 병합 요청 자동 검사 (사양서 docs/specs/2026-10-20-migration-ledger.md 「설계 2·3」)
//
// 검사 다섯 — 결과는 차단(error) 또는 경고(warning):
//   ① 더한 마이그레이션 번호가 받는 브랜치에 다른 이름으로 있거나, 요청 안에 같은 번호가 둘 → 차단
//   ② 더한 파일이 정의하는 함수·제약·트리거·뷰를, 갈라진 뒤 받는 브랜치에 들어온 다른 마이그레이션도 정의 → 경고(dev 로 가는 요청만)
//   ③ 검사 시작 번호보다 큰 더한 마이그레이션이 설계 2 양식이 아님 → 차단
//   ④ 받는 브랜치에 이미 있는 마이그레이션 파일을 고침 → 경고
//   ⑤ 더한 패치가 설계 2 양식이 아님 → 경고(읽기·검증 패치면 사람이 넘긴다)
//
// 파일 글자만 본다 — 데이터베이스에 접속하지 않는다. 판정은 주석을 뺀 본문으로.
//
// 사용: node scripts/check-migrations.js --base dev --head <커밋>   (GitHub 실행 파일이 부른다)
//       node scripts/check-migrations.js --self-test                  (판정 함수 시험)

'use strict';
const { execFileSync } = require('child_process');

// 🔴 이 번호보다 큰 마이그레이션부터 설계 2 양식을 요구한다. 572(기록 표)는 baseline 줄이 있어 이 값은 572 이상이어야 한다.
//    값을 정하는 때: 이 스크립트를 처음 dev 에 병합하기 직전, dev 의 마지막 마이그레이션 번호로 맞춘다(사양서 「착수 전 알아야 할 것」 ①)
const CHECK_START_NUMBER = 572;

const MIG_DIR = 'supabase/migrations/';
const PATCH_DIR = 'supabase/patches/';

// ── SQL 글자 다루기 ───────────────────────────────────────────

// 주석을 빼고 세미콜론으로 문장을 나눈다(따옴표·$$ 묶음 안의 ; 와 -- 는 건드리지 않는다)
function splitStatements(sql) {
  const stmts = [];
  let cur = '';
  let i = 0;
  const n = sql.length;
  while (i < n) {
    const c = sql[i];
    const next = sql[i + 1];
    if (c === '-' && next === '-') {           // 줄 주석
      while (i < n && sql[i] !== '\n') i++;
      continue;
    }
    if (c === '/' && next === '*') {           // 덩어리 주석(중첩 허용)
      let depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (sql[i] === '/' && sql[i + 1] === '*') { depth++; i += 2; continue; }
        if (sql[i] === '*' && sql[i + 1] === '/') { depth--; i += 2; continue; }
        i++;
      }
      cur += ' ';
      continue;
    }
    if (c === "'" || c === '"') {              // 따옴표 문자열·이름 ('' 는 이어진 따옴표 · E'…' 는 \ 이스케이프도)
      const escaped = c === "'" && /[eE]/.test(sql[i - 1] || '') && !/[\w$]/.test(sql[i - 2] || '');
      let j = i + 1;
      while (j < n) {
        if (escaped && sql[j] === '\\') { j += 2; continue; }
        if (sql[j] === c) {
          if (sql[j + 1] === c) { j += 2; continue; }
          break;
        }
        j++;
      }
      cur += sql.slice(i, j + 1);
      i = j + 1;
      continue;
    }
    if (c === '$' && !/[\w$]/.test(sql[i - 1] || '')) {   // $태그$ … $태그$ 묶음(이름 중간의 $ 는 아님)
      const m = /^\$([A-Za-z_][A-Za-z0-9_]*)?\$/.exec(sql.slice(i));
      if (m) {
        const tag = m[0];
        const end = sql.indexOf(tag, i + tag.length);
        const stop = end === -1 ? n : end + tag.length;
        cur += sql.slice(i, stop);
        i = stop;
        continue;
      }
    }
    if (c === ';') {
      if (cur.trim()) stmts.push(cur.trim());
      cur = '';
      i++;
      continue;
    }
    cur += c;
    i++;
  }
  if (cur.trim()) stmts.push(cur.trim());
  return stmts;
}

const isWord = (stmt, re) => re.test(stmt.replace(/\s+/g, ' ').trim());
const isBegin = s => isWord(s, /^(BEGIN|START TRANSACTION)( (WORK|TRANSACTION))?$/i);
const isCommit = s => isWord(s, /^(COMMIT|END)( (WORK|TRANSACTION))?$/i);
const isLedgerInsert = s => /^INSERT\s+INTO\s+(public\.)?migration_ledger\b/i.test(s);
const sqlStr = v => "'" + String(v).replace(/'/g, "''") + "'";

// 설계 2 판정 — 문제 목록을 돌려준다(빈 배열 = 양식 맞음)
//   ⓐ BEGIN; 으로 시작 ⓑ COMMIT; 으로 끝 ⓒ 사이에 BEGIN;·COMMIT; 없음
//   ⓓ COMMIT; 바로 앞이 자기 종류·열쇠·파일 이름의 기록 줄 · 본문 어디에도 baseline 줄 없음
function checkFormat(sql, { kind, key, fileName }) {
  const problems = [];
  const st = splitStatements(sql);
  if (st.length < 3) return ['본문이 BEGIN; · 기록 줄 · COMMIT; 셋보다 짧다'];
  if (!isBegin(st[0])) problems.push('주석을 뺀 본문이 BEGIN; 으로 시작하지 않는다');
  if (!isCommit(st[st.length - 1])) problems.push('주석을 뺀 본문이 COMMIT; 으로 끝나지 않는다');
  const inner = st.slice(1, -1);
  if (inner.some(s => isBegin(s) || isCommit(s))) problems.push('BEGIN; 과 COMMIT; 사이에 다른 BEGIN;·COMMIT; 이 있다(묶음이 둘 이상)');
  if (st.some(s => isLedgerInsert(s) && /'baseline'/i.test(s))) problems.push('baseline 기록 줄이 있다(기준선은 572 하나뿐)');
  const last = st[st.length - 2];
  const ok = isLedgerInsert(last)
    && last.includes(sqlStr(kind)) && last.includes(sqlStr(key)) && last.includes(sqlStr(fileName));
  if (!ok) problems.push(`COMMIT; 바로 앞 문장이 자기 기록 줄이 아니다 — 기대: INSERT INTO public.migration_ledger (kind, key, file_name) VALUES (${sqlStr(kind)}, ${sqlStr(key)}, ${sqlStr(fileName)});`);
  return problems;
}

// 파일이 「정의」하는 대상 이름(함수·트리거·뷰·제약) — 권한·주석만 손댄 파일은 빈 목록
function definedObjects(sql) {
  const out = new Set();
  const norm = name => name.replace(/"/g, '').replace(/^public\./i, '').toLowerCase();
  for (const s of splitStatements(sql)) {
    const one = s.replace(/\s+/g, ' ');
    let m;
    if ((m = /^CREATE (?:OR REPLACE )?FUNCTION ([\w."]+)\s*\(/i.exec(one))) out.add('함수 ' + norm(m[1]));
    else if ((m = /^CREATE (?:OR REPLACE )?(?:CONSTRAINT )?TRIGGER ([\w"]+) .*? ON ([\w."]+)/i.exec(one))) out.add(`트리거 ${norm(m[1])} (${norm(m[2])})`);
    else if ((m = /^CREATE (?:OR REPLACE )?(?:MATERIALIZED )?VIEW ([\w."]+)/i.exec(one))) out.add('뷰 ' + norm(m[1]));
    const re = /ADD CONSTRAINT ([\w"]+)/ig;
    while ((m = re.exec(one))) out.add('제약 ' + norm(m[1]));
  }
  return out;
}

const migNumber = path => {
  const m = /^supabase\/migrations\/(\d{3})_[^/]+\.sql$/.exec(path);
  return m ? m[1] : null;
};
const baseName = path => path.split('/').pop();

// ── git ───────────────────────────────────────────────────────

const git = (...args) => execFileSync('git', ['-c', 'core.quotepath=false', ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).trim();
const lines = s => (s ? s.split('\n').filter(Boolean) : []);
const show = (ref, path) => git('show', `${ref}:${path}`);

function diffStatus(from, to) {
  return lines(git('diff', '--name-status', '--no-renames', from, to, '--', MIG_DIR, PATCH_DIR))
    .map(l => { const [st, path] = l.split('\t'); return { st, path }; });
}

// ── 본 검사 ───────────────────────────────────────────────────

function run({ base, head }) {
  const baseRef = `origin/${base}`;
  const mergeBase = git('merge-base', baseRef, head);
  const changes = diffStatus(mergeBase, head);
  const added = changes.filter(c => c.st === 'A');
  const modified = changes.filter(c => c.st === 'M');
  const baseMigs = lines(git('ls-tree', '--name-only', baseRef, MIG_DIR)).map(p => p.startsWith(MIG_DIR) ? p : MIG_DIR + p);
  const errors = [];
  const warnings = [];

  const addedMigs = added.filter(c => migNumber(c.path));
  const addedPatches = added.filter(c => c.path.startsWith(PATCH_DIR) && c.path.endsWith('.sql'));

  // ①
  const seen = new Map();
  for (const { path } of addedMigs) {
    const num = migNumber(path);
    const clash = baseMigs.find(p => migNumber(p) === num && p !== path);
    if (clash) errors.push({ path, msg: `① 번호 ${num} 이 받는 브랜치에 이미 있다(${baseName(clash)}). 병합 전에 내 쪽 이름을 다음 번호로 바꾼다 — 이미 어느 서버에서 돌렸으면 사양서 결정 10(.claude/rules/supabase.md 「이름을 바꾸기 전 판」)` });
    if (seen.has(num)) errors.push({ path, msg: `① 이 요청 안에 번호 ${num} 이 둘이다(${baseName(seen.get(num))})` });
    seen.set(num, path);
  }

  // ②
  if (base === 'dev') {
    const arrived = lines(git('diff', '--name-only', '--diff-filter=A', '--no-renames', mergeBase, baseRef, '--', MIG_DIR)).filter(migNumber);
    const theirs = arrived.map(p => ({ p, objs: definedObjects(show(baseRef, p)) }));
    for (const { path } of addedMigs) {
      const mine = definedObjects(show(head, path));
      for (const { p, objs } of theirs) {
        const both = [...mine].filter(o => objs.has(o));
        if (both.length) warnings.push({ path, msg: `② 갈라진 뒤 dev 에 들어온 ${baseName(p)} 도 같은 대상을 정의한다: ${both.join(', ')} — 그 파일의 정의를 베이스로 다시 쓰고, 실행 전에 각 서버에서 대상을 조회하고, 상대에게 알린다(.claude/rules/supabase.md 「재정의 경고」)` });
      }
    }
  }

  // ③
  for (const { path } of addedMigs) {
    const num = migNumber(path);
    if (Number(num) <= CHECK_START_NUMBER) continue;
    const problems = checkFormat(show(head, path), { kind: 'migration', key: num, fileName: baseName(path) });
    for (const pr of problems) errors.push({ path, msg: `③ 양식: ${pr} (.claude/rules/supabase.md 「새 파일 양식」)` });
  }

  // ④
  for (const { path } of modified) {
    if (!migNumber(path)) continue;
    warnings.push({ path, msg: '④ 이미 받는 브랜치에 있는 마이그레이션을 고쳤다 — 고치지 말고 새 번호로 낸다(예외: 「끼어든 파일 양식 맞추기」 — 병합 요청 본문에 적는다)' });
  }

  // ⑤
  for (const { path } of addedPatches) {
    const name = baseName(path);
    const problems = checkFormat(show(head, path), { kind: 'patch', key: name, fileName: name });
    for (const pr of problems) warnings.push({ path, msg: `⑤ 패치 양식: ${pr} — 데이터·구조를 바꾸는 패치면 양식을 맞추고, 읽기·검증 패치면 넘긴다` });
  }

  return { errors, warnings, counts: { added: added.length, modified: modified.length } };
}

function report({ errors, warnings, counts }) {
  const esc = s => s.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
  for (const w of warnings) console.log(`::warning file=${w.path}::${esc(w.msg)}`);
  for (const e of errors) console.log(`::error file=${e.path}::${esc(e.msg)}`);
  console.log(`\n검사 끝 — 더한 파일 ${counts.added} · 고친 마이그레이션 ${counts.modified} · 차단 ${errors.length} · 경고 ${warnings.length} (검사 시작 번호 ${CHECK_START_NUMBER})`);
  const summary = process.env.GITHUB_STEP_SUMMARY;
  if (summary) {
    const row = (t, x) => `| ${t} | \`${x.path}\` | ${x.msg.replace(/\|/g, '\\|')} |`;
    const body = ['## 마이그레이션 검사', '', `차단 ${errors.length} · 경고 ${warnings.length} (검사 시작 번호 ${CHECK_START_NUMBER})`, ''];
    if (errors.length || warnings.length) {
      body.push('| 결과 | 파일 | 내용 |', '|---|---|---|', ...errors.map(e => row('차단', e)), ...warnings.map(w => row('경고', w)));
    }
    require('fs').appendFileSync(summary, body.join('\n') + '\n');
  }
  return errors.length ? 1 : 0;
}

// ── 판정 함수 시험 ─────────────────────────────────────────────

function selfTest() {
  const f = { kind: 'migration', key: '600', fileName: '600_x.sql' };
  const rec = "INSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('migration', '600', '600_x.sql');";
  const cases = [
    ['갖춘 파일', `-- 머리\nBEGIN;\nCREATE TABLE t(a int);\n${rec}\nCOMMIT;\n`, 0],
    ['함수 본문 안 BEGIN·;', `BEGIN;\nCREATE FUNCTION f() RETURNS void LANGUAGE plpgsql AS $$\nBEGIN\n  PERFORM 1; -- x;\nEND;\n$$;\n${rec}\nCOMMIT;`, 0],
    ['양식 없음', 'CREATE TABLE t(a int);', 1],
    ['BEGIN 이 주석 안에만', `-- BEGIN;\nCREATE TABLE t(a int);\n${rec}\nCOMMIT;`, 1],
    ['묶음 둘', `BEGIN;\nCREATE TABLE t(a int);\nCOMMIT;\nBEGIN;\n${rec}\nCOMMIT;`, 1],
    ['COMMIT 뒤 문장', `BEGIN;\nCREATE TABLE t(a int);\n${rec}\nCOMMIT;\nSELECT 1;`, 2],
    ['기록 줄 없음', 'BEGIN;\nCREATE TABLE t(a int);\nCOMMIT;', 1],
    ['남의 번호 기록', `BEGIN;\nCREATE TABLE t(a int);\n${rec.replace(/600/g, '601')}\nCOMMIT;`, 1],
    ['baseline 줄', `BEGIN;\nINSERT INTO public.migration_ledger (kind, key, file_name) VALUES ('baseline','baseline','600_x.sql');\n${rec}\nCOMMIT;`, 1],
    ['E 문자열 안 \\\' ;', `BEGIN;\nSELECT E'it\\'s; x';\n${rec}\nCOMMIT;`, 0],
    ['중첩 주석', `BEGIN;\n/* a /* b; */ c; */\n${rec}\nCOMMIT;`, 0],
    ['따옴표 안 ;', `BEGIN;\nCOMMENT ON TABLE t IS 'a; COMMIT; b';\n${rec}\nCOMMIT;`, 0],
  ];
  let fail = 0;
  for (const [name, sql, want] of cases) {
    const got = checkFormat(sql, f).length;
    const pass = want === 0 ? got === 0 : got > 0;
    if (!pass) fail++;
    console.log(`${pass ? 'ok  ' : 'FAIL'} ${name} — 문제 ${got}`);
  }
  const objs = definedObjects("CREATE OR REPLACE FUNCTION public.f(a int) RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql; GRANT EXECUTE ON FUNCTION public.f(int) TO anon; ALTER TABLE x ADD CONSTRAINT x_chk CHECK (a>0); CREATE TRIGGER trg_a BEFORE UPDATE ON public.t FOR EACH ROW EXECUTE FUNCTION g();");
  const wantObjs = ['함수 f', '제약 x_chk', '트리거 trg_a (t)'];
  const objOk = wantObjs.every(o => objs.has(o)) && objs.size === 3;
  if (!objOk) fail++;
  console.log(`${objOk ? 'ok  ' : 'FAIL'} 정의 대상 추출 — ${[...objs].join(', ')}`);
  const grantOnly = definedObjects('GRANT EXECUTE ON FUNCTION public.f(int) TO anon; REVOKE ALL ON FUNCTION public.f(int) FROM PUBLIC;');
  if (grantOnly.size) fail++;
  console.log(`${grantOnly.size ? 'FAIL' : 'ok  '} 권한만 바꾼 파일은 대상 없음`);
  return fail ? 1 : 0;
}

// ── 시작 ──────────────────────────────────────────────────────

function arg(name) {
  const i = process.argv.indexOf(name);
  return i === -1 ? null : process.argv[i + 1];
}

if (require.main === module) {
  if (process.argv.includes('--self-test')) process.exit(selfTest());
  const base = arg('--base');
  const head = arg('--head') || 'HEAD';
  if (!base) { console.error('--base <받는 브랜치> 가 필요하다'); process.exit(2); }
  process.exit(report(run({ base, head })));
}

module.exports = { splitStatements, checkFormat, definedObjects };
