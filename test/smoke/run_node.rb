# frozen_string_literal: true

# Host smoke test for the kotoyomi slide viewer (deck) — the Ruby port of
# test/smoke/run-node.mjs. Instead of Node + happy-dom, it boots the vendored
# lilac.wasm on wasmtime-rb (dommy-js-wasmtime) with a QuickJS JS world bound to
# a Dommy DOM, and drives the SlideDeck / Slide components the same way a browser
# would — minus the bits Dommy can't do (real <track>/TextTrack, which we stub
# the same way the Node version did).
#
# Run: ruby test/smoke/run_node.rb   (or `make smoke`)

require "json"

require "dommy"
require "dommy/js/wasmtime" # provided via Gemfile (gem "dommy-js-wasmtime")

ROOT = File.expand_path("../..", __dir__)
WASM = File.join(ROOT, "vendor/lilac/lilac.wasm")
SOURCES = %w[bus slides renderer player vtt_track slide deck].map { |n| File.join(ROOT, "lib/#{n}.rb") }

# slides.json fixture (1 html-only slide + 1 player slide), same shape as the
# Node smoke's SLIDES_JSON.
SLIDES_JSON = JSON.generate(
  "metadata" => { "title" => "Smoke", "language" => "ja", "total_slides" => 2, "theme" => "dark" },
  "slides" => [
    { "index" => 0, "title" => "Intro", "html" => "<h1>Intro</h1><p>hello</p>",
      "layout" => "two-column", "regions" => ["<h1>Intro</h1>", "<p>hello</p>"],
      "speaker_notes" => "発表者メモA", "dynamic" => false, "player" => nil },
    { "index" => 1, "title" => "Sakura", "html" => "<h1>Sakura</h1>",
      "layout" => nil, "speaker_notes" => nil, "dynamic" => false,
      "player" => { "audio" => "media/sakura.mp3",
                    "vtt" => "WEBVTT\n\n00:00.000 --> 00:01.500\nあさ\n",
                    "reading_direction" => "horizontal" } }
  ]
)

