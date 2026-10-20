// ══════════════════════════════════════════════════════════════════
// Edge Function: purge-cs-comment-attachments
// ──────────────────────────────────────────────────────────────────
// CS 이력 **지운 메모**(내가 지운 메모 · 개인정보를 비운 건의 메모 — 562·563)에 붙어 있던
// 사진을 저장소(비공개 통 `cs-case-attachments`)에서 실제로 지운다. 지운 뒤에만 표시한다.
//
// 사양서: docs/specs/2026-10-16-cs-history-management.md 「구현 결과」 1-6·4-1 · 첨부 파기(S-3)
// 마이그레이션: 567_cs_comment_attachment_purge.sql(목록·표시) · 568(운영 예약)
//
// 🔴 이 함수는 purge-withdrawal-message-attachments 를 **복제해 대상만 바꿨다** — 실패 처리·순서·
//    공개 키 거부가 같은 모양이다. 공개 키 거부 본문은 웹훅·예약 함수들과 **글자 그대로 같다**(고칠 때 함께).
//
// 🔴 순서: 지우고 → 표시(첨부 목록을 '[]' 로). 반대면 지우지 못한 파일의 경로가 사라져 영영 남는다.
//    통이 없으면(이름 바뀜 등) 아무것도 표시하지 않고 멈춘다 — 없는 통 삭제도 「성공」으로 답하기 때문(S-3).
//    메모 하나에 사진이 여러 장(최대 5장) — 한 묶음이라도 실패하면 그 메모는 표시하지 않는다(다음 실행에 다시 잡힌다).
//
// 트리거: pg_cron 매일 UTC 21:30(= 한국·일본 06:30) net.http_post(568)
// 배포: supabase functions deploy purge-cs-comment-attachments --project-ref <개발|운영>
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUCKET = "cs-case-attachments";

// 한 번에 저장소에 넘기는 경로 개수.
const DELETE_CHUNK = 100;

// 한 실행에서 처리할 최대 메모 수. 못 한 것은 표시가 안 붙어 다음 실행이
// 다시 집는다.
const BATCH_LIMIT = 500;

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

// ── 공개 키로 온 호출은 거부한다 ─────────────────────────────────
// 이 함수는 예약 실행(pg_cron)만 부른다 — 브라우저에서 부르는 자리가 0곳이다.
// 그런데 사이트에 그대로 박혀 있는 공개 키로 부르면 인증을 통과한다
// (2026-08-10 운영 실측). 이 함수는 **되돌릴 수 없는 삭제**를 한다.
// ⚠️ 반대로 「특정 값이어야 통과」로 조이지 않는다 — 정상 경로가 무엇을
//    보내는지 기록이 없어, 그 값이 아니면 파기가 통째로 죽는다.
// ⚠️ 공개 키를 교체하면 이 목록도 함께 갱신할 것.
// (같은 형태: purge-withdrawal-media · notify-brand-application ·
//  notify-orient-submitted · notify-withdrawal-scheduled)
const PUBLIC_CLIENT_KEYS = [
  "sb_publishable_3pfK7sF55NZO7owlm13_uA_iCbORAvP",  // 운영
  "sb_publishable_WTxFsvQFllOPIdQ8MDNwCw_e0qBlYTv",  // 개발
];

// JWT 의 역할(role)만 읽는다 — 서명은 플랫폼이 이미 검증했다. 못 읽으면 null(막지 않는다).
function jwtRole(token: string): string | null {
  if (!token.startsWith("eyJ")) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const payload = JSON.parse(atob(b64 + "=".repeat((4 - (b64.length % 4)) % 4)));
    return typeof payload?.role === "string" ? payload.role : null;
  } catch {
    return null;   // 못 읽으면 막지 않는다 — 정상 발송을 세우는 쪽이 더 나쁘다
  }
}

function rejectPublicKeyCaller(req: Request, tag: string): boolean {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const token = raw.replace(/^Bearer\s+/i, "").trim();
  if (!token) return false;                       // 토큰 없음 — 플랫폼이 이미 막는다
  if (PUBLIC_CLIENT_KEYS.includes(token)) {
    console.warn(`[${tag}] rejected — called with the public client key`);
    return true;
  }
  // 🔴 비로그인(anon)·로그인 회원(authenticated) 토큰은 거부한다(2026-09-28 전수조사 3차).
  //   회원가입은 누구나 할 수 있어 authenticated 토큰도 사실상 공개다 — 예전에는 anon 만 막아
  //   로그인한 회원이 방침 통지 시험 발송(임의 주소)·홍보 메일 전체 발송을 부를 수 있었다.
  //   예약 실행(vault edge_function_jwt)·데이터베이스 웹훅은 service_role 이라 통과한다.
  const role = jwtRole(token);
  if (role === "anon" || role === "authenticated") {
    console.warn(`[${tag}] rejected — called with an end-user JWT`, { role });
    return true;
  }
  // 토큰 자체는 절대 남기지 않는다.
  const isServiceRole = token === (Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "");
  console.log(`[${tag}] caller check passed`, { isServiceRole, role });
  return false;
}

