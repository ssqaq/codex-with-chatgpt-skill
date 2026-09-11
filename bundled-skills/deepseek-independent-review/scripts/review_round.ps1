[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('RecordRound', 'ResolveDeadlock', 'Show')]
    [string]$Action,
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$ReviewBatch,
    [string]$UnresolvedIssues,
    [string]$CodexPosition,
    [string]$DeepSeekPosition,
    [switch]$HasNewEvidence,
    [switch]$ConsensusReached,
    [string]$UserDecision,
    [ValidateRange(2, 20)]
    [int]$DeadlockThreshold = 2,
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
    throw '缺少 CodexThreadId，禁止读取或修改无归属轮次状态。'
}

$statePath = Join-Path $StateDir "$TaskId.json"

function Text([object]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Trim()
}

function Truthy([object]$Value) {
    return (Text $Value) -in @('True', 'true', '1', 'yes')
}

function GetValue([object]$Object, [string]$Name) {
    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function SetDefault(
    [System.Collections.IDictionary]$State,
    [string]$Name,
    [object]$Value
) {
    if (-not $State.Contains($Name) -or $null -eq $State[$Name]) {
        $State[$Name] = $Value
    }
}

function ReadState {
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "找不到任务状态：$statePath"
    }
    $raw = [IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "任务状态为空：$statePath"
    }
    try {
        return $raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "任务状态 JSON 损坏，未修改原文件：$statePath。$($_.Exception.Message)"
    }
}

