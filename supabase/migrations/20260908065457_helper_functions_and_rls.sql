-- Role check that bypasses RLS so profile policies do not recurse
create or replace function public.is_admin(p_uid uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = p_uid
      and p.role = 'admin'
      and p.is_active
  );
$$;

-- True when at least one active admin account exists (first-run bootstrap)
create or replace function public.admin_exists()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p where p.role = 'admin' and p.is_active
  );
$$;

-- Promotes the caller to admin, but only while the org has no admin yet
create or replace function public.claim_first_admin()
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'You must be signed in.' using hint = 'not_authenticated';
  end if;

  -- Serialise concurrent bootstrap attempts
  perform pg_advisory_xact_lock(hashtext('claim_first_admin'));

  if public.admin_exists() then
    raise exception 'An administrator already exists for this organisation.'
      using hint = 'admin_already_exists';
  end if;

  update public.profiles
     set role = 'admin', is_active = true
   where id = v_uid
  returning * into v_row;

  return v_row;
end;
$$;

-- Great-circle distance in metres (Haversine)
create or replace function public.distance_meters(
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
)
returns double precision
language sql
immutable
as $$
  select 6371000.0 * 2.0 * asin(
    least(1.0, sqrt(
      power(sin(radians(p_lat2 - p_lat1) / 2.0), 2)
      + cos(radians(p_lat1)) * cos(radians(p_lat2))
        * power(sin(radians(p_lng2 - p_lng1) / 2.0), 2)
    ))
  );
$$;

-- Row level security
alter table public.profiles enable row level security;
alter table public.org_settings enable row level security;
alter table public.attendance enable row level security;

-- profiles: everyone sees themselves, admins see and manage everyone
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = auth.uid());

create policy profiles_select_admin on public.profiles
  for select to authenticated
  using (public.is_admin());

create policy profiles_update_self on public.profiles
  for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = (select p.role from public.profiles p where p.id = auth.uid()));

create policy profiles_update_admin on public.profiles
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy profiles_delete_admin on public.profiles
  for delete to authenticated
  using (public.is_admin() and id <> auth.uid());

-- org_settings: readable by any signed-in user (staff need the geofence), admin writable
create policy org_settings_select on public.org_settings
  for select to authenticated
  using (true);

create policy org_settings_update_admin on public.org_settings
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- attendance: read-only from the client. Writes go through clock_in/clock_out.
create policy attendance_select_self on public.attendance
  for select to authenticated
  using (user_id = auth.uid());

create policy attendance_select_admin on public.attendance
  for select to authenticated
  using (public.is_admin());

create policy attendance_delete_admin on public.attendance
  for delete to authenticated
  using (public.is_admin());
