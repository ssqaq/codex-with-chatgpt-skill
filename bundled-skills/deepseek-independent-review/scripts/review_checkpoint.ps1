[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Save','Restore','Revalidate')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$TaskId,
    [Parameter(Mandatory)][string]$CodexThreadId,
    [Parameter(Mandatory)][string]$StateDir,
    [string]$EvidenceFile
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$file = Join-Path $StateDir "$TaskId.json"
$checkpoint = Join-Path $StateDir "$TaskId.checkpoint.json"
$scope = ([IO.Path]::GetFullPath($StateDir).TrimEnd('\') + '|' + $TaskId).ToLowerInvariant()
$hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($scope))).Substring(0,24)
$mutex = [Threading.Mutex]::new($false, "Global\CodexDeepSeekReviewTaskStateV6-$hash")
$owned = $false
function Read([string]$path) { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
function WriteCheckpointJson([string]$path, $value) {
    $tmp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($value | ConvertTo-Json -Depth 35), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($tmp, $path, $true)
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}
function Own($value) {
    if ($value.taskId -ne $TaskId -or $value.codexThreadId -ne $CodexThreadId) { throw '恢复记录不属于当前任务。' }
}
try {
    try { $owned = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { throw '无法取得当前任务的恢复锁。' }
    if ($Action -eq 'Save') {
        $state = Read $file
        Own $state
        # Only task identity, short review summaries and receipt metadata. No leases or authorization text.
        $fields = ('taskId codexThreadId skillName reviewBatch stateRevision activationStatus taskTerminalStatus reviewCancelled sessionBindingStatus sessionOwner targetUrl browserSurface browserTabId browserRuntimeId runtimeEpoch bindingRevision deepseekSessionId deepseekSessionTitle conversationUrl domMessageMarker model reasoning searchMode pendingReceipt auditRisk resendBlocked auditOnly lastReceiptStatus sendPhase domMessagePresence submissionStatus submissionMechanism domSendControl domInputPresence domInputEnabled lastOpenTabsEvidence lastTabsListEvidence browserConfirmationStatus lastMessageFingerprint browserActionAt sendOwnerTaskId deepseekCompletedRounds deepseekStatus deepSeekPosition codexPosition agreementSummary unresolvedIssues consensusStatus codexSummaryStatus checkResult planStatus executionStatus nextAction decisionDeadlock repeatedDisagreementRounds unresolvedIssueFingerprint roundTrackingVersion roundStatus resolvedCount totalIssues createdAt updatedAt') -split ' '
        $safe = [ordered]@{}
        foreach ($key in $fields) { if ($state.Contains($key)) { $safe[$key] = $state[$key] } }
        $safe.roundHistory = @($state.roundHistory | ForEach-Object {
            $row = [ordered]@{}
            foreach ($key in @('batch','roundNumber','recordedAt','consensusReached','codexPosition','deepSeekPosition','unresolvedIssues','hasNewEvidence','repeatedDisagreementRounds','resolvedCount','totalIssues')) {
                if ($null -ne $_ -and $_.Contains($key)) { $row[$key] = $_[$key] }
            }
            $row
        })
        WriteCheckpointJson $checkpoint @{schemaVersion=1; savedAt=[DateTimeOffset]::UtcNow.ToString('o'); state=$safe}
    } elseif ($Action -eq 'Restore') {
        $healthy = $null
        try { $healthy = Read $file } catch { }
        if ($null -ne $healthy) { Own $healthy; @{ok=$true;status='already-readable'} | ConvertTo-Json -Compress; return }
        $saved = Read $checkpoint
        if ($saved.schemaVersion -ne 1) { throw '恢复记录格式无效。' }
        $state = $saved.state
        Own $state
        if ($state.reviewBatch -notmatch '^[CR][1-9][0-9]*$') { throw '恢复记录没有有效轮次。' }
        if (Test-Path -LiteralPath $file) { Copy-Item -LiteralPath $file -Destination "$file.$([guid]::NewGuid().ToString('N')).damaged" }
        $state.reviewRecoveryRequired = $true
        $state.executionStatus = '禁止修改'
        $state.codexSummaryStatus = '待检查'
        $state.checkResult = '待检查'
        $state.sendAuthorization = 'none'
        $state.nextAction = 'revalidate-recovered-page'
        WriteCheckpointJson $file $state
    } else {
        $state = Read $file
        Own $state
        if (-not $state.reviewRecoveryRequired) { throw '当前任务不需要恢复核验。' }
        $e = Read $EvidenceFile
        $captured = if ($e.capturedAt -is [datetime]) { [DateTimeOffset]$e.capturedAt } else { [DateTimeOffset]::Parse($e.capturedAt) }
        $age = ([DateTimeOffset]::UtcNow - $captured).TotalSeconds
        if ($e.source -ne 'codex-in-app-browser' -or -not $e.observationId -or $age -gt 30 -or $age -lt -5) { throw '必须使用内置浏览器刚读取的原页面。' }
        if ($e.taskId -ne $TaskId -or $e.codexThreadId -ne $CodexThreadId -or $e.round -ne [long]$state.reviewBatch.Substring(1)) { throw '网页核验属于其他任务或轮次。' }
        $registry = Read (Join-Path $StateDir 'thread-bindings.json')
        $matches = @($registry.bindings | Where-Object { $_.codexThreadId -eq $CodexThreadId })
        if ($matches.Count -ne 1) { throw '原会话绑定不能唯一确认。' }
        $b = $matches[0]
        if ($b.activeTaskId -ne $TaskId -or $b.status -ne 'bound' -or $state.taskTerminalStatus -ne 'active') { throw '原任务已结束或绑定已变化，不能恢复执行。' }
        foreach ($key in @('deepseekSessionId','browserTabId','browserRuntimeId','runtimeEpoch')) {
            if (-not $e[$key] -or [string]$e[$key] -cne [string]$b[$key] -or [string]$state[$key] -cne [string]$b[$key]) { throw '网页、原绑定和恢复记录不一致。' }
        }
        $pageUrl = [uri]$e.domTargetUrl
        if ($e.browserSurface -ne 'codex-in-app-sidebar' -or $pageUrl.Scheme -ne 'https' -or $pageUrl.Host -ne 'chat.deepseek.com' -or
            $pageUrl.UserInfo -or -not $pageUrl.IsDefaultPort -or $pageUrl.AbsoluteUri -cne ([uri]$state.conversationUrl).AbsoluteUri -or
            $e.messagePresence -ne 'present' -or $e.messageFingerprint -ne $state.lastMessageFingerprint -or
            $b.lastMessageFingerprint -ne $state.lastMessageFingerprint -or $e.domMessageMarker -ne $state.domMessageMarker -or
            $e.domModel -notin @('网页当前模型（合并升级版）','专家模式') -or
            $e.domReasoning -ne '深度思考' -or $e.domSearch -ne '智能搜索') { throw '尚未在原网页核对到本轮消息和设置，不能恢复。' }
        $state.reviewRecoveryRequired = $false
        $state.nextAction = 'read-current-round-reply'
        WriteCheckpointJson $file $state
    }
    @{ok=$true;action=$Action;taskId=$TaskId;round=$state.reviewBatch;canExecute=$false} | ConvertTo-Json -Compress
} catch {
    if ($_.Exception.Message -match '^(恢复记录不属于|恢复记录格式|恢复记录没有|当前任务不需要|必须使用内置|网页核验属于|原会话绑定|原任务已结束|网页、原绑定|尚未在原网页|无法取得当前任务)') { throw $_.Exception.Message }
    throw '保存或恢复检查点失败；保留原任务，未获得发送或执行权限。'
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
