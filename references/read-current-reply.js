// Use only a reader backed by the current host's documented browser API.
// The optional adapter returns JUST the current assistant reply, not a whole page/history.
// It must establish completion from the UI, never from the presence of CONSENSUS.
function readerError(code, message) {
  return Object.assign(new Error(message), { code });
}
function timestamp(value) {
  if (typeof value !== 'string' || !/(?:Z|[+-]\d{2}:\d{2})$/i.test(value) || !Number.isFinite(Date.parse(value))) {
    throw readerError('invalid-observation', '观察时间缺失时区或无效；保留原始证据，不补造时间。');
  }
  return Date.parse(value);
}
export function normalizeCurrentReply(raw, taskId, round) {
  if (!raw || typeof raw.text !== 'string' || typeof raw.complete !== 'boolean') {
    throw readerError('invalid-observation', '读取器必须返回真实助手正文 text 和布尔完成状态 complete。');
  }
  const observedAt = raw.observedAt ?? new Date().toISOString();
  timestamp(observedAt);
  const fields = name => [...raw.text.matchAll(new RegExp(`^${name}:[\\t ]*([^\\r\\n]+)$`, 'gm'))].map(m => m[1].trim());
  const tasks = fields('TASK_ID'), rounds = fields('ROUND');
  const current = tasks.length === 1 && tasks[0] === taskId && rounds.length === 1 && rounds[0] === String(round);
  // Streaming headers may be unfinished; completed or terminated wrong headers fail closed.
  const terminated = raw.text.slice(0, raw.text.lastIndexOf('\n') + 1);
  const wrongHeader = [...terminated.matchAll(/^TASK_ID:[\t ]*([^\r\n]+)$|^ROUND:[\t ]*([^\r\n]+)$/gm)]
    .some(m => m[1] ? m[1].trim() !== taskId : m[2].trim() !== String(round));
  return { observedAt, text: current ? raw.text : '', complete: current && raw.complete,
    identity: current ? 'current-round' : raw.text ? raw.complete || wrongHeader || tasks.length > 1 || rounds.length > 1 ? 'unverified-round' : 'awaiting-identity' : raw.complete ? 'unverified-round' : 'no-reply-yet' };
}

// Pass this round's context on EVERY call. Never capture a message from an older REPL cell.
export async function readCurrentReply(tab, message, taskId, round, options = {}) {
  if (typeof message !== 'string' || !message.trim() || typeof taskId !== 'string' || !taskId.trim() || !Number.isSafeInteger(round) || round < 1) {
    throw readerError('invalid-review-context', '读取本轮回复需要消息、任务号和正整数轮次。');
  }
  const readStartedAt = Date.now();
  let raw;
  if (typeof options.readObservation === 'function') {
    // The host-specific callback is responsible for locating the adjacent assistant message.
    // This shared helper still verifies TASK_ID/ROUND; an adapter cannot skip identity checks.
    raw = await options.readObservation({ tab, message, taskId, round });
  } else if (tab?.playwright && typeof tab.playwright.getByText === 'function') {
    // Legacy adapter: use ONLY when this exact API is actually documented by that host.
    raw = await tab.playwright.getByText(message, { exact: true }).first().evaluate(el => {
      const reply = el.closest('.ds-message')?.parentElement.nextElementSibling?.querySelector('.ds-message');
      const text = reply?.querySelector('.ds-assistant-message-main-content')?.innerText ?? '';
      const bar = reply?.nextElementSibling;
      return { text, complete: !!bar?.matches('.ds-flex') && bar.querySelectorAll('[role="button"]').length >= 3 };
    });
  } else {
    throw readerError('unsupported-browser-reader', '当前宿主未提供旧读取接口；请用已公开的浏览器 API 传入 readObservation，不猜接口或另开连接。');
  }
  const observation = normalizeCurrentReply(raw, taskId, round);
  const observed = timestamp(observation.observedAt);
  if (observed < readStartedAt || observed > Date.now()) {
    throw readerError('invalid-observation', '返回的观察不在本次真实读取时间范围内，不能把旧缓存当作新的页面检查。');
  }
  return observation;
}

// A bounded read batch, not a background scheduler. It never sends or advances a round.
// singleRead is for hosts which schedule/wait internally and forbid explicit polling sleeps.
// previousObservedAt must be the last actual saved observation; it includes inter-call overhead.
export async function pollCurrentReply(tab, message, taskId, round, options = {}) {
  const observations = [];
  const started = Date.now();
  const deadline = started + 20000;
  let previous = started;
  let maxCheckIntervalMs = 0;
  const intervalScope = options.previousObservedAt == null ? 'dispatch-only' : 'previous-observation';
  const result = error => ({ observations, error, elapsedMs: Date.now() - started,
    timing: { intervalScope, maxCheckIntervalMs, limitMs: 30000 } });
  try {
    if (options.previousObservedAt != null) {
      previous = timestamp(options.previousObservedAt);
      if (previous > started) throw readerError('invalid-observation', '上次观察时间在本次调用之后，不能据此计算检查间隔。');
    }
  } catch (error) { return result({ code: error.code, message: error.message }); }
  while (true) {
    let observation;
    try {
      observation = await readCurrentReply(tab, message, taskId, round, options);
    } catch (error) {
      return result({ code: error?.code ?? 'read-failed', message: String(error?.message ?? error) });
    }
    if (observation.identity === 'unverified-round') {
      return result({ code: 'unverified-round', message: '回复身份不匹配，核对当前消息定位后再继续。' });
    }
    const observed = timestamp(observation.observedAt);
    if (observed < previous || ((observations.length > 0 || options.previousObservedAt != null) && observed === previous) || observed > Date.now()) {
      return result({ code: 'invalid-observation', message: '观察时间倒序、重复或位于未来；不计作成功检查。' });
    }
    maxCheckIntervalMs = Math.max(maxCheckIntervalMs, observed - previous);
    previous = observed;
    observations.push(observation);
    if (maxCheckIntervalMs > 30000) {
      return result({ code: 'observation-gap-exceeded', message: '实际检查间隔超过30秒。真实回复已保留，但不能把本轮速度验收记为通过。' });
    }
    if (options.singleRead || observation.complete || Date.now() >= deadline) return result(null);
    await new Promise(resolve => setTimeout(resolve, Math.min(5000, deadline - Date.now())));
    if (Date.now() >= deadline) return result(null);
  }
}
