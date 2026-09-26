$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not $env:PHX_SERVER) { $env:PHX_SERVER = "true" }
if (-not $env:PORT) { $env:PORT = "5008" }
if (-not $env:PHX_HOST) { $env:PHX_HOST = "localhost" }

$data = Join-Path $env:USERPROFILE ".handbeam"
New-Item -ItemType Directory -Force -Path $data | Out-Null
if (-not $env:DATABASE_PATH) { $env:DATABASE_PATH = Join-Path $data "sigil.db" }
if (-not $env:SECRET_KEY_BASE) {
  $bytes = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $env:SECRET_KEY_BASE = [Convert]::ToBase64String($bytes)
}

Write-Host "Handbeam http://localhost:$($env:PORT)"
Write-Host "Stop with Ctrl+C"
& "$PSScriptRoot\bin\handbeam.bat" start
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
