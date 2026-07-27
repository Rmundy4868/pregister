param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$SupabaseUrl = '',
  [string]$SupabaseAnonKey = '',
  [string]$PaymentApiBaseUrl = 'https://pregister.onrender.com',
  [string]$BuildName = '',
  [string]$BuildNumber = '',
  [bool]$SpinSandbox = $false,
  [bool]$DebugMode = $false,
  [string]$OutputDir = '',
  [switch]$SkipBuild,
  [switch]$SkipZip,
  [switch]$TryInnoSetup
)

$ErrorActionPreference = 'Stop'

function Resolve-InnoSetupCompiler {
  $candidates = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe'
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -Path $candidate) {
      return $candidate
    }
  }

  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd) {
    return $cmd.Source
  }

  return $null
}

function Get-PubspecVersion {
  param([string]$PubspecPath)

  if (-not (Test-Path -Path $PubspecPath)) {
    throw "pubspec.yaml not found at $PubspecPath"
  }

  $line = (Get-Content -Path $PubspecPath | Where-Object { $_ -match '^version:\s*' } | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($line)) {
    throw 'Unable to find version in pubspec.yaml.'
  }

  $raw = $line -replace '^version:\s*', ''
  return ($raw -split '\+')[0].Trim()
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $RepoRoot 'dist'
}

if (-not (Test-Path -Path $RepoRoot)) {
  throw "Repo root not found: $RepoRoot"
}

$pubspecPath = Join-Path $RepoRoot 'pubspec.yaml'
$version = if ([string]::IsNullOrWhiteSpace($BuildName)) { Get-PubspecVersion -PubspecPath $pubspecPath } else { $BuildName }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$artifactBase = "pregister-terminal-v$version-windows-$timestamp"
$artifactDir = Join-Path $OutputDir $artifactBase

$releaseDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'

if (-not $SkipBuild) {
  Write-Host 'Building Flutter Windows release...'

  $flutterArgs = @('build', 'windows', '--release')
  if (-not [string]::IsNullOrWhiteSpace($BuildName)) {
    $flutterArgs += "--build-name=$BuildName"
  }
  if (-not [string]::IsNullOrWhiteSpace($BuildNumber)) {
    $flutterArgs += "--build-number=$BuildNumber"
  }
  if (-not [string]::IsNullOrWhiteSpace($SupabaseUrl)) {
    $flutterArgs += "--dart-define=SUPABASE_URL=$SupabaseUrl"
  }
  if (-not [string]::IsNullOrWhiteSpace($SupabaseAnonKey)) {
    $flutterArgs += "--dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey"
  }
  if (-not [string]::IsNullOrWhiteSpace($PaymentApiBaseUrl)) {
    $flutterArgs += "--dart-define=PAYMENT_API_BASE_URL=$PaymentApiBaseUrl"
  }
  $flutterArgs += "--dart-define=SPIN_SANDBOX=$SpinSandbox"
  $flutterArgs += "--dart-define=DEBUG_MODE=$DebugMode"

  Push-Location $RepoRoot
  try {
    & flutter @flutterArgs
  } finally {
    Pop-Location
  }
}

if (-not (Test-Path -Path $releaseDir)) {
  throw "Windows release output not found: $releaseDir"
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
if (Test-Path -Path $artifactDir) {
  Remove-Item -Path $artifactDir -Recurse -Force
}
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null

Write-Host "Staging release files into: $artifactDir"
Copy-Item -Path (Join-Path $releaseDir '*') -Destination $artifactDir -Recurse -Force

$notes = @(
  'PRegister Windows Distribution',
  '',
  "Version: $version",
  "Built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
  "Backend API URL baked into app: $PaymentApiBaseUrl",
  '',
  'How to run:',
  '1. Open this folder.',
  '2. Run pregister.exe.',
  '',
  'This desktop app can still use hosted services:',
  '- Render backend API',
  '- Vercel-hosted pages/routes used by your flow'
)
Set-Content -Path (Join-Path $artifactDir 'README-WINDOWS.txt') -Value $notes -Encoding utf8

$deactivateScriptName = 'deactivate_install_on_uninstall.ps1'
$deactivateScriptPath = Join-Path $artifactDir $deactivateScriptName
$deactivateScript = @"
param()

`$ErrorActionPreference = 'SilentlyContinue'
`$supabaseUrl = '$SupabaseUrl'
`$supabaseAnonKey = '$SupabaseAnonKey'

if ([string]::IsNullOrWhiteSpace(`$supabaseUrl) -or [string]::IsNullOrWhiteSpace(`$supabaseAnonKey)) {
  exit 0
}

`$prefsPath = Join-Path `$env:APPDATA 'com.example\pregister\shared_preferences.json'
if (-not (Test-Path -Path `$prefsPath)) {
  exit 0
}

try {
  `$prefs = Get-Content -Path `$prefsPath -Raw | ConvertFrom-Json
} catch {
  exit 0
}

