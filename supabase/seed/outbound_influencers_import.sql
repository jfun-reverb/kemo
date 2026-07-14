-- ============================================================
-- outbound_influencers_import.sql
-- 인플루언서 추천 도구 — 영업팀 구글시트 → outbound_influencers 전량 이관
-- 사양서: docs/specs/2026-07-08-influencer-recommendation.md
--
-- 출처 시트: Google Drive fileId 1_60ClsHen1hE0WnXNsI_j567idEPOl0xtFn8f7aywhs
--   (영업팀 아웃바운드 인플루언서 명단 — **917명**, globalreverb 미가입)
-- 대상 테이블: public.outbound_influencers (마이그레이션 226)
-- 기준 데이터 코드: ob_category/ob_series/ob_tier (마이그레이션 227 + health·tech 추가 236)
--
-- ⚠️ 2026-07-14 정정: 최초 이관(1단계-c)이 시트를 "약 50명"으로 잘못 파악해
--   앞 50명만 넣었으나, 실제 시트는 917명. 전량 재이관으로 정정.
--
-- ⚠️ 통화: 가격 5종은 모두 **엔화(¥)**. 콤마·¥ 제거한 정수만 저장.
--
-- ⚠️ 적용 순서: ①마이그레이션 236(ob_category health·tech 추가) → ②이 seed.
--   236 미적용 상태로 실행하면 category_code='health'/'tech' 행의 라벨·필터가 깨진다.
--   개발 DB(qysmxtipobomefudyixw)에 먼저 적용·검증 → 운영(nrwtujmlbktxjgdwlpjj).
--
-- ⚠️ 멱등성: BEGIN/DELETE ALL/INSERT/COMMIT 로 감쌈 → **재실행해도 917행 유지**(중복 없음).
--   단 DELETE 는 outbound_influencers 전체를 지운다. 실행 전 반드시:
--     SELECT count(*) FROM public.outbound_influencers;   -- 현재 건수·수동 등록분 확인
--   운영은 현재 0행이라 DELETE no-op. 개발은 기존 50행을 지우고 917행으로 교체.
--
-- 정제 규칙(생성기 적용 완료):
--   1) 등급(시트 「분류」열) 없는 68명 → 대표 채널 팔로워로 자동 추정(micro<5만/middle 5~30만/mega 30만+)
--   2) 계정주제 → ob_category (헬스/다이어트=health·테크/기타=tech 신규, 나머지 기존 7종)
--      계열은 category→series 매핑(health→life, tech→other)
--   3) 수식 오류값 46,167 · 날짜형 값(26-05-24 등) 이 들어간 가격/팔로워 칸 → NULL
--   4) 빈 가격·빈 팔로워 = NULL (0 아님)
--   5) 핸들: 각 채널 URL 마지막 경로에서 추출(youtube channel/UC.. 대응), 인스타는 계정ID 폴백
--
-- 건수: 917행 (계정ID 없는 6명 포함 — name_ko 만 필수라 등록). 카테고리 9종·등급 3종.
-- ============================================================

BEGIN;

-- 기존 이관분(+재실행 대비) 전체 삭제 후 917행 재삽입
DELETE FROM public.outbound_influencers;

