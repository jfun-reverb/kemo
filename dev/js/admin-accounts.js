// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-accounts.js
// ═════════════════════════════════════════════════════════════════
//
// 내 계정 + 관리자 계정 관리 페인 (admin.js 파일 분리).
//   · 사이드바 프로필 (updateSidebarProfile)
//   · 관리자 목록 + 메일 수신 구독 + 권한 헬퍼 (loadAdminAccounts/openAdminEmailSubsModal/
//     isCampaignAdminOrAbove/applyLookupMenuVisibility)
//   · 본인 계정/비밀번호 (loadMyAdminInfo/saveMyAdminInfo/changeMyAdminPassword)
//   · 관리자 추가/편집/삭제 모달 + 초대(RPC)/비번 재설정 (openAddAdminModal/saveAdmin/
//     executeRemoveRole/executeDeleteCompletely/sendResetEmail 등)
//   · 상태: _adminEmailKindsCache/_adminEmailSubsEditingId/_adminEmailSubsModalKinds
//
// ⚠ loadAdminAccounts/loadMyAdminInfo 는 switchAdminPane(admin-core.js) loaders 가,
//   isCampaignAdminOrAbove/applyLookupMenuVisibility 는 LOOKUPS(admin.js)·FAQ(admin-faq.js)가 호출
//   → 전역 유지(이름 변경 금지). currentAdminInfo 는 admin-core.js 선언, 여기서 할당.
// ═════════════════════════════════════════════════════════════════

// ══════════════════════════════════════
// 관리자 계정 관리
// ══════════════════════════════════════

// ════════════════════════════════════════════════════════════════════
// SECTION: MY-ACCOUNT — 사이드바 프로필 표시
// ════════════════════════════════════════════════════════════════════

function updateSidebarProfile() {
  const name = currentAdminInfo?.name || currentUserProfile?.name || currentUser?.email || '관리자';
  const initial = (name || 'A').charAt(0).toUpperCase();
  const el = $('sidebarAdminName');
  const av = $('sidebarAdminAvatar');
  if (el) el.textContent = name;
  if (av) av.textContent = initial;
  // STAGING 배지
  const sb = $('stagingBadgeSide');
  const sbOrig = $('stagingBadge');
  if (sb && sbOrig && sbOrig.style.display !== 'none') sb.style.display = '';
}

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-ACCOUNTS — 목록 + 광고주 알림 토글 + 권한 헬퍼
//   isCampaignAdminOrAbove / applyLookupMenuVisibility 도 함께 이동
// ════════════════════════════════════════════════════════════════════

// 메일 종류 카탈로그 캐시 (모달 + 칩 라벨 양쪽에서 재사용)
let _adminEmailKindsCache = null;
async function _getAdminEmailKinds() {
  if (_adminEmailKindsCache) return _adminEmailKindsCache;
  _adminEmailKindsCache = await fetchAdminEmailKinds();
  return _adminEmailKindsCache;
}

async function loadAdminAccounts() {
  if (!db) return;
  const {data} = await db?.from('admins').select('*').order('created_at');
  const admins = data || [];
  // 현재 로그인한 관리자 정보 먼저 확정 (렌더 시 권한 판단에 사용)
  currentAdminInfo = admins.find(a => a.auth_id === currentUser?.id) || null;
  const isSuper = currentAdminInfo?.role === 'super_admin';

  // 구독 상태 + 메일 종류 카탈로그 일괄 로드
  const adminIds = admins.map(a => a.id);
  const [subs, kinds] = await Promise.all([
    fetchAdminEmailSubscriptions(adminIds),
    _getAdminEmailKinds()
  ]);

  _renderAdminAccountsTable(admins, subs, kinds, isSuper);
  applyLookupMenuVisibility();
}

