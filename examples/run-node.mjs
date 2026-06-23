// Host smoke test for the kotoyomi slide viewer (deck). Boots the vendored
// lilac.wasm under happy-dom and drives the SlideDeck / Slide components
// the same way a browser would, minus the bits happy-dom can't do (real
// <track>/TextTrack — see run-node.mjs's note and the browser manual check).
//
// What it verifies:
//   - SlideDeck#setup fetches slides.json (via Fetchy → globalThis.fetch),
//     parses it (Kotoyomi::Slides), and renders the current slide.
//   - data-each="@visible" mounts exactly the current slide; navigating
//     (ArrowRight) unmounts the previous slide and mounts the next.
//   - prev/next disabled state + counter track @index.
//   - A player slide mounts: its <track>.track cues are stubbed (happy-dom
//     has no TextTrack), so we patch HTMLTrackElement to expose FAKE_CUES and
//     report readyState=LOADED; we then assert the cue→stanza render and that
//     leaving the slide pauses its audio.
//
// Run: npm run smoke  (node --experimental-wasm-exnref)

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

// --- happy-dom globals (mirror lilac/test/runner.mjs) ----------------------
// The bridge's `JS.global` is Node's globalThis, which DOES define
// BroadcastChannel — so without this the deck opens a real channel that keeps
// the event loop alive (process never exits) and that we can't drive anyway
// (cross-window sync is browser-only). Remove it so the deck runs the no-sync
// path, matching a single-window environment.
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

// happy-dom has no real TextTrack. Patch every <track> so the player slide's
// readyState is LOADED and `.track.cues` yields fixed cues (content model A).
const FAKE_CUES = [
  { id: "c1", startTime: 0, endTime: 1.5, text: "あさ\nゆきが\nふって" },
  { id: "", startTime: 1.5, endTime: 3, text: "ひるに\nやんだ" },
];
const cues = { length: FAKE_CUES.length };
FAKE_CUES.forEach((c, i) => { cues[i] = c; });
const TrackProto = dom.window.HTMLTrackElement.prototype;
Object.defineProperty(TrackProto, "readyState", { get: () => 2, configurable: true });
Object.defineProperty(TrackProto, "track", {
  get: () => ({ mode: "disabled", cues }),
  configurable: true,
});

// --- slides.json fixture (1 html-only slide + 1 player slide) --------------
const SLIDES_JSON = JSON.stringify({
  metadata: { title: "Smoke", language: "ja", total_slides: 2, theme: "dark" },
  slides: [
    // Two-column layout (2 regions) + speaker notes.
    { index: 0, title: "Intro", html: "<h1>Intro</h1><p>hello</p>",
      layout: "two-column", regions: ["<h1>Intro</h1>", "<p>hello</p>"],
      speaker_notes: "発表者メモA", dynamic: false, player: null },
    // No regions/layout → single-region fallback path.
    { index: 1, title: "Sakura", html: "<h1>Sakura</h1>",
      layout: null, speaker_notes: null, dynamic: false,
      player: { audio: "media/sakura.mp3", vtt: "WEBVTT\n\n00:00.000 --> 00:01.500\nあさ\n" } },
  ],
});

// fetch polyfill: slides.json → fixture; rb/wasm → local file reads.
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

