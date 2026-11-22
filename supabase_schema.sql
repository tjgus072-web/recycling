-- =====================================================================
-- 바른분리 · Supabase(PostgreSQL) 데이터베이스 스키마
-- 사용법: Supabase 대시보드 > SQL Editor 에 전체를 붙여넣고 Run (처음 한 번만)
-- 구성: 1 ENUM / 2 공용 데이터 / 3 회원 데이터 / 4 함수·트리거 / 5 보안(RLS) / 6 샘플 데이터
-- =====================================================================

-- ---------- 1. ENUM (정해진 값만 들어가게 하는 타입) ----------
create type waste_category as enum ('recycle', 'general', 'food', 'special'); -- 재활용/일반/음식물/특수
create type point_type     as enum ('clothes', 'appliance', 'battery');       -- 의류/소형가전/종이팩·폐건전지
create type user_role      as enum ('member', 'admin');
create type label_source   as enum ('image', 'text', 'barcode');
create type label_status   as enum ('pending', 'done');

create extension if not exists pg_trgm;  -- 비슷한 품목 검색(유사도)용

-- ---------- 2. 공용 데이터 (누구나 읽기, 관리자만 쓰기) ----------

-- 지자체(지역) 정보
create table regions (
  id               text primary key,                 -- 예: 'gangnam', 'gunsan'
  name             text not null unique,             -- 예: '전북특별자치도 군산시'
  lat              double precision,                 -- 지역 중심 좌표(선택)
  lng              double precision,
  bag_rule         text not null default '',         -- 종량제 봉투 규칙
  note             text not null default '',         -- 참고 메모(미수거일, 문의처 등)
  data_source      text,                             -- 예: '행정안전부 생활쓰레기배출정보'
  data_updated_at  date,
  created_at       timestamptz not null default now()
);

-- 지역별 배출 요일·시간 (지역 1개 x 분류 3개)
create table region_schedules (
  region_id  text not null references regions(id) on delete cascade,
  category   waste_category not null check (category <> 'special'),
  days       smallint[] not null default '{}',       -- 0=일, 1=월, ... 6=토
  time_text  text not null default '',               -- 예: '18:00~24:00'
  primary key (region_id, category),
  check (days <@ array[0,1,2,3,4,5,6]::smallint[])
);

-- 품목 (검색의 중심 테이블)
create table items (
  id                text primary key,                -- 예: 'hetbahn'
  name              text not null,
  aliases           text[] not null default '{}',    -- 다른 이름(검색용)
  category          waste_category not null,
  material          text not null default '-',
  steps             text[] not null,                 -- 3단계 분리배출 가이드
  warnings          text[] not null default '{}',    -- 헷갈리기 쉬운 주의사항
  dirty_to_general  boolean not null default false,  -- 이물질이 안 지워지면 일반쓰레기
  is_tricky         boolean not null default false,  -- 퀴즈에 자주 출제
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (cardinality(steps) between 1 and 3)
);
create index items_aliases_gin on items using gin (aliases);
create index items_name_trgm   on items using gin (name gin_trgm_ops);

-- 바코드 -> 용기 재질/품목
create table barcodes (
  code      text primary key check (code ~ '^[0-9]{8,14}$'),
  product   text not null,
  material  text not null,
  item_id   text references items(id) on delete set null
);

-- 수거함 위치 (공공데이터 CSV/JSON 가져오기 결과)
create table collection_points (
  id         uuid primary key default gen_random_uuid(),
  region_id  text references regions(id) on delete set null,
  type       point_type not null,
  name       text not null,
  address    text,
  lat        double precision not null check (lat between 33 and 39),
  lng        double precision not null check (lng between 124 and 132),
  source     text not null default 'manual',         -- manual | csv | demo
  created_at timestamptz not null default now()
);
create index collection_points_type on collection_points (type);
create index collection_points_geo  on collection_points (lat, lng);

-- ---------- 3. 회원 데이터 (본인 것만 읽고 쓰기) ----------

-- 회원 프로필 (로그인 정보 auth.users 와 1:1)
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null default '회원',
  role       user_role not null default 'member',
  region_id  text references regions(id) on delete set null,
  created_at timestamptz not null default now()
);

-- 즐겨찾기
create table favorites (
  user_id    uuid not null references profiles(id) on delete cascade,
  item_id    text not null references items(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

-- 분리배출 기록 ("오늘 버렸어요")
create table disposal_logs (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references profiles(id) on delete cascade,
  item_id      text references items(id) on delete set null,
  category     waste_category not null,              -- 기록 당시 분류(통계용)
  disposed_at  timestamptz not null default now()
);
create index disposal_logs_user_time on disposal_logs (user_id, disposed_at desc);

-- 퀴즈에서 틀린 품목
create table quiz_wrong_items (
  user_id        uuid not null references profiles(id) on delete cascade,
  item_id        text not null references items(id) on delete cascade,
  wrong_count    int not null default 1,
  last_wrong_at  timestamptz not null default now(),
  primary key (user_id, item_id)
);

-- 동네 배출일 알림 설정 (분류별 켜기/끄기)
create table notification_settings (
  user_id   uuid not null references profiles(id) on delete cascade,
  category  waste_category not null check (category <> 'special'),
  enabled   boolean not null default true,
  primary key (user_id, category)
);

-- 관리자 레이블링 대기열 (AI가 못 알아본 사진, 검색 결과 없던 검색어, 미등록 바코드)
create table labeling_queue (
  id             bigint generated always as identity primary key,
  source         label_source not null,
  text_value     text not null default '',           -- 검색어, 바코드 번호, AI가 본 이름
  image_path     text,                               -- Storage 버킷 경로(선택)
  status         label_status not null default 'pending',
  label_item_id  text references items(id) on delete set null,
  created_by     uuid references profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);
create index labeling_queue_status on labeling_queue (status, created_at desc);

-- ---------- 4. 함수·트리거 ----------

-- 관리자 여부 (RLS 정책에서 사용)
create function is_admin() returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

-- 회원가입 시 프로필과 기본 알림 설정을 자동 생성
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, nickname)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'nickname', '회원'));
  insert into notification_settings (user_id, category)
  select new.id, c from unnest(array['recycle','general','food']::waste_category[]) as c;
  return new;
