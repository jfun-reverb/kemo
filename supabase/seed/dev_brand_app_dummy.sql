-- ============================================================
-- dev_brand_app_dummy.sql
-- 브랜드 서베이 신청 목록 UI 검증용 더미 데이터 (15건)
--
-- 대상 DB: 개발(qysmxtipobomefudyixw) 전용. 운영 DB 실행 금지!
-- 사용법: Supabase SQL Editor에 전체 붙여넣기 → Run
--
-- 채번 트리거가 application_no를 자동 생성하므로 명시 불필요.
-- 다양성 커버:
--   - form_type: reviewer 9건 / seeding 6건
--   - products 갯수: 1, 1, 2, 3, 5, 1, 2, 8, 1, 3, 4, 1, 1, 6, 2 (1~8개 분포)
--   - status: new(3) / reviewing(2) / quoted(2) / orient_sheet_sent(1) /
--             schedule_sent(1) / campaign_registered(1) / paid(2) / done(2) / rejected(1)
--   - 가격 폭: ¥500 ~ ¥25,000
--   - 수량 폭: 3 ~ 500개
--   - transfer_fee_krw: 3000, 5000, 7500, null 혼합
--   - 브랜드명 언어: 한국어 / 영문 / 일본어 / 한일 혼용
--   - admin_memo / quote_sent_at / request_note 길이 다양 (짧음/중간/매우 김 + 개행 포함)
-- ============================================================

INSERT INTO public.brand_applications (
  form_type, brand_name, contact_name, phone, email, billing_email,
  products, request_note, status, admin_memo, final_quote_krw, quote_sent_at
) VALUES

-- 1. reviewer · 1개 · new · 평균값
('reviewer', '뷰티스킨 코리아', '김지우', '010-1234-5678', 'kim.jiwoo@beautyskin.kr', 'tax@beautyskin.kr',
 '[{"name":"하이드라 부스터 세럼 50ml","url":"https://qoo10.jp/g/sample-001","qty":50,"price":2800,"transfer_fee_krw":5000}]'::jsonb,
 '리뷰어 분들께 자세한 사용법 동영상 가이드 함께 제공 부탁드립니다. 일본어 패키지 라벨 제공 가능합니다.',
 'new', NULL, NULL, NULL),

-- 2. reviewer · 2개 · reviewing
('reviewer', '오가닉 푸드 스토리', '박서연', '02-555-1234', 'park@organicfood.kr', NULL,
 '[{"name":"유기농 견과류 믹스 200g","url":"https://qoo10.jp/g/sample-002a","qty":30,"price":1500,"transfer_fee_krw":5000},
   {"name":"수제 그래놀라 250g","url":"https://qoo10.jp/g/sample-002b","qty":30,"price":1800,"transfer_fee_krw":5000}]'::jsonb,
 NULL,
 'reviewing', '담당자 휴가 중. 5월 6일 견적 전달 예정.', NULL, NULL),

-- 3. seeding · 1개 · quoted
('seeding', '내추럴 코스메틱', '이수민', '+82-10-9999-8888', 'sumin@naturalcos.com', 'billing@naturalcos.com',
 '[{"name":"아이크림 30ml","url":"","qty":20,"price":3500,"transfer_fee_krw":null}]'::jsonb,
 '나노 인플루언서 30명 정도 매칭 희망합니다. 30대 여성 타깃.',
 'quoted', '예상 견적 전달. 클라이언트 확인 대기 중. 5/3 후속 연락 예정.', 1100000,
 '2026-05-01 14:30:00+09'::timestamptz),

-- 4. reviewer · 3개 · paid
('reviewer', '주방의 마법', '최민준', '031-789-0123', 'choi@kitchenmagic.kr', 'finance@kitchenmagic.kr',
 '[{"name":"실리콘 주걱 3종 세트","url":"https://qoo10.jp/g/sample-004a","qty":15,"price":1200,"transfer_fee_krw":5000},
   {"name":"논스틱 프라이팬 24cm","url":"https://qoo10.jp/g/sample-004b","qty":15,"price":4800,"transfer_fee_krw":5000},
   {"name":"수제 우드 도마 L","url":"https://qoo10.jp/g/sample-004c","qty":15,"price":2500,"transfer_fee_krw":5000}]'::jsonb,
 '주방 카테고리 인플루언서 우선. 요리 콘텐츠 제작 가능자로 매칭 부탁드립니다.',
 'paid', '입금 확인 완료. 5/2 카톡방 생성 예정. 오리엔테이션 5/4.',
 1850000, '2026-04-25 10:00:00+09'::timestamptz),

