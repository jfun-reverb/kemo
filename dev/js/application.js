// ══════════════════════════════════════
// CAMPAIGN DETAIL + APPLICATION
// ══════════════════════════════════════

async function openCampaign(id) {
  const camp = allCampaigns.find(c=>c.id===id) || DEMO_CAMPAIGNS.find(c=>c.id===id);
  if (!camp) return;

  // 비공개 캠페인 진입 가드 (사양서 2026-07-29 §설계 5-(8)-1)
  //   준비중(draft)·노출종료(expired)는 목록에 안 나오지만 해시(#detail-{id})로 직접 열 수 있었고,
  //   응모 버튼까지 활성이라 마감일이 미래면 서버도 통과시켜 **응모가 실제로 접수**됐다.
  //   운영자가 숨겼다고 믿는 캠페인에 응모가 쌓이는 경로라 상세 자체를 열지 않는다.
  //   ⚠️ 단 **응모이력에서 온 진입은 막지 않는다**. 본인이 응모했던 캠페인을 관리자가 나중에
  //      노출 종료로 내리는 것은 정상 운영인데, 그때 본인 응모이력에서 상세조차 볼 수 없으면
  //      「내가 신청한 게 사라졌다」가 된다. 그 경로는 상세를 보여주고 응모 버튼만 닫는다(아래 버튼 판정).
  //   ⚠️ **관리자 미리보기(?preview=1)는 통과시킨다.** 미리보기가 정작 필요한 것이 아직
  //      공개 안 한 캠페인인데, 여기서 막으면 「준비」 상태 캠페인은 어떻게 보일지 확인할
  //      길이 아예 없다(2026-08-12 운영 보고 — 목록으로 튕기며 「공개되지 않았습니다」).
  //      미리보기는 관리자만 여는 자리라 이 가드가 막으려던 「몰래 접수되는 응모」와 무관하다
  //      (그 화면에는 응모 버튼을 눌러도 진행할 사용자 세션이 없다).
  const _isPreview = document.documentElement.classList.contains('preview-mode');
  if ((camp.status === 'draft' || camp.status === 'expired') && _detailFrom !== 'mypage' && !_isPreview) {
    if (typeof toast === 'function') toast(t('detail.notPublic'), 'error');
    if (typeof navigate === 'function') navigate('campaigns');
    return;
  }

  currentCampaignId = id;

  // 조회수 증가 (비동기, UI 차단 없음)
  incrementViewCount(id).catch(()=>{});

  let alreadyApplied = false;
  let _myApp = null;
  let hasCancelledHistory = false;
  if (currentUser) {
    // partial unique index 가 cancelled 가 아닌 행 1개만 보장하므로
    // .neq('status', 'cancelled') 로 활성 행만 단일 조회. cancelled 이력은 별도 확인.
    const {data:_appData} = await (db?.from('applications').select('*')
      .eq('user_id', currentUser.id)
      .eq('campaign_id', id)
      .neq('status', 'cancelled')
      .maybeSingle() || {data:null});
    _myApp = _appData;
    alreadyApplied = !!_myApp;
    if (!alreadyApplied) {
      // 활성 행이 없으면 본인이 이 캠페인을 과거에 cancelled 했는지 확인 → 재응모 동선
      const {data:_cancelled} = await (db?.from('applications').select('id')
        .eq('user_id', currentUser.id)
        .eq('campaign_id', id)
        .eq('status', 'cancelled')
        .limit(1)
        .maybeSingle() || {data:null});
      hasCancelledHistory = !!_cancelled;
    }
  }

  // 리뷰어(monitor)만 모집인원 초과 시 신규 응모 차단. 기프팅·방문형은 초과 응모 허용.
  // DB 트리거(048)가 최종 방어선, 여기서는 UX 보조.
  // applied_count는 수동 동기화 캐시 → 실시간 DB count로 판정 (pending+approved 기준, 트리거와 일치)
  let actualApplied = camp.applied_count || 0;
  if (camp.recruit_type === 'monitor' && db) {
    const cnt = await countActiveApplications(id);
    if (cnt > 0) actualApplied = cnt;
  }
  const isFull = camp.recruit_type === 'monitor' && actualApplied >= (camp.slots || 0);
  if (isFull && !alreadyApplied) {
    toast(t('apply.slotsFull'), 'error');
  }
  _slideIdx = 0;

  // ── 초대 전용(비공개) 캠페인 게이트 (사양서 §4-3 「초대 전용 진입」) ──
  //   확인되지 않으면 캠페인 내용을 **한 글자도 그리지 않고** 게이트만 띄운다.
  //   ⚠️ 화면 단계 방어라 우회할 수 있다. 예약을 실제로 막는 것은 서버 재검증이다.
  if (typeof canOpenInviteCampaign === 'function' && !(await canOpenInviteCampaign(camp))) {
    if (typeof renderInviteGate === 'function') renderInviteGate(camp.id);
    // 게이트 화면에는 신청 버튼을 띄우지 않는다.
    //   ⚠️ 아이디는 detailFloatBar 다. 'floatBar' 로 적으면 항상 null 이라 **조용히 안 숨겨진다**
    //      — 그러면 직전 캠페인에서 보던 「申請」 버튼이 그대로 남고, 그걸 누르면
    //      신청 모달 제목에 비공개 캠페인 이름과 주의사항이 노출된다(2026-08-03 리뷰 지적).
    const _fb = $('detailFloatBar');
    if (_fb) _fb.style.display = 'none';
    // 아이디 하나에만 기대지 않는다 — 버튼이 어떤 이유로 남아도 눌리지 않게 이중으로 끊는다.
    const _fab = $('floatApplyBtn');
    if (_fab) _fab.onclick = null;
    // 직전 캠페인에서 고른 타임이 남아 있으면 「고른 게 없는데 신청이 되는」 상태가 된다.
    _selectedEventSlotId = null;
    navigate('detail-' + id);
    return;
  }

  // 슬라이드 이미지 + 크롭 정보 매핑
  const crops = camp.image_crops || {};
  const rawSlides = [
    {url: camp.img1, key: 'img1'}, {url: camp.img2, key: 'img2'},
    {url: camp.img3, key: 'img3'}, {url: camp.img4, key: 'img4'},
    {url: camp.img5, key: 'img5'}, {url: camp.img6, key: 'img6'},
    {url: camp.img7, key: 'img7'}, {url: camp.img8, key: 'img8'},
    {url: camp.image_url, key: null}
  ].filter(s => s.url);
  const seen = new Set();
  const slideData = rawSlides.filter(s => seen.has(s.url) ? false : (seen.add(s.url), true));
  const slideImgs = slideData.map(s => s.url);

  const slideHtml = slideImgs.length > 0 ? `
    <div id="campSlider" style="position:relative;overflow:hidden;border-radius:16px;margin-bottom:0;background:${getCampGrad(camp.category)};aspect-ratio:1/1;height:auto">
      <div id="campSlides" style="display:flex;height:100%;transition:transform .32s cubic-bezier(.4,0,.2,1)">
        ${slideData.map((s,idx)=>{
          const crop = s.key ? crops[s.key] : null;
          // 첫 장(LCP)만 720, lazy 로드 나머지는 480으로 용량 절감
          const thumb = idx === 0 ? 720 : 480;
          return `<div style="flex:0 0 100%;width:100%;height:100%;position:relative;overflow:hidden;background:${getCampGrad(camp.category)}">${renderCroppedImg(s.url, crop, {thumb, quality:80, lazy: idx>0})}</div>`;
        }).join('')}
      </div>
      ${slideImgs.length>1?`
        <button onclick="slideMove(-1)" style="position:absolute;left:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:#333">chevron_left</span></button>
        <button onclick="slideMove(1)" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round notranslate" translate="no" style="font-size:20px;color:#333">chevron_right</span></button>
        <div style="position:absolute;bottom:10px;left:50%;transform:translateX(-50%);display:flex;gap:5px;z-index:5">
          ${slideImgs.map((_,i)=>`<div onclick="slideTo(${i})" id="dot${i}" style="width:${i===0?'16px':'6px'};height:6px;border-radius:3px;background:${i===0?'#fff':'rgba(255,255,255,.5)'};border:1px solid rgba(0,0,0,.06);cursor:pointer;transition:.2s"></div>`).join('')}
        </div>
        <div style="position:absolute;top:12px;right:12px;background:rgba(0,0,0,.45);color:#fff;font-size:11px;font-weight:600;padding:3px 8px;border-radius:20px;z-index:5"><span id="slideCurrentNum">1</span>/${slideImgs.length}</div>` : ''}
      <div style="position:absolute;top:12px;left:12px;display:flex;gap:5px;z-index:5">
        ${camp.content_types?camp.content_types.split(',').map(t=>`<span style="background:rgba(0,0,0,.55);color:#fff;font-size:10px;font-weight:700;padding:3px 9px;border-radius:20px;backdrop-filter:blur(4px)">${esc(getLookupLabel('content_type', t.trim()))}</span>`).join(''):''}
      </div>
    </div>` : `<div style="aspect-ratio:1/1;width:100%;border-radius:16px;background:${getCampGrad(camp.category)};display:flex;align-items:center;justify-content:center;font-size:64px">${camp.emoji||''}</div>`;

  $('detailContent').innerHTML = `
    <div class="detail-main">
      ${slideHtml}

      <div style="background:#fff;border-bottom:1px solid var(--line);margin-bottom:10px">
        <div style="padding:16px 0 12px">
          <div style="font-size:11px;color:var(--pink);font-weight:700;letter-spacing:.06em;margin-bottom:5px">${esc(brandLabelInflu(camp))}</div>
          ${camp.recruit_type ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:4px">${esc(getRecruitTypeLabelJa(camp.recruit_type))}</div>` : ''}
          <div style="font-size:18px;font-weight:800;color:var(--ink);line-height:1.3;margin-bottom:10px">${esc(camp.title)}</div>
          ${camp.product_price>0?(camp.recruit_type === 'monitor'
            // 리뷰어형 — 받는 금액이 응모 시점에 확정되지 않으므로(영수증 실결제액 기준,
            // 300) 금액을 주인공으로 세우던 마크업을 버리고 문장을 앞세운다. 상한은
            // 작은 보조 줄로 내린다. 시딩·방문형은 제품 가치가 확정이라 기존 그대로.
            ? `<div style="display:inline-block;background:var(--light-pink);border-radius:8px;padding:7px 12px;margin-bottom:4px">
                 <div style="font-size:13px;font-weight:800;color:var(--pink);line-height:1.35">${esc(t('detail.rewardPaybackFull').replace('{price}', camp.product_price.toLocaleString()))}</div>
               </div>`
            : `<div style="display:inline-flex;align-items:center;gap:6px;background:var(--light-pink);border-radius:8px;padding:6px 12px;margin-bottom:4px"><span style="font-size:17px;font-weight:900;color:var(--pink)">¥${camp.product_price.toLocaleString()}</span><span style="font-size:12px;color:var(--dark-pink);font-weight:600">${t('detail.rewardProduct')}</span></div>`
          ):''}
          ${/* 현금 리워드 줄 — ⚠️ 리뷰어형(monitor)에는 그리지 않는다. 정산 계산이
                리뷰어형에서 campaigns.reward 를 아예 쓰지 않으므로(마이그레이션 300은
                min(영수증, 상시가) 하나로만 정한다), 표시하면 **지급되지 않는 금액을
                약속**하게 된다. 운영 실측(2026-08-05) 리뷰어형 74개 중 현금 리워드가
                설정된 것은 0개라 실제 노출은 없었지만, 앞으로 누가 값을 넣으면 바로 새어
                나가는 자리라 막는다. 합산 지급(amount_source='product_plus_reward')이
                구현되면 그때 되살린다. */''}
          ${(camp.reward>0 && camp.recruit_type !== 'monitor')?`<div style="font-size:12px;color:var(--green);font-weight:600;margin-top:4px">${t('detail.rewardCash').replace('{amount}',camp.reward.toLocaleString())}</div>`:''}
        </div>
        ${(()=>{
          // 페이백 안내 — 리뷰어형이면 항상(가구매 포함) 정보표 바로 위에 한 상자.
          //   ⚠️ 색은 「注意事項(必読)」(빨강)과 구분되는 정보 안내 톤으로 한다.
          //      같은 빨강을 쓰면 인플루언서 눈에 경고가 두 벌이 되어 둘 다 안 읽힌다.
          //   ⚠️ 첫 줄은 그 캠페인이 화면에 어떻게 그려지는지에 맞춰 갈린다(결정 11) —
          //      두 줄로 그려지는 캠페인에서 「모집/구매 기간」이라 하면 화면 어디에도
          //      없는 이름을 가리키게 된다.
          if (camp.recruit_type !== 'monitor') return '';
          const kind = (typeof campaignPeriodRowKind === 'function') ? campaignPeriodRowKind(camp) : 'none';
          // 2026-08-11 이후 세 갈래가 모두 화면에 있는 이름을 가리킨다 —
          //   merged·monitorNoPurchase = 줄 이름이 「모집 및 구매 기간」이라 기본 문구가 맞고,
          //   split = 두 번째 날짜 줄에 「(구매 기간)」 이름표가 붙어 있어 Split 문구가 맞다.
          //   ⚠️ 그 전에는 구매 칸이 빈 캠페인(운영 10건)이 화면엔 「모집 기간」인데 안내문은
          //      「모집·구매 기간」이라 **없는 이름을 가리켰다.** 줄 이름을 합치며 해소됐다.
          const line1 = t(kind === 'split' ? 'detail.paybackNoticeLine1Split' : 'detail.paybackNoticeLine1');
          return `<div id="campaignPaybackNotice" style="margin:0 0 12px;padding:11px 13px;background:#eff6ff;border:1px solid #bfdbfe;border-radius:9px;font-size:12px;line-height:1.6;color:#1e40af">
            <div>${esc(line1)}</div>
            <div>${esc(t('detail.paybackNoticeLine2'))}</div>
          </div>`;
        })()}
        ${(()=>{
          // 캠페인 상세 표 — 시간 흐름 순으로 행 배치
          // 순서: 상품명 → 모집타입 → 채널 → 콘텐츠 → 모집기간 → 구매/방문기간 → 결과물 제출 마감 → 모집인원
          //       → (monitor 외) 당선 발표 → (monitor 외) 리워드
          const isMonitor = camp.recruit_type === 'monitor';
          // 오프라인 행사는 SNS 게시물·결과물·리워드가 없다. 관리자 폼에서 그 칸들을
          // 숨겼지만, 예전에 저장된 값이나 행사로 바꾸기 전 값이 남아 있을 수 있어
          // **그리는 쪽에서도 막는다** — 저장된 값과 무관하게 행사면 안 그린다.
          const isEvent = (typeof isEventCampaign === 'function') && isEventCampaign(camp);
          // 선정형 행사인가 — 아래 「선정 기간」 줄을 가르는 판정(2026-08-24 선정형 사양서 설계 7).
          const isSelEvent = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);
          // 라벨 칸 폭 — 낼 것을 다 적은 제출 마감 이름(「レシート・投稿スクショの提出締切」)이
          //   90픽셀에서 **네 줄**로 접혀 110픽셀로 넓혔다(2026-08-06 브라우저 실측).
          //   ⚠️ 전 행 공통 값이라 바꾸면 모든 줄에 영향을 준다 — 나머지 라벨은 전부 한 줄이라
          //      넓혀도 안전한 것을 확인했다.
          const KEY = 'width:110px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0';
          const VAL = 'padding:10px 13px;flex:1;font-size:12px';
          const ROW = 'display:flex;border-top:1px solid #faf5f9';
          // 「모집 및 구매 기간」이 날짜 두 줄로 갈릴 때 각 줄 끝에 붙는 이름표.
          //   날짜가 주인공이고 이름표는 보조라 흐린 작은 글씨. whitespace:nowrap 로 이름표
          //   자체가 반으로 쪼개지는 것만 막고, 좁은 화면에서 이름표 통째로 다음 줄에
          //   내려가는 것은 허용한다(글자가 잘리는 것보다 낫다).
          //   ⚠️ 왼쪽 여백은 **5픽셀이 아니라 3픽셀**이다. 폭 375픽셀(현행 최소 기기)에서
          //      실측하니 값 칸 192픽셀에 날짜+여백+이름표가 191.8픽셀 — 여유가 0.2픽셀뿐이라
          //      글꼴이 제때 안 불러와져 다른 글꼴로 대체되기만 해도 접혔다. 3픽셀이면 2.2픽셀이
          //      남는다. **다시 넓히지 말 것**(2026-08-11 브라우저 실측).
          const PTAG = 'margin-left:3px;color:var(--muted);font-size:11px;white-space:nowrap';
          const rows = [];
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.productName')}</div><div style="${VAL}">${esc(camp.product)||'—'}</div></div>`);
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.recruitType')}</div><div style="${VAL}">${(()=>{const rt=camp.recruit_type;const map={monitor:['var(--blue-l)','var(--blue)'],gifting:['var(--gold-l)','var(--gold)'],visit:['#E8F7EF','#0E7E4A']};const m=map[rt];return m?`<span style="background:${m[0]};color:${m[1]};font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px">${esc(getRecruitTypeLabelJa(rt))}</span>`:'—'})()}</div></div>`);
          if (!isEvent) rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.channel')}</div><div style="${VAL};display:flex;gap:6px;flex-wrap:wrap;align-items:center">${(()=>{const sep = camp.channel_match === 'and' ? '&' : 'or'; return (camp.channel||'').split(',').map(s=>s.trim()).filter(Boolean).map(code=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:11px;font-weight:600;padding:2px 10px;border-radius:20px">${esc(getChannelLabel(code))}</span>`).join(`<span style="color:var(--muted);font-size:11px;font-weight:600">${sep}</span>`);})()}</div></div>`);
          if (camp.content_types && !isEvent) {
            const ctList = camp.content_types.split(',').map(c => c.trim()).filter(Boolean);
            if (ctList.length) {
              rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.contentType')}</div><div style="${VAL};display:flex;gap:4px;flex-wrap:wrap">${ctList.map(c=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:10px;font-weight:600;padding:2px 8px;border-radius:20px">${esc(getLookupLabel('content_type', c))}</span>`).join('')}</div></div>`);
            }
          }
          // 판정은 공용 헬퍼 하나만 쓴다 — 관리자 미리보기도 같은 함수를 부른다.
          //   ⚠️ 두 기간이 다르게 저장된 캠페인의 **구매 마감일이 화면에서 사라지면 안 된다**
          //      (결정 5). 그래서 합치되 날짜는 두 줄로 남기고 이름표를 붙인다.
          const periodKind = (typeof campaignPeriodRowKind === 'function') ? campaignPeriodRowKind(camp) : 'none';
          // 리뷰어형은 **항상** 「모집 및 구매 기간」 한 줄로 부른다(2026-08-11 결정).
          //   두 기간이 다르게 저장된 옛 캠페인(split)만 날짜를 두 줄로 놓고 각각 이름표를 단다.
          //   ⚠️ 갈래를 이름으로 지목한다 — `!== 'none'` 같은 부정 조건을 쓰면 갈래가 늘 때
          //      시딩·방문형이 조용히 「구매 기간」 쪽으로 빨려 들어간다.
          const periodMerged = (periodKind === 'merged' || periodKind === 'split' || periodKind === 'monitorNoPurchase');
          // 방문형도 방문 기간이 모집 기간과 똑같이 저장돼 있으면 한 줄로 합친다(2026-08-12).
          //   이름만 「방문」으로 갈릴 뿐 이유는 리뷰어형과 같다 — 같은 날짜를 두 번 보여
          //   주지 않는다. 방문 기간이 따로 있으면 종전대로 아래에 「訪問期間」 줄이 선다.
          //   ⚠️ 행사 캠페인은 제외한다. 행사의 실제 방문 시각은 **아래 타임 선택표**가
          //      정하는데, 이 줄이 「訪問期間」을 겸하면 그걸 대표하는 것처럼 읽힌다.
          //      (행사는 방문 기간 별도 줄도 원래 안 그린다 — 아래 !isEvent 조건)
          const periodVisitMerged = (periodKind === 'visitMerged') && !isEvent;
          const recruitDates = `${formatDate(camp.recruit_start || new Date())} 〜 ${formatDate(camp.deadline)}`;
          // split 은 날짜가 두 줄이고 각 줄 끝에 어느 기간인지 붙는다. 이름표는 보조 정보라
          //   흐린 작은 글씨로 — 날짜가 주인공이다.
          const periodValue = (periodKind === 'split')
            ? `<div>${recruitDates}<span style="${PTAG}">${esc(t('detail.periodTagRecruit'))}</span></div>`
              + `<div style="margin-top:3px">${camp.purchase_start?formatDate(camp.purchase_start):'—'} 〜 ${camp.purchase_end?formatDate(camp.purchase_end):'—'}<span style="${PTAG}">${esc(t('detail.periodTagPurchase'))}</span></div>`
            : recruitDates;
          const periodLabelKey = periodMerged ? 'detail.recruitPurchasePeriod'
                               : periodVisitMerged ? 'detail.recruitVisitPeriod' : 'detail.recruitPeriod';
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t(periodLabelKey)}</div><div style="${VAL}">${periodValue}</div></div>`);
          // 선정 기간 — 시딩형과 **행사가 아닌 방문형**(2026-08-24 결정). 모집 기간 바로
          //   아래에 둔다(인플루언서가 겪는 순서: 모집 → 선정 → 방문 → 결과물 제출 마감).
          //   ⚠️ 두 칸이 다 비면 줄을 그리지 않는다.
          //   ⚠️ 기존 「당선 발표」 줄은 그대로 둔다(날짜 vs 알리는 방법 — 서로 다른 정보).
          //   ⚠️ **선착순형 행사는 값이 있어도 안 그린다.** 관리자 폼이 행사일 때 입력칸을
          //      숨기긴 하나 값을 지우지는 않으므로(일부러 그렇다), 「행사를 켜기 전에 넣어 둔
          //      값」이 남아 있을 수 있다. 여기서 행사를 안 보면 그 줄이 방문객 화면에 떠 버린다.
          //   ★ **선정형 행사(isSelectionEvent)는 그린다** — 2026-08-24 선정형 사양서 설계 7.
          //      선행 결정이 행사를 통째로 뺀 근거는 「예약이 곧 당선(선착순)이라 뽑는 기간이
          //      성립하지 않는다」였는데, 선정형은 관리자가 실제로 뽑으므로 그 전제가 뒤집힌다.
          //      ⚠️ 그래서 조건은 「행사」가 아니라 **「선정형」으로** 넓힌다 — 선착순형 비공개
          //      행사에는 여전히 뜨면 안 된다(뽑는 기간이 없다). 갈래를 이름으로 지목하는
          //      isSelectionEvent 를 쓰고 `!== 'first_come'` 같은 부정 조건을 쓰지 않는다.
          //   ★ 이 조건은 **네 곳에 있다 — ①인플루언서 캠페인 상세(application.js)
          //      ②관리자 미리보기(admin.js kSelectionPeriod) ③진행현황 개요 카드
          //      (admin-applications.js selRange) ④관리자 엑셀(admin-excel.js pickSelection).
          //      ⚠️ **관리자 캠페인 목록의 「선정기간」 열은 이 넷이 아니다** — 그 열은 모집
          //      형식을 아예 안 보고 값만 있으면 그린다(운영 도구라 일부러 그렇다).
          //      한 곳만 고치면 관리자가 본 것과 인플루언서가 보는 것이 갈린다. 나머지 셋의
          //      주석은 이 자리를 가리키므로, **조건을 바꾸면 여기부터 고친다.**
          if ((camp.recruit_type === 'gifting' || (camp.recruit_type === 'visit' && (!isEvent || isSelEvent)))
              && (camp.selection_start || camp.selection_end)) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.selectionPeriod')}</div><div style="${VAL}">${camp.selection_start?formatDate(camp.selection_start):'—'} 〜 ${camp.selection_end?formatDate(camp.selection_end):'—'}</div></div>`);
          }
          // ⚠️ 구매 기간 별도 줄은 2026-08-11 에 없앴다. split 은 위 「모집 및 구매 기간」
          //    줄 안에서 두 번째 날짜 줄로 그린다 — 여기에 되살리면 같은 날짜가 두 번 나온다.
          // 행사 캠페인은 아래 타임 선택표가 날짜를 보여준다 — 여기에 또 적으면
          // 방문객이 두 벌의 날짜를 보게 된다(예전엔 그 둘이 어긋나기까지 했다).
          // ⚠️ 방문 기간이 모집 기간과 똑같이 저장된 캠페인(visitMerged)은 위 줄이 이미
          //    「募集・訪問期間」이므로 여기서 또 그리면 같은 날짜가 두 번 나온다.
          if (camp.recruit_type === 'visit' && !isEvent && !periodVisitMerged && (camp.visit_start || camp.visit_end)) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.visitPeriod')}</div><div style="${VAL}">${camp.visit_start?formatDate(camp.visit_start):'—'} 〜 ${camp.visit_end?formatDate(camp.visit_end):'—'}</div></div>`);
          }
          if (camp.submission_end && !isEvent) {
            // 낼 것을 이름에 적는다 — 리뷰어형은 영수증(+게시물 인증샷), 가구매는 영수증만.
            //   ⚠️ 가구매를 안 가리고 「인증샷」을 넣으면 낼 수 없는 것을 내라는 말이 된다
            //      (마감 안내 메일이 같은 실수를 해 리뷰어형에게 게시물 독촉이 나갔던 선례).
            const labelCode = (typeof campaignSubmissionLabelCode === 'function') ? campaignSubmissionLabelCode(camp) : 'default';
            const subKey = labelCode === 'receiptOnly' ? 'detail.submissionEndProxy'
                         : labelCode === 'receiptAndPost' ? 'detail.submissionEndMonitor'
                         : 'detail.submissionEnd';
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t(subKey)}</div><div style="${VAL};font-weight:600;color:var(--ink)">${formatDate(camp.submission_end)}</div></div>`);
          }
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.recruitSlots')}</div><div style="${VAL}">${camp.slots}${t('detail.peopleUnit')}</div></div>`);
          // 최소 팔로워수 — 시딩·방문형만(리뷰어는 저장 시 0이라 자연 제외). 미리보기와 정합
          if (camp.min_followers && !isEvent) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.minFollowers')}</div><div style="${VAL}">${camp.min_followers.toLocaleString()}${t('detail.minFollowersSuffix')}</div></div>`);
          }
          // 리뷰어(monitor) 캠페인은 당선 발표·리워드 행 제외
          if (!isMonitor && !isEvent) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.winnerAnnounce')}</div><div style="${VAL}">${esc(camp.winner_announce || t('detail.winnerAnnounceValue'))}</div></div>`);
            if (camp.product_price>0 || camp.reward>0 || camp.reward_note) {
              const rewardLine = (camp.product_price>0 || camp.reward>0) ? `${camp.product_price>0?t('detail.rewardProductAmount').replace('{price}',camp.product_price.toLocaleString()):t('detail.rewardProductFree')}${camp.reward>0?` + ${t('detail.rewardCashAmount').replace('{amount}',camp.reward.toLocaleString())}`:''}` : '';
              const noteLine = camp.reward_note ? `<div style="margin-top:${rewardLine?'6px':'0'};font-size:11px;color:var(--muted);font-weight:400;line-height:1.6;white-space:pre-wrap">${esc(camp.reward_note)}</div>` : '';
              rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.reward')}</div><div style="${VAL};color:var(--pink);font-weight:600">${rewardLine}${noteLine}</div></div>`);
            }
          }
          return `<div style="font-size:13px">${rows.join('')}</div>`;
        })()}
      </div>

      ${(typeof isEventCampaign === 'function' && isEventCampaign(camp)) ? `
      <!-- 오프라인 행사 타임 선택표 — 사양서 2026-07-30 §4-3. 내용은 렌더 뒤 비동기로 채운다
           (잔여 인원은 서버 집계라 화면을 먼저 그리고 숫자를 나중에 넣는다). -->
      <div id="eventSlotPicker" style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:4px;color:var(--ink)">${t('event.slotPickerTitle')}</div>
        <div style="font-size:12px;color:var(--muted);margin-bottom:12px">${t('event.slotPickerHint')}</div>
        <div id="eventSlotDateTabs" class="event-date-tabs"></div>
        <div id="eventSlotList" class="event-slot-list">
          <div style="font-size:13px;color:var(--muted);padding:12px 0">${t('event.slotLoading')}</div>
        </div>
      </div>` : ''}

      ${(() => {
        // 참여방법: 스냅샷만 사용 — legacy 폴백 제거, migration 110으로 운영 백필 완료
        const steps = Array.isArray(camp.participation_steps) ? camp.participation_steps : [];
        if (!steps.length) return '';
        return `
      <div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:14px;color:var(--ink)">${t('detail.participationTitle')}</div>
        <div style="display:flex;flex-direction:column;gap:14px">
          ${steps.map((s,i)=>{
            const lang = (typeof getLang === 'function' ? getLang() : 'ja');
            const title = lang === 'ko' ? (s.title_ko||s.title_ja||'') : (s.title_ja||s.title_ko||'');
            const desc = lang === 'ko' ? (s.desc_ko||s.desc_ja||'') : (s.desc_ja||s.desc_ko||'');
            const descHtml = (typeof miniRichHtml === 'function') ? miniRichHtml(desc) : esc(desc);
            return `
            <div style="display:flex;gap:12px;align-items:flex-start">
              <div style="min-width:50px;height:20px;background:var(--light-pink);border-radius:20px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;color:var(--pink);flex-shrink:0">STEP ${i+1}</div>
              <div>
                <div style="font-size:13px;font-weight:700;margin-bottom:2px">${esc(title)}</div>
                ${desc ? `<div class="rich-content" style="font-size:12px;color:var(--muted);line-height:1.55">${descHtml}</div>` : ''}
              </div>
            </div>`;
          }).join('')}
        </div>
      </div>`;
      })()}

      ${camp.description ? `
      <div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">${t('detail.campaignDesc')}</div>
        <div class="rich-content" style="font-size:13px;color:var(--ink);line-height:1.7">${richHtml(camp.description)}</div>
      </div>` : ''}

      ${(camp.hashtags||camp.mentions||camp.appeal) ? `
      <div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:12px;color:var(--ink)">${t('detail.postGuideline')}</div>
        ${camp.appeal ? `<div style="margin-bottom:12px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.brandAppeal')}</div><div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:var(--surface-dim);padding:10px 12px;border-radius:8px;border:1px solid var(--outline)">${richHtml(camp.appeal)}</div></div>` : ''}
        ${camp.hashtags ? (() => {
          // 옛 데이터는 태그 뒤에 안내문(※ …)이 함께 저장돼 있다. 안내문까지 칩으로 그리면
          // 긴 문장이 태그 모양으로 나와 읽기 어려우므로 분리해 아래 문단으로 보여준다.
          const parts = splitTagsAndNote(camp.hashtags);
          const chips = parts.tags.split(/[,\s]+/).map(s => s.trim()).filter(Boolean);
          return `<div style="margin-bottom:10px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.requiredHashtag')}</div>`
            + (chips.length ? `<div style="display:flex;flex-wrap:wrap;gap:5px">${chips.map(tag=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(tag)}</span>`).join('')}</div>` : '')
            + (parts.note ? `<div style="font-size:11px;color:var(--muted);line-height:1.7;margin-top:6px">${esc(parts.note)}</div>` : '')
            + `</div>`;
        })() : ''}
        ${camp.mentions ? `<div><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.requiredMention')}</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.mentions.split(',').map(t=>`<span style="background:#f0f0ff;color:#4040cc;font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(t.trim())}</span>`).join('')}</div></div>` : ''}
      </div>` : ''}

      ${camp.guide ? `
      <div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">${t('detail.shootingGuide')}</div>
        <div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:var(--surface-dim);padding:12px;border-radius:8px;border:1px solid var(--outline)">${richHtml(camp.guide)}</div>
      </div>` : ''}

      ${(() => {
        // ng_items (jsonb 번들 스냅샷) 우선 렌더, 없으면 legacy campaigns.ng 폴백
        const ngItems = Array.isArray(camp.ng_items) ? camp.ng_items : [];
        const hasJsonb = ngItems.length > 0;
        const hasLegacy = !!camp.ng;
        if (!hasJsonb && !hasLegacy) return '';
        const ngHeader = `<div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">${t('detail.ngItems')}</div>`;
        const ngBody = hasJsonb
          ? `<div style="font-size:12px;color:var(--ink);line-height:1.7;padding:12px;border-radius:8px;background:#fff8f8;border:1px solid #fdd">${renderNgItemsHtml(ngItems)}</div>`
          : `<div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:#fff8f8;padding:12px;border-radius:8px;border:1px solid #fdd">${richHtml(camp.ng)}</div>`;
        return `<div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">${ngHeader}${ngBody}</div>`;
      })()}

      ${camp.product_url ? `
      <div style="background:#fff;padding:12px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <a href="${esc(cleanUrl(camp.product_url))}" target="_blank" style="display:flex;align-items:center;gap:8px;color:var(--pink);font-size:13px;font-weight:600;text-decoration:none">
          <span class="material-icons-round notranslate" translate="no" style="font-size:16px">shopping_bag</span> ${t('detail.productPage')}
        </a>
      </div>` : ''}

      ${Array.isArray(camp.caution_items) && camp.caution_items.length ? `
      <div style="background:#fff;padding:16px 0;">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">${t('detail.noticeTitle')}</div>
        <div style="font-size:12px;color:var(--muted)">${renderCautionItemsHtml(camp.caution_items)}</div>
      </div>` : ''}
      <div style="display:flex;flex-direction:column;gap:10px;padding:0 0 calc(var(--tab-h) + 70px)">
        <div style="background:linear-gradient(135deg,#E8789A 0%,#C84B8C 100%);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;cursor:pointer" onclick="window.open('https://instagram.com/reverb_jp','_blank')">
          <div style="flex-shrink:0;width:44px;height:44px;background:#fff;border-radius:10px;display:flex;align-items:center;justify-content:center">
            <svg width="26" height="26" viewBox="0 0 24 24" fill="none"><defs><radialGradient id="igC" cx="30%" cy="107%"><stop offset="0%" stop-color="#ffd676"/><stop offset="50%" stop-color="#f56040"/><stop offset="100%" stop-color="#833ab4"/></radialGradient></defs><rect x="2" y="2" width="20" height="20" rx="5.5" fill="url(#igC)"/><circle cx="12" cy="12" r="4" fill="none" stroke="#fff" stroke-width="1.8"/><circle cx="17.5" cy="6.5" r="1.2" fill="#fff"/></svg>
          </div>
          <div style="flex:1">
            <div style="font-family:'Sora',sans-serif;font-weight:800;font-size:14px;color:#fff;margin-bottom:2px">REVERB <span style="font-size:10px;font-weight:600;opacity:.85">INSTAGRAM</span></div>
            <div style="font-size:11px;color:rgba(255,255,255,.95);font-weight:600;line-height:1.5">${t('detail.igFollowCta')}</div>
            <div style="font-size:10px;color:rgba(255,255,255,.65);margin-top:2px">${t('detail.igFollowSub')}</div>
          </div>
        </div>
        <div style="background:linear-gradient(135deg,#3AC05A 0%,#06A434 100%);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;cursor:pointer" onclick="window.open('https://line.me/R/ti/p/@reverb.jp','_blank')">
          <div style="flex-shrink:0;width:44px;height:44px;background:#fff;border-radius:10px;overflow:hidden;padding:3px">
            <img src="https://qr-official.line.me/sid/M/reverb.jp.png" style="width:100%;height:100%;object-fit:contain" alt="LINE QR" onerror="this.src='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 40 40%22><rect width=%2240%22 height=%2240%22 fill=%22%2306A434%22/><text x=%2250%%22 y=%2255%%22 text-anchor=%22middle%22 fill=%22white%22 font-size=%2218%22>L</text></svg>'">
          </div>
          <div style="flex:1">
            <div style="font-family:'Sora',sans-serif;font-weight:800;font-size:14px;color:#fff;margin-bottom:2px">REVERB <span style="font-size:10px;font-weight:600;opacity:.85">LINE</span></div>
            <div style="font-size:11px;color:rgba(255,255,255,.95);font-weight:600;line-height:1.5">${t('detail.lineAddCta')}</div>
            <div style="font-size:10px;color:rgba(255,255,255,.8);margin-top:2px">${t('detail.lineAddSub')}</div>
            <div style="display:inline-block;background:rgba(255,255,255,.2);border:1px solid rgba(255,255,255,.4);border-radius:20px;padding:2px 9px;font-size:10px;font-weight:700;color:#fff;margin-top:4px">${t('detail.channelRequired')} <span class="material-icons-round notranslate" translate="no" style="font-size:10px;vertical-align:middle">check</span></div>
          </div>
        </div>
      </div>
    </div>
    <div class="detail-sidebar" style="display:none"></div>`;

  // 하단 고정 바 설정
  const fb = $('detailFloatBar');
  const floatName = $('floatProductName');
  const floatReward = $('floatProductReward');
  const floatApplyBtn = $('floatApplyBtn');
  const floatProductPageBtn = $('floatProductPageBtn');
  if (floatName) floatName.textContent = camp.title;
  if (floatReward) {
    const isMonitor = camp.recruit_type === 'monitor';
    // 행사(방문 예약)는 **제품을 주지 않는다.** 리워드가 0이라 그냥 두면 「製品全額無償提供」이
    //   떠서, 놀러 오는 방문객이 제품을 받는 줄 안다(2026-08-06 확인). 그 자리에는 방문객이
    //   실제로 알아야 하는 것 — 어디로 가면 되는지 — 를 넣고, 안 정해졌으면 비워 둔다.
    if ((typeof isEventCampaign === 'function') && isEventCampaign(camp)) {
      //   아직 안 정한 행사면 빈 줄 대신 그렇다고 말한다 — 빈 줄은 「안 불러와졌나」로 읽힌다.
      //   티켓 화면은 같은 자리에 긴 문장을 쓰지만 이 바는 폭이 좁아 짧은 쪽을 따로 둔다.
      floatReward.textContent = String(camp.event_place || '').trim() || t('event.placeTbdShort');
    } else {
      // 하단 고정 바는 폭이 좁아(480px) 전체형을 넣으면 잘린다 — 리뷰어형은 축약형.
      floatReward.textContent = camp.product_price>0
        ? (isMonitor
            ? t('detail.rewardPaybackShort').replace('{price}', camp.product_price.toLocaleString())
            : `¥${camp.product_price.toLocaleString()}${t('detail.rewardProduct')}`)
        : t('detail.rewardFree');
    }
  }
  if (floatProductPageBtn) {
    floatProductPageBtn.style.display = camp.product_url ? 'inline-flex' : 'none';
    floatProductPageBtn.dataset.url = cleanUrl(camp.product_url)||'';
  }
  if (floatApplyBtn) {
    if (_myApp?.status === 'approved') {
      // 행사(방문 예약)는 낼 결과물이 없다 — 누르면 입장 티켓으로 가므로 **이름도 그렇게 적는다.**
      //   「活動管理」는 결과물을 내는 캠페인의 말이라, 놀러 온 방문객에게는 뜻이 안 통한다
      //   (누르면 티켓이 나오는데 이름만 다른 상태였다 — 2026-08-06 확인).
      const _isEvt = (typeof isEventCampaign === 'function') && isEventCampaign(camp);
      floatApplyBtn.textContent = _isEvt ? t('event.ticketMenu') : t('detail.manageBtn');
      floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm';
      floatApplyBtn.onclick = () => openActivityPage(_myApp.id, id, 'detail');
    } else if (alreadyApplied && (typeof isEventCampaign === 'function') && isEventCampaign(camp)) {
      // 행사에서 「심사중」은 **대기(캔슬 대기)** 라는 뜻이다(예약 함수가 대기를 그렇게 저장한다).
      //   그런데 여기서 「応募済み」 + 비활성 버튼으로 그리면 두 가지가 잘못된다 —
      //   ① 확정된 것처럼 읽힌다 ② 자기 대기 순번을 보거나 취소하러 갈 길이 이 화면에서 끊긴다
      //   (응모 이력 카드에는 티켓 버튼이 있지만 상세에서 바로 못 간다 — 2026-08-06 확인).
      // 선정형이면 「캔슬 대기」가 아니라 「심사중」이다 — 뽑히기를 기다리는 것이라
      //   순번을 보러 간다고 적으면 없는 순번을 찾게 된다(의심 ⑤).
      //   ⚠️ 선정형에서 **떨어진 사람도 여기까지 온다.** 응모가 'rejected' 라 위
      //      `_myApp` 조회(취소만 제외)에 걸려 alreadyApplied 가 참이 되고, 응모이력
      //      카드를 누르면 이 상세로 들어온다. 그때 「심사중」이라고 적으면 **이미 끝난
      //      일을 계속 기다리게 된다** — 낙선 알림을 안 보내기로 해(확정 1) 화면 표시가
      //      유일한 통지이므로 더 나쁘다. 누르면 티켓 화면에서 이유를 볼 수 있게 열어 둔다.
      //   ⚠️ 선착순형은 이 분기에 손대지 않는다 — 캠페인 종료 자동 낙첨(마이그레이션 176)에도
      //      같은 어긋남이 있지만 이번 변경 이전부터 있던 별개 문제라 여기서 바꾸지 않는다.
      const _selEvt = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);
      floatApplyBtn.textContent = (_selEvt && _myApp?.status === 'rejected')
        ? t('event.selectionRejectedBtn')
        : (_selEvt ? t('event.selectionPendingBtn') : t('event.waitlistBtn'));
      floatApplyBtn.disabled = false;
      floatApplyBtn.className = 'btn btn-ghost btn-sm';
      floatApplyBtn.onclick = () => {
        if (typeof openTicketForCampaign === 'function') openTicketForCampaign(camp.id);
      };
    } else if (alreadyApplied) { floatApplyBtn.textContent=t('detail.appliedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    // 비공개 캠페인(준비중·노출종료) — 응모이력에서 진입한 경우에만 여기 도달한다(위 가드 참조).
    //   상세는 보여주되 응모는 막는다. 취소 이력이 있으면 「재응모」 버튼이 열려 버리므로 이 분기가 필요하다.
    else if (camp.status === 'draft' || camp.status === 'expired') { floatApplyBtn.textContent=t('detail.closedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    // 마감 판정 — 상태 「모집마감」 또는 마감일 경과(사양서 §설계 5-(1) 단방향 규칙).
    //   자정을 넘겨 캐시의 status 가 active 로 남은 경우에도 여기서 닫혀야 서버 거부를 안 본다.
    else if (camp.status==='closed' || (typeof recruitDeadlinePassed === 'function' && recruitDeadlinePassed(camp) && camp.status!=='scheduled')) { floatApplyBtn.textContent=t('detail.closedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (camp.status==='ended') { floatApplyBtn.textContent=t('detail.endedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    // 모집 시작 전 — 링크로 직접 들어온 경우에도 응모를 막는다(목록에서는 카드 클릭 자체가 불가)
    else if (camp.status==='scheduled') { floatApplyBtn.textContent=t('detail.scheduledBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (isFull) { floatApplyBtn.textContent=t('detail.fullBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (hasCancelledHistory) {
      // 사양 §4-9: 본인이 과거 취소한 캠페인 → 「再応募する」 라벨 + 안내 박스
      floatApplyBtn.textContent=t('detail.reapplyBtn'); floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm';
      floatApplyBtn.onclick=()=>handleFloatApply();
    }
    else { floatApplyBtn.textContent=t('detail.applyBtn'); floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    // 재응모 안내 박스 (버튼 위에 회색 한 줄)
    const reapplyNoticeId = 'detailReapplyNotice';
    let reapplyNotice = document.getElementById(reapplyNoticeId);
    if (hasCancelledHistory && !alreadyApplied && _myApp?.status !== 'approved' && camp.status !== 'closed' && camp.status !== 'ended' && !isFull) {
      if (!reapplyNotice) {
        reapplyNotice = document.createElement('div');
        reapplyNotice.id = reapplyNoticeId;
        reapplyNotice.style.cssText = 'background:#F5F5F5;border-radius:8px;padding:8px 12px;font-size:12px;color:var(--muted);margin-bottom:8px;text-align:center';
      }
      // 안내는 버튼 줄 「위」에 놓는다. 버튼의 부모는 가로 한 줄(flex)이라
      //   거기에 넣으면 제목·리워드 칸(flex:1)이 0px 로 찌부러져 글자가 세로로 쌓인다.
      const floatRow = floatApplyBtn.parentNode;
      if (fb && floatRow?.parentNode === fb && reapplyNotice.parentNode !== fb) fb.insertBefore(reapplyNotice, floatRow);
      reapplyNotice.textContent = t('detail.reapplyNotice');
      reapplyNotice.style.display = '';
    } else if (reapplyNotice) {
      reapplyNotice.style.display = 'none';
    }
  }
  if (fb) fb.style.display='block';

  // 뒤로가기 버튼 라벨 업데이트
  const backLabel = $('detailBackLabel');
  if (backLabel) backLabel.textContent = _detailFrom === 'mypage' ? t('detail.backToHistory') : t('detail.backToCampaigns');

  navigate('detail-' + id);

  // 오프라인 행사면 타임 선택표를 채운다(서버 집계라 비동기).
  //   화면 전환을 막지 않으려고 await 하지 않는다 — 숫자가 오면 그때 들어간다.
  if (typeof isEventCampaign === 'function' && isEventCampaign(camp)) {
    loadEventSlotPicker(camp);
  }
}

// ══════════════════════════════════════
// 오프라인 행사 — 타임 선택표 (사양서 2026-07-30 §4-3)
// ══════════════════════════════════════
let _selectedEventSlotId = null;   // 이번 상세 화면에서 고른 타임
let _eventSlotsForDetail = [];     // 이 캠페인의 타임 목록
let _eventSlotCountsForDetail = {};// 타임별 정원·확정 수
let _eventSlotActiveDate = '';     // 지금 보고 있는 날짜 탭
// 지금 보고 있는 행사가 선정형인가 — 타임 선택표를 그리는 함수들이 camp 를 못 받아 여기 둔다.
//   ⚠️ 선정형은 **정원을 안 세고 받는다**(마이그레이션 378). 그래서 「잔여 N명」·「만석」을
//      그리면 안 된다 — 「잔여 0명」인 타임에도 접수가 되어 안내가 거짓이 된다(의심 ②).
let _eventSelectionForDetail = false;

async function loadEventSlotPicker(camp) {
  // 다른 캠페인을 열었을 수 있으니 매번 초기화한다.
  _selectedEventSlotId = null;
  _eventSlotsForDetail = [];
  _eventSlotCountsForDetail = {};
  _eventSlotActiveDate = '';
  // ⚠️ 여기서 반드시 다시 정한다. 안 되돌리면 선정형 행사를 한 번 열고 나서 여는
  //    선착순형 행사에 「접수 중」이 남아 잔여·만석이 통째로 사라진다.
  _eventSelectionForDetail = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);

  const listEl = $('eventSlotList');
  if (!listEl) return;

  // 비로그인에게는 방문 날짜를 물어봐도 서버가 안 내려준다(타임 표는 로그인한 사람 전용).
  //   그대로 두면 「타임이 하나도 없는 행사」로 보이므로, 왜 안 보이는지와 다음에 할 일을
  //   알려 준다. 예약은 어차피 로그인해야 하므로 여기서 길을 열어 주는 편이 짧다.
  if (!currentUser) {
    const tabs = $('eventSlotDateTabs');
    if (tabs) tabs.innerHTML = '';
    listEl.innerHTML = `
      <div class="event-slot-login">
        <div class="event-slot-login-msg">${esc(t('event.slotNeedLogin'))}</div>
        <div class="invite-gate-btns">
          <button type="button" class="btn btn-primary" onclick="goInviteAuth('${esc(camp.id)}','signup')">${esc(t('event.inviteSignupBtn'))}</button>
          <button type="button" class="btn btn-ghost" onclick="goInviteAuth('${esc(camp.id)}','login')">${esc(t('event.inviteLoginBtn'))}</button>
        </div>
      </div>`;
    return;
  }

  try {
    const [slots, counts] = await Promise.all([
      fetchEventSlots(camp.id),
      fetchEventSlotCounts(camp.id)
    ]);
    // 응답이 오는 사이에 사용자가 다른 캠페인으로 넘어갔으면 그리지 않는다
    // (늦게 도착한 응답이 다른 캠페인 화면을 덮어쓰는 것 방지).
    if (currentCampaignId !== camp.id) return;

    // 이미 끝난 **날짜**의 타임은 고를 수 없게 뺀다. 행사가 여러 날이면 둘째 날 아침에
    //   첫날 탭이 맨 앞에 남아 그게 기본으로 열리고, 지나간 날 예약이 그대로 만들어진다
    //   (서버는 지난 타임을 막지 않는다 — 2026-08-06 테스트에서 실제로 성립했다).
    //   ⚠️ **오늘 것은 시각이 지났어도 남긴다.** 14시 타임을 14시 10분에 현장에서
    //      받아 줘야 하는 경우가 있어, 날짜 단위로만 자른다(2026-08-06 사용자 결정).
    //   ⚠️ 기준은 기기 시각이 아니라 **일본 날짜**(jstTodayStr) — 현장 확인 화면과 같은 기준.
    const _today = (typeof jstTodayStr === 'function')
      ? jstTodayStr()
      : new Date(Date.now() + 9 * 3600 * 1000).toISOString().slice(0, 10);
    _eventSlotsForDetail = (slots || []).filter(s =>
      s.is_active && String(s.slot_date).slice(0, 10) >= _today);   // 'YYYY-MM-DD' 는 사전순 = 날짜순
    _eventSlotCountsForDetail = counts || {};

    if (!_eventSlotsForDetail.length) {
      listEl.innerHTML = `<div style="font-size:13px;color:var(--muted);padding:12px 0">${t('event.slotNone')}</div>`;
      return;
    }
    const dates = [...new Set(_eventSlotsForDetail.map(s => String(s.slot_date).slice(0, 10)))].sort();
    // 지난 날짜를 이미 뺐으므로 dates[0] 는 「오늘 또는 그 이후 가장 가까운 날」이다.
    _eventSlotActiveDate = dates[0];
    renderEventSlotDateTabs(dates);
    renderEventSlotList();
  } catch (e) {
    console.warn('[loadEventSlotPicker]', e);
    logAppError('loadEventSlotPicker', e);
    // 조회 실패를 「타임 없음」으로 보여 주면 방문객이 행사가 끝난 줄 안다 — 다시 시도하라고 알린다.
    listEl.innerHTML = `<div style="font-size:13px;color:var(--red);padding:12px 0">${t('event.slotLoadFailed')}</div>`;
  }
}

function renderEventSlotDateTabs(dates) {
  const el = $('eventSlotDateTabs');
  if (!el) return;
  // ⚠️ 날짜가 하나뿐이어도 **반드시 보여 준다.** 예전에는 하나면 탭을 아예 안 그렸는데,
  //    그러면 시각만 늘어서서 방문객이 **며칠에 가는 예약인지 모른 채** 신청하게 된다
  //    (2026-08-03 지적). 고를 것이 없을 뿐 알아야 하는 정보다.
  if (dates.length === 1) {
    el.innerHTML = `<div class="event-date-single">${esc(formatEventSlotDateLabel(dates[0]))}</div>`;
    return;
  }
  el.innerHTML = dates.map(d => `
    <button type="button" class="event-date-tab${d === _eventSlotActiveDate ? ' on' : ''}"
            onclick="setEventSlotDate('${d}')">${esc(formatEventSlotDateLabel(d))}</button>`).join('');
}

// 'YYYY-MM-DD' → '8/28(金)'. 요일은 보는 사람 언어로.
function formatEventSlotDateLabel(d) {
  const dt = new Date(d + 'T00:00:00+09:00');
  if (isNaN(dt.getTime())) return d;
  const lang = (typeof getLang === 'function' ? getLang() : 'ja');
  const wd = dt.toLocaleDateString(lang === 'ko' ? 'ko-KR' : 'ja-JP', {weekday: 'short', timeZone: 'Asia/Tokyo'});
  return `${dt.getMonth() + 1}/${dt.getDate()}(${wd.replace(/[()]/g, '')})`;
}

function setEventSlotDate(d) {
  _eventSlotActiveDate = d;
  // 날짜를 바꾸면 고른 타임을 푼다 — 안 보이는 타임이 골라진 채로 남으면
  // 「고른 게 없어 보이는데 신청이 되는」 어긋남이 생긴다.
  _selectedEventSlotId = null;
  renderEventSlotDateTabs([...new Set(_eventSlotsForDetail.map(s => String(s.slot_date).slice(0, 10)))].sort());
  renderEventSlotList();
}

function renderEventSlotList() {
  const el = $('eventSlotList');
  if (!el) return;
  const rows = _eventSlotsForDetail.filter(s => String(s.slot_date).slice(0, 10) === _eventSlotActiveDate);
  el.innerHTML = rows.map(s => {
    const c = _eventSlotCountsForDetail[s.id] || {remaining: Number(s.capacity || 0), waitlist: 0};
    const remaining = Number(c.remaining || 0);
    // 선정형은 정원과 상관없이 신청을 받으므로 「만석」이라는 상태 자체가 없다.
    //   full 을 늘 false 로 두면 회색 처리·대기 안내·토스트가 한꺼번에 안 뜬다.
    const full = !_eventSelectionForDetail && remaining <= 0;
    const picked = _selectedEventSlotId === s.id;
    const st = String(s.start_time || '').slice(0, 5);
    const en = s.end_time ? String(s.end_time).slice(0, 5) : '';
    const timeLabel = en ? `${st}〜${en}` : st;
    // 선정형은 잔여를 쓰지 않는다(위 _eventSelectionForDetail 주석) — 접수 중임만 알린다.
    const rightLabel = _eventSelectionForDetail
      ? t('event.slotOpenLabel')
      : (full ? t('event.slotFullWaitlist') : t('event.slotRemaining').replace('{n}', remaining));
    // ⚠️ 대기 안내는 **고른 줄 바로 아래**에 붙인다. 목록 맨 아래에 두면 이른 시간을
    //    고른 사람은 한참 스크롤해야 볼 수 있어 사실상 못 본다(2026-08-03 지적).
    const note = (picked && full)
      ? `<div class="event-slot-note">${esc(t('event.slotWaitlistNote'))}</div>`
      : '';
    return `
      <button type="button" class="event-slot${picked ? ' on' : ''}${full ? ' full' : ''}"
              aria-pressed="${picked ? 'true' : 'false'}"
              onclick="selectEventSlot('${s.id}')">
        <span class="event-slot-time">${esc(timeLabel)}</span>
        ${s.audience_label ? `<span class="event-slot-aud">${esc(s.audience_label)}</span>` : ''}
        <span class="event-slot-remain">${esc(rightLabel)}</span>
      </button>${note}`;
  }).join('');
}

// 고른 타임이 만석인가 — 신청 모달·안내가 같은 판정을 쓰게 한 곳에 둔다.
//   ⚠️ 선정형에는 만석이 없다. 여기서 한 번만 막으면 신청 모달 상단의 대기 안내와
//      타임을 고를 때 뜨는 토스트가 **둘 다** 안 뜬다(§1-2 자리 2).
function isSelectedEventSlotFull() {
  if (_eventSelectionForDetail) return false;
  const s = _eventSlotsForDetail.find(x => x.id === _selectedEventSlotId);
  if (!s) return false;
  const c = _eventSlotCountsForDetail[s.id] || {};
  return Number(c.remaining || 0) <= 0;
}

function selectEventSlot(slotId) {
  const wasPicked = _selectedEventSlotId === slotId;
  _selectedEventSlotId = wasPicked ? null : slotId;
  renderEventSlotList();
  // 만석을 고른 그 순간에도 한 번 알린다. 줄 아래 안내는 계속 남아 있어
  // 토스트가 사라진 뒤 신청 버튼을 누를 때도 보인다.
  if (!wasPicked && isSelectedEventSlotFull()) {
    toast(t('event.slotWaitlistNote'), 'warn');
  }
}

// 예약 실행 — 서버는 실패를 예외가 아니라 {ok:false, reason} 으로 돌려준다.
//   ⚠️ 사유마다 안내가 다 있어야 한다. 없으면 방문객이 왜 안 되는지 모른 채
//      버튼을 여러 번 누른다(작업표 「주의」).
function eventReserveFailMessage(reason) {
  const map = {
    invite_required:      'event.failInviteRequired',
    invite_mismatch:      'event.failInviteMismatch',
    already_applied:      'event.failAlreadyApplied',
    slot_closed:          'event.failSlotClosed',
    deadline_passed:      'event.failDeadlinePassed',
    birthdate_required:   'event.failBirthdate',
    under_age:            'event.failUnderAge',
    not_found:            'event.failNotFound',
    invalid_campaign_type:'event.failGeneric',
    permission_denied:    'event.failGeneric',
  };
  return t(map[reason] || 'event.failGeneric');
}

async function submitEventReservation(camp) {
  if (!_selectedEventSlotId) { toast(t('event.selectSlotFirst'), 'error'); return; }

  // 초대 전용 캠페인이면 주소에 담겨 온 초대 번호를 함께 보낸다.
  //   화면 게이트(작업 5)를 우회해도 서버가 다시 확인하므로 이것이 최종 방어선은 아니다.
  const inviteCode = (typeof getInviteCodeForCampaign === 'function')
    ? getInviteCodeForCampaign(camp.id) : null;

  // 주의사항 동의 스냅샷 — 일반 신청과 같은 v2 형식(마이그레이션 067).
  //   모달에 주의사항이 표시 중일 때만 만든다. 체크 강제는 이미 호출부에서 끝났다.
  let cautionAgreedAt = null, cautionSnapshot = null;
  {
    const cRow = $('applyCautionAgreeRow');
    if (cRow && cRow.style.display !== 'none') {
      cautionAgreedAt = new Date().toISOString();
      cautionSnapshot = {
        version: 2,
        campaign_id: camp.id,
        set_id: camp.caution_set_id || null,
        items: Array.isArray(camp.caution_items) ? JSON.parse(JSON.stringify(camp.caution_items)) : [],
        agreed_lang: (typeof getLang === 'function') ? getLang() : 'ja',
        snapshot_at: cautionAgreedAt
      };
    }
  }

  let res;
  try {
    res = await reserveEventTicket(_selectedEventSlotId, inviteCode, cautionAgreedAt, cautionSnapshot);
  } catch (e) {
    console.error('[submitEventReservation]', e);
    logAppError('reserveEventTicket', e);
    toast(t('event.failGeneric'), 'error');
    return;
  }

  if (!res || !res.ok) {
    // 사전에 있는 사유는 정상 거부. 그 밖의 값은 예상 못 한 오류로 기록된다
    // (기본 문구 event.failGeneric 이 원인을 덮어 버리는 자리라 기록이 유일한 단서다).
    //   ⚠️ `invalid_campaign_type`·`permission_denied` 는 **일부러 뺐다** — 화면 사전에는
    //      있지만 「행사가 아닌 캠페인에 예약을 시도」·「남의 자리를 건드림」이라 정상 동작이
    //      아니다. 정상 거부로 분류하면 진짜 결함이 조용히 묻힌다.
    logAppError('reserveEventTicket', (res && res.reason) || 'no_result', [
      'invite_required', 'invite_mismatch', 'already_applied', 'slot_closed',
      'deadline_passed', 'birthdate_required', 'under_age', 'not_found'
    ]);
    toast(eventReserveFailMessage(res && res.reason), 'error');
    // 정원이 방금 찼거나 타임이 닫힌 경우는 화면 숫자가 낡은 것이므로 다시 불러온다.
    if (res && (res.reason === 'slot_closed' || res.reason === 'not_found')) {
      closeModal('applyModal');
      loadEventSlotPicker(camp);
    }
    return;
  }

  closeModal('applyModal');
  // 선정형에서 `waitlist` 는 「캔슬 대기」가 아니라 「심사중」이다 — 「자리가 나면 알려
  //   드립니다」로 안내하면 방문객이 **엉뚱한 것을 기다린다**(의심 ①).
  //   ⚠️ 판정은 camp 로 한다(선택표용 플래그가 아니라) — 이 함수는 camp 를 받는다.
  const _selEvent = (typeof isSelectionEvent === 'function') && isSelectionEvent(camp);
  toast(t(res.status === 'waitlist'
            ? (_selEvent ? 'event.selectionDone' : 'event.waitlistDone')
            : 'event.applyDone'), 'success');

  _selectedEventSlotId = null;

  // 확정이면 바로 티켓 화면으로 보낸다 — 예약번호·QR 를 그 자리에서 받는 것이
  // 1차 범위에서 안내 메일을 대신한다(사양서 §0 결정 11).
  if (res.status === 'confirmed' && typeof openTicketPage === 'function') {
    openTicketPage(res.ticket_id, 'detail');
    return;
  }

  // 티켓 화면으로 넘어가지 않는 경우(대기 등록 · 티켓 화면 미배포)는 상세를 통째로
  // 다시 그린다. 선택표만 새로 그리면 신청 버튼이 그대로 눌리는 상태로 남아,
  // 다시 누른 방문객이 「이미 예약했습니다」만 보고 왜인지 모른다(2026-08-03 리뷰 지적).
  await openCampaign(camp.id);
}

// ══════════════════════════════════════
// APPLY MODAL
// ══════════════════════════════════════
function openApplyModal(campaignId) {
  currentCampaignId = campaignId;
  const camp = allCampaigns.find(c=>c.id===campaignId);
  if (camp) $('applyModalTitle').textContent = `${t('detail.applyTitle')}: ${camp.title}`;
  $('applyMessage').value = '';
  $('applyAddress').value = currentUserProfile?.address || '';
  $('applyPrCheck').checked = false;

  // ── 오프라인 행사는 모달 안에서 받는 것이 주의사항 동의뿐이다 (사양서 §4-3) ──
  //   신청 이유·배송지·PR 태그 동의는 배송도 게시물도 없는 방문 예약과 맞지 않는다.
  //   숨기기만 하면 검증이 살아 있어 저장이 막히므로, 제출 쪽 검사도 함께 건너뛴다
  //   (_submitApplicationInner 의 같은 분기).
  {
    const isEvent = (typeof isEventCampaign === 'function') && isEventCampaign(camp);
    const reasonWrap = $('applyMessage')?.closest('.form-group');
    const addrWrap = $('applyAddressWrap');
    const prWrap = $('applyPrCheck')?.closest('.form-group');
    if (reasonWrap) reasonWrap.style.display = isEvent ? 'none' : '';
    if (addrWrap)   addrWrap.style.display   = isEvent ? 'none' : '';
    if (prWrap)     prWrap.style.display     = isEvent ? 'none' : '';

    // 모달 상단 안내문도 행사용으로 바꾼다(원문은 「상품을 받고 SNS에 올려 달라」는 내용).
    const notice = $('applyModalNotice');
    if (notice) {
      if (isEvent) {
        const s = _eventSlotsForDetail.find(x => x.id === _selectedEventSlotId);
        const when = s
          ? `${formatEventSlotDateLabel(String(s.slot_date).slice(0, 10))} ${String(s.start_time || '').slice(0, 5)}`
          : '';
        const full = isSelectedEventSlotFull();
        notice.innerHTML = `<b>${esc(t('event.selected'))}</b><br>${esc(when)}`
          + (full ? `<div style="margin-top:8px;color:var(--dark-pink);font-weight:700">${esc(t('event.slotWaitlistNote'))}</div>` : '');
      } else {
        // 일반 캠페인으로 돌아왔을 때 원래 안내문을 되살린다.
        //   행사 캠페인을 한 번 열면 이 자리를 덮어쓰므로, 안 되살리면 그 뒤에 여는
        //   일반 캠페인 모달에 「고른 시간」이 남는다.
        notice.innerHTML = t('apply.modalNotice');
      }
    }
  }
  // 주의사항 영역 동기 렌더 — caution_items 가 이미 camp 스냅샷에 포함되어 있어 fetch 불필요 (migration 069)
  resetCautionUI();
  if (camp && hasCaution(camp)) {
    renderApplyCaution(camp);
  }
  $('applyModal').classList.add('open');
}

function hasCaution(camp) {
  return Array.isArray(camp?.caution_items) && camp.caution_items.length > 0;
}

function resetCautionUI() {
  const box = $('applyCautionBox');
  const row = $('applyCautionAgreeRow');
  const cb = $('applyCautionCheck');
  if (box) { box.style.display = 'none'; box.innerHTML = ''; }
  if (row) row.style.display = 'none';
  if (cb) cb.checked = false;
}

// 캠페인 상세 + 신청 모달 공용 — caution_items 배열(v2: html_ko/html_ja)을 sanitize 렌더
// v1 (text_ko + link_* 분해) 스냅샷도 normalizeCautionItem 으로 html 로 합쳐 동일 경로 처리
function renderCautionItemsHtml(items) {
  if (!Array.isArray(items) || !items.length) return '';
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const sanitize = (typeof sanitizeCautionHtml === 'function')
    ? sanitizeCautionHtml
    : (h => String(h||'').replace(/<script/gi,'&lt;script'));
  const lis = items.map(it => {
    const html = lang === 'ko' ? (it.html_ko || it.html_ja || '') : (it.html_ja || it.html_ko || '');
    // v1 레거시 스냅샷 하위호환 (text_*/link_*) — html 키 없으면 즉석 합성
    if (!html && (it.text_ko || it.text_ja)) {
      const body = lang === 'ko' ? (it.text_ko || it.text_ja || '') : (it.text_ja || it.text_ko || '');
      const url = (it.link_url || '').trim();
      const safeUrl = /^https?:\/\/|^mailto:/i.test(url) ? url : '';
      const label = lang === 'ko' ? (it.link_label_ko || it.link_label_ja || url) : (it.link_label_ja || it.link_label_ko || url);
      const after = lang === 'ko' ? (it.text_after_ko || '') : (it.text_after_ja || '');
      const link = safeUrl
        ? `<a href="${esc(safeUrl)}" target="_blank" rel="noopener noreferrer" style="color:var(--pink);font-weight:600">${esc(label)}</a>`
        : '';
      return `<li>${esc(body)}${link}${esc(after)}</li>`;
    }
    return `<li>${sanitize(html)}</li>`;
  }).join('');
  return `<ul style="margin:0;padding-left:18px;display:flex;flex-direction:column;gap:4px;line-height:1.8">${lis}</ul>`;
}

// ng_items 배열(v2: html_ko/html_ja) 렌더 — 저장 전 DOMPurify 통과한 인라인 서식 허용
// caution 과 달리 NG 는 동의 항목 아니므로 신청 모달 미노출, 상세 페이지만 렌더.
function renderNgItemsHtml(items) {
  if (!Array.isArray(items) || !items.length) return '';
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const sanitize = (typeof sanitizeCautionHtml === 'function')
    ? sanitizeCautionHtml
    : (h => String(h||'').replace(/<script/gi,'&lt;script'));
  const lis = items.map(it => {
    const html = lang === 'ko' ? (it.html_ko || it.html_ja || '') : (it.html_ja || it.html_ko || '');
    return `<li>${sanitize(html)}</li>`;
  }).join('');
  return `<ul style="margin:0;padding-left:18px;display:flex;flex-direction:column;gap:4px;line-height:1.8">${lis}</ul>`;
}

// 신청 모달 빨간 박스 + 동의 체크 행 (items 기반 동기 렌더 — race 자동 해소)
function renderApplyCaution(camp) {
  const items = Array.isArray(camp?.caution_items) ? camp.caution_items : [];
  if (!items.length) return;
  const lang = (typeof getLang === 'function') ? getLang() : 'ja';
  const titleText = lang === 'ko' ? '주의사항(필독)' : '注意事項(必読)';
  const box = $('applyCautionBox');
  if (box) {
    box.innerHTML = `<div style="font-weight:700;color:var(--red);font-size:13px;display:flex;align-items:center;gap:6px;margin-bottom:8px"><span class="material-icons-round notranslate" translate="no" style="font-size:18px">warning</span>${esc(titleText)}</div>${renderCautionItemsHtml(items)}`;
    box.style.display = 'block';
  }
  const row = $('applyCautionAgreeRow');
  if (row) row.style.display = 'block';
}

// 연타 잠금으로 감싼다(사양서 2026-07-31 §3 단계 1). 본문은 그대로고 감싸기만 추가 —
//   중간에 빠져나가는 지점이 8곳이라 개별 해제를 쓰면 반드시 하나가 빠진다.
//   해제는 withSubmitLock 의 finally 에서 한 번만 일어난다.
async function submitApplication() {
  return withSubmitLock('apply:' + currentCampaignId, 'applySubmitBtn', t('common.submitting'), _submitApplicationInner);
}

async function _submitApplicationInner() {
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  // 배송지 이름 누락 차단 — 한자명·가나명 둘 다 필수.
  // 관리자 화면에서 신청자 이름이 「-」로 표시되던 케이스 방지 (마이페이지에서 등록 후 재시도)
  const nameKanji = (currentUserProfile?.name_kanji || currentUserProfile?.name || '').trim();
  const nameKana = (currentUserProfile?.name_kana || '').trim();
  if (!nameKanji || nameKanji === '-' || !nameKana || nameKana === '-') {
    toast(t('apply.needName'),'error');
    return;
  }
  // ── 오프라인 행사(방문 예약)는 여기서 갈라진다 (사양서 §4-3) ──
  //   신청 이유·배송지·PR 태그 동의 검사를 건너뛰고, 신청 행을 직접 만들지 않고
  //   예약 함수를 부른다. 신청 행은 그 함수가 같은 트랜잭션에서 만든다.
  {
    const _campNow0 = allCampaigns.find(c => c.id === currentCampaignId);
    if (typeof isEventCampaign === 'function' && isEventCampaign(_campNow0)) {
      // 주의사항 동의는 행사에서도 그대로 받는다(모달에 표시 중일 때만).
      const _cRow = $('applyCautionAgreeRow');
      if (_cRow && _cRow.style.display !== 'none' && !$('applyCautionCheck')?.checked) {
        toast(t('apply.cautionRequired'), 'error'); return;
      }
      await submitEventReservation(_campNow0);
      return;
    }
  }

  const msg = $('applyMessage').value.trim();
  const addr = $('applyAddress').value.trim();
  const prCheck = $('applyPrCheck').checked;
  if (!msg) { toast(t('apply.needReason'),'error'); return; }
  if (!addr) { toast(t('apply.needAddress'),'error'); return; }
  if (!prCheck) { toast(t('apply.needPrAgree'),'error'); return; }
  // 주의사항 동의 검증 (캠페인에 caution이 있을 때만 — UI에서 행이 표시 중인지로 판단)
  const cautionRow = $('applyCautionAgreeRow');
  const cautionShown = cautionRow && cautionRow.style.display !== 'none';
  if (cautionShown && !$('applyCautionCheck')?.checked) {
    toast(t('apply.cautionRequired'),'error'); return;
  }

  const isDuplicate = await checkDuplicateApplication(currentUser.id, currentCampaignId);
  if (isDuplicate) {
    toast(t('apply.alreadyApplied'),'error'); closeModal('applyModal'); return;
  }

  // 리뷰어(monitor) 캠페인은 모집인원 초과 시 응모 차단 (UX 보조, DB 트리거 048이 최종)
  const camp0 = allCampaigns.find(c => c.id === currentCampaignId);
  if (camp0 && camp0.recruit_type === 'monitor') {
    const realCount = await countActiveApplications(currentCampaignId);
    const slots = Number(camp0.slots || 0);
    if (slots > 0 && realCount >= slots) {
      toast(t('apply.slotsFull'), 'error');
      closeModal('applyModal');
      return;
    }
  }

  // 제출 직전 마감 재검사 (사양서 2026-07-29 §설계 5-(8)-2)
  //   응모 모달을 열어 둔 채 자정을 넘기면 버튼은 이미 눌렸고 화면 판정은 모달 열 때 값이다.
  //   서버까지 갔다 와서 거부당하는 대신 여기서 안내하고 상세를 다시 그려 버튼을 닫는다.
  //   같은 화면 판정의 재실행이라 판정이 두 벌이 되는 것은 아니다.
  {
    const _campNow = allCampaigns.find(c => c.id === currentCampaignId);
    if (_campNow && typeof recruitDeadlinePassed === 'function' && recruitDeadlinePassed(_campNow)) {
      toast(t('detail.deadlineJustPassed'), 'error');
      closeModal('applyModal');
      openCampaign(currentCampaignId);
      return;
    }
  }

  // 주의사항 동의 시 스냅샷 v2 빌드 — 캠페인의 caution_items 를 신청 시점 그대로 보존 (migration 069)
  let cautionAgreedAt = null, cautionSnapshot = null;
  if (cautionShown) {
    cautionAgreedAt = new Date().toISOString();
    const camp = allCampaigns.find(c => c.id === currentCampaignId) || {};
    cautionSnapshot = {
      version: 2,
      campaign_id: currentCampaignId,
      set_id: camp.caution_set_id || null,
      items: Array.isArray(camp.caution_items) ? JSON.parse(JSON.stringify(camp.caution_items)) : [],
      agreed_lang: (typeof getLang === 'function') ? getLang() : 'ja',
      snapshot_at: cautionAgreedAt
    };
  }

  try {
    await insertApplication({
      user_id: currentUser.id, user_email: currentUser.email,
      user_name: currentUserProfile?.name || currentUser.email,
      user_followers: currentUserProfile?.followers || 0,
      user_ig: currentUserProfile?.ig || '',
      campaign_id: currentCampaignId, message: msg, address: addr, status: 'pending',
      caution_agreed_at: cautionAgreedAt,
      caution_snapshot: cautionSnapshot
    });
    // DB 트리거(058)가 applied_count를 자동 동기화하므로 수동 UPDATE 불필요.
    // 로컬 객체만 낙관적 증가 → 다음 fetchCampaigns 시 DB 실제값으로 덮어씌워짐.
    const camp = allCampaigns.find(c=>c.id===currentCampaignId);
    if (camp) camp.applied_count = (camp.applied_count||0) + 1;
  } catch(e) {
    if (e.message?.includes('row-level security')) {
      // ⚠️ 이 분기는 return 으로 빠져나가 아래 friendlyErrorJa 를 안 거친다 —
      //    세션 만료로 보이지만 실제로는 접근 정책 결함일 수도 있어 기록해 둔다.
      logAppError('submitApplication.rls', e);
      toast(t('apply.sessionExpired'),'error');
      closeModal('applyModal');
      currentUser = null; currentUserProfile = null;
      updateGnb();
      return;
    }
    toast(friendlyErrorJa(e), 'error'); closeModal('applyModal');
    // 마감으로 거부됐다면 상세를 다시 그려 버튼을 「募集締切」로 갱신한다(사양서 §설계 5-(8)-3).
    //   갱신하지 않으면 버튼이 활성 그대로라 인플루언서가 2~3회 더 누르고 「앱이 고장났다」고 느낀다.
    //   일반 실패(네트워크 등)에는 재렌더하지 않는다 — 화면이 튀고 입력이 사라진다.
    //   ★ 응모 중복도 같은 이유로 다시 그린다 — 중복이라는 건 **이미 응모가 존재한다**는 뜻이라
    //     버튼이 「応募済み」로 바뀌어야 인플루언서가 「됐구나」를 알 수 있다. 그대로 두면
    //     실패 문구만 보고 또 누른다(사양서 2026-07-31 §3 1-5).
    const _em = String(e?.message || '');
    if (/recruit_deadline_passed/.test(_em)
        || /uidx_applications_user_campaign|applications_user_camp_active_uidx/.test(_em)) {
      openCampaign(currentCampaignId);
    }
    return;
  }

  closeModal('applyModal');
  toast(t('detail.applyComplete'),'success');
  openCampaign(currentCampaignId);
}

// ── FLOAT BAR + LOGIN PROMPT ──
function handleFloatApply() {
  if (!currentUser) {
    // 초대 링크로 들어온 비로그인 방문객이 여기서 로그인하면 **그 행사로 돌아와야 한다.**
    //   안 적어 두면 로그인 뒤 홈으로 떨어지고, 초대 링크를 다시 찾아 열어야 한다.
    //   (게이트 화면의 로그인 버튼은 goInviteAuth 가 같은 일을 한다 — 여기는 그 짝이다.)
    const _c = (typeof allCampaigns !== 'undefined' && allCampaigns)
      ? allCampaigns.find(c => c.id === currentCampaignId) : null;
    if (_c && typeof isInviteOnlyCampaign === 'function' && isInviteOnlyCampaign(_c)
        && typeof rememberInviteReturn === 'function') {
      rememberInviteReturn(_c.id);
    }
    const o = $('loginPromptOverlay');
    if (o) { o.style.display='flex'; }
    return;
  }
  // 이메일 미인증 체크
  if (!currentUser.email_confirmed_at) {
    toast(t('apply.emailUnverified'),'error');
    return;
  }
  // 연령 게이트 (소급 — 응모 시점 검증, 사양서 §0-1 ①). 클라 표시용·서버 트리거(P0002)가 최종 방어선
  //   - 생년월일/성별 미입력 → 입력 게이트 모달 (입력·저장 후 다시 응모 진행)
  //   - 만 18세 미만 → 응모 차단 안내 (계정·둘러보기는 유지, 18세 도달 시 자동 해제)
  const pAge = currentUserProfile || {};
  if (!pAge.birthdate || !pAge.gender) {
    openAgeGate();
    return;
  }
  const curAge = (typeof calcAgeFromBirthdate === 'function') ? calcAgeFromBirthdate(pAge.birthdate) : null;
  if (curAge !== null && curAge < AGE_POLICY_MIN_AGE) {
    if (typeof openModal === 'function') {
      $('alertModalMessage').textContent = t('ageGate.under18Apply');
      openModal('alertModal');
    } else {
      toast(t('ageGate.under18Apply'), 'error');
    }
    return;
  }
  // 필수 정보 체크: 이름(한자·가나) + 캠페인 채널에 맞는 SNS 계정 + 배송지
  const p = currentUserProfile || {};
  const camp = allCampaigns.find(c => c.id === currentCampaignId) || {};

  // ── 오프라인 행사(방문 예약)는 요구 항목이 다르다 (사양서 §2-1 · §4-3) ──
  //   남기는 것: 이름(한자·가나) · 생년월일·성별(위 연령 게이트에서 이미 통과)
  //   빼는 것  : SNS 계정 · 우편번호·도도부현·시군구·전화 · PayPal 이메일 · 최소 팔로워
  //   팝업에 놀러 오는 일반 손님에게 PayPal 계정을 요구할 수는 없다.
  //   ⚠️ 분기 조건은 isEventCampaign 하나만 쓴다 — 판정을 새로 만들면 화면마다 달라진다.
  if (typeof isEventCampaign === 'function' && isEventCampaign(camp)) {
    const nk = ((p.name_kanji || p.name || '') + '').trim();
    const nn = ((p.name_kana || '') + '').trim();
    const lack = [];
    if (!nk || nk === '-') lack.push(t('profile.nameKanji'));
    if (!nn || nn === '-') lack.push(t('profile.nameKana'));
    if (lack.length) {
      $('profileAlertMissing').innerHTML = lack.map(m =>
        `<div style="display:flex;align-items:center;gap:8px;padding:8px 12px;margin-bottom:6px;background:var(--light-pink);border-radius:10px;font-size:13px;color:var(--dark-pink);font-weight:600">
          <span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--pink)">warning</span>${esc(m)}
        </div>`).join('');
      $('profileAlertOverlay').style.display = 'flex';
      return;
    }
    // 타임을 안 고르면 무엇을 예약하는지 알 수 없다. 선택표로 시선을 돌려준다.
    if (!_selectedEventSlotId) {
      toast(t('event.selectSlotFirst'), 'error');
      const picker = $('eventSlotPicker');
      if (picker && typeof picker.scrollIntoView === 'function') {
        picker.scrollIntoView({behavior: 'smooth', block: 'center'});
      }
      return;
    }
    openApplyModal(currentCampaignId);
    return;
  }
  // 채널 비교는 항상 split(',').includes() 패턴 — 단순 includes는 부분 문자열 오탐 위험
  const chList = (camp.channel || '').toLowerCase().split(',').map(s => s.trim()).filter(Boolean);
  const missing = [];
  // 이름(한자·가나) — 한자명은 name_kanji 우선, 폴백 name. "-" 도 미등록으로 간주
  const nameKanji = ((p.name_kanji || p.name || '') + '').trim();
  const nameKana = ((p.name_kana || '') + '').trim();
  if (!nameKanji || nameKanji === '-') missing.push(t('profile.nameKanji'));
  if (!nameKana || nameKana === '-') missing.push(t('profile.nameKana'));
  // 캠페인 채널에 맞는 SNS 계정 체크
  if (chList.includes('instagram') && !p.ig) missing.push('Instagram ID');
  if (chList.includes('x') && !p.x) missing.push('X(Twitter) ID');
  if (chList.includes('tiktok') && !p.tiktok) missing.push('TikTok ID');
  if (chList.includes('youtube') && !p.youtube) missing.push('YouTube ID');
  if (chList.includes('qoo10') && !p.ig) missing.push('Instagram ID');
  // SNS 계정이 하나도 없으면 기본적으로 Instagram 체크
  if (chList.length === 0 && !p.ig) missing.push('Instagram ID');
  if (!p.zip) missing.push(t('profile.zip'));
  if (!p.prefecture) missing.push(t('profile.prefecture'));
  if (!p.city) missing.push(t('profile.city'));
  if (!p.phone) missing.push(t('profile.phone'));
  if (!p.paypal_email) missing.push(t('profile.paypalEmail'));
  if (missing.length > 0) {
    $('profileAlertMissing').innerHTML = missing.map(m =>
      `<div style="display:flex;align-items:center;gap:8px;padding:8px 12px;margin-bottom:6px;background:var(--light-pink);border-radius:10px;font-size:13px;color:var(--dark-pink);font-weight:600">
        <span class="material-icons-round notranslate" translate="no" style="font-size:18px;color:var(--pink)">warning</span>${esc(m)}
      </div>`
    ).join('');
    $('profileAlertOverlay').style.display = 'flex';
    return;
  }
  // 최소 팔로워수 체크 — 기준 채널(primary_channel) 단일 검증
  // 리뷰어(monitor)형은 영수증 검증이라 팔로워 조건 미적용
  const minF = camp.min_followers || 0;
  if (minF > 0 && camp.recruit_type !== 'monitor') {
    const followerMap = {instagram: p.ig_followers||0, x: p.x_followers||0, tiktok: p.tiktok_followers||0, youtube: p.youtube_followers||0, qoo10: p.ig_followers||0};
    const chNameMap = {instagram:'Instagram', x:'X(Twitter)', tiktok:'TikTok', youtube:'YouTube', qoo10:'Qoo10'};
    // 기준 채널: primary_channel 우선, 없으면 첫 번째 채널로 폴백
    // chList 는 camp.channel 을 split(',')+lowercase+trim 한 배열 (위 496줄)
    const primary = (camp.primary_channel || chList[0] || 'instagram').trim();
    const primaryName = chNameMap[primary] || primary;
    const primaryCount = followerMap[primary] || 0;
    if (primaryCount < minF) {
      $('alertModalMessage').innerHTML = `${t('detail.followerRequirement')}<br><strong>${primaryName}</strong> ${t('detail.followerRequirementSuffix').replace('{n}',minF.toLocaleString())}<br><br>${t('detail.yourFollowers').replace('{channel}',primaryName)}<br><strong>${primaryCount.toLocaleString()}${t('detail.peopleUnit')}</strong><br><br><span style="font-size:11px;color:var(--muted)">${t('detail.followerWarning')}</span>`;
      openModal('alertModal');
      return;
    }
  }
  openApplyModal(currentCampaignId);
}
function openProductPage() {
  const url = $('floatProductPageBtn')?.dataset.url;
  if (url) window.open(url,'_blank');
}

// ── 응모 연령 게이트 (생년월일·성별 미입력 시 응모 직전 입력, 사양서 §0-1 ①) ──
function openAgeGate() {
  if (typeof populateBirthdateSelects === 'function') populateBirthdateSelects('gate');
  const err = $('ageGateError');
  if (err) { err.style.display='none'; err.textContent=''; }
  // 기존 입력값 복원 (성별만 — 생년월일은 최초 입력이라 보통 비어 있음)
  const p = currentUserProfile || {};
  if (p.gender && $('gateGender')) $('gateGender').value = p.gender;
  // 동의 체크박스는 매번 미체크로 초기화 (재진입 시 이전 체크 상태로 무의식 통과 방지)
  if ($('gateAgreePrivacy')) $('gateAgreePrivacy').checked = false;
  const ov = $('ageGateOverlay');
  if (ov) ov.style.display = 'flex';
}

function closeAgeGate() {
  const ov = $('ageGateOverlay');
  if (ov) ov.style.display = 'none';
}

async function saveAgeGate() {
  const err = $('ageGateError');
  const showErr = (msg) => { if (err) { err.textContent = msg; err.style.display='block'; } };
  const by = $('gateBirthYear')?.value || '';
  const bm = $('gateBirthMonth')?.value || '';
  const bd = $('gateBirthDay')?.value || '';
  const gender = $('gateGender')?.value || '';
  if (err) err.style.display='none';
  if (!by || !bm || !bd) { showErr(t('authError.enterBirthdate')); return; }
  const birthdate = `${by}-${String(bm).padStart(2,'0')}-${String(bd).padStart(2,'0')}`;
  const bdObj = new Date(birthdate + 'T00:00:00+09:00');
  if (isNaN(bdObj.getTime()) || (bdObj.getMonth()+1) !== Number(bm) || bdObj.getDate() !== Number(bd)) {
    showErr(t('authError.invalidBirthdate')); return;
  }
  if (!gender) { showErr(t('authError.enterGender')); return; }
  // 개인정보(생년월일·성별) 수집·이용 동의 필수 — 신규 수집이므로 명시 동의 (개인정보보호법)
  if (!$('gateAgreePrivacy')?.checked) { showErr(t('ageGate.agreeRequired')); return; }

  // ⚠️ 18세 미만은 DB 저장 없이 차단 — 생년월일 잠금 트리거(PR1)로 오타가 영구 고정되는 것 방지
  //    (개인정보 최소수집 원칙). 18세 도달 후 재입력 시 저장됨(서버가 birthdate로 매번 판정).
  const age = (typeof calcAgeFromBirthdate === 'function') ? calcAgeFromBirthdate(birthdate) : null;
  if (age !== null && age < AGE_POLICY_MIN_AGE) {
    closeAgeGate();
    if (typeof openModal === 'function') {
      $('alertModalMessage').textContent = t('ageGate.under18Apply');
      openModal('alertModal');
    } else {
      toast(t('ageGate.under18Apply'), 'error');
    }
    return;
  }

  // 잠금·버튼 복원을 헬퍼에 맡긴다(사양서 2026-07-31 §3 1-3).
  //   예전에는 성공·실패 경로에서 각각 풀어, 그 사이에서 예외가 나면 버튼이 잠긴 채 남았다.
  const consentAt = new Date().toISOString();
  const _saved = await withSubmitLock('ageGate', 'ageGateSaveBtn', t('common.submitting'), async function() {
    try {
      await updateInfluencer(currentUser.id, { birthdate, gender, age_consent_at: consentAt });
      if (!currentUserProfile) currentUserProfile = {};
      currentUserProfile.birthdate = birthdate;
      currentUserProfile.gender = gender;
      currentUserProfile.age_consent_at = consentAt;
      return true;
    } catch(e) {
      showErr(friendlyErrorJa(e));
      return false;
    }
  });
  if (!_saved) return;   // 저장 실패, 또는 이미 실행 중이라 무시됨(undefined)
  closeAgeGate();
  // 18세 이상 — 저장 완료, 응모 흐름 재개
  handleFloatApply();
}

// ══════════════════════════════════════
// ACTIVITY PAGE — 활동 관리
// ══════════════════════════════════════
let _activityAppId = null;
let _activityCampId = null;
let _activityCamp = null;
let _activityFrom = 'detail'; // 'detail' or 'mypage'
// 마지막 loadDeliverablesForActivity() 결과 — draft 추가 함수의 마감 후 가드 판정에 사용
let _activityLastDelivs = [];
// 서버가 준 결과물 제출 가부 판정(마이그레이션 276). null = 조회 실패 → 화면은 막지 않는다.
let _activityGate = null;
let _receiptImgData = null;
let _receiptOcrFile = null;  // 영수증 OCR 자동입력용 원본 파일 (base64와 별개로 File 보관)
let _reviewImgDataByChannel = {};  // monitor 2단계 — 채널별 리뷰 캡쳐 base64 ({channel: dataUrl})

async function openActivityPage(applicationId, campaignId, from) {
  _activityAppId = applicationId;
  _activityCampId = campaignId;
  _activityFrom = from || 'detail';
  const camp = allCampaigns.find(c=>c.id===campaignId) || {};
  _activityCamp = camp;
  // 사양 §4-8: cancelled 신청은 활동관리 진입 자체 차단.
  // 회색 안내 화면만 보여주고 폼은 DOM 비공개. 헤더 알림에서 과거 이력으로
  // 진입한 경우에도 동일 분기.
  // 오프라인 행사는 결과물을 내지 않는다 — 활동관리 대신 입장 티켓 화면으로 보낸다.
  //   확정 티켓은 신청이 「승인」 상태라 이 화면이 그대로 열리면 결과물 제출 폼이
  //   뜨고 방문객이 「무엇을 내라는 건지」 혼란에 빠진다(사양서 §2-5 — 선택이 아니라 필수).
  //   ⚠️ 취소 판정보다 **뒤**에 둔다. 취소된 신청은 취소 안내가 먼저다.
  const isCancelled = (typeof isApplicationCancelled === 'function') && isApplicationCancelled(applicationId);
  if (!isCancelled && typeof isEventCampaign === 'function' && isEventCampaign(camp)
      && typeof openTicketForCampaign === 'function') {
    await openTicketForCampaign(campaignId);
    return;
  }
  if (isCancelled) {
    // 차단 안내 패널을 보여주려면 페이지 전환 필요. 정상 진입은 함수 끝의 navigate 가 처리하므로
    // 여기서는 cancelled 분기 한정으로만 호출 — 정상 진입에서 navigate 2회 호출되어 뒤로가기 1번이
    // 무반응이던 회귀 해소 (2026-05-28 핫픽스).
    if (typeof navigate === 'function') navigate('activity');
    const root = $('page-activity');
    if (root) {
      // 첫 차단 진입일 때만 안내 패널 삽입. 이후 다른 신청 열면 원래 폼이 다시 표시되어야 하므로 plain 패널만 추가.
      let blocked = $('activityCancelledNotice');
      if (!blocked) {
        blocked = document.createElement('div');
        blocked.id = 'activityCancelledNotice';
        blocked.style.cssText = 'padding:40px 20px;text-align:center;background:#F5F5F5;border-radius:14px;margin:20px';
        blocked.innerHTML = `
          <div style="font-size:36px;color:var(--muted);margin-bottom:12px"><span class="material-icons-round notranslate" translate="no" style="font-size:48px">cancel</span></div>
          <div style="font-size:15px;font-weight:700;color:var(--ink);margin-bottom:8px" data-i18n="appHistory.cancelBlocked.title">この応募はキャンセルされました</div>
          <div style="font-size:13px;color:var(--muted);margin-bottom:20px;line-height:1.7" data-i18n="appHistory.cancelBlocked.body">応募履歴に戻る場合は下のボタンをタップ</div>
          <button class="btn btn-primary" onclick="navigate('mypage', false);openMypageSub('applications')" data-i18n="appHistory.cancelBlocked.backBtn">応募履歴に戻る</button>`;
        // 페이지 헤더 + 안내. 다른 폼/섹션은 모두 가린다.
        const main = root.querySelector('.page-content') || root;
        // 기존 자식 모두 숨김 후 안내만 노출
        Array.from(main.children).forEach(ch => { ch.style.display = 'none'; });
        main.appendChild(blocked);
      } else {
        blocked.style.display = '';
      }
      if (typeof applyI18n === 'function') applyI18n();
    }
    return;
  }
  // cancelled 가 아닌 정상 진입 — 차단 패널이 이전에 삽입되어 있으면 숨기고 폼을 복원
  const prevBlocked = $('activityCancelledNotice');
  if (prevBlocked && prevBlocked.parentNode) {
    const main = prevBlocked.parentNode;
    Array.from(main.children).forEach(ch => { ch.style.display = ''; });
    prevBlocked.style.display = 'none';
  }
  $('activityCampTitle').textContent = camp.title || '';
  $('activityCampBrand').textContent = brandLabelInflu(camp);
  const rtLabel = $('activityRecruitLabel');
  if (rtLabel) {
    if (camp.recruit_type && typeof getRecruitTypeLabelJa === 'function') {
      rtLabel.textContent = getRecruitTypeLabelJa(camp.recruit_type);
      rtLabel.style.display = '';
    } else {
      rtLabel.style.display = 'none';
    }
  }

  // 사양 §4-1 추가 진입점: 활동관리 페이지 상단 「取消」 버튼.
  // 표시 조건은 응모이력 ⋮ 메뉴와 동일 — pending/approved 이면서
  // 결과물 1건도 approved 아닐 때만. fetchDeliverablesForUser 로 본인
  // 결과물 조회 후 판단.
  const cancelBtnEl = $('activityCancelBtn');
  if (cancelBtnEl) {
    let canCancel = false;
    try {
      const app = (typeof _myApps !== 'undefined' && Array.isArray(_myApps))
        ? _myApps.find(a => a.id === applicationId)
        : null;
      const appStatus = app?.status;
      if (appStatus === 'pending' || appStatus === 'approved') {
        const ds = await fetchDeliverablesForUser({user_id: currentUser?.id, application_id: applicationId});
        const hasApprovedDeliv = ds.some(d => d.status === 'approved');
        canCancel = !hasApprovedDeliv;
      }
    // ⚠️ 조회가 실패하면 취소 버튼이 **조용히 사라진다**(취소가 막힌 것처럼 보인다).
    } catch(_e) { logAppError('openActivityPage.cancelCheck', _e); canCancel = false; }
    cancelBtnEl.style.display = canCancel ? '' : 'none';
    cancelBtnEl.dataset.appId = applicationId;
  }

  // 타입별 섹션 표시
  //   monitor: 영수증 이미지만 (receiptSection) — 자비 구매 증빙
  //   gifting: 게시 URL만 (postSection) — 무료 제품 + SNS 포스트
  //   visit:   이미지 + URL (둘 다) — 현장 사진 + SNS 게시
  const rt = camp.recruit_type || 'monitor';
  const showImage = (rt === 'monitor' || rt === 'visit');
  const showPost = (rt === 'gifting' || rt === 'visit');
  const isMonitor = (rt === 'monitor');
  // 가구매(proxy_purchase, 마이그레이션 197): monitor지만 영수증만 — 리뷰 캡쳐(STEP 2) 미요구
  const isProxy = isMonitor && !!camp.proxy_purchase;
  $('activityReceiptSection').style.display = showImage ? '' : 'none';
  $('activityPostSection').style.display = showPost ? '' : 'none';
  // monitor 캠페인은 STEP 1 라벨 + STEP 2(리뷰 캡쳐) 섹션 노출. 가구매는 STEP 2 없음.
  const stepLabel = $('receiptStepLabel');
  if (stepLabel) stepLabel.style.display = (isMonitor && !isProxy) ? '' : 'none';
  const reviewSec = $('reviewImageSection');
  if (reviewSec) reviewSec.style.display = (isMonitor && !isProxy) ? '' : 'none';
  // monitor 전용 영수증 필수 필드(주문번호·구매일·구매금액) — 마이그레이션 128
  const monitorFields = $('monitorReceiptFields');
  if (monitorFields) monitorFields.style.display = isMonitor ? '' : 'none';
  const isPostType = showPost;  // 아래 마감 검사 로직용

  // 제출 마감일 안내 기본값 (마감 전 케이스만 여기서 처리)
  // 마감 후 비활성/반려후 활성 분기는 loadDeliverablesForActivity 가 끝난 뒤
  // applyFormGating() 이 덮어쓴다 — 반려된 결과물 데이터를 알아야 결정 가능하므로.
  const submissionEnd = camp.submission_end || null;
  const deadlineBox = $('activitySubmissionDeadline');
  if (deadlineBox) {
    if (submissionEnd) {
      deadlineBox.style.display = '';
      deadlineBox.textContent = `${t('activity.submissionEndLabel')}: ${formatDate(submissionEnd)}`;
      deadlineBox.style.color = 'var(--muted)';
    } else {
      deadlineBox.style.display = 'none';
    }
  }

  // 폼 초기화 (이미지·URL 섹션 모두 null-safe 처리)
  if (showImage) {
    const rp = $('receiptPreview'); if (rp) rp.innerHTML = '';
    const rf = $('receiptFile'); if (rf) rf.value = '';
    _receiptImgData = null;
    _receiptOcrFile = null;
    const ocrSt = $('receiptOcrStatus'); if (ocrSt) { ocrSt.style.display = 'none'; ocrSt.textContent = ''; }
    // monitor 전용 3종 필드 — 폼 진입 시 비움 (마이그레이션 128)
    const ron = $('receiptOrderNumber'); if (ron) ron.value = '';
    const rd = $('receiptDate'); if (rd) rd.value = '';
    const ra = $('receiptAmount'); if (ra) ra.value = '';
    renderReceiptPayoutNote(camp);
  }
  if (isMonitor) {
    // 채널별 카드 컨테이너는 renderActivityReviewImageList 가 재렌더 시 초기화하므로
    // 여기서는 in-memory 상태(_reviewImgDataByChannel)만 비움
    _reviewImgDataByChannel = {};
  }
  if (showPost) {
    const urlEl = $('postUrlInput'); if (urlEl) urlEl.value = '';
    const ch = $('postChannelDetected'); if (ch) ch.textContent = '';
    const mw = $('postChannelManualWrap'); if (mw) mw.style.display = 'none';
  }

  navigate('activity');
  await loadDeliverablesForActivity();
}

// ── 게시물 URL 채널 자동판별 (Stage 3) ──
function detectChannelFromUrl(url) {
  if (!url) return null;
  try {
    const u = new URL(url.trim());
    const host = u.hostname.toLowerCase().replace(/^www\./, '');
    if (host.includes('instagram.com')) return 'instagram';
    if (host.includes('tiktok.com')) return 'tiktok';
    if (host === 'youtube.com' || host === 'youtu.be' || host.endsWith('.youtube.com')) return 'youtube';
    if (host === 'x.com' || host === 'twitter.com' || host.endsWith('.twitter.com')) return 'x';
    if (host.includes('qoo10.jp')) return 'qoo10';
    if (host.includes('lipscosme.com')) return 'lips';
    if (host === 'cosme.net' || host.endsWith('.cosme.net')) return 'cosme';
    return null;
  } catch(e) { return null; }
}

const CHANNEL_LABELS = {
  instagram: 'Instagram', tiktok: 'TikTok', youtube: 'YouTube',
  x: 'X (Twitter)', qoo10: 'Qoo10', lips: 'LIPS', cosme: '@cosme'
};
// 채널 라벨 해석 우선순위:
//   ① lookup_values 의 현재 언어 라벨 (관리자가 추가한 신규 채널 — 자동 생성 code 'channel-XXXX' 포함)
//   ② CHANNEL_LABELS 하드코딩 (Instagram·TikTok·YouTube·X·Qoo10·LIPS·@cosme 등 표준 채널)
//   ③ i18n '기타' 폴백
function getChannelLabelLocal(code) {
  if (!code) return '';
  if (typeof getLookupLabel === 'function') {
    const lang = (typeof getLang === 'function') ? getLang() : 'ja';
    const lbl = getLookupLabel('channel', code, lang);
    if (lbl) return lbl;
  }
  if (CHANNEL_LABELS[code]) return CHANNEL_LABELS[code];
  return t('channelLabel.other');
}

// 게시물 수동 채널 드롭다운을 캠페인 요구 채널로만 제한 (2026-06-16).
//   자동 판별 실패(단축 URL 등) 시에도 인플이 캠페인과 다른 채널을 고르지 못하게 함.
//   캠페인 channel 이 비어 있으면(레거시 미설정) 기존 하드코딩 옵션 유지(폴백).
function populatePostChannelManualOptions() {
  const sel = $('postChannelManual');
  if (!sel) return;
  const camp = _activityCamp || {};
  const list = String(camp.channel || '').split(',').map(s => s.trim()).filter(Boolean);
  // 캠페인에 채널이 하나도 없으면 고를 수 있는 값이 없다.
  //   예전에는 그냥 return 해서 화면에 박아둔 기본 선택지가 그대로 남았고, 그 안의
  //   「その他」가 기준 데이터에 없는 값으로 저장돼 **어떤 캠페인 채널과도 영원히
  //   일치하지 않는** 결과물을 만들었다(감지 함수 C층. 실제로 2건 발생).
  //   지금은 캠페인 등록·편집 양쪽이 채널을 필수로 받아 이 상태가 새로 생기지 않지만,
  //   과거 데이터가 남아 있을 수 있으므로 방어로 남긴다 — 잘못된 값을 고르게 두느니
  //   고를 수 없음을 알리고 사람 경로로 보낸다.
  if (list.length === 0) {
    sel.innerHTML = `<option value="">${esc(t('activity.postChannelUnavailable'))}</option>`;
    sel.value = '';
    return;
  }
  const cur = sel.value;
  const opts = [`<option value="">${esc(t('common.select'))}</option>`];
  list.forEach(code => {
    opts.push(`<option value="${esc(code)}">${esc(getChannelLabelLocal(code))}</option>`);
  });
  sel.innerHTML = opts.join('');
  if (cur && list.includes(cur)) sel.value = cur;
}

function onPostUrlInputChange() {
  const raw = $('postUrlInput')?.value || '';
  const detectedLbl = $('postChannelDetected');
  const manualWrap = $('postChannelManualWrap');
  if (!raw.trim()) {
    if (detectedLbl) detectedLbl.textContent = '';
    if (manualWrap) manualWrap.style.display = 'none';
    return;
  }
  // 보정된 주소로 채널 판별 (ttp:// 등 오타가 있어도 채널 인식 — 저장 시 addDraftUrl 이 실제 보정)
  const norm = normalizeUrlInput(raw);
  const url = norm ? norm.url : raw;
  const ch = detectChannelFromUrl(url);
  if (ch) {
    if (detectedLbl) detectedLbl.textContent = t('activity.postChannelDetected').replace('{channel}', getChannelLabelLocal(ch));
    if (detectedLbl) detectedLbl.style.color = 'var(--dark-pink)';
    if (manualWrap) manualWrap.style.display = 'none';
  } else {
    if (detectedLbl) detectedLbl.textContent = t('activity.postChannelDetectFail');
    if (detectedLbl) detectedLbl.style.color = '#C33';
    if (manualWrap) manualWrap.style.display = '';
  }
}

function navigateBackFromActivity() {
  // 새로고침으로 직접 진입한 경우 _activityCampId·_activityFrom 모두 NULL —
  // openCampaign(undefined) 무반응 회귀 방지. 안전하게 응모이력으로 폴백.
  if (_activityFrom === 'mypage' || !_activityCampId) {
    navigate('mypage');
    openMypageSub('applications');
  } else {
    openCampaign(_activityCampId);
  }
}

// 활동관리 페이지 상단 「取消」 버튼 클릭 핸들러 (사양 §4-1).
// 응모이력 ⋮ 메뉴와 동일하게 openCancelModalFor 재사용. _myApps 캐시가
// 이 시점에 없을 수 있으므로 (응모이력을 거치지 않고 직접 진입한 케이스)
// loadMyApplications 로 캐시를 보장하고 모달을 연다.
async function onActivityCancelClick() {
  const appId = $('activityCancelBtn')?.dataset?.appId || _activityAppId;
  if (!appId) return;
  // _myApps 캐시에 대상 행이 있는지로 검사 — 응모이력 거치지 않고 직접 진입
  // (예: 알림 클릭 등) 케이스 모두 커버.
  const cacheReady = typeof _myApps !== 'undefined'
    && Array.isArray(_myApps)
    && !!_myApps.find(a => a.id === appId);
  if (!cacheReady && typeof loadMyApplications === 'function') {
    try { await loadMyApplications(); } catch(_e) { /* 캐시 실패해도 모달은 시도 */ }
  }
  if (typeof openCancelModalFor === 'function') openCancelModalFor(appId);
}

async function loadReceipts() { return loadDeliverablesForActivity(); }

// Stage 3: 활동관리 화면의 결과물 리스트 (영수증·게시물 통합)
async function loadDeliverablesForActivity() {
  // 이전 응모건의 건수가 남아 있으면, 아직 아무것도 안 그린 사이에 이탈 확인이 엉뚱하게 뜬다.
  //   ⚠️ 아래 렌더러들이 0 을 포함해 다시 채워 준다 — 여기서 비우는 것은 그 사이 구간용이다.
  Object.keys(_activityDraftPending).forEach(k => { _activityDraftPending[k] = 0; });
  const camp = _activityCamp || {};
  const rt = camp.recruit_type || 'monitor';
  const showImage = (rt === 'monitor' || rt === 'visit');
  const showPost = (rt === 'gifting' || rt === 'visit');
  const isMonitor = (rt === 'monitor');
  const all = await fetchDeliverablesForUser({
    application_id: _activityAppId,
    user_id: currentUser?.id
  });
  _activityLastDelivs = all || [];
  // 제출 가부는 **서버 판정을 그대로 소비**한다(사양서 §설계 3-(1), 마이그레이션 276).
  //   화면이 같은 판정을 다시 계산하면 두 벌이 되어 어긋난다 — 2단계에서 실제로 겪은 함정이다.
  _activityGate = await fetchDeliverableGate(_activityAppId);

  // 반려 사유 배너: 활동관리 페이지 상단에 표시. receipt/post/review_image
  // 모든 결과물 종류의 가장 최신 반려 1건을 후보로 집계 (각 행 안에도 사유 박스가
  // 추가로 표시되지만, 카드를 펼쳐보기 전에 한 줄로 인지하도록 상단 배너 유지).
  const banner = $('activityRejectBanner');
  const reasonEl = $('activityRejectReason');
  if (banner && reasonEl) {
    const sorted = all
      .filter(d => d.kind === 'receipt' || d.kind === 'post' || d.kind === 'review_image')
      .sort((a,b) => (b.submitted_at||'').localeCompare(a.submitted_at||''));
    const latest = sorted[0];
    if (latest && latest.status === 'rejected' && latest.reject_reason) {
      banner.style.display = '';
      reasonEl.textContent = latest.reject_reason;
    } else {
      banner.style.display = 'none';
    }
  }

  if (showImage) renderActivityReceiptList(all.filter(d => d.kind === 'receipt'));
  if (showPost) {
    renderActivityPostList(all.filter(d => d.kind === 'post'));
    populatePostChannelManualOptions();  // 수동 채널 선택칸을 캠페인 채널로 제한
  }

  // monitor 2단계: 영수증 1건 이상 approved 시 STEP 2(채널별 리뷰 캡쳐) 영역 활성화
  // 채널 없는 레거시 monitor 캠페인은 STEP 2 영역 자체를 숨김 (grandfather, 영수증만 받음)
  if (isMonitor) {
    // 가구매(proxy_purchase)·채널 없는 레거시 monitor는 STEP 2(리뷰 캡쳐) 영역 자체를 숨김 — 영수증만 받음
    const channels = (camp.channel || '').split(',').map(c => c.trim()).filter(Boolean);
    const section = $('reviewImageSection');
    if (camp.proxy_purchase || channels.length === 0) {
      if (section) section.style.display = 'none';
    } else {
      if (section) section.style.display = '';
      const receiptApproved = all.some(d => d.kind === 'receipt' && d.status === 'approved');
      const gatedNote = $('reviewImageGatedNote');
      const body = $('reviewImageBody');
      if (gatedNote) gatedNote.style.display = receiptApproved ? 'none' : '';
      if (body) body.style.display = receiptApproved ? '' : 'none';
      if (receiptApproved) {
        renderActivityReviewImageList(all.filter(d => d.kind === 'review_image'), channels);
      }
    }
  }

  // 마감 안내 + 폼 활성/비활성 결정 (데이터 로드 후 한 번에 처리)
  // 반려된 결과물(kind 별 최신 1건이 rejected)이 있으면 마감 후에도 재제출 허용 — 관리자 책임 정책
  applyFormGating(all);
}

// ── 서버 판정(get_deliverable_gate) 소비 헬퍼 ──
//   ⚠️ 여기서 「최신 1건이 반려인가」를 다시 계산하지 말 것. 그 판정의 단일 소스는
//      데이터베이스 함수 can_submit_deliverable 이다(사양서 §설계 3). 예전에는 화면에도
//      같은 판정(_latestNonDraftIsRejected)이 있어 두 벌이 어긋날 위험을 안고 있었고,
//      실제로 「재제출이 기존 행을 임시저장으로 되돌린다」는 타이밍 차이를 화면 판정만으로는
//      표현할 수 없었다(2026-07-30 2단계에서 발견).
//   조회 실패(_activityGate === null)면 **막지 않는다** — 최종 방어선은 서버 검사 장치다.
function gateAllows(kind, channel) {
  if (!Array.isArray(_activityGate)) return true;
  const rows = _activityGate.filter(g => g.kind === kind);
  if (!rows.length) return true;
  if (kind === 'receipt') return !!rows[0].allowed;
  const hit = rows.find(g => (g.post_channel || '') === (channel || ''));
  return hit ? !!hit.allowed : true;
}
// 그 종류의 항목이 **하나라도** 낼 수 있는가 (영역 단위 폼 활성·안내문 분기용)
function gateAllowsAny(kind) {
  if (!Array.isArray(_activityGate)) return true;
  const rows = _activityGate.filter(g => g.kind === kind);
  return rows.length ? rows.some(g => g.allowed) : true;
}

// 활동관리 폼 활성/비활성 + 마감 안내문 분기
//   - 마감 전: 「제출 기한: YYYY/MM/DD」 + 폼 활성 (기본 상태 유지)
//   - 마감 후 + 어떤 kind든 최신 1건 rejected: 「기한은 지났지만 재제출 가능」 + 해당 폼 활성
//   - 마감 후 + 반려 없음: 「제출 기한이 지났습니다」 빨간색 + 폼 비활성 (label 회색·input/button disabled)
function applyFormGating(allDelivs) {
  const camp = _activityCamp || {};
  const rt = camp.recruit_type || 'monitor';
  const showImage = (rt === 'monitor' || rt === 'visit');
  const showPost = (rt === 'gifting' || rt === 'visit');
  const isMonitor = (rt === 'monitor');
  const submissionEnd = camp.submission_end || null;
  // 마감 여부는 서버와 같은 기준(일본 시각)으로 본다 — 안내문 분기에만 쓴다
  const isAfterDeadline = (typeof submissionDeadlinePassed === 'function')
    ? submissionDeadlinePassed(camp)
    : (submissionEnd ? (new Date(submissionEnd + 'T23:59:59') < new Date()) : false);

  // 제출 가부는 **서버 판정**만 본다(사양서 §설계 3-(1)). 화면이 다시 계산하지 않는다.
  const receiptAllowed = gateAllowsAny('receipt');
  const reviewAllowed  = gateAllowsAny('review_image');
  const postAllowed    = gateAllowsAny('post');
  // 마감 후인데도 낼 수 있는 게 하나라도 있으면 「기한은 지났지만 재제출 가능」 안내
  // ⚠️ 안내문 분기는 **서버가 실제로 내려준 항목**만 센다. gateAllowsAny 는 「그 종류가
  //   이 캠페인에 해당 없음(행 0건)」도 true 로 돌려주는데(조회 실패 시 막지 않기 위한
  //   폴백), 그 값을 여기에 섞으면 반려가 하나도 없는 캠페인에서도 「재제출 가능」이
  //   뜬다 — 리뷰어형은 post 행이, 시딩형은 receipt·review_image 행이 애초에 0건이라
  //   무조건 true 가 된다(2026-07-31 브라우저 검증에서 양쪽 다 발견).
  //   ⚠️ 조회 실패(null)와 「해당 항목 0건」([])을 반드시 구분한다. 둘을 뭉뚱그려 빈
  //   배열로 다루면, 서버에 못 물어본 상황(네트워크 실패·DEMO_MODE)에서 폼은 열려 있는데
  //   안내문만 「기한이 지났습니다」로 닫히는 어긋난 조합이 된다. 폼 활성(gateAllowsAny)과
  //   안내문은 폴백 방향이 같아야 한다 — 조회 실패 시엔 둘 다 막지 않는 쪽(2026-07-31 리뷰).
  const gateRows = Array.isArray(_activityGate) ? _activityGate : null;
  //   변수명 주의: 「반려가 있는가」가 아니라 「마감 후에도 낼 수 있는 항목이 남았는가」다.
  //   서버 판정에서 마감 후 통과 사유는 반려 예외(rejected_exception/_history)뿐이므로
  //   결과적으로 같지만, 판단 근거는 어디까지나 서버가 준 allowed 값이다.
  const stillSubmittable = isAfterDeadline
    && (gateRows ? gateRows.some(g => g.allowed) : true);

  // 마감 안내문 (전체 상단에 하나만)
  const deadlineBox = $('activitySubmissionDeadline');
  if (deadlineBox && submissionEnd) {
    deadlineBox.style.display = '';
    if (!isAfterDeadline) {
      deadlineBox.textContent = `${t('activity.submissionEndLabel')}: ${formatDate(submissionEnd)}`;
      deadlineBox.style.color = 'var(--muted)';
    } else if (stillSubmittable) {
      deadlineBox.textContent = t('activity.submissionEndPastButRejected').replace('{date}', formatDate(submissionEnd));
      deadlineBox.style.color = '#B8741A';
    } else {
      deadlineBox.textContent = `${t('activity.submissionEndPast')} (${formatDate(submissionEnd)})`;
      deadlineBox.style.color = '#C33';
    }
  }

  // 폼 비활성 결정 — 서버가 「낼 수 없다」고 한 종류만 잠근다
  const receiptDisabled = !receiptAllowed;
  const reviewDisabled  = !reviewAllowed;
  const postDisabled    = !postAllowed;

  if (showImage) {
    _setFormDisabled({
      labelId: 'receiptFileLabel',
      inputIds: ['receiptFile', 'receiptOrderNumber', 'receiptDate', 'receiptAmount'],
      buttonIds: ['addReceiptBtn', 'submitImagesBtn']
    }, receiptDisabled);
  }
  // monitor 채널별 리뷰 카드는 renderActivityReviewImageList 가 카드 단위로 폼 disabled 처리 +
  // 통합 제출 버튼(submitReviewImageBtn)도 거기서 「낼 수 있는 임시저장이 있을 때만」 노출한다
  // (채널마다 가부가 갈리므로 카드를 그리는 쪽이 판단해야 한다 — 여기서 일괄로 잠그면
  //  인스타그램만 반려된 경우처럼 일부 채널만 낼 수 있는 상황을 표현할 수 없다).
  // reviewAllowed/reviewDisabled 변수는 위 마감 안내문 분기에서 계속 사용.
  if (showPost) {
    _setFormDisabled({
      labelId: null,
      inputIds: ['postUrlInput', 'postChannelManual'],
      buttonIds: ['addPostBtn', 'submitPostsBtn']
    }, postDisabled);
  }
}

// 한 폼의 label / input / button 묶음을 disabled 토글
//   label: <label> 회색 처리 + 클릭 차단 (file input 트리거 막기) — CSS 클래스 토글
//     inline style 의 background:var(--pink) 를 보존하기 위해 클래스 방식 사용
//   input/button: disabled 속성 직접 설정
function _setFormDisabled(targets, disabled) {
  if (targets.labelId) {
    const lab = $(targets.labelId);
    if (lab) lab.classList.toggle('form-label-disabled', disabled);
  }
  (targets.inputIds || []).forEach(function(id) {
    const el = $(id); if (el) el.disabled = disabled;
  });
  (targets.buttonIds || []).forEach(function(id) {
    const el = $(id); if (el) el.disabled = disabled;
  });
}

function renderActivityReceiptList(delivs) {
  const container = $('receiptList');
  if (!container) return;
  const submitBtn = $('submitImagesBtn');
  const formBox = $('receiptForm');
  const addBtn = $('addReceiptBtn');
  const maxNote = $('receiptMaxNote');
  // monitor 캠페인은 영수증 1장만 제출 가능 (visit는 현장 사진 여러 장 가능 — 그대로 둠)
  // active 판정: kind별 가장 최신 1건이 rejected가 아니면 active로 본다.
  //   같은 application에 옛 pending 행이 누적되어도(관리자 미검수 방치 등) 가장 최신이
  //   rejected면 재제출 form 노출. 2026-05-12 a4y2u9.i@gmail.com 케이스 — pending 3건
  //   누적 + 최신 rejected였는데 단순 `status !== 'rejected'` 카운트로 인해 재제출 차단됨.
  const isMonitor = (_activityCamp?.recruit_type === 'monitor');
  const latestPerKind = {};
  (delivs || []).forEach(function(d) {
    var prev = latestPerKind[d.kind];
    if (!prev || new Date(d.created_at) > new Date(prev.created_at)) latestPerKind[d.kind] = d;
  });
  const activeCount = Object.values(latestPerKind).filter(function(d) { return d.status !== 'rejected'; }).length;
  const reachedMax = isMonitor && activeCount >= 1;
  if (formBox) formBox.style.display = reachedMax ? 'none' : '';
  if (addBtn) addBtn.style.display = reachedMax ? 'none' : '';
  if (maxNote) maxNote.style.display = reachedMax ? '' : 'none';

  if (!delivs.length) {
    container.innerHTML = `<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">${t('activity.noImage')}</div>`;
    if (submitBtn) submitBtn.style.display = 'none';
    renderDraftPendingBar('receipt', 0);
    return;
  }
  let draftCount = 0;
  container.innerHTML = splitDeliverableGroups(delivs, r => {
    const isDraft = r.status === 'draft';
    if (isDraft) draftCount++;
    const stBadge = isDraft
      ? `<span style="background:#e5e7eb;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('activity.draftBadge')}</span>`
      : activityStatusBadge(r.status);
    const rightCol = isDraft
      ? `<button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="deleteDraft('${esc(r.id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete</span></button>`
      : `<div style="font-size:10px;color:var(--muted)">${formatDate(r.submitted_at || r.created_at)}</div>`;
    // 반려된 결과물에는 행 하단에 사유 박스 표시 (상단 배너와는 별개로 행 단위 인지 강화)
    const reasonBox = (r.status === 'rejected' && r.reject_reason)
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FFF5F5;border-left:3px solid #C33;border-radius:6px;font-size:11px;color:#C33;white-space:pre-wrap;line-height:1.5">${esc(r.reject_reason)}</div>`
      : '';
    // 마이그레이션 160: 관리자 대리 등록 행이면 한 줄 일본어 설명 상시 노출 (사용자 결정 2026-05-28)
    const proxyBox = r.submitted_by_admin
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FEF3C7;border-left:3px solid #FBBF24;border-radius:6px;font-size:11px;color:#92400E;line-height:1.5">${activityProxyNoticeJa(r)}</div>`
      : '';
    return `
    <div style="padding:12px;background:var(--surface);border:1px solid var(--outline);border-radius:12px;margin-bottom:8px">
      <div style="display:flex;align-items:center;gap:12px">
        <div style="width:56px;height:56px;border-radius:8px;overflow:hidden;flex-shrink:0;background:#f5f5f5">
          ${r.receipt_url ? `<img src="${esc(imgThumb(r.receipt_url,112,80))}" data-orig="${esc(r.receipt_url)}" loading="lazy" decoding="async" style="width:100%;height:100%;object-fit:contain;cursor:pointer;background:#f5f5f5" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" onclick="window.open('${esc(r.receipt_url)}','_blank')">` : ''}
        </div>
        <div style="flex:1;min-width:0">
          ${stBadge}
        </div>
        <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">
          ${rightCol}
        </div>
      </div>
      ${proxyBox}
      ${reasonBox}
    </div>`;
  }, 'receipt');
  if (submitBtn) submitBtn.style.display = draftCount ? '' : 'none';
  renderDraftPendingBar('receipt', draftCount);
}

// monitor 2단계 — 캠페인 채널 수만큼 「채널별 리뷰 이미지 카드」를 N개 동적 렌더.
//   채널별로: 해당 채널의 최신 1건 행 표시(승인/검수중/반려) + 행이 없거나 최신이 반려이면 업로드 폼 노출.
//   채널 간 독립: A 채널 검수중 + B 채널 미제출 + C 채널 반려 동시 가능.
//   기존 채널 없는 monitor 캠페인(`post_channel=NULL` 레거시 행)은 §2 정정에 따라 STEP 2 영역 자체를 숨김 → 이 함수가 호출되지 않음.
function renderActivityReviewImageList(delivs, channels) {
  const container = $('reviewImageList');
  if (!container) return;
  const submitBtn = $('submitReviewImageBtn');
  const camp = _activityCamp || {};
  // ⚠️ 마감·재제출 가부는 서버 판정(gateAllows)만 본다. 화면에서 다시 계산하지 말 것.
  //   채널 코드 → 최신 1건 매핑 (post_channel 기준, NULL 레거시 행은 무시)
  const latestByChannel = {};
  (delivs || []).forEach(function(d) {
    if (!d.post_channel) return;  // NULL 레거시 행 무시
    const prev = latestByChannel[d.post_channel];
    if (!prev || new Date(d.created_at) > new Date(prev.created_at)) latestByChannel[d.post_channel] = d;
  });

  // hasSubmittableDraft = 「서버가 제출을 허용한 채널」의 임시저장이 하나라도 있는가.
  //   단순히 임시저장 유무(hasDraft)로 버튼을 띄우면, 마감이 지나 서버가 거부할 채널의
  //   임시저장만 남았을 때도 버튼이 눌리는 상태로 노출된다(2026-07-31 브라우저 검증에서 발견).
  let hasSubmittableDraft = false;
  let submittableDraftCount = 0;   // 안내 줄 건수 — 버튼이 실제로 보낼 것과 같은 수여야 한다
  container.innerHTML = (channels || []).map(function(ch) {
    const chLabel = getChannelLabelLocal(ch) || ch;
    const row = latestByChannel[ch];
    // 폼 표시 조건: 행 없음 OR 최신이 rejected (표시용). 실제 제출 가부는 서버 판정.
    const needForm = !row || row.status === 'rejected';
    const formDisabled = !gateAllows('review_image', ch);
    let cardBody = '';

    if (row) {
      const isDraft = row.status === 'draft';
      if (isDraft && !formDisabled) { hasSubmittableDraft = true; submittableDraftCount++; }
      const stBadge = isDraft
        ? `<span style="background:#e5e7eb;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('activity.draftBadge')}</span>`
        : activityStatusBadge(row.status);
      const rightCol = isDraft
        ? `<button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="deleteDraft('${esc(row.id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete</span></button>`
        : `<div style="font-size:10px;color:var(--muted)">${formatDate(row.submitted_at || row.created_at)}</div>`;
      const reasonBox = (row.status === 'rejected' && row.reject_reason)
        ? `<div style="margin-top:8px;padding:8px 10px;background:#FFF5F5;border-left:3px solid #C33;border-radius:6px;font-size:11px;color:#C33;white-space:pre-wrap;line-height:1.5">${esc(row.reject_reason)}</div>`
        : '';
      // 마이그레이션 160: 관리자 대리 등록 노랑 박스 (사양 2 운영 후 review_image 대리 등록 활성)
      const proxyBox = row.submitted_by_admin
        ? `<div style="margin-top:8px;padding:8px 10px;background:#FEF3C7;border-left:3px solid #FBBF24;border-radius:6px;font-size:11px;color:#92400E;line-height:1.5">${activityProxyNoticeJa(row)}</div>`
        : '';
      const thumb = row.receipt_url
        ? `<img src="${esc(imgThumb(row.receipt_url,112,80))}" data-orig="${esc(row.receipt_url)}" loading="lazy" decoding="async" style="width:100%;height:100%;object-fit:contain;cursor:pointer;background:#f5f5f5" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}" onclick="window.open('${esc(row.receipt_url)}','_blank')">`
        : '';
      cardBody += `
        <div style="display:flex;align-items:center;gap:12px">
          <div style="width:56px;height:56px;border-radius:8px;overflow:hidden;flex-shrink:0;background:#f5f5f5">${thumb}</div>
          <div style="flex:1;min-width:0">${stBadge}</div>
          <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">${rightCol}</div>
        </div>
        ${proxyBox}
        ${reasonBox}`;
    }

    if (needForm) {
      // 카드별 업로드 폼: 채널 코드를 ID 접미사로 사용해 카드 간 격리
      const disabledAttr = formDisabled ? 'disabled' : '';
      const disabledStyle = formDisabled ? 'opacity:0.5;pointer-events:none' : '';
      cardBody += `
        <div style="margin-top:${row ? '12' : '0'}px;background:var(--bg);border:1.5px dashed var(--outline);border-radius:12px;padding:14px;${disabledStyle}">
          <div id="reviewImagePreview-${esc(ch)}" style="margin-bottom:8px"></div>
          <label style="display:flex;align-items:center;justify-content:center;gap:6px;padding:10px 16px;background:var(--pink);color:#fff;border-radius:var(--r-full);font-size:13px;font-weight:600;cursor:pointer">
            <span class="material-icons-round notranslate" translate="no" style="font-size:18px">add_a_photo</span>
            <span data-i18n="activity.imageBtn">画像を選択</span>
            <input type="file" accept="image/*" style="display:none" ${disabledAttr} onchange="previewReviewImage(this, '${esc(ch)}')">
          </label>
          <button class="btn btn-ghost btn-block" style="margin-top:10px" ${disabledAttr} onclick="addDraftReviewImage('${esc(ch)}', this)" data-i18n="activity.addDraftBtn">リストに追加</button>
        </div>`;
    }

    return `
      <div style="padding:14px;background:var(--surface);border:1px solid var(--outline);border-radius:14px;margin-bottom:12px">
        <div style="font-size:13px;font-weight:700;color:var(--ink);margin-bottom:10px">「${esc(chLabel)}」<span data-i18n="activity.reviewImageOfChannelLabel">のレビュー画像</span></div>
        ${cardBody}
      </div>`;
  }).join('');

  // 통합 제출 버튼은 **낼 수 있는** 임시저장이 있을 때만 노출·활성화한다.
  //   서버가 거부할 채널의 임시저장만 남았는데 버튼을 띄우면 「눌리는데 결국 실패하는
  //   버튼」이 되어, 3단계(화면 판정 서버 일원화)가 없애려던 바로 그 패턴이 남는다.
  //   남은 임시저장 자체는 각 카드의 삭제 버튼으로 정리할 수 있다(막다른 골목 아님).
  if (submitBtn) {
    submitBtn.style.display = hasSubmittableDraft ? '' : 'none';
    submitBtn.disabled = !hasSubmittableDraft;
  }
  renderDraftPendingBar('review_image', submittableDraftCount);
  // 카드별 data-i18n 처리 (renderActivityReviewImageList 가 동적으로 마크업을 갈아끼우므로 호출 후 i18n 적용)
  if (typeof applyI18n === 'function') applyI18n(container);
}


