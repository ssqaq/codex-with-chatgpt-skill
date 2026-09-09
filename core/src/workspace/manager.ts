import fs from "node:fs";
import path from "node:path";
import { createHash } from "node:crypto";
import readline from "node:readline";
import os from "node:os";
import { IgnoreRules } from "./ignore.js";
import { readJsonIfExists } from "../config/paths.js";

export type WorkspaceErrorCode =
  | "INVALID_PATH"
  | "PATH_OUTSIDE_WORKSPACE"
  | "ACCESS_DENIED_SENSITIVE_FILE"
  | "FILE_NOT_FOUND"
  | "NOT_A_FILE"
  | "NOT_A_DIRECTORY"
  | "BINARY_FILE"
  | "FILE_TOO_LARGE"
  | "UNSUPPORTED_IMAGE_FORMAT"
  | "INVALID_IMAGE"
  | "IMAGE_TOO_LARGE"
  | "IMAGE_DIMENSIONS_TOO_LARGE"
  | "IMAGE_READ_BUSY"
  | "ATTACHMENT_NOT_ALLOWED";

export class WorkspaceError extends Error {
  constructor(
    public code: WorkspaceErrorCode,
    message: string
  ) {
    super(message);
    this.name = "WorkspaceError";
  }
}

const CASE_INSENSITIVE = process.platform === "win32" || process.platform === "darwin";
const normCase = (p: string): string => (CASE_INSENSITIVE ? p.toLowerCase() : p);

export interface ReadFileResult {
  path: string;
  sizeBytes: number;
  totalLines: number;
  startLine: number;
  endLine: number;
  truncated: boolean;
  remainingLines: number;
  nextStartLine: number | null;
  content: string;
}

export interface ReadImageResult {
  path: string;
  source: "workspace" | "attachment";
  sizeBytes: number;
  mimeType: "image/png" | "image/jpeg" | "image/webp" | "image/gif";
  width: number;
  height: number;
  dataBase64: string;
}

export interface DirEntry {
  path: string;
  type: "file" | "dir";
  sizeBytes?: number;
}

export interface ListDirectoryResult {
  path: string;
  entries: DirEntry[];
  total: number;
  offset: number;
  limit: number;
  hasMore: boolean;
}

export interface ProjectConfig {
  name?: string;
  maxIterations?: number;
}

function parseProjectConfig(value: unknown): ProjectConfig {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const raw = value as Record<string, unknown>;
  const config: ProjectConfig = {};
  if (typeof raw.name === "string") config.name = raw.name;
  if (typeof raw.maxIterations === "number") config.maxIterations = raw.maxIterations;
  return config;
}

function stringRecord(value: unknown): Record<string, string> {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  const entries = Object.entries(value as Record<string, unknown>).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string"
  );
  return Object.fromEntries(entries);
}

const DEFAULT_MAX_LINES = 400;
const HARD_MAX_LINES = 2000;
const DEFAULT_MAX_BYTES = 256 * 1024;
const MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_IMAGE_WIDTH = 8192;
const MAX_IMAGE_HEIGHT = 8192;
const MAX_IMAGE_PIXELS = 40_000_000;
const MAX_CONCURRENT_IMAGE_READS = 2;
const MAX_QUEUED_IMAGE_READS = 8;

let activeImageReads = 0;
const imageReadWaiters: Array<() => void> = [];

type ImageMimeType = ReadImageResult["mimeType"];

const IMAGE_MIME_BY_EXTENSION: Record<string, ImageMimeType> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
};

function hasPrefix(data: Buffer, prefix: number[]): boolean {
  return data.length >= prefix.length && data.subarray(0, prefix.length).equals(Buffer.from(prefix));
}