`$licenseKey = [string](`$prefs.'flutter.app_license_key')
`$terminalNumber = [string](`$prefs.'flutter.app_terminal_number')
`$locationName = [string](`$prefs.'flutter.app_location_name')
`$deviceId = [string](`$prefs.'flutter.app_device_id')

if ([string]::IsNullOrWhiteSpace(`$licenseKey)) {
  exit 0
}

`$body = @{
  p_license_key = `$licenseKey.Trim()
  p_deactivate_terminal = `$true
}

if (-not [string]::IsNullOrWhiteSpace(`$terminalNumber)) {
  `$body.p_terminal_number = `$terminalNumber.Trim()
}
if (-not [string]::IsNullOrWhiteSpace(`$locationName)) {
  `$body.p_location_name = `$locationName.Trim()
}
if (-not [string]::IsNullOrWhiteSpace(`$deviceId)) {
  `$body.p_device_id = `$deviceId.Trim()
}

Invoke-RestMethod `
  -Uri ((`$supabaseUrl.TrimEnd('/')) + '/rest/v1/rpc/deactivate_install_license') `
  -Method Post `
  -Headers @{
    apikey = `$supabaseAnonKey
    Authorization = 'Bearer ' + `$supabaseAnonKey
    'Content-Type' = 'application/json'
    Accept = 'application/json'
  } `
  -Body (`$body | ConvertTo-Json -Compress -Depth 5) | Out-Null

exit 0
"@
Set-Content -Path $deactivateScriptPath -Value $deactivateScript -Encoding ascii

$zipPath = Join-Path $OutputDir ($artifactBase + '.zip')
if (-not $SkipZip) {
  if (Test-Path -Path $zipPath) {
    Remove-Item -Path $zipPath -Force
  }
  Write-Host "Creating ZIP: $zipPath"
  Compress-Archive -Path (Join-Path $artifactDir '*') -DestinationPath $zipPath -CompressionLevel Optimal

  $sha = Get-FileHash -Path $zipPath -Algorithm SHA256
  $shaLine = "{0} *{1}" -f $sha.Hash.ToLowerInvariant(), (Split-Path -Path $zipPath -Leaf)
  $shaPath = $zipPath + '.sha256'
  Set-Content -Path $shaPath -Value $shaLine -Encoding ascii
}

$innoOutput = $null
if ($TryInnoSetup) {
  $iscc = Resolve-InnoSetupCompiler
  if ($null -eq $iscc) {
    Write-Warning 'Inno Setup compiler not found (ISCC.exe). Skipping Setup.exe creation.'
  } else {
    $issPath = Join-Path $env:TEMP ("pregister-installer-$timestamp.iss")
    $safeArtifactDir = $artifactDir -replace '\\', '\\\\'
    $safeOutputDir = $OutputDir -replace '\\', '\\\\'

    $iss = @"
[Setup]
AppName=PRegister Terminal
AppVersion=$version
DefaultDirName={autopf}\\PRegister Terminal
DefaultGroupName=PRegister Terminal
OutputDir=$safeOutputDir
OutputBaseFilename=pregister-terminal-v$version-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: desktopicon; Description: "Create a desktop icon"; GroupDescription: "Additional icons:";

[Files]
Source: "$safeArtifactDir\\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\\PRegister Terminal"; Filename: "{app}\\pregister.exe"
Name: "{autodesktop}\\PRegister Terminal"; Filename: "{app}\\pregister.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\\pregister.exe"; Description: "Launch PRegister Terminal"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\$deactivateScriptName"""; Flags: runhidden waituntilterminated skipifdoesntexist

[UninstallDelete]
Type: filesandordirs; Name: "{userappdata}\com.example\pregister"
"@

    Set-Content -Path $issPath -Value $iss -Encoding ascii
    try {
      Write-Host "Building Setup.exe with Inno Setup: $iscc"
      & $iscc $issPath
      $innoOutput = Join-Path $OutputDir "pregister-terminal-v$version-setup.exe"
    } finally {
      Remove-Item -Path $issPath -Force -ErrorAction SilentlyContinue
    }
  }
}

Write-Host ''
Write-Host 'Windows distribution complete.'
Write-Host "- Staged folder: $artifactDir"
if (-not $SkipZip) {
  Write-Host "- ZIP package: $zipPath"
  Write-Host "- ZIP checksum: $($zipPath).sha256"
}
if ($innoOutput) {
  Write-Host "- Setup installer: $innoOutput"
  if (Test-Path -Path $innoOutput) {
    $setupSha = Get-FileHash -Path $innoOutput -Algorithm SHA256
    $setupShaLine = "{0} *{1}" -f $setupSha.Hash.ToLowerInvariant(), (Split-Path -Path $innoOutput -Leaf)
    $setupShaPath = $innoOutput + '.sha256'
    Set-Content -Path $setupShaPath -Value $setupShaLine -Encoding ascii
    Write-Host "- Setup checksum: $setupShaPath"
  }
}
