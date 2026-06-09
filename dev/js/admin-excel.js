// ═════════════════════════════════════════════════════════════════
// REVERB ADMIN — dev/js/admin-excel.js
// ═════════════════════════════════════════════════════════════════
//
// 엑셀 내보내기 공용 유틸 (admin.js 파일 분리).
//   · ExcelJS 지연 로드(loadExcelJS) + 이미지 임베드 + 셀 헬퍼(_excel*)
//   · 선택/쿨다운/락 (toggleCampSelect/_checkExportAllowed/_markExportStart 등)
//   · 4종 export (캠페인 신청자/결과물, 단일/다중 선택)
//   · 상태: _excelJsLoading/_selectedCampIds/_exportInProgress/_lastExportAt/EXPORT_COOLDOWN_MS
//
// ⚠ 캠페인 목록(admin.js 잔류)이 _selectedCampIds·toggleCampSelect·toggleCampSelectAll·
//   exportCampaignDeliverables 등을 onclick/참조 → 전역 유지(이름 변경 금지). 빌드 순서상 admin.js 앞.
// ═════════════════════════════════════════════════════════════════

// ══════════════════════════════════════
// 캠페인 결과물 엑셀 다운로드 (exceljs 지연 로드 + 이미지 임베드)
// ══════════════════════════════════════
var _excelJsLoading = null;
// ════════════════════════════════════════════════════════════════════
// SECTION: EXCEL — ExcelJS lazy-load + 4종 export (캠페인 신청자/결과물)
// ════════════════════════════════════════════════════════════════════

function loadExcelJS() {
  if (window.ExcelJS) return Promise.resolve();
  if (_excelJsLoading) return _excelJsLoading;
  _excelJsLoading = new Promise(function(resolve, reject) {
    var s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js';
    s.onload = function() { resolve(); };
    s.onerror = function() { reject(new Error('ExcelJS 로드 실패')); };
    document.head.appendChild(s);
  });
  return _excelJsLoading;
}

// Supabase Storage 이미지를 Image→Canvas를 거쳐 jpeg ArrayBuffer로 변환
// fetch 기반보다 CORS·binary 안정성이 좋고 webp 등 예외 포맷도 jpeg로 통일
function imgToJpegArrayBuffer(url, maxW, maxH) {
  return new Promise(function(resolve, reject) {
    var img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = function() {
      try {
        var ratio = Math.min((maxW || 800) / img.width, (maxH || 800) / img.height, 1);
        var w = Math.max(1, Math.round(img.width * ratio));
        var h = Math.max(1, Math.round(img.height * ratio));
        var canvas = document.createElement('canvas');
        canvas.width = w;
        canvas.height = h;
        var ctx = canvas.getContext('2d');
        ctx.fillStyle = '#ffffff';
        ctx.fillRect(0, 0, w, h);
        ctx.drawImage(img, 0, 0, w, h);
        canvas.toBlob(function(blob) {
          if (!blob) { reject(new Error('canvas toBlob returned null')); return; }
          blob.arrayBuffer().then(function(buf) {
            resolve({buffer: buf, ext: 'jpeg'});
          }).catch(reject);
        }, 'image/jpeg', 0.85);
      } catch(e) { reject(e); }
    };
    img.onerror = function() { reject(new Error('image load failed: ' + url)); };
    img.src = url;
  });
}

// ─── 엑셀 export 공용 헬퍼 ─────────────────────────────────────────
// 인플루언서 이름 — 한자/가나 별도 컬럼용 (사용자 요청 형식)
function _excelInfluencerNameParts(u) {
  if (!u) return {kanji: '', kana: ''};
  return {
    kanji: (u.name_kanji || '').trim(),
    kana:  (u.name_kana || u.name || '').trim()
  };
}

// SNS 핸들 → 전체 URL 변환 (각 SNS 공식 URL 형식 유지). TikTok/YouTube 는 @ 필수
function _excelSnsUrl(channel, raw) {
  if (!raw) return '';
  var handle = (typeof extractSnsHandle === 'function') ? extractSnsHandle(channel, raw) : String(raw).replace(/^@/, '').trim();
  if (!handle) return '';
  switch (channel) {
    case 'instagram': return 'https://www.instagram.com/' + handle + '/';
    case 'tiktok':    return 'https://www.tiktok.com/@' + handle;
    case 'x':         return 'https://x.com/' + handle;
    case 'youtube':   return 'https://www.youtube.com/@' + handle;
    default: return handle;
  }
}

// 우편번호 (별도 컬럼용). 〒 prefix 제거, 하이픈 유지
function _excelZip(u) {
  if (!u || !u.zip) return '';
  return String(u.zip).replace(/^〒\s*/, '').trim();
}

// 주소 본문 (우편번호 제외). 도도부현 + 시군구 + 건물
function _excelAddressOnly(u, fallback) {
  if (u && (u.prefecture || u.city || u.building)) {
    return (u.prefecture || '') + (u.city || '') + (u.building ? ' ' + u.building : '');
  }
  return fallback || '';
}

// ─── 인증 상태 판정 (엑셀 빌더 전용) ────────────────────────────────
// admin-deliverables.js 의 computeCertStatus(g) 와 동일 규칙이지만, 엑셀 빌더는
// 자체 그룹 구조(g.receipt / g.result / g.reviewByCh)를 쓰므로 그 구조에 맞춰 재현한다.
//   - 인증성공: (monitor) 영수증 승인 + 채널별 review_image 대표 상태 approved
//               (gifting/visit) 게시물(post) 승인
//   - 미제출: (monitor) 영수증·review_image 둘 다 전혀 없음 / (gifting/visit) 게시물 없음
//   - 인증샷 제출중: 그 외 전부

// monitor 채널별 review_image 상태 집합 → 대표 상태 repr (admin-deliverables 와 동일 우선순위)
//   campChannels: 캠페인 채널 코드 배열, reviewByCh: { channelCode: deliv }
function _excelMonitorResultRepr(campChannels, reviewByCh) {
  reviewByCh = reviewByCh || {};
  var channels = (campChannels || []).filter(Boolean);
  if (channels.length === 0) {
    // 채널 미등록 monitor — review_image 행이 하나라도 있으면 제출중, 없으면 none
    return Object.keys(reviewByCh).length > 0 ? 'pending' : 'none';
  }
  var states = channels.map(function(ch) { return (reviewByCh[ch] && reviewByCh[ch].status) || 'none'; });
  if (states.indexOf('rejected') !== -1) return 'rejected';
  if (states.indexOf('pending') !== -1) return 'pending';
  if (states.indexOf('none') !== -1) return 'none';
  return 'approved';
}

// gifting/visit (post 단독) 또는 채널 없는 monitor(receipt + 단일 result) 구조용.
//   recruitType, receipt(receipt deliv), result(post/review_image deliv)
function _excelCertStatusKo(recruitType, receipt, result) {
  if (recruitType === 'monitor') {
    var hasReceipt = !!receipt;
    var hasReview = !!result;
    if (!hasReceipt && !hasReview) return '미제출';
    if (receipt && receipt.status === 'approved' && result && result.status === 'approved') return '인증성공';
    return '인증샷 제출중';
  }
  // gifting / visit — 게시물(post) 단독
  if (!result) return '미제출';
  if (result.status === 'approved') return '인증성공';
  return '인증샷 제출중';
}

// monitor 다채널 구조용 (receipt + reviewByCh).
function _excelCertStatusMonitorKo(campChannels, receipt, reviewByCh) {
  var hasReceipt = !!receipt;
  var hasReview = reviewByCh && Object.keys(reviewByCh).length > 0;
  if (!hasReceipt && !hasReview) return '미제출';
  var repr = _excelMonitorResultRepr(campChannels, reviewByCh);
  if (receipt && receipt.status === 'approved' && repr === 'approved') return '인증성공';
  return '인증샷 제출중';
}

// ─── 캠페인 다중 선택 + 통합 엑셀 ────────────────────────────────────
// _selectedCampIds: 사용자가 체크한 캠페인 id 집합. 페인 이동/새로고침 시 초기화.
// 필터·정렬·lazy-load remount 와 무관하게 Set 기반 절대 선택 유지.
var _selectedCampIds = new Set();

// 다운로드 쿨다운 가드 — 단시간 다중 클릭 방지
var _exportInProgress = false;
var _lastExportAt = 0;
var EXPORT_COOLDOWN_MS = 5000;

function _checkExportAllowed() {
  if (_exportInProgress) {
    toast('다운로드가 진행 중입니다. 잠시 기다려주세요.', 'warn');
    return false;
  }
  var now = Date.now();
  var elapsed = now - _lastExportAt;
  if (elapsed < EXPORT_COOLDOWN_MS) {
    var wait = Math.ceil((EXPORT_COOLDOWN_MS - elapsed) / 1000);
    toast(wait + '초 후 다시 시도해주세요', 'warn');
    return false;
  }
  return true;
}

function _markExportStart() { _exportInProgress = true; }
function _markExportEnd() { _exportInProgress = false; _lastExportAt = Date.now(); }

function toggleCampSelect(campId, checked) {
  if (checked) _selectedCampIds.add(campId);
  else _selectedCampIds.delete(campId);
  updateCampSelectionUI();
}

function toggleCampSelectAll(checked) {
  // 필터 결과 전체 — getCurrentFilteredCamps() 반환을 우선, 없으면 캠페인 전체 캐시
  var filtered = (typeof getCurrentFilteredCamps === 'function') ? getCurrentFilteredCamps() : null;
  if (!filtered) filtered = (Array.isArray(allCampaigns) ? allCampaigns : []);
  if (checked) {
    filtered.forEach(function(c) { _selectedCampIds.add(c.id); });
  } else {
    filtered.forEach(function(c) { _selectedCampIds.delete(c.id); });
  }
  // DOM 행의 체크박스도 동기 (현재 렌더된 행만)
  document.querySelectorAll('.camp-select-cb').forEach(function(cb) {
    var id = cb.dataset.campId;
    cb.checked = _selectedCampIds.has(id);
  });
  updateCampSelectionUI();
}

function clearCampSelection() {
  _selectedCampIds.clear();
  document.querySelectorAll('.camp-select-cb').forEach(function(cb) { cb.checked = false; });
  var sa = document.getElementById('campSelectAll');
  if (sa) { sa.checked = false; sa.indeterminate = false; }
  updateCampSelectionUI();
}

function updateCampSelectionUI() {
  var n = _selectedCampIds.size;
  var btnApp = document.getElementById('btnCampSelectApplicants');
  var btnDel = document.getElementById('btnCampSelectDeliverables');
  var btnClr = document.getElementById('btnCampSelectClear');
  var cntEl = document.getElementById('adminCampSelectedCount');
  if (btnApp) {
    btnApp.disabled = (n === 0);
    btnApp.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">download</span> ' + (n > 0 ? '선택 ' + n + '개 ' : '') + '신청자 엑셀';
  }
  if (btnDel) {
    btnDel.disabled = (n === 0);
    btnDel.innerHTML = '<span class="material-icons-round notranslate" translate="no" style="font-size:14px;vertical-align:middle">download</span> ' + (n > 0 ? '선택 ' + n + '개 ' : '') + '결과물 엑셀';
  }
  if (btnClr) btnClr.style.display = n > 0 ? '' : 'none';
  if (cntEl) {
    if (n > 0) { cntEl.textContent = '· ' + n + '개 선택'; cntEl.style.display = ''; }
    else { cntEl.textContent = ''; cntEl.style.display = 'none'; }
  }
  // 전체 선택 체크박스 indeterminate
  var sa = document.getElementById('campSelectAll');
  if (sa) {
    var filtered = (typeof getCurrentFilteredCamps === 'function') ? getCurrentFilteredCamps() : null;
    if (!filtered) filtered = (Array.isArray(allCampaigns) ? allCampaigns : []);
    var total = filtered.length;
    var selectedInFiltered = filtered.filter(function(c) { return _selectedCampIds.has(c.id); }).length;
    sa.checked = (total > 0 && selectedInFiltered === total);
    sa.indeterminate = (selectedInFiltered > 0 && selectedInFiltered < total);
  }
}

