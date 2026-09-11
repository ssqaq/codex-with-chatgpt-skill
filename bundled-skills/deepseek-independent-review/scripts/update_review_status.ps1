[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [string]$TaskName,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$ReviewBatch,
    [string]$CompletedRounds,
    [string]$BrowserRecoveryCount,
    [string]$LocalSessionStatus,
    [string]$LocalSessionTitle,
    [string]$DeepSeekSessionId,
    [string]$DeepSeekSessionTitle,
    [string]$BrowserTabId,
    [string]$BrowserTabTitle,
    [ValidateSet('', 'codex-in-app-sidebar', 'unverified-legacy-or-external')]
    [string]$BrowserSurface,
    [string]$BrowserTabIdentityScope,
    [string]$BrowserRuntimeId,
    [string]$RuntimeEpoch,
    [string]$LeaseEpoch,
    [string]$BindingRevision,
    [string]$TabMatchCount,
    [string]$EvidenceSource,
    [string]$DomSessionTitle,
    [string]$DomMessageMarker,
    [string]$BindingConfidence,
    [string]$SessionBindingStatus,
    [string]$SessionOwner,
    [string]$BrowserLeaseStatus,
    [string]$BindingConflict,
    [string]$SessionLost,
    [string]$TargetUrl,
    [string]$ConversationUrl,
    [string]$Model,
    [string]$Reasoning,
    [string]$SendStatus,
    [string]$RoundStatus,
    [string]$DeepSeekStatus,
    [string]$CodexSummaryStatus,
    [string]$CheckResult,
    [string]$PlanStatus,
    [string]$ExecutionStatus,
    [string]$WaitingStartedAt,
    [string]$LastMessageFingerprint,
    [string]$LastReceiptStatus,
    [string]$SendOwnerTaskId,
    [string]$SendIdempotencyKey,
    [string]$ResendBlocked,
    [string]$SendAttemptId,
    [string]$PendingReceipt,
    [string]$AuditRisk,
    [string]$SendDeadlineAt,
    [string]$SendRetryCount,
    [string]$MaxSendRetries,
    [string]$LastRetryAt,
    [string]$DomMessagePresence,
    [string]$RetryExhausted,
    [string]$BrowserConfirmationRequired,
    [ValidateSet('', 'awaiting', 'confirmed', 'rejected')]
    [string]$BrowserConfirmationStatus,
    [ValidateSet('', 'action-time-user-response', 'browser-tool-token')]
    [string]$ConfirmationSource,
    [string]$ConfirmationContextHash,
    [string]$BrowserConfirmationAt,
    [string]$BrowserConfirmationEvidence,
    [string]$RequestedAt,
    [string]$ActivatedAt,
    [string]$ActivationElapsedMs,
    [string]$ActivationSlowPathAlert,
    [string]$ActivationSlowPathThresholdMs,
    [string]$ActivationSlowPathReason,
    [string]$MessageReadyAt,
    [string]$BrowserVerifiedAt,
    [string]$ConfirmationRequestedAt,
    [string]$BrowserActionAt,
    [string]$BrowserActionEvidence,
    [string]$BrowserEvidenceCapturedAt,
    [string]$ReceiptAt,
    [ValidateSet('', 'button', 'enter')]
    [string]$SubmissionMechanism,
    [ValidateSet('', 'succeeded', 'failed', 'unknown')]
    [string]$SubmissionStatus,
    [ValidateSet('', 'present', 'absent', 'unknown')]
    [string]$DomInputPresence,
    [ValidateSet('', 'enabled', 'disabled', 'unknown')]
    [string]$DomInputEnabled,
    [ValidateSet('', 'enabled', 'disabled', 'unknown')]
    [string]$DomSendControl,
    [string]$DeadlineStartedAt,
    [string]$LastOpenTabsEvidence,
    [string]$LastTabsListEvidence,
    [string]$LastReceiptEvidenceAt,
    [string]$BrowserTool,
    [string]$BrowserToolStatus,
    [string]$BrowserToolCallId,
    [string]$BrowserToolFailureCount,
    [string]$BrowserToolFailureReason,
    [string]$BrowserEvidenceStatus,
    [ValidateSet('', 'none', 'workflow-authorized', 'message-confirmed', 'rejected')]
    [string]$SendAuthorization,
    [string]$AuthorizationScope,
    [string]$AuthorizationEvidence,
    [string]$AuthorizedMessageFingerprint,
    [ValidateSet('', 'active', 'completed', 'failed', 'cancelled', 'frozen')]
    [string]$TaskTerminalStatus,
    [string]$Note,
    [string]$ConsensusStatus,
    [string]$UnresolvedIssues,
    [string]$CodexPosition,
    [string]$DeepSeekPosition,
    [string]$AgreementSummary,
    [ValidateSet('', 'deepseek-consensus-review', 'deepseek-independent-review')]
    [string]$SkillName,
    [ValidateSet('', 'requested', 'activated', 'unknown', 'frozen')]
    [string]$ActivationStatus,
    [string]$ActivationEvidence,
     [string]$CancelReason,
     [string]$StateDir,
     [switch]$AllowRebind,
     [switch]$FreezeAudit,
     [string]$LegacyReceiptEvidenceGap,
     [switch]$FinalizeLegacyAudit,
     [switch]$CancelReview,
     [switch]$HumanReadable,
     [switch]$Show
 )

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$TargetUrlValue = 'https://chat.deepseek.com/'
$TargetModelValue = '专家模式'
$TargetReasoningValue = '深度思考'
$TargetSurfaceValue = 'codex-in-app-sidebar'
$SchemaVersion = 7

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

