-- Pin search_path on the two functions that were still using the caller's
alter function public.distance_meters(double precision, double precision, double precision, double precision)
  set search_path = '';
alter function public.has_fresh_passkey_auth(integer)
  set search_path = '';

-- Trigger functions are never called directly through the API
revoke all on function public.handle_new_user() from anon, authenticated;
revoke all on function public.touch_updated_at() from anon, authenticated;
revoke all on function public.guard_last_admin() from anon, authenticated;
revoke all on function public.validate_org_settings() from anon, authenticated;

-- Nothing in this app is usable before signing in
revoke all on function public.is_admin(uuid) from anon;
revoke all on function public.admin_exists() from anon;
revoke all on function public.claim_first_admin() from anon;
revoke all on function public.update_my_profile(text) from anon;
revoke all on function public.has_fresh_passkey_auth(integer) from anon;

-- RLS policies are evaluated as the calling role, so signed-in users need to
-- be able to run the role check the policies depend on.
grant execute on function public.is_admin(uuid) to authenticated;
grant execute on function public.admin_exists() to authenticated;
grant execute on function public.claim_first_admin() to authenticated;
grant execute on function public.update_my_profile(text) to authenticated;
