---
description: REVERB JP 프로젝트 전체 맥락 로드 (CLAUDE.md + PROJECT_CONTEXT.md + 최근 git log)
---

다음 순서로 파일을 읽고 현재 프로젝트 상황을 요약해주세요:

1. `CLAUDE.md` — 프로젝트 전반 규칙
2. `docs/PROJECT_CONTEXT.md` — 비즈니스/법률/데이터 모델 맥락
3. `.claude/rules/*.md` — 세부 규칙 (supabase, security, git, ui, build, quality)
4. 최근 git 커밋 10개 (`git log --oneline -10`)
5. 현재 브랜치 (`git branch --show-current`)

요약 출력 형식:
- **프로젝트 개요** (1~2문장)
- **현재 작업 중 브랜치 + 최근 진행** (커밋 제목 기반)
- **아직 미해결 이슈** (PROJECT_CONTEXT §7 "❌ 미구현" 기준)
- **최근 수정된 영역** (커밋 로그 기반 추론)

요약 끝에 "무엇을 도와드릴까요?" 질문으로 마무리.
