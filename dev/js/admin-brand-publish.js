// ════════════════════════════════════════════════════════════════════
// 캠페인 「브랜드 공개」 설정 — 진행현황 결과물 카드 단추 + 머리 줄 상태 표시
//   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 9」 · 사양서 「리포트 공유 링크 … ③」(Figma 1차 a05-01)
//   서버: 544 admin_get/set_campaign_brand_publish · 열 판정: report-rows.js(조각 13)
//
//   · 열 목록 = reportColumnsFor(그 캠페인의 결과물 줄 + 요구 채널) — 리포트 화면과 같은 함수
//   · 처음 켤 때 체크 = reportDefaultCheckedKeys(열, 서버가 고른 기본 열) · 그 뒤 = !reportShareColOff(열쇠, 저장값)
//   · 저장값 = reportPublishColsToSave(체크, 지금 저장값) — S19(지금 없는 채널 열은 꺼진 채)
//   · 스위치 = 누르는 즉시 켜기·끄기 저장 / 열 = 「열 저장」 따로(Figma a05-01 · 2026-10-22) — 서버는 559 그대로
//   · 외부 줄에 값이 없는 열(ⓓ — reportIsExtEmptyKey) = 처음 켤 때 꺼짐, 외부 결과 파일이 붙은 캠페인이면 잠김(a05-01b)
//   · 「계정 ID」(로그인 이메일)는 고를 수 없다(늘 꺼짐)
//   · 권한 report.share — 숨김 등급(매니저)은 단추를 숨기고 상태 표시만 본다 · 읽기 등급은 창을 열되 저장 못 함
//   🔴 「비공개」 낱말을 쓰지 않는다(같은 화면에 초대 전용 행사의 「비공개」 배지가 있다 — 사양서)
//   ⚠️ 상태 표시 조회 실패(null)는 표시를 숨긴다 — 실패를 「꺼짐」으로 그리지 않는다
// ════════════════════════════════════════════════════════════════════

var _bpCtx = null;   // {campaignId, data, cols, campTitle}

// 목록 배지 — 캠페인 관리 목록(캠페인명 아래)·관리자 브랜드 상세 캠페인 탭이 **같은 함수**를 쓴다(조각 10).
//   enabled 가 true/false 가 아니면(조회 실패·모름) 아무것도 안 그린다. 누르면 진행현황(onclickJs — 목록에서 바로 켜지 않는다)
//   🔴 「비공개」 낱말 금지 — 같은 목록에 초대 전용 행사의 「비공개」 배지가 있다
function brandPublishBadgeHtml(enabled, onclickJs) {
  if (enabled !== true && enabled !== false) return '';
  const style = 'display:inline-flex;align-items:center;gap:2px;font-size:10px;font-weight:600;padding:1px 7px;border-radius:999px;white-space:nowrap;'
    + (enabled ? 'background:#ECFDF5;color:#047857;border:1px solid #A7F3D0;' : 'background:#F4F4F5;color:#71717A;border:1px solid var(--line);')
    + (onclickJs ? 'cursor:pointer;' : '');
  return '<span style="' + style + '"' + (onclickJs ? ' onclick="event.stopPropagation();' + onclickJs + '" title="진행현황에서 설정"' : '') + '>'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:12px">' + (enabled ? 'visibility' : 'visibility_off') + '</span>'
    + (enabled ? '브랜드 공개 중' : '브랜드 공개 꺼짐') + '</span>';
}

// 「열람 정지」 배지(이용 제한 12) — 브랜드 결과물 열람 정지 중이면 공개 배지 옆에. 브랜드 단위 값이라 그 브랜드 캠페인 전부에 붙는다.
//   suspended 가 true 일 때만 그린다 — 조회 실패(null)·모름은 「정지 아님」으로 단정하지 않고 아무것도 안 그린다(보조 표시)
//   size 'head' = 진행현황 머리 줄 크기
function brandSuspendBadgeHtml(suspended, size) {
  if (suspended !== true) return '';
  const head = size === 'head';
  const style = 'display:inline-flex;align-items:center;gap:' + (head ? '3px' : '2px') + ';font-weight:600;border-radius:999px;white-space:nowrap;'
    + (head ? 'font-size:12px;padding:3px 10px;' : 'font-size:10px;padding:1px 7px;')
    + 'background:#FDECEC;color:#B42318;border:1px solid #F5C2C0;';
  return '<span style="' + style + '" title="이 브랜드의 결과물 열람이 정지되어 있습니다(브랜드 상세에서 해제)">'
    + '<span class="material-icons-round notranslate" translate="no" style="font-size:' + (head ? '14px' : '12px') + '">block</span>열람 정지</span>';
}

