param(
  [string]$RepoRoot = $PSScriptRoot,
  [int]$BackendPort = 3000,
  [string]$BackendHost = '127.0.0.1',
  [string]$SupabaseUrl = 'https://qpfdbaefkgedlsvdyfcg.supabase.co',
  [string]$SupabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFwZmRiYWVma2dlZGxzdmR5ZmNnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzExOTM2MTYsImV4cCI6MjA4Njc2OTYxNn0.LZxDqe0HrQVR7vLQ1i-Xw76kdmExHaji1CPO_-G0YT8',
  [string]$AppLicenseKey = '',
  [string]$OrganizationNumber = '',
  [string]$TerminalNumber = '',
  [string]$LocationName = '',
  [string]$SpinTpn = '',
  [string]$SpinAuthKey = '',
  [string]$AppDeviceId = '',
  [string]$AppDeviceLabel = '',
  [string]$InstallIdentityPath = '',
  [object]$SpinSandbox = $true,
  [object]$DebugMode = $true,
  [switch]$ForceActivationScreen,
  [switch]$SkipBackendRestart,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

function ConvertTo-Bool {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Value,
    [string]$ParamName = 'value'
  )

  if ($Value -is [bool]) {
    return [bool]$Value
  }

  $text = [string]$Value
  $normalized = $text.Trim().ToLowerInvariant()

  switch ($normalized) {
    'true' { return $true }
    'false' { return $false }
    '1' { return $true }
    '0' { return $false }
    '$true' { return $true }
    '$false' { return $false }
    default {
      throw "$ParamName must be a boolean value (true/false/1/0). Received: '$text'"
    }
  }
}

$SpinSandbox = ConvertTo-Bool -Value $SpinSandbox -ParamName 'SpinSandbox'
$DebugMode = ConvertTo-Bool -Value $DebugMode -ParamName 'DebugMode'

if (-not (Test-Path -Path $RepoRoot)) {
  throw "Repo root not found: $RepoRoot"
}

if (-not $SkipBackendRestart) {
  $startScript = Join-Path $RepoRoot 'start_pregister.ps1'
  if (Test-Path -Path $startScript) {
    Write-Host 'Refreshing backend before Flutter Windows launch...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $startScript -RepoRoot $RepoRoot -SkipLaunchApp -ForceRestartBackend
  } else {
    Write-Warning "start_pregister.ps1 not found at $startScript; skipping backend refresh."
  }
}

if ([string]::IsNullOrWhiteSpace($InstallIdentityPath)) {
  $InstallIdentityPath = Join-Path $RepoRoot 'runtime\install.identity.json'
}

if ($ForceActivationScreen) {
  $prefsPath = Join-Path $env:APPDATA 'com.example\pregister\shared_preferences.json'

  if (Test-Path -Path $InstallIdentityPath) {
    Remove-Item -Path $InstallIdentityPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed install identity: $InstallIdentityPath"
  }

  if (Test-Path -Path $prefsPath) {
    Remove-Item -Path $prefsPath -Force -ErrorAction SilentlyContinue
    Write-Host "Removed app preferences: $prefsPath"
  }

  # Keep all startup identity fields empty so the app lands on activation UI.
  $AppLicenseKey = ''
  $OrganizationNumber = ''
  $TerminalNumber = ''
  $LocationName = ''
  $SpinTpn = ''
  $SpinAuthKey = ''
  $AppDeviceId = ''
  $AppDeviceLabel = ''
}

if (Test-Path -Path $InstallIdentityPath) {
  try {
    $identity = Get-Content -Path $InstallIdentityPath -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($AppLicenseKey) -and $identity.appLicenseKey) {
      $AppLicenseKey = [string]$identity.appLicenseKey
    }
    if ([string]::IsNullOrWhiteSpace($OrganizationNumber) -and $identity.organizationNumber) {
      $OrganizationNumber = [string]$identity.organizationNumber
    }
    if ([string]::IsNullOrWhiteSpace($TerminalNumber) -and $identity.terminalNumber) {
      $TerminalNumber = [string]$identity.terminalNumber
    }
    if ([string]::IsNullOrWhiteSpace($LocationName) -and $identity.locationName) {
      $LocationName = [string]$identity.locationName
    }
    if ([string]::IsNullOrWhiteSpace($SpinTpn) -and $identity.spinTpn) {
      $SpinTpn = [string]$identity.spinTpn
    }
    if ([string]::IsNullOrWhiteSpace($SpinAuthKey) -and $identity.spinAuthKey) {
      $SpinAuthKey = [string]$identity.spinAuthKey
    }
    if ([string]::IsNullOrWhiteSpace($AppDeviceId) -and $identity.appDeviceId) {
      $AppDeviceId = [string]$identity.appDeviceId
    }
    if ([string]::IsNullOrWhiteSpace($AppDeviceLabel) -and $identity.appDeviceLabel) {
      $AppDeviceLabel = [string]$identity.appDeviceLabel
    }
  } catch {
    Write-Warning ("Failed to parse install identity file at {0}. {1}" -f $InstallIdentityPath, $_.Exception.Message)
  }
}

