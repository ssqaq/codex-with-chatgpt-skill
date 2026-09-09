[CmdletBinding()]
param(
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt"),
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
$installer = Join-Path $PSScriptRoot "install.ps1"
& $installer -Checkout $Checkout -SkillDirectory $SkillDirectory
Write-Host "更新完成。"