// 머리 줄 「열람 정지」 — 캠페인의 브랜드 정지 여부를 한 번 묻는다. 브랜드를 모르거나 조회 실패면 숨김
async function refreshCampBrandSuspendStatus(campaignId) {
  const el = document.getElementById('campBrandSuspendStatus');
  if (!el) return;
  el.innerHTML = '';
  if (!campaignId || typeof _brandAccountEnabled !== 'function' || !_brandAccountEnabled()) return;
  const camp = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns.find(c => c.id === campaignId) : null;
  const brandId = camp && camp.brand_id;
  if (!brandId) return;
  const map = await fetchBrandResultsSuspendedMap([brandId]);
  if (campaignId !== currentCampApplicantId) return;   // 그사이 다른 캠페인을 열었다
  if (!map) return;
  el.innerHTML = brandSuspendBadgeHtml(map[brandId] === true, 'head');
}

// 머리 줄 상태 표시 + 결과물 카드 단추 — loadCampApplicants 가 캠페인을 열 때마다 부른다
async function refreshCampBrandPublishStatus(campaignId) {
  const el = document.getElementById('campBrandPublishStatus');
  const btn = document.getElementById('btnCampBrandPublish');
  // 🔴 운영(브랜드 묶음 반영 전)에서는 단추·표시 모두 숨긴다 — 판정은 _brandAccountEnabled() 한 곳
  const live = (typeof _brandAccountEnabled === 'function') && _brandAccountEnabled();
  const hidden = !live || ((typeof isHidden === 'function') && isHidden('report.share'));
  if (btn) btn.style.display = hidden ? 'none' : '';
  refreshCampBrandSuspendStatus(campaignId);   // 공개 상태와 따로 — 권한 report.share 와 무관하게 보인다
  if (!el) return;
  el.style.display = 'none';
  if (!campaignId) return;
  const data = await fetchCampaignBrandPublish(campaignId);
  if (campaignId !== currentCampApplicantId) return;   // 그사이 다른 캠페인을 열었다
  if (!data) return;                                   // 실패 — 표시하지 않는다
  const on = !!data.enabled;
  el.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:-2px">'
    + (on ? 'visibility' : 'visibility_off') + '</span> ' + (on ? '브랜드 공개 중' : '브랜드 공개 꺼짐');
  el.style.cssText = 'display:inline-flex;align-items:center;gap:3px;font-size:12px;font-weight:600;padding:3px 10px;border-radius:999px;'
    + (on ? 'background:#ECFDF5;color:#047857;border:1px solid #A7F3D0;' : 'background:#F4F4F5;color:#52525B;border:1px solid var(--line);')
    + (hidden ? 'cursor:default;' : 'cursor:pointer;');
  el.title = hidden ? '' : '브랜드 공개 설정 열기';
  el.onclick = hidden ? null : function () { openBrandPublishModal(campaignId); };
}

function _bpEnsureModal() {
  if (document.getElementById('brandPublishModal')) return;
  const wrap = document.createElement('div');
  wrap.innerHTML = `
  <div class="modal-overlay" id="brandPublishModal">
    <div class="modal" style="max-width:640px;width:94vw;border-radius:16px;margin:auto;max-height:88vh;display:flex;flex-direction:column">
      <div class="modal-header"><h2>브랜드 공개 설정</h2>
        <button type="button" class="modal-close-btn" onclick="closeBrandPublishModal()"><span class="material-icons-round notranslate" translate="no">close</span></button></div>
      <div class="modal-body" id="brandPublishBody" style="padding:20px;overflow-y:auto;flex:1"></div>
      <div class="modal-footer" style="padding:14px 20px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end">
        <button type="button" class="btn btn-ghost" onclick="closeBrandPublishModal()">닫기</button>
        <button type="button" class="btn btn-primary" id="brandPublishSaveBtn" onclick="saveBrandPublishColumns()">열 저장</button>
      </div>
    </div>
  </div>`;
  document.body.appendChild(wrap.firstElementChild);
}
function closeBrandPublishModal() {
  const m = document.getElementById('brandPublishModal');
  if (m) m.classList.remove('open');
  _bpCtx = null;
}

// 열 목록 — 그 캠페인의 결과물 줄(리포트와 같은 조회·같은 표 만들기) + 요구 채널 한 줄(아직 아무도 안 낸 채널 열도 고를 수 있게)
async function _bpColumnsFor(camp) {
  const delivs = await fetchDeliverablesForReport([camp.id]);
  if (delivs === null) return null;
  const uids = [...new Set(delivs.map(function (d) { return d.user_id; }).filter(Boolean))];
  const users = uids.length ? await fetchInfluencersForReport(uids) : {};
  if (users === null) return null;
  const rows = buildReportRows(delivs, [{ id: camp.id, campaign_no: camp.campaign_no, title: camp.title, _exists: true,
    channel: camp.channel, channel_match: camp.channel_match, recruit_type: camp.recruit_type }], users);
  return reportColumnsFor(rows.concat([{ _channels: _reportCampChannels(camp) }]));
}

