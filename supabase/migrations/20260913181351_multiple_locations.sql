-- Multiple clock-in locations: replace the single org_settings geofence with a
-- locations table. Staff pick which in-range site they are at, may visit more
-- than once per day, and clock out from anywhere.

-- ---------------------------------------------------------------------------
-- locations
-- ---------------------------------------------------------------------------

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  lat double precision not null,
  lng double precision not null,
  radius_meters integer not null default 100
    constraint locations_radius_range check (radius_meters between 10 and 5000),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint locations_name_not_blank check (btrim(name) <> ''),
  constraint locations_lat_range check (lat between -90 and 90),
  constraint locations_lng_range check (lng between -180 and 180)
);

create index locations_active_idx on public.locations (is_active)
  where is_active;

alter table public.locations enable row level security;

create policy locations_select on public.locations
  for select to authenticated
  using (true);

create policy locations_insert_admin on public.locations
  for insert to authenticated
  with check (public.is_admin());

create policy locations_update_admin on public.locations
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

revoke all on public.locations from anon;
revoke delete on public.locations from authenticated;

-- ---------------------------------------------------------------------------
-- Seed from the existing org geofence (if configured)
-- ---------------------------------------------------------------------------

insert into public.locations (name, lat, lng, radius_meters)
select
  coalesce(nullif(btrim(s.location_name), ''), 'Main Site'),
  s.geofence_lat,
  s.geofence_lng,
  s.radius_meters
from public.org_settings s
where s.id
  and s.geofence_lat is not null
  and s.geofence_lng is not null;

-- ---------------------------------------------------------------------------
-- attendance: which site, multi-visit per day
-- ---------------------------------------------------------------------------

alter table public.attendance
  add column location_id uuid references public.locations (id),
  add column location_name text;

update public.attendance a
   set location_id = l.id,
       location_name = l.name
  from public.locations l
 where a.location_id is null
   and (select count(*) from public.locations) = 1;

alter table public.attendance
  drop constraint if exists attendance_one_per_day;

create unique index attendance_one_open_shift
  on public.attendance (user_id)
  where clock_out_at is null;

-- ---------------------------------------------------------------------------
-- Drop geofence columns from org_settings (keep accuracy + verification)
-- ---------------------------------------------------------------------------

create or replace function public.validate_org_settings()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from pg_catalog.pg_timezone_names tz where tz.name = new.timezone
  ) then
    raise exception 'Unknown timezone: %', new.timezone using hint = 'invalid_timezone';
  end if;

  new.updated_by := coalesce(auth.uid(), new.updated_by);

  return new;
end;
$$;

alter table public.org_settings
  drop column if exists location_name,
  drop column if exists geofence_lat,
  drop column if exists geofence_lng,
  drop column if exists radius_meters,
  drop column if exists allow_clock_out_outside_geofence;

-- ---------------------------------------------------------------------------
-- Location validation trigger
-- ---------------------------------------------------------------------------

create or replace function public.validate_location()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.name := btrim(new.name);
  if new.name = '' then
    raise exception 'A location needs a name.' using hint = 'invalid_name';
  end if;

  if new.lat < -90 or new.lat > 90 or new.lng < -180 or new.lng > 180 then
    raise exception 'Location coordinates are out of range.'
      using hint = 'invalid_coordinates';
  end if;

  if new.radius_meters < 10 or new.radius_meters > 5000 then
    raise exception 'Radius must be between 10 and 5000 metres.'
      using hint = 'invalid_radius';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger locations_validate
before insert or update on public.locations
for each row
execute function public.validate_location();

revoke all on function public.validate_location() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- clock_in: requires a chosen location_id
-- ---------------------------------------------------------------------------

drop function if exists public.clock_in(
  double precision, double precision, double precision, text
);

create or replace function public.clock_in(
  p_lat double precision,
  p_lng double precision,
  p_location_id uuid,
  p_accuracy_meters double precision default null,
  p_selfie_path text default null
)
returns public.attendance
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_profile public.profiles;
  v_settings public.org_settings;
  v_location public.locations;
  v_distance double precision;
  v_work_date date;
  v_row public.attendance;
  v_selfie_created timestamptz;
  v_selfie_verified boolean := false;
  v_passkey_verified boolean := false;
