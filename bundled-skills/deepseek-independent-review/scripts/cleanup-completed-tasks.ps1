[CmdletBinding()]
param(
    [string]$StateDir,
    [ValidateRange(1, 3650)]
    [int]$RetentionDays = 7,
    [string]$ReferenceTime,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$TaskId,
    [switch]$Delete,
    [ValidateSet('Markdown', 'Json')]
    [string]$Format = 'Markdown'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$CleanupMutexName = 'Global\CodexDeepSeekReviewStateCleanupV1'
$ProtectedNames = @(
    'thread-bindings.json',
    'browser-lease.json',
    'browser-lease-epoch.json'
)

function Is-ProtectedStateFileName([string]$Name) {
    $nameText = Text $Name
    return (
        $nameText -in $ProtectedNames -or
        $nameText -match '^browser-lease(?:-epoch)?\.[A-Za-z0-9._-]+\.json$'
    )
}

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

function Read-JsonStrict([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "状态文件为空：$([IO.Path]::GetFileName($Path))"
    }
    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        throw "状态文件 JSON 损坏：$([IO.Path]::GetFileName($Path))"
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

function Safe-Name([string]$Value) {
    return [regex]::Replace((Text $Value), '[^A-Za-z0-9._-]', '_')
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText(
        $Path,
        $Content.TrimEnd() + "`r`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-Unique([System.Collections.Generic.HashSet[string]]$Set, [string]$Value) {
    $valueText = Text $Value
    if (-not [string]::IsNullOrWhiteSpace($valueText)) {
        [void]$Set.Add($valueText)
    }
}

function Acquire-CleanupMutex {
    $mutex = [Threading.Mutex]::new($false, $CleanupMutexName)
    $owned = $false
    try {
        try {
            $owned = $mutex.WaitOne(0)
        }
        catch [Threading.AbandonedMutexException] {
            $owned = $true
        }
        if (-not $owned) {
            $mutex.Dispose()
            throw '另一个状态清理任务正在运行，本次拒绝并发执行。'
        }
        return $mutex
    }
    catch {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        throw
    }
}

$CodexThreadId = Normalize-Thread $CodexThreadId
if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\deepseek-review-state'
}
$StateDir = [IO.Path]::GetFullPath($StateDir)
if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
    $empty = [ordered]@{
        status = if ($Delete) { 'STATE_CLEANUP_DELETE_OK' } else { 'STATE_CLEANUP_PREVIEW_OK' }
        mode = if ($Delete) { 'delete' } else { 'preview' }
        stateDir = $StateDir
        retentionDays = $RetentionDays
        candidates = @()
        deleted = @()
        skipped = @()
        counts = [ordered]@{ scanned = 0; candidates = 0; deleted = 0; skipped = 0 }
    }
    $empty | ConvertTo-Json -Depth 12
    exit 0
}

$reference = if ([string]::IsNullOrWhiteSpace($ReferenceTime)) {
    [datetimeoffset]::Now
}
else {
    $parsedReference = Parse-Instant $ReferenceTime
    if ($null -eq $parsedReference) {
        throw 'ReferenceTime 不是有效的 ISO 时间。'
    }
    $parsedReference
}
$cutoff = $reference.AddDays(-$RetentionDays)
$mutex = Acquire-CleanupMutex
try {
    $protectedTaskIds = [System.Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase
    )
    Add-Unique $protectedTaskIds $TaskId

    $registryPath = Join-Path $StateDir 'thread-bindings.json'
    if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
        $registry = Read-JsonStrict $registryPath
        foreach ($binding in @($registry.bindings)) {
            $bindingThread = Prop $binding 'codexThreadId'
            $activeTask = Prop $binding 'activeTaskId'
            if ([string]::IsNullOrWhiteSpace($activeTask)) {
                $activeTask = Prop $binding 'taskId'
            }
            if (
                -not [string]::IsNullOrWhiteSpace($activeTask) -and
                (
                    [string]::IsNullOrWhiteSpace($CodexThreadId) -or
                    $bindingThread -eq $CodexThreadId -or
                    (Prop $binding 'status') -in @('bound', 'bootstrap-pending', 'lost', 'recovery-pending')
                )
            ) {
                Add-Unique $protectedTaskIds $activeTask
            }
        }
    }

    $leasePaths = @(
        Get-ChildItem -LiteralPath $StateDir -File -Filter 'browser-lease*.json' -ErrorAction SilentlyContinue
    )
    foreach ($leaseFile in $leasePaths) {
        $lease = Read-JsonStrict $leaseFile.FullName
        foreach ($leaseField in @('taskId', 'activeTaskId', 'ownerTaskId')) {
            Add-Unique $protectedTaskIds (Prop $lease $leaseField)
        }
    }

    $candidates = [System.Collections.Generic.List[object]]::new()
    $deleted = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()
    $taskFiles = @(
        Get-ChildItem -LiteralPath $StateDir -File -Filter '*.json' |
            Where-Object { -not (Is-ProtectedStateFileName $_.Name) }
    )

    foreach ($file in $taskFiles) {
        $id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = '文件名不是任务状态格式'
            })
            continue
        }
        try {
            $state = Read-JsonStrict $file.FullName
        }
        catch {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = $_.Exception.Message
            })
            continue
        }
        if ((Prop $state 'taskTerminalStatus') -ne 'completed') {
            continue
        }
        $completionTime = $null
        foreach ($field in @('completedAt', 'taskCompletedAt', 'updatedAt')) {
            $completionTime = Parse-Instant (Prop $state $field)
            if ($null -ne $completionTime) {
                break
            }
        }
        if ($null -eq $completionTime) {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = 'completed 任务缺少有效完成时间'
            })
            continue
        }
        if ($completionTime -ge $cutoff) {
            continue
        }
        if ($protectedTaskIds.Contains($id)) {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = '仍被当前绑定或 lease 保护'
            })
            continue
        }
        if (Truthy (Prop $state 'pendingReceipt')) {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = '存在 pendingReceipt'
            })
            continue
        }
        if (Truthy (Prop $state 'auditRisk')) {
            [void]$skipped.Add([ordered]@{
                taskId = $id
                file = $file.Name
                reason = '存在 auditRisk'
            })
            continue
        }
        $item = [ordered]@{
            taskId = $id
            file = $file.Name
            completedAt = $completionTime.ToUniversalTime().ToString('o')
            ageDays = [math]::Round(($reference - $completionTime).TotalDays, 2)
            action = if ($Delete) { 'delete' } else { 'preview-delete' }
        }
        if ($Delete) {
            Remove-Item -LiteralPath $file.FullName -Force
            [void]$deleted.Add($item)
        }
        else {
            [void]$candidates.Add($item)
        }
    }

    $result = [ordered]@{
        status = if ($Delete) { 'STATE_CLEANUP_DELETE_OK' } else { 'STATE_CLEANUP_PREVIEW_OK' }
        mode = if ($Delete) { 'delete' } else { 'preview' }
        stateDir = $StateDir
        referenceTime = $reference.ToUniversalTime().ToString('o')
        retentionDays = $RetentionDays
        cutoff = $cutoff.ToUniversalTime().ToString('o')
        protectedTaskCount = $protectedTaskIds.Count
        candidates = @($candidates)
        deleted = @($deleted)
        skipped = @($skipped)
        counts = [ordered]@{
            scanned = $taskFiles.Count
            candidates = $candidates.Count
            deleted = $deleted.Count
            skipped = $skipped.Count
        }
    }

    if ($Format -eq 'Json') {
        $result | ConvertTo-Json -Depth 15
    }
    else {
        $lines = @(
            '| 项目 | 值 |'
            '|------|----|'
            "| 模式 | $($result.mode) |"
            "| 保留天数 | $($result.retentionDays) |"
            "| 截止时间 | $($result.cutoff) |"
            "| 扫描 | $($result.counts.scanned) |"
            "| 可清理 | $($result.counts.candidates) |"
            "| 已删除 | $($result.counts.deleted) |"
            "| 跳过 | $($result.counts.skipped) |"
            ''
            '安全规则：只处理 taskTerminalStatus=completed 的任务 JSON；默认预览；不碰绑定、lease、审计、失败和活跃任务。'
        )
        $lines -join "`n"
        $result | ConvertTo-Json -Depth 15
    }
}
finally {
    if ($null -ne $mutex) {
        try {
            $mutex.ReleaseMutex() | Out-Null
        }
        catch {
        }
        $mutex.Dispose()
    }
}
exit 0
