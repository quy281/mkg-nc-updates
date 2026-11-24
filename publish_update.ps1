param(
  [string]$Version = '',
  [string]$RbzName = '',
  [string]$StatusFile = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $root

function Write-PublishStatus {
  param([bool]$Ok, [string]$Message)
  if (-not [string]::IsNullOrWhiteSpace($StatusFile)) {
    $obj = @{ ok = $Ok; message = $Message } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($StatusFile, $obj, [System.Text.UTF8Encoding]::new($false))
  }
}

try {
  $manifestPath = Join-Path $root 'manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw 'Khong tim thay manifest.json trong thu muc phat hanh.'
  }

  $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = [string]($manifest.plugin_version)
    if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]($manifest.version) }
  }
  if ([string]::IsNullOrWhiteSpace($RbzName)) {
    $RbzName = [string]($manifest.rbz_filename)
    if ([string]::IsNullOrWhiteSpace($RbzName)) {
      $parts = $Version.Split('.')
      $shortVer = if ($parts.Length -ge 2) { "$($parts[0]).$($parts[1])" } else { $Version }
      $RbzName = "mkg_nc_v$shortVer.rbz"
    }
  }

  $rbzPath = Join-Path $root $RbzName
  $latestRbz = Join-Path $root 'mkg_nc.rbz'
  if (-not (Test-Path -LiteralPath $rbzPath)) { throw "Khong tim thay $RbzName." }
  if (-not (Test-Path -LiteralPath $latestRbz)) { Copy-Item -LiteralPath $rbzPath -Destination $latestRbz -Force }

  $cfgVer = [string]$manifest.config_version

  # 1. Dong bo Cloudflare Pages tu thu muc dist sach
  $distDir = Join-Path $root 'dist'
  if (Test-Path -LiteralPath $distDir) { Remove-Item -LiteralPath $distDir -Recurse -Force }
  New-Item -ItemType Directory -Path $distDir | Out-Null

  Copy-Item -LiteralPath (Join-Path $root 'index.html') -Destination $distDir -Force
  Copy-Item -LiteralPath $manifestPath -Destination $distDir -Force
  Copy-Item -LiteralPath (Join-Path $root 'config_bundle.json') -Destination $distDir -Force
  Copy-Item -LiteralPath $rbzPath -Destination $distDir -Force
  Copy-Item -LiteralPath $latestRbz -Destination $distDir -Force

  $wranglerCmd = Get-Command wrangler -ErrorAction SilentlyContinue
  if ($wranglerCmd) {
    & $wranglerCmd.Source pages deploy dist --project-name mkg-nc-updates --branch main --commit-dirty=true
  } else {
    & npx --yes wrangler pages deploy dist --project-name mkg-nc-updates --branch main --commit-dirty=true
  }
  if ($LASTEXITCODE -ne 0) { throw "Cloudflare Pages deploy that bai (exit $LASTEXITCODE)." }

  # 2. Day len GitHub (manifest + config_bundle + index) & GitHub Release asset (.rbz)
  git add manifest.json config_bundle.json index.html README.md .gitignore publish_update.ps1
  & git diff --cached --quiet
  if ($LASTEXITCODE -ne 0) {
    git commit -m "Release v$Version (config v$cfgVer)"
    if ($LASTEXITCODE -ne 0) { throw "Git commit that bai." }
  }
  git push -u origin main
  if ($LASTEXITCODE -ne 0) { throw "Git push len GitHub that bai." }

  $tag = "v$Version"
  $null = & gh release view $tag 2>&1
  if ($LASTEXITCODE -eq 0) {
    & gh release upload $tag $rbzPath $latestRbz --clobber
  } else {
    & gh release create $tag $rbzPath $latestRbz --title "MKG - NC $tag" --notes "Phien ban v$Version & Cau hinh dong bo v$cfgVer"
  }
  if ($LASTEXITCODE -ne 0) { throw "GitHub Release upload that bai (exit $LASTEXITCODE)." }

  if (Test-Path -LiteralPath $distDir) { Remove-Item -LiteralPath $distDir -Recurse -Force }
  Write-PublishStatus -Ok $true -Message "Da day Online v$Version + Cau hinh v$cfgVer len Cloudflare Pages + GitHub!"
} catch {
  $errMsg = $_.Exception.Message
  Write-PublishStatus -Ok $false -Message "Loi day Online: $errMsg"
  throw
}
