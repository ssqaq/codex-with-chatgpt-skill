[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceDir = 'D:\aips小程序\提示词模板',
    [string]$SkillDir
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ([string]::IsNullOrWhiteSpace($SkillDir)) { $SkillDir = Split-Path -Parent $PSScriptRoot }
$sourceRoot = (Resolve-Path -LiteralPath $SourceDir).Path
$skillRoot = (Resolve-Path -LiteralPath $SkillDir).Path
$referencesDir = Join-Path $skillRoot 'references'
New-Item -ItemType Directory -Force -Path $referencesDir | Out-Null
$mapping=@(
    @{Source='通用协作提示词.md';Destination='general-collaboration.md'},
    @{Source='浏览器工具调用协议模板.md';Destination='browser-protocol.md'},
    @{Source='README.md';Destination='usage.md'}
)
$results=foreach($item in $mapping){
    $src=Join-Path $sourceRoot $item.Source
    $dst=Join-Path $referencesDir $item.Destination
    if(-not(Test-Path -LiteralPath $src -PathType Leaf)){throw "源模板不存在：$src"}
    $hash=(Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash
    $old=''
    if(Test-Path -LiteralPath $dst -PathType Leaf){$old=(Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash}
    if($hash -eq $old){[pscustomobject]@{Source=$src;Destination=$dst;Status='unchanged';Hash=$hash};continue}
    if($PSCmdlet.ShouldProcess($dst,"同步 $($item.Source)")){Copy-Item -LiteralPath $src -Destination $dst -Force;[pscustomobject]@{Source=$src;Destination=$dst;Status='updated';Hash=$hash}}
}
$results|ConvertTo-Json -Depth 4