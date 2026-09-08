-- Clock-in photos were evidence nobody could act on: an administrator could
-- open one, but there was nowhere to record that they had looked, or that what
-- they saw was wrong. Give each record a review state so a suspicious photo
-- can be flagged and the rest marked off.

alter table public.attendance
  add column review_status text not null default 'unreviewed',
  add column reviewed_by uuid references public.profiles (id) on delete set null,
  add column reviewed_at timestamptz,
  add constraint attendance_review_status_check
    check (review_status in ('unreviewed', 'reviewed', 'flagged'));

-- Only the handful of rows an admin has acted on need indexing.
create index attendance_review_status_idx
  on public.attendance (review_status)
  where review_status <> 'unreviewed';

-- Attendance is revoked for update from authenticated, so reviewing goes
-- through an RPC like clocking in and out does.
create or replace function public.review_attendance(p_id uuid, p_status text)
returns public.attendance
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.attendance;
begin
  if not public.is_admin() then
    raise exception 'Only administrators can review clock-ins.' using hint = 'forbidden';
  end if;

  if p_status is null or p_status not in ('unreviewed', 'reviewed', 'flagged') then
    raise exception 'That review status is not recognised.'
      using hint = 'invalid_review_status';
  end if;

  update public.attendance a
     set review_status = p_status,
         reviewed_by = case when p_status = 'unreviewed' then null else auth.uid() end,
         reviewed_at = case when p_status = 'unreviewed' then null else now() end
   where a.id = p_id
  returning * into v_row;

  if not found then
    raise exception 'That clock-in record no longer exists.' using hint = 'record_not_found';
  end if;

  return v_row;
end;
$$;

revoke all on function public.review_attendance(uuid, text) from public, anon;
grant execute on function public.review_attendance(uuid, text) to authenticated;
