// ══════════════════════════════════════════════════════════════════
// Edge Function: purge-withdrawal-media
// ──────────────────────────────────────────────────────────────────
// 탈퇴 확정 6개월이 지난 회원의 영수증·인증샷 파일을 저장소에서 **실제로
// 지운다**. 지운 뒤에만 데이터베이스에 파기 표시를 남긴다.
//
// 사양서: docs/specs/2026-08-18-member-withdrawal.md
// 작업표: docs/specs/2026-08-19-member-withdrawal-breakdown.md 작업 12
// 마이그레이션: 364_withdrawal_media_purge.sql
//
// ══════════════════════════════════════════════════════════════════
// 🔴 이 저장소에서 「서버가 저장소 파일을 지우는」 첫 함수다
// ══════════════════════════════════════════════════════════════════
//   지금까지 파일 삭제는 전부 브라우저가 했다(감사용 계정 청소·캠페인 보관
//   삭제 — 서버가 경로를 돌려주고 화면이 지운다). 이번은 예약 실행이라
//   브라우저가 없어서 여기서 직접 지운다.
//
//   메일을 보내는 함수가 아니다 — Brevo 를 안 쓴다. 그래서 「개발서버 발송
//   시험 금지」 정책의 대상이 아니고, **개발서버에서 끝까지 시험해야 한다**
//   (실제로 파일이 사라지는 것을 눈으로 보는 것이 이 작업의 완료 기준이다).
//
// ══════════════════════════════════════════════════════════════════
// 🔴 순서가 전부다: 지우고 → 표시한다
// ══════════════════════════════════════════════════════════════════
//   반대로 하면(표시 먼저 → 삭제) 삭제에 실패한 파일이 「지운 것」으로
//   찍혀 목록에서 빠지고, 그 파일은 **영원히 저장소에 남는다.** 주소 칸을
//   이미 비웠으니 다시 찾을 방법도 없다.
//
// 트리거: pg_cron 매일 UTC 20:15(= KST/JST 05:15) net.http_post
//   (마이그레이션 365). 05:00 은 363(페이팔 파기)이 이미 쓴다 — 파기끼리
//   같은 분에 몰리면 하나가 실패했을 때 원인을 가리기 어려워 15분 뗐다.
//   탈퇴 상태 전이(04:45)보다는 반드시 뒤여야 한다(그날 확정된 건이 이
//   실행에 포함되도록).
//
// 대상 선정 / 재시도:
//   list_pending_withdrawal_media_purge() 가 「기한 지났고 아직 주소가
//   남아 있는」 행을 돌려준다. **별도 큐가 없다** — 안 지운 것은 주소가
//   그대로 남아 다음 실행에 자동으로 다시 잡힌다. 「쌓기만 하고 안 지우는」
//   실패가 구조적으로 불가능하다(마이그레이션 364 헤더의 325 사례 참고).
//
// 이 함수가 파기 표시를 **안 하는** 경우 — 행 단위 둘, 시작 전 하나:
//
//   [행 단위 — 그 행만 건너뛰고 나머지는 계속 처리]
//   ① storage_path 가 null (주소 형식 불일치) — 표시하면 주소가 사라져
//      파일을 영영 못 찾는다. 안 지운 채 두면 밀린 건수에 남아 눈에 띈다.
//   ② 저장소 삭제가 오류를 냈을 때 — 다음 실행이 다시 집는다.
//
//   [시작 전 — 아무것도 안 하고 통째로 중단]
//   ③ 통 자체를 못 찾을 때 (아래 [0]) — 그 상태로 진행하면 삭제가 전부
//      헛돌면서 표시만 붙는다.
//   ⚠️ 「파일이 이미 없음」은 오류가 아니다(Supabase 저장소는 없는 경로를
//      지워도 성공으로 답한다). 이걸 실패로 치면 밀린 건수가 0 이 될 수
//      없고, 상시 켜진 경고는 아무도 안 본다.
//   🔴 **그런데 저장소는 「없는 통」에 대한 삭제도 조용히 성공으로 답한다**
//      (2026-08-20 개발서버 실측). 그래서 응답만으로는 「이미 없는 파일」과
//      「통 자체가 틀림」을 구분할 수 없다 → 아래 [0] 에서 **통 존재를
//      시작할 때 한 번 확인**한다. 그 검사를 빼면 통 이름이 바뀌는 날
//      파일은 그대로인데 주소 칸만 비워진다.
//
// should_delete_file = false 인 행:
//   같은 주소를 파기 대상 밖의 다른 행도 가리키는 경우다. 파일은 남기고
//   **이 행의 주소 칸만 비운다**(= 표시는 한다). 그 파일은 아직 탈퇴하지
//   않은 다른 사람의 것이기도 하기 때문이다.
//
// 환경변수 (Edge Functions Secrets — 둘 다 자동 주입):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// 배포:
//   supabase functions deploy purge-withdrawal-media --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy purge-withdrawal-media --project-ref nrwtujmlbktxjgdwlpjj   # 운영
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUCKET = "campaign-images";