$prefsPath = Join-Path $env:APPDATA 'com.example\pregister\shared_preferences.json'
if (Test-Path -Path $prefsPath) {
  try {
    $prefs = Get-Content -Path $prefsPath -Raw | ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace($AppLicenseKey) -and $prefs.'flutter.app_license_key') {
      $AppLicenseKey = [string]$prefs.'flutter.app_license_key'
    }
    if ([string]::IsNullOrWhiteSpace($TerminalNumber) -and $prefs.'flutter.app_terminal_number') {
      $TerminalNumber = [string]$prefs.'flutter.app_terminal_number'
    }
    if ([string]::IsNullOrWhiteSpace($LocationName) -and $prefs.'flutter.app_location_name') {
      $LocationName = [string]$prefs.'flutter.app_location_name'
    }
    if ([string]::IsNullOrWhiteSpace($SpinTpn) -and $prefs.'flutter.app_spin_tpn') {
      $SpinTpn = [string]$prefs.'flutter.app_spin_tpn'
    }
    if ([string]::IsNullOrWhiteSpace($SpinAuthKey) -and $prefs.'flutter.app_spin_auth_key') {
      $SpinAuthKey = [string]$prefs.'flutter.app_spin_auth_key'
    }
    if ([string]::IsNullOrWhiteSpace($AppDeviceId) -and $prefs.'flutter.app_device_id') {
      $AppDeviceId = [string]$prefs.'flutter.app_device_id'
    }
    if ([string]::IsNullOrWhiteSpace($AppDeviceLabel) -and $prefs.'flutter.app_device_label') {
      $AppDeviceLabel = [string]$prefs.'flutter.app_device_label'
    }
  } catch {
    Write-Warning ("Failed to parse shared preferences at {0}. {1}" -f $prefsPath, $_.Exception.Message)
  }
}

if ([string]::IsNullOrWhiteSpace($AppLicenseKey) -and -not [string]::IsNullOrWhiteSpace($OrganizationNumber)) {
  Write-Warning 'APP_LICENSE_KEY missing in install identity; using ORGANIZATION_NUMBER fallback for startup lookup.'
  $AppLicenseKey = $OrganizationNumber
}

if ([string]::IsNullOrWhiteSpace($TerminalNumber)) {
  $TerminalNumber = '0001'
}

$paymentApiBaseUrl = "http://${BackendHost}:$BackendPort"

$flutterArgs = @(
  'run',
  '-d', 'windows',
  "--dart-define=SUPABASE_URL=$SupabaseUrl",
  "--dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey",
  "--dart-define=PAYMENT_API_BASE_URL=$paymentApiBaseUrl",
  "--dart-define=APP_LICENSE_KEY=$AppLicenseKey",
  "--dart-define=ORGANIZATION_NUMBER=$OrganizationNumber",
  "--dart-define=TERMINAL_NUMBER=$TerminalNumber",
  "--dart-define=LOCATION_NAME=$LocationName",
  "--dart-define=SPIN_TPN=$SpinTpn",
  "--dart-define=SPIN_AUTH_KEY=$SpinAuthKey",
  "--dart-define=APP_DEVICE_ID=$AppDeviceId",
  "--dart-define=APP_DEVICE_LABEL=$AppDeviceLabel",
  "--dart-define=SPIN_SANDBOX=$SpinSandbox",
  "--dart-define=DEBUG_MODE=$DebugMode"
)

Push-Location $RepoRoot
try {
  Write-Host "Starting Flutter on windows"
  Write-Host "Command: flutter $($flutterArgs -join ' ')"
  if (-not $DryRun) {
    & flutter @flutterArgs
  }
} finally {
  Pop-Location
}
