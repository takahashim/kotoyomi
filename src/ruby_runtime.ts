const RUBY_WASM_VERSION = "2.8.1";
const BROWSER_ESM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/wasm-wasi@${RUBY_WASM_VERSION}/dist/browser/+esm`;
const RUBY_WASM_URL =
  `https://cdn.jsdelivr.net/npm/@ruby/3.4-wasm-wasi@${RUBY_WASM_VERSION}/dist/ruby+stdlib.wasm`;

const RUBY_SOURCES = [
  "src-rb/renderer.rb",
  "src-rb/player.rb",
  "src-rb/kotoyomi.rb",
];

type RubyVM = {
  eval(code: string): unknown;
  evalAsync(code: string): Promise<unknown>;
};

type DefaultRubyVM = (
  module: WebAssembly.Module,
) => Promise<{ vm: RubyVM }>;

export async function bootRuby(): Promise<void> {
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

  await vm.evalAsync("Kotoyomi.start");
}
