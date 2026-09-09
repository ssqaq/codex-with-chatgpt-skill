import { spawn, type ChildProcess } from "node:child_process";
import readline from "node:readline";
import type { Logger } from "../logger/index.js";
import { nullLogger } from "../logger/index.js";
import { findBinary } from "./detect.js";
import type { TunnelDoctorReport, TunnelProvider, TunnelStatus } from "./provider.js";
import { SERVICE_NAME } from "../version.js";

const CONNECTED_RE = /registered tunnel connection/i;
const HOSTNAME_RE = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i;
const HEALTH_CHECK_INTERVAL_MS = 250;
const HEALTH_CHECK_TIMEOUT_MS = 5_000;

function isBridgeHealth(payload: unknown): boolean {
  if (!payload || typeof payload !== "object") return false;
  const health = payload as Record<string, unknown>;
  return health.service === SERVICE_NAME && health.status === "ok";
}

export interface CloudflaredNamedTunnelOptions {
  tunnelName: string;
  hostname: string;
  logger?: Logger;
  binaryOverride?: string;
  startTimeoutMs?: number;
  fetchImpl?: (input: string | URL, init?: RequestInit) => Promise<Response>;
  spawnImpl?: (
    command: string,
    args: string[],
    options: { stdio: ["ignore", "pipe", "pipe"]; windowsHide: true }
  ) => ChildProcess;
}

export function normalizeNamedTunnelHostname(hostname: string): string {
  const normalized = hostname.trim().toLowerCase().replace(/\.$/, "");
  if (!HOSTNAME_RE.test(normalized)) {
    throw new Error(`Invalid named tunnel hostname: ${hostname}`);
  }
  return normalized;
}

/**
 * Locally-managed Cloudflare named tunnel.
 *
 * The tunnel object and its DNS route are provisioned once with cloudflared.
 * This provider only starts and monitors the connector process, so the public
 * URL remains stable across bridge restarts.
 */
export class CloudflaredNamedTunnel implements TunnelProvider {
  readonly name = "cloudflare-named";
  private readonly tunnelName: string;
  private readonly hostname: string;
  private readonly logger: Logger;
  private readonly binaryOverride?: string;
  private readonly startTimeoutMs: number;
  private readonly fetchImpl: NonNullable<CloudflaredNamedTunnelOptions["fetchImpl"]>;
  private readonly spawnImpl: NonNullable<CloudflaredNamedTunnelOptions["spawnImpl"]>;
  private child: ChildProcess | null = null;
  private connected = false;
  private lastError: string | null = null;
  private starting: Promise<string> | null = null;
  private cancelStart: (() => void) | null = null;

  constructor(opts: CloudflaredNamedTunnelOptions) {
    const tunnelName = opts.tunnelName.trim();
    if (!tunnelName || tunnelName.length > 128) {
      throw new Error("Named tunnel name must be between 1 and 128 characters");
    }
    this.tunnelName = tunnelName;
    this.hostname = normalizeNamedTunnelHostname(opts.hostname);
    this.logger = opts.logger ?? nullLogger;
    this.binaryOverride = opts.binaryOverride;
    this.startTimeoutMs = opts.startTimeoutMs ?? 45_000;
    this.fetchImpl = opts.fetchImpl ?? ((input, init) => fetch(input, init));
    this.spawnImpl = opts.spawnImpl ?? ((command, args, spawnOptions) => spawn(command, args, spawnOptions));
  }

  private binary(): string | null {
    return this.binaryOverride ?? findBinary("cloudflared");
  }

  private publicUrl(): string {
    return `https://${this.hostname}`;
  }

  async start(localPort: number): Promise<string> {
    if (this.child && this.connected) return this.publicUrl();
    if (this.starting) return this.starting;
    const starting = this.startProcess(localPort);
    this.starting = starting;
    try {
      return await starting;
    } finally {
      if (this.starting === starting) this.starting = null;
    }
  }

