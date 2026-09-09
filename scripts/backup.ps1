[CmdletBinding()]
param(
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt"),
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt"),
  [string]$BackupRoot = (Join-Path $HOME ".codex\backups\codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $Checkout ".git"))) { throw "找不到项目：$Checkout" }
$commit = (git -C $Checkout rev-parse HEAD).Trim()
$dirty = (git -C $Checkout status --porcelain --untracked-files=all).Trim()
if ($dirty) {
  throw "检测到未提交改动，已停止更新以保护你的代码。请先提交改动，或在确认后手动处理。"
}
$stamp = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss-fff"), ([guid]::NewGuid().ToString("N").Substring(0, 8))
$backupPath = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
$manifestPath = Join-Path $backupPath "manifest.json"
$manifestTemp = Join-Path $backupPath ".manifest.$([guid]::NewGuid().ToString('N')).tmp"
@{ checkout = $Checkout; skillDirectory = $SkillDirectory; commit = $commit; createdAt = (Get-Date).ToUniversalTime().ToString("o") } |
  ConvertTo-Json -Compress | Set-Content -LiteralPath $manifestTemp -Encoding UTF8
Move-Item -LiteralPath $manifestTemp -Destination $manifestPath -Force
if (Test-Path (Join-Path $SkillDirectory "SKILL.md")) {
  Copy-Item -LiteralPath (Join-Path $SkillDirectory "SKILL.md") -Destination (Join-Path $backupPath "SKILL.md")
}
foreach ($directoryName in @("references", "agents")) {
  $sourceDirectory = Join-Path $SkillDirectory $directoryName
  if (Test-Path $sourceDirectory) {
    Copy-Item -LiteralPath $sourceDirectory -Destination (Join-Path $backupPath $directoryName) -Recurse -Force
  }
}
$latestPath = Join-Path $BackupRoot "latest.txt"
$latestTemp = Join-Path $BackupRoot ".latest.$([guid]::NewGuid().ToString('N')).tmp"
Set-Content -LiteralPath $latestTemp -Value $backupPath -Encoding UTF8
Move-Item -LiteralPath $latestTemp -Destination $latestPath -Force
Write-Host "备份完成：$backupPath"

