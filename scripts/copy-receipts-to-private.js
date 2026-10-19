// ════════════════════════════════════════════════════════════════════
// 영수증 파일을 공개 통 → 비공개 통으로 복사한다 (출시 날 ⑥ · 작업표 2026-10-19 「조각 8」)
//
// 무엇을 하나
//   kind='receipt'(영수증 + 방문형 현장 사진) 줄이 **가리키는 파일만** campaign-images 에서
//   deliverable-media 의 **같은 경로**로 복사한다(원본 + `thumb/` 사본). 폴더째 복사하지 않는다(D1 —
//   같은 receipts/ 폴더에 회원 리뷰 인증샷도 섞여 있다).
//   🔴 이 도구는 **복사만** 한다. 영수증 칸을 경로로 바꾸는 것은 다음 단계 SQL
//      (supabase/patches/2026-10-19-receipt-url-to-private-path.sql)이고, 그 SQL 은
//      **복사된 파일이 있는 줄만** 바꾼다 — 이 도구가 실패한 파일의 줄은 공개 주소로 남는다.
//
// 어떻게 쓰나
//   1. 관리자 화면(`/admin/`)에 **관리자로 로그인한 채로** 연다(복사 권한이 로그인 세션에서 나온다 — 548 넣기 정책)
//   2. 개발자 도구 콘솔에 이 파일 내용을 통째로 붙여넣는다
//   3. 끝에 「복사 N · 이미 있음 M · 함께 쓰는 파일 K · 썸네일 없음 T · 실패 목록」을 찍는다.
//      **실패가 있으면 그대로 다시 돌리면 된다**(이미 복사한 것은 「이미 있음」 — 몇 번 돌려도 결과가 같다)
//
// ⚠️ 개발서버·운영서버에서 **각각** 돌린다. 저장소는 서버마다 따로다.
// ⚠️ 복사본의 올린 사람(owner)은 **이 도구를 돌린 관리자**가 된다 — 회원이 자기 영수증을 보려면
//    다음 단계 SQL 이 owner 를 그 회원으로 고친다(548 조회 정책의 올린 사람 대조).
// 🔴 원본은 건드리지 않는다. 공개 통의 옛 파일을 지우는 것은 조각 20(대조를 통과한 뒤)이다.
// 「함께 쓰는 파일」 = 같은 파일을 리뷰 인증샷 줄도 가리킴. 복사·변환은 하되 **공개 사본은 남겨야 한다**
//    (그 인증샷 줄이 계속 공개 주소로 연다) — 조각 20 이 이 목록을 지우지 않는다. 그 영수증은 공개 주소로도 계속 열린다.
// ════════════════════════════════════════════════════════════════════
(async function copyReceiptsToPrivate() {
  const SRC = 'campaign-images';
  const DST = 'deliverable-media';
  const MARKER = '/storage/v1/object/public/' + SRC + '/';

  if (typeof db === 'undefined' || !db?.storage) { console.error('로그인한 관리자 화면에서 돌려 주세요 (db 없음)'); return; }

  // 1) 영수증 줄 전부(1,000행 상한 — 페이지로 끝까지)
  async function fetchAll(kind) {
    const out = [];
    for (let from = 0; ; from += 1000) {
      const { data, error } = await db.from('deliverables').select('id, receipt_url').eq('kind', kind)
        .not('receipt_url', 'is', null).order('id').range(from, from + 999);
      if (error) throw error;
      out.push(...(data || []));
      if (!data || data.length < 1000) break;
    }
    return out;
  }
  const receipts = await fetchAll('receipt');
  const reviews = await fetchAll('review_image');
  const toPath = (u) => { const i = String(u || '').indexOf(MARKER); return i === -1 ? null : String(u).slice(i + MARKER.length); };
  const reviewPaths = new Set(reviews.map(r => toPath(r.receipt_url)).filter(Boolean));

  const paths = Array.from(new Set(receipts.map(r => toPath(r.receipt_url)).filter(Boolean)));
  const skippedOther = receipts.filter(r => String(r.receipt_url).indexOf('://') !== -1 && !toPath(r.receipt_url)).length;
  const alreadyPath = receipts.filter(r => String(r.receipt_url).indexOf('://') === -1).length;
  console.log(`[영수증 복사] 대상 파일 ${paths.length}개 (영수증 줄 ${receipts.length} · 이미 경로 ${alreadyPath} · 다른 주소라 건너뜀 ${skippedOther})`);

  const thumbOf = (p) => { const s = p.indexOf('/'); if (s === -1) return null; const rest = p.slice(s + 1); return rest.startsWith('thumb/') ? null : p.slice(0, s) + '/thumb/' + rest; };
  // 상태 번호가 있으면 번호로, 없으면 문구로만 판정(파일 이름에 409·404 가 섞여도 오판하지 않게)
  const code = (e) => Number(e && (e.statusCode || e.status)) || 0;
  const isExists = (e) => code(e) === 409 || (!code(e) && /already exists|Duplicate/i.test(String((e && (e.message || e.error)) || '')));
  const isMissing = (e) => code(e) === 404 || (!code(e) && /not found/i.test(String((e && (e.message || e.error)) || '')));

  const t = { copied: 0, existed: 0, shared: 0, thumbCopied: 0, thumbExisted: 0, thumbMissing: 0, failed: [] };
  for (let i = 0; i < paths.length; i++) {
    const p = paths[i];
    const { error } = await db.storage.from(SRC).copy(p, p, { destinationBucket: DST });
    if (!error) t.copied++;
    else if (isExists(error)) t.existed++;
    else { t.failed.push({ path: p, error: error.message || String(error) }); continue; }
    if (reviewPaths.has(p)) t.shared++;   // 복사(또는 이미 있음)된 것만 센다
    const tp = thumbOf(p);
    if (tp) {
      const { error: te } = await db.storage.from(SRC).copy(tp, tp, { destinationBucket: DST });
      if (!te) t.thumbCopied++;
      else if (isExists(te)) t.thumbExisted++;
      else if (isMissing(te)) t.thumbMissing++;   // 썸네일 없는 옛 파일 — 화면은 원본으로 대신 연다
      else t.failed.push({ path: tp, error: te.message || String(te) });
    }
    if ((i + 1) % 50 === 0) console.log(`[영수증 복사] ${i + 1}/${paths.length}`);
  }
  console.log(`[영수증 복사] 끝 — 복사 ${t.copied} · 이미 있음 ${t.existed} · 함께 쓰는 파일 ${t.shared} · 썸네일 복사 ${t.thumbCopied}/이미 ${t.thumbExisted}/없음 ${t.thumbMissing} · 실패 ${t.failed.length}`);
  if (t.failed.length) console.table(t.failed);
  if (t.shared) console.warn(`🔴 함께 쓰는 파일 ${t.shared}개 — 리뷰 인증샷 줄도 가리킨다. 공개 사본을 지우지 말 것(조각 20). 목록:`, paths.filter(p => reviewPaths.has(p)));
  return t;
})();