// 외부 결과 파일이 붙은 캠페인인가(사양서 16-5 15번 ④ ⓓ-3) — 판정은 서버, 조회 응답의 칸을 읽기만 한다.
//   🔴 칸이 없거나(서버가 아직 옛 판) 값이 true/false 가 아니면 「붙었다」로 본다 — 모르는 채 켤 수 있게 그리지 않는다
function _bpExtLocked(data) { return !(data && data.ext_locked === false); }

// 저장할 체크 목록 — 잠긴 열(ⓓ)은 화면 체크가 아니라 **지금 저장값**을 그대로 쓴다(화면에 안 나온 채널 열 포함).
//   잠기지 않았으면 모달 체크 그대로(지금 이 캠페인에 없는 열은 reportPublishColsToSave 가 꺼진 채로 적는다 — S19)
function _bpCheckedForSave(ctx) {
  const boxes = [...document.querySelectorAll('.brandPublishCol')];
  if (!ctx.locked) return boxes.filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
  const out = boxes.filter(function (i) { return i.checked && !reportIsExtEmptyKey(i.value); }).map(function (i) { return i.value; });
  const prev = Array.isArray(ctx.data.columns) ? ctx.data.columns : null;
  if (prev) reportAllPublishKeys().forEach(function (k) {
    if (reportIsExtEmptyKey(k) && !reportShareColOff(k, prev) && out.indexOf(k) === -1) out.push(k);
  });
  return out;
}
function _bpCheckedNow() {
  return [...document.querySelectorAll('.brandPublishCol')].filter(function (i) { return i.checked; }).map(function (i) { return i.value; }).sort();
}

// 상태 줄·스위치·「아직 저장 안 함」 안내를 지금 값으로 다시 그린다
function _bpSyncUi() {
  const ctx = _bpCtx;
  if (!ctx) return;
  const on = !!ctx.data.enabled;
  const sw = document.getElementById('brandPublishToggle');
  if (sw) {
    sw.classList.toggle('is-on', on);
    sw.setAttribute('aria-checked', on ? 'true' : 'false');
    sw.disabled = !ctx.canEdit || !!ctx.busy;
    sw.classList.toggle('is-disabled', !ctx.canEdit || !!ctx.busy);
  }
  const line = document.getElementById('brandPublishStateLine');
  if (line) line.textContent = on ? '지금 브랜드 페이지에 보이는 중' : '지금 브랜드 페이지에 보이지 않습니다';
  const dirty = JSON.stringify(_bpCheckedNow()) !== JSON.stringify(ctx.baseline);
  const note = document.getElementById('brandPublishDirtyNote');
  if (note) note.style.display = (ctx.canEdit && dirty) ? '' : 'none';
  const saveBtn = document.getElementById('brandPublishSaveBtn');
  if (saveBtn) saveBtn.disabled = !ctx.canEdit || !!ctx.busy;
}

