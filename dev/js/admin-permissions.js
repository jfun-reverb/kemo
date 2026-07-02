// ════════════════════════════════════════════════════════════════════
// admin-permissions.js — 동적 권한 관리 설정 화면 (super_admin 전용). PR2 조각 C.
//   등급(super_admin/campaign_admin/campaign_manager) × 기능(ADMIN_PERMISSION_CATALOG 36)
//   그리드에서 super_admin 이 접근수준(쓰기/읽기/숨김)을 설정.
//   저장 = update_role_permissions RPC(일괄·원자·이력·권한상승/충돌 가드, storage.js saveRolePermissions).
//   ⚠️ 이 설정은 "화면 표시 제어"다. 실제 데이터 접근 차단이 아니다(서버 RLS/has_permission 이 방어선, PR3).
//      그래서 상단 경고 배너로 명시하고, server_enforced 기능 셀엔 「화면 제어만」 표식을 붙인다.
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
// 권한 상승 위험 — 이 기능들은 super 전용 유지(admin/manager 는 hidden 고정·편집 잠금).
//   permissions.manage·admin.manage 는 서버 RPC denylist 와 동일(권한 상승 차단).
//   menu.permissions 는 이 화면 자체의 사이드바 노출 — admin/manager 에게 write 로 열면 죽은 메뉴가 보이므로 잠금(서버 진입은 별도 super 가드가 차단).
const PERM_DENYLIST = ['permissions.manage', 'admin.manage', 'menu.permissions'];

let _permCurrent = {};  // 'role|feature_key' → level (서버 현재값)
let _permEdited  = {};  // 변경분만 'role|feature_key' → level

// 셀 현재 표시값: super 는 항상 write, 그 외 편집값 우선 → 서버값 → 기본 write
function permCellValue(role, key) {
  if (role === 'super_admin') return 'write';
  const k = role + '|' + key;
  if (k in _permEdited) return _permEdited[k];
  return _permCurrent[k] || 'write';
}

async function loadPermissionsPane() {
  const body = document.getElementById('permPaneBody');
  if (!body) return;
  // 이중 가드 — super_admin 아니면 렌더 안 함(switchAdminPane 진입 가드가 이미 막지만 방어적)
  if (!(currentAdminInfo && currentAdminInfo.role === 'super_admin')) {
    body.innerHTML = '<div style="padding:24px;color:var(--muted)">이 화면은 슈퍼관리자만 사용할 수 있습니다.</div>';
    return;
  }
  _permCurrent = {}; _permEdited = {};
  const rows = (typeof fetchRolePermissions === 'function') ? await fetchRolePermissions() : [];
  rows.forEach(r => { _permCurrent[r.role + '|' + r.feature_key] = r.access_level; });
  renderPermGrid();
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

  let html = '';
  html += '<div class="perm-head">';
  html += '<div style="font-size:16px;font-weight:700;color:var(--ink);margin-bottom:8px">권한 관리</div>';
  html += '<div class="perm-warn"><span class="material-icons-round notranslate" translate="no">warning</span>'
       +  '<span>이 설정은 <b>화면 표시 제어</b>입니다. 실제 데이터 접근 차단은 다음 단계에서 적용됩니다. '
       +  '지금은 메뉴·버튼 노출만 바뀌고, 데이터는 서버에서 그대로 열려 있습니다.</span></div>';
  html += '</div>';

  groups.forEach((g, gi) => {
    html += '<div class="perm-group">';
    html += '<div class="perm-group-hd" onclick="togglePermGroup(' + gi + ')">'
         +  '<span class="material-icons-round notranslate perm-caret" translate="no" id="permCaret' + gi + '">expand_more</span>'
         +  esc(g.category) + '</div>';
    html += '<div class="perm-group-body" id="permGroupBody' + gi + '">';
    html += '<table class="perm-table"><thead><tr><th class="perm-th-feat">기능</th>';
    PERM_ROLES.forEach(r => { html += '<th>' + esc(r.label) + '</th>'; });
    html += '</tr></thead><tbody>';
    g.items.forEach(f => {
      const locked = PERM_DENYLIST.indexOf(f.key) !== -1;
      html += '<tr><td class="perm-feat">' + esc(f.label_ko)
           +  (f.server_enforced ? ' <span class="perm-tag">화면 제어만</span>' : '')
           +  (locked ? ' <span class="perm-tag perm-tag-super">슈퍼 전용</span>' : '') + '</td>';
      PERM_ROLES.forEach(r => {
        const isSuper = r.key === 'super_admin';
        const cellLocked = isSuper || locked;  // super 열 전체 + denylist 행의 admin/manager 셀 잠금
        if (cellLocked) {
          html += '<td class="perm-cell perm-locked">' + (isSuper ? '쓰기(전권)' : '숨김') + '</td>';
        } else {
          const val = permCellValue(r.key, f.key);
          const dirty = (r.key + '|' + f.key) in _permEdited;
          let sel = '<select class="perm-sel' + (dirty ? ' perm-dirty' : '')
                 +  '" onchange="onPermCell(\'' + r.key + '\',\'' + f.key + '\',this)">';
          PERM_LEVELS.forEach(l => { sel += '<option value="' + l.v + '"' + (l.v === val ? ' selected' : '') + '>' + l.label + '</option>'; });
          sel += '</select>';
          html += '<td class="perm-cell">' + sel + '</td>';
        }
      });
      html += '</tr>';
    });
    html += '</tbody></table></div></div>';
  });

  const n = Object.keys(_permEdited).length;
  html += '<div class="perm-actions">'
       +  '<span class="perm-changecount">' + (n ? n + '개 변경됨' : '변경 없음') + '</span>'
       +  '<button class="btn btn-primary" id="permSaveBtn" onclick="savePermChanges()"' + (n ? '' : ' disabled') + '>저장</button>'
       +  '</div>';
  body.innerHTML = html;
}

function togglePermGroup(gi) {
  const b = document.getElementById('permGroupBody' + gi);
  const c = document.getElementById('permCaret' + gi);
  if (!b) return;
  const collapsed = b.style.display === 'none';
  b.style.display = collapsed ? '' : 'none';
  if (c) c.textContent = collapsed ? 'expand_more' : 'chevron_right';
}

function onPermCell(role, key, sel) {
  const k = role + '|' + key;
  const cur = _permCurrent[k] || 'write';
  if (sel.value === cur) delete _permEdited[k];
  else _permEdited[k] = sel.value;
  sel.classList.toggle('perm-dirty', (k in _permEdited));
  const n = Object.keys(_permEdited).length;
  const btn = document.getElementById('permSaveBtn');
  if (btn) btn.disabled = !n;
  const cnt = document.querySelector('.perm-changecount');
  if (cnt) cnt.textContent = n ? n + '개 변경됨' : '변경 없음';
}

async function savePermChanges() {
  const keys = Object.keys(_permEdited);
  if (!keys.length) return;
  const ok = await showConfirm(keys.length + '개 권한 설정을 변경합니다. 계속할까요?');
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
