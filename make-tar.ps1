$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$parent = Split-Path -Parent $root
$tarOut = Join-Path $parent "v2raya-policy-kit.tar"
$gzOut = Join-Path $parent "v2raya-policy-kit.tar.gz"

if (Test-Path $tarOut) { Remove-Item $tarOut -Force }
if (Test-Path $gzOut) { Remove-Item $gzOut -Force }

tar --exclude="v2raya-policy-kit/.git" --exclude="v2raya-policy-kit/dist" --exclude="v2raya-policy-kit/optional-v2raya-db" -cf $tarOut -C $parent "v2raya-policy-kit"
tar --exclude="v2raya-policy-kit/.git" --exclude="v2raya-policy-kit/dist" --exclude="v2raya-policy-kit/optional-v2raya-db" -czf $gzOut -C $parent "v2raya-policy-kit"

Write-Host "Created: $tarOut"
Write-Host "Created: $gzOut"