// 관리자 목록 테이블 렌더 (loadAdminAccounts 길이 축소 목적 분리)
function _renderAdminAccountsTable(admins, subs, kinds, isSuper) {
  const kindLabel = code => (kinds.find(k => k.code === code) || {}).name_ko || code;

  const roleLabel = r => r === 'super_admin'
    ? '<span class="badge badge-red">슈퍼관리자</span>'
    : r === 'campaign_admin'
    ? '<span class="badge badge-blue">캠페인관리자</span>'
    : '<span class="badge badge-gray">캠페인매니저</span>';

  // 메일받기 셀: 켜진 종류 회색 칩 나열 + 「설정」 버튼.
  // 본인 행은 항상 편집 가능. 다른 관리자 행은 super_admin 만 편집 가능.
  const renderMailCell = a => {
    const codes = subs[a.id] || [];
    const chips = codes.length
      ? codes.map(c => `<span class="badge badge-gray" style="font-size:10px;padding:1px 6px;border-radius:8px;line-height:1.5;white-space:nowrap">${esc(kindLabel(c))}</span>`).join(' ')
      : '<span style="color:var(--muted);font-size:12px">—</span>';
    const canEdit = isSuper || a.auth_id === currentUser?.id;
    const btn = canEdit
      ? `<button class="btn btn-ghost btn-xs" data-name="${esc(a.name||'')}" data-email="${esc(a.email)}" onclick="openAdminEmailSubsModal('${a.id}', this.dataset.name, this.dataset.email)">설정</button>`
      : '';
    return `<div style="display:flex;align-items:center;gap:8px">
      <div style="flex:1;min-width:0;display:flex;flex-wrap:wrap;gap:4px">${chips}</div>
      ${btn}
    </div>`;
  };

  $('adminAccountsBody').innerHTML = admins.length ? admins.map(a => `<tr>
    <td style="font-weight:600">${esc(a.name)||'—'}</td>
    <td>${esc(a.email)}</td>
    <td>${roleLabel(a.role)}</td>
    <td>${renderMailCell(a)}</td>
    <td style="font-size:12px;color:var(--muted)">${formatDate(a.created_at)}</td>
    <td><div style="display:flex;gap:5px">
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" data-name="${esc(a.name||'')}" onclick="openEditAdmin('${a.id}',this.dataset.email,this.dataset.name,'${a.role}')">수정</button>
      <button class="btn btn-ghost btn-xs" data-email="${esc(a.email)}" onclick="openResetPwModal('${a.auth_id}',this.dataset.email)">비밀번호</button>
      ${(isSuper && a.auth_id !== currentUser?.id) ? `<button class="btn btn-ghost btn-xs" style="color:#B3261E" data-email="${esc(a.email)}" data-auth-id="${a.auth_id}" onclick="openDeleteAdminModal('${a.id}',this.dataset.authId,this.dataset.email)">삭제</button>` : ''}
    </div></td>
  </tr>`).join('') : '<tr><td colspan="6" style="text-align:center;color:var(--muted);padding:24px">데이터 없음</td></tr>';
}

// ──────────────────────────────────────
// 「메일 받기 설정」 모달 (admin_email_subscriptions)
// ──────────────────────────────────────
// 현재 편집 중인 관리자 id (저장 시 사용)
let _adminEmailSubsEditingId = null;
// 모달 안의 메일 종류 목록 (저장 시 사용)
let _adminEmailSubsModalKinds = [];

