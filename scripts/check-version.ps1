[CmdletBinding()]
param(
  [string]$CurrentVersion,
  [string]$Repository = "ssqaq/codex-with-chatgpt-skill"
)

$ErrorActionPreference = "Stop"
if (-not $CurrentVersion) {
  $versionFile = Join-Path $PSScriptRoot "..\VERSION"
  $CurrentVersion = (Get-Content -Raw $versionFile).Trim()
}
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers @{ "User-Agent" = "codex-with-chatgpt-skill" }
$latest = ($release.tag_name -replace '^v', '').Trim()
if ([version]$CurrentVersion -lt [version]$latest) {
  Write-Host "有新版本：$CurrentVersion -> $latest"
  exit 10
}
Write-Host "已是最新版本：$CurrentVersion"