async function openBrandPublishModal(campaignId) {
  if (!((typeof _brandAccountEnabled === 'function') && _brandAccountEnabled())) return;
  if ((typeof isHidden === 'function') && isHidden('report.share')) return;
  _bpCtx = null;   // ESC(전역 처리기)로 닫혀 남은 이전 값을 지운다
  _bpEnsureModal();
  const body = document.getElementById('brandPublishBody');
  const saveBtn = document.getElementById('brandPublishSaveBtn');
  body.innerHTML = '<div style="text-align:center;padding:40px"><span class="spinner"></span></div>';
  if (saveBtn) saveBtn.disabled = true;
  openModal('brandPublishModal');

  let camp = (typeof allCampaigns !== 'undefined' && Array.isArray(allCampaigns)) ? allCampaigns.find(function (c) { return c.id === campaignId; }) : null;
  if (!camp) { try { camp = (await fetchCampaigns()).find(function (c) { return c.id === campaignId; }); } catch (_) { camp = null; } }
  const [data, cols] = await Promise.all([fetchCampaignBrandPublish(campaignId), camp ? _bpColumnsFor(camp) : Promise.resolve(null)]);
  if (!camp || !data || !cols) {
    body.innerHTML = '<div style="text-align:center;padding:32px;color:var(--muted);font-size:13px">설정을 불러오지 못했습니다. 잠시 뒤 다시 열어 주세요.</div>';
    return;
  }
  const canEdit = (typeof canWrite === 'function') && canWrite('report.share');
  const locked = _bpExtLocked(data);
  // 처음 켤 때(아직 한 번도 켠 적 없음) = 기본 열(ⓓ 열은 빠진다) · 그 뒤 = 저장한 열
  const firstTime = !data.first_enabled_at && !Array.isArray(data.columns);
  const checked = firstTime
    ? reportDefaultCheckedKeys(cols, data.default_spec)
    : cols.filter(function (c) { return !reportShareColOff(c.key, data.columns); }).map(function (c) { return c.key; });
  const order = [], byGrp = {};
  cols.forEach(function (c) { const g = c.grp || '기본'; if (!byGrp[g]) { byGrp[g] = []; order.push(g); } byGrp[g].push(c); });
  const srcLabel = data.default_source === 'brand' ? '이 브랜드의 기본 열' : '전체 기본 열';
  // 기본 열이 없거나(아직 안 정함) 빈 목록이면 체크가 하나도 없다 — 안내를 띄운다(개발서버 실측: 처음 값이 [])
  const noDefault = firstTime && !(Array.isArray(data.default_spec) && data.default_spec.length);
  const brandName = String(camp.brand || '').trim();
  const lockTip = '외부 결과 파일이 붙은 캠페인이라 켤 수 없습니다';
  body.innerHTML = `
    <div style="display:flex;align-items:center;gap:16px;padding:14px 16px;border:1px solid var(--line);border-radius:12px;background:var(--surface-dim)">
      <div style="flex:1;min-width:0">
        <div style="font-weight:700;font-size:14px">브랜드 페이지에 결과물 보이기</div>
        <div style="margin-top:4px;font-size:12px;color:var(--muted);line-height:1.6">켜면 ${brandName ? esc(brandName) + ' 브랜드 페이지의' : '이 캠페인 브랜드 페이지의'} 이 캠페인 상세 「결과물」에 아래에서 고른 열이 보입니다. 캠페인을 만들면 처음에는 꺼져 있습니다.</div>
      </div>
      <button type="button" id="brandPublishToggle" class="visibility-toggle" role="switch" aria-checked="false" aria-label="브랜드 페이지에 결과물 보이기" onclick="toggleBrandPublishEnabled()"><span class="visibility-toggle-knob"></span></button>
    </div>
    <div id="brandPublishStateLine" style="margin:12px 0 0;font-size:12px;color:var(--muted)"></div>
    <div style="margin:16px 0 6px;display:flex;align-items:baseline;gap:8px">
      <strong style="font-size:13px">브랜드에게 보여줄 열</strong>
      <span style="font-size:12px;color:var(--muted)">${firstTime ? '처음 켤 때는 ' + esc(srcLabel) + '이 미리 체크됩니다' : '저장한 열'}</span>
    </div>
    ${noDefault ? '<div style="margin:0 0 8px;padding:8px 10px;border-radius:8px;background:#FEF3C7;color:#92400E;font-size:12px">기본 열이 아직 정해지지 않아 체크된 열이 없습니다. 보일 열을 직접 골라 주세요.</div>' : ''}
    ${order.map(function (g, gi) {
      const sep = gi === 0 ? 'margin-top:4px' : 'margin-top:10px;padding-top:10px;border-top:1px solid var(--line)';
      return `<div style="${sep}"><div style="font-size:11px;font-weight:600;color:var(--muted);margin-bottom:3px">${esc(g)}</div>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:4px 10px;font-size:12px">
          ${byGrp[g].map(function (c) {
            if (c.key === 'account_id') return `<label style="display:flex;align-items:center;gap:6px;color:var(--muted)" title="로그인 이메일이라 브랜드에게 보이지 않습니다"><input type="checkbox" disabled> ${esc(c.pick || c.label)} (고를 수 없음)</label>`;
            const isOn = checked.indexOf(c.key) !== -1;
            if (locked && reportIsExtEmptyKey(c.key)) {
              return `<label style="display:flex;align-items:center;gap:6px;color:var(--muted);cursor:not-allowed" title="${esc(lockTip)}"><input type="checkbox" class="brandPublishCol" value="${esc(c.key)}" ${isOn ? 'checked' : ''} disabled><span class="material-icons-round notranslate" translate="no" style="font-size:13px">lock</span>${esc(c.pick || c.label)}</label>`;
            }
            return `<label style="display:flex;align-items:center;gap:6px"><input type="checkbox" class="brandPublishCol" value="${esc(c.key)}" ${isOn ? 'checked' : ''} ${canEdit ? '' : 'disabled'} onchange="_bpSyncUi()"> ${esc(c.pick || c.label)}</label>`;
          }).join('')}
        </div></div>`;
    }).join('')}
    <div id="brandPublishDirtyNote" style="display:none;margin:12px 0 0;padding:8px 10px;border-radius:8px;background:#FEF3C7;color:#92400E;font-size:12px">바꾼 열은 아직 저장되지 않았습니다 — 「열 저장」을 눌러 주세요</div>
    ${locked
      ? '<p style="margin:14px 0 0;font-size:11.5px;color:var(--red);line-height:1.6">외부 결과 파일이 붙은 캠페인이라 켤 수 없습니다 — 이름·후리가나·구매기간·구매일·채널 계정·SNS 결과물(잠긴 열). 파일을 모두 삭제하면 저장된 설정대로 다시 보입니다. 계정 ID(로그인 이메일)는 어떤 설정이어도 보내지 않습니다.</p>'
      : '<p style="margin:14px 0 0;font-size:11.5px;color:var(--muted);line-height:1.6">계정 ID(로그인 이메일)는 어떤 설정이어도 보내지 않습니다. 이름·후리가나·구매기간·구매일·SNS 계정·SNS 결과물은 처음에 꺼져 있고, 외부 결과 파일이 붙은 캠페인에서는 켤 수 없습니다. 값이 하나도 없는 열은 켜져 있어도 브랜드 화면에 나오지 않습니다.</p>'}
    ${canEdit ? '' : '<p style="margin:8px 0 0;font-size:11.5px;color:var(--muted)">변경 권한이 없어 볼 수만 있습니다.</p>'}`;
  _bpCtx = { campaignId: campaignId, data: data, cols: cols, campTitle: camp.title || '', canEdit: canEdit, locked: locked, busy: false, baseline: null };
  _bpCtx.baseline = _bpCheckedNow();
  if (saveBtn) saveBtn.style.display = canEdit ? '' : 'none';
  _bpSyncUi();
}

