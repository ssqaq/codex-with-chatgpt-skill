# Codex with ChatGPT Skill Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use inline execution with task-by-task verification.

**Goal:** Implement all ten selected improvements: documentation correctness, enforceable post-change verification, safer backup/rollback, clearer image/model behavior, a shorter routed Skill, UI metadata, and OAuth/tunnel/image security hardening.

**Architecture:** Keep the read-only MCP boundary and existing session protocol. Add verification evidence to the persisted session checkpoint and make the CLI refuse an execution checkpoint without a passed local gate. Move long operational details from the Skill entrypoint into focused references while keeping the trigger and plain-language workflow in `SKILL.md`.

**Tech Stack:** TypeScript, Node.js 20+, Express, MCP SDK, Vitest, PowerShell, Bash, Markdown, GitHub Actions.

**Spec:** User-selected improvements 1–10 from the 2026-09-10 review.

## Global Constraints

- Use only `https://github.com/ssqaq/codex-with-chatgpt-skill` as the update repository.
- Preserve read-only MCP behavior and existing old-session/connector reuse.
- Do not upload images to ChatGPT file storage or call an external vision service.
- Use the built-in browser for ChatGPT/page checks.
- Do not expose credentials, tokens, private keys, or sensitive file contents.
- Every file mutation requires tests, diff review, and page verification when applicable before synchronization.

### Task 1: Correct user-facing documentation

**Files:**
- Modify: `core/README.md`
- Modify: `core/README.zh-CN.md`
- Modify: `README.md`
- Modify: `SKILL.md`
- Modify: `core/skill/SKILL.md`
- Modify: `core/docs/protocol.md`

- [ ] Replace every `XiaoDuoYa/codex-with-chatgpt` clone URL with `ssqaq/codex-with-chatgpt-skill`.
- [ ] Replace every `skill/SKILL.md` installation instruction with the repository-root `SKILL.md` path.
- [ ] State that images are read through the current connection and may count against the ChatGPT account's image/message allowance even though they are not saved to the file area.
- [ ] State that the model cannot be forced by this Skill; it uses the account-visible model and reports the actual model/strength when known.
- [ ] Correct update behavior to say dirty worktrees stop the update; remove any claim that the updater stashes automatically.
- [ ] Document the first-time setup's one-time choice and exact attachment path rule (`attachment=true` plus an absolute `codex-clipboard-*` temporary image path).
- [ ] Replace “repository is never uploaded” with “the repository is not uploaded as a whole; only permitted files/images are read and transmitted as needed.”
- [ ] Replace stale `V1` text with `VERSION`-based wording and add the old-session sync copyable prompt.

### Task 2: Persist and enforce post-change verification

**Files:**
- Modify: `core/src/session/state.ts`
- Modify: `core/src/cli/index.ts`
- Modify: `core/src/execution/records.ts`
- Modify: `core/tests/session.test.ts`
- Modify: `core/tests/record-cli.test.ts`
- Modify: `core/docs/protocol.md`

- [ ] Add checkpoint fields `selfCheckStatus`, `pageVerifyStatus`, `pageScope`, and `verificationAt`, with statuses `PASS`, `FAIL`, or `NOT_APPLICABLE` as appropriate.
- [ ] Add CLI options `--self-check`, `--page-verify`, `--page-scope`, and `--verification-at` to `c2c session set` and validate their combinations.
- [ ] Reject `EXECUTED_LOCAL`, `EXECUTED_SENT`, and `DONE` in consensus/coding workflows unless self-check is `PASS` and page verification is `PASS` or `NOT_APPLICABLE`.
- [ ] Record the evidence in execution records so ChatGPT can audit it through MCP.
- [ ] Add tests proving missing or failed evidence blocks completion and passed evidence survives reload.

### Task 3: Harden backup and rollback

**Files:**
- Modify: `scripts/backup.sh`
- Modify: `scripts/rollback.sh`
- Modify: `scripts/backup.ps1`
- Modify: `scripts/rollback.ps1`
- Modify: `scripts/update.sh`
- Modify: `scripts/update.ps1`
- Add/modify: script tests or CI smoke checks

- [ ] Save `checkout`, `skillDirectory`, `commit`, and timestamp in both manifests.
- [ ] Make Bash rollback read `skillDirectory` from the manifest instead of hard-coding `$HOME/.codex/skills/...`.
- [ ] Use millisecond timestamps plus a collision-safe suffix for backup directories.
- [ ] Validate manifest paths and required files before reset/copy.
- [ ] Keep dirty-worktree fail-closed behavior and test custom checkout/Skill paths.

### Task 4: Harden image reading and OAuth boundary

**Files:**
- Modify: `core/src/workspace/manager.ts`
- Modify: `core/src/auth/oauth.ts`
- Modify: `core/src/auth/store.ts`
- Modify: `core/src/bridge/server.ts`
- Modify: `core/src/pairing/manager.ts`
- Modify: `core/src/tunnel/cloudflared-named.ts`
- Modify: corresponding tests in `core/tests/`

- [ ] Add concurrency regression coverage for image reads and verify the two-reader limit under queued requests.
- [ ] Make image parsing stop correctly after JPEG SOS/EOI and add valid multi-encoder fixtures plus malformed-boundary tests.
- [ ] Recheck canonical path after opening or use an equivalent no-follow strategy to reduce image-read TOCTOU risk.
- [ ] Reject unknown OAuth scopes instead of expanding them to all supported scopes; cap and expire pending authorization requests.
- [ ] Canonicalize and restrict redirect URIs, cap/expire pairing IP counters, and trust forwarded headers only from configured proxies.
- [ ] Deduplicate named-tunnel starts and require a health check before reporting ready.

### Task 5: Split the Skill and add UI metadata

**Files:**
- Modify: `SKILL.md`
- Modify: `core/skill/SKILL.md`
- Add: `references/setup.md`
- Add: `references/protocol.md`
- Add: `references/security-and-images.md`
- Add: `agents/openai.yaml`
- Modify: `.github/workflows/ci.yml`

- [ ] Keep the entrypoint focused on trigger phrases, plain-language usage, routing, and hard constraints.
- [ ] Move long setup/protocol/security details into the three references and link them from both Skill copies.
- [ ] Add UI display name, short description, and a default prompt without disabling implicit invocation.
- [ ] Add CI checks for exact Skill-copy equality, stale repository URLs, conflicting `skill/` paths, and required image/model boundary wording.

### Task 6: Final verification and release

**Files:**
- Modify: `VERSION`
- Modify: `core/package.json`
- Modify: `core/src/version.ts`
- Modify: `CHANGELOG.md`

- [ ] Increment the patch/minor version only after all tasks pass.
- [ ] Run `corepack pnpm test`, `corepack pnpm typecheck`, `corepack pnpm build`, PowerShell/Bash syntax checks, and Skill validation with UTF-8 input.
- [ ] Review the complete diff and verify no secrets or unrelated files changed.
- [ ] Use the built-in browser to verify the GitHub repository page, Release page, and affected connection/settings page when applicable.
- [ ] Push only after all checks pass; verify remote SHA, Actions, Release, local checkout, installed Skill, and clean worktrees.
