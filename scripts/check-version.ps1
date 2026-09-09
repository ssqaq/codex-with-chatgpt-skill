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
$needsUpdate = [version]$CurrentVersion -lt [version]$latest
Write-Host "本机版本：$CurrentVersion"
Write-Host "GitHub 最新版本：$latest"
Write-Host ("是否需要更新：" + $(if ($needsUpdate) { "是" } else { "否" }))
if ($needsUpdate) {
  exit 10
}
