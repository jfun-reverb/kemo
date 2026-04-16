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
    login: 'ログイン',
    signup: '新規登録',
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
      title: 'ログイン',
      sub: 'REVERBインフルエンサーアカウントでログイン',
      emailLabel: 'メールアドレス',
      pwLabel: 'パスワード',
      btn: 'ログイン',
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
      title: '新規登録',
      sub: 'REVERBに参加してKブランドキャンペーンを体験しよう',
      nameKanjiLabel: '氏名（漢字）',
      nameKanaLabel: '氏名（ふりがな）',
      nameKanaHint: '日本語の配送先登録のため、かな名を入力してください',
      emailLabel: 'メールアドレス',
      pwLabel: 'パスワード',
      pwHint: '（8文字以上）',
      pwConfirmLabel: 'パスワード（確認）',
      agreeAll: 'すべてに同意する',
      required: '必須',
      optional: '任意',
      agreeTermsSuffix: 'に同意します',
      agreeMarketing: 'マーケティング情報の受信に同意します（キャンペーン案内・お得な情報）',
      btn: '登録する',
      afterNote: 'SNS情報や配送先はマイページから後で追加できます',
      switchText: 'すでにアカウントをお持ちですか？',
      switchLink: 'ログイン',
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

  // 응모이력
  appHistory: {
    title: '応募履歴',
    all: 'すべて',
    pending: '審査中',
    approved: '承認',
    rejected: '非承認',
    campStatus: 'キャンペーン状態',
    sortNewest: '新しい順',
    sortOldest: '古い順',
    emptyAll: 'まだ応募したキャンペーンはありません',
    emptyFiltered: '該当する応募はありません',
    emptySub: '今すぐKブランド体験団に応募してみましょう！',
    emptyBtn: 'キャンペーンを見る',
    applyDate: '応募日',
  },

  // 하단 탭
  tab: {
    home: 'ホーム',
    campaigns: 'キャンペーン',
    mypage: 'マイページ',
  },

  // 프로필 부족 알림
  profileAlert: {
    title: 'キャンペーン応募の前に',
    desc: '応募するにはマイページで「個人情報」「PayPal」の登録が必要です。<br>以下の項目を登録してください。',
    cancel: 'キャンセル',
    goMypage: 'マイページへ',
  },

  // 로그인 프롬프트
  loginPrompt: {
    title: 'ログインが必要です',
    desc: 'キャンペーンに応募するにはログインしてください。',
    noAccount: 'アカウントをお持ちでないですか？',
    signupFree: '無料で新規登録',
  },

  // 약관/개인정보 링크 라벨
  legal: {
    termsTitle: '利用規約',
    privacyTitle: '個人情報処理方針',
    about: '会社紹介',
  },

  // 캠페인 상세
  detail: {
    recruitType: '募集タイプ',
    recruitPeriod: '募集期間',
    recruitSlots: '募集人数',
    winnerAnnounce: '当選発表',
    winnerAnnounceValue: '選考後、LINEにてご連絡',
    postDeadline: '投稿締切日',
    postDeadlineRelative: '受取後 {days}日以内',
    purchasePeriod: '購入期間',
    visitPeriod: '訪問期間',
    submissionEnd: '成果物提出締切',
    peopleUnit: '名',
    noSetting: '—',
    applyBtn: '申請',
    closedBtn: '募集締切',
    fullBtn: '募集終了',
    appliedBtn: '応募済み',
    manageBtn: '活動管理',
  },

  // 응모
  apply: {
    reasonLabel: '応募理由',
    reasonPlaceholder: 'Kブランドの体験に対する意気込みをお聞かせください',
    addressLabel: '配送先住所',
    prAgreeLabel: '#PRタグ表記に同意します',
    submitBtn: '応募する',
    needLogin: 'ログインが必要です',
    needReason: '応募理由を入力してください',
    needAddress: '配送先住所を入力してください',
    needPrAgree: '#PRタグの表記に同意が必要です',
    alreadyApplied: 'すでに応募済みのキャンペーンです',
    slotsFull: '募集人数に達したため、応募できません',
    sessionExpired: 'セッションの有効期限が切れました。再ログインしてください',
    emailUnverified: 'メールアドレスの認証が必要です。受信メールをご確認ください',
    success: '応募が完了しました！',
  },

  // 활동관리
  activity: {
    rejectedTitle: '差し戻しされました',
    rejectedHint: '修正後、再度ご提出ください。',
    submissionEndLabel: '提出期限',
    submissionEndPast: '提出期限が過ぎました',
    receiptSection: '購入レシート',
    receiptImageLabel: 'レシート画像',
    receiptImageBtn: '画像を選択',
    receiptDateLabel: '購入日',
    receiptAmountLabel: '金額（円）',
    submitBtn: '登録する',
    uploading: 'アップロード中...',
    noReceipt: 'まだレシートが登録されていません',
    postSection: '投稿URLの提出',
    postUrlLabel: '投稿URL',
    postUrlPlaceholder: 'https://www.instagram.com/p/... など',
    postChannelLabel: 'チャンネルを選択',
    postChannelHint: 'URLからチャンネルを自動判別できませんでした',
    postChannelDetected: '判別: {channel}',
    postChannelDetectFail: 'URLからチャンネルを自動判別できません',
    noPost: 'まだ投稿が登録されていません',
    submitCountLabel: '提出回数: {n}回',
    needUrl: 'URLを入力してください',
    badUrlFormat: 'URLの形式が正しくありません',
    needChannel: 'チャンネルを選択してください',
    afterDeadline: '提出期限が過ぎたため、登録できません',
    needImage: 'レシート画像を選択してください',
    receiptSuccess: 'レシートを登録しました',
    postSuccess: '投稿URLを登録しました',
    resubmitSuccess: '再提出しました',
    appendedSuccess: '提出履歴を追加しました',
    saveFail: '登録に失敗しました',
    unknownDate: '日付未入力',
    unknownAmount: '金額未入力',
  },

  // 결과물 상태 배지 (인플루언서 화면)
  delivStatus: {
    pending: '審査中',
    approved: '承認',
    rejected: '差戻',
  },

  // 알림
  notif: {
    headerN: 'お知らせ ({n})',
    markAllRead: 'すべて既読',
  },
};
