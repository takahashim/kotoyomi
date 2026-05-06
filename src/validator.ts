import type { PoemLine } from "./types.ts";

export function assertPoemLines(value: unknown): asserts value is PoemLine[] {
  if (!Array.isArray(value)) {
    throw new TypeError("PoemLine[] は配列である必要があります。");
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
    if (typeof candidate.text !== "string") {
      throw new TypeError(`要素 ${i} の text は文字列である必要があります。`);
    }
  }
}
