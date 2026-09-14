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
function requestRouting(request: string): { requested?: ReviewProvider; excluded: Set<ReviewProvider> } {
  // Parse visible link labels, not destinations; keep the original request
  // untouched so resolve/start can validate the same user text.
  const plainRequest = request
    .replace(/\[([^\]\r\n]+)\]\((?:[^()\\]|\\.)*\)/g, "$1")
    .replace(/[*_`]/g, "");
  const matches = [...plainRequest.matchAll(/(?:使用|用|让|请|交给|use\s+)\s*(?:(?:网页(?:版)?|官网|官方(?:网页(?:版)?|网站)?)(?:的)?\s*)*(deepseek|chatgpt|gpt)(?=\s|[，,。;；：:]|网页|官网|官方|的|评审|复审|多轮|帮|来|先|做|对|$)/gi)];
  const providers = new Set<ReviewProvider>();
  const excluded = new Set<ReviewProvider>();
  for (const match of matches) {
    const provider = parseReviewProvider(match[1]);
    // Basic explicit negatives such as 不要用 / 不用 / 别用 are never choices.
    const target = /(?:不要|不|别)\s*$/.test(plainRequest.slice(0, match.index)) ? excluded : providers;
    target.add(provider);
  }
  if (providers.size > 1) throw new Error("一次任务只能指定一个评审渠道；请明确选择 DeepSeek 或 ChatGPT。");
  const requested = [...providers][0];
  if (requested && excluded.has(requested)) throw new Error("同一需求同时要求使用和不使用同一渠道，不能自动选择评审渠道。");
  return { requested, excluded };
}

export function requestProvider(request: string): ReviewProvider | undefined {
  return requestRouting(request).requested;
}

export function selectReviewer(input: {
  explicit?: string; request?: string; saved?: ReviewProvider; defaultProvider: ReviewProvider;
}): ReviewProvider {
  const { requested, excluded } = requestRouting(input.request ?? "");
  const explicit = input.explicit ? parseReviewProvider(input.explicit) : undefined;
  if ([requested, explicit].some(provider => provider && input.saved && provider !== input.saved)) {
    throw new Error("当前评审尚未结束，不能中途换渠道；先停止原评审，再开始新任务。");
  }
  const resolved = requested ?? input.saved ?? input.defaultProvider;
  // With an original user request, --provider is a consistency assertion, not
  // permission to rewrite the user's choice (or turn the skill brand into one).
  // Keep provider-only CLI use compatible for callers that have no request text.
  if (input.request?.trim() && explicit && explicit !== resolved) {
    throw new Error("--provider 与原始需求解析的评审渠道不一致；保留用户原话，按 review resolve 的结果开始，不得改写需求或擅自换渠道。");
  }
  const selected = explicit ?? resolved;
  if (excluded.has(selected)) throw new Error("本次需求已明确排除当前评审渠道，不能自动继续或擅自切换渠道。");
  return selected;
}

export function providerLabel(provider: ReviewProvider): string {
  return provider === "deepseek" ? "DeepSeek" : "ChatGPT";
}
