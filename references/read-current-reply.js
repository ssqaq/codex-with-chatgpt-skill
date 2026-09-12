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
  return { observedAt: new Date().toISOString(), text: current ? raw.text : '', complete: current && raw.complete,
    identity: current ? 'current-round' : raw.text ? 'unverified-round' : 'no-reply-yet' };
}
