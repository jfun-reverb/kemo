// ══════════════════════════════════════
// AUTH — 로그인, 회원가입, 로그아웃
// ══════════════════════════════════════

function updateGnb() {
  const gnbRight = $('gnbRight');
  // GNB 우측은 항상 비움 (로그인/가입은 하단 CTA, Admin은 햄버거 메뉴)
  if (gnbRight) gnbRight.innerHTML = '';
  // GNB 알림 버튼: 로그인한 인플루언서만 노출. display='' 면 CSS 규칙 따름(웹 none / iOS flex) → iOS 앱에서만 보임.
  const gnbNotifBtn = $('gnbNotifBtn');
  if (gnbNotifBtn) gnbNotifBtn.style.display = (currentUser && !currentUser._isAdmin) ? '' : 'none';
  // 햄버거 메뉴 항목 갱신 (비로그인/관리자 분기)
  if (typeof renderNavMenu === 'function') renderNavMenu();
  if (typeof refreshNotifBadge === 'function') refreshNotifBadge();
  if (typeof updateFloatingAuthCta === 'function') updateFloatingAuthCta();
}

// 생년월일 년/월/일 select 채우기 (멱등). prefix 로 가입('signup')·응모 게이트('gate') 공용.
// 가입 폼 입력을 바꾸면 즉시 에러 문구를 지움 (값을 고쳐도 에러가 다음 제출까지 남는 문제 방지)
function bindSignupErrorClear() {
  const area = $('signupFormArea'), errEl = $('signupError');
  if (!area || !errEl || area.dataset.errClearBound) return;
  area.dataset.errClearBound = '1';
  const clear = () => { errEl.style.display = 'none'; };
  area.addEventListener('input', clear);   // 텍스트·이메일·비밀번호
  area.addEventListener('change', clear);  // 생년월일·성별 select
}

function populateBirthdateSelects(prefix) {
  prefix = prefix || 'signup';
  if (prefix === 'signup') bindSignupErrorClear();
  const yEl = $(prefix+'BirthYear'), mEl = $(prefix+'BirthMonth'), dEl = $(prefix+'BirthDay');
  if (!yEl || !mEl || !dEl || yEl.dataset.filled) return;
  const curY = new Date().getFullYear();
  for (let y = curY; y >= 1940; y--) {
    const o = document.createElement('option'); o.value = String(y); o.textContent = String(y); yEl.appendChild(o);
  }
  for (let mo = 1; mo <= 12; mo++) {
    const o = document.createElement('option'); o.value = String(mo); o.textContent = String(mo); mEl.appendChild(o);
  }
  for (let d = 1; d <= 31; d++) {
    const o = document.createElement('option'); o.value = String(d); o.textContent = String(d); dEl.appendChild(o);
  }
  yEl.dataset.filled = '1';
}

