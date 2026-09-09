import { describe, it, expect, beforeAll, afterAll } from "vitest";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { Workspace, WorkspaceError } from "../src/workspace/manager.js";
import { makeTmpDir, cleanup, write } from "./helpers.js";

let root: string;
let outside: string;
let ws: Workspace;
let symlinksReady: boolean;

beforeAll(() => {
  root = makeTmpDir("ws");
  outside = makeTmpDir("outside");
  write(root, "hello.txt", "hello world\n");
  write(root, "src/app.ts", "const x = 1;\n");
  write(root, ".env", "SECRET=topsecret\n");
  write(root, ".env.production", "SECRET=prod\n");
  write(root, ".env.example", "SECRET=changeme\n");
  write(root, "certs/server.pem", "PRIVATE KEY\n");
  write(root, "keys/id_rsa", "PRIVATE KEY\n");
  write(root, "nested/.ssh/config", "Host *\n");
  write(outside, "secret.txt", "outside data\n");
  write(root, ".c2cignore", "private-notes/\n");
  write(root, "private-notes/todo.md", "secret notes\n");
  // symlink pointing outside the workspace (needs symlink privileges, e.g.
  // absent for unprivileged Windows runners — the escape tests then skip)
  symlinksReady = true;
  try {
    fs.symlinkSync(path.join(outside, "secret.txt"), path.join(root, "link-out.txt"));
    fs.symlinkSync(outside, path.join(root, "dir-out"));
  } catch {
    symlinksReady = false;
  }
  ws = new Workspace(root);
});

afterAll(() => {
  cleanup(root);
  cleanup(outside);
});

describe("path containment", () => {
  it("reads a normal relative path", async () => {
    const result = await ws.readFile("hello.txt");
    expect(result.content).toContain("hello world");
  });

  it("rejects ../ traversal", () => {
    expect(() => ws.resolve("../outside-file")).toThrowError(WorkspaceError);
    expect(() => ws.resolve("../../etc/passwd")).toThrow(/PATH_OUTSIDE|outside/i);
    try {
      ws.resolve("a/../../b");
    } catch (error) {
      expect((error as WorkspaceError).code).toBe("PATH_OUTSIDE_WORKSPACE");
    }
  });

  it("rejects absolute paths outside the workspace", () => {
    expect(() => ws.resolve("/etc/passwd")).toThrowError(WorkspaceError);
    expect(() => ws.resolve(outside)).toThrowError(WorkspaceError);
  });

  it("allows absolute paths inside the workspace", () => {
    const resolved = ws.resolve(path.join(root, "hello.txt"));
    expect(resolved.rel).toBe("hello.txt");
  });

  it("rejects windows-style traversal", () => {
    expect(() => ws.resolve("..\\..\\etc\\passwd")).toThrowError(WorkspaceError);
  });

  it("rejects null bytes", () => {
    expect(() => ws.resolve("hello.txt\0.png")).toThrowError(WorkspaceError);
  });

  it("rejects symlinked file escaping the workspace", () => {
    if (!symlinksReady) return; // symlink privilege unavailable
    try {
      ws.resolve("link-out.txt");
      expect.unreachable("should have thrown");
    } catch (error) {
      expect((error as WorkspaceError).code).toBe("PATH_OUTSIDE_WORKSPACE");
    }
  });

  it("rejects paths through a symlinked directory escaping the workspace", () => {
    if (!symlinksReady) return; // symlink privilege unavailable
    try {
      ws.resolve("dir-out/secret.txt");
      expect.unreachable("should have thrown");
    } catch (error) {
      expect((error as WorkspaceError).code).toBe("PATH_OUTSIDE_WORKSPACE");
    }
  });
});

