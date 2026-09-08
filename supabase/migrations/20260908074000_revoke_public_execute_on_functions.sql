-- Postgres grants EXECUTE on new functions to PUBLIC, and `anon` inherits it.
-- Revoking from `anon` alone left that PUBLIC grant in place, so every RPC was
-- still reachable without a session. Strip PUBLIC and grant explicitly.

do $$
declare
  v_signature text;
begin
  for v_signature in
    select format('%I.%I(%s)', n.nspname, p.proname,
                  pg_catalog.pg_get_function_identity_arguments(p.oid))
      from pg_catalog.pg_proc p
      join pg_catalog.pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated',
                   v_signature);
  end loop;
end $$;

-- Re-grant only what a signed-in user legitimately calls. RLS policies are
-- evaluated as the calling role, so is_admin has to stay executable.
grant execute on function public.is_admin(uuid) to authenticated;
grant execute on function public.admin_exists() to authenticated;
grant execute on function public.claim_first_admin(text) to authenticated;
grant execute on function public.update_my_profile(text) to authenticated;
grant execute on function public.org_today() to authenticated;
grant execute on function public.my_today_attendance() to authenticated;
grant execute on function public.clock_in(double precision, double precision, double precision, text) to authenticated;
grant execute on function public.clock_out(double precision, double precision, double precision) to authenticated;

-- distance_meters and has_fresh_passkey_auth are internals of clock_in, which
-- runs as its owner, so they need no client-facing grant. The trigger
-- functions (handle_new_user, touch_updated_at, guard_last_admin,
-- validate_org_settings) are likewise invoked by the triggers, not the API.

-- admin_exists() already tells the client whether first-run setup is open, so
-- a second setup_pending() RPC would be dead surface area.
drop function if exists public.setup_pending();