async function handleSignup(e) {
  e.preventDefault();
  const name = ($('signupNameKanji')?.value||'').trim();
  const nameKana = ($('signupNameKana')?.value||'').trim();
  const birthYear = $('signupBirthYear')?.value || '';
  const birthMonth = $('signupBirthMonth')?.value || '';
  const birthDay = $('signupBirthDay')?.value || '';
  const gender = $('signupGender')?.value || '';
  const email = $('signupEmail').value.trim();
  const pw = $('signupPw').value;
  const pw2 = $('signupPw2').value;
  const errEl = $('signupError');
  const btn = $('signupBtn');

  errEl.style.display='none';
  if (!name || !nameKana) { errEl.textContent=t('authError.enterName'); errEl.style.display='block'; return; }
  // 생년월일 필수 + 유효 날짜 + 만 18세 이상 검증
  if (!birthYear || !birthMonth || !birthDay) { errEl.textContent=t('authError.enterBirthdate'); errEl.style.display='block'; return; }
  const birthdate = `${birthYear}-${String(birthMonth).padStart(2,'0')}-${String(birthDay).padStart(2,'0')}`;
  const bdObj = new Date(birthdate + 'T00:00:00+09:00');
  if (isNaN(bdObj.getTime()) || (bdObj.getMonth()+1) !== Number(birthMonth) || bdObj.getDate() !== Number(birthDay)) {
    errEl.textContent=t('authError.invalidBirthdate'); errEl.style.display='block'; return;
  }
  const age = calcAgeFromBirthdate(birthdate);
  if (age === null || age < AGE_POLICY_MIN_AGE) { errEl.textContent=t('authError.under18'); errEl.style.display='block'; return; }
  // 성별 필수 (回答しない 포함 4종 — 빈 값만 차단)
  if (!gender) { errEl.textContent=t('authError.enterGender'); errEl.style.display='block'; return; }
  if (pw !== pw2) { errEl.textContent = (typeof t==='function') ? t('auth.pwMismatch', 'パスワードが一致しません。') : 'パスワードが一致しません。'; errEl.style.display='block'; return; }
  const pwErr = validatePasswordPolicy(pw);
  if (pwErr) { errEl.textContent = pwErr; errEl.style.display='block'; return; }
  if (!$('agreeTerms')?.checked || !$('agreePrivacy')?.checked) {
    errEl.textContent = t('authError.agreeRequired');
    errEl.style.display = 'block';
    return;
  }
  const marketingOptIn = !!$('agreeMarketing')?.checked;

  btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  const nowIso = new Date().toISOString();
  const userData = {
    email, name, name_kanji: name, name_kana: nameKana,
    birthdate, gender,
    terms_agreed_at: nowIso,
    privacy_agreed_at: nowIso,
    marketing_opt_in: marketingOptIn,
    marketing_agreed_at: marketingOptIn ? nowIso : null,
    created_at: nowIso
  };

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.signup.btn'); return;
  }

  // 탈퇴 후 재가입 제한 기간인가 (마이그레이션 361·362 — 작업 11)
  //   ⚠️ 이 대조는 **방어선이 아니다** — 막는 것은 서버 트리거(362)다. 여기서 먼저
  //     걸러 주는 이유는 셋이다: ①서버 거부는 인증 서비스가 일반 오류로 덮어 회원이
  //     이유를 알 수 없다 ②그 오류가 관리자 오류 로그에 「미해결」로 쌓인다
  //     ③그런데 그 오류는 「정상 거부」 목록에 넣을 수 없다(일반 문구를 넣으면 진짜
  //     데이터베이스 장애까지 함께 침묵한다).
  //   ⚠️ 조회에 실패하면 **가입을 막지 않는다** — 서버가 최종 방어선이고, 통신 장애로
  //     정상 가입을 막는 쪽이 훨씬 나쁘다.
  if (typeof isEmailWithdrawalBlocked === 'function') {
    const blocked = await isEmailWithdrawalBlocked(email);
    if (blocked === true) {
      // ⚠️ 여기만 innerHTML 을 쓴다 — 연락처를 **누를 수 있는 링크**로 줘야 하기
      //   때문이다(2026-08-20 사용자 지시: 「안 되면 어디로 연락하는지 같이 안내」).
      //   넣는 값은 번역 파일의 고정 문구라 사용자 입력이 섞이지 않는다.
      showSignupFailure(errEl);
      errEl.style.display='block';
      btn.disabled=false; btn.textContent=t('auth.signup.btn');
      return;
    }
  }

  try {
    const {data, error} = await db.auth.signUp({email, password: pw});
    // 계정 열거 방지: 이미 가입된 이메일 등 서버 원문(영문) 노출 금지, 모호한 일반 메시지로 통일
    // 문구는 그대로 모호하게 두되, 원문은 기록해 둔다(기가입 등 정상 거부는 자동 구분됨).
    if (error) { logAppError('handleSignup', error); showSignupFailure(errEl); btn.disabled=false; btn.textContent=t('auth.signup.btn'); return; }
    if (data.user?.id) {
      // 이메일 확인 대기 중인 경우 (identities가 비어있음)
      if (!data.session && data.user) {
        btn.disabled=false; btn.textContent=t('auth.signup.btn');
        errEl.style.display='none';
        $('signupFormArea').style.display='none';
        $('signupConfirmMsg').style.display='block';
        return;
      }
      try {
        await upsertInfluencer({id: data.user.id, ...userData});
      } catch(dbErr) {
        // ⚠️ 계정은 만들어졌는데 프로필 행이 안 생긴 상태로 넘어간다(무음).
        //    가입은 성공한 것처럼 보이므로 기록이 없으면 영영 드러나지 않는다.
        logAppError('handleSignup.upsertInfluencer', dbErr);
      }
      currentUser = data.user;
      currentUserProfile = {id: data.user.id, ...userData};
    }
  } catch(e) {
    // 영문 예외 메시지 노출 금지 — 일반 안내로 통일
    logAppError('handleSignup', e);
    showSignupFailure(errEl);
    btn.disabled=false; btn.textContent=t('auth.signup.btn'); return;
  }

  toast(t('auth.toast.welcome'),'success');
  updateGnb();
  btn.disabled=false; btn.textContent=t('auth.signup.btn');
  // 초대 링크로 들어와 가입한 경우 그 캠페인으로 되돌린다(사양서 §2-8 U7).
  //   안 돌려보내면 가입만 하고 이탈한다 — 첫날 초대분이 그대로 새는 자리다.
  if (typeof consumeInviteReturn === 'function' && consumeInviteReturn()) return;
  navigate('home');
}

