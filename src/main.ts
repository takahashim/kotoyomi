import type { Cue } from "./types.ts";
import { renderPoem } from "./renderer.ts";
import { PoemPlayer } from "./player.ts";
import { startRubyEngine } from "./ruby_engine.ts";

const AUDIO_URL = "poems/sample.mp3";

async function main(): Promise<void> {
  const audio = document.getElementById("audio") as HTMLAudioElement | null;
  const trackEl = document.getElementById("track") as HTMLTrackElement | null;
  const poemContainer = document.getElementById("poem") as HTMLElement | null;
  const errorEl = document.getElementById("error") as HTMLElement | null;

  if (!audio || !trackEl || !poemContainer || !errorEl) {
    console.error("必要なDOM要素が見つかりません。");
    return;
  }

  audio.src = AUDIO_URL;

  const engine = new URLSearchParams(globalThis.location.search).get("engine") ?? "ts";

  try {
    const track = trackEl.track;
    track.mode = "hidden";
    await waitForTrackLoad(trackEl);
    const cues = track.cues ? Array.from(track.cues) as VTTCue[] : [];
    const cueData = cues.map(toCue);

    if (engine === "ruby") {
      await startRubyEngine({ track, cues: cueData, container: poemContainer });
    } else {
      const elements = renderPoem(cueData, poemContainer);
      new PoemPlayer({ track, elements });
    }
  } catch (err) {
    console.error(err);
    errorEl.textContent = `${
      engine === "ruby"
        ? "Ruby エンジンの起動に失敗しました。"
        : "字幕トラックの読み込みに失敗しました。"
    }\n${err instanceof Error ? err.message : String(err)}`;
    errorEl.hidden = false;
  }
}

function waitForTrackLoad(trackEl: HTMLTrackElement): Promise<void> {
  if (trackEl.readyState === 2) return Promise.resolve();
  if (trackEl.readyState === 3) return Promise.reject(new Error("track load error"));
  return new Promise<void>((resolve, reject) => {
    const onLoad = (): void => {
      cleanup();
      resolve();
    };
    const onError = (): void => {
      cleanup();
      reject(new Error("track load error"));
    };
    const cleanup = (): void => {
      trackEl.removeEventListener("load", onLoad);
      trackEl.removeEventListener("error", onError);
    };
    trackEl.addEventListener("load", onLoad);
    trackEl.addEventListener("error", onError);
  });
}

function toCue(cue: VTTCue): Cue {
  return { id: cue.id, startTime: cue.startTime, text: cue.text };
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => void main());
} else {
  void main();
}