end $$;
create trigger on_auth_user_created
  after insert on auth.users for each row execute function handle_new_user();

-- items.updated_at 자동 갱신
create function touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
create trigger items_touch before update on items
  for each row execute function touch_updated_at();

-- 내 위치 주변 수거함 (가까운 순). 앱에서: supabase.rpc('nearby_points', {p_lat, p_lng, p_type, p_limit})
create function nearby_points(
  p_lat double precision, p_lng double precision,
  p_type point_type default null, p_limit int default 12
) returns table (
  out_id uuid, out_type point_type, out_name text,
  out_lat double precision, out_lng double precision, distance_km double precision
) language sql stable as $$
  select cp.id, cp.type, cp.name, cp.lat, cp.lng,
         6371 * 2 * asin(sqrt(
           power(sin(radians(cp.lat - p_lat) / 2), 2) +
           cos(radians(p_lat)) * cos(radians(cp.lat)) *
           power(sin(radians(cp.lng - p_lng) / 2), 2)
         )) as distance_km
  from collection_points cp
  where p_type is null or cp.type = p_type
  order by distance_km
  limit p_limit;
$$;

-- ---------- 5. 보안 (Row Level Security) ----------
alter table regions               enable row level security;
alter table region_schedules      enable row level security;
alter table items                 enable row level security;
alter table barcodes              enable row level security;
alter table collection_points     enable row level security;
alter table profiles              enable row level security;
alter table favorites             enable row level security;
alter table disposal_logs         enable row level security;
alter table quiz_wrong_items      enable row level security;
alter table notification_settings enable row level security;
alter table labeling_queue        enable row level security;

-- 공용 데이터: 누구나 읽기 / 관리자만 쓰기
create policy "공개 읽기" on regions           for select using (true);
create policy "공개 읽기" on region_schedules  for select using (true);
create policy "공개 읽기" on items             for select using (true);
create policy "공개 읽기" on barcodes          for select using (true);
create policy "공개 읽기" on collection_points for select using (true);

create policy "관리자 쓰기" on regions           for all using (is_admin()) with check (is_admin());
create policy "관리자 쓰기" on region_schedules  for all using (is_admin()) with check (is_admin());
create policy "관리자 쓰기" on items             for all using (is_admin()) with check (is_admin());
create policy "관리자 쓰기" on barcodes          for all using (is_admin()) with check (is_admin());
create policy "관리자 쓰기" on collection_points for all using (is_admin()) with check (is_admin());

-- 프로필: 본인(또는 관리자)만 읽기, 본인만 수정(role 은 수정 불가)
create policy "본인 프로필 읽기" on profiles for select using (id = auth.uid() or is_admin());
create policy "본인 프로필 수정" on profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on profiles from authenticated, anon;
grant  update (nickname, region_id) on profiles to authenticated;

-- 회원 데이터: 본인 행만
create policy "본인 즐겨찾기" on favorites             for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "본인 배출 기록" on disposal_logs         for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "본인 퀴즈 오답" on quiz_wrong_items      for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "본인 알림 설정" on notification_settings for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 레이블링 대기열: 누구나 등록(대기 상태만), 읽기·처리는 관리자만
create policy "대기열 등록"   on labeling_queue for insert with check (status = 'pending');
create policy "관리자 처리"   on labeling_queue for all using (is_admin()) with check (is_admin());

-- ---------- 6. 샘플 데이터 (동작 확인용, 필요한 만큼 더 추가) ----------
insert into regions (id, name, lat, lng, bag_rule, note, data_source) values
  ('gunsan', '전북특별자치도 군산시', 35.9676, 126.7366, '군산시 종량제 봉투를 사용해요.', '샘플 데이터예요.', '샘플');

insert into region_schedules (region_id, category, days, time_text) values
  ('gunsan', 'recycle', '{1,4}', '18:00~24:00'),
  ('gunsan', 'general', '{0,2,4}', '18:00~24:00'),
  ('gunsan', 'food',    '{0,1,2,3,4,5,6}', '18:00~24:00');

insert into items (id, name, aliases, category, material, steps, warnings, dirty_to_general, is_tricky) values
  ('hetbahn', '햇반 용기', '{즉석밥 용기,햇반,즉석밥}', 'recycle', 'PP(플라스틱)',
   '{"남은 밥알을 털고 물로 헹구기","겉면 종이 띠지와 비닐 필름 떼기","플라스틱류로 배출하기"}',
   '{"이물질이 지워지지 않으면 일반쓰레기로 버리세요"}', true, false),
  ('chicken', '치킨 뼈', '{닭뼈,갈비뼈,생선뼈}', 'general', 'Bone',
   '{"남은 살과 양념 정리하기","물기를 빼기","종량제 봉투에 담아 배출하기"}',
   '{"뼈는 딱딱해서 음식물쓰레기가 아니에요"}', false, true);

insert into barcodes (code, product, material, item_id) values
  ('8800000000011', '즉석밥 210g (데모)', 'PP', 'hetbahn');

-- ---------- 관리자 지정 방법 (가입 후 SQL Editor 에서 1회 실행) ----------
-- update profiles set role = 'admin' where id = '여기에-내-사용자-UUID';
-- (UUID 는 Authentication > Users 에서 확인)