async function openAdminEmailSubsModal(adminId, adminName, adminEmail) {
  if (!db) return;
  _adminEmailSubsEditingId = adminId;
  // 헤더에 관리자 정보 + 안내문
  const hdr = $('adminEmailSubsHeader');
  if (hdr) hdr.textContent = `${adminName || '—'} (${adminEmail || ''})`;
  // 메일 종류 카탈로그 + 현재 구독 상태 로드
  const [kinds, subs] = await Promise.all([
    _getAdminEmailKinds(),
    fetchAdminEmailSubscriptions([adminId])
  ]);
  _adminEmailSubsModalKinds = kinds;
  const currentSet = new Set(subs[adminId] || []);
  // 본문 동적 렌더
  const body = $('adminEmailSubsBody');
  if (body) {
    body.innerHTML = kinds.length ? kinds.map(k => `
      <label style="display:flex;gap:10px;align-items:flex-start;padding:10px;border:1px solid var(--line);border-radius:10px;margin-bottom:8px;cursor:pointer">
        <input type="checkbox" class="adm-email-sub-cb" data-code="${esc(k.code)}" ${currentSet.has(k.code) ? 'checked' : ''} style="margin-top:3px">
        <div style="flex:1">
          <div style="font-weight:600;color:var(--ink);font-size:13px">${esc(k.name_ko)}</div>
          <div style="font-size:11px;color:var(--muted);margin-top:2px">${esc(_adminEmailKindDesc(k.code))}</div>
        </div>
      </label>
    `).join('') : '<div style="color:var(--muted);font-size:12px;padding:12px">등록된 메일 종류가 없습니다.</div>';
  }
  openModal('adminEmailSubsModal');
}

// 메일 종류별 보조 설명 (사용자 친화 카피)
function _adminEmailKindDesc(code) {
  const map = {
    'brand_notify':       '광고주(브랜드)가 sales 페이지에서 신청 폼을 제출했을 때 접수 알림',
    'application_cancel': '인플루언서가 구매기간 이후에 응모를 취소했을 때 알림'
  };
  return map[code] || '';
}

async function saveAdminEmailSubsFromModal() {
  if (!_adminEmailSubsEditingId) { closeModal('adminEmailSubsModal'); return; }
  // 모달 안 체크박스 상태 → Set
  const checked = new Set();
  document.querySelectorAll('#adminEmailSubsBody .adm-email-sub-cb:checked').forEach(cb => {
    const code = cb.getAttribute('data-code');
    if (code) checked.add(code);
  });
  const res = await saveAdminEmailSubscriptions(_adminEmailSubsEditingId, checked, _adminEmailSubsModalKinds);
  if (!res.ok) {
    toast('저장 실패: ' + (res.error || '알 수 없는 오류'), 'error');
    return;
  }
  toast('메일 수신 설정을 저장했습니다');
  closeModal('adminEmailSubsModal');
  _adminEmailSubsEditingId = null;
  _adminEmailSubsModalKinds = [];
  await refreshPane('admin-accounts');
}

// 권한에 따라 "기준 데이터" 메뉴 표시/숨김
function isCampaignAdminOrAbove() {
  const r = currentAdminInfo?.role;
  return r === 'super_admin' || r === 'campaign_admin';
}
function applyLookupMenuVisibility() {
  const show = isCampaignAdminOrAbove() ? '' : 'none';
  const el = document.getElementById('adminLookupsSi');
  if (el) el.style.display = show;
  // 자주 묻는 질문(FAQ) 메뉴도 동일 권한(campaign_admin 이상)으로 노출
  const faqEl = document.getElementById('adminFaqSi');
  if (faqEl) faqEl.style.display = show;
}

// ════════════════════════════════════════════════════════════════════
// SECTION: MY-ACCOUNT — 본인 계정 정보/비밀번호
// ════════════════════════════════════════════════════════════════════

async function loadMyAdminInfo() {
  if (!currentAdminInfo && db) {
    const {data} = await db?.from('admins').select('*').eq('auth_id', currentUser?.id).maybeSingle();
    currentAdminInfo = data;
  }
  if (!currentAdminInfo) return;
  if ($('myAdminEmail')) $('myAdminEmail').value = currentAdminInfo.email;
  if ($('myAdminName')) $('myAdminName').value = currentAdminInfo.name || '';
  if ($('myAdminRole')) $('myAdminRole').value = currentAdminInfo.role === 'super_admin' ? '슈퍼관리자' : currentAdminInfo.role === 'campaign_admin' ? '캠페인관리자' : '캠페인매니저';
  applyLookupMenuVisibility();
}

