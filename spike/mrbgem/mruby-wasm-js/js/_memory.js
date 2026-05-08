// Shared memory helpers for index.js and wasi-preview1.js.
//
// Both modules need to encode/decode UTF-8 from wasm linear memory and
// read i32 arrays of handles. Keeping a single TextDecoder/Encoder pair
// avoids re-allocating per call, and the `createMemoryHelpers` factory
// binds them to a particular VM's instance via the `getInstance`
// callback (read on every helper call so callers can wire it before
// they actually have an instance handle — e.g. when building the
// imports object that's fed to instantiateStreaming).

export const decoder = new TextDecoder("utf-8");
export const encoder = new TextEncoder();

export function createMemoryHelpers(getInstance) {
  function readUtf8(ptr, len) {
    const memory = getInstance().exports.memory;
    return decoder.decode(new Uint8Array(memory.buffer, ptr, len));
  }
  function writeUtf8(s, ptr, maxLen) {
    const memory = getInstance().exports.memory;
    const view = new Uint8Array(memory.buffer, ptr, maxLen);
    const encoded = encoder.encode(s);
    const n = Math.min(encoded.length, maxLen);
    view.set(encoded.subarray(0, n));
    return n;
  }
  function readHandleArray(ptr, count) {
    if (count <= 0) return [];
    const view = new DataView(getInstance().exports.memory.buffer);
    const out = new Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getInt32(ptr + i * 4, true);
    return out;
  }
  return { readUtf8, writeUtf8, readHandleArray };
}
