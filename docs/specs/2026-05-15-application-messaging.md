# 인플루언서 ↔ 관리자 양방향 메시지 (응모건 단위)

**작성일:** 2026-05-15
**작성자:** 기획 세션
**구현 담당:** 개발 세션 (TBD)
**예상 마이그레이션:** 129 이후 (영수증 필수 입력 128 다음 — 구현 시점에 가장 최신 마이그레이션 번호+1 재확인)
**관련 사양서:** 없음 (신규)

---

## 1. 배경 / 문제

### 현재 상태
- 인플루언서 ↔ 운영팀 개별 문의는 **LINE @reverb.jp** 로 받는 중. 캠페인 상세·홈 풋터에 LINE CTA 노출
- 시스템 자동 알림(`notifications`) 은 결과물 검수 결과 등 단방향만
- 응모 시 인플루언서 → 관리자 1회 메시지(`applications.message`) 가 있지만 답장 불가
- 결과물 반려 사유(`reject_reason`) 는 있지만 「왜요?」 같은 후속 질문 채널 없음

### 문제
- LINE 상담 이력이 시스템 밖에 있어 **검색·통계·인수인계 불가**. 담당자 변경 시 맥락 단절
- 「이 응모건 관련 문의」가 어떤 응모인지 LINE에서 매번 확인해야 함 (인플루언서가 「캠페인 이름」 + 「본인 이름」 매번 입력)
- 캠페인 종료 후 분쟁 발생 시 LINE 대화 증빙 어려움
- 일본 거주자가 LINE 비사용자면 진입 장벽

### 목표
- 응모건 단위 1대1 대화방을 앱 안에서 운영
- 검색·통계·인수인계 가능
- LINE 의존을 단계적으로 축소 → 「앞으로 개별 문의는 앱에서」 일원화

## 2. 확정 요구사항 (사용자 결정)

| 항목 | 결정 |
|---|---|
| 대화 단위 | **응모건마다 별도 대화방** (응모 1건 = 대화방 1개) |
| LINE 관계 | **대체** — 앞으로 앱 내 메시지로 일원화 |

## 3. 결정 사항

아래 7개 항목 모두 사용자 검토 후 **확정**. 본 사양서 작성 시점(2026-05-15) 기준 결정 완료. 구현 중 변경 발견 시 개발 세션이 「구현 결과」 섹션에 기록.

### 3-1. 알림 방식 — **확정: 인플루언서 (앱 내 알림 즉시 + 메일 지연·묶음·야간 보류) / 관리자 (사이드바 배지 + 일별 다이제스트)**

**인플루언서 메일 정책 (지연 발송):**
- 새 관리자 메시지 도착 후 **30분 동안 인플루언서가 안 읽으면** 메일 1통 발송 (읽으면 메일 스킵)
- 같은 응모건의 30분 안 후속 메시지는 **1통으로 묶음** (잠잠 윈도우)
- 한 응모건당 **24시간 안 최대 1통** (리마인더 폭주 방지)
- **야간(한국시간 22시~아침 9시) 트리거는 아침 9시에 일괄 발송** (인플루언서 수면 보호)

**기타:**
- 인플루언서 앱 내 알림(notifications)은 메일과 별개로 **즉시 생성**
- 관리자 사이드바 배지는 즉시 갱신
- 관리자 일별 다이제스트 메일은 오전 9시 1회 (전일 미답변 요약)

**사유:**
- 인플루언서가 앱 열어서 바로 읽으면 메일 안 가서 Brevo 한도(20,000/월) 절약
- 「방금 봤는데 메일도 와있네」 중복 알림 피로 감소
- 야간 메일로 휴대폰 「뎅」 울려 불만 발생 방지

### 3-2. 첨부 파일 — **확정: 이미지만 + 클라이언트 자동 압축/HEIC 변환**

**허용 형식:** jpg · png · webp · **heic** (iPhone 사진)

**업로드 전 클라이언트 자동 처리 (필수):**
- HEIC 자동 감지 → JPEG 변환 (`heic2any` 또는 동등 라이브러리, CDN lazy-load)
- Canvas API 자동 리사이즈/압축:
  - 긴 변 **2048px** (영수증 작은 글씨까지 가독)
  - JPEG quality **0.85**
  - 결과: 모바일 카메라 4~10MB 원본 → 평균 400~900KB
- 자동 회전 보정 (EXIF Orientation 유지)

**한도:**
- 압축 **후** 2MB 한도 (사실상 안 걸림)
- 압축 후에도 2MB 초과 시 「이미지가 너무 큽니다, 다른 이미지를 시도해주세요」 안내
- 메시지 1건당 첨부 최대 5장

**저장:**
- 비공개 Storage 버킷 + 짧은 시한(5분) signed URL

**사유:**
- 과거 이슈: 모바일 카메라·스크린샷 원본을 그대로 올리면 파일이 너무 크고, 회선 느린 곳에선 업로드 실패. 한도 상향만으로는 Storage 비용·전송 실패율만 키움 → 본질은 클라이언트에서 자동 압축
- 영수증·결과물 재제출은 별도 흐름이지만, 메시지 안에서 「영수증 다시 보여주세요」 요청도 있을 수 있어 가독성 보존 (2048px 채택 이유)
- 일반 파일(PDF·Office) 허용은 보안·저장 부담 커서 v2 검토

### 3-3. 응모 종료 후 메시지 가능 기간 — **확정: 응모 종료(승인 후 결과물 검수 완료 / 반려 / 취소) 후 90일까지 발신 가능, 이후 열람만**

**정책:**
- 응모 종료 시각 + 90일까지: 인플루언서·관리자 모두 자유 발신
- 90일 경과: 입력창 비활성 + 「이 대화는 종료되었습니다 (応募終了から90日経過)」 안내
- 과거 메시지·첨부 열람은 무기한 가능

**사유:**
- 정산·결과물 분쟁·환불 문의 대응 윈도우 (3개월)
- 무기한 허용도 합리적이었으나 (검토 결과 강한 차단 사유는 없음), 분쟁 윈도우 명확화 + 운영 부담 관리 측면에서 90일 채택
- 90일 경과 후에도 정당한 사후 문의가 필요하면 인플루언서가 LINE 공식 채널 또는 신규 응모를 통해 접근 가능

**보조 운영 안전망 (구현 시):**
- 관리자 받은편지함 기본 필터: 「최근 6개월」 + 「전체 보기」 토글 (오래된 응모 건 노이즈 차단)
- 인플루언서 메시지 화면: 「최근 1년」 + 「전체 보기」 토글

### 3-4. 관리자 응대 권한 — **확정: 모든 관리자 발신·열람 + 개인별 읽음 + 응대 완료 마킹 (하이브리드)**

**발신·열람 권한:**
- super_admin · campaign_admin · campaign_manager 모두 가능

**읽음 처리 (개인별 — Slack·카톡 패턴):**
- 메시지 「읽음」은 관리자마다 따로 추적 (별도 테이블)
- 본인이 응모건 진입 시각 = 본인의 「마지막 확인」. 이후 도착한 메시지는 본인 받은편지함에서 미열람 강조
- 다른 관리자가 먼저 봤어도 본인은 한 번 클릭해야 표시 사라짐 → 본인 누락 방지

**응대 완료 마킹 (응모건 단위, 그룹 공통):**
- 「이 응모건은 답장 처리됨」 상태를 응모건 단위로 추적
- **자동 처리**: 인플루언서 마지막 메시지 이후 관리자가 답장하면 자동으로 「응대 완료」
- **수동 처리**: 받은편지함·메시지 모달에 「응대 완료」 버튼 (답장 없이 LINE·전화 등으로 처리한 경우)
- **자동 reopen**: 응대 완료 후 새 인플루언서 메시지 도착하면 자동으로 미응대 복귀

**카운트 정의:**
- **사이드바 배지** = 「우리 팀 미응대 응모건 수」 (그룹 공통, 모든 관리자 동일 숫자)
- **받은편지함 행 강조** = 「본인이 마지막 확인 후 새 메시지가 있는 건」 (개인별)
- 응모 행 메시지 버튼 배지 = 본인 미열람 메시지 수 (개인별)

**사유:**
- 개인별 읽음: 본인 누락 방지 (Slack·카톡 표준)
- 응대 완료 마킹: 「누가 답장할지」 합의 없이 양쪽이 답장 또는 양쪽이 안 함 → 누락 방지
- 둘 결합: 「우리 팀 미응대」 + 「내가 한 번 봐야 할 것」 둘 다 추적

**담당자 배정·SLA·자동응답·메시지 단위 이모지 반응 등은 v2 (이번 범위 외)**

### 3-5. 부적절한 메시지 대응 — **확정: 관리자 숨김 + 본인 회수 + 일괄 회수 (신고·욕설 필터는 v2)**

**3종 회수·숨김 메커니즘:**

#### 1) 관리자 강제 숨김 (soft delete)
다른 사람의 부적절 메시지를 관리자가 숨김 처리
- **권한**: campaign_admin 이상
- **사유 입력**: 카테고리 드롭다운 + 자유 메모 (신규 lookup `kind='message_hide_reason'`, 시드 7건 — §3-5 끝부분 참조)
- **인플루언서 화면**: 「[管理者により非表示処理されたメッセージ]」 회색 placeholder 카드 (메시지 카드 위치는 보임, 본문·첨부는 가림)
- **다른 관리자 화면**: 「숨김 처리됨 / 카테고리 / 자유 메모 / 처리자 / 시각」 표시 + 「원본 보기」 토글
- **첨부 Storage**: **영구 보존** (분쟁 증거 — 응모건 cascade 삭제 시에만 정리)
- **복구**: super_admin 만 가능
  - 「복구」 버튼 → 사유 메모 입력 모달 (audit 테이블 row 생성용, 필수)
  - 인플루언서 알림 없음 (조용한 복구) — 다음에 모달 열 때 메시지가 그냥 다시 보임
  - audit 이력 영구 보존 (super_admin 감사용)

