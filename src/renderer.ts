import type { Cue } from "./types.ts";

export function renderPoem(cues: Cue[], container: HTMLElement): HTMLElement[] {
  container.replaceChildren();

  const elements: HTMLElement[] = [];
  cues.forEach((cue, i) => {
    const div = document.createElement("div");
    div.id = cue.id || `stanza-${i + 1}`;
    div.className = "stanza";
    div.dataset.startTime = String(cue.startTime);

    for (const line of cue.text.split("\n")) {
      const p = document.createElement("p");
      p.className = "stanza-line";
      p.textContent = line;
      div.appendChild(p);
    }

    container.appendChild(div);
    elements.push(div);
  });
  return elements;
}
