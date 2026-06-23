import { bootRuby } from "./ruby_runtime.js";
import { setupHotReload } from "./hotreload.js";
import { setupFitTitle } from "./fit-title.js";

async function main() {
  // テーマは Markdown frontmatter で指定し、deck 起動時に適用する(画面 UI は無し)。
  try {
    await bootRuby();
    // boot 後に開始(Ruby 側のリスナー登録が済んでいる)。localhost のみ稼働。
    setupHotReload();
    // 通常スライドの長い h1 を 1 行に収める(差し替えごとに再計測)。
    // setupFitTitle();
  } catch (err) {
    console.error(err);
    const errorEl = document.getElementById("boot-error");
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