// 결과물 목록을 「지난 제출」과 「제출할 항목」 두 무리로 나눈다.
//   ⚠️ 왜 나누나 — 제출 버튼이 목록 **아래**에 있어서, 섞여 있으면 위의 모든 행을
//   보내는 것처럼 보인다(2026-08-25 사용자 지적: 「비승인 3건까지 같이 제출되는
//   것처럼 읽힌다」). 실제로 보내는 것은 임시저장뿐이다.
//   ⚠️ 임시저장을 **아래쪽**에 둔다 — 버튼·안내 줄이 바로 뒤에 붙어야 「이것을 보낸다」가
//   눈으로 이어진다.
//   ⚠️ 한쪽 무리가 비면 제목을 안 붙인다 — 나눌 것이 없는데 제목만 있으면 군더더기다.
//   ⚠️ 「지난 제출」은 **최근 1건만** 펼쳐 두고 나머지는 접는다 — 재제출을 거듭하면
//   반려 이력이 쌓여, 정작 지금 해야 할 일(아래 「제출할 항목」)이 화면 밖으로 밀린다.
//   ⚠️ 목록은 **제출 시각 내림차순**으로 들어온다(application.js 의 정렬). 그래서 첫
//   번째가 최근이다 — 순서가 바뀌면 옛것이 대표로 뜨므로 그 정렬을 함께 볼 것.
//   ⚠️ 펼친 상태는 다시 그려도 유지한다(_activityPastOpen) — 펼쳐 놓고 한 건 추가했다고
//   접혀 버리면 방금 본 것을 다시 찾아야 한다.
const _activityPastOpen = new Set();
// ⚠️ 펼침 상태는 **응모건마다** 따로 기억한다. 종류(receipt·post)로만 키를 잡으면
//   A 응모건에서 펼친 것이 B 응모건까지 펼쳐진 채로 넘어가, 그 화면도 늘어진 채
//   시작한다 — 이 기능을 만든 이유(쌓인 이력에 할 일이 묻힌다)가 그대로 재발한다.
function _activityPastKey(kind) { return String(_activityAppId || '') + ':' + kind; }
function toggleActivityPastMore(kind) {
  const k = _activityPastKey(kind);
  if (_activityPastOpen.has(k)) _activityPastOpen.delete(k);
  else _activityPastOpen.add(k);
  // ⚠️ 서버를 다시 부르지 않는다 — 직전 조회 결과를 그대로 다시 그린다.
  //   loadDeliverablesForActivity() 를 부르면 조회가 **매번 2회**(목록 + 제출 가부)
  //   돌고 화면이 깜빡인다. 펼치기는 이미 받아 둔 것을 보여주는 일일 뿐이다.
  //   ⚠️ 거르는 기준은 그 로더가 쓰는 것과 **같아야** 한다 — 종류로만 거른다.
  const rows = (_activityLastDelivs || []).filter(d => d.kind === kind);
  if (kind === 'receipt') renderActivityReceiptList(rows);
  else if (kind === 'post') renderActivityPostList(rows);
}
function splitDeliverableGroups(rows, renderRow, key) {
  const past = [], todo = [];
  (rows || []).forEach(function(r) { (r.status === 'draft' ? todo : past).push(r); });
  const head = k => `<div class="deliv-group-head">${esc(t('activity.' + k))}</div>`;
  const both = past.length && todo.length;
  let html = '';
  if (past.length) {
    const open = _activityPastOpen.has(_activityPastKey(key));
    const hidden = past.length - 1;
    // ⚠️ 제목 줄은 「나눌 것이 있을 때」뿐 아니라 「접을 것이 있을 때」도 그린다 —
    //   펼치기 버튼이 그 줄에 얹히므로, 제목을 안 그리면 버튼도 함께 사라진다.
    if (both || hidden > 0) {
      const label = open
        ? t('activity.pastLess')
        : String(t('activity.pastMore')).replace('{n}', String(hidden));
      const toggle = hidden > 0
        ? `<button type="button" class="deliv-past-toggle" onclick="toggleActivityPastMore('${esc(key)}')">${esc(label)}</button>`
        : '';
      html += `<div class="deliv-group-head deliv-group-head-row"><span>${esc(t('activity.groupPast'))}</span>${toggle}</div>`;
    }
    html += renderRow(past[0]);
    if (open && hidden > 0) html += past.slice(1).map(renderRow).join('');
  }
  if (todo.length) html += (both ? head('groupToSubmit') : '') + todo.map(renderRow).join('');
  return html;
}

