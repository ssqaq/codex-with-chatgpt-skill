[CmdletBinding()]
param(
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [ValidateSet('Markdown', 'Json')]
    [string]$Format = 'Markdown',
    [string]$StateDir,
    [string]$BrowserTabsJson,
    [ValidateSet('', 'confirmed', 'absent', 'empty', 'unknown', 'failed')]
    [string]$OpenTabsStatus = '',
    [ValidateSet('', 'confirmed', 'absent', 'empty', 'unknown', 'failed')]
    [string]$TabsListStatus = ''
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

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Choose([object]$Primary, [object]$Fallback) {
    $first = Text $Primary
    if (-not [string]::IsNullOrWhiteSpace($first)) { return $first }
    return Text $Fallback
}

function Get-SessionId([string]$Url) {
    $text = Text $Url
    if ($text -match '^https://chat\.deepseek\.com/a/chat/s/([A-Za-z0-9][A-Za-z0-9_-]{7,127})(?:[/?#]|$)') {
        return "official-chat:$($Matches[1])"
    }
    return ''
}

function Group-Duplicates([object[]]$Items, [string]$KeyName, [string]$Label) {
    $groups = @(
        $Items |
            Where-Object { -not [string]::IsNullOrWhiteSpace((Prop $_ $KeyName)) } |
            Group-Object -Property { Prop $_ $KeyName } |
            Where-Object Count -gt 1 |
            ForEach-Object {
                [pscustomobject][ordered]@{
                    type  = $Label
                    key   = $_.Name
                    count = $_.Count
                    items = @($_.Group | ForEach-Object {
                        [pscustomobject][ordered]@{
                            threadId  = Prop $_ 'codexThreadId'
                            tabId     = Prop $_ 'browserTabId'
                            runtimeId = Prop $_ 'browserRuntimeId'
                            sessionId = Prop $_ 'deepseekSessionId'
                            url       = Prop $_ 'url'
                        }
                    })
                }
            }
    )
    return $groups
}

$CodexThreadId = Normalize-Thread $CodexThreadId
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
$registry = Read-Json (Join-Path $StateDir 'thread-bindings.json')
$activeBindings = @(
    if ($null -ne $registry) {
        @($registry.bindings) | Where-Object {
            (Prop $_ 'status') -notin @('lost', 'cancelled', 'terminated') -and
            -not [string]::IsNullOrWhiteSpace((Prop $_ 'codexThreadId'))
        } | ForEach-Object {
            [pscustomobject][ordered]@{
                codexThreadId      = Normalize-Thread (Prop $_ 'codexThreadId')
                browserTabId       = Prop $_ 'browserTabId'
                browserRuntimeId   = Prop $_ 'browserRuntimeId'
                deepseekSessionId  = Prop $_ 'deepseekSessionId'
                browserSurface     = Prop $_ 'browserSurface'
                status             = Prop $_ 'status'
            }
        }
    }
)

$observed = @()
if (-not [string]::IsNullOrWhiteSpace($BrowserTabsJson)) {
    try {
        $parsed = $BrowserTabsJson | ConvertFrom-Json
        $sourceItems = if ($parsed -is [array]) { @($parsed) } elseif ($null -ne $parsed.tabs) { @($parsed.tabs) } else { @($parsed) }
        $observed = @(
            $sourceItems | ForEach-Object {
                $url = Prop $_ 'url'
                [pscustomobject][ordered]@{
                    codexThreadId     = Normalize-Thread (Prop $_ 'codexThreadId')
                    browserTabId      = Choose (Prop $_ 'tabId') (Prop $_ 'browserTabId')
                    browserRuntimeId  = Choose (Prop $_ 'runtimeId') (Prop $_ 'browserRuntimeId')
                    deepseekSessionId = Choose (Prop $_ 'sessionId') (Get-SessionId $url)
                    url               = $url
                    browserSurface    = Choose (Prop $_ 'browserSurface') 'codex-in-app-sidebar'
                    model             = Prop $_ 'model'
                    reasoning         = Prop $_ 'reasoning'
                }
            }
        )
    }
    catch {
        throw "BrowserTabsJson 不是有效 JSON：$($_.Exception.Message)"
    }
}

$openStatus = if ([string]::IsNullOrWhiteSpace($OpenTabsStatus)) { 'unknown' } else { $OpenTabsStatus }
$listStatus = if ([string]::IsNullOrWhiteSpace($TabsListStatus)) { 'unknown' } else { $TabsListStatus }

$registryDuplicates = @(
    @(Group-Duplicates $activeBindings 'browserTabId' 'registry-tab') +
    @(Group-Duplicates $activeBindings 'deepseekSessionId' 'registry-session')
)
$observedDuplicates = @(
    @(Group-Duplicates $observed 'browserTabId' 'observed-tab') +
    @(Group-Duplicates $observed 'deepseekSessionId' 'observed-session') +
    @(Group-Duplicates $observed 'url' 'observed-url')
)
$wrongSurface = @(
    $observed | Where-Object {
        (Prop $_ 'browserSurface') -ne 'codex-in-app-sidebar'
    }
)

$result = [pscustomobject][ordered]@{
    status              = 'DUPLICATE_TAB_DIAGNOSTIC_OK'
    currentThread       = $CodexThreadId
    autoClose           = $false
    action              = '只提醒；绑定时拒绝重复 tab；不自动关闭用户窗口'
    registryBindingCount = $activeBindings.Count
    observedTabCount    = $observed.Count
    duplicateCount      = $registryDuplicates.Count + $observedDuplicates.Count
    registryDuplicates  = $registryDuplicates
    observedDuplicates  = $observedDuplicates
    wrongSurfaceCount   = $wrongSurface.Count
    wrongSurfaceTabs    = $wrongSurface
    openTabsStatus      = $openStatus
    tabsListStatus      = $listStatus
    absenceConfirmed    = ($openStatus -eq 'absent' -and $listStatus -eq 'absent')
    replacementAllowed  = ($openStatus -eq 'absent' -and $listStatus -eq 'absent')
}

if ($Format -eq 'Json') {
    $result | ConvertTo-Json -Depth 16
    exit 0
}

$lines = @(
    '| 检查项 | 数量 | 结果 | 处理 |'
    '|--------|------|------|------|'
    "| 注册表绑定 | $($activeBindings.Count) | 已读取 | 不改动 |"
    "| 浏览器标签 | $($observed.Count) | 已读取 | 不自动关闭 |"
    "| 重复项 | $($result.duplicateCount) | $(if ($result.duplicateCount -gt 0) { '发现重复' } else { '未发现' }) | 只提醒并拒绝重复接管 |"
    "| 外部/错误浏览器 | $($wrongSurface.Count) | $(if ($wrongSurface.Count -gt 0) { '发现' } else { '无' }) | 只允许 Codex 右侧栏 |"
    "| user.openTabs | $openStatus | $(if ($openStatus -eq 'absent') { '明确为空' } else { '不能证明丢失' }) | empty/unknown 不触发新建 |"
    "| tabs.list | $listStatus | $(if ($listStatus -eq 'absent') { '明确为空' } else { '不能证明丢失' }) | empty/unknown 不触发新建 |"
)
$lines += ''
if ($result.duplicateCount -gt 0) {
    $lines += '提醒：发现重复 session/tab；不要新建第三个窗口，也不要自动关闭已有窗口。'
}
else {
    $lines += '提醒：当前没有发现可确认的重复 session/tab。'
}
$lines += '安全说明：本诊断只输出 tab/session/运行时摘要，不输出消息正文、Token、密码或密钥。'
$lines -join "`n"
