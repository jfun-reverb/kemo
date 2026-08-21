// ══════════════════════════════════════════════════════════════════
// Edge Function: purge-withdrawal-message-attachments
// ──────────────────────────────────────────────────────────────────
// 탈퇴 확정 6개월이 지난 회원이 **응모건 메시지에 보낸 사진**을 저장소에서
// 실제로 지운다. 지운 뒤에만 데이터베이스에 파기 표시를 남긴다.
//
// 사양서: docs/specs/2026-08-18-member-withdrawal.md
// 작업표: docs/specs/2026-08-21-message-attachment-purge-breakdown.md 작업 12-B-2
// 마이그레이션: 368_withdrawal_message_attachment_purge.sql
//
// ══════════════════════════════════════════════════════════════════
// 이 함수는 purge-withdrawal-media 의 형제다
// ══════════════════════════════════════════════════════════════════
//   그쪽은 영수증·인증샷(공개 통 `campaign-images`), 이쪽은 메시지 첨부
//   (비공개 통 `application-message-attachments`). 실패 처리·순서·공개 키
//   거부는 **일부러 같은 모양**으로 뒀다 — 둘 중 하나만 고치는 사고를 막으려면
//   나란히 놓고 볼 수 있어야 한다.
//
//   ⚠️ 다만 **한 가지가 다르다**: 그쪽은 행 하나 = 파일 하나인데,
//   이쪽은 **메시지 하나에 사진이 여러 장**(최대 5장)이다. 그래서 한 장만
//   지워지고 나머지가 실패하면 그 메시지는 **표시하지 않는다** — 표시하면
//   남은 사진의 주소가 사라져 영영 못 찾는다.
//
// ══════════════════════════════════════════════════════════════════
// 🔴 순서가 전부다: 지우고 → 표시한다
// ══════════════════════════════════════════════════════════════════
//   반대로 하면(표시 먼저 → 삭제) 삭제에 실패한 파일이 「지운 것」으로 찍혀
//   목록에서 빠지고, 그 파일은 **영원히 저장소에 남는다.** 표시가 첨부 목록을
//   `{"purged":true}` 로 덮으므로 주소를 다시 찾을 방법도 없다.
//
// 트리거: pg_cron 매일 UTC 20:30(= 한국·일본 05:30) net.http_post
//   (작업 12-B-3). 05:15 는 purge-withdrawal-media 가 이미 쓴다 — 파기끼리
//   같은 분에 몰리면 하나가 실패했을 때 원인을 가리기 어려워 15분 뗐다.
//   탈퇴 상태 전이(04:45)보다 반드시 뒤여야 한다(그날 확정된 건이 포함되도록).
//
// 대상 선정 / 재시도:
//   list_pending_withdrawal_message_attachment_purge() 가 「기한 지났고 아직
//   파기 표시가 없는」 메시지를 돌려준다. **별도 큐가 없다** — 표시가 안 붙은
//   것은 다음 실행에 자동으로 다시 잡힌다. 「쌓기만 하고 안 지우는」 실패가
//   구조적으로 불가능하다.
//
// keep_paths 가 뭔가:
//   같은 사진을 **파기 대상이 아닌 다른 메시지**도 가리키는 경우다. 파일은
//   남기고 이 메시지의 첨부 목록만 덮는다. 아직 탈퇴하지 않은 사람의 것이기도
//   하기 때문이다. (실제로는 거의 없지만 — 첨부 주소는 올릴 때마다 새로
//   만들어진다 — 데이터베이스가 이미 판정해 주므로 그대로 따른다.)
//
// 환경변수 (Edge Functions Secrets — 둘 다 자동 주입):
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY
//
// 배포:
//   supabase functions deploy purge-withdrawal-message-attachments --project-ref qysmxtipobomefudyixw   # 개발
//   supabase functions deploy purge-withdrawal-message-attachments --project-ref nrwtujmlbktxjgdwlpjj   # 운영
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const BUCKET = "application-message-attachments";

