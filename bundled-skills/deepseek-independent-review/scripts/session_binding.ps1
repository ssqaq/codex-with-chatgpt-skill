[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'Show',
        'BeginBootstrap',
        'VerifyBootstrap',
        'CompleteBootstrap',
        'Claim',
        'BindExistingOfficialSession',
        'RecoverExpiredLeaseBinding',
        'InspectRecoveryBinding',
        'InspectLostBinding',
        'RecoverLostBinding',
        'Verify',
        'PrepareSend',
        'ConfirmBrowserSend',
        'RetrySendAfterTimeout',
        'ResolvePendingSend',
        'RecoverRuntimeTab',
        'MigrateToInAppSidebar',
        'MigrateToLocalSession',
        'NormalizeInactiveBinding',
        'CompleteTask',
        'ForceTerminateTask',
        'MarkLost',
        'FailBrowserWorkflow',
        'CancelBootstrap',
        'CancelReview',
        'RecordSendOutcome',
        'AcquireBrowserLease',
        'RenewBrowserLease',
        'ReleaseBrowserLease',
        'ForceReleaseLease'
    )]
    [string]$Action,
    [string]$TaskId,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$DeepSeekSessionId,
    [string]$DeepSeekSessionTitle,
    [string]$BrowserTabId,
    [string]$BrowserTabTitle,
    [string]$BrowserTabIdentityScope = 'browser-runtime-tab-id',
    [ValidateSet('', 'codex-in-app-sidebar')]
    [string]$BrowserSurface = '',
    [string]$BrowserRuntimeId,
    [long]$RuntimeEpoch = -1,
    [int]$TabMatchCount = -1,
    [ValidateSet('', 'dom')]
    [string]$EvidenceSource = '',
    [string]$DomTargetUrl,
    [string]$DomSessionTitle,
    [string]$DomModel,
    [string]$DomReasoning,
    [string]$DomSearch,
    [ValidateSet('', 'absent', 'present', 'unknown')]
    [string]$DomMessagePresence = '',
    [ValidateSet('', 'present', 'absent', 'unknown')]
    [string]$DomInputPresence = '',
    [ValidateSet('', 'enabled', 'disabled', 'unknown')]
    [string]$DomInputEnabled = '',
    [ValidateSet('', 'enabled', 'disabled', 'unknown')]
    [string]$DomSendControl = '',
    [ValidateSet('', 'awaiting', 'confirmed', 'rejected')]
    [string]$PlatformConfirmationStatus = '',
    [ValidateSet('', 'action-time-user-response', 'browser-tool-token')]
    [string]$ConfirmationSource = '',
    [string]$PlatformConfirmationEvidence,
    [ValidateSet('', 'button', 'enter')]
    [string]$SubmissionMechanism = '',
    [ValidateSet('', 'succeeded', 'failed', 'unknown')]
    [string]$SubmissionStatus = '',
    [string]$BrowserActionAt,
    [string]$BrowserActionEvidence,
    [string]$BrowserEvidenceCapturedAt,
    [string]$MessageReadyAt,
    [ValidateSet('', 'confirmed', 'absent', 'wrong-session', 'unknown', 'empty')]
    [string]$OpenTabsEvidence = '',
    [ValidateSet('', 'confirmed', 'absent', 'wrong-session', 'unknown', 'empty')]
    [string]$TabsListEvidence = '',
    [string]$DomMessageMarker,
    [string]$ExpectedMessageMarker,
    [ValidateSet(
        '',
        'official-session-id+browser-tab-id',
        'official-marker+browser-tab-id',
        'backend-session-id+browser-tab-id',
        'bootstrap-pending'
    )]
    [string]$BindingConfidence = '',
    [string]$MessageFingerprint,
    [string]$AuthorizedMessageFingerprint,
    [string]$SendAttemptId,
    [string]$SendIdempotencyKey,
    [ValidateSet('confirmed', 'unknown', 'wrong-session', 'not-found')]
    [string]$ReceiptStatus,
    [string]$Reason,
    [ValidateSet('', 'confirmed-absent', 'confirmed-mismatch')]
    [string]$LossEvidence = '',
    [int]$LossObservationCount = 0,
    [int]$LossObservationWindowSeconds = 0,
    [string]$LossEvidenceSources = '',
    [ValidateSet('', 'not-found', 'unknown')]
    [string]$OriginalConversationStatus = '',
    [string]$BrowserTool = 'mcp__cua_repl.js',
    [ValidateSet('', 'not-started', 'available', 'failed', 'unavailable')]
    [string]$BrowserToolStatus = '',
    [ValidateSet('', 'runtime-disconnected', 'tool-failed', 'unknown')]
    [string]$BrowserFailureClass = 'runtime-disconnected',
    [string]$BrowserToolCallId,
    [int]$BrowserToolFailureCount = -1,
    [int]$LeaseSeconds = 90,
    [string]$LeaseToken,
    [long]$LeaseEpoch = -1,
    [string]$StateDir,
    [switch]$MigrateLegacyTab,
    [switch]$ReplaceLost
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$TargetUrl = 'https://chat.deepseek.com/'
$TargetModel = '网页当前模型（合并升级版）'
$TargetSearch = '智能搜索'
$TargetReasoning = '深度思考'
$TargetBrowserSurface = 'codex-in-app-sidebar'
$BrowserActionTimeoutSeconds = 60
$PlatformSendTimeoutSeconds = 30
# v8：任务状态、浏览器 lease 都按 thread/task 隔离；共享绑定注册表仍使用全局互斥锁。
$SchemaVersion = 7

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$BindingPath = Join-Path $StateDir 'thread-bindings.json'
$transactionThreadId = ([string]$CodexThreadId).Trim()
if ($transactionThreadId -match '^codex://threads/([^/?#]+)') {
    $transactionThreadId = $Matches[1]
}
$safeThreadId = [regex]::Replace($transactionThreadId, '[^A-Za-z0-9._-]', '_')
$safeTaskId = [regex]::Replace(([string]$TaskId).Trim(), '[^A-Za-z0-9._-]', '_')
if ([string]::IsNullOrWhiteSpace($safeThreadId)) {
    $safeThreadId = 'unassigned-thread'
}
if ([string]::IsNullOrWhiteSpace($safeTaskId)) {
    $safeTaskId = 'unassigned-task'
}
$LegacyLeasePath = Join-Path $StateDir 'browser-lease.json'
$LegacyLeaseEpochPath = Join-Path $StateDir 'browser-lease-epoch.json'
$LeasePath = Join-Path $StateDir "browser-lease.$safeThreadId.json"
$LeaseEpochPath = Join-Path $StateDir "browser-lease-epoch.$safeThreadId.json"
$TransactionPath = Join-Path $StateDir "workflow-transaction.$safeThreadId.$safeTaskId.json"
$BindingMutexName = 'Global\CodexDeepSeekReviewBindingV5'
$stateMutexScope = (
    [IO.Path]::GetFullPath($StateDir).TrimEnd('\') + '|' + $safeTaskId
).ToLowerInvariant()
$stateMutexHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($stateMutexScope)
    )
).Substring(0, 24)
$StateMutexName = "Global\CodexDeepSeekReviewTaskStateV6-$stateMutexHash"

function Text([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [datetime] -or $Value -is [DateTimeOffset]) { return $Value.ToUniversalTime().ToString('o') }
    return ([string]$Value).Trim()
}