#### 2) 본인 메시지 회수 (이메일 전송 취소 패턴)
**25분** 안에 본인이 직접 취소 (메일 발송 30분과 5분 안전 마진)
- **권한**: 메시지 발신자 본인 (인플루언서·관리자 모두)
- **시간 제한**: **25분** (경과 후 버튼 비활성)
  - 메일 발송 `email_send_at` 은 INSERT 후 30분 — 25분 회수 만료 후 5분 여유로 race condition 차단
  - 회수 시점이 `email_send_at` 도래 전이면 메일도 자동 cancel (`email_skip_reason='cancelled'`)
- **사유 입력**: 안 함 (실수·후회용 빠른 취소)
- **첨부 Storage**: **즉시 삭제** (본인 권리 강력 보장 + 디스크 비용 절감)
- **인플루언서가 회수한 경우** (Slack 패턴 — 양쪽 모두 placeholder, 본인 권리 강력):
  - 인플루언서 화면: 「[本人が取り消したメッセージ]」 placeholder
  - 관리자 화면: 동일 placeholder (다른 관리자도 본문·첨부 못 봄)
- **관리자가 회수한 경우** (권한별 비대칭 — 운영팀 내부 감사용):
  - 인플루언서 화면: 「[管理者が取り消したメッセージ]」 placeholder
  - 다른 관리자 화면: **원본 본문·첨부 보임** + 「본인 회수 / 시각」 헤더 표기
- **25분 만료 후 본인 정정 요청**: 운영 가이드 — 다음 메시지로 관리자에게 「이전 메시지 지워주세요」 요청 → 관리자가 `influencer_request` 카테고리로 강제 숨김 처리. 별도 기능 없음 (v2 신고·요청 기능에서 보완)

#### 3) 일괄 발송 회수 (broadcast_id 단위)
잘못 보낸 일괄 발송을 한 번에 N개 회수
- **권한**: 일괄 발송 발신자 본인 또는 super_admin
- **시간 제한**: 없음 (실수 발견이 늦을 수 있음)
- **사유 입력**: 카테고리 + 자유 메모 (강제 숨김과 동일 lookup)
- **첨부 Storage**: 영구 보존 (분쟁 증거)
- **동작**: 해당 broadcast 그룹의 모든 메시지를 한 번에 숨김 처리 (각 message 행에 `hidden_by_admin_at` + audit history row 추가) + broadcast 행에 「회수됨」 표시. 부분 회수는 별도 개별 강제 숨김으로 처리

**메일 발송과의 관계 (자동 동작, 분기 없음):**
- 회수/숨김 시점이 `email_send_at` 도래 **전** → 메일도 자동 cancel
- 도래 **후** (이미 메일 발송 완료) → 메일 자체는 회수 불가, 앱 UI만 placeholder. 운영 가이드에 「발송된 메일은 되돌릴 수 없음」 안내

**신규 lookup `kind='message_hide_reason'` 시드 7건:**
- `inappropriate_expression` (부적절한 표현)
- `personal_info_leak` (개인정보 노출)
- `defamation` (명예훼손)
- `spam` (스팸·광고)
- `wrong_recipient` (잘못 발송)
- `influencer_request` (인플루언서 요청 — 본인 회수 25분 만료 후 인플루언서가 다음 메시지로 부탁한 케이스)
- `other` (기타)

**audit 이력 (신규 테이블 `application_message_hide_history`, §4-1-5):**
- 모든 hide·unhide·self_withdraw·broadcast_withdraw 이벤트를 row 누적 (append-only, 덮어쓰기 안 함)
- 컬럼: `id`, `message_id`, `action`, `by_user_kind`(influencer|admin), `by_user_id`, `by_name`, `reason_code`, `reason_memo`, `at`
- 행 단위 보안 정책: SELECT super_admin 한정 (campaign_admin 본인 처리분 가시화는 v2)
- 분쟁 대응 + super_admin이 운영팀 내부 부당 숨김 사례 감지 가능

**v2 검토 (이번 사양서 범위 외):**
- 인플루언서 신고 버튼 (관리자 메시지 신고 → super_admin 검토)
- 인플루언서 본인 메시지 「숨김 요청」 버튼 (25분 만료 후 보완)
- 욕설 자동 필터 (한·일 양 언어)
- 정책 위반 누적 시 자동 조치 (계정 정지 등)
- campaign_admin 본인 처리 audit row 가시화 (현재는 super_admin만 SELECT)

**사유:**
- **숨김(soft delete)**: 영구 삭제하지 않아 분쟁 시 증거 보존 (일본 소비자청·법적 대응 안전)
- **본인 회수 25분 + 메일 발송 30분 안전 마진**: 회수와 메일 발송 race condition 차단, 사용자에게 실수·후회 인지에 충분한 시간
- **본인 회수 권한별 비대칭**: 인플루언서 본인 권리 강력 보장(Slack 패턴) + 관리자 운영팀 내부 감사(다른 관리자에게 원본 노출) 양립
- **첨부 Storage 원인별 정책**: 본인 회수는 즉시 삭제(개인정보 최소화 APPI), 관리자 처분·일괄 회수는 영구 보존(분쟁 증거)
- **카테고리 + 자유 메모**: 통계·운영 편의 + 예외 케이스 자유 표현. 기존 `reject_reason` 패턴과 일관
- **별도 audit 테이블**: 복구·재숨김 다중 이벤트 추적, super_admin이 「누가 언제 무엇을 처리했는지」 영구 감사 가능

### 3-6. 인터페이스 형식 — **확정: 게시판형 (이메일 thread 스타일)**

채팅형(Slack·카톡)을 처음 검토했으나, 단문 핑퐁 발생·관리자 「빨리 답해야 한다」 압박·일본 비즈니스 문화와 결 안 맞음 등 우려로 **게시판형** 채택.

**핵심 UI 차이:**
| 요소 | 채택안 (게시판형) | 비채택 (채팅형) |
|---|---|---|
| 메시지 카드 | 위→아래 누적 박스 카드 (본문 + 첨부 + 메타) | 좌우 말풍선 |
| 입력칸 | 여러 줄 textarea (자연스럽게 「정리해서 쓰자」) | 한 줄 input + 옆 전송 |
| 자동 스크롤 | 새 메시지 알림 → 사용자가 클릭 이동 | 항상 맨 아래 |
| 「..님이 입력 중」 | 없음 (비동기 전제) | 보통 있음 |
| 첨부 | 메시지당 다중 자연스러움 | 보통 1~2장 |

**제목 처리:**
- 사용자가 「제목」 입력하지 않음 (진입 장벽 제거)
- 응모건 헤더에 자동 생성: 「캠페인 X에 관한 문의」 (시스템 자동, DB 저장 안 함)

**사유:**
- 단문 폭주 본질적 감소 (textarea가 「한 번에 정리해서 쓰자」 압박 자연 유도)
- 일본 비즈니스 메일 문화(「お忙しいところ恐れ入ります…」 정중한 본문 구조)와 자연스럽게 맞음
- 비동기 응대 적합 (관리자가 시간 갖고 답장 작성, 즉시성 압박 없음)
- 「응대 완료」 마킹(§3-4)이 더 자연스러움 — 이메일 처리 패턴과 동일
- 첨부 다중 결합 자연스러움 (§3-2 자동 압축과 시너지)
- v2 티켓관리 확장 시 카테고리·우선순위 UI를 카드 헤더에 자연스럽게 추가 가능

**데이터 모델 영향:** **거의 없음** — `application_messages` 행이 곧 「게시글 1건」. UI 렌더링만 게시판형으로 작성.

### 3-7. 양방향 시작 + 일괄 발송 (BCC 패턴) — **확정**

**양방향 시작 (메시지 0건 상태에서도 시작 가능):**
- 인플루언서: 본인 응모건 화면에서 「メッセージを送る」 버튼 → 첫 메시지 작성
- 관리자: 신청 관리·캠페인별 신청자·결과물 관리 페인 응모 행에서 「메시지」 버튼 → 첫 메시지 작성
- 양쪽 모두 응모건이 존재해야 시작 가능 (응모 안 한 회원 대상 메시지는 본 사양서 범위 외)

**관리자 일괄 발송 (BCC 패턴, 단체대화방 아님):**
- 관리자가 N명 인플루언서 선택 → 같은 본문 한 번 작성 → 발송
- 받는 인플루언서는 각자의 1대1 응모건 대화방에 메시지 도착 (서로 모름)
- 인플루언서가 답장하면 발신 관리자(그룹) 에게만 회신, 다른 수신자는 못 봄

**발송 단위 (둘 다 가능):**
- **캠페인 단위**: 「캠페인 X 응모자」 → 추가 필터(상태/채널/팔로워수 등) → 다중 선택 → 발송
  - 시나리오 예: 「캠페인 X 승인자 5명에게 발송 일정 안내」
- **임의 응모건 다중 선택**: 응모건 검색·체크박스 다중 선택 → 발송
  - 시나리오 예: 「서로 다른 캠페인 응모자 3명에게 동일 안내 한꺼번에」

**발송 그룹 메타 추적:**
- 「발송 묶음 1건」 = 별도 테이블 `application_message_broadcasts` 신규
- 각 메시지는 `broadcast_id` 로 묶음 추적
- 「몇 명에게 보냈고 몇 명이 읽었나」 통계 가능
- 받은편지함의 일괄 발송 메시지 카드에 Material Icon `campaign` + 「일괄 발송 (N명에게 동시)」 작은 배지 (이모지 금지, CLAUDE.md 규칙)

**응모 안 한 회원 대상 발송은 v2 검토** — 본 사양서는 응모건 단위만. 공지가 필요하면 기존 `admin_notices`(관리자 공지)·LINE 공식 계정 활용.

## 4. 데이터 모델 (마이그레이션 132 이후 가정 — 구현 시점 재확인)

### 4-1. 신규 테이블 `application_messages`

