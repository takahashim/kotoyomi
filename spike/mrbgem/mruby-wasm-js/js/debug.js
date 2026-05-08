// Shared debug toggle. Lives in its own module so index.js (gem core)
// and wasi-preview1.js (one of N possible WASI impls) can both import it
// without forming a cycle.
//
// Set `debug.trace = true` at runtime to log handle release / callback
// dispatch / WASI fd_read / WASI path_open. Off by default — production
// noise.
export const debug = { trace: false };
