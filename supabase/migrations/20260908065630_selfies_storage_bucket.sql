-- Private bucket for clock-in selfies. Files live under "<user_id>/..." so the
-- first path segment can be used to scope access.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('selfies', 'selfies', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Staff may only upload into their own folder
create policy selfies_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Staff can review their own photos; admins can review everyone's for verification
create policy selfies_select_own on storage.objects
  for select to authenticated
  using (
    bucket_id = 'selfies'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy selfies_select_admin on storage.objects
  for select to authenticated
  using (bucket_id = 'selfies' and public.is_admin());

-- Selfies are attendance evidence: staff cannot overwrite or remove them
create policy selfies_delete_admin on storage.objects
  for delete to authenticated
  using (bucket_id = 'selfies' and public.is_admin());