$CodexThreadId = if ($CodexThreadId -match '^codex://threads/([^/?#]+)') {
    $Matches[1]
}
else {
    $CodexThreadId.Trim()
}
$statePath = Join-Path $StateDir "$TaskId.json"

function Text([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Trim()
}

function SetProp([object]$Object, [string]$Name, [object]$Value) {
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Prop([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return ''
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return ''
        }
        return Text $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return ''
    }
    return Text $property.Value
}

function ReadJson([string]$Path, [object]$Default) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $Default
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $Default
    }
    return $raw | ConvertFrom-Json
}

function WriteJson([string]$Path, [object]$Value) {
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

function Truthy([object]$Value) {
    return (Text $Value) -in @('True', 'true', '1', 'yes')
}

function HasSafeConfirmedReceiptEvidence([object]$Object) {
    if ((Prop $Object 'domMessagePresence') -ne 'present') {
        return $false
    }
    $openTabsEvidence = Prop $Object 'lastOpenTabsEvidence'
    $tabsListEvidence = Prop $Object 'lastTabsListEvidence'
    return (
        ($openTabsEvidence -eq 'confirmed' -or $tabsListEvidence -eq 'confirmed') -and
        $openTabsEvidence -ne 'wrong-session' -and
        $tabsListEvidence -ne 'wrong-session'
    )
}

function IsLocalUrl([string]$Value) {
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

function BindingForThread([string]$Thread) {
    $bindingPath = Join-Path $StateDir 'thread-bindings.json'
    if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf)) {
        return $null
    }
    $registry = ReadJson $bindingPath @{}
    $items = @(
        $registry.bindings |
            Where-Object { (Prop $_ 'codexThreadId') -eq $Thread }
    )
    if ($items.Count -gt 1) {
        throw '同一 Codex thread 存在多条绑定，状态更新拒绝猜测。'
    }
    if ($items.Count -eq 0) {
        return $null
    }
    return $items[0]
}

function SetIf(
    [System.Collections.IDictionary]$State,
    [string]$Name,
    [object]$Value
) {
    $valueText = Text $Value
    if (
        -not [string]::IsNullOrWhiteSpace($valueText) -and
        $valueText -ne '-1'
    ) {
        $State[$Name] = $Value
    }
}

function AssertCanonicalInputs {
    if ($FreezeAudit -or $FinalizeLegacyAudit) {
         return
     }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $TargetUrl)) -and
        (Text $TargetUrl) -ne $TargetUrlValue
    ) {
        throw '当前 Skill 只允许 https://chat.deepseek.com/。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $Model)) -and
        (Text $Model) -ne $TargetModelValue
    ) {
        throw '当前 Skill 只允许目标模型专家模式。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $Reasoning)) -and
        (Text $Reasoning) -ne $TargetReasoningValue
    ) {
        throw '当前 Skill 只允许开启深度思考。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $ConversationUrl)) -and
        -not (IsLocalUrl $ConversationUrl)
    ) {
        throw '当前 conversationUrl 必须是 DeepSeek 官网 URL。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $DeepSeekSessionId)) -and
        (Text $DeepSeekSessionId) -notmatch '^(official-chat|official-marker):'
    ) {
        throw '当前 sessionId 必须是 official-chat 或 official-marker。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $BrowserSurface)) -and
        (Text $BrowserSurface) -ne $TargetSurfaceValue
    ) {
        throw '当前状态只允许 Codex 右侧栏内置浏览器。'
    }
}

function MoveLegacyField(
    [System.Collections.IDictionary]$State,
    [string]$CurrentName,
    [string]$LegacyName,
    [scriptblock]$IsValid
) {
    $currentValue = Text $State[$CurrentName]
    if (
        -not [string]::IsNullOrWhiteSpace($currentValue) -and
        -not (& $IsValid $currentValue)
    ) {
        if (
            [string]::IsNullOrWhiteSpace((Text $State[$LegacyName]))
        ) {
            $State[$LegacyName] = $currentValue
        }
        $State[$CurrentName] = ''
    }
}

