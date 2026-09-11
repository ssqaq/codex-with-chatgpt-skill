[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [ValidateSet('Markdown', 'Json')]
    [string]$Format = 'Markdown',
    [string]$StateDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
$CodexThreadId = if ($CodexThreadId -match '^codex://threads/([^/?#]+)') {
    $Matches[1]
}
else {
    ([string]$CodexThreadId).Trim()
}
if ([string]::IsNullOrWhiteSpace($CodexThreadId)) {
    throw '缺少 CodexThreadId，禁止显示无归属任务。'
}

function Text([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Trim()
}

function DisplayDateTime([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return ''
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )) {
        return $parsed.ToUniversalTime().ToString('o')
    }
    return $text
}

function ParseInstant([object]$Value) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function ElapsedText([object]$From, [object]$To) {
    $start = ParseInstant $From
    $end = ParseInstant $To
    if ($null -eq $start -or $null -eq $end -or $end -lt $start) {
        return '无'
    }
    $milliseconds = [math]::Round(($end - $start).TotalMilliseconds)
    if ($milliseconds -lt 1000) {
        return "${milliseconds}ms"
    }
    return "$([math]::Round($milliseconds / 1000, 2))s"
}

function Truthy([object]$Value) {
    return (Text $Value) -in @('True', 'true', '1', 'yes')
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

function ReadJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    try {
        $convertParams = @{}
        if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
            $convertParams.DateKind = 'String'
        }
        return $raw | ConvertFrom-Json @convertParams
    }
    catch {
        throw "JSON 损坏：$Path。$($_.Exception.Message)"
    }
}

function SafeMarkdown([string]$Value) {
    $safe = Text $Value
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return '无'
    }
    return ($safe -replace '\|', '｜' -replace "`r?`n", '；')
}

function Row(
    [int]$Index,
    [string]$Item,
    [string]$Description,
    [string]$Status,
    [string]$Progress,
    [string]$Next
) {
    [pscustomobject]@{
        index = $Index
        item = $Item
        description = $Description
        status = $Status
        progress = $Progress
        next = $Next
    }
}

$statePath = Join-Path $StateDir "$TaskId.json"
$state = ReadJson $statePath
if ($null -eq $state) {
    throw "找不到任务状态：$statePath"
}
if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
    throw '任务状态归属冲突，禁止显示其他 Codex thread。'
}

$binding = $null
$bindingCandidates = @()
$bindingConflict = ''
$registry = ReadJson (Join-Path $StateDir 'thread-bindings.json')
if ($null -ne $registry) {
    $bindingCandidates = @(
        $registry.bindings |
            Where-Object { (Prop $_ 'codexThreadId') -eq $CodexThreadId }
    )
    if ($bindingCandidates.Count -eq 1) {
        $binding = $bindingCandidates[0]
    }
    elseif ($bindingCandidates.Count -gt 1) {
        $bindingConflict = '同一 Codex thread 存在多条绑定，执行和恢复都禁止猜测。'
    }
}

