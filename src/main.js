import { bootRuby } from "./ruby_runtime.js";

async function main() {
  try {
    await bootRuby();
  } catch (err) {
    console.error(err);
    const errorEl = document.getElementById("error");
    if (errorEl) {
      errorEl.textContent = `起動に失敗しました。\n${
        err instanceof Error ? err.message : String(err)
      }`;
      errorEl.hidden = false;
    }
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => main());
} else {
  main();
}
