import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cleanup, makeTmpDir } from "./helpers.js";

const repo = fileURLToPath(new URL("../../", import.meta.url));
const skills = ["deepseek-consensus-review", "deepseek-independent-review"];
let dir: string;
beforeEach(() => { dir = makeTmpDir("diagnostic-timing"); });
afterEach(() => cleanup(dir));
function run(script: string, args: string[], shell = "pwsh") {
  const result = spawnSync(shell, ["-NoProfile", "-NonInteractive", "-File", script, ...args],
    { encoding: "utf8", timeout: 20000, windowsHide: true });
  expect(result.status, result.stderr || result.stdout).toBe(0);
  return JSON.parse(result.stdout);
}

describe.each(skills)("%s diagnostic timestamp fidelity", skill => {
  const scripts = path.join(repo, "bundled-skills", skill, "scripts");
  it("matches dashboard intervals across Z and +08:00 without losing fractional seconds", () => {
    const task = "diagnostic-time", thread = "diagnostic-thread";
    fs.writeFileSync(path.join(dir, `${task}.json`), JSON.stringify({
      taskId: task, codexThreadId: thread, skillName: skill, reviewBatch: "C2", taskTerminalStatus: "active",
      requestedAt: "2026-09-15T13:00:00.1234567Z", activatedAt: "2026-09-15T21:00:00.1454567+08:00",
      messageReadyAt: "2026-09-15T21:01:00.250+08:00", browserVerifiedAt: "2026-09-15T13:01:00.375Z",
      browserConfirmationAt: "2026-09-15T21:27:39.631+08:00", browserActionAt: "2026-09-15T13:27:39.656Z",
      receiptAt: "2026-09-15T21:27:49.5646054+08:00",
    }));
    const args = ["-TaskId", task, "-CodexThreadId", thread, "-StateDir", dir, "-Format", "Json"];
    const report = run(path.join(scripts, "export_diagnostic_report.ps1"), args);
    const dashboard = run(path.join(scripts, "show_review_dashboard.ps1"), args);
    expect(report.send.timing).toEqual({ requestToActivation: "22ms", messageToBrowserVerify: "125ms",
      confirmationToAction: "25ms", actionToReceipt: "9.91s" });
    expect(report.send.timing.actionToReceipt).toBe(dashboard.timing.browserActionToReceipt);
    expect(report.send.timing.requestToActivation).toBe(dashboard.timing.requestedToActivated);
    expect(report.send.timing.messageToBrowserVerify).toBe(dashboard.timing.messageReadyToBrowserVerified);
    expect(report.send.timing.confirmationToAction).toBe(dashboard.timing.confirmationToBrowserAction);
  });

  it("preserves native DateTime/DateTimeOffset kinds and leaves absent or invalid times unknown", () => {
    const harness = path.join(dir, "native-timing.ps1");
    fs.writeFileSync(harness, `param([string]$Source)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
` +
      `$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
` +
      `if($errors.Count){throw 'Script parse failed'}
` +
      `$wanted=@('Text','Prop','Parse-Instant','Elapsed-Text')
` +
      `$functions=$ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted},$false)
` +
      `if($functions.Count -ne 4){throw 'Missing timing helpers'}
` +
      `foreach($function in $functions){Invoke-Expression $function.Extent.Text}
` +
      `$culture=[Globalization.CultureInfo]::InvariantCulture
` +
      `$start=[datetime]::Parse('2026-09-15T13:27:39.656Z',$culture,[Globalization.DateTimeStyles]::RoundtripKind)
` +
      `$end=[datetimeoffset]::Parse('2026-09-15T21:27:49.5646054+08:00',$culture)
` +
      `$cases=@(
` +
      ` [pscustomobject]@{a=$start;b='2026-09-15T21:27:49.5646054+08:00'},
` +
      ` [pscustomobject]@{a='2026-09-15T13:27:39.656Z';b=$end},
` +
      ` [pscustomobject]@{a=$start;b=$end},
` +
      ` [pscustomobject]@{a=$start.ToLocalTime();b=$end.UtcDateTime}
)
` +
      `$mixed=@($cases|ForEach-Object {Elapsed-Text (Prop $_ 'a') (Prop $_ 'b')})
` +
      `$unknown=@((Elapsed-Text $null $end),(Elapsed-Text '' $end),(Elapsed-Text 'bad-time' $end),(Elapsed-Text $end $start))
` +
      `@{mixed=$mixed;unknown=$unknown}|ConvertTo-Json -Compress
`);
    const result = run(harness, ["-Source", path.join(scripts, "export_diagnostic_report.ps1")]);
    expect(result.mixed).toEqual(["9.91s", "9.91s", "9.91s", "9.91s"]);
    expect(result.unknown).toEqual(["无", "无", "无", "无"]);
  });
});