$batch = Prop $state 'reviewBatch'
$completed = Prop $state 'deepseekCompletedRounds'
$issues = Prop $state 'unresolvedIssues'
$repeat = Prop $state 'repeatedDisagreementRounds'
if ([string]::IsNullOrWhiteSpace($repeat)) { $repeat = '0' }
$threshold = Prop $state 'deadlockThreshold'
if ([string]::IsNullOrWhiteSpace($threshold)) { $threshold = '2' }
$deadlock = Truthy (Prop $state 'decisionDeadlock')
$bindingStatus = if (-not [string]::IsNullOrWhiteSpace($bindingConflict)) {
    'conflict'
}
elseif ($null -eq $binding) {
    Prop $state 'sessionBindingStatus'
}
else {
    Prop $binding 'status'
}
$receipt = if ($null -eq $binding) { Prop $state 'lastReceiptStatus' } else { Prop $binding 'lastReceiptStatus' }
$sendRetryCount = if ($null -eq $binding) { Prop $state 'sendRetryCount' } else { Prop $binding 'sendRetryCount' }
$maxSendRetries = if ($null -eq $binding) { Prop $state 'maxSendRetries' } else { Prop $binding 'maxSendRetries' }
$sendDeadlineAt = if ($null -eq $binding) { Prop $state 'sendDeadlineAt' } else { Prop $binding 'sendDeadlineAt' }
$sendDeadlineAt = DisplayDateTime $sendDeadlineAt
$domMessagePresence = if ($null -eq $binding) { Prop $state 'domMessagePresence' } else { Prop $binding 'domMessagePresence' }
$browserConfirmationStatus = if ($null -eq $binding) { Prop $state 'browserConfirmationStatus' } else { Prop $binding 'browserConfirmationStatus' }
$retryExhausted = if ($null -eq $binding) { Prop $state 'retryExhausted' } else { Prop $binding 'retryExhausted' }
if ([string]::IsNullOrWhiteSpace($sendRetryCount)) { $sendRetryCount = '0' }
if ([string]::IsNullOrWhiteSpace($maxSendRetries)) { $maxSendRetries = '2' }
if ([string]::IsNullOrWhiteSpace($sendDeadlineAt)) { $sendDeadlineAt = '无' }
if ([string]::IsNullOrWhiteSpace($domMessagePresence)) { $domMessagePresence = '无' }
if ([string]::IsNullOrWhiteSpace($retryExhausted)) { $retryExhausted = 'false' }
$consensus = Prop $state 'consensusStatus'
$nextAction = Prop $state 'nextAction'
if ([string]::IsNullOrWhiteSpace($nextAction)) {
    $nextAction = if ($deadlock) { 'await-user-decision' } else { 'record-next-round' }
}
$taskTerminalStatus = Prop $state 'taskTerminalStatus'
$messageReadyAt = if ($null -eq $binding) { Prop $state 'messageReadyAt' } else { Prop $binding 'messageReadyAt' }
$browserVerifiedAt = if ($null -eq $binding) { Prop $state 'browserVerifiedAt' } else { Prop $binding 'browserVerifiedAt' }
if (
    -not $deadlock -and
    $taskTerminalStatus -eq 'active' -and
    $bindingStatus -ne 'bound' -and
    $nextAction -in @('', 'record-next-round')
) {
    # 旧状态或旧面板不能把“没有浏览器绑定”伪装成“记录下一轮”。
    # 面板必须给出当前真正可执行的下一步，避免只汇报、不推进。
    $nextAction = 'prepare-browser-binding'
}
elseif (
    -not $deadlock -and
    $taskTerminalStatus -eq 'active' -and
    $bindingStatus -eq 'bound' -and
    $nextAction -eq 'record-next-round' -and
    [string]::IsNullOrWhiteSpace($messageReadyAt) -and
    [string]::IsNullOrWhiteSpace($browserVerifiedAt)
) {
    $nextAction = 'prepare-review-message'
}
$progress = Prop $state 'roundProgressPercent'
if ([string]::IsNullOrWhiteSpace($progress)) { $progress = '0' }
$requestedAt = Prop $state 'requestedAt'
$activatedAt = Prop $state 'activatedAt'
if ([string]::IsNullOrWhiteSpace($activatedAt)) { $activatedAt = Prop $state 'activationAt' }
$activationElapsedMs = Prop $state 'activationElapsedMs'
$activationSlowPathAlert = Prop $state 'activationSlowPathAlert'
$activationSlowPathThresholdMs = Prop $state 'activationSlowPathThresholdMs'
$activationSlowPathReason = Prop $state 'activationSlowPathReason'
$stateRevision = Prop $state 'stateRevision'
$lastActionAt = Prop $state 'lastActionAt'
$noOpReportCount = Prop $state 'noOpReportCount'
$stateBlockedReason = Prop $state 'blockedReason'
$requiredAction = Prop $state 'requiredAction'
$requiredEvidence = Prop $state 'requiredEvidence'
$actionContractStatus = Prop $state 'actionContractStatus'
$actionContractDeadlineAt = DisplayDateTime (Prop $state 'actionContractDeadlineAt')
$requiredDeadlineSeconds = Prop $state 'requiredDeadlineSeconds'
$onTimeout = Prop $state 'onTimeout'
if ([string]::IsNullOrWhiteSpace($activationElapsedMs)) { $activationElapsedMs = '无' }
if ([string]::IsNullOrWhiteSpace($activationSlowPathAlert)) { $activationSlowPathAlert = 'false' }
if ([string]::IsNullOrWhiteSpace($activationSlowPathThresholdMs)) { $activationSlowPathThresholdMs = '2000' }
$stateRevision = if ([string]::IsNullOrWhiteSpace($stateRevision)) { '0' } else { $stateRevision }
$noOpReportCount = if ([string]::IsNullOrWhiteSpace($noOpReportCount)) { '0' } else { $noOpReportCount }
$confirmationRequestedAt = if ($null -eq $binding) { Prop $state 'confirmationRequestedAt' } else { Prop $binding 'confirmationRequestedAt' }
$browserActionAt = if ($null -eq $binding) { Prop $state 'browserActionAt' } else { Prop $binding 'browserActionAt' }
$receiptAt = if ($null -eq $binding) { Prop $state 'receiptAt' } else { Prop $binding 'receiptAt' }
$confirmationAt = if ($null -eq $binding) { Prop $state 'browserConfirmationAt' } else { Prop $binding 'browserConfirmationAt' }
$timingSummary = @(
    "请求→激活=$(ElapsedText $requestedAt $activatedAt)；激活耗时=${activationElapsedMs}ms；慢路径=$activationSlowPathAlert/$activationSlowPathThresholdMs",
    "消息→页面=$(ElapsedText $messageReadyAt $browserVerifiedAt)",
    "页面→确认请求=$(ElapsedText $browserVerifiedAt $confirmationRequestedAt)",
    "确认→动作=$(ElapsedText $confirmationAt $browserActionAt)",
    "动作→回执=$(ElapsedText $browserActionAt $receiptAt)"
) -join '；'

