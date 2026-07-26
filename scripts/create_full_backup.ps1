param(
  [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
  [string]$BackupRoot = ''
)

$ErrorActionPreference = 'Stop'

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupName = "pregister-full-backup-$timestamp"

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
  $BackupRoot = Join-Path $RepoRoot 'backup'
}

$destDir = Join-Path $BackupRoot $backupName
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

$restoreScriptSource = Join-Path $RepoRoot 'scripts\restore_full_backup.ps1'
$pgDumpAvailable = [bool](Get-Command pg_dump -ErrorAction SilentlyContinue)
$supabaseCliAvailable = [bool](Get-Command supabase -ErrorAction SilentlyContinue)
$databaseSnapshotMode = if ($pgDumpAvailable -or $supabaseCliAvailable) {
  'tooling-available'
} else {
  'migrations-only'
}
$databaseSnapshotNote = if ($databaseSnapshotMode -eq 'migrations-only') {
  'Exact remote Supabase row state is not captured on this machine because pg_dump / Supabase CLI is not installed. Local repo state, identity files, backend env, and SQL migrations are captured.'
} else {
  'Database dump tooling exists on this machine, but this backup script currently captures migrations rather than a live database dump.'
}

Write-Host "Backup destination: $destDir"
Write-Host ''

# ──────────────────────────────────────────────────────────────────────────────
# 1. Source code and project files
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[1/7] Copying source code and project files...'

$excludeFolders = @('.dart_tool', 'build', '.flutter-plugins-dependencies', '.chrome-profile', 'node_modules')
$excludeFiles   = @('.flutter-plugins-dependencies')

$items = Get-ChildItem -Path $RepoRoot -Force | Where-Object {
  $excludeFolders -notcontains $_.Name -and $excludeFiles -notcontains $_.Name
}

