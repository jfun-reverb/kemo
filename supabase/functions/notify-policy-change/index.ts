// notify-policy-change — 약관·개인정보처리방침 개정 사전 통지 메일 발송기
//
// 동작:
//   1. 첫 배치만 policy_notice_runs INSERT (notice_key UNIQUE = mutex, 중복 호출 차단)
//   2. influencers 전건 조회(id, 정렬) — marketing_opt_in 무관(필수 고지/트랜잭션)
//   3. batchOffset~+BATCH_SIZE 슬라이스 → 이메일 일괄 조회(auth.admin.getUserById)
//   4. 인플별 발송:
//      - policy_notice_sent 에 status='sent' 선점 INSERT (ON CONFLICT 23505 → already_sent skip)
//      - 선점 성공 시 Brevo 발송, 실패 시 status='failed' UPDATE
//      - 이메일 없으면 status='skipped'(no_email)
//   5. hasMore 면 자기재호출(fire-and-forget, source='chained')
//   6. 마지막 배치에서 policy_notice_runs status/count finalize
//
// 호출 (운영자 수동, cron 아님):
//   { "noticeKey": "message_feature_2026", "effectiveDate": "2026年6月27日" }
//   testRecipient 지정 시 단일 발송 + 로그/멱등 우회(디버그).
//
// 마이그레이션 153 (policy_notice_runs / policy_notice_sent) 의존.
// 메모: influencers.id = auth.users.id (project_influencer_join_key)

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const BATCH_SIZE = 200;          // 배치당 인플 수 (Deno 150초 timeout 안전)
const DEFAULT_NOTICE_KEY = "message_feature_2026";

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function loadTemplate(name: string): string {
  const html = TEMPLATES[name];
  if (!html) throw new Error(`template not registered: ${name}`);
  // HTML 주석 제거 — 주석 안 placeholder 치환 시 중첩 주석 → 본문 누출 차단
  return html.replace(/<!--[\s\S]*?-->/g, "");
}

function render(html: string, data: Record<string, string>): string {
  let out = html;
  for (const [k, v] of Object.entries(data)) {
    out = out.replaceAll(`{{${k}}}`, v);
  }
  return out;
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");
  const senderEmail = env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com");
  const senderName = env("BREVO_SENDER_NAME", "REVERB JP");
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: {
      "api-key": apiKey,
      "content-type": "application/json",
      accept: "application/json",
    },
    body: JSON.stringify({
      sender: { email: senderEmail, name: senderName },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Brevo send failed ${res.status}: ${errText}`);
  }
}

// 메일 제목·본문 빌드 (고정 문안 + 시행일 치환)
function buildMail(effectiveDate: string): { subject: string; html: string; text: string } {
  const tpl = loadTemplate("policy-change-notice");
  const html = render(tpl, { effective_date: effectiveDate });
  const subject = "【REVERB JP】「メッセージ」機能の追加と、規約・プライバシーポリシー改定のお知らせ";
  const text = [
    "REVERB JP をご利用いただきありがとうございます。",
    "",
    "応募したキャンペーンごとに運営チームへ直接お問い合わせができる「メッセージ」機能を追加します。",
    "あわせて、利用規約とプライバシーポリシーを一部改定いたします。",
    "",
    "■ 新しく集める情報：メッセージの本文・添付画像（保管期間：応募終了後1年 / 退会時に削除）",
    "■ メッセージを見られる人：ご本人と運営チームのみ",
    `■ 施行日：${effectiveDate}`,
    "",
    "改定後の規約全文はアプリ下部の「利用規約」「個人情報処理方針」からご確認ください。",
    "お問い合わせは公式LINE @reverb.jp まで。",
  ].join("\n");
  return { subject, html, text };
}

function selfInvokeChained(args: {
  supaUrl: string; serviceKey: string;
  noticeKey: string; effectiveDate: string; nextOffset: number;
}): void {
  const url = `${args.supaUrl.replace(/\/$/, "")}/functions/v1/notify-policy-change`;
  // await 하지 않음 (fire-and-forget)
  fetch(url, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${args.serviceKey}`,
    },
    body: JSON.stringify({
      source: "chained",
      noticeKey: args.noticeKey,
      effectiveDate: args.effectiveDate,
      batchOffset: args.nextOffset,
    }),
  }).catch((e) => console.error("[notify-policy-change] chained invoke failed", e));
}

