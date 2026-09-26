# Build a self-contained Web UI OTP release and zip it.
# Usage: powershell -File scripts/pack_webui.ps1 windows-amd64
$ErrorActionPreference = "Stop"
$target = $args[0]
if (-not $target) { throw "target name required, e.g. windows-amd64" }

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

mix local.hex --force
mix local.rebar --force
mix deps.get
npm ci
$env:MIX_ENV = "prod"
mix compile
mix assets.deploy
mix release --overwrite

$release = Join-Path $root "_build\prod\rel\handbeam"
Copy-Item (Join-Path $root "scripts\start.bat") (Join-Path $release "start.bat") -Force
Copy-Item (Join-Path $root "scripts\start.ps1") (Join-Path $release "start.ps1") -Force

$archive = Join-Path $root "handbeam-web-$target.zip"
$sum = "$archive.sha256"
if (Test-Path $archive) { Remove-Item $archive -Force }
if (Test-Path $sum) { Remove-Item $sum -Force }
tar -a -c -f $archive -C $release .
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $archive -Leaf)" | Set-Content -Encoding ascii $sum
