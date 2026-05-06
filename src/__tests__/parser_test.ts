import { assertEquals, assertThrows } from "jsr:@std/assert@^1.0.0";
import { parsePoem, PoemParseError } from "../parser.ts";

Deno.test("1行の連をパース", () => {
  const source = `
[00:00.000]
春の夜に

[00:04.200]
静かに雨が降る
`;

  const stanzas = parsePoem(source);

  assertEquals(stanzas, [
    { id: "stanza-1", time: 0, lines: ["春の夜に"] },
    { id: "stanza-2", time: 4.2, lines: ["静かに雨が降る"] },
  ]);
});

Deno.test("複数行の連をパース", () => {
  const source = `
[00:00.000]
春の夜に
静かに雨が降る

[00:08.600]
遠い灯りが
川面に揺れている
`;

  const stanzas = parsePoem(source);

  assertEquals(stanzas, [
    { id: "stanza-1", time: 0, lines: ["春の夜に", "静かに雨が降る"] },
    { id: "stanza-2", time: 8.6, lines: ["遠い灯りが", "川面に揺れている"] },
  ]);
});

Deno.test("空行は連の終端として扱われる", () => {
  const source = `
[00:00.000]
行1

[00:01.000]
行2


[00:02.500]
行3
`;
  const stanzas = parsePoem(source);
  assertEquals(stanzas.length, 3);
  assertEquals(stanzas[2], { id: "stanza-3", time: 2.5, lines: ["行3"] });
});

Deno.test("複数桁分のパース", () => {
  const stanzas = parsePoem("[12:03.000]\n長い詩");
  assertEquals(stanzas, [{ id: "stanza-1", time: 723, lines: ["長い詩"] }]);
});

Deno.test("時刻昇順違反でエラー", () => {
  const source = `
[00:05.000]
行1
[00:03.000]
行2
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻が昇順ではありません",
  );
});

Deno.test("時刻マーカー形式不正でエラー", () => {
  const source = `
[00:00.000]
行1
[abc]
行2
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻マーカー形式が不正です",
  );
});

Deno.test("時刻マーカーのない本文行で始まるとエラー", () => {
  const source = `
本文だけ
[00:00.000]
行1
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "時刻マーカーがありません",
  );
});

Deno.test("マーカーのみで本文がないとエラー", () => {
  const source = `
[00:00.000]

[00:01.000]
行2
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "本文がありません",
  );
});

Deno.test("末尾のマーカーのみで本文がないとエラー", () => {
  const source = `
[00:00.000]
行1
[00:01.000]
`;
  assertThrows(
    () => parsePoem(source),
    PoemParseError,
    "本文がありません",
  );
});

Deno.test("マーカー行に本文が含まれているとエラー", () => {
  assertThrows(
    () => parsePoem("[00:00.000] 春の夜に"),
    PoemParseError,
    "マーカー行に本文を含めることはできません",
  );
});

Deno.test("sample.poem が期待JSONと一致する", async () => {
  const url = new URL("../../poems/sample.poem", import.meta.url);
  const expectedUrl = new URL("../../testdata/sample.expected.json", import.meta.url);
  const source = await Deno.readTextFile(url);
  const expected = JSON.parse(await Deno.readTextFile(expectedUrl));

  const stanzas = parsePoem(source);
  assertEquals(stanzas, expected);
});
