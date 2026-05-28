# 운영 일괄 배포 실행 체크리스트 (②경로 — 약관 통지 동시 출시)

> 작성일: 2026-05-28 (개발 세션)
> 배경: dev에 130커밋이 쌓였고 거의 전부 "의도적 운영 보류". 진짜 게이트는 **문의하기/FAQ 노출 = 약관 통지 필요** 하나뿐. 다국어(i18n)는 이미 운영 배포돼 있어 화면 깨짐 리스크 없음(2026-05-28 git 확정).
> 사용자 결정(2026-05-28): **즉시 시행 방식**(앱 공지만, 메일 미발송) + **dev 준비만 먼저, 배포일은 검증 후 결정**. 통지 게시일 = 시행일 = 본체 출시일이 모두 같은 날.

---

## 현재 운영(main) 실태 (2026-05-28 git 확정)

| 항목 | 운영 배포 |
|---|---|
| 다국어(日/韓) 인프라 (`window.t`/`I18N_JA`) | ✅ 이미 있음 |
| 캠페인 신청 카운트 집계 | ✅ 배포됨 |
| 마이그레이션 | 151까지 적용 |
| 관리자 홍보메일 (152 + Edge Function) | ✅ 운영 DB·함수만 적용(코드 형상은 dev) |
| 관리자 코드 분리(16파일) | ❌ 운영은 단일 `admin.js` |
| 약관 통지 / 문의하기 / FAQ / 캠페인 종료(156) | ❌ 운영에 전혀 없음 |

dev 구현·검증 완료(운영 미배포): 문의하기(144·145), FAQ 자동응답+인플 게이트 화면(146·155), 승인 알림(154), 약관 통지·앱 공지(153), 브랜드 운영현황(147·148·149·150), 캠페인 종료 상태(156), 관리자 코드 분리(DB 무관).

---

## 0. 배포일(= 시행일) 확정
- `D` = 운영 출시일 (이 값이 정해져야 아래 1번 실행 가능)

---

## 1. 시행일 의존 항목 수정 (dev, D 확정 시 — "1줄 수정 위치")

- [ ] `dev/lib/shared.js:518` — `effectiveDate: '2026-05-27'` → `'D'`(운영 출시일)
- [ ] 약관 4종 부칙에 **메시지(문의하기) 개정 항목 + 시행일 D** 추가
  - `docs/TERMS_kr.md:225~`, `docs/TERMS_ja.md:225~`, `docs/PRIVACY_kr.md:212~`, `docs/PRIVACY_ja.md:212~`
  - 현재 "시행일 2026년 5월 1일"만 있고 메시지 개정 부칙 누락 (본문 §8-2 A~E는 PR #302에서 반영 완료)
- [ ] 통지 문안 `docs/notices/2026-05-27-message-feature-notice.md` — `{시행일}` 2곳(일 61줄·한 134줄) 치환 + **"+30일로 치환" 주석(147줄) 정리**(30일 통지 시절 잔재, 즉시 시행과 불일치)
  - ※ 앱 공지는 하드코딩 컴포넌트(PR #308). 이 md가 앱에 직접 쓰이는지 확인 — 메일 미발송이면 참고용
- [ ] `cd dev && bash build.sh` → 루트 `index.html`·`admin/index.html` 재빌드
- [ ] `reverb-reviewer` + `/약관확인` (한·일 일치)

---

## 2. 운영 도쿄 DB 마이그레이션 적용 (SQL Editor, pooler)
> pooler: `aws-1-ap-northeast-1.pooler.supabase.com:5432`, user `postgres.nrwtujmlbktxjgdwlpjj`
> **1단계씩 순차 적용 + 결과 확인**(`.claude/rules/supabase.md` SQL 순차 안내). 152는 이미 운영 적용됨 → 건너뜀.

- [ ] **147** 회사 백필 (멱등) — 적용 전 검증 SQL로 생성될 회사 수 확인
- [ ] **148·149·150** 브랜드 운영현황 함수 재정의(테이블 추가 없음) — 적용 후 스모크 호출
- [ ] **144** 문의하기 — ⚠️ Storage 버킷 `application-message-attachments` 도쿄 존재 여부 먼저 확인
- [ ] **145** 문의하기 PR2 — 신규 함수 스모크
- [ ] **146** FAQ — 신규 함수 스모크
- [ ] **153** 정책 통지 로그
- [ ] **154** 승인 알림 트리거
- [ ] **155** FAQ 문구 정정
- [ ] **156** 캠페인 종료 상태 — 적용 전 `closed→ended` 백필 대상 건수 확인

---

## 3. Edge Function 운영 배포
- [ ] `notify-policy-change`: 메일 미발송 결정 → **운영 호출 안 함**(cron 아닌 수동 호출이라 배포만 해도 발송 안 됨). 보존용 배포는 선택
- [ ] `notify-campaign-promo-digest`·`notify-admin-daily-digest`: 이미 운영 배포됨(152 작업) — dev→main 머지로 코드 형상만 동기화

---

## 4. dev → main 머지
- [ ] `reverb-reviewer` GO
- [ ] `reverb-qa-tester` full (인증/응모/문의하기 플로우 — main merge 직전)
- [ ] dev → main PR 생성
- [ ] 충돌은 빌드 산출물(`index.html`/`admin/index.html`)뿐 → `origin/main` 머지 후 재빌드로 해소
- [ ] 머지 (Netlify 체크 fail은 미사용 잔존 → Vercel만 확인. 필요 시 `gh pr merge --admin`)

---

## 5. 운영 검증 (배포 직후)
- [ ] 앱 공지: 로그인 1회 팝업 + 홈 배너 노출, 시행일 표기 정확
- [ ] 문의하기: 응모이력 카드 진입 → 텍스트·이미지 발신 → 25분 내 회수
- [ ] FAQ 게이트: 문의 입력 중 유사 질문 제안 + 확인 시트
- [ ] 캠페인 종료 상태: 관리자 목록 모집마감/종료 분리, 인플 終了 오버레이
- [ ] 브랜드 운영현황: `#brand-ops` 카드·사유 배너·미니카드
- [ ] 약관 4종 `#page-legal` 한·일 노출 + 부칙 시행일
- [ ] 관리자 화면 전반 정상 (16파일 분리 후 회귀 없음)
- [ ] 메일 발송 검증은 운영에서만 (`feedback_dev_no_mail_test`)
- 운영 curl 확인은 `-L` 필수 (apex→www 307, `feedback_prod_curl_follow_redirect`)

---

## 참고
- 관련 메모리: `project_pending_features_prod_deploy`, `project_message_policy_notice`, `project_message_faq`, `project_admin_promo_and_digest_sns`, `project_faq_accuracy_fix`
- 보안 후속(도쿄 컷오버 공통): 도쿄 DB password·service_role·Brevo API 키 재생성, 시드니 1주 보존 후 폐기
