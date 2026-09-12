// Copy this function into the host's documented CUA REPL after inspecting the DOM.
// Pass this round's message explicitly on EVERY call; never capture it from an older cell.
export async function readCurrentReply(tab, message, taskId, round) {
  const raw = await tab.playwright.getByText(message, { exact: true }).first().evaluate(el => {
    const reply = el.closest('.ds-message')?.parentElement.nextElementSibling?.querySelector('.ds-message');
    const text = reply?.querySelector('.ds-assistant-message-main-content')?.innerText ?? '';
    const bar = reply?.nextElementSibling;
    return { text, complete: !!bar?.matches('.ds-flex') && bar.querySelectorAll('[role="button"]').length >= 3 };
  });
  const fields = name => [...raw.text.matchAll(new RegExp(`^${name}:\\s*([^\\r\\n]+)$`, 'gm'))].map(m => m[1].trim());
  const tasks = fields('TASK_ID'), rounds = fields('ROUND');
  const current = tasks.length === 1 && tasks[0] === taskId && rounds.length === 1 && rounds[0] === String(round);
  // A streaming header can be incomplete. Reject completed/terminated wrong headers,
  // while an unfinished header remains a page check with no content progress.
  const terminated = raw.text.slice(0, raw.text.lastIndexOf('\n') + 1);
  const wrongHeader = [...terminated.matchAll(/^TASK_ID:\s*([^\r\n]+)$|^ROUND:\s*([^\r\n]+)$/gm)]
    .some(m => m[1] ? m[1].trim() !== taskId : m[2].trim() !== String(round));
  return { observedAt: new Date().toISOString(), text: current ? raw.text : '', complete: current && raw.complete,
    identity: current ? 'current-round' : raw.text ? raw.complete || wrongHeader || tasks.length > 1 || rounds.length > 1 ? 'unverified-round' : 'awaiting-identity' : 'no-reply-yet' };
}

// Run inside the documented CUA REPL. This helper only reads; it never sends or advances a round.
// At most 20 seconds of scheduling, including reads. A slow in-flight tool call still uses
// the host timeout: report its real elapsed time, never fake cancellation or a successful read.
export async function pollCurrentReply(tab, message, taskId, round) {
  const observations = [];
  const started = Date.now();
  const deadline = started + 20000;
  const result = error => ({ observations, error, elapsedMs: Date.now() - started });
  while (true) {
    let observation;
    try {
      observation = await readCurrentReply(tab, message, taskId, round);
    } catch (error) {
      return result({ code: 'read-failed', message: String(error?.message ?? error) });
    }
    if (observation.identity === 'unverified-round') {
      return result({ code: 'unverified-round', message: '回复身份不匹配，核对当前消息定位后再继续。' });
    }
    observations.push(observation);
    if (observation.complete || Date.now() >= deadline) return result(null);
    await new Promise(resolve => setTimeout(resolve, Math.min(5000, deadline - Date.now())));
    if (Date.now() >= deadline) return result(null);
  }
}
