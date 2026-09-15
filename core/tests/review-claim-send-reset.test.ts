import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {it,expect} from 'vitest';
import {makeTmpDir,cleanup} from './helpers.js';

const repo = fileURLToPath(new URL('../../', import.meta.url));
const bundle = path.join(repo, 'bundled-skills/deepseek-consensus-review');

it('resets inherited send state after ForceTerminate then BindExistingOfficialSession', () => {
  const dir = makeTmpDir('claim-send-reset');
  const ps = (file: string, args: string[]) =>
    spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file, ...args], {
      encoding: 'utf8', windowsHide: true, timeout: 20000,
    });
  try {
    const setup = ps(path.join(repo, 'core/tests/fixtures/review-native-smoke.ps1'), [
      '-SkillRoot', bundle, '-StateDir', dir,
    ]);
    expect(setup.status, setup.stderr).toBe(0);

    const registryFile = path.join(dir, 'thread-bindings.json');
    const original = JSON.parse(fs.readFileSync(registryFile, 'utf8')).bindings[0];
    expect(original.lastReceiptStatus).toBe('confirmed');
    expect(original.lastMessageFingerprint).toBeTruthy();
    expect(original.sendPhase).toBe('receipt-confirmed');
    const oldFingerprint = original.lastMessageFingerprint;

    const terminate = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'ForceTerminateTask',
      '-TaskId', 'native-smoke',
      '-CodexThreadId', 'native-test-thread',
      '-StateDir', dir,
      '-Reason', 'start-new-review-on-same-official-session',
    ]);
    expect(terminate.status, terminate.stderr).toBe(0);

    const next = ['-TaskId', 'next-review', '-CodexThreadId', 'native-test-thread', '-StateDir', dir];
    const activate = ps(path.join(bundle, 'scripts/activate_review.ps1'), [
      ...next, '-SkillName', 'deepseek-consensus-review',
    ]);
    expect(activate.status, activate.stderr).toBe(0);

    const bind = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'BindExistingOfficialSession',
      ...next,
      '-EvidenceSource', 'dom',
      '-BrowserSurface', 'codex-in-app-sidebar',
      '-BrowserTabId', 'synthetic-tab',
      '-BrowserTabTitle', 'Synthetic test',
      '-BrowserRuntimeId', 'synthetic-runtime',
      '-RuntimeEpoch', '1',
      '-TabMatchCount', '1',
      '-DeepSeekSessionId', 'official-chat:synthetic-session-123',
      '-DomTargetUrl', 'https://chat.deepseek.com/a/chat/s/synthetic-session-123',
      '-DomSessionTitle', 'Synthetic test',
      '-DomMessageMarker', 'CODEX-BINDING-native-test-thread',
      '-DomModel', '网页当前模型（合并升级版）',
      '-DomReasoning', '深度思考',
      '-DomSearch', '智能搜索',
    ]);
    expect(bind.status, bind.stderr).toBe(0);

    const binding = JSON.parse(fs.readFileSync(registryFile, 'utf8')).bindings[0];
    expect(binding.activeTaskId).toBe('next-review');
    expect(binding.sendOwnerTaskId || '').toBe('');
    expect(binding.lastMessageFingerprint || '').toBe('');
    expect(binding.sendPhase || '').toBe('');
    expect(binding.lastReceiptStatus || '').toBe('');
    expect(binding.sendPhase).not.toBe('receipt-confirmed');
    const audit = binding.previousSendAudit || [];
    expect(audit.some((entry: {lastMessageFingerprint?: string}) => entry.lastMessageFingerprint === oldFingerprint)).toBe(true);

    const claim = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'Claim', ...next,
    ]);
    expect(claim.status, claim.stderr).toBe(0);
    const afterClaim = JSON.parse(fs.readFileSync(registryFile, 'utf8')).bindings[0];
    expect(afterClaim.lastMessageFingerprint || '').toBe('');
    expect(afterClaim.sendOwnerTaskId || '').toBe('');
  } finally {
    cleanup(dir);
  }
}, 30000);

