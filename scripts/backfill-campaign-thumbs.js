// ════════════════════════════════════════════════════════════════════
// 기존 캠페인 사진의 720px 썸네일을 뒤늦게 만들어 준다 (일회성)
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
//   1. 관리자 화면(`/admin/`)에 **관리자로 로그인한 채로** 연다
//      (저장소 쓰기 권한이 로그인 세션에서 나온다 — 서비스 키가 필요 없다)
//   2. 개발자 도구 콘솔에 이 파일 내용을 통째로 붙여넣는다
//   3. 끝나면 처리·건너뜀·실패 건수를 찍는다. **실패가 있으면 그대로 다시 돌리면 된다**
//      (이미 만든 것은 건너뛴다 — 몇 번을 돌려도 결과가 같다)
//
// ⚠️ 개발서버·운영서버에서 **각각** 돌려야 한다. 저장소는 서버마다 따로다.
// ⚠️ 원본은 건드리지 않는다. 만드는 것은 `campaigns/thumb/` 아래 사본뿐이다.
// ⚠️ 읽기는 공개 주소로 하고(무료), 유료 변환 주소(`/render/image/`)는 쓰지 않는다.
// ════════════════════════════════════════════════════════════════════
(async function backfillCampaignThumbs() {
  const BUCKET = 'campaign-images';
  const SRC = 'campaigns';
  const THUMB = 'campaigns/thumb';

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

  console.log('[썸네일 채우기] 목록을 읽는 중…');
  const originals = await listAll(SRC);
  const existing = new Set((await listAll(THUMB)).map(f => f.name));
  const todo = originals.filter(f => !existing.has(f.name));

  console.log(`[썸네일 채우기] 원본 ${originals.length}장 · 이미 있음 ${existing.size}장 · 만들 것 ${todo.length}장`);
  if (!todo.length) { console.log('[썸네일 채우기] 할 일이 없습니다.'); return; }

  let done = 0, failed = 0;
  const failures = [];
  for (let i = 0; i < todo.length; i++) {
    const name = todo[i].name;
    try {
      const { data: pub } = db.storage.from(BUCKET).getPublicUrl(`${SRC}/${name}`);
      const res = await fetch(pub.publicUrl, { cache: 'no-store' });
      if (!res.ok) throw new Error('원본을 받지 못함 ' + res.status);
      const blob = await res.blob();
      const mime = blob.type || 'image/jpeg';
      // keepIfSmall — 720 보다 좁으면 다시 그리지 않는다(투명한 PNG 배경이 검게 되는 함정)
      const small = await compressImageFile(new File([blob], 'camp-thumb', { type: mime }), { maxWidth: 720, keepIfSmall: true });
      const { error } = await db.storage.from(BUCKET).upload(`${THUMB}/${name}`, small, {
        contentType: small.type || mime, upsert: true, cacheControl: '86400'
      });
      if (error) throw error;
      done++;
    } catch (e) {
      failed++;
      failures.push({ name, reason: String(e && e.message || e) });
    }
    if ((i + 1) % 20 === 0 || i === todo.length - 1) {
      console.log(`[썸네일 채우기] ${i + 1}/${todo.length} — 성공 ${done} · 실패 ${failed}`);
    }
  }

  console.log(`[썸네일 채우기] 끝. 성공 ${done} · 실패 ${failed}`);
  if (failures.length) {
    console.warn('[썸네일 채우기] 실패 목록 — 다시 돌리면 이것만 재시도합니다', failures);
  }
  return { total: originals.length, created: done, failed, failures };
})();