```sql
CREATE TABLE public.application_messages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid NOT NULL REFERENCES public.applications(id) ON DELETE CASCADE,
  sender_kind     text NOT NULL CHECK (sender_kind IN ('influencer','admin')),
  sender_id       uuid NOT NULL,        -- auth.uid
  sender_name     text NOT NULL,        -- 스냅샷 (관리자 이름 / 인플루언서 이름)
  body            text NOT NULL CHECK (btrim(body) <> '' OR attachments <> '[]'::jsonb),
  attachments     jsonb NOT NULL DEFAULT '[]'::jsonb,  -- [{path, name, size, mime}]
  created_at      timestamptz NOT NULL DEFAULT now(),
  read_by_influencer_at timestamptz NULL,
  -- 관리자 읽음은 application_message_admin_reads 별도 테이블 (개인별 추적, §3-4)
  -- 강제 숨김 (관리자 행위) — 마지막 상태 캐시. 상세 이력은 application_message_hide_history (§4-1-5)
  hidden_by_admin_at    timestamptz NULL,
  hidden_by_admin_id    uuid NULL,
  hidden_reason_code    text NULL,   -- lookup_values(kind='message_hide_reason').code 카테고리
  hidden_reason_memo    text NULL,   -- 자유 메모
  -- 본인 회수 (25분 한도, §3-5) — sender_kind 별로 인플루언서·관리자 화면 노출 비대칭
  self_withdrawn_at      timestamptz NULL,
  self_withdrawn_by_kind text NULL CHECK (self_withdrawn_by_kind IN ('influencer','admin')),
  -- 메일 발송 큐 (§4-6 지연 발송 정책) — 관리자 메시지 INSERT 시 트리거가 자동 계산.
  -- 인플루언서 → 관리자 메시지는 모두 NULL (관리자는 사이드바 배지·일별 다이제스트로 처리)
  email_send_at     timestamptz NULL,
  email_sent_at     timestamptz NULL,
  email_skip_reason text NULL CHECK (email_skip_reason IN
    ('read_in_time','rate_limited_24h','cancelled','merged_into_other'))
);

CREATE INDEX idx_application_messages_app_created
  ON public.application_messages (application_id, created_at);

ALTER TABLE public.application_messages ENABLE ROW LEVEL SECURITY;

-- SELECT 정책 — 행 가시성만 RLS, 본문·첨부 마스킹은 application_message_safe 뷰 또는 RPC로 처리(§9)
-- 인플루언서는 본인 응모건의 모든 메시지 행을 fetch 할 수 있되, 강제 숨김·관리자 본인 회수의
-- 본문·첨부는 뷰 단계에서 NULL 또는 placeholder 토큰으로 마스킹된 상태로 반환
CREATE POLICY "influencer_read_own_application_messages"
  ON public.application_messages FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM public.applications a
       WHERE a.id = application_id
         AND a.user_id = auth.uid()
    )
  );

CREATE POLICY "admin_read_all_messages"
  ON public.application_messages FOR SELECT
  USING (public.is_admin());

-- INSERT 는 send_application_message·send_application_message_bulk RPC 경유만 (sender_kind 변조 방지)
-- UPDATE 는 mark_application_messages_read·hide·unhide·withdraw_own·withdraw_broadcast RPC 경유만
-- DELETE 는 응모건 CASCADE 외에는 차단 (메시지 본문 영구 삭제 없음, soft delete 만 — §3-5)
-- 모든 RPC 는 SECURITY DEFINER + 함수 owner 가 BYPASSRLS 권한 보유 (Supabase 기본 postgres role)
-- + 함수 안에서 권한 검증 (is_admin / is_campaign_admin / 본인 검증)
```

### 4-1-2. 관리자 개인별 읽음 추적 (신규, 하이브리드 §3-4)

```sql
CREATE TABLE public.application_message_admin_reads (
  message_id    uuid NOT NULL REFERENCES public.application_messages(id) ON DELETE CASCADE,
  admin_auth_id uuid NOT NULL,
  read_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, admin_auth_id)
);

CREATE INDEX idx_admin_reads_admin
  ON public.application_message_admin_reads (admin_auth_id, read_at DESC);

ALTER TABLE public.application_message_admin_reads ENABLE ROW LEVEL SECURITY;

-- 본인 읽음 기록만 SELECT (다른 관리자가 언제 봤는지는 알 필요 없음 — v2 정보 표시 옵션)
CREATE POLICY "admin_read_own_reads"
  ON public.application_message_admin_reads FOR SELECT
  USING (admin_auth_id = auth.uid() AND public.is_admin());

-- INSERT 는 mark_application_messages_read RPC 경유만 (SECURITY DEFINER 함수 owner 는 BYPASSRLS
-- 권한 보유 — Supabase 기본 postgres role 권장. 별도 INSERT 정책 추가 시는 클라이언트가 RPC 우회로
-- 직접 INSERT 가능해질 위험이 있어 비권장. 개발 세션 결정)
```

### 4-1-3. 응모건 응대 완료 (신규, 하이브리드 §3-4)

```sql
CREATE TABLE public.application_message_resolutions (
  application_id            uuid PRIMARY KEY REFERENCES public.applications(id) ON DELETE CASCADE,
  resolved_at               timestamptz NOT NULL DEFAULT now(),
  resolved_by               uuid NOT NULL,
  resolved_by_name          text NOT NULL,
  resolved_after_message_at timestamptz NOT NULL,  -- 응대 완료 시점의 마지막 메시지 시각
  resolution_method         text NOT NULL CHECK (resolution_method IN ('auto_replied','manual'))
);

ALTER TABLE public.application_message_resolutions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_read_resolutions"
  ON public.application_message_resolutions FOR SELECT
  USING (public.is_admin());

-- INSERT/UPDATE/DELETE 는 RPC 경유만 — 자동 처리는 send_application_message RPC 끝부분에서
-- (결정 J: 관리자 답장 → UPSERT 자동 응대 완료 / 인플루언서 메시지 → DELETE reopen),
-- 수동 처리는 mark_application_resolved RPC. SECURITY DEFINER + BYPASSRLS owner
```

**자동 응대·reopen 동작 (결정 J — `send_application_message` RPC 끝부분에 통합 처리):**
- **인플루언서 새 메시지 INSERT 시** → `application_message_resolutions` 행 자동 DELETE (reopen)
- **관리자 답장 INSERT 시** → `application_message_resolutions` 자동 UPSERT (`resolution_method='auto_replied'`)
- 한 트랜잭션 안에서 메시지 INSERT 와 응대 상태 변경이 원자적 처리되어 race condition 차단
- 트리거 분리 옵션은 비채택 (RPC 안이 명시적·디버깅 용이)

### 4-1-4. 일괄 발송 그룹 메타 (신규, BCC 패턴 §3-7)

```sql
CREATE TABLE public.application_message_broadcasts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sender_id       uuid NOT NULL,
  sender_name     text NOT NULL,
  body            text NOT NULL,
  attachments     jsonb NOT NULL DEFAULT '[]'::jsonb,
  recipient_count integer NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  -- 발송 컨텍스트 추적
  context_kind        text NOT NULL CHECK (context_kind IN ('campaign','manual')),
  context_campaign_id uuid NULL REFERENCES public.campaigns(id) ON DELETE SET NULL,
  context_filter      jsonb NULL,  -- 적용한 필터 스냅샷 (status·channel·follower_min 등)
  -- 일괄 회수 (§3-5 ③) — withdraw_broadcast RPC 가 함께 UPDATE
  withdrawn_at        timestamptz NULL,
  withdrawn_by        uuid NULL,
  withdrawn_reason_code text NULL,  -- lookup_values(kind='message_hide_reason').code
  withdrawn_reason_memo text NULL
);

CREATE INDEX idx_broadcasts_sender_created
  ON public.application_message_broadcasts (sender_id, created_at DESC);

CREATE INDEX idx_broadcasts_campaign
  ON public.application_message_broadcasts (context_campaign_id, created_at DESC)
  WHERE context_campaign_id IS NOT NULL;

ALTER TABLE public.application_message_broadcasts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_read_broadcasts"
  ON public.application_message_broadcasts FOR SELECT
  USING (public.is_admin());

-- INSERT 는 send_application_message_bulk RPC 경유만 (SECURITY DEFINER + BYPASSRLS owner)
```

**`application_messages` 컬럼 추가:**
```sql
ALTER TABLE public.application_messages
  ADD COLUMN broadcast_id uuid NULL
  REFERENCES public.application_message_broadcasts(id) ON DELETE SET NULL;

CREATE INDEX idx_application_messages_broadcast
  ON public.application_messages (broadcast_id)
  WHERE broadcast_id IS NOT NULL;

COMMENT ON COLUMN public.application_messages.broadcast_id IS
  '일괄 발송으로 생성된 메시지면 broadcast 그룹 ID. 개별 발송이면 NULL';
```

### 4-1-5. 신규 테이블 `application_message_hide_history` (audit 이력, §3-5)

숨김·복구·본인 회수 모든 이벤트를 append-only 로 누적. 복구·재숨김 같은 다중 이벤트 추적 가능.

```sql
CREATE TABLE public.application_message_hide_history (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id    uuid NOT NULL REFERENCES public.application_messages(id) ON DELETE CASCADE,
  action        text NOT NULL CHECK (action IN ('hide','unhide','self_withdraw','broadcast_withdraw')),
  by_user_kind  text NOT NULL CHECK (by_user_kind IN ('influencer','admin')),
  by_user_id    uuid NOT NULL,
  by_name       text NOT NULL,
  reason_code   text NULL,  -- lookup_values(kind='message_hide_reason').code. 본인 회수(self_withdraw)는 NULL
  reason_memo   text NULL,  -- 자유 메모. 본인 회수는 NULL, 강제 숨김·복구·일괄 회수는 입력 가능 (UI 필수)
  at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_message_hide_history_message_at
  ON public.application_message_hide_history (message_id, at);

ALTER TABLE public.application_message_hide_history ENABLE ROW LEVEL SECURITY;

-- super_admin 만 SELECT — 운영팀 내부 부당 숨김 사례 감지·분쟁 대응용
-- campaign_admin 본인 처리 row 가시화는 v2 (현재는 super_admin 전용)
CREATE POLICY "super_admin_read_hide_history"
  ON public.application_message_hide_history FOR SELECT
  USING (public.is_super_admin());

-- INSERT 는 hide/unhide/withdraw RPC 경유만 (SECURITY DEFINER 함수 owner 가 BYPASSRLS 권한 보유 —
-- Supabase 기본 postgres role 사용. 클라이언트는 RPC 만 호출 가능, 직접 INSERT 차단)
```