// ── 「아직 제출 안 함」 안내 줄 (세 화면 공용) ────────────────────────────
//   2026-08-25: 운영에서 결과물 26건이 임시저장으로 멈춰 있었다(게시물 23·인증샷 2·
//   영수증 1 — 세 종류 전부, 4개월간 누적). 「リストに追加」만 누르고 끝난 줄 아는
//   사람이 이어졌다. 같은 일이 2026-04-27 에도 있었고(마이그레이션 073 머리말),
//   그때는 화면을 안 고쳤다.
//   ⚠️ 세 화면이 반드시 이 함수 하나를 쓴다 — 따로 쓰면 화면마다 다른 말이 된다.
//   ⚠️ 안내 줄은 **제출 버튼과 항상 같이** 뜨고 같이 사라진다. 버튼 없이 안내만
//      남으면 「하라는데 할 수가 없는」 막다른 길이 된다.
//   ⚠️ 0건이면 아무것도 안 그린다(정상 흐름의 몇 초도 미제출 상태다 — 상시 노출되면
//      「원래 그런 화면」으로 학습돼 아무도 안 본다).
const DRAFT_BAR_IDS = {receipt: 'draftBarReceipt', review_image: 'draftBarReviewImage', post: 'draftBarPost'};
// 종류별 「아직 안 낸」 건수. 이탈 확인(navigate)이 이 값을 본다.
//   ⚠️ 세 렌더러가 **반드시** renderDraftPendingBar 를 거치므로 여기 한 곳에서만 갱신한다.
//      따로 세면 안내 줄이 말하는 수와 이탈 확인이 보는 수가 갈린다.
const _activityDraftPending = {receipt: 0, review_image: 0, post: 0};
// 지금 활동관리 화면에 「낼 수 있는데 안 낸 것」이 있는가 (이탈 확인용)
function activityHasSubmittableDraft() {
  return Object.keys(_activityDraftPending).some(k => _activityDraftPending[k] > 0);
}
function renderDraftPendingBar(kind, count) {
  const n = Number(count) || 0;
  // ⚠️ 건수 기록은 **화면 요소를 찾기 전에** 한다 — 안내 줄이 없는 화면이라고 해서
  //    「안 낸 것이 없다」가 되면, 그 화면에서 나갈 때 이탈 확인이 조용히 안 뜬다.
  if (kind in _activityDraftPending) _activityDraftPending[kind] = n;
  const el = $(DRAFT_BAR_IDS[kind]);
  if (!el) return;
  if (n <= 0) { el.style.display = 'none'; el.innerHTML = ''; return; }
  el.innerHTML =
    `<div class="dpb-title">${esc(String(t('activity.draftPendingTitle')).replace('{n}', String(n)))}</div>` +
    `<div class="dpb-step">${esc(t('activity.draftPendingStep'))}</div>`;
  el.style.display = '';
}