async function saveMyAdminInfo() {
  if (!currentAdminInfo || !db) return;
  const name = $('myAdminName')?.value.trim();
  try {
    await db?.from('admins').update({name}).eq('id', currentAdminInfo.id);
    currentAdminInfo.name = name;
    updateSidebarProfile();
    toast('정보가 저장되었습니다','success');
  } catch(e) {
    toast('저장 오류: ' + e.message,'error');
  }
}

async function changeMyAdminPassword() {
  if (!db) return;
  const cur = $('myAdminCurrentPw')?.value;
  const nw = $('myAdminNewPw')?.value;
  const nw2 = $('myAdminNewPw2')?.value;
  const err = $('myPwError');
  err.style.display = 'none';
  if (!cur || !nw) { err.textContent='모든 항목을 입력해주세요'; err.style.display='block'; return; }
  if (nw.length < 8) { err.textContent='새 비밀번호는 8자 이상이어야 합니다'; err.style.display='block'; return; }
  if (nw !== nw2) { err.textContent='비밀번호가 일치하지 않습니다'; err.style.display='block'; return; }
  try {
    const {error} = await db.auth.updateUser({password: nw});
    if (error) { err.textContent = error.message; err.style.display='block'; return; }
    toast('비밀번호가 변경되었습니다','success');
    $('myAdminCurrentPw').value = '';
    $('myAdminNewPw').value = '';
    $('myAdminNewPw2').value = '';
  } catch(e) {
    err.textContent = '변경 오류: ' + friendlyError(e.message); err.style.display='block';
  }
}

// ════════════════════════════════════════════════════════════════════
// SECTION: ADMIN-ACCOUNTS — 추가/편집/삭제 모달 + 초대(RPC) + 비밀번호
// ════════════════════════════════════════════════════════════════════

function openAddAdminModal() {
  $('addAdminModalTitle').textContent = '관리자 추가';
  $('editAdminId').value = '';
  $('adminFormEmail').value = '';
  $('adminFormEmail').disabled = false;
  $('adminFormName').value = '';
  $('adminFormRole').value = 'campaign_admin';
  $('adminFormBtn').textContent = '추가';
  $('adminFormError').style.display = 'none';
  const inviteNotice = document.getElementById('adminFormInviteNotice');
  if (inviteNotice) inviteNotice.style.display = '';
  $('addAdminModal').classList.add('open');
}

function openEditAdmin(id, email, name, role) {
  $('addAdminModalTitle').textContent = '관리자 수정';
  $('editAdminId').value = id;
  $('adminFormEmail').value = email;
  $('adminFormEmail').disabled = true;
  $('adminFormName').value = name;
  $('adminFormRole').value = role;
  $('adminFormBtn').textContent = '저장';
  $('adminFormError').style.display = 'none';
  const inviteNotice = document.getElementById('adminFormInviteNotice');
  if (inviteNotice) inviteNotice.style.display = 'none';
  $('addAdminModal').classList.add('open');
}

