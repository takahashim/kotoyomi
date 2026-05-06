import type { PoemStanza } from "./types.ts";

const MARKER_PATTERN = /^\[(\d{1,2}):(\d{2})\.(\d{3})\](.*)$/;

export class PoemParseError extends Error {
  readonly lineNumber: number;

  constructor(lineNumber: number, message: string) {
    super(`${lineNumber}行目の${message}`);
    this.name = "PoemParseError";
    this.lineNumber = lineNumber;
  }
}

type Pending = {
  time: number;
  startLineNumber: number;
  lines: string[];
};

export function parsePoem(source: string): PoemStanza[] {
  const stanzas: PoemStanza[] = [];
  const rawLines = source.split(/\r?\n/);

  let prevTime = -Infinity;
  let pending: Pending | null = null;

  const flush = (): void => {
    if (!pending) return;
    if (pending.lines.length === 0) {
      throw new PoemParseError(pending.startLineNumber, "本文がありません。");
    }
    stanzas.push({
      id: `stanza-${stanzas.length + 1}`,
      time: pending.time,
      lines: pending.lines,
    });
    pending = null;
  };

  for (let i = 0; i < rawLines.length; i++) {
    const lineNumber = i + 1;
    const trimmed = rawLines[i].trim();

    if (trimmed === "") {
      flush();
      continue;
    }

    const match = trimmed.match(MARKER_PATTERN);
    if (match) {
      flush();
      const [, mm, ss, mmm, rest] = match;
      const minutes = Number(mm);
      const seconds = Number(ss);
      const millis = Number(mmm);

      if (!Number.isFinite(minutes) || !Number.isFinite(seconds) || !Number.isFinite(millis)) {
        throw new PoemParseError(lineNumber, "時刻が数値として解釈できません。");
      }
      if (seconds >= 60) {
        throw new PoemParseError(lineNumber, "時刻の秒数が不正です。");
      }

      if (rest.trim() !== "") {
        throw new PoemParseError(lineNumber, "マーカー行に本文を含めることはできません。");
      }

      const time = minutes * 60 + seconds + millis / 1000;
      if (time < prevTime) {
        throw new PoemParseError(lineNumber, "時刻が昇順ではありません。");
      }
      prevTime = time;

      pending = {
        time,
        startLineNumber: lineNumber,
        lines: [],
      };
      continue;
    }

    if (trimmed.startsWith("[")) {
      throw new PoemParseError(lineNumber, "時刻マーカー形式が不正です。");
    }
    if (!pending) {
      throw new PoemParseError(lineNumber, "時刻マーカーがありません。");
    }
    pending.lines.push(trimmed);
  }

  flush();
  return stanzas;
}
