[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')]
    [string]$TaskId,
    [Parameter(Mandatory)]
    [ValidateSet('deepseek-consensus-review', 'deepseek-independent-review')]
    [string]$SkillName,
    [string]$TaskName,
    [string]$CodexThreadId = $env:CODEX_THREAD_ID,
    [string]$StateDir,
    [ValidateRange(1, 60000)]
    [int]$SlowPathThresholdMs = 2000
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
    throw '缺少 CodexThreadId，禁止激活无归属 Skill。'
}

$started = [Diagnostics.Stopwatch]::StartNew()
$statePath = Join-Path $StateDir "$TaskId.json"
$mode = 'new'
$slowPathReason = ''
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $old = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$old.codexThreadId -ne $CodexThreadId) {
        $mode = 'conflict'
        $slowPathReason = 'task-owned-by-other-thread'
        throw 'TaskId 已属于另一个 Codex thread。'
    }
    $mode = 'resume'
}

$statusScript = Join-Path $PSScriptRoot 'update_review_status.ps1'
$reviewBatch = if ($SkillName -eq 'deepseek-independent-review') { 'R1' } else { 'C1' }
$stateJson = & $statusScript `
    -TaskId $TaskId `
    -TaskName $TaskName `
    -CodexThreadId $CodexThreadId `
    -StateDir $StateDir `
    -SkillName $SkillName `
    -ReviewBatch $reviewBatch `
    -ActivationStatus activated `
    -ActivationEvidence 'activate_review.ps1 幂等激活' `
    -TargetUrl 'https://chat.deepseek.com/' `
    -Model '网页当前模型（合并升级版）' `
    -SearchMode '智能搜索' `
    -Reasoning '深度思考' `
    -SendAuthorization workflow-authorized `
    -AuthorizationScope '本次 DeepSeek 评审流程' `
    -AuthorizationEvidence '用户显式调用 DeepSeek Skill'
$state = $stateJson | ConvertFrom-Json
$started.Stop()
$activationElapsedMs = [math]::Round($started.Elapsed.TotalMilliseconds, 2)
$slowPathAlert = $activationElapsedMs -gt $SlowPathThresholdMs
$slowPathReason = ''
$slowPathRecordStatus = 'not-needed'
$slowPathRecordErrorType = ''
if ($slowPathAlert) {
    $slowPathReason = "activation-over-$SlowPathThresholdMs-ms"
    try {
        & $statusScript `
            -TaskId $TaskId `
            -CodexThreadId $CodexThreadId `
            -StateDir $StateDir `
            -ActivationElapsedMs ([string]$activationElapsedMs) `
            -ActivationSlowPathAlert 'true' `
            -ActivationSlowPathThresholdMs ([string]$SlowPathThresholdMs) `
            -ActivationSlowPathReason $slowPathReason | Out-Null
        $slowPathRecordStatus = 'state-recorded'
    }
    catch {
        $slowPathRecordStatus = 'state-record-failed'
        $slowPathRecordErrorType = $_.Exception.GetType().Name
        New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
        $alertLog = Join-Path $StateDir 'activation-slow-path.log'
        $alertLine = @(
            (Get-Date).ToString('o'),
            "taskId=$TaskId",
            "codexThreadId=$CodexThreadId",
            "skillName=$SkillName",
            "elapsedMs=$activationElapsedMs",
            "thresholdMs=$SlowPathThresholdMs",
            "reason=$slowPathReason",
            "recordErrorType=$slowPathRecordErrorType"
        ) -join "`t"
        Add-Content -LiteralPath $alertLog -Value $alertLine -Encoding UTF8
    }
}

[pscustomobject][ordered]@{
    status = 'REVIEW_ACTIVATED'
    taskId = $TaskId
    codexThreadId = $CodexThreadId
    skillName = $SkillName
    activationMode = $mode
    activationElapsedMs = $activationElapsedMs
    claimElapsedMs = 0
    activationSlowPathAlert = $slowPathAlert
    activationSlowPathThresholdMs = $SlowPathThresholdMs
    activationSlowPathRecordStatus = $slowPathRecordStatus
    activationSlowPathRecordErrorType = $slowPathRecordErrorType
    slowPathReason = $slowPathReason
    statePath = $statePath
    activationStatus = $state.activationStatus
    targetUrl = $state.targetUrl
    model = $state.model
    reasoning = $state.reasoning
    reviewBatch = $state.reviewBatch
} | ConvertTo-Json -Depth 8
