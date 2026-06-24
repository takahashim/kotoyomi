// Host smoke test for the presenter view (PresenterDeck). Boots the vendored
// lilac.wasm under happy-dom and checks that the presenter view renders the
// current slide, the upcoming previews, and the speaker notes, and that
// navigating advances all of them.
//
// Cross-window sync (BroadcastChannel) is NOT exercised here: happy-dom has no
// BroadcastChannel, so PresenterDeck#setup_sync no-ops (verified indirectly by
// boot succeeding). Sync is a browser-only, two-window feature — checked
// manually. This smoke covers the render + local navigation contract.
//
// Run: npm run smoke:presenter  (node --experimental-wasm-exnref)

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// See run-node.mjs: remove Node's BroadcastChannel so the deck runs the
// no-sync path (cross-window sync is browser-only and would keep the event
// loop alive here).
delete globalThis.BroadcastChannel;

const { Window } = await import("happy-dom");
const dom = new Window({ url: "https://test.local/" });
globalThis.document = dom.document;
globalThis.window = dom;
globalThis.requestAnimationFrame = dom.requestAnimationFrame.bind(dom);
globalThis.cancelAnimationFrame = dom.cancelAnimationFrame.bind(dom);
globalThis.MutationObserver = dom.MutationObserver;
globalThis.URL = dom.URL ?? globalThis.URL;
globalThis.Blob = dom.Blob ?? globalThis.Blob;

// 5 slides; slide 0 carries notes. No player slides needed for this view.
const SLIDES_JSON = JSON.stringify({
  metadata: { title: "Smoke", language: "ja", total_slides: 5 },
  slides: [
    { index: 0, title: "Intro", html: "<h1>Intro</h1><p>x</p>", layout: "two-column",
      regions: ["<h1>Intro</h1>", "<p>x</p>"],
      speaker_notes: "発表者メモ0", dynamic: false, player: null },
    // Slide 1 is a poem (player) slide → presenter shows the remote-control.
    { index: 1, title: "A", html: "<h1>A</h1>", layout: null,
      speaker_notes: null, dynamic: false,
      player: { audio: "media/a.mp3", vtt: "WEBVTT\n\n00:00.000 --> 00:01.000\nあ\n" } },
    { index: 2, title: "B", html: "<h1>B</h1>", layout: null,
      speaker_notes: null, dynamic: false, player: null },
    { index: 3, title: "C", html: "<h1>C</h1>", layout: null,
      speaker_notes: null, dynamic: false, player: null },
    { index: 4, title: "D", html: "<h1>D</h1>", layout: null,
      speaker_notes: null, dynamic: false, player: null },
  ],
});

globalThis.fetch = async (url) => {
  const s = String(url);
  if (s.endsWith("slides.json")) {
    return new Response(SLIDES_JSON, { headers: { "Content-Type": "application/json" } });
  }
  const path = fileURLToPath(new URL(s, import.meta.url));
  return new Response(await readFile(path), {
    headers: { "Content-Type": s.endsWith(".wasm") ? "application/wasm" : "text/plain" },
  });
};

// Mirror viewer/presenter.html body.
document.body.innerHTML = `
  <main class="presenter" data-component="PresenterDeck">
    <header class="presenter-bar">
      <button type="button" data-on-click="go_prev">←</button>
      <span class="counter" data-text="@counter"></span>
      <button type="button" data-on-click="go_next">→</button>
    </header>
    <div class="presenter-grid">
      <section class="presenter-current">
        <div class="preview preview-current">
          <div class="slide-body" data-attr-data-layout="@current_layout">
            <div class="slide-regions" data-each="@current_regions" data-key="n">
              <div class="slide-region slide-html" data-unsafe-html="html"></div>
            </div>
          </div>
        </div>
        <div class="presenter-player" data-show="@has_player">
          <div class="progress" data-ref="progress">
            <div class="progress-played" data-ref="progress_played"></div>
          </div>
          <div class="controls">
            <button type="button" data-on-click="play">再生する</button>
            <button type="button" data-on-click="pause">止める</button>
            <button type="button" data-on-click="reset">最初に戻る</button>
          </div>
        </div>
      </section>
      <section class="presenter-next">
        <div class="preview-list" data-each="@upcoming" data-key="n">
          <div class="preview preview-small">
            <span class="preview-num" data-text="num"></span>
            <div class="preview-body slide-html" data-unsafe-html="html"></div>
          </div>
        </div>
      </section>
    </div>
    <section class="presenter-notes">
      <div class="notes-body" data-text="@notes"></div>
    </section>
  </main>
  <p id="boot-error" class="error" hidden></p>
`;