function NormalizeCurrentState([System.Collections.IDictionary]$State) {
    if ($FreezeAudit -or $FinalizeLegacyAudit) {
         return
     }

    MoveLegacyField $State 'conversationUrl' 'legacyConversationUrl' {
        param($Value)
        IsLocalUrl $Value
    }
    MoveLegacyField $State 'deepseekSessionId' 'legacyDeepSeekSessionId' {
        param($Value)
        $Value -match '^(official-chat|official-marker):'
    }
    MoveLegacyField $State 'browserSurface' 'legacyBrowserSurface' {
        param($Value)
        $Value -in @('', 'codex-in-app-sidebar', 'unverified-legacy-or-external')
    }

    $existingTarget = Text $State['targetUrl']
    if (
        -not [string]::IsNullOrWhiteSpace($existingTarget) -and
        $existingTarget -ne $TargetUrlValue -and
        [string]::IsNullOrWhiteSpace((Text $State['legacyTargetUrl']))
    ) {
        $State['legacyTargetUrl'] = $existingTarget
    }
    $State['targetUrl'] = $TargetUrlValue

    $existingModel = Text $State['model']
    if (
        -not [string]::IsNullOrWhiteSpace($existingModel) -and
        $existingModel -ne $TargetModelValue -and
        [string]::IsNullOrWhiteSpace((Text $State['legacyModel']))
    ) {
        $State['legacyModel'] = $existingModel
    }
    $State['model'] = $TargetModelValue
    $existingReasoning = Text $State['reasoning']
    if (
        -not [string]::IsNullOrWhiteSpace($existingReasoning) -and
        $existingReasoning -ne $TargetReasoningValue -and
        [string]::IsNullOrWhiteSpace((Text $State['legacyReasoning']))
    ) {
        $State['legacyReasoning'] = $existingReasoning
    }
    $State['reasoning'] = $TargetReasoningValue

    if (
        -not [string]::IsNullOrWhiteSpace((Text $TargetUrl)) -and
        (Text $TargetUrl) -eq $TargetUrlValue
    ) {
        $State['targetUrl'] = $TargetUrlValue
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $Model)) -and
        (Text $Model) -eq $TargetModelValue
    ) {
        $State['model'] = $TargetModelValue
    }
}

function RevokeAuthorization([System.Collections.IDictionary]$State) {
    $State['sendAuthorization'] = 'none'
    $State['authorizationScope'] = ''
    $State['authorizationEvidence'] = ''
    $State['resendBlocked'] = 'true'
}

function AssertStateConsistency([System.Collections.IDictionary]$State) {
    if ($FreezeAudit -or $FinalizeLegacyAudit) {
         return
     }
    if ((Text $State['targetUrl']) -ne $TargetUrlValue) {
        throw '状态 targetUrl 不是 DeepSeek 官网。'
    }
    if ((Text $State['model']) -ne $TargetModelValue) {
        throw '状态 model 不是专家模式。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $State['conversationUrl'])) -and
        -not (IsLocalUrl $State['conversationUrl'])
    ) {
        throw '状态 conversationUrl 不是 DeepSeek 官网 URL。'
    }
    if (
        -not [string]::IsNullOrWhiteSpace((Text $State['deepseekSessionId'])) -and
        (Text $State['deepseekSessionId']) -notmatch '^(official-chat|official-marker):'
    ) {
        throw '状态 deepseekSessionId 不是官网会话。'
    }
    if ((Text $State['reasoning']) -ne $TargetReasoningValue) {
        throw '状态 reasoning 不是深度思考。'
    }
    if (
        (Text $State['browserSurface']) -notin @('', 'codex-in-app-sidebar', 'unverified-legacy-or-external')
    ) {
        throw '状态 browserSurface 不受支持。'
    }
    $confirmationStatus = Text $State['browserConfirmationStatus']
    if ($confirmationStatus -eq 'awaiting') {
        if (
            -not [string]::IsNullOrWhiteSpace((Text $State['deadlineStartedAt'])) -or
            -not [string]::IsNullOrWhiteSpace((Text $State['sendDeadlineAt']))
        ) {
            throw '平台确认仍是 awaiting 时，禁止提前启动发送 deadline。'
        }
    }
    if (
        (Text $State['lastReceiptStatus']) -eq 'confirmed' -and
        -not (HasSafeConfirmedReceiptEvidence $State)
    ) {
        throw 'confirmed 回执必须保留 DOM present、至少一个标签来源 confirmed，且不能有 wrong-session 冲突。'
    }
    if (
        (Text $State['taskTerminalStatus']) -in @('completed', 'failed', 'cancelled', 'frozen') -or
        (Text $State['activationStatus']) -eq 'frozen'
    ) {
        if ((Text $State['sendAuthorization']) -ne 'none') {
            throw '终态或冻结态仍保留发送授权。'
        }
    }
    if (Truthy $State['decisionDeadlock']) {
        if ((Text $State['executionStatus']) -ne '禁止修改') {
            throw '决策僵局状态必须保持禁止修改。'
        }
        if ((Text $State['consensusStatus']) -eq '已达成') {
            throw '决策僵局不能同时标记为已达成共识。'
        }
    }
}

