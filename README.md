# Staff Clock-In

A geofenced attendance app for one or more work sites. Staff clock in and out
from a browser, but only while they are physically inside a zone an
administrator draws on a map. Two optional identity checks (a passkey and a
live photo) can each be switched on or off from the admin UI. Staff may visit
more than one site in a day, and a shift may stay open overnight.

Flutter web front end, Supabase (Postgres + Auth + Storage + Edge Functions)
back end.

## Why the rules live in the database

Browser geolocation is trivially spoofable, so the client is treated as
untrusted. Everything that decides whether attendance is valid happens inside
the `clock_in` and `clock_out` Postgres functions:

- the distance from the configured centre is recomputed server-side (Haversine)
  and compared against the saved radius;
- clock-ins are refused when the reported GPS accuracy is worse than the
  configured limit;
- when a passkey is required, the request's JWT must contain a recent WebAuthn
  entry in its `amr` claim;
- when a live photo is required, a selfie path must be present *and* sit inside
  the caller's own storage folder.

The `attendance` table has `INSERT` and `UPDATE` revoked from clients
altogether, so those functions are the only way a row can be written. The live
distance readout and the disabled/enabled clock-in button on the staff screen
are convenience only; the server re-checks all of it.

## Roles and account creation

| Concern | How it works |
| --- | --- |
| Staff accounts | Created by an admin through the `manage-staff` Edge Function, which returns a one-time temporary password to hand over |
| Self-registration | Allowed by Supabase, but such accounts land **deactivated** and cannot clock in until an admin activates them |
| First admin | The first signed-in account can claim the admin role once, by entering a setup code stored in `app_secrets` (a table with RLS on and no policies, so it is unreachable through the API) |
| Last admin | A deferred constraint trigger refuses any change that would leave the org with no active administrator |

## Fraud prevention

Both checks are independent toggles on the **Verification** admin screen, so you
can run both, either one, or neither.

- **Passkey**: at clock-in the staff member re-runs the WebAuthn ceremony on
  their own device. That mints a fresh token whose `amr` claim carries a
  WebAuthn entry, and `clock_in` requires one no older than the configured
  freshness window (1 minute to 1 hour). The app also refuses a ceremony that
  resolves to a different account, so one person cannot clock in as another.
  Staff enrol a passkey from **Account**; they cannot pass the check until they
  do, so give them time to enrol before switching this on.
- **Live photo**: a photo is captured from the camera feed at the moment of
  clocking in and uploaded to a private `selfies` bucket. There is deliberately
  no file picker. Admins review the thumbnails on the dashboard; staff cannot
  overwrite or delete a photo once uploaded.

## Running it

```bash
flutter pub get
flutter run -d chrome --web-port 3001
```

In VS Code or Cursor, press F5 instead; `.vscode/launch.json` runs the same
thing with the debugger attached.

Flutter starts Chrome with a throwaway profile, so enrolled passkeys and
location and camera grants are discarded on every run. To keep them across
runs, serve the app without launching a browser and open the URL in your normal
browser:

```bash
flutter run -d web-server --web-port 3001
```

The port matters: `localhost:3001` is what the project's WebAuthn relying party
origins are set to, and a passkey ceremony fails on any other origin. Port 3000
is avoided because it is commonly occupied by other local services.
Geolocation, camera and passkeys all require HTTPS in production; `localhost`
is the only exemption.

Supabase credentials default to the project this was built against and can be
overridden at build time:

```bash
flutter run -d chrome --web-port 3001 \
  --dart-define=SUPABASE_URL=https://your-project.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_...
```

The publishable key is safe in a browser bundle: every table is behind row level
security and all writes go through RPCs.

## First-time setup

1. Sign up or sign in with the account that should be the administrator.
2. Enter the setup code when prompted. Read it from the database if you need it:
   `select value from app_secrets where key = 'admin_setup_code';`
3. **Locations**: add each site (or press "Use my location"), set the radius,
   pick the timezone that decides when the working day rolls over, and save.
   Nobody can clock in until at least one active location exists.
4. **Verification**: choose which identity checks to require.
5. **Staff**: add accounts and hand out the temporary passwords.

## Layout

```
lib/src/
  config/          Supabase URL and key
  core/            error normalisation, formatters
  models/          Profile, OrgSettings, AttendanceRecord
  services/        repositories + Riverpod providers, location, camera, passkeys
  routing/         role-derived AppStage and the go_router config
  features/
    auth/          login, first-admin setup, awaiting-approval
    staff/         clock-in home, geofence status, selfie capture, history
    admin/         dashboard, attendance browser, staff management,
                   locations editor, verification settings, export
    shared/        account page, boot gate, common widgets

supabase/
  migrations/      schema, RLS, RPCs, storage policies, privilege hardening
  functions/       manage-staff Edge Function
```

## Deploying

Set the WebAuthn relying party to your real domain **before** staff enrol
passkeys. Passkeys are cryptographically bound to the relying party ID, and
changing it invalidates every one already registered. Local config uses
`rp_id = "localhost"` and `http://localhost:3001`; production must match the
served HTTPS origin.

Also raise the project's Data API **Max rows** to at least **6000** so Excel
exports (up to 5000 visits) are not silently truncated by PostgREST's default
1000-row cap. Client export and calendar guards still refuse oversized ranges.

```bash
flutter build web --release
```

Serve `build/web` over HTTPS, then update the Supabase project's Site URL and
the passkey relying party ID/origins to match.