-- 5. reviewer · 5개 · done · 캠페인 완료
('reviewer', '슈퍼키즈', '정하린', '010-2222-3333', 'jung@superkids.kr', 'tax@superkids.kr',
 '[{"name":"유아 스토리북 세트 (5권)","url":"https://qoo10.jp/g/sample-005a","qty":40,"price":2200,"transfer_fee_krw":5000},
   {"name":"한글 학습 카드 100종","url":"https://qoo10.jp/g/sample-005b","qty":40,"price":1500,"transfer_fee_krw":5000},
   {"name":"수학 워크북 미취학용","url":"https://qoo10.jp/g/sample-005c","qty":40,"price":1800,"transfer_fee_krw":5000},
   {"name":"색칠공부 키트 24색","url":"https://qoo10.jp/g/sample-005d","qty":40,"price":1200,"transfer_fee_krw":5000},
   {"name":"스티커 보상판 세트","url":"https://qoo10.jp/g/sample-005e","qty":40,"price":800,"transfer_fee_krw":5000}]'::jsonb,
 '주부맘 인플루언서 위주. 자녀 등장 시 모자이크 처리 필수 안내 부탁드립니다. 일본 가정 대상.',
 'done', '캠페인 완료. 결과 보고서 5/15까지 정리 예정. 재의뢰 가능성 있음.',
 3520000, '2026-04-10 09:00:00+09'::timestamptz),

-- 6. seeding · 2개 · rejected
('seeding', '글로우 스킨케어', '강민지', '010-7777-8888', 'kang@glowskin.kr', NULL,
 '[{"name":"비타민C 세럼 30ml","url":"","qty":25,"price":3200,"transfer_fee_krw":null},
   {"name":"리프팅 크림 50ml","url":"","qty":25,"price":4500,"transfer_fee_krw":null}]'::jsonb,
 '20대 여성 인플루언서 매칭. 광고 표기 가이드 사전 안내 필요.',
 'rejected', '2025년 컴플라이언스 이슈로 보류 결정. 재신청 가능.', NULL, NULL),

-- 7. reviewer · 2개 · orient_sheet_sent
('reviewer', '홈데코 라운지', '윤도현', '010-5555-6666', 'yoon@homedeco.kr', 'tax@homedeco.kr',
 '[{"name":"인테리어 우드 액자 A4","url":"https://qoo10.jp/g/sample-007a","qty":20,"price":2800,"transfer_fee_krw":5000},
   {"name":"향초 3종 세트 (라벤더/우드/시트러스)","url":"https://qoo10.jp/g/sample-007b","qty":20,"price":3500,"transfer_fee_krw":5000}]'::jsonb,
 NULL,
 'orient_sheet_sent', '오리엔테이션 5/2 발송. 응답 대기 중.', 1450000,
 '2026-04-30 16:00:00+09'::timestamptz),

-- 8. reviewer · 8개 · schedule_sent · 대형 신청
('reviewer', 'Beauty Glow Inc.', '서민호', '010-3344-5566', 'seo@beautyglow.com', 'finance@beautyglow.com',
 '[{"name":"스킨토너 200ml","url":"https://qoo10.jp/g/sample-008a","qty":100,"price":1800,"transfer_fee_krw":5000},
   {"name":"클렌징 폼 150ml","url":"https://qoo10.jp/g/sample-008b","qty":100,"price":1500,"transfer_fee_krw":5000},
   {"name":"에센스 50ml","url":"https://qoo10.jp/g/sample-008c","qty":100,"price":3500,"transfer_fee_krw":5000},
   {"name":"세럼 30ml","url":"https://qoo10.jp/g/sample-008d","qty":100,"price":4200,"transfer_fee_krw":5000},
   {"name":"아이크림 25ml","url":"https://qoo10.jp/g/sample-008e","qty":100,"price":3800,"transfer_fee_krw":5000},
   {"name":"수면팩 80g","url":"https://qoo10.jp/g/sample-008f","qty":100,"price":2200,"transfer_fee_krw":5000},
   {"name":"마스크팩 5매입","url":"https://qoo10.jp/g/sample-008g","qty":100,"price":1200,"transfer_fee_krw":5000},
   {"name":"클렌징 오일 200ml","url":"https://qoo10.jp/g/sample-008h","qty":100,"price":2800,"transfer_fee_krw":5000}]'::jsonb,
 '대규모 캠페인이라 진행 일정 사전 협의 필요합니다.\n관련 일정표는 별도 메일 첨부 예정입니다.',
 'schedule_sent', '일정표 5/3 발송. 클라이언트 확인 후 견적 확정 예정.', NULL, NULL),

