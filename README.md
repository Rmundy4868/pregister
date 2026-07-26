# pregister

A new Flutter project.

## Supabase setup

1. Open your Supabase project SQL Editor.
2. Run the SQL in `supabase/organization_structure_setup.sql`.
3. Run the SQL in `supabase/license_setup.sql`.
   - Re-run this script after updates; it creates the `activate_install_license` RPC used by startup license validation.
4. Run the SQL in `supabase/settings_tables_policies.sql` to apply organization/location scoped RLS for `locations`, `terminals`, and `staff`.
5. Run the SQL in `supabase/transactions_setup.sql`.
   - If you already ran it earlier, run it again to apply the read policy used by the in-app `Recent Tx` debug viewer.
6. Run the SQL in `supabase/2026-02-23_add_location_extended_fields.sql` to add `address_2`, `city`, `state`, `zip`, and `phone` to `locations`.
   - Re-run this script after updates to keep locations form fields in sync.
   - Re-run all four scripts after updates to apply `organization_number` (6 digits), `terminal_number` (4 digits), and trigger/policy changes.
7. Start the app:

```bash
flutter pub get
flutter run -d windows
```

After this, successful cash payments and all card payment results are inserted into `public.transactions`.

Multi-tenant note: the new RLS policies are strict and intended for authenticated users (`authenticated` role). Access is scoped by `public.user_memberships` so one organization cannot see another, and one location cannot see another unless the user has org-level membership.

Optional demo seed: run `supabase/seed_multi_tenant_demo.sql` after replacing the placeholder `user_id` values with real IDs from `auth.users`.

Optional demo reset: run `supabase/reset_demo_seed.sql` to remove only rows created by the demo seed.

## Live Supabase runtime config

This app reads Supabase values from Dart defines:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `PAYMENT_API_BASE_URL` (for card/payment backend API; defaults to `http://localhost:3000` if omitted)
- `APP_LICENSE_KEY` (optional if not entered in-app; this key is validated at startup)
- `ORGANIZATION_NUMBER` (optional, for anon/device transaction scope fallback)
- `TERMINAL_NUMBER` (optional, for anon/device transaction scope fallback)

Example (run):

```bash
flutter run -d windows \
   --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
   --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

Example (release build):

```bash
flutter build windows --release \
   --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
   --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY \
   --dart-define=PAYMENT_API_BASE_URL=https://YOUR_PAYMENT_BACKEND
```

## Secrets hygiene

- Never commit real Supabase URLs, anon keys, or license keys to source control.
- Keep README examples on placeholders such as `YOUR_PROJECT` and `YOUR_ANON_KEY`.
- Use local shell history, CI/CD secrets, or per-machine environment setup for real values.
- If a real key is exposed, rotate it in Supabase and replace it in docs immediately.

## Developer workflow

Use this checklist during day-to-day development:

1. Start debug run:

```bash
flutter run -d windows --dart-define=SUPABASE_URL=https://qpfdbaefkgedlsvdyfcg.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFwZmRiYWVma2dlZGxzdmR5ZmNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExOTM2MTYsImV4cCI6MjA4Njc2OTYxNn0.LZxDqe0HrQVR7vLQ1i-Xw76kdmExHaji1CPO_-G0YT8
```

1. While running:
   - Press `r` for hot reload (most changes)
   - Press `R` for hot restart (init/state changes)

1. Validate code before stopping:

```bash
flutter analyze
```

1. If SQL scripts changed, re-run them in Supabase SQL Editor:
   - `supabase/organization_structure_setup.sql`
   - `supabase/license_setup.sql`
   - `supabase/settings_tables_policies.sql`
   - `supabase/transactions_setup.sql`

1. Build release only when needed for distribution:

```bash
flutter build windows --release --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_ANON_KEY
```

1. Build installer only when shipping a version:

```powershell
powershell -ExecutionPolicy Bypass -File installer/build_installer.ps1
```

The installer script reads version from `pubspec.yaml` and outputs a versioned installer in `installer/`.

## Desktop startup launcher (auto backend check/start)

Use `start_pregister.ps1` as the desktop icon command so startup always checks
`/api/health`, starts `backend/server.js` when needed, and then opens the app.

PowerShell command for shortcut target:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\rmund\Documents\FlutterProjects\paaayit\pregister\start_pregister.ps1" -AppUrl "https://YOUR-APP-URL"
```

Optional flags:

- `-ForceRestartBackend` (kills existing process on backend port, then restarts)
- `-SkipLaunchApp` (only ensure backend is running)

Production-friendly launcher with popup diagnostics:

- `start_pregister_production.ps1`

This wrapper checks that Node.js exists before launch and shows a clear Windows
popup if startup fails (for example missing Node.js or backend startup errors).

Desktop shortcut target example:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\rmund\Documents\FlutterProjects\paaayit\pregister\start_pregister_production.ps1" -AppExePath "C:\Path\To\pregister.exe"
```

## Web debug restart helper

Use `restart_flutter_web.ps1` to avoid duplicate Flutter runs on port 8181.
The script always clears the current listener on the target port, then starts one run.

Default usage (Chrome target):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\restart_flutter_web.ps1"
```

If Chrome launch is unstable on your machine, use web-server mode:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\restart_flutter_web.ps1" -NoBrowser
```

Desktop shortcut target for reliable web debug restart:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Users\rmund\Documents\FlutterProjects\paaayit\pregister\restart_flutter_web.ps1" -NoBrowser
```

Alternative: point the desktop shortcut directly to:

```text
C:\Users\rmund\Documents\FlutterProjects\paaayit\pregister\launch_web_debug.cmd
```

Chrome-mode shortcut variant:

```text
C:\Users\rmund\Documents\FlutterProjects\paaayit\pregister\launch_web_debug_chrome.cmd
```

This uses the same single-instance safety flow and attempts to launch on the
Chrome target instead of `web-server`.

### Portable install identity for backup/restore

To make backup restore deterministic (copy workspace, run, and recover terminal
context from Supabase), store install identity in:

- `runtime/install.identity.json`

Template:

- `runtime/install.identity.json.example`

`restart_flutter_web.ps1` now auto-loads this file and passes:

- `APP_LICENSE_KEY`
- `ORGANIZATION_NUMBER`
- `TERMINAL_NUMBER`
- `LOCATION_NAME`
- `APP_DEVICE_ID`
- `APP_DEVICE_LABEL`

This allows startup to resolve terminal/license context from Supabase after a
simple workspace restore, even if browser local storage was cleared.

Recommended process:

1. Copy `runtime/install.identity.json.example` to `runtime/install.identity.json`.
2. Fill real values for your terminal/install.
3. Include `runtime/install.identity.json` in backups for exact startup restore.

Detailed operational steps:

- `ops/restore-runbook.md`

Automated local repair command for corrupted Flutter pub cache:

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair_flutter_cache.ps1`

## Install license activation flow

- On startup, the app validates a per-install license key (from local saved key or typed on activation screen).
- The license key maps to an organization row (`organizations.license_key`) and reads `organization_number`.
- If no location exists for that organization, activation auto-creates a default `Primary Location`.
- The app resolves/creates the selected location + terminal number and stores the license in `terminals.application_license_number`.
- The app then launches the register and displays terminal name from terminal fields (`terminal_name`, `name`, or `code`).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
