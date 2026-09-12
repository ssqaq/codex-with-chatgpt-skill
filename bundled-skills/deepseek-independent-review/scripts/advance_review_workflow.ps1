[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Advance', 'RecordReport')]
    [string]$Action,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$StateDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
if ($CodexThreadId -match '^codex://threads/([^/?#]+)') {
    $CodexThreadId = $Matches[1]
}
$CodexThreadId = ([string]$CodexThreadId).Trim()
if ([string]::IsNullOrWhiteSpace($CodexThreadId)) {
    throw '缺少 CodexThreadId，禁止推进无归属评审。'
}

$statePath = Join-Path $StateDir "$TaskId.json"
$bindingPath = Join-Path $StateDir 'thread-bindings.json'
$stateMutexScope = ([IO.Path]::GetFullPath($StateDir).TrimEnd('\') + '|' + $TaskId).ToLowerInvariant()
$stateMutexHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($stateMutexScope))
).Substring(0, 24)
$stateMutexName = "Global\CodexDeepSeekReviewTaskStateV6-$stateMutexHash"

function Text([object]$Value) {
    if ($null -eq $Value) { return '' }
    return ([string]$Value).Trim()
}

function Truthy([object]$Value) {
    return (Text $Value) -in @('True', 'true', '1', 'yes')
}

function Prop([object]$Object, [string]$Name) {
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return Text $property.Value
}

function IntValue([object]$Value, [int]$Default = 0) {
    $number = 0
    if ([int]::TryParse((Text $Value), [ref]$number)) { return $number }
    return $Default
}

function ReadJson([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function WriteJsonAtomic([string]$Path, [object]$Value) {
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $temporary = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText(
            $temporary,
            ($Value | ConvertTo-Json -Depth 30),
            [Text.UTF8Encoding]::new($false)
        )
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = "$Path.$PID.$([guid]::NewGuid().ToString('N')).bak"
            try {
                [IO.File]::Replace($temporary, $Path, $backup, $true)
            }
            finally {
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function SetProp([object]$Object, [string]$Name, [object]$Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function AcquireStateMutex {
    $mutex = [Threading.Mutex]::new($false, $stateMutexName)
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) { throw '无法取得当前 Task 状态锁。' }
        return [pscustomobject]@{ Mutex = $mutex; Owned = $true }
    }
    catch {
        $mutex.Dispose()
        throw
    }
}

function ReleaseStateMutex([object]$Lock) {
    if ($null -eq $Lock) { return }
    if ($Lock.Owned) {
        try { $Lock.Mutex.ReleaseMutex() | Out-Null } catch {}
    }
    $Lock.Mutex.Dispose()
}

function GetCurrentTaskBinding([object]$Registry) {
    if ($null -eq $Registry) { return [pscustomobject]@{ Current = $null; Legacy = @(); Count = 0 } }
    $sameThread = @(
        @($Registry.bindings) |
            Where-Object { (Prop $_ 'codexThreadId') -eq $CodexThreadId }
    )
    $current = @(
        $sameThread |
            Where-Object {
                $active = Prop $_ 'activeTaskId'
                if ([string]::IsNullOrWhiteSpace($active)) { $active = Prop $_ 'taskId' }
                $active -eq $TaskId
            }
    )
    if ($current.Count -gt 1) {
        throw '当前 Codex thread + TaskId 存在多条绑定，拒绝猜测。'
    }
    [pscustomobject]@{
        Current = if ($current.Count -eq 1) { $current[0] } else { $null }
        Legacy  = @($sameThread | Where-Object { $_ -notin $current })
        Count   = $current.Count
    }
}

function GetBindingStatus([object]$Binding) {
    if ($null -eq $Binding) { return 'unbound' }
    $status = Prop $Binding 'status'
    if ([string]::IsNullOrWhiteSpace($status)) { return 'unknown' }
    return $status
}

function BuildReportFingerprint([object]$State, [object]$Binding, [string]$NextAction) {
    @(
        $NextAction,
        (Prop $State 'taskTerminalStatus'),
        (Prop $State 'sendStatus'),
        (Prop $State 'deepseekStatus'),
        (GetBindingStatus $Binding),
        (Prop $Binding 'sendPhase'),
        (Prop $Binding 'lastReceiptStatus')
    ) -join '|'
}

$BrowserActionTimeoutSeconds = 60
$PlatformSendTimeoutSeconds = 30

function ParseInstant([object]$Value) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $text,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed
        )) {
        return $parsed
    }
    return $null
}

function Get-ActionContract([string]$ActionName) {
    switch ($ActionName) {
        'prepare-browser-binding' {
            return [pscustomobject]@{
                requiredAction = 'browser-bind-or-reuse'
                requiredEvidence = 'mcp__cua_repl.js：宿主公开标签清单 + 原标签 DOM/截图，核对官网、当前模型、深度思考和智能搜索、session、tab、runtime'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'auto-recover-runtime-tab' {
            return [pscustomobject]@{
                requiredAction = 'browser-recover-runtime-tab'
                requiredEvidence = 'mcp__cua_repl.js：同一 session、marker、tab 身份和 DOM 核验'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'auto-begin-replacement-bootstrap' {
            return [pscustomobject]@{
                requiredAction = 'browser-replace-lost-session'
                requiredEvidence = 'mcp__cua_repl.js：双来源 confirmed-absent 后的新 tab、官网、当前模型、深度思考和智能搜索和新 session'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'bind-existing-official-session' {
            return [pscustomobject]@{
                requiredAction = 'browser-bind-existing-official-session'
                requiredEvidence = 'mcp__cua_repl.js：当前官方会话 URL、标题、当前模型、深度思考和智能搜索、DOM marker、tab/runtime'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'confirm-platform-before-send' {
            return [pscustomobject]@{
                requiredAction = 'platform-confirm-send'
                requiredEvidence = '宿主平台真实发送确认；不是文字“继续”、Skill chip 或业务授权'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = 0
                onTimeout = 'wait-for-platform-confirmation'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'send-immediately' {
            return [pscustomobject]@{
                requiredAction = 'browser-fill-submit-and-read'
                requiredEvidence = 'mcp__cua_repl.js：输入框 present/enabled、button 或 Enter 提交成功、DOM 消息落点、宿主公开标签清单'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $PlatformSendTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'send-immediately-without-reconfirmation' {
            return [pscustomobject]@{
                requiredAction = 'browser-fill-submit-and-read'
                requiredEvidence = 'mcp__cua_repl.js：复用同一平台确认后立即提交并回读 DOM'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $PlatformSendTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'verify-original-send-outcome' {
            return [pscustomobject]@{
                requiredAction = 'browser-reconcile-original-send'
                requiredEvidence = 'mcp__cua_repl.js：原 session/tab/runtime 的 DOM 消息落点和标签来源'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'fail-browser-workflow-timeout' {
            return [pscustomobject]@{
                requiredAction = 'call-FailBrowserWorkflow'
                requiredEvidence = '记录超时原因、browserToolCallId、当前 task/session/tab/runtime，不重发'
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = 0
                onTimeout = 'freeze'
                onFailure = 'freeze'
            }
        }
        default {
            return [pscustomobject]@{
                requiredAction = 'execute-next-action'
                requiredEvidence = '必须产生状态变化或明确失败记录；不能只汇报'
                browserTool = 'none'
                deadlineSeconds = 0
                onTimeout = 'none'
                onFailure = 'fail-closed'
            }
        }
    }
}

function Set-ActionContract(
    [object]$State,
    [object]$Contract,
    [string]$ActionName,
    [string]$Now
) {
    $oldAction = Prop $State 'requiredAction'
    $oldStatus = Prop $State 'actionContractStatus'
    $issuedAt = Prop $State 'actionContractIssuedAt'
    $deadlineAt = Prop $State 'actionContractDeadlineAt'
    $actionChanged = $oldAction -ne (Text $Contract.requiredAction)
    if ($actionChanged -or [string]::IsNullOrWhiteSpace($issuedAt) -or $oldStatus -ne 'pending') {
        $issuedAt = $Now
        $deadlineAt = if ([int]$Contract.deadlineSeconds -gt 0) {
            ([datetimeoffset]$Now).AddSeconds([int]$Contract.deadlineSeconds).ToString('o')
        } else { '' }
        SetProp $State 'actionContractRevision' "$((IntValue (Prop $State 'actionContractRevision') 0) + 1)"
        SetProp $State 'actionContractStatus' 'pending'
        SetProp $State 'actionContractIssuedAt' $issuedAt
        SetProp $State 'actionContractDeadlineAt' $deadlineAt
    }
    SetProp $State 'requiredAction' (Text $Contract.requiredAction)
    SetProp $State 'requiredEvidence' (Text $Contract.requiredEvidence)
    SetProp $State 'requiredBrowserTool' (Text $Contract.browserTool)
    SetProp $State 'requiredDeadlineSeconds' ([string]$Contract.deadlineSeconds)
    SetProp $State 'onTimeout' (Text $Contract.onTimeout)
    SetProp $State 'onFailure' (Text $Contract.onFailure)
    SetProp $State 'requiredActionName' $ActionName
}

if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    throw "找不到任务状态：$statePath"
}

$lock = AcquireStateMutex
try {
    $state = ReadJson $statePath
    if ($null -eq $state) { throw "任务状态为空：$statePath" }
    if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
        throw '任务状态归属冲突，禁止推进其他 Codex thread。'
    }
    $registry = ReadJson $bindingPath
    $bindingInfo = GetCurrentTaskBinding $registry
    $binding = $bindingInfo.Current
    $bindingStatus = GetBindingStatus $binding
    $now = (Get-Date).ToString('o')
    $oldRevision = IntValue (Prop $state 'stateRevision') 0
    $nextAction = Prop $state 'nextAction'
    if ([string]::IsNullOrWhiteSpace($nextAction)) { $nextAction = 'prepare-browser-binding' }
    $changed = $false
    $blockedReason = ''
    $resultStatus = 'advanced'

    if ($Action -eq 'RecordReport') {
        $fingerprint = BuildReportFingerprint $state $binding $nextAction
        $previousFingerprint = Prop $state 'lastReportFingerprint'
        $previousReportActionAt = Prop $state 'lastReportActionAt'
        $lastActionAt = Prop $state 'lastActionAt'
        $noOpCount = IntValue (Prop $state 'noOpReportCount') 0
        if (
            $fingerprint -eq $previousFingerprint -and
            $previousReportActionAt -eq $lastActionAt
        ) {
            $noOpCount++
        }
        else {
            $noOpCount = 0
        }
        SetProp $state 'lastReportFingerprint' $fingerprint
        SetProp $state 'lastReportActionAt' $lastActionAt
        SetProp $state 'lastReportAt' $now
        SetProp $state 'noOpReportCount' "$noOpCount"
        SetProp $state 'stateRevision' "$($oldRevision + 1)"
        $waitingForReply = (Prop $binding 'sendPhase') -eq 'receipt-confirmed' -and
            (Prop $state 'deepseekStatus') -notin @('已收到完整回复','已完成') -and
            -not (Truthy (Prop $binding 'pendingReceipt')) -and -not (Truthy (Prop $binding 'auditRisk'))
        if ($waitingForReply) { $noOpCount = 0; SetProp $state 'noOpReportCount' '0' }
        if ($noOpCount -ge 2) {
            SetProp $state 'nextAction' 'advance-review-workflow'
            SetProp $state 'blockedReason' '连续两次进度汇报没有真实动作，禁止继续只汇报；必须调用 advance_review_workflow.ps1。'
            $resultStatus = 'workflow-stalled'
        }
        $changed = $true
    }
    else {
        $recoverable = (Prop $state 'taskTerminalStatus') -eq 'frozen' -and
            (Prop $state 'nextAction') -eq 'auto-recover-runtime-tab' -and
            $bindingStatus -eq 'recovery-pending' -and
            -not (Truthy (Prop $state 'reviewCancelled')) -and
            (IntValue (Prop $binding 'browserRecoveryCount') 0) -le 1
        if ((Prop $state 'taskTerminalStatus') -in @('completed', 'failed', 'cancelled', 'frozen') -and -not $recoverable) {
            $resultStatus = 'terminal'
            $blockedReason = '当前 Task 已终态，不能继续推进。'
        }
        elseif ($null -eq $binding) {
            $nextAction = 'prepare-browser-binding'
            $blockedReason = if ($bindingInfo.Legacy.Count -gt 0) {
                '当前 Task 没有自己的 bound 会话；同一 thread 的旧 Task 绑定只能保留审计，不能继承。'
            }
            else {
                '当前 Task 尚未绑定 DeepSeek 官网会话。'
            }
            SetProp $state 'nextAction' $nextAction
            SetProp $state 'blockedReason' $blockedReason
        }
        elseif ($bindingStatus -eq 'recovery-pending') {
            $nextAction = 'auto-recover-runtime-tab'
            $blockedReason = '浏览器 runtime 需要按当前 Task 自动恢复。'
            SetProp $state 'nextAction' $nextAction
            SetProp $state 'blockedReason' $blockedReason
        }
        elseif ($bindingStatus -eq 'lost' -and (Truthy (Prop $binding 'replacementRequired'))) {
            $nextAction = 'bind-existing-official-session'
            $blockedReason = '旧绑定已失效，先核验并绑定当前右侧栏已有官方会话；只有双来源明确 absent 才能新建 replacement。'
            SetProp $state 'nextAction' $nextAction
            SetProp $state 'blockedReason' $blockedReason
        }
        elseif (
            (Truthy (Prop $binding 'pendingReceipt')) -or
            (Truthy (Prop $binding 'auditRisk')) -or
            (Truthy (Prop $binding 'resendBlocked'))
        ) {
            $nextAction = 'reconcile-pending-receipt'
            $blockedReason = '当前 Task 有未核实回执或审计风险，禁止直接发送新消息。'
            SetProp $state 'nextAction' $nextAction
            SetProp $state 'blockedReason' $blockedReason
        }
        elseif ((Prop $binding 'browserConfirmationStatus') -eq 'awaiting') {
            $nextAction = 'confirm-platform-before-send'
            SetProp $state 'nextAction' $nextAction
        }
        elseif ((Prop $binding 'sendPhase') -eq 'confirmed') {
            $nextAction = 'send-immediately'
            SetProp $state 'nextAction' $nextAction
        }
        elseif ((Prop $binding 'sendPhase') -eq 'prepared') {
            $nextAction = 'confirm-platform-before-send'
            SetProp $state 'nextAction' $nextAction
        }
        elseif (
            (Prop $state 'nextAction') -eq 'record-next-round' -and
            [string]::IsNullOrWhiteSpace((Prop $state 'messageReadyAt'))
        ) {
            $nextAction = 'prepare-review-message'
            SetProp $state 'nextAction' $nextAction
        }
        else {
            SetProp $state 'nextAction' $nextAction
        }
        SetProp $state 'blockedReason' $blockedReason
        SetProp $state 'lastActionAt' $now
        SetProp $state 'noOpReportCount' '0'
        SetProp $state 'stateRevision' "$($oldRevision + 1)"
        $changed = $true
    }

    $resolvedNextAction = Prop $state 'nextAction'
    $contract = Get-ActionContract $resolvedNextAction
    $contractDeadline = ParseInstant (Prop $state 'actionContractDeadlineAt')
    $nowInstant = [datetimeoffset]$now
    $browserActionObserved = (
        -not [string]::IsNullOrWhiteSpace((Prop $state 'browserActionAt')) -or
        -not [string]::IsNullOrWhiteSpace((Prop $state 'browserActionEvidence')) -or
        (Prop $state 'submissionStatus') -in @('succeeded', 'failed')
    )
    $sendDeadline = ParseInstant (Prop $state 'sendDeadlineAt')
    if (
        $Action -eq 'Advance' -and
        $contractDeadline -ne $null -and
        $nowInstant -ge $contractDeadline -and
        -not $browserActionObserved -and
        (Prop $state 'actionContractStatus') -eq 'pending'
    ) {
        SetProp $state 'nextAction' 'fail-browser-workflow-timeout'
        SetProp $state 'blockedReason' "动作合同 $resolvedNextAction 已超过 $($contract.deadlineSeconds) 秒，没有真实浏览器动作证据；必须调用 FailBrowserWorkflow，禁止继续汇报或重发。"
        SetProp $state 'actionContractStatus' 'timed-out'
        SetProp $state 'executionStatus' '禁止修改'
        SetProp $state 'sendAuthorization' 'none'
        $resultStatus = 'workflow-timeout'
        $changed = $true
        $resolvedNextAction = 'fail-browser-workflow-timeout'
        $contract = Get-ActionContract $resolvedNextAction
    }
    elseif (
        $Action -eq 'Advance' -and
        $sendDeadline -ne $null -and
        $nowInstant -ge $sendDeadline -and
        (Prop $state 'sendPhase') -eq 'confirmed' -and
        -not $browserActionObserved
    ) {
        SetProp $state 'nextAction' 'fail-browser-workflow-timeout'
        SetProp $state 'blockedReason' '平台确认后的 30 秒发送时限已到，但没有真实提交或回执；必须调用 FailBrowserWorkflow，不能再次询问确认。'
        SetProp $state 'actionContractStatus' 'timed-out'
        SetProp $state 'executionStatus' '禁止修改'
        SetProp $state 'sendAuthorization' 'none'
        $resultStatus = 'workflow-timeout'
        $changed = $true
        $resolvedNextAction = 'fail-browser-workflow-timeout'
        $contract = Get-ActionContract $resolvedNextAction
    }
    $timedOutThisPass = $resultStatus -eq 'workflow-timeout'
    Set-ActionContract $state $contract $resolvedNextAction $now
    if ($timedOutThisPass) {
        # 超时是终止信号，不要在切换到 fail-browser-workflow-timeout
        # 时又把合同重置成 pending，避免“超时后继续空转”。
        SetProp $state 'actionContractStatus' 'timed-out'
        SetProp $state 'actionContractDeadlineAt' ''
    }
    if ($changed) {
        WriteJsonAtomic $statePath $state
    }

    [pscustomobject][ordered]@{
        status = $resultStatus
        action = $Action
        taskId = $TaskId
        codexThreadId = $CodexThreadId
        nextAction = Prop $state 'nextAction'
        bindingStatus = $bindingStatus
        currentTaskBinding = ($null -ne $binding)
        legacyBindingCount = $bindingInfo.Legacy.Count
        stateRevision = IntValue (Prop $state 'stateRevision') $oldRevision
        lastActionAt = Prop $state 'lastActionAt'
        noOpReportCount = IntValue (Prop $state 'noOpReportCount') 0
        requiredAction = Prop $state 'requiredAction'
        requiredEvidence = Prop $state 'requiredEvidence'
        browserTool = Prop $state 'requiredBrowserTool'
        deadlineSeconds = IntValue (Prop $state 'requiredDeadlineSeconds') 0
        actionContractStatus = Prop $state 'actionContractStatus'
        actionContractIssuedAt = Prop $state 'actionContractIssuedAt'
        actionContractDeadlineAt = Prop $state 'actionContractDeadlineAt'
        onTimeout = Prop $state 'onTimeout'
        onFailure = Prop $state 'onFailure'
        blockedReason = Prop $state 'blockedReason'
        changed = $changed
    } | ConvertTo-Json -Depth 8
}
finally {
    ReleaseStateMutex $lock
}
