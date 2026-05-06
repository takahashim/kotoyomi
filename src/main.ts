import { startRubyEngine } from "./ruby_engine.ts";

async function main(): Promise<void> {
  const audio = document.getElementById("audio") as HTMLAudioElement;
  const trackEl = document.getElementById("track") as HTMLTrackElement;
  const poem = document.getElementById("poem") as HTMLElement;
  const errorEl = document.getElementById("error") as HTMLElement;
  const resetBtn = document.getElementById("reset") as HTMLButtonElement;

  resetBtn.addEventListener("click", () => {
    audio.currentTime = 0;
  });

  try {
    await startRubyEngine({ trackEl, container: poem });
    audio.currentTime = 0;
  } catch (err) {
    console.error(err);
    errorEl.textContent = `起動に失敗しました。\n${
      err instanceof Error ? err.message : String(err)
    }`;
    errorEl.hidden = false;
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => void main());
} else {
  void main();
}