describe.each(skills)("%s legacy JSON timestamp parser compatibility", skill => {
  const runtimes = [
    { shell: "pwsh", parserMode: "legacy" },
    { shell: "pwsh", parserMode: "native" },
    ...(process.platform === "win32" ? [{ shell: "powershell", parserMode: "native" }] : []),
  ];
  const cases = ["session_binding.ps1", "export_diagnostic_report.ps1"].flatMap(script => runtimes.map(runtime => ({ script, ...runtime })));
  it.each(cases)("$script preserves JSON values using $shell ($parserMode)", ({ script, shell, parserMode }) => {
    const harness = path.join(dir, "legacy-json-reader.ps1");
    const input = path.join(dir, "json-input.json");
    const fixture = {
      timestamp: "2026-09-15T22:23:50.0173840+08:00", utc: "2026-09-15T14:23:50.0000000Z",
      nested: { timestamp: "2026-09-15T22:23:50.1276540+08:00", missing: null },
      empty: [], single: ["2026-09-15T14:23:50.0000000Z"],
      arrays: [[], [1], [[null], [false, true, 0, -5, 1.25], []]],
      "$type": "System.Version", "$values": [1, 2], stringNumber: "1234",
    };
    fs.writeFileSync(harness, String.raw`param([string]$Source,[string]$InputPath,[string]$Reader,[string]$ParserMode)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText($Source,[Text.Encoding]::UTF8),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Script parse failed'}
$wanted=@('ConvertFrom-JsonPreservingDates','ConvertFrom-JsonToken','Read-Json','Read-JsonSafe')
$functions=$ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $wanted},$false)
foreach($function in $functions){Invoke-Expression $function.Extent.Text}
# Simulate the old pwsh command surface while retaining its real date-coercing parser.
if($ParserMode -eq 'legacy') {
function Get-Command([string]$Name) {
    $command=Microsoft.PowerShell.Core\Get-Command $Name
    if($Name -ne 'ConvertFrom-Json'){return $command}
    $parameters=@{}
    foreach($entry in $command.Parameters.GetEnumerator()) {
        if($entry.Key -ne 'DateKind'){$parameters[$entry.Key]=$entry.Value}
    }
    [pscustomobject]@{Parameters=$parameters}
}
$raw=[IO.File]::ReadAllText($InputPath,[Text.Encoding]::UTF8)
$baseline='{"timestamp":"2026-09-15T22:23:50.0173840+08:00"}'|Microsoft.PowerShell.Utility\ConvertFrom-Json
if($baseline.timestamp -isnot [datetime]){throw 'Harness did not reproduce the legacy date coercion'}
}
if($Reader -eq 'Read-Json'){$value=Read-Json $InputPath $null}
else {
    $read=Read-JsonSafe $InputPath
    if($read.errorType){throw $read.errorType}
    $value=$read.value
}
@{value=$value;dateKindVisible=(Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')}|ConvertTo-Json -Depth 30 -Compress
`);
    const reader = script === "session_binding.ps1" ? "Read-Json" : "Read-JsonSafe";
    const source = path.join(repo, "bundled-skills", skill, "scripts", script);
    for (const value of [fixture, {}, [], [fixture], [[1], [], [null, false, 2.5]], null, false, 1.25]) {
      fs.writeFileSync(input, JSON.stringify(value));
      const result = run(harness, ["-Source", source, "-InputPath", input, "-Reader", reader, "-ParserMode", parserMode], shell);
      if (parserMode === "legacy") expect(result.dateKindVisible).toBe(false);
      expect(result.value).toEqual(value);
    }
  }, 30000);
});
