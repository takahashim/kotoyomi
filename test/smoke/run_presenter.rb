# frozen_string_literal: true

# Host smoke test for the presenter view (PresenterDeck) — the Ruby port of
# test/smoke/run-presenter.mjs. Boots the vendored lilac.wasm on wasmtime-rb
# (dommy-js-wasmtime, QuickJS + Dommy) and checks the presenter view renders the
# current slide, the upcoming previews, and the speaker notes, and that
# navigating advances all of them.
#
# Cross-window sync (BroadcastChannel) is NOT exercised: it's removed so
# PresenterDeck#setup_sync no-ops (a browser-only two-window feature). This smoke
# covers the render + local navigation contract.
#
# Run: ruby test/smoke/run_presenter.rb   (or `make smoke`)

require "json"

require "dommy"
require "dommy/js/wasmtime" # provided via Gemfile (gem "dommy-js-wasmtime")

ROOT = File.expand_path("../..", __dir__)
WASM = File.join(ROOT, "vendor/lilac/lilac.wasm")
SOURCES = %w[bus slides renderer player vtt_track slide deck].map { |n| File.join(ROOT, "lib/#{n}.rb") }

# 5 slides; slide 0 carries notes, slide 1 is a poem (player) slide.
SLIDES_JSON = JSON.generate(
  "metadata" => { "title" => "Smoke", "language" => "ja", "total_slides" => 5 },
  "slides" => [
    { "index" => 0, "title" => "Intro", "html" => "<h1>Intro</h1><p>x</p>", "layout" => "two-column",
      "regions" => ["<h1>Intro</h1>", "<p>x</p>"], "speaker_notes" => "発表者メモ0", "dynamic" => false, "player" => nil },
    { "index" => 1, "title" => "A", "html" => "<h1>A</h1>", "layout" => nil, "speaker_notes" => nil, "dynamic" => false,
      "player" => { "audio" => "media/a.mp3", "vtt" => "WEBVTT\n\n00:00.000 --> 00:01.000\nあ\n" } },
    { "index" => 2, "title" => "B", "html" => "<h1>B</h1>", "layout" => nil, "speaker_notes" => nil,
      "dynamic" => false, "player" => nil },
    { "index" => 3, "title" => "C", "html" => "<h1>C</h1>", "layout" => nil, "speaker_notes" => nil,
      "dynamic" => false, "player" => nil },
    { "index" => 4, "title" => "D", "html" => "<h1>D</h1>", "layout" => nil, "speaker_notes" => nil,
      "dynamic" => false, "player" => nil }
  ]
)

SETUP_JS = <<~JS
  delete globalThis.BroadcastChannel;
  globalThis.fetch = async (url) =>
    new Response(#{SLIDES_JSON.to_json}, { status: 200, headers: { "Content-Type": "application/json" } });
JS

FAILS = []
def check(cond, msg)
  return if cond

  FAILS << msg
  warn "FAIL: #{msg}"
end

vm = Dommy::Js::Wasmtime.boot(wasm: WASM, html: File.read(File.join(ROOT, "viewer/presenter.html")),
                              sources: SOURCES, entrypoint: "Lilac.start") do |engine|
  engine.eval(SETUP_JS)
end
DOC = vm.document
$engine = vm.engine
$vm = vm

def q(sel) = DOC.query_selector(sel)
def qa(sel) = DOC.query_selector_all(sel)

def dispatch(js)
  $engine.eval(js)
  $vm.drain_async!
end

# Initial: current = slide 0, 3 upcoming previews (2/3/4), notes of slide 0.
check(q(".preview-current").inner_html.include?("Intro"), "current preview is slide 0")
check(q(".preview-current .slide-body").get_attribute("data-layout") == "two-column",
      "current preview applies the slide layout (two-column)")
check(qa(".preview-current .slide-region").length == 2,
      "current preview renders regions (got #{qa('.preview-current .slide-region').length})")
check(q(".counter").text_content == "1 / 5", "counter '1 / 5' (got #{q('.counter').text_content})")
previews = qa(".preview-list .preview-small")
check(previews.length == 3, "3 upcoming previews (got #{previews.length})")
check(qa(".preview-num")[0].text_content == "2",
      "first upcoming numbered 2 (got #{qa('.preview-num')[0]&.text_content})")
check(previews[0].inner_html.include?("A"), "first upcoming is slide 1 (A)")
check(q(".notes-body").text_content.include?("発表者メモ0"), "notes of current slide shown")
check(q(".presenter-player").class_list.contains?("lil-hidden"), "player remote hidden on non-poem slide")
puts "[ok] presenter renders current + upcoming + notes"

# Advance with ArrowRight: everything tracks @index.
dispatch('document.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }))')
check(q(".preview-current").inner_html.include?("A"), "current advanced to slide 1 (A)")
check(q(".counter").text_content == "2 / 5", "counter '2 / 5' (got #{q('.counter').text_content})")
check(qa(".preview-num")[0].text_content == "3",
      "upcoming now starts at 3 (got #{qa('.preview-num')[0]&.text_content})")
check(q(".notes-body").text_content.include?("ノートはありません"), "no-notes placeholder for slide 1")
puts "[ok] navigation advances current + upcoming + notes"

# Slide 1 is a poem slide → the remote-control appears with 3 buttons.
check(!q(".presenter-player").class_list.contains?("lil-hidden"), "player remote shown on poem slide")
check(qa(".presenter-player .controls button").length == 3, "remote has play/pause/reset")
dispatch('document.querySelector(\'.presenter-player [data-on-click="play"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))')
dispatch('document.querySelector(\'.presenter-player [data-on-click="reset"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))')
puts "[ok] poem slide shows the play/pause/reset remote + indicator"

# Near the end: fewer upcoming previews (clamped, no wrap).
dispatch('document.querySelector(\'[data-on-click="go_next"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))') # -> 2 (B)
dispatch('document.querySelector(\'[data-on-click="go_next"]\').dispatchEvent(new MouseEvent("click", { bubbles: true }))') # -> 3 (C)
check(q(".counter").text_content == "4 / 5", "counter '4 / 5' (got #{q('.counter').text_content})")
check(qa(".preview-list .preview-small").length == 1,
      "only 1 upcoming near end (got #{qa('.preview-list .preview-small').length})")
puts "[ok] upcoming clamps at the end (no wrap)"

if FAILS.empty?
  puts "ALL OK"
else
  warn "\n#{FAILS.length} check(s) failed"
  exit 1
end
