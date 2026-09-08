-- Reads the current request's JWT and reports whether the session was
-- established (or refreshed) with a passkey inside the freshness window.
-- Supabase records authentication methods in the `amr` claim; the exact method
-- string for WebAuthn is matched loosely so it survives naming changes.
create or replace function public.has_fresh_passkey_auth(p_max_age_seconds integer)
returns boolean
language plpgsql
stable
as $$
declare
  v_claims jsonb;
  v_entry jsonb;
  v_method text;
  v_ts double precision;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then
    return false;
  end;

  if v_claims is null then
    return false;
  end if;

  for v_entry in
    select value from jsonb_array_elements(
      case when jsonb_typeof(v_claims -> 'amr') = 'array'
           then v_claims -> 'amr'
           else '[]'::jsonb end
    )
  loop
    v_method := lower(coalesce(v_entry ->> 'method', ''));

    if v_method like '%passkey%' or v_method like '%webauthn%' then
      if p_max_age_seconds is null then
        return true;
      end if;

      begin
        v_ts := (v_entry ->> 'timestamp')::double precision;
      exception when others then
        v_ts := null;
      end;

      if v_ts is null then
        return true;
      end if;

      if extract(epoch from now()) - v_ts <= p_max_age_seconds then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

-- Records a clock-in. All geofence and fraud-prevention rules are enforced
-- here rather than on the client, because browser coordinates are spoofable.
create or replace function public.clock_in(
  p_lat double precision,
  p_lng double precision,
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
  v_distance double precision;
  v_work_date date;
  v_row public.attendance;
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

  if v_settings.geofence_lat is null then
    raise exception 'The clock-in location has not been configured yet. Contact your administrator.'
      using hint = 'geofence_not_configured';
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
    p_lat, p_lng, v_settings.geofence_lat, v_settings.geofence_lng
  );

  if v_distance > v_settings.radius_meters then
    raise exception 'You are %m from %, which is outside the % m clock-in zone.',
      round(v_distance), v_settings.location_name, v_settings.radius_meters
      using hint = 'outside_geofence';
  end if;

  if v_settings.require_passkey
     and not public.has_fresh_passkey_auth(v_settings.passkey_freshness_seconds) then
    raise exception 'Passkey verification is required to clock in.'
      using hint = 'passkey_required';
  end if;

  if v_settings.require_selfie then
    if coalesce(btrim(coalesce(p_selfie_path, '')), '') = '' then
      raise exception 'A live photo is required to clock in.' using hint = 'selfie_required';
    end if;

    if p_selfie_path not like (v_uid::text || '/%') then
      raise exception 'The submitted photo does not belong to this account.'
        using hint = 'invalid_selfie_path';
    end if;
  end if;

  v_work_date := (now() at time zone v_settings.timezone)::date;

  insert into public.attendance (
    user_id, work_date,
    clock_in_at, clock_in_lat, clock_in_lng,
    clock_in_distance_meters, clock_in_accuracy_meters,
    selfie_path, verified_with_selfie, verified_with_passkey
  )
  values (
    v_uid, v_work_date,
    now(), p_lat, p_lng,
    v_distance, p_accuracy_meters,
    nullif(btrim(coalesce(p_selfie_path, '')), ''),
    v_settings.require_selfie,
    v_settings.require_passkey
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'You have already clocked in today.' using hint = 'already_clocked_in';
end;
$$;

-- Closes out today's attendance record.
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
  v_settings public.org_settings;
  v_distance double precision;
  v_work_date date;
  v_row public.attendance;
begin
  if v_uid is null then
    raise exception 'You must be signed in to clock out.' using hint = 'not_authenticated';
  end if;

  select * into v_settings from public.org_settings s where s.id;
  v_work_date := (now() at time zone v_settings.timezone)::date;

  select * into v_row
    from public.attendance a
   where a.user_id = v_uid and a.work_date = v_work_date
     for update;

  if not found then
    raise exception 'You have not clocked in today.' using hint = 'not_clocked_in';
  end if;

  if v_row.clock_out_at is not null then
    raise exception 'You have already clocked out today.' using hint = 'already_clocked_out';
  end if;

  if p_lat is not null and p_lng is not null and v_settings.geofence_lat is not null then
    v_distance := public.distance_meters(
      p_lat, p_lng, v_settings.geofence_lat, v_settings.geofence_lng
    );
  end if;

  if not v_settings.allow_clock_out_outside_geofence then
    if v_distance is null then
      raise exception 'Your location is required to clock out.' using hint = 'missing_location';
    end if;

    if v_distance > v_settings.radius_meters then
      raise exception 'You are %m from %, which is outside the % m clock-out zone.',
        round(v_distance), v_settings.location_name, v_settings.radius_meters
        using hint = 'outside_geofence';
    end if;
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

-- Only the RPCs may write attendance rows
revoke insert, update on public.attendance from anon, authenticated;
revoke all on function public.clock_in(double precision, double precision, double precision, text) from anon;
revoke all on function public.clock_out(double precision, double precision, double precision) from anon;
grant execute on function public.clock_in(double precision, double precision, double precision, text) to authenticated;
grant execute on function public.clock_out(double precision, double precision, double precision) to authenticated;
