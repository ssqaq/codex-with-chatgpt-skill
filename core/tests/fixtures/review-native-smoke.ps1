# Synthetic page evidence only: exercise the real local scripts without opening a browser.
param([string]$SkillRoot,[string]$StateDir,[string]$SkillName='deepseek-consensus-review')
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$task='native-smoke';$thread='native-test-thread';$marker="CODEX-BINDING-$thread"
$scripts=Join-Path $SkillRoot 'scripts'
$base=@{TaskId=$task;CodexThreadId=$thread;StateDir=$StateDir}
& (Join-Path $scripts 'activate_review.ps1') @base -SkillName $SkillName | Out-Null
$dom=@{EvidenceSource='dom';BrowserSurface='codex-in-app-sidebar';BrowserTabId='synthetic-tab';BrowserRuntimeId='synthetic-runtime';RuntimeEpoch=1;TabMatchCount=1;
 DomTargetUrl='https://chat.deepseek.com/';DomSessionTitle='Synthetic test';DomModel='网页当前模型（合并升级版）';DomReasoning='深度思考';DomSearch='智能搜索';DomInputPresence='present';DomInputEnabled='enabled'}
& (Join-Path $scripts 'session_binding.ps1') @base @dom -Action BeginBootstrap -ExpectedMessageMarker $marker | Out-Null
$acquireDom=$dom.Clone();$acquireDom.Remove('TabMatchCount')
$lease=& (Join-Path $scripts 'session_binding.ps1') @base @acquireDom -Action AcquireBrowserLease | ConvertFrom-Json
$token=$lease.leaseToken
if(-not $token){$token=$lease.lease.token}
$epoch=$lease.leaseEpoch
if(-not $epoch){$epoch=$lease.lease.leaseEpoch}
$batch=if($SkillName -eq 'deepseek-independent-review'){'R1'}else{'C1'}
$message="$batch synthetic test`n$marker"
$messagePath=Join-Path $StateDir 'message.txt';[IO.File]::WriteAllText($messagePath,$message,[Text.UTF8Encoding]::new($false))
$fp=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($message))).ToLowerInvariant()
$e=@{source='codex-in-app-browser';observationId='synthetic-fixture';capturedAt=[DateTimeOffset]::UtcNow.ToString('o');taskId=$task;codexThreadId=$thread;round=1;
 messageFingerprint=$fp;messagePresence='absent';browserSurface=$dom.BrowserSurface;browserTabId=$dom.BrowserTabId;browserRuntimeId=$dom.BrowserRuntimeId;runtimeEpoch=1;tabMatchCount=1;
 domTargetUrl=$dom.DomTargetUrl;domSessionTitle=$dom.DomSessionTitle;domModel=$dom.DomModel;domReasoning=$dom.DomReasoning;domSearch=$dom.DomSearch;domInputPresence='present';domInputEnabled='enabled';domMessageMarker=''}
$evidence=Join-Path $StateDir 'evidence.json';$e|ConvertTo-Json|Set-Content -LiteralPath $evidence -Encoding utf8
$result=& (Join-Path $scripts 'send_review_round.ps1') @base -MessageFile $messagePath -EvidenceFile $evidence -RoundNumber 1 -AuthorizationEvidence 'Synthetic test authorization' -LeaseToken $token -LeaseEpoch $epoch | ConvertFrom-Json
if(-not $result.ok){throw ($result.problems -join ',')}
if($result.sent -ne $false){throw 'Local scripts cannot claim a browser send'}
$dom.DomTargetUrl='https://chat.deepseek.com/a/chat/s/synthetic-session-123'
$dom.DomMessageMarker=$marker
$sessionId='official-chat:synthetic-session-123'
& (Join-Path $scripts 'session_binding.ps1') @base @dom -Action CompleteBootstrap -DeepSeekSessionId $sessionId -LeaseToken $token -LeaseEpoch $epoch | Out-Null
& (Join-Path $scripts 'session_binding.ps1') @base @dom -Action RecordSendOutcome -DeepSeekSessionId $sessionId -MessageFingerprint $fp -ReceiptStatus confirmed -DomMessagePresence present -OpenTabsEvidence confirmed -TabsListEvidence unknown -SubmissionMechanism enter -SubmissionStatus succeeded -LeaseToken $token -LeaseEpoch $epoch | Out-Null
$wrongReleaseRejected=$false
try {
 $wrongRelease=@{BrowserSurface='external-browser';BrowserRuntimeId=$dom.BrowserRuntimeId;RuntimeEpoch=$dom.RuntimeEpoch}
 & (Join-Path $scripts 'session_binding.ps1') @base @wrongRelease -Action ReleaseBrowserLease -LeaseToken $token -LeaseEpoch $epoch | Out-Null
} catch {$wrongReleaseRejected=$true}
if(-not $wrongReleaseRejected){throw 'Mismatched browser surface was accepted'}
$releaseDom=@{BrowserRuntimeId=$dom.BrowserRuntimeId;RuntimeEpoch=$dom.RuntimeEpoch}
& (Join-Path $scripts 'session_binding.ps1') @base @releaseDom -Action ReleaseBrowserLease -LeaseToken $token -LeaseEpoch $epoch | Out-Null
$wrongAcquireRejected=$false
try {
 $wrongAcquire=$acquireDom.Clone();$wrongAcquire.BrowserRuntimeId='other-runtime'
 & (Join-Path $scripts 'session_binding.ps1') @base @wrongAcquire -Action AcquireBrowserLease | Out-Null
} catch {$wrongAcquireRejected=$true}
if(-not $wrongAcquireRejected){throw 'Mismatched browser runtime was accepted'}
$statuses=@()
1..3 | ForEach-Object {
 $r=& (Join-Path $scripts 'advance_review_workflow.ps1') @base -Action RecordReport | ConvertFrom-Json
 $statuses+= $r.status
}
$state=Get-Content (Join-Path $StateDir "$task.json") -Raw | ConvertFrom-Json
if($state.lastReceiptStatus -ne 'confirmed' -or $state.sendPhase -ne 'receipt-confirmed' -or $state.pendingReceipt -eq 'true'){throw 'Receipt not confirmed'}
if([DateTimeOffset]$state.sendPageVerifiedAt -ne [DateTimeOffset]::Parse($e.capturedAt)){throw 'Receipt overwrote send page verification time'}
if($statuses -contains 'workflow-stalled'){throw 'Normal waiting was treated as stalled'}
@{ok=$true;synthetic=$true;receiptConfirmed=$true;acquireRecoveredUniqueTab=$true;releaseRecoveredSurface=$true;wrongAcquireRejected=$wrongAcquireRejected;wrongReleaseRejected=$wrongReleaseRejected;duplicateReportsPaused=$false;checkpointExists=(Test-Path (Join-Path $StateDir "$task.checkpoint.json"))}|ConvertTo-Json -Compress