function imageSignatureMatches(mimeType: ImageMimeType, data: Buffer): boolean {
  switch (mimeType) {
    case "image/png":
      return hasPrefix(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    case "image/jpeg":
      return hasPrefix(data, [0xff, 0xd8, 0xff]);
    case "image/gif":
      return data.length >= 6 && (data.subarray(0, 6).toString("ascii") === "GIF87a" || data.subarray(0, 6).toString("ascii") === "GIF89a");
    case "image/webp":
      return data.length >= 12 && data.subarray(0, 4).toString("ascii") === "RIFF" && data.subarray(8, 12).toString("ascii") === "WEBP";
  }
}

interface ImageInspection {
  width: number;
  height: number;
}

function invalidImage(): never {
  throw new WorkspaceError("INVALID_IMAGE", "Image data is truncated or structurally invalid.");
}

function checkDimensions(width: number, height: number): ImageInspection {
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1 ||
    height < 1 ||
    width > MAX_IMAGE_WIDTH ||
    height > MAX_IMAGE_HEIGHT ||
    width * height > MAX_IMAGE_PIXELS
  ) {
    throw new WorkspaceError(
      "IMAGE_DIMENSIONS_TOO_LARGE",
      `Image dimensions exceed the limit (${MAX_IMAGE_WIDTH}x${MAX_IMAGE_HEIGHT}, ${MAX_IMAGE_PIXELS} pixels).`
    );
  }
  return { width, height };
}

function inspectPng(data: Buffer): ImageInspection {
  if (!imageSignatureMatches("image/png", data) || data.length < 33) invalidImage();
  let offset = 8;
  let dimensions: ImageInspection | null = null;
  let hasIdat = false;
  let hasIend = false;
  while (offset + 12 <= data.length) {
    const length = data.readUInt32BE(offset);
    const end = offset + 12 + length;
    if (end > data.length) invalidImage();
    const type = data.subarray(offset + 4, offset + 8).toString("ascii");
    if (type === "IHDR") {
      if (length !== 13 || dimensions) invalidImage();
      dimensions = checkDimensions(data.readUInt32BE(offset + 8), data.readUInt32BE(offset + 12));
    } else if (type === "IDAT") {
      hasIdat = true;
    } else if (type === "IEND") {
      if (length !== 0) invalidImage();
      hasIend = true;
      break;
    }
    offset = end;
  }
  if (!dimensions || !hasIdat || !hasIend) invalidImage();
  return dimensions;
}

function isJpegSof(marker: number): boolean {
  return (
    (marker >= 0xc0 && marker <= 0xc3) ||
    (marker >= 0xc5 && marker <= 0xc7) ||
    (marker >= 0xc9 && marker <= 0xcb) ||
    (marker >= 0xcd && marker <= 0xcf)
  );
}