async function saveAdmin() {
  if (!db) return;
  const err = $('adminFormError');
  err.style.display = 'none';
  const editId = $('editAdminId').value;

  if (editId) {
    // 수정 모드
    const name = $('adminFormName').value.trim();
    const role = $('adminFormRole').value;
    try {
      await retryWithRefresh(() => db?.from('admins').update({name, role}).eq('id', editId));
      toast('관리자 정보가 수정되었습니다','success');
      closeModal('addAdminModal');
      loadAdminAccounts();
    } catch(e) {
      err.textContent = '수정 오류: ' + friendlyError(e.message); err.style.display = 'block';
    }
  } else {
    // 추가 모드 (초대 플로우)
    const email = $('adminFormEmail').value.trim();
    const name = $('adminFormName').value.trim();
    const role = $('adminFormRole').value;
    if (!email || !name) { err.textContent = '모든 항목을 입력해주세요'; err.style.display = 'block'; return; }
    try {
      const {data, error} = await db.rpc('invite_admin', {
        admin_email: email, admin_name: name, admin_role: role
      });
      if (error) throw error;

      // 초대 메일 발송 (비밀번호 설정 링크)
      const redirectUrl = location.origin + '/#reset-pw';
      const {error: mailErr} = await db.auth.resetPasswordForEmail(email, {redirectTo: redirectUrl});
      if (mailErr) {
        toast('관리자 등록 성공. 단 초대 메일 발송 실패: ' + friendlyError(mailErr.message), 'error');
      } else {
        toast('관리자가 추가되었습니다. 초대 이메일이 발송되었습니다.', 'success');
      }
      closeModal('addAdminModal');
      loadAdminAccounts();
    } catch(e) {
      err.textContent = '추가 오류: ' + friendlyError(e.message); err.style.display = 'block';
    }
  }
}

function openDeleteAdminModal(adminId, authId, email) {
  const modal = document.getElementById('deleteAdminModal');
  if (!modal) return;
  document.getElementById('deleteAdminEmail').textContent = email;
  document.getElementById('deleteAdminAuthId').value = authId;
  document.getElementById('deleteAdminAdminId').value = adminId;
  modal.classList.add('open');
}

function closeDeleteAdminModal() {
  document.getElementById('deleteAdminModal')?.classList.remove('open');
}

async function executeRemoveRole() {
  if (!db) return;
  const authId = document.getElementById('deleteAdminAuthId').value;
  if (!authId) return;
  try {
    const { error } = await db.rpc('remove_admin_role', { target_auth_id: authId });
    if (error) throw error;
    toast('관리자 권한이 해제되었습니다 (인플루언서 계정은 유지)', 'success');
    closeDeleteAdminModal();
    loadAdminAccounts();
  } catch(e) {
    toast('권한 해제 오류: ' + friendlyError(e.message), 'error');
  }
}

async function executeDeleteCompletely() {
  if (!db) return;
  const authId = document.getElementById('deleteAdminAuthId').value;
  if (!authId) return;
  try {
    const { error } = await db.rpc('delete_admin_completely', { target_auth_id: authId });
    if (error) throw error;
    toast('계정이 완전 삭제되었습니다', 'success');
    closeDeleteAdminModal();
    loadAdminAccounts();
  } catch(e) {
    toast('삭제 오류: ' + friendlyError(e.message), 'error');
  }
}

function openResetPwModal(authId, email) {
  $('resetPwTargetId').value = authId;
  $('resetPwTargetEmail').textContent = email;
  $('resetPwNew').value = '';
  $('resetPwError').style.display = 'none';
  $('resetPwModal').classList.add('open');
}

async function executeResetPw() {
  if (!db) return;
  const authId = $('resetPwTargetId').value;
  const newPw = $('resetPwNew').value;
  const err = $('resetPwError');
  err.style.display = 'none';
  if (!newPw || newPw.length < 8) { err.textContent = '비밀번호는 8자 이상이어야 합니다'; err.style.display = 'block'; return; }
  try {
    const {error} = await db.rpc('reset_admin_password', {target_auth_id: authId, new_password: newPw});
    if (error) throw error;
    toast('비밀번호가 초기화되었습니다','success');
    closeModal('resetPwModal');
  } catch(e) {
    err.textContent = '초기화 오류: ' + friendlyError(e.message); err.style.display = 'block';
  }
}

async function sendResetEmail() {
  if (!db) return;
  const email = $('resetPwTargetEmail').textContent;
  try {
    const {error} = await db.auth.resetPasswordForEmail(email);
    if (error) throw error;
    toast(`${email}로 재설정 링크를 보냈습니다`,'success');
    closeModal('resetPwModal');
  } catch(e) {
    toast('이메일 발송 오류: ' + friendlyError(e.message),'error');
  }
}