# JS world setup: drop BroadcastChannel (force the no-sync path), stub fetch to
# the fixture, and patch <track> so the player slide's readyState is LOADED and
# `.track.cues` yields fixed cues (Dommy has no TextTrack — same as happy-dom).
SETUP_JS = <<~JS
  delete globalThis.BroadcastChannel;
  globalThis.fetch = async (url) =>
    new Response(#{SLIDES_JSON.to_json}, { status: 200, headers: { "Content-Type": "application/json" } });

  const FAKE_CUES = [
    { id: "c1", startTime: 0, endTime: 1.5, text: "あさ\\nゆきが\\nふって" },
    { id: "", startTime: 1.5, endTime: 3, text: "ひるに\\nやんだ" },
  ];
  const cues = { length: FAKE_CUES.length };
  FAKE_CUES.forEach((c, i) => { cues[i] = c; });
  // Dommy implements `readyState` (returns 0/NONE) so a prototype override is
  // shadowed; the deck then waits for a `load` event (its readyState!=2 path),
  // which the smoke dispatches after navigating to the player slide. `track`
  // isn't a Dommy property, so this prototype getter does surface the cues.
  const TrackProto = HTMLTrackElement.prototype;
  Object.defineProperty(TrackProto, "track", { get: () => ({ mode: "disabled", cues }), configurable: true });
JS

FAILS = []
def check(cond, msg)
  return if cond

  FAILS << msg
  warn "FAIL: #{msg}"
end

vm = Dommy::Js::Wasmtime.boot(wasm: WASM, html: File.read(File.join(ROOT, "viewer/index.html")),
                              sources: SOURCES, entrypoint: "Lilac.start") do |engine|
  engine.eval(SETUP_JS)
end
DOC = vm.document

def q(sel) = DOC.query_selector(sel)
def qa(sel) = DOC.query_selector_all(sel)

# Dispatch a DOM event in the JS world, then settle the event loop.
def dispatch(js)
  $engine.eval(js)
  $vm.drain_async!
end
$vm = vm
$engine = vm.engine

# --- Slide 0 (two-column, 2 regions, speaker notes); counter + prev disabled ---
check(qa(".stage .slide").length == 1, "exactly one slide mounted")
check(q(".slide-html").inner_html.include?("Intro"), "slide 0 html rendered")
check(qa(".slide-body .slide-region").length == 2,
      "slide 0 split into 2 regions (got #{qa('.slide-body .slide-region').length})")
check(q(".slide-body").get_attribute("data-layout") == "two-column", "slide 0 data-layout=two-column")
check(q(".notes-body").text_content.include?("発表者メモA"), "speaker notes rendered (hidden until toggled)")
check(q(".counter").text_content == "1 / 2", "counter is '1 / 2' (got #{q('.counter').text_content})")
check(q('[data-ref="prev"]').get_attribute("disabled"), "prev disabled on first slide")
check(q('[data-ref="next"]').get_attribute("disabled").nil?, "next enabled on first slide")
puts "[ok] slide 0 renders (two-column + notes); nav state correct"

# Theme from frontmatter metadata.
check(DOC.document_element.get_attribute("data-theme") == "dark", "theme applied from metadata (frontmatter)")
puts "[ok] theme from frontmatter metadata"

# Audio-unlock banner shown on first page (deck has a poem slide), gone after click.
check(!q(".audio-unlock").class_list.contains?("lil-hidden"), "audio unlock banner shown on first slide")
dispatch('document.querySelector(".audio-unlock [data-on-click=unlock_audio]").dispatchEvent(new MouseEvent("click", { bubbles: true }))')
check(q(".audio-unlock").class_list.contains?("lil-hidden"), "audio unlock banner hidden after click")
puts "[ok] audio unlock banner (first page)"

# Presenter notes toggle: 'n' toggles the show-notes class on <html>.
check(!DOC.document_element.class_list.contains?("show-notes"), "notes hidden by default")
dispatch('document.dispatchEvent(new KeyboardEvent("keydown", { key: "n", bubbles: true }))')
check(DOC.document_element.class_list.contains?("show-notes"), "n toggles presenter notes on")
dispatch('document.dispatchEvent(new KeyboardEvent("keydown", { key: "n", bubbles: true }))')
check(!DOC.document_element.class_list.contains?("show-notes"), "n toggles presenter notes off")
puts "[ok] presenter notes toggle (n)"

# Navigate: ArrowRight → slide 1 (player). Previous slide unmounts.
dispatch('document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }))')
check(qa(".stage .slide").length == 1, "still exactly one slide after nav (prev unmounted)")
check(q(".slide-html").inner_html.include?("Sakura"), "slide 1 html rendered")
check(qa(".slide-body .slide-region").length == 1,
      "slide 1 single region (fallback) (got #{qa('.slide-body .slide-region').length})")
check(q(".slide-body").get_attribute("data-layout").nil?, "slide 1 has no data-layout (nil → removed)")
check(q(".counter").text_content == "2 / 2", "counter is '2 / 2' (got #{q('.counter').text_content})")
check(q('[data-ref="next"]').get_attribute("disabled"), "next disabled on last slide")
puts "[ok] navigation advances + unmounts previous slide"

# The track loads asynchronously in the browser; Dommy doesn't parse VTT, so we
# fire the `load` event the deck waits on (its readyState!=2 path). build_player
# then reads `track.track.cues` (our FAKE_CUES) and renders the poem.
dispatch('document.querySelector(\'[data-ref="track"]\').dispatchEvent(new Event("load"))')

# Player slide: cue→stanza render (FAKE_CUES = 2 stanzas, 5 lines, 1 active).
check(qa(".stanza").length == 2, "2 stanzas (got #{qa('.stanza').length})")
check(qa(".stanza-line").length == 5, "5 stanza lines (got #{qa('.stanza-line').length})")
check(qa(".stanza.active").length == 1, "exactly one active stanza (got #{qa('.stanza.active').length})")
check(q(".poem").get_attribute("data-reading-direction") == "horizontal",
      "poem reading_direction applied from vtt fence")
puts "[ok] player slide renders cue→stanza with one active (+reading_direction)"

# Custom progress bar: a timeupdate sets played width to currentTime/duration.
dispatch(<<~JS)
  const audioEl = document.querySelector('[data-ref="audio"]');
  Object.defineProperty(audioEl, "duration", { value: 10, configurable: true });
  Object.defineProperty(audioEl, "currentTime", { value: 4, writable: true, configurable: true });
  audioEl.dispatchEvent(new Event("timeupdate"));
JS
played = q(".progress-played")
check(played, "progress-played element exists")
played_width = played&.style&.get_property_value("width").to_s
played_width = played&.get_attribute("style").to_s[/width:\s*([\d.]+%)/, 1].to_s if played_width.empty?
check(played_width.start_with?("40"), "progress played width ~40% (got #{played_width.inspect})")
puts "[ok] custom progress bar tracks playback position"

# Play / pause buttons drive the (native-controls-hidden) <audio>.
$engine.eval(<<~JS)
  globalThis.__playCalled = false; globalThis.__pauseCalled = false;
  const a = document.querySelector('[data-ref="audio"]');
  a.play = () => { globalThis.__playCalled = true; };
  a.pause = () => { globalThis.__pauseCalled = true; };
JS
dispatch('document.querySelector(\'[data-ref="play"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))')
check($engine.eval("globalThis.__playCalled"), "再生する button calls audio.play()")
dispatch('document.querySelector(\'[data-ref="pause"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))')
check($engine.eval("globalThis.__pauseCalled"), "止める button calls audio.pause()")
puts "[ok] play / pause buttons drive audio"

# Leave the player slide: its audio must be paused (cleanup on unmount).
$engine.eval("globalThis.__pauseCalled = false;")
dispatch('document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true }))')
check(q(".slide-html").inner_html.include?("Intro"), "navigated back to slide 0")
check($engine.eval("globalThis.__pauseCalled"), "leaving the player slide paused its audio")
puts "[ok] leaving player slide pauses audio"

# Hot reload: a "kotoyomi:slides" event swaps @slides in place.
RELOADED = JSON.generate(
  "metadata" => { "title" => "Reloaded", "language" => "ja", "total_slides" => 1 },
  "slides" => [{ "index" => 0, "title" => "Reloaded", "html" => "<h1>Reloaded</h1>", "layout" => nil,
                 "regions" => ["<h1>Reloaded</h1>"], "speaker_notes" => nil, "dynamic" => false, "player" => nil }]
)
dispatch("document.dispatchEvent(new CustomEvent('kotoyomi:slides', { detail: #{RELOADED} }))")
check(q(".slide-html").inner_html.include?("Reloaded"), "hot reload swapped slide content")
check(q(".counter").text_content == "1 / 1", "counter after reload '1 / 1' (got #{q('.counter').text_content})")
puts "[ok] hot reload swaps slides in place"

if FAILS.empty?
  puts "ALL OK"
else
  warn "\n#{FAILS.length} check(s) failed"
  exit 1
end