describe("sensitive files", () => {
  const expectDenied = (p: string): void => {
    try {
      ws.resolve(p);
      expect.unreachable(`expected ${p} to be denied`);
    } catch (error) {
      expect((error as WorkspaceError).code).toBe("ACCESS_DENIED_SENSITIVE_FILE");
    }
  };

  it("denies .env and variants", () => {
    expectDenied(".env");
    expectDenied(".env.production");
  });

  it("allows .env.example", () => {
    expect(ws.resolve(".env.example").rel).toBe(".env.example");
  });

  it("denies keys and certificates", () => {
    expectDenied("certs/server.pem");
    expectDenied("keys/id_rsa");
  });

  it("denies .ssh directories anywhere", () => {
    expectDenied("nested/.ssh/config");
  });

  it("honors .c2cignore custom rules", () => {
    expectDenied("private-notes/todo.md");
  });

  it("hides sensitive files from directory listing", async () => {
    const listing = await ws.listDirectory(".", { limit: 500, depth: 2 });
    const paths = listing.entries.map((entry) => entry.path);
    expect(paths).toContain("hello.txt");
    expect(paths).not.toContain(".env");
    expect(paths.some((p) => p.includes("private-notes"))).toBe(false);
  });
});

describe("read_file pagination", () => {
  it("caps unbounded reads at 400 lines and reports the remainder", async () => {
    const big = Array.from({ length: 1000 }, (_, i) => `line ${i + 1}`).join("\n") + "\n";
    write(root, "big.txt", big);
    const result = await ws.readFile("big.txt");
    expect(result.totalLines).toBe(1000);
    expect(result.endLine).toBe(400);
    expect(result.truncated).toBe(true);
    expect(result.remainingLines).toBe(600);
    expect(result.nextStartLine).toBe(401);
  });

  it("returns an explicit range", async () => {
    const result = await ws.readFile("big.txt", { startLine: 500, endLine: 502 });
    expect(result.content).toBe("line 500\nline 501\nline 502");
    expect(result.startLine).toBe(500);
    expect(result.endLine).toBe(502);
  });

  it("denies binary files", async () => {
    fs.writeFileSync(path.join(root, "blob.bin"), Buffer.from([0, 1, 2, 3, 0, 255]));
    await expect(ws.readFile("blob.bin")).rejects.toMatchObject({ code: "BINARY_FILE" });
  });

  it("reports FILE_NOT_FOUND for missing files", async () => {
    await expect(ws.readFile("nope.txt")).rejects.toMatchObject({ code: "FILE_NOT_FOUND" });
  });
});

