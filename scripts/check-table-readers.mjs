#!/usr/bin/env node
// ──────────────────────────────────────────────────────────────────
// check-table-readers.mjs
// 「조용히 죽는 관리자 화면」 감지 장치 — 2겹(코드 점검)
// 사양서: docs/specs/2026-08-18-blocked-admin-screen-detection.md §3-4
// 작업표: docs/specs/2026-08-18-blocked-admin-screen-detection-breakdown.md 작업 2
//
// ▶ 무엇을 하나
//   표 이름을 받아, 그 표를 **관리자 화면 코드가 아직 직접 읽는 자리**를 찾는다.
//   접근 허가를 좁히는 변경(행 단위 보안 정책 축소)은 막히면 오류가 아니라
//   **빈 결과**가 돌아와 오류 로그에도 안 남는다 — 그래서 정적 점검이 유일한 방어선이다.
//
// ▶ 실행 방식 2가지
//   ㉮ 적용 전 : node scripts/check-table-readers.mjs --sql supabase/migrations/312_*.sql
//               적용하려는 SQL 이 좁히는 표를 뽑아 미리 검사한다. **이게 주 용도다**
//               — 사고를 그 자리에서 막는 경로다.
//   ㉯ 적용 후 : node scripts/check-table-readers.mjs --tables influencers [--record]
//               감지 함수가 알려준 표를 검사하고, --record 면 결과를 데이터베이스에 남긴다.
//
// ▶ ⚠️ 아직 자동 실행되지 않는다
//   커밋 가드 훅 연결은 작업 4다(사양서 §5 ⑦). 그때까지는 **사람이 손으로 돌린다.**
//   훅이 붙기 전에는 이 스크립트가 있어도 아무도 안 돌릴 수 있다는 뜻이다.
// ──────────────────────────────────────────────────────────────────

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative, extname } from 'node:path';

const REPO = new URL('..', import.meta.url).pathname.replace(/\/$/, '');
const DEV_DIR = join(REPO, 'dev');
const BUILD_SH = join(DEV_DIR, 'build.sh');

// 훑지 않을 확장자(그림·글꼴 등). ⚠️ **확장자 화이트리스트를 쓰지 않는다** —
// 새 종류의 파일이 생겨도 기본이 「검사 대상」이어야 한다(사양서 §3-4 블랙리스트 원칙).
const BINARY_EXT = new Set([
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.woff', '.woff2',
  '.ttf', '.otf', '.eot', '.pdf', '.zip', '.mp4', '.mov', '.webm', '.heic',
]);

// 쓰기로 보는 호출 — 읽기만 세므로 이건 제외한다.
const WRITE_CALLS = /\.(insert|update|upsert|delete)\s*\(/;

// ──────────────────────────────────────────────────────────────────
// 1. 인플루언서 전용 파일 목록 = CLIENT_JS_FILES − ADMIN_JS_FILES (차집합)
//
// ★ 반드시 차집합이어야 한다. 「CLIENT_JS_FILES 에 있으면 제외」로 짜면
//   두 목록에 모두 있는 lib/storage.js 가 통째로 검사에서 빠진다 —
//   거기 관리자용 조회가 생겨도 **영원히 안 잡힌다**(「문제인데 안 뜨는」 방향).
//   하필 2026-08-07 사고로 죽은 자리 중 하나가 그 파일에 있었다.
// ──────────────────────────────────────────────────────────────────
function influencerOnlyFiles() {
  const sh = readFileSync(BUILD_SH, 'utf8');
  const listOf = (name) => {
    const m = sh.match(new RegExp(`^${name}=\\(([^)]*)\\)`, 'm'));
    if (!m) throw new Error(`build.sh 에서 ${name} 을 못 찾았다 — 목록 이름이 바뀌었는지 확인할 것`);
    return new Set([...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]));
  };
  const client = listOf('CLIENT_JS_FILES');
  const admin = listOf('ADMIN_JS_FILES');
  return new Set([...client].filter((f) => !admin.has(f))); // ← 차집합
}

