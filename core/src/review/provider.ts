export const REVIEW_PROVIDERS = ["deepseek", "chatgpt"] as const;
export type ReviewProvider = (typeof REVIEW_PROVIDERS)[number];
export type ReviewMode = "single" | "consensus";

export function parseReviewProvider(value: string): ReviewProvider {
  const name = value.trim().toLowerCase();
  if (name === "gpt") return "chatgpt";
  if (name === "chatgpt" || name === "deepseek") return name;
  throw new Error("review-provider must be deepseek or chatgpt");
}

export function parseReviewMode(value: string): ReviewMode {
  if (value === "single" || value === "consensus") return value;
  throw new Error("review-mode must be single or consensus");
}

/** Only explicit reviewer commands; the product name 'Codex with ChatGPT' is not an override. */
export function requestProvider(request: string): ReviewProvider | undefined {
  const matches = [...request.matchAll(/(?:使用|用|让|请|use\s+)\s*(deepseek|chatgpt|gpt)(?=\s|[，,。;；：:]|评审|复审|多轮|帮|来|先|做|对|$)/gi)];
  const providers = new Set(matches.map(m => parseReviewProvider(m[1])));
  if (providers.size > 1) throw new Error("一次任务只能指定一个评审渠道；请明确选择 DeepSeek 或 ChatGPT。");
  return [...providers][0];
}

export function selectReviewer(input: {
  explicit?: string; request?: string; saved?: ReviewProvider; defaultProvider: ReviewProvider;
}): ReviewProvider {
  const explicit = input.explicit ? parseReviewProvider(input.explicit) : requestProvider(input.request ?? "");
  if (explicit && input.saved && explicit !== input.saved) {
    throw new Error("当前评审尚未结束，不能中途换渠道；先停止原评审，再开始新任务。");
  }
  return explicit ?? input.saved ?? input.defaultProvider;
}

export function providerLabel(provider: ReviewProvider): string {
  return provider === "deepseek" ? "DeepSeek" : "ChatGPT";
}
