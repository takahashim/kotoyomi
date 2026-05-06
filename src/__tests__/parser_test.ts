import { assertEquals, assertThrows } from "jsr:@std/assert@^1.0.0";
import { parsePoem, PoemParseError } from "../parser.ts";

Deno.test("parse poem lines", () => {
  const source = `
[00:00.000] 春の夜に
[00:04.200] 静かに雨が降る
`;

  const lines = parsePoem(source);

  assertEquals(lines, [
    { id: "line-1", time: 0, text: "春の夜に" },
    { id: "line-2", time: 4.2, text: "静かに雨が降る" },
  ]);
});

Deno.test("空行は無視される", () => {
  const source = `
[00:00.000] 行1

[00:01.000] 行2


[00:02.500] 行3
`;
  const lines = parsePoem(source);
  assertEquals(lines.length, 3);
  assertEquals(lines[2], { id: "line-3", time: 2.5, text: "行3" });
});

Deno.test("複数桁分のパース", () => {
  const lines = parsePoem("[12:03.000] 長い詩");
  assertEquals(lines, [{ id: "line-1", time: 723, text: "長い詩" }]);
});

Deno.test("時刻昇順違反でエラー", () => {
  const source = `
[00:05.000] 行1
[00:03.000] 行2
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻が昇順ではありません",
  );
});

Deno.test("時刻マーカー形式不正でエラー", () => {
  const source = `
[00:00.000] 行1
[abc] 行2
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻マーカー形式が不正です",
  );
});

Deno.test("時刻マーカーのない本文行でエラー", () => {
  const source = `
[00:00.000] 行1
本文だけ
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻マーカーがありません",
  );
});

Deno.test("本文が空でエラー", () => {
  assertThrows(
    () => parsePoem("[00:00.000]   "),
    PoemParseError,
    "本文が空です",
  );
});

Deno.test("sample.poem が期待JSONと一致する", async () => {
  const url = new URL("../../poems/sample.poem", import.meta.url);
  const expectedUrl = new URL("../../testdata/sample.expected.json", import.meta.url);
  const source = await Deno.readTextFile(url);
  const expected = JSON.parse(await Deno.readTextFile(expectedUrl));

  const lines = parsePoem(source);
  assertEquals(lines, expected);
});
