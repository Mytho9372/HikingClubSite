-- Run this whole file once in Supabase: SQL Editor -> New query -> paste -> Run.

create table destinations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table cars (
  id uuid primary key default gen_random_uuid(),
  destination_id uuid not null references destinations(id) on delete cascade,
  driver_name text not null,
  phone text not null,
  seats int not null check (seats between 1 and 20),
  created_at timestamptz not null default now()
);

-- A rider with car_id = null is on the waitlist (oldest created_at = top of list).
create table riders (
  id uuid primary key default gen_random_uuid(),
  destination_id uuid not null references destinations(id) on delete cascade,
  car_id uuid references cars(id) on delete set null,
  name text not null,
  phone text not null,
  highlighted boolean not null default false,
  created_at timestamptz not null default now()
);

-- Host password lives here. Nobody can read this table from the website.
create table host_config (password text not null);
insert into host_config values ('Hiking2026!');

alter table destinations enable row level security;
alter table cars enable row level security;
alter table riders enable row level security;
alter table host_config enable row level security;

-- Website visitors may read the public tables. All writing goes through the functions below.
create policy "read destinations" on destinations for select using (true);
create policy "read cars" on cars for select using (true);
create policy "read riders" on riders for select using (true);

-- ---------- helpers (not callable from the website) ----------
create function assert_host(p_pw text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from host_config where password = p_pw) then
    raise exception 'Wrong host password';
  end if;
end $$;

-- Moves the top of the waitlist into any open seats and highlights them.
create function fill_waitlist(p_dest uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c record; w uuid;
begin
  for c in select id, seats from cars where destination_id = p_dest order by created_at loop
    while (select count(*) from riders where car_id = c.id) < c.seats loop
      select id into w from riders
        where destination_id = p_dest and car_id is null
        order by created_at limit 1;
      exit when w is null;
      update riders set car_id = c.id, highlighted = true where id = w;
    end loop;
  end loop;
end $$;

revoke execute on function assert_host(text) from public, anon, authenticated;
revoke execute on function fill_waitlist(uuid) from public, anon, authenticated;

-- ---------- public actions ----------
create function add_car(p_dest uuid, p_name text, p_phone text, p_seats int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(trim(p_name)) = 0 or length(trim(p_phone)) = 0 then raise exception 'Name and phone are required'; end if;
  insert into cars (destination_id, driver_name, phone, seats)
    values (p_dest, trim(p_name), trim(p_phone), p_seats);
  perform fill_waitlist(p_dest);
end $$;

create function join_car(p_car uuid, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
declare c cars%rowtype;
begin
  if length(trim(p_name)) = 0 or length(trim(p_phone)) = 0 then raise exception 'Name and phone are required'; end if;
  select * into c from cars where id = p_car for update;
  if not found then raise exception 'That car no longer exists'; end if;
  if (select count(*) from riders where car_id = c.id) >= c.seats then
    raise exception 'That car is full';
  end if;
  insert into riders (destination_id, car_id, name, phone)
    values (c.destination_id, c.id, trim(p_name), trim(p_phone));
end $$;

create function join_waitlist(p_dest uuid, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if length(trim(p_name)) = 0 or length(trim(p_phone)) = 0 then raise exception 'Name and phone are required'; end if;
  if not exists (select 1 from cars where destination_id = p_dest) then
    raise exception 'No drivers yet. Wait for a driver to sign up';
  end if;
  if exists (select 1 from cars c where c.destination_id = p_dest
             and (select count(*) from riders r where r.car_id = c.id) < c.seats) then
    raise exception 'A car still has open seats';
  end if;
  insert into riders (destination_id, car_id, name, phone)
    values (p_dest, null, trim(p_name), trim(p_phone));
end $$;

-- ---------- host actions (password checked on the server) ----------
create function host_login(p_pw text) returns boolean
language sql security definer set search_path = public as $$
  select exists (select 1 from host_config where password = p_pw);
$$;

create function host_add_destination(p_pw text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_host(p_pw);
  insert into destinations (name) values (trim(p_name));
end $$;

create function host_delete_destination(p_pw text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_host(p_pw);
  delete from destinations where id = p_id;
end $$;

create function host_toggle_highlight(p_pw text, p_rider uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform assert_host(p_pw);
  update riders set highlighted = not highlighted where id = p_rider;
end $$;

-- Removes a rider (from a car or the waitlist); the top of the waitlist takes any freed seat, highlighted.
create function host_kick(p_pw text, p_rider uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  perform assert_host(p_pw);
  select destination_id into d from riders where id = p_rider;
  delete from riders where id = p_rider;
  if d is not null then perform fill_waitlist(d); end if;
end $$;

-- Removes a car; its riders go to the waitlist (or into other open seats, highlighted).
create function host_delete_car(p_pw text, p_car uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  perform assert_host(p_pw);
  select destination_id into d from cars where id = p_car;
  delete from cars where id = p_car;
  if d is not null then perform fill_waitlist(d); end if;
end $$;
