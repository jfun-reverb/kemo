// ══════════════════════════════════════════════════════════════════
// Edge Function: brand-password-reset-request
// ──────────────────────────────────────────────────────────────────
// 트리거: 브랜드 로그인 화면(/brand/)의 「비밀번호를 잊으셨나요」 → 찾기 화면에서 비로그인 호출.
//          → 브라우저 직접 호출이라 CORS + OPTIONS 필수. 🔴 공개 키 거부는 걸지 않는다
//            (비로그인 브라우저가 공개 키로 부른다 — supabase.md).
//
// 복제 원본: admin-password-reset-request (최소 응답 2500밀리초·요청 제한 3층·항상 {ok:true}).
// 링크 조립·Brevo·두 겹 잠금 판정은 notify-brand-account-setup 과 같은 방식·같은 비밀값을 쓴다.
//
// 요청:  POST { email }
// 응답:  항상 200 { ok:true } — 본문·상태·소요 시간이 어떤 분기에서도 같다(security.md 「계정 열거 방지」).
//        형식 불량·요청 제한·없는 이메일·인플루언서·관리자·오류·개발서버 잠금 모두 동일.
//        「요청이 많습니다」 같은 별도 문구 금지 — 제한은 실재하는 이메일에서만 자주 걸려 그 문구가 신호가 된다.
//
// 분기 (모두 응답 {ok:true}, 최소 2500밀리초)
//   · 형식·길이 불량            → DB 안 탐, 무동작
//   · brand_accounts 에 없음    → 요청 제한 기록(matched=false) 후 무동작  (인플루언서·관리자·없는 주소 동일)
//   · 제한 걸림                  → 조용히 종료
//   · 있음 + service_issue_brand_account_link(auth_id,'auto'):
//       kind=reset  → 재설정 메일 (brand-password-reset 양식, 링크 …/brand/?link=<id>&mode=reset#confirm=…)
//       kind=setup  → 처음 받은 설정 메일 다시 (brand-account-setup 양식의 「다시 보냄」 문구 그대로,
//                      mode=setup) + service_mark_brand_setup_mail_sent
//       그 밖(no_active_brand 등) → 무동작
//
// 링크 번호(setup_link_id): 발급(service_issue_brand_account_link)이 앞서 보낸 링크를 모두 무효화한다.
//   재설정 메일은 발송 기록 칸이 없다(setup_mail_sent_* 는 설정 메일 전용).
//
// 🔴 개발서버 잠금 — 이 함수는 비로그인 공개 함수라 notify-brand-account-setup 처럼 응답에 링크(dev_link)를
//    실을 수 없다(싣는 순간 누구나 아무 브랜드 계정의 재설정 링크를 받아 계정을 탈취한다 — 개발서버여도).
//    그리고 로그에도 남기지 않는다(함수 로그 열람자가 링크를 본다). 그래서:
//      잠금 둘(BRAND_SETUP_DEV_ECHO==="1" 그리고 SUPABASE_URL 이 개발 프로젝트)이 켜지면
//      → 링크 번호 발급까지만 하고 **발송도·링크 생성(generateLink)도·노출도 하지 않는다.**
//      확인은 DB 로: brand_accounts.setup_link_id 가 바뀌었는지(관리자 콘솔 admin_get_brand_account_status
//      또는 SQL 편집기)로 「이 경로가 끝까지 돌았다」를 본다. 링크를 열어 봐야 하는 시험은 관리자 화면의
//      「다시 보내기」(dev_link, 관리자 토큰 필요)로 한다.
//    ⚠️ 이 분기를 "dev_link 를 응답/로그에 실어 편하게" 바꾸지 말 것. 잠금 둘 중 하나라도 지우면 개발서버에서
//       메일이 실제로 나가려다(Brevo 키 없음) 실패하는 것뿐이지만, 운영에서는 아래 잠금과 무관하다 —
//       운영에는 BRAND_SETUP_DEV_ECHO 를 넣지 않는다.
//
// 로그에는 이메일·토큰·링크를 남기지 않는다(분기 이름만).
//
// 환경변수: BREVO_API_KEY / PUBLIC_BRAND_URL(필수, 기본값 없음) / BRAND_SETUP_DEV_ECHO(개발만 "1") /
//           BREVO_SENDER_EMAIL / BREVO_SENDER_NAME / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY(자동 주입)
//
// 템플릿: templates.ts → TEMPLATES['brand-password-reset'], TEMPLATES['brand-account-setup']
//
// 배포 (개발 → 운영):
//   bash scripts/sync-email-templates.sh
//   supabase functions deploy brand-password-reset-request --use-api --project-ref qysmxtipobomefudyixw
//   (운영) supabase functions deploy brand-password-reset-request --use-api --project-ref nrwtujmlbktxjgdwlpjj
//   비밀값 PUBLIC_BRAND_URL·BRAND_SETUP_DEV_ECHO 는 notify-brand-account-setup 과 같은 것을 공유(프로젝트 단위)한다.
// ══════════════════════════════════════════════════════════════════

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { TEMPLATES } from "./templates.ts";

