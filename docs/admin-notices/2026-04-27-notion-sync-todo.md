# 노션 반영 To-Do (2026-04-27 운영 배포 5종)

> **컨텍스트**: 2026-04-27 PR #125·#126·#127·#128·#129 일괄 운영 배포에 따라 `docs/OPERATOR_GUIDE.md` 가 갱신됨. Notion 페이지(실무자 가이드)도 동기화 필요.
>
> **현재 상태**: 로컬 문서는 모두 갱신 완료. **Notion 미반영**. Notion MCP 서버 disconnected 상태에서 작업 중단됨.
>
> **이 파일의 용도**: MCP 재연결 후 다음 세션에서 Claude가 이 파일을 읽고 노션 페이지 fetch → 변경 전/후 diff 안내 → 사용자 검수 후 수정 진행

---

## 영향받는 OPERATOR_GUIDE 섹션 (Notion 동기화 대상)

### 🔵 신규 추가

**상단 변경 요약 패널** (목차 위)
- 2026-04-27 업데이트 4줄 신규 추가 (캠페인 폼 날짜 / 공지 게시 분리 / 브랜드 서베이 단계 순서 / 입금 계좌)
- 위치: 2026-04-22 업데이트 요약 박스 **바로 위**

### ✏️ 수정

**§3-5 캠페인 상태**
- 변경: 자동 시작 박스 신규 추가 (자동 종료 박스 바로 아래)
- 내용: scheduled 캠페인의 모집 시작일 도래 시 active 자동 전환

**§4-2 캠페인 등록 폼 — 기본정보 섹션**
- 입력 항목 표 전체 교체:
  - 모집 타입·정원·카테고리 → "기본정보" 섹션으로 이동했음 표시
  - "모집 기간 (recruit_start ~ deadline)" 신규 행 (range picker)
  - "결과물 제출 마감일" 행에 "모집 마감일 +14일 자동 추천" 표기
  - "구매 기간"·"방문 기간" 행 — range picker로 변경
- 인사이트 박스 4개 신규/교체:
  - 캠페인 상태 드롭다운 위치 변경 (2026-04-16) — **유지**
  - 날짜 입력 방식 변경 (2026-04-27) — **신규**
  - 모집 시작일 신규 (2026-04-27) — **신규**
  - monitor 콘텐츠 자동 필터링 (2026-04-27) — **신규**

**§4-5 모집조건 섹션**
- 상단에 "2026-04-27 변경: 모집 타입·정원·카테고리는 §4-2 기본정보로 이동" 안내 추가
- 콘텐츠 종류 행에 "리뷰어(monitor) 캠페인일 때 영상·이미지 위주 자동 필터링" 표기

**§12-4 브랜드 서베이 상태 9단계**
- 표 행 순서 재정렬 (이전: schedule_sent → quoted → orient → register → paid → done / 변경 후: quoted → paid → orient_sheet_sent → schedule_sent → campaign_registered → done)
- 표 위에 "2026-04-27 표시 순서 재정렬, DB 데이터·status 값 동일" 안내 박스

**§16 공지사항 시스템 — §16-2 사용법 전체 교체**
- 리스트 화면 필터에 "게시 상태(전체/게시/초안)" 필터 추가
- 미읽음 배지/팝업 절: "published만 카운트" 명시 + "확인 버튼 → 상세 보기 단일 버튼" 변경
- 공지 등록·수정 절차: "[초안 저장] / [게시하기] 두 버튼" + "이미 게시된 공지 수정 시 [게시 유지하며 저장] / [초안으로 되돌리고 저장]" 분기 + "보기 화면 [지금 게시] / [게시 회수]" 토글
- 대시보드 카드: "published 만 노출" 명시
- 재게시 시 미읽음 미리셋 정책 추가

---

## MCP 재연결 후 작업 절차 (Claude가 자동 수행)

1. **노션 페이지 식별**: `mcp__claude_ai_Notion__notion-search` 로 "REVERB JP 실무자 운영 가이드" 또는 "OPERATOR_GUIDE" 키워드 검색 → 페이지 ID 확정
2. **현재 노션 본문 fetch**: `mcp__claude_ai_Notion__notion-fetch` 로 페이지 전체 가져와 위에 나열된 5개 섹션의 변경 전 텍스트 캡처
3. **diff 안내 생성**: 각 섹션마다 "변경 전 (현 노션)" vs "변경 후 (OPERATOR_GUIDE.md)" 표 형태 안내
4. **AskUserQuestion으로 검수 요청**:
   - "이대로 적용 / 부분 수정 / 보류" 중 선택
   - 각 섹션별 개별 검수 권장
5. **승인된 변경만** `mcp__claude_ai_Notion__notion-update-page` 로 적용
6. **마커 갱신**: OPERATOR_GUIDE.md 의 `<!-- NOTION:PENDING -->` → `<!-- NOTION:SYNCED 2026-04-XX -->` (사용자 확인 후)
7. **Notion 오탈자 점검**: 반영된 본문에서 `node .claude/hooks/typo-scan.js` 패턴 grep — Notion MCP 유니코드 이스케이프 ghost 오탈자 위험 (interaction.md 규칙). 점검 단어 목록은 `.claude/hooks/typo-patterns.js` 의 `GENERAL` + `DOMAIN_REVERB_JP` 배열 참조

---

## MCP 재연결 방법 안내 (사용자용)

Claude Code 세션에서 Notion MCP 가 disconnected 됐을 때:

1. **세션 종료 후 재시작** — 가장 단순. Claude Code 를 끄고 다시 켜면 MCP 서버 자동 재연결 시도
2. **`/mcp` 명령으로 상태 확인** — Claude Code 안에서 `/mcp` 입력하면 현재 연결된 MCP 서버 목록 + 상태 표시
3. **OAuth 만료 가능성** — `claude_ai_Notion` MCP 는 Anthropic 공식 커넥터로 OAuth 인증 사용. 토큰 만료 시 재인증 화면 자동 노출
4. **그래도 안 되면** Claude.ai 웹 → 설정 → Connectors → Notion 재연결

재연결 확인 후 이 세션에서 다시 "노션 반영 진행해줘" 또는 "이 To-Do 파일 보고 진행" 요청만 주시면 위 절차대로 진행하겠습니다.

---

## 참고: 직접 수정 시 가이드 (MCP 재연결 안 될 때)

Notion 에서 손으로 수정하시려면 위 "영향받는 섹션" 5개를 OPERATOR_GUIDE.md 해당 섹션에서 복사해 그대로 교체하시면 됩니다. 위치 표시(§3-5, §4-2, §4-5, §12-4, §16) 그대로 노션 페이지에서 찾아갈 수 있도록 해뒀습니다.

**오탈자 주의**: 노션 MCP 사용 시 유니코드 이스케이프 ghost 오탈자가 종종 발생합니다. 붙여넣은 후 `node .claude/hooks/typo-scan.js` 의 패턴 단어들로 본문 검색해서 점검하세요. 점검 단어 목록은 `.claude/hooks/typo-patterns.js` 의 `GENERAL` + `DOMAIN_REVERB_JP` 배열을 참조 (현재 20개 등록).
