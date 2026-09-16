// ════════════════════════════════════════════════════════════════════
// SECTION: AD-TRACKING — 관리자 「광고 추적」(메타 픽셀 설정) 페인
// ════════════════════════════════════════════════════════════════════
// 사양서 docs/specs/2026-09-03-meta-pixel.md 「관리 화면」
// 작업표 docs/specs/2026-09-15-meta-pixel-breakdown.md 「작업 4」
// 서버 마이그레이션 438(설정 표·함수) · 439(권한 시드)
//
// ⚠️ 이 파일은 dev/admin/index.html 에 <script> 태그를 넣지 않는다 — ADMIN_JS_FILES 한 곳에만 등록한다.
//    (관리자 태그 제거 정규식이 이 파일 이름에 안 걸려, 넣으면 죽은 태그가 산출물에 남는다)
// ⚠️ 로더 이름 loadAdTrackingPane 은 shared.js PANE_REFRESHERS['ad-tracking'] 와
//    admin-core.js switchAdminPane loaders 가 함께 부른다 — 한쪽만 바꾸면 오류 없이 빈 화면이 된다.
// 🔴 이 페인은 설정만 다룬다. 관리자 앱에 픽셀 전송 코드를 넣지 않는다(사양서 ⑥).
// 🔴 상태 배지는 서버가 준 status 그대로 그린다 — 화면이 시행일을 날짜 비교하지 않는다.
//    (화면 판정과 서버 판정이 갈리면 「켤 수 있어 보이는데 거부」가 생긴다)
// ════════════════════════════════════════════════════════════════════

let _adTrackingData = null;      // 마지막으로 받은 get_meta_pixel_admin 결과
let _adTrackingBusy = false;     // 저장 중 두 번 누르기 방지
let _adTrackingNotice = '';      // 저장 직후 안내 — 다시 그린 뒤에도 한 번 보여준다

// 저장 뒤 안내 — 사양서 ⑬(새 방문부터 적용 / 이미 열린 화면은 새로고침 전까지 옛 설정).
//   ⚠️ 셋을 같은 문장으로 두면 **껐을 때 「이전 설정으로 동작」이 무슨 뜻인지 알 수 없다**(2026-09-16 사용자 지적).
//      뜻은 같아도 **지금 한 동작 기준으로** 적는다 — 껐으면 「계속 보낼 수 있음」, 켰으면 「아직 안 보낼 수 있음」.
const AD_TRACKING_NOTICE = {
  on:     '새로 들어오는 방문부터 Meta 로 전송합니다. 이미 열려 있는 인플루언서 화면은 새로고침 전까지 아직 보내지 않을 수 있습니다.',
  off:    '새로 들어오는 방문부터 전송을 멈춥니다. 이미 열려 있는 인플루언서 화면은 새로고침 전까지 계속 보낼 수 있습니다.',
  id:     '새로 들어오는 방문부터 이 아이디로 전송합니다. 이미 열려 있는 인플루언서 화면은 새로고침 전까지 이전 아이디로 보낼 수 있습니다.',
  // 아이디를 **지운** 경우 — 직전까지 그 아이디로 보내던 탭이 남아 있을 수 있다
  idCleared: '아이디가 없어 전송하지 않습니다. 이미 열려 있는 인플루언서 화면은 새로고침 전까지 지운 아이디로 계속 보낼 수 있습니다.',
  // 아이디가 **처음부터 없는데** 켠 경우 — 아무 탭도 아이디를 받은 적이 없으니 「계속 보낸다」고 겁주지 않는다
  idMissing: '픽셀 아이디가 없어 아직 전송하지 않습니다. 아이디를 저장하면 그때부터 새 방문에 적용됩니다.',
};

// 서버 거부 사유 → 문구. ⚠️ 하나도 「알 수 없는 오류」로 뭉뚱그리지 않는다
const AD_TRACKING_ERROR_TEXT = {
  forbidden:            '변경 권한이 없습니다. 권한 관리에서 「광고 추적 켜기·끄기·픽셀 아이디 저장」이 쓰기인 관리자만 바꿀 수 있습니다.',
  invalid_pixel_id:     '픽셀 아이디는 숫자만 입력할 수 있습니다 (최대 32자리).',
  policy_not_in_effect: '개인정보처리방침 개정 시행일 전이라 켤 수 없습니다. 아이디 저장은 미리 해 둘 수 있습니다.',
  invalid_input:        '요청 값이 올바르지 않습니다. 화면을 새로고침한 뒤 다시 시도해 주세요.',
  request_failed:       '저장하지 못했습니다. 통신 상태를 확인하고 다시 시도해 주세요.',
};

