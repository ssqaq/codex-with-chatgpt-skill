import os from "node:os";
import path from "node:path";
import fs from "node:fs";

/**
 * State directory resolution, following OS conventions.
 * Override with C2C_STATE_DIR (used heavily by tests).
 */
export function getStateDir(): string {
  const override = process.env.C2C_STATE_DIR;
  if (override && override.trim() !== "") return path.resolve(override);
  const home = os.homedir();
  switch (process.platform) {
    case "darwin":
      return path.join(home, "Library", "Application Support", "codex-with-chatgpt");
    case "win32":
      return path.join(process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local"), "codex-with-chatgpt");
    default: {
      const base = process.env.XDG_STATE_HOME ?? path.join(home, ".local", "state");
      return path.join(base, "codex-with-chatgpt");
    }
  }
}

export function ensureDir(dir: string): string {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
}

export function stateSubdir(name: string): string {
  return ensureDir(path.join(getStateDir(), name));
}

/** Write a JSON file with owner-only permissions. */
export function writeSecureJson(file: string, data: unknown): void {
  ensureDir(path.dirname(file));
  const temporary = `${file}.${process.pid}.${Date.now()}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(data, null, 2), { mode: 0o600 });
  try {
    fs.chmodSync(temporary, 0o600);
  } catch {
    // best effort on platforms without chmod semantics
  }
  try {
    fs.renameSync(temporary, file);
  } catch (error) {
    // Windows may refuse to replace an existing file with rename; remove only
    // the known destination and retry, while keeping the temp file private.
    if ((error as NodeJS.ErrnoException).code !== "EEXIST" && (error as NodeJS.ErrnoException).code !== "EPERM") {
      fs.rmSync(temporary, { force: true });
      throw error;
    }
    fs.rmSync(file, { force: true });
    fs.renameSync(temporary, file);
  }
}

export function readJsonIfExists<T>(file: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch {
    return null;
  }
}

export const DEFAULT_PORT = 48765;
export const DEFAULT_HOST = "127.0.0.1";