function renderActivityPostList(delivs) {
  const container = $('postSubmissionList');
  if (!container) return;
  const submitBtn = $('submitPostsBtn');
  if (!delivs.length) {
    container.innerHTML = `<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">${t('activity.noPost')}</div>`;
    if (submitBtn) submitBtn.style.display = 'none';
    renderDraftPendingBar('post', 0);
    return;
  }
  // 「낼 수 있는」 임시저장만 센다 — 리뷰 인증샷(renderActivityReviewImageList)과 같은 기준.
  //   ⚠️ 예전에는 임시저장이 있기만 하면 버튼을 띄웠다(종류 단위). 그러면 A채널은 낼 수 있고
  //      B채널만 서버가 거부하는 상황에서 버튼이 활성인 채로 눌리고, 부분 실패한 뒤에도
  //      **무엇이 못 나갔는지 알려주지 않았다**. 리뷰 인증샷은 처음부터 채널 단위였는데
  //      게시물만 종류 단위라 두 화면이 서로 다르게 동작했다(2026-08-25 작업표 S1).
  //   ⚠️ `gateAllows` 는 그 종류 행이 0건이면 `true` 다 — 채널이 빈 시딩 캠페인에서는
  //      종전처럼 버튼이 그대로 뜬다(막지 않는 방향). 조회 실패도 같다.
  let submittableDraftCount = 0;
  container.innerHTML = splitDeliverableGroups(delivs, d => {
    const isDraft = d.status === 'draft';
    if (isDraft && gateAllows('post', d.post_channel)) submittableDraftCount++;
    const stBadge = isDraft
      ? `<span style="background:#e5e7eb;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('activity.draftBadge')}</span>`
      : activityStatusBadge(d.status);
    const chLabel = getChannelLabelLocal(d.post_channel) || d.post_channel || '—';
    const actionBtn = isDraft
      ? `<button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="deleteDraft('${esc(d.id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete</span></button>`
      : '';
    const reasonBox = (d.status === 'rejected' && d.reject_reason)
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FFF5F5;border-left:3px solid #C33;border-radius:6px;font-size:11px;color:#C33;white-space:pre-wrap;line-height:1.5">${esc(d.reject_reason)}</div>`
      : '';
    // 마이그레이션 160: 관리자 대리 등록 노랑 박스
    const proxyBox = d.submitted_by_admin
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FEF3C7;border-left:3px solid #FBBF24;border-radius:6px;font-size:11px;color:#92400E;line-height:1.5">${activityProxyNoticeJa(d)}</div>`
      : '';
    return `
    <div style="padding:12px;background:var(--surface);border:1px solid var(--outline);border-radius:12px;margin-bottom:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px">
        <div style="font-size:12px;font-weight:600;color:var(--ink)">${esc(chLabel)}</div>
        <div style="display:flex;align-items:center;gap:6px">${stBadge}${actionBtn}</div>
      </div>
      <a href="${esc(d.post_url||'')}" target="_blank" rel="noopener" style="font-size:12px;color:var(--dark-pink);word-break:break-all;text-decoration:none">${esc(d.post_url||'')}</a>
      <div style="font-size:10px;color:var(--muted);margin-top:4px">${formatDate(d.submitted_at)}</div>
      ${proxyBox}
      ${reasonBox}
    </div>`;
  }, 'post');
  // 버튼과 안내 줄이 **같은 수**를 봐야 한다 — 안내 줄이 「N건 남았다」는데 버튼이 그중
  //   일부만 보내면 그 차이를 아무도 설명해 주지 않는다.
  if (submitBtn) {
    submitBtn.style.display = submittableDraftCount ? '' : 'none';
    submitBtn.disabled = !submittableDraftCount;
  }
  renderDraftPendingBar('post', submittableDraftCount);
}

