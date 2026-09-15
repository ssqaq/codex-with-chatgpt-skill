import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { cleanup, makeTmpDir } from './helpers.js';

const script = fileURLToPath(new URL('../../scripts/audit-review-observations.mjs', import.meta.url));
const moduleUrl = new URL('../../scripts/audit-review-observations.mjs', import.meta.url).href;
const { auditReviewObservations: audit, auditExitCode, auditReviewObservationFile: auditFile } = await import(/* @vite-ignore */ moduleUrl);
const start = '2026-09-15T13:41:00.000Z';
function evidence(end = '2026-09-15T13:41:30.000Z') {
  return { round: 3, submittedAt: start, observations: [
    { observedAt: start, complete: false },
    { observedAt: end, complete: true, identity: 'current-round' },
  ] };
}
const codes = (report: any) => report.issues.map((issue: any) => issue.code);
const run = (value: unknown, options: Record<string, unknown> = {}) => audit(value, { expectedRound: 3, ...options });

// These are the recorded C1-C3 shapes, not a claim that this test accessed DeepSeek.
describe('raw review observation timing acceptance', () => {
  it.each([
    [1, '13:36:14.230', '13:36:14.331', '13:36:36.921', 101, 22590, 22691, 'passed'],
    [2, '13:39:13.604', '13:39:13.678', '13:39:41.747', 74, 28069, 28143, 'passed'],
    [3, '13:41:37.216', '13:41:37.280', '13:42:32.834', 64, 55554, 55618, 'failed'],
  ])('recomputes C%s from the two raw observations', (round, submitted, first, last, firstMs, intervalMs, completeMs, status) => {
    const report = audit({ round, submittedAt: `2026-09-15T${submitted}Z`, decision: 'CONSENSUS',
      latencySeconds: 0, maxCheckIntervalSeconds: 0, status: 'all-passed',
      observations: [ { observedAt: `2026-09-15T${first}Z`, complete: false },
        { observedAt: `2026-09-15T${last}Z`, complete: true, identity: 'current-round' } ] }, { expectedRound: round });
    expect(report.status).toBe(status);
    expect(report.timing).toEqual({ firstCheckDelayMs: firstMs, maxCheckIntervalMs: intervalMs,
      completeReplyObservedDelayMs: completeMs, timeoutCount: status === 'failed' ? 1 : 0 });
    expect(report.ignoredSummaryFields).toEqual(['decision', 'latencySeconds', 'maxCheckIntervalSeconds', 'status']);
    if (status === 'failed') {
      expect(report.speedTargetMet).toBe(false);
      expect(report.overruns[0]).toMatchObject({ actualMs: 55554, excessMs: 25554 });
      expect(auditExitCode(report)).toBe(1);
    }
  });

  it('accepts exactly 30000ms without accepting 30001ms', () => {
    expect(run(evidence()).status).toBe('passed');
    expect(run(evidence('2026-09-15T13:41:30.001Z')).status).toBe('failed');
  });

  it('does not truncate nanosecond timestamp precision into a false pass', () => {
    const report = run(evidence('2026-09-15T13:41:30.000000001Z'));
    expect(report.status).toBe('failed');
    expect(report.timing.maxCheckIntervalMs).toBeGreaterThan(30000);
    expect(report.overruns[0].excessMs).toBe(0.000001);
  });

  it('counts delayed first check as an overrun even with no adjacent observations', () => {
    const data = evidence('2026-09-15T13:41:31.000Z');
    data.observations.shift();
    const report = run(data);
    expect(report.status).toBe('failed');
    expect(report.timing).toEqual({ firstCheckDelayMs: 31000, maxCheckIntervalMs: null,
      completeReplyObservedDelayMs: 31000, timeoutCount: 1 });
    expect(report.overruns[0].kind).toBe('submission-to-first-observation');
  });

  it('allows an immediate first read to return complete', () => {
    const data = evidence('2026-09-15T13:41:00.001Z');
    data.observations.shift();
    const report = run(data);
    expect(report.status).toBe('passed');
    expect(report.timing.firstCheckDelayMs).toBe(1);
    expect(report.timing.maxCheckIntervalMs).toBeNull();
  });

  it('counts every overrun including first-read delay', () => {
    const report = run({ round: 3, submittedAt: start, observations: [
      { observedAt: '2026-09-15T13:41:31Z', complete: false },
      { observedAt: '2026-09-15T13:42:03Z', complete: false },
      { observedAt: '2026-09-15T13:42:36Z', complete: true, identity: 'current-round' },
    ] });
    expect(report.timing.timeoutCount).toBe(3);
    expect(report.overruns.map((entry: any) => entry.excessMs)).toEqual([1000, 2000, 3000]);
    expect(report.timing.maxCheckIntervalMs).toBe(33000);
  });

  it('uses absolute time across Z and +08:00 while preserving fractions', () => {
    const data = evidence('2026-09-15T21:41:30.0000000+08:00');
    expect(run(data).status).toBe('passed');
    expect(run(data).timing.maxCheckIntervalMs).toBe(30000);
  });

  it.each([undefined, null, '', 'bad-time', '2026-02-30T13:41:00Z', '2026-09-15T13:41:00',
    '2026-09-15T13:41:60Z', '2026-09-15T13:41:00+24:00', '2026-09-15T13:41:00+08:60', 12345])(
    'never accepts missing or invalid submission %s', value => {
      const data = { ...evidence(), submittedAt: value };
      const report = run(data);
      expect(report.status).not.toBe('passed');
      expect(auditExitCode(report)).not.toBe(0);
      expect(report.timing.firstCheckDelayMs).toBeNull();
    });

  it.each([undefined, null, 'invalid', '2026-09-15T13:41:00.1234567891Z'])(
    'never accepts missing or invalid intermediate observation %s', value => {
      const data: any = evidence();
      data.observations.splice(1, 0, { observedAt: value, complete: false });
      const report = run(data);
      expect(report.status).not.toBe('passed');
      expect(auditExitCode(report)).not.toBe(0);
    });

  it('rejects duplicate instants even when the textual offsets differ', () => {
    const report = run(evidence('2026-09-15T21:41:00+08:00'));
    expect(report.status).toBe('failed');
    expect(codes(report)).toContain('DUPLICATE_TIMESTAMP');
  });

  it('does not silently sort reversed observations', () => {
    const data: any = evidence();
    data.observations.splice(1, 0, { observedAt: '2026-09-15T13:41:31Z', complete: false });
    const report = run(data);
    expect(report.status).toBe('failed');
    expect(codes(report)).toContain('OUT_OF_ORDER_TIMESTAMP');
    expect(data.observations[1].observedAt).toBe('2026-09-15T13:41:31Z');
  });

  it('rejects an observation made before submission', () => {
    const data = evidence(); data.observations[0].observedAt = '2026-09-15T13:40:59Z';
    const report = run(data);
    expect(report.status).toBe('failed');
    expect(codes(report)).toContain('OBSERVATION_BEFORE_SUBMISSION');
  });

  it('requires explicit expected round and rejects mismatches at both levels', () => {
    expect(audit(evidence()).status).toBe('unknown');
    expect(run(evidence(), { expectedRound: 4 }).status).toBe('failed');
    const data: any = evidence(); data.observations[1].round = 4;
    expect(codes(run(data))).toContain('WRONG_OBSERVATION_ROUND');
    data.round = '3';
    expect(run(data).status).not.toBe('passed');
  });

  it('requires recorded task identity when the caller requests a task check', () => {
    expect(run(evidence(), { expectedTaskId: 'expected-task' }).status).toBe('unknown');
    const data: any = { ...evidence(), taskId: 'wrong-task' };
    expect(codes(run(data, { expectedTaskId: 'expected-task' }))).toContain('WRONG_TASK');
    data.taskId = 'expected-task'; data.observations[0].taskId = 'other-task';
    expect(codes(run(data, { expectedTaskId: 'expected-task' }))).toContain('WRONG_OBSERVATION_TASK');
  });

  it.each([{}, [], null, { round: 3, submittedAt: start, observations: [] }])('does not manufacture missing evidence', value => {
    const report = run(value);
    expect(report.status).toBe('unknown');
    expect(report.speedTargetMet).toBeNull();
    expect(auditExitCode(report)).toBe(2);
  });

  it('rejects a final streaming reply even if DECISION already says CONSENSUS', () => {
    const data = { ...evidence(), decision: 'CONSENSUS' }; data.observations[1].complete = false;
    const report = run(data);
    expect(report.status).toBe('unknown');
    expect(report.timing.completeReplyObservedDelayMs).toBeNull();
    expect(codes(report)).toContain('FINAL_REPLY_NOT_VERIFIED_COMPLETE');
  });

  it.each([undefined, 'unverified-round', 'awaiting-identity', 'no-reply-yet', 'invented-success'])(
    'does not accept a completed reply with identity %s', identity => {
      const data: any = evidence(); data.observations[1].identity = identity;
      expect(run(data).status).not.toBe('passed');
    });

  it('does not accept string completion flags or observations after completion', () => {
    const data: any = evidence(); data.observations[1].complete = 'true';
    expect(run(data).status).toBe('unknown');
    data.observations[0] = { ...data.observations[0], complete: true, identity: 'current-round' };
    expect(run(data).status).toBe('failed');
    expect(codes(run(data))).toContain('OBSERVATION_AFTER_COMPLETION');
  });

  it('does not mutate input or include reply text and clearly limits acceptance scope', () => {
    const data = { ...evidence(), reply: 'do-not-copy-this-body', decision: 'CONSENSUS' };
    const before = JSON.stringify(data);
    const report = run(data);
    expect(JSON.stringify(data)).toBe(before);
    expect(JSON.stringify(report)).not.toContain('do-not-copy-this-body');
    expect(report.limitations.join(' ')).toMatch(/不能证明真实网页/);
    expect(report.limitations.join(' ')).toMatch(/不是速度达标、执行许可或发布许可/);
  });
});