function AssertSentConsistency([System.Collections.IDictionary]$State) {
    $sent = (Text $State['sendStatus']) -match '已发送|已收到|sent|received'
    if (-not $sent) {
        return
    }
    if (Truthy $State['auditOnly']) {
        throw '历史审计态禁止写入已发送/已收到。'
    }
    if ((Text $State['activationStatus']) -ne 'activated') {
        throw '没有真实 Skill 激活记录，禁止写入已发送/已收到。'
    }
    $binding = BindingForThread $CodexThreadId
    if ($null -eq $binding -or (Prop $binding 'status') -ne 'bound') {
        throw '当前 thread 没有 bound DeepSeek 官网会话。'
    }
    if ((Prop $binding 'browserSurface') -ne $TargetSurfaceValue) {
        throw '绑定不是 Codex 右侧栏内置浏览器。'
    }
    if (
        (Prop $binding 'targetUrl') -ne $TargetUrlValue -or
        (Prop $binding 'model') -ne $TargetModelValue -or
        (Prop $binding 'reasoning') -ne $TargetReasoningValue
    ) {
        throw '绑定不是 DeepSeek 官网专家模式 + 深度思考。'
    }
    if (
        [string]::IsNullOrWhiteSpace((Prop $binding 'deepseekSessionId')) -or
        (Prop $binding 'deepseekSessionId') -notmatch '^(official-chat|official-marker):'
    ) {
        throw '绑定缺少官网会话或仍残留外部 session。'
    }
    $activeTask = Prop $binding 'activeTaskId'
    if ([string]::IsNullOrWhiteSpace($activeTask)) {
        $activeTask = Prop $binding 'taskId'
    }
    if ($activeTask -ne $TaskId) {
        throw '当前任务还没有 Claim 这条官网会话。'
    }
    if ((Prop $binding 'lastReceiptStatus') -ne 'confirmed') {
        throw '没有 confirmed 页面回执，禁止写入已发送/已收到。'
    }
    if (-not (HasSafeConfirmedReceiptEvidence $binding)) {
        throw '绑定的 confirmed 回执缺少安全降级所需的 DOM 和至少一个 confirmed 标签来源。'
    }
    if (-not (IsLocalUrl (Text $State['conversationUrl']))) {
        throw '状态缺少 DeepSeek 官网 conversation URL。'
    }
    if ((Text $State['browserSurface']) -ne $TargetSurfaceValue) {
        throw '状态没有证明使用 Codex 右侧栏内置浏览器。'
    }
    if (
        (Text $State['targetUrl']) -ne $TargetUrlValue -or
        (Text $State['model']) -ne $TargetModelValue -or
        (Text $State['reasoning']) -ne $TargetReasoningValue
    ) {
        throw '状态没有证明使用 DeepSeek 官网专家模式 + 深度思考。'
    }
    if (
        (Text $State['deepseekSessionId']) -ne (Prop $binding 'deepseekSessionId') -or
        (Text $State['browserTabId']) -ne (Prop $binding 'browserTabId')
    ) {
        throw '任务状态与绑定的本机会话/tab 不一致。'
    }
}

if ($Show -and $CancelReview) {
    throw 'Show 不能和 CancelReview 同时使用。'
}

if ($Show) {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "找不到任务状态：$statePath"
    }
    Get-Content -LiteralPath $statePath -Raw -Encoding utf8
    exit 0
}

if ([string]::IsNullOrWhiteSpace($CodexThreadId) -and -not $FreezeAudit) {
    throw '缺少 CodexThreadId，禁止写无归属状态。'
}

AssertCanonicalInputs

