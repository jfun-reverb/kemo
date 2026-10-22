// ════════════════════════════════════════════════════════════════════
// 캠페인 「브랜드 공개」 설정 — 진행현황 결과물 카드 단추 + 머리 줄 상태 표시
//   작업표 docs/specs/2026-10-19-brand-campaign-results-breakdown.md 「조각 9」 · 사양서 「리포트 공유 링크 … ③」(Figma 1차 a05-01)
//   서버: 544 admin_get/set_campaign_brand_publish · 열 판정: report-rows.js(조각 13)
//
//   · 열 목록 = reportColumnsFor(그 캠페인의 결과물 줄 + 요구 채널) — 리포트 화면과 같은 함수
//   · 처음 켤 때 체크 = reportDefaultCheckedKeys(열, 서버가 고른 기본 열) · 그 뒤 = !reportShareColOff(열쇠, 저장값)
//   · 저장값 = reportPublishColsToSave(체크, 지금 저장값) — S19(지금 없는 채널 열은 꺼진 채)
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
        <button type="button" class="btn btn-ghost" onclick="closeBrandPublishModal()">취소</button>
        <button type="button" class="btn btn-primary" id="brandPublishSaveBtn" onclick="saveBrandPublishModal()">저장</button>
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
  _bpCtx = { campaignId: campaignId, data: data, cols: cols, campTitle: camp.title || '' };
  const canEdit = (typeof canWrite === 'function') && canWrite('report.share');
  // 처음 켤 때(아직 한 번도 켠 적 없음) = 기본 열 · 그 뒤 = 저장한 열
  const firstTime = !data.first_enabled_at && !Array.isArray(data.columns);
  const checked = firstTime
    ? reportDefaultCheckedKeys(cols, data.default_spec)
    : cols.filter(function (c) { return !reportShareColOff(c.key, data.columns); }).map(function (c) { return c.key; });
  const order = [], byGrp = {};
  cols.forEach(function (c) { const g = c.grp || '기본'; if (!byGrp[g]) { byGrp[g] = []; order.push(g); } byGrp[g].push(c); });
  const srcLabel = data.default_source === 'brand' ? '이 브랜드의 기본 열' : '전체 기본 열';
  // 기본 열이 없거나(아직 안 정함) 빈 목록이면 체크가 하나도 없다 — 안내를 띄운다(개발서버 실측: 처음 값이 [])
  const noDefault = firstTime && !(Array.isArray(data.default_spec) && data.default_spec.length);
  body.innerHTML = `
    <label style="display:flex;align-items:center;gap:10px;padding:12px 14px;border:1px solid var(--line);border-radius:12px;cursor:${canEdit ? 'pointer' : 'default'}">
      <input type="checkbox" id="brandPublishEnabled" ${data.enabled ? 'checked' : ''} ${canEdit ? '' : 'disabled'} style="width:18px;height:18px">
      <span style="font-weight:700;font-size:14px">브랜드 페이지에 결과물 공개</span>
      <span style="margin-left:auto;font-size:12px;color:var(--muted)">켜면 이 캠페인 브랜드의 계정이 바로 봅니다</span>
    </label>
    <div style="margin:16px 0 6px;display:flex;align-items:baseline;gap:8px">
      <strong style="font-size:13px">브랜드에게 보일 열</strong>
      <span style="font-size:12px;color:var(--muted)">${firstTime ? '처음 켤 때는 ' + esc(srcLabel) + '이 미리 체크됩니다' : '저장한 열'}</span>
    </div>
    ${noDefault ? '<div style="margin:0 0 8px;padding:8px 10px;border-radius:8px;background:#FEF3C7;color:#92400E;font-size:12px">기본 열이 아직 정해지지 않아 체크된 열이 없습니다. 보일 열을 직접 골라 주세요.</div>' : ''}
    ${order.map(function (g, gi) {
      const sep = gi === 0 ? 'margin-top:4px' : 'margin-top:10px;padding-top:10px;border-top:1px solid var(--line)';
      return `<div style="${sep}"><div style="font-size:11px;font-weight:600;color:var(--muted);margin-bottom:3px">${esc(g)}</div>
        <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:4px 10px;font-size:12px">
          ${byGrp[g].map(function (c) {
            if (c.key === 'account_id') return `<label style="display:flex;align-items:center;gap:6px;color:var(--muted)" title="로그인 이메일이라 브랜드에게 보이지 않습니다"><input type="checkbox" disabled> ${esc(c.pick || c.label)} (고를 수 없음)</label>`;
            return `<label style="display:flex;align-items:center;gap:6px"><input type="checkbox" class="brandPublishCol" value="${esc(c.key)}" ${checked.indexOf(c.key) !== -1 ? 'checked' : ''} ${canEdit ? '' : 'disabled'}> ${esc(c.pick || c.label)}</label>`;
          }).join('')}
        </div></div>`;
    }).join('')}
    <p style="margin:14px 0 0;font-size:11.5px;color:var(--muted);line-height:1.6">지금 이 캠페인에 없는 채널 열은 나중에 생겨도 꺼진 채로 시작합니다. 계정 ID 는 늘 보이지 않습니다.${canEdit ? '' : '<br>변경 권한이 없어 볼 수만 있습니다.'}</p>`;
  if (saveBtn) { saveBtn.disabled = !canEdit; saveBtn.style.display = canEdit ? '' : 'none'; }
}

