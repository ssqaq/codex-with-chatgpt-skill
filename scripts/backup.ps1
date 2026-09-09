[CmdletBinding()]
param(
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt"),
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt"),
  [string]$BackupRoot = (Join-Path $HOME ".codex\backups\codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path (Join-Path $Checkout ".git"))) { throw "找不到项目：$Checkout" }
$commit = (git -C $Checkout rev-parse HEAD).Trim()
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = Join-Path $BackupRoot $stamp
New-Item -ItemType Directory -Force -Path $backupPath | Out-Null
@{ checkout = $Checkout; skillDirectory = $SkillDirectory; commit = $commit; createdAt = (Get-Date).ToString("o") } |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backupPath "manifest.json") -Encoding UTF8
if (Test-Path (Join-Path $SkillDirectory "SKILL.md")) {
  Copy-Item -LiteralPath (Join-Path $SkillDirectory "SKILL.md") -Destination (Join-Path $backupPath "SKILL.md")
}
Set-Content -LiteralPath (Join-Path $BackupRoot "latest.txt") -Value $backupPath -Encoding UTF8
Write-Host "备份完成：$backupPath"