Deno.serve(async (req) => {
  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    return new Response(JSON.stringify({ error: "missing env" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  let body: {
    source?: "manual" | "chained";
    noticeKey?: string;
    effectiveDate?: string;
    batchOffset?: number;
    testRecipient?: string;
  } = {};
  try { body = await req.json(); } catch { /* 빈 body 허용 */ }

  const noticeKey = body.noticeKey || DEFAULT_NOTICE_KEY;
  const effectiveDate = body.effectiveDate || "別途ご案内いたします";
  if (!body.effectiveDate) {
    console.warn("[notify-policy-change] effectiveDate 미지정 — 폴백 문구로 발송됨. 통지 메일엔 시행일 명시 권장");
  }
  const batchOffset = body.batchOffset ?? 0;
  const isFirstBatch = batchOffset === 0;
  const source = body.source ?? "manual";

  // ── 0. testRecipient 디버그 모드 (멱등/로그/mutex 우회 단일 발송) ──
  if (body.testRecipient) {
    try {
      const mail = buildMail(effectiveDate);
      await sendBrevoEmail({
        to: [{ email: body.testRecipient, name: "テスト" }],
        subject: mail.subject, htmlContent: mail.html, textContent: mail.text,
      });
      return new Response(JSON.stringify({ ok: true, test: true, recipient: body.testRecipient }), {
        status: 200, headers: { "content-type": "application/json" },
      });
    } catch (e) {
      return new Response(JSON.stringify({ error: (e as Error).message, stage: "test" }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
  }

  // ── 1. 첫 배치 mutex (notice_key UNIQUE) ──
  if (isFirstBatch) {
    const { error } = await sb.from("policy_notice_runs").insert({
      notice_key: noticeKey,
      status: "failed",
      target_influencer_count: 0,
      sent_count: 0, skipped_count: 0, failed_count: 0,
      error_message: "in-flight",
      triggered_by: null,
    });
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        console.log("[notify-policy-change] already processed", noticeKey);
        return new Response(JSON.stringify({ ok: true, skipped: true, reason: "already_processed", noticeKey }), {
          status: 200, headers: { "content-type": "application/json" },
        });
      }
      return new Response(JSON.stringify({ error: "mutex insert failed", detail: error.message }), {
        status: 500, headers: { "content-type": "application/json" },
      });
    }
  }

  const finalizeRun = async (payload: {
    status: "sent" | "partial" | "failed";
    targetCount?: number;
    sentCount: number; skippedCount: number; failedCount: number;
    errorMessage?: string | null;
    finishedAt?: string;
  }) => {
    const upd: Record<string, unknown> = {
      status: payload.status,
      sent_count: payload.sentCount,
      skipped_count: payload.skippedCount,
      failed_count: payload.failedCount,
      error_message: payload.errorMessage ?? null,
    };
    if (payload.targetCount !== undefined) upd.target_influencer_count = payload.targetCount;
    if (payload.finishedAt !== undefined) upd.finished_at = payload.finishedAt;
    const { error } = await sb.from("policy_notice_runs").update(upd).eq("notice_key", noticeKey);
    if (error) console.error("[notify-policy-change] finalize failed", error);
  };

  // influencers 전건 id 조회 (PostgREST 1000-row cap 대응 range loop). sb 클로저 사용.
  const fetchAllInfluencerIds = async (): Promise<string[]> => {
    const ids: string[] = [];
    const PAGE = 1000;
    let from = 0;
    while (true) {
      const { data, error } = await sb
        .from("influencers")
        .select("id")
        .order("id", { ascending: true })
        .range(from, from + PAGE - 1);
      if (error) throw error;
      const rows = (data || []) as { id: string }[];
      rows.forEach((r) => ids.push(r.id));
      if (rows.length < PAGE) break;
      from += PAGE;
    }
    return ids;
  };

  try {
    // ── 2. 전체 인플 id ──
    const allIds = await fetchAllInfluencerIds();
    const total = allIds.length;
    const batchIds = allIds.slice(batchOffset, batchOffset + BATCH_SIZE);
    const hasMore = batchOffset + BATCH_SIZE < total;
    console.log("[notify-policy-change] batch", { source, batchOffset, batchSize: batchIds.length, total, hasMore });

    // ── 3. 배치 이메일 일괄 조회 ──
    const emailMap = new Map<string, string>();
    const emailResults = await Promise.all(batchIds.map((id) => sb.auth.admin.getUserById(id)));
    emailResults.forEach((r, i) => {
      if (!r.error && r.data?.user?.email) emailMap.set(batchIds[i], r.data.user.email);
    });

    const mail = buildMail(effectiveDate);

    // ── 4. 발송 ──
    let sent = 0, skipped = 0, failed = 0;
    for (const id of batchIds) {
      const email = emailMap.get(id);
      if (!email) {
        await sb.from("policy_notice_sent").insert({
          influencer_id: id, notice_key: noticeKey, status: "skipped", skip_reason: "no_email",
        }); // 충돌(이미 처리)은 무시
        skipped++;
        continue;
      }
      // 멱등 선점: status='sent' INSERT 성공해야 발송 (충돌이면 already_sent)
      const { error: claimErr } = await sb.from("policy_notice_sent").insert({
        influencer_id: id, notice_key: noticeKey, status: "sent",
      });
      if (claimErr) {
        if ((claimErr as { code?: string }).code === "23505") { skipped++; continue; } // already_sent
        console.error("[notify-policy-change] claim failed", id, claimErr.message);
        failed++;
        continue;
      }
      try {
        await sendBrevoEmail({
          to: [{ email, name: undefined }],
          subject: mail.subject, htmlContent: mail.html, textContent: mail.text,
        });
        sent++;
      } catch (e) {
        // 발송 실패 → 선점한 sent 행을 failed 로 정정
        await sb.from("policy_notice_sent")
          .update({ status: "failed" })
          .eq("influencer_id", id).eq("notice_key", noticeKey);
        failed++;
        console.error("[notify-policy-change] send failed", email, (e as Error).message);
      }
    }

    // ── 5. chained or finalize ──
    if (hasMore) {
      // 중간 배치: 누적 카운트는 각 배치가 자기 몫만 더함. finished_at 은 마지막 배치만.
      // ⚠️ 카운트 UPDATE 를 먼저 완료한 뒤 chained 호출 — chained 배치가 현재 배치보다
      //    먼저 실행돼 read-modify-write 가 경합하는 것을 방지.
      const { data: cur } = await sb.from("policy_notice_runs")
        .select("sent_count, skipped_count, failed_count").eq("notice_key", noticeKey).maybeSingle();
      const c = (cur || {}) as { sent_count?: number; skipped_count?: number; failed_count?: number };
      await finalizeRun({
        status: "partial",
        targetCount: isFirstBatch ? total : undefined,
        sentCount: (c.sent_count || 0) + sent,
        skippedCount: (c.skipped_count || 0) + skipped,
        failedCount: (c.failed_count || 0) + failed,
      });
      selfInvokeChained({ supaUrl, serviceKey, noticeKey, effectiveDate, nextOffset: batchOffset + BATCH_SIZE });
    } else {
      const { data: cur } = await sb.from("policy_notice_runs")
        .select("sent_count, skipped_count, failed_count").eq("notice_key", noticeKey).maybeSingle();
      const c = (cur || {}) as { sent_count?: number; skipped_count?: number; failed_count?: number };
      const totalSent = (c.sent_count || 0) + sent;
      const totalSkipped = (c.skipped_count || 0) + skipped;
      const totalFailed = (c.failed_count || 0) + failed;
      await finalizeRun({
        status: totalFailed > 0 ? "partial" : "sent",
        targetCount: isFirstBatch ? total : undefined,
        sentCount: totalSent, skippedCount: totalSkipped, failedCount: totalFailed,
        finishedAt: new Date().toISOString(),
      });
    }

    return new Response(JSON.stringify({
      ok: true, noticeKey, batchOffset, batchSize: batchIds.length, sent, skipped, failed, hasMore,
    }), { status: 200, headers: { "content-type": "application/json" } });

  } catch (e) {
    if (isFirstBatch) {
      await finalizeRun({
        status: "failed", targetCount: 0, sentCount: 0, skippedCount: 0, failedCount: 0,
        errorMessage: (e as Error).message, finishedAt: new Date().toISOString(),
      });
    }
    return new Response(JSON.stringify({ error: (e as Error).message, stage: "main" }), {
      status: 500, headers: { "content-type": "application/json" },
    });
  }
});