### 4-2. 신규 테이블 `application_message_threads_meta` (조회 최적화용)

대화방 자체는 응모 행이 곧 식별자이므로 별도 테이블 불필요. 단 「인플루언서 응모이력 옆 미읽음 배지」, 「관리자 받은편지함 마지막 메시지 정렬」 등의 조회 성능을 위해 메타 캐시 테이블을 둘지 여부는 개발 세션이 측정 후 결정. 1차에는 view 로 충분할 수 있음:

```sql
CREATE OR REPLACE VIEW public.application_message_summary AS
SELECT
  a.id AS application_id,
  a.user_id AS influencer_id,
  a.campaign_id,
  -- message_count·last_message_at 은 placeholder 도 화면에 보이므로 self_withdrawn 포함
  count(m.*) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS message_count,
  -- 인플루언서 미열람: 관리자가 본인 회수한 메시지는 본문 못 보므로 제외 (§3-5)
  count(m.*) FILTER (
    WHERE m.sender_kind = 'admin'
      AND m.read_by_influencer_at IS NULL
      AND m.hidden_by_admin_at IS NULL
      AND m.self_withdrawn_at IS NULL
  ) AS unread_for_influencer,
  -- 그룹 공통 미응대 = resolutions 없거나 마지막 인플루언서 메시지(본문 살아있는 것)가 응대 완료 시점 이후
  -- 인플루언서가 본인 회수한 메시지는 본문이 사라졌으므로 응대 대상 아님 (§3-5)
  CASE
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind='influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) IS NULL THEN false
    WHEN r.resolved_after_message_at IS NULL THEN true
    WHEN max(m.created_at) FILTER (
      WHERE m.sender_kind='influencer'
        AND m.hidden_by_admin_at IS NULL
        AND m.self_withdrawn_at IS NULL
    ) > r.resolved_after_message_at THEN true
    ELSE false
  END AS unresolved_for_admin_team,
  max(m.created_at) FILTER (WHERE m.hidden_by_admin_at IS NULL) AS last_message_at
FROM public.applications a
LEFT JOIN public.application_messages m ON m.application_id = a.id
LEFT JOIN public.application_message_resolutions r ON r.application_id = a.id
GROUP BY a.id, a.user_id, a.campaign_id, r.resolved_after_message_at;
```

**개인별 미열람 카운트** (관리자 본인 기준)는 별도 view 또는 RPC로 (admin_auth_id 파라미터 필요):

```sql
CREATE OR REPLACE FUNCTION public.application_message_admin_unread_counts(
  p_admin_auth_id uuid DEFAULT NULL  -- NULL 이면 auth.uid()
) RETURNS TABLE (application_id uuid, unread_count bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT
    m.application_id,
    count(*) AS unread_count
  FROM public.application_messages m
  LEFT JOIN public.application_message_admin_reads r
    ON r.message_id = m.id AND r.admin_auth_id = COALESCE(p_admin_auth_id, auth.uid())
  WHERE m.sender_kind = 'influencer'
    AND m.hidden_by_admin_at IS NULL
    AND m.self_withdrawn_at IS NULL  -- 본인 회수된 인플루언서 메시지는 관리자 미열람 카운트에서 제외 (§3-5)
    AND r.message_id IS NULL  -- 본인이 안 읽음
  GROUP BY m.application_id;
$$;
```

### 4-3. 신규 RPC

