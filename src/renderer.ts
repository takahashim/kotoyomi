import type { PoemLine } from "./types.ts";

export function renderPoem(lines: PoemLine[], container: HTMLElement): HTMLElement[] {
  container.replaceChildren();

  const elements: HTMLElement[] = [];
  for (const line of lines) {
    const p = document.createElement("p");
    p.id = line.id;
    p.className = "line";
    p.dataset.time = String(line.time);
    p.textContent = line.text;
    container.appendChild(p);
    elements.push(p);
  }
  return elements;
}
