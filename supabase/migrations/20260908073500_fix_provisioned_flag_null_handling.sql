-- `(jsonb ->> 'missing_key') = 'true'` evaluates to NULL rather than false,
-- which made is_active NULL and aborted the signup outright. Default it.
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
  v_provisioned boolean := coalesce(
    (v_meta ->> 'provisioned_by_admin') = 'true', false
  );
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
