// 배송 리스트 엑셀 — 브랜드·관리자 공용 순수 함수(화면·전역 상태·바로 실행되는 줄 없음)
//   브랜드 빌드(brand-shipping-excel.js 앞) · 관리자 빌드(admin-shipping-excel.js 앞) 둘 다 싣는다
//   🔴 빌드가 이어붙이기라 전역이 하나다 — 이 파일의 최상위 이름은 모두 SHIPXL_ / shipXl 머리말(겹치면 그 앱 전체가 문법 오류로 안 뜬다)
//   🔴 송장 형식 정규식·ExcelJS 로더·이름 표시는 받는 쪽이 넘긴다(사본을 더 만들지 않는다)
//   🔴 파일·칸 값을 콘솔·오류 기록에 싣지 않는다(결정 3 — 관리자 앱은 오류 수집이 붙어 있다)
//   작업표 docs/specs/2026-10-19-brand-seeding-shipping-list-breakdown.md 조각 S6 · 결정 D1·D3·D7·D8·D21

const SHIPXL_MAX_BYTES = 5 * 1024 * 1024;   // D7
const SHIPXL_MAX_ROWS = 2000;               // D7 — 서버 저장 함수 상한과 같다
const SHIPXL_OTHER_LABEL = '기타';
// D3 열 순서·머리글 이름 단일 소스 — key 는 올리기에서 찾는 칸. 내려받기·올리기가 같은 목록을 쓴다
//   pii: 우편번호·주소·전화 — 관리자 「송장 양식」에는 넣지 않는다
const SHIPXL_HEADS = [
  { key: 'row_no', label: '줄 번호', w: 9 },
  { key: 'name', label: '이름(한자)', w: 16 },
  { key: 'kana', label: '이름(가나)', w: 18 },
  { key: 'zip', label: '우편번호', w: 11, text: true, pii: true },
  { key: 'addr', label: '주소', w: 44, pii: true },
  { key: 'phone', label: '전화번호', w: 16, text: true, pii: true },
  { key: 'status', label: '상태', w: 16 },
  { key: 'carrier', label: '택배사', w: 16 },
  { key: 'other', label: '택배사 이름(기타일 때)', w: 22 },
  { key: 'tracking', label: '송장번호', w: 22, text: true },
  { key: 'shipped_on', label: '발송일', w: 12, text: true }
];
// 파일 읽기 오류 코드 → 받는 쪽이 문구로 바꾼다
//   not_xlsx · too_big · too_many · read_fail · no_head · no_notice · other_campaign

function shipXlStatusText(r) {
  if (r.status === 'shipped') return '발송함';
  if (r.status === 'overdue') return '발송 전 · 기한 지남';
  if (r.status === 'cancelled') return '취소됨';
  return '발송 전';
}
// 내려받기 「택배사」 두 칸 — 목록에 있는 택배사는 이름, 「기타」 직접 입력·목록에서 꺼진 택배사는 「기타」 + 이름(결정 8 — 그대로 다시 올려도 반영되게)
function shipXlCarrierCells(r) {
  if (r.carrier_code && r.carrier_active !== false) return [r.carrier_name || '', ''];
  const name = r.carrier_code ? (r.carrier_name || '') : (r.carrier_other || '');
  return name ? [SHIPXL_OTHER_LABEL, name] : ['', ''];
}
// 글자 비교용 — 전각·반각·띄어쓰기·대소문자 차이를 없앤다
function shipXlNorm(s) { return String(s == null ? '' : s).normalize('NFKC').replace(/\s+/g, '').toLowerCase(); }
function shipXlPad2(n) { return String(n).padStart(2, '0'); }
function shipXlDateYmd(dt) {   // 엑셀 날짜 칸은 그날 0시(UTC)로 읽힌다
  return dt.getUTCFullYear() + '-' + shipXlPad2(dt.getUTCMonth() + 1) + '-' + shipXlPad2(dt.getUTCDate());
}
// 칸 값 → 글자
function shipXlCellText(v) {
  if (v === null || v === undefined) return '';
  if (v instanceof Date) return shipXlDateYmd(v);
  if (typeof v === 'number') return Number.isInteger(v) ? v.toLocaleString('en-US', { useGrouping: false, maximumFractionDigits: 0 }) : String(v);
  if (typeof v === 'object') {
    if (Array.isArray(v.richText)) return v.richText.map(t => t.text || '').join('');
    if ('result' in v) return shipXlCellText(v.result);   // 수식 칸 — 계산된 값
    if ('text' in v) return shipXlCellText(v.text);       // 링크 칸
    return '';
  }
  return String(v);
}
// 발송일 칸 → 'YYYY-MM-DD' | '' (빈칸) | null (형식 오류)
function shipXlParseDate(v) {
  if (v === null || v === undefined || v === '') return '';
  if (v && typeof v === 'object' && !(v instanceof Date) && 'result' in v) return shipXlParseDate(v.result);
  if (v instanceof Date) {
    if (isNaN(v.getTime())) return null;
    return shipXlDateYmd(v);
  }
  if (typeof v === 'number') {   // 날짜 일련번호(1900 기준)
    if (v < 20000 || v > 80000) return null;
    return shipXlDateYmd(new Date(Math.round((v - 25569) * 86400000)));
  }
  const s = shipXlCellText(v).normalize('NFKC').trim();
  if (!s) return '';
  const mt = s.match(/^(\d{4})\s*[-\/.年]\s*(\d{1,2})\s*[-\/.月]\s*(\d{1,2})\s*日?$/);
  if (!mt) return null;
  const y = Number(mt[1]), m = Number(mt[2]), d = Number(mt[3]);
  const chk = new Date(Date.UTC(y, m - 1, d));
  if (chk.getUTCFullYear() !== y || chk.getUTCMonth() !== m - 1 || chk.getUTCDate() !== d) return null;
  return shipXlDateYmd(chk);
}
// 맨 위 안내 줄 — 올리기는 이 「캠페인 번호」로 다른 캠페인 파일을 거른다(D21). 🔴 문장을 바꾸면 shipXlReadFile 의 정규식도 본다
function shipXlNoticeText(campaignNo, forAdmin) {
  if (forAdmin) {
    return '캠페인 번호 ' + campaignNo + ' · 운영팀 송장 입력용 양식입니다(우편번호·주소·전화번호는 넣지 않았습니다). ' +
      '송장을 올릴 때는 이 줄과 「줄 번호」 칸을 지우거나 고치지 마십시오.';
  }
  return '캠페인 번호 ' + campaignNo + ' · 이 파일의 이름·주소·전화번호는 제품 배송에만 쓰고, 배송이 끝나면 이 파일을 지워 주십시오(이용약관 제8조). ' +
    '송장을 올릴 때는 이 줄과 「줄 번호」 칸을 지우거나 고치지 마십시오.';
}

