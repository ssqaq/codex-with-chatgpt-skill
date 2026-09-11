[CmdletBinding()]
param(
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [ValidateSet('Markdown', 'Json')]
    [string]$Format = 'Markdown',
    [string]$StateDir,
    [switch]$AllThreads
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

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

function Normalize-Thread([string]$Value) {
    $text = Text $Value
    if ($text -match '^codex://threads/([^/?#]+)') {
        return $Matches[1]
    }
    return $text
}

function Safe-Text([object]$Value, [int]$Limit = 240) {
    $text = Text $Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '无' }
    $text = $text -replace '(?i)(password|passwd|secret|token|cookie|api[_-]?key|access[_-]?key)\s*[:=]\s*[^;\s,]+', '$1=<redacted>'
    $text = $text -replace '(?i)\b(?:gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+\b', '<redacted>'
    $text = $text -replace '\|', '｜' -replace "`r?`n", '；'
    if ($text.Length -gt $Limit) { return $text.Substring(0, $Limit) + '…' }
    return $text
}

function Read-Json([string]$Path) {
    try {
        $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Choose([object]$Primary, [object]$Fallback) {
    $primaryText = Text $Primary
    if (-not [string]::IsNullOrWhiteSpace($primaryText)) { return $primaryText }
    return Text $Fallback
}

$CodexThreadId = Normalize-Thread $CodexThreadId
if (-not $AllThreads -and [string]::IsNullOrWhiteSpace($CodexThreadId)) {
    throw '缺少 CodexThreadId；如需查看全部 thread，请显式使用 -AllThreads。'
}
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
    throw "找不到状态目录：$StateDir"
}

$registry = Read-Json (Join-Path $StateDir 'thread-bindings.json')
$bindings = if ($null -eq $registry) { @() } else { @($registry.bindings) }
$stateFiles = @(
    Get-ChildItem -LiteralPath $StateDir -File -Filter '*.json' -Force |
        Where-Object {
            $_.Name -notin @('thread-bindings.json', 'browser-lease.json', 'browser-lease-epoch.json') -and
            $_.Name -notlike 'browser-lease.*.json' -and
            $_.Name -notlike 'browser-lease-epoch.*.json' -and
            $_.Name -notlike 'workflow-transaction.*.json' -and
            $_.Name -notmatch '\.bak$'
        }
)

$rows = @(
    foreach ($file in $stateFiles) {
        $state = Read-Json $file.FullName
        if ($null -eq $state) { continue }
        $thread = Normalize-Thread (Prop $state 'codexThreadId')
        if (-not $AllThreads -and $thread -ne $CodexThreadId) { continue }
        $task = Prop $state 'taskId'
        if ([string]::IsNullOrWhiteSpace($task)) {
            $task = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        }
        $bindingCandidates = @(
            $bindings | Where-Object {
                (Normalize-Thread (Prop $_ 'codexThreadId')) -eq $thread -and
                (
                    (Prop $_ 'activeTaskId') -eq $task -or
                    (Prop $_ 'taskId') -eq $task
                )
            }
        )
        $binding = if ($bindingCandidates.Count -eq 1) { $bindingCandidates[0] } else { $null }
        $pending = (
            (Truthy (Prop $state 'pendingReceipt')) -or
            ($null -ne $binding -and (Truthy (Prop $binding 'pendingReceipt')))
        )
        $auditRisk = (
            (Truthy (Prop $state 'auditRisk')) -or
            ($null -ne $binding -and (Truthy (Prop $binding 'auditRisk')))
        )
        if (-not ($pending -or $auditRisk)) { continue }

        $reason = Choose (Prop $state 'browserToolFailureReason') (Prop $state 'auditRiskReason')
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = Choose (Prop $state 'sessionLost') (Prop $state 'taskTerminationReason')
        }
        if ([string]::IsNullOrWhiteSpace($reason)) {
            $reason = Choose (Prop $state 'nextAction') '等待人工核验'
        }
        $receipt = Choose (Prop $state 'lastReceiptStatus') $(if ($null -eq $binding) { '' } else { Prop $binding 'lastReceiptStatus' })
        $terminal = Prop $state 'taskTerminalStatus'
        $bindingStatus = if ($null -eq $binding) {
            Prop $state 'sessionBindingStatus'
        } else {
            Prop $binding 'status'
        }

        [pscustomobject][ordered]@{
            taskId             = $task
            codexThreadId      = $thread
            pendingReceipt     = $pending
            auditRisk          = $auditRisk
            taskTerminalStatus = $terminal
            bindingStatus      = $bindingStatus
            sendPhase          = Choose (Prop $state 'sendPhase') $(if ($null -eq $binding) { '' } else { Prop $binding 'sendPhase' })
            lastReceiptStatus  = $receipt
            freezeReason       = Safe-Text $reason
            nextAction         = Safe-Text (Prop $state 'nextAction')
            updatedAt          = Choose (Prop $state 'updatedAt') $file.LastWriteTimeUtc.ToString('o')
            messageEvidence   = (
                -not [string]::IsNullOrWhiteSpace((Prop $state 'pendingMessageFingerprint')) -or
                -not [string]::IsNullOrWhiteSpace((Prop $state 'lastMessageFingerprint'))
            )
            bindingConflict    = ($bindingCandidates.Count -gt 1)
        }
    }
)

$result = [pscustomobject][ordered]@{
    status       = 'PENDING_RECEIPT_PANEL_OK'
    scope        = if ($AllThreads) { 'all-threads' } else { $CodexThreadId }
    total        = $rows.Count
    blocked      = @($rows | Where-Object { $_.pendingReceipt -or $_.auditRisk }).Count
    safeFields   = '不输出消息正文、fingerprint、lease token、账号、密码、Token 或密钥'
    rows         = $rows
}

if ($Format -eq 'Json') {
    $result | ConvertTo-Json -Depth 12
    exit 0
}

$lines = @(
    '| Task | Codex thread | 待回执/风险 | 回执 | 冻结原因 | 下一步 |'
    '|------|--------------|--------------|------|----------|--------|'
)
foreach ($row in $rows) {
    $risk = "pending=$($row.pendingReceipt)，audit=$($row.auditRisk)"
    $lines += "| $(Safe-Text $row.taskId) | $(Safe-Text $row.codexThreadId) | $risk | $(Safe-Text $row.lastReceiptStatus) | $(Safe-Text $row.freezeReason) | $(Safe-Text $row.nextAction) |"
}
if ($rows.Count -eq 0) {
    $lines += '| 无 | 无 | 无 | 无 | 当前范围没有 pendingReceipt 或 auditRisk | 无 |'
}
$lines += ''
$lines += "待处理数量：$($rows.Count)"
$lines += '安全说明：不输出消息正文、fingerprint、lease token、账号、密码、Token 或密钥。'
$lines -join "`n"
