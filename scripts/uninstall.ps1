[CmdletBinding()]
param(
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt"),
  [switch]$RemoveCheckout,
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt")
)

$ErrorActionPreference = "Stop"
if (Test-Path $SkillDirectory) {
  [IO.Directory]::Delete((Resolve-Path $SkillDirectory).Path, $true)
  Write-Host "已移除 Skill：$SkillDirectory"
} else {
  Write-Host "Skill 已不存在：$SkillDirectory"
}
if ($RemoveCheckout -and (Test-Path $Checkout)) {
  [IO.Directory]::Delete((Resolve-Path $Checkout).Path, $true)
  Write-Host "已移除项目目录：$Checkout"
}
Write-Host "卸载完成。默认保留项目目录；如需一起移除，请加 -RemoveCheckout。"
