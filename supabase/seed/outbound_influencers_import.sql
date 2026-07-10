-- ============================================================
-- outbound_influencers_import.sql
-- 인플루언서 추천 도구 1단계-c — 영업팀 구글시트 → outbound_influencers 이관
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md
-- 인계서: docs/specs/2026-07-09-influencer-recommendation-stage1-handoff.md §PR 1단계-c
--
-- 출처 시트: Google Drive fileId 1_60ClsHen1hE0WnXNsI_j567idEPOl0xtFn8f7aywhs
--   (영업팀 아웃바운드 인플루언서 명단, 약 50명, globalreverb 미가입)
-- 대상 테이블: public.outbound_influencers (마이그레이션 226)
-- 기준 데이터 코드: ob_category/ob_series/ob_tier (마이그레이션 227 시드)
--
-- ⚠️ 통화: 가격 5종(price_tiktok/feed/reels/story/secondary)은 모두 **엔화(¥)**.
--   시트 원본이 엔화 표기(사용자 확정 2026-07-09). 콤마·¥ 제거한 정수만 저장.
--
-- ⚠️ 적용 순서: 개발 DB(qysmxtipobomefudyixw)에 먼저 적용 → 검증 → 운영.
--   실행 전 마이그레이션 226·227이 해당 DB에 반영되어 있어야 한다.
--   (RLS 는 authenticated + has_permission('outbound.view','write') 라 SQL Editor
--    service_role 세션은 정책 우회로 INSERT 된다.)
--
-- ⚠️ 멱등성 없음(1회용 seed): 이 파일은 UNIQUE 제약이 없는 신규 INSERT 이므로
--   **두 번 실행하면 50행이 그대로 중복 삽입**된다. 재실행 금지.
--   재적용이 필요하면 먼저 기존 이관분을 지운 뒤(예: 아래 정리 SQL) 다시 실행:
--     -- DELETE FROM public.outbound_influencers;   -- (수동 등록분이 섞이기 전 초기 이관 한정)
--
-- 정제 규칙(적용 완료):
--   1) 스프레드시트 수식 오류값 ¥46,167 은 어느 가격 칸이든 NULL 처리
--      (코콘·은아·니타마고·미요코 5셀 — 실제 단가 아님)
--   2) 가격 칸에 날짜/시각이 들어간 값(예 26-05-24 19:09)은 NULL
--      (키키마루·우사미미·카렌·호노피스 스토리 칸)
--   3) 빈 가격·빈 팔로워 = NULL (0 아님). 명시적 0 은 0 저장(피이 X팔로워)
--   4) nego_memo mojibake(깨진 이모지) 정리: ð¯ðµ→일본, ð°ð·→한국, ð¬ð¦·ð´ 제거
--   5) SQL 이스케이프: 작은따옴표는 '' (원본 데이터엔 작은따옴표 없음 확인)
--   6) nego_memo = 부가설명 + 소속별 시딩 비용 + 기타 코멘트 (레이블 [] 로 구분)
--   7) 월별(01~12월) 컬럼은 매핑 제외(시트에 소속/캠페인 메모가 산발적으로 섞여 있으나
--      구조화 정보 아님). 소속사는 시트 「소속사」 컬럼만 사용(대부분 비어 있음).
-- ============================================================

