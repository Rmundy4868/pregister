Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $projectRoot 'backup'
$backupDir = Join-Path $backupRoot "pregister-backup-$timestamp"

if (-not (Test-Path -Path $backupRoot)) {
	New-Item -Path $backupRoot -ItemType Directory | Out-Null
}

Write-Host "Creating backup: $backupDir"

# Exclude paths that are large, generated, or cause recursive backups.
$excludeDirs = @(
	(Join-Path $projectRoot 'backup'),
	(Join-Path $projectRoot '.git'),
	(Join-Path $projectRoot 'build'),
	(Join-Path $projectRoot '.dart_tool'),
	(Join-Path $projectRoot 'node_modules'),
	(Join-Path $projectRoot 'backend\node_modules'),
	(Join-Path $projectRoot 'windows\flutter\ephemeral'),
	(Join-Path $projectRoot 'linux\flutter\ephemeral'),
	(Join-Path $projectRoot 'macos\Flutter\ephemeral')
)

$excludeFiles = @(
	'*.tmp',
	'*.lock',
	'Thumbs.db',
	'.DS_Store'
)

$robocopyArgs = @(
	$projectRoot,
	$backupDir,
	'/E',
	'/R:1',
	'/W:1',
	'/XJ',
	'/NP',
	'/NFL',
	'/NDL',
	'/NJH',
	'/NJS',
	'/XD'
) + $excludeDirs + @('/XF') + $excludeFiles

& robocopy @robocopyArgs | Out-Host
$rc = $LASTEXITCODE

# Robocopy exit codes 0-7 indicate success or non-fatal differences.
if ($rc -gt 7) {
	throw "Backup failed (robocopy exit code $rc)."
}

Write-Host "Backup complete: $backupDir"
