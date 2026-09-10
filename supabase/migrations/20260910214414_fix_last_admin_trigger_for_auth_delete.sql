-- Auth deletes a user as supabase_auth_admin, which cascades into profiles.
-- The last-admin guard then runs and SELECTs from profiles. That role has no
-- table privileges on public.profiles, so the delete fails with
-- "permission denied for table profiles" and the edge function surfaces a
-- generic "Unexpected failure" message. Run the check as the function owner.

create or replace function public.guard_last_admin()
returns trigger
language plpgsql
security definer
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

revoke all on function public.guard_last_admin() from public, anon, authenticated;
