// ══════════════════════════════════════
// CAMPAIGN DETAIL + APPLICATION
// ══════════════════════════════════════

async function openCampaign(id) {
  const camp = allCampaigns.find(c=>c.id===id) || DEMO_CAMPAIGNS.find(c=>c.id===id);
  if (!camp) return;
  currentCampaignId = id;

  let alreadyApplied = false;
  if (currentUser) {
    alreadyApplied = await checkDuplicateApplication(currentUser.id, id);
  }

  const isFull = (camp.applied_count||0) >= camp.slots;
  _slideIdx = 0;

  // 슬라이드 이미지
  const slideImgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url]
    .filter(Boolean).filter((v,i,a)=>a.indexOf(v)===i);

  const slideHtml = slideImgs.length > 0 ? `
    <div id="campSlider" style="position:relative;overflow:hidden;border-radius:16px;margin-bottom:0;background:${getCampGrad(camp.category)};aspect-ratio:1/1;height:auto">
      <div id="campSlides" style="display:flex;height:100%;transition:transform .32s cubic-bezier(.4,0,.2,1)">
        ${slideImgs.map(url=>`<div style="min-width:100%;height:100%;flex-shrink:0"><img src="${url}" style="width:100%;height:100%;object-fit:cover;display:block" onerror="this.parentElement.style.background='${getCampGrad(camp.category)}'"></div>`).join('')}
      </div>
      ${slideImgs.length>1?`
        <button onclick="slideMove(-1)" style="position:absolute;left:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)">‹</button>
        <button onclick="slideMove(1)" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)">›</button>
        <div style="position:absolute;bottom:10px;left:50%;transform:translateX(-50%);display:flex;gap:5px;z-index:5">
          ${slideImgs.map((_,i)=>`<div onclick="slideTo(${i})" id="dot${i}" style="width:${i===0?'16px':'6px'};height:6px;border-radius:3px;background:${i===0?'#fff':'rgba(255,255,255,.5)'};cursor:pointer;transition:.2s"></div>`).join('')}
        </div>
        <div style="position:absolute;top:12px;right:12px;background:rgba(0,0,0,.45);color:#fff;font-size:11px;font-weight:600;padding:3px 8px;border-radius:20px;z-index:5"><span id="slideCurrentNum">1</span>/${slideImgs.length}</div>` : ''}
      <div style="position:absolute;top:12px;left:12px;display:flex;gap:5px;z-index:5">
        ${camp.content_types?camp.content_types.split(',').map(t=>`<span style="background:rgba(0,0,0,.55);color:#fff;font-size:10px;font-weight:700;padding:3px 9px;border-radius:20px;backdrop-filter:blur(4px)">${t.trim()}</span>`).join(''):''}
      </div>
    </div>` : `<div style="aspect-ratio:1/1;width:100%;border-radius:16px;background:${getCampGrad(camp.category)};display:flex;align-items:center;justify-content:center;font-size:64px">${camp.emoji||''}</div>`;

  $('detailContent').innerHTML = `
    <div class="detail-main">
      ${slideHtml}

      <div style="background:#fff;border-bottom:1px solid var(--line);margin-bottom:10px">
        <div style="padding:16px 16px 12px">
          <div style="font-size:11px;color:var(--pink);font-weight:700;letter-spacing:.06em;margin-bottom:5px">${camp.brand}</div>
          <div style="font-size:18px;font-weight:800;color:var(--ink);line-height:1.3;margin-bottom:10px">${camp.title}</div>
          ${camp.product_price>0?`<div style="display:inline-flex;align-items:center;gap:6px;background:var(--light-pink);border-radius:8px;padding:6px 12px;margin-bottom:4px"><span style="font-size:17px;font-weight:900;color:var(--pink)">¥${camp.product_price.toLocaleString()}</span><span style="font-size:12px;color:var(--dark-pink);font-weight:600">円相当の製品を無償提供</span></div>`:''}
          ${camp.reward>0?`<div style="font-size:12px;color:var(--green);font-weight:600;margin-top:4px">+ 現金リワード ¥${camp.reward.toLocaleString()}</div>`:''}
        </div>
        <div style="font-size:13px">
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">商品名</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${camp.product||'—'}</div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">募集タイプ</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">
              ${camp.recruit_type==='monitor'?'<span style="background:var(--blue-l);color:var(--blue);font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px">Reviewer</span>':camp.recruit_type==='gifting'?'<span style="background:var(--gold-l);color:var(--gold);font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px">Gifting</span>':'—'}
            </div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">チャンネル</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${getChannelLabel(camp.channel)}</div>
          </div>
          ${camp.content_types?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">コンテンツ</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;display:flex;gap:4px;flex-wrap:wrap">
              ${camp.content_types.split(',').map(t=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:10px;font-weight:600;padding:2px 8px;border-radius:20px">${t.trim()}</span>`).join('')}
            </div>
          </div>`:''}
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">募集期間</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${formatDate(new Date())} 〜 ${formatDate(camp.deadline)}</div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">募集人数</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${camp.slots}名</div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">当選発表</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">選考後、LINEにてご連絡</div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">投稿締切日</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;font-weight:600;color:var(--ink)">${camp.post_deadline ? formatDate(camp.post_deadline) : camp.post_days ? `受取後 ${camp.post_days}日以内` : '—'}</div>
          </div>
          ${(camp.product_price>0||camp.reward>0)?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">リワード</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;color:var(--pink);font-weight:600">
              ${camp.product_price>0?`製品 ¥${camp.product_price.toLocaleString()}円相当`:'製品無償提供'}${camp.reward>0?` + 現金 ¥${camp.reward.toLocaleString()}`:''}
            </div>
          </div>`:''}
        </div>
      </div>

      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:14px;color:var(--ink)">参加方法</div>
        <div style="display:flex;flex-direction:column;gap:14px">
          <div style="display:flex;gap:12px;align-items:flex-start">
            <div style="min-width:50px;height:20px;background:var(--light-pink);border-radius:20px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;color:var(--pink);flex-shrink:0">STEP 1</div>
            <div><div style="font-size:13px;font-weight:700;margin-bottom:2px">応募フォームを提出</div><div style="font-size:12px;color:var(--muted);line-height:1.55">当選された方には当選日にLINEにてご連絡いたします。</div></div>
          </div>
          <div style="display:flex;gap:12px;align-items:flex-start">
            <div style="min-width:50px;height:20px;background:var(--light-pink);border-radius:20px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;color:var(--pink);flex-shrink:0">STEP 2</div>
            <div><div style="font-size:13px;font-weight:700;margin-bottom:2px">製品を使用してSNSにレビューを投稿</div><div style="font-size:12px;color:var(--muted);line-height:1.55">① 投稿ガイドを確認 ② SNSにレビューを投稿</div></div>
          </div>
          <div style="display:flex;gap:12px;align-items:flex-start">
            <div style="min-width:50px;height:20px;background:var(--light-pink);border-radius:20px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;color:var(--pink);flex-shrink:0">STEP 3</div>
            <div><div style="font-size:13px;font-weight:700;margin-bottom:2px">LINEで投稿リンクを送る</div><div style="font-size:12px;color:var(--muted);line-height:1.55">SNSの投稿リンクをコピーして、LINEで送信してください。</div></div>
          </div>
        </div>
      </div>

      ${camp.description ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">キャンペーン説明</div>
        <div style="font-size:13px;color:var(--ink);line-height:1.7;white-space:pre-wrap">${camp.description}</div>
      </div>` : ''}

      ${(camp.hashtags||camp.mentions||camp.appeal) ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:12px;color:var(--ink)">投稿ガイドライン</div>
        ${camp.appeal ? `<div style="margin-bottom:12px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">ブランドアピールポイント</div><div style="font-size:12px;color:var(--ink);line-height:1.7;background:var(--bg);padding:10px 12px;border-radius:8px;white-space:pre-wrap">${camp.appeal}</div></div>` : ''}
        ${camp.hashtags ? `<div style="margin-bottom:10px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">必須ハッシュタグ</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.hashtags.split(',').map(t=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${t.trim()}</span>`).join('')}</div></div>` : ''}
        ${camp.mentions ? `<div><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">必須メンション</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.mentions.split(',').map(t=>`<span style="background:#f0f0ff;color:#4040cc;font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${t.trim()}</span>`).join('')}</div></div>` : ''}
      </div>` : ''}

      ${camp.guide ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">撮影ガイド</div>
        <div style="font-size:12px;color:var(--ink);line-height:1.7;white-space:pre-wrap;background:var(--bg);padding:12px;border-radius:8px">${camp.guide}</div>
      </div>` : ''}

      ${camp.ng ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">NG事項</div>
        <div style="font-size:12px;color:var(--ink);line-height:1.7;white-space:pre-wrap;background:#fff8f8;padding:12px;border-radius:8px;border:1px solid #fdd">${camp.ng}</div>
      </div>` : ''}

      ${camp.product_url ? `
      <div style="background:#fff;padding:12px 16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <a href="${camp.product_url}" target="_blank" style="display:flex;align-items:center;gap:8px;color:var(--pink);font-size:13px;font-weight:600;text-decoration:none">
          <span style="font-size:16px">🛍</span> 商品ページを見る →
        </a>
      </div>` : ''}

      <div style="background:#fff;padding:16px;">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">注意事項</div>
        <ul style="font-size:12px;color:var(--muted);line-height:1.8;padding-left:14px;display:flex;flex-direction:column;gap:2px">
          <li>期限内での対応が難しい方は、申請をご遠慮いただくようお願いいたします。</li>
          <li>投稿が期限内に行われない場合、原稿料のお支払いはできません。</li>
          <li>ガイドラインを遵守したうえで作成し、遵守されていない場合は修正をお願いします。</li>
          <li>掲載されたレビューはブランドのマーケティング目的で活用される場合があります。</li>
          <li>投稿は6ヶ月以上の掲載が必須です。</li>
          <li>当選されなかった方への個別のご連絡は実施しておりません。</li>
          <li>ご不明点は <a href="https://line.me/R/ti/p/@586mnjoc" target="_blank" style="color:var(--pink);font-weight:600">LINE(@586mnjoc)</a> まで。</li>
        </ul>
      </div>
      <div style="display:flex;flex-direction:column;gap:10px;padding:0 0 calc(var(--tab-h) + 70px)">
        <div style="background:linear-gradient(135deg,#E8789A 0%,#C84B8C 100%);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;cursor:pointer" onclick="window.open('https://instagram.com/reverb_jp','_blank')">
          <div style="flex-shrink:0;width:44px;height:44px;background:#fff;border-radius:10px;display:flex;align-items:center;justify-content:center">
            <svg width="26" height="26" viewBox="0 0 24 24" fill="none"><defs><radialGradient id="igC" cx="30%" cy="107%"><stop offset="0%" stop-color="#ffd676"/><stop offset="50%" stop-color="#f56040"/><stop offset="100%" stop-color="#833ab4"/></radialGradient></defs><rect x="2" y="2" width="20" height="20" rx="5.5" fill="url(#igC)"/><circle cx="12" cy="12" r="4" fill="none" stroke="#fff" stroke-width="1.8"/><circle cx="17.5" cy="6.5" r="1.2" fill="#fff"/></svg>
          </div>
          <div style="flex:1">
            <div style="font-family:'Sora',sans-serif;font-weight:800;font-size:14px;color:#fff;margin-bottom:2px">REVERB <span style="font-size:10px;font-weight:600;opacity:.85">INSTAGRAM</span></div>
            <div style="font-size:11px;color:rgba(255,255,255,.95);font-weight:600;line-height:1.5">公式アカウントをフォローして最新キャンペーン情報を受け取る</div>
            <div style="font-size:10px;color:rgba(255,255,255,.65);margin-top:2px">@reverb_jp をフォロー →</div>
          </div>
        </div>
        <div style="background:linear-gradient(135deg,#3AC05A 0%,#06A434 100%);border-radius:14px;padding:16px 18px;display:flex;align-items:center;gap:14px;cursor:pointer" onclick="window.open('https://line.me/R/ti/p/@586mnjoc','_blank')">
          <div style="flex-shrink:0;width:44px;height:44px;background:#fff;border-radius:10px;overflow:hidden;padding:3px">
            <img src="https://qr-official.line.me/sid/M/586mnjoc.png" style="width:100%;height:100%;object-fit:contain" alt="LINE QR" onerror="this.src='data:image/svg+xml,<svg xmlns=%22http://www.w3.org/2000/svg%22 viewBox=%220 0 40 40%22><rect width=%2240%22 height=%2240%22 fill=%22%2306A434%22/><text x=%2250%%22 y=%2255%%22 text-anchor=%22middle%22 fill=%22white%22 font-size=%2218%22>L</text></svg>'">
          </div>
          <div style="flex:1">
            <div style="font-family:'Sora',sans-serif;font-weight:800;font-size:14px;color:#fff;margin-bottom:2px">REVERB <span style="font-size:10px;font-weight:600;opacity:.85">LINE</span></div>
            <div style="font-size:11px;color:rgba(255,255,255,.95);font-weight:600;line-height:1.5">LINE公式アカウントを追加して最新キャンペーン情報を受け取りましょう。</div>
            <div style="font-size:10px;color:rgba(255,255,255,.8);margin-top:2px">友だち検索「@586mnjoc」</div>
            <div style="display:inline-block;background:rgba(255,255,255,.2);border:1px solid rgba(255,255,255,.4);border-radius:20px;padding:2px 9px;font-size:10px;font-weight:700;color:#fff;margin-top:4px">Reverbチャンネル登録は必須です ✓</div>
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
  if (floatReward) floatReward.textContent = camp.product_price>0
    ? `¥${camp.product_price.toLocaleString()}円相当の製品を無償提供`
    : '製品全額無償提供';
  if (floatProductPageBtn) {
    floatProductPageBtn.style.display = camp.product_url ? 'inline-flex' : 'none';
    floatProductPageBtn.dataset.url = camp.product_url||'';
  }
  if (floatApplyBtn) {
    if (alreadyApplied) { floatApplyBtn.textContent='✓ 応募済み'; floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; }
    else if (isFull) { floatApplyBtn.textContent='募集終了'; floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; }
    else { floatApplyBtn.textContent='申請'; floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm'; }
  }
  if (fb) fb.style.display='block';

  navigate('detail');
}

// ══════════════════════════════════════
// APPLY MODAL
// ══════════════════════════════════════
function openApplyModal(campaignId) {
  currentCampaignId = campaignId;
  const camp = allCampaigns.find(c=>c.id===campaignId);
  if (camp) $('applyModalTitle').textContent = `応募: ${camp.title}`;
  $('applyMessage').value = '';
  $('applyAddress').value = currentUserProfile?.address || '';
  $('applyPrCheck').checked = false;
  $('applyModal').classList.add('open');
}

async function submitApplication() {
  if (!currentUser) { toast('ログインが必要です','error'); return; }
  const msg = $('applyMessage').value.trim();
  const addr = $('applyAddress').value.trim();
  const prCheck = $('applyPrCheck').checked;
  if (!msg) { toast('応募理由を入力してください','error'); return; }
  if (!addr) { toast('配送先住所を入力してください','error'); return; }
  if (!prCheck) { toast('#PRタグの表記に同意が必要です','error'); return; }

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
    toast('すでに応募済みのキャンペーンです','error'); closeModal('applyModal'); return;
  }

  try {
    await insertApplication({
      user_id: currentUser.id, user_email: currentUser.email,
      user_name: currentUserProfile?.name || currentUser.email,
      user_followers: currentUserProfile?.followers || 0,
      user_ig: currentUserProfile?.ig || '',
      campaign_id: currentCampaignId, message: msg, address: addr, status: 'pending'
    });
    // 신청수 업데이트
    const camp = allCampaigns.find(c=>c.id===currentCampaignId);
    if (camp) {
      camp.applied_count = (camp.applied_count||0) + 1;
      await updateCampaign(currentCampaignId, {applied_count: camp.applied_count}).catch(()=>{});
    }
  } catch(e) {
    toast('応募エラー: '+e.message,'error'); closeModal('applyModal'); return;
  }

  closeModal('applyModal');
  toast('応募完了！結果はメールでお知らせします ✉️','success');
  openCampaign(currentCampaignId);
}

// ── FLOAT BAR + LOGIN PROMPT ──
function handleFloatApply() {
  if (!currentUser) {
    const o = $('loginPromptOverlay');
    if (o) { o.style.display='flex'; }
    return;
  }
  openApplyModal(currentCampaignId);
}
function openProductPage() {
  const url = $('floatProductPageBtn')?.dataset.url;
  if (url) window.open(url,'_blank');
}