// 날짜 문자열(YYYY-MM-DD)을 2026/09/15 모양으로 — new Date() 로 파싱하면 시간대가 끼어든다
function _adTrackingDateText(ymd) {
  return ymd ? String(ymd).slice(0, 10).replace(/-/g, '/') : '';
}

function _adTrackingStatusBadge(d) {
  switch (d.status) {
    case 'policy_locked': {
      const when = d.policy_effective_date ? _adTrackingDateText(d.policy_effective_date) : '미정';
      return `<span class="badge badge-gray">방침 시행 전 — 전송 안 됨 (시행일: ${esc(when)})</span>`;
    }
    case 'no_pixel_id': return '<span class="badge badge-gold">아이디 없음</span>';
    case 'disabled':    return '<span class="badge badge-gray">꺼짐</span>';
    case 'active':      return '<span class="badge badge-green">켜짐 — 전송 중</span>';
    default:            return `<span class="badge badge-gray">${esc(d.status || '알 수 없음')}</span>`;
  }
}

// 이력 한 줄의 「무엇을」 — 바뀐 칸마다 **무엇을 어떻게 했는지** 한 문장으로.
//   ⚠️ 「켬/끔」처럼 동작만 적으면 어느 아이디로 켰는지·무엇이 달라졌는지 알 수 없다(2026-09-16 사용자 지적).
//   트리거는 세 칸의 전·후 값을 **매번 다 기록**하므로, 안 바뀐 칸의 값도 설명에 끌어다 쓸 수 있다.
function _adTrackingHistoryChanges(h) {
  const parts = [];
  const idText = v => v ? esc(v) : '(없음)';

  if (h.prev_meta_pixel_id !== h.next_meta_pixel_id) {
    if (!h.prev_meta_pixel_id)      parts.push(`픽셀 아이디 등록 — ${idText(h.next_meta_pixel_id)}`);
    else if (!h.next_meta_pixel_id) parts.push(`픽셀 아이디 삭제 — ${idText(h.prev_meta_pixel_id)} 를 지움 (전송 중단)`);
    else                            parts.push(`픽셀 아이디 변경 — ${idText(h.prev_meta_pixel_id)} → ${idText(h.next_meta_pixel_id)}`);
  }

  if (h.prev_enabled !== h.next_enabled) {
    if (h.next_enabled) {
      // ⚠️ 아이디가 없으면 켜도 서버가 내주지 않아 실제 전송은 0 이다 — 문구가 사실보다 강해지지 않게 가른다
      parts.push(h.next_meta_pixel_id
        ? `<strong style="color:var(--green)">전송 켜기</strong> — 아이디 ${idText(h.next_meta_pixel_id)} 로 인플루언서 사이트 방문·가입·신청 정보를 Meta 로 보내기 시작`
        : '<strong style="color:var(--green)">전송 켜기</strong> — 다만 픽셀 아이디가 없어 실제로는 전송되지 않음');
    } else {
      parts.push('<strong>전송 끄기</strong> — Meta 로 보내지 않음 (이미 열려 있던 화면은 새로고침 전까지 보낼 수 있음)');
    }
  }

  if (h.prev_policy_effective_date !== h.next_policy_effective_date) {
    const prev = h.prev_policy_effective_date ? _adTrackingDateText(h.prev_policy_effective_date) : null;
    const next = h.next_policy_effective_date ? _adTrackingDateText(h.next_policy_effective_date) : null;
    if (!prev)      parts.push(`방침 시행일 설정 — ${esc(next)} (그날부터 켤 수 있음)`);
    else if (!next) parts.push(`방침 시행일 삭제 — ${esc(prev)} 를 지움 (다시 켤 수 없음)`);
    else            parts.push(`방침 시행일 변경 — ${esc(prev)} → ${esc(next)}`);
  }

  return parts.length ? parts.join('<br>') : '-';
}

