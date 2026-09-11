[CmdletBinding()]
param(
    [string]$TaskId,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [ValidateSet('Markdown', 'Json', 'Both')]
    [string]$Format = 'Both',
    [string]$StateDir,
    [string]$OutputDirectory,
    [string]$VersionPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Text([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Trim()
}

function Normalize-Thread([string]$Value) {
    $text = Text $Value
    if ($text -match '^codex://threads/([^/?#]+)') {
        return $Matches[1]
    }
    return $text
}

function Safe-Name([string]$Value) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return 'unknown'
    }
    return [regex]::Replace($text, '[^A-Za-z0-9._-]', '_')
}

function Prop([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return ''
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return ''
    }
    return Text $property.Value
}

function Truthy([object]$Value) {
    return (Text $Value) -in @('True', 'true', '1', 'yes')
}

function Safe-Text([object]$Value, [int]$Limit = 240) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    $text = $text -replace '(?i)(password|passwd|secret|token|cookie|api[_-]?key|access[_-]?key)\s*[:=]\s*[^;\s,]+', '$1=<redacted>'
    $text = $text -replace '(?i)\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+\b', '<redacted>'
    if ($text.Length -gt $Limit) {
        return $text.Substring(0, $Limit) + '…'
    }
    return $text
}

function Read-JsonSafe([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            exists = $false
            value = $null
            errorType = ''
        }
    }
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [pscustomobject]@{
                exists = $true
                value = $null
                errorType = 'EmptyFile'
            }
        }
        return [pscustomobject]@{
            exists = $true
            value = ($raw | ConvertFrom-Json)
            errorType = ''
        }
    }
    catch {
        return [pscustomobject]@{
            exists = $true
            value = $null
            errorType = $_.Exception.GetType().Name
        }
    }
}

function Parse-Instant([object]$Value) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Elapsed-Text([object]$From, [object]$To) {
    $start = Parse-Instant $From
    $end = Parse-Instant $To
    if ($null -eq $start -or $null -eq $end -or $end -lt $start) {
        return '无'
    }
    $milliseconds = [math]::Round(($end - $start).TotalMilliseconds)
    if ($milliseconds -lt 1000) {
        return "${milliseconds}ms"
    }
    return "$([math]::Round($milliseconds / 1000, 2))s"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText(
        $Path,
        $Content.TrimEnd() + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Markdown-Value([object]$Value) {
    $text = Safe-Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '无'
    }
    return $text -replace '\|', '｜' -replace "`r?`n", '；'
}

$CodexThreadId = Normalize-Thread $CodexThreadId
if ([string]::IsNullOrWhiteSpace($CodexThreadId)) {
    throw '缺少 CodexThreadId，诊断报告不能猜测 thread。'
}
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $StateDir 'diagnostics'
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

$errors = [System.Collections.Generic.List[string]]::new()
$registryRead = Read-JsonSafe (Join-Path $StateDir 'thread-bindings.json')
$registry = $registryRead.value
if ($registryRead.errorType) {
    [void]$errors.Add("绑定注册表读取失败：$($registryRead.errorType)")
}

$bindingCandidates = @()
if ($null -ne $registry) {
    $bindingCandidates = @(
        @($registry.bindings) | Where-Object {
            (Prop $_ 'codexThreadId') -eq $CodexThreadId
        }
    )
}
$binding = if ($bindingCandidates.Count -eq 1) { $bindingCandidates[0] } else { $null }
$bindingConflict = $bindingCandidates.Count -gt 1
if ($bindingConflict) {
    [void]$errors.Add('同一 Codex thread 存在多个绑定，报告不猜测使用哪一个。')
}

if ([string]::IsNullOrWhiteSpace($TaskId) -and $null -ne $binding) {
    $TaskId = Prop $binding 'activeTaskId'
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        $TaskId = Prop $binding 'taskId'
    }
}
$TaskId = Text $TaskId
$state = $null
$stateRead = $null
if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        [void]$errors.Add('TaskId 格式不受支持。')
        $TaskId = ''
    }
    else {
        $stateRead = Read-JsonSafe (Join-Path $StateDir "$TaskId.json")
        $state = $stateRead.value
        if (-not $stateRead.exists) {
            [void]$errors.Add('找不到当前任务状态文件。')
        }
        elseif ($stateRead.errorType) {
            [void]$errors.Add("任务状态读取失败：$($stateRead.errorType)")
        }
        elseif ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
            [void]$errors.Add('任务状态不属于当前 Codex thread。')
            $state = $null
        }
    }
}
else {
    [void]$errors.Add('当前 thread 没有可报告的 TaskId。')
}

