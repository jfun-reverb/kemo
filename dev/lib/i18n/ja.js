// ══════════════════════════════════════
// i18n — 일본어 (기본)
// ══════════════════════════════════════
window.I18N_JA = {
  common: {
    save: '保存する',
    cancel: 'キャンセル',
    confirm: '確認',
    back: '戻る',
    select: '選択してください',
    unregistered: '未登録',
    loading: '読み込み中…',
    retry: '再試行',
    close: '閉じる',
    apply: '適用',
    ok: 'OK',
  },

  // 홈
  home: {
    hero: {
      eyebrow: '🇰🇷 K-Brand × Japan Only',
      titleLine1: '韓国の人気Kブランドを',
      titleLine2: 'あなたのSNSで',
      titleLine3: '体験しよう',
      titleJp: '日本未発売の新商品を、インフルエンサー限定で無償体験',
      sub: 'K-Beautyのトレンドをいち早くあなたのフォロワーへ。厳選されたKブランドと、本当に伝えたいインフルエンサーをつなぐ体験プラットフォームです。',
      cta: '無料で体験団に参加する →',
    },
    stat: {
      freeValue: '無償',
      freeLabel: '製品は全額無料',
      priorityValue: '先行',
      priorityLabel: '日本未発売品も体験',
      chosenValue: '選考',
      chosenLabel: 'あなたの感想が選ばれる',
    },
    feature: {
      shippingTitle: '韓国直送・新商品',
      shippingDesc: '日本未発売のKブランド新商品を<br>いち早く体験できます',
      freeTitle: '完全無償提供',
      freeDesc: '製品代・送料すべて無料<br>リワード付きキャンペーンも',
      chosenTitle: 'あなたが選ばれる',
      chosenDesc: 'フォロワー数より「届ける力」<br>ナノインフルエンサー大歓迎',
    },
    section: {
      campaignsTitle: 'キャンペーン',
      campaignsSub: '今すぐ応募できる体験団',
      viewAll: 'すべて見る →',
    },
  },

  // GNB
  nav: {
    login: 'Log In',
    signup: 'Sign Up',
  },

  // 캠페인 목록 페이지
  campaigns: {
    pageTitle: 'キャンペーン一覧',
    typeAll: 'すべて',
    typeMonitor: 'Reviewer',
    typeGifting: 'ギフティング',
    typeVisit: '来店',
  },

  // 캠페인 상태
  status: {
    campaign: {
      active: '募集中',
      scheduled: '近日公開',
      closed: '締切',
      draft: '準備中',
      paused: '一時停止',
    },
  },

  // 인증
  auth: {
    pwPolicy: '8文字以上、英小文字と記号（!@#$%^&*など）を必ず含め、英大文字・数字・記号のうち2種類以上の組み合わせで作成してください。',
    pwTooShort: 'パスワードは8文字以上で入力してください。',
    pwNeedLower: 'パスワードに英小文字を1つ以上含めてください。',
    pwNeedSpecial: 'パスワードに記号（!@#$%^&*など）を1つ以上含めてください。',
    pwMismatch: 'パスワードが一致しません。',
    pwSameAsCurrent: '現在のパスワードと同じパスワードは使用できません。',
    login: {
      title: 'Log In',
      sub: 'REVERBインフルエンサーアカウントでログイン',
      emailLabel: 'Email',
      pwLabel: 'Password',
      btn: 'Log In',
      forgotLink: 'パスワードをお忘れですか？',
      switchText: 'アカウントをお持ちでないですか？',
      switchLink: '新規登録',
    },
    forgot: {
      title: 'パスワード再設定',
      sub: '登録したメールアドレスを入力してください。<br>パスワード再設定用のメールをお送りします。',
      emailLabel: 'メールアドレス',
      btn: 'リセットメールを送信',
      backLink: 'ログインに戻る',
      successMsg: 'ご入力のメールアドレスが登録されている場合、再設定メールを送信しました。メールボックス（迷惑メールフォルダも含む）をご確認ください。',
    },
    reset: {
      title: '新しいパスワード',
      sub: '新しいパスワードを入力してください。',
      newLabel: '新しいパスワード（8文字以上）',
      confirmLabel: 'パスワード確認',
      btn: 'パスワードを変更',
    },
    signup: {
      title: 'Sign Up',
      sub: 'REVERBに参加してKブランドキャンペーンを体験しよう',
      nameKanjiLabel: 'Name (Kanji)',
      nameKanaLabel: 'Name (Kana)',
      nameKanaHint: '日本語の配送先登録のため、かな名を入力してください',
      emailLabel: 'Email',
      pwLabel: 'Password',
      pwHint: '(8+ chars)',
      pwConfirmLabel: 'Confirm Password',
      agreeAll: 'すべてに同意する',
      required: '必須',
      optional: '任意',
      agreeTermsSuffix: 'に同意します',
      agreeMarketing: 'マーケティング情報の受信に同意します（キャンペーン案内・お得な情報）',
      btn: 'Sign Up',
      afterNote: 'SNS情報や配送先はマイページから後で追加できます',
      switchText: 'すでにアカウントをお持ちですか？',
      switchLink: 'Log In',
      confirmSentTitle: '確認メールを送信しました',
      confirmSentDesc: 'ご入力いただいたメールアドレスに確認メールをお送りしました。<br>メール内のリンクをクリックして登録を完了してください。<br><br>※すでに登録されているメールアドレスの場合は、下の「ログインページへ」からログインしてください。',
      confirmSentBtn: 'ログインページへ',
    },
  },

  // 마이페이지
  mypage: {
    menu: {
      applications: '応募履歴',
      basic: '基本情報',
      sns: 'SNSアカウント',
      address: '配送先',
      paypal: 'PayPal',
      password: 'パスワード変更',
      logout: 'ログアウト',
      language: '言語 / 언어',
    },
    withdraw: '退会する',
    withdrawConfirm: '本当に退会しますか？',
    withdrawToast: '退会申請を受け付けました。運営にLINEでご連絡ください。',
  },

  // 프로필 부족 알림
  profileAlert: {
    title: 'キャンペーン応募の前に',
    desc: '応募するにはマイページで「個人情報」「PayPal」の登録が必要です。<br>以下の項目を登録してください。',
    cancel: 'Cancel',
    goMypage: 'My Page',
  },

  // 로그인 프롬프트
  loginPrompt: {
    title: 'Login Required',
    desc: 'Please log in to join the campaign.',
    noAccount: "Don't have an account?",
    signupFree: 'Sign Up Free',
  },

  // 약관/개인정보 링크 라벨
  legal: {
    termsTitle: '利用規約',
    privacyTitle: '個人情報処理方針',
    about: '会社紹介',
  },
};
