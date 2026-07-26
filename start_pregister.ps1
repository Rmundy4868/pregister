param(
  [string]$RepoRoot = $PSScriptRoot,
  [int]$BackendPort = 3000,
  [string]$BackendHost = '127.0.0.1',
  [string]$BackendDir = '',
  [string]$BackendScript = 'server.js',
  [string]$AppExePath = '',
  [string]$AppUrl = '',
  [switch]$SkipLaunchApp,
  [switch]$ForceRestartBackend,
  [int]$BackendWaitSeconds = 12
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BackendDir)) {
  $BackendDir = Join-Path $RepoRoot 'backend'
}

$healthUrl = "http://${BackendHost}:$BackendPort/api/health"

function Test-BackendHealth {
  param([string]$Url)

  try {
    $response = Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 2
    if ($null -ne $response -and ($response.ok -eq $true -or $response.service -eq 'pregister-backend')) {
      return $true
    }
  } catch {
    return $false
  }

  return $false
}

function Get-ListeningProcessId {
  param([int]$Port)

  try {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
      Select-Object -First 1
    if ($null -ne $listener) {
      return [int]$listener.OwningProcess
    }
  } catch {
  }

  return $null
}

function Ensure-BackendRunning {
  param(
    [string]$Url,
    [int]$Port,
    [string]$WorkingDir,
    [string]$ScriptName,
    [int]$WaitSeconds,
    [switch]$ForceRestart
  )

  if (Test-BackendHealth -Url $Url) {
    if (-not $ForceRestart) {
      Write-Host "Backend healthy at $Url"
      return
    }

    $healthyPid = Get-ListeningProcessId -Port $Port
    if ($null -ne $healthyPid) {
      Write-Host "ForceRestart enabled. Stopping healthy backend PID $healthyPid on port $Port."
      try {
        Stop-Process -Id $healthyPid -Force -ErrorAction Stop
      } catch {
        Write-Warning "Failed to stop healthy backend PID $healthyPid on port ${Port}: $($_.Exception.Message)"
      }
    }
  }

  $existingPid = Get-ListeningProcessId -Port $Port
  if ($null -ne $existingPid) {
    # Port is occupied but /api/health failed, so this is stale/wrong process
    # for this backend. Restart it to recover deterministically.
    if (-not $ForceRestart) {
      Write-Warning "Port $Port is occupied by PID $existingPid but health check failed. Restarting process on that port."
    }
    try {
      Stop-Process -Id $existingPid -Force -ErrorAction Stop
      Write-Host "Stopped existing process on port $Port (PID $existingPid)."
    } catch {
      Write-Warning "Failed to stop PID $existingPid on port ${Port}: $($_.Exception.Message)"
    }
  }

  if (-not (Test-Path -Path $WorkingDir)) {
    throw "Backend directory not found: $WorkingDir"
  }

  $scriptPath = Join-Path $WorkingDir $ScriptName
  if (-not (Test-Path -Path $scriptPath)) {
    throw "Backend script not found: $scriptPath"
  }

  Write-Host "Starting backend: node $ScriptName (cwd: $WorkingDir)"
  $logFile = Join-Path $WorkingDir 'backend.log'
  Start-Process -FilePath 'node' -ArgumentList $ScriptName -WorkingDirectory $WorkingDir -WindowStyle Hidden -RedirectStandardOutput $logFile  | Out-Null

  $deadline = (Get-Date).AddSeconds($WaitSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-BackendHealth -Url $Url) {
      Write-Host "Backend started and healthy at $Url"
      return
    }
    Start-Sleep -Milliseconds 500
  }

  throw "Backend failed health check at $Url after ${WaitSeconds}s"
}

Ensure-BackendRunning -Url $healthUrl -Port $BackendPort -WorkingDir $BackendDir -ScriptName $BackendScript -WaitSeconds $BackendWaitSeconds -ForceRestart:$ForceRestartBackend

if (-not $SkipLaunchApp) {
  if (-not [string]::IsNullOrWhiteSpace($AppUrl)) {
    Write-Host "Launching app URL: $AppUrl"
    Start-Process $AppUrl | Out-Null
  } else {
    $candidateExePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($AppExePath)) {
      $candidateExePaths += $AppExePath
    }
    $candidateExePaths += @(
      (Join-Path $RepoRoot 'pregister.exe'),
      (Join-Path $RepoRoot 'app\pregister.exe'),
      (Join-Path $RepoRoot 'build\windows\x64\runner\Release\pregister.exe')
    )

    $resolvedExe = $null
    foreach ($candidate in $candidateExePaths) {
      if ([string]::IsNullOrWhiteSpace($candidate)) {
        continue
      }

      $pathToCheck = $candidate
      if (-not [System.IO.Path]::IsPathRooted($pathToCheck)) {
        $pathToCheck = Join-Path $RepoRoot $pathToCheck
      }

      if (Test-Path -Path $pathToCheck) {
        $resolvedExe = $pathToCheck
        break
      }
    }

    if ($null -ne $resolvedExe) {
      Write-Host "Launching local app: $resolvedExe"
      Start-Process -FilePath $resolvedExe | Out-Null
    } else {
      Write-Host 'Backend is running. No AppUrl provided and no app executable was found.'
      Write-Host 'Pass -AppExePath "C:\Path\To\pregister.exe" or -AppUrl "https://..." in the desktop shortcut command.'
    }
  }
}
