#!/usr/bin/env node
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { spawnSync } from "node:child_process";

const here = path.dirname(fileURLToPath(import.meta.url));
const coreEntry = path.join(here, "..", "core", "bin", "c2c.js");

if (existsSync(coreEntry)) {
  const result = spawnSync(process.execPath, [coreEntry, ...process.argv.slice(2)], { stdio: "inherit" });
  process.exit(result.status ?? 1);
}

console.error(`找不到核心 CLI：${coreEntry}`);
process.exit(1);