  private startProcess(localPort: number): Promise<string> {
    const bin = this.binary();
    if (!bin) {
      throw new Error(
        "cloudflared is not installed. Install it (e.g. `brew install cloudflared`) and retry."
      );
    }

    return new Promise<string>((resolve, reject) => {
      const child = this.spawnImpl(
        bin,
        [
          "tunnel",
          "--no-autoupdate",
          "--url",
          `http://127.0.0.1:${localPort}`,
          "run",
          this.tunnelName,
        ],
        { stdio: ["ignore", "pipe", "pipe"], windowsHide: true }
      );
      this.child = child;
      this.connected = false;
      this.lastError = null;
      let settled = false;
      let registered = false;

      const closeReaders = (): void => {
        child.stdout?.destroy();
        child.stderr?.destroy();
      };
      const isAlive = (): boolean => this.child === child;
      const finish = (fn: () => void, closeOutput = true): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        if (closeOutput) closeReaders();
        if (this.cancelStart) this.cancelStart = null;
        fn();
      };
      const fail = (error: unknown): void => {
        finish(() => {
          try {
            child.kill("SIGTERM");
          } catch {
            // Process may have exited already.
          }
          if (this.child === child) {
            this.child = null;
            this.connected = false;
          }
          reject(error instanceof Error ? error : new Error(String(error)));
        });
      };
      this.cancelStart = () => fail(new Error("Named tunnel start stopped"));
      const timeout = setTimeout(() => {
        if (!settled) {
          this.lastError = "Named tunnel start timed out";
          fail(new Error(this.lastError));
        }
      }, this.startTimeoutMs);

      const waitForHealth = async (): Promise<void> => {
        while (!settled && registered) {
          if (!isAlive()) {
            fail(new Error("cloudflared exited before the public health endpoint became ready"));
            return;
          }
          try {
            const response = await this.fetchImpl(`${this.publicUrl()}/health`, {
              redirect: "error",
              signal: AbortSignal.timeout(HEALTH_CHECK_TIMEOUT_MS),
            });
            if (response.ok && isBridgeHealth(await response.json().catch(() => null))) {
              this.connected = true;
              this.logger.info(`Named tunnel established: ${this.publicUrl()}`);
              // Keep consuming cloudflared output after readiness so the
              // long-lived process remains observable and does not hit a
              // closed stdout/stderr pipe.
              finish(() => resolve(this.publicUrl()), false);
              return;
            }
            await response.body?.cancel().catch(() => undefined);
            this.lastError = `Health check returned HTTP ${response.status}`;
          } catch (error) {
            this.lastError = error instanceof Error ? error.message : String(error);
          }
          if (!settled) await new Promise((resolveWait) => setTimeout(resolveWait, HEALTH_CHECK_INTERVAL_MS));
        }
      };

      const scan = (stream: NodeJS.ReadableStream): void => {
        const rl = readline.createInterface({ input: stream });
        rl.on("line", (line) => {
          if (CONNECTED_RE.test(line) && !registered) {
            registered = true;
            void waitForHealth().catch((error) => fail(error));
          }
          if (/\b(error|failed|fatal)\b/i.test(line)) {
            this.lastError = line.slice(0, 400);
            this.logger.debug(`cloudflared: ${line.slice(0, 400)}`);
          }
        });
      };
      if (child.stdout) scan(child.stdout);
      if (child.stderr) scan(child.stderr);

      child.on("error", (error) => {
        fail(error);
      });
      child.on("exit", (code) => {
        const wasStarting = !this.connected;
        this.logger.warn(`cloudflared named tunnel exited with code ${code}`);
        this.child = null;
        this.connected = false;
        if (wasStarting) {
          fail(
            new Error(
              `cloudflared exited (code ${code}) before establishing the named tunnel${
                this.lastError ? `: ${this.lastError}` : ""
              }`
            )
          );
        }
      });
    });
  }

  async stop(): Promise<void> {
    this.cancelStart?.();
    if (this.child) {
      this.child.kill("SIGTERM");
      this.child = null;
    }
    this.connected = false;
  }

  async restart(localPort: number): Promise<string> {
    await this.stop();
    return this.start(localPort);
  }

  status(): TunnelStatus {
    return {
      running: this.child !== null && this.connected,
      url: this.connected ? this.publicUrl() : null,
      provider: this.name,
      detail: this.lastError ?? undefined,
    };
  }

  getPublicUrl(): string | null {
    return this.connected ? this.publicUrl() : null;
  }

  async doctor(): Promise<TunnelDoctorReport> {
    const bin = this.binary();
    const problems: string[] = [];
    if (!bin) problems.push("cloudflared binary not found");
    if (bin && !this.child) problems.push("named tunnel process not running");
    if (this.child && !this.connected) problems.push("named tunnel is not connected yet");
    return {
      provider: this.name,
      binaryFound: bin !== null,
      binaryPath: bin,
      running: this.child !== null && this.connected,
      url: this.connected ? this.publicUrl() : null,
      problems,
    };
  }
}
