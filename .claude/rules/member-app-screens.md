---
description: 회원 앱 화면 — 캠페인 목록·상세·마이페이지·메뉴·알림·수신 설정·푸터
paths:
  - "dev/js/campaign.js"
  - "dev/js/application.js"
  - "dev/js/app.js"
  - "dev/js/mypage.js"
  - "dev/js/notifications.js"
  - "dev/js/event-ticket.js"
  - "dev/js/messaging.js"
  - "dev/js/ui.js"
  - "dev/index.html"
  - "dev/lib/storage.js"
  - "dev/lib/legal.js"
  - "docs/email-templates/*promo*"
---

# 회원 앱 화면 (CLAUDE.md 인플루언서 기능 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **캠페인 목록**: 채널·모집유형 필터. 노출 대상은 active + scheduled + closed(노출 ON)
- **캠페인 카드 배지**: 좌상단 `募集中`(active), 우상단 `NEW`(7일 이내), 제목 위 `締切間近`(deadline<5일 또는 잔여 slots≤30%), 콘텐츠 종류 아래 모집타입 pill + `{applied}/{slots}名` 슬롯 카운트, 이미지 좌하단 첫 채널+`+N`
- **캠페인 목록 탭별 주소**: `#campaigns`·`#campaigns-reviewer`·`-gifting`·`-visit`. 판정은 `isCampaignsHash`·`campPageTypeFromHash`(campaign.js) **두 함수로만** — `'campaigns'` 와 정확히 같은지로 판정하는 자리를 새로 만들면 탭 주소에서 빈 화면. 탭 클릭은 `pushState`(메타 픽셀이 페이지뷰 1건으로 셈), 같은 탭 재클릭은 무동작. 🔴 `loadCampaignsPage(목표 주소)` — 부르기 전 `location.hash` 를 읽지 말 것. 사양서 `docs/specs/2026-09-30-campaign-list-tab-url.md`
- **상세 뒤로 단추 = 온 곳으로**: 출처(`_detailFrom` 응모이력/홈/목록+탭)와 단추 이름은 `openCampaign()` **한 곳에서 떠 있던 화면으로** 정한다(상세 안 재호출은 유지). ⚠️ 이름표는 초대 게이트 갈래보다 **앞**에서 붙인다. `history.back()` 금지(직접 진입이면 사이트를 떠난다)
- **캠페인 상세**: 이미지 캐러셀(최대9장), 상품정보·모집조건·참가방법·가이드라인·NG, LINE/Instagram CTA, 조회수 카운트, closed 시 신청버튼 비활성(募集締切). 채널 pill 사이에 `or` 또는 `&` 구분자 (`channel_match`)
- **마이페이지**: 입력 폼 7종(応募履歴/基本情報/SNSアカウント/配送先/PayPal/パスワード変更/メール受信設定) 컨테이너(`#mypage-list` 제거). 진입은 햄버거 「マイページ」 서브항목, 백버튼 없음. `navigate('mypage')`·`#mypage`/`#mypage-*` popstate 는 応募履歴(`closeMypageSub`)로. 대표SNS 선택, 미입력 "未登録" 배지(`computeProfileBadges`)
- **마이페이지 저장 단추·떠날 때 확인**(2026-10-06 사용자 결정, `mypage.js`): 저장 단추는 **바뀐 값이 있을 때만** 켠다 — 기본정보·SNS·배송지는 `loadMyPage` 가 칸을 채운 **뒤** 잡은 기준값(`snapshotMypageForms`)과 비교, PayPal 은 저장된 주소와 다르고 확인 칸까지 채워지면, 비밀번호는 세 칸이 다 채워지면. 형식 오류는 지금처럼 **누른 뒤** 안내(끄는 조건에 넣지 않는다). 바뀐 채 떠나면 「変更した内容を保存しますか？」 창(`#mypageLeaveOverlay`) — 단추 **둘**(「保存する」·「保存せずに移動」) + 오른쪽 위 닫기(`cancelMypageLeave` — 이동을 그만두고 그 폼에 머문다, 사용자 요청), 저장 실패면 이동하지 않는다
  - 🔴 **「바뀐 값이 있다」의 판정은 그 폼의 저장 단추가 켜져 있느냐 하나**(`mypageDirtyView`) — 따로 세면 「단추는 꺼졌는데 나갈 때 묻는」 어긋남이 생긴다
  - 🔴 **`navigate()` 가드는 목적지가 마이페이지여도 건다** — `navigate('mypage')` 는 `loadMyPage` 로 칸을 서버 값으로 **다시 채워** 고친 내용을 조용히 지운다(햄버거로 다른 폼에 갈 때 이 경로). 활동관리 확인과 같은 자리·같은 방식(false 반환 + 주소 되돌림 `restoreMypageHash`). 고른 뒤 같은 이동을 `_mypageLeaveBypass` 로 다시 실행 — 막힌 동안 이어서 불린 `openMypageSub` 와 뒤로가기의 목적지 폼은 보류 기록에 적힌다
  - 🔴 **`navigate()` 를 안 거치고 페이지를 통째로 다시 부르는 길이 둘 있다** — 상단 로고(`onGnbLogoClick`, `window.location.href='/'`)와 당겨서 새로고침. 둘 다 `mypageLeaveGuardHref` 를 따로 부른다(로고로는 묻지 않고 나가지던 결함, 2026-10-06 사용자 발견). 새로 `location.href`·`reload` 로 이동하는 자리를 만들면 같이 걸 것
  - ⚠️ **코드가 값을 바꾸는 자리는 입력 신호가 안 난다** — 주소 검색(`lookupZipProfile`, `ui.js`)은 `change` 를 쏘고 SNS 핸들 정리는 `refreshMypageSaveButtons` 를 직접 부른다. 새로 그런 자리를 만들면 같이 할 것
  - ⚠️ 대표 SNS·도도부현 선택 칸은 서버 값이 없으면 **빈 값으로 되돌린다**(예전엔 그대로 둬서 「저장하지 않고 이동」 뒤 고르다 만 값이 남았다). 탭 닫기·새로고침은 묻지 않는다(브라우저 기본 영어 창뿐이라 범위 밖)
