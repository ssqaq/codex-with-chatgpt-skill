[CmdletBinding()]
param(
  [string]$BackupPath,
  [string]$BackupRoot = (Join-Path $HOME ".codex\backups\codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
if (-not $BackupPath) { $BackupPath = (Get-Content -Raw (Join-Path $BackupRoot "latest.txt")).Trim() }
$manifest = Get-Content -Raw (Join-Path $BackupPath "manifest.json") | ConvertFrom-Json
if (-not (Test-Path (Join-Path $manifest.checkout ".git"))) { throw "找不到项目：$($manifest.checkout)" }
git -C $manifest.checkout reset --hard $manifest.commit
$skill = Join-Path $BackupPath "SKILL.md"
if (Test-Path $skill) {
  $skillDirectory = $manifest.skillDirectory
  New-Item -ItemType Directory -Force -Path $skillDirectory | Out-Null
  Copy-Item -LiteralPath $skill -Destination (Join-Path $skillDirectory "SKILL.md") -Force
}
Write-Host "已恢复上一版：$($manifest.commit)"
