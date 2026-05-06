import { bootRuby } from "./ruby_runtime.ts";

async function main(): Promise<void> {
  try {
    await bootRuby();
  } catch (err) {
    console.error(err);
    const errorEl = document.getElementById("error") as HTMLElement | null;
    if (errorEl) {
      errorEl.textContent = `起動に失敗しました。\n${
        err instanceof Error ? err.message : String(err)
      }`;
      errorEl.hidden = false;
    }
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => void main());
} else {
  void main();
}