async function saveBrandPublishModal() {
  const ctx = _bpCtx;
  if (!ctx) return;
  const enabledEl = document.getElementById('brandPublishEnabled');
  const enabled = !!(enabledEl && enabledEl.checked);
  const checked = [...document.querySelectorAll('.brandPublishCol')].filter(function (i) { return i.checked; }).map(function (i) { return i.value; });
  const wasOn = !!ctx.data.enabled;
  if (enabled && !wasOn) {
    if (!checked.length && !window.confirm('보일 열을 하나도 고르지 않았습니다. 이대로 켜면 브랜드에게 결과물 표가 비어 보입니다. 계속할까요?')) return;
    if (!window.confirm('브랜드 공개를 켭니다.\n저장하는 순간 이 캠페인 브랜드의 계정이 브랜드 페이지에서 결과물을 바로 봅니다. 계속할까요?')) return;
  } else if (!enabled && wasOn) {
    if (!window.confirm('브랜드 공개를 끕니다.\n브랜드 페이지의 이 캠페인 결과물이 「준비 중」으로 바뀝니다. 계속할까요?')) return;
  }
  const cols = reportPublishColsToSave(checked, Array.isArray(ctx.data.columns) ? ctx.data.columns : null);
  const btn = document.getElementById('brandPublishSaveBtn');
  if (btn) btn.disabled = true;
  try {
    const v = await saveCampaignBrandPublish(ctx.campaignId, enabled, cols, ctx.data.version || 0);
    if (v === -1) {
      toast('다른 관리자가 먼저 바꿨습니다. 창을 다시 열어 확인해 주세요.', 'warning');
      closeBrandPublishModal();
    } else {
      toast(enabled ? '브랜드 공개를 저장했습니다' : '브랜드 공개를 껐습니다');
      closeBrandPublishModal();
    }
    _campListPublishStates = undefined;   // 캠페인 목록 배지·필터가 다음 그리기에서 새로 받게
    await refreshPane('camp-applicants');
  } catch (e) {
    toast('저장하지 못했습니다 — ' + ((e && e.message) || e), 'error');
    if (btn) btn.disabled = false;
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
function brandPublishDefaultPickerHtml(prefix, spec, editable) {
  const on = Array.isArray(spec) ? spec : [];
  const groups = [], byGrp = {};
  REPORT_COLS.forEach(function (c) {
    if (c.key === 'account_id') return;
    const g = c.grp || '기본';
    if (!byGrp[g]) { byGrp[g] = []; groups.push(g); }
    byGrp[g].push({ key: c.key, label: c.pick || c.label });
  });
  const others = REPORT_CHANNELS.filter(function (ch) { return !ch.always; }).map(function (ch) { return ch.label; }).concat(['기타']).join('·');
  const gOther = '그 밖의 채널 (' + others + ')';
  groups.push(gOther);
  byGrp[gOther] = REPORT_KIND_KEYS.map(function (k) { return { key: k, label: BP_KIND_LABEL[k] || k }; });
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
    + '<p style="margin:0 0 12px;font-size:12.5px;color:var(--muted);line-height:1.6">캠페인에서 「브랜드 공개」를 <strong>처음 켤 때</strong> 미리 체크되는 열입니다. 브랜드별로 따로 정하지 않은 브랜드는 이 값을 따릅니다.<br>바꿔도 <strong>이미 공개를 켠 캠페인은 바뀌지 않습니다</strong>(캠페인마다 저장한 열을 씁니다). 계정 ID(로그인 이메일)는 고를 수 없습니다.</p>'
    + brandPublishDefaultPickerHtml('bpGlobal', d.global_spec, editable)
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
