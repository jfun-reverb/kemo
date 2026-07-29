// ════════════════════════════════════════════════════════════════════
// admin-permissions.js — 동적 권한 관리 설정 화면 (super_admin 전용). PR2 조각 C.
//   등급(super_admin/campaign_admin/campaign_manager) × 기능(ADMIN_PERMISSION_CATALOG 36)
//   그리드에서 super_admin 이 접근수준(쓰기/읽기/숨김)을 설정.
//   저장 = update_role_permissions RPC(일괄·원자·이력·권한상승/충돌 가드, storage.js saveRolePermissions).
//   ⚠️ 이 설정은 "화면 표시 제어"다. 실제 데이터 접근 차단이 아니다(서버 RLS/has_permission 이 방어선, PR3).
//      그래서 상단 경고 배너에 범례를 두고, 기능마다 「서버 차단 / 화면에서만 / 슈퍼 적용 안 됨」
//      배지를 붙인다(PERM_EFFECT_BADGE — 슈퍼관리자 자기 제한 관점).
// ════════════════════════════════════════════════════════════════════

const PERM_ROLES = [
  {key: 'super_admin',      label: '슈퍼관리자'},
  {key: 'campaign_admin',   label: '캠페인관리자'},
  {key: 'campaign_manager', label: '캠페인매니저'},
];
const PERM_LEVELS = [
  {v: 'write',  label: '쓰기'},
  {v: 'read',   label: '읽기'},
  {v: 'hidden', label: '숨김'},
];
// 값별 아이콘 — 색과 함께 써서 색으로만 구분하지 않게 한다(색각 이상 대비)
const PERM_LEVEL_ICON = { write: 'edit', read: 'visibility', hidden: 'visibility_off' };
// 권한 상승 위험 — 이 기능들은 super 전용 유지(admin/manager 는 hidden 고정·편집 잠금).
//   permissions.manage·admin.manage 는 서버 RPC denylist 와 동일(권한 상승 차단).
//   menu.permissions 는 이 화면 자체의 사이드바 노출 — admin/manager 에게 write 로 열면 죽은 메뉴가 보이므로 잠금(서버 진입은 별도 super 가드가 차단).
const PERM_DENYLIST = ['permissions.manage', 'admin.manage', 'menu.permissions'];

let _permCurrent = {};  // 'role|feature_key' → level (서버 현재값)
let _permEdited  = {};  // 변경분만 'role|feature_key' → level
let _permDefault = {};  // 'role|feature_key' → default_level (기본값 baseline, 복원 버튼 활성 판정용)

// 셀 현재 표시값: 편집값 우선 → 서버값 → 기본 write
//   (슈퍼관리자도 마이그레이션 268~270 이후로는 표의 값을 그대로 쓴다 — 더 이상 write 고정 아님)
function permCellValue(role, key) {
  const k = role + '|' + key;
  if (k in _permEdited) return _permEdited[k];
  return _permCurrent[k] || 'write';
}

// 슈퍼관리자 칸에서 잠글 기능 — 이걸 제한하면 되돌릴 방법이 없어진다(사양서 §4-4)
const PERM_SUPER_LOCKED = ['permissions.manage', 'admin.manage', 'menu.permissions'];

// 「이 설정이 실제로 먹히는가」 배지 — 슈퍼관리자 열에만 의미가 있다
const PERM_EFFECT_BADGE = {
  server: '<span class="perm-tag perm-tag-server" title="슈퍼관리자가 제한하면 서버에서 데이터까지 막힙니다">서버 차단</span>',
  client: '<span class="perm-tag" title="슈퍼관리자가 제한하면 메뉴·버튼만 감춰집니다. 데이터는 서버에서 그대로 열려 있습니다">화면에서만</span>',
  none:   '<span class="perm-tag perm-tag-none" title="서버·화면 모두 등급을 직접 보고 판단해, 슈퍼관리자에게는 이 설정이 적용되지 않습니다">슈퍼 적용 안 됨</span>'
};

async function loadPermissionsPane() {
  const body = document.getElementById('permPaneBody');
  if (!body) return;
  // 이중 가드 — super_admin 아니면 렌더 안 함(switchAdminPane 진입 가드가 이미 막지만 방어적)
  if (!(currentAdminInfo && currentAdminInfo.role === 'super_admin')) {
    body.innerHTML = '<div style="padding:24px;color:var(--muted)">이 화면은 슈퍼관리자만 사용할 수 있습니다.</div>';
    return;
  }
  _permCurrent = {}; _permEdited = {}; _permDefault = {};
  const rows = (typeof fetchRolePermissions === 'function') ? await fetchRolePermissions() : [];
  rows.forEach(r => {
    _permCurrent[r.role + '|' + r.feature_key] = r.access_level;
    if (r.default_level) _permDefault[r.role + '|' + r.feature_key] = r.default_level;
  });
  renderPermGrid();
  updatePermSaveBar();
}