```sql
-- 메시지 발송 (인플루언서 / 관리자 공용, sender_kind 자동 판별)
CREATE OR REPLACE FUNCTION public.send_application_message(
  p_application_id uuid,
  p_body           text,
  p_attachments    jsonb DEFAULT '[]'::jsonb
) RETURNS uuid -- new message id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_kind text;
  v_sender_name text;
  v_app_owner   uuid;
  v_app_status  text;
  v_msg_id      uuid;
BEGIN
  -- 응모 소유자 확인
  SELECT user_id, status INTO v_app_owner, v_app_status
    FROM public.applications WHERE id = p_application_id;

  IF v_app_owner IS NULL THEN
    RAISE EXCEPTION '응모를 찾을 수 없습니다';
  END IF;

  -- sender_kind 판별
  IF public.is_admin() THEN
    v_sender_kind := 'admin';
    SELECT name INTO v_sender_name FROM public.admins WHERE auth_id = auth.uid();
  ELSIF v_app_owner = auth.uid() THEN
    v_sender_kind := 'influencer';
    SELECT name INTO v_sender_name FROM public.influencers WHERE id = auth.uid();
  ELSE
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  -- 본문/첨부 빈값 검증
  IF (p_body IS NULL OR btrim(p_body) = '') AND (p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION '메시지 본문 또는 첨부가 필요합니다';
  END IF;

  -- 응모 종료 90일 경과 차단 (§3-3)
  -- 응모 종료 시각 계산 권장 로직 (개발 세션이 정확한 컬럼·뷰 명세 결정):
  --   1) applications.cancelled_at IS NOT NULL 이면 → cancelled_at
  --   2) applications.status='rejected' 이면 → applications.reviewed_at
  --   3) applications.status='approved' + 해당 응모의 모든 deliverables 가 status='approved'
  --      → 마지막 deliverable.reviewed_at (deliverables.application_id = p_application_id 기준)
  --   4) 위 모두 아니면 (진행 중) → NULL (메시지 발송 가능, 90일 차단 적용 안 함)
  -- 별도 헬퍼 함수 application_ended_at(p_application_id uuid) RETURNS timestamptz STABLE
  -- 로 추출 권장 (view 부담 줄임). is_admin() 이 true 면 90일 경과해도 발송 허용할지 여부는 개발 세션 결정
  -- (관리자의 사후 안내 필요한 케이스도 있어 관리자 한정 예외가 합리적)
  --
  -- 의사 코드:
  --   v_ended_at := application_ended_at(p_application_id);
  --   IF v_ended_at IS NOT NULL AND v_ended_at < now() - interval '90 days'
  --        AND NOT public.is_admin() THEN
  --     RAISE EXCEPTION '応募終了から90日経過しました。閲覧のみ可能です';
  --   END IF;

  INSERT INTO public.application_messages (
    application_id, sender_kind, sender_id, sender_name, body, attachments
  ) VALUES (
    p_application_id, v_sender_kind, auth.uid(), COALESCE(v_sender_name,'(이름미상)'),
    COALESCE(p_body,''), p_attachments
  )
  RETURNING id INTO v_msg_id;

  -- 자동 응대 처리 (§3-4 + §4-1-3, 결정 J):
  --   인플루언서 새 메시지 → application_message_resolutions 행 자동 DELETE (자동 reopen)
  --   관리자 답장 → application_message_resolutions 자동 UPSERT (자동 응대 완료, method='auto_replied')
  IF v_sender_kind = 'influencer' THEN
    DELETE FROM public.application_message_resolutions
     WHERE application_id = p_application_id;
  ELSE  -- v_sender_kind = 'admin'
    INSERT INTO public.application_message_resolutions (
      application_id, resolved_at, resolved_by, resolved_by_name,
      resolved_after_message_at, resolution_method
    ) VALUES (
      p_application_id, now(), auth.uid(), COALESCE(v_sender_name,'(이름미상)'),
      COALESCE(
        (SELECT max(created_at) FROM public.application_messages
          WHERE application_id = p_application_id
            AND sender_kind = 'influencer'
            AND hidden_by_admin_at IS NULL
            AND self_withdrawn_at IS NULL),
        now()  -- 인플루언서 메시지 없을 때 (관리자가 먼저 시작한 케이스)는 now() 로 폴백
      ),
      'auto_replied'
    )
    ON CONFLICT (application_id) DO UPDATE
      SET resolved_at               = EXCLUDED.resolved_at,
          resolved_by               = EXCLUDED.resolved_by,
          resolved_by_name          = EXCLUDED.resolved_by_name,
          resolved_after_message_at = EXCLUDED.resolved_after_message_at,
          resolution_method         = 'auto_replied';
  END IF;

  RETURN v_msg_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_application_message TO authenticated;

-- 읽음 처리
CREATE OR REPLACE FUNCTION public.mark_application_messages_read(
  p_application_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_role text;
  v_owner uuid;
BEGIN
  SELECT user_id INTO v_owner FROM public.applications WHERE id = p_application_id;

  IF public.is_admin() THEN
    v_role := 'admin';
  ELSIF v_owner = auth.uid() THEN
    v_role := 'influencer';
  ELSE
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  IF v_role = 'admin' THEN
    -- 관리자: 본인이 안 읽은 인플루언서 메시지를 application_message_admin_reads 에 UPSERT
    INSERT INTO public.application_message_admin_reads (message_id, admin_auth_id, read_at)
    SELECT m.id, auth.uid(), now()
      FROM public.application_messages m
     WHERE m.application_id = p_application_id
       AND m.sender_kind = 'influencer'
       AND m.hidden_by_admin_at IS NULL
    ON CONFLICT (message_id, admin_auth_id) DO NOTHING;
  ELSE
    UPDATE public.application_messages
       SET read_by_influencer_at = now()
     WHERE application_id = p_application_id
       AND sender_kind = 'admin'
       AND read_by_influencer_at IS NULL
       AND hidden_by_admin_at IS NULL;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_application_messages_read TO authenticated;

-- 응대 완료 수동 마킹 (관리자가 LINE·전화 등으로 처리한 경우)
CREATE OR REPLACE FUNCTION public.mark_application_resolved(
  p_application_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name      text;
  v_last_message_at timestamptz;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  SELECT max(created_at) INTO v_last_message_at
    FROM public.application_messages
   WHERE application_id = p_application_id
     AND hidden_by_admin_at IS NULL;

  IF v_last_message_at IS NULL THEN
    RAISE EXCEPTION '메시지가 없는 응모건은 응대 완료할 수 없습니다';
  END IF;

  INSERT INTO public.application_message_resolutions (
    application_id, resolved_at, resolved_by, resolved_by_name,
    resolved_after_message_at, resolution_method
  ) VALUES (
    p_application_id, now(), auth.uid(), COALESCE(v_admin_name,'(이름미상)'),
    v_last_message_at, 'manual'
  )
  ON CONFLICT (application_id) DO UPDATE
    SET resolved_at               = now(),
        resolved_by               = auth.uid(),
        resolved_by_name          = COALESCE(v_admin_name,'(이름미상)'),
        resolved_after_message_at = EXCLUDED.resolved_after_message_at,
        resolution_method         = 'manual';
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_application_resolved TO authenticated;

-- 자동 응대 완료(관리자 답장 시) + 자동 reopen(인플루언서 새 메시지 시) 처리는
-- send_application_message RPC 끝부분에 통합 (결정 J, §4-1-3) — 위 RPC 본문 참조
-- 동일 트랜잭션 안에서 메시지 INSERT 와 응대 상태 변경이 원자적으로 처리됨

-- 일괄 발송 RPC (관리자 → N명 BCC, §3-7)
CREATE OR REPLACE FUNCTION public.send_application_message_bulk(
  p_application_ids     uuid[],
  p_body                text,
  p_attachments         jsonb DEFAULT '[]'::jsonb,
  p_context_kind        text  DEFAULT 'manual',  -- 'campaign' | 'manual'
  p_context_campaign_id uuid  DEFAULT NULL,
  p_context_filter      jsonb DEFAULT NULL
) RETURNS uuid  -- broadcast_id
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name   text;
  v_broadcast_id uuid;
  v_app_id       uuid;
  v_app_owner    uuid;
  v_inserted     integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (관리자만 일괄 발송 가능)';
  END IF;

  IF (p_body IS NULL OR btrim(p_body) = '') AND (p_attachments = '[]'::jsonb) THEN
    RAISE EXCEPTION '메시지 본문 또는 첨부가 필요합니다';
  END IF;

  IF array_length(p_application_ids, 1) IS NULL THEN
    RAISE EXCEPTION '수신자가 없습니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 발송 그룹 메타 INSERT (recipient_count 는 실제 INSERT 후 UPDATE)
  INSERT INTO public.application_message_broadcasts (
    sender_id, sender_name, body, attachments, recipient_count,
    context_kind, context_campaign_id, context_filter
  ) VALUES (
    auth.uid(), COALESCE(v_admin_name,'(이름미상)'),
    p_body, p_attachments, 0,
    p_context_kind, p_context_campaign_id, p_context_filter
  )
  RETURNING id INTO v_broadcast_id;

  -- N개 메시지 INSERT (응모 존재 확인 후)
  FOREACH v_app_id IN ARRAY p_application_ids LOOP
    SELECT user_id INTO v_app_owner FROM public.applications WHERE id = v_app_id;
    IF v_app_owner IS NULL THEN
      CONTINUE;  -- 존재하지 않는 응모건은 skip
    END IF;

    INSERT INTO public.application_messages (
      application_id, sender_kind, sender_id, sender_name,
      body, attachments, broadcast_id
    ) VALUES (
      v_app_id, 'admin', auth.uid(), COALESCE(v_admin_name,'(이름미상)'),
      COALESCE(p_body,''), p_attachments, v_broadcast_id
    );
    v_inserted := v_inserted + 1;
  END LOOP;

  -- 실제 INSERT 된 수로 갱신
  UPDATE public.application_message_broadcasts
     SET recipient_count = v_inserted
   WHERE id = v_broadcast_id;

  IF v_inserted = 0 THEN
    -- 모든 응모건이 없어진 경우 broadcast 행도 정리
    DELETE FROM public.application_message_broadcasts WHERE id = v_broadcast_id;
    RAISE EXCEPTION '발송된 응모건이 없습니다 (모두 존재하지 않거나 삭제됨)';
  END IF;

  RETURN v_broadcast_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_application_message_bulk TO authenticated;

-- 강제 숨김 (campaign_admin 이상, §3-5 ①)
CREATE OR REPLACE FUNCTION public.hide_application_message(
  p_message_id  uuid,
  p_reason_code text,
  p_reason_memo text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name text;
BEGIN
  IF NOT public.is_campaign_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (campaign_admin 이상 필요)';
  END IF;

  -- 사유 카테고리 검증
  IF NOT EXISTS (
    SELECT 1 FROM public.lookup_values
     WHERE kind = 'message_hide_reason' AND code = p_reason_code AND active = true
  ) THEN
    RAISE EXCEPTION '유효하지 않은 사유 카테고리입니다: %', p_reason_code;
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  UPDATE public.application_messages
     SET hidden_by_admin_at = now(),
         hidden_by_admin_id = auth.uid(),
         hidden_reason_code = p_reason_code,
         hidden_reason_memo = p_reason_memo
   WHERE id = p_message_id
     AND hidden_by_admin_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION '메시지를 찾을 수 없거나 이미 숨김 처리되었습니다';
  END IF;

  -- audit row 누적
  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id, 'hide', 'admin', auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'), p_reason_code, p_reason_memo
  );

  -- 메일 발송 자동 cancel (email_send_at 도래 전이면)
  UPDATE public.application_messages
     SET email_skip_reason = 'cancelled'
   WHERE id = p_message_id
     AND email_send_at IS NOT NULL
     AND email_send_at > now()
     AND email_sent_at IS NULL;
END;
$$;

GRANT EXECUTE ON FUNCTION public.hide_application_message TO authenticated;

-- 강제 숨김 복구 (super_admin 한정, §3-5 복구 절차)
CREATE OR REPLACE FUNCTION public.unhide_application_message(
  p_message_id  uuid,
  p_reason_memo text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_admin_name text;
BEGIN
  IF NOT public.is_super_admin() THEN
    RAISE EXCEPTION '권한이 없습니다 (super_admin 한정)';
  END IF;

  IF p_reason_memo IS NULL OR btrim(p_reason_memo) = '' THEN
    RAISE EXCEPTION '복구 사유 메모는 필수입니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  UPDATE public.application_messages
     SET hidden_by_admin_at = NULL,
         hidden_by_admin_id = NULL,
         hidden_reason_code = NULL,
         hidden_reason_memo = NULL
   WHERE id = p_message_id
     AND hidden_by_admin_at IS NOT NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION '메시지를 찾을 수 없거나 숨김 상태가 아닙니다';
  END IF;

  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id, 'unhide', 'admin', auth.uid(),
    COALESCE(v_admin_name, '(이름미상)'), NULL, p_reason_memo
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.unhide_application_message TO authenticated;

-- 본인 메시지 회수 (25분 한도, §3-5 ②) — 인플루언서·관리자 공용
CREATE OR REPLACE FUNCTION public.withdraw_own_message(
  p_message_id uuid
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id    uuid;
  v_sender_kind  text;
  v_created_at   timestamptz;
  v_sender_name  text;
BEGIN
  SELECT sender_id, sender_kind, created_at, sender_name
    INTO v_sender_id, v_sender_kind, v_created_at, v_sender_name
    FROM public.application_messages
   WHERE id = p_message_id;

  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION '메시지를 찾을 수 없습니다';
  END IF;

  -- 발신자 본인 검증
  IF v_sender_id <> auth.uid() THEN
    RAISE EXCEPTION '본인 메시지만 회수할 수 있습니다';
  END IF;

  -- 25분 한도 검증
  IF v_created_at < now() - interval '25 minutes' THEN
    RAISE EXCEPTION '회수 가능 시간(25분)이 지났습니다';
  END IF;

  -- 이미 처리된 메시지 차단
  IF EXISTS (
    SELECT 1 FROM public.application_messages
     WHERE id = p_message_id
       AND (hidden_by_admin_at IS NOT NULL OR self_withdrawn_at IS NOT NULL)
  ) THEN
    RAISE EXCEPTION '이미 회수·숨김 처리된 메시지입니다';
  END IF;

  UPDATE public.application_messages
     SET self_withdrawn_at      = now(),
         self_withdrawn_by_kind = v_sender_kind
   WHERE id = p_message_id;

  -- audit row 추가 (사유 없음)
  INSERT INTO public.application_message_hide_history (
    message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
  ) VALUES (
    p_message_id, 'self_withdraw', v_sender_kind, auth.uid(), v_sender_name, NULL, NULL
  );

  -- 메일 발송 자동 cancel
  UPDATE public.application_messages
     SET email_skip_reason = 'cancelled'
   WHERE id = p_message_id
     AND email_send_at IS NOT NULL
     AND email_send_at > now()
     AND email_sent_at IS NULL;
END;
$$;

-- 첨부 Storage 즉시 삭제는 SQL 안에서 직접 불가 — Edge Function 또는 클라이언트가 RPC 호출 후
-- attachments 경로 목록으로 storage.objects 에서 삭제. 정확한 cleanup 트리거 위치는 개발 세션 결정.
-- (1안: 클라이언트가 withdraw_own_message 호출 직후 storage.from('application-message-attachments').remove([...])
--  2안: pg_cron 으로 self_withdrawn 메시지의 attachments 경로를 5분 주기 정리하는 Edge Function 호출)

GRANT EXECUTE ON FUNCTION public.withdraw_own_message TO authenticated;

-- 일괄 발송 회수 (broadcast_id 단위, §3-5 ③)
CREATE OR REPLACE FUNCTION public.withdraw_broadcast(
  p_broadcast_id uuid,
  p_reason_code  text,
  p_reason_memo  text DEFAULT NULL
) RETURNS integer  -- 회수된 메시지 수
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  v_sender_id  uuid;
  v_admin_name text;
  v_count      integer := 0;
  v_msg_id     uuid;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION '권한이 없습니다';
  END IF;

  -- 사유 카테고리 검증
  IF NOT EXISTS (
    SELECT 1 FROM public.lookup_values
     WHERE kind = 'message_hide_reason' AND code = p_reason_code AND active = true
  ) THEN
    RAISE EXCEPTION '유효하지 않은 사유 카테고리입니다: %', p_reason_code;
  END IF;

  -- 권한: 발신자 본인 또는 super_admin
  SELECT sender_id INTO v_sender_id
    FROM public.application_message_broadcasts WHERE id = p_broadcast_id;
  IF v_sender_id IS NULL THEN
    RAISE EXCEPTION '발송 그룹을 찾을 수 없습니다';
  END IF;
  IF v_sender_id <> auth.uid() AND NOT public.is_super_admin() THEN
    RAISE EXCEPTION '본인 발송 또는 super_admin 만 일괄 회수할 수 있습니다';
  END IF;

  SELECT name INTO v_admin_name FROM public.admins WHERE auth_id = auth.uid();

  -- 그룹의 미숨김 메시지 각각 hide + audit row
  FOR v_msg_id IN
    SELECT id FROM public.application_messages
     WHERE broadcast_id = p_broadcast_id
       AND hidden_by_admin_at IS NULL
  LOOP
    UPDATE public.application_messages
       SET hidden_by_admin_at = now(),
           hidden_by_admin_id = auth.uid(),
           hidden_reason_code = p_reason_code,
           hidden_reason_memo = p_reason_memo
     WHERE id = v_msg_id;

    INSERT INTO public.application_message_hide_history (
      message_id, action, by_user_kind, by_user_id, by_name, reason_code, reason_memo
    ) VALUES (
      v_msg_id, 'broadcast_withdraw', 'admin', auth.uid(),
      COALESCE(v_admin_name, '(이름미상)'), p_reason_code, p_reason_memo
    );

    -- 메일 자동 cancel
    UPDATE public.application_messages
       SET email_skip_reason = 'cancelled'
     WHERE id = v_msg_id
       AND email_send_at IS NOT NULL
       AND email_send_at > now()
       AND email_sent_at IS NULL;

    v_count := v_count + 1;
  END LOOP;

  -- broadcast 행에 회수 마킹 (§3-5 ③, 2차 검수 2-A) — 「회수됨」 배지 판별용
  UPDATE public.application_message_broadcasts
     SET withdrawn_at          = now(),
         withdrawn_by          = auth.uid(),
         withdrawn_reason_code = p_reason_code,
         withdrawn_reason_memo = p_reason_memo
   WHERE id = p_broadcast_id
     AND withdrawn_at IS NULL;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.withdraw_broadcast TO authenticated;
```

