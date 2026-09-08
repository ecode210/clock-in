-- Three gaps in the clock-in checks:
--
--   * has_fresh_passkey_auth treated an `amr` entry with no usable timestamp
--     as fresh, so a token that could not be shown to be recent passed the
--     freshness requirement.
--   * The selfie was only checked for being under the caller's own folder.
--     The filename is a client-supplied timestamp and the object was never
--     looked up, so a direct RPC call could replay a photo uploaded earlier.
--   * verified_with_selfie / verified_with_passkey were copied from the org
--     toggles, so they recorded that a policy was switched on rather than that
--     anything was actually verified.

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

      -- An entry carrying no readable timestamp cannot be shown to be recent,
      -- so it fails a freshness requirement instead of satisfying it. Keep
      -- looking: a later entry may still qualify.
      if v_ts is not null
         and extract(epoch from now()) - v_ts <= p_max_age_seconds then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

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

  -- Recorded whether or not it is required, so the attendance row says what
  -- actually happened rather than what the setting was at the time.
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

    -- The path is built from a clock the client controls, so age comes from
    -- the stored object instead. Anything older than this is a replay of a
    -- photo taken earlier rather than a live capture.
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
    v_selfie_verified,
    v_passkey_verified
  )
  returning * into v_row;

  return v_row;
exception
  when unique_violation then
    raise exception 'You have already clocked in today.' using hint = 'already_clocked_in';
end;
$$;

revoke all on function public.clock_in(double precision, double precision, double precision, text) from public, anon;
grant execute on function public.clock_in(double precision, double precision, double precision, text) to authenticated;
