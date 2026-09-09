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
  $skillDirectory = if ($manifest.skillDirectory) { [string]$manifest.skillDirectory } else { Join-Path $HOME ".codex\skills\codex-with-chatgpt" }
  New-Item -ItemType Directory -Force -Path $skillDirectory | Out-Null
  $target = Join-Path $skillDirectory "SKILL.md"
  $temp = Join-Path $skillDirectory ".SKILL.$([guid]::NewGuid().ToString('N')).tmp"
  Copy-Item -LiteralPath $skill -Destination $temp -Force
  Move-Item -LiteralPath $temp -Destination $target -Force
}
$skillDirectory = if ($manifest.skillDirectory) { [string]$manifest.skillDirectory } else { Join-Path $HOME ".codex\skills\codex-with-chatgpt" }
foreach ($directoryName in @("references", "agents")) {
  $backupDirectory = Join-Path $BackupPath $directoryName
  $targetDirectory = Join-Path $skillDirectory $directoryName
  if (Test-Path $backupDirectory) {
    if (Test-Path $targetDirectory) { Remove-Item -LiteralPath $targetDirectory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $skillDirectory | Out-Null
    Copy-Item -LiteralPath $backupDirectory -Destination $targetDirectory -Recurse -Force
  }
}
Write-Host "已恢复上一版：$($manifest.commit)"