function activityStatusBadge(status) {
  if (status === 'approved') return `<span style="background:#E4F5E8;color:#2D7A3E;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.approved')}</span>`;
  if (status === 'rejected') return `<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.rejected')}</span>`;
  return `<span style="background:#FFF4E4;color:#B8741A;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.pending')}</span>`;
}

// 마이그레이션 160: 인플 화면 「운영 측에서 등록」 한 줄 일본어 안내 (사용자 결정 2026-05-28)
// 사유 메모(자유 텍스트)는 운영 내부 정보이므로 노출하지 않고 사유 라벨만 노출.
function activityProxyNoticeJa(deliverable) {
  if (!deliverable || !deliverable.submitted_by_admin) return '';
  const code = deliverable.submitted_by_admin_reason_code || '';
  // 시드 4건 인라인 일본어 매핑 (마이그레이션 160 lookup_values admin_proxy_reason)
  const REASON_JA = {
    shipping_delay:      '配送遅延',
    system_error:        'システムエラー',
    inflexible_deadline: '期間外協議',
    other:               'その他'
  };
  const reasonJa = REASON_JA[code] || code || '—';
  return `運営側で登録 — ${esc(reasonJa)}`;
}

function previewReceipt(input) {
  const file = input.files[0];
  if (!file) return;
  _receiptOcrFile = file;  // OCR 자동입력용 원본 파일 보관
  // 이미지 새로 고르면 이전 OCR 안내 초기화 + 이전 이미지로 OCR 자동입력한 칸 비움
  // (손으로 직접 입력한 칸은 ocrFilled 표시가 없어 보존 → 새 이미지로 다시 자동입력 가능)
  const ocrStatus = $('receiptOcrStatus'); if (ocrStatus) { ocrStatus.style.display = 'none'; ocrStatus.textContent = ''; }
  clearOcrFilledReceiptFields();
  const reader = new FileReader();
  reader.onload = e => {
    _receiptImgData = e.target.result;
    $('receiptPreview').innerHTML = `<img src="${_receiptImgData}" style="max-width:100%;max-height:200px;border-radius:10px;margin-bottom:8px">`;
  };
  reader.readAsDataURL(file);
}