$leaseRead = Read-JsonSafe (Join-Path $StateDir 'browser-lease.json')
$lease = $leaseRead.value
if ($leaseRead.errorType) {
    [void]$errors.Add("浏览器 lease 读取失败：$($leaseRead.errorType)")
}

$versionValue = 'installed-unknown'
if ([string]::IsNullOrWhiteSpace($VersionPath)) {
    $candidate = Join-Path $PSScriptRoot '..\..\..\VERSION'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $VersionPath = $candidate
    }
}
if (-not [string]::IsNullOrWhiteSpace($VersionPath) -and (Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
    $versionValue = (Get-Content -LiteralPath $VersionPath -Raw -Encoding UTF8).Trim()
}
elseif (-not [string]::IsNullOrWhiteSpace($env:DEEPSEEK_SKILL_VERSION)) {
    $versionValue = Safe-Text $env:DEEPSEEK_SKILL_VERSION
}

$latestTest = $null
$repoRoot = ''
if (-not [string]::IsNullOrWhiteSpace($VersionPath) -and (Test-Path -LiteralPath $VersionPath -PathType Leaf)) {
    $repoRoot = Split-Path -Parent (Resolve-Path -LiteralPath $VersionPath).Path
    $reportRoot = Join-Path $repoRoot 'dist'
    if (Test-Path -LiteralPath $reportRoot -PathType Container) {
        $reportDir = Get-ChildItem -LiteralPath $reportRoot -Directory -Filter 'test-report-*' |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -ne $reportDir) {
            $summaryPath = Join-Path $reportDir.FullName 'summary.json'
            $summaryRead = Read-JsonSafe $summaryPath
            if ($null -ne $summaryRead.value) {
                $latestTest = [ordered]@{
                    directory = $reportDir.Name
                    total = Prop $summaryRead.value 'total'
                    passed = Prop $summaryRead.value 'passed'
                    failed = Prop $summaryRead.value 'failed'
                    finishedAt = Prop $summaryRead.value 'finishedAt'
                }
            }
        }
    }
}

