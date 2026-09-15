import { afterEach, describe, expect, it, vi } from 'vitest';
const file = new URL('../../references/read-current-reply.js', import.meta.url).href;
const { pollCurrentReply } = await import(/* @vite-ignore */ file);
const current = (complete = false) => ({text: 'TASK_ID: task\nROUND: 1\nDECISION: CONSENSUS',complete});
function mock(read: () => Promise<unknown>) {
  return {playwright: {getByText: vi.fn(() => ({first: () => ({evaluate: read})}))}};
}
afterEach(() => vi.useRealTimers());
describe('bounded CUA reader', () => {
  it('returns immediately on completion without another check', async () => {
    const read = vi.fn(async () => current(true));
    const result = await pollCurrentReply(mock(read),'m','task',1);
    expect(result.error).toBeNull(); expect(result.observations).toHaveLength(1);
    expect(result.observations[0].complete).toBe(true); expect(read).toHaveBeenCalledTimes(1);
  });
  it('stops scheduling at 20 seconds without inventing completion', async () => {
    vi.useFakeTimers(); const read = vi.fn(async () => ({text:'',complete:false}));
    const done = pollCurrentReply(mock(read),'m','task',1);
    await vi.advanceTimersByTimeAsync(20000); const result = await done;
    expect(read).toHaveBeenCalledTimes(4); expect(result.elapsedMs).toBe(20000);
    expect(result.observations.every((o: any) => !o.complete)).toBe(true);
  });
  it('returns on the first complete observation inside the batch', async () => {
    vi.useFakeTimers(); const read = vi.fn().mockResolvedValueOnce(current()).mockResolvedValue(current(true));
    const done = pollCurrentReply(mock(read),'m','task',1);
    await vi.advanceTimersByTimeAsync(5000); const result = await done;
    expect(read).toHaveBeenCalledTimes(2); expect(result.elapsedMs).toBe(5000);
    expect(result.observations[1].complete).toBe(true);
  });
  it('does not mistake a streaming partial header for a wrong completed round', async () => {
    vi.useFakeTimers();
    const read = vi.fn().mockResolvedValueOnce({text:'TASK_ID: ta',complete:false}).mockResolvedValue(current(true));
    const done = pollCurrentReply(mock(read),'m','task',1);
    await vi.advanceTimersByTimeAsync(5000); const result = await done;
    expect(result.error).toBeNull(); expect(result.observations[0]).toMatchObject({identity:'awaiting-identity',text:'',complete:false});
    expect(result.observations[1].complete).toBe(true);
  });
  it('preserves successful observations and timestamps on a later read failure', async () => {
    vi.useFakeTimers(); vi.setSystemTime(100000);
    const read = vi.fn().mockResolvedValueOnce(current()).mockRejectedValueOnce(new Error('connection lost'));
    const done = pollCurrentReply(mock(read),'m','task',1);
    await vi.advanceTimersByTimeAsync(5000); const result = await done;
    expect(result.error.code).toBe('read-failed'); expect(result.observations).toHaveLength(1);
    expect(result.observations[0].observedAt).toBe(new Date(100000).toISOString());
    expect(result.observations[0].complete).toBe(false);
  });
  it('does not record a fabricated observation when the first read fails', async () => {
    const result = await pollCurrentReply(mock(async () => {throw new Error('unavailable');}),'m','task',1);
    expect(result.error.code).toBe('read-failed'); expect(result.observations).toEqual([]);
  });
  it('exits immediately for another round and does not save its text as progress', async () => {
    const read = vi.fn(async () => current(true));
    const result = await pollCurrentReply(mock(read),'m2','task',2);
    expect(result.error.code).toBe('unverified-round'); expect(result.observations).toEqual([]);
    expect(read).toHaveBeenCalledTimes(1);
  });
  it('includes slow tool calls in elapsed time and never starts another read past deadline', async () => {
    vi.useFakeTimers(); const read = vi.fn(async () => {await new Promise(r => setTimeout(r,25000)); return current();});
    const done = pollCurrentReply(mock(read),'m','task',1);
    await vi.advanceTimersByTimeAsync(25000); const result = await done;
    expect(result.elapsedMs).toBe(25000); expect(read).toHaveBeenCalledTimes(1);
    expect(result.observations).toHaveLength(1);
  });
});

