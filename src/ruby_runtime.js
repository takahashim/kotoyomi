const RUBY_WASM_VERSION = "2.8.1";
const BROWSER_ESM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@${RUBY_WASM_VERSION}/dist/browser/+esm`;
const RUBY_WASM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@${RUBY_WASM_VERSION}/dist/ruby+stdlib.wasm`;

// import.meta.url 起点で解決する。これによりこのモジュールが
// CDN や別オリジンから import されても lib/*.rb を同じ場所から取得できる。
const RUBY_SOURCES = [
  "lib/dom.rb",
  "lib/renderer.rb",
  "lib/player.rb",
  "lib/kotoyomi.rb",
].map((path) => new URL(`../${path}`, import.meta.url).href);

export async function bootRuby() {
  const [{ DefaultRubyVM }, wasmResponse] = await Promise.all([
    import(BROWSER_ESM_URL),
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

  await vm.evalAsync("Kotoyomi.start");
}