INSERT INTO public.outbound_influencers (
  id, name_ko, account_id, ig_handle, ig_followers,
  tiktok_handle, tiktok_followers, youtube_handle, youtube_followers,
  x_handle, x_followers, category_code, series_code, tier_code,
  price_tiktok, price_feed, price_reels, price_story, price_secondary,
  contact_channel, agency, nego_memo, availability, content_consent, is_active
) VALUES
(gen_random_uuid(), '코콘', 'cocon_makeup', 'cocon_makeup', 40000, NULL, NULL, NULL, NULL, 'cocon_makeup', 1586, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] 1. 피드 1건 50,000엔 / 피드2건 콘텐츠 제작 80,000엔  / 스토리 1개 10,000엔', 'available', false, true),
(gen_random_uuid(), '마슈', 'marsh_stagram', 'marsh_stagram', 49000, 'marsh_mako', 8432, 'marsh_mako', 4240, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 피드/릴스1회 + 스토리 +@', 'available', false, true),
(gen_random_uuid(), '사치카', 'schk_maru', 'schk_maru', 62000, NULL, NULL, 'sachikanchi', 1130, NULL, NULL, 'color', 'beauty', 'middle', NULL, 60000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 피드/릴스1회 + 스토리 +@  / 별도 문의했을 때 투고 10만엔, 릴에 12만엔

[250806/순희/라인]
릴스1회 + 스토리4회 : 130,000엔+세금으로 가능', 'available', false, true),
(gen_random_uuid(), '아야카', 'aya.v_v.ka', 'aya.v_v.ka', 150000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 50000, NULL, NULL, NULL, '한나', NULL, '[부가설명] [앞으로 진행안하는게 좋을듯] 3개월 고정 20만엔  한달 단위X 3개월 20
5만엔 해줄듯(05월18일/변경) / 10만엔 / 3개월 20만엔', 'available', false, true),
(gen_random_uuid(), '체스카', 'rinachesca', 'rinachesca', 90000, 'rinachesca', 27800, 'RinaFranchesca1', 3760, 'rinachesca', 1906, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
(gen_random_uuid(), '아스카', 'asuka_skincare', 'asuka_skincare', 52000, 'asuka_skincare', 12000, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 75000, 75000, 5000, NULL, '한나', NULL, '[부가설명] 1. 1 팔로워 1.5엔 세금별도(3주 이상 확보 스케쥴)
2. 1팔로워 2엔 세금별도(2주 이내 경우)
- 2차 이용 : 1개월 50,000엔 세금 별도 / 파트너쉽 광고
3. 스토리 : 

-----7/8 한나님 회신 ---
①도착부터 초안까지 2주이내의경우 🛬📦
1 팔로어×2엔 세금 별도
·3주 이상 확보할 수 있는 경우
1 팔로어×1.5엔 세금 별도

이차 이용 --> 광고 전달 1개월 50,000엔 세금 별도

기타 -->  🇯🇵에서 이체하는 경우 세금이 듭니다.

🇰🇷에서 이체하는 경우
세금대상에서 제외되지만, 폐사 입금시에
외화송금수령수수료가 반드시 차감되므로  +3000엔 받았습니다. 

②콜라보
1회분의 투고 비용(최저 보증액으로서)   / 1 팔로워 × 1.5엔~ / 매상 비율 → 평균 12-15%', 'available', false, true),
(gen_random_uuid(), '린', 'happy_cosme3150', 'happy_cosme3150', 48000, 'happy_cosme', NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 77000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 7.7만엔', 'available', false, true),
(gen_random_uuid(), '카나코', 'knk_csmpink', 'knk_csmpink', 54000, 'knk_csmpink', 3470, 'knk_csmpink', 49, NULL, NULL, 'color', 'beauty', 'middle', NULL, 50000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 5만엔', 'available', false, true),
(gen_random_uuid(), '하루', 'fleurir_personalcolor', 'fleurir_personalcolor', 32000, NULL, NULL, 'UCXg7OAShX25ghJbS038wB9w', 212, 'fleurir_pc', 20900, 'color', 'beauty', 'micro', NULL, 30000, NULL, NULL, 10000, '한나', NULL, '[부가설명] 05월18일 3만엔으로 변경 됨 / 기 작성 : 단순 시딩 : 5만엔/ 2차사용 : 1만엔~', 'available', false, true),
(gen_random_uuid(), '피이', 'piii_xx_01', 'piii_xx_01', 51000, 'piii_xx_01', 1517, NULL, NULL, 'piii_xx_01', 0, 'color', 'beauty', 'middle', NULL, 85000, 96000, NULL, NULL, '한나, JFUN', NULL, '[부가설명] 신규 : 인스타그램+틱톡+립스 : 150,000엔
과거 : 콜라보X 단순투고 7만엔

------jfun -----[250703/DM회신]
릴 96,000엔  /   피드 85,000엔', 'available', false, true),
(gen_random_uuid(), '카린', 'karin__life', 'karin__life', 146000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 180000, 250000, 30000, NULL, '한나', NULL, '[부가설명] (05월18일/변경) 10만엔으로/ 5만엔

[251105/신지상답변/순희]
인스타그램 피드 1회 : 18만엔
인스타그램릴 1회 : 25만엔
인스타그램 스토리 1회 : 3.0만엔 / 장
※모두 세금 별도', 'available', false, true),
(gen_random_uuid(), '아카네', 'cosmesalan', 'cosmesalan', 43000, 'cosmesalan', 2206, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '낫짱', 'natsu._.beauty', 'natsu._.beauty', 79000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 100000, 100000, NULL, NULL, '한나', NULL, '[부가설명] 1투고+스토리2회 : 70,000엔에서 100,000엔으로 변경 요청
최종적으로는 1릴에 7만엔으로 진행함', 'available', false, true),
(gen_random_uuid(), '유이', 'msyui313', 'msyui313', 100000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모미', 'momomi_makino', 'momomi_makino', 51000, 'momomi_makino', NULL, 'momomi_makino', 2130, 'Momomi_arrest', 3446, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '토모리', 'tomilly101', 'tomilly101', 181000, 'tomilly101', 45200, 'UC5is64EAMZKYq7smI1ffSnw', 19700, 'tomilly101', 5925, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미코', 'mwnail.kt', 'mwnail.kt', 45000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 45000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성
1투고 1스토리 5만엔 수익쉐어 15%', 'available', false, true),
(gen_random_uuid(), '케코', 'keko_blog', 'keko_blog', 37000, 'kekoyakedo', 77100, NULL, NULL, 'keko_blog', 1204, 'base', 'beauty', 'micro', NULL, 30000, NULL, NULL, NULL, '한나, 아유네', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
(gen_random_uuid(), '히마', 'hima323232', 'hima323232', 23000, '_hima323232', 14300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 30000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나라', 'keana_nara', 'keana_nara', 124000, 'keana_nara', 64500, 'keana_nara', 49500, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, 아유네', NULL, '[부가설명] 한나님 소통가능', 'available', false, true),
(gen_random_uuid(), '한나', 'honey0627_', 'honey0627_', 65000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유이카', 'yuika00802', 'yuika00802', 75000, NULL, NULL, NULL, NULL, 'yuika_0802', 2063, 'fashion', 'fashion', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
(gen_random_uuid(), '미미탄', 'mimitan090909', 'mimitan090909', 116000, NULL, NULL, 'UCkUaAS-UNgPvTvZOeHHURkg', 73900, 'mimitan090909', 75500, 'base', 'beauty', 'middle', NULL, 510000, 600000, NULL, 120000, '한나, JFUN', NULL, '[부가설명] [250724/ 신지상 회신]  아리얼 제안시 가격 
릴스 게시 + 스토리 게시: 600,000엔
피드 게시 + 스토리 게시: 510,000엔
2차 활용 1개월: 120,000엔', 'available', false, true),
(gen_random_uuid(), '나오미', 'naomi_majima', 'naomi_majima', 1009000, 'naomi_majima', 245900, NULL, NULL, 'naomi_majima', 695800, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '안짱', 'annpeach__', 'annpeach__', 76000, 'annpeach__', 152100, 'UCKYfNY255PzJTGUtLSRzfNw', 98100, 'annpeach__', 4655, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아유네', 'ayune____', 'ayune____', 107000, NULL, NULL, 'UC4X3Lv1Dtu4WgLrQljvPOXA', 14200, 'ayumi_1022_', 20100, 'kidsmom', 'life', 'middle', NULL, 100000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 시딩 금액 : 05월18일/작성', 'available', false, true),
(gen_random_uuid(), '아리사', 'arisa_deguchi', 'arisa_deguchi', 89000, NULL, NULL, NULL, NULL, 'deguchiarisa', 29200, 'fashion', 'fashion', 'middle', NULL, 90000, NULL, 50000, NULL, '한나, JFUN', NULL, '[부가설명] 251127 라인방 회신 
◾️ 릴 투고 (1 개) 해본 적이 없어요.
◾️ 피드 게시물 (1 개) 9만~
◾️ 스토리 투고 (1개 ~ 복수) 5만~
◾️콜라보 진행 경험 없음', 'available', false, true),
(gen_random_uuid(), '카나코', '11kanaco14', '11kanaco14', 94000, '11kanaco14', 17500, '11kanaco14', 5100, 'kanaco1114', 120400, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모코', 'momosan0627', 'momosan0627', 200000, 'momosan0627', 69900, NULL, NULL, 'momosan0627', 84900, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '개인', NULL, 'available', false, true),
(gen_random_uuid(), '나코', 'nako_iimonohakken', 'nako_iimonohakken', 86000, 'nako_iimonohakken', 1657, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 85000, 100000, 10000, NULL, '한나, JFUN', NULL, '[부가설명] [250702/DM회신]
릴스 1회  100,000엔 /  피드 1회 85,000엔  /  스토리 1회10,000엔

[250905/순희/카라코리스트]
피드 투고: ¥180,000
릴스 투고: ¥225,000
2차 활용(2개월): ¥30,000', 'available', false, true),
(gen_random_uuid(), '키키마루', 'kikigram_97', 'kikigram_97', 436000, 'kikidayo', 433900, NULL, NULL, 'kikidayo_97', 83900, 'vlog', 'life', 'mega', NULL, NULL, 400000, NULL, NULL, '한나, JFUN', NULL, '[부가설명] [251209 라인회신]
타이업 비용 ·릴스 : 40만엔 ( TikTok/X/Threads에도 전재 예정 )', 'available', false, true),
(gen_random_uuid(), '은아', 'xtrina2', 'xtrina2', 195000, NULL, NULL, 'UNA_TV', 99500, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 1350000, 250000, 380000, '한나, JFUN', NULL, '[부가설명] 인스타 40만엔 틱톡 40만엔 둘다면 할인해서 60만엔

[250617/DM회신] 
첫 진행비용 틱톡 125만엔 / 릴스 125만엔 / 스토리 22만엔
메가와리기간 비용 틱톡 135만엔 / 릴스 135만엔 / 스토리 25만엔 등 
2025년 은아님 자세한 가격 표 
https://docs.google.com/spreadsheets/d/100w07CtVwzSdPy4mzTyFJUC7Z-Fc-vUzP-SNLxGn8zo/edit?gid=0#gid=0', 'available', false, true),
(gen_random_uuid(), '우사미미', 'usamimi080', 'usamimi080', 52000, 'usamimi080', 59000, NULL, NULL, NULL, NULL, 'other', 'other', 'middle', 80000, 50000, NULL, NULL, NULL, '한나, 기타, JFUN', 'tag', '[부가설명] 250818 tag 소속사 리스트에서 추가', 'available', false, true),
(gen_random_uuid(), '니타마고', '__nitamago__', '__nitamago__', 154000, '_nitamago', 362300, '__nitamago__', 473000, '__nitamago__', 45400, 'color', 'beauty', 'middle', NULL, 250000, 450000, 80000, NULL, '한나, 아유네, JFUN', NULL, '[부가설명] info@nitamagoch.com  
[2507/22/라인회신] 
▼타이업 비용 (세금 제외)  조율가능 
・릴스 게시물 (1건): 450,000엔~
・피드 게시물 (1건): 200,000~~250,000엔
・스토리 게시물 (1장~~): 80,000엔~ (\*하이라이트 설정은 별도)
※ 모든 금액은 세금 별도 기준입니다. 해외에서 송금 시 비과세로 처리되는 경우, 소비세 10%를 추가한 금액으로 제안해 주시면 감사하겠습니다.
※ 2차 활용 비용은 별도로 발생하오니 미리 양해 부탁드립니다.', 'available', false, true),
(gen_random_uuid(), '카렌', 'berobero_baaa', 'berobero_baaa', 123000, 'berobero__baaa', 260000, 'berobero_baaa', 928, 'satoukaren_desu', 40400, 'vlog', 'life', 'middle', NULL, 70000, 70000, NULL, NULL, '한나', NULL, '[부가설명] 앞으로 진행할 때는 릴 1건 + 스토리 5건으로해서 15만엔으로 협의하는게 좋을 듯 
처음에는 4만엔 / 5만엔 제안함
릴스 1 스토리 4개 10만엔 
콜라보 20만엔 (릴스1+스토리4+틱톡1/수익쉐어X)
- -6월09일 : 릴은 7만~ / 스토리는 2만엔 정도', 'available', false, true),
(gen_random_uuid(), '미요코', 'miyoko.myondon', 'miyoko.myondon', 19000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '세토', 'mi10mi18', 'mi10mi18', 130000, NULL, NULL, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '메구', 'megukiss0517', 'megukiss0517', 169000, 'megukiss0517', 1345, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마이', 'environs31', 'environs31', 98000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '시바 코노나', 'konona.official', 'konona.official', 84000, NULL, NULL, NULL, NULL, 'konona0214shiba', 5805, 'kidsmom', 'life', 'middle', NULL, 200000, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] 1. 조건  - 월 4회 =80만엔 /  월 5회 = 90만엔 / 월 6회 = 100만엔
2. 포스팅 진행 방식 /  스토리 4~5회/피드or릴스1번+2차 활용', 'available', false, true),
(gen_random_uuid(), '미키치', 'mikichi0726', 'mikichi0726', 27000, 'mikichi119', 2696, NULL, NULL, 'mikichi1979', 19600, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '안나', 'annatsumura_', 'annatsumura_', 28000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, 20000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '호노피스', 'noponopisu2', 'noponopisu2', 168000, 'noponopisu2', 830000, 'noponopisu2', 59800, 'noponopisu2', 5565, 'color', 'beauty', 'middle', 1450000, 250000, 800000, NULL, NULL, '호노피스', NULL, '[부가설명] 【TikTok】

＜스킨케어·샴푸＞

TikTok 게시물: 1,250,000엔 + 세금
※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 합니다.
Spark Ads를 이용하지 않을 경우 1,450,000엔에 진행됩니다.
Spark Ads(1개월): 200,000엔 + 세금

＜그 외 카테고리＞

TikTok 게시물: 1,150,000엔 + 세금
※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 하며,
Spark Ads를 이용하지 않을 경우 1,350,000엔에 진행됩니다.
Spark Ads(1개월): 150,000엔 + 세금
릴스 영상을 TikTok에 전재: 1,150,000엔 + 세금
※ 게시 후 2일 이내에 Spark Ads를 10만 엔 이상(운영 기간: 1주일) 집행하는 것을 조건으로 하며,
Spark Ads를 이용하지 않을 경우 1,350,000엔에 진행됩니다.

【Instagram】

＜스킨케어·샴푸＞

릴스 게시물: 800,000엔 + 세금
※ 피드에 유지할 경우 +50,000엔
제3자 송출(1개월): 200,000엔 + 세금

＜그 외 카테고리＞

릴스 게시물: 750,000엔 + 세금
※ 피드에 유지할 경우 +50,000엔
제3자 송출(1개월): 150,000엔 + 세금

피드 게시물: 250,000엔 + 세금', 'available', false, true),
(gen_random_uuid(), '이츠키', 'itky75', 'itky75', 228000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 250000, 350000, NULL, NULL, '한나', NULL, '[부가설명] [ 260219 라인회신 ] 
릴스 35만엔
피드 25만엔', 'available', false, true),
(gen_random_uuid(), '블루베짱', 'bluebe_chan', 'bluebe_chan', 99000, 'bluebe_chan_', 35, NULL, NULL, 'bluebe_chan', 80, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] [25년07월04일/아리얼]
·피드 포스팅 : @ 1.2엔~ / ·스토리(1세트(6장)):@0.8엔~ / ·릴 포스팅 : @ 1.2엔~ / ·라이브 방송 : 실시 없음
·2차 이용(1개월) : 30,000엔~   / ◎TIKTOK◎···실시 없음

---- 7/9 라인 회신 내용 -- 
◎AriuL PR
■릴 PR 비용 ■ 스토리 6연 (1세트) PR 비용  ■아이콘 권리사용료  ➡ 【합계 150,000엔 (부가세 별도)】

◎라운드 랩 PR
■릴 PR 비용 ■ 스토리 6연 (1세트) PR 비용 ■아이콘 권리사용료 ➡ 【합계 150,000엔 (부가세 별도)】
🔴 피드 1 건 추가 시 [합계 213,000엔 (세금 별도)]', 'available', false, true),
(gen_random_uuid(), '모에카', 'moe.thxx', 'moe.thxx', 93000, 'mm.thx', 789400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 50000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '논체르', 'noa_u._.u', 'noa_u._.u', 103000, 'cherry_noa', 230600, 'cherry_noa', 4750, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 300000, 400000, 100000, NULL, '한나', NULL, '[부가설명] •Instagram 피드 게시물: 150,000엔 / •Instagram 릴스 게시물: 200,000엔
- 릴+ 스토리 2회 = 200만 원
•TikTok 게시물: 300,000엔 / •Instagram + TikTok 동시 게시: 400,000엔

[순희/251014/라인방]
•TikTok: 60만엔~
•인스타그램 릴 : 40만엔~
•인스타그램피드:30만엔~
•스토리(4장) : 10만엔~

[11월 체이싱래빗]
릴스 1 + 스토리4 + 2차사용까지 35만엔', 'available', false, true),
(gen_random_uuid(), '유리', 'biyoushin_413', 'biyoushin_413', 64000, NULL, NULL, 'UCcVvlbqoojZBBOUZsUZNo0w', 5330, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, 아유네', NULL, '[부가설명] Kr.contact@ssint.jp   7/18 한나님, 신지상, jfun도 연락이 불가', 'available', false, true),
(gen_random_uuid(), '리이나', 'riina_lam', 'riina_lam', 14000, 'riina_lam', 93300, 'UC5DYqwDgxx0e3iIV2gvksCQ', 99400, 'riina_lam', 42800, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미레', 'mire_k_23', 'mire_k_23', 60000, 'mire_k_23', 82800, 'mire_k_23', 60600, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, 아유네', NULL, '[부가설명] 한나님 연락불가, 신지상 요청중', 'available', false, true),
(gen_random_uuid(), '줄리아', 'vdyli', 'vdyli', 7065, 'vdyli', 128000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, PPP스튜디오', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카오리', 'ka0ri10', 'ka0ri10', 34000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오리', 'ori0515', 'ori0515', 26000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '호시노코', 'hoshinoko728', 'hoshinoko728', 148000, 'hoshinoko728.28', 29100, 'hoshinoko728', 426000, 'hoshinoko_728', 30200, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] hoshinoko00@gmail.com', 'available', false, true),
(gen_random_uuid(), '아스카', 'aspoo02', 'aspoo02', 710000, NULL, NULL, NULL, NULL, 'asupons02', 324000, 'tech', 'other', 'mega', NULL, 100000, NULL, NULL, NULL, '한나, 아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오키타 아이카', 'okita_aika', 'okita_aika', 307000, NULL, NULL, 'UChhIeOmQx0_V7NxY_IUsOWw', 26000, 'okita_aika_0214', 916, 'color', 'beauty', 'mega', NULL, 184200, 300000, 20000, NULL, '한나', NULL, '[부가설명] [251030/순희/라인방]
릴스1 + 스토리4 + 2차 이용(1개월 기준) = 60만부터

[251105/순희/개인라인방]
피드 비용감: 팔로워✖️0.5에서 1엔

2차이용 없이 릴1+스1 30만엔', 'available', false, true),
(gen_random_uuid(), '나코', 'naco_story', 'naco_story', 77000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아얀누', 'ayannu61', 'ayannu61', 47000, 'ayannu61', 664, 'ayannu61', 11400, 'yannu61', 19700, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] ayannu@buggy.tokyo', 'available', false, true),
(gen_random_uuid(), '나츠', 'natu__mtk', 'natu__mtk', 72000, 'natu__mtk', 39300, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아이스', 'o_bury_', 'o_bury_', 26000, 'o_bury_', 24200, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 60000, 97500, NULL, 30000, '한나', NULL, '[부가설명] [250910/순희/카라코상 리스트]
피드 투고: ¥60,000
릴스 투고: ¥97,500
2차 사용 : ¥30,000', 'available', false, true),
(gen_random_uuid(), '츠키코', 'tsukiko_kotsuki', 'tsukiko_kotsuki', 12000, NULL, NULL, NULL, NULL, 'tsukiko_kotsuki', 3077, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카오리', 'kaoriii_s', 'kaoriii_s', 60000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오츠쿠', 'otgram97', 'otgram97', 94000, 'otgram', 85900, 'otgram97', 2550, NULL, NULL, 'vlog', 'life', 'middle', NULL, 280000, 300000, 50000, NULL, 'JFUN', NULL, '[부가설명] 28만엔+10% 수수료 / 시딩만 : 30만엔  
스토리 5만엔
·2차 이용 1개월(사진사용, 오츠구pick 이라는 명기, meta나 Spark Ads 광고사용) + 30,000엔
11월 티블레스 -> 릴1+스1+2차pick+meta광고13일 -> 38만엔', 'available', false, true),
(gen_random_uuid(), '코토네', 'kokkofk', 'kokkofk', 33000, NULL, NULL, NULL, NULL, 'kokkofk', 13700, 'color', 'beauty', 'micro', NULL, 30000, NULL, NULL, NULL, '한나', NULL, '[부가설명] (05월18일/작성)', 'available', false, true),
(gen_random_uuid(), '카호', 'momota_kaho', 'momota_kaho', 93000, 'momota_kaho', 400000, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 180000, 270000, 25000, 100000, 'JFUN', NULL, '[부가설명] - 릴스1+틱톡1(+ 스토리 2회 2만엔)/메가포,메가와리 총 2건 = 45만엔
- 릴스1+틱톡1+2차 사용포함 = 25만 엔 (인스타DM 내용)
- 입금 : 23만5천엔 
-------------------------------------------------------
[카호님 제안 비용감]
·전달면별 단가(부가세 별도)
Instagram 릴 포스팅 : 27만엔　
 스토리 1 투고 : 2.5만엔
 Instagram 피드 포스팅 : 18만엔
• TikTok 투고 : 20만엔
 • 세트 플랜 (릴+TikTok) : 38만엔 (같은 상품 게재)
 • 타이업 투고 (Instagram 또는 TikTok) : +5만엔
 • 콘텐츠 이차이용(3개월간) : +12만엔
  • 아이콘 이차 이용(7~12일간, 판매 기간과 동일): 10만엔
-------------------------------------------------------
[250721/라인방/순희]
- 릴스 1회 + 스토리 10회 = 43만엔
- 릴스 1회 + 스토리 15건 = 53만엔

[250725/라인방/순희]
스토리만 8개 = 20만엔
스토리만 10개 = 25만엔', 'available', false, true),
(gen_random_uuid(), '유리카', 'yurika.syj', 'yurika.syj', 14000, 'its.yurika', 8210, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '노라', 'noranoranora1988', 'noranoranora1988', 686000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키누', '2_5_2555', '2_5_2555', 258000, NULL, NULL, 'kinuchannell', 665000, '2_5_2555', 165800, 'color', 'beauty', 'middle', NULL, 500000, 550000, NULL, NULL, '한나, OOO엔터', NULL, '[부가설명] [250915/순희/라인]
Feed
¥500,000（税別）
Reel
¥550,000（税別）
Stories
¥250,000（税別）', 'available', false, true),
(gen_random_uuid(), '모치이', 'mochi_mochi_kr', 'mochi_mochi_kr', 31000, 'mochi_mochi_kr', 3955, 'mochi_mochi_kr', 279, 'mochi_mochi_kr', 21600, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유키리누', 'yukirin_u', 'yukirin_u', 192000, 'yukirinu', 318000, 'yukirin_u', 983000, 'yukirin_u', 259399, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] 소속사 홈페이지에서 신청필수 https://www.uuum.co.jp/inquiry-promotion', 'available', false, true),
(gen_random_uuid(), '미쿠', 'miku812miku', 'miku812miku', 50000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '루이', 'rui_1oo8', 'rui_1oo8', 45000, 'rui_1oo8', 11100, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미쿠', 'smiku0524', 'smiku0524', 179000, '3939miku2', 271100, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 260000, 330000, 20000, NULL, '한나, JFUN', NULL, '[부가설명] [251218 라인회신]
◾️ 릴 투고 (1 개) 33만엔 (세금 별도)
◾️ 피드 게시물 (1개) 26만엔 (세금 별도)
◾️ 스토리 투고 (1개 ~ 복수) 2만엔 (세금 별도)
◾️ 콜라보 비용 (릴 1개 + 스토리 4개 + QOO10 상품 페이지에 프로필 이미지 사용) 45만엔 (부가세 별도)', 'available', false, true),
(gen_random_uuid(), '마타라이 아야', 'matarai_aya', 'matarai_aya', 141000, '_matarai_aya_', 19100, 'mataraiaya9', 2020, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, 기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아이', 'ai_tinker_b', 'ai_tinker_b', 97000, 'aitinkerb', 461200, 'aitinkerb', 59200, 'ai_tinker_b', NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카즈미', 'donfan.love2', 'donfan.love2', 59000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 5000, NULL, NULL, NULL, '한나', NULL, '[부가설명] (05월18일/작성)', 'available', false, true),
(gen_random_uuid(), '아야카', 'ayakaxxk', 'ayakaxxk', 14000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 5000, NULL, NULL, NULL, '한나', NULL, '[부가설명] (05월18일/작성)', 'available', false, true),
(gen_random_uuid(), '유리코', 'yuriko5k', 'yuriko5k', 43000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] (05월18일/변경) 기존 만엔/ 
콜라보 1만엔 피드1 + 스토리1
1피드 1스토리 총 1만엔  / 콜라보 형태로 매출액 10%로 조건으롱 / 릴스 1회 + 피드 1회+스토리 4회~', 'available', false, true),
(gen_random_uuid(), '이사코', 'ichaaako', 'ichaaako', 136000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, 187000, NULL, NULL, 'JFUN', NULL, '[부가설명] [260107 라인회신]', 'available', false, true),
(gen_random_uuid(), '히나코', 'kerahinako1105', 'kerahinako1105', 95000, 'kerahinako1105', 8668, NULL, NULL, 'aksb_kera', 15800, 'fashion', 'fashion', 'middle', NULL, 30000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미치', 'suzumichi605', 'suzumichi605', 80000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 5000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에린코', 'erinko0315', 'erinko0315', 56000, 'erinko0315', 16300, 'UCGoG5fpKLtn8bOcXbeXOXpg', 1670, 'erinko0315', 4121, 'fashion', 'fashion', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야', 'ayaokutsu', 'ayaokutsu', 83000, 'ayaoku222', 153700, 'ayaokutsu', 20700, 'ayaoku222', 274, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] cues@ultrasocial.jp', 'available', false, true),
(gen_random_uuid(), '츠카사', 'brave97s', 'brave97s', 29000, 'brave97ss', 39000, 'UCpelEMV1LTSPVGS6v91kSMA', 58300, 'Brave97s', 449, 'vlog', 'life', 'micro', NULL, 30000, 80000, NULL, NULL, '한나', NULL, '[부가설명] 인스타그램 이미지 게시물: 3만 엔
인스타그램 릴 + 스토리: 8만 엔(세전)
TikTok: 5만 엔(세전)
YouTube 쇼츠: 5만 엔(세전)

A. 릴 + 스토리 + TikTok: 10만 엔(세전)
B. 릴 + 스토리 + TikTok + YouTube 쇼츠: 12만 엔(세전)

2차 이용(A&B만, 3개월 포함)
※ 이후 이용은 별도 상담 부탁드립니다.', 'available', false, true),
(gen_random_uuid(), '아마모모', '1momorooon', '1momorooon', 46000, '1momorooon', 5067, '1momorooon', 3310, NULL, NULL, 'vlog', 'life', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야카', 'ayaka0611_official', 'ayaka0611_official', 40000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아리사', 'arisa_74no', 'arisa_74no', 39000, 'arisa_74no', 1611, 'arisa_74no.makeup', NULL, 'arisa_74no', 3894, 'color', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리아', 'riatan0208', 'riatan0208', 83000, 'rears', 8591, 'officialchannel601', 477, 'ria_shiraishi', 2226, 'fashion', 'fashion', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마이타무', 'xx.mai.xx39', 'xx.mai.xx39', 15000, 'xx.mai.xx39', 1773, 'UC0rCyAYpIIMTitGIwmBZoVA', 36, NULL, NULL, 'color', 'beauty', 'micro', NULL, 5000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '히나타', 'saharahinata', 'saharahinata', 82000, 'saharahinata', 14200, 'saharahinata', 15500, 'hinatarosu', 50800, 'color', 'beauty', 'middle', NULL, NULL, 100000, NULL, NULL, 'JFUN', NULL, '[부가설명] [250612/라인회신]
릴스  10만엔 
피드, 스토리는 상담 가능', 'available', false, true),
(gen_random_uuid(), '마요', '__mayotan__', '__mayotan__', 22000, '__mayotan__', 17100, '__mayotan__', 924, '__mayotan__', 24100, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야치', 'o.aya_0613', 'o.aya_0613', 208000, 'o.aya_0613', 234000, NULL, NULL, 'o_aya_0613', 13000, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아이', 'tougarashi_suki', 'tougarashi_suki', 84000, NULL, NULL, 'UChTTicc7PtaNNzuEUBGa_NQ', 5680, 'tougarashi_suki', 30000, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마유윤', 'mayu__yunyun', 'mayu__yunyun', 74000, 'mayu__yunyun', 1753, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마리', 'm__mcandy30', 'm__mcandy30', 134000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '세리나', 'serina.beauty_', 'serina.beauty_', 78000, 'serina.beauty_', 11000, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나, 아유네', NULL, '[부가설명] kr.biz@ssint.jp', 'available', false, true),
(gen_random_uuid(), '아카리', 'akari030201', 'akari030201', 56000, 'akari030201', 3728, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나츠키', 'natsuki.okada0601', 'natsuki.okada0601', 36000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하루카', 'haruka_takahashi0127', 'haruka_takahashi0127', 140000, NULL, NULL, NULL, NULL, 'takaharu_0127', 3894, 'base', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 1만엔 진행', 'available', false, true),
(gen_random_uuid(), '아사코', 'asaren77', 'asaren77', 47000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 80000, 90000, 10000, 20000, '한나, JFUN', NULL, '[부가설명] [250722/DM회신]
■ 피드 게시: 80,000엔
■ 릴스 게시: 90,000엔
■ 스토리 게시 (별도로 제작하는 경우): 10,000엔
■ 2차 사용 (1개월): 20,000엔
※ 모두 세금 별도 금액입니다.', 'available', false, true),
(gen_random_uuid(), '카토 미나미', 'minamikato_0115', 'minamikato_0115', 188000, 'minamikato_0115', NULL, 'UCIwTysqXPw3k7Ge5olI4_lQ', 17000, 'minamikato0115', 58500, 'base', 'beauty', 'middle', NULL, 300000, 350000, 150000, NULL, '한나, JFUN', NULL, '[부가설명] three-o@bitstar.tokyo
[2507/21/DM 이메일 회신] 가격 조절 가능 
릴 35만
피드 30만
스토리 15만', 'available', false, true),
(gen_random_uuid(), '아스미', 'asumi_naa', 'asumi_naa', 104000, NULL, NULL, NULL, NULL, 'asumi_nnn', 1550, 'base', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아아사', 'aasa104', 'aasa104', 71000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유우', 'yuu_5240', 'yuu_5240', 27000, NULL, NULL, NULL, NULL, 'yuu_miyoshineko', 8507, 'color', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '이손', 'eson____', 'eson____', 224000, 'soniieson', NULL, '이손eson', 165000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마리이', 'marii_u_', 'marii_u_', 53000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하루카', 'haruka_yamazaki', 'haruka_yamazaki', 55000, 'haruka_yamazaki', 1039, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나노카', 'nanoka_0711', 'nanoka_0711', 155000, '0711nanoka', 126700, 'UCOvBs3Hv7m5MHewCW221f0A', 108000, '0711Nanoka', 71200, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] aoki.nanoka@gmail.com', 'available', false, true),
(gen_random_uuid(), '아이리', 'arimuraairi', 'arimuraairi', 163000, 'arimuraairi', 81200, 'UCNCvy3jyDhhndW-VKKuJEZg', 9940, 'arimuraairi', 196000, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, '[부가설명] info@arimura-airi.com', 'available', false, true),
(gen_random_uuid(), '나쵸스', 'nachos_kimono', 'nachos_kimono', 213000, 'nachos_kimono', 169900, 'UCfqOzJWK03DqjtcFkwE0o3g', 148000, 'nachos_tokumoto', 188100, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유이코', 'yuiko__h', 'yuiko__h', 78000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사아야', 'saaya.xoxo', 'saaya.xoxo', 48000, 'saaya.xxx', 2256, NULL, NULL, 'xoxo0614', 18800, 'fashion', 'fashion', 'micro', NULL, 50000, 80000, 55000, NULL, '한나', NULL, '[부가설명] [241030/순희/신지상답변]
피드¥50,000
릴 ¥80,000
스토리 55,000엔', 'available', false, true),
(gen_random_uuid(), '나호', 'inouenaho1207', 'inouenaho1207', 14000, 'inouenaho1207', 384, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카호', 'kaho.skincare', 'kaho.skincare', 99000, 'kaho.skincare', 7845, 'kaho.skincare', 3500, 'kaho_skincare', 902, 'base', 'beauty', 'middle', NULL, 220000, 360000, NULL, 120000, '한나, JFUN', NULL, '[부가설명] kaho.skincare@gmail.com   리쥬란 선호하십니다. 
[250722/메일회신]
◾️스토리 단독 진행은 별도 협의.
■ 피드 1건 게시   ￥220,000 (세금 별도) ／ ￥242,000 (세금 포함) ※ 자막 삽입, 영상 포함, 얼굴 노출 있음, 5장 이상 보장
◾️ 릴스 1건 게시  ¥360,000 (세금 별도) ／ ¥396,000 (세금 포함) ※ 얼굴 노출 있음, 본인 나레이션 있음, 자막 삽입 있음
■ 2차 사용권 (Instagram 내 광고 송출에 한함)
1개월 ¥120,000 (세금 별도) ／ ¥132,000 (세금 포함)
2개월 ¥240,000 (세금 별도) ／ ¥264,000 (세금 포함)
1쿼터 ¥360,000 (세금 별도) ／ ¥396,000 (세금 포함)

아래 참고 자료
https://docs.google.com/document/d/10vmfEixYU0dbSkwUM5CF5h0NrcQHARJe2WaCZBCMN_k/edit?usp=sharing', 'available', false, true),
(gen_random_uuid(), '사키노', 'niki_sakino', 'niki_sakino', 60000, 'niki_sakino', 524, 'UC7MyccaiE4MYa9ERzqZYY4Q', 220000, 'niki_sakino', 45800, 'color', 'beauty', 'middle', NULL, 60000, 100000, 30000, NULL, '한나, 코노나', NULL, '[부가설명] 5만엔

---- 251013 코노나 투어 진행 ___ 
평상시 금액  릴스는 10만 엔, 피드는 6만 엔, 스토리(URL 포함 PR 게시물)는 3만 엔', 'available', false, true),
(gen_random_uuid(), '리카코', 'rikako_0331', 'rikako_0331', 105000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 50000, 80000, 10000, NULL, '한나, JFUN', NULL, '[부가설명] [250612/라인회신]
릴: 8만 엔 이상
피드: 5만 엔 이상
스토리: 1만 엔 이상', 'available', false, true),
(gen_random_uuid(), '마나미', 'manami_s0902', 'manami_s0902', 111000, 'manami_s0902', 11000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오카리에', 'okarie1023', 'okarie1023', 112000, 'okarie1023', NULL, 'UCAn4ByU60Yw4HkkrdTN0G7w', 18500, 'okarie1023', 78700, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아스카', 'a.asuka.a', 'a.asuka.a', 81000, 'a.asuka.a', 284, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에린기', 'eringichannel0301', 'eringichannel0301', 71000, 'eringichannel0301', 1200000, 'UCssakkZ9FlJ7XInWVTKwF4g', 15300, 'eri_choco_0301', 6704, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미와', 'love.beautiful365', 'love.beautiful365', 39000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사아야', 'saaya_love', 'saaya_love', 53000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리노', 'rino.wauchi', 'rino.wauchi', 67000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '시호미', 'shihomi1129', 'shihomi1129', 156000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 1만엔 투고 1 + 스토리 1
5만엔(콜라보 진행/수익쉐어X)
[250714/순희/카톡방 내용]피드 + 스토리 1만엔씩이요🎀', 'available', false, true),
(gen_random_uuid(), '피짱', 'x.x.pixk.x.x', 'x.x.pixk.x.x', 32000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 150000, 150000, NULL, 100000, '한나', NULL, '[부가설명] ·릴1개 : 15만엔
·스토리 4 투고분 : 4만엔 (※ 1 투고는 무상 지원하며, 4 투고분만 청구)
·프로필 이미지 사용료 : 주당 1만엔

위에서 합계 20만엔(세금 별도)이지만, 조정도 가능하기 때문에 상담해 주십시오!

Instagram, TikTok, LIPS에 게시물로 150,000
2차 영상 가공 10만엔

・Instagram 릴스: 10만 엔~
・Instagram 피드: 9만 엔~
・TikTok: 7만 엔~
・Instagram + TikTok 세트: 15만 엔에 진행하고 있습니다.
※ 세금 별도
※ 송금 시 발생하는 수수료는 죄송하지만 부담 부탁드립니다.
- 연락주셔서 감사합니다 ✨️

①PR 투고가 있는 경우 스토리 1 투고 무상
　스토리만 있는 경우는 1만엔으로 부탁드리고 있습니다.

②프로필 이미지 사용은 +1만엔으로 상담 가능합니다.', 'available', false, true),
(gen_random_uuid(), '마리나', 'marinachan_0205', 'marinachan_0205', 310000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 300000, 650000, NULL, NULL, NULL, '한나, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥300,000  인스타 피드 ¥650,000', 'available', false, true),
(gen_random_uuid(), '카렌', 'karenokajima0318', 'karenokajima0318', 43000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, 10000, NULL, NULL, NULL, '한나', NULL, '[부가설명] 1만엔 / 릴스1건 + 스토리4건', 'available', false, true),
(gen_random_uuid(), '치에짱', 'cccekaa', 'cccekaa', 40000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나나짱', 'na7golf', 'na7golf', 30000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에렌', '_elen.official', '_elen.official', 31000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '타케타로', 'taketaroutime', 'taketaroutime', 406000, 'taketaroutime', 710000, 'taketaroutime', 409000, 'taketaroutime', 6989, 'color', 'beauty', 'mega', 2400000, NULL, 2400000, NULL, 500000, 'WOW', NULL, '[부가설명] TikTok PR 게시물 1회: 2,400,000엔 ~ 2,500,000엔 (세금 별도)
릴스(Reel) 게시물 1회: 2,400,000엔 ~ 2,500,000엔 (세금 별도)
Spark Ads 1개월: 500,000엔 (세금 별도)
릴스 재게시(전재): 건별 협의', 'available', false, true),
(gen_random_uuid(), '시다히나노', 'sh__ddney', 'sh__ddney', 100000, 'sh__ddney', 730000, 'shinoschannel', 84600, 'sh_ddney', 1811, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'WOW', NULL, '[부가설명] 1. 인스타 : 릴스 800,000엔 / 피드 400,000엔 
2. 틱톡 : 1,300,000엔
3 오프라인 : ¥300,000＋출장비 (ASK)', 'available', false, true),
(gen_random_uuid(), '츠키히메', 'ot.si3', 'ot.si3', 97000, 'ot.si3', 400000, 'LUNE__channel', 52700, NULL, NULL, 'color', 'beauty', 'middle', NULL, 250000, 660000, NULL, NULL, 'WOW', NULL, '[부가설명] 1. 인스타 : 릴스 : 500,000엔 / 피드 250,000엔
2. 틱톡 : 500,000엔 
3. 오프라인 : ¥300,000＋출장비 (ASK) (이벤트 참가 할인가능)

[251118/WOW 라인방/순희]
·Reels1 투고 ¥660,000 (세금 포함)
·스토리1 투고 ¥55,000 (세금포함)
·2차 이용 1개월 ¥275,000 (세금 포함)

(TikTok 1 투고) ¥660,000 (세금 포함)
※ 일반적으로 타이업 할 때도 이 금액입니다.', 'available', false, true),
(gen_random_uuid(), '쿠라타노아', 'i_09_noa', 'i_09_noa', 140000, 'i_09_noa', 330000, 'UCV4Qg7XOW30nR9jglyK1xeg', 116000, 'i_09_noa', 114100, 'base', 'beauty', 'middle', NULL, 170000, 320000, 140000, NULL, '기타, JFUN', 'riseearth', '[부가설명] [250623 /메일회신] r.chikuni@riseearth.co.jp 
・Instagram 릴스: ¥320,000 (세금 별도)
・Instagram 피드: ¥170,000 (세금 별도)
・Instagram 스토리: ¥140,000 (세금 별도)
※ 콘텐츠 내용에 따라 수락이 어려울 수 있는 경우도 있습니다.
최근 Instagram 릴스 타이업에 관해서는, 가능한 한 광고 느낌이 들지 않도록 쿠라타의 평소 영상 콘텐츠 스타일로 녹여내어,
내레이션은 기본적으로 제외하고 자막도 최소한으로 억제한 템포감 있는 영상을 희망하는 경우가 있습니다.
또한, 성분 설명이나 자막을 통해 어필 포인트를 확실하게 전달하는 영상을 원하실 경우에는
쿠라타 노아의 TikTok에서의 진행을 추천드립니다.
쿠라타 노아\_TikTok 타이업 영상 1건: ¥450,000 (세금 별도)

---- --- 250818 tag 소속사 
틱톡 ¥600,000        ¥220,000

[251104/라이즈어 소속사/순희]
https://www.youtube.com/channel/UCV4Qg7XOW30nR9jglyK1xeg 유튜브
틱톡 ¥450,000
릴스: ¥320,000 
피드: ¥172,000 
스토리: ¥144,000', 'available', false, true),
(gen_random_uuid(), '타카타 세이카', 'seika____official', 'seika____official', 484000, 'seika_25', 800000, 'seika_official', 184000, 'seika_tamukai', 191600, 'color', 'beauty', 'mega', NULL, 1000000, 1100000, 800000, NULL, '기타, 아유네, JFUN', 'tag', '[부가설명] [250718/메일회신] takagi@toyboxagent.com
릴스 게시물: 110만 엔 (세금 별도)
피드 게시물: 100만 엔 (세금 별도)
스토리 게시물: 80만 엔 (세금 별도)

--- 250818 tag 소속사 
틱톡 ¥1,000,000        인스타 피드 ¥650,000', 'available', false, true),
(gen_random_uuid(), '모모코', 'momoko.kawakami.29', 'momoko.kawakami.29', 95000, 'momoko.kawakami.29', 4674, 'UCEUq4O3GSUnEWEwkh5DaXMw', 14600, 'momokokotakote', 2770, 'base', 'beauty', 'middle', NULL, 500000, 600000, NULL, NULL, 'JFUN', NULL, '[부가설명] [250616/라인회신]
피드 게시① 최대 3장: ¥400,000 ② 최대 5장: ¥500,000 ③ 5장 이상: 협의 필요
릴스 30초 이내: ¥600,000  60초 이내: ¥800,000
스토리 세트로 1회 홍보 기준: ¥100,000
** PICK 이미지 사용 가능', 'available', false, true),
(gen_random_uuid(), '소헤이', 'sohei.japan', 'sohei.japan', 100000, 'sohei.japan', 273000, 'sohei.japan_1', 2080, 'jp___sohei', 21900, 'base', 'beauty', 'middle', NULL, 90000, 150000, 50000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥590,000 / 스파크애즈 1개월 : ¥120,000
스토리 : ¥50,000  / 릴스 게시 비용 : ¥150,000 / 릴스(전재비용): ¥120,000 / 피드 ¥90.000', 'available', false, true),
(gen_random_uuid(), '에츠코', 'etsuko_mrok', 'etsuko_mrok', 165000, 'etsuko_mrok', 207800, 'etsuko_mrok', 15400, 'etsuko_mrok', 18500, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '기타', NULL, '[부가설명] 신지상 연락중', 'available', false, true),
(gen_random_uuid(), 'FUU', 'fuchan_2003', 'fuchan_2003', 140000, 'fuchan_2003', 26100, 'UCX-SKMUHwFfWBpwKwXiP04Q', 30200, 'fuchan_2003', 53300, 'fashion', 'fashion', 'middle', NULL, 200000, 300000, 50000, 30000, '기타, JFUN', NULL, '[부가설명] [250722/DM회신]  조율가능
■ 릴스 1건: 300,000엔
■ 피드 1건: 200,000엔
■ 스토리 1건: 50,000엔
■ 2차 사용 (60일): 30,000엔
※ 위 모든 금액은 세금 별도입니다.

[251104/라이즈어 소속사/순희]
https://www.youtube.com/@fuchan_2003 유튜브', 'available', false, true),
(gen_random_uuid(), '미즈노 사아야', 'saaya_mizuno', 'saaya_mizuno', 170000, NULL, NULL, 'UCABAp3cj8aoFtarWVSLW0vw', 3600, 'saayamizuno', NULL, 'vlog', 'life', 'middle', NULL, NULL, 300000, NULL, NULL, '기타, 아유네, JFUN', NULL, '[부가설명] [250724/DM회신] sales@picfee.jp xx 이메일 안됨 
릴 1건당 약 20만 엔 전후', 'available', false, true),
(gen_random_uuid(), '나루', 'naru._.um', 'naru._.um', 89000, 'naa._.aru', 241900, 'naru_uchan', 87600, 'naru_uchan', 43300, 'color', 'beauty', 'middle', NULL, 180000, 220000, 60000, NULL, '기타, 아유네, JFUN', NULL, '[부가설명] [250725/메일회신]  contact@unlock-un.jp
◾️릴스 게시물 (1건): 220,000엔 (세금 별도) ※피드 노출은 1일 한정
◾️피드 게시물 (1건): 180,000엔 (세금 별도)
◾️스토리 게시물 (1건~복수): 1장당 60,000엔 (세금 별도)

*** 9월달 진행은 어려움', 'available', false, true),
(gen_random_uuid(), '히마리', 'himari0827', 'himari0827', 33000, 'himari0827', 102200, 'UCbK7qLf2hvMf3wHDO0rUblA', 53500, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, 100000, NULL, NULL, '기타', 'libertytown', NULL, 'available', false, true),
(gen_random_uuid(), '나오나오', 'naonao.diet1201', 'naonao.diet1201', 58000, 'naonao.diet', 29200, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아코레아', 'akorea423', 'akorea423', 27000, 'akorea423', 1921, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '네라', 'nera.beauty', 'nera.beauty', 142000, 'nera_beauty', 7499, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 450000, 550000, 50000, NULL, 'JFUN', '미용기획 주식회사', '[부가설명] [250613/라인회신] (세금 변도)
피드: 450,000엔 / 릴스: 550,000엔/ 스토리: 50,000엔 / 2차 사용료: 100,000엔 / 1개월
▼NERA & KARA코 세트 발주
<피드의 경우>
총액: 860,000엔 (세금 별도)
※ 일반 금액에서 90,000엔 할인 (약 10% 할인)

<릴스의 경우>
총액: 1,040,000엔 (세금 별도)
※ 일반 금액에서 110,000엔 할인 (약 10% 할인)

▼메가세일 콜라보 판매 실행 금액
(브랜드 측 요청에 따라 패키지 내용 조정 가능)
NERA 피드의 경우: 750,000엔 (세금 별도)
내역:
피드: 450,000엔
스토리 5건 게시 (링크 포함 3건): 250,000엔
2차 사용 1개월 (Pick 이미지 사용/광고 집행용): 100,000엔
※ 고정 핀 고정(피드 상단 고정) 희망 시 위 금액에 추가로 150,000엔 발생
※ 위 패키지는 저가형 구성으로 제공되는 것이므로, 스토리 추가 시에는 일반 요금이 적용됩니다
※ KARA코와의 세트 발주일 경우, 할인 조정 등 유연하게 대응 가능합니다

---8월쯤 라운드랩 제안시 답변 
특별이 10% 할인   콜라보 실시 비용 : 81만엔  * 비과세인 경우 추가비용 2500엔 ( 릴스 1 + 스토리 5건 +  2차 사용 픽사용 )

[250807/순희/라인]
릴스 1건 + 스토리 5건 (인스타그램 이미지 사용) :  812,500엔 (비과세)

[250905/순희/카라코리스트]
피드 투고: ¥450,000
릴스 투고: ¥550,000
2차 활용(1개월) : ¥100,000', 'available', false, true),
(gen_random_uuid(), '카라코', 'karako_cosme', 'karako_cosme', 167000, 'karako_cosme', NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 500000, 600000, 50000, NULL, 'JFUN', '미용기획 주식회사', '[부가설명] [250613/라인회신] (세금 변도)
피드: 500,000엔 /  릴스: 600,000엔 / 스토리: 50,000엔 / 2차 사용료: 100,000엔 / 1개월

▼NERA & KARA코 세트 발주
<피드의 경우>
총액: 860,000엔 (세금 별도)  / ※ 일반 금액에서 90,000엔 할인 (약 10% 할인)

<릴스의 경우>
총액: 1,040,000엔 (세금 별도) / ※ 일반 금액에서 110,000엔 할인 (약 10% 할인)

▼메가세일 콜라보 판매 실행 금액
(브랜드 측 요청에 따라 패키지 내용 조정 가능)
NERA 피드의 경우: 750,000엔 (세금 별도)
내역: 피드: 450,000엔 / 스토리 5건 게시 (링크 포함 3건): 250,000엔
2차 사용 1개월 (Pick 이미지 사용/광고 집행용): 100,000엔
※ 고정 핀 고정(피드 상단 고정) 희망 시 위 금액에 추가로 150,000엔 발생
※ 위 패키지는 저가형 구성으로 제공되는 것이므로, 스토리 추가 시에는 일반 요금이 적용됩니다
※ KARA코와의 세트 발주일 경우, 할인 조정 등 유연하게 대응 가능합니다

[250905/순희/카라코리스트]
피드 투고: ¥500,000
릴스 투고: ¥600,000
2차 활용(1개월) : ¥100,000', 'available', false, true),
(gen_random_uuid(), '모노나오', 'mono96nao', 'mono96nao', 41000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미조베 히카루', 'hikaru_mizobe', 'hikaru_mizobe', 147000, 'hikaru_mizobe', 382800, 'hikaru_mizobe', 165000, 'hikarumizobe', 2911, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '손아미', 'snam8_', 'snam8_', 171000, 'snam8_', 600000, 'snam8_', 38100, 'snam8_', 39, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '기타, 아유네, 신지상', NULL, '[부가설명] [ 250709 신지상 회신] 다른 에이전시랑 진행중이라 연결이 어려운 상황', 'available', false, true),
(gen_random_uuid(), '니시무라 켄타', 'nishimurakentakun', 'nishimurakentakun', 108000, 'kenta_nishimura0', 77100, 'nishimurakenta', 1140, 'nishimurakentan', 6543, 'color', 'beauty', 'middle', NULL, 110000, 180000, NULL, NULL, '기타', NULL, '[부가설명] [251105/신지상답변/순희]
인스타그램 피드 포스팅 : 110,000엔(세금 별도) ~
Instagram 릴게시 : 180,000엔(세금별도) ~', 'available', false, true),
(gen_random_uuid(), '모모에', 'momoe1919', 'momoe1919', 102000, NULL, NULL, 'mihawkb', 62500, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '쿠루미', 'kurumimi1113', 'kurumimi1113', 162000, NULL, NULL, 'mimifilm', 99600, 'kurumimi1113', 9597, 'color', 'beauty', 'middle', NULL, NULL, 200000, 30000, NULL, '기타, JFUN', NULL, '[부가설명] kuruminnie1113@gmail.com
[250722/DM회신]
■ 릴스 1건: 200,000엔
■ 스토리 1건: 30,000엔', 'available', false, true),
(gen_random_uuid(), '에리나', '___er_5m', '___er_5m', 262000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사리나', 'sssaaarrriina', 'sssaaarrriina', 24000, 'saaaaaariiiiiiinaaaaaa', 219, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에리스코', 'erisuko_.s22', 'erisuko_.s22', 18000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 40000, 70000, 20000, NULL, '스플애드, JFUN', NULL, '[부가설명] [250617/라인회신]
릴스 : 7만 엔 (TikTok에도 함께 업로드 시 8만 엔)
피드 : 4만 엔 / 스토리: 2만 엔', 'available', false, true),
(gen_random_uuid(), '치히로', 'chihirosawa', 'chihirosawa', 35000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '기타', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '후지', 'missfuuji', 'missfuuji', 192000, 'fuuji__', 800000, 'missfuuji', 211000, 'missfuuji', 44800, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥2,400,000 / 스파크애즈 1개월 : 480,000엔
스토리 : ¥50,000  / 릴스(전재비용) : ¥1,000,000 / 피드 770,000엔 (릴스만 가능한지 확인 필요)', 'available', false, true),
(gen_random_uuid(), '세요', 'emiiseyo', 'emiiseyo', 37000, 'emiiseyo', 780000, 'UC2Swu9ZOW6GgAaGOkSt-jRg', 29500, 'emiiseyo', 31, 'color', 'beauty', 'micro', 2400000, 500000, 2400000, NULL, 400000, 'PPP스튜디오', NULL, '[부가설명] TikTok PR 게시물 1회: 2,400,000엔 (세금 별도)
릴스(Reel) 게시물 1회: 2,400,000엔 (세금 별도)
Spark Ads 1개월: 400,000엔 (세금 별도)
릴스 재게시(전재): 500,000엔 (세금 별도)
피드 게시물 1회: 500,000엔 (세금 별도)

【せよ】レギュレーション_202506', 'available', false, true),
(gen_random_uuid(), '주티 마티아', 'zuttijapanese', 'zuttijapanese', 515000, 'zutti_tok', 710000, NULL, NULL, 'japanese_ken', 21400, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥2,500,000 / 스파크애즈 1개월 : 500,000엔
스토리 : ¥50,000/  / 릴스 게시 비용 : 2,500,000엔 / 릴스(전재비용) : ¥1,000,000 / 피드 750,000엔', 'available', false, true),
(gen_random_uuid(), '슈가솔트', 'sugarsalt__official', 'sugarsalt__official', 25000, 'sugarsalt_official', 470000, 'sugarsalt.official', 304000, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥500,000 / 스파크애즈 1개월 : 100,000엔
스토리 : ¥20,000  / 릴스 : ¥170,000 / 릴스(전재비용) : ¥90,000 / 피드 120,000엔', 'available', false, true),
(gen_random_uuid(), '마유언니', 'mayunee.fem', 'mayunee.fem', 300000, 'mayunee.fem', 332100, 'mayunee_fem', NULL, 'mayunee_fem', 51400, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥590,000  / 스파크애즈 1개월 : 120,000엔
스토리 : ¥50,000 / 릴스 게시 비용 : ¥750,000 / 릴스(전제비용) : ¥340,000 / 피드 : ¥250,000', 'available', false, true),
(gen_random_uuid(), '타무라 나오야', 't_amu708', 't_amu708', 20000, 't_amu708', 321400, 't_amu708', 66900, 'tamu0708', 275, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥420,000 / 스파크애즈 1개월 : 90,000엔
스토리 : ¥50,000  / 릴스 : ¥170,000 / 릴스(전재비용)160,000엔 / 피드 120,000엔', 'available', false, true),
(gen_random_uuid(), '미네 리아나', 'riana_mine', 'riana_mine', 53000, 'riana_mine', 275000, 'UC5n5KFMOESCy9DFNMn3AV6Q', 170000, 'leanna_mse', 3142, 'color', 'beauty', 'middle', NULL, 90000, 150000, 50000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥340,000 / 스파크애즈 1개월 : 70,000엔
스토리 : ¥50,000  / 릴스 게시 비용 : 150,000엔 / 릴스(전재비용): ¥70,000 / 피드 90,000엔', 'available', false, true),
(gen_random_uuid(), '미즈키', 'm___22___y', 'm___22___y', 103000, 'mizuki....22', 198700, 'm___22___y', 92900, NULL, NULL, 'color', 'beauty', 'middle', NULL, 140000, 250000, 40000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥420,000 / 스파크애즈 1개월 : ¥90,000
스토리 : ¥40,000  / 릴스 게시 비용 : ¥250,000 / 릴스(전재비용): ¥90,000 / 피드 ¥140,000', 'available', false, true),
(gen_random_uuid(), '우유໒꒱', '_o4.uyu_', '_o4.uyu_', 93000, '_o4.uyu_', 190000, '_o4.uyu_', 17400, NULL, NULL, 'color', 'beauty', 'middle', NULL, 70000, 250000, 30000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥300,000 / 스파크애즈 1개월 : ¥60,000
스토리 : ¥30,000  / 릴스 게시 비용 : ¥180,000 / 릴스(전재비용): ¥100,000 / 피드 ¥70,000

[순희/251014/소속사]
·2차 이용(이미지 사용): 3만엔
·nstagram Reels 1회: 250,000엔 (부가세 별도)
·Meta 광고 전달 1개월 : 50,000엔 (부가세 별도)', 'available', false, true),
(gen_random_uuid(), '솔로 씨', 'zid0ri', 'zid0ri', 12000, 'zid0ri', 156000, 'zid0ri', 124000, 'zid0ri', 557, 'health', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '호민', 'homie.512', 'homie.512', 13000, 'homie.512', 109000, NULL, NULL, 'homie_512', 11300, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'PPP스튜디오', NULL, '[부가설명] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미남 야노', 'yano__beauty', 'yano__beauty', 52000, 'beauty_yano', 70000, 'UC0J207a77jE68AocS6BtzRg', 74700, 'bidanshi_yano', 145, 'color', 'beauty', 'middle', NULL, NULL, 450000, NULL, 50000, 'PPP스튜디오', NULL, '[부가설명] 릴스, 쇼츠, 틱톡

• 1개 매체 게시: 45만 엔 (세금 별도)
• 2개 매체 게시: 50만 엔 (세금 별도)
• 3개 매체 게시: 55만 엔 (세금 별도)

2차 사용
• 매체 1개당: 월 5만 엔 (세금 별도)', 'available', false, true),
(gen_random_uuid(), '모모 (슈가솔트)', 'momo_ogata', 'momo_ogata', 27000, 'momo_sugarsalt', 57000, 'sugarsalt.official', 304000, 'laiciffo_omom', 4722, 'color', 'beauty', 'micro', NULL, 90000, 150000, 50000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥300,000 / 스파크애즈 1개월 : ¥60,000
스토리 : ¥50,000  / 릴스 게시 비용 : ¥150,000 / 릴스(전재비용): ¥90,000 / 피드 ¥90,000', 'available', false, true),
(gen_random_uuid(), '신리', 'purplebigbaby', 'purplebigbaby', 1893, 'purplebigbaby', 5200, 'purplebigbaby', 408, NULL, NULL, 'base', 'beauty', 'micro', NULL, 150000, 150000, 50000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥200,000 / 스파크애즈 1개월 : ¥40,000
스토리 : ¥ 50,000 / 릴스 게시 비용 : ¥150,000 / 릴스(전재비용): ¥150,000 / 피드 ¥150,000', 'available', false, true),
(gen_random_uuid(), '야네 언니', 'ya_ne_1103', 'ya_ne_1103', 8400, 'yaneonni', 10000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, 30000, 150000, 10000, NULL, 'PPP스튜디오', NULL, '[부가설명] 틱톡 : ¥150,000 / 스파크애즈 1개월 : ¥30,000
스토리 : ¥10,000  / 릴스 게시 비용 : ¥150,000 / 릴스(전재비용): ¥30,000 / 피드 ¥30,000', 'available', false, true),
(gen_random_uuid(), '희영', 'cchan_fee4', 'cchan_fee4', 330000, NULL, NULL, 'hiyonchannel', 700000, NULL, NULL, 'base', 'beauty', 'mega', NULL, 1000000, 1300000, 500000, NULL, '아유네, JFUN', NULL, '[부가설명] --- jfun --- 
[250613/라인회신]
(모두 세금 별도 )
인스타그램 릴스 (더빙 없음): 1,200,000엔
인스타그램 릴스 (더빙 포함): 1,300,000엔
인스타그램 피드: 1,000,000엔
인스타그램 스토리: 500,000엔', 'available', false, true),
(gen_random_uuid(), '후루하타 세이카', 'starandsummer', 'starandsummer', 260000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] seika.furuhata.official@gmail.com

[250811/신지상]
피드 투고: ¥411,000
릴스 투고: ¥548,000', 'available', false, true),
(gen_random_uuid(), '마에다 노조미', 'maeda_nozomi', 'maeda_nozomi', 323000, NULL, NULL, 'maeda_nozomi', 226000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, 한나, 신지상', NULL, '[부가설명] 581400

--- 신지상 소통중', 'available', false, true),
(gen_random_uuid(), '야마모토 루나', 'ohana_runa', 'ohana_runa', 210000, 'ohana_runa', 10900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미키', '___mikik___', '___mikik___', 204000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 300000, 400000, 100000, NULL, '아유네, JFUN', NULL, '[부가설명] [2507/22/DM회신]
◾️ 릴스 게시 (1건): 35만~40만 엔 ※ 게시물 내용에 대한 지시 및 감독이 강할 경우 40만 엔으로 책정됩니다.
◾️ 피드 게시 (1건): 30만 엔 ※ 복수 이미지 및 태그 포함
◾️ 스토리 게시 (1건~복수): 스토리당 10만 엔 ※ 아카이브로 프로필 상단에 고정할 경우 월 5만 엔 추가', 'available', false, true),
(gen_random_uuid(), '마아리', 'maari.0108', 'maari.0108', 309000, 'maari.0108', 101900, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥556,200', 'available', false, true),
(gen_random_uuid(), '사토 유리아', 'yuriang_', 'yuriang_', 306000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥550,800', 'available', false, true),
(gen_random_uuid(), '오오구치 치에미', 'chemiiiii', 'chemiiiii', 220000, 'chemiiiii', NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사노 유키코', 'yukikosano1111', 'yukikosano1111', 305000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 300000, 610000, 100000, NULL, '아유네, JFUN', NULL, '[부가설명] 518400

[251202 라인 회신] 
릴스 팔로워 × 1.7엔 ~ 2.0엔 → 대략 61만 엔
피드 팔로워 × 1엔 → 대략 30만 엔
스토리 1개 10만 엔부터 ~
콜라보 게시물 문의', 'available', false, true),
(gen_random_uuid(), '스즈나', 'succhanal__09', 'succhanal__09', 290000, NULL, NULL, 'succhanal__09', 37000, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 350000, 100000, NULL, '아유네, JFUN', NULL, '[부가설명] info@trapeziste-creative.com  연락중 JFUN 
[ 250707 이메일회신] 아리얼 제안시 내용 
릴스  35만엔 (세금별도) 
릴 1건과 스토리 1건, 총 2건 게시로
45만 엔 + 세금으로 진행 가능', 'available', false, true),
(gen_random_uuid(), '코코
(본명;이시하라유리코)', 'coco_coco000', 'coco_coco000', 540000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 50000, 80000, 20000, NULL, '아유네, JFUN', NULL, '[부가설명] ①[모두가능]
릴 1회 + 스토리 2장  (게시 비용 : ¥977,400-세금 별도)

---JFUN---[250613/라인회신]
피드 게시물: 30,000엔 ~ 50,000엔 (세금 포함)
릴스 게시물: 50,000엔 ~ 80,000엔 (세금 포함)
스토리: 10,000엔 ~ 20,000엔', 'available', false, true),
(gen_random_uuid(), '노자키 모에카', 'moeka_nozaki', 'moeka_nozaki', 300000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 550800, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] ②[선크림 안됨]
릴 1회 + 스토리 2장 (게시 비용 : ¥550,800-세금 별도)
ーーーーＪＦUＮ　[ 250707 이메일 회신]desaki-takami@av.avex.co.jp　아리얼 제안시 내용 
릴스 1건: 20만 엔 ~ 60만 엔 (내용에 따라 금액 변동)
피드 1건: 20만 엔 ~ 30만 엔 (내용에 따라 다름)
스토리  1건 등: 15만 엔 ~ 20만 엔', 'available', false, true),
(gen_random_uuid(), '사노마이', 'sanomaisanomai', 'sanomaisanomai', 250000, NULL, NULL, 'sanomaisanomai', 13600, NULL, NULL, 'color', 'beauty', 'middle', NULL, 466200, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 라운드랩 진행 : https://www.instagram.com/reel/DKeR1TXRWeT/?igsh=dmljd3ZobHo1aTdk
③[모두가능] 릴 1회 + 스토리 2장 (게시 비용 : ¥466,200-세금 별도)', 'available', false, true),
(gen_random_uuid(), '미우', 'immiu3', 'immiu3', 266000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 478800, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미나미 모모에', 'xoemomo', 'xoemomo', 224000, 'xoemomo', 225600, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 403200, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ⑬[모두가능]릴스 1회 + 스토리 2장 (게시 비용 :¥401,400)', 'available', false, true),
(gen_random_uuid(), '이나가키 리오', 'sep17ri', 'sep17ri', 223000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 401400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나나', '_twinkle_makeup_', '_twinkle_makeup_', 290000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '레이나', 'leina810', 'leina810', 181000, 'leina810', 34800, 'leina810', 9510, NULL, NULL, 'color', 'beauty', 'middle', NULL, 300000, 400000, 150000, 150000, '아유네, 기타, JFUN', NULL, '[부가설명] ¥325,800

 [250722/메일회신]  leina.n8n@gmail.com
- 릴스 1건: 40만 엔(세금 별도)부터 상담 가능
- 피드 게시물은 기본적으로 진행하지 않지만, 아이템에 따라 상담은 가능.
피드 1건: 30만 엔(세금 별도)을 기준으로 생각해주시면 감사하겠습니다.
- 스토리 1건: 15만 엔(세금 별도)   단, 릴스 게시가 확정된 경우에는 별도로 금액이 더 저렴해집니다.
2차 사용에 해당되므로, 1개월 기준 15만 엔

** 금액은 어디까지나 참고용이며, 아이템이나 진행 내용에 따라 별도로 조정 가능합니다.', 'available', false, true),
(gen_random_uuid(), '야마가 코토코', 'kotokoyamaga', 'kotokoyamaga', 430000, 'kotokoyamaga', 50700, 'kotokoyamaga', 93600, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '쿠로다 리코', 'kuroda_riko', 'kuroda_riko', 320000, 'kuroda_riko', 14200, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 576000, NULL, NULL, NULL, '아유네, 한나', NULL, '[부가설명] 라운드랩 : https://www.instagram.com/reel/DKtyoyezgAr/
④[모두가능] 릴스 1회 + 스토리 2회  (게시 비용 : ¥576,000) / 아유네', 'available', false, true),
(gen_random_uuid(), '나카다 아키코', 'akiico', 'akiico', 270000, 'akiico', NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '이시이 미호', 'miho_ishii', 'miho_ishii', 330000, NULL, NULL, 'miho_ishii', 85000, NULL, NULL, 'base', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카세', '_kayodoll_', '_kayodoll_', 220000, '_kayodoll_', 473500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 401400, NULL, NULL, NULL, '아유네', NULL, '[부가설명] kayodoll3838@gmail.com', 'available', false, true),
(gen_random_uuid(), '타쿠보 카린', 'kar_insta_gram', 'kar_insta_gram', 351000, 'kar_insta_gram', NULL, 'UCgLLIxDOwM2QFAoZqHSGi7w', 251000, 'takubokarin', 43300, 'fashion', 'fashion', 'mega', NULL, 770000, 1650000, 660000, NULL, '아유네, 한나, JFUN', NULL, '[부가설명] 631800

 [250723/메일회신] info@beaile.co.jp
* 리쥬란, 바이오단스 가능 ( 아렌시아, 라운드랩 x )
◾️ 릴스 게시물 (1건): 165만 엔
◾️ 피드 게시물 (1건): 77만 엔
◾️ 스토리 게시물 (1건~복수 가능): (1건) 66만 엔
※ 1건만 진행 가능합니다. 여러 장 연속으로 업로드되는 스토리는 진행하지 않습니다.', 'available', false, true),
(gen_random_uuid(), '아카리 오노', 'riuakari', 'riuakari', 408000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 500000, 800000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 734400
info@ariuinc.com

--250818 tag 소속사 
틱톡  ¥500,000	인스타 피드 ¥800,000', 'available', false, true),
(gen_random_uuid(), '에프티씨뷰티', 'ftcbeauty.official', 'ftcbeauty.official', 186000, 'towakokimijima_ftcbeauty', 67800, 'UCd3Dfpgg89AXz2t1xcN6ltA', 90700, 'FTC_beauty', 1895, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에미네', 'emk_oooo', 'emk_oooo', 250000, 'emk_oooo', 55700, 'emk_oooo', 619000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, 한나', NULL, '[부가설명] 450000

info@moonlit.co.jp', 'available', false, true),
(gen_random_uuid(), '세키네 리사', 'sekine.risa', 'sekine.risa', 384000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 691200

info@sekinerisa.jp', 'available', false, true),
(gen_random_uuid(), '카와니시 미키', 'mikipon1111', 'mikipon1111', 340000, NULL, NULL, 'featured', 1000000, NULL, NULL, 'color', 'beauty', 'mega', NULL, 1400000, 2100000, 567600, 420000, 'JFUN, 아유네', NULL, '[부가설명] YouTube 롱폼(장편): ¥2,850,000
YouTube 숏폼: ¥2,100,000
인스타그램 피드: ¥756,800
인스타그램 릴스: ¥2,100,000
인스타그램 스토리: ¥567,600
X(구 트위터): ¥380,000
TikTok: ¥1,400,000
YouTube 쇼츠 + 릴스 재활용: ¥3,400,000
릴스 또는 쇼츠 + TikTok 재활용: ¥2,800,000
YouTube 쇼츠 + TikTok + 인스타 릴스 전체 재활용: ¥4,000,000
광고 1매체 1쿨: ¥840,000
2차 활용 1매체 1쿨: ¥420,000', 'available', false, true),
(gen_random_uuid(), '쿠로다', 'kurodamayukaxx', 'kurodamayukaxx', 210000, NULL, NULL, 'kurodamayukaxx', 43400, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 400000, 450000, NULL, NULL, '아유네, 신지상', NULL, '[부가설명] ⑤[비거나이즈/립희망]
릴 1회 + 스토리 2장 (게시 비용 : ¥394,200-) 

[신지상회신/250718]
릴스 게시물 + 스토리 게시물：450,000円
피드 게시물 + 스토리 게시물：400,000円', 'available', false, true),
(gen_random_uuid(), '코지마 마코', 'makochan_2525', 'makochan_2525', 240000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카지 마리코', 'kajimari1226', 'kajimari1226', 310000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '이하라 아오이', 'aoi186', 'aoi186', 645000, 'aoi186', 12900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, 2900000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250612/메일회신] (세금 별도 표기)erina_izumitani@bullz.jp
YouTube 타이업(브랜드 제한 없음) 1회: 2,300,000엔~
YouTube 타이업(브랜드 제한 있음) 1회: 2,600,000엔~
Instagram 피드 1회: 1,300,000엔
Instagram 릴스 1회: 1,700,000엔~
Instagram 스토리 1회: 650,000엔
2차 사용(온라인/1개월): 600,000엔→ 1개월 단위로만 진행이 가능
*큐텐 상세페이지 이미지 사용 불가 XXX!!

[250710 신지상 회신]
・릴스 게시물 + 스토리 게시물: 2,900,000엔
・피드 게시물 + 스토리 게시물: 2,400,000엔
※스토리는 피드/릴스 게시물의 리포스트이며, 별도의 내용 지정(태그, 링크, 해시태그 등)이 없을 경우, 비용은 받지 않습니다.', 'available', false, true),
(gen_random_uuid(), '키리마루', 'kirimaruuu', 'kirimaruuu', 733000, 'kirimaruuu', 335500, 'kirimaruuu', 1070000, NULL, NULL, 'health', 'life', 'mega', NULL, 1500000, 2400000, 500000, NULL, '아유네, JFUN', NULL, '[부가설명] [250723/메일회신] contact@fooop.jp
인스타그램 피드 게시물: 150만 엔 + 세금
인스타그램 스토리 게시물: 50만 엔 + 세금부터 ※ 영상 길이 및 작업량에 따라 협의 가능
인스타그램 릴스 게시물: 240만 엔 + 세금 ※ 인스타그램 스토리 사전 홍보 포함

 [250729/신지상회신]  밀잇 제안시 
릴스 게시 + 스토리 게시: 3,800,000엔
피드 게시 + 스토리 게시: 2,600,000엔
※ 게시물을 간단히 리포스트하는 정도의 스토리일 경우, 할인 협의 가능

2차 활용 1개월: 400,000엔
2차 활용 3개월: 1,200,000엔

9월 일정은 불가능하며, 10월 이후라면 진행 협의 가능하나, 오리엔시트 확인 후 최종 판단을 희망합니다.', 'available', false, true),
(gen_random_uuid(), '레이카', 'reika0901', 'reika0901', 316000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 572400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '피토', 'hitoe_style', 'hitoe_style', 274000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 495000, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키라리', 'kirari_1016_', 'kirari_1016_', 374000, 'kirari_1016_', 822900, 'kirari_1016_', 2880, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리리카', 'ririka_0508', 'ririka_0508', 260000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마이마이', 'maimai.007', 'maimai.007', 309000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '코무로 아미', 'ami_komuro', 'ami_komuro', 286000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '린카', '1n_o28', '1n_o28', 279000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '줄리아', 'julia.c.0209', 'julia.c.0209', 369000, 'julia.c.0209', 102100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오사키', 'sakichanman_you', 'sakichanman_you', 458000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', 1300000, 500000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] --250818 tag 소속사 

틱톡 ¥1,300,000	인스타 피드 ¥500,000', 'available', false, true),
(gen_random_uuid(), '스즈키아미', 'ami927s', 'ami927s', 335000, 'ami927s', 31300, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유스코', 'yukos0520', 'yukos0520', 426000, 'yukos0520', 72300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 2000000, 2500000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250725/메일회신] info@kospro.jp
 피드 게시물: 200만 엔  /   릴스 게시물: 250만 엔
유튜브 게시물: 250만 엔', 'available', false, true),
(gen_random_uuid(), '타카아시아카리', 'akari___0302', 'akari___0302', 521000, 'akari___0302', 396000, 'akari___0302', 106000, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나카무라 아사미', 'asami_nakamura_', 'asami_nakamura_', 362000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '쵸시', 'cyoshi___', 'cyoshi___', 249000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '요시다 레이카', 'reikayoshida_', 'reikayoshida_', 315000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '히가시 아키', 'akihigashihara', 'akihigashihara', 434000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모나', 'momoonaaa', 'momoonaaa', 311000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 한국사는 일본 크리에이터 momona.info@gmail.com', 'available', false, true),
(gen_random_uuid(), '에아', 'volbic_xx', 'volbic_xx', 822000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 950000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] --250818 tag 소속사 

인스타 피드 ¥950,000', 'available', false, true),
(gen_random_uuid(), '마야', 'mayaaa_124', 'mayaaa_124', 973000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 1600000, 1300000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] --250818 tag 소속사 
틱톡 ¥1,600,000      인슽 피드   ¥1,300,000', 'available', false, true),
(gen_random_uuid(), '아사미 메이', 'mei_asami_', 'mei_asami_', 784000, 'mei_asami_', 1600000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 950000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] info@starray-p.com

--250818 tag 소속사 

인스타 피드 ¥950,000', 'available', false, true),
(gen_random_uuid(), '미나미', 'mimi.minami.mimi', 'mimi.minami.mimi', 842000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 860000, 1290000, 430000, NULL, '아유네, JFUN', NULL, '[부가설명] [250725/메일회신]  info.minami.0819@gmail.com
■대략적인 견적  2025년 9월 말까지 유효
・인스타그램 릴스 1건: 1,290,000엔
・인스타그램 사진 피드 1건: 860,000엔
・인스타그램 스토리 1건: 430,000엔
※모든 금액은 세금 별도입니다.
※구체적인 게시 내용이나 오리엔시트 확인 전의 대략적인 견적이므로, 상세 내용에 따라 변동될 수 있습니다.
※제반 비용은 포함되어 있지 않으며, 필요 시 별도로 지급해주셔야 합니다.', 'available', false, true),
(gen_random_uuid(), '히나코', 'hlnak06', 'hlnak06', 316000, 'hlnak06', 102500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '요코다 미라이', 'mirai_yokoda', 'mirai_yokoda', 301000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 850000, 350000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥850,000  인스타 피드  ¥350,000', 'available', false, true),
(gen_random_uuid(), '후루사와 리사', 'fuuuuu_ri', 'fuuuuu_ri', 404000, 'fuuuuu_ri', 912400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 980000, 500000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] ino@ndpromotion.co.jp

250818 tag 소속사 
틱톡 ¥980,000        인스타 피드 ¥500,000', 'available', false, true),
(gen_random_uuid(), '카논', 'kanon420_official', 'kanon420_official', 319000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아미 스즈키', 'ami_._._suzuki', 'ami_._._suzuki', 276000, 'ami_._._suzuki', 1200000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 300000, 400000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
릴스 1건 (단독 게시든 스토리 1건 포함이든 동일 금액): 400,000엔
피드 1건 (단독 게시든 스토리 1건 포함이든 동일 금액): 300,000엔
세 가지 모두 세트로 진행하실 경우, 조금 할인되어 500,000엔', 'available', false, true),
(gen_random_uuid(), '사가 스즈카', 'suzuka.saga', 'suzuka.saga', 380000, 'suzuka.saga', 229300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리코', 'h_rico16', 'h_rico16', 398000, 'h_rico16', 30900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모카', '__peachstagram__', '__peachstagram__', 571000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', 670000, 650000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] takagi@toyboxagent.com

250818 tag 소속사 

틱톡 ¥670,000      인스타 피드   ¥650,000', 'available', false, true),
(gen_random_uuid(), '모에', 'm____wip', 'm____wip', 324000, 'm____wip', 363600, 'm____wip', 1910, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '챠챠', 'chacch1', 'chacch1', 465000, NULL, NULL, 'chacch1', 111000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오카자키 사에', 'sae_okazaki', 'sae_okazaki', 835000, 'sae_okazaki', 1823, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유즈키', '_yuzuki22', '_yuzuki22', 298000, '_yuzuki22', 165700, '_yuzuki22', 107000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오자와 미사토', 'misatooozamisa', 'misatooozamisa', 331000, NULL, NULL, 'misatoozawa1781', 272000, NULL, NULL, 'base', 'beauty', 'mega', NULL, 605000, 770000, 546150, NULL, '아유네, JFUN', 'meilly', '[부가설명] " [250617/메일회신]s.mori@meilly.jp
 릴스 : 770,000엔/ 피드 605,000엔 / 스토리 546,150엔 ~
가격표 PDF 있음 (일본어)
file:///C:/Users/JFUN/Desktop/%E3%80%902025.07.01-09.30%E3%80%91Meilly_%EC%9D%B8%ED%94%8C%EB%A3%A8%EC%96%B8%EC%84%9C%20%EA%B0%80%EA%B2%A9%20%EB%B0%8F%20%EC%86%8C%EA%B0%9C.pdf

--7/9 시점 내용 
숏폼 세트 메뉴 (현재 기준, 가장 빠른 업로드 가능 시점: 9월)
2개 매체 (YouTube 숏폼 + 인스타그램 릴스) : 100만 엔 + 소비세

Instagram (현재, 최단 9월 게시 가능)
릴 (피드 게시 가능): 700,000엔 + 소비세 ※촬영 시트 포함
※클라이언트 계정의 인스타그램 스토리 신규 작성 시, 「○○님께서 게시해 주셨습니다」라는 문구(멘션 필수)로 작성하는 경우에 한해, 무상 게재 1회만 가능합니다.
▼ 2차 활용 비용
・정지 이미지 1소재 (1개월): 180,000엔 + 소비세
・영상 1소재 (3개월 미만 일괄): 360,000엔 + 소비세
 활용 범위 ⇒ 자사 사이트, 클라이언트 소유 SNS, 온라인 몰,  메일 매거진, 오프라인 매장 등 활용 가능 (사전 보고 필수)
 ※ 영상 그대로를 클라이언트 SNS에 게시하는 것은 불가합니다.  LP나 홈페이지에서의 활용은 가능
 ※ 짧은 영상 편집은 1개의 장면을 잘라내는 1회에 한해 무상 제공 /   복수 장면을 하나의 영상으로 편집할 경우, 별도의 편집 비용(150,000엔 + 소비세)이 발생합니다
 ※ 대행사나 클라이언트 측에서의 편집은 불가하오니 유의해주시기 바랍니다
・디지털 광고 송출 1소재 (1개월): 360,000엔 + 소비세
※ YouTube 광고는 인피드 광고만 가능하며, 그 외 위치는 불가합니다
※ “AD 네트워크”는 불가하오니 양해 부탁드립니다', 'available', false, true),
(gen_random_uuid(), '사이토 사키', 'saki__saito', 'saki__saito', 314000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] info@ysm-inc.com', 'available', false, true),
(gen_random_uuid(), '후나키', 'funacky325', 'funacky325', 676000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', 700000, 1300000, NULL, NULL, NULL, '아유네, 기타, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥700,000      인스타 피드   ¥1,300,000', 'available', false, true),
(gen_random_uuid(), '치세', 'peach_chu_', 'peach_chu_', 357000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 642600, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '텐치무', 'super_muchiko', 'super_muchiko', 797000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사쿠라', 'sakura_0808_', 'sakura_0808_', 964000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 2400000, 2700000, 1800000, NULL, '아유네, JFUN', 'tag', '[부가설명] sakura0808.mg@gmail.com / yusukenishina24@gmail.com
[250616/메일회신] 
릴스 270만엔/ 피드 240만엔 / 스토리 180만엔
자세한 가격표 
https://docs.google.com/spreadsheets/d/1o7Cr9eD9hUx7nqxypUEQQ_ukMHE6UFXD/edit?gid=1065107993#gid=1065107993

--- 250818 tag 소속사 
인스타 피드 ¥1,200,000', 'available', false, true),
(gen_random_uuid(), '바아쿠', 'baaaakuuuu', 'baaaakuuuu', 416000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키타노 히나코', 'kitanohinako_official', 'kitanohinako_official', 297000, NULL, NULL, 'kitanohinako_official', 117000, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 1000000, 1000000, 1000000, NULL, '아유네, JFUN', NULL, '[부가설명] [250806/메일회신] sihoko.kobayashi @amee.fun
◾️릴스 게시물 (1건)　100만 엔
◾️피드 게시물 (1건)　100만 엔
◾️스토리 게시물 (1건~복수)　100만 엔', 'available', false, true),
(gen_random_uuid(), '호노카', 'honoka.n28', 'honoka.n28', 276000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, 한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카히나', 'xxkhyn', 'xxkhyn', 258000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] xxkhyn06@gmail.com', 'available', false, true),
(gen_random_uuid(), '오타니 에미리', 'otani_emiri', 'otani_emiri', 439000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '후쿠오카 미나미', 'fukuokaminami373', 'fukuokaminami373', 291000, 'fukuokaminami373', 580900, 'fukuokaminami373', 72400, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '쿠도 미오', 'mmio_kudo', 'mmio_kudo', 306000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야카', 'am1026_official', 'am1026_official', 382000, 'am1026_official', 464200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아리사 우에노', 'alisaueno', 'alisaueno', 645000, NULL, NULL, 'alisaueno', 182000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 1000000, 1300000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250725/메일회신] alisaueno.info@bullz.jp / erina_izumitani@bullz.jp
기본 비용 *상품마다 변동이 있어 확정금액은 아닙니다. 
YouTube 타이업 (브랜드 제한 없음) 1회: 2,000,000엔~
YouTube 타이업 (브랜드 제한 있음) 1회: 2,250,000엔~
Instagram 피드 게시물 1회: 1,000,000엔~
Instagram 릴스 1회: 1,300,000엔~', 'available', false, true),
(gen_random_uuid(), '나고미', '__nagomi32__', '__nagomi32__', 954000, '__nagomi32__', 525100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', 4500000, NULL, 4000000, NULL, NULL, '아유네', 'vaz', '[부가설명] [250925 vaz 케스팅]
틱톡 ¥4,500,000		릴스 ¥4,000,000', 'available', false, true),
(gen_random_uuid(), '아이', '__aiiiia__', '__aiiiia__', 283000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 400000, 750000, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] [250806/메일회신] management.miura@gmail.com　매니저 이메일
・IG 피드: 400,000엔 (세금 별도)   ※1번째 이미지는 자유 이미지일 것이라는 조건입니다.
・IG 릴스: 750,000엔 (세금 별도)
・IG 스토리: 단독 판매는 없음   ※IG 릴스 또는 피드와 세트일 경우, +50,000엔부터 판매 가능

--250818 tag 소속사 리스트에 있음', 'available', false, true),
(gen_random_uuid(), '카와사키 노조미', 'kawasakinozomi', 'kawasakinozomi', 295000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 800000, 1000000, NULL, 1100000, '아유네, 신지상', NULL, '[부가설명] [신지상회신/250718]
릴스 게시물 + 스토리 게시물：1,000,000円
피드 게시물 + 스토리 게시물：800,000円
2차 사용(1개월)：1,100,000円
2차 사용(3개월)：2,000,000円', 'available', false, true),
(gen_random_uuid(), '코피야마', 'kopiyama_', 'kopiyama_', 301000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 700000, 800000, NULL, 150000, '아유네, 신지상', NULL, '[부가설명] [신지상회신/250718]
릴스 게시물 + 스토리 게시물：800,000円
피드 게시물 + 스토리 게시물：700,000円
2차 사용(1개월)：150,000円
2차 사용(3개월)：350,000円', 'available', false, true),
(gen_random_uuid(), '오노카', 'ononono_ka', 'ononono_ka', 325000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나스 호홈', 'nasu_hohomi', 'nasu_hohomi', 329000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하타 메이', 'mei_hata_official', 'mei_hata_official', 608000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오카다 사야카', 'sayaka_okada', 'sayaka_okada', 886000, 'sayaka_okada', 278600, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사이토 나기사', 'saitou_nagisa', 'saitou_nagisa', 596000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '루나', 'luna_7373', 'luna_7373', 321000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오린', 'ourin_ringoooo', 'ourin_ringoooo', 388000, 'ourin_ringoooo', 166000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마이 신우치', 'mai.shinuchi_official', 'mai.shinuchi_official', 296000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카토 미카', 'katomika1212', 'katomika1212', 299000, 'katomika1212', 112200, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 150000, 350000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥150,000    인스타 피드    ¥350,000', 'available', false, true),
(gen_random_uuid(), '아이자와 에미리', 'emiri_aizawa', 'emiri_aizawa', 839000, 'emiri_aizawa', 203900, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유나', 'yuna_3047', 'yuna_3047', 355000, NULL, NULL, 'yuna_3047', 16100, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 430000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

 인스타 피드¥430,000', 'available', false, true),
(gen_random_uuid(), '아이사', 'aaaisa.d.r.chihuahua', 'aaaisa.d.r.chihuahua', 312000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', 600000, 350000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥600,000     인스타 피드    ¥350,000', 'available', false, true),
(gen_random_uuid(), '마아미', 'maaaami79', 'maaaami79', 289000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 850000, 350000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥850,000         인스타 피드 ¥350,000', 'available', false, true),
(gen_random_uuid(), '키지마 아스카', 'asuka_kijima', 'asuka_kijima', 647000, 'asuka_kijima', 34300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '군지 쿄코', 'kyoko_gunji', 'kyoko_gunji', 264000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '스미레', 'sumire808', 'sumire808', 509000, 'sumire808', 6037, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아유미 힐스', 'ayumihills', 'ayumihills', 511000, 'ayumihills', 1100000, 'ayumihills', 10700, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 300000, 500000, 100000, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
피드 300,000엔부터 / 릴스 500,000엔부터 / 스토리  100,000엔부터
상담가능', 'available', false, true),
(gen_random_uuid(), '무메이', 'mumeix820', 'mumeix820', 881000, 'mumeix820', 22800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리코', 'riko_riko1204', 'riko_riko1204', 557000, NULL, NULL, 'riko_riko1204', 1030, NULL, NULL, 'fashion', 'fashion', 'mega', 1600000, 870000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥1,600,000    인스타 피드     ¥870,000', 'available', false, true),
(gen_random_uuid(), '사라', 'lespros_sara00', 'lespros_sara00', 361000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '세로리칸보우초칸', 'serorikanbouchoukan', 'serorikanbouchoukan', 417000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', 1700000, 600000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥1,700,000  인스타 피드    ¥600,000', 'available', false, true),
(gen_random_uuid(), '모토카노', 'motokano._.29', 'motokano._.29', 431000, 'motokano._.29', 582500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, 한나', NULL, '[부가설명] 한나 : 콜라보 40만엔', 'available', false, true),
(gen_random_uuid(), '료카', 'ryoka_0720', 'ryoka_0720', 277000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 교통사고로 인해 활동 중지중 25.05부터', 'available', false, true),
(gen_random_uuid(), '카토', 'n_katooo0705', 'n_katooo0705', 676000, 'n_katooo0705', 1643, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', 2700000, 1200000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥2,700,000	인스타 피드 ¥1,200,000', 'available', false, true),
(gen_random_uuid(), '미유미유', 'miyumiyu1112', 'miyumiyu1112', 420000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] [순희 : 칮을 수 없는 인스타그램]', 'available', false, true),
(gen_random_uuid(), '카파짱', '_kappachan_24', '_kappachan_24', 285000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 600000, 450000, NULL, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 250818 tag 소속사 

틱톡 ¥600,000    인스타 피드    ¥450,000', 'available', false, true),
(gen_random_uuid(), '쿠로사키 미사', 'misa_k88', 'misa_k88', 272000, NULL, NULL, 'misa_k88', 263000, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리세', '1209rise', '1209rise', 299000, '1209rise', 1600000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사사하라요오스케', 'ymmty30', 'ymmty30', 236000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 283200, 306800, NULL, NULL, '아유네, JFUN', 'wilm', '[부가설명] ⑧[최종 라운드랩/비거나이즈립 가능함] [1차 비거나이즈/립만 가능]
릴스 1회 + 스토리 2회(1개 : ¥423,000) / 2개 게시 비용 : ¥846,000

---JFUN --- 
[250617/메일회신] ohata@wilm.co.jp
인스타그램 피드 1건 + 스토리 1건→ 팔로워 수 × 1.2엔 + 세금~
인스타그램 릴스 1건 + 스토리 1건 → 팔로워 수 × 1.3엔 + 세금~

이하 캐스팅 인원이 많은 경우, 볼륨 할인도 가능합니다.
yui.       〈 IG @ymmty30 〉
sayako 〈 IG @sysysysy_0623 〉
nana     〈 IG @nnmg__ 〉
yo         〈 IG @yo_kinoshita〉
sana.    〈 IG @sanagram.__ 〉
suni.     〈 TW @suni__fit 〉 X(구 Twitter) 게시물: 팔로워 수 × 1.0엔 + 세금~', 'available', false, true),
(gen_random_uuid(), '나카세코 유키나', 'yuch1129', 'yuch1129', 66000, NULL, NULL, 'yuch1129', 10400, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '기타카제 아스카', 'asukaa02', 'asukaa02', 221000, 'asukaa02', 28800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '치바 유카', 'chibayuka', 'chibayuka', 185000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] chibayuka.info@gmail.com', 'available', false, true),
(gen_random_uuid(), '와카나', '991231t', '991231t', 155000, '991231t', 71400, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, 코노나', NULL, '[부가설명] 279000 
[ 250714 코노나 회신]  9월달 투어 진행 예정', 'available', false, true),
(gen_random_uuid(), '기미나', '___kimi3___', '___kimi3___', 105000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사토오마키', 'maakkiii1144', 'maakkiii1144', 166000, 'maakkiii1144', 18500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 295200, NULL, NULL, '아유네', NULL, '[부가설명] ⑨[비거나이즈/립만 가능 OK / 자외선 차단제 NG]
릴스 1회 + 스토리 2회 (게시 비용 : ¥295,200)', 'available', false, true),
(gen_random_uuid(), '산주우다이짱', 'woman_from30', 'woman_from30', 61000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥109,800', 'available', false, true),
(gen_random_uuid(), '나기노호타루', 'hotarutaru21', 'hotarutaru21', 95000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 171000, NULL, NULL, '아유네', NULL, '[부가설명] ⑦[전상품 가능]
릴스 1회 + 스토리 2회  (게시 비용 : ¥171,000)', 'available', false, true),
(gen_random_uuid(), '이노하나 치히로', 'inohanachihiro', 'inohanachihiro', 90000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 162000, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마미', '__mamigram___', '__mamigram___', 292000, NULL, NULL, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키타 요시카', 'kita_bichou', 'kita_bichou', 109000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '스다 마이', 'mai._.suda', 'mai._.suda', 71000, 'mai._.suda', 18400, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, 한나', NULL, '[부가설명] ⑩[비가나이즈/립 만희망]
릴스 1회 + 스토리 2회  (게시 비용 : ¥126,000)', 'available', false, true),
(gen_random_uuid(), '이리에 시오리', 'sh10110', 'sh10110', 73000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥131,400', 'available', false, true),
(gen_random_uuid(), '얀', 'yan___5', 'yan___5', 165000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모리야마사키', 'morisaki0404', 'morisaki0404', 78000, 'morisaki0404', 5856, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, 138600, NULL, NULL, '아유네', NULL, '[부가설명] ⑪[전체상품 가능] 
릴스 1회 + 스토리 2장 (게시 비용 : ¥138,600)', 'available', false, true),
(gen_random_uuid(), '츠치야 카나', 'cami_kana', 'cami_kana', 450000, 'cami_kana', 334000, NULL, NULL, NULL, NULL, 'food', 'food', 'mega', NULL, NULL, 2500000, NULL, 850000, '아유네, JFUN', NULL, '[부가설명] 842400

------ [250724/DM회신] 
상품을 사용해본 후, PR이 가능한 경우  현재 비용은 다음과 같습니다.
■ 릴스 1건・2,500,000엔 (세금 별도)   ※ 팔로워 수 × 단가 5엔 (향후 팔로워 수에 따라 가격 변동 가능성 있음)
■ 기타 서비스
・릴스 → 스토리 공유
・스토리 1건 추가 (URL 첨부 등)
・TikTok 동시 업로드 (현재 팔로워 20만 명 ※ TikTok 단독 PR은 현재 진행하지 않음)
위 4가지 세트로 진행 가능합니다.
■ 2차 활용 비용 (Meta 광고, TikTok 광고 등 사용 가능)   ・1개월: 850,000엔 ・3개월: 2,500,000엔', 'available', false, true),
(gen_random_uuid(), '코노 유미', 'yuumikono125', 'yuumikono125', 209000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥376,200', 'available', false, true),
(gen_random_uuid(), '나나', 'nana.0312', 'nana.0312', 441000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, 기타, JFUN', NULL, '[부가설명] 793800

[250725/메일회신] nana.contact@crazeofficial.jp   / shinoda@crazeofficial.jp 
모든 신규 PR 진행 불가 XXX', 'available', false, true),
(gen_random_uuid(), '야나기하시 유이', 'yui.yanagihashi', 'yui.yanagihashi', 349000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 3300000, 4200000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 628200
---
[ 250709 신지상회신] 아렌시아 제안시 내용  
소속사가 대기업이라 금액이 비싸요 
9월 10일 이후라면 협의 가능하며,   최종 상품 확인 후 판단을 원하십니다.
・릴 게시물 + 스토리 게시물: 4,200,000엔 (세금 별도) -->> 세금포함 가격 4,640,000엔
・피드 게시물 + 스토리 게시물: 3,300,000엔 (세금 별도) -->> 세금포함 가격3,630,000엔
※ 피드는 정지 이미지 최대 3장까지 가능하며, 그 중 1장을 영상으로 변경 가능
※ 스토리는 정지 이미지 게시물입니다', 'available', false, true),
(gen_random_uuid(), '이시 히로미', 'romi_1006', 'romi_1006', 228000, 'romi_1006', 44500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, 한나', NULL, '[부가설명] 한나 : 450,000엔 
¥410,400', 'available', false, true),
(gen_random_uuid(), '모나코', 'monako0515', 'monako0515', 884000, NULL, NULL, 'monako0515', 65400, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 1591200

[250728/메일회신] info_monako@a-light.jp', 'available', false, true),
(gen_random_uuid(), '시카노마', 'rhodon41', 'rhodon41', 270000, 'rhodon41', 198200, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 589600, NULL, 442200, NULL, '아유네, JFUN', 'meilly', '[부가설명] [250617/메일회신]s.mori@meilly.jp
 릴스 : 상담필요/ 피드 589,600엔 / 스토리 442,200엔 ~
각겨 표 PDF 있음 (일본어)
file:///C:/Users/JFUN/Desktop/%E3%80%902025.07.01-09.30%E3%80%91Meilly_%EC%9D%B8%ED%94%8C%EB%A3%A8%EC%96%B8%EC%84%9C%20%EA%B0%80%EA%B2%A9%20%EB%B0%8F%20%EC%86%8C%EA%B0%9C.pdf
7/2 jfun -------------
모든 타이업 10월 이후에 가능, 11월 메가와리 때도 일찍 확정되야 가능하다고 합니다.', 'available', false, true),
(gen_random_uuid(), '미즈코시 미사토', 'mitan.m', 'mitan.m', 319000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네, 한나, JFUN', NULL, '[부가설명] 574200

[250709 신지상 회신]  라운드랩 제안시 거절 xx
기본적으로 스킨케어 상품은 PR NG', 'available', false, true),
(gen_random_uuid(), '이와마 메구미', 'iwamame', 'iwamame', 198000, 'iwamame', 3683, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 356400

info@eternalfriends.jp', 'available', false, true),
(gen_random_uuid(), '하우스다스트', 'tamukun_36', 'tamukun_36', 380000, 'tamukun_36', 1500000, 'tamukun_36', 1180000, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 684000

contact@up-p.co.jp', 'available', false, true),
(gen_random_uuid(), '하나우에 쥰', 'jnp92119', 'jnp92119', 387000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', NULL, 800000, 1650000, 600000, NULL, '아유네, JFUN', NULL, '[부가설명] [250623/메일회신] hanauejun119@gmail.com
릴 1건 게시: 165만 엔
피드 1건 게시: 80만 엔
스토리 1건 게시: 60만 엔', 'available', false, true),
(gen_random_uuid(), '사야코', 'sysysysy_0623', 'sysysysy_0623', 238000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 342720, 309400, NULL, NULL, '아유네, JFUN', 'wilm', '[부가설명] ⑮[전제품 가능]릴스 1회 + 스토리 2장 (게시 비용 :¥428,400)

--JFUN --- 
[250617/메일회신] ohata@wilm.co.jp
인스타그램 피드 1건 + 스토리 1건→ 팔로워 수 × 1.2엔 + 세금~
인스타그램 릴스 1건 + 스토리 1건 → 팔로워 수 × 1.3엔 + 세금~

이하 캐스팅 인원이 많은 경우, 볼륨 할인도 가능합니다.
yui.       〈 IG @ymmty30 〉
sayako 〈 IG @sysysysy_0623 〉
nana     〈 IG @nnmg__ 〉
yo         〈 IG @yo_kinoshita〉
sana.    〈 IG @sanagram.__ 〉
suni.     〈 TW @suni__fit 〉 X(구 Twitter) 게시물: 팔로워 수 × 1.0엔 + 세금~', 'available', false, true),
(gen_random_uuid(), '나나코', '_nana._.com_', '_nana._.com_', 270000, 'nanamameco', 240000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, 2825000, NULL, 500000, '아유네, 기타', 'UUUM', '[부가설명] 아유네 제안 : 486,000엔(팔로워1.8)
25년 11월 메가와리 기준
유튜브 숏츠+릴스 2,825,000엔
2차이용 500,000엔', 'available', false, true),
(gen_random_uuid(), '카토유리', 'katoyuridayo', 'katoyuridayo', 395000, 'katoyuridayo', 734000, 'katoyuridayo', 292000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '후루카와 유카', 'iamyukaf', 'iamyukaf', 718000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 1292400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '뾰나', '_000919_', '_000919_', 520000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 아유네 제안 : 937,800(팔로워1.8)', 'available', false, true),
(gen_random_uuid(), '미즈타니 카에', 'mizutani_kae', 'mizutani_kae', 258000, 'mizutani_kae', 254400, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥493,200', 'available', false, true),
(gen_random_uuid(), '키리탄포', 'kiritampopopo', 'kiritampopopo', 719000, 'kiritampopopo', 23100, 'kiritampopopo', 1330000, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '윤', 'yuntaaam_s2', 'yuntaaam_s2', 337000, NULL, NULL, NULL, NULL, NULL, NULL, 'food', 'food', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '사콘 스즈노', 'suzuno_sakon', 'suzuno_sakon', 188000, 'suzuno_sakon', 14900, 'suzuno_sakon', 57900, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 330000, 390000, 150000, NULL, '아유네, JFUN', NULL, '[부가설명] ⑫ [비가나이즈/립희망]
아유네 : 릴스 1회 + 스토리 2장 (게시 비용 : ¥338,400)

---- jfn----- [250613/메일회신]
(세금 별도)
YouTube 롱폼 1편: 450,000엔
（※ 브랜드 독점 조건이 있을 경우 +100,000엔 추가 발생）
릴스 1편: 390,000엔 / 피드 1편: 330,000엔  / 스토리 1편: 150,000엔', 'available', false, true),
(gen_random_uuid(), '신야마 모모코', 'momomoo_2', 'momomoo_2', 257000, 'momomoo_2', 6445, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥462,600', 'available', false, true),
(gen_random_uuid(), '리리카', 'ririka_0225_', 'ririka_0225_', 210000, 'ririka_0225_', 493400, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 250000, 350000, 150000, NULL, '아유네, JFUN', NULL, '[부가설명] 378000

---  [250724/DM회신] 
릴스 1건 게시: 35만 엔 (세금 별도)
피드 1건 게시: 25만 엔 (세금 별도)
스토리 1건 게시: 15만 엔 (세금 별도)', 'available', false, true),
(gen_random_uuid(), '가나카', 'kanakastella', 'kanakastella', 197000, 'kanakastella', 163400, 'kanakastella', 38100, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] kanakaworks@gmail.com', 'available', false, true),
(gen_random_uuid(), '엔소짱', 'jyo.kin', 'jyo.kin', 195000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 292500, NULL, NULL, NULL, '아유네, JFUN', 'nukta', '[부가설명] "[250616/라인회신] nukta 소속사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 "', 'available', false, true),
(gen_random_uuid(), '가연', 'gyeon.yn', 'gyeon.yn', 155000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 277200

gayeongayeon.kr@gmail.com

[250811/신지상]
피드 투고: ¥267,000
릴스 투고: ¥356,000', 'available', false, true),
(gen_random_uuid(), '아리짱', 'niinana27', 'niinana27', 146000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 262800, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250614/메일회신] nomura@buggy.tokyo
PR 투고 XXX 어려워서 거절', 'available', false, true),
(gen_random_uuid(), '카키부치 모모노
히토에', 'hitoedes13', 'hitoedes13', 181000, 'hitoedes13', 350000, 'hitoedes13', 223000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 325800

momonobuchi13@gmail.com

[순희/ 화장품 메인/팔로워수 보다 노출수가 더 높으신 분]', 'available', false, true),
(gen_random_uuid(), '우카', 'd28_uka', 'd28_uka', 145000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 145000, 145000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
피드, 릴스  팔로워 X 1엔  / 스토리 2~3 투고로 팔로워 X 1엔

[251030]
릴스 : ¥152,000
광고 코드+2차 사용(이미지): ¥60,000
총: ¥212,000', 'available', false, true),
(gen_random_uuid(), '유우냥', 'yuunyan_222', 'yuunyan_222', 142000, 'yuunyan_222', 561200, 'yuunyan_222', 258000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥255,600', 'available', false, true),
(gen_random_uuid(), '하나마루', 'hana_maru_7', 'hana_maru_7', 137000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '스지코', 'cooneru_suji_co', 'cooneru_suji_co', 133000, 'unkomorasunayo', 507700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, 1200000, NULL, NULL, '아유네, JFUN', 'tag', '[부가설명] 239400

---- 250818 tag 소속사
제품 재료나 투고 시기에 따라 다르지만,
100만~120만 정도', 'available', false, true),
(gen_random_uuid(), '노보리 모에', 'moe_nobori', 'moe_nobori', 132000, 'moe_nobori', 27200, 'moe_nobori', 24900, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '니나', 'nina_27story', 'nina_27story', 127000, 'nina_27story', 9489, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 228600

[ 250709 신지상회신]  자사 브랜드가 있기 때문에 아리얼 NG 
상품마다 다른건지 확인 필요', 'available', false, true),
(gen_random_uuid(), '오자키 마이', 'm.mai_ozaki', 'm.mai_ozaki', 127000, NULL, NULL, 'm.mai_ozaki', 10400, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 228600, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '코미', 'kooooomi64', 'kooooomi64', 113000, 'kooooomi64', 86800, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유우네', 'give_me_jishin', 'give_me_jishin', 108000, 'give_me_jishin', 106100, 'give_me_jishin', 104000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥196,200', 'available', false, true),
(gen_random_uuid(), '나유', 'nayouuw', 'nayouuw', 109000, 'nayouuw', 191200, 'nayouuw', 59800, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥196,200', 'available', false, true),
(gen_random_uuid(), '미노리', 'minori_aboutus', 'minori_aboutus', 96000, 'minori_aboutus', 33500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '야미짱', 'ayami_yamichan', 'ayami_yamichan', 90000, 'ayami_yamichan', 838300, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, 2800000, 600000, 600000, '아유네, 한나, 신지상', 'twin', '[부가설명] 162000

-----[250724/신지상 회신]  아렌시아 제안시 답장 
 ■ Instagram 릴스   금액: 2,800,000엔   (피드 게재 포함, 경쟁 배제 조건, 자막 콘티 제공, 재촬영 없음, 수정 1회)
※ 오프라인 방문이 필수일 경우 별도 협의
■ Instagram 스토리   금액: 600,000엔   (URL 협의 가능, 이미지만 제공)
※ 하이라이트 등록은 불가합니다.   ※ 해시태그는 #PR 포함 최대 2개까지로 부탁드립니다.
■ Instagram 광고 (경쟁 배제 조건)    1주일 금액: 600,000엔
※ 본인 계정과 연동된 영상만 수락 가능합니다.
※ 본인 계정에 게시된 콘텐츠(전재)가 필수입니다.
※ URL 링크가 포함될 경우, 사전에 협의 부탁드립니다.
※ 클라이언트 공식 계정에서의 게시 및 광고 집행은 현재 수락하지 않고 있습니다.
장기 광고를 원하실 경우 별도로 견적 드리오니, 문의 부탁드립니다.

[251202/TWIN 라인방/순희]
피드: ¥400,000
릴스: ¥1,900,000
2차 이용료: ¥300,000(1週間)
※MAX2週間（要相談', 'available', false, true),
(gen_random_uuid(), '아리시아', 'alicia__gram', 'alicia__gram', 89000, 'alicia__gram', 15800, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '노노코', '_nonstyle_', '_nonstyle_', 85000, '_nonstyle_', 16700, '_nonstyle_', 2080, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, 85000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 153000
[ 250711DM 회신 ] 
릴스 1건 85000엔 정도 ?? 자세한 내용 회신 대기중', 'available', false, true),
(gen_random_uuid(), '마메', 'mame_beauty_', 'mame_beauty_', 81000, 'mame_beauty_', 7816, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥145,800', 'available', false, true),
(gen_random_uuid(), '고토 시츠', 'sh_11_zu', 'sh_11_zu', 80000, 'sh_11_zu', 19200, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, 144000, NULL, 50000, '아유네', NULL, '[부가설명] ⑭[전제품 가능] 릴스 1회 + 스토리 2장 (게시 비용 :¥144,000)

mg.nyangorosanva@gmail.com 연락중 

[250910/순희/라인방]
【10~11월 요금표】
릴 ¥140,000
스토리즈➕릴 투고 ¥160,000
릴➕TT 전재 ¥170,000
※2차 이용은 별도로 받고 있습니다.', 'available', false, true),
(gen_random_uuid(), '나나', 'nnmg__', 'nnmg__', 186000, NULL, NULL, 'nnmg__', 36700, NULL, NULL, 'color', 'beauty', 'middle', NULL, 223200, 241800, NULL, NULL, '아유네, JFUN', 'wilm', '[부가설명] ⑯[전제품 가능]릴스 1회 + 스토리 2장 (게시 비용 :¥333,000)

---JFUN --- 
[250617/메일회신] ohata@wilm.co.jp
인스타그램 피드 1건 + 스토리 1건→ 팔로워 수 × 1.2엔 + 세금~
인스타그램 릴스 1건 + 스토리 1건 → 팔로워 수 × 1.3엔 + 세금~

이하 캐스팅 인원이 많은 경우, 볼륨 할인도 가능합니다.
yui.       〈 IG @ymmty30 〉sayako 〈 IG @sysysysy_0623 〉
nana     〈 IG @nnmg__ 〉 yo         〈 IG @yo_kinoshita〉
sana.    〈 IG @sanagram.__ 〉 suni.     〈 TW @suni__fit 〉 X(구 Twitter) 게시물: 팔로워 수 × 1.0엔 + 세금~

[ 라인 매니저님 회신] 아리얼건 

⚪ 일반 PR 진행 시
릴스 1건 +스토리 1건 =    팔로워 수 × 1.3엔 + 세금
⚪ 콜라보 진행 시
릴스 1건 + 스토리 연속적으로 2장  +  Qoo10 페이지 내 이미지 전재 (메가와리 기간 중)  =  팔로워 수 × 1.4엔 + 세금
※ 위 조건 이상으로 스토리 게재를 희망할 경우에는 별도 견적   ※ 2차 사용은 포함되지 않음

[0714 라인 회신 ]  
① 콜라보 진행 시 ・릴 1건 게시  ・스토리 2연속 / 1회  ・Qoo10 페이지 내 이미지 전재 (메가할인 기간 중)
→ FW × 1.4엔 + 세금 → 185,000 × 1.4엔 = 259,000엔 + 세금
② 스토리 추가 비용에 대해
・①과는 별도의 날짜에 게재
・릴 콘텐츠의 소재를 활용한 크리에이티브 제작
・광고 느낌이 강하지 않은, 자연스러운 형태의 오가닉 게시물에 가까운 구성
아래 금액으로 진행 가능합니다.
※①과 함께 발주해주시는 경우에 한함
→ 스토리 1건 게시: 30,000엔 + 세금', 'available', false, true),
(gen_random_uuid(), '키노시타 요', 'yo_kinoshita', 'yo_kinoshita', 102000, 'yo_kinoshita', 12600, 'yo_kinoshita', 35600, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 122400, 132600, NULL, NULL, '아유네, JFUN', 'wilm', '[부가설명] ⑰[전제품 가능]릴스 1회 + 스토리 2장 (게시 비용 :¥183,600)

---JFUN --- 
[250617/메일회신] ohata@wilm.co.jp
인스타그램 피드 1건 + 스토리 1건→ 팔로워 수 × 1.2엔 + 세금~
인스타그램 릴스 1건 + 스토리 1건 → 팔로워 수 × 1.3엔 + 세금~

이하 캐스팅 인원이 많은 경우, 볼륨 할인도 가능합니다.
yui.       〈 IG @ymmty30 〉
sayako 〈 IG @sysysysy_0623 〉
nana     〈 IG @nnmg__ 〉
yo         〈 IG @yo_kinoshita〉
sana.    〈 IG @sanagram.__ 〉
suni.     〈 TW @suni__fit 〉 X(구 Twitter) 게시물: 팔로워 수 × 1.0엔 + 세금~', 'available', false, true),
(gen_random_uuid(), '사나', 'sanagram.__', 'sanagram.__', 69000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 82800, 89700, NULL, NULL, '아유네, JFUN', 'wilm', '[부가설명] ⑱[전제품 가능]릴스 1회 + 스토리 2장 (게시 비용 :¥122,400)

---JFUN --- 
[250617/메일회신] ohata@wilm.co.jp
인스타그램 피드 1건 + 스토리 1건→ 팔로워 수 × 1.2엔 + 세금~
인스타그램 릴스 1건 + 스토리 1건 → 팔로워 수 × 1.3엔 + 세금~

이하 캐스팅 인원이 많은 경우, 볼륨 할인도 가능합니다.
yui.       〈 IG @ymmty30 〉
sayako 〈 IG @sysysysy_0623 〉
nana     〈 IG @nnmg__ 〉
yo         〈 IG @yo_kinoshita〉
sana.    〈 IG @sanagram.__ 〉
suni.     〈 TW @suni__fit 〉 X(구 Twitter) 게시물: 팔로워 수 × 1.0엔 + 세금~', 'available', false, true),
(gen_random_uuid(), '세리나', 'serina_aespa', 'serina_aespa', 30000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '한나', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '메구미 칸자키', 'megumi_kanzaki', 'megumi_kanzaki', 1064000, 'megumi_kanzaki', 44500, 'megumi_kanzaki', 207000, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥1,915,200', 'available', false, true),
(gen_random_uuid(), '구디미나미', 'gudeminami', 'gudeminami', 351000, 'gudeminami', 49300, 'gudeminami', 36000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥631,800', 'available', false, true),
(gen_random_uuid(), '미카이오자키', 'mikiozaki_', 'mikiozaki_', 282000, NULL, NULL, 'mikiozaki_', 36500, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥507,600', 'available', false, true),
(gen_random_uuid(), '선웨이', 'sunwei1013', 'sunwei1013', 271000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 487800, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '노에', 'noe.lecinq', 'noe.lecinq', 244000, 'noe.lecinq', 124200, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 439200
[250709 신지상 회신] 아렌시아 제안시 PR 진행 불가', 'available', false, true),
(gen_random_uuid(), '요시오카 세이카', 'sw_718', 'sw_718', 239000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥430,200', 'available', false, true),
(gen_random_uuid(), '히카루', 'hikaru_0177', 'hikaru_0177', 232000, 'hikaru_0177', 56000, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] 417600
-- [ 250709 신지상 회신]  대리점 NG !  브랜드사랑 직접 소통을 원하십니다.', 'available', false, true),
(gen_random_uuid(), '린 선생님', 'beauty_geka_riku', 'beauty_geka_riku', 227000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥408,600', 'available', false, true),
(gen_random_uuid(), '손쿄', 'sonkyou1013', 'sonkyou1013', 215000, 'sonkyou1013', 13600, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 387000, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '니시야마 마오', 'nishiyamamao', 'nishiyamamao', 182000, NULL, NULL, 'nishiyamamao', 5970, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 190000, 230000, NULL, NULL, '아유네, 코노나', NULL, '[부가설명] 327600
 
[ 250715 코노나님 소개로 라인 회신] 아렌시아 제안시 [2510 T1/셀리젠진행시 동일]
피드 게시물: 190,000엔
릴 영상: 230,000엔', 'available', false, true),
(gen_random_uuid(), '요시다 리사', 'yoshirisaa', 'yoshirisaa', 167000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 300600, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유코 스즈키', 'sa_youu', 'sa_youu', 151000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 271800, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마유', 'ommmzu', 'ommmzu', 146000, 'ommmzu', 96500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥262,800', 'available', false, true),
(gen_random_uuid(), '유카', 'yuppi_91', 'yuppi_91', 133000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥239,400', 'available', false, true),
(gen_random_uuid(), '마코토', '__macoto', '__macoto', 130000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥234,000', 'available', false, true),
(gen_random_uuid(), '윳짱', 'h_m_cosme', 'h_m_cosme', 120000, 'h_m_cosme', 119600, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥216,000', 'available', false, true),
(gen_random_uuid(), '리나티', 'rinaty_0416', 'rinaty_0416', 118000, NULL, NULL, 'rinaty_0416', 283000, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥212,400', 'available', false, true),
(gen_random_uuid(), '하야타 유리코', 'yurikohayata', 'yurikohayata', 116000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 208800, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '다테 치하루', 'date_chiharu', 'date_chiharu', 107000, 'date_chiharu', 220300, 'date_chiharu', 140000, NULL, NULL, 'base', 'beauty', 'middle', 330000, 150000, 275000, 88000, NULL, '아유네, JFUN', 'tag', '[부가설명] [250617/메일회신]
셀프뷰티 픽서 조회수 높음  / info@hachidream.com 
릴스 : 275,000엔 / 피드 : 진행 불가 / 스토리 1장: 88,000엔 ※릴스와 세트일 경우에만 진행 가능
※모든 항목은 2차 사용료를 포함하지 않습니다.

7/8 시점 --> 라운드랩 가능 9/1~9/3 , 9/7~9/9 일정 빈
・인스타그램 릴 1건 게시: 275,000엔(비과세)
・인스타그램 스토리 2회 게시: 88,000엔(비과세)
・2차 활용(메가와리 기간 중 픽업 게재): 33,000엔(비과세)
【 합계: 396,000엔(비과세) 】', 'available', false, true),
(gen_random_uuid(), '나나', 'nana.cocon', 'nana.cocon', 99000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥178,200', 'available', false, true),
(gen_random_uuid(), '시오리', 'shio_yeol98', 'shio_yeol98', 97000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥174,600', 'available', false, true),
(gen_random_uuid(), '스즈카', '_ryoka_870', '_ryoka_870', 92000, '_ryoka_870', 11900, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥165,600', 'available', false, true),
(gen_random_uuid(), '나시키', '25_nsk_25', '25_nsk_25', 86000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥154,800', 'available', false, true),
(gen_random_uuid(), '유나', '__unqqr', '__unqqr', 82000, '__unqqr', 90600, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 147600, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카즈하 요코우치', 'kazuha_y5', 'kazuha_y5', 80000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 144000, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모타', 'furumomo_t', 'furumomo_t', 78000, 'furumomo_t', 11900, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥140,400', 'available', false, true),
(gen_random_uuid(), '마키짱', 'ymnmk0808', 'ymnmk0808', 73000, 'ymnmk0808', 19100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥131,400', 'available', false, true),
(gen_random_uuid(), '하치야 아미 공식', 'hachiyaami', 'hachiyaami', 68000, 'hachiyaami', 58200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, 122400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미와', 'miwa_asmr', 'miwa_asmr', 111000, 'miwa_asmr', 744400, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 80000, 150000, 20000, NULL, '아유네, JFUN', NULL, '[부가설명] [250923/순희/라인]
릴스 1회: 150,000엔', 'available', false, true),
(gen_random_uuid(), '시로미짱', 'shiro_mi_chan', 'shiro_mi_chan', 76000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 150000, 300000, 200000, NULL, '아유네, JFUN', NULL, '[부가설명] [250617/메일회신]shiromi@buggy.tokyo  
＜시로미쨩 타이업 정가＞
Instagram 피드 : 10만 엔 / 스토리 1회 (3장 세트): 15만 엔 / 릴스: 25만 엔
라이브 방송 1회: 10만 엔  /  2차 활용: 월 15만 엔~

TikTok 게시 1회: 25만 엔   /  2차 활용: 월 15만 엔~

※메가 세일 기간의 타이업 요금
Instagram 피드 : 15만 엔 / 스토리 1회 (3장 세트): 20만 엔  /  릴스 : 30만 엔
라이브 방송 1회: 15만 엔   /  2차 활용: 월 20만 엔~

TikTok 게시 1회: 30만 엔  /  2차 활용: 월 20만 엔~', 'available', false, true),
(gen_random_uuid(), '리오', 'rio.29dy', 'rio.29dy', 59000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 106200, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리노', 'rinono418', 'rinono418', 58000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 30000, 50000, 5000, NULL, '아유네, JFUN', NULL, '[부가설명] 104400

---JFUN  [250630 /DM회신]
릴스: 50,000엔
피드: 30,000엔
스토리: 5,000엔', 'available', false, true),
(gen_random_uuid(), '마코', 'ktmk___55', 'ktmk___55', 58000, 'ktmk___55', 17700, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥104,400', 'available', false, true),
(gen_random_uuid(), '스즈키 히카루', 'hika_suzuki', 'hika_suzuki', 58000, 'hika_suzuki', 41900, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 104400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하마다 아오이', 'aoihamada', 'aoihamada', 58000, NULL, NULL, 'aoihamada', 12700, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥104,400', 'available', false, true),
(gen_random_uuid(), '리라', 'beauty.rira', 'beauty.rira', 56000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥100,800', 'available', false, true),
(gen_random_uuid(), '하루나', '0507hn', '0507hn', 53000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥95,400', 'available', false, true),
(gen_random_uuid(), '한나미', 'han_nami_', 'han_nami_', 53000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, 95400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '우이', 'uitaem', 'uitaem', 50000, 'uitaem', 7270, 'uitaem316', 2800, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] 90000 
[ 250613 DM회신 ]  답변 대기중', 'available', false, true),
(gen_random_uuid(), '사토 마리코', 'pepe___29', 'pepe___29', 50000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 90000, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '한카이 판카이', 'hankaichan', 'hankaichan', 49000, 'hankaichan', 16300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, 60000, 10000, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
 피드: 50,000엔 / 릴스: 60,000엔 /  스토리: 10,000엔
인스타그램 릴스 + TikTok 재업로드: 65,000엔
콜라보 가격 : 릴스 1건 + 스토리 2장 + 이미지 사용 포함 70,000엔
콜라보 가격 : 릴스 1건 + 스토리 4장 + 이미지 사용 포함 85,000엔', 'available', false, true),
(gen_random_uuid(), '윤', 'yun.skincare_', 'yun.skincare_', 48000, 'yun.skincare_', 2475, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥86,400', 'available', false, true),
(gen_random_uuid(), '유이', 'yui_tokue', 'yui_tokue', 47000, 'yui_tokue', 49100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, 84600, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카시유이', 'kashiyui_beauty', 'kashiyui_beauty', 45000, 'kashiyui_beauty', 36400, 'kashiyui_beauty', 4330, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥81,000', 'available', false, true),
(gen_random_uuid(), '유리', '_yuriharupi_', '_yuriharupi_', 40000, '_yuriharupi_', 11800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, 80000, 30000, NULL, '아유네, JFUN', NULL, '[부가설명] 72000

---JFUN -- [250702/DM회신]
릴스: 팔로워 수 × 2엔 /  피드: 5만 엔  /  스토리 2장: 3만 엔', 'available', false, true),
(gen_random_uuid(), '우루루', 'ururu_biyo', 'ururu_biyo', 40000, 'ururu_biyo', 2959, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 50000, 80000, 30000, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
릴스  80,000엔 / 피드  50,000엔 / 스토리 30,000엔', 'available', false, true),
(gen_random_uuid(), '모테코스메짱', 'mote__cosme', 'mote__cosme', 40000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, 100000, 20000, NULL, '아유네, JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
릴스 10만엔 (2차사용 1달 5만엔) / 피드 5만엔 / 스토리 2만엔
상품 페이지 내 이미지 사용: 1개월 5만 엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798

[250808/순희/라인]
릴스 1회 + 스토리 4회 + 이미지 사용 = 250,000엔', 'available', false, true),
(gen_random_uuid(), '마유코', 'maaaayu_0512', 'maaaayu_0512', 39000, 'maaaayu_0512', 29200, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'micro', NULL, 50000, 80000, 30000, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/DM회신]
릴스  80,000엔 / 피드  50,000엔 / 스토리 30,000엔', 'available', false, true),
(gen_random_uuid(), '혼네짱', '50__honne', '50__honne', 38000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 68400, NULL, NULL, NULL, '아유네', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '쿠마자와 아리사', '_arisa_212_', '_arisa_212_', 36000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 55000, 60000, 10000, NULL, '아유네, JFUN', NULL, '[부가설명] [250613/메일회신] sumire.tanaka@appbrew.io
구체적인 상품에 따라 다르지만, 최소 가격 세금 별도
 피드 ¥55,000 ~/  릴스  ¥60,000 ~ / 스토리  ¥10,000 ~', 'available', false, true),
(gen_random_uuid(), '미진코', '3_jinkoooo', '3_jinkoooo', 33000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥59,400', 'available', false, true),
(gen_random_uuid(), '유', '123kirin', '123kirin', 33000, NULL, NULL, '123kirin', 11600, NULL, NULL, 'vlog', 'life', 'micro', NULL, 50000, 50000, NULL, NULL, '아유네, JFUN', NULL, '[부가설명] [250614/DM회신]
Instagram / TikTok / YouTube Shorts / X(구 Twitter) 모두에 게시 **1건당 50,000엔(세금 별도)', 'available', false, true),
(gen_random_uuid(), '킨마리', '_kimmarin_', '_kimmarin_', 30000, '_kimmarin_', 26000, '_kimmarin_', 11100, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥54,000', 'available', false, true),
(gen_random_uuid(), '고질라쨩', 'kakoushikakatan', 'kakoushikakatan', 30000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥54,000', 'available', false, true),
(gen_random_uuid(), '미유', 'cosmelove.korea', 'cosmelove.korea', 30000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '아유네', NULL, '[부가설명] ¥54,000', 'available', false, true),
(gen_random_uuid(), '아야니', 'ayani0625', 'ayani0625', 42000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, 40000, NULL, NULL, 'JFUN, 코노나', NULL, '[부가설명] 3개 브랜드 합산 10만엔

jfun-- > 현재 진행중인 분이라 연락 필요한지 확인', 'available', false, true),
(gen_random_uuid(), '미쥬', 'iwbcd___6', 'iwbcd___6', 93000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 100000, 150000, 50000, NULL, 'JFUN', NULL, '[부가설명] 한나님한테 DM 컨텍
릴 15만~ / 피드 10만~ / 스토리 5만~ (세금 별도)', 'available', false, true),
(gen_random_uuid(), '마루노우치', 'marunouchi__ol_', 'marunouchi__ol_', 263000, 'marunouchi__ol_', 15900, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] [250709 신지상 회신]  아리얼 NG', 'available', false, true),
(gen_random_uuid(), '사라', 'sara_parin', 'sara_parin', 237000, NULL, NULL, 'CosmeWotaSara', 1550000, NULL, NULL, 'color', 'beauty', 'middle', NULL, 400000, 1700000, 300000, NULL, 'JFUN', NULL, '[부가설명] [250613/메일회신] kirara_yamada@vaz.co.jp
릴스: ¥1,700,000 /  피드: ¥400,000 /  스토리: ¥300,000

*** 라운드랩 진행 거절', 'available', false, true),
(gen_random_uuid(), '사이토 미라이', 'miraisaitou716', 'miraisaitou716', 190000, 'miraisaitou716', 4661, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 250000, 300000, 150000, NULL, 'JFUN', NULL, '[부가설명] [250625/메일회신] yanagihara@playdot.co.jp 
비용에 대해서는 시기나 내용에 따라 다소 변동이 있을 수 있으나, 아래를 기본적인 기준으로 상담하고 있습니다.
* 인스타그램 피드 게시물: 25만 엔(세금 별도)
* 인스타그램 릴 게시물: 30만 엔(세금 별도)
* 인스타그램 스토리즈 게시물: 15만 엔(세금 별도)
※ 2차 사용에 대해서는 별도 견적이며, 기준으로는 한 달에 25만 엔부터 상담 가능합니다.', 'available', false, true),
(gen_random_uuid(), '코마츠 유유코', 'yuyukmt', 'yuyukmt', 171000, 'yuyukmt', 24200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '세라베이비', 'serababy_', 'serababy_', 110000, 'serababy_', 106500, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미소', 'j__ms_99', 'j__ms_99', 102000, NULL, NULL, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카포', 'kapo_025', 'kapo_025', 96000, 'kapo_025', 277400, 'kapo_025', 239000, NULL, NULL, 'base', 'beauty', 'middle', NULL, 300000, 550000, NULL, NULL, NULL, NULL, '[부가설명] [250728/메일회신] kapomail25@gmail.com
◾️릴스 게시물 (1건): 55만 엔
◾️피드 게시물 (1건): 30만 엔~
◾️스토리 게시물 (1건~복수): 협의 필요', 'available', false, true),
(gen_random_uuid(), '세레사', 's_20010827', 's_20010827', 73000, 's_20010827', 417700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '시즈카', 'szk_furocan', 'szk_furocan', 69000, 'szk_furocan', 52900, 'szk_furocan', 129000, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '고바야시 아유', 'ayuchosuu', 'ayuchosuu', 63000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, 550000, NULL, NULL, NULL, '미용기획 주식회사', '[부가설명] [260114 라인 회신 ]', 'available', false, true),
(gen_random_uuid(), '아야노다가네', 'ayanodagane32', 'ayanodagane', 71000, 'ayanodagane32', 1200000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'WOW', NULL, '[부가설명] 1. 인스타 : 릴스 350,000엔 / 피드 150,000엔
2. 틱톡 : 800,000엔
3 오프라인 : ¥300,000＋출장비 (ASK)', 'available', false, true),
(gen_random_uuid(), '모리 니나', 'ninazaballa', 'ninazaballa', 23000, NULL, NULL, 'ninamori1160', 180000, NULL, NULL, 'base', 'beauty', 'micro', NULL, 50600, NULL, 37950, NULL, 'JFUN', 'meilly', '[부가설명] [250617/메일회신]s.mori@meilly.jp
 릴스 : 상담후 결정 / 피드 50,600엔 / 스토리 37,950엔 ~
각겨 표 PDF 있음 (일본어)
file:///C:/Users/JFUN/Desktop/%E3%80%902025.07.01-09.30%E3%80%91Meilly_%EC%9D%B8%ED%94%8C%EB%A3%A8%EC%96%B8%EC%84%9C%20%EA%B0%80%EA%B2%A9%20%EB%B0%8F%20%EC%86%8C%EA%B0%9C.pdf', 'available', false, true),
(gen_random_uuid(), '비비쨩', 'bibichan__cosme', 'bibichan__cosme', 24000, 'bibichan_cosme', 271590, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, 100000, 20000, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
릴스 10만엔 (2차사용 1달 5만엔) / 피드 5만엔 / 스토리 2만엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '피부루틴쨩', 'bihadanaritaina', 'bihadanaritaina', 17850, 'bihadanaritaina', 97350, 'bihadanaritaina', 45500, NULL, NULL, 'base', 'beauty', 'micro', NULL, 50000, 100000, 20000, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
릴스 10만엔 (2차사용 1달 5만엔) / 피드 5만엔 / 스토리 2만엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '코스메괴수쨩', 'cosme_kaiju', 'cosme_kaiju', 22679, 'cosme_kaiju', 116300, 'cosme_kaiju', 39200, NULL, NULL, 'color', 'beauty', 'micro', NULL, 50000, 100000, 20000, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
릴스 10만엔 (2차사용 1달 5만엔) / 피드 5만엔 / 스토리 2만엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '코스메 이야기 클럽', NULL, NULL, NULL, 'cosme_katari.club', 130700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 200,000엔 / 2차활동 1개월 50,000엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '모모소라', NULL, NULL, NULL, 'cosme_daisuki.kaigi', 238700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 400,000엔 / 2차활동 1개월 75,000엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '뷰티탐정쨩', NULL, NULL, NULL, 'tantei_cosme', 145400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 250000, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 250,000엔 / 2차활동 1개월 50,000엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '성분오타쿠쨩', NULL, NULL, NULL, 'seibun_otakuchan', 379100, NULL, NULL, NULL, NULL, 'base', 'beauty', 'mega', 300000, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 300,000엔 / 2차활동 1개월 87,500엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '한국언니', NULL, NULL, NULL, 'choa_cosme', 117600, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 250000, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 250,000엔 / 2차활동 1개월 75,000엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '돌격쨩', NULL, NULL, NULL, 'totsugeki_cosme', 106060, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 200000, NULL, NULL, NULL, NULL, 'JFUN', 'nadesiko', '[부가설명] [250616/메일회신]contact@hadoinc.com  /  s.yoshitani@hadoinc.com
틱톡 200,000엔 / 2차활동 1개월 50,000엔

아래는 nadesiko 소속사분들의 가격 리스트
https://docs.google.com/spreadsheets/d/1v-svb03logwLEz29l6b-u_W2fmFbTx53/edit?gid=370263798#gid=370263798', 'available', false, true),
(gen_random_uuid(), '하루노 에미리', 'emiri0101_', 'emiri0101_', 113000, 'emiri0101_', 53100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미쿠폰', '___ponmk2___', '___ponmk2___', 101000, 'ponmkdayo2', 64400, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '사야카', 'sayaka112009', 'sayaka112009', 238000, 'sayaka112009', 42500, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '하마사키 츠바사', 'tsubasa_hamasaki', 'tsubasa_hamasaki', 69000, 'tsubasah2', 33800, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미무라 아미', 'mimura.ami', 'mimura.ami', 122000, 'mimura.ami', 4617, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미즈키', 'mizukichandesuyo', 'mizukichandesuyo', 72000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '히로나', 'hirona0523', 'hirona0523', 78000, 'hirona0523', 30900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '나카히라 마이', 'im_5868', 'im_5868', 121000, 'im_5868', 3479, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '스이 스즈', 'osuzudashi_', 'osuzudashi_', 126000, 'osuzudashi_', 38700, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미용중과금 라이타', 'raita_miyu', 'raita_miyu', 64000, 'rairai_biyou', 6330, 'raita_miyu', 1150, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '라무네', 'ramune_chaaan', 'ramune_chaaan', 18000, NULL, NULL, 'ramune043', 67600, NULL, NULL, 'health', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '오토쿤', 'otokun.kun', 'otokun.kun', 14000, 'otokun__05', 52000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '키호', 'i8.ey_', 'i8.ey_', 38000, 'hrzn512', 169100, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '이시카와 나미키', 'namikidayoo', 'namikidayoo', 403000, 'namikidayo', 2783000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '카호코', 'kaho7911', 'kaho7911', 110000, 'kaho7911', 2920000, 'kaho7911', 2490000, NULL, NULL, 'vlog', 'life', 'middle', 1000000, 150000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- 250818  tag 소속사  아래 리스트 참고 
https://docs.google.com/spreadsheets/d/12TzQwNz-7NMU1RiWCuv7XZ4eVehJNSpus8XdMdxRjh4/edit?gid=1284291624#gid=1284291624', 'available', false, true),
(gen_random_uuid(), '히카린조', 'hkr7140', 'hkr7140', 195000, 'hkr7140', 1000000, 'hkr7140', 163000, NULL, NULL, 'vlog', 'life', 'middle', 1000000, 250000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- 250818  tag 소속사  아래 리스트 참고 
https://docs.google.com/spreadsheets/d/12TzQwNz-7NMU1RiWCuv7XZ4eVehJNSpus8XdMdxRjh4/edit?gid=1284291624#gid=1284291624', 'available', false, true),
(gen_random_uuid(), '치바호구와즈', 'minato_aidenden', 'minato_aidenden', 132000, 'harrytickerkun', 588700, NULL, NULL, NULL, NULL, 'tech', 'other', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '에라미', 'erami___gram', 'erami___gram', 44000, 'erami_331', 442600, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 650000, 60000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- 8/18 tag 소속사  아래 리스트 참고 
https://docs.google.com/spreadsheets/d/12TzQwNz-7NMU1RiWCuv7XZ4eVehJNSpus8XdMdxRjh4/edit?gid=1284291624#gid=1284291624', 'available', false, true),
(gen_random_uuid(), '나나린린', '7ri__n', '7ri__n', 11000, 'taberu.nanarin', 56900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '로이', 'royroy_666', 'royroy_666', 345000, 'royroy_666', 1200000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, 1000000, 500000, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 소속사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

[250709 신지상회신]   아리얼, 아렌시아 오리엔시트 확인 후 판단하기 
릴스 100만엔  / 스토리 50만엔', 'available', false, true),
(gen_random_uuid(), '아이난', 'iamaina1026', 'iamaina1026', 140000, 'iamainan', 461100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), 'Someone 카엔', '15_82en', '15_82en', 33000, 'uha00', 138800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '리노', '__ri.n0.22', '__ri.n0.22', 23000, 'rinocha2', 248300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '세이노 류하', 'ryuha_10s', 'ryuha_10s', 179000, 'countryside7777', 937400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '마호', 'm19_peach', 'm19_peach', 42000, 'm19_peach', 253700, 'm19_peach', 5560, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '하나', 'yamamotohana_', 'yamamotohana_', 91000, 'hanadeikiteru', 523600, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '샤논', '__syn.n', '__syn.n', 28000, 'syanchandayo', 222000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '노리 리토휜', 'nori.nori945', 'nori.nori945', 179000, 'litofin1231', 224000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '아스피 갸루모델 사장', 'asuka__0928', 'asuka__0928', 53000, 'asuka_popgirls', 286700, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '마루모 모모카', 'moga3marumo', 'moga3marumo', 17000, 'marumo666', 146500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '코토짱', 'i__am.5108', 'i__am.5108', 50000, 'kottto13', 672000, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '로루도루', 'rorudoll', 'rorudoll', 37000, 'rorudoll', 82000, 'rorudoll', 17100, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '오구시 미쿠', 'miku.ogushi', 'miku.ogushi', 116000, 'miku.ogushi', 113800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미루쿠티', '2002_151', '2002_151', 19000, '2002_151', 193500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '비서 한나', 'hanna_dayo14', 'hanna_dayo14', 38000, 'hanna_dayo14', 82900, 'hanna_dayo14', 10400, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '노조미', 'n_b2is', 'n_b2is', 77000, 'n_b2is', 258700, 'n_b2is', 33200, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미사키', 'misaki_haaan', 'misaki_haaan', 121000, 'misaki_haaan', 534800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '사야폰', 'sayapon_310', 'sayapon_310', 137000, 'sayapon_hs', 89800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '리사뽕', 'pink_r_918', 'pink_r_918', 118000, 'pink_r_918', 652400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '미츠짱', 'matu_chan_official', 'matu_chan_official', 26000, 'matu_chan_official', 443000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '마유', '_924o87', '_924o87', 11000, '_924o87', 212400, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '세키 사쿠라', 'ssakura0212', 'ssakura0212', 152000, '_s.s_0212', 361800, 'ssakura0212', 7970, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), 'R짱  메스메덕후', 'r___cosme2021', 'r___cosme2021', 26000, 'r___cosme2021', 147000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), 'yuuka akagi', 'yuuukaa1015', 'yuuukaa1015', 28000, 'yuukaakagi1015', 70500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '유리탄', 'heterodoxxy', 'heterodoxxy', 48000, 'heterodoxxy', 88100, 'heterodoxxy', 1030, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '마나피오', '_manatakeuchi_', '_manatakeuchi_', 30000, 'manappio', 115700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '아사히나 리오나', 'asahina_riona', 'asahina_riona', 121000, 'asahina_riona', 124000, 'asahina_riona', 48300, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '아야세 리에', 'ayase1013rie', 'ayase1013rie', 221000, 'ayase1013rie', 459100, 'ayase1013rie', 36300, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '안', 'an____dayo', 'an____dayo', 47000, 'an____dayo', 103300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'nukta', '[부가설명] [250616/라인회신] nukta 캐스팅회사 
팔로워 x 1.5 엔 정도 희망 나머지는 브랜드사 및 예상에 따라 먼저 제안을 원하십니다. 상의가능 

--- jfun 신지상 쪽에서 직접 컨텍해보는게 빠를 수도 있습니다.', 'available', false, true),
(gen_random_uuid(), '오노 게이토', 'kx0lx8', 'kx0lx8', 29000, 'keity_daily', 26800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] info@s2model.com', 'available', false, true),
(gen_random_uuid(), '유이카', 'yu.i.k.a', 'yu.i.k.a', 79000, 'yuikakusan', 5617, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '코노나', NULL, '[부가설명] 릴스 + 스토리 1건 = 6만엔', 'available', false, true),
(gen_random_uuid(), '키라라', 'kinkinkin00', 'kinkinkin00', 108000, 'mitugonotamago', 167400, 'kinkinkin00', 3820, NULL, NULL, 'color', 'beauty', 'middle', 400000, 330000, 370000, 300000, NULL, 'JFUN', 'libertytown', '[부가설명] sales@libertytown.co.jp  [250923 소속사 라인]

TikTok 1건 게시: 40만 엔 (비과세)
릴스 게시(1건): 37만 엔 (비과세)
피드 게시(1건): 33만 엔 (비과세)
스토리 1건 게시: 30만 엔 (비과세)', 'available', false, true),
(gen_random_uuid(), '아카리', 'aoo____ao', 'aoo____ao', 180000, 'aoo____ao', 87600, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 220000, 500000, 550000, 450000, NULL, 'JFUN', 'libertytown', '[부가설명] sales@libertytown.co.jp [250923 소속사 라인]
TikTok 1건 게시: 22만 엔 (비과세)
릴스 게시(1건): 55만 엔 (비과세)
피드 게시(1건): 50만 엔 (비과세)
스토리 1건 게시: 45만 엔 (비과세)', 'available', false, true),
(gen_random_uuid(), '마루', 'honkidasumaru', 'honkidasumaru', 465000, 'honkidasumaru', 31700, 'honkidasumaru', 103000, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '코노나', NULL, '[부가설명] [ 250714 코노나회신]  레버브 투어 진행예정 

[250811/신지상]
피드 투고: ¥699,000
릴스 투고: ¥932,000', 'available', false, true),
(gen_random_uuid(), '유리린', 'yuririn24posi.mama', 'yuririn24posi.mama', 116000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, 350000, NULL, NULL, '코노나', NULL, '[부가설명] [ 250714 코노나회신]  레버브 투어 진행예정 

본인 포트폴리오 및 가격에 대한 자료
https://www.canva.com/design/DAGnktgZWls/BHCWVopg8SHjmhuT2C9qtw/edit

A 플랜 :   릴스 영상 1개  35만엔 
B 플랜 :   릴스 영상 1개 + 스토리 4건 이상 콜라보 25만엔 10%

・2차 사용료: 50,000엔 (세금 별도) / 1개월', 'available', false, true),
(gen_random_uuid(), '오자와 나요', 'ozawanayo', 'ozawanayo', 22000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, '코노나', NULL, '[부가설명] [ 250709 코노나회신] 
고정비 없이  매출쉐어를 높게 콜라보 진행도 좋을 것 같습니다.', 'available', false, true),
(gen_random_uuid(), '지이', 'chii158cm', 'chii158cm', 598000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, 350000, NULL, NULL, '코노나', NULL, '[부가설명] [ 250714 코노나회신]  레버브 투어 진행예정 

① 팔로워 수 × 0.7엔     --> ·릴 투고 × 1   ·릴의 스토리즈 쉐어 = 418,600엔
② 팔로워 수 × 0.8엔  -->> ·릴 투고 × 1    ·릴의 스토리즈 쉐어    ·링크 스토리 5~8장정도  = 478,400엔 
③ 팔로워 수 × 1엔   --->> ·릴 투고 × 1   ·릴의 스토리즈 쉐어   ·링크 스토리 5~8장정도   ·하이라이트에 1개월 고정 = 598,000엔

*** 필로필 사진 사용 가능 (큐텐 상품페이지)', 'available', false, true),
(gen_random_uuid(), '아유무', 'ayumu_takeuchi', 'ayumu_takeuchi', 159000, 'ayumu_takeuchi', 6560, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, 70000, 100000, NULL, NULL, '코노나', NULL, '[부가설명] [250714 코노나회신]  레버브 투어 진행예정  

투어건은 고정비용 없이 성과로 진행 
평소에  릴스 10만엔, 피드 7만엔 
투어 진행시 릴스 5만엔, 피드 4만엔', 'available', false, true),
(gen_random_uuid(), '노아', 'diet_nooa', 'diet_nooa', 470000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미야가와 마야(마야)', 'maya_m0901', 'maya_m0901', 353000, 'maya_m0901', 103900, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '이시이 리나', 'ri7tin1025', 'ri7tin1025', 344000, 'ri7tin1025', 1900, 'ri7tin1025', 4550, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '트레 피나', 'pina.diet', 'pina.diet', 315000, 'pina.diet', 511400, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '히카루', 'hikaru_workout', 'hikaru_workout', 273000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미이', 'dietvlog_miii160cm', 'dietvlog_miii160cm', 221000, 'dietvlog_miii160cm', 109000, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, 200000, NULL, NULL, '신지상', NULL, '[부가설명] 251203 라인 회신
릴스 1건 20만엔', 'available', false, true),
(gen_random_uuid(), '나루미 유', 'debumi_yuu_diet', 'debumi_yuu_diet', 183000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥274,500
릴스 투고: ¥366,000', 'available', false, true),
(gen_random_uuid(), 'SHIRI', 'shiri_diet', 'shiri_diet', 164000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥246,000
릴스 투고: ¥328,000', 'available', false, true),
(gen_random_uuid(), 'mao', 'mao_recipe', 'mao_recipe', 160000, NULL, NULL, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥240,000
릴스 투고: ¥320,000', 'available', false, true),
(gen_random_uuid(), '𝙆𝙞𝙠𝙞', 'kiki_diet_training', 'kiki_diet_training', 140000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, 210000, 280000, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥210,000
릴스 투고: ¥280,000', 'available', false, true),
(gen_random_uuid(), '아야', 'aya_92bodymake', 'aya_92bodymake', 127000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아사나', 'asana_diet', 'asana_diet', 114000, 'asana_diet', 25100, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥171,000
릴스 투고: ¥228,000', 'available', false, true),
(gen_random_uuid(), '페쉐코', 'pe.diet2', 'pe.diet2', 102000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'Hanon Tomino', 'hanon._.sunny', 'hanon._.sunny', 94000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오카나 트레이너', 'i_am_kyana', 'i_am_kyana', 76000, 'i_am_kyana', 25700, 'i_am_kyana', 38800, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모 짱', 'momo_diet_2021', 'momo_diet_2021', 75000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나짱', 'natsu_diet97', 'natsu_diet97', 54000, 'natsu_diet97', 20700, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '이시다 에리카', 'dinette_inc', 'dinette_inc', 343000, 'dinette_inc', 20700, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, 525000, NULL, NULL, NULL, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '미용 괴짜 화장품 · 미용', 'kii_kurashi_', 'kii_kurashi_', 255000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마유', 'otonajoshi_cosme', 'otonajoshi_cosme', 237700, 'otonajoshi_cosme', 3652, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '뷰티 오타쿠
【화장품/스킨케어】', 'brg_magazine', 'brg_magazine', 237000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오시', 'ossy_beautylog', 'ossy_beautylog', 235000, 'ossy_beautylog', 106100, 'ossy_beautylog', 9760, NULL, NULL, 'color', 'beauty', 'middle', NULL, 375000, 525000, NULL, NULL, '신지상', 'Karako', '[부가설명] [250904/순희/카라코상 리스트]
피드 :  ¥375,000
릴스 : ¥525,000', 'available', false, true),
(gen_random_uuid(), '차리코', 'charico2019', 'charico2019', 170000, 'charico2019', 23800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 520000, 675000, NULL, 225000, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '마유미 쿠도', 'ma.yu8980', 'ma.yu8980', 164000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '라라', 'lalamakeup_official', 'lalamakeup_official', 163500, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카와이 아야코', '_ayakokawai_', '_ayakokawai_', 160000, NULL, NULL, '_ayakokawai_', 67500, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '페이스 grow 방법', 'sugarcranz_beauty_health', 'sugarcranz_beauty_health', 159000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [순희: 얼굴 근육 관련 설명]', 'available', false, true),
(gen_random_uuid(), '마리', 'bamli.tokyo', 'bamli.tokyo', 155000, 'bamli.tokyo', 6168, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 234000, NULL, NULL, NULL, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '토모카', 'moka.3o', 'moka.3o', 154900, 'moka.3o', 58300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '우사요시', 'usayoshi_cosme', 'usayoshi_cosme', 146400, 'usayoshi_cosme', 1629, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'Ayana', 'ayana_218', 'ayana_218', 136700, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'OL 찬', 'minamininaritaiol', 'minamininaritaiol', 132000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [순희 : 악세서리, 옷 관련 잡지도 업로드]', 'available', false, true),
(gen_random_uuid(), '아야판', 'ayapan_beauty', 'ayapan_beauty', 130300, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마리 피', 'maripii_cosme', 'maripii_cosme', 126000, 'maripii_cosme', 14700, 'maripii_cosme', 5930, NULL, NULL, 'color', 'beauty', 'middle', NULL, 375000, 525000, NULL, NULL, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '네네', 'nene_cosme_nene', 'nene_cosme_nene', 126000, 'nene_cosme_nene', 33400, 'nene_cosme_nene', 24300, NULL, NULL, 'color', 'beauty', 'middle', NULL, 330000, 450000, NULL, NULL, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '야마구치 나츠미', 'natsumi19910625', 'natsumi19910625', 118300, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '노코', 'noako_cosme', 'noako_cosme', 115000, 'noako_cosme', 148300, 'noako_cosme', 18300, NULL, NULL, 'color', 'beauty', 'middle', NULL, 330000, 480000, NULL, NULL, '신지상', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '부원 와디', 'wada.akane', 'wada.akane', 112000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모', 'fcl_skincare', 'fcl_skincare', 100000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미토', 'mito_makeup', 'mito_makeup', 99500, NULL, NULL, 'mito_makeup', 3800, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에비짱', 'ebichan_nn_n', 'ebichan_nn_n', 94200, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '히코', 'hisako_shindo', 'hisako_shindo', 93000, NULL, NULL, 'hisako_shindo', 14500, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '라나', 'lana__cosme', 'lana__cosme', 92700, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 180000, 225000, NULL, 15000, '신지상', 'Karako', '[부가설명] [250905/순희/카라코리스트]
피드 투고:¥180,000
릴스 투고:¥225,000
2차 활용(1개월): ¥15,000', 'available', false, true),
(gen_random_uuid(), '코할', 'koharun.rooom', 'koharun.rooom', 92200, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, 300000, 330000, NULL, 330000, '신지상', NULL, '[부가설명] [250905/순희/카라코리스트]
피드 투고: ¥300,000
릴스 투고: ¥330,000
2차 활용(1개월): ¥135,000', 'available', false, true),
(gen_random_uuid(), '미미', 'mimi_around_forty', 'mimi_around_forty', 89000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하나', 'hana.cosme33', 'hana.cosme33', 88900, 'hana.cosme33', 1024, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유카', 'yuka_mamabiyou', 'yuka_mamabiyou', 88000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '토마토 촌장', 'tomato4researcher', 'tomato4researcher', 88000, 'tomato4researcher', 2845, 'tomato4researcher', 8830, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '논', 'honeycute01', 'honeycute01', 83500, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'saori', 'saoridayoo', 'saoridayoo', 82000, 'saoridayoo', 2728, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '시라이와 마치코', 'machichas', 'machichas', 79000, 'machichas', 2352, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'hani', 'hani_korea.cosme', 'hani_korea.cosme', 78000, 'hani_korea.cosme', 5035, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '예베짱', 'iebe_chan', 'iebe_chan', 75000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), 'Usamimi', 'usamimi_nail', 'usamimi_nail', 74000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야카', 'ayanekotan', 'ayanekotan', 66000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야미', 'ayami.0624', 'ayami.0624', 60000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '하나', '__cvvz__', '__cvvz__', 59000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '창유카', 'pikachu0827', 'pikachu0827', 59000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아이', 'ao1_beauty', 'ao1_beauty', 58000, 'ao1_beauty', 6788, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '타치바나 유리', 'yuuriofficial', 'yuuriofficial', 50200, NULL, NULL, 'yuuriofficial', 8270, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아사미', 'joshinoasami', 'joshinoasami', 29000, 'joshinoasami', 301800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '와타리', '_wata.a', '_wata.a', 131000, '_wata.a', 1100000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, 200000, 400000, NULL, NULL, '신지상, JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하나사키 쥬리나', 'hanasaki_jurina', 'hanasaki_jurina', 37000, 'hanasaki_jurina', 76000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] ·금액
└ 릴 투고 + 스토리 투고 : 200,000엔
└피드 투고 + 스토리 투고 : 150,000엔

·이차이용비용
1개월간 : +60,000엔
3개월간 : NG', 'available', false, true),
(gen_random_uuid(), '호리 미오나', 'horimiona_official', 'horimiona_official', 586000, NULL, NULL, 'horimiona_official', 191000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 2000000, 2000000, 2000000, NULL, 'JFUN', NULL, '[부가설명] [250806/메일회신] sihoko.kobayashi@amee.fun
◾️릴스 게시물 (1건)　200만 엔
◾️피드 게시물 (1건)　200만 엔
◾️스토리 게시물 (1건~복수)　200만 엔', 'available', false, true),
(gen_random_uuid(), '유미네무', 'ymkghn', 'ymkghn', 71000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, 150000, NULL, NULL, '코노나', NULL, '[부가설명] 코노나님 투어 소개 
릴스 1건 15만엔 정도 
투어시 서오가로 진행', 'available', false, true),
(gen_random_uuid(), '소다 마리에', 'marie_soda_', 'marie_soda_', 112000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, 150000, NULL, NULL, '코노나', NULL, '[부가설명] 코노나님 투어 소개 평상시 릴스 15만엔~ 30만엔

11월21일기준 릴스1+스토리1 20만엔 OK', 'available', false, true),
(gen_random_uuid(), '아오이', 'aoi.biyouhifuka', 'aoi.biyouhifuka', 83000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, 150000, NULL, NULL, '코노나', NULL, '[부가설명] 코노나님 투어 소개  평상시 릴스 15만엔/ 투어는 릴스 1건 5만엔으로 진행', 'available', false, true),
(gen_random_uuid(), '토루', 'gewinteroo', 'gewinteroo', 23000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '미에이', 'miey_bodymake', 'miey_bodymake', 543000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥814,500
릴스 투고: ¥1,086,000', 'available', false, true),
(gen_random_uuid(), '히나치', 'hinach_workout', 'hinach_workout', 462000, 'hinach_0421', 655500, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', 1000000, NULL, 850000, NULL, NULL, '신지상', 'vaz', '[부가설명] [250811/신지상]
피드 투고: ¥693,000
릴스 투고: ¥924,000

[250925 vaz 케스팅]
틱톡 ¥1,000,000		릴스 ¥850,000', 'available', false, true),
(gen_random_uuid(), '사야카', 'sayaka8346', 'sayaka8346', 408000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥612,000
릴스 투고: ¥816,000', 'available', false, true),
(gen_random_uuid(), '미리', 'mirinofficial__', 'mirinofficial__', 365000, 'mirinofficial__', 69200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고:¥547,500
릴스 투고:¥730,000', 'available', false, true),
(gen_random_uuid(), '케이토', 'keito.ohy', 'keito.ohy', 191000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥382,000
릴스 투고: ¥477,500', 'available', false, true),
(gen_random_uuid(), '이야미', 'ayami__room', 'ayami__room', 252000, 'ayami__room', 484100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고:¥378,000
릴스 투고: ¥504,000', 'available', false, true),
(gen_random_uuid(), '센차', 'sen_cha123', 'sen_cha123', 196000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고:¥294,000
릴스 투고: ¥392,000', 'available', false, true),
(gen_random_uuid(), '미사', 'misa.diet', 'misa.diet', 207000, 'misa.diet', 90000, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고:¥310,500
릴스 투고: ¥414,000', 'available', false, true),
(gen_random_uuid(), '나기챠피', 'nagichapi', 'nagichapi', 261000, NULL, NULL, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고:¥391,500
릴스 투고: ¥522,000', 'available', false, true),
(gen_random_uuid(), '카고시마', 'maple_kagoshima', 'maple_kagoshima', NULL, 'maple_kagoshima', 94000, NULL, NULL, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아민산', 'aminsan_diet', 'aminsan_diet', NULL, 'aminsan_diet', 333300, NULL, NULL, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥499,950
릴스 투고: ¥666,600', 'available', false, true),
(gen_random_uuid(), '사야카', 'fujimori_sayaka', 'fujimori_sayaka', NULL, 'fujimori_sayaka', 111300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥166,950
릴스 투고:¥222,600', 'available', false, true),
(gen_random_uuid(), '메자스', 'garigari_mezas', 'garigari_mezas', NULL, NULL, NULL, NULL, NULL, 'garigari_mezas', 133800, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '스이', '97sui_', 'sui_diet_', NULL, NULL, NULL, NULL, NULL, '97sui_', 100700, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리리', 'riri_ch_a', 'riri_ch_a', NULL, NULL, NULL, NULL, NULL, 'riri_ch_a', 95000, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '히요', 'hiyodieter', 'hiyodieter', NULL, NULL, NULL, NULL, NULL, 'hiyodieter', 81400, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '마사모', '__356gram', '__356gram', 103000, '__356gram', 43200, '__356gram', 14400, NULL, NULL, 'health', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, '신지상', NULL, '[부가설명] [250811/신지상]
피드 투고: ¥154,500
릴스 투고: ¥206,000', 'available', false, true),
(gen_random_uuid(), '미이미', 'mibe.27', 'mibe.27', 32000, '313mi', 13900, 'BEYMI27', 568000, NULL, NULL, 'vlog', 'life', 'micro', NULL, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하가타 루나', 'lunachi_0921', 'lunachi_0921', 66000, 'lunachi_0921', 137800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 150000, 80000, 150000, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아논', 'anon0516k', 'anon.official_516', 32000, 'anon0516k', 94800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, 50000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '28소바 (니하치소바)', '28soba_taiko', '28soba_taiko', 21000, '28soba_taiko', 252300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 270000, 30000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유마우미 커플', 'yumaumicouple', 'yumaumicouple', 39000, 'mami__chan_3', 19700, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 220000, 65000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유키나', 'yukina12223', 'yukina12223', 5776, 'yukina12233', 81800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 120000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '사봉', 'sabon_246', 'sabon_246', 42000, 'sabon246', 447900, 'sabon_246', 31800, NULL, NULL, 'color', 'beauty', 'micro', 600000, 55000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아야노', 'moriko0120', 'moriko0120', 47000, 'moriko0120', 93400, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 130000, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '디에라', 'indopangallery', 'indopangallery', 1275, 'indopangallery', 45000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 70000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '디에라 나타니아', 'dieranathania', 'dieranathania', 251000, 'dieranathania', 1900000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 250000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '츠무', 'tsuuum3', 'tsuuuuum3', 3875, 'tsuuum3', 63900, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '류야', 'ryuu_uuya_1', 'ryuu_uuya_1', 4217, 'ryuu_uuya', 49400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 100000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아야세 치이', 'ayase_chii', 'ayase_chii', 15000, 'torotorotoront', 31200, 'ayase_chii', 128000, NULL, NULL, 'color', 'beauty', 'micro', 60000, NULL, 66000, NULL, NULL, 'JFUN', 'tag', '[부가설명] [ 260119 신지상 컨텍 ] 
피드: 30,000엔
스토리 : 20,000엔
릴 : 66,000엔
※ 피드, 스토리의 단독 판매는 없음
TikTok 66,000엔
2차 이용 30,000엔/1개월', 'available', false, true),
(gen_random_uuid(), '모쵸', 'moo_ch0', 'moo_ch0', 2007, 'mocho_desu', 26100, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 50000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카시이 야스코', 'yasuko_kashii', 'yasuko_kashii', 16000, 'yasuko_kashii', 13300, 'yasuko_kashii', 3120, NULL, NULL, 'fashion', 'fashion', 'micro', 20000, 30000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '슈니', 'shuni._.monologue', 'shuni._.monologue', 2360, 'shuni._.monologue', 12800, NULL, NULL, NULL, NULL, 'health', 'life', 'micro', 25000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세이세이', 'seir_aw', 'seir_aw', 31, 'seiraaa50', 10900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 20000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유찬', 'youwie0618', 'youwie0618', 3168, 'yuuchan0618', 29400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 35000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '소와소와 커플', 'nomalperson_106', 'nomalperson_106', 1084, 'nomalperson__106', 19100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 35000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '케다마짱', 'kedama_chan00', 'kedama_chan00', 1343, 'kedamachan_dayo', 3505, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '에노', 'enowa_otaku', 'enowa_otaku', 20000, 'enowa_otaku', 13300, 'enowa_otaku', 15300, NULL, NULL, 'tech', 'other', 'micro', 30000, 40000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '스테파니', 'li_ks18', 'li_ks18', 8652, 'li_sk18', 3730, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '모모텐', 'momonoten', 'momonoten', 9087, 'momonoten', 8672, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카이토', 'bo.bbbby', 'bo.bbbby', 3067, 'bo.bbbby', 1527, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아챠모', 'achamo_4', 'achamo_4', 1471, 'achamo_4', 4194, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 15000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우누보레쿤', 'matsu_rrrr', 'matsu_rrrr', 1329, 'unubore1102', 48800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 35000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '라나', 'rana.0509', 'rana.0509', 183000, '_rana_0509', 109600, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 150000, 250000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '오무리호', 'omukorosutton', 'omukorosutton', 2293, 'omurihoyuu', 325900, 'omukorosutton', 33400, NULL, NULL, 'vlog', 'life', 'mega', 330000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세렌', 'milkpan_1215', 'milkpan_1215', 6382, 'milkpan_1215', 113400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 150000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '초키쿠짱', 'kikuland', 'kikuland', 2053, '_kikuland_', 43600, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 80000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '랏짱', 'ao_rana_days_', 'ao_rana_days_', 748, 'ao_rana_127xxx', 25000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 40000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아야노', 'ayano_27_', 'ayano_27_', 119000, 'ryuyano_', 1300000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 800000, 130000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '미루멘 커플', 'milmen9396', 'milmen9396', 37000, 'milmen_9396', 290500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 350000, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카누', 'unick_99', 'unick_99', 114000, 'kam9908', 467900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 550000, 120000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '구가', 'guga9791', 'guga9791', 2379, 'guga9791', 110800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 165000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '센쨩', 'stayathomemom93', 'stayathomemom93', 931, 'stayathomemom93', 52600, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '소마', '03sooma__', '03sooma__', 1334, 'souma5687', 19800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 25000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '레오나', '_rreonaa_', '_rreonaa_', 18000, '_rreonaa_', 37500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 100000, 25000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '사쿠리타', 'ryota.sakura', 'ryota.sakura', NULL, 'ryota.sakura', 87900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '김이오하우스', 'k1mu_1o', 'k1mu_1o', 121000, 'k1mu_1o', 361900, 'k1mu_1o', 187000, NULL, NULL, 'vlog', 'life', 'middle', 430000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '모쵸페', 'mochopeeeeee', 'mochopeeeeee', 79000, 'y_k_060124', 559600, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 630000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쇼짱', '_shochan0611', '_shochan0611', 29000, '_shochan0611', 80400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유리', '0906yurin', '0906yurin', 412000, '0906yu_rin', 6800000, '0906yurin', 3000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 430000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '와타나베 나나', 'watanana1225', 'watanana1225', 50000, 'watanana1225', 43600, 'watanana1225', 5570, 'watanana1225', 28000, 'vlog', 'life', 'middle', 70000, 80000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '키쿠치 사쿠라', '_01.39_', '_01.39_', 93000, '_01.39_', 136900, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 300000, 150000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '재스민티', 'jas_mi__2212', 'jas_mi__2212', 7389, 'jas_mi__2221', 23000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠도 레노', 're_ino12', 're_ino12', 67000, 're_ino12', 386900, NULL, NULL, 're_ino12', 179, 'fashion', 'fashion', 'middle', 400000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '마오', 'mao___0122', 'mao___0122', 4194, 'mao___0122', 18900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 30000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하야카와 리쿠', 'rikuuuuu_hayakawa', 'rikuuuuu_hayakawa', 15000, 'rikuuuuu_hayakawa', 81800, 'rikuuuuu_hayakawa', 5970, NULL, NULL, 'vlog', 'life', 'micro', 100000, 30000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유이마루', 'i.yuiko0908', '石田 夢音子 (いしだ ゆいこ) (@i.yuiko0908) • Instagram photos and videos', 7303, 'i.yuiko0908', 271700, NULL, NULL, 'yuiko_ishida', 3336, 'vlog', 'life', 'middle', 450000, 20000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '시타마치 아오', 'ao_shitamachi', 'ao_shitamachi', 1440, 'ao_shitamachi', 89700, NULL, NULL, 'ao_shitamachi', 2465, 'vlog', 'life', 'middle', 170000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '키타노 마이', 'mai.5671', 'mai.5671', 19000, 'ma_i26', 202300, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 250000, 30000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '네코다 레나', 'renya_san07', 'renya_san07', 3961, 'renya_san07', 161500, NULL, NULL, 'renya_san07', 6542, 'vlog', 'life', 'middle', 200000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '야마자키 코코로', 'koko__heart', 'koko__heart', 51000, 'koko__heart', 123800, NULL, NULL, 'koko__0226', 10600, 'fashion', 'fashion', 'middle', 170000, 85000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [251104/라이즈어 소속사/순희]
틱톡: ¥150,000
릴스:¥150,000
피드: ¥61,000
스토리: ¥51,000', 'available', false, true),
(gen_random_uuid(), '소노다 노아', 'noaaa327_', 'noaaa327_', 71000, 'noaaa327_', 171800, NULL, NULL, 'noaaa327_', 13400, 'kidsmom', 'life', 'middle', 230000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '히카하루', 'hikaharu0311', 'hikaharu0311', 59000, 'hikaharu0311', 338800, NULL, NULL, '0311hikaharu', 32800, 'vlog', 'life', 'middle', 400000, 95000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [251104/라이즈어 소속사/순희]
틱톡: ¥240,000
릴스: ¥150,000
피드: ¥70,000
스토리: ¥59,000', 'available', false, true),
(gen_random_uuid(), '반다리 아사야', 'asaya.0223', 'asaya.0223', 170000, 'asaya0223', 448600, NULL, NULL, 'asaya_0223', 195, 'fashion', 'fashion', 'middle', 600000, 260000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '이와타 마아리', 'iwatamaari', 'iwatamaari', 27000, 'iwatamaari', 683900, 'iwatamaari', 155000, 'iwatamaari', 7191, 'vlog', 'life', 'micro', 700000, 35000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '신토 마리', 'mari0121_', 'mari0121_', 249000, 'mari_0121', 476600, 'mari0121_', 183000, 'mari0121_', 32600, 'color', 'beauty', 'middle', 600000, 350000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아마미야 유오카', '_pinkbunnygirl_', '_pinkbunnygirl_', 149000, 'yuzuha_amemiya', 286900, NULL, NULL, 'yuzuha_amemiya', 73900, 'fashion', 'fashion', 'middle', 350000, 200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아마미야 미이', '__milky_berry__', '__milky_berry__', 54000, '_.milkyberry._', 151200, NULL, NULL, '_milkyyberry_', 10800, 'health', 'life', 'middle', 230000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세이나', 'seinaaa_0318', 'seinaaa_0318', 462000, 'seina3333', 458700, NULL, NULL, 'seinaaa318', 139100, 'fashion', 'fashion', 'mega', 550000, 500000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유우챠미', 'chamitan_0908', 'chamitan_0908', 479000, 'chamitan_09082424', 1000000, 'chamitan_0908', 134000, 'yuuna09082424_', 184800, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '리세리', 'rsr_0717', 'rsr_0717', 87000, 'rsr_0717', 480600, NULL, NULL, 'rsr_0717', NULL, 'fashion', 'fashion', 'middle', 550000, 130000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유이챠미', 'yui628', 'yui628', 119000, 'yui.081', 193300, NULL, NULL, 'Ex240130', 30300, 'fashion', 'fashion', 'middle', 250000, 150000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '키이리푸', 'kyiiripu.friedegg', 'kyiiripu.friedegg', 165000, 'kiiiriypu', 180100, NULL, NULL, '9_6_0807kisu', 87400, 'color', 'beauty', 'middle', 230000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세토 모모아', 'momoa.seto', 'momoa.seto', 173000, 'momoa_1130', 441200, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 500000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아이미', 'aichipo07', 'aichipo07', 104000, 'aichipo7', 74400, 'aichipo07', 4020, 'Aichipo07', 37100, 'fashion', 'fashion', 'middle', 100000, 125000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '레이타피', '_reistagram._', '_reistagram._', 169000, 'reitapi_17', 394800, 'reitapi', 130000, 'koma_san17', 110800, 'color', 'beauty', 'middle', 430000, 200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '이토 메이미', 'aimi___1227', 'aimi___1227', 149000, 'aimin_1227', 416600, NULL, NULL, 'aimi_no04', 14500, 'fashion', 'fashion', 'middle', 550000, 200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '미리챰', 'mirichamu_0710', 'mirichamu_0710', 212000, 'mirichamuu_0710.34', 234200, 'UCx0rJPnTiM2YErF3wJung5A', 188000, 'mirichamuu_0710', 112500, 'fashion', 'fashion', 'middle', 300000, 250000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '리아나', 'im_rianaaa93', 'im_rianaaa93', 58000, 'ria_xx7', 108800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 130000, 70000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아오폰', 'aopon0528', 'aopon0528', 99000, '0528_aoi', 50000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 70000, 130000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '에리카', 'iametann', 'iametann', 64000, 'luvluvry', 90000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 120000, 75000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아이메로', 'aisyu0101', 'aisyu0101', 48000, 'aisyu_0101', 61100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 90000, 65000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '네온', '__neo23n', '__neo23n', 59000, 'nnn1o23', 67500, NULL, NULL, 'neo23n', 4535, 'fashion', 'fashion', 'middle', 80000, 70000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세이라', 'seichan134', 'seichan134', 52000, 'seichan134', 47600, NULL, NULL, 'seichan134', 2137, 'fashion', 'fashion', 'middle', 65000, 65000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아이리', 'a12dance07', 'a12dance07', 45000, 'airi_dancer1', 54400, 'UC2oEwy95JYxyABdDRq3j9sg', 4430, 'BB_sg1t2v0d7_A', 10500, 'vlog', 'life', 'micro', 65000, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '마나페코', 'ma__mi.82', 'ma__mi.82', 52000, 'ma__mi.99', 66400, NULL, NULL, 'mana02130', 3342, 'color', 'beauty', 'middle', 80000, 70000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쥬나', 'junnadayoo', 'junnadayoo', 286000, 'jun1515', 1700000, 'じゅんなJUNNA', 36800, 'junnadayoo', 100400, 'fashion', 'fashion', 'middle', 1850000, 350000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유우나', 'unaunayuuna', 'unaunayuuna', 241000, 'unaunayuuna', 1500000, 'UClNlFFqQFz6QBUnDB303XsQ', 153000, 'yunaunauna', 86100, 'vlog', 'life', 'middle', 1600000, 320000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우나', '0314una', '0314una', 81000, 'unanico25', 710200, '0314una', 30900, 'unanico25', 6711, 'vlog', 'life', 'middle', 780000, 150000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠루스 루나', 'moon_kurusu', 'moon_kurusu', 107000, 'kurusu_moon', 327100, 'UCUnWn_6kphjZnoz9tS5EPWg', 140000, 'moon_kurusu', 42300, 'color', 'beauty', 'middle', 400000, 170000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '마호', 'bibilab1011', 'bibilab1011', 59000, 'bibilab1011', 656000, NULL, NULL, 'bibilab1011', 23500, 'fashion', 'fashion', 'middle', 680000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우사', 'usa_usa0427', 'usa_usa0427', 275000, 'usa_usa0427', 503600, NULL, NULL, 'usa_usa0427', 174500, 'fashion', 'fashion', 'middle', 500000, 305000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '히메노 히나노', 'pi._.y', 'pi._.y', 32500, 'hinanon11', 756500, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 800000, 320000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아유우', 'ayuuu.jp', 'ayuuu.jp', 20000, 'ayuuu.jp', 238800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 260000, 30000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '마스다 아야노', 'm_ayano26', 'm_ayano26', 518000, 'm_ayano26', 677600, NULL, NULL, 'ayano_cs0526', 203400, 'fashion', 'fashion', 'mega', 850000, 800000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '오구니 마우', 'mau124.luv', 'mau124.luv', 263000, 'mau124.luv', 519000, NULL, NULL, 'mau124_luv', 28100, 'fashion', 'fashion', 'middle', 650000, 320000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '무라타니 하루나', '_haruchi.05', '_haruchi.05', 367000, 'llun_377', 430000, NULL, NULL, 'haru_jk07', 19900, 'fashion', 'fashion', 'mega', 480000, 450000, 900000, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠로에 코하루', 'koharun_0586_', 'koharun_0586_', 109000, 'koharun_0586_', 167700, NULL, NULL, 'koharun_0586_', 34400, 'fashion', 'fashion', 'middle', 300000, 184500, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '나카자토 마야토', 'my_002', 'my_002', 57000, 'myt002_', 1500000, 'UCHKiTnUG7IU3w-a70xtgplQ', 14700, '0922mayato', 13200, 'fashion', 'fashion', 'middle', 2300000, 90000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '미노미야 스즈', 'suzuchan.1', 'suzuchan.1', 108000, 'suzu.sannomiya', 187500, 'suzuchan.1', 92200, 'suzuchan0517', 68500, 'vlog', 'life', 'middle', 210000, 120000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '미시마 케이시', 'keishi__mishima', 'keishi__mishima', 68000, 'keishi__japan', 123200, '三島啓史-n3k', NULL, 'keishi_m0912', 14400, 'fashion', 'fashion', 'middle', 150000, 88800, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카스야 네오', 'non.1611', 'non.1611', 63000, 'non0312312', 95800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 130000, 76800, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '시미즈 아스카', 'asu_asu_51000', 'asu_asu_51000', 76000, 'asu_asu_510', 127600, NULL, NULL, 'asu_asu_510', 15600, 'fashion', 'fashion', 'middle', 150000, 90000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유안', 'yu_2006_1103', 'yu_2006_1103', 25000, 'jkmisukonyuan', 129600, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 230000, 44400, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '안나얀', 'anna__gram0718', 'anna__gram0718', 21000, 'anna_chan718', 313100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 500000, 25000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '니시 아야노', 'achan___15', 'achan___15', 146000, 'ayapo_0815', 411400, NULL, NULL, 'ayapo__15', 43400, 'fashion', 'fashion', 'middle', 480000, 220000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '무카이 아이마루', 'natamaru041', 'natamaru041', 160000, 'natamaru041', 318500, 'natamaru041', 2400, 'natamaru041', 109000, 'vlog', 'life', 'middle', 450000, 250000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '이시카와 카린', 'karen__i328', 'karen__i328', 280000, 'karen__i328', 574200, 'karen__i328', 74300, 'karen__i328', 142300, 'fashion', 'fashion', 'middle', 750000, 400000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '에비노 코코로', 'heart_u29', 'heart_u29', 70000, 'heart_u29', 107300, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 160000, 105000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '이시카와 스즈카', 'suzuka__0510', 'suzuka__0510', 85000, 'suzuka510', 132200, NULL, NULL, 'suzuka_0510_', NULL, 'fashion', 'fashion', 'middle', 190000, 130000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '안자이 세이라', 'seiraanzai', 'seiraanzai', 261000, 'seiraanzai', 298000, NULL, NULL, 'seiraanzai', 45200, 'fashion', 'fashion', 'middle', 380000, 280000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하야카와 루카', 'ru_4519', 'ru_4519', 52000, 'ru_0419', 229500, NULL, NULL, 'ruka15321', 21400, 'fashion', 'fashion', 'middle', 270000, 80000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '코하마 모모나', 'momona_kohama', 'momona_kohama', 203000, 'kohama._.7', 207600, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 270000, 240000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '탄다 하즈키', 'tandahazuki_', 'tandahazuki_', 99000, 'tandachan_28', 218400, 'UCOLL3KDzhqu-CQ_uXZUQ7XA', 32800, 'tanda_hazuki', 173400, 'vlog', 'life', 'middle', 250000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '타마키 유우유', 'yuuyu_114', 'yuuyu_114', 26000, 'yuuyu_114', 158800, NULL, NULL, 'yuuyu_114', 17300, 'vlog', 'life', 'micro', 195000, 35000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '타테누마 유이', 'tadeyui', 'tadeyui', 100000, 'tadeyui', 259100, NULL, NULL, 'tadeyui', 31600, 'vlog', 'life', 'middle', 260000, 110000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '타카츠루 모모하', 'momoha2003523', 'momoha2003523', 68000, 'sweets_suki3', 169300, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 180000, 90000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '오오츠카 미나미', 'mi7mi12_', 'mi7mi12_', 37000, 'red_mi7', 108800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 145000, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '오오츠카 모에카', 'moka_otsuka', 'moka_otsuka', 43000, 'moka.otsuka', 133100, NULL, NULL, 'moka_otsuka', 11000, 'fashion', 'fashion', 'micro', 170000, 65000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아이자와 나츠키', 'aizawa_natsuki_', 'aizawa_natsuki_', 69000, 'aizawa_natsuki', 96800, NULL, NULL, 'aizawa_natsuki', 24100, 'fashion', 'fashion', 'middle', 130000, 105000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠로사키', 'kurosaki0516', 'kurosaki0516', 400000, 'nanako.kurosaki', 549200, NULL, NULL, '0516_nanako', 180600, 'fashion', 'fashion', 'mega', 570000, 410000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '피노짱', 'pinopino.403', 'pinopino.403', 4948, 'pinopino403', 88200, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 100000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아즈키 아리사', 'azuki_arisa', 'azuki_arisa', 25000, 'azuki_arisa', 80400, 'azuki_arisa', 15700, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아키라 후타바', 'ftb_2x28', 'ftb_2x28', 69000, 'ftb_2', 336900, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 600000, 120000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유리나', 'yu_rina07', 'yu_rina07', 148000, 'yu_rina3925', 270800, NULL, NULL, 'y_rina0', 5532, 'color', 'beauty', 'middle', 370000, 240000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠보 노노카', 'kubononoka__gram', 'kubononoka__gram', 73000, 'kubononoka_offi', 247900, NULL, NULL, 'kubononoka_offi', 22300, 'fashion', 'fashion', 'middle', 470000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카와미치 사라', 'hunny_214', 'hunny_214', 377000, 'hunny_214', 64400, 'UCxuhL_-415_1xbz9PbxrbhQ', NULL, 'hunny_214', 247100, 'fashion', 'fashion', 'mega', NULL, 360000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '후쿠다 이치카', 'f_ichika', 'f_ichika', 21000, 'f.ichika_', 83900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 180000, 70000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '사란 (사라)', 'saracchidayo', 'saracchidayo', 251000, 'saracchidayo1129', 15400, NULL, NULL, 'saracchidayo', 173500, 'fashion', 'fashion', 'middle', 60000, 385000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '밈', 'mim_11_11', 'mim_11_11', 140000, 'mimchansan', 24000, NULL, NULL, 'mim_11_11', 147000, 'fashion', 'fashion', 'middle', 60000, 270000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '맘 (마무)', 'mam_11_11', 'mam_11_11', 91000, 'mam_11_11', 52400, 'mamirie', 500, 'mam_11_11', 125100, 'tech', 'other', 'middle', 130000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '후우카', 'p_p_pukka', 'p_p_pukka', 109000, 'p_p_pukka', 484800, 'p_p_pukka', 6580, 'p_p_pukka', 18900, 'tech', 'other', 'middle', 750000, 200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '야가미 케이지로', 'keijiro_yagami_official', 'keijiro_yagami_official', 19000, 'keijiro_yagami_official', 373900, NULL, NULL, 'keijiro_yagami', 4070, 'fashion', 'fashion', 'micro', 600000, 80000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '나카마치 아야', 'ayanakamachi', 'ayanakamachi', 1379000, 'ayanakamachi', 1700000, 'NakamachiAya', 1610000, 'aya110n_n', 365400, 'vlog', 'life', 'mega', 2500000, 2200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '나카마치 JP', 'demichenakamachi', 'demichenakamachi', 422000, 'demichenakamachi', 578600, 'UCp7GNebwQ2z8coZ4wV5_Eiw', 1610000, 'demichenakamach', 165000, 'vlog', 'life', 'mega', 900000, 900000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '아리샨', 'arishan.3', 'arishan.3', 384000, 'hera3_arishan', 96400, 'hera3.arishan', 193000, 'arishan_hera3', 172700, 'vlog', 'life', 'mega', 300000, 650000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '노리반', 'noriban_dayo', 'noriban_dayo', 11000, 'noribandayo', 10500, 'UCNK2kwARfN-NPXoRrX96dhQ', 63900, '_NORIBAN_', 6073, 'vlog', 'life', 'micro', 50000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '토우아', '___2toua2___', '___2toua2___', 847000, '___2toua2___', 1000000, '___2toua2___', 1400000, '___2toua2___', 36900, 'fashion', 'fashion', 'mega', 2000000, 1200000, NULL, NULL, NULL, 'JFUN', 'tag', '[부가설명] [250818 tag 케스팅] 
틱톡 ¥2,000,000         피드 ¥1,200,000', 'available', false, true),
(gen_random_uuid(), '리리', 'watashiwali', 'watashiwali', 486000, 'watashiwalil', 401100, 'sandomenoshoujiki', 399000, 'watashiwalil', 88900, 'color', 'beauty', 'mega', 1700000, 600000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '사토 소루토', 'soruto154', 'soruto154', 93000, 'soruto_154', 48000, 'soruto154', 385000, 'soruto154', 111500, 'kidsmom', 'life', 'middle', 100000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '소완', '_wanco02m', '_wanco02m', 246000, '_wanco02mm', 48400, '_wanco02m', 584000, '_wanco02m', 115000, 'color', 'beauty', 'middle', 240000, 420000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하라페코 트윈즈', 'harapeko__kako', 'harapeko__kako', 48000, 'haaraapeekootwins', 64300, 'UCD-1TFnqeSem13xk52_wPBw', 567000, 'harapeko__kako', 17700, 'food', 'food', 'micro', NULL, 60000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우치야마 유우카', 'yuka3l7', 'yuka3l7', 252000, 'yuka3l7', 579800, NULL, NULL, 'yuka3l7', 35800, 'fashion', 'fashion', 'middle', 500000, 300000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '코바야시 케이타', 'kidai_kobayashi', 'kidai_kobayashi', 93000, '0729kidai', 209800, NULL, NULL, 'kidai_kobayashi', 23400, 'vlog', 'life', 'middle', 280000, 130000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우에무라 소우타', 'souta.uemura1126', 'souta.uemura1126', 148000, 'soutatiktok', 419600, 'UCiBB63bW34iyPAM-FahcH9A', 8720, NULL, NULL, 'fashion', 'fashion', 'middle', 500000, 180000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유즈키 시이나', 'shiina_1021', 'shiina_1021', 71000, 'shiina1021', 149100, NULL, NULL, 'shiina_1021_', 21300, 'fashion', 'fashion', 'middle', 200000, 110000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '이로하 유메', 'yumeyume_22', 'yumeyume_22', 85000, 'yumecha_821', 533500, NULL, NULL, NULL, NULL, 'tech', 'other', 'middle', 550000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '야시로 나나', '8467_0', '8467_0', 212000, '8467_0', 332000, 'UCN4B2sSkQZwNDkkynVWLRuw', NULL, '8467_0', 75500, 'color', 'beauty', 'middle', 400000, 240000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '우란', 'luv02_uran', 'luv02_uran', 475000, 'luv02uran', 828600, NULL, NULL, 'luv02_uran', 220500, 'fashion', 'fashion', 'mega', NULL, 600000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '마에다 마하루', 'mahalu_maeda', 'mahalu_maeda', 111000, 'm20000429', 298500, NULL, NULL, 'mahalu_maeda', 5775, 'vlog', 'life', 'middle', NULL, 140000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카와구치 히우가', 'k_hyuuga0323', 'k_hyuuga0323', 124000, 'k_hyuuga0323', 1900000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, 250000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '하루세 모모', 'mo_mo_0061', 'mo_mo_0061', 42000, '161omom__', 359700, NULL, NULL, 'momo_karatea', 21400, 'vlog', 'life', 'micro', NULL, 50000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '료마', 'r_jimaaaa', 'r_jimaaaa', 92000, 'r_jimaaa', 914300, 'r_jimaaaa', 28200, 'r_jimaaaa', 20500, 'tech', 'other', 'middle', 900000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '료', '____hr13', '____hr13', 150000, 'riiiiiiilil', 1074000, NULL, NULL, '____hr13', 30, 'vlog', 'life', 'middle', 1100000, 170000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '에리사이토', 'erisaito.official', 'erisaito.official', 96000, 'eri_saito529', 43000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 50000, 140000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '야마노우치 스즈', 'suzu____chan', 'suzu____chan', 179000, 'mi89_k', 670500, NULL, NULL, '__suzu__chan', 153600, 'vlog', 'life', 'middle', 700000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '란', 'ran_okirenai', 'ran_okirenai', 419000, 'ran_okirenai', 1992000, 'ran_okirenai', 3, 'ran_okirenai', 136400, 'vlog', 'life', 'mega', 1700000, 500000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '타케우치 호노카', 'pochandaa', 'pochandaa', 97000, 'pochandaaa', 37100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 100000, 150000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '쿠루미', 'krm.__.mrk', 'krm.__.mrk', 160000, 'krm.__.mrk', 206200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 200000, 200000, 160000, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '카스', 'kasuu_kasu', 'kasuu_kasu', 894000, 'kasu_ps', 758200, NULL, NULL, 'kasu_ps', 595800, 'color', 'beauty', 'mega', 850000, 1100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '누쿠미 메루', 'meru_nukumi', 'meru_nukumi', 1990000, 'meru_nukumi', 477700, NULL, NULL, 'meruru20020306', 488300, 'fashion', 'fashion', 'mega', NULL, 3000000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '코난', 'konan_610', 'konan_610', 228000, 'konan610', 472400, 'UCgHEUGUX_tuGvIZU8o7phpw', 34600, 'konan6109', 127100, 'fashion', 'fashion', 'middle', 550000, 300000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '호시노 유나 (유나)', 'yuna_hoshino_official', 'yuna_hoshino_official', 540000, 'yuna_hoshino_official', 1673000, 'UCsTM1roCxoot1-03EO5zQxg', 518000, 'yuna__hoshino', 362100, 'fashion', 'fashion', 'mega', 2000000, 700000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '호노카', 'honoka7000', 'honoka7000', 153000, 'honoka7000', 291500, 'honoka7000', 505000, 'honoka7000', 381100, 'vlog', 'life', 'middle', 300000, 220000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세리슌', 'shun.28', 'shun.28', 116000, '0208_31', 533400, 'shun.28', 271000, '0208_31', 80000, 'vlog', 'life', 'middle', 500000, 190000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '바바 카이가', 'kaiga_banba', 'kaiga_banba', 64000, 'kaiga0819', 539200, 'UCUrZNkYO8SEEmuZwWdBRSzg', 271000, NULL, NULL, 'fashion', 'fashion', 'middle', 500000, 100000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '모카', 'moca.2812', 'moca.2812', 98000, 'moca_2812', 413800, NULL, NULL, 'MocaYamazaki', 34300, 'vlog', 'life', 'middle', 550000, 200000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '니코리', 'nlc0rl', 'nlc0rl', 42000, 'nlc0rl', 464100, 'nlc0rl', 3470, 'nlc0rl2', 9884, 'vlog', 'life', 'micro', 500000, 75000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '시라카와 레나', '__r_kw', '__r_kw', 91000, 'rena_grr', 467500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 450000, 120000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '유히', '_yuhi_1116', '_yuhi_1116', 73000, '_yuhi_1116', 1224000, '_yuhi_1116', 53700, '_yuhi_1116', 22300, 'tech', 'other', 'middle', 600000, 90000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '다이키', 'daiki20010606', 'daiki20010606', 97000, 'miyadaikin', 780000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 500000, 80000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '노리폰 채널', 'noripon1513', 'noripon1513', 49000, 'noripon.channel', 481600, 'UC2anAxlFg64q98Ba176msrA', 2000000, 'ponnori_1513', 24400, 'vlog', 'life', 'micro', 500000, 70000, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '타다노 히토', 'tadanohito12214', 'tadanohito12214', 42000, 'asobicocoro', 258000, 'tadanohito1', 161000, NULL, NULL, 'vlog', 'life', 'micro', 350000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '신타카', 'taka_uech', 'taka_uech', NULL, NULL, 265400, 'UCumTkkzAHkgeRC0awA-Kk8Q', 123000, NULL, NULL, 'fashion', 'fashion', 'micro', 320000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '신', 'shin_pq', 'shin_pq', 34000, 'shintaka.com', 265400, 'UCumTkkzAHkgeRC0awA-Kk8Q', 123000, 'shin_hsmt', 3545, 'fashion', 'fashion', 'micro', 320000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '류', 'taka_bq', 'taka_bq', 18000, 'shintaka.com', 265400, 'UCumTkkzAHkgeRC0awA-Kk8Q', 123000, 'iro_uech', 3625, 'fashion', 'fashion', 'micro', 320000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '켓케', 'kkadabusu', 'kkadabusu', 16000, 'kkadabusu', 68800, 'kkadabusu', 131000, 'kkadabusu', 9180, 'tech', 'other', 'micro', 100000, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '소우우츠 센세이', 'ofmsj', 'ofmsj', NULL, 'ofmsj', 135000, 'ofmsj', 1980, NULL, NULL, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', 'tag', NULL, 'available', false, true),
(gen_random_uuid(), '세나', 'sena_biyou', 'sena_biyou', 46000, 'sena_biyou', 2438, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 120000, 127500, NULL, 15000, 'JFUN', 'Karako', '[부가설명] [250905/DM회신]
피드 130,000엔(세금 별도)
릴스 150,000엔(세금 별도)
피드 모음 80,000엔(세금 별도)
스토리 30,000엔(세금 별도)
2차 사용(1개월) 20,000엔(세금 별도)
자세한 내용 자료
https://www.canva.com/design/DAF2w1TaJoo/aTI_ybO_xon_dSFVSUrfJA/view?utm_content=DAF2w1TaJoo&utm_campaign=designshare&utm_medium=link2&utm_source=uniquelinks&utlId=h57402ad408', 'available', false, true),
(gen_random_uuid(), '코바야시 아유', 'ayuchosuu', 'ayuchosuu', 48000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, 150000, 225000, NULL, 50000, 'JFUN', 'Karako', '[부가설명] [250905/순희/카라코리스트]
피드 투고: ¥150,000
릴스 투고: ¥225,000
2차 활용(1개월): ¥50,000', 'available', false, true),
(gen_random_uuid(), '하씨', 'hassiexxx', 'hassiexxx', 13000, NULL, NULL, NULL, NULL, 'hassiexxx', 525, 'base', 'beauty', 'micro', NULL, 19500, NULL, NULL, 7500, 'JFUN', 'Karako', '[부가설명] [250905/순희/카라코리스트]
피드 투고: ¥19,500
릴스 투고: -
2차 활용(1개월): ¥7,500', 'available', false, true),
(gen_random_uuid(), '미린', 'mirin_biyou', 'mirin_biyou', 47000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 375000, 525000, NULL, 50000, 'JFUN', 'Karako', '[부가설명] [250905/순희/카라코리스트]
피드 투고: ¥200,000
릴스 투고: ¥250,000
2차 활용(1개월): ¥50,000', 'available', false, true),
(gen_random_uuid(), '테스코', 'tesuko_test', 'tesuko_test', 103000, 'tesuko_test', 6724, 'tesuko_test', 6530, NULL, NULL, 'color', 'beauty', 'middle', NULL, 165000, 270000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '미리', 'mirimanialove', 'mirimanialove', 33000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 105000, 150000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '오유탄', 'oyutann', 'oyutann', 28000, NULL, NULL, NULL, NULL, 'oyutannnnn', 213, 'base', 'beauty', 'micro', NULL, 90000, 135000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '죤', 'chon_._._', 'chon_._._', 22000, NULL, NULL, NULL, NULL, NULL, NULL, 'base', 'beauty', 'micro', NULL, 66000, 99000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '니나', '_____nemn', '_____nemn', 91000, '_____nemn', 144100, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 285000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '미키미쿠', 'makimiku001', 'makimiku001', 40000, 'makimiku001', 18, NULL, NULL, 'makimiku0006', 302, 'fashion', 'fashion', 'micro', NULL, 45000, 60000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '카논', '7x16__', '7x16__', 26000, '7x16__', 5486, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, 37500, 45000, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '타후코짱', 'llx_ayu_xll', 'llx_ayu_xll', NULL, 'llx_ayu_xll', 19700, NULL, NULL, 'llx_ayu_xll', 163000, 'base', 'beauty', 'middle', NULL, 450000, NULL, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '미린', 'usagi_usagi____', 'usagi_usagi____', NULL, NULL, NULL, NULL, NULL, 'usagi_usagi____', 146000, 'color', 'beauty', 'middle', NULL, 225000, NULL, NULL, NULL, 'JFUN', 'Karako', NULL, 'available', false, true),
(gen_random_uuid(), '짱키티', 'heisay2k', 'heisay2k', 6500, 'heisay2k', 8890, 'heisay2k', 4320, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', '개인', '[부가설명] [250905/DM회신]

고정비용 방식
■ 피드 게시물(이미지·영상)   1건당 80,000엔(세금 별도)
■ 릴스 게시물(숏폼 영상)   평균 조회수가 약 8만 회이므로,    1건당 240,000엔(세금 별도)로 책정됩니다.
■ 스토리 게시물   • 릴스나 피드와 세트일 경우: 무상     • 단독으로 스토리 게시물만 진행할 경우: 20,000엔(세금 별도)
---------------
완전 성과 보수형
◾️릴스 게시물(숏폼 영상)    1임프레션당 3엔  ※ 1개월간 1만 임프레션 미만일 경우 무상
◾️피드 게시물(이미지·영상)    1임프레션당 1엔    ※ 1개월간 1만 임프레션 미만일 경우 무상
◾️스토리 게시물    무상

상한 금액: 릴스·피드 모두 1게시물당 최대 300만 엔     /릴스 (100만 임프레션) / 피드 (300만 임프레션)  ※ 그 이상의 임프레션이 발생해도 추가 비용은 청구하지 않습니다.', 'available', false, true),
(gen_random_uuid(), '시노다 마리코', 'shinodamariko3', 'shinodamariko3', 671000, 'marikoshinoda', 190300, 'UCPvMrbh7KtLwWwTAOBmjeIg', 130000, 'mariko_dayo', 1800000, 'fashion', 'fashion', 'mega', NULL, 1250000, 1250000, 1000000, NULL, 'OOO엔터', NULL, '[부가설명] [250915/순희/라인방]
Feed
¥1,250,000（税別）
Reel
¥1,250,000（税別）
Stories
¥1,000,000（税別）', 'available', false, true),
(gen_random_uuid(), '마쓰카와 아카리', 'akarin__rin', 'akarin__rin', 635000, 'akarin__rin', 406800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, 1600000, 2000000, NULL, NULL, 'OOO엔터', NULL, '[부가설명] [250915/순희/라인방]
Feed
¥1,600,000（税別）
Reel
¥2,000,000（税別）
Stories
都度相談', 'available', false, true),
(gen_random_uuid(), '타케야키 쇼', 'takeyakisan', 'takeyakisan', NULL, 'takeyakisyo', 455500, 'takeyakisan', 2730000, 'takeyakii', 433500, 'tech', 'other', 'mega', NULL, NULL, 853050, 871200, 550000, 'OfficeU', NULL, '[부가설명] [250915/순희/라인방]
-Reels：¥853,050
-스토리 2회 : ¥871,200
-TikTok：¥2,200,000
→TikTokLive도 적극적으로 하고 있으며 팔로워 수도 급상승 중입니다!', 'available', false, true),
(gen_random_uuid(), '미사', 'misa_fufulife', 'misa_fufulife', 63000, 'misa_fufulife', 9785, 'misa_fufulife', 7390, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 80000, NULL, NULL, 'JFUN', NULL, '[부가설명] [250922 레이리/ 라인 / 유리린 소개]
릴스 8만엔', 'available', false, true),
(gen_random_uuid(), '유우', 'yoummmmmb', 'yoummmmmb', 26000, 'yoummmmmb', 31900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, 80000, 90000, 70000, NULL, 'JFUN', 'libertytown', '[부가설명] sales@libertytown.co.jp  [250923 소속사 라인]

・릴스 게시물(1건): 9만 엔 (비과세)
・피드 게시물(1건): 8만 엔 (비과세)
・스토리 게시물(1건): 7만엔 (비과세)', 'available', false, true),
(gen_random_uuid(), '타마고짱', 'tamagochan_ol', 'tamagochan_ol', 106000, 'tamagochan_ol', 135700, 'tamagochan_ol', 80500, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] [인플루언서 서칭 중 릴스 노출수가 높아 리스트업 해둠]
가격 및 컨택 가능 확인 필요', 'available', false, true),
(gen_random_uuid(), '사유', 'nikibi_sayu', 'nikibi_sayu', 30000, 'nikibi_sayu', NULL, 'nikibi_sayu', 4300, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] [인플루언서 서칭 중 릴스 노출수가 높아 리스트업 해둠]
가격 및 컨택 가능 확인 필요', 'available', false, true),
(gen_random_uuid(), '마아', 'pica__maa', 'pica__maa', 72000, NULL, NULL, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '에리자베스와 남편', 'elizabeth_dannadayo', 'elizabeth_dannadayo', 54000, 'elizabeth_dannadayo', 22800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아유', 'ayayuu32', 'ayayuu32', 133000, 'ayayuu32', 49700, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나카가와 쇼코', 'shoko55mmts', 'shoko55mmts', 375000, NULL, NULL, 'shokotan_wo', 950000, 'shoko55mmts', 896800, 'tech', 'other', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '츠지노 노조미', 'tsujinozomi_official', 'tsujinozomi_official', 2085000, 'tsujinozomiofficial', 851500, 'UCNiurMpWExWgio2lqldycbA', 250000, 'nozomituji__', 528, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '문', 'moontwins.0810', 'moontwins.0810', 269000, 'moontwins.0810', 1332, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '모모', 'momodietlife', 'momodietlife', 19000, 'momodietlife', 1215, 'momodietlife', 1800, NULL, NULL, 'kidsmom', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유라라와 하루짱', 'yurara_haruchan', 'yurara_haruchan', 30000, 'yurara_haruchan', 56800, 'UCsBHbLc6_z1VznBd8aK39pA', 17500, NULL, NULL, 'kidsmom', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유이', '_ui_ymgm', '_ui_ymgm', 40000, '_ui_ymgm', 5632, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야', 'aya_life333', 'aya_life333', 26000, 'aya_life333', 4466, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야토와 오즈', 'aya.to.ooz', 'aya.to.ooz', 134000, 'aya.to.ooz', 84400, NULL, NULL, NULL, NULL, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아이리', 'gtamtgat', 'gtamtgat', 128000, 'akak0319', NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키쿠치 아미', 'amikikuchi0905', 'amikikuchi0905', 462000, NULL, NULL, 'UCjl8UBoqlulhOn6OR8fpiUg', 258000, 'lespros_ami', 150000, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '키노시타 유키', 'kinoshitayuki_official', 'kinoshitayuki_official', 910000, 'kinoshitayuki_official', 650400, 'kinoshitayu-ki', 323000, 'kinoshitas0309', 370900, 'kidsmom', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '유키 토모에', '_tomoe_0722', '_tomoe_0722', 163000, NULL, NULL, NULL, NULL, '_tomoe_0722', 36700, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '교우세이짱', 'kotty_xx', 'kotty_xx', 86000, 'kyouseichan', 736900, 'UCrIKsbSGllNsz70-t2pBlqQ', 57300, 'kyoseichan_xxme', 1118, 'food', 'food', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '루나', 'mm_runa', 'mm_runa', 1296000, 'runa_mm_0211', 2100000, 'UCSspDdadXHACIwgHLQ3q2bw', 55500, '_Runa_Ru_na', 585200, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '나나', '__na817ktt', '__na817ktt', 38000, '__na817ktt', 502000, NULL, NULL, '__na817ktt', 3524, 'color', 'beauty', 'micro', 500000, 100000, 300000, 50000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '에무', 'mamama_ss', 'mamama_ss', 188000, 'karaage_usb111', 299300, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 700000, 200000, 600000, 130000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '모니', 'mo_2_i', 'mo_2_i', 74000, 'mo_2_o', 211300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 400000, 150000, 300000, 80000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '아타시짱', 'qvvskkaee', 'qvvskkaee', 65000, '___888_8g', 390400, 'UCMxmQ6WZNxlML00ikIAdnhw', 13899, NULL, NULL, 'color', 'beauty', 'middle', 300000, 100000, 250000, 80000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '카논', '__xd_x1', '__xd_x1', 104000, 'xd__x1', 373000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 350000, 150000, 300000, 100000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '메이', 'mei20001105', 'mei20001105', 82000, 'ptjamwtjjmmgttwwjpppppp', 709000, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 500000, 80000, 200000, 50000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '키키', 'oo_31_oo', 'oo_31_oo', 8163, 'oo_31_oo', 125000, 'oo_31_oo', 4180, NULL, NULL, 'fashion', 'fashion', 'middle', 250000, 25000, 80000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '아네데스', 'meronpan_p_reverse', 'meronpan_p_reverse', 103000, 'meronpan_ane', 456000, 'UCsuzpUViBIBKB1VGEMIp4kg', 372000, 'p_reverse', NULL, 'vlog', 'life', 'middle', 550000, 200000, 350000, 150000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '후지나 네코', 'tsubunyank0', 'tsubunyank0', 36000, 'tsubunyank0', 135000, 'tsubunyank0', 1570, NULL, NULL, 'color', 'beauty', 'micro', 220000, 100000, 150000, 60000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '하즈나', 'milk__tea.com_', 'milk__tea.com_', 24000, 'milk__tea.com_', 56000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 80000, 40000, 60000, 30000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '메구미', 'immegx_', 'immegx_', 19000, 'mayuge_inochi_', 123000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 200000, 50000, 100000, 30000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '나호', '____nhgram____', '____nhgram____', 17000, '____nhgram____', 182200, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 180000, 50000, 100000, 30000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '렌렌의 일상', 'renrenpoyo0904', 'renrenpoyo0904', 24000, 'renren9944', 102300, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 120000, 40000, 80000, 20000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '우라아카', 'a.n.e.hikoukai', 'a.n.e.hikoukai', 2815, 'a.n.e.hikoukai', 80000, NULL, NULL, NULL, NULL, 'tech', 'other', 'middle', 250000, NULL, NULL, NULL, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '코요짱', 'koyomatsu5', 'koyomatsu5', 19000, 'koyomatsu5', 156800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 200000, 80000, 150000, 50000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '케로짱', 'kerochan1104', 'kerochan1104', 57000, 'keroriinu1218', 109900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 65000, 10000, 50000, 5000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '스누', 'room___1997', 'room___1997', 1733, 'sn00py_0519', 63000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 75000, 10000, 40000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '쿠로하네 리카', 'pomu_rrrika', 'pomu_rrrika', 38000, 'pomu_rrr', 209200, NULL, NULL, 'pomu_rrika', 5796, 'color', 'beauty', 'micro', 200000, 55000, 120000, 40000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '히나', '013hina', '013hina', 58000, '057hina', 126900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 200000, 75000, 120000, 50000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '고키젯토', 'pi_ch.jp', 'pi_ch.jp', 77000, 'goki_jet_jp', 345800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 300000, 100000, 150000, 85000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '레나', '_07chany_', '_07chany_', 5555, '_ll27y', 146500, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 170000, 20000, 30000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '마나카', 'choco_manaka', 'choco_manaka', 5705, 'choco__manaka', 92300, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 150000, 20000, 70000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '나포', '_napochi_', '_napochi_', 39000, 'napo782', 219000, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 240000, 50000, 90000, 30000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '세리', 'kksry.1231', 'kksry.1231', 11000, 's_e_r_i_', 50900, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 60000, 20000, 30000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '마리아', 'm1r609', 'm1r609', 1918, 'm1r609', 106100, 'm1r609', 163000, NULL, NULL, 'tech', 'other', 'middle', 100000, 10000, 50000, 5000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '마유', 'm_0806u', 'm_0806u', 7483, 'm_0806u', 15800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 40000, 20000, 30000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '야다 나나미', 'nanamiyada', 'nanamiyada', 6904, 'nanamiyada', 31400, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 30000, 20000, 40000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '카논', 'kann_19', 'kann_19', 5169, '__kaisua__', 32300, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 40000, 20000, 30000, 10000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '유메노', 'y_nstyle', 'y_nstyle', 30000, 'yumeno777777', 163300, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 150000, 40000, 100000, 35000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '하가마우', 'baikinman_m', 'baikinman_m', 3556, 'baikinman_m', 108800, NULL, NULL, NULL, NULL, 'color', 'beauty', 'middle', 75000, 20000, 50000, 5000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '마유', '_mayu.o0_', '_mayu.o0_', 13000, '_89.o0_', 123500, NULL, NULL, NULL, NULL, 'vlog', 'life', 'micro', 100000, 30000, 70000, 15000, NULL, 'JFUN', 'CRAZE', NULL, 'available', false, true),
(gen_random_uuid(), '하시시타 미요시', 'miyoshikun', 'miyoshikun', 269000, 'miyoshikun', 115400, 'UCirdhrmnVwwTFAXW6ombrxQ', 156000, 'miyoshikundane', 85000, 'color', 'beauty', 'middle', NULL, 500000, 550000, 150000, NULL, 'JFUN', NULL, '[부가설명] [ 251215 라인 회신] 
◾️릴투고(1개)_55만엔+세금
◾️피드백(1개)_50만엔+세금
◾️ 스토리 투고 (1개 ~ 복수) _ 위 추가 투고인 경우 15만엔 + 세금
◾️콜라보 게시물 여부
가능(상품에 따라 그때그때 판단하면 좋을 것 같습니다)
* Qoo10랜딩페이지에서 인플루언서 이미지사용+릴1개+스토리4개 이상 ~

·2026년 1월은 샴푸&클리닉을 자제하고 있습니다', 'available', false, true),
(gen_random_uuid(), '트레이니 사쿠라', 'sakufitness', 'sakufitness', 188000, 'sa__ku_', 132100, 'sakufitness', 408000, NULL, NULL, 'health', 'life', 'middle', 500000, NULL, 600000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아이오나', 'iona_suzuki', 'iona_suzuki', 85000, 'iona0903', 65500, NULL, NULL, 'IONA0903', 4219, 'health', 'life', 'middle', 520000, NULL, 560000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '유리냐', 'yurinya_1128', 'yurinya_1128', 463000, 'yurinya1128', 1000000, 'yurinya', 515000, 'yurinya1128', 424300, 'fashion', 'fashion', 'mega', 3000000, NULL, 2300000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '모모미', 'momomi__official', 'momomi__official', 110000, 'momomi__official', 97000, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', 350000, NULL, 300000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '다케우치 마리나', 'takemari1219', 'takemari1219', 917000, 'takemari1219', 80100, 'UCw7HTQv0F4CB9zGRhqosYsg', 4410000, 'takemari1219', 193400, 'health', 'life', 'mega', 500000, NULL, 1800000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아마네', 'amane_3636', 'amane_3636', 177000, 'amane3636', 314300, 'UCYnoZ1SC1yT1cgSDRpe8gxQ', 623000, NULL, NULL, 'vlog', 'life', 'middle', 1000000, NULL, 1300000, 650000, NULL, NULL, 'vaz', '[부가설명] [ 260402 라인 회신] 

릴스 게시물 1건: 130만 엔 (세별)
스토리 1건: 65만 엔 (세별)
유튜브 쇼츠 1건: 170만 엔 (세별)
유튜브 장편 영상 내 상품 노출 1건: 470만 엔 (세별)
YouTube 쇼츠·TikTok·Instagram 3개 매체 동시 업로드(재업로드): 200만 엔 (세별)', 'available', false, true),
(gen_random_uuid(), '노가 채널', 'nogachannel', 'nogachannel', 112000, 'nogachannel', 44300, 'UCP6aw2-Afafmm0cPZ7pmYyQ', 38800, 'nogachannel', 105800, 'health', 'life', 'middle', 150000, NULL, 300000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '스즈', '__zvely__', '__zvely__', 83000, '__zvely__', 320500, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 560000, NULL, 350000, NULL, NULL, NULL, 'vaz', '[부가설명] [251104/라이즈어 소속사/순희]
https://www.youtube.com/@user__zvely__ 유튜브', 'available', false, true),
(gen_random_uuid(), '히나타', 'hinat.a0525', 'hinat.a0525', 117000, 'hi_na106', 355000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 600000, NULL, 400000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '미나츠', 'meenatsu_', 'meenatsu_', 93000, 'mnluvx', 254700, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 400000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '히나노', '_hina_n_o_08', '_hina_n_o_08', 32000, 'hi_na_no__', 105000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 200000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '마호코', 'mahoko.0918', 'mahoko.0918', 169000, 'mahoko_918', 222700, NULL, NULL, 'mahoko0918', 7, 'color', 'beauty', 'middle', 400000, NULL, 400000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '유우리', 'shimizu_414', 'shimizu_414', 20000, 'yutya_sama', 61100, 'shimizu_414', 6430, NULL, NULL, 'fashion', 'fashion', 'micro', 200000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '유우히', 'yuhi_0206', 'yuhi_0206', NULL, 'yuhi_0206', 37200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '치나푸푸', 'tina._.nyan', 'tina._.nyan', 148000, 'tina._.nyan', 506800, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 630000, NULL, 250000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아야노다가네', 'ayanodagane', 'ayanodagane', 70000, 'ayanodagane32', 1200000, 'ayanodagane', 46400, 'ayanodagane', 5430, 'color', 'beauty', 'middle', 1200000, NULL, 440000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '시라세 아카리', 'shiraseakari12', 'shiraseakari12', NULL, 'shiraseakari12', 910000, 'shiraseakari4033', 508000, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '쓰지 노조미', 'tsujinozomiofficial', 'tsujinozomiofficial', NULL, 'tsujinozomiofficial', 813500, 'UCNiurMpWExWgio2lqldycbA', 250000, NULL, NULL, 'kidsmom', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '케미오', 'mmkemio', 'mmkemio', NULL, 'mmkemio', 1200000, 'mmkemio', 2130000, 'mmkemio', 1200000, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '이타노 토모미', 'tomo.i_0703', 'tomo.i_0703', 2091000, 'tomo.i_0703', 375200, 'UCDLqvTPnN70jKZNqaDF4GwQ', 2170, 'tomo_coco73', 1600000, 'fashion', 'fashion', 'mega', 1000000, NULL, 3500000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나카가와 소라', 'nakagawa_sora214', 'nakagawa_sora214', 84000, 'nakagawa_sora214', 153800, NULL, NULL, 'nakagawasora214', 4984, 'color', 'beauty', 'middle', 250000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '다카하시 카노', 'kano0825', 'kano0825', 124000, 'kano_0939', 276300, 'UCuXbGMij6S45YtuaHJJKa_A', 39100, NULL, NULL, 'fashion', 'fashion', 'middle', 360000, NULL, 240000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '마사모토 레이라', 'leilaazjp', 'leilaazjp', 29000, 'leilamasamoto', 91400, 'UCuXbGMij6S45YtuaHJJKa_A', 39100, NULL, NULL, 'fashion', 'fashion', 'micro', 160000, NULL, 100000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '이마이 안제리카', 'ange1115', 'ange1115', 129000, 'ange_nuts', 157500, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 180000, NULL, 240000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나카무라 리온', 'rion_nakamura89', 'rion_nakamura89', 108000, 'rion_nakamura89', 300100, NULL, NULL, 'Rion_Nakamura', 20300, 'fashion', 'fashion', 'middle', 360000, NULL, 180000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '후쿠레나', 'fukurena1', 'fukurena1', NULL, 'fukurena1', 809600, 'fukurena', 1780000, 'fukurena0924', 550900, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '요루노 히토와라이', 'hnkichie27', 'hnkichie27', 236000, 'yorunohitowarai', 2300000, NULL, NULL, 'ichie19991027', 78100, 'vlog', 'life', 'middle', 2400000, NULL, 2500000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '한나리즈', 'hannariz.haru', 'hannariz.haru', NULL, 'hannariz.haru', 568800, 'UC5LiCoPtOS5Tr_fZ5qLc4eA', 941000, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나가노 코ト네', 'n.__.ene0840', 'n.__.ene0840', 94000, 'nenemonsterr', 747600, 'nene._.monster', 24800, NULL, NULL, 'vlog', 'life', 'middle', 660000, NULL, 120000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나나', 'nana101381', 'nana101381', 97000, 'nana101313', 687900, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 480000, NULL, 60000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '히마리 스피카', 'himari__spica', 'himari__spica', 107000, 'himari_spica', 368400, NULL, NULL, 'himari_spica', NULL, 'vlog', 'life', 'middle', 250000, NULL, 100000, NULL, NULL, NULL, 'vaz', '[부가설명] [251104/라이즈어 소속사/순희]
틱톡: ¥450,000
릴스: ¥250,000
피드: ¥150,000
스토리: ¥109,000', 'available', false, true),
(gen_random_uuid(), '카와무라 카나토', 'kanato4926', 'kanato4926', 127000, 'kanatodayon_freum', 237100, 'kanato-freum', 60800, NULL, NULL, 'fashion', 'fashion', 'middle', 250000, NULL, 120000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '야기 리미', 'rim_i0930', 'rim_i0930', 13000, '093r__', 96100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 120000, NULL, 50000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '유후 나츠키', 'yufudayo', 'yufudayo', 231000, NULL, NULL, 'yufudayo', 231000, 'yufudayo', 23600, 'vlog', 'life', 'middle', NULL, NULL, 1000000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '세이케이 아이돌 토도로키짱', 'todoroki.sk', 'todoroki.sk', 149000, 'todoroki_sk', 294700, 'UCIPKo-3YgwWFFEeagS-j30A', 170000, 'todoroki_sk', 135400, 'color', 'beauty', 'middle', 1630000, NULL, 1500000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '사쿠라', 'skrchan1028', 'skrchan1028', 19000, 'skrchan1028', 132500, NULL, NULL, 'skrchan1028', 10700, 'vlog', 'life', 'micro', 270000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아메이', 'amei_oooka.sakura', 'amei_oooka.sakura', 8107, 'amei.oooka', 72200, NULL, NULL, 'amei_sakura', 8710, 'food', 'food', 'middle', 200000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아키야마 미즈키', '3.zuki2', '3.zuki2', 110000, 'miii.500', 261800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 450000, NULL, 300000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '쿠키타 나나카', 'nanaka_kukita', 'nanaka_kukita', 111000, 'nanaka_kukita', 264000, 'kukitananakadesu', 127000, 'nanaka_karatea', NULL, 'vlog', 'life', 'middle', 320000, NULL, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '히마히마', 'himahima_channel', 'himahima_channel', 221000, 'himahima_channel', 437000, 'hima_hima', 1020000, 'himahima_chan', 41600, 'vlog', 'life', 'middle', 480000, 440000, 440000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '미유', 'miyu0300', 'miyu0300', 720000, 'miyusan.30', 619400, 'miyu0300', 470000, 'miyu0300_', 126800, 'vlog', 'life', 'mega', 2500000, 2880000, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '리리카', '0027_rika', '0027_rika', 88000, 'ririka20070727', 422700, '0027_rika', 19700, NULL, NULL, 'fashion', 'fashion', 'middle', 600000, 180000, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아이바 세이온', 'aiba_rinon', 'aiba_rinon', 202000, 'rinon241', 450600, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 600000, 300000, 400000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '히요리', 'hiyo1_991', 'hiyo1_991', 38000, 'hiyori_mommy1929', 106000, NULL, NULL, 'hiyori_1119ta', 5370, 'fashion', 'fashion', 'micro', 200000, 70000, 200000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '마린 일기', 'marin_honda', 'marin_honda', 1392000, 'marin.honda', 191600, 'marin_honda', 184000, NULL, NULL, 'vlog', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '후지타 미아', 'miamiamia2006', 'miamiamia2006', 219000, 'mia_f069', 472100, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '기타즈메 미즈키', '__.michox.__', '__.michox.__', 32000, 'mizukidasinnn', 123200, NULL, NULL, '__michox__', 952, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '마스다 코하루', 'koha_0303', 'koha_0303', 47000, 'kkkoha33', 180000, NULL, NULL, 'kohakona7200', 16000, 'fashion', 'fashion', 'micro', 290000, 130000, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나가하마 히로나', 'hinak.o0619', 'hinak.o0619', 559000, 'hinako0619', 931200, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz, grove', '[부가설명] [251106/라인/순희]
Grove 라인방 생성/기업정보등록 후 금액 확인 가능', 'available', false, true),
(gen_random_uuid(), '토키타 네네', 'tokita_nene', 'tokita_nene', 233000, 'nene_tokita', 364300, NULL, NULL, 'nene_tokita', 30600, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '코마치', 'k204910', 'k204910', 53000, 'machimachi_877', 285800, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'middle', 650000, NULL, 520000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '초사', '_chosa___', '_chosa___', 129000, 'chosaramensuki', 720000, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', 520000, NULL, 390000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '아이', 'll09ll0_', 'll09ll0_', 37000, 'cheezu.o', 24400, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', 200000, NULL, 150000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '소바', 'so_ba2838', 'so_ba2838', 11000, 'soba.2838', 155000, NULL, NULL, NULL, NULL, 'tech', 'other', 'micro', 200000, NULL, 150000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '나나카', 'anyo_______n', 'anyo_______n', 35000, 'anyo_______n', 80000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', 200000, NULL, 150000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '완코', 'wanko_1215', 'wanko_1215', 16000, 'h_1215na', 56700, NULL, NULL, 'wanko_1215', 6612, 'tech', 'other', 'micro', 150000, NULL, 100000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '미이나', '__y.317', '__y.317', 106000, '__y.317', 121200, 'y.317channel', 29800, 'mmiina317', 3241, 'fashion', 'fashion', 'middle', 260000, NULL, 260000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '유나', 'ny__yn1002', 'ny__yn1002', 20000, 'yunyo02', 845000, 'nyyuna1002', 3330, NULL, NULL, 'fashion', 'fashion', 'micro', 650000, NULL, 650000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '레이', 'leeei_h_0', 'leeei_h_0', 50000, 'leeei_h_0', 134400, 'leeei_h_0', 48200, 'leeei_h_0', 413, 'color', 'beauty', 'middle', 780000, NULL, 650000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '하루키 미리아', '3rhycha_n', '3rhycha_n', 38000, '3rhycha_n', 50600, '3rhycha_n', 1850, '3rhycha_n', 328, 'color', 'beauty', 'micro', 130000, NULL, 120000, NULL, NULL, NULL, 'vaz', NULL, 'available', false, true),
(gen_random_uuid(), '신도 쿄카', 'kyoka.san01', 'kyoka.san01', 79000, 'kyokasan123', 1500000, NULL, NULL, 'kyokasan01', 16000, 'vlog', 'life', 'middle', 1000000, 340000, 500000, 40000, 100000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '후타바 CP', 'kschan_98', 'kschan_98', 26000, 'futaba_channel', 1100000, 'kschan_98', 17200, NULL, NULL, 'vlog', 'life', 'micro', 840000, 50000, 150000, 40000, 80000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), 'GYUTAE(규테)', 'kimgyutae_official', 'kimgyutae_official', 751000, '_kimgyutae', 948400, 'UCcwh0T2Fqxo9NHrpqKBrwIw', 957000, '_kimgyutae', 56300, 'color', 'beauty', 'mega', 4000000, 2500000, 4000000, 850000, 750000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), 'Chuson Channel 츄손 채널', 'chusonchannel', 'chusonchannel', 30000, 'chusonchannel', 883500, 'chusonchannel', 2080000, NULL, NULL, 'vlog', 'life', 'micro', 500000, 90000, 170000, 50000, 50000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '에리카', 'myxx_erika', 'myxx_erika', 109000, 'myxx_erika', 840600, NULL, NULL, 'myxx_erika', 109100, 'fashion', 'fashion', 'middle', 1000000, 140000, 250000, 50000, 100000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '마이판', 'maipan_03', 'maipan_03', 134000, 'maipan_03', 831400, 'maipan_03', 481000, 'mcr2018_03ms', 11300, 'vlog', 'life', 'middle', 1250000, NULL, NULL, NULL, 120000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '아카빈탄', 'akabintan', 'akabintan', 154000, 'akabintan', 729700, 'akabintan', 1570000, NULL, NULL, 'vlog', 'life', 'middle', 1500000, 250000, 1000000, 90000, 150000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '코니타카 긴', 'peitakagin', 'peitakagin', 540000, 'conytakagin', 679700, 'conytakagin', 335000, NULL, NULL, 'vlog', 'life', 'mega', 2500000, 1170000, 2500000, 50000, 400000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '요메노 네조가 와루스기루', 'kanojyononezou', 'kanojyononezou', 51000, 'kanojyononezou', 534700, 'kanojyononezou', 154000, 'kanojyononezou', 1006, 'vlog', 'life', 'middle', 1000000, 150000, 300000, 50000, 100000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '테테미', 't_e_t_e_m_i', 't_e_t_e_m_i', 68000, 't_e_t_e_m_i', 522300, 'UCZIFv5qDVYcrLcd3sXyEpKQ', 105000, 't_e_t_e_m_i', 2032, 'color', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '료지미쿠 커플', 'ryojimiku1227', 'ryojimiku1227', 19000, 'ryoji0718', 497000, 'ryojimiku1227', 232000, NULL, NULL, 'vlog', 'life', 'micro', 700000, 50000, 150000, 40000, 70000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '류우사키 CP', 'ryu____saki', 'ryu____saki', 36000, 'ryu__saki', 495400, 'ryu_saki', 26700, 'ryu___saki', 1353, 'vlog', 'life', 'micro', 420000, 60000, 150000, 50000, 40000, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '사사키 노조미', 'nozomisasaki_official', 'nozomisasaki_official', 4801733, '_nozomi_sasaki', NULL, 'nozomi_sasaki', 477000, NULL, NULL, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '야마다 유우', 'yu_yamada_', 'yu_yamada_', 1396146, 'yu_yamada_official', 55300, NULL, NULL, 'yu_yamada__', 74800, 'fashion', 'fashion', 'mega', NULL, NULL, 8500000, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '후지모토 미키', 'mikittyfujimoto', 'mikittyfujimoto', 727819, 'mikitty_staff', 111100, 'hello_mikitty', 1030000, 'mikitty_staff', 12600, 'vlog', 'life', 'mega', NULL, NULL, 2500000, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '마스와카 츠바사', 'tsubasamasuwaka1013', 'tsubasamasuwaka1013', 670425, 'tsubasamasuwaka1013', 162000, 'tsubasamasuwaka1013', 254000, 'tsubasamasuwaka', 1000000, 'color', 'beauty', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '시오리', 'salt__.xx', 'salt__.xx', 598073, 'salt__.xx', 716800, 'UCyvr2ELIyzSfkaZ8TcJWBvw', 24700, 'salt__xx_', 59000, 'fashion', 'fashion', 'mega', NULL, NULL, 1500000, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '나루네에', 'naru.enjoy_diet', 'naru.enjoy_diet', 564577, 'naru.enjoy_diet', 884800, 'naru.enjoy_diet', 2550000, NULL, NULL, 'health', 'life', 'mega', NULL, NULL, NULL, NULL, NULL, NULL, 'ppp스튜디오', NULL, 'available', false, true),
(gen_random_uuid(), '치히로', 'chihiro_511', 'chihiro_511', 91000, NULL, NULL, NULL, NULL, 'chihiro_511_3', 38600, 'fashion', 'fashion', 'middle', NULL, 90000, 150000, 40000, NULL, '코노나', NULL, '[부가설명] ---251013 코노나님 투어 진행 --- 
평상시 릴스 15만엔, 피드 9만엔 , 스토리 4만엔', 'available', false, true),
(gen_random_uuid(), '사쿠라', 'skr_mtt', 'skr_mtt', 15000, 'skr_mtt', 163400, 'skr_mtt410', 3080, 'skr_mtt', 714, 'tech', 'other', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야', 'aya_0429', 'aya_0429', 91000, NULL, NULL, NULL, NULL, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] 251103 소다마리에님 소개로 이유클리닉 방문', 'available', false, true),
(gen_random_uuid(), '가츠야', 's_katsuya_', 's_katsuya_', 183000, 's_katsuya___', 229000, NULL, NULL, 's_katsuya___', 1377, 'fashion', 'fashion', 'middle', NULL, 300000, 350000, 50000, NULL, 'JFUN', '개인', '[부가설명] 251125 라인방

피드 30만엔, 릴스 35만엔 ,틱톡 35만앤 , 릴스+ 틱톡  50만엔  ( 기본적으로 스토리 1건은 무상이지만 추가시 스토리 1건 5만엔 )', 'available', false, true),
(gen_random_uuid(), '사본', 'sakibon69', 'sakibon69', 100000, 'sakibon69', 77800, 'sakibon69', 8140, 'sakibon69', 39700, 'tech', 'other', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '개인', NULL, 'available', false, true),
(gen_random_uuid(), '나츠미', 'na0912mi', 'na0912mi', 248000, 'natssumiiiii', NULL, NULL, NULL, 'Natssumiiiii', 68200, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '개인', '[부가설명] 251209 라인 회신]
릴스 1건 25만엔', 'available', false, true),
(gen_random_uuid(), '신디', 'cindystory__', 'cindystory__', 113600, 'cindystory__', 81800, 'UCwTdc0EFNmFtcruuLLY57OQ', 5320, 'cindystory__', 10500, 'vlog', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '개인', NULL, 'available', false, true),
(gen_random_uuid(), '쥬리나', 'julia_crossvein', 'julia_crossvein', 17000, NULL, NULL, NULL, NULL, 'crossvein_vo', 3958, 'kidsmom', 'life', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '아야짱', 'aya.you.love.r', 'aya.you.love.r', 217000, 'ayayoulover', 127600, NULL, NULL, 'ayayoulover', 7591, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '카나민', 'kanamingram_24', 'kanamingram_24', 58000, 'kanamin_98', 56800, NULL, NULL, 'kanamin_98', 1525, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '리코', 'riko_shirahama', 'riko_shirahama', 51000, 'riko_shirahama', 22700, 'riko_shirahama', 216, 'riko_shirahama', 763, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '츠루', 'tsuru_30beauty', 'tsuru_30beauty', 19000, 'tsuru_30beauty', 13100, 'tsuru_30beauty', 10500, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '니키', 'niki.kawabe', 'niki.kawabe', 30000, 'niki.kawabe', 24300, NULL, NULL, 'niki_kawabe', 15700, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '오토', 'oto_13_', 'oto_13_', 10000, NULL, NULL, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true),
(gen_random_uuid(), '노리코', 'norikofukuda212', 'norikofukuda212', 69000, NULL, NULL, NULL, NULL, 'norikofukuda212', 68900, 'vlog', 'life', 'middle', NULL, NULL, 200000, 200000, NULL, NULL, '개인', NULL, 'available', false, true),
(gen_random_uuid(), '간 아스카', 'asukan71', 'asukan71', 18000, 'asukan71', 17000, NULL, NULL, NULL, NULL, 'fashion', 'fashion', 'micro', NULL, 25000, 30000, 15000, NULL, 'JFUN', NULL, '[부가설명] [251208 라인회신]
 ◾️ 릴 투고 (1 개) : 25,000~35,000엔
◾️ 피드 게시물 (1 개) : 20,000~30,000엔
◾️ 스토리 투고 (1개 ~ 복수) : 편당 10,000~15,000엔 (3개 세트 : 25,000~35,000엔)', 'available', false, true),
(gen_random_uuid(), '에미', 'emiliopucci__', 'emiliopucci__', 245000, 'emiliopucci__', 42700, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, 250000, NULL, NULL, 'JFUN', NULL, '[부가설명] [260107 라인회신]', 'available', false, true),
(gen_random_uuid(), '오죠', 'ojou_kirkir', 'ojou_kirkir', 43000, 'ojou_kirkir', 46600, 'ojou_kirkir', 1060, NULL, NULL, 'base', 'beauty', 'micro', NULL, NULL, 150000, NULL, NULL, 'JFUN', NULL, '[부가설명] [260107 라인회신]', 'available', false, true),
(gen_random_uuid(), '언야', 'onnya_s2', 'onnya_s2', 200000, 'onnya_s2', 131100, 'onnya_s2', 146000, NULL, NULL, 'vlog', 'life', 'middle', NULL, NULL, 400000, NULL, NULL, 'JFUN', NULL, '[부가설명] [260119라인회신]
 Instagram 릴 + 틱톡 + 유튜브 쇼츠 세트 40만엔', 'available', false, true),
(gen_random_uuid(), '유메피', 'W83Xl', 'W83Xl', NULL, NULL, NULL, NULL, NULL, 'W83Xl', 165000, 'base', 'beauty', 'middle', NULL, NULL, 400000, NULL, NULL, 'JFUN', 'kraft', '[부가설명] [260119라인회신]', 'available', false, true),
(gen_random_uuid(), '엠', 'm_loves_kcosme', 'm_loves_kcosme', 39000, NULL, NULL, NULL, NULL, NULL, NULL, 'color', 'beauty', 'micro', NULL, NULL, NULL, NULL, NULL, 'JFUN', '매니저', '[부가설명] [260119라인회신]', 'available', false, true),
(gen_random_uuid(), '슈', 'shushu_223_', 'shushu_223_', 218000, 'shushu_223_', 260700, 'shushu_223_', 212000, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, 800000, NULL, NULL, 'JFUN', '매니저', '[부가설명] [260313라인회신]
YouTube 쇼츠: 60만 엔
TikTok: 60만 엔
릴스: 80만 엔
디렉션·진행비: 5만 엔', 'available', false, true),
(gen_random_uuid(), '마슈하나', 'hanaaamarsh', 'hanaaamarsh', 62000, 'hanaaamarsh', 44000, NULL, NULL, NULL, NULL, 'base', 'beauty', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '매니저', '[부가설명] [260313라인회신]', 'available', false, true),
(gen_random_uuid(), '고우키', 'go_kkki_', 'go_kkki_', 306000, 'go_kkki_', NULL, NULL, NULL, 'go_kkki_', 59, 'fashion', 'fashion', 'mega', NULL, NULL, NULL, NULL, NULL, 'JFUN', '매니저', '[부가설명] [260313라인회신]', 'available', false, true),
(gen_random_uuid(), '후지타 미리아', 'miria_fujita', 'miria_fujita', 234000, 'miria_fujita', 45500, 'miria_fujita', 33200, 'miria_fujita', NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', '매니저', '[부가설명] [260313라인회신]', 'available', false, true),
(gen_random_uuid(), '이노우에 마이', 'mai_inoue', 'mai_inoue', 75000, 'mai_inoue', 1121, NULL, NULL, NULL, NULL, 'kidsmom', 'life', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] [260313라인회신]', 'available', false, true),
(gen_random_uuid(), '케빈Kevin', 'konnichiwakevin', 'konnichiwakevin', 46000, 'konnichiwakevin', 156200, 'konnichiwakevin', 20800, 'konnichiwakevin', 83, 'base', 'beauty', 'micro', NULL, 200000, 500000, 100000, NULL, 'JFUN', NULL, '[부가설명] [260401 DM 회신]
틱톡 80만엔
릴스 50만엔 
피드 20만엔 
스토리 10만엔
유튜브 쇼츠 30만엔 ( *릴스 전개에 경우 10만앤)', 'available', false, true),
(gen_random_uuid(), '코키', 'kooki_mensskincare', 'kooki_mensskincare', 86000, 'kooki_mensskincare', 99400, 'kooki_mensskincare', 96900, NULL, NULL, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, 'JFUN', NULL, '[부가설명] [260409 DM 회신

・YouTube 쇼츠 (91,220명)
・인스타 릴스 (86,000명)
・TikTok (95,000명)
＝총 팔로워 28만 명

위 3개 매체에 게시할 경우 50만 엔 이상

2개 매체일 경우 48만 엔
1개 매체일 경우 46만 엔

2차 활용 비용은 1개월 기준 5만 엔입니다.', 'available', false, true),
(gen_random_uuid(), '리카', 'ichirika_62', 'ichirika_62', 175000, 'ichirika_62', 31000, NULL, NULL, 'rika62dance', 125300, 'fashion', 'fashion', 'middle', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'available', false, true);

COMMIT;
