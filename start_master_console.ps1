param(
  [string]$RepoRoot = $PSScriptRoot,
  [ValidateSet('chrome', 'edge', 'web-server', 'windows')]
  [string]$Device = 'chrome',
  [int]$WebPort = 8282,
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

# Paste your Supabase values here.
$SupabaseUrl = 'https://YOUR_PROJECT.supabase.co'
$SupabaseAnonKey = 'YOUR_ANON_KEY'

if ([string]::IsNullOrWhiteSpace($SupabaseUrl) -or $SupabaseUrl -like '*YOUR_PROJECT*') {
  throw 'Set $SupabaseUrl in start_master_console.ps1 before running.'
}

if ([string]::IsNullOrWhiteSpace($SupabaseAnonKey) -or $SupabaseAnonKey -like '*YOUR_ANON_KEY*') {
  throw 'Set $SupabaseAnonKey in start_master_console.ps1 before running.'
}

function Stop-PortOwner {
  param([int]$Port)

  $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1

  if ($null -eq $listener) {
    return
  }

  $ownerPid = [int]$listener.OwningProcess
  Write-Host "Stopping existing listener on port $Port (PID $ownerPid)"
  Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -Path $RepoRoot)) {
  throw "Repo root not found: $RepoRoot"
}

$targetDevice = if ($NoBrowser) { 'web-server' } else { $Device }

$flutterArgs = @(
  'run',
  '-d', $targetDevice,
  "--dart-define=APP_SHELL=master_console",
  "--dart-define=SUPABASE_URL=$SupabaseUrl",
  "--dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey"
)

if ($targetDevice -eq 'chrome' -or $targetDevice -eq 'edge' -or $targetDevice -eq 'web-server') {
  Stop-PortOwner -Port $WebPort
  $flutterArgs += @('--web-port', "$WebPort")
}

Push-Location $RepoRoot
try {
  Write-Host 'Starting PaaayIT Master Console...'
  Write-Host "Device: $targetDevice"
  if ($targetDevice -eq 'chrome' -or $targetDevice -eq 'edge' -or $targetDevice -eq 'web-server') {
    Write-Host "URL: http://localhost:$WebPort"
  }
  Write-Host "Command: flutter $($flutterArgs -join ' ')"
  & flutter @flutterArgs
} finally {
  Pop-Location
}