INSERT INTO public.outbound_influencers (
  id, name_ko, account_id, ig_handle, ig_followers,
  tiktok_handle, tiktok_followers, youtube_handle, youtube_followers,
  x_handle, x_followers, category_code, series_code, tier_code,
  price_tiktok, price_feed, price_reels, price_story, price_secondary,
  contact_channel, agency, nego_memo, availability, content_consent, is_active
) VALUES
-- 1. 코콘
(gen_random_uuid(), '코콘', 'cocon_makeup', 'cocon_makeup', 40000,
 NULL, NULL, NULL, NULL,
 'cocon_makeup', 1586, 'color', 'beauty', 'micro',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 1. 피드 1건 50,000엔 / 피드2건 콘텐츠 제작 80,000엔 / 스토리 1개 10,000엔', 'available', false, true),
-- 2. 마슈
(gen_random_uuid(), '마슈', 'marsh_stagram', 'marsh_stagram', 49000,
 'marsh_mako', 8432, 'marsh_mako', 4240,
 NULL, NULL, 'color', 'beauty', 'micro',
 NULL, 50000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 피드/릴스1회 + 스토리 +@', 'available', false, true),
-- 3. 사치카
(gen_random_uuid(), '사치카', 'schk_maru', 'schk_maru', 62000,
 NULL, NULL, 'sachikanchi', 1130,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 60000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 피드/릴스1회 + 스토리 +@ / 별도 문의했을 때 투고 10만엔, 릴에 12만엔 [250806/순희/라인] 릴스1회 + 스토리4회 : 130,000엔+세금으로 가능', 'available', false, true),
-- 4. 아야카
(gen_random_uuid(), '아야카', 'aya.v_v.ka', 'aya.v_v.ka', 150000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'vlog', 'life', 'middle',
 NULL, 50000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] [앞으로 진행안하는게 좋을듯] 3개월 고정 20만엔 한달 단위X 3개월 20 5만엔 해줄듯(05월18일/변경) / 10만엔 / 3개월 20만엔', 'available', false, true),
-- 5. 체스카
(gen_random_uuid(), '체스카', 'rinachesca', 'rinachesca', 90000,
 'rinachesca', 27800, 'RinaFranchesca1', 3760,
 'rinachesca', 1906, 'color', 'beauty', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
-- 6. 아스카
(gen_random_uuid(), '아스카', 'asuka_skincare', 'asuka_skincare', 52000,
 'asuka_skincare', 12000, NULL, NULL,
 NULL, NULL, 'base', 'beauty', 'middle',
 NULL, 75000, 75000, 5000, NULL,
 '한나', NULL, '[부가설명] 1. 1 팔로워 1.5엔 세금별도(3주 이상 확보 스케쥴) 2. 1팔로워 2엔 세금별도(2주 이내 경우) - 2차 이용 : 1개월 50,000엔 세금 별도 / 파트너쉽 광고 3. 스토리 : -----7/8 한나님 회신 --- ①도착부터 초안까지 2주이내의경우 1 팔로어×2엔 세금 별도 ·3주 이상 확보할 수 있는 경우 1 팔로어×1.5엔 세금 별도 이차 이용 --> 광고 전달 1개월 50,000엔 세금 별도 기타 --> 일본에서 이체하는 경우 세금이 듭니다. 한국에서 이체하는 경우 세금대상에서 제외되지만, 폐사 입금시에 외화송금수령수수료가 반드시 차감되므로 +3000엔 받았습니다. ②콜라보 1회분의 투고 비용(최저 보증액으로서) / 1 팔로워 × 1.5엔~ / 매상 비율 → 평균 12-15%', 'available', false, true),
-- 7. 린
(gen_random_uuid(), '린', 'happy_cosme3150', 'happy_cosme3150', 48000,
 'happy_cosme', NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'micro',
 NULL, 77000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 7.7만엔', 'available', false, true),
-- 8. 카나코 (knk_csmpink)
(gen_random_uuid(), '카나코', 'knk_csmpink', 'knk_csmpink', 54000,
 'knk_csmpink', 3470, 'knk_csmpink', 49,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 50000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 5만엔', 'available', false, true),
-- 9. 하루
(gen_random_uuid(), '하루', 'fleurir_personalcolor', 'fleurir_personalcolor', 32000,
 NULL, NULL, NULL, 212,
 'fleurir_pc', 20900, 'color', 'beauty', 'micro',
 NULL, 30000, NULL, NULL, 10000,
 '한나', NULL, '[부가설명] 05월18일 3만엔으로 변경 됨 / 기 작성 : 단순 시딩 : 5만엔/ 2차사용 : 1만엔~', 'available', false, true),
-- 10. 피이
(gen_random_uuid(), '피이', 'piii_xx_01', 'piii_xx_01', 51000,
 'piii_xx_01', 1517, NULL, NULL,
 'piii_xx_01', 0, 'color', 'beauty', 'middle',
 NULL, 85000, 96000, NULL, NULL,
 '한나, JFUN', NULL, '[부가설명] 신규 : 인스타그램+틱톡+립스 : 150,000엔 과거 : 콜라보X 단순투고 7만엔 ------jfun -----[250703/DM회신] 릴 96,000엔 / 피드 85,000엔', 'available', false, true),
-- 11. 카린
(gen_random_uuid(), '카린', 'karin__life', 'karin__life', 146000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'vlog', 'life', 'middle',
 NULL, 180000, 250000, 30000, NULL,
 '한나', NULL, '[부가설명] (05월18일/변경) 10만엔으로/ 5만엔 [251105/신지상답변/순희] 인스타그램 피드 1회 : 18만엔 인스타그램릴 1회 : 25만엔 인스타그램 스토리 1회 : 3.0만엔 / 장 ※모두 세금 별도', 'available', false, true),
-- 12. 아카네
(gen_random_uuid(), '아카네', 'cosmesalan', 'cosmesalan', 43000,
 'cosmesalan', 2206, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'micro',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 13. 낫짱
(gen_random_uuid(), '낫짱', 'natsu._.beauty', 'natsu._.beauty', 79000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 100000, 100000, NULL, NULL,
 '한나', NULL, '[부가설명] 1투고+스토리2회 : 70,000엔에서 100,000엔으로 변경 요청 최종적으로는 1릴에 7만엔으로 진행함', 'available', false, true),
-- 14. 유이
(gen_random_uuid(), '유이', 'msyui313', 'msyui313', 100000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 15. 모미
(gen_random_uuid(), '모미', 'momomi_makino', 'momomi_makino', 51000,
 'momomi_makino', NULL, 'momomi_makino', 2130,
 'Momomi_arrest', 3446, 'color', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 16. 토모리
(gen_random_uuid(), '토모리', 'tomilly101', 'tomilly101', 181000,
 'tomilly101', 45200, NULL, 19700,
 'tomilly101', 5925, 'base', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 17. 미코
(gen_random_uuid(), '미코', 'mwnail.kt', 'mwnail.kt', 45000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'micro',
 NULL, 45000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성 1투고 1스토리 5만엔 수익쉐어 15%', 'available', false, true),
-- 18. 케코
(gen_random_uuid(), '케코', 'keko_blog', 'keko_blog', 37000,
 'kekoyakedo', 77100, NULL, NULL,
 'keko_blog', 1204, 'base', 'beauty', 'micro',
 NULL, 30000, NULL, NULL, NULL,
 '한나, 아유네', NULL, '[부가설명] 시딩 금액 : 05월18일/작성 [소속별 시딩 비용] -한나: ¥30,000 -아유네: ¥66,600', 'available', false, true),
-- 19. 히마
(gen_random_uuid(), '히마', 'hima323232', 'hima323232', 23000,
 '_hima323232', 14300, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'micro',
 NULL, 30000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 20. 나라
(gen_random_uuid(), '나라', 'keana_nara', 'keana_nara', 124000,
 'keana_nara', 64500, 'keana_nara', 49500,
 NULL, NULL, 'base', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나, 아유네', NULL, '[부가설명] 한나님 소통가능 [소속별 시딩 비용] -한나: - -아유네: ¥217,800 [기타 코멘트] [순희: 눈, 립 화장에 특화]', 'available', false, true),
-- 21. 한나
(gen_random_uuid(), '한나', 'honey0627_', 'honey0627_', 65000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 22. 유이카
(gen_random_uuid(), '유이카', 'yuika00802', 'yuika00802', 75000,
 NULL, NULL, NULL, NULL,
 'yuika_0802', 2063, 'fashion', 'fashion', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
-- 23. 미미탄
(gen_random_uuid(), '미미탄', 'mimitan090909', 'mimitan090909', 116000,
 NULL, NULL, NULL, 73900,
 'mimitan090909', 75500, 'base', 'beauty', 'middle',
 NULL, 510000, 600000, NULL, 120000,
 '한나, JFUN', NULL, '[부가설명] [250724/ 신지상 회신] 아리얼 제안시 가격 릴스 게시 + 스토리 게시: 600,000엔 피드 게시 + 스토리 게시: 510,000엔 2차 활용 1개월: 120,000엔', 'available', false, true),
-- 24. 나오미
(gen_random_uuid(), '나오미', 'naomi_majima', 'naomi_majima', 1009000,
 'naomi_majima', 245900, NULL, NULL,
 'naomi_majima', 695800, 'fashion', 'fashion', 'mega',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 25. 안짱
(gen_random_uuid(), '안짱', 'annpeach__', 'annpeach__', 76000,
 'annpeach__', 152100, NULL, 98100,
 'annpeach__', 4655, 'color', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 26. 아유네
(gen_random_uuid(), '아유네', 'ayune____', 'ayune____', 107000,
 NULL, NULL, NULL, 14200,
 'ayumi_1022_', 20100, 'kidsmom', 'life', 'middle',
 NULL, 100000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
-- 27. 아리사
(gen_random_uuid(), '아리사', 'arisa_deguchi', 'arisa_deguchi', 89000,
 NULL, NULL, NULL, NULL,
 'deguchiarisa', 29200, 'fashion', 'fashion', 'middle',
 NULL, 90000, NULL, 50000, NULL,
 '한나, JFUN', NULL, '[부가설명] 251127 라인방 회신 ◾️ 릴 투고 (1 개) 해본 적이 없어요. ◾️ 피드 게시물 (1 개) 9만~ ◾️ 스토리 투고 (1개 ~ 복수) 5만~ ◾️콜라보 진행 경험 없음', 'available', false, true),
-- 28. 카나코 (11kanaco14)
(gen_random_uuid(), '카나코', '11kanaco14', '11kanaco14', 94000,
 '11kanaco14', 17500, '11kanaco14', 5100,
 'kanaco1114', 120400, 'fashion', 'fashion', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 29. 모모코
(gen_random_uuid(), '모모코', 'momosan0627', 'momosan0627', 200000,
 'momosan0627', 69900, NULL, NULL,
 'momosan0627', 84900, 'food', 'food', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 'JFUN', '개인', NULL, 'available', false, true),
-- 30. 나코
(gen_random_uuid(), '나코', 'nako_iimonohakken', 'nako_iimonohakken', 86000,
 'nako_iimonohakken', 1657, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 85000, 100000, 10000, NULL,
 '한나, JFUN', NULL, '[부가설명] [250702/DM회신] 릴스 1회 100,000엔 / 피드 1회 85,000엔 / 스토리 1회10,000엔 [250905/순희/카라코리스트] 피드 투고: ¥180,000 릴스 투고: ¥225,000 2차 활용(2개월): ¥30,000', 'available', false, true),
-- 31. 키키마루
(gen_random_uuid(), '키키마루', 'kikigram_97', 'kikigram_97', 436000,
 'kikidayo', 433900, NULL, NULL,
 'kikidayo_97', 83900, 'vlog', 'life', 'mega',
 NULL, NULL, 400000, NULL, NULL,
 '한나, JFUN', NULL, '[부가설명] [251209 라인회신] 타이업 비용 ·릴스 : 40만엔 ( TikTok/X/Threads에도 전재 예정 )', 'available', false, true),
-- 32. 은아
(gen_random_uuid(), '은아', 'xtrina2', 'xtrina2', 195000,
 NULL, NULL, 'UNA_TV', 99500,
 NULL, NULL, 'vlog', 'life', 'middle',
 NULL, NULL, 1350000, 250000, 380000,
 '한나, JFUN', NULL, '[부가설명] 인스타 40만엔 틱톡 40만엔 둘다면 할인해서 60만엔 [250617/DM회신] 첫 진행비용 틱톡 125만엔 / 릴스 125만엔 / 스토리 22만엔 메가와리기간 비용 틱톡 135만엔 / 릴스 135만엔 / 스토리 25만엔 등 2025년 은아님 자세한 가격 표 https://docs.google.com/spreadsheets/d/100w07CtVwzSdPy4mzTyFJUC7Z-Fc-vUzP-SNLxGn8zo/edit?gid=0#gid=0 [소속별 시딩 비용] -한나: ¥400,000 -기타: -', 'available', false, true),
-- 33. 우사미미
(gen_random_uuid(), '우사미미', 'usamimi080', 'usamimi080', 52000,
 'usamimi080', 59000, NULL, NULL,
 NULL, NULL, 'other', 'other', 'middle',
 80000, 50000, NULL, NULL, NULL,
 '한나, 기타, JFUN', 'tag', '[부가설명] 250818 tag 소속사 리스트에서 추가 [소속별 시딩 비용] -한나: - -기타: -', 'available', false, true),
-- 34. 니타마고
(gen_random_uuid(), '니타마고', '__nitamago__', '__nitamago__', 154000,
 '_nitamago', 362300, '__nitamago__', 473000,
 '__nitamago__', 45400, 'color', 'beauty', 'middle',
 NULL, 250000, 450000, 80000, NULL,
 '한나, 아유네, JFUN', NULL, '[부가설명] info@nitamagoch.com [2507/22/라인회신] ▼타이업 비용 (세금 제외) 조율가능 ・릴스 게시물 (1건): 450,000엔~ ・피드 게시물 (1건): 200,000~~250,000엔 ・스토리 게시물 (1장~~): 80,000엔~ (*하이라이트 설정은 별도) ※ 모든 금액은 세금 별도 기준입니다. 해외에서 송금 시 비과세로 처리되는 경우, 소비세 10%를 추가한 금액으로 제안해 주시면 감사하겠습니다. ※ 2차 활용 비용은 별도로 발생하오니 미리 양해 부탁드립니다. [소속별 시딩 비용] -한나: - -아유네: 277200', 'available', false, true),
-- 35. 카렌
(gen_random_uuid(), '카렌', 'berobero_baaa', 'berobero_baaa', 123000,
 'berobero__baaa', 260000, 'berobero_baaa', 928,
 'satoukaren_desu', 40400, 'vlog', 'life', 'middle',
 NULL, 70000, 70000, NULL, NULL,
 '한나', NULL, '[부가설명] 앞으로 진행할 때는 릴 1건 + 스토리 5건으로해서 15만엔으로 협의하는게 좋을 듯 처음에는 4만엔 / 5만엔 제안함 릴스 1 스토리 4개 10만엔 콜라보 20만엔 (릴스1+스토리4+틱톡1/수익쉐어X) - -6월09일 : 릴은 7만~ / 스토리는 2만엔 정도', 'available', false, true),
-- 36. 미요코
(gen_random_uuid(), '미요코', 'miyoko.myondon', 'miyoko.myondon', 19000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'base', 'beauty', 'micro',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 37. 세토
(gen_random_uuid(), '세토', 'mi10mi18', 'mi10mi18', 130000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'food', 'food', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 38. 메구
(gen_random_uuid(), '메구', 'megukiss0517', 'megukiss0517', 169000,
 'megukiss0517', 1345, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 39. 마이
(gen_random_uuid(), '마이', 'environs31', 'environs31', 98000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'kidsmom', 'life', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 40. 시바 코노나
(gen_random_uuid(), '시바 코노나', 'konona.official', 'konona.official', 84000,
 NULL, NULL, NULL, NULL,
 'konona0214shiba', 5805, 'kidsmom', 'life', 'middle',
 NULL, 200000, NULL, NULL, NULL,
 'JFUN', NULL, '[부가설명] 1. 조건 - 월 4회 =80만엔 / 월 5회 = 90만엔 / 월 6회 = 100만엔 2. 포스팅 진행 방식 / 스토리 4~5회/피드or릴스1번+2차 활용 [소속별 시딩 비용] -JFUN: ¥200,000 -아유네: ¥156,600', 'available', false, true),
-- 41. 미키치
(gen_random_uuid(), '미키치', 'mikichi0726', 'mikichi0726', 27000,
 'mikichi119', 2696, NULL, NULL,
 'mikichi1979', 19600, 'base', 'beauty', 'micro',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 42. 안나
(gen_random_uuid(), '안나', 'annatsumura_', 'annatsumura_', 28000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'fashion', 'fashion', 'micro',
 NULL, 20000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 43. 호노피스
(gen_random_uuid(), '호노피스', 'noponopisu2', 'noponopisu2', 168000,
 'noponopisu2', 830000, 'noponopisu2', 59800,
 'noponopisu2', 5565, 'color', 'beauty', 'middle',
 1450000, 250000, 800000, NULL, NULL,
 '호노피스', NULL, '[부가설명] 【TikTok】 ＜스킨케어·샴푸＞ TikTok 게시물: 1,250,000엔 + 세금 ※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 합니다. Spark Ads를 이용하지 않을 경우 1,450,000엔에 진행됩니다. Spark Ads(1개월): 200,000엔 + 세금 ＜그 외 카테고리＞ TikTok 게시물: 1,150,000엔 + 세금 ※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 하며, Spark Ads를 이용하지 않을 경우 1,350,000엔에 진행됩니다. Spark Ads(1개월): 150,000엔 + 세금 릴스 영상을 TikTok에 전재: 1,150,000엔 + 세금 ※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 하며, Spark Ads를 이용하지 않을 경우 1,350,000엔에 진행됩니다. 【Instagram】 ＜스킨케어·샴푸＞ 릴스 게시물: 800,000엔 + 세금 ※ 피드에 유지할 경우 +50,000엔 제3자 송출(1개월): 200,000엔 + 세금 ＜그 외 카테고리＞ 릴스 게시물: 750,000엔 + 세금 ※ 피드에 유지할 경우 +50,000엔 제3자 송출(1개월): 150,000엔 + 세금 피드 게시물: 250,000엔 + 세금', 'available', false, true),
-- 44. 이츠키
(gen_random_uuid(), '이츠키', 'itky75', 'itky75', 228000,
 NULL, NULL, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 250000, 350000, NULL, NULL,
 '한나', NULL, '[부가설명] [ 260219 라인회신 ] 릴스 35만엔 피드 25만엔', 'available', false, true),
-- 45. 블루베짱
(gen_random_uuid(), '블루베짱', 'bluebe_chan', 'bluebe_chan', 99000,
 'bluebe_chan_', 35, NULL, NULL,
 'bluebe_chan', 80, 'color', 'beauty', 'middle',
 NULL, 10000, NULL, NULL, NULL,
 '한나', NULL, '[부가설명] [25년07월04일/아리얼] ·피드 포스팅 : @ 1.2엔~ / ·스토리(1세트(6장)):@0.8엔~ / ·릴 포스팅 : @ 1.2엔~ / ·라이브 방송 : 실시 없음 ·2차 이용(1개월) : 30,000엔~ / ◎TIKTOK◎···실시 없음 ---- 7/9 라인 회신 내용 -- ◎AriuL PR ■릴 PR 비용 ■ 스토리 6연 (1세트) PR 비용 ■아이콘 권리사용료 ➡ 【합계 150,000엔 (부가세 별도)】 ◎라운드 랩 PR ■릴 PR 비용 ■ 스토리 6연 (1세트) PR 비용 ■아이콘 권리사용료 ➡ 【합계 150,000엔 (부가세 별도)】 피드 1 건 추가 시 [합계 213,000엔 (세금 별도)] [기타 코멘트] [순희 : 효과는 높지 않은 인플루언서]', 'available', false, true),
-- 46. 모에카
(gen_random_uuid(), '모에카', 'moe.thxx', 'moe.thxx', 93000,
 'mm.thx', 789400, NULL, NULL,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, 50000, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 47. 논체르
(gen_random_uuid(), '논체르', 'noa_u._.u', 'noa_u._.u', 103000,
 'cherry_noa', 230600, 'cherry_noa', 4750,
 NULL, NULL, 'fashion', 'fashion', 'middle',
 NULL, 300000, 400000, 100000, NULL,
 '한나', NULL, '[부가설명] •Instagram 피드 게시물: 150,000엔 / •Instagram 릴스 게시물: 200,000엔 - 릴+ 스토리 2회 = 200만 원 •TikTok 게시물: 300,000엔 / •Instagram + TikTok 동시 게시: 400,000엔 [순희/251014/라인방] •TikTok: 60만엔~ •인스타그램 릴 : 40만엔~ •인스타그램피드:30만엔~ •스토리(4장) : 10만엔~ [11월 체이싱래빗] 릴스 1 + 스토리4 + 2차사용까지 35만엔', 'available', false, true),
-- 48. 유리
(gen_random_uuid(), '유리', 'biyoushin_413', 'biyoushin_413', 64000,
 NULL, NULL, NULL, 5330,
 NULL, NULL, 'base', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나, 아유네', NULL, '[부가설명] Kr.contact@ssint.jp 7/18 한나님, 신지상, jfun도 연락이 불가 [소속별 시딩 비용] -한나: - -아유네: 115200', 'available', false, true),
-- 49. 리이나
(gen_random_uuid(), '리이나', 'riina_lam', 'riina_lam', 14000,
 'riina_lam', 93300, NULL, 99400,
 'riina_lam', 42800, 'color', 'beauty', 'micro',
 NULL, NULL, NULL, NULL, NULL,
 '한나', NULL, NULL, 'available', false, true),
-- 50. 미레
(gen_random_uuid(), '미레', 'mire_k_23', 'mire_k_23', 60000,
 'mire_k_23', 82800, 'mire_k_23', 60600,
 NULL, NULL, 'color', 'beauty', 'middle',
 NULL, NULL, NULL, NULL, NULL,
 '한나, 아유네', NULL, '[부가설명] 한나님 연락불가, 신지상 요청중 [소속별 시딩 비용] -한나: ¥340,000 -아유네: ¥117,000', 'available', false, true);

-- ============================================================
-- 적용 후 검증 SQL (개발 DB SQL Editor에서 1단계씩 실행 — 결과 확인 후 다음 단계로)
-- ============================================================
/*

-- [V0] 총 건수 (50 기대)
SELECT count(*) AS total FROM public.outbound_influencers;

-- [V1] 카테고리 분포 (color 25 / base 8 / fashion 6 / vlog 5 / kidsmom 3 / food 2 / other 1)
SELECT category_code, count(*) AS n
FROM public.outbound_influencers
GROUP BY category_code
ORDER BY n DESC;

-- [V1-b] 계열 분포 (beauty 33 / life 8 / fashion 6 / food 2 / other 1)
SELECT series_code, count(*) AS n
FROM public.outbound_influencers
GROUP BY series_code
ORDER BY n DESC;

-- [V1-c] 등급 분포 (middle 36 / micro 12 / mega 2)
SELECT tier_code, count(*) AS n
FROM public.outbound_influencers
GROUP BY tier_code
ORDER BY n DESC;

-- [V2] 가격 5종 NULL(가격 미상) 비율
SELECT
  count(*)                                         AS total,
  count(price_tiktok)                              AS has_tiktok,
  count(price_feed)                                AS has_feed,
  count(price_reels)                               AS has_reels,
  count(price_story)                               AS has_story,
  count(price_secondary)                           AS has_secondary,
  round(100.0 * (count(*) - count(price_feed)) / count(*), 1) AS feed_null_pct
FROM public.outbound_influencers;

-- [V3] 코드 무결성 — lookup_values 에 없는 코드가 있으면 행 반환(0행 기대)
SELECT id, name_ko, category_code, series_code, tier_code
FROM public.outbound_influencers oi
WHERE NOT EXISTS (SELECT 1 FROM lookup_values lv WHERE lv.kind='ob_category' AND lv.code=oi.category_code)
   OR NOT EXISTS (SELECT 1 FROM lookup_values lv WHERE lv.kind='ob_series'   AND lv.code=oi.series_code)
   OR NOT EXISTS (SELECT 1 FROM lookup_values lv WHERE lv.kind='ob_tier'     AND lv.code=oi.tier_code);

*/