async function loadAdTrackingPane() {
  const pane = document.getElementById('adminPane-ad-tracking');
  if (!pane) return;

  if (typeof isHidden === 'function' && isHidden('menu.ad-tracking')) {
    pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted);font-size:13px">이 화면에 접근할 권한이 없습니다.</div>';
    return;
  }

  pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--muted);font-size:13px">불러오는 중…</div>';
  const d = await fetchMetaPixelAdmin();
  _adTrackingData = d;
  if (!d) {
    // 🔴 실패면 스위치를 그리지 않는다 — 꺼짐처럼 보이면 「꺼져 있다」로 오해한다
    pane.innerHTML = '<div style="padding:40px;text-align:center;color:var(--red);font-size:13px">광고 추적 설정을 불러오지 못했습니다. 새로고침해 주세요.</div>';
    return;
  }
  renderAdTrackingPane(pane, d);
}

function renderAdTrackingPane(pane, d) {
  const canEdit = typeof canWrite === 'function' ? canWrite('ad_tracking.manage') : false;
  const locked = d.status === 'policy_locked';
  // 방침 시행 전에는 「켜는 방향」만 막는다 — 켜짐 값이면(SQL 로 켠 경우) 끄기는 허용(사양서 화면 구성 3)
  const toggleDisabled = !canEdit || (locked && !d.enabled);
  const notice = _adTrackingNotice;
  _adTrackingNotice = '';

  const stagingWarn = (typeof IS_STAGING !== 'undefined' && IS_STAGING)
    ? `<div style="margin:0 0 14px;padding:10px 14px;border-radius:10px;background:#FFF7ED;border:1px solid #FDBA74;color:#9A3412;font-size:13px;font-weight:600;display:flex;gap:8px;align-items:center">
         <span class="material-icons-round notranslate" translate="no" style="font-size:18px">warning</span>
         개발서버입니다 — 운영 아이디를 넣지 마세요. 시험용 픽셀만 넣습니다.
       </div>`
    : '';

  const lockLine = locked
    ? `<div style="font-size:12px;color:var(--muted);margin-top:8px">개인정보처리방침 개정 시행일 전에는 켤 수 없습니다 (서버도 거부합니다). 아이디는 미리 저장해 둘 수 있습니다.${d.enabled ? ' 지금 값이 「켜짐」으로 들어가 있어 끄기만 할 수 있습니다.' : ''}</div>`
    : '';
  const noPermLine = canEdit ? '' : '<div style="font-size:12px;color:var(--red);margin-top:8px">변경 권한이 없습니다.</div>';
  const noticeLine = notice
    ? `<div style="margin-top:12px;padding:9px 12px;border-radius:8px;background:var(--blue-l);color:var(--blue);font-size:12px;line-height:1.6">${esc(notice)}</div>`
    : '';

  const eventRows = (typeof META_PIXEL_EVENT_TABLE !== 'undefined' ? META_PIXEL_EVENT_TABLE : []).map(r => `<tr>
      <td style="font-family:monospace;font-size:12px;white-space:nowrap">${esc(r.event)}</td>
      <td style="font-size:13px">${esc(r.when_ko)}</td>
      <td style="font-size:12px;color:var(--muted)">${esc(r.params_ko)}</td>
    </tr>`).join('');

  const history = Array.isArray(d.history) ? d.history : [];
  const historyRows = history.length
    ? history.map(h => `<tr>
        <td style="font-size:12px;color:var(--muted);white-space:nowrap">${h.at ? esc(formatDateTime(h.at)) : '-'}</td>
        <td style="font-size:13px">${h.by_system ? '<span style="color:var(--muted)">시스템(직접 입력)</span>' : esc(h.actor_name || '(이름 없음)')}</td>
        <td style="font-size:13px">${_adTrackingHistoryChanges(h)}</td>
      </tr>`).join('')
    : '<tr><td colspan="3" style="padding:24px;text-align:center;color:var(--muted);font-size:13px">변경 이력이 없습니다.</td></tr>';

  pane.innerHTML = `
    <div class="admin-card" style="margin-bottom:16px">
      <div class="admin-card-header">
        <span class="admin-card-title">광고 추적 (메타 픽셀)</span>
        <!-- 상태 배지 · 마지막 저장 · 「Meta 전송」 스위치를 제목 줄 오른쪽에 모은다(2026-09-16 사용자 요청).
             ⚠️ 스위치 옆 설명(잠금 사유·권한 없음·저장 안내)은 본문에 그대로 둔다 — 머리글에 넣으면 제목 줄이 두 줄로 접힌다. -->
        <div style="display:flex;align-items:center;gap:14px;flex-wrap:wrap;justify-content:flex-end">
          ${_adTrackingStatusBadge(d)}
          ${d.updated_at ? `<span style="font-size:11px;color:var(--muted);white-space:nowrap">마지막 저장 ${esc(formatDateTime(d.updated_at))}</span>` : ''}
          <!-- ⚠️ 라벨은 「Meta 전송」(무엇을 켜고 끄는지)이다. 「전송 켜기」로 두면 스위치 옆에서 **지금 켜져 있다는 뜻**으로 읽힌다(2026-09-16 사용자 지적).
               지금 상태는 왼쪽 배지가 말하므로 스위치 옆에 꺼짐/켜짐을 또 적지 않는다. -->
          <span style="display:flex;align-items:center;gap:8px">
            <span class="visibility-toggle-label" style="font-size:13px;white-space:nowrap">Meta 전송</span>
            <button type="button" id="adTrackingToggle" class="visibility-toggle${d.enabled ? ' is-on' : ''}${toggleDisabled ? ' is-disabled' : ''}"
                    role="switch" aria-checked="${d.enabled ? 'true' : 'false'}" aria-label="메타 픽셀 전송"
                    ${toggleDisabled ? 'disabled' : ''} onclick="toggleAdTrackingEnabled()"><span class="visibility-toggle-knob"></span></button>
          </span>
        </div>
      </div>
      <div style="padding:18px 20px">
        ${stagingWarn}
        <div style="font-size:13px;color:var(--muted);line-height:1.7;margin-bottom:16px">
          인플루언서 사이트의 방문·가입·신청 정보를 Meta(인스타그램·페이스북)로 보내 광고 성과를 측정합니다. 관리자 화면에서는 전송하지 않습니다.
        </div>

        <label class="form-label" for="adTrackingPixelId" style="display:block;font-size:13px;font-weight:700;margin-bottom:6px">메타 픽셀 아이디</label>
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap">
          <input id="adTrackingPixelId" class="form-input" inputmode="numeric" autocomplete="off" maxlength="32"
                 placeholder="숫자만 (예: 1234567890123456)" value="${esc(d.meta_pixel_id || '')}"
                 style="width:280px" ${canEdit ? '' : 'disabled'}
                 onkeydown="if(event.key==='Enter'){saveAdTrackingPixelId()}">
          <button class="btn btn-primary btn-sm" onclick="saveAdTrackingPixelId()" ${canEdit ? '' : 'disabled'}>저장</button>
        </div>
        <div style="font-size:12px;color:var(--muted);margin-top:6px">비워서 저장하면 아이디가 지워집니다.</div>

        ${lockLine}
        ${noPermLine}
        ${noticeLine}
      </div>
    </div>

    <div class="admin-card" style="margin-bottom:16px">
      <div class="admin-card-header"><span class="admin-card-title">보내는 이벤트</span></div>
      <div style="padding:12px 20px 4px;font-size:12px;color:var(--muted)">이벤트 이름은 코드에 고정돼 있어 바꿀 수 없습니다 (이름이 바뀌면 메타 쪽 집계가 끊깁니다). 이름·전화번호·이메일 같은 회원 정보는 보내지 않습니다.</div>
      <div class="admin-table-wrap">
        <table class="data-table">
          <thead><tr><th style="width:190px">이벤트</th><th>언제</th><th style="width:300px">함께 보내는 값</th></tr></thead>
          <tbody>${eventRows}</tbody>
        </table>
      </div>
    </div>

    <div class="admin-card" style="margin-bottom:16px">
      <div class="admin-card-header"><span class="admin-card-title">실제로 들어오는지 확인하는 방법</span></div>
      <ol style="margin:0;padding:14px 20px 16px 38px;font-size:13px;line-height:1.9">
        <li>메타 비즈니스 관리자에서 <strong>이벤트 관리자</strong>를 엽니다.</li>
        <li>이 아이디의 픽셀을 고르고 <strong>「테스트 이벤트」</strong> 탭으로 갑니다.</li>
        <li>새 브라우저 창에서 인플루언서 사이트를 열어 캠페인 상세를 눌러 봅니다.</li>
        <li>몇 초 안에 <code>PageView</code>·<code>ViewContent</code> 가 목록에 뜨면 정상입니다. 아이디가 틀려도 이 화면에는 「저장됨」만 보이므로 반드시 여기서 확인합니다.</li>
      </ol>
    </div>

    <div class="admin-card">
      <div class="admin-card-header"><span class="admin-card-title">변경 이력</span><span style="font-size:12px;color:var(--muted)">최근 50건</span></div>
      <div class="admin-table-wrap">
        <table class="data-table">
          <thead><tr><th style="width:160px">시각</th><th style="width:160px">수정자</th><th>변경 내역</th></tr></thead>
          <tbody>${historyRows}</tbody>
        </table>
      </div>
    </div>`;
}