-- 9. reviewer · 1개 · campaign_registered · 캠페인 등록 단계
('reviewer', 'Q10 글로벌 유통', '한유진', '02-3344-5566', 'han.yujin@q10global.kr', 'tax@q10global.kr',
 '[{"name":"프리미엄 홍삼 스틱 30포","url":"https://qoo10.jp/g/sample-009","qty":80,"price":4500,"transfer_fee_krw":5000}]'::jsonb,
 '40~50대 건강관심층 인플루언서 우선.',
 'campaign_registered', '캠페인 #2026-04-22 등록 완료. 모집 시작 5/5.', 4290000,
 '2026-04-20 11:00:00+09'::timestamptz),

-- 10. seeding · 3개 · new · 매우 짧은 정보
('seeding', 'F&B 스튜디오', '오지훈', '+82-10-1111-2222', 'oh@fnb.kr', NULL,
 '[{"name":"수제 잼 200g","url":"","qty":15,"price":1800,"transfer_fee_krw":null},
   {"name":"꿀 250g","url":"","qty":15,"price":2500,"transfer_fee_krw":null},
   {"name":"드립백 커피 10개입","url":"","qty":15,"price":1200,"transfer_fee_krw":null}]'::jsonb,
 NULL,
 'new', NULL, NULL, NULL),

-- 11. reviewer · 4개 · paid · 매우 긴 메모 (더보기 검증)
('reviewer', '스타일 클로젯', '임채원', '010-8899-7766', 'lim@styleclo.kr', 'finance@styleclo.kr',
 '[{"name":"베이직 티셔츠 (화이트)","url":"https://qoo10.jp/g/sample-011a","qty":25,"price":2800,"transfer_fee_krw":5000},
   {"name":"베이직 티셔츠 (블랙)","url":"https://qoo10.jp/g/sample-011b","qty":25,"price":2800,"transfer_fee_krw":5000},
   {"name":"슬랙스 (베이지)","url":"https://qoo10.jp/g/sample-011c","qty":25,"price":4500,"transfer_fee_krw":5000},
   {"name":"가디건 (네이비)","url":"https://qoo10.jp/g/sample-011d","qty":25,"price":5800,"transfer_fee_krw":5000}]'::jsonb,
 '20~30대 여성 패션 인플루언서로 매칭 부탁드립니다.\n착용샷 + 코디 제안 콘텐츠 가능자 우선이며,\n계절 트렌드 반영해주시면 좋겠습니다.',
 'paid', '입금 5/1 확인 완료. 카톡방 생성 5/2.\n\n[중요 협의사항]\n- 사이즈 표기는 일본 기준(S/M/L)으로 통일\n- 컬러는 영문(white/black/beige/navy)+한글 병기\n- 배송 추적은 EMS 송장번호 공유\n- 결과물은 2026-05-20까지 제출 마감\n- VAT 포함 견적이며 추가 수수료 없음 확인됨\n\n클라이언트 측 요청으로 인플루언서 모집 시 패션 카테고리 팔로워 5천 이상 우선 고려.',
 2780000, '2026-04-28 09:30:00+09'::timestamptz),

-- 12. reviewer · 1개 · done · 럭셔리 (가격 매우 높음)
('reviewer', '프리미엄 워치 갤러리', '강시현', '02-777-8888', 'kang@premiumwatch.kr', 'tax@premiumwatch.kr',
 '[{"name":"오토매틱 손목시계 (스테인리스)","url":"https://qoo10.jp/g/sample-012","qty":5,"price":25000,"transfer_fee_krw":7500}]'::jsonb,
 '럭셔리 카테고리 메가 인플루언서 5명 한정 매칭. 30대 남성 우선.',
 'done', '캠페인 완료. ROAS 320% 달성. 재진행 협의 중.', 1450000,
 '2026-04-05 14:00:00+09'::timestamptz),