// 한 번에 저장소에 넘기는 경로 개수.
const DELETE_CHUNK = 100;

// 한 실행에서 처리할 최대 메시지 수. 못 한 것은 표시가 안 붙어 다음 실행이
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
  message_id: string;
  delete_paths: string[] | null;
  keep_paths: string[] | null;
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
  if (rejectPublicKeyCaller(req, "purge-withdrawal-message-attachments")) {
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
      `[purge-msg-attach] bucket '${BUCKET}' unavailable — aborting before any mark`,
      bucketErr,
    );
    return new Response(
      JSON.stringify({ ok: false, error: "bucket_unavailable", bucket: BUCKET }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  // ── 1. 대상 조회 ────────────────────────────────────────────────
  const { data, error: listErr } = await sb.rpc(
    "list_pending_withdrawal_message_attachment_purge",
    { p_limit: BATCH_LIMIT },
  );

  if (listErr) {
    console.error("[purge-msg-attach] list failed", listErr);
    return new Response(
      JSON.stringify({ ok: false, error: "list_failed" }),
      { status: 500, headers: { "content-type": "application/json" } },
    );
  }

  const rows: PurgeRow[] = Array.isArray(data) ? data : [];
  if (rows.length === 0) {
    console.log("[purge-msg-attach] nothing to purge");
    return new Response(
      JSON.stringify({ ok: true, candidates: 0, deleted_files: 0, marked: 0 }),
      { headers: { "content-type": "application/json" } },
    );
  }

  // ── 2. 지울 경로를 모은다 (메시지 여러 개가 같은 경로를 가리킬 수 있다) ──
  const pathToMessages = new Map<string, Set<string>>();
  for (const r of rows) {
    for (const p of r.delete_paths ?? []) {
      if (!p) continue;
      const set = pathToMessages.get(p) ?? new Set<string>();
      set.add(r.message_id);
      pathToMessages.set(p, set);
    }
  }

  // ── 3. 저장소에서 실제로 지운다 ─────────────────────────────────
  //   실패한 묶음에 속한 경로를 가리키는 메시지는 **표시하지 않는다.**
  //   ⚠️ 메시지 하나에 사진이 여러 장이라, 한 장이라도 실패하면 그 메시지
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
        `[purge-msg-attach] storage remove failed for ${group.length} files`,
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
  //   지울 것이 하나도 없던 메시지(전부 keep_paths)도 여기 포함된다 —
  //   파일은 남기고 첨부 목록만 덮는 것이 맞다.
  const idsToMark = rows
    .map((r) => r.message_id)
    .filter((id) => !failedMessageIds.has(id));

  let marked = 0;
  if (idsToMark.length > 0) {
    const { data: markData, error: markErr } = await sb.rpc(
      "mark_withdrawal_message_attachments_purged",
      { p_message_ids: idsToMark },
    );
    if (markErr) {
      // 🔴 파일은 이미 사라졌는데 표시가 안 된 상태다. 다음 실행이 같은
      //    메시지를 다시 집고, 저장소는 「없는 파일 삭제」를 성공으로 답하므로
      //    그때 표시가 채워진다. 즉 스스로 회복된다 — 그래서 여기서 전체를
      //    실패로 돌리지 않고 기록만 남긴다.
      console.error("[purge-msg-attach] mark failed (self-heals next run)", markErr);
    } else {
      marked = typeof markData === "number" ? markData : idsToMark.length;
    }
  }

  const result = {
    ok: true,
    candidates: rows.length,
    deleted_files: deletedFiles,
    marked,
    deferred_messages: failedMessageIds.size, // 삭제 실패로 미룬 메시지
    failed_chunks: failedChunks,
  };
  console.log("[purge-msg-attach] done", result);

  return new Response(JSON.stringify(result), {
    headers: { "content-type": "application/json" },
  });
});