$activationElapsedMs = if ($null -eq $state) { '' } else { Prop $state 'activationElapsedMs' }
$activationAlert = if ($null -eq $state) { '' } else { Prop $state 'activationSlowPathAlert' }
$activationThreshold = if ($null -eq $state) { '2000' } else { Prop $state 'activationSlowPathThresholdMs' }
$activationReason = if ($null -eq $state) { '' } else { Prop $state 'activationSlowPathReason' }
$report = [ordered]@{
    status = 'DIAGNOSTIC_REPORT_OK'
    generatedAt = (Get-Date).ToString('o')
    skill = if ($null -eq $state) { '' } else { Prop $state 'skillName' }
    version = $versionValue
    versionPath = Safe-Text $VersionPath
    codexThreadId = $CodexThreadId
    taskId = $TaskId
    stateDir = $StateDir
    state = [ordered]@{
        activationStatus = if ($null -eq $state) { '' } else { Prop $state 'activationStatus' }
        taskTerminalStatus = if ($null -eq $state) { '' } else { Prop $state 'taskTerminalStatus' }
        sessionBindingStatus = if ($null -eq $state) { '' } else { Prop $state 'sessionBindingStatus' }
        nextAction = if ($null -eq $state) { '' } else { Prop $state 'nextAction' }
        sendStatus = if ($null -eq $state) { '' } else { Prop $state 'sendStatus' }
        deepseekStatus = if ($null -eq $state) { '' } else { Prop $state 'deepseekStatus' }
        lastReceiptStatus = if ($null -eq $state) { '' } else { Prop $state 'lastReceiptStatus' }
        pendingReceipt = if ($null -eq $state) { '' } else { Prop $state 'pendingReceipt' }
        auditRisk = if ($null -eq $state) { '' } else { Prop $state 'auditRisk' }
        resendBlocked = if ($null -eq $state) { '' } else { Prop $state 'resendBlocked' }
    }
    browser = [ordered]@{
        targetUrl = if ($null -eq $state) { 'https://chat.deepseek.com/' } else { Prop $state 'targetUrl' }
        model = if ($null -eq $state) { '专家模式' } else { Prop $state 'model' }
        reasoning = if ($null -eq $state) { '深度思考' } else { Prop $state 'reasoning' }
        surface = if ($null -eq $state) { 'codex-in-app-sidebar' } else { Prop $state 'browserSurface' }
        sessionId = if ($null -eq $state) { '' } else { Prop $state 'deepseekSessionId' }
        conversationUrl = if ($null -eq $state) { '' } else { Prop $state 'conversationUrl' }
        tabId = if ($null -eq $state) { '' } else { Prop $state 'browserTabId' }
        runtimeId = if ($null -eq $state) { '' } else { Prop $state 'browserRuntimeId' }
        runtimeEpoch = if ($null -eq $state) { '' } else { Prop $state 'runtimeEpoch' }
        bindingConfidence = if ($null -eq $state) { '' } else { Prop $state 'bindingConfidence' }
        bindingConflict = $bindingConflict
    }
    activation = [ordered]@{
        requestedAt = if ($null -eq $state) { '' } else { Prop $state 'requestedAt' }
        activatedAt = if ($null -eq $state) { '' } else { Prop $state 'activatedAt' }
        elapsedMs = $activationElapsedMs
        slowPathAlert = $activationAlert
        thresholdMs = $activationThreshold
        reason = $activationReason
    }
    send = [ordered]@{
        phase = if ($null -eq $binding) { '' } else { Prop $binding 'sendPhase' }
        confirmationStatus = if ($null -eq $state) { '' } else { Prop $state 'browserConfirmationStatus' }
        sendOwnerTaskId = if ($null -eq $state) { '' } else { Prop $state 'sendOwnerTaskId' }
        retryCount = if ($null -eq $state) { '' } else { Prop $state 'sendRetryCount' }
        maxRetries = if ($null -eq $state) { '' } else { Prop $state 'maxSendRetries' }
        deadlineAt = if ($null -eq $state) { '' } else { Prop $state 'sendDeadlineAt' }
        domMessagePresence = if ($null -eq $state) { '' } else { Prop $state 'domMessagePresence' }
        timing = [ordered]@{
            requestToActivation = if ($null -eq $state) { '无' } else { Elapsed-Text (Prop $state 'requestedAt') (Prop $state 'activatedAt') }
            messageToBrowserVerify = if ($null -eq $state) { '无' } else { Elapsed-Text (Prop $state 'messageReadyAt') (Prop $state 'browserVerifiedAt') }
            confirmationToAction = if ($null -eq $state) { '无' } else { Elapsed-Text (Prop $state 'browserConfirmationAt') (Prop $state 'browserActionAt') }
            actionToReceipt = if ($null -eq $state) { '无' } else { Elapsed-Text (Prop $state 'browserActionAt') (Prop $state 'receiptAt') }
        }
    }
    lease = [ordered]@{
        present = $null -ne $lease
        ownerThreadId = if ($null -eq $lease) { '' } else { Prop $lease 'codexThreadId' }
        taskId = if ($null -eq $lease) { '' } else { Prop $lease 'taskId' }
        browserTabId = if ($null -eq $lease) { '' } else { Prop $lease 'browserTabId' }
        runtimeId = if ($null -eq $lease) { '' } else { Prop $lease 'browserRuntimeId' }
        leaseEpoch = if ($null -eq $lease) { '' } else { Prop $lease 'leaseEpoch' }
        expiresAt = if ($null -eq $lease) { '' } else { Prop $lease 'expiresAt' }
    }
    errors = @(
        $errors | ForEach-Object { Safe-Text $_ }
        if ($null -ne $state) {
            foreach ($field in @('browserToolFailureReason', 'sessionLost', 'bindingConflict', 'auditRiskReason', 'taskTerminationReason')) {
                $value = Prop $state $field
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    Safe-Text $value
                }
            }
        }
    ) | Select-Object -Unique
    latestTest = $latestTest
    safety = [ordered]@{
        messageBodyIncluded = $false
        messageFingerprintIncluded = $false
        authorizationContentIncluded = $false
        leaseTokenIncluded = $false
        secretsIncluded = $false
    }
}

