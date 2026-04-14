// ══════════════════════════════════════
// LEGAL — 약관/개인정보 페이지 마크다운 렌더링
// ══════════════════════════════════════

const LEGAL_DOCS = {
  terms:   { ko: 'docs/TERMS_kr.md',   ja: 'docs/TERMS_ja.md',   titleKo: '서비스 이용약관',     titleJa: '利用規約' },
  privacy: { ko: 'docs/PRIVACY_kr.md', ja: 'docs/PRIVACY_ja.md', titleKo: '개인정보 처리방침',   titleJa: '個人情報処理方針' }
};

let _currentLegal = { kind: 'terms', lang: 'ko' };

// 매우 간단한 마크다운 → HTML 변환 (자체 문서 전용, 외부 입력 금지)
function renderMarkdown(md) {
  if (!md) return '';
  const escape = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  const inline = s => s
    .replace(/`([^`]+)`/g, (_,c)=>`<code>${escape(c)}</code>`)
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\*([^*]+)\*/g, '<em>$1</em>')
    .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

  const lines = md.split('\n');
  const html = [];
  let i = 0;
  let inList = null;

  const closeList = () => { if (inList) { html.push(`</${inList}>`); inList = null; } };

  while (i < lines.length) {
    const line = lines[i];

    // 표 (헤더 | --- | 본문)
    if (line.includes('|') && lines[i+1] && /^\s*\|?\s*:?-+/.test(lines[i+1])) {
      closeList();
      const parseRow = l => l.replace(/^\s*\|/,'').replace(/\|\s*$/,'').split('|').map(c=>c.trim());
      const headers = parseRow(line);
      i += 2;
      const rows = [];
      while (i < lines.length && lines[i].includes('|')) {
        rows.push(parseRow(lines[i]));
        i++;
      }
      html.push('<table class="legal-table"><thead><tr>'
        + headers.map(h=>`<th>${inline(escape(h))}</th>`).join('')
        + '</tr></thead><tbody>'
        + rows.map(r=>'<tr>'+r.map(c=>`<td>${inline(escape(c))}</td>`).join('')+'</tr>').join('')
        + '</tbody></table>');
      continue;
    }

    // 헤딩
    const h = line.match(/^(#{1,6})\s+(.+)/);
    if (h) {
      closeList();
      const level = h[1].length;
      html.push(`<h${level}>${inline(escape(h[2]))}</h${level}>`);
      i++; continue;
    }

    // 수평선
    if (/^---+$/.test(line.trim())) { closeList(); html.push('<hr>'); i++; continue; }

    // 인용
    if (/^>\s?/.test(line)) {
      closeList();
      const buf = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) { buf.push(lines[i].replace(/^>\s?/,'')); i++; }
      html.push(`<blockquote>${inline(escape(buf.join(' ')))}</blockquote>`);
      continue;
    }

    // 순서 없는 리스트
    const ul = line.match(/^\s*-\s+(.+)/);
    if (ul) {
      if (inList !== 'ul') { closeList(); html.push('<ul>'); inList = 'ul'; }
      html.push(`<li>${inline(escape(ul[1]))}</li>`);
      i++; continue;
    }

    // 순서 있는 리스트
    const ol = line.match(/^\s*\d+\.\s+(.+)/);
    if (ol) {
      if (inList !== 'ol') { closeList(); html.push('<ol>'); inList = 'ol'; }
      html.push(`<li>${inline(escape(ol[1]))}</li>`);
      i++; continue;
    }

    // 빈 줄
    if (!line.trim()) { closeList(); i++; continue; }

    // 일반 단락
    closeList();
    html.push(`<p>${inline(escape(line))}</p>`);
    i++;
  }
  closeList();
  return html.join('\n');
}

async function openLegalPage(kind, lang) {
  _currentLegal.kind = kind;
  // 인자 > 현재 i18n 언어 > 기존 상태 > ja 기본
  _currentLegal.lang = lang || (typeof getLang === 'function' ? getLang() : null) || _currentLegal.lang || 'ja';
  navigate('legal');
  await renderLegalPage();
}

function setLegalLang(lang) {
  _currentLegal.lang = lang;
  renderLegalPage();
}

async function renderLegalPage() {
  const { kind, lang } = _currentLegal;
  const def = LEGAL_DOCS[kind];
  if (!def) return;

  // 타이틀
  const titleEl = document.getElementById('legalPageTitle');
  if (titleEl) titleEl.textContent = lang === 'ja' ? def.titleJa : def.titleKo;

  // 언어 탭 활성 표시
  document.querySelectorAll('.legal-lang-btn').forEach(b => {
    b.classList.toggle('on', b.dataset.lang === lang);
  });

  // 본문
  const body = document.getElementById('legalPageBody');
  if (!body) return;
  body.innerHTML = '<div style="text-align:center;padding:40px 0"><span class="spinner"></span></div>';

  try {
    const url = def[lang];
    const res = await fetch(url, { cache: 'no-cache' });
    if (!res.ok) throw new Error('fetch failed');
    const md = await res.text();
    body.innerHTML = renderMarkdown(md);
    body.scrollTop = 0;
  } catch(e) {
    if (lang === 'ja') {
      body.innerHTML = `
        <div style="padding:40px 16px;text-align:center;color:var(--muted);font-size:13px;line-height:1.8">
          <div style="font-size:32px;margin-bottom:12px"><span class="material-icons-round notranslate" translate="no">translate</span></div>
          <div style="font-weight:700;color:var(--ink);margin-bottom:6px">日本語版は現在準備中です</div>
          <div>正式な日本語訳は施行日（2026年5月1日）までに公開予定です。</div>
          <div style="margin-top:12px">韓国語版を確認するか、公式LINE（<a href="https://line.me/R/ti/p/@586mnjoc" target="_blank" rel="noopener" style="color:var(--pink)">@586mnjoc</a>）までお問い合わせください。</div>
          <button class="btn btn-ghost" style="margin-top:16px" onclick="setLegalLang('ko')">韓国語版を見る</button>
        </div>`;
    } else {
      body.innerHTML = `<div style="padding:40px 16px;text-align:center;color:var(--muted)">문서를 불러올 수 없습니다.</div>`;
    }
  }
}