-- 13. seeding · 1개 · reviewing · 저가 (가격 매우 낮음)
('seeding', '데일리 스낵 코리아', '김다현', '010-4455-6677', 'kim@dailysnack.kr', NULL,
 '[{"name":"미니 초콜릿 5개입","url":"","qty":200,"price":500,"transfer_fee_krw":null}]'::jsonb,
 '대량 시딩 (200명). MZ세대 푸드 인플루언서 위주.',
 'reviewing', '단가 낮은 대량 시딩 건. 견적 검토 중.', NULL, NULL),

-- 14. reviewer · 6개 · quoted · 매우 긴 요청사항 (개행 포함)
('reviewer', '株式会社グリーンライフ (한국법인)', '中村 美優', '+81-90-1234-5678', 'nakamura@greenlife.jp', 'tax@greenlife.jp',
 '[{"name":"식물 키우기 키트 (선인장)","url":"https://qoo10.jp/g/sample-014a","qty":35,"price":1500,"transfer_fee_krw":5000},
   {"name":"식물 키우기 키트 (다육이)","url":"https://qoo10.jp/g/sample-014b","qty":35,"price":1800,"transfer_fee_krw":5000},
   {"name":"미니 화분 3종","url":"https://qoo10.jp/g/sample-014c","qty":35,"price":2200,"transfer_fee_krw":5000},
   {"name":"식물영양제","url":"https://qoo10.jp/g/sample-014d","qty":35,"price":1200,"transfer_fee_krw":5000},
   {"name":"가드닝 도구 4종 세트","url":"https://qoo10.jp/g/sample-014e","qty":35,"price":3500,"transfer_fee_krw":5000},
   {"name":"식물 라벨 스티커","url":"https://qoo10.jp/g/sample-014f","qty":35,"price":600,"transfer_fee_krw":5000}]'::jsonb,
 '【 진행 조건 】\n1. 식물/가드닝 카테고리 인플루언서 한정\n2. 20~40대 여성 우선\n3. 키우는 과정 동영상 콘텐츠 가능자\n\n【 콘텐츠 가이드 】\n- 발아부터 성장까지 주 1회 업로드 (총 4주)\n- 마지막 영상에 #PR #광고 표기 필수\n- 제품 패키지 노출 1회 이상\n\n【 기타 】\n- 일본어 안내문 별도 동봉\n- 배송 지연 시 사전 공지\n- 문제 발생 시 24시간 내 응대 원칙',
 'quoted', '클라이언트 측 견적 확인 대기. 5/4 회신 예정.', 1620000,
 '2026-04-29 10:30:00+09'::timestamptz),

-- 15. reviewer · 2개 · new · 영문 + 한일 혼용
('reviewer', 'Korea-Japan Cosmetics', 'Lee Min Ho', '010-9988-7766', 'lee@kjcosmetics.com', NULL,
 '[{"name":"BB Cushion 15g","url":"https://qoo10.jp/g/sample-015a","qty":60,"price":3200,"transfer_fee_krw":3000},
   {"name":"Lip Tint Set (3종)","url":"https://qoo10.jp/g/sample-015b","qty":60,"price":2800,"transfer_fee_krw":3000}]'::jsonb,
 'K-Beauty 인플루언서 위주. JP→KR 트래픽 유도 목적.',
 'new', NULL, NULL, NULL);


-- ============================================================
-- 검증 SQL (선택)
-- ============================================================
/*
SELECT application_no, form_type, brand_name, status,
       jsonb_array_length(products) AS prod_cnt,
       total_qty, total_jpy, estimated_krw, final_quote_krw,
       quote_sent_at IS NOT NULL AS quote_sent,
       admin_memo IS NOT NULL AS has_memo,
       (length(coalesce(admin_memo, '')) > 40 OR admin_memo LIKE '%' || E'\n' || '%') AS memo_long
FROM public.brand_applications
ORDER BY created_at DESC
LIMIT 20;

-- 상태별 분포
SELECT status, COUNT(*) FROM public.brand_applications GROUP BY status ORDER BY status;

-- 폼 종류별 분포
SELECT form_type, COUNT(*) FROM public.brand_applications GROUP BY form_type;
*/