### 4-4. Storage 버킷

- 신규 비공개 버킷 `application-message-attachments`
- 경로 컨벤션: `{application_id}/{message_id}/{filename}`
- 정책: 인플루언서는 본인 응모건만 업로드, 관리자는 모두 가능. 다운로드는 본인 응모건 + 관리자
- 최대 **2MB** (클라이언트 압축 후 기준), MIME 화이트리스트 (jpg/png/webp — heic는 클라이언트에서 jpg로 변환 후 업로드)
- 메시지 1건당 첨부 최대 5장
- **클라이언트 압축 헬퍼** 신규 작성 — `dev/lib/image-compress.js` (또는 동등 위치):
  - HEIC → JPEG 변환 (`heic2any` CDN lazy-load)
  - Canvas API 리사이즈: 긴 변 2048px / quality 0.85
  - EXIF Orientation 자동 회전 보정
  - 압축 전·후 크기 콘솔 로그 (디버깅용)
  - 이번 사양서 범위는 메시지 첨부 적용만, 영수증·캠페인 이미지로의 확산은 §10 추후 검토

### 4-5. 알림 통합

- 기존 `notifications` 테이블에 신규 kind 추가:
  - `message_received` (인플루언서 → 새 관리자 메시지 도착)
- 관리자 측 미읽음은 사이드바 배지로 직접 view 카운트 (별도 알림 테이블 없음)

### 4-6. 메일 발송 (Brevo) — 지연 큐 패턴

**인플루언서는 즉시 발송 안 함**. 30분 미읽음 + 야간 보류 + 24h 1통 한도 정책 적용.

**메일 큐 컬럼**: §4-1 `application_messages` 정의에 통합 (`email_send_at`·`email_sent_at`·`email_skip_reason` 3종) — 컬럼 정의는 위 §4-1 참조.

**트리거** (관리자 메시지 INSERT 시):
1. 한국시간 22~9시 사이면 `email_send_at = 다음날 오전 9시(KST)`
2. 그 외엔 `email_send_at = now() + 30분`

**pg_cron `process_pending_message_emails()`** (5분 주기 권장):
1. `email_send_at <= now()` AND `email_sent_at IS NULL` 메시지 조회 (`SELECT ... FOR UPDATE SKIP LOCKED` 로 직렬화)
2. **숨김·회수 직전 재확인 (race condition 방어, §9)**: 같은 트랜잭션 안에서 `hidden_by_admin_at IS NOT NULL` 또는 `self_withdrawn_at IS NOT NULL` 이면 → `email_skip_reason='cancelled'` 마킹 후 스킵. 회수 시간 25분과 메일 발송 30분 사이 5분 안전 마진이 있지만 pg_cron 실행 시점에 회수 직전 메시지 보호용
3. 인플루언서가 이미 읽었으면 → `email_skip_reason='read_in_time'` 마킹 후 스킵
4. 같은 응모건에 24시간 안 메일 발송 이력 있으면 → `email_skip_reason='rate_limited_24h'`
5. **묶음 처리**: 같은 `application_id` 의 미발송 메시지를 1통에 합쳐 발송 (대표 1건만 `email_sent_at` 채우고 나머지는 `merged_into_other`)
6. Edge Function 호출 → Brevo SMTP → 발송 성공 시 `email_sent_at = now()`

**메일 템플릿:**
- `message-influencer-pending` — 지연 발송용. 「안 읽은 새 메시지 N건」 미리보기 + 응모건 정보 + 앱 링크
- `message-admin-digest` — 관리자 일별 다이제스트 (전일 미답변 응모건별 그룹)

**Edge Function 2개:**
- `notify-message-influencer-pending` (pg_cron 호출, 큐 처리 + Brevo 발송)
- `notify-message-admin-digest` (pg_cron 일별)

**`docs/email-templates/`** 신규 파일 + `_templates/` 미러 + `scripts/sync-email-templates.sh` 동기화

**`admin_email_subscriptions`** 에 신규 mail_kind `message_digest` 추가 (`lookup_values(kind='admin_email_kind')` 시드 1건).

## 5. UI 변경

### 5-1. 인플루언서 — 응모이력 화면 (게시판형)
- 응모이력 행에 「メッセージ」 버튼 + 미읽음 배지 (관리자가 보낸 미읽음 수)
- 클릭 시 슬라이드업 풀스크린 모달:
  - **상단 헤더**: 캠페인 썸네일 + 제목 + 상태 + 신청일 + 자동 제목 「캠페인 X에 관한 문의」
  - **중간 메시지 영역**: 위→아래 누적 박스 카드. 각 카드는:
    - 보낸이 아바타·이름 (본인 / 운영팀)
    - 본문 (줄바꿈 보존, 링크 자동 변환)
    - 첨부 이미지 썸네일 (다중 가능, 클릭 시 라이트박스)
    - 보낸 시각 + 읽음 표시
    - 본인 카드와 관리자 카드는 배경색·테두리로 구분 (좌우 정렬 아님)
    - **본인 카드 우상단 ⋮ 메뉴**: 「メッセージを取り消す」 버튼 — 보낸 후 25분 안만 활성 (§3-5 ②). 클릭 시 확인 다이얼로그(「このメッセージを取り消しますか?」) → `withdraw_own_message` 원격 호출 함수(RPC) + 첨부 Storage 삭제. 25분 경과 시 메뉴 비노출
    - **숨김·회수 케이스별 회색 placeholder 카드** (본문·첨부 가림, 보낸이·시각 헤더만 노출):
      - 관리자 강제 숨김: 「[管理者により非表示処理されたメッセージ]」
      - 본인이 회수한 메시지: 「[本人が取り消したメッセージ]」
      - 관리자가 회수한 메시지: 「[管理者が取り消したメッセージ]」
  - **하단 입력 영역**:
    - 여러 줄 textarea (높이 4~6줄 기본, 길어지면 자동 확장)
    - 이미지 첨부 버튼 (다중, §3-2 클라이언트 압축 적용)
    - 전송 버튼 (입력칸 아래 우측)
  - 새 메시지 도착 시 「↓ 새 메시지」 배너 (자동 스크롤 안 함, 사용자 클릭 시 이동)
  - 응모 종료 90일 경과 시 입력 영역 비활성 + 「応募終了から90日経過しました」 안내

### 5-2. 인플루언서 — GNB 햄버거 메뉴
- 「メッセージ」 항목 신규 (전체 미읽음 배지)
- 클릭 시 미읽음 우선 정렬한 응모건 리스트 (각 행에 캠페인·마지막 메시지 미리보기·시각·미읽음 배지)

### 5-3. 관리자 — 응모 행 메시지 버튼
- 신청 관리·캠페인별 신청자·결과물 관리 페인 응모 행에 「메시지」 버튼 + **본인 미열람 배지** (개인별)
- 클릭 시 모달 (인플루언서 화면과 동일 구조, 단 한국어 UI)
- 모달 진입 시 자동으로 `mark_application_messages_read` 호출 → 본인 미열람 배지 0
- 모달 우상단 상태 표시 (Material Icons, 유니코드 기호·이모지 금지 — CLAUDE.md 규칙):
  - 응대 완료: Material Icon `check_circle` (초록) + 「응대 완료」 + `resolved_by_name` 표기 (그룹 공통, 다른 관리자 처리분 포함)
  - 미응대: Material Icon `warning` (빨강) + 「미응대」 (그룹 공통, 답장 또는 「응대 완료」 버튼 필요)
- 모달 하단 「응대 완료」 버튼 (모든 관리자):
  - 미응대 상태에서만 활성. 클릭 시 `mark_application_resolved` RPC 호출
  - 답장하면 자동으로 응대 완료 처리되므로, 이 버튼은 「LINE·전화 등 외부 처리」 시 사용
