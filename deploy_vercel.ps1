param(
  [Parameter(Mandatory = $true)]
  [string]$SupabaseUrl,

  [Parameter(Mandatory = $false)]
  [string]$SupabaseAnonKey,

  [Parameter(Mandatory = $false)]
  [string]$AppLicenseKey = 'DEMO-LICENSE-123456',

  [Parameter(Mandatory = $false)]
  [string]$TerminalNumber = '0001',

  [Parameter(Mandatory = $false)]
  [string]$PaymentApiBaseUrl = ''
)

$ErrorActionPreference = 'Stop'

$supabaseKeySource = 'parameter'

if ([string]::IsNullOrWhiteSpace($SupabaseAnonKey)) {
  $SupabaseAnonKey = $env:SUPABASE_ANON_KEY
  $supabaseKeySource = 'environment variable SUPABASE_ANON_KEY'
}

if ([string]::IsNullOrWhiteSpace($SupabaseAnonKey)) {
  throw 'Supabase anon key is required. Pass -SupabaseAnonKey or set SUPABASE_ANON_KEY environment variable.'
}

$keyLen = $SupabaseAnonKey.Length
$head = if ($keyLen -ge 6) { $SupabaseAnonKey.Substring(0, 6) } else { $SupabaseAnonKey }
$tail = if ($keyLen -ge 4) { $SupabaseAnonKey.Substring($keyLen - 4) } else { $SupabaseAnonKey }
Write-Host "Using Supabase anon key from $supabaseKeySource (length: $keyLen, preview: $head...$tail)" -ForegroundColor Yellow

if ([string]::IsNullOrWhiteSpace($PaymentApiBaseUrl)) {
  Write-Host 'PAYMENT_API_BASE_URL not provided. Build will default to localhost:3000.' -ForegroundColor Yellow
} else {
  Write-Host "Using PAYMENT_API_BASE_URL: $PaymentApiBaseUrl" -ForegroundColor Yellow
}

Write-Host 'Building Flutter web app...' -ForegroundColor Cyan
flutter clean
flutter pub get
$buildArgs = @(
  'build', 'web', '--release',
  "--dart-define=SUPABASE_URL=$SupabaseUrl",
  "--dart-define=SUPABASE_ANON_KEY=$SupabaseAnonKey",
  "--dart-define=APP_LICENSE_KEY=$AppLicenseKey",
  "--dart-define=TERMINAL_NUMBER=$TerminalNumber"
)

if (-not [string]::IsNullOrWhiteSpace($PaymentApiBaseUrl)) {
  $buildArgs += "--dart-define=PAYMENT_API_BASE_URL=$PaymentApiBaseUrl"
}

flutter @buildArgs

$deployDir = Join-Path $PSScriptRoot 'build/web'
if (-not (Test-Path $deployDir)) {
  throw "Build output not found at $deployDir"
}

$vercelConfig = @'
{
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ]
}
'@

$vercelConfigPath = Join-Path $deployDir 'vercel.json'
$vercelConfig | Set-Content -Path $vercelConfigPath -Encoding ascii

Write-Host 'Deploying build/web to Vercel production...' -ForegroundColor Cyan
Push-Location $deployDir
try {
  vercel --prod
}
finally {
  Pop-Location
}

Write-Host 'Done.' -ForegroundColor Green