// --- Build the deck DOM (mirrors viewer/index.html body) -------------------
document.body.innerHTML = `
  <main class="deck" data-component="SlideDeck">
    <div class="audio-unlock" data-show="@show_unlock">
      <button type="button" data-on-click="unlock_audio">🔊 クリックして再生を有効化</button>
    </div>
    <section class="stage" data-each="@visible" data-key="index">
      <article class="slide" data-component="Slide">
        <div class="slide-body" data-attr-data-layout="@layout">
          <div class="slide-regions" data-each="@region_list" data-key="n">
            <div class="slide-region slide-html" data-unsafe-html="html"></div>
          </div>
        </div>
        <div class="player" data-show="@has_player">
          <div class="poem" data-each="@stanzas" data-key="id">
            <div class="stanza" data-class="{ active: active }" data-each="lines" data-key="n">
              <p class="stanza-line" data-text="text"></p>
            </div>
          </div>
          <div class="progress" data-ref="progress">
            <div class="progress-played" data-ref="progress_played"></div>
          </div>
          <audio data-ref="audio" crossorigin="anonymous">
            <track data-ref="track" kind="metadata" default />
          </audio>
          <div class="controls">
            <button data-ref="play" type="button" data-on-click="play">再生する</button>
            <button data-ref="pause" type="button" data-on-click="pause">止める</button>
            <button data-ref="reset" type="button" data-on-click="reset">最初に戻る</button>
          </div>
        </div>
        <p data-ref="error" class="error" hidden></p>
        <aside class="notes" data-show="@has_notes">
          <div class="notes-body" data-text="@notes"></div>
        </aside>
      </article>
    </section>
    <nav class="deck-nav">
      <button data-ref="prev" type="button" data-on-click="go_prev" data-attr-disabled="@at_start">←</button>
      <span class="counter" data-text="@counter"></span>
      <button data-ref="next" type="button" data-on-click="go_next" data-attr-disabled="@at_end">→</button>
    </nav>
  </main>
  <p id="boot-error" class="error" hidden></p>
`;

// --- Boot the real runtime -------------------------------------------------
const { bootRuby } = await import("../src/ruby_runtime.js");
await bootRuby();
const tick = (ms = 30) => new Promise((r) => setTimeout(r, ms));
await tick();

// --- Assertions ------------------------------------------------------------
const q = (sel) => document.querySelector(sel);
const qa = (sel) => Array.from(document.querySelectorAll(sel));
function check(cond, msg) {
  if (!cond) { console.error("FAIL:", msg); process.exit(1); }
}

// Slide 0 (two-column, 2 regions, speaker notes) is mounted; counter + prev disabled.
check(qa(".stage .slide").length === 1, "exactly one slide mounted");
check(q(".slide-html").innerHTML.includes("Intro"), "slide 0 html rendered");
check(qa(".slide-body .slide-region").length === 2, `slide 0 split into 2 regions (got ${qa(".slide-body .slide-region").length})`);
check(q(".slide-body").getAttribute("data-layout") === "two-column", "slide 0 data-layout=two-column");
check(q(".notes-body").textContent.includes("発表者メモA"), "speaker notes rendered (hidden until toggled)");
check(q(".counter").textContent === "1 / 2", `counter is "1 / 2" (got ${q(".counter").textContent})`);
check(q('[data-ref="prev"]').disabled === true, "prev disabled on first slide");
check(q('[data-ref="next"]').disabled === false, "next enabled on first slide");
console.log("[ok] slide 0 renders (two-column + notes); nav state correct");

// Theme comes from slides.json metadata (Markdown frontmatter), applied on boot.
check(document.documentElement.getAttribute("data-theme") === "dark", "theme applied from metadata (frontmatter)");
console.log("[ok] theme from frontmatter metadata");

// Audio-unlock banner: shown on the first page (deck has a poem slide),
// then gone after the click (the click is the user gesture that unlocks).
check(!q(".audio-unlock").classList.contains("lil-hidden"), "audio unlock banner shown on first slide");
q('.audio-unlock [data-on-click="unlock_audio"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
await tick();
check(q(".audio-unlock").classList.contains("lil-hidden"), "audio unlock banner hidden after click");
console.log("[ok] audio unlock banner (first page)");

// Presenter notes toggle: 'n' adds/removes the show-notes class on <html>.
check(!document.documentElement.classList.contains("show-notes"), "notes hidden by default");
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "n", bubbles: true }));
await tick();
check(document.documentElement.classList.contains("show-notes"), "n toggles presenter notes on");
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "n", bubbles: true }));
await tick();
check(!document.documentElement.classList.contains("show-notes"), "n toggles presenter notes off");
console.log("[ok] presenter notes toggle (n)");

