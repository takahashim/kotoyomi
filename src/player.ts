import type { PoemStanza } from "./types.ts";

export type PoemPlayerParams = {
  audio: HTMLAudioElement;
  stanzas: PoemStanza[];
  elements: HTMLElement[];
};

export class PoemPlayer {
  private readonly audio: HTMLAudioElement;
  private readonly stanzas: PoemStanza[];
  private readonly elements: HTMLElement[];
  private rafId: number | null = null;
  private currentIndex = -1;
  private disposed = false;

  constructor(params: PoemPlayerParams) {
    if (params.stanzas.length !== params.elements.length) {
      throw new Error("stanzas と elements の数が一致しません。");
    }
    this.audio = params.audio;
    this.stanzas = params.stanzas;
    this.elements = params.elements;

    this.audio.addEventListener("play", this.onPlay);
    this.audio.addEventListener("pause", this.onPause);
    this.audio.addEventListener("ended", this.onPause);
    this.audio.addEventListener("seeked", this.onSeeked);

    this.update();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.stopLoop();
    this.audio.removeEventListener("play", this.onPlay);
    this.audio.removeEventListener("pause", this.onPause);
    this.audio.removeEventListener("ended", this.onPause);
    this.audio.removeEventListener("seeked", this.onSeeked);
  }

  private readonly onPlay = (): void => {
    this.startLoop();
  };

  private readonly onPause = (): void => {
    this.stopLoop();
    this.update();
  };

  private readonly onSeeked = (): void => {
    this.update();
  };

  private startLoop(): void {
    if (this.rafId !== null) return;
    const tick = (): void => {
      this.update();
      this.rafId = globalThis.requestAnimationFrame(tick);
    };
    this.rafId = globalThis.requestAnimationFrame(tick);
  }

  private stopLoop(): void {
    if (this.rafId === null) return;
    globalThis.cancelAnimationFrame(this.rafId);
    this.rafId = null;
  }

  private update(): void {
    const nextIndex = this.findIndex(this.audio.currentTime);
    if (nextIndex === this.currentIndex) return;

    if (this.currentIndex >= 0) {
      this.elements[this.currentIndex].classList.remove("active");
    }
    this.currentIndex = nextIndex;
    if (nextIndex >= 0) {
      this.elements[nextIndex].classList.add("active");
    }
  }

  private findIndex(currentTime: number): number {
    if (this.stanzas.length === 0) return -1;
    if (currentTime < this.stanzas[0].time) return -1;

    let lo = 0;
    let hi = this.stanzas.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >>> 1;
      if (this.stanzas[mid].time <= currentTime) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
