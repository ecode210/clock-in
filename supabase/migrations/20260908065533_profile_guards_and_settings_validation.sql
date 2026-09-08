-- A policy that subqueries its own table recurses under RLS, so staff self-edits
-- go through an RPC instead and the permissive self-update policy is removed.
drop policy if exists profiles_update_self on public.profiles;

create or replace function public.update_my_profile(p_full_name text)
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

  if coalesce(btrim(p_full_name), '') = '' then
    raise exception 'Name cannot be empty.' using hint = 'invalid_name';
  end if;

  update public.profiles
     set full_name = btrim(p_full_name)
   where id = v_uid
  returning * into v_row;

  return v_row;
end;
$$;

-- Never allow the organisation to be left without an admin who can sign in
create or replace function public.guard_last_admin()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.profiles p where p.role = 'admin' and p.is_active
  ) then
    raise exception 'There must be at least one active administrator.'
      using hint = 'last_admin';
  end if;
  return null;
end;
$$;

create constraint trigger profiles_guard_last_admin
after update or delete on public.profiles
deferrable initially deferred
for each row
execute function public.guard_last_admin();

-- Validate geofence + timezone whenever settings are saved
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

  if (new.geofence_lat is null) <> (new.geofence_lng is null) then
    raise exception 'Geofence latitude and longitude must be set together.'
      using hint = 'incomplete_geofence';
  end if;

  if new.geofence_lat is not null
     and (new.geofence_lat < -90 or new.geofence_lat > 90
          or new.geofence_lng < -180 or new.geofence_lng > 180) then
    raise exception 'Geofence coordinates are out of range.'
      using hint = 'invalid_coordinates';
  end if;

  new.updated_by := coalesce(auth.uid(), new.updated_by);

  return new;
end;
$$;

create trigger org_settings_validate
before insert or update on public.org_settings
for each row
execute function public.validate_org_settings();
