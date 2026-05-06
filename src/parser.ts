import type { PoemLine } from "./types.ts";

const LINE_PATTERN = /^\[(\d{1,2}):(\d{2})\.(\d{3})\]\s*(.*)$/;

export class PoemParseError extends Error {
  readonly lineNumber: number;

  constructor(lineNumber: number, message: string) {
    super(`${lineNumber}行目の${message}`);
    this.name = "PoemParseError";
    this.lineNumber = lineNumber;
  }
}

export function parsePoem(source: string): PoemLine[] {
  const lines: PoemLine[] = [];
  const rawLines = source.split(/\r?\n/);

  let prevTime = -Infinity;
  let index = 0;

  for (let i = 0; i < rawLines.length; i++) {
    const lineNumber = i + 1;
    const raw = rawLines[i];
    const trimmed = raw.trim();

    if (trimmed === "") continue;

    const match = trimmed.match(LINE_PATTERN);
    if (!match) {
      if (trimmed.startsWith("[")) {
        throw new PoemParseError(lineNumber, "時刻マーカー形式が不正です。");
      }
      throw new PoemParseError(lineNumber, "時刻マーカーがありません。");
    }

    const [, mm, ss, mmm, body] = match;
    const minutes = Number(mm);
    const seconds = Number(ss);
    const millis = Number(mmm);

    if (!Number.isFinite(minutes) || !Number.isFinite(seconds) || !Number.isFinite(millis)) {
      throw new PoemParseError(lineNumber, "時刻が数値として解釈できません。");
    }
    if (seconds >= 60) {
      throw new PoemParseError(lineNumber, "時刻の秒数が不正です。");
    }

    const text = body.trim();
    if (text === "") {
      throw new PoemParseError(lineNumber, "本文が空です。");
    }

    const time = minutes * 60 + seconds + millis / 1000;
    if (time < prevTime) {
      throw new PoemParseError(lineNumber, "時刻が昇順ではありません。");
    }
    prevTime = time;

    index += 1;
    lines.push({ id: `line-${index}`, time, text });
  }

  return lines;
}