// 저장 뒤 목록 배지·진행현황 머리 줄을 새로 그린다
async function _bpAfterSave() {
  _campListPublishStates = undefined;   // 캠페인 목록 배지·필터가 다음 그리기에서 새로 받게
  await refreshPane('camp-applicants');
}

// 스위치 — 누르는 즉시 켜기·끄기를 저장한다(열은 따로 「열 저장」). 켤 때만 확인 창(2026-10-22 결정 2 A).
//   켤 때 보내는 열 = 저장된 열(결정 3 A — 모달에서 바꾸고 저장 안 한 체크는 싣지 않는다).
//   한 번도 열을 저장한 적 없으면 지금 체크된 열(서버가 열 없이 켜기를 거부한다 — 559).
//   실패하면 스위치를 원래대로 되돌린다.
async function toggleBrandPublishEnabled() {
  const ctx = _bpCtx;
  if (!ctx || ctx.busy || !ctx.canEdit) return;
  const next = !ctx.data.enabled;
  let cols = null;
  if (next) {
    const hasSaved = Array.isArray(ctx.data.columns);
    cols = hasSaved ? ctx.data.columns : reportPublishColsToSave(_bpCheckedForSave(ctx), null);
    const anyOn = reportAllPublishKeys().some(function (k) { return !reportShareColOff(k, cols); });   // 저장된 열이 [] 인 경우도 잡는다
    if (!anyOn && !window.confirm('보일 열을 하나도 고르지 않았습니다. 이대로 켜면 브랜드에게 결과물 표가 비어 보입니다. 계속할까요?')) return;
    if (!window.confirm('브랜드 공개를 켭니다.\n이 캠페인 브랜드의 계정이 브랜드 페이지에서 결과물을 바로 봅니다. 계속할까요?')) return;
  }
  ctx.busy = true;
  ctx.data.enabled = next;   // 스위치를 먼저 옮겨 그린다 — 실패하면 아래에서 되돌린다
  _bpSyncUi();
  try {
    const v = await saveCampaignBrandPublish(ctx.campaignId, next, cols, ctx.data.version || 0);
    if (_bpCtx !== ctx) {   // 그사이 창이 닫혔다 — 결과만 알린다
      if (v === -1) toast('다른 관리자가 먼저 바꿨습니다. 창을 다시 열어 확인해 주세요.', 'warning');
      else toast(next ? '브랜드 페이지에 결과물을 공개했습니다.' : '브랜드 페이지에서 결과물을 내렸습니다.');
      await _bpAfterSave();
      return;
    }
    if (v === -1) {
      ctx.data.enabled = !next;
      ctx.busy = false;
      _bpSyncUi();
      toast('다른 관리자가 먼저 바꿨습니다. 창을 다시 열어 확인해 주세요.', 'warning');
      closeBrandPublishModal();
      await _bpAfterSave();
      return;
    }
    ctx.data.version = v;
    if (next) {
      if (!Array.isArray(ctx.data.columns)) { ctx.data.columns = cols; ctx.baseline = _bpCheckedNow(); }
      if (!ctx.data.first_enabled_at) ctx.data.first_enabled_at = new Date().toISOString();
    }
    ctx.busy = false;
    _bpSyncUi();
    toast(next ? '브랜드 페이지에 결과물을 공개했습니다.' : '브랜드 페이지에서 결과물을 내렸습니다.');
    await _bpAfterSave();
  } catch (e) {
    console.error('[toggleBrandPublishEnabled]', e);
    ctx.data.enabled = !next;
    ctx.busy = false;
    _bpSyncUi();
    toast('저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error');
  }
}

