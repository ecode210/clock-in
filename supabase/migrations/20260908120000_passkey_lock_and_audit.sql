-- One passkey per account: the staff member enrols their own device once, and
-- from then on only an administrator can clear it.
--
-- Self-service enrolment was the weak link in the clock-in checks. Anyone
-- holding a colleague's password could sign in, register their own phone as a
-- passkey, and satisfy the freshness check in clock_in with their own
-- biometrics. Capping the account at a single credential and refusing
-- self-service removal means a stolen password on its own is no longer enough.
--
-- GoTrue owns auth.webauthn_credentials, so the rules live in triggers on that
-- table rather than in the app: the Auth API, the dashboard and any direct
-- caller all go through the same checks. Migrations run as `postgres`, which
-- holds TRIGGER on the table without being a member of supabase_auth_admin.

create type public.passkey_event_action as enum ('enrolled', 'deleted', 'reset');

-- Audit trail, so an administrator can see that a device was swapped even
-- though the credential itself is opaque to us.
create table public.passkey_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  actor_id uuid references public.profiles (id) on delete set null,
  action public.passkey_event_action not null,
  friendly_name text,
  created_at timestamptz not null default now()
);

create index passkey_events_user_idx
  on public.passkey_events (user_id, created_at desc);

alter table public.passkey_events enable row level security;

create policy passkey_events_select_self on public.passkey_events
  for select to authenticated
  using (user_id = auth.uid());

create policy passkey_events_select_admin on public.passkey_events
  for select to authenticated
  using (public.is_admin());

-- Written only by the triggers and the reset RPC below, which are all
-- security definer.
revoke all on public.passkey_events from anon;
revoke insert, update, delete on public.passkey_events from authenticated;

-- Refuses a second credential for an account that already has one.
create or replace function public.enforce_single_passkey()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
      from auth.webauthn_credentials c
     where c.user_id = new.user_id
       and c.id <> new.id
  ) then
    raise exception 'This account already has a passkey. Ask an administrator to reset it before registering another device.'
      using hint = 'passkey_already_registered';
  end if;

  return new;
end;
$$;

-- Staff cannot remove their own passkey; otherwise the one-per-account cap
-- would only ever be one *at a time*, and a device swap would leave no trace.
create or replace function public.guard_passkey_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- reset_staff_passkey opens this window for the length of its transaction.
  if coalesce(current_setting('clockin.allow_passkey_delete', true), '') = 'on' then
    return old;
  end if;

  -- The owning account is being deleted. Referential-integrity cascades run
  -- after the auth.users row is gone, so an absent user means this delete is
  -- part of that teardown rather than someone dropping their credential.
  if not exists (select 1 from auth.users u where u.id = old.user_id) then
    return old;
  end if;

  raise exception 'Passkeys can only be removed by an administrator.'
    using hint = 'passkey_delete_forbidden';
end;
$$;

create or replace function public.log_passkey_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := case when tg_op = 'INSERT' then new.user_id else old.user_id end;
  v_action public.passkey_event_action;
begin
  -- No profile means the account is being torn down, and the audit row would
  -- only fail its foreign key and block the deletion.
  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    return null;
  end if;

  if tg_op = 'INSERT' then
    v_action := 'enrolled';
  elsif coalesce(current_setting('clockin.allow_passkey_delete', true), '') = 'on' then
    v_action := 'reset';
  else
    v_action := 'deleted';
  end if;

  insert into public.passkey_events (user_id, actor_id, action, friendly_name)
  values (
    v_user_id,
    -- Enrolment runs on a GoTrue connection with no JWT, so the actor is null
    -- and the staff member themselves is implied. A reset carries the admin.
    (select p.id from public.profiles p where p.id = auth.uid()),
    v_action,
    case when tg_op = 'INSERT' then new.friendly_name else old.friendly_name end
  );

  return null;
end;
$$;

drop trigger if exists webauthn_enforce_single_passkey on auth.webauthn_credentials;
create trigger webauthn_enforce_single_passkey
before insert on auth.webauthn_credentials
for each row
execute function public.enforce_single_passkey();

drop trigger if exists webauthn_guard_delete on auth.webauthn_credentials;
create trigger webauthn_guard_delete
before delete on auth.webauthn_credentials
for each row
execute function public.guard_passkey_delete();

drop trigger if exists webauthn_log_event on auth.webauthn_credentials;
create trigger webauthn_log_event
after insert or delete on auth.webauthn_credentials
for each row
execute function public.log_passkey_event();

-- What an administrator sees on the staff sheet. The credential itself stays
-- opaque; only the labels and dates are exposed.
create or replace function public.list_staff_passkeys(p_user_id uuid)
returns table (
  friendly_name text,
  created_at timestamptz,
  last_used_at timestamptz,
  backed_up boolean
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Only administrators can view passkeys.' using hint = 'forbidden';
  end if;

  return query
    select c.friendly_name, c.created_at, c.last_used_at, c.backed_up
      from auth.webauthn_credentials c
     where c.user_id = p_user_id
     order by c.created_at;
end;
$$;

-- Clears the account's passkey so the staff member can enrol a new device.
-- The delete has to happen here rather than through the Auth admin API: that
-- path would trip the guard trigger, which only stands down for this function.
create or replace function public.reset_staff_passkey(p_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removed integer;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can reset passkeys.' using hint = 'forbidden';
  end if;

  if p_user_id is null then
    raise exception 'A staff member is required.' using hint = 'invalid_user';
  end if;

  perform set_config('clockin.allow_passkey_delete', 'on', true);

  delete from auth.webauthn_credentials c where c.user_id = p_user_id;
  get diagnostics v_removed = row_count;

  perform set_config('clockin.allow_passkey_delete', 'off', true);

  return v_removed;
end;
$$;

revoke all on function public.enforce_single_passkey() from public, anon, authenticated;
revoke all on function public.guard_passkey_delete() from public, anon, authenticated;
revoke all on function public.log_passkey_event() from public, anon, authenticated;
revoke all on function public.list_staff_passkeys(uuid) from public, anon;
revoke all on function public.reset_staff_passkey(uuid) from public, anon;

-- The triggers fire on GoTrue's own connection. Postgres only checks EXECUTE
-- when a trigger is created, but granting keeps that independent of the
-- version we happen to be on.
grant execute on function public.enforce_single_passkey() to supabase_auth_admin;
grant execute on function public.guard_passkey_delete() to supabase_auth_admin;
grant execute on function public.log_passkey_event() to supabase_auth_admin;

-- Both RPCs check is_admin() themselves.
grant execute on function public.list_staff_passkeys(uuid) to authenticated;
grant execute on function public.reset_staff_passkey(uuid) to authenticated;