let dir: string;
beforeEach(() => { dir = makeTmpDir('observation-audit'); });
afterEach(() => cleanup(dir));
function inputFile(value: unknown = evidence(), name = 'input.json') {
  const file = path.join(dir, name); fs.writeFileSync(file, JSON.stringify(value)); return file;
}
function cli(args: string[]) {
  return spawnSync(process.execPath, [script, ...args], { encoding: 'utf8', timeout: 10000, windowsHide: true });
}

describe('independent local audit report and CLI', () => {
  it.each([['passed', '2026-09-15T13:41:30Z', 0], ['failed', '2026-09-15T13:41:31Z', 1]])(
    'writes a new %s report and uses the documented exit code', (status, end, exitCode) => {
      const input = inputFile(evidence(String(end))), output = path.join(dir, 'report.json');
      const before = fs.readFileSync(input);
      const result = cli(['--input', input, '--output', output, '--round', '3']);
      expect(result.status, result.stderr).toBe(exitCode);
      expect(result.stderr).toBe('');
      const report = JSON.parse(fs.readFileSync(output, 'utf8'));
      expect(report.status).toBe(status);
      expect(JSON.parse(result.stdout)).toEqual(report);
      expect(report.source.sha256).toMatch(/^[0-9a-f]{64}$/);
      expect(fs.readFileSync(input).equals(before)).toBe(true);
    });

  it('writes unknown with nonzero exit for incomplete evidence', () => {
    const input = inputFile({ round: 3, submittedAt: start, observations: [] });
    const output = path.join(dir, 'unknown.json');
    const result = cli(['--input', input, '--output', output, '--round', '3']);
    expect(result.status).toBe(2);
    expect(JSON.parse(fs.readFileSync(output, 'utf8')).status).toBe('unknown');
  });

  it('does not overwrite input, existing reports, or hardlink aliases', () => {
    const input = inputFile(), bytes = fs.readFileSync(input);
    expect(() => auditFile({ inputPath: input, outputPath: input, expectedRound: 3 })).toThrow(/不能覆盖/);
    const alias = path.join(dir, 'alias.json'); fs.linkSync(input, alias);
    expect(() => auditFile({ inputPath: input, outputPath: alias, expectedRound: 3 })).toThrow();
    const output = path.join(dir, 'prior-report.json'); fs.writeFileSync(output, 'keep-prior-report');
    expect(() => auditFile({ inputPath: input, outputPath: output, expectedRound: 3 })).toThrow();
    expect(fs.readFileSync(input).equals(bytes)).toBe(true);
    expect(fs.readFileSync(output, 'utf8')).toBe('keep-prior-report');
  });

  it('refuses relative paths and missing or duplicate round flags', () => {
    const input = inputFile(), output = path.join(dir, 'report.json');
    expect(cli(['--input', 'input.json', '--output', output, '--round', '3']).status).toBe(2);
    expect(cli(['--input', input, '--output', 'output.json', '--round', '3']).status).toBe(2);
    expect(cli(['--input', input, '--output', output]).status).toBe(2);
    expect(cli(['--input', input, '--output', output, '--round', '3', '--round', '3']).status).toBe(2);
    expect(fs.existsSync(output)).toBe(false);
  });

  it('handles malformed JSON without changing source or creating a successful report', () => {
    const input = inputFile(); fs.writeFileSync(input, '{not-json');
    const output = path.join(dir, 'report.json');
    const result = cli(['--input', input, '--output', output, '--round', '3']);
    expect(result.status).toBe(2);
    expect(JSON.parse(result.stderr).status).toBe('unknown');
    expect(fs.readFileSync(input, 'utf8')).toBe('{not-json');
    expect(fs.existsSync(output)).toBe(false);
  });

  it('accepts UTF8 BOM JSON and can enforce expected task identity', () => {
    const input = inputFile({ ...evidence(), taskId: 'review-task' });
    fs.writeFileSync(input, '\uFEFF' + fs.readFileSync(input, 'utf8'));
    const output = path.join(dir, 'report.json');
    const result = cli(['--input', input, '--output', output, '--round', '3', '--task-id', 'review-task']);
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout).status).toBe('passed');
  });
});
