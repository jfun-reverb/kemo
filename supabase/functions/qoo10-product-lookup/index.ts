// qoo10-product-lookup — 큐텐 상품 페이지 읽기 (오리엔시트 단순화 3단계)
//
// 작성 폼(dev/sales/orient.html — sales 도메인 브라우저)이 **직접 부르는** 함수다 → 교차 출처 허용 헤더 + OPTIONS 필수
//   (notify-orient-sheet 전례 — 헤더 없으면 한 번도 성공하지 못한다).
//
// 관문 3종 — 🔴 셋이 한 세트다. 하나라도 빼면 공개 키만으로 누구나 Supabase 를 시켜 큐텐을 읽게 된다.
//   ① 살아 있는 작성 토큰만 — 200 의 orient_token_can_upload 판정(만료·소비·미매칭 false)
//   ② qoo10.jp 계열 호스트 + 상품 번호(/g/{n} · /item/{이름}/{n} · goodscode={n})가 뽑힐 때만
//   ③ 토큰당 분당 5회
//   ①③ 은 데이터베이스 함수 public.orient_lookup_gate(token)(428) 이 한 번에 판정한다(서비스 키로 호출, service_role 전용).
//   🔴 ③ 을 함수 인스턴스 메모리(Map)로 만들면 안 된다 — 요청마다 인스턴스가 갈려 개발서버 실측(2026-09-08)에서
//      6회 연속 호출이 전부 통과했다. 계수는 반드시 데이터베이스에서.
//
// 입력  {token, url}               → 출력 {ok:true, goods_code, product_name, store_name, price_sale_jpy, price_list_jpy, price_event_jpy, image_url, brand_name}
// 실패  전부 {ok:false} (이유는 로그만 — 브랜드 폼에는 「자동으로 못 불러왔어요」 한 줄만 간다. 실패 사유를 응답에 담지 않는다)
//
// 2026-09-08 작업 21 읽기 검증 통과(상품 3개, 개발 Edge Function). 큐텐 이용약관 위험은 사용자가 감수하기로 결정(선-2, 2026-09-08).
//
// 가격이 세 겹이다 — 参考価格(정가) · 販売価格(판매가, DOM `#dl_sell_price [data-price]`) · メガ割時(행사가, JSON-LD offers.price).
// 🔴 offers.price 는 행사가라 상시가로 쓰면 틀린다 — 판매가(DOM)를 price_sale_jpy 로, 정가를 price_list_jpy 로 돌려준다(확정 ⓚ).

const CHROME_HEADERS: Record<string, string> = {
  "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
  "accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
  "accept-language": "ja,en-US;q=0.9,en;q=0.8",
  "accept-encoding": "gzip, deflate, br",
  "upgrade-insecure-requests": "1",
  "sec-fetch-dest": "document", "sec-fetch-mode": "navigate", "sec-fetch-site": "none", "sec-fetch-user": "?1",
  "sec-ch-ua": '"Chromium";v="128", "Not;A=Brand";v="24", "Google Chrome";v="128"',
  "sec-ch-ua-mobile": "?0", "sec-ch-ua-platform": '"macOS"',
  "cache-control": "max-age=0",
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, "content-type": "application/json" } });
}

// 큐텐 상품 번호 — /g/{n} · /item/{이름}/{n} · goodscode={n}
function goodsCodeOf(raw: string): string | null {
  let u: URL;
  try { u = new URL(raw); } catch { return null; }
  if (!/(^|\.)qoo10\.jp$/i.test(u.hostname)) return null;
  const m = u.pathname.match(/\/(?:g|item\/[^/]+)\/(\d{6,12})(?:$|[/?#])/i) || u.search.match(/[?&]goodscode=(\d{6,12})/i);
  return m ? m[1] : null;
}

function toNum(s: string | null | undefined): number | null {
  if (!s) return null;
  const n = Number(String(s).replace(/[^0-9.]/g, ""));
  return Number.isFinite(n) && n > 0 ? n : null;
}

function parseProduct(html: string) {
  let name: string | null = null, sku: string | null = null, brand: string | null = null, image: string | null = null, offer: number | null = null;
  for (const m of html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)) {
    try {
      const j = JSON.parse(m[1].trim());
      for (const o of (Array.isArray(j) ? j : [j])) {
        const ty = o && o["@type"];
        if (ty === "Product" || (Array.isArray(ty) && ty.includes("Product"))) {
          name = o.name ?? name; sku = o.sku != null ? String(o.sku) : sku;
          brand = (o.brand && (o.brand.name || (typeof o.brand === "string" ? o.brand : null))) ?? brand;
          image = (Array.isArray(o.image) ? o.image[0] : o.image) ?? image;
          const of = Array.isArray(o.offers) ? o.offers[0] : o.offers;
          offer = toNum(of && of.price) ?? offer;
        }
      }
    } catch { /* 다음 블록 */ }
  }
  const sell = html.match(/id=["']dl_sell_price["'][\s\S]{0,600}?data-price=["']([\d,.]+)["']/i);
  const ref = html.match(/参考価格[\s\S]{0,400}?([\d,]{3,})/);
  const store = html.match(/<a[^>]+class=["'][^"']*\bname\b[^"']*["'][^>]*>([^<]{1,80})<\/a>/);
  return {
    product_name: name, goods_code: sku, brand_name: brand, image_url: image,
    price_sale_jpy: toNum(sell && sell[1]), price_list_jpy: toNum(ref && ref[1]), price_event_jpy: offer,
    store_name: store ? store[1].trim() : null,
  };
}

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// ①③ 살아 있는 토큰 + 분당 5회 — 데이터베이스 관문(428). 토큰 형식이 아니면 왕복 없이 거부
async function passGate(token: string): Promise<boolean> {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) return false;
  const url = Deno.env.get("SUPABASE_URL"); const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !key) return false;
  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("orient_lookup_gate", { p_token: token });
  if (error) { console.error("[qoo10-lookup] gate failed", error.message); return false; }
  return data === true;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false }, 405);
  let url = "", token = "";
  try { ({ url, token } = await req.json()); } catch { return json({ ok: false }); }
  token = String(token || "").trim();
  if (!token) return json({ ok: false });
  // ② 호스트·상품 번호를 먼저 본다(데이터베이스 왕복 없이 거를 수 있는 것부터)
  const code = goodsCodeOf(String(url || ""));
  if (!code) { console.log("[qoo10-lookup] not a qoo10 goods url"); return json({ ok: false }); }
  if (!(await passGate(token))) { console.log("[qoo10-lookup] gate rejected (dead token or rate limited)"); return json({ ok: false }); }
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 8000);
    const r = await fetch(`https://www.qoo10.jp/g/${code}`, { headers: CHROME_HEADERS, redirect: "follow", signal: ctrl.signal });
    clearTimeout(timer);
    const html = await r.text();
    console.log("[qoo10-lookup]", code, "status", r.status, "len", html.length);
    if (r.status !== 200 || html.length < 3000) return json({ ok: false });   // 1,209바이트짜리 차단 안내 페이지 포함
    const p = parseProduct(html);
    if (!p.product_name && !p.goods_code) return json({ ok: false });
    return json({ ok: true, ...p, goods_code: p.goods_code || code });
  } catch (e) {
    console.error("[qoo10-lookup] fetch failed", String(e));
    return json({ ok: false });
  }
});