const BREVO_ENDPOINT = "https://api.brevo.com/v3/smtp/email";
const STAGING_PROJECT_REF = "qysmxtipobomefudyixw";

// 최소 응답 시간 — 하한만 강제, 상한은 두지 않는다(admin-password-reset-request 와 같은 이유).
const FIXED_RESPONSE_MS = 2500;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function env(key: string, fallback = ""): string {
  return Deno.env.get(key) ?? fallback;
}

function render(html: string, data: Record<string, string>): string {
  return html.replace(/\{\{(\w+)\}\}/g, (_m, key) => data[key] ?? "");
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// 🔴 두 겹 잠금 — 위 머리말 참고(notify-brand-account-setup 과 같은 판정).
function devEchoEnabled(): boolean {
  return env("BRAND_SETUP_DEV_ECHO") === "1"
    && env("SUPABASE_URL").includes(`://${STAGING_PROJECT_REF}.`);
}

async function sha256Hex(input: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function sendBrevoEmail(params: {
  to: { email: string; name?: string }[];
  subject: string;
  htmlContent: string;
  textContent: string;
}): Promise<void> {
  const apiKey = env("BREVO_API_KEY");
  if (!apiKey) throw new Error("BREVO_API_KEY not configured");
  const res = await fetch(BREVO_ENDPOINT, {
    method: "POST",
    headers: { "api-key": apiKey, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({
      sender: {
        email: env("BREVO_SENDER_EMAIL", "noreply@globalreverb.com"),
        name: env("BREVO_SENDER_NAME", "REVERB JP"),
      },
      to: params.to,
      subject: params.subject,
      htmlContent: params.htmlContent,
      textContent: params.textContent,
    }),
  });
  // 응답 본문에 수신 주소가 들어올 수 있어 상태 코드만 남긴다
  if (!res.ok) throw new Error(`Brevo send failed ${res.status}`);
}

// 실제 처리. 예외를 밖으로 던지지 않는다(호출자에게는 어떤 경우에도 동일한 응답).
async function process(rawEmail: unknown): Promise<void> {
  // 1) 정규화(저장값과 같은 lower(btrim)) + 형식·길이 검사 — 불량이면 DB 도 안 탄다
  const email = (typeof rawEmail === "string" ? rawEmail : "").trim().toLowerCase();
  if (!email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return;

  const supaUrl = env("SUPABASE_URL");
  const serviceKey = env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supaUrl || !serviceKey) {
    console.error("[brand-password-reset-request] service credentials not configured");
    return;
  }
  // 링크 도메인은 서버 설정만 믿는다(기본값을 두지 않는다)
  const brandBase = env("PUBLIC_BRAND_URL").replace(/\/$/, "");
  if (!/^https:\/\/[^/\s]+$/.test(brandBase)) {
    console.error("[brand-password-reset-request] PUBLIC_BRAND_URL not configured");
    return;
  }
  const sb = createClient(supaUrl, serviceKey, { auth: { persistSession: false } });

  // 2) 브랜드 계정 조회 (결과는 응답에 반영하지 않는다). brand_accounts.email 은 정규화 저장(CHECK)이라 eq.
  const { data: acct, error: acctErr } = await sb
    .from("brand_accounts")
    .select("auth_id, email, name")
    .eq("email", email)
    .maybeSingle();
  if (acctErr) {
    console.error("[brand-password-reset-request] account lookup failed", acctErr.message);
    return;
  }

  // 3) 요청 제한 판정 + 기록 — 매칭 여부와 무관하게 항상 호출(미매칭도 세야 난사로 메일 한도를 못 태운다)
  const emailHash = await sha256Hex(email);
  const { data: allowed, error: rlErr } = await sb.rpc("check_brand_password_reset_rate_limit", {
    p_email_hash: emailHash,
    p_matched: !!acct,
  });
  if (rlErr) {
    console.error("[brand-password-reset-request] rate limit rpc failed", rlErr.message);
    return;
  }
  if (allowed !== true) {
    console.log("[brand-password-reset-request] rate limited");
    return;
  }
  if (!acct) {
    console.log("[brand-password-reset-request] no brand account");
    return;
  }

  // 4) 새 링크 번호 발급 — 앞서 보낸 링크는 이 순간 모두 무효. 종류는 계정 상태로 서버가 정한다.
  const { data: issued, error: issueErr } = await sb.rpc("service_issue_brand_account_link", {
    p_auth_id: acct.auth_id,
    p_kind: "auto",
  });
  if (issueErr) {
    console.error("[brand-password-reset-request] issue failed", issueErr.message);
    return;
  }
  if (!issued?.ok) {
    console.log("[brand-password-reset-request] not issued", String(issued?.reason || "unknown"));
    return;
  }
  const kind = String(issued.kind);
  const linkId = String(issued.link_id);
  const toEmail = String(issued.email || acct.email);
  const contactName = String(issued.name || acct.name || "").trim() || "담당자";

  // 5) 개발서버 두 겹 잠금 — 링크 번호 발급까지만. 발송·링크 생성·노출 없음(머리말 참고).
  if (devEchoEnabled()) {
    console.log("[brand-password-reset-request] dev lock: issued only", { kind });
    return;
  }

  // 6) 링크 발급 (서버 발급 — 브라우저 검증값에 의존하지 않음)
  const mode = kind === "reset" ? "reset" : "setup";
  const landing = `${brandBase}/brand/?link=${linkId}&mode=${mode}`;
  const { data: genData, error: genErr } = await sb.auth.admin.generateLink({
    type: "recovery",
    email: toEmail,
    options: { redirectTo: landing },
  });
  const rawLink = genData?.properties?.action_link;
  if (genErr || !rawLink) {
    console.error("[brand-password-reset-request] generateLink failed", genErr?.message ?? "no action_link");
    return;
  }
  // ★메일에는 Supabase 검증 주소를 그대로 싣지 않는다 — 우리 페이지의 # 뒤에 담는다
  //   (메일 보안 검사기·클릭 추적 서버가 먼저 열어도 1회용 토큰이 소진되지 않게 — notify-admin-invite 와 같은 이유).
  const mailLink = `${landing}#confirm=${encodeURIComponent(rawLink)}`;
  const expiresNote = "이 링크는 보낸 때부터 1시간 동안 유효합니다.";

  let subject: string;
  let html: string;
  let text: string;

  if (kind === "reset") {
    const tpl = TEMPLATES["brand-password-reset"].replace(/<!--[\s\S]*?-->/g, "");
    html = render(tpl, {
      contact_name: escapeHtml(contactName),
      link: escapeHtml(mailLink),
      expires: escapeHtml(expiresNote),
    });
    subject = "[REVERB] 브랜드 페이지 비밀번호 재설정";
    text =
      `${contactName} 님\n\n` +
      `REVERB 브랜드 페이지의 비밀번호 재설정이 요청되었습니다.\n` +
      `아래 링크에서 새 비밀번호를 정해 주세요.\n\n` +
      `링크: ${mailLink}\n\n` +
      `${expiresNote} 기한이 지나면 링크가 열리지 않으니, 그때는 로그인 화면에서 「비밀번호를 잊으셨나요」를 다시 눌러 주세요. ` +
      `여러 번 요청하셨다면 가장 최근에 받은 링크만 사용할 수 있습니다.\n\n` +
      `본인이 요청하지 않으셨다면 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 비밀번호는 바뀌지 않습니다.\n`;
  } else {
    // 설정 전 계정 — 처음 받은 설정 메일을 다시 보낸다(notify-brand-account-setup 의 「다시 보냄」 문구와 같음).
    const { data: linkRows } = await sb
      .from("brand_account_links")
      .select("brand_id, role")
      .eq("auth_id", acct.auth_id)
      .eq("status", "active")
      .order("role", { ascending: true }) // 'member' < 'owner' 라 아래에서 owner 를 우선 고른다
      .limit(20);
    const rows = (linkRows ?? []) as { brand_id: string; role: string }[];
    const pick = rows.find((r) => r.role === "owner") ?? rows[0];
    let brandName = "브랜드";
    if (pick) {
      const { data: brandRow } = await sb.from("brands").select("name").eq("id", pick.brand_id).maybeSingle();
      brandName = String(brandRow?.name || "").trim() || "브랜드";
    }
    // ⚠️ 설정 메일 「다시 보냄」 제목·소개 문장은 supabase/functions/notify-brand-account-setup/index.ts 에도 같은 글자로 있다 — 고치면 두 곳을 함께 고친다
    const intro =
      `REVERB 운영팀이 ${brandName} 브랜드 계정의 비밀번호 설정 링크를 다시 보내 드립니다. 앞서 받으신 링크는 더 이상 쓸 수 없습니다.`;
    const tpl = TEMPLATES["brand-account-setup"].replace(/<!--[\s\S]*?-->/g, "");
    html = render(tpl, {
      brand_name: escapeHtml(brandName),
      contact_name: escapeHtml(contactName),
      link: escapeHtml(mailLink),
      intro: escapeHtml(intro),
      expires: escapeHtml(expiresNote),
    });
    subject = `[REVERB] ${brandName} 브랜드 계정 — 비밀번호 설정 링크를 다시 보내 드립니다`;
    text =
      `${contactName} 님\n\n` +
      `${intro}\n` +
      `아래 링크에서 사용하실 비밀번호를 설정해 주세요. 설정을 마치면 REVERB 브랜드 페이지에 로그인하실 수 있습니다.\n\n` +
      `링크: ${mailLink}\n\n` +
      `${expiresNote} 기한이 지나면 링크가 열리지 않으니, 그때는 REVERB 운영팀에 다시 보내 달라고 요청해 주세요.\n\n` +
      `본인이 요청하지 않았거나 무슨 메일인지 모르시겠다면, 이 메일을 무시하셔도 됩니다. 링크를 누르지 않으면 아무 일도 일어나지 않습니다.\n`;
  }

  // 7) 발송
  try {
    await sendBrevoEmail({ to: [{ email: toEmail, name: contactName }], subject, htmlContent: html, textContent: text });
  } catch (e) {
    console.error("[brand-password-reset-request] send failed", (e as Error).message);
    return;
  }
  console.log("[brand-password-reset-request] mail sent", { kind });

  // 8) 설정 메일 재발송만 발송 기록을 남긴다(재설정 메일은 기록 칸이 없다). 실패가 발송을 무효화하지 않는다.
  if (kind === "setup") {
    const { error: markErr } = await sb.rpc("service_mark_brand_setup_mail_sent", {
      p_auth_id: acct.auth_id,
      p_link_id: linkId,
      p_sent_to: toEmail,
    });
    if (markErr) console.error("[brand-password-reset-request] mark failed", markErr.message);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405, headers: CORS_HEADERS });

  const startedAt = Date.now();
  let email: unknown = "";
  try {
    const body = await req.json();
    email = body?.email;
  } catch (_) { /* 본문 파싱 실패도 동일 응답으로 수렴 */ }

  // 🔴 실제 처리(조회·링크 발급·메일 발송)는 응답과 떼어 **응답 뒤에** 끝낸다(EdgeRuntime.waitUntil).
  //   처리를 기다렸다 응답하면 브랜드 계정일 때만 링크 발급·발송 시간만큼 늦어져, 걸린 시간으로 계정 여부가
  //   드러났다(개발서버 실측 2026-10-14: 브랜드 계정 +0.3초, 운영은 발송까지 더해져 더 크다).
  //   응답은 이제 처리 시간과 무관하게 FIXED_RESPONSE_MS 에 나간다. waitUntil 이 없는 환경(로컬 등)은 예전처럼 기다린다.
  const work = process(email).catch((e) => {
    console.error("[brand-password-reset-request] error", (e as Error).message);
  });
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt && typeof rt.waitUntil === "function") {
    rt.waitUntil(work);
  } else {
    await work;
  }

  // ★고정 시각까지 대기 후 반환 — 분기별 소요 시간 차이를 흡수한다
  const elapsed = Date.now() - startedAt;
  if (elapsed < FIXED_RESPONSE_MS) await new Promise((r) => setTimeout(r, FIXED_RESPONSE_MS - elapsed));

  return new Response(JSON.stringify({ ok: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, "content-type": "application/json" },
  });
});
