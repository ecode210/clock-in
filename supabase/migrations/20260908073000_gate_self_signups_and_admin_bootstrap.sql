-- Supabase leaves public sign-up enabled by default. Rather than depend on a
-- dashboard toggle staying off, the database refuses to trust any account it
-- did not see an admin provision:
--   * self-registered accounts arrive deactivated and cannot clock in until an
--     administrator activates them;
--   * claiming the very first admin role additionally requires a setup code
--     that is not readable through the API.

create table public.app_secrets (
  key text primary key,
  value text not null,
  created_at timestamptz not null default now(),
  consumed_at timestamptz
);

-- RLS on with no policies at all: unreachable from anon and authenticated.
-- Only the security definer functions below can see it.
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

insert into public.app_secrets (key, value)
values ('admin_setup_code', encode(gen_random_bytes(9), 'hex'));

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_role public.user_role := 'staff';
  -- Only the manage-staff Edge Function sets this, and it runs with the
  -- service role after checking that the caller is an admin.
  v_provisioned boolean := (v_meta ->> 'provisioned_by_admin') = 'true';
begin
  if v_provisioned and v_meta ->> 'role' = 'admin' then
    v_role := 'admin';
  end if;

  insert into public.profiles (id, full_name, email, staff_id, role, is_active)
  values (
    new.id,
    coalesce(v_meta ->> 'full_name', ''),
    new.email,
    nullif(v_meta ->> 'staff_id', ''),
    v_role,
    v_provisioned
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function public.handle_new_user() from anon, authenticated;

-- Replaced by the setup-code variant below.
drop function if exists public.claim_first_admin();

create or replace function public.claim_first_admin(p_setup_code text)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_expected text;
  v_row public.profiles;
begin
  if v_uid is null then
    raise exception 'You must be signed in.' using hint = 'not_authenticated';
  end if;

  perform pg_advisory_xact_lock(hashtext('claim_first_admin'));

  if public.admin_exists() then
    raise exception 'An administrator already exists for this organisation.'
      using hint = 'admin_already_exists';
  end if;

  select s.value into v_expected
    from public.app_secrets s
   where s.key = 'admin_setup_code' and s.consumed_at is null;

  if v_expected is null then
    raise exception 'Administrator setup has already been completed.'
      using hint = 'setup_already_used';
  end if;

  if coalesce(btrim(lower(p_setup_code)), '') <> lower(v_expected) then
    raise exception 'That setup code is not correct.'
      using hint = 'invalid_setup_code';
  end if;

  update public.profiles
     set role = 'admin', is_active = true
   where id = v_uid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'No staff profile found for this account.'
      using hint = 'no_profile';
  end if;

  update public.app_secrets
     set consumed_at = now()
   where key = 'admin_setup_code';

  return v_row;
end;
$$;

revoke all on function public.claim_first_admin(text) from anon;
grant execute on function public.claim_first_admin(text) to authenticated;
