import { assertThrows } from "jsr:@std/assert@^1.0.0";
import { assertPoemStanzas } from "../validator.ts";

Deno.test("正常な PoemStanza[] は通過する", () => {
  assertPoemStanzas([
    { id: "stanza-1", time: 0, lines: ["a"] },
    { id: "stanza-2", time: 1.5, lines: ["b", "c"] },
  ]);
});

Deno.test("空配列も通過する", () => {
  assertPoemStanzas([]);
});

Deno.test("配列でないと TypeError", () => {
  assertThrows(() => assertPoemStanzas({ id: "x" }), TypeError);
});

Deno.test("id が文字列でないと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: 1, time: 0, lines: ["a"] }]),
    TypeError,
    "id",
  );
});

Deno.test("time が数値でないと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: "0", lines: ["a"] }]),
    TypeError,
    "time",
  );
});

Deno.test("time が NaN だと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: NaN, lines: ["a"] }]),
    TypeError,
    "time",
  );
});

Deno.test("lines が配列でないと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: 0, lines: "a" }]),
    TypeError,
    "lines",
  );
});

Deno.test("lines が空配列だと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: 0, lines: [] }]),
    TypeError,
    "lines",
  );
});

Deno.test("lines の要素が文字列でないと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: 0, lines: [123] }]),
    TypeError,
    "lines[0]",
  );
});

Deno.test("lines の要素が空文字列だと TypeError", () => {
  assertThrows(
    () => assertPoemStanzas([{ id: "stanza-1", time: 0, lines: [""] }]),
    TypeError,
    "lines[0]",
  );
});

Deno.test("null 要素は TypeError", () => {
  assertThrows(() => assertPoemStanzas([null]), TypeError);
});