it('Claim still resets leftover sendOwner after Bind already switched activeTaskId', () => {
  const dir = makeTmpDir('claim-send-reset-claim');
  const ps = (file: string, args: string[]) =>
    spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file, ...args], {
      encoding: 'utf8', windowsHide: true, timeout: 20000,
    });
  try {
    const setup = ps(path.join(repo, 'core/tests/fixtures/review-native-smoke.ps1'), [
      '-SkillRoot', bundle, '-StateDir', dir,
    ]);
    expect(setup.status, setup.stderr).toBe(0);
    const registryFile = path.join(dir, 'thread-bindings.json');
    const original = JSON.parse(fs.readFileSync(registryFile, 'utf8'));
    const oldFingerprint = original.bindings[0].lastMessageFingerprint;
    original.bindings[0].previousTaskId = 'native-smoke';
    original.bindings[0].activeTaskId = 'next-review';
    original.bindings[0].taskId = 'next-review';
    original.bindings[0].sendOwnerTaskId = 'native-smoke';
    fs.writeFileSync(registryFile, JSON.stringify(original));
    fs.writeFileSync(path.join(dir, 'native-smoke.json'), JSON.stringify({
      ...JSON.parse(fs.readFileSync(path.join(dir, 'native-smoke.json'), 'utf8')),
      taskTerminalStatus: 'cancelled',
    }));
    const next = ['-TaskId', 'next-review', '-CodexThreadId', 'native-test-thread', '-StateDir', dir];
    expect(ps(path.join(bundle, 'scripts/activate_review.ps1'), [...next, '-SkillName', 'deepseek-consensus-review']).status).toBe(0);
    const claim = ps(path.join(bundle, 'scripts/session_binding.ps1'), ['-Action', 'Claim', ...next]);
    expect(claim.status, claim.stderr).toBe(0);
    const binding = JSON.parse(fs.readFileSync(registryFile, 'utf8')).bindings[0];
    expect(binding.sendOwnerTaskId || '').toBe('');
    expect(binding.lastMessageFingerprint || '').toBe('');
    expect((binding.previousSendAudit || []).some((entry: {lastMessageFingerprint?: string}) => entry.lastMessageFingerprint === oldFingerprint)).toBe(true);
  } finally {
    cleanup(dir);
  }
}, 30000);
it('ForceTerminate refuses pendingReceipt or auditRisk', () => {
  const dir = makeTmpDir('force-terminate-pending');
  const ps = (file: string, args: string[]) =>
    spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file, ...args], {
      encoding: 'utf8', windowsHide: true, timeout: 20000,
    });
  try {
    const setup = ps(path.join(repo, 'core/tests/fixtures/review-native-smoke.ps1'), [
      '-SkillRoot', bundle, '-StateDir', dir,
    ]);
    expect(setup.status, setup.stderr).toBe(0);
    const registryFile = path.join(dir, 'thread-bindings.json');
    const original = JSON.parse(fs.readFileSync(registryFile, 'utf8'));
    original.bindings[0].pendingReceipt = true;
    fs.writeFileSync(registryFile, JSON.stringify(original));
    const terminate = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'ForceTerminateTask',
      '-TaskId', 'native-smoke',
      '-CodexThreadId', 'native-test-thread',
      '-StateDir', dir,
      '-Reason', 'should-not-terminate-pending',
    ]);
    expect(terminate.status).not.toBe(0);
    original.bindings[0].pendingReceipt = false;
    original.bindings[0].auditRisk = true;
    fs.writeFileSync(registryFile, JSON.stringify(original));
    const terminateAudit = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'ForceTerminateTask',
      '-TaskId', 'native-smoke',
      '-CodexThreadId', 'native-test-thread',
      '-StateDir', dir,
      '-Reason', 'should-not-terminate-audit',
    ]);
    expect(terminateAudit.status).not.toBe(0);
  } finally {
    cleanup(dir);
  }
}, 30000);

it('Bind pauses leftover send when sendOwner is empty', () => {
  const dir = makeTmpDir('bind-empty-send-owner');
  const ps = (file: string, args: string[]) =>
    spawnSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file, ...args], {
      encoding: 'utf8', windowsHide: true, timeout: 20000,
    });
  try {
    const setup = ps(path.join(repo, 'core/tests/fixtures/review-native-smoke.ps1'), [
      '-SkillRoot', bundle, '-StateDir', dir,
    ]);
    expect(setup.status, setup.stderr).toBe(0);
    const registryFile = path.join(dir, 'thread-bindings.json');
    const original = JSON.parse(fs.readFileSync(registryFile, 'utf8'));
    original.bindings[0].activeTaskId = '';
    original.bindings[0].taskId = '';
    original.bindings[0].previousTaskId = '';
    original.bindings[0].sendOwnerTaskId = '';
    original.bindings[0].lastMessageFingerprint = 'leftover-fingerprint';
    original.bindings[0].sendPhase = 'receipt-confirmed';
    fs.writeFileSync(registryFile, JSON.stringify(original));
    fs.writeFileSync(path.join(dir, 'next-review.json'), JSON.stringify({
      taskId: 'next-review',
      codexThreadId: 'native-test-thread',
      skillName: 'deepseek-consensus-review',
      activationStatus: 'activated',
      taskTerminalStatus: 'active',
      executionStatus: '禁止修改',
    }));
    const bind = ps(path.join(bundle, 'scripts/session_binding.ps1'), [
      '-Action', 'BindExistingOfficialSession',
      '-TaskId', 'next-review',
      '-CodexThreadId', 'native-test-thread',
      '-StateDir', dir,
      '-EvidenceSource', 'dom',
      '-BrowserSurface', 'codex-in-app-sidebar',
      '-BrowserTabId', 'synthetic-tab',
      '-BrowserTabTitle', 'Synthetic test',
      '-BrowserRuntimeId', 'synthetic-runtime',
      '-RuntimeEpoch', '1',
      '-TabMatchCount', '1',
      '-DeepSeekSessionId', 'official-chat:synthetic-session-123',
      '-DomTargetUrl', 'https://chat.deepseek.com/a/chat/s/synthetic-session-123',
      '-DomSessionTitle', 'Synthetic test',
      '-DomMessageMarker', 'CODEX-BINDING-native-test-thread',
      '-DomModel', '网页当前模型（合并升级版）',
      '-DomReasoning', '深度思考',
      '-DomSearch', '智能搜索',
    ]);
    expect(bind.status).not.toBe(0);
    const binding = JSON.parse(fs.readFileSync(registryFile, 'utf8')).bindings[0];
    expect(binding.lastMessageFingerprint).toBe('leftover-fingerprint');
  } finally {
    cleanup(dir);
  }
}, 30000);
