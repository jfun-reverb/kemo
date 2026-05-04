/**
 * 한국어 오탈자 패턴 — 단일 source of truth.
 * 변경 시 memory/feedback_korean_typos.md와 동기화.
 *
 * GENERAL: 모든 프로젝트 공통 (글로벌 hook에서도 재사용)
 * DOMAIN:  REVERB JP 전용 도메인 단어
 */

// 일반 한국어 오탈자 (false positive 위험 낮은 확정 단어만)
const GENERAL = [
  { bad: '캐페인', good: '캠페인' },
  { bad: '캐웩인', good: '캠페인' },
  { bad: '캠패인', good: '캠페인' },
  { bad: '켐페인', good: '캠페인' },
  { bad: '행버거', good: '햄버거' },
  { bad: '재생각', good: '다시 생각' },
  { bad: '돿습', good: '됐습' },
  { bad: '바뀍니다', good: '바뀝니다' },
  { bad: '뗴다가', good: '떼다가' },
  { bad: '컨텐츠', good: '콘텐츠' },
  { bad: '메세지', good: '메시지' },
  { bad: '뮤티', good: '뷰티' },
  { bad: '팔로움', good: '팔로워' },
  { bad: '컴럼', good: '컬럼' },
  { bad: '부와다니', good: '옮겨졌' },
  { bad: '마카일 기록', good: '명확한 표현으로 다시 작성' },
  { bad: '좌혀짐', good: '좁혀짐' },
  { bad: '캐프처', good: '캡처' },
  { bad: '굕이', good: '굳이' },
  { bad: '굾이', good: '굳이' },
  { bad: '주이항', good: '주의사항' },
  { bad: '높곐널', good: '끊길' },
  { bad: '합컴 저장', good: '합쳐 저장' },
  { bad: '추촜', good: '추천' }
];

// 프로젝트 도메인 단어
const DOMAIN_REVERB_JP = [
  { bad: '오리엔씨트', good: '오리엔시트' },
  { bad: '오리엔트시트', good: '오리엔시트' },
  { bad: '오리엔테이션 시트', good: '오리엔시트' },
  { bad: '현장 없음', good: '현재 없음' }
];

const ALL = [...GENERAL, ...DOMAIN_REVERB_JP];

// 한글 포함 라인만 매칭 (영어/일본어/순수 ASCII 라인은 무시)
const HANGUL_RE = /[가-힯]/;

/**
 * 텍스트에서 오탈자 검출.
 * @param {string} text  검사할 텍스트
 * @param {Array<{bad,good}>} patterns  패턴 리스트 (default: ALL)
 * @returns {Array<{bad, good, count, sample}>}
 */
function findTypos(text, patterns = ALL) {
  if (!text || typeof text !== 'string') return [];

  // 한글 포함 라인만 필터
  const hangulLines = text.split('\n').filter((line) => HANGUL_RE.test(line));
  if (hangulLines.length === 0) return [];
  const haystack = hangulLines.join('\n');

  const hits = [];
  for (const { bad, good } of patterns) {
    // 단순 substring 매칭 — 한글 단어 경계는 정규식으로 표현 어려움
    let count = 0;
    let sample = '';
    let idx = 0;
    while ((idx = haystack.indexOf(bad, idx)) !== -1) {
      count++;
      if (!sample) {
        // 주변 30자 컨텍스트 추출
        const start = Math.max(0, idx - 30);
        const end = Math.min(haystack.length, idx + bad.length + 30);
        sample = haystack.slice(start, end).replace(/\n/g, ' ');
      }
      idx += bad.length;
    }
    if (count > 0) hits.push({ bad, good, count, sample });
  }
  return hits;
}

module.exports = {
  GENERAL,
  DOMAIN_REVERB_JP,
  ALL,
  findTypos
};