const { bootRuby } = await import("../../src/ruby_runtime.js");
await bootRuby();
const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));
await tick();

const q = (sel) => document.querySelector(sel);
const qa = (sel) => Array.from(document.querySelectorAll(sel));
function check(cond, msg) {
  if (!cond) { console.error("FAIL:", msg); process.exit(1); }
}

// Initial: current = slide 0, 3 upcoming previews (2/3/4), notes of slide 0.
check(q(".preview-current").innerHTML.includes("Intro"), "current preview is slide 0");
// presenter-current uses the same slide-body/regions layout as the normal view.
check(q(".preview-current .slide-body").getAttribute("data-layout") === "two-column",
      "current preview applies the slide layout (two-column)");
check(qa(".preview-current .slide-region").length === 2,
      `current preview renders regions (got ${qa(".preview-current .slide-region").length})`);
check(q(".counter").textContent === "1 / 5", `counter "1 / 5" (got ${q(".counter").textContent})`);
const previews = qa(".preview-list .preview-small");
check(previews.length === 3, `3 upcoming previews (got ${previews.length})`);
check(qa(".preview-num")[0].textContent === "2", `first upcoming numbered 2 (got ${qa(".preview-num")[0].textContent})`);
check(previews[0].innerHTML.includes("A"), "first upcoming is slide 1 (A)");
check(q(".notes-body").textContent.includes("発表者メモ0"), "notes of current slide shown");
// Slide 0 is not a poem slide → the remote-control is hidden.
check(q(".presenter-player").classList.contains("lil-hidden"), "player remote hidden on non-poem slide");
console.log("[ok] presenter renders current + upcoming + notes");

// Advance with ArrowRight: everything tracks @index.
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
await tick();
check(q(".preview-current").innerHTML.includes("A"), "current advanced to slide 1 (A)");
check(q(".counter").textContent === "2 / 5", `counter "2 / 5" (got ${q(".counter").textContent})`);
check(qa(".preview-num")[0].textContent === "3", `upcoming now starts at 3 (got ${qa(".preview-num")[0].textContent})`);
check(q(".notes-body").textContent.includes("ノートはありません"), "no-notes placeholder for slide 1");
console.log("[ok] navigation advances current + upcoming + notes");

// Slide 1 is a poem slide → the remote-control appears with 3 buttons, and
// the buttons are clickable (no-op here: BroadcastChannel removed above).
check(!q(".presenter-player").classList.contains("lil-hidden"), "player remote shown on poem slide");
check(qa(".presenter-player .controls button").length === 3, "remote has play/pause/reset");
q('.presenter-player [data-on-click="play"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
q('.presenter-player [data-on-click="reset"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
await tick();
console.log("[ok] poem slide shows the play/pause/reset remote + indicator");

// Near the end: fewer upcoming previews (clamped, no wrap).
q('[data-on-click="go_next"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })); // -> 2 (B)
await tick();
q('[data-on-click="go_next"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })); // -> 3 (C)
await tick();
check(q(".counter").textContent === "4 / 5", `counter "4 / 5" (got ${q(".counter").textContent})`);
check(qa(".preview-list .preview-small").length === 1, `only 1 upcoming near end (got ${qa(".preview-list .preview-small").length})`);
console.log("[ok] upcoming clamps at the end (no wrap)");

console.log("ALL OK");
