import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { pathToFileURL } from 'node:url';

export const CHECK_LIMIT_MS = 30_000;
const NS_PER_MS = 1_000_000n;
const LIMIT_NS = BigInt(CHECK_LIMIT_MS) * NS_PER_MS;
const MAX_OBSERVATIONS = 10_000;
const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const positiveInteger = value => Number.isSafeInteger(value) && value > 0;

// Parse explicit-offset instants without truncating sub-millisecond precision at the limit.
function instant(value) {
  if (typeof value !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!m) return null;
  const [year, month, day, hour, minute, second] = m.slice(1, 7).map(Number);
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return null;
  const whole = `${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}Z`;
  const ms = Date.parse(whole);
  if (!Number.isFinite(ms) || new Date(ms).toISOString().slice(0, 19) !== whole.slice(0, 19)) return null;
  const offsetHour = Number(m[10] ?? 0), offsetMinute = Number(m[11] ?? 0);
  if (offsetHour > 23 || offsetMinute > 59) return null;
  const offset = (m[9] === '-' ? -1 : 1) * (offsetHour * 60 + offsetMinute);
  return BigInt(ms) * NS_PER_MS + BigInt((m[7] ?? '').padEnd(9, '0')) - BigInt(offset) * 60_000_000_000n;
}

/** Pure audit: supplied evidence is not proof that a browser was actually observed. */
export function auditReviewObservations(input, { expectedRound, expectedTaskId } = {}) {
  const issues = [];
  const add = (severity, code, message, observationIndex) => issues.push({ severity, code, message,
    ...(observationIndex === undefined ? {} : { observationIndex }) });
  const readInstant = (value, label, index) => {
    if (value === undefined || value === null || value === '') {
      add('unknown', 'MISSING_TIMESTAMP', `${label}未记录，不能补造。`, index);
      return null;
    }
    const result = instant(value);
    if (result === null) add('failed', 'INVALID_TIMESTAMP', `${label}不是合法且带明确时区的时间。`, index);
    return result;
  };
  const data = isRecord(input) ? input : {};
  if (!isRecord(input)) add('unknown', 'MISSING_EVIDENCE', '缺少有效的本轮原始观察对象。');
  const round = positiveInteger(data.round) ? data.round : null;
  if (round === null) add('unknown', 'MISSING_ROUND', '输入文件缺少有效的轮数。');
  if (!positiveInteger(expectedRound)) add('unknown', 'EXPECTED_ROUND_REQUIRED', '必须指定要核对的轮数，不能仅信任文件自报轮数。');
  else if (round !== null && round !== expectedRound) add('failed', 'WRONG_ROUND', '输入文件不是要求核对的轮次。');
  if (expectedTaskId !== undefined) {
    if (typeof expectedTaskId !== 'string' || !expectedTaskId.trim()) add('unknown', 'INVALID_EXPECTED_TASK', '预期任务标识无效。');
    else if (typeof data.taskId !== 'string' || !data.taskId) add('unknown', 'MISSING_TASK_ID', '未记录任务标识，无法独立核对任务归属。');
    else if (data.taskId !== expectedTaskId) add('failed', 'WRONG_TASK', '输入文件属于其他任务。');
  }
  const submitted = readInstant(data.submittedAt, '提交时间');
  const observations = Array.isArray(data.observations) && data.observations.length <= MAX_OBSERVATIONS ? data.observations : [];
  if (!observations.length) add('unknown', 'MISSING_OBSERVATIONS', '没有可核对的逐次网页观察。');
  if (Array.isArray(data.observations) && data.observations.length > MAX_OBSERVATIONS) add('failed', 'TOO_MANY_OBSERVATIONS', '观察条数超出本地验收上限。');
  const times = [];
  const intervals = [];
  const overruns = [];
  let previous = null, sawComplete = false;
  observations.forEach((value, index) => {
    const row = isRecord(value) ? value : {};
    if (!isRecord(value)) add('unknown', 'INVALID_OBSERVATION', '观察记录不是有效对象。', index);
    const at = readInstant(row.observedAt, '观察时间', index);
    times.push(at);
    if (row.round !== undefined && row.round !== round) add('failed', 'WRONG_OBSERVATION_ROUND', '观察记录与本轮轮数不符。', index);
    const task = expectedTaskId ?? data.taskId;
    if (row.taskId !== undefined && task !== undefined && row.taskId !== task) add('failed', 'WRONG_OBSERVATION_TASK', '观察记录属于其他任务。', index);
    if (typeof row.complete !== 'boolean') add('unknown', 'MISSING_COMPLETION_FLAG', '没有明确记录回复是否完成。', index);
    if (row.identity !== undefined && !['current-round', 'awaiting-identity', 'no-reply-yet'].includes(row.identity)) {
      add('failed', 'WRONG_IDENTITY', '观察身份不匹配或无效，不能作为本轮成功证据。', index);
    }
    if (row.complete === true && row.identity !== 'current-round') {
      add(row.identity === undefined ? 'unknown' : 'failed', 'UNVERIFIED_COMPLETE_REPLY', '完整回复没有匹配当前轮次的身份标记。', index);
    }
    if (sawComplete) add('failed', 'OBSERVATION_AFTER_COMPLETION', '完成后仍追加观察，无法当作同一段等待记录验收。', index);
    if (row.complete === true) sawComplete = true;
    if (at !== null && submitted !== null && at < submitted) add('failed', 'OBSERVATION_BEFORE_SUBMISSION', '观察时间早于本轮提交时间。', index);
    if (index > 0 && at !== null && previous !== null) {
      const gap = at - previous;
      if (gap <= 0n) add('failed', gap === 0n ? 'DUPLICATE_TIMESTAMP' : 'OUT_OF_ORDER_TIMESTAMP', '观察时间重复或倒序，不能排序后伪装成有效检查。', index);
      else {
        intervals.push(gap);
        if (gap > LIMIT_NS) overruns.push({ kind: 'between-observations', fromIndex: index - 1, toIndex: index,
          actualMs: Number(gap) / 1e6, excessMs: Number(gap - LIMIT_NS) / 1e6 });
      }
    }
    previous = at;
  });
  const first = times[0] ?? null, last = times.at(-1) ?? null;
  const firstDelay = submitted !== null && first !== null && first >= submitted ? first - submitted : null;
  if (firstDelay !== null && firstDelay > LIMIT_NS) overruns.unshift({ kind: 'submission-to-first-observation', toIndex: 0,
    actualMs: Number(firstDelay) / 1e6, excessMs: Number(firstDelay - LIMIT_NS) / 1e6 });
  const lastRow = observations.at(-1);
  const completed = isRecord(lastRow) && lastRow.complete === true && lastRow.identity === 'current-round';
  if (observations.length && !completed) add('unknown', 'FINAL_REPLY_NOT_VERIFIED_COMPLETE', '最后一次观察没有确认本轮完整回复，不能判定复测通过。');
  const completeDelay = completed && submitted !== null && last !== null && last >= submitted ? last - submitted : null;
  if (overruns.length) add('failed', 'CHECK_INTERVAL_EXCEEDED', '实际检查空档超过30秒；评审意见同意也不能覆盖这一失败。');
  const failed = issues.some(issue => issue.severity === 'failed');
  const status = failed ? 'failed' : issues.length ? 'unknown' : 'passed';
  const maxGap = intervals.length ? intervals.reduce((a, b) => a > b ? a : b) : null;
  const ms = value => value === null ? null : Number(value) / 1e6;
  return {
    schemaVersion: 1, auditKind: 'review-observation-timing', status,
    speedTargetMet: overruns.length ? false : status === 'passed' ? true : null,
    limitMs: CHECK_LIMIT_MS, round, expectedRound: positiveInteger(expectedRound) ? expectedRound : null,
    observationCount: observations.length,
    timing: { firstCheckDelayMs: ms(firstDelay), maxCheckIntervalMs: ms(maxGap), timeoutCount: overruns.length,
      completeReplyObservedDelayMs: ms(completeDelay) },
    overruns, issues,
    ignoredSummaryFields: Object.keys(data).filter(key => !['round', 'taskId', 'submittedAt', 'observations'].includes(key)),
    limitations: [
      '只核对输入文件声称的原始时间、轮次和完成标记；文件本身不能证明真实网页访问、实际生成速度或发送回执。',
      'DECISION或CONSENSUS是评审意见，不是速度达标、执行许可或发布许可。',
      '未记录的数据不补造；独立报告不改历史，失败不能靠后续一轮同意覆盖，修复后需要重新完整复测3至4轮。',
    ],
  };
}