// 파일 → { error:코드 } | { rows:[{ excelRow, rowNoText, carrier, other, tracking, date }] }
//   loadExcel: ExcelJS 를 불러오는 함수(Promise) — 각 앱 것
async function shipXlReadFile(file, campaignNo, loadExcel) {
  if (!/\.xlsx$/i.test(file.name || '')) return { error: 'not_xlsx' };
  if (file.size > SHIPXL_MAX_BYTES) return { error: 'too_big' };
  let wb;
  try {
    await loadExcel();
    wb = new ExcelJS.Workbook();
    await wb.xlsx.load(await file.arrayBuffer());
  } catch (e) { return { error: 'read_fail' }; }
  // 머리글 줄 찾기 — 첫 시트부터, 위쪽 10줄 안에서 「줄 번호」·「송장번호」가 함께 있는 줄
  //   (관리자 양식은 맨 위에 「사내용」 줄이 하나 더 붙어 머리글이 3행이다 — 그래도 찾는다)
  for (const ws of wb.worksheets) {
    let headRow = 0, cols = null;
    for (let i = 1; i <= Math.min(10, ws.rowCount); i++) {
      const map = {};
      ws.getRow(i).eachCell({ includeEmpty: false }, (cell, col) => {
        const h = shipXlNorm(shipXlCellText(cell.value));
        if (h === shipXlNorm('줄 번호')) map.row_no = map.row_no || col;
        else if (h === shipXlNorm('택배사')) map.carrier = map.carrier || col;
        else if (h.indexOf(shipXlNorm('택배사 이름')) === 0) map.other = map.other || col;
        else if (h === shipXlNorm('송장번호')) map.tracking = map.tracking || col;
        else if (h === shipXlNorm('발송일')) map.shipped_on = map.shipped_on || col;
      });
      if (map.row_no && map.tracking) { headRow = i; cols = map; break; }
    }
    if (!headRow) continue;
    if (!cols.carrier) return { error: 'no_head' };
    // 다른 캠페인 판별(D21) — 머리글 위 안내 줄의 캠페인 번호
    if (headRow < 2) return { error: 'no_notice' };
    let notice = '';
    for (let i = 1; i < headRow; i++) ws.getRow(i).eachCell({ includeEmpty: false }, cell => { notice += ' ' + shipXlCellText(cell.value); });
    const mt = notice.normalize('NFKC').match(/캠페인\s*번호\s*([A-Za-z0-9-]+)/);
    if (!mt) return { error: 'no_notice' };
    if (mt[1].toUpperCase() !== String(campaignNo).toUpperCase()) return { error: 'other_campaign' };
    const rows = [];
    for (let i = headRow + 1; i <= ws.rowCount; i++) {
      const row = ws.getRow(i);
      const raw = k => (cols[k] ? row.getCell(cols[k]).value : null);
      const rec = {
        excelRow: i,
        rowNoText: shipXlCellText(raw('row_no')).normalize('NFKC').trim(),
        carrier: shipXlCellText(raw('carrier')).normalize('NFKC').trim(),
        other: shipXlCellText(raw('other')).normalize('NFKC').trim(),
        tracking: shipXlCellText(raw('tracking')).normalize('NFKC').trim(),
        date: shipXlParseDate(raw('shipped_on'))
      };
      if (!rec.rowNoText && !rec.carrier && !rec.other && !rec.tracking && rec.date === '') continue;   // 빈 줄
      rows.push(rec);
      if (rows.length > SHIPXL_MAX_ROWS) return { error: 'too_many' };
    }
    return { rows };
  }
  return { error: 'no_head' };
}

