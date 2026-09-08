-- Admin-provisioned accounts start with a temporary password that the
-- administrator has seen and handed over in person. Until the staff member
-- replaces it, that password is a shared secret, and anyone holding it can
-- sign in as them. Flag those accounts so the app blocks everything else until
-- the password is changed.

alter table public.profiles
  add column must_change_password boolean not null default false;

-- Only the service role may move this flag: manage-staff raises it when it
-- issues a temporary password and lowers it once the staff member has chosen
-- their own. Administrators can edit every other profile column, so without
-- this guard an admin could simply clear their own flag, and any future
-- self-update policy would hand the same escape to staff.
create or replace function public.guard_must_change_password()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.must_change_password is distinct from old.must_change_password
     and coalesce(auth.role(), '') <> 'service_role' then
    new.must_change_password := old.must_change_password;
  end if;

  return new;
end;
$$;

create trigger profiles_guard_must_change_password
before update on public.profiles
for each row
execute function public.guard_must_change_password();

revoke all on function public.guard_must_change_password() from public, anon, authenticated;