// 「열 저장」 — 켜짐·꺼짐은 그대로 두고 열만 저장한다(꺼진 상태에서 미리 골라 두기 가능 — 559 는 꺼진 채 열 저장을 기록하지 않는다)
async function saveBrandPublishColumns() {
  const ctx = _bpCtx;
  if (!ctx || ctx.busy || !ctx.canEdit) return;
  const checked = _bpCheckedForSave(ctx);
  if (ctx.data.enabled && !checked.length && !window.confirm('보일 열을 하나도 고르지 않았습니다. 브랜드에게 결과물 표가 비어 보입니다. 계속할까요?')) return;
  const cols = reportPublishColsToSave(checked, Array.isArray(ctx.data.columns) ? ctx.data.columns : null);
  ctx.busy = true;
  _bpSyncUi();
  try {
    const v = await saveCampaignBrandPublish(ctx.campaignId, !!ctx.data.enabled, cols, ctx.data.version || 0);
    if (v === -1) toast('다른 관리자가 먼저 바꿨습니다. 창을 다시 열어 확인해 주세요.', 'warning');
    else toast('보일 열을 저장했습니다.');
    closeBrandPublishModal();
    await _bpAfterSave();
  } catch (e) {
    console.error('[saveBrandPublishColumns]', e);
    toast('저장하지 못했습니다. 잠시 후 다시 시도해 주십시오.', 'error');
    if (_bpCtx === ctx) { ctx.busy = false; _bpSyncUi(); }
  }
}

// ════════════════════════════════════════════════════════════════════
// 브랜드 공개 기본 열(조각 11) — 기준 데이터 「브랜드 공개 기본 열」 탭(전체) · 관리자 브랜드 상세 칸(이 브랜드만)
//   값 형식은 report-rows.js 「브랜드 공개 기본 열」 주석 — 늘 있는 열은 열쇠 그대로, 생기고 빠지는 채널 열은 종류 열쇠(REPORT_KIND_KEYS)
//   🔴 권한 report.share 쓰기가 아니면 **읽기 전용**(숨김 등급도 읽기 전용 — 사양서 §4 ③ · 16-4 의 의도된 예외, 조각 9 의 단추 숨김과 다르다)
//   🔴 옛 페이지(운영)는 자기 저장 단추·자기 함수로만 저장한다 — saveBrandDetail(폼 통째 저장)에 넣지 않는다.
//      새 상세 페이지(개발서버 — 조각 7)는 embedded 로 그려 단추 없이 「브랜드 정보」 탭 「저장」(575 admin_update_brand_info)이 함께 저장한다
//   ⚠️ 바꿔도 이미 공개를 켠 캠페인은 안 바뀐다(캠페인마다 저장한 열을 쓴다)
// ════════════════════════════════════════════════════════════════════
const BP_KIND_LABEL = { 'ch_*_acct': '계정 (인스타그램·틱톡·X·유튜브)', 'ch_*_url': '결과물 (URL)', 'ch_*_at': '업로드 날짜' };
//   🔴 외부 줄에 값이 없는 열(ⓓ — reportIsExtEmptyKey)은 목록에 없다(사양서 16-5 15번 ④ ⓓ-1 · Figma a05-05·a03-00d).
//      그래서 「그 밖의 채널」 묶음(종류 열쇠 셋)은 지금 통째로 빠진다 — 종류 열쇠가 ⓓ 가 아니게 바뀌면 다시 나온다
function brandPublishDefaultPickerHtml(prefix, spec, editable) {
  const on = Array.isArray(spec) ? spec : [];
  const groups = [], byGrp = {};
  REPORT_COLS.forEach(function (c) {
    if (c.key === 'account_id' || reportIsExtEmptyKey(c.key)) return;
    const g = c.grp || '기본';
    if (!byGrp[g]) { byGrp[g] = []; groups.push(g); }
    byGrp[g].push({ key: c.key, label: c.pick || c.label });
  });
  const others = REPORT_CHANNELS.filter(function (ch) { return !ch.always; }).map(function (ch) { return ch.label; }).concat(['기타']).join('·');
  const gOther = '그 밖의 채널 (' + others + ')';
  const kindItems = REPORT_KIND_KEYS.filter(function (k) { return !reportIsExtEmptyKey(k); }).map(function (k) { return { key: k, label: BP_KIND_LABEL[k] || k }; });
  if (kindItems.length) { groups.push(gOther); byGrp[gOther] = kindItems; }
  return groups.map(function (g, gi) {
    const sep = gi === 0 ? '' : 'margin-top:10px;padding-top:10px;border-top:1px solid var(--line)';
    return '<div style="' + sep + '"><div style="font-size:11px;font-weight:600;color:var(--muted);margin-bottom:3px">' + esc(g) + '</div>'
      + '<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:4px 10px;font-size:12px">'
      + byGrp[g].map(function (it) {
          return '<label style="display:flex;align-items:center;gap:6px"><input type="checkbox" class="' + esc(prefix) + 'Col" value="' + esc(it.key) + '"'
            + (on.indexOf(it.key) !== -1 ? ' checked' : '') + (editable ? '' : ' disabled') + '> ' + esc(it.label) + '</label>';
        }).join('')
      + '</div>'
      + (g === gOther ? '<div style="font-size:11px;color:var(--muted);margin-top:4px">캠페인에 그 채널이 있을 때 그 채널 열 모두에 적용됩니다. 「계정」은 회원이 등록한 SNS 계정 주소이고 로그인 이메일(계정 ID)과 다릅니다.</div>' : '')
      + '</div>';
  }).join('');
}
function brandPublishDefaultPickerValue(prefix) {
  return [...document.querySelectorAll('.' + prefix + 'Col')].filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
}
function _bpCanEditDefaults() { return (typeof canWrite === 'function') && canWrite('report.share'); }

