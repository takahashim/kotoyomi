export type PoemPlayerParams = {
  track: TextTrack;
  elements: HTMLElement[];
};

export class PoemPlayer {
  private readonly track: TextTrack;
  private readonly elements: HTMLElement[];
  private readonly cueList: TextTrackCue[];
  private currentIndex = -1;
  private disposed = false;

  constructor(params: PoemPlayerParams) {
    this.track = params.track;
    this.elements = params.elements;
    this.cueList = params.track.cues ? Array.from(params.track.cues) : [];

    if (this.cueList.length !== this.elements.length) {
      throw new Error("cues と elements の数が一致しません。");
    }

    this.track.mode = "hidden";
    this.track.addEventListener("cuechange", this.onCueChange);
    this.update();
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.track.removeEventListener("cuechange", this.onCueChange);
  }

  private readonly onCueChange = (): void => {
    this.update();
  };

  private update(): void {
    const active = this.track.activeCues;
    const cue = active && active.length > 0 ? active[0] : null;
    const nextIndex = cue ? this.cueList.indexOf(cue) : -1;
    if (nextIndex === this.currentIndex) return;

    if (this.currentIndex >= 0) {
      this.elements[this.currentIndex].classList.remove("active");
    }
    this.currentIndex = nextIndex;
    if (nextIndex >= 0) {
      this.elements[nextIndex].classList.add("active");
    }
  }
}
