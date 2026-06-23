// 開発時のライブリロード(SSE)。`kotoyomi serve`(監視時)が立てる SSE サーバ
// (:8001)へ EventSource で常時接続し、"reload" を受け取ったら slides.json を
// 取り直して CustomEvent("kotoyomi:slides") を発火する。Ruby 側
// (DeckControls#setup_hot_reload)が受けて @slides を差し替え、Lilac がその場で
// 再描画する(wasm 再起動なし・表示位置/テーマは維持)。
//
// ポーリングしないので、開いているだけで毎秒アクセスは出ない。SSE サーバが無い
// (serve していない/本番)場合は接続に失敗して一度きりで諦める(再試行スパムも
// 出さない)。localhost 以外では何もしない。

const DEV_HOSTS = new Set(["localhost", "127.0.0.1", "[::1]"]);

export function setupHotReload() {
  if (!DEV_HOSTS.has(location.hostname)) return;
  if (typeof EventSource === "undefined") return;

  // SSE は wsv のポート + 1(kotoyomi serve の SERVE_PORT+1 = 8001)。
  const port = Number(location.port || 80) + 1;

  let es;
  try {
    es = new EventSource(`http://127.0.0.1:${port}/`);
  } catch {
    return;
  }

  es.addEventListener("reload", async () => {
    try {
      const res = await fetch("slides.json", { cache: "no-store" });
      if (!res.ok) return;
      const data = JSON.parse(await res.text());
      document.dispatchEvent(new CustomEvent("kotoyomi:slides", { detail: data }));
    } catch {
      /* 取得/パース失敗(ビルド途中など)は無視。次の reload で拾う */
    }
  });

  // 接続できない(serve していない)なら EventSource は自動再接続を試みるので、
  // エラー時に閉じて再試行スパムを止める。serve 中は接続が確立し error は出ない。
  es.onerror = () => es.close();
}
