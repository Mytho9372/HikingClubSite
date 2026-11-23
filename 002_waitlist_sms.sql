-- Run in the Supabase SQL Editor AFTER setup.sql and 001_hike_details.sql, and BEFORE publishing the new index.html.
-- Sends each waitlisted person exactly one text, at the moment they move off the waitlist into a car.
begin;

alter table public.riders add column if not exists sms_consent boolean not null default false;

-- Outbox of texts. The website can never read or write it; only the database functions and the Edge Function can.
-- unique (rider_id) guarantees one text per person, ever.
create table if not exists public.sms_queue (
  id uuid primary key default gen_random_uuid(),
  rider_id uuid unique references public.riders(id) on delete cascade,
  phone text not null,
  body text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  error text
);
alter table public.sms_queue enable row level security;

-- Same promotion logic as before, plus: queue one text for each consenting rider who just got a seat.
create or replace function public.fill_waitlist(p_dest uuid) returns void
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
      insert into sms_queue (rider_id, phone, body)
        select r.id, r.phone,
               'Hiking Club: a seat opened up for ' || d.name || '! You are in '
               || coalesce(cr.driver_name, 'a driver') || '''s car. Check the carpool page for meeting details. Reply STOP to opt out.'
        from riders r
        join destinations d on d.id = r.destination_id
        join cars cr on cr.id = r.car_id
        where r.id = w and r.sms_consent and r.phone is not null
        on conflict (rider_id) do nothing;
    end loop;
  end loop;
end $$;
revoke execute on function public.fill_waitlist(uuid) from public, anon, authenticated;

-- Joining the waitlist now requires agreeing to the one-time text.
drop function if exists public.join_waitlist(uuid, text, text);
create or replace function public.join_waitlist(p_dest uuid, p_name text, p_phone text, p_sms_consent boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform lock_carpool(p_dest);
  perform check_signup_contact(null, p_name, p_phone);
  if p_sms_consent is distinct from true then
    raise exception 'Please agree to receive one text message when a seat opens up.';
  end if;
  if not exists (select 1 from cars where destination_id = p_dest) then
    raise exception 'No drivers yet. Wait for a driver to sign up';
  end if;
  if exists (select 1 from cars c where c.destination_id = p_dest
             and (select count(*) from riders r where r.car_id = c.id) < c.seats) then
    raise exception 'A car still has open seats';
  end if;
  insert into riders (destination_id, car_id, name, phone, sms_consent)
    values (p_dest, null, trim(p_name), trim(p_phone), true);
end $$;
grant execute on function public.join_waitlist(uuid, text, text, boolean) to anon, authenticated;

commit;
