# HANDOFF — 메인 폴더 코드 수정 경고 후크

**작성:** 2026-06-05 (고문 세션)
**대상:** 개발 세션
**목적:** 개발 세션이 **메인 폴더**(`~/Documents/projects/reverb-jp`)에서 코드 파일을 수정하기 시작하면 "worktree로 분리하라"는 **경고**를 띄운다. 차단이 아니라 경고(단독 시퀀셜 작업은 무시하고 진행 가능). 규칙 근거: `.claude/rules/session-roles.md` §1.
**배경:** 2026-06-05 이 세션 작업 중 개발 세션이 메인 폴더 작업트리에 코드 커밋을 여러 번 쌓는 게 실시간으로 관찰됨(`30c5689`·`23f21b2`·`b25dc7d` 등). 규칙 문서만으로는 안 막혀 경고 후크가 필요.

---

## 설계

### 트리거
- `PreToolUse`, matcher `Write|Edit`(필요시 `MultiEdit` 추가).
- 기존 `frontend-skill-reminder` 후크와 같은 등록 패턴(`.claude/settings.json` PreToolUse). 그 파일을 참고 구현체로 삼을 것.

### 발동 조건 (모두 충족 시 경고)
1. **현재 작업트리가 메인 폴더**일 것 — worktree가 아님.
   - 판정: worktree는 `.git`이 **파일**(gitdir 포인터), 메인 폴더는 `.git`이 **디렉토리**. `[ -d .git ]` 로 메인 폴더 판정. (또는 `git rev-parse --show-toplevel` 결과가 `~/Documents/projects/reverb-jp` 와 정확히 일치)
2. **수정 대상 파일이 코드성**일 것 — 후크에 전달되는 도구 입력의 파일 경로가 `dev/`, `supabase/` 로 시작(빌드 산출물 `index.html`/`admin/index.html` 포함). 
   - **거버넌스 문서는 제외**: `.claude/rules/`, `docs/`, 메모리 경로는 경고하지 않음 (고문/기획이 메인 폴더에서 직접 수정·커밋하는 게 정상이므로).
3. **세션 1회만** 경고 — 기존 `frontend-skill-reminder` 의 once-per-session 패턴(임시 플래그 파일 등) 재사용.

### 동작
- 경고 메시지(stderr 또는 후크 출력)만 내고 **차단하지 않음**(exit 0, 도구 실행 허용).
- 메시지 예시(한국어):
  ```
  ⚠️ 메인 폴더에서 코드 파일 수정이 감지됐습니다.
     다른 세션과 동시 작업 중이면 /새세션 으로 worktree(별도 작업 폴더)를 분리하세요.
     혼자 시퀀셜 작업이면 이 경고는 무시하고 진행해도 됩니다.
     (규칙: .claude/rules/session-roles.md §1)
  ```

### 주의
- **차단 모드 아님** — 단독 시퀀셜 작업도 막으면 기존 규칙(`multi-session.md` "혼자면 메인 OK")과 충돌. 반드시 경고만.
- 후크가 "다른 세션이 떠 있는지"는 알 수 없음 → 조건 1·2만으로 발동하고, 단독 작업자는 경고를 무시하는 설계가 맞음(완벽 강제 아님, 상기 역할).

---

## 검증 (개발 세션이 수행)
1. 메인 폴더에서 `dev/js/*.js` 를 Edit → 경고가 1회 뜨는지.
2. 같은 세션에서 두 번째 Edit → 경고가 **다시 안 뜨는지**(once-per-session).
3. 메인 폴더에서 `.claude/rules/*.md` 수정 → 경고가 **안 뜨는지**(거버넌스 문서 제외).
4. worktree에서 `dev/js/*.js` 수정 → 경고가 **안 뜨는지**(메인 폴더 아님).
5. 후크 자체 오류로 도구가 막히지 않는지(어떤 경우도 exit 0).

## 커밋
- 후크 스크립트(`.claude/hooks/` 또는 기존 후크 위치) + `.claude/settings.json` 등록.
- `docs(hooks): warn on code edits in main folder (advise worktree split)`
- reverb-reviewer: 후크 스크립트는 실행 코드이므로 **호출 권장**(stale 참조·exit code 안전성).

## 주의
- 본 HANDOFF는 구현 완료 후 삭제 무방.