async function handleLogin(e) {
  e.preventDefault();
  const email = $('loginEmail').value.trim();
  const pw = $('loginPw').value;
  const errEl = $('loginError');
  const btn = $('loginBtn');
  errEl.style.display='none'; btn.disabled=true; btn.innerHTML='<span class="spinner"></span>';

  if (!db) {
    errEl.textContent=t('authError.serverError'); errEl.style.display='block';
    btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
  }

  try {
    const {data, error} = await db.auth.signInWithPassword({email, password: pw});
    if (error) {
      // 비밀번호 오입력·메일 미확인은 정상 거부로 자동 분류된다(shared.js 패턴 목록).
      logAppError('handleLogin', error);
      if (error.message?.includes('Email not confirmed')) {
        errEl.textContent=t('authError.emailUnverifiedDetail');
      } else {
        errEl.textContent=t('authError.checkCredentials');
      }
      errEl.style.display='block';
      btn.disabled=false; btn.textContent=t('auth.login.btn'); return;
    }
    currentUser = data.user;
    // 관리자 테이블에서 확인
    const {data:adminData} = await db.from('admins').select('*').eq('auth_id', data.user.id).maybeSingle();
    if (adminData) {
      currentUser._isAdmin = true;
      currentUserProfile = {name: adminData.name || 'Admin', email};
      toast(t('auth.toast.adminLogin'),'success'); updateGnb();
      // 앱 번들에는 관리자 페이지가 없다. /admin/ 으로 보내면 Capacitor 가 그 주소에서
      // 인플루언서 index.html 을 대신 띄우고, 상대경로 자산(ios-theme.css 등)이 404 나서
      // 테마가 통째로 빠진 화면이 된다. 앱에서는 인플루언서 화면에 그대로 머문다.
      const _isNativeApp = !!(window.Capacitor && window.Capacitor.isNativePlatform && window.Capacitor.isNativePlatform());
      if (_isNativeApp) {
        navigate('home');
      } else {
        window.location.href = '/admin/';
      }
    } else {
      const {data:profile} = await db.from('influencers').select('*').eq('id', data.user.id).maybeSingle();
      currentUserProfile = profile;
      // 프로필이 없으면 기본 프로필 생성 (회원가입 시 RLS로 실패한 경우)
      if (!profile) {
        try {
          await upsertInfluencer({id: data.user.id, email, created_at: new Date().toISOString()});
          currentUserProfile = {id: data.user.id, email};
        } catch(e) {
          // ⚠️ 프로필 없는 계정을 되살리는 마지막 구제 경로다. 여기까지 실패하면
          //    그 사람은 프로필 없이 앱을 쓰게 되는데 지금까지 무음이었다.
          logAppError('handleLogin.upsertInfluencer', e);
        }
      }
      toast(t('auth.toast.welcomeBack'),'success'); updateGnb();
      // 네이티브 앱(iOS)에서만 푸시 권한 요청 + 토큰 등록. 웹엔 _enablePush 가 없어 no-op.
      //   초대 복귀보다 먼저 — 아래 return 뒤에 두면 초대 링크로 들어온 사람만 푸시 등록이 빠진다.
      if (window._enablePush) { try { window._enablePush(); } catch(e){} }
      // 초대 링크로 들어와 로그인한 경우 그 캠페인으로 되돌린다(가입 경로와 같은 이유).
      if (typeof consumeInviteReturn === 'function' && consumeInviteReturn()) return;
      navigate('home');
    }
  } catch(e) {
    logAppError('handleLogin', e);
    errEl.textContent=t('authError.genericError'); errEl.style.display='block';
  }
  btn.disabled=false; btn.textContent=t('auth.login.btn');
}