function WriteState([System.Collections.IDictionary]$State) {
    $expectedRevision = [long](Text $State['stateRevision']) - 1
    $diskState = ReadState
    $diskRevision = [long](Text $diskState['stateRevision'])
    if ($diskRevision -ne $expectedRevision) {
        throw "轮次状态发生并发变化，拒绝覆盖旧状态（期望 revision=$expectedRevision，实际 revision=$diskRevision）。"
    }
    $temporaryPath = "$statePath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $json = $State | ConvertTo-Json -Depth 30
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

        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            $backupPath = "$statePath.$PID.$([guid]::NewGuid().ToString('N')).bak"
            try {
                [IO.File]::Replace($temporaryPath, $statePath, $backupPath, $true)
            }
            finally {
                if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else {
            [IO.File]::Move($temporaryPath, $statePath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function NormalizeIssues([string]$Value) {
    $normalized = (Text $Value) -replace "`r`n?", "`n"
    $normalized = $normalized -replace '\s+', ' '
    return $normalized.Trim()
}

function IssueFingerprint([string]$Value) {
    $normalized = NormalizeIssues $Value
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return ''
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $hash = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function ParseBatch([string]$Value) {
    $batch = Text $Value
    if ($batch -notmatch '^(?<prefix>[CR])(?<number>[1-9][0-9]*)$') {
        throw 'ReviewBatch 必须是 C1…Cn 或 R1…Rn。'
    }
    return [pscustomobject]@{
        batch = $batch
        prefix = $Matches['prefix']
        number = [int]$Matches['number']
    }
}

function AssertOwnership([System.Collections.IDictionary]$State) {
    if ((Text $State['codexThreadId']) -ne $CodexThreadId) {
        throw '任务状态归属冲突，禁止操作其他 Codex thread。'
    }
}

function AssertActive([System.Collections.IDictionary]$State) {
    if ((Text $State['activationStatus']) -ne 'activated') {
        throw 'Skill 尚未真实激活，禁止记录评审轮次。'
    }
    if (
        (Text $State['taskTerminalStatus']) -in @('completed', 'failed', 'cancelled', 'frozen') -or
        (Truthy $State['reviewCancelled'])
    ) {
        throw '任务已终态或评审已取消，禁止记录新轮次。'
    }
}

function AssertBatchMatchesSkill(
    [System.Collections.IDictionary]$State,
    [pscustomobject]$Batch
) {
    $skill = Text $State['skillName']
    if ($skill -eq 'deepseek-consensus-review' -and $Batch.prefix -ne 'C') {
        throw '多轮共识评审必须使用 C1…Cn。'
    }
    if ($skill -eq 'deepseek-independent-review' -and $Batch.prefix -ne 'R') {
        throw '独立评审后续批次必须使用 R1…Rn。'
    }
}

function CalculateProgress([System.Collections.IDictionary]$State) {
    $score = 0
    if ((Text $State['activationStatus']) -eq 'activated') { $score += 10 }
    if ((Text $State['sessionBindingStatus']) -eq 'bound') { $score += 15 }
    if (
        (Text $State['lastReceiptStatus']) -eq 'confirmed' -or
        (Text $State['sendStatus']) -match '已收到'
    ) { $score += 15 }
    if ([int](Text $State['deepseekCompletedRounds']) -gt 0) { $score += 20 }
    if ([string]::IsNullOrWhiteSpace((Text $State['unresolvedIssues']))) { $score += 10 }
    if ((Text $State['consensusStatus']) -eq '已达成') { $score += 15 }
    if ((Text $State['codexSummaryStatus']) -eq '已完成') { $score += 5 }
    if ((Text $State['checkResult']) -eq '无问题') { $score += 5 }
    if ((Text $State['planStatus']) -eq '已敲定') { $score += 5 }
    if (Truthy $State['decisionDeadlock']) {
        $score = [Math]::Min($score, 70)
    }
    return [Math]::Min($score, 100)
}

function RoundResult(
    [string]$Status,
    [System.Collections.IDictionary]$State
) {
    [pscustomobject]@{
        status = $Status
        taskId = $TaskId
        codexThreadId = $CodexThreadId
        reviewBatch = Text $State['reviewBatch']
        completedRounds = Text $State['deepseekCompletedRounds']
        repeatedDisagreementRounds = Text $State['repeatedDisagreementRounds']
        deadlockThreshold = Text $State['deadlockThreshold']
        decisionDeadlock = (Truthy $State['decisionDeadlock'])
        decisionDeadlockReason = (Text $State['decisionDeadlockReason'])
        consensusStatus = (Text $State['consensusStatus'])
        executionStatus = (Text $State['executionStatus'])
        unresolvedIssues = (Text $State['unresolvedIssues'])
        nextAction = (Text $State['nextAction'])
        roundProgressPercent = (Text $State['roundProgressPercent'])
        roundHistoryCount = @($State['roundHistory']).Count
        statePath = $statePath
    }
}

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
        throw '无法取得轮次状态锁。'
    }

    $state = ReadState
    AssertOwnership $state
    SetDefault $state 'stateRevision' 0

    $roundDefaults = [ordered]@{
        roundTrackingVersion = '1'
        roundHistory = @()
        deadlockResolutionHistory = @()
        unresolvedIssueFingerprint = ''
        repeatedDisagreementRounds = '0'
        deadlockThreshold = "$DeadlockThreshold"
        decisionDeadlock = 'false'
        decisionDeadlockReason = ''
        lastDecisionDeadlockReason = ''
        deadlockDetectedAt = ''
        deadlockResolvedAt = ''
        userDecision = ''
        nextAction = 'record-next-round'
        roundProgressPercent = '0'
    }
    foreach ($entry in $roundDefaults.GetEnumerator()) {
        SetDefault $state $entry.Key $entry.Value
    }

    switch ($Action) {
        'Show' {
            RoundResult 'round-state' $state | ConvertTo-Json -Depth 20
            break
        }

        'ResolveDeadlock' {
            AssertActive $state
            if (-not (Truthy $state['decisionDeadlock'])) {
                throw '当前任务没有决策僵局，不需要解除。'
            }
            if (
                [string]::IsNullOrWhiteSpace((Text $UserDecision)) -and
                -not $HasNewEvidence
            ) {
                throw '解除僵局必须提供用户裁决或明确存在新证据。'
            }

            $resolvedAt = (Get-Date).ToString('o')
            $resolutionHistory = @($state['deadlockResolutionHistory'])
            $resolutionHistory += [ordered]@{
                resolvedAt = $resolvedAt
                reviewBatch = Text $state['reviewBatch']
                previousReason = Text $state['decisionDeadlockReason']
                userDecision = Text $UserDecision
                hasNewEvidence = [bool]$HasNewEvidence
            }
            $state['deadlockResolutionHistory'] = $resolutionHistory
            $state['lastDecisionDeadlockReason'] = Text $state['decisionDeadlockReason']
            $state['decisionDeadlock'] = 'false'
            $state['decisionDeadlockReason'] = ''
            $state['deadlockResolvedAt'] = $resolvedAt
            $state['userDecision'] = Text $UserDecision
            $state['repeatedDisagreementRounds'] = '0'
            $state['consensusStatus'] = '进行中'
            $state['roundStatus'] = '僵局已解除，等待下一轮核对'
            $state['executionStatus'] = '禁止修改'
            $state['planStatus'] = '未敲定'
            $state['nextAction'] = 'continue-review'
            $state['stateRevision'] = ([long](Text $state['stateRevision'])) + 1
            $state['roundProgressPercent'] = "$(CalculateProgress $state)"
            $state['updatedAt'] = $resolvedAt
            WriteState $state
            & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
            RoundResult 'deadlock-resolved' $state | ConvertTo-Json -Depth 20
            break
        }

        'RecordRound' {
            AssertActive $state
            if (Truthy $state['decisionDeadlock']) {
                throw '当前处于决策僵局，必须先 ResolveDeadlock，禁止直接追加轮次绕过用户裁决。'
            }
            if (
                [string]::IsNullOrWhiteSpace((Text $CodexPosition)) -or
                [string]::IsNullOrWhiteSpace((Text $DeepSeekPosition))
            ) {
                throw '记录轮次必须同时提供 CodexPosition 和 DeepSeekPosition。'
            }

            $batch = ParseBatch $ReviewBatch
            AssertBatchMatchesSkill $state $batch
            $issues = NormalizeIssues $UnresolvedIssues
            if ($ConsensusReached -and -not [string]::IsNullOrWhiteSpace($issues)) {
                throw '仍有未解决分歧时不能标记已达成共识。'
            }

            $fingerprint = IssueFingerprint $issues
            $history = @($state['roundHistory'])
            $existing = @(
                $history | Where-Object {
                    (Text (GetValue $_ 'batch')) -eq $batch.batch
                } | Select-Object -First 1
            )[0]
            if ($null -ne $existing) {
                $same = (
                    (Text (GetValue $existing 'unresolvedFingerprint')) -eq $fingerprint -and
                    (Text (GetValue $existing 'codexPosition')) -eq (Text $CodexPosition) -and
                    (Text (GetValue $existing 'deepSeekPosition')) -eq (Text $DeepSeekPosition) -and
                    [bool](GetValue $existing 'hasNewEvidence') -eq [bool]$HasNewEvidence -and
                    [bool](GetValue $existing 'consensusReached') -eq [bool]$ConsensusReached
                )
                if (-not $same) {
                    throw "轮次 $($batch.batch) 已存在不同内容，禁止静默覆盖。"
                }
                RoundResult 'round-already-recorded' $state | ConvertTo-Json -Depth 20
                break
            }

            if ($history.Count -gt 0) {
                $lastNumber = [int](GetValue $history[-1] 'roundNumber')
                if ($batch.number -le $lastNumber) {
                    throw "轮次必须向前递增；上一轮为 $lastNumber，当前为 $($batch.number)。"
                }
            }
            else {
                $currentBatch = Text $state['reviewBatch']
                if ($currentBatch -match '^[CR](?<number>[1-9][0-9]*)$') {
                    $currentNumber = [int]$Matches['number']
                    if ($batch.number -lt $currentNumber) {
                        throw "轮次不能从 $currentBatch 倒退到 $($batch.batch)。"
                    }
                }
            }

            $repeatCount = 0
            if (-not [string]::IsNullOrWhiteSpace($issues)) {
                $repeatCount = 1
                if ($history.Count -gt 0) {
                    $previous = $history[-1]
                    if (
                        (Text (GetValue $previous 'unresolvedFingerprint')) -eq $fingerprint -and
                        -not $HasNewEvidence
                    ) {
                        $previousRepeat = [int](GetValue $previous 'repeatedDisagreementRounds')
                        $repeatCount = [Math]::Max(1, $previousRepeat + 1)
                    }
                }
            }

            $isDeadlock = (
                -not $ConsensusReached -and
                -not [string]::IsNullOrWhiteSpace($issues) -and
                -not $HasNewEvidence -and
                $repeatCount -ge $DeadlockThreshold
            )
            $recordedAt = (Get-Date).ToString('o')
            $history += [ordered]@{
                batch = $batch.batch
                roundNumber = $batch.number
                recordedAt = $recordedAt
                unresolvedIssues = $issues
                unresolvedFingerprint = $fingerprint
                repeatedDisagreementRounds = $repeatCount
                hasNewEvidence = [bool]$HasNewEvidence
                consensusReached = [bool]$ConsensusReached
                codexPosition = Text $CodexPosition
                deepSeekPosition = Text $DeepSeekPosition
            }

            $state['roundTrackingVersion'] = '1'
            $state['roundHistory'] = $history
            $state['reviewBatch'] = $batch.batch
            $state['deepseekCompletedRounds'] = "$($batch.number)"
            $state['unresolvedIssues'] = $issues
            $state['unresolvedIssueFingerprint'] = $fingerprint
            $state['repeatedDisagreementRounds'] = "$repeatCount"
            $state['deadlockThreshold'] = "$DeadlockThreshold"
            $state['codexPosition'] = Text $CodexPosition
            $state['deepSeekPosition'] = Text $DeepSeekPosition
            $state['decisionDeadlock'] = if ($isDeadlock) { 'true' } else { 'false' }
            $state['executionStatus'] = '禁止修改'
            $state['checkResult'] = '待检查'

            if ($ConsensusReached) {
                $state['consensusStatus'] = '已达成'
                $state['roundStatus'] = '本轮完成，已达成共识'
                $state['decisionDeadlockReason'] = ''
                $state['nextAction'] = 'complete-codex-summary'
            }
            elseif ($isDeadlock) {
                $reason = "连续 $repeatCount 轮相同实质分歧且没有新证据：$issues"
                $state['consensusStatus'] = '决策僵局'
                $state['roundStatus'] = '决策僵局，等待用户裁决'
                $state['decisionDeadlockReason'] = $reason
                $state['deadlockDetectedAt'] = $recordedAt
                $state['planStatus'] = '待用户裁决'
                $state['nextAction'] = 'await-user-decision'
            }
            else {
                $state['consensusStatus'] = '进行中'
                $state['roundStatus'] = if ([string]::IsNullOrWhiteSpace($issues)) {
                    '本轮完成，等待确认共识'
                }
                else {
                    '本轮完成，仍有分歧'
                }
                $state['decisionDeadlockReason'] = ''
                $state['nextAction'] = if ([string]::IsNullOrWhiteSpace($issues)) {
                    'confirm-consensus'
                }
                else {
                    'continue-review'
                }
            }

            $state['stateRevision'] = ([long](Text $state['stateRevision'])) + 1
            $state['roundProgressPercent'] = "$(CalculateProgress $state)"
            $state['updatedAt'] = $recordedAt
            WriteState $state
            & (Join-Path $PSScriptRoot 'review_checkpoint.ps1') -Action Save -TaskId $TaskId -CodexThreadId $CodexThreadId -StateDir $StateDir | Out-Null
            RoundResult $(if ($isDeadlock) { 'deadlock-detected' } else { 'round-recorded' }) $state |
                ConvertTo-Json -Depth 20
            break
        }
    }
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
