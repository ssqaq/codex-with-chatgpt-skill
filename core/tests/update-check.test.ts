import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { cleanup, makeTmpDir } from "./helpers.js";

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cliEntry = path.join(projectRoot, "src/cli/index.ts");

describe("update-check offline status", () => {
  it("does not claim the local version is current when the latest version is unconfirmed", () => {
    const stateDir = makeTmpDir("update-check-state");
    try {
      const today = new Date().toLocaleDateString("en-CA");
      fs.writeFileSync(
        path.join(stateDir, "update-check.json"),
        JSON.stringify({ date: today, updateAvailable: false, latestConfirmed: false, latestVersion: null }),
        "utf8"
      );
      const result = spawnSync(process.execPath, ["--import", "tsx", cliEntry, "update-check", "--json"], {
        cwd: projectRoot,
        encoding: "utf8",
        env: { ...process.env, C2C_STATE_DIR: stateDir },
      });
      expect(result.status).toBe(0);
      const payload = JSON.parse(result.stdout.trim()) as {
        latestConfirmed?: boolean;
        latestStatus?: string;
        needsUpdate?: boolean;
      };
      expect(payload.latestConfirmed).toBe(false);
      expect(payload.latestStatus).toBe("unconfirmed");
      expect(payload.needsUpdate).toBe(false);
    } finally {
      cleanup(stateDir);
    }
  });
});
