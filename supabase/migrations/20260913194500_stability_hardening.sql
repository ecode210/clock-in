-- Stability hardening: enforce password / accuracy rules in RPCs, revoke
-- silent attendance deletes, and expose admin summary RPCs that stay correct
-- past PostgREST row caps and overnight open shifts.

-- ---------------------------------------------------------------------------
-- clock_in: must_change_password + required accuracy
-- ---------------------------------------------------------------------------

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
  if v_profile.must_change_password then
    raise exception 'Replace your temporary password before clocking in.'
      using hint = 'must_change_password';
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

  if v_settings.max_accuracy_meters is not null then
    if p_accuracy_meters is null then
      raise exception 'Your location accuracy could not be verified. Try again near a window or outdoors.'
        using hint = 'missing_accuracy';
    elsif p_accuracy_meters > v_settings.max_accuracy_meters then
      raise exception 'Your location is only accurate to %m. Move somewhere with a better signal and try again.',
        round(p_accuracy_meters)
        using hint = 'poor_accuracy';
    end if;
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
-- clock_out: must_change_password
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
  v_profile public.profiles;
  v_row public.attendance;
  v_distance double precision;
begin
  if v_uid is null then
    raise exception 'You must be signed in to clock out.' using hint = 'not_authenticated';
  end if;

  select * into v_profile from public.profiles p where p.id = v_uid;
  if not found then
    raise exception 'No staff profile found for this account.' using hint = 'no_profile';
  end if;
  if not v_profile.is_active then
    raise exception 'This account has been deactivated. Contact your administrator.'
      using hint = 'account_inactive';
  end if;
  if v_profile.must_change_password then
    raise exception 'Replace your temporary password before clocking out.'
      using hint = 'must_change_password';
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
-- No silent attendance deletes through the Data API
-- ---------------------------------------------------------------------------

drop policy if exists attendance_delete_admin on public.attendance;
revoke delete on public.attendance from authenticated;

-- ---------------------------------------------------------------------------
-- Admin: visit counts per day for one calendar month
-- ---------------------------------------------------------------------------

create or replace function public.admin_month_visit_counts(
  p_year integer,
  p_month integer,
  p_user_id uuid default null
)
returns table (work_date date, visit_count bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_from date;
  v_to date;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can view organisation attendance.'
      using hint = 'forbidden';
  end if;

  if p_year is null or p_month is null
     or p_month < 1 or p_month > 12
     or p_year < 2000 or p_year > 2100 then
    raise exception 'That month is not valid.' using hint = 'invalid_month';
  end if;

  v_from := make_date(p_year, p_month, 1);
  v_to := (v_from + interval '1 month')::date - 1;

  return query
  select a.work_date, count(*)::bigint
    from public.attendance a
   where a.work_date between v_from and v_to
     and (p_user_id is null or a.user_id = p_user_id)
   group by a.work_date
   order by a.work_date;
end;
$$;

revoke all on function public.admin_month_visit_counts(integer, integer, uuid)
  from public, anon;
grant execute on function public.admin_month_visit_counts(integer, integer, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Admin: today snapshot including overnight open shifts
-- ---------------------------------------------------------------------------

create or replace function public.admin_today_snapshot(
  p_recent_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.org_today();
  v_limit integer := greatest(1, least(coalesce(p_recent_limit, 50), 200));
  v_people bigint;
  v_on_shift bigint;
  v_completed bigint;
  v_absent jsonb;
  v_recent jsonb;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can view organisation attendance.'
      using hint = 'forbidden';
  end if;

  select count(distinct a.user_id)::bigint
    into v_people
    from public.attendance a
   where a.work_date = v_today
      or a.clock_out_at is null;

  select count(*)::bigint
    into v_on_shift
    from public.attendance a
   where a.clock_out_at is null;

  select count(*)::bigint
    into v_completed
    from public.attendance a
   where a.work_date = v_today
     and a.clock_out_at is not null;

  select coalesce(jsonb_agg(
           jsonb_build_object(
             'id', p.id,
             'full_name', p.full_name,
             'email', p.email,
             'staff_id', p.staff_id,
             'role', p.role,
             'is_active', p.is_active
           )
           order by p.full_name
         ), '[]'::jsonb)
    into v_absent
    from public.profiles p
   where p.is_active
     and not exists (
       select 1
         from public.attendance a
        where a.user_id = p.id
          and (a.work_date = v_today or a.clock_out_at is null)
     );

  select coalesce(jsonb_agg(item), '[]'::jsonb)
    into v_recent
    from (
      select to_jsonb(a) || jsonb_build_object(
               'profiles', jsonb_build_object(
                 'full_name', pr.full_name,
                 'email', pr.email,
                 'staff_id', pr.staff_id,
                 'role', pr.role,
                 'is_active', pr.is_active
               )
             ) as item
        from public.attendance a
        join public.profiles pr on pr.id = a.user_id
       where a.work_date = v_today
          or a.clock_out_at is null
       order by a.clock_in_at desc
       limit v_limit
    ) q;

  return jsonb_build_object(
    'work_date', v_today,
    'people', v_people,
    'on_shift', v_on_shift,
    'completed', v_completed,
    'absent', v_absent,
    'recent', v_recent
  );
end;
$$;

revoke all on function public.admin_today_snapshot(integer) from public, anon;
grant execute on function public.admin_today_snapshot(integer) to authenticated;
