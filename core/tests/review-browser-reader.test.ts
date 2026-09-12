import { describe, expect, it } from "vitest";

describe("browser reader keeps the requested round on every call", () => {
  it("selects each current message explicitly and rejects a stale complete reply", async () => {
    // DOM shape itself is verified on the real site; this fixture covers orchestration.
    const readerFile = new URL("../../references/read-current-reply.js", import.meta.url).href;
    const { readCurrentReply } = await import(/* @vite-ignore */ readerFile);
    const selected: string[] = [];
    let shownRound = 1;
    const tab = { playwright: { getByText: (message: string) => {
      selected.push(message);
      return { first: () => ({ evaluate: async () => ({ text: `TASK_ID: task\nROUND: ${shownRound}\nDECISION: CONSENSUS`, complete: true }) }) };
    } } };
    expect((await readCurrentReply(tab, "message-1", "task", 1)).complete).toBe(true);
    expect(await readCurrentReply(tab, "message-2", "task", 2)).toMatchObject({ complete: false, text: "", identity: "unverified-round" });
    shownRound = 2;
    expect((await readCurrentReply(tab, "message-2", "task", 2)).complete).toBe(true);
    expect(selected).toEqual(["message-1", "message-2", "message-2"]);
    expect((await readCurrentReply(tab, "message-2", "other-task", 2)).complete).toBe(false);
  });
});