function Normalize-ThreadId([string]$Value) {
    $valueText = Text $Value
    if ($valueText -match '^codex://threads/([^/?#]+)') {
        return $Matches[1]
    }
    return $valueText
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

function LongProp([object]$Object, [string]$Name, [long]$Default = 0) {
    $number = 0L
    if ([long]::TryParse((Prop $Object $Name), [ref]$number)) {
        return $number
    }
    return $Default
}

function BoolProp([object]$Object, [string]$Name) {
    return (Prop $Object $Name) -in @('True', 'true', '1', 'yes')
}

function Get-SendIdempotencyKey([string]$Fingerprint) {
    $inputText = "$CodexThreadId|$TaskId|$(Text $Fingerprint)"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($inputText)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ConfirmationContextHash(
    [string]$Fingerprint,
    [string]$IdempotencyKey,
    [string]$SessionId
) {
    $inputText = @(
        $CodexThreadId,
        $TaskId,
        (Text $Fingerprint),
        (Text $IdempotencyKey),
        (Text $SessionId),
        (Text $BrowserTabId),
        (Text $BrowserRuntimeId),
        "$RuntimeEpoch",
        (Text $LeaseToken),
        "$LeaseEpoch"
    ) -join '|'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($inputText)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ConfirmedSendResumeState(
    [object]$Binding,
    [string]$Fingerprint
) {
    $expectedContextHash = Get-ConfirmationContextHash `
        -Fingerprint $Fingerprint `
        -IdempotencyKey (Prop $Binding 'sendIdempotencyKey') `
        -SessionId (Prop $Binding 'deepseekSessionId')
    $deadlineExpired = $false
    $deadlineText = Prop $Binding 'sendDeadlineAt'
    if (-not [string]::IsNullOrWhiteSpace($deadlineText)) {
        $deadline = [datetimeoffset]::MinValue
        if ([datetimeoffset]::TryParse($deadlineText, [ref]$deadline)) {
            $deadlineExpired = [datetimeoffset]::Now -gt $deadline
        }
    }
    $browserActionObserved = (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'browserActionAt')) -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'submissionStatus'))
    )
    $confirmedForMessage = (
        (BoolProp $Binding 'pendingReceipt') -and
        (Prop $Binding 'sendOwnerTaskId') -eq (Text $TaskId) -and
        (Prop $Binding 'pendingMessageFingerprint') -eq (Text $Fingerprint) -and
        (Prop $Binding 'browserConfirmationStatus') -eq 'confirmed' -and
        (Prop $Binding 'sendPhase') -eq 'confirmed'
    )
    $sameContext = (
        $confirmedForMessage -and
        (Prop $Binding 'confirmationContextHash') -eq $expectedContextHash
    )

    return [pscustomobject]@{
        confirmedForMessage    = $confirmedForMessage
        sameContext           = $sameContext
        browserActionObserved = $browserActionObserved
        deadlineExpired       = $deadlineExpired
        reusable              = (
            $sameContext -and
            -not $browserActionObserved -and
            -not $deadlineExpired
        )
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

function Write-JsonAtomic([string]$Path, [object]$Value) {
    $temporaryPath = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $stream = [IO.File]::Open(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backupPath = "$Path.$PID.$([guid]::NewGuid().ToString('N')).bak"
            try {
                [IO.File]::Replace($temporaryPath, $Path, $backupPath, $true)
            }
            finally {
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-TransactionIntent(
    [string]$Operation,
    [string]$Phase,
    [hashtable]$Payload
) {
    $orderedPayload = [ordered]@{}
    foreach ($entry in $Payload.GetEnumerator()) {
        $orderedPayload[$entry.Key] = $entry.Value
    }
    Write-JsonAtomic $TransactionPath ([ordered]@{
            version   = 1
            operation = $Operation
            phase     = $Phase
            payload   = $orderedPayload
            updatedAt = (Get-Date).ToString('o')
        })
}

function Update-TransactionPhase([string]$Phase) {
    $intent = Read-Json $TransactionPath $null
    if ($null -eq $intent) {
        throw '事务日志不存在，拒绝继续写入。'
    }
    SetProp $intent 'phase' $Phase
    SetProp $intent 'updatedAt' (Get-Date).ToString('o')
    Write-JsonAtomic $TransactionPath $intent
}

function Clear-TransactionIntent {
    if (Test-Path -LiteralPath $TransactionPath -PathType Leaf) {
        Remove-Item -LiteralPath $TransactionPath -Force
    }
}

function Get-PendingTransaction {
    if (-not (Test-Path -LiteralPath $TransactionPath -PathType Leaf)) {
        return $null
    }
    return Read-Json $TransactionPath $null
}

function Read-Json([string]$Path, [object]$Default) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $Default
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }
    return $raw | ConvertFrom-Json
}

function With-BindingMutex([scriptblock]$Body) {
    $mutex = [Threading.Mutex]::new($false, $BindingMutexName)
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) {
            throw '无法取得会话绑定锁，另一个任务正在更新。'
        }
        & $Body
    }
    finally {
        if ($owned) {
            try {
                $mutex.ReleaseMutex() | Out-Null
            }
            catch {
            }
        }
        $mutex.Dispose()
    }
}

function TargetUri([string]$Value) {
    try {
        $uri = [uri](Text $Value)
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'chat.deepseek.com' -or $uri.Port -ne 443) {
            return $null
        }
        return $uri
    }
    catch {
        return $null
    }
}

function IsTargetUrl([string]$Value) {
    return $null -ne (TargetUri $Value)
}

function IsBootstrapUrl([string]$Value) {
    $uri = TargetUri $Value
    return $null -ne $uri -and
        $uri.AbsolutePath -in @('', '/') -and
        [string]::IsNullOrWhiteSpace($uri.Query)
}

function SessionIdFromUrl([string]$Value) {
    $uri = TargetUri $Value
    if ($null -eq $uri) {
        return ''
    }

    $path = $uri.AbsolutePath.Trim('/')
    # 只信任 DeepSeek 官网真实会话路由，不能从任意 query/path 猜 session。
    if ($path -match '^a/chat/s/(?<id>[A-Za-z0-9][A-Za-z0-9_-]{7,127})$') {
        return "official-chat:$($Matches['id'])"
    }
    return ''
}

function ResolvedSessionId {
    $given = Text $DeepSeekSessionId
    $fromUrl = SessionIdFromUrl $DomTargetUrl
    $marker = Text $DomMessageMarker

    if (-not [string]::IsNullOrWhiteSpace($given)) {
        if ($given -notmatch '^(official-chat|official-marker):') {
            throw '会话 ID 必须是官网 official-chat 或当前 thread 的 official-marker。'
        }
        if (
            $given -like 'official-chat:*' -and
            [string]::IsNullOrWhiteSpace($fromUrl)
        ) {
            throw 'official-chat sessionId 必须由 DeepSeek 官网真实会话 URL 证明，不能只信任外部传入值。'
        }
        if (
            $given -like 'official-chat:*' -and
            -not [string]::IsNullOrWhiteSpace($fromUrl) -and
            $given -ne $fromUrl
        ) {
            throw '传入 sessionId 与本机页面 URL 不一致。'
        }
        if (
            $given -like 'official-marker:*' -and
            -not [string]::IsNullOrWhiteSpace($marker) -and
            $given -ne "official-marker:$marker"
        ) {
            throw '传入 marker 与页面 marker 不一致。'
        }
        if (
            $given -like 'official-marker:*' -and
            $given -notlike "*$CodexThreadId*"
        ) {
            throw 'marker 不属于当前 Codex thread。'
        }
        return $given
    }

    if (-not [string]::IsNullOrWhiteSpace($fromUrl)) {
        return $fromUrl
    }
    if (-not [string]::IsNullOrWhiteSpace($marker)) {
        return "official-marker:$marker"
    }
    return ''
}

function MarkerValue {
    if (-not [string]::IsNullOrWhiteSpace((Text $DomMessageMarker))) {
        return Text $DomMessageMarker
    }
    if (-not [string]::IsNullOrWhiteSpace((Text $ExpectedMessageMarker))) {
        return Text $ExpectedMessageMarker
    }
    $sessionId = Text $DeepSeekSessionId
    if ($sessionId -like 'official-marker:*') {
        return $sessionId.Substring('official-marker:'.Length)
    }
    return ''
}

function ConfidenceValue {
    $sessionId = ResolvedSessionId
    if ($sessionId -like 'official-chat:*') {
        return 'official-session-id+browser-tab-id'
    }
    if ($sessionId -like 'official-marker:*') {
        return 'official-marker+browser-tab-id'
    }
    return 'bootstrap-pending'
}

function Require-Thread {
    $script:CodexThreadId = Normalize-ThreadId $script:CodexThreadId
    if ([string]::IsNullOrWhiteSpace($script:CodexThreadId)) {
        throw '缺少 CodexThreadId，禁止猜测会话归属。'
    }
}

function Require-Task {
    if ([string]::IsNullOrWhiteSpace((Text $TaskId))) {
        throw '所有 DeepSeek 操作都必须提供 TaskId。'
    }
}

function Get-TaskState {
    Require-Task
    $taskPath = Join-Path $StateDir "$TaskId.json"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        throw "找不到任务状态：$taskPath"
    }
    return Read-Json $taskPath @{}
}

function Require-Activation {
    Require-Thread
    $state = Get-TaskState
    if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
        throw '任务状态不属于当前 Codex thread。'
    }
    if ((BoolProp $state 'reviewRecoveryRequired') -and $Action -in @('PrepareSend','ConfirmBrowserSend','RetrySendAfterTimeout')) { throw '恢复记录尚未核对原网页，不能发送。' }
    $recoveryClaimAllowed = (
        $Action -in @('Claim', 'RecoverRuntimeTab') -and
        (Prop $state 'activationStatus') -eq 'frozen' -and
        (Prop $state 'taskTerminalStatus') -eq 'frozen' -and
        (Prop $state 'nextAction') -eq 'auto-recover-runtime-tab'
    )
    if (
        (Prop $state 'activationStatus') -ne 'activated' -and
        -not $recoveryClaimAllowed
    ) {
        throw 'Skill 尚未真实激活，禁止操作 DeepSeek 页面。'
    }
    if (BoolProp $state 'auditOnly') {
        throw '当前任务是历史审计态，禁止发送。'
    }
    if (
        (Prop $state 'taskTerminalStatus') -in @('completed', 'failed', 'cancelled', 'frozen') -and
        -not $recoveryClaimAllowed
    ) {
        throw '当前 TaskId 已终态，不能恢复发送能力。'
    }
    if (
        (Prop $state 'targetUrl') -ne $TargetUrl -or
        (Prop $state 'model') -notin @($TargetModel, '专家模式') -or
        (Prop $state 'reasoning') -ne $TargetReasoning -or
        (Prop $state 'searchMode') -ne $TargetSearch
    ) {
        throw '任务状态不是当前 DeepSeek 官网 + 深度思考 + 智能搜索规范。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $state 'conversationUrl')) -and
        -not (IsTargetUrl (Prop $state 'conversationUrl'))
    ) {
        throw '任务状态残留外部 conversationUrl，禁止继续发送。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $state 'deepseekSessionId')) -and
        (Prop $state 'deepseekSessionId') -notmatch '^(official-chat|official-marker):'
    ) {
        throw '任务状态残留不受支持的 sessionId，禁止继续发送。'
    }
    return $state
}

function Require-CancellableTask {
    Require-Thread
    Require-Task
    $state = Get-TaskState
    if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
        throw '任务状态不属于当前 Codex thread，禁止取消。'
    }
    if ((Prop $state 'taskTerminalStatus') -in @('completed', 'failed')) {
        throw '已完成或失败的任务不能被取消。'
    }
    return $state
}

function Assert-Tab {
    if ((Text $BrowserSurface) -ne $TargetBrowserSurface) {
        throw '只允许 Codex 右侧栏内置浏览器；禁止 Chrome、Edge、扩展和外部浏览器。'
    }
    if (
        [string]::IsNullOrWhiteSpace((Text $BrowserTabId)) -or
        [string]::IsNullOrWhiteSpace((Text $BrowserRuntimeId)) -or
        $RuntimeEpoch -lt 1 -or
        $TabMatchCount -ne 1
    ) {
        throw '右侧栏 tab、runtime、epoch 和唯一匹配证据不完整。'
    }
    if ((Text $BrowserTabIdentityScope) -in @('index', 'ordinal', 'active-tab', 'process-lifetime')) {
        throw '禁止用活动 tab 或数字序号做身份。'
    }
}

function Assert-Dom(
    [switch]$Bootstrap,
    [switch]$Marker,
    [switch]$Title,
    [switch]$RequireSendSurface
) {
    if ($EvidenceSource -ne 'dom') {
        throw '必须提供本轮真实 DOM 证据。'
    }
    if (-not (IsTargetUrl $DomTargetUrl)) {
        throw '页面必须是 https://chat.deepseek.com/。'
    }
    if ($Bootstrap -and -not (IsBootstrapUrl $DomTargetUrl)) {
        throw '首次绑定必须从 DeepSeek 官网空白会话页开始。'
    }
    if ((Text $DomModel) -notin @($TargetModel, '专家模式')) {
        throw '页面未确认 DeepSeek 当前模型。'
    }
    if ((Text $DomReasoning) -ne $TargetReasoning) {
        throw '页面未开启深度思考。'
    }
    if ((Text $DomSearch) -ne $TargetSearch) {
        throw '页面未开启智能搜索。'
    }
    if (
        $Marker -and
        [string]::IsNullOrWhiteSpace((Text $DomMessageMarker)) -and
        (ResolvedSessionId) -notlike 'official-chat:*'
    ) {
        throw '缺少当前会话的绑定 marker 或官网 official-chat sessionId。'
    }
    if ($Title -and [string]::IsNullOrWhiteSpace((Text $DomSessionTitle))) {
        throw '缺少当前会话标题。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $DomMessageMarker)) -and
        (Text $DomMessageMarker) -notlike "*$CodexThreadId*"
    ) {
        throw '页面 marker 不属于当前 Codex thread。'
    }
    if ($RequireSendSurface) {
        if ((Text $DomInputPresence) -ne 'present') {
            throw '页面输入框不存在或无法确认，禁止发送。'
        }
        if ((Text $DomInputEnabled) -ne 'enabled') {
            throw '页面输入框未启用或无法确认，禁止发送。'
        }
    }
    Assert-Tab
}

function Assert-SubmissionEvidence([object]$Binding) {
    if ((Text $SubmissionStatus) -ne 'succeeded') {
        throw 'confirmed 回执必须证明浏览器提交动作成功。'
    }
    $inputPresence = Text $DomInputPresence
    if ([string]::IsNullOrWhiteSpace($inputPresence)) {
        $inputPresence = Prop $Binding 'domInputPresence'
    }
    $inputEnabled = Text $DomInputEnabled
    if ([string]::IsNullOrWhiteSpace($inputEnabled)) {
        $inputEnabled = Prop $Binding 'domInputEnabled'
    }
    $sendControl = Text $DomSendControl
    if ([string]::IsNullOrWhiteSpace($sendControl)) {
        $sendControl = Prop $Binding 'domSendControl'
    }
    if ((Text $SubmissionMechanism) -eq 'button') {
        if ($sendControl -ne 'enabled') {
            throw 'button 提交必须证明填入后发送按钮已启用。'
        }
        return
    }
    if ((Text $SubmissionMechanism) -eq 'enter') {
        if (
            $inputPresence -ne 'present' -or
            $inputEnabled -ne 'enabled'
        ) {
            throw 'Enter 提交必须证明输入框存在且已启用。'
        }
        return
    }
    throw 'confirmed 回执必须明确 SubmissionMechanism=button 或 enter。'
}

function Assert-ReceiptEvidence {
    $openEvidence = Text $OpenTabsEvidence
    $listEvidence = Text $TabsListEvidence
    $positiveSources = @($openEvidence, $listEvidence) |
        Where-Object { $_ -eq 'confirmed' }
    $absentSources = @($openEvidence, $listEvidence) |
        Where-Object { $_ -eq 'absent' }
    $wrongSessionSources = @($openEvidence, $listEvidence) |
        Where-Object { $_ -eq 'wrong-session' }
    $contradictorySources = @($openEvidence, $listEvidence) |
        Where-Object { $_ -in @('confirmed', 'wrong-session') }

    if ($ReceiptStatus -eq 'confirmed') {
        if (
            (Text $DomMessagePresence) -ne 'present' -or
            $positiveSources.Count -lt 1 -or
            $wrongSessionSources.Count -gt 0
        ) {
            throw 'confirmed 回执必须有 DOM present、至少一个标签来源 confirmed，且不能有 wrong-session 冲突；另一来源为空/unknown 时按未知辅助证据处理。'
        }
        return
    }
    if ($ReceiptStatus -eq 'not-found') {
        if (
            (Text $DomMessagePresence) -ne 'absent' -or
            $absentSources.Count -lt 1 -or
            $contradictorySources.Count -gt 0
        ) {
            throw 'not-found 回执必须有 DOM absent、至少一个标签来源明确 absent，且不能有 confirmed/wrong-session 冲突；另一来源为空/unknown 时按未知辅助证据处理。'
        }
        return
    }
    if ($ReceiptStatus -eq 'wrong-session') {
        if (
            (Text $DomMessagePresence) -ne 'absent' -or
            $wrongSessionSources.Count -lt 1 -or
            $positiveSources.Count -gt 0
        ) {
            throw 'wrong-session 回执必须有 DOM absent、至少一个标签来源 wrong-session，且不能有 confirmed 冲突；另一来源为空/unknown 时按未知辅助证据处理。'
        }
        return
    }
}

function Init-Binding([object]$Binding) {
    if ($null -eq $Binding) {
        return
    }
    $defaults = [ordered]@{
        activeTaskId                   = (Prop $Binding 'taskId')
        taskHistory                    = @()
        browserSurface                 = 'unverified-legacy-or-external'
        browserTabIdentityScope        = ''
        browserRuntimeId               = ''
        runtimeEpoch                   = 0
        tabMatchCount                  = 0
        targetUrl                      = ''
        conversationUrl                = ''
        model                          = ''
        reasoning                      = ''
        bindingConfidence              = ''
        evidenceSource                 = ''
        domSessionTitle                = ''
        domMessageMarker               = ''
        expectedMessageMarker          = ''
        pendingReceipt                 = $false
        sendPhase                      = ''
        pendingMessageFingerprint      = ''
        authorizedMessageFingerprint   = ''
        sendOwnerTaskId                = ''
        sendIdempotencyKey             = ''
        sendAttemptId                 = ''
        browserConfirmationRequired    = $false
        browserConfirmationStatus      = ''
        confirmationSource             = ''
        confirmationContextHash        = ''
        browserConfirmationAt          = ''
        browserConfirmationEvidence    = ''
        messageReadyAt                 = ''
        browserVerifiedAt              = ''
        confirmationRequestedAt        = ''
        browserActionAt                = ''
        browserActionEvidence          = ''
        browserEvidenceCapturedAt      = ''
        receiptAt                      = ''
        submissionMechanism            = ''
        submissionStatus               = ''
        domInputPresence               = ''
        domInputEnabled                = ''
        domSendControl                 = ''
        deadlineStartedAt              = ''
        sendDeadlineAt                = ''
        sendRetryCount                = 0
        maxSendRetries                = 2
        lastRetryAt                   = ''
        retryHistory                  = @()
        domMessagePresence            = ''
        retryExhausted                = $false
        browserTool                   = 'mcp__cua_repl.js'
        browserToolStatus             = 'not-started'
        browserToolCallId             = ''
        browserToolFailureCount       = 0
        browserToolFailureReason      = ''
        lastBrowserToolAt             = ''
        browserEvidenceStatus         = ''
        browserFailureClass            = ''
        browserRecoveryCount           = 0
        browserRecoveryLimit           = 1
        browserRecoveryStatus          = ''
        resendBlocked                  = $false
        auditRisk                      = $false
        auditRiskReason               = ''
        lastMessageFingerprint         = ''
        lastReceiptStatus              = ''
        lastOpenTabsEvidence           = ''
        lastTabsListEvidence           = ''
        lastReceiptEvidenceAt          = ''
        lossEvidence                   = ''
        lossEvidenceSources            = ''
        lossObservationCount           = 0
        lossObservationWindowSeconds   = 0
        lossEvidenceRecordedAt         = ''
        bindingRevision                = 0
        bindingVersion                 = "$SchemaVersion"
        previousDeepSeekSessionId     = ''
        previousTargetUrl             = ''
        previousModel                 = ''
        previousReasoning             = ''
        previousConversationUrl       = ''
        previousDomMessageMarker      = ''
        previousExpectedMessageMarker = ''
        previousBrowserSurface        = ''
        previousBrowserTabId          = ''
        previousBrowserRuntimeId      = ''
        previousRuntimeEpoch          = ''
        previousAuditRisk             = $false
        previousAuditRiskReason       = ''
        previousPendingReceipt        = $false
        previousLastReceiptStatus     = ''
        previousSendAudit             = @()
        previousCancelledPendingAudit = $false
        replacementAudit              = $false
        replacementReason             = ''
        sessionLostAt                 = ''
        browserMigrationReason        = ''
        browserMigratedAt             = ''
        cancelledAt                   = ''
        cancelReason                  = ''
        cancelledPendingAudit         = $false
        replacementRequired           = $false
    }
    foreach ($entry in $defaults.GetEnumerator()) {
        if ($null -eq $Binding.PSObject.Properties[$entry.Key] -or $null -eq $Binding.($entry.Key)) {
            SetProp $Binding $entry.Key $entry.Value
        }
    }
}

function Get-Bindings {
    $registry = Read-Json $BindingPath ([pscustomobject]@{
            version  = $SchemaVersion
            bindings = @()
        })
    $items = @($registry.bindings)
    foreach ($binding in $items) {
        Init-Binding $binding
    }
    return $items
}

function Sync-TaskStateFromBinding([object]$Binding) {
    if (
        $null -eq $Binding -or
        [string]::IsNullOrWhiteSpace((Text $TaskId))
    ) {
        return
    }
    $taskPath = Join-Path $StateDir "$TaskId.json"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        return
    }

    $stateMutex = [Threading.Mutex]::new($false, $StateMutexName)
    $stateOwned = $false
    try {
        try {
            $stateOwned = $stateMutex.WaitOne(10000)
        }
        catch [Threading.AbandonedMutexException] {
            $stateOwned = $true
        }
        if (-not $stateOwned) {
            throw '绑定已写入，但无法取得任务状态锁进行同步。'
        }

        $state = Read-Json $taskPath @{}
        if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
            throw '绑定与任务状态的 Codex thread 不一致。'
        }

        foreach ($legacy in @(
                @{ Current = 'targetUrl'; Previous = 'legacyTargetUrl'; Expected = $TargetUrl },
                @{ Current = 'model'; Previous = 'legacyModel'; Expected = $TargetModel },
                @{ Current = 'reasoning'; Previous = 'legacyReasoning'; Expected = $TargetReasoning }
            )) {
            $old = Prop $state $legacy.Current
            if (
                -not [string]::IsNullOrWhiteSpace($old) -and
                $old -ne $legacy.Expected -and
                [string]::IsNullOrWhiteSpace((Prop $state $legacy.Previous))
            ) {
                SetProp $state $legacy.Previous $old
            }
        }

        SetProp $state 'targetUrl' $TargetUrl
        SetProp $state 'model' $TargetModel
        SetProp $state 'reasoning' $TargetReasoning
        SetProp $state 'searchMode' $TargetSearch
        SetProp $state 'sessionOwner' $CodexThreadId
        $bindingSessionId = Prop $Binding 'deepseekSessionId'
        if (
            -not [string]::IsNullOrWhiteSpace($bindingSessionId) -and
            $bindingSessionId -notmatch '^(official-chat|official-marker):'
        ) {
            if ([string]::IsNullOrWhiteSpace((Prop $state 'legacyDeepSeekSessionId'))) {
                SetProp $state 'legacyDeepSeekSessionId' $bindingSessionId
            }
            $bindingSessionId = ''
        }
        SetProp $state 'deepseekSessionId' $bindingSessionId
        SetProp $state 'deepseekSessionTitle' (Prop $Binding 'deepseekSessionTitle')
        SetProp $state 'browserTabId' (Prop $Binding 'browserTabId')
        SetProp $state 'browserTabTitle' (Prop $Binding 'browserTabTitle')
        SetProp $state 'browserSurface' (Prop $Binding 'browserSurface')
        SetProp $state 'browserTabIdentityScope' (Prop $Binding 'browserTabIdentityScope')
        SetProp $state 'browserRuntimeId' (Prop $Binding 'browserRuntimeId')
        SetProp $state 'runtimeEpoch' (Prop $Binding 'runtimeEpoch')
        SetProp $state 'bindingRevision' (Prop $Binding 'bindingRevision')
        SetProp $state 'tabMatchCount' (Prop $Binding 'tabMatchCount')
        SetProp $state 'evidenceSource' (Prop $Binding 'evidenceSource')
        SetProp $state 'domSessionTitle' (Prop $Binding 'domSessionTitle')
        SetProp $state 'domMessageMarker' (Prop $Binding 'domMessageMarker')
        SetProp $state 'bindingConfidence' (Prop $Binding 'bindingConfidence')
        SetProp $state 'sessionBindingStatus' (Prop $Binding 'status')
        $bindingConversationUrl = Prop $Binding 'conversationUrl'
        if (
            -not [string]::IsNullOrWhiteSpace($bindingConversationUrl) -and
            -not (IsTargetUrl $bindingConversationUrl)
        ) {
            if ([string]::IsNullOrWhiteSpace((Prop $state 'legacyConversationUrl'))) {
                SetProp $state 'legacyConversationUrl' $bindingConversationUrl
            }
            $bindingConversationUrl = ''
        }
        SetProp $state 'conversationUrl' $bindingConversationUrl
        SetProp $state 'pendingReceipt' ([string](BoolProp $Binding 'pendingReceipt')).ToLowerInvariant()
        SetProp $state 'sendPhase' (Prop $Binding 'sendPhase')
        SetProp $state 'sendOwnerTaskId' (Prop $Binding 'sendOwnerTaskId')
        SetProp $state 'sendIdempotencyKey' (Prop $Binding 'sendIdempotencyKey')
        SetProp $state 'lastMessageFingerprint' (Prop $Binding 'lastMessageFingerprint')
        SetProp $state 'lastReceiptStatus' (Prop $Binding 'lastReceiptStatus')
        SetProp $state 'lastOpenTabsEvidence' (Prop $Binding 'lastOpenTabsEvidence')
        SetProp $state 'lastTabsListEvidence' (Prop $Binding 'lastTabsListEvidence')
        SetProp $state 'lastReceiptEvidenceAt' (Prop $Binding 'lastReceiptEvidenceAt')
        SetProp $state 'resendBlocked' ([string](BoolProp $Binding 'resendBlocked')).ToLowerInvariant()
        SetProp $state 'sendAttemptId' (Prop $Binding 'sendAttemptId')
        SetProp $state 'browserConfirmationRequired' ([string](BoolProp $Binding 'browserConfirmationRequired')).ToLowerInvariant()
        SetProp $state 'browserConfirmationStatus' (Prop $Binding 'browserConfirmationStatus')
        SetProp $state 'confirmationSource' (Prop $Binding 'confirmationSource')
        SetProp $state 'confirmationContextHash' (Prop $Binding 'confirmationContextHash')
        SetProp $state 'browserConfirmationAt' (Prop $Binding 'browserConfirmationAt')
        SetProp $state 'browserConfirmationEvidence' (Prop $Binding 'browserConfirmationEvidence')
        SetProp $state 'messageReadyAt' (Prop $Binding 'messageReadyAt')
        SetProp $state 'browserVerifiedAt' (Prop $Binding 'browserVerifiedAt')
        SetProp $state 'confirmationRequestedAt' (Prop $Binding 'confirmationRequestedAt')
        SetProp $state 'browserActionAt' (Prop $Binding 'browserActionAt')
        SetProp $state 'browserActionEvidence' (Prop $Binding 'browserActionEvidence')
        SetProp $state 'browserEvidenceCapturedAt' (Prop $Binding 'browserEvidenceCapturedAt')
        SetProp $state 'sendPageVerifiedAt' (Prop $Binding 'sendPageVerifiedAt')
        SetProp $state 'receiptAt' (Prop $Binding 'receiptAt')
        SetProp $state 'submissionMechanism' (Prop $Binding 'submissionMechanism')
        SetProp $state 'submissionStatus' (Prop $Binding 'submissionStatus')
        SetProp $state 'domInputPresence' (Prop $Binding 'domInputPresence')
        SetProp $state 'domInputEnabled' (Prop $Binding 'domInputEnabled')
        SetProp $state 'domSendControl' (Prop $Binding 'domSendControl')
        SetProp $state 'deadlineStartedAt' (Prop $Binding 'deadlineStartedAt')
        SetProp $state 'sendDeadlineAt' (Prop $Binding 'sendDeadlineAt')
        SetProp $state 'sendRetryCount' (Prop $Binding 'sendRetryCount')
        SetProp $state 'maxSendRetries' (Prop $Binding 'maxSendRetries')
        SetProp $state 'lastRetryAt' (Prop $Binding 'lastRetryAt')
        SetProp $state 'domMessagePresence' (Prop $Binding 'domMessagePresence')
        SetProp $state 'retryExhausted' ([string](BoolProp $Binding 'retryExhausted')).ToLowerInvariant()
        SetProp $state 'browserTool' (Prop $Binding 'browserTool')
        SetProp $state 'browserToolStatus' (Prop $Binding 'browserToolStatus')
        SetProp $state 'browserToolCallId' (Prop $Binding 'browserToolCallId')
        SetProp $state 'browserToolFailureCount' (Prop $Binding 'browserToolFailureCount')
        SetProp $state 'browserToolFailureReason' (Prop $Binding 'browserToolFailureReason')
        SetProp $state 'lastBrowserToolAt' (Prop $Binding 'lastBrowserToolAt')
        SetProp $state 'browserEvidenceStatus' (Prop $Binding 'browserEvidenceStatus')
        SetProp $state 'lossEvidence' (Prop $Binding 'lossEvidence')
        SetProp $state 'lossEvidenceSources' (Prop $Binding 'lossEvidenceSources')
        SetProp $state 'lossObservationCount' (Prop $Binding 'lossObservationCount')
        SetProp $state 'lossObservationWindowSeconds' (Prop $Binding 'lossObservationWindowSeconds')
        SetProp $state 'auditRisk' ([string](BoolProp $Binding 'auditRisk')).ToLowerInvariant()
        SetProp $state 'replacementAudit' ([string](BoolProp $Binding 'replacementAudit')).ToLowerInvariant()
        SetProp $state 'previousPendingReceipt' ([string](BoolProp $Binding 'previousPendingReceipt')).ToLowerInvariant()
        SetProp $state 'previousLastReceiptStatus' (Prop $Binding 'previousLastReceiptStatus')
        SetProp $state 'previousAuditRisk' ([string](BoolProp $Binding 'previousAuditRisk')).ToLowerInvariant()
        SetProp $state 'previousAuditRiskReason' (Prop $Binding 'previousAuditRiskReason')
        SetProp $state 'previousSendAudit' @($Binding.previousSendAudit)
        $sessionLostValue = ''
        if ((Prop $Binding 'status') -eq 'lost') {
            $sessionLostValue = Prop $Binding 'replacementReason'
        }
        SetProp $state 'sessionLost' $sessionLostValue

        $localSessionValue = '官网会话待重新绑定'
        if ((Prop $Binding 'status') -eq 'bound') {
            $localSessionValue = '已绑定 Codex 右侧栏 DeepSeek 官网专用会话'
        }
        elseif ((Prop $Binding 'status') -eq 'bootstrap-pending') {
            $localSessionValue = '官网会话正在首次绑定'
        }
        SetProp $state 'localDeepSeekSession' $localSessionValue
        SetProp $state 'updatedAt' (Get-Date).ToString('o')
        Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
    }
    finally {
        if ($stateOwned) {
            try {
                $stateMutex.ReleaseMutex() | Out-Null
            }
            catch {
            }
        }
        $stateMutex.Dispose()
    }
}

function Save-Bindings([object[]]$Bindings) {
    $currentCandidates = @(
        $Bindings |
            Where-Object { (Prop $_ 'codexThreadId') -eq $CodexThreadId }
    )
    if ($currentCandidates.Count -gt 1) {
        throw '同一 Codex thread 出现多个绑定，拒绝写入和同步任务状态。'
    }
    $current = $null
    if (
        $currentCandidates.Count -eq 1 -and
        (ActiveTask $currentCandidates[0]) -eq (Text $TaskId)
    ) {
        $current = $currentCandidates[0]
    }
    Write-JsonAtomic $BindingPath ([ordered]@{
            version   = $SchemaVersion
            updatedAt = (Get-Date).ToString('o')
            bindings  = @($Bindings)
        })
    Sync-TaskStateFromBinding $current
}

function Current-Binding([object[]]$Bindings) {
    $items = @($Bindings | Where-Object { (Prop $_ 'codexThreadId') -eq $CodexThreadId })
    if ($items.Count -gt 1) {
        throw '同一 Codex thread 出现多个绑定，拒绝猜测。'
    }
    if ($items.Count -eq 0) {
        return $null
    }
    return $items[0]
}

function ActiveTask([object]$Binding) {
    $activeTask = Prop $Binding 'activeTaskId'
    if ([string]::IsNullOrWhiteSpace($activeTask)) {
        return Prop $Binding 'taskId'
    }
    return $activeTask
}

function IsTaskTerminal([string]$Id) {
    if ([string]::IsNullOrWhiteSpace((Text $Id))) {
        return $true
    }
    $taskPath = Join-Path $StateDir "$Id.json"
    if (-not (Test-Path -LiteralPath $taskPath -PathType Leaf)) {
        return $false
    }
    $state = Read-Json $taskPath @{}
    return (
        (Prop $state 'taskTerminalStatus') -in @('completed', 'failed', 'cancelled', 'frozen') -or
        (Prop $state 'executionStatus') -in @('已完成', '失败', '已取消', '已冻结')
    )
}

function Add-History(
    [object]$Binding,
    [string]$OldTask,
    [string]$Status,
    [string]$Why
) {
    if ([string]::IsNullOrWhiteSpace((Text $OldTask))) {
        return
    }
    $history = @($Binding.taskHistory)
    $history += [pscustomobject][ordered]@{
        taskId     = $OldTask
        status     = $Status
        reason     = $Why
        recordedAt = (Get-Date).ToString('o')
    }
    SetProp $Binding 'taskHistory' $history
}

function Set-Active(
    [object]$Binding,
    [string]$NewTask,
    [string]$Status = 'superseded',
    [string]$Why = ''
) {
    $oldTask = ActiveTask $Binding
    if (
        -not [string]::IsNullOrWhiteSpace($oldTask) -and
        $oldTask -ne $NewTask
    ) {
        Add-History $Binding $oldTask $Status $Why
        SetProp $Binding 'previousTaskId' $oldTask
    }
    SetProp $Binding 'activeTaskId' $NewTask
    SetProp $Binding 'taskId' $NewTask
}

function Resolve-SendOwnerTaskId(
    [object]$Binding,
    [string]$FallbackTask
) {
    $owner = Prop $Binding 'sendOwnerTaskId'
    if (-not [string]::IsNullOrWhiteSpace($owner)) {
        return $owner
    }

    $fingerprint = Prop $Binding 'pendingMessageFingerprint'
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        $fingerprint = Prop $Binding 'lastMessageFingerprint'
    }
    if ([string]::IsNullOrWhiteSpace($fingerprint)) {
        if (-not [string]::IsNullOrWhiteSpace((Text $FallbackTask))) {
            return Text $FallbackTask
        }
        return 'unknown'
    }

    $directCandidates = @(
        (Text $FallbackTask),
        (Prop $Binding 'previousTaskId'),
        (ActiveTask $Binding)
    ) | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'unknown'
    } | Select-Object -Unique
    foreach ($candidateTaskId in $directCandidates) {
        $candidatePath = Join-Path $StateDir "$candidateTaskId.json"
        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            continue
        }
        try {
            $candidate = Read-Json $candidatePath $null
            if (
                $null -ne $candidate -and
                (Prop $candidate 'codexThreadId') -eq $CodexThreadId -and
                (
                    (Prop $candidate 'lastMessageFingerprint') -eq $fingerprint -or
                    (Prop $candidate 'pendingMessageFingerprint') -eq $fingerprint -or
                    (Prop $candidate 'authorizedMessageFingerprint') -eq $fingerprint
                )
            ) {
                return $candidateTaskId
            }
        }
        catch {
        }
    }

    $auditOwners = @(
        @($Binding.previousSendAudit) | Where-Object {
            (Prop $_ 'pendingMessageFingerprint') -eq $fingerprint -or
            (Prop $_ 'lastMessageFingerprint') -eq $fingerprint -or
            (Prop $_ 'authorizedMessageFingerprint') -eq $fingerprint
        } | ForEach-Object {
            $candidateTask = Prop $_ 'sourceTaskId'
            if ([string]::IsNullOrWhiteSpace($candidateTask)) {
                $candidateTask = Prop $_ 'taskId'
            }
            $candidateTask
        } | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'unknown'
        } | Sort-Object -Unique
    )
    if ($auditOwners.Count -eq 1) {
        return $auditOwners[0]
    }

    $matches = @(
        Get-ChildItem -LiteralPath $StateDir -File -Filter '*.json' -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -notin @('thread-bindings.json', 'browser-lease.json', 'browser-lease-epoch.json') -and
                $_.Name -notlike 'workflow-transaction.*'
            } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 200 |
            ForEach-Object {
                try {
                    $candidate = Read-Json $_.FullName $null
                    if (
                        $null -ne $candidate -and
                        (Prop $candidate 'codexThreadId') -eq $CodexThreadId -and
                        (
                            (Prop $candidate 'lastMessageFingerprint') -eq $fingerprint -or
                            (Prop $candidate 'pendingMessageFingerprint') -eq $fingerprint -or
                            (Prop $candidate 'authorizedMessageFingerprint') -eq $fingerprint
                        )
                    ) {
                        $candidateTask = Prop $candidate 'taskId'
                        if (-not [string]::IsNullOrWhiteSpace($candidateTask)) {
                            $candidateTask
                        }
                    }
                }
                catch {
                    # 历史状态损坏不能让 Claim 接管错误 Task；忽略该文件并保留 unknown。
                }
            } |
            Sort-Object -Unique
    )
    if ($matches.Count -eq 1) {
        return $matches[0]
    }
    return 'unknown'
}

function PreviousAuditContainsFingerprint(
    [object]$Binding,
    [string]$Fingerprint
) {
    if ([string]::IsNullOrWhiteSpace((Text $Fingerprint))) {
        return $false
    }
    foreach ($entry in @($Binding.previousSendAudit)) {
        if (
            (Prop $entry 'pendingMessageFingerprint') -eq (Text $Fingerprint) -or
            (Prop $entry 'lastMessageFingerprint') -eq (Text $Fingerprint) -or
            (Prop $entry 'authorizedMessageFingerprint') -eq (Text $Fingerprint)
        ) {
            return $true
        }
    }
    return $false
}

function Reset-TaskScopedSendState(
    [object]$Binding,
    [string]$OldTask,
    [string]$Why
) {
    $hadAuditState = (
        (BoolProp $Binding 'pendingReceipt') -or
        (BoolProp $Binding 'auditRisk') -or
        (BoolProp $Binding 'resendBlocked') -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'lastReceiptStatus')) -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'lastMessageFingerprint')) -or
        (LongProp $Binding 'browserRecoveryCount') -gt 0
    )
    $sourceTaskId = Resolve-SendOwnerTaskId $Binding $OldTask
    $capturedAt = (Get-Date).ToString('o')
    $auditEntry = [ordered]@{
        schemaVersion          = 1
        taskId                 = $sourceTaskId
        sourceTaskId           = $sourceTaskId
        capturedAt             = $capturedAt
        pendingReceipt         = [bool](BoolProp $Binding 'pendingReceipt')
        pendingMessageFingerprint = (Prop $Binding 'pendingMessageFingerprint')
        authorizedMessageFingerprint = (Prop $Binding 'authorizedMessageFingerprint')
        lastMessageFingerprint = (Prop $Binding 'lastMessageFingerprint')
        lastReceiptStatus      = (Prop $Binding 'lastReceiptStatus')
        auditRisk              = [bool](BoolProp $Binding 'auditRisk')
        auditRiskReason        = (Prop $Binding 'auditRiskReason')
        resendBlocked          = [bool](BoolProp $Binding 'resendBlocked')
        sendIdempotencyKey     = (Prop $Binding 'sendIdempotencyKey')
        sendAttemptId          = (Prop $Binding 'sendAttemptId')
        sendPhase              = (Prop $Binding 'sendPhase')
        retryHistory           = @($Binding.retryHistory)
        sendRetryCount         = (LongProp $Binding 'sendRetryCount')
        maxSendRetries         = (LongProp $Binding 'maxSendRetries' 2)
        lastRetryAt            = (Prop $Binding 'lastRetryAt')
        retryExhausted         = [bool](BoolProp $Binding 'retryExhausted')
        lastOpenTabsEvidence   = (Prop $Binding 'lastOpenTabsEvidence')
        lastTabsListEvidence   = (Prop $Binding 'lastTabsListEvidence')
        lastReceiptEvidenceAt  = (Prop $Binding 'lastReceiptEvidenceAt')
        browserConfirmationRequired = [bool](BoolProp $Binding 'browserConfirmationRequired')
        browserConfirmationStatus = (Prop $Binding 'browserConfirmationStatus')
        confirmationSource     = (Prop $Binding 'confirmationSource')
        confirmationContextHash = (Prop $Binding 'confirmationContextHash')
        browserConfirmationAt  = (Prop $Binding 'browserConfirmationAt')
        browserConfirmationEvidence = (Prop $Binding 'browserConfirmationEvidence')
        deadlineStartedAt      = (Prop $Binding 'deadlineStartedAt')
        sendDeadlineAt         = (Prop $Binding 'sendDeadlineAt')
        sendPreparedAt         = (Prop $Binding 'sendPreparedAt')
        messageReadyAt         = (Prop $Binding 'messageReadyAt')
        browserVerifiedAt      = (Prop $Binding 'browserVerifiedAt')
        confirmationRequestedAt = (Prop $Binding 'confirmationRequestedAt')
        browserActionAt        = (Prop $Binding 'browserActionAt')
        browserActionEvidence  = (Prop $Binding 'browserActionEvidence')
        browserEvidenceCapturedAt = (Prop $Binding 'browserEvidenceCapturedAt')
        sendPageVerifiedAt = (Prop $Binding 'sendPageVerifiedAt')
        receiptAt              = (Prop $Binding 'receiptAt')
        submissionMechanism    = (Prop $Binding 'submissionMechanism')
        submissionStatus       = (Prop $Binding 'submissionStatus')
        domInputPresence       = (Prop $Binding 'domInputPresence')
        domInputEnabled        = (Prop $Binding 'domInputEnabled')
        domSendControl         = (Prop $Binding 'domSendControl')
        domMessagePresence     = (Prop $Binding 'domMessagePresence')
        browserToolStatus      = (Prop $Binding 'browserToolStatus')
        browserToolFailureCount = (LongProp $Binding 'browserToolFailureCount')
        browserToolFailureReason = (Prop $Binding 'browserToolFailureReason')
        browserRecoveryCount   = (LongProp $Binding 'browserRecoveryCount')
        browserRecoveryStatus  = (Prop $Binding 'browserRecoveryStatus')
        browserRecoveryTaskId  = (Prop $Binding 'browserRecoveryTaskId')
        lossEvidence           = (Prop $Binding 'lossEvidence')
        lossEvidenceSources    = (Prop $Binding 'lossEvidenceSources')
        lossObservationCount   = (LongProp $Binding 'lossObservationCount')
        lossObservationWindowSeconds = (LongProp $Binding 'lossObservationWindowSeconds')
        recordedAt             = $capturedAt
        reason                 = (Text $Why)
    }
    $auditHistory = @($Binding.previousSendAudit)
    if (-not [string]::IsNullOrWhiteSpace((Text $OldTask)) -and $hadAuditState) {
        $auditHistory += [pscustomobject]$auditEntry
    }
    SetProp $Binding 'previousSendAudit' $auditHistory
    SetProp $Binding 'previousPendingReceipt' (BoolProp $Binding 'pendingReceipt')
    SetProp $Binding 'previousLastReceiptStatus' (Prop $Binding 'lastReceiptStatus')
    SetProp $Binding 'previousAuditRisk' (BoolProp $Binding 'auditRisk')
    SetProp $Binding 'previousAuditRiskReason' (Prop $Binding 'auditRiskReason')
    SetProp $Binding 'replacementAudit' $hadAuditState
    if ($hadAuditState) {
        SetProp $Binding 'replacementReason' (
            "新 Task 复用同一官网会话；旧 Task 的 pendingReceipt/auditRisk 已移入 previousSendAudit，不能阻塞新评审消息。$(Text $Why)"
        ).Trim()
    }

    SetProp $Binding 'pendingReceipt' $false
    SetProp $Binding 'sendPhase' ''
    SetProp $Binding 'retryHistory' @()
    SetProp $Binding 'sendRetryCount' 0
    SetProp $Binding 'lossObservationCount' 0
    SetProp $Binding 'lossObservationWindowSeconds' 0
    SetProp $Binding 'browserToolFailureCount' 0
    SetProp $Binding 'browserRecoveryCount' 0
    SetProp $Binding 'browserRecoveryStatus' ''
    SetProp $Binding 'browserRecoveryTaskId' (Text $TaskId)
    SetProp $Binding 'browserFailureClass' ''
    foreach ($field in @(
            'pendingMessageFingerprint',
            'authorizedMessageFingerprint',
            'sendOwnerTaskId',
            'sendIdempotencyKey',
            'sendAttemptId',
            'lastMessageFingerprint',
            'lastReceiptStatus',
             'lastOpenTabsEvidence',
             'lastTabsListEvidence',
             'lastReceiptEvidenceAt',
             'receiptRecordedAt',
             'sendDeadlineAt',
             'lastRetryAt',
             'browserConfirmationAt',
             'browserConfirmationEvidence',
             'confirmationSource',
             'confirmationContextHash',
             'deadlineStartedAt',
             'sendPreparedAt',
             'messageReadyAt',
             'browserVerifiedAt',
             'confirmationRequestedAt',
             'browserActionAt',
             'browserActionEvidence',
             'browserEvidenceCapturedAt',
             'sendPageVerifiedAt',
             'receiptAt',
             'submissionMechanism',
             'submissionStatus',
             'domInputPresence',
             'domInputEnabled',
             'domSendControl',
             'domMessagePresence',
             'lastBrowserToolAt',
             'browserToolCallId',
             'browserToolFailureReason',
             'lossEvidence',
             'lossEvidenceSources',
             'lossEvidenceRecordedAt'
         )) {
         SetProp $Binding $field ''
     }
    SetProp $Binding 'resendBlocked' $false
    SetProp $Binding 'auditRisk' $false
    SetProp $Binding 'auditRiskReason' ''
    SetProp $Binding 'retryExhausted' $false
     SetProp $Binding 'browserConfirmationRequired' $false
     SetProp $Binding 'browserConfirmationStatus' ''
     SetProp $Binding 'browserToolStatus' 'not-started'
     SetProp $Binding 'browserToolFailureCount' 0
 }

function Rev([object]$Binding) {
    $nextRevision = (LongProp $Binding 'bindingRevision') + 1
    SetProp $Binding 'bindingRevision' $nextRevision
    SetProp $Binding 'bindingVersion' "$SchemaVersion"
    SetProp $Binding 'updatedAt' (Get-Date).ToString('o')
}

# Repair only a legacy Claim that has not started any browser/send work in this task.
# An actual recovery sets available/recovered; failures have lastBrowserToolAt.
function Repair-InheritedRecoveryBudget([object]$Binding) {
    $previousTask = Prop $Binding 'previousTaskId'
    if ((Prop $Binding 'status') -ne 'bound' -or
        (ActiveTask $Binding) -ne (Text $TaskId) -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'browserRecoveryTaskId')) -or
        [string]::IsNullOrWhiteSpace($previousTask) -or $previousTask -eq (Text $TaskId) -or
        -not (IsTaskTerminal $previousTask) -or
        (Prop $Binding 'browserToolStatus') -ne 'not-started' -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'lastBrowserToolAt')) -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'sendPhase')) -or
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'lastMessageFingerprint')) -or
        (BoolProp $Binding 'pendingReceipt') -or (BoolProp $Binding 'auditRisk') -or
        (LongProp $Binding 'browserRecoveryCount') -lt 1) { return }
    $audit = @($Binding.previousRecoveryAudit) + @([pscustomobject]@{
        taskId = $previousTask; capturedAt = (Get-Date).ToString('o')
        browserRecoveryCount = (LongProp $Binding 'browserRecoveryCount')
        browserRecoveryStatus = (Prop $Binding 'browserRecoveryStatus')
        reason = 'legacy-claim-inherited-recovery-budget'
    })
    SetProp $Binding 'previousRecoveryAudit' $audit
    SetProp $Binding 'browserRecoveryCount' 0
    SetProp $Binding 'browserRecoveryStatus' ''
    SetProp $Binding 'browserRecoveryTaskId' (Text $TaskId)
}

function IsInactiveBinding([object]$Binding) {
    return (Prop $Binding 'status') -in @('lost', 'cancelled', 'terminated')
}

function Assert-Unique(
    [object[]]$Bindings,
    [string]$Session,
    [string]$Tab,
    [object]$Current
) {
    $sessionValue = Text $Session
    $tabValue = Text $Tab
    $runtimeValue = Text $BrowserRuntimeId
    $markerValue = MarkerValue

    foreach ($binding in $Bindings) {
        if (
            $null -ne $Current -and
            [object]::ReferenceEquals($binding, $Current)
        ) {
            continue
        }
        if (IsInactiveBinding $binding) {
            continue
        }
        if ((Prop $binding 'codexThreadId') -eq $CodexThreadId) {
            continue
        }

        if (
            -not [string]::IsNullOrWhiteSpace($sessionValue) -and
            (Prop $binding 'deepseekSessionId') -eq $sessionValue
        ) {
            throw '本机会话已属于另一个 Codex thread。'
        }

        $existingTab = Prop $binding 'browserTabId'
        if (-not [string]::IsNullOrWhiteSpace($tabValue) -and $existingTab -eq $tabValue) {
            $existingRuntime = Prop $binding 'browserRuntimeId'
            if (
                [string]::IsNullOrWhiteSpace($existingRuntime) -or
                [string]::IsNullOrWhiteSpace($runtimeValue)
            ) {
                throw '右侧栏 tab ID 已被其他 thread 占用，但 runtime 不完整，拒绝猜测归属。'
            }
            if ($existingRuntime -eq $runtimeValue) {
                throw '右侧栏 runtime + tab 已属于另一个 Codex thread。'
            }
            throw '同一个右侧栏 tab ID 在不同 runtime 中出现跨 thread 冲突，必须换用有唯一证据的 tab。'
        }

        $existingRuntime = Prop $binding 'browserRuntimeId'
        if (
            -not [string]::IsNullOrWhiteSpace($existingRuntime) -and
            $existingRuntime -eq $runtimeValue -and
            [string]::IsNullOrWhiteSpace($existingTab)
        ) {
            throw '另一个 Codex thread 已占用当前 runtime，但没有完整 tab 证据。'
        }

        $existingMarker = Prop $binding 'expectedMessageMarker'
        if ([string]::IsNullOrWhiteSpace($existingMarker)) {
            $existingMarker = Prop $binding 'domMessageMarker'
        }
        if (
            -not [string]::IsNullOrWhiteSpace($markerValue) -and
            $existingMarker -eq $markerValue
        ) {
            throw '当前 thread marker 已属于另一个 Codex thread。'
        }
    }
}

function Assert-Local([object]$Binding) {
    if (
        (Prop $Binding 'targetUrl') -ne $TargetUrl -or
        (Prop $Binding 'model') -notin @($TargetModel, '专家模式')
    ) {
        throw '当前绑定不是已核验的 DeepSeek 官网会话，不能直接复用。'
    }
    $sessionId = Prop $Binding 'deepseekSessionId'
    if (
        -not [string]::IsNullOrWhiteSpace($sessionId) -and
        $sessionId -notmatch '^(official-chat|official-marker):'
    ) {
        throw '当前绑定残留不受支持的 sessionId，必须 MarkLost 后重新 bootstrap。'
    }
    $conversationUrl = Prop $Binding 'conversationUrl'
    if (
        -not [string]::IsNullOrWhiteSpace($conversationUrl) -and
        -not (IsTargetUrl $conversationUrl)
    ) {
        throw '当前绑定残留不受支持的 conversationUrl，必须 MarkLost 后重新 bootstrap。'
    }
}

function Test-ObsoleteBinding([object]$Binding) {
    $reasons = @()
    if ((Prop $Binding 'targetUrl') -ne $TargetUrl) {
        $reasons += '绑定仍残留旧入口'
    }
    if ((Prop $Binding 'model') -ne $TargetModel) {
        $reasons += '绑定仍残留旧模型'
    }
    if ((Prop $Binding 'reasoning') -ne $TargetReasoning) {
        $reasons += '绑定仍残留旧推理等级'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'conversationUrl')) -and
        -not (IsTargetUrl (Prop $Binding 'conversationUrl'))
    ) {
        $reasons += '绑定 conversationUrl 不是官网地址'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'deepseekSessionId')) -and
        (Prop $Binding 'deepseekSessionId') -notmatch '^(official-chat|official-marker):'
    ) {
        $reasons += '绑定 sessionId 不是官网会话'
    }
    return [pscustomobject][ordered]@{
        obsolete = ($reasons.Count -gt 0)
        reasons  = @($reasons)
    }
}

function Repair-ObsoleteBinding(
    [object]$Binding,
    [string]$Why
) {
    $check = Test-ObsoleteBinding $Binding
    if (-not $check.obsolete) {
        return $false
    }

    $oldPending = BoolProp $Binding 'pendingReceipt'
    $oldAudit = BoolProp $Binding 'auditRisk'
    $oldReceipt = Prop $Binding 'lastReceiptStatus'
    $uncertain = (
        $oldPending -or
        $oldAudit -or
        $oldReceipt -in @('unknown', 'wrong-session', 'not-found') -or
        (BoolProp $Binding 'cancelledPendingAudit')
    )
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'targetUrl')) -and
        (Prop $Binding 'targetUrl') -ne $TargetUrl
    ) {
        SetProp $Binding 'previousTargetUrl' (Prop $Binding 'targetUrl')
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'model')) -and
        (Prop $Binding 'model') -ne $TargetModel
    ) {
        SetProp $Binding 'previousModel' (Prop $Binding 'model')
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'reasoning')) -and
        (Prop $Binding 'reasoning') -ne $TargetReasoning
    ) {
        SetProp $Binding 'previousReasoning' (Prop $Binding 'reasoning')
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'conversationUrl')) -and
        [string]::IsNullOrWhiteSpace((Prop $Binding 'previousConversationUrl'))
    ) {
        SetProp $Binding 'previousConversationUrl' (Prop $Binding 'conversationUrl')
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'deepseekSessionId')) -and
        [string]::IsNullOrWhiteSpace((Prop $Binding 'previousDeepSeekSessionId'))
    ) {
        SetProp $Binding 'previousDeepSeekSessionId' (Prop $Binding 'deepseekSessionId')
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Prop $Binding 'browserSurface')) -and
        (Prop $Binding 'browserSurface') -ne $TargetBrowserSurface -and
        [string]::IsNullOrWhiteSpace((Prop $Binding 'previousBrowserSurface'))
    ) {
        SetProp $Binding 'previousBrowserSurface' (Prop $Binding 'browserSurface')
    }

    SetProp $Binding 'targetUrl' $TargetUrl
    SetProp $Binding 'model' $TargetModel
    SetProp $Binding 'reasoning' $TargetReasoning
    SetProp $Binding 'searchMode' $TargetSearch
    SetProp $Binding 'conversationUrl' ''
    SetProp $Binding 'deepseekSessionId' ''
    SetProp $Binding 'deepseekSessionTitle' ''
    SetProp $Binding 'domSessionTitle' ''
    SetProp $Binding 'domMessageMarker' ''
    SetProp $Binding 'expectedMessageMarker' ''
    SetProp $Binding 'browserTabId' ''
    SetProp $Binding 'browserTabTitle' ''
    SetProp $Binding 'browserRuntimeId' ''
    SetProp $Binding 'runtimeEpoch' 0
    SetProp $Binding 'tabMatchCount' 0
    SetProp $Binding 'bindingConfidence' 'bootstrap-pending'
    SetProp $Binding 'evidenceSource' ''
    SetProp $Binding 'status' 'lost'
    SetProp $Binding 'sessionLostAt' (Get-Date).ToString('o')
    SetProp $Binding 'replacementRequired' $true
    SetProp $Binding 'replacementReason' (
        "自动隔离旧绑定：$((@($check.reasons) -join '、'))。$(Text $Why)"
    ).Trim()
    SetProp $Binding 'resendBlocked' $true
    SetProp $Binding 'auditRisk' $uncertain
    SetProp $Binding 'cancelledPendingAudit' $uncertain
    if ($uncertain) {
        SetProp $Binding 'auditRiskReason' '旧绑定含未确认回执或历史风险，已隔离；新会话不能继承旧消息。'
    }
    else {
        SetProp $Binding 'auditRiskReason' ''
        SetProp $Binding 'pendingReceipt' $false
        SetProp $Binding 'pendingMessageFingerprint' ''
        SetProp $Binding 'authorizedMessageFingerprint' ''
        SetProp $Binding 'sendAttemptId' ''
    }
    Rev $Binding
    return $true
}

function Reset-ActiveIdentityForReplacement(
    [object]$Binding,
    [string]$Why
) {
    foreach ($pair in @(
            @{ Current = 'deepseekSessionId'; Previous = 'previousDeepSeekSessionId' },
            @{ Current = 'browserSurface'; Previous = 'previousBrowserSurface' },
            @{ Current = 'browserTabId'; Previous = 'previousBrowserTabId' },
            @{ Current = 'browserRuntimeId'; Previous = 'previousBrowserRuntimeId' },
            @{ Current = 'runtimeEpoch'; Previous = 'previousRuntimeEpoch' },
            @{ Current = 'conversationUrl'; Previous = 'previousConversationUrl' },
            @{ Current = 'domMessageMarker'; Previous = 'previousDomMessageMarker' },
            @{ Current = 'expectedMessageMarker'; Previous = 'previousExpectedMessageMarker' }
        )) {
        $value = Prop $Binding $pair.Current
        if (
            -not [string]::IsNullOrWhiteSpace($value) -and
            [string]::IsNullOrWhiteSpace((Prop $Binding $pair.Previous))
        ) {
            SetProp $Binding $pair.Previous $value
        }
    }

    foreach ($field in @(
            'deepseekSessionId',
            'deepseekSessionTitle',
            'browserTabId',
            'browserTabTitle',
            'browserRuntimeId',
            'conversationUrl',
            'domSessionTitle',
            'domMessageMarker',
            'expectedMessageMarker',
            'evidenceSource',
            'sendIdempotencyKey'
        )) {
        SetProp $Binding $field ''
    }
    SetProp $Binding 'runtimeEpoch' 0
    SetProp $Binding 'tabMatchCount' 0
    SetProp $Binding 'bindingConfidence' 'bootstrap-pending'
    SetProp $Binding 'sendDeadlineAt' ''
    SetProp $Binding 'sendRetryCount' 0
    SetProp $Binding 'lastRetryAt' ''
    SetProp $Binding 'retryHistory' @()
    SetProp $Binding 'domMessagePresence' ''
    SetProp $Binding 'retryExhausted' $false
    SetProp $Binding 'lossEvidence' ''
    SetProp $Binding 'lossEvidenceSources' ''
    SetProp $Binding 'lossObservationCount' 0
    SetProp $Binding 'lossObservationWindowSeconds' 0
    SetProp $Binding 'lossEvidenceRecordedAt' ''
    SetProp $Binding 'replacementRequired' $true
    if (-not [string]::IsNullOrWhiteSpace((Text $Why))) {
        SetProp $Binding 'replacementReason' (Text $Why)
    }
}

function Assert-Binding([object]$Binding) {
    Assert-Local $Binding
    if ((Prop $Binding 'browserSurface') -ne $TargetBrowserSurface) {
        throw '当前绑定不是 Codex 右侧栏内置浏览器，禁止继续使用。'
    }
}

function Assert-CurrentBindingSurface([object]$Binding) {
    if (
        (Text $BrowserTabId) -ne (Prop $Binding 'browserTabId') -or
        (Text $BrowserRuntimeId) -ne (Prop $Binding 'browserRuntimeId') -or
        (LongProp $Binding 'runtimeEpoch') -ne $RuntimeEpoch
    ) {
        throw '当前页面 tab/runtime/epoch 与绑定不一致，禁止继续操作。'
    }
}

function Get-RecoverySummary([object]$Binding, [string]$SessionId) {
    $status = Prop $Binding 'status'
    $existingSessionId = Prop $Binding 'deepseekSessionId'
    $existingMarker = Prop $Binding 'domMessageMarker'
    $domMarker = Text $DomMessageMarker
    $sessionMatch = $SessionId -eq $existingSessionId
    $markerMatch = $domMarker -eq $existingMarker
    $tabMatch = (Prop $Binding 'browserTabId') -eq (Text $BrowserTabId)
    $runtimeMatch = (Prop $Binding 'browserRuntimeId') -eq (Text $BrowserRuntimeId)
    $oldEpoch = LongProp $Binding 'runtimeEpoch'
    $runtimeChanged = -not ($tabMatch -and $runtimeMatch)
    $runtimeEpochValid = if ($runtimeChanged) {
        $RuntimeEpoch -eq ($oldEpoch + 1)
    }
    else {
        $RuntimeEpoch -eq $oldEpoch
    }
    $safeExpiredLeaseReason = (
        "$(Prop $Binding 'auditRiskReason') $(Prop $Binding 'replacementReason')" -match '过期\s*lease|lease\s*清理'
    )
    $pendingReceipt = BoolProp $Binding 'pendingReceipt'
    $receiptConfirmed = (Prop $Binding 'lastReceiptStatus') -eq 'confirmed'
    $modelMatch = (Text $DomModel) -in @($TargetModel, '专家模式')
    $reasoningMatch = (Text $DomReasoning) -eq $TargetReasoning
    $searchMatch = (Text $DomSearch) -eq $TargetSearch
    $reasons = @()

    if ($status -ne 'lost') { $reasons += '当前绑定不是 lost 状态' }
    if (-not $safeExpiredLeaseReason) { $reasons += '丢失原因不是可安全恢复的过期 lease 清理' }
    if ($pendingReceipt) { $reasons += '仍有 pendingReceipt' }
    if (-not $receiptConfirmed) { $reasons += '上一条消息没有 confirmed 回执' }
    if (-not $sessionMatch) { $reasons += '页面 sessionId 与绑定不一致' }
    if (-not $markerMatch) { $reasons += '页面 marker 与绑定不一致' }
    if (-not $modelMatch) { $reasons += '尚未核对页面当前模型' }
    if (-not $reasoningMatch) { $reasons += '页面没有开启深度思考' }
    if (-not $searchMatch) { $reasons += '页面没有开启智能搜索' }
    if (-not $runtimeEpochValid) { $reasons += 'runtime epoch 不符合恢复规则' }

    return [pscustomobject][ordered]@{
        bindingStatus          = $status
        existingSessionId      = $existingSessionId
        domSessionId           = $SessionId
        sessionMatch           = $sessionMatch
        existingMarker         = $existingMarker
        domMarker              = $domMarker
        markerMatch            = $markerMatch
        existingTabId          = Prop $Binding 'browserTabId'
        domTabId               = Text $BrowserTabId
        tabMatch               = $tabMatch
        existingRuntimeId      = Prop $Binding 'browserRuntimeId'
        domRuntimeId            = Text $BrowserRuntimeId
        runtimeMatch           = $runtimeMatch
        runtimeEpoch           = $RuntimeEpoch
        runtimeEpochValid      = $runtimeEpochValid
        modelMatch             = $modelMatch
        reasoningMatch         = $reasoningMatch
        pendingReceipt         = $pendingReceipt
        lastReceiptStatus      = Prop $Binding 'lastReceiptStatus'
        safeExpiredLeaseReason = $safeExpiredLeaseReason
        canRecover              = (
            $status -eq 'lost' -and
            $safeExpiredLeaseReason -and
            -not $pendingReceipt -and
            $receiptConfirmed -and
            $sessionMatch -and
            $markerMatch -and
            $modelMatch -and
            $reasoningMatch -and
            $searchMatch -and
            $runtimeEpochValid
        )
        reasons                = @($reasons)
    }
}

function Get-LostBindingRecoverySummary([object]$Binding, [string]$SessionId) {
    $historicalSessionId = Text $Binding.previousDeepSeekSessionId
    $historicalConversationUrl = Text $Binding.previousConversationUrl
    if (
        [string]::IsNullOrWhiteSpace($historicalSessionId) -and
        -not [string]::IsNullOrWhiteSpace($historicalConversationUrl)
    ) {
        $historicalSessionId = SessionIdFromUrl $historicalConversationUrl
    }
    $historicalMarker = Text $Binding.previousDomMessageMarker
    if ([string]::IsNullOrWhiteSpace($historicalMarker)) {
        $historicalMarker = Text $Binding.previousExpectedMessageMarker
    }
    $sessionMatch = (
        -not [string]::IsNullOrWhiteSpace($historicalSessionId) -and
        $SessionId -eq $historicalSessionId
    )
    $markerAvailable = -not [string]::IsNullOrWhiteSpace($historicalMarker)
    $markerMatch = $markerAvailable -and (Text $DomMessageMarker) -eq $historicalMarker
    $tabMatch = (
        -not [string]::IsNullOrWhiteSpace((Text $BrowserTabId)) -and
        (Text $BrowserTabId) -eq (Text $Binding.previousBrowserTabId)
    )
    $surfaceMatch = (Text $BrowserSurface) -eq $TargetBrowserSurface
    $modelMatch = (Text $DomModel) -eq $TargetModel
    $reasoningMatch = (Text $DomReasoning) -eq $TargetReasoning
    $pendingReceipt = (
        (BoolProp $Binding 'pendingReceipt') -or
        (BoolProp $Binding 'previousPendingReceipt')
    )
    $auditRisk = (
        (BoolProp $Binding 'auditRisk') -or
        (BoolProp $Binding 'previousAuditRisk') -or
        (BoolProp $Binding 'cancelledPendingAudit')
    )
    $receiptConfirmed = (
        (Prop $Binding 'lastReceiptStatus') -eq 'confirmed' -or
        (Prop $Binding 'previousLastReceiptStatus') -eq 'confirmed'
    )
    $reasons = @()
    if ((Prop $Binding 'status') -ne 'lost') { $reasons += '当前绑定不是 lost 状态' }
    if ([string]::IsNullOrWhiteSpace($historicalSessionId)) { $reasons += '没有可核对的历史官网 session' }
    if (-not $sessionMatch) { $reasons += '当前页面 session 与历史 session 不一致' }
    if (-not $markerAvailable) { $reasons += '历史 marker 不可用，不能证明 marker 连续性' }
    elseif (-not $markerMatch) { $reasons += '当前页面 marker 与历史 marker 不一致' }
    if (-not $tabMatch) { $reasons += '当前 tab 不是历史专用 tab' }
    if (-not $surfaceMatch) { $reasons += '当前页面不是 Codex 右侧栏内置浏览器' }
    if (-not $modelMatch) { $reasons += '尚未核对页面当前模型' }
    if (-not $reasoningMatch) { $reasons += '页面没有开启深度思考' }
    if ($pendingReceipt) { $reasons += '历史或当前仍有 pendingReceipt，禁止清除和重发' }
    if ($auditRisk) { $reasons += '历史或当前存在 auditRisk，禁止静默恢复' }
    if (-not $receiptConfirmed) { $reasons += '没有 confirmed 回执，不能把找回当成安全恢复' }

    return [pscustomobject][ordered]@{
        bindingStatus            = Prop $Binding 'status'
        historicalSessionId      = $historicalSessionId
        historicalConversationUrl = $historicalConversationUrl
        currentSessionId         = $SessionId
        sessionMatch             = $sessionMatch
        historicalMarker         = $historicalMarker
        currentMarker            = Text $DomMessageMarker
        markerAvailable           = $markerAvailable
        markerMatch              = $markerMatch
        historicalTabId           = Text $Binding.previousBrowserTabId
        currentTabId              = Text $BrowserTabId
        tabMatch                 = $tabMatch
        surfaceMatch             = $surfaceMatch
        modelMatch               = $modelMatch
        reasoningMatch           = $reasoningMatch
        pendingReceipt           = $pendingReceipt
        auditRisk                = $auditRisk
        receiptConfirmed         = $receiptConfirmed
        canRecover               = (
            (Prop $Binding 'status') -eq 'lost' -and
            $sessionMatch -and
            $markerAvailable -and
            $markerMatch -and
            $tabMatch -and
            $surfaceMatch -and
            $modelMatch -and
            $reasoningMatch -and
            -not $pendingReceipt -and
            -not $auditRisk -and
            $receiptConfirmed
        )
        reasons                  = @($reasons)
    }
}

function New-Binding([string]$Status, [string]$Session = '') {
    $confidence = 'bootstrap-pending'
    if ($Status -ne 'bootstrap-pending') {
        $confidence = ConfidenceValue
    }
    return [pscustomobject][ordered]@{
        codexThreadId                 = $CodexThreadId
        owner                         = $CodexThreadId
        taskId                        = (Text $TaskId)
        activeTaskId                  = (Text $TaskId)
        taskHistory                   = @()
        deepseekSessionId             = $Session
        deepseekSessionTitle          = (Text $DeepSeekSessionTitle)
        browserTabId                 = (Text $BrowserTabId)
        browserTabTitle              = (Text $BrowserTabTitle)
        browserTabIdentityScope      = (Text $BrowserTabIdentityScope)
        browserSurface               = $TargetBrowserSurface
        browserRuntimeId             = (Text $BrowserRuntimeId)
        runtimeEpoch                 = $RuntimeEpoch
        tabMatchCount                = $TabMatchCount
        targetUrl                    = $TargetUrl
        conversationUrl              = (Text $DomTargetUrl)
        model                        = $TargetModel
        reasoning                    = (Text $DomReasoning)
        bindingConfidence            = $confidence
        evidenceSource               = (Text $EvidenceSource)
        domSessionTitle              = (Text $DomSessionTitle)
        domMessageMarker             = (MarkerValue)
        expectedMessageMarker        = (Text $ExpectedMessageMarker)
        status                       = $Status
        pendingReceipt               = $false
        sendPhase                    = ''
        pendingMessageFingerprint    = ''
        authorizedMessageFingerprint = ''
        sendAttemptId                = ''
        sendDeadlineAt               = ''
        sendRetryCount               = 0
        maxSendRetries               = 2
        lastRetryAt                  = ''
        retryHistory                 = @()
        domMessagePresence           = ''
        retryExhausted               = $false
        browserTool                  = 'mcp__cua_repl.js'
        browserToolStatus             = 'not-started'
        browserToolCallId            = ''
        browserToolFailureCount      = 0
        browserToolFailureReason     = ''
        lastBrowserToolAt             = ''
        browserEvidenceStatus        = ''
        browserActionEvidence        = ''
        browserEvidenceCapturedAt    = ''
        browserFailureClass           = ''
        browserRecoveryCount          = 0
        browserRecoveryLimit          = 1
        browserRecoveryStatus         = ''
        resendBlocked                = $false
        auditRisk                    = $false
        auditRiskReason              = ''
        lastMessageFingerprint       = ''
        lastReceiptStatus            = ''
        createdAt                    = (Get-Date).ToString('o')
        updatedAt                    = (Get-Date).ToString('o')
        bindingRevision              = 1
        bindingVersion               = "$SchemaVersion"
        previousDeepSeekSessionId    = ''
        previousTargetUrl            = ''
        previousModel                = ''
        previousReasoning            = ''
        previousConversationUrl      = ''
        previousDomMessageMarker     = ''
        previousExpectedMessageMarker = ''
        previousBrowserSurface       = ''
        previousBrowserTabId         = ''
        previousBrowserRuntimeId     = ''
        previousRuntimeEpoch         = ''
        previousAuditRisk            = $false
        previousAuditRiskReason      = ''
        previousPendingReceipt       = $false
        previousLastReceiptStatus    = ''
        previousCancelledPendingAudit = $false
        replacementAudit             = $false
        replacementReason            = ''
        sessionLostAt                = ''
        browserMigrationReason       = ''
        browserMigratedAt            = ''
        cancelledAt                  = ''
        cancelReason                 = ''
        cancelledPendingAudit        = $false
        replacementRequired          = $false
    }
}

function Get-Lease {
    $lease = Read-Json $LeasePath $null
    if ($null -ne $lease) {
        return $lease
    }

    # 兼容升级前的全局 lease：只允许当前 thread 读取自己的旧 lease，
    # 其他 thread 的旧 lease 对本 thread 不可见，不能继续造成全局阻塞。
    $legacy = Read-Json $LegacyLeasePath $null
    if (
        $null -ne $legacy -and
        (Prop $legacy 'codexThreadId') -eq $CodexThreadId
    ) {
        return $legacy
    }
    return $null
}

function Migrate-LegacyLeaseIfOwned {
    if (Test-Path -LiteralPath $LeasePath -PathType Leaf) {
        return
    }
    if (-not (Test-Path -LiteralPath $LegacyLeasePath -PathType Leaf)) {
        return
    }
    $legacy = Read-Json $LegacyLeasePath $null
    if (
        $null -ne $legacy -and
        (Prop $legacy 'codexThreadId') -eq $CodexThreadId
    ) {
        Write-JsonAtomic $LeasePath $legacy
        Remove-Item -LiteralPath $LegacyLeasePath -Force
    }
}

function Remove-LeaseFiles {
    if (Test-Path -LiteralPath $LeasePath -PathType Leaf) {
        Remove-Item -LiteralPath $LeasePath -Force
    }
    if (Test-Path -LiteralPath $LegacyLeasePath -PathType Leaf) {
        $legacy = Read-Json $LegacyLeasePath $null
        if (
            $null -ne $legacy -and
            (Prop $legacy 'codexThreadId') -eq $CodexThreadId
        ) {
            Remove-Item -LiteralPath $LegacyLeasePath -Force
        }
    }
}

function LeaseExpired([object]$Lease) {
    if ($null -eq $Lease) {
        return $true
    }
    try {
        return [datetime]::Parse((Prop $Lease 'expiresAt')) -le (Get-Date)
    }
    catch {
        return $true
    }
}

function Next-LeaseEpoch {
    $value = 0L
    if (Test-Path -LiteralPath $LeaseEpochPath) {
        $value = LongProp (Read-Json $LeaseEpochPath @{}) 'leaseEpoch'
    }
    elseif (Test-Path -LiteralPath $LegacyLeaseEpochPath) {
        # 旧全局 epoch 只作为迁移起点，之后立即写入本 thread 的 epoch 文件。
        $value = LongProp (Read-Json $LegacyLeaseEpochPath @{}) 'leaseEpoch'
    }
    $value++
    Write-JsonAtomic $LeaseEpochPath ([ordered]@{
            leaseEpoch = $value
            updatedAt  = (Get-Date).ToString('o')
        })
    return $value
}

function Assert-NoLease([string]$Operation) {
    $lease = Get-Lease
    if ($null -ne $lease -and -not (LeaseExpired $lease)) {
        throw "$Operation 前有有效浏览器锁，不能接管。"
    }
}

function Assert-Lease(
    [string]$Tab,
    [string]$Token,
    [long]$Epoch,
    [string]$Runtime,
    [long]$RuntimeEpochExpected,
    [switch]$AllowOmittedBrowserSurface
) {
    $lease = Get-Lease
    if ($null -eq $lease -or (LeaseExpired $lease)) {
        throw '没有有效浏览器 lease。'
    }
    if (
        (Prop $lease 'codexThreadId') -ne $CodexThreadId -or
        (Prop $lease 'taskId') -ne (Text $TaskId)
    ) {
        throw '浏览器 lease 不属于当前任务。'
    }
    $presentedSurface = Text $BrowserSurface
    if (
        (Prop $lease 'browserSurface') -ne $TargetBrowserSurface -or
        ((-not $AllowOmittedBrowserSurface) -and $presentedSurface -ne $TargetBrowserSurface) -or
        ($AllowOmittedBrowserSurface -and -not [string]::IsNullOrWhiteSpace($presentedSurface) -and $presentedSurface -ne $TargetBrowserSurface)
    ) {
        throw '浏览器 lease 不是 Codex 右侧栏创建的。'
    }
    if (
        (Prop $lease 'token') -ne (Text $Token) -or
        (LongProp $lease 'leaseEpoch') -ne $Epoch
    ) {
        throw '浏览器 lease token 或 epoch 不一致。'
    }
    if (
        (Prop $lease 'browserRuntimeId') -ne (Text $Runtime) -or
        (LongProp $lease 'runtimeEpoch') -ne $RuntimeEpochExpected
    ) {
        throw '浏览器 runtime 与 lease 不一致。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $Tab)) -and
        (Prop $lease 'browserTabId') -ne (Text $Tab)
    ) {
        throw '浏览器 tab 与 lease 不一致。'
    }
}

function Result([hashtable]$Data) {
    $contract = Get-ActionContract $Action
    $result = [ordered]@{
        action         = $Action
        codexThreadId  = $CodexThreadId
        taskId         = (Text $TaskId)
        targetUrl      = $TargetUrl
        model          = $TargetModel
        browserSurface = $TargetBrowserSurface
        requiredAction = $contract.requiredAction
        requiredEvidence = $contract.requiredEvidence
        browserTool    = $contract.browserTool
        deadlineSeconds = $contract.deadlineSeconds
        onTimeout      = $contract.onTimeout
        onFailure      = $contract.onFailure
    }
    foreach ($entry in $Data.GetEnumerator()) {
        $result[$entry.Key] = $entry.Value
    }
    return [pscustomobject]$result
}

function Get-ActionContract([string]$ActionName) {
    $browserEvidence = 'mcp__cua_repl.js 真实调用回执 + DOM/截图 + 当前 tab/runtime/session'
    switch ($ActionName) {
        'BeginBootstrap' {
            return [pscustomobject]@{
                requiredAction = 'browser-bind-or-reuse'
                requiredEvidence = "宿主公开标签清单、原标签 DOM；$browserEvidence"
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'BindExistingOfficialSession' {
            return [pscustomobject]@{
                requiredAction = 'browser-bind-existing-official-session'
                requiredEvidence = "当前官方会话 URL、标题、当前模型、深度思考和智能搜索、DOM marker、当前 tab/runtime；$browserEvidence"
                browserTool = 'mcp__cua_repl.js'
                deadlineSeconds = $BrowserActionTimeoutSeconds
                onTimeout = 'FailBrowserWorkflow'
                onFailure = 'FailBrowserWorkflow'
            }
        }
        'VerifyBootstrap' { $name = 'browser-verify-bootstrap' }
        'Verify' { $name = 'browser-verify-dom' }
        'PrepareSend' { $name = 'browser-prepare-send' }
        'ConfirmBrowserSend' { $name = 'browser-fill-submit' }
        'RecordSendOutcome' { $name = 'browser-read-receipt' }
        'RecoverRuntimeTab' { $name = 'browser-recover-runtime-tab' }
        default {
            return [pscustomobject]@{
                requiredAction = 'local-state-transition'
                requiredEvidence = 'PowerShell 状态写入结果'
                browserTool = 'none'
                deadlineSeconds = 0
                onTimeout = 'none'
                onFailure = 'fail-closed'
            }
        }
    }
    return [pscustomobject]@{
        requiredAction = $name
        requiredEvidence = $browserEvidence
        browserTool = 'mcp__cua_repl.js'
        deadlineSeconds = if ($ActionName -eq 'ConfirmBrowserSend') {
            $PlatformSendTimeoutSeconds
        } else {
            $BrowserActionTimeoutSeconds
        }
        onTimeout = if ($ActionName -eq 'ConfirmBrowserSend') {
            'FailBrowserWorkflow'
        } else {
            'FailBrowserWorkflow'
        }
        onFailure = 'FailBrowserWorkflow'
    }
}

function Update-TerminatedState([string]$Why) {
    $taskPath = Join-Path $StateDir "$TaskId.json"
    $state = Read-Json $taskPath @{}
    SetProp $state 'taskTerminalStatus' 'cancelled'
    SetProp $state 'executionStatus' '已取消'
    SetProp $state 'auditOnly' $true
    SetProp $state 'activationStatus' 'frozen'
    SetProp $state 'sendAuthorization' 'none'
    SetProp $state 'authorizationScope' ''
    SetProp $state 'authorizationEvidence' ''
    SetProp $state 'resendBlocked' 'true'
    SetProp $state 'taskTerminationReason' $Why
    SetProp $state 'updatedAt' (Get-Date).ToString('o')
    Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
}

function Update-CompletedState([string]$Why) {
    $taskPath = Join-Path $StateDir "$TaskId.json"
    $state = Read-Json $taskPath @{}
    SetProp $state 'taskTerminalStatus' 'completed'
    SetProp $state 'executionStatus' '已完成'
    SetProp $state 'sendAuthorization' 'none'
    SetProp $state 'authorizationScope' ''
    SetProp $state 'authorizationEvidence' ''
    SetProp $state 'resendBlocked' 'false'
    SetProp $state 'taskCompletionReason' $Why
    SetProp $state 'completedAt' (Get-Date).ToString('o')
    SetProp $state 'nextAction' 'completed'
    SetProp $state 'updatedAt' (Get-Date).ToString('o')
    Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
}

function Invoke-FailBrowserWorkflow {
    Require-Activation | Out-Null
    Require-Task

    $reasonText = Text $Reason
    if ([string]::IsNullOrWhiteSpace($reasonText)) {
        $reasonText = 'Codex 右侧栏浏览器工具不可用或调用失败，已停止继续空转。'
    }
    $toolText = if ([string]::IsNullOrWhiteSpace((Text $BrowserTool))) {
        'mcp__cua_repl.js'
    } else {
        Text $BrowserTool
    }
    $statusText = if ([string]::IsNullOrWhiteSpace((Text $BrowserToolStatus))) {
        'failed'
    } else {
        Text $BrowserToolStatus
    }
    $failureClass = if ([string]::IsNullOrWhiteSpace((Text $BrowserFailureClass))) {
        'runtime-disconnected'
    } else {
        Text $BrowserFailureClass
    }
    $recoveryFailure = $failureClass -in @('runtime-disconnected', 'tool-failed', 'unknown')

    With-BindingMutex {
        $transactionPayload = @{
            codexThreadId          = $CodexThreadId
            taskId                 = (Text $TaskId)
            reason                 = $reasonText
            browserTool            = $toolText
            browserToolStatus      = $statusText
            browserFailureClass    = $failureClass
            browserToolCallId      = (Text $BrowserToolCallId)
            browserToolFailureCount = $BrowserToolFailureCount
        }
        Write-TransactionIntent 'fail-browser-workflow' 'prepared' $transactionPayload
        $bindings = Get-Bindings
        $binding = Current-Binding $bindings
        $lease = Get-Lease
        $pendingAudit = $false
        $recoveryCount = 0
        $recoveryLimit = 1

        if ($null -ne $binding) {
            $pendingAudit = BoolProp $binding 'pendingReceipt'
            SetProp $binding 'browserTool' $toolText
            SetProp $binding 'browserToolStatus' $statusText
            SetProp $binding 'browserToolCallId' (Text $BrowserToolCallId)
            if ($BrowserToolFailureCount -ge 0) {
                SetProp $binding 'browserToolFailureCount' $BrowserToolFailureCount
            } else {
                SetProp $binding 'browserToolFailureCount' ((LongProp $binding 'browserToolFailureCount') + 1)
            }
            SetProp $binding 'browserToolFailureReason' $reasonText
            SetProp $binding 'lastBrowserToolAt' (Get-Date).ToString('o')
            SetProp $binding 'browserFailureClass' $failureClass
            $recoveryCount = (LongProp $binding 'browserRecoveryCount') + 1
            $recoveryLimit = [math]::Max(1, (LongProp $binding 'browserRecoveryLimit'))
            SetProp $binding 'browserRecoveryCount' $recoveryCount
            SetProp $binding 'browserRecoveryLimit' $recoveryLimit
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'replacementRequired' (-not $recoveryFailure)
            SetProp $binding 'auditRisk' $pendingAudit
            if ($pendingAudit) {
                SetProp $binding 'auditRiskReason' '浏览器工具失败时已有未核实发送回执，禁止重发。'
            } else {
                SetProp $binding 'auditRiskReason' $reasonText
            }
            if ($recoveryFailure) {
                SetProp $binding 'browserRecoveryStatus' $(
                    if ($recoveryCount -le $recoveryLimit) { 'recovery-pending' } else { 'recovery-exhausted' }
                )
                SetProp $binding 'status' 'recovery-pending'
            }
            elseif ((Prop $binding 'status') -in @('bound', 'bootstrap-pending')) {
                Reset-ActiveIdentityForReplacement $binding $reasonText
                SetProp $binding 'status' 'lost'
                SetProp $binding 'sessionLostAt' (Get-Date).ToString('o')
            }
            Rev $binding
            Save-Bindings $bindings
            Update-TransactionPhase 'binding-updated'
        }

        if (
            $null -ne $lease -and
            (Prop $lease 'codexThreadId') -eq $CodexThreadId -and
            (Prop $lease 'taskId') -eq (Text $TaskId)
        ) {
            Remove-LeaseFiles
        }
        Update-TransactionPhase 'lease-released'

        $taskPath = Join-Path $StateDir "$TaskId.json"
        $state = Get-TaskState
        $bindingRecoveryCount = if ($null -ne $binding) { LongProp $binding 'browserRecoveryCount' } else { 0 }
        $bindingRecoveryLimit = if ($null -ne $binding) { [math]::Max(1, (LongProp $binding 'browserRecoveryLimit')) } else { 1 }
        $recoveryPending = $recoveryFailure -and $bindingRecoveryCount -le $bindingRecoveryLimit
        $nextAction = if ($recoveryPending) {
            'auto-recover-runtime-tab'
        }
        elseif ($failureClass -in @('wrong-session', 'not-found')) {
            'auto-mark-lost-then-replace-tab'
        }
        else {
            'freeze-and-await-browser-evidence'
        }
        SetProp $state 'taskTerminalStatus' $(if ($recoveryPending) { 'frozen' } else { 'failed' })
        SetProp $state 'executionStatus' '禁止修改'
        SetProp $state 'activationStatus' 'frozen'
        SetProp $state 'sendAuthorization' 'none'
        SetProp $state 'authorizationScope' ''
        SetProp $state 'authorizationEvidence' ''
        SetProp $state 'resendBlocked' 'true'
        SetProp $state 'sendStatus' $(if ($recoveryPending) { '浏览器暂时断开，等待一次受控恢复' } else { '评审失败，浏览器工具不可用' })
        SetProp $state 'deepseekStatus' $(if ($recoveryPending) { '未发送，等待恢复原会话' } else { '未发送，已停止继续空转' })
        SetProp $state 'roundStatus' $(if ($recoveryPending) { '等待浏览器恢复' } else { '评审失败' })
        SetProp $state 'auditRisk' ([string]$pendingAudit).ToLowerInvariant()
        SetProp $state 'browserTool' $toolText
        SetProp $state 'browserToolStatus' $statusText
        SetProp $state 'browserFailureClass' $failureClass
        SetProp $state 'browserToolCallId' (Text $BrowserToolCallId)
        SetProp $state 'browserToolFailureReason' $reasonText
        SetProp $state 'taskTerminationReason' $reasonText
        SetProp $state 'nextAction' $nextAction
        SetProp $state 'updatedAt' (Get-Date).ToString('o')
        Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
        Update-TransactionPhase 'task-updated'
        Clear-TransactionIntent

        Result @{
            status                 = $(if ($recoveryPending) { 'browser-recovery-pending' } else { 'browser-workflow-failed' })
            browserTool            = $toolText
            browserToolStatus      = $statusText
            browserFailureClass    = $failureClass
            browserToolCallId      = (Text $BrowserToolCallId)
            reason                 = $reasonText
            pendingAudit           = $pendingAudit
            recoveryCount          = $bindingRecoveryCount
            recoveryLimit          = $bindingRecoveryLimit
            nextAction             = $nextAction
            leaseReleased          = $true
            binding                = $binding
        } | ConvertTo-Json -Depth 20
    }
}

function Recover-PendingTransaction {
    $intent = Get-PendingTransaction
    if (
        $null -eq $intent -or
        (Prop $intent 'operation') -ne 'fail-browser-workflow'
    ) {
        return
    }

    $payload = $intent.payload
    if (
        (Prop $payload 'codexThreadId') -ne $CodexThreadId -or
        (Prop $payload 'taskId') -ne (Text $TaskId)
    ) {
        return
    }

    With-BindingMutex {
        $bindings = Get-Bindings
        $binding = Current-Binding $bindings
        $reasonText = Text (Prop $payload 'reason')
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            $reasonText = '恢复未完成的浏览器失败事务。'
        }
        $failureClass = Text (Prop $payload 'browserFailureClass')
        if ([string]::IsNullOrWhiteSpace($failureClass)) {
            $failureClass = 'runtime-disconnected'
        }
        $recoveryFailure = $failureClass -in @('runtime-disconnected', 'tool-failed', 'unknown')
        $pendingAudit = $false
        $recoveryCount = 0
        $recoveryLimit = 1

        if ($null -ne $binding) {
            $pendingAudit = BoolProp $binding 'pendingReceipt'
            SetProp $binding 'browserTool' (Text (Prop $payload 'browserTool'))
            SetProp $binding 'browserToolStatus' (Text (Prop $payload 'browserToolStatus'))
            SetProp $binding 'browserFailureClass' $failureClass
            SetProp $binding 'browserToolCallId' (Text (Prop $payload 'browserToolCallId'))
            SetProp $binding 'browserToolFailureReason' $reasonText
            SetProp $binding 'lastBrowserToolAt' (Get-Date).ToString('o')
            $recoveryCount = (LongProp $binding 'browserRecoveryCount') + 1
            $recoveryLimit = [math]::Max(1, (LongProp $binding 'browserRecoveryLimit'))
            SetProp $binding 'browserRecoveryCount' $recoveryCount
            SetProp $binding 'browserRecoveryLimit' $recoveryLimit
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'replacementRequired' (-not $recoveryFailure)
            SetProp $binding 'auditRisk' $pendingAudit
            if ($pendingAudit) {
                SetProp $binding 'auditRiskReason' '恢复浏览器失败事务时已有未核实发送回执，禁止重发。'
            }
            else {
                SetProp $binding 'auditRiskReason' $reasonText
            }
            if ($recoveryFailure) {
                SetProp $binding 'browserRecoveryStatus' $(
                    if ($recoveryCount -le $recoveryLimit) { 'recovery-pending' } else { 'recovery-exhausted' }
                )
                SetProp $binding 'status' 'recovery-pending'
            }
            else {
                Reset-ActiveIdentityForReplacement $binding $reasonText
                SetProp $binding 'status' 'lost'
                SetProp $binding 'sessionLostAt' (Get-Date).ToString('o')
            }
            Rev $binding
            Save-Bindings $bindings
        }

        $lease = Get-Lease
        if (
            $null -ne $lease -and
            (Prop $lease 'codexThreadId') -eq $CodexThreadId -and
            (Prop $lease 'taskId') -eq (Text $TaskId)
        ) {
            Remove-LeaseFiles
        }

        $taskPath = Join-Path $StateDir "$TaskId.json"
        if (Test-Path -LiteralPath $taskPath -PathType Leaf) {
            $state = Read-Json $taskPath @{}
            $recoveryPending = $recoveryFailure -and $recoveryCount -le $recoveryLimit
            $nextAction = if ($recoveryPending) {
                'auto-recover-runtime-tab'
            }
            elseif ($failureClass -in @('wrong-session', 'not-found')) {
                'auto-mark-lost-then-replace-tab'
            }
            else {
                'freeze-and-await-browser-evidence'
            }
            SetProp $state 'taskTerminalStatus' $(if ($recoveryPending) { 'frozen' } else { 'failed' })
            SetProp $state 'executionStatus' '禁止修改'
            SetProp $state 'activationStatus' 'frozen'
            SetProp $state 'sendAuthorization' 'none'
            SetProp $state 'authorizationScope' ''
            SetProp $state 'authorizationEvidence' ''
            SetProp $state 'resendBlocked' 'true'
            SetProp $state 'sendStatus' $(if ($recoveryPending) { '浏览器暂时断开，等待一次受控恢复' } else { '评审失败，浏览器工具不可用' })
            SetProp $state 'deepseekStatus' $(if ($recoveryPending) { '未发送，等待恢复原会话' } else { '未发送，已停止继续空转' })
            SetProp $state 'roundStatus' $(if ($recoveryPending) { '等待浏览器恢复' } else { '评审失败' })
            SetProp $state 'auditRisk' ([string]$pendingAudit).ToLowerInvariant()
            SetProp $state 'browserTool' (Text (Prop $payload 'browserTool'))
            SetProp $state 'browserToolStatus' (Text (Prop $payload 'browserToolStatus'))
            SetProp $state 'browserFailureClass' $failureClass
            SetProp $state 'browserToolCallId' (Text (Prop $payload 'browserToolCallId'))
            SetProp $state 'browserToolFailureReason' $reasonText
            SetProp $state 'taskTerminationReason' $reasonText
            SetProp $state 'nextAction' $nextAction
            SetProp $state 'recoveredFromTransaction' $true
            SetProp $state 'updatedAt' (Get-Date).ToString('o')
            Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
        }
        Clear-TransactionIntent
    }
}

function Update-CancelledState(
    [string]$Why,
    [bool]$PendingAudit
) {
    $taskPath = Join-Path $StateDir "$TaskId.json"
    $state = Get-TaskState
    if ((Prop $state 'codexThreadId') -ne $CodexThreadId) {
        throw '任务状态不属于当前 Codex thread，禁止写入取消状态。'
    }

    $oldTargetUrl = Prop $state 'targetUrl'
    if (
        -not [string]::IsNullOrWhiteSpace($oldTargetUrl) -and
        $oldTargetUrl -ne $TargetUrl
    ) {
        SetProp $state 'legacyTargetUrl' $oldTargetUrl
    }
    $oldModel = Prop $state 'model'
    if (
        -not [string]::IsNullOrWhiteSpace($oldModel) -and
        $oldModel -ne $TargetModel
    ) {
        SetProp $state 'legacyModel' $oldModel
    }
    $oldReasoning = Prop $state 'reasoning'
    if (
        -not [string]::IsNullOrWhiteSpace($oldReasoning) -and
        $oldReasoning -ne $TargetReasoning
    ) {
        SetProp $state 'legacyReasoning' $oldReasoning
    }
    SetProp $state 'targetUrl' $TargetUrl
    SetProp $state 'model' $TargetModel
    SetProp $state 'reasoning' $TargetReasoning
    SetProp $state 'taskTerminalStatus' 'cancelled'
    SetProp $state 'executionStatus' '禁止修改'
    SetProp $state 'auditOnly' $false
    SetProp $state 'reviewCancelled' $true
    SetProp $state 'cancelledAt' (Get-Date).ToString('o')
    SetProp $state 'cancelReason' $Why
    SetProp $state 'activationStatus' 'frozen'
    SetProp $state 'sendAuthorization' 'none'
    SetProp $state 'authorizationScope' ''
    SetProp $state 'authorizationEvidence' ''
    SetProp $state 'resendBlocked' 'true'
    SetProp $state 'pendingReceipt' ([string]$PendingAudit).ToLowerInvariant()
    SetProp $state 'auditRisk' ([string]$PendingAudit).ToLowerInvariant()
    if ($PendingAudit) {
        SetProp $state 'sendStatus' '评审已取消，存在未核实发送回执'
        SetProp $state 'deepseekStatus' '用户取消评审，未确认页面回执'
        SetProp $state 'auditRiskReason' '取消时已有 pendingReceipt，必须保留审计风险，禁止重发。'
    }
    else {
        SetProp $state 'sendStatus' '评审已取消，未继续发送'
        SetProp $state 'deepseekStatus' '用户取消评审，未调用 DeepSeek'
        SetProp $state 'auditRiskReason' ''
    }
    SetProp $state 'roundStatus' '评审已取消'
    SetProp $state 'consensusStatus' '用户取消，不作为执行门槛'
    SetProp $state 'agreementSummary' '用户明确取消本轮 DeepSeek 评审；此状态不等同于双方达成共识。'
    SetProp $state 'taskTerminationReason' $Why
    SetProp $state 'updatedAt' (Get-Date).ToString('o')
    Write-JsonAtomic $taskPath $state
        & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
}

function Invoke-CancelReview {
    $state = Require-CancellableTask
    $reasonText = Text $Reason
    if ([string]::IsNullOrWhiteSpace($reasonText)) {
        $reasonText = '用户明确要求本轮不调用 DeepSeek，取消未完成评审。'
    }

    With-BindingMutex {
        $bindings = Get-Bindings
        $binding = Current-Binding $bindings
        $lease = Get-Lease
        $leaseAction = 'lease-not-present'
        $pendingAudit = $false

        if ($null -ne $lease) {
            $sameTaskLease = (
                (Prop $lease 'codexThreadId') -eq $CodexThreadId -and
                (Prop $lease 'taskId') -eq (Text $TaskId)
            )
            if ($sameTaskLease) {
                Remove-LeaseFiles
                $leaseAction = 'released-current-task-lease'
            }
            elseif (-not (LeaseExpired $lease)) {
                $leaseAction = 'preserved-other-thread-lease'
            }
            else {
                $leaseAction = 'preserved-expired-other-thread-lease'
            }
        }

        if ($null -ne $binding) {
            $activeTask = ActiveTask $binding
            if (
                -not [string]::IsNullOrWhiteSpace($activeTask) -and
                $activeTask -ne (Text $TaskId) -and
                $activeTask -ne (Prop $state 'taskId')
            ) {
                throw '当前 thread 的 activeTaskId 不是要取消的 TaskId。'
            }

            $pendingAudit = BoolProp $binding 'pendingReceipt'
            if (
                -not [string]::IsNullOrWhiteSpace((Prop $binding 'targetUrl')) -and
                (Prop $binding 'targetUrl') -ne $TargetUrl
            ) {
                SetProp $binding 'previousTargetUrl' (Prop $binding 'targetUrl')
            }
            if (
                -not [string]::IsNullOrWhiteSpace((Prop $binding 'model')) -and
                (Prop $binding 'model') -ne $TargetModel
            ) {
                SetProp $binding 'previousModel' (Prop $binding 'model')
            }
            if (
                -not [string]::IsNullOrWhiteSpace((Prop $binding 'reasoning')) -and
                (Prop $binding 'reasoning') -ne $TargetReasoning
            ) {
                SetProp $binding 'previousReasoning' (Prop $binding 'reasoning')
            }
            SetProp $binding 'targetUrl' $TargetUrl
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' $TargetReasoning
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'status' 'cancelled'
            Reset-ActiveIdentityForReplacement $binding $reasonText
            SetProp $binding 'replacementRequired' $true
            SetProp $binding 'cancelledAt' (Get-Date).ToString('o')
            SetProp $binding 'cancelReason' $reasonText
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'pendingReceipt' $pendingAudit
            if ($pendingAudit) {
                SetProp $binding 'cancelledPendingAudit' $true
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' '用户取消时已有 pendingReceipt，禁止重发，需人工核对页面落点。'
            }
            else {
                SetProp $binding 'cancelledPendingAudit' $false
                SetProp $binding 'pendingMessageFingerprint' ''
                SetProp $binding 'authorizedMessageFingerprint' ''
                SetProp $binding 'sendAttemptId' ''
                SetProp $binding 'auditRisk' $false
                SetProp $binding 'auditRiskReason' ''
            }
            Rev $binding
            Save-Bindings $bindings
        }

        Update-CancelledState $reasonText $pendingAudit
        $status = 'review-cancelled'
        if ($null -eq $binding) {
            $status = 'review-cancelled-no-binding'
        }
        Result @{
            status       = $status
            leaseAction  = $leaseAction
            pendingAudit = $pendingAudit
            binding      = $binding
        } | ConvertTo-Json -Depth 20
    }
}

Require-Thread

if ($Action -ne 'FailBrowserWorkflow') {
    Recover-PendingTransaction
}

switch ($Action) {
    'Show' {
        $items = Get-Bindings
        Result @{
            status   = 'ok'
            bindings = $items
        } | ConvertTo-Json -Depth 20
        exit 0
    }

    'BeginBootstrap' {
        Require-Activation | Out-Null
        Require-Task
        if ([string]::IsNullOrWhiteSpace((Text $ExpectedMessageMarker))) {
            throw '首次绑定必须提供当前 thread 的 marker。'
        }
        Assert-Dom -Bootstrap

        With-BindingMutex {
            Assert-NoLease 'BeginBootstrap'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if (
                $null -ne $binding -and
                (Prop $binding 'status') -eq 'bound' -and
                (Test-ObsoleteBinding $binding).obsolete
            ) {
                if ([string]::IsNullOrWhiteSpace((Text $Reason))) {
                    $Reason = '当前页面已切换到 DeepSeek 官网，自动隔离旧本机/旧规则绑定并重新建立官网会话。'
                }
                Repair-ObsoleteBinding $binding (Text $Reason) | Out-Null
                Save-Bindings $bindings
                # 旧入口已经被安全隔离，当前本轮可以直接进入 replacement 流程；
                # 不再让调用方卡在“已有 bound 绑定”的错误上。
                $ReplaceLost = $true
            }
            if ($null -eq $binding) {
                Assert-Unique $bindings '' (Text $BrowserTabId) $null
                $binding = New-Binding 'bootstrap-pending'
                $bindings = @($bindings) + @($binding)
                Save-Bindings $bindings
                Result @{
                    status  = 'bootstrap-reserved'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }

            $status = Prop $binding 'status'
            if ($status -eq 'bound') {
                throw '当前 thread 已有本机会话；新 TaskId 应先 Claim 复用。'
            }
            if ($status -eq 'bootstrap-pending') {
                if (
                    (Prop $binding 'browserTabId') -ne (Text $BrowserTabId) -or
                    (Prop $binding 'browserRuntimeId') -ne (Text $BrowserRuntimeId) -or
                    (LongProp $binding 'runtimeEpoch') -ne $RuntimeEpoch -or
                    (ActiveTask $binding) -ne (Text $TaskId) -or
                    (Prop $binding 'expectedMessageMarker') -ne (Text $ExpectedMessageMarker)
                ) {
                    throw '已有 bootstrap 预占不匹配，禁止静默换 tab、runtime 或 marker。'
                }
                Result @{
                    status  = 'bootstrap-already-reserved'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            if (
                $status -notin @('lost', 'cancelled') -or
                -not $ReplaceLost
            ) {
                throw '旧绑定不是 lost/cancelled，或没有显式 ReplaceLost，禁止新建会话。'
            }
            if ([string]::IsNullOrWhiteSpace((Text $Reason))) {
                throw '替代旧绑定必须提供原因。'
            }

            $oldPendingReceipt = BoolProp $binding 'pendingReceipt'
            $oldAuditRisk = BoolProp $binding 'auditRisk'
            $oldReceiptStatus = Prop $binding 'lastReceiptStatus'
            $replacementAudit = (
                $oldPendingReceipt -or
                $oldAuditRisk -or
                $oldReceiptStatus -in @('unknown', 'wrong-session', 'not-found') -or
                (BoolProp $binding 'cancelledPendingAudit')
            )
            # 旧绑定的未确认风险必须保留在历史审计字段，但不能冻结全新的 replacement。
            # replacement 只能继承审计事实，不能继承旧消息的发送阻断状态。
            SetProp $binding 'previousAuditRisk' $oldAuditRisk
            SetProp $binding 'previousAuditRiskReason' (Prop $binding 'auditRiskReason')
            SetProp $binding 'previousPendingReceipt' $oldPendingReceipt
            SetProp $binding 'previousLastReceiptStatus' $oldReceiptStatus
            SetProp $binding 'previousCancelledPendingAudit' (BoolProp $binding 'cancelledPendingAudit')
            SetProp $binding 'replacementAudit' $replacementAudit
            Assert-Unique $bindings '' (Text $BrowserTabId) $binding
            # MarkLost/CancelReview 可能已经把活动身份清空并写入 previous*。
            # replacement bootstrap 只能补齐尚未保存的审计值，不能用空值覆盖历史。
            Reset-ActiveIdentityForReplacement $binding (Text $Reason)
            Set-Active $binding (Text $TaskId) 'replaced' (Text $Reason)

            foreach ($field in @(
                    'deepseekSessionId',
                    'deepseekSessionTitle',
                    'conversationUrl',
                    'domSessionTitle',
            'pendingMessageFingerprint',
            'authorizedMessageFingerprint',
            'sendAttemptId',
            'browserConfirmationStatus',
            'browserConfirmationAt',
            'browserConfirmationEvidence',
            'deadlineStartedAt',
            'sendDeadlineAt',
            'sendRetryCount',
            'lastRetryAt',
            'retryHistory',
            'domMessagePresence',
            'retryExhausted',
            'lastMessageFingerprint',
            'lastReceiptStatus'
                )) {
                SetProp $binding $field ''
            }

            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserTabIdentityScope' (Text $BrowserTabIdentityScope)
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'targetUrl' $TargetUrl
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' (Text $DomReasoning)
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'bindingConfidence' 'bootstrap-pending'
            SetProp $binding 'evidenceSource' 'dom'
            SetProp $binding 'domMessageMarker' (Text $ExpectedMessageMarker)
            SetProp $binding 'expectedMessageMarker' (Text $ExpectedMessageMarker)
            SetProp $binding 'status' 'bootstrap-pending'
            SetProp $binding 'pendingReceipt' $false
            SetProp $binding 'browserConfirmationRequired' $false
            SetProp $binding 'browserConfirmationStatus' ''
            SetProp $binding 'browserConfirmationAt' ''
            SetProp $binding 'browserConfirmationEvidence' ''
            SetProp $binding 'deadlineStartedAt' ''
            SetProp $binding 'sendDeadlineAt' ''
            SetProp $binding 'sendRetryCount' 0
            SetProp $binding 'lastRetryAt' ''
            SetProp $binding 'retryHistory' @()
            SetProp $binding 'domMessagePresence' (Text $DomMessagePresence)
            SetProp $binding 'retryExhausted' $false
            # 新 replacement 没有自己的发送记录，必须允许它独立 PrepareSend。
            # 旧风险已经写入 previous* 和 replacementAudit，不能继续阻塞当前会话。
            SetProp $binding 'resendBlocked' $false
            SetProp $binding 'auditRisk' $false
            SetProp $binding 'auditRiskReason' ''
            SetProp $binding 'cancelledPendingAudit' $false
            SetProp $binding 'replacementRequired' $false
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status  = 'bootstrap-reserved'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'VerifyBootstrap' {
        Require-Activation | Out-Null
        Assert-Dom -Bootstrap
        With-BindingMutex {
            $binding = Current-Binding (Get-Bindings)
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bootstrap-pending') {
                throw '当前没有 bootstrap 预占。'
            }
            Assert-Binding $binding
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                (Prop $binding 'browserTabId') -ne (Text $BrowserTabId) -or
                (Prop $binding 'browserRuntimeId') -ne (Text $BrowserRuntimeId) -or
                (LongProp $binding 'runtimeEpoch') -ne $RuntimeEpoch
            ) {
                throw 'bootstrap 归属或 runtime 不一致。'
            }
            if (
                -not [string]::IsNullOrWhiteSpace((Text $ExpectedMessageMarker)) -and
                (Prop $binding 'expectedMessageMarker') -ne (Text $ExpectedMessageMarker)
            ) {
                throw 'bootstrap marker 不一致。'
            }
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            Result @{
                status  = 'bootstrap-verified'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'CompleteBootstrap' {
        Require-Activation | Out-Null
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            throw '首条消息后没有 sessionId 或 marker，不能完成绑定。'
        }
        $markerObserved = -not [string]::IsNullOrWhiteSpace((Text $DomMessageMarker))

        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '没有 bootstrap 预占。'
            }
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                (Prop $binding 'browserTabId') -ne (Text $BrowserTabId)
            ) {
                throw 'bootstrap task/tab 不一致。'
            }
            if ($markerObserved) {
                if ((Text $DomMessageMarker) -ne (Prop $binding 'expectedMessageMarker')) {
                    throw '首条消息回显的 marker 与预占值不一致。'
                }
            }
            else {
                if (
                    $sessionId -notlike 'official-chat:*' -or
                    (Text $DomMessagePresence) -ne 'present' -or
                    [string]::IsNullOrWhiteSpace((Text $MessageFingerprint)) -or
                    (Prop $binding 'pendingMessageFingerprint') -ne (Text $MessageFingerprint)
                ) {
                    throw '没有 marker 时，必须同时提供官网 official-chat sessionId、DOM 消息 present 和匹配的首条消息指纹。'
                }
            }
            if ((Prop $binding 'status') -eq 'bound') {
                if ((Prop $binding 'deepseekSessionId') -ne $sessionId) {
                    throw '已完成绑定但 session 不一致。'
                }
                Result @{
                    status  = 'bootstrap-already-completed'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            if ((Prop $binding 'status') -ne 'bootstrap-pending') {
                throw '当前状态不能完成 bootstrap。'
            }

            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            SetProp $binding 'deepseekSessionId' $sessionId
            SetProp $binding 'deepseekSessionTitle' (Text $DomSessionTitle)
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' (Text $DomReasoning)
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'bindingConfidence' (ConfidenceValue)
            SetProp $binding 'evidenceSource' 'dom'
            SetProp $binding 'domSessionTitle' (Text $DomSessionTitle)
            SetProp $binding 'domMessageMarker' (Text $DomMessageMarker)
            SetProp $binding 'status' 'bound'
            SetProp $binding 'bootstrapCompletedAt' (Get-Date).ToString('o')
            $verifiedAt = (Get-Date).ToString('o')
            SetProp $binding 'lastVerifiedAt' $verifiedAt
            SetProp $binding 'browserVerifiedAt' $verifiedAt
            SetProp $binding 'replacementRequired' $false
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status  = 'bootstrap-completed'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'BindExistingOfficialSession' {
        Require-Activation | Out-Null
        Require-Task
        $sessionId = ResolvedSessionId
        if ([string]::IsNullOrWhiteSpace($sessionId)) {
            throw '绑定已有官方会话必须提供可由当前 DeepSeek 会话 URL 证明的 sessionId。'
        }
        Assert-Dom -Marker -Title

        With-BindingMutex {
            Assert-NoLease 'BindExistingOfficialSession'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            $oldTask = ''
            $oldStatus = ''

            if ($null -ne $binding) {
                $oldStatus = Prop $binding 'status'
                $oldTask = ActiveTask $binding
                if (
                    $oldStatus -eq 'recovery-pending'
                ) {
                    throw '当前绑定仍在 recovery-pending，必须先 RecoverRuntimeTab，不能把恢复中的 tab 当成新会话接管。'
                }
                if (
                    $oldTask -ne (Text $TaskId) -and
                    -not (IsTaskTerminal $oldTask)
                ) {
                    throw '旧 TaskId 未终态，禁止绑定已有官方会话。'
                }
                if (
                    $oldStatus -eq 'bound' -and
                    (
                        (Prop $binding 'deepseekSessionId') -ne $sessionId -or
                        (Prop $binding 'browserTabId') -ne (Text $BrowserTabId) -or
                        (Prop $binding 'browserRuntimeId') -ne (Text $BrowserRuntimeId)
                    )
                ) {
                    throw '当前仍有 bound 会话，但 session/tab/runtime 不一致；不能用 BindExistingOfficialSession 偷换已有绑定。'
                }
            }

            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            $isNewTask = (
                $null -ne $binding -and
                -not [string]::IsNullOrWhiteSpace($oldTask) -and
                $oldTask -ne (Text $TaskId)
            )

            if ($null -eq $binding) {
                $binding = New-Binding 'bound' $sessionId
            }
            elseif ($isNewTask -or $oldStatus -in @('lost', 'cancelled', 'terminated')) {
                Reset-TaskScopedSendState $binding $oldTask `
                    '当前页面已核验为官方 DeepSeek 会话，允许当前 Task 接管；旧 Task 审计保留在 previousSendAudit。'
            }

            Set-Active $binding (Text $TaskId) 'completed-or-frozen' `
                '绑定当前右侧栏已有官方 DeepSeek 会话'
            SetProp $binding 'deepseekSessionId' $sessionId
            SetProp $binding 'deepseekSessionTitle' (Text $DomSessionTitle)
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'targetUrl' $TargetUrl
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' (Text $DomReasoning)
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'bindingConfidence' (ConfidenceValue)
            SetProp $binding 'evidenceSource' (Text $EvidenceSource)
            SetProp $binding 'domSessionTitle' (Text $DomSessionTitle)
            SetProp $binding 'domMessageMarker' (MarkerValue)
            SetProp $binding 'expectedMessageMarker' (Text $ExpectedMessageMarker)
            SetProp $binding 'status' 'bound'
            SetProp $binding 'replacementRequired' $false
            SetProp $binding 'browserRecoveryStatus' ''
            SetProp $binding 'browserFailureClass' ''
            SetProp $binding 'resendBlocked' $false
            Rev $binding

            $bindingAlreadyInRegistry = $false
            foreach ($candidate in @($bindings)) {
                if ([object]::ReferenceEquals($candidate, $binding)) {
                    $bindingAlreadyInRegistry = $true
                    break
                }
            }
            if (-not $bindingAlreadyInRegistry) {
                $bindings = @($bindings) + @($binding)
            }
            Save-Bindings $bindings
            Result @{
                status = 'existing-official-session-bound'
                previousTaskId = $oldTask
                previousAuditPreserved = [bool](
                    (BoolProp $binding 'replacementAudit') -or
                    @($binding.previousSendAudit).Count -gt 0
                )
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'Claim' {
        Require-Activation | Out-Null
        Require-Task
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            Assert-NoLease 'Claim'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                if ([string]::IsNullOrWhiteSpace($sessionId)) {
                    Result @{ status = 'needs-session' } | ConvertTo-Json -Depth 20
                    return
                }
                Assert-Dom -Marker
                Assert-Unique $bindings $sessionId (Text $BrowserTabId) $null
                $binding = New-Binding 'bound' $sessionId
                $bindings = @($bindings) + @($binding)
                Save-Bindings $bindings
                Result @{
                    status  = 'claimed'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }

            $status = Prop $binding 'status'
            if ($status -eq 'recovery-pending') {
                Assert-Binding $binding
                $oldTask = ActiveTask $binding
                if (
                    $oldTask -ne (Text $TaskId) -and
                    -not (IsTaskTerminal $oldTask)
                ) {
                    throw '浏览器恢复中的旧 TaskId 未终态，禁止接管。'
                }
                if (
                    -not [string]::IsNullOrWhiteSpace($sessionId) -and
                    $sessionId -ne (Prop $binding 'deepseekSessionId')
                ) {
                    throw '恢复中的官网 sessionId 与当前绑定不一致。'
                }
                if (
                    -not [string]::IsNullOrWhiteSpace((Text $BrowserTabId)) -and
                    (Text $BrowserTabId) -ne (Prop $binding 'browserTabId')
                ) {
                    throw '恢复中的 tab 不是原绑定 tab；禁止接管重复 tab。'
                }
                $isNewTask = (
                    -not [string]::IsNullOrWhiteSpace((Text $oldTask)) -and
                    $oldTask -ne (Text $TaskId)
                )
                Set-Active $binding (Text $TaskId) 'recovery-pending' '复用原官网会话，等待一次受控 runtime 恢复'
                if ($isNewTask) {
                    Reset-TaskScopedSendState $binding $oldTask '复用原官网会话，等待一次受控 runtime 恢复'
                }
                Rev $binding
                Save-Bindings $bindings
                Result @{
                    status = 'recover-runtime-required'
                    reason = '浏览器工具暂时断开；保留原 session/tab，下一步只允许 RecoverRuntimeTab，不得新建第二个窗口。'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            if ($status -in @('lost', 'cancelled')) {
                Result @{
                    status  = 'replacement-required'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            if ($status -eq 'bootstrap-pending') {
                throw '当前处于 bootstrap，不能普通 Claim。'
            }
            if ($status -ne 'bound') {
                throw '当前绑定状态不可 Claim。'
            }

            $obsolete = Test-ObsoleteBinding $binding
            if ($obsolete.obsolete) {
                $reason = 'Claim 发现旧入口/旧状态，已自动隔离；当前任务必须直接进入官网 replacement bootstrap。'
                Repair-ObsoleteBinding $binding $reason | Out-Null
                Save-Bindings $bindings
                Result @{
                    status  = 'replacement-required'
                    reason  = $reason
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }

            Assert-Binding $binding
            $oldTask = ActiveTask $binding
            if ([string]::IsNullOrWhiteSpace((Text $oldTask))) {
                $oldTask = Prop $binding 'previousTaskId'
            }
            if ([string]::IsNullOrWhiteSpace((Text $oldTask))) {
                $history = @($binding.taskHistory)
                if ($history.Count -gt 0) {
                    $oldTask = Prop $history[$history.Count - 1] 'taskId'
                }
            }
            if (
                $oldTask -ne (Text $TaskId) -and
                -not (IsTaskTerminal $oldTask)
            ) {
                throw '旧 TaskId 未终态，禁止接管会话。'
            }
            if (
                -not [string]::IsNullOrWhiteSpace($sessionId) -and
                $sessionId -ne (Prop $binding 'deepseekSessionId')
            ) {
                throw 'Claim 禁止换会话。'
            }
            if (
                -not [string]::IsNullOrWhiteSpace((Text $BrowserTabId)) -and
                (Text $BrowserTabId) -ne (Prop $binding 'browserTabId')
            ) {
                throw 'Claim 禁止换 tab；浏览器重启用 Recover，来源迁移用 MigrateToInAppSidebar。'
            }
            $claimReason = 'Claim复用同一官网会话'
            Repair-InheritedRecoveryBudget $binding
            $isNewTask = (
                -not [string]::IsNullOrWhiteSpace((Text $oldTask)) -and
                $oldTask -ne (Text $TaskId)
            )
            Set-Active $binding (Text $TaskId) 'completed-or-frozen' $claimReason
            if ($isNewTask) {
                Reset-TaskScopedSendState $binding $oldTask $claimReason
            }
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status  = 'reused'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RecoverExpiredLeaseBinding' {
        $state = Require-Activation
        Require-Task
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            Assert-NoLease 'RecoverExpiredLeaseBinding'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '没有现有绑定，不能执行安全恢复。'
            }
            Assert-Local $binding
            $summary = Get-RecoverySummary $binding $sessionId
            if (-not $summary.canRecover) {
                throw ("恢复前核验未通过：" + (($summary.reasons) -join '；'))
            }

            $oldTab = Text $binding.browserTabId
            $oldRuntime = Text $binding.browserRuntimeId
            $oldEpoch = LongProp $binding 'runtimeEpoch'
            $runtimeChanged = (
                $oldTab -ne (Text $BrowserTabId) -or
                $oldRuntime -ne (Text $BrowserRuntimeId)
            )
            if ($runtimeChanged) {
                if ($RuntimeEpoch -ne ($oldEpoch + 1)) {
                    throw "恢复 runtime 必须从 $oldEpoch 递增为 $($oldEpoch + 1)。"
                }
                SetProp $binding 'previousBrowserTabId' $oldTab
                SetProp $binding 'previousBrowserRuntimeId' $oldRuntime
                SetProp $binding 'previousRuntimeEpoch' $oldEpoch
            }
            elseif ($RuntimeEpoch -ne $oldEpoch) {
                throw '同一 runtime 恢复时 RuntimeEpoch 不一致。'
            }

            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            Set-Active $binding (Text $TaskId) 'recovered-expired-lease' '恢复同一官网会话，未新建 DeepSeek 会话'
            SetProp $binding 'deepseekSessionId' $sessionId
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserTabIdentityScope' (Text $BrowserTabIdentityScope)
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' $TargetReasoning
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'status' 'bound'
            SetProp $binding 'auditRisk' $false
            SetProp $binding 'auditRiskReason' ''
            SetProp $binding 'resendBlocked' $false
            SetProp $binding 'replacementRequired' $false
            SetProp $binding 'sessionLostAt' ''
            SetProp $binding 'replacementReason' ''
            $verifiedAt = (Get-Date).ToString('o')
            SetProp $binding 'lastVerifiedAt' $verifiedAt
            SetProp $binding 'browserVerifiedAt' $verifiedAt
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status             = 'expired-lease-binding-recovered'
                reusedSessionId    = $sessionId
                createdNewSession  = $false
                createdNewTab      = $false
                runtimeRebound     = $runtimeChanged
                recoverySummary    = $summary
                binding            = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'InspectRecoveryBinding' {
        Require-Activation | Out-Null
        Require-Task
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId
        With-BindingMutex {
            $binding = Current-Binding (Get-Bindings)
            if ($null -eq $binding) {
                Result @{
                    status      = 'recovery-check'
                    canRecover  = $false
                    summary     = $null
                    reason      = '没有现有绑定，不能复用旧会话。'
                } | ConvertTo-Json -Depth 20
                return
            }
            Assert-Local $binding
            $summary = Get-RecoverySummary $binding $sessionId
            Result @{
                status     = 'recovery-check'
                canRecover = $summary.canRecover
                summary    = $summary
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'InspectLostBinding' {
        Require-Activation | Out-Null
        Require-Task
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId
        With-BindingMutex {
            $binding = Current-Binding (Get-Bindings)
            if ($null -eq $binding) {
                Result @{
                    status      = 'lost-recovery-check'
                    canRecover  = $false
                    summary     = $null
                    reason      = '没有现有绑定，不能找回旧会话。'
                } | ConvertTo-Json -Depth 20
                return
            }
            Assert-Local $binding
            $summary = Get-LostBindingRecoverySummary $binding $sessionId
            Result @{
                status             = 'lost-recovery-check'
                canRecover         = $summary.canRecover
                createsNewSession  = $false
                createsNewTab      = $false
                summary            = $summary
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RecoverLostBinding' {
        Require-Activation | Out-Null
        Require-Task
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            Assert-NoLease 'RecoverLostBinding'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '没有现有 lost 绑定，禁止猜测恢复。'
            }
            Assert-Local $binding
            $summary = Get-LostBindingRecoverySummary $binding $sessionId
            if (-not $summary.canRecover) {
                throw ('旧 lost 会话找回前核验未通过：' + (($summary.reasons) -join '；'))
            }

            $activeTask = ActiveTask $binding
            if (
                $activeTask -ne (Text $TaskId) -and
                -not (IsTaskTerminal $activeTask)
            ) {
                throw '当前绑定仍被其他未终态 Task 占用，禁止跨 Task 找回。'
            }
            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            Set-Active $binding (Text $TaskId) 'recovered-lost-session' '核对历史官网 session、marker、专用 tab、模式和回执后安全找回，未新建会话'
            SetProp $binding 'deepseekSessionId' $sessionId
            SetProp $binding 'deepseekSessionTitle' (Text $DeepSeekSessionTitle)
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserTabIdentityScope' (Text $BrowserTabIdentityScope)
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'domSessionTitle' (Text $DomSessionTitle)
            SetProp $binding 'domMessageMarker' (Text $DomMessageMarker)
            SetProp $binding 'expectedMessageMarker' (Text $DomMessageMarker)
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' $TargetReasoning
            SetProp $binding 'searchMode' $TargetSearch
            SetProp $binding 'evidenceSource' 'dom'
            SetProp $binding 'status' 'bound'
            SetProp $binding 'pendingReceipt' $false
            SetProp $binding 'auditRisk' $false
            SetProp $binding 'auditRiskReason' ''
            SetProp $binding 'resendBlocked' $false
            SetProp $binding 'replacementRequired' $false
            SetProp $binding 'sessionLostAt' ''
            SetProp $binding 'replacementReason' ''
            $verifiedAt = (Get-Date).ToString('o')
            SetProp $binding 'lastVerifiedAt' $verifiedAt
            SetProp $binding 'browserVerifiedAt' $verifiedAt
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status             = 'lost-session-recovered'
                reusedSessionId    = $sessionId
                createdNewSession  = $false
                createdNewTab      = $false
                pendingReceiptCleared = $false
                recoverySummary    = $summary
                binding            = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'Verify' {
        Require-Activation | Out-Null
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
                throw '当前没有可验证的绑定。'
            }
            Assert-Binding $binding
            if ((ActiveTask $binding) -ne (Text $TaskId)) {
                throw '当前 TaskId 未 Claim。'
            }
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            $confirmedResume = Get-ConfirmedSendResumeState `
                -Binding $binding `
                -Fingerprint (Prop $binding 'pendingMessageFingerprint')
            $preparedReverify = (
                (Prop $binding 'sendPhase') -eq 'prepared' -and
                (Prop $binding 'browserConfirmationStatus') -eq 'awaiting' -and
                (Prop $binding 'sendOwnerTaskId') -eq (Text $TaskId) -and
                [string]::IsNullOrWhiteSpace((Prop $binding 'deadlineStartedAt')) -and
                [string]::IsNullOrWhiteSpace((Prop $binding 'browserActionAt')) -and
                [string]::IsNullOrWhiteSpace((Prop $binding 'submissionStatus'))
            )
            if (
                (BoolProp $binding 'auditRisk') -or
                (
                    (BoolProp $binding 'resendBlocked') -and
                    -not $preparedReverify -and
                    -not $confirmedResume.reusable
                )
            ) {
                throw '当前绑定存在审计风险或待回执，禁止继续发送。'
            }
            if (
                $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                (Text $BrowserTabId) -ne (Prop $binding 'browserTabId') -or
                (Prop $binding 'browserRuntimeId') -ne (Text $BrowserRuntimeId) -or
                (LongProp $binding 'runtimeEpoch') -ne $RuntimeEpoch
            ) {
                throw '页面 session/tab/runtime 与绑定不一致。'
            }
            if ((Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')) {
                throw '页面 marker 与绑定不一致。'
            }
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            $verifiedAt = (Get-Date).ToString('o')
            SetProp $binding 'lastVerifiedAt' $verifiedAt
            if (
                (Prop $binding 'sendPhase') -notin @('prepared', 'confirmed') -or
                [string]::IsNullOrWhiteSpace((Prop $binding 'browserVerifiedAt'))
            ) {
                SetProp $binding 'browserVerifiedAt' $verifiedAt
            }
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status     = if ($confirmedResume.reusable) { 'verified-confirmed-send' } else { 'verified' }
                binding    = $binding
                sendNow    = [bool]$confirmedResume.reusable
                nextAction = if ($confirmedResume.reusable) {
                    'send-immediately-without-reconfirmation'
                }
                else {
                    'continue-prepare-send'
                }
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'PrepareSend' {
        $state = Require-Activation
        if ([string]::IsNullOrWhiteSpace((Text $MessageFingerprint))) {
            throw 'PrepareSend 必须带消息指纹。'
        }
        if (-not [string]::IsNullOrWhiteSpace((Text $PlatformConfirmationStatus))) {
            throw 'PrepareSend 只负责进入 awaiting；平台 confirmed/rejected 必须单独调用 ConfirmBrowserSend。'
        }
        if ((Prop $state 'sendAuthorization') -notin @('workflow-authorized', 'message-confirmed')) {
            throw '当前任务没有发送授权。'
        }

        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '没有绑定会话。'
            }
            if ((Prop $binding 'status') -notin @('bound', 'bootstrap-pending')) {
                throw '当前状态不能发送。'
            }
            Assert-Binding $binding
            Assert-CurrentBindingSurface $binding
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if ((ActiveTask $binding) -ne (Text $TaskId)) {
                throw 'PrepareSend 的 TaskId 不是当前 ActiveTaskId。'
            }

            if ((Prop $binding 'status') -eq 'bootstrap-pending') {
                Assert-Dom -Bootstrap -RequireSendSurface
            }
            else {
                Assert-Dom -Marker -RequireSendSurface
                $sessionId = ResolvedSessionId
                if (
                    $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                    (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
                ) {
                    throw '发送页面不是绑定会话。'
                }
            }

            if (BoolProp $binding 'pendingReceipt') {
                if (
                    (Prop $binding 'pendingMessageFingerprint') -eq (Text $MessageFingerprint)
                ) {
                    $confirmedResume = Get-ConfirmedSendResumeState `
                        -Binding $binding `
                        -Fingerprint $MessageFingerprint
                    $confirmationReady = [bool]$confirmedResume.reusable
                    $alreadyConfirmed = (
                        (Prop $binding 'browserConfirmationStatus') -eq 'confirmed'
                    )
                    $nextAction = if ($confirmationReady) {
                        'send-immediately-without-reconfirmation'
                    }
                    elseif ($alreadyConfirmed -and $confirmedResume.browserActionObserved) {
                        'verify-original-send-outcome'
                    }
                    elseif ($alreadyConfirmed -and $confirmedResume.deadlineExpired) {
                        'fail-browser-workflow-without-reconfirmation'
                    }
                    elseif ($alreadyConfirmed) {
                        'fail-browser-workflow-without-reconfirmation'
                    }
                    else {
                        'confirm-platform-before-send'
                    }
                    Result @{
                        status        = if ($confirmationReady) { 'send-confirmed-ready' } else { 'send-already-prepared' }
                        binding       = $binding
                        sendAttemptId = (Prop $binding 'sendAttemptId')
                        sendIdempotencyKey = (Prop $binding 'sendIdempotencyKey')
                        sendNow       = $confirmationReady
                        nextAction    = $nextAction
                        confirmationReusable = $confirmationReady
                        browserActionObserved = [bool]$confirmedResume.browserActionObserved
                        sendDeadlineAt = if ([string]::IsNullOrWhiteSpace((Prop $binding 'sendDeadlineAt'))) {
                            ''
                        } else {
                            Prop $binding 'sendDeadlineAt'
                        }
                        browserConfirmationStatus = (Prop $binding 'browserConfirmationStatus')
                        sendRetryCount = LongProp $binding 'sendRetryCount'
                        maxSendRetries = LongProp $binding 'maxSendRetries' 2
                    } | ConvertTo-Json -Depth 20
                    return
                }
                throw '已有待回执消息。'
            }
            if (
                (Prop $binding 'lastMessageFingerprint') -eq (Text $MessageFingerprint) -and
                (Prop $binding 'lastReceiptStatus') -eq 'confirmed'
            ) {
                Result @{
                    status  = 'duplicate-suppressed'
                    binding = $binding
                    sendNow = $false
                    nextAction = 'do-not-resend'
                } | ConvertTo-Json -Depth 20
                return
            }
            if (PreviousAuditContainsFingerprint $binding $MessageFingerprint) {
                throw '该消息 fingerprint 已存在于 previousSendAudit，禁止跨 Task 重发旧消息。'
            }
            if (BoolProp $binding 'resendBlocked') {
                throw '上一条消息回执不明，禁止重发。'
            }
            if (BoolProp $binding 'auditRisk') {
                throw '当前绑定存在审计风险，必须先完成旧回执核对或 replacement bootstrap。'
            }

            $attempt = Text $SendAttemptId
            if ([string]::IsNullOrWhiteSpace($attempt)) {
                $attempt = [guid]::NewGuid().ToString('N')
            }
            $idempotencyKey = Get-SendIdempotencyKey $MessageFingerprint
            if (
                -not [string]::IsNullOrWhiteSpace((Text $SendIdempotencyKey)) -and
                (Text $SendIdempotencyKey) -ne $idempotencyKey
            ) {
                throw '发送幂等键与当前 thread/task/message fingerprint 不一致。'
            }
            SetProp $binding 'pendingReceipt' $true
            SetProp $binding 'sendPhase' 'prepared'
            SetProp $binding 'pendingMessageFingerprint' (Text $MessageFingerprint)
            SetProp $binding 'authorizedMessageFingerprint' (Text $MessageFingerprint)
            SetProp $binding 'sendOwnerTaskId' (Text $TaskId)
            SetProp $binding 'sendIdempotencyKey' $idempotencyKey
            SetProp $binding 'sendAttemptId' $attempt
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'browserConfirmationRequired' $true
            $confirmationStatus = 'awaiting'
            SetProp $binding 'browserConfirmationStatus' $confirmationStatus
            SetProp $binding 'confirmationSource' ''
            SetProp $binding 'confirmationContextHash' ''
            SetProp $binding 'browserConfirmationAt' ''
            SetProp $binding 'browserConfirmationEvidence' ''
            SetProp $binding 'deadlineStartedAt' ''
            SetProp $binding 'sendDeadlineAt' ''
            SetProp $binding 'sendRetryCount' 0
            SetProp $binding 'maxSendRetries' 2
            SetProp $binding 'lastRetryAt' ''
            SetProp $binding 'retryHistory' @()
            SetProp $binding 'domMessagePresence' ''
            SetProp $binding 'domInputPresence' (Text $DomInputPresence)
            SetProp $binding 'domInputEnabled' (Text $DomInputEnabled)
            SetProp $binding 'domSendControl' (Text $DomSendControl)
            SetProp $binding 'submissionMechanism' ''
            SetProp $binding 'submissionStatus' ''
            SetProp $binding 'browserActionAt' ''
            SetProp $binding 'receiptAt' ''
            SetProp $binding 'retryExhausted' $false
            $preparedAt = (Get-Date).ToString('o')
            SetProp $binding 'sendPreparedAt' $preparedAt
            # Preserve the real preflight capture for this send only. Receipt and recovery must not overwrite it.
            SetProp $binding 'sendPageVerifiedAt' (Text $BrowserEvidenceCapturedAt)
            SetProp $binding 'messageReadyAt' $(if ([string]::IsNullOrWhiteSpace((Text $MessageReadyAt))) { $preparedAt } else { Text $MessageReadyAt })
            SetProp $binding 'confirmationRequestedAt' $preparedAt
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status        = 'send-prepared'
                binding       = $binding
                sendAttemptId = $attempt
                sendIdempotencyKey = $idempotencyKey
                sendNow       = ($confirmationStatus -eq 'confirmed')
                nextAction    = if ($confirmationStatus -eq 'confirmed') { 'send-immediately' } else { 'confirm-platform-before-send' }
                sendDeadlineAt = (Prop $binding 'sendDeadlineAt')
                browserConfirmationRequired = $true
                browserConfirmationStatus = $confirmationStatus
                sendRetryCount = 0
                maxSendRetries = 2
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'ConfirmBrowserSend' {
        $state = Require-Activation
        if ($PlatformConfirmationStatus -notin @('confirmed', 'rejected')) {
            throw 'ConfirmBrowserSend 必须明确提供 confirmed 或 rejected。'
        }
        if ([string]::IsNullOrWhiteSpace((Text $MessageFingerprint))) {
            throw 'ConfirmBrowserSend 必须带消息指纹。'
        }
        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -notin @('bound', 'bootstrap-pending')) {
                throw '只有 bound 或 bootstrap-pending DeepSeek 官网会话可以确认平台发送。'
            }
            Assert-Binding $binding
            Assert-CurrentBindingSurface $binding
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                (Prop $binding 'sendOwnerTaskId') -ne (Text $TaskId)
            ) {
                throw '平台确认的 TaskId 与 ActiveTaskId/sendOwnerTaskId 不一致。'
            }
            if (
                -not (BoolProp $binding 'pendingReceipt') -or
                (Prop $binding 'pendingMessageFingerprint') -ne (Text $MessageFingerprint)
            ) {
                throw '当前没有匹配的待确认发送消息。'
            }
            $confirmedResume = Get-ConfirmedSendResumeState `
                -Binding $binding `
                -Fingerprint $MessageFingerprint
            if ($confirmedResume.sameContext -and $confirmedResume.browserActionObserved) {
                throw '同一消息确认后已经出现浏览器动作，禁止再次确认或重发；必须先核对原发送结果。'
            }
            if ($confirmedResume.sameContext -and $confirmedResume.deadlineExpired) {
                Result @{
                    status = 'platform-confirmation-expired-without-action'
                    sendNow = $false
                    nextAction = 'fail-browser-workflow-without-reconfirmation'
                    confirmationReused = $false
                    browserConfirmationStatus = 'confirmed'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            if ($confirmedResume.confirmedForMessage -and -not $confirmedResume.sameContext) {
                Result @{
                    status = 'platform-confirmation-context-changed'
                    sendNow = $false
                    nextAction = 'fail-browser-workflow-without-reconfirmation'
                    confirmationReused = $false
                    browserConfirmationStatus = 'confirmed'
                    binding = $binding
                } | ConvertTo-Json -Depth 20
                return
            }
            $confirmationCapturedThisCall = $false
            if (-not $confirmedResume.confirmedForMessage) {
                if ($PlatformConfirmationStatus -eq 'confirmed' -and
                    [string]::IsNullOrWhiteSpace((Text $PlatformConfirmationEvidence))) {
                    throw '首次平台确认通过必须带确认来源证据；同一消息已确认的重入不需要再次提供。'
                }
                if (
                    $PlatformConfirmationStatus -eq 'confirmed' -and
                    [string]::IsNullOrWhiteSpace((Text $ConfirmationSource))
                ) {
                    throw '首次平台确认通过必须明确 ConfirmationSource；同一消息已确认的重入不需要再次提供。'
                }

                $now = Get-Date
                if ($PlatformConfirmationStatus -eq 'rejected') {
                    SetProp $binding 'browserConfirmationStatus' 'rejected'
                    SetProp $binding 'sendPhase' 'confirmation-rejected'
                    SetProp $binding 'confirmationSource' (Text $ConfirmationSource)
                    SetProp $binding 'confirmationContextHash' ''
                    SetProp $binding 'browserConfirmationAt' $now.ToString('o')
                    SetProp $binding 'browserConfirmationEvidence' (Text $PlatformConfirmationEvidence)
                    SetProp $binding 'deadlineStartedAt' ''
                    SetProp $binding 'sendDeadlineAt' ''
                    SetProp $binding 'auditRisk' $true
                    SetProp $binding 'auditRiskReason' '平台发送确认被拒绝，保留 pendingReceipt 并冻结，禁止自动重发。'
                    SetProp $binding 'resendBlocked' $true
                    Rev $binding
                    Save-Bindings $bindings
                    Result @{
                        status = 'platform-confirmation-rejected'
                        sendNow = $false
                        nextAction = 'freeze-and-reconcile'
                        browserConfirmationStatus = 'rejected'
                        binding = $binding
                    } | ConvertTo-Json -Depth 20
                    return
                }

                $contextHash = Get-ConfirmationContextHash `
                    -Fingerprint $MessageFingerprint `
                    -IdempotencyKey (Prop $binding 'sendIdempotencyKey') `
                    -SessionId (Prop $binding 'deepseekSessionId')
                SetProp $binding 'browserConfirmationStatus' 'confirmed'
                SetProp $binding 'sendPhase' 'confirmed'
                SetProp $binding 'confirmationSource' (Text $ConfirmationSource)
                SetProp $binding 'confirmationContextHash' $contextHash
                SetProp $binding 'browserConfirmationAt' $now.ToString('o')
                SetProp $binding 'browserConfirmationEvidence' (Text $PlatformConfirmationEvidence)
                SetProp $binding 'deadlineStartedAt' $now.ToString('o')
                SetProp $binding 'sendDeadlineAt' $now.AddSeconds(30).ToString('o')
                SetProp $binding 'auditRisk' $false
                SetProp $binding 'auditRiskReason' ''
                SetProp $binding 'resendBlocked' $true
                Rev $binding
                Save-Bindings $bindings
                $confirmationCapturedThisCall = $true
                $confirmedResume = Get-ConfirmedSendResumeState `
                    -Binding $binding `
                    -Fingerprint $MessageFingerprint
            }

            # 平台确认先落盘，再做本地 DOM 参数校验。这里失败不会丢失同一消息的确认。
            if ((Prop $binding 'status') -eq 'bootstrap-pending') {
                Assert-Dom -Bootstrap -RequireSendSurface
            }
            else {
                Assert-Dom -Marker -RequireSendSurface
                $sessionId = ResolvedSessionId
                if (
                    $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                    (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
                ) {
                    throw '平台确认时页面不是原绑定会话。'
                }
            }

            if (-not $confirmedResume.reusable) {
                throw '平台确认已记录，但当前上下文不能安全复用；禁止再次询问，必须失败收尾或核对原发送结果。'
            }
            Result @{
                status = if ($confirmationCapturedThisCall) { 'platform-confirmed' } else { 'platform-already-confirmed' }
                sendNow = $true
                nextAction = if ($confirmationCapturedThisCall) { 'send-immediately' } else { 'send-immediately-without-reconfirmation' }
                confirmationReused = (-not $confirmationCapturedThisCall)
                deadlineStartedAt = (Prop $binding 'deadlineStartedAt')
                sendDeadlineAt = (Prop $binding 'sendDeadlineAt')
                browserConfirmationStatus = 'confirmed'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RetrySendAfterTimeout' {
        $state = Require-Activation
        if ([string]::IsNullOrWhiteSpace((Text $MessageFingerprint))) {
            throw 'RetrySendAfterTimeout 必须带原消息指纹。'
        }
        if ((Prop $state 'sendAuthorization') -notin @('workflow-authorized', 'message-confirmed')) {
            throw '当前任务没有重试发送授权。'
        }
        if ((Text $DomMessagePresence) -ne 'absent') {
            throw '只有 DOM 明确确认目标消息不存在时才能重试；present/unknown 都禁止重发。'
        }

        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
                throw '只有 bound DeepSeek 官网会话可以重试发送。'
            }
            Assert-Binding $binding
            Assert-CurrentBindingSurface $binding
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                (Prop $binding 'sendOwnerTaskId') -ne (Text $TaskId)
            ) {
                throw '重试的 TaskId 与 ActiveTaskId/sendOwnerTaskId 不一致。'
            }
            Assert-Dom -Marker -RequireSendSurface
            $sessionId = ResolvedSessionId
            if (
                $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
            ) {
                throw '重试页面不是绑定会话。'
            }
            if (-not (BoolProp $binding 'pendingReceipt')) {
                throw '当前没有超时待回执消息，禁止重试。'
            }
            if ((Prop $binding 'pendingMessageFingerprint') -ne (Text $MessageFingerprint)) {
                throw '重试消息指纹与待回执消息不一致。'
            }
            $idempotencyKey = Get-SendIdempotencyKey $MessageFingerprint
            if (
                (Prop $binding 'sendIdempotencyKey') -ne $idempotencyKey -or
                (
                    -not [string]::IsNullOrWhiteSpace((Text $SendIdempotencyKey)) -and
                    (Text $SendIdempotencyKey) -ne $idempotencyKey
                )
            ) {
                throw '重试幂等键与原始发送不一致，禁止重发。'
            }
            if ((Prop $binding 'lastReceiptStatus') -eq 'confirmed') {
                throw '消息已经 confirmed，禁止重试。'
            }

            $deadlineText = Prop $binding 'sendDeadlineAt'
            $deadline = $null
            try {
                $deadline = [datetime]::Parse($deadlineText)
            }
            catch {
                throw '缺少有效 sendDeadlineAt，禁止猜测是否超时。'
            }
            if ((Get-Date) -lt $deadline) {
                throw "发送尚未超时，必须等到 $deadline 后才能重试。"
            }

            $retryCount = LongProp $binding 'sendRetryCount'
            $maxRetries = LongProp $binding 'maxSendRetries' 2
            if ($retryCount -ge $maxRetries) {
                SetProp $binding 'retryExhausted' $true
                SetProp $binding 'auditRiskReason' '发送重试已达到上限，必须人工核对页面。'
                Rev $binding
                Save-Bindings $bindings
                throw "发送重试已达到上限 $maxRetries 次，禁止继续重发。"
            }

            $attempt = [guid]::NewGuid().ToString('N')
            $now = Get-Date
            $history = @($binding.retryHistory)
            $history += [pscustomobject][ordered]@{
                retryNumber          = $retryCount + 1
                previousAttemptId    = (Prop $binding 'sendAttemptId')
                newAttemptId         = $attempt
                messageFingerprint   = (Text $MessageFingerprint)
                reason               = (Text $Reason)
                domMessagePresence   = (Text $DomMessagePresence)
                retriedAt            = $now.ToString('o')
            }
            SetProp $binding 'sendAttemptId' $attempt
            SetProp $binding 'sendRetryCount' ($retryCount + 1)
            SetProp $binding 'maxSendRetries' $maxRetries
            SetProp $binding 'lastRetryAt' $now.ToString('o')
            SetProp $binding 'retryHistory' $history
            SetProp $binding 'domMessagePresence' (Text $DomMessagePresence)
            SetProp $binding 'browserConfirmationRequired' $true
            SetProp $binding 'browserConfirmationStatus' 'awaiting'
            SetProp $binding 'confirmationSource' ''
            SetProp $binding 'confirmationContextHash' ''
            SetProp $binding 'browserConfirmationAt' ''
            SetProp $binding 'browserConfirmationEvidence' ''
            SetProp $binding 'deadlineStartedAt' ''
            SetProp $binding 'sendDeadlineAt' ''
            SetProp $binding 'retryExhausted' $false
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'domInputPresence' (Text $DomInputPresence)
            SetProp $binding 'domInputEnabled' (Text $DomInputEnabled)
            SetProp $binding 'domSendControl' (Text $DomSendControl)
            SetProp $binding 'submissionMechanism' ''
            SetProp $binding 'submissionStatus' ''
            SetProp $binding 'browserActionAt' ''
            SetProp $binding 'confirmationRequestedAt' $now.ToString('o')
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status          = 'send-retry-prepared'
                binding         = $binding
                sendAttemptId   = $attempt
                sendIdempotencyKey = $idempotencyKey
                sendNow         = $false
                nextAction      = 'confirm-platform-before-send'
                sendDeadlineAt  = (Prop $binding 'sendDeadlineAt')
                sendRetryCount  = $retryCount + 1
                maxSendRetries  = $maxRetries
                browserConfirmationStatus = 'awaiting'
                retryEvidence   = 'dom-message-absent'
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RecoverRuntimeTab' {
        Require-Activation | Out-Null
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            Assert-NoLease 'RecoverRuntimeTab'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if (
                $null -eq $binding -or
                (Prop $binding 'status') -notin @('bound', 'recovery-pending')
            ) {
                throw '只有 bound 或 recovery-pending 的 DeepSeek 官网会话才能恢复 runtime tab。'
            }
            Assert-Local $binding
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
            ) {
                throw '恢复页面不是原本机会话。'
            }
            if ((Prop $binding 'browserRecoveryStatus') -eq 'recovered' -or (LongProp $binding 'browserRecoveryCount') -gt 1 -or ((Prop $binding 'status') -eq 'bound' -and (LongProp $binding 'browserRecoveryCount') -ge 1)) {
                throw '本任务已使用一次浏览器恢复，保留原会话并暂停，不重复恢复。'
            }
            if ((Prop $binding 'status') -eq 'recovery-pending') {
                $failureAt = [datetimeoffset]::MinValue
                if (-not [datetimeoffset]::TryParse((Prop $binding 'lastBrowserToolAt'), [ref]$failureAt) -or
                    ([datetimeoffset]::UtcNow - $failureAt).TotalSeconds -gt 60) {
                    throw '浏览器恢复超过 60 秒，原轮次和发送记录已保留，未重复发送。'
                }
            }
            $nextEpoch = (LongProp $binding 'runtimeEpoch') + 1
            if ($RuntimeEpoch -ne $nextEpoch) {
                throw "RuntimeEpoch 必须从 $($nextEpoch - 1) 递增为 $nextEpoch。"
            }
            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            SetProp $binding 'previousBrowserTabId' (Prop $binding 'browserTabId')
            SetProp $binding 'previousBrowserRuntimeId' (Prop $binding 'browserRuntimeId')
            SetProp $binding 'previousRuntimeEpoch' (LongProp $binding 'runtimeEpoch')
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserTabIdentityScope' (Text $BrowserTabIdentityScope)
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'status' 'bound'
            SetProp $binding 'browserRecoveryStatus' 'recovered'
            SetProp $binding 'browserRecoveryCount' 1
            SetProp $binding 'browserRecoveryTaskId' (Text $TaskId)
            SetProp $binding 'browserFailureClass' ''
            SetProp $binding 'browserToolStatus' 'available'
            SetProp $binding 'browserToolFailureReason' ''
            SetProp $binding 'replacementRequired' $false
            $hasPendingReceipt = BoolProp $binding 'pendingReceipt'
            $hasAuditRisk = BoolProp $binding 'auditRisk'
            if (-not $hasPendingReceipt -and -not $hasAuditRisk) {
                SetProp $binding 'resendBlocked' $false
                SetProp $binding 'auditRiskReason' ''
            }
            else {
                SetProp $binding 'resendBlocked' $true
            }
            $verifiedAt = (Get-Date).ToString('o')
            SetProp $binding 'lastVerifiedAt' $verifiedAt
            SetProp $binding 'browserVerifiedAt' $verifiedAt
            Rev $binding
            Save-Bindings $bindings
            $taskState = Get-TaskState
            SetProp $taskState 'taskTerminalStatus' 'active'
            SetProp $taskState 'executionStatus' '禁止修改'
            SetProp $taskState 'activationStatus' 'activated'
            SetProp $taskState 'sendAuthorization' 'workflow-authorized'
            SetProp $taskState 'nextAction' 'verify-recovered-session'
            SetProp $taskState 'resendBlocked' ([bool]($hasPendingReceipt -or $hasAuditRisk))
            SetProp $taskState 'updatedAt' (Get-Date).ToString('o')
            Write-JsonAtomic (Join-Path $StateDir "$TaskId.json") $taskState
            Result @{
                status  = 'runtime-tab-recovered'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'MigrateToInAppSidebar' {
        Require-Activation | Out-Null
        Assert-Dom -Marker
        $sessionId = ResolvedSessionId

        With-BindingMutex {
            Assert-NoLease 'MigrateToInAppSidebar'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
                throw '只有 bound DeepSeek 官网会话才能迁入 Codex 右侧栏。'
            }
            Assert-Local $binding
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
            ) {
                throw '迁移必须验证同一 sessionId 和 marker。'
            }
            $nextEpoch = (LongProp $binding 'runtimeEpoch') + 1
            if ($RuntimeEpoch -ne $nextEpoch) {
                throw "迁移 RuntimeEpoch 必须从 $($nextEpoch - 1) 递增为 $nextEpoch。"
            }
            Assert-Unique $bindings $sessionId (Text $BrowserTabId) $binding
            SetProp $binding 'previousBrowserSurface' (Prop $binding 'browserSurface')
            SetProp $binding 'previousBrowserTabId' (Prop $binding 'browserTabId')
            SetProp $binding 'previousBrowserRuntimeId' (Prop $binding 'browserRuntimeId')
            SetProp $binding 'previousRuntimeEpoch' (LongProp $binding 'runtimeEpoch')
            SetProp $binding 'browserSurface' $TargetBrowserSurface
            SetProp $binding 'browserTabId' (Text $BrowserTabId)
            SetProp $binding 'browserTabTitle' (Text $BrowserTabTitle)
            SetProp $binding 'browserTabIdentityScope' (Text $BrowserTabIdentityScope)
            SetProp $binding 'browserRuntimeId' (Text $BrowserRuntimeId)
            SetProp $binding 'runtimeEpoch' $RuntimeEpoch
            SetProp $binding 'tabMatchCount' $TabMatchCount
            SetProp $binding 'conversationUrl' (Text $DomTargetUrl)
            SetProp $binding 'browserMigrationReason' (Text $Reason)
            SetProp $binding 'browserMigratedAt' (Get-Date).ToString('o')
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status  = 'migrated-to-codex-sidebar'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'MigrateToLocalSession' {
        Require-Activation | Out-Null
        Require-Task
        $binding = Current-Binding (Get-Bindings)
        if ($null -eq $binding) {
            throw '没有可迁移的绑定；旧会话必须先新建官网 bootstrap。'
        }
        Assert-Local $binding
        $sessionId = Prop $binding 'deepseekSessionId'
        if (
            [string]::IsNullOrWhiteSpace($sessionId) -or
            $sessionId -notmatch '^(official-chat|official-marker):'
        ) {
            throw 'MigrateToLocalSession 不会把外部 session 迁成当前官网会话；请 MarkLost 后 BeginBootstrap -ReplaceLost。'
        }
        $forward = @{}
        foreach ($parameterName in $PSBoundParameters.Keys) {
            $forward[$parameterName] = $PSBoundParameters[$parameterName]
        }
        $forward['Action'] = 'MigrateToInAppSidebar'
        & $PSCommandPath @forward
        exit $LASTEXITCODE
    }

    'NormalizeInactiveBinding' {
        Require-Activation | Out-Null
        Require-Task
        With-BindingMutex {
            Assert-NoLease 'NormalizeInactiveBinding'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '当前 thread 没有可规范化的绑定。'
            }
            if ((Prop $binding 'status') -notin @('lost', 'cancelled')) {
                throw '只有 lost/cancelled 绑定才能清理失效 tab 和旧页面身份。'
            }
            if ((ActiveTask $binding) -ne (Text $TaskId)) {
                throw '当前 TaskId 不是该失效绑定的 activeTaskId。'
            }
            $reasonText = Text $Reason
            if ([string]::IsNullOrWhiteSpace($reasonText)) {
                $reasonText = '清理 lost/cancelled 绑定残留的旧 tab/runtime，等待官网 replacement bootstrap。'
            }
            Reset-ActiveIdentityForReplacement $binding $reasonText
            SetProp $binding 'targetUrl' $TargetUrl
            SetProp $binding 'model' $TargetModel
            SetProp $binding 'reasoning' $TargetReasoning
            SetProp $binding 'searchMode' $TargetSearch
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status  = 'inactive-binding-normalized'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RecordSendOutcome' {
        Require-Activation | Out-Null
        if ([string]::IsNullOrWhiteSpace((Text $MessageFingerprint))) {
            throw '回执必须带消息指纹。'
        }
        if ([string]::IsNullOrWhiteSpace((Text $ReceiptStatus))) {
            throw '回执必须带 ReceiptStatus。'
        }
        $expectedIdempotencyKey = Get-SendIdempotencyKey $MessageFingerprint
        if (
            -not [string]::IsNullOrWhiteSpace((Text $SendIdempotencyKey)) -and
            (Text $SendIdempotencyKey) -ne $expectedIdempotencyKey
        ) {
            throw '回执幂等键与当前 thread/task/message fingerprint 不一致。'
        }
        if ($ReceiptStatus -ne 'unknown') {
            Assert-ReceiptEvidence
        }
        $sessionId = ''
        if ($ReceiptStatus -in @('confirmed', 'not-found', 'wrong-session')) {
            Assert-Dom -Marker
            $sessionId = ResolvedSessionId
        }

        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
                throw '当前没有 bound DeepSeek 官网会话。'
            }
            Assert-Binding $binding
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if ($ReceiptStatus -eq 'confirmed') {
                Assert-SubmissionEvidence $binding
            }
            if (
                (ActiveTask $binding) -ne (Text $TaskId) -or
                (Prop $binding 'sendOwnerTaskId') -ne (Text $TaskId)
            ) {
                throw '发送回执的 TaskId 与 ActiveTaskId/sendOwnerTaskId 不一致。'
            }
            if (
                -not (BoolProp $binding 'pendingReceipt') -or
                (Prop $binding 'pendingMessageFingerprint') -ne (Text $MessageFingerprint)
            ) {
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' '没有对应的 PrepareSend 回执'
                SetProp $binding 'resendBlocked' $true
                Rev $binding
                Save-Bindings $bindings
                throw '回执没有对应的 PrepareSend，已冻结。'
            }
            if ((Prop $binding 'sendIdempotencyKey') -ne $expectedIdempotencyKey) {
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' '回执幂等键与 PrepareSend 不一致'
                SetProp $binding 'resendBlocked' $true
                Rev $binding
                Save-Bindings $bindings
                throw '回执幂等键与原始发送不一致，已冻结。'
            }
            if (
                (Prop $binding 'browserConfirmationStatus') -ne 'confirmed' -or
                [string]::IsNullOrWhiteSpace((Prop $binding 'deadlineStartedAt'))
            ) {
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' '发送结果没有对应的宿主平台 confirmed 记录'
                SetProp $binding 'resendBlocked' $true
                Rev $binding
                Save-Bindings $bindings
                throw '没有宿主平台 confirmed 记录，禁止登记发送结果，已冻结。'
            }
            if (
                $ReceiptStatus -eq 'confirmed' -and
                (
                    $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                    (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
                )
            ) {
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' 'confirmed 回执页面 session 或 marker 不一致'
                SetProp $binding 'resendBlocked' $true
                Rev $binding
                Save-Bindings $bindings
                throw 'confirmed 回执页面与绑定不一致。'
            }
            if (
                $ReceiptStatus -eq 'not-found' -and
                (
                    $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                    (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
                )
            ) {
                throw 'not-found 回执必须来自原绑定会话。'
            }
            if (
                $ReceiptStatus -eq 'wrong-session' -and
                $sessionId -eq (Prop $binding 'deepseekSessionId') -and
                (Text $DomMessageMarker) -eq (Prop $binding 'domMessageMarker')
            ) {
                throw 'wrong-session 回执证据仍指向原绑定会话。'
            }

            if ($ReceiptStatus -eq 'unknown') {
                SetProp $binding 'sendPhase' 'receipt-unknown'
                SetProp $binding 'lastReceiptStatus' 'unknown'
                SetProp $binding 'domMessagePresence' 'unknown'
                SetProp $binding 'auditRisk' $true
                SetProp $binding 'auditRiskReason' '发送回执未知，保留 pendingReceipt，等待重新核验，不自动重发。'
                SetProp $binding 'resendBlocked' $true
                SetProp $binding 'lastOpenTabsEvidence' (Text $OpenTabsEvidence)
                SetProp $binding 'lastTabsListEvidence' (Text $TabsListEvidence)
                SetProp $binding 'submissionMechanism' (Text $SubmissionMechanism)
                SetProp $binding 'submissionStatus' $(if ([string]::IsNullOrWhiteSpace((Text $SubmissionStatus))) { 'unknown' } else { Text $SubmissionStatus })
                SetProp $binding 'browserActionAt' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserActionAt))) { (Get-Date).ToString('o') } else { Text $BrowserActionAt })
                SetProp $binding 'browserActionEvidence' (Text $BrowserActionEvidence)
                SetProp $binding 'browserEvidenceCapturedAt' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserEvidenceCapturedAt))) { (Get-Date).ToString('o') } else { Text $BrowserEvidenceCapturedAt })
                SetProp $binding 'browserEvidenceStatus' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserActionEvidence))) { 'unattributed' } else { 'captured' })
                SetProp $binding 'lastReceiptEvidenceAt' (Get-Date).ToString('o')
                SetProp $binding 'receiptRecordedAt' (Get-Date).ToString('o')
                SetProp $binding 'receiptAt' (Prop $binding 'receiptRecordedAt')
                Rev $binding
                Save-Bindings $bindings
                Result @{
                    status        = 'recorded-uncertain'
                    receiptStatus = 'unknown'
                    sendIdempotencyKey = $expectedIdempotencyKey
                    nextAction    = 'ResolvePendingSend'
                    binding       = $binding
                } | ConvertTo-Json -Depth 20
                return
            }

            SetProp $binding 'lastMessageFingerprint' (Text $MessageFingerprint)
            SetProp $binding 'lastReceiptStatus' (Text $ReceiptStatus)
            SetProp $binding 'lastOpenTabsEvidence' (Text $OpenTabsEvidence)
            SetProp $binding 'lastTabsListEvidence' (Text $TabsListEvidence)
            SetProp $binding 'submissionMechanism' (Text $SubmissionMechanism)
            SetProp $binding 'submissionStatus' (Text $SubmissionStatus)
            SetProp $binding 'browserActionAt' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserActionAt))) { (Get-Date).ToString('o') } else { Text $BrowserActionAt })
            SetProp $binding 'browserActionEvidence' (Text $BrowserActionEvidence)
            SetProp $binding 'browserEvidenceCapturedAt' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserEvidenceCapturedAt))) { (Get-Date).ToString('o') } else { Text $BrowserEvidenceCapturedAt })
            SetProp $binding 'browserEvidenceStatus' $(if ([string]::IsNullOrWhiteSpace((Text $BrowserActionEvidence))) { 'unattributed' } else { 'captured' })
            SetProp $binding 'lastReceiptEvidenceAt' (Get-Date).ToString('o')
            SetProp $binding 'pendingReceipt' $false
            SetProp $binding 'sendPhase' 'receipt-confirmed'
            SetProp $binding 'pendingMessageFingerprint' ''
            SetProp $binding 'sendAttemptId' ''
            SetProp $binding 'sendDeadlineAt' ''
            SetProp $binding 'sendRetryCount' 0
            SetProp $binding 'lastRetryAt' ''
            SetProp $binding 'retryHistory' @()
            SetProp $binding 'domMessagePresence' (Text $DomMessagePresence)
            SetProp $binding 'retryExhausted' $false
            SetProp $binding 'receiptRecordedAt' (Get-Date).ToString('o')
            SetProp $binding 'receiptAt' (Prop $binding 'receiptRecordedAt')
            if ($ReceiptStatus -eq 'confirmed') {
                SetProp $binding 'resendBlocked' $false
                SetProp $binding 'retryExhausted' $false
            }
            else {
                SetProp $binding 'resendBlocked' $true
                if ($ReceiptStatus -eq 'wrong-session') {
                    SetProp $binding 'status' 'lost'
                    SetProp $binding 'sessionLostAt' (Get-Date).ToString('o')
                }
            }
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status        = 'recorded'
                receiptStatus = $ReceiptStatus
                sendIdempotencyKey = $expectedIdempotencyKey
                binding       = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'ResolvePendingSend' {
        Require-Activation | Out-Null
        if ([string]::IsNullOrWhiteSpace((Text $MessageFingerprint))) {
            throw 'ResolvePendingSend 必须带原消息指纹。'
        }
        if ($ReceiptStatus -ne 'not-found') {
            throw 'ResolvePendingSend 只能使用 not-found；重新确认成功时直接调用 RecordSendOutcome confirmed。'
        }
        if ((Text $DomMessagePresence) -ne 'absent') {
            throw 'ResolvePendingSend 必须带 DOM 明确 absent 证据；present/unknown 不能清除 pendingReceipt。'
        }
        Assert-ReceiptEvidence
        $expectedIdempotencyKey = Get-SendIdempotencyKey $MessageFingerprint
        if (
            -not [string]::IsNullOrWhiteSpace((Text $SendIdempotencyKey)) -and
            (Text $SendIdempotencyKey) -ne $expectedIdempotencyKey
        ) {
            throw 'ResolvePendingSend 幂等键不一致。'
        }
        Assert-Dom -Marker -RequireSendSurface
        $sessionId = ResolvedSessionId
        With-BindingMutex {
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
                throw '当前没有 bound DeepSeek 官网会话。'
            }
            Assert-Binding $binding
            Assert-Lease (Prop $binding 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            if (
                -not (BoolProp $binding 'pendingReceipt') -or
                (Prop $binding 'pendingMessageFingerprint') -ne (Text $MessageFingerprint) -or
                (Prop $binding 'sendIdempotencyKey') -ne $expectedIdempotencyKey
            ) {
                throw '当前没有匹配的 unknown 待回执消息。'
            }
            if (
                $sessionId -ne (Prop $binding 'deepseekSessionId') -or
                (Text $DomMessageMarker) -ne (Prop $binding 'domMessageMarker')
            ) {
                throw '重新核验页面不是原绑定会话。'
            }
            $now = Get-Date
            $deadline = [datetime]::Parse((Prop $binding 'sendDeadlineAt'))
            SetProp $binding 'lastReceiptStatus' 'not-found'
            SetProp $binding 'domMessagePresence' 'absent'
            SetProp $binding 'resendBlocked' $false
            SetProp $binding 'auditRisk' $false
            SetProp $binding 'auditRiskReason' '重新核验确认 DOM 没有目标消息；仅允许在 sendDeadlineAt 之后按原幂等键重试。'
            SetProp $binding 'lastReconciledAt' $now.ToString('o')
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status = 'pending-send-reconciled'
                receiptStatus = 'not-found'
                sendIdempotencyKey = $expectedIdempotencyKey
                retryAllowedAfter = $deadline.ToString('o')
                nextAction = if ($now -ge $deadline) { 'RetrySendAfterTimeout' } else { 'wait-until-sendDeadlineAt' }
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'AcquireBrowserLease' {
        Require-Activation | Out-Null
        $bindings = Get-Bindings
        $binding = Current-Binding $bindings
        if (
            $null -eq $binding -or
            (Prop $binding 'status') -notin @('bound', 'bootstrap-pending')
        ) {
            throw '当前 thread 没有可用 DeepSeek 官网会话。'
        }

        # Acquire happens before the next fresh DOM verification. If only the
        # count was omitted, reuse it solely from this exact bound tab/runtime.
        if ($TabMatchCount -eq -1) {
            $sameBoundBrowser = (
                (Prop $binding 'browserSurface') -eq $TargetBrowserSurface -and
                (Prop $binding 'browserTabId') -eq (Text $BrowserTabId) -and
                (Prop $binding 'browserRuntimeId') -eq (Text $BrowserRuntimeId) -and
                (LongProp $binding 'runtimeEpoch') -eq $RuntimeEpoch -and
                (Prop $binding 'evidenceSource') -eq 'dom' -and
                (LongProp $binding 'tabMatchCount') -eq 1
            )
            if (-not $sameBoundBrowser) {
                throw 'AcquireBrowserLease 缺少唯一标签数量，且当前绑定不能安全补齐。'
            }
            $TabMatchCount = 1
        }
        Assert-Tab
        Assert-Binding $binding
        if (
            (ActiveTask $binding) -ne (Text $TaskId) -or
            (Prop $binding 'browserTabId') -ne (Text $BrowserTabId) -or
            (Prop $binding 'browserRuntimeId') -ne (Text $BrowserRuntimeId) -or
            (LongProp $binding 'runtimeEpoch') -ne $RuntimeEpoch
        ) {
            throw 'lease 请求与绑定 tab/runtime 不一致。'
        }

        With-BindingMutex {
            Migrate-LegacyLeaseIfOwned
            $oldLease = Get-Lease
            if ($null -ne $oldLease -and -not (LeaseExpired $oldLease)) {
                if (
                    (Prop $oldLease 'codexThreadId') -ne $CodexThreadId -or
                    (Prop $oldLease 'taskId') -ne (Text $TaskId)
                ) {
                    throw '另一个 Codex thread 正在使用浏览器 lease。'
                }
                $token = Prop $oldLease 'token'
                $epoch = LongProp $oldLease 'leaseEpoch'
            }
            else {
                $token = [guid]::NewGuid().ToString('N')
                $epoch = Next-LeaseEpoch
            }
            $now = Get-Date
            $lease = [ordered]@{
                token                    = $token
                leaseEpoch               = $epoch
                codexThreadId            = $CodexThreadId
                taskId                   = (Text $TaskId)
                browserSurface           = $TargetBrowserSurface
                browserTabId             = (Text $BrowserTabId)
                browserTabIdentityScope = (Text $BrowserTabIdentityScope)
                browserRuntimeId        = (Text $BrowserRuntimeId)
                runtimeEpoch             = $RuntimeEpoch
                acquiredAt               = $now.ToString('o')
                expiresAt                = $now.AddSeconds(
                    [math]::Max(30, [math]::Min(1800, $LeaseSeconds))
                ).ToString('o')
            }
            Write-JsonAtomic $LeasePath $lease
            Result @{
                status = 'lease-acquired'
                lease  = [pscustomobject]$lease
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'RenewBrowserLease' {
        Require-Activation | Out-Null
        Require-Task
        With-BindingMutex {
            $lease = Get-Lease
            if ($null -eq $lease -or (LeaseExpired $lease)) {
                throw 'lease 已过期。'
            }
            Assert-Lease (Prop $lease 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch
            $now = Get-Date
            SetProp $lease 'expiresAt' $now.AddSeconds(
                [math]::Max(30, [math]::Min(1800, $LeaseSeconds))
            ).ToString('o')
            SetProp $lease 'renewedAt' $now.ToString('o')
            Write-JsonAtomic $LeasePath $lease
            Result @{
                status = 'lease-renewed'
                lease  = $lease
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'ReleaseBrowserLease' {
        Require-Activation | Out-Null
        Require-Task
        With-BindingMutex {
            $lease = Get-Lease
            if ($null -eq $lease) {
                Result @{ status = 'lease-already-free' } | ConvertTo-Json -Depth 20
                return
            }
            Assert-Lease (Prop $lease 'browserTabId') $LeaseToken $LeaseEpoch $BrowserRuntimeId $RuntimeEpoch -AllowOmittedBrowserSurface
            Remove-LeaseFiles
            Result @{ status = 'lease-released' } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'ForceReleaseLease' {
        Require-Activation | Out-Null
        Require-Task
        if ([string]::IsNullOrWhiteSpace((Text $Reason))) {
            throw 'ForceReleaseLease 必须提供原因。'
        }
        With-BindingMutex {
            $lease = Get-Lease
            if ($null -eq $lease) {
                Result @{ status = 'lease-already-free' } | ConvertTo-Json -Depth 20
                return
            }
            $expired = LeaseExpired $lease
            $sameTask = (
                (Prop $lease 'codexThreadId') -eq $CodexThreadId -and
                (Prop $lease 'taskId') -eq (Text $TaskId)
            )
            if (-not $expired -and -not $sameTask) {
                throw '不能释放其他 thread 的有效 lease。'
            }
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            $auditRiskApplied = $false
            $auditClassification = 'no-binding'
            if ($null -ne $binding) {
                $pendingReceipt = BoolProp $binding 'pendingReceipt'
                $resendBlocked = BoolProp $binding 'resendBlocked'
                $lastReceiptStatus = Text $binding 'lastReceiptStatus'
                $uncertainReceipt = (
                    $pendingReceipt -or
                    $lastReceiptStatus -in @('unknown', 'wrong-session', 'not-found') -or
                    $resendBlocked
                )

                if (-not $expired) {
                    SetProp $binding 'auditRisk' $true
                    SetProp $binding 'auditRiskReason' (Text $Reason)
                    $auditRiskApplied = $true
                    $auditClassification = 'active-lease-force-release'
                }
                elseif ($uncertainReceipt) {
                    SetProp $binding 'auditRisk' $true
                    SetProp $binding 'auditRiskReason' "$((Text $Reason))；过期 lease 清理时存在未确认发送风险。"
                    $auditRiskApplied = $true
                    $auditClassification = 'expired-lease-with-uncertain-receipt'
                }
                else {
                    # 过期 lease 本身只是临时锁超时，不应把正常会话永久冻结。
                    # 如果之前已经有审计风险，保留原风险和原因，不在这里静默清除。
                    $auditClassification = 'expired-lease-safe-release'
                }
                Rev $binding
                Save-Bindings $bindings
            }
            Remove-LeaseFiles
            Result @{
                status             = 'lease-force-released'
                expired            = $expired
                auditRiskApplied   = $auditRiskApplied
                auditClassification = $auditClassification
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'CompleteTask' {
        Require-Activation | Out-Null
        Require-Task
        $state = Get-TaskState
        $commonGates = @(
            @{ Name = 'codexSummaryStatus'; Value = '已完成' },
            @{ Name = 'checkResult'; Value = '无问题' },
            @{ Name = 'planStatus'; Value = '已敲定' },
            @{ Name = 'executionStatus'; Value = '允许开始执行' }
        )
        foreach ($gate in $commonGates) {
            if ((Prop $state $gate.Name) -ne $gate.Value) {
                throw "CompleteTask 执行门槛未满足：$($gate.Name) 必须是 $($gate.Value)。"
            }
        }
        $skillName = Prop $state 'skillName'
        if ($skillName -eq 'deepseek-consensus-review') {
            if ((Prop $state 'consensusStatus') -ne '已达成') {
                throw 'CompleteTask 执行门槛未满足：多轮共识评审必须已达成共识。'
            }
        }
        elseif ($skillName -eq 'deepseek-independent-review') {
            $batch = Prop $state 'reviewBatch'
            if ($batch -notmatch '^R(?<number>[1-9][0-9]*)$') {
                throw 'CompleteTask 执行门槛未满足：独立评审批次必须是 R1…Rn。'
            }
            $batchNumber = [long]$Matches['number']
            if ((LongProp $state 'deepseekCompletedRounds') -lt $batchNumber) {
                throw 'CompleteTask 执行门槛未满足：独立评审当前 Rn 尚未完成。'
            }
            if ((Prop $state 'deepseekStatus') -notmatch '已收到完整回复|已完成') {
                throw 'CompleteTask 执行门槛未满足：独立评审尚未收到完整回复。'
            }
            if ((Prop $state 'lastReceiptStatus') -ne 'confirmed') {
                throw 'CompleteTask 执行门槛未满足：独立评审没有 confirmed 页面回执。'
            }
        }
        else {
            throw 'CompleteTask 遇到未知 SkillName，拒绝猜测执行门槛。'
        }
        With-BindingMutex {
            Assert-NoLease 'CompleteTask'
            $lease = Get-Lease
            if ($null -ne $lease -and (LeaseExpired $lease)) {
                Remove-LeaseFiles
            }
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '找不到当前 thread 绑定。'
            }
            $oldTask = ActiveTask $binding
            if ($oldTask -ne (Text $TaskId)) {
                if (IsTaskTerminal $TaskId) {
                    Result @{
                        status  = 'task-already-completed'
                        binding = $binding
                    } | ConvertTo-Json -Depth 20
                    return
                }
                throw '当前 activeTaskId 不是要完成的 TaskId。'
            }
            if (
                (BoolProp $binding 'pendingReceipt') -or
                (BoolProp $binding 'auditRisk') -or
                (BoolProp $binding 'resendBlocked')
            ) {
                throw 'CompleteTask 前仍有 pendingReceipt、auditRisk 或 resendBlocked。'
            }
            $reasonText = Text $Reason
            if ([string]::IsNullOrWhiteSpace($reasonText)) {
                $reasonText = '评审、修复、验证和发布已正常完成。'
            }
            Add-History $binding $oldTask 'completed' $reasonText
            SetProp $binding 'activeTaskId' ''
            SetProp $binding 'taskId' ''
            SetProp $binding 'previousTaskId' $oldTask
            SetProp $binding 'taskCompletionReason' $reasonText
            SetProp $binding 'taskCompletedAt' (Get-Date).ToString('o')
            Rev $binding
            Save-Bindings $bindings
            Update-CompletedState $reasonText
            Result @{
                status  = 'task-completed'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'ForceTerminateTask' {
        Require-Thread
        Require-Task
        $state = Get-TaskState
        if (
            (Prop $state 'activationStatus') -notin @('activated', 'frozen') -and
            -not (BoolProp $state 'auditOnly')
        ) {
            throw '旧任务没有激活或冻结证据。'
        }
        With-BindingMutex {
            Assert-NoLease 'ForceTerminateTask'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '找不到当前 thread 绑定。'
            }
            $oldTask = ActiveTask $binding
            if ($oldTask -ne (Text $TaskId)) {
                if (IsTaskTerminal $TaskId) {
                    Result @{
                        status  = 'task-already-terminated'
                        binding = $binding
                    } | ConvertTo-Json -Depth 20
                    return
                }
                throw '当前 activeTaskId 不是要终止的 TaskId。'
            }
            Add-History $binding $oldTask 'terminated' (Text $Reason)
            SetProp $binding 'activeTaskId' ''
            SetProp $binding 'taskId' ''
            SetProp $binding 'previousTaskId' $oldTask
            SetProp $binding 'taskTerminationReason' (Text $Reason)
            Rev $binding
            Save-Bindings $bindings
            Update-TerminatedState (Text $Reason)
            Result @{
                status  = 'task-terminated'
                binding = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'MarkLost' {
        Require-Activation | Out-Null
        Require-Task
        if ([string]::IsNullOrWhiteSpace((Text $Reason))) {
            throw 'MarkLost 必须提供原因。'
        }
        if ((Text $LossEvidence) -ne 'confirmed-absent') {
            throw 'MarkLost 必须带 confirmed-absent 丢失证据；浏览器工具暂时不可用时不能误标 lost。'
        }
        if ($LossObservationCount -lt 1) {
            throw 'MarkLost 至少需要一次真实丢失观测。'
        }
        $lossSources = @(
            (Text $LossEvidenceSources) -split '[,;\s]+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.ToLowerInvariant() }
        )
        $legacyLost = ('opentabs' -in $lossSources -and 'tabs.list' -in $lossSources -and
            (Text $OpenTabsEvidence) -eq 'absent' -and (Text $TabsListEvidence) -eq 'absent')
        $publicLost = ('cua.getstate' -in $lossSources -and 'original-url' -in $lossSources -and
            $LossObservationCount -ge 2 -and (Text $BrowserToolStatus) -eq 'available' -and
            (Text $OpenTabsEvidence) -eq 'absent' -and (Text $TabsListEvidence) -in @('', 'unknown', 'absent') -and
            (Text $OriginalConversationStatus) -eq 'not-found')
        if (-not $legacyLost -and -not $publicLost) {
            throw 'MarkLost 需要真实旧双清单，或当前工具清单加原对话地址明确不存在；empty/unknown、登录和工具失败不能当作丢失。'
        }
        With-BindingMutex {
            Assert-NoLease 'MarkLost'
            $bindings = Get-Bindings
            $binding = Current-Binding $bindings
            if ($null -eq $binding) {
                throw '找不到当前 thread 绑定。'
            }
            if ($publicLost) {
                if ((Text $DomTargetUrl) -ne (Prop $binding 'conversationUrl') -or
                    (BoolProp $binding 'pendingReceipt') -or (BoolProp $binding 'auditRisk')) {
                    throw '原对话地址不匹配或发送落点仍未知，保留原记录，不进入新会话。'
                }
                $taskState = Get-TaskState
                if ((BoolProp $taskState 'reviewCancelled') -or (Prop $taskState 'taskTerminalStatus') -notin @('active', 'frozen')) {
                    throw '已停止或已完成的任务不能自动新建对话。'
                }
            }
            $oldTask = ActiveTask $binding
            if (
                $oldTask -ne (Text $TaskId) -and
                -not (IsTaskTerminal $oldTask)
            ) {
                throw '旧 TaskId 未终态，禁止由新任务直接 MarkLost。'
            }
            Set-Active $binding (Text $TaskId) 'lost' (Text $Reason)
            SetProp $binding 'status' 'lost'
            Reset-ActiveIdentityForReplacement $binding (Text $Reason)
            SetProp $binding 'sessionLostAt' (Get-Date).ToString('o')
            SetProp $binding 'replacementReason' (Text $Reason)
            SetProp $binding 'resendBlocked' $true
            SetProp $binding 'replacementRequired' $true
            SetProp $binding 'lossEvidence' (Text $LossEvidence)
            SetProp $binding 'lossEvidenceSources' ($lossSources -join ',')
            SetProp $binding 'originalConversationStatus' (Text $OriginalConversationStatus)
            SetProp $binding 'lossObservationCount' $LossObservationCount
            SetProp $binding 'lossObservationWindowSeconds' $LossObservationWindowSeconds
            SetProp $binding 'lossEvidenceRecordedAt' (Get-Date).ToString('o')
            Rev $binding
            Save-Bindings $bindings
            Result @{
                status     = 'marked-lost'
                nextAction = 'auto-begin-replacement-bootstrap'
                binding    = $binding
            } | ConvertTo-Json -Depth 20
        }
        exit 0
    }

    'CancelBootstrap' {
        Invoke-CancelReview
        exit 0
    }

    'CancelReview' {
        Invoke-CancelReview
        exit 0
    }

    'FailBrowserWorkflow' {
        Invoke-FailBrowserWorkflow
        exit 0
    }

    default {
        throw "不支持的 Action：$Action"
    }
}
