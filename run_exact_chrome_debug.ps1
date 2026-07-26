param(
  [string]$RepoRoot = $PSScriptRoot,
  [int]$WebPort = 8181
)

$ErrorActionPreference = 'Stop'

function Stop-WebPortOwner {
  param([int]$Port)

  $connections = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty OwningProcess -Unique

  if ($null -eq $connections) {
    Write-Host "Port $Port is already free."
    return
  }

  foreach ($pid in $connections) {
    if ($null -eq $pid) { continue }
    Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped PID $pid on port $Port"
  }
}

if (-not (Test-Path -Path $RepoRoot)) {
  throw "Repo root not found: $RepoRoot"
}

Push-Location $RepoRoot
try {
  Stop-WebPortOwner -Port $WebPort

  $flutterArgs = @(
    'run',
    '-d', 'chrome',
    "--web-port=$WebPort",
    '--dart-define=SUPABASE_URL=https://qpfdbaefkgedlsvdyfcg.supabase.co',
    '--dart-define=SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFwZmRiYWVma2dlZGxzdmR5ZmNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExOTM2MTYsImV4cCI6MjA4Njc2OTYxNn0.LZxDqe0HrQVR7vLQ1i-Xw76kdmExHaji1CPO_-G0YT8',
    '--dart-define=SPIN_SANDBOX=true',
    '--dart-define=DEBUG_MODE=true'
  )

  Write-Host "Running: flutter $($flutterArgs -join ' ')"
  & flutter @flutterArgs
} finally {
  Pop-Location
}
