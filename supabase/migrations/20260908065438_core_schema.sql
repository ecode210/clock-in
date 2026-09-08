-- Roles
create type public.user_role as enum ('staff', 'admin');

-- Staff/admin profiles, mirrored from auth.users
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  email text,
  staff_id text,
  role public.user_role not null default 'staff',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index profiles_role_idx on public.profiles (role);

-- Single-row organisation configuration: geofence + fraud prevention toggles
create table public.org_settings (
  id boolean primary key default true,
  org_name text not null default 'Hospital',
  location_name text not null default 'Main Site',
  timezone text not null default 'UTC',
  geofence_lat double precision,
  geofence_lng double precision,
  radius_meters integer not null default 100,
  require_selfie boolean not null default false,
  require_passkey boolean not null default false,
  passkey_freshness_seconds integer not null default 300,
  max_accuracy_meters integer,
  allow_clock_out_outside_geofence boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles (id) on delete set null,
  constraint org_settings_singleton check (id),
  constraint org_settings_radius_range check (radius_meters between 10 and 5000),
  constraint org_settings_freshness_range check (passkey_freshness_seconds between 30 and 3600)
);

insert into public.org_settings (id) values (true);

-- One attendance record per staff member per working day
create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  work_date date not null,
  clock_in_at timestamptz not null default now(),
  clock_in_lat double precision not null,
  clock_in_lng double precision not null,
  clock_in_distance_meters double precision not null,
  clock_in_accuracy_meters double precision,
  clock_out_at timestamptz,
  clock_out_lat double precision,
  clock_out_lng double precision,
  clock_out_distance_meters double precision,
  clock_out_accuracy_meters double precision,
  selfie_path text,
  verified_with_selfie boolean not null default false,
  verified_with_passkey boolean not null default false,
  created_at timestamptz not null default now(),
  constraint attendance_one_per_day unique (user_id, work_date)
);

create index attendance_work_date_idx on public.attendance (work_date desc);
create index attendance_user_date_idx on public.attendance (user_id, work_date desc);

-- Mirror new auth users into profiles
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.user_role := 'staff';
  v_requested text := new.raw_user_meta_data ->> 'role';
begin
  if v_requested = 'admin' then
    v_role := 'admin';
  end if;

  insert into public.profiles (id, full_name, email, staff_id, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.email,
    nullif(new.raw_user_meta_data ->> 'staff_id', ''),
    v_role
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

-- Keep updated_at fresh
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch_updated_at
before update on public.profiles
for each row
execute function public.touch_updated_at();

create trigger org_settings_touch_updated_at
before update on public.org_settings
for each row
execute function public.touch_updated_at();
