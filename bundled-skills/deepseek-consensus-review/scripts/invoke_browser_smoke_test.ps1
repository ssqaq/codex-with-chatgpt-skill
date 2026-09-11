[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [Parameter(Mandatory)]
    [string]$CodexThreadId,
    [Parameter(Mandatory)]
    [string]$BrowserEvidenceJson,
    [switch]$RequireSuccessfulSend
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Text([object]$Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Prop([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return Text $property.Value
}

function Normalize-Thread([string]$Value) {
    $text = Text $Value
    if ($text -match '^codex://threads/([^/?#]+)') { return $Matches[1] }
    return $text
}

function Is-TargetUrl([string]$Value) {
    try {
        $uri = [uri](Text $Value)
        return (
            $uri.Scheme -eq 'https' -and
            $uri.Host -eq 'chat.deepseek.com' -and
            $uri.Port -eq 443
        )
    }
    catch {
        return $false
    }
}

$CodexThreadId = Normalize-Thread $CodexThreadId
try {
    $evidence = $BrowserEvidenceJson | ConvertFrom-Json
}
catch {
    throw '真实浏览器冒烟检查失败：证据不是有效 JSON，已拒绝继续。'
}

$failures = [System.Collections.Generic.List[string]]::new()
if ((Prop $evidence 'surface') -ne 'codex-in-app-sidebar') {
    [void]$failures.Add('浏览器来源不是 Codex 右侧栏内置浏览器')
}
if (-not (Is-TargetUrl (Prop $evidence 'url'))) {
    [void]$failures.Add('页面不是 chat.deepseek.com 官网')
}
if ((Prop $evidence 'model') -notin @('网页当前模型（合并升级版）', '专家模式')) {
    [void]$failures.Add('专家模式未被真实 DOM 证据确认')
}
if ((Prop $evidence 'reasoning') -ne '深度思考') {
    [void]$failures.Add('深度思考未被真实 DOM 证据确认')
}
if ((Prop $evidence 'searchMode') -ne '智能搜索') {
    [void]$failures.Add('智能搜索未被真实 DOM 证据确认')
}
if ([string]::IsNullOrWhiteSpace((Prop $evidence 'sessionId'))) {
    [void]$failures.Add('缺少官网 sessionId')
}
if ([string]::IsNullOrWhiteSpace((Prop $evidence 'tabId'))) {
    [void]$failures.Add('缺少专用 tabId')
}
if ([string]::IsNullOrWhiteSpace((Prop $evidence 'runtimeId'))) {
    [void]$failures.Add('缺少 browser runtimeId')
}
$tabMatchCount = 0
if (-not [int]::TryParse((Prop $evidence 'tabMatchCount'), [ref]$tabMatchCount) -or $tabMatchCount -ne 1) {
    [void]$failures.Add('没有唯一 tab 匹配证据')
}
if ((Prop $evidence 'tool') -ne 'mcp__node_repl.js') {
    [void]$failures.Add('浏览器工具不是受支持的 Codex 右侧栏工具')
}
if ((Prop $evidence 'toolStatus') -notin @('available', 'succeeded')) {
    [void]$failures.Add('浏览器工具没有返回可用状态')
}
if ($RequireSuccessfulSend) {
    if ((Prop $evidence 'inputPresence') -ne 'present' -or (Prop $evidence 'inputEnabled') -ne 'enabled') {
        [void]$failures.Add('发送前输入框证据不完整')
    }
    if ((Prop $evidence 'submissionStatus') -ne 'succeeded') {
        [void]$failures.Add('真实发送提交没有成功回读')
    }
}

if ($failures.Count -gt 0) {
    [pscustomobject][ordered]@{
        status       = 'BROWSER_SMOKE_FAIL_CLOSED'
        taskId       = $TaskId
        codexThreadId = $CodexThreadId
        failures     = @($failures)
        fallback     = '禁止回退到 Chrome、Edge、外部浏览器、官网 API 或手工发送'
        sendExecuted = $false
    } | ConvertTo-Json -Depth 8
    exit 1
}

[pscustomobject][ordered]@{
    status        = 'BROWSER_SMOKE_OK'
    taskId        = $TaskId
    codexThreadId = $CodexThreadId
    targetUrl     = 'https://chat.deepseek.com/'
    model         = '专家模式'
    reasoning     = '深度思考'
    browser       = 'Codex 右侧栏内置浏览器'
    sendExecuted  = [bool]$RequireSuccessfulSend
    nextStep      = if ($RequireSuccessfulSend) { '继续读取 DOM 和回执' } else { '如需发送，仍须走现有 PrepareSend → ConfirmBrowserSend → 回读回执闸门' }
} | ConvertTo-Json -Depth 8