// 한 번에 저장소에 넘기는 경로 개수. 배열이 너무 길면 요청이 거부될 수
// 있어 나눠 보낸다. 한 묶음이 실패해도 나머지 묶음은 계속 진행한다.
const DELETE_CHUNK = 100;

// 한 실행에서 처리할 최대 행 수. 밀린 것이 많아도 한 번에 다 하지 않고
// 며칠에 걸쳐 줄인다(한 실행이 너무 길어져 중간에 끊기는 것 방지).
// 못 한 것은 주소가 남아 있어 다음 실행이 다시 집는다.
const BATCH_LIMIT = 500;

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

// ── 공개 키로 온 호출은 거부한다 ─────────────────────────────────
// 이 함수는 예약 실행(pg_cron)만 부른다 — 브라우저에서 부르는 자리가 0곳이다.
// 그런데 사이트에 그대로 박혀 있는 공개 키로 부르면 인증을 통과한다
// (2026-08-10 운영 실측). 그러면 누구나 파기를 임의로 촉발할 수 있는데,
// 이 함수는 **되돌릴 수 없는 삭제**를 하므로 메일 함수보다 위험이 크다.
// ⚠️ 반대로 「특정 값이어야 통과」로 조이지 않는다 — 정상 경로가 무엇을
//    보내는지 기록이 없어, 그 값이 아니면 파기가 통째로 죽는다.
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
// (같은 형태: notify-brand-application · notify-orient-submitted ·
//  notify-withdrawal-scheduled)
const PUBLIC_CLIENT_KEYS = [
  "sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP",  // 운영
  "sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv",  // 개발
];

function rejectPublicKeyCaller(req: Request, tag: string): boolean {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;                       // 토큰 없음 — 플랫폼이 이미 막는다
  if (PUBLIC_CLIENT_KEYS.includes(token)) {
    console.warn(`[${tag}] rejected — called with the public client key`);
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole });
  return false;
}

interface PurgeRow {
  deliverable_id: string;
  receipt_url: string | null;
  storage_path: string | null;
  should_delete_file: boolean;
}