// 시트1 헬퍼: 선택한 캠페인 N개 요약 행
//   appsByCampId: {campaignId: appsArray} — 시트2 export 시 이미 fetch한 결과 재사용 (round-trip 절약)
function _buildCampaignSummarySheet(wb, campaigns, appsByCampId) {
  var ws = wb.addWorksheet('캠페인 정보');
  ws.columns = [
    { header: '캠페인 번호',     key: 'no',       width: 18 },
    { header: '제목',            key: 'title',    width: 36 },
    { header: '브랜드',          key: 'brand',    width: 18 },
    { header: '제품',            key: 'product',  width: 22 },
    { header: '모집 타입',       key: 'rtype',    width: 10 },
    { header: '상태',            key: 'status',   width: 10 },
    { header: '모집 시작',       key: 'rstart',   width: 14 },
    { header: '모집 마감',       key: 'deadline', width: 14 },
    // 2026-05-15 추가: 운영자가 캠페인 일정 한 번에 보기용 기간 3종.
    //   monitor 캠페인은 purchase_start/end, visit 캠페인은 visit_start/end 를 같은 컬럼에 매핑.
    //   gifting 캠페인은 구매·방문 개념이 없어 빈칸.
    //   2026-05-18: 게시 마감/노출 마감 컬럼 제거 (post_deadline 폐기 — migration 129)
    { header: '구매기간 시작',   key: 'pstart',   width: 14 },
    { header: '구매기간 마감',   key: 'pend',     width: 14 },
    { header: '결과물 제출 마감',key: 'subend',   width: 16 },
    { header: '슬롯',            key: 'slots',    width: 8 },
    { header: '신청 수',         key: 'apps',     width: 10 },
    { header: '승인 수',         key: 'approved', width: 10 }
  ];
  var header = ws.getRow(1);
  header.font = { bold: true, color: { argb: 'FF222222' } };
  header.alignment = { vertical: 'middle', horizontal: 'center' };
  header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
  header.height = 22;
  var rtypeLabel = function(t) { return t === 'monitor' ? '리뷰어' : t === 'gifting' ? '기프팅' : t === 'visit' ? '방문형' : (t || ''); };
  var statusKo = function(s) { return s === 'draft' ? '준비' : s === 'scheduled' ? '모집예정' : s === 'active' ? '모집중' : s === 'closed' ? '모집마감' : s === 'ended' ? '종료' : s === 'expired' ? '노출종료' : (s || ''); };
  // 캠페인 종류별 구매·방문 기간 매핑 (monitor=purchase_*, visit=visit_*, gifting=빈칸)
  var pickPurchStart = function(c) {
    if (c.recruit_type === 'monitor') return c.purchase_start || '';
    if (c.recruit_type === 'visit')   return c.visit_start || '';
    return '';
  };
  var pickPurchEnd = function(c) {
    if (c.recruit_type === 'monitor') return c.purchase_end || '';
    if (c.recruit_type === 'visit')   return c.visit_end || '';
    return '';
  };
  campaigns.forEach(function(c) {
    var campApps = (appsByCampId && appsByCampId[c.id]) || [];
    var approvedCnt = campApps.filter(function(a){ return a.status === 'approved'; }).length;
    var ps = pickPurchStart(c);
    var pe = pickPurchEnd(c);
    ws.addRow({
      no:       c.campaign_no || '',
      title:    c.title || '',
      brand:    brandLabelAdmin(c) || '',
      product:  c.product_ko || c.product || '',
      rtype:    rtypeLabel(c.recruit_type),
      status:   statusKo(c.status),
      rstart:   c.recruit_start ? formatDate(c.recruit_start) : '',
      deadline: c.deadline ? formatDate(c.deadline) : '',
      pstart:   ps ? formatDate(ps) : '',
      pend:     pe ? formatDate(pe) : '',
      subend:   c.submission_end ? formatDate(c.submission_end) : '',
      slots:    Number(c.slots || 0),
      apps:     campApps.length,
      approved: approvedCnt
    });
  });
  return ws;
}

// 50개 이상 경고 모달
function _confirmLargeExport(n) {
  if (n < 50) return Promise.resolve(true);
  return new Promise(function(resolve) {
    var ok = confirm(n + '개 캠페인 선택했습니다.\n엑셀 생성에 수십 초~수 분 걸릴 수 있습니다.\n\n계속할까요?');
    resolve(!!ok);
  });
}