// 공용 저장 — 성공이면 그 동작에 맞는 안내를 남기고 페인을 다시 그린다
async function _adTrackingSave(pixelId, enabled, successToast, noticeKey) {
  if (_adTrackingBusy) return;
  _adTrackingBusy = true;
  try {
    const res = await updateMetaPixelSettings(pixelId, enabled);
    if (!res.ok) {
      toast(AD_TRACKING_ERROR_TEXT[res.error_code] || AD_TRACKING_ERROR_TEXT.request_failed, 'error');
      await refreshPane('ad-tracking');   // 서버 값 기준으로 스위치 모양을 되돌린다
      return;
    }
    toast(successToast, 'success');
    _adTrackingNotice = AD_TRACKING_NOTICE[noticeKey] || '';
    await refreshPane('ad-tracking');
  } finally {
    _adTrackingBusy = false;
  }
}

async function saveAdTrackingPixelId() {
  const d = _adTrackingData;
  if (!d) return;
  if (typeof canWrite === 'function' && !canWrite('ad_tracking.manage')) { toast(AD_TRACKING_ERROR_TEXT.forbidden, 'error'); return; }
  const input = document.getElementById('adTrackingPixelId');
  const value = input ? input.value.trim() : '';
  if (value && !/^[0-9]{1,32}$/.test(value)) { toast(AD_TRACKING_ERROR_TEXT.invalid_pixel_id, 'error'); return; }
  if (value === (d.meta_pixel_id || '')) { toast('바뀐 내용이 없습니다.'); return; }
  // 켜기 상태는 그대로 두고 아이디만 바꾼다
  // 꺼져 있으면 아이디를 저장해도 전송은 안 되므로 「이 아이디로 전송」이라고 적지 않는다
  const noticeKey = !value ? (d.meta_pixel_id ? 'idCleared' : 'idMissing') : (d.enabled ? 'id' : 'off');
  await _adTrackingSave(value, !!d.enabled, value ? '픽셀 아이디를 저장했습니다.' : '픽셀 아이디를 지웠습니다.', noticeKey);
}

async function toggleAdTrackingEnabled() {
  const d = _adTrackingData;
  if (!d) return;
  const toggle = document.getElementById('adTrackingToggle');
  if (toggle && toggle.disabled) return;
  // 저장 안 한 아이디가 입력칸에 있으면 멈춘다 — 스위치는 저장된 아이디로 켜고 끈다
  const input = document.getElementById('adTrackingPixelId');
  if (input && input.value.trim() !== (d.meta_pixel_id || '')) {
    toast('입력한 아이디를 먼저 저장해 주세요.');
    return;
  }
  const turnOn = !d.enabled;
  if (turnOn) {
    const ok = await showConfirm('켜면 인플루언서 사이트 방문·가입·신청 정보가 Meta 로 전송됩니다. 켤까요?', '켜기', '취소');
    if (!ok) return;
  }
  // 끌 때는 확인 없이 바로 — 끄는 쪽은 안전한 방향
  await _adTrackingSave(d.meta_pixel_id || '', turnOn, turnOn ? '광고 추적을 켰습니다.' : '광고 추적을 껐습니다.',
                        turnOn ? (d.meta_pixel_id ? 'on' : 'idMissing') : 'off');
}
