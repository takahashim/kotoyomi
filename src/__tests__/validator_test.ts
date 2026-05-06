import { assertThrows } from "jsr:@std/assert@^1.0.0";
import { assertPoemLines } from "../validator.ts";

Deno.test("正常な PoemLine[] は通過する", () => {
  assertPoemLines([
    { id: "line-1", time: 0, text: "a" },
    { id: "line-2", time: 1.5, text: "b" },
  ]);
});

Deno.test("空配列も通過する", () => {
  assertPoemLines([]);
});

Deno.test("配列でないと TypeError", () => {
  assertThrows(() => assertPoemLines({ id: "x" }), TypeError);
});

Deno.test("id が文字列でないと TypeError", () => {
  assertThrows(
    () => assertPoemLines([{ id: 1, time: 0, text: "a" }]),
    TypeError,
    "id",
  );
});

Deno.test("time が数値でないと TypeError", () => {
  assertThrows(
    () => assertPoemLines([{ id: "line-1", time: "0", text: "a" }]),
    TypeError,
    "time",
  );
});

Deno.test("time が NaN だと TypeError", () => {
  assertThrows(
    () => assertPoemLines([{ id: "line-1", time: NaN, text: "a" }]),
    TypeError,
    "time",
  );
});

Deno.test("text が文字列でないと TypeError", () => {
  assertThrows(
    () => assertPoemLines([{ id: "line-1", time: 0, text: 123 }]),
    TypeError,
    "text",
  );
});

Deno.test("null 要素は TypeError", () => {
  assertThrows(() => assertPoemLines([null]), TypeError);
});