// ──────────────────────────────────────────────────────────────────
// 2. dev/ 아래 파일을 전부 훑는다
//    ⚠️ 파일 이름을 목록으로 적지 않는다 — 새 파일이 생기면 안 걸린다
//       (사양서가 방향 C 를 탈락시킨 바로 그 결함).
//       dev/event-scan.html 같은 자립형 화면이 이 규칙 덕에 잡힌다.
// ──────────────────────────────────────────────────────────────────
function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (!BINARY_EXT.has(extname(name).toLowerCase())) out.push(p);
  }
  return out;
}

// ──────────────────────────────────────────────────────────────────
// 3. 세 형태를 각각 따로 찾는다 (사양서 §3-4)
//
// ⚠️ 부분 문자열 경계를 반드시 본다 — `influencers` 는 `influencers_admin_view`
//    안에 들어 있다. 경계를 안 보면 **이미 가림막 통로로 옮긴 자리까지**
//    「아직 읽는 자리」로 센다(dev/ 전체에 `influencers` 문자열이 85곳).
// ──────────────────────────────────────────────────────────────────
const BOUNDARY = '(?![A-Za-z0-9_])'; // 뒤에 식별자 글자가 오면 다른 이름이다
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// ──────────────────────────────────────────────────────────────────
// ② 를 위한 사전 작업 — 「표 이름을 변수로 받는 헬퍼」를 먼저 찾는다
//
// ⚠️ 표 이름이 든 문자열을 전부 세면 안 된다. `refreshPane('influencers')`·
//    `subToParent = {'influencer-detail':'influencers'}` 처럼 **화면 이름·객체
//    열쇠말**이 같은 낱말을 쓰기 때문이다(실측 18곳 중 13곳이 이런 오탐이었다).
//    규칙(.claude/rules/request-validation.md 「이름 전파 점검」)이 정한 방법 그대로
//    **`.from(변수)` 를 하는 헬퍼를 먼저 찾고, 그 헬퍼의 호출부만** 본다.
// ──────────────────────────────────────────────────────────────────
function findTableNameHelpers(files) {
  const helpers = new Set();
  for (const file of files) {
    let text;
    try { text = readFileSync(file, 'utf8'); } catch { continue; }
    // `.from(변수)` — 따옴표가 아닌 식별자를 넘기는 자리
    for (const m of text.matchAll(/\.from\(\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*\)/g)) {
      // 그 자리를 감싼 함수 이름을 뒤로 훑어 찾는다
      const before = text.slice(0, m.index);
      const decl = [...before.matchAll(
        /(?:async\s+)?function\s+([A-Za-z_$][\w$]*)\s*\(|(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:async\s*)?\(/g
      )].pop();
      if (decl) helpers.add(decl[1] || decl[2]);
    }
  }
  return helpers;
}

// ③ 을 위한 사전 작업 — 조회문(`.select(...)`)의 문자열 인자만 뽑는다
//
// ⚠️ 문서 전체에서 `표이름:` 을 찾으면 안 된다. 자바스크립트 객체 열쇠말
//    (`influencers: infMap[...]`)이 똑같이 생겼다(실측 오탐 다수).
//    임베드 조인은 **반드시 조회문 문자열 안**에 있다.
function selectStringSpans(text) {
  const spans = [];
  for (const m of text.matchAll(/\.select\(\s*(['"`])([\s\S]*?)\1/g)) {
    spans.push({ start: m.index + m[0].indexOf(m[2]), body: m[2] });
  }
  return spans;
}

function patternsFor(table) {
  const t = esc(table);
  return {
    // ① 그대로 적힌 것 — db.from('표')
    direct: new RegExp(`\\.from\\(\\s*['"\`]${t}['"\`]`, 'g'),

    // ③ 임베드 조인 — 조회문 문자열 안에서 세 갈래.
    //
    // ★ 별명이 아니라 **대상**을 봐야 한다. `별명:대상 (칸)` 에서 실제로 읽히는 것은
    //   대상이다. 이 구분을 안 하면 **이미 가림막 통로로 옮긴 자리를 「아직 원본을
    //   읽는 자리」로 잘못 센다** — `influencers:influencers_admin_view (…)` 가
    //   정확히 그 모양이고, 2026-08-18 에 실제로 그렇게 오탐이 났다.
    //
    //   ㄱ. `:표 (`        → 대상이 우리 표 (예: `inf:influencers (…)`)
    //   ㄴ. `표:열_id (`   → 대상이 외래 키 열이라 **별명이 표 이름**으로 붙는다
    //                        (예: `influencers:influencer_id (…)` — 2026-08-07 사고 형태).
    //                        ⚠️ 대상이 `_id` 로 끝나지 않으면 **다른 관계를 가리키는
    //                        것**이므로 세지 않는다(위 오탐이 이 경우다).
    //                        ⚠️ **왼쪽 경계도 잠근다** — 안 잠그면 표 이름이 더 긴 이름의
    //                        꼬리로 들어간 것까지 센다. 이 저장소에 실제로
    //                        `outbound_influencers`(→`influencers` 검사 시)·
    //                        `brand_applications`(→`applications` 검사 시)가 있다.
    //   ㄷ. `, 표 (`       → 별명 없이 대상만 적은 형태
    embed: new RegExp(
      `:\\s*${t}${BOUNDARY}\\s*\\(`
      + `|(?<![A-Za-z0-9_])${t}${BOUNDARY}\\s*:\\s*[A-Za-z0-9_]*_id${BOUNDARY}\\s*\\(`
      + `|(?:^|[,\\s])${t}${BOUNDARY}\\s*\\(`,
      'g'
    ),
  };
}

// 주석을 공백으로 덮는다(길이 보존 — 줄 번호가 안 틀어지게).
// ⚠️ 안 덮으면 **주석에 적힌 예시 코드가 「읽는 자리」로 잡힌다.** 이 저장소는
//    사고 경위를 주석으로 길게 남기는 관행이 있어(오늘 것도 그렇다) 실제로 걸렸다.
function stripComments(text) {
  const blank = (m) => m.replace(/[^\n]/g, ' ');
  return text
    .replace(/\/\*[\s\S]*?\*\//g, blank)      // /* … */
    .replace(/<!--[\s\S]*?-->/g, blank)        // <!-- … -->
    .replace(/(^|[^:'"`\\])\/\/[^\n]*/g, (m, p1) => p1 + blank(m.slice(p1.length))); // // …  (https:// 제외)
}

// 매치 지점부터 「한 문장」의 범위를 잡는다.
// ⚠️ 같은 줄만 보면 안 된다 — storage.js 의 본인 행 수정은
//    db.from('influencers') 다음 줄에 .update(...) 가 온다.
function statementWindow(text, idx) {
  const end = text.indexOf(';', idx);
  const limit = idx + 400; // 세미콜론이 멀거나 없을 때의 상한
  return text.slice(idx, end === -1 ? limit : Math.min(end, limit));
}

function lineOf(text, idx) {
  return text.slice(0, idx).split('\n').length;
}

function scanTable(table, files, excluded, helpers) {
  const hits = [];
  const skipped = { influencerOnly: 0, write: 0 };
  const { direct, embed } = patternsFor(table);

  // ② 호출부 패턴 — 「.from(변수)」 를 하는 헬퍼에 표 이름을 넘기는 자리만.
  //    헬퍼가 하나도 없으면 이 형태는 검사하지 않는다(빈 정규식으로 오탐 내지 않게).
  const helperCall = helpers.size
    ? new RegExp(`\\b(?:${[...helpers].map(esc).join('|')})\\s*\\(\\s*['"\`]${esc(table)}['"\`]`, 'g')
    : null;

  for (const file of files) {
    const rel = relative(DEV_DIR, file);
    if (excluded.has(rel)) { skipped.influencerOnly++; continue; }

    let text;
    try { text = readFileSync(file, 'utf8'); } catch { continue; }
    if (!text.includes(table)) continue;
    text = stripComments(text);   // ⚠️ 주석 속 예시 코드를 「읽는 자리」로 세지 않게

    const seen = new Set();
    const add = (idx, form) => {
      const line = lineOf(text, idx);
      const key = `${rel}:${line}:${form}`;
      if (seen.has(key)) return;
      if (WRITE_CALLS.test(statementWindow(text, idx))) { skipped.write++; return; }
      seen.add(key);
      hits.push({ file: relative(REPO, file), line, form });
    };

    for (const m of text.matchAll(direct)) add(m.index, '①직접');
    if (helperCall) for (const m of text.matchAll(helperCall)) add(m.index, '②인자');

    // ③ 은 조회문 문자열 안에서만 찾는다 — 객체 열쇠말과 생김새가 같기 때문이다.
    for (const span of selectStringSpans(text)) {
      embed.lastIndex = 0;
      let e;
      while ((e = embed.exec(span.body)) !== null) add(span.start + e.index, '③임베드');
    }
  }
  return { hits, skipped };
}

// ──────────────────────────────────────────────────────────────────
// 4. ㉮ 모드 — 적용할 SQL 이 「좁히는」 표 이름을 뽑는다
//    조회를 좁히는 신호 = 조회 정책을 지우거나 바꾸는 것.
// ──────────────────────────────────────────────────────────────────
function tablesNarrowedBy(sqlPath) {
  let raw;
  try {
    raw = readFileSync(sqlPath, 'utf8');
  } catch (e) {
    // ⚠️ 파일이 없으면 **조용히 넘어간다.** 훅에서 도는 도구라 여기서 오류 스택을
    //    쏟으면 사람이 「뭔가 망가졌다」로 읽는다. 파일을 지우거나 이름을 바꾼 커밋,
    //    작업 폴더 경로가 다른 경우에 실제로 생긴다.
    return null;   // ⚠️ [] 아님 — 「파일 없음」과 「좁히는 게 없음」은 다른 상태다
  }

  // ★ 주석을 **둘 다** 지운다. 이 저장소는 파일 하단에 **롤백 SQL 을 `/* */` 안에**
  //   적어두는 관행이 있어(084·137·240·325), 안 지우면 **실행되지 않는 구문이
  //   「다시 만듦」으로 읽힌다.** 084 는 익명 사용자의 신청서 등록 권한을 영구히
  //   없앤 보안 마이그레이션인데, 주석 속 롤백 문구 때문에 통째로 사라졌었다.
  const sql = raw
    .replace(/\/\*[\s\S]*?\*\//g, '')   // 여러 줄 주석
    .replace(/^\s*--.*$/gm, '');          // 한 줄 주석

  // 이 파일에서 **새로 만드는** 표는 검사 대상이 아니다. 새 표에 처음 정책을 다는 것은
  //   「좁히는」 게 아니라 「세우는」 것이고, 그 표를 읽는 자리가 있는 건 정상이다.
  const created = new Set();
  for (const m of sql.matchAll(
    /CREATE\s+(?:OR\s+REPLACE\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?"?([A-Za-z0-9_]+)"?/gi
  )) created.add(m[1]);

  // ★ 정책 이름은 **따옴표 안을 통째로** 잡는다. 공백 든 이름이 실제로 쓰인다
  //   (`"faq_nodes: authenticated can select"` 등 4개). 첫 공백에서 끊으면 그 넷이
  //   전부 `faq_nodes:` 하나로 묶여 **서로 다른 정책이 같은 것으로** 읽힌다.
  const POLICY = '(?:"([^"]+)"|(\\S+))';
  const recreated = new Set();
  for (const m of sql.matchAll(
    new RegExp(`CREATE\\s+POLICY\\s+${POLICY}\\s+ON\\s+(?:public\\.)?"?([A-Za-z0-9_]+)"?`, 'gi')
  )) recreated.add((m[1] ?? m[2]) + '\u0000' + m[3]);

  const removed = new Set();     // 통로가 사라짐 — 확정
  const unverified = [];         // 같은 이름으로 다시 만듦 — 조건 변경 여부 모름

  for (const m of sql.matchAll(
    new RegExp(`DROP\\s+POLICY\\s+(?:IF\\s+EXISTS\\s+)?${POLICY}\\s+ON\\s+(?:public\\.)?"?([A-Za-z0-9_]+)"?`, 'gi')
  )) {
    const name = m[1] ?? m[2], table = m[3];
    if (created.has(table)) continue;                    // 이 파일이 만든 표
    if (recreated.has(name + '\u0000' + table)) {
      // ★ **숨기지 않는다.** 같은 이름으로 다시 만들었다고 안전한 게 아니다 —
      //   조건이 좁아졌을 수 있고, 그건 **이 파일만 봐서는 알 수 없다**(이전 정의가
      //   다른 마이그레이션에 있다). 실제로 240 이 그 형태로 정산 조회를 잠갔다.
      //   기계가 판정 못 하는 것을 **사람이 볼 수 있는 크기로 잘라서** 넘긴다.
      unverified.push({ table, policy: name });
      continue;
    }
    removed.add(table);
  }

  // 이미 있던 표에 행 보안을 **새로 켜는** 것 (그 순간 기존 조회가 막힌다)
  for (const m of sql.matchAll(
    /ALTER\s+TABLE\s+(?:public\.)?"?([A-Za-z0-9_]+)"?[\s\S]{0,80}?ROW\s+LEVEL\s+SECURITY/gi
  )) {
    if (!created.has(m[1])) removed.add(m[1]);
  }

  return { removed: [...removed], unverified };
}

// ──────────────────────────────────────────────────────────────────
// 5. ㉯ 모드 — 결과를 admin_table_access_scan 에 기록
//    ⚠️ 서비스 키를 쓴다. 키를 절대 출력하지 않는다(오류 본문에도 안 실리게 한다).
// ──────────────────────────────────────────────────────────────────
async function record(results) {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) {
    console.error('\n✗ --record 에는 SUPABASE_URL 과 SUPABASE_SERVICE_ROLE_KEY 환경변수가 필요합니다.');
    console.error('  (키 값은 출력하지 않습니다. 셸 기록에 남지 않게 주의하세요.)');
    process.exit(2);
  }
  const now = new Date().toISOString();
  const rows = results.map((r) => ({
    table_name: r.table,
    scanned_at: now,
    reading_sites: r.hits.length,
    sites: r.hits.map((h) => ({ file: h.file, line: h.line, form: h.form })),
    updated_at: now,
  }));

  const res = await fetch(`${url}/rest/v1/admin_table_access_scan?on_conflict=table_name`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
      Prefer: 'resolution=merge-duplicates',
    },
    body: JSON.stringify(rows),
  });
  if (!res.ok) {
    // ⚠️ 응답 본문만 싣는다 — 요청 헤더(키)는 절대 싣지 않는다.
    console.error(`\n✗ 기록 실패 (HTTP ${res.status}): ${(await res.text()).slice(0, 300)}`);
    process.exit(1);
  }
  console.log(`\n✅ ${rows.length}개 표의 점검 결과를 기록했습니다.`);
}

// ──────────────────────────────────────────────────────────────────
// 6. 실행
// ──────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
const arg = (name) => {
  const i = argv.indexOf(name);
  return i === -1 ? null : argv[i + 1];
};

const sqlPath = arg('--sql');
const tablesArg = arg('--tables');
const doRecord = argv.includes('--record');

if (!sqlPath && !tablesArg) {
  console.log(`사용법:
  ㉮ 적용 전  node scripts/check-table-readers.mjs --sql supabase/migrations/NNN_*.sql
  ㉯ 적용 후  node scripts/check-table-readers.mjs --tables 표이름[,표이름...] [--record]

  --record 는 결과를 admin_table_access_scan 에 남깁니다
  (SUPABASE_URL · SUPABASE_SERVICE_ROLE_KEY 환경변수 필요).`);
  process.exit(0);
}

let tables;
let unverified = [];
if (sqlPath) {
  const narrowed = tablesNarrowedBy(sqlPath);
  if (narrowed === null) {
    // 파일 없음 — 「검사했는데 안전하다」로 읽히지 않게 원인을 그대로 밝힌다
    console.log(`\n파일을 찾지 못해 건너뜁니다: ${relative(REPO, sqlPath)}`);
    process.exit(0);
  }
  tables = narrowed.removed;
  unverified = narrowed.unverified;
  if (!tables.length && !unverified.length) {
    console.log(`\n조회 허가를 좁히는 구문을 못 찾았습니다: ${relative(REPO, sqlPath)}`);
    console.log('→ 이 파일은 조회 정책을 건드리지 않는 것으로 보입니다. 검사할 것이 없습니다.');
    process.exit(0);
  }
  if (tables.length) console.log(`\n▶ ${relative(REPO, sqlPath)} 가 좁히는 표: ${tables.join(', ')}`);
} else {
  tables = tablesArg.split(',').map((s) => s.trim()).filter(Boolean);
}

// ★ 「모른다」를 「없다」로 적지 않는다. 같은 이름으로 다시 만든 정책은 **조건이
//   좁아졌을 수 있고 이 파일만 봐서는 알 수 없다**(이전 정의가 다른 마이그레이션에 있다).
//   숨기면 240(정산 조회 잠금) 같은 진짜가 조용히 사라진다.
//   ⚠️ **확인 방법을 그 자리에 적는다** — 「안내」가 아니라 「작업 지시」가 되어야 읽힌다.
function printUnverified() {
  if (!unverified.length) return;
  console.log('\n⚠️  같은 이름으로 다시 만든 정책 — 조건이 좁아졌는지 확인해 주세요');
  console.log('    (이 파일만 봐서는 이전 조건을 알 수 없어 기계가 판정하지 못합니다)');
  for (const u of unverified) {
    console.log(`\n    ${u.table}.${u.policy}`);
    console.log(`      이전 정의 보기:  git log -p -S '${u.policy}' -- supabase/migrations/`);
    console.log(`      좁아졌다면:      node ${relative(REPO, process.argv[1])} --tables ${u.table}`);
  }
}

if (!tables.length) {   // 미검증만 있는 경우
  printUnverified();
  process.exit(0);       // ⚠️ 확정이 아니므로 3 을 쓰지 않는다(출력에는 반드시 남는다)
}

const excluded = influencerOnlyFiles();
const files = walk(DEV_DIR);
const helpers = findTableNameHelpers(files);
console.log(`▶ 검사 범위: dev/ 아래 ${files.length}개 파일 (인플루언서 전용 ${excluded.size}개 제외)`);
console.log(`▶ 표 이름을 변수로 받는 헬퍼 ${helpers.size}개: ${[...helpers].join(', ') || '없음'}`);

const results = tables.map((table) => ({ table, ...scanTable(table, files, excluded, helpers) }));

for (const r of results) {
  console.log(`\n━━ ${r.table} — 아직 읽는 자리 ${r.hits.length}곳`);
  if (r.hits.length === 0) {
    console.log('   없음. 관리자 화면은 이 표를 직접 읽지 않습니다.');
  } else {
    for (const h of r.hits) console.log(`   ${h.form}  ${h.file}:${h.line}`);
  }
  if (r.skipped.write) console.log(`   (쓰기 ${r.skipped.write}곳은 셈에서 뺐습니다 — 읽기만 셉니다)`);
}

printUnverified();

if (doRecord) await record(results);

// 자리가 남아 있으면 0 이 아닌 값으로 끝낸다 — 훅이 이 값으로 경고를 띄운다.
// ⚠️ 커밋을 막지는 않는다(작업표 작업 4 주의사항). 훅 쪽에서 이 값을 「경고」로만 쓴다.
process.exit(results.some((r) => r.hits.length > 0) ? 3 : 0);
