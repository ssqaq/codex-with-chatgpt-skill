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
