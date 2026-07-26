param(
  [string]$RepoRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$identityPath = Join-Path $RepoRoot 'runtime\install.identity.json'
$prefsPath = Join-Path $env:APPDATA 'com.example\pregister\shared_preferences.json'

if (Test-Path -Path $identityPath) {
  Remove-Item -Path $identityPath -Force -ErrorAction SilentlyContinue
  Write-Host "Removed: $identityPath"
} else {
  Write-Host "Not found: $identityPath"
}

if (Test-Path -Path $prefsPath) {
  Remove-Item -Path $prefsPath -Force -ErrorAction SilentlyContinue
  Write-Host "Removed: $prefsPath"
} else {
  Write-Host "Not found: $prefsPath"
}

Write-Host 'Activation cache reset complete.'
