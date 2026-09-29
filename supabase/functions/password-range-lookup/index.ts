// password-range-lookup — 유출 비밀번호 목록(Have I Been Pwned · Pwned Passwords) 범위 조회 대행
//
// 사양서: docs/specs/2026-09-29-common-password-warning.md §3-1
// 브라우저(인플루언서 앱·관리자 앱·admin-setpw.html)가 공개 키로 **직접 부르는** 함수 → 교차 출처 허용 헤더 + OPTIONS 필수
//   (qoo10-product-lookup 과 같은 규칙).
//
// 입력  {prefix}  — SHA-1 해시 16진수 **정확히 5글자**(대소문자 무관). 그 밖은 외부 요청 없이 바로 {ok:false}
// 출력  {ok:true, lines:"접미사35글자:횟수\r\n…"}  /  실패는 전부 {ok:false}
//
// 🔴 받은 5글자를 로그에 남기지 않는다 — 5글자만으로는 비밀번호를 특정할 수 없지만 남길 이유도 없다.
// 🔴 비밀번호 원문·전체 해시는 이 함수에 오지 않는다. 대조는 브라우저가 한다(판정: dev/js/ui.js · dev/admin-setpw.html).
// ⚠️ Add-Padding: true — 응답 길이로 후보 수를 추측하지 못하게 외부 서비스가 횟수 0 짜리 가짜 줄을 섞는다.
//    판정 쪽은 횟수 0 줄을 「흔한 비밀번호」로 치지 않는다.
// ⚠️ 요청 수 제한은 두지 않는다(사양서 §5). 외부 서비스는 무료·공개라 우리 비용은 함수 호출 수뿐.
// ⚠️ 이 함수가 없거나 실패하면 화면은 'unknown' → 검사 없이 통과한다(막지 않는다). 그래서 배포 순서는 **함수 먼저, 화면 나중**.

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false }, 405);
  let prefix = "";
  try { ({ prefix } = await req.json()); } catch { return json({ ok: false }); }
  prefix = String(prefix || "").trim().toUpperCase();
  if (!/^[0-9A-F]{5}$/.test(prefix)) return json({ ok: false });
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 2500);
    const r = await fetch(`https://api.pwnedpasswords.com/range/${prefix}`, {
      headers: { "Add-Padding": "true", "user-agent": "reverb-jp-password-check" },
      signal: ctrl.signal,
    });
    clearTimeout(timer);
    if (r.status !== 200) { console.log("[pw-range] upstream status", r.status); return json({ ok: false }); }
    const lines = await r.text();
    return json({ ok: true, lines });
  } catch (e) {
    console.error("[pw-range] fetch failed", String(e && (e as Error).name || e));
    return json({ ok: false });
  }
});