function inspectJpeg(data: Buffer): ImageInspection {
  if (!imageSignatureMatches("image/jpeg", data) || data.length < 4) invalidImage();
  let offset = 2;
  let dimensions: ImageInspection | null = null;
  let hasSos = false;
  while (offset + 1 < data.length) {
    if (data[offset] !== 0xff) {
      // Encoders may leave padding bytes between marker segments. They are
      // harmless before SOS and compressed bytes are skipped after SOS.
      offset++;
      continue;
    }
    while (offset < data.length && data[offset] === 0xff) offset++;
    if (offset >= data.length) invalidImage();
    const marker = data[offset++];
    if (hasSos && marker === 0x00) continue; // byte-stuffed 0xFF in compressed data
    if (marker === 0xd9) break;
    if (marker === 0xda) {
      if (offset + 2 > data.length) invalidImage();
      const length = data.readUInt16BE(offset);
      if (length < 2 || offset + length > data.length) invalidImage();
      offset += length;
      hasSos = true;
      continue;
    }
    if (marker === 0xd8 || (marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) continue;
    if (offset + 2 > data.length) invalidImage();
    const length = data.readUInt16BE(offset);
    if (length < 2 || offset + length > data.length) invalidImage();
    if (isJpegSof(marker)) {
      if (length < 7 || dimensions) invalidImage();
      dimensions = checkDimensions(data.readUInt16BE(offset + 3), data.readUInt16BE(offset + 5));
    }
    offset += length;
  }
  const eoi = data.lastIndexOf(Buffer.from([0xff, 0xd9]));
  if (!dimensions || !hasSos || eoi < 0) invalidImage();
  return dimensions;
}

function inspectGif(data: Buffer): ImageInspection {
  if (!imageSignatureMatches("image/gif", data) || data.length < 14 || data[data.length - 1] !== 0x3b) invalidImage();
  return checkDimensions(data.readUInt16LE(6), data.readUInt16LE(8));
}

function readUInt24LE(data: Buffer, offset: number): number {
  return data[offset] | (data[offset + 1] << 8) | (data[offset + 2] << 16);
}

function inspectWebp(data: Buffer): ImageInspection {
  if (!imageSignatureMatches("image/webp", data) || data.length < 30) invalidImage();
  const riffSize = data.readUInt32LE(4);
  if (riffSize + 8 > data.length) invalidImage();
  let offset = 12;
  while (offset + 8 <= data.length) {
    const type = data.subarray(offset, offset + 4).toString("ascii");
    const length = data.readUInt32LE(offset + 4);
    const dataOffset = offset + 8;
    const end = dataOffset + length;
    if (end > data.length) invalidImage();
    if (type === "VP8X" && length >= 10) {
      return checkDimensions(readUInt24LE(data, dataOffset + 4) + 1, readUInt24LE(data, dataOffset + 7) + 1);
    }
    if (type === "VP8L" && length >= 5 && data[dataOffset] === 0x2f) {
      const b1 = data[dataOffset + 1];
      const b2 = data[dataOffset + 2];
      const b3 = data[dataOffset + 3];
      const b4 = data[dataOffset + 4];
      return checkDimensions(1 + ((b1 | (b2 << 8)) & 0x3fff), 1 + (((b2 >> 6) | (b3 << 2) | (b4 << 10)) & 0x3fff));
    }
    if (type === "VP8 " && length >= 10 && data[dataOffset + 3] === 0x9d && data[dataOffset + 4] === 0x01 && data[dataOffset + 5] === 0x2a) {
      return checkDimensions(data.readUInt16LE(dataOffset + 6) & 0x3fff, data.readUInt16LE(dataOffset + 8) & 0x3fff);
    }
    offset = dataOffset + length + (length & 1);
  }
  invalidImage();
}

function inspectImage(mimeType: ImageMimeType, data: Buffer): ImageInspection {
  switch (mimeType) {
    case "image/png":
      return inspectPng(data);
    case "image/jpeg":
      return inspectJpeg(data);
    case "image/webp":
      return inspectWebp(data);
    case "image/gif":
      return inspectGif(data);
  }
}

async function acquireImageRead(): Promise<() => void> {
  if (activeImageReads < MAX_CONCURRENT_IMAGE_READS) {
    activeImageReads++;
    return () => releaseImageRead();
  }
  if (imageReadWaiters.length >= MAX_QUEUED_IMAGE_READS) {
    throw new WorkspaceError("IMAGE_READ_BUSY", "Too many image reads are already in progress. Try again shortly.");
  }
  await new Promise<void>((resolve) => imageReadWaiters.push(resolve));
  return () => releaseImageRead();
}

function releaseImageRead(): void {
  const next = imageReadWaiters.shift();
  if (next) next();
  else activeImageReads = Math.max(0, activeImageReads - 1);
}

export class Workspace {
  readonly root: string;
  readonly id: string;
  readonly name: string;
  readonly ignoreRules: IgnoreRules;
  readonly projectConfig: ProjectConfig;

  constructor(rootInput: string) {
    const resolved = path.resolve(rootInput);
    let real: string;
    try {
      real = fs.realpathSync.native(resolved);
    } catch {
      throw new WorkspaceError("FILE_NOT_FOUND", `Workspace root does not exist: ${rootInput}`);
    }
    if (!fs.statSync(real).isDirectory()) {
      throw new WorkspaceError("NOT_A_DIRECTORY", `Workspace root is not a directory: ${rootInput}`);
    }
    this.root = real;
    this.id = createHash("sha256").update(normCase(real)).digest("hex").slice(0, 12);
    this.ignoreRules = new IgnoreRules(real);
    this.projectConfig = parseProjectConfig(readJsonIfExists<unknown>(path.join(real, ".c2c.json")));
    this.name = this.projectConfig.name ?? path.basename(real);
  }

  private contains(candidate: string): boolean {
    const r = normCase(this.root);
    const c = normCase(candidate);
    return c === r || c.startsWith(r + path.sep);
  }

  /**
   * Canonicalize a path by realpath-ing its deepest existing ancestor.
   * Defends against symlink escapes even for not-yet-existing leaf segments.
   */
  private canonicalize(abs: string): string {
    let current = abs;
    const suffix: string[] = [];
    for (;;) {
      try {
        const real = fs.realpathSync.native(current);
        return suffix.length > 0 ? path.join(real, ...suffix) : real;
      } catch {
        const parent = path.dirname(current);
        if (parent === current) return abs;
        suffix.unshift(path.basename(current));
        current = parent;
      }
    }
  }

  /**
   * Resolve an untrusted path to a canonical absolute path inside the workspace.
   * Throws PATH_OUTSIDE_WORKSPACE or ACCESS_DENIED_SENSITIVE_FILE.
   */
  resolve(requested: string, opts: { allowSensitive?: boolean } = {}): { abs: string; rel: string } {
    if (typeof requested !== "string" || requested.includes("\0")) {
      throw new WorkspaceError("INVALID_PATH", "Invalid path");
    }
    let p = requested.trim();
    if (p === "" || p === "/") p = ".";
    // Normalize separators so Windows-style input behaves identically everywhere.
    p = p.replace(/\\/g, "/");
    // Strip a "workspace:/" alias prefix if the model echoes it back.
    p = p.replace(/^workspace:\/*/i, "");
    if (p === "") p = ".";

    const abs = path.resolve(this.root, p);
    const canonical = this.canonicalize(abs);
    if (!this.contains(canonical)) {
      throw new WorkspaceError(
        "PATH_OUTSIDE_WORKSPACE",
        `Path resolves outside the connected workspace: ${requested}`
      );
    }
    const rel = path.relative(this.root, canonical).split(path.sep).join("/");
    if (rel.startsWith("..")) {
      throw new WorkspaceError("PATH_OUTSIDE_WORKSPACE", `Path resolves outside the connected workspace: ${requested}`);
    }
    if (!opts.allowSensitive && rel !== "" && this.ignoreRules.isSensitive(rel)) {
      throw new WorkspaceError(
        "ACCESS_DENIED_SENSITIVE_FILE",
        `ACCESS_DENIED_SENSITIVE_FILE: '${rel}' matches the sensitive-file policy and cannot be read.`
      );
    }
    return { abs: canonical, rel };
  }

  private async isBinary(abs: string): Promise<boolean> {
    const fd = await fs.promises.open(abs, "r");
    try {
      const buf = Buffer.alloc(8192);
      const { bytesRead } = await fd.read(buf, 0, buf.length, 0);
      for (let i = 0; i < bytesRead; i++) {
        if (buf[i] === 0) return true;
      }
      return false;
    } finally {
      await fd.close();
    }
  }

  async readFile(
    requested: string,
    opts: { startLine?: number; endLine?: number; maxLines?: number; maxBytes?: number } = {}
  ): Promise<ReadFileResult> {
    const { abs, rel } = this.resolve(requested);
    let stat: fs.Stats;
    try {
      stat = await fs.promises.stat(abs);
    } catch {
      throw new WorkspaceError("FILE_NOT_FOUND", `File not found: ${rel}`);
    }
    if (!stat.isFile()) {
      throw new WorkspaceError("NOT_A_FILE", `Not a regular file: ${rel}`);
    }
    if (await this.isBinary(abs)) {
      throw new WorkspaceError("BINARY_FILE", `Binary file (${stat.size} bytes): ${rel}. Content is not returned.`);
    }

    const startLine = Math.max(1, Math.floor(opts.startLine ?? 1));
    const maxLines = Math.min(HARD_MAX_LINES, Math.max(1, Math.floor(opts.maxLines ?? DEFAULT_MAX_LINES)));
    const endLimit = opts.endLine
      ? Math.min(Math.floor(opts.endLine), startLine + HARD_MAX_LINES - 1)
      : startLine + maxLines - 1;
    const maxBytes = Math.min(1024 * 1024, Math.max(1024, Math.floor(opts.maxBytes ?? DEFAULT_MAX_BYTES)));

    const lines: string[] = [];
    let totalLines = 0;
    let collectedBytes = 0;
    let byteTruncated = false;
    let actualEnd = startLine - 1;

    const stream = fs.createReadStream(abs, { encoding: "utf8" });
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
    for await (const line of rl) {
      totalLines++;
      if (totalLines >= startLine && totalLines <= endLimit && !byteTruncated) {
        const cost = Buffer.byteLength(line, "utf8") + 1;
        if (collectedBytes + cost > maxBytes && lines.length > 0) {
          byteTruncated = true;
        } else {
          lines.push(line);
          collectedBytes += cost;
          actualEnd = totalLines;
        }
      }
    }
    rl.close();

    const remaining = Math.max(0, totalLines - actualEnd);
    return {
      path: rel,
      sizeBytes: stat.size,
      totalLines,
      startLine: Math.min(startLine, Math.max(totalLines, 1)),
      endLine: actualEnd,
      truncated: remaining > 0,
      remainingLines: remaining,
      nextStartLine: remaining > 0 ? actualEnd + 1 : null,
      content: lines.join("\n"),
    };
  }

  private resolveAttachment(requested: string): { abs: string; rel: string } {
    if (typeof requested !== "string" || requested.includes("\0")) {
      throw new WorkspaceError("INVALID_PATH", "Invalid attachment path");
    }
    const input = requested.trim();
    if (!path.isAbsolute(input)) {
      throw new WorkspaceError("ATTACHMENT_NOT_ALLOWED", "Attachments must use an absolute temporary-file path.");
    }
    const abs = this.canonicalize(path.resolve(input));
    let tempRoot: string;
    try {
      tempRoot = fs.realpathSync.native(os.tmpdir());
    } catch {
      throw new WorkspaceError("ATTACHMENT_NOT_ALLOWED", "The temporary attachment directory is unavailable.");
    }
    const tempCase = normCase(tempRoot);
    const absCase = normCase(abs);
    if (absCase !== tempCase && !absCase.startsWith(tempCase + path.sep)) {
      throw new WorkspaceError("ATTACHMENT_NOT_ALLOWED", "Attachment is outside the temporary attachment directory.");
    }
    const base = path.basename(abs);
    if (!/^codex-clipboard-[a-z0-9-]{8,80}\.(?:png|jpe?g|webp|gif)$/i.test(base)) {
      throw new WorkspaceError("ATTACHMENT_NOT_ALLOWED", "Only explicitly named Codex clipboard images may be read.");
    }
    return { abs, rel: `attachment/${base}` };
  }

  async readImage(requested: string, opts: { attachment?: boolean } = {}): Promise<ReadImageResult> {
    const release = await acquireImageRead();
    try {
      const resolved = opts.attachment ? this.resolveAttachment(requested) : this.resolve(requested);
      const { abs, rel } = resolved;
      const source = opts.attachment ? "attachment" : "workspace";
      const expectedMime = IMAGE_MIME_BY_EXTENSION[path.extname(rel).toLowerCase()];
      if (!expectedMime) {
        throw new WorkspaceError(
          "UNSUPPORTED_IMAGE_FORMAT",
          `Unsupported image format: ${rel}. Supported formats: PNG, JPG/JPEG, WEBP and GIF.`
        );
      }

      let stat: fs.Stats;
      try {
        stat = await fs.promises.stat(abs);
      } catch {
        throw new WorkspaceError("FILE_NOT_FOUND", `File not found: ${rel}`);
      }
      if (!stat.isFile()) {
        throw new WorkspaceError("NOT_A_FILE", `Not a regular file: ${rel}`);
      }
      if (stat.size > MAX_IMAGE_BYTES) {
        throw new WorkspaceError(
          "IMAGE_TOO_LARGE",
          `Image is too large (${stat.size} bytes): ${rel}. Maximum allowed size is ${MAX_IMAGE_BYTES} bytes.`
        );
      }

      let data: Buffer;
      try {
        data = await fs.promises.readFile(abs);
      } catch {
        throw new WorkspaceError("FILE_NOT_FOUND", `File not found: ${rel}`);
      }
      if (data.length > MAX_IMAGE_BYTES) {
        throw new WorkspaceError(
          "IMAGE_TOO_LARGE",
          `Image is too large (${data.length} bytes): ${rel}. Maximum allowed size is ${MAX_IMAGE_BYTES} bytes.`
        );
      }
      const dimensions = inspectImage(expectedMime, data);
      return {
        path: rel,
        source,
        sizeBytes: data.length,
        mimeType: expectedMime,
        width: dimensions.width,
        height: dimensions.height,
        dataBase64: data.toString("base64"),
      };
    } finally {
      release();
    }
  }

  async listDirectory(
    requested: string,
    opts: { depth?: number; limit?: number; offset?: number } = {}
  ): Promise<ListDirectoryResult> {
    const { abs, rel } = this.resolve(requested);
    let stat: fs.Stats;
    try {
      stat = await fs.promises.stat(abs);
    } catch {
      throw new WorkspaceError("FILE_NOT_FOUND", `Directory not found: ${rel || "."}`);
    }
    if (!stat.isDirectory()) {
      throw new WorkspaceError("NOT_A_DIRECTORY", `Not a directory: ${rel}`);
    }
    const depth = Math.min(4, Math.max(1, Math.floor(opts.depth ?? 1)));
    const limit = Math.min(1000, Math.max(1, Math.floor(opts.limit ?? 200)));
    const offset = Math.max(0, Math.floor(opts.offset ?? 0));

    const all: DirEntry[] = [];
    const walk = async (dirAbs: string, dirRel: string, level: number): Promise<void> => {
      let entries: fs.Dirent[];
      try {
        entries = await fs.promises.readdir(dirAbs, { withFileTypes: true });
      } catch {
        return;
      }
      entries.sort((a, b) => {
        const ad = a.isDirectory() ? 0 : 1;
        const bd = b.isDirectory() ? 0 : 1;
        return ad !== bd ? ad - bd : a.name.localeCompare(b.name);
      });
      for (const entry of entries) {
        const childRel = dirRel ? `${dirRel}/${entry.name}` : entry.name;
        if (this.ignoreRules.isHidden(childRel) || this.ignoreRules.isHidden(childRel + "/")) continue;
        if (entry.isDirectory()) {
          all.push({ path: childRel + "/", type: "dir" });
          if (level < depth) await walk(path.join(dirAbs, entry.name), childRel, level + 1);
        } else if (entry.isFile()) {
          let size: number | undefined;
          try {
            size = (await fs.promises.stat(path.join(dirAbs, entry.name))).size;
          } catch {
            size = undefined;
          }
          all.push({ path: childRel, type: "file", sizeBytes: size });
        }
        if (all.length >= offset + limit + 2000) return; // hard cap for huge trees
      }
    };
    await walk(abs, rel, 1);

    const page = all.slice(offset, offset + limit);
    return {
      path: rel || ".",
      entries: page,
      total: all.length,
      offset,
      limit,
      hasMore: offset + page.length < all.length,
    };
  }

  /** Lightweight project detection for workspace_info. */
  detectProject(): {
    projectType: string;
    languages: string[];
    frameworks: string[];
    packageManager: string | null;
    scripts: Record<string, string>;
  } {
    const has = (f: string): boolean => fs.existsSync(path.join(this.root, f));
    const languages = new Set<string>();
    const frameworks = new Set<string>();
    let projectType = "unknown";
    let packageManager: string | null = null;
    let scripts: Record<string, string> = {};

    if (has("package.json")) {
      projectType = "node";
      languages.add("JavaScript");
      const rawPackage = readJsonIfExists<unknown>(path.join(this.root, "package.json"));
      const pkg = rawPackage && typeof rawPackage === "object" && !Array.isArray(rawPackage)
        ? rawPackage as Record<string, unknown>
        : {};
      scripts = stringRecord(pkg.scripts);
      const deps = { ...stringRecord(pkg.dependencies), ...stringRecord(pkg.devDependencies) };
      const known: Record<string, string> = {
        next: "Next.js",
        react: "React",
        vue: "Vue",
        svelte: "Svelte",
        express: "Express",
        fastify: "Fastify",
        "@nestjs/core": "NestJS",
        electron: "Electron",
        vitest: "Vitest",
        jest: "Jest",
      };
      for (const [dep, label] of Object.entries(known)) {
        if (deps[dep]) frameworks.add(label);
      }
      if (has("pnpm-lock.yaml")) packageManager = "pnpm";
      else if (has("yarn.lock")) packageManager = "yarn";
      else if (has("bun.lockb") || has("bun.lock")) packageManager = "bun";
      else if (has("package-lock.json")) packageManager = "npm";
    }
    if (has("tsconfig.json")) languages.add("TypeScript");
    if (has("pyproject.toml") || has("requirements.txt") || has("setup.py")) {
      languages.add("Python");
      if (projectType === "unknown") projectType = "python";
    }
    if (has("Cargo.toml")) {
      languages.add("Rust");
      if (projectType === "unknown") projectType = "rust";
    }
    if (has("go.mod")) {
      languages.add("Go");
      if (projectType === "unknown") projectType = "go";
    }
    if (has("Package.swift")) {
      languages.add("Swift");
      if (projectType === "unknown") projectType = "swift";
    }
    return {
      projectType,
      languages: [...languages],
      frameworks: [...frameworks],
      packageManager,
      scripts,
    };
  }
}
