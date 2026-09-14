import fs from "node:fs";
import { describe, expect, it } from "vitest";

const readDoc = (name: string): string =>
  fs.readFileSync(new URL(`../../${name}`, import.meta.url), "utf8");
const docs = [
  "SKILL.md",
  "core/skill/SKILL.md",
  "references/protocol.md",
  "references/reliability.md",
  "core/docs/protocol.md",
];

// Static documentation contracts supplement, rather than replace, runtime and
// browser verification. They catch contradictory routing/fail-open instructions.
describe("review routing and failure documentation contracts", () => {
  it("ships identical root and core Skill instructions", () => {
    expect(readDoc("SKILL.md")).toBe(readDoc("core/skill/SKILL.md"));
  });

  for (const name of docs) {
    describe(name, () => {
      const text = readDoc(name);

      it("distinguishes the Skill brand from an explicit ChatGPT selection", () => {
        expect(text).toMatch(/Codex with ChatGPT[\s\S]{0,180}(?:Skill 名称|Skill name|names the Skill)/);
        expect(text).toMatch(/(?:默认\s*DeepSeek|default(?:s)? to DeepSeek|默认评审渠道是 DeepSeek)/);
        expect(text).toMatch(/(?:明确|explicit)[\s\S]{0,50}(?:GPT\/ChatGPT|GPT|ChatGPT)/);
      });

      it("requires the user's original request instead of a fabricated routing prompt", () => {
        expect(text).toContain("--request");
        expect(text).toMatch(/(?:逐字使用本次用户原始要求|current user's original request verbatim)/);
        expect(text).toMatch(/(?:不能[\s\S]{0,70}|Never fabricate |Do not invent )“使用 GPT 评审”/);
        expect(text).toMatch(/(?:本地文件|local file)/);
      });

      it("keeps writes closed when sending or execution eligibility fails", () => {
        expect(text).toContain("canExecute=false");
        expect(text).toContain("sent=false");
        expect(text).toMatch(/(?:不修改业务文件或系统配置|Do not modify business files or system configuration)/);
        expect(text).toMatch(/(?:只读诊断|read-only diagnosis)/);
        expect(text).toMatch(/(?:不自行取消评审|Do not cancel the review)/);
        expect(text).toMatch(/(?:只有用户明确放弃评审|Only the user's explicit waiver)/);
      });

      it("separates host authorization from website login, quota and dependencies", () => {
        expect(text).toContain("Codex auth token is unavailable");
        expect(text).toMatch(/(?:宿主.{0,30}浏览器控制|host.{0,30}browser-control authorization)/);
        expect(text).toMatch(/(?:额度|quota)/);
        expect(text).toMatch(/(?:缺少依赖|缺依赖|Skill dependencies)/);
        expect(text).toContain("auth.json");
        expect(text).toContain("requires_openai_auth");
        expect(text).toMatch(/(?:不自动修改|[Dd]o not automatically change)/);
        expect(text).toMatch(/(?:不退出\/重启 Codex|exit\/restart Codex)/);
        expect(text).toContain("HTTP/CDP");
        expect(text).toMatch(/(?:一般业务任务|ordinary business tasks)/);
        expect(text).toMatch(/(?:用户明确授权诊断修复时|user explicitly authorizes diagnosis and repair)/);
        expect(text).toMatch(/(?:检查备份|inspect backups)/);
        expect(text).toMatch(/(?:官方认证优先级|official authentication precedence)/);
        expect(text).toMatch(/(?:安全的本地验证|safe local validation)/);
      });

      it("does not claim to sandbox arbitrary shell calls or override host constraints", () => {
        expect(text).toMatch(/(?:不能强制拦截任意 shell|cannot[\s\S]{0,30}arbitrary shell|do not sandbox arbitrary shell)/);
        expect(text).toMatch(/(?:更高优先级|宿主工具限制优先|higher-priority host tool)/);
      });
    });
  }

  for (const name of ["SKILL.md", "core/skill/SKILL.md"]) {
    it(`${name} makes the simplest and multi-round copy examples use the default reviewer`, () => {
      const text = readDoc(name);
      const simple = text.split("## 最简单的用法")[1].split("## 多轮评审后修改代码")[0];
      const multi = text.split("## 多轮评审后修改代码")[1].split("## 用户可见的标题")[0];
      expect(simple).toContain("使用 Codex with ChatGPT 帮我规划这个功能");
      expect(simple).toContain("默认由 DeepSeek 评审");
      expect(multi).toContain("让 DeepSeek 和 Codex 一轮一轮讨论");
      expect(multi).not.toContain("让 ChatGPT 和 Codex");
      expect(text).toContain("> 使用 GPT 评审这个问题，然后按意见修改并测试。");
      expect(text).toContain("所选评审方返回 `DECISION: CONSENSUS`");
    });
  }

  for (const name of ["SKILL.md", "core/skill/SKILL.md"]) {
    it(`${name} keeps screenshots on the selected provider without invented vision access`, () => {
      const text = readDoc(name);
      const routing = text.split("## 任务路由")[1].split("## 连接失败和等待速度保护")[0];
      const images = text.split("## 图片与数据边界")[1].split("## ChatGPT 模型说明")[0];
      expect(routing).toContain("默认 DeepSeek 由 Codex 在本地只读查看截图");
      expect(routing).not.toContain("先走只读 `read_image`");
      expect(images).toContain("没有直接看到原图");
      expect(images).toContain("不确定的地方");
      expect(images).toContain("只有已选 ChatGPT 且当前连接实际提供 `read_image` 时");
      expect(images).toContain("不因图片自动切换渠道、不自动上传、不调用 `claude-vision-skill`");
    });

    it(`${name} scopes MCP pairing and ChatGPT model selection to ChatGPT`, () => {
      const text = readDoc(name);
      expect(text).toContain("以下模型选择只适用于已选 ChatGPT 渠道，不影响默认 DeepSeek");
      expect(text).toContain("MCP 连接器设置仅适用于 ChatGPT 渠道");
      expect(text).toContain("默认 DeepSeek 复用配套 Skill 的官方会话与内置浏览器绑定");
      expect(text).toContain("不要求创建或配对 ChatGPT 连接器");
    });
  }

  it("labels the ChatGPT connector instructions as a selected-provider branch", () => {
    const text = readDoc("references/protocol.md");
    expect(text).toContain("numbered ChatGPT connector workflow below is only for tasks actually routed to ChatGPT");
    expect(text).toContain("## 已明确选择 ChatGPT 时的连接器流程");
  });
});
