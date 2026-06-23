$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$parent = Split-Path -Parent $root
$distDir = Join-Path $root "dist"
$gzOut = Join-Path $distDir "v2raya-policy-kit.tar.gz"

if (-not (Test-Path $distDir)) {
  New-Item -ItemType Directory -Path $distDir | Out-Null
}

if (Test-Path $gzOut) { Remove-Item $gzOut -Force }
if (Test-Path (Join-Path $distDir "v2raya-policy-kit.tar")) {
  Remove-Item (Join-Path $distDir "v2raya-policy-kit.tar") -Force
}

tar --exclude="v2raya-policy-kit/.git" --exclude="v2raya-policy-kit/dist" --exclude="v2raya-policy-kit/optional-v2raya-db" -czf $gzOut -C $parent "v2raya-policy-kit"

Write-Host "Created: $gzOut"
