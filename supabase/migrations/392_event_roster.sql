-- 392: 팝업 행사 승인자 명단 조회 (구글 시트 자동 수집용)
--
-- 왜 필요한가 — 구글 시트의 Apps Script 가 공개 키로 호출해 승인자 명단을 읽는다.
-- 공개 키는 사이트에 그대로 박혀 있으므로 이 함수는 스스로를 지켜야 한다:
--   ① 비밀 열쇠말(토큰)을 인자로 받아 sha256 해시를 함수 안의 값과 비교한다.
--      원문 토큰은 데이터베이스 어디에도 없다(해시만 있다).
--   ② 반환 항목에 전화·주소·이메일·페이팔은 넣지 않는다. 이름·SNS 계정·팔로워만.
--   ③ 감사용 계정(운영팀 시험 계정)은 제외한다.
--
-- ⚠️ o_app_id 를 돌려주는 이유 — 시트의 수동 관리 칸(비고·동행인원·안내 연락·현장 확인)을
--    갱신 때마다 제자리에 돌려놓으려면 행을 알아볼 고유 열쇠가 있어야 한다.
--    계정ID·이름으로 짝지으면 그 값이 바뀌는 순간 수동 기록이 엉뚱한 사람에게 붙는다.
--
-- ⚠️ 반환 컬럼에 o_ 접두어를 붙인 이유 — plpgsql 의 RETURNS TABLE 출력 이름이
--    influencers 의 실제 컬럼명(name, ig ...)과 같으면 42702(모호한 참조)로
--    첫 호출에서 터진다. 이 저장소가 2026-05-20 에 같은 함정을 겪었다.
drop function if exists public.get_event_roster(text, text);

create function public.get_event_roster(p_token text, p_campaign_no text)
returns table (
  o_app_id            uuid,
  o_applied_at        timestamptz,
  o_name              text,
  o_name_kanji        text,
  o_name_kana         text,
  o_primary_sns       text,
  o_ig                text,
  o_ig_followers      bigint,
  o_x                 text,
  o_x_followers       bigint,
  o_tiktok            text,
  o_tiktok_followers  bigint,
  o_youtube           text,
  o_youtube_followers bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $fn$
begin
  if encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
     <> 'cb0ee14914fc3405861b54eaec447b37ac16db1f121580e469b8e5a78cac9976' then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  return query
  select a.id, a.created_at,
         i.name::text, i.name_kanji::text, i.name_kana::text, i.primary_sns::text,
         i.ig::text,      i.ig_followers::bigint,
         i.x::text,       i.x_followers::bigint,
         i.tiktok::text,  i.tiktok_followers::bigint,
         i.youtube::text, i.youtube_followers::bigint
  from public.applications a
  join public.campaigns   c on c.id = a.campaign_id
  join public.influencers i on i.id = a.user_id
  where c.campaign_no = p_campaign_no
    and c.deleted_at is null
    and a.status = 'approved'
    and coalesce(i.is_audit, false) = false
  order by a.created_at;
end;
$fn$;

revoke all on function public.get_event_roster(text, text) from public;
grant execute on function public.get_event_roster(text, text) to anon, authenticated;
