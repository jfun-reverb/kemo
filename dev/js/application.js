// ══════════════════════════════════════
// CAMPAIGN DETAIL + APPLICATION
// ══════════════════════════════════════

async function openCampaign(id) {
  const camp = allCampaigns.find(c=>c.id===id) || DEMO_CAMPAIGNS.find(c=>c.id===id);
  if (!camp) return;
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
        <button onclick="slideMove(-1)" style="position:absolute;left:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round" style="font-size:20px;color:#333">chevron_left</span></button>
        <button onclick="slideMove(1)" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round" style="font-size:20px;color:#333">chevron_right</span></button>
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
          <div style="font-size:11px;color:var(--pink);font-weight:700;letter-spacing:.06em;margin-bottom:5px">${esc(camp.brand)}</div>
          ${camp.recruit_type ? `<div style="font-size:10px;font-weight:700;color:var(--pink);margin-bottom:4px">${esc(getRecruitTypeLabelJa(camp.recruit_type))}</div>` : ''}
          <div style="font-size:18px;font-weight:800;color:var(--ink);line-height:1.3;margin-bottom:10px">${esc(camp.title)}</div>
          ${camp.product_price>0?`<div style="display:inline-flex;align-items:center;gap:6px;background:var(--light-pink);border-radius:8px;padding:6px 12px;margin-bottom:4px"><span style="font-size:17px;font-weight:900;color:var(--pink)">¥${camp.product_price.toLocaleString()}</span><span style="font-size:12px;color:var(--dark-pink);font-weight:600">${camp.recruit_type === 'monitor' ? t('detail.rewardPayback') : t('detail.rewardProduct')}</span></div>`:''}
          ${camp.reward>0?`<div style="font-size:12px;color:var(--green);font-weight:600;margin-top:4px">${t('detail.rewardCash').replace('{amount}',camp.reward.toLocaleString())}</div>`:''}
        </div>
        ${(()=>{
          // 캠페인 상세 표 — 시간 흐름 순으로 행 배치
          // 순서: 상품명 → 모집타입 → 채널 → 콘텐츠 → 모집기간 → 구매/방문기간 → 결과물 제출 마감 → 모집인원
          //       → (monitor 외) 당선 발표 → (monitor 외) 리워드
          const isMonitor = camp.recruit_type === 'monitor';
          const KEY = 'width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0';
          const VAL = 'padding:10px 13px;flex:1;font-size:12px';
          const ROW = 'display:flex;border-top:1px solid #faf5f9';
          const rows = [];
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.productName')}</div><div style="${VAL}">${esc(camp.product)||'—'}</div></div>`);
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.recruitType')}</div><div style="${VAL}">${(()=>{const t=camp.recruit_type;const map={monitor:['var(--blue-l)','var(--blue)','レビュアー'],gifting:['var(--gold-l)','var(--gold)','ギフティング'],visit:['#E8F7EF','#0E7E4A','訪問']};const m=map[t];return m?`<span style="background:${m[0]};color:${m[1]};font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px">${m[2]}</span>`:'—'})()}</div></div>`);
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.channel')}</div><div style="${VAL};display:flex;gap:6px;flex-wrap:wrap;align-items:center">${(()=>{const sep = camp.channel_match === 'and' ? '&' : 'or'; return (camp.channel||'').split(',').map(s=>s.trim()).filter(Boolean).map(code=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:11px;font-weight:600;padding:2px 10px;border-radius:20px">${esc(getChannelLabel(code))}</span>`).join(`<span style="color:var(--muted);font-size:11px;font-weight:600">${sep}</span>`);})()}</div></div>`);
          if (camp.content_types) {
            const ctList = camp.content_types.split(',').map(c => c.trim()).filter(Boolean);
            if (ctList.length) {
              rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.contentType')}</div><div style="${VAL};display:flex;gap:4px;flex-wrap:wrap">${ctList.map(c=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:10px;font-weight:600;padding:2px 8px;border-radius:20px">${esc(getLookupLabel('content_type', c))}</span>`).join('')}</div></div>`);
            }
          }
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.recruitPeriod')}</div><div style="${VAL}">${formatDate(camp.recruit_start || new Date())} 〜 ${formatDate(camp.deadline)}</div></div>`);
          if (isMonitor && (camp.purchase_start || camp.purchase_end)) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.purchasePeriod')}</div><div style="${VAL}">${camp.purchase_start?formatDate(camp.purchase_start):'—'} 〜 ${camp.purchase_end?formatDate(camp.purchase_end):'—'}</div></div>`);
          }
          if (camp.recruit_type === 'visit' && (camp.visit_start || camp.visit_end)) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.visitPeriod')}</div><div style="${VAL}">${camp.visit_start?formatDate(camp.visit_start):'—'} 〜 ${camp.visit_end?formatDate(camp.visit_end):'—'}</div></div>`);
          }
          if (camp.submission_end) {
            rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.submissionEnd')}</div><div style="${VAL};font-weight:600;color:var(--ink)">${formatDate(camp.submission_end)}</div></div>`);
          }
          rows.push(`<div style="${ROW}"><div style="${KEY}">${t('detail.recruitSlots')}</div><div style="${VAL}">${camp.slots}${t('detail.peopleUnit')}</div></div>`);
          // 리뷰어(monitor) 캠페인은 당선 발표·리워드 행 제외
          if (!isMonitor) {
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
        ${camp.appeal ? `<div style="margin-bottom:12px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.brandAppeal')}</div><div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:#fff5ff;padding:10px 12px;border-radius:8px;border:1px solid #f0d8e8">${richHtml(camp.appeal)}</div></div>` : ''}
        ${camp.hashtags ? `<div style="margin-bottom:10px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.requiredHashtag')}</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.hashtags.split(',').map(t=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(t.trim())}</span>`).join('')}</div></div>` : ''}
        ${camp.mentions ? `<div><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">${t('detail.requiredMention')}</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.mentions.split(',').map(t=>`<span style="background:#f0f0ff;color:#4040cc;font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(t.trim())}</span>`).join('')}</div></div>` : ''}
      </div>` : ''}

      ${camp.guide ? `
      <div style="background:#fff;padding:16px 0;margin-bottom:10px;border-bottom:1px dashed var(--line)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">${t('detail.shootingGuide')}</div>
        <div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:#fdf5fd;padding:12px;border-radius:8px;border:1px solid #e8d4e8">${richHtml(camp.guide)}</div>
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
    floatReward.textContent = camp.product_price>0
      ? `¥${camp.product_price.toLocaleString()}${isMonitor ? t('detail.rewardPayback') : t('detail.rewardProduct')}`
      : t('detail.rewardFree');
  }
  if (floatProductPageBtn) {
    floatProductPageBtn.style.display = camp.product_url ? 'inline-flex' : 'none';
    floatProductPageBtn.dataset.url = cleanUrl(camp.product_url)||'';
  }
  if (floatApplyBtn) {
    if (_myApp?.status === 'approved') {
      floatApplyBtn.textContent=t('detail.manageBtn'); floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm';
      floatApplyBtn.onclick = () => openActivityPage(_myApp.id, id, 'detail');
    } else if (alreadyApplied) { floatApplyBtn.textContent=t('detail.appliedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (camp.status==='closed') { floatApplyBtn.textContent=t('detail.closedBtn'); floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
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
    if (hasCancelledHistory && !alreadyApplied && _myApp?.status !== 'approved' && camp.status !== 'closed' && !isFull) {
      if (!reapplyNotice) {
        reapplyNotice = document.createElement('div');
        reapplyNotice.id = reapplyNoticeId;
        reapplyNotice.style.cssText = 'background:#F5F5F5;border-radius:8px;padding:8px 12px;font-size:12px;color:var(--muted);margin-bottom:8px;text-align:center';
        floatApplyBtn.parentNode?.insertBefore(reapplyNotice, floatApplyBtn);
      }
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

async function submitApplication() {
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  // 배송지 이름 누락 차단 — 한자명·가나명 둘 다 필수.
  // 관리자 화면에서 신청자 이름이 「-」로 표시되던 케이스 방지 (마이페이지에서 등록 후 재시도)
  const nameKanji = (currentUserProfile?.name_kanji || currentUserProfile?.name || '').trim();
  const nameKana = (currentUserProfile?.name_kana || '').trim();
  if (!nameKanji || nameKanji === '-' || !nameKana || nameKana === '-') {
    toast(t('apply.needName'),'error');
    return;
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

  const app = {
    id: 'app-'+Date.now(),
    user_id: currentUser.id,
    user_email: currentUser.email,
    user_name: currentUserProfile?.name || currentUser.email,
    user_followers: currentUserProfile?.followers || 0,
    campaign_id: currentCampaignId,
    message: msg,
    address: addr,
    status: 'pending',
    created_at: new Date().toISOString()
  };

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
      toast(t('apply.sessionExpired'),'error');
      closeModal('applyModal');
      currentUser = null; currentUserProfile = null;
      updateGnb();
      return;
    }
    toast(friendlyErrorJa(e), 'error'); closeModal('applyModal'); return;
  }

  closeModal('applyModal');
  toast(t('detail.applyComplete'),'success');
  openCampaign(currentCampaignId);
}

// ── FLOAT BAR + LOGIN PROMPT ──
function handleFloatApply() {
  if (!currentUser) {
    const o = $('loginPromptOverlay');
    if (o) { o.style.display='flex'; }
    return;
  }
  // 이메일 미인증 체크
  if (!currentUser.email_confirmed_at) {
    toast(t('apply.emailUnverified'),'error');
    return;
  }
  // 필수 정보 체크: 이름(한자·가나) + 캠페인 채널에 맞는 SNS 계정 + 배송지
  const p = currentUserProfile || {};
  const camp = allCampaigns.find(c => c.id === currentCampaignId) || {};
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
        <span class="material-icons-round" style="font-size:18px;color:var(--pink)">warning</span>${esc(m)}
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
    const primary = (camp.primary_channel || (ch||'').split(',')[0] || 'instagram').trim();
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

// ══════════════════════════════════════
// ACTIVITY PAGE — 활동 관리
// ══════════════════════════════════════
let _activityAppId = null;
let _activityCampId = null;
let _activityCamp = null;
let _activityFrom = 'detail'; // 'detail' or 'mypage'
// 마지막 loadDeliverablesForActivity() 결과 — draft 추가 함수의 마감 후 가드 판정에 사용
let _activityLastDelivs = [];
let _receiptImgData = null;
let _reviewImgData = null;  // monitor 2단계 — 리뷰 게시물 캡쳐 (이미지 base64)

async function openActivityPage(applicationId, campaignId, from) {
  _activityAppId = applicationId;
  _activityCampId = campaignId;
  _activityFrom = from || 'detail';
  const camp = allCampaigns.find(c=>c.id===campaignId) || {};
  _activityCamp = camp;
  // 사양 §4-8: cancelled 신청은 활동관리 진입 자체 차단.
  // 회색 안내 화면만 보여주고 폼은 DOM 비공개. 헤더 알림에서 과거 이력으로
  // 진입한 경우에도 동일 분기.
  const isCancelled = (typeof isApplicationCancelled === 'function') && isApplicationCancelled(applicationId);
  if (typeof navigate === 'function') navigate('activity');
  if (isCancelled) {
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
          <button class="btn btn-primary" onclick="navigate('mypage');openMypageSub('applications')" data-i18n="appHistory.cancelBlocked.backBtn">応募履歴に戻る</button>`;
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
  $('activityCampBrand').textContent = camp.brand || '';
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
    } catch(_e) { canCancel = false; }
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
  $('activityReceiptSection').style.display = showImage ? '' : 'none';
  $('activityPostSection').style.display = showPost ? '' : 'none';
  // monitor 캠페인은 STEP 1 라벨 + STEP 2(리뷰 캡쳐) 섹션 노출, 그 외는 모두 숨김
  const stepLabel = $('receiptStepLabel');
  if (stepLabel) stepLabel.style.display = isMonitor ? '' : 'none';
  const reviewSec = $('reviewImageSection');
  if (reviewSec) reviewSec.style.display = isMonitor ? '' : 'none';
  // monitor 전용 영수증 필수 필드(주문번호·구매일·구매금액) — 마이그레이션 128
  const monitorFields = $('monitorReceiptFields');
  if (monitorFields) monitorFields.style.display = isMonitor ? '' : 'none';
  const isPostType = showPost;  // 아래 마감 검사 로직용

  // 제출 마감일 안내 기본값 (마감 전 케이스만 여기서 처리)
  // 마감 후 비활성/반려후 활성 분기는 loadDeliverablesForActivity 가 끝난 뒤
  // applyFormGating() 이 덮어쓴다 — 반려된 결과물 데이터를 알아야 결정 가능하므로.
  const submissionEnd = camp.submission_end || camp.post_deadline || null;
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
    // monitor 전용 3종 필드 — 폼 진입 시 비움 (마이그레이션 128)
    const ron = $('receiptOrderNumber'); if (ron) ron.value = '';
    const rd = $('receiptDate'); if (rd) rd.value = '';
    const ra = $('receiptAmount'); if (ra) ra.value = '';
  }
  if (isMonitor) {
    const rp2 = $('reviewImagePreview'); if (rp2) rp2.innerHTML = '';
    const rf2 = $('reviewImageFile'); if (rf2) rf2.value = '';
    _reviewImgData = null;
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
    return null;
  } catch(e) { return null; }
}

const CHANNEL_LABELS = {
  instagram: 'Instagram', tiktok: 'TikTok', youtube: 'YouTube',
  x: 'X (Twitter)', qoo10: 'Qoo10'
};
function getChannelLabelLocal(code) {
  return CHANNEL_LABELS[code] || t('channelLabel.other');
}

function onPostUrlInputChange() {
  const url = $('postUrlInput')?.value || '';
  const detectedLbl = $('postChannelDetected');
  const manualWrap = $('postChannelManualWrap');
  if (!url.trim()) {
    if (detectedLbl) detectedLbl.textContent = '';
    if (manualWrap) manualWrap.style.display = 'none';
    return;
  }
  const ch = detectChannelFromUrl(url);
  if (ch) {
    if (detectedLbl) detectedLbl.textContent = t('activity.postChannelDetected').replace('{channel}', CHANNEL_LABELS[ch]);
    if (detectedLbl) detectedLbl.style.color = 'var(--dark-pink)';
    if (manualWrap) manualWrap.style.display = 'none';
  } else {
    if (detectedLbl) detectedLbl.textContent = t('activity.postChannelDetectFail');
    if (detectedLbl) detectedLbl.style.color = '#C33';
    if (manualWrap) manualWrap.style.display = '';
  }
}

function navigateBackFromActivity() {
  if (_activityFrom === 'mypage') {
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
  if (showPost) renderActivityPostList(all.filter(d => d.kind === 'post'));

  // monitor 2단계: 영수증 1건 이상 approved 시 STEP 2(리뷰 캡쳐) 영역 활성화
  if (isMonitor) {
    const receiptApproved = all.some(d => d.kind === 'receipt' && d.status === 'approved');
    const gatedNote = $('reviewImageGatedNote');
    const body = $('reviewImageBody');
    if (gatedNote) gatedNote.style.display = receiptApproved ? 'none' : '';
    if (body) body.style.display = receiptApproved ? '' : 'none';
    if (receiptApproved) {
      renderActivityReviewImageList(all.filter(d => d.kind === 'review_image'));
    }
  }

  // 마감 안내 + 폼 활성/비활성 결정 (데이터 로드 후 한 번에 처리)
  // 반려된 결과물(kind 별 최신 1건이 rejected)이 있으면 마감 후에도 재제출 허용 — 관리자 책임 정책
  applyFormGating(all);
}

// kind 별 최신 1건이 rejected 상태인지 판정 (활동관리 1장 제약·재제출 정책의 공통 기준)
//   draft 행은 제외(아직 제출 전이라 「반려당했다」 판정에 부적합)
function _latestNonDraftIsRejected(allDelivs, kind) {
  if (!Array.isArray(allDelivs)) return false;
  const candidates = allDelivs
    .filter(d => d.kind === kind && d.status !== 'draft')
    .sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
  return !!(candidates[0] && candidates[0].status === 'rejected');
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
  const submissionEnd = camp.submission_end || camp.post_deadline || null;
  const isAfterDeadline = submissionEnd ? (new Date(submissionEnd + 'T23:59:59') < new Date()) : false;

  // kind 별 「최신 1건 rejected」 판정 (마감 후에도 폼 활성 허용 조건)
  const receiptRejected = _latestNonDraftIsRejected(allDelivs, 'receipt');
  const reviewRejected = _latestNonDraftIsRejected(allDelivs, 'review_image');
  const postRejected = _latestNonDraftIsRejected(allDelivs, 'post');
  const anyRejected = receiptRejected || reviewRejected || postRejected;

  // 마감 안내문 (전체 상단에 하나만)
  const deadlineBox = $('activitySubmissionDeadline');
  if (deadlineBox && submissionEnd) {
    deadlineBox.style.display = '';
    if (!isAfterDeadline) {
      deadlineBox.textContent = `${t('activity.submissionEndLabel')}: ${formatDate(submissionEnd)}`;
      deadlineBox.style.color = 'var(--muted)';
    } else if (anyRejected) {
      deadlineBox.textContent = `${t('activity.submissionEndPastButRejected')} (${formatDate(submissionEnd)})`;
      deadlineBox.style.color = '#B8741A';
    } else {
      deadlineBox.textContent = `${t('activity.submissionEndPast')} (${formatDate(submissionEnd)})`;
      deadlineBox.style.color = '#C33';
    }
  }

  // kind 별 폼 비활성 결정 — 마감 후이고 해당 kind 에 반려 이력이 없으면 비활성
  const receiptDisabled = isAfterDeadline && !receiptRejected;
  const reviewDisabled  = isAfterDeadline && !reviewRejected;
  const postDisabled    = isAfterDeadline && !postRejected;

  if (showImage) {
    _setFormDisabled({
      labelId: 'receiptFileLabel',
      inputIds: ['receiptFile', 'receiptOrderNumber', 'receiptDate', 'receiptAmount'],
      buttonIds: ['addReceiptBtn', 'submitImagesBtn']
    }, receiptDisabled);
  }
  if (isMonitor) {
    _setFormDisabled({
      labelId: 'reviewImageFileLabel',
      inputIds: ['reviewImageFile'],
      buttonIds: ['addReviewImageBtn', 'submitReviewImageBtn']
    }, reviewDisabled);
  }
  if (showPost) {
    _setFormDisabled({
      labelId: null,
      inputIds: ['postUrlInput', 'postChannelManual'],
      buttonIds: ['addPostBtn', 'submitPostsBtn']
    }, postDisabled);
  }
}

// 한 폼의 label / input / button 묶음을 disabled 토글
//   label: <label> 회색 처리 + 클릭 차단 (file input 트리거 막기)
//   input/button: disabled 속성 직접 설정
function _setFormDisabled(targets, disabled) {
  if (targets.labelId) {
    const lab = $(targets.labelId);
    if (lab) {
      if (disabled) {
        lab.style.background = '#cccccc';
        lab.style.cursor = 'not-allowed';
        lab.style.pointerEvents = 'none';
        lab.style.opacity = '0.6';
      } else {
        lab.style.background = '';
        lab.style.cursor = '';
        lab.style.pointerEvents = '';
        lab.style.opacity = '';
      }
    }
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
    return;
  }
  let hasDraft = false;
  container.innerHTML = delivs.map(r => {
    const isDraft = r.status === 'draft';
    if (isDraft) hasDraft = true;
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
      ${reasonBox}
    </div>`;
  }).join('');
  if (submitBtn) submitBtn.style.display = hasDraft ? '' : 'none';
}

// monitor 2단계 — 리뷰 캡쳐 결과물 리스트 렌더 + 1장 제약(클라이언트 차단)
function renderActivityReviewImageList(delivs) {
  const container = $('reviewImageList');
  if (!container) return;
  const submitBtn = $('submitReviewImageBtn');
  const addBtn = $('addReviewImageBtn');
  const maxNote = $('reviewImageMaxNote');
  const formBox = $('reviewImageForm');
  // 1장 제약: 어떤 상태든(draft/pending/approved) 1건이라도 있으면 추가 불가
  //   active 판정은 kind별 가장 최신 1건 기준 — 같은 application에 옛 pending 누적되어도
  //   가장 최신이 rejected면 재제출 form 노출 (renderActivityList 와 동일 패턴)
  const latestPerKind = {};
  (delivs || []).forEach(function(d) {
    var prev = latestPerKind[d.kind];
    if (!prev || new Date(d.created_at) > new Date(prev.created_at)) latestPerKind[d.kind] = d;
  });
  const activeCount = Object.values(latestPerKind).filter(function(d) { return d.status !== 'rejected'; }).length;
  const reachedMax = activeCount >= 1;
  if (formBox) formBox.style.display = reachedMax ? 'none' : '';
  if (addBtn) addBtn.style.display = reachedMax ? 'none' : '';
  if (maxNote) maxNote.style.display = reachedMax ? '' : 'none';

  if (!delivs || !delivs.length) {
    container.innerHTML = `<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">${t('activity.noReviewImage')}</div>`;
    if (submitBtn) submitBtn.style.display = 'none';
    return;
  }
  let hasDraft = false;
  container.innerHTML = delivs.map(r => {
    const isDraft = r.status === 'draft';
    if (isDraft) hasDraft = true;
    const stBadge = isDraft
      ? `<span style="background:#e5e7eb;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('activity.draftBadge')}</span>`
      : activityStatusBadge(r.status);
    const rightCol = isDraft
      ? `<button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="deleteDraft('${esc(r.id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete</span></button>`
      : `<div style="font-size:10px;color:var(--muted)">${formatDate(r.submitted_at || r.created_at)}</div>`;
    const reasonBox = (r.status === 'rejected' && r.reject_reason)
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FFF5F5;border-left:3px solid #C33;border-radius:6px;font-size:11px;color:#C33;white-space:pre-wrap;line-height:1.5">${esc(r.reject_reason)}</div>`
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
      ${reasonBox}
    </div>`;
  }).join('');
  if (submitBtn) submitBtn.style.display = hasDraft ? '' : 'none';
}

function renderActivityPostList(delivs) {
  const container = $('postSubmissionList');
  if (!container) return;
  const submitBtn = $('submitPostsBtn');
  if (!delivs.length) {
    container.innerHTML = `<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">${t('activity.noPost')}</div>`;
    if (submitBtn) submitBtn.style.display = 'none';
    return;
  }
  let hasDraft = false;
  container.innerHTML = delivs.map(d => {
    const isDraft = d.status === 'draft';
    if (isDraft) hasDraft = true;
    const stBadge = isDraft
      ? `<span style="background:#e5e7eb;color:#555;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('activity.draftBadge')}</span>`
      : activityStatusBadge(d.status);
    const chLabel = CHANNEL_LABELS[d.post_channel] || d.post_channel || '—';
    const actionBtn = isDraft
      ? `<button class="btn btn-ghost btn-xs" style="color:var(--red);border-color:var(--red)" onclick="deleteDraft('${esc(d.id)}')"><span class="material-icons-round notranslate" translate="no" style="font-size:14px">delete</span></button>`
      : '';
    const reasonBox = (d.status === 'rejected' && d.reject_reason)
      ? `<div style="margin-top:8px;padding:8px 10px;background:#FFF5F5;border-left:3px solid #C33;border-radius:6px;font-size:11px;color:#C33;white-space:pre-wrap;line-height:1.5">${esc(d.reject_reason)}</div>`
      : '';
    return `
    <div style="padding:12px;background:var(--surface);border:1px solid var(--outline);border-radius:12px;margin-bottom:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px">
        <div style="font-size:12px;font-weight:600;color:var(--ink)">${esc(chLabel)}</div>
        <div style="display:flex;align-items:center;gap:6px">${stBadge}${actionBtn}</div>
      </div>
      <a href="${esc(d.post_url||'')}" target="_blank" rel="noopener" style="font-size:12px;color:var(--dark-pink);word-break:break-all;text-decoration:none">${esc(d.post_url||'')}</a>
      <div style="font-size:10px;color:var(--muted);margin-top:4px">${formatDate(d.submitted_at)}</div>
      ${reasonBox}
    </div>`;
  }).join('');
  if (submitBtn) submitBtn.style.display = hasDraft ? '' : 'none';
}

function activityStatusBadge(status) {
  if (status === 'approved') return `<span style="background:#E4F5E8;color:#2D7A3E;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.approved')}</span>`;
  if (status === 'rejected') return `<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.rejected')}</span>`;
  return `<span style="background:#FFF4E4;color:#B8741A;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">${t('delivStatus.pending')}</span>`;
}

function previewReceipt(input) {
  const file = input.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = e => {
    _receiptImgData = e.target.result;
    $('receiptPreview').innerHTML = `<img src="${_receiptImgData}" style="max-width:100%;max-height:200px;border-radius:10px;margin-bottom:8px">`;
  };
  reader.readAsDataURL(file);
}

// monitor 2단계 — 리뷰 게시물 캡쳐 미리보기
function previewReviewImage(input) {
  const file = input.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = e => {
    _reviewImgData = e.target.result;
    const prev = $('reviewImagePreview');
    if (prev) prev.innerHTML = `<img src="${_reviewImgData}" style="max-width:100%;max-height:200px;border-radius:10px;margin-bottom:8px">`;
  };
  reader.readAsDataURL(file);
}

// Draft URL 추가 (gifting/visit — SNS 게시 URL 제출)
async function addDraftUrl() {
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const url = ($('postUrlInput')?.value || '').trim();
  if (!url) { toast(t('activity.needUrl'), 'error'); return; }
  try { new URL(url); } catch(e) { toast(t('activity.badUrlFormat'),'error'); return; }

  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  // 마감 후라도 해당 kind 에 반려 이력이 있으면 재제출 허용 (관리자 책임 정책)
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()
      && !_latestNonDraftIsRejected(_activityLastDelivs, 'post')) {
    toast(t('activity.afterDeadline'),'error'); return;
  }

  let channel = detectChannelFromUrl(url);
  if (!channel) {
    channel = $('postChannelManual')?.value || '';
    if (!channel) { toast(t('activity.needChannel'), 'error'); return; }
  }

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
    toast(t('activity.draftAdded'), 'success');
    await loadDeliverablesForActivity();
  } catch(e) { toast(friendlyErrorJa(e), 'error'); }
}

// Draft 이미지 추가 (monitor/visit — 영수증·현장 사진 제출)
async function addDraftImage() {
  if (!_receiptImgData) { toast(t('activity.needImage'),'error'); return; }
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  // 마감 후라도 receipt 에 반려 이력이 있으면 재제출 허용 (관리자 책임 정책)
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()
      && !_latestNonDraftIsRejected(_activityLastDelivs, 'receipt')) {
    toast(t('activity.afterDeadline'),'error'); return;
  }

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
    $('receiptPreview').innerHTML = '';
    $('receiptFile').value = '';
    // monitor 전용 필드 비움
    if (isMonitor) {
      const ron = $('receiptOrderNumber'); if (ron) ron.value = '';
      const rd = $('receiptDate'); if (rd) rd.value = '';
      const ra = $('receiptAmount'); if (ra) ra.value = '';
    }
    toast(t('activity.draftAdded'), 'success');
    await loadDeliverablesForActivity();
  } catch(e) { toast(friendlyErrorJa(e), 'error'); }
}

// monitor 2단계 — 리뷰 게시물 캡쳐 draft 추가 (1장 제약은 UI에서 form 자체를 숨김)
async function addDraftReviewImage() {
  if (!_reviewImgData) { toast(t('activity.needReviewImage'),'error'); return; }
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }
  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  // 마감 후라도 review_image 에 반려 이력이 있으면 재제출 허용 (관리자 책임 정책)
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()
      && !_latestNonDraftIsRejected(_activityLastDelivs, 'review_image')) {
    toast(t('activity.afterDeadline'),'error'); return;
  }
  try {
    toast(t('activity.uploading'),'');
    const fileName = `review_${currentUser.id}_${Date.now()}.jpg`;
    const imgUrl = await uploadImage(_reviewImgData, fileName, 'receipts');
    const id = await insertDraftDeliverable({
      application_id: _activityAppId,
      user_id: currentUser.id,
      campaign_id: _activityCampId,
      kind: 'review_image',
      receipt_url: imgUrl
    });
    if (!id) { toast(t('activity.saveFail'), 'error'); return; }
    _reviewImgData = null;
    const prev = $('reviewImagePreview'); if (prev) prev.innerHTML = '';
    const fileEl = $('reviewImageFile'); if (fileEl) fileEl.value = '';
    toast(t('activity.draftAdded'), 'success');
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
async function submitAllDrafts(kind) {
  const count = await submitDrafts(_activityAppId, kind);
  if (count > 0) {
    toast(t('activity.submittedN').replace('{n}', count), 'success');
    await loadDeliverablesForActivity();
  } else toast(t('activity.nothingToSubmit'), 'warn');
}

// [DEAD CODE 2026-05-15] 활동관리 현행 흐름은 addDraftImage → submitDrafts 로 일원화됨.
//   receipts 테이블 직접 INSERT 경로(submitReceipt) 는 더 이상 호출되지 않음. CLAUDE.md 명시.
//   별도 정리 PR 에서 제거 예정. 본 함수의 마감 가드 정책은 의도적으로 동결.
async function submitReceipt() {
  if (!_receiptImgData) { toast(t('activity.needImage'),'error'); return; }
  if (!currentUser) { toast(t('apply.needLogin'),'error'); return; }

  // 제출 마감 확인 (Stage 3)
  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()) {
    toast(t('activity.afterDeadline'),'error');
    return;
  }

  try {
    toast(t('activity.uploading'),'');
    const fileName = `receipt_${currentUser.id}_${Date.now()}.jpg`;
    const receiptUrl = await uploadImage(_receiptImgData, fileName, 'receipts');

    await insertReceipt({
      application_id: _activityAppId,
      user_id: currentUser.id,
      campaign_id: _activityCampId,
      receipt_url: receiptUrl,
      purchase_date: $('receiptDate').value || null,
      purchase_amount: parseInt($('receiptAmount').value) || 0
    });

    toast(t('activity.receiptSuccess'),'success');
    _receiptImgData = null;
    $('receiptPreview').innerHTML = '';
    $('receiptFile').value = '';
    $('receiptDate').value = '';
    $('receiptAmount').value = '';
    await loadReceipts();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}