$mutexScope = (
    [IO.Path]::GetFullPath($StateDir).TrimEnd('\') + '|' + $TaskId
).ToLowerInvariant()
$mutexHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($mutexScope)
    )
).Substring(0, 24)
$mutex = [Threading.Mutex]::new(
    $false,
    "Global\CodexDeepSeekReviewTaskStateV6-$mutexHash"
)
$owned = $false
try {
    try {
        $owned = $mutex.WaitOne(10000)
    }
    catch [Threading.AbandonedMutexException] {
        $owned = $true
    }
    if (-not $owned) {
        throw '无法取得状态锁。'
    }

    $state = [ordered]@{}
    $stateExisted = Test-Path -LiteralPath $statePath -PathType Leaf
    if ($stateExisted) {
        $old = ReadJson $statePath @{}
    foreach ($property in $old.PSObject.Properties) {
            $state[$property.Name] = $property.Value
        }
    }

    if (
        $stateExisted -and
        (Truthy $state['auditOnly']) -and
        -not $FreezeAudit -and
        -not $FinalizeLegacyAudit
    ) {
        throw '历史审计态是只读状态；不能用普通状态更新把流程伪装成继续运行。请读取审计，或明确执行 FinalizeLegacyAudit。'
    }

    $ownershipStatus = 'owned'
    if ([string]::IsNullOrWhiteSpace($CodexThreadId)) {
        $ownershipStatus = 'unowned-historical'
    }

    $defaults = [ordered]@{
        taskId                        = $TaskId
        stateRevision                = 0
        taskName                      = ''
        codexThreadId                 = $CodexThreadId
        sessionOwner                  = $CodexThreadId
        reviewBatch                   = 'C1'
        deepseekCompletedRounds      = '0'
        browserRecoveryCount         = '0/1'
        localDeepSeekSession          = '未开始'
        localSessionTitle             = ''
        deepseekSessionId             = ''
        deepseekSessionTitle          = ''
        browserTabId                 = ''
        browserTabTitle              = ''
        browserSurface               = 'unverified-legacy-or-external'
        browserTabIdentityScope      = 'browser-runtime-tab-id'
        browserRuntimeId             = ''
        runtimeEpoch                 = ''
        leaseEpoch                   = ''
        bindingRevision              = ''
        tabMatchCount                = ''
        evidenceSource               = ''
        domSessionTitle              = ''
        domMessageMarker             = ''
        bindingConfidence            = ''
        sessionBindingStatus         = '待首次绑定'
        browserLeaseStatus           = '未持有'
        bindingConflict              = ''
        sessionLost                  = ''
        targetUrl                    = $TargetUrlValue
        conversationUrl              = ''
        model                        = $TargetModelValue
        reasoning                    = $TargetReasoningValue
        sendStatus                   = '未发送'
        roundStatus                  = '未开始'
        deepseekStatus               = '未开始'
        codexSummaryStatus           = '未开始'
        checkResult                 = '待检查'
        planStatus                  = '未敲定'
        executionStatus             = '禁止修改'
        waitingStartedAt            = ''
        lastMessageFingerprint      = ''
        lastReceiptStatus            = ''
        sendOwnerTaskId              = ''
        sendIdempotencyKey           = ''
        resendBlocked               = 'false'
        sendAttemptId               = ''
        pendingReceipt              = 'false'
        auditRisk                   = 'false'
        sendDeadlineAt              = ''
        sendRetryCount              = '0'
        maxSendRetries              = '2'
        lastRetryAt                 = ''
        domMessagePresence          = ''
        retryExhausted              = 'false'
        browserConfirmationRequired = 'false'
        browserConfirmationStatus   = ''
        confirmationSource          = ''
        confirmationContextHash     = ''
        browserConfirmationAt       = ''
        browserConfirmationEvidence = ''
        requestedAt                 = (Get-Date).ToString('o')
        activatedAt                 = ''
        activationElapsedMs         = ''
        activationSlowPathAlert     = $false
        activationSlowPathThresholdMs = '2000'
        activationSlowPathReason     = ''
        messageReadyAt              = ''
        browserVerifiedAt           = ''
        confirmationRequestedAt     = ''
        browserActionAt             = ''
        browserActionEvidence       = ''
        browserEvidenceCapturedAt   = ''
        receiptAt                   = ''
        submissionMechanism         = ''
        submissionStatus            = ''
        domInputPresence            = ''
        domInputEnabled             = ''
        domSendControl              = ''
        deadlineStartedAt            = ''
        lastOpenTabsEvidence        = ''
        lastTabsListEvidence        = ''
        lastReceiptEvidenceAt       = ''
        browserTool                 = 'mcp__node_repl.js'
        browserToolStatus           = 'not-started'
        browserToolCallId           = ''
        browserToolFailureCount     = '0'
        browserToolFailureReason    = ''
        browserEvidenceStatus       = ''
        sendAuthorization           = 'none'
        authorizationScope          = ''
        authorizationEvidence       = ''
        authorizedMessageFingerprint = ''
        taskTerminalStatus          = 'active'
        note                        = ''
        consensusStatus             = '未开始'
        unresolvedIssues            = ''
        codexPosition               = '初步判断'
        deepSeekPosition            = '未回复'
        agreementSummary            = ''
        roundTrackingVersion        = '1'
        roundHistory                = @()
        deadlockResolutionHistory   = @()
        unresolvedIssueFingerprint = ''
        repeatedDisagreementRounds  = '0'
        deadlockThreshold           = '2'
        decisionDeadlock            = 'false'
        decisionDeadlockReason      = ''
        lastDecisionDeadlockReason  = ''
        deadlockDetectedAt          = ''
        deadlockResolvedAt          = ''
        userDecision                = ''
        # 激活后第一步永远是准备/核验浏览器绑定；不能把尚未发送的任务
        # 错误标成“记录下一轮”，否则状态面板会反复汇报而不推进流程。
        nextAction                  = 'prepare-browser-binding'
        roundProgressPercent        = '0'
        blockedReason               = ''
        lastActionAt                = ''
        lastReportAt                = ''
        lastReportActionAt          = ''
        lastReportFingerprint       = ''
        noOpReportCount             = '0'
        requiredAction              = ''
        requiredEvidence            = ''
        requiredBrowserTool         = ''
        requiredDeadlineSeconds     = '0'
        requiredActionName          = ''
        actionContractStatus        = ''
        actionContractRevision      = '0'
        actionContractIssuedAt      = ''
        actionContractDeadlineAt    = ''
        onTimeout                   = ''
        onFailure                   = ''
        skillName                   = ''
        activationStatus            = 'not-activated'
        activationEvidence          = ''
        activationAt                = ''
        auditOnly                   = $false
        ownershipStatus             = $ownershipStatus
        stateSchemaVersion          = "$SchemaVersion"
        bindingVersion              = "$SchemaVersion"
        reviewCancelled             = $false
        cancelledAt                 = ''
        cancelReason                = ''
        legacyTargetUrl             = ''
        legacyModel                 = ''
        legacyConversationUrl       = ''
        legacyDeepSeekSessionId     = ''
        legacyBrowserSurface        = ''
        legacyReasoning             = ''
        legacyLastReceiptStatus     = ''
        legacyReceiptEvidenceGap    = ''
        legacyDomMessagePresence    = ''
        legacyOpenTabsEvidence      = ''
        legacyTabsListEvidence      = ''
        legacyPendingReceipt        = ''
        legacyTaskTerminalStatus    = ''
        legacyAuditFinalizedAt      = ''
    }

    foreach ($entry in $defaults.GetEnumerator()) {
        if (-not $state.Contains($entry.Key) -or $null -eq $state[$entry.Key]) {
            $state[$entry.Key] = $entry.Value
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace((Text $state['codexThreadId'])) -and
        (Text $state['codexThreadId']) -ne $CodexThreadId
    ) {
        throw '任务状态归属冲突。'
    }

    $state['taskId'] = $TaskId
    $state['codexThreadId'] = $CodexThreadId
    $state['sessionOwner'] = $CodexThreadId
    $state['stateSchemaVersion'] = "$SchemaVersion"
    $state['bindingVersion'] = "$SchemaVersion"
    $state['ownershipStatus'] = $ownershipStatus

    if (-not $FreezeAudit) {
        NormalizeCurrentState $state
    }

    if (
        -not [string]::IsNullOrWhiteSpace($DeepSeekSessionId) -and
        -not [string]::IsNullOrWhiteSpace((Text $state['deepseekSessionId'])) -and
        $DeepSeekSessionId -ne (Text $state['deepseekSessionId']) -and
        -not $AllowRebind
    ) {
        throw '任务状态 session 冲突，禁止静默切换。'
    }

    $optionalFields = @{
        taskName                      = $TaskName
        reviewBatch                   = $ReviewBatch
        deepseekCompletedRounds      = $CompletedRounds
        browserRecoveryCount         = $BrowserRecoveryCount
        localDeepSeekSession          = $LocalSessionStatus
        localSessionTitle             = $LocalSessionTitle
        deepseekSessionId             = $DeepSeekSessionId
        deepseekSessionTitle          = $DeepSeekSessionTitle
        browserTabId                 = $BrowserTabId
        browserTabTitle              = $BrowserTabTitle
        browserSurface               = $BrowserSurface
        browserTabIdentityScope      = $BrowserTabIdentityScope
        browserRuntimeId             = $BrowserRuntimeId
        runtimeEpoch                 = $RuntimeEpoch
        leaseEpoch                   = $LeaseEpoch
        bindingRevision              = $BindingRevision
        tabMatchCount                = $TabMatchCount
        evidenceSource               = $EvidenceSource
        domSessionTitle              = $DomSessionTitle
        domMessageMarker             = $DomMessageMarker
        bindingConfidence            = $BindingConfidence
        sessionBindingStatus         = $SessionBindingStatus
        sessionOwner                 = $SessionOwner
        browserLeaseStatus           = $BrowserLeaseStatus
        bindingConflict              = $BindingConflict
        sessionLost                  = $SessionLost
        targetUrl                    = $TargetUrl
        conversationUrl              = $ConversationUrl
        model                        = $Model
        reasoning                    = $Reasoning
        sendStatus                   = $SendStatus
        roundStatus                  = $RoundStatus
        deepseekStatus               = $DeepSeekStatus
        codexSummaryStatus           = $CodexSummaryStatus
        checkResult                 = $CheckResult
        planStatus                  = $PlanStatus
        executionStatus             = $ExecutionStatus
        waitingStartedAt            = $WaitingStartedAt
        lastMessageFingerprint      = $LastMessageFingerprint
        lastReceiptStatus            = $LastReceiptStatus
        sendOwnerTaskId              = $SendOwnerTaskId
        sendIdempotencyKey           = $SendIdempotencyKey
        resendBlocked               = $ResendBlocked
        sendAttemptId               = $SendAttemptId
        pendingReceipt              = $PendingReceipt
        auditRisk                   = $AuditRisk
        sendDeadlineAt              = $SendDeadlineAt
        sendRetryCount              = $SendRetryCount
        maxSendRetries              = $MaxSendRetries
        lastRetryAt                 = $LastRetryAt
        domMessagePresence          = $DomMessagePresence
        retryExhausted              = $RetryExhausted
        browserConfirmationRequired = $BrowserConfirmationRequired
        browserConfirmationStatus   = $BrowserConfirmationStatus
        confirmationSource          = $ConfirmationSource
        confirmationContextHash     = $ConfirmationContextHash
        browserConfirmationAt       = $BrowserConfirmationAt
        browserConfirmationEvidence = $BrowserConfirmationEvidence
        requestedAt                 = $RequestedAt
        activatedAt                 = $ActivatedAt
        activationElapsedMs         = $ActivationElapsedMs
        activationSlowPathAlert     = $ActivationSlowPathAlert
        activationSlowPathThresholdMs = $ActivationSlowPathThresholdMs
        activationSlowPathReason     = $ActivationSlowPathReason
        messageReadyAt              = $MessageReadyAt
        browserVerifiedAt           = $BrowserVerifiedAt
        confirmationRequestedAt     = $ConfirmationRequestedAt
        browserActionAt             = $BrowserActionAt
        browserActionEvidence       = $BrowserActionEvidence
        browserEvidenceCapturedAt   = $BrowserEvidenceCapturedAt
        receiptAt                   = $ReceiptAt
        submissionMechanism         = $SubmissionMechanism
        submissionStatus            = $SubmissionStatus
        domInputPresence            = $DomInputPresence
        domInputEnabled             = $DomInputEnabled
        domSendControl              = $DomSendControl
        deadlineStartedAt            = $DeadlineStartedAt
        lastOpenTabsEvidence        = $LastOpenTabsEvidence
        lastTabsListEvidence        = $LastTabsListEvidence
        lastReceiptEvidenceAt       = $LastReceiptEvidenceAt
        browserTool                 = $BrowserTool
        browserToolStatus           = $BrowserToolStatus
        browserToolCallId           = $BrowserToolCallId
        browserToolFailureCount     = $BrowserToolFailureCount
        browserToolFailureReason    = $BrowserToolFailureReason
        browserEvidenceStatus       = $BrowserEvidenceStatus
        sendAuthorization           = $SendAuthorization
        authorizationScope          = $AuthorizationScope
        authorizationEvidence       = $AuthorizationEvidence
        authorizedMessageFingerprint = $AuthorizedMessageFingerprint
        taskTerminalStatus          = $TaskTerminalStatus
        note                        = $Note
        consensusStatus             = $ConsensusStatus
        unresolvedIssues            = $UnresolvedIssues
        codexPosition               = $CodexPosition
        deepSeekPosition            = $DeepSeekPosition
        agreementSummary            = $AgreementSummary
        skillName                   = $SkillName
        activationStatus            = $ActivationStatus
        activationEvidence          = $ActivationEvidence
    }
    foreach ($entry in $optionalFields.GetEnumerator()) {
        SetIf $state $entry.Key $entry.Value
    }

    if ($FinalizeLegacyAudit) {
        if (-not $stateExisted) {
            throw '历史终态迁移要求目标任务状态文件已经存在。'
        }
        if ((Text $state['lastReceiptStatus']) -ne 'confirmed') {
            throw '历史终态迁移只允许处理旧 confirmed 回执，其他状态必须先正常核验。'
        }
        $evidenceGaps = @()
        if ((Text $state['domMessagePresence']) -ne 'present') {
            $evidenceGaps += 'DOM'
        }
        if (
            (Text $state['lastOpenTabsEvidence']) -ne 'confirmed' -and
            (Text $state['lastTabsListEvidence']) -ne 'confirmed'
        ) {
            $evidenceGaps += 'openTabs/tabs.list 至少一个 confirmed 来源'
        }
        if (
            (Text $state['lastOpenTabsEvidence']) -eq 'wrong-session' -or
            (Text $state['lastTabsListEvidence']) -eq 'wrong-session'
        ) {
            $evidenceGaps += '标签来源存在 wrong-session 冲突'
        }
        if ($evidenceGaps.Count -eq 0) {
            throw '历史 confirmed 已经具备完整回执证据，不需要走历史审计迁移。'
        }
        if (
            -not [string]::IsNullOrWhiteSpace((Text $TaskTerminalStatus)) -and
            (Text $TaskTerminalStatus) -notin @('completed', 'failed')
        ) {
            throw '历史审计迁移只能收口为 completed 或 failed，不能保留 active/cancelled/frozen。'
        }

        $gapText = Text $LegacyReceiptEvidenceGap
        if ([string]::IsNullOrWhiteSpace($gapText)) {
            $gapText = "旧 confirmed 回执缺少：$($evidenceGaps -join '、')"
        }
        $state['legacyLastReceiptStatus'] = Text $state['lastReceiptStatus']
        $state['legacyReceiptEvidenceGap'] = $gapText
        $state['legacyDomMessagePresence'] = Text $state['domMessagePresence']
        $state['legacyOpenTabsEvidence'] = Text $state['lastOpenTabsEvidence']
        $state['legacyTabsListEvidence'] = Text $state['lastTabsListEvidence']
        $state['legacyPendingReceipt'] = Text $state['pendingReceipt']
        $state['legacyTaskTerminalStatus'] = Text $state['taskTerminalStatus']
        $state['legacyAuditFinalizedAt'] = (Get-Date).ToString('o')
        $state['auditOnly'] = $true
        $state['taskTerminalStatus'] = if (
            (Text $TaskTerminalStatus) -in @('completed', 'failed')
        ) {
            Text $TaskTerminalStatus
        }
        elseif ((Text $state['taskTerminalStatus']) -eq 'failed') {
            'failed'
        }
        else {
            'completed'
        }
        $state['activationStatus'] = 'unknown'
        $state['executionStatus'] = '禁止修改'
        $state['sendAuthorization'] = 'none'
        $state['authorizationScope'] = ''
        $state['authorizationEvidence'] = ''
        $state['pendingReceipt'] = 'false'
        $state['resendBlocked'] = 'true'
        $state['auditRisk'] = 'true'
        $state['auditRiskReason'] = "$gapText；已转为只读历史审计，禁止重发。"
        $state['sendStatus'] = '历史 confirmed 回执已安全终态迁移，证据缺口保留在 legacy* 字段'
        $state['roundStatus'] = '历史审计已收口'
        $state['deepseekStatus'] = '历史回执已迁移，未继续发送'
        $state['consensusStatus'] = '历史审计，不作为当前执行门槛'
        $state['agreementSummary'] = '旧 confirmed 回执缺少完整页面/标签证据；已保留风险并转只读终态，不能把它当作当前新任务的发送依据。'
        $state['nextAction'] = 'historical-audit-finalized'
        $state['taskTerminationReason'] = $gapText
        RevokeAuthorization $state
    }

    if (
        -not $FreezeAudit -and
        -not $FinalizeLegacyAudit -and
        (Text $state['targetUrl']) -ne $TargetUrlValue
    ) {
        $state['legacyTargetUrl'] = $state['targetUrl']
        $state['targetUrl'] = $TargetUrlValue
    }
    if (
        -not $FreezeAudit -and
        -not $FinalizeLegacyAudit -and
        (Text $state['model']) -ne $TargetModelValue
    ) {
        $state['legacyModel'] = $state['model']
        $state['model'] = $TargetModelValue
    }
    if (
        -not $FreezeAudit -and
        -not $FinalizeLegacyAudit -and
        (Text $state['reasoning']) -ne $TargetReasoningValue
    ) {
        $state['legacyReasoning'] = $state['reasoning']
        $state['reasoning'] = $TargetReasoningValue
    }

    if ((Text $ActivationStatus) -eq 'activated') {
        if ($FinalizeLegacyAudit) {
            throw '历史审计迁移不能同时重新激活 Skill。'
        }
        if (
            [string]::IsNullOrWhiteSpace($SkillName) -or
            [string]::IsNullOrWhiteSpace($ActivationEvidence)
        ) {
            throw 'Skill 激活必须带 SkillName 和 ActivationEvidence。'
        }
        if (
            ((Text $state['taskTerminalStatus']) -in @('completed', 'failed', 'cancelled', 'frozen')) -or
            (Truthy $state['reviewCancelled'])
        ) {
            throw '已终态或已取消评审的任务不能重新激活。'
        }
        $activationTime = (Get-Date).ToString('o')
        $state['activationAt'] = $activationTime
        $state['activatedAt'] = $activationTime
        if ((Text $state['sendAuthorization']) -in @('', 'none')) {
            $state['sendAuthorization'] = 'workflow-authorized'
            $state['authorizationScope'] = '当前 Codex thread、当前评审目标、当前 DeepSeek 官网专家模式/深度思考会话内的完整评审流程'
            $state['authorizationEvidence'] = '用户显式调用 DeepSeek Skill 并要求评审；同一流程自动授权。'
        }

        # 兼容旧状态：旧版本把激活后的 nextAction 错写成
        # record-next-round。没有 bound 会话时必须先进入浏览器绑定，
        # 已有 bound 会话才允许进入消息准备/下一轮评审。
        $activationBinding = BindingForThread $CodexThreadId
        $activationBindingStatus = if ($null -eq $activationBinding) {
            ''
        }
        else {
            Text (Prop $activationBinding 'status')
        }
        if (
            $activationBindingStatus -ne 'bound' -and
            (Text $state['nextAction']) -in @('', 'record-next-round')
        ) {
            $state['nextAction'] = 'prepare-browser-binding'
        }
        elseif (
            $activationBindingStatus -eq 'bound' -and
            (Text $state['nextAction']) -eq 'record-next-round' -and
            [string]::IsNullOrWhiteSpace((Text $state['messageReadyAt']))
        ) {
            $state['nextAction'] = 'prepare-review-message'
        }
    }

    if ($CancelReview) {
        if ($FinalizeLegacyAudit) {
            throw '历史审计迁移不能同时取消评审。'
        }
        $reasonText = Text $CancelReason
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            $reasonText = Text $Note
        }
        if ([string]::IsNullOrWhiteSpace($reasonText)) {
            $reasonText = '用户明确要求本轮不调用 DeepSeek，取消未完成评审。'
        }
        if ((Text $state['taskTerminalStatus']) -in @('completed', 'failed')) {
            throw '已完成或失败的任务不能取消评审。'
        }
        $state['taskTerminalStatus'] = 'cancelled'
        $state['executionStatus'] = '禁止修改'
        $state['reviewCancelled'] = $true
        $state['cancelledAt'] = (Get-Date).ToString('o')
        $state['cancelReason'] = $reasonText
        $state['activationStatus'] = 'frozen'
        RevokeAuthorization $state
        $state['sendStatus'] = if (Truthy $state['pendingReceipt']) {
            '评审已取消，存在未核实发送回执'
        }
        else {
            '评审已取消，未继续发送'
        }
        $state['deepseekStatus'] = '用户取消评审，未调用 DeepSeek'
        $state['roundStatus'] = '评审已取消'
        $state['consensusStatus'] = '用户取消，不作为执行门槛'
        $state['agreementSummary'] = '用户明确取消本轮 DeepSeek 评审；此状态不等同于双方达成共识。'
        $state['nextAction'] = 'cancelled'
        $state['taskTerminationReason'] = $reasonText
    }

    if (
        (Text $state['taskTerminalStatus']) -in @('completed', 'failed', 'cancelled', 'frozen') -or
        (Text $state['activationStatus']) -eq 'frozen'
    ) {
        RevokeAuthorization $state
    }

    if ($FreezeAudit) {
        $state['auditOnly'] = $true
        $state['sendStatus'] = '历史发送记录未验证'
        $state['activationStatus'] = 'unknown'
        $state['executionStatus'] = '禁止修改'
        $state['ownershipStatus'] = 'owned-historical'
        if ([string]::IsNullOrWhiteSpace($CodexThreadId)) {
            $state['ownershipStatus'] = 'unowned-historical'
        }
    }

    $state['stateRevision'] = ([long](Text $state['stateRevision'])) + 1
    $state['updatedAt'] = (Get-Date).ToString('o')
    AssertStateConsistency $state
    AssertSentConsistency $state
    WriteJson $statePath $state
    & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
    if ($HumanReadable) {
        Write-Output "状态已记录：$statePath"
    }
    else {
        Write-Verbose "状态已记录：$statePath"
    }
    $state | ConvertTo-Json -Depth 20
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