// 영수증 글자 자동입력 (기기 안 처리). 빈 칸만 채우고, 실패해도 제출엔 영향 없음.
// 영수증 구매금액 아래 「이 금액이 그대로 송금됩니다」 안내(마이그레이션 300 이후).
// ⚠️ 리뷰어형(monitor)에서만 그린다 — 방문형(visit)도 이 폼으로 현장 사진을 내지만
// 방문형 정산은 현금 리워드 기준이라, 띄우면 사실과 다른 안내가 된다.
// 상한(제품 가격)이 없거나 0 이면 3번 줄(상한 안내)만 빼고 나머지는 그대로 보여준다.
function renderReceiptPayoutNote(camp) {
  const box = $('receiptPayoutNote');
  if (!box) return;
  camp = camp || {};
  if (camp.recruit_type !== 'monitor') { box.style.display = 'none'; box.innerHTML = ''; return; }
  const price = Number(camp.product_price);
  const hasCap = Number.isFinite(price) && price > 0;
  const lines = [t('activity.payoutNote1'), t('activity.payoutNote2')];
  if (hasCap) lines.push(t('activity.payoutNote3').replace('{price}', price.toLocaleString()));
  lines.push(t('activity.payoutNote4'));
  box.innerHTML = `<div style="font-weight:700;margin-bottom:6px">${esc(t('activity.payoutNoteTitle'))}</div>`
    + `<ol style="margin:0;padding-left:18px">${lines.map(s => `<li style="margin-bottom:2px">${esc(s)}</li>`).join('')}</ol>`;
  box.style.display = '';
}