// 파일 줄 × 새로 받은 리스트 → 미리 보기 분류
//   새로 등록(송장 없던 줄) · 바뀜(이전 번호) · 그대로 · 반영 안 됨 — 반영은 앞의 둘만
//   opts: { trackingRe(송장 형식 — 받는 쪽 사본), nameOf(줄 → 표시 이름) }
//   반영할 줄은 저장 값 대신 { rowNo, name, prev, tracking, carrierName, cur, save:{carrier_code, carrier_other, tracking_no, shipped_on} } —
//   줄 열쇠(브랜드 row_no / 관리자 application_id)와 버전은 받는 쪽이 cur 에서 붙인다
function shipXlPlan(fileRows, list, opts) {
  const nameOf = opts.nameOf;
  const byNo = new Map((Array.isArray(list.rows) ? list.rows : []).filter(r => r.row_no != null).map(r => [Number(r.row_no), r]));
  const carriers = Array.isArray(list.carriers) ? list.carriers : [];
  const plan = { add: [], change: [], same: [], skip: [] };
  const seen = new Set();
  const skip = (rec, cur, reason) => plan.skip.push({ rowNo: rec.rowNoText || '', excelRow: rec.excelRow, name: cur ? nameOf(cur) : '', reason });
  fileRows.forEach(rec => {
    if (!rec.rowNoText) { skip(rec, null, 'no_row'); return; }
    if (!/^\d{1,9}$/.test(rec.rowNoText)) { skip(rec, null, 'format_row'); return; }
    const no = Number(rec.rowNoText);
    if (seen.has(no)) { skip(rec, byNo.get(no), 'duplicate'); return; }
    seen.add(no);
    const cur = byNo.get(no);
    if (!cur) { skip(rec, null, 'no_row'); return; }
    const curTrack = cur.tracking_no || '';
    const curCarrierName = cur.carrier_name || cur.carrier_other || '';
    // 파일 택배사 → 저장할 값(목록 코드 또는 「기타」 이름) · 비교용 이름
    const isOther = shipXlNorm(rec.carrier) === shipXlNorm(SHIPXL_OTHER_LABEL);
    const fileCarrierName = isOther ? rec.other : rec.carrier;
    const hit = !isOther && rec.carrier ? carriers.find(c => shipXlNorm(c.name) === shipXlNorm(rec.carrier)) : null;
    // 1) 아무것도 없는 줄 — 그대로
    if (!rec.tracking && !curTrack && !fileCarrierName) { plan.same.push(no); return; }
    // 2) 송장·택배사가 지금과 같고 발송일이 비었거나 같다 — 그대로(꺼진 택배사·「기타」도 이름으로 비교 — 결정 8)
    if (rec.tracking && rec.tracking === curTrack && shipXlNorm(fileCarrierName) === shipXlNorm(curCarrierName) &&
        (rec.date === '' || rec.date === (cur.shipped_on ? String(cur.shipped_on).slice(0, 10) : ''))) { plan.same.push(no); return; }
    if (cur.status === 'cancelled') { skip(rec, cur, 'cancelled'); return; }
    if (!rec.tracking) { skip(rec, cur, curTrack ? 'blank' : 'no_tracking'); return; }        // D1 — 빈칸은 지우기가 아니다
    if (!opts.trackingRe.test(rec.tracking)) { skip(rec, cur, 'format_tracking'); return; }
    if (rec.date === null) { skip(rec, cur, 'format_date'); return; }
    if (!hit && !(isOther && rec.other && rec.other.length <= 50)) { skip(rec, cur, 'carrier'); return; }
    const item = {
      rowNo: no, name: nameOf(cur), prev: curTrack, tracking: rec.tracking,
      carrierName: hit ? hit.name : rec.other,
      cur: cur,   // 버전·줄 열쇠는 파일이 아니라 방금 받은 리스트의 이 줄에서
      save: {
        carrier_code: hit ? hit.code : null, carrier_other: hit ? null : rec.other,
        // 발송일 빈칸 — 「바뀜」은 지금 발송일을 그대로, 「새로 등록」은 서버가 오늘(일본 날짜)
        tracking_no: rec.tracking, shipped_on: rec.date || (curTrack && cur.shipped_on ? String(cur.shipped_on).slice(0, 10) : null)
      }
    };
    (curTrack ? plan.change : plan.add).push(item);
  });
  return plan;
}
