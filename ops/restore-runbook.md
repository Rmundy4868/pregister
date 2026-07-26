# Restore Runbook (One-Command Local Restore)

**Last verified session:** 2026-05-13 — Login Integrity Check PASSED, card/cash transaction flow validated.

## Goal

After restoring from backup, the local repo state should be recoverable with one command from the backup folder, and startup should recover terminal context from Supabase without manual reactivation.

---

## Step 0 — Create the backup (before stopping)

Double-click `run_full_backup.cmd`, or from a terminal in the repo root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\create_full_backup.ps1
```

This captures: all source files, `runtime/install.identity.json`, all Supabase SQL migrations, all launchers, backend, and a `RESTORE_MANIFEST.json` that records tool versions, identity values, and the restore checklist.

---

## Backup contents (what is captured automatically)

- `lib/` source code: all Dart app logic
- `runtime/install.identity.json`: activation identity, license key, terminal number, device ID
- `supabase/*.sql`: DB migration history that must match the connected Supabase project
- `restart_flutter_web.ps1`: full identity-seeding launcher
- `run_exact_chrome_debug.ps1` and `launch_exact_debug_chrome.cmd`: one-click debug launch
- `scripts/repair_flutter_cache.ps1`: recovery for pub cache corruption
- `backend/server.js` and `backend/package.json`: Node payment backend
- `RESTORE_MANIFEST.json`: versions, URLs, identity summary, restore steps

---

## Restore procedure

1. **Run the restore command from inside the backup folder:**

   ```powershell
   .\restore_backup.cmd
   ```

   This restores the local workspace state into the parent repo folder and runs dependency restore.

2. **If restoring to a different machine**, verify these files still contain the intended environment values:
   - `backend/.env`
   - `runtime/install.identity.json`

3. **Re-apply Supabase SQL files if the remote database also needs to be returned to this state.**
   Current backups capture migrations, runtime identity, backend env, and local code exactly.
   They do **not** capture a live PostgreSQL/Supabase row dump on this machine because `pg_dump` / Supabase CLI is not installed.

4. **Apply Supabase SQL migrations** in the Supabase SQL editor for the target project, in date order when needed:
   - `supabase/2026-05-13_resolve_install_from_device.sql` ← **critical — device restore RPC**
   - All earlier `.sql` files if this is a fresh Supabase project

5. **Start Node backend** (in a separate terminal, keep it running):

   ```powershell
   Push-Location backend; node server.js
   ```

   Verify healthy: `http://127.0.0.1:3000/api/health` should return `{"ok":true}`

6. **Start the app** (one-click):

   ```text
   launch_exact_debug_chrome.cmd
   ```

   Or with full identity seeding from identity file:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\restart_flutter_web.ps1
   ```

7. **Validate** — in the running app:
   - Open Settings → enable Integrity Checks toggle
   - Click Integrity Checks button
   - Run **Login Integrity Check**
   - All checks must show PASS (especially `resolve_install_from_device RPC is available`)

---

## Validation checklist

- [ ] App launches and Chrome opens
- [ ] Terminal output shows `Supabase init completed`
- [ ] Startup routes to Login (not activation screen)
- [ ] Login Integrity Check: all PASS
- [ ] Backend health: `http://127.0.0.1:3000/api/health` returns ok
- [ ] Test cash transaction completes and posts to Supabase
- [ ] Test card transaction routes to reader (sandbox mode OK)

---

## Failure handling

**Startup shows activation screen / enter license key:**

1. Confirm `runtime/install.identity.json` exists with correct `appLicenseKey`.
2. Confirm `resolve_install_from_device` SQL migration is applied in the connected Supabase project.
3. If this is a new machine, activate once via Terminal Activation screen — identity will be seeded into Supabase.

**Login Integrity Check: RPC guard FAIL:**

- SQL migration has not been applied in this Supabase environment.
- Run `supabase/2026-05-13_resolve_install_from_device.sql` in Supabase SQL editor.

**Port 8181 already in use:**

```powershell
Get-NetTCPConnection -LocalPort 8181 -State Listen -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty OwningProcess -Unique |
  ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
```

**Pub cache corruption (compile errors about missing packages):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\repair_flutter_cache.ps1
```

**Backend not starting (port 3000 error):**

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty OwningProcess -Unique |
  ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
```

---

## Production safety notes

- The SQL migrations add RPCs and schema only; they do not mutate transaction history.
- Always apply migrations to target environment before deploying code that depends on them.
- Use Integrity Checks window to validate each environment before processing live transactions.