function renderPermGrid() {
  const body = document.getElementById('permPaneBody');
  if (!body || typeof ADMIN_PERMISSION_CATALOG === 'undefined') return;
  // category 순서 유지하며 그룹핑
  const groups = [];
  const idx = {};
  ADMIN_PERMISSION_CATALOG.forEach(f => {
    if (!(f.category in idx)) { idx[f.category] = groups.length; groups.push({category: f.category, items: []}); }
    groups[idx[f.category]].items.push(f);
  });

  // 제목·경고배너는 페인 상단 고정 헤더(admin-sticky-header)에 정적 배치 — 여기선 그리드만.
  // 하나의 표 + category 구분 행 → 열 헤더는 맨 위 1회만(스크롤 시 상단 고정). 접기는 category 행 토글.
  const colspan = PERM_ROLES.length + 1;
  let html = '<table class="perm-table"><thead><tr><th class="perm-th-feat">기능</th>';
  PERM_ROLES.forEach(r => { html += '<th>' + esc(r.label) + '</th>'; });
  html += '</tr></thead><tbody>';

  groups.forEach((g, gi) => {
    html += '<tr class="perm-cat-row" onclick="togglePermGroup(' + gi + ')"><td colspan="' + colspan + '">'
         +  '<span class="material-icons-round notranslate perm-caret" translate="no" id="permCaret' + gi + '">expand_more</span>'
         +  esc(g.category) + '</td></tr>';
    g.items.forEach(f => {
      const locked = PERM_DENYLIST.indexOf(f.key) !== -1;
      html += '<tr class="perm-item perm-cat-' + gi + '"><td class="perm-feat">' + esc(f.label_ko)
           +  (locked ? ' <span class="perm-tag perm-tag-super">슈퍼 전용</span>' : '')
           +  (locked ? '' : (PERM_EFFECT_BADGE[permSuperEffect(f.key)] || '')) + '</td>';
      PERM_ROLES.forEach(r => {
        const isSuper = r.key === 'super_admin';
        // 슈퍼관리자 열은 이제 편집 가능. 단 되돌릴 길을 끊는 3종만 「쓰기」로 고정.
        const cellLocked = locked && (isSuper ? PERM_SUPER_LOCKED.indexOf(f.key) !== -1 : true);
        if (cellLocked) {
          html += '<td class="perm-cell perm-locked" title="'
               +  (isSuper ? '이 항목을 제한하면 권한을 되돌릴 수 없어 고정합니다' : '권한 상승을 막기 위해 고정된 항목입니다')
               +  '">' + (isSuper ? '쓰기(고정)' : '숨김') + '</td>';
        } else {
          const val = permCellValue(r.key, f.key);
          const dirty = (r.key + '|' + f.key) in _permEdited;
          // 글자만으로는 세 값이 한눈에 안 구분돼 색 + 아이콘을 함께 붙인다(2026-07-29 지적).
          // 아이콘은 select 안에 못 넣으므로 감싸는 칸에 겹쳐 놓고 select 왼쪽 여백을 준다.
          let sel = '<span class="perm-sel-wrap perm-lv-' + val + '">'
                 +  '<span class="material-icons-round notranslate perm-sel-ico" translate="no">' + PERM_LEVEL_ICON[val] + '</span>'
                 +  '<select class="perm-sel' + (dirty ? ' perm-dirty' : '')
                 +  '" onchange="onPermCell(\'' + r.key + '\',\'' + f.key + '\',this)">';
          PERM_LEVELS.forEach(l => { sel += '<option value="' + l.v + '"' + (l.v === val ? ' selected' : '') + '>' + l.label + '</option>'; });
          sel += '</select></span>';
          html += '<td class="perm-cell">' + sel + '</td>';
        }
      });
      html += '</tr>';
    });
  });
  html += '</tbody></table>';
  body.innerHTML = html;
}

