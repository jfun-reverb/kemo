# Notion 동기화 규칙

> `docs/OPERATOR_GUIDE.md`는 실무자용 가이드의 **원본(source of truth)**. 사용자가 이 문서를 수동으로 Notion에 복사해서 실무자에게 배포한다.
> 따라서 변경 시 **Notion에 붙여넣을 부분을 명확히 구분**해야 한다.

## 원칙

1. **신규 섹션 추가**: 추가된 섹션 번호를 응답 끝에 "Notion에 추가할 블록"으로 명시
2. **기존 섹션 수정**: "변경 전 → 변경 후" diff를 응답 끝에 제시
3. **여러 섹션 동시 수정**: 각각을 별도 블록으로 구분

## 응답 포맷 (필수)

문서 수정 완료 시 아래 형식으로 **응답 말미에** Notion 반영 안내 추가:

```
---
📋 **Notion 반영 필요**

### 신규 추가
- §N. <제목> (OPERATOR_GUIDE.md lines ...)
  → Notion 페이지에 새 섹션 추가

### 수정
- §N-M <제목>
  변경 전: "..."
  변경 후: "..."
  → Notion 해당 블록 교체

### 삭제
- §N-M <제목>
  → Notion 해당 블록 제거
---
```

## 마커 컨벤션

`OPERATOR_GUIDE.md` 내에서 Notion 동기화 상태 추적:
- 각 주요 섹션(`# N. <제목>`) 바로 아래에 HTML 주석으로 동기화 상태 표시
- 예: `<!-- NOTION:SYNCED 2026-04-15 -->` / `<!-- NOTION:PENDING -->`
- 사용자가 Notion에 반영 완료 후 PENDING → SYNCED 수동 갱신 (Claude가 임의 변경 금지)

## 적용 시점

- `OPERATOR_GUIDE.md` 섹션 추가·수정 커밋을 할 때마다
- 동일 커밋에 다른 내부 문서(CLAUDE.md, FEATURE_SPEC.md 등) 변경이 섞여 있어도 **OPERATOR_GUIDE 변경분만** Notion 블록에 포함

## 예외
- `OPERATOR_GUIDE.md`의 오탈자/단순 표현 정정은 Notion 블록 생략 가능 (메시지로 "Notion 쪽도 같은 오탈자 확인 바람"만 안내)
- 템플릿/포맷 변경(섹션 번호 재정리 등)은 "Notion 페이지 전체 재복사 권장" 한 줄 안내