$safeKey = if ([string]::IsNullOrWhiteSpace($TaskId)) {
    "thread-$($CodexThreadId)"
}
else {
    "task-$TaskId"
}
$jsonPath = Join-Path $OutputDirectory "diagnostic-$(Safe-Name $safeKey).json"
$markdownPath = Join-Path $OutputDirectory "diagnostic-$(Safe-Name $safeKey).md"
$report.files = [ordered]@{
    json = if ($Format -in @('Json', 'Both')) { $jsonPath } else { '' }
    markdown = if ($Format -in @('Markdown', 'Both')) { $markdownPath } else { '' }
}
$jsonText = $report | ConvertTo-Json -Depth 20
$markdownLines = @(
    '# DeepSeek Skill 诊断报告'
    ''
    "| 项目 | 值 |"
    "|------|----|"
    "| 生成时间 | $(Markdown-Value $report.generatedAt) |"
    "| Skill | $(Markdown-Value $report.skill) |"
    "| 版本 | $(Markdown-Value $report.version) |"
    "| Codex thread | $(Markdown-Value $report.codexThreadId) |"
    "| Task | $(Markdown-Value $report.taskId) |"
    "| 激活状态 | $(Markdown-Value $report.state.activationStatus) |"
    "| 终态 | $(Markdown-Value $report.state.taskTerminalStatus) |"
    "| DeepSeek 会话 | $(Markdown-Value $report.browser.sessionId) |"
    "| 右侧栏 tab | $(Markdown-Value $report.browser.tabId) |"
    "| runtime | $(Markdown-Value $report.browser.runtimeId) |"
    "| 目标模式 | $(Markdown-Value $report.browser.model) / $(Markdown-Value $report.browser.reasoning) |"
    "| 激活耗时 | $(Markdown-Value $report.activation.elapsedMs) ms |"
    "| 慢路径告警 | $(Markdown-Value $report.activation.slowPathAlert) |"
    "| 当前发送阶段 | $(Markdown-Value $report.send.phase) |"
    "| 发送状态 | $(Markdown-Value $report.state.sendStatus) |"
    "| 回执 | $(Markdown-Value $report.state.lastReceiptStatus) |"
    "| lease | $(Markdown-Value $report.lease.present) |"
    "| 最近错误 | $(Markdown-Value (($report.errors -join '；'))) |"
    ''
    '安全检查：不包含消息正文、消息指纹、授权内容、lease Token、密码、Token 或密钥。'
)
$markdownText = $markdownLines -join "`r`n"
if ($Format -in @('Json', 'Both')) {
    Write-Utf8NoBom $jsonPath $jsonText
}
if ($Format -in @('Markdown', 'Both')) {
    Write-Utf8NoBom $markdownPath $markdownText
}

$report | ConvertTo-Json -Depth 20
exit 0