// ── 기준 데이터 탭(전체 기본값) ──
async function renderBrandPublishDefaultTable() {
  const tbody = $('lookupsTableBody'); const thead = $('lookupTableHead'); const title = $('lookupTableTitle');
  const rb = $('btnLookupReorderMode'); if (rb) rb.style.display = 'none';
  if (title) title.textContent = '브랜드 공개 기본 열';
  if (thead) thead.innerHTML = '';
  const wrap = function (inner) { return '<tr><td colspan="7" style="padding:0">' + inner + '</td></tr>'; };
  tbody.innerHTML = wrap('<div style="text-align:center;padding:24px"><span class="spinner"></span></div>');
  const d = await fetchBrandPublishDefaults(null);
  if (!d) { tbody.innerHTML = wrap('<div style="text-align:center;color:var(--red);padding:24px">기본 열을 불러오지 못했습니다. 새로고침해 주세요.</div>'); return; }
  const editable = _bpCanEditDefaults();
  tbody.innerHTML = wrap('<div style="padding:18px 20px;max-width:760px">'
    + '<p style="margin:0 0 12px;font-size:12.5px;color:var(--muted);line-height:1.6">캠페인에서 「브랜드 공개」를 <strong>처음 켤 때</strong> 미리 체크되는 열입니다. 브랜드 상세에서 따로 정한 브랜드는 그 브랜드의 값을 씁니다.<br>바꿔도 <strong>이미 공개를 켠 캠페인은 바뀌지 않습니다</strong>(캠페인마다 저장한 열을 씁니다). 계정 ID(로그인 이메일)·이름·후리가나·구매기간·구매일·SNS 열은 기본 열로 정할 수 없습니다.</p>'
    + brandPublishDefaultPickerHtml('bpGlobal', d.global_spec, editable)
    + '<p style="margin:12px 0 0;font-size:12px;color:#B45309;line-height:1.6">구매 금액·주문번호·구매 영수증을 켜면 앞으로 공개를 켜는 모든 캠페인(따로 정한 브랜드 제외)에서 브랜드에게 보입니다.</p>'
    + '<div style="margin-top:14px;display:flex;gap:8px;align-items:center">'
      + (editable ? '<button type="button" class="btn btn-primary btn-sm" id="bpGlobalSaveBtn" onclick="saveBrandPublishDefaultGlobalFromTab()">저장</button>'
                  : '<span style="font-size:12px;color:var(--muted)">변경 권한이 없어 볼 수만 있습니다.</span>')
    + '</div></div>');
}
async function saveBrandPublishDefaultGlobalFromTab() {
  const btn = $('bpGlobalSaveBtn'); if (btn) btn.disabled = true;
  try {
    await saveBrandPublishDefaultGlobal(brandPublishDefaultPickerValue('bpGlobal'));
    toast('전체 기본 열을 저장했습니다');
    await renderBrandPublishDefaultTable();
  } catch (e) {
    toast('저장하지 못했습니다 — ' + ((e && e.message) || e), 'error');
    if (btn) btn.disabled = false;
  }
}

