$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$parent = Split-Path -Parent $root
$tarOut = Join-Path $parent "v2raya-policy-kit.tar"
$gzOut = Join-Path $parent "v2raya-policy-kit.tar.gz"

if (Test-Path $tarOut) { Remove-Item $tarOut -Force }
if (Test-Path $gzOut) { Remove-Item $gzOut -Force }

tar -cf $tarOut -C $parent "v2raya-policy-kit"
tar -czf $gzOut -C $parent "v2raya-policy-kit"

Write-Host "Created: $tarOut"
Write-Host "Created: $gzOut"
