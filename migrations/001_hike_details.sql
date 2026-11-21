-- Existing club database: run this file in the Supabase SQL Editor before publishing index.html.
-- If an earlier version was already applied, rerun this file to add the new fields.
-- New installation: run setup.sql first, then this file.
begin;

alter table public.destinations
  add column if not exists meeting_time text not null default '',
  add column if not exists meeting_location text not null default '',
  add column if not exists trailhead_eta text not null default '',
  add column if not exists passenger_fee text not null default '',
  add column if not exists distance text not null default '',
  add column if not exists elevation_gain text not null default '',
  add column if not exists difficulty text not null default '',
  add column if not exists campus_return text not null default '',
  add column if not exists trail_url text not null default '',
  add column if not exists trailhead text not null default '';

create table if not exists public.non_carpooling_attendees (
  id uuid primary key default gen_random_uuid(),
  destination_id uuid not null references public.destinations(id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  phone text not null check (length(trim(phone)) > 0),
  created_at timestamptz not null default now()
);
alter table public.non_carpooling_attendees enable row level security;
drop policy if exists "read non-carpooling attendees" on public.non_carpooling_attendees;
create policy "read non-carpooling attendees" on public.non_carpooling_attendees for select using (true);
grant select on public.non_carpooling_attendees to anon, authenticated;

create or replace function public.register_non_carpooling(p_dest uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Name and phone number are required.';
  end if;
  insert into non_carpooling_attendees (destination_id, name, phone)
    values (p_dest, trim(p_name), trim(p_phone));
end $$;

create or replace function public.host_remove_attendee(p_pw text, p_attendee uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_host(p_pw);
  delete from non_carpooling_attendees where id = p_attendee;
end $$;

create or replace function public.host_edit_hike(
  p_pw text, p_dest uuid, p_name text, p_meeting_time text, p_passenger_fee text,
  p_distance text, p_elevation_gain text, p_difficulty text, p_campus_return text,
  p_trail_url text, p_trailhead text
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform assert_host(p_pw);
  if coalesce(trim(p_name), '') = '' then raise exception 'Enter a hike name.'; end if;
  if trim(p_trail_url) <> '' and trim(p_trail_url) !~* '^https?://[^[:space:]]+$' then
    raise exception 'Enter a trail link starting with https:// or http://.';
  end if;
  update destinations set name = trim(p_name), meeting_time = trim(p_meeting_time),
    passenger_fee = trim(p_passenger_fee), distance = trim(p_distance),
    elevation_gain = trim(p_elevation_gain), difficulty = trim(p_difficulty),
    campus_return = trim(p_campus_return), trail_url = trim(p_trail_url), trailhead = trim(p_trailhead)
    where id = p_dest;
  if not found then raise exception 'That hike no longer exists.'; end if;
end $$;

-- Older pages still call the original signature and preserve these two fields.
create or replace function public.host_edit_hike(
  p_pw text, p_dest uuid, p_name text, p_meeting_time text, p_passenger_fee text,
  p_distance text, p_elevation_gain text, p_difficulty text, p_campus_return text,
  p_trail_url text, p_trailhead text, p_meeting_location text, p_trailhead_eta text
) returns void language plpgsql security definer set search_path = public as $$
begin
  perform host_edit_hike(p_pw, p_dest, p_name, p_meeting_time, p_passenger_fee,
    p_distance, p_elevation_gain, p_difficulty, p_campus_return, p_trail_url, p_trailhead);
  update destinations set meeting_location = trim(p_meeting_location), trailhead_eta = trim(p_trailhead_eta)
    where id = p_dest;
end $$;

-- Serialize capacity changes, seat claims and waitlist promotions for the same hike.
-- A second request sees the first one's committed seats and passenger list.
create or replace function public.lock_carpool(p_dest uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_dest is null then return; end if;
  perform 1 from destinations where id = p_dest for no key update;
  if not found then raise exception 'That hike no longer exists.'; end if;
end $$;
revoke execute on function public.lock_carpool(uuid) from public, anon, authenticated;

create or replace function public.host_set_car_seats(p_pw text, p_car uuid, p_seats int)
returns void language plpgsql security definer set search_path = public as $$
declare d uuid; occupied int;
begin
  perform assert_host(p_pw);
  select destination_id into d from cars where id = p_car;
  if not found then raise exception 'That car no longer exists.'; end if;
  perform lock_carpool(d);
  if p_seats is null or p_seats not between 1 and 20 then
    raise exception 'Choose between 1 and 20 passenger seats.';
  end if;
  select count(*) into occupied from riders where car_id = p_car;
  if occupied > p_seats then
    raise exception 'Remove % passenger(s) from this car before reducing it to % seat(s).', occupied - p_seats, p_seats;
  end if;
  update cars set seats = p_seats where id = p_car;
  if not found then raise exception 'That car no longer exists.'; end if;
  perform fill_waitlist(d);
end $$;

-- Let a host free an occupied seat and retire it before automatic promotion fills it.
create or replace function public.host_kick_and_close_seat(p_pw text, p_rider uuid, p_car uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  perform assert_host(p_pw);
  select destination_id into d from cars where id = p_car;
  if not found then raise exception 'That car no longer exists.'; end if;
  perform lock_carpool(d);
  delete from riders where id = p_rider and car_id = p_car;
  if not found then raise exception 'This passenger is no longer in that car.'; end if;
  update cars set seats = seats - 1 where id = p_car and seats > 1;
  if not found then raise exception 'A car must keep at least one passenger seat.'; end if;
  perform fill_waitlist(d);
end $$;

create or replace function public.add_car(p_dest uuid, p_name text, p_phone text, p_seats int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform lock_carpool(p_dest);
  if length(trim(p_name)) = 0 or length(trim(p_phone)) = 0 then raise exception 'Name and phone are required'; end if;
  insert into cars (destination_id, driver_name, phone, seats)
    values (p_dest, trim(p_name), trim(p_phone), p_seats);
  perform fill_waitlist(p_dest);
end $$;

create or replace function public.join_car(p_car uuid, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
declare c cars%rowtype;
begin
  perform lock_carpool((select destination_id from cars where id = p_car));
  if length(trim(p_name)) = 0 or length(trim(p_phone)) = 0 then raise exception 'Name and phone are required'; end if;
  select * into c from cars where id = p_car for update;
  if not found then raise exception 'That car no longer exists'; end if;
  if (select count(*) from riders where car_id = c.id) >= c.seats then
    raise exception 'That car is full';
  end if;
  insert into riders (destination_id, car_id, name, phone)
    values (c.destination_id, c.id, trim(p_name), trim(p_phone));
end $$;

create or replace function public.join_waitlist(p_dest uuid, p_name text, p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform lock_carpool(p_dest);
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

create or replace function public.host_kick(p_pw text, p_rider uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  perform assert_host(p_pw);
  select destination_id into d from riders where id = p_rider;
  if not found then return; end if;
  perform lock_carpool(d);
  delete from riders where id = p_rider;
  perform fill_waitlist(d);
end $$;

create or replace function public.host_delete_car(p_pw text, p_car uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d uuid;
begin
  perform assert_host(p_pw);
  select destination_id into d from cars where id = p_car;
  if not found then return; end if;
  perform lock_carpool(d);
  delete from cars where id = p_car;
  perform fill_waitlist(d);
end $$;

grant execute on function public.register_non_carpooling(uuid, text, text),
  public.host_remove_attendee(text, uuid),
  public.host_edit_hike(text, uuid, text, text, text, text, text, text, text, text, text),
  public.host_edit_hike(text, uuid, text, text, text, text, text, text, text, text, text, text, text),
  public.host_set_car_seats(text, uuid, int),
  public.host_kick_and_close_seat(text, uuid, uuid) to anon, authenticated;

commit;