export const auditExitCode = report => report.status === 'passed' ? 0 : report.status === 'failed' ? 1 : 2;

/** Read evidence and create a NEW report. Existing files, links and histories are never overwritten. */
export function auditReviewObservationFile({ inputPath, outputPath, expectedRound, expectedTaskId }) {
  if (typeof inputPath !== 'string' || !path.isAbsolute(inputPath) || typeof outputPath !== 'string' || !path.isAbsolute(outputPath)) {
    throw new Error('输入和输出必须是绝对路径。');
  }
  if (path.resolve(inputPath) === path.resolve(outputPath)) throw new Error('输出不能覆盖输入证据。');
  const stat = fs.statSync(inputPath);
  if (!stat.isFile() || stat.size > 4 * 1024 * 1024) throw new Error('输入必须是4MB以内的本地JSON文件。');
  const bytes = fs.readFileSync(inputPath);
  let data;
  try { data = JSON.parse(bytes.toString('utf8').replace(/^\uFEFF/, '')); }
  catch { throw new Error('输入JSON无法解析；历史文件未修改。'); }
  const report = { ...auditReviewObservations(data, { expectedRound, expectedTaskId }),
    generatedAt: new Date().toISOString(), source: { path: path.resolve(inputPath), sha256: createHash('sha256').update(bytes).digest('hex') } };
  // wx is atomic exclusive creation; it also refuses output aliases/hardlinks/symlinks that already exist.
  fs.writeFileSync(outputPath, `${JSON.stringify(report, null, 2)}\n`, { encoding: 'utf8', flag: 'wx' });
  return report;
}