$rows = @(
    Row 1 '当前轮次' "$batch，已完成 $completed 轮" `
        $(if ([int]$completed -gt 0) { '✅ 已完成' } else { '⏳ 待处理' }) `
        $(if ([int]$completed -gt 0) { '100%' } else { '0%' }) `
        $(if ($deadlock) { '等待用户裁决' } else { '按分歧进入下一轮' })
    Row 2 '未解决分歧' $(if ([string]::IsNullOrWhiteSpace($issues)) { '当前没有记录实质分歧' } else { $issues }) `
        $(if ([string]::IsNullOrWhiteSpace($issues)) { '✅ 已完成' } else { '🔄 正在做' }) `
        $(if ([string]::IsNullOrWhiteSpace($issues)) { '100%' } else { '50%' }) `
        $(if ([string]::IsNullOrWhiteSpace($issues)) { '确认是否达成共识' } else { '继续补证据或反驳' })
    Row 3 '僵局检查' "相同分歧连续 $repeat/$threshold 轮" `
        $(if ($deadlock) { '⏳ 待处理' } else { '✅ 已完成' }) `
        $(if ($deadlock) { '100%' } else { "$([Math]::Min(100, ([int]$repeat * 50)))%" }) `
        $(if ($deadlock) { '必须由用户裁决或提供新证据' } else { '继续监测下一轮' })
    Row 4 '会话和发送' "绑定=$bindingStatus；回执=$receipt；平台确认=$browserConfirmationStatus；发送=$(Prop $state 'sendStatus')；重试=$sendRetryCount/$maxSendRetries；截止=$sendDeadlineAt；DOM=$domMessagePresence；耗尽=$retryExhausted；慢路径原因=$activationSlowPathReason；$timingSummary" `
        $(if ($bindingStatus -eq 'bound' -and $receipt -eq 'confirmed') { '✅ 已完成' } elseif ($bindingStatus -eq 'bound') { '🔄 正在做' } else { '⏳ 待处理' }) `
        $(if ($bindingStatus -eq 'bound' -and $receipt -eq 'confirmed') { '100%' } elseif ($bindingStatus -eq 'bound') { '60%' } else { '0%' }) `
        $(if ($bindingStatus -eq 'bound') { '核对回执或继续评审' } else { '恢复或重新绑定专用官网会话' })
    Row 5 '共识执行门槛' "共识=$consensus；总结=$(Prop $state 'codexSummaryStatus')；检查=$(Prop $state 'checkResult')；方案=$(Prop $state 'planStatus')" `
        $(if ((Prop $state 'executionStatus') -match '允许') { '✅ 已完成' } elseif ($deadlock) { '⏳ 待处理' } else { '🔄 正在做' }) `
        "$progress%" `
        $(if ($deadlock) { '保持禁止修改' } elseif ($consensus -eq '已达成') { '完成 Codex 总结和最终检查' } else { '继续消除分歧' })
    Row 6 '下一步' "$nextAction；动作合同=$requiredAction；证据=$requiredEvidence；合同状态=$actionContractStatus；限时=${requiredDeadlineSeconds}s；截止=$actionContractDeadlineAt；超时=$onTimeout" `
        $(if ((Prop $state 'executionStatus') -match '允许') { '✅ 已完成' } elseif ($deadlock) { '⏳ 待处理' } else { '🔄 正在做' }) `
        "$progress%" `
        $(if ($deadlock) { '等待用户选择方案' } else { $nextAction })
)