// ── 관리자 브랜드 상세 칸(이 브랜드만) — 본문을 그린 뒤 따로 받는다 ──
// opts.embedded — 새 상세 페이지: 자기 「기본 열 저장」 단추를 안 그리고, 받은 값을 opts.onLoaded(d|null) 로 돌려준다.
//   opts.data — 이미 받은 값으로 그린다(되돌리기·다시 불러오기 — 서버를 다시 부르지 않음)
async function renderBrandPublishDefaultBox(brandId, opts) {
  opts = opts || {};
  const box = document.getElementById('brandPublishDefaultBox');
  if (!box || !brandId) return;
  const d = opts.data !== undefined ? opts.data : await fetchBrandPublishDefaults(brandId);
  if (document.getElementById('brandPublishDefaultBox') !== box || _brandsCurrentId !== brandId) return;   // 그사이 다른 브랜드
  if (typeof opts.onLoaded === 'function') opts.onLoaded(d || null);
  if (!d) { box.innerHTML = '<div style="padding:12px;text-align:center;color:var(--muted);font-size:12px;background:var(--surface-dim);border-radius:6px">불러오지 못했습니다</div>'; return; }
  const editable = _bpCanEditDefaults();
  const own = Array.isArray(d.brand_spec);
  box.innerHTML = '<div style="display:flex;gap:16px;font-size:13px;margin-bottom:10px">'
      + '<label style="display:flex;align-items:center;gap:6px"><input type="radio" name="bpBrandMode" value="global"' + (own ? '' : ' checked') + (editable ? '' : ' disabled') + ' onchange="toggleBrandPublishDefaultMode()"> 전체 기본값 따르기</label>'
      + '<label style="display:flex;align-items:center;gap:6px"><input type="radio" name="bpBrandMode" value="own"' + (own ? ' checked' : '') + (editable ? '' : ' disabled') + ' onchange="toggleBrandPublishDefaultMode()"> 이 브랜드만 따로 정하기</label>'
    + '</div>'
    + '<div id="bpBrandPicker" style="' + (own ? '' : 'opacity:.55;pointer-events:none') + '">'
      + brandPublishDefaultPickerHtml('bpBrand', own ? d.brand_spec : d.global_spec, editable)
    + '</div>'
    + (opts.embedded
      ? '<div style="margin-top:10px;font-size:11.5px;color:var(--muted)">전체 기본값은 「기준 데이터」 → 「브랜드 공개 기본 열」에서 바꿉니다.' + (editable ? ' 이 칸도 아래 「저장」으로 함께 저장됩니다.' : '') + '</div>'
        + (editable ? '' : '<div style="margin-top:8px;font-size:12px;color:var(--muted)">변경 권한이 없어 볼 수만 있습니다.</div>')
      : '<div style="margin-top:10px;font-size:11.5px;color:var(--muted)">이 브랜드 캠페인에서 「브랜드 공개」를 처음 켤 때 미리 체크됩니다. 바꿔도 이미 공개를 켠 캠페인은 바뀌지 않습니다. 이 칸은 아래 「저장」으로만 저장됩니다(브랜드 정보 저장과 따로).</div>'
    + (editable ? '<div style="margin-top:10px"><button type="button" class="btn btn-ghost btn-sm" id="bpBrandSaveBtn" onclick="saveBrandPublishDefaultFromDetail(\'' + esc(brandId) + '\')">기본 열 저장</button></div>'
                : '<div style="margin-top:8px;font-size:12px;color:var(--muted)">변경 권한이 없어 볼 수만 있습니다.</div>'));
}
function toggleBrandPublishDefaultMode() {
  const own = (document.querySelector('input[name="bpBrandMode"]:checked') || {}).value === 'own';
  const p = document.getElementById('bpBrandPicker');
  if (p) p.style.cssText = own ? '' : 'opacity:.55;pointer-events:none';
}
// 이 칸의 지금 값 — 따로 정하기면 고른 열 배열, 전체 기본값 따르기면 null(575·544 형식)
function brandPublishDefaultBoxValue() {
  const own = (document.querySelector('input[name="bpBrandMode"]:checked') || {}).value === 'own';
  return own ? brandPublishDefaultPickerValue('bpBrand') : null;
}
async function saveBrandPublishDefaultFromDetail(brandId) {
  const own = (document.querySelector('input[name="bpBrandMode"]:checked') || {}).value === 'own';
  const btn = document.getElementById('bpBrandSaveBtn'); if (btn) btn.disabled = true;
  try {
    await saveBrandPublishDefaultBrand(brandId, own ? brandPublishDefaultPickerValue('bpBrand') : null);
    toast(own ? '이 브랜드의 기본 열을 저장했습니다' : '전체 기본값을 따르도록 저장했습니다');
    await renderBrandPublishDefaultBox(brandId);
  } catch (e) {
    toast('저장하지 못했습니다 — ' + ((e && e.message) || e), 'error');
    if (btn) btn.disabled = false;
  }
}