describe('documented host reader adapter and real observation gaps', () => {
  it('accepts an explicit host adapter without touching the legacy browser API', async () => {
    const tab = { get playwright(): never { throw new Error('legacy API must not be touched'); } };
    const readObservation = vi.fn(async () => current(true));
    const result = await pollCurrentReply(tab, 'm', 'task', 1, { readObservation, singleRead: true });
    expect(result.error).toBeNull();
    expect(readObservation).toHaveBeenCalledTimes(1);
    const args = readObservation.mock.calls[0] as unknown as [Record<string, unknown>];
    expect(args[0].tab).toBe(tab); expect(args[0].message).toBe('m');
    expect(args[0].taskId).toBe('task'); expect(args[0].round).toBe(1);
    expect(result.observations[0]).toMatchObject({complete: true, identity: 'current-round'});
  });
  it('reports unsupported host APIs once instead of guessing another connection', async () => {
    const result = await pollCurrentReply({}, 'm', 'task', 1);
    expect(result.error.code).toBe('unsupported-browser-reader');
    expect(result.observations).toEqual([]);
  });
  it('singleRead never schedules explicit sleeps even when the reply is unfinished', async () => {
    vi.useFakeTimers(); const readObservation = vi.fn(async () => current());
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation, singleRead: true });
    expect(result.error).toBeNull(); expect(result.observations).toHaveLength(1);
    expect(readObservation).toHaveBeenCalledTimes(1); expect(vi.getTimerCount()).toBe(0);
  });
  it('keeps context and identity checks even if an adapter supplies its own identity', async () => {
    const readObservation = vi.fn(async () => ({...current(true), identity: 'current-round'}));
    const result = await pollCurrentReply({}, 'new-message', 'task', 2, { readObservation });
    expect(result.error.code).toBe('unverified-round'); expect(result.observations).toEqual([]);
  });
  it('keeps the completed reply but fails speed acceptance for the actual 55.554 second gap', async () => {
    vi.useFakeTimers(); vi.setSystemTime(Date.parse('2026-09-15T13:42:32.834Z'));
    const readObservation = vi.fn(async () => ({...current(true), observedAt: '2026-09-15T13:42:32.834Z'}));
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation, previousObservedAt: '2026-09-15T13:41:37.280Z' });
    expect(result.error.code).toBe('observation-gap-exceeded'); expect(result.observations[0].complete).toBe(true);
    expect(result.timing).toMatchObject({intervalScope: 'previous-observation', maxCheckIntervalMs: 55554, limitMs: 30000});
    expect(readObservation).toHaveBeenCalledTimes(1);
  });
  it.each([[30000, null], [30001, 'observation-gap-exceeded']])('does not round a %i ms gap into a pass', async (gap, code) => {
    vi.useFakeTimers(); vi.setSystemTime(100000 + Number(gap));
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation: async () => current(true), previousObservedAt: new Date(100000).toISOString() });
    expect(result.error?.code ?? null).toBe(code); expect(result.timing.maxCheckIntervalMs).toBe(gap);
  });
  it('includes a slow first browser read in the same 30 second limit', async () => {
    vi.useFakeTimers(); vi.setSystemTime(100000);
    const readObservation = vi.fn(async () => { await new Promise(r => setTimeout(r,31000)); return current(true); });
    const done = pollCurrentReply({}, 'm', 'task', 1, { readObservation });
    await vi.advanceTimersByTimeAsync(31000); const result = await done;
    expect(result.error.code).toBe('observation-gap-exceeded'); expect(result.observations[0].complete).toBe(true);
    expect(result.elapsedMs).toBe(31000); expect(readObservation).toHaveBeenCalledTimes(1);
  });
  it.each(['invalid','2026-09-15T13:41:37'])('rejects invalid saved timestamps without calling the browser: %s', async previousObservedAt => {
    const readObservation = vi.fn(async () => current(true));
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation, previousObservedAt });
    expect(result.error.code).toBe('invalid-observation'); expect(readObservation).not.toHaveBeenCalled();
  });
  it('rejects untrusted string completion values', async () => {
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation: async () => ({text: 'TASK_ID: task\nROUND: 1', complete: 'true'}) });
    expect(result.error.code).toBe('invalid-observation'); expect(result.observations).toEqual([]);
  });
  it('does not confuse completed empty content with waiting forever', async () => {
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation: async () => ({text:'',complete:true}) });
    expect(result.error.code).toBe('unverified-round'); expect(result.observations).toEqual([]);
  });
  it('does not allow a missing header value to swallow the next header line', async () => {
    const result = await pollCurrentReply({}, 'm', 'task', 1, { readObservation: async () => ({text:'TASK_ID:\nROUND: 1\nDECISION: CONSENSUS',complete:true}) });
    expect(result.error.code).toBe('unverified-round'); expect(result.observations).toEqual([]);
  });
});

describe('cross-dispatch timestamp guards', () => {
  it('rejects a duplicate timestamp from the preceding dispatch', async () => {
    vi.useFakeTimers(); vi.setSystemTime(105000);
    const result = await pollCurrentReply({}, 'm', 'task', 1, {
      readObservation: async () => ({...current(true), observedAt: new Date(100000).toISOString()}),
      previousObservedAt: new Date(100000).toISOString(),
    });
    expect(result.error.code).toBe('invalid-observation'); expect(result.observations).toEqual([]);
  });
  it('rejects future timestamps from the reader instead of shifting the deadline', async () => {
    vi.useFakeTimers(); vi.setSystemTime(100000);
    const result = await pollCurrentReply({}, 'm', 'task', 1, {
      readObservation: async () => ({...current(true), observedAt: new Date(105000).toISOString()}),
    });
    expect(result.error.code).toBe('invalid-observation'); expect(result.observations).toEqual([]);
  });
});

describe('fresh evidence per individual browser read', () => {
  it('rejects cached complete evidence that is newer than the previous dispatch but older than this read', async () => {
    vi.useFakeTimers(); vi.setSystemTime(600000);
    const result = await pollCurrentReply({}, 'm', 'task', 1, {
      previousObservedAt: new Date(100000).toISOString(),
      readObservation: async () => ({...current(true), observedAt: new Date(110000).toISOString()}),
    });
    expect(result.error.code).toBe('invalid-observation'); expect(result.observations).toEqual([]);
  });
  it('retains the first real read but rejects later cached observations in the same batch', async () => {
    vi.useFakeTimers(); vi.setSystemTime(100000);
    const readObservation = vi.fn()
      .mockResolvedValueOnce({...current(), observedAt: new Date(100000).toISOString()})
      .mockResolvedValueOnce({...current(true), observedAt: new Date(102000).toISOString()});
    const done = pollCurrentReply({}, 'm', 'task', 1, {readObservation});
    await vi.advanceTimersByTimeAsync(5000); const result = await done;
    expect(result.error.code).toBe('invalid-observation'); expect(result.observations).toHaveLength(1);
    expect(result.observations[0]).toMatchObject({complete:false, observedAt:new Date(100000).toISOString()});
    expect(readObservation).toHaveBeenCalledTimes(2);
  });
});
