// ════════════════════════════════════════════════════════════════════
// 이미 저장된 이미지의 썸네일을 뒤늦게 만들어 준다 (일회성)
//
// 왜 필요한가
//   앞으로 올라오는 사진은 `uploadImage`(dev/lib/storage.js)가 올릴 때 두 벌 저장한다.
//   그런데 **이미 저장된 사진에는 썸네일이 없다.** 화면(`campThumbUrl`)이 썸네일 주소를
//   먼저 요청하므로, 없으면 404 를 한 번 받고 `onerror` 로 원본을 다시 받는다 —
//   🔴 요청이 두 번이고 **원본을 통째로 받는다**(실측 평균 399KB · 최대 5MB).
//   유료 변환을 쓰던 때보다 오히려 느려지므로, **표시를 바꾸기 전에 이 스크립트를 먼저
//   돌려야 한다.**
//
// 어떻게 쓰나
//   0. 폴더별 목표 폭은 아래 FOLDERS 표에 있다. 화면 쪽 `THUMB_FOLDERS`(ui.js)·저장 쪽
//      `THUMB_WIDTH_BY_PREFIX`(storage.js)와 **같은 집합**이어야 한다.
//   1. 관리자 화면(`/admin/`)에 **관리자로 로그인한 채로** 연다
//      (저장소 쓰기 권한이 로그인 세션에서 나온다 — 서비스 키가 필요 없다)
//   2. 개발자 도구 콘솔에 이 파일 내용을 통째로 붙여넣는다
//   3. 끝나면 처리·건너뜀·실패 건수를 찍는다. **실패가 있으면 그대로 다시 돌리면 된다**
//      (이미 만든 것은 건너뛴다 — 몇 번을 돌려도 결과가 같다)
//
// ⚠️ 개발서버·운영서버에서 **각각** 돌려야 한다. 저장소는 서버마다 따로다.
// 🔴 **원본은 절대 건드리지 않는다.** 영수증은 관리자가 「영수증에서 읽기」로 글자를 기계가
//    읽는데, 원본을 압축하면 자리를 잃는다(2026-09-01 실측: 주문번호 마지막 한 자리 누락).
//    만드는 것은 `{폴더}/thumb/` 아래 사본뿐이다.
// ⚠️ 영수증·인증샷은 **개인정보**다. 사본이 늘어나므로, 파기하는 자리 넷이 썸네일도 함께
//    지우도록 고쳐진 뒤에 돌릴 것(`_withThumbPaths` · purge-withdrawal-media).
// ⚠️ 읽기는 공개 주소로 하고(무료), 유료 변환 주소(`/render/image/`)는 쓰지 않는다.
// ════════════════════════════════════════════════════════════════════
(async function backfillCampaignThumbs() {
  const BUCKET = 'campaign-images';
  // 폴더 → 썸네일 가로 폭
  const FOLDERS = { 'campaigns': 720, 'receipts': 480, 'review-images': 480, 'content': 720 };
  // ⚠️ 아웃바운드 명단 이미지(`outbound-influencer-images` 통)는 **여기 없다** — 저장된 사진이
  //    0건이라 소급할 것이 없다. 새로 올라오는 것은 uploadOutboundImage 가 두 벌로 저장한다.
  //    나중에 그 통에 옛 사진이 생기면 이 스크립트에 통 인자를 더해야 한다.

  if (typeof db === 'undefined' || !db?.storage) { console.error('로그인한 관리자 화면에서 돌려 주세요 (db 없음)'); return; }
  if (typeof compressImageFile !== 'function') { console.error('compressImageFile 이 없습니다 — 관리자 화면에서 돌려 주세요'); return; }

  // 폴더 하나를 끝까지 훑는다 — list() 는 한 번에 다 주지 않는다
  async function listAll(prefix) {
    const out = [];
    for (let offset = 0; ; offset += 100) {
      const { data, error } = await db.storage.from(BUCKET).list(prefix, { limit: 100, offset });
      if (error) throw error;
      if (!data || !data.length) break;
      // ⚠️ 하위 폴더(`thumb`)는 id 가 없는 항목으로 섞여 온다 — 파일만 남긴다
      out.push(...data.filter(f => f && f.id));
      if (data.length < 100) break;
    }
    return out;
  }

  const totals = { done: 0, failed: 0, failures: [] };

  for (const [folder, maxWidth] of Object.entries(FOLDERS)) {
    const THUMB = folder + '/thumb';
    console.log(`[썸네일 채우기] ${folder} — 목록을 읽는 중…`);
    const originals = await listAll(folder);
    const existing = new Set((await listAll(THUMB)).map(f => f.name));
    const todo = originals.filter(f => !existing.has(f.name));
    console.log(`[썸네일 채우기] ${folder} — 원본 ${originals.length}장 · 이미 있음 ${existing.size}장 · 만들 것 ${todo.length}장 (가로 ${maxWidth})`);
    if (!todo.length) continue;

    for (let i = 0; i < todo.length; i++) {
      const name = todo[i].name;
      try {
        const { data: pub } = db.storage.from(BUCKET).getPublicUrl(`${folder}/${name}`);
        const res = await fetch(pub.publicUrl, { cache: 'no-store' });
        if (!res.ok) throw new Error('원본을 받지 못함 ' + res.status);
        const blob = await res.blob();
        const mime = blob.type || 'image/jpeg';
        // keepIfSmall — 목표 폭보다 좁으면 다시 그리지 않는다(투명 PNG 배경이 검게 되는 함정)
        const small = await compressImageFile(new File([blob], 'thumb-src', { type: mime }), { maxWidth, keepIfSmall: true });
        const { error } = await db.storage.from(BUCKET).upload(`${THUMB}/${name}`, small, {
          contentType: small.type || mime, upsert: true, cacheControl: '86400'
        });
        if (error) throw error;
        totals.done++;
      } catch (e) {
        totals.failed++;
        totals.failures.push({ folder, name, reason: String(e && e.message || e) });
      }
      if ((i + 1) % 50 === 0 || i === todo.length - 1) {
        console.log(`[썸네일 채우기] ${folder} ${i + 1}/${todo.length} — 누적 성공 ${totals.done} · 실패 ${totals.failed}`);
      }
    }
  }

  const done = totals.done, failed = totals.failed, failures = totals.failures;
  console.log(`[썸네일 채우기] 끝. 성공 ${done} · 실패 ${failed}`);
  if (failures.length) {
    console.warn('[썸네일 채우기] 실패 목록 — 다시 돌리면 이것만 재시도합니다', failures);
  }
  return { created: done, failed, failures };
})();
