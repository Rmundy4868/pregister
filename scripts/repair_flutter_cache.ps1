param(
  [string]$ProjectRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -Path $ProjectRoot)) {
  throw "Project root not found: $ProjectRoot"
}

# Move to repo root when script is under scripts/
if ((Split-Path -Leaf $ProjectRoot) -ieq 'scripts') {
  $ProjectRoot = Split-Path -Parent $ProjectRoot
}

$cacheRoot = Join-Path $env:LOCALAPPDATA 'Pub\Cache\hosted\pub.dev'
$knownCorruptPackages = @(
  'app_links-7.0.0',
  'app_links_linux-1.0.3',
  'gtk-2.2.0',
  'jni-1.0.0',
  'path_provider_linux-2.2.1',
  'path_provider_windows-2.3.0',
  'printing-5.14.3',
  'shared_preferences_linux-2.4.1',
  'shared_preferences_windows-2.4.1',
  'url_launcher_linux-3.2.2',
  'url_launcher_windows-3.1.5'
)

Write-Host 'Checking known corrupt pub cache package folders...'
foreach ($pkg in $knownCorruptPackages) {
  $pkgDir = Join-Path $cacheRoot $pkg
  if (Test-Path -Path $pkgDir) {
    $pubspec = Join-Path $pkgDir 'pubspec.yaml'
    if (-not (Test-Path -Path $pubspec)) {
      Write-Host "Removing corrupt cache folder: $pkgDir"
      Remove-Item -Path $pkgDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}

Push-Location $ProjectRoot
try {
  Write-Host 'Running flutter clean...'
  flutter clean

  Write-Host 'Running flutter pub get...'
  flutter pub get

  Write-Host 'Running flutter pub cache repair (best effort)...'
  flutter pub cache repair

  Write-Host 'Running flutter pub get after repair...'
  flutter pub get

  Write-Host 'Cache repair flow complete.'
} finally {
  Pop-Location
}