// Navigate: ArrowRight → slide 1 (player). Previous slide unmounts.
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }));
await tick();

check(qa(".stage .slide").length === 1, "still exactly one slide after nav (prev unmounted)");
check(q(".slide-html").innerHTML.includes("Sakura"), "slide 1 html rendered");
check(qa(".slide-body .slide-region").length === 1, `slide 1 single region (fallback) (got ${qa(".slide-body .slide-region").length})`);
check(q(".slide-body").getAttribute("data-layout") === null, "slide 1 has no data-layout (nil → removed)");
check(q(".counter").textContent === "2 / 2", `counter is "2 / 2" (got ${q(".counter").textContent})`);
check(q('[data-ref="next"]').disabled === true, "next disabled on last slide");
console.log("[ok] navigation advances + unmounts previous slide");

// Player slide: cue→stanza render (FAKE_CUES = 2 stanzas, 5 lines, active 1).
const stanzas = qa(".stanza");
const lines = qa(".stanza-line");
const active = qa(".stanza.active");
check(stanzas.length === FAKE_CUES.length, `2 stanzas (got ${stanzas.length})`);
check(lines.length === 5, `5 stanza lines (got ${lines.length})`);
check(active.length === 1, `exactly one active stanza (got ${active.length})`);
console.log("[ok] player slide renders cue→stanza with one active");

// Custom progress bar: a timeupdate should set the played width to
// currentTime/duration (two-colour played/remaining line).
const audioEl = q('[data-ref="audio"]');
Object.defineProperty(audioEl, "duration", { value: 10, configurable: true });
Object.defineProperty(audioEl, "currentTime", { value: 4, writable: true, configurable: true });
audioEl.dispatchEvent(new dom.window.Event("timeupdate"));
await tick();
const played = q(".progress-played");
check(played, "progress-played element exists");
check(
  played.style.width.startsWith("40") && played.style.width.endsWith("%"),
  `progress played width ~40% (got ${played.style.width})`,
);
console.log("[ok] custom progress bar tracks playback position");

// Play / pause buttons drive the (native-controls-hidden) <audio>.
let playCalled = false;
let pauseCalled = false;
audioEl.play = () => { playCalled = true; };
audioEl.pause = () => { pauseCalled = true; };
q('[data-ref="play"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
await tick();
check(playCalled, "再生する button calls audio.play()");
q('[data-ref="pause"]').dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
await tick();
check(pauseCalled, "止める button calls audio.pause()");
console.log("[ok] play / pause buttons drive audio");

// Leave the player slide: its audio must be paused (cleanup on unmount).
pauseCalled = false;
document.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }));
await tick();
check(q(".slide-html").innerHTML.includes("Intro"), "navigated back to slide 0");
check(pauseCalled, "leaving the player slide paused its audio");
console.log("[ok] leaving player slide pauses audio");

// Hot reload: a "kotoyomi:slides" event (what the dev poller dispatches) swaps
// @slides in place — Lilac re-renders the current slide without a page reload.
const reloaded = {
  metadata: { title: "Reloaded", language: "ja", total_slides: 1 },
  slides: [
    { index: 0, title: "Reloaded", html: "<h1>Reloaded</h1>", layout: null,
      regions: ["<h1>Reloaded</h1>"], speaker_notes: null, dynamic: false, player: null },
  ],
};
document.dispatchEvent(new dom.window.CustomEvent("kotoyomi:slides", { detail: reloaded }));
await tick();
check(q(".slide-html").innerHTML.includes("Reloaded"), "hot reload swapped slide content");
check(q(".counter").textContent === "1 / 1", `counter after reload "1 / 1" (got ${q(".counter").textContent})`);
console.log("[ok] hot reload swaps slides in place");

console.log("ALL OK");
