[CmdletBinding()]
param(
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt"),
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
$installer = Join-Path $PSScriptRoot "install.ps1"
$backup = Join-Path $PSScriptRoot "backup.ps1"
$rollback = Join-Path $PSScriptRoot "rollback.ps1"
& $backup -Checkout $Checkout -SkillDirectory $SkillDirectory
try {
  & $installer -Checkout $Checkout -SkillDirectory $SkillDirectory
} catch {
  Write-Warning "更新失败，正在恢复上一版..."
  & $rollback
  throw
}
Write-Host "更新完成。"