begin
  if v_uid is null then
    raise exception 'You must be signed in to clock in.' using hint = 'not_authenticated';
  end if;

  select * into v_profile from public.profiles p where p.id = v_uid;
  if not found then
    raise exception 'No staff profile found for this account.' using hint = 'no_profile';
  end if;
  if not v_profile.is_active then
    raise exception 'This account has been deactivated. Contact your administrator.'
      using hint = 'account_inactive';
  end if;

  select * into v_settings from public.org_settings s where s.id;

  if not exists (
    select 1 from public.locations loc where loc.is_active
  ) then
    raise exception 'No clock-in locations have been set up yet. Contact your administrator.'
      using hint = 'geofence_not_configured';
  end if;

  if p_location_id is null then
    raise exception 'Choose which location you are clocking in at.'
      using hint = 'missing_location';
  end if;

  select * into v_location
    from public.locations loc
   where loc.id = p_location_id;

  if not found or not v_location.is_active then
    raise exception 'That clock-in location is no longer available. Pick another one.'
      using hint = 'location_inactive';
  end if;

  if p_lat is null or p_lng is null then
    raise exception 'Your location could not be determined.' using hint = 'missing_location';
  end if;

  if p_lat < -90 or p_lat > 90 or p_lng < -180 or p_lng > 180 then
    raise exception 'The reported location is not valid.' using hint = 'invalid_location';
  end if;

  if v_settings.max_accuracy_meters is not null
     and p_accuracy_meters is not null
     and p_accuracy_meters > v_settings.max_accuracy_meters then
    raise exception 'Your location is only accurate to %m. Move somewhere with a better signal and try again.',
      round(p_accuracy_meters)
      using hint = 'poor_accuracy';
  end if;

  v_distance := public.distance_meters(
    p_lat, p_lng, v_location.lat, v_location.lng
  );

  if v_distance > v_location.radius_meters then
    raise exception 'You are %m from %, which is outside the % m clock-in zone.',
      round(v_distance), v_location.name, v_location.radius_meters
      using hint = 'outside_geofence';
  end if;

  if exists (
    select 1 from public.attendance a
     where a.user_id = v_uid and a.clock_out_at is null
  ) then
    raise exception 'You are already on shift. Clock out before starting another visit.'
      using hint = 'already_on_shift';
  end if;

  v_passkey_verified := public.has_fresh_passkey_auth(v_settings.passkey_freshness_seconds);

  if v_settings.require_passkey and not v_passkey_verified then
    raise exception 'Passkey verification is required to clock in.'
      using hint = 'passkey_required';
  end if;

  if coalesce(btrim(coalesce(p_selfie_path, '')), '') <> '' then
    if p_selfie_path not like (v_uid::text || '/%') then
      raise exception 'The submitted photo does not belong to this account.'
        using hint = 'invalid_selfie_path';
    end if;

    select o.created_at into v_selfie_created
      from storage.objects o
     where o.bucket_id = 'selfies'
       and o.name = p_selfie_path;

    if v_selfie_created is null then
      raise exception 'Your photo did not finish uploading. Please take it again.'
        using hint = 'selfie_missing';
    end if;

    if now() - v_selfie_created > interval '2 minutes' then
      raise exception 'That photo was not taken just now. Please take a new one.'
        using hint = 'selfie_stale';
    end if;

    v_selfie_verified := true;
  elsif v_settings.require_selfie then
    raise exception 'A live photo is required to clock in.' using hint = 'selfie_required';
  end if;

  v_work_date := (now() at time zone v_settings.timezone)::date;

  insert into public.attendance (
    user_id, work_date, location_id, location_name,
    clock_in_at, clock_in_lat, clock_in_lng,
    clock_in_distance_meters, clock_in_accuracy_meters,
    selfie_path, verified_with_selfie, verified_with_passkey
  )
  values (
    v_uid, v_work_date, v_location.id, v_location.name,
    now(), p_lat, p_lng,
    v_distance, p_accuracy_meters,
    nullif(btrim(coalesce(p_selfie_path, '')), ''),
    v_selfie_verified,
    v_passkey_verified
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'You are already on shift. Clock out before starting another visit.'
      using hint = 'already_on_shift';
end;
$$;

revoke all on function public.clock_in(
  double precision, double precision, uuid, double precision, text
) from public, anon;
grant execute on function public.clock_in(
  double precision, double precision, uuid, double precision, text
) to authenticated;

-- ---------------------------------------------------------------------------
-- clock_out: open visit only, no geofence
-- ---------------------------------------------------------------------------

create or replace function public.clock_out(
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_meters double precision default null
)
returns public.attendance
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.attendance;
  v_distance double precision;
begin
  if v_uid is null then
    raise exception 'You must be signed in to clock out.' using hint = 'not_authenticated';
  end if;

  select * into v_row
    from public.attendance a
   where a.id = (
     select a2.id
       from public.attendance a2
      where a2.user_id = v_uid
        and a2.clock_out_at is null
      order by a2.clock_in_at desc
      limit 1
   )
   for update;

  if not found then
    raise exception 'You are not on shift right now.' using hint = 'not_clocked_in';
  end if;

  -- Optional distance from the visit's site, for the record only. Never blocks.
  if p_lat is not null and p_lng is not null and v_row.location_id is not null then
    select public.distance_meters(p_lat, p_lng, loc.lat, loc.lng)
      into v_distance
      from public.locations loc
     where loc.id = v_row.location_id;
  end if;

  update public.attendance a
     set clock_out_at = now(),
         clock_out_lat = p_lat,
         clock_out_lng = p_lng,
         clock_out_distance_meters = v_distance,
         clock_out_accuracy_meters = p_accuracy_meters
   where a.id = v_row.id
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on function public.clock_out(
  double precision, double precision, double precision
) from public, anon;
grant execute on function public.clock_out(
  double precision, double precision, double precision
) to authenticated;

-- ---------------------------------------------------------------------------
-- Today helpers: all visits + the open one
-- ---------------------------------------------------------------------------

drop function if exists public.my_today_attendance();

create or replace function public.my_today_attendance()
returns setof public.attendance
language sql
stable
security definer
set search_path = ''
as $$
  select a.*
    from public.attendance a
   where a.user_id = auth.uid()
     and a.work_date = public.org_today()
   order by a.clock_in_at desc;
$$;

create or replace function public.my_open_attendance()
returns public.attendance
language sql
stable
security definer
set search_path = ''
as $$
  select a.*
    from public.attendance a
   where a.user_id = auth.uid()
     and a.clock_out_at is null
   order by a.clock_in_at desc
   limit 1;
$$;

revoke all on function public.my_today_attendance() from public, anon;
revoke all on function public.my_open_attendance() from public, anon;
grant execute on function public.my_today_attendance() to authenticated;
grant execute on function public.my_open_attendance() to authenticated;
