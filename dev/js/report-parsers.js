// ══════════════════════════════════════════════════════════════
// 리포트 외부 파일 파서 — 작업 14
//   사양서 : docs/specs/2026-09-03-campaign-report-builder.md 「외부 파일(포인테일) 실측 구조」
//   서비스가 늘어날 것을 전제로, 파일을 읽어 **같은 모양**으로 돌려주는 층.
//
// 산출 계약
//   REPORT_PARSERS[service](arrayBuffer) → { ok, reason, rows[], summary }
//   rows[] 한 원소의 칸 이름은 **`campaign_report_ext_rows`(409) 와 글자 그대로 같다** —
//   하나라도 어긋나면 서버 함수(410)가 그 칸을 조용히 NULL 로 넣는다(오류가 아니다).
//
// ⚠️ 이 파일 이름에 `admin` 이 없다 — `dev/build.sh` 의 목록과 정규식 **두 곳**에 넣었다.
//    (원본 HTML 은 페인 파일을 개별 <script> 로 부르지 않으므로 태그는 없다.)
// ══════════════════════════════════════════════════════════════

// 셀 값 정규화 — ExcelJS 는 셀 종류에 따라 문자열·숫자·{richText}·{text,hyperlink}·Date 를 준다.
function _rpCellText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'string') return v.trim();
  if (typeof v === 'number') return Number.isInteger(v) ? String(v) : String(v);
  if (v instanceof Date) return v.toISOString();
  if (typeof v === 'object') {
    if (Array.isArray(v.richText)) return v.richText.map(function(t){ return t.text || ''; }).join('').trim();
    if (v.text !== undefined) return _rpCellText(v.text);
    if (v.result !== undefined) return _rpCellText(v.result);   // 수식 셀
    if (v.hyperlink) return String(v.hyperlink).trim();
  }
  return String(v).trim();
}

// 「2026-08-12 10:03:42」 → ISO. ⚠️ 포인테일은 한국 서비스라 **한국 시각(+09:00)으로 본다.**
//   시간대를 안 붙이면 브라우저가 자기 시간대로 읽어 서버·화면이 9시간 어긋난다.
function _rpToIso(s) {
  s = _rpCellText(s);
  if (!s) return '';
  if (/^\d{4}-\d{2}-\d{2}T/.test(s)) return s;                       // 이미 ISO(Date 셀)
  const m = s.match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2})(?::(\d{2}))?)?$/);
  if (!m) return '';
  return `${m[1]}-${m[2]}-${m[3]}T${m[4]||'00'}:${m[5]||'00'}:${m[6]||'00'}+09:00`;
}

// 머리글 행을 **문구로** 찾는다 — 행 번호로 박지 않는다(1행이 비어 있고 머리글이 2행에 있다).
//   앞 10행 안에서 「회원번호」가 있는 첫 행.
function _rpFindHeader(ws) {
  const maxScan = Math.min(10, ws.rowCount);
  for (let r = 1; r <= maxScan; r++) {
    const vals = (ws.getRow(r).values || []).map(_rpCellText);
    const idx = vals.findIndex(function(v){ return v === '회원번호'; });
    if (idx !== -1) {
      const cols = {};
      vals.forEach(function(v, i){ if (v) cols[v] = i; });   // 머리글 → 열 번호(1-based, values[0] 은 비어 있다)
      return { rowNo: r, cols: cols };
    }
  }
  return null;
}

// 탭 하나를 {회원번호 → {열이름: 값}} 로 읽는다. 머리글이 없으면 null.
function _rpReadSheet(ws) {
  const h = _rpFindHeader(ws);
  if (!h) return null;
  const out = new Map();
  for (let r = h.rowNo + 1; r <= ws.rowCount; r++) {
    const row = ws.getRow(r);
    const get = function(name) { const c = h.cols[name]; return c ? _rpCellText(row.getCell(c).value) : ''; };
    const memberNo = get('회원번호');
    if (!memberNo) continue;                                   // 회원번호 없는 줄은 짝지을 수 없다
    out.set(memberNo, { get: get });
  }
  return out;
}