async function handleLogout() {
  // 로그아웃 전에 이 기기의 푸시 토큰 해지 (signOut 후엔 auth.uid()가 사라져 해지 불가).
  //   웹엔 _revokePushOnLogout 가 없어 no-op.
  if (window._revokePushOnLogout) { try { await window._revokePushOnLogout(); } catch(e){} }
  if (db) { try { await db.auth.signOut(); } catch(e){} }
  currentUser=null; currentUserProfile=null;
  toast(t('auth.toast.loggedOut')); updateGnb(); navigate('home');
}

// ── 비밀번호 재설정 ──
async function handleForgotPassword(e) {
  e.preventDefault();
  const email = $('forgotEmail').value.trim();
  const errEl = $('forgotError');
  const successEl = $('forgotSuccess');
  const btn = $('forgotBtn');

  errEl.style.display = 'none';
  successEl.style.display = 'none';

  if (!db) {
    errEl.textContent = t('authError.serverError');
    errEl.style.display = 'block';
    return;
  }

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>';

  try {
    // 보조 클라이언트로 요청 — 다른 기기에서도 열 수 있는 토큰을 받기 위함(supabase.js 주석 참조).
    // redirectTo 는 일부러 넘기지 않는다: 넘기면 인증 서버가 그 주소를 검증·정규화하면서
    //   `#` 뒷부분을 통째로 버려(`.../#` 만 남음) 착지 화면을 못 찾는다.
    //   되돌아갈 주소는 메일 서식이 `{{ .SiteURL }}/#reset-pw?token_hash=...` 로 직접 만든다.
    const authClient = (typeof dbAuthRequest !== 'undefined' && dbAuthRequest) ? dbAuthRequest : db;
    const {error} = await authClient.auth.resetPasswordForEmail(email);
    if (error) {
      // 영문 서버 메시지·계정 존재 힌트 노출 금지 — 일반 안내로 통일.
      //   ⚠️ 인플루언서 비밀번호 찾기는 실제로 고장 난 적이 있는 경로다(2026-07-20).
      //      화면 문구는 그대로 두고 원인만 남긴다.
      logAppError('handleForgotPassword', error);
      errEl.textContent = t('authError.genericError');
      errEl.style.display = 'block';
    } else {
      successEl.textContent = t('auth.forgot.successMsg');
      successEl.style.display = 'block';
      $('forgotForm').reset();
    }
  } catch (err) {
    logAppError('handleForgotPassword', err);
    errEl.textContent = t('authError.genericError');
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = t('auth.forgot.btn');
}

async function handleResetPassword(e) {
  e.preventDefault();
  const pw = $('resetPwNew').value;
  const pw2 = $('resetPwConfirm').value;
  const errEl = $('resetPwError');
  const btn = $('resetPwBtn');

  errEl.style.display = 'none';

  const pwErr = validatePasswordPolicy(pw);
  if (pwErr) {
    errEl.textContent = pwErr;
    errEl.style.display = 'block';
    return;
  }
  if (pw !== pw2) {
    errEl.textContent = (typeof t==='function') ? t('auth.pwMismatch') : 'パスワードが一致しません';
    errEl.style.display = 'block';
    return;
  }

  if (!db) {
    errEl.textContent = t('authError.serverError');
    errEl.style.display = 'block';
    return;
  }

  btn.disabled = true;
  btn.innerHTML = '<span class="spinner"></span>';

  try {
    const {error} = await db.auth.updateUser({password: pw});
    if (error) {
      // 영문 서버 메시지 노출 금지 — 일반 안내로 통일
      logAppError('handleResetPassword', error);
      // 「세션 없음」은 링크가 만료됐거나 이미 쓰인 것이다. 일반 문구로 덮으면
      //   사용자는 **무엇을 해야 할지 알 수 없다**(2026-08-08 운영 오류 1건 — 아이폰 사파리).
      //   이미 있는 만료 안내 화면(다시 보내기 버튼 포함)으로 보낸다.
      if (/Auth session missing/i.test(String(error.message || ''))) {
        const _f = $('resetPwFormWrap'), _x = $('resetPwExpired');
        if (_f && _x) { _f.style.display = 'none'; _x.style.display = ''; }
        else { errEl.textContent = t('authError.genericError'); errEl.style.display = 'block'; }
        try { sessionStorage.removeItem('reverb.recovery'); } catch(_e) {}
        btn.disabled = false;
        btn.textContent = t('auth.reset.btn');
        return;
      }
      // 「예전과 같은 비밀번호」도 같은 이유로 갈라낸다 — 이 화면은 지금 쓰는 비밀번호를
      //   입력받지 않아 화면에서 미리 막을 수 없고, **서버가 거부한 뒤에야** 알 수 있다.
      //   일반 문구로 덮으면 왜 안 되는지 몰라 같은 비밀번호를 다시 넣게 된다 —
      //   운영에서 한 사람이 **5번 반복**했다(2026-08-11~12 오류 로그).
      //   ⚠️ 서버 영문 메시지를 그대로 보여주지 않는다. 마이페이지 비밀번호 변경이 이미
      //      쓰는 번역 문구(auth.pwSameAsCurrent)를 **같이** 쓴다 — 두 화면이 같은 말을 해야 한다.
      if (/different from the old password/i.test(String(error.message || ''))
          || String(error.code || '') === 'same_password') {
        errEl.textContent = t('auth.pwSameAsCurrent');
        errEl.style.display = 'block';
        btn.disabled = false;
        btn.textContent = t('auth.reset.btn');
        return;
      }
      errEl.textContent = t('authError.genericError');
      errEl.style.display = 'block';
    } else {
      try { sessionStorage.removeItem('reverb.recovery'); } catch(e) {}
      await db.auth.signOut();
      toast(t('profile.pwChanged'), 'success');
      navigate('login');
    }
  } catch (err) {
    logAppError('handleResetPassword', err);
    errEl.textContent = t('authError.genericError');
    errEl.style.display = 'block';
  }

  btn.disabled = false;
  btn.textContent = t('auth.reset.btn');
}


// ══════════════════════════════════════
// 탈퇴가 확정된 계정을 로그아웃시킨다 (마이그레이션 358·359 — 작업 8)
//
//   ⚠️ 이건 **보조 장치**다. 최종 방어선은 서버의 차단 장치(359)이고, 이 함수는
//      화면을 안 거치는 사람까지 막지 못한다. 그래도 필요한 이유는, 파기로 비워진
//      마이페이지를 회원이 계속 들여다보며 **다시 입력하라고 재촉받는** 상태를
//      끊어 주기 때문이다.
//
//   ★ **`login_blocked` 만 본다 — `write_blocked` 를 쓰면 안 된다.**
//      예정일이 지났지만 예약 실행이 아직 안 돈 구간의 회원까지 로그아웃시키면
//      **탈퇴 취소 버튼에 닿지 못한다.** 취소는 회원에게 유리한 동작이다.
//
//   ⚠️ 조회에 실패하면 **아무것도 하지 않는다**(fail-open). 통신 장애로 정상 회원을
//      쫓아내는 쪽이 훨씬 나쁘고, 서버가 최종 방어선이라 실피해가 없다.
//      (마이그레이션 276 이 세운 「서버에 못 물어본 경우엔 막지 않는다」 원칙)
// ══════════════════════════════════════
let _withdrawalLogoutChecked = false;

async function enforceWithdrawalLogout() {
  // 같은 세션에서 두 번 이상 돌지 않게 — 부팅과 로그인 이벤트 양쪽에서 불린다
  if (_withdrawalLogoutChecked) return;
  if (!currentUser) return;
  // 관리자는 대상이 아니다(관리자를 겸한 회원은 파기 자체가 거부된다 — 마이그레이션 352)
  if (currentUser._isAdmin) return;
  if (typeof fetchMyWithdrawalState !== 'function') return;

  _withdrawalLogoutChecked = true;

  const st = await fetchMyWithdrawalState();
  // ok 가 아니거나 login_blocked 가 명시적으로 true 가 아니면 아무것도 안 한다
  if (!st || st.ok !== true || st.login_blocked !== true) return;

  const msg = typeof t === 'function' ? t('auth.withdrawnLogout')
    : '退会手続きが完了したため、ログアウトしました。ご不明な点は運営までLINEでご連絡ください。';

  try {
    await db?.auth?.signOut();
  } catch (e) {
    console.error('[enforceWithdrawalLogout] signOut', e);
  }
  currentUser = null;
  currentUserProfile = null;
  if (typeof updateGnb === 'function') updateGnb();
  if (typeof navigate === 'function') navigate('login');

  // 안내는 사라지지 않게 로그인 화면에 남긴다 — 되돌릴 수 없는 사건이라 2.8초 뒤
  //   사라지는 알림으로는 부족하다. (#loginError 는 정적 요소라 다시 그려지지 않는다)
  const errEl = typeof $ === 'function' ? $('loginError') : null;
  if (errEl) {
    errEl.textContent = msg;
    errEl.style.display = '';
  } else if (typeof toast === 'function') {
    toast(msg);
  }
}


// 회원가입 실패를 화면에 알린다 — **모든 실패가 이 함수 하나를 쓴다**
//
//   ★ **왜 실패했는지 구분해 보여주지 않는다.** 이미 가입된 이메일이든, 탈퇴 후
//     재가입 제한 기간이든, 서버 오류든 **똑같은 문구**가 뜬다.
//     구분해 보여주면 아무나 임의의 이메일로 가입을 시도해 보고 **「이 사람이 최근에
//     탈퇴했다」를 알아낼 수 있다** — 가입 화면은 누구나 열 수 있기 때문이다.
//     (2026-08-20 검토 지적: 「본인은 메일로 이미 안다」는 근거는 계정 열거 방지
//      논리로 성립하지 않는다 — 문제는 본인이 아니라 제3자다)
//   ★ **연락할 곳은 항상 함께 준다**(2026-08-20 사용자 지시). 이유를 안 알리면서 갈
//     곳도 없으면 회원은 고장으로 오해한 채 막힌다. 연락처를 **차단된 경우에만** 붙이면
//     그 자체가 구분 신호가 되므로, **모든 실패에** 붙이는 것이 두 요구를 함께 지키는
//     유일한 방법이다.
//   ⚠️ 앱 안 문의 창구가 생기면(작업 2) 이 연락처를 그것으로 바꾼다.
//   ⚠️ 여기만 innerHTML 을 쓴다 — 연락처를 **누를 수 있는 링크**로 줘야 하기 때문이다.
//     넣는 값은 번역 파일의 고정 문구라 사용자 입력이 섞이지 않는다.
function showSignupFailure(errEl) {
  if (!errEl) return;
  const msg  = typeof t === 'function' ? t('authError.signupFailed')
    : '登録に失敗しました。しばらくしてからもう一度お試しください';
  const help = typeof t === 'function' ? t('authError.signupHelp')
    : 'お困りの場合は LINE までご連絡ください。';
  errEl.innerHTML = esc(msg) + '<br>' + esc(help)
    + ' <a href="https://line.me/R/ti/p/@reverb.jp" target="_blank" rel="noopener"'
    + ' style="color:var(--pink);text-decoration:underline">@reverb.jp</a>';
  errEl.style.display = 'block';
}
