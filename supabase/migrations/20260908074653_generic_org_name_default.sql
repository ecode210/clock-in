-- The app is general purpose, not hospital specific. Drop the sector-specific
-- default and rename the seeded row, but only while it still holds the old
-- default so a real organisation name is never overwritten.
alter table public.org_settings
  alter column org_name set default 'My Organisation';

update public.org_settings
   set org_name = 'My Organisation'
 where org_name = 'Hospital';