// 포인테일(스토어링크) 캠페인 리포트 엑셀
//   탭: 「구매하기」(필수) · 「텍스트 리뷰」 · 「포토 리뷰」 · 「@cosme 텍스트 리뷰」 · 「@cosme 포토 리뷰」(있으면)
//   ⚠️ 계정 열이 탭마다 다르다 — 큐텐 탭은 「채널 계정 ID(닉네임)」, @cosme 탭은 「미션 채널 계정 닉네임」.
//      @cosme 의 닉네임은 **이름 칸에 넣지 않는다**(이름이 아니라 닉네임이고 21명 중 17명만 있다).
async function parsePointailWorkbook(arrayBuffer) {
  await loadExcelJS();
  const wb = new ExcelJS.Workbook();
  try { await wb.xlsx.load(arrayBuffer); }
  catch (e) { return { ok:false, reason:'엑셀 파일로 읽을 수 없습니다 (.xlsx 인지 확인해 주세요)', rows:[], summary:null }; }

  const names = wb.worksheets.map(function(w){ return w.name; });
  const find = function(name) { return wb.getWorksheet(name) || null; };
  const wsBuy   = find('구매하기');
  const wsText  = find('텍스트 리뷰');
  const wsPhoto = find('포토 리뷰');
  const wsCText  = find('@cosme 텍스트 리뷰');
  const wsCPhoto = find('@cosme 포토 리뷰');

  // 🔴 예상한 탭이 하나도 없으면 **분명히 거부**한다 — 조용히 0행을 돌려주면
  //    「외부 인원 0명」이 진짜 0명인지 파싱 실패인지 아무도 모른다(사양서 ⑦).
  if (!wsBuy && !wsText && !wsPhoto) {
    return { ok:false, reason:'이 파일에서 「구매하기」·「텍스트 리뷰」·「포토 리뷰」 탭을 찾지 못했습니다 (있는 탭: ' + names.join(', ') + ')', rows:[], summary:null };
  }

  const buy   = wsBuy   ? _rpReadSheet(wsBuy)   : new Map();
  const text  = wsText  ? _rpReadSheet(wsText)  : new Map();
  const photo = wsPhoto ? _rpReadSheet(wsPhoto) : new Map();
  const ctext  = wsCText  ? _rpReadSheet(wsCText)  : new Map();
  const cphoto = wsCPhoto ? _rpReadSheet(wsCPhoto) : new Map();
  const missing = [['구매하기',wsBuy,buy],['텍스트 리뷰',wsText,text],['포토 리뷰',wsPhoto,photo]]
    .filter(function(x){ return x[1] && x[2] === null; }).map(function(x){ return x[0]; });
  if (missing.length) {
    return { ok:false, reason:'「' + missing.join('」·「') + '」 탭에서 「회원번호」 머리글을 찾지 못했습니다 (양식이 바뀌었을 수 있습니다)', rows:[], summary:null };
  }

  // 한 사람 = 한 행. 구매 탭을 바탕으로 리뷰 탭을 회원번호로 얹는다.
  //   ⚠️ 구매 탭에 없는 사람이 리뷰 탭에만 있으면 그 사람도 한 줄로 넣는다(빠뜨리면 리뷰가 사라진다).
  const members = new Set([...(buy||new Map()).keys(), ...(text||new Map()).keys(), ...(photo||new Map()).keys(),
                           ...(ctext||new Map()).keys(), ...(cphoto||new Map()).keys()]);
  const rows = [];
  let completed = 0;
  members.forEach(function(no) {
    const b = buy && buy.get(no);
    const t = text && text.get(no);
    const p = photo && photo.get(no);
    const ct = ctext && ctext.get(no);
    const cp = cphoto && cphoto.get(no);
    // 리뷰 종류 — 포토가 있으면 포토(A-2), 아니면 텍스트(A-1). 둘 다 없으면 NULL.
    const rv = p || t;
    const kind = p ? 'photo' : (t ? 'text' : '');
    const cv = cp || ct;
    const account = (b && b.get('채널 계정 ID(닉네임)')) || (rv && rv.get('채널 계정 ID(닉네임)')) || '';
    const status = b ? b.get('미션 상태') : '';
    if (status === '완료') completed++;
    rows.push({
      member_no:       no,
      account_id:      account,
      mission_status:  status,
      order_no:        b ? b.get('주문번호') : '',
      purchase_amount: b ? b.get('구매 가격') : '',
      receipt_url:     b ? b.get('인증 자료') : '',          // 여러 장이면 줄바꿈 그대로
      receipt_at:      b ? _rpToIso(b.get('미션 완료일')) : '',
      review_kind:     kind,
      qoo10_urls:      rv ? rv.get('증빙자료') : '',          // 리뷰 탭은 「증빙자료」, 구매 탭은 「인증 자료」 — 이름이 다르다
      qoo10_at:        rv ? _rpToIso(rv.get('미션 완료일')) : '',
      cosme_urls:      cv ? cv.get('증빙자료') : '',
      cosme_at:        cv ? _rpToIso(cv.get('미션 완료일')) : '',
    });
  });

  return {
    ok: true, reason: '',
    rows: rows,
    summary: {
      buyers:      buy ? buy.size : 0,
      reviewText:  text ? text.size : 0,
      reviewPhoto: photo ? photo.size : 0,
      cosme:       (ctext ? ctext.size : 0) + (cphoto ? cphoto.size : 0),
      completed:   completed,
      people:      rows.length,
      hasCosme:    !!(wsCText || wsCPhoto),
      maskedAccounts: rows.filter(function(r){ return /\*\*/.test(r.account_id || ''); }).length,  // 원본부터 가려진 계정
    }
  };
}

const REPORT_PARSERS = { pointail: parsePointailWorkbook };
const REPORT_SERVICES = [ { code:'pointail', label:'포인테일 (스토어링크)' } ];