// 언어 전환 시 이 안내만 옛 언어로 남지 않게 다시 그린다 — 동적 렌더라 applyI18n
// 대상이 아니고, app.js 의 langchange 재렌더 목록에도 활동관리 화면은 없다.
// (마이페이지 정산 화면이 쓰는 패턴과 같다 — mypage.js)
window.addEventListener('langchange', () => {
  const page = $('page-activity');
  if (page && page.classList.contains('active') && _activityCamp) renderReceiptPayoutNote(_activityCamp);
});

async function runReceiptAutofill() {
  const btn = $('receiptOcrBtn');
  const statusEl = $('receiptOcrStatus');
  const show = msg => { if (statusEl) { statusEl.style.display = ''; statusEl.textContent = msg; } };
  if (typeof runReceiptOcr !== 'function') { show(t('activity.ocrFailed')); return; }
  if (!_receiptOcrFile) { show(t('activity.ocrNoImage')); return; }
  if (btn) btn.disabled = true;
  try {
    show(t('activity.ocrLoading'));
    const { fields } = await runReceiptOcr(_receiptOcrFile, {
      onProgress: (stage, prog) => {
        if (stage === 'recognize') show(`${t('activity.ocrRunning')} ${Math.round((prog || 0) * 100)}%`);
        else if (stage === 'load') show(t('activity.ocrLoading'));
        else show(t('activity.ocrRunning'));
      }
    });
    // 자동입력을 다시 눌러도 이전 OCR 값은 새로 갱신 (손입력 칸은 ocrFilled 표시가 없어 보존)
    clearOcrFilledReceiptFields();
    // 빈 칸만 채우기 (사용자가 직접 입력한 값은 보존)
    let filled = 0;
    const on = $('receiptOrderNumber');
    if (on && !on.value.trim() && fields.order) { on.value = fields.order; markOcrFilled(on); filled++; }
    const dt = $('receiptDate');
    if (dt && !dt.value && fields.date) { dt.value = fields.date; markOcrFilled(dt); filled++; }
    const am = $('receiptAmount');
    if (am && am.value === '' && fields.amount != null) { am.value = fields.amount; markOcrFilled(am); filled++; }
    if (filled > 0) {
      show(t('activity.ocrDone'));
    } else {
      // 빈 칸이 없어 못 채운 경우와 진짜 인식 실패를 구분
      const got = !!fields.order || !!fields.date || fields.amount != null;
      show(got ? t('activity.ocrAlready') : t('activity.ocrFailed'));
    }
  } catch (e) {
    console.warn('영수증 OCR 실패', e);
    show(t('activity.ocrFailed'));
  } finally {
    if (btn) btn.disabled = false;
  }
}