describe("read_image", () => {
  it("reads real 1x1 PNG, JPEG, WEBP and GIF files with dimensions", async () => {
    const fixtures: Array<{ name: string; base64: string; mimeType: string }> = [
      { name: "screen.png", base64: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", mimeType: "image/png" },
      { name: "photo.jpg", base64: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDi6KKK+ZP3E//Z", mimeType: "image/jpeg" },
      { name: "preview.webp", base64: "UklGRjwAAABXRUJQVlA4IDAAAADQAQCdASoBAAEAAUAmJaACdLoB+AADsAD+8ut//NgVzXPv9//S4P0uD9Lg/9KQAAA=", mimeType: "image/webp" },
      { name: "animation.gif", base64: "R0lGODdhAQABAIEAAP8AAAAAAAAAAAAAACwAAAAAAQABAAAIBAABBAQAOw==", mimeType: "image/gif" },
    ];

    for (const fixture of fixtures) {
      const bytes = Buffer.from(fixture.base64, "base64");
      fs.writeFileSync(path.join(root, fixture.name), bytes);
      const result = await ws.readImage(fixture.name);
      expect(result.mimeType).toBe(fixture.mimeType);
      expect(result.source).toBe("workspace");
      expect(result.width).toBe(1);
      expect(result.height).toBe(1);
      expect(result.sizeBytes).toBe(bytes.length);
      expect(Buffer.from(result.dataBase64, "base64")).toEqual(bytes);
    }
  });

  it("rejects unsupported extensions and mismatched file headers", async () => {
    fs.writeFileSync(path.join(root, "notes.txt"), Buffer.from("not an image"));
    await expect(ws.readImage("notes.txt")).rejects.toMatchObject({ code: "UNSUPPORTED_IMAGE_FORMAT" });

    fs.writeFileSync(path.join(root, "wrong.png"), Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    await expect(ws.readImage("wrong.png")).rejects.toMatchObject({ code: "INVALID_IMAGE" });
  });

  it("reads an explicitly authorized Codex clipboard attachment and rejects arbitrary temp files", async () => {
    const attachment = path.join(os.tmpdir(), "codex-clipboard-test-12345678.png");
    const bytes = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64");
    fs.writeFileSync(attachment, bytes);
    try {
      const result = await ws.readImage(attachment, { attachment: true });
      expect(result.source).toBe("attachment");
      expect(result.path).toBe("attachment/codex-clipboard-test-12345678.png");
      expect(result.width).toBe(1);
      await expect(ws.readImage(attachment)).rejects.toMatchObject({ code: "PATH_OUTSIDE_WORKSPACE" });
      await expect(ws.readImage(path.join(os.tmpdir(), "ordinary.png"), { attachment: true })).rejects.toMatchObject({ code: "ATTACHMENT_NOT_ALLOWED" });
    } finally {
      fs.rmSync(attachment, { force: true });
    }
  });

  it("enforces workspace and sensitive-file boundaries", async () => {
    fs.writeFileSync(path.join(outside, "outside.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    await expect(ws.readImage(path.join(outside, "outside.png"))).rejects.toMatchObject({ code: "PATH_OUTSIDE_WORKSPACE" });

    fs.writeFileSync(path.join(root, ".env.png"), Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
    await expect(ws.readImage(".env.png")).rejects.toMatchObject({ code: "ACCESS_DENIED_SENSITIVE_FILE" });
  });

  it("rejects images larger than 10 MB", async () => {
    fs.writeFileSync(path.join(root, "large.png"), Buffer.concat([
      Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64"),
      Buffer.alloc(10 * 1024 * 1024),
    ]));
    await expect(ws.readImage("large.png")).rejects.toMatchObject({ code: "IMAGE_TOO_LARGE" });
  });

  it("rejects images whose declared dimensions exceed the safety limit", async () => {
    const oversized = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==", "base64");
    oversized.writeUInt32BE(9000, 16);
    fs.writeFileSync(path.join(root, "oversized-dimensions.png"), oversized);
    await expect(ws.readImage("oversized-dimensions.png")).rejects.toMatchObject({ code: "IMAGE_DIMENSIONS_TOO_LARGE" });
  });
});

describe("workspace identity", () => {
  it("has a stable id and name", () => {
    const again = new Workspace(root);
    expect(again.id).toBe(ws.id);
    expect(ws.id).toMatch(/^[a-f0-9]{12}$/);
    expect(ws.name).toBe(path.basename(root));
  });

  it("reads .c2c.json project name", () => {
    const named = makeTmpDir("named");
    write(
      named,
      ".c2c.json",
      JSON.stringify({
        name: "Remi",
        maxIterations: 12,
      })
    );
    const namedWs = new Workspace(named);
    expect(namedWs.name).toBe("Remi");
    expect(namedWs.projectConfig.maxIterations).toBe(12);
    cleanup(named);
  });

  it("falls back to the directory name when .c2c.json has invalid types", () => {
    const invalid = makeTmpDir("invalid-project-config");
    write(invalid, ".c2c.json", JSON.stringify({ name: 42, maxIterations: "many" }));

    const invalidWs = new Workspace(invalid);

    expect(invalidWs.name).toBe(path.basename(invalid));
    expect(invalidWs.projectConfig).toEqual({});
    cleanup(invalid);
  });

  it("filters invalid package script values during project detection", () => {
    const projectRoot = makeTmpDir("invalid-package-scripts");
    write(
      projectRoot,
      "package.json",
      JSON.stringify({
        name: "demo",
        scripts: { test: "vitest run", invalid: 42 },
        dependencies: { react: "^19.0.0" },
      })
    );

    const project = new Workspace(projectRoot).detectProject();

    expect(project.scripts).toEqual({ test: "vitest run" });
    expect(project.frameworks).toContain("React");
    cleanup(projectRoot);
  });
});
