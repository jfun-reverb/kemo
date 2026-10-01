---
description: 기준 데이터·자주 묻는 질문 관리·주의사항/참여방법/NG 번들·민감 항목 변경 경고·캠페인 변경 이력(묶음 규칙)
paths:
  - "dev/js/admin-lookups.js"
  - "dev/js/admin-faq.js"
  - "dev/js/admin.js"
  - "dev/js/mypage.js"
  - "dev/lib/shared.js"
  - "dev/lib/storage.js"
  - "dev/lib/i18n/ja.js"
  - "dev/admin/index.html"
  - "supabase/migrations/*caution*"
  - "supabase/migrations/*participation*"
  - "supabase/migrations/*ng_set*"
  - "supabase/migrations/*change_history*"
  - "supabase/migrations/*faq*"
  - "supabase/migrations/*lookup*"
---

# 기준 데이터·번들·변경 이력 (CLAUDE.md 기준 데이터·번들·관리자 계정 절에서 옮겨 옴 — 2026-10-01 조각 D′)
- **기준 데이터 관리**(`/admin#lookups`): 채널/카테고리/콘텐츠 종류/NG 사항/반려사유/블랙리스트·위반 사유/주의사항/취소 사유/메일 종류 등을 한국어·일본어로 관리(campaign_admin 이상). 항목 활성/비활성 토글, 순서 변경 모드, 사용 중이면 hard delete 차단(soft delete 만). 채널은 모집 타입(monitor/gifting/visit) 다중 지정. code 자동 생성·비공개
- **자주 묻는 질문(FAQ) 관리**(`/admin#faq`, campaign_admin 이상): 응모건 메시지 자동응답 등록 페인. 좌우 2단(카테고리 | 질문 + 측정 배지[조회수·직접문의 전환수]) + 편집 모달(한/일 2열·화면이동 드롭다운·handoff·단계 다중선택·미리보기)
- **주의사항 번들**(`caution_sets`): 폼 콘텐츠 가이드 섹션 — 번들 드롭다운(recruit_type 필터) + "번들 다시 불러오기". 저장 시 스냅샷 복사
- **참여방법 번들**(`participation_sets`): 1~6단계, title/desc ko·ja, recruit_types[] 필터. 스냅샷 `participation_steps jsonb`
- **NG 번들**(`ng_sets`): caution_sets 미러. items `{html_ko, html_ja}` (DOMPurify, inline 서식만). `campaigns.ng_set_id` + `ng_items jsonb`. 인플은 jsonb 우선 + legacy `campaigns.ng` 폴백
- **민감 항목 변경 경고**: `caution_items`/`participation_steps`/`ng_items` 변경 시 `#sensitiveChangeModal`. closed 캠페인은 변경 차단 트리거. 이력 `campaign_caution_history` → 「변경 이력」(super_admin) + 인플 응모이력 「現在の文言と比較」 토글
- **변경 이력 = 전체 항목**(마이그레이션 265·266): 「변경 이력」 모달이 3영역 + **48개 항목**을 시각 역순 한 목록으로. **실제로 안 바뀐 기록은 접어 둠**. 변환 `CAMPAIGN_FIELD_LABELS`/`campaignFieldValueText`(shared.js), 렌더 `campaignChangeCardHtml`/`campaignChangeRowHtml`(admin.js). 열람은 super_admin 하드코딩
- **변경 이력 차이 표시**: **항목 단위 차이 목록**(`renderSensitiveDiffSection`/`renderSensitiveDiffRow`, admin.js) — 바뀐 글자만 강조, 한·일 둘 다. 엔진은 `dev/lib/shared.js`(`diffSensitiveItemLists`/`diffChars`/`richToPlainText`/`textSimilarity`/`sensitiveListsIdentical`) — **리치 HTML에 강조 태그를 직접 끼우지 않고** sanitize→텍스트→글자 비교→이스케이프 후 강조(태그 붕괴·저장형 XSS 차단). 상한 1200자·변경 비율 60% 초과 시 전문 비교 폴백. 저장 전 경고 모달(`#sensitiveChangeModal`)은 아직 옛 2단 표시
- **편집 모달 분리**: 참여방법/주의사항 편집을 별도 모달로, 注意事項 미리보기 한·일 토글