$blockedReason = ''
if ($deadlock) {
    $blockedReason = Prop $state 'decisionDeadlockReason'
}
elseif (-not [string]::IsNullOrWhiteSpace($bindingConflict)) {
    $blockedReason = $bindingConflict
}
elseif ($bindingStatus -ne 'bound') {
    $blockedReason = if (-not [string]::IsNullOrWhiteSpace($stateBlockedReason)) {
        $stateBlockedReason
    }
    else {
        '当前 thread 没有可用的 bound DeepSeek 官网会话。'
    }
}

$result = [pscustomobject]@{
    status = 'REVIEW_DASHBOARD_OK'
    taskId = $TaskId
    codexThreadId = $CodexThreadId
    reviewBatch = $batch
    completedRounds = $completed
    decisionDeadlock = $deadlock
    blockedReason = $blockedReason
    bindingConflict = $bindingConflict
    bindingCount = $bindingCandidates.Count
    totalProgress = [int]$progress
    nextAction = $nextAction
    stateRevision = [int]$stateRevision
    lastActionAt = $lastActionAt
    noOpReportCount = [int]$noOpReportCount
    actionContract = [pscustomobject][ordered]@{
        requiredAction = $requiredAction
        requiredEvidence = $requiredEvidence
        status = $actionContractStatus
        deadlineSeconds = if ([string]::IsNullOrWhiteSpace($requiredDeadlineSeconds)) { 0 } else { [int]$requiredDeadlineSeconds }
        deadlineAt = $actionContractDeadlineAt
        onTimeout = $onTimeout
    }
    sendRetry = [pscustomobject][ordered]@{
        count = [int]$sendRetryCount
        max = [int]$maxSendRetries
        deadlineAt = $sendDeadlineAt
        domMessagePresence = $domMessagePresence
        exhausted = Truthy $retryExhausted
    }
    timing = [pscustomobject][ordered]@{
        activationElapsedMs = $activationElapsedMs
        activationSlowPathAlert = Truthy $activationSlowPathAlert
        activationSlowPathThresholdMs = $activationSlowPathThresholdMs
        activationSlowPathReason = $activationSlowPathReason
        requestedToActivated = ElapsedText $requestedAt $activatedAt
        messageReadyToBrowserVerified = ElapsedText $messageReadyAt $browserVerifiedAt
        browserVerifiedToConfirmationRequested = ElapsedText $browserVerifiedAt $confirmationRequestedAt
        confirmationToBrowserAction = ElapsedText $confirmationAt $browserActionAt
        browserActionToReceipt = ElapsedText $browserActionAt $receiptAt
    }
    rows = $rows
}

if ($Format -eq 'Json') {
    $result | ConvertTo-Json -Depth 12
    exit 0
}

$lines = @(
    '| 序号 | 当前项 | 大白话说明 | 状态 | 单项进度 | 下一步 |',
    '|------|--------|------------|------|----------|--------|'
)
foreach ($row in $rows) {
    $lines += "| $($row.index) | $(SafeMarkdown $row.item) | $(SafeMarkdown $row.description) | $(SafeMarkdown $row.status) | $(SafeMarkdown $row.progress) | $(SafeMarkdown $row.next) |"
}
$lines += ''
$lines += if ([string]::IsNullOrWhiteSpace($blockedReason)) {
    '有没有卡住：没有。'
}
else {
    "有没有卡住：卡在$(SafeMarkdown $blockedReason)"
}
$lines += "总进度：$progress%"
$lines += "下一步：$(SafeMarkdown $nextAction)"
$lines -join "`n"
