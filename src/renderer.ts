import type { PoemStanza } from "./types.ts";

export function renderPoem(stanzas: PoemStanza[], container: HTMLElement): HTMLElement[] {
  container.replaceChildren();

  const elements: HTMLElement[] = [];
  for (const stanza of stanzas) {
    const div = document.createElement("div");
    div.id = stanza.id;
    div.className = "stanza";
    div.dataset.time = String(stanza.time);

    for (const line of stanza.lines) {
      const p = document.createElement("p");
      p.className = "stanza-line";
      p.textContent = line;
      div.appendChild(p);
    }

    container.appendChild(div);
    elements.push(div);
  }
  return elements;
}
