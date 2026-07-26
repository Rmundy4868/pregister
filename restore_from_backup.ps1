param(
  [string]$BackupPath = (Split-Path -Parent $PSScriptRoot),
  [string]$TargetRoot = '',
  [switch]$SkipFlutterPubGet,
  [switch]$SkipBackendInstall,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$resolvedBackupPath = (Resolve-Path $BackupPath).Path
if ([string]::IsNullOrWhiteSpace($TargetRoot)) {
  $TargetRoot = Split-Path -Parent $resolvedBackupPath
}

$resolvedTargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)
$manifestPath = Join-Path $resolvedBackupPath 'RESTORE_MANIFEST.json'
$excludedSnapshotItems = @('RESTORE_MANIFEST.json', 'restore_from_backup.ps1', 'restore_backup.cmd')
$preserveTargetItems = @('backup')

Write-Host "Backup path : $resolvedBackupPath"
Write-Host "Target root : $resolvedTargetRoot"
Write-Host ''

if (-not (Test-Path $resolvedTargetRoot)) {
  if ($DryRun) {
    Write-Host "[dry-run] Would create target root: $resolvedTargetRoot"
  } else {
    New-Item -ItemType Directory -Path $resolvedTargetRoot -Force | Out-Null
  }
}

$backupItems = Get-ChildItem -Path $resolvedBackupPath -Force | Where-Object {
  $excludedSnapshotItems -notcontains $_.Name
}

Write-Host '[1/3] Resetting target root to snapshot state...'
$targetItems = @()
if (Test-Path $resolvedTargetRoot) {
  $targetItems = Get-ChildItem -Path $resolvedTargetRoot -Force | Where-Object {
    $preserveTargetItems -notcontains $_.Name
  }
}

foreach ($item in $targetItems) {
  if ($DryRun) {
    Write-Host "  [dry-run] Remove: $($item.FullName)"
  } else {
    Remove-Item -Path $item.FullName -Recurse -Force
  }
}

Write-Host '[2/3] Restoring snapshot files...'
foreach ($item in $backupItems) {
  $destination = Join-Path $resolvedTargetRoot $item.Name
  if ($DryRun) {
    Write-Host "  [dry-run] Copy: $($item.FullName) -> $destination"
    continue
  }

  Copy-Item -Path $item.FullName -Destination $destination -Recurse -Force
}

Write-Host '[3/3] Restoring dependencies...'
if ($DryRun) {
  if (-not $SkipFlutterPubGet) {
    Write-Host "  [dry-run] Would run: flutter pub get"
  }
  if (-not $SkipBackendInstall) {
    Write-Host "  [dry-run] Would run backend package restore (npm ci/npm install)"
  }
} else {
  if (-not $SkipFlutterPubGet -and (Test-Path (Join-Path $resolvedTargetRoot 'pubspec.yaml'))) {
    Push-Location $resolvedTargetRoot
    try {
      flutter pub get
    } finally {
      Pop-Location
    }
  }

  $backendDir = Join-Path $resolvedTargetRoot 'backend'
  if (-not $SkipBackendInstall -and (Test-Path (Join-Path $backendDir 'package.json'))) {
    Push-Location $backendDir
    try {
      if (Test-Path (Join-Path $backendDir 'package-lock.json')) {
        npm ci
      } else {
        npm install
      }
    } finally {
      Pop-Location
    }
  }
}

if (Test-Path $manifestPath) {
  try {
    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    Write-Host ''
    Write-Host 'Restore manifest summary:'
    Write-Host "  Backup name         : $($manifest.backupName)"
    Write-Host "  Created at          : $($manifest.createdAt)"
    Write-Host "  Database snapshot   : $($manifest.databaseSnapshotMode)"
    if ($manifest.databaseSnapshotNote) {
      Write-Warning "  $($manifest.databaseSnapshotNote)"
    }
  } catch {
    Write-Warning 'Failed to read RESTORE_MANIFEST.json summary.'
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host 'Dry run complete.'
} else {
  Write-Host 'Restore complete.'
}