// 저장 영역(변경 카운트·저장 버튼)은 페인 상단 고정 헤더에 정적으로 있음 — 상태만 갱신.
function updatePermSaveBar() {
  const n = Object.keys(_permEdited).length;
  const btn = document.getElementById('permSaveBtn');
  if (btn) btn.disabled = !n;
  const cnt = document.querySelector('.perm-changecount');
  if (cnt) cnt.textContent = n ? n + '개 변경됨' : '변경 없음';
  // 「기본값 복원」 버튼 — 저장된 현재값이 기본값과 다른 항목이 있을 때만 활성
  const rbtn = document.getElementById('permRestoreBtn');
  if (rbtn) {
    const diff = countPermDefaultDiff();
    rbtn.disabled = !diff;
    rbtn.title = diff ? (diff + '개 항목이 기본값과 다릅니다 — 기본값으로 되돌립니다') : '이미 기본값 상태입니다';
  }
  // 슈퍼관리자만 복원 — 자기 제한을 걸어둔 항목이 있을 때만 활성
  const sbtn = document.getElementById('permSuperRestoreBtn');
  if (sbtn) {
    const sdiff = countSuperPermDiff();
    sbtn.disabled = !sdiff;
    sbtn.title = sdiff
      ? ('슈퍼관리자 권한 ' + sdiff + '개가 제한돼 있습니다 — 전권으로 되돌립니다 (다른 등급 설정은 그대로)')
      : '슈퍼관리자는 이미 전권 상태입니다';
  }
}

// 저장된 현재값(_permCurrent) 중 기본값(_permDefault)과 다른 항목 수. 미저장 편집(_permEdited)은 제외 —
//   복원은 "저장된 값 → 기본값"이라 편집 중 값이 아니라 서버 현재값 기준으로 판정.
function countPermDefaultDiff() {
  let n = 0;
  Object.keys(_permDefault).forEach(k => {
    if ((_permCurrent[k] || 'write') !== _permDefault[k]) n++;
  });
  return n;
}

function togglePermGroup(gi) {
  const c = document.getElementById('permCaret' + gi);
  const collapsed = c && c.textContent.trim() === 'chevron_right';  // 현재 접힘 상태인지(caret 기준 — DOM 인덱스 안 씀)
  document.querySelectorAll('.perm-cat-' + gi).forEach(r => { r.style.display = collapsed ? '' : 'none'; });
  if (c) c.textContent = collapsed ? 'expand_more' : 'chevron_right';
}

function onPermCell(role, key, sel) {
  const k = role + '|' + key;
  const cur = _permCurrent[k] || 'write';
  if (sel.value === cur) delete _permEdited[k];
  else _permEdited[k] = sel.value;
  sel.classList.toggle('perm-dirty', (k in _permEdited));
  // 색·아이콘도 새 값에 맞춰 바로 바꿔준다(재렌더 없이)
  const wrap = sel.parentElement;
  if (wrap && wrap.classList.contains('perm-sel-wrap')) {
    wrap.classList.remove('perm-lv-write', 'perm-lv-read', 'perm-lv-hidden');
    wrap.classList.add('perm-lv-' + sel.value);
    const ico = wrap.querySelector('.perm-sel-ico');
    if (ico) ico.textContent = PERM_LEVEL_ICON[sel.value] || 'edit';
  }
  updatePermSaveBar();
}

// 슈퍼관리자 권한을 바꿀 때의 확인 문구.
//   ① 등급 전체에 걸린다 ② 서버까지 막히는 항목은 무엇인지 ③ 언제든 되돌릴 수 있다
function buildSuperPermConfirmText(superKeys, totalCount) {
  const lines = superKeys.map(k => {
    const feat = k.slice('super_admin|'.length);
    const label = (typeof ADMIN_PERMISSION_CATALOG !== 'undefined')
      ? ((ADMIN_PERMISSION_CATALOG.find(f => f.key === feat) || {}).label_ko || feat) : feat;
    const lv = ({ write: '쓰기', read: '읽기', hidden: '숨김' })[_permEdited[k]] || _permEdited[k];
    const eff = permSuperEffect(feat);
    const note = eff === 'server' ? ' (서버에서 데이터까지 막힘)'
               : eff === 'none' ? ' (슈퍼관리자에게는 적용되지 않음)' : '';
    return '· ' + label + ' → ' + lv + note;
  });
  return '슈퍼관리자 권한 ' + superKeys.length + '개를 바꿉니다.\n\n'
       + lines.join('\n')
       + '\n\n이 설정은 슈퍼관리자 등급 전체에 적용됩니다(계정별 아님).'
       + '\n권한 관리 화면은 어떤 설정으로도 닫히지 않으니 언제든 되돌릴 수 있습니다.'
       + (totalCount > superKeys.length ? '\n\n다른 등급 변경 ' + (totalCount - superKeys.length) + '개도 함께 저장됩니다.' : '')
       + '\n\n계속할까요?';
}

