// 開発時のライブリロード。slides.json を監視し、変化したら
// CustomEvent("kotoyomi:slides") を detail(パース済み JSON)付きで投げる。
// Ruby 側(DeckControls#setup_hot_reload)が受けて @slides を差し替え、Lilac
// がその場で再描画する(wasm 再起動なし・表示位置/テーマは維持)。
//
// 本番(GitHub Pages 等)では動かない: localhost のときだけポーリングする。
// rqslides 側は `rqslides --watch -o viewer/slides.json examples/deck.md` で
// 編集を検知して slides.json を再生成する想定(make watch)。

const DEV_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);
const POLL_MS = 800;

export function setupHotReload() {
  if (!DEV_HOSTS.has(location.hostname)) return;

  let last = null;
  setInterval(async () => {
    let text;
    try {
      const res = await fetch("slides.json", { cache: "no-store" });
      if (!res.ok) return;
      text = await res.text();
    } catch {
      return; // ビルド途中で読めない瞬間などは無視
    }

    if (last === null) {
      last = text; // 初回はベースライン(起動直後の再描画を防ぐ)
      return;
    }
    if (text === last) return;
    last = text;

    let data;
    try {
      data = JSON.parse(text);
    } catch {
      return; // 書き込み途中の不完全 JSON は無視(次のポーリングで拾う)
    }
    document.dispatchEvent(new CustomEvent("kotoyomi:slides", { detail: data }));
  }, POLL_MS);
}