- **메일 수신 설정**(`#mypage-email-settings`): 마케팅 메일 ON/OFF + 업무 알림 상시 발송 안내. ON → `resubscribe_marketing()`(`marketing_agreed_at` 갱신 — 특정전자메일법 동의 근거), OFF → `influencers.marketing_opt_in=false` + `marketing_unsubscribed_at` 본인 행 UPDATE. `storage.js` `resubscribeMarketing()`/`updateMarketingOptIn(value)`(ON 은 RPC 위임 — 동의시각 누락 차단)
- **메일 수신거부 라우트**(`#unsubscribe?token=...`): 홍보 메일 하단 1-click 수신거부. 비로그인·토큰만으로 `unsubscribe_by_token(token)` 익명 RPC → 성공/무효 화면(무효·만료는 「リンクが無効です」). `app.js` 가 쿼리 붙은 해시(`#unsubscribe?token=`)를 파싱해 `handleUnsubscribePage(token)`. ⚠️ **템플릿의 수신거부 줄은 지우지 말 것** — 일본 특정전자메일법 필수 표시다(한때 주석으로 빠진 채 몇 달간 아무도 몰랐다)
- **GNB 햄버거 메뉴**: ☰ 미읽음 배지(9+), 우측 슬라이드. 로그인 시 — 계정 카드(이름·SNS핸들·이메일 + **알림 벨**·배지) → 홈/캠페인 → 「マイページ」 아코디언(기본 펼침, 서브 7종 각 `min-height:48px`, 「未登録」 배지) → ログアウト → 退会する(`margin-top`). **メッセージ 항목 없음**(메시지는 응모이력 카드, 답장은 `message_received` 알림), **通知는 벨로 통합**. 열 때 프로필 새로고침(`_lastUnread` 캐시 → `applyNotifBadge`). 찌부러짐 방지 `.nav-menu>*{flex-shrink:0}` 필수. 비로그인은 로그인/회원가입, 인증 페이지에선 숨김
- **알림 모달**: deliverables.status 트리거 알림 3종(rejected/changed/approved). 클릭 시 읽음 + 활동관리로. "모두 읽음" 버튼
- **응모이력**: **상태 드롭다운**(進行中[심사중+당첨, 기본]/すべて/審査中/当選/落選/取消, 건수 병기), 캠페인상태/채널/정렬 필터. 진행중 0건이면 「すべて表示」 안내. 승인 캠페인 클릭→활동관리, 기타→캠페인 상세
- **홈 하단 푸터**: 株式会社ジェイファン 회사 정보 + 会社紹介/利用規約/個人情報処理方針 링크 (슬라이드업 모달), Instagram·X SNS 아이콘
- **성능 최적화**: preconnect(Supabase/Fonts/jsDelivr), 썸네일 lazy loading + decoding=async, **캠페인 사진은 올릴 때 저장한 720px 썸네일**(아래 Rules 「캠페인 사진 썸네일」), 로드 실패 시 원본 URL 폴백

## CLAUDE.md Rules 절에서 옮겨 온 것 — 캠페인 목록 보관 (2026-10-01 조각 D′)
- **인플루언서 앱 캠페인 목록 보관**(2026-09-30, `campaign.js` `getCampaignsCached`): 받아 둔 목록으로 먼저 그리고 뒤에서 새로 받아 **바뀌었을 때만** 다시 그린다(10초 안이면 안 받음). ⚠️ 신청 인원을 바꾸는 동작(응모·취소·행사 예약·예약 취소) 뒤에는 **`invalidateCampaignsCache()`** — 새 경로를 만들면 함께. ⚠️ `fetchCampaigns` 자체는 관리자도 써서 **보관하지 않는다**(편집 직후 최신값 필요)
