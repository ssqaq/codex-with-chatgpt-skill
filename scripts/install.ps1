[CmdletBinding()]
param(
  [string]$Checkout = (Join-Path $HOME "codex-with-chatgpt"),
  [string]$SkillDirectory = (Join-Path $HOME ".codex\skills\codex-with-chatgpt"),
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"
$repoUrl = "https://github.com/ssqaq/codex-with-chatgpt-skill.git"

function Has-Command([string]$Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Install-Winget([string]$Id, [string]$Label) {
  Write-Host "正在安装 $Label..."
  winget install --id $Id --exact --source winget --accept-source-agreements --accept-package-agreements
}

if (-not (Has-Command "winget")) { throw "找不到 winget，请先安装 App Installer。" }
if (-not (Has-Command "git")) { Install-Winget "Git.Git" "Git" }
if (-not (Has-Command "node")) { Install-Winget "OpenJS.NodeJS.LTS" "Node.js" }
if (-not (Has-Command "cloudflared")) { Install-Winget "Cloudflare.cloudflared" "cloudflared" }

if (-not (Has-Command "git") -or -not (Has-Command "node") -or -not (Has-Command "cloudflared")) {
  throw "安装完成但当前窗口还没有刷新 PATH，请关闭后重新打开 PowerShell 再运行此脚本。"
}

$nodeMajor = [int]((node --version).Trim().TrimStart("v").Split(".")[0])
if ($nodeMajor -lt 20) { throw "Node.js 版本低于 20，请升级后重试。" }

if (Test-Path (Join-Path $Checkout ".git")) {
  Write-Host "更新已有项目：$Checkout"
  git -C $Checkout pull --ff-only
} else {
  Write-Host "下载项目：$Checkout"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Checkout) | Out-Null
  git clone $repoUrl $Checkout
}

$projectRoot = if (Test-Path (Join-Path $Checkout "core\package.json")) {
  Join-Path $Checkout "core"
} else {
  $Checkout
}

if (-not $SkipBuild) {
  Push-Location $projectRoot
  try {
    corepack enable
    corepack pnpm install
    corepack pnpm build
  } finally {
    Pop-Location
  }
}

New-Item -ItemType Directory -Force -Path $SkillDirectory | Out-Null
$sourceSkill = Join-Path $Checkout "SKILL.md"
if (-not (Test-Path $sourceSkill)) {
  $sourceSkill = Join-Path $projectRoot "skill\SKILL.md"
}
$targetSkill = Join-Path $SkillDirectory "SKILL.md"
if (-not (Test-Path $sourceSkill)) { throw "找不到 Skill 文件：$sourceSkill" }
Copy-Item -LiteralPath $sourceSkill -Destination $targetSkill -Force
$content = Get-Content -Raw -LiteralPath $targetSkill
$replacement = '- The codex-with-chatgpt checkout lives at: `' + $Checkout + '`'
$pattern = '(?m)^- The codex-with-chatgpt checkout lives at:.*$'
if (-not [regex]::IsMatch($content, $pattern)) { throw "Skill 中找不到工作区路径行。" }
$content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement })
Set-Content -LiteralPath $targetSkill -Value $content -Encoding UTF8

Write-Host "安装完成。"
Write-Host "项目目录：$Checkout"
Write-Host "Skill 文件：$targetSkill"
Write-Host "连接器名称规则：Codex with ChatGPT · <项目名>"