// OCR 로 채운 칸 시각 표시 (녹색) + ocrFilled 표시(이미지 교체 시 이 칸만 비움 판단용).
// 사용자가 직접 수정하면 손입력으로 간주 → 표시·녹색 해제(이후 이미지 교체해도 보존).
function markOcrFilled(el) {
  if (!el) return;
  el.style.background = '#F0FDF4';
  el.style.borderColor = '#BBF7D0';
  el.dataset.ocrFilled = '1';
  const clear = () => { el.style.background = ''; el.style.borderColor = ''; delete el.dataset.ocrFilled; el.removeEventListener('input', clear); };
  el.addEventListener('input', clear);
}

// OCR 로 채운 영수증 3칸만 비움 (손으로 입력한 칸은 dataset.ocrFilled 표시가 없어 보존).
// 이미지 재선택·자동입력 재실행 시 호출 → 새 인식 결과로 갱신 가능.
function clearOcrFilledReceiptFields() {
  ['receiptOrderNumber', 'receiptDate', 'receiptAmount'].forEach(id => {
    const el = $(id);
    if (el && el.dataset.ocrFilled) { el.value = ''; el.style.background = ''; el.style.borderColor = ''; delete el.dataset.ocrFilled; }
  });
}

// monitor 2단계 — 채널별 리뷰 캡쳐 미리보기 (채널 코드를 인자로 받아 격리)
function previewReviewImage(input, channel) {
  const file = input.files[0];
  if (!file || !channel) return;
  const reader = new FileReader();
  reader.onload = e => {
    _reviewImgDataByChannel[channel] = e.target.result;
    const prev = document.getElementById('reviewImagePreview-' + channel);
    if (prev) prev.innerHTML = `<img src="${_reviewImgDataByChannel[channel]}" style="max-width:100%;max-height:200px;border-radius:10px;margin-bottom:8px">`;
  };
  reader.readAsDataURL(file);
}

// Draft URL 추가 (gifting/visit — SNS 게시 URL 제출)
//   연타 잠금으로 감쌈(사양서 2026-07-31 §3 단계 1). 해제는 헬퍼 finally 한 곳.
async function addDraftUrl() {
  return withSubmitLock('draftUrl', 'addPostBtn', t('common.submitting'), _addDraftUrlInner);
}

async function _addDraftUrlInner() {
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const rawUrl = ($('postUrlInput')?.value || '').trim();
  if (!rawUrl) { toast(t('activity.needUrl'), 'error'); return; }
  // URL 오타 자동 보정 (2026-06-16) — ttp:// 등 흔한 실수·스킴 누락 교정, 위험 스킴 차단
  const norm = normalizeUrlInput(rawUrl);
  if (!norm) { toast(t('activity.badUrlFormat'),'error'); return; }
  const url = norm.url;
  if (norm.changed) toast(t('activity.urlFixed').replace('{url}', url), 'success');

  const camp = _activityCamp || {};

  let channel = detectChannelFromUrl(url);
  if (!channel) {
    channel = $('postChannelManual')?.value || '';
    if (!channel) { toast(t('activity.needChannel'), 'error'); return; }
  }

  // 캠페인이 요구하는 채널과 일치하는지 검증 (2026-06-16) —
  // 인플이 캠페인과 다른 SNS 링크(예: 인스타 캠페인에 LIPS URL)를 올려도 통과하던 사고 차단.
  if (!postChannelMatchesCampaign(camp, channel)) {
    const reqLabels = String(camp.channel || '')
      .split(',').map(s => s.trim()).filter(Boolean)
      .map(c => getChannelLabelLocal(c)).join('・');
    toast(t('activity.channelMismatch').replace('{channels}', reqLabels), 'error');
    return;
  }

  // 제출 가부는 서버 판정만 본다(사양서 §설계 3-(1)). 게시물도 3단계부터 **채널 단위**라
  //   채널이 확정된 뒤에 검사한다 — 위 URL 판별 전에는 어느 채널인지 알 수 없다.
  if (!gateAllows('post', channel)) { toast(t('activity.afterDeadline'),'error'); return; }

  try {
    const id = await insertDraftDeliverable({
      application_id: _activityAppId,
      user_id: currentUser.id,
      campaign_id: _activityCampId,
      kind: 'post',
      post_url: url,
      post_channel: channel
    });
    if (!id) { toast(t('activity.saveFail'), 'error'); return; }
    $('postUrlInput').value = '';
    const ch = $('postChannelDetected'); if (ch) ch.textContent = '';
    const mw = $('postChannelManualWrap'); if (mw) mw.style.display = 'none';
    toast(t('activity.draftAddedNeedSubmit'), 'success');
    await loadDeliverablesForActivity();
  } catch(e) { toast(friendlyErrorJa(e), 'error'); }
}

// Draft 이미지 추가 (monitor/visit — 영수증·현장 사진 제출)
//   업로드가 끼어 시간 창이 넓다 → 진행 문구를 「올리는 중」으로.
async function addDraftImage() {
  return withSubmitLock('draftImage', 'addReceiptBtn', t('common.uploading'), _addDraftImageInner);
}

async function _addDraftImageInner() {
  if (!_receiptImgData) { toast(t('activity.needImage'),'error'); return; }
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const camp = _activityCamp || {};
  // 제출 가부는 서버 판정만 본다(사양서 §설계 3-(1))
  if (!gateAllows('receipt', null)) { toast(t('activity.afterDeadline'),'error'); return; }

  // monitor(리뷰어) 전용 필수 필드 검증 — 마이그레이션 128
  const isMonitor = (camp.recruit_type === 'monitor');
  let orderNumber = null;
  let purchaseDate = null;
  let purchaseAmount = null;
  if (isMonitor) {
    orderNumber = ($('receiptOrderNumber')?.value || '').trim();
    purchaseDate = $('receiptDate')?.value || '';
    const rawAmount = $('receiptAmount')?.value || '';
    if (!orderNumber) { toast(t('activity.needOrderNumber'), 'error'); return; }
    if (orderNumber.length > 200) { toast(t('activity.orderNumberTooLong'), 'error'); return; }
    if (!purchaseDate) { toast(t('activity.needPurchaseDate'), 'error'); return; }
    if (rawAmount === '' || rawAmount === null || rawAmount === undefined) {
      toast(t('activity.needPurchaseAmount'), 'error'); return;
    }
    purchaseAmount = Number(rawAmount);
    if (!Number.isFinite(purchaseAmount) || purchaseAmount < 0) {
      toast(t('activity.invalidPurchaseAmount'), 'error'); return;
    }
  }

  try {
    toast(t('activity.uploading'),'');
    const fileName = `evidence_${currentUser.id}_${Date.now()}.jpg`;
    const imgUrl = await uploadImage(_receiptImgData, fileName, 'receipts');
    const id = await insertDraftDeliverable({
      application_id: _activityAppId,
      user_id: currentUser.id,
      campaign_id: _activityCampId,
      kind: 'receipt',
      receipt_url: imgUrl,
      // monitor 전용 3종 — visit 캠페인이면 모두 null
      order_number: orderNumber,
      purchase_date: purchaseDate || null,
      purchase_amount: purchaseAmount
    });
    if (!id) { toast(t('activity.saveFail'), 'error'); return; }
    _receiptImgData = null;
    _receiptOcrFile = null;
    $('receiptPreview').innerHTML = '';
    $('receiptFile').value = '';
    const ocrSt2 = $('receiptOcrStatus'); if (ocrSt2) { ocrSt2.style.display = 'none'; ocrSt2.textContent = ''; }
    // monitor 전용 필드 비움
    if (isMonitor) {
      const ron = $('receiptOrderNumber'); if (ron) ron.value = '';
      const rd = $('receiptDate'); if (rd) rd.value = '';
      const ra = $('receiptAmount'); if (ra) ra.value = '';
    }
    toast(t('activity.draftAddedNeedSubmit'), 'success');
    await loadDeliverablesForActivity();
  } catch(e) { toast(friendlyErrorJa(e), 'error'); }
}

// monitor 2단계 — 채널별 리뷰 캡쳐 draft 추가. payload에 post_channel 채워 신청+채널 유니크 인덱스(마이그레이션 158)와 정합.
// 채널마다 따로 눌러야 하므로 잠금 키에 채널을 붙인다(한 채널 제출 중에 다른 채널은 눌러야 함).
//   버튼은 카드마다 동적 생성이라 호출부가 자기 요소(this)를 넘긴다.
async function addDraftReviewImage(channel, btnEl) {
  return withSubmitLock('draftReviewImage:' + (channel || ''), btnEl || null, t('common.uploading'),
    function() { return _addDraftReviewImageInner(channel); });
}

async function _addDraftReviewImageInner(channel) {
  if (!channel) { toast(t('activity.needReviewImage'),'error'); return; }
  const imgData = _reviewImgDataByChannel[channel];
  if (!imgData) { toast(t('activity.needReviewImage'),'error'); return; }
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const camp = _activityCamp || {};
  // 제출 가부는 서버 판정만 본다(사양서 §설계 3-(1)) — 채널 단위
  if (!gateAllows('review_image', channel)) { toast(t('activity.afterDeadline'),'error'); return; }
  try {
    toast(t('activity.uploading'),'');
    const fileName = `review_${channel}_${currentUser.id}_${Date.now()}.jpg`;
    const imgUrl = await uploadImage(imgData, fileName, 'receipts');
    const id = await insertDraftDeliverable({
      application_id: _activityAppId,
      user_id: currentUser.id,
      campaign_id: _activityCampId,
      kind: 'review_image',
      post_channel: channel,
      receipt_url: imgUrl
    });
    if (!id) { toast(t('activity.saveFail'), 'error'); return; }
    _reviewImgDataByChannel[channel] = null;
    toast(t('activity.draftAddedNeedSubmit'), 'success');
    await loadDeliverablesForActivity();
  } catch(e) { toast(friendlyErrorJa(e), 'error'); }
}

// Draft 삭제
async function deleteDraft(id) {
  const ok = await deleteDraftDeliverable(id);
  if (ok) {
    toast(t('activity.draftDeleted'), 'success');
    await loadDeliverablesForActivity();
  } else toast(t('activity.saveFail'), 'error');
}

// Draft → 제출 (kind 별로 일괄)
// 종류별로 버튼이 따로 있으므로 잠금 키·버튼도 종류별.
async function submitAllDrafts(kind) {
  const BTN = {receipt: 'submitImagesBtn', review_image: 'submitReviewImageBtn', post: 'submitPostsBtn'};
  return withSubmitLock('submitDrafts:' + kind, BTN[kind] || null, t('common.submitting'),
    function() { return _submitAllDraftsInner(kind); });
}

async function _submitAllDraftsInner(kind) {
  let count = 0, failed = 0, failedChannels = [];
  try {
    const r = await submitDrafts(_activityAppId, kind);
    count = r.count; failed = r.failed; failedChannels = r.failedChannels || [];
  } catch (e) {
    // 서버가 거부한 경우(제출 마감 등) 정확한 사유를 보여준다. 예전에는 storage 쪽에서 에러를
    // 삼켜 count=0 이 되고 아래 「제출할 것이 없습니다」가 떠서, 왜 안 되는지 알 수 없었다.
    toast(friendlyErrorJa(e), 'error');
    // 마감으로 막힌 경우 폼 상태를 실제 서버 기준으로 다시 그려 반복 시도를 끊는다
    if (/submission_deadline_passed/.test(String(e?.message || ''))) {
      try { await loadDeliverablesForActivity(); } catch(_) {}
    }
    return;
  }
  if (count > 0) {
    // 일부만 올라간 경우(채널마다 자격이 다를 때) 그 사실을 알려야 「전부 됐다」고 오해하지 않는다.
    //   ⚠️ 채널을 알 수 있으면 **이름으로** 말해 준다 — 「제출하지 못한 항목이 있습니다」만으로는
    //      무엇을 다시 손봐야 하는지 알 수 없다. 영수증은 채널이 없어 늘 옛 문구로 떨어진다.
    let msg;
    if (failed > 0 && failedChannels.length) {
      // 구분자는 말에 맞춘다 — 일본어는 「、」, 한국어는 쉼표. 한쪽 기호를 두 언어에 쓰면
      //   어느 한쪽에서 남의 나라 문장부호가 된다.
      const sep = (typeof getLang === 'function' && getLang() === 'ko') ? ', ' : '、';
      const names = failedChannels.map(c => getChannelLabelLocal(c) || c).join(sep);
      msg = t('activity.submitPartialFailed').replace('{channels}', names);
    } else if (failed > 0) {
      msg = t('activity.submittedPartial').replace('{n}', count);
    } else {
      msg = t('activity.submittedN').replace('{n}', count);
    }
    toast(msg, failed > 0 ? 'warn' : 'success');
    await loadDeliverablesForActivity();
  } else toast(t('activity.nothingToSubmit'), 'warn');
}

