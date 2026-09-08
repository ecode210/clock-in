-- "Today" is whatever the organisation's timezone says it is, not the
-- browser's. Both the staff screen and the admin dashboard ask the server.
create or replace function public.org_today()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (now() at time zone s.timezone)::date
    from public.org_settings s
   where s.id;
$$;

create or replace function public.my_today_attendance()
returns public.attendance
language sql
stable
security definer
set search_path = ''
as $$
  select a.*
    from public.attendance a
   where a.user_id = auth.uid()
     and a.work_date = public.org_today();
$$;

revoke all on function public.org_today() from anon;
revoke all on function public.my_today_attendance() from anon;
grant execute on function public.org_today() to authenticated;
grant execute on function public.my_today_attendance() to authenticated;
