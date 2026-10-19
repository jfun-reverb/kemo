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

// 머리 줄 상태 표시 + 결과물 카드 단추 — loadCampApplicants 가 캠페인을 열 때마다 부른다
async function refreshCampBrandPublishStatus(campaignId) {
  const el = document.getElementById('campBrandPublishStatus');
  const btn = document.getElementById('btnCampBrandPublish');
  // 🔴 운영(브랜드 묶음 반영 전)에서는 단추·표시 모두 숨긴다 — 판정은 _brandAccountEnabled() 한 곳
  const live = (typeof _brandAccountEnabled === 'function') && _brandAccountEnabled();
  const hidden = !live || ((typeof isHidden === 'function') && isHidden('report.share'));
  if (btn) btn.style.display = hidden ? 'none' : '';
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
    channel: camp.channel, channel_match: camp.channel_match, recruit_type: camp.recruit_type, proxy_purchase: camp.proxy_purchase }], users);
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
