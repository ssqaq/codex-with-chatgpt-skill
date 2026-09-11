[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$TaskId,
    [Parameter(Mandatory)][string]$CodexThreadId,
    [Parameter(Mandatory)][string]$MessageFile,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$RoundNumber,
    [Parameter(Mandatory)][string]$EvidenceFile,
    [string]$AuthorizationEvidence,
    [ValidateSet('action-time-user-response','browser-tool-token')][string]$AuthorizationSource = 'action-time-user-response',
    [string]$LeaseToken,
    [long]$LeaseEpoch = -1,
    [int]$ResolvedCount = -1,
    [int]$TotalIssues = -1,
    [string]$StateDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex/deepseek-review-state'),
    [string]$SkillRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$CheckOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$stage = 'precheck'
function Fail([string]$message) { throw $message }
function Text($value) { return ([string]$value).Trim() }
function Hash([string]$value) { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($value))).ToLowerInvariant() }
function Native([string]$action, [hashtable]$arguments) {
    $scriptPath = Join-Path $SkillRoot 'scripts/session_binding.ps1'
    try {
        $global:LASTEXITCODE = 0
        $raw = & $scriptPath -Action $action @arguments | Out-String
        if ($LASTEXITCODE -ne 0) { Fail 'native-failed' }
        return ($raw | ConvertFrom-Json)
    } catch { Fail "配套脚本在 $action 阶段失败；保留原状态，核对后继续，禁止直接重发。" }
}
try {
    $CodexThreadId = $CodexThreadId -replace '^codex://threads/', ''
    if ($CodexThreadId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') { Fail '任务归属无效。' }
    if ((Get-Item -LiteralPath $EvidenceFile).Length -gt 16384) { Fail '网页检查摘要过大。' }
    $e = Get-Content -LiteralPath $EvidenceFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($e.source -ne 'codex-in-app-browser' -or -not (Text $e.observationId)) { Fail '缺少内置浏览器刚读取的页面检查。' }
    $captured = if ($e.capturedAt -is [datetime]) { [DateTimeOffset]$e.capturedAt } else { [DateTimeOffset]::Parse($e.capturedAt) }
    $age = ([DateTimeOffset]::UtcNow - $captured).TotalSeconds
    if ($age -gt 30 -or $age -lt -5) { Fail '网页检查已过期，请重新读取原页面。' }
    if ($e.taskId -ne $TaskId -or $e.codexThreadId -ne $CodexThreadId -or $e.round -ne $RoundNumber) { Fail '网页检查属于其他任务或轮次。' }
    $state = Get-Content -LiteralPath (Join-Path $StateDir "$TaskId.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.codexThreadId -ne $CodexThreadId -or $state.taskId -ne $TaskId) { Fail '本地任务归属不一致。' }
    if ((Text $state.reviewRecoveryRequired) -in @('true','True') -or $state.taskTerminalStatus -ne 'active') { Fail '任务尚未恢复或已停止，不能发送。' }
    if ($state.reviewBatch -notmatch '^[CR]([1-9][0-9]*)$' -or [long]$Matches[1] -ne $RoundNumber) { Fail '本地轮次与提交轮次不一致。' }
    $bootstrap = $state.sessionBindingStatus -eq 'bootstrap-pending'
    if (-not $bootstrap -and $state.sessionBindingStatus -ne 'bound') { Fail '原会话尚未绑定，请先恢复绑定。' }
    $msg = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $MessageFile), [Text.Encoding]::UTF8)
    if ([Text.Encoding]::UTF8.GetByteCount($msg) -gt 16384) { Fail '消息过长，只发送方案摘要。' }
    $marker = "CODEX-BINDING-$CodexThreadId"
    if (($msg.TrimEnd() -split '\r?\n')[-1] -cne $marker) { Fail '消息最后一行必须是当前任务的绑定暗号。' }
    $fp = Hash $msg
    if ($e.messageFingerprint -cne $fp) { Fail '网页检查后消息发生变化，请重新核对。' }
    if ($e.browserSurface -ne 'codex-in-app-sidebar' -or $e.tabMatchCount -ne 1) { Fail '未唯一确认内置浏览器原标签。' }
    foreach ($field in @('browserTabId','browserRuntimeId','runtimeEpoch')) {
        if (-not (Text $e.$field) -or (Text $e.$field) -cne (Text $state.$field)) { Fail '浏览器身份已变化，请先核验并恢复原标签。' }
    }
    $pageUrl = [uri]$e.domTargetUrl
    if ($pageUrl.Scheme -ne 'https' -or $pageUrl.Host -ne 'chat.deepseek.com' -or $pageUrl.UserInfo -or -not $pageUrl.IsDefaultPort -or
        $e.domModel -notin @('网页当前模型（合并升级版）','专家模式') -or
        $e.domReasoning -ne '深度思考' -or $e.domSearch -ne '智能搜索') { Fail '尚未从网页确认 DeepSeek、深度思考和智能搜索。' }
    if (-not (Text $e.domSessionTitle) -or (-not $bootstrap -and
        ($e.deepSeekSessionId -cne $state.deepseekSessionId -or $e.domMessageMarker -cne $state.domMessageMarker))) { Fail '当前网页不是原评审会话。' }
    if (-not $bootstrap -and $state.conversationUrl -and ([uri]$state.conversationUrl).AbsoluteUri -cne $pageUrl.AbsoluteUri) { Fail '当前网页地址与原会话不一致。' }
    if (-not $bootstrap -and $e.deepSeekSessionId -like 'official-chat:*' -and
        $pageUrl.AbsolutePath.TrimEnd('/') -cne ('/a/chat/s/' + $e.deepSeekSessionId.Substring(14))) { Fail '当前网页地址没有对应的官方会话编号。' }
    if ($e.domInputPresence -ne 'present' -or $e.domInputEnabled -ne 'enabled') { Fail '网页输入框不可用，未准备发送。' }
    if ($e.messagePresence -ne 'absent') { Fail '本轮消息已存在或落点不明确，先核对回执，禁止重发。' }
    if (-not $CheckOnly -and [string]::IsNullOrWhiteSpace($AuthorizationEvidence)) { Fail '缺少本次任务已有的用户授权依据；不能由脚本编造。' }
    $key = Hash "$CodexThreadId|$TaskId|$fp"
    if ($CheckOnly) {
        @{ok=$true;stage='checked-only';sent=$false;round=$RoundNumber} | ConvertTo-Json -Compress
        exit 0
    }
    $argsForSend = @{
        TaskId=$TaskId; CodexThreadId=$CodexThreadId; StateDir=$StateDir;
        EvidenceSource='dom'; BrowserSurface=$e.browserSurface; BrowserTabId=$e.browserTabId;
        BrowserRuntimeId=$e.browserRuntimeId; RuntimeEpoch=$e.runtimeEpoch; TabMatchCount=$e.tabMatchCount;
        BrowserTabIdentityScope='browser-runtime-tab-id'; DeepSeekSessionId=$e.deepSeekSessionId;
        DomTargetUrl=$e.domTargetUrl; DomSessionTitle=$e.domSessionTitle; DomMessageMarker=$e.domMessageMarker;
        DomModel=$e.domModel; DomReasoning=$e.domReasoning; DomSearch=$e.domSearch;
        DomInputPresence=$e.domInputPresence; DomInputEnabled=$e.domInputEnabled;
        BrowserEvidenceCapturedAt=$captured.ToString('o'); MessageFingerprint=$fp; SendIdempotencyKey=$key;
        LeaseToken=$LeaseToken; LeaseEpoch=$LeaseEpoch
    }
    $stage = 'prepare-send'
    $prepared = Native 'PrepareSend' $argsForSend
    $stage = 'confirm-send'
    $argsForSend.PlatformConfirmationStatus = 'confirmed'
    $argsForSend.ConfirmationSource = $AuthorizationSource
    $argsForSend.PlatformConfirmationEvidence = $AuthorizationEvidence
    $confirmed = Native 'ConfirmBrowserSend' $argsForSend
    if ($confirmed.sendNow -ne $true) { Fail '本轮没有取得可发送状态；先核对原记录。' }
    @{ok=$true;stage='ready-for-browser-send';sent=$false;round=$RoundNumber;
      messageFile=(Resolve-Path -LiteralPath $MessageFile).Path;fingerprint=$fp;idempotencyKey=$key;
      nextStep='立即由内置浏览器提交原消息并回读页面；确认本轮消息出现后记录回执。'} | ConvertTo-Json -Compress
} catch {
    $message = if ($_.Exception.Message -match '^(配套脚本|任务|缺少|网页|本地|原会话|消息|浏览器|尚未|当前网页|本轮|未唯一)') { $_.Exception.Message } else { '输入文件无效或本地操作失败；原任务保留，先核对当前阶段。' }
    @{ok=$false;stage=$stage;sent=$false;problems=@($message)} | ConvertTo-Json -Compress
    exit 1
}
