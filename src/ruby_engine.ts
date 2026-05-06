import type { Cue } from "./types.ts";

const RUBY_WASM_VERSION = "2.8.1";
const BROWSER_ESM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@${RUBY_WASM_VERSION}/dist/browser/+esm`;
const RUBY_WASM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@${RUBY_WASM_VERSION}/dist/ruby+stdlib.wasm`;

const RUBY_SOURCES = ["src-rb/renderer.rb", "src-rb/player.rb"];

type RbValue = {
  call(method: string, ...args: unknown[]): RbValue;
  toString(): string;
};

type RubyVM = {
  eval(code: string): RbValue;
  wrap(value: unknown): RbValue;
};

type DefaultRubyVM = (
  module: WebAssembly.Module,
) => Promise<{ vm: RubyVM }>;

export async function startRubyEngine(params: {
  trackEl: HTMLTrackElement;
  container: HTMLElement;
}): Promise<void> {
  const track = params.trackEl.track;
  track.mode = "hidden";
  await waitForTrackLoad(params.trackEl);
  const cues = Array.from(track.cues ?? []) as VTTCue[];
  const cueData: Cue[] = cues.map((c) => ({
    id: c.id,
    startTime: c.startTime,
    text: c.text,
  }));

  const [{ DefaultRubyVM }, wasmResponse] = await Promise.all([
    import(BROWSER_ESM_URL) as Promise<{ DefaultRubyVM: DefaultRubyVM }>,
    fetch(RUBY_WASM_URL),
  ]);
  if (!wasmResponse.ok) {
    throw new Error(`ruby.wasm の取得に失敗しました (${wasmResponse.status})`);
  }
  const wasmModule = await WebAssembly.compileStreaming(wasmResponse);
  const { vm } = await DefaultRubyVM(wasmModule);

  const sources = await Promise.all(
    RUBY_SOURCES.map(async (path) => {
      const res = await fetch(path);
      if (!res.ok) throw new Error(`${path} の取得に失敗しました (${res.status})`);
      return res.text();
    }),
  );
  for (const source of sources) vm.eval(source);

  const renderer = vm.eval("Kotoyomi::Renderer");
  const elementsRb = renderer.call("render", vm.wrap(cueData), vm.wrap(params.container));

  const playerClass = vm.eval("Kotoyomi::Player");
  playerClass.call("new", vm.wrap(track), elementsRb);
}

function waitForTrackLoad(trackEl: HTMLTrackElement): Promise<void> {
  if (trackEl.readyState === 2) return Promise.resolve();
  if (trackEl.readyState === 3) return Promise.reject(new Error("track load error"));
  return new Promise((resolve, reject) => {
    const cleanup = () => {
      trackEl.removeEventListener("load", onLoad);
      trackEl.removeEventListener("error", onError);
    };
    const onLoad = () => {
      cleanup();
      resolve();
    };
    const onError = () => {
      cleanup();
      reject(new Error("track load error"));
    };
    trackEl.addEventListener("load", onLoad);
    trackEl.addEventListener("error", onError);
  });
}
