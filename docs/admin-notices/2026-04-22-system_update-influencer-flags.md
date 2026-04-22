---
category: system_update
title: 인플루언서 인증·위반·블랙 관리 기능 추가
is_pinned: false
generated_at: 2026-04-22
source_pr: 109
---

# 인플루언서 인증·위반·블랙 관리 기능 추가

## 본문 HTML (Quill 붙여넣기용)

```html
<p>관리자 페이지에 인플루언서 상태를 직접 관리할 수 있는 기능이 추가되었습니다. DB 마이그레이션 059~062 가 개발·운영 서버 모두 적용 완료된 상태입니다.</p>
<p><strong>주요 변경</strong></p>
<ul>
  <li>인플루언서 이름 옆에 <strong>인증 / 위반 카운트 / 블랙리스트</strong> 상태 배지가 전역 노출 (목록·신청 관리·캠페인 신청자·결과물 관리·상세 모달)</li>
  <li>인플루언서 이름을 클릭하면 어디서든 동일한 풀 상세 모달이 열리도록 통합 (기존 간이 모달 삭제)</li>
  <li>상세 모달 안에서 <strong>인증 토글 · 위반 등록 · 블랙리스트 등록/해제</strong>를 한 화면에서 처리. 관리자 이력은 같은 카드 하단에 누적 pill + 타임라인 + 편집 아이콘으로 정리</li>
  <li>위반 기록에 <strong>증빙 이미지/PDF 복수 첨부</strong> 가능. 썸네일 클릭 시 라이트박스 확대. 파일은 비공개 버킷 <code>influencer-flag-evidence</code> 에 저장</li>
  <li>인플루언서 목록 필터를 상단으로 이관: 채널·인증·위반 상태 드롭다운 + 이름·이메일·SNS 핸들 검색 추가</li>
  <li>캠페인 · 신청자 목록에도 동일 스펙 검색창 추가</li>
  <li>모든 모달은 ESC 키로 닫기 가능</li>
</ul>
<p><strong>영향 범위</strong>: 관리자 페이지 한정. 인플루언서 앱·광고주 페이지에는 영향 없음.</p>
<p><strong>권한</strong>: 배지 조회는 모든 관리자. 인증/위반/블랙 조작은 <code>campaign_admin</code> 이상.</p>
```

## 등록 안내
관리자 페이지 → `공지사항` 메뉴 → `새 공지 작성` → 카테고리 `시스템 업데이트` 선택 → 제목·본문 복사 붙여넣기.

## 근거 커밋
- `3a1655b` feat(admin): influencer verify · violation · blacklist management
- `88d6d3e` feat(admin): violation evidence uploads + ESC close + status UI cleanup
- PR #109: feat(admin): influencer verify · violation · blacklist + evidence uploads