async function savePermChanges() {
  const keys = Object.keys(_permEdited);
  if (!keys.length) return;
  // 슈퍼관리자 자기 제한은 자기 발등을 찍는 동작이라, 무엇이 사라지는지·되돌리는 법을 따로 알린다
  const superKeys = keys.filter(k => k.indexOf('super_admin|') === 0);
  const ok = await showConfirm(superKeys.length
    ? buildSuperPermConfirmText(superKeys, keys.length)
    : keys.length + '개 권한 설정을 변경합니다. 계속할까요?');
  if (!ok) return;
  // 저장 안정성 — (role, feature_key) 정렬로 배치 잠금 순서 고정(데드락 예방, reviewer 권고)
  keys.sort();
  const changes = keys.map(k => {
    const sep = k.indexOf('|');
    const role = k.slice(0, sep), feat = k.slice(sep + 1);
    return {role: role, feature_key: feat, prev_level: (_permCurrent[k] || 'write'), next_level: _permEdited[k]};
  });
  const btn = document.getElementById('permSaveBtn');
  if (btn) btn.disabled = true;
  try {
    const applied = await saveRolePermissions(changes);
    toast((applied || 0) + '개 권한을 저장했습니다.');
    // 저장 후 재로드(현재값 갱신·편집 초기화) + 메뉴 숨김 즉시 재적용(본인이 바꾼 게 super 무관이라 화면엔 무영향이나 일관성)
    await loadPermissionsPane();
    if (typeof applyLookupMenuVisibility === 'function') applyLookupMenuVisibility();
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    // RPC 가드 메시지 친화화
    if (msg.indexOf('conflict') !== -1) toast('다른 관리자가 먼저 변경했습니다. 새로고침 후 다시 시도하세요.', 'error');
    else toast('저장 실패: ' + msg, 'error');
    if (btn) btn.disabled = false;
  }
}

// 「기본값 복원」 — 저장된 현재값을 baseline(default_level)으로 되돌린다. 전용 서버 RPC로 원자 처리
//   (낙관적 락 마찰 없음). 미저장 편집은 버려짐(확인 모달에 명시). denylist 행은 기본값이 hidden이라 서버가 자연 skip.
// 슈퍼관리자 행만 전권으로 되돌린다 — 전체 복원은 다른 등급 설정까지 초기화해 버리므로,
// 자기 제한을 풀려다 남의 설정을 날리는 일이 없게 별도 버튼을 둔다(사양서 §2-5-4).
function countSuperPermDiff() {
  return Object.keys(_permCurrent).filter(k =>
    k.indexOf('super_admin|') === 0 && _permCurrent[k] !== (_permDefault[k] || 'write')).length;
}

async function restoreSuperPermDefaults() {
  const keys = Object.keys(_permCurrent).filter(k =>
    k.indexOf('super_admin|') === 0 && _permCurrent[k] !== (_permDefault[k] || 'write'));
  if (!keys.length) { toast('슈퍼관리자 권한은 이미 전권 상태입니다.'); return; }
  const ok = await showConfirm('슈퍼관리자 권한 ' + keys.length + '개를 전권(쓰기)으로 되돌립니다.\n다른 등급 설정은 그대로 둡니다. 계속할까요?');
  if (!ok) return;
  const btn = document.getElementById('permSuperRestoreBtn');
  if (btn) btn.disabled = true;
  try {
    keys.sort();
    const changes = keys.map(k => ({
      role: 'super_admin', feature_key: k.slice('super_admin|'.length),
      prev_level: _permCurrent[k], next_level: (_permDefault[k] || 'write')
    }));
    const applied = await saveRolePermissions(changes);
    toast((applied || 0) + '개 권한을 되돌렸습니다.');
    await loadPermissionsPane();
    if (typeof applyLookupMenuVisibility === 'function') applyLookupMenuVisibility();
  } catch (e) {
    toast('복원 실패: ' + ((e && e.message) ? e.message : String(e)), 'error');
    if (btn) btn.disabled = false;
  }
}

async function restorePermDefaults() {
  const diff = countPermDefaultDiff();
  if (!diff) { toast('이미 기본값 상태입니다.'); return; }
  const ok = await showConfirm(diff + '개 항목을 기본값으로 되돌립니다. 저장하지 않은 편집은 사라집니다. 계속할까요?');
  if (!ok) return;
  const btn = document.getElementById('permRestoreBtn');
  if (btn) btn.disabled = true;
  try {
    const applied = (typeof restoreRolePermissionsDefaults === 'function') ? await restoreRolePermissionsDefaults() : 0;
    toast((applied || 0) + '개 권한을 기본값으로 복원했습니다.');
    await loadPermissionsPane();
    if (typeof applyLookupMenuVisibility === 'function') applyLookupMenuVisibility();
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    toast('복원 실패: ' + msg, 'error');
    if (btn) btn.disabled = false;
  }
}