interface PurgeRow {
  comment_id: string;
  paths: string[] | null;
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
  if (rejectPublicKeyCaller(req, "purge-cs-comment-attachments")) {
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
  //   Supabase 저장소는 없는 통·없는 경로에 대한 삭제 요청을 **조용히 성공으로
  //   답한다**(2026-08-20 개발서버 실측 — 통 이름을 일부러 틀리게 바꿔 돌렸더니
  //   오류가 안 났고 파기 표시만 붙었다. 파일은 남아 있는데 주소만 사라진,
  //   이 기능에서 가장 나쁜 실패다).
  //
  // ⚠️ 그런데 **「없는 파일」은 성공으로 받아야 한다**(이미 지운 것을 다시
  //   지우는 정상 경우다). 그래서 응답으로 둘을 구분하려 하지 않고,
  //   **통 존재만 시작할 때 한 번** 확인한다.
  const { error: bucketErr } = await sb.storage.getBucket(BUCKET);
  if (bucketErr) {
    console.error(
      `[purge-cs-attach] bucket '${BUCKET}' unavailable — aborting before any mark`,
      bucketErr,
    );
    return new Response(
      JSON.stringify({ ok: false, error: "bucket_unavailable", bucket: BUCKET }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  // ── 1. 대상 조회 ────────────────────────────────────────────────
  const { data, error: listErr } = await sb.rpc(
    "list_pending_cs_attachment_purge",
    { p_limit: BATCH_LIMIT },
  );

  if (listErr) {
    console.error("[purge-cs-attach] list failed", listErr);
    return new Response(
      JSON.stringify({ ok: false, error: "list_failed" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const rows: PurgeRow[] = Array.isArray(data) ? data : [];
  if (rows.length === 0) {
    console.log("[purge-cs-attach] nothing to purge");
    return new Response(
      JSON.stringify({ ok: true, candidates: 0, deleted_files: 0, marked: 0 }),
      { headers: { "content-type": "application/json" } },
    );
  }

  // ── 2. 지울 경로를 모은다 (메모 여러 개가 같은 경로를 가리킬 수 있다) ──
  const pathToMessages = new Map<string, Set<string>>();
  for (const r of rows) {
    for (const p of r.paths ?? []) {
      if (!p) continue;
      const set = pathToMessages.get(p) ?? new Set<string>();
      set.add(r.comment_id);
      pathToMessages.set(p, set);
    }
  }

  // ── 3. 저장소에서 실제로 지운다 ─────────────────────────────────
  //   실패한 묶음에 속한 경로를 가리키는 메모는 **표시하지 않는다.**
  //   ⚠️ 메모 하나에 사진이 여러 장이라, 한 장이라도 실패하면 그 메모
  //      전체를 미뤄야 한다(표시하면 남은 사진 주소가 사라진다).
  const failedMessageIds = new Set<string>();
  let deletedFiles = 0;
  let failedChunks = 0;

  for (const group of chunk([...pathToMessages.keys()], DELETE_CHUNK)) {
    const { error: rmErr } = await sb.storage.from(BUCKET).remove(group);
    if (rmErr) {
      failedChunks += 1;
      // 주소 자체는 로그에 남기지 않는다(주소 = 파일 열람 실마리).
      console.error(
        `[purge-cs-attach] storage remove failed for ${group.length} files`,
        rmErr,
      );
      for (const p of group) {
        for (const id of pathToMessages.get(p) ?? []) failedMessageIds.add(id);
      }
      continue;
    }
    deletedFiles += group.length;
  }

  // ── 4. 지운 뒤에만 표시한다 ─────────────────────────────────────
  //   올바른 경로가 하나도 없던 메모(목록이 비정상)도 여기 포함된다 — 지울 파일이 없으니 목록만 비운다.
  const idsToMark = rows
    .map((r) => r.comment_id)
    .filter((id) => !failedMessageIds.has(id));

  let marked = 0;
  if (idsToMark.length > 0) {
    const { data: markData, error: markErr } = await sb.rpc(
      "mark_cs_attachments_purged",
      { p_comment_ids: idsToMark },
    );
    if (markErr) {
      // 🔴 파일은 이미 사라졌는데 표시가 안 된 상태다. 다음 실행이 같은
      //    메모를 다시 집고, 저장소는 「없는 파일 삭제」를 성공으로 답하므로
      //    그때 표시가 채워진다. 즉 스스로 회복된다 — 그래서 여기서 전체를
      //    실패로 돌리지 않고 기록만 남긴다.
      console.error("[purge-cs-attach] mark failed (self-heals next run)", markErr);
    } else {
      marked = typeof markData === "number" ? markData : idsToMark.length;
    }
  }

  const result = {
    ok: true,
    candidates: rows.length,
    deleted_files: deletedFiles,
    marked,
    deferred_comments: failedMessageIds.size, // 삭제 실패로 미룬 메모
    failed_chunks: failedChunks,
  };
  console.log("[purge-cs-attach] done", result);

  return new Response(JSON.stringify(result), {
    headers: { "content-type": "application/json" },
  });
});
