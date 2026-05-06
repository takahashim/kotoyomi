import { parsePoem } from "./parser.ts";
import { renderPoem } from "./renderer.ts";
import { PoemPlayer } from "./player.ts";

const POEM_URL = "poems/sample.poem";
const AUDIO_URL = "poems/sample.mp3";

async function main(): Promise<void> {
  const audio = document.getElementById("audio") as HTMLAudioElement | null;
  const poemContainer = document.getElementById("poem") as HTMLElement | null;
  const errorEl = document.getElementById("error") as HTMLElement | null;

  if (!audio || !poemContainer || !errorEl) {
    console.error("必要なDOM要素が見つかりません。");
    return;
  }

  try {
    const response = await fetch(POEM_URL);
    if (!response.ok) {
      throw new Error(`詩テキストの取得に失敗しました (${response.status})`);
    }
    const source = await response.text();
    const lines = parsePoem(source);
    const elements = renderPoem(lines, poemContainer);
    audio.src = AUDIO_URL;
    new PoemPlayer({ audio, lines, elements });
  } catch (err) {
    console.error(err);
    errorEl.textContent = `詩テキストの読み込みに失敗しました。\n${
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