function main(args) {
  const usage = '用法：node audit-review-observations.mjs --input <原始观察JSON绝对路径> --output <新的报告JSON绝对路径> --round <轮数> [--task-id <预期任务标识>]\n退出码：0=本文件时间验收通过；1=失败；2=证据不足或命令错误。报告不是网页真实性、执行或发布许可。';
  if (args.length === 1 && ['--help', '-h'].includes(args[0])) { console.log(usage); return 0; }
  try {
    const flags = {};
    for (let i = 0; i < args.length; i += 2) {
      if (!['--input', '--output', '--round', '--task-id'].includes(args[i]) || flags[args[i]] !== undefined || !args[i + 1] || args[i + 1].startsWith('--')) throw new Error(usage);
      flags[args[i]] = args[i + 1];
    }
    if (!flags['--input'] || !flags['--output'] || !/^[1-9]\d*$/.test(flags['--round'] ?? '') || !positiveInteger(Number(flags['--round']))) throw new Error(usage);
    const report = auditReviewObservationFile({ inputPath: flags['--input'], outputPath: flags['--output'],
      expectedRound: Number(flags['--round']), expectedTaskId: flags['--task-id'] });
    console.log(JSON.stringify(report, null, 2));
    return auditExitCode(report);
  } catch (error) {
    console.error(JSON.stringify({ status: 'unknown', error: error instanceof Error ? error.message : String(error), historyModified: false }));
    return 2;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  process.exitCode = main(process.argv.slice(2));
}
