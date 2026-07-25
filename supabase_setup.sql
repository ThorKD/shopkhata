-- ShopKhata: run this entire file once in Supabase SQL Editor
-- (Dashboard -> SQL Editor -> New query -> paste all of this -> Run)

create extension if not exists pgcrypto;

create table people (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table items (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  price integer not null default 0,
  created_at timestamptz not null default now()
);

create table guests (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

-- person_id may point to people.id or guests.id (cast to text). Deliberately
-- not foreign-keyed to either -- matches the app's existing loose validation.
create table present (
  person_id text primary key,
  marked_at timestamptz not null default now()
);

-- Hottest table: one row per tap. Atomic INSERT/DELETE = no lost updates.
create table cart_entries (
  id uuid primary key default gen_random_uuid(),
  item_id uuid references items(id) on delete set null,
  item_name text not null,
  price integer not null,
  person_id text not null,
  created_at timestamptz not null default now()
);

create table sessions (
  id uuid primary key default gen_random_uuid(),
  settled_at timestamptz not null default now(),
  total integer not null,
  entries jsonb not null,
  splits jsonb not null   -- [{personId, name, amount, extra}]
);

create table app_settings (
  id boolean primary key default true check (id),
  round_unit integer not null default 5,
  updated_at timestamptz not null default now()
);
insert into app_settings (id, round_unit) values (true, 5);

create index cart_entries_created_at_idx on cart_entries (created_at);
create index sessions_settled_at_idx on sessions (settled_at);

-- Seed data mirrors current ROSTER / default items exactly
insert into people (name) values
  ('Kundendu S.'), ('Prashant T.'), ('Abhishek V.'), ('Amit P.'), ('Amit M.'),
  ('Anupam B.'), ('K Abhishek'), ('Kumar M.'), ('Mihir R.'), ('Rohit R.'),
  ('Ronak'), ('Secular S.'), ('Shivashish'), ('Vinayak');

insert into items (name, price) values
  ('Cigarette', 25), ('Water', 20), ('Lassi', 30), ('Chaas', 20), ('Tea', 10),
  ('Gogo', 20), ('Soft Drink', 30), ('Rajnigandha', 20), ('Tulsi', 5), ('Snacks', 40);

-- Settle RPC: serializes concurrent settles via advisory lock, aborts with a
-- named error if the cart changed underneath the caller (stale total) or was
-- already settled by another phone (empty cart).
create or replace function settle_current_sitting(p_expected_total integer, p_splits jsonb)
returns table(session_id uuid)
language plpgsql
as $$
declare
  v_total integer;
  v_entries jsonb;
  v_new_id uuid;
begin
  perform pg_advisory_xact_lock(hashtext('shopkhata_settle'));

  select coalesce(sum(price), 0) into v_total from cart_entries;

  if v_total = 0 then
    raise exception 'NOTHING_TO_SETTLE';
  end if;

  if v_total <> p_expected_total then
    raise exception 'STALE_TOTAL';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'itemId', item_id, 'name', item_name,
      'price', price, 'personId', person_id,
      'ts', floor(extract(epoch from created_at) * 1000)
    ) order by created_at), '[]'::jsonb)
  into v_entries
  from cart_entries;

  insert into sessions (settled_at, total, entries, splits)
  values (now(), v_total, v_entries, p_splits)
  returning id into v_new_id;

  delete from cart_entries;
  delete from present;
  delete from guests;

  return query select v_new_id;
end;
$$;
grant execute on function settle_current_sitting(integer, jsonb) to anon;

-- Guest add/remove touch two tables at once; wrap in RPCs for atomicity.
create or replace function add_guest(p_name text)
returns uuid language plpgsql as $$
declare v_id uuid;
begin
  insert into guests(name) values (p_name) returning id into v_id;
  insert into present(person_id) values (v_id::text);
  return v_id;
end; $$;
grant execute on function add_guest(text) to anon;

create or replace function remove_guest(p_id uuid)
returns void language plpgsql as $$
begin
  delete from present where person_id = p_id::text;
  delete from guests where id = p_id;
end; $$;
grant execute on function remove_guest(uuid) to anon;

-- Separate reset actions, matching the two-tier Danger Zone UX.
create or replace function reset_current_sitting()
returns void language plpgsql as $$
begin
  delete from cart_entries;
  delete from present;
  delete from guests;
end; $$;
grant execute on function reset_current_sitting() to anon;

create or replace function erase_all_history()
returns void language plpgsql as $$
begin
  delete from sessions;
end; $$;
grant execute on function erase_all_history() to anon;

-- RLS: fully open to anon, matching the app's existing no-login trust model.
alter table people        enable row level security;
alter table items         enable row level security;
alter table guests        enable row level security;
alter table present       enable row level security;
alter table cart_entries  enable row level security;
alter table sessions      enable row level security;
alter table app_settings  enable row level security;

create policy "anon full access" on people        for all to anon using (true) with check (true);
create policy "anon full access" on items         for all to anon using (true) with check (true);
create policy "anon full access" on guests        for all to anon using (true) with check (true);
create policy "anon full access" on present       for all to anon using (true) with check (true);
create policy "anon full access" on cart_entries  for all to anon using (true) with check (true);
create policy "anon full access" on sessions      for all to anon using (true) with check (true);
create policy "anon full access" on app_settings  for all to anon using (true) with check (true);

-- Realtime: push changes to all connected clients
alter publication supabase_realtime add table
  people, items, guests, present, cart_entries, sessions, app_settings;
