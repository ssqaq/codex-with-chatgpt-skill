[CmdletBinding()]
param(
  [string]$BackupPath,
  [string]$BackupRoot = (Join-Path $HOME ".codex\backups\codex-with-chatgpt"),
  [switch]$Force
)

$ErrorActionPreference = "Stop"
if (-not $BackupPath) { $BackupPath = (Get-Content -Raw (Join-Path $BackupRoot "latest.txt")).Trim() }
$manifest = Get-Content -Raw (Join-Path $BackupPath "manifest.json") | ConvertFrom-Json
if (-not (Test-Path (Join-Path $manifest.checkout ".git"))) { throw "找不到项目：$($manifest.checkout)" }
if (-not $Force) {
  $dirty = (git -C $manifest.checkout status --porcelain --untracked-files=all).Trim()
  if ($dirty) { throw "工作区有未提交改动，已拒绝回滚以保护你的代码。确认后可加 -Force。" }
}
git -C $manifest.checkout reset --hard $manifest.commit
$skill = Join-Path $BackupPath "SKILL.md"
if (Test-Path $skill) {
  $skillDirectory = $manifest.skillDirectory
  New-Item -ItemType Directory -Force -Path $skillDirectory | Out-Null
  Copy-Item -LiteralPath $skill -Destination (Join-Path $skillDirectory "SKILL.md") -Force
}
Write-Host "已恢复上一版：$($manifest.commit)"