// 캠페인 다중 선택 신청자 엑셀 — 시트1 캠페인 정보 + 시트2 통합 신청자 리스트
//   idsOverride: 인자로 직접 ids 배열 받기 가능 (단일 캠페인 더보기 메뉴 호출용)
async function exportSelectedCampaignsApplicants(idsOverride) {
  if (!_checkExportAllowed()) return;
  var ids = (Array.isArray(idsOverride) && idsOverride.length > 0) ? idsOverride : Array.from(_selectedCampIds);
  if (ids.length === 0) { toast('캠페인을 1개 이상 선택하세요', 'warn'); return; }
  if (!(await _confirmLargeExport(ids.length))) return;

  _markExportStart();
  try {
    toast('엑셀 생성 중...');
    await loadExcelJS();
    var camps = (Array.isArray(allCampaigns) ? allCampaigns : []).filter(function(c){ return ids.indexOf(c.id) !== -1; });
    if (camps.length === 0) { toast('선택한 캠페인을 찾을 수 없습니다', 'error'); return; }
    // 모든 캠페인의 신청자 + 인플루언서 한 번에 fetch
    await ensureCancelReasonsCache();
    var users = await fetchInfluencers();
    var userByEmail = {};
    (users || []).forEach(function(u){ if (u.email) userByEmail[u.email] = u; });
    // 신청자: 캠페인별로 fetch (서버 round-trip) — appsByCampId 캐시도 동시 빌드
    var allCampApps = [];
    var appsByCampId = {};
    for (var i = 0; i < camps.length; i++) {
      var c = camps[i];
      var apps = await fetchApplications({ campaign_id: c.id });
      appsByCampId[c.id] = apps || [];
      (apps || []).forEach(function(a){ a._campMeta = c; allCampApps.push(a); });
    }

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    _buildCampaignSummarySheet(wb, camps, appsByCampId);

    var ws = wb.addWorksheet('신청자');
    ws.columns = [
      { header: '캠페인 번호',   key: 'campNo',     width: 16 },
      { header: '캠페인 제목',   key: 'campTitle',  width: 28 },
      { header: '신청일',        key: 'created',    width: 20 },
      { header: '상태',          key: 'status',     width: 10 },
      { header: '이름(한자)',    key: 'nameKanji',  width: 16 },
      { header: '이름(가나)',    key: 'nameKana',   width: 16 },
      { header: '이메일',        key: 'email',      width: 26 },
      { header: '연락처',        key: 'phone',      width: 16 },
      { header: 'Instagram URL', key: 'ig',         width: 36 },
      { header: 'Instagram 팔로워', key: 'igF',     width: 14 },
      { header: 'TikTok URL',    key: 'tt',         width: 36 },
      { header: 'TikTok 팔로워', key: 'ttF',        width: 14 },
      { header: 'X URL',         key: 'x',          width: 36 },
      { header: 'X 팔로워',      key: 'xF',         width: 14 },
      { header: 'YouTube URL',   key: 'yt',         width: 36 },
      { header: 'YouTube 팔로워',key: 'ytF',        width: 14 },
      { header: '우편번호',      key: 'zip',        width: 10 },
      { header: '배송지',        key: 'address',    width: 36 },
      { header: '신청 메시지',   key: 'message',    width: 32 },
      { header: '심사일',        key: 'reviewedAt', width: 20 },
      { header: '리뷰어',        key: 'reviewedBy', width: 14 },
      { header: '취소일',        key: 'cancelledAt',width: 20 },
      { header: '취소 사유',     key: 'cancelReason',width: 24 },
      { header: '취소 카테고리', key: 'cancelCategory', width: 18 },
      { header: '취소 시점',     key: 'cancelPhase', width: 12 }
    ];
    var hdr = ws.getRow(1);
    hdr.font = { bold: true, color: { argb: 'FF222222' } };
    hdr.alignment = { vertical: 'middle', horizontal: 'center' };
    hdr.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    hdr.height = 22;

    var statusKo = function(s) { return s === 'approved' ? '승인' : s === 'pending' ? '심사중' : s === 'rejected' ? '미승인' : s === 'cancelled' ? '취소' : (s || ''); };
    var fmtKR = function(iso) { if (!iso) return ''; try { return new Date(iso).toLocaleString('ko-KR', {timeZone:'Asia/Seoul'}); } catch(e) { return String(iso); } };

    allCampApps.forEach(function(a) {
      var u = userByEmail[a.user_email] || {};
      var c = a._campMeta || {};
      var nm = _excelInfluencerNameParts(u);
      ws.addRow({
        campNo:        c.campaign_no || '',
        campTitle:     c.title || '',
        created:       fmtKR(a.created_at),
        status:        statusKo(a.status),
        nameKanji:     nm.kanji || a.user_name || '',
        nameKana:      nm.kana || '',
        email:         a.user_email || '',
        phone:         formatPhoneDisplay(u.phone),
        ig:            _excelSnsUrl('instagram', u.ig || a.ig_id || a.user_ig),
        igF:           Number(u.ig_followers || 0),
        tt:            _excelSnsUrl('tiktok', u.tiktok),
        ttF:           Number(u.tiktok_followers || 0),
        x:             _excelSnsUrl('x', u.x),
        xF:            Number(u.x_followers || 0),
        yt:            _excelSnsUrl('youtube', u.youtube),
        ytF:           Number(u.youtube_followers || 0),
        zip:           _excelZip(u),
        address:       _excelAddressOnly(u, a.address),
        message:       a.message || '',
        reviewedAt:    fmtKR(a.reviewed_at),
        reviewedBy:    formatReviewer(a.reviewed_by),
        cancelledAt:   fmtKR(a.cancelled_at),
        cancelReason:  a.cancel_reason || '',
        cancelCategory:a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : '',
        cancelPhase:   a.cancel_phase ? cancelPhaseLabelKo(a.cancel_phase) : ''
      });
    });
    ['igF','ttF','xF','ytF'].forEach(function(k) {
      ws.getColumn(k).numFmt = '#,##0';
      ws.getColumn(k).alignment = { horizontal: 'right' };
    });
    ws.getColumn('message').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('address').alignment = { wrapText: true, vertical: 'top' };

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var aEl = document.createElement('a');
    aEl.href = url;
    var ts = new Date();
    var ymd = ts.getFullYear() + String(ts.getMonth()+1).padStart(2,'0') + String(ts.getDate()).padStart(2,'0');
    aEl.download = 'applicants-' + camps.length + 'campaigns-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + camps.length + '개 캠페인, ' + allCampApps.length + '건 신청)');
  } catch (e) {
    console.error('[exportSelectedCampaignsApplicants]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}

// 캠페인 다중 선택 결과물 엑셀 — 시트1 캠페인 정보 + 시트2 통합 결과물 리스트 (이미지 임베드 생략, URL만)
//   idsOverride: 인자로 직접 ids 배열 받기 가능 (단일 캠페인 더보기 메뉴 호출용)
async function exportSelectedCampaignsDeliverables(idsOverride) {
  if (!_checkExportAllowed()) return;
  var ids = (Array.isArray(idsOverride) && idsOverride.length > 0) ? idsOverride : Array.from(_selectedCampIds);
  if (ids.length === 0) { toast('캠페인을 1개 이상 선택하세요', 'warn'); return; }
  if (!(await _confirmLargeExport(ids.length))) return;

  _markExportStart();
  try {
    toast('엑셀 생성 중...');
    await loadExcelJS();
    var camps = (Array.isArray(allCampaigns) ? allCampaigns : []).filter(function(c){ return ids.indexOf(c.id) !== -1; });
    if (camps.length === 0) { toast('선택한 캠페인을 찾을 수 없습니다', 'error'); return; }

    var users = await fetchInfluencers();
    // 시트1 캠페인 요약 「신청 수」 컬럼을 채우기 위해 신청 전체 fetch 1회 + groupBy
    var allAppsForSummary = await fetchApplications();
    var appsByCampId = {};
    (allAppsForSummary || []).forEach(function(a){
      if (!appsByCampId[a.campaign_id]) appsByCampId[a.campaign_id] = [];
      appsByCampId[a.campaign_id].push(a);
    });
    // 결과물 fetch (전체 상태) + 이미지 다운로드
    var allDelivs = [];
    for (var i = 0; i < camps.length; i++) {
      var c = camps[i];
      var dels = await fetchDeliverables({ campaign_id: c.id });
      (dels || []).forEach(function(d){ d._campMeta = c; allDelivs.push(d); });
    }
    if (allDelivs.length === 0) { toast('결과물이 없습니다', 'warn'); return; }

    // 인플루언서 id 매핑 (단일 함수와 동일 패턴)
    var usersById = {};
    (users || []).forEach(function(u){ if (u && u.id) usersById[u.id] = u; });

    // 영수증·리뷰 이미지 Image→Canvas→JPEG 재인코딩 (CORS·포맷 호환성)
    var imgBuffers = {};
    await Promise.all(allDelivs.filter(function(d){
      return (d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url;
    }).map(async function(d) {
      try {
        var url = d.receipt_url;
        if (url && !/^https?:\/\//.test(url) && db?.storage) {
          var sig = await db?.storage?.from('campaign-images').createSignedUrl(url, 3600);
          url = sig?.data?.signedUrl;
        }
        if (!url) return;
        var result = await imgToJpegArrayBuffer(url, 400, 400);
        if (result && result.buffer && result.buffer.byteLength > 0) {
          imgBuffers[d.id] = result;
        }
      } catch(e) { console.warn('[excel] receipt fetch failed', d.id, e); }
    }));

    // application_id 단위 그룹핑 (캠페인 정보 보존). 동일 신청 receipt + result 한 행에 펼침
    var groups = {};
    allDelivs.forEach(function(d) {
      var ck = (d._campMeta && d._campMeta.id) || '';
      var key = ck + '|' + (d.application_id || ('user-' + d.user_id));
      if (!groups[key]) {
        groups[key] = { key: key, camp: d._campMeta || {}, application_id: d.application_id, user_id: d.user_id, receipt: null, result: null };
      }
      var g = groups[key];
      if (d.kind === 'receipt') {
        if (!g.receipt || (d.updated_at || '') > (g.receipt.updated_at || '')) g.receipt = d;
      } else if (d.kind === 'review_image' || d.kind === 'post') {
        if (!g.result || (d.updated_at || '') > (g.result.updated_at || '')) g.result = d;
      }
    });
    var groupList = Object.values(groups);
    // 정렬: 캠페인 번호 → 인플루언서 한자 이름
    groupList.sort(function(a, b) {
      var ca = (a.camp.campaign_no || '').toString();
      var cb = (b.camp.campaign_no || '').toString();
      if (ca !== cb) return ca.localeCompare(cb, 'ja');
      var ua = usersById[a.user_id] || {};
      var ub = usersById[b.user_id] || {};
      var na = (ua.name_kanji || ua.name || '').toString();
      var nb = (ub.name_kanji || ub.name || '').toString();
      return na.localeCompare(nb, 'ja');
    });

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();

    // 시트1 캠페인 정보 (기존 유지)
    _buildCampaignSummarySheet(wb, camps, appsByCampId);

    // ── monitor(리뷰어) 캠페인 전체를 단일 「리뷰어 결과물」 시트로 통합 (2026-06-08)
    //   이전: 채널 조합별로 시트(탭) 분리 → 모집 타입이 같은 리뷰어인데도 큐텐/엣코스메가 탭마다 갈려
    //         인플루언서·영수증 정보 양식이 반복돼 취합 불편(사용자 지적).
    //   변경: 모집 타입이 같은(monitor) 캠페인은 채널이 달라도 한 시트에. 채널은 전체 합집합으로 가로 펼침
    //         (1명 1줄, 본인이 낸 채널 칸만 채우고 안 낸 채널은 빈칸 — 영수증·인플 정보 1회만 표시).
    //   비monitor(기프팅·방문형)·채널 없는 monitor 캠페인은 아래 통합 「결과물」 시트로 폴백.
    try { await fetchLookups('channel'); } catch(e) { /* 라벨 폴백 OK */ }
    var monitorCovered = {};     // 리뷰어 시트로 처리된 캠페인 id (통합 시트에서 제외 대상)
    var monitorChannelSet = {};  // 리뷰어 캠페인에 등장한 채널 코드 합집합
    camps.forEach(function(c) {
      if (c.recruit_type !== 'monitor') return;
      var chs = (c.channel || '').split(',').map(function(x){return x.trim();}).filter(Boolean);
      if (chs.length === 0) return;  // 채널 없는 리뷰어는 통합 시트로
      monitorCovered[c.id] = true;
      chs.forEach(function(ch){ monitorChannelSet[ch] = true; });
    });

    if (Object.keys(monitorCovered).length > 0) {
      var allChannels = Object.keys(monitorChannelSet).sort();  // 합집합 채널 (코드 정렬, 기존 패턴 유지)
      var monCamps = camps.filter(function(c){ return monitorCovered[c.id]; });
      var monDelivs = allDelivs.filter(function(d){ return monitorCovered[d.campaign_id]; });
      _buildMonitorGroupSheet(wb, '리뷰어 결과물', monCamps, allChannels, monDelivs, usersById, imgBuffers, '리뷰어 결과물 통합');
    }

    // 통합 시트는 monitor 그룹으로 처리된 캠페인 외 결과물만 (비monitor + monitor 채널 없음)
    groupList = groupList.filter(function(g) { return !(g.camp && monitorCovered[g.camp.id]); });
    var hasOtherCamps = groupList.length > 0;

    // 통합 시트 — monitor 그룹으로 처리되지 않은 결과물(비monitor + monitor 채널 없음)만 있을 때 생성.
    //   monitor 그룹만 있고 통합 대상이 없으면 빈 시트 생성하지 않음 (사용자 지적: '탭이 세개나 생겨').
    if (hasOtherCamps) {

    // 시트2 결과물 — 24컬럼 (캠페인 2 + 인플루언서 7 + 영수증 9 + 결과물 6)
    // 영수증 9컬럼: 타입 / 제출일 / 검수일 / 상태 / 주문번호 / 구매일 / 구매금액 / 이미지 / URL (마이그레이션 128)
    var ws = wb.addWorksheet('결과물');

    // 머리글 (A1:Y1, A2:Y2)
    ws.mergeCells('A1:Y1');
    var tCell = ws.getCell('A1');
    tCell.value = '선택한 ' + camps.length + '개 캠페인 결과물 통합';
    tCell.font = {bold: true, size: 14};
    tCell.alignment = {vertical: 'middle'};
    ws.getRow(1).height = 26;

    ws.mergeCells('A2:Y2');
    var mCell = ws.getCell('A2');
    mCell.value = '캠페인 수: ' + camps.length + '개'
      + '  ·  신청 건수: ' + groupList.length + '건'
      + '  ·  결과물 합계: ' + allDelivs.length + '건'
      + '  ·  생성일: ' + new Date().toLocaleString('ko-KR');
    mCell.font = {color: {argb: 'FF888888'}, size: 11};
    ws.getRow(2).height = 20;

    // 그룹 헤더 (3행) — 2026-06-09: 인증 상태를 인플루언서 정보 다음·영수증 앞으로 이동. 영수증·결과물 인덱스 +1 밀림.
    ws.mergeCells('A3:B3'); ws.getCell('A3').value = '캠페인';
    ws.mergeCells('C3:I3'); ws.getCell('C3').value = '인플루언서 정보';
    ws.getCell('J3').value = '인증 상태';
    ws.mergeCells('K3:S3'); ws.getCell('K3').value = '영수증';
    ws.mergeCells('T3:Y3'); ws.getCell('T3').value = '결과물';
    ['A3','C3','J3','K3','T3'].forEach(function(addr) {
      var c2 = ws.getCell(addr);
      c2.font = {bold: true, color: {argb: 'FF222222'}};
      c2.alignment = {vertical: 'middle', horizontal: 'center'};
      c2.fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFE8E8E8'}};
    });
    ws.getRow(3).height = 22;

    // 컬럼 헤더 (4행)
    ws.getRow(4).values = [
      '캠페인 번호', '캠페인 제목',
      '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
      '인증 상태',
      '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL',
      '타입', '제출일', '검수일', '상태', '이미지', 'URL'
    ];
    ws.getRow(4).font = {bold: true, color: {argb: 'FF222222'}};
    ws.getRow(4).fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFF0F0F0'}};
    ws.getRow(4).alignment = {vertical: 'middle', horizontal: 'center'};
    ws.getRow(4).height = 24;

    // 컬럼 너비 — 캠페인 2 / 인플 7 / 인증 상태 1 / 영수증 9 / 결과물 6
    ws.columns = [
      {width: 18}, {width: 28},
      {width: 18}, {width: 18}, {width: 28}, {width: 36}, {width: 36}, {width: 36}, {width: 36},
      {width: 14},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 18}, {width: 12}, {width: 12}, {width: 16}, {width: 32},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 16}, {width: 32}
    ];

    // 결과물 1건 → 6컬럼 값 (post / review_image)
    var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려', changed:'재제출요청'};
    var renderDeliverableCells = function(d) {
      if (!d) return ['', '', '', '', '', ''];
      var kindLabel = d.kind === 'receipt' ? '영수증'
        : d.kind === 'review_image' ? '리뷰 이미지'
        : '게시물';
      var submittedStr = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
      var reviewedStr = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
      var statusStr = statusLabelMap[d.status] || d.status || '';
      var urlCellValue = '';
      if (d.kind === 'post') {
        var postUrl = d.post_url || '';
        if (Array.isArray(d.post_submissions) && d.post_submissions.length) {
          var last = d.post_submissions[d.post_submissions.length - 1];
          postUrl = (last && last.url) || postUrl;
        }
        if (postUrl) urlCellValue = {text: postUrl, hyperlink: postUrl};
      } else if ((d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url) {
        var imgUrl = /^https?:\/\//.test(d.receipt_url)
          ? d.receipt_url
          : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
        urlCellValue = {text: imgUrl, hyperlink: imgUrl};
      }
      return [kindLabel, submittedStr, reviewedStr, statusStr, '', urlCellValue];
    };

    // 영수증(receipt) 전용 9컬럼 — 기본 4 + 주문번호·구매일·구매금액 + 이미지·URL (마이그레이션 128)
    var renderReceiptCells9 = function(d) {
      if (!d) return ['', '', '', '', '', '', '', '', ''];
      var base = renderDeliverableCells(d);  // [type, submitted, reviewed, status, '', url]
      var orderNo = d.order_number || '';
      var purchaseDate = d.purchase_date || '';
      var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
        ? '' : Number(d.purchase_amount);
      // 결과: [type, submitted, reviewed, status, order_no, purchase_date, purchase_amount, image, url]
      return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
    };

    // 본문 행 — 그룹 1개 = 1행
    groupList.forEach(function(g, idx) {
      var rowNum = 5 + idx;
      var u = usersById[g.user_id] || {};
      var cc = g.camp || {};
      var row = ws.getRow(rowNum);
      row.height = 84;
      var receiptCells = renderReceiptCells9(g.receipt);
      var resultCells = renderDeliverableCells(g.result);
      row.values = [
        cc.campaign_no || '', cc.title || '',
        u.name_kanji || u.name || '—',
        u.name_kana || '',
        u.email || '',
        _excelSnsUrl('instagram', u.ig),
        _excelSnsUrl('tiktok', u.tiktok),
        _excelSnsUrl('x', u.x),
        _excelSnsUrl('youtube', u.youtube),
        // 인증 상태 1컬럼 (J열=10) — 인플루언서 정보 다음·영수증 앞 (2026-06-09 이동)
        _excelCertStatusKo((cc.recruit_type), g.receipt, g.result),
        // 영수증 9컬럼 (K~S열=11~19)
        receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8],
        // 결과물 6컬럼 (T~Y열=20~25)
        resultCells[0], resultCells[1], resultCells[2], resultCells[3], resultCells[4], resultCells[5]
      ];
      row.alignment = {vertical: 'middle', wrapText: true};
      // 하이퍼링크 색상 (S열=19 영수증 URL, Y열=25 결과물 URL — 인증 상태 1칸 밀림)
      [19, 25].forEach(function(colNum) {
        var cell = row.getCell(colNum);
        if (cell && cell.value && cell.value.hyperlink) {
          cell.font = {color: {argb: 'FFE8344E'}, underline: true};
        }
      });
      // 이미지 임베드 (R열=18 영수증, X열=24 결과물 — 인증 상태 1칸 밀림)
      if (g.receipt && imgBuffers[g.receipt.id]) {
        var rImgId = wb.addImage({buffer: imgBuffers[g.receipt.id].buffer, extension: imgBuffers[g.receipt.id].ext});
        ws.addImage(rImgId, 'R' + rowNum + ':R' + rowNum);
      }
      if (g.result && g.result.kind === 'review_image' && imgBuffers[g.result.id]) {
        var sImgId = wb.addImage({buffer: imgBuffers[g.result.id].buffer, extension: imgBuffers[g.result.id].ext});
        ws.addImage(sImgId, 'X' + rowNum + ':X' + rowNum);
      }
    });
    }  // end if (hasOtherCamps)

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var aEl = document.createElement('a');
    aEl.href = url;
    var ts = new Date();
    var ymd = ts.getFullYear() + String(ts.getMonth()+1).padStart(2,'0') + String(ts.getDate()).padStart(2,'0');
    var fnTag = camps.length === 1
      ? ((camps[0].campaign_no || camps[0].title || 'campaign').replace(/[\\\/:*?"<>|]/g, '_').substring(0, 40))
      : (camps.length + 'campaigns');
    aEl.download = 'deliverables-' + fnTag + '-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + camps.length + '개 캠페인, ' + groupList.length + '건 신청, ' + allDelivs.length + '건 결과물)');
  } catch (e) {
    console.error('[exportSelectedCampaignsDeliverables]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}

// 캠페인별 신청자 목록 엑셀 다운로드 (전체 상태, 4채널 SNS+팔로워 포함)
async function exportCampaignApplicationsExcel(campId) {
  if (!_checkExportAllowed()) return;
  _markExportStart();
  try {
    document.querySelectorAll('.camp-more-menu').forEach(function(d){ d.remove(); });

    var camp = (Array.isArray(allCampaigns) ? allCampaigns : []).find(function(c){ return c.id === campId; });
    if (!camp && db) {
      var res = await db?.from('campaigns').select('*').eq('id', campId).maybeSingle();
      camp = res?.data;
    }
    if (!camp) { toast('캠페인을 찾을 수 없습니다', 'error'); return; }

    toast('엑셀 생성 중...');
    await loadExcelJS();

    var apps = await fetchApplications({ campaign_id: campId });
    if (!apps || apps.length === 0) { toast('신청자가 없습니다', 'error'); return; }

    var users = await fetchInfluencers();
    var userByEmail = {};
    (users || []).forEach(function(u){ if (u.email) userByEmail[u.email] = u; });

    var statusLabel = function(s) {
      if (s === 'approved') return '승인';
      if (s === 'pending') return '심사중';
      if (s === 'rejected') return '미승인';
      if (s === 'cancelled') return '취소';
      return s || '';
    };
    // 취소 카테고리 라벨 캐시 (cancelled 행 있으면 미리 채움)
    await ensureCancelReasonsCache();
    // 인라인 헬퍼 폐기 — _excelInfluencerNameParts / _excelSnsUrl / _excelZip / _excelAddressOnly 공용 헬퍼 사용

    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var sheetName = (camp.campaign_no || camp.title || '신청자').substring(0, 28);
    var ws = wb.addWorksheet(sheetName);

    ws.columns = [
      { header: '신청일',            key: 'created',    width: 20 },
      { header: '상태',              key: 'status',     width: 10 },
      { header: '이름(한자)',        key: 'nameKanji',  width: 16 },
      { header: '이름(가나)',        key: 'nameKana',   width: 16 },
      { header: '이메일',            key: 'email',      width: 26 },
      { header: '연락처',            key: 'phone',      width: 16 },
      { header: 'Instagram URL',     key: 'ig',         width: 36 },
      { header: 'Instagram 팔로워', key: 'igF',        width: 14 },
      { header: 'TikTok URL',        key: 'tt',         width: 36 },
      { header: 'TikTok 팔로워',    key: 'ttF',        width: 14 },
      { header: 'X URL',             key: 'x',          width: 36 },
      { header: 'X 팔로워',          key: 'xF',         width: 14 },
      { header: 'YouTube URL',       key: 'yt',         width: 36 },
      { header: 'YouTube 팔로워',    key: 'ytF',        width: 14 },
      { header: '우편번호',          key: 'zip',        width: 10 },
      { header: '배송지',            key: 'address',    width: 40 },
      { header: '신청 메시지',       key: 'message',    width: 40 },
      { header: '심사일',            key: 'reviewedAt', width: 20 },
      { header: '리뷰어',            key: 'reviewedBy', width: 16 },
      { header: '취소일',            key: 'cancelledAt',    width: 20 },
      { header: '취소 사유(보충)',   key: 'cancelReason',   width: 30 },
      { header: '취소 카테고리',     key: 'cancelCategory', width: 22 },
      { header: '취소 시점',         key: 'cancelPhase',    width: 14 }
    ];

    var header = ws.getRow(1);
    header.font = { bold: true, color: { argb: 'FF222222' } };
    header.alignment = { vertical: 'middle', horizontal: 'center' };
    header.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF2F2F2' } };
    header.height = 22;

    apps.forEach(function(a) {
      var u = userByEmail[a.user_email] || {};
      var createdStr = '';
      if (a.created_at) {
        try { createdStr = new Date(a.created_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { createdStr = String(a.created_at); }
      }
      var reviewedStr = '';
      if (a.reviewed_at) {
        try { reviewedStr = new Date(a.reviewed_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { reviewedStr = String(a.reviewed_at); }
      }
      var cancelledStr = '';
      if (a.cancelled_at) {
        try { cancelledStr = new Date(a.cancelled_at).toLocaleString('ko-KR', { timeZone: 'Asia/Seoul' }); }
        catch(e) { cancelledStr = String(a.cancelled_at); }
      }
      var nmS = _excelInfluencerNameParts(u);
      ws.addRow({
        created:        createdStr,
        status:         statusLabel(a.status),
        nameKanji:      nmS.kanji || a.user_name || '',
        nameKana:       nmS.kana || '',
        email:          a.user_email || '',
        phone:          formatPhoneDisplay(u.phone),
        ig:             _excelSnsUrl('instagram', u.ig || a.ig_id || a.user_ig),
        igF:            Number(u.ig_followers || 0),
        tt:             _excelSnsUrl('tiktok', u.tiktok),
        ttF:            Number(u.tiktok_followers || 0),
        x:              _excelSnsUrl('x', u.x),
        xF:             Number(u.x_followers || 0),
        yt:             _excelSnsUrl('youtube', u.youtube),
        ytF:            Number(u.youtube_followers || 0),
        zip:            _excelZip(u),
        address:        _excelAddressOnly(u, a.address),
        message:        a.message || '',
        reviewedAt:     reviewedStr,
        reviewedBy:     formatReviewer(a.reviewed_by),
        cancelledAt:    cancelledStr,
        cancelReason:   a.cancel_reason || '',
        cancelCategory: a.cancel_reason_code ? cancelReasonLabelKo(a.cancel_reason_code) : '',
        cancelPhase:    a.cancel_phase ? cancelPhaseLabelKo(a.cancel_phase) : ''
      });
    });

    ['igF','ttF','xF','ytF'].forEach(function(k) {
      ws.getColumn(k).numFmt = '#,##0';
      ws.getColumn(k).alignment = { horizontal: 'right' };
    });
    ws.getColumn('message').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('address').alignment = { wrapText: true, vertical: 'top' };
    ws.getColumn('cancelReason').alignment = { wrapText: true, vertical: 'top' };

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a');
    a.href = url;
    var ts = new Date();
    var yyyy = ts.getFullYear();
    var mm = String(ts.getMonth()+1).padStart(2,'0');
    var dd = String(ts.getDate()).padStart(2,'0');
    var safeTitle = (camp.campaign_no || camp.title || 'campaign').replace(/[\\\/:*?"<>|]/g, '_').substring(0, 40);
    a.download = `applicants-${safeTitle}-${yyyy}${mm}${dd}.xlsx`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + apps.length + '건)');
  } catch (e) {
    console.error('[exportCampaignApplicationsExcel]', e);
    toast('엑셀 생성 실패: ' + (e?.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}


async function exportCampaignDeliverables(campId) {
  if (!_checkExportAllowed()) return;
  _markExportStart();
  try {
    document.querySelectorAll('.camp-more-menu').forEach(function(d){ d.remove(); });
    toast('엑셀 생성 중...');
    await loadExcelJS();

    // 1) 캠페인 로드
    var camp = (Array.isArray(allCampaigns) ? allCampaigns : []).find(function(c){ return c.id === campId; });
    if (!camp && db) {
      var res = await db?.from('campaigns').select('*').eq('id', campId).maybeSingle();
      camp = res?.data;
    }
    if (!camp) { toast('캠페인을 찾을 수 없습니다', 'error'); return; }

    // 2) 결과물 로드 (전체 상태 — 검수중·반려·미제출 인증 상태가 보이도록, 2026-06-09 사용자 결정)
    var delivs = await fetchDeliverables({campaign_id: campId});
    // 미제출(결과물 0건) 신청도 행에 포함 — 화면 목록(renderDeliverablesList includeMissing) 과 동일.
    //   승인된(approved) 신청을 가져와, 결과물 그룹에 없는 신청은 빈 행 + 인증 상태 '미제출' 로 추가.
    var approvedApps = await fetchApplications({campaign_id: campId, status: 'approved'});
    if (!delivs.length && !approvedApps.length) { toast('결과물이 없습니다', 'warn'); return; }

    // 3) 인플루언서 전체 조회 (SNS 핸들·한자 이름은 fetchDeliverables의 인플루언서 매핑에 포함되지 않음)
    var users = await fetchInfluencers();
    var userById = {};
    (users || []).forEach(function(u){ if (u && u.id) userById[u.id] = u; });

    // 3-1) monitor + 캠페인 채널 N개면 채널별 결과물 컬럼 펼침 (사양 2 PR 3, 2026-05-28)
    //   gifting/visit·채널 없는 레거시 monitor는 기존 22컬럼 단일 결과물 코드 그대로.
    var campChannels = (camp.recruit_type === 'monitor')
      ? (camp.channel || '').split(',').map(function(c){ return c.trim(); }).filter(Boolean)
      : [];
    if (campChannels.length > 0) {
      try { await fetchLookups('channel'); } catch(e) { /* 라벨 폴백 OK */ }
      return await _exportCampDelivsMonitorMulti(camp, delivs, userById, campChannels, {approvedApps: approvedApps});
    }

    // 4) 영수증·리뷰 이미지 Image→Canvas로 jpeg 재인코딩 (CORS·포맷 호환성 보장)
    //    receipt(영수증) + review_image(monitor 2단계 리뷰 캡처) 모두 receipt_url 컬럼을 재사용
    var imgBuffers = {};
    await Promise.all(delivs.filter(function(d){
      return (d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url;
    }).map(async function(d) {
      try {
        var url = d.receipt_url;
        if (url && !/^https?:\/\//.test(url) && db?.storage) {
          var sig = await db?.storage?.from('campaign-images').createSignedUrl(url, 3600);
          url = sig?.data?.signedUrl;
        }
        if (!url) return;
        var result = await imgToJpegArrayBuffer(url, 400, 400);
        if (result && result.buffer && result.buffer.byteLength > 0) {
          imgBuffers[d.id] = result;
        }
      } catch(e) {
        console.warn('[excel] receipt fetch failed', d.id, e);
      }
    }));

    // 5) application_id 단위로 그룹핑 — 한 신청 = 한 행 (영수증 + 결과물 6컬럼씩 펼침)
    //    receipt: kind='receipt' / result: kind='review_image' 또는 'post' 중 최신
    var groups = {};
    delivs.forEach(function(d) {
      var key = d.application_id || ('user-' + d.user_id);  // application_id 없으면 user_id 폴백
      if (!groups[key]) {
        groups[key] = {key: key, application_id: d.application_id, user_id: d.user_id, receipt: null, result: null};
      }
      var g = groups[key];
      if (d.kind === 'receipt') {
        // 동일 application에 receipt 여러 건이면 최신(updated_at 기준) 우선
        if (!g.receipt || (d.updated_at || '') > (g.receipt.updated_at || '')) g.receipt = d;
      } else if (d.kind === 'review_image' || d.kind === 'post') {
        if (!g.result || (d.updated_at || '') > (g.result.updated_at || '')) g.result = d;
      }
    });
    // 미제출(결과물 0건) 신청 행 추가 — 승인 신청 중 결과물 그룹에 없는 건은 빈 행으로 (인증 상태 '미제출')
    (approvedApps || []).forEach(function(app) {
      var key = app.id;
      if (groups[key]) return;
      groups[key] = {key: key, application_id: app.id, user_id: app.user_id, receipt: null, result: null};
    });
    var groupList = Object.values(groups);
    // 인플루언서 이름순 정렬 (한자 우선)
    groupList.sort(function(a, b) {
      var ua = userById[a.user_id] || {};
      var ub = userById[b.user_id] || {};
      var na = (ua.name_kanji || ua.name || '').toString();
      var nb = (ub.name_kanji || ub.name || '').toString();
      return na.localeCompare(nb, 'ja');
    });

    // 6) 워크북 생성
    var wb = new ExcelJS.Workbook();
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
    var ws = wb.addWorksheet('결과물');

    // 헤더 (A1:X1, A2:X2) — 총 24열 (인플 7 + 인증상태 1 + 영수증 9 + 결과물 6 + 대리등록 1)
    ws.mergeCells('A1:X1');
    var t = ws.getCell('A1');
    t.value = (camp.campaign_no ? camp.campaign_no + '  ' : '') + (camp.title || '');
    t.font = {bold: true, size: 14};
    t.alignment = {vertical: 'middle'};
    ws.getRow(1).height = 26;

    ws.mergeCells('A2:X2');
    var m = ws.getCell('A2');
    m.value = '브랜드: ' + (brandLabelAdmin(camp) || '—')
      + '  ·  신청 건수: ' + groupList.length + '건'
      + '  ·  결과물 합계: ' + delivs.length + '건'
      + '  ·  생성일: ' + new Date().toLocaleString('ko-KR');
    m.font = {color: {argb: 'FF888888'}, size: 11};
    ws.getRow(2).height = 20;

    // 그룹 헤더 (3행) — 인플루언서 7컬럼 / 인증 상태 1컬럼 / 영수증 9컬럼 / 결과물 6컬럼 / 대리 등록 1컬럼
    //   2026-06-09: 인증 상태를 인플루언서 정보 다음·영수증 앞으로 이동 (사용자 요청). 영수증·결과물 인덱스 +1 밀림.
    ws.mergeCells('A3:G3'); ws.getCell('A3').value = '인플루언서 정보';
    ws.getCell('H3').value = '인증 상태';
    ws.mergeCells('I3:Q3'); ws.getCell('I3').value = '영수증';
    ws.mergeCells('R3:W3'); ws.getCell('R3').value = '결과물';
    ws.getCell('X3').value = '대리 등록';
    ['A3','H3','I3','R3','X3'].forEach(function(addr) {
      var c = ws.getCell(addr);
      c.font = {bold: true, color: {argb: 'FF222222'}};
      c.alignment = {vertical: 'middle', horizontal: 'center'};
      c.fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFE8E8E8'}};
    });
    ws.getRow(3).height = 22;

    // 컬럼 헤더 (4행)
    // 영수증 9컬럼: 타입 / 제출일 / 검수일 / 상태 / 주문번호 / 구매일 / 구매금액 / 이미지 / URL
    // W컬럼 「관리자 · 사유」: 영수증 또는 결과물 중 1건이라도 대리 등록이면 표시
    ws.getRow(4).values = [
      '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
      '인증 상태',
      '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL',
      '타입', '제출일', '검수일', '상태', '이미지', 'URL',
      '관리자 · 사유'
    ];
    ws.getRow(4).font = {bold: true, color: {argb: 'FF222222'}};
    ws.getRow(4).fill = {type: 'pattern', pattern: 'solid', fgColor: {argb: 'FFF0F0F0'}};
    ws.getRow(4).alignment = {vertical: 'middle', horizontal: 'center'};
    ws.getRow(4).height = 24;

    // 컬럼 너비 (이름 18·이메일 28·SNS URL 36, 인증 상태 1컬럼·영수증 9컬럼·결과물 6컬럼·대리 등록 1컬럼)
    ws.columns = [
      {width: 18}, {width: 18}, {width: 28}, {width: 36}, {width: 36}, {width: 36}, {width: 36},
      {width: 14},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 18}, {width: 12}, {width: 12}, {width: 16}, {width: 32},
      {width: 12}, {width: 12}, {width: 12}, {width: 10}, {width: 16}, {width: 32},
      {width: 28}
    ];

    // SNS URL 변환은 공용 _excelSnsUrl 헬퍼 사용 (handle → 전체 URL)
    // 헬퍼: 결과물 1건의 6컬럼 값 계산 — 타입/제출일/검수일/상태/이미지(빈 셀, 임베드는 별도)/URL
    var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려'};
    var renderDeliverableCells = function(d) {
      if (!d) return ['', '', '', '', '', ''];
      var kindLabel = d.kind === 'receipt' ? '영수증'
        : d.kind === 'review_image' ? '리뷰 이미지'
        : '게시물';
      var submittedStr = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
      var reviewedStr = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
      var statusStr = statusLabelMap[d.status] || d.status || '';
      // URL 셀: post는 게시물 URL, receipt/review_image는 receipt_url 기반 하이퍼링크
      var urlCellValue = '';
      if (d.kind === 'post') {
        var postUrl = d.post_url || '';
        if (Array.isArray(d.post_submissions) && d.post_submissions.length) {
          var last = d.post_submissions[d.post_submissions.length - 1];
          postUrl = (last && last.url) || postUrl;
        }
        if (postUrl) urlCellValue = {text: postUrl, hyperlink: postUrl};
      } else if ((d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url) {
        var imgUrl = /^https?:\/\//.test(d.receipt_url)
          ? d.receipt_url
          : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
        urlCellValue = {text: imgUrl, hyperlink: imgUrl};
      }
      return [kindLabel, submittedStr, reviewedStr, statusStr, '', urlCellValue];
    };

    // 영수증(receipt) 전용 9컬럼 (마이그레이션 128) — 기본 4 + 주문번호·구매일·구매금액 + 이미지·URL
    var renderReceiptCells9 = function(d) {
      if (!d) return ['', '', '', '', '', '', '', '', ''];
      var base = renderDeliverableCells(d);  // [type, submitted, reviewed, status, '', url]
      var orderNo = d.order_number || '';
      var purchaseDate = d.purchase_date || '';
      var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
        ? '' : Number(d.purchase_amount);
      return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
    };

    // 본문 행 — 그룹 1개 = 1행
    groupList.forEach(function(g, i) {
      var rowNum = 5 + i;
      var u = userById[g.user_id] || {};
      var row = ws.getRow(rowNum);
      row.height = 84;

      var receiptCells = renderReceiptCells9(g.receipt);
      var resultCells = renderDeliverableCells(g.result);
      // 마이그레이션 160: 대리 등록 1컬럼 — 영수증 또는 결과물 중 1건이라도 submitted_by_admin 이면 "사유 라벨 (영수증/결과물 표시)" 한 줄
      var proxyParts = [];
      if (g.receipt && g.receipt.submitted_by_admin) {
        var rReason = _excelProxyReasonKo(g.receipt.submitted_by_admin_reason_code);
        proxyParts.push('영수증 · ' + rReason);
      }
      if (g.result && g.result.submitted_by_admin) {
        var dReason = _excelProxyReasonKo(g.result.submitted_by_admin_reason_code);
        proxyParts.push('결과물 · ' + dReason);
      }
      var proxyCell = proxyParts.length ? proxyParts.join(' / ') : '';

      row.values = [
        // 인플루언서 정보 7컬럼
        u.name_kanji || u.name || '—',
        u.name_kana || '',
        u.email || '',
        _excelSnsUrl('instagram', u.ig),
        _excelSnsUrl('tiktok', u.tiktok),
        _excelSnsUrl('x', u.x),
        _excelSnsUrl('youtube', u.youtube),
        // 인증 상태 1컬럼 (H열=8) — 인플루언서 정보 다음·영수증 앞 (2026-06-09 이동)
        _excelCertStatusKo(camp.recruit_type, g.receipt, g.result),
        // 영수증 9컬럼 (I~Q열=9~17)
        receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8],
        // 결과물 6컬럼 (R~W열=18~23)
        resultCells[0], resultCells[1], resultCells[2], resultCells[3], resultCells[4], resultCells[5],
        // 대리 등록 1컬럼 (X열=24)
        proxyCell
      ];
      row.alignment = {vertical: 'middle', wrapText: true};

      // 하이퍼링크 셀 스타일 (Q열=17 영수증 URL, W열=23 결과물 URL — 인증 상태 1칸 밀림)
      [17, 23].forEach(function(colNum) {
        var c = row.getCell(colNum);
        if (c && c.value && c.value.hyperlink) {
          c.font = {color: {argb: 'FFE8344E'}, underline: true};
        }
      });

      // 영수증 이미지 임베드 (P열=16 — 인증 상태 1칸 밀림)
      if (g.receipt && imgBuffers[g.receipt.id]) {
        var rImgId = wb.addImage({buffer: imgBuffers[g.receipt.id].buffer, extension: imgBuffers[g.receipt.id].ext});
        ws.addImage(rImgId, 'P' + rowNum + ':P' + rowNum);
      }
      // 결과물 이미지 임베드 (review_image, V열=22 — 인증 상태 1칸 밀림). post는 이미지 없음.
      if (g.result && g.result.kind === 'review_image' && imgBuffers[g.result.id]) {
        var dImgId = wb.addImage({buffer: imgBuffers[g.result.id].buffer, extension: imgBuffers[g.result.id].ext});
        ws.addImage(dImgId, 'V' + rowNum + ':V' + rowNum);
      }
    });

    // 7) 파일 저장
    var buffer = await wb.xlsx.writeBuffer();
    var blob = new Blob([buffer], {type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
    var safeBrand = (brandLabelAdmin(camp) || 'brand').replace(/[\/\\?%*:|"<>]/g, '_');
    var today = new Date().toISOString().slice(0, 10);
    var fname = (camp.campaign_no || camp.id.slice(0,8)) + '_' + safeBrand + '_결과물_' + today + '.xlsx';

    var link = document.createElement('a');
    link.href = URL.createObjectURL(blob);
    link.download = fname;
    link.click();
    setTimeout(function(){ URL.revokeObjectURL(link.href); }, 1000);

    toast('엑셀 다운로드 완료 (' + groupList.length + '건)');
  } catch(e) {
    console.error('[exportCampaignDeliverables]', e);
    toast('엑셀 생성 실패: ' + (e.message || String(e)), 'error');
  } finally {
    _markExportEnd();
  }
}

// 엑셀 컬럼 번호 → 알파벳 변환 (1=A, 27=AA, 28=AB ...)
function _excelColLetter(n) {
  var s = '';
  while (n > 0) {
    var r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

// 사양 2 PR 3 — 단일 캠페인 monitor 다채널 엑셀.
// 결과물 6컬럼을 캠페인 채널 수만큼 N개 펼침. 헤더 3행에 채널별 그룹 헤더,
// 본문 행 단위 = application_id, 채널별 review_image 미제출 채널은 공란.
async function _exportCampDelivsMonitorMulti(camp, delivs, userById, campChannels, opts) {
  // opts = { wb, sheetName, imgBuffers, skipDownload } — 다중 엑셀에서 시트 추가형으로 재사용.
  //   wb 전달 시 자체 워크북 생성하지 않고 그 wb 에 시트 추가, 다운로드도 외부 책임.
  //   imgBuffers 전달 시 사전 다운로드된 버퍼 재사용 (다중에서 1회 일괄 다운로드).
  opts = opts || {};
  var externalWb = opts.wb || null;
  var externalSheetName = opts.sheetName || '결과물';
  var externalImgBuffers = opts.imgBuffers || null;
  var skipDownload = !!opts.skipDownload || !!externalWb;
  var approvedApps = opts.approvedApps || null;  // 미제출(결과물 0건) 신청 빈 행 포함용 (단일 엑셀 전체 로드)
  // ── 1) 이미지 사전 다운로드 (receipt + review_image 모두) — 외부 전달 시 재사용 ─
  var imgBuffers = externalImgBuffers || {};
  if (!externalImgBuffers) {
    await Promise.all(delivs.filter(function(d){
      return (d.kind === 'receipt' || d.kind === 'review_image') && d.receipt_url;
    }).map(async function(d) {
      try {
        var url = d.receipt_url;
        if (url && !/^https?:\/\//.test(url) && db?.storage) {
          var sig = await db?.storage?.from('campaign-images').createSignedUrl(url, 3600);
          url = sig?.data?.signedUrl;
        }
        if (!url) return;
        var result = await imgToJpegArrayBuffer(url, 400, 400);
        if (result && result.buffer && result.buffer.byteLength > 0) imgBuffers[d.id] = result;
      } catch(e) { console.warn('[excel-multi] receipt fetch failed', d.id, e); }
    }));
  }

  // ── 2) application_id 단위 그룹핑 — receipt + reviewByCh{channel: deliv} ─────
  var groups = {};
  delivs.forEach(function(d) {
    var key = d.application_id || ('user-' + d.user_id);
    if (!groups[key]) groups[key] = {key:key, application_id:d.application_id, user_id:d.user_id, receipt:null, reviewByCh:{}, latest:''};
    var g = groups[key];
    var subAt = d.updated_at || d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.updated_at || g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image' && d.post_channel) {
      var prev = g.reviewByCh[d.post_channel];
      if (!prev || subAt > (prev.updated_at || prev.submitted_at || '')) g.reviewByCh[d.post_channel] = d;
    }
    if (subAt > g.latest) g.latest = subAt;
  });
  // 미제출(결과물 0건) 신청 빈 행 추가 — 승인 신청 중 그룹에 없는 건 (인증 상태 '미제출')
  (approvedApps || []).forEach(function(app) {
    var key = app.id;
    if (groups[key]) return;
    groups[key] = {key:key, application_id:app.id, user_id:app.user_id, receipt:null, reviewByCh:{}, latest:''};
  });
  var groupList = Object.values(groups).sort(function(a, b) {
    var ua = userById[a.user_id] || {}, ub = userById[b.user_id] || {};
    return (ua.name_kanji || ua.name || '').localeCompare(ub.name_kanji || ub.name || '', 'ja');
  });

  // ── 3) 컬럼 계산 — 인플 7 + 인증 상태 1 + 영수증 9 + 채널별 6 × N ─────────────
  //   2026-06-09: 인증 상태를 인플루언서 정보 다음·영수증 앞으로 이동. 영수증·채널 인덱스 +1 밀림.
  var INFO_COLS = 7, RECEIPT_COLS = 9, CH_COLS = 6;
  var N = campChannels.length;
  var certCol = INFO_COLS + 1;                    // 인증 상태 컬럼 (8, 인플 다음)
  var receiptStart = INFO_COLS + 2;              // 9 (인증 상태 1칸 뒤)
  var receiptEnd   = INFO_COLS + 1 + RECEIPT_COLS; // 17
  var receiptImgCol = receiptEnd - 1;            // 16 (이미지 컬럼)
  var chBase = INFO_COLS + 1 + RECEIPT_COLS;     // 채널 그룹 시작 직전 컬럼 (17) — 채널 i 시작 = chBase + 1 + i*CH_COLS
  var totalCols = chBase + CH_COLS * N;          // 마지막 컬럼 (채널 데이터 끝)
  var grandLastLetter = _excelColLetter(totalCols); // 머리글 머지용

  // 채널별 라벨 (lookup_values name_ko, 폴백 code)
  var chLabelOf = function(code) {
    return (typeof getLookupLabel === 'function') ? (getLookupLabel('channel', code, 'ko') || code) : code;
  };

  // ── 4) 워크북 + 헤더 3행 — 외부 wb 전달 시 시트만 추가 ────────────────────
  var wb = externalWb || new ExcelJS.Workbook();
  if (!externalWb) {
    wb.creator = 'REVERB JP Admin';
    wb.created = new Date();
  }
  var ws = wb.addWorksheet(externalSheetName);

  // row 1: 캠페인 제목 머지
  ws.mergeCells('A1:' + grandLastLetter + '1');
  var t = ws.getCell('A1');
  t.value = (camp.campaign_no ? camp.campaign_no + '  ' : '') + (camp.title || '');
  t.font = {bold:true, size:14};
  t.alignment = {vertical:'middle'};
  ws.getRow(1).height = 26;

  // row 2: 메타 정보 머지
  ws.mergeCells('A2:' + grandLastLetter + '2');
  var m = ws.getCell('A2');
  m.value = '브랜드: ' + (brandLabelAdmin(camp) || '—')
    + '  ·  신청 건수: ' + groupList.length + '건'
    + '  ·  결과물 합계: ' + delivs.length + '건'
    + '  ·  채널: ' + campChannels.map(chLabelOf).join(', ')
    + '  ·  생성일: ' + new Date().toLocaleString('ko-KR');
  m.font = {color:{argb:'FF888888'}, size:11};
  ws.getRow(2).height = 20;

  // row 3: 그룹 헤더 (인플루언서 / 인증 상태 / 영수증 / 채널 N개 리뷰)
  var certL = _excelColLetter(certCol);                 // H (8)
  var receiptStartL = _excelColLetter(receiptStart);    // I (9)
  var receiptEndL = _excelColLetter(receiptEnd);        // Q (17)
  ws.mergeCells('A3:G3'); ws.getCell('A3').value = '인플루언서 정보';
  ws.getCell(certL + '3').value = '인증 상태';
  ws.mergeCells(receiptStartL + '3:' + receiptEndL + '3'); ws.getCell(receiptStartL + '3').value = '영수증';
  campChannels.forEach(function(ch, i) {
    var s = chBase + 1 + i * CH_COLS;
    var e = s + CH_COLS - 1;
    var sL = _excelColLetter(s), eL = _excelColLetter(e);
    ws.mergeCells(sL + '3:' + eL + '3');
    ws.getCell(sL + '3').value = '「' + chLabelOf(ch) + '」 리뷰';
  });
  ['A3', certL + '3', receiptStartL + '3'].concat(campChannels.map(function(_, i){ return _excelColLetter(chBase + 1 + i * CH_COLS) + '3'; })).forEach(function(addr) {
    var c = ws.getCell(addr);
    c.font = {bold:true, color:{argb:'FF222222'}};
    c.alignment = {vertical:'middle', horizontal:'center'};
    c.fill = {type:'pattern', pattern:'solid', fgColor:{argb:'FFE8E8E8'}};
  });
  ws.getRow(3).height = 22;

  // row 4: 컬럼 헤더 (인플 7 → 인증 상태 1 → 영수증 9 → 채널별 6 × N)
  var headerValues = [
    '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
    '인증 상태',
    '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL'
  ];
  campChannels.forEach(function() {
    headerValues.push('타입', '제출일', '검수일', '상태', '이미지', 'URL');
  });
  ws.getRow(4).values = headerValues;
  ws.getRow(4).font = {bold:true, color:{argb:'FF222222'}};
  ws.getRow(4).fill = {type:'pattern', pattern:'solid', fgColor:{argb:'FFF0F0F0'}};
  ws.getRow(4).alignment = {vertical:'middle', horizontal:'center'};
  ws.getRow(4).height = 24;

  // 컬럼 너비 (인플 7 → 인증 상태 1 → 영수증 9 → 채널별 6 × N)
  var colWidths = [
    18, 18, 28, 36, 36, 36, 36,         // 인플 7
    14,                                  // 인증 상태 1
    12, 12, 12, 10, 18, 12, 12, 16, 32  // 영수증 9
  ];
  campChannels.forEach(function() { colWidths.push(12, 12, 12, 10, 16, 32); });
  ws.columns = colWidths.map(function(w) { return {width:w}; });

  // 결과물 6컬럼 값 계산 헬퍼 (단일 함수와 동일 패턴, 인라인)
  var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려'};
  var renderDeliv6 = function(d) {
    if (!d) return ['', '', '', '', '', ''];
    var sub = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
    var rev = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
    var st = statusLabelMap[d.status] || d.status || '';
    var urlVal = '';
    if (d.receipt_url) {
      var iu = /^https?:\/\//.test(d.receipt_url)
        ? d.receipt_url
        : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
      urlVal = {text:iu, hyperlink:iu};
    }
    return ['리뷰 이미지', sub, rev, st, '', urlVal];
  };
  var renderReceipt9 = function(d) {
    if (!d) return ['', '', '', '', '', '', '', '', ''];
    var base = renderDeliv6(d);  // base[0]='리뷰 이미지' 라서 type 만 영수증으로 교체
    base[0] = '영수증';
    var orderNo = d.order_number || '';
    var purchaseDate = d.purchase_date || '';
    var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
      ? '' : Number(d.purchase_amount);
    return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
  };

  // ── 5) 본문 행 ────────────────────────────────────────────────────────
  groupList.forEach(function(g, i) {
    var rowNum = 5 + i;
    var u = userById[g.user_id] || {};
    var row = ws.getRow(rowNum);
    row.height = 84;

    var receiptCells = renderReceipt9(g.receipt);
    var vals = [
      u.name_kanji || u.name || '—',
      u.name_kana || '',
      u.email || '',
      _excelSnsUrl('instagram', u.ig),
      _excelSnsUrl('tiktok', u.tiktok),
      _excelSnsUrl('x', u.x),
      _excelSnsUrl('youtube', u.youtube),
      // 인증 상태 1컬럼 (certCol=8) — monitor: 영수증 승인 + 채널별 대표 상태 approved 면 인증성공
      _excelCertStatusMonitorKo(campChannels, g.receipt, g.reviewByCh),
      // 영수증 9컬럼
      receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8]
    ];
    campChannels.forEach(function(ch) {
      var cells = renderDeliv6(g.reviewByCh[ch]);
      vals.push(cells[0], cells[1], cells[2], cells[3], cells[4], cells[5]);
    });
    row.values = vals;
    row.alignment = {vertical:'middle', wrapText:true};

    // 하이퍼링크 셀 스타일 — 영수증 URL(receiptEnd) + 채널별 URL(채널 시작 + 5)
    var linkCols = [receiptEnd];
    campChannels.forEach(function(_, ci) {
      linkCols.push(chBase + 1 + ci * CH_COLS + 5);  // URL = 채널 시작 + 5
    });
    linkCols.forEach(function(col) {
      var c = row.getCell(col);
      if (c && c.value && c.value.hyperlink) c.font = {color:{argb:'FFE8344E'}, underline:true};
    });

    // 이미지 임베드 — 영수증(receiptImgCol=16) + 채널별 review_image(채널 시작 + 4)
    if (g.receipt && imgBuffers[g.receipt.id]) {
      var rImgId = wb.addImage({buffer:imgBuffers[g.receipt.id].buffer, extension:imgBuffers[g.receipt.id].ext});
      ws.addImage(rImgId, _excelColLetter(receiptImgCol) + rowNum + ':' + _excelColLetter(receiptImgCol) + rowNum);
    }
    campChannels.forEach(function(ch, ci) {
      var d = g.reviewByCh[ch];
      if (d && imgBuffers[d.id]) {
        var dImgId = wb.addImage({buffer:imgBuffers[d.id].buffer, extension:imgBuffers[d.id].ext});
        var imgCol = chBase + 1 + ci * CH_COLS + 4;  // 이미지 = 채널 시작 + 4
        var imgColL = _excelColLetter(imgCol);
        ws.addImage(dImgId, imgColL + rowNum + ':' + imgColL + rowNum);
      }
    });
  });

  // ── 6) 파일 저장 — skipDownload 면 시트만 빌드 후 종료 (다중 엑셀에서 사용) ──
  if (skipDownload) return ws;
  var buffer = await wb.xlsx.writeBuffer();
  var blob = new Blob([buffer], {type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'});
  var safeBrand = (brandLabelAdmin(camp) || 'brand').replace(/[\/\\?%*:|"<>]/g, '_');
  var today = new Date().toISOString().slice(0, 10);
  var fname = (camp.campaign_no || camp.id.slice(0,8)) + '_' + safeBrand + '_결과물_' + today + '.xlsx';
  var link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = fname;
  link.click();
  setTimeout(function(){ URL.revokeObjectURL(link.href); }, 1000);
  toast('엑셀 다운로드 완료 (' + groupList.length + '건, 채널 ' + N + '개)');
}

// 사양 2 PR 3 단계 b — 다중 엑셀의 「리뷰 · {채널 조합}」 그룹 시트 빌더.
//   같은 채널 구성(예: qoo10, qoo10/lips)의 캠페인 N개를 한 시트에 묶음.
//   컬럼 = 캠페인 2 + 인플 7 + 영수증 9 + 채널 N × 6.
//   행 = (campaign_id, application_id) 단위.
function _buildMonitorGroupSheet(wb, sheetName, grpCamps, channels, delivs, userById, imgBuffers, titleOverride) {
  // 그룹핑
  var groups = {};
  delivs.forEach(function(d) {
    var key = d.campaign_id + '|' + (d.application_id || ('user-' + d.user_id));
    if (!groups[key]) {
      var camp = grpCamps.find(function(c){ return c.id === d.campaign_id; }) || {};
      groups[key] = {key:key, camp:camp, application_id:d.application_id, user_id:d.user_id, receipt:null, reviewByCh:{}};
    }
    var g = groups[key];
    var subAt = d.updated_at || d.submitted_at || '';
    if (d.kind === 'receipt') {
      if (!g.receipt || subAt > (g.receipt.updated_at || g.receipt.submitted_at || '')) g.receipt = d;
    } else if (d.kind === 'review_image' && d.post_channel) {
      var prev = g.reviewByCh[d.post_channel];
      if (!prev || subAt > (prev.updated_at || prev.submitted_at || '')) g.reviewByCh[d.post_channel] = d;
    }
  });
  var groupList = Object.values(groups).sort(function(a, b) {
    var ca = (a.camp.campaign_no || '').toString();
    var cb = (b.camp.campaign_no || '').toString();
    if (ca !== cb) return ca.localeCompare(cb, 'ja');
    var ua = userById[a.user_id] || {}, ub = userById[b.user_id] || {};
    return (ua.name_kanji || ua.name || '').localeCompare(ub.name_kanji || ub.name || '', 'ja');
  });

  // 컬럼 계산 — 캠페인 2 + 인플 7 + 인증 상태 1 + 영수증 9 + 채널별 6 × N
  //   2026-06-09: 인증 상태를 인플루언서 정보 다음·영수증 앞으로 이동. 영수증·채널 인덱스 +1 밀림.
  var CAMP_COLS = 2, INFO_COLS = 7, RECEIPT_COLS = 9, CH_COLS = 6;
  var N = channels.length;
  var certCol = CAMP_COLS + INFO_COLS + 1;          // 인증 상태 컬럼 (10, 인플 다음)
  var receiptStart = CAMP_COLS + INFO_COLS + 2;     // 11 (인증 상태 1칸 뒤)
  var receiptEnd = CAMP_COLS + INFO_COLS + 1 + RECEIPT_COLS;  // 19
  var receiptImgCol = receiptEnd - 1;               // 18 (영수증 이미지 컬럼)
  var chBase = CAMP_COLS + INFO_COLS + 1 + RECEIPT_COLS;  // 채널 그룹 시작 직전 컬럼 (19)
  var totalCols = chBase + CH_COLS * N;             // 마지막 컬럼 (채널 데이터 끝)
  var grandLastLetter = _excelColLetter(totalCols); // 머리글 머지용

  var chLabelOf = function(code) {
    return (typeof getLookupLabel === 'function') ? (getLookupLabel('channel', code, 'ko') || code) : code;
  };

  var ws = wb.addWorksheet(sheetName);

  // row 1: 그룹 제목
  ws.mergeCells('A1:' + grandLastLetter + '1');
  var t = ws.getCell('A1');
  t.value = (titleOverride || ('채널 조합 「' + channels.map(chLabelOf).join(' / ') + '」')) + '  (' + grpCamps.length + '개 캠페인)';
  t.font = {bold:true, size:14};
  t.alignment = {vertical:'middle'};
  ws.getRow(1).height = 26;

  // row 2: 메타
  ws.mergeCells('A2:' + grandLastLetter + '2');
  var m = ws.getCell('A2');
  m.value = '캠페인 ' + grpCamps.length + '개  ·  신청 ' + groupList.length + '건  ·  결과물 ' + delivs.length + '건  ·  생성일: ' + new Date().toLocaleString('ko-KR');
  m.font = {color:{argb:'FF888888'}, size:11};
  ws.getRow(2).height = 20;

  // row 3: 그룹 헤더 (캠페인 / 인플 / 인증 상태 / 영수증 / 채널 N개)
  var certL = _excelColLetter(certCol);              // J (10)
  var receiptStartL = _excelColLetter(receiptStart); // K (11)
  var receiptEndL = _excelColLetter(receiptEnd);     // S (19)
  ws.mergeCells('A3:B3'); ws.getCell('A3').value = '캠페인';
  ws.mergeCells('C3:I3'); ws.getCell('C3').value = '인플루언서 정보';
  ws.getCell(certL + '3').value = '인증 상태';
  ws.mergeCells(receiptStartL + '3:' + receiptEndL + '3'); ws.getCell(receiptStartL + '3').value = '영수증';
  channels.forEach(function(ch, i) {
    var s = chBase + 1 + i * CH_COLS;
    var e = s + CH_COLS - 1;
    ws.mergeCells(_excelColLetter(s) + '3:' + _excelColLetter(e) + '3');
    ws.getCell(_excelColLetter(s) + '3').value = '「' + chLabelOf(ch) + '」 리뷰';
  });
  ['A3','C3', certL + '3', receiptStartL + '3'].concat(channels.map(function(_, i){ return _excelColLetter(chBase + 1 + i * CH_COLS) + '3'; })).forEach(function(addr) {
    var c = ws.getCell(addr);
    c.font = {bold:true, color:{argb:'FF222222'}};
    c.alignment = {vertical:'middle', horizontal:'center'};
    c.fill = {type:'pattern', pattern:'solid', fgColor:{argb:'FFE8E8E8'}};
  });
  ws.getRow(3).height = 22;

  // row 4: 컬럼 헤더 (캠페인 2 → 인플 7 → 인증 상태 1 → 영수증 9 → 채널별 6 × N)
  var headerValues = [
    '캠페인 번호', '캠페인 제목',
    '이름(한자)', '이름(가타카나)', '계정 아이디(이메일)', 'Instagram URL', 'TikTok URL', 'X URL', 'YouTube URL',
    '인증 상태',
    '타입', '제출일', '검수일', '상태', '주문번호', '구매일', '구매금액', '이미지', 'URL'
  ];
  channels.forEach(function() {
    headerValues.push('타입', '제출일', '검수일', '상태', '이미지', 'URL');
  });
  ws.getRow(4).values = headerValues;
  ws.getRow(4).font = {bold:true, color:{argb:'FF222222'}};
  ws.getRow(4).fill = {type:'pattern', pattern:'solid', fgColor:{argb:'FFF0F0F0'}};
  ws.getRow(4).alignment = {vertical:'middle', horizontal:'center'};
  ws.getRow(4).height = 24;

  var colWidths = [
    18, 28,
    18, 18, 28, 36, 36, 36, 36,
    14,                                  // 인증 상태
    12, 12, 12, 10, 18, 12, 12, 16, 32
  ];
  channels.forEach(function() { colWidths.push(12, 12, 12, 10, 16, 32); });
  ws.columns = colWidths.map(function(w) { return {width:w}; });

  var statusLabelMap = {pending:'검수대기', approved:'승인', rejected:'반려'};
  var renderDeliv6 = function(d) {
    if (!d) return ['', '', '', '', '', ''];
    var sub = d.submitted_at ? new Date(d.submitted_at).toLocaleDateString('ko-KR') : '';
    var rev = d.reviewed_at ? new Date(d.reviewed_at).toLocaleDateString('ko-KR') : '';
    var st = statusLabelMap[d.status] || d.status || '';
    var urlVal = '';
    if (d.receipt_url) {
      var iu = /^https?:\/\//.test(d.receipt_url) ? d.receipt_url
        : (db?.storage?.from ? db.storage.from('campaign-images').getPublicUrl(d.receipt_url)?.data?.publicUrl : d.receipt_url);
      urlVal = {text:iu, hyperlink:iu};
    }
    return ['리뷰 이미지', sub, rev, st, '', urlVal];
  };
  var renderReceipt9 = function(d) {
    if (!d) return ['', '', '', '', '', '', '', '', ''];
    var base = renderDeliv6(d);
    base[0] = '영수증';
    var orderNo = d.order_number || '';
    var purchaseDate = d.purchase_date || '';
    var amt = (d.purchase_amount === null || d.purchase_amount === undefined || d.purchase_amount === '')
      ? '' : Number(d.purchase_amount);
    return [base[0], base[1], base[2], base[3], orderNo, purchaseDate, amt, base[4], base[5]];
  };

  // 본문
  groupList.forEach(function(g, i) {
    var rowNum = 5 + i;
    var u = userById[g.user_id] || {};
    var cc = g.camp || {};
    var row = ws.getRow(rowNum);
    row.height = 84;

    var receiptCells = renderReceipt9(g.receipt);
    var vals = [
      cc.campaign_no || '', cc.title || '',
      u.name_kanji || u.name || '—',
      u.name_kana || '',
      u.email || '',
      _excelSnsUrl('instagram', u.ig),
      _excelSnsUrl('tiktok', u.tiktok),
      _excelSnsUrl('x', u.x),
      _excelSnsUrl('youtube', u.youtube),
      // 인증 상태 1컬럼 (certCol=10) — monitor: 영수증 승인 + 채널별 대표 상태 approved 면 인증성공
      _excelCertStatusMonitorKo(channels, g.receipt, g.reviewByCh),
      // 영수증 9컬럼
      receiptCells[0], receiptCells[1], receiptCells[2], receiptCells[3], receiptCells[4], receiptCells[5], receiptCells[6], receiptCells[7], receiptCells[8]
    ];
    channels.forEach(function(ch) {
      var cells = renderDeliv6(g.reviewByCh[ch]);
      vals.push(cells[0], cells[1], cells[2], cells[3], cells[4], cells[5]);
    });
    row.values = vals;
    row.alignment = {vertical:'middle', wrapText:true};

    var linkCols = [receiptEnd];  // 영수증 URL
    channels.forEach(function(_, ci) {
      linkCols.push(chBase + 1 + ci * CH_COLS + 5);
    });
    linkCols.forEach(function(col) {
      var cell = row.getCell(col);
      if (cell && cell.value && cell.value.hyperlink) cell.font = {color:{argb:'FFE8344E'}, underline:true};
    });

    if (g.receipt && imgBuffers[g.receipt.id]) {
      var rImgId = wb.addImage({buffer:imgBuffers[g.receipt.id].buffer, extension:imgBuffers[g.receipt.id].ext});
      var imgColL = _excelColLetter(receiptImgCol);
      ws.addImage(rImgId, imgColL + rowNum + ':' + imgColL + rowNum);
    }
    channels.forEach(function(ch, ci) {
      var d = g.reviewByCh[ch];
      if (d && imgBuffers[d.id]) {
        var dImgId = wb.addImage({buffer:imgBuffers[d.id].buffer, extension:imgBuffers[d.id].ext});
        var imgCol = chBase + 1 + ci * CH_COLS + 4;
        var imgColL = _excelColLetter(imgCol);
        ws.addImage(dImgId, imgColL + rowNum + ':' + imgColL + rowNum);
      }
    });
  });

  return ws;
}



// 마이그레이션 160: 엑셀 대리 등록 사유 코드 → 한국어 라벨 (시드 4건 인라인, 관리자 엑셀 한국어 UI)
function _excelProxyReasonKo(code) {
  if (!code) return '—';
  var map = {
    shipping_delay:      '배송 지연',
    system_error:        '시스템 오류',
    inflexible_deadline: '기간 외 합의 처리',
    other:               '기타'
  };
  return map[code] || code;
}

// ─── 인플루언서 목록 엑셀 ──────────────────────────────────────────
// 현재 필터(주소지/팔로워/채널/인증/위반/검색)가 적용된 인플 목록을 엑셀로.
//   기본 열: 모든 관리자. 민감정보 열(전화·LINE·PayPal·상세주소): campaign_admin 이상 + 「민감정보 포함」 체크 시.
//   ⚠ fetchInfluencers 가 select('*') 라 민감정보는 이미 전 관리자 클라 메모리에 있음 → 본 권한 분기는 엑셀 출력 표시 제한 수준
//     (실데이터 차단은 RLS/뷰 컬럼 마스킹 별도 과제). 사양서 docs/specs/2026-06-04-influencer-combo-filter.md 의심 9번.
async function exportInfluencersExcel() {
  if (!_checkExportAllowed()) return;
  var rows = (typeof getFilteredInfluencersForView === 'function') ? getFilteredInfluencersForView() : [];
  if (!rows.length) { toast('내보낼 인플루언서가 없습니다', 'warn'); return; }
  if (!(await _confirmLargeExport(rows.length))) return;

  var canSensitive = (typeof isCampaignAdminOrAbove === 'function') && isCampaignAdminOrAbove();
  var includeSensitive = canSensitive && !!(document.getElementById('infExcelSensitive') && document.getElementById('infExcelSensitive').checked);

  _markExportStart();
  try {
    await loadExcelJS();
    var wb = new ExcelJS.Workbook();
    var ws = wb.addWorksheet('인플루언서');
    var cols = [
      { header: '이름(한자)', key: 'kanji', width: 14 },
      { header: '이름(가나)', key: 'kana', width: 16 },
      { header: '이메일', key: 'email', width: 24 },
      { header: '대표SNS', key: 'primary', width: 10 },
      { header: 'Instagram', key: 'ig', width: 28 },
      { header: 'IG 팔로워', key: 'igf', width: 11 },
      { header: 'X(Twitter)', key: 'x', width: 24 },
      { header: 'X 팔로워', key: 'xf', width: 11 },
      { header: 'TikTok', key: 'tt', width: 24 },
      { header: 'TikTok 팔로워', key: 'ttf', width: 12 },
      { header: 'YouTube', key: 'yt', width: 24 },
      { header: 'YT 팔로워', key: 'ytf', width: 11 },
      { header: '합계 팔로워', key: 'total', width: 12 },
      { header: '도도부현', key: 'pref', width: 12 },
      { header: '시군구', key: 'city', width: 16 },
      { header: '등록일', key: 'created', width: 12 }
    ];
    if (includeSensitive) {
      cols.push(
        { header: '전화번호', key: 'phone', width: 16 },
        { header: 'LINE', key: 'line', width: 16 },
        { header: 'PayPal', key: 'paypal', width: 24 },
        { header: '우편번호', key: 'zip', width: 12 },
        { header: '건물명', key: 'building', width: 18 },
        { header: '상세주소', key: 'address', width: 30 }
      );
    }
    ws.columns = cols;
    ws.getRow(1).font = { bold: true };

    rows.forEach(function (u) {
      var nm = _excelInfluencerNameParts(u);
      var row = {
        kanji:   nm.kanji,
        kana:    nm.kana,
        email:   u.email || '',
        primary: u.primary_sns || '',
        ig:      _excelSnsUrl('instagram', u.ig),
        igf:     u.ig_followers || 0,
        x:       _excelSnsUrl('x', u.x),
        xf:      u.x_followers || 0,
        tt:      _excelSnsUrl('tiktok', u.tiktok),
        ttf:     u.tiktok_followers || 0,
        yt:      _excelSnsUrl('youtube', u.youtube),
        ytf:     u.youtube_followers || 0,
        total:   (u.ig_followers || 0) + (u.x_followers || 0) + (u.tiktok_followers || 0) + (u.youtube_followers || 0),
        pref:    u.prefecture || '',
        city:    u.city || '',
        created: u.created_at ? formatDate(u.created_at) : ''
      };
      if (includeSensitive) {
        row.phone    = u.phone || '';
        row.line     = u.line_id || '';
        row.paypal   = u.paypal_email || '';
        row.zip      = _excelZip(u);
        row.building = u.building || '';
        row.address  = _excelAddressOnly(u, u.address);
      }
      ws.addRow(row);
    });

    var buf = await wb.xlsx.writeBuffer();
    var blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
    var url = URL.createObjectURL(blob);
    var aEl = document.createElement('a');
    aEl.href = url;
    var ts = new Date();
    var ymd = ts.getFullYear() + String(ts.getMonth() + 1).padStart(2, '0') + String(ts.getDate()).padStart(2, '0');
    aEl.download = 'influencers-' + rows.length + '-' + ymd + '.xlsx';
    document.body.appendChild(aEl); aEl.click(); document.body.removeChild(aEl);
    URL.revokeObjectURL(url);
    toast('엑셀 다운로드 완료 (' + rows.length + '명' + (includeSensitive ? ', 민감정보 포함' : '') + ')');
  } catch (e) {
    toast('엑셀 생성 실패: ' + friendlyError(e.message || e), 'error');
  } finally {
    _markExportEnd();
  }
}
