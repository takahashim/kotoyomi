import type { PoemStanza } from "./types.ts";

export function assertPoemStanzas(value: unknown): asserts value is PoemStanza[] {
  if (!Array.isArray(value)) {
    throw new TypeError("PoemStanza[] は配列である必要があります。");
  }

  for (let i = 0; i < value.length; i++) {
    const entry = value[i];
    if (typeof entry !== "object" || entry === null) {
      throw new TypeError(`要素 ${i} はオブジェクトである必要があります。`);
    }
    const candidate = entry as Record<string, unknown>;

    if (typeof candidate.id !== "string") {
      throw new TypeError(`要素 ${i} の id は文字列である必要があります。`);
    }
    if (typeof candidate.time !== "number" || !Number.isFinite(candidate.time)) {
      throw new TypeError(`要素 ${i} の time は有限の数値である必要があります。`);
    }
    if (!Array.isArray(candidate.lines) || candidate.lines.length === 0) {
      throw new TypeError(`要素 ${i} の lines は非空の配列である必要があります。`);
    }
    for (let j = 0; j < candidate.lines.length; j++) {
      const line = candidate.lines[j];
      if (typeof line !== "string" || line === "") {
        throw new TypeError(`要素 ${i} の lines[${j}] は非空の文字列である必要があります。`);
      }
    }
  }
}