function chunk<T>(arr: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < arr.length; i += size) out.push(arr.slice(i, i + size));
  return out;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }
  if (rejectPublicKeyCaller(req, "purge-withdrawal-media")) {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "SUPABASE env missing" }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // ── 0. 통이 실제로 있는지 먼저 확인한다 ─────────────────────────
  //
  // 🔴 **이 검사가 없으면 삭제 실패를 감지할 방법이 아예 없다.**
  //   2026-08-20 개발서버 실측: 통 이름을 일부러 틀리게 바꿔 배포하고 돌렸더니
  //   `remove()` 가 **오류를 내지 않았고**, 그래서 파기 표시가 그대로 붙었다
  //   (파일은 남아 있는데 주소 칸만 비워진 상태 — 이 기능에서 가장 나쁜 실패).
  //   Supabase 저장소는 없는 통·없는 경로에 대한 삭제 요청을 조용히 성공으로
  //   답한다.
  //
  // ⚠️ 그런데 **「없는 파일」은 성공으로 받아야 한다**(이미 지운 것을 다시
  //   지우는 정상 경우다. 실패로 치면 그 행이 매일 목록에 떠 밀린 건수가
  //   0 이 될 수 없고, 상시 켜진 경고는 아무도 안 본다).
  //   → 그래서 「없는 파일」과 「없는 통」을 응답으로 구분하려 하지 않고,
  //     **통 존재만 시작할 때 한 번 확인**한다. 통 이름은 코드 상수라
  //     배포 시점에 고정되고, 그게 틀린 것은 데이터 문제가 아니라
  //     설정 오류라 한 번만 보면 된다.
  //
  // 확인에 실패하면 **아무것도 안 하고 끝낸다** — 주소 칸이 그대로 남아
  // 다음 실행이 같은 행을 다시 집는다.
  const { error: bucketErr } = await sb.storage.getBucket(BUCKET);
  if (bucketErr) {
    console.error(
      `[purge-withdrawal-media] bucket '${BUCKET}' unavailable — aborting before any mark`,
      bucketErr,
    );
    return new Response(
      JSON.stringify({ ok: false, error: "bucket_unavailable", bucket: BUCKET }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  // ── 1. 대상 조회 ────────────────────────────────────────────────
  const { data, error: listErr } = await sb.rpc(
    "list_pending_withdrawal_media_purge",
    { p_limit: BATCH_LIMIT },
  );

  if (listErr) {
    console.error("[purge-withdrawal-media] list failed", listErr);
    return new Response(
      JSON.stringify({ ok: false, error: "list_failed" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const rows: PurgeRow[] = Array.isArray(data) ? data : [];
  if (rows.length === 0) {
    console.log("[purge-withdrawal-media] nothing to purge");
    return new Response(
      JSON.stringify({ ok: true, candidates: 0, deleted_files: 0, marked: 0 }),
      { headers: { "content-type": "application/json" } },
    );
  }

  // ── 2. 세 갈래로 나눈다 ─────────────────────────────────────────
  //   a) 파일을 지워야 하는 행           → 지운 뒤 표시
  //   b) 파일은 남기고 주소만 비울 행    → 바로 표시 (다른 사람도 쓰는 파일)
  //   c) 주소 형식이 안 맞는 행           → 아무것도 안 한다 (밀린 건수에 남김)
  const toDelete = rows.filter((r) => r.should_delete_file && r.storage_path);
  const markOnly = rows.filter((r) => !r.should_delete_file && r.storage_path);
  const skipped  = rows.filter((r) => !r.storage_path);

  if (skipped.length > 0) {
    // 주소 자체는 로그에 남기지 않는다(공개 통이라 주소 = 파일 열람).
    console.warn(
      `[purge-withdrawal-media] ${skipped.length} rows skipped — storage path could not be derived`,
    );
  }

  // ── 3. 저장소에서 실제로 지운다 ─────────────────────────────────
  //   같은 파일을 두 행이 가리키는 경우가 있어 경로는 중복을 없앤 뒤 넘긴다.
  const pathToIds = new Map<string, string[]>();
  for (const r of toDelete) {
    const p = r.storage_path as string;
    const ids = pathToIds.get(p) ?? [];
    ids.push(r.deliverable_id);
    pathToIds.set(p, ids);
  }

  const deletedIds: string[] = [];
  let deletedFiles = 0;
  let failedChunks = 0;

  for (const group of chunk([...pathToIds.keys()], DELETE_CHUNK)) {
    const { error: rmErr } = await sb.storage.from(BUCKET).remove(group);
    if (rmErr) {
      // 이 묶음은 표시하지 않는다 — 다음 실행이 같은 행을 다시 집는다.
      failedChunks += 1;
      console.error(
        `[purge-withdrawal-media] storage remove failed for ${group.length} files`,
        rmErr,
      );
      continue;
    }
    deletedFiles += group.length;
    for (const p of group) deletedIds.push(...(pathToIds.get(p) ?? []));
  }

  // ── 4. 지운 뒤에만 표시한다 ─────────────────────────────────────
  const idsToMark = [...deletedIds, ...markOnly.map((r) => r.deliverable_id)];

  let marked = 0;
  if (idsToMark.length > 0) {
    const { data: markData, error: markErr } = await sb.rpc(
      "mark_withdrawal_media_purged",
      { p_ids: idsToMark },
    );
    if (markErr) {
      // 🔴 파일은 이미 사라졌는데 표시가 안 된 상태다. 다음 실행이 같은
      //    행을 다시 집고, 저장소는 「없는 파일 삭제」를 성공으로 답하므로
      //    그때 표시가 채워진다. 즉 스스로 회복된다 — 그래서 여기서
      //    전체를 실패로 돌리지 않고 기록만 남긴다.
      console.error("[purge-withdrawal-media] mark failed (self-heals next run)", markErr);
    } else {
      marked = typeof markData === "number" ? markData : idsToMark.length;
    }
  }

  const result = {
    ok: true,
    candidates: rows.length,
    deleted_files: deletedFiles,
    marked,
    mark_only: markOnly.length,      // 다른 행도 쓰는 파일이라 주소만 비움
    skipped_no_path: skipped.length, // 주소 형식 불일치 — 사람이 봐야 함
    failed_chunks: failedChunks,
  };
  console.log("[purge-withdrawal-media] done", result);

  return new Response(JSON.stringify(result), {
    headers: { "content-type": "application/json" },
  });
});
