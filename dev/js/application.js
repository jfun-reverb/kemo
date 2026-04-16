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
  if (currentUser) {
    const {data:_appData} = await (db?.from('applications').select('*').eq('user_id', currentUser.id).eq('campaign_id', id).maybeSingle() || {data:null});
    _myApp = _appData;
    alreadyApplied = !!_myApp;
  }

  // 리뷰어(monitor)만 모집인원 초과 시 신규 응모 차단. 기프팅·방문형은 초과 응모 허용.
  const isFull = camp.recruit_type === 'monitor' && (camp.applied_count||0) >= camp.slots;
  _slideIdx = 0;

  // 슬라이드 이미지
  const slideImgs = [camp.img1,camp.img2,camp.img3,camp.img4,camp.img5,camp.img6,camp.img7,camp.img8,camp.image_url]
    .filter(Boolean).filter((v,i,a)=>a.indexOf(v)===i);

  const slideHtml = slideImgs.length > 0 ? `
    <div id="campSlider" style="position:relative;overflow:hidden;border-radius:16px;margin-bottom:0;background:${getCampGrad(camp.category)};aspect-ratio:1/1;height:auto">
      <div id="campSlides" style="display:flex;height:100%;transition:transform .32s cubic-bezier(.4,0,.2,1)">
        ${slideImgs.map((url,idx)=>`<div style="flex:0 0 100%;width:100%;height:100%;background:${getCampGrad(camp.category)}"><img src="${imgThumb(url,960,80)}" data-orig="${url}" ${idx===0?'':'loading="lazy"'} decoding="async" style="width:100%;height:100%;object-fit:contain;display:block" onerror="if(this.src!==this.dataset.orig){this.src=this.dataset.orig}else{this.parentElement.style.background='${getCampGrad(camp.category)}'}"></div>`).join('')}
      </div>
      ${slideImgs.length>1?`
        <button onclick="slideMove(-1)" style="position:absolute;left:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round" style="font-size:20px;color:#333">chevron_left</span></button>
        <button onclick="slideMove(1)" style="position:absolute;right:10px;top:50%;transform:translateY(-50%);width:30px;height:30px;background:rgba(255,255,255,.88);border:none;border-radius:50%;cursor:pointer;display:flex;align-items:center;justify-content:center;z-index:5;box-shadow:0 2px 6px rgba(0,0,0,.15)"><span class="material-icons-round" style="font-size:20px;color:#333">chevron_right</span></button>
        <div style="position:absolute;bottom:10px;left:50%;transform:translateX(-50%);display:flex;gap:5px;z-index:5">
          ${slideImgs.map((_,i)=>`<div onclick="slideTo(${i})" id="dot${i}" style="width:${i===0?'16px':'6px'};height:6px;border-radius:3px;background:${i===0?'#fff':'rgba(255,255,255,.5)'};border:1px solid rgba(0,0,0,.06);cursor:pointer;transition:.2s"></div>`).join('')}
        </div>
        <div style="position:absolute;top:12px;right:12px;background:rgba(0,0,0,.45);color:#fff;font-size:11px;font-weight:600;padding:3px 8px;border-radius:20px;z-index:5"><span id="slideCurrentNum">1</span>/${slideImgs.length}</div>` : ''}
      <div style="position:absolute;top:12px;left:12px;display:flex;gap:5px;z-index:5">
        ${camp.content_types?camp.content_types.split(',').map(t=>`<span style="background:rgba(0,0,0,.55);color:#fff;font-size:10px;font-weight:700;padding:3px 9px;border-radius:20px;backdrop-filter:blur(4px)">${esc(t.trim())}</span>`).join(''):''}
      </div>
    </div>` : `<div style="aspect-ratio:1/1;width:100%;border-radius:16px;background:${getCampGrad(camp.category)};display:flex;align-items:center;justify-content:center;font-size:64px">${camp.emoji||''}</div>`;

  $('detailContent').innerHTML = `
    <div class="detail-main">
      ${slideHtml}

      <div style="background:#fff;border-bottom:1px solid var(--line);margin-bottom:10px">
        <div style="padding:16px 16px 12px">
          <div style="font-size:11px;color:var(--pink);font-weight:700;letter-spacing:.06em;margin-bottom:5px">${esc(camp.brand)}</div>
          <div style="font-size:18px;font-weight:800;color:var(--ink);line-height:1.3;margin-bottom:10px">${esc(camp.title)}</div>
          ${camp.product_price>0?`<div style="display:inline-flex;align-items:center;gap:6px;background:var(--light-pink);border-radius:8px;padding:6px 12px;margin-bottom:4px"><span style="font-size:17px;font-weight:900;color:var(--pink)">¥${camp.product_price.toLocaleString()}</span><span style="font-size:12px;color:var(--dark-pink);font-weight:600">円相当の製品を無償提供</span></div>`:''}
          ${camp.reward>0?`<div style="font-size:12px;color:var(--green);font-weight:600;margin-top:4px">+ 現金リワード ¥${camp.reward.toLocaleString()}</div>`:''}
        </div>
        <div style="font-size:13px">
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">商品名</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${esc(camp.product)||'—'}</div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">募集タイプ</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">
              ${(()=>{const t=camp.recruit_type;const map={monitor:['var(--blue-l)','var(--blue)','Reviewer'],gifting:['var(--gold-l)','var(--gold)','Gifting'],visit:['#E8F7EF','#0E7E4A','Visit']};const m=map[t];return m?`<span style="background:${m[0]};color:${m[1]};font-size:11px;font-weight:700;padding:2px 8px;border-radius:20px">${m[2]}</span>`:'—'})()}
            </div>
          </div>
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">チャンネル</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;display:flex;gap:6px;flex-wrap:wrap;align-items:center">
              ${(()=>{const sep = camp.channel_match === 'and' ? '&' : 'or'; return (camp.channel||'').split(',').map(s=>s.trim()).filter(Boolean).map(code=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:11px;font-weight:600;padding:2px 10px;border-radius:20px">${esc(getChannelLabel(code))}</span>`).join(`<span style="color:var(--muted);font-size:11px;font-weight:600">${sep}</span>`);})()}
            </div>
          </div>
          ${camp.content_types?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">コンテンツ</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;display:flex;gap:4px;flex-wrap:wrap">
              ${camp.content_types.split(',').map(t=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:10px;font-weight:600;padding:2px 8px;border-radius:20px">${esc(t.trim())}</span>`).join('')}
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
          ${(camp.recruit_type==='monitor' && (camp.purchase_start||camp.purchase_end))?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">購入期間</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${camp.purchase_start?formatDate(camp.purchase_start):'—'} 〜 ${camp.purchase_end?formatDate(camp.purchase_end):'—'}</div>
          </div>`:''}
          ${(camp.recruit_type==='visit' && (camp.visit_start||camp.visit_end))?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">訪問期間</div>
            <div style="padding:10px 13px;flex:1;font-size:12px">${camp.visit_start?formatDate(camp.visit_start):'—'} 〜 ${camp.visit_end?formatDate(camp.visit_end):'—'}</div>
          </div>`:''}
          ${camp.submission_end?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">成果物提出締切</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;font-weight:600;color:var(--ink)">${formatDate(camp.submission_end)}</div>
          </div>`:''}
          ${(camp.product_price>0||camp.reward>0)?`
          <div style="display:flex;border-top:1px solid #faf5f9">
            <div style="width:90px;padding:10px 14px;color:var(--dark-pink);font-weight:600;font-size:11px;background:#fdf5fb;flex-shrink:0">リワード</div>
            <div style="padding:10px 13px;flex:1;font-size:12px;color:var(--pink);font-weight:600">
              ${camp.product_price>0?`製品 ¥${camp.product_price.toLocaleString()}円相当`:'製品無償提供'}${camp.reward>0?` + 現金 ¥${camp.reward.toLocaleString()}`:''}
            </div>
          </div>`:''}
        </div>
      </div>

      ${(() => {
        // 캠페인별 참여방법 스냅샷 우선, 없으면 legacy 하드코딩 fallback
        const legacy = [
          {title_ja:'応募フォームを提出', desc_ja:'当選された方には当選日にLINEにてご連絡いたします。'},
          {title_ja:'製品を使用してSNSにレビューを投稿', desc_ja:'① 投稿ガイドを確認 ② SNSにレビューを投稿'},
          {title_ja:'LINEで投稿リンクを送る', desc_ja:'SNSの投稿リンクをコピーして、LINEで送信してください。'}
        ];
        const steps = (Array.isArray(camp.participation_steps) && camp.participation_steps.length)
          ? camp.participation_steps
          : legacy;
        return `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:14px;color:var(--ink)">参加方法</div>
        <div style="display:flex;flex-direction:column;gap:14px">
          ${steps.map((s,i)=>`
            <div style="display:flex;gap:12px;align-items:flex-start">
              <div style="min-width:50px;height:20px;background:var(--light-pink);border-radius:20px;display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700;color:var(--pink);flex-shrink:0">STEP ${i+1}</div>
              <div>
                <div style="font-size:13px;font-weight:700;margin-bottom:2px">${esc(s.title_ja||s.title_ko||'')}</div>
                ${(s.desc_ja||s.desc_ko) ? `<div style="font-size:12px;color:var(--muted);line-height:1.55">${esc(s.desc_ja||s.desc_ko||'')}</div>` : ''}
              </div>
            </div>
          `).join('')}
        </div>
      </div>`;
      })()}

      ${camp.description ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">キャンペーン説明</div>
        <div class="rich-content" style="font-size:13px;color:var(--ink);line-height:1.7">${richHtml(camp.description)}</div>
      </div>` : ''}

      ${(camp.hashtags||camp.mentions||camp.appeal) ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:12px;color:var(--ink)">投稿ガイドライン</div>
        ${camp.appeal ? `<div style="margin-bottom:12px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">ブランドアピールポイント</div><div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:var(--bg);padding:10px 12px;border-radius:8px">${richHtml(camp.appeal)}</div></div>` : ''}
        ${camp.hashtags ? `<div style="margin-bottom:10px"><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">必須ハッシュタグ</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.hashtags.split(',').map(t=>`<span style="background:var(--light-pink);color:var(--dark-pink);font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(t.trim())}</span>`).join('')}</div></div>` : ''}
        ${camp.mentions ? `<div><div style="font-size:11px;font-weight:700;color:var(--pink);margin-bottom:5px;text-transform:uppercase;letter-spacing:.05em">必須メンション</div><div style="display:flex;flex-wrap:wrap;gap:5px">${camp.mentions.split(',').map(t=>`<span style="background:#f0f0ff;color:#4040cc;font-size:12px;font-weight:600;padding:3px 10px;border-radius:20px">${esc(t.trim())}</span>`).join('')}</div></div>` : ''}
      </div>` : ''}

      ${camp.guide ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">撮影ガイド</div>
        <div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:var(--bg);padding:12px;border-radius:8px">${richHtml(camp.guide)}</div>
      </div>` : ''}

      ${camp.ng ? `
      <div style="background:#fff;padding:16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <div style="font-size:14px;font-weight:700;margin-bottom:10px;color:var(--ink)">NG事項</div>
        <div class="rich-content" style="font-size:12px;color:var(--ink);line-height:1.7;background:#fff8f8;padding:12px;border-radius:8px;border:1px solid #fdd">${richHtml(camp.ng)}</div>
      </div>` : ''}

      ${camp.product_url ? `
      <div style="background:#fff;padding:12px 16px;margin-bottom:10px;border-bottom:8px solid var(--bg)">
        <a href="${esc(cleanUrl(camp.product_url))}" target="_blank" style="display:flex;align-items:center;gap:8px;color:var(--pink);font-size:13px;font-weight:600;text-decoration:none">
          <span class="material-icons-round notranslate" translate="no" style="font-size:16px">shopping_bag</span> 商品ページを見る →
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
            <div style="display:inline-block;background:rgba(255,255,255,.2);border:1px solid rgba(255,255,255,.4);border-radius:20px;padding:2px 9px;font-size:10px;font-weight:700;color:#fff;margin-top:4px">Reverbチャンネル登録は必須です <span class="material-icons-round notranslate" translate="no" style="font-size:10px;vertical-align:middle">check</span></div>
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
    floatProductPageBtn.dataset.url = cleanUrl(camp.product_url)||'';
  }
  if (floatApplyBtn) {
    if (_myApp?.status === 'approved') {
      floatApplyBtn.textContent='活動管理'; floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm';
      floatApplyBtn.onclick = () => openActivityPage(_myApp.id, id, 'detail');
    } else if (alreadyApplied) { floatApplyBtn.textContent='応募済み'; floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (camp.status==='closed') { floatApplyBtn.textContent='募集締切'; floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else if (isFull) { floatApplyBtn.textContent='募集終了'; floatApplyBtn.disabled=true; floatApplyBtn.className='btn btn-ghost btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
    else { floatApplyBtn.textContent='申請'; floatApplyBtn.disabled=false; floatApplyBtn.className='btn btn-primary btn-sm'; floatApplyBtn.onclick=()=>handleFloatApply(); }
  }
  if (fb) fb.style.display='block';

  // 뒤로가기 버튼 라벨 업데이트
  const backLabel = $('detailBackLabel');
  if (backLabel) backLabel.textContent = _detailFrom === 'mypage' ? '応募履歴へ' : 'キャンペーン一覧へ';

  navigate('detail-' + id);
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

  // 리뷰어(monitor) 캠페인은 모집인원 초과 시 응모 차단
  // 주의: 클라이언트 캐시 기반 사전 차단(UX 보조). 근본 방어는 DB 레벨 트리거/체크가 필요.
  const camp0 = allCampaigns.find(c => c.id === currentCampaignId);
  if (camp0 && camp0.recruit_type === 'monitor') {
    const applied = Number(camp0.applied_count || 0);
    const slots = Number(camp0.slots || 0);
    if (slots > 0 && applied >= slots) {
      toast('募集人数に達したため、応募できません', 'error');
      closeModal('applyModal');
      return;
    }
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
    if (e.message?.includes('row-level security')) {
      toast('セッションの有効期限が切れました。再ログインしてください','error');
      closeModal('applyModal');
      currentUser = null; currentUserProfile = null;
      updateGnb();
      return;
    }
    toast(friendlyErrorJa(e), 'error'); closeModal('applyModal'); return;
  }

  closeModal('applyModal');
  toast('応募完了！結果はメールでお知らせします','success');
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
    toast('メールアドレスの認証が必要です。受信メールをご確認ください','error');
    return;
  }
  // 필수 정보 체크: 캠페인 채널에 맞는 SNS 계정 + 배송지
  const p = currentUserProfile || {};
  const camp = allCampaigns.find(c => c.id === currentCampaignId) || {};
  const ch = (camp.channel || '').toLowerCase();
  const missing = [];
  // 캠페인 채널에 맞는 SNS 계정 체크
  if (ch.includes('instagram') && !p.ig) missing.push('Instagram ID');
  if (ch.includes('x') && !p.x) missing.push('X(Twitter) ID');
  if (ch.includes('tiktok') && !p.tiktok) missing.push('TikTok ID');
  if (ch.includes('youtube') && !p.youtube) missing.push('YouTube ID');
  if (ch.includes('qoo10') && !p.ig) missing.push('Instagram ID');
  // SNS 계정이 하나도 없으면 기본적으로 Instagram 체크
  if (!ch && !p.ig) missing.push('Instagram ID');
  if (!p.zip) missing.push('郵便番号');
  if (!p.prefecture) missing.push('都道府県');
  if (!p.city) missing.push('市区町村・番地');
  if (!p.phone) missing.push('電話番号');
  if (!p.paypal_email) missing.push('PayPal メールアドレス');
  if (missing.length > 0) {
    $('profileAlertMissing').innerHTML = missing.map(m =>
      `<div style="display:flex;align-items:center;gap:8px;padding:8px 12px;margin-bottom:6px;background:var(--light-pink);border-radius:10px;font-size:13px;color:var(--dark-pink);font-weight:600">
        <span class="material-icons-round" style="font-size:18px;color:var(--pink)">warning</span>${m}
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
      $('alertModalMessage').innerHTML = `このキャンペーンの応募条件は<br><strong>${primaryName}</strong> フォロワー <strong>${minF.toLocaleString()}人以上</strong> です。<br><br>あなたの ${primaryName} フォロワー数:<br><strong>${primaryCount.toLocaleString()}人</strong><br><br><span style="font-size:11px;color:var(--muted)">※ フォロワー数の虚偽申告が発覚した場合、<br>アカウント停止等の不利益を受ける場合があります。</span>`;
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
let _receiptImgData = null;

async function openActivityPage(applicationId, campaignId, from) {
  _activityAppId = applicationId;
  _activityCampId = campaignId;
  _activityFrom = from || 'detail';
  const camp = allCampaigns.find(c=>c.id===campaignId) || {};
  _activityCamp = camp;
  $('activityCampTitle').textContent = camp.title || '';
  $('activityCampBrand').textContent = camp.brand || '';

  // 타입 분기 (Stage 3)
  const rt = camp.recruit_type || 'monitor';
  const isPostType = (rt === 'gifting' || rt === 'visit');
  $('activityReceiptSection').style.display = isPostType ? 'none' : '';
  $('activityPostSection').style.display = isPostType ? '' : 'none';

  // 제출 마감일 안내 + 마감 초과 시 폼 비활성
  const submissionEnd = camp.submission_end || camp.post_deadline || null;
  const isAfterDeadline = submissionEnd ? (new Date(submissionEnd + 'T23:59:59') < new Date()) : false;
  const deadlineBox = $('activitySubmissionDeadline');
  if (deadlineBox) {
    if (submissionEnd) {
      deadlineBox.style.display = '';
      deadlineBox.textContent = isAfterDeadline
        ? `提出期限が過ぎました (${formatDate(submissionEnd)})`
        : `提出期限: ${formatDate(submissionEnd)}`;
      deadlineBox.style.color = isAfterDeadline ? '#C33' : 'var(--muted)';
    } else {
      deadlineBox.style.display = 'none';
    }
  }
  // 마감 후엔 입력 UI 비활성
  const formDisabled = isAfterDeadline;
  if (isPostType) {
    const urlEl = $('postUrlInput'); if (urlEl) urlEl.disabled = formDisabled;
    const selEl = $('postChannelManual'); if (selEl) selEl.disabled = formDisabled;
  } else {
    const rf = $('receiptFile'); if (rf) rf.disabled = formDisabled;
    const rd = $('receiptDate'); if (rd) rd.disabled = formDisabled;
    const ra = $('receiptAmount'); if (ra) ra.disabled = formDisabled;
  }

  // 폼 초기화
  if (!isPostType) {
    $('receiptPreview').innerHTML = '';
    $('receiptDate').value = '';
    $('receiptAmount').value = '';
    $('receiptFile').value = '';
    _receiptImgData = null;
  } else {
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
  x: 'X (Twitter)', qoo10: 'Qoo10', other: 'その他'
};

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
    if (detectedLbl) detectedLbl.textContent = `判別: ${CHANNEL_LABELS[ch]}`;
    if (detectedLbl) detectedLbl.style.color = 'var(--dark-pink)';
    if (manualWrap) manualWrap.style.display = 'none';
  } else {
    if (detectedLbl) detectedLbl.textContent = 'URLからチャンネルを自動判別できません';
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

async function loadReceipts() { return loadDeliverablesForActivity(); }

// Stage 3: 활동관리 화면의 결과물 리스트 (영수증·게시물 통합)
async function loadDeliverablesForActivity() {
  const camp = _activityCamp || {};
  const isPostType = (camp.recruit_type === 'gifting' || camp.recruit_type === 'visit');
  const kind = isPostType ? 'post' : 'receipt';
  const delivs = await fetchDeliverablesForUser({
    application_id: _activityAppId,
    user_id: currentUser?.id,
    kind
  });

  // 반려 사유 배너: 최신 제출 건이 rejected일 때만 표시 (재제출하면 새 deliverable이 pending이므로 숨김)
  const banner = $('activityRejectBanner');
  const reasonEl = $('activityRejectReason');
  if (banner && reasonEl) {
    const sorted = delivs.slice().sort((a,b) => (b.submitted_at||'').localeCompare(a.submitted_at||''));
    const latest = sorted[0];
    if (latest && latest.status === 'rejected' && latest.reject_reason) {
      banner.style.display = '';
      reasonEl.textContent = latest.reject_reason;
    } else {
      banner.style.display = 'none';
    }
  }

  if (isPostType) renderActivityPostList(delivs);
  else renderActivityReceiptList(delivs);
}

function renderActivityReceiptList(delivs) {
  const container = $('receiptList');
  if (!container) return;
  if (!delivs.length) {
    container.innerHTML = '<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">まだレシートが登録されていません</div>';
    return;
  }
  container.innerHTML = delivs.map(r => {
    const stBadge = activityStatusBadge(r.status);
    return `
    <div style="display:flex;align-items:center;gap:12px;padding:12px;background:var(--surface);border:1px solid var(--outline);border-radius:12px;margin-bottom:8px">
      <div style="width:48px;height:48px;border-radius:8px;overflow:hidden;flex-shrink:0;background:var(--surface-dim)">
        ${r.receipt_url ? `<img src="${esc(r.receipt_url)}" style="width:100%;height:100%;object-fit:cover;cursor:pointer" onclick="window.open('${esc(r.receipt_url)}','_blank')">` : ''}
      </div>
      <div style="flex:1;min-width:0">
        <div style="font-size:13px;font-weight:600;color:var(--ink)">${r.purchase_date ? formatDate(r.purchase_date) : '日付未入力'}</div>
        <div style="font-size:12px;color:var(--muted)">${r.purchase_amount ? '¥'+Number(r.purchase_amount).toLocaleString() : '金額未入力'}</div>
      </div>
      <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">
        ${stBadge}
        <div style="font-size:10px;color:var(--muted)">${formatDate(r.submitted_at || r.created_at)}</div>
      </div>
    </div>`;
  }).join('');
}

function renderActivityPostList(delivs) {
  const container = $('postSubmissionList');
  if (!container) return;
  if (!delivs.length) {
    container.innerHTML = '<div style="text-align:center;color:var(--muted);font-size:13px;padding:16px">まだ投稿が登録されていません</div>';
    return;
  }
  container.innerHTML = delivs.map(d => {
    const stBadge = activityStatusBadge(d.status);
    const chLabel = CHANNEL_LABELS[d.post_channel] || d.post_channel || '—';
    const subs = Array.isArray(d.post_submissions) ? d.post_submissions : [];
    return `
    <div style="padding:12px;background:var(--surface);border:1px solid var(--outline);border-radius:12px;margin-bottom:8px">
      <div style="display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px">
        <div style="font-size:12px;font-weight:600;color:var(--ink)">${esc(chLabel)}</div>
        ${stBadge}
      </div>
      <a href="${esc(d.post_url||'')}" target="_blank" rel="noopener" style="font-size:12px;color:var(--dark-pink);word-break:break-all;text-decoration:none">${esc(d.post_url||'')}</a>
      ${subs.length > 1 ? `<div style="font-size:10px;color:var(--muted);margin-top:6px">提出回数: ${subs.length}回</div>` : ''}
      <div style="font-size:10px;color:var(--muted);margin-top:4px">${formatDate(d.submitted_at)}</div>
    </div>`;
  }).join('');
}

function activityStatusBadge(status) {
  if (status === 'approved') return '<span style="background:#E4F5E8;color:#2D7A3E;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">承認</span>';
  if (status === 'rejected') return '<span style="background:#FFE4E4;color:#C33;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">差戻</span>';
  return '<span style="background:#FFF4E4;color:#B8741A;font-size:10px;font-weight:600;padding:2px 7px;border-radius:3px">審査中</span>';
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

// Stage 3: 게시물 URL 제출 (기프팅·방문형)
async function submitPostUrl() {
  if (!currentUser) { toast('ログインが必要です','error'); return; }
  const url = ($('postUrlInput')?.value || '').trim();
  if (!url) { toast('URLを入力してください', 'error'); return; }
  // URL 형식 검증
  try { new URL(url); } catch(e) { toast('URLの形式が正しくありません','error'); return; }

  // 제출 마감 확인
  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()) {
    toast('提出期限が過ぎたため、登録できません','error');
    return;
  }

  // 채널 판별 (자동 실패 시 수동 선택 필수)
  let channel = detectChannelFromUrl(url);
  if (!channel) {
    channel = $('postChannelManual')?.value || '';
    if (!channel) { toast('チャンネルを選択してください', 'error'); return; }
  }

  try {
    // 동일 URL 재제출 여부 확인
    const existing = await fetchDeliverablesForUser({
      application_id: _activityAppId,
      user_id: currentUser.id,
      kind: 'post'
    });
    const sameUrl = existing.find(d => (d.post_url || '').trim() === url);
    if (sameUrl) {
      await appendPostSubmission(sameUrl.id, url, channel);
      toast(sameUrl.status === 'rejected' ? '再提出しました' : '提出履歴を追加しました', 'success');
    } else {
      const id = await insertPostDeliverable({
        application_id: _activityAppId,
        user_id: currentUser.id,
        campaign_id: _activityCampId,
        post_url: url,
        post_channel: channel
      });
      if (!id) { toast('登録に失敗しました', 'error'); return; }
      toast('投稿URLを登録しました', 'success');
    }
    // 폼 초기화
    const urlEl = $('postUrlInput'); if (urlEl) urlEl.value = '';
    const ch = $('postChannelDetected'); if (ch) ch.textContent = '';
    const mw = $('postChannelManualWrap'); if (mw) mw.style.display = 'none';
    await loadDeliverablesForActivity();
  } catch(e) {
    toast(friendlyErrorJa(e), 'error');
  }
}

async function submitReceipt() {
  if (!_receiptImgData) { toast('レシート画像を選択してください','error'); return; }
  if (!currentUser) { toast('ログインが必要です','error'); return; }

  // 제출 마감 확인 (Stage 3)
  const camp = _activityCamp || {};
  const submissionEnd = camp.submission_end || camp.post_deadline;
  if (submissionEnd && new Date(submissionEnd + 'T23:59:59') < new Date()) {
    toast('提出期限が過ぎたため、登録できません','error');
    return;
  }

  try {
    toast('アップロード中...','');
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

    toast('レシートを登録しました','success');
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