- 메시지 카드 ⋮ 메뉴 (권한별 비대칭, §3-5):
  - **본인 메시지** (자기가 보낸 것): 「회수」 버튼 — 보낸 후 25분 안만 활성 (`created_at + 25 minutes < now()` 면 disabled). 사유 입력 없이 즉시 처리. 양쪽 placeholder 처리(인플루언서 회수) / 인플루언서에게만 placeholder(관리자 회수)
  - **다른 사람 메시지** (campaign_admin 이상): 「숨김」 버튼 → 카테고리 드롭다운(`message_hide_reason` 7종) + 자유 메모 입력 모달 → 강제 숨김 처리 (§3-5 ①)
  - **숨김 상태 메시지** (super_admin 한정): 「복구」 버튼 → 복구 사유 메모 입력 모달(필수) → 강제 숨김 해제 (audit row 자동 생성, 인플루언서 알림 없음 — 조용한 복구)
- **숨김 이력 패널** (super_admin 한정): 메시지 모달 하단 또는 별도 탭에 `application_message_hide_history` 타임라인 표시 — action / by_user_kind / by_name / reason_code+memo / 시각. 운영팀 내부 부당 숨김 사례 감지·분쟁 대응용 (§3-5 audit)
- 메시지 본문 수정 자체는 불가 (숨김·회수만 가능). 본문 수정 기능은 v2 검토

### 5-3-2. 관리자 — 일괄 발송 모달 (BCC, §3-7)
- 진입: 사이드바 「메시지」 페인 우상단 「일괄 발송」 버튼 + 신청 관리·캠페인별 신청자 페인의 「선택된 N건에 발송」 버튼
- **모달 1단계 — 발송 단위 선택**:
  - 「캠페인 단위」 라디오 → 캠페인 검색·선택 → 응모자 필터(상태·채널·팔로워수) 적용 → 다중 선택 (전체 선택·필터 결과 전체 선택 버튼)
  - 「임의 응모건 다중 선택」 라디오 → 응모건 검색(인플루언서·캠페인) → 체크박스 다중 선택
- **모달 2단계 — 본문 작성**:
  - 게시판형 입력 (textarea, 다중 첨부)
  - 우상단에 「선택된 수신자 N명」 표시 + 미리보기
  - 「발송」 버튼 클릭 전 확인 모달: 「인플루언서 N명에게 같은 메시지를 발송합니다. 받는 사람들끼리는 서로 모릅니다 (BCC). 진행할까요?」
- **발송 후**: 「N명에게 발송 완료」 토스트 + 발송 그룹 상세로 이동 (§5-3-3)
- **수신자 0명 차단**: 필터 결과 0명·체크 0개면 발송 버튼 비활성

### 5-3-3. 관리자 — 발송 이력 페인 (사이드바 「메시지」 하위)
- 사이드바 「메시지」 클릭 시 기본은 받은편지함, 탭으로 「발송 이력」 전환
- 내가 보낸 일괄 발송 목록 (다른 관리자 발송도 super_admin 은 모두 열람):
  - 발송 시각 / 본문 미리보기 / 수신자 N명 / 읽음 N명 / 답장 N명 / **회수 여부 배지** (회색 「회수됨」 + 회수 시각·처리자 툴팁)
  - 컨텍스트 표시 (「캠페인 X 승인자」 / 「임의 선택 5건」)
- **회수된 broadcast 답장 카운트 처리 (결정 K — 회수돼도 답장 카운트 그대로 보존)**:
  - 인플루언서가 broadcast 회수 「전후」 모두 답장한 경우 두 시점 답장이 모두 「답장 N명」 카운트에 포함
  - 사유: 인플루언서 답장 행위는 broadcast 회수와 독립된 별개 활동. 회수해도 인플루언서 메시지는 살아있음 (회수는 관리자 발송분만). 「몇 명이 반응했는지」 통계 유용성 유지
  - UI: 답장 카운트 옆 작은 「(회수 후 답장 N건 포함)」 보조 표기 (회수된 broadcast 만)
- 행 클릭 시 발송 그룹 상세:
  - 본문·첨부 원본 (회수돼도 관리자에게 보임 — §3-5 첨부 영구 보존)
  - 수신자 목록 + 각 인플루언서별 「읽음 / 답장 / 미응대」 상태
  - 각 행 클릭 시 해당 응모건 메시지 모달로 이동 (§5-3)

### 5-3-4. 일괄 발송 메시지 표시 (받은편지함·메시지 모달)
- 받은편지함 행에 Material Icon `campaign` + 「일괄 발송 (N명에게 동시)」 작은 배지 (이모지 금지)
- 메시지 모달 안 카드에 같은 배지 + 클릭 시 발송 그룹 상세로 이동
- 인플루언서 화면에서는 일괄 발송 여부를 표시하지 않음 (BCC 패턴 — 본인이 N명 중 1명임을 모르게)

### 5-4. 관리자 — 사이드바 「메시지」 메뉴 신규
- 위치: 사이드바 「공지사항」 다음
- **사이드바 배지 = 「우리 팀 미응대 응모건 수」** (그룹 공통, 모든 관리자 동일 숫자)
- 페인 진입 시 통합 받은편지함:
  - **필터**: 캠페인 (multi-select), 인플루언서 검색, 「미응대 only」 토글, 「내 미열람 only」 토글, 기간 (기본 「최근 6개월」 + 「전체 보기」 토글)
  - **정렬**: 미응대 우선 → 마지막 메시지 시각 내림차순
  - **행 구성**:
    - 캠페인 썸네일 + 인플루언서 이름 + 마지막 메시지 미리보기 + 시각
    - **「미응대」 칩** (그룹 공통, 빨강) — `unresolved_for_admin_team=true`
    - **「내 미열람 N개」 칩** (개인별, 파랑) — 본인이 안 본 메시지 있을 때
    - 응대 완료 상태면 「응대 완료」 회색 칩 + `resolved_by_name`
  - 클릭 시 §5-3 모달과 동일 (자동 본인 읽음 처리)

### 5-5. 인플루언서 알림 모달
- 기존 알림 모달에 `message_received` kind 항목 추가 (다른 알림과 동일 패턴)
- 클릭 시 해당 응모건 메시지 모달로 이동 + 자동 읽음 처리

### 5-6. LINE 전환 안내 (인플루언서)
- 캠페인 상세·홈 풋터 LINE CTA → 「メッセージ」 안내로 단계 변경:
  - 1단계 (이번 배포): LINE CTA 옆에 「個別のお問い合わせはアプリの『メッセージ』からも可能」 안내
  - 2단계 (1개월 안정화 후): 개별 문의 CTA 는 앱 내 메시지로 변경, LINE CTA는 「最新お知らせ用」 라벨로 약화
  - 3단계 (장기): LINE 자동응답이 「개별 문의는 앱에서」 안내 (LINE 자체는 공지·캠페인 안내용으로 유지)

## 6. 영향 범위

| 영역 | 변경 |
|---|---|
| DB | 마이그레이션 129+ — 테이블 **5개** (`application_messages`, `application_message_admin_reads`, `application_message_resolutions`, `application_message_broadcasts`, **`application_message_hide_history`**) + 컬럼 추가 1개(`broadcast_id`) + **뷰 2개** (`application_message_summary` 집계용, `application_message_safe` 마스킹용 — 마스킹은 RPC 패턴 채택 시 1개로 축소 가능) + RPC **9개** (send / send_bulk / read / **hide(시그니처 변경)** / **unhide(신설)** / **withdraw_own(신설)** / **withdraw_broadcast(신설)** / resolve / admin_unread_counts) + Storage 버킷 1개 + lookup_values 시드 **2종** (`admin_email_kind` 1건 + **`message_hide_reason` 7건**) |
| Edge Functions | 신규 2개 (`notify-message-influencer`, `notify-message-admin-digest`) |
| 메일 템플릿 | `docs/email-templates/` 신규 2개 + `_templates/` 미러 |
| 인플루언서 코드 | 응모이력 / GNB / 알림 모달 + 신규 메시지 모달 + 첨부 업로드 + i18n 키 다수 |
| 관리자 코드 | 신청 관리·캠페인별 신청자·결과물 관리 응모 행 버튼 + 신규 사이드바 「메시지」 페인 + 모달 |
| 문서 | `FEATURE_SPEC.md`, `CLAUDE.md` (스키마·메일 섹션·LINE 정책 변경) |
| 약관 | **PRIVACY** 「수집 항목」에 메시지·첨부 추가, **TERMS** 「이용자 의무」에 부적절 메시지 금지 + 관리자 열람권 명시 — `/약관확인` 호출 필수 |

## 7. 의존성·실행 순서

선행:
- 마이그레이션 121 (link/unlink) 운영 적용 완료 필수
- 영수증 필수 입력 128 작업과 충돌 없음 (별도 영역, 이미 완료됨)

이번 작업 단계:
1. 사양서 §3 결정 사항 7개 — **본 사양서 작성 시점에 모두 확정** (개발 세션 시작 시 변경 없는지만 재확인)
2. 개발 세션 진입 시 `reverb-planner` 한 번 호출로 PR-1 우선순위 점검 (사양서 자체는 이미 PR 분할 권장안 포함)
3. PR 분할 권장 (큰 기능이라 1 PR 무리, 5단계로 점진 배포):
   - PR-1: DB 마이그레이션(테이블 **5개**·컬럼 1개) + lookup_values 시드(`message_hide_reason` 7건) + 개별 발송·읽음·**본인 회수(25분) RPC** + Storage 버킷 + 인플루언서 메시지 모달 (게시판형, 응모이력 진입만) + 본인 회수 버튼·placeholder 표시 + 첨부 Storage 즉시 삭제 클라이언트 cleanup
   - PR-2: 관리자 사이드바 「메시지」 페인 + 응모 행 버튼 + 받은편지함(미응대·내 미열람 칩) + 응대 완료 마킹 UI + **강제 숨김 모달(카테고리+자유 메모) + 복구 모달(super_admin) + audit 이력 패널(super_admin)**
   - PR-3: **일괄 발송 모달(BCC) + 발송 이력 페인** + 일괄 발송 RPC + **일괄 회수 RPC + 일괄 회수 UI(broadcast.withdrawn_* 컬럼 갱신)** + 메시지 카드 Material Icon `campaign` + 「일괄 발송」 배지
   - PR-4: 지연 큐(30분 미읽음) + 묶음 발송 + 야간 보류 + 24h 리마인더 한도 + 일별 다이제스트
   - PR-5: LINE 전환 1단계 안내 + i18n + 약관 반영
