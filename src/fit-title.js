// 通常スライドの h1(タイトル)を 1 行に収める。長いタイトルのときだけ
// font-size を縮める(短いときは CSS 既定の clamp サイズのまま)。
//
// 内容幅に応じた縮小は CSS だけではできないので JS で計測する。対象は
// data-layout の無い通常スライド(表紙 cover / 章扉 section は専用サイズなので
// 除外)。Lilac がスライドを差し替えるたび、MutationObserver で再フィットする。

const MIN_PX = 18; // これ以上は縮めない下限
// 通常スライド + カラムレイアウトの全幅ヘッダ h1 が対象。表紙(cover)・章扉
// (section)は専用の大きさ・中央寄せなので除外する。
const SELECTOR =
  '.slide .slide-body:not([data-layout="cover"]):not([data-layout="section"]) .slide-html h1';

function fitOne(h1) {
  h1.style.whiteSpace = "nowrap";
  h1.style.fontSize = ""; // いったん CSS 既定(clamp)へ戻してから計測
  const avail = h1.clientWidth; // h1 はブロック = 親(領域)の内容幅
  if (avail === 0) return; // レイアウト未確定(happy-dom 等)では何もしない
  const text = h1.scrollWidth; // nowrap 時の実テキスト幅
  if (text <= avail) return; // 収まっているので縮めない

  const base = parseFloat(getComputedStyle(h1).fontSize);
  const fitted = Math.max(MIN_PX, Math.floor(base * (avail / text)));
  h1.style.fontSize = `${fitted}px`;
}

function fitAll() {
  document.querySelectorAll(SELECTOR).forEach(fitOne);
}

export function setupFitTitle() {
  const root = document.querySelector(".deck") || document.body;
  let queued = false;
  const run = () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => {
      queued = false;
      fitAll();
    });
  };

  // スライド差し替え(data-unsafe-html の innerHTML 置換)を拾う。font-size の
  // style 変更は attributes なので childList 監視には乗らず、ループしない。
  new MutationObserver(run).observe(root, { childList: true, subtree: true });
  window.addEventListener("resize", run);
  run();
}