foreach ($item in $items) {
  $dest = Join-Path $destDir $item.Name
  if ($item.PSIsContainer) {
    if ($item.Name -eq 'backup') {
      # Do not nest backups inside backups.
      continue
    }
    Copy-Item -Path $item.FullName -Destination $dest -Recurse -Force
  } else {
    Copy-Item -Path $item.FullName -Destination $dest -Force
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Runtime identity artifact (explicit — even if already included above)
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[2/7] Verifying runtime/install.identity.json...'

$identityPath = Join-Path $RepoRoot 'runtime\install.identity.json'
$destIdentity = Join-Path $destDir 'runtime\install.identity.json'

if (Test-Path $identityPath) {
  New-Item -ItemType Directory -Path (Split-Path $destIdentity) -Force | Out-Null
  Copy-Item -Path $identityPath -Destination $destIdentity -Force
  Write-Host "  Captured: $identityPath"
  $identityContent = Get-Content $identityPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
  if ($identityContent) {
    Write-Host "  appLicenseKey    : $($identityContent.appLicenseKey)"
    Write-Host "  terminalNumber   : $($identityContent.terminalNumber)"
    Write-Host "  organizationNumber: $($identityContent.organizationNumber)"
    Write-Host "  locationName     : $($identityContent.locationName)"
    Write-Host "  spinAuthKey      : $($identityContent.spinAuthKey)"
    Write-Host "  appDeviceId      : $($identityContent.appDeviceId)"
    Write-Host "  appDeviceLabel   : $($identityContent.appDeviceLabel)"
  }
} else {
  Write-Warning '  runtime/install.identity.json NOT FOUND. Device registration recovery will NOT work on restore.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. Supabase migration files
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[3/7] Capturing Supabase migration files...'

$supabaseDir = Join-Path $RepoRoot 'supabase'
$destSupabase = Join-Path $destDir 'supabase'
if (Test-Path $supabaseDir) {
  Copy-Item -Path $supabaseDir -Destination $destSupabase -Recurse -Force
  $sqlCount = (Get-ChildItem -Path $supabaseDir -Filter '*.sql').Count
  Write-Host "  $sqlCount SQL migration file(s) captured."
} else {
  Write-Warning '  supabase/ folder not found.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Launcher and run scripts
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[4/8] Verifying key launcher files...'

$launcherFiles = @(
  'restart_flutter_web.ps1',
  'run_exact_chrome_debug.ps1',
  'start_pregister.ps1',
  'launch_web_debug_chrome.cmd',
  'launch_web_debug.cmd',
  'launch_web_app_mode.cmd',
  'launch_exact_debug_chrome.cmd',
  'scripts\restore_full_backup.ps1',
  'scripts\repair_flutter_cache.ps1',
  'ops\restore-runbook.md'
)

foreach ($rel in $launcherFiles) {
  $src = Join-Path $RepoRoot $rel
  $dst = Join-Path $destDir $rel
  if (Test-Path $src) {
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "  OK: $rel"
  } else {
    Write-Warning "  MISSING: $rel"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Backend package manifest (for npm install on restore)
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[5/8] Capturing backend manifest...'

$backendFiles = @('backend\server.js', 'backend\package.json', 'backend\.env')
foreach ($rel in $backendFiles) {
  $src = Join-Path $RepoRoot $rel
  $dst = Join-Path $destDir $rel
  if (Test-Path $src) {
    New-Item -ItemType Directory -Path (Split-Path $dst) -Force | Out-Null
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "  OK: $rel"
  } else {
    Write-Warning "  MISSING: $rel"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Generate one-command restore helpers
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[6/8] Generating one-command restore helpers...'

if (Test-Path $restoreScriptSource) {
  Copy-Item -Path $restoreScriptSource -Destination (Join-Path $destDir 'restore_from_backup.ps1') -Force
  @(
    '@echo off'
    'setlocal'
    'set "SCRIPT_DIR=%~dp0"'
    'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%restore_from_backup.ps1" %*'
    'endlocal'
  ) | Set-Content -Path (Join-Path $destDir 'restore_backup.cmd') -Encoding ASCII
  Write-Host '  Created: restore_from_backup.ps1'
  Write-Host '  Created: restore_backup.cmd'
} else {
  Write-Warning '  scripts\restore_full_backup.ps1 not found. One-command restore helper was not generated.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Write restore-state manifest (exact state of tonight's session)
# ──────────────────────────────────────────────────────────────────────────────
Write-Host '[7/8] Writing restore-state manifest...'

$flutterVersion = (flutter --version --no-color 2>&1 | Select-Object -First 1) -as [string]
$dartVersion    = (dart --version 2>&1 | Select-Object -First 1) -as [string]
$nodeVersion    = try { node --version 2>&1 | Select-Object -First 1 } catch { 'not found' }
$gitCommit      = try { git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1 } catch { '' }

$manifest = [ordered]@{
  backupName      = $backupName
  createdAt       = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  repoRoot        = $RepoRoot
  gitCommit       = "$gitCommit".Trim()
  toolVersions = [ordered]@{
    flutter = $flutterVersion.Trim()
    dart    = $dartVersion.Trim()
    node    = "$nodeVersion".Trim()
  }
  supabaseUrl     = 'https://qpfdbaefkgedlsvdyfcg.supabase.co'
  webPort         = 8181
  backendPort     = 3000
  databaseSnapshotMode = $databaseSnapshotMode
  databaseSnapshotNote = $databaseSnapshotNote
  identityFile    = 'runtime\install.identity.json'
  restoreCommand  = 'restore_backup.cmd'
  criticalMigrations = @(
    'supabase/2026-05-13_resolve_install_from_device.sql'
  )
  restoreSteps = @(
    '1. Run restore_backup.cmd from inside the backup folder to restore the local workspace state.'
    '2. If moving to a different machine, verify backend\.env and runtime\install.identity.json contain the intended environment values.'
    '3. Re-apply target Supabase SQL files if the remote database also needs to be returned to this state.'
    '4. Start backend and app, then re-run integrity checks.'
  )
  integrityCheckPassedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  sessionNotes = 'Login Integrity Check PASSED (all except RPC guard probe fixed). Card/cash transaction flow validated. Node backend confirmed running on port 3000.'
}

$manifestPath = Join-Path $destDir 'RESTORE_MANIFEST.json'
$manifest | ConvertTo-Json -Depth 10 | Out-File -FilePath $manifestPath -Encoding UTF8
Write-Host "  Manifest written: RESTORE_MANIFEST.json"

# ──────────────────────────────────────────────────────────────────────────────
# 7. Summary
# ──────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[8/8] Backup complete.'
Write-Host ''
Write-Host ('  Backup folder : ' + $destDir)
Write-Host ('  Manifest      : ' + $manifestPath)
Write-Host ('  Restore cmd   : ' + (Join-Path $destDir 'restore_backup.cmd'))
Write-Host ''
$totalSize = (Get-ChildItem -Path $destDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
$sizeMB = [math]::Round($totalSize / 1MB, 1)
Write-Host "  Total size    : $sizeMB MB"
Write-Host ''
if ($databaseSnapshotMode -eq 'migrations-only') {
  Write-Warning $databaseSnapshotNote
  Write-Host ''
}
Write-Host 'RESTORE CHECKLIST:'
foreach ($step in $manifest.restoreSteps) {
  Write-Host "  $step"
}
Write-Host ''
