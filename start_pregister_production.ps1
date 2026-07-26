param(
  [string]$RepoRoot = $PSScriptRoot,
  [string]$AppExePath = '',
  [string]$AppUrl = '',
  [int]$BackendPort = 3000,
  [string]$BackendHost = '127.0.0.1',
  [string]$BackendDir = '',
  [string]$BackendScript = 'server.js',
  [switch]$ForceRestartBackend,
  [int]$BackendWaitSeconds = 12
)

$ErrorActionPreference = 'Stop'

function Show-StartupMessage {
  param(
    [string]$Title,
    [string]$Message,
    [ValidateSet('Info', 'Warning', 'Error')]
    [string]$Level = 'Info'
  )

  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $icon = switch ($Level) {
      'Error' { [System.Windows.Forms.MessageBoxIcon]::Error }
      'Warning' { [System.Windows.Forms.MessageBoxIcon]::Warning }
      default { [System.Windows.Forms.MessageBoxIcon]::Information }
    }
    [System.Windows.Forms.MessageBox]::Show(
      $Message,
      $Title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      $icon
    ) | Out-Null
  } catch {
    Write-Warning "$Title`n$Message"
  }
}

try {
  $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $nodeCmd) {
    Show-StartupMessage -Title 'PRegister Startup Error' -Level 'Error' -Message (
      'Node.js is not installed or not available in PATH.' + [Environment]::NewLine +
      [Environment]::NewLine +
      'Card processing backend cannot start without Node.js.' + [Environment]::NewLine +
      'Please install Node.js LTS and retry.'
    )
    throw 'Node.js command not found.'
  }

  $launcherPath = Join-Path $RepoRoot 'start_pregister.ps1'
  if (-not (Test-Path -Path $launcherPath)) {
    Show-StartupMessage -Title 'PRegister Startup Error' -Level 'Error' -Message (
      "Missing launcher script: $launcherPath"
    )
    throw "Missing launcher script: $launcherPath"
  }

  $launchParams = @{
    RepoRoot = $RepoRoot
    BackendPort = $BackendPort
    BackendHost = $BackendHost
    BackendDir = $BackendDir
    BackendScript = $BackendScript
    AppExePath = $AppExePath
    AppUrl = $AppUrl
    BackendWaitSeconds = $BackendWaitSeconds
  }

  if ($ForceRestartBackend) {
    $launchParams['ForceRestartBackend'] = $true
  }

  & $launcherPath @launchParams
} catch {
  $message = $_.Exception.Message
  if ([string]::IsNullOrWhiteSpace($message)) {
    $message = $_.ToString()
  }

  Show-StartupMessage -Title 'PRegister Startup Error' -Level 'Error' -Message (
    'Unable to launch PRegister.' + [Environment]::NewLine +
    [Environment]::NewLine +
    $message + [Environment]::NewLine +
    [Environment]::NewLine +
    'Please contact support if this persists.'
  )

  throw
}