4. 각 PR 마다 `reverb-supabase-expert` (DB 변경 시) + `reverb-reviewer` + `reverb-qa-tester`
5. PR-1·PR-2 운영 배포 후 1주 안정화 → PR-3
6. PR-3 운영 1개월 후 LINE 전환 2단계 검토

## 8. 약관·개인정보 영향 (중요)

### 8-1. /약관확인 분석 결과 (2026-05-18 메인 세션 검증)

#### 중대 변경 판단
- ① 메시지 본문·첨부 이미지 수집 항목 신규 + ③ 관리자 열람권 신설 결합으로 **중대 변경**에 해당
- **사전 통지 7일**: 필수 — 한국 PIPA 「중요 사항 변경 시 7일 전 공지」 + 일본 APPI 「이용 목적 변경 사전 공지」 양쪽 트리거
- **재동의 절차**: 불필요 — 메시지는 「서비스 운영을 위한 통신 수단」 = 필수 서비스 이용 조건. 선택 동의 항목 아니므로 사전 통지로 충족

#### 운영 배포 일정 영향
- 운영 배포일 = D-day 라면 **D-7 일**에 앱 내 공지 + 메일 발송 + 정책 문서 시행일 명시
- 사전 공지 본문에 포함: 메시지 기능 출시 + 수집 항목(본문·첨부) + 보유 기간(응모 종료 후 1년) + 관리자 열람 범위 + 시행일

### 8-2. 정책 문서 갱신 — 확정 문구 5건 (한·일 양쪽)

운영 배포 시점에 아래 5건을 PRIVACY_kr·ja + TERMS_kr·ja 4종 모두 적용. 시행일은 운영 배포일로 명시.

#### A. PRIVACY_kr §2.1 인플루언서 회원 수집 항목 표에 행 추가

| 수집 시점 | 구분 | 항목 | 이용 목적 | 보유 기간 |
|---|---|---|---|---|
| 응모 후 운영 문의 | 필수 | 메시지 본문(텍스트)·첨부 이미지 | 응모건 관련 운영팀 문의·답변·증빙 | 응모 종료 후 1년 / 탈퇴 시 파기 |

PRIVACY_ja §2.1 同等行:
| 収集時点 | 区分 | 項目 | 利用目的 | 保有期間 |
|---|---|---|---|---|
| 応募後の運営お問い合わせ | 必須 | メッセージ本文(テキスト)·添付画像 | 応募件に関する運営チームへの問い合わせ·返信·証憑 | 応募終了後1年 / 退会時に破棄 |

#### B. PRIVACY_kr §6.1 보유 기간 표에 행 추가

| 보유 정보 | 보유 기간 | 근거 |
|---|---|---|
| 응모건 운영 메시지·첨부 | 응모 종료 후 1년 또는 탈퇴 시 파기(둘 중 빠른 시점) | 분쟁 대응·서비스 이용 기록 |

PRIVACY_ja §6.1 同等行: `応募件運営メッセージ·添付 / 応募終了後1年または退会時に破棄(いずれか早い時点) / 紛争対応·サービス利用記録`

#### C. PRIVACY_kr §9 기술적·관리적 조치 — 내부 접근 권한 항목 추가

```
- 응모건 메시지·첨부는 본인(인플루언서)과 운영팀 관리자(super_admin / campaign_admin / campaign_manager) 만 접근 가능합니다. 행 단위 보안 정책으로 다른 회원의 메시지는 본인이 열람할 수 없으며, 관리자 열람·다운로드는 감사 로그 대상입니다.
```

PRIVACY_ja §9 同等項目:
```
- 応募件メッセージ·添付は本人(インフルエンサー)と運営チーム管理者(super_admin / campaign_admin / campaign_manager)のみアクセス可能です。行単位セキュリティポリシーにより他会員のメッセージは本人が閲覧できず、管理者の閲覧·ダウンロードは監査ログ対象です。
```

#### D. TERMS_kr §제7조 (제공 서비스의 내용) 항목 7번 신규 (기존 6번 「기타 부가 서비스」는 8번으로 이동)

```
7. 응모건 단위 운영팀 메시지 채널(인플루언서 ↔ 운영팀 양방향, 텍스트·이미지 첨부)
8. 기타 회사가 정하는 부가 서비스
```

TERMS_ja §第7条 同等項目:
```
7. 応募件単位の運営チームメッセージチャネル(インフルエンサー ↔ 運営チーム双方向、テキスト·画像添付)
8. その他、当社が定める付加サービス
```

#### E. PRIVACY_kr §5 국외 이전 표에 행 추가

| 이전 항목 | 이전받는 자 | 이전 국가 | 이전 일시·방법 | 이용 목적 | 보유 기간 |
|---|---|---|---|---|---|
| 응모건 운영 메시지·첨부 | Supabase, Inc. | 호주(시드니) | 메시지 발송 시 실시간 네트워크 전송 | 응모건 문의 대응·증빙 | 응모 종료 후 1년 / 탈퇴 시 파기 |

PRIVACY_ja §5 同等行 (동일 컬럼 구조).

### 8-3. 운영 배포 직전 체크리스트 (개발 세션용)

- [ ] PRIVACY_kr·ja + TERMS_kr·ja 4종에 §8-2 A~E 5건 적용
- [ ] 4종 문서 상단 「최종 갱신일」 + 「시행일」 갱신
- [ ] 시행일 = 운영 배포일 (D-day)
- [ ] D-7 일 앱 내 공지 + 회원 메일 발송 준비
- [ ] 사전 공지 본문 작성: 메시지 기능 출시·수집 항목·보유 기간·관리자 열람 범위·시행일 모두 포함
- [ ] D-day 운영 배포 후 정책 변경 안내 푸시/공지 1회 추가

## 9. 보안 고려

- 행 단위 보안 정책 강제: 인플루언서는 본인 응모건만, 관리자는 전체. 원격 호출 함수(RPC) 가 sender_kind 자동 판별로 변조 차단
- **숨김·회수 본문·첨부 마스킹 (§3-5)**: 행 자체는 SELECT 가능하되 본문(`body`)·첨부(`attachments`) 컬럼은 `application_message_safe` 뷰 또는 SECURITY DEFINER 원격 호출 함수(RPC) 경유로 마스킹 처리. 행 단위 보안 정책 단독으로는 컬럼 단위 가시성 차등이 어려워 뷰·RPC 패턴 필수. 정확한 구현(뷰 vs RPC) 선택은 개발 세션 결정
- **숨김·회수 비대칭 분기**: 뷰·RPC 안에서 `(is_admin() OR NOT)` 과 `self_withdrawn_by_kind` 조합으로 마스킹 케이스 4종 분기 — 강제 숨김(인플루언서만 마스킹) / 인플루언서 본인 회수(양쪽 마스킹) / 관리자 본인 회수(인플루언서만 마스킹) / 일괄 회수(인플루언서만 마스킹)
- **첨부 업로드**: MIME 화이트리스트 + 파일 크기 한도 + Storage 정책 검증 (클라이언트 검사 단독 금지)
- **본인 회수 시 첨부 Storage 즉시 삭제 (§3-5 ②)**: SQL RPC 안에서 storage.objects 직접 삭제 불가 → 클라이언트가 `withdraw_own_message` RPC 호출 성공 후 attachments 경로로 `storage.from('application-message-attachments').remove([...])` 직접 호출. 또는 pg_cron 5분 주기로 `self_withdrawn_at IS NOT NULL AND attachments_cleaned_at IS NULL` 행 정리 Edge Function 호출 (개발 세션 결정)
- **본문 sanitize**: 인플루언서·관리자 모두 입력값을 esc 처리해 표시 (XSS 방어 — 교차 사이트 스크립팅(XSS))
- **회수·숨김 Rate limit**: 발송 RPC 와 별개로 `withdraw_own_message` 도 사용자별 시간당 한도 (예: 50건/시간) 적용 — 악의적 메시지 후 즉시 회수로 도배하는 패턴 방지
- **Rate limit**: 메시지 발송 RPC 에 사용자별 시간당 한도 (예: 100건/시간) — Brevo 메일 폭주 방지
- **audit 테이블 SELECT 한정**: `application_message_hide_history` 는 super_admin 만 SELECT 가능. campaign_admin 본인 처리 row 가시화는 v2 (§10)
- **첨부 다운로드 signed URL**: 5분 시한, audit 로그 (관리자 다운로드는 누가 언제 받았는지 기록 — v2)

## 10. 미해결 / 추후 검토 (v2)

- 담당자 배정·SLA·자동응답
- 인플루언서 신고·욕설 자동 필터
- **인플루언서 본인 메시지 「숨김 요청」 버튼** — 25분 회수 만료 후 인플루언서가 본인 메시지를 지우고 싶을 때 관리자에게 알림 + 승인·거절 워크플로 (§3-5)
- **campaign_admin 본인 처리 audit row 가시화** — `application_message_hide_history` SELECT 정책 확장 (현재 super_admin 전용)
- 메시지 검색 (본문 키워드)
- 메시지 라벨링 (배송 / 결과물 / 정산 등 카테고리)
- 첨부 파일 PDF 허용 검토
- 관리자 다운로드 audit 로그
- 응모 종료 후 90일 경과 시 자동 「다른 캠페인으로 신규 응모하기」 유도 안내
- **공통 이미지 압축 헬퍼 확산 적용** — 이번에 만드는 `dev/lib/image-compress.js` 를 영수증 제출·캠페인 이미지 업로드·미니 에디터 이미지 첨부 등 다른 업로드 흐름에도 적용. 별도 사양서로 분리 예정 (모바일 카메라 큰 파일 이슈 근본 해결)

---

## 구현 결과

**구현일:** (개발 세션이 채울 것)
**관련 커밋:** (개발 세션이 채울 것)
**PR:** (PR-1~4 링크 차례로)

### 초안 대비 변경 사항
- 추가된 것:
- 빠진 것:
- 달라진 것:

### 구현 중 기술 결정 사항
-
